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

const OFThemes = preload("res://addons/orphan_finder/graph3d/of_themes.gd")

var scope := "nodes"

var _theme_picker: OptionButton
var _rows_box: VBoxContainer
var _summary: Label
var _theme_ids: Array = []
var _current_theme := ""
var _entries: Array = []          # [{ key, label, description }]
var _overrides                    # ColourOverrides, injected by the viewer


func configure(new_scope: String, window_title: String, theme_ids: Array,
		labels: Array, entries: Array, overrides) -> void:
	scope = new_scope
	title = window_title
	_theme_ids = theme_ids.duplicate()
	_entries = entries.duplicate()
	_overrides = overrides

	_theme_picker.clear()
	for i in labels.size():
		_theme_picker.add_item(String(labels[i]), i)


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

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD
	_summary.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	root_box.add_child(_summary)

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


func set_theme_id(theme_id: String) -> void:
	_current_theme = theme_id
	var index := _theme_ids.find(theme_id)
	if index >= 0:
		_theme_picker.select(index)
	rebuild()


func _on_theme_selected(index: int) -> void:
	if index < 0 or index >= _theme_ids.size():
		return
	_current_theme = String(_theme_ids[index])
	rebuild()
	theme_selected.emit(scope, _current_theme)


func _on_reset_theme() -> void:
	theme_reset.emit(scope, _current_theme)
	rebuild()


func _resolved(key: String, fallback: Color) -> Color:
	if _overrides == null:
		return fallback
	return _overrides.get_override(scope, _current_theme, key, fallback)


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

	_summary.text = "Click a swatch to change it. %s" % (
		"%d colour(s) customised — reset restores the theme's own." % overridden
		if overridden > 0 else "No colours customised."
	)


func _add_row(entry: Dictionary) -> void:
	var key := String(entry["key"])
	var base: Color = entry["default"]
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

	# Only shown when this key actually differs from the theme, so the button
	# itself tells you what has been touched.
	if _is_overridden(key):
		var reset := Button.new()
		reset.text = "↺"
		reset.tooltip_text = "Reset this colour to the theme's own"
		reset.pressed.connect(func():
			colour_reset.emit(scope, _current_theme, key)
			rebuild()
		)
		row.add_child(reset)

	_rows_box.add_child(row)


func _refresh_summary() -> void:
	var overridden := 0
	for entry_any in _entries:
		if _is_overridden(String((entry_any as Dictionary)["key"])):
			overridden += 1
	_summary.text = "Click a swatch to change it. %s" % (
		"%d colour(s) customised — reset restores the theme's own." % overridden
		if overridden > 0 else "No colours customised."
	)
