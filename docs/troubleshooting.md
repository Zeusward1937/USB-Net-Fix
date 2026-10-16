# Troubleshooting

## 1. Usage questions

### Double-clicking UsbNetFix.cmd raises a UAC prompt - is that normal?

**Yes, by design.**

The registry key `HKLM\...\NetworkList` is owned by SYSTEM, and its ACL grants access only to `BUILTIN\Administrators` and the `netprofm` service account. A **standard user cannot even read it**, so without elevation the control panel could only report "admin rights required" for almost everything.

The launcher therefore requests elevation. If you decline the prompt it falls back to a normal run, where the informational commands still work.

> Daily use needs **no interaction at all**: the background scheduled task runs as SYSTEM.

### The name did not change after plugging in the phone

Check in order:

1. **Menu `3 monitor`** — is the phone's network adapter actually present? (should list an adapter such as `Remote NDIS`)
   - not listed → USB tethering is off on the phone, or the cable is charge-only
2. **Menu `2 names`** — what did the tool identify, and what name would it use?
   - if it shows `usb model: (phone never reported a model)`, this phone has never been connected in **File transfer** mode
3. **Menu `1 status`** — scheduled task state
   - `not registered` → choose `5` to reinstall
   - `Ready` but a non-zero `result` → read the last lines of `log\usbnet-fix.log`

### The name is `USB Tethering` instead of the phone model

The phone has not reported its model name yet. Android only reports it in **File transfer (MTP) mode**, and on Android tethering and file transfer are **mutually exclusive USB configurations**.

**Fix**: set the phone's USB mode to "File transfer", let the PC see the storage, then switch back to "USB tethering". The tool remembers the model from then on.

### Why does the phone name have " 2" appended?

The base name is already taken by **another phone**. Two phones are not allowed to share a name (they would look like each other's leftovers and get cleaned up).

Fix: give each phone its own `DeviceRules` entry in `config.json`.

### File transfer does not work while tethering

That is an **Android limitation**, not caused by this tool — the two modes are mutually exclusive at the USB level:

| phone USB mode | product id | interfaces Windows sees |
|---|---|---|
| **USB tethering** | `PID_600A` | only `MI_00` = RNDIS network adapter |
| **File transfer (MTP)** | `PID_6012` | `MI_00` = MTP, `MI_01` = mass storage |

Android enables exactly **one** USB configuration at a time, so while tethering is on the MTP interface is not enumerated at all.

Workarounds, easiest first:

1. **Wireless transfer** — WeChat/QQ file helper, LocalSend, Feem; tethering stays on
2. **Switch the phone's USB mode** to "File transfer", copy, then switch back (network drops for a few seconds)
3. **`adb push` / `adb pull`** — USB debugging is a different interface and can coexist; needs a driver and is slower than MTP
4. **Cloud storage** over the shared connection

### Will it lose my Wi-Fi profiles?

**No.** The tool only acts on profiles whose gateway MAC was **observed during a real phone tethering session**. Your Wi-Fi profiles are never candidates. Verified: five real Wi-Fi profiles survived hundreds of sessions untouched.

### Does it slow down boot or shutdown?

**No.** No resident process (the process lives 1-2 s), no service, no driver, `WakeToRun=false`, and the boot trigger is delayed 30 s to stay out of the busiest boot phase.

### How much does it use?

**Nothing while idle** (event driven, no polling). When triggered: about 0.5-10 s and ~180 MB peak working set (the PowerShell interpreter baseline, released when the process exits).

---

## 2. Troubleshooting

### Collect diagnostics

```
UsbNetFix.cmd diagnose
```

Writes a full snapshot into `log\` (devices, fingerprints, profile list, task state, log tail).

> ⚠️ **This file contains your phone model and USB serial number.** Check and redact it before posting publicly (e.g. in a GitHub issue).

### It says netprof-lib.ps1 (or a similar file) cannot be found

The program folder is **incomplete**. Copy the whole folder again.

Both layouts are supported — **flat** (all `.ps1` files in one folder, which is what unpacking the release gives you) and a **`lib\` subfolder** — and the scripts detect which one they are in. But the files must all be present.

### The task exists but nothing happens

Check that the task's action path really exists:

```powershell
$a = (Get-ScheduledTask -TaskName 'UsbNetFix-OnPhonePlug').Actions[0].Arguments
$a
Test-Path '<install dir>\usbnet-fix.ps1'   # use the path from the output above
```

This bit during development: the task **was** triggered and **did** report success, but its `-File` pointed at a folder with no script in it, so nothing happened. The task registration now prints the actual runner path for this reason.

If the path is wrong: run `UsbNetFix.cmd` → choose `5`.

### Run it by hand to see the error

```powershell
# elevated PowerShell, adjust the path to your install folder
cd <install dir>
powershell -ExecutionPolicy Bypass -File .\usbnet-fix.ps1 -Once
```

- `-Once` skips the 8 s settle wait and runs immediately
- `-DryRun` reports what it would change and **changes nothing**
- `-MergeOnly` only cleans leftovers of already-known phones
- `-Loop` stays resident and polls (debugging only)

> In a `lib\` layout the path is `.\lib\usbnet-fix.ps1`.

### Self check

```
verify.bat
```

Runs seven checks: script syntax, ASCII purity, leftover personal data, absence of runtime data, `config.json` validity, **a real run of each entry point**, and a final sweep that also removes anything the tests created. Any failure is reported explicitly.

### Where are the logs?

```
<install dir>\log\usbnet-fix.log
<install dir>\log\diag-*.txt       diagnostic snapshots
<install dir>\log\tasks.txt        task registration record
```

The log rotates at 768 KB, and old diagnostic snapshots are pruned by count and age.

---

## 3. Development pitfalls

These cost real debugging time; they are listed so nobody repeats them.

| Pitfall | Symptom | Fix |
|---|---|---|
| `Profiles\{GUID}` has **no** `Signature` value | the whole lookup chain silently found nothing | the link is the other way round: `Signatures\*\ProfileGuid` points at the profile |
| Treating `DateCreated` as a FILETIME | dates parse as empty | it is a 16-byte `SYSTEMTIME` (8 little-endian WORDs) |
| Trusting "the MAC looks randomized" | real routers use locally-administered MACs too; it renamed the user's Wi-Fi | only act on fingerprints confirmed during a real phone session |
| `reg.exe export` without a hive prefix | backup silently produced 0 files | must be `HKLM\...` |
| PS 5.1 parses a BOM-less `.ps1` as ANSI | non-ASCII literals break the parser (`$var:` inside strings, unterminated strings) | keep scripts pure ASCII; put non-ASCII in JSON |
| `Global\` mutex in an elevated process | `Access denied`, the single-instance guard silently disabled | use the `Local\` namespace |
| Deriving the parent device name from the string | fails for interface instances shaped like `6&1EB7303F&1&0000` | ask the device tree (`DEVPKEY_Device_Parent`) |
| Treating the last segment of a USB interface instance as a serial | it is a **port path** that changes with the port | take the serial from the parent device |
| Telling phones apart by USB port | two phones on the same port resolved to the same model | use the USB serial number as the identity key |
| Registering an event trigger from a CIM object | `Register-ScheduledTask` reports success but no task appears | define the task as raw XML |
| Filtering on `EventData` in an event query | `The specified query is invalid` | only equality is supported; filter inside the script |
| An empty string in `config.json` | `"LogFile": ""` was accepted as a valid path → logging silently off | treat blank as "not configured", add a fallback path |
| Saving `.cmd` as UTF-8 | cmd.exe reads it as ANSI, eats a line break, every word becomes a command | save `.cmd` as ANSI/ASCII |
| Copying files by hand to sync | an older build overwrote a newer one; the task pointed at an empty folder (`0xFFFD0000`, silent failure) | one-way `deploy.ps1` that verifies hashes and prints the runner path |
| A per-minute polling task | 1440 runs/day, all pointless | USB / network-profile events plus a boot and a daily safety net |
| Waiting 8 s before checking for a phone | wasted time on almost every run | pre-check first, exit immediately when there is nothing to do |
| A verification script that runs the tool | the tool's log contains the phone's real model and serial | point test logs at a temp directory and rescan everything afterwards |
| **Assuming a `lib\` layout only** | the flat release could not start at all: every command died with "netprof-lib.ps1 is not recognized" | detect the layout at runtime; the verifier now checks output, not just exit codes |
| **A verifier that only checks exit codes** | that layout bug slipped through, because a failed command still exited 0 | check exit code AND expected output AND "command not found" text |
| Chinese text inside a helper `.ps1` | the script fails to parse (`Unexpected token`) because 5.1 reads it as ANSI | keep helper scripts pure ASCII too |

### About encoding

Windows PowerShell 5.1 decodes a **BOM-less `.ps1` as ANSI** (GBK on a Chinese system). This caused:

- Chinese comments in a `.ps1` to break the parser ("string is missing the terminator")
- UTF-8 Chinese in a `.cmd` to eat a line break, producing `'l' is not recognized as an internal or external command`

**Every script in this project is pure ASCII**; non-ASCII text lives only in `.md` and `.json` files. Check 2 of `verify-release.ps1` enforces this.

---

## 4. Reporting a problem

Please include:

1. a **diagnostic snapshot** (redact the phone model and serial number first)
2. Windows version (`winver`)
3. phone model and Android version
4. what you expected vs what happened

The last 30 lines of `log\usbnet-fix.log` help too (again, check for sensitive content first).
