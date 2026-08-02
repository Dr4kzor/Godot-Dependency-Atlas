@tool
extends Window

## Legend dialog: what every colour in the graph means, plus the theme picker.

## Named palette_selected rather than theme_changed: Window already has a
## native theme_changed signal and redefining it is a parse error.
signal palette_selected(theme_id: String)

const TypeIcons = preload("res://addons/godot_dependency_atlas/graph3d/type_icons.gd")
const OFThemes = preload("res://addons/godot_dependency_atlas/graph3d/of_themes.gd")

var _rows_box: VBoxContainer
var _theme_picker: OptionButton
var _theme_ids: Array = []
var _current_theme := OFThemes.DEFAULT_THEME


func _init() -> void:
	title = "Colours & Legend"
	size = Vector2i(430, 640)
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
	_theme_ids = OFThemes.theme_ids()
	for i in _theme_ids.size():
		_theme_picker.add_item(OFThemes.label_of(String(_theme_ids[i])), i)
	_theme_picker.item_selected.connect(_on_theme_selected)
	theme_row.add_child(_theme_picker)

	var note := Label.new()
	note.text = "Saved to dependency-atlas.config in the scanned project."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	note.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	root_box.add_child(note)

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
	palette_selected.emit(_current_theme)


func rebuild() -> void:
	for child in _rows_box.get_children():
		child.queue_free()

	_add_heading("File kinds")
	for kind_value in TypeIcons.Kind.values():
		var kind = kind_value
		var kind_name: String = TypeIcons.Kind.keys()[int(kind)]
		_add_row(
			OFThemes.kind_color(_current_theme, kind_name),
			TypeIcons.kind_label(kind),
			_kind_description(kind_name)
		)

	_add_heading("Node roles")
	_add_row(OFThemes.role_color(_current_theme, "root"), "Entry point",
		"Main scene, autoload or editor plugin — where traversal starts.")
	_add_row(OFThemes.role_color(_current_theme, "orphan"), "Orphan",
		"Never reached from any entry point. Verify before deleting.")
	_add_row(OFThemes.role_color(_current_theme, "cycle"), "In a cycle",
		"Heat mode only. Part of a circular dependency.")

	_add_heading("Connections")
	_add_row(OFThemes.role_color(_current_theme, "out"), "Outgoing",
		"The selected file depends on this one. Strand count or tube thickness = lines of code involved.")
	_add_row(OFThemes.role_color(_current_theme, "in"), "Incoming",
		"That file depends on the selected one.")
	_add_row(Color(0.55, 0.65, 0.80), "Tree edge",
		"The reference traversal actually followed to first reach a file.")
	_add_row(Color(0.50, 0.42, 0.60), "Cross-link",
		"An additional reference to a file already placed elsewhere.")

	_add_row(Color(0.45, 0.90, 0.80), "Folder coupling",
		"Shown when a folder is selected in folder mode: which other folders its contents reference, or are referenced by.")

	_add_heading("Gather on selection (R)")
	_add_row(Color(0.55, 0.80, 1.00), "Left of the selection",
		"Files that depend on it — what a change to it would reach.")
	_add_row(Color(1.00, 0.72, 0.45), "Right of the selection",
		"Files it depends on — what it needs in order to work.")
	_add_row(Color(0.70, 0.70, 0.74), "Whole branches move together",
		"Each relation brings its own subtree, keeping the structure the scan found. Unrelated nodes are pushed clear rather than buried, and everything returns to its real position when the selection changes.")

	_add_heading("Analysis overlays (right-click a node)")
	_add_row(Color(0.40, 1.00, 0.55), "Reachability path",
		"A chain from an entry point to the selected file. Answers why it is in the build; cutting any one link breaks that chain.")
	_add_row(Color(0.75, 1.00, 0.85), "Travelling pulse",
		"Walks each chain from the entry point, lighting nodes and edges as it arrives. Replays on a loop so the route can be followed more than once.")
	_add_row(Color(1.00, 0.55, 0.25), "Change impact — direct",
		"Files that use the selected one directly. These are the ones a change actually lands on.")
	_add_row(Color(0.72, 0.45, 0.32), "Change impact — indirect",
		"Further down the chain. Shown dimmer because impact fades with each hop; the full transitive count is reported in the panel.")

	_add_heading("Inlined copies (U)")
	_add_row(Color(0.35, 0.85, 0.78), "Resource / shader with embedded code",
		"A .tres or .gdshader whose code was found inline in a live file. Teal rather than a warning colour because these are almost always still wanted. A copy of it is drawn in the tree where the code actually sits; clicking either selects the same file.")
	_add_row(Color(1.00, 0.72, 0.30), "Other file with embedded code",
		"Same situation, but not a resource or shader — worth a closer look before deleting.")
	_add_row(Color(0.72, 0.42, 1.00), "Inlined-copy link",
		"Joins a standalone resource to the live file that embeds its exact code. Shown with U, or whenever either end is selected.")
	_add_row(Color(0.70, 0.35, 0.35), "Tie to the orphan cube",
		"Groups a semi-orphan with the orphan area without implying a real dependency.")
	_add_row(Color(1.00, 0.32, 0.30), "Cube marker — lone orphans",
		"Files nothing references, and which reference nothing else themselves. Individually droppable leftovers.")
	_add_row(Color(1.00, 0.32, 0.30), "Sphere marker — orphan clusters",
		"Orphans that reference each other: a dead subsystem, best reviewed as a unit rather than file by file.")
	_add_row(Color(0.70, 0.70, 0.74), "Orphans sit below the tree",
		"Dead code is layered beneath the live graph, centred under the entry point: the red cube marker on top, then orphans whose code was found embedded elsewhere, then everything else one layer further down.")
	_add_row(Color(1.00, 0.85, 0.15), "Triangle above a node's label",
		"Always shown. Marks a live file that CONTAINS someone else's code — usually the result of Make Unique.")
	_add_row(Color(1.00, 0.72, 0.30), "Round warning as a node's icon",
		"The orphan itself, whose code was found inside another file. Different shape from the badge so the two directions are never confused.")
	_add_row(Color(0.66, 0.40, 0.38), "Orphan dependency",
		"A real reference between two orphans. Dead code still has internal structure; this is what makes a dead cluster readable as one unit.")

	_add_heading("Heat map")
	_add_row(Color(0.35, 0.85, 0.45), "Low coupling", "Few lines depend on it and it depends on few.")
	_add_row(Color(1.00, 0.90, 0.30), "Moderate", "")
	_add_row(Color(1.00, 0.25, 0.20), "Chokepoint",
		"High incoming AND outgoing line weight — changes here ripple both ways.")


func _kind_description(kind_name: String) -> String:
	match kind_name:
		"SCENE":
			return ".tscn / .scn"
		"SCRIPT":
			return ".gd / .cs"
		"SHADER":
			return ".gdshader"
		"RESOURCE":
			return ".tres / .res"
		"DATA":
			return ".json / .cfg / .import / .uid"
		"BINARY":
			return ".so / .dll / .dylib / .wasm — compiled native libraries"
		"GDEXTENSION":
			return ".gdextension — GDExtension loader descriptor"
		"OTHER":
			return "Unrecognised extension — deliberately loud so oddities stand out."
	return ""


func _add_heading(text: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	_rows_box.add_child(spacer)
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	_rows_box.add_child(label)
	_rows_box.add_child(HSeparator.new())


func _add_row(colour: Color, row_name: String, description: String) -> void:
	var row := HBoxContainer.new()
	var swatch := ColorRect.new()
	swatch.color = colour
	swatch.custom_minimum_size = Vector2(18, 18)
	row.add_child(swatch)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var name_label := Label.new()
	name_label.text = row_name
	text_box.add_child(name_label)
	if description != "":
		var desc := Label.new()
		desc.text = description
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
		text_box.add_child(desc)
	row.add_child(text_box)
	_rows_box.add_child(row)
