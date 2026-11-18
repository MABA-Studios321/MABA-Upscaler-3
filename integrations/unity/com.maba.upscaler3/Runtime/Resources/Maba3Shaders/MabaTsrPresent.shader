// MABA Upscaler 3 - Unity present pass: sharpens the temporal result into the screen.
// The pixel is rebuilt from the interpolated UV so it addresses the render texture's own storage rows
// whichever way the platform orients the back buffer.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
Shader "MABA3/TsrPresent"
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
            #include "MabaTsr.hlsl"

            Texture2D _MabaShown;
            float4 _OutInfo;          // xy = output size, zw = 1 / output size
            float4 _MabaParams;       // x = sharpen strength

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
                return MabaTsrPresent(_MabaShown, floor(i.uv * _OutInfo.xy), _OutInfo, _MabaParams.x);
            }
            ENDHLSL
        }
    }
}