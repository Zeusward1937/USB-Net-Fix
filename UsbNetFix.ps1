#requires -Version 5.1
<#
  UsbNetFix.ps1 -- control panel / single entry point of the UsbNetFix app
  ===========================================================================
  Usage (double-click UsbNetFix.cmd for the interactive menu):

      .\UsbNetFix.ps1                 menu
      .\UsbNetFix.ps1 status          state report (devices, profiles, tasks, log tail)
      .\UsbNetFix.ps1 apply           apply the fix right now
      .\UsbNetFix.ps1 monitor         show live tethering state (USB/screen/MTP)
      .\UsbNetFix.ps1 names           show which name each phone gets, and why
      .\UsbNetFix.ps1 install         deploy + register the scheduled task
      .\UsbNetFix.ps1 uninstall       remove the task (and optionally everything else)
      .\UsbNetFix.ps1 diagnose        write a full diagnostic snapshot
      .\UsbNetFix.ps1 upgrade <dir>   copy a newer release over this app folder

  ASCII only (Windows PowerShell 5.1 decodes BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'menu',
    [Parameter(Position = 1)]
    [string]$Arg2
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'netprof-lib.ps1')

$script:CfgPath = NP-ConfigPath
$script:Cfg = $null
try { $script:Cfg = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
function Get-Cfg {
    param($Obj, [string]$Name, $Default)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Invoke-Elevated {
    param([string]$Script, [string[]]$Arguments = @())
    $argl = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $Script + '"')) + $Arguments
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -Verb RunAs -Wait -PassThru
    return $p.ExitCode
}
function Line { param([string]$T = '') Write-Host $T }
function Head { param([string]$T) Line; Line ('=' * 68); Line (' ' + $T); Line ('=' * 68) }

# --------------------------------------------------------------------------- commands
function Show-Status {
    $state = NP-GetState
    Head 'UsbNetFix status'
    Line (' app folder : ' + $root)
    Line (' config     : ' + $script:CfgPath)
    Line (' admin      : ' + (Test-Admin))
    Line ''

    Line '-- configured names -------------------------------------------------'
    Line ('  default name    : ' + (Get-Cfg $script:Cfg 'DefaultName' 'USB Tethering'))
    Line ('  name from model : ' + (Get-Cfg $script:Cfg 'AutoNameFromModel' $true))
    $rules = @()
    if ($script:Cfg -and $script:Cfg.PSObject.Properties['DeviceRules'] -and $script:Cfg.DeviceRules) { $rules = @($script:Cfg.DeviceRules) }
    if ($rules.Count -eq 0) { Line '  (no device rules - names come from the phone model)' }
    foreach ($r in $rules) {
        $m = ''; $n = ''; $v = ''
        if ($r.PSObject.Properties['ModelLike']) { $m = [string]$r.ModelLike }
        if ($r.PSObject.Properties['Name']) { $n = [string]$r.Name }
        if ($r.PSObject.Properties['Vid']) { $v = [string]$r.Vid }
        Line ('  rule: vid=' + $v + ' model~' + $m + '  ->  ' + $n)
    }
    Line ''

    Line '-- phones this app has seen (state.json) ----------------------------'
    if (-not $state.Devices -or @($state.Devices).Count -eq 0) { Line '  (none yet)' }
    foreach ($d in @($state.Devices)) {
        Line ('  ' + $d.Name)
        Line ('      model=' + $d.Model + '  id=' + $d.DeviceId + '  sessions=' + $d.Sessions + '  last=' + $d.LastSeen)
    }
    Line ('  confirmed fingerprints: ' + (($state.PhoneGatewayMacs | ForEach-Object { NP-MacPretty $_ }) -join ', '))
    Line ''

    Line '-- saved network profiles ------------------------------------------'
    if (NP-CanWrite) {
        $prof = @(NP-GetProfiles | Sort-Object { if ($_.Created) { $_.Created } else { [datetime]::MinValue } })
        foreach ($p in $prof) {
            $tag = '     '
            if ($state.PhoneGatewayMacs -contains $p.GatewayMac) { $tag = 'PHONE' }
            Line ('  [' + $tag + '] ' + $p.Name.PadRight(22) + ' cat=' + $p.Category + '  gw=' + (NP-MacPretty $p.GatewayMac))
        }
        Line ('  total: ' + $prof.Count)
    } else {
        Line '  (cannot read the saved-network database without administrator rights)'
        Line '  (run this from an elevated prompt, or double-click UsbNetFix.cmd and approve UAC)'
    }
    Line ''

    Line '-- live networks ---------------------------------------------------'
    foreach ($c in (Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        Line ('  ' + $c.Name.PadRight(22) + ' ' + $c.NetworkCategory + '  ' + $c.InterfaceAlias + '  IPv4=' + $c.IPv4Connectivity)
    }
    Line ''

    Line '-- scheduled task --------------------------------------------------'
    if (-not (Test-Admin)) { Line '  (task state needs administrator rights - showing configured names only)' }
    foreach ($n in @('UsbNetFix-OnPhonePlug','UsbNetFix-Poll','UsbNetFix-OnConnect')) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if ($t) {
            $i = $t | Get-ScheduledTaskInfo
            Line ('  ' + $n + ': ' + $t.State + '  last=' + $i.LastRunTime + '  result=0x' + ('{0:X}' -f $i.LastTaskResult))
        } else { Line ('  ' + $n + ': not registered') }
    }
    Line ''

    Line '-- log tail --------------------------------------------------------'
    $lf = [string](Get-Cfg $script:Cfg 'LogFile' '')
    if (-not $lf) { $lf = Join-Path (NP-LogDir) 'usbnet-fix.log' }
    if (Test-Path $lf) { Get-Content $lf -Tail 12 -Encoding UTF8 | ForEach-Object { Line ('  ' + $_) } }
    else { Line ('  (no log yet: ' + $lf + ')') }
    Line ''
}

function Show-Names {
    Head 'Which phone gets which name'
    $state = NP-GetState
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Remote NDIS|RNDIS|Android|USB.*Ethernet' })
    if ($adapters.Count -eq 0) { Line '  no phone/RNDIS adapter attached right now'; Line ''; return }
    foreach ($a in $adapters) {
        $ii  = NP-GetInstanceIdForAdapter -Adapter $a
        $par = NP-GetParentInstanceId -InstanceId $ii
        $ids = NP-GetUsbIds -InstanceId $par
        if (-not $ids.Serial) { $ids = NP-GetUsbIds -InstanceId $ii }
        $loc   = NP-GetUsbLocation -InstanceId $ii
        $model = NP-GetUsbDeviceModel -InstanceId $ii
        $res   = NP-ResolveDeviceName -Cfg $script:Cfg -InstanceId $ii -State $state
        Line ('  adapter    : ' + $a.Name + ' (ifIndex ' + $a.ifIndex + ')')
        Line ('  usb        : ' + $ii)
        Line ('  location   : ' + $loc + '   <- ties the interfaces of one device together')
        Line ('  vendor     : ' + $ids.Vid + '   serial: ' + $(if ($ids.Serial) { $ids.Serial } else { '(not exposed)' }))
        Line ('  usb model  : ' + $(if ($model) { "'" + $model + "'" } else { '(phone never reported a model - connect it in MTP/file-transfer mode once)' }))
        Line ('  NAME       : ' + $res.Name)
        Line ('  decided by : ' + $res.Source)
        Line ('  gateway MAC: ' + (NP-MacPretty (NP-GetGatewayMac -InterfaceIndex $a.ifIndex)))
        Line ''
    }
}

function Show-Monitor {
    Head 'Live USB tethering state'
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'Remote NDIS|RNDIS|Android|USB.*Ethernet' })
    if ($adapters.Count -eq 0) { Line '  no phone attached / tethering off'; Line ''; return }
    foreach ($a in $adapters) {
        Line ('  adapter : ' + $a.Name + '   status=' + $a.Status + '   mac=' + $a.MacAddress)
        $live = @(Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue)
        foreach ($l in $live) { Line ('  network : ' + $l.Name + '   category=' + $l.NetworkCategory + '   IPv4=' + $l.IPv4Connectivity) }
        $gw = NP-GetGatewayMac -InterfaceIndex $a.ifIndex
        Line ('  gateway : ' + (NP-MacPretty $gw) + '   (a new random value each session - this is why Windows invents new networks)')
    }
    Line ''
    Line '-- USB modes of the attached device(s) -----------------------------'
    $modeMap = @{
        'WUDFWpdMtp' = 'file transfer (MTP)'
        'USBSTOR'    = 'file transfer (storage)'
        'usbrndis6'  = 'USB tethering (RNDIS)'
    }
    foreach ($k in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match 'VID_' })) {
        foreach ($i in (Get-ChildItem $k.PSPath -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue
            $d = [string]$p.DeviceDesc
            if (-not $d -or $d -match '^@') { continue }
            $svc = [string]$p.Service
            $mode = $svc
            if ($modeMap.ContainsKey($svc)) { $mode = $modeMap[$svc] }
            $flag = ''
            if ($p.ConfigFlags -band 1) { $flag = '  (not currently present)' }
            Line ('  ' + $k.PSChildName + '  ->  ' + $d + '   [' + $mode + ']' + $flag)
        }
    }
    Line ''
    Line '  Note: Android exposes tethering OR file transfer in one USB configuration,'
    Line '        so the cable cannot do both at the same time.'
    Line ''
}

function Invoke-Apply {
    Head 'Applying the fix now'
    $fix = Join-Path $root 'usbnet-fix.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fix -Once
    Line ''
}

function Invoke-Install {
    Head 'Install / repair'
    $rc = Invoke-Elevated -Script (Join-Path $root 'tasks.ps1') -Arguments @('-SourceDir', $root)
    Line ''
    Line ('  installer exit code: ' + $rc)
    return $rc
}

function Invoke-Uninstall {
    Head 'Uninstall'
    $uargs = @()
    if ($Command -eq 'uninstall-all') { $uargs += '-Purge' }
    $rc = Invoke-Elevated -Script (Join-Path $root 'uninstall.ps1') -Arguments $uargs
    Line ''
    Line ('  uninstaller exit code: ' + $rc)
    return $rc
}

function Invoke-Diagnose {
    Head 'Diagnostic snapshot'
    Invoke-Elevated -Script (Join-Path $root 'diag-watcher.ps1') -Arguments @('-OutDir', (NP-LogDir))
    $last = Get-ChildItem (NP-LogDir) -Filter 'diag-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($last) {
        Line ('  newest report: ' + $last.FullName)
        Line ''
        Get-Content $last.FullName -Encoding UTF8 | Select-Object -First 40 | ForEach-Object { Line ('  ' + $_) }
    }
    Line ''
}

function Invoke-Upgrade {
    param([string]$From)
    Head ('Upgrade from ' + $From)
    if (-not $From -or -not (Test-Path $From)) { Line '  usage: UsbNetFix.ps1 upgrade <path-to-new-release>'; Line ''; return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bk = Join-Path $root ('backup\app-' + $stamp)
    New-Item -ItemType Directory -Force -Path $bk | Out-Null
    foreach ($sub in @('*.ps1','*.cmd','config.json','README.md')) {
        Get-ChildItem (Join-Path $root $sub) -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName $bk -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Line ('  current version copied to ' + $bk)
    # config.json is never overwritten by an upgrade
    foreach ($sub in @('*.ps1','*.cmd','README.md')) {
        Get-ChildItem (Join-Path $From $sub) -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item $_.FullName $root -Force -ErrorAction SilentlyContinue
            Line ('  updated ' + $_.Name)
        }
    }
    if (Test-Path (Join-Path $From 'config.new.json')) {
        Copy-Item (Join-Path $From 'config.new.json') (Join-Path $root 'config.new.json') -Force
        Line '  a new config.new.json was placed next to your config.json (compare, then merge)'
    }
    Line ''
    Invoke-Elevated -Script (Join-Path $root 'tasks.ps1') -Arguments @('-SourceDir', $root)
    Line ''
}

function Show-Menu {
    param([switch]$FirstRun)
    if ($FirstRun) {
        Head 'UsbNetFix - USB tethering network name fixer'
        Line (' app: ' + $root)
        Line ''
    }
    Line '  1  status      state report'
    Line '  2  names       which phone gets which name, and why'
    Line '  3  monitor     live tethering state + USB modes'
    Line '  4  apply       apply the fix right now'
    Line '  5  install     deploy + register the scheduled task (needs admin)'
    Line '  6  diagnose    write a diagnostic snapshot (needs admin)'
    Line '  7  edit config open config.json in Notepad'
    Line '  8  open logs   open the log folder'
    Line '  9  uninstall   remove the scheduled task'
    Line '  0  exit'
    Line ''
    $c = Read-Host ' choose'
    switch ($c) {
        '1' { Show-Status }
        '2' { Show-Names }
        '3' { Show-Monitor }
        '4' { Invoke-Apply }
        '5' { $null = Invoke-Install }
        '6' { Invoke-Diagnose }
        '7' { Start-Process notepad.exe $script:CfgPath }
        '8' { $p = NP-LogDir; if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }; Start-Process explorer.exe $p }
        '9' { $null = Invoke-Uninstall }
        '0' { return }
        default { Line ' unknown choice' }
    }
    Line ''
    Read-Host ' press Enter to go back to the menu' | Out-Null
    Show-Menu
}

switch ($Command.ToLower()) {
    'status'        { Show-Status; exit 0 }
    'names'         { Show-Names; exit 0 }
    'monitor'       { Show-Monitor; exit 0 }
    'apply'         { Invoke-Apply; exit 0 }
    'install'       { exit (Invoke-Install) }
    'uninstall'     { exit (Invoke-Uninstall) }
    'uninstall-all' { exit (Invoke-Uninstall) }
    'diagnose'      { Invoke-Diagnose; exit 0 }
    'upgrade'       { Invoke-Upgrade -From $Arg2; exit 0 }
    default         { Show-Menu -FirstRun; exit 0 }
}
