@tool
extends RefCounted

## Selectable colour palettes for the graph view.
##
## Each theme supplies a colour per file kind plus the special roles (root,
## orphan, cycle, edge directions). "Colourblind safe" exists because the
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
		"cycle": Color(1.00, 0.25, 0.95), "out": Color(1.00, 0.78, 0.35),
		"in": Color(0.40, 0.85, 1.00), "background": Color(0.07, 0.08, 0.11),
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
		"cycle": Color(1.00, 0.10, 1.00), "out": Color(1.00, 0.72, 0.10),
		"in": Color(0.20, 0.85, 1.00), "background": Color(0.02, 0.02, 0.04),
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
		"cycle": Color(0.80, 0.47, 0.65), "out": Color(0.90, 0.62, 0.00),
		"in": Color(0.34, 0.71, 0.91), "background": Color(0.08, 0.09, 0.12),
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
		"cycle": Color(0.78, 0.52, 0.76), "out": Color(0.82, 0.72, 0.52),
		"in": Color(0.55, 0.72, 0.85), "background": Color(0.11, 0.12, 0.14),
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
		"cycle": Color("#d33682"), "out": Color("#cb4b16"),
		"in": Color("#268bd2"), "background": Color("#002b36"),
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
		"cycle": Color("#b48ead"), "out": Color("#d08770"),
		"in": Color("#88c0d0"), "background": Color("#2e3440"),
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
		"cycle": Color("#d3869b"), "out": Color("#fe8019"),
		"in": Color("#83a598"), "background": Color("#282828"),
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
		"cycle": Color("#bd93f9"), "out": Color("#ffb86c"),
		"in": Color("#8be9fd"), "background": Color("#282a36"),
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
		"cycle": Color("#ff7edb"), "out": Color("#ff8b39"),
		"in": Color("#36f9f6"), "background": Color("#241b2f"),
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
		"cycle": Color("#ff9db0"), "out": Color("#ffd479"),
		"in": Color("#7fdbff"), "background": Color("#0a2540"),
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
		"cycle": Color("#9a1f9a"), "out": Color("#b8620a"),
		"in": Color("#1f6feb"), "background": Color("#f2efe6"),
	},
}

const DEFAULT_THEME := "godot_dark"


static func theme_ids() -> Array:
	var ids: Array = THEMES.keys()
	ids.sort()
	return ids


static func label_of(theme_id: String) -> String:
	return String(THEMES.get(theme_id, THEMES[DEFAULT_THEME])["label"])


static func palette(theme_id: String) -> Dictionary:
	return THEMES.get(theme_id, THEMES[DEFAULT_THEME])


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
const CONNECTION_THEMES := {
	"godot_dark": {
		"label": "Godot Dark",
		"tree_edge": Color(0.55,0.65,0.80),
		"cross_edge": Color(0.50,0.42,0.60),
		"orphan_edge": Color(0.66,0.40,0.38),
		"proxied": Color(0.35,0.85,0.78),
		"duplicated": Color(1.00,0.72,0.30),
		"embed_link": Color(0.72,0.42,1.00),
		"folder_link": Color(0.45,0.90,0.80),
		"path": Color(0.40,1.00,0.55),
		"blast": Color(1.00,0.55,0.25),
		"blast_far": Color(0.72,0.45,0.32),
		"pulse": Color(0.75,1.00,0.85),
		"highlight": Color(1.00,0.95,0.50),
	},
	"high_contrast": {
		"label": "High Contrast",
		"tree_edge": Color(0.95,0.95,1.00),
		"cross_edge": Color(0.70,0.55,0.95),
		"orphan_edge": Color(0.85,0.45,0.40),
		"proxied": Color(0.20,1.00,0.90),
		"duplicated": Color(1.00,0.75,0.10),
		"embed_link": Color(0.85,0.40,1.00),
		"folder_link": Color(0.30,1.00,0.85),
		"path": Color(0.25,1.00,0.40),
		"blast": Color(1.00,0.50,0.10),
		"blast_far": Color(0.80,0.45,0.25),
		"pulse": Color(0.80,1.00,0.90),
		"highlight": Color(1.00,1.00,0.30),
	},
	"colorblind_safe": {
		"label": "Colourblind Safe",
		"tree_edge": Color(0.34,0.71,0.91),
		"cross_edge": Color(0.90,0.62,0.00),
		"orphan_edge": Color(0.65,0.46,0.11),
		"proxied": Color(0.34,0.71,0.91),
		"duplicated": Color(0.90,0.62,0.00),
		"embed_link": Color(0.80,0.47,0.65),
		"folder_link": Color(0.35,0.70,0.65),
		"path": Color(0.00,0.62,0.45),
		"blast": Color(0.84,0.37,0.00),
		"blast_far": Color(0.65,0.46,0.11),
		"pulse": Color(0.60,0.85,0.95),
		"highlight": Color(0.94,0.89,0.26),
	},
	"muted": {
		"label": "Muted",
		"tree_edge": Color(0.60,0.68,0.62),
		"cross_edge": Color(0.72,0.62,0.55),
		"orphan_edge": Color(0.62,0.48,0.45),
		"proxied": Color(0.45,0.75,0.72),
		"duplicated": Color(0.85,0.72,0.50),
		"embed_link": Color(0.68,0.52,0.80),
		"folder_link": Color(0.50,0.75,0.70),
		"path": Color(0.50,0.78,0.55),
		"blast": Color(0.85,0.60,0.42),
		"blast_far": Color(0.68,0.52,0.45),
		"pulse": Color(0.72,0.88,0.80),
		"highlight": Color(0.90,0.85,0.55),
	},
	"solarized_dark": {
		"label": "Solarized Dark",
		"tree_edge": Color(0.16,0.63,0.60),
		"cross_edge": Color(0.71,0.54,0.00),
		"orphan_edge": Color(0.70,0.42,0.30),
		"proxied": Color(0.16,0.63,0.60),
		"duplicated": Color(0.71,0.54,0.00),
		"embed_link": Color(0.42,0.44,0.77),
		"folder_link": Color(0.16,0.63,0.60),
		"path": Color(0.52,0.60,0.00),
		"blast": Color(0.80,0.29,0.09),
		"blast_far": Color(0.60,0.40,0.25),
		"pulse": Color(0.65,0.85,0.75),
		"highlight": Color(0.71,0.54,0.00),
	},
	"nord": {
		"label": "Nord",
		"tree_edge": Color(0.53,0.75,0.82),
		"cross_edge": Color(0.71,0.56,0.68),
		"orphan_edge": Color(0.75,0.38,0.42),
		"proxied": Color(0.56,0.74,0.73),
		"duplicated": Color(0.92,0.80,0.55),
		"embed_link": Color(0.71,0.56,0.68),
		"folder_link": Color(0.53,0.75,0.82),
		"path": Color(0.64,0.75,0.55),
		"blast": Color(0.82,0.53,0.44),
		"blast_far": Color(0.66,0.48,0.44),
		"pulse": Color(0.75,0.87,0.85),
		"highlight": Color(0.92,0.80,0.55),
	},
	"gruvbox": {
		"label": "Gruvbox Dark",
		"tree_edge": Color(0.72,0.73,0.15),
		"cross_edge": Color(0.83,0.53,0.61),
		"orphan_edge": Color(0.72,0.42,0.32),
		"proxied": Color(0.56,0.75,0.49),
		"duplicated": Color(0.98,0.74,0.18),
		"embed_link": Color(0.83,0.53,0.61),
		"folder_link": Color(0.27,0.52,0.53),
		"path": Color(0.72,0.73,0.15),
		"blast": Color(0.99,0.50,0.10),
		"blast_far": Color(0.75,0.45,0.25),
		"pulse": Color(0.80,0.88,0.70),
		"highlight": Color(0.98,0.74,0.18),
	},
	"dracula": {
		"label": "Dracula",
		"tree_edge": Color(0.55,0.91,0.99),
		"cross_edge": Color(1.00,0.47,0.78),
		"orphan_edge": Color(0.80,0.42,0.45),
		"proxied": Color(0.55,0.91,0.99),
		"duplicated": Color(1.00,0.72,0.42),
		"embed_link": Color(0.74,0.58,0.98),
		"folder_link": Color(0.35,0.85,0.88),
		"path": Color(0.31,0.98,0.48),
		"blast": Color(1.00,0.55,0.35),
		"blast_far": Color(0.72,0.48,0.42),
		"pulse": Color(0.80,1.00,0.90),
		"highlight": Color(0.95,0.98,0.55),
	},
	"synthwave": {
		"label": "Synthwave",
		"tree_edge": Color(0.21,0.98,0.96),
		"cross_edge": Color(1.00,0.49,0.86),
		"orphan_edge": Color(0.85,0.35,0.48),
		"proxied": Color(0.21,0.85,0.84),
		"duplicated": Color(1.00,0.85,0.36),
		"embed_link": Color(0.73,0.40,1.00),
		"folder_link": Color(0.21,0.98,0.96),
		"path": Color(0.45,0.95,0.72),
		"blast": Color(1.00,0.55,0.22),
		"blast_far": Color(0.75,0.45,0.40),
		"pulse": Color(0.85,1.00,0.95),
		"highlight": Color(1.00,0.89,0.36),
	},
	"blueprint": {
		"label": "Blueprint",
		"tree_edge": Color(0.50,0.86,1.00),
		"cross_edge": Color(0.85,0.80,0.55),
		"orphan_edge": Color(0.78,0.50,0.55),
		"proxied": Color(0.22,0.80,0.80),
		"duplicated": Color(1.00,0.83,0.47),
		"embed_link": Color(0.65,0.70,1.00),
		"folder_link": Color(0.22,0.80,0.80),
		"path": Color(0.50,0.90,0.85),
		"blast": Color(1.00,0.67,0.44),
		"blast_far": Color(0.72,0.55,0.48),
		"pulse": Color(0.80,0.95,1.00),
		"highlight": Color(1.00,0.83,0.47),
	},
	"paper_light": {
		"label": "Paper (light)",
		"tree_edge": Color(0.20,0.35,0.55),
		"cross_edge": Color(0.60,0.35,0.15),
		"orphan_edge": Color(0.65,0.35,0.25),
		"proxied": Color(0.05,0.55,0.52),
		"duplicated": Color(0.72,0.45,0.05),
		"embed_link": Color(0.49,0.23,0.76),
		"folder_link": Color(0.06,0.48,0.45),
		"path": Color(0.10,0.50,0.22),
		"blast": Color(0.71,0.19,0.06),
		"blast_far": Color(0.55,0.35,0.25),
		"pulse": Color(0.15,0.45,0.35),
		"highlight": Color(0.60,0.40,0.00),
	},
}

const DEFAULT_CONNECTION_THEME := "godot_dark"


static func connection_theme_ids() -> Array:
	var ids: Array = CONNECTION_THEMES.keys()
	ids.sort()
	return ids


static func connection_label_of(theme_id: String) -> String:
	return String(CONNECTION_THEMES.get(theme_id, CONNECTION_THEMES[DEFAULT_CONNECTION_THEME])["label"])


## All connection colour keys, in display order.
const CONNECTION_KEYS := ["tree_edge", "cross_edge", "orphan_edge", "proxied", "duplicated", "embed_link", "folder_link", "path", "blast", "blast_far", "pulse", "highlight"]


static func connection_color(theme_id: String, key: String) -> Color:
	var palette: Dictionary = CONNECTION_THEMES.get(theme_id, CONNECTION_THEMES[DEFAULT_CONNECTION_THEME])
	return palette.get(key, Color(0.7, 0.7, 0.7))
