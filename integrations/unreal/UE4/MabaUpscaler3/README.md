# MABA Upscaler 3 for Unreal Engine 4 (4.26 - 4.27)

> **Status: PRE-ALPHA, NOT COMPILED.** No UE4 engine could be installed on the development machine, so this folder has **never been
> built against UE 4.26 or 4.27**. It is the UE5 plugin ([`../UE5`](../UE5/MabaUpscaler3), compiled and run on UE 5.6 and 5.8) with the UE4
> differences written from the engine's API history. Every source file except `MabaCompat.h` is byte-identical to the UE5 plugin (the
> test suite enforces this), so the algorithms, shaders, settings API, menu and Frame Generation scheduler are the tested ones; what is
> unproven is only the thin layer that touches UE4's renderer API. Expect to fix a small compile error or two on first build and please
> report them. Windows (Win64) only. Unreal Engine 5 has its own folder: [`../UE5`](../UE5/MabaUpscaler3).
Render the scene at a lower `r.ScreenPercentage` with a sub-pixel projection jitter; a post-process pass **after the
tonemapper** accumulates the jittered samples at **output** resolution (camera-motion reprojection from depth,
disocclusion test, colour clamp) and a second pass sharpens the result into the view's output. On renderers without SM5 scene
textures (mobile) or without depth it falls back to a single-pass spatial upscale.

## Install

1. Copy this `MabaUpscaler3` folder (the one containing `MabaUpscaler3.uplugin`) to `YourProject/Plugins/`. Use it with UE 4.26 or 4.27 only (a UE5 project gets a compile error that points to the UE5 folder).
2. Right-click the `.uproject` > *Generate Visual Studio project files*, then build (the plugin has C++ source).
3. Open the project: *Edit > Plugins > Rendering > MABA Upscaler 3* is enabled by default.
4. *Edit > Project Settings > Plugins > MABA Upscaler*: pick a preset, press Play.

Do not enable it together with MABA Upscaler 2 (they share console variable names).

## Blueprint and C++ API (like the DLSS plugin's)

All of these are in the **MABA Upscaler** Blueprint category (class `UMabaBlueprintLibrary`):

| Node | What it does |
|---|---|
| `Is MABA Supported`, `Is MABA Temporal Supported`, `Is MABA Frame Generation Supported` | capability checks: gate your menu options on them |
| `Get MABA Mode Infos (Output Size)`, `Get MABA Mode Info` | every preset with name, render scale and render resolution: build a menu from this |
| `Get MABA Recommended Mode (Output Size)` | a starting preset for a screen size |
| `Set MABA Enabled / Mode / Sharpness / Target Fps / Scale Range / Temporal / Show Stats` | individual settings |
| `Set MABA Frame Generation`, `Set MABA Frame Generation Auto Pause` | Frame Generation mode (Off / 2x / 3x) |
| `Get MABA User Settings`, `Apply MABA User Settings` | the whole settings value (`FMabaUserSettings`) at once |
| `Get MABA Status` | what MABA did on the last tick (`FMabaStatus`): scale, temporal running, Frame Generation state |
| `Reset MABA History` | after a camera cut or teleport |
| `Get MABA Subsystem`, `Show MABA Settings Menu` | the subsystem and the ready-made menu (below) |

**`UMabaSubsystem`** (a game instance subsystem; node `Get MABA Subsystem`): `Get / Apply User Settings`, `Save / Load User Settings`
(stored in `GameUserSettings.ini`, section `MabaUpscaler3`, loaded automatically at start), `Reset To Project Defaults`,
`Apply Recommended Mode`, `Get Status Text`, and the event `On Settings Changed`.

**`UMabaSettingsWidget`** (class *MABA Settings Menu*): a ready-made UMG menu built in C++ (no Widget Blueprint needed):
preset list with render scale, sharpness slider, Dynamic target frame rate, Frame Generation, status line. Show it with
`Show MABA Settings Menu` or `Create Widget` > `Add to Viewport`. Everything goes through the subsystem, so choices are
applied, saved and restored. It has a Close button, and `Show MABA Settings Menu` shows the mouse cursor and sends input to the menu until it is closed (pass *Capture Input* = false to manage that yourself). Derive a Widget Blueprint from it to add your own controls (`On Settings Applied` event).

```cpp
UMabaSubsystem* Maba = GetGameInstance()->GetSubsystem<UMabaSubsystem>();
FMabaUserSettings S = Maba->GetUserSettings();
S.Mode = EMabaMode::Quality;
Maba->ApplyUserSettings(S, /*bSave*/ true);
```

Console variables (all `r.Maba.*`): `Enable`, `Mode` (0 Dynamic, 1 Ultra Quality 0.77, 2 Quality 0.67, 3 Balanced 0.59, 4 Performance 0.50),
`Sharpness`, `TargetFps`, `MinScale`, `MaxScale`, `Temporal`, `Temporal.ClipGamma`, `Temporal.DepthTolerance`,
`FrameGeneration`, `FrameGeneration.AutoPause`, `OverrideAntiAliasing`, `ShowStats`. The Project Settings page (*Plugins > MABA Upscaler*)
sets the defaults.

## Frame Generation (camera re-projection, 2x / 3x)

Set it with `Set MABA Frame Generation` (Off / 2x / 3x), the menu, or `r.Maba.FrameGeneration 0 / 1 / 2`. How it works: the game keeps
ticking every frame (input, gameplay and the camera are sampled every frame); the scene is rendered on every 2nd (3rd) frame; on the
others the view is rendered with almost everything switched off (no meshes, shadows or lighting: in the test scene the generated frame
shows 0 draw calls and about 0.02 ms of scene time in `ProfileGPU`) and the plugin's post-process pass replaces the picture with the
last rendered frame **re-projected to the current camera pose** using its depth (an iterative depth search along each pixel's ray,
`Shaders/MabaFgWarp.usf`), then sharpens it. Camera motion is parallax-correct; the engine's HUD / UMG is drawn on top as usual and is
never warped.

- **Exposure** (a bug found in the UE5 plugin by testing a lit scene): a generated frame renders an almost empty scene and the engine's automatic exposure used to adapt to it, so real frames pulsed in brightness. Generated frames now carry zero time deltas so exposure cannot move; `MabaCompat::FreezeTime` writes whichever time member the engine's view family has (`DeltaWorldTime` in UE 4, `FGameTime` later). **Unverified on UE4**: if that member does not exist as assumed, the build stops there and the fix is a one-line change.
- **Governor** (`r.Maba.FrameGeneration.AutoPause 1`, default): it measures the milliseconds per displayed frame with and without
  generating and pauses itself when generating would not cut that by about 8%, so Frame Generation never shows fewer frames per
  second than leaving it off. In the vsync-bound test scene it paused after 918 ticks.
- **Needs**: the temporal tier running (SM5, MABA owning the anti-aliasing) and one local player (split-screen turns it off).
  `IsMabaFrameGenerationSupported` and `Get MABA Status` report what is possible and what is happening; when a requirement is
  missing the plugin renders every frame and says so. It is built for a perspective game camera; orthographic cameras are untested.
- **Limits, plainly**: objects that move by themselves update only on rendered frames (so at 2x they step at half the rate; the camera
  does not); things the renderer updates during the scene render (Lumen and virtual shadow map caches, GPU particle simulation, etc.)
  are skipped on generated frames, so expect them to advance at the rendered rate - **not tested on real game content**; a sudden
  camera cut that lands on a generated frame shows a warped copy of the old view for that one frame (not tested); on a disocclusion
  the warp stretches the nearest surface (it cannot invent the hidden pixels).
- **Measured on UE 5.6 (the UE5 plugin; not measured on UE4), unlit test scene, 640x360, camera moving 8 units per tick** (`test/unreal/psnr_fg.ps1`): a generated frame
  scores 31.6 dB against a true render of the same pose, repeating the previous real frame scores 28.7 dB; 3x gives the pattern
  real, generated, generated every time; on a still camera real and generated frames are as steady as the engine's own picture
  (see Verification).

## What differs from the UE5 plugin

| Area | UE5 plugin | This (UE4) plugin |
|---|---|---|
| Vector / matrix types | `FVector4f` / `FMatrix44f` (float) next to double | `FVector4` / `FMatrix` (float) |
| Ticker | `FTSTicker` | `FTicker` |
| `SubscribeToPostProcessingPass` | extra `const FSceneView&` overload from 5.5 | the original signature only |
| Post-process inputs | slices from 5.4 | `FScreenPassTexture` |
| `ISceneViewExtension` | pre-render hooks take `FRDGBuilder` and are optional | the two `FRHICommandListImmediate` pre-render hooks are pure virtual: overridden (empty) |
| Engine TAA / TSR | `AAM_TSR` exists | `AAM_TemporalAA` only |
| Show flags for generated frames | adds Nanite, Lumen and Hair | no Nanite / Lumen; Hair left alone |

All of it lives in `Source/MabaUpscaler3/Private/MabaCompat.h` plus one `#if MABA_UE_RHI_PRERENDER` block in `MabaViewExtension.h`.
UE 4.25 and older lack the post-process callback this plugin uses.

**Where a first build may need a fix** (the layer nobody could compile): the scene-texture container inside `FPostProcessMaterialInputs`
(`MabaCompat::GetSceneDepth` accepts both known shapes), `FPixelShaderUtils::AddFullscreenPass` argument lists, `AddDrawTexturePass`
overloads, the view family's time member used by `MabaCompat::FreezeTime`, and the exact set of show-flag names (`MabaFrameGen.cpp`, `ApplyCheapShowFlags`). If the build stops, the compiler names the
line; each is a one-line change.
## Limits

- Motion is rebuilt from the camera (depth + matrices). Objects moving on their own are rejected by the depth/colour test rather
  than tracked, so fast movers soften and may ghost slightly.
- The pass runs after the tonemapper, so the engine's own TAA / TSR is switched off for MABA-rendered views
  (`r.Maba.OverrideAntiAliasing`). Scene captures and reflection captures are left alone.

## Verification (what was actually run)

- **UE 4: nothing was compiled or run** (see the status above). What was checked without an engine: the shared source is byte-identical to
  the UE5 plugin (`test/run_all.ps1`, sync check), the shaders in `Shaders/` compile with glslc, `fxc` (shader model 5.0) and `dxc` (6.0) and are
  the same files that ran in UE 5.6 and 5.8, and the settings logic is the code that passed the UE5 behaviour tests.
- **Where the tested behaviour comes from** (UE5, 5.6.1 and 5.8.4, an unlit test scene): the Blueprint API, 5 presets and recommended modes,
  settings save / load, the menu, the 3x frame pattern, the governor, Frame Generation 31.6 dB vs a true render (repeating a frame:
  28.7 dB), and a still-camera flicker check of 56 dB frame to frame. See the UE5 README.
- **Not verified for UE4**: everything that needs the UE4 engine. Also lit scenes, real game content and non-Windows platforms.
A note on priorities: `r.Maba.*` values set from the console or command line (priority *console*) win over the Blueprint / C++ API
(priority *code*) by design, so a developer's console tweak is not undone by the menu. Saved player settings are applied at start with
code priority, over the Project Settings defaults.

## Licence

Apache-2.0, Copyright 2026 MABA Studios. See `NOTICE` and `THIRD_PARTY_NOTICES.md`.