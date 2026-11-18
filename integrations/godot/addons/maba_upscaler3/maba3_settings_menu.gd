# MABA Upscaler 3 - drop-in settings menu for Godot: preset, sharpness, Frame Generation and the Dynamic options, with a
# live status line. Add it to any Control/CanvasLayer (or use Project > Tools > MABA Upscaler 3: add settings menu), leave
# `upscaler_path` empty to use the first Maba3Upscaler in the scene, and the player's choices are saved to user:// and
# restored next time. It is plain Controls, so your Theme styles it; build your own with Maba3Settings if you prefer.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
class_name Maba3SettingsMenu
extends PanelContainer

## Emitted after the player changed a setting (and it was applied and saved).
signal settings_changed

## The Maba3Upscaler to control. Empty = the first one found in the scene tree.
@export var upscaler_path: NodePath
## Save the choices to `settings_path` on every change and load them when the menu appears.
@export var autosave := true
@export var settings_path := Maba3Settings.DEFAULT_PATH
@export var show_frame_generation := true
@export var show_status := true

var _up: Maba3Upscaler
var _preset: OptionButton
var _sharp: HSlider
var _sharp_value: Label
var _fg: OptionButton
var _auto_pause: CheckButton
var _target: SpinBox
var _dynamic_box: VBoxContainer
var _status: Label
var _built := false
var _updating := false
var _status_timer := 0.0


func _ready() -> void:
	_up = _find_upscaler()
	_build()
	if _up == null:
		_status.text = "No Maba3Upscaler found in the scene."
		return
	if autosave:
		Maba3Settings.load_into(_up, settings_path)
	_refresh_controls()


func _process(delta: float) -> void:
	if not show_status or _up == null or not _built:
		return
	_status_timer -= delta
	if _status_timer > 0.0:
		return
	_status_timer = 0.4
	var s := _up.get_status()
	var text := "%s | render %s -> %s | %d fps" % [Maba3Upscaler.PRESET_NAMES[s["preset"]], str(s["internal_size"]), str(s["output_size"]), roundi(s["fps"])]
	if not s["running"]:
		text += " | NOT running: " + str(s["fail_reason"])
	elif s["frame_generation"] != Maba3Upscaler.FrameGen.OFF:
		text += " | Frame Gen %s: %s" % [Maba3Upscaler.FG_NAMES[s["frame_generation"]], "paused (it would not help)" if s["fg_paused"] else "on"]
	_status.text = text


func _find_upscaler() -> Maba3Upscaler:
	if not upscaler_path.is_empty():
		var n := get_node_or_null(upscaler_path)
		if n is Maba3Upscaler:
			return n
	var root := get_tree().root if is_inside_tree() else null
	if root == null:
		return null
	var found := root.find_children("*", "Maba3Upscaler", true, false)
	return found[0] if not found.is_empty() else null


## Builds the controls (called from _ready; public so a test can build the menu without a scene tree).
func build_for(upscaler: Maba3Upscaler) -> void:
	_up = upscaler
	_build()
	_refresh_controls()


func _build() -> void:
	if _built:
		return
	_built = true
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)

	var title := Label.new()
	title.text = "MABA Upscaler 3"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	box.add_child(_row_label("Quality preset"))
	_preset = OptionButton.new()
	for p in Maba3Upscaler.PRESET_NAMES.size():
		var scale: float = Maba3Upscaler.PRESET_SCALE[p]
		var label: String = Maba3Upscaler.PRESET_NAMES[p]
		_preset.add_item("%s (%d%% render)" % [label, roundi(scale * 100.0)] if scale > 0.0 else "%s (follows the target fps)" % label, p)
	_preset.item_selected.connect(_on_preset)
	box.add_child(_preset)

	box.add_child(_row_label("Sharpness"))
	var row := HBoxContainer.new()
	_sharp = HSlider.new()
	_sharp.min_value = 0.0
	_sharp.max_value = 1.0
	_sharp.step = 0.01
	_sharp.custom_minimum_size = Vector2(220, 0)
	_sharp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sharp.value_changed.connect(_on_sharp)
	row.add_child(_sharp)
	_sharp_value = Label.new()
	_sharp_value.custom_minimum_size = Vector2(40, 0)
	row.add_child(_sharp_value)
	box.add_child(row)

	_dynamic_box = VBoxContainer.new()
	_dynamic_box.add_child(_row_label("Target frame rate (Dynamic preset)"))
	_target = SpinBox.new()
	_target.min_value = 15
	_target.max_value = 240
	_target.step = 1
	_target.suffix = "fps"
	_target.value_changed.connect(_on_target)
	_dynamic_box.add_child(_target)
	box.add_child(_dynamic_box)

	if show_frame_generation:
		box.add_child(_row_label("Frame Generation"))
		_fg = OptionButton.new()
		for m in Maba3Upscaler.FG_NAMES.size():
			_fg.add_item(Maba3Upscaler.FG_NAMES[m], m)
		_fg.item_selected.connect(_on_fg)
		if not Maba3Settings.is_frame_generation_supported():
			_fg.disabled = true
			_fg.tooltip_text = "Needs the Forward+ or Mobile renderer."
		box.add_child(_fg)
		_auto_pause = CheckButton.new()
		_auto_pause.text = "Pause automatically when it would not help"
		_auto_pause.toggled.connect(_on_auto_pause)
		box.add_child(_auto_pause)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(280, 0)
	_status.visible = show_status
	box.add_child(_status)


func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _refresh_controls() -> void:
	if _up == null or not _built:
		return
	_updating = true
	_preset.select(_preset.get_item_index(int(_up.preset)))
	_sharp.value = _up.sharpness
	_sharp_value.text = "%.2f" % _up.sharpness
	_target.value = _up.target_fps
	_dynamic_box.visible = _up.preset == Maba3Upscaler.Preset.DYNAMIC
	if _fg != null:
		_fg.select(_fg.get_item_index(int(_up.frame_generation)))
		_auto_pause.button_pressed = _up.frame_generation_auto_pause
	_updating = false


func _changed() -> void:
	if autosave:
		Maba3Settings.save(_up, settings_path)
	settings_changed.emit()


func _on_preset(index: int) -> void:
	if _updating or _up == null:
		return
	_up.set_preset(_preset.get_item_id(index))
	_dynamic_box.visible = _up.preset == Maba3Upscaler.Preset.DYNAMIC
	_changed()


func _on_sharp(v: float) -> void:
	if _updating or _up == null:
		return
	_up.set_sharpness(v)
	_sharp_value.text = "%.2f" % v
	_changed()


func _on_target(v: float) -> void:
	if _updating or _up == null:
		return
	_up.target_fps = v
	_changed()


func _on_fg(index: int) -> void:
	if _updating or _up == null:
		return
	_up.set_frame_generation(_fg.get_item_id(index))
	_changed()


func _on_auto_pause(on: bool) -> void:
	if _updating or _up == null:
		return
	_up.frame_generation_auto_pause = on
	_changed()