# GPU time of each Frame Gen slot (real / generated), read from the platform instead of the app.
#
# For every frame it displays, SurfaceFlinger records when the GPU finished it. With the GPU
# saturated (Frame Gen uncapped, a scene too heavy to wait on the panel), the gap between two
# consecutive finish times is the GPU time of the later frame, so the real and generated slots can
# be read separately without a GPU timer query and without trusting the app's own clock. This is
# panel-independent: it works on any Android device.
#
# Usage (one configuration per call):
#   & .\gpu_slots.ps1 -Label "warp, 8 probe taps" -Mode 6
#   & .\gpu_slots.ps1 -Label "4 probe taps" -Mode 6 -Extra '--ei','fgprobe','4'
# Mode: app mode (6 Native, 1 Ultra, 2 Quality, 3 Balanced, 4 Performance). Developer extras that
# help: fgdbg 1 (generated frame = plain copy), fgprobe N, fgnoedge 1.
param(
    [string]$Label = "run",
    [int]$Mode = 6,
    [string[]]$Extra = @(),
    [int]$Snapshots = 3
)
$ErrorActionPreference = "Continue"
$sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" }
$adb = "$sdk\platform-tools\adb.exe"
$pkg = "com.maba.upscalertest"

function Get-Layer {
    $line = & $adb shell dumpsys SurfaceFlinger --list | Where-Object { $_ -match 'SurfaceView\[com\.maba\.upscalertest[^\]]*\]@\d+\(BLAST\)#\d+' } | Select-Object -First 1
    [regex]::Match([string]$line, '(SurfaceView\[[^\]]+\]@\d+\(BLAST\)#\d+)').Groups[1].Value
}

& $adb shell am force-stop $pkg | Out-Null
& $adb logcat -c | Out-Null
& $adb shell am start -n "$pkg/.MainActivity" --ei mode $Mode --ei fg 1 --ei vsync 0 @Extra | Out-Null
for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Seconds 3; if (& $adb logcat -d -s MABA:I | Select-String 'ONSCREEN.*Frame Gen') { break } }
Start-Sleep -Seconds 6
$layer = Get-Layer
$real = New-Object System.Collections.Generic.List[double]
$gen = New-Object System.Collections.Generic.List[double]
for ($s = 0; $s -lt $Snapshots; $s++) {
    $raw = & $adb shell "dumpsys SurfaceFlinger --latency '$layer'"
    $ready = @($raw | Select-Object -Skip 1 | Where-Object { $_ -match '^\s*\d+\s+\d+\s+\d+' } | ForEach-Object {
        $p = ($_ -split '\s+') | Where-Object { $_ -ne '' }; [int64]$p[2] } | Where-Object { $_ -gt 0 -and $_ -lt 9000000000000000000 })
    $d = @(for ($i = 1; $i -lt $ready.Count; $i++) { ($ready[$i] - $ready[$i - 1]) / 1e6 })
    # Slots alternate. Split by parity and call the slower parity the real slot.
    $ev = @(); $od = @()
    for ($i = 0; $i -lt $d.Count; $i++) { if ($d[$i] -gt 0 -and $d[$i] -lt 90) { if ($i % 2 -eq 0) { $ev += $d[$i] } else { $od += $d[$i] } } }
    $me = ($ev | Measure-Object -Average).Average; $mo = ($od | Measure-Object -Average).Average
    $real.Add([math]::Max($me, $mo)); $gen.Add([math]::Min($me, $mo))
    if ($s -lt $Snapshots - 1) { Start-Sleep -Seconds 2 }
}
$r = ($real | Measure-Object -Average).Average; $g = ($gen | Measure-Object -Average).Average
$line = & $adb logcat -d -s MABA:I | Select-String 'ONSCREEN' | Select-Object -Last 1
$shown = if ($line -match 'shown ([\d\.]+)') { $Matches[1] } else { "?" }
Write-Host ("{0,-34} real slot {1,5:N1} ms | generated slot {2,5:N1} ms | pair {3,5:N1} ms | app counts {4} shown fps" -f $Label, $r, $g, ($r + $g), $shown)
& $adb shell am force-stop $pkg | Out-Null
