# Builds the app and installs it on the connected phone, with timeouts (a plain `adb install` can sit
# forever waiting for a confirmation on the phone).
#   powershell -ExecutionPolicy Bypass -File deploy.ps1
param([string]$Serial = "")
$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" }
$adb = "$sdk\platform-tools\adb.exe"
$tmp = [System.IO.Path]::GetTempPath()

$p = Start-Process powershell -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "$here\build.ps1") `
    -RedirectStandardOutput "$tmp\maba_build.out" -RedirectStandardError "$tmp\maba_build.err" -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(300000)) { $p.Kill(); throw "build timed out" }
$log = (Get-Content "$tmp\maba_build.out", "$tmp\maba_build.err" -ErrorAction SilentlyContinue)
$log | Where-Object { $_ -match 'error|Built' } | Select-Object -First 15 | ForEach-Object { Write-Host $_ }
if (-not ($log | Where-Object { $_ -match '^Built' })) { throw "build failed" }

$target = if ($Serial) { @("-s", $Serial) } else { @() }
$q = Start-Process $adb -ArgumentList ($target + @("install", "-r", "$here\build\maba-upscaler-test.apk")) `
    -RedirectStandardOutput "$tmp\maba_inst.out" -RedirectStandardError "$tmp\maba_inst.err" -PassThru -WindowStyle Hidden
if (-not $q.WaitForExit(120000)) { $q.Kill(); throw "install timed out (confirm the install on the phone?)" }
Get-Content "$tmp\maba_inst.out" | Select-Object -Last 1 | ForEach-Object { Write-Host $_ }
