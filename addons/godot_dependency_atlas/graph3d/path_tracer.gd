@tool
class_name DependencyPathTracer
extends RefCounted

## Finds chains from project entry points to a selected file.
##
## The old viewer search walked outward from every root with a simple-path
## DFS. That is exponential in branching factor: a hub like UI.tscn with ~90
## children can burn a fixed expansion budget exploring Animation_Editor /
## Voxel_Editor subtrees and never reach a sibling such as VisionBar.gd --
## even when the edge is sitting right there.
##
## Reverse BFS from the target through the reverse adjacency is O(E) and
## always recovers a shortest path from every entry that can reach it.
## The scan's spanning tree (`tree_parent`) is a free second answer when it
## differs from the shortest path.


static func find_paths_to(
	target: String,
	entry_paths: Array,
	reverse_graph: Dictionary,
	tree_parent: Dictionary = {},
	max_paths: int = 12,
	max_depth: int = 24
) -> Array:
	if target == "":
		return []

	var entry_set := {}
	for entry_any in entry_paths:
		var entry := String(entry_any)
		if entry != "":
			entry_set[entry] = true

	var results: Array = []
	var seen_keys := {}

	if entry_set.has(target):
		_append_unique(results, seen_keys, [target])
		return results

	var tree_path := path_via_tree_parent(target, tree_parent, entry_set, max_depth)
	if not tree_path.is_empty():
		_append_unique(results, seen_keys, tree_path)

	# Reverse BFS: walk referrers until every reachable entry is found.
	var came_from := {}  # node -> neighbour closer to the target
	var queue: Array = [target]
	var visited := {target: true}
	var found_entries: Array = []
	var head := 0
	while head < queue.size() and found_entries.size() < entry_set.size():
		var node: String = queue[head]
		head += 1
		if entry_set.has(node) and node != target:
			found_entries.append(node)
			# Keep expanding: another entry may sit behind this one.
		for referrer_any in reverse_graph.get(node, []):
			var referrer := String(referrer_any)
			if referrer == "" or visited.has(referrer):
				continue
			visited[referrer] = true
			came_from[referrer] = node
			queue.append(referrer)

	for entry_any2 in found_entries:
		var entry2 := String(entry_any2)
		var chain := _reconstruct(entry2, target, came_from, max_depth)
		if not chain.is_empty():
			_append_unique(results, seen_keys, chain)
		if results.size() >= max_paths:
			break

	results.sort_custom(func(a, b): return (a as Array).size() < (b as Array).size())
	if results.size() > max_paths:
		results.resize(max_paths)
	return results


## Walk the scan's BFS spanning tree from `target` back to an entry point.
static func path_via_tree_parent(
	target: String,
	tree_parent: Dictionary,
	entry_set: Dictionary,
	max_depth: int = 24
) -> Array:
	if target == "":
		return []
	# An entry has no tree parent; it is its own one-hop answer.
	if entry_set.has(target) or (tree_parent.is_empty() and entry_set.is_empty()):
		return [target] if entry_set.has(target) else []
	if not tree_parent.has(target):
		return []
	var chain: Array = [target]
	var current := target
	var guard := 0
	while tree_parent.has(current) and guard < max_depth:
		guard += 1
		current = String(tree_parent[current])
		if current == "" or chain.has(current):
			return []
		chain.push_front(current)
	# Spanning-tree roots are entry points. If we were given an explicit set,
	# insist the reconstructed root is one of them.
	var root := String(chain[0])
	if entry_set.is_empty() or entry_set.has(root):
		return chain
	return []


static func _reconstruct(
	start: String, target: String, came_from: Dictionary, max_depth: int
) -> Array:
	var chain: Array = [start]
	var current := start
	var guard := 0
	while current != target and guard < max_depth:
		guard += 1
		if not came_from.has(current):
			return []
		current = String(came_from[current])
		chain.append(current)
	if current != target:
		return []
	return chain


static func _append_unique(results: Array, seen_keys: Dictionary, path: Array) -> void:
	if path.is_empty():
		return
	var key := "|".join(PackedStringArray(path))
	if seen_keys.has(key):
		return
	seen_keys[key] = true
	results.append(path)
