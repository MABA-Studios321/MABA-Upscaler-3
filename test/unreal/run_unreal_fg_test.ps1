# MABA Upscaler 3 - Unreal checks that need a real engine. Usage:
#   powershell -File test\unreal\run_unreal_fg_test.ps1 -Engine <path to the UE_5.6 folder>
# What it does: builds the plugin with UAT BuildPlugin, creates a throw-away project under -Work, builds a small test level, then runs two
# in-game Python scripts (they drive the real plugin through the Blueprint API and console variables):
#   behaviour_test.py  settings API round trip, mode table, recommended modes, the settings menu, the 3x frame pattern, the governor
#   fg_capture.py      screenshots of generated frames vs true renders of the same camera pose (psnr_fg.ps1 compares them)
#   flicker_capture.py consecutive displayed frames with a STILL camera (flicker_check.ps1): with MABA's resolve alone and with Frame Generation,
#                      every frame must equal the next one (regression test for the sky-edge crawl, 39 dB before the fix, 56 dB after)
# The test level is drawn UNLIT (ShowFlag.Lighting 0): on the development PC lit scenes render black in UE 5.6 / 5.8 for a reason that is not
# in the plugin (the engine's own maps render, test levels do not), so the image check uses a scene the machine can draw.
# Needs a GPU, a window and about 5 minutes. Exit code 1 when any check fails.
param(
    [Parameter(Mandatory = $true)][string]$Engine,
    [string]$Work = (Join-Path $env:TEMP "maba_ue_test"),
    [switch]$SkipBuild,
    [int]$TimeoutS = 240
)
$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$exe = Join-Path $Engine "Engine\Binaries\Win64\UnrealEditor.exe"
if (-not (Test-Path $exe)) { throw "UnrealEditor.exe not found under $Engine" }
$ver = (Split-Path $Engine -Leaf) -replace '[^0-9.]', ''
$pluginOut = Join-Path $Work "plugin_$ver"
$proj = Join-Path $Work "U3Test_$ver"
$shots = Join-Path $Work "shots_$ver"
New-Item -ItemType Directory -Force $Work | Out-Null
$fails = 0
function Say($m) { Write-Host $m }

# 1. build the plugin ------------------------------------------------------------------------------
if (-not $SkipBuild) {
    Say "[1/7] building the plugin for UE $ver (a few minutes)"
    if (Test-Path $pluginOut) { Remove-Item $pluginOut -Recurse -Force }
    $buildLog = Join-Path $Work "build_$ver.txt"
    & (Join-Path $Engine "Engine\Build\BatchFiles\RunUAT.bat") BuildPlugin -Plugin="$repo\integrations\unreal\UE5\MabaUpscaler3\MabaUpscaler3.uplugin" -Package="$pluginOut" -TargetPlatforms=Win64 -Rocket *> $buildLog
    if (-not (Select-String -Path $buildLog -Pattern 'BUILD SUCCESSFUL' -Quiet)) { Say "FAIL  plugin build (see $buildLog)"; exit 1 }
    Say "PASS  plugin build"
} else { Say "[1/7] build skipped, using $pluginOut" }

# 2. project ---------------------------------------------------------------------------------------
Say "[2/7] preparing the test project"
New-Item -ItemType Directory -Force "$proj\Config", "$proj\Plugins" | Out-Null
$uproject = '{ "FileVersion": 3, "EngineAssociation": "", "Plugins": [ { "Name": "MabaUpscaler3", "Enabled": true }, { "Name": "PythonScriptPlugin", "Enabled": true }, { "Name": "EditorScriptingUtilities", "Enabled": true } ] }'
Set-Content "$proj\U3Test.uproject" $uproject -Encoding ascii
Set-Content "$proj\Config\DefaultEngine.ini" "[/Script/EngineSettings.GameMapsSettings]`r`nEditorStartupMap=/Game/TestMap`r`nGameDefaultMap=/Game/TestMap`r`n`r`n[/Script/PythonScriptPlugin.PythonScriptPluginSettings]`r`nbDeveloperMode=True`r`n" -Encoding ascii
if (Test-Path "$proj\Plugins\MabaUpscaler3") { Remove-Item "$proj\Plugins\MabaUpscaler3" -Recurse -Force }
Copy-Item $pluginOut "$proj\Plugins\MabaUpscaler3" -Recurse
foreach ($s in 'make_map.py', 'behaviour_test.py', 'fg_capture.py', 'flicker_capture.py', 'lit_capture.py') { Copy-Item "$PSScriptRoot\$s" "$Work\$s" -Force }
$log = "$proj\Saved\Logs\U3Test.log"
$w = $Work -replace '\\', '/'

function Invoke-Ue([string[]]$ueArgs, [string]$what) {
    Remove-Item "$proj\Saved\Config" -Recurse -Force -ErrorAction SilentlyContinue   # saved player settings of an earlier run must not leak in
    # UE 5.8 runs Engine\Build\BatchFiles\Build.bat at start, and that script takes a lock file in %TEMP% (keyed by the script's path). A helper
    # left over from an earlier editor run can keep the lock, and then every later launch waits on it forever (the log stops at "Launching
    # UnrealBuildTool"). A private TEMP folder per launch gives each editor its own lock.
    $privateTmp = Join-Path $Work ("tmp_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Force $privateTmp | Out-Null
    $oldTmp = $env:TMP; $oldTemp = $env:TEMP
    $env:TMP = $privateTmp; $env:TEMP = $privateTmp
    try {
        # The editor sometimes hangs at start-up with no log output at all (seen on 5.6 and 5.8). A running editor keeps writing its log, so a
        # log that does not grow for 90 s means a stalled start: kill it and try once more. A real run that is merely slow still finishes.
        $log = "$proj\Saved\Logs\U3Test.log"
        for ($try = 1; $try -le 2; $try++) {
            $p = Start-Process -FilePath $exe -ArgumentList (@("`"$proj\U3Test.uproject`"") + $ueArgs) -PassThru
            $deadline = (Get-Date).AddSeconds($TimeoutS); $lastSize = -1; $lastChange = Get-Date; $stalled = $false
            while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
                $size = (Get-Item $log -ErrorAction SilentlyContinue).Length
                if ($size -ne $lastSize) { $lastSize = $size; $lastChange = Get-Date }
                elseif (((Get-Date) - $lastChange).TotalSeconds -gt 90) { $stalled = $true; break }
            }
            if ($p.HasExited) { break }
            $p.Kill()
            if ($stalled -and $try -lt 2) { Say "NOTE  ${what}: the editor stalled (no log output for 90 s); retrying once"; continue }
            Say ("FAIL  $what " + $(if ($stalled) { "stalled twice (no log output)" } else { "timed out after $TimeoutS s" })); $script:fails++
            break
        }
    } finally {
        $env:TMP = $oldTmp; $env:TEMP = $oldTemp
        Remove-Item $privateTmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
# 3. level -----------------------------------------------------------------------------------------
if (-not (Test-Path "$proj\Content\TestMap.umap")) {
    Say "[3/7] building the test level"
    Invoke-Ue @("-unattended", "-nosplash", "-log", "-ExecutePythonScript=`"$w/make_map.py`"") "level build"
    if (-not (Test-Path "$proj\Content\TestMap.umap")) { Say "FAIL  the test level was not created"; exit 1 }
} else { Say "[3/7] test level already there" }

$game = @("/Game/TestMap", "-game", "-windowed", "-ResX=640", "-ResY=360", "-nosplash", "-unattended", "-log")

# 4. behaviour -------------------------------------------------------------------------------------
Say "[4/7] behaviour test (settings API, menu, 3x pattern, governor)"
Invoke-Ue ($game + @("-ExecCmds=`"py $w/behaviour_test.py`"")) "behaviour test"
$lines = @(Select-String -Path $log -Pattern 'MABATEST' | ForEach-Object { ($_.Line -replace '^.*MABATEST ', '') })
$lines | ForEach-Object { Say ("  " + $_) }
$expected = 7
$pass = @($lines | Where-Object { $_ -match '-> PASS$' }).Count
$bad = @($lines | Where-Object { $_ -match '-> FAIL$|^EXC' }).Count
if ($pass -ne $expected -or $bad -gt 0) { Say "FAIL  behaviour test: $pass of $expected checks passed, $bad failed"; $fails++ } else { Say "PASS  behaviour test ($pass of $expected checks)" }

# 5. image check -----------------------------------------------------------------------------------
Say "[5/7] Frame Generation image check (generated frame vs true render of the same pose)"
# One retry, said out loud: on 5.8 a single run once scored about 19.6 dB for BOTH the generated and the repeated frame (the true renders
# themselves differed) and two identical re-runs scored 31.57 / 28.70 dB again, so that was a capture glitch, not Frame Generation. A real
# regression fails both attempts.
$imageOk = $false
for ($attempt = 1; $attempt -le 2 -and -not $imageOk; $attempt++) {
    if (Test-Path $shots) { Remove-Item $shots -Recurse -Force }
    New-Item -ItemType Directory -Force $shots | Out-Null
    $env:MABA_SHOTS = $shots
    Invoke-Ue ($game + @("-ExecCmds=`"py $w/fg_capture.py`"")) "image check"
    $res = & "$PSScriptRoot\psnr_fg.ps1" -Shots $shots | Select-Object -Last 1
    if ($res -and $res.Count -ge 2 -and $res.Gen -gt $res.Repeat + 1.0) {
        $imageOk = $true
        Say ("PASS  generated frames {0:N2} dB vs repeating the previous real frame {1:N2} dB ({2} frames){3}" -f $res.Gen, $res.Repeat, $res.Count, $(if ($attempt -gt 1) { "  [passed on the retry: attempt 1 was a capture glitch]" } else { "" }))
    } elseif ($attempt -eq 1) { Say "NOTE  image check attempt 1 failed ($(if ($res) { '{0:N2} vs {1:N2} dB' -f $res.Gen, $res.Repeat } else { 'no frames' })); retrying once" }
}
if (-not $imageOk) { Say "FAIL  generated frames are not clearly closer to the truth than a repeated frame (both attempts)"; $fails++ }
# 6. flicker -----------------------------------------------------------------------------------------
Say "[6/7] flicker check (still camera: consecutive displayed frames must be identical)"
foreach ($cfg in @(@{ n = "upscaler alone"; fg = "0"; hud = "0" }, @{ n = "Frame Generation 2x"; fg = "1"; hud = "0" }, @{ n = "Frame Generation 2x with canvas HUD text on screen (the HUD must not vanish on generated frames)"; fg = "1"; hud = "1" })) {
    $dir = Join-Path $Work ("flicker_{0}_{1}{2}" -f $ver, $cfg.fg, $(if ($cfg.hud -eq "1") { "_hud" } else { "" }))
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:MABA_SHOTS = $dir; $env:MABA_FG = $cfg.fg; $env:MABA_HUD = $cfg.hud
    if ($cfg.hud -eq "1") { Remove-Item "$proj\Saved\Screenshots" -Recurse -Force -ErrorAction SilentlyContinue }
    Invoke-Ue ($game + @("-ExecCmds=`"py $w/flicker_capture.py`"")) "flicker capture ($($cfg.n))"
    if ($cfg.hud -eq "1") {   # the engine names "Shot showui" files itself: collect them as still_NNN_gen.png (kind alternates, the label does not matter)
        $i = 0; Get-ChildItem "$proj\Saved\Screenshots" -Recurse -Filter "ScreenShot*.png" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { Copy-Item $_.FullName (Join-Path $dir ("still_{0:000}_gen.png" -f $i)); $i++ }
    }
    $rows = & "$PSScriptRoot\flicker_check.ps1" -Shots $dir 6>$null
    $still = @($rows | Where-Object { $_.Phase -eq "still" })
    if ($still.Count -eq 1) {
        $vals = @($still[0].ToGenerated_dB, $still[0].ToReal_dB) | Where-Object { $_ -gt 0 }
        $mean = ($vals | Measure-Object -Average).Average
        if ($mean -ge 50.0) { Say ("PASS  {0}: still camera frame-to-frame {1:N1} dB (worst pair {2:N1} dB)" -f $cfg.n, $mean, $still[0].MinStep_dB) }
        else { Say ("FAIL  {0}: still camera frame-to-frame only {1:N1} dB (needs 50+; the picture shimmers)" -f $cfg.n, $mean); $fails++ }
    } else { Say "FAIL  $($cfg.n): no still-camera frames captured"; $fails++ }
}
# 7. lit scene ------------------------------------------------------------------------------------------
# The test level above is drawn unlit, which hides everything that depends on lighting. This step runs the engine's own lit template map
# (sky, clouds, sun, Lumen, automatic exposure) and checks Frame Generation there. It found a bug the unlit scene could not show: the
# engine's automatic exposure adapted to the almost empty generated frames, so real frames pulsed between 101 and 149 (of 255) in brightness.
# The checks are in lit_check.ps1.
Say "[7/7] lit scene (the engine's Template_Default map: sky, sun, automatic exposure)"
$litDir = Join-Path $Work "lit_$ver"
if (Test-Path $litDir) { Remove-Item $litDir -Recurse -Force }
New-Item -ItemType Directory -Force $litDir | Out-Null
$env:MABA_SHOTS = $litDir; $env:MABA_CVARS = ""
$litArgs = @("/Engine/Maps/Templates/Template_Default", "-game", "-windowed", "-ResX=640", "-ResY=360", "-nosplash", "-unattended", "-log")
Invoke-Ue ($litArgs + @("-ExecCmds=`"py $w/lit_capture.py`"")) "lit scene capture"
$lit = & "$PSScriptRoot\lit_check.ps1" -Shots $litDir 6>$null | Select-Object -Last 1
if ($lit -and $lit.fg2x_still_db -and $lit.fg3x_still_db) {
    $bad = @()
    if ($lit.fg2x_brightness_dev -gt 4 -or $lit.fg3x_brightness_dev -gt 4) { $bad += ("brightness deviates {0} / {1} of 255 (2x / 3x)" -f $lit.fg2x_brightness_dev, $lit.fg3x_brightness_dev) }
    if ($lit.fg2x_still_db -lt 38 -or $lit.fg3x_still_db -lt 38) { $bad += ("still-camera frames only {0} / {1} dB apart (2x / 3x, needs 38+)" -f $lit.fg2x_still_db, $lit.fg3x_still_db) }
    if ($lit.maba_vs_native_db -lt 33) { $bad += ("upscaler only {0} dB against the native frame (needs 33+)" -f $lit.maba_vs_native_db) }
    if ($bad.Count) { Say ("FAIL  lit scene: " + ($bad -join "; ")); $fails++ }
    else { Say ("PASS  lit scene: brightness steady (max deviation {0} / {1}), still-camera {2} / {3} dB (2x / 3x), upscaler {4} dB vs native" -f $lit.fg2x_brightness_dev, $lit.fg3x_brightness_dev, $lit.fg2x_still_db, $lit.fg3x_still_db, $lit.maba_vs_native_db) }
} else { Say "FAIL  lit scene: no frames captured"; $fails++ }
if ($fails) { Say "$fails check group(s) failed"; exit 1 }
Say "all Unreal checks passed on UE $ver"