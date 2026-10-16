#requires -Version 5.1
<#
  tasks.ps1 -- deploy the app and (re)register its scheduled tasks.
  ===================================================================================
  Called by "install" / "repair" (UsbNetFix.ps1 install, migrate-to-apps.ps1,
  upgrade).  It is idempotent: safe to run any time something looks off.

  Task model: NO resident daemon.  Two tasks run short one-shot processes:
      UsbNetFix-Poll      - at boot + every minute (safety net)
      UsbNetFix-OnConnect - Windows event when a network profile is created/renamed

  Layout it expects (the app folder):
      <App>\lib\usbnet-fix.ps1, netprof-lib.ps1, manage.ps1 ...
      <App>\config.json

  ASCII only.
#>
[CmdletBinding()]
param([string]$SourceDir)

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Admin)) {
    $argl = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
    if ($SourceDir) { $argl += @('-SourceDir', $SourceDir) }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -Verb RunAs -Wait
    exit
}

# app root resolution - get this wrong and every trigger fires into the void (that
# happened once during development: the task did run, but its -File pointed at a dev
# folder with no lib\ in it, so it silently did nothing).
# Order of preference:
#   1. -SourceDir, when it really is an installed app (has lib\usbnet-fix.ps1)
#   2. $env:UsbNetFixHome or $DefaultAppRoot, when that is an installed app
#   3. this script's folder (or its parent, for a lib\ layout)
#   4. $DefaultAppRoot as the last resort
# Override the install location with:  setx UsbNetFixHome "D:\Tools\UsbNetFix"
$DefaultAppRoot = if ($env:UsbNetFixHome) { $env:UsbNetFixHome } else { Join-Path $env:ProgramData 'UsbNetFix' }
function Test-InstalledApp {
    param([string]$Path)
    if (-not $Path) { return $false }
    $runner = Join-Path $Path 'usbnet-fix.ps1'
    if (-not (Test-Path $runner)) { $runner = Join-Path $Path 'lib\usbnet-fix.ps1' }
    return ((Test-Path $runner) -and (Test-Path (Join-Path $Path 'config.json')))
}
# Both layouts are supported: flat (no lib\) and lib\ (what deploy.ps1 produces).
function Get-AppScript {
    param([string]$Name)
    $flat = Join-Path $appRoot $Name
    if (Test-Path $flat) { return $flat }
    return (Join-Path $appRoot ('lib\' + $Name))
}
$devDir  = $SourceDir
if (-not $devDir) { $devDir = $PSScriptRoot }

$appRoot = ''
if (Test-InstalledApp $SourceDir) { $appRoot = $SourceDir }
if (-not $appRoot -and (Test-InstalledApp $DefaultAppRoot)) { $appRoot = $DefaultAppRoot }
if (-not $appRoot -and $PSScriptRoot) {
    $parent = Split-Path -Parent $PSScriptRoot
    if ($parent -and (Test-InstalledApp $parent)) { $appRoot = $parent }
    elseif (Test-InstalledApp $PSScriptRoot) { $appRoot = $PSScriptRoot }
}
if (-not $appRoot) { $appRoot = $DefaultAppRoot }

# recognise the layout that is actually present instead of assuming lib\
$flatRunner = Join-Path $appRoot 'usbnet-fix.ps1'
$useFlat    = Test-Path $flatRunner
$libDir     = if ($useFlat) { $appRoot } else { Join-Path $appRoot 'lib' }
$watcher    = if ($useFlat) { $flatRunner } else { Join-Path $libDir 'usbnet-fix.ps1' }
$logDir     = Join-Path $appRoot 'log'
$bakDir     = Join-Path $appRoot 'backup'
New-Item -ItemType Directory -Force -Path $appRoot, $logDir, $bakDir | Out-Null
if (-not $useFlat) { New-Item -ItemType Directory -Force -Path $libDir | Out-Null }

$log = Join-Path $logDir 'tasks.txt'
$L = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $L.Add($s); Write-Host $s }

W ('### tasks / deploy  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ('  app root : ' + $appRoot)
W ('  dev dir  : ' + $devDir)
W ('  runner   : ' + $watcher)

. (Get-AppScript 'netprof-lib.ps1')

# --- deploy the implementation into lib\ (only when the sources live elsewhere) -------
$srcForFiles = $devDir
$sameFolder = $false
try { $sameFolder = ((Resolve-Path $srcForFiles).Path -eq (Resolve-Path $appRoot).Path) } catch { }
if ($srcForFiles -and -not $sameFolder) {
    $libSrc = $srcForFiles
    if ((Test-Path (Join-Path $srcForFiles 'lib\usbnet-fix.ps1')) -and
        -not (Test-Path (Join-Path $srcForFiles 'usbnet-fix.ps1'))) {
        $libSrc = Join-Path $srcForFiles 'lib'
    }
    foreach ($f in @('usbnet-fix.ps1','netprof-lib.ps1','tasks.ps1','uninstall.ps1','diag-watcher.ps1')) {
        $s = Join-Path $libSrc $f
        $d = Join-Path $libDir $f
        if (-not (Test-Path $s)) { continue }
        try { if ((Resolve-Path $s).Path -ne (Resolve-Path $d -ErrorAction SilentlyContinue).Path) { Copy-Item -LiteralPath $s -Destination $d -Force -ErrorAction Stop; W ('   deployed lib\' + $f) } }
        catch { W ('   [warn] could not deploy lib\' + $f + ' : ' + $_.Exception.Message) }
    }
    foreach ($f in @('UsbNetFix.ps1','UsbNetFix.cmd','README.md')) {
        $s = Join-Path $srcForFiles $f
        $d = Join-Path $appRoot $f
        if (-not (Test-Path $s)) { continue }
        try { if ((Resolve-Path $s).Path -ne (Resolve-Path $d -ErrorAction SilentlyContinue).Path) { Copy-Item -LiteralPath $s -Destination $d -Force -ErrorAction Stop; W ('   deployed ' + $f) } }
        catch { W ('   [warn] could not deploy ' + $f + ' : ' + $_.Exception.Message) }
    }
} else {
    W '   sources already in place (running from the installed app)'
}
if (-not (Test-Path (Join-Path $appRoot 'config.json'))) {
    $s = Join-Path $srcForFiles 'config.json'
    if (Test-Path $s) { Copy-Item $s $appRoot -Force; W '   config.json installed' }
    else { W '   [WARN] no config.json - defaults will be used' }
}
if (-not (Test-Path $watcher)) { W '   [ERROR] watcher missing - the task would do nothing!' }

# --- stop whatever is running -------------------------------------------------------
foreach ($n in @('UsbNetFix-Poll','UsbNetFix-OnConnect','UsbNetFix-Watcher','UsbNetFix-Watchdog')) {
    Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
}
W '   old tasks removed'
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.CommandLine -match 'usbnet-fix\.ps1') {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }
}
W ('   stopped ' + $killed + ' running instance(s)')

# --- register -----------------------------------------------------------------------
# EVENT DRIVEN, NO POLLING.  A run costs ~0.5 s when no phone is attached, and it only
# happens when something actually happened:
#     Kernel-PnP EventID 410/400             a USB device started/configured
#     NetworkProfile EventID 10000-10002     Windows created/changed/deleted a profile
#     BootTrigger (30 s delay)               safety net after every boot
#     CalendarTrigger (once a day)           last resort if an event was missed
#
# NOTE on the Kernel-PnP filter: Windows event queries accept only EQUALITY on EventData
# (contains() is rejected with "The specified query is invalid"), and the USB instance
# path changes with the port, so the phone cannot be named in the query.  Matching on
# EventID 410/400 alone is deliberate - the script checks for a phone adapter within
# ~0.5 s and exits immediately when there is none.
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>UsbNetFix</Author>
    <Description>UsbNetFix: names the USB tethering network profile after the phone that created it. Event driven - no polling.</Description>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-Kernel-PnP/Configuration"&gt;&lt;Select Path="Microsoft-Windows-Kernel-PnP/Configuration"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-PnP'] and (EventID=410 or EventID=400)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10000 or EventID=10001 or EventID=10002)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <BootTrigger>
      <Enabled>true</Enabled>
      <Delay>PT30S</Delay>
    </BootTrigger>
    <CalendarTrigger>
      <StartBoundary>2026-01-01T12:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>2</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$watcher"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
try {
    Register-ScheduledTask -TaskName 'UsbNetFix-OnPhonePlug' -Xml $taskXml -Force -ErrorAction Stop | Out-Null
    W '   registered UsbNetFix-OnPhonePlug (USB event + profile event + boot + daily)'
} catch {
    W ('   [ERROR] registration failed: ' + $_.Exception.Message)
}
if (-not (Test-Path $watcher)) { W '   [ERROR] runner missing - the task would do nothing!' }

# --- one test run -------------------------------------------------------------------
W ''
W 'test run:'
$out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $watcher 2>&1
foreach ($o in @($out)) { W ('   ' + $o) }

W ''
W 'tasks now:'
foreach ($n in @('UsbNetFix-OnPhonePlug','UsbNetFix-Poll','UsbNetFix-OnConnect')) {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if (-not $t) { W ('   ' + $n + ': absent'); continue }
    $i = $t | Get-ScheduledTaskInfo
    W ('   ' + $n + ': ' + $t.State + '  result=0x' + ('{0:X}' -f $i.LastTaskResult))
    W ('        action: ' + $t.Actions[0].Arguments)
    foreach ($tr in $t.Triggers) {
        $tag = ''
        if ($tr.CimClass.CimClassName -eq 'MSFT_TaskEventTrigger') {
            $s = [string]$tr.Subscription
            if ($s -match 'Kernel-PnP') { $tag = '  [USB device event]' }
            elseif ($s -match 'NetworkProfile') { $tag = '  [network profile event]' }
        }
        W ('        trigger: ' + $tr.CimClass.CimClassName + $tag)
    }
}
W ''
W 'no polling task is registered any more.'

$L | Set-Content $log -Encoding UTF8
Write-Host ('WROTE ' + $log)
