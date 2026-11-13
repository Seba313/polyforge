## PfPicking — screen-space picking of vertices / edges / faces for a
## session: click, box and circle select. Without X-Ray only elements not
## hidden behind the mesh itself are pickable (BVH occlusion test).
@tool
extends RefCounted

const VERT_RADIUS := 14.0
const EDGE_RADIUS := 10.0

enum { VERTEX = 1, EDGE = 2, FACE = 3 }


static func _to_local(s, camera: Camera3D, screen: Vector2) -> Array:
	var inv: Transform3D = s.node.global_transform.affine_inverse()
	var o := inv * camera.project_ray_origin(screen)
	var d := (inv.basis * camera.project_ray_normal(screen)).normalized()
	return [o, d]

## Screen position of a mesh-local point (null when behind the camera).
static func project(s, camera: Camera3D, p: Vector3) -> Variant:
	var w: Vector3 = s.node.global_transform * p
	if camera.is_position_behind(w):
		return null
	return camera.unproject_position(w)

static func _visible(s, camera: Camera3D, p: Vector3, screen: Vector2) -> bool:
	if s.xray:
		return true
	var r := _to_local(s, camera, screen)
	return not s.bvh().occluded(r[0], p)

## Element under the mouse for the current mode (vertex int / edge Vector2i /
## face int) or null.
static func pick(s, camera: Camera3D, mouse: Vector2, for_mode := 0) -> Variant:
	var m: int = for_mode if for_mode != 0 else s.mode
	match m:
		VERTEX: return pick_vertex(s, camera, mouse)
		EDGE: return pick_edge(s, camera, mouse)
		FACE: return pick_face(s, camera, mouse)
	return null

static func pick_vertex(s, camera: Camera3D, mouse: Vector2) -> Variant:
	var best = null
	var best_d := VERT_RADIUS
	for v in s.mesh.verts.size():
		if s.is_vert_hidden(v):
			continue
		var sp = project(s, camera, s.mesh.verts[v])
		if sp == null:
			continue
		var d: float = (sp as Vector2).distance_to(mouse)
		if d < best_d and _visible(s, camera, s.mesh.verts[v], sp):
			best_d = d
			best = v
	return best

static func pick_edge(s, camera: Camera3D, mouse: Vector2) -> Variant:
	var best = null
	var best_d := EDGE_RADIUS
	for e in s.mesh.edges():
		if s.is_edge_hidden(e):
			continue
		var a = project(s, camera, s.mesh.verts[e.x])
		var b = project(s, camera, s.mesh.verts[e.y])
		if a == null or b == null:
			continue
		var q := Geometry2D.get_closest_point_to_segment(mouse, a, b)
		var d := q.distance_to(mouse)
		if d >= best_d:
			continue
		var seg: Vector2 = b - a
		var t := 0.5 if seg.length_squared() < 1e-6 else clampf((q - a).dot(seg) / seg.length_squared(), 0.0, 1.0)
		var p3: Vector3 = s.mesh.verts[e.x].lerp(s.mesh.verts[e.y], t)
		if _visible(s, camera, p3, q):
			best_d = d
			best = e
	return best

static func pick_face(s, camera: Camera3D, mouse: Vector2) -> Variant:
	var r := _to_local(s, camera, mouse)
	var hit: Dictionary = s.bvh().raycast(r[0], r[1])
	if hit.is_empty():
		return null
	return int(hit["face"])

## Edge of face `fi` closest to the mouse (for face loops).
static func nearest_edge_of_face(s, camera: Camera3D, mouse: Vector2, fi: int) -> Variant:
	var best = null
	var best_d := INF
	for e in s.mesh.face_edges(fi):
		var a = project(s, camera, s.mesh.verts[e.x])
		var b = project(s, camera, s.mesh.verts[e.y])
		if a == null or b == null:
			continue
		var d := Geometry2D.get_closest_point_to_segment(mouse, a, b).distance_to(mouse)
		if d < best_d:
			best_d = d
			best = e
	return best


# ==============================================================================
# Region select
# ==============================================================================

## Elements of the current mode inside `rect` (screen).
static func in_rect(s, camera: Camera3D, rect: Rect2) -> Array:
	return _region(s, camera, func(p: Vector2) -> bool: return rect.has_point(p),
		func(a: Vector2, b: Vector2) -> bool: return _segment_hits_rect(a, b, rect))

static func in_circle(s, camera: Camera3D, center: Vector2, radius: float) -> Array:
	return _region(s, camera, func(p: Vector2) -> bool: return p.distance_to(center) <= radius,
		func(a: Vector2, b: Vector2) -> bool: return Geometry2D.get_closest_point_to_segment(center, a, b).distance_to(center) <= radius)

static func _region(s, camera: Camera3D, inside: Callable, seg_hits: Callable) -> Array:
	var out := []
	var m = s.mesh
	match s.mode:
		VERTEX:
			for v in m.verts.size():
				if s.is_vert_hidden(v):
					continue
				var sp = project(s, camera, m.verts[v])
				if sp != null and inside.call(sp) and _visible(s, camera, m.verts[v], sp):
					out.append(v)
		EDGE:
			# Blender: edges fully inside; if none, edges crossing the region.
			var crossing := []
			for e in m.edges():
				if s.is_edge_hidden(e):
					continue
				var a = project(s, camera, m.verts[e.x])
				var b = project(s, camera, m.verts[e.y])
				if a == null or b == null:
					continue
				var ia: bool = inside.call(a)
				var ib: bool = inside.call(b)
				if ia and ib:
					if _visible(s, camera, m.verts[e.x], a) or _visible(s, camera, m.verts[e.y], b):
						out.append(e)
				elif seg_hits.call(a, b):
					var mid: Vector3 = (m.verts[e.x] + m.verts[e.y]) * 0.5
					var ms = project(s, camera, mid)
					if ms != null and _visible(s, camera, mid, ms):
						crossing.append(e)
			if out.is_empty():
				out = crossing
		FACE:
			# Face centres (Blender's face dots).
			for fi in m.faces.size():
				if s.is_face_hidden(fi):
					continue
				var c: Vector3 = m.face_center(fi)
				var sp = project(s, camera, c)
				if sp == null or not inside.call(sp):
					continue
				# Test visibility slightly in front of the face.
				if _visible(s, camera, c + m.face_normal(fi) * 1e-4, sp):
					out.append(fi)
	return out

static func _segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	if r.has_point(a) or r.has_point(b):
		return true
	var c := [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]
	for i in 4:
		if Geometry2D.segment_intersects_segment(a, b, c[i], c[(i + 1) % 4]) != null:
			return true
	return false
