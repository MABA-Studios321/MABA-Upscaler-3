# MABA Upscaler 3 for Godot 4

> **Status: PRE-ALPHA.** Tested on Godot 4.7, Forward+, Vulkan, one desktop GPU (see *Verification*). Not
> tested on a phone, on the Mobile renderer, or on Godot 4.3 - 4.6.

Temporal super-resolution **and Frame Generation** for the 3D scene, with presets, a save/load settings API and a
drop-in settings menu.

- **Upscaler:** the camera renders at a lower resolution with a sub-pixel jitter, a compositor effect accumulates the
  samples at **output** resolution (motion reprojection from depth, disocclusion test, colour clamp), and a full-screen
  canvas item behind your UI tonemaps and sharpens the result.
- **Frame Generation (2x / 3x):** the game keeps running every iteration (input, logic, UI), but the 3D scene is
  rendered only on every second (third) one. On the others the node switches the 3D render off for that iteration and the
  present shader re-projects the last rendered frame to the camera pose *of that iteration* (parallax-correct for
  camera motion), with the UI drawn on top, never warped. A governor pauses it whenever it would not show more frames
  per second than leaving it off.

## Install

1. Copy `addons/maba_upscaler3` into your project's `addons/` folder.
2. *Project > Project Settings > Plugins*: enable **MABA Upscaler 3**.
3. *Project > Tools > MABA Upscaler 3: add to open scene* adds a `Maba3Upscaler` node (one per viewport). It finds the
   viewport's current `Camera3D` at run time. *...: add settings menu to open scene* adds the drop-in menu.
   *...: check setup* reports problems (renderer, camera, glow/DoF/auto-exposure that the engine tonemap pass would have applied).

Requires the **Forward+** or **Mobile** renderer (compositor effects do not exist on Compatibility) and Godot 4.3 or newer.

## The node

| Property | Meaning |
|---|---|
| `preset` | Performance 0.50, Balanced 0.59, Balance Lite 0.55, Quality 0.67, Ultra Quality 0.77, Native AA 1.00 (anti-aliasing only), Dynamic (holds `target_fps`) |
| `sharpness` | present sharpen, 0 - 1 (0.5 default) |
| `target_fps`, `min_scale`, `max_scale` | Dynamic preset only |
| `frame_generation` | `OFF`, `X2`, `X3` |
| `frame_generation_auto_pause` | pause Frame Generation while it would not help (default on) |
| `clip_gamma`, `depth_tolerance` | ghost rejection (defaults 1.25 and 0.01) |
| `show_stats` | on-screen fps, render size, state |

```gdscript
var up: Maba3Upscaler = $Maba3Upscaler
up.set_preset(Maba3Upscaler.Preset.QUALITY)
up.set_frame_generation(Maba3Upscaler.FrameGen.X2)
up.reset_history()                          # after a camera cut or teleport
print(up.get_status())                      # preset, scale, fps, running, frame_generation, fg_active, fg_paused, ...
up.frame_generation_changed.connect(func(active): print("generating: ", active))
```

## Settings API and menu (like a DLSS options screen)

```gdscript
Maba3Settings.is_supported()                              # false on the Compatibility renderer
Maba3Settings.recommended_preset(DisplayServer.window_get_size())
Maba3Settings.all_presets(Vector2i(1920, 1080))           # [{preset, name, scale, render_size}, ...]
Maba3Settings.load_into(up)                               # the player's saved choices (user://maba3_settings.cfg)
Maba3Settings.save(up)                                    # after they change something
```

`Maba3SettingsMenu` (a `PanelContainer`) is a ready-made menu: preset list with render scale, sharpness slider,
Frame Generation Off/2x/3x, auto-pause, target fps for Dynamic, and a live status line. Leave `upscaler_path` empty to use the
first `Maba3Upscaler` in the scene; it saves and restores the player's choices (`autosave`) and emits `settings_changed`.
It is plain Controls, so your Theme styles it. Build your own from `Maba3Settings` if you prefer.

## Limits

- Godot has **no hook after its tonemapper**, so MABA 3 replaces the tonemap step: it tonemaps (Linear, Reinhard,
  Filmic, ACES; AgX is approximated by ACES) and sharpens in its own canvas item.
  **Glow, depth of field, colour adjustments and auto-exposure of the engine tonemap pass are not applied.**
- Motion comes from the camera only (rebuilt from depth). Objects that move by themselves are rejected by the
  depth/colour test rather than tracked, so fast movers soften and may ghost slightly.
- **Frame Generation re-projects camera motion only.** Objects that move on their own, and animations, update on rendered
  frames, so at 2x they run at half the displayed rate while the camera and UI run at full rate. It needs a perspective
  `Camera3D`; with other cameras it stays off. Game logic and `_process` run every iteration, so anything that is expensive on the CPU
  still costs its full price per displayed frame.
- Only perspective `Camera3D`s are jittered.

## Verification (what was actually run)

Godot 4.7 stable, Windows, Vulkan, Forward+, one RTX-class GPU:

- Headless self-test (jitter sequence, controller, setup checks, **settings save/load round trip, clamping, the menu's
  controls driving the node**): passes.
- Render test against a 2x-supersampled reference, 800x450 output, render scale 0.59: bilinear 28.26 dB;
  MABA 3 32.03 dB static (+3.8 dB), 31.23 dB with the camera and a sphere moving.
- **Still-camera stability:** consecutive frames of a static scene score 46.6 dB against each other (worst pair 44.9 dB; a plain bilinear frame is 99 dB).
  The remaining difference is on thin high-contrast edges (stripes, checker lines, poles), not on the sky; the test fails below 40 dB.
  Pass / fail thresholds are built into the render test, and the runner fails if the render test cannot finish (Godot 4.7 sometimes stalls at
  start-up on the development PC; the runner detects that within 45 s and retries).
- **Frame Generation (2x), camera moving every iteration:** a generated frame scores 29.2 - 29.6 dB against a true render of the same
  camera pose, against 22.9 - 23.0 dB for repeating the previous real frame (+6.2 dB); real frames score 30.6 dB. Present spacing
  with Frame Generation on is as even as with it off (median 13.3 ms, 100% within 20% of the median, 75 Hz display).
  The governor paused it on a scene where a real frame already fits in a refresh interval, as designed.
- Displayed iterations per second on a GPU-bound test scene, 1444x881, vsync off: native 276, MABA 599, MABA + Frame Gen 2x 944.
  This is a synthetic scene on a desktop GPU: it shows the mechanism works and what it can save, not what a game will get.
- GPU time, same machine: the upscaler adds about 0.04 ms against plain bilinear at the same render scale and saves 0.13 - 0.30 ms
  against native.

Run them yourself:

```
powershell -ExecutionPolicy Bypass -File integrations\godot\test\run_godot_tests.ps1 `
    -Godot <path-to-godot-console.exe> -Render -Moving -Fg [-Bench 1500 -Resolution 1920x1080]
```

## Licence

Apache-2.0, Copyright 2026 MABA Studios. See `THIRD_PARTY_NOTICES.md`.