# Godot Dependency Atlas

Godot Dependency Atlas maps how a Godot project’s scenes, scripts, resources,
native code, and build files relate to one another. It can report files that
are unreachable from the project’s entry points and render the resulting
dependency graph as an interactive 3D scene.

![Godot Dependency Atlas 3D graph](screenshot/Screenshot.png)

The atlas is intended for investigation and informed cleanup. An orphan result
is a review candidate, not proof that a file is safe to delete: static analysis
cannot observe every path assembled or dependency selected at runtime.

## Features

- Traverses outward from the main scene, autoloads, enabled plugins, and other
  detected entry points instead of merely counting filename mentions.
- Separates reachable files, lone orphan candidates, and orphan clusters whose
  files still depend on one another.
- Understands Godot paths, resource UIDs, `class_name`, inheritance, includes,
  type use, build membership, and common project manifests.
- Visualizes dependency and folder layouts in 3D, with selection tracing,
  change-impact analysis, isolation, relation gathering, naming groups, file
  filtering, visibility controls, themes, and layout diagnostics.
- Shows dependency cycles and distinguishes incoming, outgoing, and dangling
  resource connections.
- Scans another Godot project directory without modifying it.
- Moves reviewed orphan files to the operating system trash after explicit
  permission and records the action in an audit log.
- Provides **Move + Refactor** from Godot’s FileSystem dock and from the 3D
  graph’s node and file-tree context menus.
- Saves scan reports, display settings, theme overrides, and custom themes in
  a human-readable project-local directory.

## Installation

1. Copy `addons/godot_dependency_atlas` into the target project.
2. Open **Project → Project Settings → Plugins**.
3. Enable **Godot Dependency Atlas**.

The addon requires Godot 4.3 or newer for its FileSystem context-menu API. This
repository is currently developed and tested with Godot 4.7.

Only one plugin needs to be enabled. The refactor implementation is
compartmentalized under:

```text
addons/godot_dependency_atlas/refactor/
```

## Using the editor panel

Open the **Dependency Atlas** bottom panel or choose
**Project → Tools → Scan with Dependency Atlas**.

Press **Run 3D Atlas** in the bottom panel to launch the interactive graph
directly. There is no need to find and manually run its scene.

The scan reports:

- reachable files and the entry points that led to them;
- orphan candidates never reached from an entry point;
- orphan clusters representing disconnected subsystems;
- unresolved or dynamic references that reduce confidence;
- cycles, highly coupled files, and other graph metrics.

Double-click a result to reveal it in Godot. Reports are saved only when
requested.

Deletion is deliberately gated. Enabling it presents the static-analysis
limitations first, and accepted files are moved to the system trash rather
than permanently erased.

## Using the 3D atlas

Use **Run 3D Atlas** in the Dependency Atlas bottom panel. Alternatively, open
and run the scene directly:

```text
addons/godot_dependency_atlas/graph3d/graph_viewer.tscn
```

The left panel mirrors project files. Click a file or graph node to select it;
double-click to fly to it. Right-click or long-press either a 3D node or a file
entry for its context actions.

Basic navigation:

- `WASD` and mouse: fly
- `Q` / `E`: move down or up
- `Shift`: boost
- Mouse wheel: adjust speed
- `Esc`: release the mouse
- `F` or `Home`: reset the view
- `F1` / `F2`: toggle the file and selection panels
- `F3`: scan another Godot project

The in-view **Help** button documents every toolbar state and shortcut.

### External projects

The 3D viewer can scan a different project directory. That mode is read-only:
moving, refactoring, or deleting a path is disabled because Godot’s active
`res://` still points to the project hosting the viewer. For complete Godot
resource dependency data and mutation tools, install and run the addon inside
the project being inspected.

## Move + Refactor

For the active project, select exactly one file or folder and choose
**Move + Refactor…** from:

- Godot’s FileSystem dock;
- the 3D graph node context menu;
- the 3D viewer’s Project Files context menu.

The tool previews textual references, moves the target, follows `.uid` and
`.import` sidecars, updates matching `res://` references, refreshes Godot’s
filesystem, and rescans the atlas. Progress is shown while references are
being calculated.

Refactor logs are written beneath:

```text
dependency_atlas/refactor_logs/
```

Commit or back up the project before restructuring it. The refactor is
text-based and does not currently prove or rewrite every possible relative,
generated, reflected, or runtime-computed reference.

## Language and build support

The graph recognizes:

- GDScript and Godot scenes/resources;
- C# classes, structs, interfaces, inheritance, type usage, project files, and
  SDK-style implicit compile membership;
- C and C++ includes, types, inheritance, common source/header extensions, and
  GDExtension manifests;
- CMake, SCons, Meson, Visual Studio, C# project, and solution manifests,
  including explicit source paths and common extension globs.

Build membership is represented separately from runtime, include, inheritance,
and type-use relationships. Native source, generated libraries, and scripts
using a GDExtension can therefore appear as a connected chain when the relevant
manifest and binary paths are available in the project.

## Accuracy and safety

Static analysis cannot guarantee that a reported orphan is disposable.
Particular sources of uncertainty include:

- paths assembled at runtime;
- reflection and dynamically loaded classes;
- P/Invoke or native symbols selected only at runtime;
- generated source and generated build manifests;
- preprocessor/platform-specific branches;
- resources referenced only by external tools or data;
- compiled assemblies whose original source relationship is unavailable.

The scanner is intentionally conservative when it finds evidence of use.
Review the incoming/outgoing graph, unresolved-reference warnings, and orphan
cluster before deleting anything. Version control remains the best safety net.

## Project-local data

Settings and reports live in:

```text
dependency_atlas/
├── dependency-atlas.config
├── custom_themes/
├── logs/
├── refactor_logs/
└── deleted.log
```

The configuration and theme JSON are human-readable. Scan logs are ignored by
the generated `.gitignore`; the deletion audit is kept so a team can review
cleanup history.

## Development

The automated scripts can be run with a Godot executable:

```bash
godot --headless --path . --script res://tests/test_language_analyzer.gd
godot --headless --path . --script res://tests/test_multilang_scan.gd
godot --headless --path . --script res://tests/test_theme_store.gd
godot --headless --path . --script res://tests/test_move_refactor.gd
```

The project originated through AI-assisted implementation guided by Ricardo
Dias, followed by manual testing and iterative fixes.

## License

See [LICENSE](LICENSE).
