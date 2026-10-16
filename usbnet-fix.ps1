#requires -Version 5.1
<#
  usbnet-fix.ps1 -- keeps USB-tethering network profiles named after the phone
  ===================================================================================
  Part of UsbNetFix (see README.md).  One-shot by default: the scheduled task runs it
  every minute and on every Windows "network profile" event; it evaluates the current
  state, fixes the name/category and exits.  -Loop keeps it resident instead.

  WHAT IT DOES, PER PHONE
    Windows fingerprints a network by the default-gateway MAC.  Android re-randomizes
    the RNDIS MAC on every tethering session, so Windows keeps inventing new networks
    ("Network", "Network 2", "Network 3", ...).  This script:
      1. finds the RNDIS/USB-tethering adapter
      2. confirms the session's gateway MAC (ARP) - never guesses
      3. works out WHICH phone it is: USB vendor id + USB serial number, plus the
         marketing name Android reports (e.g. "Galaxy S24"), read from the USB
         enumeration tree
      4. picks the profile name: config deviceRules -> name learned earlier -> the
         phone's own model name -> DefaultName   (never "Network N")
      5. renames the fresh profile, sets the network category, and removes the phone's
         own leftovers from previous sessions so the list never grows

  USAGE
    (no switch)   one-shot poll  (what the scheduled tasks use)
    -Once         same, but skips the settle delay (manual "apply now")
    -DryRun       print what would change, change nothing
    -MergeOnly    only clean up leftovers of already-known phones
    -Loop         stay resident and poll
    -ConfigPath   use a different config.json

  ASCII only (Windows PowerShell 5.1 decodes BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [switch]$Loop,
    [switch]$Once,
    [switch]$MergeOnly,
    [switch]$DryRun,
    [string]$ConfigPath,
    [int]$PollSeconds = 0,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'netprof-lib.ps1')

# --------------------------------------------------------------------------- config
function Get-Cfg {
    param($Obj, [string]$Name, $Default)
    if ($null -eq $Obj) { return $Default }
    $p = $Obj.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    # an empty/blank string means "not configured" - otherwise a blank LogFile would
    # switch logging off silently (that bug cost an hour of debugging)
    if ($p.Value -is [string] -and -not $p.Value.Trim()) { return $Default }
    return $p.Value
}

function Get-Defaults {
    [pscustomobject]@{
        DeviceRules            = @()
        AutoNameFromModel      = $true
        NamePrefix             = ''
        DefaultName            = 'USB Tethering'
        Category               = 'Private'
        PollSeconds            = 3
        SettleSeconds          = 8
        ProfileWaitSeconds     = 30
        MergeDuplicateProfiles = $true
        ForgetLegacyProfiles   = $true
        VendorIds              = @('2D95','18D1','2717','22D9','04E8','12D1','0BB4','1004','05C6','2A70','0E8D','0FCE','2916','19D2')
        DescriptionPatterns    = @('Remote NDIS','RNDIS','Android','iQOO','vivo','USB.*Ethernet')
        LogFile                = (Join-Path (NP-ToolDir) 'log\usbnet-fix.log')
        LogMaxKB               = 768
        Verbose                = $false
    }
}

function Load-Config {
    param([string]$Path)
    $cfg = Get-Defaults
    if ($Path -and (Test-Path $Path)) {
        try {
            $j = (Get-Content -Path $Path -Raw -Encoding UTF8) | ConvertFrom-Json
            foreach ($p in $cfg.PSObject.Properties) {
                $v = Get-Cfg $j $p.Name $null
                if ($null -ne $v) { $cfg.$($p.Name) = $v }
            }
        } catch { Write-Host ('[WARN] bad config.json (' + $_.Exception.Message + '); using defaults') }
    }
    return $cfg
}

if (-not $ConfigPath) {
    foreach ($cand in @((Join-Path $here 'config.json'),
                        (Join-Path (NP-ToolDir) 'config.json'))) {
        if (Test-Path $cand) { $ConfigPath = $cand; break }
    }
}
$script:Cfg     = Load-Config -Path $ConfigPath
$script:LogFile = [string](Get-Cfg $script:Cfg 'LogFile' (Join-Path (NP-ToolDir) 'log\usbnet-fix.log'))
$script:DebugOn = [bool](Get-Cfg $script:Cfg 'Verbose' $false)
if ($PollSeconds -le 0) { $PollSeconds = [int](Get-Cfg $script:Cfg 'PollSeconds' 3) }
if ($PollSeconds -lt 1) { $PollSeconds = 3 }

$script:LogWriteErrorShown = $false
$script:LogFallback = Join-Path $env:ProgramData 'UsbNetFix\log\usbnet-fix.log'
$script:LogTargetNote = ''
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not $Quiet) { Write-Host $line }

    $targets = @()
    if ($script:LogFile) { $targets += $script:LogFile }
    if ($script:LogFallback -and ($script:LogFallback -ne $script:LogFile)) { $targets += $script:LogFallback }

    foreach ($target in $targets) {
        try {
            $dir = Split-Path -Parent $target
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::AppendAllText($target, ($line + [Environment]::NewLine), $enc)
            if (-not $script:LogTargetNote) {
                $script:LogTargetNote = $target
                if ($target -ne $script:LogFile -and -not $Quiet) {
                    Write-Host ('[WARN] log fallback active: "' + $script:LogFile + '" is not writable, using "' + $target + '"')
                }
            }
            return
        } catch { }
    }
    if (-not $script:LogWriteErrorShown) {
        $script:LogWriteErrorShown = $true
        if (-not $Quiet) { Write-Host ('[WARN] cannot write any log file (tried: ' + ($targets -join ', ') + ')') }
    }
}
function Write-DebugLog { param([string]$Message) if ($script:DebugOn) { Write-Log -Message $Message -Level 'DEBUG' } }
function Rotate-Log {
    <#  keep the log bounded.  Called on every run, but the directory scan only happens
        after an actual rotation, so the steady-state cost is zero.  #>
    try {
        $max = [int](Get-Cfg $script:Cfg 'LogMaxKB' 768) * 1024
        if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt $max)) {
            $bak = $script:LogFile + '.1'
            if (Test-Path $bak) { Remove-Item $bak -Force -ErrorAction SilentlyContinue }
            Move-Item $script:LogFile $bak -Force -ErrorAction SilentlyContinue
            # prune diagnostic snapshots (bounds log\ growth over months)
            $dir = Split-Path -Parent $script:LogFile
            $keepFiles = [int](Get-Cfg $script:Cfg 'LogKeepDiagFiles' 20)
            $keepDays = [int](Get-Cfg $script:Cfg 'LogKeepDiagDays' 30)
            $diag = @(Get-ChildItem $dir -Filter 'diag-*.txt' -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending)
            $cut = (Get-Date).AddDays(-$keepDays)
            for ($i = 0; $i -lt $diag.Count; $i++) {
                if ($diag[$i].LastWriteTime -lt $cut -or $i -ge $keepFiles) {
                    Remove-Item $diag[$i].FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch { }
}

# --------------------------------------------------------------------------- detection
function Test-IsPhoneAdapter {
    param($Adapter)
    $desc = [string]$Adapter.InterfaceDescription
    $name = [string]$Adapter.Name
    if ($desc -match 'Wi-Fi Direct|Hyper-V|TAP-Windows|Loopback|Virtual|Kernel Debug|WAN Miniport') { return $false }
    if ($name -match 'Wi-Fi Direct|Hyper-V|TAP-Windows|Loopback') { return $false }

    $vid = ''
    if ([string]$Adapter.DeviceID -match 'VID_([0-9A-Fa-f]{4})') { $vid = $Matches[1].ToUpper() }
    $vendors = @(Get-Cfg $script:Cfg 'VendorIds' @('2D95')) | ForEach-Object { ([string]$_).ToUpper() }
    if ($vid -and ($vendors -contains $vid)) { return $true }

    foreach ($pat in @(Get-Cfg $script:Cfg 'DescriptionPatterns' @('Remote NDIS'))) {
        if ($desc -match $pat) { return $true }
    }
    return $false
}
function Get-PhoneAdapters {
    try { $all = Get-NetAdapter -IncludeHidden -ErrorAction Stop } catch { return @() }
    return @($all | Where-Object { Test-IsPhoneAdapter $_ })
}
function Get-LiveProfiles {
    param([int]$InterfaceIndex)
    try { return @(Get-NetConnectionProfile -InterfaceIndex $InterfaceIndex -ErrorAction Stop) } catch { return @() }
}
function Find-ProfileGuidByName {
    param([string]$Name, $AllProfiles)
    $c = @($AllProfiles | Where-Object { $_.Name -eq $Name })
    if ($c.Count -eq 0) { return '' }
    if ($c.Count -eq 1) { return $c[0].Guid }
    $best = $c | Sort-Object { if ($_.LastConnected) { $_.LastConnected } else { [datetime]::MinValue } } -Descending | Select-Object -First 1
    return $best.Guid
}

# --------------------------------------------------------------------------- core
function Invoke-PhoneFix {
    param([switch]$PlanOnly, [switch]$MergeOnly)

    if (-not (NP-CanWrite)) {
        Write-Log 'no access to the saved-network database - administrator rights required (the scheduled task runs as SYSTEM; this only affects manual runs)' 'WARN'
        return 0
    }

    $changes = 0
    $touchedNames = @()
    $onlineGuids = @()      # profiles that are connected right now - never delete these

    if (-not $MergeOnly) {
        $adapters = Get-PhoneAdapters
        if ($adapters.Count -eq 0) { Write-DebugLog 'no phone/RNDIS adapter attached'; return 0 }

        foreach ($a in $adapters) {
            $live = Get-LiveProfiles -InterfaceIndex $a.ifIndex
            if ($live.Count -eq 0) { Write-DebugLog ("adapter '" + $a.Name + "' has no network profile yet"); continue }

            # confirm the session fingerprint
            $gw = NP-GetGatewayMac -InterfaceIndex $a.ifIndex
            $adapterMac = NP-NormalizeMac $a.MacAddress
            $note = ''
            if ($gw) { $note = 'gateway MAC from ARP' }
            elseif ($adapterMac) { $gw = $adapterMac; $note = 'ARP empty, using adapter MAC' }
            if (-not $gw) {
                Write-Log ("phone adapter '" + $a.Name + "' is up but its gateway MAC is unknown yet; will retry") 'WARN'
                continue
            }
            Write-DebugLog ('session fingerprint ' + (NP-MacPretty $gw) + ' (' + $note + ')')

            $all = NP-GetProfiles
            $state = NP-GetState
            $knownNames = @(NP-GetDeviceNames)
            $cat = [string](Get-Cfg $script:Cfg 'Category' 'Private')
            $wantCat = -1
            if ($cat -eq 'Private') { $wantCat = 1 } elseif ($cat -eq 'Public') { $wantCat = 0 }
            $resolved = $false
            $res = $null

            foreach ($lp in $live) {
                $name = [string]$lp.Name
                $guid = Find-ProfileGuidByName -Name $name -AllProfiles $all
                if (-not $guid) { Write-Log ("cannot map live network '" + $name + "' to a saved profile") 'WARN'; continue }
                $onlineGuids += $guid

                # ---------------------------------------------------------------- fast path
                # The everyday case is a poll in the middle of an unchanged tethering
                # session: fingerprint already confirmed and the name already right.  Then
                # the whole USB device identification (PnP + registry walk) is pointless -
                # it would only re-derive the name we already have in state.json.
                if (-not $resolved -and ($state.PhoneGatewayMacs -contains $gw) -and ($knownNames -contains $name)) {
                    $others = @($knownNames | Where-Object { $_ -and $_ -ne $name })
                    if ($others -notcontains $name) {
                        Write-DebugLog ('fast path: session ' + (NP-MacPretty $gw) + " already named '" + $name + "'")
                        $touchedNames += $name
                        if ($wantCat -ge 0 -and [int]$lp.NetworkCategory -ne $wantCat) {
                            $p2 = $all | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
                            if (NP-SetProfileCategory -Guid $guid -Category $wantCat -PlanOnly:$PlanOnly) {
                                Write-Log ('category -> ' + $cat + " on '" + $name + "'") 'FIX'
                                $changes++
                            }
                        }
                        continue
                    }
                }

                # ----------------------------------------------------------- full identify
                if (-not $resolved) {
                    $instanceId = NP-GetInstanceIdForAdapter -Adapter $a
                    if (-not $instanceId) { $instanceId = [string]$a.DeviceID }
                    $parentId = NP-GetParentInstanceId -InstanceId $instanceId
                    $ids = NP-GetUsbIds -InstanceId $parentId
                    if (-not $ids.Serial) { $ids = NP-GetUsbIds -InstanceId $instanceId }
                    $loc = NP-GetUsbLocation -InstanceId $instanceId
                    Write-DebugLog ('usb instance: ' + $instanceId + '  parent: ' + $parentId + '  location: ' + $loc + '  serial: ' + $ids.Serial)

                    $res = NP-ResolveDeviceName -Cfg $script:Cfg -InstanceId $instanceId -State $state
                    if ($res.Source -eq 'default' -and -not $res.Model) {
                        # no rule matched and the model is unknown: try the parent form as well
                        $alt = NP-ResolveDeviceName -Cfg $script:Cfg -InstanceId $parentId -State $state
                        if ($alt.Model -or $alt.Source -ne 'default') { $res = $alt }
                    }
                    $wantName = $res.Name
                    if (-not $wantName) { $wantName = 'USB Tethering' }

                    # keep names unique across phones (never let two devices share a name,
                    # otherwise Windows starts appending " 2" again)
                    $others = @($knownNames | Where-Object { $_ -and $_ -ne $res.Name })
                    $base = $wantName
                    $suffix = 2
                    while ($others -contains $wantName) { $wantName = "$base $suffix"; $suffix++ }

                    Write-Log ('device: model=' + $(if ($res.Model) { "'" + $res.Model + "'" } else { 'unknown' }) +
                               ' id=' + $res.DeviceId + ' -> name "' + $wantName + '" (' + $res.Source + ')')
                    $resolved = $true
                }

                $prof = $all | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
                if (NP-SetProfileName -Guid $guid -NewName $wantName -PlanOnly:$PlanOnly) {
                    Write-Log ("rename '" + $prof.Name + "' -> '" + $wantName + "'  [" + (NP-MacPretty $gw) + ']') 'FIX'
                    $changes++
                }
                if ($wantCat -ge 0) {
                    if (NP-SetProfileCategory -Guid $guid -Category $wantCat -PlanOnly:$PlanOnly) {
                        Write-Log ('category -> ' + $cat + " on '" + $wantName + "'") 'FIX'
                        $changes++
                    }
                }
                $touchedNames += $wantName
            }

            if (-not $PlanOnly -and $resolved -and $res) {
                if (NP-RecordPhoneSession -DeviceId $res.DeviceId -Name $wantName -Model $res.Model -GatewayMac $gw) {
                    Write-DebugLog ('state saved for ' + $res.DeviceId)
                }
            }
        }
    }

    # --- leftovers: every profile whose gateway MAC was confirmed to be a phone AND whose
    #     name equals the name of a phone that is NOT the one currently online -----------
    if ([bool](Get-Cfg $script:Cfg 'MergeDuplicateProfiles' $true)) {
        if ($onlineGuids.Count -eq 0) {
            # Hard safety interlock.  We only got here without identifying a live phone
            # profile (-MergeOnly, or the adapter had no profile yet), so we cannot tell
            # which entry is in use right now.  Deleting in that state is exactly how one
            # could remove a profile that is currently connected - so we do not.
            Write-DebugLog 'merge skipped: no online profile was identified, cannot tell which entry is in use'
        } else {
        $state = NP-GetState
        if ($state.PhoneGatewayMacs.Count -gt 0) {
            $all = NP-GetProfiles
            $phone = @($all | Where-Object { $state.PhoneGatewayMacs -contains $_.GatewayMac })
            if ($phone.Count -gt 0) {
                # name -> profiles, so leftovers of the same phone can be folded
                $byName = @{}
                foreach ($p in $phone) {
                    if (-not $p.Name) { continue }
                    if (-not $byName.ContainsKey($p.Name)) { $byName[$p.Name] = @() }
                    $byName[$p.Name] += $p
                }
                foreach ($n in $byName.Keys) {
                    $group = @($byName[$n] | Sort-Object { if ($_.Created) { $_.Created } else { [datetime]::MinValue } } -Descending)
                    if ($group.Count -le 1) { continue }
                    $keep = $group[0]
                    $isCurrentPhone = ($touchedNames -contains $n)
                    foreach ($p in $group) {
                        if ($p.Guid -eq $keep.Guid) { continue }
                        # never delete the profile that is online right now, whatever else
                        # happens - that is a hard safety rule
                        if ($onlineGuids -contains $p.Guid) { Write-DebugLog ('keeping online profile ' + $p.Name); continue }
                        if ($isCurrentPhone -or [bool](Get-Cfg $script:Cfg 'ForgetLegacyProfiles' $true)) {
                            if (NP-RemoveProfile -Guid $p.Guid -PlanOnly:$PlanOnly) {
                                Write-Log ("forget leftover profile '" + $p.Name + "' (" + $p.Guid + ')') 'FIX'
                                $changes++
                            }
                        }
                    }
                }
            }
        }
        }
    }
    return $changes
}

# --------------------------------------------------------------------------- runner guard
$script:Mutex = $null
function Test-SingleInstance {
    <#  short-lived runs must not overlap.  "Local\" works for elevated user processes,
        where "Global\" is denied (verified: Access denied).  #>
    try {
        $createdNew = $false
        $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\UsbNetFixRunner', ([ref]$createdNew))
        if (-not $createdNew) {
            Write-Log ('another run is already in progress - this one exits (pid ' + $PID + ')')
            return $false
        }
        return $true
    } catch {
        Write-Log ('mutex unavailable (' + $_.Exception.Message + ') - continuing anyway') 'WARN'
        return $true
    }
}

# --------------------------------------------------------------------------- entry points
if (-not $Loop) {
    Rotate-Log
    if (-not (Test-SingleInstance)) { return }

    # Cheap pre-check BEFORE the settle wait.  There is no point in sleeping 8 seconds and
    # then discovering that no phone is attached: that is the state the machine is in for
    # most runs of the day, so the wait is skipped entirely when there is nothing to fix.
    $preAdapters = @()
    if (-not $MergeOnly) {
        $preAdapters = Get-PhoneAdapters
        if ($preAdapters.Count -eq 0) {
            Write-DebugLog 'no phone/RNDIS adapter attached - nothing to do (skipped settle wait)'
            return
        }
    }

    $delay = [int](Get-Cfg $script:Cfg 'SettleSeconds' 8)
    if ($Once) { $delay = 0 }
    Write-Log ('poll (DryRun=' + [bool]$DryRun + ' MergeOnly=' + [bool]$MergeOnly + ' delay=' + $delay + 's) config=' + $ConfigPath)
    if ($delay -gt 0) { Start-Sleep -Seconds $delay }

    # Second gate.  The adapter is there but Windows may not have assigned the network
    # profile yet (DHCP + NLA identification take a few seconds).  Rather than report
    # "0 changes" and hope another event arrives, wait for the profile - this is the one
    # race that really matters, because it is exactly the plug-in moment.
    if (-not $MergeOnly -and $preAdapters.Count -gt 0 -and -not $Once) {
        $waitSec = [int](Get-Cfg $script:Cfg 'ProfileWaitSeconds' 30)
        $deadline = (Get-Date).AddSeconds($waitSec)
        while ($true) {
            $ready = $false
            foreach ($pa in $preAdapters) {
                if (@(Get-LiveProfiles -InterfaceIndex $pa.ifIndex).Count -gt 0) { $ready = $true; break }
            }
            if ($ready) { break }
            if ((Get-Date) -ge $deadline) {
                Write-Log ('phone attached but Windows assigned no network profile within ' + $waitSec + 's - the next event or the daily run will pick it up') 'WARN'
                break
            }
            Start-Sleep -Seconds 3
        }
    }

    $n = Invoke-PhoneFix -PlanOnly:$DryRun -MergeOnly:$MergeOnly
    Write-Log ('finished, ' + $n + ' change(s)')
    return
}

$settle = [int](Get-Cfg $script:Cfg 'SettleSeconds' 8)
if (-not (Test-SingleInstance)) { return }
Write-Log ('resident watcher started (poll ' + $PollSeconds + 's) config=' + $ConfigPath)

$script:WasUp    = $false
$script:DoneKeys = @{}
try {
    while ($true) {
        try {
            Rotate-Log
            $adapters = Get-PhoneAdapters
            if ($adapters.Count -eq 0) {
                if ($script:WasUp) {
                    Write-Log 'phone adapter disconnected'
                    $script:WasUp = $false
                    $script:DoneKeys = @{}
                }
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            $a = $adapters | Sort-Object ifIndex | Select-Object -First 1
            $live = Get-LiveProfiles -InterfaceIndex $a.ifIndex
            if ($live.Count -gt 0) {
                if (-not $script:WasUp) {
                    Write-Log ("phone adapter up: '" + $a.Name + "' ifIndex=" + $a.ifIndex + " profile='" + [string]$live[0].Name + "'")
                    $script:WasUp = $true
                }
                Start-Sleep -Seconds $settle
                $n = Invoke-PhoneFix
                if ($n -gt 0) { Write-Log ('applied ' + $n + ' change(s)') }
            }
        } catch {
            Write-Log ('loop error: ' + $_.Exception.Message) 'ERROR'
        }
        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Write-Log ('watcher loop exited (pid ' + $PID + ')') 'WARN'
}
