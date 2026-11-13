## PfSelect — topology-based selection helpers (Blender semantics):
## edge loops / rings, face loops, linked, grow / shrink, mode conversion.
## Selections are Dictionaries used as sets: vertex int / edge Vector2i / face int.
@tool
extends RefCounted

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")

enum Mode { VERTEX = 1, EDGE = 2, FACE = 3 }


# ==============================================================================
# Mode conversion
# ==============================================================================

static func verts_to_edges(m, verts: Dictionary) -> Dictionary:
	var out := {}
	for e in m.edges():
		if verts.has(e.x) and verts.has(e.y):
			out[e] = true
	return out

static func verts_to_faces(m, verts: Dictionary) -> Dictionary:
	var out := {}
	for fi in m.faces.size():
		var all := true
		for v in m.faces[fi]:
			if not verts.has(v):
				all = false
				break
		if all:
			out[fi] = true
	return out

static func edges_to_verts(edges: Dictionary) -> Dictionary:
	var out := {}
	for e in edges:
		out[e.x] = true
		out[e.y] = true
	return out

static func edges_to_faces(m, edges: Dictionary) -> Dictionary:
	var out := {}
	for fi in m.faces.size():
		var all := true
		for e in m.face_edges(fi):
			if not edges.has(e):
				all = false
				break
		if all:
			out[fi] = true
	return out

static func faces_to_verts(m, faces: Dictionary) -> Dictionary:
	var out := {}
	for fi in faces:
		if fi < m.faces.size():
			for v in m.faces[fi]:
				out[v] = true
	return out

static func faces_to_edges(m, faces: Dictionary) -> Dictionary:
	var out := {}
	for fi in faces:
		if fi < m.faces.size():
			for e in m.face_edges(fi):
				out[e] = true
	return out


# ==============================================================================
# Loops and rings
# ==============================================================================

## Next edge of an edge loop when walking from edge `e` through vertex `v`.
static func _next_loop_edge(m, e: Vector2i, v: int) -> Vector2i:
	var at_v: Array[Vector2i] = m.vert_edges(v)
	if m.is_boundary_edge(e):
		var cand: Array[Vector2i] = []
		for o in at_v:
			if o != e and m.is_boundary_edge(o):
				cand.append(o)
		return cand[0] if cand.size() == 1 else Vector2i(-1, -1)
	var fe: PackedInt32Array = m.edge_faces(e)
	# Blender: an edge on an n-gon (> 4 corners) loops along that n-gon's
	# border (e.g. the rim of a cylinder cap).
	for fi in fe:
		var f: PackedInt32Array = m.faces[fi]
		if f.size() > 4:
			var k: int = m.corner_of(fi, v)
			var prev := PfMesh.ekey(f[(k + f.size() - 1) % f.size()], v)
			var nxt := PfMesh.ekey(v, f[(k + 1) % f.size()])
			return nxt if prev == e else prev
	if at_v.size() != 4:
		return Vector2i(-1, -1)
	for o in at_v:
		if o == e:
			continue
		var shares := false
		for f in m.edge_faces(o):
			if fe.has(f):
				shares = true
				break
		if not shares:
			return o
	return Vector2i(-1, -1)

## Edge loop through `start` (Blender Alt+click).
static func edge_loop(m, start: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = [start]
	var seen := {start: true}
	for dir in 2:
		var e := start
		var v := start.y if dir == 0 else start.x
		while true:
			var nx := _next_loop_edge(m, e, v)
			if nx.x < 0 or seen.has(nx):
				break
			seen[nx] = true
			out.append(nx)
			v = nx.x if nx.y == v else nx.y
			e = nx
	return out

## Opposite edge of a quad face.
static func _opposite_in_quad(m, fi: int, e: Vector2i) -> Vector2i:
	var f: PackedInt32Array = m.faces[fi]
	if f.size() != 4:
		return Vector2i(-1, -1)
	for k in 4:
		if PfMesh.ekey(f[k], f[(k + 1) % 4]) == e:
			return PfMesh.ekey(f[(k + 2) % 4], f[(k + 3) % 4])
	return Vector2i(-1, -1)

## Edge ring through `start` (Ctrl+Alt+click). Returns {"edges": [...], "faces": {...}}.
static func edge_ring(m, start: Vector2i) -> Dictionary:
	var edges: Array[Vector2i] = [start]
	var faces := {}
	var seen := {start: true}
	var start_faces: PackedInt32Array = m.edge_faces(start)
	for sf in start_faces:
		var e := start
		var f := sf
		while true:
			var opp := _opposite_in_quad(m, f, e)
			if opp.x < 0:
				break
			faces[f] = true
			if seen.has(opp):
				break
			seen[opp] = true
			edges.append(opp)
			var nf := -1
			for g in m.edge_faces(opp):
				if g != f:
					nf = g
			if nf < 0 or faces.has(nf):
				break
			e = opp
			f = nf
	return {"edges": edges, "faces": faces}

## Face loop (face-mode Alt+click): faces crossed by the ring of edge `e`.
static func face_loop(m, e: Vector2i) -> Dictionary:
	return edge_ring(m, e)["faces"]


# ==============================================================================
# Linked / grow / shrink
# ==============================================================================

## Faces connected to `seed_faces` through shared edges (optionally not
## crossing seams). Hidden faces (`hidden`) are skipped.
static func linked_faces(m, seed_faces: Dictionary, delimit_seams := false, hidden := {}) -> Dictionary:
	var out := {}
	var stack: Array = seed_faces.keys()
	while not stack.is_empty():
		var fi: int = stack.pop_back()
		if out.has(fi) or hidden.has(fi):
			continue
		out[fi] = true
		for e in m.face_edges(fi):
			if delimit_seams and m.seam_edges.has(e):
				continue
			for g in m.edge_faces(e):
				if not out.has(g):
					stack.append(g)
	return out

static func faces_with_any_vert(m, verts: Dictionary) -> Dictionary:
	var out := {}
	for v in verts:
		for fi in m.vert_faces(v):
			out[fi] = true
	return out

## Blender "Select More" in vertex terms.
static func grow_verts(m, verts: Dictionary) -> Dictionary:
	var out := verts.duplicate()
	for fi in faces_with_any_vert(m, verts):
		for v in m.faces[fi]:
			out[v] = true
	return out

## Blender "Select Less" in vertex terms: drop vertices on the selection border.
static func shrink_verts(m, verts: Dictionary) -> Dictionary:
	var out := {}
	for v in verts:
		var inner := true
		for fi in m.vert_faces(v):
			for w in m.faces[fi]:
				if not verts.has(w):
					inner = false
					break
			if not inner:
				break
		if inner:
			out[v] = true
	return out

static func grow_faces(m, faces: Dictionary) -> Dictionary:
	var out := faces.duplicate()
	for fi in faces_with_any_vert(m, faces_to_verts(m, faces)):
		out[fi] = true
	return out

static func shrink_faces(m, faces: Dictionary) -> Dictionary:
	var out := {}
	for fi in faces:
		var inner := true
		for v in m.faces[fi]:
			for g in m.vert_faces(v):
				if not faces.has(g):
					inner = false
					break
			if not inner:
				break
		if inner:
			out[fi] = true
	return out


# ==============================================================================
# Select Similar (Shift+G)
# ==============================================================================

const SIMILAR := {
	Mode.VERTEX: [["Normal", "normal"], ["Amount of Connecting Edges", "edges"], ["Amount of Adjacent Faces", "faces"]],
	Mode.EDGE: [["Length", "length"], ["Direction", "direction"], ["Amount of Faces Around an Edge", "faces"], ["Face Angles", "angle"], ["Seam", "seam"], ["Sharpness", "sharp"]],
	Mode.FACE: [["Material", "material"], ["Area", "area"], ["Polygon Sides", "sides"], ["Perimeter", "perimeter"], ["Normal", "normal"], ["Co-planar", "coplanar"], ["Flat/Smooth", "smooth"]],
}

## Elements (of `mode`) similar to any selected one. Vectors compare by angle
## (threshold in radians), numbers by relative difference.
static func similar(m, mode: int, sel: Dictionary, kind: String, threshold := 0.0) -> Dictionary:
	var pool: Array = []
	match mode:
		Mode.VERTEX: pool = range(m.verts.size())
		Mode.EDGE: pool = m.edges()
		_: pool = range(m.faces.size())
	var keys := {}
	for x in pool:
		keys[x] = _similar_key(m, mode, x, kind)
	var refs: Array = sel.keys().map(func(x): return keys.get(x))
	var out := sel.duplicate()
	for x in pool:
		for r in refs:
			if r != null and _similar_match(keys[x], r, kind, threshold):
				out[x] = true
				break
	return out

static func _similar_key(m, mode: int, x, kind: String):
	match [mode, kind]:
		[Mode.VERTEX, "normal"]:
			var n := Vector3.ZERO
			for f in m.vert_faces(x):
				n += m.face_normal(f)
			return n.normalized()
		[Mode.VERTEX, "edges"]: return m.vert_edges(x).size()
		[Mode.VERTEX, "faces"]: return m.vert_faces(x).size()
		[Mode.EDGE, "length"]: return m.verts[x.x].distance_to(m.verts[x.y])
		[Mode.EDGE, "direction"]: return (m.verts[x.y] - m.verts[x.x]).normalized()
		[Mode.EDGE, "faces"]: return m.edge_faces(x).size()
		[Mode.EDGE, "angle"]:
			var ef: PackedInt32Array = m.edge_faces(x)
			return m.face_normal(ef[0]).angle_to(m.face_normal(ef[1])) if ef.size() == 2 else -1.0
		[Mode.EDGE, "seam"]: return m.seam_edges.has(x)
		[Mode.EDGE, "sharp"]: return m.sharp_edges.has(x)
		[Mode.FACE, "material"]: return m.face_mat[x]
		[Mode.FACE, "area"]: return m.face_area(x)
		[Mode.FACE, "sides"]: return m.faces[x].size()
		[Mode.FACE, "perimeter"]:
			var f: PackedInt32Array = m.faces[x]
			var p := 0.0
			for i in f.size():
				p += m.verts[f[i]].distance_to(m.verts[f[(i + 1) % f.size()]])
			return p
		[Mode.FACE, "normal"]: return m.face_normal(x)
		[Mode.FACE, "coplanar"]:
			var n: Vector3 = m.face_normal(x)
			return Plane(n, m.face_center(x).dot(n))
		[Mode.FACE, "smooth"]: return m.face_smooth[x] != 0
	return null

static func _similar_match(a, b, kind: String, t: float) -> bool:
	if a is Vector3:
		var ang := (a as Vector3).angle_to(b)
		return minf(ang, PI - ang) <= t + 1e-4 if kind == "direction" else ang <= t + 1e-4
	if a is Plane:
		return (a as Plane).normal.angle_to(b.normal) <= t + 1e-4 and absf(a.d - b.d) <= t + 1e-4
	if a is float:
		return absf(a - b) <= maxf(absf(b) * t, 1e-5)
	return a == b
