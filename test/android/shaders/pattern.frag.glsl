// Reference test patterns, matching test/native/reference.c exactly (except noise, which is
// sequential on the CPU). Used with the "dump" intent to compare GPU output against the CPU
// golden reference. Rendered at region resolution; gl_FragCoord is the region texel.
precision highp float;
uniform int uPattern;
uniform highp vec2 uRes;
layout(location = 0) out vec4 oColor;

void main()
{
    int x = int(gl_FragCoord.x);
    // Reference images are top-down; gl_FragCoord is bottom-up.
    int y = int(uRes.y) - 1 - int(gl_FragCoord.y);
    float fx = float(x) / uRes.x;
    float fy = float(y) / uRes.y;
    vec3 c = vec3(0.0);
    if (uPattern == 0) {
        float v = (fx + fy > 1.0) ? 0.9 : 0.1;
        c = vec3(v);
    } else if (uPattern == 1) {
        float v = (((x / 4 + y / 4) & 1) != 0) ? 0.85 : 0.15;
        c = vec3(v);
    } else if (uPattern == 2) {
        float dx = fx - 0.5, dy = fy - 0.5;
        float v = (dx * dx + dy * dy < 0.09) ? 0.95 : 0.05;
        c = vec3(v, v * 0.6, v * 0.3);
    } else if (uPattern == 3) {
        c = vec3(fx, fy, 0.5);
    } else if (uPattern == 5) {
        c = vec3(0.4);
    } else if (uPattern == 6) {
        float v = ((x % 7 == 0) || (y % 9 == 0)) ? 0.9 : 0.08;
        c = vec3(v);
    }
    oColor = vec4(c, 1.0);
}