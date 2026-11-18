# MABA Upscaler 3 (Godot) - render test. Needs a GPU and a window (Vulkan, Forward+).
#
# Renders a scene with fine detail (checker ground, stripes, thin poles, a moving sphere) and scores each
# configuration against a 2x-supersampled reference, in PSNR (dB, higher is better).
#
#   godot --path <project> --rendering-driver vulkan --resolution 800x450 res://render_test.tscn
#   append  -- --scan     to scan the jitter sign conventions (prints every combination)
#   append  -- --moving   to also run the moving-camera check
#   append  -- --fg       to test Frame Generation: generated frames vs a true render of the same camera pose, and present spacing
#   append  -- --bench N  to time native / bilinear / MABA with an N-iteration pixel shader on the ground (GPU ms)
#   append  -- --save     to write the images to the user data folder
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
extends Node3D

const SCALE := 0.59
const STILL_MIN_DB := 40.0   # frame-to-frame PSNR of a still scene: measured 46.6 dB mean here, 56 dB in Unreal; the broken Unreal build scored 39
var cam: Camera3D
var maba: Maba3Upscaler
var mover: MeshInstance3D
var ground: MeshInstance3D
var failures := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_build_scene()
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	await _frames(6)

	vp.scaling_3d_scale = 2.0
	await _frames(6)
	var ref := await _capture()
	print("RENDER reference captured ", ref.get_size())

	vp.scaling_3d_scale = SCALE
	await _frames(6)
	var bil := await _capture()
	var psnr_bil := _psnr(ref, bil)
	print("RENDER bilinear        PSNR ", "%.2f" % psnr_bil)

	maba = Maba3Upscaler.new()
	maba.preset = Maba3Upscaler.Preset.BALANCED
	add_child(maba)
	maba._effect.debug_log = args.has("--debug")
	for k in 6:
		await _frames(10)
		var st := maba.get_status()
		if k == 0 or k == 5:
			print("RENDER   progress frames ", maba._effect.frames, " running ", st["running"], " reason '", st["fail_reason"], "' internal ", st["internal_size"], " output ", st["output_size"])
	var img := await _capture()
	var psnr_tsr := _psnr(ref, img)
	print("RENDER maba3 temporal SR PSNR ", "%.2f" % psnr_tsr, "  (", "%+.2f" % (psnr_tsr - psnr_bil), " dB vs bilinear)")
	# Margins sit well inside what was measured (+3.8 dB), so a real regression fails and normal noise does not.
	if psnr_tsr < psnr_bil + 2.0:
		_fail("temporal SR is less than 2 dB above bilinear")
	# Still-camera stability: in a static scene every displayed frame must equal the next one. The jitter changes every frame, so an
	# unstable resolve (e.g. history reset by a classification that flips with the jitter phase) shows up here as shimmer, which the
	# PSNR against a reference cannot see. A plain bilinear frame scores 99 dB here.
	var still_prev := await _capture()
	var still_sum := 0.0
	var still_min := 99.0
	var still_n := 12
	for k in still_n:
		var cur := await _capture()
		var p := _psnr(still_prev, cur)
		still_sum += p
		still_min = minf(still_min, p)
		if args.has("--save") and k < 2:
			still_prev.save_png("user://still_%d_a.png" % k)
			cur.save_png("user://still_%d_b.png" % k)
		still_prev = cur
	print("RENDER still camera, frame to frame: mean %.2f dB, worst %.2f dB" % [still_sum / still_n, still_min])
	if still_sum / still_n < STILL_MIN_DB:
		_fail("still-camera frames differ too much (mean below %.0f dB): the picture shimmers" % STILL_MIN_DB)

	if args.has("--save"):
		ref.save_png("user://ref.png")
		bil.save_png("user://bilinear.png")
		img.save_png("user://tsr.png")
		print("RENDER images saved to ", OS.get_user_data_dir())

	if args.has("--scan"):
		await _scan(ref)
	if args.has("--moving"):
		await _moving(ref)
	if args.has("--fg"):
		await _fg_test()
	if args.has("--bench"):
		await _bench(int(args[args.find("--bench") + 1]) if args.find("--bench") + 1 < args.size() else 20)
	print("RENDER done")
	get_tree().quit(failures)


func _fail(msg: String) -> void:
	failures += 1
	print("RENDER FAIL ", msg)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


# The image of the frame that was just drawn (call right after awaiting frame_post_draw, without awaiting anything else).
func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _capture() -> Image:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	return img


func _psnr(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return -1.0
	var da := a.get_data()
	var db := b.get_data()
	var sum := 0.0
	var n := da.size()
	for i in n:
		var d := float(da[i]) - float(db[i])
		sum += d * d
	var mse := sum / float(n)
	if mse < 1e-9:
		return 99.0
	return 10.0 * log(255.0 * 255.0 / mse) / log(10.0)


func _signs() -> Array:
	return [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]


# The node's frustum-offset signs and the effect's jitter-read signs: 16 combinations, a static camera.
func _scan(ref: Image) -> void:
	var eff: Maba3Effect = maba._effect
	var results := []
	for ns in _signs():
		for rs in _signs():
			maba.jitter_node_sign = ns
			eff.jitter_read_sign = rs
			maba.reset_history()
			await _frames(30)
			var img := await _capture()
			results.append({"ns": ns, "rs": rs, "psnr": _psnr(ref, img)})
	results.sort_custom(func(a, b): return a["psnr"] > b["psnr"])
	print("RENDER scan: node sign / read sign, best 6 of ", results.size())
	for i in mini(6, results.size()):
		var r: Dictionary = results[i]
		print("RENDER   node=", r["ns"], " read=", r["rs"], "  PSNR ", "%.2f" % r["psnr"])
	var worst: Dictionary = results[results.size() - 1]
	print("RENDER   worst: node=", worst["ns"], " read=", worst["rs"], "  PSNR ", "%.2f" % worst["psnr"])
	maba.jitter_node_sign = results[0]["ns"]
	eff.jitter_read_sign = results[0]["rs"]


# The camera slides sideways and a sphere moves; compares the settled image with a reference rendered at the end pose.
func _moving(_ref_static: Image) -> void:
	var vp := get_viewport()
	var start := cam.position
	var mstart := mover.position
	var step := Vector3(0.01, 0.0, 0.0)
	var mstep := Vector3(0.0, 0.0, -0.015)
	var frames := 30
	maba.set_process(false)
	maba._restore_camera()
	maba._layer.visible = false
	vp.scaling_3d_scale = 2.0
	cam.position = start + step * frames
	mover.position = mstart + mstep * frames
	await _frames(8)
	var ref_end := await _capture()
	maba.set_process(true)
	cam.position = start
	mover.position = mstart
	maba.reset_history()
	await _frames(40)
	for i in frames:
		cam.position += step
		mover.position += mstep
		await get_tree().process_frame
	await _frames(1)
	var img := await _capture()
	vp.scaling_3d_scale = SCALE
	var psnr_moving := _psnr(ref_end, img)
	print("RENDER moving maba3 PSNR ", "%.2f" % psnr_moving)
	if psnr_moving < 28.0:
		_fail("moving-scene PSNR below 28 dB (measured 31.2)")
	cam.position = start
	mover.position = mstart


# GPU time per frame (ms) of the whole viewport, vsync off. The ground gets a pixel shader whose cost scales
# with `iters`, so the upscaler's fixed per-output-pixel cost can be weighed against what a lower render
# resolution saves.
func _bench(iters: int) -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nuniform int iters = 20;\nvoid fragment(){ vec2 p = UV * 40.0; float a = 0.0; for (int i = 0; i < iters; i++) { p = vec2(sin(p.y + a) , cos(p.x - a)) * 1.7 + p * 0.31; a += 0.01 * length(p); } ALBEDO = vec3(0.5 + 0.5 * sin(a), 0.5 + 0.5 * cos(a * 1.3), 0.5); }"
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("iters", iters)
	ground.material_override = mat
	var vp := get_viewport()
	var rid := vp.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var res := {}
	# native
	maba.set_process(false)
	maba._restore_camera()
	maba._layer.visible = false
	vp.scaling_3d_scale = 1.0
	res["native"] = await _measure(rid)
	vp.scaling_3d_scale = SCALE
	res["bilinear %.2f" % SCALE] = await _measure(rid)
	maba.set_process(true)
	maba._layer.visible = true
	maba.reset_history()
	await _frames(20)
	res["MABA %.2f" % SCALE] = await _measure(rid)
	maba.frame_generation = Maba3Upscaler.FrameGen.X2
	maba.frame_generation_auto_pause = false
	await _frames(30)
	res["MABA %.2f + Frame Gen 2x" % SCALE] = await _measure(rid)
	maba.frame_generation = Maba3Upscaler.FrameGen.OFF
	print("RENDER bench iters ", iters, " output ", vp.get_visible_rect().size)
	for k in res:
		print("RENDER   ", k, "  GPU ", "%.3f" % res[k]["gpu"], " ms   frame ", "%.3f" % res[k]["cpu"], " ms  = ", "%.0f" % (1000.0 / res[k]["cpu"]), " displayed fps")


func _measure(rid: RID) -> Dictionary:
	await _frames(30)
	var gpu := 0.0
	var n := 0
	var t0 := Time.get_ticks_usec()
	for i in 120:
		await get_tree().process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		n += 1
	var cpu := float(Time.get_ticks_usec() - t0) / 1000.0 / float(n)
	return {"gpu": gpu / float(n), "cpu": cpu}

# Frame Generation: the camera moves a little every iteration. For each iteration the displayed image is captured, and the
# true image of the same camera pose is rendered afterwards (2x supersampled, like the other references). A generated
# iteration is judged against repeating the previous real frame, which is what the display would show without it.
func _fg_test() -> void:
	var vp := get_viewport()
	var start := cam.position
	var step := Vector3(0.03, 0.0, 0.0)
	maba.frame_generation = Maba3Upscaler.FrameGen.X2
	maba.frame_generation_auto_pause = false
	maba.reset_history()
	var pose := func(i: int) -> Vector3: return start + step * float(i)
	var i := 0
	for k in 80:                                   # settle, with the camera already moving
		cam.position = pose.call(i)
		i += 1
		await get_tree().process_frame
	var imgs := []
	var kinds := []
	var poses := []
	var times := []
	for k in 16:
		cam.position = pose.call(i)
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
		kinds.append(maba.is_current_frame_generated())
		imgs.append(_grab())
		poses.append(cam.position)
		times.append(Time.get_ticks_usec())
		i += 1
	# the spacing of presented frames over a longer run, FG on and off
	var spacing := {}
	for mode in 2:
		maba.frame_generation = Maba3Upscaler.FrameGen.X2 if mode == 0 else Maba3Upscaler.FrameGen.OFF
		await _frames(30)
		var stamps := []
		for k in 240:
			cam.position = pose.call(i)
			i += 1
			await RenderingServer.frame_post_draw
			stamps.append(Time.get_ticks_usec())
		var gaps := []
		for k in range(1, stamps.size()):
			gaps.append(float(stamps[k] - stamps[k - 1]) / 1000.0)
		gaps.sort()
		var med: float = gaps[gaps.size() / 2]
		var even := 0
		for g in gaps:
			if absf(g - med) <= med * 0.2:
				even += 1
		spacing["FG on" if mode == 0 else "FG off"] = "median %.2f ms, p95 %.2f ms, %.0f%% within 20%% of the median" % [med, gaps[int(gaps.size() * 0.95)], 100.0 * even / gaps.size()]
	# The governor: on this trivial scene a real frame fits inside a refresh, so Frame Generation cannot show more frames
	# per second and has to pause itself (measuring with it on, probing with it off, comparing).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	maba.frame_generation = Maba3Upscaler.FrameGen.X2
	maba.frame_generation_auto_pause = true
	await _frames(30)
	var waited := 0.0
	var paused := false
	while waited < 50.0 and not paused:
		cam.position = pose.call(i)
		i += 1
		await get_tree().process_frame
		waited += get_process_delta_time()
		paused = maba.get_status()["fg_paused"]
	print("RENDER fg  governor: ", ("paused itself after %.1f s" % waited) if paused else "did NOT pause within 50 s")
	maba.frame_generation_auto_pause = false

	# the truth for each captured pose	maba.set_process(false)
	maba._restore_camera()
	maba._layer.visible = false
	vp.disable_3d = false
	vp.scaling_3d_scale = 2.0
	var truths := []
	for p in poses:
		cam.position = p
		await _frames(6)
		truths.append(await _capture())
	var gen_db := []
	var rep_db := []
	var real_db := []
	for j in range(1, imgs.size()):
		if kinds[j]:
			gen_db.append(_psnr(truths[j], imgs[j]))
			rep_db.append(_psnr(truths[j], imgs[j - 1]))
		else:
			real_db.append(_psnr(truths[j], imgs[j]))
	var avg := func(a: Array) -> float:
		var s := 0.0
		for v in a:
			s += v
		return s / maxf(1.0, float(a.size()))
	print("RENDER fg  captured ", kinds.size(), " iterations, ", gen_db.size(), " generated: ", kinds)
	print("RENDER fg  generated frame vs true render of the same pose: %.2f dB" % avg.call(gen_db))
	print("RENDER fg  repeating the previous real frame instead:       %.2f dB" % avg.call(rep_db))
	print("RENDER fg  real frames (temporal SR) vs true render:        %.2f dB" % avg.call(real_db))
	if gen_db.size() < 4 or real_db.size() < 4:
		_fail("Frame Generation did not alternate real and generated frames")
	elif avg.call(gen_db) < avg.call(rep_db) + 3.0:
		_fail("generated frames are not 3 dB closer to the truth than repeating a frame (measured +6.2)")
	for k in spacing:
		print("RENDER fg  present spacing ", k, ": ", spacing[k])
	cam.position = start
	vp.scaling_3d_scale = SCALE

func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.35, 0.45, 0.6)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.9, 0.6, 0.0)
	light.light_energy = 0.9
	add_child(light)
	cam = Camera3D.new()
	cam.fov = 60.0
	cam.position = Vector3(0.0, 1.4, 4.2)
	add_child(cam)
	cam.rotation = Vector3(-0.22, 0.0, 0.0)
	cam.current = true

	var checker := _texture(func(x: int, y: int) -> Color:
		return Color.WHITE if ((x / 16) + (y / 16)) % 2 == 0 else Color(0.12, 0.12, 0.14))
	var stripes := _texture(func(x: int, y: int) -> Color:
		return Color(0.95, 0.35, 0.2) if (x / 8) % 2 == 0 else Color(0.05, 0.1, 0.35))
	ground = MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(30.0, 30.0)
	ground.mesh = plane
	ground.material_override = _mat(checker, Vector3(5.0, 5.0, 1.0))
	add_child(ground)
	for i in 5:
		var box := MeshInstance3D.new()
		box.mesh = BoxMesh.new()
		box.material_override = _mat(stripes, Vector3(1.0, 1.0, 1.0))
		box.position = Vector3(-3.0 + i * 1.5, 0.5, 0.5 - i * 0.7)
		box.rotation = Vector3(0.0, 0.5 * i, 0.0)
		add_child(box)
	for i in 14:
		var pole := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.025
		cyl.bottom_radius = 0.025
		cyl.height = 2.2
		pole.mesh = cyl
		pole.position = Vector3(-4.5 + i * 0.7, 1.1, -2.5)
		add_child(pole)
	mover = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.8
	sm.height = 1.6
	mover.mesh = sm
	mover.material_override = _mat(stripes, Vector3(2.0, 2.0, 1.0))
	mover.position = Vector3(0.0, 0.9, 1.2)
	add_child(mover)


func _texture(fn: Callable) -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			img.set_pixel(x, y, fn.call(x, y))
	return ImageTexture.create_from_image(img)


func _mat(tex: Texture2D, uv_scale: Vector3) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_scale = uv_scale
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return m