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

	if ext in SOURCE_EXTENSIONS:
		for symbol_any in symbol_index.keys():
			var symbol: String = symbol_any
			var target: String = symbol_index[symbol]
			if target != path and _word_contains(clean, symbol):
				found[target] = true
				if not kinds.has(target):
					kinds[target] = "type"

	# Build languages commonly list sources without quotes (CMake and Meson)
	# or via extension globs (SCons). Match only known project files, so a
	# compiler flag or library name cannot invent a dependency.
	if is_build_file(path):
		var build_base := path.get_base_dir()
		for candidate_any in file_set.keys():
			var candidate: String = candidate_any
			if candidate == path:
				continue
			var candidate_ext := candidate.get_extension().to_lower()
			if not (candidate_ext in SOURCE_EXTENSIONS or candidate_ext in BUILD_EXTENSIONS):
				continue
			var relative := candidate.trim_prefix(build_base + "/")
			var explicitly_listed := content.contains(relative) or content.contains(candidate.get_file())
			var globbed := candidate.begins_with(build_base + "/") and (content.contains("*." + candidate_ext) or content.contains("**/*." + candidate_ext))
			if explicitly_listed or globbed:
				found[candidate] = true
				kinds[candidate] = "build"

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
				if parent_path != path:
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
