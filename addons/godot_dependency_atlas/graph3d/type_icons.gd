@tool
extends RefCounted

## Shared classification of project files into kinds, with a distinct colour
## and a matching Godot editor icon for each.
##
## Icons cannot be pulled from the editor theme at runtime -- the 3D viewer
## runs as its own process, where EditorInterface does not exist. So the
## editor side calls export_icons() once to dump the real EditorIcons to PNG,
## and the viewer loads those PNGs from disk. If they were never exported,
## the viewer falls back to coloured spheres and still works.

## Outline baked around exported marker icons so they read against any node
## colour behind them.
const OUTLINE_COLOR := Color(0, 0, 0, 1)
const OUTLINE_ALPHA_THRESHOLD := 0.35

const ICON_DIR := "res://addons/godot_dependency_atlas/graph3d/icons"

enum Kind {
	SCENE, SCRIPT, SHADER, RESOURCE, IMAGE, AUDIO, VIDEO, MESH,
	FONT, TEXT, DATA, ARCHIVE, TRANSLATION, BINARY, GDEXTENSION, FOLDER, OTHER,
}

## Extension -> Kind. Anything unlisted falls through to OTHER, which is
## deliberately a loud colour so unusual file types stand out rather than
## blending into the rest of the graph.
const EXTENSION_KINDS := {
	"tscn": Kind.SCENE, "scn": Kind.SCENE, "escn": Kind.SCENE,
	"gd": Kind.SCRIPT, "cs": Kind.SCRIPT, "gdc": Kind.SCRIPT,
	"c": Kind.SCRIPT, "cc": Kind.SCRIPT, "cpp": Kind.SCRIPT, "cxx": Kind.SCRIPT,
	"h": Kind.SCRIPT, "hh": Kind.SCRIPT, "hpp": Kind.SCRIPT, "hxx": Kind.SCRIPT,
	"csproj": Kind.DATA, "sln": Kind.DATA, "vcxproj": Kind.DATA,
	"gdshader": Kind.SHADER, "gdshaderinc": Kind.SHADER, "shader": Kind.SHADER,
	"tres": Kind.RESOURCE, "res": Kind.RESOURCE, "material": Kind.RESOURCE,
	"png": Kind.IMAGE, "jpg": Kind.IMAGE, "jpeg": Kind.IMAGE, "webp": Kind.IMAGE,
	"bmp": Kind.IMAGE, "svg": Kind.IMAGE, "tga": Kind.IMAGE, "exr": Kind.IMAGE,
	"hdr": Kind.IMAGE, "ktx": Kind.IMAGE, "dds": Kind.IMAGE,
	"wav": Kind.AUDIO, "ogg": Kind.AUDIO, "mp3": Kind.AUDIO, "flac": Kind.AUDIO,
	"ogv": Kind.VIDEO, "webm": Kind.VIDEO, "mp4": Kind.VIDEO, "avi": Kind.VIDEO,
	"glb": Kind.MESH, "gltf": Kind.MESH, "obj": Kind.MESH, "fbx": Kind.MESH,
	"dae": Kind.MESH, "blend": Kind.MESH, "mesh": Kind.MESH,
	"ttf": Kind.FONT, "otf": Kind.FONT, "woff": Kind.FONT, "woff2": Kind.FONT,
	"fnt": Kind.FONT, "font": Kind.FONT,
	"txt": Kind.TEXT, "md": Kind.TEXT, "rst": Kind.TEXT, "log": Kind.TEXT,
	"json": Kind.DATA, "cfg": Kind.DATA, "csv": Kind.DATA, "xml": Kind.DATA,
	"yml": Kind.DATA, "yaml": Kind.DATA, "ini": Kind.DATA, "toml": Kind.DATA,
	"godot": Kind.DATA, "import": Kind.DATA, "uid": Kind.DATA,
	"zip": Kind.ARCHIVE, "pck": Kind.ARCHIVE, "tar": Kind.ARCHIVE,
	"gz": Kind.ARCHIVE, "7z": Kind.ARCHIVE, "rar": Kind.ARCHIVE,
	"po": Kind.TRANSLATION, "pot": Kind.TRANSLATION, "translation": Kind.TRANSLATION,
	# Shared libraries / opaque blobs. Prefer File over FileBroken so they
	# read as real binaries rather than missing resources.
	"bin": Kind.BINARY, "dat": Kind.BINARY, "so": Kind.BINARY, "dll": Kind.BINARY,
	"dylib": Kind.BINARY, "wasm": Kind.BINARY,
	"gdextension": Kind.GDEXTENSION,
}

const KIND_COLORS := {
	Kind.SCENE: Color(0.40, 0.68, 1.00),
	Kind.SCRIPT: Color(0.42, 0.92, 0.55),
	Kind.SHADER: Color(0.35, 0.95, 0.85),
	Kind.RESOURCE: Color(1.00, 0.70, 0.32),
	Kind.IMAGE: Color(0.80, 0.52, 1.00),
	Kind.AUDIO: Color(1.00, 0.90, 0.36),
	Kind.VIDEO: Color(1.00, 0.52, 0.72),
	Kind.MESH: Color(0.98, 0.45, 0.30),
	Kind.FONT: Color(0.70, 0.80, 0.95),
	Kind.TEXT: Color(0.85, 0.85, 0.80),
	Kind.DATA: Color(0.60, 0.85, 0.72),
	Kind.ARCHIVE: Color(0.78, 0.65, 0.45),
	Kind.TRANSLATION: Color(0.55, 0.75, 1.00),
	Kind.BINARY: Color(0.55, 0.62, 0.78),
	Kind.GDEXTENSION: Color(0.45, 0.78, 0.92),
	Kind.FOLDER: Color(0.55, 0.58, 0.68),
	Kind.OTHER: Color(1.00, 0.30, 0.55),
}

## Kind -> the name of the icon in Godot's own EditorIcons theme type.
const KIND_ICON_NAMES := {
	Kind.SCENE: "PackedScene",
	Kind.SCRIPT: "GDScript",
	Kind.SHADER: "Shader",
	Kind.RESOURCE: "Resource",
	Kind.IMAGE: "Texture2D",
	Kind.AUDIO: "AudioStream",
	Kind.VIDEO: "VideoStream",
	Kind.MESH: "Mesh",
	Kind.FONT: "Font",
	Kind.TEXT: "TextFile",
	Kind.DATA: "JSON",
	Kind.ARCHIVE: "Zip",
	Kind.TRANSLATION: "Translation",
	# Godot has no dedicated "bin" glyph; File is the closest stock icon for
	# compiled shared libraries (.so/.dll). FileBroken was wrongly used before.
	Kind.BINARY: "File",
	Kind.GDEXTENSION: "GDExtension",
	Kind.FOLDER: "Folder",
	Kind.OTHER: "File",
}

## Candidate icon names tried in order, per kind. Godot renames and reshuffles
## editor icons between versions, so every kind needs a chain rather than a
## single hardcoded name -- a kind with no fallbacks simply fails to export
## if its one name is missing.
const ICON_FALLBACKS := {
	Kind.SCENE: ["PackedScene", "Node", "Object"],
	Kind.SCRIPT: ["GDScript", "Script", "File"],
	Kind.SHADER: ["Shader", "ShaderMaterial", "ShaderGlobalsOverride"],
	Kind.RESOURCE: ["Resource", "ResourcePreloader", "Object", "File"],
	Kind.IMAGE: ["Texture2D", "CompressedTexture2D", "ImageTexture", "Image"],
	Kind.AUDIO: ["AudioStream", "AudioStreamPlayer", "AudioStreamWAV", "AudioBusLayout"],
	Kind.VIDEO: ["VideoStream", "VideoStreamPlayer", "File"],
	Kind.MESH: ["Mesh", "ArrayMesh", "MeshInstance3D"],
	Kind.FONT: ["Font", "FontFile", "FontVariation"],
	Kind.TEXT: ["TextFile", "File", "Font"],
	Kind.DATA: ["JSON", "ConfigFile", "File"],
	Kind.ARCHIVE: ["Zip", "Folder", "File"],
	Kind.TRANSLATION: ["Translation", "TranslationServer", "File"],
	Kind.BINARY: ["File", "Object", "Resource"],
	Kind.GDEXTENSION: ["GDExtension", "PluginScript", "Object", "File"],
	Kind.FOLDER: ["Folder", "FolderBrowse", "Filesystem"],
	Kind.OTHER: ["File", "Object"],
}


## Extra icons that aren't file kinds. Exported alongside the kind icons so
## the standalone viewer can show a warning marker.
## Two different warnings, deliberately different shapes:
##   node_warning  the round one, used ON an orphan node whose code was found
##                 elsewhere -- it replaces that node's own type icon
##   host_badge    the triangle, used as a small corner badge on a live file
##                 that CONTAINS someone else's code
##
## Sharing one icon made those two meanings indistinguishable, which is the
## opposite of what a marker is for. Neither has a fallback: exporting the
## wrong shape is worse than exporting none, since the marker would then mean
## something different from what it looks like.
const SPECIAL_ICONS := {
	"node_warning": ["StatusWarning"],
	"host_badge": ["NodeWarning"],
	"toolbar_layout": ["Grid", "GridContainer", "Control"],
	"toolbar_sidecars": ["Import", "File"],
	"toolbar_heat": ["GraphEdit", "GraphNode", "VisualShader"],
	"toolbar_pair": ["LinkButton", "Instance"],
	"toolbar_connections": ["Curve3D", "Path3D", "Line2D"],
	"toolbar_isolate": ["Zoom", "Search"],
	"toolbar_inline": ["ScriptCreate", "Script"],
	"toolbar_gather": ["CenterView", "SnapGrid"],
	"toolbar_pull": ["Move", "ToolMove"],
	"toolbar_group": ["Group", "Groups"],
	"toolbar_group_reasoning": ["Info", "Help", "Groups"],
	"toolbar_labels": ["Font", "Label"],
	"toolbar_label_cull": ["GuiVisibilityHidden", "GuiVisibilityVisible"],
	"toolbar_filter": ["Filter", "Search"],
	"toolbar_visibility": ["GuiVisibilityVisible", "GuiVisibilityHidden"],
	"toolbar_pack_hidden": ["CollapseTree", "Groups", "Group"],
	"toolbar_spacing": ["HSlider", "EditorPosition", "DistractionFree"],
	"toolbar_home": ["CenterView", "ZoomReset"],
	"toolbar_clear": ["Clear", "Remove"],
	"toolbar_panels": ["Panels2", "HBoxContainer"],
	"toolbar_files": ["Filesystem", "Folder"],
	"toolbar_info": ["Info", "Help"],
	"toolbar_layout_dependency": ["FileTree", "Filesystem", "GraphTree"],
	"toolbar_layout_folder": ["Folder", "FolderBrowse"],
	"toolbar_sidecars_off": ["GuiVisibilityHidden", "File"],
	"toolbar_sidecars_on": ["Import", "File"],
	"toolbar_heat_off": ["ColorPick", "Color"],
	"toolbar_heat_on": ["GraphEdit", "GraphNode"],
	"toolbar_pair_off": ["Unlinked", "LinkBroken", "Remove"],
	"toolbar_pair_on": ["LinkButton", "Instance"],
	"toolbar_connections_flat": ["Line2D", "Curve2D"],
	"toolbar_connections_cable": ["Curve3D", "Path3D"],
	"toolbar_connections_tube": ["CylinderMesh", "Mesh"],
	"toolbar_isolate_off": ["ZoomOut", "ZoomLess", "Search"],
	"toolbar_isolate_on": ["Zoom", "ZoomMore"],
	"toolbar_inline_off": ["Unlinked", "LinkBroken", "Script"],
	"toolbar_inline_on": ["ScriptCreate", "Link"],
	"toolbar_gather_off": ["SnapGrid", "Grid"],
	"toolbar_gather_on": ["CenterView", "ZoomReset"],
	"toolbar_pull_off": ["ToolSelect", "Lock", "Control"],
	"toolbar_pull_on": ["ToolMove", "Move"],
	"toolbar_group_off": ["Unlinked", "Groups"],
	"toolbar_group_on": ["LinkButton", "Group"],
	"toolbar_group_reasoning_off": ["GuiVisibilityHidden", "Info"],
	"toolbar_group_reasoning_on": ["GuiVisibilityVisible", "Info"],
	"toolbar_labels_off": ["Font", "Label"],
	"toolbar_labels_on": ["FontSize", "Font"],
	"toolbar_label_cull_off": ["GuiVisibilityVisible"],
	"toolbar_label_cull_on": ["GuiVisibilityHidden"],
	"toolbar_files_off": ["GuiVisibilityHidden", "Filesystem"],
	"toolbar_files_on": ["Filesystem", "Folder"],
	"toolbar_info_off": ["GuiVisibilityHidden", "Info"],
	"toolbar_info_on": ["Info", "GuiVisibilityVisible"],
	"toolbar_pack_hidden_off": ["ExpandTree", "GuiVisibilityHidden", "Groups"],
	"toolbar_pack_hidden_on": ["CollapseTree", "GuiVisibilityVisible", "Group"],
	"toolbar_help": ["Help", "Info"],
}


static func special_icon_path(key: String) -> String:
	return "%s/special_%s.png" % [ICON_DIR, key]


static func kind_of(path: String) -> Kind:
	var ext := path.get_extension().to_lower()
	if EXTENSION_KINDS.has(ext):
		return EXTENSION_KINDS[ext]
	return Kind.OTHER


## Active palette override, set from the theme picker. Empty means use the
## built-in KIND_COLORS above.
static var _palette_override := {}


static func set_palette(kind_colors: Dictionary) -> void:
	_palette_override = kind_colors


static func color_of(kind: Kind) -> Color:
	if not _palette_override.is_empty():
		var key: String = Kind.keys()[int(kind)]
		if _palette_override.has(key):
			return _palette_override[key]
	return KIND_COLORS.get(kind, KIND_COLORS[Kind.OTHER])


static func color_of_path(path: String) -> Color:
	return color_of(kind_of(path))


static func kind_label(kind: Kind) -> String:
	return Kind.keys()[kind].capitalize()


## res:// path of the exported PNG for a kind.
static func icon_path_for(kind: Kind) -> String:
	return "%s/%s.png" % [ICON_DIR, Kind.keys()[kind].to_lower()]


## Looks up an icon by name, and if the theme doesn't have it, walks up the
## class inheritance chain looking for an ancestor that does. This mirrors
## how the editor itself falls back (a custom Resource shows the Resource
## icon, and so on), and makes the export resilient to icons being renamed
## or removed between Godot versions.
## Adds a one-pixel dark outline around an icon's opaque pixels.
##
## Baked into the PNG rather than done with a shader because the marker is
## drawn as a plain Sprite3D; a shader would mean a second material and a
## second draw path for one badge. Grows the image by a pixel on each side so
## the outline is not clipped at the edge.
static func _outlined(source: Image) -> Image:
	var width := source.get_width()
	var height := source.get_height()
	source.convert(Image.FORMAT_RGBA8)

	var out := Image.create(width + 2, height + 2, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))

	# Pass one: stamp the outline wherever a neighbour is opaque.
	for y in height:
		for x in width:
			if source.get_pixel(x, y).a <= OUTLINE_ALPHA_THRESHOLD:
				continue
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var ox := x + 1 + dx
					var oy := y + 1 + dy
					if ox < 0 or oy < 0 or ox >= width + 2 or oy >= height + 2:
						continue
					out.set_pixel(ox, oy, OUTLINE_COLOR)

	# Pass two: lay the original over the top so only the fringe shows.
	for y2 in height:
		for x2 in width:
			var pixel := source.get_pixel(x2, y2)
			if pixel.a > OUTLINE_ALPHA_THRESHOLD:
				out.set_pixel(x2 + 1, y2 + 1, pixel)
	return out


static func _find_icon(theme: Theme, icon_name: String) -> Dictionary:
	if theme.has_icon(icon_name, "EditorIcons"):
		return {"texture": theme.get_icon(icon_name, "EditorIcons"), "name": icon_name}
	if not ClassDB.class_exists(icon_name):
		return {}
	var current := ClassDB.get_parent_class(icon_name)
	while current != "":
		if theme.has_icon(current, "EditorIcons"):
			return {"texture": theme.get_icon(current, "EditorIcons"), "name": current + " (inherited)"}
		current = ClassDB.get_parent_class(current)
	return {}


## Dumps Godot's own editor icons to PNG so the standalone viewer can use
## them. Editor-only: relies on the editor theme being available.
## Returns { "exported": [names], "missing": [names], "dir": String }.
static func export_icons() -> Dictionary:
	var exported: Array = []
	var missing: Array = []

	if not Engine.has_singleton("EditorInterface"):
		return {"exported": exported, "missing": missing, "dir": ICON_DIR,
				"error": "Editor icons can only be exported from inside the editor."}

	var editor = Engine.get_singleton("EditorInterface")
	var theme: Theme = editor.get_editor_theme()
	if theme == null:
		return {"exported": exported, "missing": missing, "dir": ICON_DIR,
				"error": "Could not access the editor theme."}

	if not DirAccess.dir_exists_absolute(ICON_DIR):
		DirAccess.make_dir_recursive_absolute(ICON_DIR)

	for kind_value in Kind.values():
		var kind: Kind = kind_value
		var candidates: Array = ICON_FALLBACKS.get(kind, [])
		var names: Array = [KIND_ICON_NAMES.get(kind, "File")]
		for c in candidates:
			if not names.has(c):
				names.append(c)

		var texture: Texture2D = null
		var used_name := ""
		for n in names:
			var icon_name: String = n
			var resolved: Dictionary = _find_icon(theme, icon_name)
			if not resolved.is_empty():
				texture = resolved["texture"]
				used_name = String(resolved["name"])
				break

		if texture == null:
			missing.append(kind_label(kind))
			continue

		var image := texture.get_image()
		if image == null:
			missing.append(kind_label(kind))
			continue
		# Icons are small (usually 16px); upscale so they stay crisp when the
		# camera flies close in the 3D view.
		image = image.duplicate()
		if image.get_width() < 64:
			image.resize(64, 64, Image.INTERPOLATE_LANCZOS)
		# Outlined like the markers: it costs nothing at runtime, since the
		# fringe is baked into the PNG here rather than drawn each frame, and
		# it keeps every icon legible against whatever is behind it.
		image = _outlined(image)
		var out_path := icon_path_for(kind)
		if image.save_png(out_path) == OK:
			exported.append("%s (%s)" % [kind_label(kind), used_name])
		else:
			missing.append(kind_label(kind))

	for special_key in SPECIAL_ICONS.keys():
		var key: String = special_key
		var special_texture: Texture2D = null
		var special_used := ""
		for candidate in SPECIAL_ICONS[key]:
			var resolved_special: Dictionary = _find_icon(theme, String(candidate))
			if not resolved_special.is_empty():
				special_texture = resolved_special["texture"]
				special_used = String(resolved_special["name"])
				break
		if special_texture == null:
			missing.append(key)
			continue
		var special_image := special_texture.get_image()
		if special_image == null:
			missing.append(key)
			continue
		special_image = special_image.duplicate()
		if special_image.get_width() < 64:
			special_image.resize(64, 64, Image.INTERPOLATE_LANCZOS)
		special_image = _outlined(special_image)
		if special_image.save_png(special_icon_path(key)) == OK:
			exported.append("%s (%s)" % [key, special_used])
		else:
			missing.append(key)

	return {"exported": exported, "missing": missing, "dir": ICON_DIR, "error": ""}
