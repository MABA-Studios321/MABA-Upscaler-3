//==============================================================================================
// MABA Frame Gen (2x) - extrapolated frame generation, light enough for low-end mobile GPUs
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// WHAT IT DOES
//   Builds one extra frame after every real frame by extrapolating the newest real frame
//   forward by MABA_FG_GEN_OFFSET (0.5) of a real-frame interval, using the game's per-pixel
//   motion vectors (camera AND object motion) and depth. Nothing waits for the next real frame,
//   so frame generation adds no waiting latency. It runs at RENDER resolution; the result is
//   upscaled to the screen by maba_upscaler.frag.glsl like any real frame.
//
//   One pass at render resolution (a separate pre-pass to find moving regions was measured and
//   removed: on a tiled mobile GPU every extra dependent pass costs more in stalls than in work).
//   Warp, per output pixel:
//     - smooth area (the motion around the pixel agrees to under 1.25 texel): pull the pixel from
//       where the surface was, one refinement step. This is the common, cheap case.
//     - moving edges: sample along the fast motion's direction, keep the taps that really land
//       on this pixel, and let the NEAREST surface win (correct overlap, no ghost copies).
//     - disocclusion (newly uncovered area): take background, never foreground. If the
//       previous real frame saw the same background (depth check), use its true colour;
//       otherwise extend the nearest background pixel.
//
// HOW TO BUILD (GLES 3.0 or later; no #version line)
//     "#version 300 es\n"
//   Drawn with maba_upscaler.vert.glsl (full-screen triangle); only gl_FragCoord is used.
//
// INPUTS (all textures NEAREST unless noted; texelFetch is used for data textures)
//   uMabaColor      LDR gamma-space colour of the newest real frame, LINEAR filter
//   uMabaVelocity   RG16F: surface motion in UV units over the previous real interval
//                   (current UV minus previous UV), camera and objects, unjittered
//   uMabaDepth      window depth [0,1] of the newest real frame
//   uMabaPrevColor  previous real frame colour, LINEAR;  uMabaPrevDepth its depth
//   uMabaFgSize     xy = region size in texels (image starts at texel 0,0), zw = 1 / texture size
//   uMabaFgPrevSize xy = previous real frame's region size in texels
//   uMabaFgParams   x = offset (MABA_FG_GEN_OFFSET), y = near plane, z = far plane,
//                   w = resolution scale override (0 = automatic, see below)
//
// RESOLUTION INDEPENDENCE
//   The probe radius is measured in texels, so it must grow with the render resolution: the same
//   physical motion is three times as many texels at 1440p as at 480p, and a fixed 6-10 texel
//   probe stops seeing the objects that matter (the host test loses 714 pixels of fast movers at
//   3x with the radius fixed, none with it scaled). The radius is defined for a render height of
//   MABA_FG_REF_HEIGHT and scaled by k = height / MABA_FG_REF_HEIGHT (at least 1). The edge
//   threshold (1.25 texel) and the validity tolerance (1 texel) compare motion DIFFERENCES that
//   the scene itself keeps small, and stay fixed (MABA_FG_SCALE_MASK scales them for experiments).
//==============================================================================================

precision highp float;
precision highp int;
precision highp sampler2D;

uniform sampler2D uMabaColor;
uniform sampler2D uMabaVelocity;
uniform sampler2D uMabaDepth;
uniform sampler2D uMabaPrevColor;
uniform sampler2D uMabaPrevDepth;
uniform vec4 uMabaFgSize;
uniform vec4 uMabaFgPrevSize;
uniform vec4 uMabaFgParams;
// MABA_FG_COLOR_SEPARATE 1: the colour textures (current and previous) are the finished, display-
// resolution image while motion and depth stay at render resolution; the pass then runs at DISPLAY
// resolution. uMabaFgColorSize: xy = colour region in texels, zw = 1 / colour texture size.
// uMabaFgOut: xy = output size in pixels.
#ifndef MABA_FG_COLOR_SEPARATE
#define MABA_FG_COLOR_SEPARATE 0
#endif
#if MABA_FG_COLOR_SEPARATE
uniform vec4 uMabaFgColorSize;
uniform vec4 uMabaFgOut;
#endif

layout(location = 0) out vec4 oMabaColor;

ivec2 texelOf(vec2 uv)
{
    return clamp(ivec2(uv * uMabaFgSize.xy), ivec2(0), ivec2(uMabaFgSize.xy) - 1);
}

vec2 fetchVel(vec2 uv)
{
    return texelFetch(uMabaVelocity, texelOf(uv), 0).rg;
}

// Window depth -> view-space distance (GL convention, depth 0 = near, 1 = far).
float linearize(float d)
{
    float n = uMabaFgParams.y;
    float f = uMabaFgParams.z;
    return 2.0 * n * f / ((f + n) - (2.0 * d - 1.0) * (f - n));
}

float fetchLin(vec2 uv)
{
    return linearize(texelFetch(uMabaDepth, texelOf(uv), 0).r);
}

// Bilinear colour at a region UV, kept half a texel inside the image region. (A sharper 5-tap
// Catmull-Rom resample was measured on the device and scored worse: it rings.)
vec3 sampleColor(sampler2D tex, vec2 uv, vec2 region)
{
#if MABA_FG_COLOR_SEPARATE
    vec2 t = clamp(uv * uMabaFgColorSize.xy, vec2(0.5), uMabaFgColorSize.xy - 0.5) * uMabaFgColorSize.zw;
#else
    vec2 t = clamp(uv * region, vec2(0.5), region - 0.5) * uMabaFgSize.zw;
#endif
    return textureLod(tex, t, 0.0).rgb;
}
const float TAPS[5] = float[5](0.0, 0.5, 1.0, 1.5, 2.0);
// Render height the texel constants below were tuned for; larger renders scale them up.
#ifndef MABA_FG_REF_HEIGHT
#define MABA_FG_REF_HEIGHT 480.0
#endif
// Which constants scale with the render height: bit 0 = probe radius, bit 1 = edge-search
// threshold, bit 2 = validity tolerance. Default 1 (the probe radius only): the host test
// (test/native/test_framegen.c, built for 1x/2x/3x render heights) shows the probe radius is the
// one that must grow, and on the device the other two were measured neutral to slightly worse.
#ifndef MABA_FG_SCALE_MASK
#define MABA_FG_SCALE_MASK 1
#endif
// Texels of motion difference around a pixel above which the edge search runs (at the reference
// height; multiplied by k).
#define MABA_FG_THR 1.25
// How many of the 8 neighbourhood probe taps are read (the 4 cardinal ones come first). 0 = never
// search for edges: the cheap smooth path everywhere. Default 8.
#ifndef MABA_FG_PROBE_TAPS
#define MABA_FG_PROBE_TAPS 8
#endif
// Developer: read the probe but always take the smooth path, to time the probe on its own.
#ifndef MABA_FG_NOEDGE
#define MABA_FG_NOEDGE 0
#endif
const vec2 OFFS[8] = vec2[8](vec2(6.0, 0.0), vec2(-6.0, 0.0), vec2(0.0, 6.0), vec2(0.0, -6.0),
                             vec2(10.0, 10.0), vec2(-10.0, 10.0), vec2(10.0, -10.0), vec2(-10.0, -10.0));

void main()
{
    vec2 size = uMabaFgSize.xy;
#if MABA_FG_COLOR_SEPARATE
    vec2 uv = gl_FragCoord.xy / uMabaFgOut.xy;
#else
    vec2 uv = gl_FragCoord.xy / size;
#endif
    float h = uMabaFgParams.x;
    // Texel constants scale with the render height (see RESOLUTION INDEPENDENCE above).
    float k = uMabaFgParams.w > 0.0 ? uMabaFgParams.w : max(size.y / MABA_FG_REF_HEIGHT, 1.0);
#if (MABA_FG_SCALE_MASK & 1)
    float kProbe = k;
#else
    float kProbe = 1.0;
#endif
#if (MABA_FG_SCALE_MASK & 2)
    float kThr = k;
#else
    float kThr = 1.0;
#endif
#if (MABA_FG_SCALE_MASK & 4)
    float kValid = k;
#else
    float kValid = 1.0;
#endif

    // Probe the neighbourhood (8 taps) for the fastest and the slowest motion around this pixel.
    vec2 vc = fetchVel(uv);                 // this pixel's own motion, read once and reused below
    vec2 vmax = vc;
    vec2 vmin = vmax;
    float mmax = dot(vmax, vmax);
    float mmin = mmax;
    for (int i = 0; i < MABA_FG_PROBE_TAPS; i++)
    {
        vec2 o = OFFS[i] * (kProbe / size);
        vec2 v = fetchVel(clamp(uv + o, 0.0, 1.0));
        float m = dot(v, v);
        if (m > mmax) { mmax = m; vmax = v; }
        if (m < mmin) { mmin = m; vmin = v; }
    }
    float spread = length((vmax - vmin) * size) * h;
    vec3 col;

    if (MABA_FG_NOEDGE == 1 || spread < MABA_FG_THR * kThr)
    {
        // Smooth motion: pull from where this surface was, refined once.
        vec2 s = clamp(uv - h * vc, 0.0, 1.0);
        s = clamp(uv - h * fetchVel(s), 0.0, 1.0);
        col = sampleColor(uMabaColor, s, size);
    }
    else
    {
        // Moving edges: sample velocities along the fast motion. Each velocity proposes a
        // source position (uv - h*v); the proposal is valid only if the surface found there
        // really moves with that velocity. The nearest valid surface wins.
        float bestD = 1e30;
        vec2 bestS = uv;
        bool found = false;
        for (int i = 0; i < 5; i++)
        {
            vec2 pos = clamp(uv - TAPS[i] * h * vmax, 0.0, 1.0);
            vec2 v = (i == 0) ? vc : fetchVel(pos);      // tap 0 is this pixel: already read
            vec2 s = clamp(uv - h * v, 0.0, 1.0);
            if (length((fetchVel(s) - v) * size) * h < kValid)
            {
                float ds = fetchLin(s);
                if (ds < bestD) { bestD = ds; bestS = s; found = true; }
            }
        }
        if (found)
        {
            col = sampleColor(uMabaColor, bestS, size);
        }
        else
        {
            // Newly uncovered: background only = the farthest surface along the motion. (Depth is
            // only fetched here, for the few pixels that really are holes.)
            float bgD = -1.0;
            vec2 bgPos = uv;
            for (int i = 0; i < 5; i++)
            {
                vec2 pos = clamp(uv - TAPS[i] * h * vmax, 0.0, 1.0);
                float d = fetchLin(pos);
                if (d > bgD) { bgD = d; bgPos = pos; }
            }
            // Try the previous real frame's view of it.
            vec2 vb = fetchVel(bgPos);
            vec2 sp = uv - (1.0 + h) * vb;
            bool inside = all(greaterThanEqual(sp, vec2(0.0))) && all(lessThanEqual(sp, vec2(1.0)));
            bool sameSurface = false;
            if (inside)
            {
                ivec2 pt = clamp(ivec2(sp * uMabaFgPrevSize.xy), ivec2(0), ivec2(uMabaFgPrevSize.xy) - 1);
                float pd = linearize(texelFetch(uMabaPrevDepth, pt, 0).r);
                sameSurface = abs(pd - bgD) < 0.1 * bgD;
            }
            col = sameSurface ? sampleColor(uMabaPrevColor, sp, uMabaFgPrevSize.xy)
                              : sampleColor(uMabaColor, bgPos, size);
        }
    }
#if MABA_FG_NOEDGE
    // Keeps the probe alive for timing (the compiler cannot prove this is exactly 1.0).
    oMabaColor = vec4(col, clamp(1.0 + spread * 1e-9, 0.0, 1.0));
#else
    oMabaColor = vec4(col, 1.0);
#endif
}
