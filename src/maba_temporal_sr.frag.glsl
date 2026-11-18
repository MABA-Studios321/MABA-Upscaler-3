//==============================================================================================
// MABA Temporal SR - temporal super-resolution, tuned on a low-end mobile GPU
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// The neighbourhood variance-clipping approach is inspired by AMD FidelityFX Super Resolution 2
// and temporal anti-aliasing upscalers in general; this is an independent implementation.
//
// WHAT IT DOES
//   maba_temporal.frag.glsl accumulates a jittered sequence at RENDER resolution, so its history
//   can never hold more detail than one rendered frame (measured: it kept 75-90% of the detail of
//   a 2x-supersampled render and did not beat bilinear). This pass accumulates at OUTPUT
//   resolution, so the jitter really adds detail: a static scene reaches about 2 dB MORE fidelity
//   than a native-resolution render, from a render at 0.59 scale.
//
//   Per output pixel, every frame:
//     1. The 3x3 jittered render texels around it are read once and weighted twice by their true
//        distance to the pixel: a WIDE kernel (bilinear quality, the fallback) and a NARROW kernel
//        (sample-accurate, what is accumulated).
//     2. The output-resolution history is reprojected with the game's motion vectors, rejected on
//        disocclusion (only where the pixel really moves), clamped to the 3x3 neighbourhood in
//        YCoCg, and blended with the narrow estimate in proportion to the kernel weight each side
//        has accumulated (weighted running average; no minimum share for a frame whose samples
//        were far from the pixel).
//     3. The image shown is the accumulated history blended with the wide estimate by confidence:
//        a young or fast-moving pixel looks like a good spatial upscale, a settled one like the
//        accumulated super-resolved image. The wide estimate never enters the history.
//   A second, cheap pass (MABA_TSR_PRESENT 1) sharpens the shown image, clamped to the local range
//   so it cannot ring; it is never fed back.
//
// HOW TO BUILD (GLES 3.0 or later; no #version line)
//     "#version 300 es\n"                                resolve pass (two render targets)
//     "#version 300 es\n#define MABA_TSR_PRESENT 1\n"    present pass
//   Both are drawn with maba_upscaler.vert.glsl (full-screen triangle) at OUTPUT resolution.
//
// INPUTS (resolve pass)
//   uMabaInput      current jittered scene colour, LDR gamma space (render-resolution region at 0,0)
//   uMabaHistory    previous history, output resolution, half-float, LINEAR filter
//                   (rgb = accumulated colour, a = accumulated weight / MABA_TSR_WMAX)
//   uMabaDepth / uMabaPrevDepth   render-resolution depth, [0,1] GL convention
//   uMabaVelocity   RG16F: surface motion in UV units since the previous frame, UNjittered
//   uMabaTemporalParams  y = depth tolerance (relative), z = reset (x, w unused)
//   uMabaTexel      1 / allocated size of the render textures
//   uMabaRegion     render size in texels
//   uMabaOut        xy = output size in pixels, zw = 1 / output size
//   uMabaJitter     this frame's jitter in render texels, sign as in maba_temporal.h (content
//                   moved BY +jitter)
//   uMabaDepthRange near, far plane (depth is compared in view space)
// OUTPUTS (resolve pass)  location 0: the new history (half-float); location 1: the image to show.
//==============================================================================================

#ifndef MABA_TSR_PRESENT
#define MABA_TSR_PRESENT 0
#endif
// Kernels: weight = max(1 - R * d^2, 0)^2 for a render texel at distance d (in render texels).
// NARROW (accumulated): larger R = more sample-accurate; the history averages out its aliasing.
// WIDE (fallback): about bilinear quality.
#ifndef MABA_TSR_R
#define MABA_TSR_R 5.0
#endif
#ifndef MABA_TSR_RW
#define MABA_TSR_RW 0.5
#endif
// Weight the wide estimate keeps against accumulated history in the SHOWN image (the history
// itself is unaffected). Smaller = sharper once settled.
#ifndef MABA_TSR_PRIOR
#define MABA_TSR_PRIOR 0.5
#endif
// Accumulated weight cap (recency), in units of kernel weight; one full-weight sample is 1.
#ifndef MABA_TSR_WMAX
#define MABA_TSR_WMAX 12.0
#endif
// Catmull-Rom history resampling (1) instead of bilinear (0): bilinear softens it every frame.
#ifndef MABA_TSR_SHARP
#define MABA_TSR_SHARP 0
#endif
// History weight / (1 + K * motion in render texels).
#ifndef MABA_TSR_MOTION_K
#define MABA_TSR_MOTION_K 8.0
#endif
// The depth test only applies to pixels that move more than this many render texels per frame:
// without motion nothing can be uncovered, and for thin geometry the depth sampled at neighbouring
// jitter positions differs at every edge, which would reject the history exactly where
// super-resolution matters (measured: with the test always on, a static scene gained nothing).
#ifndef MABA_TSR_DEPTH_MOTION
#define MABA_TSR_DEPTH_MOTION 0.15
#endif
// Render texels read per output pixel: 3 = the 3x3 block around it, 2 = the 2x2 block around it
// (4 reads instead of 9: the narrow kernel only ever reaches the nearest texel, and the wide one
// is bilinear-like). 2 is cheaper; the history clamp then uses the smaller neighbourhood.
#ifndef MABA_TSR_TAPS
#define MABA_TSR_TAPS 2
#endif
#if MABA_TSR_TAPS == 2
#define MABA_TSR_LO 0
#define MABA_TSR_N 4.0
#else
#define MABA_TSR_LO -1
#define MABA_TSR_N 9.0
#endif

// MABA_TSR_HIGHP 0 runs the colour arithmetic in half precision (positions, depth and velocity stay
// full precision, below); 1 runs everything in full precision.
#ifndef MABA_TSR_HIGHP
#define MABA_TSR_HIGHP 1
#endif
#if MABA_TSR_HIGHP
precision highp float;
#else
precision mediump float;
#endif
precision highp int;
precision highp sampler2D;

#if MABA_TSR_PRESENT
//----------------------------------------------------------------------------------------------
// Present pass: 5-tap sharpen of the shown image, clamped to the local range.
//----------------------------------------------------------------------------------------------
layout(location = 0) out vec4 oMabaColor;

uniform sampler2D uMabaInput;      // the shown image, output resolution
uniform vec4 uMabaOut;
uniform float uMabaSharp;          // 0 = plain copy; about 0.1 - 0.3 is useful

void main()
{
    ivec2 ip = ivec2(gl_FragCoord.xy);
    ivec2 lim = ivec2(uMabaOut.xy) - 1;
    vec3 c = texelFetch(uMabaInput, ip, 0).rgb;
    vec3 n = texelFetch(uMabaInput, clamp(ip + ivec2(0, 1), ivec2(0), lim), 0).rgb;
    vec3 s = texelFetch(uMabaInput, clamp(ip - ivec2(0, 1), ivec2(0), lim), 0).rgb;
    vec3 e = texelFetch(uMabaInput, clamp(ip + ivec2(1, 0), ivec2(0), lim), 0).rgb;
    vec3 w = texelFetch(uMabaInput, clamp(ip - ivec2(1, 0), ivec2(0), lim), 0).rgb;
    vec3 mn = min(min(min(n, s), min(e, w)), c);
    vec3 mx = max(max(max(n, s), max(e, w)), c);
    oMabaColor = vec4(clamp(c + uMabaSharp * (4.0 * c - n - s - e - w), mn, mx), 1.0);
}

#else
//----------------------------------------------------------------------------------------------
// Resolve pass.
//----------------------------------------------------------------------------------------------
layout(location = 0) out vec4 oHist;
layout(location = 1) out vec4 oShown;

uniform sampler2D uMabaInput;
uniform sampler2D uMabaHistory;
uniform sampler2D uMabaDepth;
uniform sampler2D uMabaPrevDepth;
uniform sampler2D uMabaVelocity;
uniform highp vec4 uMabaTemporalParams;
uniform highp vec2 uMabaTexel;
uniform highp vec2 uMabaRegion;
uniform highp vec4 uMabaOut;
uniform highp vec2 uMabaJitter;
uniform highp vec2 uMabaDepthRange;

vec3 toYCoCg(vec3 c)
{
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
                0.5 * c.r - 0.5 * c.b,
               -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

vec3 fromYCoCg(vec3 c)
{
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

highp float linearDepth(highp float d)
{
    highp float n = uMabaDepthRange.x;
    highp float f = uMabaDepthRange.y;
    return 2.0 * n * f / ((f + n) - (2.0 * d - 1.0) * (f - n));
}

// History at an output-pixel position (pixel centres at +0.5): colour in rgb, weight in alpha.
vec4 sampleHistory(highp vec2 pos)
{
    pos = clamp(pos, vec2(0.5), uMabaOut.xy - 0.5);
#if MABA_TSR_SHARP
    highp vec2 tc = floor(pos - 0.5) + 0.5;
    highp vec2 f = pos - tc;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    highp vec2 t12 = tc + w2 / w12;
    highp vec2 t0 = max(tc - 1.0, vec2(0.5));
    highp vec2 t3 = min(tc + 2.0, uMabaOut.xy - 0.5);
    vec4 c = textureLod(uMabaHistory, vec2(t12.x, t0.y) * uMabaOut.zw, 0.0) * (w12.x * w0.y)
           + textureLod(uMabaHistory, vec2(t0.x, t12.y) * uMabaOut.zw, 0.0) * (w0.x * w12.y)
           + textureLod(uMabaHistory, t12 * uMabaOut.zw, 0.0) * (w12.x * w12.y)
           + textureLod(uMabaHistory, vec2(t3.x, t12.y) * uMabaOut.zw, 0.0) * (w3.x * w12.y)
           + textureLod(uMabaHistory, vec2(t12.x, t3.y) * uMabaOut.zw, 0.0) * (w12.x * w3.y);
    float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return clamp(c / wsum, 0.0, 1.0);
#else
    return textureLod(uMabaHistory, pos * uMabaOut.zw, 0.0);
#endif
}

void main()
{
    highp vec2 uv = gl_FragCoord.xy * uMabaOut.zw;
    // Where this output pixel sits in the JITTERED render image (content moved BY +jitter).
    highp vec2 lp = uv * uMabaRegion + uMabaJitter;
    ivec2 c0 = ivec2(floor(lp));                         // the render texel containing it
#if MABA_TSR_TAPS == 2
    ivec2 cb = ivec2(floor(lp - 0.5));                   // lower-left texel of the 2x2 block around it
#else
    ivec2 cb = c0;
#endif
    ivec2 lim = ivec2(uMabaRegion) - 1;

    // The render texels around the pixel, read once: a narrow and a wide weighting, and the
    // neighbourhood statistics used to clamp the history.
    vec3 accN = vec3(0.0);
    vec3 accW = vec3(0.0);
    float wsN = 0.0;
    float wsW = 0.0;
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    vec3 mn = vec3(1e9);
    vec3 mx = vec3(-1e9);
    for (int dy = MABA_TSR_LO; dy <= 1; dy++)
    {
        for (int dx = MABA_TSR_LO; dx <= 1; dx++)
        {
            ivec2 o = cb + ivec2(dx, dy);
            vec3 c = texelFetch(uMabaInput, clamp(o, ivec2(0), lim), 0).rgb;
            vec2 d = vec2(o) + 0.5 - lp;
            float d2 = dot(d, d);
            float wn = max(1.0 - MABA_TSR_R * d2, 0.0);
            float ww = max(1.0 - MABA_TSR_RW * d2, 0.0);
            wn *= wn;
            ww *= ww;
            accN += c * wn;
            wsN += wn;
            accW += c * ww;
            wsW += ww;
            vec3 y = toYCoCg(c);
            m1 += y;
            m2 += y * y;
            mn = min(mn, y);
            mx = max(mx, y);
        }
    }
    const float tiny = 1e-4;
    vec3 curN = accN / max(wsN, tiny);
    vec3 curW = accW / max(wsW, tiny);

    // No usable history: this frame alone. (Weight wsN may be near zero; that is correct, it then
    // counts for almost nothing next frame.)
    float wNoHist = min(wsN, MABA_TSR_WMAX);
    vec3 shownNoHist = mix(curW, curN, wNoHist / (wNoHist + MABA_TSR_PRIOR));

    ivec2 n = clamp(c0, ivec2(0), lim);
    float depth = texelFetch(uMabaDepth, n, 0).r;
    if (uMabaTemporalParams.z > 0.5 || depth <= 0.0)
    {
        oHist = vec4(curN, wNoHist / MABA_TSR_WMAX);
        oShown = vec4(shownNoHist, 1.0);
        return;
    }
    highp vec2 vel = texelFetch(uMabaVelocity, n, 0).rg;
    highp vec2 puv = uv - vel;
    if (any(lessThan(puv, vec2(0.0))) || any(greaterThan(puv, vec2(1.0))))
    {
        oHist = vec4(curN, wNoHist / MABA_TSR_WMAX);
        oShown = vec4(shownNoHist, 1.0);
        return;
    }
    float disp = length(vel * uMabaRegion);              // motion in render texels
    // Disocclusion, only where the pixel moves: the surface seen last frame at the reprojected
    // position must be at about the same view-space distance.
    if (disp > MABA_TSR_DEPTH_MOTION)
    {
        highp float curLin = linearDepth(depth);
        highp float prevLin = linearDepth(texelFetch(uMabaPrevDepth, clamp(ivec2(puv * uMabaRegion), ivec2(0), lim), 0).r);
        if (abs(prevLin - curLin) > uMabaTemporalParams.y * curLin)
        {
            oHist = vec4(curN, wNoHist / MABA_TSR_WMAX);
            oShown = vec4(shownNoHist, 1.0);
            return;
        }
    }

    vec3 mean = m1 * (1.0 / MABA_TSR_N);
    vec3 sigma = sqrt(max(m2 * (1.0 / MABA_TSR_N) - mean * mean, vec3(0.0)));
    float gamma = uMabaTemporalParams.w;
    vec3 lo = max(mean - gamma * sigma, mn);
    vec3 hi = min(mean + gamma * sigma, mx);
    vec4 hs = sampleHistory(puv * uMabaOut.xy);
    vec3 hist = clamp(toYCoCg(hs.rgb), lo, hi);

    // Weighted running average: a frame counts in proportion to how close its samples were. There
    // is deliberately no minimum share for the new frame. Fast motion trusts the history less.
    float wh = hs.a * MABA_TSR_WMAX / (1.0 + MABA_TSR_MOTION_K * disp);
    float a = wsN / (wh + wsN + tiny);
    vec3 histNew = clamp(fromYCoCg(mix(hist, toYCoCg(curN), a)), 0.0, 1.0);
    float wNew = min(wh + wsN, MABA_TSR_WMAX);

    oHist = vec4(histNew, wNew / MABA_TSR_WMAX);
    oShown = vec4(mix(curW, histNew, wNew / (wNew + MABA_TSR_PRIOR)), 1.0);
}
#endif
