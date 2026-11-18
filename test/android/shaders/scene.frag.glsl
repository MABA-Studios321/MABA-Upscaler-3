// Procedural low-resolution test scene: dark, hard un-antialiased edges, fine detail, noise.
precision highp float;
uniform vec2 uRes;
uniform float uTime;
uniform int uLoad;
in highp vec2 vMabaUV;
layout(location = 0) out vec4 oColor;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void main()
{
    vec2 uv = vMabaUV;
    vec2 p = (uv - 0.5) * vec2(uRes.x / uRes.y, 1.0);

    // Dim wall with tiles.
    vec3 col = vec3(0.05, 0.055, 0.06) + 0.04 * uv.y;
    vec2 tile = fract(p * vec2(6.0, 4.0) + vec2(uTime * 0.02, 0.0));
    col *= 1.0 - 0.6 * step(0.96, max(tile.x, tile.y));

    // Rotating spokes: hard diagonal edges at every angle.
    float r = length(p);
    float a = atan(p.y, p.x) + uTime * 0.05;
    float spokes = step(0.5, fract(a * 12.0 / 3.14159265));
    float ring = step(0.12, r) * step(r, 0.40);
    col = mix(col, vec3(0.75, 0.62, 0.45), spokes * ring);

    // Thin slanted bars on the left.
    float bars = step(0.8, fract((p.x * 1.0 + p.y * 0.35) * 40.0));
    col = mix(col, vec3(0.55, 0.6, 0.65), bars * step(p.x, -0.48) * step(-0.85, p.x));

    // Text-like blocks on the right.
    vec2 cell = floor(p * vec2(90.0, 30.0));
    float glyph = step(0.55, hash(cell)) * step(0.25, fract(p.y * 30.0));
    col = mix(col, vec3(0.8), glyph * step(0.50, p.x) * step(p.x, 0.86) * step(abs(p.y), 0.36));

    // Moving flashlight falloff, as in a dark game scene.
    vec2 lp = vec2(0.35 * sin(uTime * 0.3), 0.12 * cos(uTime * 0.23));
    float light = 0.25 + 1.0 / (1.0 + 9.0 * dot(p - lp, p - lp));
    col *= light;

    // Artificial per-pixel work standing in for a game's lighting cost. uLoad is calibrated by
    // the app; the result barely changes the image but cannot be optimised away.
    float acc = 0.0;
    for (int i = 0; i < uLoad; i++)
    {
        vec2 q = p - vec2(sin(float(i) * 1.7), cos(float(i) * 2.3)) * 0.6;
        acc += 1.0 / (1.0 + 40.0 * dot(q, q));
    }
    col += acc * 0.00002;

    // Slight per-pixel noise.
    col += (hash(gl_FragCoord.xy) - 0.5) * (2.0 / 255.0);

    oColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
