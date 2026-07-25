@tool
class_name OrphanFinderPanel
extends VBoxContainer

const OrphanScanner = preload("res://addons/orphan_finder/orphan_scanner.gd")

## Minimum height requested when this panel is first docked.
const PANEL_MIN_HEIGHT := 260

var _scan_button: Button
var _status_label: Label
var _progress_bar: ProgressBar
var _tree: Tree
var _scanning := false


func _init() -> void:
	custom_minimum_size = Vector2(0, PANEL_MIN_HEIGHT)

	var hint := Label.new()
	hint.text = "Traverses from the main scene, autoloads, and enabled plugins, following every reference. Files never reached are reported as orphans. REPORT ONLY -- nothing is moved or deleted. Runtime-built paths (e.g. load(\"res://levels/\" + name)) can't be seen, so verify before deleting."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	hint.modulate = Color(1, 1, 1, 0.7)
	add_child(hint)

	var toolbar := HBoxContainer.new()
	add_child(toolbar)

	_scan_button = Button.new()
	_scan_button.text = "Scan Project"
	_scan_button.pressed.connect(start_scan)
	toolbar.add_child(_scan_button)

	_status_label = Label.new()
	_status_label.text = "Never scanned."
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(_status_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0
	_progress_bar.max_value = 100
	_progress_bar.show_percentage = true
	_progress_bar.visible = false
	add_child(_progress_bar)

	_tree = Tree.new()
	_tree.columns = 3
	_tree.column_titles_visible = true
	_tree.set_column_title(0, "File")
	_tree.set_column_title(1, "Size")
	_tree.set_column_title(2, "Detail")
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, true)
	_tree.set_column_custom_minimum_width(1, 80)
	_tree.set_column_expand(2, false)
	_tree.set_column_custom_minimum_width(2, 280)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.item_activated.connect(_on_item_activated)
	add_child(_tree)


func start_scan() -> void:
	if _scanning:
		return
	_scanning = true
	_scan_button.disabled = true
	_progress_bar.visible = true
	_progress_bar.value = 0
	_status_label.text = "Starting..."
	_tree.clear()

	var result: Dictionary = await OrphanScanner.scan_async(
		func(phase: String, done: int, total: int): _on_progress(phase, done, total)
	)

	_progress_bar.visible = false
	_scan_button.disabled = false
	_scanning = false

	_populate(result)


func _on_progress(phase: String, done: int, total: int) -> void:
	match phase:
		"inventory":
			_progress_bar.value = 0
			_status_label.text = "1/4 Building file inventory... %d found" % done
		"reading":
			_progress_bar.value = 0.0 if total <= 0 else (float(done) / float(total)) * 100.0
			_status_label.text = "2/4 Reading file contents... %d / %d" % [done, total]
		"indexing":
			_progress_bar.value = 0.0 if total <= 0 else (float(done) / float(total)) * 100.0
			_status_label.text = "3/4 Indexing UIDs and class names... %d / %d" % [done, total]
		"traversing":
			_status_label.text = "4/4 Following references from entry points... %d file(s) reached" % done
		_:
			_status_label.text = "Working... (%s)" % phase


func _populate(result: Dictionary) -> void:
	_tree.clear()
	var root := _tree.create_item()

	var error: String = result.get("error", "")
	if error != "":
		_status_label.text = "Scan could not complete."
		var err_item := _tree.create_item(root)
		err_item.set_text(0, error)
		err_item.set_selectable(0, false)
		err_item.set_custom_color(0, Color(1.0, 0.5, 0.5))
		return

	var orphans: Array = result["orphans"]
	var roots: Array = result["roots"]
	var dynamic_dirs: Array = result["dynamic_dirs"]
	var truncated: Array = result["truncated_files"]

	_status_label.text = "Reached %d of %d file(s) from %d entry point(s): %d orphan(s)." % [
		result["reachable_count"], result["total_files"], roots.size(), orphans.size()
	]

	# Entry points first -- if these are wrong, every result below is wrong,
	# so they're worth seeing before trusting anything else.
	var roots_header := _tree.create_item(root)
	roots_header.set_text(0, "ENTRY POINTS -- traversal started here (%d)" % roots.size())
	roots_header.set_selectable(0, false)
	roots_header.set_selectable(1, false)
	roots_header.set_selectable(2, false)
	roots_header.set_custom_color(0, Color(0.6, 0.85, 1.0))
	for r in roots:
		var rd: Dictionary = r
		var item := _tree.create_item(root)
		item.set_text(0, "  " + String(rd["path"]))
		item.set_text(2, String(rd["kind"]))
		item.set_metadata(0, String(rd["path"]))

	if orphans.is_empty():
		var none_item := _tree.create_item(root)
		none_item.set_text(0, "No orphans found -- every file is reachable.")
		none_item.set_selectable(0, false)
		none_item.set_selectable(1, false)
		none_item.set_selectable(2, false)
	else:
		var orphans_header := _tree.create_item(root)
		orphans_header.set_text(0, "ORPHANS -- never reached from any entry point (%d)" % orphans.size())
		orphans_header.set_selectable(0, false)
		orphans_header.set_selectable(1, false)
		orphans_header.set_selectable(2, false)
		orphans_header.set_custom_color(0, Color(1.0, 0.5, 0.5))
		for o in orphans:
			var od: Dictionary = o
			var item2 := _tree.create_item(root)
			item2.set_text(0, String(od["path"]))
			item2.set_text(1, _format_size(int(od["size"])))
			item2.set_text(2, "unreachable")
			item2.set_custom_color(0, Color(1.0, 0.85, 0.3))
			item2.set_metadata(0, String(od["path"]))
			item2.set_tooltip_text(0, "Double-click to open / reveal")

	if not dynamic_dirs.is_empty():
		var dyn_header := _tree.create_item(root)
		dyn_header.set_text(0, "DIRECTORIES REFERENCED AS PATHS -- contents kept as live (%d)" % dynamic_dirs.size())
		dyn_header.set_selectable(0, false)
		dyn_header.set_selectable(1, false)
		dyn_header.set_selectable(2, false)
		dyn_header.set_custom_color(0, Color(1.0, 0.85, 0.3))
		for d in dynamic_dirs:
			var dd: Dictionary = d
			var item3 := _tree.create_item(root)
			item3.set_text(0, String(dd["dir"]))
			item3.set_text(1, "%d files" % int(dd["file_count"]))
			item3.set_text(2, "referenced in " + String(dd["referenced_in"]))
			item3.set_metadata(0, String(dd["referenced_in"]))

	if not truncated.is_empty():
		var trunc_header := _tree.create_item(root)
		trunc_header.set_text(0, "READ-TRUNCATED -- too large to read fully (%d)" % truncated.size())
		trunc_header.set_selectable(0, false)
		trunc_header.set_selectable(1, false)
		trunc_header.set_selectable(2, false)
		trunc_header.set_custom_color(0, Color(1.0, 0.85, 0.3))
		for t in truncated:
			var item4 := _tree.create_item(root)
			item4.set_text(0, String(t))
			item4.set_text(2, "references past the cap were not seen")
			item4.set_metadata(0, String(t))

	var unresolved_refs: Array = result.get("unresolved_refs", [])
	if not unresolved_refs.is_empty():
		var unres_header := _tree.create_item(root)
		unres_header.set_text(0, "UNRESOLVED REFERENCES -- seen but not matched to a file (%d)" % unresolved_refs.size())
		unres_header.set_text(2, "likely cause of false orphans")
		unres_header.set_selectable(0, false)
		unres_header.set_selectable(1, false)
		unres_header.set_selectable(2, false)
		unres_header.set_custom_color(0, Color(0.325, 0.663, 0.949, 1.0))
		unres_header.set_collapsed(true)
		for u in unresolved_refs:
			var ud: Dictionary = u
			var uitem := _tree.create_item(unres_header)
			uitem.set_text(0, String(ud["reference"]))
			uitem.set_text(2, "in " + String(ud["in_file"]))
			uitem.set_metadata(0, String(ud["in_file"]))

	# The reference graph: every parsed file and what it was found to point
	# at. This is what makes a wrong result diagnosable -- expand the parent
	# that should have referenced a file and see whether it actually did.
	var graph: Dictionary = result.get("graph", {})
	if not graph.is_empty():
		var graph_header := _tree.create_item(root)
		graph_header.set_text(0, "REFERENCE GRAPH -- what each parsed file points at (%d)" % graph.size())
		graph_header.set_text(2, "expand to inspect")
		graph_header.set_selectable(0, false)
		graph_header.set_selectable(1, false)
		graph_header.set_selectable(2, false)
		graph_header.set_custom_color(0, Color(0.7, 0.7, 0.7))
		graph_header.set_collapsed(true)

		var graph_keys: Array = graph.keys()
		graph_keys.sort()
		for gk in graph_keys:
			var parent_path: String = gk
			var refs: Array = graph[parent_path]
			var parent_item := _tree.create_item(graph_header)
			parent_item.set_text(0, parent_path)
			parent_item.set_text(1, "%d refs" % refs.size())
			parent_item.set_metadata(0, parent_path)
			parent_item.set_collapsed(true)
			for rf in refs:
				var child_item := _tree.create_item(parent_item)
				child_item.set_text(0, "  -> " + String(rf))
				child_item.set_metadata(0, String(rf))


func _on_item_activated() -> void:
	var item := _tree.get_selected()
	if item == null:
		return
	var meta = item.get_metadata(0)
	if typeof(meta) != TYPE_STRING:
		return
	_open_path(meta)


func _open_path(path: String) -> void:
	var ext := path.get_extension().to_lower()

	if ext == "gd" or ext == "cs":
		var script := ResourceLoader.load(path) as Script
		if script:
			EditorInterface.edit_script(script, 0, 0, true)
			return
	elif ext == "tscn" or ext == "scn":
		EditorInterface.open_scene_from_path(path)
		return

	EditorInterface.get_file_system_dock().navigate_to_path(path)
	var res := ResourceLoader.load(path)
	if res:
		EditorInterface.edit_resource(res)


static func _format_size(bytes: int) -> String:
	if bytes < 0:
		return "?"
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))
