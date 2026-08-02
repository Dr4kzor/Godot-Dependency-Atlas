# Dependency Atlas — AI map

For coding agents: read this before deleting, moving, renaming, or rewiring Godot assets. Prefer exact `res://` paths listed here. This is a reachability summary, not proof a file is unused at runtime.

Generated: `2026-08-03T00:11:37` · scan_root: `res://` · reachable **16** / **50** · roots **5** · orphans **21** · tangle **38** (notably entangled)

## Agent rules
- A missing `res://.../file` is an unresolved reference — never treat its parent folder as fully live.
- Orphans are review candidates only; check **Uncertainty** and runtime `load()`/`preload()` patterns first.
- Changing a **hub** or anything in a **cycle** has wide blast radius — open dependents before editing.
- GDExtension classes live in the `.so`/`.dll`; GDScript may name them with no `res://` path.
- Sidecars (`.import`, `.uid`) follow their owner; do not reason about them alone.

## Entry points
- `[C# build]` `res://tests/fixtures/multilang_project/Game.csproj`
- `[native build]` `res://tests/fixtures/multilang_project/native/CMakeLists.txt`
- `[native extension]` `res://tests/fixtures/multilang_project/native/demo.gdextension`
- `[native build]` `res://tests/fixtures/multilang_project/native_scons/SConstruct`
- `[native extension]` `res://tests/fixtures/multilang_project/native_scons/voxel_native.gdextension`

## Native / GDExtension
- `res://tests/fixtures/multilang_project/native/demo.gdextension` → `res://tests/fixtures/multilang_project/native/bin/libdemo.so`
- `res://tests/fixtures/multilang_project/native_scons/voxel_native.gdextension` → `res://tests/fixtures/multilang_project/native_scons/bin/voxel_native.linux.template_debug.arm64.so`
- classes → `res://tests/fixtures/multilang_project/native/bin/libdemo.so`: NativeChild
- classes → `res://tests/fixtures/multilang_project/native_scons/bin/voxel_native.linux.template_debug.arm64.so`: VoxelChunk

## Coupling hubs (highest change impact)
- `res://tests/fixtures/multilang_project/native/bin/libdemo.so` — in:4 out:3 hub:12 · **in cycle**
- `res://tests/fixtures/multilang_project/native_scons/bin/voxel_native.linux.template_debug.arm64.so` — in:4 out:3 hub:12 · **in cycle**
- `res://tests/fixtures/multilang_project/native_scons/src/voxel_chunk.cpp` — in:4 out:2 hub:8 · **in cycle**
- `res://tests/fixtures/multilang_project/native/child.cpp` — in:3 out:2 hub:6 · **in cycle**
- `res://tests/fixtures/multilang_project/native_scons/src/register_types.cpp` — in:2 out:3 hub:6 · **in cycle**
- `res://tests/fixtures/multilang_project/native/register_types.cpp` — in:2 out:2 hub:4 · **in cycle**
- `res://tests/fixtures/multilang_project/native_scons/src/voxel_chunk.h` — in:2 out:2 hub:4 · **in cycle**
- `res://tests/fixtures/multilang_project/native/CMakeLists.txt` — in:1 out:2 hub:2 · **in cycle**
- `res://tests/fixtures/multilang_project/native_scons/SConstruct` — in:1 out:2 hub:2 · **in cycle**

## Dependency cycles
- cycle 1 (5 files):
  - `res://tests/fixtures/multilang_project/native_scons/SConstruct`
  - `res://tests/fixtures/multilang_project/native_scons/bin/voxel_native.linux.template_debug.arm64.so`
  - `res://tests/fixtures/multilang_project/native_scons/src/register_types.cpp`
  - `res://tests/fixtures/multilang_project/native_scons/src/voxel_chunk.cpp`
  - `res://tests/fixtures/multilang_project/native_scons/src/voxel_chunk.h`
- cycle 2 (4 files):
  - `res://tests/fixtures/multilang_project/native/CMakeLists.txt`
  - `res://tests/fixtures/multilang_project/native/bin/libdemo.so`
  - `res://tests/fixtures/multilang_project/native/child.cpp`
  - `res://tests/fixtures/multilang_project/native/register_types.cpp`

## Orphan clusters (disconnected subsystems)
- cluster 1 (2 files):
  - `res://tests/fixtures/multilang_project/addons/audit-plugin/icon.png`
  - `res://tests/fixtures/multilang_project/addons/audit-plugin/plugin.gd`

## Lone orphans (sample)
- `res://Icon.png`
- `res://LICENSE`
- `res://screenshot/Screenshot.png`
- `res://tests/fixtures/multilang_project/addons/audit-plugin/panel.tscn`
- `res://tests/fixtures/multilang_project/icon.svg`
- `res://tests/fixtures/multilang_project/main.tscn`
- `res://tests/fixtures/multilang_project/native/broken_path_scene.tscn`
- `res://tests/fixtures/multilang_project/native/native_child_scene.tscn`
- `res://tests/fixtures/multilang_project/native/native_user.gd`
- `res://tests/fixtures/multilang_project/native/stale.hpp`
- `res://tests/fixtures/multilang_project/native_scons/VoxelChunk.gd`
- `res://tests/fixtures/multilang_project/native_scons/chunk_user.gd`
- `res://tests/fixtures/multilang_project/stale_debug.json`
- `res://tests/test_ai_map.gd`
- `res://tests/test_language_analyzer.gd`
- `res://tests/test_move_refactor.gd`
- `res://tests/test_multilang_scan.gd`
- `res://tests/test_theme_store.gd`
- `res://tests/test_visibility_aggregation.gd`

## Uncertainty
### Dynamic directories (entire tree treated live)
- _(none)_

### Unresolved references (often explain false orphans)
- `res://native/bin/libdemo.so` ← `res://tests/fixtures/multilang_project/native/demo.gdextension`
- `res://native_scons/bin/voxel_native.linux.template_debug.arm64.so` ← `res://tests/fixtures/multilang_project/native_scons/voxel_native.gdextension`

### Truncated reads
- _(none)_

---
Full adjacency lives in the atlas UI / optional text log — omit it from prompts unless debugging a specific edge.
