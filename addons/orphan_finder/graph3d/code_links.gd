@tool
extends RefCounted

## For a single script, counts how many DISTINCT LINES OF CODE reach each
## other file. This turns a binary "A references B" edge into a weighted one:
## touching a file on 30 separate lines is a very different dependency from
## touching it once.
##
## What counts as a touch on a line:
##   - a res:// or uid:// literal resolving to that file
##   - a global class_name belonging to that file, used as a whole word
##   - a member access (`thing.method()`) on a variable that was bound to
##     that file earlier in the script
##
## Variable binding is tracked from declarations, which is what lets
## `inventory.take(n)` be attributed to inventory.gd:
##   const Foo = preload("res://foo.gd")
##   var x: SomeClass
##   var x = SomeClass.new()
##   func f(param: SomeClass)
##
## Deliberate non-goals: this does not care whether a line actually executes,
## how often, or what the other file does in response. Control flow,
## recursion and reachability are all irrelevant here -- the question is only
## "how many places in this file are wired to that one", which is what makes
## it a usable coupling weight.
##
## Comments are stripped before analysis, so a commented-out call doesn't
## count. String literals are kept, because res:// paths live inside them.

const IDENT_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
const PATH_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-"


## Returns { target_path: PackedInt32Array of 1-based line numbers }.
static func analyze(
	content: String, class_to_path: Dictionary, file_set: Dictionary
) -> Dictionary:
	var raw_lines := content.split("\n")
	var lines: Array = []
	for l in raw_lines:
		lines.append(_strip_comment(String(l)))

	var bindings := _extract_bindings(lines, class_to_path, file_set)

	# Only scan for classes that appear somewhere in the file at all --
	# checking every known class against every line would be needlessly slow
	# on projects with hundreds of global classes.
	var present_classes := {}
	for key in class_to_path.keys():
		var cls: String = key
		if content.find(cls) != -1:
			present_classes[cls] = String(class_to_path[cls])

	var hits := {}
	for i in lines.size():
		var line: String = lines[i]
		if line.strip_edges() == "":
			continue
		var touched := {}

		for token in _res_tokens(line):
			var resolved := _longest_known(String(token), file_set)
			if resolved != "":
				touched[resolved] = true

		for key2 in present_classes.keys():
			var cls2: String = key2
			if _word_contains(line, cls2):
				touched[String(present_classes[cls2])] = true

		for key3 in bindings.keys():
			var var_name: String = key3
			if _has_member_access(line, var_name):
				touched[String(bindings[var_name])] = true

		for key4 in touched.keys():
			var target: String = key4
			if not hits.has(target):
				hits[target] = PackedInt32Array()
			var arr: PackedInt32Array = hits[target]
			arr.append(i + 1)
			hits[target] = arr

	return hits


static func _strip_comment(line: String) -> String:
	var out := ""
	var i := 0
	var in_string := false
	var quote := ""
	while i < line.length():
		var c: String = line[i]
		if in_string:
			if c == "\\":
				out += line.substr(i, 2)
				i += 2
				continue
			if c == quote:
				in_string = false
			out += c
			i += 1
			continue
		if c == "\"" or c == "'":
			in_string = true
			quote = c
			out += c
			i += 1
			continue
		if c == "#":
			break
		out += c
		i += 1
	return out


## Maps local identifiers to the file they represent, so later member
## accesses on them can be attributed correctly.
static func _extract_bindings(lines: Array, class_to_path: Dictionary, file_set: Dictionary) -> Dictionary:
	var bindings := {}
	for l in lines:
		var line: String = String(l).strip_edges()

		if line.begins_with("func "):
			_bind_params(line, class_to_path, bindings)
			continue

		var decl := line
		if decl.begins_with("@onready "):
			decl = decl.substr(9).strip_edges()
		if not (decl.begins_with("var ") or decl.begins_with("const ")):
			continue

		var after_keyword := decl.substr(decl.find(" ") + 1).strip_edges()
		var name := _read_identifier(after_keyword, 0)
		if name == "":
			continue

		# const Foo = preload("res://foo.gd")
		var path := _first_known_path(decl, file_set)
		if path != "":
			bindings[name] = path
			continue

		# var x: SomeClass
		var colon := decl.find(":", decl.find(name) + name.length())
		if colon != -1:
			var type_name := _read_identifier(decl, _skip_spaces(decl, colon + 1))
			if class_to_path.has(type_name):
				bindings[name] = String(class_to_path[type_name])
				continue

		# var x = SomeClass.new()
		var ctor := _constructed_class(decl, class_to_path)
		if ctor != "":
			bindings[name] = String(class_to_path[ctor])
	return bindings


static func _bind_params(line: String, class_to_path: Dictionary, bindings: Dictionary) -> void:
	var open_paren := line.find("(")
	var close_paren := line.rfind(")")
	if open_paren == -1 or close_paren <= open_paren:
		return
	var params := line.substr(open_paren + 1, close_paren - open_paren - 1)
	for part in params.split(","):
		var p: String = String(part).strip_edges()
		var colon := p.find(":")
		if colon == -1:
			continue
		var pname := _read_identifier(p, 0)
		var ptype := _read_identifier(p, _skip_spaces(p, colon + 1))
		if pname != "" and class_to_path.has(ptype):
			if not bindings.has(pname):
				bindings[pname] = String(class_to_path[ptype])


static func _constructed_class(line: String, class_to_path: Dictionary) -> String:
	var idx := line.find(".new(")
	while idx != -1:
		var start := idx
		while start > 0 and IDENT_CHARS.find(line[start - 1]) != -1:
			start -= 1
		var candidate := line.substr(start, idx - start)
		if class_to_path.has(candidate):
			return candidate
		idx = line.find(".new(", idx + 1)
	return ""


static func _first_known_path(line: String, file_set: Dictionary) -> String:
	for token in _res_tokens(line):
		var resolved := _longest_known(String(token), file_set)
		if resolved != "":
			return resolved
	return ""


static func _res_tokens(line: String) -> Array:
	var tokens: Array = []
	var idx := line.find("res://")
	while idx != -1:
		var end := idx
		while end < line.length() and PATH_CHARS.find(line[end]) != -1:
			end += 1
		if end > idx + 6:
			tokens.append(line.substr(idx, end - idx))
		idx = line.find("res://", idx + 6)
	return tokens


static func _longest_known(token: String, known: Dictionary) -> String:
	var candidate := token
	while candidate.length() > 6:
		if known.has(candidate):
			return candidate
		candidate = candidate.substr(0, candidate.length() - 1)
	return ""


## True when the line contains `name.` as a member access -- the pattern that
## means this line is actually using the bound object.
static func _has_member_access(line: String, name: String) -> bool:
	var idx := line.find(name)
	while idx != -1:
		var before_ok := idx == 0 or IDENT_CHARS.find(line[idx - 1]) == -1
		var after := idx + name.length()
		if before_ok and after < line.length():
			var j := _skip_spaces(line, after)
			if j < line.length() and line[j] == ".":
				return true
		idx = line.find(name, idx + 1)
	return false


static func _word_contains(line: String, word: String) -> bool:
	if word == "":
		return false
	var idx := line.find(word)
	while idx != -1:
		var before_ok := idx == 0 or IDENT_CHARS.find(line[idx - 1]) == -1
		var after := idx + word.length()
		var after_ok := after >= line.length() or IDENT_CHARS.find(line[after]) == -1
		if before_ok and after_ok:
			return true
		idx = line.find(word, idx + 1)
	return false


static func _read_identifier(text: String, from: int) -> String:
	var i := from
	var out := ""
	while i < text.length() and IDENT_CHARS.find(text[i]) != -1:
		out += text[i]
		i += 1
	return out


static func _skip_spaces(text: String, from: int) -> int:
	var i := from
	while i < text.length() and (text[i] == " " or text[i] == "\t"):
		i += 1
	return i
