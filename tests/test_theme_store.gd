extends SceneTree

const Store = preload("res://addons/orphan_finder/graph3d/theme_store.gd")
const Themes = preload("res://addons/orphan_finder/graph3d/of_themes.gd")

var failures := 0


func _initialize() -> void:
	var root := "user://orphan_finder_theme_store_test_%d" % Time.get_ticks_msec()
	var node_colors := {
		"kind_SCENE": Color("#123456"),
		"role_root": Color("#abcdef"),
		"role_orphan": Color("#ff3344"),
		"role_cycle": Color("#aa55dd"),
		"role_background": Color("#101820"),
	}
	var saved := Store.save_custom(root, "nodes", "Readable Test", node_colors, true)
	_expect(String(saved.get("error", "")) == "", "custom node theme was not saved")
	var node_id := String(saved.get("id", ""))
	_expect(Themes.is_custom_theme("nodes", node_id), "custom node theme was not registered")

	var renamed := Store.rename_custom(root, node_id, "Renamed Test")
	_expect(renamed == "", "custom theme was not renamed")
	_expect(Themes.label_of(node_id) == "Renamed Test", "renamed label was not refreshed")
	node_colors["kind_SCENE"] = Color("#654321")
	var updated := Store.update_custom(root, "nodes", node_id, node_colors, true)
	_expect(updated == "", "custom theme was not updated")
	_expect(
		Themes.kind_color(node_id, "SCENE").is_equal_approx(Color("#654321")),
		"updated custom colour was not registered"
	)

	var flat := {"nodes/godot_dark/kind_SCENE": Color("#102030")}
	_expect(Store.save_overrides(root, flat) == "", "override JSON was not saved")
	var loaded_overrides := Store.load_overrides(root)
	_expect(
		loaded_overrides.get("nodes/godot_dark/kind_SCENE", Color.BLACK).is_equal_approx(
			Color("#102030")
		),
		"override JSON did not round-trip"
	)

	Themes.clear_custom_themes()
	var problems := Store.load_custom_themes(root)
	_expect(problems.is_empty(), "saved custom theme did not reload")
	_expect(Themes.label_of(node_id) == "Renamed Test", "reloaded theme has the wrong name")
	_expect(Store.delete_custom(root, "nodes", node_id) == "", "custom theme was not deleted")
	_expect(not Themes.is_custom_theme("nodes", node_id), "deleted theme remained registered")

	if failures == 0:
		print("Theme store: all tests passed")
	quit(failures)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)
