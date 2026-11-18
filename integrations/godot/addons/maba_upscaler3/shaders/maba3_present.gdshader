// MABA Upscaler 3 - presents the temporal super-resolution result (Godot canvas item).
//
// Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
// SPDX-License-Identifier: Apache-2.0
//
// Godot has no hook after its own tonemap, so the compositor effect produces the finished frame at
// OUTPUT resolution in a texture (linear, compressed as c / (1 + luma)), and this shader, on a full-
// screen canvas item behind the UI, turns it into pixels: undo the compression, apply exposure and
// the tonemapper of the scene's Environment (Linear, Reinhard, Filmic, ACES; AgX is approximated
// with ACES), convert to sRGB, and sharpen (a 5-tap sharpen clamped to the local range, so it cannot
// ring). Glow, depth of field, colour adjustments and auto-exposure of the engine's own tonemap pass
// are NOT applied: see README.md.
//
// FRAME GENERATION (warp_mode = true): on a "generated" iteration the 3D scene was not rendered at all. The
// last real frame (`shown`, with its depth `depth_tex`, both output resolution) is re-projected to the camera
// pose of THIS iteration: for every pixel of the new view a short search along its ray finds the surface the old
// frame saw there (parallax-correct for the camera's motion; objects that move by themselves stay where the real
// frame had them), then the same tonemap and sharpen run on the warped colour. The UI is drawn on top as usual,
// so it is never warped.
shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D shown : filter_nearest, repeat_disable;
uniform int tonemap_mode = 0;       // 0 Linear, 1 Reinhard, 2 Filmic, 3 ACES
uniform float exposure = 1.0;
uniform float white = 1.0;
uniform float sharp = 0.06;         // 0 = plain copy
uniform vec2 out_size = vec2(1280.0, 720.0);

uniform bool warp_mode = false;
uniform sampler2D shown_lin : filter_linear, repeat_disable;     // the same texture as `shown`, bilinear
uniform sampler2D depth_tex : filter_nearest, repeat_disable;    // last real frame's depth, Godot reversed-Z
uniform mat4 last_vp;        // last real frame's unjittered view-projection
uniform mat4 last_inv_vp;
uniform mat4 new_vp;         // this iteration's camera
uniform mat4 new_inv_vp;
vec3 decompress(vec3 c) {
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	return c / max(1.0 - min(l, 0.995), 0.005);
}

vec3 tonemap_filmic(vec3 c, float w) {
	const float FA = 0.15, FB = 0.50, FC = 0.10, FD = 0.20, FE = 0.02, FF = 0.30;
	vec3 x = ((c * (FA * c + FC * FB) + FD * FE) / (c * (FA * c + FB) + FD * FF)) - FE / FF;
	float W = ((w * (FA * w + FC * FB) + FD * FE) / (w * (FA * w + FB) + FD * FF)) - FE / FF;
	return x / W;
}

vec3 tonemap_aces(vec3 c, float w) {
	const float exposure_bias = 1.8;
	const float AA = 0.0245786, AB = 0.000090537, AC = 0.983729, AD = 0.4329510, AE = 0.238081;
	c *= exposure_bias;
	vec3 r = (c * (c + AA) - AB) / (c * (AC * c + AD) + AE);
	float cw = w * exposure_bias;
	float rw = (cw * (cw + AA) - AB) / (cw * (AC * cw + AD) + AE);
	return r / rw;
}

vec3 tonemap(vec3 c) {
	c *= exposure;
	if (tonemap_mode == 1) {
		return (white * c + c) / (c * white + white);
	} else if (tonemap_mode == 2) {
		return tonemap_filmic(c, white);
	} else if (tonemap_mode == 3) {
		return tonemap_aces(c, white);
	}
	return c;
}

vec3 linear_to_srgb(vec3 c) {
	c = clamp(c, vec3(0.0), vec3(1.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, 12.92 * c, lessThan(c, vec3(0.0031308)));
}

vec3 fetch(ivec2 p, ivec2 lim) {
	return tonemap(decompress(texelFetch(shown, clamp(p, ivec2(0), lim), 0).rgb));
}

// Where in the last real frame does the surface seen at `uv` in the new view come from? Iterate: guess the new
// view's depth at the pixel, find where that world point was in the old frame, read the old depth there, turn it
// back into a world point and a new-view depth, repeat. Converges in a few steps for smooth motion.
vec2 warp_source(vec2 uv) {
	vec2 ndc = uv * 2.0 - 1.0;
	float d_old = max(texture(depth_tex, uv).r, 1e-6);
	vec4 w0 = last_inv_vp * vec4(ndc, d_old, 1.0);
	w0 /= w0.w;
	vec4 n0 = new_vp * w0;
	float zn = n0.z / n0.w;
	vec2 puv = uv;
	for (int i = 0; i < 4; i++) {
		vec4 wp = new_inv_vp * vec4(ndc, zn, 1.0);
		wp /= wp.w;
		vec4 pl = last_vp * wp;
		puv = clamp(pl.xy / pl.w * 0.5 + 0.5, vec2(0.0), vec2(1.0));
		float d = max(texture(depth_tex, puv).r, 1e-6);
		vec4 w2 = last_inv_vp * vec4(puv * 2.0 - 1.0, d, 1.0);
		w2 /= w2.w;
		vec4 n2 = new_vp * w2;
		zn = n2.z / n2.w;
	}
	return puv;
}

vec3 fetch_lin(vec2 uv) {
	return tonemap(decompress(texture(shown_lin, uv).rgb));
}

// Plain presenting of the last real frame (no warp).
vec3 present_plain(ivec2 ip, ivec2 lim) {
	vec3 c = fetch(ip, lim);
	if (sharp > 0.0) {
		vec3 n = fetch(ip + ivec2(0, 1), lim);
		vec3 s = fetch(ip - ivec2(0, 1), lim);
		vec3 e = fetch(ip + ivec2(1, 0), lim);
		vec3 w = fetch(ip - ivec2(1, 0), lim);
		vec3 mn = min(min(min(n, s), min(e, w)), c);
		vec3 mx = max(max(max(n, s), max(e, w)), c);
		c = clamp(c + sharp * (4.0 * c - n - s - e - w), mn, mx);
	}
	return c;
}

// The last real frame re-projected to this iteration's camera.
vec3 present_warped(vec2 frag) {
	vec2 uv = frag / out_size;
	vec2 puv = warp_source(uv);
	vec2 tx = 1.0 / out_size;
	vec3 c = fetch_lin(puv);
	if (sharp > 0.0) {
		vec3 n = fetch_lin(puv + vec2(0.0, tx.y));
		vec3 s = fetch_lin(puv - vec2(0.0, tx.y));
		vec3 e = fetch_lin(puv + vec2(tx.x, 0.0));
		vec3 w = fetch_lin(puv - vec2(tx.x, 0.0));
		vec3 mn = min(min(min(n, s), min(e, w)), c);
		vec3 mx = max(max(max(n, s), max(e, w)), c);
		c = clamp(c + sharp * (4.0 * c - n - s - e - w), mn, mx);
	}
	return c;
}

void fragment() {
	vec3 c;
	if (warp_mode) {
		c = present_warped(FRAGCOORD.xy);
	} else {
		c = present_plain(ivec2(FRAGCOORD.xy), ivec2(out_size) - 1);
	}
	COLOR = vec4(linear_to_srgb(c), 1.0);
}