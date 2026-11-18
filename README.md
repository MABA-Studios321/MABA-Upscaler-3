# MABA Upscaler 3

Temporal super-resolution plus **Frame Gen (2x / 3x)** for low-end mobile GPUs, with five quality presets,
and engine integrations for **Godot, Unity and Unreal Engine**. The scene is rendered at a lower resolution
with a sub-pixel jitter; an **output-resolution temporal resolve** (weighted accumulation of the jittered
samples, motion reprojection, YCoCg clamp, a wide "prior" for moving pixels) produces the image and a light
present sharpen finishes it. Frame Gen (Android test app) adds generated frames between or after real ones.

> **Status: PRE-ALPHA.** Everything below states what was measured and on what. One test phone
> (Galaxy A05, Mali-G52 MC2, 60 Hz panel), one desktop GPU for the engine tests.

## Quick start

| Engine | Do this | Details |
|---|---|---|
| Godot 4 | copy `integrations/godot/addons/maba_upscaler3` into your project's `addons/`, enable the plugin, add a `Maba3Upscaler` node | [README](integrations/godot/addons/maba_upscaler3/README.md) |
| Unity 2021.3+ | Package Manager > add package from disk > `integrations/unity/com.maba.upscaler3/package.json`, then *Tools > MABA Upscaler > Add to Main Camera* | [README](integrations/unity/com.maba.upscaler3/README.md) |
| Unreal Engine 5 | copy `integrations/unreal/UE5/MabaUpscaler3` into `YourProject/Plugins/`, rebuild | [README](integrations/unreal/UE5/MabaUpscaler3/README.md) |
| Unreal Engine 4 | copy `integrations/unreal/UE4/MabaUpscaler3` into `YourProject/Plugins/`, rebuild (never compiled: expect to fix a small error) | [README](integrations/unreal/UE4/MabaUpscaler3/README.md) |
| Android test app | `powershell -File test\android\build.ps1 -Install` | below |

See also [CHANGELOG.md](CHANGELOG.md), [CONTRIBUTING.md](CONTRIBUTING.md) and [DECISIONS.md](DECISIONS.md).

## What is in the repo

| Path | What it is |
|---|---|
| `src/maba_temporal_sr.frag.glsl` | Temporal super-resolution resolve + present sharpen (GLSL ES 3.0). |
| `src/maba_tsr.hlsl`, `maba_fg_warp.hlsl` | The same algorithm as an HLSL core (Unity, Unreal), and the Frame Generation re-projection warp used by the engine integrations. |
| `src/maba_framegen.frag.glsl`, `maba_framegen.h` | Frame Gen: the extrapolation warp (one generated frame predicted forward from the newest real frame, no real frame held back) and the governor that never lets it show fewer frames than off (host-tested). |
| `src/maba_upscaler.*`, `maba_temporal.*` | Single-pass spatial upscaler, dynamic-resolution controller, Halton jitter. |
| `integrations/godot/` | Godot 4 addon (compositor effect + present canvas item). |
| `integrations/unity/com.maba.upscaler3/` | Unity package (built-in pipeline and URP). |
| `integrations/unreal/UE5/MabaUpscaler3/` | Unreal Engine 5 plugin (5.0 - 5.8): compiled and run on 5.6 and 5.8. |
| `integrations/unreal/UE4/MabaUpscaler3/` | Unreal Engine 4 plugin (4.26 - 4.27): same source, UE4 differences in one header; **never compiled**. |
| `test/android/` | The test app: scene with motion vectors, presets, Frame Gen, quality check, panel scripts. Builds without Gradle. |
| `test/` | Every automated check: shaders through glslc, fxc and dxc, the governor, Unity against the real UnityEngine API, C vs C# parity, Godot and Unreal in-engine runs (see *Tests you can run*). |
| `DECISIONS.md` | Every experiment kept or rejected, with numbers. |

## Engine integrations at a glance

Each integration has the same shape as a DLSS-style plugin: a runtime component, presets, a settings API with saved player choices, and a
ready-made settings menu.

| | Godot 4 | Unity | Unreal (UE5 5.0 - 5.8 / UE4 4.26 - 4.27) |
|---|---|---|---|
| Upscaler + presets | yes | yes | yes |
| Settings API (capabilities, presets for a screen, apply / save / load) | `Maba3Settings` | `MabaSettings` | Blueprint library + `UMabaSubsystem` |
| Drop-in menu | `Maba3SettingsMenu` | uGUI binder + quick IMGUI menu | `UMabaSettingsWidget` (UMG) |
| Editor integration | Tools menu, inspector warnings | Tools menu, inspector | Project Settings page |
| Frame Generation (camera re-projection, 2x / 3x) | **yes, tested** | written, **never run** | UE5: **yes, tested on 5.6 and 5.8** (unlit test scene); UE4: same code, never compiled |
| Verified | headless + render + Frame Gen + governor tests on 4.7 | compiles against the real UnityEngine 2021.3 API (runtime; Editor scripts against a hand-written UnityEditor stub); logic checks against a stub; shaders compile with glslc, fxc and dxc | UE5 compiles on 5.6 and 5.8; in a game on both: Blueprint API, settings save, menu, upscaler image + flicker, Frame Gen (2x / 3x pattern, image vs truth, governor) |
| Not verified | Mobile renderer, a phone, 4.3 - 4.6 | **never opened in Unity** (no rendering, no player), uGUI declared by hand | UE5: real game content (lit only on the engine's template map), 5.0 - 5.5, non-Windows. UE4: everything (never compiled) |

Engine Frame Generation here means *camera re-projection*: the game keeps running every frame, the scene is rendered every second
(third) one, and the other frames re-project the last rendered frame to the newest camera pose. Camera motion is parallax-correct and the UI
is never warped; objects that move by themselves update on rendered frames only. The phone test app's Frame Gen is a different mechanism
(extrapolation with per-pixel motion vectors from a renderer that outputs them). See each integration's `README.md`.

## Presets

Performance 0.50, Balance Lite 0.55, Balanced 0.59, Quality 0.67, Ultra Quality 0.77 render scale (of the
output width and height); Dynamic holds a target frame rate.

## Measured on the test phone (1541 x 720 output, scene GPU-bound, Balanced 0.59)

| | FPS |
|---|---|
| Native, no upscaling | 25.9 |
| Spatial upscale (no temporal) | 45.9 |
| **Temporal SR** | **39 - 41** |
| Temporal SR + Frame Gen 2x (uncapped counters) | 61 (real 30.7 + generated 30.7) |
| Temporal SR + Frame Gen 3x | 74 (real 25 + 49 generated) |

Image quality against a 2x-supersampled reference (PSNR / detail kept, Balanced 0.59):

| | bilinear | spatial (old) | temporal |
|---|---|---|---|
| moving scenes | 22.39 dB / 93% | 22.43 / 97% | **22.59 / 99%** |
| calm scene | 22.39 dB | 22.43 | **24.69 / 98%** |

Native aliased render: 24.82 dB. So the temporal path matches native on a calm scene at 59% render scale
(and beats it at 77%: 25.80 dB), is slightly better than spatial in motion, and costs about 4.4 ms per frame
against the spatial path. The weak spot is fast motion: the camera-motion history rejects fast movers
rather than tracking them, and tuning (trust, clamp width, history cap, kernel widths, sharpen) is
saturated within 0.05 dB on the moving test scenes.

Frame Gen (extrapolation only), what the numbers mean:

- 2x gives 1.5x the FPS here, not 2x: each generated frame costs about 7 ms next to a 25 ms real frame.
  About 3 ms of that is presenting one more frame, and a full-screen pass is a floor of about 2 - 3 ms on this
  GPU; the warp shader itself is only a small part (a generated frame that is a plain copy still gives 61 fps).
- The real (input-driven) frame rate falls from 40 to about 30 at 2x and about 25 at 3x.
- Input latency, tap to the frame reaching the panel (software only, mean of 38 taps, VSync on; method in
  `test/android/latency_u3.ps1`): Frame Gen off 73 ms, **2x 75 ms**, 3x 103 ms. Extrapolation holds no real
  frame back, so 2x adds nothing measurable; 3x costs about 30 ms because the real frame rate drops to 25.
  This excludes the touch sensor and the panel's scan-out (add roughly 8 ms for a 60 Hz panel on average), so it
  is not photon latency. About 17 - 23 ms of it is Android input delivery plus waiting for the next frame, and most
  of the rest is the GPU-bound frame (25 ms) plus buffers queued ahead of it.
- Generated frames score 23.3 dB against a true render of the same instant, vs 20.9 dB for repeating the real
  frame (at 6x faster motion: 17.5 vs 13.9 dB). It can guess wrong when motion changes direction, which the
  constant-speed test scene cannot show.
- An interpolating mode (a frame between two real frames) was built, measured and **removed**: same quality on
  the test scene, but it holds the real frame back (real frame 85 - 92 ms at 2x, 137 ms at 3x).
- The panel is 60 Hz: with VSync off the app counts frames it presents and the glass shows at most 60.

## Interacting with the test scene

Drag to orbit the camera, pinch to zoom. Until the first drag the camera auto-orbits; *Settings > Camera: back to
auto orbit* hands it back. The camera is a real camera matrix, so the temporal resolve and Frame Gen see it as
they would a game camera. The settings panel opens from the *Settings* button at the top right.
## Build and run the test app (Windows)

Needs the Android SDK (build-tools, a platform), an NDK, a JDK 11+, and the debug keystore Android Studio
creates.

```
powershell -ExecutionPolicy Bypass -File test\android\build.ps1 -Install
```

Package `com.maba.upscaler3`. Script it with extras: `--ei preset 0..4`, `--ei fg 1` (2x) or `3` (3x),
`--ei vsync 0|1`, `--ei lat 1` (input-latency probe), `--ei fggov 0|1` (governor). Developer
extras are listed at the top of `MainActivity.java`. Panel-truth scripts: `test/android/panel_u3.ps1`.

## Tests you can run

```
powershell -ExecutionPolicy Bypass -File test\run_all.ps1 [-Godot <exe>] [-Unreal56 <UE root>] [-Unreal58 <UE root>]
powershell -ExecutionPolicy Bypass -File test\unreal\run_unreal_fg_test.ps1 -Engine "C:\Program Files\Epic Games\UE_5.6"    # in-game Unreal checks (GPU, about 10 min)
```

Always runs (no GPU, no engine install): the engine-copy sync check (every engine copy equals `src/`, and the UE4 plugin equals the UE5 one
except its compatibility header), the shader compile check (glslc for the GLSL builds and every HLSL variant, then Microsoft's `fxc` SM5.0 and
`dxc` SM6.0 for the HLSL ones), the Frame Gen governor unit test (gcc or clang), the Unity runtime and Editor scripts compiled against the real
UnityEngine 2021.3 reference assemblies (a 3 MB NuGet download into a cache folder, nothing added to the repo; the Editor scripts use a
hand-written UnityEditor stub and uGUI is declared by hand), the Unity settings logic run against a stub, and a C vs C# parity test of the
controller and jitter ports (.NET SDK). `-Godot` adds the Godot render tests (static, moving camera, Frame Generation, with pass / fail
thresholds); `-Unreal5x` builds the UE5 plugin with that engine. The in-game Unreal checks (settings API, menu, Frame Generation image check,
a still-camera flicker check) are `test/unreal/run_unreal_fg_test.ps1`.

## What is verified, in one table

| | Godot | Unity | UE5 | UE4 |
|---|---|---|---|---|
| Compiles | runs in 4.7 | against the real UnityEngine API (runtime) | 5.6, 5.8 | no (never built) |
| Runs | yes (Vulkan, headless + render) | **no** (no editor available) | yes, 5.6 and 5.8 (unlit scene) | no |
| Image quality measured | yes (+3.8 dB vs bilinear, FG 29.2 vs 22.9 dB) | no | yes (+3.1 dB vs the earlier build, FG 31.6 vs 28.7 dB) | no |
| Flicker (still camera) checked | yes, 46.6 dB | no | yes, 56 dB frame to frame (unlit) | no |
| Lit scene checked (sky, sun, automatic exposure) | yes (the test scene is lit) | no | yes, the engine's template map on 5.6 and 5.8 (exposure bug found and fixed there) | no |

Every "no" is a gap, not a pass. The phone measurements above are for the Android test app, not for any engine plugin.