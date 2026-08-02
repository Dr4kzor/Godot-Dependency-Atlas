extends SceneTree

const AiMap = preload("res://addons/godot_dependency_atlas/ai_map.gd")
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
	_expect(String(result.get("error", "")) == "", "AI map: scan failed")
	var text := AiMap.build(result, Scanner.scan_root)
	_expect(text.contains("# Dependency Atlas — AI map"), "AI map: missing title")
	_expect(text.contains("## Agent rules"), "AI map: missing agent rules")
	_expect(text.contains("## Entry points"), "AI map: missing entry points")
	_expect(text.contains("## Coupling hubs"), "AI map: missing hubs")
	_expect(text.contains("res://native/demo.gdextension"), "AI map: missing GDExtension descriptor")
	_expect(not text.contains("REFERENCE GRAPH"), "AI map: dumped full adjacency graph")
	# Must stay compact — a full graph dump for multilang is huge.
	_expect(text.length() < 12000, "AI map: too large for agent context (%d chars)" % text.length())
	var write_error := AiMap.write_from_scan(result, Scanner.scan_root)
	_expect(write_error == "", "AI map: write failed: " + write_error)
	var path := AiMap.map_path(Scanner.scan_root)
	_expect(FileAccess.file_exists(path), "AI map: file missing at " + path)
	if failures == 0:
		print("AI map: all tests passed (%d chars)" % text.length())
	quit(failures)
