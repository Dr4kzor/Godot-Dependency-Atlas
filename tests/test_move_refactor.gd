extends SceneTree

const RefactorEngineScript = preload("res://addons/godot_dependency_atlas/refactor/refactor_engine.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var stamp := str(Time.get_ticks_usec())
	var temp_dir := "res://tests/move_refactor_test_" + stamp
	var source := temp_dir.path_join("source.tres")
	var destination := temp_dir.path_join("renamed.tres")
	var consumer := temp_dir.path_join("consumer.gd")
	DirAccess.make_dir_recursive_absolute(temp_dir)
	_write(source, "[gd_resource]\n")
	_write(source + ".uid", "uid://move_refactor_test\n")
	_write(consumer, "const DATA = preload(\"%s\")\n" % source)

	var summary: Dictionary = await RefactorEngineScript.perform_moves_async([{
		"from": source,
		"to": destination,
		"is_dir": false,
	}])

	_expect((summary.get("failed", []) as Array).is_empty(), "move succeeds")
	_expect(not FileAccess.file_exists(source), "old file is gone")
	_expect(FileAccess.file_exists(destination), "new file exists")
	_expect(FileAccess.file_exists(destination + ".uid"), "UID sidecar follows the file")
	_expect(_read(consumer).contains(destination), "absolute project reference is rewritten")

	_cleanup_file(destination)
	_cleanup_file(destination + ".uid")
	_cleanup_file(consumer)
	DirAccess.remove_absolute(temp_dir)
	_cleanup_file(RefactorEngineScript._log_filename_for(source))

	if _failures == 0:
		print("Move refactor tests: PASS")
		quit(0)
	else:
		push_error("Move refactor tests: %d failure(s)" % _failures)
		quit(1)


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_expect(false, "can create " + path)
		return
	file.store_string(content)
	file.close()


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


func _cleanup_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  PASS: " + label)
	else:
		_failures += 1
		push_error("  FAIL: " + label)
