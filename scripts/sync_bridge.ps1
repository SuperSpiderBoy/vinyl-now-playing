param([int]$Port = 28973)

Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Web

$asTask1 = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

$asStreamMethod = [System.IO.WindowsRuntimeStreamExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsStreamForRead' -and $_.GetParameters().Count -eq 1
} | Select-Object -First 1

[Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime] | Out-Null
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
[Net.ServicePointManager]::DefaultConnectionLimit = 16

function Await-RT($WinRtTask, $ResultType) {
    $asTask = $asTask1.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

$mgr = Await-RT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

# Persistent disk cache directory for resolved motion cover URLs & public Apple Music storefront JWT
$cacheDir = Join-Path $env:LOCALAPPDATA "VinylNowPlaying"
try { New-Item -ItemType Directory -Force $cacheDir | Out-Null } catch {}
$motionCacheFile = Join-Path $cacheDir "motion_cache.json"

# Low-memory shared caches (bounded)
$shared = [hashtable]::Synchronized(@{
    lyricsCache     = [hashtable]::Synchronized(@{})
    artworkCache    = [hashtable]::Synchronized(@{})
    motionCache     = [hashtable]::Synchronized(@{}) # positive + session-only negative cache
    motionDiskMap   = [hashtable]::Synchronized(@{}) # persisted positive albumKey -> mp4 url
    appleToken      = ""
    appleTokenExp   = [long]0
    motionCacheFile = $motionCacheFile
    diskLock        = (New-Object object)
    tokenLock       = (New-Object object)
    lyricsHits      = 0
    artworkHits     = 0
    motionHits      = 0
})

# Hydrate persistent motion cache & cached JWT from disk (< 40KB)
if (Test-Path $motionCacheFile) {
    try {
        $raw = Get-Content -Path $motionCacheFile -Raw -Encoding UTF8 -ErrorAction Stop
        if ($raw) {
            $parsed = $raw | ConvertFrom-Json
            if ($parsed.token -and $parsed.tokenExp) {
                $shared.appleToken = [string]$parsed.token
                $shared.appleTokenExp = [long]$parsed.tokenExp
            }
            if ($parsed.albums) {
                foreach ($prop in $parsed.albums.PSObject.Properties) {
                    if ($prop.Value -and ([string]$prop.Value).StartsWith("http")) {
                        $shared.motionDiskMap[$prop.Name] = [string]$prop.Value
                    }
                }
            }
        }
    } catch {}
}

# Main-thread state (zero runspace allocation on /state, /cover, /seek, /control!)
$script:cachedCoverKey = ""
$script:cachedCoverBytes = $null
$script:cachedCoverMime = "image/jpeg"
$script:prevCoverSig = ""
$script:lastTrackForSig = ""
$script:seekTrackKey = ""
$script:seekPos = 0.0
$script:seekAt = [DateTimeOffset]::MinValue
$script:seekBaseUpd = [DateTimeOffset]::MinValue
$script:lastStateKey = ""
$script:trackChangedAt = [DateTimeOffset]::MinValue
$script:staleUpdAtSwitch = [DateTimeOffset]::MinValue
$script:staleDurAtSwitch = -1.0
$script:stateHits = 0
$script:lastOrigin = ""

function Get-MusicSession {
    $sessions = $mgr.GetSessions()
    foreach ($s in $sessions) {
        if ($s.SourceAppUserModelId -match 'MyGo') { return $s }
    }
    return $mgr.GetCurrentSession()
}

function Read-CoverBytes($session, $key) {
    if ($key -eq $script:cachedCoverKey -and $null -ne $script:cachedCoverBytes) {
        return $script:cachedCoverBytes
    }
    try {
        $info = Await-RT ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        if ($null -eq $info.Thumbnail) { return $null }
        $stream = Await-RT ($info.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
        $netStream = $asStreamMethod.Invoke($null, @($stream))
        $ms = New-Object System.IO.MemoryStream
        $netStream.CopyTo($ms)
        $bytes = $ms.ToArray()
        try { $ms.Dispose() } catch {}
        try { $netStream.Dispose() } catch {}
        if ($bytes.Length -lt 64) { return $null }

        $sig = "$($bytes.Length)_$($bytes[64])_$($bytes[$bytes.Length - 16])"
        if ($key -ne $script:lastTrackForSig -and $sig -eq $script:prevCoverSig) {
            Start-Sleep -Milliseconds 160
            $info2 = Await-RT ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
            if ($null -ne $info2.Thumbnail) {
                $st2 = Await-RT ($info2.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
                $ns2 = $asStreamMethod.Invoke($null, @($st2))
                $ms2 = New-Object System.IO.MemoryStream
                $ns2.CopyTo($ms2)
                $b2 = $ms2.ToArray()
                try { $ms2.Dispose(); $ns2.Dispose() } catch {}
                if ($b2.Length -ge 64) {
                    $bytes = $b2
                    $sig = "$($bytes.Length)_$($bytes[64])_$($bytes[$bytes.Length - 16])"
                }
            }
        }

        $mime = "image/jpeg"
        if ($bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) { $mime = "image/png" }
        elseif ($bytes[0] -eq 0x52 -and $bytes[1] -eq 0x49) { $mime = "image/webp" }

        $script:prevCoverSig = $sig
        $script:lastTrackForSig = $key
        $script:cachedCoverKey = $key
        $script:cachedCoverBytes = $bytes
        $script:cachedCoverMime = $mime
        return $bytes
    } catch {
        return $null
    }
}

# Lightweight 3-worker pool for external network endpoints (/artwork stage 1, /motion stage 2, /lyrics)
$netWorker = {
    param($ctx, $shared, $path, $title, $artist, $album, $duration, $refresh)
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
    $res = $ctx.Response

    function Get-Utf8String($url, $method = "GET", $headers = @{}, $timeoutMs = 5000, $retries = 1) {
        $lastErr = $null
        for ($attempt = 0; $attempt -le $retries; $attempt++) {
            try {
                $r = [System.Net.HttpWebRequest]::Create($url)
                $r.Method = $method
                $r.Timeout = $timeoutMs
                $r.ReadWriteTimeout = $timeoutMs
                $r.KeepAlive = $true
                $r.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
                $r.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
                foreach ($k in $headers.Keys) {
                    if ($k -eq "Referer") { $r.Referer = $headers[$k] }
                    elseif ($k -eq "Accept") { $r.Accept = $headers[$k] }
                    else { $r.Headers.Add($k, $headers[$k]) }
                }
                if ($method -eq "POST") { $r.ContentLength = 0 }
                $resp = $r.GetResponse()
                try {
                    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                    return $sr.ReadToEnd()
                } finally {
                    $resp.Close()
                }
            } catch [System.Net.WebException] {
                $lastErr = $_
                $code = 0
                try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch {}
                if ($code -eq 401 -or $code -eq 403 -or $code -eq 404) { throw }
                if ($attempt -lt $retries) { Start-Sleep -Milliseconds 180 }
            } catch {
                $lastErr = $_
                if ($attempt -lt $retries) { Start-Sleep -Milliseconds 180 }
            }
        }
        if ($lastErr) { throw $lastErr }
        return ""
    }

    function Get-Utf8Json($url, $method = "GET", $headers = @{}, $timeoutMs = 5000, $retries = 1) {
        return ((Get-Utf8String $url $method $headers $timeoutMs $retries) | ConvertFrom-Json)
    }

    function Normalize-Key($s) {
        if (-not $s) { return "" }
        return ($s.ToLower() -replace '[^\p{L}\p{Nd}]', '')
    }

    function Clean-Title($s) {
        if (-not $s) { return "" }
        return ($s -replace '\s*[\(\[（【](feat\.|ft\.|Live|Remaster|Explicit|Deluxe|Acoustic|Radio Edit|Version).*?[\)\]）】]', '').Trim()
    }

    function Clean-Album($s) {
        if (-not $s) { return "" }
        return ($s -replace '\s*[\(\[（【](Deluxe|Expanded|Remaster|Edition|Bonus|Explicit|Clean|Single|EP|Alternate|Complete|Anniversary).*?[\)\]）】]', '' -replace '\s*-\s*(Single|EP)$', '').Trim()
    }

    function Test-LooseMatch($a, $b) {
        $na = Normalize-Key $a
        $nb = Normalize-Key $b
        if (-not $na -or -not $nb) { return $false }
        return ($na -eq $nb -or $na.Contains($nb) -or $nb.Contains($na))
    }

    function Save-MotionDiskCache {
        [System.Threading.Monitor]::Enter($shared.diskLock)
        try {
            $albumsOut = @{}
            $keys = @($shared.motionDiskMap.Keys)
            if ($keys.Count -gt 200) {
                $keys = $keys[($keys.Count - 200)..($keys.Count - 1)]
                $shared.motionDiskMap.Clear()
            }
            foreach ($k in $keys) {
                $v = $shared.motionDiskMap[$k]
                if ($v) { $albumsOut[$k] = $v }
            }
            $payload = @{
                token    = [string]$shared.appleToken
                tokenExp = [long]$shared.appleTokenExp
                albums   = $albumsOut
            } | ConvertTo-Json -Depth 4 -Compress
            [System.IO.File]::WriteAllText($shared.motionCacheFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
        } catch {} finally {
            [System.Threading.Monitor]::Exit($shared.diskLock)
        }
    }

    function Get-JwtExp($jwt) {
        try {
            $parts = $jwt.Split('.')
            if ($parts.Length -lt 2) { return [long]0 }
            $b64 = $parts[1].Replace('-', '+').Replace('_', '/')
            while ($b64.Length % 4 -ne 0) { $b64 += '=' }
            $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
            if ($json.exp) { return [long]$json.exp }
        } catch {}
        return ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 86400 * 14)
    }

    function Get-AppleToken($forceRefresh = $false) {
        $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (-not $forceRefresh -and $shared.appleToken -and ($shared.appleTokenExp -gt ($nowUnix + 3600))) {
            return $shared.appleToken
        }
        [System.Threading.Monitor]::Enter($shared.tokenLock)
        try {
            $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if (-not $forceRefresh -and $shared.appleToken -and ($shared.appleTokenExp -gt ($nowUnix + 3600))) {
                return $shared.appleToken
            }
            foreach ($browseUrl in @("https://music.apple.com/cn/browse", "https://music.apple.com/us/browse")) {
                try {
                    $html = Get-Utf8String $browseUrl "GET" @{} 7000 1
                    $mJs = [regex]::Match($html, 'src="(/assets/index[^"]+\.js)"')
                    if (-not $mJs.Success) { $mJs = [regex]::Match($html, '(/assets/index[^"''\\]+\.js)') }
                    if ($mJs.Success) {
                        $js = Get-Utf8String ("https://music.apple.com" + $mJs.Groups[1].Value) "GET" @{} 9000 1
                        $mTok = [regex]::Match($js, 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}')
                        if ($mTok.Success) {
                            $tok = $mTok.Value
                            $shared.appleToken = $tok
                            $shared.appleTokenExp = Get-JwtExp $tok
                            Save-MotionDiskCache
                            return $tok
                        }
                    }
                } catch {}
            }
        } finally {
            [System.Threading.Monitor]::Exit($shared.tokenLock)
        }
        return ""
    }

    function Resolve-M3u8ToMp4($masterUrl) {
        if (-not $masterUrl) { return "" }
        try {
            $master = Get-Utf8String $masterUrl "GET" @{} 7500 1
            $lines = @($master -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
            $bestUrl = ""; $bestScore = -1
            for ($i = 0; $i -lt $lines.Count - 1; $i++) {
                $l = $lines[$i]
                if (-not $l.StartsWith("#EXT-X-STREAM-INF:")) { continue }
                if ($l -notmatch 'CODECS="avc1') { continue }
                $mRes = [regex]::Match($l, 'RESOLUTION=(\d+)x(\d+)')
                if (-not $mRes.Success) { continue }
                $w = [int]$mRes.Groups[1].Value
                $h = [int]$mRes.Groups[2].Value
                if ($w -lt 450) { continue }

                $isSquare = ([math]::Abs($w - $h) -le 6)
                # Prefer 768px (crisp + low VRAM/decode power), then 960px, then 1080px, then mid-res
                $score = if ($w -eq 768) { 1000 }
                    elseif ($w -eq 960) { 950 }
                    elseif ($w -eq 1080) { 910 }
                    elseif ($w -ge 640 -and $w -le 880) { 880 }
                    else { 500 + [math]::Min($w, 1080) / 4 }
                if ($isSquare) { $score += 220 }
                if ($l -match 'VIDEO-RANGE=SDR') { $score += 50 }

                if ($score -gt $bestScore) {
                    $bestScore = $score
                    $u = $lines[$i + 1]
                    if ($u -match '^https?://') { $bestUrl = $u }
                    else { $bestUrl = "$($masterUrl.Substring(0, $masterUrl.LastIndexOf('/') + 1))$u" }
                }
            }
            if (-not $bestUrl) { return "" }

            $varPl = Get-Utf8String $bestUrl "GET" @{} 7500 1
            $mp4M = [regex]::Match($varPl, 'URI="([^"]+\.mp4)"')
            if (-not $mp4M.Success) { $mp4M = [regex]::Match($varPl, '(?m)^([^\r\n#]+\.mp4)\s*$') }
            if ($mp4M.Success) {
                $fn = $mp4M.Groups[1].Value.Trim()
                if ($fn -match '^https?://') { return $fn }
                return "$($bestUrl.Substring(0, $bestUrl.LastIndexOf('/') + 1))$fn"
            }
        } catch {}
        return ""
    }

    function Pick-EditorialVideoUrl($ev) {
        if ($null -eq $ev) { return "" }
        # Prefer 1:1 square artwork, gracefully fall back to 3:4 tall (cropped seamlessly via object-fit: cover)
        foreach ($k in @("motionSquareVideo1x1", "motionDetailSquare", "motionTallVideo3x4", "motionDetailTall")) {
            try {
                $slot = $ev.$k
                if ($slot -and $slot.video) { return [string]$slot.video }
            } catch {}
        }
        return ""
    }

    function Search-AmpApiMotion($sf, $cleanTitle, $cleanArtist, $cleanAlbum) {
        $tok = Get-AppleToken $false
        if (-not $tok) { return $null }

        $makeHeaders = {
            param($t)
            @{
                "Authorization" = "Bearer $t"
                "Origin"        = "https://music.apple.com"
                "Referer"       = "https://music.apple.com/"
            }
        }

        $invokeAmp = {
            param($url)
            try {
                return Get-Utf8Json $url "GET" (& $makeHeaders $tok) 6000 1
            } catch [System.Net.WebException] {
                $code = 0
                try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch {}
                if ($code -eq 401 -or $code -eq 403) {
                    $tok = Get-AppleToken $true
                    if ($tok) {
                        return Get-Utf8Json $url "GET" (& $makeHeaders $tok) 6000 0
                    }
                }
                return $null
            } catch {
                return $null
            }
        }

        # 1. Search albums first when album metadata exists
        if ($cleanAlbum) {
            $term = "$cleanAlbum $cleanArtist".Trim()
            $url = "https://amp-api.music.apple.com/v1/catalog/$sf/search?term=$([uri]::EscapeDataString($term))&types=albums&limit=8&extend=editorialVideo"
            $d = & $invokeAmp $url
            if ($d -and $d.results -and $d.results.albums -and $d.results.albums.data) {
                $bestStatic = $null
                foreach ($a in $d.results.albums.data) {
                    $attr = $a.attributes
                    if (-not $attr) { continue }
                    $albOk = Test-LooseMatch $cleanAlbum ([string]$attr.name)
                    $artOk = (-not $cleanArtist) -or (Test-LooseMatch $cleanArtist ([string]$attr.artistName))
                    if (-not ($albOk -and $artOk)) { continue }
                    if (-not $bestStatic) { $bestStatic = $a }
                    $m3u8 = Pick-EditorialVideoUrl $attr.editorialVideo
                    if ($m3u8) {
                        return @{ m3u8 = $m3u8; album = $a; storefront = $sf }
                    }
                }
            }
        }

        # 2. Fallback: search songs -> resolve their parent album IDs -> batch fetch /albums?extend=editorialVideo
        # Handles singles, mismatched album tags, remixes, OSTs, or missing album metadata!
        if ($cleanTitle) {
            $term = "$cleanTitle $cleanArtist".Trim()
            $url = "https://amp-api.music.apple.com/v1/catalog/$sf/search?term=$([uri]::EscapeDataString($term))&types=songs&limit=6"
            $d = & $invokeAmp $url
            if ($d -and $d.results -and $d.results.songs -and $d.results.songs.data) {
                $albIds = New-Object System.Collections.ArrayList
                foreach ($s in $d.results.songs.data) {
                    $attr = $s.attributes
                    if (-not $attr) { continue }
                    $tOk = Test-LooseMatch $cleanTitle ([string]$attr.name)
                    $aOk = (-not $cleanArtist) -or (Test-LooseMatch $cleanArtist ([string]$attr.artistName))
                    if (-not ($tOk -and $aOk)) { continue }
                    $uStr = [string]$attr.url
                    $mId = [regex]::Match($uStr, '/album/[^/]+/(\d+)')
                    if ($mId.Success) {
                        $aid = $mId.Groups[1].Value
                        if (-not $albIds.Contains($aid)) { [void]$albIds.Add($aid) }
                    }
                    if ($albIds.Count -ge 4) { break }
                }
                if ($albIds.Count -gt 0) {
                    $idsCsv = ($albIds -join ",")
                    $bUrl = "https://amp-api.music.apple.com/v1/catalog/$sf/albums?ids=$idsCsv&extend=editorialVideo"
                    $d2 = & $invokeAmp $bUrl
                    if ($d2 -and $d2.data) {
                        foreach ($a in $d2.data) {
                            $m3u8 = Pick-EditorialVideoUrl $a.attributes.editorialVideo
                            if ($m3u8) {
                                return @{ m3u8 = $m3u8; album = $a; storefront = $sf }
                            }
                        }
                    }
                }
            }
        }
        return $null
    }

    try {
        $res.Headers.Add("Access-Control-Allow-Origin", "*")
        $res.Headers.Add("Cache-Control", "no-store")
        $body = "{}"

        $cleanTitle = Clean-Title $title
        $cleanArtist = ($artist -split '[,/&、]')[0].Trim()
        $cleanAlbum = Clean-Album $album
        $normAlbKey = if ($cleanAlbum) { "$(Normalize-Key $cleanArtist)||$(Normalize-Key $cleanAlbum)" } else { "$(Normalize-Key $cleanArtist)||t:$(Normalize-Key $cleanTitle)" }

        if ($path -eq "/artwork") {
            # STAGE 1: Fast static cover & metadata ONLY (<350ms). Never blocks on Apple M3U8 resolution!
            $cacheKey = "$title||$artist||$album"
            $cachedMotion = if ($shared.motionDiskMap.ContainsKey($normAlbKey)) { [string]$shared.motionDiskMap[$normAlbKey] } else { "" }

            if ($shared.artworkCache.ContainsKey($cacheKey)) {
                $obj = $shared.artworkCache[$cacheKey] | ConvertFrom-Json
                if ($cachedMotion -and -not $obj.motionVideo) {
                    $obj | Add-Member -NotePropertyName motionVideo -NotePropertyValue $cachedMotion -Force
                    $body = $obj | ConvertTo-Json -Compress
                } else {
                    $body = $shared.artworkCache[$cacheKey]
                }
            } else {
                $resObj = @{ hiResCover = ""; motionVideo = $cachedMotion; artist = ""; album = ""; appleUrl = ""; motionCached = [bool]$cachedMotion }
                $cc = if (("$cleanTitle $cleanArtist $cleanAlbum") -match '[\u4e00-\u9fff]') { "cn" } else { "us" }

                $hit = $null
                if ($cleanAlbum) {
                    try {
                        $it = Get-Utf8Json "https://itunes.apple.com/search?term=$([uri]::EscapeDataString("$cleanAlbum $cleanArtist".Trim()))&country=$cc&entity=album&limit=4" "GET" @{} 2500 0
                        foreach ($c in $it.results) {
                            if ((Test-LooseMatch $cleanAlbum $c.collectionName) -and ((-not $cleanArtist) -or (Test-LooseMatch $cleanArtist $c.artistName))) {
                                $hit = $c; break
                            }
                        }
                    } catch {}
                }
                if (-not $hit -and $cleanTitle) {
                    try {
                        $it = Get-Utf8Json "https://itunes.apple.com/search?term=$([uri]::EscapeDataString("$cleanTitle $cleanArtist".Trim()))&country=$cc&entity=song&limit=4" "GET" @{} 2500 0
                        foreach ($c in $it.results) {
                            if ((Test-LooseMatch $cleanTitle $c.trackName) -and ((-not $cleanArtist) -or (Test-LooseMatch $cleanArtist $c.artistName))) {
                                $hit = $c; break
                            }
                        }
                    } catch {}
                }

                if ($hit) {
                    if ($hit.artworkUrl100) { $resObj.hiResCover = ($hit.artworkUrl100 -replace '100x100bb', '800x800bb') }
                    if ($hit.artistName) { $resObj.artist = [string]$hit.artistName }
                    if ($hit.collectionName) { $resObj.album = [string]$hit.collectionName }
                    if ($hit.collectionViewUrl) { $resObj.appleUrl = [string]$hit.collectionViewUrl }
                }
                if (-not $resObj.hiResCover -and $cleanTitle) {
                    try {
                        $sr = Get-Utf8Json "https://music.163.com/api/search/get/web?csrf_token=&s=$([uri]::EscapeDataString("$cleanTitle $cleanArtist".Trim()))&type=1&offset=0&total=true&limit=3" "POST" @{ "Referer" = "https://music.163.com/" } 2500 0
                        foreach ($song in $sr.result.songs) {
                            if (Test-LooseMatch $cleanTitle $song.name) {
                                if ($song.album.picUrl) { $resObj.hiResCover = "$($song.album.picUrl)?param=800y800" }
                                if (-not $resObj.artist -and $song.artists.Count -gt 0) { $resObj.artist = ($song.artists | ForEach-Object { $_.name }) -join ", " }
                                if (-not $resObj.album -and $song.album.name) { $resObj.album = [string]$song.album.name }
                                break
                            }
                        }
                    } catch {}
                }

                $body = $resObj | ConvertTo-Json -Compress
                if ($shared.artworkCache.Count -ge 40) { $shared.artworkCache.Clear() }
                $shared.artworkCache[$cacheKey] = $body
            }

        } elseif ($path -eq "/motion") {
            # STAGE 2: Fast background Apple Music Motion Cover resolution via official amp-api + disk cache
            $forceRefresh = ($refresh -eq "1" -or $refresh -eq "true")
            if (-not $forceRefresh -and $shared.motionDiskMap.ContainsKey($normAlbKey)) {
                $body = (@{ motionVideo = [string]$shared.motionDiskMap[$normAlbKey]; cached = $true; source = "disk-cache" } | ConvertTo-Json -Compress)
            } elseif (-not $forceRefresh -and $shared.motionCache.ContainsKey($normAlbKey)) {
                $body = $shared.motionCache[$normAlbKey]
            } else {
                if ($forceRefresh) {
                    $shared.motionDiskMap.Remove($normAlbKey)
                    $shared.motionCache.Remove($normAlbKey)
                }

                $isCjk = (("$cleanTitle $cleanArtist $cleanAlbum") -match '[\u4e00-\u9fff]')
                $storefronts = if ($isCjk) { @("cn", "hk", "us") } else { @("us", "cn") }

                $mp4 = ""
                $usedSf = ""
                $hiRes = ""
                foreach ($sf in $storefronts) {
                    $found = Search-AmpApiMotion $sf $cleanTitle $cleanArtist $cleanAlbum
                    if ($found -and $found.m3u8) {
                        $mp4 = Resolve-M3u8ToMp4 $found.m3u8
                        if ($mp4) {
                            $usedSf = $sf
                            try {
                                $aw = $found.album.attributes.artwork.url
                                if ($aw) { $hiRes = ($aw -replace '\{w\}', '800' -replace '\{h\}', '800') }
                            } catch {}
                            break
                        }
                    }
                }

                $resObj = @{
                    motionVideo = $mp4
                    hiResCover  = $hiRes
                    storefront  = $usedSf
                    cached      = $false
                    source      = if ($mp4) { "amp-api-$usedSf" } else { "none" }
                }
                $body = $resObj | ConvertTo-Json -Compress

                if ($shared.motionCache.Count -ge 60) { $shared.motionCache.Clear() }
                $shared.motionCache[$normAlbKey] = $body

                if ($mp4) {
                    $shared.motionDiskMap[$normAlbKey] = $mp4
                    Save-MotionDiskCache
                }
            }

        } elseif ($path -eq "/lyrics") {
            $cacheKey = "$title||$artist"
            if ($shared.lyricsCache.ContainsKey($cacheKey)) {
                $body = $shared.lyricsCache[$cacheKey]
            } else {
                $result = @{ yrc = ""; synced = ""; tlyric = ""; plain = ""; source = "none" }
                $normTitle = Normalize-Key $cleanTitle

                $neLrc = ""; $neTlyric = ""
                try {
                    $sr = Get-Utf8Json "https://music.163.com/api/search/get/web?csrf_token=&s=$([uri]::EscapeDataString("$cleanTitle $cleanArtist".Trim()))&type=1&offset=0&total=true&limit=5" "POST" @{ "Referer" = "https://music.163.com/" } 3500 0
                    $bestSong = $null
                    foreach ($song in $sr.result.songs) {
                        $sNorm = Normalize-Key ([string]$song.name)
                        $durOk = ($duration -le 0 -or [math]::Abs(($song.duration / 1000.0) - $duration) -lt 15)
                        if ($normTitle -and ($sNorm -eq $normTitle -or $sNorm.Contains($normTitle) -or $normTitle.Contains($sNorm)) -and $durOk) {
                            $bestSong = $song; break
                        }
                    }
                    if (-not $bestSong -and $sr.result.songs.Count -gt 0) {
                        $s0 = $sr.result.songs[0]
                        $s0Norm = Normalize-Key ([string]$s0.name)
                        if ($normTitle -and ($s0Norm.Contains($normTitle) -or $normTitle.Contains($s0Norm))) { $bestSong = $s0 }
                    }
                    if ($bestSong) {
                        $lr = Get-Utf8Json "https://music.163.com/api/song/lyric?id=$($bestSong.id)&lv=1&yv=1&tv=-1" "GET" @{ "Referer" = "https://music.163.com/" } 3500 0
                        if ($lr.yrc.lyric) {
                            $result = @{ yrc = [string]$lr.yrc.lyric; synced = [string]$lr.lrc.lyric; tlyric = [string]$lr.tlyric.lyric; plain = ""; source = "netease-yrc" }
                        } elseif ($lr.lrc.lyric) {
                            $neLrc = [string]$lr.lrc.lyric; $neTlyric = [string]$lr.tlyric.lyric
                        }
                    }
                } catch {}

                if (-not $result.yrc -and -not $result.synced -and $cleanArtist) {
                    try {
                        $u = "https://lrclib.net/api/get?track_name=$([uri]::EscapeDataString($cleanTitle))&artist_name=$([uri]::EscapeDataString($cleanArtist))"
                        if ($duration -gt 0) { $u += "&duration=$([int][math]::Round($duration))" }
                        $r = Get-Utf8Json $u "GET" @{} 3500 0
                        if ($r.syncedLyrics) {
                            $result = @{ yrc = ""; synced = [string]$r.syncedLyrics; tlyric = $neTlyric; plain = [string]$r.plainLyrics; source = "lrclib" }
                        } elseif ($r.plainLyrics) { $result.plain = [string]$r.plainLyrics }
                    } catch {}
                }
                if (-not $result.yrc -and -not $result.synced) {
                    try {
                        $arr = Get-Utf8Json "https://lrclib.net/api/search?q=$([uri]::EscapeDataString("$cleanTitle $cleanArtist".Trim()))" "GET" @{} 3500 0
                        $hit = $arr | Where-Object { $_.syncedLyrics } | Select-Object -First 1
                        if ($hit) {
                            $result = @{ yrc = ""; synced = [string]$hit.syncedLyrics; tlyric = $neTlyric; plain = [string]$hit.plainLyrics; source = "lrclib-search" }
                        }
                    } catch {}
                }
                if (-not $result.yrc -and -not $result.synced -and $neLrc) {
                    $result = @{ yrc = ""; synced = $neLrc; tlyric = $neTlyric; plain = ""; source = "netease-lrc" }
                }

                $body = $result | ConvertTo-Json -Compress
                if ($shared.lyricsCache.Count -ge 30) { $shared.lyricsCache.Clear() }
                $shared.lyricsCache[$cacheKey] = $body
            }
        }

        $buf = [Text.Encoding]::UTF8.GetBytes($body)
        $res.ContentType = "application/json; charset=utf-8"
        $res.ContentLength64 = $buf.Length
        $res.OutputStream.Write($buf, 0, $buf.Length)
    } catch {
        try { $res.StatusCode = 500 } catch {}
    } finally {
        try { $res.Close() } catch {}
    }
}

# Lightweight 3-worker pool for external async routes (/artwork, /motion, /lyrics)
$netPool = [runspacefactory]::CreateRunspacePool(1, 3)
$netPool.Open()
$netJobs = New-Object System.Collections.ArrayList

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

$lastGc = [DateTimeOffset]::Now

while ($listener.IsListening) {
    try {
        $ctx = $listener.GetContext()

        # Reap completed network jobs & trim memory periodically
        for ($i = $netJobs.Count - 1; $i -ge 0; $i--) {
            if ($netJobs[$i].Handle.IsCompleted) {
                try { $netJobs[$i].PS.EndInvoke($netJobs[$i].Handle) } catch {}
                try { $netJobs[$i].PS.Dispose() } catch {}
                $netJobs.RemoveAt($i)
            }
        }
        if (([DateTimeOffset]::Now - $lastGc).TotalSeconds -gt 120) {
            [GC]::Collect()
            $lastGc = [DateTimeOffset]::Now
        }

        $req = $ctx.Request
        $res = $ctx.Response
        $qs = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query, [Text.Encoding]::UTF8)
        $path = $req.Url.AbsolutePath.ToLower()
        $orig = $req.Headers["Origin"]
        if ($orig) { $script:lastOrigin = $orig }

        # External network routes run asynchronously on 3-worker pool (never block /state or /cover!)
        if ($path -eq "/artwork" -or $path -eq "/motion" -or $path -eq "/lyrics") {
            if ($path -eq "/artwork") { $shared.artworkHits++ }
            elseif ($path -eq "/motion") { $shared.motionHits++ }
            else { $shared.lyricsHits++ }

            $d = 0.0
            [double]::TryParse([string]$qs["duration"], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) | Out-Null
            $ps = [powershell]::Create()
            $ps.RunspacePool = $netPool
            [void]$ps.AddScript($netWorker).AddArgument($ctx).AddArgument($shared).AddArgument($path).AddArgument([string]$qs["title"]).AddArgument([string]$qs["artist"]).AddArgument([string]$qs["album"]).AddArgument($d).AddArgument([string]$qs["refresh"])
            [void]$netJobs.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
            continue
        }

        # Fast local routes run directly on main thread (<2ms, ZERO runspace overhead!)
        try {
            $res.Headers.Add("Access-Control-Allow-Origin", "*")
            $res.Headers.Add("Cache-Control", "no-store")

            if ($path -eq "/state") {
                $script:stateHits++
                $s = Get-MusicSession
                if ($null -eq $s) {
                    $body = '{"active":false}'
                } else {
                    $info = Await-RT ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                    $pb = $s.GetPlaybackInfo()
                    $tl = $s.GetTimelineProperties()
                    $isPlaying = ($pb.PlaybackStatus.ToString() -eq 'Playing')
                    $dur = [math]::Max(0, $tl.EndTime.TotalSeconds)
                    $title = [string]$info.Title
                    $artist = [string]$info.Artist
                    $album = [string]$info.AlbumTitle
                    $key = "$title||$artist||$album"

                    if ($key -ne $script:lastStateKey) {
                        if ($script:lastStateKey -ne "") {
                            $script:trackChangedAt = [DateTimeOffset]::Now
                            $script:staleUpdAtSwitch = $tl.LastUpdatedTime
                            $script:staleDurAtSwitch = $dur
                        }
                        $script:lastStateKey = $key
                        $script:seekTrackKey = ""
                    } elseif ($script:staleUpdAtSwitch -ne [DateTimeOffset]::MinValue -and $tl.LastUpdatedTime -ne $script:staleUpdAtSwitch) {
                        $script:staleUpdAtSwitch = [DateTimeOffset]::MinValue
                    }

                    $useSeekAnchor = ($script:seekTrackKey -eq $key) -and ($tl.LastUpdatedTime -eq $script:seekBaseUpd) -and (([DateTimeOffset]::Now - $script:seekAt).TotalSeconds -lt 6.0)
                    $useSwitchGuard = ($script:staleUpdAtSwitch -ne [DateTimeOffset]::MinValue) -and ($tl.LastUpdatedTime -eq $script:staleUpdAtSwitch) -and (([DateTimeOffset]::Now - $script:trackChangedAt).TotalSeconds -lt 600.0)

                    if ($useSeekAnchor) {
                        $pos = $script:seekPos
                        if ($isPlaying) { $pos += ([DateTimeOffset]::Now - $script:seekAt).TotalSeconds }
                    } elseif ($useSwitchGuard) {
                        $pos = if ($isPlaying) { ([DateTimeOffset]::Now - $script:trackChangedAt).TotalSeconds } else { 0.0 }
                        if ($dur -eq $script:staleDurAtSwitch) { $dur = 0 }
                    } else {
                        if ($script:seekTrackKey -eq $key -and $tl.LastUpdatedTime -ne $script:seekBaseUpd) {
                            $script:seekTrackKey = ""
                        }
                        $pos = $tl.Position.TotalSeconds
                        if ($isPlaying -and $tl.LastUpdatedTime.Year -gt 2000) {
                            $elapsed = ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalSeconds
                            if ($elapsed -gt 0 -and $elapsed -lt 36000) { $pos += $elapsed }
                        }
                    }
                    if ($dur -gt 0 -and $pos -gt $dur) { $pos = $dur }
                    if ($pos -lt 0) { $pos = 0 }

                    $body = (@{
                        active   = ($title -ne "" -or $artist -ne "")
                        playing  = $isPlaying
                        status   = $pb.PlaybackStatus.ToString()
                        title    = $title
                        artist   = $artist
                        album    = $album
                        duration = [math]::Round($dur, 2)
                        position = [math]::Round($pos, 2)
                        trackKey = $key
                        hasCover = ($null -ne $info.Thumbnail)
                        app      = $s.SourceAppUserModelId
                    } | ConvertTo-Json -Compress)
                }
                $buf = [Text.Encoding]::UTF8.GetBytes($body)
                $res.ContentType = "application/json; charset=utf-8"
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)

            } elseif ($path -eq "/seek") {
                $posSec = 0.0
                [double]::TryParse([string]$qs["pos"], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$posSec) | Out-Null
                $s = Get-MusicSession
                $ok = $false
                if ($s) {
                    $info = Await-RT ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                    $tl = $s.GetTimelineProperties()
                    $key = "$([string]$info.Title)||$([string]$info.Artist)||$([string]$info.AlbumTitle)"
                    $dur = [math]::Max(0, $tl.EndTime.TotalSeconds)
                    if ($dur -gt 0 -and $posSec -gt $dur) { $posSec = $dur }
                    if ($posSec -lt 0) { $posSec = 0 }
                    $script:seekTrackKey = $key
                    $script:seekPos = $posSec
                    $script:seekAt = [DateTimeOffset]::Now
                    $script:seekBaseUpd = $tl.LastUpdatedTime
                    $ok = Await-RT ($s.TryChangePlaybackPositionAsync([long]([math]::Round($posSec * 10000000)))) ([bool])
                }
                $buf = [Text.Encoding]::UTF8.GetBytes((@{ ok = $ok; pos = $posSec } | ConvertTo-Json -Compress))
                $res.ContentType = "application/json; charset=utf-8"
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)

            } elseif ($path -eq "/control") {
                $cmd = [string]$qs["cmd"]
                $s = Get-MusicSession
                $ok = $false
                if ($s) {
                    if ($cmd -eq "toggle") { $ok = Await-RT ($s.TryTogglePlayPauseAsync()) ([bool]) }
                    elseif ($cmd -eq "next") { $ok = Await-RT ($s.TrySkipNextAsync()) ([bool]) }
                    elseif ($cmd -eq "prev") { $ok = Await-RT ($s.TrySkipPreviousAsync()) ([bool]) }
                }
                $buf = [Text.Encoding]::UTF8.GetBytes((@{ ok = $ok; cmd = $cmd } | ConvertTo-Json -Compress))
                $res.ContentType = "application/json; charset=utf-8"
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)

            } elseif ($path -eq "/cover") {
                $s = Get-MusicSession
                $key = [string]$qs["k"]
                if (-not $key) { $key = [guid]::NewGuid().ToString() }
                $bytes = if ($s) { Read-CoverBytes $s $key } else { $null }
                if ($bytes -and $bytes.Length -gt 0) {
                    $res.ContentType = $script:cachedCoverMime
                    $res.ContentLength64 = $bytes.Length
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $res.StatusCode = 404
                }

            } elseif ($path -eq "/debug") {
                $body = (@{
                    stateHits       = $script:stateHits
                    lyricsHits      = $shared.lyricsHits
                    artworkHits     = $shared.artworkHits
                    motionHits      = $shared.motionHits
                    lastOrigin      = $script:lastOrigin
                    lyricsCache     = $shared.lyricsCache.Count
                    artworkCache    = $shared.artworkCache.Count
                    motionCache     = $shared.motionCache.Count
                    motionDiskCache = $shared.motionDiskMap.Count
                    hasAppleToken   = [bool]$shared.appleToken
                } | ConvertTo-Json -Compress)
                $buf = [Text.Encoding]::UTF8.GetBytes($body)
                $res.ContentType = "application/json; charset=utf-8"
                $res.ContentLength64 = $buf.Length
                $res.OutputStream.Write($buf, 0, $buf.Length)

            } else {
                $res.StatusCode = 200
                $buf = [Text.Encoding]::UTF8.GetBytes("ok")
                $res.OutputStream.Write($buf, 0, $buf.Length)
            }
        } catch {
            try { $res.StatusCode = 500 } catch {}
        } finally {
            try { $res.Close() } catch {}
        }
    } catch {
        break
    }
}
