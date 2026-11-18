//==============================================================================================
// MABA Frame Generation warp - engine-neutral HLSL core (Unity / Unreal). Canonical: src/.
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// A "generated" frame is not rendered: the last REAL frame (the finished image and its depth, both at output
// resolution) is re-projected to the camera pose of the iteration being shown. For every pixel of the new view a short
// search along its ray finds the surface the old frame saw there: guess the new-view depth, find where that world
// point was in the old frame, read the old depth there, turn it back into a world point and a new-view depth, repeat.
// That is parallax-correct for camera motion; objects that move by themselves stay where the real frame had them.
//
// CONTRACT
//   depthTex     last real frame's depth, OUTPUT resolution. MABA_FG_DEPTH_MODE 0: window depth [0,1], 0 = near
//                (Unity); 1: reversed, infinite far (Unreal, Godot), sky = 0.
//   lastVP / lastInvVP   last real frame's UNJITTERED view-projection and its inverse (column-vector form)
//   newVP / newInvVP     the same for the camera of the iteration being shown
//   MABA_FG_Y_DOWN 1     when texture rows run top to bottom and clip-space y runs up (Unreal)
//==============================================================================================
#ifndef MABA_FG_WARP_HLSL
#define MABA_FG_WARP_HLSL

#ifndef MABA_FG_DEPTH_MODE
#define MABA_FG_DEPTH_MODE 0
#endif
#ifndef MABA_FG_Y_DOWN
#define MABA_FG_Y_DOWN 0
#endif
#ifndef MABA_FG_ITERATIONS
#define MABA_FG_ITERATIONS 4
#endif

float MabaFgNdcZ(float d)
{
#if MABA_FG_DEPTH_MODE == 1
    return max(d, 1e-6);                                  // sky (0) stays just inside the range so it still rotates
#else
    return clamp(d, 0.0, 0.999999) * 2.0 - 1.0;
#endif
}

float2 MabaFgUvToNdc(float2 uv)
{
    float2 n = uv * 2.0 - 1.0;
#if MABA_FG_Y_DOWN
    n.y = -n.y;
#endif
    return n;
}

float2 MabaFgNdcToUv(float2 n)
{
#if MABA_FG_Y_DOWN
    n.y = -n.y;
#endif
    return n * 0.5 + 0.5;
}

float MabaFgDepthAt(Texture2D depthTex, float2 uv, float2 outSize)
{
    int2 p = clamp(int2(uv * outSize), int2(0, 0), int2(outSize) - 1);
    return depthTex.Load(int3(p, 0)).r;
}

// Where in the last real frame (UV) does the surface seen at `uv` in the new view come from?
float2 MabaFgWarpSource(Texture2D depthTex, float2 uv, float2 outSize,
    float4x4 lastVP, float4x4 lastInvVP, float4x4 newVP, float4x4 newInvVP)
{
    float2 ndc = MabaFgUvToNdc(uv);
    float4 w0 = mul(lastInvVP, float4(ndc, MabaFgNdcZ(MabaFgDepthAt(depthTex, uv, outSize)), 1.0));
    w0 /= w0.w;
    float4 n0 = mul(newVP, w0);
    float zn = n0.z / n0.w;
    float2 puv = uv;
    [unroll] for (int i = 0; i < MABA_FG_ITERATIONS; i++)
    {
        float4 wp = mul(newInvVP, float4(ndc, zn, 1.0));
        wp /= wp.w;
        float4 pl = mul(lastVP, wp);
        puv = saturate(MabaFgNdcToUv(pl.xy / pl.w));
        float4 w2 = mul(lastInvVP, float4(MabaFgUvToNdc(puv), MabaFgNdcZ(MabaFgDepthAt(depthTex, puv, outSize)), 1.0));
        w2 /= w2.w;
        float4 n2 = mul(newVP, w2);
        zn = n2.z / n2.w;
    }
    return puv;
}

// The generated frame's pixel: the warped colour with the same 5-tap sharpen (clamped to the local range) the real frames get.
// `pixel` is SV_Position.xy of the output; outInfo = (width, height, 1/width, 1/height).
float4 MabaFgWarpPresent(Texture2D shownTex, Texture2D depthTex, SamplerState sampLinear, float2 pixel, float4 outInfo,
    float4x4 lastVP, float4x4 lastInvVP, float4x4 newVP, float4x4 newInvVP, float sharp)
{
    float2 uv = pixel * outInfo.zw;
    float2 puv = MabaFgWarpSource(depthTex, uv, outInfo.xy, lastVP, lastInvVP, newVP, newInvVP);
    float2 tx = outInfo.zw;
    float3 c = shownTex.SampleLevel(sampLinear, puv, 0).rgb;
    float3 n = shownTex.SampleLevel(sampLinear, puv + float2(0.0, tx.y), 0).rgb;
    float3 s = shownTex.SampleLevel(sampLinear, puv - float2(0.0, tx.y), 0).rgb;
    float3 e = shownTex.SampleLevel(sampLinear, puv + float2(tx.x, 0.0), 0).rgb;
    float3 w = shownTex.SampleLevel(sampLinear, puv - float2(tx.x, 0.0), 0).rgb;
    float3 mn = min(min(min(n, s), min(e, w)), c);
    float3 mx = max(max(max(n, s), max(e, w)), c);
    return float4(clamp(c + sharp * (4.0 * c - n - s - e - w), mn, mx), 1.0);
}

#endif // MABA_FG_WARP_HLSL