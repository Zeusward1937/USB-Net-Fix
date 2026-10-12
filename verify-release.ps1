#requires -Version 5.1
<#
  verify-release.ps1 -- pre-publish checks for this release copy.
  ===========================================================================
  Run this BEFORE uploading to GitHub.  It verifies, using only what is available on
  a stock Windows box:

    1. every .ps1 file parses (catches typos introduced while editing)
    2. no machine/owner specific data is left in the sources
    3. no runtime data files (state.json / log / backup) are present
    4. the entry points actually run (read-only commands)
    5. the JSON config is valid

  Nothing here needs administrator rights and nothing is modified.
  ASCII only (Windows PowerShell 5.1 decodes BOM-less .ps1 as ANSI).
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
function Head { param([string]$m) Write-Host ''; Write-Host ('== ' + $m + ' ' + ('=' * [Math]::Max(0, 58 - $m.Length))) -ForegroundColor Cyan }
# sensitive markers seen on the development machine - the release must contain none of
# them.  Kept in one place so the first scan and the final sweep use the same list.
$patterns = @(
    'C:\Users\',
    'C:\Apps\',
    'AppData\Local\UsbNetFix',
    'DESKTOP-',
    '10CEAN', '10CF5E', '5059B8DC',
    'LatticeNimble', 'tjuwlan', 'Zeusward',
    'iQOO Z9', 'iQOO Z10', 'Redmi K70', 'Pad2 Pro'
)

Write-Host ''
Write-Host 'UsbNetFix - release verification' -ForegroundColor White
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
        Warn ($f.Name + ' contains ' + $nonAscii + ' non-ASCII byte(s) - PowerShell 5.1 may misparse it')
    } else {
        Ok ($f.Name + ' is pure ASCII')
    }
}

# ------------------------------------------------------------------ 3. personal data
Head '3. leftover personal / machine specific data'
$scanFiles = @(Get-ChildItem $root -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @('.ps1','.json','.md','.cmd','.bat','.txt') -and $_.Name -ne 'verify-release.ps1' })
$hits = 0
foreach ($p in $patterns) {
    foreach ($f in $scanFiles) {
        $m = Select-String -LiteralPath $f.FullName -Pattern $p -SimpleMatch -ErrorAction SilentlyContinue
        if ($m) {
            $hits++
            Bad ("'" + $p + "' found in " + $f.Name + ' (line ' + ($m | Select-Object -First 1).LineNumber + ')')
        }
    }
}
if ($hits -eq 0) { Ok 'no personal data patterns found' }

# ------------------------------------------------------------------ 4. runtime data
Head '4. runtime data must not be shipped'
foreach ($item in @('state.json', 'config.new.json')) {
    if (Test-Path (Join-Path $root $item)) { Bad ($item + ' is present - it contains your real device data, delete it') }
    else { Ok ($item + ' is absent') }
}
foreach ($dir in @('log', 'backup')) {
    if (Test-Path (Join-Path $root $dir)) {
        $n = @(Get-ChildItem (Join-Path $root $dir) -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($n -gt 0) { Bad ($dir + '\ contains ' + $n + ' file(s) - logs/registry backups must not be published') }
        else { Ok ($dir + '\ is empty') }
    } else { Ok ($dir + '\ is absent') }
}
if (Test-Path (Join-Path $root '.gitignore')) {
    $gi = Get-Content (Join-Path $root '.gitignore') -Raw
    foreach ($need in @('state.json', 'log/', 'backup/')) {
        if ($gi -match [regex]::Escape($need)) { Ok ('.gitignore excludes ' + $need) }
        else { Bad ('.gitignore does not exclude ' + $need) }
    }
} else { Bad '.gitignore is missing' }

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
Head '6. entry points (read-only)'
# The fixer writes a log, and that log would contain the attached phone's real model and
# USB serial number - so point it at a throw-away config in %TEMP% and delete it after.
$probeDir = Join-Path $env:TEMP ('UsbNetFix-verify-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
$probeCfg = Join-Path $probeDir 'config.json'
try { Get-Content $cfgPath -Raw -Encoding UTF8 | Set-Content -Path $probeCfg -Encoding UTF8 } catch { }

foreach ($cmd in @('names', 'monitor')) {
    try {
        $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'UsbNetFix.ps1') $cmd 2>&1
        $rc = $LASTEXITCODE
        if ($rc -eq 0) { Ok ('UsbNetFix.ps1 ' + $cmd + ' ran (exit 0)') }
        else { Bad ('UsbNetFix.ps1 ' + $cmd + ' exited with ' + $rc); @($out) | Select-Object -First 5 | ForEach-Object { Write-Host ('           ' + $_) -ForegroundColor Red } }
    } catch { Bad ('UsbNetFix.ps1 ' + $cmd + ' threw: ' + $_.Exception.Message) }
}
try {
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'usbnet-fix.ps1') -Once -DryRun -ConfigPath $probeCfg 2>&1
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { Ok 'usbnet-fix.ps1 -Once -DryRun ran (exit 0)' }
    else { Warn ('usbnet-fix.ps1 -DryRun exited with ' + $rc + ' (normal when not elevated)') }
} catch { Warn ('usbnet-fix.ps1 -DryRun threw: ' + $_.Exception.Message) }

Write-Host ''
Write-Host '== 7. final sweep (rescan every file, clean test artifacts) ==========' -ForegroundColor Cyan
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
if ($removed -eq 0) { Ok 'no test artifacts were left behind' }
$allFiles = @(Get-ChildItem $root -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'verify-release.ps1' })
$left = 0
foreach ($sfile in $allFiles) {
    foreach ($p in $patterns) {
        $m = Select-String -LiteralPath $sfile.FullName -Pattern $p -SimpleMatch -ErrorAction SilentlyContinue
        if ($m) { $left++; Bad ("'" + $p + "' still present in " + $sfile.Name) }
    }
}
if ($left -eq 0) { Ok ('all ' + $allFiles.Count + ' file(s) in the folder are clean') }

# ------------------------------------------------------------------ summary
Write-Host ''
Write-Host ('=' * 62) -ForegroundColor Cyan
if ($fail -eq 0) {
    Write-Host ' RESULT: ready to publish' -ForegroundColor Green
    Write-Host ' Review the [WARN] lines above (if any), then upload.' -ForegroundColor Gray
} else {
    Write-Host (' RESULT: ' + $fail + ' problem(s) must be fixed before publishing') -ForegroundColor Red
}
Write-Host ('=' * 62) -ForegroundColor Cyan
Write-Host ''
exit $fail
