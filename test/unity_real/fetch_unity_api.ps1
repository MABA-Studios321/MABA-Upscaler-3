# Downloads the Unity API reference assemblies used by test\unity_real (UnityEngine.Modules 2021.3.33 from nuget.org, about 3 MB) into a
# cache folder and prints the folder. Nothing is added to the repository. Skipped when the cache already holds them.
param([string]$Cache = (Join-Path $env:LOCALAPPDATA "maba_test_cache\unity_api"))
$ProgressPreference = "SilentlyContinue"
$lib = Join-Path $Cache "modules\lib\netstandard2.0"
if (-not (Test-Path (Join-Path $lib "UnityEngine.CoreModule.dll"))) {
    New-Item -ItemType Directory -Force $Cache | Out-Null
    $zip = Join-Path $Cache "modules.zip"
    Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/unityengine.modules/2021.3.33/unityengine.modules.2021.3.33.nupkg" -OutFile $zip -UseBasicParsing
    if (Test-Path (Join-Path $Cache "modules")) { Remove-Item (Join-Path $Cache "modules") -Recurse -Force }
    Expand-Archive $zip (Join-Path $Cache "modules")
}
$lib