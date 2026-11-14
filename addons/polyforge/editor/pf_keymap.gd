## PfKeymap — one table of Blender shortcuts, split into sets:
##   EDIT    – Edit Mode in the 3D viewport (Blender keymap, fixed)
##   OBJECT  – optional Object Mode shortcuts (off by default, remappable)
##   GLOBAL  – always active in the 3D viewport (Tab, Numpad /)
## Shortcut text: "Shift+D", "Ctrl+I", "Alt+Z", "KP Divide", "Period", ...
@tool
extends RefCounted

const GLOBAL := {
	"toggle_edit": ["Tab"],
	"local_view": ["KP Divide"],
}

const EDIT := {
	"mode_vertex": ["1"],
	"mode_edge": ["2"],
	"mode_face": ["3"],
	"select_all": ["A"],
	"select_none": ["Alt+A"],
	"select_invert": ["Ctrl+I"],
	"box_select": ["B"],
	"circle_select": ["C"],
	"select_linked_pick": ["L"],
	"deselect_linked_pick": ["Shift+L"],
	"select_linked": ["Ctrl+L"],
	"select_similar_menu": ["Shift+G"],
	"select_more": ["Ctrl+KP Add", "Ctrl+Equal"],
	"select_less": ["Ctrl+KP Subtract", "Ctrl+Minus"],
	"hide": ["H"],
	"hide_unselected": ["Shift+H"],
	"reveal": ["Alt+H"],
	"xray": ["Alt+Z"],
	"grab": ["G"],
	"rotate": ["R"],
	"scale": ["S"],
	"pivot_menu": ["Period"],
	"snap_menu": ["Shift+S"],
	"view_selected": ["KP Period"],
	"proportional": ["O"],
	"prop_falloff_menu": ["Shift+O"],
	"mirror_menu": ["Ctrl+M"],
	"snap_toggle": ["Shift+Tab"],
	"snap_target_menu": ["Ctrl+Shift+Tab"],
	"orientation_menu": ["Comma"],
	"toggle_gizmo": ["Ctrl+QuoteLeft"],
	"add_mesh": ["Shift+A"],
	"context_menu_w": ["W"],
	"delete_menu": ["X", "Delete"],
	"dissolve": ["Ctrl+X"],
	"merge_menu": ["M"],
	"extrude": ["E"],
	"extrude_menu": ["Alt+E"],
	"inset": ["I"],
	"fatten": ["Alt+S"],
	"duplicate": ["Shift+D"],
	"make_face": ["F"],
	"recalc_outside": ["Shift+N"],
	"recalc_inside": ["Ctrl+Shift+N"],
	"normals_menu": ["Alt+N"],
	"triangulate": ["Ctrl+T"],
	"tris_to_quads": ["Alt+J"],
	"vertex_menu": ["Ctrl+V"],
	"edge_menu": ["Ctrl+E"],
	"face_menu": ["Ctrl+F"],
	"search": ["F3"],
	"connect_path": ["J"],
	"loopcut": ["Ctrl+R"],
	"bevel": ["Ctrl+B"],
	"bevel_verts": ["Ctrl+Shift+B"],
	"separate_menu": ["P"],
	"focus": ["Alt+F"],
	"redo_panel": ["F9"],
	"uv_menu": ["U"],
	"next_tab": ["Ctrl+PageDown"],
	"prev_tab": ["Ctrl+PageUp"],
}

const OBJECT := {
	"obj_grab": ["G"],
	"obj_rotate": ["R"],
	"obj_scale": ["S"],
	"obj_delete": ["X"],
	"obj_duplicate": ["Shift+D"],
	"obj_add": ["Shift+A"],
	"obj_join": ["Ctrl+J"],
}

const LABELS := {
	"toggle_edit": "Toggle Edit Mode", "local_view": "Local View",
	"mode_vertex": "Vertex Select", "mode_edge": "Edge Select", "mode_face": "Face Select",
	"select_all": "Select All", "select_none": "Select None", "select_invert": "Invert Selection",
	"box_select": "Box Select", "circle_select": "Circle Select",
	"select_linked_pick": "Select Linked (under cursor)", "deselect_linked_pick": "Deselect Linked (under cursor)",
	"select_linked": "Select Linked", "select_similar_menu": "Select Similar", "snap_menu": "Snap Menu", "view_selected": "View Selected", "proportional": "Proportional Editing", "prop_falloff_menu": "Proportional Falloff", "mirror_menu": "Mirror", "snap_toggle": "Toggle Snapping", "snap_target_menu": "Snap To", "select_more": "Select More", "select_less": "Select Less",
	"hide": "Hide", "hide_unselected": "Hide Unselected", "reveal": "Reveal Hidden", "xray": "Toggle X-Ray",
	"grab": "Move", "rotate": "Rotate", "scale": "Scale", "pivot_menu": "Pivot Point menu",
	"orientation_menu": "Transform Orientation menu", "toggle_gizmo": "Toggle gizmo",
	"add_mesh": "Add Mesh", "context_menu_w": "Context Menu (Right Click Select)",
	"delete_menu": "Delete menu", "dissolve": "Dissolve (by select mode)", "merge_menu": "Merge menu",
	"extrude": "Extrude and Move", "extrude_menu": "Extrude menu", "inset": "Inset Faces", "fatten": "Shrink/Fatten",
	"duplicate": "Duplicate and Move", "make_face": "Make Edge/Face", "recalc_outside": "Recalculate Normals Outside",
	"recalc_inside": "Recalculate Normals Inside", "normals_menu": "Normals menu", "triangulate": "Triangulate Faces",
	"tris_to_quads": "Tris to Quads", "vertex_menu": "Vertex menu", "edge_menu": "Edge menu", "face_menu": "Face menu",
	"search": "Search operators",
	"connect_path": "Connect Vertex Path", "loopcut": "Loop Cut and Slide", "bevel": "Bevel Edges",
	"bevel_verts": "Bevel Vertices", "separate_menu": "Separate menu", "focus": "Toggle Focus mode",
	"redo_panel": "Adjust Last Operation", "uv_menu": "UV Unwrap menu", "obj_join": "Join meshes", "obj_boolean": "Boolean menu",
	"next_tab": "Next tab (Mesh Edit / UV Edit)", "prev_tab": "Previous tab",
	"obj_grab": "Move objects", "obj_rotate": "Rotate objects", "obj_scale": "Scale objects",
	"obj_delete": "Delete objects", "obj_duplicate": "Duplicate objects", "obj_add": "Add Mesh",
}

## Keys that keep working for Godot while in Edit Mode.
static func is_passthrough(k: InputEventKey) -> bool:
	var code := _code(k)
	if code >= KEY_KP_0 and code <= KEY_KP_9 or code in [KEY_KP_PERIOD, KEY_KP_ENTER, KEY_KP_ADD, KEY_KP_SUBTRACT, KEY_KP_MULTIPLY]:
		return not k.ctrl_pressed or code in [KEY_KP_1, KEY_KP_3, KEY_KP_7, KEY_KP_9]   # Ctrl+numpad = opposite views
	if code >= KEY_F1 and code <= KEY_F12:
		return true
	if k.ctrl_pressed and code in [KEY_S, KEY_Z, KEY_Y, KEY_O, KEY_N, KEY_Q, KEY_W]:
		return true
	if code in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
		return true
	return false

static func _code(k: InputEventKey) -> int:
	return k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode

## Parses "Ctrl+Shift+D" into {code, ctrl, shift, alt}.
static func parse(text: String) -> Dictionary:
	var parts := text.split("+")
	var d := {"code": KEY_NONE, "ctrl": false, "shift": false, "alt": false}
	for i in parts.size():
		var p := parts[i].strip_edges()
		if i < parts.size() - 1:
			match p.to_lower():
				"ctrl": d["ctrl"] = true
				"shift": d["shift"] = true
				"alt": d["alt"] = true
		else:
			d["code"] = OS.find_keycode_from_string(p)
	return d

static func matches(k: InputEventKey, text: String) -> bool:
	var d := parse(text)
	if d["code"] == KEY_NONE:
		return false
	var code := _code(k)
	if code != d["code"] and k.keycode != d["code"]:
		return false
	return k.ctrl_pressed == d["ctrl"] and k.shift_pressed == d["shift"] and k.alt_pressed == d["alt"]

## First action of `table` matching the event ("" when none). `overrides`:
## action -> shortcut text (replaces the defaults of that action).
static func find(table: Dictionary, k: InputEventKey, overrides := {}) -> String:
	for action in table:
		var keys: Array = [overrides[action]] if overrides.has(action) and str(overrides[action]) != "" else table[action]
		for t in keys:
			if matches(k, t):
				return action
	return ""

## Shortcut text for display.
static func text_of(table: Dictionary, action: String, overrides := {}) -> String:
	if overrides.has(action) and str(overrides[action]) != "":
		return overrides[action]
	return " / ".join(PackedStringArray(table.get(action, [])))
