# MABA Upscaler 3 for Unreal Engine 5 (5.0 - 5.8)

> **Status: PRE-ALPHA.** Compiled **and run in a game on UE 5.6 and 5.8**: the Blueprint API, the subsystem, saved settings, the settings
> widget, the temporal upscaler and **Frame Generation** pass `test/unreal/run_unreal_fg_test.ps1` on both (an *unlit* test scene: lit
> scenes render black on the development PC for a reason outside the plugin, see Verification). UE 5.0 - 5.5 have version guards
> in the source, checked against Epic's API reference, but have **not been compiled**. Windows (Win64) only.
>
> Unreal Engine 4 (4.26 / 4.27) has its own plugin in [`../UE4`](../UE4/MabaUpscaler3): it needs different engine hooks and is a separate folder.

Render the scene at a lower `r.ScreenPercentage` with a sub-pixel projection jitter; a post-process pass **after the
tonemapper** accumulates the jittered samples at **output** resolution (camera-motion reprojection from depth,
disocclusion test, colour clamp) and a second pass sharpens the result into the view's output. On renderers without SM5 scene
textures (mobile) or without depth it falls back to a single-pass spatial upscale.

## Install

1. Copy this `MabaUpscaler3` folder (the one containing `MabaUpscaler3.uplugin`) to `YourProject/Plugins/`.
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
applied, saved and restored. It has a Close button, and `Show MABA Settings Menu` shows the mouse cursor and sends input to the menu until it is closed (pass *Capture Input* = false to manage that yourself; `Capture Input` and `Close Menu` are also nodes on the widget). Derive a Widget Blueprint from it to add your own controls (`On Settings Applied` event).

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

- **Exposure and the engine's own temporal systems** (found by testing a lit scene): a generated frame renders an almost empty scene, and the engine's automatic exposure used to adapt to it, so the real frames pulsed in brightness (101 - 149 of 255 against a steady 155). Generated frames now carry zero time deltas, so exposure cannot move (`MabaCompat::FreezeTime` picks the right time member for the engine version).
- **Governor** (`r.Maba.FrameGeneration.AutoPause 1`, default): it measures the milliseconds per displayed frame with and without
  generating and pauses itself when generating would not cut that by about 8%, so Frame Generation never shows fewer frames per
  second than leaving it off. In the vsync-bound test scene it paused after 918 ticks.
- **Needs**: the temporal tier running (SM5, MABA owning the anti-aliasing) and one local player (split-screen turns it off).
  `IsMabaFrameGenerationSupported` and `Get MABA Status` report what is possible and what is happening; when a requirement is
  missing the plugin renders every frame and says so. It is built for a perspective game camera; orthographic cameras are untested.
- **Limits, plainly**: objects that move by themselves update only on rendered frames (so at 2x they step at half the rate; the camera
  does not); things the renderer updates during the scene render (Lumen and virtual shadow map caches, GPU particle simulation, etc.)
  are skipped on generated frames, so expect them to advance at the rendered rate - **not tested on real game content**; a sudden
  camera cut that lands on a generated frame shows a warped copy of the old view for that one frame (not tested); a sky or clouds that animate on their own update at the rendered rate too (visible as a small step between a generated and the next real frame); on a disocclusion
  the warp stretches the nearest surface (it cannot invent the hidden pixels).
- **Measured on UE 5.6, unlit test scene, 640x360, camera moving 8 units per tick** (`test/unreal/psnr_fg.ps1`): a generated frame
  scores 31.6 dB against a true render of the same pose, repeating the previous real frame scores 28.7 dB; 3x gives the pattern
  real, generated, generated every time; on a still camera real and generated frames are as steady as the engine's own picture
  (see Verification).

## Supported versions and how the source copes with them

| Engine | State |
|---|---|
| 5.6 | compiled and linked (UnrealBuildTool + UnrealHeaderTool, Win64 Editor, Development) **and run in a game** (all checks of `test/unreal/run_unreal_fg_test.ps1`) |
| 5.8 | compiled and linked with no warnings from the plugin (5.8 deprecates `GetViewMatrix` and `OnPostEngineInit`; `MabaCompat.h` uses the new names there) **and run in a game** (5.8.4, all checks of the same script, same numbers as 5.6) |
| 5.0 - 5.5 | guards for: slice inputs (5.4), the `SubscribeToPostProcessingPass` signature (5.5), the scene-texture container shape. Checked against Epic's API reference for 5.0, 5.4 and 5.5 (the `SubscribeToPostProcessingPass` overloads, the `FViewMatrices` jitter and matrix functions, `FPixelShaderUtils::AddFullscreenPass`). **Not compiled.** |
| 4.26 - 4.27 | not in this folder: see [`../UE4`](../UE4/MabaUpscaler3). |

All of this is in `Source/MabaUpscaler3/Private/MabaCompat.h` (this folder's copy holds only UE5 branches). If you build on a version marked *not compiled*, expect to fix small
API differences and please report them.

## Limits

- Motion is rebuilt from the camera (depth + matrices). Objects moving on their own are rejected by the depth/colour test rather
  than tracked, so fast movers soften and may ghost slightly.
- The pass runs after the tonemapper, so the engine's own TAA / TSR is switched off for MABA-rendered views
  (`r.Maba.OverrideAntiAliasing`). Scene captures and reflection captures are left alone.

## Verification (what was actually run)

`powershell -File test\unreal\run_unreal_fg_test.ps1 -Engine <path-to-UE_5.6>` (or `<path-to-UE_5.8>`) builds the plugin, creates a throw-away project and a
small level (floor, poles, sphere, cube), and runs in a real game window (D3D12, SM5). Every check below passes on 5.6.1 and on 5.8.4:

- **Behaviour (7 checks)**: the five presets and their render sizes for 1920x1080 (1920x1080, 1478x832, 1286x724,
  1133x637, 960x540), recommended modes for 4K and 720p, Frame Generation reported supported, `Apply User Settings` read back,
  the settings menu created and in the viewport, the 3x pattern (one real + two generated frames, repeating), and the governor
  pausing Frame Generation in a vsync-bound scene.
- **Frame Generation image check**: generated frames vs a true render of the same camera pose, 31.6 dB (repeating the previous real
  frame: 28.7 dB).
- **Flicker check** (still camera, consecutive displayed frames, PSNR between each frame and the next): upscaler alone 56.1 dB,
  Frame Generation 2x 56.2 dB (the engine's own picture: 60.5 dB, spatial-only MABA: 59.4 dB). This test exists because a bug
  was found with it: the first version of the HLSL resolve reset the history of every pixel it classified as sky, and which render
  texel is "nearest" to a silhouette pixel changes with the jitter phase, so every edge against the sky flipped between "reset" and
  "accumulated" and crawled (39.3 dB frame to frame). The sky is now reprojected like any surface (a point at infinity only rotates),
  as the Godot version always did. Against the engine's native-resolution render of the same poses the resolve went from 35.9 to 39.0 dB
  (still) and 36.0 to 37.6 dB (moving), now above spatial-only (36.4 / 36.0 dB). Balanced preset, sharpness 0.35, 640x360 output, unlit scene.
- **UI on generated frames**: with Frame Generation 2x, the settings menu (UMG) and a canvas text line stay on screen on every displayed frame: consecutive shots taken with `Shot showui` (the window including Slate UI; `HighResShot` does not capture UMG) differ by 61.6 dB (5.6) and 67.7 dB (5.8) on average. The worst pair on 5.6, 34.6 dB, is the menu's status line text changing ("ready" / "on"), not flicker.
- **Lit scene** (the engine's own `Template_Default` map: sky with clouds, sun, automatic exposure; UE 5.6): the upscaler is 36.4 - 36.8 dB from the engine's native frame and steady (52.5 dB frame to frame, the engine's own picture: 49.8 dB). Frame Generation 2x / 3x: brightness stays within 0.3 of 255 of the plain upscaler, consecutive frames 42 - 43 dB apart (a still camera; the difference is the clouds animating between rendered frames), frames 30.8 / 28.1 dB from native (5.6). All of it on both 5.6 and 5.8. Before the fix the same test gave brightness swings of 54 and 26.7 dB: **it is in the regression test** (`lit_capture.py` / `lit_check.ps1`).
- **Not verified**: real game content (the lit result is one template map). My own generated test level (a few meshes and a movable directional light) renders black when lit on the development PC (RTX 5050; the engine's template maps render fine, so the cause is most likely my level, not the plugin), which is why the image checks use an unlit scene and the lit check uses the engine's template map. Also untested: UE 5.0 - 5.5, non-Windows, other renderers (mobile, ray tracing), VR and split-screen, and a GPU-time measurement of the scene cost Frame Generation saves.
- The shaders (`Shaders/*.usf`, the HLSL cores) also pass `test/compile_shaders.ps1`: glslc's HLSL front end, and Microsoft's `fxc` (shader model 5.0) and `dxc` (6.0) from the Windows SDK, which are what the engine's D3D back ends use.

A note on priorities: `r.Maba.*` values set from the console or command line (priority *console*) win over the Blueprint / C++ API
(priority *code*) by design, so a developer's console tweak is not undone by the menu. Saved player settings are applied at start with
code priority, over the Project Settings defaults.

## Licence

Apache-2.0, Copyright 2026 MABA Studios. See `NOTICE` and `THIRD_PARTY_NOTICES.md`.