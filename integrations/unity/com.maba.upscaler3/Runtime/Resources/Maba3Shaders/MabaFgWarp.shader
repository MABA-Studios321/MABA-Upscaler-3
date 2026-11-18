// MABA Upscaler 3 - Unity Frame Generation: draws a generated frame (the last real frame re-projected to the camera pose of
// this frame) straight into the screen. See MabaFgWarp.hlsl.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
Shader "MABA3/FgWarp"
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
            #define MABA_FG_DEPTH_MODE 0
            #define MABA_FG_Y_DOWN 0
            #include "MabaFgWarp.hlsl"

            Texture2D _MabaShown;      // the last real frame (temporal result, output resolution)
            Texture2D _MabaOutDepth;   // its depth (GL window depth), output resolution
            SamplerState sampler_LinearClamp;
            float4x4 _LastVP;
            float4x4 _LastInvVP;
            float4x4 _NewVP;
            float4x4 _NewInvVP;
            float4 _OutInfo;           // xy = output size, zw = 1 / output size
            float4 _MabaParams;        // x = sharpen strength

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
                // The pixel is rebuilt from the interpolated UV so it addresses the render textures' own rows whichever way
                // the platform orients the back buffer (same as the present pass).
                return MabaFgWarpPresent(_MabaShown, _MabaOutDepth, sampler_LinearClamp, i.uv * _OutInfo.xy, _OutInfo,
                    _LastVP, _LastInvVP, _NewVP, _NewInvVP, _MabaParams.x);
            }
            ENDHLSL
        }
    }
}