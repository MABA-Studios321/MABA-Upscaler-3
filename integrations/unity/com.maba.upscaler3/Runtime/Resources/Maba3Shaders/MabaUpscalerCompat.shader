// MABA Upscaler - Unity shader for hardware without texture gather (OpenGL ES 3.0 class).
// One pass: the gather-free fast build, used for every rung.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
Shader "MABA3/UpscalerCompat"
{
    SubShader
    {
        Cull Off ZTest Always ZWrite Off

        Pass
        {
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #pragma target 3.5
            #define MABA_NO_GATHER 1
            #include "MabaCore.hlsl"

            Texture2D _MabaInput;
            SamplerState sampler_MabaInput;
            float4 _MabaInputSize;
            float4 _MabaParams;

            struct Vary
            {
                float4 pos : SV_Position;
                float2 uv : TEXCOORD0;
            };

            Vary Vert(uint id : SV_VertexID)
            {
                float2 p = float2((id << 1) & 2, id & 2);
                Vary o;
                o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
                o.uv = p;
                return o;
            }

            float4 Frag(Vary i) : SV_Target
            {
                return MabaUpscaleFastNoGather(_MabaInput, sampler_MabaInput, i.uv, _MabaInputSize, _MabaParams);
            }
            ENDHLSL
        }
    }
}
