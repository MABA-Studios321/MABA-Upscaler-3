# MABA Upscaler 3 - scene node: temporal super-resolution with presets for Godot 4.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
#
# Add this node to a scene with a Camera3D (menu: Project > Tools > MABA Upscaler 3: add to open
# scene). Each frame it
#   - sets the viewport's render scale from the preset (or from the Dynamic controller),
#   - jitters the current camera's projection by a sub-texel amount (Camera3D frustum mode),
#   - attaches the Maba3Effect to that camera's Compositor, which accumulates the jittered frames at
#     OUTPUT resolution and writes the finished image into a texture,
#   - shows that texture on a full-screen canvas item behind your UI (tonemap and sharpen there).
# FRAME GENERATION (optional): the game keeps running every iteration, but the 3D scene is rendered only on some of them
# ("real" frames). On the others the node turns the 3D render off for that iteration and the present shader re-projects
# the last real frame to the camera pose of that very iteration (parallax-correct for camera motion, newest input),
# with the UI drawn on top unwarped. 2x renders every second iteration, 3x every third. A governor pauses it whenever it
# would not show more frames per second than leaving it off. Objects that move by themselves are not extrapolated:
# they update on real frames only.
# If the effect cannot run (no depth, XR, Compatibility renderer, a shader error) the node turns the
# jitter off and lets the engine's own image show: you never get a shaking picture.

@tool
@icon("res://addons/maba_upscaler3/icon.svg")
class_name Maba3Upscaler
extends Node

enum Preset { PERFORMANCE, BALANCED, BALANCE_LITE, QUALITY, ULTRA_QUALITY, NATIVE_AA, DYNAMIC }
const PRESET_NAMES := ["Performance", "Balanced", "Balance Lite", "Quality", "Ultra Quality", "Native AA", "Dynamic"]
const PRESET_SCALE := [0.50, 0.59, 0.55, 0.67, 0.77, 1.0, 0.0]

enum FrameGen { OFF, X2, X3 }
const FG_NAMES := ["Off", "2x", "3x"]

signal scale_changed(scale: float)
## Emitted when Frame Generation starts or stops generating (including the governor pausing it).
signal frame_generation_changed(active: bool)
@export_group("Upscaler")
## Render scale of the 3D scene: Performance 0.50, Balanced 0.59, Balance Lite 0.55, Quality 0.67,
## Ultra Quality 0.77, Native AA 1.00 (anti-aliasing only). Dynamic follows `target_fps`.
@export var preset: Preset = Preset.BALANCED
## Present sharpening, 0 - 1 (0.5 is the measured default: it scales a 5-tap sharpen clamped to the local range).
@export_range(0.0, 1.0, 0.01) var sharpness: float = 0.5

@export_group("Dynamic preset")
@export_range(15.0, 240.0, 1.0, "suffix:fps") var target_fps: float = 60.0
@export_range(0.35, 1.0, 0.01) var min_scale: float = 0.5
@export_range(0.35, 1.0, 0.01) var max_scale: float = 1.0

@export_group("Temporal")
## Width of the colour clamp that rejects ghosts, 1.0 - 1.5. Lower rejects ghosts harder.
@export_range(0.5, 3.0, 0.05) var clip_gamma: float = 1.25
## Relative depth difference that rejects history (disocclusion), 0.005 - 0.02.
@export_range(0.001, 0.1, 0.001) var depth_tolerance: float = 0.01

@export_group("Frame Generation")
## Shows extra frames between the rendered ones: 2x renders the 3D scene every second iteration, 3x every third.
## UI, input and game logic run every iteration. Camera motion is re-projected; objects moving on their own update
## on real frames only.
@export var frame_generation: FrameGen = FrameGen.OFF
## Pause Frame Generation automatically while it would not show more frames per second than leaving it off.
@export var frame_generation_auto_pause := true

@export_group("Debug")
@export var show_stats: bool = false:
	set(v):
		show_stats = v
		if is_inside_tree() and not Engine.is_editor_hint():
			_update_stats(true)

var _viewport: Viewport
var _effect: Maba3Effect
var _effect_camera: Camera3D
var _created_compositor := false
var _jitter_camera: Camera3D
var _saved_cam := {}
var _controller: Maba3Controller
var _temporal := Maba3Temporal.new()
var _saved_scaling_mode: Viewport.Scaling3DMode = Viewport.SCALING_3D_MODE_BILINEAR
var _saved_scaling_scale: float = 1.0
var _last_ticks_usec: int = 0
var _last_scale := -1.0
var _smoothed_ms := 16.7
var _probe := 0
const PROBE_FRAMES := 8
var _applied_target := 60.0
var _applied_min := 0.5
var _applied_max := 1.0
var _warned := false

# ---- Frame Generation state ----
var _depth_texture := Texture2DRD.new()
var _fg_phase := 0                       # 0 = this iteration renders the scene (real), >0 = generated
var _fg_generating := false              # the current iteration is a generated one
var _fg_reported_active := false
var _fg_corr := Projection.IDENTITY      # render-space depth correction (reversed Z, y flip), derived once from the effect
var _fg_corr_ok := false
var _fg_last_gl_vp := Projection.IDENTITY   # last real frame's view-projection WITHOUT the correction
var _fg_real_marker := -1                # effect.frames at the last real iteration: the render of it has finished when frames > this
var _fg_have_real := false
var _gov_state := 0                      # 0 measuring with FG on, 1 probing with FG off, 2 paused
var _gov_samples := 0
var _gov_sum := 0.0
var _gov_on_ms := 0.0                    # ms per displayed frame with FG on
var _gov_off_ms := 0.0                   # ms per frame with FG off (a real frame alone)
var _gov_timer := 12.0                   # seconds until the next probe (state 0) or until FG resumes (state 2)
const GOV_PROBE_ITERATIONS := 14
const GOV_PERIOD_S := 12.0
const GOV_PAUSE_S := 20.0
const GOV_MARGIN := 0.92                 # FG must cut the ms per displayed frame to below 92% of the real frame time
var _layer: CanvasLayer
var _rect: ColorRect
var _material: ShaderMaterial
var _texture := Texture2DRD.new()
var _stats_layer: CanvasLayer
var _stats_label: Label

## Sign of the frustum offset that moves the image content by +jitter texels, per axis; and the matching
## sign the effect reads the jitter back with (calibrated, see test/render_test.gd).
var jitter_node_sign := Vector2(1.0, -1.0)


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	_viewport = get_viewport()
	if RenderingServer.get_rendering_device() == null:
		push_warning("MABA 3: needs the Vulkan renderer (Forward+ or Mobile); the Compatibility renderer is not supported.")
		set_process(false)
		return
	_controller = Maba3Controller.new(Maba3Controller.MODE_DYNAMIC, target_fps)
	_controller.set_scale_range(min_scale, max_scale)
	_saved_scaling_mode = _viewport.scaling_3d_mode
	_saved_scaling_scale = _viewport.scaling_3d_scale
	_viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	_effect = Maba3Effect.new()
	_effect.output_texture = _texture
	_effect.depth_texture = _depth_texture
	_push_settings()
	_build_display()
	_last_ticks_usec = Time.get_ticks_usec()
	set_process(true)


func _exit_tree() -> void:
	if _viewport != null:
		_viewport.disable_3d = false
	_restore_camera()
	_detach_effect()
	if _layer != null:
		_layer.queue_free()
		_layer = null
	if _stats_layer != null:
		_stats_layer.queue_free()
		_stats_layer = null
	if _viewport != null and _effect != null:
		_effect.release()
		_viewport.scaling_3d_mode = _saved_scaling_mode
		_viewport.scaling_3d_scale = _saved_scaling_scale
		_effect = null
		request_ready()   # re-adding the node installs everything again


# ---- Public API -------------------------------------------------------------------------------

func set_preset(p: Preset) -> void:
	preset = p


func set_sharpness(v: float) -> void:
	sharpness = clampf(v, 0.0, 1.0)


func set_frame_generation(mode: FrameGen) -> void:
	frame_generation = mode


func get_frame_generation() -> FrameGen:
	return frame_generation


## True while iterations are being generated right now (false when off, paused by the governor or not ready).
func is_frame_generation_active() -> bool:
	return _fg_reported_active


## True when the iteration that is being drawn right now is a generated one (no 3D render, re-projected image).
func is_current_frame_generated() -> bool:
	return _fg_generating


## True when this renderer can run Frame Generation (needs the RenderingDevice, i.e. Forward+ or Mobile).
static func is_frame_generation_supported() -> bool:
	return RenderingServer.get_rendering_device() != null

## Drop the temporal history after a camera cut, teleport or scene change.
func reset_history() -> void:
	_temporal.reset()
	if _effect != null:
		_effect.reset_history()


## {preset, scale, native, fps, frame_ms, running, fail_reason, internal_size, output_size}
func get_status() -> Dictionary:
	return {
		"preset": int(preset),
		"scale": _current_scale(),
		"native": _current_scale() >= 0.999,
		"fps": 1000.0 / maxf(_smoothed_ms, 0.1),
		"frame_ms": _smoothed_ms,
		"running": _effect != null and _effect.running,
		"fail_reason": _effect.fail_reason if _effect != null else "",
		"internal_size": _effect.last_internal_size if _effect != null else Vector2i.ZERO,
		"output_size": _effect.last_target_size if _effect != null else Vector2i.ZERO,
		"frame_generation": int(frame_generation),
		"fg_active": _fg_reported_active,
		"fg_paused": _gov_state == 2 and frame_generation != FrameGen.OFF,
	}


func _get_configuration_warnings() -> PackedStringArray:
	return Maba3Setup.configuration_warnings(self)


# ---- Internals --------------------------------------------------------------------------------

func _current_scale() -> float:
	if preset == Preset.DYNAMIC:
		return _controller.scale() if _controller != null else 1.0
	return PRESET_SCALE[int(preset)]


func _push_settings() -> void:
	if _effect == null:
		return
	_effect.clip_gamma = clip_gamma
	_effect.depth_tolerance = depth_tolerance


func _build_display() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = -100                        # behind every UI layer, in front of the 3D scene
	_layer.visible = false
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_material = ShaderMaterial.new()
	_material.shader = load((get_script() as Script).resource_path.get_base_dir() + "/shaders/maba3_present.gdshader")
	_material.set_shader_parameter("shown", _texture)
	_material.set_shader_parameter("shown_lin", _texture)
	_material.set_shader_parameter("depth_tex", _depth_texture)
	_rect.material = _material
	_layer.add_child(_rect)
	add_child(_layer)


# Godot keeps the Compositor on a Camera3D, not on the viewport.
func _attach_effect(cam: Camera3D) -> void:
	_detach_effect()
	if cam == null or _effect == null:
		return
	if cam.compositor == null:
		cam.compositor = Compositor.new()
		_created_compositor = true
	var kept: Array[CompositorEffect] = []
	for e in cam.compositor.compositor_effects:
		if not (e is Maba3Effect):
			kept.append(e)
	kept.append(_effect)
	cam.compositor.compositor_effects = kept
	_effect_camera = cam


func _detach_effect() -> void:
	if _effect_camera != null and is_instance_valid(_effect_camera) and _effect_camera.compositor != null:
		var kept: Array[CompositorEffect] = []
		for e in _effect_camera.compositor.compositor_effects:
			if e != _effect:
				kept.append(e)
		_effect_camera.compositor.compositor_effects = kept
		if _created_compositor and kept.is_empty():
			_effect_camera.compositor = null
	_effect_camera = null
	_created_compositor = false


func _apply_camera_jitter(jitter: Vector2, render_size: Vector2) -> void:
	var cam := _viewport.get_camera_3d()
	if cam == null:
		_restore_camera()
		return
	if cam != _jitter_camera:
		_restore_camera()
		_jitter_camera = cam
		_saved_cam = {
			"projection": cam.projection, "size": cam.size, "frustum_offset": cam.frustum_offset,
			"h_offset": cam.h_offset, "v_offset": cam.v_offset,
		}
	if _saved_cam["projection"] != Camera3D.PROJECTION_PERSPECTIVE:
		return   # orthographic / frustum cameras are left alone: no jitter, so no detail is added
	var aspect := render_size.x / render_size.y
	var extent := 2.0 * cam.near * tan(deg_to_rad(cam.fov) * 0.5)
	var width := extent if cam.keep_aspect == Camera3D.KEEP_WIDTH else extent * aspect
	var height := extent / aspect if cam.keep_aspect == Camera3D.KEEP_WIDTH else extent
	var offset := Vector2(jitter_node_sign.x * jitter.x * width / render_size.x,
			jitter_node_sign.y * jitter.y * height / render_size.y)
	cam.set_frustum(extent, offset, cam.near, cam.far)


func _restore_camera() -> void:
	if _jitter_camera != null and is_instance_valid(_jitter_camera) and not _saved_cam.is_empty():
		if _saved_cam["projection"] == Camera3D.PROJECTION_PERSPECTIVE:
			_jitter_camera.set_perspective(_jitter_camera.fov, _jitter_camera.near, _jitter_camera.far)
		_jitter_camera.frustum_offset = _saved_cam["frustum_offset"]
		_jitter_camera.h_offset = _saved_cam["h_offset"]
		_jitter_camera.v_offset = _saved_cam["v_offset"]
	_jitter_camera = null
	_saved_cam = {}


# The scene's Environment decides how the engine would tonemap; the present shader mirrors it.
func _environment(cam: Camera3D) -> Environment:
	if cam != null and cam.environment != null:
		return cam.environment
	var world := _viewport.find_world_3d()
	return world.environment if world != null else null


func _update_present(cam: Camera3D) -> void:
	var env := _environment(cam)
	var mode := 0
	var exposure := 1.0
	var white := 1.0
	if env != null:
		match env.tonemap_mode:
			Environment.TONE_MAPPER_REINHARDT: mode = 1
			Environment.TONE_MAPPER_FILMIC: mode = 2
			Environment.TONE_MAPPER_ACES, 4: mode = 3   # 4 = AgX (approximated with ACES)
		exposure = env.tonemap_exposure
		white = maxf(env.tonemap_white, 0.01)
	_material.set_shader_parameter("tonemap_mode", mode)
	_material.set_shader_parameter("exposure", exposure)
	_material.set_shader_parameter("white", white)
	_material.set_shader_parameter("sharp", sharpness * 0.12)
	_material.set_shader_parameter("out_size", Vector2(_effect.last_target_size) if _effect.last_target_size.x > 0 else Vector2(_viewport.get_visible_rect().size))


func _update_stats(force: bool = false) -> void:
	if not show_stats:
		if _stats_layer != null:
			_stats_layer.queue_free()
			_stats_layer = null
			_stats_label = null
		return
	if _stats_layer == null:
		_stats_layer = CanvasLayer.new()
		_stats_layer.layer = 128
		_stats_label = Label.new()
		_stats_label.position = Vector2(8, 8)
		_stats_label.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))
		_stats_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_stats_label.add_theme_constant_override("outline_size", 4)
		_stats_layer.add_child(_stats_label)
		add_child(_stats_layer)
	if force or Engine.get_frames_drawn() % 15 == 0:
		var s := get_status()
		_stats_label.text = "MABA 3 %s | render %d%% (%s -> %s) | %d fps (%.1f ms) | %s" % [
			PRESET_NAMES[s["preset"]], roundi(s["scale"] * 100.0), str(s["internal_size"]), str(s["output_size"]),
			roundi(s["fps"]), s["frame_ms"], "running" if s["running"] else "NOT running: " + s["fail_reason"]]


# ---- Frame Generation -----------------------------------------------------------------------------

func _gl_projection(cam: Camera3D) -> Projection:
	var s := _viewport.get_visible_rect().size
	return Projection.create_perspective(cam.fov, s.x / s.y, cam.near, cam.far, cam.keep_aspect == Camera3D.KEEP_WIDTH)


func _gl_view_proj(cam: Camera3D) -> Projection:
	return _gl_projection(cam) * Projection(cam.global_transform.affine_inverse())


# The engine renders with a depth-corrected projection (reversed Z, flipped y). It is a constant matrix, so it is
# taken once from a real frame: the effect reports the projection it rendered with, the node knows the plain one.
func _fg_calibrate(cam: Camera3D) -> void:
	if _fg_corr_ok or _effect == null or _effect.frames < 1:
		return
	var rendered := _effect.last_unjittered_proj
	if rendered == Projection.IDENTITY:
		return
	_fg_corr = rendered * _gl_projection(cam).inverse()
	_fg_corr_ok = true


# While the temporal jitter is on, the camera is in frustum mode; the game's own projection is the saved one.
func _is_perspective(cam: Camera3D) -> bool:
	if cam == _jitter_camera and not _saved_cam.is_empty():
		return _saved_cam["projection"] == Camera3D.PROJECTION_PERSPECTIVE
	return cam.projection == Camera3D.PROJECTION_PERSPECTIVE


func _fg_wanted_factor(cam: Camera3D) -> int:
	if frame_generation == FrameGen.OFF or cam == null or not _effect.running:
		return 1
	if not _is_perspective(cam):
		return 1       # the warp is built on a perspective camera
	if frame_generation_auto_pause and _gov_state != 0:
		return 1       # probing without it, or paused
	return 2 if frame_generation == FrameGen.X2 else 3


# Decides whether this iteration is real (renders the scene) or generated, before the engine draws it.
func _fg_decide(cam: Camera3D) -> bool:
	var factor := _fg_wanted_factor(cam)
	_effect.max_frame_gap = maxi(2, factor + 1)
	_fg_calibrate(cam)
	var ready := _fg_corr_ok and _fg_have_real and _effect.frames > _fg_real_marker
	if factor <= 1 or not ready:
		_fg_phase = 0 if factor <= 1 else 1 % factor
		return false
	var gen := _fg_phase != 0
	_fg_phase = (_fg_phase + 1) % factor
	return gen


func _fg_vp(cam: Camera3D) -> Projection:
	return _fg_corr * _gl_view_proj(cam)


func _fg_present_generated(cam: Camera3D) -> void:
	_restore_camera()                       # the warp needs the plain camera: no jitter
	var new_vp := _fg_vp(cam)
	var last_vp := _fg_corr * _fg_last_gl_vp
	_material.set_shader_parameter("warp_mode", true)
	_material.set_shader_parameter("last_vp", last_vp)
	_material.set_shader_parameter("last_inv_vp", last_vp.inverse())
	_material.set_shader_parameter("new_vp", new_vp)
	_material.set_shader_parameter("new_inv_vp", new_vp.inverse())
	_update_present(cam)


# Governor: Frame Generation must never show fewer frames per second than leaving it off. While it runs it measures the
# ms per displayed iteration; every GOV_PERIOD_S it renders every iteration for a few frames to measure a real frame alone,
# and pauses itself when generating would not cut the ms per displayed frame by at least 8%.
func _gov_update(frame_ms: float, delta_s: float) -> void:
	if frame_generation == FrameGen.OFF or not frame_generation_auto_pause:
		_gov_state = 0
		_gov_timer = GOV_PERIOD_S
		_gov_samples = 0
		_gov_sum = 0.0
		return
	match _gov_state:
		0:
			if _fg_have_real:
				_gov_sum += frame_ms
				_gov_samples += 1
			_gov_timer -= delta_s
			if _gov_timer <= 0.0 and _gov_samples > 60:
				_gov_on_ms = _gov_sum / _gov_samples
				_gov_state = 1
				_gov_samples = 0
				_gov_sum = 0.0
		1:
			_gov_samples += 1
			if _gov_samples > 3:                 # skip the transition frames
				_gov_sum += frame_ms
			if _gov_samples >= GOV_PROBE_ITERATIONS:
				_gov_off_ms = _gov_sum / float(GOV_PROBE_ITERATIONS - 3)
				_gov_samples = 0
				_gov_sum = 0.0
				if _gov_on_ms < _gov_off_ms * GOV_MARGIN:
					_gov_state = 0
					_gov_timer = GOV_PERIOD_S
				else:
					_gov_state = 2
					_gov_timer = GOV_PAUSE_S
		2:
			_gov_timer -= delta_s
			if _gov_timer <= 0.0:
				_gov_state = 0
				_gov_timer = 6.0                 # measure FG again soon after resuming
				_gov_samples = 0
				_gov_sum = 0.0


func _process(delta: float) -> void:
	if _effect == null or _viewport == null:
		return
	var now := Time.get_ticks_usec()
	var frame_ms := float(now - _last_ticks_usec) / 1000.0
	_last_ticks_usec = now
	_smoothed_ms += (frame_ms - _smoothed_ms) * 0.05
	_gov_update(frame_ms, delta)

	var out := _viewport.get_visible_rect().size
	if out.x < 2.0 or out.y < 2.0:
		return
	var cam := _viewport.get_camera_3d()
	if cam != _effect_camera:
		_attach_effect(cam)

	# Frame Generation: is this iteration generated (no 3D render) or real?
	var generated := _fg_decide(cam)
	_fg_generating = generated
	_viewport.disable_3d = generated
	var active := generated or (_fg_phase != 0)
	if active != _fg_reported_active:
		_fg_reported_active = active
		frame_generation_changed.emit(active)
	if generated:
		_fg_present_generated(cam)
		_layer.visible = true
		_update_stats()
		return
	_material.set_shader_parameter("warp_mode", false)

	if preset == Preset.DYNAMIC:
		# set_target_fps / set_scale_range reset the controller's counters: only call them on a change.
		if target_fps != _applied_target:
			_applied_target = target_fps
			_controller.set_target_fps(target_fps)
		if min_scale != _applied_min or max_scale != _applied_max:
			_applied_min = min_scale
			_applied_max = max_scale
			_controller.set_scale_range(min_scale, max_scale)
		# The controller holds a DISPLAYED frame rate: with Frame Generation the interval between real frames covers
		# several displayed frames.
		var factor := _fg_wanted_factor(cam)
		_controller.begin_frame(frame_ms / float(factor) if factor > 1 else frame_ms)
	var scale := _current_scale()
	_viewport.scaling_3d_scale = scale
	if not is_equal_approx(scale, _last_scale):
		_last_scale = scale
		scale_changed.emit(scale)
	_push_settings()

	# Jitter only while the resolve is confirmed running (or during a short probe).
	var render_size := Vector2(maxf(2.0, roundf(out.x * scale)), maxf(2.0, roundf(out.y * scale)))
	if not _effect.running:
		_probe += 1
	else:
		_probe = 0
	if _effect.running or _probe < PROBE_FRAMES:
		_apply_camera_jitter(_temporal.begin_frame(), render_size)
	else:
		_restore_camera()
		if not _warned and _probe == PROBE_FRAMES:
			_warned = true
			push_warning("MABA 3: the temporal resolve is not running (%s); showing the engine's own image." % _effect.fail_reason)
	_layer.visible = _effect.running
	if _effect.running:
		_update_present(cam)
	if cam != null:
		_fg_last_gl_vp = _gl_view_proj(cam)
		_fg_real_marker = _effect.frames
		_fg_have_real = _effect.running
	_update_stats()
