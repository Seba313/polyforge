## Polyforge — Blender-style Edit Mode for Godot 4.7.
##
## Object Mode is plain Godot (only Tab and Numpad / are handled, optional
## Blender shortcuts can be enabled in the settings). Tab enters Edit Mode on
## the selected MeshInstance3D: a yellow frame marks the viewport and the
## Blender keymap takes over while the mouse is over it.
##
## Output is always a plain ArrayMesh on a plain MeshInstance3D; the edit data
## is stored as metadata (packed arrays). No class_name anywhere: every script
## is loaded with preload, so the plugin cannot clash with other addons.
@tool
extends EditorPlugin

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfUv := preload("res://addons/polyforge/core/pf_uv.gd")
const PfSelect := preload("res://addons/polyforge/core/pf_select.gd")
const PfSession := preload("res://addons/polyforge/editor/pf_session.gd")
const PfPicking := preload("res://addons/polyforge/editor/pf_picking.gd")
const PfOverlay := preload("res://addons/polyforge/editor/pf_overlay.gd")
const PfModal := preload("res://addons/polyforge/editor/pf_modal.gd")
const PfKeymap := preload("res://addons/polyforge/editor/pf_keymap.gd")
const PfSettings := preload("res://addons/polyforge/editor/pf_settings.gd")
const PfUi := preload("res://addons/polyforge/editor/pf_ui.gd")
const PfLocalView := preload("res://addons/polyforge/editor/pf_local_view.gd")
const PfUvPanel := preload("res://addons/polyforge/editor/pf_uv_panel.gd")
const PfSaveGuard := preload("res://addons/polyforge/editor/pf_save_guard.gd")
const PfShape := preload("res://addons/polyforge/core/pf_shape.gd")
const PfOrient := preload("res://addons/polyforge/editor/pf_orient.gd")
const PfGizmo := preload("res://addons/polyforge/editor/pf_gizmo.gd")
const PfOps := preload("res://addons/polyforge/core/pf_ops.gd")
const PfValueModal := preload("res://addons/polyforge/editor/pf_value_modal.gd")
const PfOps2 := preload("res://addons/polyforge/core/pf_ops2.gd")
const PfBoolean := preload("res://addons/polyforge/editor/pf_boolean.gd")
const PfFocus := preload("res://addons/polyforge/editor/pf_focus.gd")
const PfRedo := preload("res://addons/polyforge/editor/pf_redo.gd")
const PfUvOps := preload("res://addons/polyforge/core/pf_uvops.gd")

const STOP := EditorPlugin.AFTER_GUI_INPUT_STOP
const PASS := EditorPlugin.AFTER_GUI_INPUT_PASS
const MODE_NAMES := ["", "Vertex", "Edge", "Face"]
const CLICK_DRAG_PX := 6.0
const RMB_CLICK_MS := 300

var settings = null
var session = null           # PfSession while in Edit Mode
var overlay = null
var modal = null
var ui = null
var local_view = null
var uv_panel: Control = null
var tab := 0                 # 0 = Mesh Edit, 1 = UV Edit
var pivot_mode := "median"
var orientation := "global"  # Transform Orientation (global / local / normal / view)
var gizmo = null             # PfGizmo (optional, off by default)
var _gizmo_hover := ""
var vmodal = null            # value modal (Inset, Shrink/Fatten)
var _pending_undo: Dictionary = {}   # operator before a following move: {"label", "pre"}
var _vm_state: Dictionary = {}       # value-modal operator state
var _lc: Dictionary = {}             # Loop Cut tool: {"cuts", "edge"} while choosing the loop
var focus = null                     # PfFocus
var _busy := false                   # async operator (Boolean) running
var redo = null                      # PfRedo: Adjust Last Operation
var last_mode := 1
var active_slot := 0
var cursor3d := Vector3.ZERO   # Blender's 3D cursor (world space)

var _camera: Camera3D = null
var _mouse := Vector2.ZERO
var _lmb_down := false
var _lmb_pos := Vector2.ZERO
var _box := false
var _box_rect := Rect2()
var _rmb_down := false
var _rmb_pos := Vector2.ZERO
var _rmb_time := 0
var _region := ""            # "", "box", "circle"
var _region_drag := false
var _region_op := "add"
var _region_before: Dictionary = {}
var _circle_radius := 40.0
var _circle_paint := 0
var _message := ""
var _message_until := 0
var _lv_accum := 0.0
var _pass_f_until := 0
var _locked_node: Node3D = null   # temporary _edit_lock_ that hides Godot's gizmo
var _guard: Node = null
var _extra_locked: Array = []   # other objects locked in multi-object edit


# ==============================================================================
# Plugin lifecycle
# ==============================================================================

func _get_plugin_name() -> String:
	return "Polyforge"

func _enter_tree() -> void:
	settings = PfSettings.new()
	overlay = PfOverlay.new()
	modal = PfModal.new()
	modal.undo = get_undo_redo()
	modal.finished.connect(_on_modal_finished)
	vmodal = PfValueModal.new()
	vmodal.finished.connect(_on_vmodal_finished)
	focus = PfFocus.new()
	redo = PfRedo.new()
	local_view = PfLocalView.new()
	ui = PfUi.new()
	ui.build(self)
	uv_panel = PfUvPanel.new()
	uv_panel.name = "PolyforgeUV"
	uv_panel.visible = false
	uv_panel.on_key = _uv_panel_key
	uv_panel.plugin = self
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, uv_panel)
	tab = int(settings.get_pref("last_tab"))
	orientation = str(settings.get_pref("orientation"))
	gizmo = PfGizmo.new()
	gizmo.ui_scale = EditorInterface.get_editor_scale()
	gizmo.show_move = bool(settings.get_pref("gizmo_move"))
	gizmo.show_rotate = bool(settings.get_pref("gizmo_rotate"))
	gizmo.show_scale = bool(settings.get_pref("gizmo_scale"))
	set_force_draw_over_forwarding_enabled()
	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	scene_changed.connect(_on_scene_changed)
	scene_closed.connect(func(_p): exit_edit())
	set_process(true)

func _exit_tree() -> void:
	exit_edit()
	if redo != null:
		redo.hide()
	if local_view.active:
		local_view.exit()
	if EditorInterface.get_selection().selection_changed.is_connected(_on_selection_changed):
		EditorInterface.get_selection().selection_changed.disconnect(_on_selection_changed)
	ui.teardown()
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, uv_panel)
	uv_panel.queue_free()
	overlay.free_all()

func _handles(object: Object) -> bool:
	return object is Node3D

func _build() -> bool:
	exit_edit()   # running the game: leave Edit Mode with a complete mesh
	return true

func _save_external_data() -> void:
	if session != null and session.is_valid():
		session.rebuild(false)
		var res: Resource = session.target_resource()
		if res.resource_path != "" and not res.resource_path.contains("::"):
			ResourceSaver.save(res)

func _process(delta: float) -> void:
	if redo != null:
		if redo.is_current() and not modal.active and not vmodal.active:
			redo.show_in(_view_host())
		elif redo.panel != null:
			redo.hide()
	if session != null and (not session.is_valid() or session.current_node_resource() != session.target_resource()):
		_abort_edit()
	if local_view.active:
		_lv_accum += delta
		if _lv_accum > 0.5:
			_lv_accum = 0.0
			local_view.refresh()
	if _message != "" and Time.get_ticks_msec() > _message_until:
		_message = ""
		update_overlays()

## Called by the save guard right before / after Godot writes the scene.
func _on_pre_save() -> void:
	if _locked_node != null and is_instance_valid(_locked_node):
		_locked_node.remove_meta("_edit_lock_")
	for o in _extra_locked:
		if is_instance_valid(o):
			o.remove_meta("_edit_lock_")
	_save_external_data()

func _on_post_save() -> void:
	if _locked_node != null and is_instance_valid(_locked_node) and session != null:
		_locked_node.set_meta("_edit_lock_", true)
		for o in _extra_locked:
			if is_instance_valid(o):
				o.set_meta("_edit_lock_", true)

## Godot hides its transform gizmo for locked nodes: lock the edited node while
## in Edit Mode (Blender shows no object gizmo there). Re-selecting refreshes
## the gizmo. The lock is ours only if the node was not locked already.
func _set_gizmo_lock(n: Node3D, on: bool) -> void:
	if on:
		if n.has_meta("_edit_lock_"):
			return
		n.set_meta("_edit_lock_", true)
		_locked_node = n
	else:
		for o in _extra_locked:
			if is_instance_valid(o) and o.has_meta("_edit_lock_"):
				o.remove_meta("_edit_lock_")
		_extra_locked.clear()
		if _locked_node == null or not is_instance_valid(_locked_node):
			_locked_node = null
			return
		_locked_node.remove_meta("_edit_lock_")
		n = _locked_node
		_locked_node = null
	var sel := EditorInterface.get_selection()
	if sel.get_selected_nodes().has(n):
		sel.remove_node(n)
		sel.add_node(n)

func _on_selection_changed() -> void:
	if session == null:
		return
	if not EditorInterface.get_selection().get_selected_nodes().has(session.node):
		exit_edit()

func _on_scene_changed(_root: Node) -> void:
	exit_edit()
	if local_view.active:
		local_view.exit()
		update_overlays()

func msg(text: String, seconds := 3.0) -> void:
	_message = text
	_message_until = Time.get_ticks_msec() + int(seconds * 1000.0)
	update_overlays()


# ==============================================================================
# Edit Mode
# ==============================================================================

func _selected_editable() -> Node3D:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	for n in nodes:
		if n is MeshInstance3D or n is CollisionShape3D:
			return n
	return null

## Edit Mode on a CollisionShape3D with a Convex / Concave shape.
func _shape_edit_mesh(cs: CollisionShape3D):
	if cs.shape == null:
		msg("This CollisionShape3D has no shape")
		return null
	if not PfShape.supports(cs.shape):
		msg("Only ConvexPolygonShape3D and ConcavePolygonShape3D can be edited (%s has its own handles)" % cs.shape.get_class(), 5.0)
		return null
	var m = PfShape.read(cs.shape)
	if m == null:
		msg("This shape has no volume to edit")
	return m

func enter_edit(target: Node3D = null) -> bool:
	if session != null:
		return true
	if target == null:
		var many := _selected_meshes()
		if many.size() >= 2:
			return _enter_multi(many)
		target = _selected_editable()
	if target == null:
		msg("Select a MeshInstance3D or a CollisionShape3D to enter Edit Mode")
		return false
	if target is CollisionShape3D:
		var sm = _shape_edit_mesh(target)
		if sm == null:
			return false
		return _start_session(target, sm)
	var mi := target as MeshInstance3D
	var m = null
	if mi.mesh is ArrayMesh and mi.mesh.has_meta(PfMesh.META_KEY):
		m = PfMesh.new()
		if not m.from_dict(mi.mesh.get_meta(PfMesh.META_KEY)):
			msg("Polyforge data on this mesh is from an unknown version")
			return false
	elif mi.mesh != null and PfPrim.supports(mi.mesh):
		m = PfPrim.from_godot(mi.mesh)
		m.world_uv = settings.world_uv_default()
		if m.world_uv:
			PfUv.cube_project_world(m, settings.density_for(m))
		var am := PfBuild.build(m)
		var ur := get_undo_redo()
		ur.create_action("Polyforge: Make %s editable" % mi.mesh.get_class(), UndoRedo.MERGE_DISABLE, mi)
		ur.add_do_property(mi, "mesh", am)
		ur.add_undo_property(mi, "mesh", mi.mesh)
		ur.commit_action()
	elif mi.mesh == null:
		msg("This MeshInstance3D has no mesh — use Polyforge → Add Mesh")
		return false
	else:
		msg("This mesh was not made with Polyforge (importing other meshes comes in a later stage)", 5.0)
		return false
	return _start_session(mi, m)

## Multi-object edit (Blender 2.8+): all selected meshes in one Edit Mode;
## the last selected one is active.
func _enter_multi(meshes: Array) -> bool:
	var convert := []
	for mi in meshes:
		if not ((mi as MeshInstance3D).mesh is ArrayMesh and (mi as MeshInstance3D).mesh.has_meta(PfMesh.META_KEY)):
			convert.append(mi)
	if not convert.is_empty():
		var ur := get_undo_redo()
		ur.create_action("Polyforge: Make editable", UndoRedo.MERGE_DISABLE, EditorInterface.get_edited_scene_root())
		for mi in convert:
			var pm = PfPrim.from_godot((mi as MeshInstance3D).mesh)
			ur.add_do_property(mi, "mesh", PfBuild.build(pm))
			ur.add_undo_property(mi, "mesh", (mi as MeshInstance3D).mesh)
		ur.commit_action()
	var active: MeshInstance3D = meshes[meshes.size() - 1]
	var combined = PfMesh.new()
	var inv := active.global_transform.affine_inverse()
	for i in meshes.size():
		var mi: MeshInstance3D = meshes[i]
		var mm = _read_pf(mi)
		if i == meshes.size() - 1:
			combined.world_uv = mm.world_uv
			combined.texel_density = mm.texel_density
		var first: int = combined.faces.size()
		PfOps2.join_into(combined, mm, inv * mi.global_transform)
		for fi in range(first, combined.faces.size()):
			combined.face_tag[fi] = i
	return _start_session(active, combined, meshes)

func _start_session(mi: Node3D, m, members: Array = []) -> bool:
	session = PfSession.new()
	if members.size() > 1:
		session.start_multi(self, members, m)
	else:
		session.start(self, mi, m)
	_set_gizmo_lock(mi, true)
	for o in members:
		if o != mi and not (o as Node).has_meta("_edit_lock_"):
			(o as Node).set_meta("_edit_lock_", true)
			_extra_locked.append(o)
	_guard = PfSaveGuard.new()
	_guard.name = "PolyforgeSaveGuard"
	_guard.pre_save = _on_pre_save
	_guard.post_save = _on_post_save
	mi.add_child(_guard, false, Node.INTERNAL_MODE_BACK)
	session.mode = last_mode
	session.changed.connect(_on_session_changed)
	overlay.create(mi.get_world_3d().scenario)
	_apply_overlays()
	_apply_focus()
	uv_panel.session = session
	_apply_tab()
	ui.sync()
	update_overlays()
	return true

func exit_edit() -> void:
	if session == null:
		return
	if modal.active:
		modal.cancel()
	if vmodal.active:
		vmodal._finish(false)
	if _region != "":
		_end_region(false)
	last_mode = session.mode
	session.finish()
	_abort_edit()

## Drops the session without writing (node gone / mesh replaced by undo).
func _abort_edit() -> void:
	_lc = {}
	if focus != null:
		focus.disable()
	_set_gizmo_lock(null, false)
	if _guard != null and is_instance_valid(_guard):
		_guard.get_parent().remove_child(_guard)
		_guard.queue_free()
	_guard = null
	if session != null and session.changed.is_connected(_on_session_changed):
		session.changed.disconnect(_on_session_changed)
	session = null
	overlay.free_all()
	uv_panel.session = null
	_apply_tab()
	ui.sync()
	update_overlays()

func _on_session_changed() -> void:
	if session == null:
		return
	if session.note != "":
		msg(session.note, 4.0)
		session.note = ""
	overlay.update(session)
	uv_panel.queue_redraw()
	update_overlays()

## Undo / redo in multi-object edit: the combined snapshot is split back
## into the objects (works also after leaving Edit Mode).
func _pf_restore_multi(ids: Array, xfs: Array, snap: Dictionary) -> void:
	var active = instance_from_id(ids[ids.size() - 1])
	if session != null and session.node == active and session.is_multi():
		session.restore(snap)
		ui.sync()
		return
	var m = PfMesh.new()
	m.from_dict(snap["mesh"])
	var to_local := []
	for x in xfs:
		to_local.append((x as Transform3D).affine_inverse())
	var parts: Array = PfOps2.split_by_tags(m, ids.size(), to_local, ids.size() - 1)
	for i in ids.size():
		var n = instance_from_id(ids[i])
		if n is MeshInstance3D and (n as MeshInstance3D).mesh is ArrayMesh:
			PfBuild.build(parts[i], (n as MeshInstance3D).mesh)

## Undo / redo target for every Polyforge edit (whole-mesh snapshots).
func _pf_restore(node_id: int, snap: Dictionary) -> void:
	var n = instance_from_id(node_id)
	if n == null or not (n is MeshInstance3D or n is CollisionShape3D):
		return
	if session != null and session.node == n:
		session.restore(snap)
		ui.sync()
		return
	if n is CollisionShape3D:
		if PfShape.supports((n as CollisionShape3D).shape):
			var sm = PfMesh.new()
			sm.from_dict(snap["mesh"])
			PfShape.write((n as CollisionShape3D).shape, sm)
		return
	if (n as MeshInstance3D).mesh is ArrayMesh:
		var m = PfMesh.new()
		m.from_dict(snap["mesh"])
		PfBuild.build(m, (n as MeshInstance3D).mesh)

func _apply_tab() -> void:
	var show: bool = session != null and tab == 1 and not session.is_shape()
	if uv_panel.visible and not show:
		settings.set_pref("uv_panel_width", int(uv_panel.size.x))
	if show and not uv_panel.visible:
		uv_panel.custom_minimum_size.x = maxf(200.0, float(settings.get_pref("uv_panel_width")))
		uv_panel.visible = true
		uv_panel.frame_unit.call_deferred()
	elif not show:
		uv_panel.visible = false
	uv_panel.queue_redraw()


# ==============================================================================
# Input
# ==============================================================================

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	var r := _forward_impl(camera, event)
	if r == STOP:
		# Godot's 3D viewport stops its own handling on STOP but does not mark
		# the event as handled, so e.g. Tab would still move the GUI focus away
		# from the viewport (and later keys would no longer reach it).
		var vp := EditorInterface.get_base_control().get_viewport()
		if vp != null:
			vp.set_input_as_handled()
	return r

func _forward_impl(camera: Camera3D, event: InputEvent) -> int:
	_camera = camera
	if event is InputEventMouse:
		_mouse = (event as InputEventMouse).position
	if modal.active:
		modal.handle_input(camera, event)
		update_overlays()
		return STOP
	if modal.swallow_lmb_release and event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		modal.swallow_lmb_release = false
		return STOP
	if vmodal.active:
		vmodal.handle_input(event)
		update_overlays()
		return STOP
	if not _lc.is_empty():
		return _loopcut_input(camera, event)
	if vmodal.swallow_lmb_release and event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		vmodal.swallow_lmb_release = false
		return STOP
	if _region != "":
		return _region_input(camera, event)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		return _rmb_input(camera, event)
	if event is InputEventKey:
		return _key_input(camera, event)
	if session == null:
		return PASS
	return _edit_mouse_input(camera, event)

func _key_input(_cam: Camera3D, k: InputEventKey) -> int:
	if _rmb_down:
		return PASS   # Godot freelook (WASD) while the right button is held
	if PfKeymap._code(k) == KEY_F and Time.get_ticks_msec() < _pass_f_until:
		return PASS   # our own Focus Selection request (Local View)
	var g := PfKeymap.find(PfKeymap.GLOBAL, k)
	if g != "":
		if k.pressed and not k.echo:
			run_action(g)
		return STOP
	if session != null:
		var a := PfKeymap.find(PfKeymap.EDIT, k)
		if a != "":
			if k.pressed and not k.echo:
				run_action(a)
			return STOP
		if PfKeymap.is_passthrough(k) or (k.ctrl_pressed and PfKeymap._code(k) == KEY_TAB):
			return PASS
		return STOP   # Blender keymap owns the viewport in Edit Mode
	if bool(settings.get_pref("object_mode_shortcuts")):
		var a := PfKeymap.find(PfKeymap.OBJECT, k, settings.get_pref("object_keymap"))
		if a != "":
			if k.pressed and not k.echo:
				run_action(a)
			return STOP
	return PASS

func _rmb_input(camera: Camera3D, mb: InputEventMouseButton) -> int:
	if mb.pressed:
		_rmb_down = true
		_rmb_pos = mb.position
		_rmb_time = Time.get_ticks_msec()
		return PASS
	_rmb_down = false
	var click := Time.get_ticks_msec() - _rmb_time < RMB_CLICK_MS and mb.position.distance_to(_rmb_pos) < CLICK_DRAG_PX
	if session != null and click:
		if mb.shift_pressed:
			_place_cursor(camera, mb.position)
		elif bool(settings.get_pref("right_click_select")):
			_click_select(camera, mb)
		else:
			ui.popup_at(ui.context_menu, _screen_pos(camera, mb.position))
	return PASS

func _edit_mouse_input(camera: Camera3D, event: InputEvent) -> int:
	var rcs := bool(settings.get_pref("right_click_select"))
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed and _gizmo_drag(camera, mb.position):
			return STOP
		if mb.pressed:
			_lmb_down = true
			_lmb_pos = mb.position
			_box = false
			return STOP
		if _lmb_down:
			_lmb_down = false
			if _box:
				_box = false
				var op := "add" if mb.shift_pressed else ("sub" if mb.ctrl_pressed else "set")
				_apply_region_select(PfPicking.in_rect(session, camera, _box_rect), op, "Box Select")
				update_overlays()
			elif not rcs:
				_click_select(camera, mb)
		return STOP
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if not _lmb_down and gizmo.enabled():
			var h := _gizmo_pick(camera, mm.position)
			var hid: String = h.get("id", "")
			if hid != _gizmo_hover:
				_gizmo_hover = hid
				update_overlays()
		if _lmb_down:
			if not _box and mm.position.distance_to(_lmb_pos) > CLICK_DRAG_PX:
				_box = true
			if _box:
				_box_rect = Rect2(_lmb_pos, mm.position - _lmb_pos).abs()
				update_overlays()
				return STOP
	return PASS

## The focusable control of the 3D viewport that shows `camera` (Godot sends
## keys to the viewport only while it has keyboard focus).
func _viewport_surface(camera: Camera3D) -> Control:
	if camera == null:
		return null
	var vp := camera.get_viewport()
	var container := vp.get_parent() as Control if vp != null else null
	var view := container.get_parent() as Control if container != null else null
	if view == null:
		return null
	for c in view.find_children("*", "Control", true, false):
		if c.get_class() == "Control" and (c as Control).focus_mode != Control.FOCUS_NONE:
			return c
	return null

# ==============================================================================
# Transform Orientation / gizmo
# ==============================================================================

## World axes of the current Transform Orientation.
func orient_basis(camera: Camera3D = null) -> Basis:
	var node: Node3D = session.node if session != null else null
	if node == null:
		for n in EditorInterface.get_selection().get_top_selected_nodes():
			if n is Node3D:
				node = n
				break
	return PfOrient.basis(orientation, session, node, camera if camera != null else _camera)

## Gizmo origin (world) for the current selection, or null.
func _gizmo_origin() -> Variant:
	if session == null or not gizmo.enabled():
		return null
	var p = PfModal.selection_pivot(session, pivot_mode)
	if p == null:
		return null
	return session.node.global_transform * (p as Vector3)

func _gizmo_pick(camera: Camera3D, pos: Vector2) -> Dictionary:
	var o = _gizmo_origin()
	if o == null or camera == null:
		return {}
	return gizmo.pick(camera, o, orient_basis(camera), pos)

## LMB on a gizmo handle: modal transform with that constraint, confirmed on
## release.
func _gizmo_drag(camera: Camera3D, pos: Vector2) -> bool:
	var h := _gizmo_pick(camera, pos)
	if h.is_empty():
		return false
	var mode: int = {"move": PfModal.Mode.MOVE, "rotate": PfModal.Mode.ROTATE, "scale": PfModal.Mode.SCALE}[h["op"]]
	_configure_modal()
	if not modal.begin_elements(mode, camera, pos, session):
		return false
	modal.drag_confirm = true
	match h["con"]:
		"axis": modal.preset_constraint(PfModal.Constraint.AXIS, h["axis"])
		"plane": modal.preset_constraint(PfModal.Constraint.PLANE, h["axis"])
	update_overlays()
	return true

func _configure_modal() -> void:
	modal.snap_increment = float(settings.get_pref("snap_increment"))
	modal.orient_name = orientation
	modal.orient_basis = orient_basis()
	if session != null:
		modal.uv_world = session.mesh.world_uv
		modal.uv_correct = session.mesh.world_uv or bool(settings.get_pref("correct_face_attributes"))
		modal.pivot_mode = pivot_mode
	for k in ["prop_connected", "prop_falloff", "prop_size"]:
		modal.set(k, settings.get_pref(k))
	modal.prop_enabled = bool(settings.get_pref("proportional"))
	modal.mirror_axes = settings.get_pref("mirror_axes").duplicate()
	modal.snap_on = bool(settings.get_pref("snap_on"))
	modal.snap_target = str(settings.get_pref("snap_target"))

func _screen_pos(camera: Camera3D, local: Vector2) -> Vector2:
	var vp := camera.get_viewport()
	var c := vp.get_parent() as Control if vp != null else null
	return (c.get_screen_position() if c != null else Vector2.ZERO) + local


# ==============================================================================
# Selection
# ==============================================================================

func _click_select(camera: Camera3D, mb: InputEventMouseButton) -> void:
	var before: Dictionary = session.snapshot()
	if mb.alt_pressed:
		var elems := _loop_elements(camera, mb.position, mb.ctrl_pressed)
		if elems.is_empty():
			return
		if mb.shift_pressed:
			session.select_many(elems, "add")
		else:
			session.select_many(elems, "set")
	else:
		session.click_select(PfPicking.pick(session, camera, mb.position), mb.shift_pressed)
	_commit_selection("Select", before)

## Alt+click loop (Ctrl+Alt+click ring) as elements of the current mode.
func _loop_elements(camera: Camera3D, pos: Vector2, ring: bool) -> Array:
	var m = session.mesh
	var edge = null
	if session.mode == PfSession.FACE:
		var f = PfPicking.pick_face(session, camera, pos)
		if f != null:
			edge = PfPicking.nearest_edge_of_face(session, camera, pos, f)
	else:
		edge = PfPicking.pick_edge(session, camera, pos)
	if edge == null:
		return []
	var out := []
	if session.mode == PfSession.FACE:
		var faces: Dictionary = PfSelect.face_loop(m, edge) if not ring else PfSelect.edge_ring(m, edge)["faces"]
		return faces.keys()
	var edges: Array = PfSelect.edge_ring(m, edge)["edges"] if ring else PfSelect.edge_loop(m, edge)
	if session.mode == PfSession.EDGE:
		return edges
	var vs := {}
	for e in edges:
		vs[e.x] = true
		vs[e.y] = true
	out = vs.keys()
	return out

func _apply_region_select(elems: Array, op: String, label: String) -> void:
	var before: Dictionary = session.snapshot()
	session.select_many(elems, op)
	_commit_selection(label, before)

## Selection changes are undo steps too (like Blender).
func _commit_selection(label: String, before: Dictionary) -> void:
	var now: Dictionary = session.snapshot()
	if now["sel_v"] == before["sel_v"] and now["sel_e"] == before["sel_e"] and now["sel_f"] == before["sel_f"] and now["mode"] == before["mode"]:
		return
	var ur := get_undo_redo()
	ur.create_action("Polyforge: " + label, UndoRedo.MERGE_DISABLE, session.node)
	ur.add_do_method(self, "_pf_select_restore", session.node.get_instance_id(), now)
	ur.add_undo_method(self, "_pf_select_restore", session.node.get_instance_id(), before)
	ur.commit_action(false)

## Selection-only undo: restores selection (and mesh only if it differs).
func _pf_select_restore(node_id: int, snap: Dictionary) -> void:
	if session == null or session.node == null or session.node.get_instance_id() != node_id:
		return
	session.mode = int(snap["mode"])
	session.sel_v = (snap["sel_v"] as Dictionary).duplicate()
	session.sel_e = (snap["sel_e"] as Dictionary).duplicate()
	session.sel_f = (snap["sel_f"] as Dictionary).duplicate()
	session.history = (snap["history"] as Array).duplicate()
	session._selection_changed()
	ui.sync()

func _linked_elements(seed_faces: Dictionary) -> Array:
	return _faces_in_mode(PfSelect.linked_faces(session.mesh, seed_faces, true, session.hidden_face_set()))

func _faces_in_mode(faces: Dictionary) -> Array:
	match session.mode:
		PfSession.VERTEX: return PfSelect.faces_to_verts(session.mesh, faces).keys()
		PfSession.EDGE: return PfSelect.faces_to_edges(session.mesh, faces).keys()
	return faces.keys()

func _faces_of(elem) -> Dictionary:
	var out := {}
	if elem == null:
		return out
	match session.mode:
		PfSession.VERTEX:
			for f in session.mesh.vert_faces(elem):
				out[f] = true
		PfSession.EDGE:
			for f in session.mesh.edge_faces(elem):
				out[f] = true
		PfSession.FACE:
			out[elem] = true
	return out


# ==============================================================================
# Box / circle select (B / C)
# ==============================================================================

func _start_region(kind: String) -> void:
	_region = kind
	_region_drag = false
	_region_before = session.snapshot()
	update_overlays()

func _end_region(commit: bool) -> void:
	var kind := _region
	_region = ""
	_region_drag = false
	_circle_paint = 0
	if commit and session != null:
		_commit_selection("Box Select" if kind == "box" else "Circle Select", _region_before)
	update_overlays()

func _region_input(camera: Camera3D, event: InputEvent) -> int:
	if session == null:
		_region = ""
		return PASS
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and k.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
			_end_region(_region == "circle")
		return STOP
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_end_region(_region == "circle")
			return STOP
		if _region == "circle" and mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_circle_radius = clampf(_circle_radius * (0.9 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1), 5.0, 500.0)
			update_overlays()
			return STOP
		if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
			var sub := mb.button_index == MOUSE_BUTTON_MIDDLE or mb.shift_pressed
			if _region == "box":
				if mb.pressed:
					_region_drag = true
					_region_op = "sub" if sub else "add"
					_lmb_pos = mb.position
					_box_rect = Rect2(mb.position, Vector2.ZERO)
				elif _region_drag:
					session.select_many(PfPicking.in_rect(session, camera, _box_rect), _region_op)
					_end_region(true)
			else:
				_circle_paint = (-1 if sub else 1) if mb.pressed else 0
				if mb.pressed:
					_circle_apply(camera)
			update_overlays()
			return STOP
		return STOP
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _region == "box" and _region_drag:
			_box_rect = Rect2(_lmb_pos, mm.position - _lmb_pos).abs()
		elif _region == "circle" and _circle_paint != 0:
			_circle_apply(camera)
		update_overlays()
		return STOP
	return STOP

func _circle_apply(camera: Camera3D) -> void:
	session.select_many(PfPicking.in_circle(session, camera, _mouse, _circle_radius), "sub" if _circle_paint < 0 else "add")


# ==============================================================================
# Actions
# ==============================================================================

func run_action(action: String, arg: Variant = null) -> void:
	match action:
		"toggle_edit":
			if session != null:
				exit_edit()
			else:
				enter_edit()
		"local_view":
			_toggle_local_view()
		"tab":
			tab = int(arg)
			settings.set_pref("last_tab", tab)
			_apply_tab()
			ui.sync()
		"next_tab", "prev_tab":
			run_action("tab", (tab + 1) % 2)
		"add_object":
			if session != null:
				run_action("add_mesh_pick", arg)
			else:
				_add_object(str(arg))
		"add_mesh_pick":
			if session != null:
				_add_into_mesh(str(arg))
			else:
				_add_object(str(arg))
		"obj_add", "add_mesh":
			if _camera != null:
				ui.popup_at(ui.add_menu, _screen_pos(_camera, _mouse))
		"settings":
			ui.open_settings()
		"obj_grab", "obj_rotate", "obj_scale":
			_begin_object_modal({"obj_grab": PfModal.Mode.MOVE, "obj_rotate": PfModal.Mode.ROTATE, "obj_scale": PfModal.Mode.SCALE}[action])
		"obj_delete":
			_delete_objects()
		"obj_join":
			_join_objects()
		"obj_boolean":
			_boolean_objects(str(arg))
		"focus", "focus_set":
			var on: bool = not bool(settings.get_pref("focus_mode")) if action == "focus" else bool(arg)
			settings.set_pref("focus_mode", on)
			_apply_focus()
			ui.sync()
		"orientation":
			orientation = str(arg)
			settings.set_pref("orientation", orientation)
			ui.sync()
			update_overlays()
		"gizmo_set":
			gizmo.set("show_" + str(arg[0]), bool(arg[1]))
			_save_gizmo_prefs()
		"obj_duplicate":
			_duplicate_objects()
	if session == null:
		return
	# ---------------- Edit Mode actions ----------------
	var before: Dictionary = {}
	match action:
		"mode_vertex", "mode_edge", "mode_face", "set_mode":
			var m: int = arg if action == "set_mode" else {"mode_vertex": 1, "mode_edge": 2, "mode_face": 3}[action]
			before = session.snapshot()
			session.set_mode(m)
			last_mode = m
			_commit_selection("Select Mode", before)
			ui.sync()
		"select_all", "select_none", "select_invert":
			before = session.snapshot()
			match action:
				"select_all": session.select_all()
				"select_none": session.deselect_all()
				_: session.invert()
			_commit_selection(PfKeymap.LABELS[action], before)
		"box_select":
			_start_region("box")
		"circle_select":
			_start_region("circle")
		"select_linked_pick", "deselect_linked_pick":
			if _camera != null:
				before = session.snapshot()
				var e = PfPicking.pick(session, _camera, _mouse)
				if e != null:
					session.select_many(_linked_elements(_faces_of(e)), "sub" if action == "deselect_linked_pick" else "add")
					_commit_selection("Select Linked", before)
		"select_linked":
			before = session.snapshot()
			session.select_many(_linked_elements(PfSelect.faces_with_any_vert(session.mesh, session.selected_verts())), "add")
			_commit_selection("Select Linked", before)
		"select_more", "select_less":
			before = session.snapshot()
			_grow_shrink(action == "select_more")
			_commit_selection(PfKeymap.LABELS[action], before)
		"hide", "hide_unselected":
			before = session.snapshot()
			session.hide(action == "hide_unselected")
			_commit_selection("Hide", before)
		"reveal":
			session.reveal()
		"xray":
			session.xray = not session.xray
			session.changed.emit()
			ui.sync()
		"xray_set":
			session.xray = bool(arg)
			session.changed.emit()
			ui.sync()
		"grab", "rotate", "scale":
			_begin_element_modal({"grab": PfModal.Mode.MOVE, "rotate": PfModal.Mode.ROTATE, "scale": PfModal.Mode.SCALE}[action])
		"proportional", "prop_connected":
			settings.set_pref(action, not bool(settings.get_pref(action)) if arg == null else bool(arg))
			msg("Proportional Editing: %s" % ("on" if settings.get_pref("proportional") else "off"))
			ui.sync()
		"prop_falloff_menu":
			var items := []
			for f in PfUi.FALLOFFS:
				items.append([f[1], "prop_falloff", f[0]])
			_menu_at("Proportional Falloff", items)
		"prop_falloff":
			settings.set_pref("prop_falloff", str(arg))
			ui.sync()
		"mirror_menu":
			_menu_at("Mirror", [["X Global", "mirror", [0, false]], ["Y Global", "mirror", [1, false]], ["Z Global", "mirror", [2, false]], ["-"],
				["X Local", "mirror", [0, true]], ["Y Local", "mirror", [1, true]], ["Z Local", "mirror", [2, true]]])
		"mirror":
			_mirror_selection(int(arg[0]), bool(arg[1]))
		"symmetry":
			var axes: Array = settings.get_pref("mirror_axes").duplicate()
			axes[int(arg)] = not axes[int(arg)]
			settings.set_pref("mirror_axes", axes)
			ui.sync()
		"snap_toggle":
			settings.set_pref("snap_on", not bool(settings.get_pref("snap_on")))
			msg("Snapping: %s (%s)" % ["on" if settings.get_pref("snap_on") else "off", settings.get_pref("snap_target")])
			ui.sync()
		"snap_target_menu":
			var items := []
			for t in PfUi.SNAP_TARGETS:
				items.append([t[1], "snap_target", t[0]])
			_menu_at("Snap To", items)
		"snap_target":
			settings.set_pref("snap_target", str(arg))
			ui.sync()
		"overlay":
			settings.set_pref(str(arg), not bool(settings.get_pref(str(arg))))
			_apply_overlays()
			ui.sync()
		"snap_menu":
			_menu_at("Snap", [["Selection to Cursor", "snap", "sel_cursor"], ["Selection to Cursor (Keep Offset)", "snap", "sel_cursor_offset"],
				["Selection to Active", "snap", "sel_active"], ["-"], ["Cursor to Selected", "snap", "cursor_sel"],
				["Cursor to World Origin", "snap", "cursor_origin"], ["Cursor to Active", "snap", "cursor_active"]])
		"snap":
			_snap(str(arg))
		"pivot_menu":
			if _camera != null:
				ui.popup_pivot(_screen_pos(_camera, _mouse))
		"pivot":
			pivot_mode = str(arg)
			ui.sync()
			update_overlays()
		"orientation_menu":
			if _camera != null:
				ui.popup_orientation(_screen_pos(_camera, _mouse))
		"toggle_gizmo":
			if gizmo.enabled():
				gizmo.show_move = false
				gizmo.show_rotate = false
				gizmo.show_scale = false
			else:
				gizmo.show_move = true
			_save_gizmo_prefs()
		"context_menu_w":
			if bool(settings.get_pref("right_click_select")) and _camera != null:
				ui.popup_at(ui.context_menu, _screen_pos(_camera, _mouse))
		"shade_smooth", "shade_flat":
			before = session.snapshot()
			for fi in session.selected_faces():
				session.mesh.face_smooth[fi] = 1 if action == "shade_smooth" else 0
			session.commit_undo("Shade Smooth" if action == "shade_smooth" else "Shade Flat", before)
		"mark_sharp", "clear_sharp":
			before = session.snapshot()
			for e in session.selected_edges():
				if action == "mark_sharp":
					session.mesh.sharp_edges[e] = true
				else:
					session.mesh.sharp_edges.erase(e)
			session.commit_undo("Mark Sharp" if action == "mark_sharp" else "Clear Sharp", before)
		"correct_face_attributes":
			settings.set_pref("correct_face_attributes", bool(arg))
		"world_uv":
			before = session.snapshot()
			session.mesh.world_uv = bool(arg)
			if session.mesh.world_uv:
				PfUv.cube_project_world(session.mesh, settings.density_for(session.mesh))
			session.commit_undo("World-Scale UV", before)
			msg("World-Scale UV %s" % ("on: UVs projected at %d px/m" % settings.density_for(session.mesh) if bool(arg) else "off"))
		"texel_density":
			before = session.snapshot()
			session.mesh.texel_density = float(arg)
			if session.mesh.world_uv:
				PfUv.cube_project_world(session.mesh, settings.density_for(session.mesh))
			session.commit_undo("Texel Density", before)
			ui.sync()
		"save_mesh_as":
			_save_mesh_as(str(arg))
		"delete_menu":
			_menu_at("Delete", [["Vertices", "delete", "verts"], ["Edges", "delete", "edges"], ["Faces", "delete", "faces"],
				["Only Edges & Faces", "delete", "edges_faces"], ["Only Faces", "delete", "only_faces"], ["-"],
				["Dissolve Vertices", "dissolve", 1], ["Dissolve Edges", "dissolve", 2], ["Dissolve Faces", "dissolve", 3]])
		"delete":
			_op("Delete " + str(arg).capitalize(), func(m): return PfOps.delete(m, str(arg), session.selected_verts(), session.selected_edges(), session.selected_faces()))
		"dissolve":
			var dm: int = int(arg) if arg != null else session.mode
			match dm:
				1: _op("Dissolve Vertices", func(m): return PfOps.dissolve_verts(m, session.selected_verts()))
				2: _op("Dissolve Edges", func(m): return PfOps.dissolve_edges(m, session.selected_edges()))
				_: _op("Dissolve Faces", func(m): return PfOps.dissolve_faces(m, session.selected_faces()))
		"merge_menu":
			var vm: bool = session.mode == PfSession.VERTEX and session.history.size() >= 2
			_menu_at("Merge", [["At Center", "merge", ["center"]], ["At First", "merge", ["first"], vm], ["At Last", "merge", ["last"], vm],
				["Collapse", "merge", ["collapse"]], ["-"], ["By Distance…", "merge_distance_dialog", null]])
		"merge_distance_dialog":
			ui.popup_merge_distance()
		"merge":
			_merge(arg)
		"extrude":
			_extrude("region")
		"extrude_menu":
			_menu_at("Extrude", [["Extrude Faces", "extrude_kind", "region"], ["Extrude Faces Along Normals", "extrude_kind", "normals"],
				["Extrude Individual Faces", "extrude_kind", "individual"], ["-"], ["Extrude Edges Only", "extrude_kind", "edges"],
				["Extrude Vertices Only", "extrude_kind", "verts"]])
		"extrude_kind":
			_extrude(str(arg))
		"inset":
			_inset()
		"fatten":
			_fatten({}, "Shrink/Fatten")
		"duplicate":
			_duplicate()
		"make_face":
			var vb: Vector3 = (session.node.global_transform.basis.inverse() * (_camera.global_transform.basis.z if _camera else Vector3.BACK)).normalized()
			_op("Make Edge/Face", func(m): return PfOps.make_edge_face(m, session.selected_verts(), session.selected_edges(), vb, session.selected_faces()))
		"recalc_outside", "recalc_inside":
			var sf: Dictionary = session.selected_faces()
			if sf.is_empty():
				msg("Select faces")
			else:
				_op("Recalculate Normals", func(m):
					PfOps.recalc_normals(m, sf, action == "recalc_inside")
					return {"faces": sf})
		"flip":
			var sf2: Dictionary = session.selected_faces()
			_op("Flip Normals", func(m):
				PfOps.flip(m, sf2)
				return {"faces": sf2})
		"normals_menu":
			_menu_at("Normals", [["Flip", "flip", null], ["Recalculate Outside", "recalc_outside", null], ["Recalculate Inside", "recalc_inside", null]])
		"triangulate":
			_op("Triangulate Faces", func(m): return PfOps.triangulate(m, session.selected_faces()))
		"tris_to_quads":
			_op("Tris to Quads", func(m): return PfOps.tris_to_quads(m, session.selected_faces()))
		"smooth_verts":
			var sv: Dictionary = session.selected_verts()
			var sp: Dictionary = arg if arg is Dictionary else {"factor": 0.5, "repeat": 1}
			_op("Smooth Vertices", func(m):
				PfOps.smooth_verts(m, sv, float(sp["factor"]), int(sp["repeat"]))
				return {"verts": sv})
			_redo("Smooth Vertices", [["factor", "Smoothing", "float", sp["factor"], 0.0, 1.0], ["repeat", "Repeat", "int", sp["repeat"], 1, 100]],
				func(v): run_action("smooth_verts", v))
		"uv_menu":
			var pos: Vector2 = arg if arg is Vector2 else (_screen_pos(_camera, _mouse) if _camera else Vector2.ZERO)
			ui.popup_ops("UV Unwrap (%s)" % ("UV2" if uv_panel.channel == 1 else "UV1"), [["Unwrap", "uv_op", "unwrap"], ["Smart UV Project", "uv_op", "smart"], ["-"],
				["Cube Projection", "uv_op", "cube"], ["Cylinder Projection", "uv_op", "cylinder"], ["Sphere Projection", "uv_op", "sphere"], ["-"],
				["Project from View", "uv_op", "view"], ["Project from View (Bounds)", "uv_op", "view_bounds"], ["-"], ["Reset", "uv_op", "reset"],
				["Lightmap Pack", "uv_op", "lightmap"], ["-"], ["Pack Islands", "uv_pack", null], ["Average Islands Scale", "uv_average", null], ["-"],
				["Texel Density: 128 px/m", "uv_density", 128.0], ["Texel Density: 256 px/m", "uv_density", 256.0],
				["Texel Density: 512 px/m", "uv_density", 512.0], ["Texel Density: Project Default", "uv_density", 0.0]], pos)
		"uv_snap_menu":
			var pos: Vector2 = arg if arg is Vector2 else Vector2.ZERO
			ui.popup_ops("UV Snap", [["Selected to Pixels", "uv_snap", "selected_to_pixels"], ["Selected to Cursor", "uv_snap", "selected_to_cursor"],
				["Selected to Cursor (Offset)", "uv_snap", "selected_to_cursor_offset"], ["Selected to Adjacent Unselected", "uv_snap", "selected_to_adjacent"], ["-"],
				["Cursor to Pixels", "uv_snap", "cursor_to_pixels"], ["Cursor to Origin", "uv_snap", "cursor_to_origin"], ["Cursor to Selected", "uv_snap", "cursor_to_selected"]], pos)
		"uv_snap":
			uv_panel.snap_op(str(arg))
		"uv_pivot_menu":
			var pos: Vector2 = arg if arg is Vector2 else Vector2.ZERO
			var items := []
			for pv in uv_panel.PIVOTS:
				items.append([pv[1], "uv_pivot", pv[0]])
			ui.popup_ops("UV Pivot", items, pos)
		"uv_pivot":
			uv_panel.set_pivot(str(arg))
		"uv_density":
			var faces: Dictionary = session.selected_faces()
			if faces.is_empty():
				msg("Select faces first")
				return
			var ch: int = uv_panel.channel
			var px: float = float(arg) if float(arg) > 0.0 else float(settings.density_for(session.mesh))
			_op("Set Texel Density", func(m):
				for isl in PfUvOps.islands(m, ch, faces):
					PfUvOps.set_density(m, ch, isl, px)
				return {"faces": faces})
			_redo("Set Texel Density", [["px", "Texel Density (px/m)", "float", px, 1.0, 100000.0]], func(v): run_action("uv_density", v["px"]))
			uv_panel.queue_redraw()
		"uv_op":
			if arg is Array:
				_uv_op(str(arg[0]), arg[1])
			else:
				_uv_op(str(arg))
		"uv_pack", "uv_average":
			var faces: Dictionary = session.selected_faces()
			var ch: int = uv_panel.channel
			var world: bool = session.mesh.world_uv
			var pp: Dictionary = arg if arg is Dictionary else {"margin": 0.01, "rotate": true}
			_op("Pack Islands" if action == "uv_pack" else "Average Islands Scale", func(m):
				var isl: Array = PfUvOps.islands(m, ch, faces)
				if action == "uv_pack":
					PfUvOps.pack(m, ch, isl, not world, float(pp["margin"]), bool(pp["rotate"]))
				else:
					PfUvOps.average_scale(m, ch, isl)
				return {"faces": faces})
			if action == "uv_pack":
				_redo("Pack Islands", [["margin", "Margin", "float", pp["margin"], 0.0, 0.25], ["rotate", "Rotate", "bool", pp["rotate"]]],
					func(v): run_action("uv_pack", v))
			uv_panel.queue_redraw()
		"uv_pin":
			var on: bool = arg[0]
			var vs: Dictionary = arg[1]
			if vs.is_empty():
				msg("Select UVs to pin")
			else:
				before = session.snapshot()
				for v in vs:
					if on:
						session.mesh.uv_pins[v] = true
					else:
						session.mesh.uv_pins.erase(v)
				session.commit_undo("Pin" if on else "Unpin", before)
		"uv_copy_to_uv2":
			var faces2: Dictionary = session.selected_faces()
			_op("Copy UV1 to UV2", func(m):
				for f in faces2:
					PfUvOps.set_uv(m, 1, f, m.uvs[f].duplicate())
				return {"faces": faces2})
		"redo_panel":
			if not redo.is_current():
				msg("No operation to adjust")
		"mark_seam", "clear_seam":
			before = session.snapshot()
			for e in session.selected_edges():
				if action == "mark_seam":
					session.mesh.seam_edges[e] = true
				else:
					session.mesh.seam_edges.erase(e)
			session.commit_undo("Mark Seam" if action == "mark_seam" else "Clear Seam", before)
		"mat_slot_add", "mat_slot_remove", "mat_set", "mat_assign":
			if action == "mat_assign" and session.selected_faces().is_empty():
				msg("Select faces")
				return
			before = session.snapshot()
			match action:
				"mat_slot_add": active_slot = PfOps2.add_slot(session.mesh)
				"mat_slot_remove":
					PfOps2.remove_slot(session.mesh, active_slot)
					active_slot = maxi(active_slot - 1, 0)
				"mat_set": PfOps2.set_slot_material(session.mesh, active_slot, arg)
				"mat_assign": PfOps2.assign_slot(session.mesh, session.selected_faces(), active_slot)
			session.commit_undo({"mat_slot_add": "Add Material Slot", "mat_slot_remove": "Remove Material Slot",
				"mat_set": "Set Material", "mat_assign": "Assign Material"}[action], before)
			ui.sync()
		"mat_select", "mat_deselect":
			var fs := {}
			for fi in session.mesh.faces.size():
				if session.mesh.face_mat[fi] == active_slot and not session.is_face_hidden(fi):
					fs[fi] = true
			before = session.snapshot()
			session.select_many(_faces_in_mode(fs), "add" if action == "mat_select" else "sub")
			_commit_selection("Select Material" if action == "mat_select" else "Deselect Material", before)
		"select_similar_menu":
			var items := []
			for it in PfSelect.SIMILAR[session.mode]:
				items.append([it[0], "select_similar", it[1]])
			_menu_at("Select Similar", items)
		"select_similar":
			if session.primary().is_empty():
				msg("Nothing selected")
				return
			before = session.snapshot()
			session.select_many(PfSelect.similar(session.mesh, session.mode, session.primary(), str(arg)).keys().filter(func(x):
				match session.mode:
					PfSession.VERTEX: return not session.is_vert_hidden(x)
					PfSession.EDGE: return not (session.is_vert_hidden(x.x) or session.is_vert_hidden(x.y))
				return not session.is_face_hidden(x)), "add")
			_commit_selection("Select Similar", before)
		"vertex_menu":
			_menu_at("Vertex", [["Extrude Vertices", "extrude_kind", "verts"], ["Bevel Vertices", "bevel_verts", null], ["Connect Vertex Path", "connect_path", null], ["Make Edge/Face", "make_face", null], ["-"],
				["Merge at Center", "merge", ["center"]], ["Merge by Distance…", "merge_distance_dialog", null], ["Smooth Vertices", "smooth_verts", null],
				["-"], ["Dissolve Vertices", "dissolve", 1], ["Delete Vertices", "delete", "verts"]])
		"edge_menu":
			_menu_at("Edge", [["Extrude Edges", "extrude_kind", "edges"], ["Bevel Edges", "bevel", null], ["Loop Cut and Slide", "loopcut", null], ["-"], ["Mark Sharp", "mark_sharp", null], ["Clear Sharp", "clear_sharp", null],
				["Mark Seam", "mark_seam", null], ["Clear Seam", "clear_seam", null], ["-"], ["Dissolve Edges", "dissolve", 2], ["Delete Edges", "delete", "edges"]])
		"face_menu":
			_menu_at("Face", [["Extrude Faces", "extrude_kind", "region"], ["Extrude Faces Along Normals", "extrude_kind", "normals"],
				["Extrude Individual Faces", "extrude_kind", "individual"], ["Inset Faces", "inset", null], ["-"],
				["Shade Smooth", "shade_smooth", null], ["Shade Flat", "shade_flat", null], ["Flip", "flip", null], ["Recalculate Outside", "recalc_outside", null],
				["-"], ["Triangulate Faces", "triangulate", null], ["Tris to Quads", "tris_to_quads", null], ["Dissolve Faces", "dissolve", 3], ["Delete Faces", "delete", "faces"],
				["-"], ["Intersect (Boolean): Union", "boolean_edit", "union"], ["Intersect (Boolean): Difference", "boolean_edit", "difference"],
				["Intersect (Boolean): Intersect", "boolean_edit", "intersect"]])
		"search":
			if _camera != null:
				ui.open_search(_screen_pos(_camera, _mouse))
		"connect_path":
			var sv3: Dictionary = session.selected_verts()
			var order: Array = session.history.filter(func(x): return x is int and sv3.has(x))
			if order.size() < 2 and sv3.size() == 2:
				order = sv3.keys()
			_op("Connect Vertex Path", func(m): return PfOps2.connect_path(m, order))
		"loopcut":
			_lc = {"cuts": 1, "edge": null}
			if _camera != null:
				_lc["edge"] = PfPicking.pick_edge(session, _camera, _mouse)
			update_overlays()
		"bevel":
			_bevel(false)
		"bevel_verts":
			_bevel(true)
		"separate_menu":
			_menu_at("Separate", [["Selection", "separate", "selection"], ["By Loose Parts", "separate", "loose"], ["By Material", "separate", "material"]])
		"separate":
			_separate(str(arg))
		"boolean_edit":
			_boolean_edit(str(arg))

func _save_gizmo_prefs() -> void:
	settings.set_pref("gizmo_move", gizmo.show_move)
	settings.set_pref("gizmo_rotate", gizmo.show_rotate)
	settings.set_pref("gizmo_scale", gizmo.show_scale)
	_gizmo_hover = ""
	ui.sync()
	update_overlays()

# ==============================================================================
# Mesh operators
# ==============================================================================

func _menu_at(title: String, items: Array) -> void:
	if _camera != null:
		ui.popup_ops(title, items, _screen_pos(_camera, _mouse))

## Operators the F3 search lists: [label, action, arg].
func search_operators() -> Array:
	var ops := [
		["Extrude Region", "extrude_kind", "region"], ["Extrude Faces Along Normals", "extrude_kind", "normals"],
		["Extrude Individual Faces", "extrude_kind", "individual"], ["Extrude Edges Only", "extrude_kind", "edges"],
		["Extrude Vertices Only", "extrude_kind", "verts"], ["Inset Faces", "inset", null], ["Shrink/Fatten", "fatten", null],
		["Duplicate", "duplicate", null], ["Make Edge/Face", "make_face", null],
		["Material: Assign to Selected", "mat_assign", null], ["Material: Select Slot", "mat_select", null], ["Material: Add Slot", "mat_slot_add", null],
		["Delete Vertices", "delete", "verts"], ["Delete Edges", "delete", "edges"], ["Delete Faces", "delete", "faces"],
		["Delete Only Faces", "delete", "only_faces"], ["Delete Only Edges & Faces", "delete", "edges_faces"],
		["Dissolve Vertices", "dissolve", 1], ["Dissolve Edges", "dissolve", 2], ["Dissolve Faces", "dissolve", 3],
		["Merge at Center", "merge", ["center"]], ["Merge Collapse", "merge", ["collapse"]], ["Merge at First", "merge", ["first"]],
		["Merge at Last", "merge", ["last"]], ["Merge by Distance", "merge_distance_dialog", null],
		["Flip Normals", "flip", null], ["Recalculate Normals Outside", "recalc_outside", null], ["Recalculate Normals Inside", "recalc_inside", null],
		["Triangulate Faces", "triangulate", null], ["Tris to Quads", "tris_to_quads", null], ["Smooth Vertices", "smooth_verts", null],
		["Shade Smooth", "shade_smooth", null], ["Shade Flat", "shade_flat", null], ["Mark Sharp", "mark_sharp", null],
		["Clear Sharp", "clear_sharp", null], ["Mark Seam", "mark_seam", null], ["Clear Seam", "clear_seam", null],
		["Select All", "select_all", null], ["Select None", "select_none", null], ["Select Invert", "select_invert", null],
		["Select Linked", "select_linked", null], ["Select More", "select_more", null], ["Select Less", "select_less", null],
		["Hide", "hide", null], ["Reveal Hidden", "reveal", null], ["Toggle X-Ray", "xray", null],
		["Loop Cut and Slide", "loopcut", null], ["Bevel Edges", "bevel", null], ["Bevel Vertices", "bevel_verts", null],
		["Connect Vertex Path", "connect_path", null], ["Separate Selection", "separate", "selection"],
		["Separate by Loose Parts", "separate", "loose"], ["Separate by Material", "separate", "material"],
		["Intersect (Boolean) Union", "boolean_edit", "union"], ["Intersect (Boolean) Difference", "boolean_edit", "difference"],
		["Intersect (Boolean) Intersect", "boolean_edit", "intersect"], ["Toggle Focus mode", "focus", null],
	]
	for k in PfPrim.KINDS:
		ops.append(["Add " + str(PfPrim.LABELS[k]), "add_mesh_pick", k])
	return ops

## Runs an instant operator: fn(mesh) -> PfOps result. One undo step.
func _op(label: String, fn: Callable) -> void:
	var before: Dictionary = session.snapshot()
	var r: Dictionary = fn.call(session.mesh)
	if r.has("error"):
		session.restore(before)
		msg(str(r["error"]))
		return
	var shape_err := _shape_check()
	if shape_err != "":
		session.restore(before)
		msg(shape_err, 5.0)
		return
	_apply_result(r)
	session.commit_undo(label, before)
	if session.kind == "concave":
		var open: int = PfOps2.open_edges(session.mesh)
		if session.mesh.faces.is_empty():
			msg("Collision shape is empty — it no longer collides with anything", 5.0)
		elif open > PfOps2.open_edges(_mesh_of(before)):
			msg("Collision shape has %d open edges — bodies can pass through the holes" % open, 5.0)
	if r.has("removed"):
		msg("Removed %d vertices" % int(r["removed"]))

## Convex shapes need a 3D hull (else Godot physics: "Failed to build convex hull").
func _shape_check() -> String:
	if session.kind == "convex" and PfShape.rehull(session.mesh).is_empty():
		return "Operation cancelled: a convex shape needs at least 4 points that are not in one plane"
	return ""

func _mesh_of(snap: Dictionary):
	var m = PfMesh.new()
	m.from_dict(snap["mesh"])
	return m

## New selection + World-Scale UV projection of new faces.
func _apply_result(r: Dictionary) -> void:
	session.set_selection_result(r)
	if session.mesh.world_uv and not session.is_shape():
		var nf := {}
		nf.merge(r.get("faces", {}))
		nf.merge(r.get("side_faces", {}))
		if not nf.is_empty():
			PfUv.cube_project_world(session.mesh, settings.density_for(session.mesh), PackedInt32Array(nf.keys()))
	session.rebuild(true)
	ui.sync()

func _merge(arg) -> void:
	var kind: String = arg[0]
	var sv: Dictionary = session.selected_verts()
	match kind:
		"center":
			_op("Merge at Center", func(m):
				var c := Vector3.ZERO
				for v in sv:
					c += m.verts[v]
				return PfOps.merge_at(m, sv, c / float(maxi(sv.size(), 1))))
		"first", "last":
			var hist: Array = session.history.filter(func(x): return sv.has(x))
			if hist.size() < 1 or sv.size() < 2:
				msg("At First / At Last need vertices selected one by one (vertex mode)")
				return
			var t: int = hist[0] if kind == "first" else hist[hist.size() - 1]
			_op("Merge at " + kind.capitalize(), func(m): return PfOps.merge_at(m, sv, m.verts[t], t))
		"collapse":
			_op("Merge Collapse", func(m): return PfOps.merge_collapse(m, sv))
		"distance":
			var d := float(arg[1])
			_op("Merge by Distance", func(m): return PfOps.merge_by_distance(m, sv, d))
			_redo("Merge by Distance", [["distance", "Merge Distance", "float", d, 0.0, 100.0]], func(v): _merge(["distance", v["distance"]]))

## Starts a move of the operator result; cancelling keeps the result.
func _move_after(label: String, pre: Dictionary, normal_axis := Vector3.ZERO, side := {}, redo_kind := "") -> void:
	if _camera == null:
		session.commit_undo(label, pre)
		return
	_configure_modal()
	if normal_axis != Vector3.ZERO:
		var gx: Transform3D = session.node.global_transform
		var z := (gx.basis.inverse().transposed() * normal_axis).normalized()
		var y := (Vector3.UP if absf(z.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT).cross(z).normalized()
		modal.orient_name = "normal"
		modal.orient_basis = Basis(y.cross(z), y, z)
	if not modal.begin_elements(PfModal.Mode.MOVE, _camera, _mouse, session):
		session.commit_undo(label, pre)
		return
	modal.undo_base = pre
	modal.undo_label = label + " and Move"
	if session.mesh.world_uv:
		modal.reproject_faces = side
		modal.reproject_density = settings.density_for(session.mesh)
	if normal_axis != Vector3.ZERO:
		modal.preset_constraint(PfModal.Constraint.AXIS, 2)
	_pending_undo = {"label": label, "pre": pre, "redo_kind": redo_kind}
	update_overlays()

func _extrude(kind: String) -> void:
	var pre: Dictionary = session.snapshot()
	var sv: Dictionary = session.selected_verts()
	var se: Dictionary = session.selected_edges()
	var sf: Dictionary = session.selected_faces()
	var r: Dictionary
	match kind:
		"individual":
			r = PfOps.extrude_individual(session.mesh, sf)
		"edges":
			r = PfOps.extrude_region(session.mesh, {}, se, {})
		"verts":
			r = PfOps.extrude_region(session.mesh, sv, {}, {})
		_:
			r = PfOps.extrude_region(session.mesh, sv, se, sf)
	if r.has("error") or (r.get("verts", {}) as Dictionary).is_empty():
		session.restore(pre)
		msg(str(r.get("error", "Nothing selected to extrude")))
		return
	_apply_result(r)
	match kind:
		"individual":
			_fatten(r["dirs"], "Extrude Individual Faces", pre, r.get("side_faces", {}), func(d): _extrude_now("individual", {"distance": d}))
		"normals":
			_fatten({}, "Extrude Faces Along Normals", pre, r.get("side_faces", {}), func(d): _extrude_now("normals", {"distance": d}))
		_:
			var n: Vector3 = r.get("normal", Vector3.ZERO) if not sf.is_empty() else Vector3.ZERO
			_move_after("Extrude", pre, n, r.get("side_faces", {}), "extrude:" + kind)

func _duplicate() -> void:
	var pre: Dictionary = session.snapshot()
	var r: Dictionary = PfOps.duplicate_geometry(session.mesh, session.selected_verts(), session.selected_edges(), session.selected_faces())
	if r.has("error"):
		session.restore(pre)
		msg(str(r["error"]))
		return
	_apply_result(r)
	_move_after("Duplicate", pre, Vector3.ZERO, {}, "duplicate")

func _selection_pivot_world() -> Vector3:
	var p = PfModal.selection_pivot(session, "median")
	return session.node.global_transform * (p as Vector3) if p != null else session.node.global_position

## Shrink/Fatten (Alt+S) and the move part of Extrude Along Normals /
## Individual: vertices move along their normals by the modal value.
func _fatten(dirs: Dictionary, label: String, pre := {}, side := {}, redo_fn := Callable()) -> void:
	if _camera == null:
		return
	var sv: Dictionary = session.selected_verts()
	if sv.is_empty():
		msg("Nothing selected")
		return
	var d := dirs if not dirs.is_empty() else PfOps.vertex_normals(session.mesh, sv, session.selected_faces())
	var base: Dictionary = pre if not pre.is_empty() else session.snapshot()
	var orig := {}
	for v in d:
		orig[v] = session.mesh.verts[v]
	var density: float = settings.density_for(session.mesh)
	var world: bool = session.mesh.world_uv
	_vm_state = {"label": label, "pre": base, "kind": "fatten",
		"redo": redo_fn if redo_fn.is_valid() else (func(d): _fatten_now({"distance": d}))}
	vmodal.snap_increment = float(settings.get_pref("snap_increment"))
	vmodal.on_key = Callable()
	vmodal.begin(label, "fatten", _camera, _mouse, _selection_pivot_world(), func(t: float):
		for v in d:
			session.mesh.verts[v] = (orig[v] as Vector3) + (d[v] as Vector3) * t
		session.mesh.invalidate()
		if world and not side.is_empty():
			PfUv.cube_project_world(session.mesh, density, PackedInt32Array(side.keys()))
		session.rebuild(true))
	update_overlays()

func _inset() -> void:
	if _camera == null:
		return
	var sf: Dictionary = session.selected_faces()
	if sf.is_empty():
		msg("Select faces to inset")
		return
	var pre: Dictionary = session.snapshot()
	_vm_state = {"label": "Inset Faces", "pre": pre, "kind": "inset", "faces": sf, "individual": false}
	if not _inset_build():
		return
	vmodal.snap_increment = float(settings.get_pref("snap_increment"))
	vmodal.on_key = func(code: int) -> bool:
		if code != KEY_I:
			return false
		_vm_state["individual"] = not bool(_vm_state["individual"])
		session.restore(_vm_state["pre"])
		_inset_build()
		vmodal.extra = "Individual" if _vm_state["individual"] else ""
		return true
	vmodal.begin("Inset Faces", "inset", _camera, _mouse, _selection_pivot_world(), func(t: float):
		if _vm_state.has("data"):
			PfOps.inset_update(session.mesh, _vm_state["data"], t)
			if session.mesh.world_uv:
				PfUv.cube_project_world(session.mesh, settings.density_for(session.mesh), PackedInt32Array((_vm_state["data"]["side_faces"] as Dictionary).keys()))
			session.rebuild(true))
	update_overlays()

func _inset_build() -> bool:
	var data: Dictionary = PfOps.inset(session.mesh, _vm_state["faces"], bool(_vm_state["individual"]))
	if data.has("error"):
		session.restore(_vm_state["pre"])
		msg(str(data["error"]))
		return false
	_vm_state["data"] = data
	session.set_selection_result(data)
	return true

func _on_vmodal_finished(committed: bool) -> void:
	if session == null or _vm_state.is_empty():
		_vm_state = {}
		return
	if _vm_state.has("finish"):
		var cb: Callable = _vm_state["finish"]
		_vm_state = {}
		cb.call(committed)
		ui.sync()
		update_overlays()
		return
	if committed:
		session.commit_undo(_vm_state["label"], _vm_state["pre"])
		var val: float = vmodal.value
		if _vm_state["kind"] == "fatten" and _vm_state.has("redo"):
			var rf: Callable = _vm_state["redo"]
			_redo(_vm_state["label"], [["distance", "Distance", "float", val, -1000.0, 1000.0]], func(v): rf.call(float(v["distance"])))
		elif _vm_state["kind"] == "inset":
			_redo("Inset Faces", [["thickness", "Thickness", "float", val, 0.0, 1000.0], ["individual", "Individual", "bool", bool(_vm_state["individual"])]],
				func(v): _inset_now(v))
	elif _vm_state["kind"] == "inset" or not (_vm_state["label"] as String).begins_with("Extrude"):
		session.restore(_vm_state["pre"])
	else:
		# Extrude + fatten cancelled: the extrusion stays in place (Blender).
		vmodal.apply.call(0.0)
		session.commit_undo(_vm_state["label"], _vm_state["pre"])
	_vm_state = {}
	ui.sync()
	update_overlays()

# ==============================================================================
# Adjust Last Operation (F9): non-interactive re-runs
# ==============================================================================

## The 3D view control hosting the panel (bottom-left corner).
func _view_host() -> Control:
	var cam := _camera
	if cam == null:
		var vp3 := EditorInterface.get_editor_viewport_3d(0)
		cam = vp3.get_camera_3d() if vp3 != null else null
	if cam == null:
		return null
	var vp := cam.get_viewport()
	var c := vp.get_parent() as Control if vp != null else null
	return c.get_parent() as Control if c != null else null

## Registers the last operator: spec = [[key, label, type, value, min, max]].
func _redo(label: String, spec: Array, run: Callable) -> void:
	var node: Node = session.node if session != null else EditorInterface.get_edited_scene_root()
	_redo_on(label, spec, run, node)

func _redo_on(label: String, spec: Array, run: Callable, node: Node) -> void:
	if node == null or redo == null:
		return
	var ur := get_undo_redo()
	var h := ur.get_history_undo_redo(ur.get_object_history_id(node))
	var ps := []
	for sp in spec:
		ps.append({"key": sp[0], "label": sp[1], "type": sp[2], "value": sp[3],
			"min": sp[4] if sp.size() > 4 else -100000.0, "max": sp[5] if sp.size() > 5 else 100000.0})
	redo.register(label, ps, run, h)

func _redo_prim(label: String, kind: String, values: Dictionary, node: Node, run: Callable) -> void:
	var cur := PfPrim.default_params(kind)
	cur.merge(values, true)
	var spec := []
	for p in PfPrim.PARAMS.get(kind, []):
		spec.append([p[0], p[1], p[2], cur[p[0]], p[4], p[5]])
	_redo_on(label, spec, run, node)

func _register_move_redo(kind: String, t: Vector3) -> void:
	var spec := [["x", "Move X", "float", t.x], ["y", "Move Y", "float", t.y], ["z", "Move Z", "float", t.z]]
	if kind == "duplicate":
		_redo("Duplicate and Move", spec, func(v): _duplicate_now(v))
	else:
		_redo("Extrude and Move", spec, func(v): _extrude_now(kind.trim_prefix("extrude:"), v))

func _move_new(r: Dictionary, v: Dictionary) -> void:
	var t := Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0)))
	for vi in r.get("verts", {}):
		session.mesh.verts[vi] += t

## Extrude without the interactive part (region/edges/verts: move by x/y/z;
## individual/normals: distance along the normals).
func _extrude_now(kind: String, v: Dictionary) -> void:
	var pre: Dictionary = session.snapshot()
	var sv: Dictionary = session.selected_verts()
	var se: Dictionary = session.selected_edges()
	var sf: Dictionary = session.selected_faces()
	var r: Dictionary
	match kind:
		"individual": r = PfOps.extrude_individual(session.mesh, sf)
		"edges": r = PfOps.extrude_region(session.mesh, {}, se, {})
		"verts": r = PfOps.extrude_region(session.mesh, sv, {}, {})
		_: r = PfOps.extrude_region(session.mesh, sv, se, sf)
	if r.has("error"):
		session.restore(pre)
		msg(str(r["error"]))
		return
	_apply_result(r)
	var label := "Extrude and Move"
	if kind == "individual" or kind == "normals":
		var dirs: Dictionary = r["dirs"] if kind == "individual" else PfOps.vertex_normals(session.mesh, session.selected_verts(), session.selected_faces())
		for vi in dirs:
			session.mesh.verts[vi] += (dirs[vi] as Vector3) * float(v.get("distance", 0.0))
		label = "Extrude Individual Faces" if kind == "individual" else "Extrude Faces Along Normals"
	else:
		_move_new(r, v)
	if session.mesh.world_uv:
		PfUv.cube_project_world(session.mesh, settings.density_for(session.mesh), PackedInt32Array((r.get("side_faces", {}) as Dictionary).keys()))
	session.commit_undo(label, pre)
	if kind == "individual" or kind == "normals":
		_redo(label, [["distance", "Distance", "float", v.get("distance", 0.0), -1000.0, 1000.0]], func(nv): _extrude_now(kind, nv))
	else:
		_register_move_redo("extrude:" + kind, Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0))))

func _duplicate_now(v: Dictionary) -> void:
	var pre: Dictionary = session.snapshot()
	var r: Dictionary = PfOps.duplicate_geometry(session.mesh, session.selected_verts(), session.selected_edges(), session.selected_faces())
	if r.has("error"):
		session.restore(pre)
		return
	_apply_result(r)
	_move_new(r, v)
	session.commit_undo("Duplicate and Move", pre)
	_register_move_redo("duplicate", Vector3(float(v.get("x", 0.0)), float(v.get("y", 0.0)), float(v.get("z", 0.0))))

func _fatten_now(v: Dictionary) -> void:
	var pre: Dictionary = session.snapshot()
	var sv: Dictionary = session.selected_verts()
	var d := PfOps.vertex_normals(session.mesh, sv, session.selected_faces())
	for vi in d:
		session.mesh.verts[vi] += (d[vi] as Vector3) * float(v.get("distance", 0.0))
	session.mesh.invalidate()
	session.commit_undo("Shrink/Fatten", pre)
	_redo("Shrink/Fatten", [["distance", "Distance", "float", v.get("distance", 0.0), -1000.0, 1000.0]], func(nv): _fatten_now(nv))

func _inset_now(v: Dictionary) -> void:
	var pre: Dictionary = session.snapshot()
	var data: Dictionary = PfOps.inset(session.mesh, session.selected_faces(), bool(v.get("individual", false)))
	if data.has("error"):
		session.restore(pre)
		msg(str(data["error"]))
		return
	session.set_selection_result(data)
	PfOps.inset_update(session.mesh, data, float(v.get("thickness", 0.0)))
	if session.mesh.world_uv:
		PfUv.cube_project_world(session.mesh, settings.density_for(session.mesh), PackedInt32Array((data["side_faces"] as Dictionary).keys()))
	session.commit_undo("Inset Faces", pre)
	_redo("Inset Faces", [["thickness", "Thickness", "float", v.get("thickness", 0.0), 0.0, 1000.0], ["individual", "Individual", "bool", bool(v.get("individual", false))]],
		func(nv): _inset_now(nv))

func _bevel_now(verts_only: bool, v: Dictionary) -> void:
	var pre: Dictionary = session.snapshot()
	var d: Dictionary = PfOps2.bevel_verts(session.mesh, session.selected_verts()) if verts_only \
		else PfOps2.bevel_edges(session.mesh, session.selected_edges(), int(v.get("segments", 1)))
	if d.has("error"):
		session.restore(pre)
		msg(str(d["error"]))
		return
	session.set_selection_result({"faces": d["faces"]})
	var w := PfOps2.bevel_update(session.mesh, d, float(v.get("width", 0.0)))
	session.commit_undo("Bevel Vertices" if verts_only else "Bevel", pre)
	var spec := [["width", "Width", "float", w, 0.0, 1000.0]]
	if not verts_only:
		spec.append(["segments", "Segments", "int", int(v.get("segments", 1)), 1, 32])
	_redo("Bevel Vertices" if verts_only else "Bevel", spec, func(nv): _bevel_now(verts_only, nv))

func _loopcut_now(edge: Vector2i, v: Dictionary) -> void:
	var pre: Dictionary = session.snapshot()
	var data: Dictionary = PfOps2.loop_cut(session.mesh, edge, int(v.get("cuts", 1)))
	if data.has("error"):
		session.restore(pre)
		msg(str(data["error"]))
		return
	_apply_result(data)
	PfOps2.loop_slide(session.mesh, data, float(v.get("factor", 0.0)))
	session.commit_undo("Loop Cut and Slide", pre)
	_redo("Loop Cut and Slide", [["cuts", "Number of Cuts", "int", int(v.get("cuts", 1)), 1, 64], ["factor", "Factor", "float", float(v.get("factor", 0.0)), -1.0, 1.0]],
		func(nv): _loopcut_now(edge, nv))


# ==============================================================================
# Stage 2B: loop cut, bevel, separate, join, Boolean, focus
# ==============================================================================

func _apply_focus() -> void:
	if session != null and bool(settings.get_pref("focus_mode")) and session.node is VisualInstance3D:
		var others := []
		for mb in session.members:
			others.append(mb["node"])
		focus.enable(session.node, float(settings.get_pref("focus_amount")), others)
	else:
		focus.disable()

func _loopcut_input(camera: Camera3D, event: InputEvent) -> int:
	if session == null:
		_lc = {}
		return PASS
	if event is InputEventMouseMotion:
		_lc["edge"] = PfPicking.pick_edge(session, camera, (event as InputEventMouseMotion).position)
		update_overlays()
		return STOP
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				_lc["cuts"] = clampi(int(_lc["cuts"]) + (1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1), 1, 64)
				update_overlays()
			MOUSE_BUTTON_LEFT:
				if _lc["edge"] != null:
					_do_loopcut(camera, _lc["edge"], int(_lc["cuts"]))
				_lc = {}   # the release goes to the slide modal (ignored there)
			MOUSE_BUTTON_RIGHT:
				_lc = {}
				update_overlays()
		return STOP
	if event is InputEventKey and event.pressed:
		match (event as InputEventKey).keycode:
			KEY_ESCAPE:
				_lc = {}
			KEY_PAGEUP:
				_lc["cuts"] = mini(int(_lc["cuts"]) + 1, 64)
			KEY_PAGEDOWN:
				_lc["cuts"] = maxi(int(_lc["cuts"]) - 1, 1)
		update_overlays()
	return STOP

func _draw_loopcut(vc: Control) -> void:
	var font := vc.get_theme_default_font()
	var hint := "Loop Cut: hover an edge, wheel / PgUp PgDn: number of cuts (%d), LMB: cut then slide, RMB / Esc: cancel" % int(_lc["cuts"])
	_label(vc, font, hint, vc.size.y - 18.0, Color(1, 1, 1, 0.85), 12)
	if _lc["edge"] == null or _camera == null:
		return
	var gx: Transform3D = session.node.global_transform
	for seg in PfOps2.loop_preview(session.mesh, _lc["edge"], int(_lc["cuts"])):
		var a: Vector3 = gx * (seg[0] as Vector3)
		var b: Vector3 = gx * (seg[1] as Vector3)
		if _camera.is_position_behind(a) or _camera.is_position_behind(b):
			continue
		vc.draw_line(_camera.unproject_position(a), _camera.unproject_position(b), Color(1.0, 0.9, 0.2), 2.0, true)

func _do_loopcut(camera: Camera3D, edge: Vector2i, cuts: int) -> void:
	var pre: Dictionary = session.snapshot()
	var data: Dictionary = PfOps2.loop_cut(session.mesh, edge, cuts)
	if data.has("error"):
		session.restore(pre)
		msg(str(data["error"]))
		return
	_apply_result(data)
	var gx: Transform3D = session.node.global_transform
	var a := camera.unproject_position(gx * (pre["mesh"]["verts"][edge.x] as Vector3))
	var b := camera.unproject_position(gx * (pre["mesh"]["verts"][edge.y] as Vector3))
	var axis := (b - a) * (0.5 / float(cuts + 1)) * 2.0
	_vm_state = {"finish": func(committed: bool):
		if not committed:
			PfOps2.loop_slide(session.mesh, data, 0.0)   # RMB: loop stays in the middle (Blender)
		session.rebuild(false)
		session.commit_undo("Loop Cut and Slide", pre)
		_redo("Loop Cut and Slide", [["cuts", "Number of Cuts", "int", cuts, 1, 64], ["factor", "Factor", "float", vmodal.value if committed else 0.0, -1.0, 1.0]],
			func(v): _loopcut_now(edge, v))}
	vmodal.snap_increment = float(settings.get_pref("snap_increment"))
	vmodal.on_key = Callable()
	vmodal.begin("Loop Cut and Slide", "factor", camera, _mouse, _selection_pivot_world(), func(f: float):
		PfOps2.loop_slide(session.mesh, data, f)
		session.rebuild(true))
	vmodal.axis_screen = axis if axis.length() > 1.0 else Vector2(60, 0)
	vmodal.name_override = "Factor"

## Ctrl+B (edges) / Ctrl+Shift+B (vertices): width with the mouse, segments
## with the wheel; Esc / RMB cancels everything.
func _bevel(verts_only: bool) -> void:
	if _camera == null:
		return
	var pre: Dictionary = session.snapshot()
	var st := {"seg": 1, "data": {}, "w": 0.0}
	var build := func() -> bool:
		var d: Dictionary = PfOps2.bevel_verts(session.mesh, session.selected_verts()) if verts_only \
			else PfOps2.bevel_edges(session.mesh, session.selected_edges(), int(st["seg"]))
		if d.has("error"):
			session.restore(pre)
			msg(str(d["error"]))
			return false
		st["data"] = d
		return true
	if not build.call():
		return
	var sel_after := func():
		session.set_selection_result({"faces": st["data"]["faces"]})
	sel_after.call()
	_vm_state = {"finish": func(committed: bool):
		if committed:
			session.rebuild(false)
			session.commit_undo("Bevel Vertices" if verts_only else "Bevel", pre)
			var spec := [["width", "Width", "float", st["w"], 0.0, 1000.0]]
			if not verts_only:
				spec.append(["segments", "Segments", "int", int(st["seg"]), 1, 32])
			_redo("Bevel Vertices" if verts_only else "Bevel", spec, func(v): _bevel_now(verts_only, v))
		else:
			session.restore(pre)}
	vmodal.snap_increment = float(settings.get_pref("snap_increment"))
	vmodal.on_key = Callable()
	vmodal.begin("Bevel", "width", _camera, _mouse, _selection_pivot_world(), func(w: float):
		st["w"] = PfOps2.bevel_update(session.mesh, st["data"], w)
		session.rebuild(true))
	if not verts_only:
		vmodal.on_wheel = func(step: int):
			st["seg"] = clampi(int(st["seg"]) + step, 1, 32)
			var keep: Dictionary = session.snapshot()
			session.restore(pre)
			if build.call():
				sel_after.call()
				vmodal.extra = "Segments: %d" % int(st["seg"])
			else:
				session.restore(keep)
		vmodal.extra = "Segments: 1"

## P: selected faces / loose parts / material groups become new objects.
func _separate(kind: String) -> void:
	var m = session.mesh
	var groups: Array = PfOps2.separate_groups(m, kind, session.selected_faces())
	var move: Array = []
	if kind == "selection":
		if groups.is_empty():
			msg("Select faces to separate")
			return
		if (groups[0] as Dictionary).size() == m.faces.size():
			msg("Cannot separate everything (nothing would be left)")
			return
		move = groups
	else:
		if groups.size() < 2:
			msg("Nothing to separate (only one part)")
			return
		move = groups.slice(1)
	var node: MeshInstance3D = session.node
	var root := EditorInterface.get_edited_scene_root()
	var parent := node.get_parent()
	var pre: Dictionary = session.snapshot()
	var all := {}
	var new_nodes := []
	for g in move:
		all.merge(g)
		var part = PfOps2.extract(m, g)
		var mi := MeshInstance3D.new()
		mi.name = node.name
		mi.transform = node.transform
		mi.mesh = PfBuild.build(part)
		new_nodes.append(mi)
	PfOps.delete(m, "faces", {}, {}, all)
	session.set_selection_result({})
	session.rebuild(false)
	var after: Dictionary = session.snapshot()
	var ur := get_undo_redo()
	ur.create_action("Polyforge: Separate", UndoRedo.MERGE_DISABLE, node)
	ur.add_do_method(self, "_pf_restore", node.get_instance_id(), after)
	ur.add_undo_method(self, "_pf_restore", node.get_instance_id(), pre)
	for mi in new_nodes:
		ur.add_do_method(parent, "add_child", mi, true)
		ur.add_do_method(mi, "set_owner", root)
		ur.add_do_reference(mi)
		ur.add_undo_method(parent, "remove_child", mi)
	ur.commit_action()
	msg("Separated %d part(s) into new object(s)" % new_nodes.size())

## Edit data of a MeshInstance3D (Polyforge mesh or supported primitive).
func _read_pf(mi: MeshInstance3D):
	if mi.mesh is ArrayMesh and mi.mesh.has_meta(PfMesh.META_KEY):
		var m = PfMesh.new()
		return m if m.from_dict(mi.mesh.get_meta(PfMesh.META_KEY)) else null
	if mi.mesh != null and PfPrim.supports(mi.mesh):
		return PfPrim.from_godot(mi.mesh)
	return null

## Selected meshes in Object Mode, the active one (last selected) last.
func _selected_meshes() -> Array:
	var out := []
	for n in EditorInterface.get_selection().get_selected_nodes():
		if n is MeshInstance3D and _read_pf(n) != null:
			out.append(n)
	return out

## Ctrl+J: the other selected meshes join the active (last selected) one.
func _join_objects() -> void:
	if session != null:
		msg("Join works in Object Mode (Tab out first)")
		return
	var meshes := _selected_meshes()
	if meshes.size() < 2:
		msg("Select two or more Polyforge meshes (the last one receives the others)")
		return
	var target: MeshInstance3D = meshes[meshes.size() - 1]
	var m = _read_pf(target)
	var inv := target.global_transform.affine_inverse()
	for i in meshes.size() - 1:
		var o: MeshInstance3D = meshes[i]
		PfOps2.join_into(m, _read_pf(o), inv * o.global_transform)
	var am := PfBuild.build(m)
	var ur := get_undo_redo()
	var root := EditorInterface.get_edited_scene_root()
	ur.create_action("Polyforge: Join", UndoRedo.MERGE_DISABLE, root)
	ur.add_do_property(target, "mesh", am)
	ur.add_undo_property(target, "mesh", target.mesh)
	for i in meshes.size() - 1:
		var o: MeshInstance3D = meshes[i]
		var parent := o.get_parent()
		ur.add_do_method(parent, "remove_child", o)
		ur.add_undo_method(parent, "add_child", o)
		ur.add_undo_method(parent, "move_child", o, o.get_index())
		ur.add_undo_reference(o)
	ur.commit_action()
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(target)
	msg("Joined %d object(s)" % (meshes.size() - 1))

## Boolean in Object Mode: the active (last selected) mesh is changed by the
## others; the cutters stay as they are (like Blender's applied modifier).
func _boolean_objects(op: String) -> void:
	if session != null or _busy:
		msg("Boolean between objects works in Object Mode")
		return
	var meshes := _selected_meshes()
	if meshes.size() < 2:
		msg("Select the cutter(s), then the object to change last")
		return
	var target: MeshInstance3D = meshes[meshes.size() - 1]
	var base = _read_pf(target)
	var inv := target.global_transform.affine_inverse()
	var cutters := []
	for i in meshes.size() - 1:
		var c = _read_pf(meshes[i])
		var moved = PfMesh.new()
		PfOps2.join_into(moved, c, inv * (meshes[i] as MeshInstance3D).global_transform)
		cutters.append(moved)
	_busy = true
	var r: Dictionary = await PfBoolean.compute(self, base, cutters, op)
	_busy = false
	if r.has("error"):
		msg(str(r["error"]), 5.0)
		return
	var ur := get_undo_redo()
	ur.create_action("Polyforge: Boolean " + op.capitalize(), UndoRedo.MERGE_DISABLE, target)
	ur.add_do_property(target, "mesh", PfBuild.build(r["mesh"]))
	ur.add_undo_property(target, "mesh", target.mesh)
	ur.commit_action()
	msg("Boolean %s done" % op)

## Edit Mode "Intersect (Boolean)": selected faces cut / join the rest.
func _boolean_edit(op: String) -> void:
	if _busy:
		return
	var m = session.mesh
	var sf: Dictionary = session.selected_faces()
	if sf.is_empty() or sf.size() == m.faces.size():
		msg("Select the cutting part (faces); the unselected part is the base")
		return
	var rest := {}
	for fi in m.faces.size():
		if not sf.has(fi):
			rest[fi] = true
	var pre: Dictionary = session.snapshot()
	var base = PfOps2.extract(m, rest)
	var cutter = PfOps2.extract(m, sf)
	_busy = true
	var r: Dictionary = await PfBoolean.compute(self, base, [cutter], op)
	_busy = false
	if session == null:
		return
	if r.has("error"):
		msg(str(r["error"]), 5.0)
		return
	session.mesh.from_dict(r["mesh"].to_dict())
	session.set_selection_result({})
	session.commit_undo("Intersect (Boolean)", pre)
	msg("Boolean %s done" % op)

## U menu operators on the faces selected in 3D, channel of the UV editor.
func _uv_op(kind: String, p := {}) -> void:
	var faces: Dictionary = session.selected_faces()
	if faces.is_empty():
		msg("Select faces to unwrap")
		return
	var ch: int = uv_panel.channel
	var dens: float = settings.density_for(session.mesh) if session.mesh.world_uv else 0.0
	var cam := _camera
	var gx: Transform3D = session.node.global_transform
	_op({"unwrap": "Unwrap", "smart": "Smart UV Project", "cube": "Cube Projection", "cylinder": "Cylinder Projection",
		"sphere": "Sphere Projection", "view": "Project from View", "view_bounds": "Project from View", "reset": "Reset", "lightmap": "Lightmap Pack"}[kind], func(m):
		match kind:
			"unwrap": PfUvOps.unwrap(m, ch, faces, dens, m.uv_pins)
			"smart": PfUvOps.smart_project(m, ch, faces, float(p.get("angle", 66.0)), dens)
			"cube": PfUvOps.cube_project(m, ch, faces, float(p.get("size", 2.0)), dens)
			"cylinder": PfUvOps.wrap_project(m, ch, faces, false)
			"sphere": PfUvOps.wrap_project(m, ch, faces, true)
			"reset": PfUvOps.reset(m, ch, faces)
			"lightmap": PfUvOps.lightmap_pack(m, ch, faces, float(p.get("margin", 0.02)))
			_:
				if cam == null:
					return {"error": "No 3D view"}
				var h := float(cam.get_viewport().get_visible_rect().size.y)
				PfUvOps.project_view(m, ch, faces, func(p): return cam.unproject_position(gx * p), kind == "view_bounds", maxf(h, 1.0))
		return {"faces": faces})
	if kind == "smart":
		_redo("Smart UV Project", [["angle", "Angle Limit", "float", p.get("angle", 66.0), 1.0, 89.0]], func(v): run_action("uv_op", ["smart", v]))
	elif kind == "lightmap":
		_redo("Lightmap Pack", [["margin", "Margin", "float", p.get("margin", 0.02), 0.0, 0.25]], func(v): run_action("uv_op", ["lightmap", v]))
	elif kind == "cube":
		_redo("Cube Projection", [["size", "Cube Size", "float", p.get("size", 2.0), 0.001, 1000.0]], func(v): run_action("uv_op", ["cube", v]))
	uv_panel.queue_redraw()

func _grow_shrink(grow: bool) -> void:
	var m = session.mesh
	match session.mode:
		PfSession.FACE:
			var f: Dictionary = PfSelect.grow_faces(m, session.sel_f) if grow else PfSelect.shrink_faces(m, session.sel_f)
			session.select_many(f.keys(), "set")
		_:
			var v: Dictionary = PfSelect.grow_verts(m, session.selected_verts()) if grow else PfSelect.shrink_verts(m, session.selected_verts())
			if session.mode == PfSession.EDGE:
				session.select_many(PfSelect.verts_to_edges(m, v).keys(), "set")
			else:
				session.select_many(v.keys(), "set")

func _begin_element_modal(mode: int) -> void:
	if _camera == null:
		return
	_configure_modal()
	if not modal.begin_elements(mode, _camera, _mouse, session):
		msg("Nothing selected")
	update_overlays()

func _begin_object_modal(mode: int) -> void:
	if _camera == null:
		return
	var nodes: Array[Node3D] = []
	for n in EditorInterface.get_selection().get_top_selected_nodes():
		if n is Node3D:
			nodes.append(n)
	_configure_modal()
	modal.begin_objects(mode, _camera, _mouse, nodes)
	update_overlays()

func _on_modal_finished(committed: bool) -> void:
	if modal.prop_size != float(settings.get_pref("prop_size")):
		settings.set_pref("prop_size", modal.prop_size)
	if session != null:
		session.rebuild(false)
		# Operator + move cancelled: the operator result stays (Blender) and
		# becomes its own undo step.
		if not _pending_undo.is_empty() and not committed:
			session.commit_undo(_pending_undo["label"], _pending_undo["pre"])
		var rk: String = _pending_undo.get("redo_kind", "")
		if rk != "":
			var t: Vector3 = session.node.global_transform.basis.inverse() * modal.current_xf.origin if committed else Vector3.ZERO
			_register_move_redo(rk, t)
	_pending_undo = {}
	ui.sync()
	update_overlays()


# ==============================================================================
# Adding meshes
# ==============================================================================

func _new_primitive(kind: String, values := {}):
	var m = PfPrim.create_with(kind, values)
	if m == null:
		return null
	m.world_uv = settings.world_uv_default()
	if m.world_uv:
		PfUv.cube_project_world(m, settings.density_for(m))
	return m

## Polyforge → Add Mesh (Object Mode): a new MeshInstance3D at the world
## origin (Blender adds at the 3D cursor, which starts there), then Edit Mode.
func _add_object(kind: String, values := {}) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		msg("Open or create a 3D scene first")
		return
	var m = _new_primitive(kind, values)
	if m == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = str(PfPrim.LABELS[kind]).replace(" ", "")
	mi.mesh = PfBuild.build(m)
	var parent: Node = root
	var ur := get_undo_redo()
	ur.create_action("Polyforge: Add %s" % PfPrim.LABELS[kind], UndoRedo.MERGE_DISABLE, root)
	ur.add_do_method(parent, "add_child", mi, true)
	ur.add_do_method(mi, "set_owner", root)
	ur.add_do_reference(mi)
	ur.add_undo_method(parent, "remove_child", mi)
	ur.commit_action()
	if parent is Node3D:
		mi.global_transform = Transform3D(Basis(), cursor3d)
	_redo_prim("Add " + str(PfPrim.LABELS[kind]), kind, values, root, func(v): _add_object(kind, v))
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(mi)
	_enter_after_add.call_deferred(mi)

func _enter_after_add(mi: MeshInstance3D) -> void:
	if is_instance_valid(mi) and mi.is_inside_tree():
		enter_edit(mi)

## Shift+RMB: the 3D cursor goes to the surface under the mouse, else onto the
## view plane through its current position (Blender).
func _place_cursor(camera: Camera3D, pos: Vector2) -> void:
	var r := PfPicking._to_local(session, camera, pos)
	var hit: Dictionary = session.bvh().raycast(r[0], r[1])
	if not hit.is_empty():
		cursor3d = session.node.global_transform * (hit["point"] as Vector3)
	else:
		var p = Plane(-camera.global_transform.basis.z, cursor3d).intersects_ray(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
		if p != null:
			cursor3d = p
	update_overlays()

## Ctrl+M: mirror the selection about the pivot; fully selected faces are
## flipped so their normals keep pointing outwards.
func _mirror_selection(axis: int, local: bool) -> void:
	var piv = PfModal.selection_pivot(session, pivot_mode)
	if piv == null:
		msg("Nothing selected")
		return
	var gx: Transform3D = session.node.global_transform
	var fr := gx.basis.orthonormalized() if local else Basis.IDENTITY
	var sc := Vector3.ONE
	sc[axis] = -1.0
	var b := fr * Basis.from_scale(sc) * fr.inverse()
	var wp: Vector3 = gx * (piv as Vector3)
	var to_local := gx.affine_inverse() * Transform3D(b, wp - b * wp) * gx
	var before: Dictionary = session.snapshot()
	for v in session.selected_verts():
		session.mesh.verts[v] = to_local * session.mesh.verts[v]
	PfOps.flip(session.mesh, session.selected_faces())
	session.commit_undo("Mirror", before)

## Shift+S (Blender Snap menu).
func _snap(kind: String) -> void:
	var xf: Transform3D = session.node.global_transform
	var med = PfModal.selection_pivot(session, "median")
	var act = session.active_position()
	if kind.begins_with("cursor_"):
		match kind:
			"cursor_origin": cursor3d = Vector3.ZERO
			"cursor_sel": if med != null: cursor3d = xf * (med as Vector3)
			"cursor_active": if act != null: cursor3d = xf * (act as Vector3)
		update_overlays()
		return
	if med == null or (kind == "sel_active" and act == null):
		msg("Nothing selected" if med == null else "No active element")
		return
	var target: Vector3 = act if kind == "sel_active" else xf.affine_inverse() * cursor3d
	var before: Dictionary = session.snapshot()
	for v in session.selected_verts():
		session.mesh.verts[v] = session.mesh.verts[v] - (med as Vector3) + target if kind == "sel_cursor_offset" else target
	session.commit_undo("Snap Selection", before)

## Shift+A in Edit Mode: the primitive joins the edited mesh (Blender), at the
## 3D cursor aligned to the world; the new part becomes the selection.
func _add_into_mesh(kind: String, values := {}) -> void:
	var p = _new_primitive(kind, values)
	if p == null:
		return
	var before: Dictionary = session.snapshot()
	var xf: Transform3D = session.node.global_transform.affine_inverse() * Transform3D(Basis(), cursor3d)
	var first: int = session.mesh.faces.size()
	var new_v: PackedInt32Array = session.mesh.append_mesh(p, xf)
	session.mesh.invalidate()
	var vs := {}
	for v in new_v:
		vs[v] = true
	match session.mode:
		PfSession.VERTEX: session.select_many(vs.keys(), "set")
		PfSession.EDGE: session.select_many(PfSelect.verts_to_edges(session.mesh, vs).keys(), "set")
		PfSession.FACE: session.select_many(range(first, session.mesh.faces.size()), "set")
	session.commit_undo("Add %s" % PfPrim.LABELS[kind], before)
	_redo_prim("Add " + str(PfPrim.LABELS[kind]), kind, values, session.node, func(v): _add_into_mesh(kind, v))


# ==============================================================================
# Object Mode helpers (optional shortcuts)
# ==============================================================================

func _delete_objects() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var nodes := EditorInterface.get_selection().get_top_selected_nodes()
	nodes = nodes.filter(func(n): return n != root)
	if nodes.is_empty():
		return
	var ur := get_undo_redo()
	ur.create_action("Polyforge: Delete", UndoRedo.MERGE_DISABLE, root)
	for n in nodes:
		var parent: Node = n.get_parent()
		ur.add_do_method(parent, "remove_child", n)
		ur.add_undo_method(parent, "add_child", n)
		ur.add_undo_method(parent, "move_child", n, n.get_index())
		ur.add_undo_reference(n)
	ur.commit_action()

func _duplicate_objects() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var nodes := EditorInterface.get_selection().get_top_selected_nodes().filter(func(n): return n != root and n is Node3D)
	if nodes.is_empty():
		return
	var ur := get_undo_redo()
	ur.create_action("Polyforge: Duplicate", UndoRedo.MERGE_DISABLE, root)
	var dups: Array[Node3D] = []
	for n in nodes:
		var d: Node3D = n.duplicate()
		var parent: Node = n.get_parent()
		ur.add_do_method(parent, "add_child", d, true)
		ur.add_do_method(self, "_set_owner_recursive", d, root)
		ur.add_do_reference(d)
		ur.add_undo_method(parent, "remove_child", d)
		dups.append(d)
	ur.commit_action()
	var sel := EditorInterface.get_selection()
	sel.clear()
	for d in dups:
		sel.add_node(d)
	_begin_object_modal(PfModal.Mode.MOVE)

func _set_owner_recursive(n: Node, owner: Node) -> void:
	n.owner = owner
	for c in n.get_children():
		_set_owner_recursive(c, owner)


# ==============================================================================
# Local View / saving
# ==============================================================================

func _toggle_local_view() -> void:
	if local_view.active:
		local_view.exit()
		update_overlays()
		return
	var sel := EditorInterface.get_selection().get_top_selected_nodes()
	if sel.is_empty():
		msg("Select objects for Local View")
		return
	if local_view.enter(EditorInterface.get_edited_scene_root(), sel):
		if bool(settings.get_pref("local_view_frame")):
			_frame_selection()
	update_overlays()

## Frames the selection with Godot's own "Focus Selection" (F). The event is
## queued, so F is let through to Godot for a moment even in Edit Mode.
func _frame_selection() -> void:
	_pass_f_until = Time.get_ticks_msec() + 500
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = KEY_F
		ev.physical_keycode = KEY_F
		ev.pressed = pressed
		Input.parse_input_event(ev)

func _save_mesh_as(path: String) -> void:
	if session == null:
		return
	session.rebuild(false)
	var err := ResourceSaver.save(session.amesh, path)
	if err != OK:
		msg("Could not save %s (error %d)" % [path, err])
		return
	session.amesh.take_over_path(path)
	msg("Mesh saved to %s" % path)

func _uv_panel_key(k: InputEventKey) -> bool:
	var a := PfKeymap.find(PfKeymap.EDIT, k)
	if a in ["next_tab", "prev_tab"]:
		run_action(a)
		return true
	return false


# ==============================================================================
# Viewport drawing (2D over the 3D view)
# ==============================================================================

func _forward_3d_draw_over_viewport(vc: Control) -> void:
	var font := vc.get_theme_default_font()
	var top := 26.0
	if session != null:
		var w := float(settings.get_pref("frame_width"))
		var col: Color = settings.get_pref("frame_color")
		vc.draw_rect(Rect2(0, 0, vc.size.x, w), col)
		vc.draw_rect(Rect2(0, vc.size.y - w, vc.size.x, w), col)
		vc.draw_rect(Rect2(vc.size.x - w, 0, w, vc.size.y), col)
		var joined: bool = uv_panel.is_visible_in_tree() and absf(vc.get_global_rect().position.x - uv_panel.get_global_rect().end.x) < 40.0
		if not joined:
			vc.draw_rect(Rect2(0, 0, w, vc.size.y), col)
		var label := "EDIT MODE · %s" % MODE_NAMES[session.mode]
		if session.is_shape():
			label += " · %s Collision Shape" % session.kind.capitalize()
		if session.is_multi():
			label += " · %d objects" % session.members.size()
		if session.xray:
			label += " · X-Ray"
		if tab == 1:
			label += " · UV Edit"
		_label(vc, font, label, top, col)
		top += 22.0
	if session != null:
		_draw_text_overlays(vc, font)
	if session != null and _camera != null and not _camera.is_position_behind(cursor3d):
		var c := _camera.unproject_position(cursor3d)
		var r := 10.0 * EditorInterface.get_editor_scale()
		for i in 8:
			vc.draw_arc(c, r, i * TAU / 8.0, (i + 1) * TAU / 8.0, 4, Color.RED if i % 2 == 0 else Color.WHITE, 2.0, true)
		for d in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			vc.draw_line(c + d * r * 0.5, c + d * r * 1.6, Color.BLACK, 1.0)
	if local_view.active:
		_label(vc, font, "LOCAL VIEW", top, Color(0.7, 0.85, 1.0))
		top += 22.0
	if _message != "":
		_label(vc, font, _message, vc.size.y - 40.0, Color(1, 0.9, 0.6))
	if _box or (_region == "box" and _region_drag):
		vc.draw_rect(_box_rect, Color(1, 1, 1, 0.08), true)
		vc.draw_rect(_box_rect, Color(1, 1, 1, 0.8), false, 1.0)
	if _region != "":
		var hint := "Box Select: drag LMB (MMB / Shift: deselect)   RMB / Esc: cancel" if _region == "box" \
			else "Circle Select: LMB paint, MMB / Shift: deselect, wheel: radius   RMB / Esc / Enter: done"
		_label(vc, font, hint, vc.size.y - 18.0, Color(1, 1, 1, 0.85), 12)
		if _region == "circle":
			vc.draw_arc(_mouse, _circle_radius, 0, TAU, 48, Color(1, 1, 1, 0.9), 1.0, true)
	if modal.active:
		modal.draw(vc)
	elif vmodal.active:
		vmodal.draw(vc)
	elif not _lc.is_empty():
		_draw_loopcut(vc)
	elif session != null and gizmo.enabled() and _camera != null:
		var o = _gizmo_origin()
		if o != null:
			gizmo.draw(vc, _camera, o, orient_basis(), _gizmo_hover)

func _apply_overlays() -> void:
	overlay.show_orientation = bool(settings.get_pref("overlay_face_orientation"))
	overlay.show_normals = bool(settings.get_pref("overlay_normals"))
	if session != null:
		overlay.update(session)
	update_overlays()

## Statistics and edge lengths (Blender viewport overlays), 2D over the view.
func _draw_text_overlays(vc: Control, font: Font) -> void:
	var m = session.mesh
	if bool(settings.get_pref("overlay_stats")):
		var tris := 0
		for f in m.faces:
			tris += f.size() - 2
		var lines := ["Vertices  %d / %d" % [session.selected_verts().size(), m.verts.size()],
			"Edges  %d / %d" % [session.selected_edges().size(), m.edges().size()],
			"Faces  %d / %d" % [session.selected_faces().size(), m.faces.size()],
			"Triangles  %d" % tris]
		for i in lines.size():
			var p := Vector2(12, 84 + i * 16)
			vc.draw_string_outline(font, p, lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.85))
			vc.draw_string(font, p, lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.9))
	if bool(settings.get_pref("overlay_edge_length")) and _camera != null:
		var gx: Transform3D = session.node.global_transform
		var n := 0
		var edges: Dictionary = session.selected_edges().duplicate()
		if modal.active or vmodal.active:
			# While transforming (Extrude, Loop Cut slide, Inset…): also the edges being stretched.
			var sv: Dictionary = session.selected_verts()
			for e in m.edges():
				if sv.has(e.x) != sv.has(e.y):
					edges[e] = true
		for e in edges:
			var a: Vector3 = gx * m.verts[e.x]
			var b: Vector3 = gx * m.verts[e.y]
			var mid := (a + b) * 0.5
			if _camera.is_position_behind(mid) or session.is_edge_hidden(e):
				continue
			var txt := "%.3f" % a.distance_to(b)
			var p := _camera.unproject_position(mid) - Vector2(font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x * 0.5, -4)
			vc.draw_string_outline(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.85))
			vc.draw_string(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1))
			n += 1
			if n >= 300:
				break

func _label(vc: Control, font: Font, text: String, y: float, col: Color, fs := 14) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var pos := Vector2((vc.size.x - w) * 0.5, y)
	vc.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color(0, 0, 0, 0.85))
	vc.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
