@tool
extends RefCounted

## Persistent settings for the Dependency Atlas, stored inside the scanned
## project so filters and theme choice travel with it.
##
## Layout created inside the project being scanned:
##   dependency_atlas/
##       .gitignore              ignores the logs, keeps the config tracked
##       dependency-atlas.config    filters + display settings
##       deleted.log             audit trail of files moved to trash
##       logs/                   scan reports
##
## The config file and the whole folder are excluded from scanning, so the
## tool never reports its own bookkeeping as an orphan.

const DATA_DIR_NAME := "dependency_atlas"
const CONFIG_NAME := "dependency-atlas.config"
const LOG_DIR_NAME := "logs"
const CUSTOM_THEMES_DIR_NAME := "custom_themes"
const DEFAULT_IDLE_CONNECTION_ALPHA := 0.06
const DEFAULT_SELECTED_CONNECTION_ALPHA := 1.0
const DEFAULT_NODE_MIN_SEPARATION := 3.0
const DEFAULT_GROUP_MEMBER_MIN_SEPARATION := 4.0
const DEFAULT_GROUP_MIN_SEPARATION := 3.0
const DEFAULT_VERTICAL_LAYER_SEPARATION := 10.0

const GITIGNORE_BODY := """# Dependency Atlas
# Scan reports are machine-local and change on every run, so they are not
# tracked. The config file IS tracked deliberately: filter and theme choices
# are project decisions worth sharing across a team.
logs/
*.log

# deleted.log is tracked deliberately: it is the record of what this tool
# removed, which is exactly the kind of thing a team wants in history.
!deleted.log
"""


## Absolute-or-res:// path of the data folder for a given project root.
static func data_dir(root: String) -> String:
	return _join(root, DATA_DIR_NAME)


static func config_path(root: String) -> String:
	return _join(data_dir(root), CONFIG_NAME)


static func log_dir(root: String) -> String:
	return _join(data_dir(root), LOG_DIR_NAME)


static func custom_themes_dir(root: String) -> String:
	return _join(data_dir(root), CUSTOM_THEMES_DIR_NAME)


static func _join(base: String, leaf: String) -> String:
	if base.ends_with("/"):
		return base + leaf
	return base + "/" + leaf


## Creates the folder, the logs subfolder and the .gitignore if missing.
## Returns "" on success or an error message.
static func ensure_layout(root: String) -> String:
	var dir := data_dir(root)
	if not DirAccess.dir_exists_absolute(dir):
		if DirAccess.make_dir_recursive_absolute(dir) != OK:
			return "Could not create %s" % dir
	var logs := log_dir(root)
	if not DirAccess.dir_exists_absolute(logs):
		DirAccess.make_dir_recursive_absolute(logs)
	var themes := custom_themes_dir(root)
	if not DirAccess.dir_exists_absolute(themes):
		DirAccess.make_dir_recursive_absolute(themes)

	var ignore_path := _join(dir, ".gitignore")
	if not FileAccess.file_exists(ignore_path):
		var f := FileAccess.open(ignore_path, FileAccess.WRITE)
		if f == null:
			return "Could not write %s" % ignore_path
		f.store_string(GITIGNORE_BODY)
		f.close()
	return ""


static func default_settings() -> Dictionary:
	return {
		"hidden_kinds": [],
		"hidden_extensions": [],
		"custom_extensions": [],
		"view_hidden_kinds": [],
		"view_hidden_extensions": [],
		"pack_hidden_resources": false,
		"theme": "godot_dark",
		"connection_theme": "godot_dark",
		"idle_connection_alpha": DEFAULT_IDLE_CONNECTION_ALPHA,
		"selected_connection_alpha": DEFAULT_SELECTED_CONNECTION_ALPHA,
		"colour_overrides": {},
		"gather_relations": false,
		"show_embed_links": true,
		"show_group_reasoning": true,
		"node_min_separation": DEFAULT_NODE_MIN_SEPARATION,
		"group_member_min_separation": DEFAULT_GROUP_MEMBER_MIN_SEPARATION,
		"group_min_separation": DEFAULT_GROUP_MIN_SEPARATION,
		"vertical_layer_separation": DEFAULT_VERTICAL_LAYER_SEPARATION,
	}


static func load_settings(root: String) -> Dictionary:
	var settings := default_settings()
	var path := config_path(root)
	if not FileAccess.file_exists(path):
		return settings

	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		push_warning("Dependency Atlas: could not read %s, using defaults." % path)
		return settings

	settings["hidden_kinds"] = Array(cfg.get_value("filters", "hidden_kinds", []))
	settings["hidden_extensions"] = Array(cfg.get_value("filters", "hidden_extensions", []))
	settings["custom_extensions"] = Array(cfg.get_value("filters", "custom_extensions", []))
	settings["view_hidden_kinds"] = Array(cfg.get_value("visibility", "hidden_kinds", []))
	settings["view_hidden_extensions"] = Array(cfg.get_value("visibility", "hidden_extensions", []))
	settings["pack_hidden_resources"] = bool(cfg.get_value("visibility", "pack_hidden_resources", false))
	settings["theme"] = String(cfg.get_value("display", "theme", "godot_dark"))
	settings["connection_theme"] = String(cfg.get_value("display", "connection_theme", "godot_dark"))
	settings["idle_connection_alpha"] = clampf(float(cfg.get_value(
		"display", "idle_connection_alpha", DEFAULT_IDLE_CONNECTION_ALPHA
	)), 0.0, 1.0)
	settings["selected_connection_alpha"] = clampf(float(cfg.get_value(
		"display", "selected_connection_alpha", DEFAULT_SELECTED_CONNECTION_ALPHA
	)), 0.0, 1.0)
	# Stored flat ("scope/theme/key" -> Color) because nested dictionaries do
	# not survive a ConfigFile round-trip reliably.
	settings["colour_overrides"] = Dictionary(cfg.get_value("display", "colour_overrides", {}))
	settings["gather_relations"] = bool(cfg.get_value("display", "gather_relations", false))
	settings["show_embed_links"] = bool(cfg.get_value("display", "show_embed_links", true))
	settings["show_group_reasoning"] = bool(cfg.get_value(
		"display", "show_group_reasoning", true
	))
	settings["node_min_separation"] = float(cfg.get_value(
		"layout", "node_min_separation", DEFAULT_NODE_MIN_SEPARATION
	))
	settings["group_member_min_separation"] = float(cfg.get_value(
		"layout", "group_member_min_separation", DEFAULT_GROUP_MEMBER_MIN_SEPARATION
	))
	settings["group_min_separation"] = float(cfg.get_value(
		"layout", "group_min_separation", DEFAULT_GROUP_MIN_SEPARATION
	))
	settings["vertical_layer_separation"] = float(cfg.get_value(
		"layout", "vertical_layer_separation", DEFAULT_VERTICAL_LAYER_SEPARATION
	))
	return settings


static func save_settings(root: String, settings: Dictionary) -> String:
	var problem := ensure_layout(root)
	if problem != "":
		return problem

	var cfg := ConfigFile.new()
	cfg.set_value("filters", "hidden_kinds", settings.get("hidden_kinds", []))
	cfg.set_value("filters", "hidden_extensions", settings.get("hidden_extensions", []))
	cfg.set_value("filters", "custom_extensions", settings.get("custom_extensions", []))
	cfg.set_value("visibility", "hidden_kinds", settings.get("view_hidden_kinds", []))
	cfg.set_value("visibility", "hidden_extensions", settings.get("view_hidden_extensions", []))
	cfg.set_value("visibility", "pack_hidden_resources", settings.get("pack_hidden_resources", false))
	cfg.set_value("display", "theme", settings.get("theme", "godot_dark"))
	cfg.set_value("display", "connection_theme", settings.get("connection_theme", "godot_dark"))
	cfg.set_value("display", "idle_connection_alpha", settings.get(
		"idle_connection_alpha", DEFAULT_IDLE_CONNECTION_ALPHA
	))
	cfg.set_value("display", "selected_connection_alpha", settings.get(
		"selected_connection_alpha", DEFAULT_SELECTED_CONNECTION_ALPHA
	))
	cfg.set_value("display", "colour_overrides", settings.get("colour_overrides", {}))
	cfg.set_value("display", "gather_relations", settings.get("gather_relations", false))
	cfg.set_value("display", "show_embed_links", settings.get("show_embed_links", true))
	cfg.set_value("display", "show_group_reasoning", settings.get(
		"show_group_reasoning", true
	))
	cfg.set_value("layout", "node_min_separation", settings.get(
		"node_min_separation", DEFAULT_NODE_MIN_SEPARATION
	))
	cfg.set_value("layout", "group_member_min_separation", settings.get(
		"group_member_min_separation", DEFAULT_GROUP_MEMBER_MIN_SEPARATION
	))
	cfg.set_value("layout", "group_min_separation", settings.get(
		"group_min_separation", DEFAULT_GROUP_MIN_SEPARATION
	))
	cfg.set_value("layout", "vertical_layer_separation", settings.get(
		"vertical_layer_separation", DEFAULT_VERTICAL_LAYER_SEPARATION
	))

	var path := config_path(root)
	if cfg.save(path) != OK:
		return "Could not write %s" % path
	return ""
