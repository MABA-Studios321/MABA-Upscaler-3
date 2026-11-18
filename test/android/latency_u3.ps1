# Input-to-glass latency of the test app on the phone, per configuration.
#
#   powershell -ExecutionPolicy Bypass -File latency_u3.ps1 [-Taps 40] [-Preset 1]
#
# For every configuration the app is launched with --ei lat 1, `input tap` is injected at random intervals, and the app logs
# (tag MABA, "LAT ...") for each tap:
#   touch_to_sample        the tap's event time to the start of the first real-slot frame after it (Android input
#                          delivery plus waiting for the next frame: where a game would read its input)
#   first_visible_present  from that frame start to the first presented frame that carries the new real frame
#   real_present           ... to the first presented frame that IS the real frame
#   gpu_done_to_present    the platform's wait between the GPU finishing the frame and the panel presenting it
# "Present" is EGL_DISPLAY_PRESENT_TIME_ANDROID: when the frame was handed to the panel, about when its refresh begins.
# NOT included: the touch sensor's own latency and the panel's scan-out and response (add roughly 8 ms for the
# scan-out of a 60 Hz panel on average, plus the sensor), so this is a software latency, not photon latency.
param([int]$Taps = 40, [int]$Preset = 1, [int]$Vsync = 1)
$ErrorActionPreference = "Continue"
$sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" }
$adb = "$sdk\platform-tools\adb.exe"
$pkg = "com.maba.upscaler3"
$configs = @(
    @{ Name = "Frame Gen off";        Extra = @("--ei", "fg", "0") },
    @{ Name = "Extrapolated 2x";      Extra = @("--ei", "fg", "1", "--ei", "fggov", "0") },
    @{ Name = "Extrapolated 3x";      Extra = @("--ei", "fg", "3", "--ei", "fggov", "0") }
)
function Stat([double[]]$v) {
    $s = $v | Sort-Object
    if ($s.Count -eq 0) { return "n/a" }
    $mean = ($s | Measure-Object -Average).Average
    $p50 = $s[[int][Math]::Floor(($s.Count - 1) * 0.5)]
    $p95 = $s[[int][Math]::Floor(($s.Count - 1) * 0.95)]
    return ("{0,6:N1} / {1,6:N1} / {2,6:N1}" -f $mean, $p50, $p95)
}
$rand = New-Object System.Random 7
try {
    foreach ($c in $configs) {
        & $adb shell am force-stop $pkg
        & $adb logcat -c
        & $adb shell am start -n "$pkg/com.maba.upscalertest.MainActivity" --ei preset $Preset --ei vsync $Vsync --ei lat 1 @($c.Extra) | Out-Null
        Start-Sleep 12
        # one shell with all the taps and pauses, so adb start-up does not add to the spacing
        $cmds = for ($i = 0; $i -lt $Taps; $i++) { "input tap 700 400; sleep 0.{0:D2}" -f $rand.Next(55, 95) }
        & $adb shell ($cmds -join "; ") | Out-Null
        Start-Sleep 3
        $lines = & $adb logcat -d -s MABA | Select-String 'LAT touch_to_sample' | ForEach-Object { $_.Line }
        $rows = foreach ($l in $lines) {
            $o = @{}
            foreach ($m in [regex]::Matches($l, '(\w+)=([\-\d\.]+)')) { $o[$m.Groups[1].Value] = [double]$m.Groups[2].Value }
            [pscustomobject]$o
        }
        $rows = @($rows | Select-Object -Skip 2)
        Write-Host ("`n{0}  ({1} taps measured; mean / median / p95, ms)" -f $c.Name, $rows.Count) -ForegroundColor Cyan
        if ($rows.Count -eq 0) {
            & $adb logcat -d -s MABA | Select-String 'LAT frame timestamps' | ForEach-Object { Write-Host $_.Line }
            continue
        }
        Write-Host ("  tap -> sampled by the app        {0}" -f (Stat ($rows | ForEach-Object { $_.touch_to_sample })))
        Write-Host ("  sampled -> first visible on panel {0}" -f (Stat ($rows | ForEach-Object { $_.first_visible_present })))
        Write-Host ("  sampled -> the real frame on panel{0}" -f (Stat ($rows | ForEach-Object { $_.real_present })))
        Write-Host ("  TAP -> FIRST VISIBLE (total)      {0}" -f (Stat ($rows | ForEach-Object { $_.first_visible_total })))
        Write-Host ("  TAP -> REAL FRAME (total)         {0}" -f (Stat ($rows | ForEach-Object { $_.real_total })))
        Write-Host ("  GPU done -> presented             {0}" -f (Stat ($rows | ForEach-Object { $_.gpu_done_to_present })))
    }
} finally {
    & $adb shell am force-stop $pkg
    & $adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 | Out-Null
    Write-Host "`nphone restored to the default launch"
}