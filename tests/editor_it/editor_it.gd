## Polyforge editor integration test: drives the real plugin inside a
## headless editor with synthetic viewport input. Run by tests/run_tests.sh in
## a temporary copy of the project (your scenes and settings are untouched).
@tool
extends EditorPlugin

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfUv := preload("res://addons/polyforge/core/pf_uv.gd")
const PfSettings := preload("res://addons/polyforge/editor/pf_settings.gd")

const STOP := EditorPlugin.AFTER_GUI_INPUT_STOP
const PASS := EditorPlugin.AFTER_GUI_INPUT_PASS

var failures := 0
var pf: EditorPlugin = null
var cam: Camera3D = null
var vp: SubViewport = null

func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		failures += 1

func _enter_tree() -> void:
	_run.call_deferred()

func frames(n := 3) -> void:
	for i in n:
		await get_tree().process_frame

func send(ev: InputEvent) -> int:
	return pf._forward_3d_gui_input(cam, ev)

func key(code: Key, shift := false, ctrl := false, alt := false) -> int:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	ev.shift_pressed = shift
	ev.ctrl_pressed = ctrl
	ev.alt_pressed = alt
	var r := send(ev)
	var up := ev.duplicate()
	up.pressed = false
	send(up)
	return r

func move(pos: Vector2, shift := false, ctrl := false) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.shift_pressed = shift
	ev.ctrl_pressed = ctrl
	send(ev)

func button(b: MouseButton, pos: Vector2, pressed: bool, shift := false, ctrl := false, alt := false) -> int:
	var ev := InputEventMouseButton.new()
	ev.button_index = b
	ev.position = pos
	ev.pressed = pressed
	ev.shift_pressed = shift
	ev.ctrl_pressed = ctrl
	ev.alt_pressed = alt
	return send(ev)

func click(pos: Vector2, shift := false, ctrl := false, alt := false) -> void:
	move(pos)
	button(MOUSE_BUTTON_LEFT, pos, true, shift, ctrl, alt)
	button(MOUSE_BUTTON_LEFT, pos, false, shift, ctrl, alt)

func drag(a: Vector2, b: Vector2, shift := false, ctrl := false) -> void:
	move(a)
	button(MOUSE_BUTTON_LEFT, a, true, shift, ctrl)
	for i in range(1, 6):
		move(a.lerp(b, i / 5.0), shift, ctrl)
	button(MOUSE_BUTTON_LEFT, b, false, shift, ctrl)

func type_number(s: String) -> void:
	for ch in s:
		if ch == ".":
			key(KEY_PERIOD)
		elif ch == "-":
			key(KEY_MINUS)
		else:
			key(KEY_0 + int(ch))

func select(node: Node) -> void:
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(node)
	await frames()

func history_for(node: Object) -> UndoRedo:
	var ur := get_undo_redo()
	return ur.get_history_undo_redo(ur.get_object_history_id(node))

func undo(node: Object) -> void:
	history_for(node).undo()
	await frames()

func look(from: Vector3, at: Vector3) -> void:
	cam.global_transform = Transform3D(Basis.looking_at(at - from, Vector3.UP if absf((at - from).normalized().y) < 0.99 else Vector3.FORWARD), from)

func screen(node: Node3D, local: Vector3) -> Vector2:
	return cam.unproject_position(node.global_transform * local)

func verts() -> PackedVector3Array:
	return pf.session.mesh.verts.duplicate()

func _run() -> void:
	await frames(10)
	for n in get_tree().root.find_children("*", "EditorPlugin", true, false):
		if n.get_script() != null and n.get_script().resource_path == "res://addons/polyforge/plugin.gd":
			pf = n
	check(pf != null, "Polyforge plugin instance found")
	if pf == null:
		return _finish()
	# Never write the user's editor config from tests.
	pf.settings = PfSettings.new("user://pf_test_prefs.cfg")
	EditorInterface.open_scene_from_path("res://test_scene.tscn")
	await frames(10)
	var root := EditorInterface.get_edited_scene_root()
	check(root != null and root.name == "TestScene", "test scene opened")
	vp = EditorInterface.get_editor_viewport_3d(0)
	cam = vp.get_camera_3d()
	print("  viewport size: ", vp.size)
	var cube: MeshInstance3D = root.get_node("Cube")

	await _test_real_tab_focus(cube)
	await _test_enter_and_keys(cube)
	await _test_click_select(cube)
	await _test_box_select(cube)
	await _test_transforms(cube)
	await _test_orientation_and_gizmo(cube)
	await _test_uv_modes(cube)
	await _test_hide_reveal(cube)
	await _test_modeling(cube)
	await _test_modeling_2b(cube)
	await _test_uv_editor(cube)
	await _test_tabs_and_menus(cube)
	await _test_key_blocking(cube)
	await _test_add_and_loops(root)
	await _test_convert_godot_box(root)
	await _test_multi_edit(root)
	await _test_join_boolean_objects(root)
	await _test_collision_shapes(root)
	await _test_stage4(root)
	await _test_stage4b(root)
	await _test_local_view(root, cube)
	await _test_exit_and_save(root, cube)
	_finish()


## Real key dispatch (Input.parse_input_event): Tab must keep working in and
## out of Edit Mode without clicking the viewport again (keyboard focus).
func _real_key(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await frames(2)
	await frames(6)

func _test_real_tab_focus(cube: MeshInstance3D) -> void:
	print("== Tab in / out / in with real key events, no clicks in between")
	await select(cube)
	var surface: Control = pf._viewport_surface(cam)
	check(surface != null, "found the 3D viewport surface control")
	if surface == null:
		return
	surface.grab_focus()
	await frames()
	await _real_key(KEY_TAB)
	check(pf.session != null, "Tab -> Edit Mode")
	await _real_key(KEY_TAB)
	check(pf.session == null, "Tab again -> Object Mode (no click needed)")
	await _real_key(KEY_TAB)
	check(pf.session != null, "Tab again -> Edit Mode (no click needed)")
	await _real_key(KEY_TAB)
	check(pf.session == null, "and back to Object Mode")

func _test_enter_and_keys(cube: MeshInstance3D) -> void:
	print("== Tab enters Edit Mode, 1/2/3, A / Alt+A / Ctrl+I")
	await select(cube)
	look(Vector3(0, 1, 8), Vector3(0, 1, 0))
	check(pf.session == null, "starts in Object Mode")
	check(key(KEY_TAB) == STOP, "Tab consumed")
	check(pf.session != null and pf.session.node == cube, "Tab -> Edit Mode on the cube")
	check(pf.ui.edit_bar.visible, "Edit Mode bar (tabs, modes) visible")
	check(cube.has_meta("_edit_lock_"), "node locked while editing (hides Godot's transform gizmo)")
	key(KEY_1)
	check(pf.session.mode == 1, "1 -> vertex mode")
	key(KEY_A)
	check(pf.session.selected_verts().size() == 8, "A selects all 8 vertices")
	key(KEY_A, false, false, true)
	check(pf.session.selected_verts().is_empty(), "Alt+A deselects")
	key(KEY_I, false, true)
	check(pf.session.selected_verts().size() == 8, "Ctrl+I inverts (all)")
	key(KEY_2)
	check(pf.session.mode == 2 and pf.session.sel_e.size() == 12, "2 -> edge mode keeps the 12 edges")
	key(KEY_3)
	check(pf.session.mode == 3 and pf.session.sel_f.size() == 6, "3 -> face mode keeps the 6 faces")
	key(KEY_1)
	key(KEY_A, false, false, true)


func _test_click_select(cube: MeshInstance3D) -> void:
	print("== click / Shift+click / occlusion / X-Ray")
	look(Vector3(0, 1, 8), Vector3(0, 1, 0))
	var m = pf.session.mesh
	var front := []
	var back := []
	for v in m.verts.size():
		(front if m.verts[v].z > 0 else back).append(v)
	var a: int = front[0]
	var b: int = front[1]
	click(screen(cube, m.verts[a]))
	check(pf.session.sel_v.keys() == [a] and pf.session.active() == a, "click selects one vertex (active)")
	click(screen(cube, m.verts[b]), true)
	check(pf.session.sel_v.size() == 2 and pf.session.active() == b, "Shift+click adds and makes active")
	click(screen(cube, m.verts[b]), true)
	check(pf.session.sel_v.size() == 1, "Shift+click on the active vertex deselects it")
	await undo(cube)
	check(pf.session.sel_v.size() == 2, "Ctrl+Z restores the previous selection")
	click(Vector2(5, 5))
	check(pf.session.sel_v.is_empty(), "click on empty space deselects all")
	# A vertex hidden behind the cube (diagonal view) is not pickable
	# without X-Ray.
	look(Vector3(3, 4, 6), Vector3(0, 1, 0))
	await frames()
	var PfPicking := preload("res://addons/polyforge/editor/pf_picking.gd")
	var bv := -1
	for v in m.verts.size():
		var sp := screen(cube, m.verts[v])
		var vis := PfPicking._visible(pf.session, cam, m.verts[v], sp)
		var clear := true
		for w in m.verts.size():
			if w != v and screen(cube, m.verts[w]).distance_to(sp) < 25.0:
				clear = false
		if not vis and clear:
			bv = v
	check(bv >= 0, "found a vertex hidden behind the cube")
	if bv >= 0:
		var bs := screen(cube, m.verts[bv])
		click(bs)
		check(pf.session.sel_v.is_empty(), "occluded vertex is not pickable")
		key(KEY_Z, false, false, true)
		check(pf.session.xray, "Alt+Z toggles X-Ray")
		click(bs)
		check(pf.session.sel_v.keys() == [bv], "with X-Ray the hidden vertex is pickable")
		key(KEY_Z, false, false, true)
	look(Vector3(0, 1, 8), Vector3(0, 1, 0))
	key(KEY_A, false, false, true)


func _test_box_select(cube: MeshInstance3D) -> void:
	print("== box select (LMB drag, B) respects occlusion")
	look(Vector3(0, 1, 8), Vector3(0, 1, 0))
	var size := Vector2(vp.size)
	drag(Vector2(2, 2), size - Vector2(2, 2))
	check(pf.session.sel_v.size() == 4, "LMB drag box: only the 4 visible front vertices (got %d)" % pf.session.sel_v.size())
	key(KEY_A, false, false, true)
	pf.session.xray = true
	drag(Vector2(2, 2), size - Vector2(2, 2))
	check(pf.session.sel_v.size() == 8, "with X-Ray: all 8")
	pf.session.xray = false
	key(KEY_A, false, false, true)
	key(KEY_B)
	check(pf._region == "box", "B starts box select")
	move(Vector2(2, 2))
	button(MOUSE_BUTTON_LEFT, Vector2(2, 2), true)
	move(size * 0.5)
	move(size - Vector2(2, 2))
	button(MOUSE_BUTTON_LEFT, size - Vector2(2, 2), false)
	check(pf._region == "" and pf.session.sel_v.size() == 4, "B + drag selects, then ends")
	key(KEY_C)
	check(pf._region == "circle", "C starts circle select")
	var center := screen(cube, Vector3(0, 0, 1))
	move(center)
	button(MOUSE_BUTTON_MIDDLE, center, true)
	button(MOUSE_BUTTON_MIDDLE, center, false)
	key(KEY_ESCAPE)
	check(pf._region == "", "Esc ends circle select")
	key(KEY_A, false, false, true)


func _test_transforms(cube: MeshInstance3D) -> void:
	print("== modal G / R / S with numeric input, undo")
	look(Vector3(0, 1, 8), Vector3(0, 1, 0))
	var center := Vector2(vp.size) * 0.5
	key(KEY_A)
	var p0 := verts()
	move(center)
	key(KEY_G)
	check(pf.modal.active, "G starts grab")
	key(KEY_X)
	type_number("1")
	key(KEY_ENTER)
	check(not pf.modal.active, "Enter confirms")
	var ok := true
	var p1 := verts()
	for i in p0.size():
		if not (p1[i] - p0[i]).is_equal_approx(Vector3(1, 0, 0)):
			ok = false
	check(ok, "G X 1: every vertex moved +1 on X")
	await undo(cube)
	check(verts() == p0, "Ctrl+Z restores")
	move(center)
	key(KEY_R)
	key(KEY_Y)
	type_number("90")
	key(KEY_ENTER)
	var bb := AABB(pf.session.mesh.verts[0], Vector3.ZERO)
	for p in pf.session.mesh.verts:
		bb = bb.expand(p)
	check(bb.size.is_equal_approx(Vector3(2, 2, 2)) and not verts().is_empty(), "R Y 90 keeps a 2 m cube")
	await undo(cube)
	move(center)
	key(KEY_S)
	type_number("2")
	key(KEY_ENTER)
	check(pf.session.mesh.bounds().size.is_equal_approx(Vector3(4, 4, 4)), "S 2 doubles the cube")
	await undo(cube)
	check(verts() == p0, "undo after S")
	# Mouse-driven move with cancel.
	move(center)
	key(KEY_G)
	move(center + Vector2(80, 0))
	check(verts() != p0, "mouse moves vertices live")
	button(MOUSE_BUTTON_RIGHT, center + Vector2(80, 0), true)
	check(not pf.modal.active and verts() == p0, "RMB cancels and restores")
	# Individual Origins: top and bottom faces (not connected) scale about
	# their own centres.
	key(KEY_3)
	var mm = pf.session.mesh
	var tb := []
	for fi in mm.faces.size():
		if absf(mm.face_normal(fi).y) > 0.9:
			tb.append(fi)
	pf.session.select_many(tb, "set")
	pf.run_action("pivot", "individual")
	move(center)
	key(KEY_S)
	type_number("0.5")
	key(KEY_ENTER)
	var ys := {}
	var max_x := 0.0
	for p in pf.session.mesh.verts:
		ys[snappedf(p.y, 0.001)] = true
		max_x = maxf(max_x, absf(p.x))
	check(ys.size() == 2 and is_equal_approx(max_x, 0.5), "Individual Origins: top/bottom faces shrink in place (y kept, half width)")
	await undo(cube)
	pf.run_action("pivot", "median")
	key(KEY_1)
	key(KEY_A, false, false, true)
	# G G vertex slide.
	var m = pf.session.mesh
	var v0 := -1
	for v in m.verts.size():
		if m.verts[v].is_equal_approx(Vector3(1, 1, 1)):
			v0 = v
	click(screen(cube, m.verts[v0]))
	move(screen(cube, m.verts[v0]))
	key(KEY_G)
	key(KEY_G)
	check(pf.modal.mode == 3, "G G -> vertex slide")
	type_number("0.5")
	key(KEY_ENTER)
	var moved: Vector3 = pf.session.mesh.verts[v0]
	check(moved.distance_to(Vector3(1, 1, 1)) > 0.9 and moved.distance_to(Vector3(1, 1, 1)) < 1.1, "slide 0.5 moves half an edge (1 m)")
	await undo(cube)
	key(KEY_A, false, false, true)


func _handle(id: String) -> Dictionary:
	for h in pf.gizmo.handles(cam, pf._gizmo_origin(), pf.orient_basis()):
		if h["id"] == id:
			return h
	return {}

func _gizmo_drag(from: Vector2, to: Vector2) -> void:
	move(from)
	button(MOUSE_BUTTON_LEFT, from, true)
	for i in range(1, 7):
		move(from.lerp(to, i / 6.0))
	button(MOUSE_BUTTON_LEFT, to, false)

func _test_orientation_and_gizmo(cube: MeshInstance3D) -> void:
	print("== Transform Orientation (Normal, second press = Global) and the optional gizmo")
	look(Vector3(4, 3, 6), Vector3(0, 1, 0))
	var center := Vector2(vp.size) * 0.5
	key(KEY_3)
	var m = pf.session.mesh
	var fx := -1
	for fi in m.faces.size():
		if m.face_normal(fi).is_equal_approx(Vector3.RIGHT):
			fx = fi
	pf.session.select_many([fx], "set")
	pf.run_action("orientation", "normal")
	check(pf.orient_basis().z.is_equal_approx(Vector3.RIGHT), "Normal orientation of the +X face: Z = +X")
	var p0 := verts()
	move(center)
	key(KEY_G)
	key(KEY_Z)
	type_number("0.5")
	key(KEY_ENTER)
	var d := (pf.session.mesh.bounds() as AABB).size
	check(d.is_equal_approx(Vector3(2.5, 2, 2)), "G Z 0.5 with Normal: the face moves along its normal (world X)")
	await undo(cube)
	move(center)
	key(KEY_G)
	key(KEY_Z)
	key(KEY_Z)
	type_number("0.5")
	key(KEY_ENTER)
	check(pf.session.mesh.bounds().size.is_equal_approx(Vector3(2, 2, 2.5)), "G Z Z: second press = Global Z (face sheared along Z)")
	await undo(cube)
	check(verts() == p0, "undo")
	pf.run_action("orientation", "global")
	key(KEY_1)
	# --- gizmo ---
	check(not pf.gizmo.enabled(), "gizmo off by default")
	key(KEY_QUOTELEFT, false, true)
	check(pf.gizmo.show_move, "Ctrl+` turns the (move) gizmo on")
	key(KEY_A)
	var h := _handle("move_0")
	check(not h.is_empty(), "X arrow handle on screen")
	if not h.is_empty():
		var a: Vector2 = h["pts"][0]
		var b: Vector2 = h["pts"][1]
		var grab := a.lerp(b, 0.8)
		var dir := (b - a).normalized()
		_gizmo_drag(grab, grab + dir * 60.0)
		check(not pf.modal.active, "releasing the handle confirms")
		var dv := verts()
		var only_x := true
		var moved_x := 0.0
		for i in dv.size():
			var dd := dv[i] - p0[i]
			if not is_zero_approx(dd.y) or not is_zero_approx(dd.z):
				only_x = false
			moved_x = dd.x
		check(only_x and moved_x > 0.05, "dragging the X arrow moves only along X (+%.3f)" % moved_x)
		await undo(cube)
	var ph := _handle("plane_1")
	if not ph.is_empty():
		var c := Vector2.ZERO
		for q in ph["rect"]:
			c += q
		c /= 4.0
		_gizmo_drag(c, c + Vector2(40, 25))
		var dv := verts()
		var y_kept := true
		for i in dv.size():
			if not is_equal_approx(dv[i].y, p0[i].y):
				y_kept = false
		check(y_kept and dv != p0, "XZ plane square: moves in the plane, Y unchanged")
		await undo(cube)
	else:
		check(false, "XZ plane handle on screen")
	pf.run_action("gizmo_set", ["move", false])
	pf.run_action("gizmo_set", ["rotate", true])
	var rh := _handle("rot_1")
	check(not rh.is_empty(), "Y rotation ring on screen")
	if not rh.is_empty():
		var pts: PackedVector2Array = rh["pts"]
		var i0 := 0
		for i in pts.size():
			if pts[i].distance_to(center) > pts[i0].distance_to(center):
				i0 = i
		var g0 := pts[i0]
		var g1 := pts[(i0 + 6) % pts.size()]
		_gizmo_drag(g0, g1)
		var dv := verts()
		var y_kept := true
		for i in dv.size():
			if not is_equal_approx(dv[i].y, p0[i].y):
				y_kept = false
		check(y_kept and dv != p0, "dragging the Y ring rotates about Y")
		await undo(cube)
	pf.run_action("gizmo_set", ["rotate", false])
	check(not pf.gizmo.enabled() and bool(pf.settings.get_pref("gizmo_rotate")) == false, "gizmo off again (saved in prefs)")
	# With the gizmo off, a click where the arrow was selects normally.
	key(KEY_A, false, false, true)
	look(Vector3(0, 1, 8), Vector3(0, 1, 0))

func _test_uv_modes(cube: MeshInstance3D) -> void:
	print("== UV: Blender default vs Correct Face Attributes vs World-Scale UV")
	var center := Vector2(vp.size) * 0.5
	var m = pf.session.mesh
	var uv0: Array = m.uvs.duplicate(true)
	key(KEY_A)
	move(center)
	key(KEY_S)
	type_number("2")
	key(KEY_ENTER)
	check(pf.session.mesh.uvs == uv0, "default (Blender): S 2 keeps UVs -> texture scales with the mesh")
	await undo(cube)
	pf.run_action("world_uv", true)
	m = pf.session.mesh
	check(m.world_uv, "World-Scale UV on (projected)")
	var d0 := PfUv.measured_uv_per_metre(m, 0)
	check(is_equal_approx(d0, 1.0), "256 px/m on a 256 px (default) texture = 1 UV per metre (%.3f)" % d0)
	key(KEY_A)
	move(center)
	key(KEY_S)
	type_number("2")
	key(KEY_ENTER)
	check(is_equal_approx(PfUv.measured_uv_per_metre(pf.session.mesh, 0), d0), "World-Scale: S 2 keeps the texel density")
	await undo(cube)
	pf.run_action("texel_density", 512.0)
	check(is_equal_approx(PfUv.measured_uv_per_metre(pf.session.mesh, 0), 2.0), "Texel density 512 px/m -> 2 UV per metre")
	await undo(cube)
	await undo(cube)
	check(not pf.session.mesh.world_uv and pf.session.mesh.uvs == uv0, "undo back to Blender UVs")
	# Correct Face Attributes: moving one edge keeps the density of its faces.
	pf.run_action("correct_face_attributes", true)
	key(KEY_A, false, false, true)
	m = pf.session.mesh
	var top := -1
	for fi in m.faces.size():
		if m.face_normal(fi).is_equal_approx(Vector3.UP):
			top = fi
	var dt := PfUv.measured_uv_per_metre(m, top)
	var sel := []
	for v in m.verts.size():
		if m.verts[v].y > 0 and m.verts[v].z > 0:
			sel.append(v)
	pf.session.select_many(sel, "set")
	move(center)
	key(KEY_G)
	key(KEY_Z)
	type_number("1")
	key(KEY_ENTER)
	check(is_equal_approx(PfUv.measured_uv_per_metre(pf.session.mesh, top), dt), "Correct Face Attributes: moved edge does not stretch the top face")
	await undo(cube)
	pf.run_action("correct_face_attributes", false)
	key(KEY_A, false, false, true)


func _test_hide_reveal(cube: MeshInstance3D) -> void:
	print("== H / Shift+H / Alt+H")
	key(KEY_3)
	var m = pf.session.mesh
	pf.session.select_many([0], "set")
	key(KEY_H)
	check(pf.session.is_face_hidden(0) and pf.session.sel_f.is_empty(), "H hides the selected face")
	check(pf.session.has_display_override(), "hidden face removed from the viewport display only")
	check((cube.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() == 36, "real mesh still has all 6 faces")
	key(KEY_A)
	check(pf.session.sel_f.size() == 5, "A ignores hidden faces")
	key(KEY_H, false, false, true)
	check(not pf.session.is_face_hidden(0) and pf.session.sel_f.has(0), "Alt+H reveals and selects the revealed face")
	check(not pf.session.has_display_override(), "display back to the real mesh")
	key(KEY_A, false, false, true)
	pf.session.select_many([0], "set")
	key(KEY_H, true)
	var hidden := 0
	for fi in m.faces.size():
		if pf.session.is_face_hidden(fi):
			hidden += 1
	check(hidden == 5, "Shift+H hides the 5 unselected faces")
	key(KEY_H, false, false, true)
	key(KEY_A, false, false, true)
	key(KEY_1)


func _face_n(n: Vector3) -> int:
	var m = pf.session.mesh
	for fi in m.faces.size():
		if m.face_normal(fi).is_equal_approx(n):
			return fi
	return -1

func _counts() -> Vector2i:
	return Vector2i(pf.session.mesh.verts.size(), pf.session.mesh.faces.size())

func _test_modeling(cube: MeshInstance3D) -> void:
	print("== modeling: E / I / Alt+S / Shift+D / X / Ctrl+X / M / F / normals / F3")
	look(Vector3(3, 4, 6), Vector3(0, 1, 0))
	var center := Vector2(vp.size) * 0.5
	pf.session.set_mode(3)
	pf.session.select_many([_face_n(Vector3.UP)], "set")
	move(center)
	key(KEY_E)
	check(pf.modal.active and pf.modal.constraint == 1 and pf.modal.axis == 2, "E: extrude, moving along the face normal")
	type_number("1")
	key(KEY_ENTER)
	check(_counts() == Vector2i(12, 10) and pf.session.mesh.bounds().size.is_equal_approx(Vector3(2, 3, 2)), "E 1 Enter: top extruded by 1 m (12 verts, 10 faces)")
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "one Ctrl+Z undoes Extrude and Move")
	pf.session.select_many([_face_n(Vector3.UP)], "set")
	move(center)
	key(KEY_E)
	button(MOUSE_BUTTON_RIGHT, center, true)
	check(_counts() == Vector2i(12, 10) and pf.session.mesh.bounds().size.is_equal_approx(Vector3(2, 2, 2)), "E then RMB: extrusion stays in place (Blender)")
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "Ctrl+Z removes it")
	# Inset
	pf.session.select_many([_face_n(Vector3.UP)], "set")
	move(center)
	key(KEY_I)
	check(pf.vmodal.active, "I: inset modal")
	type_number("0.25")
	key(KEY_ENTER)
	check(_counts() == Vector2i(12, 10), "I 0.25 Enter: inset top face")
	var ok := true
	for p in pf.session.mesh.verts:
		if p.y > 0.99 and not (is_equal_approx(absf(p.x), 1.0) or is_equal_approx(absf(p.x), 0.75)):
			ok = false
	check(ok, "inner loop 0.25 m from the edges")
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "undo inset")
	pf.session.select_many([_face_n(Vector3.UP), _face_n(Vector3.BACK)], "set")
	move(center)
	key(KEY_I)
	key(KEY_I)
	type_number("0.2")
	key(KEY_ENTER)
	check(_counts() == Vector2i(16, 14), "I I: individual inset of two faces (8 new verts)")
	await undo(cube)
	key(KEY_I)
	key(KEY_ESCAPE)
	check(_counts() == Vector2i(8, 6) and not pf.vmodal.active, "Esc cancels the inset completely")
	# Shrink/Fatten
	pf.session.select_all()
	move(center)
	key(KEY_S, false, false, true)
	type_number("0.5")
	key(KEY_ENTER)
	var exp := 2.0 + 2.0 * 0.5 / sqrt(3.0)   # corners move along the averaged normal
	check(pf.session.mesh.bounds().size.is_equal_approx(Vector3.ONE * exp), "Alt+S 0.5: vertices pushed out along their normals (%s)" % pf.session.mesh.bounds().size)
	await undo(cube)
	# Duplicate
	move(center)
	key(KEY_D, true)
	check(pf.modal.active and _counts() == Vector2i(16, 12), "Shift+D: copy made, moving")
	key(KEY_X)
	type_number("3")
	key(KEY_ENTER)
	check(pf.session.mesh.bounds().size.is_equal_approx(Vector3(5, 2, 2)), "Shift+D X 3: copy 3 m along X")
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "one undo removes the duplicate")
	# Delete menu / dissolve / merge / fill
	pf.session.deselect_all()
	pf.session.select_many([_face_n(Vector3.UP)], "set")
	key(KEY_X)
	await frames()
	check(pf.ui.op_menu.visible, "X opens the Delete menu")
	pf.ui.op_menu.hide()
	pf.run_action("delete", "only_faces")
	check(_counts() == Vector2i(8, 5), "Delete > Only Faces: hole, edges kept")
	pf.session.set_mode(1)
	var tv := []
	for v in pf.session.mesh.verts.size():
		if pf.session.mesh.verts[v].y > 0:
			tv.append(v)
	pf.session.select_many(tv, "set")
	key(KEY_F)
	check(_counts() == Vector2i(8, 6), "F fills the hole again")
	var vol := 0.0
	var mm = pf.session.mesh
	for fi in mm.faces.size():
		var f: PackedInt32Array = mm.faces[fi]
		for k in range(1, f.size() - 1):
			vol += mm.verts[f[0]].dot(mm.verts[f[k]].cross(mm.verts[f[k + 1]])) / 6.0
	check(vol > 0.0, "new face oriented outward")
	await undo(cube)
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "undo F and Delete")
	pf.session.set_mode(3)
	pf.session.select_many([_face_n(Vector3.UP), _face_n(Vector3.BACK)], "set")
	key(KEY_X, false, true)
	check(_counts() == Vector2i(8, 5), "Ctrl+X dissolves two faces into one")
	await undo(cube)
	pf.session.set_mode(1)
	pf.session.select_many(tv, "set")
	key(KEY_M)
	await frames()
	check(pf.ui.op_menu.visible, "M opens the Merge menu")
	pf.ui.op_menu.hide()
	pf.run_action("merge", ["center"])
	check(_counts() == Vector2i(5, 5), "Merge at Center: pyramid")
	await undo(cube)
	# Triangulate / Tris to Quads / normals
	pf.session.set_mode(3)
	pf.session.select_all()
	key(KEY_T, false, true)
	check(_counts().y == 12, "Ctrl+T triangulates (%s, sel %d, mode %d, msg %s)" % [_counts(), pf.session.sel_f.size(), pf.session.mode, pf._message])
	pf.session.select_all()
	key(KEY_J, false, false, true)
	check(_counts().y == 6, "Alt+J joins back to quads")
	await undo(cube)
	await undo(cube)
	pf.session.select_many([0], "set")
	pf.run_action("flip")
	pf.session.select_all()
	key(KEY_N, true)
	vol = 0.0
	mm = pf.session.mesh
	for fi in mm.faces.size():
		var f: PackedInt32Array = mm.faces[fi]
		for k in range(1, f.size() - 1):
			vol += mm.verts[f[0]].dot(mm.verts[f[k]].cross(mm.verts[f[k + 1]])) / 6.0
	check(vol > 0.0, "Shift+N recalculates the flipped face outward")
	await undo(cube)
	await undo(cube)
	key(KEY_F3)
	await frames()
	check(pf.ui.search_popup.visible, "F3 opens the operator search")
	pf.ui.search_popup.hide()
	pf.session.deselect_all()
	pf.session.set_mode(1)
	check(_counts() == Vector2i(8, 6), "cube back to the start (%s)" % _counts())

func _closed_now() -> bool:
	var m = pf.session.mesh
	m.ensure_topology()
	for e in m.edges():
		if m.edge_faces(e).size() != 2:
			return false
	return true

func _test_modeling_2b(cube: MeshInstance3D) -> void:
	print("== modeling 2B: J / Ctrl+R / Ctrl+B / Ctrl+Shift+B / P / Boolean / Focus")
	look(Vector3(3, 4, 6), Vector3(0, 1, 0))
	var center := Vector2(vp.size) * 0.5
	var m = pf.session.mesh
	pf.session.set_mode(1)
	pf.session.deselect_all()
	var top := _face_n(Vector3.UP)
	var tf: PackedInt32Array = m.faces[top]
	pf.session.click_select(tf[0], false)
	pf.session.click_select(tf[2], true)
	key(KEY_J)
	check(_counts() == Vector2i(8, 7) and _closed_now(), "J connects two vertices across the face")
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "undo J")
	# Loop cut: hover the front-top edge, 2 cuts with the wheel, click, Enter.
	pf.session.set_mode(2)
	pf.session.deselect_all()
	var eg := Vector2i(-1, -1)
	for e in m.edges():
		if m.verts[e.x].y > 0 and m.verts[e.y].y > 0 and m.verts[e.x].z > 0 and m.verts[e.y].z > 0:
			eg = e
	var es := screen(cube, (m.verts[eg.x] + m.verts[eg.y]) * 0.5)
	move(es)
	key(KEY_R, false, true)
	check(not pf._lc.is_empty(), "Ctrl+R starts the loop cut tool")
	move(es)
	check(pf._lc["edge"] != null, "an edge is hovered (preview)")
	button(MOUSE_BUTTON_WHEEL_UP, es, true)
	check(int(pf._lc["cuts"]) == 2, "wheel: 2 cuts")
	button(MOUSE_BUTTON_LEFT, es, true)
	button(MOUSE_BUTTON_LEFT, es, false)
	check(pf.vmodal.active and pf._lc.is_empty(), "click cuts and starts the slide")
	key(KEY_ENTER)
	check(_counts() == Vector2i(16, 14) and _closed_now(), "2 loops cut around the cube (16 verts, 14 faces)")
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "one undo removes the loop cut")
	# Bevel one edge with 2 segments.
	pf.session.select_many([eg], "set")
	move(center)
	key(KEY_B, false, true)
	check(pf.vmodal.active, "Ctrl+B: bevel modal")
	button(MOUSE_BUTTON_WHEEL_UP, center, true)
	type_number("0.2")
	key(KEY_ENTER)
	check(_counts().y == 8 and _closed_now(), "Ctrl+B, wheel (2 segments), 0.2: 8 faces, closed (%s)" % _counts())
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "undo bevel")
	pf.session.select_many([eg], "set")
	move(center)
	key(KEY_B, false, true)
	key(KEY_ESCAPE)
	check(_counts() == Vector2i(8, 6) and not pf.vmodal.active, "Esc cancels the bevel")
	pf.session.set_mode(1)
	pf.session.select_many([tf[0]], "set")
	move(center)
	key(KEY_B, true, true)
	type_number("0.3")
	key(KEY_ENTER)
	check(_counts() == Vector2i(10, 7) and _closed_now(), "Ctrl+Shift+B cuts a corner (10 verts, 7 faces)")
	await undo(cube)
	# Separate selection into a new object.
	pf.session.set_mode(3)
	pf.session.select_many([_face_n(Vector3.UP)], "set")
	key(KEY_P)
	await frames()
	check(pf.ui.op_menu.visible, "P opens the Separate menu")
	pf.ui.op_menu.hide()
	var n0 := cube.get_parent().get_child_count()
	pf.run_action("separate", "selection")
	await frames()
	check(_counts().y == 5 and cube.get_parent().get_child_count() == n0 + 1, "Separate Selection: new object with the face, 5 left")
	await undo(cube)
	await frames()
	check(_counts() == Vector2i(8, 6) and cube.get_parent().get_child_count() == n0, "undo separate removes the new object")
	# Edit-mode Boolean: a second cube added into the mesh cuts the first one.
	pf.session.set_mode(3)
	pf.run_action("add_mesh_pick", "cube")
	for v in pf.session.selected_verts():
		pf.session.mesh.verts[v] = pf.session.mesh.verts[v] * 0.5 + Vector3(1, 1, 1) * 0.5
	pf.session.rebuild(false)
	var cnt_before := _counts()
	pf.run_action("boolean_edit", "difference")
	for i in 20:
		await frames(2)
		if not pf._busy:
			break
	check(_counts() != cnt_before and _closed_now(), "Intersect (Boolean) Difference: corner cut out, closed (%s)" % _counts())
	var bb: AABB = pf.session.mesh.bounds()
	check(bb.size.is_equal_approx(Vector3(2, 2, 2)), "result keeps the original size")
	await undo(cube)
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "undo Boolean and Add")
	# Focus mode
	pf.run_action("focus_set", true)
	check(pf.focus.active, "Focus mode dims the rest (stencil overlay active)")
	pf.run_action("focus_set", false)
	check(not pf.focus.active, "Focus off")
	# Adjust Last Operation (F9 panel): change the parameters of the last operator.
	pf.session.set_mode(3)
	pf.session.select_many([_face_n(Vector3.UP)], "set")
	move(center)
	key(KEY_E)
	type_number("1")
	key(KEY_ENTER)
	await frames(3)
	check(pf.redo.is_current() and pf.redo.label == "Extrude and Move", "after E: Adjust Last Operation available (%s)" % pf.redo.label)
	check(pf.redo.panel != null and is_instance_valid(pf.redo.panel), "panel shown in the 3D view")
	pf.redo.apply_values({"y": 2.0})
	check(_counts() == Vector2i(12, 10) and pf.session.mesh.bounds().size.is_equal_approx(Vector3(2, 4, 2)), "Move Y = 2 in the panel: extrusion redone 2 m high")
	check(pf.redo.is_current(), "panel stays for further tweaks")
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "one undo removes it (no extra steps)")
	pf.session.select_many([_face_n(Vector3.UP)], "set")
	pf.run_action("add_mesh_pick", "uv_sphere")
	pf.redo.apply_values({"segments": 8, "rings": 4})
	check(_counts() == Vector2i(8 + 8 * 3 + 2, 6 + 8 * 4), "Add UV Sphere: segments/rings changed afterwards (%s)" % _counts())
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "undo")
	pf.session.select_many([_face_n(Vector3.UP)], "set")
	move(center)
	key(KEY_I)
	type_number("0.25")
	key(KEY_ENTER)
	pf.redo.apply_values({"thickness": 0.5})
	var ok_in := true
	for p in pf.session.mesh.verts:
		if p.y > 0.99 and not (is_equal_approx(absf(p.x), 1.0) or is_equal_approx(absf(p.x), 0.5)):
			ok_in = false
	check(ok_in and _counts() == Vector2i(12, 10), "Inset thickness changed to 0.5 in the panel")
	await undo(cube)
	pf.session.set_mode(2)
	pf.session.select_many([eg], "set")
	move(center)
	key(KEY_B, false, true)
	type_number("0.2")
	key(KEY_ENTER)
	pf.redo.apply_values({"segments": 3})
	check(_counts().y == 9 and _closed_now(), "Bevel segments changed to 3 in the panel (%s)" % _counts())
	await undo(cube)
	check(_counts() == Vector2i(8, 6), "undo bevel")
	key(KEY_A)
	await frames(2)
	check(not pf.redo.is_current() and pf.redo.panel == null, "any other step hides the panel")
	pf.session.set_mode(1)
	pf.session.deselect_all()

func _uvkey(code: Key, shift := false, ctrl := false, alt := false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	ev.shift_pressed = shift
	ev.ctrl_pressed = ctrl
	ev.alt_pressed = alt
	pf.uv_panel._gui_input(ev)
	var up := ev.duplicate()
	up.pressed = false
	pf.uv_panel._gui_input(up)

func _uvmouse(pos: Vector2, button := MOUSE_BUTTON_NONE, shift := false) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	pf.uv_panel._gui_input(mm)
	if button != MOUSE_BUTTON_NONE:
		for pr in [true, false]:
			var ev := InputEventMouseButton.new()
			ev.button_index = button
			ev.position = pos
			ev.pressed = pr
			ev.shift_pressed = shift
			pf.uv_panel._gui_input(ev)

func _test_uv_editor(cube: MeshInstance3D) -> void:
	print("== UV editor: seams, U > Unwrap, G/R/S, sticky, L, pin, pack, UV2")
	var PfUvOps := preload("res://addons/polyforge/core/pf_uvops.gd")
	pf.run_action("tab", 1)
	await frames(3)
	var up = pf.uv_panel
	check(up.visible and up.size.x > 100, "UV Edit tab shows the UV editor (%s)" % up.size)
	up.frame_unit()
	pf.session.set_mode(2)
	pf.session.select_all()
	key(KEY_E, false, true)
	await frames()
	check(pf.ui.op_menu.visible, "Ctrl+E edge menu")
	pf.ui.op_menu.hide()
	await frames()
	pf.run_action("mark_seam")
	check(pf.session.mesh.seam_edges.size() == 12, "Mark Seam on all edges")
	pf.session.set_mode(3)
	pf.session.select_all()
	key(KEY_U)
	await frames()
	check(pf.ui.op_menu.visible, "U opens the unwrap menu in 3D")
	pf.ui.op_menu.hide()
	pf.run_action("uv_op", "unwrap")
	var m = pf.session.mesh
	var all := {}
	for f in m.faces.size():
		all[f] = true
	check(PfUvOps.islands(m, 0, all).size() == 6, "Unwrap: 6 islands")
	var inside := true
	for f in m.faces.size():
		for u in m.uvs[f]:
			if u.x < -1e-4 or u.y < -1e-4 or u.x > 1.0001 or u.y > 1.0001:
				inside = false
	check(inside, "packed into 0..1")
	_uvkey(KEY_A)
	check(up.sel.size() == 24, "A in the UV editor selects all 24 UV corners")
	var u0: Array = m.uvs.duplicate(true)
	_uvmouse(up.size * 0.5)
	_uvkey(KEY_G)
	_uvkey(KEY_X)
	_uvkey(KEY_PERIOD)
	_uvkey(KEY_1)
	_uvkey(KEY_ENTER)
	var moved := true
	for f in m.faces.size():
		for k in m.uvs[f].size():
			if not (m.uvs[f][k] - u0[f][k]).is_equal_approx(Vector2(0.1, 0)):
				moved = false
	check(moved, "G X .1 Enter moves all UVs by 0.1 in U")
	await undo(cube)
	check(pf.session.mesh.uvs == u0, "Ctrl+Z restores the UVs")
	_uvkey(KEY_R)
	_uvkey(KEY_9)
	_uvkey(KEY_0)
	_uvkey(KEY_ESCAPE)
	check(pf.session.mesh.uvs == u0, "Esc cancels a UV rotate")
	_uvkey(KEY_A, false, false, true)
	check(up.sel.is_empty(), "Alt+A deselects")
	var c: Vector2 = up.uv_to_screen(m.uvs[0][0])
	_uvmouse(c, MOUSE_BUTTON_LEFT)
	check(up.sel.size() == 1, "click: one corner (islands are cut, sticky finds no twin)")
	var fc := Vector2.ZERO
	for u in m.uvs[0]:
		fc += u
	_uvmouse(up.uv_to_screen(fc / 4.0))
	_uvkey(KEY_L)
	check(up.sel.size() == 4, "L selects the island under the cursor (4 corners, got %d)" % up.sel.size())
	_uvkey(KEY_P)
	check(m.uv_pins.size() == 4, "P pins its vertices")
	_uvkey(KEY_P, false, false, true)
	check(m.uv_pins.is_empty(), "Alt+P unpins")
	await undo(cube)
	await undo(cube)
	_uvkey(KEY_P, false, true)
	check(PfUvOps.islands(pf.session.mesh, 0, all).size() == 6, "Ctrl+P packs (islands kept)")
	var b0: Rect2 = PfUvOps.island_bounds(pf.session.mesh, 0, PfUvOps.islands(pf.session.mesh, 0, all)[0])
	check(pf.redo.is_current() and pf.redo.label == "Pack Islands", "F9 panel offers Pack Islands")
	pf.redo.apply_values({"margin": 0.1})
	await frames()
	var b1: Rect2 = PfUvOps.island_bounds(pf.session.mesh, 0, PfUvOps.islands(pf.session.mesh, 0, all)[0])
	check(b1.size.x < b0.size.x - 1e-4, "F9 Margin 0.1 re-packs smaller islands (%.3f -> %.3f)" % [b0.size.x, b1.size.x])
	await undo(cube)
	await _test_uv_3b(cube, up)
	up.channel = 1
	pf.run_action("uv_op", "smart")
	check(pf.session.mesh.has_uv2, "UV2 channel: Smart UV Project writes UV2")
	check(pf.session.mesh.uvs == u0, "UV1 untouched")
	await undo(cube)
	up.channel = 0
	await undo(cube)
	await undo(cube)
	pf.run_action("tab", 0)
	pf.session.set_mode(1)
	pf.session.deselect_all()

func _test_uv_3b(cube: MeshInstance3D, up) -> void:
	print("== UV 3B: 2D cursor, Shift+S, snapping, pivots, stitch, split, sync")
	var PfUvOps := preload("res://addons/polyforge/core/pf_uvops.gd")
	var m = pf.session.mesh
	_uvmouse(up.uv_to_screen(Vector2(0.25, 0.75)), MOUSE_BUTTON_RIGHT, true)
	check(up.cursor.distance_to(Vector2(0.25, 0.75)) < 0.01, "Shift+RMB places the 2D cursor (%s)" % up.cursor)
	var f0 := {}
	for k in m.faces[0].size():
		f0[Vector2i(0, k)] = true
	up.sel = f0.duplicate()
	_uvkey(KEY_S, true)
	await frames()
	check(pf.ui.op_menu.visible, "Shift+S opens the UV Snap menu")
	pf.ui.op_menu.hide()
	await frames()
	pf.run_action("uv_snap", "selected_to_cursor_offset")
	check(PfUvOps.island_bounds(m, 0, {0: true}).get_center().distance_to(up.cursor) < 1e-4, "Selected to Cursor (Offset) centres the face on the cursor")
	await undo(cube)
	pf.run_action("uv_snap", "selected_to_pixels")
	var on_grid := true
	for u in m.uvs[0]:
		on_grid = on_grid and (u * 64.0).is_equal_approx((u * 64.0).round())
	check(on_grid, "Selected to Pixels (no texture: 1/64 grid)")
	await undo(cube)
	pf.run_action("uv_snap", "cursor_to_selected")
	check(up.cursor.is_equal_approx(PfUvOps.island_bounds(m, 0, {0: true}).get_center()), "Cursor to Selected")
	pf.run_action("uv_snap", "cursor_to_origin")
	check(up.cursor == Vector2.ZERO, "Cursor to Origin")
	# vertex snapping: drag face 0 so its first corner lands on a corner of face 1
	up.set_snap(true, "vertex")
	var target: Vector2 = m.uvs[1][0]
	_uvmouse(up.uv_to_screen(m.uvs[0][0]))
	_uvkey(KEY_G)
	_uvmouse(up.uv_to_screen(target) + Vector2(5, 4))
	_uvkey(KEY_ENTER)
	check(m.uvs[0][0].is_equal_approx(target), "Snap Vertex: the grabbed corner lands on another UV vertex")
	await undo(cube)
	up.set_snap(true, "pixels")
	_uvmouse(up.uv_to_screen(m.uvs[0][0]))
	_uvkey(KEY_G)
	_uvmouse(up.uv_to_screen(m.uvs[0][0]) + Vector2(13.3, 7.7))
	_uvkey(KEY_ENTER)
	check((m.uvs[0][0] * 64.0).is_equal_approx((m.uvs[0][0] * 64.0).round()), "Snap Pixels: the grabbed corner lands on the pixel grid")
	await undo(cube)
	up.set_snap(false)
	_uvkey(KEY_TAB, true)
	check(up.snap_on, "Shift+Tab toggles snapping")
	up.set_snap(false)
	# Individual Origins: every island scales around its own centre
	var all := {}
	for f in m.faces.size():
		all[f] = true
	var centres := []
	for isl in PfUvOps.islands(m, 0, all):
		centres.append(PfUvOps.island_bounds(m, 0, isl).get_center())
	_uvkey(KEY_PERIOD)
	await frames()
	check(pf.ui.op_menu.visible, "Period opens the UV pivot menu")
	pf.ui.op_menu.hide()
	await frames()
	pf.run_action("uv_pivot", "individual")
	_uvkey(KEY_A)
	_uvkey(KEY_S)
	_uvkey(KEY_0)
	_uvkey(KEY_PERIOD)
	_uvkey(KEY_5)
	_uvkey(KEY_ENTER)
	var same := true
	var isl2: Array = PfUvOps.islands(m, 0, all)
	for i in isl2.size():
		same = same and PfUvOps.island_bounds(m, 0, isl2[i]).get_center().distance_to(centres[i]) < 1e-4
	check(isl2.size() == 6 and same, "Individual Origins: islands keep their centres")
	await undo(cube)
	up.set_pivot("bounds")
	# Stitch two faces that share an edge
	var e0: Vector2i = m.edges()[0]
	var two: PackedInt32Array = m.edge_faces(e0)
	up.sel = {}
	for f in two:
		for k in m.faces[f].size():
			up.sel[Vector2i(f, k)] = true
	_uvkey(KEY_V)
	var a: Vector2 = m.uvs[two[0]][m.corner_of(two[0], e0.x)]
	var b: Vector2 = m.uvs[two[1]][m.corner_of(two[1], e0.x)]
	check(a.is_equal_approx(b), "V stitches the shared edge")
	await undo(cube)
	up.sel = f0.duplicate()
	up.sel[Vector2i(two[1], 0)] = true
	_uvkey(KEY_Y)
	check(up.sel.size() == m.faces[0].size(), "Y keeps only fully selected faces")
	# UV Sync Selection
	pf.session.deselect_all()
	up.set_sync(true)
	check(up.visible_faces().size() == m.faces.size(), "Sync: all faces shown")
	up.select_mode = "face"
	var fc := Vector2.ZERO
	for u in m.uvs[2]:
		fc += u
	_uvmouse(up.uv_to_screen(fc / m.uvs[2].size()), MOUSE_BUTTON_LEFT)
	check(pf.session.selected_faces().size() == 1 and pf.session.selected_faces().has(2), "Sync: clicking a UV face selects it in 3D")
	pf.session.select_all()
	up.queue_redraw()
	up._pull_sync()
	check(up.sel.size() == 24, "Sync: 3D Select All shows in the UV editor")
	up.set_sync(false)
	up.select_mode = "vertex"
	pf.run_action("uv_op", "lightmap")
	check(PfUvOps.islands(m, 0, all).size() == 6, "U > Lightmap Pack runs from the editor")
	check(pf.redo.label == "Lightmap Pack", "F9 offers Lightmap Pack margin")
	await undo(cube)

func _test_tabs_and_menus(cube: MeshInstance3D) -> void:
	print("== Mesh Edit / UV Edit tabs, menus")
	key(KEY_PAGEDOWN, false, true)
	check(pf.tab == 1 and pf.uv_panel.visible, "Ctrl+PageDown -> UV Edit: UV panel next to the 3D view")
	key(KEY_PAGEUP, false, true)
	check(pf.tab == 0 and not pf.uv_panel.visible, "Ctrl+PageUp -> Mesh Edit")
	var center := Vector2(vp.size) * 0.5
	move(center)
	button(MOUSE_BUTTON_RIGHT, center, true)
	var r := button(MOUSE_BUTTON_RIGHT, center, false)
	await frames()
	check(r == PASS and pf.ui.context_menu.visible, "RMB click opens the context menu (press passed to Godot for fly mode)")
	pf.ui.context_menu.hide()
	key(KEY_PERIOD)
	await frames()
	check(pf.ui.pivot_menu.visible, ". opens the pivot menu")
	pf.ui.pivot_menu.hide()
	key(KEY_A, true)
	await frames()
	check(pf.ui.add_menu.visible, "Shift+A opens the Add Mesh menu")
	pf.ui.add_menu.hide()
	var nv: int = pf.session.mesh.verts.size()
	pf.run_action("add_mesh_pick", "cube")
	check(pf.session.mesh.verts.size() == nv + 8 and pf.session.sel_v.size() == 8, "Add Cube in Edit Mode joins the mesh, new part selected")
	await undo(cube)
	check(pf.session.mesh.verts.size() == nv, "undo removes it")


func _test_key_blocking(cube: MeshInstance3D) -> void:
	print("== Edit Mode owns the keyboard (except navigation / save / undo)")
	check(key(KEY_W) == STOP and key(KEY_E) == STOP and key(KEY_Q) == STOP and key(KEY_F) == STOP, "W/E/Q/F blocked (no Godot gizmo/focus surprises)")
	check(key(KEY_KP_3) == PASS and key(KEY_KP_7) == PASS, "numpad views pass to Godot")
	check(key(KEY_S, false, true) == PASS and key(KEY_Z, false, true) == PASS, "Ctrl+S / Ctrl+Z pass to Godot")
	var center := Vector2(vp.size) * 0.5
	button(MOUSE_BUTTON_RIGHT, center, true)
	check(key(KEY_W) == PASS, "with RMB held (fly mode) W goes to Godot")
	button(MOUSE_BUTTON_RIGHT, center + Vector2(50, 0), false)
	await frames()
	pf.ui.context_menu.hide()
	# Real dispatch: top-row 1 must not change the view in Edit Mode.
	for c in vp.get_parent().get_parent().find_children("*", "Control", true, false):
		if c.focus_mode != Control.FOCUS_NONE and c.get_class() == "Control":
			c.grab_focus()
			break
	await frames()
	look(Vector3(3, 3, 6), Vector3(0, 1, 0))
	var b0 := cam.global_basis
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = KEY_2
		ev.physical_keycode = KEY_2
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await frames(2)
	await frames(10)
	check(pf.session.mode == 2 and cam.global_basis.is_equal_approx(b0), "real key 2: edge mode, view untouched")
	key(KEY_1)


func _test_add_and_loops(root: Node) -> void:
	print("== Polyforge > Add Mesh (object), Alt+click loops, L, Ctrl+L")
	pf.exit_edit()
	pf.run_action("add_object", "grid")
	await frames(5)
	var grid: MeshInstance3D = null
	for c in root.get_children():
		if c.name.begins_with("Grid"):
			grid = c
	check(grid != null and grid.owner == root, "Grid node added to the scene")
	check(pf.session != null and pf.session.node == grid, "new object enters Edit Mode")
	look(Vector3(0.0, 6, 0.01), Vector3(0, 0, 0))
	key(KEY_2)
	var m = pf.session.mesh
	# Middle horizontal edge (z = 0, x in [0, 0.2]).
	var e0 := Vector2i(-1, -1)
	for e in m.edges():
		var a: Vector3 = m.verts[e.x]
		var b: Vector3 = m.verts[e.y]
		if is_zero_approx(a.z) and is_zero_approx(b.z) and minf(a.x, b.x) > -0.01 and maxf(a.x, b.x) < 0.21:
			e0 = e
	var mid: Vector3 = (m.verts[e0.x] + m.verts[e0.y]) * 0.5
	click(screen(grid, mid), false, false, true)
	check(pf.session.sel_e.size() == 10, "Alt+click: edge loop across the 10x10 grid (got %d)" % pf.session.sel_e.size())
	click(screen(grid, mid), false, true, true)
	check(pf.session.sel_e.size() == 11, "Ctrl+Alt+click: edge ring (11 edges, got %d)" % pf.session.sel_e.size())
	key(KEY_3)
	key(KEY_A, false, false, true)
	move(screen(grid, Vector3(0.1, 0, 0.1)))
	key(KEY_L)
	check(pf.session.sel_f.size() == 100, "L selects the linked faces under the cursor")
	key(KEY_A, false, false, true)
	pf.session.select_many([0], "set")
	key(KEY_KP_ADD, false, true)
	check(pf.session.sel_f.size() == 4, "Ctrl+Numpad+ grows the selection (corner face -> 4)")
	key(KEY_KP_SUBTRACT, false, true)
	check(pf.session.sel_f.size() == 1, "Ctrl+Numpad- shrinks it back")
	pf.exit_edit()
	for i in 40:
		if not grid.is_inside_tree():
			break
		await undo(root)
	check(not grid.is_inside_tree(), "Ctrl+Z (repeated) removes the added object")


func _test_convert_godot_box(root: Node) -> void:
	print("== Tab on a Godot BoxMesh converts it (undoable)")
	var box: MeshInstance3D = root.get_node("GodotBox")
	await select(box)
	key(KEY_TAB)
	check(pf.session != null and box.mesh is ArrayMesh and box.mesh.has_meta(PfMesh.META_KEY), "BoxMesh -> Polyforge ArrayMesh")
	check(pf.session.mesh.bounds().size.is_equal_approx(Vector3.ONE), "same 1 m size")
	key(KEY_TAB)
	await undo(box)
	check(box.mesh is BoxMesh, "Ctrl+Z restores the BoxMesh")
	var floor_mi: MeshInstance3D = root.get_node("Floor")
	await select(floor_mi)
	key(KEY_TAB)
	check(pf.session != null, "PlaneMesh floor converts too")
	key(KEY_TAB)
	await undo(floor_mi)


func _bounds(pts: PackedVector3Array) -> AABB:
	var bb := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		bb = bb.expand(p)
	return bb

func _test_multi_edit(root: Node) -> void:
	print("== multi-object edit: Tab with two meshes selected")
	var cube: MeshInstance3D = root.get_node("Cube")
	var box: MeshInstance3D = root.get_node("GodotBox")
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(box)
	sel.add_node(cube)
	await frames()
	look(Vector3(1.5, 4, 9), Vector3(1.5, 1, 0))
	key(KEY_TAB)
	check(pf.session != null and pf.session.is_multi() and pf.session.members.size() == 2, "Tab: both objects in Edit Mode")
	check(box.mesh is ArrayMesh and pf.session.mesh.verts.size() == 16, "BoxMesh converted, combined mesh has 16 vertices")
	check(cube.has_meta("_edit_lock_") and box.has_meta("_edit_lock_"), "both objects locked (no Godot gizmo)")
	var b0: AABB = (box.mesh as ArrayMesh).get_aabb()
	var c0: AABB = (cube.mesh as ArrayMesh).get_aabb()
	key(KEY_1)
	key(KEY_A)
	move(Vector2(vp.size) * 0.5)
	key(KEY_G)
	key(KEY_X)
	type_number("1")
	key(KEY_ENTER)
	var b1: AABB = (box.mesh as ArrayMesh).get_aabb()
	var c1: AABB = (cube.mesh as ArrayMesh).get_aabb()
	check(is_equal_approx(b1.position.x - b0.position.x, 1.0) and is_equal_approx(c1.position.x - c0.position.x, 1.0), "G X 1 moves both meshes (each in its own space)")
	await undo(cube)
	check((box.mesh as ArrayMesh).get_aabb().is_equal_approx(b0) and (cube.mesh as ArrayMesh).get_aabb().is_equal_approx(c0), "Ctrl+Z restores both")
	# Extrude a face of the box part only.
	pf.session.set_mode(3)
	var m = pf.session.mesh
	var bf := -1
	for fi in m.faces.size():
		if m.face_tag[fi] == 0 and m.face_normal(fi).is_equal_approx(Vector3.UP):
			bf = fi
	pf.session.select_many([bf], "set")
	move(Vector2(vp.size) * 0.5)
	key(KEY_E)
	type_number("1")
	key(KEY_ENTER)
	key(KEY_TAB)
	check(pf.session == null, "Tab leaves Edit Mode")
	check(pf._read_pf(box).faces.size() == 10 and pf._read_pf(cube).faces.size() == 6, "extrusion went into the box only")
	check(not cube.has_meta("_edit_lock_") and not box.has_meta("_edit_lock_"), "locks removed")
	await undo(cube)
	check(pf._read_pf(box).faces.size() == 6, "undo after leaving Edit Mode restores the box")
	for i in 10:
		if box.mesh is BoxMesh:
			break
		await undo(root)
	sel.clear()

func _test_join_boolean_objects(root: Node) -> void:
	print("== Object Mode: Join (Ctrl+J) and Boolean between objects")
	var cube: MeshInstance3D = root.get_node("Cube")
	var box: MeshInstance3D = root.get_node("GodotBox")
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(box)
	sel.add_node(cube)
	await frames()
	pf.run_action("obj_join")
	await frames()
	var m = pf._read_pf(cube)
	check(m.verts.size() == 16 and not box.is_inside_tree(), "Join: box merged into the cube (16 verts), box node removed")
	await undo(root)
	await frames()
	check(box.is_inside_tree() and pf._read_pf(cube).verts.size() == 8, "undo Join")
	sel.clear()
	sel.add_node(box)
	sel.add_node(cube)
	await frames()
	pf.run_action("obj_boolean", "union")
	for i in 20:
		await frames(2)
		if not pf._busy:
			break
	var u = pf._read_pf(cube)
	check(u != null and u.verts.size() == 16, "Boolean Union of two separate boxes -> both in one mesh (%d verts)" % (u.verts.size() if u else -1))
	await undo(cube)
	check(pf._read_pf(cube).verts.size() == 8, "undo Boolean")
	sel.clear()

func _test_collision_shapes(root: Node) -> void:
	print("== Edit Mode on collision shapes (concave trimesh, convex hull)")
	var cc: CollisionShape3D = root.get_node("Body/ConcaveShape")
	await select(cc)
	look(Vector3(-3, 2, 6), Vector3(-3, 0.5, 0))
	key(KEY_TAB)
	check(pf.session != null and pf.session.kind == "concave", "Tab on a ConcavePolygonShape3D -> Edit Mode")
	check(pf.session.mesh.verts.size() == 8 and pf.session.mesh.faces.size() == 6, "trimesh box edited as 8 vertices / 6 quads")
	check(pf.ui.tab_uv.disabled and not pf.ui.options_btn.visible, "no UV Edit / Options for shapes")
	var f0: PackedVector3Array = (cc.shape as ConcavePolygonShape3D).get_faces()
	key(KEY_1)
	key(KEY_A)
	move(Vector2(vp.size) * 0.5)
	key(KEY_G)
	key(KEY_Y)
	type_number("1")
	key(KEY_ENTER)
	var f1: PackedVector3Array = (cc.shape as ConcavePolygonShape3D).get_faces()
	check(f1.size() == f0.size() and _bounds(f1).position.is_equal_approx(_bounds(f0).position + Vector3(0, 1, 0)) \
		and _bounds(f1).size.is_equal_approx(_bounds(f0).size), "G Y 1 moves the collision triangles (same triangle count)")
	await undo(cc)
	var f2: PackedVector3Array = (cc.shape as ConcavePolygonShape3D).get_faces()
	check(f2.size() == f0.size() and _bounds(f2) == _bounds(f0), "Ctrl+Z restores the shape")
	key(KEY_3)
	pf.session.select_many([0], "set")
	pf.run_action("delete", "faces")
	check(pf.session.mesh.faces.size() == 5 and pf._message.contains("open edges"), "deleting a trimesh face warns about the hole (%s)" % pf._message)
	await undo(cc)
	key(KEY_1)
	key(KEY_TAB)
	check(pf.session == null and not cc.has_meta("_edit_lock_"), "Tab leaves Edit Mode, lock removed")
	var cv: CollisionShape3D = root.get_node("Body/ConvexShape")
	await select(cv)
	key(KEY_TAB)
	check(pf.session != null and pf.session.kind == "convex", "Tab on a ConvexPolygonShape3D -> Edit Mode")
	var m = pf.session.mesh
	var ngons := 0
	for f in m.faces:
		if f.size() > 4:
			ngons += 1
	check(m.verts.size() == 32 and ngons == 2, "convex cylinder: 32 points, caps as 2 n-gons")
	# Push one top rim vertex onto the cap (inside the hull): it is dropped.
	var v := -1
	var best := -INF
	for i in m.verts.size():
		if m.verts[i].y > 0 and m.verts[i].x > best:
			best = m.verts[i].x
			v = i
	pf.session.select_many([v], "set")
	move(Vector2(vp.size) * 0.5)
	key(KEY_G)
	key(KEY_X)
	type_number("-0.3")
	key(KEY_ENTER)
	await frames()
	check(pf.session.mesh.verts.size() == 31 and (cv.shape as ConvexPolygonShape3D).points.size() == 31, "vertex moved inside the hull is removed (31 points)")
	check(pf._message.contains("inside the convex hull"), "user is told why (%s)" % pf._message)
	await undo(cv)
	check(pf.session.mesh.verts.size() == 32 and (cv.shape as ConvexPolygonShape3D).points.size() == 32, "Ctrl+Z brings it back")
	pf.session.select_many([v], "set")
	move(Vector2(vp.size) * 0.5)
	key(KEY_G)
	key(KEY_X)
	type_number("0.5")
	key(KEY_ENTER)
	var has_far := false
	for p in (cv.shape as ConvexPolygonShape3D).points:
		if p.is_equal_approx(Vector3(1.0, 1.0, 0.0)):
			has_far = true
	check(has_far, "vertex pulled outward becomes a hull point (hull grows)")
	key(KEY_1)
	var keep: Array = range(pf.session.mesh.verts.size()).filter(func(i): return pf.session.mesh.verts[i].y > 0)
	var pts_before: int = (cv.shape as ConvexPolygonShape3D).points.size()
	pf.session.select_many(keep, "set")
	pf.run_action("delete", "verts")
	check((cv.shape as ConvexPolygonShape3D).points.size() == pts_before and pf._message.contains("cancelled"), "deleting down to a flat convex shape is refused (%s)" % pf._message)
	key(KEY_TAB)
	check(cv.shape.has_meta("polyforge"), "edit data kept on the shape as plain metadata")

func _test_local_view(root: Node, cube: MeshInstance3D) -> void:
	print("== Local View (Numpad /) without touching the scene")
	await select(cube)
	var h := history_for(root)
	var v0 := h.get_version()
	var floor_mi: MeshInstance3D = root.get_node("Floor")
	check(key(KEY_KP_DIVIDE) == STOP and pf.local_view.active, "Numpad / -> Local View")
	check(pf.local_view.is_hidden(floor_mi) and not pf.local_view.is_hidden(cube), "other objects hidden, selection kept")
	check(floor_mi.visible and h.get_version() == v0, "node visibility untouched, no undo step (scene not modified)")
	key(KEY_TAB)
	check(pf.session != null and pf.local_view.active, "Edit Mode inside Local View")
	key(KEY_TAB)
	key(KEY_KP_DIVIDE)
	check(not pf.local_view.active, "Numpad / again leaves Local View")


func _test_exit_and_save(root: Node, cube: MeshInstance3D) -> void:
	print("== exit on selection change, save without addon references")
	await select(cube)
	key(KEY_TAB)
	check(pf.session != null, "edit cube")
	await select(root.get_node("GodotBox"))
	check(pf.session == null, "selecting another node leaves Edit Mode")
	check(not cube.has_meta("_edit_lock_"), "lock removed after leaving Edit Mode")
	await select(cube)
	key(KEY_TAB)
	key(KEY_A)
	move(Vector2(vp.size) * 0.5)
	key(KEY_G)
	key(KEY_Y)
	type_number("1")
	key(KEY_ENTER)
	EditorInterface.save_scene()
	await frames(5)
	var txt := FileAccess.get_file_as_string("res://test_scene.tscn")
	check(not txt.contains("res://addons/polyforge"), "saved scene references no Polyforge script")
	check(txt.contains("polyforge"), "edit data saved as mesh metadata")
	check(not txt.contains("_edit_lock_"), "temporary gizmo lock not saved")
	check(not txt.contains("PolyforgeSaveGuard"), "internal save guard not saved")
	check(cube.has_meta("_edit_lock_"), "gizmo lock back after saving (still in Edit Mode)")
	key(KEY_TAB)
	var ps: PackedScene = ResourceLoader.load("res://test_scene.tscn", "", ResourceLoader.CACHE_MODE_IGNORE)
	var inst := ps.instantiate()
	var c2: MeshInstance3D = inst.get_node("Cube")
	var am: ArrayMesh = c2.mesh
	var top := -INF
	for p in am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		top = maxf(top, p.y)
	check(is_equal_approx(top, 2.0), "reloaded scene has the edited mesh (top at y=2)")
	inst.free()


func _finish() -> void:
	print("RESULT: %s" % ("PASS" if failures == 0 else "%d FAILURE(S)" % failures))
	get_tree().quit(1 if failures > 0 else 0)


func _nearest_vert(p: Vector3) -> int:
	var m = pf.session.mesh
	var best := -1
	for i in m.verts.size():
		if best < 0 or m.verts[i].distance_to(p) < m.verts[best].distance_to(p):
			best = i
	return best

func _test_stage4(root: Node) -> void:
	print("== stage 4A: 3D cursor, snap, proportional, symmetry, mirror, material slots")
	if pf.session != null:
		key(KEY_TAB)
	pf.run_action("add_object", "grid")
	await frames(5)
	var grid: MeshInstance3D = root.get_child(root.get_child_count() - 1)
	check(pf.session != null and pf.session.node == grid, "fresh grid in Edit Mode")
	look(Vector3(0.0, 6, 0.01), Vector3(0, 0, 0))
	await frames()
	key(KEY_1)
	# 3D cursor
	var sp := screen(grid, Vector3(0.4, 0, 0.2))
	move(sp)
	button(MOUSE_BUTTON_RIGHT, sp, true, true)
	button(MOUSE_BUTTON_RIGHT, sp, false, true)
	check(pf.cursor3d.distance_to(Vector3(0.4, 0, 0.2)) < 0.02, "Shift+RMB puts the 3D cursor on the surface (%s)" % pf.cursor3d)
	check(not pf.ui.context_menu.visible, "Shift+RMB does not open the context menu")
	move(screen(grid, Vector3.ZERO))
	key(KEY_S, true)
	check(pf.ui.op_menu.visible, "Shift+S opens the Snap menu")
	pf.ui.op_menu.hide()
	await frames()
	var v := _nearest_vert(Vector3(-0.6, 0, 0.0))
	pf.session.select_many([v], "set")
	pf.run_action("snap", "sel_cursor")
	check(pf.session.mesh.verts[v].distance_to(pf.cursor3d) < 1e-5, "Selection to Cursor")
	await undo(grid)
	check(pf.session.mesh.verts[v].is_equal_approx(Vector3(-0.6, 0, 0)), "undo Selection to Cursor")
	pf.session.select_many([v], "set")
	pf.run_action("snap", "cursor_sel")
	check(pf.cursor3d.is_equal_approx(Vector3(-0.6, 0, 0)), "Cursor to Selected")
	# pivot: 3D cursor
	pf.cursor3d = Vector3(-1, 0, 0)
	pf.run_action("pivot", "cursor")
	move(Vector2(vp.size) * 0.5)
	key(KEY_S)
	type_number("2")
	key(KEY_ENTER)
	check(pf.session.mesh.verts[v].is_equal_approx(Vector3(-0.2, 0, 0)), "S 2 around the 3D cursor (%s)" % pf.session.mesh.verts[v])
	await undo(grid)
	pf.run_action("pivot", "median")
	pf.cursor3d = Vector3.ZERO
	# proportional editing
	pf.run_action("proportional", true)
	pf.settings.set_pref("prop_size", 0.5)
	pf.settings.set_pref("prop_falloff", "linear")
	var c := _nearest_vert(Vector3.ZERO)
	var n1 := _nearest_vert(Vector3(0.2, 0, 0))
	var far := _nearest_vert(Vector3(0.8, 0, 0))
	pf.session.select_many([c], "set")
	move(Vector2(vp.size) * 0.5)
	key(KEY_G)
	key(KEY_Y)
	type_number("1")
	var m = pf.session.mesh
	check(is_equal_approx(m.verts[c].y, 1.0) and is_equal_approx(m.verts[n1].y, 0.6) and m.verts[far].y == 0.0,
		"O: linear falloff, size 0.5 -> neighbour at 0.2 moves 0.6, far vertex stays (%.3f)" % m.verts[n1].y)
	button(MOUSE_BUTTON_WHEEL_DOWN, Vector2(vp.size) * 0.5, true)
	check(pf.modal.prop_size > 0.5 and pf.session.mesh.verts[n1].y > 0.6, "wheel grows the proportional size during G")
	key(KEY_ESCAPE)
	check(pf.session.mesh.verts[n1].y == 0.0, "cancel restores the influenced vertices")
	check(float(pf.settings.get_pref("prop_size")) > 0.5, "new size remembered")
	key(KEY_O)
	check(not bool(pf.settings.get_pref("proportional")), "O toggles proportional editing off")
	# symmetry X
	pf.run_action("symmetry", 0)
	var r := _nearest_vert(Vector3(0.6, 0, 0.2))
	var l := _nearest_vert(Vector3(-0.6, 0, 0.2))
	pf.session.select_many([r], "set")
	move(Vector2(vp.size) * 0.5)
	key(KEY_G)
	key(KEY_X)
	type_number("0.2")
	key(KEY_ENTER)
	check(pf.session.mesh.verts[l].is_equal_approx(Vector3(-0.8, 0, 0.2)), "Mirror X: partner follows mirrored (%s)" % pf.session.mesh.verts[l])
	await undo(grid)
	check(pf.session.mesh.verts[l].is_equal_approx(Vector3(-0.6, 0, 0.2)), "undo restores the partner")
	pf.run_action("symmetry", 0)
	# Ctrl+M
	key(KEY_3)
	key(KEY_A)
	pf.session.select_many([0], "set")
	var f0c: Vector3 = pf.session.mesh.face_center(0)
	key(KEY_M, false, true)
	check(pf.ui.op_menu.visible, "Ctrl+M opens the Mirror menu")
	pf.ui.op_menu.hide()
	await frames()
	pf.cursor3d = Vector3(f0c.x + 1.0, 0, 0)
	pf.run_action("pivot", "cursor")
	pf.run_action("mirror", [0, false])
	pf.run_action("pivot", "median")
	check(is_equal_approx(pf.session.mesh.face_center(0).x, f0c.x + 2.0) and pf.session.mesh.face_normal(0).y > 0.99,
		"Mirror X about the cursor, normal still up")
	await undo(grid)
	pf.cursor3d = Vector3.ZERO
	# material slots
	var red := StandardMaterial3D.new()
	pf.session.select_many([0, 1], "set")
	pf.run_action("mat_slot_add")
	pf.run_action("mat_set", red)
	pf.run_action("mat_assign")
	check(pf.active_slot == 1 and grid.mesh.get_surface_count() == 2 and grid.mesh.surface_get_material(1) == red, "slot added, material set, 2 faces assigned -> 2 surfaces")
	pf.session.select_many([0], "set")
	key(KEY_G, true)
	check(pf.ui.op_menu.visible, "Shift+G opens Select Similar")
	pf.ui.op_menu.hide()
	await frames()
	pf.run_action("select_similar", "material")
	check(pf.session.sel_f.size() == 2, "Select Similar > Material")
	pf.run_action("select_none")
	pf.run_action("mat_select")
	check(pf.session.sel_f.size() == 2, "material panel Select")
	pf.ui.open_materials()
	await frames()
	check(pf.ui.mat_panel.visible and pf.ui.mat_list.item_count == 2, "material panel lists 2 slots")
	pf.ui.mat_panel.hide()
	pf.run_action("mat_slot_remove")
	check(grid.mesh.get_surface_count() == 1, "removing the slot moves its faces back to slot 0")
	key(KEY_TAB)
	key(KEY_1)
	grid.get_parent().remove_child(grid)
	grid.queue_free()
	await frames()


func _test_stage4b(root: Node) -> void:
	print("== stage 4B: overlays, snapping")
	pf.run_action("add_object", "grid")
	await frames(5)
	var grid: MeshInstance3D = root.get_child(root.get_child_count() - 1)
	look(Vector3(0.0, 6, 0.01), Vector3(0, 0, 0))
	await frames()
	key(KEY_1)
	for o in ["overlay_stats", "overlay_edge_length", "overlay_face_orientation", "overlay_normals"]:
		pf.run_action("overlay", o)
	pf.run_action("select_all")
	await frames()
	check(RenderingServer.mesh_get_surface_count(pf.overlay._meshes["orient"]) == 1 and RenderingServer.mesh_get_surface_count(pf.overlay._meshes["normals"]) == 1,
		"Face Orientation and Face Normals overlays drawn")
	check(pf.ui.overlays_btn.get_popup().is_item_checked(0), "Overlays menu shows the state")
	for o in ["overlay_stats", "overlay_edge_length", "overlay_face_orientation", "overlay_normals"]:
		pf.run_action("overlay", o)
	await frames()
	check(RenderingServer.mesh_get_surface_count(pf.overlay._meshes["orient"]) == 0, "overlays off again")
	key(KEY_TAB, true)
	check(bool(pf.settings.get_pref("snap_on")), "Shift+Tab turns snapping on")
	pf.run_action("snap_target", "vertex")
	var v := _nearest_vert(Vector3(0.6, 0, 0.2))
	var tgt := _nearest_vert(Vector3(-0.4, 0, -0.6))
	pf.session.select_many([v], "set")
	var start := screen(grid, Vector3(0.6, 0, 0.2))
	move(start)
	key(KEY_G)
	move(screen(grid, Vector3(-0.4, 0, -0.6)) + Vector2(2, 1))
	check(pf.session.mesh.verts[v].is_equal_approx(pf.session.mesh.verts[tgt]), "Snap to Vertex: lands exactly on the vertex under the mouse (%s)" % pf.session.mesh.verts[v])
	move(screen(grid, Vector3(-0.4, 0, -0.6)) + Vector2(2, 1), false, true)
	check(not pf.session.mesh.verts[v].is_equal_approx(pf.session.mesh.verts[tgt]), "Ctrl inverts snapping")
	key(KEY_ESCAPE)
	pf.run_action("snap_target", "edge")
	move(start)
	key(KEY_G)
	move(screen(grid, Vector3(-0.5, 0, -0.6)) + Vector2(0, 3))
	var p: Vector3 = pf.session.mesh.verts[v]
	check(is_equal_approx(p.z, -0.6) and is_equal_approx(p.y, 0.0), "Snap to Edge: on the edge z = -0.6 (%s)" % p)
	key(KEY_ESCAPE)
	pf.session.select_many([v], "set")
	move(start)
	key(KEY_G)
	key(KEY_Y)
	type_number("1")
	key(KEY_ENTER)
	pf.run_action("snap_target", "face")
	move(screen(grid, Vector3(0.6, 1, 0.2)))
	key(KEY_G)
	move(screen(grid, Vector3(-0.5, 0, -0.5)))
	p = pf.session.mesh.verts[v]
	check(p.distance_to(Vector3(-0.5, 0, -0.5)) < 0.02, "Snap to Face: lands on the surface under the mouse (%s)" % p)
	key(KEY_ESCAPE)
	key(KEY_TAB, true)
	pf.run_action("snap_target", "increment")
	check(not bool(pf.settings.get_pref("snap_on")), "Shift+Tab turns snapping off")
	key(KEY_TAB)
	grid.get_parent().remove_child(grid)
	grid.queue_free()
	await frames()
