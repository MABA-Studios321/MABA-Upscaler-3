//==============================================================================================
// MABA Temporal SR - engine-neutral HLSL core (Unity / Unreal). Canonical: src/.
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// Port of maba_temporal_sr.frag.glsl (the output-resolution temporal super-resolution used by
// MABA Upscaler 3). The neighbourhood variance-clipping approach is inspired by AMD FidelityFX
// Super Resolution 2 and temporal anti-aliasing upscalers in general; this is an independent
// implementation. See that file for the full description. In short, per OUTPUT pixel and frame:
//   1. the 2x2 jittered render texels around it are read once and weighted by their true distance:
//      a NARROW kernel (accumulated) and a WIDE kernel (bilinear quality, the fallback);
//   2. the output-resolution history is reprojected with the motion vectors, rejected where depth
//      disagrees (only for pixels that really move), clamped to the neighbourhood in YCoCg and blended
//      as a weighted running average;
//   3. the image shown blends the accumulated history with the wide estimate by confidence.
// MabaTsrPresent then sharpens the shown image, clamped to the local range (never fed back).
//
// CONTRACT
//   inputTex     current jittered render-resolution colour, LDR gamma space, region at texel (0,0)
//   histTex      previous history, OUTPUT resolution, half float: rgb = colour, a = weight / WMAX
//   depthTex     render-resolution depth. MABA_TSR_DEPTH_MODE selects the convention:
//                  0 window depth [0,1], 0 = near .. 1 = far, needs params.near / .far
//                  1 reversed, infinite far (Unreal, Godot): linear z = near / d
//   prevDepthTex previous frame's depth, same convention, at OUTPUT resolution (last frame's
//                MabaTsrOut.depth; every render target of the pass must have the same size)
//   velTex       RG: surface motion in UV units, current UV minus previous UV, unjittered
//                (only with MABA_TSR_VELOCITY_TEX 1; otherwise the motion is rebuilt from the depth and
//                invViewProj / prevViewProj, which moves only with the camera)
//   region       render size in texels;  out = (output width, height, 1/width, 1/height)
//   jitter       this frame's jitter in render texels, the image content moved BY +jitter
//   params       x unused, y depth tolerance (relative, 0.01), z reset (1 = ignore history), w clip gamma (1.25)
//   depthRange   x = near, y = far (mode 0) / near (mode 1)
// Rows: pixel row 0 / UV origin must be the same for every texture (MABA_TSR_Y_DOWN 1 for engines
// whose screen rows run top to bottom: only affects the camera-only velocity rebuild).
//==============================================================================================
#ifndef MABA_TSR_HLSL
#define MABA_TSR_HLSL

#ifndef MABA_TSR_R
#define MABA_TSR_R 5.0
#endif
#ifndef MABA_TSR_RW
#define MABA_TSR_RW 0.5
#endif
#ifndef MABA_TSR_PRIOR
#define MABA_TSR_PRIOR 0.5
#endif
#ifndef MABA_TSR_WMAX
#define MABA_TSR_WMAX 12.0
#endif
#ifndef MABA_TSR_MOTION_K
#define MABA_TSR_MOTION_K 8.0
#endif
#ifndef MABA_TSR_DEPTH_MOTION
#define MABA_TSR_DEPTH_MOTION 0.15
#endif
#ifndef MABA_TSR_DEPTH_MODE
#define MABA_TSR_DEPTH_MODE 0
#endif
#ifndef MABA_TSR_VELOCITY_TEX
#define MABA_TSR_VELOCITY_TEX 1
#endif
#ifndef MABA_TSR_Y_DOWN
#define MABA_TSR_Y_DOWN 0
#endif

struct MabaTsrOut
{
    float4 hist;    // new history: rgb colour, a = accumulated weight / MABA_TSR_WMAX
    float4 shown;   // the image to show (before the present sharpen)
    float  depth;   // this frame's depth (nearest render texel) at OUTPUT resolution: next frame's prevDepthTex
};

float3 MabaTsrToYCoCg(float3 c)
{
    return float3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
                  0.5 * c.r - 0.5 * c.b,
                 -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}

float3 MabaTsrFromYCoCg(float3 c)
{
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// View-space distance from a depth sample (only ratios matter).
float MabaTsrLinearDepth(float d, float2 depthRange)
{
#if MABA_TSR_DEPTH_MODE == 1
    return depthRange.x / max(d, 1e-7);
#else
    float n = depthRange.x;
    float f = depthRange.y;
    return 2.0 * n * f / ((f + n) - (2.0 * d - 1.0) * (f - n));
#endif
}

MabaTsrOut MabaTsrResolve(
    Texture2D inputTex, Texture2D histTex, Texture2D depthTex, Texture2D prevDepthTex, Texture2D velTex,
    SamplerState sampLinear, float2 pixel,
    float4 params, float2 texel, float2 region, float4 outInfo, float2 jitter, float2 depthRange
#if !MABA_TSR_VELOCITY_TEX
    , float4x4 invViewProj, float4x4 prevViewProj
#endif
    )
{
    MabaTsrOut o;
    o.depth = 0.0;
    float2 uv = pixel * outInfo.zw;                       // pixel = SV_Position.xy: already at the pixel centre
    // Where this output pixel sits in the JITTERED render image (content moved BY +jitter).
    float2 lp = uv * region + jitter;
    int2 c0 = int2(floor(lp));
    int2 cb = int2(floor(lp - 0.5));                      // lower-left texel of the 2x2 block around it
    int2 lim = int2(region) - 1;

    float3 accN = 0.0, accW = 0.0;
    float wsN = 0.0, wsW = 0.0;
    float3 m1 = 0.0, m2 = 0.0;
    float3 mn = 1e9, mx = -1e9;
    [unroll] for (int dy = 0; dy <= 1; dy++)
    {
        [unroll] for (int dx = 0; dx <= 1; dx++)
        {
            int2 oi = cb + int2(dx, dy);
            float3 c = inputTex.Load(int3(clamp(oi, int2(0, 0), lim), 0)).rgb;
            float2 dd = float2(oi) + 0.5 - lp;
            float d2 = dot(dd, dd);
            float wn = max(1.0 - MABA_TSR_R * d2, 0.0);
            float ww = max(1.0 - MABA_TSR_RW * d2, 0.0);
            wn *= wn;
            ww *= ww;
            accN += c * wn;  wsN += wn;
            accW += c * ww;  wsW += ww;
            float3 y = MabaTsrToYCoCg(c);
            m1 += y;  m2 += y * y;
            mn = min(mn, y);  mx = max(mx, y);
        }
    }
    const float tiny = 1e-4;
    float3 curN = accN / max(wsN, tiny);
    float3 curW = accW / max(wsW, tiny);

    float wNoHist = min(wsN, MABA_TSR_WMAX);
    float3 shownNoHist = lerp(curW, curN, wNoHist / (wNoHist + MABA_TSR_PRIOR));
    o.hist = float4(curN, wNoHist / MABA_TSR_WMAX);
    o.shown = float4(shownNoHist, 1.0);

    int2 n = clamp(c0, int2(0, 0), lim);
    float depth = depthTex.Load(int3(n, 0)).r;
    o.depth = depth;
    // The sky (reversed Z: depth 0, infinitely far) is NOT special-cased. It is reprojected like any surface (a point at
    // infinity only rotates with the camera), so it keeps its history. An early "no history for the sky" return makes every
    // silhouette against the sky crawl: which render texel is nearest to an edge pixel changes with the jitter phase, so the
    // pixel would flip between "reset" and "accumulated" from frame to frame (measured in Unreal: 39 dB frame-to-frame on a
    // still camera, 56 dB without it).
    if (params.z > 0.5)
        return o;

#if MABA_TSR_VELOCITY_TEX
    float2 vel = velTex.Load(int3(n, 0)).rg;
#else
    // Camera-only motion rebuilt from the depth: world position from this frame's unjittered
    // matrices, projected with last frame's.
    float2 ndc = uv * 2.0 - 1.0;
  #if MABA_TSR_Y_DOWN
    ndc.y = -ndc.y;
  #endif
  #if MABA_TSR_DEPTH_MODE == 1
    float ndcZ = max(depth, 1e-6);                        // [0,1] NDC z, reversed; the sky (0) stays just inside the range
  #else
    float ndcZ = depth * 2.0 - 1.0;
  #endif
    float4 wp = mul(invViewProj, float4(ndc, ndcZ, 1.0));
    wp.xyz /= wp.w;
    float4 pc = mul(prevViewProj, float4(wp.xyz, 1.0));
    if (pc.w <= 0.0)
        return o;
    float2 pndc = pc.xy / pc.w;
  #if MABA_TSR_Y_DOWN
    pndc.y = -pndc.y;
  #endif
    float2 vel = uv - (pndc * 0.5 + 0.5);
#endif
    float2 puv = uv - vel;
    if (any(puv < 0.0) || any(puv > 1.0))
        return o;
    float disp = length(vel * region);                    // motion in render texels
    // Disocclusion, only where the pixel moves: the surface seen last frame at the reprojected
    // position must be at about the same view-space distance.
    if (disp > MABA_TSR_DEPTH_MOTION)
    {
        float curLin = MabaTsrLinearDepth(depth, depthRange);
        float prevLin = MabaTsrLinearDepth(prevDepthTex.Load(int3(clamp(int2(puv * outInfo.xy), int2(0, 0), int2(outInfo.xy) - 1), 0)).r, depthRange);
        if (abs(prevLin - curLin) > params.y * curLin)
            return o;
    }

    float3 mean = m1 * 0.25;
    float3 sigma = sqrt(max(m2 * 0.25 - mean * mean, 0.0));
    float gam = params.w;
    float3 lo = max(mean - gam * sigma, mn);
    float3 hi = min(mean + gam * sigma, mx);
    float2 hpos = clamp(puv * outInfo.xy, 0.5, outInfo.xy - 0.5);
    float4 hs = histTex.SampleLevel(sampLinear, hpos * outInfo.zw, 0);
    float3 hist = clamp(MabaTsrToYCoCg(hs.rgb), lo, hi);

    // Weighted running average: a frame counts in proportion to how close its samples were. There
    // is deliberately no minimum share for the new frame. Fast motion trusts the history less.
    float wh = hs.a * MABA_TSR_WMAX / (1.0 + MABA_TSR_MOTION_K * disp);
    float a = wsN / (wh + wsN + tiny);
    float3 histNew = saturate(MabaTsrFromYCoCg(lerp(hist, MabaTsrToYCoCg(curN), a)));
    float wNew = min(wh + wsN, MABA_TSR_WMAX);

    o.hist = float4(histNew, wNew / MABA_TSR_WMAX);
    o.shown = float4(lerp(curW, histNew, wNew / (wNew + MABA_TSR_PRIOR)), 1.0);
    return o;
}

// Present: 5-tap sharpen of the shown image, clamped to the local range. sharp 0 = plain copy; about
// 0.06 (the app's default sharpness 0.5 * 0.12) to 0.3 is useful.
float4 MabaTsrPresent(Texture2D shownTex, float2 pixel, float4 outInfo, float sharp)
{
    int2 ip = int2(pixel);
    int2 lim = int2(outInfo.xy) - 1;
    float3 c = shownTex.Load(int3(ip, 0)).rgb;
    float3 n = shownTex.Load(int3(clamp(ip + int2(0, 1), int2(0, 0), lim), 0)).rgb;
    float3 s = shownTex.Load(int3(clamp(ip - int2(0, 1), int2(0, 0), lim), 0)).rgb;
    float3 e = shownTex.Load(int3(clamp(ip + int2(1, 0), int2(0, 0), lim), 0)).rgb;
    float3 w = shownTex.Load(int3(clamp(ip - int2(1, 0), int2(0, 0), lim), 0)).rgb;
    float3 mn = min(min(min(n, s), min(e, w)), c);
    float3 mx = max(max(max(n, s), max(e, w)), c);
    return float4(clamp(c + sharp * (4.0 * c - n - s - e - w), mn, mx), 1.0);
}

#endif // MABA_TSR_HLSL
