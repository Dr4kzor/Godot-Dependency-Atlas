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


## Backwards-compatible exact-reference query. New UI and move execution use
## preview_move_async(), which also understands relative reference forms.
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


## Builds a dry-run plan without changing the project.
##
## Returns:
## {
##   "ok": bool, "error": String,
##   "changes": [{ "path", "new_path", "line", "old_ref", "new_ref" }],
##   "affected_files": PackedStringArray,
##   "file_plans": [{ "old_path", "new_path", "pairs", "changes" }]
## }
##
## Reference forms include:
##   - res:// paths used by Godot resources and GDExtension manifests;
##   - project-relative paths used by build manifests;
##   - paths relative to the file containing the reference;
##   - unique bare filenames used by includes and compile item lists;
##   - slash and backslash variants for cross-platform build files.
static func preview_move_async(
	from_raw: String,
	to_raw: String,
	is_dir: bool,
	progress: Callable = Callable()
) -> Dictionary:
	var from := _strip_trailing_slash(from_raw)
	var to := _strip_trailing_slash(to_raw)
	var validation_error := _validate_move(from, to)
	if validation_error != "":
		return {
			"ok": false, "error": validation_error, "changes": [],
			"affected_files": PackedStringArray(), "file_plans": [],
		}

	var candidates: Array = []
	_collect_candidate_files("res://", candidates)
	var allow_bare_filename := not is_dir and _basename_is_unique(from, candidates)
	var changes: Array = []
	var affected_files := PackedStringArray()
	var file_plans: Array = []
	var total := candidates.size()
	var main_loop := Engine.get_main_loop()

	for i in total:
		var old_file_path := String(candidates[i])
		var new_file_path := _remap_moved_path(old_file_path, from, to, is_dir)
		var pairs := _replacement_pairs(
			old_file_path, new_file_path, from, to, is_dir, allow_bare_filename
		)
		var content := _read_text(old_file_path)
		var file_changes := _preview_pairs(
			content, old_file_path, new_file_path, pairs, is_dir
		)
		if not file_changes.is_empty():
			affected_files.append(old_file_path)
			changes.append_array(file_changes)
			file_plans.append({
				"old_path": old_file_path,
				"new_path": new_file_path,
				"pairs": pairs,
				"changes": file_changes,
			})
		if progress.is_valid():
			progress.call(i + 1, total)
		if main_loop is SceneTree and (i % YIELD_EVERY_N_FILES == 0):
			await (main_loop as SceneTree).process_frame

	if progress.is_valid():
		progress.call(total, total)
	return {
		"ok": true,
		"error": "",
		"changes": changes,
		"affected_files": affected_files,
		"file_plans": file_plans,
	}


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

	var search_from := _search_key(from, is_dir)
	var search_to := _search_key(to, is_dir)
	var validation_error := _validate_move(from, to)
	if validation_error != "":
		return {"ok": false, "error": validation_error, "updated_files": [], "search_from": search_from, "search_to": search_to, "affected_count": 0}

	# Validate/prepare the destination BEFORE touching any file content, so a
	# bad destination fails early instead of leaving text half-rewritten.
	var to_dir := to.get_base_dir()
	if to_dir != "" and not DirAccess.dir_exists_absolute(to_dir):
		var mk_err := DirAccess.make_dir_recursive_absolute(to_dir)
		if mk_err != OK:
			return {"ok": false, "error": "Could not create destination dir (%d)" % mk_err, "updated_files": [], "search_from": search_from, "search_to": search_to, "affected_count": 0}

	# Plan every byte-level change before moving, but apply nothing until the
	# rename succeeds. This is the same plan shown by the dialog's dry run.
	var preview := await preview_move_async(from, to, is_dir, progress)
	if not preview.get("ok", false):
		return {"ok": false, "error": preview.get("error", "Preview failed."), "updated_files": [], "search_from": search_from, "search_to": search_to, "affected_count": 0}
	var affected: PackedStringArray = preview["affected_files"]
	var file_plans: Array = preview["file_plans"]

	# Prove every planned reference file can be opened for writing before the
	# source path moves. This cannot prevent storage failures, but it catches
	# read-only files and permission problems while the project is untouched.
	for file_plan_any in file_plans:
		var planned_file := String((file_plan_any as Dictionary)["old_path"])
		var write_probe := FileAccess.open(planned_file, FileAccess.READ_WRITE)
		if write_probe == null:
			return {
				"ok": false,
				"error": "Referenced file is not writable; nothing was moved: %s" % planned_file,
				"updated_files": [],
				"search_from": search_from,
				"search_to": search_to,
				"affected_count": affected.size(),
			}
		write_probe.close()

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

	# Rewrite only after the move is known to have succeeded. Each plan already
	# knows the referencing file's post-move path, which is essential when the
	# file lives inside a folder that was moved.
	for file_plan_any in file_plans:
		var file_plan: Dictionary = file_plan_any
		var file_path := String(file_plan["new_path"])
		if not FileAccess.file_exists(file_path):
			continue
		var applied := _apply_file_plan(file_path, file_plan["pairs"], is_dir)
		updated_files.append_array(applied)

	_write_log(from, to, is_dir, search_from, search_to, affected, updated_files)

	return {
		"ok": true,
		"error": "",
		"updated_files": updated_files,
		"search_from": search_from,
		"search_to": search_to,
		"affected_count": affected.size(),
	}


static func _validate_move(from: String, to: String) -> String:
	if not from.begins_with("res://") or not to.begins_with("res://"):
		return "Move + Refactor only accepts paths inside the active res:// project."
	if from == "res://" or to == "res://":
		return "The project root cannot be moved or replaced."
	if from == to:
		return "Source and destination are the same."
	if not (
		FileAccess.file_exists(from)
		or ResourceLoader.exists(from)
		or DirAccess.dir_exists_absolute(from)
	):
		return "Source does not exist: %s" % from
	if FileAccess.file_exists(to) or DirAccess.dir_exists_absolute(to):
		return "Destination already exists: %s" % to
	if to.begins_with(from + "/"):
		return "A folder cannot be moved inside itself."
	return ""


static func _basename_is_unique(from: String, candidates: Array) -> bool:
	var basename := from.get_file()
	var count := 0
	for candidate_any in candidates:
		if String(candidate_any).get_file() == basename:
			count += 1
			if count > 1:
				return false
	return count == 1


static func _remap_moved_path(path: String, from: String, to: String, is_dir: bool) -> String:
	if path == from:
		return to
	if is_dir and path.begins_with(from + "/"):
		return to + path.substr(from.length())
	return path


static func _replacement_pairs(
	old_file_path: String,
	new_file_path: String,
	from: String,
	to: String,
	is_dir: bool,
	allow_bare_filename: bool
) -> Array:
	var pairs: Array = []
	_add_pair(pairs, from, to, "project")
	_add_pair(
		pairs,
		from.trim_prefix("res://"),
		to.trim_prefix("res://"),
		"project-relative"
	)

	var old_base := old_file_path.get_base_dir()
	var new_base := new_file_path.get_base_dir()
	_add_pair(
		pairs,
		_relative_path(old_base, from),
		_relative_path(new_base, to),
		"file-relative"
	)

	if allow_bare_filename and from.get_file() != to.get_file():
		_add_pair(pairs, from.get_file(), to.get_file(), "unique-filename")

	# Visual Studio and some cross-platform build files store Windows slashes.
	var originals := pairs.duplicate(true)
	for pair_any in originals:
		var pair: Dictionary = pair_any
		var old_ref := String(pair["old_ref"])
		var new_ref := String(pair["new_ref"])
		if not old_ref.begins_with("res://") and old_ref.contains("/"):
			_add_pair(
				pairs,
				old_ref.replace("/", "\\"),
				new_ref.replace("/", "\\"),
				String(pair["kind"]) + "-backslash"
			)

	# Longest first makes overlapping project and relative forms deterministic.
	pairs.sort_custom(func(a: Dictionary, b: Dictionary):
		return String(a["old_ref"]).length() > String(b["old_ref"]).length()
	)
	return pairs


static func _relative_path(base_dir: String, target: String) -> String:
	var base_parts := Array(base_dir.trim_prefix("res://").split("/", false))
	var target_parts := Array(target.trim_prefix("res://").split("/", false))
	var common := 0
	while (
		common < base_parts.size()
		and common < target_parts.size() - 1
		and base_parts[common] == target_parts[common]
	):
		common += 1
	var output: Array[String] = []
	for _index in range(common, base_parts.size()):
		output.append("..")
	for index in range(common, target_parts.size()):
		output.append(String(target_parts[index]))
	return "/".join(output)


static func _add_pair(pairs: Array, old_ref: String, new_ref: String, kind: String) -> void:
	old_ref = _strip_trailing_slash(old_ref)
	new_ref = _strip_trailing_slash(new_ref)
	if old_ref == "" or old_ref == "." or old_ref == new_ref:
		return
	for existing_any in pairs:
		var existing: Dictionary = existing_any
		if existing["old_ref"] == old_ref:
			return
	pairs.append({"old_ref": old_ref, "new_ref": new_ref, "kind": kind})


static func _preview_pairs(
	content: String,
	old_file_path: String,
	new_file_path: String,
	pairs: Array,
	is_dir: bool
) -> Array:
	var changes: Array = []
	for pair_any in pairs:
		var pair: Dictionary = pair_any
		var lines := _path_occurrence_lines(content, String(pair["old_ref"]), is_dir)
		for line in lines:
			changes.append({
				"path": old_file_path,
				"new_path": new_file_path,
				"line": line,
				"old_ref": pair["old_ref"],
				"new_ref": pair["new_ref"],
				"kind": pair["kind"],
			})
	return changes


static func _apply_file_plan(path: String, pairs: Array, is_dir: bool) -> Array:
	var content := _read_text(path)
	var original := content
	var changes: Array = []
	for pair_any in pairs:
		var pair: Dictionary = pair_any
		var old_ref := String(pair["old_ref"])
		var new_ref := String(pair["new_ref"])
		var result := _replace_path_occurrences(content, old_ref, new_ref, is_dir)
		content = result["content"]
		for line in result["lines"]:
			changes.append({
				"path": path,
				"line": line,
				"old_ref": old_ref,
				"new_ref": new_ref,
				"kind": pair["kind"],
			})
	if content == original:
		return changes
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		push_error("Move + Refactor: could not write to %s" % path)
		return []
	output.store_string(content)
	output.close()
	return changes


static func _replace_path_occurrences(
	content: String, old_ref: String, new_ref: String, is_dir: bool
) -> Dictionary:
	var indices := _path_occurrence_indices(content, old_ref, is_dir)
	var lines := PackedInt32Array()
	var offset := 0
	for original_index in indices:
		var index := int(original_index) + offset
		lines.append(_line_number_at(content, index))
		content = content.substr(0, index) + new_ref + content.substr(index + old_ref.length())
		offset += new_ref.length() - old_ref.length()
	return {"content": content, "lines": lines}


static func _path_occurrence_lines(content: String, old_ref: String, is_dir: bool) -> PackedInt32Array:
	var result := PackedInt32Array()
	for index in _path_occurrence_indices(content, old_ref, is_dir):
		var line := _line_number_at(content, int(index))
		if not line in result:
			result.append(line)
	return result


static func _path_occurrence_indices(content: String, old_ref: String, is_dir: bool) -> PackedInt32Array:
	var result := PackedInt32Array()
	if old_ref == "":
		return result
	var search_from := 0
	while search_from < content.length():
		var index := content.find(old_ref, search_from)
		if index < 0:
			break
		var before_ok := index == 0 or not _is_path_character(content[index - 1])
		var after_index := index + old_ref.length()
		var after_ok := after_index >= content.length()
		if not after_ok:
			var after := content[after_index]
			after_ok = not _is_path_character(after) or (is_dir and (after == "/" or after == "\\"))
		if before_ok and after_ok:
			result.append(index)
		search_from = index + maxi(1, old_ref.length())
	return result


static func _is_path_character(character: String) -> bool:
	return (
		character.to_lower() != character.to_upper()
		or character >= "0" and character <= "9"
		or character in ["_", ".", "/", "\\", ":", "-"]
	)


static func _line_number_at(content: String, index: int) -> int:
	return content.substr(0, index).count("\n") + 1


static func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content


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
