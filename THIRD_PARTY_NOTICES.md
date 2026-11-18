# Third-party notices

MABA Upscaler 3 contains code and ideas from the following third-party projects. The full license texts are below.

## AMD FidelityFX Super Resolution 1.0 (EASU), MIT License

**Where it is used.** The quality path of the single-pass spatial upscaler is derived from the EASU pass of FSR 1.0 (edge-direction analysis and kernel shaping on luma):

- `src/maba_upscaler.frag.glsl` (`MABA_QUALITY` build), `src/maba_upscaler.hlsl` (`MabaUpscaleQuality`)
- the synced copies `integrations/unity/com.maba.upscaler3/Runtime/Resources/Maba3Shaders/MabaCore.hlsl`,
  `integrations/unreal/UE5/MabaUpscaler3/Shaders/MabaCore.ush` and `integrations/unreal/UE4/MabaUpscaler3/Shaders/MabaCore.ush`

Source: https://github.com/GPUOpen-Effects/FidelityFX-FSR

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

## AMD FidelityFX Super Resolution 2 (idea only, no code copied)

The neighbourhood variance-clipping idea used by the temporal resolve (YCoCg mean +/- gamma * sigma, intersected with the local range) is inspired by FSR 2 and by temporal anti-aliasing upscalers in general. The implementation is independent and no FSR 2 code is included.

Source: https://github.com/GPUOpen-Effects/FidelityFX-FSR2 (MIT License)

## Other engines and tools

Unity, Unreal Engine and Godot are used through their public APIs only. Their source code is not included in this repository. The Unity and Unreal API reference files used by the test suite are downloaded at test time (not redistributed) and remain under their owners' terms.