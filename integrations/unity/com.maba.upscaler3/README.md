# MABA Upscaler 3 for Unity

> **Status: PRE-ALPHA, never run in the Unity editor.** There is no Unity installation on the machine this
> was written on. What *was* checked is listed under *Verification*. **Frame Generation in particular has never
> produced a picture**: treat it as experimental until you have run it.

Temporal super-resolution and Frame Generation for the built-in render pipeline and URP, with presets, a settings API
and ready-made menus.

- **Upscaler:** the camera renders into a sub-region of a fixed-size render texture at a lower resolution with a sub-pixel
  projection jitter; a resolve pass at **output** resolution accumulates the samples (camera-motion reprojection from
  depth, disocclusion test, colour clamp), and a present pass sharpens the result into the screen. Where depth is
  unavailable (orthographic cameras, `Temporal` off) it falls back to the single-pass spatial upscale.
- **Frame Generation (2x / 3x):** the game keeps updating every frame, but the camera renders only every second (third) one. On the
  others the camera is switched off for that frame and a hidden child camera presents the last rendered frame re-projected to
  the camera pose of the current frame (parallax-correct for camera motion). A governor pauses it when it would not show more
  frames per second than leaving it off.

## Install

Window > Package Manager > + > *Add package from disk...* and pick `package.json`, or copy the folder into your project's
`Packages/`. Needs Unity 2021.3 or newer. URP is optional and detected at run time (the package has no compile-time dependency on it); uGUI (`com.unity.ugui`) is a declared dependency.

Select your camera and use *Tools > MABA Upscaler > Add to Main Camera* (or *Add to Selected Camera*; *Preset* for the presets),
or add the *MABA > MABA Upscaler 3* component by hand.

## The component

| Property | Meaning |
|---|---|
| `mode` | Dynamic (holds `targetFps`), Ultra Quality 0.77, Quality 0.67, Balanced 0.59, Performance 0.50 |
| `sharpness` | present sharpen, 0 - 1 (0.5 default) |
| `targetFps`, `minScale`, `maxScale` | Dynamic mode only |
| `temporal` | temporal super-resolution (default on); off = spatial upscale |
| `frameGeneration`, `frameGenerationAutoPause` | Off / 2x / 3x, and pause it when it would not help |
| `useSavedSettings` | apply the player's saved choices when the component starts |
| `clipGamma`, `depthTolerance` | ghost rejection (defaults 1.25 and 0.01) |

```csharp
var maba = Camera.main.GetComponent<Maba3.MabaUpscaler>();
maba.SetMode(Maba3.MabaUpscaler.Mode.Quality);
maba.SetFrameGeneration(Maba3.FrameGeneration.X2);
maba.ResetHistory();                    // after a camera cut or teleport
Debug.Log(maba.RenderScale + " " + maba.TemporalRunning + " " + maba.FrameGenerationActive);
```

Everything lives in the `Maba3` namespace and the shaders are `MABA3/...`, so it can sit next to MABA Upscaler 2 (which uses `Maba`).

## Settings API and menus (like a DLSS options screen)

`Maba3.MabaSettings` is static, so any UI can use it:

```csharp
MabaSettings.IsSupported(); MabaSettings.IsTemporalSupported(); MabaSettings.IsFrameGenerationSupported();
MabaSettings.GetModeInfos(new Vector2Int(Screen.width, Screen.height));   // name, scale, render size per preset
MabaSettings.RecommendedMode(new Vector2Int(Screen.width, Screen.height));
MabaUserSettings s = maba.GetSettings();  s.mode = MabaUpscaler.Mode.Balanced;  maba.Apply(s);  MabaSettings.Save(s);  // PlayerPrefs
if (MabaSettings.TryLoad(out var saved)) maba.Apply(saved);               // (the component does this itself with useSavedSettings)
```

- **`MabaSettingsBinder`** (uGUI): build your menu in your own style, drop the `Dropdown`s, `Slider`s, `Toggle` and `Text`
  into its fields, and it fills the options, keeps everything in step, applies and saves changes.
- **`MabaSettingsMenu`**: a quick IMGUI menu with no Canvas to set up (*Tools > MABA Upscaler > Add settings menu*; F10 toggles it
  with the legacy Input Manager).
- TextMeshPro and UI Toolkit are not wrapped: use the `MabaSettings` API.

## Limits

- Motion is rebuilt from the camera (depth + matrices). Objects moving on their own are rejected by the depth/colour test
  rather than tracked, so fast movers soften and may ghost slightly. **Frame Generation re-projects camera motion only:** objects
  that move on their own update on rendered frames, i.e. at half the displayed rate at 2x.
- Perspective cameras only for the temporal path and Frame Generation.
- The camera renders into a render texture, so camera stacking, post-processing that expects the back buffer, and UI should be
  checked in your project. **Use Screen Space - Overlay UI with Frame Generation**: a camera-space canvas is tied to the main
  camera, which is off on generated frames.

## Verification (what was actually run)

- **The runtime C# compiles against Unity's real API.** `test/unity_real` builds `Runtime/*.cs` against the UnityEngine 2021.3 reference
  assemblies (`UnityEngine.Modules` from NuGet, 3 MB, fetched into a cache folder by `test/run_all.ps1`) with the real C# compiler. That
  caught a call to a method that does not exist (`FrameTimingManager.GetLatestFrameTimings`; it is `GetLatestTimings`) and a hard assembly
  reference to URP that would have broken projects without it. uGUI types are not part of the engine assemblies and are declared by hand.
- **The Editor scripts compile against a hand-written UnityEditor stub** (the editor assemblies need an install): that caught a `MenuItem`
  attribute repeated on one method, which does not compile. The stub proves our code is consistent, not that the real UnityEditor
  signatures match.
- Logic checks run against a stub (`test/unity_logic`): presets and render sizes for a screen, the recommended preset by screen size,
  clamping of settings values. A C vs C# parity test compares the dynamic-resolution controller and the jitter sequence with the C
  headers over 6,088 lines of output.
- **The shaders compile with Microsoft's `fxc` (shader model 5.0) and `dxc` (6.0)** as well as glslc: every HLSL body of the three `.shader`
  wrappers (`MabaTsr`, `MabaTsrPresent`, `MabaFgWarp`) and the HLSL cores they include. Unity's own ShaderLab / shader compiler was not run.
- The same temporal core and the same warp algorithm run correctly in the Godot addon and (the HLSL form) in Unreal 5.6 and 5.8, where
  they were measured. A sky-edge flicker bug that the HLSL core had in Unreal does not apply to Unity's depth mode (window depth, the sky is
  at the far plane and was never skipped), but it has not been looked for in Unity either.
- **Not verified: that any of it runs.** No Unity editor, no player, no picture, no Frame Generation, no URP / built-in differences.
## Licence

Apache-2.0, Copyright 2026 MABA Studios. See `THIRD_PARTY_NOTICES.md`.