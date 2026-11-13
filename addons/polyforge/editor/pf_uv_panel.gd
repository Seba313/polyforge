## PfUvPanel — the UV Edit tab: Blender's UV editor next to the 3D view.
## Shows the UVs of the faces selected in 3D (UV1 or UV2) over the texture.
## Keys work while the mouse is over the panel (like Blender):
##   click / Shift+click / LMB drag   select (vertex, face or island mode)
##   A, Alt+A, Ctrl+I, L, Ctrl+L      select all / none / invert / linked
##   G R S (+X/Y, numbers, Ctrl snap, Shift precise; LMB/Enter ok, RMB/Esc cancel)
##   P / Alt+P pin / unpin, U unwrap menu, Ctrl+P pack, Ctrl+A average scale
##   Shift+RMB 2D cursor, Shift+S snap menu, Period pivot menu, Shift+Tab snapping
##   V stitch, Y split selection
##   MMB pan, wheel zoom, Home frame 0..1
@tool
extends Control

const PfI18n := preload("res://addons/polyforge/editor/pf_i18n.gd")
const PfUv := preload("res://addons/polyforge/core/pf_uv.gd")
const PfUvOps := preload("res://addons/polyforge/core/pf_uvops.gd")
const PfSelect := preload("res://addons/polyforge/core/pf_select.gd")

const COL_SEL := Color(1.0, 0.55, 0.05)
const COL_PIN := Color(1.0, 0.15, 0.15)
const EPS := 1e-5

var session = null
var plugin: EditorPlugin = null
var channel := 0                 # 0 = UV1, 1 = UV2
var select_mode := "vertex"      # vertex / face / island
var sticky := "location"         # location / vertex / disabled
var on_key: Callable = Callable()   # forwards tab keys to the plugin
var sel := {}                    # Vector2i(face, corner) -> true
var cursor := Vector2.ZERO       # 2D cursor (UV space)
var pivot_mode := "bounds"       # bounds / median / cursor / individual
var snap_on := false             # Shift+Tab; Ctrl inverts while transforming
var snap_target := "pixels"      # pixels / vertex
var sync := false                # UV Sync Selection: UV selection = mesh selection

const PIVOTS := [["bounds", "Bounding Box Center"], ["median", "Median Point"], ["cursor", "2D Cursor"], ["individual", "Individual Origins"]]

var _zoom := 300.0
var _pan := Vector2.ZERO
var _dragging := false
var _box_from := Vector2.ZERO
var _box := false
var _lmb := false
var _mouse := Vector2.ZERO
var _tm := {}                    # running G/R/S
var _bar: HFlowContainer
var _pivot_btn: OptionButton
var _snap_btn: OptionButton
var _sync_btn: Button
var _cursor_drag := false


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)
	mouse_entered.connect(func():
		var fo := get_viewport().gui_get_focus_owner()
		if not (fo is LineEdit or fo is TextEdit) and not (plugin != null and plugin.ui != null and plugin.ui.any_popup_open()):
			grab_focus())
	_bar = HFlowContainer.new()
	add_child(_bar)
	_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_bar.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED   # Blender names
	var ch := OptionButton.new()
	ch.flat = true
	ch.add_item("UV1", 0)
	ch.add_item("UV2", 1)
	ch.tooltip_text = "UV channel (UV2: lightmaps / gradient palette)"
	ch.item_selected.connect(func(i): channel = i; sel.clear(); queue_redraw())
	ch.focus_mode = Control.FOCUS_NONE
	_bar.add_child(ch)
	var sm := OptionButton.new()
	sm.flat = true
	for t in ["Vertex", "Face", "Island"]:
		sm.add_item(t)
	sm.tooltip_text = "UV select mode"
	sm.item_selected.connect(func(i): select_mode = ["vertex", "face", "island"][i]; queue_redraw())
	sm.focus_mode = Control.FOCUS_NONE
	_bar.add_child(sm)
	var st := OptionButton.new()
	st.flat = true
	for t in ["Sticky: Location", "Sticky: Vertex", "Sticky: Off"]:
		st.add_item(t)
	st.tooltip_text = "Sticky selection"
	st.item_selected.connect(func(i): sticky = ["location", "vertex", "disabled"][i])
	st.focus_mode = Control.FOCUS_NONE
	_bar.add_child(st)
	_sync_btn = Button.new()
	_sync_btn.theme_type_variation = &"FlatButton"
	_sync_btn.add_theme_color_override(&"font_pressed_color", EditorInterface.get_editor_theme().get_color(&"accent_color", &"Editor"))
	_sync_btn.add_theme_color_override(&"font_hover_pressed_color", EditorInterface.get_editor_theme().get_color(&"accent_color", &"Editor"))
	_sync_btn.text = "Sync"
	_sync_btn.toggle_mode = true
	_sync_btn.tooltip_text = "UV Sync Selection: show all faces, UV selection = mesh selection"
	_sync_btn.focus_mode = Control.FOCUS_NONE
	_sync_btn.toggled.connect(set_sync)
	_bar.add_child(_sync_btn)
	_pivot_btn = OptionButton.new()
	_pivot_btn.flat = true
	for t in ["Pivot: Bounds", "Pivot: Median", "Pivot: Cursor", "Pivot: Individual"]:
		_pivot_btn.add_item(t)
	_pivot_btn.tooltip_text = "Pivot for rotate / scale (Period)"
	_pivot_btn.focus_mode = Control.FOCUS_NONE
	_pivot_btn.item_selected.connect(func(i): set_pivot(PIVOTS[i][0]))
	_bar.add_child(_pivot_btn)
	_snap_btn = OptionButton.new()
	_snap_btn.flat = true
	for t in ["Snap Off", "Snap Pixels", "Snap Vertex"]:
		_snap_btn.add_item(t)
	_snap_btn.tooltip_text = "Snapping while moving (Shift+Tab toggles, hold Ctrl to invert)"
	_snap_btn.focus_mode = Control.FOCUS_NONE
	_snap_btn.item_selected.connect(func(i):
		snap_on = i > 0
		if i > 0:
			snap_target = ["", "pixels", "vertex"][i])
	_bar.add_child(_snap_btn)
	var cp := Button.new()
	cp.theme_type_variation = &"FlatButton"
	cp.text = "UV1→UV2"
	cp.tooltip_text = "Copy UV1 to UV2 for the selected faces"
	cp.focus_mode = Control.FOCUS_NONE
	cp.pressed.connect(func(): plugin.run_action("uv_copy_to_uv2"))
	_bar.add_child(cp)
	PfI18n.localize(_bar)

func set_pivot(kind: String) -> void:
	pivot_mode = kind
	for i in PIVOTS.size():
		if PIVOTS[i][0] == kind:
			_pivot_btn.select(i)
	queue_redraw()

func set_snap(on: bool, target := "") -> void:
	snap_on = on
	if target != "":
		snap_target = target
	_snap_btn.select(0 if not snap_on else (1 if snap_target == "pixels" else 2))

func set_sync(on: bool) -> void:
	sync = on
	_sync_btn.set_pressed_no_signal(on)
	sel.clear()
	_pull_sync()
	queue_redraw()

func frame_unit() -> void:
	var top := _bar.size.y if _bar != null else 30.0
	_zoom = maxf(minf(size.x, size.y - top - 24.0) * 0.85, 50.0)
	_pan = Vector2(0, (top - 20.0) * 0.5)
	queue_redraw()

func uv_to_screen(uv: Vector2) -> Vector2:
	return size * 0.5 + _pan + (uv - Vector2(0.5, 0.5)) * _zoom

func screen_to_uv(p: Vector2) -> Vector2:
	return (p - size * 0.5 - _pan) / _zoom + Vector2(0.5, 0.5)


# ==============================================================================
# Data access
# ==============================================================================

func _mesh():
	return session.mesh if session != null and session.mesh != null else null

## Faces shown: those selected in 3D (Blender without UV Sync), or every
## visible face with UV Sync Selection.
func visible_faces() -> Dictionary:
	if session == null or session.mesh == null:
		return {}
	if sync:
		var out := {}
		for f in session.mesh.faces.size():
			if not session.is_face_hidden(f):
				out[f] = true
		return out
	return session.selected_faces()

## UV Sync: UV selection follows the mesh selection (by vertex, or by face
## in face mode) ...
func _pull_sync() -> void:
	if not sync or session == null or session.mesh == null or not _tm.is_empty():
		return
	sel.clear()
	var m = session.mesh
	if session.mode == 3:
		for f in session.selected_faces():
			for key in _face_keys(f):
				sel[key] = true
		return
	var sv: Dictionary = session.selected_verts()
	for f in visible_faces():
		var fv: PackedInt32Array = m.faces[f]
		for k in fv.size():
			if sv.has(fv[k]):
				sel[Vector2i(f, k)] = true

## ... and selecting in the UV editor selects in the mesh.
func _push_sync() -> void:
	if not sync or session == null or session.mesh == null:
		return
	var m = session.mesh
	var verts := _selected_verts()
	var elems := []
	match session.mode:
		1:
			elems = verts.keys()
		2:
			elems = PfSelect.verts_to_edges(m, verts).keys()
		3:
			var count := {}
			for key in sel:
				count[key.x] = count.get(key.x, 0) + 1
			for f in count:
				if count[f] == m.faces[f].size():
					elems.append(f)
	session.select_many(elems, "set")

func _uv(f: int) -> PackedVector2Array:
	return PfUvOps.get_uv(_mesh(), channel, f)

func _set_corner(f: int, k: int, p: Vector2) -> void:
	var u := _uv(f)
	u[k] = p
	PfUvOps.set_uv(_mesh(), channel, f, u)

func _sticky_add(key: Vector2i, faces: Dictionary, out: Dictionary) -> void:
	out[key] = true
	if sticky == "disabled":
		return
	var m = _mesh()
	var v: int = m.faces[key.x][key.y]
	var p := _uv(key.x)[key.y]
	for f in m.vert_faces(v):
		if not faces.has(f):
			continue
		var k: int = m.corner_of(f, v)
		if sticky == "vertex" or _uv(f)[k].distance_to(p) < EPS:
			out[Vector2i(f, k)] = true

func _face_keys(f: int) -> Array:
	var out := []
	for k in _mesh().faces[f].size():
		out.append(Vector2i(f, k))
	return out

func _face_selected(f: int) -> bool:
	for key in _face_keys(f):
		if not sel.has(key):
			return false
	return true

func _island_of(f: int, faces: Dictionary) -> Dictionary:
	for isl in PfUvOps.islands(_mesh(), channel, faces):
		if isl.has(f):
			return isl
	return {f: true}


# ==============================================================================
# Picking
# ==============================================================================

func _pick_corner(p: Vector2) -> Variant:
	var best = null
	var bd := 12.0
	var faces := visible_faces()
	for f in faces:
		var u := _uv(f)
		for k in u.size():
			var d := uv_to_screen(u[k]).distance_to(p)
			if d < bd:
				bd = d
				best = Vector2i(f, k)
	return best

func _pick_face(p: Vector2) -> int:
	for f in visible_faces():
		var poly := PackedVector2Array()
		for u in _uv(f):
			poly.append(uv_to_screen(u))
		if Geometry2D.is_point_in_polygon(p, poly):
			return f
	return -1

## Selection for a click at p (by select mode, sticky applied).
func _keys_at(p: Vector2) -> Dictionary:
	var out := {}
	var faces := visible_faces()
	match select_mode:
		"vertex":
			var c = _pick_corner(p)
			if c != null:
				_sticky_add(c, faces, out)
		"face", "island":
			var f := _pick_face(p)
			if f >= 0:
				var fs := {f: true} if select_mode == "face" else _island_of(f, faces)
				for g in fs:
					for key in _face_keys(g):
						out[key] = true
	return out

func _keys_in_rect(r: Rect2) -> Dictionary:
	var out := {}
	var faces := visible_faces()
	for f in faces:
		var u := _uv(f)
		if select_mode == "vertex":
			for k in u.size():
				if r.has_point(uv_to_screen(u[k])):
					_sticky_add(Vector2i(f, k), faces, out)
		else:
			var c := Vector2.ZERO
			for p in u:
				c += p
			if r.has_point(uv_to_screen(c / u.size())):
				for key in _face_keys(f):
					out[key] = true
	return out


# ==============================================================================
# Input
# ==============================================================================

func _gui_input(event: InputEvent) -> void:
	if session == null:
		return
	if event is InputEventMouse:
		_mouse = (event as InputEventMouse).position
	_pull_sync()
	if not _tm.is_empty():
		_tm_input(event)
		accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_MIDDLE:
				_dragging = mb.pressed
			MOUSE_BUTTON_RIGHT:
				_cursor_drag = mb.pressed and mb.shift_pressed
				if _cursor_drag:
					cursor = screen_to_uv(mb.position)
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					var f := 1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
					var before := screen_to_uv(mb.position)
					_zoom = clampf(_zoom * f, 20.0, 50000.0)
					_pan += mb.position - uv_to_screen(before)
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					grab_focus()
					_lmb = true
					_box = false
					_box_from = mb.position
				elif _lmb:
					_lmb = false
					if _box:
						_box = false
						var keys := _keys_in_rect(Rect2(_box_from, mb.position - _box_from).abs())
						if mb.ctrl_pressed:
							for k in keys:
								sel.erase(k)
						else:
							if not mb.shift_pressed:
								sel.clear()
							sel.merge(keys)
					else:
						var keys := _keys_at(mb.position)
						if mb.shift_pressed:
							var all_in := not keys.is_empty()
							for k in keys:
								if not sel.has(k):
									all_in = false
							for k in keys:
								if all_in:
									sel.erase(k)
								else:
									sel[k] = true
						else:
							sel = keys
					_push_sync()
		queue_redraw()
		accept_event()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging:
			_pan += mm.relative
		elif _cursor_drag:
			cursor = screen_to_uv(mm.position)
		elif _lmb and mm.position.distance_to(_box_from) > 6.0:
			_box = true
		queue_redraw()
		accept_event()
	elif event is InputEventKey and event.pressed and not event.echo:
		if _key(event as InputEventKey):
			accept_event()
			if _tm.is_empty():
				_push_sync()

func _key(k: InputEventKey) -> bool:
	var code := k.keycode
	if k.ctrl_pressed and code in [KEY_PAGEUP, KEY_PAGEDOWN]:
		return on_key.is_valid() and on_key.call(k)
	var faces := visible_faces()
	if k.shift_pressed and code == KEY_S:
		plugin.run_action("uv_snap_menu", get_screen_position() + _mouse)
		return true
	if k.shift_pressed and code == KEY_TAB:
		set_snap(not snap_on)
		return true
	match code:
		KEY_PERIOD:
			plugin.run_action("uv_pivot_menu", get_screen_position() + _mouse)
		KEY_V:
			if k.ctrl_pressed or k.alt_pressed:
				return false
			_edit("Stitch", func(): PfUvOps.stitch(_mesh(), channel, _valid_sel()))
		KEY_Y:
			sel = PfUvOps.split_selection(_mesh(), _valid_sel())
		KEY_HOME:
			frame_unit()
		KEY_A:
			if k.ctrl_pressed:
				plugin.run_action("uv_average", channel)
			elif k.alt_pressed:
				sel.clear()
			else:
				for f in faces:
					for key in _face_keys(f):
						sel[key] = true
		KEY_I:
			if not k.ctrl_pressed:
				return false
			var nu := {}
			for f in faces:
				for key in _face_keys(f):
					if not sel.has(key):
						nu[key] = true
			sel = nu
		KEY_L:
			if k.ctrl_pressed:
				var seed := {}
				for key in sel:
					seed[key.x] = true
				for isl in PfUvOps.islands(_mesh(), channel, faces):
					for f in isl:
						if seed.has(f):
							for g in isl:
								for key in _face_keys(g):
									sel[key] = true
							break
			else:
				var f := _pick_face(_mouse)
				if f < 0:
					var c = _pick_corner(_mouse)
					f = c.x if c != null else -1
				if f >= 0:
					for g in _island_of(f, faces):
						for key in _face_keys(g):
							if k.shift_pressed:
								sel.erase(key)
							else:
								sel[key] = true
		KEY_G, KEY_R, KEY_S:
			if k.ctrl_pressed or k.alt_pressed or k.shift_pressed:
				return false
			_tm_begin({KEY_G: "move", KEY_R: "rotate", KEY_S: "scale"}[code])
		KEY_P:
			if k.ctrl_pressed:
				plugin.run_action("uv_pack", channel)
			else:
				plugin.run_action("uv_pin", [not k.alt_pressed, _selected_verts()])
		KEY_U:
			plugin.run_action("uv_menu", get_screen_position() + _mouse)
		_:
			return false
	queue_redraw()
	return true

## Selected corners that still exist and are shown.
func _valid_sel() -> Dictionary:
	var out := {}
	var faces := visible_faces()
	for key in sel:
		if faces.has(key.x) and key.y < _mesh().faces[key.x].size():
			out[key] = true
	return out

## Runs `fn` as one undoable UV edit.
func _edit(label: String, fn: Callable) -> void:
	var before: Dictionary = session.snapshot()
	fn.call()
	session.commit_undo("UV " + label, before)
	queue_redraw()

## Shift+S menu entries (Blender UV Snap menu).
func snap_op(kind: String) -> void:
	var keys := _valid_sel()
	var m = _mesh()
	if m == null:
		return
	var step := _snap_step()
	match kind:
		"cursor_to_origin":
			cursor = Vector2.ZERO
		"cursor_to_pixels":
			cursor = cursor.snapped(Vector2.ONE * step)
		"cursor_to_selected":
			if not keys.is_empty():
				cursor = _bounds_of(keys).get_center()
		"selected_to_pixels":
			_edit("Snap to Pixels", func():
				for key in keys:
					_set_corner(key.x, key.y, _uv(key.x)[key.y].snapped(Vector2.ONE * step)))
		"selected_to_cursor":
			_edit("Snap to Cursor", func():
				for key in keys:
					_set_corner(key.x, key.y, cursor))
		"selected_to_cursor_offset":
			if keys.is_empty():
				return
			var d := cursor - _bounds_of(keys).get_center()
			_edit("Snap to Cursor (Offset)", func():
				for key in keys:
					_set_corner(key.x, key.y, _uv(key.x)[key.y] + d))
		"selected_to_adjacent":
			_edit("Snap to Adjacent Unselected", func():
				var faces := visible_faces()
				for key in keys:
					var v: int = m.faces[key.x][key.y]
					for f in m.vert_faces(v):
						var k2: int = m.corner_of(f, v)
						if faces.has(f) and not keys.has(Vector2i(f, k2)):
							_set_corner(key.x, key.y, _uv(f)[k2])
							break)
	queue_redraw()

func _bounds_of(keys: Dictionary) -> Rect2:
	var r := Rect2()
	var first := true
	for key in keys:
		var p := _uv(key.x)[key.y]
		r = Rect2(p, Vector2.ZERO) if first else r.expand(p)
		first = false
	return r

func _selected_verts() -> Dictionary:
	var out := {}
	for key in sel:
		if key.x < _mesh().faces.size():
			out[_mesh().faces[key.x][key.y]] = true
	return out


# ==============================================================================
# G / R / S
# ==============================================================================

func _tm_begin(mode: String) -> void:
	var keys := []
	for key in sel:
		if key.x < _mesh().faces.size() and visible_faces().has(key.x):
			keys.append(key)
	if keys.is_empty():
		return
	var orig := {}
	var c := Vector2.ZERO
	var anchor: Vector2i = keys[0]
	for key in keys:
		orig[key] = _uv(key.x)[key.y]
		c += orig[key]
		if uv_to_screen(orig[key]).distance_to(_mouse) < uv_to_screen(orig[anchor]).distance_to(_mouse):
			anchor = key
	var ks := {}
	for key in keys:
		ks[key] = true
	var main: Vector2 = _bounds_of(ks).get_center()
	match pivot_mode:
		"median": main = c / keys.size()
		"cursor": main = cursor
	var pivots := {}
	if pivot_mode == "individual":
		for isl in PfUvOps.islands(_mesh(), channel, visible_faces()):
			var part := {}
			for key in keys:
				if isl.has(key.x):
					part[key] = true
			if not part.is_empty():
				var ic := _bounds_of(part).get_center()
				for key in part:
					pivots[key] = ic
	_tm = {"mode": mode, "orig": orig, "pivot": main, "pivots": pivots, "anchor": anchor, "start": _mouse, "axis": -1,
		"numeric": "", "before": session.snapshot(), "acc": _mouse, "last": _mouse, "snap": snap_on}

func _tm_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var d: Vector2 = mm.position - _tm["last"]
		_tm["last"] = mm.position
		_tm["acc"] += d * (0.1 if mm.shift_pressed else 1.0)
		_tm["snap"] = mm.ctrl_pressed != snap_on
		_tm_apply()
	elif event is InputEventMouseButton and event.pressed:
		_tm_end(event.button_index == MOUSE_BUTTON_LEFT)
	elif event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		match k.keycode:
			KEY_ESCAPE:
				_tm_end(false)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				_tm_end(true)
			KEY_X, KEY_Y:
				var a := 0 if k.keycode == KEY_X else 1
				_tm["axis"] = -1 if _tm["axis"] == a else a
			KEY_BACKSPACE:
				var n: String = _tm["numeric"]
				_tm["numeric"] = n.substr(0, maxi(n.length() - 1, 0))
			KEY_MINUS, KEY_KP_SUBTRACT:
				var n: String = _tm["numeric"]
				_tm["numeric"] = n.substr(1) if n.begins_with("-") else "-" + n
			KEY_PERIOD, KEY_KP_PERIOD:
				if not (_tm["numeric"] as String).contains("."):
					_tm["numeric"] += "."
			KEY_G, KEY_R, KEY_S:
				_tm["mode"] = {KEY_G: "move", KEY_R: "rotate", KEY_S: "scale"}[k.keycode]
				_tm["numeric"] = ""
			_:
				if k.keycode >= KEY_0 and k.keycode <= KEY_9:
					_tm["numeric"] += str(k.keycode - KEY_0)
				elif k.keycode >= KEY_KP_0 and k.keycode <= KEY_KP_9:
					_tm["numeric"] += str(k.keycode - KEY_KP_0)
		if not _tm.is_empty():
			_tm_apply()
	queue_redraw()

func _numeric() -> Variant:
	var n: String = _tm["numeric"]
	if n.is_empty() or n in ["-", ".", "-."]:
		return null
	return n.to_float()

func _snap_step() -> float:
	var tex := _texture()
	return 1.0 / float(tex.get_width()) if tex != null else 1.0 / 64.0

func _tm_apply() -> void:
	var piv: Vector2 = _tm["pivot"]
	var ps := uv_to_screen(piv)
	var num = _numeric()
	var xf := Transform2D.IDENTITY
	match _tm["mode"]:
		"move":
			var d: Vector2 = (_tm["acc"] - _tm["start"]) / _zoom
			if num != null:
				d = Vector2(num, 0) if _tm["axis"] != 1 else Vector2(0, num)
			if _tm["axis"] == 0:
				d.y = 0.0
			elif _tm["axis"] == 1:
				d.x = 0.0
			if _tm["snap"] and num == null:
				d = _snap_move(d)
			xf = Transform2D(0.0, d)
		"rotate":
			var a: float = (_tm["start"] - ps).angle_to(_tm["acc"] - ps)
			if num != null:
				a = -deg_to_rad(num)   # Blender: positive = counter-clockwise on screen
			elif _tm["snap"]:
				a = deg_to_rad(snappedf(rad_to_deg(a), 5.0))
			xf = Transform2D(a, Vector2.ZERO)
		"scale":
			var s: float = (_tm["acc"] - ps).length() / maxf((_tm["start"] - ps).length(), 4.0)
			if num != null:
				s = num
			elif _tm["snap"]:
				s = snappedf(s, 0.1)
			var sv := Vector2(s, s)
			if _tm["axis"] == 0:
				sv.y = 1.0
			elif _tm["axis"] == 1:
				sv.x = 1.0
			xf = Transform2D(0.0, sv, 0.0, Vector2.ZERO)
	var pivots: Dictionary = _tm["pivots"]
	for key in _tm["orig"]:
		var o: Vector2 = _tm["orig"][key]
		var kp: Vector2 = pivots.get(key, piv)
		var p := kp + xf.basis_xform(o - kp) + xf.origin
		_set_corner(key.x, key.y, p)
	session.rebuild(true)
	_tm["xf"] = xf

## Snapped move: the grabbed corner (closest to the mouse at start) lands on
## the pixel grid, or on the nearest unselected UV vertex / the 2D cursor.
func _snap_move(d: Vector2) -> Vector2:
	var a: Vector2 = _tm["orig"][_tm["anchor"]]
	var target := a + d
	if snap_target == "pixels":
		var step := _snap_step()
		var t := target.snapped(Vector2.ONE * step)
		if _tm["axis"] == 0:
			t.y = target.y
		elif _tm["axis"] == 1:
			t.x = target.x
		return t - a
	var best := 15.0
	var hit = null
	var cands := [cursor]
	for f in visible_faces():
		var u := _uv(f)
		for k in u.size():
			if not _tm["orig"].has(Vector2i(f, k)):
				cands.append(u[k])
	for c in cands:
		var dd := uv_to_screen(c).distance_to(uv_to_screen(target))
		if dd < best:
			best = dd
			hit = c
	return d if hit == null else (hit as Vector2) - a

func _tm_end(ok: bool) -> void:
	var before: Dictionary = _tm["before"]
	var mode: String = _tm["mode"]
	_tm = {}
	if ok:
		session.commit_undo("UV " + mode.capitalize(), before)
	else:
		session.restore(before)
	queue_redraw()


# ==============================================================================
# Drawing
# ==============================================================================

func _draw() -> void:
	_pull_sync()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.16, 0.16, 0.17))
	var r := Rect2(uv_to_screen(Vector2.ZERO), Vector2.ONE * _zoom)
	var tex := _texture() if session != null else null
	if tex != null:
		draw_texture_rect(tex, r, false, Color(1, 1, 1, 0.9))
	else:
		draw_rect(r, Color(0.26, 0.26, 0.28))
	for i in 9:
		var t := float(i) / 8.0
		var c := Color(1, 1, 1, 0.08 if i % 4 != 0 else 0.25)
		draw_line(uv_to_screen(Vector2(t, 0)), uv_to_screen(Vector2(t, 1)), c)
		draw_line(uv_to_screen(Vector2(0, t)), uv_to_screen(Vector2(1, t)), c)
	var font := get_theme_default_font()
	var hint := PfI18n.t("U unwrap  G R S  A  L  P pin  V stitch  Y split  Shift+S snap  Shift+RMB cursor  Ctrl+P pack")
	if session != null and session.mesh != null:
		var m = session.mesh
		var faces := visible_faces()
		if faces.is_empty():
			hint = PfI18n.t("Select faces in the 3D view to edit their UVs (or turn on Sync)")
		for f in faces:
			var uv := _uv(f)
			if uv.size() < 2:
				continue
			var pts := PackedVector2Array()
			for u in uv:
				pts.append(uv_to_screen(u))
			if _face_selected(f):
				draw_colored_polygon(pts, Color(COL_SEL, 0.18))
			var loop := pts.duplicate()
			loop.append(pts[0])
			draw_polyline(loop, Color(0.9, 0.9, 0.9, 0.85), 1.0, true)
		for f in faces:
			var uv := _uv(f)
			for k in uv.size():
				var key := Vector2i(f, k)
				var pinned: bool = m.uv_pins.has(m.faces[f][k])
				var col := COL_PIN if pinned else (COL_SEL if sel.has(key) else Color(0.1, 0.1, 0.1))
				draw_rect(Rect2(uv_to_screen(uv[k]) - Vector2(2.5, 2.5), Vector2(5, 5)), col)
	var cp := uv_to_screen(cursor)
	draw_arc(cp, 7.0, 0.0, TAU, 24, Color(1, 0.2, 0.2), 1.5, true)
	draw_line(cp - Vector2(11, 0), cp - Vector2(4, 0), Color.BLACK)
	draw_line(cp + Vector2(4, 0), cp + Vector2(11, 0), Color.BLACK)
	draw_line(cp - Vector2(0, 11), cp - Vector2(0, 4), Color.BLACK)
	draw_line(cp + Vector2(0, 4), cp + Vector2(0, 11), Color.BLACK)
	if _box:
		var br := Rect2(_box_from, _mouse - _box_from).abs()
		draw_rect(br, Color(1, 1, 1, 0.08))
		draw_rect(br, Color(1, 1, 1, 0.8), false)
	if not _tm.is_empty():
		var txt := "UV %s  %s" % [PfI18n.t((_tm["mode"] as String).capitalize()), ("[%s|]" % _tm["numeric"]) if _tm["numeric"] != "" else ""]
		if _tm["axis"] >= 0:
			txt += PfI18n.t("  along %s") % ["U", "V"][_tm["axis"]]
		draw_string(font, Vector2(8, 50), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	draw_string(font, Vector2(8, size.y - 8), hint, HORIZONTAL_ALIGNMENT_LEFT, size.x - 16, 12, Color(1, 1, 1, 0.7))
	if session != null and plugin != null:
		var w := float(plugin.settings.get_pref("frame_width"))
		if _bar.offset_top != w:
			_bar.offset_left = w
			_bar.offset_top = w
			_bar.offset_right = -w
		# One outer frame with the 3D view: no right edge, top/bottom run across the split gap.
		var col: Color = plugin.settings.get_pref("frame_color")
		draw_rect(Rect2(0, 0, w, size.y), col)
		draw_rect(Rect2(0, 0, size.x, w), col)
		draw_rect(Rect2(0, size.y - w, size.x, w), col)
	_update_gap_host()

## The split gap between this panel and the 3D view belongs to their common
## ancestor: the frame's top / bottom edges are drawn there too (one outer frame).
var _gap_host: Control = null

func _update_gap_host() -> void:
	var vpc := EditorInterface.get_editor_viewport_3d(0).get_parent() as Control
	var a := get_parent() as Control
	while a != null and vpc != null and not a.is_ancestor_of(vpc):
		a = a.get_parent() as Control
	if a != _gap_host:
		if _gap_host != null and is_instance_valid(_gap_host) and _gap_host.draw.is_connected(_draw_gap):
			_gap_host.draw.disconnect(_draw_gap)
		_gap_host = a
		if a != null:
			a.draw.connect(_draw_gap)
	if _gap_host != null:
		_gap_host.queue_redraw()

func _draw_gap() -> void:
	if session == null or plugin == null or not is_visible_in_tree():
		return
	var vpc := EditorInterface.get_editor_viewport_3d(0).get_parent() as Control
	if vpc == null:
		return
	var w := float(plugin.settings.get_pref("frame_width"))
	var col: Color = plugin.settings.get_pref("frame_color")
	var inv := _gap_host.get_global_transform().affine_inverse()
	var a: Vector2 = inv * get_global_rect().position
	var x0 := a.x + size.x
	var x1: float = (inv * vpc.get_global_rect().position).x
	if x1 > x0:
		_gap_host.draw_rect(Rect2(x0, a.y, x1 - x0, w), col)
		_gap_host.draw_rect(Rect2(x0, a.y + size.y - w, x1 - x0, w), col)

func _texture() -> Texture2D:
	var m = session.mesh
	var slot := 0
	var act = session.active()
	if session.mode == 3 and act != null and act < m.faces.size():
		slot = m.face_mat[act]
	var mat: Material = m.materials[slot] if slot < m.materials.size() else null
	if mat == null and session.node is MeshInstance3D and (session.node as MeshInstance3D).get_surface_override_material_count() > 0:
		mat = (session.node as MeshInstance3D).get_surface_override_material(0)
	if channel == 1:
		if mat is ShaderMaterial and (mat as ShaderMaterial).get_shader_parameter("gradient_texture") is Texture2D:
			return (mat as ShaderMaterial).get_shader_parameter("gradient_texture")
		if mat is BaseMaterial3D and (mat as BaseMaterial3D).detail_enabled and (mat as BaseMaterial3D).detail_uv_layer == BaseMaterial3D.DETAIL_UV_2:
			return (mat as BaseMaterial3D).detail_albedo
		return null
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).albedo_texture
	if mat is ShaderMaterial:
		for p in ["albedo_texture", "texture_albedo"]:
			var t = (mat as ShaderMaterial).get_shader_parameter(p)
			if t is Texture2D:
				return t
	return null

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _gap_host != null and is_instance_valid(_gap_host):
		_gap_host.queue_redraw()
	elif what == NOTIFICATION_EXIT_TREE and _gap_host != null and is_instance_valid(_gap_host):
		if _gap_host.draw.is_connected(_draw_gap):
			_gap_host.draw.disconnect(_draw_gap)
		_gap_host.queue_redraw()
		_gap_host = null
