@tool
extends RefCounted

## Groups files that are probably part of the same system, judged by name.
##
## Projects name related files consistently -- inventory_panel.gd,
## inventory_slot.tscn, InventoryItemTooltip.gd -- and that convention carries
## real information the dependency graph does not. Two files can belong to one
## feature without referencing each other at all.
##
## This is a heuristic, so it is scored rather than assumed, and only applied
## above a confidence threshold. A wrong grouping is worse than none: it
## implies a relationship the project does not have.

## Tokens too generic to imply a shared system. "main_menu.gd" and
## "main_window.gd" share "main" without being related in any useful sense.
const STOP_TOKENS := [
	"new", "test", "tests", "tmp", "temp", "old", "copy", "backup",
	"main", "base", "util", "utils", "helper", "helpers", "common",
	"data", "node", "scene", "script", "default", "item", "object",
	"a", "b", "c", "x", "y", "z", "the", "and",
]

const MIN_TOKEN_LENGTH := 3
const MIN_GROUP_SIZE := 2
## Below this, the evidence is too thin to act on.
const CONFIDENCE_THRESHOLD := 0.6


## Splits a filename into lowercase words, handling snake_case, "space case",
## kebab-case and CamelCase alike.
static func tokenise(path: String) -> Array:
	var stem := path.get_file()
	var dot := stem.rfind(".")
	if dot > 0:
		stem = stem.substr(0, dot)

	# Insert a break before each capital that follows a lowercase or digit, so
	# HealthBarFill becomes health bar fill.
	var spaced := ""
	for i in stem.length():
		var character := stem[i]
		if i > 0 and character == character.to_upper() and character != character.to_lower():
			var previous := stem[i - 1]
			if previous == previous.to_lower() and previous != previous.to_upper():
				spaced += " "
			elif previous.is_valid_int():
				spaced += " "
		spaced += character

	var out: Array = []
	for part_any in spaced.replace("_", " ").replace("-", " ").split(" "):
		var part := String(part_any).strip_edges().to_lower()
		if part != "":
			out.append(part)
	return out


## Groups paths by (directory, leading token), scores each, and returns only
## those clearing the threshold.
##
## Returns { group_key: { "token", "dir", "members", "confidence" } }.
static func analyse(paths: Array) -> Dictionary:
	var buckets := {}
	var token_dirs := {}      # token -> set of directories it appears in

	for p in paths:
		var path: String = p
		var tokens := tokenise(path)
		if tokens.is_empty():
			continue
		var lead := String(tokens[0])
		var directory := path.get_base_dir()

		var key := "%s|%s" % [directory, lead]
		if not buckets.has(key):
			buckets[key] = {"token": lead, "dir": directory, "members": []}
		buckets[key]["members"].append(path)

		for t in tokens:
			var token := String(t)
			if not token_dirs.has(token):
				token_dirs[token] = {}
			token_dirs[token][directory] = true

	var groups := {}
	for key_any in buckets.keys():
		var key2: String = key_any
		var bucket: Dictionary = buckets[key2]
		var confidence := _score(bucket, token_dirs)
		if confidence >= CONFIDENCE_THRESHOLD:
			bucket["confidence"] = confidence
			groups[key2] = bucket
	return groups


static func _score(bucket: Dictionary, token_dirs: Dictionary) -> float:
	var token: String = bucket["token"]
	var members: Array = bucket["members"]

	if members.size() < MIN_GROUP_SIZE:
		return 0.0
	if token.length() < MIN_TOKEN_LENGTH:
		return 0.0
	if token in STOP_TOKENS:
		return 0.0
	if token.is_valid_int():
		return 0.0

	var confidence := 0.45                                   # shared lead token, one folder
	confidence += mini(members.size(), 5) * 0.08             # more members, stronger signal

	# A token used across many folders is a naming convention rather than one
	# system: "icon" in every folder says nothing about relatedness.
	var directories: Dictionary = token_dirs.get(token, {})
	if directories.size() > 1:
		confidence -= 0.20

	# A scene plus its script plus its resource is the classic shape of one
	# feature, so mixed extensions raise confidence.
	var extensions := {}
	for m in members:
		extensions[String(m).get_extension().to_lower()] = true
	if extensions.size() > 1:
		confidence += 0.15

	return clampf(confidence, 0.0, 1.0)


## Splits any group whose members form an inheritance hierarchy.
##
## A prefix family like RA_ReversableAction / RA_AddVoxel / RA_RemoveVoxel is
## not a flat cluster: the base class sits above and its subclasses are
## siblings that use it and never each other. Grouping them all together
## hides that entirely.
##
## Members are assigned a hierarchy level, and only files at the SAME level
## stay grouped -- so siblings sit side by side while their base rises above
## them. Inheritance wins over the name here because it is real structure
## rather than a convention.
static func apply_hierarchy(groups: Dictionary, parent_of: Dictionary) -> Dictionary:
	var out := {}
	for key_any in groups.keys():
		var key: String = key_any
		var group: Dictionary = groups[key]
		var members: Array = group["members"]

		var levels := {}
		var any_related := false
		for m in members:
			var path: String = m
			var level := _hierarchy_level(path, parent_of, members)
			levels[path] = level
			if level > 0:
				any_related = true

		if not any_related:
			out[key] = group     # no inheritance among them: leave as one group
			continue

		# Re-bucket by level: siblings together, base class on its own.
		var by_level := {}
		for m2 in members:
			var path2: String = m2
			var level2 := int(levels[path2])
			if not by_level.has(level2):
				by_level[level2] = []
			by_level[level2].append(path2)

		for level_any in by_level.keys():
			var level3: int = level_any
			var bucket: Array = by_level[level3]
			var sub_key := "%s#L%d" % [key, level3]
			out[sub_key] = {
				"token": group["token"],
				"dir": group["dir"],
				"members": bucket,
				"confidence": float(group["confidence"]),
				"hierarchy_level": level3,
			}
	return out


## How many `extends` hops separate a file from the top of its own family.
## Only hops that stay inside the group count, so an unrelated common base
## like RefCounted does not flatten everything to one level.
static func _hierarchy_level(path: String, parent_of: Dictionary, members: Array) -> int:
	var level := 0
	var current := path
	var guard := 0
	while parent_of.has(current) and guard < 32:
		var parent := String(parent_of[current])
		if not (parent in members):
			break
		level += 1
		current = parent
		guard += 1
	return level


## path -> group key, for the paths that ended up in a confident group.
static func membership(groups: Dictionary) -> Dictionary:
	var out := {}
	for key_any in groups.keys():
		var key: String = key_any
		for m in (groups[key]["members"] as Array):
			out[String(m)] = key
	return out
