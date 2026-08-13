<#
.SYNOPSIS
    EventCentral — collect Windows events, then open the dashboard.

.DESCRIPTION
    This is the launcher AND your configuration file.
    All settings (devices, look-back window, log scope, thresholds, ...)
    live in the "⚙️ YOUR SETTINGS" section below.
    It runs EventCentral-Collector.ps1 to collect event logs,
    then opens the interactive HTML dashboard in your browser.

    Files in this folder:
      Run-EventCentral.ps1         Launcher + config (this file)
      EventCentral-Collector.ps1   Engine (collect & store events)
      EventCentral-Dashboard.html  Interactive dashboard
      events.json                  Event archive (generated)
      last_scan.json               Scan state (generated)

.EXAMPLE
    .\Run-EventCentral.ps1

    Collect events from the configured devices and open the dashboard.

.EXAMPLE
    .\Run-EventCentral.ps1 -ComputerNames SRV01,SRV02 -Hours 48

    Scan two remote servers over the last 48 hours.

.EXAMPLE
    .\Run-EventCentral.ps1 -ScanScope Advanced -MaxEventsPerLog 2000

    Scan Advanced scope, up to 2000 events per log.
#>

[CmdletBinding()]
param(
    # ── Command-line parameters (optional) ────────────────────
    # You don't need to touch anything here.
    # Settings come from the "⚙️ YOUR SETTINGS" section below.
    # These parameters are only used when you pass arguments on the
    # command line, e.g.:
    #     .\Run-EventCentral.ps1 -ComputerNames SRV01,SRV02 -Hours 48
    [string[]]  $ComputerNames,
    [int]       $Hours,
    [int]       $MaxEventsPerLog,
    [ValidateSet('Basic', 'Advanced', 'All')]
    [string]    $ScanScope,
    [switch]    $RefreshDashboard,
    [switch]    $SkipRefresh,
    [int]       $CriticalThreshold,
    [int]       $ErrorThreshold,
    [int]       $ThrottleLimit
)

# ══════════════════════════════════════════════════════════════
#  ⚙️  YOUR SETTINGS — change only this section
# ══════════════════════════════════════════════════════════════
#  This is the ONLY file you need to edit.
#  Change a value below, save the file, then run:
#      .\Run-EventCentral.ps1
# ══════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────
# 1) COMPUTER NAMES — devices to monitor
# ──────────────────────────────────────────────────────────────
#   List each device name in single quotes '...', separated by commas.
#
#   Examples:
#     @($env:COMPUTERNAME)        <- this PC only (default)
#     @('SRV01', 'SRV02')         <- two servers
#     @('PC-1', 'PC-2', 'PC-3')   <- several PCs
#
#   Note: remote devices need WinRM + Administrator rights:
#     Enable-PSRemoting -Force
$config_ComputerNames = @($env:COMPUTERNAME)  # this PC only (default)

# ──────────────────────────────────────────────────────────────
# 2) LOOK-BACK WINDOW — how far back to collect events
# ──────────────────────────────────────────────────────────────
#   Value is in HOURS. Multiply days by 24.
#
#   Examples:
#     24   -> last 1 day     <- default
#     168  -> last 7 days
#     720  -> last 30 days
$config_Hours = 24

# ──────────────────────────────────────────────────────────────
# 3) MAX EVENTS PER LOG (per device)
# ──────────────────────────────────────────────────────────────
#   Cap per log so busy logs don't bloat the data file.
#   Raise it if you want more events from busy logs.
#
#   Examples:   500 (default)   1000   2000
$config_MaxEventsPerLog = 500

# ──────────────────────────────────────────────────────────────
# 4) SCAN SCOPE — which logs to collect
# ──────────────────────────────────────────────────────────────
#   'Basic'    -> standard logs only (Application, Security, System...)
#   'Advanced' -> Basic + common service logs (PowerShell, DNS, Firewall...)
#   'All'      -> every log that contains events   <- default
$config_ScanScope = 'All'

# ──────────────────────────────────────────────────────────────
# 5) REFRESH DASHBOARD — auto-update the HTML after collection
# ──────────────────────────────────────────────────────────────
#   $true  -> update EventCentral-Dashboard.html with fresh data
#             (recommended — dashboard always shows the latest events)
#   $false -> keep the HTML file unchanged
$config_RefreshDashboard = $true

# ──────────────────────────────────────────────────────────────
# 6) DEVICE HEALTH THRESHOLDS (dashboard colors)
# ──────────────────────────────────────────────────────────────
#   Critical events > threshold  -> device RED
#   Error events    > threshold  -> device ORANGE
#   Otherwise                    -> device GREEN
#
#   Examples:   5 / 20 (default)    10 / 50    3 / 10
$config_CriticalThreshold = 5
$config_ErrorThreshold    = 20

# ──────────────────────────────────────────────────────────────
# 7) THROTTLE LIMIT — parallel remote connections (WinRM)
# ──────────────────────────────────────────────────────────────
#   Higher = faster when monitoring many remote devices.
#
#   Examples:   10 (default)   20   50
$config_ThrottleLimit = 10

# ══════════════════════════════════════════════════════════════
#  DO NOT change anything below this line.
#  It runs the collection and opens the dashboard automatically.
# ══════════════════════════════════════════════════════════════

# ── Merge settings ───────────────────────────────────────────
# If a value is passed on the command line (e.g. -Hours 48) it wins
# over the config above. A normal run (.\Run-EventCentral.ps1)
# only uses the settings from the section above.
$ComputerNames     = if ($PSBoundParameters.ContainsKey('ComputerNames'))     { $ComputerNames }     else { $config_ComputerNames }
$Hours             = if ($PSBoundParameters.ContainsKey('Hours'))             { $Hours }             else { $config_Hours }
$MaxEventsPerLog   = if ($PSBoundParameters.ContainsKey('MaxEventsPerLog'))   { $MaxEventsPerLog }   else { $config_MaxEventsPerLog }
$ScanScope         = if ($PSBoundParameters.ContainsKey('ScanScope'))         { $ScanScope }         else { $config_ScanScope }
$CriticalThreshold = if ($PSBoundParameters.ContainsKey('CriticalThreshold')) { $CriticalThreshold } else { $config_CriticalThreshold }
$ErrorThreshold    = if ($PSBoundParameters.ContainsKey('ErrorThreshold'))    { $ErrorThreshold }    else { $config_ErrorThreshold }
$ThrottleLimit     = if ($PSBoundParameters.ContainsKey('ThrottleLimit'))     { $ThrottleLimit }     else { $config_ThrottleLimit }

# Should we refresh the dashboard? (default: yes)
$doRefresh = $config_RefreshDashboard
if ($SkipRefresh)      { $doRefresh = $false }
if ($RefreshDashboard) { $doRefresh = $true }

# ── Paths ──────────────────────────────────────────────────
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

$collector = Join-Path $scriptDir 'EventCentral-Collector.ps1'
$dashboard = Join-Path $scriptDir 'EventCentral-Dashboard.html'

# ── Validate ───────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $collector)) {
    Write-Host "  ERROR: Collector not found: $collector" -ForegroundColor Red
    Write-Host "  Make sure EventCentral-Collector.ps1 is in the same folder." -ForegroundColor Yellow
    exit 1
}

# ── Banner ─────────────────────────────────────────────────
$days = [math]::Round($Hours / 24, 1)
Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '   EventCentral — Multi-Device Event Monitor'          -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '  Current settings:' -ForegroundColor White
Write-Host "    Devices     : $($ComputerNames -join ', ')" -ForegroundColor Green
Write-Host "    Look-back   : last $days day(s) ($Hours hours)" -ForegroundColor Green
Write-Host "    Scope       : $ScanScope   |  Max events per log: $MaxEventsPerLog" -ForegroundColor Green
Write-Host "    Thresholds  : Critical > $CriticalThreshold  |  Error > $ErrorThreshold" -ForegroundColor Green
Write-Host "    Refresh dashboard: $doRefresh" -ForegroundColor Green
Write-Host ''

# ── Run Collector ──────────────────────────────────────────

$collectorArgs = @{
    ComputerNames     = $ComputerNames
    Hours             = $Hours
    MaxEventsPerLog   = $MaxEventsPerLog
    ScanScope         = $ScanScope
    RefreshDashboard  = $doRefresh
    CriticalThreshold = $CriticalThreshold
    ErrorThreshold    = $ErrorThreshold
    ThrottleLimit     = $ThrottleLimit
    OutputPath        = $scriptDir
}

& $collector @collectorArgs

# ── Open Dashboard ─────────────────────────────────────────
if (Test-Path -LiteralPath $dashboard) {
    Write-Host ''
    Write-Host '  Opening EventCentral dashboard...' -ForegroundColor Cyan
    $opened = $false
    try   { Start-Process -LiteralPath $dashboard; $opened = $true }
    catch { }
    if (-not $opened) {
        try   { [System.Diagnostics.Process]::Start($dashboard) | Out-Null; $opened = $true }
        catch { }
    }
    if (-not $opened) {
        try   { cmd /c start '' $dashboard 2>$null; $opened = $true }
        catch { }
    }
    if ($opened) {
        Write-Host '  Dashboard opened in your browser.' -ForegroundColor Green
    }
    else {
        Write-Host "  Could not open browser automatically." -ForegroundColor Yellow
        Write-Host "  Open this file manually: $dashboard" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  WARNING: Dashboard not found: $dashboard" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  All done.' -ForegroundColor Green
Write-Host ''
