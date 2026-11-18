# Runs the app's built-in Frame Gen / upscaler quality check on the phone and prints the results.
#   powershell -ExecutionPolicy Bypass -File fg_quality.ps1 [-Preset 1] [-Extra '--ei','tnoshade','1']
# Frame Gen lines compare each generated frame with a true render of the same instant (PSNR dB; also after a
# 4x4 box filter, which ignores sub-pixel aliasing); upscaler lines compare against a 2x-supersampled render.
param([int]$Preset = 1, [string[]]$Extra = @(), [int]$Timeout = 150, [string]$Serial = "")
$sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" }
$adb = "$sdk\platform-tools\adb.exe"
$s = if ($Serial) { @("-s", $Serial) } else { @() }
$pkg = "com.maba.upscaler3"
& $adb @s shell am force-stop $pkg
& $adb @s logcat -c
& $adb @s shell am start -n "$pkg/com.maba.upscalertest.MainActivity" --ei preset $Preset --ei vsync 1 --ei fg 0 --ei qcauto 1 @Extra | Out-Null
$deadline = (Get-Date).AddSeconds($Timeout)
$lines = @()
while ((Get-Date) -lt $deadline) {
    Start-Sleep 4
    $lines = @(& $adb @s logcat -d | Select-String 'QUALITY ')
    if (@($lines | Where-Object { $_.Line -match 'Image quality' }).Count -ge 1) { Start-Sleep 2; $lines = @(& $adb @s logcat -d | Select-String 'QUALITY '); break }
}
$lines | ForEach-Object { $_.Line.Substring($_.Line.IndexOf('QUALITY') + 8) }
& $adb @s shell am force-stop $pkg
& $adb @s shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 | Out-Null
