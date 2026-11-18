# MABA Upscaler 3 - settings helpers for Godot: capability and preset queries, the recommended preset for a screen, and
# saving / loading the player's choices (a ConfigFile in user://). Everything here is static; the Maba3SettingsMenu control
# uses it, and so can your own menu.
#
#   var up: Maba3Upscaler = $Maba3Upscaler
#   Maba3Settings.load_into(up)                              # at start-up: the player's saved choices, if any
#   up.set_preset(Maba3Settings.recommended_preset(DisplayServer.window_get_size()))
#   Maba3Settings.save(up)                                   # after the player changes something
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
class_name Maba3Settings
extends RefCounted

const DEFAULT_PATH := "user://maba3_settings.cfg"
const SECTION := "maba3"


## True when this renderer can run the upscaler (needs the RenderingDevice: Forward+ or Mobile, not Compatibility).
static func is_supported() -> bool:
	return RenderingServer.get_rendering_device() != null


## True when Frame Generation can run. Same requirement as the upscaler, and a perspective Camera3D at run time.
static func is_frame_generation_supported() -> bool:
	return is_supported()


## One entry per preset: {preset, name, scale, render_size}. render_size is the 3D render resolution for `output`
## (Dynamic reports its maximum, because the controller moves it).
static func preset_info(preset: int, output: Vector2i) -> Dictionary:
	var scale: float = Maba3Upscaler.PRESET_SCALE[preset]
	if preset == Maba3Upscaler.Preset.DYNAMIC:
		scale = 1.0
	return {
		"preset": preset,
		"name": Maba3Upscaler.PRESET_NAMES[preset],
		"scale": scale,
		"render_size": Vector2i(maxi(2, roundi(output.x * scale)), maxi(2, roundi(output.y * scale))),
	}


static func all_presets(output: Vector2i) -> Array:
	var list := []
	for p in Maba3Upscaler.PRESET_NAMES.size():
		list.append(preset_info(p, output))
	return list


## A starting preset for a screen: the more pixels to shade, the more it helps to render fewer of them. This is a
## heuristic by output size only (it cannot know the GPU or the game); the Dynamic preset is the one that adapts.
static func recommended_preset(output: Vector2i) -> int:
	var pixels := output.x * output.y
	if pixels >= 8000000:        # 4K and above
		return Maba3Upscaler.Preset.PERFORMANCE
	if pixels >= 3500000:        # 1440p
		return Maba3Upscaler.Preset.BALANCED
	if pixels >= 1900000:        # 1080p
		return Maba3Upscaler.Preset.QUALITY
	return Maba3Upscaler.Preset.ULTRA_QUALITY


## The node's settings as a plain Dictionary (what save() writes).
static func to_dict(up: Maba3Upscaler) -> Dictionary:
	return {
		"preset": int(up.preset),
		"sharpness": up.sharpness,
		"frame_generation": int(up.frame_generation),
		"frame_generation_auto_pause": up.frame_generation_auto_pause,
		"target_fps": up.target_fps,
		"min_scale": up.min_scale,
		"max_scale": up.max_scale,
	}


## Applies a Dictionary of settings (missing or out-of-range entries are ignored or clamped).
static func apply(up: Maba3Upscaler, d: Dictionary) -> void:
	if d.has("preset"):
		var p := int(d["preset"])
		if p >= 0 and p < Maba3Upscaler.PRESET_NAMES.size():
			up.set_preset(p)
	if d.has("sharpness"):
		up.set_sharpness(float(d["sharpness"]))
	if d.has("frame_generation"):
		var m := int(d["frame_generation"])
		if m >= 0 and m < Maba3Upscaler.FG_NAMES.size():
			up.set_frame_generation(m)
	if d.has("frame_generation_auto_pause"):
		up.frame_generation_auto_pause = bool(d["frame_generation_auto_pause"])
	if d.has("target_fps"):
		up.target_fps = clampf(float(d["target_fps"]), 15.0, 240.0)
	if d.has("min_scale"):
		up.min_scale = clampf(float(d["min_scale"]), 0.35, 1.0)
	if d.has("max_scale"):
		up.max_scale = clampf(float(d["max_scale"]), 0.35, 1.0)
	if up.max_scale < up.min_scale:
		up.max_scale = up.min_scale


## Writes the node's settings to a ConfigFile. Returns an Error code (OK on success).
static func save(up: Maba3Upscaler, path: String = DEFAULT_PATH) -> int:
	var cfg := ConfigFile.new()
	var d := to_dict(up)
	for key in d:
		cfg.set_value(SECTION, key, d[key])
	return cfg.save(path)


## Reads the settings file (if there is one) and applies it. Returns false when there is no usable file.
static func load_into(up: Maba3Upscaler, path: String = DEFAULT_PATH) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK or not cfg.has_section(SECTION):
		return false
	var d := {}
	for key in cfg.get_section_keys(SECTION):
		d[key] = cfg.get_value(SECTION, key)
	apply(up, d)
	return true