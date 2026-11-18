# Builds maba-upscaler-test.apk without Gradle, using the Android SDK command-line tools.
#
# Usage:  powershell -ExecutionPolicy Bypass -File build.ps1 [-Install]
#
# Needs: Android SDK (build-tools and a platform), a JDK 11 or newer, and the debug keystore that
# Android Studio creates at %USERPROFILE%\.android\debug.keystore.
# Override the defaults with the environment variables ANDROID_SDK_ROOT and JAVA_HOME.
param([switch]$Install)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)      # repository root
$out  = "$here\build"
$apk  = "$out\maba-upscaler-test.apk"

$sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" }
$jdk = if ($env:JAVA_HOME -and (Test-Path "$env:JAVA_HOME\bin\javac.exe")) { $env:JAVA_HOME }
       else { "C:\Program Files\Android\Android Studio\jbr" }
if (-not (Test-Path "$sdk\build-tools")) { throw "Android SDK not found at $sdk (set ANDROID_SDK_ROOT)" }
if (-not (Test-Path "$jdk\bin\javac.exe")) { throw "JDK not found at $jdk (set JAVA_HOME)" }

# NDK: newest installed, for the JNI bridge (real C controller + GPU timer queries).
$ndk = (Get-ChildItem "$sdk\ndk" -Directory | Sort-Object { [version]$_.Name } | Select-Object -Last 1).FullName
$clang = "$ndk\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe"
if (-not (Test-Path $clang)) { throw "NDK clang not found at $clang" }

# Newest installed build-tools and numbered platform.
$bt  = (Get-ChildItem "$sdk\build-tools" -Directory | Sort-Object { [version]($_.Name -replace '[^\d\.].*$','') } | Select-Object -Last 1).FullName
$jar = (Get-ChildItem "$sdk\platforms" -Directory | Where-Object { $_.Name -match '^android-\d+$' } |
        Sort-Object { [int]($_.Name -replace 'android-','') } | Select-Object -Last 1).FullName + "\android.jar"
$keystore = "$env:USERPROFILE\.android\debug.keystore"
if (-not (Test-Path $keystore)) { throw "Debug keystore not found at $keystore" }

function Check($what) { if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)" } }

if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force "$out\assets", "$out\classes", "$out\dex" | Out-Null

# Assets: the upscalers themselves and the test shaders.
Copy-Item "$root\src\maba_upscaler.frag.glsl", "$root\src\maba_upscaler.vert.glsl", "$root\src\maba_temporal.frag.glsl", "$root\src\maba_framegen.frag.glsl", "$root\src\maba_temporal_sr.frag.glsl" "$out\assets"
Copy-Item "$here\shaders\*.glsl" "$out\assets"

& "$bt\aapt2.exe" compile --dir "$here\res" -o "$out\res.zip"
Check "aapt2 compile"
& "$bt\aapt2.exe" link -o "$out\unsigned.apk" -I $jar --manifest "$here\AndroidManifest.xml" -A "$out\assets" --rename-manifest-package com.maba.upscaler3 "$out\res.zip"
Check "aapt2"

# Native JNI bridge for arm64-v8a and armeabi-v7a.
foreach ($abi in @("arm64-v8a", "armeabi-v7a")) {
    $target = if ($abi -eq "arm64-v8a") { "aarch64-linux-android26" } else { "armv7a-linux-androideabi26" }
    New-Item -ItemType Directory -Force "$out\lib\$abi" | Out-Null
    & $clang --target=$target -O2 -shared -Wall -I"$here\jni" `
        -o "$out\lib\$abi\libmaba_jni.so" "$here\jni\maba_jni.c" -lGLESv3 -lEGL -llog
    Check "clang $abi"
}

$sources = Get-ChildItem -Recurse "$here\src" -Filter *.java | ForEach-Object { $_.FullName }
& "$jdk\bin\javac.exe" -nowarn -source 8 -target 8 -cp $jar -d "$out\classes" $sources
Check "javac"

$classes = Get-ChildItem -Recurse "$out\classes" -Filter *.class | ForEach-Object { $_.FullName }
& "$jdk\bin\java.exe" -cp "$bt\lib\d8.jar" com.android.tools.r8.D8 --lib $jar --min-api 26 --output "$out\dex" $classes
Check "d8"

Push-Location "$out\dex"
& "$bt\aapt.exe" add "$out\unsigned.apk" classes.dex | Out-Null
Pop-Location
Check "aapt add"

Push-Location $out
& "$bt\aapt.exe" add "$out\unsigned.apk" lib/arm64-v8a/libmaba_jni.so lib/armeabi-v7a/libmaba_jni.so | Out-Null
Pop-Location
Check "aapt add libs"

& "$bt\zipalign.exe" -f -p 4 "$out\unsigned.apk" "$out\aligned.apk"
Check "zipalign"

& "$jdk\bin\java.exe" -jar "$bt\lib\apksigner.jar" sign --ks $keystore `
    --ks-pass pass:android --key-pass pass:android --ks-key-alias androiddebugkey --out $apk "$out\aligned.apk"
Check "apksigner"

"Built $apk"
if ($Install) {
    & "$sdk\platform-tools\adb.exe" install -r $apk
    Check "adb install"
}
