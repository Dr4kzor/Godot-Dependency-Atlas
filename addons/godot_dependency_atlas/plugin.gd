@tool
extends EditorPlugin

const DependencyAtlasPanel = preload("res://addons/godot_dependency_atlas/dependency_atlas_panel.gd")
const MoveRefactorContextMenu = preload("res://addons/godot_dependency_atlas/refactor/move_refactor_context_menu.gd")
const MoveRefactorDialog = preload("res://addons/godot_dependency_atlas/refactor/move_refactor_dialog.gd")
const MoveRefactorResultsPanel = preload("res://addons/godot_dependency_atlas/refactor/move_refactor_results.gd")
const RefactorEngine = preload("res://addons/godot_dependency_atlas/refactor/refactor_engine.gd")

const TOOL_MENU_LABEL := "Scan with Dependency Atlas"
const GRAPH_SCENE := "res://addons/godot_dependency_atlas/graph3d/graph_viewer.tscn"

var _panel: DependencyAtlasPanel
var _refactor_context_menu: MoveRefactorContextMenu
var _refactor_dialog: MoveRefactorDialog
var _refactor_results: MoveRefactorResultsPanel


func _enter_tree() -> void:
	_panel = DependencyAtlasPanel.new()
	_panel.open_3d_atlas_requested.connect(_on_open_3d_atlas_requested)
	add_control_to_bottom_panel(_panel, "Dependency Atlas")
	add_tool_menu_item(TOOL_MENU_LABEL, _on_tool_menu_scan)

	_refactor_dialog = MoveRefactorDialog.new()
	_refactor_dialog.refactor_requested.connect(_on_refactor_requested)
	get_editor_interface().get_base_control().add_child(_refactor_dialog)

	_refactor_results = MoveRefactorResultsPanel.new()
	add_control_to_bottom_panel(_refactor_results, "Atlas Refactor")

	_refactor_context_menu = MoveRefactorContextMenu.new()
	_refactor_context_menu.move_requested.connect(_on_refactor_move_requested)
	add_context_menu_plugin(
		EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM,
		_refactor_context_menu
	)


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_MENU_LABEL)
	if _refactor_context_menu:
		remove_context_menu_plugin(_refactor_context_menu)
		_refactor_context_menu = null
	if _refactor_dialog:
		_refactor_dialog.queue_free()
		_refactor_dialog = null
	if _refactor_results:
		remove_control_from_bottom_panel(_refactor_results)
		_refactor_results.queue_free()
		_refactor_results = null
	if _panel:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null


func _on_tool_menu_scan() -> void:
	make_bottom_panel_item_visible(_panel)
	_panel.start_scan()


func _on_open_3d_atlas_requested() -> void:
	var editor := get_editor_interface()
	if editor.is_playing_scene():
		editor.stop_playing_scene()
		# Let the previous game process close before starting the atlas.
		await get_tree().process_frame
	editor.play_custom_scene(GRAPH_SCENE)


func _on_refactor_move_requested(paths: PackedStringArray) -> void:
	_refactor_dialog.open_for_paths(paths)


func _on_refactor_requested(moves: Array) -> void:
	make_bottom_panel_item_visible(_refactor_results)
	_refactor_results.show_progress("Scanning project…", 0.0)

	var summary: Dictionary = await RefactorEngine.perform_moves_async(
		moves,
		func(done: int, total: int):
			var percent := 100.0 if total <= 0 else float(done) / float(total) * 100.0
			_refactor_results.show_progress(
				"Scanning project… %d / %d (%d%%)" % [done, total, int(percent)],
				percent
			)
	)
	for failure in summary["failed"]:
		push_error("Dependency Atlas refactor failed: %s → %s (%s)" % [
			failure["from"], failure["to"], failure["error"]
		])
	_refactor_results.show_results(
		summary["moved"],
		summary["updated_files"],
		summary["failed"]
	)
	get_editor_interface().get_resource_filesystem().scan()
