# Technical details

## 1. Root cause (verified, not guessed)

Windows identifies a network by a **signature** whose decisive attribute is the **default gateway MAC address**, stored next to every saved profile:

```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Signatures\Unmanaged\<SIGNATURE>
        DefaultGatewayMac = <6 bytes>
```

Measured on the development machine — two consecutive tethering sessions from the **same** phone produced two different fingerprints:

| saved network | created | gateway MAC |
|---|---|---|
| `Network` | 2026-10-09 | `70-3A-A6-AA-30-02` |
| `Network 2` | 2026-10-09 | `68-4A-AE-37-1C-F1` |

Android **re-randomizes the RNDIS adapter MAC on every tethering session**. Windows sees a new gateway MAC, concludes this is a brand-new network, and stores another profile. The name is auto-generated because the connection looks "ethernet-like" (`NameType = 6`) with no DHCP domain name, so Windows falls back to `Network` / `Network N`.

### Two consequences

**1. It cannot be prevented, only taken over.**

The signature's last 64 hex characters are a private hash of the fingerprint. None of the plausible candidates reproduce it (SHA-256/SHA-1 over the MAC in various formats, GUID combinations — about **157 variants tested**), so a profile cannot be pre-seeded in the registry.

What *does* work is renaming the profile the moment Windows creates it. That registry write is picked up by NLA and by the Settings UI **immediately**, with no service restart (verified on Windows 11 22631).

**2. The gateway MAC is the phone itself.**

During a session the gateway MAC equals the phone's RNDIS adapter MAC. That is what this tool uses to *confirm* "this really is a phone", instead of guessing from how the MAC looks.

> An ordinary wired network is named `Network N` for exactly the same reason. Such a profile is **never** touched — see [safety.md](safety.md).

---

## 2. How a phone is identified, and named

No guessing, no heuristics:

| Step | Information used | Notes |
|---|---|---|
| 1 | **USB vendor id** | e.g. vivo/iQOO `2D95`, Xiaomi `2717`, Google `18D1`, Samsung `04E8` — configurable list |
| 2 | **Real parent device** (`DEVPKEY_Device_Parent`) | the adapter's network GUID is resolved to its USB instance, then up to the parent, which carries the **USB serial number** |
| 3 | **Model name** | Android reports its marketing name only in **MTP mode**; that record is a sibling interface sharing the same parent serial, so it matches exactly |
| 4 | **Gateway MAC** | confirms "this session is that phone". Only confirmed MACs are ever acted on |

### Why not the USB port?

**Two different phones plugged into the same USB port share the same `LocationInformation`.** During development this caused one phone to be named after the other.

The **serial number is the primary key**; the port is only a fallback, and only when exactly one device there reports a model.

### Name resolution order

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

`Network N` can never be produced. If two phones would receive the same name, the second gets a ` 2` suffix.

### Device identity has three layers

```
USB\VID_2D95&PID_600A&MI_00\6&1EB7303F&1&0000     <- RNDIS interface (the NIC)
    +- USB\VID_2D95&PID_600A\SERIALNUMBER123      <- parent device, carries the serial (identity key)
USB\VID_2D95&PID_6012&MI_00\6&1EB7303F&1&0000     <- MTP interface (only in the other mode)
    +- USB\VID_2D95&PID_6012\SERIALNUMBER123      <- same serial -> links to the model name
```

The last segment of an interface path (`6&1EB7303F&1&0000`) is a **port path that changes with the port** — it must never be used as identity.

---

## 3. Architecture: event driven, zero polling

One scheduled task, `UsbNetFix-OnPhonePlug`, with four triggers:

| Trigger | Fires when |
|---|---|
| **Kernel-PnP EventID 410 / 400** | a USB device is started/configured (the RNDIS adapter appears) |
| **NetworkProfile EventID 10000-10002** | Windows creates / changes / deletes a network profile |
| **BootTrigger** (30 s delay) | after every boot — safety net |
| **CalendarTrigger** (once a day) | last resort if an event was missed |

Each run is a short-lived process: inspect state, fix what needs fixing, exit. **When nothing happens, nothing runs.**

### Why not a resident watcher?

A long-lived watcher process was repeatedly reclaimed by the host environment during development. Short-lived processes plus event triggers proved far more reliable, and cost nothing while idle.

### Why the Kernel-PnP trigger cannot be narrowed to one device

Windows event queries accept only **equality** on `EventData` (`contains()` is rejected with `The specified query is invalid`), and the USB instance path changes with the port. So the filter matches `EventID=410/400` alone — other USB devices trigger a run too, and the script exits within half a second.

The NetworkProfile trigger is a necessary complement: in practice a phone re-plug produced **no new PnP event**, and only the network-profile event saved the run.

### Measured resource usage

| Situation | Time | Notes |
|---|---|---|
| No phone attached | **0.52 s** | exits before any wait, writes no log line |
| Phone attached | **9.5 s** | 8 s of that is the deliberate settle wait |
| Peak memory | ~180 MB working set | PowerShell interpreter baseline, released on exit |
| CPU while idle | **0** | no polling, no resident process |

### Per-stage cost

| Operation | Time |
|---|---|
| `NP-GetGatewayMac` (ARP) | 741 ms |
| `NP-GetInstanceIdForAdapter` | 451 ms |
| `Get-NetAdapter` | 293 ms |
| `Get-NetConnectionProfile` | 117 ms |
| `NP-GetProfiles` (registry) | 58 ms |
| `NP-GetState` (state.json) | 46 ms |

With event triggering this happens a handful of times a day, not 1440 times.

### Before / after

Before the change: a per-minute polling task — **1440 runs/day**, about 12 s of CPU/day, all of it pointless. Now: **zero idle runs**.

---

## 4. Files and state

```
<install dir>\
    UsbNetFix.cmd          double-click entry
    UsbNetFix.ps1          control panel / CLI
    usbnet-fix.ps1         the fixer (this is what the task runs)
    netprof-lib.ps1        registry + device-identity layer
    tasks.ps1              task registration
    deploy.ps1             one-way deploy
    uninstall.ps1          uninstall
    diag-watcher.ps1       read-only diagnostics
    verify-release.ps1     self check
    config.json            your settings (never overwritten by an upgrade)
    state.json             learned devices + confirmed fingerprints (runtime)
    log\                   run log + diagnostic snapshots
    backup\                registry backups + previous versions
```

### `state.json` is bounded on purpose

```json
{
  "Devices": [
    { "DeviceId": "2D95:SERIALNUMBER123", "Name": "Pixel 8",
      "Model": "Pixel 8", "LastGatewayMac": "5a90e662d5ae",
      "LastSeen": "2026-10-12 18:24:14", "Sessions": 8 }
  ],
  "PhoneGatewayMacs": [ "..." ],
  "GatewayMap": { "<mac>": "<DeviceId>" }
}
```

Android hands out a fresh random gateway MAC every session, so an unbounded list would grow forever. The list is capped (default 64). Evicting the oldest only means that MAC would have to be re-learned if it ever returned, and **the newest MAC of every device is always kept**. Verified: after simulating 100 sessions the list stays at the cap.

---

## 5. Possible optimizations (not implemented)

| Optimization | Gain | Cost |
|---|---|---|
| `NP-GetGatewayMac` costs 741 ms | ~500 ms per run | needs `arp -a` parsing or caching; small gain now that runs are event driven |
| `SettleSeconds` 8 s → 4 s | faster rename | a very slow DHCP setup might rename twice (harmless) |
| Compile to a single exe | start 1.5 s → ~0.1 s, memory 180 MB → ~20 MB | needs a build chain, loses "readable and editable" |
| One CIM call for NIC + IP + gateway | saves 3 slow CIM calls | requires rewriting the identification path, medium risk |

The current design is a reasonable balance of reliability, resource use and maintainability; there is no strong reason to change it.
