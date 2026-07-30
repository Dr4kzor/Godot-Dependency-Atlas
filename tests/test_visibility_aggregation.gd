extends SceneTree

const GraphViewer = preload("res://addons/godot_dependency_atlas/graph3d/graph_viewer.gd")
const TypeIcons = preload("res://addons/godot_dependency_atlas/graph3d/type_icons.gd")

var failures := 0


func _initialize() -> void:
	var viewer = GraphViewer.new()
	viewer._label_distance_culling = true
	_expect(
		is_zero_approx(viewer._icon_range_for("res://distant.gd", {})),
		"node icons must never be distance culled"
	)
	var image_a := "res://art/a.png"
	var image_b := "res://art/b.png"
	var script := "res://code/main.gd"
	var other_script := "res://code/menu.gd"
	viewer._positions = {
		image_a: Vector3(10, -5, 0),
		image_b: Vector3(17, -5, 0),
		script: Vector3(0, 0, 0),
		other_script: Vector3(30, 0, 0),
	}
	viewer._sizes = {
		image_a: 1.0,
		image_b: 1.0,
		script: 1.0,
		other_script: 1.0,
	}
	viewer._graph = {
		script: [image_a, image_b],
		other_script: [image_b],
	}
	viewer._view_hidden_kinds[int(TypeIcons.Kind.IMAGE)] = true

	var dormant_target := "res://stale_debug.json"
	viewer._positions[dormant_target] = Vector3(4, -20, 0)
	viewer._sizes[dormant_target] = 1.0
	viewer._orphan_set[dormant_target] = true
	viewer._comment_targets[dormant_target] = [{
		"source": script,
		"target": dormant_target,
		"line": 42,
		"function_signature": "func _ready():",
		"expression": 'load("res://stale_debug.json")',
		"context": [
			{"line": 41, "text": "func _ready():", "focus": false},
			{"line": 42, "text": "\t#load(\"res://stale_debug.json\")", "focus": true},
		],
	}]
	var dormant_groups: Dictionary = viewer._orphan_groups()
	_expect(
		dormant_target in (dormant_groups.get("commented", []) as Array),
		"comment-evidenced orphan did not receive its own visual category"
	)
	viewer._place_comment_proxies([dormant_target])
	var dormant_proxy := viewer._comment_proxy_path_for(script, dormant_target)
	_expect(viewer._positions.has(dormant_proxy), "commented dependency ghost was not placed")
	var dormant_position: Vector3 = viewer._positions[dormant_proxy]
	var source_position: Vector3 = viewer._positions[script]
	_expect(
		is_equal_approx(dormant_position.x, source_position.x)
			and is_equal_approx(dormant_position.z, source_position.z),
		"commented dependency ghost was not kept directly below its source"
	)
	_expect(
		is_equal_approx(
			dormant_position.y,
			source_position.y - viewer.vertical_layer_separation * viewer.PROXY_DROP
		),
		"commented dependency ghost used the wrong vertical drop"
	)
	_expect(
		viewer._resolve_proxy(dormant_proxy) == dormant_target,
		"commented dependency ghost did not resolve to its real orphan"
	)
	viewer._positions[script] = Vector3(19, 7, -11)
	viewer._anchor_comment_proxies()
	dormant_position = viewer._positions[dormant_proxy]
	source_position = viewer._positions[script]
	_expect(
		is_equal_approx(dormant_position.x, source_position.x)
			and is_equal_approx(dormant_position.z, source_position.z),
		"commented dependency ghost detached after its source moved"
	)
	viewer._visuals_root = Node3D.new()
	viewer.add_child(viewer._visuals_root)
	viewer._selected = dormant_proxy
	viewer._update_comment_evidence_card()
	var preview_text := viewer._evidence_card_viewport.get_child(1) as Label
	_expect(
		preview_text.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT,
		"comment evidence preview text was not left aligned"
	)
	_expect(
		"▶    42 │ │   #load" in preview_text.text,
		"comment evidence preview omitted its editor-style gutter or indentation"
	)
	_expect(
		viewer._evidence_card_viewport != null,
		"comment evidence preview has no readability background"
	)
	var evidence_background := viewer._evidence_card_viewport.get_child(0) as ColorRect
	_expect(
		evidence_background.color.a > 0.0 and evidence_background.color.a < 1.0,
		"comment evidence background is not semi-transparent"
	)
	_expect(
		viewer._evidence_card.texture == viewer._evidence_card_viewport.get_texture(),
		"comment evidence background and text were not composited into one surface"
	)

	_expect(viewer._is_view_hidden(image_a), "visibility hides image nodes")
	_expect(
		not viewer._is_displayed(image_a),
		"normal visibility mode removes hidden nodes from edge eligibility"
	)
	var compacted: Dictionary = viewer._compact_view_hidden_tree({
		"children": {script: [image_a, other_script]},
		"depth": {script: 0, image_a: 1, other_script: 1},
		"roots": [script],
	})
	_expect(
		not (compacted["depth"] as Dictionary).has(image_a)
			and (compacted["children"] as Dictionary).get(script, []).has(other_script),
		"visual hiding removes node footprints while preserving visible siblings"
	)

	viewer._pack_hidden_resources = true
	viewer._prepare_hidden_resource_groups()
	var aggregate: String = viewer._hidden_group_path_for(script, image_a)
	var other_aggregate: String = viewer._hidden_group_path_for(other_script, image_b)
	_expect(viewer._positions.has(aggregate), "consumer-local image aggregate is created")
	_expect(viewer._positions.has(other_aggregate), "second consumer gets a separate aggregate")
	_expect(aggregate != other_aggregate, "hidden resources are not packed project-wide")
	_expect(
		viewer._edge_endpoint(image_a, script) == aggregate,
		"consumer's hidden image connections terminate at its aggregate"
	)
	_expect(
		viewer._edge_endpoint(image_b, script) == aggregate,
		"same consumer's hidden images share one edge endpoint"
	)
	_expect(
		viewer._edge_endpoint(image_b, other_script) == other_aggregate,
		"shared resource routes to each consumer's local aggregate"
	)
	_expect(viewer._is_displayed(aggregate), "aggregate is visible while members are collapsed")
	_expect(viewer._is_view_hidden(image_a), "collapsed aggregate keeps member hidden")

	viewer._hidden_group_expanded[aggregate] = true
	viewer.group_member_min_separation = 7.0
	viewer.vertical_layer_separation = 12.0
	viewer._prepare_hidden_resource_groups()
	_expect(viewer._is_view_hidden(image_a), "expanded aggregate keeps the real global node hidden")
	_expect(viewer._hidden_member_of.size() == 2, "expanded aggregate creates local member proxies")
	var member_proxy := String(viewer._hidden_member_of.keys()[0])
	_expect(
		viewer._hidden_member_group.get(member_proxy, "") == aggregate,
		"expanded member retains its dummy-node connection"
	)
	_expect(viewer._is_displayed(member_proxy), "expanded local member proxy is visible")
	_expect(
		viewer._resolve_proxy(member_proxy) in [image_a, image_b],
		"local member proxy resolves to the represented resource"
	)
	_expect(
		viewer._edge_endpoint(image_a, script) == aggregate,
		"expanded members still route connections through the aggregate"
	)
	var member_proxies: Array = viewer._hidden_member_of.keys()
	var first_position: Vector3 = viewer._positions[member_proxies[0]]
	var second_position: Vector3 = viewer._positions[member_proxies[1]]
	_expect(
		Vector2(first_position.x, first_position.z).distance_to(
			Vector2(second_position.x, second_position.z)
		) >= viewer.group_member_min_separation,
		"expanded members use the configured grid separation"
	)
	_expect(
		is_equal_approx(
			first_position.y,
			float(viewer._positions[aggregate].y)
				- viewer.vertical_layer_separation
		),
		"expanded hidden members move down by the configured Y separation"
	)
	_expect(
		is_equal_approx(first_position.y, second_position.y),
		"expanded members stay aligned on the same grid layer"
	)

	viewer.free()
	if failures == 0:
		print("Visibility aggregation: all tests passed")
	quit(failures)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)
