// Depth copy for the temporal tier: reads the pipeline's global _CameraDepthTexture (built-in
// and URP both bind it while the camera renders, and it stays bound afterwards) and writes GL
// window depth (0 = near, 1 = far) into the render region of a single-channel float target.
// The result is this frame's depth for the resolve pass and next frame's previous depth.
// Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
Shader "MABA3/DepthCopy"
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
            Texture2D<float> _CameraDepthTexture;
            SamplerState sampler_PointClamp;
            float4 _Region;          // xy = render region in texels (the viewport of this pass)
            float _MabaReversedZ;    // 1 when the platform stores depth reversed (1 near .. 0 far)

            float4 Vert(uint id : SV_VertexID) : SV_Position
            {
                float2 p = float2((id << 1) & 2, id & 2);
                return float4(p * 2.0 - 1.0, 0.0, 1.0);
            }

            float4 Frag(float4 pos : SV_Position) : SV_Target
            {
                // The camera depth texture covers exactly the camera's view, whatever its size.
                float d = _CameraDepthTexture.SampleLevel(sampler_PointClamp, pos.xy / _Region.xy, 0);
                if (_MabaReversedZ > 0.5) d = 1.0 - d;
                return float4(d, 0.0, 0.0, 1.0);
            }
            ENDHLSL
        }
    }
}
