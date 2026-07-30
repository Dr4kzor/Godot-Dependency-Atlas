extends SceneTree

const Analyzer = preload("res://addons/godot_dependency_atlas/language_analyzer.gd")
var failures := 0

func _initialize() -> void:
	_test_csharp()
	_test_cpp()
	_test_language_boundaries()
	_test_build_roots()
	_test_native_bridge()
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


func _test_language_boundaries() -> void:
	var header := "res://legacy/ModelGenerator.hpp"
	var gdscript := "res://model_generator.gd"
	var csharp := "res://managed/Consumer.cs"
	var contents := {
		header: "class MODEL_GENERATOR_REFRACTOR {};",
		gdscript: "class_name MODEL_GENERATOR_REFRACTOR\nextends Node\n",
		csharp: "public class Consumer { MODEL_GENERATOR_REFRACTOR value; }",
	}
	var files := {header: true, gdscript: true, csharp: true}
	var symbols := Analyzer.build_symbol_index(contents)
	var gd_refs := Analyzer.references(
		gdscript, contents[gdscript], files, {}, symbols
	)
	var cs_refs := Analyzer.references(
		csharp, contents[csharp], files, {}, symbols
	)
	_expect(
		not header in gd_refs.files,
		"Languages: GDScript identifier leaked into a same-named C++ header"
	)
	_expect(
		not header in cs_refs.files,
		"Languages: C# identifier leaked into a same-named C++ header"
	)


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


func _test_native_bridge() -> void:
	var descriptor := "res://native/demo.gdextension"
	var library := "res://native/bin/libdemo.so"
	var manifest := "res://native/CMakeLists.txt"
	var source := "res://native/child.cpp"
	var registration := "res://native/register_types.cpp"
	var contents := {
		descriptor: '[libraries]\nlinux.debug.x86_64 = "res://native/bin/libdemo.so"',
		manifest: "add_library(demo SHARED child.cpp register_types.cpp)",
		source: "class NativeChild {};",
		registration: "void init() { ClassDB::register_class<NativeChild>(); }",
	}
	var files := {
		descriptor: true, library: true, manifest: true, source: true,
		registration: true,
	}
	var basenames := {
		"libdemo.so": [library], "child.cpp": [source],
		"register_types.cpp": [registration],
	}
	var symbols := Analyzer.build_symbol_index(contents)
	var bridge := Analyzer.native_bridge(contents, files, basenames, symbols)
	var edges: Dictionary = bridge.edges
	_expect(library in edges.get(descriptor, []), "Native bridge: descriptor did not reach library")
	_expect(manifest in edges.get(library, []), "Native bridge: library did not reach build manifest")
	_expect(source in edges.get(library, []), "Native bridge: library did not reach compiled source")
	_expect(
		bridge.class_libraries.get("NativeChild", "") == library,
		"Native bridge: registered class was not associated with its library"
	)
	_expect(
		library in Analyzer.native_library_references(
			'[DllImport("demo")] static extern void ping();', [library]
		),
		"Native bridge: C# DllImport did not resolve the generated library"
	)
