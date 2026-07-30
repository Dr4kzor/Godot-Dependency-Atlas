extends SceneTree

const RefactorEngineScript = preload("res://addons/godot_dependency_atlas/refactor/refactor_engine.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var stamp := str(Time.get_ticks_usec())
	var temp_dir := "res://tests/move_refactor_test_" + stamp
	var source := temp_dir.path_join("assets/source.tres")
	var destination := temp_dir.path_join("relocated/renamed.tres")
	var absolute_consumer := temp_dir.path_join("absolute_consumer.gd")
	var relative_consumer := temp_dir.path_join("scripts/relative_consumer.gd")
	var manifest := temp_dir.path_join("CMakeLists.txt")
	DirAccess.make_dir_recursive_absolute(source.get_base_dir())
	DirAccess.make_dir_recursive_absolute(relative_consumer.get_base_dir())
	_write(source, "[gd_resource type=\"Resource\" format=3]\n")
	_write(source + ".uid", "uid://move_refactor_test\n")
	_write(absolute_consumer, "const DATA = preload(\"%s\")\n" % source)
	_write(relative_consumer, "const DATA_PATH = \"../assets/source.tres\"\n")
	_write(manifest, "set(DATA_FILE \"%s\")\n" % source.trim_prefix("res://"))

	var preview: Dictionary = await RefactorEngineScript.preview_move_async(
		source, destination, false
	)
	_expect(preview.get("ok", false), "dry-run preview succeeds")
	_expect((preview.get("changes", []) as Array).size() >= 3, "dry run lists absolute and relative changes")

	var summary: Dictionary = await RefactorEngineScript.perform_moves_async([{
		"from": source,
		"to": destination,
		"is_dir": false,
	}])

	_expect((summary.get("failed", []) as Array).is_empty(), "move succeeds")
	_expect(not FileAccess.file_exists(source), "old file is gone")
	_expect(FileAccess.file_exists(destination), "new file exists")
	_expect(FileAccess.file_exists(destination + ".uid"), "UID sidecar follows the file")
	_expect(_read(absolute_consumer).contains(destination), "absolute project reference is rewritten")
	_expect(
		_read(relative_consumer).contains("../relocated/renamed.tres"),
		"file-relative reference is recalculated"
	)
	_expect(
		_read(manifest).contains(destination.trim_prefix("res://")),
		"project-relative build reference is rewritten"
	)

	# A unique bare header name is a valid include/build reference even when
	# include search paths make it unrelated to the referencing file's folder.
	var old_header := temp_dir.path_join("native/include/old_name.hpp")
	var new_header := temp_dir.path_join("native/include/new_name.hpp")
	var cpp_user := temp_dir.path_join("native/src/user.cpp")
	var vcxproj := temp_dir.path_join("native/native.vcxproj")
	DirAccess.make_dir_recursive_absolute(old_header.get_base_dir())
	DirAccess.make_dir_recursive_absolute(cpp_user.get_base_dir())
	_write(old_header, "#pragma once\n")
	_write(cpp_user, "#include \"old_name.hpp\"\n")
	_write(vcxproj, "<ClInclude Include=\"include\\old_name.hpp\" />\n")
	var native_summary: Dictionary = await RefactorEngineScript.perform_moves_async([{
		"from": old_header, "to": new_header, "is_dir": false,
	}])
	_expect((native_summary.get("failed", []) as Array).is_empty(), "native header move succeeds")
	_expect(_read(cpp_user).contains("\"new_name.hpp\""), "unique bare C/C++ include is rewritten")
	_expect(
		_read(vcxproj).contains("include\\new_name.hpp"),
		"Visual Studio backslash path is rewritten"
	)

	# C# project compile membership uses a path relative to the project file.
	var old_cs := temp_dir.path_join("managed/OldPlayer.cs")
	var new_cs := temp_dir.path_join("managed/NewPlayer.cs")
	var csproj := temp_dir.path_join("Game.csproj")
	DirAccess.make_dir_recursive_absolute(old_cs.get_base_dir())
	_write(old_cs, "class OldPlayer {}\n")
	_write(csproj, "<Compile Include=\"managed/OldPlayer.cs\" />\n")
	var cs_summary: Dictionary = await RefactorEngineScript.perform_moves_async([{
		"from": old_cs, "to": new_cs, "is_dir": false,
	}])
	_expect((cs_summary.get("failed", []) as Array).is_empty(), "C# source move succeeds")
	_expect(_read(csproj).contains("managed/NewPlayer.cs"), "C# project membership is rewritten")

	# GDExtension manifests normally use an absolute res:// library path.
	var old_library := temp_dir.path_join("native/bin/libold.so")
	var new_library := temp_dir.path_join("native/bin/libnew.so")
	var extension_manifest := temp_dir.path_join("native/demo.gdextension")
	DirAccess.make_dir_recursive_absolute(old_library.get_base_dir())
	_write(old_library, "test binary placeholder")
	_write(extension_manifest, "[libraries]\nlinux.debug = \"%s\"\n" % old_library)
	var library_summary: Dictionary = await RefactorEngineScript.perform_moves_async([{
		"from": old_library, "to": new_library, "is_dir": false,
	}])
	_expect((library_summary.get("failed", []) as Array).is_empty(), "native library move succeeds")
	_expect(_read(extension_manifest).contains(new_library), "GDExtension library path is rewritten")

	# Folder plans must rewrite references outside the folder while preserving
	# relative relationships between files that move together.
	var old_folder := temp_dir.path_join("subsystem")
	var new_folder := temp_dir.path_join("modules/subsystem")
	var internal_cpp := old_folder.path_join("src/internal.cpp")
	var internal_header := old_folder.path_join("include/api.hpp")
	var folder_manifest := temp_dir.path_join("meson.build")
	var folder_consumer := temp_dir.path_join("folder_consumer.gd")
	DirAccess.make_dir_recursive_absolute(internal_cpp.get_base_dir())
	DirAccess.make_dir_recursive_absolute(internal_header.get_base_dir())
	_write(internal_cpp, "#include \"../include/api.hpp\"\n")
	_write(internal_header, "#pragma once\n")
	_write(folder_manifest, "subdir('subsystem')\n")
	_write(folder_consumer, "const API = \"%s\"\n" % internal_header)
	var folder_summary: Dictionary = await RefactorEngineScript.perform_moves_async([{
		"from": old_folder, "to": new_folder, "is_dir": true,
	}])
	_expect((folder_summary.get("failed", []) as Array).is_empty(), "folder move succeeds")
	_expect(
		_read(new_folder.path_join("src/internal.cpp")).contains("../include/api.hpp"),
		"relative links inside a moved folder remain stable"
	)
	_expect(_read(folder_manifest).contains("modules/subsystem"), "build folder reference is rewritten")
	_expect(
		_read(folder_consumer).contains(new_folder.path_join("include/api.hpp")),
		"absolute path into a moved folder is rewritten"
	)

	_cleanup_file(destination)
	_cleanup_file(destination + ".uid")
	_cleanup_file(absolute_consumer)
	_cleanup_file(relative_consumer)
	_cleanup_file(manifest)
	_cleanup_file(new_header)
	_cleanup_file(cpp_user)
	_cleanup_file(vcxproj)
	_cleanup_file(new_cs)
	_cleanup_file(csproj)
	_cleanup_file(new_library)
	_cleanup_file(extension_manifest)
	_cleanup_file(new_folder.path_join("src/internal.cpp"))
	_cleanup_file(new_folder.path_join("include/api.hpp"))
	_cleanup_file(folder_manifest)
	_cleanup_file(folder_consumer)
	_cleanup_empty_dir(temp_dir.path_join("assets"))
	_cleanup_empty_dir(temp_dir.path_join("relocated"))
	_cleanup_empty_dir(temp_dir.path_join("scripts"))
	_cleanup_empty_dir(temp_dir.path_join("native/include"))
	_cleanup_empty_dir(temp_dir.path_join("native/src"))
	_cleanup_empty_dir(temp_dir.path_join("native/bin"))
	_cleanup_empty_dir(temp_dir.path_join("native"))
	_cleanup_empty_dir(temp_dir.path_join("managed"))
	_cleanup_empty_dir(new_folder.path_join("src"))
	_cleanup_empty_dir(new_folder.path_join("include"))
	_cleanup_empty_dir(new_folder)
	_cleanup_empty_dir(temp_dir.path_join("modules"))
	_cleanup_empty_dir(temp_dir)
	_cleanup_file(RefactorEngineScript._log_filename_for(source))
	_cleanup_file(RefactorEngineScript._log_filename_for(old_header))
	_cleanup_file(RefactorEngineScript._log_filename_for(old_cs))
	_cleanup_file(RefactorEngineScript._log_filename_for(old_library))
	_cleanup_file(RefactorEngineScript._log_filename_for(old_folder))

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


func _cleanup_empty_dir(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		DirAccess.remove_absolute(path)


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  PASS: " + label)
	else:
		_failures += 1
		push_error("  FAIL: " + label)
