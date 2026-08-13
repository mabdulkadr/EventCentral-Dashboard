<#
.SYNOPSIS
    EventCentral Collector — Core engine for Windows Event Log collection.

.DESCRIPTION
    Collects Windows Event Log data from local and remote devices (WinRM)
    and stores it in a structured JSON file consumed by the EventCentral dashboard.

    Run via:  .\Run-EventCentral.ps1  (the launcher wrapper)
    Or directly for CLI / scheduled-task usage.

    Key behaviours:
      - Always scans the recent look-back window (default 7 days) each run, so the
        dashboard's 15m / 1h / 6h / 24h / 7d / 14d / 30d filters have fresh data.
      - Never deletes old data — events.json accumulates into a historical archive.
      - Deduplication key: Time + EventID + LogName + MachineName + message hash.
      - Device health colour-coded: Critical / Warning / OK.

    Output files (in -OutputPath):
      events.json      — structured event data (accumulated)
      last_scan.json   — scan state for incremental runs

.INPUTS
    None. This script takes parameters only.

.OUTPUTS
    Writes events.json (and last_scan.json) to -OutputPath.

.EXAMPLE
    .\EventCentral-Collector.ps1

    Default scan. Collects the last 7 days (168 hours) of events per device
    and merges them into events.json (re-collected events are deduplicated).

.EXAMPLE
    .\EventCentral-Collector.ps1 -ComputerNames SVR01,SVR02 -Hours 48

    Scan two remote devices over the last 48 hours.

.EXAMPLE
    .\EventCentral-Collector.ps1 -ComputerNames SVR01 -Credential (Get-Credential)

    Scan a remote device with alternate WinRM credentials.

.EXAMPLE
    .\EventCentral-Collector.ps1 -ScanScope Advanced -MaxEventsPerLog 1000 -ThrottleLimit 5

    Advanced scope with a higher per-log limit and 5 parallel remote connections.

.EXAMPLE
    .\EventCentral-Collector.ps1 -RefreshDashboard

    After collection, inject fresh data into EventCentral-Dashboard.html
    so it shows the latest events when opened directly from disk.

.NOTES
    Requires Windows PowerShell 5.1+. Run as Administrator for Security log
    and remote collection. Remote targets need WinRM (Enable-PSRemoting -Force).
    
    For daily use, run the launcher:  .\Run-EventCentral.ps1

.PARAMETER ComputerNames
    Devices to scan. Default: local machine.
    Remote devices are queried via Invoke-Command (WinRM).

.PARAMETER Hours
    Look-back window in hours. Default: 168 (7 days). The collector always scans
    at least this window so the dashboard time filters always have fresh data.

.PARAMETER MaxEventsPerLog
    Maximum events collected per individual log (per device). Default: 500.

.PARAMETER ScanScope
    Which logs to include:
      Basic    — Windows standard logs (Application, Security, System, Setup, ForwardedEvents)
      Advanced — Basic + common Microsoft service logs (DNS, GPO, PowerShell, Firewall, ...)
      All      — every log that contains events
    Default: All.

.PARAMETER Credential
    Alternate credentials used for remote WinRM connections.

.PARAMETER Incremental
    Kept for backward compatibility (no-op). The collector always scans the
    recent look-back window and deduplicates against the existing archive.

.PARAMETER RefreshDashboard
    After collecting events, inject the fresh JSON data into the
    EventCentral-Dashboard.html file so that it shows the latest data
    when opened directly from disk (file:// protocol).

.PARAMETER CriticalThreshold
    Number of Critical events per device that marks its health as CRITICAL.
    Default: 5.

.PARAMETER ErrorThreshold
    Number of Error events per device that marks its health as WARNING.
    Default: 20.

.PARAMETER OutputPath
    Directory where events.json and last_scan.json are written.
    Default: script directory.

.PARAMETER ThrottleLimit
    Maximum number of parallel remote connections to the same device.
    Default: 10.
#>

[CmdletBinding()]
param(
    [string[]]     $ComputerNames     = @(),
    [int]          $Hours             = 168,
    [int]          $MaxEventsPerLog   = 500,
    [ValidateSet('Basic', 'Advanced', 'All')]
    [string]       $ScanScope         = 'All',
    [pscredential] $Credential,
    [switch]       $Incremental,
    [switch]       $RefreshDashboard,
    [int]          $CriticalThreshold = 5,
    [int]          $ErrorThreshold    = 20,
    [string]       $OutputPath        = '',
    [int]          $ThrottleLimit     = 10
)

# ═══════════════════════════════════════════════════════════════
#  SECTION 1  —  Configuration & Initial Setup
# ═══════════════════════════════════════════════════════════════

$ErrorActionPreference = 'SilentlyContinue'

# ── Helpers ────────────────────────────────────────────────
function ConvertTo-NormalName {
    # Normalizes machine names to a single canonical case so that
    # 'PC-1' (from the successful list) and 'pc-1' (from an event MachineName)
    # always resolve to the same key in stats/health rendering.
    # Also strips the DNS suffix (e.g. 'PC-1.corp.local' -> 'PC-1') so remote
    # events whose MachineName is a FQDN still match the short device names
    # configured in Run-EventCentral.ps1.
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $hostname = $Name
    $dot = $Name.IndexOf('.')
    if ($dot -gt 0) { $hostname = $Name.Substring(0, $dot) }
    return $hostname.ToUpperInvariant()
}

function Get-EventDedupKey {
    # Dedup key = Time + EventID + LogName + MachineName + message hash.
    # The message hash distinguishes two distinct events that share the
    # same second/ID/log/machine (e.g. two 4625 failures in one second).
    param($Event)
    $msgHash = ''
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Event.mf)
        $md5   = [System.Security.Cryptography.MD5]::Create()
        try {
            $msgHash = [System.BitConverter]::ToString($md5.ComputeHash($bytes)).Replace('-', '')
        }
        finally { $md5.Dispose() }
    }
    catch {}
    return "$($Event.t)|$($Event.id)|$($Event.ln)|$($Event.mn)|$msgHash"
}

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$startTime  = (Get-Date).AddHours(-$Hours)
$genTimeStr = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$scriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = $scriptDir
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}

# File paths
$jsonFile     = Join-Path $OutputPath 'events.json'
$stateFile    = Join-Path $OutputPath 'last_scan.json'

# Default devices if none specified
if (-not $ComputerNames -or $ComputerNames.Count -eq 0) {
    $ComputerNames = @($env:COMPUTERNAME)
}

# Log scope definitions
$BASIC_LOGS         = @('Application', 'Security', 'System', 'Setup', 'ForwardedEvents')
$ADVANCED_PREFIXES  = @(
    'Microsoft-Windows-DNS',
    'Microsoft-Windows-GroupPolicy',
    'Microsoft-Windows-PowerShell',
    'Microsoft-Windows-TaskScheduler',
    'Microsoft-Windows-Windows Firewall',
    'Microsoft-Windows-Windows Defender',
    'Microsoft-Windows-WindowsUpdateClient',
    'Microsoft-Windows-AppLocker',
    'Microsoft-Windows-Bits-Client',
    'Microsoft-Windows-PrintService',
    'Microsoft-Windows-TerminalServices',
    'Microsoft-Windows-CodeIntegrity',
    'Windows PowerShell',
    'HardwareEvents',
    'Microsoft-Windows-WMI'
)

# ═══════════════════════════════════════════════════════════════
#  SECTION 2  —  Incremental Scan State
# ═══════════════════════════════════════════════════════════════

$existingEvents = [System.Collections.Generic.List[PSObject]]::new()

if (Test-Path -LiteralPath $jsonFile) {
    try {
        $old = Get-Content -LiteralPath $jsonFile -Raw | ConvertFrom-Json
        foreach ($evt in $old.data) {
            $evt.mn = ConvertTo-NormalName $evt.mn
            $null = $existingEvents.Add([PSCustomObject]$evt)
        }
        Write-Host "  Loaded $($existingEvents.Count) existing events" -ForegroundColor Cyan
    }
    catch {
        Write-Host "  Could not load existing events, starting fresh" -ForegroundColor Yellow
    }
}

$lastRunTime = $null
$perDeviceLast = @{}
if (Test-Path -LiteralPath $stateFile) {
    try {
        $lastState   = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($lastState.PSObject.Properties['lastRunTime']) {
            $lastRunTime = [datetime]$lastState.lastRunTime
        }
        if ($lastState.PSObject.Properties['perDevice']) {
            foreach ($p in $lastState.perDevice.PSObject.Properties) {
                $perDeviceLast[$p.Name.ToUpperInvariant()] = [datetime]$p.Value
            }
        }
    }
    catch {}
}
if (-not $lastRunTime) {
    $lastRunTime = $startTime
}

# ═══════════════════════════════════════════════════════════════
#  SECTION 3  —  Console Banner
# ═══════════════════════════════════════════════════════════════

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  EventCentral v1.0 — Event Log Collector' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Targets    : $($ComputerNames -join ', ')"
Write-Host "  Since      : last $Hours hours per device (catch-up if a device fell behind)"
Write-Host "  Scope      : $ScanScope"
Write-Host ''

# ═══════════════════════════════════════════════════════════════
#  SECTION 4  —  Remote Collection Script Block
# ═══════════════════════════════════════════════════════════════

$remoteSB = {
    param($start, $max, $scope, $basic, $advPre)

    $levelMap = @{
        0 = 'Information'
        1 = 'Critical'
        2 = 'Error'
        3 = 'Warning'
        4 = 'Information'
        5 = 'Verbose'
    }

    $results = [System.Collections.Generic.List[PSObject]]::new()

    $logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
        Where-Object { $_.RecordCount -gt 0 }

    if ($scope -eq 'Basic') {
        $logs = $logs | Where-Object { $_.LogName -in $basic }
    }
    elseif ($scope -eq 'Advanced') {
        $logs = $logs | Where-Object {
            $n = $_.LogName
            if ($n -in $basic) { return $true }
            foreach ($p in $advPre) {
                if ($n.StartsWith($p)) { return $true }
            }
            return $false
        }
    }

    foreach ($lg in $logs) {
        try {
            $evts = Get-WinEvent -FilterHashtable @{
                LogName   = $lg.LogName
                StartTime = $start
            } -MaxEvents $max -ErrorAction Stop

            foreach ($e in $evts) {
                $lv = $e.LevelDisplayName
                if (-not $lv) {
                    $li = [int]$e.Level
                    $lv = if ($levelMap[$li]) { $levelMap[$li] } else { 'Unknown' }
                }

                $mf = if ($e.Message) { $e.Message } else { '(No message)' }
                $ms = if ($mf.Length -gt 500) { $mf.Substring(0, 500) + '...' } else { $mf }

                $null = $results.Add([PSCustomObject]@{
                    t  = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                    id = $e.Id
                    lv = $lv
                    ln = $e.LogName
                    sr = $e.ProviderName
                    ms = $ms
                    mf = $mf
                    mn = $e.MachineName
                })
            }
        }
        # Silently skip logs that can't be read (access denied, no events, etc.).
        # We don't write warnings here because this runs inside a remote script
        # block and extra output would corrupt the returned event object stream.
        catch {}
    }

    $results
}

# ═══════════════════════════════════════════════════════════════
#  SECTION 5  —  Main Collection Loop
# ═══════════════════════════════════════════════════════════════

$allEvents   = [System.Collections.Generic.List[PSObject]]::new()
$successList = [System.Collections.Generic.List[string]]::new()
$failedList  = [System.Collections.Generic.List[PSObject]]::new()
$usedStartByDevice = @{}
$levelMap    = @{
    0 = 'Information'
    1 = 'Critical'
    2 = 'Error'
    3 = 'Warning'
    4 = 'Information'
    5 = 'Verbose'
}

foreach ($computer in $ComputerNames) {
    $normComputer = ConvertTo-NormalName $computer
    $isLocal = (
        $computer -eq $env:COMPUTERNAME -or
        $computer -eq 'localhost' -or
        $computer -eq '.' -or
        $computer -eq '127.0.0.1'
    )

    # Scan window. Use the device's last successful scan time as the start
    # point so subsequent runs are incremental (only fetch new events since
    # the previous scan). If the device has never been scanned, or its last
    # scan falls outside the look-back window, start from minStart so the
    # dashboard's time filters always have fresh data. Re-collected events
    # are removed by deduplication in the merge step, so the archive stays
    # stable.
    $minStart  = (Get-Date).AddHours(-$Hours)
    $devStart  = $minStart
    if ($perDeviceLast.ContainsKey($normComputer) -and $perDeviceLast[$normComputer] -gt $devStart) {
        $devStart = $perDeviceLast[$normComputer]
    }
    $usedStartByDevice[$normComputer] = $devStart

    Write-Host "  [$computer] Collecting..." -ForegroundColor Cyan

    $cnt = 0
    try {
        if ($isLocal) {
            # ── Local collection (inline, proven reliable) ──
            $allLogs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue |
                Where-Object { $_.RecordCount -gt 0 }

            if ($ScanScope -eq 'Basic') {
                $allLogs = $allLogs | Where-Object { $_.LogName -in $BASIC_LOGS }
            }
            elseif ($ScanScope -eq 'Advanced') {
                $allLogs = $allLogs | Where-Object {
                    $n = $_.LogName
                    if ($n -in $BASIC_LOGS) { return $true }
                    foreach ($p in $ADVANCED_PREFIXES) {
                        if ($n.StartsWith($p)) { return $true }
                    }
                    return $false
                }
            }

            foreach ($lg in $allLogs) {
                try {
                    $evts = Get-WinEvent -FilterHashtable @{
                        LogName   = $lg.LogName
                        StartTime = $devStart
                    } -MaxEvents $MaxEventsPerLog -ErrorAction Stop

                    foreach ($e in $evts) {
                        $lv = $e.LevelDisplayName
                        if ([string]::IsNullOrWhiteSpace($lv)) {
                            $li = [int]$e.Level
                            $lv = if ($levelMap[$li]) { $levelMap[$li] } else { 'Unknown' }
                        }

                        $mf = if ($e.Message) { $e.Message } else { '(No message)' }
                        $ms = if ($mf.Length -gt 500) { $mf.Substring(0, 500) + '...' } else { $mf }

                        $null = $allEvents.Add([PSCustomObject]@{
                            t  = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                            id = $e.Id
                            lv = $lv
                            ln = $e.LogName
                            sr = $e.ProviderName
                            ms = $ms
                            mf = $mf
                            mn = ConvertTo-NormalName $e.MachineName
                        })
                        $cnt++
                    }
                }
                catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -notlike '*No events were found*' -and $errMsg -notlike '*NoMatchingEventsFound*') {
                        Write-Host "    WARNING: [$computer] log '$($lg.LogName)': $errMsg" -ForegroundColor Yellow
                    }
                }
            }
        }
        else {
            # ── Remote collection (WinRM) ──
            $splat = @{
                ComputerName   = $computer
                ScriptBlock    = $remoteSB
                ArgumentList   = $devStart, $MaxEventsPerLog, $ScanScope, $BASIC_LOGS, $ADVANCED_PREFIXES
                ErrorAction    = 'Stop'
                ThrottleLimit  = $ThrottleLimit
            }
            if ($Credential) {
                $splat.Credential = $Credential
            }

            $remoteEvents = Invoke-Command @splat
            foreach ($e in $remoteEvents) {
                $e.mn = ConvertTo-NormalName $e.mn
                if ([string]::IsNullOrWhiteSpace($e.mn)) { $e.mn = $normComputer }
                if ($e.mn.Length -gt 50)                { $e.mn = $normComputer }
                $null = $allEvents.Add($e)
                $cnt++
            }
        }

        $null = $successList.Add($normComputer)
        Write-Host "    [$computer] OK — $cnt events" -ForegroundColor Green
    }
    catch {
        $errMsg = $_.Exception.Message

        # Classify common WinRM errors into user-friendly messages
        if ($errMsg -like '*Access is denied*' -or $errMsg -like '*AccessDenied*') {
            $errMsg = 'ACCESS DENIED — Run as Administrator or check WinRM permissions'
        }
        elseif ($errMsg -like '*WinRM cannot*' -or $errMsg -like '*WS-Management*') {
            $errMsg = 'WINRM NOT ENABLED — Run: Enable-PSRemoting -Force'
        }
        elseif ($errMsg -like '*timeout*' -or $errMsg -like '*TimedOut*') {
            $errMsg = 'TIMEOUT — Device unreachable or firewall blocking'
        }
        elseif ($errMsg -like '*network path*' -or $errMsg -like '*RPC server*') {
            $errMsg = 'NETWORK ERROR — Check connectivity and DNS'
        }

        if ($errMsg.Length -gt 200) {
            $errMsg = $errMsg.Substring(0, 200)
        }

        $null = $failedList.Add(@{ name = $computer; reason = $errMsg })
        Write-Host "    [$computer] FAIL: $errMsg" -ForegroundColor Red
    }
}

# ═══════════════════════════════════════════════════════════════
#  SECTION 6  —  Incremental Merge & Deduplication
# ═══════════════════════════════════════════════════════════════

if ($existingEvents.Count -gt 0) {
    $seen   = @{}
    $merged = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($e in $existingEvents) {
        $key = Get-EventDedupKey $e
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $null = $merged.Add($e)
        }
    }
    foreach ($e in $allEvents) {
        $key = Get-EventDedupKey $e
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $null = $merged.Add($e)
        }
    }

    $allEvents = $merged
    Write-Host "  Merged (deduplicated): $($allEvents.Count) total events" -ForegroundColor Cyan
}

# ═══════════════════════════════════════════════════════════════
#  SECTION 7  —  Sort + Statistics + Indexes
# ═══════════════════════════════════════════════════════════════

# Sort newest-first (t is always 'yyyy-MM-dd HH:mm:ss', so string sort == chrono sort)
$sorted = $allEvents | Sort-Object t -Descending
$allEvents.Clear()
foreach ($e in $sorted) { $null = $allEvents.Add($e) }

# Per-device statistics
$computerStats = @{}
foreach ($evt in $allEvents) {
    $mn = $evt.mn
    if (-not $computerStats.ContainsKey($mn)) {
        $computerStats[$mn] = @{
            total       = 0
            Critical    = 0
            Error       = 0
            Warning     = 0
            Information = 0
            Verbose     = 0
            Unknown     = 0
        }
    }
    $computerStats[$mn].total++
    $lv = $evt.lv
    if ($computerStats[$mn].ContainsKey($lv)) {
        $computerStats[$mn][$lv]++
    }
    else {
        $computerStats[$mn]['Unknown']++
    }
}

# Aggregation indexes for the dashboard
$eventsByHour    = @{}
$eventsByMachine = @{}
$eventsByLog     = @{}
$eidCount        = @{}

foreach ($evt in $allEvents) {
    if ($evt.t -and $evt.t.Length -ge 13) {
        $hk = $evt.t.Substring(0, 13) + ':00'
        if ($eventsByHour.ContainsKey($hk)) { $eventsByHour[$hk]++ } else { $eventsByHour[$hk] = 1 }
    }

    $mn = $evt.mn
    if ($eventsByMachine.ContainsKey($mn)) { $eventsByMachine[$mn]++ } else { $eventsByMachine[$mn] = 1 }

    $ln = $evt.ln
    if ($eventsByLog.ContainsKey($ln))     { $eventsByLog[$ln]++ }     else { $eventsByLog[$ln]     = 1 }

    $ek = [string]$evt.id
    if ($eidCount.ContainsKey($ek))        { $eidCount[$ek]++ }        else { $eidCount[$ek]        = 1 }
}

$topIds = $eidCount.GetEnumerator() |
    Sort-Object Value -Descending |
    Select-Object -First 20 |
    ForEach-Object { @{ id = [int]$_.Key; count = $_.Value } }

# ═══════════════════════════════════════════════════════════════
#  SECTION 8  —  Build Structured JSON
# ═══════════════════════════════════════════════════════════════

$metadataObj = @{
    scanStartTime     = $genTimeStr
    scanEndTime       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    hours             = $Hours
    scanScope         = $ScanScope
    incremental       = $true
    totalEvents       = $allEvents.Count
    computers         = @{
        successful = @($successList)
        failed     = @($failedList)
    }
    stats             = $computerStats
    criticalThreshold = $CriticalThreshold
    errorThreshold    = $ErrorThreshold
}

$indexesObj = @{
    eventsByHour    = $eventsByHour
    eventsByMachine = $eventsByMachine
    eventsByLog     = $eventsByLog
    topEventIds     = @($topIds)
}

$jsonArray  = @($allEvents | ForEach-Object {
    @{
        t  = $_.t
        id = $_.id
        lv = $_.lv
        ln = $_.ln
        sr = $_.sr
        ms = $_.ms
        mf = $_.mf
        mn = $_.mn
    }
})

$jsonOutput = @{
    metadata = $metadataObj
    indexes  = $indexesObj
    data     = $jsonArray
} | ConvertTo-Json -Depth 5 -Compress

$safeJson = $jsonOutput.Replace('</', '<\/')

# Save JSON data files
$jsonOutput | Out-File -LiteralPath $jsonFile -Encoding UTF8 -Force
if (-not (Test-Path -LiteralPath $jsonFile) -or (Get-Item -LiteralPath $jsonFile).Length -eq 0) {
    Write-Host '  ERROR: Failed to write events.json (is the file locked or disk full?)' -ForegroundColor Red
}
# Advance per-device scan state only for devices that succeeded.
# Failed devices keep their previous start time so the skipped window
# is re-collected on the next run instead of being lost forever.
foreach ($computer in $ComputerNames) {
    $normComputer = ConvertTo-NormalName $computer
    if ($successList.Contains($normComputer)) {
        $perDeviceLast[$normComputer] = $metadataObj.scanEndTime
    }
    elseif (-not $perDeviceLast.ContainsKey($normComputer)) {
        # Never succeeded before: pin it to the start time it used so the
        # missed window is preserved even though it cannot be scanned yet.
        $perDeviceLast[$normComputer] = $usedStartByDevice[$normComputer].ToString('yyyy-MM-dd HH:mm:ss')
    }
}

$perDeviceStr = @{}
foreach ($k in $perDeviceLast.Keys) {
    $v = $perDeviceLast[$k]
    if ($v -is [datetime]) { $perDeviceStr[$k] = $v.ToString('yyyy-MM-dd HH:mm:ss') }
    else                    { $perDeviceStr[$k] = [string]$v }
}

$stateObj = @{ perDevice = $perDeviceStr }
if ($successList.Count -gt 0) {
    $stateObj.lastRunTime = $metadataObj.scanEndTime
}
else {
    $stateObj.lastRunTime = $lastRunTime.ToString('yyyy-MM-dd HH:mm:ss')
}
$stateObj |
    ConvertTo-Json -Compress |
    Out-File -LiteralPath $stateFile -Encoding UTF8 -Force

# ═══════════════════════════════════════════════════════
#  SECTION 9  —  Console Summary
# ═══════════════════════════════════════════════════════

Write-Host ''
Write-Host "  JSON saved: $jsonFile" -ForegroundColor Green
Write-Host "  Total events: $($allEvents.Count) | Devices OK: $($successList.Count) | Failed: $($failedList.Count)" -ForegroundColor Cyan
Write-Host ''

if ($RefreshDashboard) {
    $dashPath = Join-Path $OutputPath 'EventCentral-Dashboard.html'
    if (Test-Path -LiteralPath $dashPath) {
        Write-Host '  Refreshing embedded data in dashboard.html...' -ForegroundColor Cyan
        try {
            $dashContent = [System.IO.File]::ReadAllText($dashPath, [System.Text.UTF8Encoding]::new($false))

            # Locate the embedded data block. The HTML uses:
            #     var RAW_DATA = {...}, META = {}, IDX = {}, DATA = [], ...
            $markerStart = 'var RAW_DATA = '
            $si = $dashContent.IndexOf($markerStart)
            if ($si -lt 0) {
                $markerStart = 'var RAW_DATA='
                $si = $dashContent.IndexOf($markerStart)
            }
            $ei = -1
            if ($si -ge 0) {
                $si += $markerStart.Length
                $needle = ', META = {}, IDX = {}, DATA = []'
                $ei = $dashContent.IndexOf($needle, $si)
                while ($ei -gt 0) {
                    $candidate = $dashContent.Substring($si, $ei - $si)
                    try { $null = $candidate | ConvertFrom-Json; break } catch {}
                    $ei = $dashContent.IndexOf($needle, $ei + 1)
                }
            }

            if ($ei -gt 0) {
                $newContent = $dashContent.Substring(0, $si) + $safeJson + $dashContent.Substring($ei)
                [System.IO.File]::WriteAllText($dashPath, $newContent, (New-Object System.Text.UTF8Encoding($true)))
                Write-Host '  Dashboard embedded data refreshed.' -ForegroundColor Green
            }
            else {
                Write-Host '  WARNING: Could not locate embedded data boundary in dashboard.html' -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  WARNING: Could not refresh dashboard.html — $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '  WARNING: dashboard.html not found in output path' -ForegroundColor Yellow
    }
}

Write-Host '  Done!' -ForegroundColor Green