#requires -Version 5.1
<#
  netprof-lib.ps1 -- shared layer of the USB tethering network-profile app (UsbNetFix)
  ===================================================================================
  Part of UsbNetFix.  Lives next to the other scripts; they dot-source it.

  AUTHORITATIVE STRUCTURE OF THE SAVED-NETWORK DATABASE (verified: Windows 11 22631)

    NetworkList\Profiles\{GUID}
        ProfileName       REG_SZ      displayed network name
        Description       REG_SZ
        Category          REG_DWORD   0 = Public, 1 = Private, 2 = Domain
        NameType          REG_DWORD   6 = wired/ethernet style, 71 = wireless
        DateCreated       REG_BINARY  16 bytes SYSTEMTIME (8 x little endian WORD)
        DateLastConnected REG_BINARY  16 bytes SYSTEMTIME
      -> there is NO signature value inside the profile key.

    NetworkList\Signatures\Unmanaged\<SIGNATURE>
        ProfileGuid       REG_SZ      -> points at Profiles\{GUID}
        DefaultGatewayMac REG_BINARY  6 bytes   <-- the network fingerprint
      -> the key name is the network signature; its last 64 hex chars are a private
         hash of the fingerprint, so signatures can never be pre-computed.

  HOW A PHONE IS IDENTIFIED (no guessing):
    1. the adapter is an RNDIS/USB-tethering device (PnP vendor id + description)
    2. during a live session the gateway MAC (ARP) of that adapter is recorded -
       this is what Windows used as the network fingerprint
    3. the phone MODEL is resolved from the USB device itself: while connected in
       MTP mode Android reports its marketing name and Windows keeps that record in the
       USB enumeration tree; the USB serial number of the shared parent device links the
       RNDIS adapter back to that record
    A profile is only ever touched when its gateway MAC was confirmed this way.

  ASCII only (Windows PowerShell 5.1 decodes BOM-less .ps1 as ANSI).
#>

$script:NLBase     = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList'
$script:NLProfiles = "$($script:NLBase)\Profiles"
$script:NLSigs     = @("$($script:NLBase)\Signatures\Unmanaged", "$($script:NLBase)\Signatures\Managed")

# --------------------------------------------------------------------------- paths
# Layout (self contained, everything under one folder - the repo root is fine):
#
#     <app folder>\
#         UsbNetFix.cmd          double-click entry
#         UsbNetFix.ps1          control panel / CLI
#         config.json            user settings   (never overwritten by an upgrade)
#         state.json             what the app learned (created at runtime)
#         README.md
#         netprof-lib.ps1        this file
#         usbnet-fix.ps1         the actual fixer (run by the scheduled task)
#         tasks.ps1              task registration ("install"/"repair")
#         uninstall.ps1
#         diag-watcher.ps1
#         log\                   run log + diagnostic snapshots (created at runtime)
#         backup\                registry backups + previous versions (created at runtime)
#
# A "lib\" subfolder is also supported: any script may live in <app>\lib\ and everything
# still resolves to the same app folder.
function NP-LibDir {
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    return $here
}
function NP-ToolDir {
    <#  app root = parent of lib\ when this file sits in a lib folder, else the folder
        this file lives in.  #>
    $lib = NP-LibDir
    if ($lib -and ((Split-Path -Leaf $lib) -ieq 'lib')) { return (Split-Path -Parent $lib) }
    return $lib
}
function NP-ConfigPath { return (Join-Path (NP-ToolDir) 'config.json') }
function NP-StatePath  { return (Join-Path (NP-ToolDir) 'state.json') }
function NP-LogDir     { return (Join-Path (NP-ToolDir) 'log') }
function NP-BackupDir  { return (Join-Path (NP-ToolDir) 'backup') }

# --------------------------------------------------------------------------- helpers
function NP-Hex {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [byte[]]) { return (($Value | ForEach-Object { $_.ToString('x2') }) -join '') }
    return ([string]$Value).ToLower()
}
function NP-MacPretty {
    param([string]$Mac)
    if (-not $Mac -or $Mac.Length -ne 12) { return $Mac }
    return (($Mac -split '(?<=\G..)(?=..)') -join '-').ToUpper()
}
function NP-NormalizeMac {
    param([string]$Mac)
    if (-not $Mac) { return '' }
    return ($Mac -replace '[^0-9a-fA-F]', '').ToLower()
}
function NP-ParseSystemTime {
    param($Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 16) { return $null }
    try {
        $y  = [BitConverter]::ToUInt16($Bytes, 0)
        $mo = [BitConverter]::ToUInt16($Bytes, 2)
        $d  = [BitConverter]::ToUInt16($Bytes, 6)
        $h  = [BitConverter]::ToUInt16($Bytes, 8)
        $mi = [BitConverter]::ToUInt16($Bytes, 10)
        $s  = [BitConverter]::ToUInt16($Bytes, 12)
        if ($y -lt 1601 -or $y -gt 9999 -or $mo -lt 1 -or $mo -gt 12 -or $d -lt 1 -or $d -gt 31) { return $null }
        return (Get-Date -Year $y -Month $mo -Day $d -Hour $h -Minute $mi -Second $s)
    } catch { return $null }
}

# --------------------------------------------------------------------------- profiles
function NP-CanWrite {
    try {
        $lm = [Microsoft.Win32.Registry]::LocalMachine
        $k = $lm.OpenSubKey($script:NLProfiles, $true)
        if ($k) { $k.Close(); return $true }
        return $false
    } catch { return $false }
}

function NP-GetProfiles {
    <#  every saved network profile joined with its signature/gateway MAC.
        Returns @() when this process has no access.  #>
    $lm = [Microsoft.Win32.Registry]::LocalMachine
    $sigByGuid = @{}
    foreach ($sub in $script:NLSigs) {
        $sk = $null
        try { $sk = $lm.OpenSubKey($sub) } catch { $sk = $null }
        if (-not $sk) { continue }
        foreach ($name in $sk.GetSubKeyNames()) {
            $s = $null
            try { $s = $sk.OpenSubKey($name) } catch { $s = $null }
            if (-not $s) { continue }
            $guid = [string]$s.GetValue('ProfileGuid')
            if ($guid) {
                $sigByGuid[$guid.ToUpper()] = [pscustomobject]@{
                    Signature  = $name
                    GatewayMac = (NP-NormalizeMac (NP-Hex $s.GetValue('DefaultGatewayMac')))
                }
            }
            $s.Close()
        }
        $sk.Close()
    }

    $out = @()
    $pk = $null
    try { $pk = $lm.OpenSubKey($script:NLProfiles) } catch { $pk = $null }
    if (-not $pk) { return $out }
    foreach ($guid in $pk.GetSubKeyNames()) {
        $k = $null
        try { $k = $pk.OpenSubKey($guid) } catch { $k = $null }
        if (-not $k) { continue }
        $sig = $null
        if ($sigByGuid.ContainsKey($guid.ToUpper())) { $sig = $sigByGuid[$guid.ToUpper()] }
        $out += [pscustomobject]@{
            Guid          = $guid
            Name          = [string]$k.GetValue('ProfileName')
            Description   = [string]$k.GetValue('Description')
            Category      = [int]$k.GetValue('Category', 0)
            Managed       = [int]$k.GetValue('Managed', 0)
            NameType      = [int]$k.GetValue('NameType', 0)
            Created       = (NP-ParseSystemTime $k.GetValue('DateCreated'))
            LastConnected = (NP-ParseSystemTime $k.GetValue('DateLastConnected'))
            Signature     = $(if ($sig) { $sig.Signature } else { '' })
            GatewayMac    = $(if ($sig) { $sig.GatewayMac } else { '' })
        }
        $k.Close()
    }
    $pk.Close()
    return $out
}

function NP-GetProfileByGuid {
    param([string]$Guid)
    return (NP-GetProfiles | Where-Object { $_.Guid -eq $Guid } | Select-Object -First 1)
}

function NP-SetProfileName {
    <#  Registry write is picked up by NLA and the Settings UI immediately
        (verified: no service restart needed).  #>
    param([string]$Guid, [string]$NewName, [switch]$PlanOnly)
    if (-not $Guid -or -not $NewName) { return $false }
    $lm = [Microsoft.Win32.Registry]::LocalMachine
    $k = $lm.OpenSubKey("$($script:NLProfiles)\$Guid", $true)
    if (-not $k) { return $false }
    try {
        if ([string]$k.GetValue('ProfileName') -eq $NewName) { return $false }
        if ($PlanOnly) { return $true }
        $k.SetValue('ProfileName', $NewName, [Microsoft.Win32.RegistryValueKind]::String)
        $k.SetValue('Description', $NewName, [Microsoft.Win32.RegistryValueKind]::String)
        return $true
    } finally { $k.Close() }
}

function NP-SetProfileCategory {
    param([string]$Guid, [int]$Category, [switch]$PlanOnly)
    $lm = [Microsoft.Win32.Registry]::LocalMachine
    $k = $lm.OpenSubKey("$($script:NLProfiles)\$Guid", $true)
    if (-not $k) { return $false }
    try {
        if ([int]$k.GetValue('Category', 0) -eq $Category) { return $false }
        if ($PlanOnly) { return $true }
        $k.SetValue('Category', $Category, [Microsoft.Win32.RegistryValueKind]::DWord)
        return $true
    } finally { $k.Close() }
}

function NP-RemoveProfile {
    <#  delete a saved network profile together with every signature that points at it.
        Never throws: a locked or partially removable profile must not abort a whole run
        (the caller counts changes and keeps going).  Returns $true only when the profile
        key is really gone afterwards.  #>
    param([string]$Guid, [switch]$PlanOnly)
    if (-not $Guid) { return $false }
    $lm = [Microsoft.Win32.Registry]::LocalMachine
    try {
        $pk = $lm.OpenSubKey($script:NLProfiles)
        if (-not $pk) { return $false }
        $exists = ($pk.GetSubKeyNames() -contains $Guid)
        $pk.Close()
        if (-not $exists) { return $false }
        if ($PlanOnly) { return $true }

        foreach ($sub in $script:NLSigs) {
            $sk = $null
            try { $sk = $lm.OpenSubKey($sub, $true) } catch { $sk = $null }
            if (-not $sk) { continue }
            foreach ($name in @($sk.GetSubKeyNames())) {
                $s = $sk.OpenSubKey($name)
                if ($s) {
                    $pg = [string]$s.GetValue('ProfileGuid')
                    $s.Close()
                    if ($pg -and $pg.ToUpper() -eq $Guid.ToUpper()) {
                        try { $sk.DeleteSubKeyTree($name, $false) } catch { }
                    }
                }
            }
            $sk.Close()
        }
        $pk = $lm.OpenSubKey($script:NLProfiles, $true)
        if ($pk) {
            try { $pk.DeleteSubKeyTree($Guid, $false) } finally { $pk.Close() }
        }
        # verify instead of assuming
        $chk = $lm.OpenSubKey($script:NLProfiles)
        if ($chk) {
            $gone = -not ($chk.GetSubKeyNames() -contains $Guid)
            $chk.Close()
            return $gone
        }
        return $false
    } catch {
        return $false
    }
}

function NP-ExportBackup {
    <#  reg.exe export of the whole saved-network database into $Dir.
        Never throws: returns the list of files it managed to write.  #>
    param([string]$Dir, [string]$Tag = 'networklist')
    $files = @()
    if (-not $Dir) { return $files }
    try { if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null } } catch { return $files }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    # reg.exe needs the full hive-qualified key name
    $pairs = @(
        @{ k = "HKLM\$($script:NLBase)\Profiles";   f = "Profiles-$Tag-$stamp.reg" },
        @{ k = "HKLM\$($script:NLBase)\Signatures"; f = "Signatures-$Tag-$stamp.reg" })
    foreach ($pair in $pairs) {
        $target = Join-Path $Dir $pair.f
        try {
            $null = & reg.exe export $pair.k $target /y 2>&1
            if (Test-Path $target) { $files += $target }
        } catch { }
    }
    return $files
}

# --------------------------------------------------------------------------- gateway
function NP-GetGatewayMac {
    param([int]$InterfaceIndex)
    $gwIp = ''
    try {
        $conf = Get-NetIPConfiguration -InterfaceIndex $InterfaceIndex -ErrorAction Stop
        if ($conf.IPv4DefaultGateway) { $gwIp = [string]$conf.IPv4DefaultGateway.NextHop }
    } catch { }
    if (-not $gwIp) { return '' }
    try {
        $n = Get-NetNeighbor -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
             Where-Object { $_.IPAddress -eq $gwIp } | Select-Object -First 1
        if ($n -and $n.LinkLayerAddress -and $n.LinkLayerAddress -ne '00-00-00-00-00-00') {
            return (NP-NormalizeMac $n.LinkLayerAddress)
        }
    } catch { }
    return ''
}

# --------------------------------------------------------------------------- device identity
function NP-GetUsbIds {
    <#  pull VID / PID / serial out of a PnP instance id.
        Instances look like:
            USB\VID_1234&PID_5678&MI_00\6&1A2B3C&0&0000   <- interface, last segment is a PORT PATH
            USB\VID_1234&PID_5678\SERIALNUMBER123         <- parent device, carries the serial
        The last segment of an interface instance is a PORT PATH that changes with the USB
        port and is shared by every phone plugged into that port, so it must never be used
        as device identity.  When given an interface instance this walks up to its parent
        (see NP-GetParentInstanceId) and takes the serial from there.  #>
    param([string]$InstanceId)
    $r = [pscustomobject]@{ Vid = ''; Pid = ''; Serial = '' }
    if (-not $InstanceId) { return $r }
    if ($InstanceId -match 'VID_([0-9A-Fa-f]{4})') { $r.Vid = $Matches[1].ToUpper() }
    if ($InstanceId -match 'PID_([0-9A-Fa-f]{4})') { $r.Pid = $Matches[1].ToUpper() }

    $parts = $InstanceId -split '\\'
    if ($parts.Count -lt 3) { return $r }
    $seg = $parts[2]
    # a port path ("6&1A2B3C&0&0000") is not a serial: resolve the real parent first
    if ($seg -match '^[0-9A-Fa-f]&\w+&\d+&\d+$' -or $seg -match '^MI_') {
        $parent = NP-GetParentInstanceId -InstanceId $InstanceId
        $pp = $parent -split '\\'
        if ($pp.Count -ge 3) { $seg = $pp[2] }
    }
    if ($seg -and $seg -notmatch '^[0-9A-Fa-f]&\w+&\d+&\d+$' -and $seg -notmatch '^MI_') {
        $r.Serial = $seg.ToUpper()
    }
    return $r
}

function NP-GetParentInstanceId {
    <#  The REAL parent of a USB interface, straight from the Windows device tree.
        This matters: several phones plugged into the same port share the same
        LocationInformation, so the port path cannot identify a device - only the parent
        device instance (which carries the USB serial number) can.

        Example: USB\VID_1234&PID_5678&MI_00\6&1A2B3C&0&0000
              -> USB\VID_1234&PID_5678\SERIALNUMBER123
        Falls back to syntactic reconstruction when the PnP API is unavailable.  #>
    param([string]$InstanceId)
    if (-not $InstanceId) { return '' }
    try {
        $parent = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
        if ($parent) { return ([string]$parent).ToUpper() }
    } catch { }
    $parts = $InstanceId -split '\\'
    if ($parts.Count -lt 3) { return $InstanceId }
    $head = $parts[1] -replace '&MI_[0-9A-Fa-f]{2}', ''
    return ('USB\' + $head + '\' + $parts[2])
}

function NP-GetInstanceIdForAdapter {
    <#  Get-NetAdapter exposes a network *GUID*, not the USB instance path.
        The network class registry links the two:
            Control\Class\{4d36e972-...}\<nnnn>\NetCfgInstanceId = <GUID>
            Control\Class\{4d36e972-...}\<nnnn>\Ndi\DeviceInstanceId = USB\VID_...\serial
        Falls back to matching the PnP device by the adapter's interface description. #>
    param($Adapter)
    $guid = ''
    if ($Adapter.PSObject.Properties['InterfaceGuid'] -and $Adapter.InterfaceGuid) { $guid = [string]$Adapter.InterfaceGuid }
    $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    if ($guid) {
        foreach ($k in (Get-ChildItem $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $p) { continue }
            if ([string]$p.NetCfgInstanceId -ne $guid) { continue }
            $ndi = Get-ItemProperty (Join-Path $k.PSPath 'Ndi') -ErrorAction SilentlyContinue
            if ($ndi -and $ndi.DeviceInstanceId) { return ([string]$ndi.DeviceInstanceId).ToUpper() }
            foreach ($vid in (Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB' -ErrorAction SilentlyContinue)) {
                foreach ($inst in (Get-ChildItem $vid.PSPath -ErrorAction SilentlyContinue)) {
                    foreach ($iface in (Get-ChildItem $inst.PSPath -ErrorAction SilentlyContinue)) {
                        $ip = Get-ItemProperty $iface.PSPath -ErrorAction SilentlyContinue
                        if ($ip -and ([string]$ip.NetCfgInstanceId) -eq $guid) {
                            return (('USB\' + $vid.PSChildName + '\' + $inst.PSChildName + '\' + $iface.PSChildName)).ToUpper()
                        }
                    }
                }
            }
        }
    }
    # fallback: same description among present devices
    $desc = [string]$Adapter.InterfaceDescription
    $cand = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'USB\*' -and $_.FriendlyName -eq $desc })
    if ($cand.Count -eq 1) { return ([string]$cand[0].InstanceId).ToUpper() }
    return ''
}

function NP-GetUsbDeviceModel {
    <#  Resolve the marketing name of the device behind a USB interface.
        Android only reports its model name in MTP mode, and that record is a SIBLING
        interface of the RNDIS one.  The link is the USB serial number of the shared
        parent device:

            RNDIS interface -> parent USB\VID_1234&PID_5678\SERIALNUMBER123
            MTP   interface -> parent USB\VID_1234&PID_5679\SERIALNUMBER123  -> "Phone Model X"

        LocationInformation deliberately is NOT used as the primary key: two different
        phones plugged into the same USB port share it, so it would name one phone after
        the other.  It only serves as a weak last resort when the vendor exposes exactly
        one named device.  #>
    param([string]$InstanceId)
    $ids = NP-GetUsbIds -InstanceId $InstanceId
    if (-not $ids.Vid) { return '' }
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
    $records = @()
    try {
        foreach ($vidKey in (Get-ChildItem $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match ('VID_' + $ids.Vid) })) {
            foreach ($inst in (Get-ChildItem $vidKey.PSPath -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty $inst.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $p) { continue }
                $desc = [string]$p.DeviceDesc
                if (-not $desc) { continue }
                if ($desc -match '^@|^USB Composite Device$|Mass Storage|RNDIS|Remote NDIS|MTP|ADB|^USB ') { continue }
                if ($desc -notmatch '[A-Za-z]') { continue }
                $instId = 'USB\' + $vidKey.PSChildName + '\' + $inst.PSChildName
                $pIds = NP-GetUsbIds -InstanceId $instId
                $l = ''
                if ($p.PSObject.Properties['LocationInformation']) { $l = [string]$p.LocationInformation }
                $records += [pscustomobject]@{ Desc = $desc; Serial = $pIds.Serial; Location = $l; Instance = $instId }
            }
        }
    } catch { }
    if ($records.Count -eq 0) { return '' }

    # 1) exact USB serial match - the only reliable key when several phones share a port
    if ($ids.Serial) {
        $bySerial = @($records | Where-Object { $_.Serial -and $_.Serial -eq $ids.Serial })
        if ($bySerial.Count -ge 1) { return $bySerial[0].Desc }
    }
    # 2) no serial available: only trust the port when exactly ONE device there reports a
    #    model, otherwise we would risk naming this phone after a different one
    $loc = NP-GetUsbLocation -InstanceId $InstanceId
    if ($loc) {
        $byLoc = @($records | Where-Object { $_.Location -and $_.Location -eq $loc })
        if ($byLoc.Count -eq 1) { return $byLoc[0].Desc }
    }
    # 3) caller handed us an interface instance whose parent carries the serial: retry there
    $parent = NP-GetParentInstanceId -InstanceId $InstanceId
    if ($parent -and $parent -ne $InstanceId) {
        $pIds = NP-GetUsbIds -InstanceId $parent
        if ($pIds.Serial -and $pIds.Serial -ne $ids.Serial) {
            $bySerial2 = @($records | Where-Object { $_.Serial -and $_.Serial -eq $pIds.Serial })
            if ($bySerial2.Count -eq 1) { return $bySerial2[0].Desc }
        }
    }
    # 4) vendor exposes exactly one named device at all
    if ($records.Count -eq 1) { return $records[0].Desc }
    return ''
}

function NP-GetUsbLocation {
    <#  LocationInformation of a PnP device, e.g. "0000.0014.0000.003.000.000.000.000.000".
        Identical for every interface of one physical device - this is the key that ties an
        RNDIS interface to the MTP record that carries the phone's model name.
        Tries the given instance, then its syntactic parent (a composite parent's registry
        key name is not always the interface's own path segment).  #>
    param([string]$InstanceId)
    if (-not $InstanceId) { return '' }
    foreach ($id in @($InstanceId, (NP-GetParentInstanceId -InstanceId $InstanceId))) {
        if (-not $id) { continue }
        try {
            $p = Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $id) -ErrorAction Stop
            if ($p -and $p.PSObject.Properties['LocationInformation'] -and $p.LocationInformation) {
                return [string]$p.LocationInformation
            }
        } catch { }
    }
    return ''
}

function NP-NormalizeName {
    <#  keep a device name usable as a network profile name #>
    param([string]$Name)
    if (-not $Name) { return '' }
    $n = $Name.Trim()
    $n = $n -replace '[\r\n\t]', ' '
    $n = $n -replace '\s{2,}', ' '
    if ($n.Length -gt 60) { $n = $n.Substring(0, 60).Trim() }
    return $n
}

function NP-ResolveDeviceName {
    <#  decide the profile name for one phone:
          1. deviceRules in config.json  (match Vid / ModelLike / SerialLike)
          2. the name learned earlier for this same device
          3. the USB reported model name, optionally prefixed
          4. DefaultName
        Returns @{ Name = ...; Source = ...; Model = ...; DeviceId = ... }  #>
    param($Cfg, $InstanceId, $State)
    $ids   = NP-GetUsbIds $InstanceId
    $model = NP-NormalizeName (NP-GetUsbDeviceModel -InstanceId $InstanceId)
    $devId = if ($ids.Serial) { $ids.Vid + ':' + $ids.Serial } else { $ids.Vid + ':' + $ids.Pid }

    $rules = @()
    if ($Cfg -and $Cfg.PSObject.Properties['DeviceRules'] -and $Cfg.DeviceRules) { $rules = @($Cfg.DeviceRules) }
    foreach ($r in $rules) {
        $rv = ''
        $rm = ''
        $rs = ''
        if ($r.PSObject.Properties['Vid'])       { $rv = [string]$r.Vid }
        if ($r.PSObject.Properties['ModelLike']) { $rm = [string]$r.ModelLike }
        if ($r.PSObject.Properties['SerialLike']) { $rs = [string]$r.SerialLike }
        if ($rv -and $rv.ToUpper() -ne $ids.Vid) { continue }
        if ($rs -and ($ids.Serial -notmatch $rs)) { continue }
        if ($rm) {
            if (-not $model) { continue }
            if ($model -notmatch $rm) { continue }
        }
        if ($r.PSObject.Properties['Name'] -and $r.Name) {
            return [pscustomobject]@{ Name = (NP-NormalizeName ([string]$r.Name)); Source = 'config rule'; Model = $model; DeviceId = $devId }
        }
    }

    if ($State -and $State.Devices) {
        foreach ($d in $State.Devices) {
            if ($d.DeviceId -eq $devId -and $d.Name) {
                return [pscustomobject]@{ Name = (NP-NormalizeName ([string]$d.Name)); Source = 'learned earlier'; Model = $model; DeviceId = $devId }
            }
        }
    }

    $auto = $true
    if ($Cfg -and $Cfg.PSObject.Properties['AutoNameFromModel']) { $auto = [bool]$Cfg.AutoNameFromModel }
    if ($auto -and $model) {
        $prefix = ''
        if ($Cfg -and $Cfg.PSObject.Properties['NamePrefix'] -and $Cfg.NamePrefix) { $prefix = [string]$Cfg.NamePrefix }
        return [pscustomobject]@{ Name = (NP-NormalizeName ($prefix + $model)); Source = 'usb model'; Model = $model; DeviceId = $devId }
    }

    $def = 'USB Tethering'
    if ($Cfg -and $Cfg.PSObject.Properties['DefaultName'] -and $Cfg.DefaultName) { $def = [string]$Cfg.DefaultName }
    return [pscustomobject]@{ Name = (NP-NormalizeName $def); Source = 'default'; Model = $model; DeviceId = $devId }
}

# --------------------------------------------------------------------------- state
function NP-GetState {
    <#  state.json:
        {
          "Devices": [ { DeviceId, Name, Model, LastGatewayMac, LastSeen, Sessions } ],
          "PhoneGatewayMacs": [ ... ]        # every confirmed fingerprint (all phones)
          "GatewayMap": { "<mac>": "<DeviceId>" }
        }  #>
    $empty = [pscustomobject]@{ Devices = @(); PhoneGatewayMacs = @(); GatewayMap = @{} }
    $path = NP-StatePath
    if (-not (Test-Path $path)) { return $empty }
    try {
        $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $devices = @()
        if ($j.PSObject.Properties['Devices'] -and $j.Devices) { $devices = @($j.Devices) }
        $macs = @()
        if ($j.PSObject.Properties['PhoneGatewayMacs'] -and $j.PhoneGatewayMacs) { $macs = @($j.PhoneGatewayMacs) }
        $map = @{}
        if ($j.PSObject.Properties['GatewayMap'] -and $j.GatewayMap) {
            foreach ($p in $j.GatewayMap.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
        }
        $cleanMacs = @()
        foreach ($m in $macs) { $n = NP-NormalizeMac ([string]$m); if ($n) { $cleanMacs += $n } }
        return [pscustomobject]@{ Devices = $devices; PhoneGatewayMacs = $cleanMacs; GatewayMap = $map }
    } catch { return $empty }
}

function NP-SaveState {
    param($State)
    $path = NP-StatePath
    try {
        $obj = [pscustomobject]@{
            Devices           = @($State.Devices)
            PhoneGatewayMacs  = @($State.PhoneGatewayMacs)
            GatewayMap        = $State.GatewayMap
            Updated           = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        }
        ($obj | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding UTF8
        return $true
    } catch { return $false }
}

function NP-RecordPhoneSession {
    <#  remember: this device, this name, this gateway MAC.

        BOUNDED ON PURPOSE: Android hands out a fresh random gateway MAC on every tethering
        session, so an unbounded list would grow forever.  $MaxFingerprints keeps the most
        recent ones.  An evicted MAC only costs a re-learn if that exact MAC ever comes
        back, and the newest MAC of every device is always kept.  #>
    param(
        [string]$DeviceId,
        [string]$Name,
        [string]$Model,
        [string]$GatewayMac,
        [int]$MaxFingerprints = 64
    )
    $st = NP-GetState
    $mac = NP-NormalizeMac $GatewayMac
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # 1) update the device record
    $devices = @()
    $found = $false
    $keepMacs = @()
    foreach ($d in $st.Devices) {
        if ($d.DeviceId -eq $DeviceId) {
            $found = $true
            $lastMac = if ($mac) { $mac } else { [string]$d.LastGatewayMac }
            if ($lastMac) { $keepMacs += $lastMac }
            $devices += [pscustomobject]@{
                DeviceId = $DeviceId; Name = $Name; Model = $Model
                LastGatewayMac = $lastMac; LastSeen = $now
                Sessions = ([int]$d.Sessions + 1)
            }
        } else {
            if ($d.LastGatewayMac) { $keepMacs += [string]$d.LastGatewayMac }
            $devices += $d
        }
    }
    if (-not $found) {
        if ($mac) { $keepMacs += $mac }
        $devices += [pscustomobject]@{
            DeviceId = $DeviceId; Name = $Name; Model = $Model
            LastGatewayMac = $mac; LastSeen = $now; Sessions = 1
        }
    }

    # 2) fingerprint list: append, then trim oldest entries beyond the cap
    $macs = @($st.PhoneGatewayMacs)
    if ($mac -and ($macs -notcontains $mac)) { $macs += $mac }
    if ($macs.Count -gt $MaxFingerprints) {
        $tail = @($macs[($macs.Count - $MaxFingerprints)..($macs.Count - 1)])
        # never evict a MAC that a current device still uses
        $macs = @($keepMacs + $tail | Where-Object { $_ } | Select-Object -Unique)
    }

    # 3) gateway map: keep only entries that are still in the fingerprint list
    $map = @{}
    foreach ($k in $st.GatewayMap.Keys) {
        if (($macs -contains $k) -or ($mac -and $k -eq $mac)) { $map[$k] = $st.GatewayMap[$k] }
    }
    if ($mac -and $DeviceId) { $map[$mac] = $DeviceId }

    $st2 = [pscustomobject]@{ Devices = $devices; PhoneGatewayMacs = $macs; GatewayMap = $map }
    return (NP-SaveState $st2)
}

function NP-GetDeviceNames {
    <#  all names currently assigned to phones (used to keep them unique) #>
    $st = NP-GetState
    $names = @()
    foreach ($d in $st.Devices) { if ($d.Name) { $names += [string]$d.Name } }
    return $names
}
