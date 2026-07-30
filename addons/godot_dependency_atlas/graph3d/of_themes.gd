@tool
extends RefCounted

## Selectable colour palettes for the graph view.
##
## Each theme supplies a colour per file kind plus the special node roles
## (root, orphan and cycle). "Colourblind safe" exists because the
## default palette leans on red/green separation for orphan-vs-script, which
## is the single most common form of colour vision deficiency.

const THEMES := {
	"godot_dark": {
		"label": "Godot Dark", "dark": true,
		"kinds": {
			"SCENE": Color(0.40, 0.68, 1.00), "SCRIPT": Color(0.42, 0.92, 0.55),
			"SHADER": Color(0.35, 0.95, 0.85), "RESOURCE": Color(1.00, 0.70, 0.32),
			"IMAGE": Color(0.80, 0.52, 1.00), "AUDIO": Color(1.00, 0.90, 0.36),
			"VIDEO": Color(1.00, 0.52, 0.72), "MESH": Color(0.98, 0.45, 0.30),
			"FONT": Color(0.70, 0.80, 0.95), "TEXT": Color(0.85, 0.85, 0.80),
			"DATA": Color(0.60, 0.85, 0.72), "ARCHIVE": Color(0.78, 0.65, 0.45),
			"TRANSLATION": Color(0.55, 0.75, 1.00), "BINARY": Color(0.62, 0.58, 0.72),
			"FOLDER": Color(0.55, 0.58, 0.68), "OTHER": Color(0.85, 0.55, 1.00),
		},
		"root": Color(1.00, 0.85, 0.35), "orphan": Color(1.00, 0.32, 0.30),
		"cycle": Color(1.00, 0.25, 0.95),
		"background": Color(0.07, 0.08, 0.11),
	},
	"high_contrast": {
		"label": "High Contrast", "dark": true,
		"kinds": {
			"SCENE": Color(0.30, 0.75, 1.00), "SCRIPT": Color(0.30, 1.00, 0.40),
			"SHADER": Color(0.00, 1.00, 0.90), "RESOURCE": Color(1.00, 0.65, 0.00),
			"IMAGE": Color(0.85, 0.40, 1.00), "AUDIO": Color(1.00, 1.00, 0.20),
			"VIDEO": Color(1.00, 0.35, 0.65), "MESH": Color(1.00, 0.40, 0.15),
			"FONT": Color(0.75, 0.85, 1.00), "TEXT": Color(1.00, 1.00, 1.00),
			"DATA": Color(0.45, 1.00, 0.75), "ARCHIVE": Color(0.90, 0.70, 0.35),
			"TRANSLATION": Color(0.45, 0.70, 1.00), "BINARY": Color(0.70, 0.65, 0.85),
			"FOLDER": Color(0.80, 0.82, 0.90), "OTHER": Color(0.80, 0.45, 1.00),
		},
		"root": Color(1.00, 0.95, 0.20), "orphan": Color(1.00, 0.15, 0.15),
		"cycle": Color(1.00, 0.10, 1.00),
		"background": Color(0.02, 0.02, 0.04),
	},
	"colorblind_safe": {
		"label": "Colourblind Safe", "dark": true,
		# Okabe-Ito derived: distinguishable under the common deficiencies,
		# and deliberately avoids relying on red-vs-green separation.
		"kinds": {
			"SCENE": Color(0.00, 0.45, 0.70), "SCRIPT": Color(0.00, 0.62, 0.45),
			"SHADER": Color(0.34, 0.71, 0.91), "RESOURCE": Color(0.90, 0.62, 0.00),
			"IMAGE": Color(0.80, 0.47, 0.65), "AUDIO": Color(0.94, 0.89, 0.26),
			"VIDEO": Color(0.84, 0.37, 0.00), "MESH": Color(0.65, 0.46, 0.11),
			"FONT": Color(0.55, 0.63, 0.80), "TEXT": Color(0.90, 0.90, 0.90),
			"DATA": Color(0.35, 0.70, 0.65), "ARCHIVE": Color(0.72, 0.60, 0.40),
			"TRANSLATION": Color(0.45, 0.55, 0.85), "BINARY": Color(0.60, 0.60, 0.60),
			"FOLDER": Color(0.75, 0.75, 0.78), "OTHER": Color(0.60, 0.45, 0.85),
		},
		"root": Color(0.94, 0.89, 0.26), "orphan": Color(0.84, 0.37, 0.00),
		"cycle": Color(0.80, 0.47, 0.65),
		"background": Color(0.08, 0.09, 0.12),
	},
	"muted": {
		"label": "Muted", "dark": true,
		"kinds": {
			"SCENE": Color(0.52, 0.65, 0.80), "SCRIPT": Color(0.55, 0.75, 0.58),
			"SHADER": Color(0.50, 0.75, 0.72), "RESOURCE": Color(0.82, 0.70, 0.52),
			"IMAGE": Color(0.70, 0.60, 0.80), "AUDIO": Color(0.82, 0.78, 0.55),
			"VIDEO": Color(0.80, 0.60, 0.68), "MESH": Color(0.78, 0.58, 0.50),
			"FONT": Color(0.66, 0.70, 0.78), "TEXT": Color(0.76, 0.76, 0.74),
			"DATA": Color(0.60, 0.74, 0.68), "ARCHIVE": Color(0.72, 0.65, 0.55),
			"TRANSLATION": Color(0.58, 0.66, 0.80), "BINARY": Color(0.64, 0.62, 0.70),
			"FOLDER": Color(0.60, 0.62, 0.68), "OTHER": Color(0.68, 0.58, 0.80),
		},
		"root": Color(0.88, 0.78, 0.50), "orphan": Color(0.82, 0.48, 0.45),
		"cycle": Color(0.78, 0.52, 0.76),
		"background": Color(0.11, 0.12, 0.14),
	},
	"solarized_dark": {
		"label": "Solarized Dark", "dark": true,
		"kinds": {
			"SCENE": Color("#268bd2"), "SCRIPT": Color("#859900"),
			"SHADER": Color("#2aa198"), "RESOURCE": Color("#b58900"),
			"IMAGE": Color("#6c71c4"), "AUDIO": Color("#d33682"),
			"VIDEO": Color("#dc322f"), "MESH": Color("#cb4b16"),
			"FONT": Color("#93a1a1"), "TEXT": Color("#eee8d5"),
			"DATA": Color("#5faf87"), "ARCHIVE": Color("#a57706"),
			"TRANSLATION": Color("#5294c7"), "BINARY": Color("#657b83"),
			"FOLDER": Color("#839496"), "OTHER": Color("#9a86c8"),
		},
		"root": Color("#b58900"), "orphan": Color("#dc322f"),
		"cycle": Color("#d33682"),
		"background": Color("#002b36"),
	},
	"nord": {
		"label": "Nord", "dark": true,
		"kinds": {
			"SCENE": Color("#81a1c1"), "SCRIPT": Color("#a3be8c"),
			"SHADER": Color("#8fbcbb"), "RESOURCE": Color("#ebcb8b"),
			"IMAGE": Color("#b48ead"), "AUDIO": Color("#f0d8a8"),
			"VIDEO": Color("#d08770"), "MESH": Color("#bf616a"),
			"FONT": Color("#88c0d0"), "TEXT": Color("#e5e9f0"),
			"DATA": Color("#7aa6a4"), "ARCHIVE": Color("#b5735f"),
			"TRANSLATION": Color("#5e81ac"), "BINARY": Color("#6b7689"),
			"FOLDER": Color("#d8dee9"), "OTHER": Color("#a98bc4"),
		},
		"root": Color("#ebcb8b"), "orphan": Color("#bf616a"),
		"cycle": Color("#b48ead"),
		"background": Color("#2e3440"),
	},
	"gruvbox": {
		"label": "Gruvbox Dark", "dark": true,
		"kinds": {
			"SCENE": Color("#83a598"), "SCRIPT": Color("#b8bb26"),
			"SHADER": Color("#8ec07c"), "RESOURCE": Color("#fabd2f"),
			"IMAGE": Color("#d3869b"), "AUDIO": Color("#fe8019"),
			"VIDEO": Color("#fb4934"), "MESH": Color("#d65d0e"),
			"FONT": Color("#a89984"), "TEXT": Color("#ebdbb2"),
			"DATA": Color("#689d6a"), "ARCHIVE": Color("#bdae93"),
			"TRANSLATION": Color("#458588"), "BINARY": Color("#928374"),
			"FOLDER": Color("#d5c4a1"), "OTHER": Color("#c39bd6"),
		},
		"root": Color("#fabd2f"), "orphan": Color("#fb4934"),
		"cycle": Color("#d3869b"),
		"background": Color("#282828"),
	},
	"dracula": {
		"label": "Dracula", "dark": true,
		"kinds": {
			"SCENE": Color("#8be9fd"), "SCRIPT": Color("#50fa7b"),
			"SHADER": Color("#5bc8e0"), "RESOURCE": Color("#ffb86c"),
			"IMAGE": Color("#bd93f9"), "AUDIO": Color("#f1fa8c"),
			"VIDEO": Color("#ff79c6"), "MESH": Color("#ff5555"),
			"FONT": Color("#8493c4"), "TEXT": Color("#f8f8f2"),
			"DATA": Color("#3fd066"), "ARCHIVE": Color("#d99a58"),
			"TRANSLATION": Color("#6272a4"), "BINARY": Color("#6b6f85"),
			"FOLDER": Color("#b0b4c9"), "OTHER": Color("#c9a2ff"),
		},
		"root": Color("#f1fa8c"), "orphan": Color("#ff5555"),
		"cycle": Color("#bd93f9"),
		"background": Color("#282a36"),
	},
	"synthwave": {
		"label": "Synthwave", "dark": true,
		"kinds": {
			"SCENE": Color("#36f9f6"), "SCRIPT": Color("#72f1b8"),
			"SHADER": Color("#2bd9d6"), "RESOURCE": Color("#fede5d"),
			"IMAGE": Color("#ff7edb"), "AUDIO": Color("#ffd93d"),
			"VIDEO": Color("#ff8b39"), "MESH": Color("#fe4450"),
			"FONT": Color("#a3a6c4"), "TEXT": Color("#ffffff"),
			"DATA": Color("#4fd6a0"), "ARCHIVE": Color("#b967ff"),
			"TRANSLATION": Color("#7a80ff"), "BINARY": Color("#6d6a8a"),
			"FOLDER": Color("#d0cce8"), "OTHER": Color("#c37bff"),
		},
		"root": Color("#fede5d"), "orphan": Color("#fe4450"),
		"cycle": Color("#ff7edb"),
		"background": Color("#241b2f"),
	},
	"blueprint": {
		"label": "Blueprint", "dark": true,
		# Technical-drawing look: a narrow cyan/white range with a few warm
		# accents, so structure reads as one material and the exceptions pop.
		"kinds": {
			"SCENE": Color("#7fdbff"), "SCRIPT": Color("#b6e8ff"),
			"SHADER": Color("#39cccc"), "RESOURCE": Color("#ffd479"),
			"IMAGE": Color("#a6c8ff"), "AUDIO": Color("#ffe9a8"),
			"VIDEO": Color("#ff9db0"), "MESH": Color("#ffab70"),
			"FONT": Color("#cfe8ff"), "TEXT": Color("#ffffff"),
			"DATA": Color("#86e5d0"), "ARCHIVE": Color("#c3b299"),
			"TRANSLATION": Color("#6fa8dc"), "BINARY": Color("#8a9bb0"),
			"FOLDER": Color("#dbe9f7"), "OTHER": Color("#b49bff"),
		},
		"root": Color("#ffd479"), "orphan": Color("#ff6b8a"),
		"cycle": Color("#ff9db0"),
		"background": Color("#0a2540"),
	},
	"paper_light": {
		"label": "Paper (light)", "dark": false,
		# The only light theme. Labels invert to dark text with a white
		# outline, handled via the "dark" flag above.
		"kinds": {
			"SCENE": Color("#1f6feb"), "SCRIPT": Color("#1a7f37"),
			"SHADER": Color("#0d7d78"), "RESOURCE": Color("#b8620a"),
			"IMAGE": Color("#7d3ac1"), "AUDIO": Color("#9a6700"),
			"VIDEO": Color("#bc2d6a"), "MESH": Color("#b4310f"),
			"FONT": Color("#495a72"), "TEXT": Color("#24292f"),
			"DATA": Color("#0f7a5a"), "ARCHIVE": Color("#7a5c2e"),
			"TRANSLATION": Color("#2c5aa8"), "BINARY": Color("#5b5f66"),
			"FOLDER": Color("#4a4f57"), "OTHER": Color("#6b3fa0"),
		},
		"root": Color("#a8620a"), "orphan": Color("#c1121f"),
		"cycle": Color("#9a1f9a"),
		"background": Color("#f2efe6"),
	},
}

const DEFAULT_THEME := "godot_dark"
static var CUSTOM_THEMES := {}


static func theme_ids() -> Array:
	var ids: Array = THEMES.keys() + CUSTOM_THEMES.keys()
	ids.sort()
	return ids


static func label_of(theme_id: String) -> String:
	return String(palette(theme_id)["label"])


static func palette(theme_id: String) -> Dictionary:
	return CUSTOM_THEMES.get(theme_id, THEMES.get(theme_id, THEMES[DEFAULT_THEME]))


## Colour for a kind name (the Kind enum key, e.g. "SCENE").
static func kind_color(theme_id: String, kind_name: String) -> Color:
	var kinds: Dictionary = palette(theme_id)["kinds"]
	return kinds.get(kind_name, Color(0.7, 0.7, 0.7))


static func role_color(theme_id: String, role: String) -> Color:
	return palette(theme_id).get(role, Color(0.7, 0.7, 0.7))


## Light themes need inverted label treatment: dark text with a white
## outline instead of the other way round.
static func is_dark(theme_id: String) -> bool:
	return bool(palette(theme_id).get("dark", true))


## Connection colours are a SEPARATE theme from the node palette, so the two
## can be mixed: a calm node palette with vivid links, or the reverse.
##
## Only visually meaningful relationships belong here. Structural tree,
## cross-file and folder edges all use "out"; their visibility is controlled
## by the shared idle/selected alpha settings rather than extra arbitrary
## colours.
const CONNECTION_THEMES := {
	"godot_dark": {
		"label": "Godot Dark",
		"out": Color("#ffb454"),
		"in": Color("#55c2ff"),
		"dangling": Color("#ff5f5f"),
		"inline": Color("#b779ff"),
		"inheritance": Color("#35e6c3"),
		"path": Color("#55e88b"),
		"impact": Color("#ff7a45"),
		"pulse": Color("#d5ffe4"),
	},
	"high_contrast": {
		"label": "High Contrast",
		"out": Color("#ffd600"),
		"in": Color("#00c8ff"),
		"dangling": Color("#ff3b3b"),
		"inline": Color("#df5cff"),
		"inheritance": Color("#00ff9d"),
		"path": Color("#35ff68"),
		"impact": Color("#ff7900"),
		"pulse": Color("#ffffff"),
	},
	"colorblind_safe": {
		"label": "Colourblind Safe",
		"out": Color("#e69f00"),
		"in": Color("#56b4e9"),
		"dangling": Color("#d55e00"),
		"inline": Color("#cc79a7"),
		"inheritance": Color("#009e73"),
		"path": Color("#009e73"),
		"impact": Color("#f0e442"),
		"pulse": Color("#e8f7ff"),
	},
	"muted": {
		"label": "Muted",
		"out": Color("#c49a62"),
		"in": Color("#6f9fbe"),
		"dangling": Color("#b86f69"),
		"inline": Color("#9b7db5"),
		"inheritance": Color("#79b8a0"),
		"path": Color("#7eae83"),
		"impact": Color("#c57d5c"),
		"pulse": Color("#d0ddd5"),
	},
	"solarized_dark": {
		"label": "Solarized Dark",
		"out": Color("#cb4b16"),
		"in": Color("#268bd2"),
		"dangling": Color("#dc322f"),
		"inline": Color("#6c71c4"),
		"inheritance": Color("#2aa198"),
		"path": Color("#859900"),
		"impact": Color("#b58900"),
		"pulse": Color("#93d6cf"),
	},
	"nord": {
		"label": "Nord",
		"out": Color("#d08770"),
		"in": Color("#88c0d0"),
		"dangling": Color("#bf616a"),
		"inline": Color("#b48ead"),
		"inheritance": Color("#8fbcbb"),
		"path": Color("#a3be8c"),
		"impact": Color("#ebcb8b"),
		"pulse": Color("#e5e9f0"),
	},
	"gruvbox": {
		"label": "Gruvbox Dark",
		"out": Color("#fe8019"),
		"in": Color("#83a598"),
		"dangling": Color("#fb4934"),
		"inline": Color("#d3869b"),
		"inheritance": Color("#8ec07c"),
		"path": Color("#b8bb26"),
		"impact": Color("#fabd2f"),
		"pulse": Color("#ebdbb2"),
	},
	"dracula": {
		"label": "Dracula",
		"out": Color("#ffb86c"),
		"in": Color("#8be9fd"),
		"dangling": Color("#ff5555"),
		"inline": Color("#bd93f9"),
		"inheritance": Color("#50fa7b"),
		"path": Color("#50fa7b"),
		"impact": Color("#f1fa8c"),
		"pulse": Color("#f8f8f2"),
	},
	"synthwave": {
		"label": "Synthwave",
		"out": Color("#ff8b39"),
		"in": Color("#36f9f6"),
		"dangling": Color("#fe4450"),
		"inline": Color("#b967ff"),
		"inheritance": Color("#72f1b8"),
		"path": Color("#72f1b8"),
		"impact": Color("#fede5d"),
		"pulse": Color("#ffffff"),
	},
	"blueprint": {
		"label": "Blueprint",
		"out": Color("#ffd479"),
		"in": Color("#7fdbff"),
		"dangling": Color("#ff6b8a"),
		"inline": Color("#b49bff"),
		"inheritance": Color("#86e5d0"),
		"path": Color("#86e5d0"),
		"impact": Color("#ffab70"),
		"pulse": Color("#ffffff"),
	},
	"paper_light": {
		"label": "Paper (light)",
		"out": Color("#b8620a"),
		"in": Color("#1f6feb"),
		"dangling": Color("#c1121f"),
		"inline": Color("#7d3ac1"),
		"inheritance": Color("#0d7d78"),
		"path": Color("#1a7f37"),
		"impact": Color("#b4310f"),
		"pulse": Color("#0d7d78"),
	},
}

const DEFAULT_CONNECTION_THEME := "godot_dark"
static var CUSTOM_CONNECTION_THEMES := {}


static func connection_theme_ids() -> Array:
	var ids: Array = CONNECTION_THEMES.keys() + CUSTOM_CONNECTION_THEMES.keys()
	ids.sort()
	return ids


static func connection_label_of(theme_id: String) -> String:
	return String(CUSTOM_CONNECTION_THEMES.get(
		theme_id, CONNECTION_THEMES.get(theme_id, CONNECTION_THEMES[DEFAULT_CONNECTION_THEME])
	)["label"])


## All connection colour keys, in display order.
const CONNECTION_KEYS := [
	"out", "in", "dangling", "inline", "inheritance", "path", "impact", "pulse"
]


static func connection_color(theme_id: String, key: String) -> Color:
	var selected: Dictionary = CUSTOM_CONNECTION_THEMES.get(
		theme_id, CONNECTION_THEMES.get(theme_id, CONNECTION_THEMES[DEFAULT_CONNECTION_THEME])
	)
	return selected.get(
		key,
		(CONNECTION_THEMES[DEFAULT_CONNECTION_THEME] as Dictionary).get(
			key, Color(0.7, 0.7, 0.7)
		)
	)


static func clear_custom_themes() -> void:
	CUSTOM_THEMES.clear()
	CUSTOM_CONNECTION_THEMES.clear()


static func register_custom_theme(scope: String, theme_id: String, definition: Dictionary) -> void:
	if scope == "connections":
		CUSTOM_CONNECTION_THEMES[theme_id] = definition
	else:
		CUSTOM_THEMES[theme_id] = definition


static func is_custom_theme(scope: String, theme_id: String) -> bool:
	return (
		CUSTOM_CONNECTION_THEMES.has(theme_id)
		if scope == "connections" else CUSTOM_THEMES.has(theme_id)
	)
