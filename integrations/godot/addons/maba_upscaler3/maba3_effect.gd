# MABA Upscaler 3 - CompositorEffect: temporal super-resolution at OUTPUT resolution.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
#
# GODOT: tested on 4.7 (Forward+, Vulkan). Forward+ and Mobile renderers, Vulkan only.
#
# HOW IT FITS GODOT'S PIPELINE
#   At POST_TRANSPARENT the compositor sees the INTERNAL colour buffer (scaled resolution, linear HDR,
#   before tonemapping) and the depth. Godot has no hook after its own tonemap, and the engine's
#   tonemap pass always resamples the internal buffer to the output. So this effect does not write
#   into the engine's buffer: it owns output-resolution history and writes the finished frame into its
#   own texture (`shown`, RGBA16F, output size). Maba3Upscaler displays that texture on a full-screen
#   canvas item behind your UI with maba3_present.gdshader (tonemap + sharpen). The engine's own
#   tonemapped image is simply covered. See README.md for what that means for glow / DoF.
#
# TEMPORAL SUPER-RESOLUTION (maba3_tsr.glsl)
#   The node jitters the camera's projection every frame (Camera3D frustum mode). This effect reads
#   the jitter back from the frame's own projection (no thread race), reprojects the OUTPUT-resolution
#   history from the depth and the camera matrices, and accumulates the jittered samples, so a static
#   scene gains detail a single low-resolution render never contained.

class_name Maba3Effect
extends CompositorEffect

## How far the depth of the reprojected history may differ (relative) before it is rejected.
@export_range(0.001, 0.1, 0.001) var depth_tolerance: float = 0.01
## Width of the colour clamp that rejects ghosts, 1.0 - 1.5.
@export_range(0.5, 3.0, 0.05) var clip_gamma: float = 1.25

## The texture the finished frame is written to; the node assigns a Texture2DRD and the effect points it
## at the RenderingDevice texture (on the render thread).
var output_texture: Texture2DRD
## Points at the depth of the last real frame (output resolution, Godot reversed-Z), for the Frame Generation warp.
var depth_texture: Texture2DRD
## The frame counter may advance this far between two real frames before the history is dropped as stale. Frame
## Generation skips the render of some iterations, so the node raises it to the number of iterations per real frame.
var max_frame_gap := 2
## Render-space projection of the last real frame without its jitter (the node derives its depth correction from it).
var last_unjittered_proj := Projection.IDENTITY
# Sign conventions between the frustum offset and the shader's texel space (see test/render_test.gd).
var jitter_read_sign := Vector2(-1.0, -1.0)
var debug_log := false

# Filled every frame, read by the node.
var running := false
var fail_reason := ""
var last_internal_size := Vector2i.ZERO
var last_target_size := Vector2i.ZERO
var frames := 0

var _rd: RenderingDevice
var _shader: RID
var _sampler: RID
var _pipeline: RID
var _fb_format: int = -1
var _hist: Array[RID] = [RID(), RID()]
var _depth_hist: Array[RID] = [RID(), RID()]
var _shown: RID
var _depth_stable: RID                      # a copy of the newest depth the display shader can sample (its RID never changes)
var _fb: Array[RID] = [RID(), RID()]
var _set: Array[RID] = [RID(), RID()]
var _set_key: Array = [null, null]
var _target := Vector2i.ZERO
var _internal := Vector2i.ZERO
var _color_format: int = -1
var _write := 0
var _have_history := false
var _depth_valid := true
var _last_frame := -100
var _reset_requested := true
var _prev_view_proj := Projection.IDENTITY
var _failed := false


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_normal_roughness = false
	needs_motion_vectors = false
	access_resolved_color = false
	access_resolved_depth = false


## Drop the temporal history (camera cut, teleport, scene change).
func reset_history() -> void:
	_reset_requested = true


func _shader_dir() -> String:
	return (get_script() as Script).resource_path.get_base_dir() + "/shaders"


func _ensure_ready() -> bool:
	if _shader.is_valid():
		return true
	if _failed:
		return false
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_failed = true
		fail_reason = "no RenderingDevice (Compatibility renderer?)"
		return false
	# The .glsl is imported by Godot as an RDShaderFile (compiled at import time, packed into exports).
	var file := load(_shader_dir() + "/maba3_tsr.glsl") as RDShaderFile
	if file == null:
		_failed = true
		fail_reason = "cannot load maba3_tsr.glsl"
		push_error("MABA 3: " + fail_reason)
		return false
	var spirv: RDShaderSPIRV = file.get_spirv()
	var err_v: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_VERTEX)
	var err_f: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_FRAGMENT)
	if err_v != "" or err_f != "":
		_failed = true
		fail_reason = "shader compile error"
		push_error("MABA 3 shader compile error: %s %s" % [err_v, err_f])
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	var ss := RDSamplerState.new()
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	return _shader.is_valid()


func _new_texture(size: Vector2i, format: int, extra_usage: int = 0) -> RID:
	var tfmt := RDTextureFormat.new()
	tfmt.format = format
	tfmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tfmt.width = size.x
	tfmt.height = size.y
	tfmt.depth = 1
	tfmt.array_layers = 1
	tfmt.mipmaps = 1
	tfmt.samples = RenderingDevice.TEXTURE_SAMPLES_1
	tfmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
		| RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | extra_usage
	return _rd.texture_create(tfmt, RDTextureView.new())


func _free_rid(rid: RID) -> void:
	if rid.is_valid():
		_rd.free_rid(rid)


# Frees the textures, framebuffers and sets that depend on the output / internal size.
func _free_targets() -> void:
	if _rd == null:
		return
	for i in 2:
		if _set[i].is_valid() and _rd.uniform_set_is_valid(_set[i]):
			_rd.free_rid(_set[i])
		if _fb[i].is_valid() and _rd.framebuffer_is_valid(_fb[i]):
			_rd.free_rid(_fb[i])
		_set[i] = RID()
		_fb[i] = RID()
		_set_key[i] = null
	for rid in [_hist[0], _hist[1], _depth_hist[0], _depth_hist[1], _shown, _depth_stable]:
		if rid.is_valid() and _rd.texture_is_valid(rid):
			_rd.free_rid(rid)
	_hist = [RID(), RID()]
	_depth_hist = [RID(), RID()]
	_shown = RID()
	_depth_stable = RID()
	_have_history = false
	_target = Vector2i.ZERO
	_internal = Vector2i.ZERO


func _ensure_targets(target: Vector2i, internal: Vector2i, color_format: int) -> bool:
	_internal = internal
	if target == _target and color_format == _color_format and _shown.is_valid() and _rd.texture_is_valid(_shown):
		return _build_framebuffers()
	_free_targets()
	_target = target
	_internal = internal
	_color_format = color_format
	# History, depth history and the shown image are all OUTPUT-sized (a framebuffer needs one size). The
	# history stays valid when the internal size changes (Dynamic scale): it is accumulated in output space.
	for i in 2:
		_hist[i] = _new_texture(target, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		_depth_hist[i] = _new_texture(target, RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_shown = _new_texture(target, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	_depth_stable = _new_texture(target, RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT)
	if not (_hist[0].is_valid() and _hist[1].is_valid() and _depth_hist[0].is_valid() and _depth_hist[1].is_valid() and _shown.is_valid() and _depth_stable.is_valid()):
		fail_reason = "could not create the history textures"
		_free_targets()
		return false
	if output_texture != null:
		output_texture.texture_rd_rid = _shown
	if depth_texture != null:
		depth_texture.texture_rd_rid = _depth_stable
	return _build_framebuffers()

func _build_framebuffers() -> bool:
	for i in 2:
		if not _fb[i].is_valid() or not _rd.framebuffer_is_valid(_fb[i]):
			_fb[i] = _rd.framebuffer_create([_hist[i], _shown, _depth_hist[i]])
		if not _fb[i].is_valid():
			fail_reason = "could not create the framebuffers"
			return false
	var fmt := _rd.framebuffer_get_format(_fb[0])
	if fmt != _fb_format or not _pipeline.is_valid() or not _rd.render_pipeline_is_valid(_pipeline):
		if _pipeline.is_valid() and _rd.render_pipeline_is_valid(_pipeline):
			_rd.free_rid(_pipeline)
		_fb_format = fmt
		var raster := RDPipelineRasterizationState.new()
		raster.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
		var ms := RDPipelineMultisampleState.new()
		ms.sample_count = RenderingDevice.TEXTURE_SAMPLES_1
		var ds := RDPipelineDepthStencilState.new()
		var blend := RDPipelineColorBlendState.new()
		var atts: Array[RDPipelineColorBlendStateAttachment] = []
		for k in 3:
			var a := RDPipelineColorBlendStateAttachment.new()
			a.enable_blend = false
			atts.append(a)
		blend.attachments = atts
		_pipeline = _rd.render_pipeline_create(_shader, fmt, RenderingDevice.INVALID_ID,
			RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster, ms, ds, blend)
	return _pipeline.is_valid()


func _unjittered_proj(scene_data: RenderSceneData) -> Projection:
	var proj: Projection = scene_data.get_cam_projection()
	proj.z = Vector4(0.0, 0.0, proj.z.z, proj.z.w)
	return proj


func _unjittered_view_proj(render_data: RenderData) -> Projection:
	var scene_data := render_data.get_render_scene_data()
	var proj: Projection = scene_data.get_cam_projection()
	proj.z = Vector4(0.0, 0.0, proj.z.z, proj.z.w)      # a symmetric frustum: the jitter is only in z.x / z.y
	var view := Projection(scene_data.get_cam_transform().affine_inverse())
	return proj * view


func _begin_pass(fb: RID) -> int:
	if Engine.get_version_info().hex >= 0x040400:
		return _rd.callv("draw_list_begin", [fb])
	return _rd.callv("draw_list_begin", [fb, 0, 0, 0, 0])


func _render_callback(p_effect_callback_type: int, render_data: RenderData) -> void:
	if p_effect_callback_type != CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	running = false
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null or buffers.get_view_count() != 1:
		fail_reason = "XR / multiview is not supported"
		return
	if not _ensure_ready():
		return
	var internal: Vector2i = buffers.get_internal_size()
	var target: Vector2i = buffers.get_target_size()
	last_internal_size = internal
	last_target_size = target
	if internal.x < 2 or internal.y < 2 or target.x < 2 or target.y < 2:
		return
	var color: RID = buffers.get_color_layer(0)
	var depth: RID = buffers.get_depth_layer(0)
	if not color.is_valid() or not depth.is_valid():
		fail_reason = "no colour or depth buffer"
		return
	var color_format: int = _rd.texture_get_format(color).format
	if not _ensure_targets(target, internal, color_format):
		return

	var scene_data := render_data.get_render_scene_data()
	var proj: Projection = scene_data.get_cam_projection()
	var jitter := Vector2(proj.z.x * jitter_read_sign.x * 0.5 * internal.x,
			proj.z.y * jitter_read_sign.y * 0.5 * internal.y)
	var frame := Engine.get_frames_drawn()
	var reset := _reset_requested or not _have_history or (frame - _last_frame) > max_frame_gap
	_reset_requested = false
	var view_proj := _unjittered_view_proj(render_data)
	var cur_to_prev := _prev_view_proj * view_proj.inverse()

	_write = 1 - _write
	var w := _write
	var r := 1 - w
	var key := [color, depth, _hist[r], _depth_hist[r]]
	if _set_key[w] != key or not _rd.uniform_set_is_valid(_set[w]):
		if _set[w].is_valid() and _rd.uniform_set_is_valid(_set[w]):
			_rd.free_rid(_set[w])
		var uniforms: Array[RDUniform] = []
		var binding := 0
		for tex in [color, _hist[r], depth, _depth_hist[r]]:
			var u := RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.binding = binding
			u.add_id(_sampler)
			u.add_id(tex)
			uniforms.append(u)
			binding += 1
		_set[w] = _rd.uniform_set_create(uniforms, _shader, 0)
		_set_key[w] = key
	if not _set[w].is_valid():
		fail_reason = "could not create the resolve inputs"
		return

	var m := cur_to_prev
	var push := PackedFloat32Array([
		m.x.x, m.x.y, m.x.z, m.x.w, m.y.x, m.y.y, m.y.z, m.y.w,
		m.z.x, m.z.y, m.z.z, m.z.w, m.w.x, m.w.y, m.w.z, m.w.w,
		target.x, target.y, 1.0 / target.x, 1.0 / target.y,
		internal.x, internal.y, jitter.x, jitter.y,
		_camera_near(proj), _camera_far(proj), 1.0 if reset else 0.0, 1.0 if _depth_valid else 0.0,
		depth_tolerance, clip_gamma, 1.0, 0.0,
	]).to_byte_array()
	if debug_log and frame % 20 == 0:
		print("MABA3DBG frame ", frame, " internal ", internal, " target ", target, " jitter ", jitter, " reset ", reset)
	var dl := _begin_pass(_fb[w])
	_rd.draw_list_bind_render_pipeline(dl, _pipeline)
	_rd.draw_list_bind_uniform_set(dl, _set[w], 0)
	_rd.draw_list_set_push_constant(dl, push, push.size())
	_rd.draw_list_draw(dl, false, 1, 3)
	_rd.draw_list_end()

	_prev_view_proj = view_proj
	last_unjittered_proj = _unjittered_proj(scene_data)
	_rd.texture_copy(_depth_hist[w], _depth_stable, Vector3.ZERO, Vector3.ZERO, Vector3(target.x, target.y, 1), 0, 0, 0, 0)
	_last_frame = frame
	_have_history = true
	_depth_valid = true
	running = true
	fail_reason = ""
	frames += 1


# Near / far planes from a Godot reversed-Z projection (column 2, 3 are (.. a, -1) and (.. b, 0)).
func _camera_near(proj: Projection) -> float:
	var b: float = proj.w.z
	var a: float = proj.z.z
	# reverse-z with remapping: a = n / (f - n), b = n * f / (f - n)
	if absf(a) < 1e-9:
		return b if b > 0.0 else 0.05
	return b / (a + 1.0)


func _camera_far(proj: Projection) -> float:
	var b: float = proj.w.z
	var a: float = proj.z.z
	if absf(a) < 1e-9:
		return 1.0e6
	return b / a


## Frees every GPU object this effect created (the node calls it when it removes the effect).
func release() -> void:
	if _rd == null:
		return
	_free_targets()
	if _pipeline.is_valid() and _rd.render_pipeline_is_valid(_pipeline):
		_rd.free_rid(_pipeline)
	_pipeline = RID()
	_fb_format = -1
	for rid in [_shader, _sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_shader = RID()
	_sampler = RID()
	if output_texture != null:
		output_texture.texture_rd_rid = RID()
	if depth_texture != null:
		depth_texture.texture_rd_rid = RID()
	running = false
	_failed = false
