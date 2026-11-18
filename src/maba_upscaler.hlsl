//==============================================================================================
// MABA Upscaler - engine-neutral HLSL core (Unity / Unreal). Canonical source: src/.
// The Unity package and UE plugin carry synced copies (test/sync_hlsl.ps1).
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// The quality path is derived from AMD FidelityFX Super Resolution 1.0 (EASU), MIT licence;
// see THIRD_PARTY_NOTICES.md. Faithful port of maba_upscaler.frag.glsl.
//
// Input contract: finished LDR gamma-space color; LINEAR filter, CLAMP address, no mips;
// image region starts at texel (0,0); size = (regionW, regionH, 1/texW, 1/texH);
// params = (sharpness 0..1, 0, 0, 0). Draw UI after this pass at output resolution.
//==============================================================================================
#ifndef MABA_UPSCALER_HLSL
#define MABA_UPSCALER_HLSL

#ifndef MABA_DARK_LO
#define MABA_DARK_LO 0.02
#endif
#ifndef MABA_DARK_HI
#define MABA_DARK_HI 0.12
#endif
// Extra gain on the edge-reconstructed luma, as a fraction of the sharpness setting (see
// maba_upscaler.frag.glsl for the measurement behind 0.5).
#ifndef MABA_QUALITY_GAIN
#define MABA_QUALITY_GAIN 0.5
#endif
#ifndef MABA_EDGE_LO
#define MABA_EDGE_LO (10.0 / 255.0)
#endif
#ifndef MABA_EDGE_HI
#define MABA_EDGE_HI (24.0 / 255.0)
#endif

float2 MabaSharpPos(float2 pp, float brightness, float sharpness)
{
    float s = sharpness * saturate((brightness - MABA_DARK_LO) * (1.0 / (MABA_DARK_HI - MABA_DARK_LO)));
    return pp + s * pp * (pp - 1.0) * (1.0 - 2.0 * pp);
}

float MabaDiagonal(float f, float g, float j, float k)
{
    float dFK = abs(f - k);
    float dGJ = abs(g - j);
    return saturate(0.5 + (dGJ - dFK) / (dGJ + dFK + 1.0 / 255.0));
}

float MabaTwistWeight(float2 p, float preferFK)
{
    return lerp(max(p.x + p.y - 1.0, 0.0), min(p.x, p.y), preferFK);
}

float MabaBlockDelta(float f, float g, float j, float k, float2 pp, float sharpness)
{
    float2 p = MabaSharpPos(pp, max(max(f, g), max(j, k)), sharpness);
    return (g - f) * (p.x - pp.x) + (j - f) * (p.y - pp.y)
         + (f - g - j + k) * (MabaTwistWeight(p, MabaDiagonal(f, g, j, k)) - pp.x * pp.y);
}

float2 MabaPos(float2 uv, float4 size)
{
    return clamp(uv * size.xy - 0.5, float2(0.0, 0.0), size.xy - 1.001);
}

float3 MabaBilinear(Texture2D tex, SamplerState samp, float2 uv, float4 size)
{
    float2 suv = min(uv * size.xy, size.xy - 0.5) * size.zw;
    return tex.SampleLevel(samp, suv, 0).rgb;
}

// Define MABA_NO_GATHER 1 before including this file on targets without texture gather
// (ES 3.0 / feature level 9_3 class); only MabaUpscaleFastNoGather is then available.
#ifndef MABA_NO_GATHER
#define MABA_NO_GATHER 0
#endif

#if !MABA_NO_GATHER
// Fast build: 1 gather (green as luma) + bilinear colour.
float4 MabaUpscaleFast(Texture2D tex, SamplerState samp, float2 uv, float4 size, float4 params)
{
    float2 pos = MabaPos(uv, size);
    float2 fp = floor(pos);
    float2 pp = pos - fp;
    float3 color = MabaBilinear(tex, samp, uv, size);
    float4 q = tex.GatherGreen(samp, (fp + 1.0) * size.zw);
    float delta = MabaBlockDelta(q.w, q.z, q.x, q.y, pp, params.x);
    return float4(saturate(color + delta), 1.0);
}
#endif

// Gather-free variant (feature level 9_3 / ES 3.0 class hardware).
float4 MabaUpscaleFastNoGather(Texture2D tex, SamplerState samp, float2 uv, float4 size, float4 params)
{
    float2 pos = MabaPos(uv, size);
    float2 fp = floor(pos);
    float2 pp = pos - fp;
    int2 lim = int2(size.xy) - 1;
    int2 i0 = clamp(int2(fp), int2(0, 0), lim);
    int2 i1 = clamp(int2(fp) + 1, int2(0, 0), lim);
    float3 f = tex.Load(int3(i0, 0)).rgb;
    float3 g = tex.Load(int3(i1.x, i0.y, 0)).rgb;
    float3 j = tex.Load(int3(i0.x, i1.y, 0)).rgb;
    float3 k = tex.Load(int3(i1, 0)).rgb;
    float2 p = MabaSharpPos(pp, max(max(f.g, g.g), max(j.g, k.g)), params.x);
    float w = MabaTwistWeight(p, MabaDiagonal(f.g, g.g, j.g, k.g));
    return float4(f + (g - f) * p.x + (j - f) * p.y + (f - g - j + k) * w, 1.0);
}

void MabaSet(inout float2 dir, inout float len, float w,
             float lA, float lB, float lC, float lD, float lE)
{
    float dirX = lD - lB;
    float lenX = max(abs(lD - lC), abs(lC - lB));
    lenX = saturate(abs(dirX) / max(lenX, 1.0 / 512.0));
    dir.x += dirX * w;
    len += lenX * lenX * w;

    float dirY = lE - lA;
    float lenY = max(abs(lE - lC), abs(lC - lA));
    lenY = saturate(abs(dirY) / max(lenY, 1.0 / 512.0));
    dir.y += dirY * w;
    len += lenY * lenY * w;
}

void MabaTap(inout float aC, inout float aW, float2 off, float2 dir, float2 len2,
             float lob, float clp, float c)
{
    float2 v = float2(off.x * dir.x + off.y * dir.y, off.y * dir.x - off.x * dir.y) * len2;
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

#if !MABA_NO_GATHER
// Quality build: adaptive 12-tap edge kernel on luma (FSR1 EASU-derived).
float4 MabaUpscaleQuality(Texture2D tex, SamplerState samp, float2 uv, float4 size, float4 params)
{
    float2 pos = MabaPos(uv, size);
    float2 fp = floor(pos);
    float2 pp = pos - fp;
    float3 color = MabaBilinear(tex, samp, uv, size);

    float4 q = tex.GatherGreen(samp, (fp + 1.0) * size.zw);
    float f = q.w, g = q.z, j = q.x, k = q.y;
    float mn = min(min(f, g), min(j, k));
    float mx = max(max(f, g), max(j, k));
    float blockDelta = MabaBlockDelta(f, g, j, k, pp, params.x);
    float contrast = mx - mn;

    if (contrast < MABA_EDGE_LO || any(fp < 1.0) || any(fp + 2.5 > size.xy))
        return float4(saturate(color + blockDelta), 1.0);

    float2 p0 = (fp + float2(1.0, -1.0)) * size.zw;
    float4 ijfe = tex.GatherGreen(samp, p0 + float2(-1.0, 2.0) * size.zw);
    float4 klhg = tex.GatherGreen(samp, p0 + float2(1.0, 2.0) * size.zw);
    float4 bczz = tex.GatherGreen(samp, p0);
    float4 zzon = tex.GatherGreen(samp, p0 + float2(0.0, 4.0) * size.zw);
    float b = bczz.x, c = bczz.y;
    float i = ijfe.x, e = ijfe.w;
    float l = klhg.y, h = klhg.z;
    float o = zzon.z, n = zzon.w;

    float2 dir = float2(0.0, 0.0);
    float len = 0.0;
    MabaSet(dir, len, (1.0 - pp.x) * (1.0 - pp.y), b, e, f, g, j);
    MabaSet(dir, len, pp.x * (1.0 - pp.y),         c, f, g, h, k);
    MabaSet(dir, len, (1.0 - pp.x) * pp.y,         f, i, j, k, n);
    MabaSet(dir, len, pp.x * pp.y,                 g, j, k, l, o);

    float dirR = dot(dir, dir);
    bool zro = dirR < (1.0 / 8192.0);
    dir = zro ? float2(1.0, 0.0) : dir * rsqrt(dirR);

    len = len * 0.5;
    len *= len;
    float stretch = 1.0 / max(abs(dir.x), abs(dir.y));
    float2 len2 = float2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    float lob = 0.5 - 0.29 * len;
    float clp = 1.0 / lob;

    float aC = 0.0, aW = 0.0;
    MabaTap(aC, aW, float2(0.0, -1.0) - pp, dir, len2, lob, clp, b);
    MabaTap(aC, aW, float2(1.0, -1.0) - pp, dir, len2, lob, clp, c);
    MabaTap(aC, aW, float2(-1.0, 1.0) - pp, dir, len2, lob, clp, i);
    MabaTap(aC, aW, float2(0.0, 1.0) - pp, dir, len2, lob, clp, j);
    MabaTap(aC, aW, float2(0.0, 0.0) - pp, dir, len2, lob, clp, f);
    MabaTap(aC, aW, float2(-1.0, 0.0) - pp, dir, len2, lob, clp, e);
    MabaTap(aC, aW, float2(1.0, 1.0) - pp, dir, len2, lob, clp, k);
    MabaTap(aC, aW, float2(2.0, 1.0) - pp, dir, len2, lob, clp, l);
    MabaTap(aC, aW, float2(2.0, 0.0) - pp, dir, len2, lob, clp, h);
    MabaTap(aC, aW, float2(1.0, 0.0) - pp, dir, len2, lob, clp, g);
    MabaTap(aC, aW, float2(1.0, 2.0) - pp, dir, len2, lob, clp, o);
    MabaTap(aC, aW, float2(0.0, 2.0) - pp, dir, len2, lob, clp, n);

    float edgeG = clamp(aC / aW, mn, mx);
    float bilG = lerp(lerp(f, g, pp.x), lerp(j, k, pp.x), pp.y);
    float gain = 1.0 + MABA_QUALITY_GAIN * params.x * smoothstep(MABA_DARK_LO, MABA_DARK_HI, bilG);
    float outG = clamp(bilG + (edgeG - bilG) * gain, mn, mx);
    float blend = saturate((contrast - MABA_EDGE_LO) * (1.0 / (MABA_EDGE_HI - MABA_EDGE_LO)));
    return float4(saturate(color + lerp(blockDelta, outG - bilG, blend)), 1.0);
}
#endif

#endif // MABA_UPSCALER_HLSL