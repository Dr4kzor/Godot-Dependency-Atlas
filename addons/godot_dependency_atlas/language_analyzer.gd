@tool
extends RefCounted

## Conservative source/build analysis for languages Godot can host beside
## GDScript. It deliberately extracts structural facts only: declarations,
## inheritance, includes, symbol use, and build membership. It is not a
## compiler and never treats control-flow guesses as reachability evidence.

const SOURCE_EXTENSIONS := ["gd", "cs", "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx"]
const CSHARP_EXTENSIONS := ["cs"]
const NATIVE_EXTENSIONS := ["c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx"]
const BUILD_FILENAMES := ["CMakeLists.txt", "SConstruct", "SConscript", "meson.build"]
const BUILD_EXTENSIONS := ["csproj", "sln", "props", "targets", "vcxproj", "filters"]
const IDENT_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"


static func is_source(path: String) -> bool:
	return path.get_extension().to_lower() in SOURCE_EXTENSIONS


static func is_build_file(path: String) -> bool:
	return path.get_file() in BUILD_FILENAMES or path.get_extension().to_lower() in BUILD_EXTENSIONS


static func is_readable(path: String) -> bool:
	return is_source(path) or is_build_file(path)


## Returns symbol -> source path for C#, C and C++ declarations.
static func build_symbol_index(contents: Dictionary) -> Dictionary:
	var out := {}
	for key_any in contents.keys():
		var path: String = key_any
		if not is_source(path):
			continue
		for declaration_any in declarations(path, String(contents[path])):
			var declaration: Dictionary = declaration_any
			var name := String(declaration.get("name", ""))
			if name != "" and not out.has(name):
				out[name] = path
	return out


## Returns [{name, parent}]. Interfaces after the first C# base are ignored
## for hierarchy placement but still become symbol-reference edges.
static func declarations(path: String, content: String) -> Array:
	var ext := path.get_extension().to_lower()
	if ext == "gd" or not (ext in CSHARP_EXTENSIONS or ext in NATIVE_EXTENSIONS):
		return [] # the scanner's mature GDScript hierarchy parser owns .gd
	var clean := strip_comments_and_strings(content, true)
	var out: Array = []
	var pattern := ""
	if ext in CSHARP_EXTENSIONS:
		pattern = "(?:^|[\\n;{}])[ \\t]*(?:(?:public|private|protected|internal|static|abstract|sealed|partial|new)[ \\t]+)*(?:class|struct|interface|record)[ \\t]+([A-Za-z_][A-Za-z0-9_]*)(?:[ \\t]*:[ \\t]*([A-Za-z_][A-Za-z0-9_\\.]*))?"
	elif ext in NATIVE_EXTENSIONS:
		pattern = "(?:^|[\\n;{}])[ \\t]*(?:class|struct)[ \\t]+(?:[A-Z_][A-Z0-9_]*[ \\t]+)*([A-Za-z_][A-Za-z0-9_]*)(?:[ \\t]*:[ \\t]*(?:(?:public|protected|private|virtual)[ \\t]+)*([A-Za-z_][A-Za-z0-9_:]*))?"
	else:
		return out
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return out
	for match_any in regex.search_all(clean):
		var match: RegExMatch = match_any
		out.append({"name": match.get_string(1), "parent": _unqualify(match.get_string(2))})
	return out


## Language-specific source edges. Generic res://, uid:// and quoted filename
## references remain the scanner's responsibility.
static func references(
	path: String, content: String, file_set: Dictionary,
	basename_index: Dictionary, symbol_index: Dictionary
) -> Dictionary:
	var found := {}
	var kinds := {}
	var ext := path.get_extension().to_lower()
	if not (ext in SOURCE_EXTENSIONS or is_build_file(path)):
		return {"files": [], "kinds": {}}
	var clean := strip_comments_and_strings(content, false)

	if ext in NATIVE_EXTENSIONS:
		var include_regex := RegEx.new()
		include_regex.compile("(?m)^[ \\t]*#[ \\t]*include[ \\t]*[\\\"<]([^\\\">]+)[\\\">]")
		for match_any in include_regex.search_all(content):
			var include_name := String((match_any as RegExMatch).get_string(1))
			var resolved := _resolve_include(path, include_name, file_set, basename_index)
			if resolved != "" and resolved != path:
				found[resolved] = true
				kinds[resolved] = "include"

	# A matching identifier is only type evidence inside the same language
	# family. GDScript class_name declarations are resolved by the scanner,
	# and a GDScript class can legitimately have the same name as an old C++
	# implementation without depending on its header. Native classes exposed
	# to Godot are handled separately by the explicit GDExtension bridge.
	if ext in CSHARP_EXTENSIONS or ext in NATIVE_EXTENSIONS:
		for symbol_any in symbol_index.keys():
			var symbol: String = symbol_any
			var target: String = symbol_index[symbol]
			if (
				target != path
				and _same_language_family(path, target)
				and _word_contains(clean, symbol)
			):
				found[target] = true
				if not kinds.has(target):
					kinds[target] = "type"

	# Build membership from explicit paths/basenames and real Glob("...") /
	# glob patterns only. A bare "*." + extension substring used to treat
	# every source under the manifest directory as compiled, which pulled in
	# vendored SDKs whenever SConstruct contained Glob("src/*.cpp").
	if is_build_file(path):
		var build_base := path.get_base_dir()
		var prefix := build_base if build_base.ends_with("/") else build_base + "/"
		for candidate_any in file_set.keys():
			var candidate: String = candidate_any
			if candidate == path:
				continue
			var candidate_ext := candidate.get_extension().to_lower()
			if not (candidate_ext in SOURCE_EXTENSIONS or candidate_ext in BUILD_EXTENSIONS):
				continue
			if not (candidate.get_base_dir() == build_base or candidate.begins_with(prefix)):
				continue
			var relative := candidate.trim_prefix(prefix)
			if content.contains(relative) or content.contains(candidate.get_file()):
				found[candidate] = true
				kinds[candidate] = "build"
		for globbed_any in _files_matching_globs(path, _extract_glob_patterns(content), file_set):
			var globbed_path := String(globbed_any)
			if globbed_path != path:
				found[globbed_path] = true
				kinds[globbed_path] = "build"

	return {"files": found.keys(), "kinds": kinds}


## SDK-style C# projects compile .cs files implicitly. Explicit build files
## are roots, and this edge records that conservative build membership.
static func implicit_build_members(path: String, content: String, file_set: Dictionary) -> Array:
	if path.get_extension().to_lower() != "csproj":
		return []
	var implicit := content.contains("<Project Sdk=") and not content.contains("<EnableDefaultCompileItems>false")
	if not implicit:
		return []
	var base := path.get_base_dir()
	# res:// already ends in a slash. Appending another produced res:/// and
	# excluded every SDK-implicit source in a root-level C# project.
	var prefix := base if base.ends_with("/") else base + "/"
	var out: Array = []
	for candidate_any in file_set.keys():
		var candidate: String = candidate_any
		if candidate.get_extension().to_lower() == "cs" and (candidate.get_base_dir() == base or candidate.begins_with(prefix)):
			out.append(candidate)
	return out


## Build manifests are execution roots only when the corresponding language
## is present. This prevents native/C# files from being judged solely by the
## Godot resource graph, while still allowing dead files omitted by a build
## manifest to remain orphan candidates.
static func build_roots(file_set: Dictionary) -> Array:
	var has_cs := false
	var has_native := false
	var has_gdextension := false
	for key_any in file_set.keys():
		var path: String = key_any
		var ext := path.get_extension().to_lower()
		has_cs = has_cs or ext == "cs"
		has_native = has_native or ext in NATIVE_EXTENSIONS
		has_gdextension = has_gdextension or ext == "gdextension"
	var out: Array = []
	for key_any2 in file_set.keys():
		var candidate: String = key_any2
		var ext2 := candidate.get_extension().to_lower()
		if ext2 == "gdextension":
			out.append({"path": candidate, "kind": "native extension"})
		elif has_cs and ext2 in ["csproj", "sln"]:
			out.append({"path": candidate, "kind": "C# build"})
		elif has_native and has_gdextension and is_build_file(candidate) and ext2 not in ["csproj", "sln", "props", "targets"]:
			out.append({"path": candidate, "kind": "native build"})
	return out


## Builds the explicit bridge between native source, its generated library,
## the .gdextension descriptor that loads it, and classes registered with
## Godot. The returned edges use normal graph direction: loader -> library ->
## build manifest -> source.
static func native_bridge(contents: Dictionary, file_set: Dictionary,
		basename_index: Dictionary, symbol_index: Dictionary) -> Dictionary:
	var edges := {}
	var kinds := {}
	var class_libraries := {}
	var libraries: Array = []
	var targets := _native_build_targets(contents, file_set, basename_index)
	var registrations := _native_registrations(contents, symbol_index)

	for key_any in contents:
		var descriptor: String = key_any
		if descriptor.get_extension().to_lower() != "gdextension":
			continue
		for library_any in _gdextension_libraries(
			descriptor, String(contents[descriptor]), file_set, basename_index
		):
			var library := String(library_any)
			if not libraries.has(library):
				libraries.append(library)
			_add_bridge_edge(edges, kinds, descriptor, library, "gdextension_library")
			var target_name := _library_stem(library)
			var target: Dictionary = _matching_native_target(targets, target_name)
			if target.is_empty():
				continue
			var manifest := String(target.get("manifest", ""))
			if manifest != "":
				_add_bridge_edge(edges, kinds, library, manifest, "native_build_target")
			for source_any in target.get("sources", []):
				var source := String(source_any)
				_add_bridge_edge(edges, kinds, library, source, "native_source")
			# Only registrations compiled into this target can expose a class
			# through this particular generated library.
			var target_sources: Array = target.get("sources", [])
			for class_any in registrations:
				var registered_name := String(class_any)
				var registration_source := String(registrations[registered_name])
				if registration_source in target_sources:
					class_libraries[registered_name] = library

	return {
		"edges": edges, "kinds": kinds,
		"class_libraries": class_libraries, "libraries": libraries,
	}


## Explicit dynamic-library loads used by managed/native interop. This is
## intentionally limited to well-known loader calls rather than treating
## every matching string literal as executable evidence.
static func native_library_references(content: String, libraries: Array) -> Array:
	var out: Array = []
	var regex := RegEx.new()
	regex.compile("(?is)(?:DllImport|LibraryImport|NativeLibrary\\.Load|dlopen|LoadLibrary(?:A|W)?)[^\\(]*\\([ \\t\\r\\n]*[\\\"']([^\\\"']+)[\\\"']")
	for match_any in regex.search_all(content):
		var requested := _library_stem(String((match_any as RegExMatch).get_string(1)))
		for library_any in libraries:
			var library := String(library_any)
			var available := _library_stem(library)
			if requested == available or requested.begins_with(available + "_"):
				if not out.has(library):
					out.append(library)
	return out


static func gdextension_library_paths(descriptor: String, content: String,
		file_set: Dictionary, basename_index: Dictionary) -> Array:
	return _gdextension_libraries(descriptor, content, file_set, basename_index)


static func _gdextension_libraries(descriptor: String, content: String,
		file_set: Dictionary, basename_index: Dictionary) -> Array:
	var out: Array = []
	var in_libraries := false
	for line_any in content.split("\n"):
		var line := String(line_any).strip_edges()
		if line.begins_with("["):
			in_libraries = line == "[libraries]"
			continue
		if not in_libraries or line == "" or line.begins_with(";") or line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq == -1:
			continue
		var value := line.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		var resolved := ""
		if value.begins_with("res://") and file_set.has(value):
			resolved = value
		else:
			resolved = _resolve_include(descriptor, value, file_set, basename_index)
		if resolved != "" and not out.has(resolved):
			out.append(resolved)
	return out


static func _native_build_targets(contents: Dictionary, file_set: Dictionary,
		basename_index: Dictionary) -> Dictionary:
	var targets := {}
	for key_any in contents:
		var manifest: String = key_any
		if not is_build_file(manifest):
			continue
		var content := String(contents[manifest])
		# CMake's add_library/add_executable calls provide the strongest
		# target-to-source evidence and cover the common GDExtension setup.
		var cmake := RegEx.new()
		cmake.compile("(?is)add_(?:library|executable)[ \\t\\r\\n]*\\(([^\\)]+)\\)")
		for match_any in cmake.search_all(content):
			var body := String((match_any as RegExMatch).get_string(1))
			var tokens := _build_tokens(body)
			if tokens.is_empty():
				continue
			var target_name := String(tokens[0])
			var sources := _resolve_build_sources(manifest, tokens.slice(1), file_set, basename_index)
			targets[target_name] = {"manifest": manifest, "sources": sources}
		var target_sources_regex := RegEx.new()
		target_sources_regex.compile("(?is)target_sources[ \\t\\r\\n]*\\(([^\\)]+)\\)")
		for match_any in target_sources_regex.search_all(content):
			var tokens := _build_tokens(String((match_any as RegExMatch).get_string(1)))
			if tokens.is_empty():
				continue
			var target_name := String(tokens[0])
			if not targets.has(target_name):
				continue
			var definition: Dictionary = targets[target_name]
			var sources: Array = definition.get("sources", [])
			for source_any in _resolve_build_sources(
				manifest, tokens.slice(1), file_set, basename_index
			):
				if not source_any in sources:
					sources.append(source_any)
			definition["sources"] = sources

		# SCons SharedLibrary/Library calls. Supports classic
		# SharedLibrary("name", [a.cpp]) plus VoxelPlus-style
		# SharedLibrary("bin/name{}{}".format(...), source=sources) where
		# sources = Glob("src/*.cpp").
		for call_any in _extract_named_calls(content, ["SharedLibrary", "Library"]):
			var call: Dictionary = call_any
			var body := String(call.get("body", ""))
			var target_raw := _first_string_literal(body)
			if target_raw == "":
				continue
			var target_key := _library_stem(_strip_format_placeholders(target_raw))
			if target_key == "":
				continue
			var source_tokens := _scons_source_tokens(body, content)
			var sources := _resolve_build_sources(
				manifest, source_tokens, file_set, basename_index
			)
			for globbed_any in _files_matching_globs(
				manifest, _extract_glob_patterns_from_tokens(source_tokens, content), file_set
			):
				var globbed_source := String(globbed_any)
				if not globbed_source in sources:
					sources.append(globbed_source)
			targets[target_key] = {"manifest": manifest, "sources": sources}
			# Also index the unstemmed path basename so OUTPUT-style aliases
			# and unusual stems still resolve.
			var raw_stem := _strip_format_placeholders(target_raw).get_file().get_basename()
			if raw_stem != "" and not targets.has(raw_stem):
				targets[raw_stem] = targets[target_key]

		# Meson literal form: shared_library('name', 'a.cpp', 'b.cpp').
		var meson := RegEx.new()
		meson.compile("(?is)shared_library[ \\t\\r\\n]*\\([ \\t\\r\\n]*[\\\"']([^\\\"']+)[\\\"'][ \\t\\r\\n]*,[ \\t\\r\\n]*([^\\)]*)\\)")
		for match_any in meson.search_all(content):
			var match: RegExMatch = match_any
			var target_name := String(match.get_string(1))
			var sources := _resolve_build_sources(
				manifest, _build_tokens(match.get_string(2)), file_set, basename_index
			)
			targets[target_name] = {"manifest": manifest, "sources": sources}

		# CMake may deliberately make the on-disk library name differ from
		# the logical target name.
		var output_name := RegEx.new()
		output_name.compile("(?is)set_target_properties[ \\t\\r\\n]*\\([ \\t\\r\\n]*([A-Za-z0-9_.+-]+).*?OUTPUT_NAME[ \\t\\r\\n]+[\\\"']?([A-Za-z0-9_.+-]+)")
		for match_any in output_name.search_all(content):
			var match: RegExMatch = match_any
			var target_name := String(match.get_string(1))
			var alias := String(match.get_string(2))
			if targets.has(target_name) and not targets.has(alias):
				targets[alias] = targets[target_name]
	return targets


static func _native_registrations(contents: Dictionary, symbol_index: Dictionary) -> Dictionary:
	var out := {}
	var patterns := [
		"(?:ClassDB::register_(?:abstract_)?class|GDREGISTER_CLASS)[ \\t\\r\\n]*(?:<|\\()[ \\t\\r\\n]*([A-Za-z_][A-Za-z0-9_:]*)",
	]
	for key_any in contents:
		var path: String = key_any
		if not path.get_extension().to_lower() in NATIVE_EXTENSIONS:
			continue
		var clean := strip_comments_and_strings(String(contents[path]), false)
		for pattern in patterns:
			var regex := RegEx.new()
			if regex.compile(pattern) != OK:
				continue
			for match_any in regex.search_all(clean):
				var registered_name := _unqualify(String((match_any as RegExMatch).get_string(1)))
				if symbol_index.has(registered_name):
					out[registered_name] = path
	return out


static func _build_tokens(body: String) -> Array:
	var normalised := body.replace("\n", " ").replace("\r", " ").replace("\t", " ")
	for character in ["\"", "'", "[", "]", ","]:
		normalised = normalised.replace(character, " ")
	var out: Array = []
	for token_any in normalised.split(" ", false):
		var token := String(token_any).strip_edges()
		if token != "":
			out.append(token)
	return out


static func _resolve_build_sources(manifest: String, tokens: Array,
		file_set: Dictionary, basename_index: Dictionary) -> Array:
	var ignored := ["STATIC", "SHARED", "MODULE", "OBJECT", "INTERFACE", "EXCLUDE_FROM_ALL",
		"WIN32", "MACOSX_BUNDLE", "PRIVATE", "PUBLIC"]
	var out: Array = []
	for token_any in tokens:
		var token := String(token_any)
		if token in ignored or token.begins_with("$") or token.begins_with("-"):
			continue
		var resolved := _resolve_include(manifest, token, file_set, basename_index)
		if resolved != "" and resolved.get_extension().to_lower() in NATIVE_EXTENSIONS:
			if not out.has(resolved):
				out.append(resolved)
	return out


static func _library_stem(path: String) -> String:
	var stem := path.get_file().get_basename()
	if stem.begins_with("lib"):
		stem = stem.trim_prefix("lib")
	# Godot's recommended output layout commonly uses names such as
	# libdemo.linux.template_debug.x86_64.so.
	if "." in stem:
		stem = stem.get_slice(".", 0)
	return stem


static func _matching_native_target(targets: Dictionary, library_stem: String) -> Dictionary:
	if targets.has(library_stem):
		return targets[library_stem]
	var matches: Array = []
	for key_any in targets:
		var target_name := String(key_any)
		if library_stem.begins_with(target_name + "_"):
			matches.append(target_name)
	if matches.size() == 1:
		return targets[matches[0]]
	return {}


static func _add_bridge_edge(edges: Dictionary, kinds: Dictionary,
		source: String, target: String, kind: String) -> void:
	if source == "" or target == "" or source == target:
		return
	if not edges.has(source):
		edges[source] = []
	if not target in edges[source]:
		edges[source].append(target)
	if not kinds.has(source):
		kinds[source] = {}
	kinds[source][target] = kind


static func hierarchy(contents: Dictionary, symbol_index: Dictionary) -> Dictionary:
	var parent_of := {}
	var class_of := {}
	for key_any in contents.keys():
		var path: String = key_any
		for declaration_any in declarations(path, String(contents[path])):
			var declaration: Dictionary = declaration_any
			var name := String(declaration.get("name", ""))
			var parent := String(declaration.get("parent", ""))
			if name != "":
				class_of[path] = name
			if parent != "" and symbol_index.has(parent):
				var parent_path: String = symbol_index[parent]
				if parent_path != path and _same_language_family(path, parent_path):
					parent_of[path] = parent_path
	return {"parent_of": parent_of, "class_of": class_of}


static func strip_comments_and_strings(content: String, keep_strings: bool) -> String:
	var out := ""
	var i := 0
	var in_line_comment := false
	var in_block_comment := false
	var in_string := false
	var quote := ""
	while i < content.length():
		var c: String = content[i]
		var next := content[i + 1] if i + 1 < content.length() else ""
		if in_line_comment:
			if c == "\\n":
				in_line_comment = false
				out += "\\n"
			else:
				out += " "
			i += 1
			continue
		if in_block_comment:
			if c == "*" and next == "/":
				in_block_comment = false
				out += "  "
				i += 2
			else:
				out += "\\n" if c == "\\n" else " "
				i += 1
			continue
		if in_string:
			if c == "\\\\":
				out += content.substr(i, 2) if keep_strings else "  "
				i += 2
				continue
			if c == quote:
				in_string = false
			out += c if keep_strings else ("\\n" if c == "\\n" else " ")
			i += 1
			continue
		if c == "/" and next == "/":
			in_line_comment = true
			out += "  "
			i += 2
			continue
		if c == "/" and next == "*":
			in_block_comment = true
			out += "  "
			i += 2
			continue
		if c == "\\\"" or c == "'":
			in_string = true
			quote = c
			out += c if keep_strings else " "
			i += 1
			continue
		out += c
		i += 1
	return out


static func _unqualify(name: String) -> String:
	var normalised := name.replace("::", ".")
	var pieces := normalised.split(".")
	return String(pieces[pieces.size() - 1]) if not pieces.is_empty() else ""


static func _same_language_family(first: String, second: String) -> bool:
	var first_ext := first.get_extension().to_lower()
	var second_ext := second.get_extension().to_lower()
	return (
		(first_ext in CSHARP_EXTENSIONS and second_ext in CSHARP_EXTENSIONS)
		or (first_ext in NATIVE_EXTENSIONS and second_ext in NATIVE_EXTENSIONS)
	)


static func _resolve_include(path: String, include_name: String, file_set: Dictionary, basename_index: Dictionary) -> String:
	var local := path.get_base_dir().path_join(include_name).simplify_path()
	if file_set.has(local):
		return local
	var base := include_name.replace("\\\\", "/").get_file()
	var candidates: Array = basename_index.get(base, [])
	if candidates.size() == 1:
		return String(candidates[0])
	return ""


static func _word_contains(content: String, word: String) -> bool:
	var idx := content.find(word)
	while idx != -1:
		var before_ok := idx == 0 or IDENT_CHARS.find(content[idx - 1]) == -1
		var after := idx + word.length()
		var after_ok := after >= content.length() or IDENT_CHARS.find(content[after]) == -1
		if before_ok and after_ok:
			return true
		idx = content.find(word, idx + 1)
	return false


## Parses Godot's .godot/extension_list.cfg. Each non-empty, non-comment line
## is a res:// path to an enabled .gdextension descriptor.
static func parse_extension_list(content: String) -> Array:
	var out: Array = []
	for line_any in content.split("\n"):
		var line := String(line_any).strip_edges()
		if line == "" or line.begins_with(";") or line.begins_with("#"):
			continue
		if line.begins_with("res://") and line.get_extension().to_lower() == "gdextension":
			if not out.has(line):
				out.append(line)
	return out


## When the atlas runs inside the project that loaded the extension, ClassDB
## already knows every exported native class. Attribute those classes to the
## generated libraries (single-library projects map 1:1; multi-library keeps
## existing register_types attribution and only fills gaps).
static func class_libraries_from_classdb(
	libraries: Array, existing_class_libraries: Dictionary
) -> Dictionary:
	var out := {}
	if libraries.is_empty():
		return out
	for class_any in ClassDB.get_class_list():
		var cls_name := String(class_any)
		if ClassDB.class_get_api_type(cls_name) != ClassDB.API_EXTENSION:
			continue
		if existing_class_libraries.has(cls_name):
			out[cls_name] = String(existing_class_libraries[cls_name])
			continue
		if libraries.size() == 1:
			out[cls_name] = String(libraries[0])
	return out


## Method names exported by a ClassDB class (public only). Used as scan
## metadata so the Selection panel can show what the loaded binary provides.
static func classdb_public_methods(cls_name: String) -> Array:
	var out: Array = []
	if not ClassDB.class_exists(cls_name):
		return out
	for method_any in ClassDB.class_get_method_list(cls_name, true):
		var method: Dictionary = method_any
		var name := String(method.get("name", ""))
		if name == "" or name.begins_with("_"):
			continue
		if not out.has(name):
			out.append(name)
	out.sort()
	return out


## Scene/resource node types that refer to a registered native class.
static func native_types_in_resource(content: String, class_libraries: Dictionary) -> Array:
	var out: Array = []
	if class_libraries.is_empty() or content == "":
		return out
	var regex := RegEx.new()
	if regex.compile("(?m)^\\[node\\b[^\\]]*\\btype\\s*=\\s*\\\"([A-Za-z_][A-Za-z0-9_]*)\\\"") != OK:
		return out
	for match_any in regex.search_all(content):
		var type_name := String((match_any as RegExMatch).get_string(1))
		if class_libraries.has(type_name) and not out.has(type_name):
			out.append(type_name)
	return out


static func _strip_format_placeholders(text: String) -> String:
	var out := text
	var regex := RegEx.new()
	if regex.compile("\\{[^}]*\\}") == OK:
		out = regex.sub(out, "", true)
	while out.contains("{}"):
		out = out.replace("{}", "")
	return out


static func _first_string_literal(body: String) -> String:
	var regex := RegEx.new()
	if regex.compile("[\\\"']([^\\\"']+)[\\\"']") != OK:
		return ""
	var match := regex.search(body)
	return String(match.get_string(1)) if match != null else ""


## Pulls source tokens from a SharedLibrary call body: keyword source=...,
## positional second argument lists, Glob("...") calls, and bare identifiers
## that name a Glob assignment elsewhere in the manifest.
static func _scons_source_tokens(call_body: String, manifest_content: String) -> Array:
	var tokens: Array = []
	var source_kw := RegEx.new()
	source_kw.compile("(?is)\\bsource\\s*=\\s*([^,\\)]+)")
	var kw_match := source_kw.search(call_body)
	var source_expr := ""
	if kw_match != null:
		source_expr = String(kw_match.get_string(1)).strip_edges()
	else:
		# Positional: SharedLibrary("name", <sources>)
		var first_string_end := -1
		var quote_regex := RegEx.new()
		quote_regex.compile("[\\\"'][^\\\"']+[\\\"']")
		var first_quote := quote_regex.search(call_body)
		if first_quote != null:
			first_string_end = first_quote.get_end()
			var remainder := call_body.substr(first_string_end).strip_edges()
			# Skip optional .format(...) after the first string.
			if remainder.begins_with("."):
				var format_call := _extract_leading_call(remainder)
				if not format_call.is_empty():
					remainder = remainder.substr(int(format_call.get("end", 0))).strip_edges()
			if remainder.begins_with(","):
				source_expr = remainder.substr(1).strip_edges()
	if source_expr == "":
		return tokens
	# Inline Glob("...") in the source expression takes precedence over
	# tokenising the call (which would smash Glob( into bare words).
	var inline_globs := _extract_glob_patterns(source_expr)
	if not inline_globs.is_empty():
		for pattern_any in inline_globs:
			tokens.append(String(pattern_any))
		return tokens
	for token_any in _build_tokens(source_expr):
		tokens.append(String(token_any))
	# Identifiers that refer to Glob(...) assignments in the same file.
	var glob_vars := _scons_glob_assignments(manifest_content)
	var expanded: Array = []
	for token_any2 in tokens:
		var token := String(token_any2)
		if glob_vars.has(token):
			for pattern_any in glob_vars[token]:
				expanded.append(String(pattern_any))
		else:
			expanded.append(token)
	return expanded


static func _extract_glob_patterns_from_tokens(tokens: Array, _manifest_content: String) -> Array:
	var patterns: Array = []
	for token_any in tokens:
		var token := String(token_any)
		if "*" in token and not patterns.has(token):
			patterns.append(token)
		for pattern_any in _extract_glob_patterns(token):
			var pattern := String(pattern_any)
			if pattern != "" and not patterns.has(pattern):
				patterns.append(pattern)
	return patterns


static func _scons_glob_assignments(content: String) -> Dictionary:
	var out := {}
	var regex := RegEx.new()
	if regex.compile("(?m)^[ \\t]*([A-Za-z_][A-Za-z0-9_]*)[ \\t]*=[ \\t]*Glob[ \\t]*\\([ \\t]*[\\\"']([^\\\"']+)[\\\"']") != OK:
		return out
	for match_any in regex.search_all(content):
		var match: RegExMatch = match_any
		var var_name := String(match.get_string(1))
		var pattern := String(match.get_string(2))
		if not out.has(var_name):
			out[var_name] = []
		(out[var_name] as Array).append(pattern)
	return out


static func _extract_glob_patterns(content: String) -> Array:
	var out: Array = []
	var regex := RegEx.new()
	if regex.compile("(?is)Glob[ \\t]*\\([ \\t]*[\\\"']([^\\\"']+)[\\\"']") != OK:
		return out
	for match_any in regex.search_all(content):
		var pattern := String((match_any as RegExMatch).get_string(1))
		if pattern != "" and not out.has(pattern):
			out.append(pattern)
	return out


static func _files_matching_globs(manifest: String, patterns: Array, file_set: Dictionary) -> Array:
	var out: Array = []
	var build_base := manifest.get_base_dir()
	var prefix := build_base if build_base.ends_with("/") else build_base + "/"
	for pattern_any in patterns:
		var pattern := String(pattern_any).replace("\\", "/")
		if pattern == "":
			continue
		var recursive := "**" in pattern
		var normalised := pattern.replace("**/", "").replace("**", "")
		var slash := normalised.rfind("/")
		var dir_part := normalised.substr(0, slash) if slash != -1 else ""
		var file_part := normalised.substr(slash + 1) if slash != -1 else normalised
		var required_ext := ""
		if file_part.begins_with("*.") and file_part.find("*", 2) == -1:
			required_ext = file_part.substr(2).to_lower()
		var dir_prefix := prefix
		if dir_part != "":
			dir_prefix = prefix.path_join(dir_part)
			if not dir_prefix.ends_with("/"):
				dir_prefix += "/"
		for candidate_any in file_set.keys():
			var candidate: String = candidate_any
			if candidate == manifest:
				continue
			if not candidate.begins_with(prefix):
				continue
			if required_ext != "" and candidate.get_extension().to_lower() != required_ext:
				continue
			if dir_part != "":
				if recursive:
					if not (candidate.begins_with(dir_prefix) or candidate.get_base_dir() == dir_prefix.trim_suffix("/")):
						continue
				else:
					# Glob("src/*.cpp") → only files directly in src/
					var expected_dir := prefix.path_join(dir_part).simplify_path()
					if candidate.get_base_dir() != expected_dir:
						continue
			elif not recursive and required_ext != "":
				# Glob("*.cpp") beside the manifest
				if candidate.get_base_dir() != build_base:
					continue
			if not out.has(candidate):
				out.append(candidate)
	return out


static func _extract_named_calls(content: String, names: Array) -> Array:
	var out: Array = []
	for name_any in names:
		var name := String(name_any)
		var search_from := 0
		while true:
			var idx := content.find(name, search_from)
			if idx == -1:
				break
			var before_ok := idx == 0 or IDENT_CHARS.find(content[idx - 1]) == -1
			var after := idx + name.length()
			var after_ok := after < content.length() and (content[after] == "(" or content[after] in " \t\r\n")
			if not (before_ok and after_ok):
				search_from = idx + name.length()
				continue
			# Advance to opening paren.
			var paren := content.find("(", after)
			if paren == -1:
				break
			var depth := 0
			var i := paren
			var in_string := false
			var quote := ""
			while i < content.length():
				var c := content[i]
				if in_string:
					if c == "\\" and i + 1 < content.length():
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
				if c == "(":
					depth += 1
				elif c == ")":
					depth -= 1
					if depth == 0:
						out.append({
							"name": name,
							"body": content.substr(paren + 1, i - paren - 1),
							"start": idx,
							"end": i + 1,
						})
						search_from = i + 1
						break
				i += 1
			if depth != 0:
				search_from = paren + 1
	return out


static func _extract_leading_call(text: String) -> Dictionary:
	var stripped := text.strip_edges()
	if not stripped.begins_with("."):
		return {}
	var name_start := 1
	while name_start < stripped.length() and IDENT_CHARS.find(stripped[name_start]) != -1:
		name_start += 1
	# Find '(' after .name
	var paren := stripped.find("(", 1)
	if paren == -1:
		return {}
	var depth := 0
	var i := paren
	var in_string := false
	var quote := ""
	while i < stripped.length():
		var c := stripped[i]
		if in_string:
			if c == "\\" and i + 1 < stripped.length():
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
		if c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
			if depth == 0:
				return {"end": i + 1, "body": stripped.substr(paren + 1, i - paren - 1)}
		i += 1
	return {}
