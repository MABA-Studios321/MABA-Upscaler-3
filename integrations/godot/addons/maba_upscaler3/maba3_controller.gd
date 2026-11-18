# MABA Upscaler - GDScript port of the dynamic controller in maba_upscaler.h.
# Kept line-for-line in sync; desk-checked against the C header (no Godot on the build machine).
# Copyright 2026 MABA Studios. SPDX-License-Identifier: Apache-2.0
class_name Maba3Controller
extends RefCounted

# The whole ladder: scale 0.35 (rung -15) .. 1.00 = native (rung 51).
const RUNG_FLOOR := -15
const RUNG_CEIL := 51
# The span of the classic presets (0.50..0.77): their anchors, no longer a limit on Dynamic mode.
const RUNG_COUNT := 29
const RUNG_MIN := 0
const RUNG_MAX := RUNG_COUNT - 1

const MODE_DYNAMIC := 0
const MODE_ULTRA_QUALITY := 1
const MODE_QUALITY := 2
const MODE_BALANCED := 3
const MODE_PERFORMANCE := 4

const START_RUNG := 10
const OVER_RATIO := 1.02
const DOWN_FRAMES := 20
const UP_FRAMES := 180
const UP_FRAMES_MAX := 3600
const PROVEN_FRAMES := 300
# A multi-rung step up must be predicted to use at most this share of the frame budget.
const HEADROOM := 0.90
# Most rungs one step up may climb.
const MAX_JUMP := 16

var mode: int
var target_ms: float
var rung: int
var avg_ms: float
var over_frames: int
var good_frames: int
var up_wait: int
var probing: bool
# The range Dynamic mode may use (default: the whole ladder), and where the current step up began.
var rung_lo: int
var rung_hi: int
var probe_from: int


func _init(p_mode: int = MODE_DYNAMIC, target_fps: float = 60.0) -> void:
	target_ms = 1000.0 / (target_fps if target_fps > 1.0 else 60.0)
	rung_lo = RUNG_FLOOR
	rung_hi = RUNG_CEIL
	set_mode(p_mode)


# Render scale of a rung in whole percent (exact).
static func rung_percent(r: int) -> int:
	return 50 + r if r <= 9 else 49 + r


static func rung_scale(r: int) -> float:
	return rung_percent(r) * 0.01


static func rung_quality(r: int) -> bool:
	return r >= 10


# True at scale 1.00: render at output size and skip the upscale pass.
static func rung_native(r: int) -> bool:
	return rung_percent(r) >= 100


# The rung closest to a render scale (0.35..1.00). 0.59 maps to the quality build (rung 10).
static func scale_to_rung(scale: float) -> int:
	var pct := clampi(int(scale * 100.0 + 0.5), 35, 100)
	return pct - 50 if pct <= 58 else pct - 49


static func mode_rung(m: int) -> int:
	match m:
		MODE_ULTRA_QUALITY: return 28
		MODE_QUALITY: return 18
		MODE_BALANCED: return 10
		MODE_PERFORMANCE: return 0
		_: return START_RUNG


func scale() -> float:
	return rung_scale(rung)


func quality_shader() -> bool:
	return rung_quality(rung)


func is_native() -> bool:
	return rung_native(rung)


func _clamp_rung(r: int) -> int:
	return clampi(r, rung_lo, rung_hi)


func set_mode(m: int) -> void:
	mode = m
	rung = mode_rung(m)
	if m == MODE_DYNAMIC:
		rung = _clamp_rung(rung)   # presets are explicit
	avg_ms = 0.0
	over_frames = 0
	good_frames = 0
	up_wait = UP_FRAMES
	probing = false
	probe_from = rung


# Restrict Dynamic mode to a render-scale range. In Dynamic mode the rung moves inside it.
func set_scale_range(min_scale: float, max_scale: float) -> void:
	var lo := scale_to_rung(min_scale)
	var hi := scale_to_rung(max_scale)
	if hi < lo:
		hi = lo
	rung_lo = lo
	rung_hi = hi
	if mode == MODE_DYNAMIC:
		rung = _clamp_rung(rung)
	avg_ms = 0.0
	over_frames = 0
	good_frames = 0
	probing = false
	probe_from = rung


func set_target_fps(fps: float) -> void:
	target_ms = 1000.0 / (fps if fps > 1.0 else 60.0)
	avg_ms = 0.0
	over_frames = 0
	good_frames = 0
	probing = false


func seed_rung(r: int) -> void:
	rung = _clamp_rung(r)
	avg_ms = 0.0
	over_frames = 0
	good_frames = 0
	probing = false
	probe_from = rung


func update_dynamic(frame_ms: float) -> void:
	if frame_ms <= 0.0 or frame_ms > 1000.0:
		return
	avg_ms = frame_ms if avg_ms <= 0.0 else avg_ms + (frame_ms - avg_ms) * 0.1
	if avg_ms > target_ms * OVER_RATIO:
		good_frames = 0
		over_frames += 1
		if over_frames >= DOWN_FRAMES and rung > rung_lo:
			var next := rung - 1
			if probing:
				# A failed step up returns to the rung it started from, in one step.
				if probe_from < rung and probe_from >= rung_lo:
					next = probe_from
				up_wait = mini(up_wait * 2, UP_FRAMES_MAX)
				probing = false
			rung = next
			over_frames = 0
			avg_ms = target_ms
	else:
		over_frames = 0
		good_frames += 1
		if probing and good_frames >= PROVEN_FRAMES:
			probing = false
			up_wait = maxi(UP_FRAMES, up_wait / 2)
		if not probing and good_frames >= up_wait and rung < rung_hi:
			# One rung, or several when the measured frame time says they fit: the time at a
			# higher rung is predicted as if the whole frame scaled with the pixel count.
			var cur := rung_percent(rung)
			var next := rung + 1
			var r := rung + 2
			while r <= rung_hi and r <= rung + MAX_JUMP:
				var p := rung_percent(r)
				if avg_ms * float(p * p) / float(cur * cur) > target_ms * HEADROOM:
					break
				next = r
				r += 1
			probe_from = rung
			rung = next
			good_frames = 0
			probing = true


func begin_frame(last_frame_ms: float) -> int:
	if mode == MODE_DYNAMIC:
		update_dynamic(last_frame_ms)
	return rung
