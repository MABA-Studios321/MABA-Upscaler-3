// MABA test scene - background sky, drawn first with depth test/write off. Matches the sky,
// exposure and tonemap in scene3d.frag.glsl, plus a sparse star field (sub-pixel detail stress).
precision highp float;
in highp vec2 vMabaUV;
layout(location = 0) out vec4 oColor;

// Jitter of the Temporal tier, in UV: the sky is generated from the screen position, so it must
// move with the jitter like geometry does (content moves BY +jitter), or it would not line up
// with the history. Zero when not jittered.
uniform highp vec2 uJitterUV;

// MABA Frame Gen variant: the sky moves with camera ROTATION only (it is infinitely far away).
#ifdef MABA_VELOCITY
uniform highp mat4 uInvVP;     // inverse of this frame's view-projection
uniform highp mat4 uPrevVP;    // previous real frame's view-projection
layout(location = 1) out highp vec2 oVelocity;
#endif

const vec3 ORANGE = vec3(1.0, 0.45, 0.08);

vec3 skyColor(float y)
{
    vec3 c = mix(vec3(0.030, 0.022, 0.035), vec3(0.004, 0.006, 0.016), smoothstep(0.0, 0.6, y));
    c = mix(vec3(0.003, 0.003, 0.005), c, smoothstep(-0.25, 0.02, y));
    c += ORANGE * 0.12 * exp(-abs(y) * 12.0);
    return c;
}

vec3 acesTonemap(vec3 x)
{
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main()
{
    // The camera looks slightly down at the core, so the horizon sits a little above centre.
    vec2 uvs = vMabaUV - uJitterUV;
    float y = (uvs.y - 0.58) * 1.3;
    vec3 col = skyColor(y);

    // Stars on a fixed angular grid (independent of render resolution), fading to the horizon.
    // Each cell may hold one small round star at a random offset (not a whole lit square).
    vec2 grid = uvs * vec2(150.0, 80.0);
    vec2 cell = floor(grid);
    float h = hash12(cell);
    vec2 off = vec2(hash12(cell + 17.0), hash12(cell + 41.0)) * 0.6 + 0.2;
    float d = length(fract(grid) - off);
    float star = step(0.975, h) * smoothstep(0.10, 0.0, d) * smoothstep(0.08, 0.5, y);
    col += vec3(0.75, 0.82, 1.0) * star * (0.3 + 1.2 * fract(h * 97.0));

    vec3 outc = pow(acesTonemap(col * 1.35), vec3(1.0 / 2.2));
    outc += (hash12(gl_FragCoord.xy) - 0.5) / 255.0;
    oColor = vec4(clamp(outc, 0.0, 1.0), 1.0);
#ifdef MABA_VELOCITY
    vec2 ndc = vMabaUV * 2.0 - 1.0;
    vec4 pn = uInvVP * vec4(ndc, 1.0, 1.0);
    vec4 pf = uInvVP * vec4(ndc, -1.0, 1.0);
    vec3 dir = pn.xyz / pn.w - pf.xyz / pf.w;           // world direction of this pixel
    vec4 pc = uPrevVP * vec4(dir, 0.0);                  // w = 0: rotation only
    vec2 prevN = pc.w > 1e-4 ? pc.xy / pc.w : ndc;
    oVelocity = (ndc - prevN) * 0.5;
#endif
}
