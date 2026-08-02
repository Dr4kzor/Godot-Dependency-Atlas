@tool
extends RefCounted

## Builds a compact, agent-oriented summary of a Dependency Atlas scan.
##
## Design goals for LLM context (not humans reading a novel):
##   - Lead with purpose + hard rules (models overweight the top of a file).
##   - Prefer short bullet lines with full `res://` paths (easy to grep/match).
##   - Cap every list; never dump the adjacency graph.
##   - Surface uncertainty (unresolved / dynamic dirs) near actionable orphans.
##   - Stable section headings so agents can skim or retrieve by name.
##
## Written to dependency_atlas/ai_map.md — one overwriteable file, not a log pile.

const GraphMetrics = preload("res://addons/godot_dependency_atlas/graph3d/graph_metrics.gd")
const OFConfig = preload("res://addons/godot_dependency_atlas/graph3d/of_config.gd")

const AI_MAP_NAME := "ai_map.md"
const MAX_HUBS := 12
const MAX_CYCLES := 6
const MAX_CYCLE_MEMBERS := 10
const MAX_ORPHAN_CLUSTERS := 8
const MAX_CLUSTER_MEMBERS := 12
const MAX_LONE_ORPHANS := 20
const MAX_UNRESOLVED := 25
const MAX_DYNAMIC_DIRS := 12
const MAX_TRUNCATED := 10
const MAX_NATIVE_CLASSES := 40
const MAX_ROOTS := 30


static func map_path(scan_root: String = "res://") -> String:
	return OFConfig.data_dir(scan_root).path_join(AI_MAP_NAME)


## Returns "" on success, otherwise an error message.
static func write_from_scan(result: Dictionary, scan_root: String = "res://") -> String:
	var text := build(result, scan_root)
	var path := map_path(scan_root)
	var folder := path.get_base_dir()
	var layout_error := OFConfig.ensure_layout(scan_root)
	if layout_error != "":
		return layout_error
	if folder != "" and not DirAccess.dir_exists_absolute(folder):
		if DirAccess.make_dir_recursive_absolute(folder) != OK:
			return "Could not create %s" % folder
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "Could not write %s" % path
	f.store_string(text)
	f.close()
	return ""


static func build(result: Dictionary, scan_root: String = "res://") -> String:
	var graph: Dictionary = result.get("graph", {})
	var edge_kinds: Dictionary = result.get("edge_kinds", {})
	var metrics: Dictionary = GraphMetrics.analyze(graph, edge_kinds)
	var roots: Array = result.get("roots", [])
	var orphans: Array = result.get("orphans", [])
	var orphan_graph: Dictionary = result.get("orphan_graph", {})
	var dynamic_dirs: Array = result.get("dynamic_dirs", [])
	var unresolved: Array = result.get("unresolved_refs", [])
	var truncated: Array = result.get("truncated_files", [])
	var native_classes: Dictionary = result.get("native_class_libraries", {})
	var reachable := int(result.get("reachable_count", 0))
	var total := int(result.get("total_files", 0))
	var clusters := _orphan_clusters(orphans, orphan_graph)
	var lone := _lone_orphans(orphans, clusters)

	var lines: PackedStringArray = []
	lines.append("# Dependency Atlas — AI map")
	lines.append("")
	lines.append(
		"For coding agents: read this before deleting, moving, renaming, or rewiring Godot assets. "
		+ "Prefer exact `res://` paths listed here. This is a reachability summary, not proof a file is unused at runtime."
	)
	lines.append("")
	lines.append(
		"Generated: `%s` · scan_root: `%s` · reachable **%d** / **%d** · roots **%d** · orphans **%d** · tangle **%.0f** (%s)"
		% [
			Time.get_datetime_string_from_system(),
			scan_root,
			reachable,
			total,
			roots.size(),
			orphans.size(),
			float(metrics.get("tangle_index", 0.0)),
			String(metrics.get("tangle_band", "")),
		]
	)
	lines.append("")
	lines.append("## Agent rules")
	lines.append(
		"- A missing `res://.../file` is an unresolved reference — never treat its parent folder as fully live."
	)
	lines.append(
		"- Orphans are review candidates only; check **Uncertainty** and runtime `load()`/`preload()` patterns first."
	)
	lines.append(
		"- Changing a **hub** or anything in a **cycle** has wide blast radius — open dependents before editing."
	)
	lines.append(
		"- GDExtension classes live in the `.so`/`.dll`; GDScript may name them with no `res://` path."
	)
	lines.append(
		"- Sidecars (`.import`, `.uid`) follow their owner; do not reason about them alone."
	)
	lines.append("")

	lines.append("## Entry points")
	var root_n := 0
	for root_any in roots:
		if root_n >= MAX_ROOTS:
			lines.append("- … +%d more roots" % (roots.size() - MAX_ROOTS))
			break
		var root: Dictionary = root_any
		lines.append("- `[%s]` `%s`" % [String(root.get("kind", "")), String(root.get("path", ""))])
		root_n += 1
	if roots.is_empty():
		lines.append("- _(none)_")
	lines.append("")

	_append_native_section(lines, graph, edge_kinds, native_classes)

	lines.append("## Coupling hubs (highest change impact)")
	var hubs: Array = metrics.get("hotspots", [])
	var hub_n := 0
	for hub_any in hubs:
		if hub_n >= MAX_HUBS:
			lines.append("- … +%d more hubs" % (hubs.size() - MAX_HUBS))
			break
		var hub: Dictionary = hub_any
		var cycle_note := " · **in cycle**" if bool(hub.get("in_cycle", false)) else ""
		lines.append(
			"- `%s` — in:%d out:%d hub:%d%s"
			% [
				String(hub.get("path", "")),
				int(hub.get("fan_in", 0)),
				int(hub.get("fan_out", 0)),
				int(hub.get("hub_score", 0)),
				cycle_note,
			]
		)
		hub_n += 1
	if hubs.is_empty():
		lines.append("- _(none above threshold)_")
	lines.append("")

	lines.append("## Dependency cycles")
	var cycles: Array = metrics.get("cycles", [])
	if cycles.is_empty():
		lines.append("- _(none)_")
	else:
		var cycle_i := 0
		for cycle_any in cycles:
			if cycle_i >= MAX_CYCLES:
				lines.append("- … +%d more cycles" % (cycles.size() - MAX_CYCLES))
				break
			var cycle: Array = cycle_any
			lines.append("- cycle %d (%d files):" % [cycle_i + 1, cycle.size()])
			var member_n := 0
			for member_any in cycle:
				if member_n >= MAX_CYCLE_MEMBERS:
					lines.append("  - … +%d more" % (cycle.size() - MAX_CYCLE_MEMBERS))
					break
				lines.append("  - `%s`" % String(member_any))
				member_n += 1
			cycle_i += 1
	lines.append("")

	lines.append("## Orphan clusters (disconnected subsystems)")
	if clusters.is_empty():
		lines.append("- _(none)_")
	else:
		var cluster_i := 0
		for cluster_any in clusters:
			if cluster_i >= MAX_ORPHAN_CLUSTERS:
				lines.append("- … +%d more clusters" % (clusters.size() - MAX_ORPHAN_CLUSTERS))
				break
			var cluster: Array = cluster_any
			lines.append("- cluster %d (%d files):" % [cluster_i + 1, cluster.size()])
			var member_n2 := 0
			for member_any2 in cluster:
				if member_n2 >= MAX_CLUSTER_MEMBERS:
					lines.append("  - … +%d more" % (cluster.size() - MAX_CLUSTER_MEMBERS))
					break
				lines.append("  - `%s`" % String(member_any2))
				member_n2 += 1
			cluster_i += 1
	lines.append("")

	lines.append("## Lone orphans (sample)")
	var lone_n := 0
	for orphan_any in lone:
		if lone_n >= MAX_LONE_ORPHANS:
			lines.append("- … +%d more lone orphans" % (lone.size() - MAX_LONE_ORPHANS))
			break
		var orphan: Dictionary = orphan_any
		var note := ""
		if orphan.has("duplicated_in"):
			note = " · content also inlined in `%s`" % String(orphan["duplicated_in"])
		lines.append("- `%s`%s" % [String(orphan.get("path", "")), note])
		lone_n += 1
	if lone.is_empty():
		lines.append("- _(none)_")
	lines.append("")

	lines.append("## Uncertainty")
	lines.append("### Dynamic directories (entire tree treated live)")
	if dynamic_dirs.is_empty():
		lines.append("- _(none)_")
	else:
		var dyn_n := 0
		var seen_dyn := {}
		for dyn_any in dynamic_dirs:
			var dyn: Dictionary = dyn_any
			var dir_path := String(dyn.get("dir", ""))
			var key := "%s|%s" % [dir_path, String(dyn.get("referenced_in", ""))]
			if seen_dyn.has(key):
				continue
			seen_dyn[key] = true
			if dyn_n >= MAX_DYNAMIC_DIRS:
				lines.append("- … +%d more" % (dynamic_dirs.size() - dyn_n))
				break
			lines.append(
				"- `%s` (%d files) ← `%s`"
				% [dir_path, int(dyn.get("file_count", 0)), String(dyn.get("referenced_in", ""))]
			)
			dyn_n += 1
	lines.append("")
	lines.append("### Unresolved references (often explain false orphans)")
	if unresolved.is_empty():
		lines.append("- _(none)_")
	else:
		var unr_n := 0
		for unr_any in unresolved:
			if unr_n >= MAX_UNRESOLVED:
				lines.append("- … +%d more" % (unresolved.size() - MAX_UNRESOLVED))
				break
			var unr: Dictionary = unr_any
			lines.append(
				"- `%s` ← `%s`"
				% [String(unr.get("reference", "")), String(unr.get("in_file", ""))]
			)
			unr_n += 1
	lines.append("")
	lines.append("### Truncated reads")
	if truncated.is_empty():
		lines.append("- _(none)_")
	else:
		var tr_n := 0
		for tr_any in truncated:
			if tr_n >= MAX_TRUNCATED:
				lines.append("- … +%d more" % (truncated.size() - MAX_TRUNCATED))
				break
			lines.append("- `%s`" % String(tr_any))
			tr_n += 1
	lines.append("")
	lines.append("---")
	lines.append(
		"Full adjacency lives in the atlas UI / optional text log — omit it from prompts unless debugging a specific edge."
	)
	lines.append("")
	return "\n".join(lines)


static func _append_native_section(
	lines: PackedStringArray, graph: Dictionary, edge_kinds: Dictionary, native_classes: Dictionary
) -> void:
	lines.append("## Native / GDExtension")
	var descriptors: Array = []
	for key_any in graph.keys():
		var path := String(key_any)
		if path.get_extension().to_lower() != "gdextension":
			continue
		descriptors.append(path)
	descriptors.sort()
	if descriptors.is_empty() and native_classes.is_empty():
		lines.append("- _(no GDExtension bridge detected)_")
		lines.append("")
		return
	for descriptor_any in descriptors:
		var descriptor := String(descriptor_any)
		var libs: Array = []
		for ref_any in graph.get(descriptor, []):
			var ref := String(ref_any)
			var kind := String((edge_kinds.get(descriptor, {}) as Dictionary).get(ref, ""))
			if kind == "gdextension_library" or ref.get_extension().to_lower() in ["so", "dll", "dylib", "framework"]:
				libs.append(ref)
		if libs.is_empty():
			lines.append("- `%s`" % descriptor)
		else:
			lines.append("- `%s` → %s" % [descriptor, ", ".join(_backtick_list(libs))])
	if not native_classes.is_empty():
		# Group classes by library for one dense line per .so.
		var by_library := {}
		for class_any in native_classes.keys():
			var cls := String(class_any)
			var library := String(native_classes[cls])
			if not by_library.has(library):
				by_library[library] = []
			(by_library[library] as Array).append(cls)
		var lib_keys: Array = by_library.keys()
		lib_keys.sort()
		for library_any in lib_keys:
			var library := String(library_any)
			var names: Array = by_library[library]
			names.sort()
			if names.size() > MAX_NATIVE_CLASSES:
				var shown: Array = names.slice(0, MAX_NATIVE_CLASSES)
				lines.append(
					"- classes → `%s`: %s, … +%d"
					% [library, ", ".join(shown), names.size() - MAX_NATIVE_CLASSES]
				)
			else:
				lines.append("- classes → `%s`: %s" % [library, ", ".join(names)])
	lines.append("")


static func _backtick_list(paths: Array) -> PackedStringArray:
	var out: PackedStringArray = []
	for path_any in paths:
		out.append("`%s`" % String(path_any))
	return out


## Connected components among orphans that reference each other, largest first.
static func _orphan_clusters(orphans: Array, orphan_graph: Dictionary) -> Array:
	var orphan_set := {}
	for orphan_any in orphans:
		orphan_set[String((orphan_any as Dictionary).get("path", ""))] = true
	var undirected := {}
	for src_any in orphan_graph.keys():
		var src := String(src_any)
		if not orphan_set.has(src):
			continue
		for dst_any in orphan_graph[src]:
			var dst := String(dst_any)
			if not orphan_set.has(dst) or dst == src:
				continue
			if not undirected.has(src):
				undirected[src] = {}
			if not undirected.has(dst):
				undirected[dst] = {}
			undirected[src][dst] = true
			undirected[dst][src] = true
	var visited := {}
	var clusters: Array = []
	for path_any in orphan_set.keys():
		var start := String(path_any)
		if visited.has(start) or start == "" or not undirected.has(start):
			continue
		var stack: Array = [start]
		var component: Array = []
		visited[start] = true
		while not stack.is_empty():
			var current: String = stack.pop_back()
			component.append(current)
			for neighbor_any in (undirected.get(current, {}) as Dictionary).keys():
				var neighbor := String(neighbor_any)
				if not visited.has(neighbor):
					visited[neighbor] = true
					stack.append(neighbor)
		if component.size() >= 2:
			component.sort()
			clusters.append(component)
	clusters.sort_custom(func(a, b): return (a as Array).size() > (b as Array).size())
	return clusters


static func _lone_orphans(orphans: Array, clusters: Array) -> Array:
	var clustered := {}
	for cluster_any in clusters:
		for path_any in cluster_any:
			clustered[String(path_any)] = true
	var lone: Array = []
	for orphan_any in orphans:
		var orphan: Dictionary = orphan_any
		var path := String(orphan.get("path", ""))
		if path == "" or clustered.has(path):
			continue
		# Skip sidecars in the sample — owner orphans matter more to agents.
		if path.ends_with(".import") or path.ends_with(".uid"):
			continue
		lone.append(orphan)
	lone.sort_custom(func(a, b):
		return String((a as Dictionary).get("path", "")) < String((b as Dictionary).get("path", ""))
	)
	return lone
