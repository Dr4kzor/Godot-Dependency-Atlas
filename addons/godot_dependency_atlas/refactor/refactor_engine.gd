@tool
class_name RefactorEngine
extends RefCounted

## Core logic: find text references to a path, move the file/folder, rewrite
## references in every affected file, and log what happened. No editor/UI
## code here beyond EditorInterface-free static calls, so it stays testable.
##
## Scanning is async (`find_references_async`) so it can yield control back
## to the editor between files instead of freezing the UI on large projects.
## Pass a Callable(done: int, total: int) as `progress` to get live updates.

const TEXT_EXTENSIONS := [
	"tscn", "tres", "gd", "gdshader", "gdshaderinc", "cfg", "import", "json",
	"cs", "gdextension", "godot", "c", "cc", "cpp", "cxx", "h", "hh", "hpp",
	"hxx", "csproj", "sln", "props", "targets", "vcxproj", "filters", "xml",
	"ini", "toml", "yml", "yaml", "scons",
]

const BUILD_FILENAMES := ["CMakeLists.txt", "SConstruct", "SConscript", "meson.build"]
const SKIP_DIRS := [
	".godot", ".git", ".import", "refactor_log", "dependency_atlas",
	"godot_dependency_atlas",
]
const SIDECAR_SUFFIXES := [".uid", ".import"]

## Where per-run change logs are written. Edit this to relocate them.
const LOG_DIR := "res://dependency_atlas/refactor_logs"

## Yield to the editor's main loop after this many files scanned, so the UI
## can repaint the progress bar. Lower = smoother progress, more overhead.
const YIELD_EVERY_N_FILES := 15


## Strips a single trailing slash, if present. Godot hands folder paths to
## context menus/dialogs with inconsistent trailing-slash presence, so raw
## from/to get normalized through this once, up front, rather than every
## call site needing to guess whether a slash is there.
static func _strip_trailing_slash(path: String) -> String:
	if path.ends_with("/"):
		return path.substr(0, path.length() - 1)
	return path


## For a directory, returns path with exactly one trailing slash, so
## "res://shaders" and "res://shaders_v2" can never be confused with each
## other as text (the trailing slash is the boundary). Files are returned
## unchanged: a file reference always ends in an extension, which is
## already an unambiguous boundary on its own.
static func _search_key(path: String, is_dir: bool) -> String:
	if not is_dir:
		return path
	return _strip_trailing_slash(path) + "/"


## Returns every project file (by extension) whose text contains target_path.
## progress, if valid, is called as progress.call(done, total) as it works.
static func find_references_async(target_path: String, is_dir: bool, progress: Callable = Callable()) -> PackedStringArray:
	var needle := _search_key(target_path, is_dir)

	var candidates: Array = []
	_collect_candidate_files("res://", candidates)

	var results: PackedStringArray = []
	var total := candidates.size()
	var main_loop := Engine.get_main_loop()

	for i in total:
		var f: String = candidates[i]
		if _file_contains(f, needle):
			results.append(f)
		if progress.is_valid():
			progress.call(i + 1, total)
		if main_loop is SceneTree and (i % YIELD_EVERY_N_FILES == 0):
			await (main_loop as SceneTree).process_frame

	if progress.is_valid():
		progress.call(total, total)

	return results


## moves: Array of { "from": String, "to": String, "is_dir": bool }
## Performs the move and rewrites references for each entry, logging each one.
## Returns { "moved": [...], "failed": [...], "updated_files": [{ "path", "line", "old_ref", "new_ref" }, ...] }
static func perform_moves_async(moves: Array, progress: Callable = Callable()) -> Dictionary:
	var summary := {"moved": [], "failed": [], "updated_files": []}
	for move in moves:
		var from: String = move["from"]
		var to: String = move["to"]
		var is_dir: bool = move.get("is_dir", false)
		var result: Dictionary = await _move_and_refactor_async(from, to, is_dir, progress)
		if result["ok"]:
			summary["moved"].append({
				"from": from,
				"to": to,
				"is_dir": is_dir,
				"search_from": result["search_from"],
				"search_to": result["search_to"],
				"affected_count": result["affected_count"],
			})
			summary["updated_files"].append_array(result["updated_files"])
		else:
			summary["failed"].append({"from": from, "to": to, "error": result["error"]})
	return summary


static func _move_and_refactor_async(from_raw: String, to_raw: String, is_dir: bool, progress: Callable) -> Dictionary:
	var from := _strip_trailing_slash(from_raw)
	var to := _strip_trailing_slash(to_raw)

	if not (
		FileAccess.file_exists(from)
		or ResourceLoader.exists(from)
		or DirAccess.dir_exists_absolute(from)
	):
		return {"ok": false, "error": "Source does not exist: %s" % from, "updated_files": [], "search_from": "", "search_to": "", "affected_count": 0}
	if FileAccess.file_exists(to) or DirAccess.dir_exists_absolute(to):
		return {"ok": false, "error": "Destination already exists: %s" % to, "updated_files": [], "search_from": "", "search_to": "", "affected_count": 0}

	var search_from := _search_key(from, is_dir)
	var search_to := _search_key(to, is_dir)

	# Validate/prepare the destination BEFORE touching any file content, so a
	# bad destination fails early instead of leaving text half-rewritten.
	var to_dir := to.get_base_dir()
	if to_dir != "" and not DirAccess.dir_exists_absolute(to_dir):
		var mk_err := DirAccess.make_dir_recursive_absolute(to_dir)
		if mk_err != OK:
			return {"ok": false, "error": "Could not create destination dir (%d)" % mk_err, "updated_files": [], "search_from": search_from, "search_to": search_to, "affected_count": 0}

	# Discover affected files before moving, but do not rewrite anything until
	# rename succeeds. The old implementation edited references first, so a
	# failed rename left the project pointing at a destination that did not
	# exist.
	var affected := await find_references_async(from, is_dir, progress)

	# Validate sidecar collisions before changing anything.
	if not is_dir:
		for suffix in SIDECAR_SUFFIXES:
			if FileAccess.file_exists(from + suffix) and FileAccess.file_exists(to + suffix):
				return {"ok": false, "error": "Destination sidecar already exists: %s" % (to + suffix), "updated_files": [], "search_from": search_from, "search_to": search_to, "affected_count": affected.size()}

	var updated_files: Array = []
	var dir := DirAccess.open("res://")
	if dir == null:
		return {"ok": false, "error": "Could not open res://", "updated_files": updated_files, "search_from": search_from, "search_to": search_to, "affected_count": affected.size()}

	var err := dir.rename(from, to)
	if err != OK:
		return {
			"ok": false,
			"error": "rename() failed (%d); no references were changed." % err,
			"updated_files": [],
			"search_from": search_from,
			"search_to": search_to,
			"affected_count": affected.size(),
		}

	if not is_dir:
		for suffix in SIDECAR_SUFFIXES:
			if FileAccess.file_exists(from + suffix):
				var sidecar_error := dir.rename(from + suffix, to + suffix)
				if sidecar_error != OK:
					push_warning("Move + Refactor: main file moved, but sidecar failed: " + from + suffix)

	# Rewrite only after the move is known to have succeeded. References
	# inside a moved directory now live under its destination path.
	for old_file_path in affected:
		var file_path := String(old_file_path)
		if is_dir and file_path.begins_with(from + "/"):
			file_path = to + file_path.substr(from.length())
		elif file_path == from:
			file_path = to
		if not FileAccess.file_exists(file_path):
			continue
		var lines := _replace_in_file(file_path, search_from, search_to)
		for line in lines:
			updated_files.append({"path": file_path, "line": line, "old_ref": from, "new_ref": to})

	_write_log(from, to, is_dir, search_from, search_to, affected, updated_files)

	return {
		"ok": true,
		"error": "",
		"updated_files": updated_files,
		"search_from": search_from,
		"search_to": search_to,
		"affected_count": affected.size(),
	}


static func _replace_in_file(path: String, old_text: String, new_text: String) -> PackedInt32Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedInt32Array()
	var content := f.get_as_text()
	f.close()

	var occurrence_lines := _find_occurrence_lines(content, old_text)
	if occurrence_lines.is_empty():
		return PackedInt32Array()

	var updated := content.replace(old_text, new_text)
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		push_error("Move + Refactor: could not write to %s" % path)
		return PackedInt32Array()
	out.store_string(updated)
	out.close()
	return occurrence_lines


## Returns the 1-based line numbers (in the ORIGINAL content) that contain needle.
static func _find_occurrence_lines(content: String, needle: String) -> PackedInt32Array:
	var result: PackedInt32Array = []
	var lines := content.split("\n")
	for i in lines.size():
		if lines[i].contains(needle):
			result.append(i + 1)
	return result


static func _collect_candidate_files(dir_path: String, results: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		if dir.current_is_dir():
			if not entry in SKIP_DIRS:
				_collect_candidate_files(dir_path.path_join(entry), results)
		else:
			var ext := entry.get_extension().to_lower()
			if ext in TEXT_EXTENSIONS or entry in BUILD_FILENAMES:
				results.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()


static func _file_contains(path: String, needle: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var content := f.get_as_text()
	f.close()
	return content.contains(needle)


## One log file per original source path, appended to on every run so a
## file's full move history lives in one place. Safe to commit to git.
static func _log_filename_for(source_path: String) -> String:
	var sanitized := source_path.trim_prefix("res://").replace("/", "__")
	if sanitized.is_empty():
		sanitized = "root"
	return "%s/%s.txt" % [LOG_DIR, sanitized]


static func _write_log(from: String, to: String, is_dir: bool, search_from: String, search_to: String, affected: PackedStringArray, updated_files: Array) -> void:
	if not DirAccess.dir_exists_absolute(LOG_DIR):
		DirAccess.make_dir_recursive_absolute(LOG_DIR)

	var log_path := _log_filename_for(from)
	var existing := ""
	if FileAccess.file_exists(log_path):
		var rf := FileAccess.open(log_path, FileAccess.READ)
		if rf:
			existing = rf.get_as_text()
			rf.close()

	var lines: PackedStringArray = []
	lines.append("================================================================")
	lines.append("Move + Refactor executed: %s" % Time.get_datetime_string_from_system())
	lines.append("FROM: %s" % from)
	lines.append("TO:   %s" % to)
	lines.append("is_dir: %s   search_from: %s   search_to: %s" % [is_dir, search_from, search_to])
	lines.append("Candidate files scanned that matched search_from: %d" % affected.size())
	lines.append("----------------------------------------------------------------")
	if updated_files.is_empty():
		lines.append("No other files referenced this path.")
	else:
		lines.append("Updated %d file(s):" % updated_files.size())
		for entry in updated_files:
			lines.append("  %s : line %d   (%s -> %s)" % [
				entry["path"], entry["line"], entry["old_ref"], entry["new_ref"]
			])
	lines.append("================================================================")
	lines.append("")

	var wf := FileAccess.open(log_path, FileAccess.WRITE)
	if wf == null:
		push_error("Move + Refactor: could not write log %s" % log_path)
		return
	wf.store_string(existing + "\n".join(lines) + "\n")
	wf.close()
