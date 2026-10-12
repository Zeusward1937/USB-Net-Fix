#requires -Version 5.1
<#
  diag-watcher.ps1 -- read-only snapshot for the "Network N+1" problem.
  Writes a UTF-8 report into <app>\log and prints the path.  Nothing else is touched.
  ASCII only.
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'netprof-lib.ps1')

if (-not $OutDir) { $OutDir = NP-LogDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = Join-Path $OutDir ('diag-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

$L = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $L.Add($s) }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W ('### UsbNetFix diagnostic   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '   IsAdmin=' + $isAdmin)
W ''

$state = NP-GetState
W '===== [1] learned phone fingerprints (state.json) ====='
if ($state.PhoneGatewayMacs.Count -eq 0) { W '  (none yet - plug in the phone and enable USB tethering once)' }
foreach ($m in $state.PhoneGatewayMacs) { W ('  ' + (NP-MacPretty $m)) }
W ''
W '===== [2] known phones ====='
foreach ($d in @($state.Devices)) {
    W ('  ' + $d.Name + '   model=' + $d.Model + '   id=' + $d.DeviceId + '   sessions=' + $d.Sessions + '   last=' + $d.LastSeen)
}
W ''

W '===== [3] phone / RNDIS adapters present ====='
$phones = @()
try {
    $phones = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
        $_.InterfaceDescription -match 'Remote NDIS|RNDIS|Android|USB.*Ethernet' })
} catch { }
if ($phones.Count -eq 0) { W '  (none)' }
foreach ($a in $phones) {
    W ('  ' + $a.Name + '  ifIndex=' + $a.ifIndex + '  status=' + $a.Status + '  mac=' + $a.MacAddress)
    W ('      desc = ' + $a.InterfaceDescription)
    $ii = NP-GetInstanceIdForAdapter -Adapter $a
    W ('      usb  = ' + $ii)
    W ('      loc  = ' + (NP-GetUsbLocation -InstanceId $ii))
    $ids = NP-GetUsbIds -InstanceId $ii
    W ('      vid/pid/serial = ' + $ids.Vid + '/' + $ids.Pid + '/' + $ids.Serial)
    W ('      usb model = ' + (NP-GetUsbDeviceModel -InstanceId $ii))
    W ('      gateway MAC (ARP) = ' + (NP-MacPretty (NP-GetGatewayMac -InterfaceIndex $a.ifIndex)))
    try {
        Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
            ForEach-Object { W ('      IPv4 = ' + $_.IPAddress + '/' + $_.PrefixLength) }
    } catch { }
    W ''
}

W '===== [4] live connection profiles ====='
try {
    foreach ($c in (Get-NetConnectionProfile -ErrorAction Stop)) {
        W ('  ' + $c.Name + '   cat=' + $c.NetworkCategory + '  ifIndex=' + $c.InterfaceIndex + '  alias=' + $c.InterfaceAlias)
    }
} catch { W ('  failed: ' + $_.Exception.Message) }
W ''

W '===== [5] saved network profiles ====='
if (NP-CanWrite) {
    W '  guid                                    name                 cat  caller    created            gateway MAC'
    W '  ---------------------------------------------------------------------------------------------------------------'
    $prof = @(NP-GetProfiles | Sort-Object { if ($_.Created) { $_.Created } else { [datetime]::MinValue } })
    foreach ($p in $prof) {
        $known = ($state.PhoneGatewayMacs -contains $p.GatewayMac)
        $nm = $p.Name; if ($nm.Length -gt 20) { $nm = $nm.Substring(0, 20) }
        $cr = '?'; if ($p.Created) { $cr = $p.Created.ToString('yyyy-MM-dd HH:mm') }
        W ('  ' + $p.Guid + '  ' + $nm.PadRight(20) + ' ' + $p.Category + '    ' + $(if ($known) { 'PHONE' } else { '-' }).PadRight(7) + '  ' + $cr.PadRight(17) + '  ' + (NP-MacPretty $p.GatewayMac))
    }
    W ('  TOTAL: ' + $prof.Count + '   confirmed phone profiles: ' + (@($prof | Where-Object { $state.PhoneGatewayMacs -contains $_.GatewayMac }).Count))
} else { W '  (needs administrator rights)' }
W ''

W '===== [6] scheduled task ====='
$t = Get-ScheduledTask -TaskName 'UsbNetFix-OnPhonePlug' -ErrorAction SilentlyContinue
if ($t) {
    $i = $t | Get-ScheduledTaskInfo
    W ('  state=' + $t.State + '  last=' + $i.LastRunTime + '  result=0x' + ('{0:X}' -f $i.LastTaskResult))
    W ('  action: ' + $t.Actions[0].Arguments)
    foreach ($tr in $t.Triggers) { W ('  trigger: ' + $tr.CimClass.CimClassName + ' enabled=' + $tr.Enabled) }
} else { W '  (not registered)' }
W ''

W '===== [7] log tail (30 lines) ====='
$lf = Join-Path (NP-LogDir) 'usbnet-fix.log'
if (Test-Path $lf) { Get-Content $lf -Tail 30 -Encoding UTF8 | ForEach-Object { W ('  ' + $_) } }
else { W ('  (no log yet: ' + $lf + ')') }

$L | Set-Content -Path $out -Encoding UTF8
Write-Host ('WROTE ' + $out)
