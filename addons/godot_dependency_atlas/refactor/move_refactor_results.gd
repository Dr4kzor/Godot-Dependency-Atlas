@tool
class_name MoveRefactorResultsPanel
extends VBoxContainer

## Minimum height requested when this panel is first docked. Godot bottom
## panels are user-resizable after that, so this is just a starting point.
const PANEL_MIN_HEIGHT := 260

var _tree: Tree
var _preview: TextEdit
var _preview_label: Label
var _progress_bar: ProgressBar
var _progress_label: Label

const HIGHLIGHT_COLOR := Color(1.0, 0.85, 0.2, 0.25)


func _init() -> void:
	custom_minimum_size = Vector2(0, PANEL_MIN_HEIGHT)

	var hint := Label.new()
	hint.text = "Click a row to preview it below. Double-click to open it (jumps to the line for .gd/.cs)."
	hint.modulate = Color(1, 1, 1, 0.7)
	add_child(hint)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0
	_progress_bar.max_value = 100
	_progress_bar.show_percentage = true
	_progress_bar.visible = false
	add_child(_progress_bar)

	_progress_label = Label.new()
	_progress_label.visible = false
	_progress_label.modulate = Color(1, 1, 1, 0.7)
	add_child(_progress_label)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 380
	add_child(split)

	_tree = Tree.new()
	_tree.columns = 3
	_tree.column_titles_visible = true
	_tree.set_column_title(0, "File")
	_tree.set_column_title(1, "Line")
	_tree.set_column_title(2, "Change")
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 50)
	_tree.set_column_expand(2, true)
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_activated.connect(_on_item_activated)
	split.add_child(_tree)

	var preview_vbox := VBoxContainer.new()
	preview_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(preview_vbox)

	_preview_label = Label.new()
	_preview_label.text = "Preview"
	_preview_label.modulate = Color(1, 1, 1, 0.7)
	preview_vbox.add_child(_preview_label)

	_preview = TextEdit.new()
	_preview.editable = false
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	preview_vbox.add_child(_preview)


## moves: [{ from, to }]   updated_files: [{ path, line, old_ref, new_ref }]   failed: [{ from, to, error }]
func show_results(moves: Array, updated_files: Array, failed: Array) -> void:
	hide_progress()
	_tree.clear()
	_preview.text = ""
	_preview_label.text = "Preview"
	var root := _tree.create_item()

	for move in moves:
		var item := _tree.create_item(root)
		item.set_text(0, "Moved: %s -> %s" % [move["from"], move["to"]])
		item.set_selectable(0, false)
		item.set_selectable(1, false)
		item.set_selectable(2, false)
		item.set_custom_color(0, Color(0.6, 0.85, 1.0))

		var debug_item := _tree.create_item(root)
		debug_item.set_text(0, "  is_dir=%s  search_from=\"%s\"  search_to=\"%s\"  matched %d file(s)" % [
			move.get("is_dir", "?"), move.get("search_from", "?"), move.get("search_to", "?"), move.get("affected_count", -1)
		])
		debug_item.set_selectable(0, false)
		debug_item.set_selectable(1, false)
		debug_item.set_selectable(2, false)
		debug_item.set_custom_color(0, Color(0.7, 0.7, 0.7))

	for fail in failed:
		var item := _tree.create_item(root)
		item.set_text(0, "FAILED: %s -> %s (%s)" % [fail["from"], fail["to"], fail["error"]])
		item.set_selectable(0, false)
		item.set_selectable(1, false)
		item.set_selectable(2, false)
		item.set_custom_color(0, Color(1.0, 0.5, 0.5))

	if updated_files.is_empty():
		var item := _tree.create_item(root)
		item.set_text(0, "No other files referenced the old path.")
		item.set_selectable(0, false)
		item.set_selectable(1, false)
		item.set_selectable(2, false)
	else:
		for entry in updated_files:
			var item := _tree.create_item(root)
			item.set_text(0, entry["path"])
			item.set_text(1, str(entry["line"]))
			item.set_text(2, "%s  ->  %s" % [entry["old_ref"], entry["new_ref"]])
			item.set_metadata(0, entry)
			item.set_tooltip_text(0, "Click to preview, double-click to open")


func show_progress(text: String, percent: float) -> void:
	_progress_bar.visible = true
	_progress_label.visible = true
	_progress_bar.value = percent
	_progress_label.text = text


func hide_progress() -> void:
	_progress_bar.visible = false
	_progress_label.visible = false


func _on_item_selected() -> void:
	_load_preview_for_selection()


func _on_item_activated() -> void:
	var entry := _load_preview_for_selection()
	if entry.is_empty():
		return
	_open_in_real_editor(entry["path"], int(entry["line"]))


func _load_preview_for_selection() -> Dictionary:
	var item := _tree.get_selected()
	if item == null:
		return {}
	var meta = item.get_metadata(0)
	if typeof(meta) != TYPE_DICTIONARY:
		return {}

	var path: String = meta["path"]
	var line: int = int(meta["line"])

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_preview.text = "// Could not open %s" % path
		_preview_label.text = "Preview"
		return {}

	_preview.text = f.get_as_text()
	f.close()
	_preview_label.text = "%s : line %d" % [path, line]

	for l in range(_preview.get_line_count()):
		_preview.set_line_background_color(l, Color(0, 0, 0, 0))
	if line >= 1 and line <= _preview.get_line_count():
		_preview.set_line_background_color(line - 1, HIGHLIGHT_COLOR)
		_preview.set_caret_line(line - 1)
		_preview.set_caret_column(0)
		call_deferred("_center_preview_caret")

	return meta


func _center_preview_caret() -> void:
	_preview.center_viewport_to_caret()


func _open_in_real_editor(path: String, line: int) -> void:
	var ext := path.get_extension().to_lower()

	match ext:
		"gd", "cs":
			var script := ResourceLoader.load(path) as Script
			if script:
				EditorInterface.edit_script(script, line, 0, true)
				return
		"tscn":
			EditorInterface.open_scene_from_path(path)
			# .tscn text isn't line-navigable through the public API; the
			# preview pane above already shows/highlights the exact line.
			return

	# Fallback for .tres/.cfg/.import/.json/.gdshader/etc: reveal it in the dock.
	EditorInterface.get_file_system_dock().navigate_to_path(path)
