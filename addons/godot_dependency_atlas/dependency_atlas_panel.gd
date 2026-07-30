@tool
class_name DependencyAtlasPanel
extends VBoxContainer

signal open_3d_atlas_requested

const OrphanScanner = preload("res://addons/godot_dependency_atlas/orphan_scanner.gd")
const DeletionManager = preload("res://addons/godot_dependency_atlas/graph3d/deletion_manager.gd")
const PermissionDialog = preload("res://addons/godot_dependency_atlas/graph3d/permission_dialog.gd")
const TypeIcons = preload("res://addons/godot_dependency_atlas/graph3d/type_icons.gd")
const GraphMetrics = preload("res://addons/godot_dependency_atlas/graph3d/graph_metrics.gd")
const DeletionWarningScene = preload("res://addons/godot_dependency_atlas/deletion_warning_overlay.tscn")

## Minimum height requested when this panel is first docked.
const PANEL_MIN_HEIGHT := 260

var _scan_button: Button
var _status_label: Label
var _progress_bar: ProgressBar
var _tree: Tree
var _scanning := false
var _deletion = DeletionManager.new()
var _permission_dialog: ConfirmationDialog
var _confirm_delete_dialog: ConfirmationDialog
var _delete_button: Button
var _pending_delete := ""
var _plain_orphan_paths := {}
var _last_log_text := ""
var _save_dialog: EditorFileDialog
var _save_log_button: Button
var _save_as_button: Button
var _deletion_warning: DeletionWarningOverlay


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

	var open_atlas_button := Button.new()
	open_atlas_button.text = "Run 3D Atlas"
	open_atlas_button.tooltip_text = "Launch the interactive dependency graph without manually opening its scene"
	open_atlas_button.pressed.connect(func(): open_3d_atlas_requested.emit())
	toolbar.add_child(open_atlas_button)

	_delete_button = Button.new()
	_delete_button.text = "Enable deleting…"
	_delete_button.tooltip_text = "Allow moving orphaned files to the trash"
	_delete_button.pressed.connect(_on_delete_button)
	toolbar.add_child(_delete_button)

	_save_log_button = Button.new()
	_save_log_button.text = "Save Log"
	_save_log_button.tooltip_text = "Write this scan's report into the project's dependency_atlas/logs folder"
	_save_log_button.disabled = true
	_save_log_button.pressed.connect(_on_save_log)
	toolbar.add_child(_save_log_button)

	_save_as_button = Button.new()
	_save_as_button.text = "Save As…"
	_save_as_button.disabled = true
	_save_as_button.pressed.connect(_on_save_log_as)
	toolbar.add_child(_save_as_button)

	var icon_button := Button.new()
	icon_button.text = "Export Type Icons"
	icon_button.tooltip_text = "Dumps Godot's own editor icons to PNG so the standalone 3D graph viewer can use them. Only needs doing once."
	icon_button.pressed.connect(_on_export_icons)
	toolbar.add_child(icon_button)

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
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 80)
	_tree.set_column_expand(2, false)
	_tree.set_column_custom_minimum_width(2, 280)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.hide_root = true
	_tree.item_activated.connect(_on_item_activated)
	add_child(_tree)

	_deletion_warning = DeletionWarningScene.instantiate()
	_tree.add_child(_deletion_warning)


## Reports are only written when asked for. Auto-saving every scan filled the
## logs folder with files nobody had read.
## Deletion is gated once, then stays enabled until the next scan.
func _on_delete_button() -> void:
	if _deletion.is_granted():
		var selected := _tree.get_selected()
		var path := "" if selected == null else String(selected.get_metadata(0))
		if path == "" or not _plain_orphan_paths.has(path):
			_status_label.text = "Select an orphan first. Files with code found elsewhere cannot be deleted here."
			return
		_confirm_delete(path)
		return

	if _permission_dialog == null:
		_permission_dialog = PermissionDialog.new()
		_permission_dialog.permission_granted.connect(func():
			_deletion.grant()
			_refresh_delete_button()
			_status_label.text = "Deletion enabled. Select an orphan and press Move to trash."
		)
		add_child(_permission_dialog)
	_permission_dialog.prepare()
	_permission_dialog.popup_centered()


func _refresh_delete_button() -> void:
	if _delete_button == null:
		return
	if _deletion_warning != null:
		_deletion_warning.set_warning_enabled(_deletion.is_granted())
	if _deletion.is_granted():
		_delete_button.text = "Move to trash  (%d done)" % _deletion.deleted_count()
		_delete_button.tooltip_text = "Moves the selected orphan to the system trash"
		_delete_button.add_theme_color_override("font_color", Color(1.0, 0.55, 0.35))
	else:
		_delete_button.text = "Enable deleting…"
		_delete_button.remove_theme_color_override("font_color")


func _confirm_delete(path: String) -> void:
	_pending_delete = path
	if _confirm_delete_dialog == null:
		_confirm_delete_dialog = ConfirmationDialog.new()
		_confirm_delete_dialog.title = "Move to trash"
		_confirm_delete_dialog.ok_button_text = "Move to trash"
		_confirm_delete_dialog.confirmed.connect(_on_delete_confirmed)
		add_child(_confirm_delete_dialog)
	_confirm_delete_dialog.dialog_text = "%s\n\nThis file is moved to your system trash and recorded in dependency_atlas/deleted.log.\n\nIf it turns out to be loaded at runtime, restore it from the trash." % path
	_confirm_delete_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	if _pending_delete == "":
		return
	var path := _pending_delete
	_pending_delete = ""
	var problem := _deletion.delete_file(path, "orphan")
	if problem != "":
		_status_label.text = problem
		return
	_plain_orphan_paths.erase(path)
	_refresh_delete_button()
	EditorInterface.get_resource_filesystem().scan()
	_status_label.text = "Moved to trash: %s   (%d this session)" % [
		path, _deletion.deleted_count()
	]
	var selected := _tree.get_selected()
	if selected != null and String(selected.get_metadata(0)) == path:
		selected.set_custom_color(0, Color(0.5, 0.5, 0.5))
		selected.set_text(2, "moved to trash")


func _on_save_log() -> void:
	if _last_log_text == "":
		return
	var path := OrphanScanner.default_log_path()
	var problem := OrphanScanner.write_log_to(path, _last_log_text)
	if problem != "":
		_status_label.text = "Could not save log: " + problem
		return
	EditorInterface.get_resource_filesystem().scan()
	_status_label.text = "Log saved to " + path


func _on_save_log_as() -> void:
	if _last_log_text == "":
		return
	if _save_dialog == null:
		_save_dialog = EditorFileDialog.new()
		_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_save_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_save_dialog.filters = PackedStringArray(["*.txt ; Text report"])
		_save_dialog.file_selected.connect(func(path: String):
			var problem := OrphanScanner.write_log_to(path, _last_log_text)
			_status_label.text = ("Could not save log: " + problem) if problem != "" else ("Log saved to " + path)
		)
		add_child(_save_dialog)
	_save_dialog.current_file = OrphanScanner.default_log_path().get_file()
	_save_dialog.popup_centered_ratio(0.7)


func _on_export_icons() -> void:
	var result: Dictionary = TypeIcons.export_icons()
	var error: String = result.get("error", "")
	if error != "":
		_status_label.text = "Icon export failed: " + error
		return

	var exported: Array = result["exported"]
	var missing: Array = result["missing"]
	# The PNGs are new files on disk; Godot needs to import them before
	# load() will resolve, so nudge the filesystem.
	EditorInterface.get_resource_filesystem().scan()

	_status_label.text = "Exported %d icon(s) to %s%s" % [
		exported.size(), result["dir"],
		"" if missing.is_empty() else "  (%d unavailable in this Godot version: %s)" % [
			missing.size(), ", ".join(missing)
		]
	]


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

	# The previous grant was given about a list that no longer exists.
	_deletion.configure("res://")
	_deletion.revoke()
	_refresh_delete_button()
	_last_log_text = String(result.get("log_text", ""))
	_save_log_button.disabled = _last_log_text == ""
	_save_as_button.disabled = _last_log_text == ""
	_populate(result)


func _on_progress(phase: String, done: int, total: int) -> void:
	match phase:
		"inventory":
			_progress_bar.indeterminate = true
			_progress_bar.value = 0
			_status_label.text = "1/4 Building file inventory... %d found" % done
		"reading":
			_progress_bar.indeterminate = false
			_progress_bar.value = 0.0 if total <= 0 else (float(done) / float(total)) * 100.0
			_status_label.text = "2/4 Reading file contents... %d / %d" % [done, total]
		"indexing":
			_progress_bar.indeterminate = false
			_progress_bar.value = 0.0 if total <= 0 else (float(done) / float(total)) * 100.0
			_status_label.text = "3/4 Indexing UIDs and class names... %d / %d" % [done, total]
		"traversing":
			_progress_bar.indeterminate = true
			_status_label.text = "Following references from entry points... %d file(s) reached" % done
		"mapping orphan links":
			_progress_bar.indeterminate = total <= 0
			_progress_bar.value = 0.0 if total <= 0 else (float(done) / float(total)) * 100.0
			_status_label.text = "Mapping relationships between unused files... %d / %d" % [done, total]
		"checking duplicated content":
			_progress_bar.indeterminate = total <= 0
			_progress_bar.value = 0.0 if total <= 0 else (float(done) / float(total)) * 100.0
			_status_label.text = "Checking whether unused content was copied elsewhere... %d / %d" % [done, total]
		"building class hierarchy":
			_progress_bar.indeterminate = true
			_status_label.text = "Building class inheritance hierarchy..."
		"writing report":
			_progress_bar.indeterminate = true
			_status_label.text = "Preparing scan results..."
		_:
			_progress_bar.indeterminate = total <= 0
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

	if _deletion.is_granted():
		var live := _tree.create_item(root)
		live.set_text(0, "DELETION ENABLED — files move to the system trash")
		live.set_text(2, "%d moved so far" % _deletion.deleted_count())
		live.set_custom_color(0, Color(1.0, 0.55, 0.35))
		live.set_selectable(0, false)

	# Reported first, because it changes how much the rest can be trusted.
	if not bool(result.get("godot_pass_used", false)):
		var warn := _tree.create_item(root)
		warn.set_text(0, "⚠ EXTERNAL PROJECT — results are less reliable")
		warn.set_text(2, "binary .scn/.res fall back to byte-scanning")
		warn.set_custom_color(0, Color(1.0, 0.55, 0.3))
		warn.set_selectable(0, false)
		warn.set_tooltip_text(0, "Godot's own dependency data is only available for the project this addon runs inside.\n\nWithout it, references stored as object pointers -- a GridMap's mesh library, for example -- cannot be seen, so files may be listed as orphans while actually in use.\n\nScan from inside that project before deleting anything.")
	else:
		var ok_item := _tree.create_item(root)
		ok_item.set_text(0, "Godot dependency data used for %d resource file(s)" % int(result.get("godot_dependency_files", 0)))
		ok_item.set_text(2, "authoritative for .scn / .res / .tscn / .tres")
		ok_item.set_custom_color(0, Color(0.55, 0.78, 1.0))
		ok_item.set_selectable(0, false)
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

	# Three buckets, in descending confidence that the file is still needed:
	#   resources/shaders whose code is embedded -- nearly always still used
	#   other files whose code is embedded        -- probably used, verify
	#   everything else                           -- no evidence of use
	# The 3D view draws these teal / amber / red; the wording here says the
	# same thing so the panel alone is enough to judge.
	const PROXY_KINDS := ["tres", "res", "gdshader", "gdshaderinc"]
	var plain_orphans: Array = []
	var likely_used: Array = []
	var maybe_used: Array = []
	for o in orphans:
		var od_split: Dictionary = o
		if not od_split.has("duplicated_in"):
			plain_orphans.append(od_split)
		elif String(od_split["path"]).get_extension().to_lower() in PROXY_KINDS:
			likely_used.append(od_split)
		else:
			maybe_used.append(od_split)

	if not likely_used.is_empty():
		_add_embedded_section(
			root, likely_used, Color(0.35, 0.85, 0.78),
			"IN USE — resource/shader code found inline (%d)" % likely_used.size(),
			"almost certainly still needed",
			"%s\n\nIts exact content was found inside\n%s\n\nResources and shaders are inlined by Make Unique all the time, and the original is nearly always still wanted. Keep unless you are certain."
		)

	if not maybe_used.is_empty():
		_add_embedded_section(
			root, maybe_used, Color(1.0, 0.72, 0.30),
			"⚠ POSSIBLY IN USE — code found inline elsewhere (%d)" % maybe_used.size(),
			"verify before deleting",
			"%s\n\nIts exact content was found inside\n%s\n\nNothing references this file, but its code IS running from that copy. Check whether the copy was meant to replace it before deleting."
		)
	orphans = plain_orphans
	# Only these are deletable: embedded-code entries are excluded because
	# their code demonstrably still runs somewhere.
	_plain_orphan_paths.clear()
	for o in plain_orphans:
		_plain_orphan_paths[String((o as Dictionary)["path"])] = true

	if orphans.is_empty():
		var none_item := _tree.create_item(root)
		none_item.set_text(0, "No unreferenced files without a duplicate found.")
		none_item.set_selectable(0, false)
		none_item.set_selectable(1, false)
		none_item.set_selectable(2, false)
	else:
		var orphans_header := _tree.create_item(root)
		orphans_header.set_text(0, "ORPHANS -- never reached from any entry point (%d)" % orphans.size())
		orphans_header.set_selectable(0, false)
		orphans_header.set_selectable(1, false)
		orphans_header.set_selectable(2, false)
		orphans_header.set_custom_color(0, Color(1.0, 0.6, 0.5))
		for o in orphans:
			var od: Dictionary = o
			var item2 := _tree.create_item(root)
			item2.set_text(0, String(od["path"]))
			item2.set_text(1, _format_size(int(od["size"])))
			if od.has("duplicated_in"):
				item2.set_text(2, "content duplicated inline in " + String(od["duplicated_in"]).get_file())
				item2.set_custom_color(0, Color(1.0, 0.75, 0.4))
			else:
				item2.set_text(2, "unreachable")
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

	# --- entanglement metrics ---
	var metrics: Dictionary = GraphMetrics.analyze(result.get("graph", {}), result.get("edge_kinds", {}))
	var metrics_header := _tree.create_item(root)
	metrics_header.set_text(0, "ENTANGLEMENT -- tangle index %.0f / 100 (%s)" % [
		float(metrics["tangle_index"]), String(metrics["tangle_band"])
	])
	metrics_header.set_text(2, "heuristic, see components")
	metrics_header.set_selectable(0, false)
	metrics_header.set_selectable(1, false)
	metrics_header.set_selectable(2, false)
	metrics_header.set_custom_color(0, _tangle_color(float(metrics["tangle_index"])))
	metrics_header.set_collapsed(true)

	var summary: Array = [
		["Dependency cycles", "%d cycle(s) covering %d file(s)" % [
			(metrics["cycles"] as Array).size(), int(metrics["files_in_cycles"])]],
		["Cross-folder references", "%.0f%% of %d edge(s) jump between top-level folders" % [
			float(metrics["cross_folder_ratio"]) * 100.0, int(metrics["total_edges"])]],
		["Hub concentration", "%.0f%% of all coupling sits in the worst 10%% of files" % [
			float(metrics["hub_concentration"]) * 100.0]],
		["Average fan-out", "%.1f reference(s) per file" % float(metrics["avg_fan_out"])],
	]
	for row in summary:
		var item := _tree.create_item(metrics_header)
		item.set_text(0, "  " + String(row[0]))
		item.set_text(2, String(row[1]))
		item.set_selectable(0, false)

	var cycles: Array = metrics["cycles"]
	if not cycles.is_empty():
		var cycles_item := _tree.create_item(metrics_header)
		cycles_item.set_text(0, "  Dependency cycles (%d)" % cycles.size())
		cycles_item.set_text(2, "strongest entanglement signal")
		cycles_item.set_custom_color(0, Color(1.0, 0.45, 0.9))
		cycles_item.set_selectable(0, false)
		cycles_item.set_collapsed(true)
		for c in cycles:
			var cycle: Array = c
			var group := _tree.create_item(cycles_item)
			group.set_text(0, "cycle of %d" % cycle.size())
			group.set_selectable(0, false)
			for f in cycle:
				var f_item := _tree.create_item(group)
				f_item.set_text(0, String(f))
				f_item.set_metadata(0, String(f))

	var hotspots: Array = metrics["hotspots"]
	if not hotspots.is_empty():
		var hot_item := _tree.create_item(metrics_header)
		hot_item.set_text(0, "  Hotspots (%d)" % hotspots.size())
		hot_item.set_text(2, "high fan-in x fan-out, or in a cycle")
		hot_item.set_custom_color(0, Color(0.55, 0.78, 1.00))
		hot_item.set_selectable(0, false)
		hot_item.set_collapsed(true)
		for h in hotspots:
			var hd: Dictionary = h
			var h_item := _tree.create_item(hot_item)
			h_item.set_text(0, String(hd["path"]))
			h_item.set_text(1, "hub %d" % int(hd["hub_score"]))
			h_item.set_text(2, "in %d / out %d%s" % [
				int(hd["fan_in"]), int(hd["fan_out"]),
				"  (in cycle)" if bool(hd["in_cycle"]) else ""
			])
			h_item.set_metadata(0, String(hd["path"]))

	if not unresolved_refs.is_empty():
		var unres_header := _tree.create_item(root)
		unres_header.set_text(0, "UNRESOLVED REFERENCES -- seen but not matched to a file (%d)" % unresolved_refs.size())
		unres_header.set_text(2, "likely cause of false orphans")
		unres_header.set_selectable(0, false)
		unres_header.set_selectable(1, false)
		unres_header.set_selectable(2, false)
		unres_header.set_custom_color(0, Color(1.0, 0.85, 0.3))
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


## Entanglement is diagnostic information, not a defect report. The old
## green/yellow/orange/red scale read as an alert -- the same visual language
## as the orphan warnings -- so severity now rides the editor's blue accent
## range instead. Nothing here means "broken".
## One embedded-code section: header, colour, and a row per file.
func _add_embedded_section(
	root: TreeItem, entries: Array, colour: Color,
	header_text: String, header_note: String, tooltip_format: String
) -> void:
	var header := _tree.create_item(root)
	header.set_text(0, header_text)
	header.set_text(2, header_note)
	header.set_selectable(0, false)
	header.set_selectable(1, false)
	header.set_selectable(2, false)
	header.set_custom_color(0, colour)
	for e in entries:
		var entry: Dictionary = e
		var item := _tree.create_item(root)
		item.set_text(0, String(entry["path"]))
		item.set_text(1, _format_size(int(entry["size"])))
		item.set_text(2, "inlined in " + String(entry["duplicated_in"]).get_file())
		item.set_custom_color(0, colour)
		item.set_tooltip_text(0, tooltip_format % [
			String(entry["path"]), String(entry["duplicated_in"])
		])
		item.set_metadata(0, String(entry["path"]))


static func _tangle_color(tangle: float) -> Color:
	if tangle < 12.0:
		return Color(0.58, 0.82, 1.00)
	if tangle < 25.0:
		return Color(0.45, 0.68, 1.00)
	if tangle < 40.0:
		return Color(0.36, 0.56, 0.96)
	return Color(0.42, 0.47, 0.94)


static func _format_size(bytes: int) -> String:
	if bytes < 0:
		return "?"
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.1f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / (1024.0 * 1024.0))
