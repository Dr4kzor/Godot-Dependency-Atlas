@tool
extends RefCounted

## Entanglement ("spaghetti") metrics computed from the reference graph.
##
## The signals here are adapted from long-standing coupling metrics rather
## than invented for this tool:
##
##   FAN-IN / FAN-OUT   how many files depend on this one, and how many it
##                      depends on. Classic afferent/efferent coupling.
##   INSTABILITY        fan_out / (fan_in + fan_out), from Robert Martin's
##                      package metrics. 0 = heavily depended upon and
##                      depends on nothing (a stable leaf); 1 = depends on
##                      everything and nothing depends on it.
##   DEPENDENCY CYCLES  strongly connected components of size > 1. This is
##                      the strongest objective entanglement signal: if
##                      A -> B -> C -> A, none of the three can be
##                      understood, tested, or reused independently.
##   HUB SCORE          fan_in * fan_out. A file that both depends on a lot
##                      AND is depended on by a lot is a chokepoint -- every
##                      change to it ripples in both directions.
##   CROSS-FOLDER RATIO fraction of references that jump between top-level
##                      folders. High values mean the folder structure no
##                      longer reflects the actual architecture.
##
## The composite TANGLE INDEX at the end is a weighted blend of those, and
## is a rule of thumb rather than a standard: the weights are a judgement
## call, so the components are always reported alongside it. Treat the
## individual numbers as the real signal and the index as a rough summary.

const CYCLE_WEIGHT := 0.5
const CROSS_FOLDER_WEIGHT := 0.3
const HUB_WEIGHT := 0.2

## Files at or above this hub score are surfaced as hotspots.
const HOTSPOT_MIN_SCORE := 6

## Sidecars are excluded from every metric below. The scanner deliberately
## links a file to its sidecar AND an .import back to its source, which is
## correct for reachability but forms a 2-cycle around every imported asset
## (icon.png -> icon.png.import -> icon.png). Those are Godot bookkeeping
## links, not design decisions, and counting them would flag almost the
## whole project as cyclic.
const SIDECAR_SUFFIXES := [".import", ".uid"]


## Edge kinds that are too speculative to count as real coupling. A
## class_name matched only inside a comment or string is a guess, and
## counting it invents dependencies -- a base class that documents its own
## subclasses would otherwise appear to depend on them, turning ordinary
## inheritance into a phantom cycle.
const WEAK_EDGE_KINDS := ["class_name_weak"]


static func _is_sidecar(path: String) -> bool:
	for suffix in SIDECAR_SUFFIXES:
		if path.ends_with(suffix):
			return true
	return false


## Reference graph with sidecar nodes/edges, self-loops, and speculative
## comment-only class references removed, so the metrics describe real
## design coupling rather than bookkeeping and guesswork.
static func logical_graph(graph: Dictionary, edge_kinds: Dictionary = {}) -> Dictionary:
	var out := {}
	for key in graph.keys():
		var parent: String = key
		if _is_sidecar(parent):
			continue
		var parent_kinds: Dictionary = edge_kinds.get(parent, {})
		var refs: Array = []
		for r in graph[parent]:
			var child: String = r
			if child == parent or _is_sidecar(child):
				continue
			if String(parent_kinds.get(child, "")) in WEAK_EDGE_KINDS:
				continue
			refs.append(child)
		out[parent] = refs
	return out


static func analyze(raw_graph: Dictionary, edge_kinds: Dictionary = {}) -> Dictionary:
	var graph := logical_graph(raw_graph, edge_kinds)
	var fan_out := {}
	var fan_in := {}
	var nodes := {}

	for key in graph.keys():
		var parent: String = key
		nodes[parent] = true
		var refs: Array = graph[parent]
		fan_out[parent] = refs.size()
		for r in refs:
			var child: String = r
			nodes[child] = true
			fan_in[child] = int(fan_in.get(child, 0)) + 1

	var total_edges := 0
	var cross_folder_edges := 0
	for key in graph.keys():
		var parent2: String = key
		for r in graph[parent2]:
			total_edges += 1
			if _top_folder(parent2) != _top_folder(String(r)):
				cross_folder_edges += 1

	var cycles := _find_cycles(graph)
	var files_in_cycles := {}
	var cycle_of := {}
	for ci in cycles.size():
		var cycle: Array = cycles[ci]
		for f in cycle:
			files_in_cycles[String(f)] = true
			cycle_of[String(f)] = ci

	# Per-file detail.
	var per_file := {}
	var hotspots: Array = []
	for key in nodes.keys():
		var path: String = key
		var out_count := int(fan_out.get(path, 0))
		var in_count := int(fan_in.get(path, 0))
		var total := out_count + in_count
		var instability := 0.0 if total == 0 else float(out_count) / float(total)
		var hub := out_count * in_count
		var cycle_index: int = int(cycle_of.get(path, -1))
		per_file[path] = {
			"fan_in": in_count,
			"fan_out": out_count,
			"instability": instability,
			"hub_score": hub,
			"in_cycle": cycle_index >= 0,
			"cycle_index": cycle_index,
			"cycle_size": 0 if cycle_index < 0 else (cycles[cycle_index] as Array).size(),
		}
		if hub >= HOTSPOT_MIN_SCORE or files_in_cycles.has(path):
			hotspots.append({
				"path": path, "fan_in": in_count, "fan_out": out_count,
				"hub_score": hub, "in_cycle": files_in_cycles.has(path),
			})

	hotspots.sort_custom(func(a, b):
		var ac: bool = a["in_cycle"]
		var bc: bool = b["in_cycle"]
		if ac != bc:
			return ac  # cycle members first, they matter most
		return int(a["hub_score"]) > int(b["hub_score"])
	)

	var node_count := nodes.size()
	var cycle_ratio := 0.0 if node_count == 0 else float(files_in_cycles.size()) / float(node_count)
	var cross_ratio := 0.0 if total_edges == 0 else float(cross_folder_edges) / float(total_edges)

	# Hub concentration: how much of the total hub score sits in the worst
	# 10% of files. A healthy graph spreads coupling out; a tangled one
	# concentrates it in a few chokepoints.
	var hub_concentration := _hub_concentration(per_file)

	var tangle := 100.0 * (
		CYCLE_WEIGHT * cycle_ratio
		+ CROSS_FOLDER_WEIGHT * cross_ratio
		+ HUB_WEIGHT * hub_concentration
	)

	return {
		"per_file": per_file,
		"cycles": cycles,
		"cycle_of": cycle_of,
		"hotspots": hotspots,
		"files_in_cycles": files_in_cycles.size(),
		"cycle_ratio": cycle_ratio,
		"cross_folder_ratio": cross_ratio,
		"cross_folder_edges": cross_folder_edges,
		"hub_concentration": hub_concentration,
		"total_edges": total_edges,
		"node_count": node_count,
		"avg_fan_out": 0.0 if node_count == 0 else float(total_edges) / float(node_count),
		"tangle_index": tangle,
		"tangle_band": _band(tangle),
	}


static func _band(tangle: float) -> String:
	if tangle < 12.0:
		return "loosely coupled"
	if tangle < 25.0:
		return "moderate coupling"
	if tangle < 40.0:
		return "notably entangled"
	return "heavily entangled"


static func _top_folder(path: String) -> String:
	var rel := path.trim_prefix("res://")
	var slash := rel.find("/")
	if slash == -1:
		return "<root>"
	return rel.substr(0, slash)


static func _hub_concentration(per_file: Dictionary) -> float:
	var scores: Array = []
	var total := 0
	for key in per_file.keys():
		var s := int(per_file[key]["hub_score"])
		scores.append(s)
		total += s
	if total == 0 or scores.is_empty():
		return 0.0
	scores.sort()
	scores.reverse()
	var top_count := maxi(1, int(ceil(float(scores.size()) * 0.1)))
	var top_sum := 0
	for i in top_count:
		top_sum += int(scores[i])
	return float(top_sum) / float(total)


## Iterative Tarjan. Written without recursion deliberately -- GDScript's
## call stack is shallow enough that a deep dependency chain could overflow
## a recursive implementation on a real project.
static func _find_cycles(graph: Dictionary) -> Array:
	var index := 0
	var indices := {}
	var lowlink := {}
	var on_stack := {}
	var stack: Array = []
	var cycles: Array = []

	for root_key in graph.keys():
		var root: String = root_key
		if indices.has(root):
			continue

		var work: Array = [[root, 0]]
		while not work.is_empty():
			var frame: Array = work[work.size() - 1]
			var node: String = frame[0]
			var child_index: int = frame[1]

			if child_index == 0:
				indices[node] = index
				lowlink[node] = index
				index += 1
				stack.append(node)
				on_stack[node] = true

			var kids: Array = graph.get(node, [])
			var recursed := false
			for i in range(child_index, kids.size()):
				var w: String = kids[i]
				if not graph.has(w):
					continue  # leaf/asset with no outgoing edges of its own
				if not indices.has(w):
					frame[1] = i + 1
					work.append([w, 0])
					recursed = true
					break
				elif on_stack.get(w, false):
					lowlink[node] = mini(int(lowlink[node]), int(indices[w]))
			if recursed:
				continue

			if int(lowlink[node]) == int(indices[node]):
				var component: Array = []
				while true:
					var popped: String = stack.pop_back()
					on_stack[popped] = false
					component.append(popped)
					if popped == node:
						break
				var is_self_loop: bool = component.size() == 1 and node in graph.get(node, [])
				if component.size() > 1 or is_self_loop:
					component.sort()
					cycles.append(component)

			work.pop_back()
			if not work.is_empty():
				var parent_frame: Array = work[work.size() - 1]
				var parent_node: String = parent_frame[0]
				lowlink[parent_node] = mini(int(lowlink[parent_node]), int(lowlink[node]))

	cycles.sort_custom(func(a, b): return a.size() > b.size())
	return cycles
