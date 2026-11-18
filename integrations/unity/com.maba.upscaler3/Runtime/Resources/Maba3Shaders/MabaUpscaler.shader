// MABA Upscaler - Unity shader. Pass 0 = fast, pass 1 = quality.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
Shader "MABA3/Upscaler"
{
    SubShader
    {
        Cull Off ZTest Always ZWrite Off

        HLSLINCLUDE
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
        ENDHLSL

        Pass
        {
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragFast
            #pragma target 4.5
            float4 FragFast(Vary i) : SV_Target
            {
                return MabaUpscaleFast(_MabaInput, sampler_MabaInput, i.uv, _MabaInputSize, _MabaParams);
            }
            ENDHLSL
        }

        Pass
        {
            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment FragQuality
            #pragma target 4.5
            float4 FragQuality(Vary i) : SV_Target
            {
                return MabaUpscaleQuality(_MabaInput, sampler_MabaInput, i.uv, _MabaInputSize, _MabaParams);
            }
            ENDHLSL
        }
    }
}