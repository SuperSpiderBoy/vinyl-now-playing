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
[Net.ServicePointManager]::DefaultConnectionLimit = 12

function Await-RT($WinRtTask, $ResultType) {
    $asTask = $asTask1.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

$mgr = Await-RT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

# Low-memory shared caches (bounded to 30 items each)
$shared = [hashtable]::Synchronized(@{
    lyricsCache  = [hashtable]::Synchronized(@{})
    artworkCache = [hashtable]::Synchronized(@{})
    lyricsHits   = 0
    artworkHits  = 0
})

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

# Only external network endpoints (/artwork & /lyrics) use a tiny 2-worker pool
$netWorker = {
    param($ctx, $shared, $path, $title, $artist, $album, $duration)
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
    $res = $ctx.Response

    function Get-Utf8String($url, $method = "GET", $headers = @{}, $timeoutMs = 3500) {
        $r = [System.Net.HttpWebRequest]::Create($url)
        $r.Method = $method
        $r.Timeout = $timeoutMs
        $r.ReadWriteTimeout = $timeoutMs
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
    }

    function Get-Utf8Json($url, $method = "GET", $headers = @{}, $timeoutMs = 3500) {
        return ((Get-Utf8String $url $method $headers $timeoutMs) | ConvertFrom-Json)
    }

    function Test-LooseMatch($a, $b) {
        if (-not $a -or -not $b) { return $false }
        $na = ($a.ToLower() -replace '[^\p{L}\p{Nd}]', '')
        $nb = ($b.ToLower() -replace '[^\p{L}\p{Nd}]', '')
        if (-not $na -or -not $nb) { return $false }
        return ($na -eq $nb -or $na.Contains($nb) -or $nb.Contains($na))
    }

    function Resolve-AppleMotionMp4($albumUrl) {
        if (-not $albumUrl) { return "" }
        try {
            $cnUrl = ($albumUrl -replace 'https://music\.apple\.com/[a-z]{2}/', 'https://music.apple.com/cn/') -replace '\?.*$', ''
            $html = Get-Utf8String $cnUrl "GET" @{} 4500
            $m3u8List = [regex]::Matches($html, 'https://mvod\.itunes\.apple\.com/[^"''\\]+\.m3u8') | ForEach-Object { $_.Value } | Select-Object -Unique
            if (-not $m3u8List) { return "" }
            foreach ($masterUrl in $m3u8List) {
                try {
                    $master = Get-Utf8String $masterUrl "GET" @{} 3000
                    $variants = [regex]::Matches($master, '#EXT-X-STREAM-INF:[^\r\n]*CODECS="avc1[^"]*"[^\r\n]*RESOLUTION=(\d+)x(\d+)[^\r\n]*[\r\n]+(https://[^\r\n]+)')
                    $bestUrl = ""; $bestScore = -1
                    foreach ($v in $variants) {
                        $w = [int]$v.Groups[1].Value; $h = [int]$v.Groups[2].Value
                        if ($w -eq $h -and $w -ge 480 -and $w -le 960) {
                            # Prefer 768x768 (crisp yet much lower VRAM/decode power than 1080x1080)
                            $score = if ($w -eq 768) { 1000 } elseif ($w -eq 960) { 950 } else { $w }
                            if ($score -gt $bestScore) { $bestScore = $score; $bestUrl = $v.Groups[3].Value.Trim() }
                        }
                    }
                    if ($bestUrl) {
                        $varPl = Get-Utf8String $bestUrl "GET" @{} 3000
                        $mp4M = [regex]::Match($varPl, 'URI="([^"]+\.mp4)"')
                        if (-not $mp4M.Success) { $mp4M = [regex]::Match($varPl, '(?m)^([^\r\n#]+\.mp4)\s*$') }
                        if ($mp4M.Success) {
                            $fn = $mp4M.Groups[1].Value.Trim()
                            if ($fn -match '^https?://') { return $fn }
                            return "$($bestUrl.Substring(0, $bestUrl.LastIndexOf('/') + 1))$fn"
                        }
                    }
                } catch {}
            }
        } catch {}
        return ""
    }

    try {
        $res.Headers.Add("Access-Control-Allow-Origin", "*")
        $res.Headers.Add("Cache-Control", "no-store")
        $body = "{}"

        if ($path -eq "/artwork") {
            $cacheKey = "$title||$artist||$album"
            if ($shared.artworkCache.ContainsKey($cacheKey)) {
                $body = $shared.artworkCache[$cacheKey]
            } else {
                $resObj = @{ hiResCover = ""; motionVideo = ""; artist = ""; album = ""; appleUrl = "" }
                $cleanTitle = ($title -replace '\s*[\(\[（【](feat\.|ft\.|Live|Remaster|Explicit|Deluxe).*?[\)\]）】]', '').Trim()
                $cleanArtist = ($artist -split '[,/&、]')[0].Trim()
                $cleanAlbum = ($album -replace '\s*[\(\[（【](Deluxe|Expanded|Remaster|Edition|Bonus).*?[\)\]）】]', '').Trim()
                $cc = if ($cleanTitle -match '[\u4e00-\u9fff]') { "cn" } else { "us" }

                $hit = $null
                if ($cleanAlbum) {
                    try {
                        $it = Get-Utf8Json "https://itunes.apple.com/search?term=$([uri]::EscapeDataString("$cleanAlbum $cleanArtist".Trim()))&country=$cc&entity=album&limit=4" "GET" @{} 2500
                        foreach ($c in $it.results) {
                            if ((Test-LooseMatch $cleanAlbum $c.collectionName) -and ((-not $cleanArtist) -or (Test-LooseMatch $cleanArtist $c.artistName))) {
                                $hit = $c; break
                            }
                        }
                    } catch {}
                }
                if (-not $hit -and $cleanTitle) {
                    try {
                        $it = Get-Utf8Json "https://itunes.apple.com/search?term=$([uri]::EscapeDataString("$cleanTitle $cleanArtist".Trim()))&country=$cc&entity=song&limit=4" "GET" @{} 2500
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
                    if ($hit.collectionViewUrl) {
                        $resObj.appleUrl = [string]$hit.collectionViewUrl
                        $mp4 = Resolve-AppleMotionMp4 $hit.collectionViewUrl
                        if ($mp4) { $resObj.motionVideo = $mp4 }
                    }
                }
                if (-not $resObj.hiResCover -and $cleanTitle) {
                    try {
                        $sr = Get-Utf8Json "https://music.163.com/api/search/get/web?csrf_token=&s=$([uri]::EscapeDataString("$cleanTitle $cleanArtist".Trim()))&type=1&offset=0&total=true&limit=3" "POST" @{ "Referer" = "https://music.163.com/" } 2500
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
                if ($shared.artworkCache.Count -ge 30) { $shared.artworkCache.Clear() }
                $shared.artworkCache[$cacheKey] = $body
            }
        } elseif ($path -eq "/lyrics") {
            $cacheKey = "$title||$artist"
            if ($shared.lyricsCache.ContainsKey($cacheKey)) {
                $body = $shared.lyricsCache[$cacheKey]
            } else {
                $result = @{ yrc = ""; synced = ""; tlyric = ""; plain = ""; source = "none" }
                $cleanTitle = ($title -replace '\s*[\(\[（【](feat\.|ft\.|Live|Remaster|Explicit|Deluxe).*?[\)\]）】]', '').Trim()
                $cleanArtist = ($artist -split '[,/&、]')[0].Trim()
                $normTitle = ($cleanTitle.ToLower() -replace '[^\p{L}\p{Nd}]', '')

                $neLrc = ""; $neTlyric = ""
                try {
                    $sr = Get-Utf8Json "https://music.163.com/api/search/get/web?csrf_token=&s=$([uri]::EscapeDataString("$cleanTitle $cleanArtist".Trim()))&type=1&offset=0&total=true&limit=5" "POST" @{ "Referer" = "https://music.163.com/" } 3500
                    $bestSong = $null
                    foreach ($song in $sr.result.songs) {
                        $sNorm = (([string]$song.name).ToLower() -replace '[^\p{L}\p{Nd}]', '')
                        $durOk = ($duration -le 0 -or [math]::Abs(($song.duration / 1000.0) - $duration) -lt 15)
                        if ($normTitle -and ($sNorm -eq $normTitle -or $sNorm.Contains($normTitle) -or $normTitle.Contains($sNorm)) -and $durOk) {
                            $bestSong = $song; break
                        }
                    }
                    if (-not $bestSong -and $sr.result.songs.Count -gt 0) {
                        $s0 = $sr.result.songs[0]
                        $s0Norm = (([string]$s0.name).ToLower() -replace '[^\p{L}\p{Nd}]', '')
                        if ($normTitle -and ($s0Norm.Contains($normTitle) -or $normTitle.Contains($s0Norm))) { $bestSong = $s0 }
                    }
                    if ($bestSong) {
                        $lr = Get-Utf8Json "https://music.163.com/api/song/lyric?id=$($bestSong.id)&lv=1&yv=1&tv=-1" "GET" @{ "Referer" = "https://music.163.com/" } 3500
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
                        $r = Get-Utf8Json $u "GET" @{} 3500
                        if ($r.syncedLyrics) {
                            $result = @{ yrc = ""; synced = [string]$r.syncedLyrics; tlyric = $neTlyric; plain = [string]$r.plainLyrics; source = "lrclib" }
                        } elseif ($r.plainLyrics) { $result.plain = [string]$r.plainLyrics }
                    } catch {}
                }
                if (-not $result.yrc -and -not $result.synced) {
                    try {
                        $arr = Get-Utf8Json "https://lrclib.net/api/search?q=$([uri]::EscapeDataString("$cleanTitle $cleanArtist".Trim()))" "GET" @{} 3500
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

# Tiny 2-thread pool ONLY for rare external network requests
$netPool = [runspacefactory]::CreateRunspacePool(1, 2)
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

        # External network routes run asynchronously on 2-worker pool (never block /state or /cover!)
        if ($path -eq "/artwork" -or $path -eq "/lyrics") {
            if ($path -eq "/artwork") { $shared.artworkHits++ } else { $shared.lyricsHits++ }
            $d = 0.0
            [double]::TryParse([string]$qs["duration"], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) | Out-Null
            $ps = [powershell]::Create()
            $ps.RunspacePool = $netPool
            [void]$ps.AddScript($netWorker).AddArgument($ctx).AddArgument($shared).AddArgument($path).AddArgument([string]$qs["title"]).AddArgument([string]$qs["artist"]).AddArgument([string]$qs["album"]).AddArgument($d)
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
                    stateHits    = $script:stateHits
                    lyricsHits   = $shared.lyricsHits
                    artworkHits  = $shared.artworkHits
                    lastOrigin   = $script:lastOrigin
                    lyricsCache  = $shared.lyricsCache.Count
                    artworkCache = $shared.artworkCache.Count
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
