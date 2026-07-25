@tool
extends EditorPlugin

const OrphanFinderPanel = preload("res://addons/orphan_finder/orphan_finder_panel.gd")

const TOOL_MENU_LABEL := "Scan for Orphaned Files"

var _panel: OrphanFinderPanel


func _enter_tree() -> void:
	_panel = OrphanFinderPanel.new()
	add_control_to_bottom_panel(_panel, "Orphan Finder")
	add_tool_menu_item(TOOL_MENU_LABEL, _on_tool_menu_scan)


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_MENU_LABEL)
	if _panel:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null


func _on_tool_menu_scan() -> void:
	make_bottom_panel_item_visible(_panel)
	_panel.start_scan()
