# Runs every check that works without a GPU or an engine installation, plus the engine tests when asked.
#
#   powershell -ExecutionPolicy Bypass -File test\run_all.ps1 [-Godot <godot console exe>] [-Unreal56 <UE 5.6 root>] [-Unreal58 <UE 5.8 root>]
#
# Always: shader compile check (glslc from the Android NDK), Frame Gen governor unit test (needs gcc or clang),
# Unity runtime C# type check against a stub UnityEngine, C vs C# parity of the controller and jitter ports
# (needs the .NET SDK). With -Godot: the Godot headless + render tests. With -Unreal5x: a plugin build.
param([string]$Godot = "", [string]$Unreal56 = "", [string]$Unreal58 = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$results = @()
function Step([string]$name, [scriptblock]$body) {
    Write-Host "`n=== $name" -ForegroundColor Cyan
    try { & $body; $script:results += [pscustomobject]@{ Step = $name; Result = "PASS" } }
    catch { Write-Host $_.Exception.Message -ForegroundColor Red; $script:results += [pscustomobject]@{ Step = $name; Result = "FAIL" } }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) "maba_run_all"
New-Item -ItemType Directory -Force $tmp | Out-Null
$cc = (Get-Command gcc -ErrorAction SilentlyContinue), (Get-Command clang -ErrorAction SilentlyContinue) | Where-Object { $_ } | Select-Object -First 1
$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue)
if (-not $dotnet -and (Test-Path "C:\Program Files\dotnet\dotnet.exe")) { $dotnet = Get-Item "C:\Program Files\dotnet\dotnet.exe" }

Step "engine copies match the canonical sources in src/ (and UE4 matches UE5)" {
    $pairs = @(
        @("src\maba_tsr.hlsl", "integrations\unity\com.maba.upscaler3\Runtime\Resources\Maba3Shaders\MabaTsr.hlsl"),
        @("src\maba_fg_warp.hlsl", "integrations\unity\com.maba.upscaler3\Runtime\Resources\Maba3Shaders\MabaFgWarp.hlsl"),
        @("src\maba_upscaler.hlsl", "integrations\unity\com.maba.upscaler3\Runtime\Resources\Maba3Shaders\MabaCore.hlsl"))
    foreach ($ue in "UE5", "UE4") {
        $p = "integrations\unreal\$ue\MabaUpscaler3"
        $pairs += @(
            @("src\maba_tsr.hlsl", "$p\Shaders\MabaTsr.ush"),
            @("src\maba_fg_warp.hlsl", "$p\Shaders\MabaFgWarp.ush"),
            @("src\maba_upscaler.hlsl", "$p\Shaders\MabaCore.ush"),
            @("src\maba_upscaler.h", "$p\Source\MabaUpscaler3\Private\MabaController.h"),
            @("src\maba_temporal.h", "$p\Source\MabaUpscaler3\Private\MabaTemporal.h"))
    }
    $bad = 0
    foreach ($pair in $pairs) {
        if ((Get-FileHash (Join-Path $root $pair[0])).Hash -ne (Get-FileHash (Join-Path $root $pair[1])).Hash) {
            Write-Host "out of sync: $($pair[0]) -> $($pair[1])"; $bad++
        }
    }
    # The two Unreal plugins are the same source except these files (engine-specific by design).
    $differ = @("MabaCompat.h", "MabaUpscaler3.uplugin", "README.md")
    $u5 = Join-Path $root "integrations\unreal\UE5\MabaUpscaler3"; $u4 = Join-Path $root "integrations\unreal\UE4\MabaUpscaler3"
    $rel5 = Get-ChildItem $u5 -Recurse -File | ForEach-Object { $_.FullName.Substring($u5.Length) }
    $rel4 = Get-ChildItem $u4 -Recurse -File | ForEach-Object { $_.FullName.Substring($u4.Length) }
    foreach ($x in (Compare-Object $rel5 $rel4)) { Write-Host "only in one Unreal plugin: $($x.InputObject)"; $bad++ }
    foreach ($rel in $rel5) {
        if ($differ -contains (Split-Path $rel -Leaf) -or -not (Test-Path ($u4 + $rel))) { continue }
        if ((Get-FileHash ($u5 + $rel)).Hash -ne (Get-FileHash ($u4 + $rel)).Hash) { Write-Host "UE4 / UE5 differ: $rel"; $bad++ }
    }
    if ($bad) { throw "$bad engine copy(ies) differ from src/ or between UE4 and UE5 (copy the canonical file over)" }
}
Step "shader compile (all variants incl. engine wrappers)" { & (Join-Path $PSScriptRoot "compile_shaders.ps1") | Select-Object -Last 1 }

Step "Frame Gen governor unit test" {
    if (-not $cc) { throw "no gcc/clang on PATH" }
    $exe = Join-Path $tmp "test_governor.exe"
    & $cc.Source -O1 -o $exe (Join-Path $PSScriptRoot "native\test_governor.c")
    if ($LASTEXITCODE -ne 0) { throw "compile failed" }
    $out = & $exe
    $out | Select-Object -Last 3 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or ($out -match "FAIL")) { throw "governor test failed" }
}

Step "Unity runtime C# type check (hand-written stub, used to run the logic checks)" {
    if (-not $dotnet) { throw "dotnet SDK not found" }
    & $dotnet.Source build (Join-Path $PSScriptRoot "unity_stub\unity_stub.csproj") -nologo -v q
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
}

Step "Unity runtime + Editor scripts compile against the REAL UnityEngine 2021.3 API" {
    if (-not $dotnet) { throw "dotnet SDK not found" }
    $ref = & (Join-Path $PSScriptRoot "unity_real\fetch_unity_api.ps1") | Select-Object -Last 1
    foreach ($p in "unity_real.csproj", "unity_editor.csproj") {
        & $dotnet.Source build (Join-Path $PSScriptRoot "unity_real\$p") -nologo -v q "-p:UnityRefDir=$ref"
        if ($LASTEXITCODE -ne 0) { throw "$p failed" }
    }
}
Step "Unity settings API logic checks (stub UnityEngine)" {
    if (-not $dotnet) { throw "dotnet SDK not found" }
    $out = & $dotnet.Source run --project (Join-Path $PSScriptRoot "unity_logic\unity_logic.csproj") -nologo -v q
    $out | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or ($out -match "FAIL")) { throw "settings checks failed" }
}

Step "C vs C# parity (rung table, mode rungs, Halton, 6000-frame dynamic run)" {
    if (-not $cc -or -not $dotnet) { throw "needs gcc/clang and the dotnet SDK" }
    $cexe = Join-Path $tmp "parity_c.exe"
    & $cc.Source -O1 -o $cexe (Join-Path $PSScriptRoot "parity\parity_c.c")
    $a = & $cexe
    $b = & $dotnet.Source run --project (Join-Path $PSScriptRoot "parity\parity_cs.csproj") -nologo -v q
    if ($a.Count -ne $b.Count) { throw "line count differs: C $($a.Count), C# $($b.Count)" }
    $bad = 0
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -eq $b[$i]) { continue }
        # float printing may differ in the last digit; compare numbers with a 2e-6 tolerance
        $ta = $a[$i] -split ' '; $tb = $b[$i] -split ' '
        $same = $ta.Count -eq $tb.Count
        if ($same) { for ($k = 0; $k -lt $ta.Count; $k++) {
            if ($ta[$k] -ne $tb[$k]) { $x = 0.0; $y = 0.0
                if (-not ([double]::TryParse($ta[$k], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x) -and [double]::TryParse($tb[$k], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$y) -and [Math]::Abs($x - $y) -le 2e-6)) { $same = $false } } } }
        if (-not $same) { $bad++; if ($bad -le 5) { Write-Host "differs: C '$($a[$i])'  C# '$($b[$i])'" } }
    }
    if ($bad -gt 0) { throw "$bad line(s) differ" }
    Write-Host "$($a.Count) lines identical (within 2e-6)"
}

if ($Godot) {
    Step "Godot addon (headless + settings + render + moving camera + Frame Generation)" {
        & (Join-Path $root "integrations\godot\test\run_godot_tests.ps1") -Godot $Godot -Render -Moving -Fg | Select-Object -Last 14
    }
}
foreach ($ue in @(@{ Root = $Unreal56; Name = "5.6" }, @{ Root = $Unreal58; Name = "5.8" })) {
    if (-not $ue.Root) { continue }
    Step "Unreal plugin build, UE $($ue.Name)" {
        $out = Join-Path $tmp ("ue" + $ue.Name)
        if (Test-Path $out) { Remove-Item -Recurse -Force $out }
        $log = & (Join-Path $ue.Root "Engine\Build\BatchFiles\RunUAT.bat") BuildPlugin "-Plugin=$root\integrations\unreal\UE5\MabaUpscaler3\MabaUpscaler3.uplugin" "-Package=$out" -TargetPlatforms=Win64 -Rocket 2>&1 | ForEach-Object { "$_" }
        if (-not ($log -match "BUILD SUCCESSFUL")) { $log | Where-Object { $_ -match "error" } | Select-Object -First 5 | ForEach-Object { Write-Host $_ }; throw "build failed" }
    }
}

Write-Host "`n=== Summary" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host
if ($results | Where-Object { $_.Result -eq "FAIL" }) { exit 1 }