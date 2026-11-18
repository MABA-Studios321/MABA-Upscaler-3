# MABA Upscaler 3 (Godot) - headless self-test: jitter sequence, the dynamic controller ladder and the setup checks.
# Run: godot --headless --script res://addons/maba_upscaler3/test_u3.gd
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan). SPDX-License-Identifier: Apache-2.0
extends SceneTree

var failures := 0


func check(cond: bool, what: String) -> void:
	if not cond:
		print("FAIL  ", what)
		failures += 1


func _init() -> void:
	# Jitter: Halton(2, 3), 16 phases, the same as maba_temporal.h
	check(absf(Maba3Temporal.halton(1, 2) - 0.5) < 1e-6, "halton(1,2)")
	check(absf(Maba3Temporal.halton(3, 2) - 0.75) < 1e-6, "halton(3,2)")
	check(absf(Maba3Temporal.halton(2, 3) - 2.0 / 3.0) < 1e-6, "halton(2,3)")
	check(Maba3Temporal.halton(5, 1) == 0.0, "halton base < 2 does not loop")
	var jt := Maba3Temporal.new()
	var seen := {}
	for i in Maba3Temporal.PHASES:
		var j := jt.begin_frame()
		check(absf(j.x) <= 0.5 and absf(j.y) <= 0.5, "jitter inside [-0.5, 0.5]")
		seen[j] = true
	check(seen.size() == Maba3Temporal.PHASES, "16 distinct phases")
	check(jt.phase == 0, "the phase wraps")

	# Presets
	check(Maba3Upscaler.PRESET_NAMES.size() == 7 and Maba3Upscaler.PRESET_SCALE.size() == 7, "7 presets")
	check(absf(Maba3Upscaler.PRESET_SCALE[Maba3Upscaler.Preset.BALANCED] - 0.59) < 1e-6, "Balanced 0.59")
	check(absf(Maba3Upscaler.PRESET_SCALE[Maba3Upscaler.Preset.ULTRA_QUALITY] - 0.77) < 1e-6, "Ultra Quality 0.77")

	# Dynamic controller: a fast GPU reaches native, a slow one is pushed down
	var c := Maba3Controller.new(Maba3Controller.MODE_DYNAMIC, 60.0)
	for i in 20000:
		c.begin_frame(5.0)
	check(c.is_native(), "fast GPU reaches native")
	for i in 400:
		c.begin_frame(40.0)
	check(not c.is_native() and c.scale() < 1.0, "slow frames lower the scale")

	# Setup checks
	var root := Node3D.new()
	var node := Maba3Upscaler.new()
	root.add_child(node)
	node.owner = root
	check(Maba3Setup.configuration_warnings(node).size() >= 1, "no camera -> warning")
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.owner = root
	check(Maba3Setup.configuration_warnings(node).is_empty(), "camera present -> no warning")
	check(not Maba3Setup.has_errors(Maba3Setup.check_project()), "renderer supported")
	root.free()

	# Settings helpers: presets for a screen, a save / load round trip, bad input
	check(Maba3Settings.recommended_preset(Vector2i(3840, 2160)) == Maba3Upscaler.Preset.PERFORMANCE, "4K -> Performance")
	check(Maba3Settings.recommended_preset(Vector2i(2560, 1440)) == Maba3Upscaler.Preset.BALANCED, "1440p -> Balanced")
	check(Maba3Settings.recommended_preset(Vector2i(1920, 1080)) == Maba3Upscaler.Preset.QUALITY, "1080p -> Quality")
	check(Maba3Settings.recommended_preset(Vector2i(1280, 720)) == Maba3Upscaler.Preset.ULTRA_QUALITY, "720p -> Ultra Quality")
	var info := Maba3Settings.preset_info(Maba3Upscaler.Preset.BALANCED, Vector2i(1920, 1080))
	check(info["render_size"] == Vector2i(1133, 637) and info["name"] == "Balanced", "preset_info render size")
	check(Maba3Settings.all_presets(Vector2i(1920, 1080)).size() == 7, "all_presets lists 7")
	var a := Maba3Upscaler.new()
	a.set_preset(Maba3Upscaler.Preset.QUALITY)
	a.set_sharpness(0.3)
	a.set_frame_generation(Maba3Upscaler.FrameGen.X3)
	a.frame_generation_auto_pause = false
	a.target_fps = 90.0
	var path := "user://maba3_selftest_settings.cfg"
	check(Maba3Settings.save(a, path) == OK, "settings save")
	var b := Maba3Upscaler.new()
	check(Maba3Settings.load_into(b, path), "settings load")
	check(b.preset == Maba3Upscaler.Preset.QUALITY and absf(b.sharpness - 0.3) < 1e-6, "preset and sharpness round trip")
	check(b.frame_generation == Maba3Upscaler.FrameGen.X3 and not b.frame_generation_auto_pause and b.target_fps == 90.0, "Frame Gen and dynamic round trip")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	check(not Maba3Settings.load_into(b, path), "no file -> false")
	Maba3Settings.apply(b, {"preset": 99, "sharpness": 5.0, "target_fps": 1.0, "frame_generation": 7, "min_scale": 0.9, "max_scale": 0.4})
	check(b.preset == Maba3Upscaler.Preset.QUALITY, "an invalid preset is ignored")
	check(b.sharpness == 1.0 and b.target_fps == 15.0, "values are clamped")
	check(b.frame_generation == Maba3Upscaler.FrameGen.X3, "an invalid Frame Gen mode is ignored")
	check(b.max_scale >= b.min_scale, "max scale is never below min scale")

	# The drop-in menu: build it for a node without a scene tree and drive its controls
	var menu := Maba3SettingsMenu.new()
	menu.autosave = false
	menu.build_for(a)
	check(menu._preset.item_count == 7 and menu._fg.item_count == 3, "the menu lists every preset and Frame Gen mode")
	check(menu._preset.get_selected_id() == Maba3Upscaler.Preset.QUALITY and menu._fg.get_selected_id() == Maba3Upscaler.FrameGen.X3, "the menu shows the node's settings")
	menu._preset.select(menu._preset.get_item_index(Maba3Upscaler.Preset.PERFORMANCE))
	menu._on_preset(menu._preset.selected)
	check(a.preset == Maba3Upscaler.Preset.PERFORMANCE, "choosing a preset in the menu sets it")
	menu._on_sharp(0.8)
	check(absf(a.sharpness - 0.8) < 1e-6, "the sharpness slider sets it")
	menu._fg.select(menu._fg.get_item_index(Maba3Upscaler.FrameGen.OFF))
	menu._on_fg(menu._fg.selected)
	check(a.frame_generation == Maba3Upscaler.FrameGen.OFF, "the Frame Gen choice sets it")
	menu._on_auto_pause(true)
	check(a.frame_generation_auto_pause, "the auto-pause toggle sets it")
	menu.free()
	a.free()
	b.free()

	if failures == 0:
		print("ALL MABA3 GODOT TESTS PASSED")
	else:
		print("%d FAILURES" % failures)
	quit(0 if failures == 0 else 1)