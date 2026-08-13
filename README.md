# ⚡ EventCentral — Multi-Device Event Monitor

Monitor **Windows Event Logs** on your PC and remote servers, and view everything in a beautiful **browser dashboard**.

✅ No agents &nbsp;·&nbsp; ✅ No databases &nbsp;·&nbsp; ✅ No dependencies &nbsp;·&nbsp; 🔒 Your data stays on your machine

---

## 🚀 Quick Start

```powershell
.\Run-EventCentral.ps1
```

That's it! The script:

1. 📥 Collects events from your devices (last 24 hours by default)
2. 💾 Saves them into `events.json`
3. 🖥️ Opens the dashboard in your browser

---

## 📁 Files

| File | What it does |
|------|--------------|
| ⚙️ `Run-EventCentral.ps1` | **The only file you edit.** Contains all your settings. |
| 🧠 `EventCentral-Collector.ps1` | The engine — collects events and saves them. |
| 📊 `EventCentral-Dashboard.html` | The dashboard — charts, filters, event history. |
| 📦 `events.json` | Your event archive (created automatically). |
| 📋 `last_scan.json` | Scan state for faster incremental runs (automatic). |
| 🗄️ `back/` | Backup copies of old versions. |

---

## 🎛️ How to Configure

Open **`Run-EventCentral.ps1`**, look for the **`⚙️ YOUR SETTINGS`** section, and change the values you want:

| Setting | Variable | Default | Simple explanation |
|---------|----------|---------|--------------------|
| 🖥️ Devices | `$config_ComputerNames` | `@($env:COMPUTERNAME)` | Which machines to monitor |
| ⏱️ Look-back | `$config_Hours` | `24` | How far back (in hours) to collect |
| 📦 Events per log | `$config_MaxEventsPerLog` | `500` | Max events per log (stops big files) |
| 🗂️ Scan scope | `$config_ScanScope` | `'All'` | `Basic` / `Advanced` / `All` logs |
| 🔄 Refresh dashboard | `$config_RefreshDashboard` | `$true` | Update the HTML after each scan |
| 🔴 Critical threshold | `$config_CriticalThreshold` | `5` | Critical events above this → device RED |
| 🟠 Error threshold | `$config_ErrorThreshold` | `20` | Error events above this → device ORANGE |
| ⚡ Throttle limit | `$config_ThrottleLimit` | `10` | Parallel remote connections (speed) |

> 💡 Save the file, then run `.\Run-EventCentral.ps1` again — your new settings apply.

---

## 🧪 Usage Examples

```powershell
# Default run — uses your settings
.\Run-EventCentral.ps1

# Monitor two remote servers, last 48 hours
.\Run-EventCentral.ps1 -ComputerNames SRV01,SRV02 -Hours 48

# More logs per log, advanced scope
.\Run-EventCentral.ps1 -ScanScope Advanced -MaxEventsPerLog 1000

# Skip updating the dashboard HTML
.\Run-EventCentral.ps1 -SkipRefresh

# Custom health thresholds
.\Run-EventCentral.ps1 -CriticalThreshold 3 -ErrorThreshold 10
```

> ⚙️ Any option you pass on the command line **overrides** the setting in the file.

---

## 🔁 How It Works (in 6 simple steps)

1. 🔍 **Discover** — finds every event log on each device
2. 📥 **Collect** — pulls events from the last scan window
3. 🔑 **Deduplicate** — skips events already in the archive (no duplicates!)
4. 💾 **Merge** — adds new events to `events.json` (old data is never deleted)
5. 📄 **Refresh** — embeds fresh data into the dashboard HTML
6. 🖥️ **Open** — launches the dashboard in your browser

---

## ✨ Dashboard Features

### 📊 Charts & Data
- **Summary cards** — Total / Critical / Error / Warning / Info
- **Timeline chart** — events per hour, one line per device
- **Sortable table** with search + infinite scroll
- **Event History** — click any event to see all its past occurrences

### 🎛️ Filters
- **Time filter** — `15m / 1h / 6h / 24h / 7d / 14d / 30d` + custom dates
- **Level filter** — only shows levels that have events
- **Search** — `Ctrl+F` to search, `Ctrl+E` to export CSV
- **Device filter** — checkboxes in the sidebar

### 🖥️ Sidebar
- **Log tree** — same layout as Windows Event Viewer
- **Device health** — 🟢 Green / 🟠 Orange / 🔴 Red chips
- **Shared events** — same Event ID found on multiple devices

### 🛠️ Extras
- 📚 **KB reference** — built-in descriptions for common Event IDs
- 🌗 **Dark / Light theme** — remembers your choice
- 📤 **CSV export** — download filtered events
- ⌨️ **Keyboard shortcuts** — `Ctrl+F` Search · `Ctrl+E` Export · `Esc` Close

---

## 📦 The Data Files

### `events.json` — your archive

```json
{
  "metadata": { "totalEvents": 34164, "hours": 24, "scanScope": "All" },
  "indexes":   { "eventsByHour": { "2026-08-13 13:00:00": 42 } },
  "data": [
    {
      "t":  "2026-08-13 13:22:11",
      "id": 4624,
      "lv": "Information",
      "ln": "Security",
      "sr": "Microsoft-Windows-Security-Auditing",
      "ms": "An account was successfully logged on...",
      "mf": "Full message...",
      "mn": "SRV01"
    }
  ]
}
```

**Event fields:**

| Field | Meaning |
|-------|---------|
| `t` | 🕒 Time of the event |
| `id` | 🔢 Windows Event ID |
| `lv` | 🏷️ Level (Critical / Error / Warning / Info...) |
| `ln` | 📁 Log name |
| `sr` | 🧩 Source / provider |
| `ms` | ✂️ Short message (first 500 chars) |
| `mf` | 📜 Full message |
| `mn` | 🖥️ Machine name |

### `last_scan.json` — scan state

```json
{
  "lastRunTime": "2026-08-13 14:05:29",
  "perDevice": { "SRV01": "2026-08-13 14:05:29" }
}
```

Used to know where each device stopped, so the next scan only collects **new** events.

---

## 🖥️ Requirements

| Requirement | Details |
|-------------|---------|
| 🪟 OS | Windows 10 / 11 / Server 2016+ |
| 🟦 PowerShell | 5.1 or later |
| 🛡️ Permissions | Run as **Administrator** |
| 🌐 Remote servers | WinRM enabled: `Enable-PSRemoting -Force` |
| 🌍 Browser | Chrome, Edge or Firefox |
| 📶 Network | Internet needed once for fonts + Chart.js |

---

## 🆘 Troubleshooting

| 😕 Problem | ✅ Solution |
|-----------|------------|
| ACCESS DENIED | Run as Administrator, check WinRM permissions |
| WINRM NOT ENABLED | Run `Enable-PSRemoting -Force` on the target |
| TIMEOUT | Check firewall, network, DNS |
| Dashboard empty | Re-run `.\Run-EventCentral.ps1` to refresh data |
| Charts not showing | Check internet (Chart.js needs it once) |
| Old data after run | Make sure `$config_RefreshDashboard = $true` |

---

## 📜 License

MIT — free to use, modify, and distribute. 💙
