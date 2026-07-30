extends SceneTree

const Scanner = preload("res://addons/godot_dependency_atlas/orphan_scanner.gd")
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	Scanner.scan_root = ProjectSettings.globalize_path("res://tests/fixtures/multilang_project")
	Scanner.log_dir = Scanner.scan_root + "/dependency_atlas/logs"
	var result: Dictionary = await Scanner.scan_async()
	_expect(String(result.get("error", "")) == "", "mixed-language scan failed: " + String(result.get("error", "")))
	var roots: Array = result.get("roots", [])
	var root_paths := []
	for root_any in roots:
		root_paths.append(String((root_any as Dictionary).path))
	_expect("res://Game.csproj" in root_paths, "C# build root missing")
	_expect("res://native/demo.gdextension" in root_paths, "GDExtension descriptor root missing")
	_expect("res://native/CMakeLists.txt" in root_paths, "native build root missing")
	_expect(not "res://project.godot" in root_paths, "project settings leaked into entry roots")
	_expect("res://addons/audit-plugin/plugin.gd" in root_paths, "enabled plugin id was not resolved")
	var graph: Dictionary = result.get("graph", {})
	_expect(not graph.has("res://project.godot"), "project settings leaked into visual graph")
	_expect(not graph.has("res://icon.svg"), "configuration-only icon leaked into visual graph")
	_expect("res://addons/audit-plugin/panel.tscn" in graph.get("res://addons/audit-plugin/plugin.gd", []), "enabled plugin subtree was not traversed")
	_expect("res://addons/audit-plugin/icon.png" in graph.get("res://addons/audit-plugin/plugin.gd", []), "apostrophe in comment swallowed a relative preload")
	_expect(not graph.has("res://ignored/documentation.png"), ".gdignore directory was inventoried")
	_expect("res://managed/BaseActor.cs" in graph.get("res://managed/Player.cs", []), "C# type edge missing")
	_expect("res://native/base.hpp" in graph.get("res://native/child.cpp", []), "native include edge missing")
	_expect(
		"res://native/bin/libdemo.so" in graph.get("res://native/demo.gdextension", []),
		"GDExtension descriptor-to-library edge missing"
	)
	_expect(
		"res://native/child.cpp" in graph.get("res://native/bin/libdemo.so", []),
		"generated library-to-source edge missing"
	)
	_expect(
		"res://native/bin/libdemo.so" in graph.get("res://native/native_user.gd", []),
		"GDScript registered-class-to-library edge missing"
	)
	_expect(
		"res://native/bin/libdemo.so" in graph.get("res://managed/Player.cs", []),
		"C# DllImport-to-native-library edge missing"
	)
	var parents: Dictionary = result.get("hierarchy", {}).get("parent_of", {})
	_expect(parents.get("res://managed/Player.cs", "") == "res://managed/BaseActor.cs", "C# hierarchy missing")
	_expect(parents.get("res://native/child.cpp", "") == "res://native/base.hpp", "native hierarchy missing")
	var orphan_paths := []
	for orphan_any in result.get("orphans", []):
		orphan_paths.append(String((orphan_any as Dictionary).path))
	_expect(not "res://managed/BaseActor.cs" in orphan_paths, "SDK-implicit C# file reported orphan")
	_expect(not "res://managed/Player.cs" in orphan_paths, "build/runtime-reached C# file reported orphan")
	_expect(not "res://icon.svg" in orphan_paths, "project icon reported orphan")
	_expect(not "res://native/child.cpp" in orphan_paths, "build-reached native file reported orphan")
	_expect(not "res://native/bin/libdemo.so" in orphan_paths, "loaded native library reported orphan")
	if failures == 0:
		print("Mixed-language scanner: all tests passed")
	quit(failures)
