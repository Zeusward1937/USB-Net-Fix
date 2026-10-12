# UsbNetFix

**Stop Windows from inventing "Network 2", "Network 3", "Network 4"... every time you enable USB tethering.**

Plug in an Android phone, turn on USB tethering, and Windows creates a *brand new* network
profile with an auto-generated name — and it does it again on the next tethering session,
and the next. After a while the saved-network list is full of `Network`, `Network 2`,
`Network 3` ... The usual advice is "do a network reset", which wipes **all** your saved
Wi-Fi profiles. That trade is terrible.

UsbNetFix names every tethering profile **after the phone that created it** — `Pixel 8`,
`Galaxy S24`, `Xiaomi 14`, whatever the phone reports — and cleans up that phone's own
leftovers. The list stops growing, and your Wi-Fi profiles are never touched.

```
before                                  after
  Network        2026-10-09               Pixel 8        Private   ← your phone
  Network 2      2026-10-11               HomeWiFi       Public    ← untouched
  Network 3      2026-10-12               OfficeNet      Public    ← untouched
  HomeWiFi       2026-03-02
  OfficeNet      2026-04-15
```

---

## Why it happens (the actual root cause)

Windows identifies a network by a **signature** whose decisive attribute is the
**default gateway MAC address**, stored next to every saved profile:

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\Unmanaged\<SIGNATURE>
        DefaultGatewayMac = <6 bytes>
```

Android **re-randomizes the RNDIS adapter MAC on every tethering session**. Windows sees a
new gateway MAC, concludes this is a brand-new network, and stores another profile. The
name is auto-generated because the connection is "ethernet-like" with no DHCP domain name,
so Windows falls back to `Network` / `Network N`.

Two consequences worth knowing:

* **It cannot be prevented, only taken over.** The signature's last 64 hex characters are a
  private hash of the fingerprint. I verified that none of the documented candidates
  (SHA-256/SHA-1 over MAC in various formats, GUID combinations, ~157 variants) reproduce
  it, so a profile cannot be pre-seeded in the registry. What *does* work is renaming the
  profile the moment Windows creates it — that registry write is picked up by NLA and by the
  Settings UI **immediately**, with no service restart (verified on Windows 11 22631).
* **The gateway MAC is the phone itself.** During a session, the gateway MAC equals the
  phone's RNDIS adapter MAC. That is what this tool uses to confirm "this really is a
  phone" instead of guessing.

---

## Requirements

* Windows 10 / 11 (developed and verified on Windows 11 22631)
* Windows PowerShell 5.1 (built in — nothing to install)
* Administrator rights (the saved-network database is under `HKLM`)
* An Android phone that supports USB tethering

---

## Install

1. Download / clone this repository.
2. Double-click **`UsbNetFix.cmd`** → choose **5 (install)** → approve the UAC prompt.

That registers one scheduled task (as SYSTEM) and runs a self test. The folder you run it
from becomes the install folder, so you can keep it wherever you like.

To publish a copy into a dedicated folder (recommended if you want the repo to stay clean):

```powershell
powershell -ExecutionPolicy Bypass -File deploy.ps1
```

`deploy.ps1` is **one way only**: it copies the scripts into `%UsbNetFixHome%`, or
`%LOCALAPPDATA%\UsbNetFix` when that variable is unset, backs up whatever was there before,
verifies every file by hash, re-registers the task against the new location and prints the
runner path it registered.

> `%LOCALAPPDATA%` is chosen as the default install root because it is writable **without**
> elevation — so the control panel can write its `log\` and `state.json` normally, while the
> SYSTEM scheduled task can still reach it. `%ProgramFiles%` would need an elevated control
> panel for those writes.
>
> Note: when the task is registered, the install path is passed in explicitly. A relative
> `%LOCALAPPDATA%` is never resolved inside the task, because the task runs as SYSTEM —
> whose `%LOCALAPPDATA%` is a different folder.

### Daily use

Nothing. Plug in the phone and enable USB tethering — within a few seconds the network is
renamed after that phone.

### Control panel

| Menu | What it does |
|---|---|
| `1 status` | devices, saved profiles, live networks, task state, log tail |
| `2 names` | **which phone would get which name, and why** (shows USB serial, model, decision source) |
| `3 monitor` | live tethering state + which USB modes the phone currently exposes |
| `4 apply` | run the fixer right now |
| `5 install` | deploy + register the scheduled task |
| `6 diagnose` | write a full diagnostic snapshot |
| `7 / 8` | edit `config.json` / open the log folder |
| `9 uninstall` | remove the scheduled task |

Command line works too: `UsbNetFix.cmd status`, `UsbNetFix.cmd names`, `UsbNetFix.cmd monitor`, ...

---

## How a phone is identified (and named)

No guessing, no heuristics like "this MAC looks random":

| Step | Information used | Notes |
|---|---|---|
| 1 | **USB vendor id** | e.g. `2D95` (vivo/iQOO), `2717` (Xiaomi), `18D1` (Google) — configurable list |
| 2 | **Real parent device** (`DEVPKEY_Device_Parent`) | the adapter's network GUID is resolved to its USB instance, then up to the parent, which carries the **USB serial number** |
| 3 | **Model name** | Android reports its marketing name only in **MTP (file transfer) mode**; that record is a sibling interface sharing the same parent serial, so it can be matched exactly |
| 4 | **Gateway MAC** | confirms "this session is that phone". Only confirmed MACs are ever acted on |

> **Why not the USB port?** Two different phones plugged into the *same* USB port share the
> same `LocationInformation`. Matching by port named one phone after another during
> development. The serial number is the primary key; the port is only a last resort when
> exactly one device there reports a model.

Name resolution order:

```
DeviceRules in config.json   (match Vid / ModelLike / SerialLike -> your own name)
        |
        v  no rule matched
name learned earlier for this same device (state.json)
        |
        v  not seen before
the model name the phone reports over USB        e.g. "Pixel 8"
        |
        v  phone never reported a model
DefaultName                                      e.g. "USB Tethering"
```

`Network N` can never be produced. If two phones would get the same name the second one
gets a ` 2` suffix, so Windows never starts numbering again.

### Using several phones

Just plug them in — each is tracked separately by USB serial number, each gets its own
profile, and switching phones does not disturb the others.

To pin a custom name, add a rule to `config.json`:

```json
"DeviceRules": [
  { "Vid": "18D1", "ModelLike": "^Pixel 8$",   "Name": "My Pixel" },
  { "Vid": "2717", "ModelLike": "^Xiaomi 14$", "SerialLike": "^ABC123", "Name": "Test phone" }
]
```

* `ModelLike` — regex against the model name the phone reports (`+` etc. must be escaped: `\+`)
* `SerialLike` — regex against the USB serial number (use this when you have several phones
  of the same model)
* Find a phone's serial with `UsbNetFix.cmd names`, or from `DeviceId` in `state.json`

> Give every phone a **different** `Name`. Two phones sharing one name look like leftovers
> of each other and get cleaned up.

---

## Configuration (`config.json`)

| Key | Default | Meaning |
|---|---|---|
| `DeviceRules` | `[]` | per-device name overrides (see above) |
| `AutoNameFromModel` | `true` | name unknown phones after their own model name |
| `NamePrefix` | `""` | optional prefix, e.g. `"USB: "` |
| `DefaultName` | `USB Tethering` | used when the phone never reported a model |
| `Category` | `Private` | `Private` \| `Public` \| `Keep`. Private enables file sharing / device discovery on that network |
| `SettleSeconds` | `8` | wait for Windows to finalize the profile before renaming |
| `ProfileWaitSeconds` | `30` | how long to wait for Windows to assign a profile after the adapter appears |
| `MergeDuplicateProfiles` | `true` | fold that phone's own leftover profiles together |
| `ForgetLegacyProfiles` | `true` | delete that phone's leftovers instead of just renaming |
| `VendorIds` | common list | USB vendor ids recognised as "phones" |
| `DescriptionPatterns` | `Remote NDIS`, ... | interface-description fallback |
| `LogMaxKB` | `768` | log rotation threshold |
| `LogKeepDiagFiles` / `LogKeepDiagDays` | `20` / `30` | pruning of diagnostic snapshots |
| `Verbose` | `false` | verbose debug logging |

---

## Architecture: event driven, zero polling

One scheduled task, `UsbNetFix-OnPhonePlug`, with four triggers:

| Trigger | Fires when |
|---|---|
| **Kernel-PnP EventID 410 / 400** | a USB device is started/configured (the phone's RNDIS adapter appears) |
| **NetworkProfile EventID 10000-10002** | Windows creates / changes / deletes a network profile |
| **BootTrigger** (30 s delay) | after every boot — safety net |
| **CalendarTrigger** (once a day) | last resort if an event was missed |

Each run is a short-lived process: it inspects the current state, fixes what needs fixing,
and exits. **When nothing happens, nothing runs.**

Measured on the development machine:

| Situation | Time | Notes |
|---|---|---|
| No phone attached | **0.52 s** | exits before any wait, writes no log line |
| Phone attached | **9.5 s** | 8 s of that is the deliberate settle wait |
| Peak memory | ~180 MB working set | PowerShell interpreter baseline, released on exit |
| CPU while idle | **0** | no polling, no resident process |

The Kernel-PnP trigger cannot be narrowed to a specific device: Windows event queries accept
only *equality* on `EventData` (`contains()` is rejected with "The specified query is
invalid"), and the USB instance path changes with the port. So other USB devices trigger a
run too — it just exits in half a second. The NetworkProfile trigger is the safety net for
phones Windows re-enumerates without a PnP event (observed in practice).

---

## Safety

* **Only confirmed phone profiles are ever modified.** A profile is acted on only when its
  gateway MAC was learned during a real tethering session. Wi-Fi/Ethernet profiles are never
  candidates — not even ones whose MAC happens to look randomized.
* **The online profile is never deleted.** Hard rule, checked twice.
* **No deletion when the online profile cannot be determined.** `-MergeOnly` and the
  "adapter up but no profile yet" case skip cleanup entirely rather than guess.
* **A `.reg` backup is taken before any cleanup.** `backup\Profiles-*.reg` +
  `Signatures-*.reg` restore the whole saved-network database.
* **No service, no driver, no resident process.** Nothing to interfere with boot/shutdown;
  `WakeToRun=false` so the machine is never woken up.
* **Nothing is installed system-wide.** One scheduled task, plus files in the app folder.

Verified on the development machine: rename takes effect immediately with no service
restart; delete → restore-from-backup round trip works; five real Wi-Fi profiles survived
hundreds of tethering sessions untouched; behavior survives a reboot (task fired 33 s after
boot, `result=0x0`).

### Uninstall

```powershell
.\UsbNetFix.cmd uninstall        # interactive
.\uninstall.ps1 -Purge           # also delete the app folder
.\uninstall.ps1 -CleanProfiles   # also remove leftover phone profiles (keeps one)
```

---

## Files

| File | Purpose |
|---|---|
| `UsbNetFix.cmd` / `UsbNetFix.ps1` | control panel / CLI |
| `usbnet-fix.ps1` | the fixer; run by the scheduled task (`-Once`, `-DryRun`, `-MergeOnly`, `-Loop`) |
| `netprof-lib.ps1` | registry + device-identity layer |
| `tasks.ps1` | registers the scheduled task |
| `deploy.ps1` | one-way deploy of a changed source tree into an install folder |
| `uninstall.ps1` | removes the task (and optionally everything else) |
| `diag-watcher.ps1` | read-only diagnostic snapshot |
| `config.json` | settings |
| `state.json` | learned phones and confirmed fingerprints (created at runtime) |
| `log\`, `backup\` | runtime data (created at runtime) |

---

## Development notes / pitfalls

These cost real debugging time; they are documented so nobody repeats them.

| Pitfall | Symptom | Fix |
|---|---|---|
| `Profiles\{GUID}` has **no** `Signature` value | the whole lookup chain silently found nothing | the link is the other way round: `Signatures\*\ProfileGuid` points at the profile |
| `DateCreated` is not a FILETIME | dates parse as empty | it is a 16-byte `SYSTEMTIME` (8 little-endian WORDs) |
| Trusting "the MAC looks randomized" | real routers use locally-administered MACs too — that would rename the user's Wi-Fi | only act on fingerprints confirmed during a real phone session |
| `reg.exe export` needs a hive-qualified key | backup silently produced 0 files | prefix with `HKLM\` |
| Windows PowerShell 5.1 reads BOM-less `.ps1` as ANSI | non-ASCII literals break the parser (`$var:` inside strings, unterminated strings) | keep scripts pure ASCII; put non-ASCII in JSON |
| `Global\` mutex from an elevated process | `Access denied`, single-instance guard silently disabled | use the `Local\` namespace |
| Deriving the parent device name syntactically | broke for interface instances shaped like `6&1A2B3C&1&0000` | ask the device tree (`DEVPKEY_Device_Parent`) |
| The USB interface's last path segment | used as a "serial", but it is a port path that changes per port | take the serial from the parent device |
| Matching phones by USB port | two phones on the same port resolved to the same model | match by USB serial number |
| Registering an event trigger from a CIM object | `Register-ScheduledTask` "succeeded" but no task appeared | define the task as raw XML |
| `EventData` filters in event queries | `The specified query is invalid` | only equality is supported; filter in the script instead |
| An empty string in `config.json` | `"LogFile": ""` was treated as a valid path → logging silently off | treat blank as "not configured" |
| `.cmd` written as UTF-8 | cmd.exe read it as ANSI, ate a line break, and every word became a command | save `.cmd` as ANSI/ASCII |
| Copying files by hand during development | an older build overwrote a newer one; the task pointed at a folder with no script (`0xFFFD0000`, silently doing nothing) | one-way `deploy.ps1` that verifies hashes and prints the runner path |

---

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Google, vivo, Xiaomi or Microsoft. It only edits Windows' own
saved-network database; no drivers, no system-wide hooks.
