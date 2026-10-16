#requires -Version 5.1
<#
  run-elevated.ps1 -- relaunch UsbNetFix.ps1 with administrator rights.
  ===========================================================================
  Called by UsbNetFix.cmd when the current console is not elevated.

  Why elevation is the default: the saved-network database under
  HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList is owned by
  SYSTEM and its ACL grants access only to BUILTIN\Administrators and the
  netprofm service account.  A standard user cannot even OPEN it for reading,
  so without elevation the control panel can only say "admin rights required".

  Arguments are validated against the control panel's known commands before they
  are passed to an elevated process.  Quoting a command string into another
  process is where argument injection happens, so anything unfamiliar is
  refused rather than forwarded.

  Exit codes:
      0   elevated run started/completed - the caller must not fall back
      1   elevation refused or failed, or the arguments were not recognised

  ASCII only (PowerShell 5.1 reads a BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $here 'UsbNetFix.ps1'
if (-not (Test-Path $target)) { exit 1 }

$known = @('status','names','monitor','apply','install','uninstall','uninstall-all','diagnose','upgrade','menu')
$pass = @()
if ($CommandArgs) {
    foreach ($a in $CommandArgs) {
        if ($null -eq $a) { continue }
        # "upgrade" takes a directory argument; allow a path for it, but nothing else
        if ($pass.Count -ge 1 -and $pass[0] -eq 'upgrade') {
            if ($a -match '^[A-Za-z]:\\' -or $a -match '^\\\\') { $pass += $a }
            continue
        }
        if ($known -contains $a.ToLower()) { $pass += $a.ToLower() }
        else { exit 1 }   # unknown argument: refuse instead of forwarding
    }
}

$argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $target + '"'))
if ($pass.Count -gt 0) { $argList += $pass }

try {
    $null = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -PassThru -Wait -ErrorAction Stop
    # The elevated process ran in its own window, so its exit code is not meaningful here.
    # Report success so the wrapper does not run everything a second time.
    exit 0
} catch {
    # User clicked "No" on the UAC prompt, or the account cannot elevate at all.
    exit 1
}
