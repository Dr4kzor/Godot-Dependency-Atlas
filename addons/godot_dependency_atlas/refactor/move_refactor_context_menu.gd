@tool
extends EditorContextMenuPlugin

## Requires Godot 4.3+ (EditorContextMenuPlugin API).

signal move_requested(paths: PackedStringArray)


func _popup_menu(paths: PackedStringArray) -> void:
	if paths.size() == 1:
		add_context_menu_item("Move + Refactor...", _on_move_pressed)


func _on_move_pressed(paths: PackedStringArray) -> void:
	move_requested.emit(paths)
