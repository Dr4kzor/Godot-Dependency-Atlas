@tool
extends Window

## Theme picker with per-colour overrides. Used twice, once for node colours
## and once for connection colours, so the two can be themed independently and
## mixed freely.
##
## Every row shows the current colour, a picker to change it, and a reset that
## appears only when that key is actually overridden -- so the presence of a
## reset button doubles as the indicator that something has been customised.

signal theme_selected(scope: String, theme_id: String)
signal colour_overridden(scope: String, theme_id: String, key: String, colour: Color)
signal colour_reset(scope: String, theme_id: String, key: String)
signal theme_reset(scope: String, theme_id: String)
signal connection_alpha_changed(idle_alpha: float, selected_alpha: float)
signal save_as_requested(scope: String, source_theme_id: String, name: String)
signal save_requested(scope: String, theme_id: String)
signal rename_requested(scope: String, theme_id: String, name: String)
signal delete_requested(scope: String, theme_id: String)
signal import_requested(path: String)
signal export_requested(scope: String, theme_id: String, path: String)

const OFThemes = preload("res://addons/godot_dependency_atlas/graph3d/of_themes.gd")

var scope := "nodes"

var _theme_picker: OptionButton
var _rows_box: VBoxContainer
var _summary: Label
var _alpha_box: VBoxContainer
var _idle_alpha: SpinBox
var _selected_alpha: SpinBox
var _rename_button: Button
var _save_button: Button
var _delete_button: Button
var _name_dialog: ConfirmationDialog
var _name_input: LineEdit
var _name_action := ""
var _import_dialog: FileDialog
var _export_dialog: FileDialog
var _delete_dialog: ConfirmationDialog
var _theme_ids: Array = []
var _current_theme := ""
var _entries: Array = []          # [{ key, label, description }]
var _overrides                    # ColourOverrides, injected by the viewer


func configure(new_scope: String, window_title: String, theme_ids: Array,
		labels: Array, entries: Array, overrides, connection_alphas := {}) -> void:
	scope = new_scope
	title = window_title
	_theme_ids = theme_ids.duplicate()
	_entries = entries.duplicate()
	_overrides = overrides

	_theme_picker.clear()
	for i in labels.size():
		_theme_picker.add_item(String(labels[i]), i)
	_alpha_box.visible = scope == "connections"
	if scope == "connections":
		_idle_alpha.set_value_no_signal(float(connection_alphas.get("idle", 0.06)))
		_selected_alpha.set_value_no_signal(float(connection_alphas.get("selected", 1.0)))
	_update_custom_actions()


func _init() -> void:
	size = Vector2i(470, 680)
	close_requested.connect(func(): hide())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)

	var root_box := VBoxContainer.new()
	margin.add_child(root_box)

	var theme_row := HBoxContainer.new()
	root_box.add_child(theme_row)
	var theme_label := Label.new()
	theme_label.text = "Theme"
	theme_row.add_child(theme_label)

	_theme_picker = OptionButton.new()
	_theme_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_theme_picker.item_selected.connect(_on_theme_selected)
	theme_row.add_child(_theme_picker)

	var reset_all := Button.new()
	reset_all.text = "Reset theme"
	reset_all.tooltip_text = "Discard every colour override for this theme"
	reset_all.pressed.connect(_on_reset_theme)
	theme_row.add_child(reset_all)

	var custom_row := HFlowContainer.new()
	root_box.add_child(custom_row)
	var save_as := Button.new()
	save_as.text = "Save as new…"
	save_as.tooltip_text = "Bake the visible colours into a named custom JSON theme"
	save_as.pressed.connect(func(): _ask_for_name("save"))
	custom_row.add_child(save_as)
	_save_button = Button.new()
	_save_button.text = "Save"
	_save_button.tooltip_text = "Save current overrides into this custom theme"
	_save_button.pressed.connect(func(): save_requested.emit(scope, _current_theme))
	custom_row.add_child(_save_button)
	_rename_button = Button.new()
	_rename_button.text = "Rename…"
	_rename_button.tooltip_text = "Rename this custom theme"
	_rename_button.pressed.connect(func(): _ask_for_name("rename"))
	custom_row.add_child(_rename_button)
	var import_button := Button.new()
	import_button.text = "Import…"
	import_button.pressed.connect(func(): _import_dialog.popup_centered_ratio(0.7))
	custom_row.add_child(import_button)
	var export_button := Button.new()
	export_button.text = "Export…"
	export_button.pressed.connect(func(): _export_dialog.popup_centered_ratio(0.7))
	custom_row.add_child(export_button)
	_delete_button = Button.new()
	_delete_button.text = "Delete…"
	_delete_button.tooltip_text = "Permanently delete this custom theme"
	_delete_button.pressed.connect(func(): _delete_dialog.popup_centered())
	custom_row.add_child(_delete_button)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD
	_summary.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	root_box.add_child(_summary)

	_alpha_box = VBoxContainer.new()
	root_box.add_child(_alpha_box)
	_idle_alpha = _add_alpha_row(
		_alpha_box, "Unselected opacity",
		"Opacity of connections when no node is selected."
	)
	_selected_alpha = _add_alpha_row(
		_alpha_box, "Selected opacity",
		"Opacity of incoming and outgoing connections for the selection."
	)
	_idle_alpha.value_changed.connect(func(_value: float): _emit_connection_alphas())
	_selected_alpha.value_changed.connect(func(_value: float): _emit_connection_alphas())
	_alpha_box.visible = false

	root_box.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_box.add_child(scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_box)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(func(): hide())
	root_box.add_child(close_button)

	_name_dialog = ConfirmationDialog.new()
	_name_dialog.title = "Custom theme name"
	_name_dialog.dialog_text = "Name"
	_name_dialog.min_size = Vector2i(420, 150)
	_name_dialog.confirmed.connect(_on_name_confirmed)
	_name_input = LineEdit.new()
	_name_input.placeholder_text = "Theme name"
	_name_input.position = Vector2(20, 52)
	_name_input.size = Vector2(380, 32)
	_name_dialog.add_child(_name_input)
	add_child(_name_dialog)

	_import_dialog = FileDialog.new()
	_import_dialog.title = "Import JSON theme"
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.filters = PackedStringArray(["*.json ; JSON themes"])
	_import_dialog.file_selected.connect(func(path: String): import_requested.emit(path))
	add_child(_import_dialog)

	_export_dialog = FileDialog.new()
	_export_dialog.title = "Export JSON theme"
	_export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_export_dialog.filters = PackedStringArray(["*.json ; JSON themes"])
	_export_dialog.file_selected.connect(func(path: String):
		export_requested.emit(scope, _current_theme, path)
	)
	add_child(_export_dialog)

	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.title = "Delete custom theme?"
	_delete_dialog.dialog_text = "This removes the custom theme JSON file. This cannot be undone."
	_delete_dialog.ok_button_text = "Delete"
	_delete_dialog.confirmed.connect(func():
		delete_requested.emit(scope, _current_theme)
	)
	add_child(_delete_dialog)


func _add_alpha_row(parent: VBoxContainer, label_text: String, tooltip: String) -> SpinBox:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value := SpinBox.new()
	value.min_value = 0.0
	value.max_value = 1.0
	value.step = 0.01
	value.tooltip_text = tooltip
	value.custom_minimum_size.x = 100.0
	row.add_child(value)
	return value


func _emit_connection_alphas() -> void:
	if scope == "connections":
		connection_alpha_changed.emit(_idle_alpha.value, _selected_alpha.value)


func set_theme_id(theme_id: String) -> void:
	_current_theme = theme_id
	var index := _theme_ids.find(theme_id)
	if index >= 0:
		_theme_picker.select(index)
	_update_custom_actions()
	rebuild()


func _on_theme_selected(index: int) -> void:
	if index < 0 or index >= _theme_ids.size():
		return
	_current_theme = String(_theme_ids[index])
	_update_custom_actions()
	rebuild()
	theme_selected.emit(scope, _current_theme)


func _update_custom_actions() -> void:
	var custom := OFThemes.is_custom_theme(scope, _current_theme)
	if _rename_button != null:
		_rename_button.disabled = not custom
	if _save_button != null:
		_save_button.disabled = not custom
	if _delete_button != null:
		_delete_button.disabled = not custom


func _ask_for_name(action: String) -> void:
	_name_action = action
	_name_input.text = (
		OFThemes.connection_label_of(_current_theme)
		if scope == "connections" else OFThemes.label_of(_current_theme)
	)
	_name_dialog.popup_centered()
	_name_input.grab_focus()
	_name_input.select_all()


func _on_name_confirmed() -> void:
	var chosen := _name_input.text.strip_edges()
	if chosen == "":
		return
	if _name_action == "rename":
		rename_requested.emit(scope, _current_theme, chosen)
	else:
		save_as_requested.emit(scope, _current_theme, chosen)


func _on_reset_theme() -> void:
	theme_reset.emit(scope, _current_theme)
	rebuild()


func _resolved(key: String, fallback: Color) -> Color:
	if _overrides == null:
		return fallback
	return _overrides.get_override(scope, _current_theme, key, fallback)


## Entry dictionaries describe the rows, but their original default belongs
## to the theme that was active when the window opened. Resolve the swatch
## against the theme currently selected in the picker so previewing another
## palette really shows that palette.
func _theme_default(entry: Dictionary) -> Color:
	var key := String(entry["key"])
	if scope == "connections":
		return OFThemes.connection_color(_current_theme, key)
	if key.begins_with("kind_"):
		return OFThemes.kind_color(_current_theme, key.trim_prefix("kind_"))
	if key.begins_with("role_"):
		return OFThemes.role_color(_current_theme, key.trim_prefix("role_"))
	return entry["default"]


func _is_overridden(key: String) -> bool:
	return _overrides != null and _overrides.has_override(scope, _current_theme, key)


func rebuild() -> void:
	for child in _rows_box.get_children():
		child.queue_free()

	var overridden := 0
	for entry_any in _entries:
		var entry: Dictionary = entry_any
		if _is_overridden(String(entry["key"])):
			overridden += 1
		_add_row(entry)

	var scope_note := (
		"Only graph connections change; file/node colours remain untouched. "
		if scope == "connections" else ""
	)
	_summary.text = scope_note + "Click a swatch to change it. %s" % (
		"%d colour(s) customised — reset restores the theme's own." % overridden
		if overridden > 0 else "No colours customised."
	)


func _add_row(entry: Dictionary) -> void:
	var key := String(entry["key"])
	var base := _theme_default(entry)
	var current := _resolved(key, base)

	var row := HBoxContainer.new()

	var picker := ColorPickerButton.new()
	picker.color = current
	picker.custom_minimum_size = Vector2(46, 24)
	picker.edit_alpha = false
	picker.color_changed.connect(func(c: Color):
		colour_overridden.emit(scope, _current_theme, key, c)
		_refresh_summary()
	)
	row.add_child(picker)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_label := Label.new()
	name_label.text = String(entry["label"])
	text_box.add_child(name_label)
	var description := String(entry.get("description", ""))
	if description != "":
		var desc := Label.new()
		desc.text = description
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
		text_box.add_child(desc)
	row.add_child(text_box)

	# Create it up front so changing the picker can reveal it immediately;
	# rebuilding a row while its ColorPicker popup is open would close it.
	var reset := Button.new()
	reset.text = "↺"
	reset.tooltip_text = "Reset this colour to the theme's own"
	reset.visible = _is_overridden(key)
	reset.pressed.connect(func():
		colour_reset.emit(scope, _current_theme, key)
		rebuild()
	)
	row.add_child(reset)
	picker.color_changed.connect(func(_colour: Color): reset.visible = true)

	_rows_box.add_child(row)


func _refresh_summary() -> void:
	var overridden := 0
	for entry_any in _entries:
		if _is_overridden(String((entry_any as Dictionary)["key"])):
			overridden += 1
	var scope_note := (
		"Only graph connections change; file/node colours remain untouched. "
		if scope == "connections" else ""
	)
	_summary.text = scope_note + "Click a swatch to change it. %s" % (
		"%d colour(s) customised — reset restores the theme's own." % overridden
		if overridden > 0 else "No colours customised."
	)
