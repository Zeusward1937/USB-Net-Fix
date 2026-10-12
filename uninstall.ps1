#requires -Version 5.1
<#
  uninstall.ps1 -- removes the UsbNetFix scheduled task.
  ---------------------------------------------------------------------------
    * stops + unregisters the task and kills running instances
    * optionally removes the phone's leftover profiles (keeps one, backs up first)
    * optionally deletes the app folder
  ASCII only (Windows PowerShell 5.1 decodes BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [switch]$Purge,          # also delete the app folder
    [switch]$CleanProfiles,  # also remove leftover phone profiles without asking
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    $argl = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
    if ($Purge) { $argl += '-Purge' }
    if ($CleanProfiles) { $argl += '-CleanProfiles' }
    if ($Yes) { $argl += '-Yes' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -Verb RunAs -Wait
    exit
}

$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'netprof-lib.ps1')
$toolDir = NP-ToolDir

Write-Host ''
Write-Host '=== UsbNetFix - uninstall ==='
Write-Host ''

# ------------------------------------------------------------------ 1. task
Write-Host '[1/4] Scheduled task'
foreach ($t in @('UsbNetFix-OnPhonePlug','UsbNetFix-Poll','UsbNetFix-OnConnect','UsbNetFix-Watcher','UsbNetFix-Watchdog')) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host ('      removed ' + $t)
    } else { Write-Host ('      ' + $t + ' was not registered') }
}

# ------------------------------------------------------------------ 2. processes
Write-Host '[2/4] Running instances'
$killed = 0
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.CommandLine -and $_.CommandLine -match 'usbnet-fix\.ps1') {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ } catch { }
    }
}
Write-Host ('      stopped ' + $killed + ' process(es)')

# ------------------------------------------------------------------ 3. leftover profiles
Write-Host '[3/4] Leftover phone profiles'
$state = NP-GetState
$phone = @()
if ($state.PhoneGatewayMacs.Count -gt 0) {
    $phone = @(NP-GetProfiles | Where-Object { $state.PhoneGatewayMacs -contains $_.GatewayMac })
}
if ($phone.Count -le 1) {
    Write-Host '      nothing to clean'
} else {
    Write-Host ('      found ' + $phone.Count + ' profiles that came from a phone:')
    foreach ($p in $phone) { Write-Host ('        - ' + $p.Name + '   ' + (NP-MacPretty $p.GatewayMac)) }
    $doIt = $CleanProfiles
    if (-not $doIt -and -not $Yes) {
        $a = Read-Host '      Remove all but the newest one? (y/N)'
        $doIt = ($a -eq 'y' -or $a -eq 'Y')
    }
    if ($doIt) {
        $files = NP-ExportBackup -Dir (Join-Path $toolDir 'backup') -Tag 'uninstall'
        $ordered = @($phone | Sort-Object { if ($_.Created) { $_.Created } else { [datetime]::MinValue } } -Descending)
        $keep = $ordered[0]
        $n = 0
        foreach ($p in $ordered) { if ($p.Guid -eq $keep.Guid) { continue }; if (NP-RemoveProfile -Guid $p.Guid) { $n++ } }
        Write-Host ('      removed ' + $n + ", kept '" + $keep.Name + "'")
        if ($files.Count -gt 0) { Write-Host ('      backup: ' + ($files -join ', ')) }
    } else { Write-Host '      kept everything' }
}

# ------------------------------------------------------------------ 4. folder
Write-Host '[4/4] App folder'
if ($Purge) {
    Remove-Item $toolDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ('      removed ' + $toolDir)
} else {
    Write-Host ('      kept ' + $toolDir + '  (registry backups are in ' + (Join-Path $toolDir 'backup') + ')')
    Write-Host '      run with -Purge to delete it as well'
}

Write-Host ''
Write-Host 'Done. No saved Wi-Fi network or password was touched.'
Write-Host ''
