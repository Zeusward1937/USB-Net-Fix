# UsbNetFix

**Stop Windows from inventing "Network 2", "Network 3", ... every time you enable Android USB tethering.**

Windows identifies a network by its default gateway MAC address, and Android re-randomizes that MAC on every tethering session — so Windows believes it found a brand new network and stores another profile, named `Network` / `Network N`. The usual advice is "do a network reset", which wipes **all** your saved Wi-Fi profiles.

UsbNetFix renames the profile to the phone's own name (e.g. `Pixel 8`) the moment Windows creates it, and removes that phone's own leftovers.

```
before                                  after
  Network        2026-10-09               Pixel 8        Private   ← your phone
  Network 2      2026-10-11               HomeWiFi       Public    ← untouched
  Network 3      2026-10-12               OfficeNet      Public    ← untouched
  HomeWiFi       2026-03-02
  OfficeNet      2026-04-15
```

- ✅ Your Wi-Fi profiles are **never** lost and **never** modified
- ✅ Multiple phones are tracked independently
- ✅ **Runs only when something happens** — event driven, no polling, no resident process
- ✅ Pure PowerShell: no drivers, no system-wide hooks

---

## Install

1. Download or clone this repository
2. **Double-click `UsbNetFix.cmd`** → choose `5` → approve the UAC prompt

Done. That registers one scheduled task (triggers on phone plug-in and on boot).

> Administrator rights are required (the saved-network database lives under `HKLM`).
> To install into a dedicated folder instead: `powershell -ExecutionPolicy Bypass -File deploy.ps1`

## Daily use

**Nothing.** Plug in the phone, enable USB tethering, and within a few seconds the network is named after that phone.

Double-click `UsbNetFix.cmd` when you want to look at something:

| Menu | What it does |
|---|---|
| `1 status` | current state: devices, profiles, task, log tail |
| `2 names` | **which name the attached phone gets, and why** |
| `3 monitor` | live tethering state + which USB modes the phone exposes |
| `4 apply` | run the fix right now |
| `5 install` | install / repair |
| `6 diagnose` | write a diagnostic snapshot (for bug reports) |
| `7` / `8` | edit config / open the log folder |
| `9 uninstall` | uninstall |

Command line works too: `UsbNetFix.cmd status`, `UsbNetFix.cmd names`, `UsbNetFix.cmd monitor`

## Switching phones / multiple phones

**Just plug them in.** Devices are told apart by USB serial number, so each gets its own name.

| Situation | Result |
|---|---|
| The phone has been connected in "File transfer" (MTP) mode at least once | named after its model, e.g. `Pixel 8` |
| The phone never reported a model | starts as `USB Tethering`; switch its USB mode to "File transfer" once and the model is remembered |
| You want a fixed custom name | add a rule to `config.json` (below) |

```json
"DeviceRules": [
  { "Vid": "18D1", "ModelLike": "^Pixel 8$",   "Name": "My Pixel" },
  { "Vid": "2717", "ModelLike": "^Xiaomi 14$", "SerialLike": "^ABC123", "Name": "Test phone" }
]
```

- `ModelLike` — regex against the model name the phone reports (escape `+` as `\+`)
- `SerialLike` — regex against the USB serial number (use it when you own several phones of the same model)
- Find a serial with `UsbNetFix.cmd names`

> ⚠️ Give every phone a **different** name. Two phones sharing one name look like leftovers of each other and get cleaned up.

## Configuration (`config.json`)

The ones you are likely to touch:

| Key | Default | Meaning |
|---|---|---|
| `DeviceRules` | `[]` | custom naming rules (see above) |
| `Category` | `Private` | network type: `Private` (file sharing allowed) / `Public` / `Keep` (do not change) |
| `DefaultName` | `USB Tethering` | used when no model name is available |
| `SettleSeconds` | `8` | wait for Windows to finalize the profile before renaming |
| `ForgetLegacyProfiles` | `true` | delete that phone's own leftover profiles |
| `Verbose` | `false` | verbose debug logging |

## Uninstall

```powershell
.\UsbNetFix.cmd uninstall        # interactive
.\uninstall.ps1 -Purge           # also delete the program files
```

## Known limits

1. **The model name requires one "File transfer" connection**, otherwise the default name is used at first.
2. **Windows still stores one profile per tethering session** — the tool renames it and removes that phone's older leftovers, so the list you see does not grow.
3. **The MAC randomization cannot be stopped** (unrooted Android does not allow changing the RNDIS MAC). This tool takes over the profile instead of preventing it, which is equivalent in practice.

## More documentation

| Document | Contents |
|---|---|
| [docs/technical.md](docs/technical.md) | root cause, identification logic, event-driven architecture, measured resource usage |
| [docs/safety.md](docs/safety.md) | safety model, verification records, rollback |
| [docs/troubleshooting.md](docs/troubleshooting.md) | troubleshooting and development pitfalls |

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Google, vivo, Xiaomi, Samsung or Microsoft. It only edits Windows' own saved-network database; no drivers, no system-wide hooks.

---

**中文**: [README.md](README.md)
