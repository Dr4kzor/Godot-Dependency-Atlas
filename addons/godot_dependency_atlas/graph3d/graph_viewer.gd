extends Node3D

## Standalone 3D view of the project's reference graph.
## Open this scene and press F6 ("Run Current Scene").
##
## Keys:
##   G      switch tree (dependency <-> real folder structure)
##   I      show/hide .import and .uid sidecars (hidden by default)
##   H      entanglement heat map
##   P      pair scripts to the scene that owns them
##   click  select a node; unrelated nodes fade out
##   wheel  adjust fly speed
##   Esc    release the mouse
##
## Layout is a nested grid rather than a radial tree: every folder (or every
## parent in dependency mode) owns a rectangular block, and its children are
## shelf-packed inside it. Seen from above this reads like a file explorer,
## and it stays far more compact than a radial layout -- a radial tree pushes
## each level outward by a fixed step, so deep projects sprawl and become
## tedious to fly across.
##
## Depth is encoded as height instead of radius, so hierarchy is still
## readable from the side.

const OrphanScanner = preload("res://addons/godot_dependency_atlas/orphan_scanner.gd")
const FlyCamera = preload("res://addons/godot_dependency_atlas/graph3d/fly_camera.gd")
const TypeIcons = preload("res://addons/godot_dependency_atlas/graph3d/type_icons.gd")
const GraphMetrics = preload("res://addons/godot_dependency_atlas/graph3d/graph_metrics.gd")
const CodeLinks = preload("res://addons/godot_dependency_atlas/graph3d/code_links.gd")
const OFConfig = preload("res://addons/godot_dependency_atlas/graph3d/of_config.gd")
const OFThemes = preload("res://addons/godot_dependency_atlas/graph3d/of_themes.gd")
const FilterWindow = preload("res://addons/godot_dependency_atlas/graph3d/filter_window.gd")
const LegendWindow = preload("res://addons/godot_dependency_atlas/graph3d/legend_window.gd")
const PaletteWindow = preload("res://addons/godot_dependency_atlas/graph3d/palette_window.gd")
const ColourOverrides = preload("res://addons/godot_dependency_atlas/graph3d/colour_overrides.gd")
const ThemeStore = preload("res://addons/godot_dependency_atlas/graph3d/theme_store.gd")
const DeletionManager = preload("res://addons/godot_dependency_atlas/graph3d/deletion_manager.gd")
const NamingAffinity = preload("res://addons/godot_dependency_atlas/graph3d/naming_affinity.gd")
const LayoutDiagnostics = preload("res://addons/godot_dependency_atlas/graph3d/layout_diagnostics.gd")
const PermissionDialog = preload("res://addons/godot_dependency_atlas/graph3d/permission_dialog.gd")
const LanguageAnalyzer = preload("res://addons/godot_dependency_atlas/language_analyzer.gd")
const MoveRefactorDialog = preload("res://addons/godot_dependency_atlas/refactor/move_refactor_dialog.gd")
const RefactorEngine = preload("res://addons/godot_dependency_atlas/refactor/refactor_engine.gd")
const DeletionWarningScene = preload("res://addons/godot_dependency_atlas/deletion_warning_overlay.tscn")

enum LayoutMode { DEPENDENCY, FOLDER }
## Optional overlays, both off by default and both driven from a selection.
##   PATHS  every chain from an entry point to the selected file
##   BLAST  everything that would be affected by changing it
enum AnalysisMode { NONE, PATHS, BLAST }
## Stages of the gather animation. Nodes always return home before gathering
## around a new selection, never morph directly between arrangements.
enum GatherStage { IDLE, RETURNING, GATHERING }
## How a weighted connection is drawn.
##   STRAND_FLAT  one line per line-of-code, fanned into a flat ribbon
##   STRAND_TUBE  same strands, wrapped around the edge axis like a cable
##   SOLID_TUBE   a single solid tube per direction, radius scaled by weight
enum LineStyle { STRAND_FLAT, STRAND_TUBE, SOLID_TUBE }

# --- grid layout -------------------------------------------------------------
const CELL_SIZE := 3.0        # footprint of a single file
const BLOCK_PADDING := 2.0    # margin a folder keeps around its contents
const LAYER_HEIGHT := 10.0    # vertical drop per depth level (grid)
const TARGET_ASPECT := 1.0    # 1.0 packs blocks toward square


const NODE_MIN_SIZE := 0.35
const NODE_MAX_SIZE := 1.6
const DIR_NODE_SIZE := 0.75
const SATELLITE_OFFSET := 1.15
const ORPHAN_GAP := 8.0
## Max distance at which labels and icons are drawn -- ONLY applied when
## distance culling is switched on (L). Off by default: labels are always
## visible at any range. Tune freely; it has no effect while culling is off.
const LABEL_VIEW_DISTANCE := 90.0

# --- label legibility --------------------------------------------------------
const LABEL_FONT_SIZE := 48
const LABEL_PIXEL_SIZE := 0.010
## Extra clearance above the node so the text isn't sitting on the icon.
const LABEL_LIFT := 0.55

## Minimum on-screen label height, in pixels. Distant labels are scaled up so
## they never shrink below these, which is what keeps a selection's
## neighbourhood readable when it is spread across the graph.
const MIN_LABEL_PIXELS_SELECTED := 12.0   # selection + its direct connections
const MIN_LABEL_PIXELS_GLOBAL := 11.0     # everything else, only when M is on
## The selected node's own label is drawn a little larger again.
const SELECTED_LABEL_SCALE := 1.20   # the selection itself, relative to its neighbours

# --- analysis overlays -------------------------------------------------------
const COLOR_PATH := Color(0.40, 1.00, 0.55)     # a live chain from an entry point
const COLOR_BLAST := Color(1.00, 0.55, 0.25)      # directly depends on it
## How many hops of impact are highlighted. Impact genuinely weakens with
## distance -- a scene that loads a script that loads a texture is barely
## affected by that texture changing -- and an unbounded closure from a leaf
## asset lights up practically the whole project, which tells you nothing.
## The full transitive figure is still reported alongside.
const MAX_BLAST_HOPS := 2

# --- gather-on-selection -----------------------------------------------------
## Pulls a selection's immediate relations in around it, then releases them
## when the selection changes. Vertical placement encodes direction: things
## that depend on the selection go above, things it depends on go below.
const GATHER_SECONDS := 0.5
## Gathered blocks stay on the selection's own plane. Lifting them vertically
## made it harder to see where a node had come from, which matters more than
## encoding the direction in the layout -- direction is already carried by the
## edge colours (amber outgoing, cyan incoming).
const GATHER_SIDE_GAP := 5.0        # lateral gap between the two directions
## Spacing between relation roots in the gathered grid. Fixed, so a relation
## carrying a large branch does not push its neighbours away.
const GATHER_ROOT_PITCH := 7.0
## Spacing inside a packed naming group.
## Fallback spacing inside a packed group. The real spacing is measured from
## the filenames themselves -- a fixed value cannot work when one group holds
## "UI.gd" and another holds "RA_SelectVoxelVolume.gd", whose label is nearly
## four world units wide and overlaps its neighbour at any fixed pitch.
const GROUP_CELL := 4.0
## Roughly how wide a glyph is in world units at the default label size.
const LABEL_GLYPH_WIDTH := LABEL_PIXEL_SIZE * float(LABEL_FONT_SIZE) * 0.55
const GROUP_CELL_PADDING := 1.4
## Fewest files sharing one parent before they are packed as a set. Two is
## coincidence; three or more is a pattern.
const SHARED_PARENT_MIN := 3
## Naming groups at or below this size defer to a shared-parent set, which is
## usually the stronger structural signal.
const SMALL_GROUP_LIMIT := 3
## Above this many referrers a file is shared infrastructure rather than part
## of one set, and grouping it with any single owner would be misleading.
const SHARED_PARENT_MAX_OWNERS := 3
## A sink with this many consumers is shared infrastructure. It belongs near
## the centre of all consumers, not beside whichever one happened to place it.
const SHARED_SINK_MIN_CONSUMERS := 4
## Fewest same-folder, same-type files before the final sweep grids them.
const LOOSE_GRID_MIN := 4
## How far a family member may sit from its siblings before the verification
## pass treats the family as broken and regrids it.
const FAMILY_MAX_SPREAD := 45.0
const FAMILY_BASE_GAP := 6.0
## How many positions to try before accepting an overlap. Bounded so a very
## crowded layout degrades rather than stalling.
const RESERVE_ATTEMPTS := 40
const RESERVE_MARGIN := 3.0

# --- proximity relaxation ----------------------------------------------------
## Pulls loosely-connected files toward whatever references them.
##
## The grid layout places a node by traversal depth, which can strand a file
## far from its only referrer -- visually implying no relationship where there
## is a direct one. A few relaxation passes fix that without rebuilding the
## layout from scratch.
## Enough passes for a heavily-damped hub to actually arrive. A node with 50+
## links moves at a tenth of a leaf's speed, so a low iteration count leaves
## it stranded partway -- which looks like a bug rather than a setting.
const RELAX_ITERATIONS := 220
## Stops early once the largest single movement falls below this, so the cost
## is paid only where the layout is genuinely still settling.
const RELAX_SETTLE_EPSILON := 0.05
const RELAX_STRENGTH := 0.30
## Nodes stop being pulled once this close, so they settle beside each other
## rather than converging onto the same point.
const RELAX_REST_DISTANCE := 6.0
## Movement is damped by connection count rather than cut off by it.
##
## A hard cap looked sensible but was backwards: a hub with 25 dependents was
## frozen in place while all 25 were pulled toward IT, so the one node most
## worth relocating never moved. Damping lets a hub drift toward its
## dependents, just more slowly than a leaf does, which is the behaviour a
## force-directed layout actually needs.
const RELAX_HUB_DAMPING := 6.0
## Past this, a node is genuinely structural and is left alone.
const RELAX_MAX_CONNECTIONS := 60
## Margin kept clear around the gathered cluster when pushing bystanders out.
const GATHER_CLEARANCE := 4.0
## Ceiling on how much of a branch travels with a relation, so one hub node
## cannot drag most of the project along with it.
const GATHER_MAX_SUBTREE := 60
## Above this many relations, gathering is skipped entirely. Rearranging a
## hub with hundreds of connections produces a wall that is harder to read
## than the original layout -- the selection highlighting already conveys the
## relationships in that case.
const GATHER_MAX_RELATIONS := 45
const MAX_TRACED_PATHS := 12
const MAX_PATH_DEPTH := 24
## Hard ceiling on search expansion: enumerating every path through a dense
## graph is exponential, and a stalled UI is worse than a truncated answer.
const PATH_SEARCH_BUDGET := 40000

# --- path trace animation ----------------------------------------------------
## A pulse travels each traced chain from the entry point to the selection,
## lighting the edge behind it and the node it lands on. Watching the route
## unfold reads far more clearly than seeing the whole chain appear at once.
const TRACE_EDGE_SECONDS := 0.35     # travel time per edge
const TRACE_NODE_SECONDS := 0.18     # pause on each node before moving on
const TRACE_PULSE_SIZE := 0.55
const TRACE_LOOP_DELAY := 1.2        # pause before the trace replays
const COLOR_TRACE_PULSE := Color(0.75, 1.00, 0.85)
## How much a selected node is lightened, so it reads as active without
## losing its type colour.
const SELECTED_LIGHTEN := 0.30
## Outline is measured in the same units as LABEL_FONT_SIZE. It only needs to
## be a couple of pixels for contrast -- earlier values of 20-26 against a
## font size of 48 made the outline over half the glyph height, which forces
## Godot to build a heavily dilated glyph atlas and fills far more pixels than
## the text itself.
const LABEL_OUTLINE_SIZE := 5
const LABEL_BRIGHTEN := 0.45        # blend node colour toward white for contrast
const LABEL_DIM_TARGET := Color(0.20, 0.21, 0.26)   # what dimmed labels fade toward

# --- root emphasis / code-link strands ---------------------------------------
const ROOT_NODE_SIZE := 2.6
const MAX_STRANDS := 12             # cap so a hot edge stays a cable, not a wall
const STRAND_SPACING := 0.16
const STRAND_RING_RADIUS := 0.22   # cable radius in the STRAND_TUBE line style
const TUBE_SIDES := 8
const TUBE_MIN_RADIUS := 0.05
const TUBE_RADIUS_PER_LINK := 0.035
const TUBE_MAX_RADIUS := 0.55
const PAIR_SEPARATION := 0.5       # gap between the two directions of a pair
const TOAST_SECONDS := 2.2
const COLOR_ROOT := Color(1.0, 0.85, 0.35)
const COLOR_OUT := Color(1.0, 0.78, 0.35)    # selection -> others
const COLOR_IN := Color(0.40, 0.85, 1.00)    # others -> selection
## Orphans whose code was found elsewhere, split by how likely they are to
## still be wanted:
##   PROXIED     resources and shaders -- almost always still in use, so a
##               calm teal rather than a warning colour
##   DUPLICATED  everything else -- amber, because those need a closer look
const COLOR_PROXIED := Color(0.35, 0.85, 0.78)
const COLOR_DUPLICATED := Color(1.0, 0.72, 0.30)

## Pseudo-path for the collapsed orphan cube. Prefixed with "::" so it can
## never collide with a real res:// path.
## Two markers, because the two kinds of orphan mean different things: a
## cluster is a dead subsystem that should be reviewed as a unit, while lone
## orphans are individually droppable leftovers.
const ORPHAN_HUB := "::orphans"          # lone orphans, nothing references them
const CLUSTER_HUB := "::orphan_clusters" # orphans that reference each other
const ORPHAN_HUB_SIZE := 2.2
## How far below the live tree orphans sit, measured in LAYER_HEIGHT units so
## it scales with the layout rather than being an arbitrary distance. Puts
## dead code on its own plane: look down and the orphan world is separated
## from the reachable one, which also makes the inlined-copy links (U) legible
## as clear vertical runs instead of lines lost in the tree.
const ORPHAN_DEPTH_LEVELS := 2.5
## Extra drop between the orphan tiers, so the three groups read as separate
## planes when looking down: the cube marker on top, then orphans whose code
## was found embedded elsewhere, then everything else.
const ORPHAN_TIER_DROP := 1.0

# --- embedded-code orphans ---------------------------------------------------
## Resources and shaders are nearly always still wanted even when nothing
## references them, so they get their own tier plus a proxy drawn in the tree
## at the point their code is actually embedded.
const PROXY_KINDS := ["tres", "res", "gdshader", "gdshaderinc"]
## Prefix marking a proxy pseudo-path, so it can be positioned and picked
## without colliding with the real file's entry.
const PROXY_PREFIX := "::proxy::"
const PROXY_DROP := 1.2            # layers below the host it is embedded in
const PROXY_SIZE := 0.5
const DASH_LENGTH := 0.9
const DASH_GAP := 0.7

## "Inlined copy" links: a standalone resource whose exact code was found
## embedded inside a live file. Usually the result of Make Unique, which
## inlines a resource and silently orphans the original.
const COLOR_EMBED_LINK := Color(0.72, 0.42, 1.00)     # purple
## Dependencies between orphans. Real relationships, but inside dead code, so
## they're muted to avoid reading as live wiring.
const COLOR_ORPHAN_EDGE := Color(0.66, 0.40, 0.38, 0.5)

## Extra breathing room around the node's actual rendered bounds. Picking
## derives its base radius from the Sprite3D texture dimensions (or the real
## fallback mesh), rather than from the unrelated layout-size value.
const PICK_VISUAL_PADDING := 1.15
## Floor on tolerance, as a fraction of distance to the node. Keeps a node
## that projects to a couple of pixels reachable without handing distant nodes
## a large grab area.
const PICK_MIN_ANGULAR := 0.006
const CROSSHAIR_HALF := 14.0
## Hold this long for a context menu (touch, or mouse press-and-hold).
const LONG_PRESS_SECONDS := 0.5
const LONG_PRESS_MOVE_TOLERANCE := 12.0
## Marker above a file that embeds someone else's code. A warning sign rather
## than a dot: a coloured dot was too easily confused with the embedded-code
## nodes themselves, whereas a warning glyph clearly means "look at this".
## Sits just above the label rather than on the icon itself: overlapping the
## icon obscured the file type it was badging, and the separation reads more
## clearly at a glance.
const EMBED_MARKER_SIZE := 0.34
const COLOR_EMBED_MARKER := Color(1.0, 0.85, 0.15)
## Clearance above the label. Applied on top of the label's own height, which
## already scales with node size, so the badge tracks the label rather than
## drifting into it on large nodes.
const EMBED_MARKER_LIFT := 0.68

# --- panels ------------------------------------------------------------------
const LEFT_PANEL_WIDTH := 300.0
const RIGHT_PANEL_WIDTH := 420.0
const PANEL_MIN_WIDTH := 180.0
## Toolbar sizing is exposed on GraphViewer so it can be tuned in the
## Inspector without fighting child-control minimums.
@export_range(8.0, 256.0, 1.0) var toolbar_min_height := 24.0
@export_range(8.0, 512.0, 1.0) var toolbar_max_height := 64.0
@export_range(8.0, 256.0, 1.0) var toolbar_initial_height := 24.0
@export var toolbar_show_labels := false
const TREE_ICON_SIZE := 16    # matches the editor FileSystem dock

# --- icons / selection -------------------------------------------------------
const ICON_PIXEL_SIZE := 0.022
const ICON_VIEW_DISTANCE := 200.0
const DIM_ALPHA := 0.4
const COLOR_ORPHAN := Color(1.0, 0.32, 0.30)
const COLOR_CYCLE := Color(1.0, 0.25, 0.95)
const COLOR_HIGHLIGHT := Color(1.0, 0.95, 0.5, 1.0)
const COLOR_BLOCK := Color(0.42, 0.46, 0.55, 0.30)

const SIDECAR_EXTENSIONS := ["import", "uid"]

var _camera: Camera3D
var _status_label: Label
var _info_label: RichTextLabel
var _help_label: Label
var _top_bar: VBoxContainer
var _toolbar_buttons := {}
var _toolbar_help: Button
var _toolbar_help_popup: PopupPanel
var _toolbar_help_list: VBoxContainer
var _left_panel: PanelContainer
var _right_panel: PanelContainer
var _left_show_button: Button
var _right_show_button: Button
var _file_tree: Tree
var _file_menu: PopupMenu
var _file_filter: LineEdit
var _filter_text := ""
var _isolate_mode := false
var _isolate_set := {}
var _hidden_kinds := {}
var _cycles_label: RichTextLabel
var _filter_window: Window
var _visibility_window: Window
var _view_hidden_kinds := {}
var _view_hidden_extensions := {}
var _legend_window: Window
var _open_dialog: FileDialog
var _scan_root := "res://"
var _theme_id := OFThemes.DEFAULT_THEME
var _connection_theme_id := OFThemes.DEFAULT_CONNECTION_THEME
var _overrides = ColourOverrides.new()
var _deletion = DeletionManager.new()
var _permission_dialog: ConfirmationDialog
var _confirm_delete_dialog: ConfirmationDialog
var _move_refactor_dialog
var _deletion_warning: DeletionWarningOverlay
var _pending_delete := ""
var _diagnostics_dialog: AcceptDialog
var _diagnostics_input: LineEdit
var _name_groups := {}        # group key -> { token, dir, members, confidence }
var _name_group_of := {}      # path -> group key
var _parent_of := {}          # path -> the file it extends
var _group_affinity := true
var _relax_layout := true
var _hierarchy_placed := {}   # bases positioned by _centre_hierarchy_bases
var _grid_placed := {}        # files positioned by a grid pass, never relaxed apart
## Rectangles already claimed by a placed block, per layer. Without this the
## passes place blocks independently and they land on top of each other --
## which is what turned the graph into one dense pile rather than a set of
## readable grids.
var _reserved := []
var _node_palette_window: Window
var _connection_palette_window: Window
var _hidden_extensions := {}
var _custom_extensions: Array = []
var _project_extensions := {}
var _last_log_text := ""
var _godot_pass_used := true
var _godot_dependency_files := 0
var _save_dialog: FileDialog
var _theme_root := COLOR_ROOT
var _theme_orphan := COLOR_ORPHAN
var _theme_cycle := COLOR_CYCLE
var _theme_out := COLOR_OUT
var _theme_in := COLOR_IN
var _theme_proxied := COLOR_PROXIED
var _theme_duplicated := COLOR_DUPLICATED
var _theme_dangling := COLOR_ORPHAN_EDGE
var _theme_inline := COLOR_EMBED_LINK
var _theme_path := COLOR_PATH
var _theme_impact := COLOR_BLAST
var _theme_pulse := COLOR_TRACE_PULSE
## Global connection opacity controls, persisted in [display] inside
## dependency-atlas.config for easy per-project tuning.
var idle_connection_alpha := OFConfig.DEFAULT_IDLE_CONNECTION_ALPHA
var selected_connection_alpha := OFConfig.DEFAULT_SELECTED_CONNECTION_ALPHA
var _world_env: WorldEnvironment
var _theme_is_dark := true
var _theme_background := Color(0.07, 0.08, 0.11)
var _sprites_root: Node3D
var _labels_root: Node3D
var _label_distance_culling := false
var _min_label_global := false
var _label_scale_dirty := true
var _last_label_camera := Transform3D()
var _progress_overlay: Label
var _rebuilding := false
var _toast_label: Label
var _toast_time := 0.0
var _suppress_tree_signal := false
var _tree_items := {}
var _root_split: HSplitContainer
var _inner_split: HSplitContainer
var _viewport_spacer: Control
var _crosshair: Control

var _graph := {}
var _edge_kinds := {}
var _dep_depth := {}
var _dep_parent := {}
var _orphan_set := {}
## path -> the reachable file its content is duplicated inside, when the
## scanner found one. Explains an otherwise baffling orphan result.
var _orphan_notes := {}
var _proxy_of := {}      # proxy pseudo-path -> the real orphan it stands for
var _orphan_graph := {}   # references between orphans, for the dead-cluster forest
var _reverse_graph := {}  # target -> everything referencing it
var _analysis_mode: AnalysisMode = AnalysisMode.NONE
var _analysis_nodes := {}
var _analysis_edges := {}
var _analysis_paths: Array = []
var _analysis_depth := {}
var _blast_total_count := 0
var _trace_active := false
var _trace_step := 0
var _trace_t := 0.0
var _trace_delay := 0.0
var _trace_reached := {}
var _trace_edges_done := {}
var _trace_pulses: MultiMeshInstance3D
## Off by default: rearranging the layout is a deliberate act, and leaving it
## on means every click reshuffles the view whether you wanted that or not.
var _gather_enabled := false
var _gather_stage: GatherStage = GatherStage.IDLE
var _gather_t := 0.0
var _gather_nodes := {}
var _gather_from := {}
var _gather_to := {}
var _home_positions := {}
var _pending_gather := false
var _home_target := Vector3.ZERO
var _home_standoff := Vector3.ZERO
var _node_menu: PopupMenu
var _menu_target := ""
var _press_time := 0.0
var _press_position := Vector2.ZERO
var _press_active := false
var _press_consumed := false
var _tree_press_time := 0.0
var _tree_press_active := false
var _tree_press_consumed := false
var _lone_orphans_expanded := false
var _cluster_orphans_expanded := false
## On by default: an orphan whose code is running from an inlined copy is the
## least obvious and most consequential case the tool finds, and hiding the
## link that explains it made it easy to mistake for ordinary dead code.
var _show_embed_links := true
var _embed_hosts := {}   # live file -> the standalone resources it inlines
var _orphan_hub_mesh: MeshInstance3D
var _warning_icon: Texture2D      # round: shown ON an embedded-code orphan
var _host_badge_icon: Texture2D   # triangle: badge on a file that embeds code
var _metrics := {}
var _max_hub_score := 1

var _layout_mode: LayoutMode = LayoutMode.DEPENDENCY
var _line_style: LineStyle = LineStyle.STRAND_FLAT
var _show_sidecars := false
var _heat_mode := false
var _pair_scripts := true

var _positions := {}
var _sizes := {}
var _block_size := {}   # path -> Vector2(width, depth) of its grid block
var _depth := {}
var _in_degree := {}
var _dir_nodes := {}
var _selected := ""
var _scan_done := false
var _roots: Array = []
var _content_cache := {}
var _class_index := {}   # class_name -> defining file
var _link_graph := {}    # source -> { target -> lines of code touching it }
var _weighted_out := {}  # file -> total lines it spends on others
var _weighted_in := {}   # file -> total lines others spend on it
var _max_weighted_hub := 1

var _icon_textures := {}
var _sprites := {}
var _labels := {}
var _sphere_paths: Array = []

var _mesh_instance: MultiMeshInstance3D
var _edge_mesh_instance: MeshInstance3D
var _visuals_root: Node3D


func _ready() -> void:
	_build_environment()
	_build_ui()
	_deletion_warning = DeletionWarningScene.instantiate()
	_viewport_spacer.add_child(_deletion_warning)
	_build_camera()
	_load_settings()
	_load_icons()
	await _run_scan()


## Runs (or re-runs) the whole pipeline against the current _scan_root.
## Separated from _ready so opening another project reuses it verbatim.
func _run_scan() -> void:
	_scan_done = false
	_selected = ""
	_graph.clear()
	_edge_kinds.clear()
	_orphan_set.clear()
	_orphan_notes.clear()
	_proxy_of.clear()
	_orphan_graph.clear()
	_parent_of.clear()
	_reverse_graph.clear()
	_embed_hosts.clear()
	_in_degree.clear()
	_content_cache.clear()
	_class_index.clear()
	_link_graph.clear()
	_weighted_in.clear()
	_weighted_out.clear()
	_project_extensions.clear()

	# The previous answer was given about a list that no longer exists.
	_deletion.configure(_scan_root)
	_deletion.revoke()
	_deletion_warning.set_warning_enabled(false)
	OrphanScanner.scan_root = _scan_root
	OrphanScanner.log_dir = OFConfig.log_dir(_scan_root)
	var layout_problem := OFConfig.ensure_layout(_scan_root)
	if layout_problem != "":
		push_warning("Dependency Atlas: " + layout_problem)
	_load_settings()

	_status_label.text = "Scanning %s..." % _scan_root
	await get_tree().process_frame

	var result: Dictionary = await OrphanScanner.scan_async(
		func(phase: String, done: int, total: int):
			var pretty := phase.capitalize()
			if total > 0:
				_set_progress("%s… %d%%" % [pretty, int(float(done) / float(maxi(total, 1)) * 100.0)])
			else:
				_set_progress("%s…" % pretty)
			_status_label.text = "%s: %d%s" % [phase, done, "" if total <= 0 else " / %d" % total]
	)

	var error: String = result.get("error", "")
	if error != "":
		_status_label.text = "Scan failed: " + error
		return

	_last_log_text = String(result.get("log_text", ""))
	_godot_pass_used = bool(result.get("godot_pass_used", false))
	_godot_dependency_files = int(result.get("godot_dependency_files", 0))
	_orphan_graph = result.get("orphan_graph", {})
	_graph = result.get("graph", {})
	_edge_kinds = result.get("edge_kinds", {})
	_dep_depth = result.get("depth", {})
	_dep_parent = result.get("tree_parent", {})
	for o in result.get("orphans", []):
		var od: Dictionary = o
		_orphan_set[String(od["path"])] = true
		if od.has("duplicated_in"):
			_orphan_notes[String(od["path"])] = String(od["duplicated_in"])
	_build_embed_hosts()

	_set_progress("Indexing results…")
	await _breathe()

	# Every extension actually present, so the filter window offers real
	# choices rather than a fixed guess at what a project might contain.
	for key in _graph.keys():
		_project_extensions[String(key).get_extension().to_lower()] = true
		for r in _graph[key]:
			_project_extensions[String(r).get_extension().to_lower()] = true
	for key in _orphan_set.keys():
		_project_extensions[String(key).get_extension().to_lower()] = true
	_project_extensions.erase("")

	_compute_in_degrees()
	_set_progress("Building reverse index…")
	await _breathe()
	_build_reverse_graph()
	await _build_class_index()
	await _build_link_graph_async()
	_set_progress("Analysing coupling and cycles…")
	await _breathe()
	_metrics = GraphMetrics.analyze(_graph, _edge_kinds)
	_max_hub_score = 1
	for key in _metrics["per_file"].keys():
		_max_hub_score = maxi(_max_hub_score, int(_metrics["per_file"][key]["hub_score"]))

	_scan_done = true
	# Naming convention is evidence the dependency graph does not carry: two
	# files can belong to one feature without referencing each other.
	var hierarchy: Dictionary = result.get("hierarchy", {})
	_parent_of = hierarchy.get("parent_of", {})
	_name_groups = NamingAffinity.analyse(_all_paths())
	# Inheritance overrides the naming grouping: a prefix family that is
	# really a class hierarchy gets split by level instead of flattened.
	_name_groups = NamingAffinity.apply_hierarchy(_name_groups, _parent_of)
	_name_group_of = NamingAffinity.membership(_name_groups)
	_populate_cycles_panel()
	await _rebuild_all()
	_save_settings()


## Applies a palette everywhere: node/type colours come from TypeIcons, and
## the role colours (root, orphan, cycle, edge directions) are cached here
## because they are read every frame during edge building.
func _apply_theme(theme_id: String) -> void:
	_theme_id = theme_id
	# Built with overrides applied, so a customised colour survives into the
	# icon tinting and everything else that reads the palette.
	var kinds := {}
	for kind_value in TypeIcons.Kind.values():
		var kind_name: String = TypeIcons.Kind.keys()[int(kind_value)]
		kinds[kind_name] = _overrides.node_kind_color(theme_id, kind_name)
	TypeIcons.set_palette(kinds)
	_theme_root = _overrides.node_role_color(theme_id, "root")
	_theme_orphan = _overrides.node_role_color(theme_id, "orphan")
	_theme_cycle = _overrides.node_role_color(theme_id, "cycle")
	# Connection and analysis colours follow the palette too, so a theme
	# changes the whole view rather than only the nodes.
	_theme_is_dark = OFThemes.is_dark(theme_id)
	_theme_background = _overrides.node_role_color(theme_id, "background")
	if _world_env != null:
		_world_env.environment.background_color = _theme_background
		# Ambient has to follow the background or a light theme renders the
		# unshaded geometry against a washed-out sky.
		_world_env.environment.ambient_light_color = (
			Color(0.6, 0.6, 0.7) if _theme_is_dark else Color(0.35, 0.35, 0.40)
		)
	_apply_connection_theme()
	_apply_label_theme()


## Re-tints existing labels when the theme changes without a full rebuild.
## Connection colours come from their own theme and their own overrides, so
## the two palettes can be combined freely.
func _apply_connection_theme() -> void:
	_theme_out = _overrides.connection_color(_connection_theme_id, "out")
	_theme_in = _overrides.connection_color(_connection_theme_id, "in")
	_theme_dangling = _overrides.connection_color(_connection_theme_id, "dangling")
	_theme_inline = _overrides.connection_color(_connection_theme_id, "inline")
	_theme_path = _overrides.connection_color(_connection_theme_id, "path")
	_theme_impact = _overrides.connection_color(_connection_theme_id, "impact")
	_theme_pulse = _overrides.connection_color(_connection_theme_id, "pulse")


func _apply_label_theme() -> void:
	for key in _labels.keys():
		var path: String = key
		var label: Label3D = _labels[path]
		label.modulate = _label_color(_color_for(path))
		label.outline_modulate = Color.BLACK if _theme_is_dark else Color.WHITE


func _label_color(base: Color) -> Color:
	# Blend toward white on dark themes and toward black on light ones, so
	# text keeps contrast against the background either way.
	return base.lerp(Color.WHITE if _theme_is_dark else Color.BLACK, LABEL_BRIGHTEN)


func _load_icons() -> void:
	for kind_value in TypeIcons.Kind.values():
		var kind = kind_value
		var texture := _load_exported_icon(TypeIcons.icon_path_for(kind))
		if texture != null:
			_icon_textures[kind] = texture
	_warning_icon = _load_exported_icon(TypeIcons.special_icon_path("node_warning"))
	_host_badge_icon = _load_exported_icon(TypeIcons.special_icon_path("host_badge"))
	_apply_toolbar_icons()
	_sync_toolbar_buttons()


func _compute_in_degrees() -> void:
	for key in _graph.keys():
		for r in _graph[key]:
			_in_degree[String(r)] = int(_in_degree.get(String(r), 0)) + 1


func _is_hidden(path: String) -> bool:
	if not _show_sidecars and path.get_extension().to_lower() in SIDECAR_EXTENSIONS:
		return true
	# Kind filtering removes files from the graph entirely, not just from the
	# render, so hiding textures actually simplifies the layout rather than
	# leaving holes in it.
	if _hidden_kinds.has(int(TypeIcons.kind_of(path))):
		return true
	if _hidden_extensions.has(path.get_extension().to_lower()):
		return true
	return false


## In isolate mode only the selection and its direct neighbours are drawn.
## Everything keeps its layout position, so toggling back is not disorienting.
func _is_view_hidden(path: String) -> bool:
	if path == ORPHAN_HUB or path == CLUSTER_HUB or _dir_nodes.has(path):
		return false
	var actual := _resolve_proxy(path)
	if _view_hidden_kinds.has(int(TypeIcons.kind_of(actual))):
		return true
	return _view_hidden_extensions.has(actual.get_extension().to_lower())


func _is_displayed(path: String) -> bool:
	if _is_view_hidden(path):
		return false
	if not _isolate_mode or _selected == "":
		return true
	return _isolate_set.has(path)


# ------------------------------------------------------------------ tree building

func _all_paths() -> Array:
	var out := {}
	for key in _graph.keys():
		if not _is_hidden(String(key)):
			out[String(key)] = true
		for r in _graph[key]:
			if not _is_hidden(String(r)):
				out[String(r)] = true
	for key in _orphan_set.keys():
		if not _is_hidden(String(key)):
			out[String(key)] = true
	var list: Array = out.keys()
	list.sort()
	return list


func _build_dependency_tree() -> Dictionary:
	var children := {}
	var depth := {}
	var roots: Array = []

	for key in _graph.keys():
		var node: String = key
		if _is_hidden(node):
			continue
		depth[node] = int(_dep_depth.get(node, 0))
		if int(depth[node]) == 0:
			roots.append(node)

	for key in _dep_parent.keys():
		var child: String = key
		if _is_hidden(child):
			continue
		var parent: String = _dep_parent[child]
		if _is_hidden(parent):
			continue
		if not children.has(parent):
			children[parent] = []
		children[parent].append(child)
		if not depth.has(child):
			depth[child] = int(_dep_depth.get(child, 0))

	return {"children": children, "depth": depth, "roots": roots}


func _build_folder_tree() -> Dictionary:
	var children := {}
	var depth := {}
	var root := "res://"
	depth[root] = 0
	_dir_nodes.clear()
	_dir_nodes[root] = true

	for p in _all_paths():
		var path: String = p
		var parts := path.trim_prefix("res://").split("/")
		var current := root
		for i in parts.size() - 1:
			var next_dir: String = current.path_join(parts[i])
			if not _dir_nodes.has(next_dir):
				_dir_nodes[next_dir] = true
				depth[next_dir] = int(depth.get(current, 0)) + 1
				if not children.has(current):
					children[current] = []
				children[current].append(next_dir)
			current = next_dir
		depth[path] = int(depth.get(current, 0)) + 1
		if not children.has(current):
			children[current] = []
		children[current].append(path)

	return {"children": children, "depth": depth, "roots": [root]}


# ------------------------------------------------------------------ ordering

func _kind_rank(path: String) -> int:
	if _dir_nodes.has(path):
		return -1
	return int(TypeIcons.kind_of(path))


func _is_scene(path: String) -> bool:
	return TypeIcons.kind_of(path) == TypeIcons.Kind.SCENE


func _is_attachment(path: String) -> bool:
	var kind = TypeIcons.kind_of(path)
	return kind == TypeIcons.Kind.SCRIPT or kind == TypeIcons.Kind.SHADER or kind == TypeIcons.Kind.RESOURCE


## Sorts siblings by kind (folders first, like an explorer), then hoists each
## scene's own scripts to sit directly after it, since a .tscn and the script
## on its root node are conceptually one unit.
func _order_siblings(kids: Array) -> Array:
	var by_kind: Array = kids.duplicate()
	by_kind.sort_custom(func(a, b):
		var ra := _kind_rank(String(a))
		var rb := _kind_rank(String(b))
		if ra != rb:
			return ra < rb
		return String(a).get_file() < String(b).get_file()
	)

	var sibling_set := {}
	for k in kids:
		sibling_set[String(k)] = true

	var used := {}
	var ordered: Array = []
	for k in by_kind:
		var path: String = k
		if used.has(path):
			continue
		ordered.append(path)
		used[path] = true
		if not _is_scene(path):
			continue
		var attached: Array = []
		for r in _graph.get(path, []):
			var ref: String = r
			if sibling_set.has(ref) and not used.has(ref) and _is_attachment(ref):
				attached.append(ref)
		attached.sort_custom(func(a, b): return String(a).get_file() < String(b).get_file())
		for a in attached:
			ordered.append(String(a))
			used[String(a)] = true
	return ordered


# ------------------------------------------------------------------ grid layout

## Shelf-packs a list of already-sized child blocks into rows, aiming for a
## roughly square result. Returns the rows plus the overall extent.
func _pack_shelves(kids: Array) -> Dictionary:
	var rows: Array = []
	if kids.is_empty():
		return {"rows": rows, "width": 0.0, "depth": 0.0}

	var area := 0.0
	var widest := 0.0
	for k in kids:
		var b: Vector2 = _block_size.get(k, Vector2(CELL_SIZE, CELL_SIZE))
		area += b.x * b.y
		widest = maxf(widest, b.x)
	var target := maxf(sqrt(area * TARGET_ASPECT), widest)

	var current: Array = []
	var current_width := 0.0
	for k in kids:
		var path: String = k
		var b2: Vector2 = _block_size.get(path, Vector2(CELL_SIZE, CELL_SIZE))
		if not current.is_empty() and current_width + b2.x > target:
			rows.append(current)
			current = []
			current_width = 0.0
		current.append(path)
		current_width += b2.x
	if not current.is_empty():
		rows.append(current)

	var total_width := 0.0
	var total_depth := 0.0
	for r in rows:
		var row: Array = r
		var row_width := 0.0
		var row_depth := 0.0
		for k in row:
			var b3: Vector2 = _block_size.get(k, Vector2(CELL_SIZE, CELL_SIZE))
			row_width += b3.x
			row_depth = maxf(row_depth, b3.y)
		total_width = maxf(total_width, row_width)
		total_depth += row_depth

	return {"rows": rows, "width": total_width, "depth": total_depth}


## Shared node sizing: bigger with more incoming references, and the entry
## points made unmistakably large so it's obvious where the graph starts.
func _assign_node_sizes(nodes: Array) -> void:
	for n in nodes:
		var node: String = n
		if _roots.has(node):
			_sizes[node] = ROOT_NODE_SIZE
		elif _dir_nodes.has(node):
			_sizes[node] = DIR_NODE_SIZE
		else:
			_sizes[node] = clampf(
				NODE_MIN_SIZE + float(_in_degree.get(node, 0)) * 0.12, NODE_MIN_SIZE, NODE_MAX_SIZE
			)


## Nested grid layout. Sizes bottom-up so a parent's block is exactly big
## enough to contain its packed children, then places top-down. Blocks never
## overlap because a parent reserves its children's full extent.
func _layout_grid(tree: Dictionary) -> void:
	_positions.clear()
	_sizes.clear()
	_block_size.clear()

	var children: Dictionary = tree["children"]
	var depth: Dictionary = tree["depth"]
	var roots: Array = tree["roots"]
	if roots.is_empty():
		return
	_depth = depth

	for key in children.keys():
		children[key] = _order_siblings(children[key])

	var nodes: Array = depth.keys()

	# Bottom-up sizing.
	var by_depth_desc: Array = nodes.duplicate()
	by_depth_desc.sort_custom(func(a, b): return int(depth.get(a, 0)) > int(depth.get(b, 0)))
	for n in by_depth_desc:
		var node: String = n
		var kids: Array = children.get(node, [])
		if kids.is_empty():
			_block_size[node] = Vector2(CELL_SIZE, CELL_SIZE)
			continue
		var packed := _pack_shelves(kids)
		_block_size[node] = Vector2(
			float(packed["width"]) + BLOCK_PADDING,
			float(packed["depth"]) + BLOCK_PADDING
		)

	# Place roots side by side.
	var cursor_x := 0.0
	for i in roots.size():
		var root: String = roots[i]
		var b: Vector2 = _block_size.get(root, Vector2(CELL_SIZE, CELL_SIZE))
		_positions[root] = Vector3(cursor_x + b.x * 0.5, 0.0, 0.0)
		cursor_x += b.x + BLOCK_PADDING

	# Top-down placement: each child sits inside its parent's block.
	var by_depth_asc: Array = nodes.duplicate()
	by_depth_asc.sort_custom(func(a, b): return int(depth.get(a, 0)) < int(depth.get(b, 0)))
	for n in by_depth_asc:
		var node2: String = n
		var kids2: Array = children.get(node2, [])
		if kids2.is_empty() or not _positions.has(node2):
			continue
		var packed2 := _pack_shelves(kids2)
		var origin: Vector3 = _positions[node2]
		var start_x := origin.x - float(packed2["width"]) * 0.5
		var z := origin.z - float(packed2["depth"]) * 0.5
		var y := origin.y - LAYER_HEIGHT
		for r in packed2["rows"]:
			var row: Array = r
			var row_depth := 0.0
			for k in row:
				row_depth = maxf(row_depth, Vector2(_block_size.get(k, Vector2(CELL_SIZE, CELL_SIZE))).y)
			var x := start_x
			for k in row:
				var kid: String = k
				var kb: Vector2 = _block_size.get(kid, Vector2(CELL_SIZE, CELL_SIZE))
				_positions[kid] = Vector3(x + kb.x * 0.5, y, z + row_depth * 0.5)
				x += kb.x
			z += row_depth

	_assign_node_sizes(nodes)
	if _layout_mode == LayoutMode.DEPENDENCY:
		_place_satellites()
	_grid_placed.clear()
	_reserved.clear()
	# The tree already occupies space, so it is claimed first: otherwise the
	# grid passes treat the whole volume as empty and drop blocks on top of
	# nodes that are already there.
	_reserve_existing_nodes()
	_apply_group_depths()
	_centre_hierarchy_bases()
	_place_orphan_grid()
	# After orphan placement: an orphan asset set has no position until then,
	# and grouping something with no position does nothing. Runs in both
	# layouts, since an asset block is worth having either way.
	_pack_shared_parent_sets()
	# Catches whatever qualified for none of the rules above.
	_grid_remaining_assets()
	# Then checks the actual result and repairs families that came out split,
	# whatever the reason.
	_verify_and_repair_families()
	_place_shared_sinks_near_consumers()
	# Last, so it can pull stray files toward their references while every
	# grid built above stays intact.
	_relax_toward_neighbours()


## Nudges a script owned by exactly one scene to sit right beside it.
func _place_satellites() -> void:
	if not _pair_scripts:
		return
	for key in _positions.keys():
		var scene_path: String = key
		if not _is_scene(scene_path):
			continue
		var owned: Array = []
		for r in _graph.get(scene_path, []):
			var ref: String = r
			if not _positions.has(ref) or not _is_attachment(ref):
				continue
			if int(_in_degree.get(ref, 0)) != 1:
				continue  # shared scripts belong to no single scene
			if String(_dep_parent.get(ref, "")) != scene_path:
				continue
			owned.append(ref)
		if owned.is_empty():
			continue
		owned.sort()
		var origin: Vector3 = _positions[scene_path]
		for i in owned.size():
			var sat: String = owned[i]
			_positions[sat] = origin + Vector3(
				SATELLITE_OFFSET * (1.0 + float(i)), -LAYER_HEIGHT * 0.35, SATELLITE_OFFSET
			)


## Splits orphans into plain ones and ones whose code was found duplicated
## inside a live file. The second group is the dangerous one to delete.
## Inverts _orphan_notes: for each live file, which standalone resources have
## their code embedded inside it.
func _build_embed_hosts() -> void:
	_embed_hosts.clear()
	for key in _orphan_notes.keys():
		var orphan: String = key
		var host: String = _orphan_notes[orphan]
		if not _embed_hosts.has(host):
			_embed_hosts[host] = []
		_embed_hosts[host].append(orphan)


## Outgoing references for any file, whether it was reached or not. Orphan
## edges live in their own map because the traversal never visited them.
func _refs_of(path: String) -> Array:
	if _orphan_graph.has(path):
		return _orphan_graph[path]
	return _graph.get(path, [])


## Everything that references `path`, from both the live and orphan graphs.
func _referrers_of(path: String) -> Array:
	return _reverse_graph.get(path, [])


## True for orphans that get the proxy treatment: resources and shaders whose
## code was found embedded in a live file.
func _has_proxy(path: String) -> bool:
	return _orphan_notes.has(path) and path.get_extension().to_lower() in PROXY_KINDS


func _proxy_path_for(path: String) -> String:
	return PROXY_PREFIX + path


## The real file a node stands for: itself, unless it is a proxy.
func _resolve_proxy(path: String) -> String:
	return String(_proxy_of.get(path, path))


## Splits plain orphans by whether they take part in any orphan-to-orphan
## reference. A cluster is a dead subsystem; a lone orphan is a loose file.
func _split_lone_and_clustered(plain: Array) -> Dictionary:
	var connected := {}
	for p in plain:
		var path: String = p
		for r in _orphan_graph.get(path, []):
			var target: String = r
			if target != path:
				connected[path] = true
				connected[target] = true

	var lone: Array = []
	var clustered: Array = []
	for p2 in plain:
		var path2: String = p2
		if connected.has(path2):
			clustered.append(path2)
		else:
			lone.append(path2)
	return {"lone": lone, "clustered": clustered}


func _orphan_groups() -> Dictionary:
	var plain: Array = []
	var duplicated: Array = []
	var proxied: Array = []
	for key in _orphan_set.keys():
		var op: String = key
		if _is_hidden(op):
			continue
		if _has_proxy(op):
			proxied.append(op)
		elif _orphan_notes.has(op):
			duplicated.append(op)
		else:
			plain.append(op)

	var sorter := func(a, b):
		var ra := _kind_rank(String(a))
		var rb := _kind_rank(String(b))
		if ra != rb:
			return ra < rb
		return String(a).get_file() < String(b).get_file()
	plain.sort_custom(sorter)
	duplicated.sort_custom(sorter)
	proxied.sort_custom(sorter)
	return {"plain": plain, "duplicated": duplicated, "proxied": proxied}


## In DEPENDENCY mode the plain orphans are collapsed behind a red cube by
## default: they have no edges, so rendering thousands of disconnected nodes
## buries the graph you came to look at.
##
## Orphans whose code was found duplicated elsewhere are ALWAYS shown. They're
## effectively in use -- something is running their code -- so hiding them
## behind a toggle would bury exactly the cases that need attention.
##
## FOLDER mode never collapses anything: there, orphans sit in their real
## directory, which is the information you want.

## Nudges each naming group's members onto their shared average depth, so a
## feature reads as one horizontal band even when its files were reached at
## different distances from the entry point.
## Depth for a naming group: the average of its members' own depths.
##
## Members usually sit at slightly different depths -- a scene one hop from
## its script -- and averaging keeps the group together without treating any
## single member's depth as authoritative. The result can land between layers,
## which is intentional: it says "this group spans these levels".
func _group_depth(group_key: String) -> float:
	if not _name_groups.has(group_key):
		return -1.0
	var total := 0.0
	var counted := 0
	for m in (_name_groups[group_key]["members"] as Array):
		var path: String = m
		if _dep_depth.has(path):
			total += float(_dep_depth[path])
			counted += 1
	if counted == 0:
		return -1.0
	return total / float(counted)


## Packs each naming group into a compact grid at its own depth.
##
## Adjusting only the depth was not enough: members kept whatever X/Z the tree
## layout gave them, so a family like RA_* ended up strung diagonally across
## the graph at a consistent height rather than reading as one block. Files
## that belong together should LOOK like they belong together, which means
## occupying one rectangle, not one altitude.
##
## Within a group, members are sub-grouped by extension: a folder of forty
## textures collapses into a tidy sub-block instead of interleaving with the
## scripts beside it.
func _apply_group_depths() -> void:
	if not _group_affinity or _layout_mode != LayoutMode.DEPENDENCY:
		return

	for key_any in _name_groups.keys():
		var key: String = key_any
		var group: Dictionary = _name_groups[key]
		var members: Array = []
		for m in (group["members"] as Array):
			var path: String = m
			if _positions.has(path) and not _orphan_set.has(path):
				members.append(path)
		if members.size() < 2:
			continue

		var average := _group_depth(key)
		if average < 0.0:
			continue
		var level := int(group.get("hierarchy_level", 0))
		var target_y := -(average + float(level)) * LAYER_HEIGHT

		# Centre the block on where the group already sits, so packing tidies
		# the arrangement without teleporting it across the graph.
		var centre := Vector3.ZERO
		for m2 in members:
			centre += Vector3(_positions[m2])
		centre /= float(members.size())

		_square_grid(_order_by_kind(members), centre.x, target_y, centre.z)
		for m2 in members:
			_grid_placed[String(m2)] = true



## Centres a base class directly beneath the subclasses that extend it.
##
## A base sitting off to one side of its own family reads as unrelated, when
## it is the single most related file there is.
## Groups files that share a single parent and a file type, regardless of name.
##
## An atlas referencing forty textures with hashed filenames has no naming
## convention to exploit, but the graph still says they belong together: each
## is referenced by exactly one thing, and it is the same thing. Requiring a
## SOLE parent is what keeps this honest -- a file used in several places is
## shared infrastructure, not part of one set.
## Groups files that share a sole parent and a file type.
##
## Runs regardless of the naming toggle: this is structural evidence from the
## graph, not a naming convention, and a folder of assets should read as a
## block whether or not you asked for name-based grouping.
func _pack_shared_parent_sets() -> void:
	if _layout_mode != LayoutMode.DEPENDENCY:
		return

	# NOT cleared here: _apply_group_depths has already registered its naming
	# groups, and wiping them let relaxation pull those grids apart again.
	# Cleared once per rebuild instead, in _rebuild_all.
	var buckets := {}
	for key_any in _positions.keys():
		var path: String = key_any
		if _dir_nodes.has(path) or path.begins_with("::"):
			continue
		# A naming group only keeps a file if it is a substantial group. Two
		# assets sharing a first token ("MergeUp" / "MergeDown") is a weaker
		# signal than thirty files sharing one parent, and letting the small
		# group win was fragmenting whole asset sets into scattered pairs.
		if _name_group_of.has(path):
			var claimed_key := String(_name_group_of[path])
			var claimed: Array = (_name_groups.get(claimed_key, {}) as Dictionary).get("members", [])
			if claimed.size() > SMALL_GROUP_LIMIT:
				continue
		# Grouped by DOMINANT parent, not sole parent.
		#
		# Requiring exactly one referrer fragmented real asset sets: an icon
		# used by two scenes was skipped while its neighbours grouped, so a
		# folder of thirty SVGs came out half-packed and half-scattered. The
		# first referrer is stable (traversal order), and a file shared by a
		# handful of scenes still belongs with the set it came from.
		# Sidecars excluded from the count AND from the choice of owner.
		#
		# An imported asset is always referenced by its own .import file, so
		# every texture looked like it had two owners, and the sidecar could
		# even win as parents[0] -- which grouped assets by their own
		# bookkeeping rather than by the scene that uses them.
		var parents: Array = []
		for r in _referrers_of(path):
			var referrer: String = r
			if referrer.get_extension().to_lower() in SIDECAR_EXTENSIONS:
				continue
			if referrer == path + ".import" or referrer == path + ".uid":
				continue
			parents.append(referrer)
		if parents.is_empty() or parents.size() > SHARED_PARENT_MAX_OWNERS:
			continue
		var bucket_key := "%s|%s" % [String(parents[0]), path.get_extension().to_lower()]
		if not buckets.has(bucket_key):
			buckets[bucket_key] = []
		buckets[bucket_key].append(path)

	for key2 in buckets.keys():
		var members: Array = buckets[key2]
		if members.size() < SHARED_PARENT_MIN:
			continue
		members.sort()
		# Placed beneath the file that owns the set, not at the members' own
		# average. Gridding them where they already were left a tidy block
		# sitting nowhere near the scene that uses it, which is most of the
		# reason the layout still read as scattered.
		var owner := String(key2).split("|")[0]
		var centre := Vector3.ZERO
		var target_y := 0.0
		if _positions.has(owner) and not _orphan_set.has(owner):
			var owner_position: Vector3 = _positions[owner]
			centre = owner_position
			target_y = owner_position.y - LAYER_HEIGHT
		else:
			for m in members:
				var position: Vector3 = _positions[m]
				centre += position
				target_y += position.y
			centre /= float(members.size())
			# Orphan sets keep their own plane rather than being lifted into
			# the live tree.
			target_y /= float(members.size())
		_square_grid(_order_by_kind(members), centre.x, target_y, centre.z)
		for m2 in members:
			_grid_placed[String(m2)] = true


## Grids each inheritance family in place, base centred beneath it.
##
## Runs in the depth layout too: a family is a family regardless of how the
## graph was walked, and leaving subclasses strewn across the tree was the
## single worst readability problem in that mode.
## Places items in a square grid, never a strip or a scatter. Pitch follows
## the longest label so names cannot collide. Returns the block extent.
## Finds a free spot for a block of the given size, starting from the
## preferred position and spiralling outward until nothing overlaps.
##
## Preference is honoured where possible -- an asset set still lands under its
## owner -- but never at the cost of burying an existing block.
## Claims a small rectangle for every node already positioned, so blocks
## placed later route around the existing layout instead of through it.
func _reserve_existing_nodes() -> void:
	for key in _positions.keys():
		var path: String = key
		if path.begins_with("::"):
			continue
		var position: Vector3 = _positions[path]
		var label_width := float(path.get_file().length()) * LABEL_GLYPH_WIDTH + GROUP_CELL_PADDING
		_reserved.append({
			"centre": Vector2(position.x, position.z),
			"half": Vector2(maxf(label_width, CELL_SIZE) * 0.5, CELL_SIZE * 0.5),
			"y": position.y,
			"owner": path,
		})


## Claims space for one node and moves it there. Every position assigned
## outside _square_grid must go through this, or the node is invisible to the
## reservation system and later blocks are free to land on top of it.
## True when a point is clear of every reserved block on its own layer.
func _is_space_free(point: Vector3, ignore_path: String) -> bool:
	var label_width := float(ignore_path.get_file().length()) * LABEL_GLYPH_WIDTH + GROUP_CELL_PADDING
	var half := Vector2(maxf(label_width, CELL_SIZE) * 0.5, CELL_SIZE * 0.5)
	var current: Vector3 = _positions.get(ignore_path, point)
	for r in _reserved:
		var rect: Dictionary = r
		if absf(float(rect["y"]) - point.y) > LAYER_HEIGHT * 0.5:
			continue
		var centre: Vector2 = rect["centre"]
		# Skip the node's own rectangle.
		if absf(centre.x - current.x) < 0.01 and absf(centre.y - current.z) < 0.01:
			continue
		var other_half: Vector2 = rect["half"]
		if absf(point.x - centre.x) < (half.x + other_half.x) \
				and absf(point.z - centre.y) < (half.y + other_half.y):
			return false
	return true


## Registers a node's current position without moving it. For placements
## whose exact location carries meaning -- a base class under its family --
## where being nudged aside would destroy the very relationship being shown.
func _reserve_at(path: String) -> void:
	if not _positions.has(path):
		return
	var position: Vector3 = _positions[path]
	var label_width := float(path.get_file().length()) * LABEL_GLYPH_WIDTH + GROUP_CELL_PADDING
	_reserved.append({
		"centre": Vector2(position.x, position.z),
		"half": Vector2(maxf(label_width, CELL_SIZE) * 0.5, CELL_SIZE * 0.5),
		"y": position.y,
		"owner": path,
	})


func _place_reserved(path: String, preferred: Vector3) -> void:
	var label_width := float(path.get_file().length()) * LABEL_GLYPH_WIDTH + GROUP_CELL_PADDING
	var size := Vector2(maxf(label_width, CELL_SIZE), CELL_SIZE)
	_release_reservation(path)
	_positions[path] = _reserve_space(preferred, size, path)


## Releases the space a node currently holds, so relocating it does not leave
## a phantom rectangle that its own new position then collides with.
func _release_reservation(path: String) -> void:
	# Matched by owner, not by coordinates: two nodes can share a position,
	# and a coordinate match silently failed whenever a node had already been
	# moved -- leaving a phantom rectangle its own new position collided with.
	for i in range(_reserved.size() - 1, -1, -1):
		if String((_reserved[i] as Dictionary).get("owner", "")) == path:
			_reserved.remove_at(i)
			return


func _reserve_space(preferred: Vector3, size: Vector2, owner: String = "") -> Vector3:
	var half := size * 0.5
	var candidate := preferred

	for attempt in RESERVE_ATTEMPTS:
		var clashes := false
		for r in _reserved:
			var rect: Dictionary = r
			# Only blocks sharing a layer can collide visually.
			if absf(float(rect["y"]) - candidate.y) > LAYER_HEIGHT * 0.5:
				continue
			var other_half: Vector2 = rect["half"]
			var other_centre: Vector2 = rect["centre"]
			if absf(candidate.x - other_centre.x) < (half.x + other_half.x + RESERVE_MARGIN) \
					and absf(candidate.z - other_centre.y) < (half.y + other_half.y + RESERVE_MARGIN):
				clashes = true
				break
		if not clashes:
			break

		# Spiral outward: alternate sides so a block does not drift steadily
		# in one direction away from where it belongs.
		var ring := float(attempt / 4 + 1)
		var step := (size.x + RESERVE_MARGIN) * ring
		match attempt % 4:
			0:
				candidate = preferred + Vector3(step, 0.0, 0.0)
			1:
				candidate = preferred + Vector3(-step, 0.0, 0.0)
			2:
				candidate = preferred + Vector3(0.0, 0.0, (size.y + RESERVE_MARGIN) * ring)
			_:
				candidate = preferred + Vector3(0.0, 0.0, -(size.y + RESERVE_MARGIN) * ring)

	_reserved.append({
		"centre": Vector2(candidate.x, candidate.z),
		"half": half,
		"y": candidate.y,
		"owner": owner,
	})
	return candidate


func _square_grid(items: Array, origin_x: float, origin_y: float, origin_z: float) -> Vector2:
	if items.is_empty():
		return Vector2.ZERO

	var longest := 0
	for item in items:
		longest = maxi(longest, String(item).get_file().length())
	var pitch := maxf(float(longest) * LABEL_GLYPH_WIDTH + GROUP_CELL_PADDING, GROUP_CELL)

	var per_row := maxi(int(ceil(sqrt(float(items.size())))), 1)
	var rows := int(ceil(float(items.size()) / float(per_row)))
	var width := float(per_row - 1) * pitch
	var depth := float(rows - 1) * pitch

	# Claim the space first: every caller gets collision avoidance without
	# having to think about it, and a block can never be buried under one
	# placed earlier.
	var block := Vector2(width + pitch, depth + pitch)
	# Members release any claim they already hold, so a block being regridded
	# does not collide with its own previous footprint.
	for item_any in items:
		_release_reservation(String(item_any))
	var centre := _reserve_space(Vector3(origin_x, origin_y, origin_z), block)

	for i in items.size():
		var path: String = items[i]
		_positions[path] = Vector3(
			centre.x + float(i % per_row) * pitch - width * 0.5,
			centre.y,
			centre.z + float(i / per_row) * pitch - depth * 0.5
		)
	return block


## Orders a set so files of one type sit together inside the grid, biggest
## type first -- forty textures form their own run rather than interleaving
## with the scripts beside them.
func _order_by_kind(items: Array) -> Array:
	var by_extension := {}
	for item in items:
		var path: String = item
		var extension := path.get_extension().to_lower()
		if not by_extension.has(extension):
			by_extension[extension] = []
		by_extension[extension].append(path)

	var extensions: Array = by_extension.keys()
	extensions.sort_custom(func(a, b):
		var ca: int = (by_extension[a] as Array).size()
		var cb: int = (by_extension[b] as Array).size()
		if ca != cb:
			return ca > cb
		return String(a) < String(b)
	)

	var ordered: Array = []
	for e in extensions:
		var bucket: Array = by_extension[e]
		bucket.sort()
		ordered.append_array(bucket)
	return ordered


## Every inheritance family, deepest first -- so a subclass that is itself a
## base has its own children gridded before it takes its place among siblings.
func _family_blocks() -> Array:
	var children_of := {}
	for key in _parent_of.keys():
		var child: String = key
		var parent := String(_parent_of[child])
		if not children_of.has(parent):
			children_of[parent] = []
		children_of[parent].append(child)

	var blocks: Array = []
	for base_any in children_of.keys():
		var base: String = base_any
		var depth := 0
		var current := base
		var guard := 0
		while _parent_of.has(current) and guard < 32:
			current = String(_parent_of[current])
			depth += 1
			guard += 1
		blocks.append({"base": base, "children": children_of[base], "depth": depth})

	blocks.sort_custom(func(a, b):
		return int((a as Dictionary)["depth"]) > int((b as Dictionary)["depth"])
	)
	return blocks


func _centre_hierarchy_bases() -> void:
	if not _group_affinity or _layout_mode != LayoutMode.DEPENDENCY:
		return

	_hierarchy_placed.clear()
	for block_any in _family_blocks():
		var block: Dictionary = block_any
		var base: String = block["base"]
		if _orphan_set.has(base):
			continue

		var children: Array = []
		for c in (block["children"] as Array):
			var child: String = c
			if _positions.has(child) and not _orphan_set.has(child):
				children.append(child)
		if children.size() < 2:
			continue

		# Grid them where they already are, so the family stays near whatever
		# uses it instead of being relocated across the graph.
		var centre := Vector3.ZERO
		for c2 in children:
			centre += Vector3(_positions[String(c2)])
		centre /= float(children.size())

		# Their existing claims are released first: otherwise the family
		# collides with its own stale rectangles and gets pushed aside, which
		# is what separated a base from its children.
		for c_old in children:
			_release_reservation(String(c_old))
		_release_reservation(base)

		_square_grid(_order_by_kind(children), centre.x, centre.y, centre.z)
		for c3 in children:
			_hierarchy_placed[String(c3)] = true

		if not _positions.has(base):
			continue
		var lowest := -INF
		var base_centre := Vector3.ZERO
		for c4 in children:
			var position: Vector3 = _positions[String(c4)]
			base_centre += position
			lowest = maxf(lowest, position.z)
		base_centre /= float(children.size())

		# Placed directly, NOT through the reservation search. A base belongs
		# centred under its own family, and letting the search relocate it to
		# avoid a neighbour is what pushed it off to one side. Its rectangle
		# is registered afterwards so nothing else lands on it.
		_release_reservation(base)
		_positions[base] = Vector3(
			base_centre.x, base_centre.y - LAYER_HEIGHT, lowest + FAMILY_BASE_GAP
		)
		_reserve_at(base)
		_hierarchy_placed[base] = true


## Final sweep: grids anything the earlier passes left scattered.
##
## Every pass above has a qualifying rule, and a file that satisfies none of
## them keeps whatever position the tree walk gave it -- which is how asset
## sets ended up strung diagonally. This catches the remainder by folder and
## file type, which is the weakest grouping signal available but still far
## better than leaving them where they fell.
func _grid_remaining_assets() -> void:
	if _layout_mode != LayoutMode.DEPENDENCY:
		return

	var buckets := {}
	for key_any in _positions.keys():
		var path: String = key_any
		if _grid_placed.has(path) or _dir_nodes.has(path) or path.begins_with("::"):
			continue
		if _hierarchy_placed.has(path) or _roots.has(path):
			continue
		# Keyed by owner where there is one, so a leftover set still lands
		# beside whatever uses it rather than only beside its folder-mates.
		var owner := ""
		for r in _referrers_of(path):
			var referrer: String = r
			if referrer.get_extension().to_lower() in SIDECAR_EXTENSIONS:
				continue
			owner = referrer
			break
		var bucket_key := "%s|%s|%s" % [
			owner, path.get_base_dir(), path.get_extension().to_lower()
		]
		if not buckets.has(bucket_key):
			buckets[bucket_key] = []
		buckets[bucket_key].append(path)

	for key2 in buckets.keys():
		var members: Array = buckets[key2]
		if members.size() < LOOSE_GRID_MIN:
			continue
		members.sort()
		var owner_path := String(key2).split("|")[0]
		var centre := Vector3.ZERO
		var target_y := 0.0
		if owner_path != "" and _positions.has(owner_path) and not _orphan_set.has(owner_path):
			var owner_position: Vector3 = _positions[owner_path]
			centre = owner_position
			target_y = owner_position.y - LAYER_HEIGHT
		else:
			for m in members:
				centre += Vector3(_positions[String(m)])
				target_y += float(Vector3(_positions[String(m)]).y)
			centre /= float(members.size())
			target_y /= float(members.size())
		_square_grid(members, centre.x, target_y, centre.z)
		for m2 in members:
			_grid_placed[String(m2)] = true


## Places highly shared nodes at the median of their real users.
##
## A high-fan-in node can be left beside the first consumer that discovered
## it, which is arbitrary and can be far from every other user. Fan-in is the
## authoritative placement signal here even when the shared node also has its
## own dependencies: where it is used matters more than traversal order.
## The coordinate median is deliberately used instead of the mean: one remote
## consumer cannot drag shared infrastructure away from the main cluster.
func _place_shared_sinks_near_consumers() -> void:
	if _layout_mode != LayoutMode.DEPENDENCY:
		return

	for key_any in _positions.keys():
		var path: String = key_any
		if _orphan_set.has(path) or _roots.has(path) or _dir_nodes.has(path) or path.begins_with("::"):
			continue
		# Inheritance layout owns both subclasses and bases. A base often has
		# no ordinary outgoing edge, but moving it here would break its family.
		if _parent_of.has(path) or path in _parent_of.values():
			continue

		var consumers: Array = []
		for referrer_any in _referrers_of(path):
			var referrer: String = referrer_any
			if referrer.get_extension().to_lower() in SIDECAR_EXTENSIONS:
				continue
			if _positions.has(referrer) and not _orphan_set.has(referrer):
				consumers.append(referrer)
		if consumers.size() < SHARED_SINK_MIN_CONSUMERS:
			continue

		var xs: Array = []
		var ys: Array = []
		var zs: Array = []
		for consumer_any in consumers:
			var consumer_position: Vector3 = _positions[String(consumer_any)]
			xs.append(consumer_position.x)
			ys.append(consumer_position.y)
			zs.append(consumer_position.z)
		var preferred := Vector3(
			_median_coordinate(xs),
			_median_coordinate(ys) - LAYER_HEIGHT,
			_median_coordinate(zs)
		)
		_place_reserved(path, preferred)
		_grid_placed[path] = true


func _median_coordinate(values: Array) -> float:
	values.sort()
	var middle := int(values.size() / 2)
	if values.size() % 2 == 1:
		return float(values[middle])
	return (float(values[middle - 1]) + float(values[middle])) * 0.5


## Final verification pass: checks the result and repairs what is wrong.
##
## Every earlier pass applies a rule and hopes. This one inspects the actual
## outcome, which is the only way to catch a member that slipped through for
## a reason no rule anticipated -- a sub-subclass landing on its own
## hierarchy level, for instance, and being gridded alone.
##
## Two repairs, both driven by measurement rather than by rule:
##   1. a family member sitting far from its siblings is brought back
##   2. a base is re-centred under wherever its family actually ended up
func _verify_and_repair_families() -> void:
	if _layout_mode != LayoutMode.DEPENDENCY:
		return

	var children_of := {}
	for key in _parent_of.keys():
		var child: String = key
		var parent := String(_parent_of[child])
		if not children_of.has(parent):
			children_of[parent] = []
		children_of[parent].append(child)

	# Roots of each inheritance tree: every subclass, however deep, belongs
	# with the family descending from the same root.
	var root_of := {}
	for key2 in _parent_of.keys():
		var node: String = key2
		var current := node
		var guard := 0
		while _parent_of.has(current) and guard < 32:
			current = String(_parent_of[current])
			guard += 1
		root_of[node] = current

	var families := {}
	for key3 in root_of.keys():
		var member: String = key3
		var root := String(root_of[member])
		if not families.has(root):
			families[root] = []
		families[root].append(member)

	for key4 in families.keys():
		var root2: String = key4
		var members: Array = []
		for m in families[root2]:
			var path: String = m
			if _positions.has(path) and not _orphan_set.has(path):
				members.append(path)
		if members.size() < 2:
			continue

		# Measure: is anyone stranded?
		var centre := Vector3.ZERO
		for m2 in members:
			centre += Vector3(_positions[String(m2)])
		centre /= float(members.size())

		var stranded := false
		for m3 in members:
			if Vector3(_positions[String(m3)]).distance_to(centre) > FAMILY_MAX_SPREAD:
				stranded = true
				break
		if not stranded:
			continue

		# Repair: regrid the whole family as one block, deepest members last
		# so subclasses read in inheritance order.
		members.sort_custom(func(a, b):
			var la := _inheritance_depth(String(a))
			var lb := _inheritance_depth(String(b))
			if la != lb:
				return la < lb
			return String(a) < String(b)
		)
		for m4 in members:
			_release_reservation(String(m4))
		_square_grid(members, centre.x, centre.y, centre.z)
		for m5 in members:
			_grid_placed[String(m5)] = true

		# And put the base back under its repaired family.
		if _positions.has(root2) and not _orphan_set.has(root2):
			var base_centre := Vector3.ZERO
			var lowest := -INF
			for m6 in members:
				var position: Vector3 = _positions[String(m6)]
				base_centre += position
				lowest = maxf(lowest, position.z)
			base_centre /= float(members.size())
			_release_reservation(root2)
			_positions[root2] = Vector3(
				base_centre.x, base_centre.y - LAYER_HEIGHT, lowest + FAMILY_BASE_GAP
			)
			_reserve_at(root2)
			_grid_placed[root2] = true

	# Grouping can move subclasses without exceeding FAMILY_MAX_SPREAD.
	# Centring is an invariant, not only a repair for scattered families.
	_recentre_all_hierarchy_bases()


## Enforces the inheritance invariant after every other placement pass:
## each base is centred on its immediate children. Deepest bases are handled
## first, so an intermediate base settles before its own parent uses it.
func _recentre_all_hierarchy_bases() -> void:
	if _layout_mode != LayoutMode.DEPENDENCY:
		return

	for block_any in _family_blocks():
		var block: Dictionary = block_any
		var base: String = block["base"]
		if not _positions.has(base) or _orphan_set.has(base):
			continue

		var children: Array = []
		for child_any in (block["children"] as Array):
			var child: String = child_any
			if _positions.has(child) and not _orphan_set.has(child):
				children.append(child)
		if children.is_empty():
			continue

		var centre := Vector3.ZERO
		var back_edge := -INF
		for child_any2 in children:
			var child_position: Vector3 = _positions[String(child_any2)]
			centre += child_position
			back_edge = maxf(back_edge, child_position.z)
		centre /= float(children.size())

		_release_reservation(base)
		_positions[base] = Vector3(
			centre.x, centre.y - LAYER_HEIGHT, back_edge + FAMILY_BASE_GAP
		)
		_reserve_at(base)
		_hierarchy_placed[base] = true


## How many extends hops separate a file from the top of its hierarchy.
func _inheritance_depth(path: String) -> int:
	var depth := 0
	var current := path
	var guard := 0
	while _parent_of.has(current) and guard < 32:
		current = String(_parent_of[current])
		depth += 1
		guard += 1
	return depth


func _relax_toward_neighbours() -> void:
	if not _relax_layout or _layout_mode != LayoutMode.DEPENDENCY:
		return

	# Nodes a grouping pass positioned deliberately are left alone: relaxation
	# would pull a packed block apart.
	var frozen := {}
	for key in _name_group_of.keys():
		frozen[String(key)] = true
	for r in _roots:
		frozen[String(r)] = true
	# A base class was placed under its family on purpose; relaxation would
	# pull it back toward the wider average and undo that.
	for key_placed in _hierarchy_placed.keys():
		frozen[String(key_placed)] = true
	# Same for any grid: the whole point of packing an asset set is that it
	# stays packed.
	for key_grid in _grid_placed.keys():
		frozen[String(key_grid)] = true

	var neighbours := {}
	for key2 in _graph.keys():
		var source: String = key2
		for t in _graph[source]:
			var target: String = t
			if source == target:
				continue
			if not neighbours.has(source):
				neighbours[source] = []
			if not neighbours.has(target):
				neighbours[target] = []
			neighbours[source].append(target)
			neighbours[target].append(source)

	for _iteration in RELAX_ITERATIONS:
		var updates := {}
		for key3 in neighbours.keys():
			var node: String = key3
			if frozen.has(node) or _orphan_set.has(node) or _dir_nodes.has(node):
				continue
			if not _positions.has(node):
				continue
			var linked: Array = neighbours[node]
			if linked.size() > RELAX_MAX_CONNECTIONS:
				continue
			# The more connections a node has, the less any single pass moves
			# it -- so hubs settle gradually rather than lurching around.
			var damping := RELAX_HUB_DAMPING / (RELAX_HUB_DAMPING + float(linked.size()))

			var centre := Vector3.ZERO
			var counted := 0
			for m in linked:
				var other: String = m
				if _positions.has(other):
					centre += Vector3(_positions[other])
					counted += 1
			if counted == 0:
				continue
			centre /= float(counted)

			var current: Vector3 = _positions[node]
			var separation := current.distance_to(centre)
			if separation <= RELAX_REST_DISTANCE:
				continue
			# Only the excess beyond the rest distance is closed, so nodes
			# settle alongside their neighbours instead of onto them.
			var factor := ((separation - RELAX_REST_DISTANCE) / separation) * RELAX_STRENGTH * damping
			var target := current.lerp(centre, factor)
			# Refuse a move that would land the node inside a reserved block:
			# relaxation exists to tidy stragglers, not to push them into a
			# grid that was deliberately packed.
			if not _is_space_free(target, node):
				continue
			updates[node] = target

		if updates.is_empty():
			return          # settled; further passes would change nothing
		var largest_shift := 0.0
		for key4 in updates.keys():
			var moved: String = key4
			largest_shift = maxf(largest_shift, Vector3(_positions[moved]).distance_to(updates[moved]))
			_positions[moved] = updates[moved]
		if largest_shift < RELAX_SETTLE_EPSILON:
			return          # nothing is meaningfully moving any more


func _place_orphan_grid() -> void:
	var groups := _orphan_groups()
	var plain: Array = groups["plain"]
	var duplicated: Array = groups["duplicated"]
	var proxied: Array = groups["proxied"]
	if plain.is_empty() and duplicated.is_empty() and proxied.is_empty():
		return

	if _layout_mode == LayoutMode.FOLDER:
		return  # already placed inside their folders

	var lowest := 0.0
	for key in _positions.keys():
		lowest = minf(lowest, float(Vector3(_positions[key]).y))
	var anchor := Vector3.ZERO
	if not _roots.is_empty() and _positions.has(_roots[0]):
		anchor = _positions[_roots[0]]
	var base_x := anchor.x

	# Four bands, from the tree downward:
	#   proxied      resources and shaders whose code is embedded -- two layers
	#                clear of the tree, because they are probably still wanted
	#   duplicated   other orphans whose code was found elsewhere
	#   cube         the expand marker
	#   plain        everything else, behind the cube
	var proxied_y := lowest - LAYER_HEIGHT * 2.0
	var duplicated_y := proxied_y - LAYER_HEIGHT * ORPHAN_TIER_DROP
	var cube_y := duplicated_y - LAYER_HEIGHT * ORPHAN_TIER_DROP
	var plain_y := cube_y - LAYER_HEIGHT * ORPHAN_TIER_DROP
	var start_z := anchor.z + ORPHAN_GAP

	var split := _split_lone_and_clustered(plain)
	var clustered: Array = split["clustered"]
	var lone: Array = split["lone"]

	# Each tier is centred on its own footprint, so expanding one never drags
	# the others off-centre.
	if not proxied.is_empty():
		_layout_orphan_forest(proxied, base_x, start_z, proxied_y)
		_centre_orphans_on(proxied, anchor)
	if not duplicated.is_empty():
		_layout_orphan_forest(duplicated, base_x, start_z, duplicated_y)
		_centre_orphans_on(duplicated, anchor)
	# Clusters sit on their own plane above the lone files: a dead subsystem
	# is reviewed as a unit, so keeping it clear of the loose leftovers makes
	# both easier to judge.
	var cluster_y := plain_y
	var lone_y := plain_y - LAYER_HEIGHT * ORPHAN_TIER_DROP
	if _cluster_orphans_expanded and not clustered.is_empty():
		_layout_orphan_forest(clustered, base_x, start_z, cluster_y)
		_centre_orphans_on(clustered, anchor)
	if _lone_orphans_expanded and not lone.is_empty():
		_layout_orphan_forest(lone, base_x, start_z, lone_y)
		_centre_orphans_on(lone, anchor)

	# Side by side, so which marker holds what is obvious before expanding.
	if not clustered.is_empty():
		_positions[CLUSTER_HUB] = Vector3(anchor.x - ORPHAN_HUB_SIZE * 2.0, cube_y, anchor.z)
		_sizes[CLUSTER_HUB] = ORPHAN_HUB_SIZE
	if not lone.is_empty():
		_positions[ORPHAN_HUB] = Vector3(anchor.x + ORPHAN_HUB_SIZE * 2.0, cube_y, anchor.z)
		_sizes[ORPHAN_HUB] = ORPHAN_HUB_SIZE

	_place_proxies(proxied)


## Draws a stand-in for each proxied orphan directly below the file that
## embeds its code, so the relationship is visible where it actually happens
## rather than only down in the orphan world.
func _place_proxies(proxied: Array) -> void:
	for key in _proxy_of.keys():
		_positions.erase(String(key))
		_sizes.erase(String(key))
	_proxy_of.clear()

	# Group by host first: one file may embed several resources.
	var by_host := {}
	for p in proxied:
		var orphan: String = p
		var host := String(_orphan_notes.get(orphan, ""))
		if host == "" or not _positions.has(host):
			continue
		if not by_host.has(host):
			by_host[host] = []
		by_host[host].append(orphan)

	for key in by_host.keys():
		var host2: String = key
		var sources: Array = by_host[host2]
		sources.sort()
		var origin: Vector3 = _positions[host2]
		var spread := float(sources.size() - 1) * CELL_SIZE * 0.5
		for i in sources.size():
			var orphan2 := String(sources[i])
			var proxy := _proxy_path_for(orphan2)
			_proxy_of[proxy] = orphan2
			# Reserved like everything else, so nothing is dropped on top of
			# a proxy and the proxy is not dropped on top of anything.
			_place_reserved(proxy, Vector3(
				origin.x + float(i) * CELL_SIZE - spread,
				origin.y - LAYER_HEIGHT * PROXY_DROP,
				origin.z
			))
			_sizes[proxy] = PROXY_SIZE


## Lays a group of orphans out as a forest of small trees rather than a flat
## grid.
##
## Orphans routinely reference each other -- a dead subsystem is usually
## several files, not one. A flat grid discards that entirely, which is a
## shame given the reachability scan is precisely what finds such clusters.
## Laying each cluster out as its own little tree makes "these five files are
## one dead unit" visible at a glance.
##
## Returns the z it finished at, so the next group can be placed clear of it.
func _layout_orphan_forest(paths: Array, base_x: float, z_start: float, base_y: float) -> float:
	if paths.is_empty():
		return z_start

	var in_group := {}
	for p in paths:
		in_group[String(p)] = true

	# Edges that stay inside this group.
	var out_edges := {}
	var in_degree := {}
	for p in paths:
		var node: String = p
		# Orphan edges live in their own map, since the main graph only holds
		# files the traversal reached.
		for r in _orphan_graph.get(node, _graph.get(node, [])):
			var ref: String = r
			if ref == node or not in_group.has(ref):
				continue
			if not out_edges.has(node):
				out_edges[node] = []
			if not (ref in out_edges[node]):
				out_edges[node].append(ref)
				in_degree[ref] = int(in_degree.get(ref, 0)) + 1

	# Cluster entry points, in preference order:
	#   1. nothing else in the group points at it (a genuine head)
	#   2. scenes before scripts before everything else -- in a dead
	#      subsystem the .tscn is nearly always the natural root, since it is
	#      what pulls in its script and its assets
	#   3. whichever pulls in the most, then name, for determinism
	#
	# Processing this order and BFS-ing from each still-unclaimed node handles
	# pure cycles for free: they simply get reached later in the same pass.
	var ordered_candidates: Array = paths.duplicate()
	ordered_candidates.sort_custom(func(a, b):
		var a_head := 0 if int(in_degree.get(a, 0)) == 0 else 1
		var b_head := 0 if int(in_degree.get(b, 0)) == 0 else 1
		if a_head != b_head:
			return a_head < b_head
		var ra := _kind_rank(String(a))
		var rb := _kind_rank(String(b))
		if ra != rb:
			return ra < rb
		var oa: int = (out_edges.get(a, []) as Array).size()
		var ob: int = (out_edges.get(b, []) as Array).size()
		if oa != ob:
			return oa > ob
		return String(a) < String(b)
	)
	var roots: Array = []

	# Spanning trees by BFS. A node is claimed by whichever root reaches it
	# first, so a file shared by two clusters appears once, not twice.
	var tree_children := {}
	var depth := {}
	var claimed := {}
	for candidate_any in ordered_candidates:
		var candidate: String = candidate_any
		if claimed.has(candidate):
			continue
		roots.append(candidate)
		claimed[candidate] = true
		depth[candidate] = 0
		var queue: Array = [candidate]
		while not queue.is_empty():
			var current: String = queue.pop_front()
			for r2 in out_edges.get(current, []):
				var child: String = r2
				if claimed.has(child):
					continue
				claimed[child] = true
				depth[child] = int(depth.get(current, 0)) + 1
				if not tree_children.has(current):
					tree_children[current] = []
				tree_children[current].append(child)
				queue.append(child)

	# Order and size, bottom-up, reusing the main layout's shelf packing.
	for key in tree_children.keys():
		tree_children[key] = _order_siblings(tree_children[key])

	var nodes: Array = depth.keys()
	var by_depth_desc: Array = nodes.duplicate()
	by_depth_desc.sort_custom(func(a, b): return int(depth.get(a, 0)) > int(depth.get(b, 0)))
	for n in by_depth_desc:
		var node3: String = n
		var kids: Array = tree_children.get(node3, [])
		if kids.is_empty():
			# Sized to its own label, so a long filename does not overlap the
			# node beside it. A fixed CELL_SIZE is what left asset names
			# running diagonally into each other.
			var label_width := float(node3.get_file().length()) * LABEL_GLYPH_WIDTH + GROUP_CELL_PADDING
			_block_size[node3] = Vector2(maxf(label_width, CELL_SIZE), CELL_SIZE)
		else:
			var packed := _pack_shelves(kids)
			_block_size[node3] = Vector2(
				float(packed["width"]) + BLOCK_PADDING,
				float(packed["depth"]) + BLOCK_PADDING
			)

	# Shelf-pack the trees themselves so a group with many clusters wraps
	# instead of stretching off to the right forever.
	var target_width := maxf(sqrt(float(paths.size())) * CELL_SIZE * 3.0, CELL_SIZE * 6.0)
	var cursor_x := base_x
	var cursor_z := z_start
	var row_depth := 0.0
	for r3 in roots:
		var root2: String = r3
		var block: Vector2 = _block_size.get(root2, Vector2(CELL_SIZE, CELL_SIZE))
		if cursor_x > base_x and (cursor_x - base_x) + block.x > target_width:
			cursor_x = base_x
			cursor_z += row_depth + BLOCK_PADDING
			row_depth = 0.0
		_positions[root2] = Vector3(cursor_x + block.x * 0.5, base_y, cursor_z + block.y * 0.5)
		_place_orphan_descendants(tree_children, root2)
		cursor_x += block.x + BLOCK_PADDING
		row_depth = maxf(row_depth, block.y)

	for n2 in nodes:
		var node4: String = n2
		_sizes[node4] = clampf(
			NODE_MIN_SIZE + float(_in_degree.get(node4, 0)) * 0.12, NODE_MIN_SIZE, NODE_MAX_SIZE
		)

	return cursor_z + row_depth


## Places a tree's descendants inside their parents' blocks, same nesting rule
## as the main grid layout.
func _place_orphan_descendants(children: Dictionary, root: String) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var current: String = stack.pop_back()
		var kids: Array = children.get(current, [])
		if kids.is_empty() or not _positions.has(current):
			continue
		var packed := _pack_shelves(kids)
		var origin: Vector3 = _positions[current]
		var start_x := origin.x - float(packed["width"]) * 0.5
		var z := origin.z - float(packed["depth"]) * 0.5
		var y := origin.y - LAYER_HEIGHT
		for r in packed["rows"]:
			var row: Array = r
			var row_depth := 0.0
			for k in row:
				row_depth = maxf(row_depth, Vector2(_block_size.get(k, Vector2(CELL_SIZE, CELL_SIZE))).y)
			var x := start_x
			for k in row:
				var kid: String = k
				var kb: Vector2 = _block_size.get(kid, Vector2(CELL_SIZE, CELL_SIZE))
				_positions[kid] = Vector3(x + kb.x * 0.5, y, z + row_depth * 0.5)
				x += kb.x
				stack.append(kid)
			z += row_depth


# ------------------------------------------------------------------ visuals

## Godot treats visibility_range_end = 0 as "never cull", which is what makes
## the always-visible mode free rather than something we have to police per
## frame.
##
## The selection and everything directly connected to it are exempt from
## culling regardless of the mode: when you are inspecting a node, its
## neighbours are exactly what you need to read, and they are often the
## furthest things from the camera.
func _label_range_for(path: String, related: Dictionary) -> float:
	if not _label_distance_culling:
		return 0.0
	if _selected != "" and related.has(path):
		return 0.0
	return LABEL_VIEW_DISTANCE


func _icon_range_for(path: String, related: Dictionary) -> float:
	if _selected != "" and related.has(path):
		return 0.0   # a label with no icon under it reads as a bug
	return ICON_VIEW_DISTANCE


func _color_for(path: String) -> Color:
	# A proxy is a stand-in, so it takes its whole appearance -- colour, icon
	# and label -- from the file it represents.
	if _proxy_of.has(path):
		return _color_for(String(_proxy_of[path]))
	# The selection is lightened rather than recoloured, so it pops without
	# losing the type colour that says what it is.
	if path == _selected and path != ORPHAN_HUB:
		return _base_color_for(path).lerp(Color.WHITE, SELECTED_LIGHTEN)
	return _base_color_for(path)


func _base_color_for(path: String) -> Color:
	# While a path trace is playing, nodes the pulse has not yet reached stay
	# unlit: the point is to watch the route arrive.
	if _trace_active and _analysis_mode == AnalysisMode.PATHS:
		if _analysis_nodes.has(path):
			return _theme_path if _trace_reached.has(path) else _theme_path.lerp(_theme_background, 0.72)

	# The analysis overlay takes priority: while it is on, it is the question
	# being asked, so it should read before file kind or heat.
	if _analysis_mode != AnalysisMode.NONE and _analysis_nodes.has(path):
		if _analysis_mode == AnalysisMode.PATHS:
			return _theme_path
		# Direct dependents read strongest; each further hop fades, because
		# that is honestly how much the change is likely to matter to them.
		var hop := int(_analysis_depth.get(path, 1))
		var falloff := clampf(float(hop - 1) / float(maxi(MAX_BLAST_HOPS - 1, 1)), 0.0, 1.0)
		return _theme_impact.lerp(_theme_background, falloff * 0.45)
	if path == ORPHAN_HUB or path == CLUSTER_HUB:
		return _theme_orphan
	if _orphan_notes.has(path):
		return _theme_proxied if _has_proxy(path) else _theme_duplicated
	if _heat_mode:
		return _heat_color(path)
	if _roots.has(path):
		return _theme_root
	if _dir_nodes.has(path):
		return TypeIcons.color_of(TypeIcons.Kind.FOLDER)
	if _orphan_set.has(path):
		return _theme_orphan
	return TypeIcons.color_of_path(path)


func _heat_color(path: String) -> Color:
	var info: Dictionary = _metrics.get("per_file", {}).get(path, {})
	if info.is_empty():
		return Color(0.3, 0.32, 0.36)
	if bool(info.get("in_cycle", false)):
		var size := float(info.get("cycle_size", 2))
		return Color(0.75, 0.35, 0.75).lerp(_theme_cycle, clampf((size - 2.0) / 6.0, 0.0, 1.0))
	# Prefer the line-weighted hub score: a file referenced by 3 others but
	# touched on 80 lines is far more entangled than one referenced by 3 and
	# touched once each, and plain reference counts can't see that.
	var hub := float(info.get("hub_score", 0))
	var scale := float(maxi(_max_hub_score, 1))
	if not _link_graph.is_empty():
		hub = float(int(_weighted_in.get(path, 0)) * int(_weighted_out.get(path, 0)))
		scale = float(maxi(_max_weighted_hub, 1))
	var t := clampf(sqrt(hub / scale), 0.0, 1.0)
	if t < 0.5:
		return Color(0.35, 0.85, 0.45).lerp(Color(1.0, 0.9, 0.3), t * 2.0)
	return Color(1.0, 0.9, 0.3).lerp(Color(1.0, 0.25, 0.2), (t - 0.5) * 2.0)


func _icon_for(path: String) -> Texture2D:
	if _proxy_of.has(path):
		return _icon_for(String(_proxy_of[path]))
	if path == ORPHAN_HUB or path == CLUSTER_HUB:
		return null   # drawn as a solid marker instead
	if _orphan_notes.has(path) and _warning_icon != null:
		return _warning_icon
	var kind = TypeIcons.Kind.FOLDER if _dir_nodes.has(path) else TypeIcons.kind_of(path)
	return _icon_textures.get(kind, null)


## reframe=false keeps the camera exactly where it is. Toggles that only
## change what's drawn shouldn't teleport you away from whatever you were
## already looking at.
func _rebuild_all(reframe: bool = true) -> void:
	# Guarded because this is now a coroutine: a second call arriving mid-build
	# would interleave with the first and corrupt the visuals.
	if not _scan_done or _rebuilding:
		return
	_rebuilding = true
	var tree: Dictionary
	if _layout_mode == LayoutMode.FOLDER:
		tree = _build_folder_tree()
	else:
		_dir_nodes.clear()
		tree = _build_dependency_tree()
	_roots = (tree["roots"] as Array).duplicate()

	_layout_grid(tree)
	await _refresh_visuals()
	if reframe:
		_frame_graph()
	# Captured after layout so gathered nodes always have a true home to
	# return to, including after a mode switch or filter change.
	_snapshot_home_positions()
	_gather_stage = GatherStage.IDLE
	_gather_nodes.clear()
	_pending_gather = false

	_set_progress("Building file list…")
	await _breathe()
	_populate_file_tree()
	_set_progress("")
	_update_status()
	_rebuilding = false


func _refresh_visuals() -> void:
	_isolate_set = _related_set()
	_clear_visuals()
	await _build_nodes()
	_rebuild_edges()
	_apply_selection_visuals()
	# Cleared here rather than only in _rebuild_all, because the isolate
	# toggle and the theme picker call this directly -- otherwise the overlay
	# would be left showing a stale percentage forever.
	_set_progress("")


func _clear_visuals() -> void:
	if _mesh_instance != null:
		_mesh_instance.queue_free()
		_mesh_instance = null
	for child in _visuals_root.get_children():
		if child == _sprites_root or child == _labels_root:
			continue
		child.queue_free()
	for child in _sprites_root.get_children():
		child.queue_free()
	for child in _labels_root.get_children():
		child.queue_free()
	_sprites.clear()
	_labels.clear()
	_sphere_paths.clear()


func _update_status() -> void:
	var mode_name := "FOLDER" if _layout_mode == LayoutMode.FOLDER else "DEPENDENCY"
	var icon_note := "" if not _icon_textures.is_empty() else "  |  no icons exported (see panel)"
	var heat_note := ""
	if _heat_mode:
		heat_note = "  |  HEAT: magenta = dependency cycle, red = heavy line-weighted coupling"
	var tangle := ""
	if not _metrics.is_empty():
		tangle = "  |  tangle %.0f (%s), %d cycle(s)" % [
			float(_metrics["tangle_index"]), String(_metrics["tangle_band"]),
			(_metrics["cycles"] as Array).size()
		]
	var visibility_note := ""
	if not _view_hidden_kinds.is_empty() or not _view_hidden_extensions.is_empty():
		visibility_note = "  |  view-hidden %d type(s)" % (_view_hidden_kinds.size() + _view_hidden_extensions.size())
	var reliability := "" if _godot_pass_used else "  |  [EXTERNAL PROJECT — reduced accuracy]"
	if _deletion.is_granted():
		reliability += "  |  DELETION ENABLED (%d moved to trash)" % _deletion.deleted_count()
	_status_label.text = "%s  |  %d reachable, %d orphan(s)  |  sidecars %s%s%s%s%s" % [
		mode_name, _graph.size(), _orphan_set.size(),
		"shown" if _show_sidecars else "hidden", tangle, icon_note, heat_note + visibility_note, reliability
	]


func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.07, 0.08, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.7)
	env.ambient_light_energy = 1.0
	_world_env = WorldEnvironment.new()
	_world_env.environment = env
	add_child(_world_env)

	_visuals_root = Node3D.new()
	add_child(_visuals_root)

	# Sprites and labels get their own parents purely so labels can be hidden
	# with a single property write instead of touching every node.
	_sprites_root = Node3D.new()
	_visuals_root.add_child(_sprites_root)
	_labels_root = Node3D.new()
	_visuals_root.add_child(_labels_root)


func _build_camera() -> void:
	_camera = FlyCamera.new()
	_camera.current = true
	_camera.far = 8000.0
	_camera.speed_changed.connect(func(value: float): _show_toast("Fly speed: %.0f" % value))
	_camera.capture_changed.connect(_on_capture_changed)
	add_child(_camera)


func _build_nodes() -> void:
	var paths: Array = _positions.keys()
	if paths.is_empty():
		return

	var loop := get_tree()
	for node_index in paths.size():
		var path: String = paths[node_index]
		# Creating a sprite and a label per node is the other place the UI
		# used to sit frozen with no explanation.
		if node_index % 40 == 0:
			_set_progress("Building view… %d%%" % int(
				float(node_index) / float(maxi(paths.size(), 1)) * 100.0
			))
			if loop != null:
				await loop.process_frame
		if not _is_displayed(path):
			continue
		var size := float(_sizes.get(path, NODE_MIN_SIZE))
		var color := _color_for(path)
		var texture := _icon_for(path)

		if texture != null:
			var sprite := Sprite3D.new()
			sprite.texture = texture
			sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			sprite.shaded = false
			sprite.transparent = true
			sprite.pixel_size = ICON_PIXEL_SIZE * (0.7 + size)
			sprite.modulate = color
			sprite.position = _positions[path]
			sprite.visibility_range_end = _icon_range_for(path, _isolate_set)
			sprite.visibility_range_end_margin = 20.0
			_sprites_root.add_child(sprite)
			_sprites[path] = sprite
		else:
			_sphere_paths.append(path)

		var label := Label3D.new()
		if path == ORPHAN_HUB or path == CLUSTER_HUB:
			var counts := _orphan_groups()
			var split := _split_lone_and_clustered(counts["plain"])
			var group: Array = split["lone"] if path == ORPHAN_HUB else split["clustered"]
			var expanded := (
				_lone_orphans_expanded if path == ORPHAN_HUB
				else _cluster_orphans_expanded
			)
			label.text = "%s (%d) — click to %s" % [
				"Lone orphans" if path == ORPHAN_HUB else "Orphan clusters",
				group.size(), "hide" if expanded else "show"
			]
		else:
			# Proxies carry the same name as the file they stand for.
			label.text = _resolve_proxy(path).get_file() + ("/" if _dir_nodes.has(path) else "")
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.font_size = LABEL_FONT_SIZE
		label.pixel_size = LABEL_PIXEL_SIZE * (1.6 if _roots.has(path) else 1.0)
		# Brightened toward white and given a heavy opaque outline: the raw
		# type colour alone is hard to read against edges and other nodes.
		label.modulate = _label_color(color)
		label.outline_size = LABEL_OUTLINE_SIZE
		label.outline_modulate = Color.BLACK if _theme_is_dark else Color.WHITE
		# ALPHA_CUT_DISABLED (the default) renders the label as transparent
		# geometry, which blends the outline away and sorts badly against
		# other labels. DISCARD makes it opaque, so the outline actually
		# shows and depth ordering behaves.
		label.alpha_cut = Label3D.ALPHA_CUT_DISCARD
		label.outline_render_priority = -1
		label.render_priority = 0
		label.position = _positions[path] + Vector3(0, size * 1.1 + LABEL_LIFT, 0)
		label.visibility_range_end = _label_range_for(path, _isolate_set)
		label.visibility_range_end_margin = 8.0
		_labels_root.add_child(label)
		_labels[path] = label

	if not _sphere_paths.is_empty():
		_build_sphere_multimesh()
	_build_orphan_hub()
	_build_embed_markers()


## A small purple dot above any live file that embeds a standalone resource's
## code. Always drawn, even with the link lines hidden, so the condition is
## discoverable while navigating normally rather than only when you go looking.
func _build_embed_markers() -> void:
	var hosts: Array = []
	for key in _embed_hosts.keys():
		var host: String = key
		if _positions.has(host) and _is_displayed(host):
			hosts.append(host)
	if hosts.is_empty():
		return

	for h in hosts:
		var host2: String = h
		var marker := Sprite3D.new()
		marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		marker.shaded = false
		marker.transparent = true
		marker.modulate = COLOR_EMBED_MARKER
		# Positioned from the label's own offset so the two stay together as
		# the node size changes.
		var host_size := float(_sizes.get(host2, NODE_MIN_SIZE))
		var label_height := host_size * 1.1 + LABEL_LIFT
		marker.position = Vector3(_positions[host2]) + Vector3(
			0.0, label_height + EMBED_MARKER_LIFT, 0.0
		)
		marker.visibility_range_end = ICON_VIEW_DISTANCE
		marker.visibility_range_end_margin = 20.0
		if _host_badge_icon != null:
			marker.texture = _host_badge_icon
			marker.pixel_size = ICON_PIXEL_SIZE * EMBED_MARKER_SIZE * (0.9 + host_size)
		else:
			# No exported icon: fall back to a text glyph so the marker is
			# still visible rather than silently absent.
			var glyph := Label3D.new()
			glyph.text = "⚠"
			glyph.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			glyph.modulate = COLOR_EMBED_MARKER
			glyph.outline_modulate = Color.BLACK
			glyph.outline_size = LABEL_OUTLINE_SIZE * 2
			glyph.font_size = LABEL_FONT_SIZE
			glyph.pixel_size = LABEL_PIXEL_SIZE * 0.7
			glyph.position = marker.position
			glyph.visibility_range_end = ICON_VIEW_DISTANCE
			_visuals_root.add_child(glyph)
			marker.queue_free()
			continue
		_visuals_root.add_child(marker)



## The collapsed-orphan marker: a plain red cube, deliberately unlike every
## other node so it reads as a control rather than a file.
func _build_orphan_hub() -> void:
	# Cube for lone orphans, sphere for clusters: different shapes because
	# they mean different things, and shape survives dimming and colour
	# themes in a way that a colour difference alone would not.
	_add_hub_marker(ORPHAN_HUB, true)
	_add_hub_marker(CLUSTER_HUB, false)


func _add_hub_marker(hub_path: String, boxy: bool) -> void:
	if not _positions.has(hub_path):
		return
	var size := float(_sizes.get(hub_path, ORPHAN_HUB_SIZE))
	var mesh: Mesh
	if boxy:
		var box := BoxMesh.new()
		box.size = Vector3.ONE * size
		mesh = box
	else:
		var sphere := SphereMesh.new()
		sphere.radius = size * 0.6
		sphere.height = size * 1.2
		sphere.radial_segments = 6
		sphere.rings = 3
		mesh = sphere

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = _theme_orphan
	mesh.surface_set_material(0, mat)

	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.position = _positions[hub_path]
	_visuals_root.add_child(instance)
	if hub_path == ORPHAN_HUB:
		_orphan_hub_mesh = instance


func _build_sphere_multimesh() -> void:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 10
	sphere.rings = 6
	sphere.material = mat

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sphere
	mm.instance_count = _sphere_paths.size()

	for i in _sphere_paths.size():
		var path: String = _sphere_paths[i]
		var size := float(_sizes.get(path, NODE_MIN_SIZE))
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * size), _positions[path]))
		mm.set_instance_color(i, _color_for(path))

	_mesh_instance = MultiMeshInstance3D.new()
	_mesh_instance.multimesh = mm
	add_child(_mesh_instance)


func _rebuild_edges() -> void:
	if _edge_mesh_instance == null:
		_edge_mesh_instance = MeshInstance3D.new()
		var line_mat := StandardMaterial3D.new()
		line_mat.vertex_color_use_as_albedo = true
		line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		line_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_edge_mesh_instance.material_override = line_mat
		add_child(_edge_mesh_instance)

	var related := _related_set()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)

	# Folder block outlines -- these are what make the top-down view read
	# like an explorer, by showing each folder's extent as a rectangle.
	if _layout_mode == LayoutMode.FOLDER:
		for key in _dir_nodes.keys():
			var dir_path: String = key
			if not _positions.has(dir_path) or not _block_size.has(dir_path):
				continue
			_add_block_outline(im, dir_path, related)

	if _layout_mode == LayoutMode.FOLDER:
		for key in _positions.keys():
			var child_path: String = key
			var parent_dir := String(child_path).get_base_dir()
			if parent_dir == child_path or not _positions.has(parent_dir):
				continue
			if not _is_displayed(child_path) or not _is_displayed(parent_dir):
				continue
			_add_edge(im, parent_dir, child_path, _theme_out, related)

	for key in _graph.keys():
		var parent: String = key
		if not _positions.has(parent) or not _is_displayed(parent):
			continue
		for r in _graph[parent]:
			var child: String = r
			if not _positions.has(child) or not _is_displayed(child):
				continue
			_add_edge(im, parent, child, _theme_out, related)

	# Orphan-to-orphan dependencies. Dead code still has real internal
	# structure, and drawing it is what makes a dead cluster legible as a
	# cluster rather than a loose pile.
	#
	# Skipped entirely during a path trace: the chain being traced is the only
	# thing that should be visible then.
	var orphan_sources: Array = []
	if _analysis_mode != AnalysisMode.PATHS:
		orphan_sources = _orphan_graph.keys()
	for key in orphan_sources:
		var orphan_src: String = key
		if not _positions.has(orphan_src) or not _is_displayed(orphan_src):
			continue
		for r in _orphan_graph[orphan_src]:
			var orphan_dst: String = r
			if not _positions.has(orphan_dst) or not _is_displayed(orphan_dst):
				continue
			if _selected == orphan_src or _selected == orphan_dst:
				continue   # drawn weighted by _draw_selection_links instead
			_add_edge(im, orphan_src, orphan_dst, _theme_dangling, related)

	# Folder coupling and inlined-copy links are noise during a trace: only
	# the chain being traced should be visible.
	if _analysis_mode != AnalysisMode.PATHS:
		_draw_folder_links(im)
		_draw_embed_links(im)

	var tubes: Array = []
	_draw_selection_links(im, tubes)
	im.surface_end()

	# Solid tubes need triangles, so they go in their own surface on the same
	# mesh -- still a single draw call per primitive type.
	if not tubes.is_empty():
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for t in tubes:
			var tube: Dictionary = t
			_add_tube_surface(im, tube["a"], tube["b"], float(tube["radius"]), tube["color"])
		im.surface_end()

	_edge_mesh_instance.mesh = im


## Context menu for a node in the 3D view. Reachable by right-click, or by
## press-and-hold -- the latter because on a touch screen there is no second
## mouse button, and holding is the established gesture for it.
## Deletable means: a plain orphan, nothing else. Embedded-code orphans are
## excluded because their code demonstrably still runs somewhere, which makes
## them the likeliest false positives in the whole report.
func _is_deletable(path: String) -> bool:
	if path == "" or path == ORPHAN_HUB or path == CLUSTER_HUB:
		return false
	if path.begins_with(PROXY_PREFIX) or _dir_nodes.has(path):
		return false
	if _orphan_notes.has(path):
		return false
	return _orphan_set.has(path) and not _deletion.was_deleted(path)


func _open_node_menu(screen_point: Vector2) -> void:
	var hit := _resolve_proxy(_pick_node_at(screen_point))
	if hit == "" or hit == ORPHAN_HUB or hit == CLUSTER_HUB:
		# Right-clicking empty space still needs to reach the overlay
		# controls: otherwise clearing an analysis means hunting for a node
		# to click, which is the opposite of what you want when the overlay
		# is in your way.
		_open_general_menu()
		return
	_menu_target = hit
	_release_mouse()
	_node_menu.clear()
	_node_menu.add_item("Fly into " + hit.get_file(), 0)
	_node_menu.add_item("Select", 1)
	_node_menu.add_separator()
	if _orphan_notes.has(hit):
		_node_menu.add_item("Go to the file that embeds this", 11)
		_node_menu.add_separator()
	elif _embed_hosts.has(hit):
		_node_menu.add_item("Go to the embedded source", 12)
		_node_menu.add_separator()
	_node_menu.add_item("Trace paths from entry point", 4)
	_node_menu.add_item("Show change impact", 5)
	if _analysis_mode != AnalysisMode.NONE:
		_node_menu.add_item("Clear analysis overlay", 6)
	_node_menu.add_separator()
	if _is_deletable(hit):
		_node_menu.add_separator()
		if _deletion.is_granted():
			_node_menu.add_item("Move to trash…", 13)
		else:
			_node_menu.add_item("Enable deleting files…", 14)
	_node_menu.add_separator()
	_node_menu.add_item("Move + Refactor…", 15)
	_node_menu.set_item_disabled(
		_node_menu.get_item_index(15),
		_scan_root != "res://" or hit.begins_with(PROXY_PREFIX)
	)
	_node_menu.add_item("Show in project files", 2)
	if not _dir_nodes.has(hit):
		_node_menu.add_item("Reveal in file manager", 3)
	_node_menu.position = Vector2i(get_viewport().get_mouse_position()) + Vector2i(4, 4)
	_node_menu.reset_size()
	_node_menu.popup()


## Menu for right-clicking empty space -- view controls only, no file actions.
func _open_general_menu() -> void:
	_menu_target = ""
	_release_mouse()
	_node_menu.clear()
	if _analysis_mode != AnalysisMode.NONE:
		_node_menu.add_item("Clear %s overlay" % _analysis_label().to_lower(), 6)
	if _isolate_mode:
		_node_menu.add_item("Leave isolate mode", 7)
	if _selected != "":
		_node_menu.add_item("Clear selection", 8)
	_node_menu.add_item(
		"Gather relations on select: %s" % ("ON" if _gather_enabled else "OFF"), 10
	)
	_node_menu.add_item("Reset view", 9)
	_node_menu.position = Vector2i(get_viewport().get_mouse_position()) + Vector2i(4, 4)
	_node_menu.reset_size()
	_node_menu.popup()


func _on_node_menu(id: int) -> void:
	# Ids 6 and above are view controls and work without a target, so they are
	# handled before the target check.
	match id:
		6:
			_set_analysis_mode(AnalysisMode.NONE)
			_show_toast("Analysis overlay cleared")
			return
		7:
			_isolate_mode = false
			await _refresh_visuals()
			_show_toast("Isolate: OFF")
			return
		8:
			_selected = ""
			_update_gather_for_selection()
			_set_analysis_mode(AnalysisMode.NONE)
			_update_info()
			_rebuild_edges()
			_apply_selection_visuals()
			_show_toast("Selection cleared")
			return
		9:
			_go_home()
			return
		10:
			_gather_enabled = not _gather_enabled
			_save_settings()
			if not _gather_enabled and not _gather_nodes.is_empty():
				_start_gather_stage(GatherStage.RETURNING)
			elif _gather_enabled and _selected != "":
				_update_gather_for_selection()
			_show_toast("Gather relations on select: %s" % ("ON" if _gather_enabled else "OFF"))
			return

	if _menu_target == "":
		return
	match id:
		0:
			_highlight_path(_menu_target)
			_fly_to(_menu_target)
		1:
			_highlight_path(_menu_target)
		2:
			_reveal_in_tree(_menu_target)
		3:
			OS.shell_show_in_file_manager(ProjectSettings.globalize_path(_menu_target), false)
		13:
			_confirm_delete(_menu_target)
		14:
			_request_delete_permission()
		15:
			_open_move_refactor(_menu_target)
		4:
			_highlight_path(_menu_target)
			_set_analysis_mode(AnalysisMode.PATHS)
			_show_toast("Traced %d path(s) from an entry point" % _analysis_paths.size())
		11:
			var host_path := String(_orphan_notes.get(_menu_target, ""))
			if host_path != "":
				_highlight_path(host_path)
				_reveal_in_tree(host_path)
				_fly_to(host_path)
		12:
			var sources: Array = _embed_hosts.get(_menu_target, [])
			if not sources.is_empty():
				var first := String(sources[0])
				_highlight_path(first)
				_reveal_in_tree(first)
				_fly_to(first)
		5:
			_highlight_path(_menu_target)
			_set_analysis_mode(AnalysisMode.BLAST)
			_show_toast("%d file(s) use this directly, %d transitively" % [_reverse_graph.get(_menu_target, []).size(), _blast_total_count])


## Press-and-hold detection, shared by mouse and touch. Godot synthesises
## mouse events from touch by default, so tracking the press duration covers
## both without needing separate touch handling.
func _update_long_press(delta: float) -> void:
	if _press_active and not _press_consumed:
		_press_time += delta
		var moved := get_viewport().get_mouse_position().distance_to(_press_position)
		if moved > LONG_PRESS_MOVE_TOLERANCE:
			_press_active = false          # a drag, not a hold
		elif _press_time >= LONG_PRESS_SECONDS:
			_press_consumed = true
			_open_node_menu(_press_position)

	if _tree_press_active and not _tree_press_consumed:
		_tree_press_time += delta
		if _tree_press_time >= LONG_PRESS_SECONDS:
			_tree_press_consumed = true
			if _selected_tree_path() != "":
				_release_mouse()
				_prepare_file_menu()
				_file_menu.position = Vector2i(get_viewport().get_mouse_position()) + Vector2i(4, 4)
				_file_menu.reset_size()
				_file_menu.popup()


func _on_file_tree_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_tree_press_active = event.pressed
		_tree_press_time = 0.0
		if event.pressed:
			_tree_press_consumed = false


## Folders whose contents reference, or are referenced by, anything under the
## given folder. Computed over the whole subtree rather than direct children,
## since folder-level coupling is what matters at this zoom.
func _connected_folders(folder: String) -> Dictionary:
	var connected := {}
	var prefix := folder + "/"
	for key in _positions.keys():
		var file_path: String = key
		if _dir_nodes.has(file_path):
			continue
		var inside := file_path.begins_with(prefix)
		for r in _refs_of(file_path):
			var other: String = r
			var other_inside := other.begins_with(prefix)
			if inside == other_inside:
				continue   # both sides in the same folder, or neither
			var outside_path := other if inside else file_path
			var outside_dir := outside_path.get_base_dir()
			while outside_dir.length() > 6 and not _positions.has(outside_dir):
				outside_dir = outside_dir.get_base_dir()
			if outside_dir != folder and _positions.has(outside_dir):
				connected[outside_dir] = true
	return connected


## Draws folder-to-folder coupling for the selected folder, so cross-folder
## dependencies are visible at the level you're actually looking at.
func _draw_folder_links(im: ImmediateMesh) -> void:
	if _layout_mode != LayoutMode.FOLDER or _selected == "" or not _dir_nodes.has(_selected):
		return
	if not _positions.has(_selected):
		return
	var origin: Vector3 = _positions[_selected]
	for key in _connected_folders(_selected).keys():
		var other: String = key
		if not _is_displayed(other):
			continue
		var colour := _connection_alpha(_theme_out, selected_connection_alpha)
		im.surface_set_color(colour)
		im.surface_add_vertex(origin)
		im.surface_set_color(colour)
		im.surface_add_vertex(_positions[other])


## Draws the two lines that explain a semi-orphan:
##   - a dim tie back to the red cube, grouping it with the orphan area
##   - a purple link to the live file that embeds its code
##
## The purple link is hidden by default (it would clutter normal navigation)
## and appears when the "inlined copies" option is on, or whenever either end
## of it is selected -- because at that point it is the whole story.
func _draw_embed_links(im: ImmediateMesh) -> void:
	for key in _orphan_notes.keys():
		var orphan: String = key
		if not _positions.has(orphan) or not _is_displayed(orphan):
			continue
		var host := String(_orphan_notes[orphan])
		# Also relevant when the selection is the ghost, since that stands in
		# for the orphan.
		var relevant := (
			_show_embed_links
			or _selected == orphan
			or _selected == host
			or _selected == _proxy_path_for(orphan)
		)
		var selected_relation := (
			_selected == orphan
			or _selected == host
			or _selected == _proxy_path_for(orphan)
		)

		var proxy := _proxy_path_for(orphan)
		if _positions.has(proxy):
			# Matches the node colour, so the pair reads as one unit.
			var link_alpha := (
				selected_connection_alpha if selected_relation else idle_connection_alpha
			)
			var link_colour := _connection_alpha(_theme_inline, link_alpha)
			# Dotted from the tree down to the stand-in: this is not a
			# reference the project declares, it is the same code in two
			# places. Solid from the stand-in on to the real file, because
			# they are one and the same thing.
			if _positions.has(host) and _is_displayed(host):
				_add_dashed_line(im, _positions[host], _positions[proxy], link_colour)
			im.surface_set_color(link_colour)
			im.surface_add_vertex(_positions[proxy])
			im.surface_set_color(link_colour)
			im.surface_add_vertex(_positions[orphan])
			continue

		# No proxy: tie it to the cube and link straight to its host.
		if _positions.has(ORPHAN_HUB):
			var anchor_colour := _connection_alpha(_theme_dangling, idle_connection_alpha)
			im.surface_set_color(anchor_colour)
			im.surface_add_vertex(_positions[ORPHAN_HUB])
			im.surface_set_color(anchor_colour)
			im.surface_add_vertex(_positions[orphan])

		if not _positions.has(host) or not _is_displayed(host) or not relevant:
			continue
		var inline_colour := _connection_alpha(_theme_inline, (
			selected_connection_alpha if selected_relation else idle_connection_alpha
		))
		im.surface_set_color(inline_colour)
		im.surface_add_vertex(_positions[orphan])
		im.surface_set_color(inline_colour)
		im.surface_add_vertex(_positions[host])


## Shifts a laid-out orphan tier so its footprint is centred under the entry
## point. Done afterwards because the forest packer works from a corner, and
## its final width is not known until it has finished. Each tier is centred
## on its own footprint, so expanding one never moves the others.
func _centre_orphans_on(paths: Array, anchor: Vector3) -> void:
	if paths.is_empty():
		return
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p in paths:
		var path: String = p
		if not _positions.has(path):
			continue
		var position: Vector3 = _positions[path]
		min_x = minf(min_x, position.x)
		max_x = maxf(max_x, position.x)
		min_z = minf(min_z, position.z)
		max_z = maxf(max_z, position.z)
	if min_x == INF:
		return

	# Only X and Z are shifted; the tier keeps the Y it was laid out at.
	var shift_x := anchor.x - (min_x + max_x) * 0.5
	var shift_z := anchor.z - (min_z + max_z) * 0.5
	for p2 in paths:
		var path2: String = p2
		if _positions.has(path2):
			_positions[path2] = Vector3(_positions[path2]) + Vector3(shift_x, 0.0, shift_z)


## Emits a dashed segment. ImmediateMesh has no line-style support, so the
## gaps come from drawing only the visible portions.
func _add_dashed_line(im: ImmediateMesh, from_point: Vector3, to_point: Vector3, colour: Color) -> void:
	var span := to_point - from_point
	var length := span.length()
	if length < 0.001:
		return
	var direction := span / length
	var stride := DASH_LENGTH + DASH_GAP
	var travelled := 0.0
	while travelled < length:
		var dash_end := minf(travelled + DASH_LENGTH, length)
		im.surface_set_color(colour)
		im.surface_add_vertex(from_point + direction * travelled)
		im.surface_set_color(colour)
		im.surface_add_vertex(from_point + direction * dash_end)
		travelled += stride


func _add_block_outline(im: ImmediateMesh, dir_path: String, related: Dictionary) -> void:
	var centre: Vector3 = _positions[dir_path]
	var b: Vector2 = _block_size[dir_path]
	var y := centre.y - LAYER_HEIGHT * 0.5
	var hw := b.x * 0.5
	var hd := b.y * 0.5
	var col := COLOR_BLOCK
	if _selected != "":
		if dir_path == _selected:
			col = COLOR_HIGHLIGHT
		elif not related.has(dir_path):
			col = Color(col.r, col.g, col.b, col.a * DIM_ALPHA)

	var corners := [
		Vector3(centre.x - hw, y, centre.z - hd),
		Vector3(centre.x + hw, y, centre.z - hd),
		Vector3(centre.x + hw, y, centre.z + hd),
		Vector3(centre.x - hw, y, centre.z + hd),
	]
	for i in 4:
		im.surface_set_color(col)
		im.surface_add_vertex(corners[i])
		im.surface_set_color(col)
		im.surface_add_vertex(corners[(i + 1) % 4])


## Maps every global class_name to the file that declares it, and caches
## script contents for the link-weight pass below.
func _build_class_index() -> void:
	_class_index.clear()
	var to_read := {}
	for key in _graph.keys():
		to_read[String(key)] = true
	# Orphans included: without their content cached, their link weights come
	# out as zero and every dead-code edge draws as a single thin strand.
	for key in _orphan_set.keys():
		to_read[String(key)] = true
	var read_keys: Array = to_read.keys()
	var loop := get_tree()
	for read_index in read_keys.size():
		var path: String = read_keys[read_index]
		if read_index % 25 == 0:
			_set_progress("Reading scripts… %d%%" % int(
				float(read_index) / float(maxi(read_keys.size(), 1)) * 100.0
			))
			if loop != null:
				await loop.process_frame
		if not LanguageAnalyzer.is_source(path):
			continue
		var f := FileAccess.open(OrphanScanner._disk_path(path), FileAccess.READ)
		if f == null:
			continue
		var content := f.get_as_text()
		f.close()
		_content_cache[path] = content
		var idx := content.find("class_name ")
		while idx != -1:
			var at_line_start := idx == 0 or content[idx - 1] == "\n" or content[idx - 1] == "\r"
			if at_line_start:
				var start := idx + 11
				var end := start
				while end < content.length() and content[end] != "\n" and content[end] != "\r" and content[end] != " ":
					end += 1
				var cls := content.substr(start, end - start).strip_edges()
				if cls != "":
					_class_index[cls] = path
				break
			idx = content.find("class_name ", idx + 1)
		for declaration_any in LanguageAnalyzer.declarations(path, content):
			var declaration: Dictionary = declaration_any
			var symbol := String(declaration.get("name", ""))
			if symbol != "" and not _class_index.has(symbol):
				_class_index[symbol] = path


## Builds the project-wide weighted link graph: for every script, how many
## distinct lines of code it devotes to each other file.
##
## Done once up front rather than per selection. It costs one extra pass over
## the scripts (reusing content already cached above), but it makes incoming
## weights, outgoing weights and the weighted heat map all instant lookups
## afterwards -- computing incoming weight on demand would otherwise mean
## re-parsing every file that references the selection, every time.
func _build_link_graph_async() -> void:
	_link_graph.clear()
	_weighted_out.clear()
	_weighted_in.clear()

	var file_set := {}
	for key in _graph.keys():
		file_set[String(key)] = true
		for r in _graph[key]:
			file_set[String(r)] = true

	var scripts: Array = []
	for key in _content_cache.keys():
		scripts.append(String(key))
	scripts.sort()

	var loop := get_tree()
	for i in scripts.size():
		var path: String = scripts[i]
		var link_content := String(_content_cache[path])
		if path.get_extension().to_lower() != "gd":
			link_content = LanguageAnalyzer.strip_comments_and_strings(link_content, true)
		var hits: Dictionary = CodeLinks.analyze(link_content, _class_index, file_set)
		var outgoing := {}
		for key2 in hits.keys():
			var target: String = key2
			if target == path:
				continue
			var arr: PackedInt32Array = hits[target]
			outgoing[target] = arr.size()
			_weighted_out[path] = int(_weighted_out.get(path, 0)) + arr.size()
			_weighted_in[target] = int(_weighted_in.get(target, 0)) + arr.size()
		if not outgoing.is_empty():
			_link_graph[path] = outgoing

		if i % 12 == 0:
			_set_progress("Weighing code links… %d%%" % int(
				float(i) / float(maxi(scripts.size(), 1)) * 100.0
			))
		if loop != null and (i % 12 == 0):
			await loop.process_frame

	for key3 in _weighted_in.keys():
		var p: String = key3
		_max_weighted_hub = maxi(
			_max_weighted_hub, int(_weighted_in.get(p, 0)) * int(_weighted_out.get(p, 0))
		)


## Lines of code in from_path that touch to_path, or 0.
func _link_weight(from_path: String, to_path: String) -> int:
	return int(_link_graph.get(from_path, {}).get(to_path, 0))


## Files referencing the selection, paired with how many lines they spend on
## it -- the incoming half of the picture.
func _incoming_weighted() -> Array:
	var out: Array = []
	if _selected == "":
		return out
	for r in _referrers_of(_selected):
		var parent: String = r
		out.append({"path": parent, "weight": _link_weight(parent, _selected)})
	out.sort_custom(func(a, b): return int(a["weight"]) > int(b["weight"]))
	return out


## Draws every connection touching the selection, grouped per neighbour.
##
## Both directions of a pair are drawn as one group, offset to either side of
## the centre line, so an A->B and B->A relationship reads as a two-lane
## bundle instead of two overlapping bundles fighting for the same pixels.
func _draw_selection_links(im: ImmediateMesh, tubes: Array) -> void:
	if _selected == "" or not _positions.has(_selected):
		return
	# Suppressed while tracing: the question there is "where does execution
	# reach this from", and the selection's own weighted strands radiate in
	# every direction, drowning out the single chain you asked to see.
	if _analysis_mode == AnalysisMode.PATHS:
		return

	# Collect each neighbour once, with the weight in both directions.
	var neighbours := {}
	for r in _refs_of(_selected):
		var target: String = r
		if not _positions.has(target):
			continue
		if not neighbours.has(target):
			neighbours[target] = {"out": 0, "in": 0}
		neighbours[target]["out"] = maxi(1, _link_weight(_selected, target))
	for r in _referrers_of(_selected):
		var source: String = r
		if source == _selected or not _positions.has(source):
			continue
		if not neighbours.has(source):
			neighbours[source] = {"out": 0, "in": 0}
		neighbours[source]["in"] = maxi(1, _link_weight(source, _selected))

	var origin: Vector3 = _positions[_selected]
	for key2 in neighbours.keys():
		var other: String = key2
		var pair: Dictionary = neighbours[other]
		var target_pos: Vector3 = _positions[other]
		var out_weight := int(pair["out"])
		var in_weight := int(pair["in"])
		var both := out_weight > 0 and in_weight > 0

		var axis := (target_pos - origin)
		if axis.length_squared() < 0.0001:
			continue
		var side := _perpendicular(axis.normalized())
		var lane := side * (PAIR_SEPARATION * 0.5)

		if out_weight > 0:
			var a := origin + (lane if both else Vector3.ZERO)
			var b := target_pos + (lane if both else Vector3.ZERO)
			_draw_link(
				im, tubes, a, b,
				_connection_alpha(_theme_out, selected_connection_alpha), out_weight
			)
		if in_weight > 0:
			var a2 := origin - (lane if both else Vector3.ZERO)
			var b2 := target_pos - (lane if both else Vector3.ZERO)
			_draw_link(
				im, tubes, b2, a2,
				_connection_alpha(_theme_in, selected_connection_alpha), in_weight
			)


## Any unit vector perpendicular to `dir`, chosen stably.
func _perpendicular(dir: Vector3) -> Vector3:
	var side := dir.cross(Vector3.UP)
	if side.length_squared() < 0.001:
		side = dir.cross(Vector3.FORWARD)
	return side.normalized()


func _draw_link(im: ImmediateMesh, tubes: Array, a: Vector3, b: Vector3, col: Color, weight: int) -> void:
	match _line_style:
		LineStyle.SOLID_TUBE:
			# One solid tube whose radius carries the weight -- far cheaper
			# and cleaner than many strands when a file is heavily coupled.
			var radius := clampf(
				TUBE_MIN_RADIUS + float(weight) * TUBE_RADIUS_PER_LINK,
				TUBE_MIN_RADIUS, TUBE_MAX_RADIUS
			)
			tubes.append({"a": a, "b": b, "radius": radius, "color": col})
		LineStyle.STRAND_TUBE:
			_add_strands(im, a, b, col, weight, true)
		_:
			_add_strands(im, a, b, col, weight, false)


## One strand per line of code, either fanned flat or wrapped around the edge
## axis so the bundle reads as a cable.
func _add_strands(im: ImmediateMesh, a: Vector3, b: Vector3, col: Color, count: int, circular: bool) -> void:
	var strands := clampi(count, 1, MAX_STRANDS)
	if strands <= 1:
		im.surface_set_color(col)
		im.surface_add_vertex(a)
		im.surface_set_color(col)
		im.surface_add_vertex(b)
		return

	var dir := (b - a).normalized()
	var side := _perpendicular(dir)
	var up := side.cross(dir).normalized()

	for i in strands:
		var offset: Vector3
		if circular:
			var angle := TAU * float(i) / float(strands)
			offset = side * cos(angle) * STRAND_RING_RADIUS + up * sin(angle) * STRAND_RING_RADIUS
		else:
			var t := (float(i) - float(strands - 1) * 0.5) * STRAND_SPACING
			offset = side * t + up * (t * 0.35)
		im.surface_set_color(col)
		im.surface_add_vertex(a + offset)
		im.surface_set_color(col)
		im.surface_add_vertex(b + offset)


## Emits a closed prism between two points. Unshaded vertex-coloured, so no
## normals are needed.
func _add_tube_surface(im: ImmediateMesh, a: Vector3, b: Vector3, radius: float, col: Color) -> void:
	var dir := (b - a)
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	var side := _perpendicular(dir)
	var up := side.cross(dir).normalized()

	for i in TUBE_SIDES:
		var a1 := TAU * float(i) / float(TUBE_SIDES)
		var a2 := TAU * float(i + 1) / float(TUBE_SIDES)
		var o1 := side * cos(a1) * radius + up * sin(a1) * radius
		var o2 := side * cos(a2) * radius + up * sin(a2) * radius
		var p1 := a + o1
		var p2 := a + o2
		var p3 := b + o2
		var p4 := b + o1
		for v in [p1, p2, p3, p1, p3, p4]:
			im.surface_set_color(col)
			im.surface_add_vertex(v)


func _add_edge(im: ImmediateMesh, from_path: String, to_path: String, base: Color, related: Dictionary) -> void:
	if _analysis_mode != AnalysisMode.NONE:
		var analysis_col := _connection_alpha(
			_theme_path if _analysis_mode == AnalysisMode.PATHS else _theme_impact,
			selected_connection_alpha
		)
		var edge_key := "%s|%s" % [from_path, to_path]
		if _trace_active and _analysis_mode == AnalysisMode.PATHS and _analysis_edges.has(edge_key):
			# Not yet travelled: leave it faint so the lit trail stands out.
			if not _trace_edges_done.has(edge_key):
				var pending := _connection_alpha(analysis_col, idle_connection_alpha)
				im.surface_set_color(pending)
				im.surface_add_vertex(_positions[from_path])
				im.surface_set_color(pending)
				im.surface_add_vertex(_positions[to_path])
				return
		if _analysis_edges.has(edge_key):
			im.surface_set_color(analysis_col)
			im.surface_add_vertex(_positions[from_path])
			im.surface_set_color(analysis_col)
			im.surface_add_vertex(_positions[to_path])
			return
		# Everything outside the analysis fades right back, so the chain is
		# legible against the rest of the graph.
		var faded := _connection_alpha(base, idle_connection_alpha * DIM_ALPHA)
		im.surface_set_color(faded)
		im.surface_add_vertex(_positions[from_path])
		im.surface_set_color(faded)
		im.surface_add_vertex(_positions[to_path])
		return

	var col := _connection_alpha(base, idle_connection_alpha)
	if _selected != "":
		# Edges touching the selection are drawn by _draw_selection_links,
		# which groups both directions of a pair together.
		if from_path == _selected or to_path == _selected:
			return
		elif not (related.has(from_path) and related.has(to_path)):
			col = _connection_alpha(base, idle_connection_alpha * DIM_ALPHA)
	im.surface_set_color(col)
	im.surface_add_vertex(_positions[from_path])
	im.surface_set_color(col)
	im.surface_add_vertex(_positions[to_path])


func _connection_alpha(colour: Color, alpha: float) -> Color:
	return Color(colour.r, colour.g, colour.b, clampf(alpha, 0.0, 1.0))


func _related_set() -> Dictionary:
	# While an analysis is running its result IS the relevant set, so the
	# dimming and label minimums follow it rather than the direct neighbours.
	if _analysis_mode != AnalysisMode.NONE and not _analysis_nodes.is_empty():
		return _analysis_nodes.duplicate()

	var related := {}
	if _selected == "":
		return related
	related[_selected] = true
	for r in _refs_of(_selected):
		related[String(r)] = true
	for r in _referrers_of(_selected):
		related[String(r)] = true

	# A proxied file and its stand-in are the same thing, so selecting either
	# lights both. The host is deliberately NOT included: it merely contains a
	# copy of the code, and lighting it made selecting the resource look like
	# it had selected the wrong node.
	var proxy_of_selected := _proxy_path_for(_selected)
	if _positions.has(proxy_of_selected):
		related[proxy_of_selected] = true

	# For embedded orphans WITHOUT a proxy there is no stand-in to point at,
	# so the host is the only way to show where the code ended up.
	if _orphan_notes.has(_selected) and not _has_proxy(_selected):
		related[String(_orphan_notes[_selected])] = true

	# Selecting a file that CONTAINS someone else's code lights the source it
	# came from, and that source's stand-in too -- otherwise the chain from
	# host to ghost to original breaks halfway and the origin of the code is
	# left dimmed.
	for e in _embed_hosts.get(_selected, []):
		var embedded_source: String = e
		related[embedded_source] = true
		var source_proxy := _proxy_path_for(embedded_source)
		if _positions.has(source_proxy):
			related[source_proxy] = true
	if _layout_mode == LayoutMode.FOLDER:
		var parent_dir := _selected.get_base_dir()
		if _positions.has(parent_dir):
			related[parent_dir] = true
		for key in _positions.keys():
			if String(key).get_base_dir() == _selected:
				related[String(key)] = true
		# Selecting a folder also keeps every folder it is coupled to bright,
		# so cross-folder dependencies stand out instead of dimming away.
		if _dir_nodes.has(_selected):
			for key in _connected_folders(_selected).keys():
				related[String(key)] = true
	return related


func _apply_selection_visuals() -> void:
	var related := _related_set()
	# Kept in sync here as well as in _refresh_visuals: selecting a node
	# without isolate mode on never reaches _refresh_visuals, which used to
	# leave this stale and starve the neighbourhood of its minimum size.
	_isolate_set = related
	var dimming := _selected != ""

	for key in _sprites.keys():
		var path: String = key
		var col := _color_for(path)
		# A proxy shares its file's lit/dim state, since they are one node
		# shown twice.
		if dimming and not related.has(path) and not related.has(_resolve_proxy(path)):
			col.a = DIM_ALPHA
		var sprite: Sprite3D = _sprites[path]
		sprite.modulate = col
		sprite.visibility_range_end = _icon_range_for(path, related)

	for key in _labels.keys():
		var path2: String = key
		var col2 := _label_color(_color_for(path2))
		if dimming and not related.has(path2) and not related.has(_resolve_proxy(path2)):
			# Faded toward the background rather than made transparent:
			# with ALPHA_CUT_DISCARD an alpha fade would clip the text away
			# entirely instead of dimming it.
			col2 = col2.lerp(_theme_background, 0.72)
		var label: Label3D = _labels[path2]
		label.modulate = col2
		label.outline_modulate = Color.BLACK if _theme_is_dark else Color.WHITE
		label.visibility_range_end = _label_range_for(path2, related)
		# Reset to base here; _update_label_scaling re-inflates only the ones
		# that should be, so a node dropping out of the selection shrinks back.
		label.pixel_size = _base_pixel_size(path2)
	_label_scale_dirty = true

	if _mesh_instance != null and _mesh_instance.multimesh != null:
		var mm: MultiMesh = _mesh_instance.multimesh
		for i in _sphere_paths.size():
			var path3: String = _sphere_paths[i]
			var col3 := _color_for(path3)
			if dimming and not related.has(path3):
				col3.a = DIM_ALPHA
			mm.set_instance_color(i, col3)


## Spawns at the entry point looking down over the graph, so you always start
## where the project starts rather than at an arbitrary bounding-box centre.
func _frame_graph() -> void:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for key in _positions.keys():
		var p: Vector3 = _positions[key]
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)
	if min_x == INF:
		return

	var span := maxf(maxf(max_x - min_x, max_z - min_z), 20.0)
	var anchor := Vector3((min_x + max_x) * 0.5, 0.0, (min_z + max_z) * 0.5)
	if not _roots.is_empty() and _positions.has(_roots[0]):
		anchor = _positions[_roots[0]]

	var height := clampf(span * 0.45, 14.0, 220.0)
	_home_target = anchor
	_home_standoff = Vector3(0, height, height * 0.55)
	_camera.look_at_from(anchor + _home_standoff, anchor)
	_camera.move_speed = clampf(span * 0.35, 18.0, 400.0)


## Flies back to the spawn view. Removing the automatic reframe on every
## toggle made it easy to get lost, so there has to be a deliberate way home.
func _go_home() -> void:
	if _home_standoff == Vector3.ZERO:
		_frame_graph()
		return
	_camera.focus_on(_home_target, _home_standoff)
	_show_toast("Returning to the starting view")


# ------------------------------------------------------------------ UI + picking

func _load_exported_icon(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		var resource = load(path)
		if resource is Texture2D:
			return resource
	# Exported EditorIcons may be used before the importer has produced a
	# cache entry. Loading the PNG directly makes them available on the first
	# viewer launch and keeps the exporter genuinely one-step.
	var absolute_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute_path):
		return null
	var image := Image.load_from_file(absolute_path)
	if image != null and not image.is_empty():
		return ImageTexture.create_from_image(image)
	return null


func _toolbar_icon(key: String) -> Texture2D:
	return _load_exported_icon(TypeIcons.special_icon_path("toolbar_" + key))


func _apply_toolbar_icons() -> void:
	for id_any in _toolbar_buttons:
		var id := String(id_any)
		var button: Button = _toolbar_buttons[id]
		var texture := _toolbar_icon(id)
		if texture != null:
			button.icon = texture
	if _toolbar_help != null:
		var help_texture := _toolbar_icon("help")
		if help_texture != null:
			_toolbar_help.icon = help_texture


func _add_toolbar_button(row: HBoxContainer, id: String, label: String,
		tooltip: String, action: Callable, toggle := false) -> Button:
	var button := Button.new()
	button.name = "Toolbar_" + id.capitalize()
	button.text = label
	button.tooltip_text = tooltip
	button.toggle_mode = toggle
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 16
	button.pressed.connect(action)
	row.add_child(button)
	_toolbar_buttons[id] = button
	return button


func _add_toolbar_separator(row: HBoxContainer) -> void:
	var separator := VSeparator.new()
	separator.custom_minimum_size.x = 5
	row.add_child(separator)


func _send_toolbar_shortcut(key: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = key
	event.pressed = true
	_unhandled_input(event)
	call_deferred("_sync_toolbar_buttons")


func _set_toolbar_pressed(id: String, pressed: bool) -> void:
	if _toolbar_buttons.has(id):
		(_toolbar_buttons[id] as Button).set_pressed_no_signal(pressed)


func _set_toolbar_state_icon(id: String, state: String) -> void:
	if not _toolbar_buttons.has(id):
		return
	var texture := _toolbar_icon(id + "_" + state)
	if texture != null:
		(_toolbar_buttons[id] as Button).icon = texture


func _sync_toolbar_buttons() -> void:
	var folder_layout := _layout_mode == LayoutMode.FOLDER
	_set_toolbar_pressed("layout", folder_layout)
	_set_toolbar_state_icon("layout", "folder" if folder_layout else "dependency")
	_set_toolbar_pressed("sidecars", _show_sidecars)
	_set_toolbar_state_icon("sidecars", "on" if _show_sidecars else "off")
	_set_toolbar_pressed("heat", _heat_mode)
	_set_toolbar_state_icon("heat", "on" if _heat_mode else "off")
	_set_toolbar_pressed("pair", _pair_scripts)
	_set_toolbar_state_icon("pair", "on" if _pair_scripts else "off")
	_set_toolbar_pressed("isolate", _isolate_mode)
	_set_toolbar_state_icon("isolate", "on" if _isolate_mode else "off")
	_set_toolbar_pressed("inline", _show_embed_links)
	_set_toolbar_state_icon("inline", "on" if _show_embed_links else "off")
	_set_toolbar_pressed("gather", _gather_enabled)
	_set_toolbar_state_icon("gather", "on" if _gather_enabled else "off")
	_set_toolbar_pressed("pull", _relax_layout)
	_set_toolbar_state_icon("pull", "on" if _relax_layout else "off")
	_set_toolbar_pressed("group", _group_affinity)
	_set_toolbar_state_icon("group", "on" if _group_affinity else "off")
	_set_toolbar_pressed("labels", _min_label_global)
	_set_toolbar_state_icon("labels", "on" if _min_label_global else "off")
	_set_toolbar_pressed("label_cull", _label_distance_culling)
	_set_toolbar_state_icon("label_cull", "on" if _label_distance_culling else "off")
	var files_visible := _left_panel != null and _left_panel.visible
	_set_toolbar_pressed("files", files_visible)
	_set_toolbar_state_icon("files", "on" if files_visible else "off")
	var info_visible := _right_panel != null and _right_panel.visible
	_set_toolbar_pressed("info", info_visible)
	_set_toolbar_state_icon("info", "on" if info_visible else "off")
	if _toolbar_buttons.has("connections"):
		var connection_state := "flat"
		if _line_style == LineStyle.STRAND_TUBE:
			connection_state = "cable"
		elif _line_style == LineStyle.SOLID_TUBE:
			connection_state = "tube"
		_set_toolbar_state_icon("connections", connection_state)
		(_toolbar_buttons["connections"] as Button).tooltip_text = "Cycle connection rendering (T). Current: " + _line_style_name()


func _add_toolbar_help_heading(text: String) -> void:
	if not _toolbar_help_list.get_children().is_empty():
		_toolbar_help_list.add_child(HSeparator.new())
	var heading := Label.new()
	heading.text = text
	heading.add_theme_font_size_override("font_size", 18)
	_toolbar_help_list.add_child(heading)


func _add_toolbar_help_entry(id: String, shortcut: String, description: String) -> void:
	var source: Button = _toolbar_buttons[id]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_toolbar_help_list.add_child(row)

	# A duplicate keeps the live icon, pressed state, flat/toggle style,
	# expansion settings and theme. Ignoring mouse input makes it a visual
	# sample without tinting it like a disabled control.
	var sample := source.duplicate() as Button
	sample.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sample.focus_mode = Control.FOCUS_NONE
	sample.set_pressed_no_signal(source.button_pressed)
	sample.custom_minimum_size = Vector2(maxf(source.size.x, 32.0), maxf(source.size.y, 24.0))
	row.add_child(sample)

	var copy := Label.new()
	copy.text = ("%s — " % shortcut if shortcut != "" else "") + description
	copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(copy)


func _equalize_toolbar_help_samples() -> void:
	var samples: Array[Button] = []
	var tallest := 0.0
	for child in _toolbar_help_list.get_children():
		if child is HBoxContainer and child.get_child_count() >= 2 and child.get_child(0) is Button:
			var sample := child.get_child(0) as Button
			samples.append(sample)
			tallest = maxf(tallest, child.size.y)
	for sample in samples:
		sample.custom_minimum_size.y = tallest


func _refresh_toolbar_help() -> void:
	for child in _toolbar_help_list.get_children():
		_toolbar_help_list.remove_child(child)
		child.queue_free()

	_add_toolbar_help_heading("View and layout")
	_add_toolbar_help_entry("layout", "G", "Switch between dependency depth and real folder structure.")
	_add_toolbar_help_entry("sidecars", "I", "Include or hide .import and .uid files.")
	_add_toolbar_help_entry("heat", "H", "Colour nodes by cycles and coupling instead of file type.")
	_add_toolbar_help_entry("pair", "P", "Keep scripts near the scenes that own them.")
	_add_toolbar_help_entry("connections", "T", "Cycle flat strands, cable strands, and weighted tubes.")
	_add_toolbar_help_entry("pull", "Y", "Pull weakly linked files toward the files that reference them.")
	_add_toolbar_help_entry("group", "J", "Group files that share a naming convention.")

	_add_toolbar_help_heading("Focus and readability")
	_add_toolbar_help_entry("isolate", "O", "Show only the selection and its direct neighbours.")
	_add_toolbar_help_entry("inline", "U", "Show links to resources whose code is copied into another file.")
	_add_toolbar_help_entry("gather", "R", "Temporarily gather direct relations around the selection.")
	_add_toolbar_help_entry("labels", "M", "Enforce a minimum screen size for every label.")
	_add_toolbar_help_entry("label_cull", "L", "Hide distant labels except the selected neighbourhood.")
	_add_toolbar_help_entry("clear", "C", "Remove path-trace or change-impact overlays.")

	_add_toolbar_help_heading("Files and panels")
	_add_toolbar_help_entry("filter", "K", "Remove file types from analysis and recompute the layout.")
	_add_toolbar_help_entry("visibility", "", "Hide file types visually while keeping the full computed graph.")
	_add_toolbar_help_entry("files", "F1", "Show or hide the Project Files panel.")
	_add_toolbar_help_entry("info", "F2", "Show or hide the Selection panel.")
	_add_toolbar_help_entry("panels", "F3", "Scan another Godot project.")
	_add_toolbar_help_entry("home", "F / Home", "Return the camera to its starting view.")

	_add_toolbar_help_heading("Mouse and camera")
	var camera_help := Label.new()
	camera_help.text = "Click captures or selects; click again deselects; right-click opens node actions.\nWASD + mouse flies, Q/E moves down/up, Shift boosts, the wheel changes speed, and Escape releases the mouse."
	camera_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toolbar_help_list.add_child(camera_help)


func _open_toolbar_help() -> void:
	_refresh_toolbar_help()
	var viewport_size := get_viewport().get_visible_rect().size
	var popup_size := Vector2(minf(780.0, viewport_size.x * 0.82), minf(720.0, viewport_size.y * 0.82))
	_toolbar_help_popup.popup_centered_clamped(popup_size)
	# Text wrapping is only known after the popup receives its final width.
	# Measure then so every icon sample adopts the tallest description row.
	await get_tree().process_frame
	_equalize_toolbar_help_samples()


func _build_toolbar_help() -> void:
	_toolbar_help_popup = PopupPanel.new()
	add_child(_toolbar_help_popup)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 12)
	_toolbar_help_popup.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)

	_toolbar_help_list = VBoxContainer.new()
	_toolbar_help_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar_help_list.add_theme_constant_override("separation", 8)
	scroll.add_child(_toolbar_help_list)
	_toolbar_help.pressed.connect(_open_toolbar_help)


func _build_toolbar() -> void:
	var row_path := "UI/Layout/MainSplit/ToolbarPanel/ToolbarScroll/ToolbarRow/"
	var bindings := {
		"layout": ["Layout", "Switch dependency/folder layout (G)", _send_toolbar_shortcut.bind(KEY_G)],
		"sidecars": ["Sidecars", "Show .import and .uid sidecars (I)", _send_toolbar_shortcut.bind(KEY_I)],
		"heat": ["Heat", "Entanglement heat colouring (H)", _send_toolbar_shortcut.bind(KEY_H)],
		"pair": ["Pair", "Pair scripts with their owning scenes (P)", _send_toolbar_shortcut.bind(KEY_P)],
		"connections": ["Connections", "Cycle connection rendering (T)", _send_toolbar_shortcut.bind(KEY_T)],
		"isolate": ["Isolate", "Show selection and direct neighbours only (O)", _send_toolbar_shortcut.bind(KEY_O)],
		"inline": ["Inline", "Show inlined-copy links (U)", _send_toolbar_shortcut.bind(KEY_U)],
		"gather": ["Gather", "Gather direct relations around selection (R)", _send_toolbar_shortcut.bind(KEY_R)],
		"pull": ["Pull", "Pull nodes toward their references (Y)", _send_toolbar_shortcut.bind(KEY_Y)],
		"group": ["Group", "Group related naming families (J)", _send_toolbar_shortcut.bind(KEY_J)],
		"labels": ["Labels", "Minimum size for all labels (M)", _send_toolbar_shortcut.bind(KEY_M)],
		"label_cull": ["LabelCull", "Hide distant labels (L)", _send_toolbar_shortcut.bind(KEY_L)],
		"filter": ["Filter", "Remove types from analysis and layout (K)", _open_filter_window],
		"visibility": ["Visibility", "Hide types visually without changing analysis", _open_visibility_window],
		"home": ["Home", "Return camera to its starting view (F / Home)", _go_home],
		"clear": ["Clear", "Clear path/change-impact analysis (C)", _send_toolbar_shortcut.bind(KEY_C)],
		"files": ["Files", "Show or hide Project Files panel (F1)", _send_toolbar_shortcut.bind(KEY_F1)],
		"info": ["Info", "Show or hide Selection panel (F2)", _send_toolbar_shortcut.bind(KEY_F2)],
		"panels": ["Panels", "Scan another Godot project (F3)", _open_project_dialog],
	}
	_toolbar_buttons.clear()
	for id_any in bindings:
		var id := String(id_any)
		var binding: Array = bindings[id]
		var button := get_node(row_path + String(binding[0])) as Button
		button.tooltip_text = String(binding[1])
		button.expand_icon = true
		button.flat = true
		button.custom_minimum_size = Vector2(24, 0)
		if not toolbar_show_labels:
			button.text = ""
		button.pressed.connect(binding[2] as Callable)
		_toolbar_buttons[id] = button

	_toolbar_help = get_node(row_path + "Help") as Button
	_toolbar_help.tooltip_text = "What every toolbar button and shortcut does"
	_toolbar_help.expand_icon = true
	_toolbar_help.flat = true
	_toolbar_help.custom_minimum_size = Vector2(24, 0)
	if not toolbar_show_labels:
		_toolbar_help.text = ""
	_build_toolbar_help()
	_apply_toolbar_icons()
	_sync_toolbar_buttons()


func _build_ui() -> void:
	var main_split := $UI/Layout/MainSplit as VSplitContainer
	var toolbar_panel := $UI/Layout/MainSplit/ToolbarPanel as PanelContainer
	var minimum := maxf(toolbar_min_height, 8.0)
	var maximum := maxf(toolbar_max_height, minimum)
	toolbar_panel.custom_minimum_size.y = minimum
	main_split.split_offset = int(clampf(toolbar_initial_height, minimum, maximum))
	main_split.dragged.connect(_on_toolbar_split_dragged)

	_root_split = $UI/Layout/MainSplit/ContentRoot/RootSplit
	_left_panel = $UI/Layout/MainSplit/ContentRoot/RootSplit/LeftPanel
	_inner_split = $UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit
	_viewport_spacer = $UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/ViewportSpacer
	_crosshair = $UI/Layout/MainSplit/ContentRoot/Crosshair
	_right_panel = $UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel
	_top_bar = $UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/ViewportSpacer/StatusOverlay
	_status_label = $UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/ViewportSpacer/StatusOverlay/Status
	_help_label = $UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/ViewportSpacer/StatusOverlay/CameraHelp
	_file_filter = $UI/Layout/MainSplit/ContentRoot/RootSplit/LeftPanel/LeftBox/FileFilter
	_file_tree = $UI/Layout/MainSplit/ContentRoot/RootSplit/LeftPanel/LeftBox/FileTree
	_info_label = $UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/Scroll/ScrollBox/Info
	_cycles_label = $UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/Scroll/ScrollBox/Cycles
	_left_show_button = $UI/Layout/MainSplit/ContentRoot/LeftShow
	_right_show_button = $UI/Layout/MainSplit/ContentRoot/RightShow
	_progress_overlay = $UI/Layout/MainSplit/ContentRoot/Progress
	_toast_label = $UI/Layout/MainSplit/ContentRoot/Toast

	_left_panel.custom_minimum_size.x = PANEL_MIN_WIDTH
	_right_panel.custom_minimum_size.x = PANEL_MIN_WIDTH
	_file_tree.hide_root = false
	_outline_overlay(_status_label)
	_outline_overlay(_help_label)
	_outline_overlay(_progress_overlay)
	_outline_overlay(_toast_label)
	_outline_overlay(_crosshair)
	_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	_help_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	_progress_overlay.add_theme_font_size_override("font_size", 20)
	_toast_label.add_theme_font_size_override("font_size", 18)
	_crosshair.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))

	$UI/Layout/MainSplit/ContentRoot/RootSplit/LeftPanel/LeftBox/Header/Visibility.pressed.connect(_open_visibility_window)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/LeftPanel/LeftBox/Header/Filters.pressed.connect(_open_filter_window)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/LeftPanel/LeftBox/Header/Open.pressed.connect(_open_project_dialog)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/LeftPanel/LeftBox/Header/Hide.pressed.connect(func(): _set_left_visible(false))
	_file_filter.text_changed.connect(_on_filter_changed)
	_file_tree.item_selected.connect(_on_file_tree_selected)
	_file_tree.item_activated.connect(_on_file_tree_activated)
	_file_tree.item_mouse_selected.connect(_on_file_tree_rmb)
	_file_tree.gui_input.connect(_on_file_tree_gui_input)
	_info_label.meta_clicked.connect(_on_info_link_clicked)
	_cycles_label.meta_clicked.connect(_on_info_link_clicked)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/Header/Hide.pressed.connect(func(): _set_right_visible(false))
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/Scroll/ScrollBox/CyclesToggle.toggled.connect(
		func(on: bool): _cycles_label.visible = on
	)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/Scroll/ScrollBox/Legend.pressed.connect(_open_legend_window)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/Scroll/ScrollBox/NodePalette.pressed.connect(_open_node_palette)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/Scroll/ScrollBox/ConnectionPalette.pressed.connect(_open_connection_palette)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/LogRow/Diagnose.pressed.connect(_open_diagnostics)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/LogRow/Reset.pressed.connect(_go_home)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/LogRow/SaveLog.pressed.connect(_on_save_log)
	$UI/Layout/MainSplit/ContentRoot/RootSplit/InnerSplit/RightPanel/RightBox/LogRow/SaveAs.pressed.connect(_on_save_log_as)
	_left_show_button.pressed.connect(func(): _set_left_visible(true))
	_right_show_button.pressed.connect(func(): _set_right_visible(true))

	_build_toolbar()

	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.filters = PackedStringArray(["*.txt ; Text report"])
	_save_dialog.file_selected.connect(_on_save_log_path_chosen)
	add_child(_save_dialog)

	_file_menu = PopupMenu.new()
	_file_menu.add_item("Highlight in 3D view", 0)
	_file_menu.add_item("Fly to it", 1)
	_file_menu.add_separator()
	_file_menu.add_item("Trace paths from entry point", 3)
	_file_menu.add_item("Show change impact", 4)
	_file_menu.add_item("Clear analysis overlay", 5)
	_file_menu.add_separator()
	_file_menu.add_item("Reveal in file manager", 2)
	_file_menu.add_item("Move + Refactor…", 7)
	_file_menu.add_item("Move to trash…", 6)
	_file_menu.id_pressed.connect(_on_file_menu)
	$UI.add_child(_file_menu)

	_node_menu = PopupMenu.new()
	_node_menu.id_pressed.connect(_on_node_menu)
	$UI.add_child(_node_menu)

	_move_refactor_dialog = MoveRefactorDialog.new()
	_move_refactor_dialog.refactor_requested.connect(_on_graph_refactor_requested)
	add_child(_move_refactor_dialog)

	_filter_window = FilterWindow.new()
	_filter_window.set_presentation("Filters", "Unchecked items are removed from the graph entirely, which also simplifies the layout.")
	_filter_window.filters_changed.connect(_on_filters_changed)
	_filter_window.hide()
	add_child(_filter_window)

	_visibility_window = FilterWindow.new()
	_visibility_window.set_presentation("Visibility", "Unchecked items are hidden from every view only. Analysis, metrics, relationships and layout stay fully computed.")
	_visibility_window.filters_changed.connect(_on_visibility_changed)
	_visibility_window.hide()
	add_child(_visibility_window)

	_legend_window = LegendWindow.new()
	_legend_window.palette_selected.connect(_on_theme_changed)
	_legend_window.hide()
	add_child(_legend_window)

	_node_palette_window = PaletteWindow.new()
	_node_palette_window.hide()
	add_child(_node_palette_window)
	_node_palette_window.configure(
		"nodes", "Node Colours", OFThemes.theme_ids(),
		_theme_labels(OFThemes.theme_ids(), false), _node_colour_entries(), _overrides
	)
	_connect_palette_window(_node_palette_window)

	_connection_palette_window = PaletteWindow.new()
	_connection_palette_window.hide()
	add_child(_connection_palette_window)
	_connection_palette_window.configure(
		"connections", "Connection Colours", OFThemes.connection_theme_ids(),
		_theme_labels(OFThemes.connection_theme_ids(), true), _connection_colour_entries(), _overrides,
		{"idle": idle_connection_alpha, "selected": selected_connection_alpha}
	)
	_connect_palette_window(_connection_palette_window)
	_connection_palette_window.connection_alpha_changed.connect(_on_connection_alpha_changed)

	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.title = "Open a Godot project folder to scan"
	_open_dialog.dir_selected.connect(_on_project_chosen)
	add_child(_open_dialog)

	_root_split.split_offset = int(LEFT_PANEL_WIDTH)
	call_deferred("_apply_initial_split")


func _on_toolbar_split_dragged(offset: int) -> void:
	var minimum := int(maxf(toolbar_min_height, 8.0))
	var maximum := int(maxf(toolbar_max_height, float(minimum)))
	var clamped := clampi(offset, minimum, maximum)
	if clamped != offset:
		($UI/Layout/MainSplit as VSplitContainer).split_offset = clamped


## The inner split's position depends on the viewport width, which isn't known
## until after the first layout pass.
func _apply_initial_split() -> void:
	if _inner_split == null:
		return
	var available := _inner_split.size.x
	_inner_split.split_offset = int(maxf(available - RIGHT_PANEL_WIDTH, PANEL_MIN_WIDTH))








## Overlay text sits directly over the 3D scene, so it needs an outline for
## the same reason the node labels do.
func _outline_overlay(label: Label) -> void:
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("outline_size", 6)


func _set_left_visible(value: bool) -> void:
	_left_panel.visible = value
	_left_show_button.visible = not value


func _set_right_visible(value: bool) -> void:
	_right_panel.visible = value
	_right_show_button.visible = not value


## Rebuilds the left tree, following Godot's own FileSystem dock conventions:
## the res:// root visible at the top, folders before files at every level,
## both alphabetical, 16px icons, and neutral filename text with the TYPE
## carried by the icon's tint rather than by colouring the name.
func _populate_file_tree() -> void:
	if _file_tree == null:
		return
	_file_tree.clear()
	_tree_items.clear()

	# Group everything by its parent directory first, so each level can be
	# ordered folders-then-files rather than in path-sorted order.
	var child_dirs := {}
	var child_files := {}
	var known_dirs := {"res://": true}

	for p in _all_paths():
		var path: String = p
		if path == ORPHAN_HUB or path == CLUSTER_HUB or path.begins_with(PROXY_PREFIX):
			continue
		if _is_view_hidden(path):
			continue
		if _filter_text != "" and not path.get_file().to_lower().contains(_filter_text):
			continue
		var parts := path.trim_prefix("res://").split("/")
		var current := "res://"
		for i in parts.size() - 1:
			var next_dir: String = current.path_join(parts[i])
			if not known_dirs.has(next_dir):
				known_dirs[next_dir] = true
				if not child_dirs.has(current):
					child_dirs[current] = []
				child_dirs[current].append(next_dir)
			current = next_dir
		if not child_files.has(current):
			child_files[current] = []
		child_files[current].append(path)

	var root := _file_tree.create_item()
	root.set_text(0, "res://")
	root.set_metadata(0, "res://")
	root.set_icon_max_width(0, TREE_ICON_SIZE)
	var root_icon := _icon_textures.get(TypeIcons.Kind.FOLDER, null)
	if root_icon != null:
		root.set_icon(0, root_icon)
		root.set_icon_modulate(0, TypeIcons.color_of(TypeIcons.Kind.FOLDER))
	_tree_items["res://"] = root

	var stack: Array = [["res://", root]]
	while not stack.is_empty():
		var frame: Array = stack.pop_back()
		var dir_path: String = frame[0]
		var parent_item: TreeItem = frame[1]

		var subdirs: Array = child_dirs.get(dir_path, [])
		subdirs.sort()
		for d in subdirs:
			var sub: String = d
			stack.append([sub, _create_tree_item(parent_item, sub, true)])

		var files: Array = child_files.get(dir_path, [])
		files.sort()
		for f in files:
			_create_tree_item(parent_item, String(f), false)


func _on_filter_changed(new_text: String) -> void:
	_filter_text = new_text.strip_edges().to_lower()
	_populate_file_tree()


func _create_tree_item(parent: TreeItem, path: String, is_dir: bool) -> TreeItem:
	var item := _file_tree.create_item(parent)
	item.set_text(0, path.get_file())
	item.set_metadata(0, path)
	# Constraining icon width is what keeps rows compact; the exported PNGs
	# are 64px so they stay crisp in 3D, and get downsampled here.
	item.set_icon_max_width(0, TREE_ICON_SIZE)

	var kind = TypeIcons.Kind.FOLDER if is_dir else TypeIcons.kind_of(path)
	var tex = _icon_textures.get(kind, null)
	if tex != null:
		item.set_icon(0, tex)

	if is_dir:
		# Folders open up automatically while filtering, so matches are visible.
		item.set_collapsed(_filter_text == "")
		item.set_icon_modulate(0, TypeIcons.color_of(TypeIcons.Kind.FOLDER))
	elif _orphan_set.has(path):
		# The one place we depart from the editor's styling, because it's the
		# whole point of the tool.
		item.set_icon_modulate(0, COLOR_ORPHAN)
		item.set_custom_color(0, COLOR_ORPHAN)
		item.set_tooltip_text(0, "%s\norphan — never reached from an entry point" % path)
	else:
		item.set_icon_modulate(0, TypeIcons.color_of_path(path))
		item.set_tooltip_text(0, path)

	_tree_items[path] = item
	return item


func _selected_tree_path() -> String:
	if _file_tree == null:
		return ""
	var item := _file_tree.get_selected()
	if item == null:
		return ""
	var meta = item.get_metadata(0)
	return String(meta) if typeof(meta) == TYPE_STRING else ""


func _on_file_tree_selected() -> void:
	if _suppress_tree_signal:
		return
	var path := _selected_tree_path()
	if path == "":
		return
	_highlight_path(path)


func _on_file_tree_activated() -> void:
	var path := _selected_tree_path()
	if path == "":
		return
	_highlight_path(path)
	_fly_to(path)


func _on_file_tree_rmb(_pos: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_RIGHT:
		return
	if _selected_tree_path() == "":
		return
	_release_mouse()
	_prepare_file_menu()
	_file_menu.position = Vector2i(get_viewport().get_mouse_position()) + Vector2i(4, 4)
	_file_menu.reset_size()
	_file_menu.popup()


func _prepare_file_menu() -> void:
	_file_menu.set_item_disabled(
		_file_menu.get_item_index(7), _scan_root != "res://"
	)


func _on_file_menu(id: int) -> void:
	var path := _selected_tree_path()
	if path == "":
		return
	match id:
		0:
			_highlight_path(path)
		1:
			_highlight_path(path)
			_fly_to(path)
		2:
			# The only filesystem interaction in this whole panel, and it is
			# read-only: hand the path to the OS file manager. Nothing here
			# can rename, move or delete anything.
			OS.shell_show_in_file_manager(ProjectSettings.globalize_path(path), false)
		3:
			_highlight_path(path)
			_set_analysis_mode(AnalysisMode.PATHS)
			_show_toast("Traced %d path(s) from an entry point" % _analysis_paths.size())
		4:
			_highlight_path(path)
			_set_analysis_mode(AnalysisMode.BLAST)
			_show_toast("%d file(s) use this directly, %d transitively" % [_reverse_graph.get(_menu_target, []).size(), _blast_total_count])
		5:
			_set_analysis_mode(AnalysisMode.NONE)
			_show_toast("Analysis overlay cleared")
		6:
			if not _is_deletable(path):
				_show_toast("Only orphans can be deleted, and not ones whose code was found elsewhere.")
			elif _deletion.is_granted():
				_confirm_delete(path)
			else:
				_request_delete_permission()
		7:
			_open_move_refactor(path)


func _open_move_refactor(path: String) -> void:
	if _scan_root != "res://":
		_show_toast("Move + Refactor is available only for the running project.")
		return
	if path == "" or path == ORPHAN_HUB or path == CLUSTER_HUB or path.begins_with(PROXY_PREFIX):
		return
	if not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path):
		_show_toast("Cannot refactor a path that no longer exists.")
		return
	_release_mouse()
	_move_refactor_dialog.open_for_paths(PackedStringArray([path]))


func _on_graph_refactor_requested(moves: Array) -> void:
	_set_progress("Move + Refactor… scanning references")
	var summary: Dictionary = await RefactorEngine.perform_moves_async(
		moves,
		func(done: int, total: int):
			var percent := 100.0 if total <= 0 else float(done) / float(total) * 100.0
			_set_progress("Move + Refactor… %d%%" % int(percent))
	)
	_set_progress("")
	var failed: Array = summary.get("failed", [])
	if not failed.is_empty():
		_show_toast("Move + Refactor failed: " + String((failed[0] as Dictionary).get("error", "")))
		return
	var moved: Array = summary.get("moved", [])
	if moved.is_empty():
		return
	if Engine.is_editor_hint():
		EditorInterface.get_resource_filesystem().scan()
	var destination := String((moved[0] as Dictionary).get("to", ""))
	await _run_scan()
	if destination != "" and _positions.has(destination):
		_highlight_path(destination)
	var updated_files: Array = summary.get("updated_files", [])
	_show_toast("Moved and refactored %d referenced occurrence(s)" % updated_files.size())


## Selects a path in the 3D view if it currently has a position; a file can be
## absent because sidecars are hidden, so say so rather than silently doing
## nothing.
func _highlight_path(path: String) -> void:
	if not _positions.has(path):
		_info_label.text = "[color=#e0b050]%s[/color]\n\n[color=#8a8f99]Not shown in the current view. It may be a hidden sidecar (press I) or excluded by the current tree mode.[/color]" % path
		return
	_selected = path
	_update_gather_for_selection()
	_update_info()
	if _isolate_mode:
		await _refresh_visuals()
	else:
		_rebuild_edges()
		_apply_selection_visuals()


func _fly_to(path: String) -> void:
	if not _positions.has(path):
		return
	var target: Vector3 = _positions[path]
	var back := maxf(float(_sizes.get(path, 1.0)) * 8.0, 12.0)
	# Animated rather than warping: turn to face it first, then travel.
	# Timing and easing live on the camera (focus_rotate_seconds,
	# focus_travel_seconds, focus_easing).
	_camera.focus_on(target, Vector3(back * 0.4, back * 0.6, back))


## Clicking a file name anywhere in the right panel navigates to it.
func _on_info_link_clicked(meta) -> void:
	var path := String(meta)
	if path == "":
		return
	_highlight_path(path)
	_reveal_in_tree(path)
	_fly_to(path)


## Any UI that expects clicking needs the mouse back first. Doing this at the
## call site of every popup means you never have to remember Esc yourself.
## Reports are written on request rather than after every scan.
## Asks which file to investigate, then reports every decision the layout made
## about it -- parsed header, resolved parent, which pass claimed it, and where
## it ended up relative to its family.
func _open_diagnostics() -> void:
	_release_mouse()
	if _diagnostics_dialog == null:
		_diagnostics_dialog = AcceptDialog.new()
		_diagnostics_dialog.title = "Diagnose layout"
		_diagnostics_dialog.ok_button_text = "Write report"

		var box := VBoxContainer.new()
		var hint := Label.new()
		hint.text = "Part of a filename to investigate. Its whole inheritance family is included."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD
		hint.custom_minimum_size = Vector2(420, 0)
		box.add_child(hint)

		_diagnostics_input = LineEdit.new()
		_diagnostics_input.placeholder_text = "e.g. RA_SelectVoxelVolume"
		box.add_child(_diagnostics_input)
		_diagnostics_dialog.add_child(box)

		_diagnostics_dialog.confirmed.connect(_write_diagnostics)
		add_child(_diagnostics_dialog)

	if _selected != "":
		_diagnostics_input.text = _selected.get_file()
	_diagnostics_dialog.popup_centered(Vector2i(480, 200))


func _write_diagnostics() -> void:
	var focus := _diagnostics_input.text.strip_edges()
	if focus == "":
		_show_toast("Enter part of a filename first.")
		return

	var report := LayoutDiagnostics.build_report(focus, {
		"positions": _positions,
		"parent_of": _parent_of,
		"name_group_of": _name_group_of,
		"name_groups": _name_groups,
		"grid_placed": _grid_placed,
		"hierarchy_placed": _hierarchy_placed,
		"orphan_set": _orphan_set,
		"contents": _content_cache,
		"graph": _graph,
	})
	var written := LayoutDiagnostics.write_report(_scan_root, report)
	if written == "":
		_show_toast("Could not write the report.")
		return
	_show_toast("Report written to %s" % written)


func _on_save_log() -> void:
	if _last_log_text == "":
		_show_toast("Nothing to save yet.")
		return
	var path := OrphanScanner.default_log_path()
	var problem := OrphanScanner.write_log_to(path, _last_log_text)
	_show_toast(("Could not save: " + problem) if problem != "" else ("Log saved to " + path))


func _on_save_log_as() -> void:
	if _last_log_text == "":
		_show_toast("Nothing to save yet.")
		return
	_release_mouse()
	_save_dialog.current_file = OrphanScanner.default_log_path().get_file()
	_save_dialog.popup_centered_ratio(0.7)


func _on_save_log_path_chosen(path: String) -> void:
	var problem := OrphanScanner.write_log_to(path, _last_log_text)
	_show_toast(("Could not save: " + problem) if problem != "" else ("Log saved to " + path))


## While flying, no UI control may hold keyboard focus. A focused Tree reads
## W/A/S/D as incremental search and jumps its selection to whatever file
## starts with that letter; a focused LineEdit would swallow them outright.
## Focus modes are disabled rather than just released, so a stray click can't
## silently hand focus back mid-flight.
func _on_capture_changed(captured: bool) -> void:
	var controls: Array = [_file_tree, _file_filter, _info_label, _cycles_label]
	for c in controls:
		if c == null:
			continue
		var control: Control = c
		if captured:
			control.release_focus()
			control.focus_mode = Control.FOCUS_NONE
		else:
			control.focus_mode = Control.FOCUS_CLICK


## One-time gate. Granting is deliberately awkward -- a checkbox that must be
## ticked before Accept enables -- so it cannot happen by reflex.
func _request_delete_permission() -> void:
	_release_mouse()
	if _permission_dialog == null:
		_permission_dialog = PermissionDialog.new()
		_permission_dialog.permission_granted.connect(func():
			_deletion.grant()
			_deletion_warning.set_warning_enabled(true)
			_update_status()
			_show_toast("Deletion enabled — files move to the trash, and reset on the next scan")
		)
		add_child(_permission_dialog)
	_permission_dialog.prepare()
	_permission_dialog.popup_centered()


func _confirm_delete(path: String) -> void:
	if not _is_deletable(path):
		return
	_release_mouse()
	_pending_delete = path
	if _confirm_delete_dialog == null:
		_confirm_delete_dialog = ConfirmationDialog.new()
		_confirm_delete_dialog.title = "Move to trash"
		_confirm_delete_dialog.ok_button_text = "Move to trash"
		_confirm_delete_dialog.confirmed.connect(_on_delete_confirmed)
		add_child(_confirm_delete_dialog)
	_confirm_delete_dialog.dialog_text = "%s\n\nThis file is moved to your system trash and recorded in dependency_atlas/deleted.log.\n\nIf it turns out to be loaded at runtime, restore it from the trash." % path
	_confirm_delete_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	if _pending_delete == "":
		return
	var path := _pending_delete
	_pending_delete = ""
	var problem := _deletion.delete_file(path, "orphan")
	if problem != "":
		_show_toast(problem)
		return
	# Dropped from the view immediately: leaving a node for a file that no
	# longer exists invites clicking it again.
	_orphan_set.erase(path)
	_positions.erase(path)
	if _selected == path:
		_selected = ""
		_update_info()
	await _rebuild_all(false)
	_show_toast("Moved to trash: %s  (%d this session)" % [
		path.get_file(), _deletion.deleted_count()
	])


func _release_mouse() -> void:
	if _camera != null and _camera.is_captured():
		_camera.set_captured(false)


func _open_project_dialog() -> void:
	_release_mouse()
	_open_dialog.popup_centered_ratio(0.7)


func _open_filter_window() -> void:
	_release_mouse()
	var extensions: Array = _project_extensions.keys()
	extensions.sort()
	var hidden_kinds: Array = _hidden_kinds.keys()
	var hidden_ext: Array = _hidden_extensions.keys()
	_filter_window.configure(extensions, hidden_kinds, hidden_ext, _custom_extensions)
	_filter_window.popup_centered()


func _open_visibility_window() -> void:
	_release_mouse()
	var extensions: Array = _project_extensions.keys()
	extensions.sort()
	_visibility_window.configure(
		extensions, _view_hidden_kinds.keys(), _view_hidden_extensions.keys(),
		_custom_extensions
	)
	_visibility_window.popup_centered()


## Both palette windows share one implementation and differ only in which
## colours they list, so their signal wiring is shared too.
func _connect_palette_window(window) -> void:
	window.theme_selected.connect(_on_palette_theme_selected)
	window.colour_overridden.connect(_on_colour_overridden)
	window.colour_reset.connect(_on_colour_reset)
	window.theme_reset.connect(_on_palette_theme_reset)
	window.save_as_requested.connect(_on_theme_save_as)
	window.save_requested.connect(_on_theme_save)
	window.rename_requested.connect(_on_theme_rename)
	window.delete_requested.connect(_on_theme_delete)
	window.import_requested.connect(_on_theme_import)
	window.export_requested.connect(_on_theme_export)


func _theme_labels(ids: Array, connections: bool) -> Array:
	var labels: Array = []
	for id_any in ids:
		var theme_id := String(id_any)
		if connections:
			# Make the independent scope explicit: choosing this changes only
			# graph wiring, never file/node colours.
			labels.append(OFThemes.connection_label_of(theme_id) + " — Connections")
		else:
			labels.append(OFThemes.label_of(theme_id))
	return labels


func _node_colour_entries() -> Array:
	var entries: Array = []
	for kind_value in TypeIcons.Kind.values():
		var kind_name: String = TypeIcons.Kind.keys()[int(kind_value)]
		entries.append({
			"key": "kind_" + kind_name,
			"label": TypeIcons.kind_label(kind_value),
			"description": "",
			"default": OFThemes.kind_color(_theme_id, kind_name),
		})
	var roles := [
		["root", "Entry point", "Main scene, autoload or plugin."],
		["orphan", "Orphan", "Never reached from an entry point."],
		["cycle", "In a cycle", "Heat map only."],
		["background", "Background", "The 3D view's clear colour."],
	]
	for r in roles:
		var role: Array = r
		entries.append({
			"key": "role_" + String(role[0]),
			"label": String(role[1]),
			"description": String(role[2]),
			"default": OFThemes.role_color(_theme_id, String(role[0])),
		})
	return entries


func _connection_colour_entries() -> Array:
	var described := {
		"out": ["Line OUT", "References made by the selected file."],
		"in": ["Line IN", "Files that reference the selected file."],
		"dangling": ["Dangling resources", "Connections inside unreachable code."],
		"inline": ["Inlined-copy link", "Joins a file to the copy of its code."],
		"path": ["Reachability path", "A chain from an entry point."],
		"impact": ["Change impact", "Files affected by the selection."],
		"pulse": ["Trace pulse", "The dot that walks each traced chain."],
	}
	var entries: Array = []
	for key_any in OFThemes.CONNECTION_KEYS:
		var key := String(key_any)
		var info: Array = described.get(key, [key, ""])
		entries.append({
			"key": key,
			"label": String(info[0]),
			"description": String(info[1]),
			"default": OFThemes.connection_color(_connection_theme_id, key),
		})
	return entries


func _open_node_palette() -> void:
	_release_mouse()
	_node_palette_window.configure(
		"nodes", "Node Colours", OFThemes.theme_ids(),
		_theme_labels(OFThemes.theme_ids(), false), _node_colour_entries(), _overrides
	)
	_node_palette_window.set_theme_id(_theme_id)
	_node_palette_window.popup_centered()


func _open_connection_palette() -> void:
	_release_mouse()
	_connection_palette_window.configure(
		"connections", "Connection Colours", OFThemes.connection_theme_ids(),
		_theme_labels(OFThemes.connection_theme_ids(), true), _connection_colour_entries(), _overrides,
		{"idle": idle_connection_alpha, "selected": selected_connection_alpha}
	)
	_connection_palette_window.set_theme_id(_connection_theme_id)
	_connection_palette_window.popup_centered()


func _on_connection_alpha_changed(idle_alpha: float, selected_alpha: float) -> void:
	idle_connection_alpha = clampf(idle_alpha, 0.0, 1.0)
	selected_connection_alpha = clampf(selected_alpha, 0.0, 1.0)
	_rebuild_edges()
	_save_settings()


func _resolved_theme_colours(scope: String, theme_id: String) -> Dictionary:
	var colours := {}
	if scope == "connections":
		for key_any in OFThemes.CONNECTION_KEYS:
			var key := String(key_any)
			colours[key] = _overrides.connection_color(theme_id, key)
		return colours
	for kind_value in TypeIcons.Kind.values():
		var kind_name: String = TypeIcons.Kind.keys()[int(kind_value)]
		colours["kind_" + kind_name] = _overrides.node_kind_color(theme_id, kind_name)
	for role in ["root", "orphan", "cycle", "background"]:
		colours["role_" + role] = _overrides.node_role_color(theme_id, role)
	return colours


func _refresh_palette_picker(scope: String, selected_id: String) -> void:
	var window = _connection_palette_window if scope == "connections" else _node_palette_window
	var ids := OFThemes.connection_theme_ids() if scope == "connections" else OFThemes.theme_ids()
	window.configure(
		scope,
		"Connection Colours" if scope == "connections" else "Node Colours",
		ids, _theme_labels(ids, scope == "connections"),
		_connection_colour_entries() if scope == "connections" else _node_colour_entries(),
		_overrides,
		{"idle": idle_connection_alpha, "selected": selected_connection_alpha}
	)
	window.set_theme_id(selected_id)


func _on_theme_save_as(scope: String, source_theme_id: String, name: String) -> void:
	var result := ThemeStore.save_custom(
		_scan_root, scope, name, _resolved_theme_colours(scope, source_theme_id),
		OFThemes.is_dark(source_theme_id)
	)
	var problem := String(result.get("error", ""))
	if problem != "":
		_show_toast("Could not save theme: " + problem)
		return
	var new_id := String(result["id"])
	_overrides.clear_theme(scope, new_id)
	if scope == "connections":
		_connection_theme_id = new_id
		_apply_connection_theme()
	else:
		_theme_id = new_id
		_apply_theme(new_id)
	_refresh_palette_picker(scope, new_id)
	await _refresh_visuals()
	_save_settings()
	_show_toast("Saved custom theme “%s”" % name)


func _on_theme_save(scope: String, theme_id: String) -> void:
	if not OFThemes.is_custom_theme(scope, theme_id):
		_show_toast("Built-in themes cannot be overwritten; save a custom copy first.")
		return
	var problem := ThemeStore.update_custom(
		_scan_root, scope, theme_id, _resolved_theme_colours(scope, theme_id),
		OFThemes.is_dark(theme_id)
	)
	if problem != "":
		_show_toast("Could not save theme: " + problem)
		return
	# The resolved colours are now the theme defaults, so these overrides are
	# redundant and would make later edits harder to reason about.
	_overrides.clear_theme(scope, theme_id)
	_refresh_palette_picker(scope, theme_id)
	await _reapply_palettes()
	_show_toast("Custom theme saved")


func _on_theme_rename(scope: String, theme_id: String, name: String) -> void:
	if not OFThemes.is_custom_theme(scope, theme_id):
		_show_toast("Built-in themes cannot be renamed; save a custom copy first.")
		return
	var problem := ThemeStore.rename_custom(_scan_root, theme_id, name)
	if problem != "":
		_show_toast("Could not rename theme: " + problem)
		return
	_refresh_palette_picker(scope, theme_id)
	_save_settings()
	_show_toast("Theme renamed to “%s”" % name)


func _on_theme_delete(scope: String, theme_id: String) -> void:
	if not OFThemes.is_custom_theme(scope, theme_id):
		_show_toast("Built-in themes cannot be deleted.")
		return
	var problem := ThemeStore.delete_custom(_scan_root, scope, theme_id)
	if problem != "":
		_show_toast("Could not delete theme: " + problem)
		return
	_overrides.clear_theme(scope, theme_id)
	var fallback := (
		OFThemes.DEFAULT_CONNECTION_THEME if scope == "connections"
		else OFThemes.DEFAULT_THEME
	)
	if scope == "connections":
		_connection_theme_id = fallback
		_apply_connection_theme()
	else:
		_theme_id = fallback
		_apply_theme(fallback)
	_refresh_palette_picker(scope, fallback)
	await _refresh_visuals()
	_save_settings()
	_show_toast("Custom theme deleted; restored the default theme")


func _on_theme_import(path: String) -> void:
	var result := ThemeStore.import_theme(_scan_root, path)
	var problem := String(result.get("error", ""))
	if problem != "":
		_show_toast("Could not import theme: " + problem)
		return
	var scope := String(result["scope"])
	var theme_id := String(result["id"])
	if scope == "connections":
		_connection_theme_id = theme_id
		_apply_connection_theme()
	else:
		_theme_id = theme_id
		_apply_theme(theme_id)
	_refresh_palette_picker(scope, theme_id)
	await _refresh_visuals()
	_save_settings()
	_show_toast("Imported theme into custom_themes")


func _on_theme_export(scope: String, theme_id: String, path: String) -> void:
	if not path.to_lower().ends_with(".json"):
		path += ".json"
	var name := (
		OFThemes.connection_label_of(theme_id)
		if scope == "connections" else OFThemes.label_of(theme_id)
	)
	var problem := ThemeStore.export_theme(
		path, scope, theme_id, name, _resolved_theme_colours(scope, theme_id),
		OFThemes.is_dark(theme_id)
	)
	_show_toast("Theme exported" if problem == "" else "Could not export theme: " + problem)


func _on_palette_theme_selected(scope: String, theme_id: String) -> void:
	if scope == "connections":
		_connection_theme_id = theme_id
		_apply_connection_theme()
		_show_toast("Connection theme: %s" % OFThemes.connection_label_of(theme_id))
	else:
		_theme_id = theme_id
		_apply_theme(theme_id)
		_show_toast("Node theme: %s" % OFThemes.label_of(theme_id))
	await _refresh_visuals()
	_populate_file_tree()
	_save_settings()


func _on_colour_overridden(scope: String, theme_id: String, key: String, colour: Color) -> void:
	_overrides.set_override(scope, theme_id, key, colour)
	await _reapply_palettes()


func _on_colour_reset(scope: String, theme_id: String, key: String) -> void:
	_overrides.clear_override(scope, theme_id, key)
	await _reapply_palettes()
	_show_toast("Colour reset to the theme's own")


func _on_palette_theme_reset(scope: String, theme_id: String) -> void:
	_overrides.clear_theme(scope, theme_id)
	await _reapply_palettes()
	_show_toast("All %s colours reset" % ("connection" if scope == "connections" else "node"))


func _reapply_palettes() -> void:
	_apply_theme(_theme_id)
	_apply_connection_theme()
	await _refresh_visuals()
	_populate_file_tree()
	_save_settings()


func _open_legend_window() -> void:
	_release_mouse()
	_legend_window.set_theme_id(_theme_id)
	_legend_window.popup_centered()


func _on_filters_changed(hidden_kinds: Array, hidden_extensions: Array, custom_extensions: Array) -> void:
	_hidden_kinds.clear()
	for k in hidden_kinds:
		_hidden_kinds[int(k)] = true
	_hidden_extensions.clear()
	for e in hidden_extensions:
		_hidden_extensions[String(e)] = true
	_custom_extensions = custom_extensions.duplicate()

	_selected = ""
	_update_info()
	_rebuild_all(false)
	_save_settings()
	_show_toast("Filters updated — %d kind(s), %d extension(s) hidden" % [
		_hidden_kinds.size(), _hidden_extensions.size()
	])


func _on_visibility_changed(hidden_kinds: Array, hidden_extensions: Array, custom_extensions: Array) -> void:
	_view_hidden_kinds.clear()
	for k in hidden_kinds:
		_view_hidden_kinds[int(k)] = true
	_view_hidden_extensions.clear()
	for e in hidden_extensions:
		_view_hidden_extensions[String(e)] = true
	_custom_extensions = custom_extensions.duplicate()
	if _selected != "" and _is_view_hidden(_selected):
		_selected = ""
		_update_info()
	await _refresh_visuals()
	_populate_file_tree()
	_save_settings()
	_show_toast("Visibility updated — %d kind(s), %d extension(s) hidden; layout unchanged" % [
		_view_hidden_kinds.size(), _view_hidden_extensions.size()
	])


func _on_theme_changed(theme_id: String) -> void:
	_apply_theme(theme_id)
	await _refresh_visuals()
	_populate_file_tree()
	_save_settings()
	_show_toast("Theme: %s" % OFThemes.label_of(theme_id))


func _save_settings() -> void:
	var problem := OFConfig.save_settings(_scan_root, {
		"hidden_kinds": _hidden_kinds.keys(),
		"hidden_extensions": _hidden_extensions.keys(),
		"custom_extensions": _custom_extensions,
		"view_hidden_kinds": _view_hidden_kinds.keys(),
		"view_hidden_extensions": _view_hidden_extensions.keys(),
		"theme": _theme_id,
		"connection_theme": _connection_theme_id,
		"idle_connection_alpha": idle_connection_alpha,
		"selected_connection_alpha": selected_connection_alpha,
		"colour_overrides": _overrides.to_flat(),
		"gather_relations": _gather_enabled,
		"show_embed_links": _show_embed_links,
	})
	if problem != "":
		push_warning("Dependency Atlas: " + problem)
	var theme_problem := ThemeStore.save_overrides(_scan_root, _overrides.to_flat())
	if theme_problem != "":
		push_warning("Dependency Atlas: " + theme_problem)


func _load_settings() -> void:
	for problem in ThemeStore.load_custom_themes(_scan_root):
		push_warning("Dependency Atlas: " + String(problem))
	var settings := OFConfig.load_settings(_scan_root)
	_hidden_kinds.clear()
	for k in settings["hidden_kinds"]:
		_hidden_kinds[int(k)] = true
	_hidden_extensions.clear()
	for e in settings["hidden_extensions"]:
		_hidden_extensions[String(e)] = true
	_custom_extensions = Array(settings["custom_extensions"])
	_view_hidden_kinds.clear()
	for k in settings.get("view_hidden_kinds", []):
		_view_hidden_kinds[int(k)] = true
	_view_hidden_extensions.clear()
	for e in settings.get("view_hidden_extensions", []):
		_view_hidden_extensions[String(e)] = true
	_gather_enabled = bool(settings.get("gather_relations", false))
	_show_embed_links = bool(settings.get("show_embed_links", true))
	_connection_theme_id = String(settings.get("connection_theme", OFThemes.DEFAULT_CONNECTION_THEME))
	idle_connection_alpha = clampf(float(settings.get(
		"idle_connection_alpha", OFConfig.DEFAULT_IDLE_CONNECTION_ALPHA
	)), 0.0, 1.0)
	selected_connection_alpha = clampf(float(settings.get(
		"selected_connection_alpha", OFConfig.DEFAULT_SELECTED_CONNECTION_ALPHA
	)), 0.0, 1.0)
	var json_overrides := ThemeStore.load_overrides(_scan_root)
	_overrides.from_flat(
		json_overrides if not json_overrides.is_empty()
		else Dictionary(settings.get("colour_overrides", {}))
	)
	_apply_theme(String(settings["theme"]))


## Scans a different Godot project. Paths inside the graph stay in logical
## res:// form, so nothing downstream needs to know the difference; only disk
## reads are redirected.
func _on_project_chosen(dir_path: String) -> void:
	if not FileAccess.file_exists(dir_path.trim_suffix("/") + "/project.godot"):
		_show_toast("No project.godot found in that folder.")
		return
	_scan_root = dir_path
	# Warned up front, not after the fact: the results are genuinely weaker
	# for an external project and it is better to know that before reading
	# them than to discover it in a footnote afterwards.
	_show_external_project_warning(dir_path)
	await _run_scan()


## Explains what degrades when scanning a project other than this one.
func _show_external_project_warning(dir_path: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Scanning an external project"
	dialog.dialog_text = """Opening: %s

This project is not the one the addon is running inside, so results will be
less reliable than for your own project.

What is unavailable:

  - Godot's own dependency data. ResourceLoader only knows the running
    project, so binary .scn and .res files fall back to byte-scanning,
    which cannot see references stored as object pointers -- a GridMap's
    mesh library, for example.

  - Full UID resolution. uid:// references resolve only where a path
    appears alongside them somewhere in the project.

Files may therefore be reported as orphans when they are actually in use.
Treat this as a rough overview, and scan from inside that project itself
before deleting anything.""" % dir_path
	dialog.ok_button_text = "Scan anyway"
	dialog.confirmed.connect(func(): dialog.queue_free())
	dialog.canceled.connect(func(): dialog.queue_free())
	add_child(dialog)
	_release_mouse()
	dialog.popup_centered(Vector2i(560, 340))


## Lists every dependency cycle, each member a clickable link. The metrics
## already find these; this just makes them reachable without hunting.
func _populate_cycles_panel() -> void:
	if _cycles_label == null:
		return
	var cycles: Array = _metrics.get("cycles", [])
	if cycles.is_empty():
		_cycles_label.text = "[color=#6fbf73]No dependency cycles found.[/color]"
		return

	var out: Array = []
	out.append("[color=#8a8f99]%d cycle(s). Files in a cycle can't be understood or reused independently.[/color]" % cycles.size())
	for i in cycles.size():
		var cycle: Array = cycles[i]
		out.append("")
		out.append("[color=#ff40f0][b]Cycle %d — %d file(s)[/b][/color]" % [i + 1, cycle.size()])
		for member in cycle:
			var path := String(member)
			out.append("    [url=%s]%s[/url]  [color=#7a808c]%s[/color]" % [
				path, path.get_file(), path.get_base_dir()
			])
	_cycles_label.text = "\n".join(out)


## Briefly reports the new state after a toggle, so a keypress always has
## visible feedback rather than leaving you to infer what changed.
## Prominent centred progress text for the phases that used to just freeze.
## Passing "" hides it.
func _set_progress(text: String) -> void:
	if _progress_overlay == null:
		return
	_progress_overlay.text = text
	_progress_overlay.visible = text != ""


## Yields a frame so whatever was just written to the overlay actually paints
## before the next blocking stretch of work begins.
func _breathe() -> void:
	var loop := get_tree()
	if loop != null:
		await loop.process_frame


## The pixel_size a label needs so that it renders at least `min_pixels` tall
## on screen from its current distance.
##
## A Label3D's world height is roughly pixel_size * font_size, and a world
## height projects to (height / distance) * (viewport_height / 2tan(fov/2))
## pixels. Rearranging gives the pixel_size required to hit a target on-screen
## height, which is what makes "never smaller than N pixels" possible without
## resorting to fixed_size (which would stop labels growing when you fly up
## close, and read as broken).
func _pixel_size_for(world_position: Vector3, min_pixels: float, base: float) -> float:
	if _camera == null or min_pixels <= 0.0:
		return base
	var distance := maxf(_camera.global_position.distance_to(world_position), 0.001)
	var viewport_height := float(get_viewport().get_visible_rect().size.y)
	if viewport_height <= 0.0:
		return base
	var world_per_pixel := (2.0 * distance * tan(deg_to_rad(_camera.fov) * 0.5)) / viewport_height
	var needed := (min_pixels * world_per_pixel) / float(LABEL_FONT_SIZE)
	return maxf(base, needed)


func _base_pixel_size(path: String) -> float:
	var base := LABEL_PIXEL_SIZE * (1.6 if _roots.has(path) else 1.0)
	if path == _selected:
		base *= SELECTED_LABEL_SCALE
	return base


## Keeps distance-compensated labels at their minimum size as the camera moves.
##
## Deliberately does nothing at all when there is no selection and the global
## minimum is off -- which is the common case -- so flying around costs
## nothing. With a selection it touches only that node's neighbourhood, and
## only the global toggle makes it iterate everything.
func _update_label_scaling() -> void:
	if _labels_root == null or _camera == null:
		return
	var needs_work := _selected != "" or _min_label_global
	if not needs_work:
		return

	var current := _camera.global_transform
	if not _label_scale_dirty and current.is_equal_approx(_last_label_camera):
		return
	_last_label_camera = current
	_label_scale_dirty = false

	if _min_label_global:
		for key in _labels.keys():
			var path: String = key
			_scale_one_label(path, MIN_LABEL_PIXELS_GLOBAL)
		return

	# Selection only: the node itself plus whatever it is directly wired to.
	_scale_one_label(_selected, MIN_LABEL_PIXELS_SELECTED)
	for key in _isolate_set.keys():
		var neighbour: String = key
		if neighbour != _selected:
			_scale_one_label(neighbour, MIN_LABEL_PIXELS_SELECTED)


func _scale_one_label(path: String, min_pixels: float) -> void:
	if not _labels.has(path):
		return
	var label: Label3D = _labels[path]
	var floor_pixels := min_pixels
	if path == _selected:
		floor_pixels *= SELECTED_LABEL_SCALE
	elif _min_label_global and _selected != "" and _isolate_set.has(path):
		floor_pixels = MIN_LABEL_PIXELS_SELECTED
	label.pixel_size = _pixel_size_for(label.global_position, floor_pixels, _base_pixel_size(path))


## Reverse index: target -> everything that references it. Built once, because
## blast radius walks referrers repeatedly and scanning the whole graph for
## each step would be quadratic.
func _build_reverse_graph() -> void:
	_reverse_graph.clear()
	for key in _graph.keys():
		var source: String = key
		for r in _graph[source]:
			var target: String = r
			if not _reverse_graph.has(target):
				_reverse_graph[target] = []
			if not (source in _reverse_graph[target]):
				_reverse_graph[target].append(source)
	for key in _orphan_graph.keys():
		var osource: String = key
		for r in _orphan_graph[osource]:
			var otarget: String = r
			if not _reverse_graph.has(otarget):
				_reverse_graph[otarget] = []
			if not (osource in _reverse_graph[otarget]):
				_reverse_graph[otarget].append(osource)


## Every chain from an entry point to `target`, up to a cap.
##
## Answers "why is this in my build?" -- and when you want something gone, each
## path is a chain of which exactly one link has to be cut. Bounded on both
## path count and expansion steps, because enumerating all paths through a
## dense graph is exponential in the worst case.
func _find_paths_to(target: String) -> Array:
	var results: Array = []
	var budget := PATH_SEARCH_BUDGET
	for r in _roots:
		var root: String = r
		if results.size() >= MAX_TRACED_PATHS:
			break
		var stack: Array = [[root, [root] as Array, {root: true}]]
		while not stack.is_empty() and results.size() < MAX_TRACED_PATHS and budget > 0:
			budget -= 1
			var frame: Array = stack.pop_back()
			var node: String = frame[0]
			var path: Array = frame[1]
			var on_path: Dictionary = frame[2]
			if node == target:
				results.append(path)
				continue
			if path.size() >= MAX_PATH_DEPTH:
				continue
			for c in _refs_of(node):
				var child: String = c
				if on_path.has(child):
					continue   # would revisit, i.e. a cycle
				var next_on_path: Dictionary = on_path.duplicate()
				next_on_path[child] = true
				var next_path: Array = path.duplicate()
				next_path.append(child)
				stack.append([child, next_path, next_on_path])
	results.sort_custom(func(a, b): return (a as Array).size() < (b as Array).size())
	return results


## Files affected by changing `path`, keyed by how many hops away they are.
## Bounded at MAX_BLAST_HOPS: the near tiers are the actionable ones.
func _blast_radius(path: String) -> Dictionary:
	var affected := {}
	var frontier: Array = [path]
	var hop := 0
	while not frontier.is_empty() and hop < MAX_BLAST_HOPS:
		hop += 1
		var next_frontier: Array = []
		for f in frontier:
			var current: String = f
			for r in _reverse_graph.get(current, []):
				var referrer: String = r
				if referrer == path or affected.has(referrer):
					continue
				affected[referrer] = hop
				next_frontier.append(referrer)
		frontier = next_frontier
	return affected


## Size of the unbounded closure, purely so the panel can say how much lies
## beyond the highlighted tiers.
func _blast_total(path: String) -> int:
	var seen_files := {}
	var queue: Array = [path]
	while not queue.is_empty():
		var current: String = queue.pop_front()
		for r in _reverse_graph.get(current, []):
			var referrer: String = r
			if referrer == path or seen_files.has(referrer):
				continue
			seen_files[referrer] = true
			queue.append(referrer)
	return seen_files.size()


## Switches the analysis overlay. Neither runs by default -- they answer
## specific questions, and leaving them on would just add noise.
func _set_analysis_mode(mode: AnalysisMode) -> void:
	_analysis_mode = mode
	_analysis_nodes.clear()
	_analysis_edges.clear()
	_analysis_paths.clear()
	_analysis_depth.clear()
	_blast_total_count = 0

	if mode == AnalysisMode.NONE or _selected == "":
		_analysis_mode = AnalysisMode.NONE
		_update_info()
		_rebuild_edges()
		_apply_selection_visuals()
		return

	_stop_path_trace()

	if mode == AnalysisMode.PATHS:
		_analysis_paths = _find_paths_to(_selected)
		for p in _analysis_paths:
			var chain: Array = p
			for i in chain.size():
				_analysis_nodes[String(chain[i])] = true
				if i > 0:
					_analysis_edges["%s|%s" % [String(chain[i - 1]), String(chain[i])]] = true
	else:
		_analysis_depth = _blast_radius(_selected)
		_blast_total_count = _blast_total(_selected)
		_analysis_nodes.clear()
		for key in _analysis_depth.keys():
			_analysis_nodes[String(key)] = true
		_analysis_nodes[_selected] = true
		# Mark the edges between affected files so the propagation is visible,
		# not just the endpoints.
		for key in _analysis_nodes.keys():
			var node: String = key
			for r in _refs_of(node):
				var child: String = r
				if _analysis_nodes.has(child):
					_analysis_edges["%s|%s" % [node, child]] = true

	_update_info()
	_rebuild_edges()
	_apply_selection_visuals()
	if mode == AnalysisMode.PATHS:
		_start_path_trace()


## Runs the pulse along every traced chain at once, one step at a time.
##
## All paths advance together rather than sequentially: they usually share
## their opening edges, so playing them one after another would replay the
## same route repeatedly and take far longer than it is worth watching.
## Turns the camera to face the entry point the trace starts from, so the
## animation is not playing off-screen behind you. Only rotates -- flying you
## somewhere else would lose the position you had chosen.
func _face_trace_start() -> void:
	if _analysis_paths.is_empty() or _camera == null:
		return
	var first_chain: Array = _analysis_paths[0]
	if first_chain.is_empty():
		return
	var start_path := String(first_chain[0])
	if not _positions.has(start_path):
		return
	# Capture the mouse as part of turning: the camera is about to move on its
	# own, and needing a click before you can look around would fight that.
	_camera.set_captured(true)
	_camera.face_towards(_positions[start_path])


func _start_path_trace() -> void:
	_trace_reached.clear()
	_trace_edges_done.clear()
	_trace_step = 0
	_trace_t = 0.0
	_trace_delay = 0.0
	_trace_active = not _analysis_paths.is_empty()
	if _trace_active:
		# Entry points are lit from the outset -- that is where the walk begins.
		for chain_any in _analysis_paths:
			var chain: Array = chain_any
			if not chain.is_empty():
				_trace_reached[String(chain[0])] = true
	_rebuild_edges()
	_apply_selection_visuals()
	_face_trace_start()


func _stop_path_trace() -> void:
	if not _trace_active:
		return
	_trace_active = false
	_trace_reached.clear()
	_trace_edges_done.clear()
	if _trace_pulses != null:
		_trace_pulses.visible = false


## How many edges the longest traced chain has: the number of steps a full
## play-through takes.
func _trace_total_steps() -> int:
	var longest := 0
	for chain_any in _analysis_paths:
		longest = maxi(longest, (chain_any as Array).size() - 1)
	return longest


func _update_path_trace(delta: float) -> void:
	if not _trace_active or _analysis_mode != AnalysisMode.PATHS:
		return

	if _trace_delay > 0.0:
		_trace_delay -= delta
		if _trace_delay <= 0.0:
			# Replay from the start, so the route can be followed more than
			# once without having to re-issue the command.
			_trace_reached.clear()
			_trace_edges_done.clear()
			for chain_any in _analysis_paths:
				var chain_restart: Array = chain_any
				if not chain_restart.is_empty():
					_trace_reached[String(chain_restart[0])] = true
			_trace_step = 0
			_trace_t = 0.0
			_rebuild_edges()
			_apply_selection_visuals()
		return

	var step_duration := TRACE_EDGE_SECONDS + TRACE_NODE_SECONDS
	_trace_t += delta / maxf(step_duration, 0.001)

	_draw_trace_pulses()

	if _trace_t < 1.0:
		return

	# Step complete: everything this step travelled to is now lit.
	var changed := false
	for chain_any in _analysis_paths:
		var chain: Array = chain_any
		if _trace_step + 1 >= chain.size():
			continue
		var from_path := String(chain[_trace_step])
		var to_path := String(chain[_trace_step + 1])
		if not _trace_reached.has(to_path):
			_trace_reached[to_path] = true
			changed = true
		var edge_key := "%s|%s" % [from_path, to_path]
		if not _trace_edges_done.has(edge_key):
			_trace_edges_done[edge_key] = true
			changed = true

	_trace_step += 1
	_trace_t = 0.0
	if changed:
		_rebuild_edges()
		_apply_selection_visuals()

	if _trace_step >= _trace_total_steps():
		# Finished: hold the completed chain, then replay.
		_trace_delay = TRACE_LOOP_DELAY
		if _trace_pulses != null:
			_trace_pulses.visible = false


## Draws one pulse per chain, positioned along the edge it is currently
## crossing. A MultiMesh keeps it to a single draw call however many chains
## are being traced.
func _draw_trace_pulses() -> void:
	var positions: Array = []
	# Travel occupies the first part of the step; the remainder is the pause
	# on the node, during which the pulse sits still.
	var travel := clampf(
		_trace_t * (TRACE_EDGE_SECONDS + TRACE_NODE_SECONDS) / maxf(TRACE_EDGE_SECONDS, 0.001),
		0.0, 1.0
	)
	for chain_any in _analysis_paths:
		var chain: Array = chain_any
		if _trace_step + 1 >= chain.size():
			continue
		var from_path := String(chain[_trace_step])
		var to_path := String(chain[_trace_step + 1])
		if not _positions.has(from_path) or not _positions.has(to_path):
			continue
		positions.append(
			Vector3(_positions[from_path]).lerp(Vector3(_positions[to_path]), travel)
		)

	if positions.is_empty():
		if _trace_pulses != null:
			_trace_pulses.visible = false
		return

	if _trace_pulses == null:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = _theme_pulse
		var sphere := SphereMesh.new()
		sphere.radius = 0.5
		sphere.height = 1.0
		sphere.radial_segments = 8
		sphere.rings = 4
		sphere.material = material
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = sphere
		_trace_pulses = MultiMeshInstance3D.new()
		_trace_pulses.multimesh = multimesh
		add_child(_trace_pulses)

	_trace_pulses.visible = true
	var mm: MultiMesh = _trace_pulses.multimesh
	if mm.instance_count != positions.size():
		mm.instance_count = positions.size()
	for i in positions.size():
		mm.set_instance_transform(i, Transform3D(
			Basis().scaled(Vector3.ONE * TRACE_PULSE_SIZE), positions[i]
		))


func _analysis_label() -> String:
	match _analysis_mode:
		AnalysisMode.PATHS:
			return "Reachability paths"
		AnalysisMode.BLAST:
			return "Change impact"
	return ""


## Snapshots the layout so gathered nodes have somewhere to return to.
func _snapshot_home_positions() -> void:
	_home_positions.clear()
	for key in _positions.keys():
		_home_positions[String(key)] = Vector3(_positions[key])


## Where each node should sit while the selection is gathered.
##
## Each relation keeps its OWN SUBTREE and moves as a unit -- the layout the
## scan produced is already correct, so this rearranges rather than rebuilds.
## Blocks are shelf-packed into a grid, the same packing the main layout uses,
## and stacked vertically by direction: things that depend on the selection go
## above it, things it depends on go below.
##
## Anything already occupying the destination is pushed outward rather than
## left overlapping, so the gathered cluster is always readable.
func _compute_gather_targets() -> Dictionary:
	var targets := {}
	if _selected == "" or not _home_positions.has(_selected):
		return targets

	var anchor: Vector3 = _home_positions[_selected]
	targets[_selected] = anchor

	var above: Array = []
	for r in _referrers_of(_selected):
		var referrer: String = r
		if _home_positions.has(referrer):
			above.append(referrer)

	var below: Array = []
	for r in _refs_of(_selected):
		var reference: String = r
		# A mutual reference would otherwise be placed twice; keep it above,
		# since "depends on me" is the more consequential relationship.
		if _home_positions.has(reference) and not (reference in above):
			below.append(reference)

	# Bail out on hub nodes: past a certain fan-out the gathered arrangement is
	# a wall of files, which is worse than leaving the layout alone.
	if above.size() + below.size() > GATHER_MAX_RELATIONS:
		return {}

	var claimed := {_selected: true}
	var moved := {}
	# Dependents to one side, dependencies to the other.
	_gather_direction(targets, above, anchor, -1.0, claimed, moved)
	_gather_direction(targets, below, anchor, 1.0, claimed, moved)
	_displace_bystanders(targets, anchor, moved)
	return targets


## Collects a relation and everything hanging off it in the layout tree, so a
## whole branch travels together instead of being torn apart.
func _subtree_of(root: String, claimed: Dictionary) -> Array:
	var members: Array = []
	var stack: Array = [root]
	var seen := {}
	while not stack.is_empty() and members.size() < GATHER_MAX_SUBTREE:
		var current: String = stack.pop_back()
		if seen.has(current) or claimed.has(current):
			continue
		seen[current] = true
		if not _home_positions.has(current):
			continue
		members.append(current)
		for child_any in _refs_of(current):
			var child: String = child_any
			# Only descend where the layout actually parented it here,
			# otherwise a shared asset would drag half the project with it.
			if String(_dep_parent.get(child, "")) == current and not seen.has(child):
				stack.append(child)
	return members


## Places one direction's relations near the anchor.
##
## The RELATION ROOTS are packed into a tight grid close to the selection, and
## each root's subtree trails behind it. Sizing the grid by whole-subtree
## extents instead pushed everything outward: one relation carrying a 50-node
## branch would set the spacing for all of them, so even single-file relations
## ended up further from the selection than they started -- the opposite of
## gathering.
func _gather_direction(
	targets: Dictionary, roots: Array, anchor: Vector3, side_sign: float,
	claimed: Dictionary, moved: Dictionary
) -> void:
	if roots.is_empty():
		return
	roots.sort_custom(func(a, b): return _kind_rank(String(a)) < _kind_rank(String(b)))

	var entries: Array = []
	for r in roots:
		var root: String = r
		var members := _subtree_of(root, claimed)
		if members.is_empty():
			continue
		for m in members:
			claimed[String(m)] = true
		entries.append({"root": root, "members": members})
	if entries.is_empty():
		return

	# Roots only, in a fixed-pitch grid: predictable spacing regardless of how
	# much each one happens to be carrying.
	var per_row := maxi(int(ceil(sqrt(float(entries.size())))), 1)
	var rows := int(ceil(float(entries.size()) / float(per_row)))
	var grid_depth := float(rows - 1) * GATHER_ROOT_PITCH

	for i in entries.size():
		var entry: Dictionary = entries[i]
		var root_path: String = entry["root"]
		var members2: Array = entry["members"]
		var column := i % per_row
		var row := i / per_row

		var root_home: Vector3 = _home_positions[root_path]
		var destination := Vector3(
			anchor.x + side_sign * (GATHER_SIDE_GAP + float(column) * GATHER_ROOT_PITCH),
			root_home.y,
			anchor.z + float(row) * GATHER_ROOT_PITCH - grid_depth * 0.5
		)
		# Shift the whole branch by however far its root moved, so the subtree
		# keeps its shape and simply follows along.
		var shift := destination - root_home
		for m2 in members2:
			var member: String = m2
			targets[member] = Vector3(_home_positions[member]) + shift
			moved[member] = true






## Pushes unrelated nodes out of the space the gathered cluster now occupies,
## so nothing ends up buried underneath it.
func _displace_bystanders(targets: Dictionary, anchor: Vector3, moved: Dictionary) -> void:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for key in targets.keys():
		var p: Vector3 = targets[key]
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)
	if min_x == INF:
		return
	min_x -= GATHER_CLEARANCE
	max_x += GATHER_CLEARANCE
	min_z -= GATHER_CLEARANCE
	max_z += GATHER_CLEARANCE

	for key in _home_positions.keys():
		var path: String = key
		if moved.has(path) or targets.has(path):
			continue
		var home: Vector3 = _home_positions[path]
		if home.x < min_x or home.x > max_x or home.z < min_z or home.z > max_z:
			continue   # already clear of the cluster
		# Push along whichever axis needs the least movement.
		var push_left := home.x - min_x
		var push_right := max_x - home.x
		var push_back := home.z - min_z
		var push_forward := max_z - home.z
		var smallest := minf(minf(push_left, push_right), minf(push_back, push_forward))
		var shifted := home
		if smallest == push_left:
			shifted.x = min_x
		elif smallest == push_right:
			shifted.x = max_x
		elif smallest == push_back:
			shifted.z = min_z
		else:
			shifted.z = max_z
		targets[path] = shifted


## Same easing family as the camera focus, so the two motions feel related.
func _gather_ease(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return -(cos(PI * x) - 1.0) / 2.0


## Decides what the gather animation should do after a selection change.
##
## If nodes are currently displaced, they always return home FIRST and gather
## afterwards. Morphing straight from one gathered arrangement into another
## looks like noise and loses any sense of where things actually live.
func _update_gather_for_selection() -> void:
	if not _gather_enabled or _home_positions.is_empty():
		return
	var displaced := not _gather_nodes.is_empty()

	if _selected == "":
		_pending_gather = false
		if displaced:
			_start_gather_stage(GatherStage.RETURNING)
		return

	# Nothing to gather (hub bail-out, or no relations): still return anything
	# currently displaced, so the previous selection's arrangement is undone.
	if _compute_gather_targets().is_empty():
		_pending_gather = false
		if displaced:
			_start_gather_stage(GatherStage.RETURNING)
		return

	if displaced:
		_pending_gather = true
		_start_gather_stage(GatherStage.RETURNING)
	else:
		_start_gather_stage(GatherStage.GATHERING)


func _start_gather_stage(stage: GatherStage) -> void:
	_gather_from.clear()
	_gather_to.clear()

	if stage == GatherStage.RETURNING:
		# Everything that was displaced returns, bystanders included -- they
		# were pushed aside by the gather, so they are part of undoing it.
		for key in _gather_nodes.keys():
			var path: String = key
			if _positions.has(path) and _home_positions.has(path):
				_gather_from[path] = Vector3(_positions[path])
				_gather_to[path] = Vector3(_home_positions[path])
	else:
		var targets := _compute_gather_targets()
		if targets.size() <= 1:
			_gather_stage = GatherStage.IDLE
			return
		_gather_nodes.clear()
		for key in targets.keys():
			var path2: String = key
			_gather_nodes[path2] = true
			_gather_from[path2] = Vector3(_positions.get(path2, targets[path2]))
			_gather_to[path2] = Vector3(targets[path2])

	if _gather_from.is_empty():
		_gather_stage = GatherStage.IDLE
		return
	_gather_t = 0.0
	_gather_stage = stage


func _update_gather(delta: float) -> void:
	if _gather_stage == GatherStage.IDLE:
		return

	_gather_t += delta / maxf(GATHER_SECONDS, 0.001)
	var eased := _gather_ease(_gather_t)
	for key in _gather_from.keys():
		var path: String = key
		_positions[path] = Vector3(_gather_from[path]).lerp(Vector3(_gather_to[path]), eased)
		_sync_node_visual(path)
	_rebuild_edges()
	_label_scale_dirty = true

	if _gather_t < 1.0:
		return

	if _gather_stage == GatherStage.RETURNING:
		_gather_nodes.clear()
		if _pending_gather and _selected != "":
			_pending_gather = false
			_start_gather_stage(GatherStage.GATHERING)
			return
	_gather_stage = GatherStage.IDLE


## Moves a node's visuals to wherever _positions now says it is.
func _sync_node_visual(path: String) -> void:
	var position_now: Vector3 = _positions[path]
	if _sprites.has(path):
		(_sprites[path] as Sprite3D).position = position_now
	if _labels.has(path):
		var size := float(_sizes.get(path, NODE_MIN_SIZE))
		(_labels[path] as Label3D).position = position_now + Vector3(0, size * 1.1 + LABEL_LIFT, 0)
	# Sphere nodes live in a MultiMesh, so their instance index has to be
	# looked up rather than read off a scene node.
	var sphere_index := _sphere_paths.find(path)
	if sphere_index != -1 and _mesh_instance != null and _mesh_instance.multimesh != null:
		var size2 := float(_sizes.get(path, NODE_MIN_SIZE))
		_mesh_instance.multimesh.set_instance_transform(
			sphere_index, Transform3D(Basis().scaled(Vector3.ONE * size2), position_now)
		)


func _show_toast(message: String) -> void:
	if _toast_label == null:
		return
	_toast_label.text = message
	_toast_time = TOAST_SECONDS


func _process(delta: float) -> void:
	_update_long_press(delta)
	_update_gather(delta)
	_update_path_trace(delta)
	_update_label_scaling()
	if _toast_time <= 0.0:
		return
	_toast_time -= delta
	var alpha := clampf(_toast_time / 0.6, 0.0, 1.0)
	_toast_label.modulate = Color(1, 1, 1, alpha)


## Expands the left tree down to a path and scrolls it into view.
func _reveal_in_tree(path: String) -> void:
	if _file_tree == null:
		return
	if not _tree_items.has(path):
		# It may be filtered out; clearing the filter is friendlier than
		# silently failing to reveal it.
		if _filter_text != "":
			_filter_text = ""
			if _file_filter != null:
				_file_filter.text = ""
			_populate_file_tree()
		if not _tree_items.has(path):
			return

	var item: TreeItem = _tree_items[path]
	var parent := item.get_parent()
	while parent != null:
		parent.set_collapsed(false)
		parent = parent.get_parent()

	# Guarded because set_selected re-emits item_selected, which would call
	# straight back into selection handling.
	_suppress_tree_signal = true
	_file_tree.set_selected(item, 0)
	_suppress_tree_signal = false
	_file_tree.scroll_to_item(item, true)


func _line_style_name() -> String:
	match _line_style:
		LineStyle.STRAND_TUBE:
			return "cable (strands wrapped in a tube)"
		LineStyle.SOLID_TUBE:
			return "solid tube (thickness = weight)"
	return "flat strands (one per line of code)"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		# Toolbar buttons and keyboard shortcuts are two faces of the same commands.
		# Defer the visual sync until after this input branch mutates its state.
		call_deferred("_sync_toolbar_buttons")
		match event.keycode:
			KEY_G:
				_layout_mode = LayoutMode.FOLDER if _layout_mode == LayoutMode.DEPENDENCY else LayoutMode.DEPENDENCY
				_selected = ""
				_update_info()
				_rebuild_all()
				_show_toast("Tree: %s" % ("real folder structure" if _layout_mode == LayoutMode.FOLDER else "dependency (hops from entry point)"))
				return
			KEY_I:
				_show_sidecars = not _show_sidecars
				_selected = ""
				_update_info()
				_rebuild_all(false)
				_show_toast("Sidecars (.import / .uid): %s" % ("shown" if _show_sidecars else "hidden"))
				return
			KEY_H:
				_heat_mode = not _heat_mode
				_rebuild_all(false)
				_show_toast("Entanglement heat: %s" % ("ON — magenta = cycle, red = heavy coupling" if _heat_mode else "OFF — colour by file type"))
				return
			KEY_P:
				_pair_scripts = not _pair_scripts
				_rebuild_all(false)
				_show_toast("Pair scripts to owning scene: %s" % ("ON" if _pair_scripts else "OFF"))
				return
			KEY_T:
				if _line_style == LineStyle.STRAND_FLAT:
					_line_style = LineStyle.STRAND_TUBE
				elif _line_style == LineStyle.STRAND_TUBE:
					_line_style = LineStyle.SOLID_TUBE
				else:
					_line_style = LineStyle.STRAND_FLAT
				_rebuild_edges()
				_show_toast("Connections: %s" % _line_style_name())
				return
			KEY_O:
				_isolate_mode = not _isolate_mode
				await _refresh_visuals()
				_show_toast("Isolate: %s" % (
					"ON — showing only the selection and its direct neighbours" if _isolate_mode
					else "OFF — showing the whole graph"
				))
				return
			KEY_K:
				_open_filter_window()
				return
			KEY_U:
				_show_embed_links = not _show_embed_links
				_save_settings()
				_rebuild_edges()
				_show_toast("Inlined-copy links: %s" % (
					"shown — purple lines join a standalone resource to the file that embeds its code"
					if _show_embed_links else "hidden (purple dots still mark the files that embed one)"
				))
				return
			KEY_R:
				_gather_enabled = not _gather_enabled
				_save_settings()
				if not _gather_enabled and not _gather_nodes.is_empty():
					_start_gather_stage(GatherStage.RETURNING)
				elif _gather_enabled and _selected != "":
					_update_gather_for_selection()
				_show_toast("Gather relations around selection: %s" % (
					"ON" if _gather_enabled else "OFF"
				))
				return
			KEY_Y:
				_relax_layout = not _relax_layout
				await _rebuild_all(false)
				_show_toast("Pull weakly-linked files toward their references: %s" % (
					"ON" if _relax_layout else "OFF"
				))
				return
			KEY_J:
				_group_affinity = not _group_affinity
				await _rebuild_all(false)
				_show_toast("Group files by naming convention: %s%s" % [
					"ON" if _group_affinity else "OFF",
					"  (%d group(s) found)" % _name_groups.size() if _group_affinity else ""
				])
				return
			KEY_C:
				_set_analysis_mode(AnalysisMode.NONE)
				_show_toast("Analysis overlay cleared")
				return
			KEY_M:
				_min_label_global = not _min_label_global
				_label_scale_dirty = true
				if not _min_label_global:
					_apply_selection_visuals()
				_show_toast("Global minimum label size: %s" % (
					"ON — every label stays at least %d px" % int(MIN_LABEL_PIXELS_GLOBAL)
					if _min_label_global else "OFF"
				))
				return
			KEY_L:
				_label_distance_culling = not _label_distance_culling
				_apply_selection_visuals()
				_show_toast("Label distance culling: %s" % (
					"ON — hidden past %d units (selection and its neighbours still shown)" % int(LABEL_VIEW_DISTANCE)
					if _label_distance_culling else "OFF — labels always visible"
				))
				return
			KEY_F, KEY_HOME:
				_go_home()
				return
			KEY_F3:
				_open_project_dialog()
				return
			KEY_F1:
				_set_left_visible(not _left_panel.visible)
				_show_toast("Project files panel: %s" % ("shown" if _left_panel.visible else "hidden"))
				return
			KEY_F2:
				_set_right_visible(not _right_panel.visible)
				_show_toast("Selection panel: %s" % ("shown" if _right_panel.visible else "hidden"))
				return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		# Cast before reading position: `event` is the base InputEvent here,
		# which has no position, so the branch would be an untyped Variant.
		var right_click := event as InputEventMouseButton
		var point: Vector2 = right_click.position
		if _camera.is_captured():
			point = _crosshair_screen_point()
		_open_node_menu(point)
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# Track press duration for the hold gesture, which is the only way to
		# reach a context menu on a touch screen.
		var left_click := event as InputEventMouseButton
		_press_active = left_click.pressed
		_press_time = 0.0
		if left_click.pressed:
			_press_consumed = false
			if _camera.is_captured():
				_press_position = _crosshair_screen_point()
			else:
				_press_position = left_click.position

	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if not _camera.is_captured():
		return
	if _press_consumed:
		return
	var hit := _pick_node()
	# A proxy stands in for its file, so clicking it selects that file.
	hit = _resolve_proxy(hit)
	if _analysis_mode != AnalysisMode.NONE and hit != "" and hit != _selected:
		_stop_path_trace()
		_analysis_mode = AnalysisMode.NONE   # a new selection asks a new question
		_analysis_nodes.clear()
		_analysis_edges.clear()
		_analysis_paths.clear()
	if hit == ORPHAN_HUB or hit == CLUSTER_HUB:
		var expanded: bool
		var group_name: String
		if hit == ORPHAN_HUB:
			_lone_orphans_expanded = not _lone_orphans_expanded
			expanded = _lone_orphans_expanded
			group_name = "Lone orphans"
		else:
			_cluster_orphans_expanded = not _cluster_orphans_expanded
			expanded = _cluster_orphans_expanded
			group_name = "Orphan clusters"
		_selected = ""
		_update_info()
		_rebuild_all(false)
		_show_toast("%s: %s" % [group_name, "shown" if expanded else "hidden"])
		return
	_selected = "" if hit == _selected else hit
	_update_gather_for_selection()
	if _selected != "":
		_reveal_in_tree(_selected)
	_update_info()
	if _isolate_mode:
		await _refresh_visuals()
	else:
		_rebuild_edges()
		_apply_selection_visuals()


func _pick_node() -> String:
	return _pick_node_at(_crosshair_screen_point())


func _crosshair_screen_point() -> Vector2:
	if _crosshair == null:
		return get_viewport().get_visible_rect().size * 0.5
	return _crosshair.get_global_rect().get_center()


## Casts a ray through the actual UI crosshair point -- not the window centre,
## because the resizable toolbar shifts the content area's centre vertically.
## Among overlapping hit volumes, the nearest visible intersection wins.
func _pick_node_at(screen_point: Vector2) -> String:
	var origin := _camera.project_ray_origin(screen_point)
	var direction := _camera.project_ray_normal(screen_point)

	var best := ""
	var best_entry := INF
	var best_score := INF
	for key in _positions.keys():
		var path: String = key
		if not _is_displayed(path):
			continue
		var world: Vector3 = _positions[path]
		var along := (world - origin).dot(direction)
		if along <= 0.0:
			continue   # behind the camera
		var miss := (origin + direction * along).distance_to(world)
		var tolerance := maxf(
			_pick_radius_for(path),
			along * PICK_MIN_ANGULAR
		)
		if miss > tolerance:
			continue
		var score := miss / tolerance
		# Choose the first visible sphere hit. Comparing only centre alignment
		# allowed a node behind the intended one to win when their targets
		# overlapped, which made the clickable area feel off-centre.
		var entry := along - sqrt(maxf(tolerance * tolerance - miss * miss, 0.0))
		if entry < best_entry or (is_equal_approx(entry, best_entry) and score < best_score):
			best_entry = entry
			best_score = score
			best = path
	return best


func _pick_radius_for(path: String) -> float:
	if _sprites.has(path):
		var sprite := _sprites[path] as Sprite3D
		if sprite != null and sprite.texture != null:
			var rendered := sprite.texture.get_size() * sprite.pixel_size
			# A sphere enclosing the whole billboard includes its corners and
			# remains centred on exactly the same position as the Sprite3D.
			return rendered.length() * 0.5 * PICK_VISUAL_PADDING
	var size := float(_sizes.get(path, NODE_MIN_SIZE))
	if path == ORPHAN_HUB:
		return size * sqrt(3.0) * 0.5 * PICK_VISUAL_PADDING
	if path == CLUSTER_HUB:
		return size * 0.6 * PICK_VISUAL_PADDING
	return size * 0.5 * PICK_VISUAL_PADDING


func _update_info() -> void:
	if _selected == "":
		_info_label.text = "[color=#8a8f99]Nothing selected.\n\nClick a node in the 3D view, or a file on the left.[/color]"
		return

	var out: Array = []
	var accent := _color_for(_selected).to_html(false)
	out.append("[b][color=#%s]%s[/color][/b]" % [accent, _selected.get_file()])
	out.append("[color=#8a8f99]%s[/color]" % _selected.get_base_dir())
	out.append("")

	if _dir_nodes.has(_selected):
		var contained := 0
		for key in _positions.keys():
			if String(key).begins_with(_selected + "/"):
				contained += 1
		out.append("[b]folder[/b] — %d item(s) inside" % contained)
		_info_label.text = "\n".join(out)
		return

	out.append("[b]kind[/b]  %s" % TypeIcons.kind_label(TypeIcons.kind_of(_selected)))

	if _embed_hosts.has(_selected):
		var embedded_here: Array = _embed_hosts[_selected]
		out.append("")
		out.append("[color=#ffb84d][b]Embeds %d source file(s)[/b][/color]" % embedded_here.size())
		out.append("[color=#8a8f99]Their code is inlined here. They are shown just below this node, joined by a dashed line.[/color]")
		for e in embedded_here:
			var embedded_path := String(e)
			out.append("    [url=%s]%s[/url]  [color=#7a808c]%s[/color]" % [
				embedded_path, embedded_path.get_file(), embedded_path.get_base_dir()
			])

	if _orphan_set.has(_selected):
		out.append("[color=#ff5b4f][b]ORPHAN[/b] — never reached from an entry point[/color]")
		if _orphan_notes.has(_selected):
			var dup := String(_orphan_notes[_selected])
			out.append("")
			out.append("[color=#ffb84d][b]⚠ CAUTION — do not delete blindly[/b][/color]")
			out.append("[color=#ffb84d]This file's exact content was found embedded inside[/color]")
			out.append("    [url=%s]%s[/url]  [color=#7a808c]%s[/color]" % [
				dup, dup.get_file(), dup.get_base_dir()
			])
			out.append("[color=#ffb84d]Nothing references this file, but its code IS running -- from that inline copy. A \"Make Unique\" in the inspector does exactly this: it inlines the resource and silently orphans the original.[/color]")


	var info: Dictionary = _metrics.get("per_file", {}).get(_selected, {})
	if not info.is_empty():
		out.append("")
		out.append("[b]Coupling[/b]")
		out.append("code weight   [color=#5bd8ff]%d line(s) in[/color]  /  [color=#ffc85b]%d line(s) out[/color]" % [
			int(_weighted_in.get(_selected, 0)), int(_weighted_out.get(_selected, 0))
		])
		out.append("fan-in %d   fan-out %d   instability %.2f" % [
			int(info["fan_in"]), int(info["fan_out"]), float(info["instability"])
		])
		if bool(info.get("in_cycle", false)):
			# The members are already listed in the Dependency cycles section
			# below, so this only points there rather than repeating them.
			var cycle_index := int(info.get("cycle_index", -1))
			out.append("[color=#ff40f0][b]In dependency cycle %d[/b] — %d file(s), listed under \"Dependency cycles\" below[/color]" % [
				cycle_index + 1, int(info.get("cycle_size", 0))
			])

	var incoming := _incoming_weighted()
	if not incoming.is_empty():
		out.append("")
		out.append("[color=#5bd8ff][b]Referenced by[/b] — %d file(s), %d line(s)[/color]" % [
			incoming.size(), int(_weighted_in.get(_selected, 0))
		])
		for entry_any in incoming:
			var entry: Dictionary = entry_any
			var w := int(entry["weight"])
			var in_path := String(entry["path"])
			out.append("    [url=%s]%s[/url]  [color=#7a808c]%s[/color]%s" % [
				in_path, in_path.get_file(), in_path.get_base_dir(),
				"" if w == 0 else "   [color=#5bd8ff]x%d[/color]" % w
			])

	var outgoing: Array = _refs_of(_selected)
	if not outgoing.is_empty():
		var ranked: Array = outgoing.duplicate()
		ranked.sort_custom(func(a, b):
			return _link_weight(_selected, String(a)) > _link_weight(_selected, String(b))
		)
		var my_kinds: Dictionary = _edge_kinds.get(_selected, {})
		out.append("")
		out.append("[color=#ffc85b][b]References[/b] — %d file(s), %d line(s)[/color]" % [
			ranked.size(), int(_weighted_out.get(_selected, 0))
		])
		for ref_any in ranked:
			var ref_path := String(ref_any)
			var touches := _link_weight(_selected, ref_path)
			var how := String(my_kinds.get(ref_path, "sidecar"))
			out.append("    [url=%s]%s[/url]  [color=#7a808c]%s [%s][/color]%s" % [
				ref_path, ref_path.get_file(), ref_path.get_base_dir(), how,
				"" if touches == 0 else "   [color=#ffc85b]x%d[/color]" % touches
			])

	_info_label.text = "\n".join(out)
