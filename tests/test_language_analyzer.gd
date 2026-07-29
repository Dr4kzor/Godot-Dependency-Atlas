extends SceneTree

const Analyzer = preload("res://addons/orphan_finder/language_analyzer.gd")
var failures := 0

func _initialize() -> void:
	_test_csharp()
	_test_cpp()
	_test_build_roots()
	if failures == 0:
		print("Language analyzer: all tests passed")
	quit(failures)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _test_csharp() -> void:
	var base_path := "res://src/BaseTool.cs"
	var child_path := "res://src/PaintTool.cs"
	var contents := {
		base_path: "public abstract class BaseTool {}",
		child_path: "namespace Demo; public partial class PaintTool : BaseTool { BaseTool owner; }",
	}
	var symbols := Analyzer.build_symbol_index(contents)
	_expect(symbols.get("BaseTool", "") == base_path, "C#: base declaration was not indexed")
	_expect(symbols.get("PaintTool", "") == child_path, "C#: partial declaration was not indexed")
	var hierarchy := Analyzer.hierarchy(contents, symbols)
	_expect(hierarchy.parent_of.get(child_path, "") == base_path, "C#: inheritance was not resolved")
	var refs := Analyzer.references(child_path, contents[child_path], {base_path: true, child_path: true}, {}, symbols)
	_expect(base_path in refs.files, "C#: typed source reference was not found")

func _test_cpp() -> void:
	var base_path := "res://native/base.hpp"
	var child_path := "res://native/paint.cpp"
	var contents := {
		base_path: "class BaseTool {};",
		child_path: "#include \"base.hpp\"\nclass PaintTool : public BaseTool {};",
	}
	var files := {base_path: true, child_path: true}
	var basenames := {"base.hpp": [base_path], "paint.cpp": [child_path]}
	var symbols := Analyzer.build_symbol_index(contents)
	var refs := Analyzer.references(child_path, contents[child_path], files, basenames, symbols)
	_expect(base_path in refs.files, "C++: quoted include was not resolved")
	_expect(refs.kinds.get(base_path, "") == "include", "C++: include edge kind was not retained")
	var hierarchy := Analyzer.hierarchy(contents, symbols)
	_expect(hierarchy.parent_of.get(child_path, "") == base_path, "C++: public inheritance was not resolved")

func _test_build_roots() -> void:
	var project := "res://Game.csproj"
	var cs := "res://Player.cs"
	var gdext := "res://native/game.gdextension"
	var cmake := "res://native/CMakeLists.txt"
	var cpp := "res://native/game.cpp"
	var files := {project: true, cs: true, gdext: true, cmake: true, cpp: true}
	var roots := Analyzer.build_roots(files)
	var root_paths := []
	for root_any in roots:
		root_paths.append(String((root_any as Dictionary).path))
	_expect(project in root_paths, "Build: C# project was not made a root")
	_expect(gdext in root_paths, "Build: GDExtension descriptor was not made a root")
	_expect(cmake in root_paths, "Build: GDExtension native manifest was not made a root")
	var members := Analyzer.implicit_build_members(project, '<Project Sdk="Godot.NET.Sdk/4.7.0"></Project>', files)
	_expect(cs in members, "Build: root-level SDK-style implicit C# compile membership was missed")
