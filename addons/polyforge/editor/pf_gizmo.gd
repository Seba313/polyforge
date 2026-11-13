## PfGizmo — optional transform gizmo for Edit Mode selections (like the
## MeshBuilder / Blender gizmos): Move (axis arrows, plane squares, free-move
## centre), Rotate (axis rings, view ring) and Scale (axis boxes, uniform
## ring). Oriented by the Transform Orientation, constant size on screen.
## Dragging a handle starts the modal transform with the matching constraint;
## releasing the button confirms.
@tool
extends RefCounted

const AXIS_COLORS := [Color(1.0, 0.33, 0.33), Color(0.55, 0.86, 0.2), Color(0.3, 0.55, 1.0)]
const SIZE_PX := 100.0
const PICK_PX := 8.0

## Editor UI scale (HiDPI): the gizmo keeps the same size as Godot's own.
var ui_scale := 1.0
var show_move := false
var show_rotate := false
var show_scale := false

func enabled() -> bool:
	return show_move or show_rotate or show_scale


## World length of `px` screen pixels at `origin`.
static func world_per_px(camera: Camera3D, origin: Vector3) -> float:
	var h := float(camera.get_viewport().get_visible_rect().size.y)
	if h <= 0.0:
		h = 600.0
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return camera.size / h
	var d := (origin - camera.global_position).dot(-camera.global_transform.basis.z)
	return 2.0 * maxf(d, 0.001) * tan(deg_to_rad(camera.fov) * 0.5) / h

## Screen-space handles: Array of dictionaries
##   {"id", "op": "move"/"rotate"/"scale", "con": "axis"/"plane"/"none",
##    "axis", "pts": PackedVector2Array (polyline) | "rect": PackedVector2Array | "center", "radius"}
func handles(camera: Camera3D, origin: Vector3, b: Basis) -> Array:
	var out := []
	if camera.is_position_behind(origin):
		return out
	var o2 := camera.unproject_position(origin)
	var px := SIZE_PX * ui_scale
	var L := px * world_per_px(camera, origin)
	for a in 3:
		var dir := b[a].normalized()
		var tip := origin + dir * L
		if camera.is_position_behind(tip):
			continue
		var t2 := camera.unproject_position(tip)
		var visible_axis := t2.distance_to(o2) > 12.0   # hidden when pointing at the viewer
		if show_move and visible_axis:
			out.append({"id": "move_%d" % a, "op": "move", "con": "axis", "axis": a,
				"pts": PackedVector2Array([camera.unproject_position(origin + dir * L * 0.2), t2])})
		if show_scale and visible_axis:
			var sl := 0.7 if show_move else 1.0
			var s2 := camera.unproject_position(origin + dir * L * sl)
			out.append({"id": "scale_%d" % a, "op": "scale", "con": "axis", "axis": a,
				"pts": PackedVector2Array([camera.unproject_position(origin + dir * L * 0.2), s2]), "box": s2})
		if show_move:
			# Plane square between the two other axes (constraint: plane normal a).
			var u := b[(a + 1) % 3].normalized() * L
			var v := b[(a + 2) % 3].normalized() * L
			var c := origin + (u + v) * 0.3
			var q := PackedVector2Array()
			for k in [[-1, -1], [1, -1], [1, 1], [-1, 1]]:
				q.append(camera.unproject_position(c + (u * k[0] + v * k[1]) * 0.07))
			if _area(q) > 30.0:
				out.append({"id": "plane_%d" % a, "op": "move", "con": "plane", "axis": a, "rect": q})
		if show_rotate:
			var ring := PackedVector2Array()
			var u := _perp(dir)
			var w := dir.cross(u)
			for i in 49:
				var ang := TAU * float(i) / 48.0
				ring.append(camera.unproject_position(origin + (u * cos(ang) + w * sin(ang)) * L * 0.8))
			out.append({"id": "rot_%d" % a, "op": "rotate", "con": "axis", "axis": a, "pts": ring})
	if show_rotate:
		out.append({"id": "rot_view", "op": "rotate", "con": "none", "axis": 0, "center": o2, "radius": px * 1.0})
	if show_scale:
		out.append({"id": "scale_all", "op": "scale", "con": "none", "axis": 0, "center": o2, "radius": px * (1.2 if show_rotate else 1.0)})
	if show_move:
		out.append({"id": "move_free", "op": "move", "con": "none", "axis": 0, "dot": o2})
	return out

## Handle under the mouse ({} when none). Small targets win over rings.
func pick(camera: Camera3D, origin: Vector3, b: Basis, mouse: Vector2) -> Dictionary:
	var hs := handles(camera, origin, b)
	for h in hs:
		if h.has("dot") and mouse.distance_to(h["dot"]) <= 10.0:
			return h
	for h in hs:
		if h.has("rect") and Geometry2D.is_point_in_polygon(mouse, h["rect"]):
			return h
	var best := {}
	var best_d := PICK_PX
	for h in hs:
		var d := INF
		if h.has("box"):
			d = mouse.distance_to(h["box"]) - 4.0
		if h.has("pts"):
			d = minf(d, _dist_polyline(mouse, h["pts"]))
		elif h.has("radius"):
			d = absf(mouse.distance_to(h["center"]) - h["radius"])
		if d < best_d:
			best_d = d
			best = h
	return best

func draw(ctl: Control, camera: Camera3D, origin: Vector3, b: Basis, hover_id: String) -> void:
	for h in handles(camera, origin, b):
		var hot: bool = h["id"] == hover_id
		var col: Color = AXIS_COLORS[h["axis"]] if h["con"] != "none" else Color(1, 1, 1, 0.8)
		if h["con"] == "plane":
			col = AXIS_COLORS[h["axis"]]
		if hot:
			col = col.lightened(0.5)
		var w := 3.0 if hot else 2.0
		if h.has("rect"):
			ctl.draw_colored_polygon(h["rect"], Color(col, 0.45))
			var r: PackedVector2Array = h["rect"].duplicate()
			r.append(r[0])
			ctl.draw_polyline(r, col, 1.0, true)
		elif h.has("dot"):
			ctl.draw_arc(h["dot"], 9.0, 0, TAU, 24, col, w, true)
		elif h.has("radius"):
			ctl.draw_arc(h["center"], h["radius"], 0, TAU, 64, Color(col, 0.6 if not hot else 1.0), w * 0.75, true)
		elif h.has("pts"):
			var pts: PackedVector2Array = h["pts"]
			ctl.draw_polyline(pts, col, w, true)
			if h["op"] == "move":
				_arrow_head(ctl, pts[0], pts[pts.size() - 1], col)
			elif h.has("box"):
				var c: Vector2 = h["box"]
				ctl.draw_rect(Rect2(c - Vector2(5, 5), Vector2(10, 10)), col)

static func _arrow_head(ctl: Control, a: Vector2, b: Vector2, col: Color) -> void:
	var d := (b - a)
	if d.length() < 1.0:
		return
	d = d.normalized()
	var n := Vector2(-d.y, d.x)
	ctl.draw_colored_polygon(PackedVector2Array([b + d * 12.0, b + n * 6.0, b - n * 6.0]), col)

static func _dist_polyline(p: Vector2, pts: PackedVector2Array) -> float:
	var best := INF
	for i in pts.size() - 1:
		best = minf(best, Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1]).distance_to(p))
	return best

static func _area(q: PackedVector2Array) -> float:
	var a := 0.0
	for i in q.size():
		a += q[i].x * q[(i + 1) % q.size()].y - q[(i + 1) % q.size()].x * q[i].y
	return absf(a) * 0.5

static func _perp(v: Vector3) -> Vector3:
	var a := Vector3.UP if absf(v.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return a.cross(v).normalized()
