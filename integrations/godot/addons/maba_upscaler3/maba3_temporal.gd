# MABA-Upscaler 2 (Temporal) - jitter sequence for Godot (port of the jitter part of
# src/maba_temporal.h). Pure maths, no rendering: it is unit-tested by test_controller.gd.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
class_name Maba3Temporal
extends RefCounted

const PHASES := 16

var phase := 0
var _reset_next := true


## Halton sequence value in [0, 1) for the given base (>= 2) and 1-based index.
static func halton(index: int, base: int) -> float:
	if base < 2:
		return 0.0   # base 0 / 1 would never terminate
	var f := 1.0
	var r := 0.0
	while index > 0:
		f /= float(base)
		r += f * float(index % base)
		@warning_ignore("integer_division")
		index = index / base
	return r


## Call on a camera cut, a resolution change or a teleport: the next frame ignores history and
## the jitter sequence restarts.
func reset() -> void:
	_reset_next = true
	phase = 0


## True when the next frame must ignore history (cleared by begin_frame).
func needs_reset() -> bool:
	return _reset_next


## The sub-texel jitter for this frame, in render texels, each axis in [-0.5, 0.5]: Halton(2, 3) over
## 16 phases. The image content must move BY this amount.
func begin_frame() -> Vector2:
	_reset_next = false
	var j := Vector2(halton(phase + 1, 2) - 0.5, halton(phase + 1, 3) - 0.5)
	phase = (phase + 1) % PHASES
	return j
