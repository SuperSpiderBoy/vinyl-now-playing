#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for Vinyl Now Playing (Lively Wallpaper + Windows SMTC Sync Bridge).
#>
[CmdletBinding()]
param(
    [switch]$SkipStartup
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== Vinyl Now Playing Installer ===" -ForegroundColor Cyan

# 1. Verify Lively Wallpaper directory
$livelyLib = Join-Path $env:LOCALAPPDATA "Lively Wallpaper\Library\wallpapers"
if (-not (Test-Path $livelyLib)) {
    Write-Warning "未检测到 Lively Wallpaper 用户目录 ($livelyLib)。"
    Write-Host "请先安装并运行一次 Lively Wallpaper：https://github.com/lively-community/lively/releases" -ForegroundColor Yellow
    Write-Host "或使用 winget 安装：winget install rocksdanister.LivelyWallpaper" -ForegroundColor Yellow
    exit 1
}

# 2. Copy wallpaper bundle into Lively Library
$wpDest = Join-Path $livelyLib "vinyl.nowplaying"
New-Item -ItemType Directory -Force $wpDest | Out-Null
Copy-Item -Path (Join-Path $root "wallpaper\*") -Destination $wpDest -Recurse -Force
Write-Host "[1/3] 已部署壁纸包到 Lively 库：$wpDest" -ForegroundColor Green

# 3. Install SMTC sync bridge scripts to user-local directory
$bridgeDir = Join-Path $env:LOCALAPPDATA "VinylNowPlaying\scripts"
New-Item -ItemType Directory -Force $bridgeDir | Out-Null
Copy-Item -Path (Join-Path $root "scripts\*") -Destination $bridgeDir -Force
Write-Host "[2/3] 已部署同步桥接脚本到：$bridgeDir" -ForegroundColor Green

# 4. Stop any previous sync_bridge instance
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\s+"?[^"]*sync_bridge\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 5. Register & start Windows Scheduled Task for logon auto-start
$vbsPath = Join-Path $bridgeDir "start_bridge.vbs"
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`""
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 0) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

if (-not $SkipStartup) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    Register-ScheduledTask -TaskName "VinylSyncBridge" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName "VinylSyncBridge"
    Write-Host "[3/3] 已注册并启动开机自启任务：VinylSyncBridge" -ForegroundColor Green
} else {
    Start-Process "wscript.exe" -ArgumentList "`"$vbsPath`""
    Write-Host "[3/3] 已按单次模式启动同步桥接（未注册开机自启）" -ForegroundColor Green
}

Start-Sleep -Seconds 2
try {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $null = $wc.DownloadString("http://127.0.0.1:28973/debug")
    Write-Host "同步服务自检通过：http://127.0.0.1:28973" -ForegroundColor Cyan
} catch {
    Write-Warning "同步服务尚未就绪，可手动执行：Start-ScheduledTask -TaskName 'VinylSyncBridge'"
}

Write-Host "`n下一步：打开 Lively Wallpaper，选择「Vinyl Now Playing (专辑黑胶)」即可启用！" -ForegroundColor White
