#requires -Version 5.1
<#
  verify-release.ps1 -- pre-publish / self check for this folder.
  ===========================================================================
  Seven checks, all read-only except for removing what its own tests create:

    1. every .ps1 file parses (catches typos introduced while editing)
    2. scripts are pure ASCII (PowerShell 5.1 reads a BOM-less .ps1 as ANSI)
    3. no machine/owner specific data is left in sources, docs or config
    4. no runtime data (state.json / log / backup) is present
    5. config.json is valid JSON
    6. the entry points really run
    7. final sweep of EVERY file, plus cleanup of test artifacts

  IMPORTANT: check 6 runs the tool, and running the tool writes a log. That log contains
  the attached phone's real model and USB serial number, so it must never be shipped:
    * the fixer test is pointed at a throw-away config in %TEMP%
    * check 7 rescans every file (not only scripts) and deletes what the tests created

  Nothing here needs administrator rights.
  ASCII only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$fail = 0
function Ok   { param([string]$m) Write-Host ('  [OK]   ' + $m) -ForegroundColor Green }
function Bad  { param([string]$m) Write-Host ('  [FAIL] ' + $m) -ForegroundColor Red; $script:fail++ }
function Warn { param([string]$m) Write-Host ('  [WARN] ' + $m) -ForegroundColor Yellow }
function Head { param([string]$m) Write-Host ''; Write-Host ('== ' + $m + ' ' + ('=' * [Math]::Max(0, 56 - $m.Length))) -ForegroundColor Cyan }

# markers seen on the machine this was developed on - a release must contain none of them.
# kept in one place so check 3 and check 7 use the same list.
$patterns = @(
    'C:\Users\',
    'DESKTOP-',
    '10CEAN', '10CF5E', '5059B8DC',
    'LatticeNimble', 'tjuwlan', 'Zeusward'
)
$selfName = Split-Path -Leaf $PSCommandPath

Write-Host ''
Write-Host 'UsbNetFix - verification' -ForegroundColor White
Write-Host ('folder: ' + $root)

# ------------------------------------------------------------------ 1. syntax
Head '1. PowerShell syntax'
$files = @(Get-ChildItem $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { Bad 'no .ps1 files found' }
foreach ($f in $files) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        Bad ($f.Name + ': ' + $errs.Count + ' parse error(s)')
        $errs | Select-Object -First 5 | ForEach-Object {
            Write-Host ('           line ' + $_.Extent.StartLineNumber + ': ' + $_.Message) -ForegroundColor Red
        }
    } else {
        Ok ($f.Name + ' parses cleanly')
    }
}

# ------------------------------------------------------------------ 2. encoding
Head '2. ASCII purity of scripts'
foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $nonAscii = 0
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0) {
        Warn ($f.Name + ' has ' + $nonAscii + ' non-ASCII byte(s) - PowerShell 5.1 may misparse it')
    } else {
        Ok ($f.Name + ' is pure ASCII')
    }
}

# ------------------------------------------------------------------ 3. personal data
Head '3. leftover personal / machine specific data'
$scanFiles = @(Get-ChildItem $root -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne $selfName -and $_.Extension -in @('.ps1','.json','.md','.cmd','.bat','.txt') })
$hits = 0
foreach ($f in $scanFiles) {
    foreach ($p in $patterns) {
        $m = @(Select-String -LiteralPath $f.FullName -Pattern $p -SimpleMatch -ErrorAction SilentlyContinue)
        if ($m.Count -gt 0) { $hits++; Bad ($p + ' found in ' + $f.Name + ' (line ' + $m[0].LineNumber + ')') }
    }
}
if ($hits -eq 0) { Ok ('no personal data patterns in ' + $scanFiles.Count + ' file(s)') }

# ------------------------------------------------------------------ 4. runtime data
Head '4. runtime data must not be shipped'
foreach ($item in @('state.json', 'config.new.json')) {
    if (Test-Path (Join-Path $root $item)) { Bad ($item + ' is present - it holds real device data, delete it') }
    else { Ok ($item + ' is absent') }
}
foreach ($dir in @('log', 'backup')) {
    if (Test-Path (Join-Path $root $dir)) {
        $n = @(Get-ChildItem (Join-Path $root $dir) -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) { Bad ($dir + '\ contains ' + $n + ' file(s) - logs/registry backups must not be shipped') }
        else { Ok ($dir + '\ is empty') }
    } else { Ok ($dir + '\ is absent') }
}
if (Test-Path (Join-Path $root '.gitignore')) {
    $gi = Get-Content (Join-Path $root '.gitignore') -Raw
    foreach ($need in @('state.json', 'log/', 'backup/')) {
        if ($gi -match [regex]::Escape($need)) { Ok ('.gitignore excludes ' + $need) }
        else { Warn ('.gitignore does not exclude ' + $need) }
    }
} else { Warn '.gitignore is missing' }

# ------------------------------------------------------------------ 5. json
Head '5. config.json'
$cfgPath = Join-Path $root 'config.json'
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Ok 'config.json is valid JSON'
        if ($cfg.PSObject.Properties['DeviceRules']) { Ok ('DeviceRules: ' + @($cfg.DeviceRules).Count + ' rule(s)') }
        if ($cfg.PSObject.Properties['DefaultName']) { Ok ('DefaultName: ' + $cfg.DefaultName) }
        if ($cfg.PSObject.Properties['VendorIds']) { Ok ('VendorIds: ' + @($cfg.VendorIds).Count + ' entries') }
    } catch { Bad ('config.json is not valid JSON: ' + $_.Exception.Message) }
} else { Bad 'config.json is missing' }

# ------------------------------------------------------------------ 6. entry points
Head '6. entry points (read-only probes)'
$probeDir = Join-Path $env:TEMP ('UsbNetFix-verify-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
$probeCfg = Join-Path $probeDir 'config.json'
try { Get-Content $cfgPath -Raw -Encoding UTF8 | Set-Content -Path $probeCfg -Encoding UTF8 } catch { }

# Running an entry point is not enough: a missing dependency makes it print an error and
# still "finish". A flat release once shipped with UsbNetFix.ps1 looking for lib\netprof-lib.ps1
# and every command failed while the exit code stayed quiet. So check BOTH the exit code
# and that the command actually produced its expected output.
function Test-EntryPoint {
    param([string]$Script, [string[]]$ScriptArgs, [string]$Expect)
    try {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @ScriptArgs 2>&1
        $text = (@($out) -join "`n")
        if ($LASTEXITCODE -ne 0) {
            Bad ((Split-Path $Script -Leaf) + ' ' + ($ScriptArgs -join ' ') + ' exited with ' + $LASTEXITCODE)
            @($out) | Select-Object -First 4 | ForEach-Object { Write-Host ('           ' + $_) -ForegroundColor Red }
            return
        }
        if ($text -match 'is not recognized as the name of a cmdlet|CommandNotFoundException|is not recognized as an internal') {
            Bad ((Split-Path $Script -Leaf) + ' ' + ($ScriptArgs -join ' ') + ' reported a missing dependency (layout problem)')
            @($out) | Select-Object -First 4 | ForEach-Object { Write-Host ('           ' + $_) -ForegroundColor Red }
            return
        }
        if ($Expect -and ($text -notmatch $Expect)) {
            Bad ((Split-Path $Script -Leaf) + ' ' + ($ScriptArgs -join ' ') + ' ran but produced no expected output (' + $Expect + ')')
            return
        }
        Ok ((Split-Path $Script -Leaf) + ' ' + ($ScriptArgs -join ' ') + ' produced real output')
    } catch { Bad ((Split-Path $Script -Leaf) + ' threw: ' + $_.Exception.Message) }
}

$entry = Join-Path $root 'UsbNetFix.ps1'
if (Test-Path $entry) {
    Test-EntryPoint -Script $entry -ScriptArgs @('names')   -Expect 'Which phone gets which name'
    Test-EntryPoint -Script $entry -ScriptArgs @('monitor') -Expect 'Live USB tethering state'
    Test-EntryPoint -Script $entry -ScriptArgs @('status')  -Expect 'UsbNetFix status'
} else { Bad 'UsbNetFix.ps1 not found - the control panel is missing' }

$fixer = Join-Path $root 'usbnet-fix.ps1'
if (Test-Path $fixer) {
    try {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $fixer -Once -DryRun -ConfigPath $probeCfg 2>&1
        $text = (@($out) -join "`n")
        if ($text -match 'is not recognized as the name of a cmdlet|CommandNotFoundException') {
            Bad 'usbnet-fix.ps1 reported a missing dependency (layout problem)'
            @($out) | Select-Object -First 4 | ForEach-Object { Write-Host ('           ' + $_) -ForegroundColor Red }
        } elseif ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1) {
            # -1 is normal here: without admin rights the fixer cannot touch HKLM
            if ($text -match '\[INFO\]|\[WARN\]|no phone|administrator') { Ok 'usbnet-fix.ps1 -Once -DryRun started and reported' }
            else { Warn 'usbnet-fix.ps1 -DryRun produced no output (no phone attached?)' }
        } else { Warn ('usbnet-fix.ps1 -DryRun exited with ' + $LASTEXITCODE) }
    } catch { Warn ('usbnet-fix.ps1 -DryRun threw: ' + $_.Exception.Message) }
}

# ------------------------------------------------------------------ 7. final sweep
Head '7. final sweep'
Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue
$removed = 0
foreach ($dir in @('log', 'backup')) {
    $p = Join-Path $root $dir
    if (Test-Path $p) {
        $n = @(Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host ('  [clean] removed ' + $dir + '\ (' + $n + ' file(s) created by the tests above)') -ForegroundColor Yellow
            $removed++
        }
    }
}
if (Test-Path (Join-Path $root 'state.json')) {
    $st = Get-Content (Join-Path $root 'state.json') -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($st -match 'DeviceId|GatewayMac') {
        Remove-Item (Join-Path $root 'state.json') -Force -ErrorAction SilentlyContinue
        Write-Host '  [clean] removed state.json (device data)' -ForegroundColor Yellow
        $removed++
    }
}
if ($removed -eq 0) { Ok 'no test artifacts were left behind' }

# rescan EVERY file, whatever its extension: a stray log is the most likely leak
$allFiles = @(Get-ChildItem $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $selfName })
$left = 0
foreach ($sf in $allFiles) {
    foreach ($p in $patterns) {
        $m = @(Select-String -LiteralPath $sf.FullName -Pattern $p -SimpleMatch -ErrorAction SilentlyContinue)
        if ($m.Count -gt 0) { $left++; Bad ($p + ' still present in ' + $sf.Name) }
    }
}
if ($left -eq 0) { Ok ('all ' + $allFiles.Count + ' file(s) in the folder are clean') }

# ------------------------------------------------------------------ summary
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
if ($fail -eq 0) {
    Write-Host ' RESULT: clean' -ForegroundColor Green
    if ($removed -gt 0) { Write-Host ' (test artifacts were cleaned automatically)' -ForegroundColor Gray }
} else {
    Write-Host (' RESULT: ' + $fail + ' problem(s) need attention') -ForegroundColor Red
}
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host ''
exit $fail
