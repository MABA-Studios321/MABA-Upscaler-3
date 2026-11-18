// MABA Upscaler 3 - Unity temporal super-resolution resolve. Runs at OUTPUT resolution and writes three
// targets of the same size: the new history, the image to show, and this frame's depth (next frame's
// previous depth). Reads the jittered render-region colour and the GL-convention depth copy.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
Shader "MABA3/Tsr"
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
            // GL window depth (0 = near .. 1 = far), camera-only motion rebuilt from the depth with
            // GL-convention matrices, render textures stored with row 0 at the bottom of the image.
            #define MABA_TSR_DEPTH_MODE 0
            #define MABA_TSR_VELOCITY_TEX 0
            #define MABA_TSR_Y_DOWN 0
            #include "MabaTsr.hlsl"

            Texture2D _MabaInput;     // scene colour (render region at texel 0,0)
            Texture2D _History;       // previous history, output resolution
            Texture2D _Depth;         // this frame's depth, render region
            Texture2D _PrevDepth;     // previous frame's depth, output resolution
            SamplerState sampler_LinearClamp;
            float4x4 _InvVP;          // inverse of this frame's UNJITTERED view-projection
            float4x4 _PrevVP;         // last frame's UNJITTERED view-projection
            float4 _TParams;          // y depth tolerance, z reset, w clip gamma
            float4 _Region;           // xy = render size in texels
            float4 _OutInfo;          // xy = output size, zw = 1 / output size
            float4 _Jitter;           // xy = this frame's jitter in render texels
            float4 _DepthRange;       // x near, y far

            float4 Vert(uint id : SV_VertexID) : SV_Position
            {
                float2 p = float2((id << 1) & 2, id & 2);
                return float4(p * 2.0 - 1.0, 0.0, 1.0);
            }

            struct FragOut
            {
                float4 hist : SV_Target0;
                float4 shown : SV_Target1;
                float depth : SV_Target2;
            };

            FragOut Frag(float4 pos : SV_Position)
            {
                MabaTsrOut r = MabaTsrResolve(_MabaInput, _History, _Depth, _PrevDepth, _MabaInput,
                    sampler_LinearClamp, pos.xy, _TParams, float2(0, 0), _Region.xy, _OutInfo, _Jitter.xy,
                    _DepthRange.xy, _InvVP, _PrevVP);
                FragOut o;
                o.hist = r.hist;
                o.shown = r.shown;
                o.depth = r.depth;
                return o;
            }
            ENDHLSL
        }
    }
}