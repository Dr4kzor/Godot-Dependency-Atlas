# Dependency Atlas — AI map

For coding agents: read this before deleting, moving, renaming, or rewiring Godot assets. Prefer exact `res://` paths listed here. This is a reachability summary, not proof a file is unused at runtime.

Generated: `2026-08-03T00:06:51` · scan_root: `/home/drak/Documents/orphan-finder/tests/fixtures/multilang_project` · reachable **25** / **29** · roots **7** · orphans **2** · tangle **37** (notably entangled)

## Agent rules
- A missing `res://.../file` is an unresolved reference — never treat its parent folder as fully live.
- Orphans are review candidates only; check **Uncertainty** and runtime `load()`/`preload()` patterns first.
- Changing a **hub** or anything in a **cycle** has wide blast radius — open dependents before editing.
- GDExtension classes live in the `.so`/`.dll`; GDScript may name them with no `res://` path.
- Sidecars (`.import`, `.uid`) follow their owner; do not reason about them alone.

## Entry points
- `[main scene]` `res://main.tscn`
- `[editor plugin]` `res://addons/audit-plugin/plugin.gd`
- `[C# build]` `res://Game.csproj`
- `[native build]` `res://native/CMakeLists.txt`
- `[native extension]` `res://native/demo.gdextension`
- `[native build]` `res://native_scons/SConstruct`
- `[native extension]` `res://native_scons/voxel_native.gdextension`

## Native / GDExtension
- `res://native/demo.gdextension` → `res://native/bin/libdemo.so`
- `res://native_scons/voxel_native.gdextension` → `res://native_scons/bin/voxel_native.linux.template_debug.arm64.so`
- classes → `res://native/bin/libdemo.so`: NativeChild
- classes → `res://native_scons/bin/voxel_native.linux.template_debug.arm64.so`: VoxelChunk

## Coupling hubs (highest change impact)
- `res://native/bin/libdemo.so` — in:6 out:3 hub:18 · **in cycle**
- `res://native_scons/bin/voxel_native.linux.template_debug.arm64.so` — in:6 out:3 hub:18 · **in cycle**
- `res://native_scons/src/voxel_chunk.cpp` — in:4 out:2 hub:8 · **in cycle**
- `res://native/child.cpp` — in:3 out:2 hub:6 · **in cycle**
- `res://native_scons/src/register_types.cpp` — in:2 out:3 hub:6 · **in cycle**
- `res://native/register_types.cpp` — in:2 out:2 hub:4 · **in cycle**
- `res://native_scons/src/voxel_chunk.h` — in:2 out:2 hub:4 · **in cycle**
- `res://native/CMakeLists.txt` — in:1 out:2 hub:2 · **in cycle**
- `res://native_scons/SConstruct` — in:1 out:2 hub:2 · **in cycle**

## Dependency cycles
- cycle 1 (5 files):
  - `res://native_scons/SConstruct`
  - `res://native_scons/bin/voxel_native.linux.template_debug.arm64.so`
  - `res://native_scons/src/register_types.cpp`
  - `res://native_scons/src/voxel_chunk.cpp`
  - `res://native_scons/src/voxel_chunk.h`
- cycle 2 (4 files):
  - `res://native/CMakeLists.txt`
  - `res://native/bin/libdemo.so`
  - `res://native/child.cpp`
  - `res://native/register_types.cpp`

## Orphan clusters (disconnected subsystems)
- _(none)_

## Lone orphans (sample)
- `res://native/stale.hpp`
- `res://stale_debug.json`

## Uncertainty
### Dynamic directories (entire tree treated live)
- _(none)_

### Unresolved references (often explain false orphans)
- `res://addons/missing_pack/textures/gone.png` ← `res://native/broken_path_scene.tscn`

### Truncated reads
- _(none)_

---
Full adjacency lives in the atlas UI / optional text log — omit it from prompts unless debugging a specific edge.
