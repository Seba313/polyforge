## PfHull — 3D convex hull (incremental), used for ConvexPolygonShape3D.
## Returns triangles as index triples into the input points, counter-clockwise
## seen from outside (Polyforge winding). Interior points are left out.
@tool
extends RefCounted


## Triangles [[a, b, c], ...] of the hull of `pts`, or [] when the points are
## degenerate (fewer than 4 non-coplanar points).
static func hull(pts: PackedVector3Array) -> Array:
	var n := pts.size()
	if n < 4:
		return []
	var bb := AABB(pts[0], Vector3.ZERO)
	for p in pts:
		bb = bb.expand(p)
	var eps := maxf(bb.size.length(), 1e-6) * 1e-7
	# Initial tetrahedron: two far points, farthest from their line, farthest
	# from their plane.
	# Start from an extreme point (min x): every point of the initial
	# tetrahedron must be a hull vertex, or an interior point would stay.
	var i0 := 0
	for i in n:
		if pts[i].x < pts[i0].x:
			i0 = i
	var i1 := -1
	var best := -1.0
	for i in n:
		var d := pts[i].distance_squared_to(pts[i0])
		if d > best:
			best = d
			i1 = i
	if best <= eps * eps:
		return []
	var i2 := -1
	best = -1.0
	var dir := (pts[i1] - pts[i0]).normalized()
	for i in n:
		var v := pts[i] - pts[i0]
		var d := (v - dir * v.dot(dir)).length_squared()
		if d > best:
			best = d
			i2 = i
	if best <= eps * eps:
		return []
	var nrm := (pts[i1] - pts[i0]).cross(pts[i2] - pts[i0]).normalized()
	var i3 := -1
	best = -1.0
	for i in n:
		var d := absf((pts[i] - pts[i0]).dot(nrm))
		if d > best:
			best = d
			i3 = i
	if best <= eps:
		return []
	var faces: Array = []   # [a, b, c] CCW outward
	var centroid := (pts[i0] + pts[i1] + pts[i2] + pts[i3]) * 0.25
	for t in [[i0, i1, i2], [i0, i1, i3], [i0, i2, i3], [i1, i2, i3]]:
		faces.append(_oriented(pts, t, centroid))
	var used := {i0: true, i1: true, i2: true, i3: true}
	for p in n:
		if used.has(p):
			continue
		var visible := []
		for fi in faces.size():
			var f: Array = faces[fi]
			var fn := (pts[f[1]] - pts[f[0]]).cross(pts[f[2]] - pts[f[0]])
			var l := fn.length()
			if l <= 1e-30:
				continue
			if (pts[p] - pts[f[0]]).dot(fn / l) > eps:
				visible.append(fi)
		if visible.is_empty():
			continue   # inside (or on) the hull
		# Horizon: directed edges of visible faces whose twin is not visible.
		var vis_edges := {}
		for fi in visible:
			var f: Array = faces[fi]
			for k in 3:
				vis_edges[Vector2i(f[k], f[(k + 1) % 3])] = true
		var horizon := []
		for e in vis_edges:
			if not vis_edges.has(Vector2i(e.y, e.x)):
				horizon.append(e)
		visible.sort()
		for k in range(visible.size() - 1, -1, -1):
			faces.remove_at(visible[k])
		for e in horizon:
			faces.append([e.x, e.y, p])
		used[p] = true
	return faces

static func _oriented(pts: PackedVector3Array, t: Array, inside: Vector3) -> Array:
	var a: Vector3 = pts[t[0]]
	var nrm := (pts[t[1]] - a).cross(pts[t[2]] - a)
	if nrm.dot(a - inside) < 0.0:
		return [t[0], t[2], t[1]]
	return t
