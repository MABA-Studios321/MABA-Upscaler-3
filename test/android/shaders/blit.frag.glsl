// Plain bilinear upscale of the image region: the baseline.
precision mediump float;
uniform mediump sampler2D uMabaInput;
uniform highp vec4 uMabaInputSize;   // xy = region size in texels, zw = 1 / texture size
in highp vec2 vMabaUV;
layout(location = 0) out mediump vec4 oColor;
void main()
{
    highp vec2 uv = min(vMabaUV * uMabaInputSize.xy, uMabaInputSize.xy - 0.5) * uMabaInputSize.zw;
    oColor = vec4(textureLod(uMabaInput, uv, 0.0).rgb, 1.0);
}
