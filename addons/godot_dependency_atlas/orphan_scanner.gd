@tool
class_name OrphanScanner
extends RefCounted

const LanguageAnalyzer = preload("res://addons/godot_dependency_atlas/language_analyzer.gd")

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
const SKIP_DIRS := [
	".godot", ".git", ".import", "refactor_log", "orphan_scan_log",
	"dependency_atlas", "godot_dependency_atlas",
]

## Where scan reports are written.
## Log destination; set alongside scan_root so external scans write into
## the scanned project rather than this one.
static var log_dir := "res://dependency_atlas/logs"

## Files whose contents are read looking for outgoing references.
## "uid" matters more than it looks: Godot can reference an attached script
## from a .tscn by UID alone, with no path= field. Resolving that requires
## the uid -> path map, which is built from these .uid sidecar files. Leave
## it out and every UID-only reference silently fails to resolve.
const READABLE_EXTENSIONS := [
	"tscn", "tres", "scn", "res", "gd", "cs", "gdshader", "gdshaderinc",
	"cfg", "godot", "json", "gdextension", "import", "uid",
	# Plain data/config formats. A project that keeps a list of asset paths in
	# an .ini or .csv is pointing at real files, and skipping those formats
	# broke the chain: the data file looked unused AND everything it pointed
	# at looked unused too.
	"ini", "txt", "csv", "tsv", "xml", "yml", "yaml", "toml", "conf",
	"properties", "md", "po", "pot",
	# Multi-language source and build files. Filename-only manifests such as
	# CMakeLists.txt/SConstruct are admitted by LanguageAnalyzer.is_readable.
	"c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx",
	"csproj", "sln", "props", "targets", "vcxproj", "filters",
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

## Directory the scan reads from. "res://" means the running project; any
## other value points at an external Godot project opened for inspection.
##
## Paths inside the graph stay in logical res:// form regardless, because
## that is how references are written inside a project's own files. Only disk
## access is redirected, through _disk_path().
static var scan_root := "res://"


## Resource formats Godot itself can enumerate dependencies for. Binary
## .scn/.res have no reliable plain-text paths at all, and even text formats
## hide references behind sub-resource ids, so asking Godot beats guessing.
const GODOT_DEPENDENCY_EXTENSIONS := ["scn", "res", "tscn", "tres", "material", "mesh"]


## True when the scan targets the project this addon is running inside.
## ResourceLoader only knows about that project, so the authoritative pass is
## unavailable for anything else.
static func scanning_current_project() -> bool:
	return scan_root == "res://"


static func _disk_path(logical: String) -> String:
	if scan_root == "res://":
		return logical
	return scan_root.trim_suffix("/") + "/" + logical.trim_prefix("res://")

## Binary files above this are read only up to this many bytes. Godot binary
## formats put their resource/uid table near the front, so references are
## almost always well within this, but see the log note if any file hits it.
const MAX_BINARY_READ_BYTES := 8 * 1024 * 1024

## Null bytes are neutralised in chunks this size, yielding between chunks,
## so a large binary file can't freeze the editor.
const NULL_SCRUB_CHUNK := 262144

## Longest plausible file extension, used to sanity-check loose references.
const MAX_LOOSE_EXTENSION := 10

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

	# Refresh Godot's own cached view of the filesystem when running inside
	# the editor. Fetched as a singleton by name rather than referenced
	# directly, so this script stays loadable when run from a live scene
	# (the 3D graph viewer) where EditorInterface may not be available.
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		Engine.get_singleton("EditorInterface").get_resource_filesystem().scan()

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
		if fp3.get_extension().to_lower() in READABLE_EXTENSIONS or LanguageAnalyzer.is_readable(fp3):
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
	# class_name -> path, for GDScript global classes. C#/C/C++ declarations
	# live in the language analyzer's separate symbol index: merging native
	# declarations here lets an identifier in GDScript (even only a comment)
	# falsely make an unregistered header reachable.
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
		if ext2 == "gd":
			var cls := _extract_class_name(body)
			if cls != "":
				class_to_path[cls] = p2
		if progress.is_valid():
			progress.call("indexing", i + 1, all_files.size())
		if main_loop is SceneTree and (i % YIELD_EVERY_N == 0):
			await (main_loop as SceneTree).process_frame

	# C#/C/C++ declarations are intentionally kept separate from Godot's
	# global GDScript class_name namespace.
	var language_symbols := LanguageAnalyzer.build_symbol_index(content_cache)

	# ---------- 3. TRAVERSE ----------
	# Walk outward from the entry points. For each file: parse it completely,
	# record every outgoing reference found into the graph, mark it seen ONLY
	# once parsing is finished, then queue anything not already seen. The
	# graph is kept (not just a reachable set) because it's the thing that
	# explains a result -- if a file is wrongly reported as an orphan, the
	# graph shows exactly which parent failed to mention it.
	var basename_index := _build_basename_index(file_set)
	# Generated native libraries are opaque, so reconstruct their provenance
	# from .gdextension descriptors, native build targets and class
	# registration calls before traversal begins.
	var native_bridge := LanguageAnalyzer.native_bridge(
		content_cache, file_set, basename_index, language_symbols
	)
	var native_edges: Dictionary = native_bridge.get("edges", {})
	var native_edge_kinds: Dictionary = native_bridge.get("kinds", {})
	var native_class_libraries: Dictionary = native_bridge.get("class_libraries", {})
	var native_libraries: Array = native_bridge.get("libraries", [])

	# Authoritative pass, unioned with the text scan below. The two find
	# different things: Godot knows every real resource dependency including
	# binary formats, while the text scan sees bare filenames, paths inside
	# data files and class_name usage that Godot has no concept of.
	if progress.is_valid():
		progress.call("asking Godot for dependencies", 0, all_files.size())
	var godot_deps := await godot_dependencies_async(all_files, progress, main_loop)

	var roots := _find_roots(content_cache, file_set)
	# project.godot is configuration, not an executable entry point and not a
	# useful node in the 3D graph. Its direct resource settings (for example
	# config/icon) are still protected from orphan reporting, but stay hidden
	# unless executable content references them independently.
	var project_owned := _project_owned_files(
		String(content_cache.get("res://project.godot", "")), file_set
	)
	var root_paths := {}
	for root_any in roots:
		root_paths[String((root_any as Dictionary)["path"])] = true
	for build_root_any in LanguageAnalyzer.build_roots(file_set):
		var build_root: Dictionary = build_root_any
		var build_path := String(build_root["path"])
		if not root_paths.has(build_path):
			root_paths[build_path] = true
			roots.append(build_root)
	if roots.is_empty():
		return {
			"orphans": [], "roots": [], "dynamic_dirs": [], "graph": {}, "unresolved_refs": [], "log_text": "", "orphan_graph": {}, "hierarchy": {}, "godot_pass_used": false, "godot_dependency_files": 0,
			"edge_kinds": {}, "depth": {}, "tree_parent": {},
			"reachable_count": 0, "total_files": all_files.size(),
			"truncated_files": truncated,
			"error": "No entry points found. Expected a main scene (run/main_scene) in project.godot. Without a starting point, reachability can't be determined and every file would look like an orphan -- refusing to report a misleading result.",
		}

	var graph := {}      # file -> Array[String] of references found inside it
	var seen := {}       # file -> true, set only AFTER the file is fully parsed
	var depth := {}      # file -> BFS distance from an entry point
	var tree_parent := {}  # file -> whoever first reached it (spanning tree edge)
	var dynamic_dirs: Array = []
	var unresolved_refs: Array = []
	var edge_kinds := {}   # parent -> { child -> how the reference was found }
	var queue: Array = []
	for r in roots:
		var rd: Dictionary = r
		var root_path := String(rd["path"])
		depth[root_path] = 0
		queue.append(root_path)

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
			var sidecar: String = current + suffix
			if file_set.has(sidecar) and not found.has(sidecar):
				found.append(sidecar)

		# An .import file implies its source asset is in use.
		if current.get_extension().to_lower() == "import":
			var source := current.substr(0, current.length() - ".import".length())
			if file_set.has(source) and not found.has(source):
				found.append(source)

		# Godot's own dependency list first: it is authoritative, and marking
		# these before the text pass means a reference found by both keeps the
		# stronger attribution.
		for dep_any in godot_deps.get(current, []):
			var dep_path: String = dep_any
			if dep_path != current and file_set.has(dep_path) and not found.has(dep_path):
				found.append(dep_path)
				if not edge_kinds.has(current):
					edge_kinds[current] = {}
				edge_kinds[current][dep_path] = "godot"

		var content := String(content_cache.get(current, ""))
		if content != "":
			var ext_now := current.get_extension().to_lower()
			var code_content := ""
			if ext_now == "gd":
				code_content = _strip_code_noise(content)
			elif LanguageAnalyzer.is_source(current):
				code_content = LanguageAnalyzer.strip_comments_and_strings(content, false)
			var outgoing := _extract_references(
				content, code_content, file_set, dir_set, uid_to_path, class_to_path,
				basename_index
			)
			var kinds: Dictionary = outgoing["kinds"]
			for ref in outgoing["files"]:
				var ref_path: String = ref
				if ref_path != current and not found.has(ref_path):
					found.append(ref_path)
				if kinds.has(ref_path):
					if not edge_kinds.has(current):
						edge_kinds[current] = {}
					edge_kinds[current][ref_path] = String(kinds[ref_path])
			for ur in outgoing["unresolved"]:
				unresolved_refs.append({"in_file": current, "reference": String(ur)})
			var language_out := LanguageAnalyzer.references(
				current, content, file_set, basename_index, language_symbols
			)
			var language_kinds: Dictionary = language_out["kinds"]
			for language_ref_any in language_out["files"]:
				var language_ref: String = language_ref_any
				if language_ref != current and not found.has(language_ref):
					found.append(language_ref)
				if language_kinds.has(language_ref):
					if not edge_kinds.has(current):
						edge_kinds[current] = {}
					edge_kinds[current][language_ref] = String(language_kinds[language_ref])
			for build_member_any in LanguageAnalyzer.implicit_build_members(current, content, file_set):
				var build_member: String = build_member_any
				if build_member != current and not found.has(build_member):
					found.append(build_member)
				if not edge_kinds.has(current):
					edge_kinds[current] = {}
				edge_kinds[current][build_member] = "build"
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

			# GDScript/C# code naming a class registered into a GDExtension
			# depends on the generated library even though the engine exposes
			# no res:// path for that runtime class.
			if code_content != "":
				for class_any in native_class_libraries:
					var native_class := String(class_any)
					var native_library := String(native_class_libraries[native_class])
					if (
						native_library != current
						and _word_contains(code_content, native_class)
						and not found.has(native_library)
					):
						found.append(native_library)
						if not edge_kinds.has(current):
							edge_kinds[current] = {}
						edge_kinds[current][native_library] = "native_class"
				for interop_any in LanguageAnalyzer.native_library_references(
					content, native_libraries
				):
					var interop_library := String(interop_any)
					if interop_library != current and not found.has(interop_library):
						found.append(interop_library)
						if not edge_kinds.has(current):
							edge_kinds[current] = {}
						edge_kinds[current][interop_library] = "native_interop"

		# These inferred edges also apply to an unreadable .so/.dll/.dylib.
		for bridge_target_any in native_edges.get(current, []):
			var bridge_target := String(bridge_target_any)
			if file_set.has(bridge_target) and not found.has(bridge_target):
				found.append(bridge_target)
			if not edge_kinds.has(current):
				edge_kinds[current] = {}
			edge_kinds[current][bridge_target] = String(
				(native_edge_kinds.get(current, {}) as Dictionary).get(
					bridge_target, "native_bridge"
				)
			)

		# --- parsing done: only now record it and mark it seen ---
		found.sort()
		graph[current] = found
		seen[current] = true
		processed += 1

		# --- queue anything we haven't already parsed ---
		# Depth/parent are fixed at FIRST enqueue. With a FIFO queue that's
		# the shortest path from an entry point, and it's what defines the
		# spanning tree used for layout: extra references to an
		# already-placed file become cross-links rather than moving it.
		for ref2 in found:
			var next_path: String = ref2
			if not seen.has(next_path):
				if not depth.has(next_path):
					depth[next_path] = int(depth.get(current, 0)) + 1
					tree_parent[next_path] = current
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
		if project_owned.has(p4):
			continue
		if _is_always_kept(p4):
			continue
		if _is_sidecar(p4):
			continue
		orphans.append({"path": p4, "size": _file_size(p4)})

	# Orphans were never traversed, so nothing recorded what THEY reference --
	# graph[] only has entries for files the walk actually reached. Without
	# this pass every orphan looks isolated, and a dead subsystem of five
	# mutually-referencing files renders as five unrelated dots.
	#
	# Kept in its own map: it is display information only, and must not leak
	# into reachability, the orphan list, or the coupling metrics.
	var orphan_graph := {}
	var orphan_index := 0
	for entry_any in orphans:
		var orphan_entry: Dictionary = entry_any
		var orphan_path: String = orphan_entry["path"]
		var orphan_content := String(content_cache.get(orphan_path, ""))
		orphan_index += 1
		if progress.is_valid() and orphan_index % 5 == 0:
			progress.call("mapping orphan links", orphan_index, orphans.size())
		if main_loop is SceneTree and (orphan_index % YIELD_EVERY_N == 0):
			await (main_loop as SceneTree).process_frame
		if orphan_content == "":
			continue
		var orphan_code := ""
		var orphan_ext := orphan_path.get_extension().to_lower()
		if orphan_ext == "gd":
			orphan_code = _strip_code_noise(orphan_content)
		elif LanguageAnalyzer.is_source(orphan_path):
			orphan_code = LanguageAnalyzer.strip_comments_and_strings(orphan_content, false)
		var orphan_out := _extract_references(
			orphan_content, orphan_code, file_set, dir_set, uid_to_path,
			class_to_path, basename_index
		)
		var orphan_refs: Array = []
		for dep_any in godot_deps.get(orphan_path, []):
			var orphan_dep: String = dep_any
			if orphan_dep != orphan_path and file_set.has(orphan_dep):
				orphan_refs.append(orphan_dep)
		for r in orphan_out["files"]:
			var ref_path: String = r
			if ref_path != orphan_path and not (ref_path in orphan_refs):
				orphan_refs.append(ref_path)
		var orphan_language := LanguageAnalyzer.references(
			orphan_path, orphan_content, file_set, basename_index, language_symbols
		)
		for language_ref_any in orphan_language["files"]:
			var language_ref: String = language_ref_any
			if language_ref != orphan_path and not (language_ref in orphan_refs):
				orphan_refs.append(language_ref)
		if not orphan_refs.is_empty():
			orphan_graph[orphan_path] = orphan_refs

	if progress.is_valid():
		progress.call("checking duplicated content", 0, orphans.size())
	await _find_duplicated_content(orphans, content_cache, seen, progress, main_loop)

	if progress.is_valid():
		progress.call("building class hierarchy", 0, -1)
	if main_loop is SceneTree:
		await (main_loop as SceneTree).process_frame
	var hierarchy := _combined_hierarchy(content_cache, class_to_path, language_symbols)

	if progress.is_valid():
		progress.call("writing report", 0, -1)
	if main_loop is SceneTree:
		await (main_loop as SceneTree).process_frame

	var reachable_count := seen.size()
	for owned_any in project_owned:
		if not seen.has(owned_any):
			reachable_count += 1
	var log_text := build_log_text(orphans, roots, dynamic_dirs, graph, unresolved_refs, reachable_count, all_files.size(), truncated, scanning_current_project(), godot_deps.size())

	return {
		"hierarchy": hierarchy,
		"orphans": orphans,
		"godot_pass_used": scanning_current_project(),
		"godot_dependency_files": godot_deps.size(),
		"orphan_graph": orphan_graph,
		"log_text": log_text,
		"roots": roots,
		"dynamic_dirs": dynamic_dirs,
		"graph": graph,
		"edge_kinds": edge_kinds,
		"depth": depth,
		"tree_parent": tree_parent,
		"unresolved_refs": unresolved_refs,
		"reachable_count": reachable_count,
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


static func _project_owned_files(project_cfg: String, file_set: Dictionary) -> Dictionary:
	var result := {}
	for token_any in _extract_res_tokens(project_cfg):
		var resolved := _longest_known_prefix(String(token_any), file_set)
		if resolved != "":
			result[resolved] = true
	return result


static func _enabled_plugin_cfgs(project_cfg: String, file_set: Dictionary) -> Array:
	var result: Array = []
	var idx := project_cfg.find("[editor_plugins]")
	if idx == -1:
		return result
	var section := project_cfg.substr(idx)
	var next_section := section.find("\n[", 1)
	if next_section != -1:
		section = section.substr(0, next_section)
	var seen := {}
	for token in _extract_res_tokens(section):
		var t: String = token
		var resolved := _longest_known_prefix(t, file_set)
		if resolved != "" and resolved.get_file() == "plugin.cfg" and not seen.has(resolved):
			seen[resolved] = true
			result.append(resolved)
	# Godot 4 stores enabled plugins by addon id, e.g.
	# PackedStringArray("node25d-cs"), not by res:// plugin.cfg path.
	for literal_any in _extract_quoted_literals(section):
		var plugin_id: String = literal_any
		if plugin_id.begins_with("res://"):
			continue
		var candidate := "res://addons/%s/plugin.cfg" % plugin_id
		if file_set.has(candidate) and not seen.has(candidate):
			seen[candidate] = true
			result.append(candidate)
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
## Returns { "files": Array, "dirs": Array, "unresolved": Array, "kinds": Dictionary }.
## `kinds` records HOW each reference was found, which lets downstream
## consumers weigh them: a path or uid reference is unambiguous, whereas a
## bare class_name match found only in a comment is a guess.
## code_content should be the file with comments/strings stripped, or "" for
## non-code files.
static func _extract_references(
	content: String, code_content: String, file_set: Dictionary, dir_set: Dictionary,
	uid_to_path: Dictionary, class_to_path: Dictionary, basename_index: Dictionary
) -> Dictionary:
	var files := {}
	var dirs := {}
	var unresolved := {}
	var kinds := {}

	# Structural resource-block parsing first: it is the authoritative source
	# for .tscn/.tres dependencies, including uid-only declarations that no
	# amount of res:// token scanning could find.
	var blocks := _extract_resource_block_refs(content, file_set, uid_to_path)
	var block_found: Dictionary = blocks["found"]
	for key in block_found.keys():
		var block_path: String = key
		files[block_path] = true
		kinds[block_path] = String(block_found[block_path])
	for u in blocks["unresolved"]:
		unresolved[String(u)] = true

	# res:// path literals -- covers instanced scenes, preloads, ext_resource
	# path= fields, and anything else written as an explicit path.
	for token in _extract_res_tokens(content):
		var t: String = token
		var resolved := _longest_known_prefix(t, file_set)
		if resolved != "":
			files[resolved] = true
			if not kinds.has(resolved):
				kinds[resolved] = "path"
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
			if not kinds.has(target):
				kinds[target] = "uid"
		else:
			unresolved[u] = true

	# Loose references inside quoted literals: bare filenames, relative
	# paths, and absolute paths written on some other machine.
	for literal in _extract_quoted_literals(content):
		var lit: String = literal
		if lit.begins_with("res://") or lit.begins_with("uid://"):
			continue  # already handled precisely above
		var loose := _resolve_loose_reference(lit, basename_index)
		if loose != "" and not kinds.has(loose):
			files[loose] = true
			kinds[loose] = "filename"

	# Global type names are meaningful in source code. Searching scenes and
	# data once per declared class is both noisy and quadratic on large projects.
	var searchable := code_content
	if searchable != "":
		for key in class_to_path.keys():
			var cls: String = key
			var target2: String = class_to_path[cls]
			if kinds.has(target2) and String(kinds[target2]) != "class_name_weak":
				continue
			if _word_contains(searchable, cls):
				files[target2] = true
				kinds[target2] = "class_name"
			elif _word_contains(content, cls):
				# Present in the file, but only inside a comment or string.
				files[target2] = true
				kinds[target2] = "class_name_weak"

	return {"files": files.keys(), "dirs": dirs.keys(), "unresolved": unresolved.keys(), "kinds": kinds}


## Pulls out every quoted string literal, which is where loose file
## references live: FileAccess.open("recent_files.ini"), a path stored in a
## data file, a relative filename in a config. None of those contain "res://"
## so path-token extraction alone never sees them.
static func _extract_quoted_literals(content: String) -> Array:
	var out: Array = []
	var i := 0
	var length := content.length()
	var in_block_comment := false
	while i < length:
		var c: String = content[i]
		var next := content[i + 1] if i + 1 < length else ""
		if in_block_comment:
			if c == "*" and next == "/":
				in_block_comment = false
				i += 2
			else:
				i += 1
			continue
		# GDScript/shell comments and C-family comments. Apostrophes inside a
		# comment such as "We're" must never open a string and swallow every
		# relative preload later in the file.
		if c == "#" or (c == "/" and next == "/"):
			while i < length and content[i] != "\n":
				i += 1
			continue
		if c == "/" and next == "*":
			in_block_comment = true
			i += 2
			continue
		if c == "\"" or c == "'":
			var quote := c
			var start := i + 1
			var j := start
			var escaped := false
			while j < length:
				var current: String = content[j]
				if not escaped and current == quote:
					break
				if not escaped and current == "\\":
					escaped = true
				else:
					escaped = false
				j += 1
			# Reference-like literals are short. Bounding them prevents huge
			# serialized values from being copied and inspected as file paths.
			var literal_length := j - start
			if literal_length > 0 and literal_length <= MAX_QUOTED_REFERENCE_LENGTH:
				var literal := content.substr(start, literal_length)
				if literal.contains("\\"):
					literal = literal.replace("\\\"", "\"").replace("\\'", "'").replace("\\\\", "\\")
				out.append(literal)
			i = j + 1
			continue
		i += 1
	return out

## filename -> every project file with that filename.
## Reads `extends` and `class_name` to recover the code hierarchy.
##
## Inheritance is far stronger evidence of structure than a shared filename
## prefix: RA_AddVoxel and RA_RemoveVoxel share a prefix but are siblings, not
## collaborators -- they use their base class and never each other. Laying
## them out as one flat cluster hides precisely the shape that matters.
##
## Returns { "parent_of": path -> parent path, "class_of": path -> class_name }.
static func extract_hierarchy(content_cache: Dictionary, class_to_path: Dictionary) -> Dictionary:
	var class_of := {}
	var extends_name := {}
	var local_consts := {}      # path -> { const name -> preloaded path }

	for key in content_cache.keys():
		var path: String = key
		if not (path.get_extension().to_lower() in ["gd"]):
			continue
		var content := String(content_cache[path])
		for raw_line in content.split("\n"):
			var line := String(raw_line).strip_edges()
			if line.begins_with("class_name "):
				var declared := line.substr(11).strip_edges()
				var comma := declared.find(",")
				if comma != -1:
					declared = declared.substr(0, comma).strip_edges()
				if declared != "":
					class_of[path] = declared
			elif line.begins_with("extends "):
				var base := line.substr(8).strip_edges()
				# `extends "res://foo.gd"` is a path, not a class name.
				if base.begins_with("\"") or base.begins_with("'"):
					base = base.replace("\"", "").replace("'", "")
				extends_name[path] = base
			elif line.begins_with("const ") and line.contains("preload("):
				# `const RA = preload("res://.../ReversableAction.gd")` followed
				# by `extends RA` is a common way to subclass without declaring
				# a class_name. Without this the parent is never resolved and
				# the hierarchy looks flat.
				var name_end := line.find("=")
				if name_end > 6:
					var const_name := line.substr(6, name_end - 6).strip_edges()
					var quote := line.find("\"", name_end)
					var quote_end := line.find("\"", quote + 1)
					if quote != -1 and quote_end != -1:
						var target := line.substr(quote + 1, quote_end - quote - 1)
						if target.begins_with("res://"):
							if not local_consts.has(path):
								local_consts[path] = {}
							local_consts[path][const_name] = target
			# Only the header matters; stop at the first function. `var` is no
			# longer a stop condition because `const X = preload(...)` often
			# sits after exported variables.
			if line.begins_with("func "):
				break

	var declared_to_path := {}
	for declared_path_any in class_of.keys():
		declared_to_path[String(class_of[declared_path_any])] = String(declared_path_any)

	var parent_of := {}
	for key2 in extends_name.keys():
		var child: String = key2
		var base_name := String(extends_name[child])
		if base_name.begins_with("res://"):
			if content_cache.has(base_name):
				parent_of[child] = base_name
			continue
		# Resolve by class_name, either declared locally or globally indexed.
		var resolved := ""
		# A preload constant in the same file resolves directly to a path.
		var consts: Dictionary = local_consts.get(child, {})
		if consts.has(base_name):
			var const_target := String(consts[base_name])
			if content_cache.has(const_target):
				parent_of[child] = const_target
				continue
		if declared_to_path.has(base_name):
			resolved = String(declared_to_path[base_name])
		if resolved == "" and class_to_path.has(base_name):
			resolved = String(class_to_path[base_name])
		if resolved != "" and resolved != child:
			parent_of[child] = resolved

	return {"parent_of": parent_of, "class_of": class_of}


## Merges the established GDScript hierarchy with C#/C/C++ declarations.
## GDScript wins on overlap because its path/preload resolution is stronger
## than name-only source parsing.
static func _combined_hierarchy(
	content_cache: Dictionary, class_to_path: Dictionary, language_symbols: Dictionary
) -> Dictionary:
	var gd := extract_hierarchy(content_cache, class_to_path)
	var native := LanguageAnalyzer.hierarchy(content_cache, language_symbols)
	var parent_of: Dictionary = native["parent_of"].duplicate()
	var class_of: Dictionary = native["class_of"].duplicate()
	for key_any in (gd["parent_of"] as Dictionary).keys():
		parent_of[String(key_any)] = gd["parent_of"][key_any]
	for key_any2 in (gd["class_of"] as Dictionary).keys():
		class_of[String(key_any2)] = gd["class_of"][key_any2]
	return {"parent_of": parent_of, "class_of": class_of}


static func _build_basename_index(file_set: Dictionary) -> Dictionary:
	var index := {}
	for key in file_set.keys():
		var path: String = key
		var base := path.get_file()
		if not index.has(base):
			index[base] = []
		index[base].append(path)
	return index


## Resolves a reference that isn't a res:// path -- a bare filename, a
## relative path, or an absolute OS path from another machine -- by matching
## on filename and then preferring whichever candidate agrees with the most
## trailing path components.
##
## This is how an entry like "/home/someone/Projects/Foo/models/test.voxel"
## inside a data file still resolves to res://models/test.voxel.
static func _resolve_loose_reference(token: String, basename_index: Dictionary) -> String:
	var normalised := token.replace("\\", "/")
	var base := normalised.get_file()
	if base == "" or base.find(".") == -1:
		return ""
	var ext := base.get_extension()
	if ext == "" or ext.length() > MAX_LOOSE_EXTENSION or ext.is_valid_int():
		return ""
	if not basename_index.has(base):
		return ""

	var candidates: Array = basename_index[base]
	if candidates.size() == 1:
		return String(candidates[0])

	var best := ""
	var best_score := -1
	for c in candidates:
		var candidate: String = c
		var score := _suffix_agreement(candidate, normalised)
		if score > best_score:
			best_score = score
			best = candidate
	return best


## How many trailing path components two paths share.
static func _suffix_agreement(project_path: String, token: String) -> int:
	var a := project_path.trim_prefix("res://").split("/")
	var b := token.split("/")
	var n := 0
	while n < mini(a.size(), b.size()) and a[a.size() - 1 - n] == b[b.size() - 1 - n]:
		n += 1
	return n


## Reads [ext_resource] and [sub_resource] headers structurally, pulling both
## the path and the uid attribute from each.
##
## Resource files shouldn't depend on generic res:// token scanning: a
## dependency can be declared with a uid and no path at all --
##   [ext_resource type="Shader" uid="uid://cabc" id="1_sh"]
## -- and then only referenced as ExtResource("1_sh") further down. Nothing in
## that file contains the shader's path, so token scanning finds nothing and
## the shader looks unused. Parsing the header and resolving the uid is the
## only reliable way to see it.
## Longest line worth using as a fingerprint when looking for duplicated
## content. Short lines match by coincidence; enormous ones are usually
## minified data.
const PROBE_MIN_LENGTH := 40
const PROBE_MAX_LENGTH := 300
const MAX_DUPLICATE_CHECKS := 400
const MAX_QUOTED_REFERENCE_LENGTH := 4096


## For each orphan, checks whether its content appears verbatim inside a file
## that IS reachable.
##
## This exists because of a genuinely confusing case: a shader saved as its own
## .tres, whose code was later pasted into a material as an inline
## [sub_resource] instead of being referenced. The standalone file then has no
## incoming reference and is correctly an orphan -- but it *looks* used,
## because its code is visibly running in the project. Saying "this content is
## duplicated inline in X" turns a baffling result into an actionable one.
static func _find_duplicated_content(
	orphans: Array, content_cache: Dictionary, seen: Dictionary,
	progress: Callable = Callable(), main_loop = null
) -> void:
	var checked := 0
	var examined := 0
	var comparisons := 0
	# Paint the new phase before beginning the potentially expensive search.
	if main_loop is SceneTree:
		await (main_loop as SceneTree).process_frame
	for entry_any in orphans:
		if checked >= MAX_DUPLICATE_CHECKS:
			break
		var entry: Dictionary = entry_any
		var path: String = entry["path"]
		var content := String(content_cache.get(path, ""))
		examined += 1
		if progress.is_valid():
			progress.call("checking duplicated content", examined, orphans.size())
		if content == "":
			continue

		var probe := _pick_probe(content)
		if probe == "":
			continue
		checked += 1

		for key in content_cache.keys():
			var other: String = key
			if other == path or not seen.has(other):
				continue
			comparisons += 1
			if comparisons % YIELD_EVERY_N == 0 and main_loop is SceneTree:
				await (main_loop as SceneTree).process_frame
			if String(content_cache[other]).find(probe) != -1:
				entry["duplicated_in"] = other
				break
	if progress.is_valid():
		progress.call("checking duplicated content", mini(examined, orphans.size()), orphans.size())


## Picks the longest reasonably-sized line to fingerprint a file by.
static func _pick_probe(content: String) -> String:
	var best := ""
	for raw_line in content.split("\n"):
		var line := String(raw_line).strip_edges()
		if line.length() < PROBE_MIN_LENGTH or line.length() > PROBE_MAX_LENGTH:
			continue
		if line.length() > best.length():
			best = line
	return best


static func _extract_resource_block_refs(
	content: String, file_set: Dictionary, uid_to_path: Dictionary
) -> Dictionary:
	var found := {}
	var unresolved := {}

	for marker in ["[ext_resource", "[sub_resource"]:
		var idx := content.find(marker)
		while idx != -1:
			var end := content.find("]", idx)
			if end == -1:
				break
			var line := content.substr(idx, end - idx)

			var path_val := _quoted_attr(line, "path")
			if path_val != "" and file_set.has(path_val):
				found[path_val] = "path"

			var uid_val := _quoted_attr(line, "uid")
			if uid_val != "" and not found.has(path_val):
				var resolved := _resolve_uid(uid_val, uid_to_path)
				if resolved != "" and file_set.has(resolved):
					found[resolved] = "uid"
				elif path_val == "":
					# Declared purely by uid and we couldn't resolve it: worth
					# surfacing, since it means something is unreachable that
					# probably shouldn't be.
					unresolved[uid_val] = true

			idx = content.find(marker, end)

	return {"found": found, "unresolved": unresolved.keys()}


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
	# ResourceUID only knows about the running project, so it is bypassed when
	# inspecting an external one; harvested uid<->path pairs cover that case.
	var id := ResourceUID.INVALID_ID if scan_root != "res://" else ResourceUID.text_to_id(uid_text)
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


## Strips GDScript comments and string literals, leaving only executable
## code. Used to tell a REAL class reference (`extends Foo`, `Foo.new()`)
## apart from a passing mention in a docstring or comment.
##
## This matters because a base class that documents its own subclasses --
## "## Subclasses include AddVoxelAction" -- would otherwise create a
## phantom base -> subclass edge, which pairs with the genuine
## subclass -> base edge to form a 2-cycle that isn't real.
static func _strip_code_noise(content: String) -> String:
	var out: PackedStringArray = []
	for raw_line in content.split("\n"):
		var line: String = raw_line
		var cleaned := ""
		var in_string := false
		var quote := ""
		var i := 0
		while i < line.length():
			var c: String = line[i]
			if in_string:
				if c == "\\":
					i += 2
					continue
				if c == quote:
					in_string = false
				i += 1
				continue
			if c == "\"" or c == "'":
				in_string = true
				quote = c
				i += 1
				continue
			if c == "#":
				break
			cleaned += c
			i += 1
		out.append(cleaned)
	return "\n".join(out)


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
	var f := FileAccess.open(_disk_path(path), FileAccess.READ)
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


## Asks Godot for each resource's dependencies.
##
## ResourceLoader.get_dependencies() reads a resource's dependency table
## WITHOUT instantiating it, so there are no script side effects and none of
## the cost of building objects only to discard them. It is the same
## deserialisation the editor uses for its own dependency tracking, which
## makes it authoritative in a way byte-scanning cannot be: a binary .scn
## stores a MeshLibrary reference as an object pointer, with no path string
## anywhere in the file for a text scan to find.
##
## Returns { file -> Array of res:// paths }.
static func godot_dependencies_async(
	files: Array, progress: Callable = Callable(), main_loop = null
) -> Dictionary:
	var found := {}
	if not scanning_current_project():
		return found   # ResourceLoader only knows the running project

	var total := files.size()
	for i in total:
		var path: String = files[i]
		if not (path.get_extension().to_lower() in GODOT_DEPENDENCY_EXTENSIONS):
			continue
		var deps := ResourceLoader.get_dependencies(path)
		var resolved: Array = []
		for entry_any in deps:
			var resolved_path := _clean_dependency(String(entry_any))
			if resolved_path != "" and resolved_path != path:
				resolved.append(resolved_path)
		if not resolved.is_empty():
			found[path] = resolved
		if progress.is_valid() and i % 10 == 0:
			progress.call("asking Godot for dependencies", i + 1, total)
		if main_loop is SceneTree and (i % YIELD_EVERY_N == 0):
			await (main_loop as SceneTree).process_frame

	if progress.is_valid():
		progress.call("asking Godot for dependencies", total, total)
	return found


## Dependency entries arrive as "uid://abc::Type::res://path" or as a plain
## path, depending on format and Godot version. Pull the usable path out of
## whichever shape turned up.
static func _clean_dependency(entry: String) -> String:
	var text := entry
	var marker := text.rfind("res://")
	if marker != -1:
		var path := text.substr(marker)
		# A type hint can trail the path ("res://a.tres::MeshLibrary"), which
		# would never match a real file.
		var type_marker := path.find("::")
		if type_marker != -1:
			path = path.substr(0, type_marker)
		return path
	# A uid-only entry: resolve it through Godot's own registry.
	var uid_marker := text.find("uid://")
	if uid_marker != -1:
		var uid_text := text.substr(uid_marker)
		var separator := uid_text.find("::")
		if separator != -1:
			uid_text = uid_text.substr(0, separator)
		var id := ResourceUID.text_to_id(uid_text)
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			return ResourceUID.get_id_path(id)
	return ""


static func _collect_files_async(dir_path: String, results: Array, progress: Callable, main_loop) -> void:
	var dir := DirAccess.open(_disk_path(dir_path))
	if dir == null:
		push_warning("Dependency Atlas: could not open directory %s" % _disk_path(dir_path))
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry == "." or entry == "..":
			entry = dir.get_next()
			continue
		if dir.current_is_dir():
			var child_dir := dir_path.path_join(entry)
			# Godot excludes an entire directory containing .gdignore from its
			# resource filesystem. Mirror that boundary so documentation/source
			# archives are not presented as deletable runtime orphans.
			var godot_ignored := FileAccess.file_exists(_disk_path(child_dir.path_join(".gdignore")))
			if not entry in SKIP_DIRS and not godot_ignored:
				await _collect_files_async(child_dir, results, progress, main_loop)
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
	var f := FileAccess.open(_disk_path(path), FileAccess.READ)
	if f == null:
		return -1
	var size := f.get_length()
	f.close()
	return size


# ---------------------------------------------------------------- logging

static func build_log_text(
	orphans: Array, roots: Array, dynamic_dirs: Array, graph: Dictionary,
	unresolved_refs: Array, reachable_count: int, total_files: int, truncated: Array,
	godot_pass := true, godot_files := 0
) -> String:
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
		var note := ""
		if od.has("duplicated_in"):
			note = "   <-- content is duplicated inline inside %s" % String(od["duplicated_in"])
		lines.append("  %s  (%d bytes)%s" % [od["path"], od["size"], note])

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

	return "\n".join(lines) + "\n"


## Writes previously-built log text to disk. Separate from building it so a
## scan never writes a file nobody asked for -- reports are only saved when
## you press Save.
static func write_log_to(path: String, text: String) -> String:
	var folder := path.get_base_dir()
	if folder != "" and not DirAccess.dir_exists_absolute(folder):
		if DirAccess.make_dir_recursive_absolute(folder) != OK:
			return "Could not create %s" % folder
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not write %s" % path
	f.store_string(text)
	f.close()
	return ""


## Default destination for a Save (as opposed to Save As).
static func default_log_path() -> String:
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	return "%s/scan_%s.txt" % [log_dir, stamp]
