@tool
extends RefCounted

## Per-key colour overrides layered on top of a theme.
##
## A theme is a starting point, not a cage: any individual colour can be
## replaced without abandoning the rest of the palette. Overrides are stored
## per theme, so switching themes and switching back restores whatever you had
## customised for each -- rather than one global set of tweaks bleeding across
## palettes it was never chosen for.
##
## Two scopes, matching the two theme pickers:
##   "nodes"        file-kind and node-role colours
##   "connections"  edges, analysis overlays and the trace pulse

const OFThemes = preload("res://addons/godot_dependency_atlas/graph3d/of_themes.gd")

## scope -> theme id -> key -> Color
var _overrides := {}


func clear() -> void:
	_overrides.clear()


func has_override(scope: String, theme_id: String, key: String) -> bool:
	return _overrides.get(scope, {}).get(theme_id, {}).has(key)


func get_override(scope: String, theme_id: String, key: String, fallback: Color) -> Color:
	var scoped: Dictionary = _overrides.get(scope, {})
	var themed: Dictionary = scoped.get(theme_id, {})
	if themed.has(key):
		return themed[key]
	return fallback


func set_override(scope: String, theme_id: String, key: String, colour: Color) -> void:
	if not _overrides.has(scope):
		_overrides[scope] = {}
	if not _overrides[scope].has(theme_id):
		_overrides[scope][theme_id] = {}
	_overrides[scope][theme_id][key] = colour


## Drops a single key, returning it to whatever the theme defines.
func clear_override(scope: String, theme_id: String, key: String) -> void:
	if _overrides.has(scope) and _overrides[scope].has(theme_id):
		_overrides[scope][theme_id].erase(key)


## Drops every override for one theme in one scope.
func clear_theme(scope: String, theme_id: String) -> void:
	if _overrides.has(scope):
		_overrides[scope].erase(theme_id)


func count_for(scope: String, theme_id: String) -> int:
	return (_overrides.get(scope, {}).get(theme_id, {}) as Dictionary).size()


## Flattened for ConfigFile: "scope/theme/key" -> Color. Nested dictionaries
## survive a round-trip through ConfigFile far less reliably than a flat map.
func to_flat() -> Dictionary:
	var flat := {}
	for scope in _overrides.keys():
		for theme_id in _overrides[scope].keys():
			for key in _overrides[scope][theme_id].keys():
				flat["%s/%s/%s" % [scope, theme_id, key]] = _overrides[scope][theme_id][key]
	return flat


func from_flat(flat: Dictionary) -> void:
	_overrides.clear()
	for compound in flat.keys():
		var parts := String(compound).split("/")
		if parts.size() != 3:
			continue
		var colour = flat[compound]
		if colour is Color:
			set_override(parts[0], parts[1], parts[2], colour)


# --- resolved lookups --------------------------------------------------------

func node_kind_color(theme_id: String, kind_name: String) -> Color:
	return get_override("nodes", theme_id, "kind_" + kind_name,
		OFThemes.kind_color(theme_id, kind_name))


func node_role_color(theme_id: String, role: String) -> Color:
	return get_override("nodes", theme_id, "role_" + role,
		OFThemes.role_color(theme_id, role))


func connection_color(theme_id: String, key: String) -> Color:
	return get_override("connections", theme_id, key,
		OFThemes.connection_color(theme_id, key))
