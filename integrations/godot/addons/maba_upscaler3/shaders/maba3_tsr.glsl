// MABA Upscaler 3 - temporal super-resolution resolve for Godot (RenderingDevice, Vulkan).
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// Godot port of src/maba_temporal_sr.frag.glsl (see that file for the full description). It runs at
// OUTPUT resolution: every output pixel reads the 2x2 jittered internal-resolution texels around it,
// weights them by their true distance (a narrow kernel that is accumulated, a wide one that is the
// fallback), reprojects the output-resolution history, clamps it to the neighbourhood in YCoCg and
// blends it as a weighted running average.
//
// Godot gives the compositor the INTERNAL colour buffer in LINEAR HDR, before tonemapping. All the
// maths here runs in a compressed space, c / (1 + luma(c)), so bright pixels cannot dominate the
// clamp and the history stays in [0, 1); maba3_present.gdshader undoes it, tonemaps and sharpens.
//
//   uInput    internal colour, linear HDR, nearest reads
//   uHistory  last frame's accumulated history (rgb compressed, a = weight / WMAX), LINEAR filter
//   uDepth    internal depth, Godot's reversed-Z (1 = near, 0 = far)
//   uPrevDepth last frame's depth at OUTPUT resolution (written by this pass; every framebuffer attachment must be the same size)
// Outputs: 0 = new history, 1 = the image to show, 2 = this frame's depth (next frame's uPrevDepth).
//
// Motion: camera motion only, rebuilt from the depth with one matrix from this frame's clip space to
// last frame's (both UNJITTERED, built on the CPU), so large world offsets cost no GPU precision.

#[vertex]
#version 450

layout(location = 0) out highp vec2 vUV;

void main()
{
    highp vec2 p = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    vUV = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

#define MABA_TSR_R 3.0
#define MABA_TSR_RW 0.5
#define MABA_TSR_PRIOR 0.5
#define MABA_TSR_WMAX 12.0
#define MABA_TSR_MOTION_K 8.0
#define MABA_TSR_DEPTH_MOTION 0.15

layout(set = 0, binding = 0) uniform sampler2D uInput;
layout(set = 0, binding = 1) uniform sampler2D uHistory;
layout(set = 0, binding = 2) uniform sampler2D uDepth;
layout(set = 0, binding = 3) uniform sampler2D uPrevDepth;

layout(push_constant) uniform MabaTsrConstants
{
    highp mat4 uCurToPrev;   // this frame's UNJITTERED clip space -> last frame's
    highp vec4 uOut;         // xy = output size in pixels, zw = 1 / output size
    highp vec4 uA;           // xy = internal (render) size in texels, zw = this frame's jitter in texels
    highp vec4 uB;           // x = near, y = far plane, z = reset (1 = ignore history), w = 1 when uPrevDepth is valid
    highp vec4 uC;           // x = depth tolerance (relative), y = clip gamma, z = history weight cap scale, w unused
};

layout(location = 0) in highp vec2 vUV;
layout(location = 0) out highp vec4 oHist;
layout(location = 1) out highp vec4 oShown;
layout(location = 2) out highp float oDepth;

highp float lumaOf(highp vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
highp vec3 compress(highp vec3 c) { c = max(c, vec3(0.0)); return c / (1.0 + lumaOf(c)); }

highp vec3 toYCoCg(highp vec3 c)
{
    return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
                0.5 * c.r - 0.5 * c.b,
               -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

highp vec3 fromYCoCg(highp vec3 c)
{
    return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// View-space distance from Godot's reversed-Z depth (finite far plane).
highp float linearDepth(highp float d)
{
    highp float n = uB.x;
    highp float f = uB.y;
    return n * f / (n + d * (f - n));
}

void main()
{
    ivec2 ip = ivec2(gl_FragCoord.xy);
    ivec2 isize = ivec2(uA.xy);
    ivec2 lim = isize - 1;
    highp vec2 uv = (gl_FragCoord.xy) * uOut.zw;
    highp vec2 region = uA.xy;
    // Where this output pixel sits in the JITTERED internal image (content moved BY +jitter).
    highp vec2 lp = uv * region + uA.zw;
    ivec2 c0 = ivec2(floor(lp));
    ivec2 cb = ivec2(floor(lp - 0.5));                     // lower-left texel of the 2x2 block around it

    vec3 accN = vec3(0.0);
    vec3 accW = vec3(0.0);
    float wsN = 0.0;
    float wsW = 0.0;
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    vec3 mn = vec3(1e9);
    vec3 mx = vec3(-1e9);
    for (int dy = 0; dy <= 1; dy++)
    {
        for (int dx = 0; dx <= 1; dx++)
        {
            ivec2 o = cb + ivec2(dx, dy);
            vec3 c = compress(texelFetch(uInput, clamp(o, ivec2(0), lim), 0).rgb);
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

    float wNoHist = min(wsN, MABA_TSR_WMAX);
    vec3 shownNoHist = mix(curW, curN, wNoHist / (wNoHist + MABA_TSR_PRIOR));
    oHist = vec4(curN, wNoHist / MABA_TSR_WMAX);
    oShown = vec4(shownNoHist, 1.0);

    ivec2 n = clamp(c0, ivec2(0), lim);
    highp float depth = texelFetch(uDepth, n, 0).r;
    oDepth = depth;                                        // the nearest internal texel's depth, stored at output resolution
    if (uB.z > 0.5)
        return;

    // Sky (depth 0 = infinitely far) keeps just inside the range so it still rotates with the camera.
    highp float dd = max(depth, 1e-6);
    highp vec4 pc = uCurToPrev * vec4(uv * 2.0 - 1.0, dd, 1.0);
    if (pc.w <= 0.0)
        return;
    highp vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    if (any(lessThan(puv, vec2(0.0))) || any(greaterThan(puv, vec2(1.0))))
        return;
    highp vec2 vel = uv - puv;
    float disp = length(vel * region);                     // motion in internal texels

    // Disocclusion, only where the pixel moves.
    if (disp > MABA_TSR_DEPTH_MOTION && uB.w > 0.5)
    {
        highp float curLin = linearDepth(dd);
        highp float prevLin = linearDepth(max(texelFetch(uPrevDepth, clamp(ivec2(puv * uOut.xy), ivec2(0), ivec2(uOut.xy) - 1), 0).r, 1e-6));
        if (abs(prevLin - curLin) > uC.x * curLin)
            return;
    }

    vec3 mean = m1 * 0.25;
    vec3 sigma = sqrt(max(m2 * 0.25 - mean * mean, vec3(0.0)));
    vec3 lo = max(mean - uC.y * sigma, mn);
    vec3 hi = min(mean + uC.y * sigma, mx);
    highp vec2 hpos = clamp(puv * uOut.xy, vec2(0.5), uOut.xy - 0.5);
    vec4 hs = textureLod(uHistory, hpos * uOut.zw, 0.0);
    vec3 hist = clamp(toYCoCg(hs.rgb), lo, hi);

    float wh = hs.a * MABA_TSR_WMAX / (1.0 + MABA_TSR_MOTION_K * disp);
    float a = wsN / (wh + wsN + tiny);
    vec3 histNew = clamp(fromYCoCg(mix(hist, toYCoCg(curN), a)), 0.0, 1.0);
    float wNew = min(wh + wsN, MABA_TSR_WMAX);

    oHist = vec4(histNew, wNew / MABA_TSR_WMAX);
    oShown = vec4(mix(curW, histNew, wNew / (wNew + MABA_TSR_PRIOR)), 1.0);
}
