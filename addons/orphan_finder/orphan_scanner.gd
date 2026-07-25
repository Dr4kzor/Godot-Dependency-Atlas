@tool
class_name OrphanScanner
extends RefCounted

## Finds unreachable ("orphan") files by TRAVERSAL, not by keyword search.
##
## The approach, in order:
##   1. INVENTORY  -- build a complete list of every file in the project.
##   2. INDEX      -- read contents, build uid -> path and class_name -> path maps.
##   3. TRAVERSE   -- start from the real entry points (main scene, autoloads,
##                    enabled editor plugins) and follow every reference
##                    outward, marking files reachable until nothing new is
##                    found.
##   4. REPORT     -- anything in the inventory that traversal never reached
##                    is an orphan candidate.
##
## Why traversal instead of "is this file mentioned anywhere?": a dead
## subsystem whose files all reference EACH OTHER looks fully "used" to a
## mention-based search, even though the running game can never get to it.
## Traversal only marks something reachable if there's an actual chain from
## a real entry point, so those dead clusters get correctly reported.
##
## This is a REPORTING tool only: it never moves or deletes anything.
## It is deliberately biased toward calling things REACHABLE when unsure --
## a missed orphan just means you clean up less, while a false orphan could
## mean deleting a file the game needs. It cannot see references built at
## runtime, e.g. load("res://levels/%s.tscn" % level_name), so directories
## referenced as paths are conservatively treated as fully live (see
## "dynamic directory" handling below).

## Directories never descended into during inventory.
const SKIP_DIRS := [".godot", ".git", ".import", "refactor_log", "orphan_scan_log"]

## Where scan reports are written.
const LOG_DIR := "res://orphan_scan_log"

## Files whose contents are read looking for outgoing references.
## "uid" matters more than it looks: Godot can reference an attached script
## from a .tscn by UID alone, with no path= field. Resolving that requires
## the uid -> path map, which is built from these .uid sidecar files. Leave
## it out and every UID-only reference silently fails to resolve.
const READABLE_EXTENSIONS := [
	"tscn", "tres", "scn", "res", "gd", "cs", "gdshader", "gdshaderinc",
	"cfg", "godot", "json", "gdextension", "import", "uid",
]

## Sidecar files owned by another file -- never reported on their own, and
## automatically considered reachable whenever their owner is.
const SIDECAR_SUFFIXES := [".import", ".uid"]

## Files that exist for reasons outside the scene graph, so being
## "unreachable" says nothing useful about them. Matched on filename.
const ALWAYS_KEEP_FILENAMES := [
	"project.godot", "export_presets.cfg", "plugin.cfg",
	".gitignore", ".gitattributes",
]

## Extensions never reported as orphans (docs, licences, notes).
const ALWAYS_KEEP_EXTENSIONS := ["md", "txt", "gitignore", "gitattributes"]

## Yield to the editor between units of work so the UI stays responsive.
const YIELD_EVERY_N := 20

## Binary files above this are read only up to this many bytes. Godot binary
## formats put their resource/uid table near the front, so references are
## almost always well within this, but see the log note if any file hits it.
const MAX_BINARY_READ_BYTES := 8 * 1024 * 1024

## Null bytes are neutralised in chunks this size, yielding between chunks,
## so a large binary file can't freeze the editor.
const NULL_SCRUB_CHUNK := 262144

const PATH_CONTINUATION_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"
const WORD_CONTINUATION_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"


## Returns:
## {
##   "orphans":       [{ "path", "size" }, ...],
##   "roots":         [{ "path", "kind" }, ...],
##   "dynamic_dirs":  [{ "dir", "referenced_in", "file_count" }, ...],
##   "reachable_count": int,
##   "total_files":     int,
##   "truncated_files": [String, ...],
##   "error":           String,      -- non-empty if the scan aborted
## }
## progress.call(phase: String, done: int, total: int); total is -1 when unknown.
static func scan_async(progress: Callable = Callable()) -> Dictionary:
	var main_loop := Engine.get_main_loop()

	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()

	# ---------- 1. INVENTORY ----------
	if progress.is_valid():
		progress.call("inventory", 0, -1)
	var all_files: Array = []
	await _collect_files_async("res://", all_files, progress, main_loop)
	all_files.sort()

	var file_set := {}
	for i in all_files.size():
		var fp: String = all_files[i]
		file_set[fp] = true

	var dir_set := {}
	for i in all_files.size():
		var fp2: String = all_files[i]
		var d: String = fp2.get_base_dir()
		while d.length() > 6 and not dir_set.has(d):  # 6 == len("res://")
			dir_set[d] = true
			d = d.get_base_dir()

	# ---------- 2. INDEX ----------
	var readable: Array = []
	for i in all_files.size():
		var fp3: String = all_files[i]
		if fp3.get_extension().to_lower() in READABLE_EXTENSIONS:
			readable.append(fp3)

	if progress.is_valid():
		progress.call("reading", 0, readable.size())

	var content_cache := {}
	var truncated: Array = []
	for i in readable.size():
		var p: String = readable[i]
		var read_result: Dictionary = await _read_file_async(p, main_loop)
		content_cache[p] = read_result["text"]
		if read_result["truncated"]:
			truncated.append(p)
		if progress.is_valid():
			progress.call("reading", i + 1, readable.size())
		if main_loop is SceneTree and (i % YIELD_EVERY_N == 0):
			await (main_loop as SceneTree).process_frame

	if progress.is_valid():
		progress.call("indexing", 0, all_files.size())

	# uid -> path, from companion .uid files and embedded uid="..." headers.
	var uid_to_path := {}
	# class_name -> path, for GDScript/C# global classes.
	var class_to_path := {}
	for i in all_files.size():
		var p2: String = all_files[i]
		var own_uid := _own_uid_of(p2, content_cache)
		if own_uid != "":
			uid_to_path[own_uid] = p2
		# Any [ext_resource] line carrying both a uid and a path teaches us a
		# pairing that another file may only reference by uid.
		var body := String(content_cache.get(p2, ""))
		if body != "":
			_harvest_ext_resource_pairs(body, uid_to_path)
		var ext2: String = p2.get_extension().to_lower()
		if ext2 == "gd" or ext2 == "cs":
			var cls := _extract_class_name(body)
			if cls != "":
				class_to_path[cls] = p2
		if progress.is_valid():
			progress.call("indexing", i + 1, all_files.size())
		if main_loop is SceneTree and (i % YIELD_EVERY_N == 0):
			await (main_loop as SceneTree).process_frame

	# ---------- 3. TRAVERSE ----------
	# Walk outward from the entry points. For each file: parse it completely,
	# record every outgoing reference found into the graph, mark it seen ONLY
	# once parsing is finished, then queue anything not already seen. The
	# graph is kept (not just a reachable set) because it's the thing that
	# explains a result -- if a file is wrongly reported as an orphan, the
	# graph shows exactly which parent failed to mention it.
	var roots := _find_roots(content_cache, file_set)
	if roots.is_empty():
		return {
			"orphans": [], "roots": [], "dynamic_dirs": [], "graph": {}, "unresolved_refs": [],
			"reachable_count": 0, "total_files": all_files.size(),
			"truncated_files": truncated,
			"error": "No entry points found. Expected a main scene (run/main_scene) in project.godot. Without a starting point, reachability can't be determined and every file would look like an orphan -- refusing to report a misleading result.",
		}

	var graph := {}      # file -> Array[String] of references found inside it
	var seen := {}       # file -> true, set only AFTER the file is fully parsed
	var dynamic_dirs: Array = []
	var unresolved_refs: Array = []
	var queue: Array = []
	for r in roots:
		var rd: Dictionary = r
		queue.append(String(rd["path"]))

	var processed := 0
	while not queue.is_empty():
		var current: String = queue.pop_front()
		if seen.has(current):
			continue
		if not file_set.has(current):
			continue

		# --- parse this file completely, collecting its outgoing references ---
		var found: Array = []

		# Sidecars belong to their owner: if the owner is live, so are they.
		for suffix in SIDECAR_SUFFIXES:
			var sidecar :String = current + suffix
			if file_set.has(sidecar) and not found.has(sidecar):
				found.append(sidecar)

		# An .import file implies its source asset is in use.
		if current.get_extension().to_lower() == "import":
			var source := current.substr(0, current.length() - ".import".length())
			if file_set.has(source) and not found.has(source):
				found.append(source)

		var content := String(content_cache.get(current, ""))
		if content != "":
			var outgoing := _extract_references(content, file_set, dir_set, uid_to_path, class_to_path)
			for ref in outgoing["files"]:
				var ref_path: String = ref
				if ref_path != current and not found.has(ref_path):
					found.append(ref_path)
			for ur in outgoing["unresolved"]:
				unresolved_refs.append({"in_file": current, "reference": String(ur)})
			for dref in outgoing["dirs"]:
				var dir_path: String = dref
				var count := 0
				for i in all_files.size():
					var candidate: String = all_files[i]
					if candidate.begins_with(dir_path + "/"):
						count += 1
						if not found.has(candidate):
							found.append(candidate)
				dynamic_dirs.append({
					"dir": dir_path, "referenced_in": current, "file_count": count,
				})

		# --- parsing done: only now record it and mark it seen ---
		found.sort()
		graph[current] = found
		seen[current] = true
		processed += 1

		# --- queue anything we haven't already parsed ---
		for ref2 in found:
			var next_path: String = ref2
			if not seen.has(next_path):
				queue.append(next_path)

		if progress.is_valid():
			progress.call("traversing", processed, -1)
		if main_loop is SceneTree and (processed % YIELD_EVERY_N == 0):
			await (main_loop as SceneTree).process_frame

	# ---------- 4. REPORT ----------
	var orphans: Array = []
	for i in all_files.size():
		var p4: String = all_files[i]
		if seen.has(p4):
			continue
		if _is_always_kept(p4):
			continue
		if _is_sidecar(p4):
			continue
		orphans.append({"path": p4, "size": _file_size(p4)})

	_write_log(orphans, roots, dynamic_dirs, graph, unresolved_refs, seen.size(), all_files.size(), truncated)

	return {
		"orphans": orphans,
		"roots": roots,
		"dynamic_dirs": dynamic_dirs,
		"graph": graph,
		"unresolved_refs": unresolved_refs,
		"reachable_count": seen.size(),
		"total_files": all_files.size(),
		"truncated_files": truncated,
		"error": "",
	}


# ---------------------------------------------------------------- entry points

## Entry points the running project actually starts from: the main scene,
## every autoload, and every enabled editor plugin. Everything reachable is
## reachable from one of these.
static func _find_roots(content_cache: Dictionary, file_set: Dictionary) -> Array:
	var roots: Array = []
	var seen := {}
	var project_cfg := String(content_cache.get("res://project.godot", ""))
	if project_cfg == "":
		return roots

	var main_scene := _cfg_value(project_cfg, "run/main_scene")
	if main_scene != "" and file_set.has(main_scene) and not seen.has(main_scene):
		seen[main_scene] = true
		roots.append({"path": main_scene, "kind": "main scene"})

	for entry in _cfg_section_values(project_cfg, "autoload"):
		var raw: String = entry
		# Autoload values look like "*res://path.gd" -- the * means enabled.
		var cleaned := raw.trim_prefix("*")
		if file_set.has(cleaned) and not seen.has(cleaned):
			seen[cleaned] = true
			roots.append({"path": cleaned, "kind": "autoload"})

	# Enabled editor plugins run in-editor; their plugin.gd is an entry point.
	for cfg_path in _enabled_plugin_cfgs(project_cfg, file_set):
		var cfg_str: String = cfg_path
		var cfg_content := String(content_cache.get(cfg_str, ""))
		var script_rel := _cfg_value(cfg_content, "script")
		if script_rel == "":
			continue
		var script_abs := cfg_str.get_base_dir().path_join(script_rel)
		if file_set.has(script_abs) and not seen.has(script_abs):
			seen[script_abs] = true
			roots.append({"path": script_abs, "kind": "editor plugin"})

	return roots


static func _enabled_plugin_cfgs(project_cfg: String, file_set: Dictionary) -> Array:
	var result: Array = []
	var idx := project_cfg.find("[editor_plugins]")
	if idx == -1:
		return result
	var section := project_cfg.substr(idx)
	var next_section := section.find("\n[", 1)
	if next_section != -1:
		section = section.substr(0, next_section)
	for token in _extract_res_tokens(section):
		var t: String = token
		var resolved := _longest_known_prefix(t, file_set)
		if resolved != "" and resolved.get_file() == "plugin.cfg":
			result.append(resolved)
	return result


## Reads `key="value"` or `key=value` from an INI-style config body.
static func _cfg_value(content: String, key: String) -> String:
	var idx := content.find(key + "=")
	while idx != -1:
		var at_line_start := idx == 0 or content[idx - 1] == "\n" or content[idx - 1] == "\r"
		if at_line_start:
			var start := idx + key.length() + 1
			var end := start
			while end < content.length() and content[end] != "\n" and content[end] != "\r":
				end += 1
			return content.substr(start, end - start).strip_edges().trim_prefix("\"").trim_suffix("\"")
		idx = content.find(key + "=", idx + 1)
	return ""


## Returns every value from an INI section, e.g. all autoload entries.
static func _cfg_section_values(content: String, section_name: String) -> Array:
	var values: Array = []
	var header := "[" + section_name + "]"
	var idx := content.find(header)
	if idx == -1:
		return values
	var body := content.substr(idx + header.length())
	var next_section := body.find("\n[")
	if next_section != -1:
		body = body.substr(0, next_section)
	for line in body.split("\n"):
		var l: String = String(line).strip_edges()
		if l == "" or l.begins_with(";") or l.begins_with("#"):
			continue
		var eq := l.find("=")
		if eq == -1:
			continue
		values.append(l.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\""))
	return values


# ---------------------------------------------------------------- references

## Pulls every outgoing reference out of one file's content.
## Returns { "files": Array, "dirs": Array, "unresolved": Array }.
## Unresolved references are reported rather than silently dropped -- a
## reference we can see but can't resolve is the most likely reason a file
## gets wrongly reported as an orphan, so it needs to be visible.
static func _extract_references(
	content: String, file_set: Dictionary, dir_set: Dictionary,
	uid_to_path: Dictionary, class_to_path: Dictionary
) -> Dictionary:
	var files := {}
	var dirs := {}
	var unresolved := {}

	# res:// path literals -- covers instanced scenes, preloads, ext_resource
	# path= fields, and anything else written as an explicit path.
	for token in _extract_res_tokens(content):
		var t: String = token
		var resolved := _longest_known_prefix(t, file_set)
		if resolved != "":
			files[resolved] = true
			continue
		var dir_resolved := _longest_known_prefix(t, dir_set)
		if dir_resolved != "":
			dirs[dir_resolved] = true
		else:
			unresolved[t] = true

	# uid:// references -- covers scenes/scripts referenced by UID alone.
	for token in _extract_uid_tokens(content):
		var u: String = token
		var target := _resolve_uid(u, uid_to_path)
		if target != "" and file_set.has(target):
			files[target] = true
		else:
			unresolved[u] = true

	# Global class_name usage, e.g. `Item.new()` or `extends Item`.
	for key in class_to_path.keys():
		var cls: String = key
		var target2: String = class_to_path[cls]
		if files.has(target2):
			continue
		if _word_contains(content, cls):
			files[target2] = true

	return {"files": files.keys(), "dirs": dirs.keys(), "unresolved": unresolved.keys()}


static func _extract_res_tokens(content: String) -> Array:
	return _extract_prefixed_tokens(content, "res://")


static func _extract_uid_tokens(content: String) -> Array:
	return _extract_prefixed_tokens(content, "uid://")


## Grabs each occurrence of `prefix` plus the run of characters after it,
## stopping at anything that clearly ends a path (quote, bracket, comma,
## control byte). Binary files often leave junk glued to the end, which
## _longest_known_prefix trims off afterwards.
static func _extract_prefixed_tokens(content: String, prefix: String) -> Array:
	var tokens: Array = []
	var idx := content.find(prefix)
	while idx != -1:
		var end := idx
		while end < content.length():
			var c := content[end]
			var code := c.unicode_at(0)
			if code < 32 or c == "\"" or c == "'" or c == ")" or c == "(" or c == "," or c == "]" or c == "[" or c == "<" or c == ">" or c == "|" or c == "*":
				break
			end += 1
		var token := content.substr(idx, end - idx)
		if token.length() > prefix.length():
			tokens.append(token)
		idx = content.find(prefix, idx + prefix.length())
	return tokens


## Trims characters off the end of `token` until it matches a known entry.
## This is what makes binary scanning safe: a path pulled out of a .scn is
## usually followed by raw bytes, and trimming finds the real path inside.
static func _longest_known_prefix(token: String, known: Dictionary) -> String:
	var candidate := token
	while candidate.length() > 6:  # 6 == len("res://")
		if known.has(candidate):
			return candidate
		candidate = candidate.substr(0, candidate.length() - 1)
	return ""


## Resolves a "uid://..." string to a res:// path.
##
## Godot maintains an authoritative UID database via the ResourceUID
## singleton, so that is asked first: it knows about every resource
## regardless of format, including binary .scn/.res scenes whose UID is not
## parseable as text. The locally-scanned map is only a fallback for
## anything the database hasn't registered.
static func _resolve_uid(uid_text: String, uid_to_path: Dictionary) -> String:
	var id := ResourceUID.text_to_id(uid_text)
	if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
		var p := ResourceUID.get_id_path(id)
		if p != "":
			return p
	if uid_to_path.has(uid_text):
		return String(uid_to_path[uid_text])
	return ""


## Harvests uid <-> path pairs from [ext_resource] lines. A scene that
## references something by UID alone may be referenced WITH its path
## elsewhere in the project, so collecting every pair seen anywhere makes
## the map far more complete than each file's own header alone.
static func _harvest_ext_resource_pairs(content: String, uid_to_path: Dictionary) -> void:
	var idx := content.find("[ext_resource")
	while idx != -1:
		var end := content.find("]", idx)
		if end == -1:
			break
		var line := content.substr(idx, end - idx)
		var uid_val := _quoted_attr(line, "uid")
		var path_val := _quoted_attr(line, "path")
		if uid_val != "" and path_val != "" and not uid_to_path.has(uid_val):
			uid_to_path[uid_val] = path_val
		idx = content.find("[ext_resource", end)


## Reads `attr="value"` out of a single resource line.
static func _quoted_attr(line: String, attr: String) -> String:
	var marker := attr + "=\""
	var idx := line.find(marker)
	if idx == -1:
		return ""
	var start := idx + marker.length()
	var end := line.find("\"", start)
	if end == -1:
		return ""
	return line.substr(start, end - start)


static func _own_uid_of(path: String, content_cache: Dictionary) -> String:
	var uid_sidecar := path + ".uid"
	if content_cache.has(uid_sidecar):
		var side := String(content_cache[uid_sidecar]).strip_edges()
		if side.begins_with("uid://"):
			return side
	var content := String(content_cache.get(path, ""))
	if content == "":
		return ""
	# A .tscn/.tres header carries its own uid: [gd_scene ... uid="uid://abc"]
	var first_line_end := content.find("\n")
	var head := content if first_line_end == -1 else content.substr(0, first_line_end)
	var marker := "uid=\""
	var idx := head.find(marker)
	if idx == -1:
		return ""
	var start := idx + marker.length()
	var end := head.find("\"", start)
	if end == -1:
		return ""
	return head.substr(start, end - start)


static func _extract_class_name(content: String) -> String:
	var marker := "class_name "
	var idx := content.find(marker)
	while idx != -1:
		var at_line_start := idx == 0 or content[idx - 1] == "\n" or content[idx - 1] == "\r"
		if at_line_start:
			var start := idx + marker.length()
			var end := start
			while end < content.length():
				var c := content[end]
				if WORD_CONTINUATION_CHARS.find(c) == -1:
					break
				end += 1
			return content.substr(start, end - start)
		idx = content.find(marker, idx + 1)
	return ""


static func _word_contains(content: String, word: String) -> bool:
	if word == "":
		return false
	var idx := content.find(word)
	while idx != -1:
		var before_ok := idx == 0 or WORD_CONTINUATION_CHARS.find(content[idx - 1]) == -1
		var after := idx + word.length()
		var after_ok := after >= content.length() or WORD_CONTINUATION_CHARS.find(content[after]) == -1
		if before_ok and after_ok:
			return true
		idx = content.find(word, idx + 1)
	return false


# ---------------------------------------------------------------- file access

## Reads a file as raw bytes, decoded 1 byte -> 1 character.
##
## Deliberately NOT get_as_text(): that's a UTF-8 decoder, and binary
## .scn/.res files are mostly non-UTF-8 bytes, which can corrupt the ASCII
## paths embedded among them. And get_string_from_ascii() alone stops dead
## at the first null byte -- binary Godot files are full of nulls, so that
## would truncate the content to a few header bytes. Nulls are therefore
## scrubbed to 0x01 first, in yielding chunks so a large file can't freeze
## the editor. Every non-null byte is left exactly as-is.
static func _read_file_async(path: String, main_loop) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"text": "", "truncated": false}
	var length := f.get_length()
	var truncated := false
	if length > MAX_BINARY_READ_BYTES:
		length = MAX_BINARY_READ_BYTES
		truncated = true
	var bytes := f.get_buffer(length)
	f.close()

	var size := bytes.size()
	var i := 0
	while i < size:
		var chunk_end: int = mini(i + NULL_SCRUB_CHUNK, size)
		while i < chunk_end:
			if bytes[i] == 0:
				bytes[i] = 1
			i += 1
		if main_loop is SceneTree and chunk_end < size:
			await (main_loop as SceneTree).process_frame

	return {"text": bytes.get_string_from_ascii(), "truncated": truncated}


static func _collect_files_async(dir_path: String, results: Array, progress: Callable, main_loop) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_warning("Orphan Finder: could not open directory %s" % dir_path)
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		if dir.current_is_dir():
			if not entry in SKIP_DIRS:
				await _collect_files_async(dir_path.path_join(entry), results, progress, main_loop)
		else:
			results.append(dir_path.path_join(entry))
			if progress.is_valid() and results.size() % 25 == 0:
				progress.call("inventory", results.size(), -1)
			if main_loop is SceneTree and (results.size() % YIELD_EVERY_N == 0):
				await (main_loop as SceneTree).process_frame
		entry = dir.get_next()
	dir.list_dir_end()


static func _is_sidecar(path: String) -> bool:
	for suffix in SIDECAR_SUFFIXES:
		if path.ends_with(suffix):
			return true
	return false


static func _is_always_kept(path: String) -> bool:
	if path.get_file() in ALWAYS_KEEP_FILENAMES:
		return true
	if path.get_extension().to_lower() in ALWAYS_KEEP_EXTENSIONS:
		return true
	return false


static func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var size := f.get_length()
	f.close()
	return size


# ---------------------------------------------------------------- logging

static func _write_log(
	orphans: Array, roots: Array, dynamic_dirs: Array, graph: Dictionary,
	unresolved_refs: Array, reachable_count: int, total_files: int, truncated: Array
) -> void:
	if not DirAccess.dir_exists_absolute(LOG_DIR):
		DirAccess.make_dir_recursive_absolute(LOG_DIR)

	var lines: PackedStringArray = []
	lines.append("================================================================")
	lines.append("Orphan scan (reachability): %s" % Time.get_datetime_string_from_system())
	lines.append("Reached %d of %d file(s) from %d entry point(s)." % [reachable_count, total_files, roots.size()])
	lines.append("----------------------------------------------------------------")
	lines.append("ENTRY POINTS:")
	for r in roots:
		var rd: Dictionary = r
		lines.append("  [%s] %s" % [rd["kind"], rd["path"]])
	lines.append("")
	lines.append("ORPHANS -- never reached from any entry point (%d):" % orphans.size())
	for o in orphans:
		var od: Dictionary = o
		lines.append("  %s  (%d bytes)" % [od["path"], od["size"]])
	if not dynamic_dirs.is_empty():
		lines.append("")
		lines.append("DIRECTORIES REFERENCED AS PATHS (%d) -- contents treated as live," % dynamic_dirs.size())
		lines.append("since code referencing a folder may load anything inside it at runtime:")
		for d in dynamic_dirs:
			var dd: Dictionary = d
			lines.append("  %s  (%d file(s), referenced in %s)" % [dd["dir"], dd["file_count"], dd["referenced_in"]])
	if not truncated.is_empty():
		lines.append("")
		lines.append("READ-TRUNCATED (%d) -- larger than the read cap, references past" % truncated.size())
		lines.append("the cap were not seen; treat orphan results for these with caution:")
		for t in truncated:
			lines.append("  %s" % t)

	if not unresolved_refs.is_empty():
		lines.append("")
		lines.append("UNRESOLVED REFERENCES (%d) -- seen in a file but not matched to" % unresolved_refs.size())
		lines.append("anything on disk. These are the most likely cause of a file being")
		lines.append("wrongly reported as an orphan:")
		for u in unresolved_refs:
			var ud: Dictionary = u
			lines.append("  %s   (in %s)" % [ud["reference"], ud["in_file"]])

	lines.append("")
	lines.append("----------------------------------------------------------------")
	lines.append("REFERENCE GRAPH -- what each parsed file was found to reference.")
	lines.append("If a file was wrongly reported as an orphan, find its expected")
	lines.append("parent here and check whether the reference was actually seen.")
	var graph_keys: Array = graph.keys()
	graph_keys.sort()
	for gk in graph_keys:
		var parent: String = gk
		var refs: Array = graph[parent]
		lines.append("")
		lines.append("%s  ->  %d reference(s)" % [parent, refs.size()])
		for rf in refs:
			lines.append("    %s" % String(rf))

	lines.append("================================================================")
	lines.append("")

	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var log_path := "%s/scan_%s.txt" % [LOG_DIR, stamp]
	var wf := FileAccess.open(log_path, FileAccess.WRITE)
	if wf == null:
		push_error("Orphan Finder: could not write log %s" % log_path)
		return
	wf.store_string("\n".join(lines) + "\n")
	wf.close()
