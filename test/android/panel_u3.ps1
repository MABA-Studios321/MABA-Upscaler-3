# Measures what the PANEL really shows (SurfaceFlinger latch record) for MABA Upscaler 3.
#
#   powershell -ExecutionPolicy Bypass -File panel_u3.ps1 [-Presets 1,3] [-Vsync 1] [-Fg 0,1]
#
# Presets: 0 Performance, 1 Balanced, 2 Balance Lite, 3 Quality, 4 Ultra Quality.
# For each preset and Frame Gen state: launches the app, waits, reads which frames reached the glass.
param(
    [int[]]$Presets = @(1),
    [int]$Vsync = 1,
    [int[]]$Fg = @(0, 1),
    [int]$Settle = 10,
    [int]$Windows = 3,
    [string[]]$AppExtra = @()
)
$ErrorActionPreference = "Continue"
$sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" }
$adb = "$sdk\platform-tools\adb.exe"
$pkg = "com.maba.upscaler3"
$names = @("Performance", "Balanced", "Balance Lite", "Quality", "Ultra Quality")

function Get-Layer {
    $line = & $adb shell dumpsys SurfaceFlinger --list | Where-Object { $_ -match 'SurfaceView\[com\.maba\.upscaler3[^\]]*\]@\d+\(BLAST\)#\d+' } | Select-Object -First 1
    return [regex]::Match([string]$line, '(SurfaceView\[[^\]]+\]@\d+\(BLAST\)#\d+)').Groups[1].Value
}

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
    $gaps = @()
    for ($i = 1; $i -lt $t.Count; $i++) { $g = ($t[$i] - $t[$i - 1]) / 1e6; if ($g -lt 120) { $gaps += $g } }
    $sum = ($gaps | Measure-Object -Sum).Sum
    $vs = 1000.0 / 60.0
    $sorted = @($gaps | Sort-Object)
    [pscustomobject]@{
        Fps = 1000.0 * $gaps.Count / $sum
        OneVs = 100.0 * @($gaps | Where-Object { [math]::Round($_ / $vs) -le 1 }).Count / $gaps.Count
        TwoVs = 100.0 * @($gaps | Where-Object { [math]::Round($_ / $vs) -eq 2 }).Count / $gaps.Count
        MoreVs = 100.0 * @($gaps | Where-Object { [math]::Round($_ / $vs) -ge 3 }).Count / $gaps.Count
        P95 = $sorted[[math]::Min($sorted.Count - 1, [int]($sorted.Count * 0.95))]
    }
}

foreach ($pr in $Presets) {
    foreach ($fg in $Fg) {
        & $adb shell am force-stop $pkg | Out-Null
        & $adb logcat -c | Out-Null
        & $adb shell am start -n "$pkg/com.maba.upscalertest.MainActivity" --ei preset $pr --ei vsync $Vsync --ei fg $fg @AppExtra | Out-Null
        Start-Sleep -Seconds ($Settle + 6)
        $r = Measure-Panel (Get-Layer)
        if ($r) {
            Write-Host ("{0,-13} FG {1,-3} VSync {2,-3} | PANEL {3,5:N1} fps | gaps {4,3:N0}% 1-vsync {5,3:N0}% 2-vsync {6,3:N0}% 3+ | p95 {7:N1} ms" -f `
                $names[$pr], $(if ($fg) { "ON" } else { "off" }), $(if ($Vsync) { "on" } else { "OFF" }), $r.Fps, $r.OneVs, $r.TwoVs, $r.MoreVs, $r.P95)
        } else {
            Write-Host ("{0,-13} FG {1,-3}: no frames recorded" -f $names[$pr], $fg)
        }
    }
}
& $adb shell am force-stop $pkg | Out-Null
& $adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 | Out-Null
