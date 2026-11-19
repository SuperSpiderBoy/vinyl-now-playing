#Requires -Version 5.1
<#
.SYNOPSIS
    Cleanly removes VinylSyncBridge scheduled task, running process, and deployed files.
#>
$ErrorActionPreference = 'SilentlyContinue'

Write-Host "=== Vinyl Now Playing Uninstaller ===" -ForegroundColor Yellow

# 1. Stop & unregister Scheduled Task
Stop-ScheduledTask -TaskName "VinylSyncBridge"
Unregister-ScheduledTask -TaskName "VinylSyncBridge" -Confirm:$false

# 2. Kill any running sync_bridge.ps1 process
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'sync_bridge\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 3. Remove bridge & Lively wallpaper copy
$bridgeRoot = Join-Path $env:LOCALAPPDATA "VinylNowPlaying"
if (Test-Path $bridgeRoot) { Remove-Item $bridgeRoot -Recurse -Force }

$wpDest = Join-Path $env:LOCALAPPDATA "Lively Wallpaper\Library\wallpapers\vinyl.nowplaying"
if (Test-Path $wpDest) { Remove-Item $wpDest -Recurse -Force }

Write-Host "已清理计划任务、后台进程与壁纸文件。" -ForegroundColor Green
