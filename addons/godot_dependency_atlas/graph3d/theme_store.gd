@tool
extends RefCounted

## Human-readable persistence for custom palettes and per-theme overrides.

const OFConfig = preload("res://addons/godot_dependency_atlas/graph3d/of_config.gd")
const OFThemes = preload("res://addons/godot_dependency_atlas/graph3d/of_themes.gd")
const OVERRIDES_FILE := "overrides.json"


static func load_custom_themes(root: String) -> Array:
	OFThemes.clear_custom_themes()
	var problems: Array = []
	var folder := OFConfig.custom_themes_dir(root)
	if not DirAccess.dir_exists_absolute(folder):
		return problems
	var dir := DirAccess.open(folder)
	if dir == null:
		return ["Could not open custom theme folder: " + folder]
	for filename in dir.get_files():
		if not filename.ends_with(".json") or filename == OVERRIDES_FILE:
			continue
		var result := _read_json(folder.path_join(filename))
		if not bool(result.get("ok", false)):
			problems.append(String(result.get("error", "Invalid theme: " + filename)))
			continue
		var document: Dictionary = result["data"]
		var problem := register_document(document)
		if problem != "":
			problems.append("%s: %s" % [filename, problem])
	return problems


static func register_document(document: Dictionary) -> String:
	var scope := String(document.get("scope", ""))
	var theme_id := String(document.get("id", ""))
	var name := String(document.get("name", "")).strip_edges()
	var colors: Dictionary = document.get("colors", {})
	if scope != "nodes" and scope != "connections":
		return "scope must be \"nodes\" or \"connections\""
	if theme_id == "" or name == "" or colors.is_empty():
		return "id, name and colors are required"
	var definition := {"label": name}
	if scope == "nodes":
		definition["dark"] = bool(document.get("dark", true))
		definition["kinds"] = {}
		for key_any in colors:
			var key := String(key_any)
			var colour := Color.from_string(String(colors[key_any]), Color(0.7, 0.7, 0.7))
			if key.begins_with("kind_"):
				definition["kinds"][key.trim_prefix("kind_")] = colour
			elif key.begins_with("role_"):
				definition[key.trim_prefix("role_")] = colour
	else:
		for key_any in colors:
			var key := String(key_any)
			if key in OFThemes.CONNECTION_KEYS:
				definition[key] = Color.from_string(
					String(colors[key_any]), Color(0.7, 0.7, 0.7)
				)
	OFThemes.register_custom_theme(scope, theme_id, definition)
	return ""


static func save_custom(root: String, scope: String, name: String,
		colors: Dictionary, dark := true, requested_id := "") -> Dictionary:
	var problem := OFConfig.ensure_layout(root)
	if problem != "":
		return {"error": problem}
	var theme_id := requested_id if requested_id != "" else _unique_id(root, name)
	var document := {
		"format": 1,
		"scope": scope,
		"id": theme_id,
		"name": name.strip_edges(),
		"colors": _colors_to_strings(colors),
	}
	if scope == "nodes":
		document["dark"] = dark
	var path := _theme_path(root, theme_id)
	problem = _write_json(path, document)
	if problem != "":
		return {"error": problem}
	problem = register_document(document)
	return {"error": problem, "id": theme_id, "path": path}


static func rename_custom(root: String, theme_id: String, new_name: String) -> String:
	var path := _theme_path(root, theme_id)
	var result := _read_json(path)
	if not bool(result.get("ok", false)):
		return String(result.get("error", "Theme file not found"))
	var document: Dictionary = result["data"]
	document["name"] = new_name.strip_edges()
	var problem := _write_json(path, document)
	if problem == "":
		problem = register_document(document)
	return problem


static func update_custom(root: String, scope: String, theme_id: String,
		colors: Dictionary, dark := true) -> String:
	var path := _theme_path(root, theme_id)
	var result := _read_json(path)
	if not bool(result.get("ok", false)):
		return String(result.get("error", "Theme file not found"))
	var document: Dictionary = result["data"]
	if String(document.get("scope", "")) != scope:
		return "Theme scope does not match"
	document["colors"] = _colors_to_strings(colors)
	if scope == "nodes":
		document["dark"] = dark
	var problem := _write_json(path, document)
	if problem == "":
		problem = register_document(document)
	return problem


static func delete_custom(root: String, scope: String, theme_id: String) -> String:
	if not OFThemes.is_custom_theme(scope, theme_id):
		return "Built-in themes cannot be deleted"
	var path := _theme_path(root, theme_id)
	if not FileAccess.file_exists(path):
		return "Theme file not found: " + path
	var error := DirAccess.remove_absolute(path)
	if error != OK:
		return "Could not delete " + path
	if scope == "connections":
		OFThemes.CUSTOM_CONNECTION_THEMES.erase(theme_id)
	else:
		OFThemes.CUSTOM_THEMES.erase(theme_id)
	return ""


static func import_theme(root: String, source_path: String) -> Dictionary:
	var layout_problem := OFConfig.ensure_layout(root)
	if layout_problem != "":
		return {"error": layout_problem}
	var result := _read_json(source_path)
	if not bool(result.get("ok", false)):
		return {"error": result.get("error", "Could not import theme")}
	var document: Dictionary = result["data"]
	var name := String(document.get("name", source_path.get_file().get_basename()))
	document["id"] = _unique_id(root, name)
	var problem := register_document(document)
	if problem != "":
		return {"error": problem}
	var target := _theme_path(root, String(document["id"]))
	problem = _write_json(target, document)
	return {
		"error": problem, "id": String(document["id"]),
		"scope": String(document.get("scope", "")), "path": target,
	}


static func export_theme(path: String, scope: String, theme_id: String,
		name: String, colors: Dictionary, dark := true) -> String:
	var document := {
		"format": 1, "scope": scope, "id": theme_id, "name": name,
		"colors": _colors_to_strings(colors),
	}
	if scope == "nodes":
		document["dark"] = dark
	return _write_json(path, document)


static func save_overrides(root: String, overrides: Dictionary) -> String:
	var problem := OFConfig.ensure_layout(root)
	if problem != "":
		return problem
	return _write_json(
		OFConfig.custom_themes_dir(root).path_join(OVERRIDES_FILE),
		{"format": 1, "overrides": _colors_to_strings(overrides)}
	)


static func load_overrides(root: String) -> Dictionary:
	var path := OFConfig.custom_themes_dir(root).path_join(OVERRIDES_FILE)
	if not FileAccess.file_exists(path):
		return {}
	var result := _read_json(path)
	if not bool(result.get("ok", false)):
		return {}
	var raw: Dictionary = Dictionary(result["data"]).get("overrides", {})
	var parsed := {}
	for key in raw:
		parsed[String(key)] = Color.from_string(String(raw[key]), Color.WHITE)
	return parsed


static func _colors_to_strings(colors: Dictionary) -> Dictionary:
	var encoded := {}
	for key in colors:
		var value = colors[key]
		encoded[String(key)] = "#" + value.to_html(true) if value is Color else value
	return encoded


static func _unique_id(root: String, name: String) -> String:
	var base := name.to_lower()
	for character in [" ", "-", ".", "/", "\\", ":"]:
		base = base.replace(character, "_")
	while "__" in base:
		base = base.replace("__", "_")
	base = base.strip_edges().trim_prefix("_").trim_suffix("_")
	if base == "":
		base = "custom_theme"
	var candidate := "custom_" + base
	var suffix := 2
	while FileAccess.file_exists(_theme_path(root, candidate)):
		candidate = "custom_%s_%d" % [base, suffix]
		suffix += 1
	return candidate


static func _theme_path(root: String, theme_id: String) -> String:
	return OFConfig.custom_themes_dir(root).path_join(theme_id + ".json")


static func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "Could not read " + path}
	var parsed = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return {"ok": false, "error": "Expected a JSON object in " + path}
	return {"ok": true, "data": parsed}


static func _write_json(path: String, document: Dictionary) -> String:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Could not write " + path
	file.store_string(JSON.stringify(document, "\t") + "\n")
	return ""
