//==============================================================================================
// MABA-Upscaler 2 (Temporal) - temporal resolve pass, light enough for low-end mobile GPUs
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// The neighborhood variance-clipping approach is inspired by AMD FidelityFX Super Resolution 2
// (MIT licence); this is an independent implementation, not a copy of AMD code.
//
// WHAT IT DOES
//   One fragment-shader pass at RENDER resolution that accumulates a jittered frame sequence
//   into a stable, effectively anti-aliased image. Its output is then upscaled to the screen by
//   maba_upscaler.frag.glsl (fast or quality build). Two cheap passes total; the history buffers
//   live at render resolution, not output resolution, to keep bandwidth low on mobile.
//
//   - Camera reprojection: current depth + inverse view-proj -> world -> previous clip space.
//     No per-object motion vectors needed (camera-only TAAU). Fast-moving objects may ghost
//     slightly; the neighborhood clamp bounds the error.
//   - Disocclusion rejection: reprojected depth is compared with the previous depth buffer.
//   - YCoCg variance clipping: history is clamped to mean +/- gamma*sigma of the 3x3 current
//     neighborhood, intersected with the neighborhood AABB. This is what prevents ghosting.
//   - Sky pixels (depth == 1) and off-screen reprojections fall back to the current frame.
//
// HOW TO BUILD
//   No #version line. Prepend:
//     GLES 3.0/3.1 : "#version 300 es\n"  (or 310 es)
//     Vulkan       : "#version 450\n#define MABA_VULKAN 1\n"
//   Uses only texelFetch/texture, so OpenGL ES 3.0 is enough. highp is required for the depth
//   reprojection math (mandated in ES 3.0 fragment shaders).
//
// INPUT REQUIREMENTS
//   - Draw a full-screen triangle at RENDER resolution (viewport = render size).
//   - uMabaInput: current jittered scene color, LDR gamma space, LINEAR filter.
//   - uMabaJitter: the jitter applied this frame, in render texels, with the sign convention that
//     the image content moved BY +jitter (maba_temporal.h: MabaTemporalFrame.jitterX / jitterY).
//   - uMabaHistory: previous frame's resolve output (ping-pong), same size.
//   - uMabaDepth / uMabaPrevDepth: current / previous depth textures, NEAREST filter,
//     CLAMP_TO_EDGE, depth in [0,1] (GL convention; Vulkan NDC z is already [0,1]).
//   - uMabaInvViewProj: inverse of the CURRENT UNJITTERED view-projection matrix.
//   - uMabaPrevViewProj: the PREVIOUS frame's UNJITTERED view-projection matrix. (The history
//     is the accumulated, jitter-free image; reprojecting with a jittered matrix would resample
//     it at a different sub-texel offset every frame and blur it.)
//   - Scene projection must be jittered each frame; see maba_temporal.h for the Halton sequence.
//   - Reset (params.z = 1) on camera cuts, resolution changes, and the first frame.
//==============================================================================================

#ifndef MABA_VULKAN
#define MABA_VULKAN 0
#endif

// MABA_TEMPORAL_VELOCITY 1: reproject with the game's per-pixel motion vectors (camera AND
// objects, GL only) instead of the camera matrices. Moving objects keep their history instead of
// being rejected. MABA_TEMPORAL_SHARP 1: resample the history with Catmull-Rom instead of
// bilinear, which otherwise softens the image a little more every frame.
#ifndef MABA_TEMPORAL_VELOCITY
#define MABA_TEMPORAL_VELOCITY 0
#endif
#ifndef MABA_TEMPORAL_SHARP
#define MABA_TEMPORAL_SHARP 0
#endif
// How fast history is distrusted as a pixel moves: weight / (1 + K * motion in texels). Measured
// on the test scene (8 fps-independent PSNR against a 2x-supersampled reference): K = 0.05 let
// history cost 1.6 dB on moving content; K = 4 makes history never worse than none (22.3 vs 22.4
// dB) while a static scene keeps its +0.6 dB gain.
#ifndef MABA_TEMPORAL_MOTION_K
#define MABA_TEMPORAL_MOTION_K 4.0
#endif

precision highp float;
precision highp int;
precision highp sampler2D;

#if MABA_VULKAN
layout(set = 0, binding = 0) uniform sampler2D uMabaInput;
layout(set = 0, binding = 1) uniform sampler2D uMabaHistory;
layout(set = 0, binding = 2) uniform sampler2D uMabaDepth;
layout(set = 0, binding = 3) uniform sampler2D uMabaPrevDepth;
layout(set = 0, binding = 4) uniform MabaTemporalMatrices
{
    highp mat4 uMabaInvViewProj;
    highp mat4 uMabaPrevViewProj;
};
layout(push_constant) uniform MabaTemporalConstants
{
    highp vec4 uMabaTemporalParams;   // x=history weight, y=depth tolerance, z=reset, w=clip gamma
    highp vec2 uMabaTexel;            // 1 / allocated texture size
    highp vec2 uMabaRegion;           // render size in texels (image region, starts at 0,0)
    highp vec2 uMabaJitter;           // this frame's jitter in texels (the image content moved BY +jitter)
};
#else
uniform highp sampler2D uMabaInput;
uniform highp sampler2D uMabaHistory;
uniform highp sampler2D uMabaDepth;
uniform highp sampler2D uMabaPrevDepth;
uniform highp mat4 uMabaInvViewProj;
uniform highp mat4 uMabaPrevViewProj;
uniform highp vec4 uMabaTemporalParams;   // x=history weight, y=depth tolerance, z=reset, w=clip gamma
uniform highp vec2 uMabaTexel;            // 1 / allocated texture size
uniform highp vec2 uMabaRegion;           // render size in texels (image region, starts at 0,0)
uniform highp vec2 uMabaJitter;           // this frame's jitter in texels (the image content moved BY +jitter)
#if MABA_TEMPORAL_VELOCITY
uniform highp sampler2D uMabaVelocity;    // RG16F: UV motion since the previous frame (unjittered)
uniform highp vec2 uMabaDepthRange;       // near, far plane (depth is compared in view space)
#endif
#endif

layout(location = 0) out vec4 oMabaColor;

//----------------------------------------------------------------------------------------------
// YCoCg (reversible, cheap) for perceptual-ish clamping.
//----------------------------------------------------------------------------------------------

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

#if MABA_TEMPORAL_VELOCITY
float linearDepth(float d)
{
    float n = uMabaDepthRange.x;
    float f = uMabaDepthRange.y;
    return 2.0 * n * f / ((f + n) - (2.0 * d - 1.0) * (f - n));
}
#endif

// History colour at a texel-space position (pixel centres at +0.5), inside the image region.
vec3 sampleHistory(vec2 pos)
{
    pos = clamp(pos, vec2(0.5), uMabaRegion - 0.5);
#if MABA_TEMPORAL_SHARP
    vec2 tc = floor(pos - 0.5) + 0.5;
    vec2 f = pos - tc;
    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);
    vec2 w12 = w1 + w2;
    vec2 t12 = tc + w2 / w12;
    vec2 t0 = max(tc - 1.0, vec2(0.5));
    vec2 t3 = min(tc + 2.0, uMabaRegion - 0.5);
    vec3 c = textureLod(uMabaHistory, vec2(t12.x, t0.y) * uMabaTexel, 0.0).rgb * (w12.x * w0.y)
           + textureLod(uMabaHistory, vec2(t0.x, t12.y) * uMabaTexel, 0.0).rgb * (w0.x * w12.y)
           + textureLod(uMabaHistory, t12 * uMabaTexel, 0.0).rgb * (w12.x * w12.y)
           + textureLod(uMabaHistory, vec2(t3.x, t12.y) * uMabaTexel, 0.0).rgb * (w3.x * w12.y)
           + textureLod(uMabaHistory, vec2(t12.x, t3.y) * uMabaTexel, 0.0).rgb * (w12.x * w3.y);
    float wsum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return clamp(c / wsum, 0.0, 1.0);
#else
    return textureLod(uMabaHistory, pos * uMabaTexel, 0.0).rgb;
#endif
}

void main()
{
    ivec2 ip = ivec2(gl_FragCoord.xy);
    ivec2 size = ivec2(uMabaRegion);
    // The current frame was rendered with a sub-texel jitter: its content sits +jitter texels from
    // where an unjittered frame would have it. Read it back at the shifted position, so every
    // frame (and the history) describes the same unjittered pixel grid. Without this the output
    // is displaced by up to half a texel and loses about 2.4 dB.
    vec2 curPos = clamp(vec2(ip) + 0.5 + uMabaJitter, vec2(0.5), uMabaRegion - 0.5);
    vec3 cur = textureLod(uMabaInput, curPos * uMabaTexel, 0.0).rgb;
    float depth = texelFetch(uMabaDepth, ip, 0).r;

    // Reset, sky, or invalid depth: no history.
#if MABA_TEMPORAL_VELOCITY
    if (uMabaTemporalParams.z > 0.5 || depth <= 0.0)
#else
    if (uMabaTemporalParams.z > 0.5 || depth >= 1.0 || depth <= 0.0)
#endif
    {
        oMabaColor = vec4(cur, 1.0);
        return;
    }

    //------------------------------------------------------------------------------------------
    // Reproject this pixel into the previous frame (camera only).
    //------------------------------------------------------------------------------------------
#if MABA_TEMPORAL_VELOCITY
    vec2 uv = (vec2(ip) + 0.5) / uMabaRegion;
    vec2 puv = uv - texelFetch(uMabaVelocity, ip, 0).rg;
    if (any(lessThan(puv, vec2(0.0))) || any(greaterThan(puv, vec2(1.0))))
    {
        oMabaColor = vec4(cur, 1.0);
        return;
    }
    vec2 hpos = clamp(puv * uMabaRegion, vec2(0.5), uMabaRegion - 0.5);
    // Disocclusion: the surface seen last frame at the reprojected position must be at about the
    // same view-space distance (relative tolerance).
    float curLin = linearDepth(depth);
    float prevLin = linearDepth(texelFetch(uMabaPrevDepth, ivec2(hpos), 0).r);
    if (abs(prevLin - curLin) > uMabaTemporalParams.y * curLin)
    {
        oMabaColor = vec4(cur, 1.0);
        return;
    }
#else
    vec2 ndc = (vec2(ip) + 0.5) / uMabaRegion * 2.0 - 1.0;
#if MABA_VULKAN
    float ndcZ = depth;                 // Vulkan NDC z is [0,1]
#else
    float ndcZ = depth * 2.0 - 1.0;     // GL NDC z is [-1,1]
#endif
    vec4 wp = uMabaInvViewProj * vec4(ndc, ndcZ, 1.0);
    wp.xyz /= wp.w;
    vec4 pc = uMabaPrevViewProj * vec4(wp.xyz, 1.0);
    if (pc.w <= 0.0)
    {
        oMabaColor = vec4(cur, 1.0);
        return;
    }
    vec2 puv = pc.xy / pc.w * 0.5 + 0.5;
    if (any(lessThan(puv, vec2(0.0))) || any(greaterThan(puv, vec2(1.0))))
    {
        oMabaColor = vec4(cur, 1.0);
        return;
    }

    // Disocclusion: the reprojected depth must agree with what was actually there last frame.
#if MABA_VULKAN
    float expected = pc.z / pc.w;
#else
    float expected = pc.z / pc.w * 0.5 + 0.5;
#endif
    // Previous-frame sample position, kept half a texel inside the image region so the bilinear
    // history read never blends in stale texels from outside it.
    vec2 huv = clamp(puv * uMabaRegion, vec2(0.5), uMabaRegion - 0.5) * uMabaTexel;
    float prevDepth = texture(uMabaPrevDepth, huv).r;
    float tol = uMabaTemporalParams.y * (0.1 + expected);
    if (abs(expected - prevDepth) > tol)
    {
        oMabaColor = vec4(cur, 1.0);
        return;
    }

#endif

    //------------------------------------------------------------------------------------------
    // 3x3 neighborhood statistics of the CURRENT frame in YCoCg.
    //------------------------------------------------------------------------------------------
    vec3 m1 = vec3(0.0);
    vec3 m2 = vec3(0.0);
    vec3 mn = vec3(1e9);
    vec3 mx = vec3(-1e9);
    for (int dy = -1; dy <= 1; dy++)
    {
        for (int dx = -1; dx <= 1; dx++)
        {
            ivec2 p = clamp(ip + ivec2(dx, dy), ivec2(0), size - 1);
            vec3 c = toYCoCg(texelFetch(uMabaInput, p, 0).rgb);
            m1 += c;
            m2 += c * c;
            mn = min(mn, c);
            mx = max(mx, c);
        }
    }
    vec3 mean = m1 * (1.0 / 9.0);
    vec3 sigma = sqrt(max(m2 * (1.0 / 9.0) - mean * mean, vec3(0.0)));
    float gamma = uMabaTemporalParams.w;
    vec3 lo = max(mean - gamma * sigma, mn);
    vec3 hi = min(mean + gamma * sigma, mx);

    //------------------------------------------------------------------------------------------
    // Clamp history into the box, blend. Larger reprojection displacement trusts history less.
    //------------------------------------------------------------------------------------------
#if MABA_TEMPORAL_VELOCITY
    vec3 hist = toYCoCg(sampleHistory(hpos));
#else
    vec3 hist = toYCoCg(sampleHistory(huv / uMabaTexel));
#endif
    hist = clamp(hist, lo, hi);

#if !MABA_TEMPORAL_VELOCITY
    vec2 uv = (vec2(ip) + 0.5) / uMabaRegion;
#endif
    float disp = length((puv - uv) * uMabaRegion);       // previous-frame motion, in texels
    float w = uMabaTemporalParams.x / (1.0 + MABA_TEMPORAL_MOTION_K * disp);

    vec3 outc = fromYCoCg(mix(toYCoCg(cur), hist, w));
    oMabaColor = vec4(clamp(outc, 0.0, 1.0), 1.0);
}