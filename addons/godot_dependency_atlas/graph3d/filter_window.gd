@tool
extends Window

## Filter dialog: hide whole file kinds, hide individual extensions, and add
## custom extensions the built-in kind list doesn't cover.
##
## Extension filtering exists alongside kind filtering because "Resource"
## lumps .tres and .res together, and you often want to hide one without the
## other -- or hide a project-specific extension the tool has never heard of.

signal filters_changed(hidden_kinds: Array, hidden_extensions: Array, custom_extensions: Array)

const TypeIcons = preload("res://addons/godot_dependency_atlas/graph3d/type_icons.gd")

var _kind_boxes := {}        # kind int -> CheckBox
var _extension_boxes := {}   # extension -> CheckBox
var _extension_list: VBoxContainer
var _custom_input: LineEdit
var _custom_extensions: Array = []
var _project_extensions: Array = []
var _intro: Label


func _init() -> void:
	title = "Filters"
	size = Vector2i(460, 620)
	unresizable = false
	close_requested.connect(func(): hide())

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var root_box := VBoxContainer.new()
	margin.add_child(root_box)

	_intro = Label.new()
	_intro.text = "Unchecked items are removed from the graph entirely, which also simplifies the layout."
	_intro.autowrap_mode = TextServer.AUTOWRAP_WORD
	_intro.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	root_box.add_child(_intro)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_box.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)

	var kinds_title := Label.new()
	kinds_title.text = "File kinds"
	content.add_child(kinds_title)

	for kind_value in TypeIcons.Kind.values():
		var kind = kind_value
		var box := CheckBox.new()
		box.text = TypeIcons.kind_label(kind)
		box.button_pressed = true
		box.toggled.connect(func(_on: bool): _emit())
		content.add_child(box)
		_kind_boxes[int(kind)] = box

	content.add_child(HSeparator.new())

	var ext_title := Label.new()
	ext_title.text = "Individual extensions"
	content.add_child(ext_title)

	var ext_hint := Label.new()
	ext_hint.text = "Finer than kinds: hide .tres without hiding .res, and so on."
	ext_hint.autowrap_mode = TextServer.AUTOWRAP_WORD
	ext_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	content.add_child(ext_hint)

	_extension_list = VBoxContainer.new()
	content.add_child(_extension_list)

	content.add_child(HSeparator.new())

	var custom_title := Label.new()
	custom_title.text = "Add a custom extension"
	content.add_child(custom_title)

	var custom_row := HBoxContainer.new()
	content.add_child(custom_row)

	_custom_input = LineEdit.new()
	_custom_input.placeholder_text = "e.g. bak"
	_custom_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_custom_input.text_submitted.connect(func(_t: String): _add_custom())
	custom_row.add_child(_custom_input)

	var add_button := Button.new()
	add_button.text = "Add"
	add_button.pressed.connect(_add_custom)
	custom_row.add_child(add_button)

	var footer := HBoxContainer.new()
	root_box.add_child(footer)

	var all_on := Button.new()
	all_on.text = "Show all"
	all_on.pressed.connect(func(): _set_all(true))
	footer.add_child(all_on)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.pressed.connect(func(): hide())
	footer.add_child(close_button)


## The same checklist serves two deliberately different jobs: structural
## filtering and display-only visibility. The owner supplies the semantics.
func set_presentation(window_title: String, explanation: String) -> void:
	title = window_title
	if _intro != null:
		_intro.text = explanation


## Rebuilds the extension list from what the project actually contains, plus
## whatever custom extensions were saved.
func configure(project_extensions: Array, hidden_kinds: Array, hidden_extensions: Array, custom_extensions: Array) -> void:
	_project_extensions = project_extensions.duplicate()
	_custom_extensions = custom_extensions.duplicate()

	for key in _kind_boxes.keys():
		var box: CheckBox = _kind_boxes[key]
		box.set_pressed_no_signal(not (int(key) in hidden_kinds))

	_rebuild_extension_list(hidden_extensions)


func _rebuild_extension_list(hidden_extensions: Array) -> void:
	for child in _extension_list.get_children():
		child.queue_free()
	_extension_boxes.clear()

	var all_extensions := {}
	for e in _project_extensions:
		all_extensions[String(e).to_lower()] = true
	for e in _custom_extensions:
		all_extensions[String(e).to_lower()] = true

	var sorted: Array = all_extensions.keys()
	sorted.sort()

	for e in sorted:
		var ext: String = e
		var row := HBoxContainer.new()
		var box := CheckBox.new()
		box.text = "." + ext
		box.button_pressed = not (ext in hidden_extensions)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.toggled.connect(func(_on: bool): _emit())
		row.add_child(box)

		if ext in _custom_extensions:
			var tag := Label.new()
			tag.text = "custom"
			tag.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
			row.add_child(tag)
			var remove := Button.new()
			remove.text = "x"
			remove.tooltip_text = "Remove this custom extension"
			remove.pressed.connect(func(): _remove_custom(ext))
			row.add_child(remove)

		_extension_list.add_child(row)
		_extension_boxes[ext] = box


func _add_custom() -> void:
	var raw := _custom_input.text.strip_edges().to_lower().trim_prefix(".")
	if raw == "":
		return
	if not (raw in _custom_extensions):
		_custom_extensions.append(raw)
	_custom_input.text = ""
	# A newly added custom extension starts hidden, since adding it is only
	# ever done in order to filter it out.
	var hidden := _current_hidden_extensions()
	if not (raw in hidden):
		hidden.append(raw)
	_rebuild_extension_list(hidden)
	_emit()


func _remove_custom(ext: String) -> void:
	_custom_extensions.erase(ext)
	var hidden := _current_hidden_extensions()
	hidden.erase(ext)
	_rebuild_extension_list(hidden)
	_emit()


func _set_all(value: bool) -> void:
	for key in _kind_boxes.keys():
		(_kind_boxes[key] as CheckBox).set_pressed_no_signal(value)
	for key in _extension_boxes.keys():
		(_extension_boxes[key] as CheckBox).set_pressed_no_signal(value)
	_emit()


func _current_hidden_extensions() -> Array:
	var hidden: Array = []
	for key in _extension_boxes.keys():
		if not (_extension_boxes[key] as CheckBox).button_pressed:
			hidden.append(String(key))
	return hidden


func _emit() -> void:
	var hidden_kinds: Array = []
	for key in _kind_boxes.keys():
		if not (_kind_boxes[key] as CheckBox).button_pressed:
			hidden_kinds.append(int(key))
	filters_changed.emit(hidden_kinds, _current_hidden_extensions(), _custom_extensions.duplicate())
