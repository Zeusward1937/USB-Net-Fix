#requires -Version 5.1
<#
  deploy.ps1 -- ONE WAY deploy from this source folder into an install folder.
  ===========================================================================
  Why this exists: while developing UsbNetFix the files were copied around by hand
  (sometimes in both directions), and that is how an older build once overwrote a newer
  one and how the scheduled task once ended up pointing at a folder with no script in it.
  This script is the only supported way to publish a change:

      source (this folder)  --->  <install folder>   (one direction only)
                                  *.ps1
                                  UsbNetFix.cmd / config.json / README.md

  It also re-registers the scheduled task so the runner path is always the installed one,
  and then verifies everything (hashes, paths, triggers).

  Usage:  powershell -ExecutionPolicy Bypass -File deploy.ps1 [-Target <dir>] [-NoTasks]

  Default target, in order of preference:
      1. -Target <dir>
      2. %UsbNetFixHome%, when set              setx UsbNetFixHome "D:\Tools\UsbNetFix"
      3. %LOCALAPPDATA%\UsbNetFix
  %LOCALAPPDATA% is used on purpose: it is writable by the user, so the control panel can
  write its log/state without elevation, while the SYSTEM scheduled task can reach it too.

  ASCII only.
#>
[CmdletBinding()]
param(
    [string]$Target,
    [switch]$NoTasks
)

$ErrorActionPreference = 'Continue'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $Target) {
    if ($env:UsbNetFixHome) { $Target = $env:UsbNetFixHome }
    else { $Target = Join-Path $env:LOCALAPPDATA 'UsbNetFix' }
}
if (-not (Test-Admin)) {
    $argl = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'), '-Target', ('"' + $Target + '"'))
    if ($NoTasks) { $argl += '-NoTasks' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -Verb RunAs -Wait
    exit
}

$src = $PSScriptRoot
$logDir = Join-Path $Target 'log'
New-Item -ItemType Directory -Force -Path $Target, $logDir, (Join-Path $Target 'backup') | Out-Null
$log = Join-Path $logDir 'deploy.txt'
$L = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $L.Add($s); Write-Host $s }

W ('### deploy  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
W ('  source : ' + $src)
W ('  target : ' + $Target)

$scriptFiles = @('UsbNetFix.ps1','usbnet-fix.ps1','netprof-lib.ps1','tasks.ps1','uninstall.ps1','diag-watcher.ps1')
$rootFiles   = @('UsbNetFix.cmd','README.md','LICENSE')

# --- guard against deploying a folder into itself ------------------------------------
$samePath = $false
try { $samePath = ((Resolve-Path $src).Path -eq (Resolve-Path $Target).Path) } catch { }
if ($samePath) { W '  source and target are the same folder - only task registration will be done' }

# --- 1. safety backup of the current app ---------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bk = Join-Path $Target ('backup\app-' + $stamp)
try {
    New-Item -ItemType Directory -Force -Path $bk | Out-Null
    foreach ($f in ($scriptFiles + $rootFiles + @('config.json'))) {
        $p = Join-Path $Target $f
        if (Test-Path $p) { Copy-Item $p $bk -Force -ErrorAction SilentlyContinue }
    }
    W ('1) previous version backed up to ' + $bk)
    Get-ChildItem (Join-Path $Target 'backup') -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
} catch { W ('1) [WARN] backup failed: ' + $_.Exception.Message) }

# --- 2. copy implementation (never touches config.json or state.json) ----------------
$copied = 0
if (-not $samePath) {
    foreach ($f in ($scriptFiles + $rootFiles)) {
        $s = Join-Path $src $f
        $d = Join-Path $Target $f
        if (-not (Test-Path $s)) { continue }
        try { Copy-Item -LiteralPath $s -Destination $d -Force -ErrorAction Stop; $copied++ }
        catch { W ('2) [ERROR] ' + $f + ' : ' + $_.Exception.Message) }
    }
    W ('2) copied ' + $copied + ' file(s); config.json and state.json left untouched')
} else {
    W '2) nothing to copy (source is the target)'
}

# --- 3. new config keys are offered, never forced ------------------------------------
$srcCfg = Join-Path $src 'config.json'
$dstCfg = Join-Path $Target 'config.json'
if (-not (Test-Path $dstCfg)) {
    if (Test-Path $srcCfg) { Copy-Item $srcCfg $dstCfg -Force; W '3) config.json installed (first time)' }
} else {
    $newKeys = @()
    try {
        $a = Get-Content $dstCfg -Raw -Encoding UTF8 | ConvertFrom-Json
        $b = Get-Content $srcCfg -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $b.PSObject.Properties) {
            if ($p.Name -like '_*') { continue }
            if (-not $a.PSObject.Properties[$p.Name]) { $newKeys += $p.Name }
        }
    } catch { }
    if ($newKeys.Count -gt 0) {
        W ('3) your config.json is missing new key(s): ' + ($newKeys -join ', '))
        W '   a reference copy was written to config.new.json - merge by hand if you want them'
        try { Copy-Item $srcCfg (Join-Path $Target 'config.new.json') -Force } catch { }
    } else {
        W '3) config.json already has every known key'
    }
}

# --- 4. verify hashes ---------------------------------------------------------------
$bad = 0
if (-not $samePath) {
    foreach ($f in ($scriptFiles + $rootFiles)) {
        $s = Join-Path $src $f
        $i = Join-Path $Target $f
        if (-not (Test-Path $s)) { continue }
        if ((Get-FileHash -LiteralPath $s).Hash -ne (Get-FileHash -LiteralPath $i).Hash) { W ('4) [ERROR] hash mismatch: ' + $f); $bad++ }
    }
}
if ($bad -eq 0) { W '4) all deployed files verified (hashes match)' } else { W ('4) ' + $bad + ' file(s) FAILED verification') }

# --- 5. re-register the scheduled task ----------------------------------------------
if (-not $NoTasks) {
    $runner = Join-Path $Target 'usbnet-fix.ps1'
    if (Test-Path $runner) {
        W '5) re-registering the scheduled task against the installed path'
        $tasksScript = Join-Path $Target 'tasks.ps1'
        if (Test-Path $tasksScript) {
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tasksScript -SourceDir $Target 2>&1 |
                ForEach-Object { W ('   ' + $_) }
        } else { W '   [ERROR] tasks.ps1 missing in the target' }
    } else {
        W '5) [ERROR] installed runner is missing - task NOT re-registered'
    }
} else {
    W '5) task registration skipped (-NoTasks)'
}

# --- 6. quick self test --------------------------------------------------------------
W ''
W '6) self test (dry run):'
$runner = Join-Path $Target 'usbnet-fix.ps1'
if (Test-Path $runner) {
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $runner -Once -DryRun 2>&1
    foreach ($o in @($out)) { W ('   ' + $o) }
} else { W '   [ERROR] runner missing' }

W ''
W ('deploy finished.  runner: ' + $runner)
$L | Set-Content $log -Encoding UTF8
Write-Host ('WROTE ' + $log)
