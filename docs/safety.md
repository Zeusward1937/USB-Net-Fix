# Safety

This tool modifies the Windows saved-network database. Here is its safety model and the verification record.

## 1. Safety model

### Only confirmed phone profiles are touched

A profile is acted on **only when its gateway MAC was recorded during a real tethering session**.

That means:

- your Wi-Fi and wired profiles are **never candidates**
- a profile is not touched merely because its MAC "looks random"
- the decision is based on **observation**, not on guessing

> An early version did use the "MAC looks randomized" heuristic. It misidentified two real networks (some routers legitimately use locally-administered MACs). That heuristic is gone.

### The online profile is never deleted

A hard rule, checked twice:

1. every run first records the GUIDs of the profiles that are connected right now
2. before deleting anything, each candidate is checked against that list again — if it is online, it is skipped

### When "which one is online" is unknown, nothing is deleted

A hard interlock:

```
if (no online profile was identified this run)
    skip the entire cleanup stage, log a debug line, continue
```

This covers two dangerous states:

- `-MergeOnly` mode (which deliberately skips device identification)
- the adapter is up but Windows has not assigned a profile yet

Deleting in either state is exactly how one could remove a profile that is in use — so it is not done.

### A backup is always taken before cleanup

Before any cleanup, the whole saved-network database is exported with `reg export`:

```
backup\Profiles-<tag>-<timestamp>.reg
backup\Signatures-<tag>-<timestamp>.reg
```

Restore with `reg import`.

### No drivers, no system-wide hooks

- **no service**
- **no driver**
- **no resident process**
- exactly **one scheduled task** (running as SYSTEM, which is required to write `HKLM`)

Task settings: `WakeToRun=false` so the machine is never woken from sleep, `ExecutionTimeLimit=PT5M` so it cannot hang, and the battery restrictions are disabled so laptops work normally on battery.

---

## 2. Verification record

| Check | Result |
|---|---|
| Rename takes effect immediately | ✅ no service restart needed, Settings UI updates at once |
| Delete → restore from `.reg` backup | ✅ full round trip |
| Real Wi-Fi profiles | ✅ 5 profiles untouched across hundreds of tethering sessions |
| Survives a reboot | ✅ task fired 33 s after boot, `result=0x0` |
| Multiple phones | ✅ three phones tracked independently, profile count stable |
| Corrupted name self-heals | ✅ renamed to `Network 99`, corrected on the next run |
| `state.json` boundedness | ✅ stays at the cap after simulating 100 sessions |
| Cost with no phone attached | ✅ 0.52 s, no log lines |
| Run without administrator rights | ✅ prints a clear message, does not crash |

### Reboot reliability

Event triggers depend on three services, all set to **Automatic** (verified):

| Service | State | Start type |
|---|---|---|
| `EventLog` | Running | Automatic |
| `EventSystem` | Running | Automatic |
| `Schedule` | Running | Automatic |

Both event channels (`Microsoft-Windows-Kernel-PnP/Configuration`, `Microsoft-Windows-NetworkProfile/Operational`) are enabled.

On top of that there is a **boot trigger (30 s delay)** and a **daily trigger**, with `StartWhenAvailable=true` so a missed run is made up.

### Effect on boot and shutdown

| Setting | Value | Meaning |
|---|---|---|
| `WakeToRun` | False | never wakes the machine |
| `ExecutionTimeLimit` | PT5M | at most 5 minutes (actual: 1-10 s) |
| `DisallowStartIfOnBatteries` | False | works on battery |
| `StopIfGoingOnBatteries` | False | switching to battery does not interrupt |
| `MultipleInstancesPolicy` | IgnoreNew | never runs concurrently |
| Resident processes | none | the process lives 1-2 s |

---

## 3. Rollback

### Restore the saved-network database

```powershell
# elevated PowerShell
$dir = Join-Path $env:UsbNetFixHome 'backup'   # or your actual install folder
reg import (Join-Path $dir 'Profiles-<timestamp>.reg')
reg import (Join-Path $dir 'Signatures-<timestamp>.reg')
```

### Uninstall

```powershell
.\UsbNetFix.cmd uninstall        # interactive, asks before cleaning leftovers
.\uninstall.ps1 -Purge           # also delete the program files
.\uninstall.ps1 -CleanProfiles   # silently clean leftover phone profiles (keeps one)
```

The uninstaller:

1. stops and unregisters every related scheduled task
2. kills running instances (only processes whose command line contains `usbnet-fix.ps1`)
3. asks whether to clean leftover phone profiles (**backs up first**)
4. keeps the program folder unless `-Purge` is given

### Full manual reset

```powershell
# 1. remove the task
Unregister-ScheduledTask -TaskName 'UsbNetFix-OnPhonePlug' -Confirm:$false

# 2. remove the program folder
Remove-Item (Join-Path $env:UsbNetFixHome) -Recurse -Force

# 3. (only if you really want it) reset all networks
#    Settings > Network & Internet > Advanced network settings > Network reset
```

> ⚠️ Step 3 is Windows' own network reset: it **deletes every saved Wi-Fi password**. Avoiding exactly that is the point of this project — use the `.reg` restore above instead unless there is no other option.

---

## 4. Boundaries worth knowing

1. **Administrator rights are required**, because the saved-network database is under `HKLM`. The scheduled task runs as SYSTEM for that reason.

2. **It edits Windows' own database**, which is different from "registry cleaner" tools: changes are strictly limited to the `NetworkList\Profiles` and `NetworkList\Signatures` keys.

3. **It never touches your Wi-Fi passwords.** Credentials live elsewhere (`ProgramData\Microsoft\Wlansvc`), which this tool never reads or writes.

4. **The log and `state.json` contain device information** (phone model, USB serial). If you publish them (e.g. in an issue), check them first — that is part of why `verify-release.ps1` exists.

5. **A brand-new phone may show the default name at first.** That is not a fault: Android only reports its model name in MTP mode; connect it that way once and the name sticks.
