## PfOps — mesh operations (Blender semantics) on a PfMesh. Pure data, no
## editor: delete / dissolve, merge, extrude, inset, duplicate, make
## edge/face, normals, triangulate, tris to quads, smooth.
## Operations return a Dictionary with the new selection
## ({"verts": {}, "edges": {}, "faces": {}}) and extras, or {"error": "..."}.
@tool
extends RefCounted

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const PfUv := preload("res://addons/polyforge/core/pf_uv.gd")

static func ekey(a: int, b: int) -> Vector2i:
	return PfMesh.ekey(a, b)

static func _sel(verts := {}, edges := {}, faces := {}) -> Dictionary:
	return {"verts": verts, "edges": edges, "faces": faces}


# ==============================================================================
# Low-level editing
# ==============================================================================

## Appends a face with corner UVs; returns its index.
static func add_face(m, f: PackedInt32Array, uv := PackedVector2Array(), mat := 0, smooth := false, uv2 := PackedVector2Array()) -> int:
	var fi: int = m.add_face(f, uv, mat, smooth)
	if uv2.size() == f.size():
		m.uv2s[fi] = uv2
	return fi

## Removes faces (set of indices). Face indices after the call are compacted.
static func remove_faces(m, del: Dictionary) -> void:
	if del.is_empty():
		return
	var nf: Array[PackedInt32Array] = []
	var nu: Array[PackedVector2Array] = []
	var nu2: Array[PackedVector2Array] = []
	var nm := PackedInt32Array()
	var ns := PackedByteArray()
	var nt := PackedInt32Array()
	for fi in m.faces.size():
		if del.has(fi):
			continue
		nf.append(m.faces[fi])
		nu.append(m.uvs[fi])
		nu2.append(m.uv2s[fi])
		nm.append(m.face_mat[fi])
		ns.append(m.face_smooth[fi])
		nt.append(m.face_tag[fi] if fi < m.face_tag.size() else -1)
	m.faces = nf
	m.uvs = nu
	m.uv2s = nu2
	m.face_mat = nm
	m.face_smooth = ns
	m.face_tag = nt
	m.invalidate()

## Removes vertices together with the faces and edges using them.
## Returns remap old -> new for the kept vertices.
static func remove_verts(m, del: Dictionary) -> Dictionary:
	var kill := {}
	for fi in m.faces.size():
		for v in m.faces[fi]:
			if del.has(v):
				kill[fi] = true
				break
	remove_faces(m, kill)
	var remap := {}
	var nv := PackedVector3Array()
	for v in m.verts.size():
		if not del.has(v):
			remap[v] = nv.size()
			nv.append(m.verts[v])
	m.verts = nv
	for fi in m.faces.size():
		var f: PackedInt32Array = m.faces[fi]
		for k in f.size():
			f[k] = remap[f[k]]
		m.faces[fi] = f
	for dname in ["sharp_edges", "seam_edges", "wire_edges"]:
		var d: Dictionary = m.get(dname)
		var nd := {}
		for e in d:
			if remap.has(e.x) and remap.has(e.y):
				nd[ekey(remap[e.x], remap[e.y])] = true
		m.set(dname, nd)
	var np := {}
	for v in m.uv_pins:
		if remap.has(v):
			np[remap[v]] = true
	m.uv_pins = np
	m.invalidate()
	return remap

## Vertices used by no face and no wire edge, among `candidates`.
static func _orphans(m, candidates: Dictionary) -> Dictionary:
	m.ensure_topology()
	var out := {}
	for v in candidates:
		if v < m.verts.size() and m.vert_edges(v).is_empty():
			out[v] = true
	return out


# ==============================================================================
# Delete / dissolve (X, Ctrl+X)
# ==============================================================================

## kind: "verts", "edges", "faces", "only_faces", "edges_faces".
static func delete(m, kind: String, sv: Dictionary, se: Dictionary, sf: Dictionary) -> Dictionary:
	m.ensure_topology()
	match kind:
		"verts":
			if sv.is_empty():
				return {"error": "No vertices selected"}
			remove_verts(m, sv)
		"edges", "edges_faces":
			if se.is_empty():
				return {"error": "No edges selected"}
			var kill := {}
			var ends := {}
			for e in se:
				for fi in m.edge_faces(e):
					kill[fi] = true
				m.wire_edges.erase(e)
				ends[e.x] = true
				ends[e.y] = true
			# Edges of the removed faces that are not selected stay as wire edges.
			for fi in kill:
				for e in m.face_edges(fi):
					if se.has(e):
						continue
					var keep := false
					for g in m.edge_faces(e):
						if not kill.has(g):
							keep = true
					if not keep:
						m.wire_edges[e] = true
			remove_faces(m, kill)
			if kind == "edges":
				remove_verts(m, _orphans(m, ends))
		"faces", "only_faces":
			if sf.is_empty():
				return {"error": "No faces selected"}
			var corner_verts := {}
			var loose_edges := {}
			for fi in sf:
				for v in m.faces[fi]:
					corner_verts[v] = true
				for e in m.face_edges(fi):
					var keep := false
					for g in m.edge_faces(e):
						if not sf.has(g):
							keep = true
					if not keep:
						loose_edges[e] = true
			remove_faces(m, sf)
			if kind == "only_faces":
				m.wire_edges.merge(loose_edges)
			else:
				remove_verts(m, _orphans(m, corner_verts))
	m.invalidate()
	return _sel()

## Outer boundary of a set of faces as one new face description
## {"f", "uv", "uv2", "mat", "smooth"}, or {} when the region has holes or
## its boundary is pinched. `drop_verts` are left out of the loop.
static func region_face(m, region: Dictionary, drop_verts := {}) -> Dictionary:
	var nxt := {}
	var uv_at := {}
	var uv2_at := {}
	var directed := {}
	for fi in region:
		var f: PackedInt32Array = m.faces[fi]
		for k in f.size():
			directed[Vector2i(f[k], f[(k + 1) % f.size()])] = true
	for fi in region:
		var f: PackedInt32Array = m.faces[fi]
		for k in f.size():
			var a := f[k]
			var b := f[(k + 1) % f.size()]
			if directed.has(Vector2i(b, a)):
				continue
			if nxt.has(a):
				return {}
			nxt[a] = b
			uv_at[a] = m.uvs[fi][k]
			uv2_at[a] = m.uv2s[fi][k]
	if nxt.is_empty():
		return {}
	var start: int = nxt.keys()[0]
	var loop := PackedInt32Array([start])
	var cur: int = nxt[start]
	var guard := 0
	while cur != start:
		if not nxt.has(cur) or guard > 100000:
			return {}
		loop.append(cur)
		cur = nxt[cur]
		guard += 1
	if loop.size() != nxt.size():
		return {}
	var f := PackedInt32Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	for v in loop:
		if drop_verts.has(v):
			continue
		f.append(v)
		uv.append(uv_at[v])
		uv2.append(uv2_at[v])
	if f.size() < 3:
		return {}
	var first: int = region.keys()[0]
	return {"f": f, "uv": uv, "uv2": uv2, "mat": m.face_mat[first], "smooth": m.face_smooth[first] != 0}

## Joins a set of faces into one face. Returns the new face index or -1.
static func merge_region(m, region: Dictionary, drop_verts := {}) -> int:
	var d := region_face(m, region, drop_verts)
	if d.is_empty():
		return -1
	remove_faces(m, region)
	return add_face(m, d["f"], d["uv"], d["mat"], d["smooth"], d["uv2"])

static func _face_regions(m, faces: Dictionary) -> Array:
	var seen := {}
	var out := []
	for f0 in faces:
		if seen.has(f0):
			continue
		var comp := {}
		var stack := [f0]
		while not stack.is_empty():
			var f: int = stack.pop_back()
			if seen.has(f):
				continue
			seen[f] = true
			comp[f] = true
			for e in m.face_edges(f):
				for g in m.edge_faces(e):
					if faces.has(g) and not seen.has(g):
						stack.append(g)
		out.append(comp)
	return out

## Dissolve Faces: each connected group of selected faces becomes one face
## (vertices left inside the new face are removed).
static func dissolve_faces(m, sf: Dictionary) -> Dictionary:
	m.ensure_topology()
	var kill := {}
	var adds := []
	var region_verts := {}
	for r in _face_regions(m, sf):
		if r.size() < 2:
			continue
		var d := region_face(m, r)
		if d.is_empty():
			continue
		kill.merge(r)
		adds.append(d)
		for fi in r:
			for v in m.faces[fi]:
				region_verts[v] = true
	if adds.is_empty():
		return {"error": "Nothing to dissolve (select at least two connected faces without holes)"}
	remove_faces(m, kill)
	var new_f := []
	for d in adds:
		new_f.append(add_face(m, d["f"], d["uv"], d["mat"], d["smooth"], d["uv2"]))
	var inner := _orphans(m, region_verts)
	var remap := remove_verts(m, inner) if not inner.is_empty() else {}
	var faces := {}
	var base: int = m.faces.size() - new_f.size()
	for i in new_f.size():
		faces[base + i] = true
	return _sel({}, {}, faces)

## Dissolve Edges: the two faces of each selected edge become one face; then
## vertices left in the middle of a straight chain are dissolved (Blender).
static func dissolve_edges(m, se: Dictionary) -> Dictionary:
	var made := 0
	var ends := {}
	for e in se:
		m.ensure_topology()
		if m.edge_id(e) < 0:
			continue
		var ef: PackedInt32Array = m.edge_faces(e)
		if ef.size() == 0:
			m.wire_edges.erase(e)
			made += 1
			continue
		if ef.size() != 2 or ef[0] == ef[1]:
			continue
		if merge_region(m, {ef[0]: true, ef[1]: true}) >= 0:
			made += 1
			ends[e.x] = true
			ends[e.y] = true
	m.ensure_topology()
	var chain := {}
	for v in ends:
		if v < m.verts.size() and m.vert_edges(v).size() == 2 and m.vert_faces(v).size() >= 1:
			chain[v] = true
	if not chain.is_empty():
		dissolve_verts(m, chain)
	m.ensure_topology()
	var lone := _orphans(m, ends)
	if not lone.is_empty():
		remove_verts(m, lone)
	if made == 0:
		return {"error": "Nothing to dissolve (edges must lie between two faces)"}
	return _sel()

## Dissolve Vertices: faces around each vertex become one face without it; a
## vertex in the middle of a chain is simply dropped from its faces.
static func dissolve_verts(m, sv: Dictionary) -> Dictionary:
	var made := 0
	for v in sv:
		m.ensure_topology()
		if v >= m.verts.size():
			continue
		var vf: PackedInt32Array = m.vert_faces(v)
		var ve: Array[Vector2i] = m.vert_edges(v)
		if vf.is_empty():
			var nb := []
			for e in ve:
				nb.append(e.y if e.x == v else e.x)
				m.wire_edges.erase(e)
			if nb.size() == 2:
				m.wire_edges[ekey(nb[0], nb[1])] = true
			made += 1
			continue
		if ve.size() == 2:
			for fi in vf:
				if m.faces[fi].size() <= 3:
					continue
				var k: int = m.corner_of(fi, v)
				var f: PackedInt32Array = m.faces[fi]
				f.remove_at(k)
				m.faces[fi] = f
				var u: PackedVector2Array = m.uvs[fi]
				u.remove_at(k)
				m.uvs[fi] = u
				var u2: PackedVector2Array = m.uv2s[fi]
				u2.remove_at(k)
				m.uv2s[fi] = u2
			m.invalidate()
			made += 1
			continue
		var region := {}
		for fi in vf:
			region[fi] = true
		if merge_region(m, region, {v: true}) >= 0:
			made += 1
	var lone := _orphans(m, sv)
	if not lone.is_empty():
		remove_verts(m, lone)
	if made == 0:
		return {"error": "Nothing to dissolve"}
	return _sel()


# ==============================================================================
# Merge (M)
# ==============================================================================

## Welds vertices: `target_of` maps a vertex to the vertex it merges into.
## Collapsed corners, degenerate faces and duplicate faces are removed.
## Returns remap old -> new (merged vertices map to their target's new index).
static func weld(m, target_of: Dictionary) -> Dictionary:
	var t := func(v: int) -> int: return target_of.get(v, v)
	var kill := {}
	var seen_sets := {}
	for fi in m.faces.size():
		var f: PackedInt32Array = m.faces[fi]
		var nf := PackedInt32Array()
		var nu := PackedVector2Array()
		var nu2 := PackedVector2Array()
		for k in f.size():
			var v: int = t.call(f[k])
			if nf.size() > 0 and nf[nf.size() - 1] == v:
				continue
			nf.append(v)
			nu.append(m.uvs[fi][k])
			nu2.append(m.uv2s[fi][k])
		while nf.size() > 1 and nf[0] == nf[nf.size() - 1]:
			nf.remove_at(nf.size() - 1)
			nu.remove_at(nu.size() - 1)
			nu2.remove_at(nu2.size() - 1)
		var uniq := {}
		for v in nf:
			uniq[v] = true
		if nf.size() < 3 or uniq.size() != nf.size():
			kill[fi] = true
			continue
		var key := Array(nf)
		key.sort()
		if seen_sets.has(key):
			kill[fi] = true
			continue
		seen_sets[key] = true
		m.faces[fi] = nf
		m.uvs[fi] = nu
		m.uv2s[fi] = nu2
	for dname in ["sharp_edges", "seam_edges", "wire_edges"]:
		var d: Dictionary = m.get(dname)
		var nd := {}
		for e in d:
			var a: int = t.call(e.x)
			var b: int = t.call(e.y)
			if a != b:
				nd[ekey(a, b)] = true
		m.set(dname, nd)
	remove_faces(m, kill)
	var dead := {}
	for v in target_of:
		if target_of[v] != v:
			dead[v] = true
	var remap := remove_verts(m, dead)
	for v in target_of:
		remap[v] = remap.get(target_of[v], -1)
	return remap

## Merge At Center / First / Last / a given position: all into one vertex.
static func merge_at(m, sv: Dictionary, pos: Vector3, into := -1) -> Dictionary:
	if sv.size() < 2:
		return {"error": "Select at least two vertices"}
	var target: int = into if into >= 0 else sv.keys()[0]
	m.verts[target] = pos
	var map := {}
	for v in sv:
		map[v] = target
	var remap := weld(m, map)
	return _sel({remap[target]: true})

## Collapse: every connected part of the selection merges at its centre.
static func merge_collapse(m, sv: Dictionary) -> Dictionary:
	m.ensure_topology()
	var map := {}
	var seen := {}
	var targets := []
	for v0 in sv:
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
				if sv.has(w) and not seen.has(w):
					stack.append(w)
		var c := Vector3.ZERO
		for v in comp:
			c += m.verts[v]
		m.verts[comp[0]] = c / float(comp.size())
		for v in comp:
			map[v] = comp[0]
		targets.append(comp[0])
	var remap := weld(m, map)
	var out := {}
	for tv in targets:
		out[remap[tv]] = true
	return _sel(out)

## Merge By Distance among `sv` (all vertices when empty). Returns
## {"removed": n, ...selection}.
static func merge_by_distance(m, sv: Dictionary, dist: float) -> Dictionary:
	var cand: Array = sv.keys() if not sv.is_empty() else range(m.verts.size())
	var cell := maxf(dist, 1e-6)
	var grid := {}
	for v in cand:
		var k := Vector3i((m.verts[v] / cell).floor())
		if not grid.has(k):
			grid[k] = []
		grid[k].append(v)
	var map := {}
	for v in cand:
		if map.has(v):
			continue
		map[v] = v
		var k := Vector3i((m.verts[v] / cell).floor())
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					for w in grid.get(k + Vector3i(dx, dy, dz), []):
						if not map.has(w) and m.verts[w].distance_to(m.verts[v]) <= dist:
							map[w] = v
	var removed := 0
	for v in map:
		if map[v] != v:
			removed += 1
	var remap := weld(m, map)
	var out := {}
	for v in cand:
		if remap.has(v) and remap[v] >= 0:
			out[remap[v]] = true
	var r := _sel(out)
	r["removed"] = removed
	return r


# ==============================================================================
# Extrude (E, Alt+E)
# ==============================================================================

## Extrude Region: selected faces move off as one region (side faces along
## its boundary); selected edges outside the faces become new faces; loose
## selected vertices get a new vertex + edge. New geometry starts in place.
static func extrude_region(m, sv: Dictionary, se: Dictionary, sf: Dictionary) -> Dictionary:
	m.ensure_topology()
	var dup := {}
	var new_v := func(v: int) -> int:
		if not dup.has(v):
			dup[v] = m.add_vertex(m.verts[v])
		return dup[v]
	var side := {}
	var region_edges := {}
	var normal := Vector3.ZERO
	# --- faces ---
	var directed := {}
	for fi in sf:
		var f: PackedInt32Array = m.faces[fi]
		normal += m.face_normal_raw(fi)
		for k in f.size():
			directed[Vector2i(f[k], f[(k + 1) % f.size()])] = true
			region_edges[ekey(f[k], f[(k + 1) % f.size()])] = true
	var boundary := []
	for fi in sf:
		var f: PackedInt32Array = m.faces[fi]
		for k in f.size():
			var a := f[k]
			var b := f[(k + 1) % f.size()]
			if not directed.has(Vector2i(b, a)):
				boundary.append([fi, k, a, b])
	if not sf.is_empty() and boundary.is_empty():
		return {"error": "Cannot extrude a closed region (it has no boundary)"}
	var bverts := {}
	for bd in boundary:
		bverts[bd[2]] = true
		bverts[bd[3]] = true
	for v in bverts:
		new_v.call(v)
	var side_uv := []
	for bd in boundary:
		var fi: int = bd[0]
		var k: int = bd[1]
		var f: PackedInt32Array = m.faces[fi]
		var ua: Vector2 = m.uvs[fi][k]
		var ub: Vector2 = m.uvs[fi][(k + 1) % f.size()]
		side_uv.append([bd[2], bd[3], ua, ub, m.face_mat[fi], m.face_smooth[fi] != 0])
	for fi in sf:
		var f: PackedInt32Array = m.faces[fi]
		for k in f.size():
			if dup.has(f[k]):
				f[k] = dup[f[k]]
		m.faces[fi] = f
	for s in side_uv:
		var a: int = s[0]
		var b: int = s[1]
		var nf := add_face(m, PackedInt32Array([a, b, dup[b], dup[a]]),
			PackedVector2Array([s[2], s[3], s[3], s[2]]), s[4], s[5])
		side[nf] = true
	# --- edges not part of the extruded faces ---
	var out_edges := {}
	for e in se:
		if region_edges.has(e):
			continue
		var a: int = e.x
		var b: int = e.y
		var ef: PackedInt32Array = m.edge_faces(e)
		if ef.size() >= 1:
			# Wind the new face against the existing neighbour.
			var g: int = ef[0]
			var k: int = m.corner_of(g, a)
			if m.faces[g][(k + 1) % m.faces[g].size()] == b:
				var tmp := a
				a = b
				b = tmp
		var na: int = new_v.call(a)
		var nb: int = new_v.call(b)
		var nf := add_face(m, PackedInt32Array([a, b, nb, na]))
		side[nf] = true
		out_edges[ekey(na, nb)] = true
	# --- loose vertices ---
	var used_v := {}
	for e in se:
		used_v[e.x] = true
		used_v[e.y] = true
	for fi in sf:
		for v in m.faces[fi]:
			used_v[v] = true
	for v in sv:
		if used_v.has(v) or dup.has(v):
			continue
		var nv: int = new_v.call(v)
		m.wire_edges[ekey(v, nv)] = true
	m.invalidate()
	var sel_v := {}
	for fi in sf:
		for v in m.faces[fi]:
			sel_v[v] = true
	for v in dup:
		sel_v[dup[v]] = true
	for e in out_edges:
		sel_v[e.x] = true
		sel_v[e.y] = true
	var edges := out_edges.duplicate()
	for fi in sf:
		for e in m.face_edges(fi):
			edges[e] = true
	var r := _sel(sel_v, edges, sf.duplicate())
	r["side_faces"] = side
	r["normal"] = normal.normalized() if normal.length_squared() > 1e-20 else Vector3.ZERO
	r["faces_only"] = se.size() == region_edges.size() or sf.size() > 0
	return r

## Extrude Individual Faces: each face extrudes on its own.
static func extrude_individual(m, sf: Dictionary) -> Dictionary:
	if sf.is_empty():
		return {"error": "No faces selected"}
	var side := {}
	var sel_v := {}
	var dirs := {}
	for fi in sf:
		var f: PackedInt32Array = m.faces[fi]
		var n: Vector3 = m.face_normal(fi)
		var nf := PackedInt32Array()
		for v in f:
			var nv: int = m.add_vertex(m.verts[v])
			nf.append(nv)
			sel_v[nv] = true
			dirs[nv] = n
		var uv: PackedVector2Array = m.uvs[fi]
		var mat: int = m.face_mat[fi]
		var smooth: bool = m.face_smooth[fi] != 0
		for k in f.size():
			var k2 := (k + 1) % f.size()
			side[add_face(m, PackedInt32Array([f[k], f[k2], nf[k2], nf[k]]),
				PackedVector2Array([uv[k], uv[k2], uv[k2], uv[k]]), mat, smooth)] = true
		m.faces[fi] = nf
	m.invalidate()
	var r := _sel(sel_v, {}, sf.duplicate())
	r["side_faces"] = side
	r["dirs"] = dirs
	return r

## Per-vertex directions for Shrink/Fatten (Alt+S): average normal of the
## selected faces around each vertex (all faces when none is selected).
static func vertex_normals(m, verts: Dictionary, sf: Dictionary) -> Dictionary:
	m.ensure_topology()
	var out := {}
	for v in verts:
		var n := Vector3.ZERO
		for fi in m.vert_faces(v):
			if sf.is_empty() or sf.has(fi):
				n += m.face_normal(fi)
		if n.length_squared() < 1e-12:
			for fi in m.vert_faces(v):
				n += m.face_normal(fi)
		out[v] = n.normalized() if n.length_squared() > 1e-12 else Vector3.ZERO
	return out


# ==============================================================================
# Inset (I)
# ==============================================================================

## Builds the inset topology (inner vertices start on the outer ones) and
## returns the data inset_update() needs. individual: each face on its own.
static func inset(m, sf: Dictionary, individual := false) -> Dictionary:
	if sf.is_empty():
		return {"error": "No faces selected"}
	m.ensure_topology()
	var groups := []
	if individual:
		for fi in sf:
			groups.append({fi: true})
	else:
		groups = _face_regions(m, sf)
	# UV maps of the faces before the change (corner UVs follow positions).
	var maps := {}
	for fi in sf:
		maps[fi] = _uv_map(m, fi)
	var inner := []     # {"v": new vertex, "o": origin, "d": direction * miter}
	var side := {}
	var side_corners := []   # [face, corner, region face, vertex] for inner UVs
	for g in groups:
		var directed := {}
		for fi in g:
			var f: PackedInt32Array = m.faces[fi]
			for k in f.size():
				directed[Vector2i(f[k], f[(k + 1) % f.size()])] = true
		var out_e := {}   # vertex -> [next vertex, face]
		var in_e := {}    # vertex -> [prev vertex, face]
		var bnd := []
		for fi in g:
			var f: PackedInt32Array = m.faces[fi]
			for k in f.size():
				var a := f[k]
				var b := f[(k + 1) % f.size()]
				if not directed.has(Vector2i(b, a)):
					out_e[a] = [b, fi]
					in_e[b] = [a, fi]
					bnd.append([fi, k, a, b])
		if bnd.is_empty():
			continue
		var dup := {}
		for v in out_e:
			var nb: Array = out_e[v]
			var pv: Array = in_e.get(v, nb)
			var n1: Vector3 = m.face_normal(nb[1])
			var n2: Vector3 = m.face_normal(pv[1])
			var in1 := n1.cross(m.verts[nb[0]] - m.verts[v]).normalized()
			var in2 := n2.cross(m.verts[v] - m.verts[pv[0]]).normalized()
			var d := (in1 + in2).normalized()
			if d.length_squared() < 1e-12:
				d = in1
			var miter := 1.0 / maxf(d.dot(in1), 0.25)
			var nv: int = m.add_vertex(m.verts[v])
			dup[v] = nv
			inner.append({"v": nv, "o": m.verts[v], "d": d * miter})
		for fi in g:
			var f: PackedInt32Array = m.faces[fi]
			for k in f.size():
				if dup.has(f[k]):
					f[k] = dup[f[k]]
			m.faces[fi] = f
		for bd in bnd:
			var fi: int = bd[0]
			var k: int = bd[1]
			var a: int = bd[2]
			var b: int = bd[3]
			var uv: PackedVector2Array = m.uvs[fi]
			var k2 := (k + 1) % uv.size()
			var nf := add_face(m, PackedInt32Array([a, b, dup[b], dup[a]]),
				PackedVector2Array([uv[k], uv[k2], uv[k2], uv[k]]), m.face_mat[fi], m.face_smooth[fi] != 0)
			side[nf] = true
			side_corners.append([nf, 2, fi, dup[b]])
			side_corners.append([nf, 3, fi, dup[a]])
	m.invalidate()
	var sel_v := {}
	for fi in sf:
		for v in m.faces[fi]:
			sel_v[v] = true
	var r := _sel(sel_v, {}, sf.duplicate())
	r["inner"] = inner
	r["side_faces"] = side
	r["maps"] = maps
	r["side_corners"] = side_corners
	return r

## Places the inner vertices at thickness t and updates the UVs.
static func inset_update(m, data: Dictionary, t: float) -> void:
	for it in data["inner"]:
		m.verts[it["v"]] = (it["o"] as Vector3) + (it["d"] as Vector3) * t
	var maps: Dictionary = data["maps"]
	for fi in maps:
		var f: PackedInt32Array = m.faces[fi]
		var uv: PackedVector2Array = m.uvs[fi]
		for k in f.size():
			uv[k] = _uv_eval(maps[fi], m.verts[f[k]], uv[k])
		m.uvs[fi] = uv
	for sc in data["side_corners"]:
		var uv: PackedVector2Array = m.uvs[sc[0]]
		uv[sc[1]] = _uv_eval(maps[sc[2]], m.verts[sc[3]], uv[sc[1]])
		m.uvs[sc[0]] = uv
	m.invalidate()

## Affine UV map of a face in its plane: {"u", "v", "m": Transform2D} or {}.
static func _uv_map(m, fi: int) -> Dictionary:
	var n: Vector3 = m.face_normal(fi)
	if n == Vector3.ZERO:
		return {}
	var u := (Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).cross(n).normalized()
	var v := n.cross(u)
	var P := PackedVector2Array()
	for vi in m.faces[fi]:
		P.append(Vector2(m.verts[vi].dot(u), m.verts[vi].dot(v)))
	var fit := PfUv._fit_affine(P, m.uvs[fi])
	if fit.is_empty():
		return {}
	return {"u": u, "v": v, "m": fit["m"]}

static func _uv_eval(mp: Dictionary, p: Vector3, fallback: Vector2) -> Vector2:
	if mp.is_empty():
		return fallback
	return (mp["m"] as Transform2D) * Vector2(p.dot(mp["u"]), p.dot(mp["v"]))


# ==============================================================================
# Duplicate (Shift+D)
# ==============================================================================

static func duplicate_geometry(m, sv: Dictionary, se: Dictionary, sf: Dictionary) -> Dictionary:
	if sv.is_empty():
		return {"error": "Nothing selected"}
	var map := {}
	for v in sv:
		map[v] = m.add_vertex(m.verts[v])
	var new_f := {}
	var face_edges := {}
	for fi in sf:
		var f := PackedInt32Array()
		for v in m.faces[fi]:
			f.append(map[v])
		new_f[add_face(m, f, m.uvs[fi].duplicate(), m.face_mat[fi], m.face_smooth[fi] != 0, m.uv2s[fi].duplicate())] = true
		for e in m.face_edges(fi):
			face_edges[e] = true
	var new_e := {}
	for e in se:
		var k := ekey(map[e.x], map[e.y])
		new_e[k] = true
		if not face_edges.has(e):
			m.wire_edges[k] = true
		if m.sharp_edges.has(e):
			m.sharp_edges[k] = true
		if m.seam_edges.has(e):
			m.seam_edges[k] = true
	m.invalidate()
	var nv := {}
	for v in map:
		nv[map[v]] = true
	return _sel(nv, new_e, new_f)


# ==============================================================================
# Make Edge/Face (F)
# ==============================================================================

## Two vertices -> edge; a closed loop of selected edges -> face filling it;
## otherwise 3+ vertices -> face around their centre. `view_back` (mesh-local,
## toward the viewer) orients faces that have no neighbours.
static func make_edge_face(m, sv: Dictionary, se: Dictionary, view_back := Vector3.BACK, sf := {}) -> Dictionary:
	m.ensure_topology()
	# Blender: with only whole faces selected, F joins them into one face.
	if sf.size() >= 2:
		var covered := {}
		for fi in sf:
			for v in m.faces[fi]:
				covered[v] = true
		if sv.keys().all(func(v): return covered.has(v)):
			return dissolve_faces(m, sf)
	if sv.size() < 2:
		return {"error": "Select at least two vertices"}
	if sv.size() == 2:
		var k: Array = sv.keys()
		var e := ekey(k[0], k[1])
		if m.edge_id(e) >= 0:
			return {"error": "Edge already exists"}
		m.wire_edges[e] = true
		m.invalidate()
		return _sel(sv.duplicate(), {e: true})
	for fi in m.vert_faces(sv.keys()[0]):
		if m.faces[fi].size() == sv.size() and Array(m.faces[fi]).all(func(v): return sv.has(v)):
			return {"error": "Face already exists"}
	var loop := _edge_loop_order(se, sv)
	var order := PackedInt32Array()
	if not loop.is_empty():
		order = loop
	else:
		order = _sort_around(m, sv, view_back)
	# Orientation: against existing neighbour faces, else toward the viewer.
	var votes := 0
	for i in order.size():
		var a := order[i]
		var b := order[(i + 1) % order.size()]
		for fi in m.edge_faces(ekey(a, b)):
			var k: int = m.corner_of(fi, a)
			if m.faces[fi][(k + 1) % m.faces[fi].size()] == b:
				votes -= 1
			else:
				votes += 1
	if votes < 0:
		order.reverse()
	elif votes == 0:
		var n := Vector3.ZERO
		for i in order.size():
			n += m.verts[order[i]].cross(m.verts[order[(i + 1) % order.size()]])
		if n.dot(view_back) < 0.0:
			order.reverse()
	for e in m.wire_edges.keys():
		if sv.has(e.x) and sv.has(e.y):
			m.wire_edges.erase(e)
	var fi := add_face(m, order, _planar_uv(m, order))
	m.invalidate()
	return _sel(sv.duplicate(), {}, {fi: true})

static func _edge_loop_order(se: Dictionary, sv: Dictionary) -> PackedInt32Array:
	if se.size() != sv.size():
		return PackedInt32Array()
	var adj := {}
	for e in se:
		adj[e.x] = adj.get(e.x, []) + [e.y]
		adj[e.y] = adj.get(e.y, []) + [e.x]
	for v in adj:
		if adj[v].size() != 2:
			return PackedInt32Array()
	var start: int = adj.keys()[0]
	var out := PackedInt32Array([start])
	var prev := start
	var cur: int = adj[start][0]
	while cur != start:
		out.append(cur)
		var nx: int = adj[cur][0] if adj[cur][0] != prev else adj[cur][1]
		prev = cur
		cur = nx
		if out.size() > sv.size():
			return PackedInt32Array()
	return out if out.size() == sv.size() else PackedInt32Array()

static func _sort_around(m, sv: Dictionary, view_back: Vector3) -> PackedInt32Array:
	var c := Vector3.ZERO
	for v in sv:
		c += m.verts[v]
	c /= float(sv.size())
	var n := view_back.normalized()
	var u := (Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).cross(n).normalized()
	var w := n.cross(u)
	var items := []
	for v in sv:
		var d: Vector3 = m.verts[v] - c
		items.append([atan2(d.dot(w), d.dot(u)), v])
	items.sort_custom(func(a, b): return a[0] < b[0])
	var out := PackedInt32Array()
	for it in items:
		out.append(it[1])
	return out

static func _planar_uv(m, f: PackedInt32Array) -> PackedVector2Array:
	var tmp = PfMesh.new()
	for v in f:
		tmp.add_vertex(m.verts[v])
	tmp.add_face(PackedInt32Array(range(f.size())))
	var n: Vector3 = tmp.face_normal(0)
	var u := (Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).cross(n).normalized()
	var w := n.cross(u)
	var pts := PackedVector2Array()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for v in f:
		var p := Vector2(m.verts[v].dot(u), -m.verts[v].dot(w))
		pts.append(p)
		lo = lo.min(p)
		hi = hi.max(p)
	var size := maxf(hi.x - lo.x, hi.y - lo.y)
	for i in pts.size():
		pts[i] = (pts[i] - lo) / maxf(size, 1e-9)
	return pts


# ==============================================================================
# Normals, triangulate, tris to quads, smooth
# ==============================================================================

static func flip(m, sf: Dictionary) -> void:
	for fi in sf:
		var f: PackedInt32Array = m.faces[fi]
		f.reverse()
		m.faces[fi] = f
		var u: PackedVector2Array = m.uvs[fi]
		u.reverse()
		m.uvs[fi] = u
		var u2: PackedVector2Array = m.uv2s[fi]
		u2.reverse()
		m.uv2s[fi] = u2
	m.invalidate()

## Recalculate Outside (inside = false) / Inside: consistent winding inside
## each connected part of the selection, then outward by signed volume.
static func recalc_normals(m, sf: Dictionary, inside := false) -> void:
	m.ensure_topology()
	for comp in _face_regions(m, sf):
		var keys: Array = comp.keys()
		var flipped := {}
		var seen := {keys[0]: true}
		var stack := [keys[0]]
		while not stack.is_empty():
			var f: int = stack.pop_back()
			var fv: PackedInt32Array = m.faces[f]
			for k in fv.size():
				var a := fv[k]
				var b := fv[(k + 1) % fv.size()]
				if flipped.has(f):
					var t := a
					a = b
					b = t
				for g in m.edge_faces(ekey(a, b)):
					if g == f or not comp.has(g) or seen.has(g):
						continue
					seen[g] = true
					var kg: int = m.corner_of(g, a)
					var same: bool = m.faces[g][(kg + 1) % m.faces[g].size()] == b
					if same:
						flipped[g] = true
					stack.append(g)
		flip(m, flipped)
		m.ensure_topology()
		var c := Vector3.ZERO
		var cnt := 0
		for f in comp:
			c += m.face_center(f)
			cnt += 1
		c /= float(cnt)
		var vol := 0.0
		for f in comp:
			vol += m.face_normal_raw(f).dot(m.face_center(f) - c)
		if (vol < 0.0) != inside:
			flip(m, comp)

## Ctrl+T: selected faces -> triangles (UVs kept).
static func triangulate(m, sf: Dictionary) -> Dictionary:
	var new_f := {}
	var kill := {}
	var adds := []
	for fi in sf:
		var f: PackedInt32Array = m.faces[fi]
		if f.size() <= 3:
			continue
		var tris := PfBuild.triangulate(m, fi)
		for t in range(0, tris.size(), 3):
			var idx := [tris[t], tris[t + 1], tris[t + 2]]
			adds.append([PackedInt32Array([f[idx[0]], f[idx[1]], f[idx[2]]]),
				PackedVector2Array([m.uvs[fi][idx[0]], m.uvs[fi][idx[1]], m.uvs[fi][idx[2]]]),
				m.face_mat[fi], m.face_smooth[fi] != 0,
				PackedVector2Array([m.uv2s[fi][idx[0]], m.uv2s[fi][idx[1]], m.uv2s[fi][idx[2]]])])
		kill[fi] = true
	if kill.is_empty():
		return {"error": "No faces with more than 3 corners selected"}
	remove_faces(m, kill)
	for a in adds:
		new_f[add_face(m, a[0], a[1], a[2], a[3], a[4])] = true
	return _sel({}, {}, new_f)

## Alt+J: coplanar triangle pairs with continuous UVs -> convex quads.
static func tris_to_quads(m, sf: Dictionary) -> Dictionary:
	m.ensure_topology()
	var matched := {}
	var pairs := []
	for fi in sf:
		if matched.has(fi) or m.faces[fi].size() != 3:
			continue
		var f: PackedInt32Array = m.faces[fi]
		var n: Vector3 = m.face_normal(fi)
		var best := []
		var best_len := -1.0
		for k in 3:
			var e := ekey(f[k], f[(k + 1) % 3])
			for g in m.edge_faces(e):
				if g == fi or matched.has(g) or not sf.has(g) or m.faces[g].size() != 3:
					continue
				if m.face_normal(g).dot(n) < 0.9999:
					continue
				var q := _quad(m, fi, k, g)
				if q.is_empty() or not _convex(m, q[0]):
					continue
				var l: float = m.verts[f[k]].distance_to(m.verts[f[(k + 1) % 3]])
				if l > best_len:
					best_len = l
					best = [g, q]
		if not best.is_empty():
			matched[fi] = true
			matched[best[0]] = true
			pairs.append([fi, best[0], best[1]])
	if pairs.is_empty():
		return {"error": "No coplanar triangle pairs to join"}
	var adds := []
	var kill := {}
	for p in pairs:
		kill[p[0]] = true
		kill[p[1]] = true
		adds.append([p[2][0], p[2][1], m.face_mat[p[0]], m.face_smooth[p[0]] != 0])
	remove_faces(m, kill)
	var new_f := {}
	for a in adds:
		new_f[add_face(m, a[0], a[1], a[2], a[3])] = true
	return _sel({}, {}, new_f)

static func _quad(m, fi: int, k: int, g: int) -> Array:
	var f: PackedInt32Array = m.faces[fi]
	var a := f[k]
	var b := f[(k + 1) % 3]
	var c := f[(k + 2) % 3]
	var gf: PackedInt32Array = m.faces[g]
	var opp := -1
	var opp_k := -1
	for i in 3:
		if gf[i] != a and gf[i] != b:
			opp = gf[i]
			opp_k = i
	# UVs must match across the shared edge (no seam).
	var ka: int = m.corner_of(g, a)
	var kb: int = m.corner_of(g, b)
	if not (m.uvs[g][ka] as Vector2).is_equal_approx(m.uvs[fi][k]) or not (m.uvs[g][kb] as Vector2).is_equal_approx(m.uvs[fi][(k + 1) % 3]):
		return []
	return [PackedInt32Array([a, opp, b, c]),
		PackedVector2Array([m.uvs[fi][k], m.uvs[g][opp_k], m.uvs[fi][(k + 1) % 3], m.uvs[fi][(k + 2) % 3]])]

static func _convex(m, q: PackedInt32Array) -> bool:
	var n: Vector3 = (m.verts[q[1]] - m.verts[q[0]]).cross(m.verts[q[2]] - m.verts[q[0]]) + (m.verts[q[2]] - m.verts[q[0]]).cross(m.verts[q[3]] - m.verts[q[0]])
	for i in 4:
		var a: Vector3 = m.verts[q[i]]
		var b: Vector3 = m.verts[q[(i + 1) % 4]]
		var c: Vector3 = m.verts[q[(i + 2) % 4]]
		if (b - a).cross(c - b).dot(n) <= 1e-12:
			return false
	return true

## Smooth Vertices (Laplacian, Blender's default factor 0.5).
static func smooth_verts(m, sv: Dictionary, factor := 0.5, repeat := 1) -> void:
	m.ensure_topology()
	for r in repeat:
		var nv: PackedVector3Array = m.verts.duplicate()
		for v in sv:
			var es: Array[Vector2i] = m.vert_edges(v)
			if es.is_empty():
				continue
			var avg := Vector3.ZERO
			for e in es:
				avg += m.verts[e.y if e.x == v else e.x]
			avg /= float(es.size())
			nv[v] = m.verts[v].lerp(avg, factor)
		m.verts = nv
	m.invalidate()
