//==============================================================================================
// MABA Upscaler 2 - single-pass spatial upscaler, cheap enough for low-end mobile GPUs
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// The MABA_QUALITY path is derived from AMD FidelityFX Super Resolution 1.0 (EASU),
// Copyright (c) 2021 Advanced Micro Devices, Inc., used under the MIT licence. The full AMD
// notice is in THIRD_PARTY_NOTICES.md and must be kept with any copy of this file.
//
// WHAT IT DOES
//   One fragment-shader pass that upscales and sharpens. No compute shader, no intermediate
//   render target, half-precision maths.
//
//   Default path (2 texture reads with gather, 4 without):
//     - Edge-directed interpolation: each 2x2 block of input texels is split into two triangles
//       along whichever diagonal has the smaller contrast, so diagonal edges are followed
//       instead of stair-stepped.
//     - Sharpening by steepening the interpolation weights. The result always stays between
//       the four source texels, so it cannot ring or overshoot.
//     - Sharpening fades out in near-black areas so dark-scene noise is not amplified.
//
//   MABA_QUALITY 1 (optional, needs gather): adaptive. Low-contrast pixels use the default
//   reconstruction at the same 2 reads; pixels on visible edges add a 12-tap edge-adaptive
//   kernel on luma (6 reads), which follows the edge direction and removes most stair-stepping.
//
// HOW TO BUILD
//   This file has no #version line. Prepend one of these headers before compiling:
//     GLES 3.1 : "#version 310 es\n#define MABA_GATHER 1\n"
//     GLES 3.0 : "#version 300 es\n#define MABA_GATHER 0\n"
//     Vulkan   : "#version 450\n#define MABA_VULKAN 1\n#define MABA_GATHER 1\n"
//
// INPUT REQUIREMENTS
//   - Input is the finished LDR frame in a perceptual (gamma / sRGB-encoded) space, 0..1.
//   - Input texture uses LINEAR filtering and CLAMP_TO_EDGE, and has no mipmaps.
//   - The image may fill the whole texture or only a region starting at texel (0,0), which is
//     how dynamic resolution works: allocate the texture once at the largest render size and
//     change the region size per frame. See maba_upscaler.h for presets and the controller.
//   - Draw UI after this pass, at output resolution.
//==============================================================================================

#ifndef MABA_GATHER
#define MABA_GATHER 1
#endif

#ifndef MABA_QUALITY
#define MABA_QUALITY 0
#endif

// MABA_QUALITY only: 2x2 blocks with contrast below EDGE_LO use the cheap reconstruction; the
// 12-tap kernel fades in above it and takes over fully at EDGE_HI.
#ifndef MABA_EDGE_LO
#define MABA_EDGE_LO (10.0 / 255.0)
#endif
#ifndef MABA_EDGE_HI
#define MABA_EDGE_HI (24.0 / 255.0)
#endif

// MABA_QUALITY only: how much of the sharpness setting is applied as extra gain on the edge-
// reconstructed luma (1 = up to 2x the difference to bilinear at full sharpness). Measured on the
// test phone against a 2x-supersampled reference (PSNR, 0.59 scale): gain 1.0 scored 22.13 dB,
// 0.5 scored 22.27 dB and 0 scored 22.40 dB (the fast build and bilinear: 22.43 / 22.39), so the
// default is 0.5: the kernel keeps its edge following, with half the overshoot.
#ifndef MABA_QUALITY_GAIN
#define MABA_QUALITY_GAIN 0.5
#endif

// Sharpening fades to zero below DARK_LO and reaches full strength at DARK_HI.
#ifndef MABA_DARK_LO
#define MABA_DARK_LO 0.02
#endif
#ifndef MABA_DARK_HI
#define MABA_DARK_HI 0.12
#endif

#ifndef MABA_HIGHP
#define MABA_HIGHP 0
#endif
#ifndef MABA_VULKAN
#define MABA_VULKAN 0
#endif

#if MABA_HIGHP
precision highp float;
#else
precision mediump float;
#endif
precision mediump int;

#if MABA_VULKAN
layout(set = 0, binding = 0) uniform sampler2D uMabaInput;
layout(push_constant) uniform MabaConstants
{
    highp vec4 uMabaInputSize;   // xy = size in texels of the image region, zw = 1 / texture size
    mediump vec4 uMabaParams;    // x = sharpness 0..1 (0.5 is a good default); yzw unused
};
layout(location = 0) in highp vec2 vMabaUV;
#else
uniform mediump sampler2D uMabaInput;
uniform highp vec4 uMabaInputSize;   // xy = size in texels of the image region, zw = 1 / texture size
uniform mediump vec4 uMabaParams;    // x = sharpness 0..1 (0.5 is a good default); yzw unused
in highp vec2 vMabaUV;
#endif

layout(location = 0) out mediump vec4 oMabaColor;

//----------------------------------------------------------------------------------------------
// 2x2 block reconstruction (the default path, and the low-contrast part of MABA_QUALITY).
//
//   f g      Texels of the 2x2 block around the output pixel; pp is the position inside it.
//   j k
//----------------------------------------------------------------------------------------------

// Interpolation weights steepened by the sharpness setting (x) and the dark fade (brightness).
vec2 MabaSharpPos(vec2 pp, float brightness)
{
    float s = uMabaParams.x
            * clamp((brightness - MABA_DARK_LO) * (1.0 / (MABA_DARK_HI - MABA_DARK_LO)), 0.0, 1.0);
    return pp + s * pp * (pp - 1.0) * (1.0 - 2.0 * pp);   // = mix(pp, smoothstep(pp), s)
}

// How strongly to prefer the f-k diagonal (1) over the g-j diagonal (0); 0.5 when undecided.
float MabaDiagonal(float f, float g, float j, float k)
{
    float dFK = abs(f - k);
    float dGJ = abs(g - j);
    return clamp(0.5 + (dGJ - dFK) / (dGJ + dFK + 1.0 / 255.0), 0.0, 1.0);
}

// Any interpolation of the block is  f + (g-f)x + (j-f)y + (f-g-j+k) * w.  Bilinear uses
// w = x*y; splitting along the f-k diagonal uses min(x,y); along g-j, max(x+y-1, 0).
float MabaTwistWeight(vec2 p, float preferFK)
{
    return mix(max(p.x + p.y - 1.0, 0.0), min(p.x, p.y), preferFK);
}

// Luma difference between the edge-directed, sharpened result and plain bilinear, to be added
// to the bilinear colour. (Both are the plane f + (g-f)x + (j-f)y plus a twist term.)
float MabaBlockDelta(float f, float g, float j, float k, vec2 pp)
{
    vec2 p = MabaSharpPos(pp, max(max(f, g), max(j, k)));
    return (g - f) * (p.x - pp.x) + (j - f) * (p.y - pp.y)
         + (f - g - j + k) * (MabaTwistWeight(p, MabaDiagonal(f, g, j, k)) - pp.x * pp.y);
}

// Position of this output pixel in input texel space, relative to texel centres. Clamped at both
// ends so the 2x2 block never reaches past the first or last row/column of the image region.
highp vec2 MabaPos()
{
    return clamp(vMabaUV * uMabaInputSize.xy - 0.5, vec2(0.0), uMabaInputSize.xy - 1.001);
}

// Bilinear colour of the image region at this output pixel, without bleeding past its edge.
vec3 MabaBilinear()
{
    highp vec2 uv = min(vMabaUV * uMabaInputSize.xy, uMabaInputSize.xy - 0.5) * uMabaInputSize.zw;
    return textureLod(uMabaInput, uv, 0.0).rgb;
}

#if MABA_GATHER
// Output colour from the 2x2 block alone: 1 gather (green as luma) + the bilinear colour.
vec4 MabaBlock(highp vec2 fp, vec2 pp, vec3 color)
{
    vec4 q = textureGather(uMabaInput, (fp + 1.0) * uMabaInputSize.zw, 1);
    return vec4(clamp(color + MabaBlockDelta(q.w, q.z, q.x, q.y, pp), 0.0, 1.0), 1.0);
}
#endif

#if !MABA_QUALITY
#if MABA_GATHER
void main()
{
    highp vec2 pos = MabaPos();
    highp vec2 fp = floor(pos);
    oMabaColor = MabaBlock(fp, pos - fp, MabaBilinear());
}
#else
// GLES 3.0: no textureGather, so fetch the four texels and interpolate the colour directly.
void main()
{
    highp vec2 pos = MabaPos();
    highp vec2 fp = floor(pos);
    vec2 pp = pos - fp;

    ivec2 lim = ivec2(uMabaInputSize.xy) - 1;
    ivec2 i0 = clamp(ivec2(fp), ivec2(0), lim);
    ivec2 i1 = clamp(ivec2(fp) + 1, ivec2(0), lim);
    vec3 f = texelFetch(uMabaInput, i0, 0).rgb;
    vec3 g = texelFetch(uMabaInput, ivec2(i1.x, i0.y), 0).rgb;
    vec3 j = texelFetch(uMabaInput, ivec2(i0.x, i1.y), 0).rgb;
    vec3 k = texelFetch(uMabaInput, i1, 0).rgb;

    vec2 p = MabaSharpPos(pp, max(max(f.g, g.g), max(j.g, k.g)));
    float w = MabaTwistWeight(p, MabaDiagonal(f.g, g.g, j.g, k.g));
    oMabaColor = vec4(f + (g - f) * p.x + (j - f) * p.y + (f - g - j + k) * w, 1.0);
}
#endif

#else
//----------------------------------------------------------------------------------------------
// MABA_QUALITY path: FSR 1.0 EASU-style kernel on luma only. Requires textureGather.
//----------------------------------------------------------------------------------------------

// Accumulate direction and edge strength for one of the four bilinear corners.
//      a
//    b c d
//      e
void MabaSet(inout vec2 dir, inout float len, float w,
             float lA, float lB, float lC, float lD, float lE)
{
    float dirX = lD - lB;
    float lenX = max(abs(lD - lC), abs(lC - lB));
    lenX = clamp(abs(dirX) / max(lenX, 1.0 / 512.0), 0.0, 1.0);
    dir.x += dirX * w;
    len += lenX * lenX * w;

    float dirY = lE - lA;
    float lenY = max(abs(lE - lC), abs(lC - lA));
    lenY = clamp(abs(dirY) / max(lenY, 1.0 / 512.0), 0.0, 1.0);
    dir.y += dirY * w;
    len += lenY * lenY * w;
}

// Accumulate one tap of the rotated, anisotropic Lanczos-like kernel.
void MabaTap(inout float aC, inout float aW, vec2 off, vec2 dir, vec2 len2,
             float lob, float clp, float c)
{
    vec2 v = vec2(off.x * dir.x + off.y * dir.y, off.y * dir.x - off.x * dir.y) * len2;
    float d2 = min(dot(v, v), clp);
    float wB = 0.4 * d2 - 1.0;
    float wA = lob * d2 - 1.0;
    wB *= wB;
    wA *= wA;
    wB = 1.5625 * wB - 0.5625;
    float w = wB * wA;
    aC += c * w;
    aW += w;
}

void main()
{
    highp vec2 pos = MabaPos();
    highp vec2 fp = floor(pos);
    vec2 pp = pos - fp;
    vec3 color = MabaBilinear();

    // The 2x2 block first: one gather, the same cost as the fast build.
    vec4 q = textureGather(uMabaInput, (fp + 1.0) * uMabaInputSize.zw, 1);
    float f = q.w, g = q.z, j = q.x, k = q.y;
    float mn = min(min(f, g), min(j, k));
    float mx = max(max(f, g), max(j, k));
    float blockDelta = MabaBlockDelta(f, g, j, k, pp);
    float contrast = mx - mn;

    // Low-contrast pixels need nothing more. Neither do pixels within one texel of the left/top
    // or two texels of the right/bottom edge, where the 12-tap footprint would leave the region.
    if (contrast < MABA_EDGE_LO || any(lessThan(fp, vec2(1.0)))
        || any(greaterThan(fp + 2.5, uMabaInputSize.xy)))
    {
        oMabaColor = vec4(clamp(color + blockDelta, 0.0, 1.0), 1.0);
        return;
    }

    // 12-tap footprint:
    //      b c
    //    e f g h
    //    i j k l
    //      n o
    highp vec2 p0 = (fp + vec2(1.0, -1.0)) * uMabaInputSize.zw;
    vec4 ijfe = textureGather(uMabaInput, p0 + vec2(-1.0, 2.0) * uMabaInputSize.zw, 1);
    vec4 klhg = textureGather(uMabaInput, p0 + vec2( 1.0, 2.0) * uMabaInputSize.zw, 1);

    vec4 bczz = textureGather(uMabaInput, p0, 1);
    vec4 zzon = textureGather(uMabaInput, p0 + vec2(0.0, 4.0) * uMabaInputSize.zw, 1);
    float b = bczz.x, c = bczz.y;
    float i = ijfe.x, e = ijfe.w;
    float l = klhg.y, h = klhg.z;
    float o = zzon.z, n = zzon.w;

    vec2 dir = vec2(0.0);
    float len = 0.0;
    MabaSet(dir, len, (1.0 - pp.x) * (1.0 - pp.y), b, e, f, g, j);
    MabaSet(dir, len, pp.x * (1.0 - pp.y),         c, f, g, h, k);
    MabaSet(dir, len, (1.0 - pp.x) * pp.y,         f, i, j, k, n);
    MabaSet(dir, len, pp.x * pp.y,                 g, j, k, l, o);

    float dirR = dot(dir, dir);
    bool zro = dirR < (1.0 / 8192.0);
    dir = zro ? vec2(1.0, 0.0) : dir * inversesqrt(dirR);

    len = len * 0.5;
    len *= len;
    float stretch = 1.0 / max(abs(dir.x), abs(dir.y));
    vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    float lob = 0.5 - 0.29 * len;
    float clp = 1.0 / lob;

    float aC = 0.0;
    float aW = 0.0;
    MabaTap(aC, aW, vec2( 0.0, -1.0) - pp, dir, len2, lob, clp, b);
    MabaTap(aC, aW, vec2( 1.0, -1.0) - pp, dir, len2, lob, clp, c);
    MabaTap(aC, aW, vec2(-1.0,  1.0) - pp, dir, len2, lob, clp, i);
    MabaTap(aC, aW, vec2( 0.0,  1.0) - pp, dir, len2, lob, clp, j);
    MabaTap(aC, aW, vec2( 0.0,  0.0) - pp, dir, len2, lob, clp, f);
    MabaTap(aC, aW, vec2(-1.0,  0.0) - pp, dir, len2, lob, clp, e);
    MabaTap(aC, aW, vec2( 1.0,  1.0) - pp, dir, len2, lob, clp, k);
    MabaTap(aC, aW, vec2( 2.0,  1.0) - pp, dir, len2, lob, clp, l);
    MabaTap(aC, aW, vec2( 2.0,  0.0) - pp, dir, len2, lob, clp, h);
    MabaTap(aC, aW, vec2( 1.0,  0.0) - pp, dir, len2, lob, clp, g);
    MabaTap(aC, aW, vec2( 1.0,  2.0) - pp, dir, len2, lob, clp, o);
    MabaTap(aC, aW, vec2( 0.0,  2.0) - pp, dir, len2, lob, clp, n);

    // Edge-reconstructed luma, limited to the local range so it cannot ring.
    float edgeG = clamp(aC / aW, mn, mx);

    // Amplify the difference from plain bilinear, fading the boost out in dark areas.
    float bilG = mix(mix(f, g, pp.x), mix(j, k, pp.x), pp.y);
    float gain = 1.0 + MABA_QUALITY_GAIN * uMabaParams.x * smoothstep(MABA_DARK_LO, MABA_DARK_HI, bilG);
    float outG = clamp(bilG + (edgeG - bilG) * gain, mn, mx);

    // Fade from the 2x2 result to the kernel result as contrast rises, so there is no seam.
    float blend = clamp((contrast - MABA_EDGE_LO) * (1.0 / (MABA_EDGE_HI - MABA_EDGE_LO)), 0.0, 1.0);
    oMabaColor = vec4(clamp(color + mix(blockDelta, outG - bilG, blend), 0.0, 1.0), 1.0);
}
#endif
