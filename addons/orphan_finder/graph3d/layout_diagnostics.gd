@tool
extends RefCounted

## Dumps what the layout actually decided, so a misplaced node can be
## diagnosed from evidence rather than inferred from a screenshot.
##
## Reports, for every file it examines: the parsed header, the resolved
## parent, which grouping pass claimed it, and its final position relative to
## the family it should belong to. Where a decision went wrong, the value that
## caused it is in the report.

const OFConfig = preload("res://addons/orphan_finder/graph3d/of_config.gd")
const NamingAffinity = preload("res://addons/orphan_finder/graph3d/naming_affinity.gd")

const REPORT_NAME := "layout_diagnostics.txt"
## Header lines quoted per file. Enough to see `extends`, `class_name`, any
## preload consts, and whatever precedes them.
const HEADER_LINES := 14


## Builds the report. `focus` is a substring: every file whose path contains it
## is examined in full, along with the whole inheritance family it belongs to.
static func build_report(focus: String, state: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("ORPHAN FINDER -- LAYOUT DIAGNOSTICS")
	lines.append("Generated %s" % Time.get_datetime_string_from_system())
	lines.append("Focus: files whose path contains \"%s\"" % focus)
	lines.append("")

	var positions: Dictionary = state.get("positions", {})
	var parent_of: Dictionary = state.get("parent_of", {})
	var name_group_of: Dictionary = state.get("name_group_of", {})
	var name_groups: Dictionary = state.get("name_groups", {})
	var grid_placed: Dictionary = state.get("grid_placed", {})
	var hierarchy_placed: Dictionary = state.get("hierarchy_placed", {})
	var orphan_set: Dictionary = state.get("orphan_set", {})
	var contents: Dictionary = state.get("contents", {})
	var graph: Dictionary = state.get("graph", {})

	# --- what matched -------------------------------------------------------
	var matched: Array = []
	for key in positions.keys():
		var path: String = key
		if path.to_lower().contains(focus.to_lower()):
			matched.append(path)
	matched.sort()

	if matched.is_empty():
		lines.append("No file matched. Check the spelling, or widen the focus.")
		return "\n".join(lines)

	# Pull in every relative of a matched file, so a split family is visible
	# in one report rather than needing several.
	var family_roots := {}
	for m in matched:
		family_roots[_root_of(String(m), parent_of)] = true
	var examined := {}
	for m2 in matched:
		examined[String(m2)] = true
	for key2 in parent_of.keys():
		var candidate: String = key2
		if family_roots.has(_root_of(candidate, parent_of)):
			examined[candidate] = true
	for root_any in family_roots.keys():
		var root: String = root_any
		if positions.has(root):
			examined[root] = true

	var examined_list: Array = examined.keys()
	examined_list.sort()
	lines.append("Examining %d file(s): %d matched, the rest are relatives." % [
		examined_list.size(), matched.size()
	])
	lines.append("")

	# --- per-file detail ----------------------------------------------------
	for path_any in examined_list:
		var path2: String = path_any
		lines.append("=".repeat(72))
		lines.append(path2)
		lines.append("=".repeat(72))

		lines.append("  parent (extends) : %s" % String(parent_of.get(path2, "<< NONE RESOLVED >>")))
		lines.append("  hierarchy root   : %s" % _root_of(path2, parent_of))
		lines.append("  inheritance depth: %d" % _depth_of(path2, parent_of))

		var group_key := String(name_group_of.get(path2, ""))
		if group_key == "":
			lines.append("  naming group     : none")
		else:
			var group: Dictionary = name_groups.get(group_key, {})
			var members: Array = group.get("members", [])
			lines.append("  naming group     : %s  (%d member(s), confidence %.2f)" % [
				group_key, members.size(), float(group.get("confidence", 0.0))
			])
			for gm in members:
				lines.append("        %s" % String(gm))

		lines.append("  placed by grid   : %s" % ("yes" if grid_placed.has(path2) else "no"))
		lines.append("  placed by family : %s" % ("yes" if hierarchy_placed.has(path2) else "no"))
		lines.append("  orphan           : %s" % ("yes" if orphan_set.has(path2) else "no"))

		if positions.has(path2):
			var position: Vector3 = positions[path2]
			lines.append("  position         : (%.1f, %.1f, %.1f)" % [
				position.x, position.y, position.z
			])
		else:
			lines.append("  position         : << NOT PLACED >>")

		lines.append("  tokenised as     : %s" % str(NamingAffinity.tokenise(path2)))

		var refs: Array = graph.get(path2, [])
		lines.append("  references       : %d" % refs.size())

		# The header is what the parser actually saw.
		var content := String(contents.get(path2, ""))
		if content == "":
			lines.append("  header           : << NOT CACHED >>")
		else:
			lines.append("  header (first %d lines, as the parser reads them):" % HEADER_LINES)
			var seen := 0
			var stopped := false
			for raw in content.split("\n"):
				if seen >= HEADER_LINES:
					break
				var line := String(raw)
				var trimmed := line.strip_edges()
				var marker := "   "
				if trimmed.begins_with("extends "):
					marker = ">> "
				elif trimmed.begins_with("class_name "):
					marker = ">> "
				elif trimmed.begins_with("func ") and not stopped:
					marker = "!! "      # parser stops here
					stopped = true
				lines.append("    %s%s" % [marker, line])
				seen += 1
			if stopped:
				lines.append("    (!! marks where header parsing stops)")
		lines.append("")

	# --- family geometry ----------------------------------------------------
	lines.append("=".repeat(72))
	lines.append("FAMILY GEOMETRY")
	lines.append("=".repeat(72))
	for root_any2 in family_roots.keys():
		var root2: String = root_any2
		var members2: Array = []
		for e in examined_list:
			var member: String = e
			if _root_of(member, parent_of) == root2 and member != root2:
				members2.append(member)
		if members2.is_empty():
			continue

		var centre := Vector3.ZERO
		var counted := 0
		for m3 in members2:
			if positions.has(m3):
				centre += Vector3(positions[m3])
				counted += 1
		if counted == 0:
			continue
		centre /= float(counted)

		lines.append("")
		lines.append("Family rooted at %s -- %d member(s)" % [root2, members2.size()])
		lines.append("  centre: (%.1f, %.1f, %.1f)" % [centre.x, centre.y, centre.z])
		for m4 in members2:
			var member2: String = m4
			if not positions.has(member2):
				lines.append("    %-52s << NOT PLACED >>" % member2.get_file())
				continue
			var distance := Vector3(positions[member2]).distance_to(centre)
			lines.append("    %-52s %7.1f from centre%s" % [
				member2.get_file(), distance, "   <-- STRANDED" if distance > 45.0 else ""
			])
		if positions.has(root2):
			var base_distance := Vector3(positions[root2]).distance_to(centre)
			lines.append("    %-52s %7.1f  (base)" % [root2.get_file(), base_distance])

	return "\n".join(lines)


static func _root_of(path: String, parent_of: Dictionary) -> String:
	var current := path
	var guard := 0
	while parent_of.has(current) and guard < 32:
		current = String(parent_of[current])
		guard += 1
	return current


static func _depth_of(path: String, parent_of: Dictionary) -> int:
	var depth := 0
	var current := path
	var guard := 0
	while parent_of.has(current) and guard < 32:
		current = String(parent_of[current])
		depth += 1
		guard += 1
	return depth


## Writes the report next to the scan logs. Returns the path, or "" on failure.
static func write_report(scan_root: String, text: String) -> String:
	var problem := OFConfig.ensure_layout(scan_root)
	if problem != "":
		push_warning("Orphan Finder: " + problem)
		return ""
	var path := OFConfig.log_dir(scan_root) + "/" + REPORT_NAME
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(text)
	file.close()
	return path
