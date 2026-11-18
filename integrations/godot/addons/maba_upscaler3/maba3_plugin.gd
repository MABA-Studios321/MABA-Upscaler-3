# MABA Upscaler 3 - editor plugin (Project > Tools menu).
#
# Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
# SPDX-License-Identifier: Apache-2.0
@tool
extends EditorPlugin

const MENU_ADD := "MABA Upscaler 3: add to open scene"
const MENU_MENU := "MABA Upscaler 3: add settings menu to open scene"
const MENU_CHECK := "MABA Upscaler 3: check setup"

var _dialog: AcceptDialog


func _enter_tree() -> void:
	add_tool_menu_item(MENU_ADD, _add_to_scene)
	add_tool_menu_item(MENU_MENU, _add_menu_to_scene)
	add_tool_menu_item(MENU_CHECK, _check_setup)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ADD)
	remove_tool_menu_item(MENU_MENU)
	remove_tool_menu_item(MENU_CHECK)
	if _dialog != null:
		_dialog.queue_free()
		_dialog = null


func _show(title: String, text: String) -> void:
	if _dialog == null:
		_dialog = AcceptDialog.new()
		_dialog.min_size = Vector2i(640, 260)
		EditorInterface.get_base_control().add_child(_dialog)
	_dialog.title = title
	_dialog.dialog_text = text
	_dialog.popup_centered()


func _add_to_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_show("MABA Upscaler 3", "Open a 3D scene first.")
		return
	if not root.find_children("*", "Maba3Upscaler", true, false).is_empty() or root is Maba3Upscaler:
		_show("MABA Upscaler 3", "This scene already has a Maba3Upscaler node.")
		return
	var node := Maba3Upscaler.new()
	node.name = "Maba3Upscaler"
	var undo := get_undo_redo()
	undo.create_action("Add Maba3Upscaler")
	undo.add_do_method(root, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(root, "remove_child", node)
	undo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	_show("MABA Upscaler 3", "Added a Maba3Upscaler node.\n\n" + Maba3Setup.report(root))


func _add_menu_to_scene() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		_show("MABA Upscaler 3", "Open a scene first.")
		return
	if not root.find_children("*", "Maba3SettingsMenu", true, false).is_empty():
		_show("MABA Upscaler 3", "This scene already has a settings menu.")
		return
	var layer := CanvasLayer.new()
	layer.name = "Maba3SettingsLayer"
	var menu := Maba3SettingsMenu.new()
	menu.name = "Maba3SettingsMenu"
	menu.position = Vector2(16, 16)
	layer.add_child(menu)
	var undo := get_undo_redo()
	undo.create_action("Add MABA settings menu")
	undo.add_do_method(root, "add_child", layer, true)
	undo.add_do_method(layer, "set_owner", root)
	undo.add_do_method(menu, "set_owner", root)
	undo.add_do_reference(layer)
	undo.add_undo_method(root, "remove_child", layer)
	undo.commit_action()
	_show("MABA Upscaler 3", "Added a settings menu (CanvasLayer > Maba3SettingsMenu). It controls the first Maba3Upscaler in the scene, "
		+ "saves the player's choices to user:// and restores them next time. Move or restyle it like any Control.")


func _check_setup() -> void:
	_show("MABA Upscaler 3: setup check", Maba3Setup.report(EditorInterface.get_edited_scene_root()))