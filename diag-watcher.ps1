#requires -Version 5.1
<#
  diag-watcher.ps1 -- read-only snapshot for the "Network N+1" problem.
  Writes a UTF-8 report into <ProgramData>\UsbNetFix\log and prints the path.
  ASCII only.
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'netprof-lib.ps1')

if (-not $OutDir) { $OutDir = Join-Path (NP-ToolDir) 'log' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = Join-Path $OutDir ('diag-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

$L = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $L.Add($s) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W ('### USB tethering diagnostic   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   IsAdmin=' + $isAdmin)
W ''

$state = NP-GetState
W '===== [1] learned phone fingerprints (state.json) ====='
if ($state.PhoneGatewayMacs.Count -eq 0) { W '  (none yet - plug in the phone and enable USB tethering once)' }
foreach ($m in $state.PhoneGatewayMacs) { W ('  ' + (NP-MacPretty $m)) }
W ''

W '===== [2] phone / RNDIS adapters present ====='
$phones = @()
try {
    $phones = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
        $_.InterfaceDescription -match 'Remote NDIS|RNDIS|Android|iQOO|vivo|USB.*Ethernet' })
} catch { }
if ($phones.Count -eq 0) { W '  (none)' }
foreach ($a in $phones) {
    W ('  ' + $a.Name + '  ifIndex=' + $a.ifIndex + '  status=' + $a.Status)
    W ('      desc = ' + $a.InterfaceDescription)
    W ('      mac  = ' + $a.MacAddress + '   instId = ' + $a.DeviceID)
    $gw = NP-GetGatewayMac -InterfaceIndex $a.ifIndex
    W ('      gateway MAC (from ARP) = ' + $(if ($gw) { NP-MacPretty $gw } else { '(unknown)' }))
    try {
        Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object { W ('      IPv4 = ' + $_.IPAddress + '/' + $_.PrefixLength) }
    } catch { }
    W ''
}

W '===== [3] live connection profiles ====='
try {
    foreach ($c in (Get-NetConnectionProfile -ErrorAction Stop)) {
        W ('  ' + $c.Name + '   cat=' + $c.NetworkCategory + '  ifIndex=' + $c.InterfaceIndex + '  alias=' + $c.InterfaceAlias)
    }
} catch { W ('  failed: ' + $_.Exception.Message) }
W ''

W '===== [4] saved network profiles ====='
W '  guid                                    name                 cat  phonelike  created            gateway MAC'
W '  ---------------------------------------------------------------------------------------------------------------'
$prof = @(NP-GetProfiles | Sort-Object { if ($_.Created) { $_.Created } else { [datetime]::MinValue } })
foreach ($p in $prof) {
    $confirmed = ($state.PhoneGatewayMacs -contains $p.GatewayMac)
    W ('  ' + $p.Guid + '  ' + $p.Name.PadRight(20) + ' ' + $p.Category + '    ' + $(if ($confirmed) { 'YES' } else { '-' }).PadRight(9) + '  ' + `
        $(if ($p.Created) { $p.Created.ToString('yyyy-MM-dd HH:mm') } else { '?' }).PadRight(17) + '  ' + (NP-MacPretty $p.GatewayMac))
}
W ('  TOTAL: ' + $prof.Count + '   confirmed phone profiles: ' + (@($prof | Where-Object { $state.PhoneGatewayMacs -contains $_.GatewayMac }).Count))
W ''

W '===== [5] scheduled tasks ====='
foreach ($n in @('UsbNetFix-Watcher','UsbNetFix-OnConnect')) {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($t) {
        $i = $t | Get-ScheduledTaskInfo
        W ('  ' + $n + ': state=' + $t.State + '  last=' + $i.LastRunTime + '  result=0x' + ('{0:X}' -f $i.LastTaskResult))
    } else { W ('  ' + $n + ': NOT REGISTERED') }
}
W ''

W '===== [6] watcher log (last 40 lines) ====='
$log = Join-Path (NP-ToolDir) 'log\usbnet-fix.log'
if (Test-Path $log) { Get-Content $log -Tail 40 -Encoding UTF8 | ForEach-Object { W ('  ' + $_) } }
else { W ('  (no log yet: ' + $log + ')') }

$L | Set-Content -Path $out -Encoding UTF8
Write-Host ('WROTE ' + $out)
