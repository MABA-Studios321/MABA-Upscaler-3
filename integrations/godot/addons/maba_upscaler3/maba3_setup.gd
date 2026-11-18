# MABA Upscaler 3 - project / scene checks shared by the editor menu and the node's inspector warnings.
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
@tool
class_name Maba3Setup
extends RefCounted

const ERROR := "error"
const WARNING := "warning"
const INFO := "info"


static func _item(level: String, text: String) -> Dictionary:
	return {"level": level, "text": text}


static func check_project() -> Array:
	var items: Array = []
	var desktop := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus"))
	var mobile := str(ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "mobile"))
	if desktop == "gl_compatibility":
		items.append(_item(ERROR, "The desktop renderer is Compatibility (OpenGL). MABA 3 needs Forward+ or Mobile (Vulkan / D3D12 / Metal): compositor effects do not exist on Compatibility."))
	if mobile == "gl_compatibility":
		items.append(_item(WARNING, "The mobile renderer override is Compatibility (OpenGL), so MABA 3 will not run on mobile exports."))
	if items.is_empty():
		items.append(_item(INFO, "Renderer: %s (desktop), %s (mobile) - supported." % [desktop, mobile]))
	return items


static func check_scene(root: Node) -> Array:
	var items: Array = []
	if root == null:
		return [_item(ERROR, "No scene is open.")]
	var nodes := root.find_children("*", "Maba3Upscaler", true, false)
	if root is Maba3Upscaler:
		nodes.append(root)
	if nodes.is_empty():
		items.append(_item(WARNING, "The scene has no Maba3Upscaler node (menu: Project > Tools > MABA Upscaler 3: add to open scene)."))
	elif nodes.size() > 1:
		items.append(_item(WARNING, "The scene has %d Maba3Upscaler nodes; use one per viewport." % nodes.size()))
	var cameras := root.find_children("*", "Camera3D", true, false)
	if root is Camera3D:
		cameras.append(root)
	if cameras.is_empty():
		items.append(_item(WARNING, "The scene has no Camera3D: MABA 3 attaches to the viewport's current camera at run time."))
	for cam in cameras:
		if cam.projection != Camera3D.PROJECTION_PERSPECTIVE:
			items.append(_item(INFO, "Camera \"%s\" is not a perspective camera: it is not jittered, so it gains no detail from the temporal accumulation." % cam.name))
	var envs := root.find_children("*", "WorldEnvironment", true, false)
	if root is WorldEnvironment:
		envs.append(root)
	for we in envs:
		var env: Environment = we.environment
		if env == null:
			continue
		if env.tonemap_mode == 4:
			items.append(_item(INFO, "WorldEnvironment \"%s\" uses the AgX tonemapper: MABA 3 approximates it with ACES." % we.name))
		if env.glow_enabled or env.adjustment_enabled or env.auto_exposure_enabled:
			items.append(_item(WARNING, "WorldEnvironment \"%s\" uses glow, colour adjustments or auto-exposure: they belong to the engine's own tonemap pass, which MABA 3 replaces, so they are NOT applied." % we.name))
	return items


static func report(root: Node) -> String:
	var lines := PackedStringArray()
	for item in check_project() + check_scene(root):
		var tags := {"error": "[ERROR]  ", "warning": "[WARNING]", "info": "[ok]     "}
		var tag: String = tags[item["level"]]
		lines.append("%s %s" % [tag, item["text"]])
	return "\n\n".join(lines)


static func has_errors(items: Array) -> bool:
	for item in items:
		if item["level"] == ERROR:
			return true
	return false


static func configuration_warnings(node: Node) -> PackedStringArray:
	var out := PackedStringArray()
	for item in check_project():
		if item["level"] != INFO:
			out.append(item["text"])
	var scene_root := node.owner if node.owner != null else node
	if scene_root.find_children("*", "Camera3D", true, false).is_empty():
		out.append("No Camera3D found in this scene. MABA 3 needs a camera: it attaches to the viewport's current one.")
	for item in check_scene(scene_root):
		if item["level"] == WARNING and "NOT applied" in item["text"]:
			out.append(item["text"])
	return out