# MABA Upscaler 3

Temporal upscaling and Frame Generation for low-end GPUs, with plugins for **Godot 4**, **Unity** and **Unreal Engine**.

The scene is rendered at a lower resolution with a sub-pixel camera jitter. A resolve pass at output resolution then accumulates the jittered samples over time (reprojected with the camera motion, rejected where depth disagrees, clamped to the local colour range) and a light sharpen finishes the image. Frame Generation shows extra frames between rendered ones, and a built-in governor switches it off whenever it would not show more frames per second than leaving it off.

> **Status: pre-alpha.** Everything here has been measured on the machines named below, and the table in [What is verified](#what-is-verified) says exactly what has and has not run. Please read it before relying on any part of the project.

## Features

- **Five quality presets** (render scale 50 %, 59 %, 67 %, 77 %) plus a **Dynamic** mode that holds a target frame rate.
- **Temporal resolve** at output resolution, with a spatial single-pass fallback where temporal data is unavailable.
- **Frame Generation** at 2x or 3x, with an automatic pause when it would not help.
- **Settings API** with capability checks, per-screen preset lists, and saved player choices.
- **Ready-made settings menus** for each engine (Godot, Unity uGUI and IMGUI, Unreal UMG).
- **Test suite** covering shaders (compiled with glslc, fxc and dxc), the Frame Generation governor, controller parity, and in-engine tests for Godot and Unreal.

## Quick start

| Engine | Steps | Details |
|---|---|---|
| Godot 4 | Copy `integrations/godot/addons/maba_upscaler3` into your project's `addons/`, enable the plugin, add a `Maba3Upscaler` node to a scene with a `Camera3D`. | [README](integrations/godot/addons/maba_upscaler3/README.md) |
| Unity 2021.3+ | Package Manager > *Add package from disk* > `integrations/unity/com.maba.upscaler3/package.json`, then *Tools > MABA Upscaler > Add to Main Camera*. | [README](integrations/unity/com.maba.upscaler3/README.md) |
| Unreal Engine 5 | Copy `integrations/unreal/UE5/MabaUpscaler3` into `YourProject/Plugins/` and rebuild. | [README](integrations/unreal/UE5/MabaUpscaler3/README.md) |
| Unreal Engine 4 | Copy `integrations/unreal/UE4/MabaUpscaler3` into `YourProject/Plugins/` and rebuild. **Not yet compiled**: expect to fix a small error on the first build. | [README](integrations/unreal/UE4/MabaUpscaler3/README.md) |
| Android test app | `powershell -File test\android\build.ps1 -Install` | [test/android](test/android) |

## What is verified

| | Godot 4 | Unity | Unreal Engine 5 | Unreal Engine 4 |
|---|---|---|---|---|
| Compiles | Runs on 4.7 | Runtime compiles against the real UnityEngine 2021.3 API | Compiles on 5.6 and 5.8 | **No** |
| Runs in an engine | Yes (Vulkan, headless and render tests) | **No**: never opened in the Unity editor | Yes, 5.6 and 5.8 | **No** |
| Upscaler image quality | Measured: +3.8 dB over bilinear | Not measured | Measured against the engine's native frame | Not measured |
| Frame Generation | Measured: generated frames 29.2 dB vs 22.9 dB for repeating a frame | Not run | Measured: 31.6 dB vs 28.7 dB | Not run |
| Still-camera stability | 46.6 dB frame to frame | Not measured | 56 dB (unlit), 42 - 43 dB (lit template map) | Not measured |
| Settings menu | Tested | Logic tested against a stub | Tested in game | Not tested |

Every "No" or "Not measured" is a gap, not a pass. The tests are in [`test/`](test/).

Test machines: Godot and Unreal on an NVIDIA RTX 5050 (Windows 11); the Android test app on a Galaxy A05 (Mali-G52, 60 Hz panel).

### Known limitations

- **Frame Generation re-projects the camera only.** Objects that move on their own update at the rendered rate, so at 2x they step at half the displayed rate. Mobile Frame Generation (the Android app) uses a different method with per-pixel motion vectors.
- **Measured gains are modest.** On a phone, the temporal resolve adds about 2 dB over spatial upscaling on calm scenes and about 0.2 dB in motion. Frame Generation 2x gives about 1.5x the frame rate, not 2x, because generated frames still cost GPU time.
- **Unreal:** lit testing was done on the engine's template map only; real game content is untested. Versions 5.0–5.5 are untested, and 4.26/4.27 have never been compiled.
- **Unity:** never run in the editor, so no rendered output has been checked yet.
- **Windows only** for the tested builds.

Not sure whether it will work for your project? Try it and report what happens with the [first-run report template](.github/ISSUE_TEMPLATE/first_run_report.md).

## Repository layout

| Path | Contents |
|---|---|
| `src/` | The reference algorithm: temporal resolve (GLSL ES 3.0 and HLSL), spatial upscaler, Frame Generation warp and governor, dynamic resolution controller. |
| `integrations/godot/` | Godot 4 addon. |
| `integrations/unity/com.maba.upscaler3/` | Unity package (built-in and URP). |
| `integrations/unreal/UE5/` | Unreal Engine 5 plugin (5.0–5.8). |
| `integrations/unreal/UE4/` | Unreal Engine 4 plugin (4.26–4.27). |
| `test/` | Automated checks and engine test scripts. |
| `test/android/` | Android test app with motion vectors, presets, Frame Generation and latency probes. |

## Running the tests

```
powershell -ExecutionPolicy Bypass -File test\run_all.ps1 -Godot <path to Godot 4.7 console exe>
powershell -ExecutionPolicy Bypass -File test\unreal\run_unreal_fg_test.ps1 -Engine <path to UE_5.6>
```

`run_all.ps1` needs the .NET SDK, gcc or clang, the Android NDK (for glslc), and optionally the Windows SDK (for fxc and dxc). The first run downloads about 3 MB of Unity reference assemblies into `%LOCALAPPDATA%\maba_test_cache`. The Unreal script builds the plugin and runs in-game checks; it takes about 10 minutes per engine version and needs a GPU.

## Contributing

Bug reports, first-run reports and pull requests are welcome. Please say which engine version you used and what you could not run. Keep claims tied to a test or a measurement, and list anything untested under "not verified" rather than describing it as working.

## Licence

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Third-party code (AMD FidelityFX Super Resolution 1.0, MIT) and attribution details are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Copyright 2026 MABA Studios.