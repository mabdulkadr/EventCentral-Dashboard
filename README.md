# 📊 EventCentral — Multi-Device Event Monitor

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey.svg)
![GUI](https://img.shields.io/badge/UI-Web%20Dashboard-purple.svg)
![Version](https://img.shields.io/badge/version-1.0-green.svg)


[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-☕-FFDD00?style=for-the-badge)](https://www.buymeacoffee.com/mabdulkadrx)


A **multi-device Windows Event Log monitoring platform** that collects events from your PC and remote servers (WinRM), discovers **all** event logs, and displays them in an interactive browser dashboard. Events accumulate forever — every scan merges new events into the archive without deleting old data.

> ✅ No agents &nbsp;·&nbsp; ✅ No databases &nbsp;·&nbsp; ✅ No dependencies &nbsp;·&nbsp; 🔒 Your data stays on your machine


---


## 🚀 Features


### Core Collection Engine
- **Incremental with catch-up** — every scan re-covers the look-back window; devices that fell behind start from their stored position, so no events are lost
- **Never deletes data** — `events.json` grows into a complete historical archive
- **Deduplication** — unique key `Time + EventID + Log + Machine + MD5(message hash)` prevents duplicates even for same-second events
- **Multi-device** — collect from localhost + remote servers via WinRM (`Invoke-Command`)
- **Full log discovery** — `Get-WinEvent -ListLog *` finds every log that contains events
- **Scan scope** — `Basic` (standard logs) / `Advanced` (+ service logs) / `All` (every log)
- **Friendly remote errors** — ACCESS DENIED / WINRM NOT ENABLED / TIMEOUT / NETWORK ERROR classified automatically
- **Resilient merge** — failed devices keep their scan position, so their missed window is re-collected next run


### Dashboard
- **Summary cards** — Total / Critical / Error / Warning / Info
- **Unified time filter** — `15m / 1h / 6h / 24h / 7d / 14d / 30d` presets + custom date pickers
- **Timeline chart** — multi-line Chart.js, events per hour per device, hover-to-filter & click-to-pin
- **Sortable + filterable table** with infinite scroll
- **Dynamic Levels filter** — dropdown only shows levels present in the data, in canonical order
- **Sidebar** — collapsible log tree matching the Event Viewer layout, with live search
- **Device health** — color-coded chips 🟢 Green / 🟠 Orange / 🔴 Red based on thresholds
- **Cross-device shared events** — detect the same Event ID across multiple devices
- **Event History** — click any event to see ALL its past occurrences (chart + average recurrence interval)
- **KB reference** — ~70 built-in entries for common Windows Event IDs
- **Dark / Light theme** — persists via `localStorage`
- **CSV export** — download filtered events
- **Keyboard shortcuts** — `Ctrl+F` Search · `Ctrl+E` Export · `Esc` Close


### Data & Storage
- **`events.json` is the database** — the dashboard reads it first and updates live
- **Embedded snapshot** — the HTML mirrors the archive so it also works offline from disk (`file://`)
- **`last_scan.json`** — per-device scan state for incremental runs


---


## 📋 Requirements


| Requirement | Details |
|-------------|---------|
| **OS** | Windows 10 / 11 / Server 2016+ |
| **PowerShell** | 5.1 or later |
| **Permissions** | Administrator (for Security log + remote scans) |
| **Remote servers** | WinRM enabled: `Enable-PSRemoting -Force` |
| **Browser** | Modern browser (Chrome, Edge, Firefox) |
| **Network** | Internet needed once for Google Fonts + Chart.js CDN |


---


## ▶️ Usage


```powershell
.\Run-EventCentral.ps1
```


Or double-click **Run-EventCentral.ps1** in File Explorer.


### Steps


1. **Configure Settings** — open `Run-EventCentral.ps1` and edit the `⚙️ YOUR SETTINGS` section (devices, hours, scope, thresholds)
2. **Run the Launcher** — collects events and opens the dashboard
3. **Explore** — filter by time, log, device, level; click any event for full details and history
4. **Export** — press `Ctrl+E` to download the filtered rows as CSV


### Configuration Examples


```powershell
# Monitor two remote servers, last 48 hours
.\Run-EventCentral.ps1 -ComputerNames SRV01,SRV02 -Hours 48

# More events per log, advanced scope
.\Run-EventCentral.ps1 -ScanScope Advanced -MaxEventsPerLog 1000

# Skip updating the dashboard HTML
.\Run-EventCentral.ps1 -SkipRefresh

# Custom health thresholds
.\Run-EventCentral.ps1 -CriticalThreshold 3 -ErrorThreshold 10
```

> ⚙️ Any option passed on the command line overrides the value in the settings section.


---


## 🏗️ Architecture


```
EventCentral-Dashboard/
├── Run-EventCentral.ps1           — Launcher + config (edit this one)
├── EventCentral-Collector.ps1     — Collection engine
├── EventCentral-Dashboard.html    — Interactive dashboard UI
├── events.json                    — Event archive (generated)
├── last_scan.json                 — Scan state (generated)
├── README.md                      — Documentation
└── back/                          — Backup copies of old versions
```


### Data Flow


```
Devices (local + WinRM)
        │
        ▼
EventCentral-Collector.ps1 ────► events.json ◄──── (database)
        │                              │
        └──► EventCentral-Dashboard.html ──► Browser
             (embedded snapshot for file://,
              live fetch for http://)
```


---


## 📁 Auto‑Created Files


Files created automatically on each run:


```
events.json      — complete historical event archive
last_scan.json   — per-device scan state for incremental runs
```


---


## 🧠 Auto‑Detection Behavior


When running a scan:
- **Log discovery** — every log containing events is found automatically via `Get-WinEvent -ListLog *`
- **Device default** — if no devices are configured, the local machine is used
- **Level mapping** — numeric event levels are mapped to friendly names (Critical / Error / Warning / Information / Verbose)
- **Machine name normalization** — DNS suffixes are stripped and names uppercased, so `pc-1.corp.local` and `PC-1` resolve to the same device
- **Dashboard refresh** — when enabled, fresh data is injected into the HTML automatically after each collection


---


## ☕ Donate


If you find this project helpful, consider supporting it by  
[buying me a coffee](https://www.buymeacoffee.com/mabdulkadrx).


---


## 📜 License


This project is licensed under the [MIT License](https://opensource.org/licenses/MIT).


---


## 👤 Author


**Mohammad Abdulkader Omar**  
Website: https://momar.tech  
Version: **1.0**


---


## ⚠ Disclaimer


These scripts are provided as-is. Test them in a staging environment before applying them to production. The author is not responsible for any unintended outcomes resulting from their use.
