## PfModal — Blender-style modal Grab / Rotate / Scale (+ G G vertex slide).
##
##   LMB / Enter / Space  confirm          RMB / Esc     cancel
##   X / Y / Z            constrain to an axis of the Transform Orientation
##                        (again: Global, or Local when the orientation is
##                        Global; again: off) — like Blender 2.8+
##   Shift+X / Y / Z      constrain to the plane excluding that axis
##   digits . - Backspace numeric input (- negates)
##   Ctrl (held)          snap (increment / 5 deg / 0.1), Ctrl+Shift finer
##   Shift (held)         precision (10x slower)
##   G / R / S            switch operation; G again while grabbing = slide
##
## Works on mesh elements of a PfSession or on Node3D objects (optional
## Object Mode shortcuts). One undo step per confirmed operation.
@tool
extends RefCounted

const PfUv := preload("res://addons/polyforge/core/pf_uv.gd")
const PfSelect := preload("res://addons/polyforge/core/pf_select.gd")
const PfBvh := preload("res://addons/polyforge/core/pf_bvh.gd")
const PfI18n := preload("res://addons/polyforge/editor/pf_i18n.gd")

enum Mode { MOVE, ROTATE, SCALE, SLIDE }
enum Target { ELEMENTS, OBJECTS }
enum Constraint { NONE, AXIS, PLANE }

signal finished(committed: bool)

const AXIS_COLORS := [Color(1.0, 0.33, 0.33), Color(0.55, 0.86, 0.2), Color(0.3, 0.55, 1.0)]
const AXIS_NAMES := ["X", "Y", "Z"]
const ROTATE_SNAP_DEG := 5.0
const SCALE_SNAP := 0.1
const PRECISION := 0.1
const HELP := "LMB/Enter: confirm   RMB/Esc: cancel   X Y Z: axis (twice: local)   Shift+X/Y/Z: plane   Ctrl: snap   Shift: precision   type a number"

## Injected by the plugin.
var undo: Object = null              # EditorUndoRedoManager (objects)
var snap_increment := 0.1
var uv_correct := false              # Correct Face Attributes / World-Scale UV
var uv_world := false                # World-Scale UV: scaled faces keep density
var pivot_mode := "median"           # median / bbox / active / individual
var orient_name := "global"          # Transform Orientation: global / local / normal / view
var orient_basis := Basis.IDENTITY   # its world-space axes (set by the plugin)
## Gizmo drag: confirm on LMB release instead of LMB press.
var drag_confirm := false
## Proportional editing (O): falloff over unselected vertices within prop_size.
var prop_enabled := false
var prop_connected := false
var prop_falloff := "smooth"
var prop_size := 1.0
## Snapping (Shift+Tab toggles, Ctrl inverts while transforming); target:
## increment / vertex / edge / face (Blender's Snap To).
var snap_on := false
var snap_target := "increment"
const SNAP_PX := 20.0
var _snap_bvh = null
var snap_point: Variant = null       # world point snapped to (drawn)

## Mesh symmetry (Blender header X/Y/Z): mirrored partners move along (local space).
var mirror_axes := [false, false, false]
## Operators that end in a move (Extrude, Duplicate): one undo step from the
## state before the operator, with its own name.
var undo_base: Dictionary = {}
var undo_label := ""
## World-Scale UV: faces re-projected while moving (new side faces).
var reproject_faces := {}
var reproject_density := 256.0

var active := false
var mode: Mode = Mode.MOVE
var target: Target = Target.ELEMENTS
var constraint: Constraint = Constraint.NONE
var axis := 0
var local_space := false
var numeric := ""
var swallow_lmb_release := false

var _camera: Camera3D = null
var _start_mouse := Vector2.ZERO
var _mouse := Vector2.ZERO
var _last_raw := Vector2.ZERO
var _precision := false
var _snap := false
var _rot_angle := 0.0
var _rot_prev := Vector2.ZERO
var _pivot := Vector3.ZERO           # world
var _local_basis := Basis.IDENTITY
var _orient := Basis.IDENTITY        # first axis press
var _alt := Basis.IDENTITY           # second axis press
var _alt_name := "local"

# Elements
var _s = null                        # PfSession
var _indices := PackedInt32Array()
var _orig := PackedVector3Array()
var _before: Dictionary = {}         # session snapshot for cancel / undo
var _uv_records: Array = []
var _group_of := {}                  # vertex -> group pivot (mesh-local) for individual origins
var _prop_dist := {}                 # unselected vertex -> world distance to the selection
var _mirror := []                    # per enabled axis: [axis, {vertex: partner}]
# Slide
var _slide_dir := {}                 # vertex -> target position (mesh-local)
var _slide_ref := -1

# Objects
var _objects: Array[Node3D] = []
var _orig_globals: Array[Transform3D] = []

var current_xf := Transform3D.IDENTITY
var _readout := ""


# ==============================================================================
# Begin
# ==============================================================================

func begin_elements(p_mode: Mode, camera: Camera3D, mouse: Vector2, s) -> bool:
	if s == null or camera == null:
		return false
	var verts: Dictionary = s.selected_verts()
	if verts.is_empty():
		return false
	_reset()
	target = Target.ELEMENTS
	_s = s
	for v in verts:
		if not s.is_vert_hidden(v):
			_indices.append(v)
	if _indices.is_empty():
		return false
	_before = s.snapshot()
	_orig = s.mesh.verts.duplicate()
	var gx: Transform3D = s.node.global_transform
	_prop_dist = _proportional_distances(s, gx) if prop_enabled and p_mode != Mode.SLIDE else {}
	_mirror = []
	for a in 3:
		if mirror_axes[a]:
			var moving: Array = Array(_indices) + _prop_dist.keys()
			_mirror.append([a, mirror_partners(s.mesh, moving, a)])
	_pivot = gx * _compute_pivot_local()
	_local_basis = gx.basis.orthonormalized()
	_setup_frames()
	_start(p_mode, camera, mouse)
	return true

## First axis press = Transform Orientation, second = Global (Local when the
## orientation is Global).
## Distance of every reachable unselected vertex to the selection: straight
## line, or along edges with Connected Only (Blender).
func _proportional_distances(s, gx: Transform3D) -> Dictionary:
	var m = s.mesh
	var wp := PackedVector3Array()
	wp.resize(m.verts.size())
	for v in m.verts.size():
		wp[v] = gx * m.verts[v]
	var sel := {}
	for v in _indices:
		sel[v] = true
	var out := {}
	if prop_connected:
		var dist := {}
		var queue: Array = _indices.duplicate()
		for v in _indices:
			dist[v] = 0.0
		while not queue.is_empty():
			var v: int = queue.pop_back()
			for e in m.vert_edges(v):
				var o: int = e.y if e.x == v else e.x
				if s.is_vert_hidden(o):
					continue
				var d: float = dist[v] + wp[v].distance_to(wp[o])
				if d < dist.get(o, INF):
					dist[o] = d
					queue.append(o)
		for v in dist:
			if not sel.has(v):
				out[v] = dist[v]
		return out
	for v in m.verts.size():
		if sel.has(v) or s.is_vert_hidden(v):
			continue
		var best := INF
		for sv in _indices:
			best = minf(best, wp[v].distance_squared_to(wp[sv]))
		out[v] = sqrt(best)
	return out

## Vertex -> its mirror partner across local plane `axis` = 0 (itself on the plane).
static func mirror_partners(m, verts: Array, axis: int) -> Dictionary:
	var at := {}
	for v in m.verts.size():
		at[Vector3i((m.verts[v] * 1000.0).round())] = v
	var out := {}
	for v in verts:
		var p: Vector3 = m.verts[v]
		p[axis] = -p[axis]
		var o = at.get(Vector3i((p * 1000.0).round()))
		if o != null:
			out[v] = o
	return out

static func falloff(kind: String, t: float) -> float:
	match kind:
		"sphere": return sqrt(maxf(2.0 * t - t * t, 0.0))
		"root": return sqrt(t)
		"inverse_square": return t * (2.0 - t)
		"sharp": return t * t
		"linear": return t
		"constant": return 1.0
	return 3.0 * t * t - 2.0 * t * t * t

func _setup_frames() -> void:
	if orient_name == "global":
		_orient = Basis.IDENTITY
		_alt = _local_basis
		_alt_name = "local"
	else:
		_orient = orient_basis.orthonormalized()
		_alt = Basis.IDENTITY
		_alt_name = "global"

## Gizmo handles start with a constraint already set (first-press frame).
func preset_constraint(kind: Constraint, p_axis: int) -> void:
	constraint = kind
	axis = p_axis
	local_space = false
	_update()

## Pivot of the current selection (mesh-local) without starting a modal —
## used to place the gizmo. Individual Origins shows the median.
static func selection_pivot(s, p_pivot_mode: String) -> Variant:
	var verts: Dictionary = s.selected_verts()
	var pts := []
	for v in verts:
		if not s.is_vert_hidden(v):
			pts.append(s.mesh.verts[v])
	if pts.is_empty():
		return null
	if p_pivot_mode == "bbox":
		var bb := AABB(pts[0], Vector3.ZERO)
		for p in pts:
			bb = bb.expand(p)
		return bb.get_center()
	if p_pivot_mode == "cursor":
		return s.node.global_transform.affine_inverse() * s.plugin.cursor3d
	if p_pivot_mode == "active":
		var ap = s.active_position()
		if ap != null:
			return ap
	var sum := Vector3.ZERO
	for p in pts:
		sum += p
	return sum / float(pts.size())

func _compute_pivot_local() -> Vector3:
	var m = _s.mesh
	_group_of.clear()
	match pivot_mode:
		"bbox":
			var bb := AABB(m.verts[_indices[0]], Vector3.ZERO)
			for v in _indices:
				bb = bb.expand(m.verts[v])
			return bb.get_center()
		"active":
			var ap = _s.active_position()
			if ap != null:
				return ap
		"individual":
			_build_groups()
		"cursor":
			return _s.node.global_transform.affine_inverse() * _s.plugin.cursor3d
	var sum := Vector3.ZERO
	for v in _indices:
		sum += m.verts[v]
	return sum / float(_indices.size())

## Individual origins: connected parts of the selection, each with its centre.
func _build_groups() -> void:
	var m = _s.mesh
	var sel := {}
	for v in _indices:
		sel[v] = true
	var seen := {}
	for v0 in _indices:
		if seen.has(v0):
			continue
		var comp := []
		var stack := [v0]
		while not stack.is_empty():
			var v: int = stack.pop_back()
			if seen.has(v):
				continue
			seen[v] = true
			comp.append(v)
			for e in m.vert_edges(v):
				var w: int = e.y if e.x == v else e.x
				if sel.has(w) and not seen.has(w):
					stack.append(w)
		var c := Vector3.ZERO
		for v in comp:
			c += m.verts[v]
		c /= float(comp.size())
		for v in comp:
			_group_of[v] = c

func begin_objects(p_mode: Mode, camera: Camera3D, mouse: Vector2, nodes: Array[Node3D]) -> bool:
	if nodes.is_empty() or camera == null:
		return false
	_reset()
	target = Target.OBJECTS
	var sum := Vector3.ZERO
	for n in nodes:
		_objects.append(n)
		_orig_globals.append(n.global_transform)
		sum += n.global_position
	_pivot = sum / float(nodes.size())
	_local_basis = nodes[0].global_transform.basis.orthonormalized()
	_setup_frames()
	_start(p_mode, camera, mouse)
	return true

func _start(p_mode: Mode, camera: Camera3D, mouse: Vector2) -> void:
	mode = p_mode
	_camera = camera
	_start_mouse = mouse
	_mouse = mouse
	_last_raw = mouse
	_rot_angle = 0.0
	_rot_prev = mouse - _pivot_screen()
	active = true
	if target == Target.ELEMENTS:
		_capture_uv()
		if mode == Mode.SLIDE:
			_prepare_slide()
	_update()

func _capture_uv() -> void:
	_uv_records = []
	if not (uv_correct or uv_world) or _s == null:
		return
	var moved := {}
	for v in _indices:
		moved[v] = true
	for v in _prop_dist:
		moved[v] = true
	for mp in _mirror:
		for v in mp[1]:
			moved[mp[1][v]] = true
	_uv_records = PfUv.capture(_s.mesh, moved, uv_world and mode == Mode.SCALE)

func _reset() -> void:
	active = false
	_snap_bvh = null
	snap_point = null
	_prop_dist = {}
	_mirror = []
	constraint = Constraint.NONE
	axis = 0
	local_space = false
	drag_confirm = false
	undo_base = {}
	undo_label = ""
	reproject_faces = {}
	numeric = ""
	_precision = false
	_snap = false
	_s = null
	_indices = PackedInt32Array()
	_orig = PackedVector3Array()
	_before = {}
	_uv_records = []
	_group_of.clear()
	_slide_dir.clear()
	_slide_ref = -1
	_objects.clear()
	_orig_globals.clear()
	current_xf = Transform3D.IDENTITY
	_readout = ""

## G <-> R <-> S mid-operation: restart from the current mouse, geometry reset.
## G while grabbing elements = vertex slide (Blender G G).
func switch_mode(p_mode: Mode) -> void:
	if not active:
		return
	if p_mode == Mode.MOVE and mode == Mode.MOVE and target == Target.ELEMENTS:
		p_mode = Mode.SLIDE
	elif p_mode == mode:
		return
	_restore_geometry()
	numeric = ""
	constraint = Constraint.NONE
	_start(p_mode, _camera, _mouse)


# ==============================================================================
# Input
# ==============================================================================

func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if not active:
		return false
	if camera != null:
		_camera = camera
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var delta := mm.position - _last_raw
		_last_raw = mm.position
		_precision = mm.shift_pressed
		_snap = mm.ctrl_pressed
		_mouse += delta * (PRECISION if _precision else 1.0)
		if mode == Mode.ROTATE:
			_accumulate_rotation()
		_update()
		return true
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			if drag_confirm and mb.button_index == MOUSE_BUTTON_LEFT:
				confirm()   # gizmo drag: releasing the handle confirms
			return true
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				swallow_lmb_release = true
				confirm()
			MOUSE_BUTTON_RIGHT:
				cancel()
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if not _prop_dist.is_empty():
					prop_size = maxf(prop_size * (1.1 if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN else 1.0 / 1.1), 0.001)
					_update()
		return true
	if event is InputEventKey:
		var k := event as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if code == KEY_CTRL or code == KEY_SHIFT:
			if code == KEY_CTRL:
				_snap = k.pressed
			else:
				_precision = k.pressed
			_update()
			return true
		if not k.pressed:
			return true
		match code:
			KEY_ESCAPE:
				cancel()
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				confirm()
			KEY_X, KEY_Y, KEY_Z:
				if mode != Mode.SLIDE:
					_toggle_constraint({KEY_X: 0, KEY_Y: 1, KEY_Z: 2}[code], k.shift_pressed)
			KEY_PAGEUP, KEY_PAGEDOWN:
				if not _prop_dist.is_empty():
					prop_size = maxf(prop_size * (1.1 if code == KEY_PAGEUP else 1.0 / 1.1), 0.001)
					_update()
			KEY_G:
				switch_mode(Mode.MOVE)
			KEY_R:
				switch_mode(Mode.ROTATE)
			KEY_S:
				switch_mode(Mode.SCALE)
			KEY_BACKSPACE:
				if not numeric.is_empty():
					numeric = numeric.substr(0, numeric.length() - 1)
					_update()
			KEY_MINUS, KEY_KP_SUBTRACT:
				numeric = numeric.substr(1) if numeric.begins_with("-") else "-" + numeric
				_update()
			KEY_PERIOD, KEY_KP_PERIOD, KEY_COMMA:
				if not numeric.contains("."):
					numeric += "."
					_update()
			_:
				var digit := _digit_of(code)
				if digit >= 0:
					numeric += str(digit)
					_update()
		return true
	return true

static func _digit_of(code: int) -> int:
	if code >= KEY_0 and code <= KEY_9:
		return code - KEY_0
	if code >= KEY_KP_0 and code <= KEY_KP_9:
		return code - KEY_KP_0
	return -1

func _toggle_constraint(p_axis: int, plane: bool) -> void:
	var wanted := Constraint.PLANE if plane else Constraint.AXIS
	if constraint == wanted and axis == p_axis:
		if not local_space:
			local_space = true
		else:
			constraint = Constraint.NONE
			local_space = false
	else:
		constraint = wanted
		axis = p_axis
		local_space = false
	_update()


# ==============================================================================
# Confirm / cancel
# ==============================================================================

func confirm() -> void:
	if not active:
		return
	_update()
	active = false
	var ok := _commit()
	finished.emit(ok)

func cancel() -> void:
	if not active:
		return
	active = false
	if target == Target.ELEMENTS and _s != null and _s.is_valid():
		_s.restore(_before)
	else:
		_restore_geometry()
	finished.emit(false)

func _restore_geometry() -> void:
	match target:
		Target.ELEMENTS:
			if _s != null and _s.is_valid():
				_s.mesh.verts = _orig.duplicate()
				# UVs back to the captured state (records hold the old UVs).
				var snap_mesh = _before.get("mesh", {})
				if not snap_mesh.is_empty():
					var tmp = _s.mesh.get_script().new()
					tmp.from_dict(snap_mesh)
					_s.mesh.uvs = tmp.uvs
				_s.rebuild(true)
		Target.OBJECTS:
			for i in _objects.size():
				if is_instance_valid(_objects[i]):
					_objects[i].global_transform = _orig_globals[i]

func _commit() -> bool:
	match target:
		Target.ELEMENTS:
			if _s == null or not _s.is_valid():
				return false
			var changed := false
			for v in _indices:
				if not _orig[v].is_equal_approx(_s.mesh.verts[v]):
					changed = true
					break
			if not changed:
				_s.restore(_before)
				return false
			_s.commit_undo(undo_label if undo_label != "" else action_name(),
				undo_base if not undo_base.is_empty() else _before)
			return true
		Target.OBJECTS:
			var any := false
			for i in _objects.size():
				if is_instance_valid(_objects[i]) and not _objects[i].global_transform.is_equal_approx(_orig_globals[i]):
					any = true
			if not any or undo == null:
				return any
			undo.create_action("Polyforge: " + action_name(), UndoRedo.MERGE_DISABLE, _objects[0])
			for i in _objects.size():
				var n := _objects[i]
				if not is_instance_valid(n):
					continue
				var parent_xf := Transform3D.IDENTITY
				if n.get_parent() is Node3D:
					parent_xf = (n.get_parent() as Node3D).global_transform
				undo.add_do_property(n, "transform", n.transform)
				undo.add_undo_property(n, "transform", parent_xf.affine_inverse() * _orig_globals[i])
			undo.commit_action(false)
			return true
	return false

func action_name() -> String:
	var what := "Elements" if target == Target.ELEMENTS else "Objects"
	match mode:
		Mode.MOVE: return "Move " + what
		Mode.ROTATE: return "Rotate " + what
		Mode.SLIDE: return "Vertex Slide"
	return "Scale " + what


# ==============================================================================
# Transform computation
# ==============================================================================

func _frame() -> Basis:
	return _alt if local_space else _orient

func _axis_dir() -> Vector3:
	return _frame()[axis].normalized()

func _pivot_screen() -> Vector2:
	return _camera.unproject_position(_pivot) if _camera != null else Vector2.ZERO

func _numeric_value() -> Variant:
	if numeric.is_empty() or numeric in ["-", ".", "-."]:
		return null
	return numeric.to_float()

func _snap_step() -> float:
	return snap_increment * (0.1 if _precision else 1.0)

func _accumulate_rotation() -> void:
	var v := _mouse - _pivot_screen()
	if v.length() < 2.0 or _rot_prev.length() < 2.0:
		_rot_prev = v
		return
	_rot_angle += _rot_prev.angle_to(v)
	_rot_prev = v

func _plane_hit(screen: Vector2, n: Vector3) -> Variant:
	return Plane(n, _pivot).intersects_ray(_camera.project_ray_origin(screen), _camera.project_ray_normal(screen))

func _axis_param(screen: Vector2, dir: Vector3) -> Variant:
	var o := _camera.project_ray_origin(screen)
	var d := _camera.project_ray_normal(screen)
	var w := _pivot - o
	var b := dir.dot(d)
	var denom := 1.0 - b * b
	if denom < 0.0001:
		return null
	return (b * d.dot(w) - dir.dot(w)) / denom

func _compute_translation() -> Vector3:
	var num: Variant = _numeric_value()
	var cam_fwd := -_camera.global_transform.basis.z
	var delta := Vector3.ZERO
	match constraint:
		Constraint.AXIS:
			var dir := _axis_dir()
			if num != null:
				delta = dir * float(num)
			else:
				var t0: Variant = _axis_param(_start_mouse, dir)
				var t1: Variant = _axis_param(_mouse, dir)
				var t := 0.0
				if t0 != null and t1 != null:
					t = float(t1) - float(t0)
				if _snapping():
					t = snappedf(t, _snap_step())
				delta = dir * t
		Constraint.PLANE:
			var n := _axis_dir()
			if num != null:
				delta = _frame()[(axis + 1) % 3].normalized() * float(num)
			else:
				var h0: Variant = _plane_hit(_start_mouse, n)
				var h1: Variant = _plane_hit(_mouse, n)
				if h0 == null or h1 == null or absf(n.dot(cam_fwd)) < 0.05:
					h0 = _plane_hit(_start_mouse, cam_fwd)
					h1 = _plane_hit(_mouse, cam_fwd)
				if h0 != null and h1 != null:
					delta = h1 - h0
					delta -= n * n.dot(delta)
				if _snapping():
					delta = _snap_in_frame(delta)
		_:
			if num != null:
				delta = Vector3(float(num), 0, 0)
			else:
				var h0: Variant = _plane_hit(_start_mouse, cam_fwd)
				var h1: Variant = _plane_hit(_mouse, cam_fwd)
				if h0 != null and h1 != null:
					delta = h1 - h0
				if _snapping():
					delta = _snap_in_frame(delta)
	return _element_snap(delta)

func _snapping() -> bool:
	return _snap != snap_on

## Element snapping (Move): the selected vertex closest to the target lands
## on the vertex / edge / face under the mouse; constraints still apply.
func _element_snap(delta: Vector3) -> Vector3:
	snap_point = null
	if not _snapping() or snap_target == "increment" or target != Target.ELEMENTS or _numeric_value() != null:
		return delta
	var gx: Transform3D = _s.node.global_transform
	var m = _s.mesh
	var moving := {}
	for v in _indices:
		moving[v] = true
	for v in _prop_dist:
		moving[v] = true
	var hit: Variant = null
	match snap_target:
		"vertex":
			var best := SNAP_PX
			for v in m.verts.size():
				if moving.has(v) or _s.is_vert_hidden(v):
					continue
				var w: Vector3 = gx * _orig[v]
				if _camera.is_position_behind(w):
					continue
				var d := _camera.unproject_position(w).distance_to(_mouse)
				if d < best:
					best = d
					hit = w
		"edge":
			var best := SNAP_PX
			var ro := _camera.project_ray_origin(_mouse)
			var rd := _camera.project_ray_normal(_mouse)
			for e in m.edges():
				if moving.has(e.x) or moving.has(e.y) or _s.is_edge_hidden(e):
					continue
				var a: Vector3 = gx * _orig[e.x]
				var b: Vector3 = gx * _orig[e.y]
				var pts := Geometry3D.get_closest_points_between_segments(a, b, ro, ro + rd * 1e5)
				var p: Vector3 = pts[0]
				if _camera.is_position_behind(p):
					continue
				var d := _camera.unproject_position(p).distance_to(_mouse)
				if d < best:
					best = d
					hit = p
		"face":
			if _snap_bvh == null:
				var skip := {}
				for v in moving:
					for f in m.vert_faces(v):
						skip[f] = true
				var tmp = m.duplicate_mesh()
				tmp.verts = _orig
				_snap_bvh = PfBvh.new()
				_snap_bvh.build(tmp, skip)
			var inv := gx.affine_inverse()
			var r: Dictionary = _snap_bvh.raycast(inv * _camera.project_ray_origin(_mouse), (inv.basis * _camera.project_ray_normal(_mouse)).normalized())
			if not r.is_empty():
				hit = gx * (r["point"] as Vector3)
	if hit == null:
		return delta
	var base := Vector3.ZERO
	var bd := INF
	for v in _indices:
		var w: Vector3 = gx * _orig[v]
		if w.distance_squared_to(hit) < bd:
			bd = w.distance_squared_to(hit)
			base = w
	var t: Vector3 = hit - base
	match constraint:
		Constraint.AXIS:
			var dir := _axis_dir().normalized()
			t = dir * dir.dot(t)
		Constraint.PLANE:
			var n := _axis_dir().normalized()
			t -= n * n.dot(t)
	snap_point = hit
	return t

func _snap_in_frame(v: Vector3) -> Vector3:
	var f := _frame()
	var step := _snap_step()
	var l := f.inverse() * v
	return f * Vector3(snappedf(l.x, step), snappedf(l.y, step), snappedf(l.z, step))

func _compute_rotation() -> Array:
	var cam_back := _camera.global_transform.basis.z
	var rot_axis := cam_back
	if constraint != Constraint.NONE:
		rot_axis = _axis_dir()
	var num: Variant = _numeric_value()
	var angle := 0.0
	if num != null:
		angle = deg_to_rad(float(num))
	else:
		angle = -_rot_angle
		if rot_axis.dot(cam_back) < 0.0:
			angle = -angle
		if _snapping():
			angle = deg_to_rad(snappedf(rad_to_deg(angle), ROTATE_SNAP_DEG * (0.2 if _precision else 1.0)))
	return [rot_axis.normalized(), angle]

func _compute_scale() -> float:
	var num: Variant = _numeric_value()
	if num != null:
		return float(num)
	var ps := _pivot_screen()
	var d0 := maxf(_start_mouse.distance_to(ps), 4.0)
	var f := _mouse.distance_to(ps) / d0
	if _snapping():
		f = snappedf(f, SCALE_SNAP * (0.1 if _precision else 1.0))
	return f

func _update() -> void:
	if not active or _camera == null:
		return
	if mode == Mode.SLIDE:
		_update_slide()
		return
	var xf := Transform3D.IDENTITY
	var space := _alt_name if local_space else orient_name
	var con := ""
	if constraint == Constraint.AXIS:
		con = PfI18n.t(" along %s %s") % [PfI18n.t(space.capitalize()), AXIS_NAMES[axis]]
	elif constraint == Constraint.PLANE:
		con = PfI18n.t(" locking %s %s") % [PfI18n.t(space.capitalize()), AXIS_NAMES[axis]]
	var num_txt := (" [%s|]" % numeric) if not numeric.is_empty() else ""
	var basis := Basis.IDENTITY
	match mode:
		Mode.MOVE:
			var t := _compute_translation()
			xf = Transform3D(Basis.IDENTITY, t)
			var shown := _frame().inverse() * t
			if constraint == Constraint.AXIS:
				_readout = PfI18n.t("Move  D: %.4f%s%s") % [shown[axis], num_txt, con]
			else:
				_readout = PfI18n.t("Move  Dx: %.4f  Dy: %.4f  Dz: %.4f%s%s") % [shown.x, shown.y, shown.z, num_txt, con]
		Mode.ROTATE:
			var r := _compute_rotation()
			basis = Basis(r[0], r[1])
			xf = Transform3D(basis, _pivot - basis * _pivot)
			_readout = PfI18n.t("Rotate  %.2f°%s%s") % [rad_to_deg(r[1]), num_txt, con if constraint != Constraint.NONE else PfI18n.t(" (view axis)")]
		Mode.SCALE:
			var f := _compute_scale()
			var sv := Vector3.ONE * f
			if constraint == Constraint.AXIS:
				sv = Vector3.ONE
				sv[axis] = f
			elif constraint == Constraint.PLANE:
				sv[axis] = 1.0
			var fr := _frame()
			basis = fr * Basis.from_scale(sv) * fr.inverse()
			xf = Transform3D(basis, _pivot - basis * _pivot)
			_readout = PfI18n.t("Scale  %.4f%s%s") % [f, num_txt, con]
	if not _prop_dist.is_empty():
		_readout += PfI18n.t("  Proportional size: %.3f") % prop_size
	current_xf = xf
	_apply(xf, basis)

func _apply(xf: Transform3D, world_basis: Basis) -> void:
	match target:
		Target.ELEMENTS:
			if _s == null or not _s.is_valid():
				return
			var gx: Transform3D = _s.node.global_transform
			var to_local := gx.affine_inverse() * xf * gx
			var verts: PackedVector3Array = _orig.duplicate()
			if not _group_of.is_empty() and mode != Mode.MOVE:
				var lb := gx.basis.inverse() * world_basis * gx.basis
				for v in _indices:
					var c: Vector3 = _group_of[v]
					verts[v] = c + lb * (_orig[v] - c)
			else:
				for v in _indices:
					verts[v] = to_local * _orig[v]
			var q := Quaternion(world_basis.orthonormalized()) if mode == Mode.ROTATE else Quaternion.IDENTITY
			for v in _prop_dist:
				var d: float = _prop_dist[v]
				if d >= prop_size:
					continue
				var w := falloff(prop_falloff, 1.0 - d / prop_size)
				if mode == Mode.ROTATE:
					var b := Basis(Quaternion.IDENTITY.slerp(q, w))
					verts[v] = gx.affine_inverse() * Transform3D(b, _pivot - b * _pivot) * gx * _orig[v]
				else:
					verts[v] = _orig[v].lerp(to_local * _orig[v], w)
			for mp in _mirror:
				var a: int = mp[0]
				for v in mp[1]:
					var o: int = mp[1][v]
					var r: Vector3 = verts[v]
					if o == v:
						r[a] = 0.0
						verts[v] = r
					elif not mp[1].has(o):
						r[a] = -r[a]
						verts[o] = r
			_s.mesh.verts = verts
			_s.mesh.invalidate()
			if not _uv_records.is_empty():
				PfUv.apply(_s.mesh, _uv_records, gx.affine_inverse() * _pivot)
			if not reproject_faces.is_empty():
				PfUv.cube_project_world(_s.mesh, reproject_density, PackedInt32Array(reproject_faces.keys()))
			_s.rebuild(true)
		Target.OBJECTS:
			for i in _objects.size():
				if is_instance_valid(_objects[i]):
					_objects[i].global_transform = xf * _orig_globals[i]


# ==============================================================================
# Vertex slide (G G)
# ==============================================================================

## Each moving vertex slides along one connected edge leading out of the
## selection: the edge best aligned with the reference edge (the one of the
## vertex nearest to the mouse), like Blender's vertex slide.
func _prepare_slide() -> void:
	_slide_dir.clear()
	var m = _s.mesh
	var gx: Transform3D = _s.node.global_transform
	var sel := {}
	for v in _indices:
		sel[v] = true
	# Reference vertex: nearest to the mouse on screen.
	var best := INF
	for v in _indices:
		var sp := _camera.unproject_position(gx * m.verts[v])
		if sp.distance_to(_start_mouse) < best:
			best = sp.distance_to(_start_mouse)
			_slide_ref = v
	_readout = PfI18n.t("Vertex Slide  (move the mouse along an edge)")

func _pick_slide_targets(screen_dir: Vector2) -> void:
	var m = _s.mesh
	var gx: Transform3D = _s.node.global_transform
	var sel := {}
	for v in _indices:
		sel[v] = true
	# Reference direction in world space from the reference vertex's best edge.
	var ref_dir := Vector3.ZERO
	var best := -INF
	for e in m.vert_edges(_slide_ref):
		var w: int = e.y if e.x == _slide_ref else e.x
		if sel.has(w) and _indices.size() > 1:
			continue
		var a := _camera.unproject_position(gx * _orig[_slide_ref])
		var b := _camera.unproject_position(gx * _orig[w])
		var sd := (b - a)
		if sd.length() < 1e-3:
			continue
		var score := sd.normalized().dot(screen_dir)
		if score > best:
			best = score
			ref_dir = (_orig[w] - _orig[_slide_ref]).normalized()
	for v in _indices:
		var bt := -INF
		var target := _orig[v]
		for e in m.vert_edges(v):
			var w: int = e.y if e.x == v else e.x
			if sel.has(w) and _indices.size() > 1:
				continue
			var d := (_orig[w] - _orig[v])
			if d.length_squared() < 1e-12:
				continue
			var score := d.normalized().dot(ref_dir) if ref_dir != Vector3.ZERO else 0.0
			if score > bt:
				bt = score
				target = _orig[w]
		_slide_dir[v] = target

func _update_slide() -> void:
	var delta := _mouse - _start_mouse
	if _slide_dir.is_empty():
		if delta.length() < 4.0 and _numeric_value() == null:
			return
		_pick_slide_targets(delta.normalized() if delta.length() > 0.0 else Vector2.RIGHT)
	var gx: Transform3D = _s.node.global_transform
	var a := _camera.unproject_position(gx * _orig[_slide_ref])
	var b := _camera.unproject_position(gx * (_slide_dir[_slide_ref] as Vector3))
	var seg := b - a
	var t := 0.0
	var num: Variant = _numeric_value()
	if num != null:
		t = float(num)
	elif seg.length_squared() > 1e-6:
		t = clampf(delta.dot(seg) / seg.length_squared(), 0.0, 1.0)
		if _snapping():
			t = snappedf(t, 0.1)
	var verts: PackedVector3Array = _orig.duplicate()
	for v in _indices:
		verts[v] = _orig[v].lerp(_slide_dir[v], t)
	_s.mesh.verts = verts
	_s.mesh.invalidate()
	if not _uv_records.is_empty():
		PfUv.apply(_s.mesh, _uv_records)
	_s.rebuild(true)
	_readout = PfI18n.t("Vertex Slide  Factor: %.4f%s") % [t, (" [%s|]" % numeric) if not numeric.is_empty() else ""]


# ==============================================================================
# HUD
# ==============================================================================

func header_text() -> String:
	return _readout

func draw(overlay: Control) -> void:
	if not active or _camera == null:
		return
	var font := overlay.get_theme_default_font()
	if font == null:
		font = ThemeDB.fallback_font
	var ps := _pivot_screen()
	if constraint != Constraint.NONE and not _camera.is_position_behind(_pivot):
		var dirs: Array[int] = [axis]
		if constraint == Constraint.PLANE:
			dirs = [(axis + 1) % 3, (axis + 2) % 3]
		var cam_pos := _camera.global_position
		var cam_fwd := -_camera.global_transform.basis.z
		var near := _camera.near * 2.0
		for a in dirs:
			var d := _frame()[a].normalized()
			var e0 := _clip(_pivot - d * 10000.0, _pivot, cam_pos, cam_fwd, near)
			var e1 := _clip(_pivot + d * 10000.0, _pivot, cam_pos, cam_fwd, near)
			overlay.draw_line(_camera.unproject_position(e0), _camera.unproject_position(e1), AXIS_COLORS[a], 1.5, true)
	if mode == Mode.ROTATE or mode == Mode.SCALE:
		overlay.draw_dashed_line(ps, _mouse, Color(1, 1, 1, 0.8), 1.0, 6.0)
	overlay.draw_circle(ps, 3.0, Color(1, 1, 1, 0.9))
	if snap_point != null and not _camera.is_position_behind(snap_point):
		overlay.draw_arc(_camera.unproject_position(snap_point), 7.0, 0, TAU, 24, Color(1, 0.6, 0.1), 2.0, true)
	if not _prop_dist.is_empty() and not _camera.is_position_behind(_pivot):
		var edge := _camera.unproject_position(_pivot + _camera.global_transform.basis.x * prop_size)
		overlay.draw_arc(ps, ps.distance_to(edge), 0, TAU, 64, Color(1, 1, 1, 0.6), 1.0, true)
	var pos := Vector2(12, 52)
	overlay.draw_string_outline(font, pos, _readout, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 6, Color(0, 0, 0, 0.9))
	overlay.draw_string(font, pos, _readout, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color.WHITE)
	var hp := Vector2(12, overlay.size.y - 12)
	overlay.draw_string_outline(font, hp, PfI18n.t(HELP), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 5, Color(0, 0, 0, 0.9))
	overlay.draw_string(font, hp, PfI18n.t(HELP), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))

static func _clip(p: Vector3, anchor: Vector3, cam_pos: Vector3, cam_fwd: Vector3, near: float) -> Vector3:
	var dp := (p - cam_pos).dot(cam_fwd)
	if dp >= near:
		return p
	var da := (anchor - cam_pos).dot(cam_fwd)
	if da <= near:
		return anchor
	return anchor.lerp(p, (da - near) / (da - dp))
