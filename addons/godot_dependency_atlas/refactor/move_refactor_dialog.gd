@tool
class_name MoveRefactorDialog
extends ConfirmationDialog

signal refactor_requested(moves: Array)

## Size of the "Move + Refactor" popup window. Edit these values to resize it.
const DIALOG_MIN_SIZE := Vector2i(520, 420)

var _source_path: String = ""
var _is_dir: bool = false
var _scan_id: int = 0

var _source_label: Label
var _new_path_edit: LineEdit
var _browse_button: Button
var _preview_list: ItemList
var _status_label: Label
var _progress_bar: ProgressBar
var _progress_label: Label
var _file_dialog: FileDialog


func _init() -> void:
	title = "Move + Refactor"
	min_size = DIALOG_MIN_SIZE
	get_ok_button().text = "Move + Refactor"

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)

	_source_label = Label.new()
	_source_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_source_label)

	var new_path_hbox := HBoxContainer.new()
	vbox.add_child(new_path_hbox)

	var new_path_label := Label.new()
	new_path_label.text = "New path:"
	new_path_hbox.add_child(new_path_label)

	_new_path_edit = LineEdit.new()
	_new_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Only refresh the preview on Enter or focus loss, not per keystroke.
	_new_path_edit.text_submitted.connect(_on_new_path_committed)
	_new_path_edit.focus_exited.connect(_on_new_path_edit_focus_exited)
	new_path_hbox.add_child(_new_path_edit)

	_browse_button = Button.new()
	_browse_button.text = "Browse..."
	_browse_button.pressed.connect(_on_browse_pressed)
	new_path_hbox.add_child(_browse_button)

	var preview_label := Label.new()
	preview_label.text = "Files that reference this path (will be updated):"
	vbox.add_child(preview_label)

	_preview_list = ItemList.new()
	_preview_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_preview_list)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0
	_progress_bar.max_value = 100
	_progress_bar.show_percentage = true
	_progress_bar.visible = false
	vbox.add_child(_progress_bar)

	_progress_label = Label.new()
	_progress_label.visible = false
	_progress_label.modulate = Color(1, 1, 1, 0.7)
	vbox.add_child(_progress_label)

	_status_label = Label.new()
	_status_label.modulate = Color(1, 1, 1, 0.7)
	vbox.add_child(_status_label)

	# FileDialog works both inside the editor plugin and when the graph viewer
	# is run as a normal scene. EditorFileDialog cannot be instantiated by a
	# running project, which made the 3D integration fail during construction.
	_file_dialog = FileDialog.new()
	_file_dialog.access = FileDialog.ACCESS_RESOURCES
	_file_dialog.file_selected.connect(_on_new_path_chosen_filename)
	_file_dialog.dir_selected.connect(_on_new_path_chosen_dir)
	add_child(_file_dialog)

	confirmed.connect(_on_confirmed)


func open_for_paths(paths: PackedStringArray) -> void:
	if paths.size() != 1:
		push_warning("Move + Refactor: select exactly one file or folder.")
		return

	_source_path = paths[0]
	_is_dir = DirAccess.dir_exists_absolute(_source_path)
	_source_label.text = "Moving: %s" % _source_path
	_new_path_edit.text = _source_path
	_update_preview()
	popup_centered(DIALOG_MIN_SIZE)


func _on_browse_pressed() -> void:
	var current := _new_path_edit.text.strip_edges()
	if current.is_empty():
		current = _source_path

	if _is_dir:
		# Folders: pick/create a destination directory. Use "Create Folder"
		# inside the dialog to give it a new name.
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_file_dialog.current_dir = current.get_base_dir()
	else:
		# Files: SAVE_FILE mode lets you navigate AND type a new filename.
		_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_file_dialog.current_dir = current.get_base_dir()
		_file_dialog.current_file = current.get_file()
		var ext := current.get_extension()
		_file_dialog.filters = PackedStringArray(["*.%s" % ext]) if ext != "" else PackedStringArray()

	_file_dialog.popup_centered_ratio(0.7)


func _on_new_path_chosen_dir(path: String) -> void:
	# The chosen directory is the destination parent. Preserve the source
	# folder's name by default; the text field can still be edited to rename it.
	_new_path_edit.text = path.path_join(_source_path.get_file())
	_update_preview()


func _on_new_path_chosen_filename(path: String) -> void:
	_new_path_edit.text = path
	_update_preview()


func _on_new_path_committed(_text: String) -> void:
	_update_preview()


func _on_new_path_edit_focus_exited() -> void:
	_update_preview()


func _update_preview() -> void:
	var new_path := _new_path_edit.text.strip_edges()
	_preview_list.clear()

	if new_path.is_empty() or new_path == _source_path:
		_status_label.text = ""
		_hide_scanning()
		get_ok_button().disabled = false
		return

	_scan_id += 1
	var this_scan := _scan_id
	_show_scanning()
	get_ok_button().disabled = true

	var affected: PackedStringArray = await RefactorEngine.find_references_async(
		_source_path,
		_is_dir,
		func(done: int, total: int): _on_scan_progress(this_scan, done, total)
	)

	if this_scan != _scan_id:
		# A newer scan superseded this one (e.g. user kept typing/browsing);
		# discard these stale results rather than overwrite fresher ones.
		return

	_hide_scanning()
	get_ok_button().disabled = false

	for f in affected:
		_preview_list.add_item(f)
	_status_label.text = "%d file(s) reference this path and will be updated." % affected.size()


func _on_scan_progress(scan_id: int, done: int, total: int) -> void:
	if scan_id != _scan_id:
		return
	var percent := 100.0 if total <= 0 else (float(done) / float(total)) * 100.0
	_progress_bar.value = percent
	_progress_label.text = "Scanning... %d / %d (%d%%)" % [done, total, int(percent)]


func _show_scanning() -> void:
	_progress_bar.value = 0
	_progress_label.text = "Scanning..."
	_progress_bar.visible = true
	_progress_label.visible = true
	_status_label.text = ""


func _hide_scanning() -> void:
	_progress_bar.visible = false
	_progress_label.visible = false


func _on_confirmed() -> void:
	var new_path := _new_path_edit.text.strip_edges()
	if new_path.is_empty() or new_path == _source_path:
		return
	refactor_requested.emit([{"from": _source_path, "to": new_path, "is_dir": _is_dir}])
