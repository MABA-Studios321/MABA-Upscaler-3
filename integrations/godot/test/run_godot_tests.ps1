# Runs the Godot-side checks of MABA Upscaler on a scratch project: the headless controller and
# jitter self-test, and (with -Render) the render test, which needs a GPU and opens a window.
#
#   powershell -ExecutionPolicy Bypass -File integrations\godot\test\run_godot_tests.ps1 -Godot D:\Tools\godot47\Godot_v4.7-stable_win64_console.exe [-Render] [-Moving] [-Tune] [-Save] [-Debug]
param(
    [string]$Godot = $env:GODOT,
    [switch]$Render, [switch]$Moving, [switch]$Scan, [switch]$Debug, [switch]$Save, [switch]$Tune, [switch]$Fg, [int]$Bench = 0, [string]$Resolution = "800x450", [int]$TimeoutSeconds = 240, [int]$Retries = 8,
    [string]$Project = (Join-Path ([IO.Path]::GetTempPath()) "maba_godot_test_project")
)
$ErrorActionPreference = "Stop"
if (-not $Godot -or -not (Test-Path $Godot)) { throw "Pass -Godot <path to a Godot 4 console executable> (or set GODOT)." }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$addon = Join-Path (Split-Path -Parent $here) "addons\maba_upscaler3"

if (Test-Path $Project) { Remove-Item -Recurse -Force $Project }
New-Item -ItemType Directory -Force "$Project\addons" | Out-Null
Copy-Item $addon "$Project\addons\maba_upscaler3" -Recurse
Copy-Item (Join-Path $here "render_test.gd") $Project
Set-Content "$Project\render_test.tscn" "[gd_scene load_steps=2 format=3]`n[ext_resource type=`"Script`" path=`"res://render_test.gd`" id=`"1`"]`n[node name=`"Root`" type=`"Node3D`"]`nscript = ExtResource(`"1`")" -Encoding ASCII
Set-Content "$Project\project.godot" "config_version=5`n[application]`nconfig/name=`"maba_godot_test`"`n[rendering]`nrenderer/rendering_method=`"forward_plus`"" -Encoding ASCII

# Godot writes warnings to stderr; do not let PowerShell turn those into terminating errors.
$ErrorActionPreference = "Continue"
& $Godot --headless --path $Project --import 2>&1 | Out-Null
# The self-test quits itself; a script error leaves Godot idle forever, so give it a watchdog.
$ctOut = Join-Path $Project "controller_out.txt"
$ct = Start-Process -FilePath $Godot -ArgumentList @("--headless", "--path", $Project, "--script", "res://addons/maba_upscaler3/test_u3.gd") -RedirectStandardOutput $ctOut -RedirectStandardError "$ctOut.err" -PassThru -WindowStyle Hidden
if (-not $ct.WaitForExit(120000)) { $ct.Kill(); Write-Host "controller test timed out (a script error leaves Godot idle):" }
$out = ((Get-Content $ctOut -ErrorAction SilentlyContinue) + (Get-Content "$ctOut.err" -ErrorAction SilentlyContinue)) -join "`n"
Write-Host $out
if ($out -notmatch "ALL MABA3 GODOT TESTS PASSED") { throw "Godot controller tests failed" }

if ($Render) {
    $userArgs = @()
    if ($Fg -or $Bench -gt 0 -or $Moving -or $Debug -or $Save -or $Tune -or $Scan) { $userArgs += "--" }
    if ($Scan) { $userArgs += "--scan" }
    if ($Tune) { $userArgs += "--tune" }
    if ($Save) { $userArgs += "--save" }
    if ($Debug) { $userArgs += "--debug" }
    if ($Moving) { $userArgs += "--moving" }
    if ($Fg) { $userArgs += "--fg" }
    if ($Bench -gt 0) { $userArgs += @("--bench", "$Bench") }
    # Hard timeout and retry: on the author's machine Godot 4.7 now and then deadlocks at startup
    # (0% CPU, right after loading its own shader cache, before any addon code runs). A stuck run must
    # not hang the test forever, so it is killed and tried again.
    $outFile = Join-Path $Project "render_out.txt"
    $argList = @("--path", $Project, "--rendering-driver", "vulkan", "--resolution", $Resolution, "res://render_test.tscn") + $userArgs
    $renderOut = ""
    $renderDone = $false
    $renderExit = -1
    # A deadlocked start prints nothing and burns no CPU, so it is recognised by silence: no "RENDER" line within StartSilence seconds of
    # launch, or no new output for RunSilence seconds afterwards. The whole process tree is killed (the console exe launches the real
    # Godot as a child) and the run is tried again.
    $startSilence = 45; $runSilence = 120
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        Remove-Item $outFile, "$outFile.err" -ErrorAction SilentlyContinue
        $proc = Start-Process -FilePath $Godot -ArgumentList $argList -RedirectStandardOutput $outFile -RedirectStandardError "$outFile.err" -PassThru -WindowStyle Normal
        $started = Get-Date; $lastChange = $started; $lastLen = -1; $why = ""
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 1000
            $len = (Get-Item $outFile -ErrorAction SilentlyContinue).Length + (Get-Item "$outFile.err" -ErrorAction SilentlyContinue).Length
            if ($len -ne $lastLen) { $lastLen = $len; $lastChange = Get-Date }
            $text = ((Get-Content $outFile -ErrorAction SilentlyContinue) -join "`n")
            $silent = ((Get-Date) - $lastChange).TotalSeconds
            $sinceStart = ((Get-Date) - $started).TotalSeconds
            if ($text -notmatch "RENDER" -and $sinceStart -gt $startSilence) { $why = "no output $startSilence s after launch (startup deadlock)" }
            elseif ($silent -gt $runSilence) { $why = "no output for $runSilence s" }
            elseif ($sinceStart -gt $TimeoutSeconds) { $why = "over $TimeoutSeconds s" }
            if ($why) {
                Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" | ForEach-Object { try { [System.Diagnostics.Process]::GetProcessById($_.ProcessId).Kill() } catch {} }
                try { $proc.Kill() } catch {}
                Write-Host "RENDER attempt $attempt stopped: $why"
                break
            }
        }
        if (-not $why) { $null = $proc.WaitForExit(); $renderExit = $proc.ExitCode }   # ExitCode is $null in Windows PowerShell 5.1 without the wait
        $renderOut = ((Get-Content $outFile -ErrorAction SilentlyContinue) + (Get-Content "$outFile.err" -ErrorAction SilentlyContinue)) -join "`n"
        if (-not $why -and $renderOut -match "RENDER done") { $renderDone = $true; break }
    }
    $renderOut -split "`n" | Where-Object { $_ -match "RENDER|MABADBG|ERROR|SCRIPT" } | ForEach-Object { Write-Host $_.TrimEnd() }
    # A render test that never finished, or finished with failures, is a FAILURE (it used to fall through silently after the last retry).
    if (-not $renderDone) { throw "Godot render test did not finish in $Retries attempts" }
    if ($null -ne $renderExit -and $renderExit -ne 0) { throw "Godot render test reported $renderExit failure(s)" }
    if ($renderOut -match "RENDER[^`n]*FAIL") { throw "Godot render test printed a FAIL line" }
}
