## PfBuild — turns a PfMesh into a plain Godot ArrayMesh.
##
## - one surface per material slot that has faces,
## - n-gons triangulated (fan for convex, ear clipping for concave),
## - normals: flat faces use the face normal; smooth faces share normals across
##   edges that are not marked sharp (Blender's smooth / sharp-edge model),
## - Polyforge winding (CCW from outside) is flipped to Godot's (CW front faces),
## - the edit data is stored as plain metadata on the mesh (no scripts).
@tool
extends RefCounted

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")


## Rebuilds `target` (or a new ArrayMesh) from `m`. `fast` skips tangents and
## vertex welding (used while dragging). `skip_faces`: face index -> true to
## leave out (hidden faces in the edit display).
static func build(m, target: ArrayMesh = null, fast := false, skip_faces := {}, store_meta := true) -> ArrayMesh:
	var am := target if target != null else ArrayMesh.new()
	# Keep surface materials if the slot list is empty (e.g. first build).
	am.clear_surfaces()
	if m.has_colors:
		m.fill_colors()
	var corner_normals := compute_corner_normals(m)
	var by_mat := {}
	for fi in m.faces.size():
		if skip_faces.has(fi):
			continue
		var slot: int = m.face_mat[fi]
		if not by_mat.has(slot):
			by_mat[slot] = []
		(by_mat[slot] as Array).append(fi)
	var slots := by_mat.keys()
	slots.sort()
	for slot in slots:
		var arrays := _surface_arrays(m, by_mat[slot], corner_normals, fast)
		if arrays.is_empty():
			continue
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var si := am.get_surface_count() - 1
		am.surface_set_name(si, "slot_%d" % slot)
		if slot >= 0 and slot < m.materials.size() and m.materials[slot] is Material:
			am.surface_set_material(si, m.materials[slot])
	if store_meta:
		am.set_meta(PfMesh.META_KEY, m.to_dict())
	return am


static func _surface_arrays(m, face_list: Array, corner_normals: Array, fast: bool) -> Array:
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var col := PackedColorArray()
	for fi in face_list:
		var f: PackedInt32Array = m.faces[fi]
		var tris := triangulate(m, fi)
		var cn: PackedVector3Array = corner_normals[fi]
		var fu: PackedVector2Array = m.uvs[fi]
		var fu2: PackedVector2Array = m.uv2s[fi]
		var fc: PackedColorArray = m.colors[fi] if m.has_colors else PackedColorArray()
		for t in range(0, tris.size(), 3):
			# Flip winding for Godot: (a, c, b).
			for k in [tris[t], tris[t + 2], tris[t + 1]]:
				pos.append(m.verts[f[k]])
				nrm.append(cn[k])
				uv.append(fu[k])
				if m.has_uv2:
					uv2.append(fu2[k])
				if m.has_colors:
					col.append(fc[k] if k < fc.size() else Color.WHITE)
	if pos.is_empty():
		return []
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_TEX_UV] = uv
	if m.has_uv2:
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
	if m.has_colors:
		arrays[Mesh.ARRAY_COLOR] = col
	if fast:
		return arrays
	var st := SurfaceTool.new()
	st.create_from_arrays(arrays)
	st.index()
	st.generate_tangents()
	return st.commit_to_arrays()


# ==============================================================================
# Normals
# ==============================================================================

## Per face, one normal per corner.
static func compute_corner_normals(m) -> Array:
	m.ensure_topology()
	var fn := []
	fn.resize(m.faces.size())
	for fi in m.faces.size():
		fn[fi] = m.face_normal_raw(fi)
	if not m.face_smooth.has(1):
		var flat_out := []
		flat_out.resize(m.faces.size())
		for fi in m.faces.size():
			var arr := PackedVector3Array()
			arr.resize(m.faces[fi].size())
			arr.fill((fn[fi] as Vector3).normalized() if (fn[fi] as Vector3).length_squared() > 1e-24 else Vector3.UP)
			flat_out[fi] = arr
		return flat_out
	# Corner ids for union-find: offset per face.
	var offset := PackedInt32Array()
	offset.resize(m.faces.size())
	var total := 0
	for fi in m.faces.size():
		offset[fi] = total
		total += m.faces[fi].size()
	var parent := PackedInt32Array()
	parent.resize(total)
	for i in total:
		parent[i] = i
	# Join corners of the same vertex across smooth, non-sharp edges.
	for key in m.edges():
		if m.sharp_edges.has(key):
			continue
		var ef: PackedInt32Array = m.edge_faces(key)
		if ef.size() != 2:
			continue
		var f1 := ef[0]
		var f2 := ef[1]
		if m.face_smooth[f1] == 0 or m.face_smooth[f2] == 0:
			continue
		for v in [key.x, key.y]:
			var c1: int = m.corner_of(f1, v)
			var c2: int = m.corner_of(f2, v)
			if c1 >= 0 and c2 >= 0:
				_union(parent, offset[f1] + c1, offset[f2] + c2)
	# Accumulate area-weighted face normals per group.
	var acc := {}
	for fi in m.faces.size():
		if m.face_smooth[fi] == 0:
			continue
		for c in m.faces[fi].size():
			var r := _find(parent, offset[fi] + c)
			acc[r] = acc.get(r, Vector3.ZERO) + fn[fi]
	var out := []
	out.resize(m.faces.size())
	for fi in m.faces.size():
		var f: PackedInt32Array = m.faces[fi]
		var arr := PackedVector3Array()
		arr.resize(f.size())
		var flat: Vector3 = (fn[fi] as Vector3).normalized() if (fn[fi] as Vector3).length_squared() > 1e-24 else Vector3.UP
		for c in f.size():
			if m.face_smooth[fi] == 0:
				arr[c] = flat
			else:
				var s: Vector3 = acc.get(_find(parent, offset[fi] + c), Vector3.ZERO)
				arr[c] = s.normalized() if s.length_squared() > 1e-24 else flat
		out[fi] = arr
	return out

static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i

static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[ra] = rb


# ==============================================================================
# Triangulation
# ==============================================================================

## Corner indices (into the face) of the triangles covering face fi, each
## triangle CCW like the face.
static func triangulate(m, fi: int) -> PackedInt32Array:
	var f: PackedInt32Array = m.faces[fi]
	var n := f.size()
	var out := PackedInt32Array()
	if n == 3:
		out.append_array([0, 1, 2])
		return out
	if n == 4:
		var p: Array = [m.verts[f[0]], m.verts[f[1]], m.verts[f[2]], m.verts[f[3]]]
		var nq: Vector3 = (p[2] - p[0]).cross(p[3] - p[1])
		var convex := true
		for k in 4:
			if (p[(k + 1) % 4] - p[k]).cross(p[(k + 2) % 4] - p[(k + 1) % 4]).dot(nq) < -1e-12:
				convex = false
		if convex:
			out.append_array([0, 1, 2, 0, 2, 3])
			return out
	var pts := _project(m, fi)
	if _is_convex(pts):
		for k in range(1, n - 1):
			out.append_array([0, k, k + 1])
		return out
	return _ear_clip(pts)

## Face corners projected to 2D in the face plane (CCW stays CCW).
static func _project(m, fi: int) -> PackedVector2Array:
	var f: PackedInt32Array = m.faces[fi]
	var nrm: Vector3 = m.face_normal(fi)
	if nrm == Vector3.ZERO:
		nrm = Vector3.UP
	var u := (Vector3.UP if absf(nrm.y) < 0.9 else Vector3.RIGHT).cross(nrm).normalized()
	var v := nrm.cross(u)
	var pts := PackedVector2Array()
	for idx in f:
		var p: Vector3 = m.verts[idx]
		pts.append(Vector2(p.dot(u), p.dot(v)))
	return pts

static func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)

static func _is_convex(pts: PackedVector2Array) -> bool:
	var n := pts.size()
	for k in n:
		if _cross(pts[k], pts[(k + 1) % n], pts[(k + 2) % n]) < -1e-12:
			return false
	return true

## Point inside a CCW triangle, boundary included (a vertex lying on the
## diagonal would otherwise let an invalid ear through).
static func _in_tri_closed(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var eps := -1e-9
	return _cross(a, b, p) >= eps and _cross(b, c, p) >= eps and _cross(c, a, p) >= eps

static func _ear_clip(pts: PackedVector2Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var idx := []
	for k in pts.size():
		idx.append(k)
	var guard := 0
	while idx.size() > 3 and guard < 10000:
		guard += 1
		var found := false
		var n := idx.size()
		for k in n:
			var a: int = idx[(k + n - 1) % n]
			var b: int = idx[k]
			var c: int = idx[(k + 1) % n]
			if _cross(pts[a], pts[b], pts[c]) <= 1e-12:
				continue   # reflex
			var inside := false
			for j in idx:
				if j == a or j == b or j == c:
					continue
				if _in_tri_closed(pts[j], pts[a], pts[b], pts[c]):
					inside = true
					break
			if inside:
				continue
			out.append_array([a, b, c])
			idx.remove_at(k)
			found = true
			break
		if not found:
			break   # degenerate: fall back to a fan for the rest
	if idx.size() >= 3:
		for k in range(1, idx.size() - 1):
			out.append_array([idx[0], idx[k], idx[k + 1]])
	return out
