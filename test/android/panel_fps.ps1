# Measures what the PANEL really shows, independent of the app's own counters.
#
# SurfaceFlinger keeps a record of every frame it latched and put on the display. This script
# launches the test app in each configuration, waits for the start-up benchmark to finish, and
# reads that record: frames per second on the glass and how evenly they are spaced.
#
# Usage:  powershell -ExecutionPolicy Bypass -File panel_fps.ps1 [-Modes 6,1,2,3,4] [-Vsync 1]
#   -Modes   app modes: 1 Ultra, 2 Quality, 3 Balanced, 4 Performance, 5 Bilinear, 6 Native, 7 Temporal
#   -Vsync   1 = locked to the panel (default, the normal way to play); 0 = uncapped
# Each mode is measured with Frame Gen off and (where supported) on.
param(
    [int[]]$Modes = @(6, 1, 2, 3, 4),
    [int]$Vsync = 1,
    [int]$Settle = 8,
    [int]$Windows = 3,
    [switch]$QuickStart,     # developer shortcut: skip the start-up benchmark (scene load 0, lighter scene)
    [string[]]$AppExtra = @()   # extra intent extras for the app, e.g. '--ei','tsr','0' (old Temporal path)
)
$ErrorActionPreference = "Continue"
$sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" }
$adb = "$sdk\platform-tools\adb.exe"
$pkg = "com.maba.upscalertest"
$names = @{ 1 = "Ultra Quality"; 2 = "Quality"; 3 = "Balanced"; 4 = "Performance"; 5 = "Bilinear"; 6 = "Native"; 7 = "Temporal" }

function Get-Layer {
    $line = & $adb shell dumpsys SurfaceFlinger --list | Where-Object { $_ -match 'SurfaceView\[com\.maba\.upscalertest[^\]]*\]@\d+\(BLAST\)#\d+' } | Select-Object -First 1
    $m = [regex]::Match([string]$line, '(SurfaceView\[[^\]]+\]@\d+\(BLAST\)#\d+)')
    return $m.Groups[1].Value
}

# One snapshot of the latch record: the actual-present time of each frame that reached the panel.
function Get-Presents([string]$layer) {
    $raw = & $adb shell "dumpsys SurfaceFlinger --latency '$layer'"
    $raw | Select-Object -Skip 1 | Where-Object { $_ -match '^\s*\d+\s+\d+\s+\d+' } | ForEach-Object {
        $p = ($_ -split '\s+') | Where-Object { $_ -ne '' }
        [int64]$p[1]
    } | Where-Object { $_ -gt 0 -and $_ -lt 9000000000000000000 }
}

function Measure-Panel([string]$layer) {
    $all = New-Object System.Collections.Generic.SortedSet[int64]
    for ($w = 0; $w -lt $Windows; $w++) {
        foreach ($t in (Get-Presents $layer)) { [void]$all.Add($t) }
        if ($w -lt $Windows - 1) { Start-Sleep -Milliseconds 2300 }
    }
    $t = @($all)
    if ($t.Count -lt 30) { return $null }
    $gaps = for ($i = 1; $i -lt $t.Count; $i++) { ($t[$i] - $t[$i - 1]) / 1e6 }
    # Snapshots are separated by sleeps, so a gap that spans the sleep is not a real gap: only
    # count gaps inside a snapshot (anything over 120 ms is a seam, not a frame).
    $gaps = @($gaps | Where-Object { $_ -lt 120 })
    $sum = ($gaps | Measure-Object -Sum).Sum
    $vs = 1000.0 / 60.0
    $one = @($gaps | Where-Object { [math]::Round($_ / $vs) -le 1 }).Count
    $two = @($gaps | Where-Object { [math]::Round($_ / $vs) -eq 2 }).Count
    $more = @($gaps | Where-Object { [math]::Round($_ / $vs) -ge 3 }).Count
    $sorted = @($gaps | Sort-Object)
    $p95 = $sorted[[math]::Min($sorted.Count - 1, [int]($sorted.Count * 0.95))]
    [pscustomobject]@{
        Fps = 1000.0 * $gaps.Count / $sum
        OneVs = 100.0 * $one / $gaps.Count
        TwoVs = 100.0 * $two / $gaps.Count
        MoreVs = 100.0 * $more / $gaps.Count
        P95 = $p95
        N = $gaps.Count
    }
}

$results = @()
foreach ($mode in $Modes) {
    foreach ($fg in @(0, 1)) {
        & $adb shell am force-stop $pkg | Out-Null
        & $adb logcat -c | Out-Null
        if ($fg -eq 1 -and $mode -eq 7) { continue }           # Frame Gen is not offered for the Temporal mode
        $startExtras = @(); if ($QuickStart) { $startExtras = @('--ei', 'qcfast', '1') }; $startExtras += $AppExtra
        & $adb shell am start -n "$pkg/.MainActivity" --ei mode $mode --ei vsync $Vsync --ei fg $fg @startExtras | Out-Null
        # Wait for the start-up benchmark to finish: the app then logs one ONSCREEN line a second.
        $claim = $null; $deadline = (Get-Date).AddSeconds(240)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $lines = & $adb logcat -d -s MABA:I | Where-Object { $_ -match 'ONSCREEN' }
            if ($lines) { $claim = ($lines | Select-Object -Last 1); if ($fg -eq 0 -or $claim -match 'Frame Gen') { break } }
        }
        if (-not $claim) { Write-Host "mode $mode fg $fg : app never reached steady state"; continue }
        Start-Sleep -Seconds $Settle
        $claim = (& $adb logcat -d -s MABA:I | Where-Object { $_ -match 'ONSCREEN' } | Select-Object -Last 1)
        $layer = Get-Layer
        $r = Measure-Panel $layer
        $appFps = if ($claim -match 'shown ([\d\.]+)') { [double]$Matches[1] } elseif ($claim -match '= ([\d\.]+) fps') { [double]$Matches[1] } else { [double]::NaN }
        $realFps = if ($claim -match 'real ([\d\.]+)') { [double]$Matches[1] } else { [double]::NaN }
        $row = [pscustomobject]@{
            Mode = $names[$mode]; FrameGen = $(if ($fg) { "ON" } else { "off" }); VSync = $(if ($Vsync) { "on" } else { "OFF" })
            AppReal = $realFps; AppSays = $appFps
            PanelFps = $(if ($r) { [math]::Round($r.Fps, 1) } else { [double]::NaN })
            Even = $(if ($r) { [math]::Round($r.OneVs) } else { [double]::NaN })
            Held = $(if ($r) { [math]::Round($r.TwoVs) } else { [double]::NaN })
            Hitch = $(if ($r) { [math]::Round($r.MoreVs) } else { [double]::NaN })
            P95ms = $(if ($r) { [math]::Round($r.P95, 1) } else { [double]::NaN })
        }
        $results += $row
        Write-Host ("{0,-14} FG {1,-3} VSync {2,-3} | app real {3,5:N1} says {4,5:N1} | PANEL {5,5:N1} fps | gaps: {6,3}% 1-vsync, {7,3}% 2-vsync, {8,3}% 3+ | p95 {9} ms" -f `
            $row.Mode, $row.FrameGen, $row.VSync, $row.AppReal, $row.AppSays, $row.PanelFps, $row.Even, $row.Held, $row.Hitch, $row.P95ms)
    }
}
& $adb shell am force-stop $pkg | Out-Null
""
"Columns: AppReal = real frames/s the app rendered, AppSays = the app's own on-screen number, PANEL = frames/s SurfaceFlinger"
"actually displayed. Gaps are the time between consecutive displayed frames, in 60 Hz refresh intervals."
$results | Format-Table -AutoSize
