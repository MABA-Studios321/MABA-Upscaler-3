# Third-party notices

MABA Upscaler 3 includes code derived from the following third-party software.

## AMD FidelityFX Super Resolution 2 (approach only, no code)

- Used in: `src/maba_temporal.frag.glsl` / `maba_temporal.hlsl`, the neighborhood
  variance-clipping approach (YCoCg mean +/- gamma*sigma intersected with the local AABB).
  This is an independent implementation of a published technique; no AMD code is copied.
- Source: https://github.com/GPUOpen-Effects/FidelityFX-FSR2
- Licence: MIT (for reference; no copied code)

## AMD FidelityFX Super Resolution 1.0

- Used in the quality path (edge-direction analysis and kernel shaping, adapted from the EASU
  pass in `ffx_fsr1.h`) of:
  - `src/maba_upscaler.frag.glsl` (`MABA_QUALITY` build) and `src/maba_upscaler.hlsl`
    (`MabaUpscaleQuality`);
  - the synced copies `integrations/unity/com.maba.upscaler3/Runtime/Resources/Maba3Shaders/MabaCore.hlsl`
    and `integrations/unreal/UE5/MabaUpscaler3/Shaders/MabaCore.ush` and `integrations/unreal/UE4/MabaUpscaler3/Shaders/MabaCore.ush`;
  - the Godot ports `integrations/godot/addons/maba_upscaler/shaders/maba_upscaler.glsl` and
    `maba_canvas.gdshader`.
- The Unity package, the Unreal plugin and the Godot addon each carry a copy of this notice, so
  it travels with them when they are copied on their own.
- Source: https://github.com/GPUOpen-Effects/FidelityFX-FSR
- Licence: MIT

```
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
