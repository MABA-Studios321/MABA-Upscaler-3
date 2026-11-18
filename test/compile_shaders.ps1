# Compile-checks every MABA shader with the NDK glslc: the GLSL builds (GLES / Vulkan), the test
# app shaders, and the HLSL cores
# (via glslc's HLSL front end; fxc is not needed).
# Usage: powershell -ExecutionPolicy Bypass -File test\compile_shaders.ps1 [-NdkVersion 30.0.14904198]
param(
    [string]$NdkVersion = "",
    [string]$SdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "$env:LOCALAPPDATA\Android\Sdk" })
)
$ErrorActionPreference = "Stop"
if (-not $NdkVersion) {
    $NdkVersion = (Get-ChildItem (Join-Path $SdkRoot "ndk") -Directory |
        Sort-Object { [version]$_.Name } | Select-Object -Last 1).Name
}
$glslc = Join-Path $SdkRoot "ndk\$NdkVersion\shader-tools\windows-x86_64\glslc.exe"
if (-not (Test-Path $glslc)) { throw "glslc not found at $glslc" }

$root = Split-Path $PSScriptRoot -Parent
$src = Join-Path $root "src"
$tmp = Join-Path $env:TEMP "maba-shader-check"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Read-Text($path) { [System.IO.File]::ReadAllText($path) }

$frag = Read-Text (Join-Path $src "maba_upscaler.frag.glsl")
$vert = Read-Text (Join-Path $src "maba_upscaler.vert.glsl")
$temporal = Read-Text (Join-Path $src "maba_temporal.frag.glsl")
$temporalSr = Read-Text (Join-Path $src "maba_temporal_sr.frag.glsl")

# ---- GLSL: the core shaders --------------------------------------------------------------------
# glslc cannot emit SPIR-V for "#version 300 es"; the ES 3.0 builds (MABA_GATHER 0, temporal) use
# only ES 3.0 core syntax, so they are validated as 310 es. The real ES 3.0 compile is on-device.
$variants = @(
    @{ Name = "es-vert";            Stage = "vert"; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"; Body = $vert },
    @{ Name = "vulkan-vert";        Stage = "vert"; Header = "#version 450`n#define MABA_VULKAN 1`n"; Env = "vulkan1.0"; Std = "450"; Body = $vert },
    @{ Name = "es31-fast";          Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 1`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "es31-quality";       Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 1`n#define MABA_QUALITY 1`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "es31-fast-highp";    Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 1`n#define MABA_HIGHP 1`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "es31-quality-highp"; Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 1`n#define MABA_QUALITY 1`n#define MABA_HIGHP 1`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "es30-fast";          Stage = "frag"; Header = "#version 310 es`n#define MABA_GATHER 0`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    # Explicit 0 must select the GLES path (the switches are tested by value, not by #ifdef).
    @{ Name = "es31-vulkan0";       Stage = "frag"; Header = "#version 310 es`n#define MABA_VULKAN 0`n#define MABA_HIGHP 0`n"; Env = "opengl"; Std = "310es"; Body = $frag },
    @{ Name = "vulkan-fast";        Stage = "frag"; Header = "#version 450`n#define MABA_VULKAN 1`n#define MABA_GATHER 1`n"; Env = "vulkan1.0"; Std = "450"; Body = $frag },
    @{ Name = "vulkan-quality";     Stage = "frag"; Header = "#version 450`n#define MABA_VULKAN 1`n#define MABA_GATHER 1`n#define MABA_QUALITY 1`n"; Env = "vulkan1.0"; Std = "450"; Body = $frag },
    @{ Name = "es-temporal";        Stage = "frag"; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"; Body = $temporal },
    @{ Name = "vulkan-temporal";    Stage = "frag"; Header = "#version 450`n#define MABA_VULKAN 1`n"; Env = "vulkan1.0"; Std = "450"; Body = $temporal },
    # Per-object motion vectors and the Catmull-Rom history resample (GL only).
    @{ Name = "es-temporal-velocity"; Stage = "frag"; Header = "#version 310 es`n#define MABA_TEMPORAL_VELOCITY 1`n#define MABA_TEMPORAL_SHARP 1`n"; Env = "opengl"; Std = "310es"; Body = $temporal },
    # Temporal super-resolution: accumulates at output resolution (resolve pass + present pass).
    @{ Name = "es-temporal-sr";         Stage = "frag"; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"; Body = $temporalSr },
    @{ Name = "es-temporal-sr-present"; Stage = "frag"; Header = "#version 310 es`n#define MABA_TSR_PRESENT 1`n"; Env = "opengl"; Std = "310es"; Body = $temporalSr }
)

# ---- GLSL: test-app shaders (GLES only) --------------------------------------------------------
$appShaders = Join-Path $root "test\android\shaders"
foreach ($s in @(
        @{ Name = "app-scene3d-vert"; Stage = "vert"; File = "scene3d.vert.glsl" },
        @{ Name = "app-scene3d-frag"; Stage = "frag"; File = "scene3d.frag.glsl" },
        @{ Name = "app-bg";           Stage = "frag"; File = "bg.frag.glsl" },
        @{ Name = "app-pattern";      Stage = "frag"; File = "pattern.frag.glsl" },
        @{ Name = "app-blit";         Stage = "frag"; File = "blit.frag.glsl" })) {
    $variants += @{ Name = $s.Name; Stage = $s.Stage; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"
                    Body = (Read-Text (Join-Path $appShaders $s.File)) }
}

# ---- GLSL: MABA Frame Gen (extrapolation warp) and the motion-vector scene variants
$framegen = Read-Text (Join-Path $src "maba_framegen.frag.glsl")
$variants += @(
    @{ Name = "framegen";              Stage = "frag"; Header = "#version 310 es`n"; Env = "opengl"; Std = "310es"; Body = $framegen },
    @{ Name = "framegen-hi";           Stage = "frag"; Header = "#version 310 es`n#define MABA_FG_COLOR_SEPARATE 1`n"; Env = "opengl"; Std = "310es"; Body = $framegen },
    @{ Name = "app-scene3d-vert-velocity"; Stage = "vert"; Header = "#version 310 es`n#define MABA_VELOCITY 1`n"; Env = "opengl"; Std = "310es"; Body = (Read-Text (Join-Path $root "test\android\shaders\scene3d.vert.glsl")) },
    @{ Name = "app-scene3d-frag-velocity"; Stage = "frag"; Header = "#version 310 es`n#define MABA_VELOCITY 1`n"; Env = "opengl"; Std = "310es"; Body = (Read-Text (Join-Path $root "test\android\shaders\scene3d.frag.glsl")) },
    @{ Name = "app-bg-velocity";       Stage = "frag"; Header = "#version 310 es`n#define MABA_VELOCITY 1`n"; Env = "opengl"; Std = "310es"; Body = (Read-Text (Join-Path $root "test\android\shaders\bg.frag.glsl")) }
)

# ---- HLSL: the cores (via glslc's HLSL front end) ----------------------------------------------
$hlslUpscaler = @'
#include "maba_upscaler.hlsl"
Texture2D T; SamplerState S; float4 Size; float4 P;
float4 Fast(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target { return MabaUpscaleFast(T, S, uv, Size, P); }
float4 Quality(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target { return MabaUpscaleQuality(T, S, uv, Size, P); }
'@
$hlslTemporal = @'
#include "maba_temporal.hlsl"
Texture2D A; Texture2D B; Texture2D C; Texture2D D; SamplerState L; SamplerState N;
float4x4 I; float4x4 Pv; float4 TP; float4 Tx; float4 Rg; float4 Jt;
float4 Frag(float4 pos : SV_Position) : SV_Target { return MabaTemporalResolve(A, B, C, D, L, N, pos.xy, I, Pv, TP, Tx.xy, Rg.xy, Jt.xy); }
'@
$hlslTsr = "#include `"maba_tsr.hlsl`"`n" + @"
Texture2D A; Texture2D B; Texture2D C; Texture2D D; Texture2D E; SamplerState L;
float4x4 I; float4x4 Pv; float4 P; float4 Tx; float4 Rg; float4 Ou; float4 Jt; float4 Dr;
struct PsOut { float4 h : SV_Target0; float4 s : SV_Target1; };
PsOut Resolve(float4 pos : SV_Position)
{
    PsOut r;
#if MABA_TSR_VELOCITY_TEX
    MabaTsrOut o = MabaTsrResolve(A, B, C, D, E, L, pos.xy, P, Tx.xy, Rg.xy, Ou, Jt.xy, Dr.xy);
#else
    MabaTsrOut o = MabaTsrResolve(A, B, C, D, E, L, pos.xy, P, Tx.xy, Rg.xy, Ou, Jt.xy, Dr.xy, I, Pv);
#endif
    r.h = o.hist; r.s = o.shown; return r;
}
float4 Present(float4 pos : SV_Position) : SV_Target { return MabaTsrPresent(A, pos.xy, Ou, Tx.z); }
"@
$variants += @(
    @{ Name = "hlsl-tsr";            Hlsl = $true; Entry = "Resolve"; Body = $hlslTsr },
    @{ Name = "hlsl-tsr-reversed";   Hlsl = $true; Entry = "Resolve"; Body = "#define MABA_TSR_DEPTH_MODE 1`n#define MABA_TSR_Y_DOWN 1`n" + $hlslTsr },
    @{ Name = "hlsl-tsr-camera-vel"; Hlsl = $true; Entry = "Resolve"; Body = "#define MABA_TSR_VELOCITY_TEX 0`n" + $hlslTsr },
    @{ Name = "hlsl-tsr-present";    Hlsl = $true; Entry = "Present"; Body = $hlslTsr }
)
$hlslFgWarp = @"
#include "maba_fg_warp.hlsl"
Texture2D A; Texture2D D; SamplerState L; float4x4 M0; float4x4 M1; float4x4 M2; float4x4 M3; float4 Ou;
float4 Frag(float4 pos : SV_Position) : SV_Target { return MabaFgWarpPresent(A, D, L, pos.xy, Ou, M0, M1, M2, M3, 0.06); }
"@
$variants += @(
    @{ Name = "hlsl-fgwarp";          Hlsl = $true; Entry = "Frag"; Body = $hlslFgWarp },
    @{ Name = "hlsl-fgwarp-reversed"; Hlsl = $true; Entry = "Frag"; Body = "#define MABA_FG_DEPTH_MODE 1`n#define MABA_FG_Y_DOWN 1`n" + $hlslFgWarp }
)
$variants += @(
    @{ Name = "hlsl-fast";     Hlsl = $true; Entry = "Fast";    Body = $hlslUpscaler },
    @{ Name = "hlsl-quality";  Hlsl = $true; Entry = "Quality"; Body = $hlslUpscaler },
    @{ Name = "hlsl-temporal"; Hlsl = $true; Entry = "Frag";    Body = $hlslTemporal }
)

# ---- Engine wrappers: the Unity .shader and Unreal .usf files that call the HLSL core -------------
# Their HLSL bodies are cut out of the engine files and compiled with the core on the include path.
# This checks syntax and types only (engine macros are stubbed); the engines' own compilers have the last word.
$engineRoot = Split-Path -Parent $PSScriptRoot
$unityShaders = Join-Path $engineRoot "integrations\unity\com.maba.upscaler3\Runtime\Resources\Maba3Shaders"
$unrealShaders = Join-Path $engineRoot "integrations\unreal\UE5\MabaUpscaler3\Shaders"   # the UE4 plugin ships the same shader files (run_all checks that)
function Get-UnityBody([string]$file) {
    $text = [System.IO.File]::ReadAllText($file)
    $m = [regex]::Match($text, "HLSLPROGRAM(.*?)ENDHLSL", "Singleline")
    $lines = $m.Groups[1].Value -split "`n" | Where-Object { $_ -notmatch '^\s*#pragma' }
    return ($lines -join "`n")
}
function Get-UnrealBody([string]$file) {
    $text = [System.IO.File]::ReadAllText($file)
    $text = $text -replace '#include "/Engine/Public/Platform.ush"', ''
    $text = $text -replace '#include "/Plugin/MabaUpscaler3/MabaTsr.ush"', '#include "MabaTsr.ush"'
    return $text
}
foreach ($f in @(
    @{ Name = "unity-tsr-vert";         File = "MabaTsr.shader";        Stage = "vert"; Entry = "Vert" },
    @{ Name = "unity-tsr-frag";         File = "MabaTsr.shader";        Stage = "frag"; Entry = "Frag" },
    @{ Name = "unity-tsr-present-vert"; File = "MabaTsrPresent.shader"; Stage = "vert"; Entry = "Vert" },
    @{ Name = "unity-tsr-present-frag"; File = "MabaTsrPresent.shader"; Stage = "frag"; Entry = "Frag" },
    @{ Name = "unity-fgwarp-vert";      File = "MabaFgWarp.shader";     Stage = "vert"; Entry = "Vert" },
    @{ Name = "unity-fgwarp-frag";      File = "MabaFgWarp.shader";     Stage = "frag"; Entry = "Frag" })) {
    $variants += @{ Name = $f.Name; Hlsl = $true; Entry = $f.Entry; HlslStage = $f.Stage; Inc = $unityShaders
        Body = (Get-UnityBody (Join-Path $unityShaders $f.File)) }
}
foreach ($f in @(
    @{ Name = "unreal-tsr";         File = "MabaTsr.usf" },
    @{ Name = "unreal-tsr-present"; File = "MabaTsrPresent.usf" })) {
    $variants += @{ Name = $f.Name; Hlsl = $true; Entry = "MainPS"; HlslStage = "frag"; Inc = $unrealShaders
        Body = (Get-UnrealBody (Join-Path $unrealShaders $f.File)) }
}
# ---- Compile ----------------------------------------------------------------------------------
$fail = 0
foreach ($v in $variants) {
    $ext = if ($v.Hlsl) { "hlsl" } else { "glsl" }
    $in = Join-Path $tmp ("$($v.Name).$ext")
    $out = Join-Path $tmp ("$($v.Name).spv")
    [System.IO.File]::WriteAllText($in, $(if ($v.Hlsl) { $v.Body } else { $v.Header + $v.Body }))
    if ($v.Hlsl) {
        $stage = if ($v.HlslStage) { $v.HlslStage } else { "frag" }
        $glslcArgs = @("-x", "hlsl", "-fshader-stage=$stage", "-fentry-point=$($v.Entry)", "-fauto-bind-uniforms",
                  "-I", $src)
        if ($v.Inc) { $glslcArgs += @("-I", $v.Inc) }
        $glslcArgs += @("-o", $out, $in)
    } else {
        $glslcArgs = @("-x", "glsl", "-std=$($v.Std)", "--target-env=$($v.Env)", "-fshader-stage=$($v.Stage)")
        if ($v.Env -eq "opengl") { $glslcArgs += "-fauto-map-locations" }
        $glslcArgs += @("-o", $out, $in)
    }
    # glslc reports errors on stderr. Under Windows PowerShell 5.1 with "Stop", the first stderr
    # line would abort the whole script before the PASS/FAIL summary, so relax it for the call.
    $ErrorActionPreference = "Continue"
    $log = & $glslc @glslcArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($code -eq 0) { Write-Host "PASS  $($v.Name)" -ForegroundColor Green }
    else {
        $log | ForEach-Object { Write-Host "      $_" }
        Write-Host "FAIL  $($v.Name)" -ForegroundColor Red
        $fail++
    }
}
# ---- The HLSL variants again with Microsoft's own compilers --------------------------------------
# fxc (Direct3D 11, shader model 5.0) and dxc (shader model 6.0, DXIL) from the Windows SDK are what Unity and Unreal use for their
# Direct3D back ends, and they are stricter than glslc's HLSL front end. Skipped with a note when the SDK is not installed.
$kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
$fxc = Get-ChildItem $kits -Recurse -Filter fxc.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName | Select-Object -Last 1
$dxc = Get-ChildItem $kits -Recurse -Filter dxc.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName | Select-Object -Last 1
if (-not $fxc -and -not $dxc) { Write-Host "NOTE  fxc / dxc not found (Windows SDK): HLSL checked with glslc only" -ForegroundColor Yellow }
$msFail = 0; $msCount = 0
foreach ($v in $variants) {
    if (-not $v.Hlsl) { continue }
    $in = Join-Path $tmp ("$($v.Name).hlsl")
    $stage = if ($v.HlslStage) { $v.HlslStage } else { "frag" }
    $incs = @("-I", $src); if ($v.Inc) { $incs += @("-I", $v.Inc) }
    foreach ($tool in @(@{ Exe = $fxc; Tag = "fxc"; Vs = "vs_5_0"; Ps = "ps_5_0"; Out = "/Fo" }, @{ Exe = $dxc; Tag = "dxc"; Vs = "vs_6_0"; Ps = "ps_6_0"; Out = "-Fo" })) {
        if (-not $tool.Exe) { continue }
        $profile = if ($stage -eq "vert") { $tool.Vs } else { $tool.Ps }
        $outFile = Join-Path $tmp ("$($v.Name).$($tool.Tag).bin")
        $toolArgs = if ($tool.Tag -eq "fxc") { @("/nologo", "/T", $profile, "/E", $v.Entry) + ($incs | ForEach-Object { if ($_ -eq "-I") { "/I" } else { $_ } }) + @("/Fo", $outFile, $in) }
                    else { @("-nologo", "-T", $profile, "-E", $v.Entry) + $incs + @("-Fo", $outFile, $in) }
        $ErrorActionPreference = "Continue"
        $log = & $tool.Exe.FullName @toolArgs 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
        $ErrorActionPreference = "Stop"
        $msCount++
        if ($code -ne 0) { $log | Where-Object { $_ -match "error" } | Select-Object -First 4 | ForEach-Object { Write-Host "      $_" }; Write-Host "FAIL  $($v.Name) ($($tool.Tag) $profile)" -ForegroundColor Red; $msFail++ }
    }
}
if ($msCount) { if ($msFail) { Write-Host "$msFail of $msCount fxc/dxc compiles failed" -ForegroundColor Red } else { Write-Host "PASS  $msCount fxc/dxc compiles (SM5.0 and SM6.0)" -ForegroundColor Green } }
$fail += $msFail
if ($fail -gt 0) { throw "$fail of $($variants.Count) shader variant(s) failed to compile" }
Write-Host "All $($variants.Count) shader variants compiled." -ForegroundColor Green
