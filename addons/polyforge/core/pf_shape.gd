## PfShape — ConvexPolygonShape3D / ConcavePolygonShape3D <-> PfMesh.
##
## Concave (trimesh): triangles are welded into a mesh and coplanar triangle
## pairs joined into quads (Blender's Tris to Quads). Convex: the hull of the
## points, coplanar hull triangles joined into n-gons.
## The edit mesh is also stored as metadata on the shape (plain arrays) with a
## hash of the shape data, so quads / n-gons survive as long as nobody else
## changed the shape.
@tool
extends RefCounted

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const PfHull := preload("res://addons/polyforge/core/pf_hull.gd")

const COPLANAR := 0.99999


static func supports(shape: Shape3D) -> bool:
	return shape is ConvexPolygonShape3D or shape is ConcavePolygonShape3D

static func kind_of(shape: Shape3D) -> String:
	if shape is ConvexPolygonShape3D:
		return "convex"
	if shape is ConcavePolygonShape3D:
		return "concave"
	return ""

static func _data_hash(shape: Shape3D) -> int:
	if shape is ConvexPolygonShape3D:
		return hash((shape as ConvexPolygonShape3D).points)
	if shape is ConcavePolygonShape3D:
		return hash((shape as ConcavePolygonShape3D).get_faces())
	return 0

## Edit mesh for a shape (null when unsupported / degenerate).
static func read(shape: Shape3D):
	if shape.has_meta(PfMesh.META_KEY):
		var d: Dictionary = shape.get_meta(PfMesh.META_KEY)
		if int(d.get("shape_hash", 0)) == _data_hash(shape):
			var m = PfMesh.new()
			if m.from_dict(d):
				return m
	if shape is ConcavePolygonShape3D:
		return from_concave_faces((shape as ConcavePolygonShape3D).get_faces())
	if shape is ConvexPolygonShape3D:
		return from_points((shape as ConvexPolygonShape3D).points)
	return null

## Writes the mesh into the shape (+ metadata).
static func write(shape: Shape3D, m) -> void:
	if shape is ConcavePolygonShape3D:
		(shape as ConcavePolygonShape3D).set_faces(to_faces(m))
	elif shape is ConvexPolygonShape3D:
		(shape as ConvexPolygonShape3D).points = used_points(m)
	var d: Dictionary = m.to_dict()
	d["shape_hash"] = _data_hash(shape)
	shape.set_meta(PfMesh.META_KEY, d)


# ==============================================================================
# Concave
# ==============================================================================

## Godot trimesh faces (clockwise front faces) -> welded PfMesh with quads.
static func from_concave_faces(faces: PackedVector3Array):
	var m = PfMesh.new()
	var lookup := {}
	for t in range(0, faces.size() - 2, 3):
		var ids := []
		for k in [0, 2, 1]:   # Godot CW -> Polyforge CCW
			var p: Vector3 = faces[t + k]
			var key := p.snapped(Vector3.ONE * 1e-5)
			if not lookup.has(key):
				lookup[key] = m.add_vertex(p)
			ids.append(lookup[key])
		if ids[0] == ids[1] or ids[1] == ids[2] or ids[0] == ids[2]:
			continue
		m.add_face(PackedInt32Array(ids))
	if m.faces.is_empty():
		return null
	return tris_to_quads(m)

## Blender "Tris to Quads": coplanar triangle pairs whose union is a convex
## quad, joined across their longest shared edge first.
static func tris_to_quads(m):
	m.ensure_topology()
	var matched := {}
	var quads := []
	var order := []
	for fi in m.faces.size():
		if m.faces[fi].size() == 3:
			order.append(fi)
	for fi in order:
		if matched.has(fi):
			continue
		var f: PackedInt32Array = m.faces[fi]
		var n: Vector3 = m.face_normal(fi)
		var best_g := -1
		var best_len := -1.0
		var best_k := -1
		for k in 3:
			var e := PfMesh.ekey(f[k], f[(k + 1) % 3])
			for g in m.edge_faces(e):
				if g == fi or matched.has(g) or m.faces[g].size() != 3:
					continue
				if m.face_normal(g).dot(n) < COPLANAR:
					continue
				var l: float = m.verts[f[k]].distance_to(m.verts[f[(k + 1) % 3]])
				if l > best_len and _quad_ok(m, f, k, m.faces[g]):
					best_len = l
					best_g = g
					best_k = k
		if best_g >= 0:
			matched[fi] = true
			matched[best_g] = true
			quads.append(_quad(f, best_k, m.faces[best_g]))
	var out = PfMesh.new()
	out.verts = m.verts
	for fi in m.faces.size():
		if not matched.has(fi):
			out.add_face(m.faces[fi])
	for q in quads:
		out.add_face(q)
	return out

## Quad from triangle f (shared edge f[k] -> f[k+1]) and its neighbour g.
static func _quad(f: PackedInt32Array, k: int, g: PackedInt32Array) -> PackedInt32Array:
	var a := f[k]
	var b := f[(k + 1) % 3]
	var c := f[(k + 2) % 3]
	var opp := -1
	for v in g:
		if v != a and v != b:
			opp = v
	return PackedInt32Array([a, opp, b, c])

static func _quad_ok(m, f: PackedInt32Array, k: int, g: PackedInt32Array) -> bool:
	var q := _quad(f, k, g)
	var n: Vector3 = (m.verts[f[1]] - m.verts[f[0]]).cross(m.verts[f[2]] - m.verts[f[0]])
	for i in 4:
		var a: Vector3 = m.verts[q[i]]
		var b: Vector3 = m.verts[q[(i + 1) % 4]]
		var c: Vector3 = m.verts[q[(i + 2) % 4]]
		if (b - a).cross(c - b).dot(n) <= 1e-12:
			return false
	return true

## PfMesh -> Godot trimesh faces (clockwise front faces).
static func to_faces(m) -> PackedVector3Array:
	var out := PackedVector3Array()
	for fi in m.faces.size():
		var f: PackedInt32Array = m.faces[fi]
		var tris := PfBuild.triangulate(m, fi)
		for t in range(0, tris.size(), 3):
			out.append(m.verts[f[tris[t]]])
			out.append(m.verts[f[tris[t + 2]]])
			out.append(m.verts[f[tris[t + 1]]])
	return out


# ==============================================================================
# Convex
# ==============================================================================

## Hull of the points as a PfMesh with n-gon faces (null if degenerate).
static func from_points(points: PackedVector3Array):
	var tris := PfHull.hull(points)
	if tris.is_empty():
		return null
	var m = PfMesh.new()
	m.verts = points
	for t in tris:
		m.add_face(PackedInt32Array(t))
	return compact(merge_coplanar(m))["mesh"]

## Re-hull an edited convex mesh keeping vertex order where possible.
## Returns {"mesh": PfMesh, "remap": {old -> new}} (dropped vertices missing):
## points inside the hull or inside a flat hull face are dropped.
static func rehull(m) -> Dictionary:
	var tris := PfHull.hull(m.verts)
	if tris.is_empty():
		return {}
	var out = PfMesh.new()
	out.verts = m.verts.duplicate()
	for t in tris:
		out.add_face(PackedInt32Array(t))
	var r := compact(merge_coplanar(out))
	r["mesh"].materials = m.materials
	return r

## Removes vertices no face uses. {"mesh", "remap": old -> new}.
static func compact(m) -> Dictionary:
	var used := {}
	for f in m.faces:
		for v in f:
			used[v] = true
	var out = PfMesh.new()
	var remap := {}
	for i in m.verts.size():
		if used.has(i):
			remap[i] = out.add_vertex(m.verts[i])
	for fi in m.faces.size():
		var f := PackedInt32Array()
		for v in m.faces[fi]:
			f.append(remap[v])
		out.add_face(f)
	return {"mesh": out, "remap": remap}

## Joins connected coplanar faces into one n-gon each (convex hulls only:
## every coplanar region of a hull is a convex polygon).
static func merge_coplanar(m):
	m.ensure_topology()
	var region := PackedInt32Array()
	region.resize(m.faces.size())
	region.fill(-1)
	var regions := []
	for fi in m.faces.size():
		if region[fi] >= 0:
			continue
		var n: Vector3 = m.face_normal(fi)
		var rid := regions.size()
		var members := []
		var stack := [fi]
		while not stack.is_empty():
			var f: int = stack.pop_back()
			if region[f] >= 0:
				continue
			region[f] = rid
			members.append(f)
			for e in m.face_edges(f):
				for g in m.edge_faces(e):
					if region[g] < 0 and m.face_normal(g).dot(n) >= COPLANAR:
						stack.append(g)
		regions.append(members)
	var out = PfMesh.new()
	out.verts = m.verts
	for members in regions:
		if members.size() == 1:
			out.add_face(m.faces[members[0]])
			continue
		var loop := _boundary_loop(m, members)
		if loop.size() >= 3:
			out.add_face(loop)
		else:
			for f in members:
				out.add_face(m.faces[f])
	return out

## Outer boundary of a set of faces as one ordered vertex loop (CCW).
static func _boundary_loop(m, members: Array) -> PackedInt32Array:
	var directed := {}
	for f in members:
		var fv: PackedInt32Array = m.faces[f]
		for k in fv.size():
			directed[Vector2i(fv[k], fv[(k + 1) % fv.size()])] = true
	var next := {}
	for e in directed:
		if not directed.has(Vector2i(e.y, e.x)):
			next[e.x] = e.y
	if next.is_empty():
		return PackedInt32Array()
	var start: int = next.keys()[0]
	var loop := PackedInt32Array([start])
	var cur: int = next[start]
	var guard := 0
	while cur != start and guard < 100000:
		loop.append(cur)
		if not next.has(cur):
			return PackedInt32Array()
		cur = next[cur]
		guard += 1
	# Collinear corners are kept: they are real shape points (dropping them
	# would leave loose vertices).
	return loop

static func used_points(m) -> PackedVector3Array:
	var used := {}
	for f in m.faces:
		for v in f:
			used[v] = true
	var out := PackedVector3Array()
	for v in m.verts.size():
		if used.has(v):
			out.append(m.verts[v])
	return out
