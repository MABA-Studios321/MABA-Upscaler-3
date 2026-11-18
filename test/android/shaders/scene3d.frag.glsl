// MABA test scene - "MABA Core": a plasma reactor orb inside a geodesic cage of thin beams,
// orbited by crystal shards and fed by an energy beam from a stepped pedestal; a halo of
// emissive blades, detailed lamp pillars and a polished grid floor. Header (#version 300 es)
// prepended by the app.
//
// Lighting is physically based, in the style of Unreal's mobile renderer: GGX distribution,
// Smith visibility, Schlick fresnel, the UE4/5 mobile analytic environment BRDF, an analytic
// sky environment for reflections. Lights: a cool key light with a soft analytic shadow from
// the orb, the orb itself as a warm point light, the pedestal glow, the nearest pillar lamp,
// and the blade halo as a ring light (cheap fake GI). Analytic ambient occlusion, a fake floor
// mirror of the orb and halo, height fog, ACES tonemap, gamma encode and dither. Output is the
// finished LDR gamma-space colour MABA expects.
//
// Materials (vMat): 0 plasma orb, 1 halo blades, 2 floor, 3 cage beams, 4 structure metal,
// 5 crystal shards, 6 cyan emissive (lamps, cage joints), 7 pillar shaft, 8 warm energy beam.
precision highp float;

uniform highp vec3 uCamPos;
uniform highp vec4 uCore;   // xyz = centre of the plasma orb, w = its radius
uniform float uTime;
uniform int uLoad;

in highp vec3 vWorld;
in mediump vec3 vNormal;
in mediump vec2 vUV;
flat in mediump float vMat;

layout(location = 0) out vec4 oColor;
#ifdef MABA_VELOCITY
in highp vec4 vCurClip;
in highp vec4 vPrevClip;
uniform highp vec2 uJitter;   // this frame's projection jitter in NDC (0 when not jittered)
layout(location = 1) out highp vec2 oVelocity;   // UV motion since the previous real frame
#endif

const float PI = 3.14159265;
const vec3 ORANGE = vec3(1.0, 0.45, 0.08);
const vec3 WARM = vec3(1.0, 0.62, 0.28);
const vec3 CYAN = vec3(0.10, 0.62, 1.0);
// Mirrors Scene3D.java.
const float FLOOR_Y = -1.55;
const float HALO_R = 2.55;
const float HALO_Y = -1.0;
const float PILLAR_R = 6.2;
const float PILLARS = 10.0;

// ---------------------------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------------------------

// Night sky with a warm horizon band (shared with bg.frag.glsl).
vec3 skyColor(vec3 d)
{
    float y = d.y;
    vec3 c = mix(vec3(0.030, 0.022, 0.035), vec3(0.004, 0.006, 0.016), smoothstep(0.0, 0.6, y));
    c = mix(vec3(0.003, 0.003, 0.005), c, smoothstep(-0.25, 0.02, y));
    c += ORANGE * 0.12 * exp(-abs(y) * 12.0);
    return c;
}

// What reflective surfaces see: the sky, a big soft overhead light panel, and the warm glow
// coming up from the floor around the pedestal.
vec3 envColor(vec3 d, float rough)
{
    vec3 c = skyColor(d);
    float panel = pow(max(d.y, 0.0), mix(24.0, 3.0, rough));
    c += vec3(0.55, 0.65, 0.85) * 0.9 * panel;
    c += ORANGE * 0.10 * pow(max(-d.y, 0.0), 2.0);
    return c;
}

// ---------------------------------------------------------------------------------------------
// BRDF
// ---------------------------------------------------------------------------------------------

float D_GGX(float nh, float a)
{
    float a2 = a * a;
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

float V_SmithJoint(float nv, float nl, float a)
{
    return 0.5 / max(nl * (nv * (1.0 - a) + a) + nv * (nl * (1.0 - a) + a), 1e-4);
}

vec3 F_Schlick(vec3 f0, float vh)
{
    return f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
}

// Unreal Engine mobile analytic environment BRDF (Karis).
vec3 EnvBRDFApprox(vec3 specColor, float rough, float nv)
{
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
    const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
    vec4 r = rough * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
    vec2 ab = vec2(-1.04, 1.04) * a004 + r.zw;
    return specColor * ab.x + ab.y;
}

vec3 directLight(vec3 N, vec3 V, vec3 L, vec3 radiance, vec3 diffColor, vec3 f0, float a)
{
    float nl = max(dot(N, L), 0.0);
    if (nl <= 0.0) return vec3(0.0);
    vec3 H = normalize(L + V);
    float nv = max(dot(N, V), 1e-3);
    float nh = max(dot(N, H), 0.0);
    float vh = max(dot(V, H), 0.0);
    vec3 spec = D_GGX(nh, a) * V_SmithJoint(nv, nl, a) * F_Schlick(f0, vh);
    return (diffColor / PI + spec) * radiance * nl;
}

// Point light with inverse-square falloff and a smooth range window.
vec3 pointLight(vec3 P, vec3 N, vec3 V, vec3 pos, vec3 intensity, float range,
                vec3 diffColor, vec3 f0, float a)
{
    vec3 d = pos - P;
    float d2 = max(dot(d, d), 1e-6);
    if (d2 >= range * range) return vec3(0.0);   // out of range: skip the BRDF entirely
    float w = 1.0 - d2 / (range * range);
    return directLight(N, V, d * inversesqrt(d2), intensity * (w * w / (d2 + 0.1)), diffColor, f0, a);
}

// ---------------------------------------------------------------------------------------------
// Analytic occlusion and helpers
// ---------------------------------------------------------------------------------------------

// Soft shadow of a sphere along a ray (Inigo Quilez).
float sphereSoftShadow(vec3 ro, vec3 rd, vec4 sph, float k)
{
    vec3 oc = ro - sph.xyz;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - sph.w * sph.w;
    float h = b * b - c;
    float d = -sph.w + sqrt(max(0.0, sph.w * sph.w - h));
    float t = -b - sqrt(max(h, 0.0));
    return (t < 0.0) ? 1.0 : smoothstep(0.0, 1.0, 2.5 * k * d / t);
}

// Ambient occlusion from a sphere (Inigo Quilez).
float sphereAO(vec3 p, vec3 n, vec4 sph)
{
    vec3 d = sph.xyz - p;
    float l = length(d);
    return 1.0 - clamp(dot(n, d / l) * (sph.w * sph.w) / (l * l), 0.0, 1.0) * 0.85;
}

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float valueNoise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x),
               mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

vec3 acesTonemap(vec3 x)
{
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

// Plasma colour on the orb for a direction from its centre (seamless, animated).
vec3 plasma(vec3 n, float t)
{
    vec3 p = n * 3.0;
    float v = sin(p.x * 2.1 + t * 1.3) + sin(p.y * 2.7 - t * 1.7) + sin(p.z * 3.3 + t * 0.9)
            + sin((p.x + p.y - p.z) * 1.9 - t * 1.1);
    v = clamp(0.5 + 0.125 * v, 0.0, 1.0);
    v = v * v * (3.0 - 2.0 * v);
    vec3 c = mix(vec3(0.9, 0.10, 0.01), vec3(1.0, 0.55, 0.12), v);
    return mix(c, vec3(1.0, 0.90, 0.70) * 1.6, smoothstep(0.82, 1.0, v));
}

// Nearest pillar (by angle around the scene centre): its xz centre and lamp height.
// Mirrors Scene3D.pillarAngle / pillarShaft / lampY.
void nearestPillar(vec2 xz, out vec2 centre, out float lampY)
{
    float seg = 2.0 * PI / PILLARS;
    float k = floor(atan(xz.y, xz.x + 1e-6) / seg);   // atan(0, 0) is undefined in GLSL
    float a = (k + 0.5) * seg;
    centre = vec2(cos(a), sin(a)) * PILLAR_R;
    float i = mod(k + PILLARS, PILLARS);
    lampY = FLOOR_Y + 0.85 + 1.9 + 0.5 * mod(i, 3.0);
}

// ---------------------------------------------------------------------------------------------

void main()
{
    vec3 P = vWorld;
    vec3 toCam = uCamPos - P;
    float dist = length(toCam);
    vec3 V = toCam / dist;
    vec3 N = normalize(vNormal);
    if (dot(N, V) < 0.0) N = -N;   // thin parts seen from behind
    float nv = max(dot(N, V), 1e-3);

    float pulse = 0.85 + 0.15 * sin(uTime * 2.0);
    float coreI = 0.9 + 0.1 * sin(uTime * 7.0) * sin(uTime * 2.3);   // reactor flicker
    // Only pixels near the pillar circle can see a lamp or a pillar ring (lamp range 3.5, rings
    // and contact shadows within ~1.1 of a pillar); skip the atan for everything else.
    vec2 pillarC = vec2(1e4);
    float lampY = 0.0;
    if (dot(P.xz, P.xz) > (PILLAR_R - 3.6) * (PILLAR_R - 3.6)) nearestPillar(P.xz, pillarC, lampY);

    // ---- Material ------------------------------------------------------------------------
    vec3 base = vec3(0.04);
    float metal = 0.0;
    float rough = 0.5;
    vec3 emit = vec3(0.0);
    float ao = 1.0;
    bool shadowed = true;   // receives the orb's shadow / occlusion

    if (vMat < 0.5) {
        // Plasma orb: pure emission, brighter towards the limb like a glowing gas shell.
        emit = plasma(N, uTime) * (0.9 + 2.2 * pow(1.0 - nv, 2.0)) * coreI;
        base = vec3(0.0);
        shadowed = false;
    } else if (vMat < 1.5) {
        // Halo blades: emissive orange, a pulse travelling around the ring.
        float wave = 0.5 + 0.5 * sin(uTime * 3.0 - atan(P.z, P.x + 1e-6) * 3.0);
        base = vec3(0.05);
        emit = ORANGE * (2.0 + 4.0 * wave);
    } else if (vMat < 2.5) {
        // Floor: dark polished tile with wet / dry roughness patches, a thin fwidth-antialiased
        // grid, a hot spot under the pedestal and an up-light ring around each pillar.
        vec2 w = P.xz * 0.5;
        vec2 g = abs(fract(w) - 0.5);
        vec2 fw = fwidth(w);
        vec2 line = smoothstep(0.5 - fw * 0.9, vec2(0.5), g);
        float grid = max(line.x, line.y);
        float r2 = dot(P.xz, P.xz);
        float n = valueNoise(P.xz * 0.9) * 0.6 + valueNoise(P.xz * 3.1) * 0.4;
        base = vec3(0.020, 0.022, 0.026) * (0.8 + 0.4 * n);
        rough = mix(0.08, 0.45, smoothstep(0.35, 0.7, n));
        float dp = length(P.xz - pillarC);
        float fwr = fwidth(dp);
        float ring = 1.0 - smoothstep(0.012, 0.012 + fwr * 1.5, abs(dp - 0.62));
        emit = CYAN * 0.22 * grid * exp(-r2 * 0.015)
             + ORANGE * 0.35 * exp(-r2 * 0.9) * pulse
             + CYAN * 1.6 * ring;
        ao *= mix(0.30, 1.0, smoothstep(0.40, 1.1, dp));            // contact shadow at plinths
        ao *= mix(0.45, 1.0, smoothstep(1.15, 1.6, sqrt(r2)));     // and at the pedestal foot
    } else if (vMat < 3.5) {
        // Cage beams: polished titanium with energy pulses racing along each beam.
        float t = fract(vUV.x * 1.5 - uTime * 0.7 + vUV.y);
        float pulseB = smoothstep(0.80, 0.97, t) * (1.0 - smoothstep(0.97, 1.0, t));
        base = vec3(0.62, 0.64, 0.68);
        metal = 1.0;
        rough = 0.20;
        emit = CYAN * 4.5 * pulseB;
        shadowed = false;
    } else if (vMat < 4.5) {
        // Structure metal (pedestal, fins, plinths, collars, capitals): dark anodised metal with
        // a glowing band near the top of parts that use a height-fraction uv.y.
        float band = smoothstep(0.88, 0.91, vUV.y) * (1.0 - smoothstep(0.96, 0.99, vUV.y));
        float brushed = valueNoise(vec2(vUV.x * 400.0, vUV.y * 6.0));
        base = vec3(0.16, 0.17, 0.19);
        metal = 0.85;
        rough = 0.32 + 0.08 * brushed;
        emit = CYAN * 3.0 * band * (0.75 + 0.25 * sin(uTime * 1.5 + vUV.x * 18.0));
        ao *= mix(0.5, 1.0, smoothstep(0.0, 0.25, P.y - FLOOR_Y));
    } else if (vMat < 5.5) {
        // Crystal shards: dark glassy dielectric; warm core light leaking through the edges.
        base = vec3(0.010, 0.030, 0.040);
        rough = 0.10;
        emit = WARM * 1.6 * pow(1.0 - nv, 2.5) * coreI + CYAN * 0.10;
        shadowed = false;
    } else if (vMat < 6.5) {
        // Cyan emissive: lamp crystals and cage joints.
        base = vec3(0.02);
        emit = CYAN * (4.0 + 1.5 * sin(uTime * 3.0 + P.x * 4.0 + P.z * 3.0));
        shadowed = false;
    } else if (vMat < 7.5) {
        // Pillar shaft: graphite metal, octagonal facets with bevelled bright edges, horizontal
        // panel seams, and running light strips down every other facet.
        float facet = floor(vUV.x * 8.0);
        float t = fract(vUV.x * 8.0);
        float fwx = fwidth(vUV.x * 8.0);
        float sy = vUV.y * 7.0;
        float fwy = fwidth(sy);
        float seam = 1.0 - smoothstep(0.012, 0.012 + fwy * 1.2, abs(fract(sy + 0.5) - 0.5));
        float bevel = 1.0 - smoothstep(0.035, 0.035 + fwx * 1.2, min(t, 1.0 - t));
        float strip = (mod(facet, 2.0) < 0.5)
            ? 1.0 - smoothstep(0.045, 0.045 + fwx * 1.2, abs(t - 0.5)) : 0.0;
        strip *= smoothstep(0.03, 0.08, vUV.y) * (1.0 - smoothstep(0.93, 0.98, vUV.y)) * (1.0 - seam);
        base = mix(vec3(0.10, 0.105, 0.115), vec3(0.55, 0.57, 0.6), bevel) * (1.0 - 0.7 * seam);
        metal = 0.9;
        rough = mix(mix(0.38, 0.16, bevel), 0.7, seam);
        emit = CYAN * 2.6 * strip * (0.5 + 0.5 * sin(vUV.y * 14.0 - uTime * 3.0 + facet));
        ao *= mix(0.55, 1.0, smoothstep(0.0, 0.7, P.y - FLOOR_Y));
    } else {
        // Warm energy beam feeding the orb: bright core with packets rising upward.
        base = vec3(0.02);
        emit = WARM * (3.0 + 2.5 * smoothstep(0.4, 1.0, sin(P.y * 9.0 - uTime * 7.0))) * coreI;
        shadowed = false;
    }

    float a = max(rough * rough, 0.002);
    vec3 diffColor = base * (1.0 - metal);
    vec3 f0 = mix(vec3(0.04), base, metal);
    vec4 orbSphere = uCore;
    if (shadowed) ao *= sphereAO(P, N, vec4(uCore.xyz, uCore.w * 1.6));

    // ---- Direct lights ---------------------------------------------------------------------
    vec3 col = vec3(0.0);
    if (vMat > 0.5) {
        // Key: cool moonlight from above / behind-left, softly shadowed by the orb.
        vec3 Lk = normalize(vec3(-0.35, 0.85, -0.40));
        float shadow = shadowed ? sphereSoftShadow(P, Lk, orbSphere, 6.0) : 1.0;
        col += directLight(N, V, Lk, vec3(0.75, 0.82, 1.0) * 2.2 * shadow, diffColor, f0, a);

        // Rim: warm light from the front-right, low, to separate shapes from the background.
        vec3 Lr = normalize(vec3(0.7, 0.25, 0.65));
        col += directLight(N, V, Lr, vec3(1.0, 0.75, 0.5) * 0.7, diffColor, f0, a);

        // The reactor orb is the hero light.
        col += pointLight(P, N, V, uCore.xyz, WARM * 4.5 * coreI, 8.0, diffColor, f0, a);

        // Pedestal glow, just above the pedestal top.
        col += pointLight(P, N, V, vec3(0.0, FLOOR_Y + 0.45, 0.0), ORANGE * 1.2 * pulse, 5.0,
                          diffColor, f0, a);

        // Nearest pillar's lamp crystal.
        col += pointLight(P, N, V, vec3(pillarC.x, lampY, pillarC.y), CYAN * 1.8, 3.5,
                          diffColor, f0, a);

        // Blade halo as a ring light from its nearest point (diffuse-only fake GI).
        vec2 dirXZ = P.xz / max(length(P.xz), 1e-3);
        vec3 toHalo = vec3(dirXZ.x * HALO_R, HALO_Y, dirXZ.y * HALO_R) - P;
        float hd2 = dot(toHalo, toHalo) + 0.04;
        col += diffColor * ORANGE * 0.9 * max(dot(N, toHalo * inversesqrt(hd2)), 0.0) / hd2;
    }

    // ---- Image-based ambient (UE mobile style) ----------------------------------------------
    vec3 R = reflect(-V, N);
    vec3 irradiance = mix(vec3(0.010, 0.008, 0.010), vec3(0.030, 0.038, 0.060), N.y * 0.5 + 0.5)
                    + ORANGE * 0.05 * max(-N.y, 0.0);
    vec3 envSpec = envColor(R, rough);

    // Floor: fake mirror of the orb (ray against its sphere) and of the blade halo.
    if (vMat > 1.5 && vMat < 2.5) {
        vec3 oc = P - uCore.xyz;
        float b = dot(oc, R);
        float h = b * b - (dot(oc, oc) - uCore.w * uCore.w);
        if (h > 0.0 && b < 0.0) envSpec += WARM * 3.0 * coreI * (1.0 - rough);
        float tH = (HALO_Y - P.y) / max(R.y, 1e-3);
        vec3 hp = P + R * tH;
        float onHalo = 1.0 - smoothstep(0.0, 0.25 + rough, abs(length(hp.xz) - HALO_R));
        envSpec += ORANGE * 1.4 * onHalo * step(0.0, R.y) * (1.0 - rough);
    }

    float specOcc = clamp(pow(nv + ao, exp2(-16.0 * a - 1.0)) - 1.0 + ao, 0.0, 1.0);
    col += diffColor * irradiance * ao;
    col += envSpec * EnvBRDFApprox(f0, rough, nv) * specOcc;
    col += emit;

    // ---- Atmosphere ------------------------------------------------------------------------
    // Exponential height fog, thicker near the floor, with warm in-scatter around the core.
    float fogDensity = 0.045 * exp(-max(P.y - FLOOR_Y, 0.0) * 0.6) + 0.012;
    float fog = 1.0 - exp(-max(dist - 3.0, 0.0) * fogDensity);
    vec3 fogCol = skyColor(-V) + ORANGE * 0.015 * exp(-dot(P.xz, P.xz) * 0.05);
    col = mix(col, fogCol, fog);

    // Artificial per-pixel work standing in for a game's lighting cost (benchmark calibration).
    float acc = 0.0;
    vec2 p = P.xz * 0.2;
    for (int i = 0; i < uLoad; i++)
    {
        vec2 q = p - vec2(sin(float(i) * 1.7), cos(float(i) * 2.3)) * 0.6;
        acc += 1.0 / (1.0 + 40.0 * dot(q, q));
    }
    col += acc * 0.00002;

    // Exposure, filmic tonemap, gamma, and dither against banding in the dark gradients.
    vec3 outc = pow(acesTonemap(col * 1.35), vec3(1.0 / 2.2));
    outc += (hash12(gl_FragCoord.xy) - 0.5) / 255.0;
    oColor = vec4(clamp(outc, 0.0, 1.0), 1.0);
#ifdef MABA_VELOCITY
    vec2 curN = vCurClip.xy / vCurClip.w;
    vec2 prevN = vPrevClip.w > 1e-4 ? vPrevClip.xy / vPrevClip.w : curN;
    oVelocity = ((curN - uJitter) - prevN) * 0.5;   // jitter-free motion
#endif
}
