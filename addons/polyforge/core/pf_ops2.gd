## PfOps2 — modelling operators of stage 2B (Blender semantics):
## connect vertex path (J), loop cut + edge slide (Ctrl+R), edge bevel
## (Ctrl+B) and vertex bevel (Ctrl+Shift+B), separate (P) and join (Ctrl+J).
## Operators that are driven by a value (slide factor, bevel width) build the
## topology once and return data for an `*_update(m, data, value)` call.
@tool
extends RefCounted

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfOps := preload("res://addons/polyforge/core/pf_ops.gd")
const PfSelect := preload("res://addons/polyforge/core/pf_select.gd")

static func ekey(a: int, b: int) -> Vector2i:
	return PfMesh.ekey(a, b)


# ==============================================================================
# J — Connect Vertex Path
# ==============================================================================

## Splits face fi between corners a and b (not adjacent). Returns true.
static func split_face(m, fi: int, a: int, b: int) -> bool:
	var f: PackedInt32Array = m.faces[fi]
	var ia := -1
	var ib := -1
	for k in f.size():
		if f[k] == a:
			ia = k
		if f[k] == b:
			ib = k
	if ia < 0 or ib < 0 or absi(ia - ib) == 1 or absi(ia - ib) == f.size() - 1:
		return false
	var n := f.size()
	var f1 := PackedInt32Array()
	var u1 := PackedVector2Array()
	var u21 := PackedVector2Array()
	var k := ia
	while true:
		f1.append(f[k])
		u1.append(m.uvs[fi][k])
		u21.append(m.uv2s[fi][k])
		if k == ib:
			break
		k = (k + 1) % n
	var f2 := PackedInt32Array()
	var u2 := PackedVector2Array()
	var u22 := PackedVector2Array()
	k = ib
	while true:
		f2.append(f[k])
		u2.append(m.uvs[fi][k])
		u22.append(m.uv2s[fi][k])
		if k == ia:
			break
		k = (k + 1) % n
	var mat: int = m.face_mat[fi]
	var smooth: bool = m.face_smooth[fi] != 0
	m.faces[fi] = f1
	m.uvs[fi] = u1
	m.uv2s[fi] = u21
	PfOps.add_face(m, f2, u2, mat, smooth, u22)
	m.invalidate()
	return true

## Connects consecutive vertices of `order` that share a face.
static func connect_path(m, order: Array) -> Dictionary:
	if order.size() < 2:
		return {"error": "Select two or more vertices (one by one)"}
	var edges := {}
	for i in order.size() - 1:
		var a: int = order[i]
		var b: int = order[i + 1]
		m.ensure_topology()
		if m.edge_id(ekey(a, b)) >= 0:
			continue
		var done := false
		for fi in m.vert_faces(a):
			if m.corner_of(fi, b) >= 0 and split_face(m, fi, a, b):
				edges[ekey(a, b)] = true
				done = true
				break
		if not done:
			return {"error": "Vertices %d and %d do not share a face" % [a, b]}
	if edges.is_empty():
		return {"error": "Nothing to connect"}
	var vs := {}
	for v in order:
		vs[v] = true
	return {"verts": vs, "edges": edges, "faces": {}}


# ==============================================================================
# Ctrl+R — Loop Cut and Slide
# ==============================================================================

## Positions of the preview lines for a loop cut through `edge` (for drawing).
## Returns Array of [Vector3, Vector3] (mesh-local) per ring face and cut.
static func loop_preview(m, edge: Vector2i, cuts: int) -> Array:
	var ring: Dictionary = PfSelect.edge_ring(m, edge)
	var out := []
	for fi in ring["faces"]:
		var sides := _ring_sides(m, fi, ring["edges"])
		if sides.is_empty():
			continue
		for i in range(1, cuts + 1):
			var t := float(i) / (cuts + 1)
			out.append([m.verts[sides[0]].lerp(m.verts[sides[1]], t), m.verts[sides[3]].lerp(m.verts[sides[2]], t)])
	return out

## For a ring quad: [c0, c1, c2, c3] with (c0,c1) and (c3,c2) on the ring.
static func _ring_sides(m, fi: int, ring_edges: Array) -> PackedInt32Array:
	var f: PackedInt32Array = m.faces[fi]
	if f.size() != 4:
		return PackedInt32Array()
	var rs := {}
	for e in ring_edges:
		rs[e] = true
	for k in 2:
		if rs.has(ekey(f[k], f[k + 1])) and rs.has(ekey(f[(k + 2) % 4], f[(k + 3) % 4])):
			return PackedInt32Array([f[k], f[k + 1], f[(k + 2) % 4], f[(k + 3) % 4]])
	return PackedInt32Array()

## Cuts `cuts` loops through the ring of `edge`. Returns the new loop as the
## selection plus slide data for loop_slide().
static func loop_cut(m, edge: Vector2i, cuts := 1) -> Dictionary:
	m.ensure_topology()
	var ring: Dictionary = PfSelect.edge_ring(m, edge)
	var ring_edges: Array = ring["edges"]
	var ring_faces: Dictionary = ring["faces"]
	if ring_faces.is_empty():
		return {"error": "No quad ring through this edge"}
	cuts = maxi(cuts, 1)
	# New vertices on every ring edge, ordered from e.x to e.y.
	var on_edge := {}
	var slide := []
	for e in ring_edges:
		var ids := []
		for i in range(1, cuts + 1):
			var t := float(i) / (cuts + 1)
			var v: int = m.add_vertex(m.verts[e.x].lerp(m.verts[e.y], t))
			ids.append(v)
			slide.append({"v": v, "a": e.x, "b": e.y, "t": t})
		on_edge[e] = ids
	var pts := func(a: int, b: int) -> Array:
		var ids: Array = on_edge[ekey(a, b)]
		return ids if a < b else ids.duplicate()
	var new_edges := {}
	var uv_slots := []   # [face, corner, uv_a, uv_b, vertex] for sliding
	var adds := []
	var kill := {}
	var side_of := {}
	for fi in ring_faces:
		var sd := _ring_sides(m, fi, ring_edges)
		if sd.is_empty():
			continue
		side_of[fi] = sd
		var f: PackedInt32Array = m.faces[fi]
		var kk: int = m.corner_of(fi, sd[0])
		var uv: PackedVector2Array = m.uvs[fi]
		var uv0: Vector2 = uv[kk]
		var uv1: Vector2 = uv[(kk + 1) % 4]
		var uv2: Vector2 = uv[(kk + 2) % 4]
		var uv3: Vector2 = uv[(kk + 3) % 4]
		var A: Array = [sd[0]]
		var ua: Array = [sd[0], sd[1]]
		var ida: Array = pts.call(sd[0], sd[1])
		if sd[0] > sd[1]:
			ida.reverse()
		A.append_array(ida)
		A.append(sd[1])
		var B: Array = [sd[3]]
		var idb: Array = pts.call(sd[3], sd[2])
		if sd[3] > sd[2]:
			idb.reverse()
		B.append_array(idb)
		B.append(sd[2])
		for i in cuts + 1:
			var t0 := float(i) / (cuts + 1)
			var t1 := float(i + 1) / (cuts + 1)
			adds.append([PackedInt32Array([A[i], A[i + 1], B[i + 1], B[i]]),
				PackedVector2Array([uv0.lerp(uv1, t0), uv0.lerp(uv1, t1), uv3.lerp(uv2, t1), uv3.lerp(uv2, t0)]),
				m.face_mat[fi], m.face_smooth[fi] != 0,
				[[0, uv0, uv1, A[i], sd[0]], [1, uv0, uv1, A[i + 1], sd[0]], [2, uv3, uv2, B[i + 1], sd[3]], [3, uv3, uv2, B[i], sd[3]]]])
		for i in range(1, cuts + 1):
			new_edges[ekey(A[i], B[i])] = true
		kill[fi] = true
	# Faces at the ends of an open ring (n-gons, triangles) get the new
	# vertices inserted into their edges.
	for e in ring_edges:
		for fi in m.edge_faces(e):
			if ring_faces.has(fi):
				continue
			var f: PackedInt32Array = m.faces[fi]
			var n := f.size()
			for k in n:
				var a := f[k]
				var b := f[(k + 1) % n]
				if ekey(a, b) != e:
					continue
				var ids: Array = on_edge[e].duplicate()
				if a > b:
					ids.reverse()
				var uv: PackedVector2Array = m.uvs[fi]
				var u2: PackedVector2Array = m.uv2s[fi]
				var ua: Vector2 = uv[k]
				var ub: Vector2 = uv[(k + 1) % n]
				for j in range(ids.size() - 1, -1, -1):
					var t := float(j + 1) / (cuts + 1)
					f.insert(k + 1, ids[j])
					uv.insert(k + 1, ua.lerp(ub, t))
					u2.insert(k + 1, u2[k])
				m.faces[fi] = f
				m.uvs[fi] = uv
				m.uv2s[fi] = u2
				break
	PfOps.remove_faces(m, kill)
	for a in adds:
		var nf := PfOps.add_face(m, a[0], a[1], a[2], a[3])
		for sl in a[4]:
			uv_slots.append([nf, sl[0], sl[1], sl[2], sl[3], sl[4]])
	m.invalidate()
	# Slide direction per ring edge, consistent around the ring (the two ring
	# sides of a quad run the same way: c0 -> c1 and c3 -> c2).
	var sign := {ring_edges[0]: 1}
	var pairs := []
	for fi in ring_faces:
		var sd: PackedInt32Array = side_of[fi]
		pairs.append([ekey(sd[0], sd[1]), 1 if sd[0] < sd[1] else -1, ekey(sd[3], sd[2]), 1 if sd[3] < sd[2] else -1])
	var changed := true
	while changed:
		changed = false
		for pr in pairs:
			if sign.has(pr[0]) and not sign.has(pr[2]):
				sign[pr[2]] = sign[pr[0]] * pr[1] * pr[3]
				changed = true
			elif sign.has(pr[2]) and not sign.has(pr[0]):
				sign[pr[0]] = sign[pr[2]] * pr[3] * pr[1]
				changed = true
	for sl in slide:
		sl["sign"] = sign.get(ekey(sl["a"], sl["b"]), 1)
	var vs := {}
	for sl in slide:
		vs[sl["v"]] = true
	return {"verts": vs, "edges": new_edges, "faces": {}, "slide": slide, "uv_slots": uv_slots, "cuts": cuts}

## Edge slide of the new loops: factor in [-1, 1] (0 = evenly spaced).
static func loop_slide(m, data: Dictionary, factor: float) -> void:
	var cuts: int = data["cuts"]
	var step := 1.0 / (cuts + 1)
	var tnew := {}
	for s in data["slide"]:
		var t := clampf(float(s["t"]) + factor * step * int(s.get("sign", 1)), 0.001, 0.999)
		tnew[s["v"]] = [t, s["a"], s["b"]]
		m.verts[s["v"]] = m.verts[s["a"]].lerp(m.verts[s["b"]], t)
	# UVs of the new corners follow along their face side (start -> end).
	for slot in data["uv_slots"]:
		var v: int = slot[4]
		if not tnew.has(v):
			continue
		var t: float = tnew[v][0]
		var tt := t if slot[5] == tnew[v][1] else 1.0 - t
		var uv: PackedVector2Array = m.uvs[slot[0]]
		uv[slot[1]] = (slot[2] as Vector2).lerp(slot[3], tt)
		m.uvs[slot[0]] = uv
	m.invalidate()


# ==============================================================================
# Ctrl+B — Bevel (edges and vertices)
# ==============================================================================

## Faces around vertex v in winding order: [[face, prev_edge, next_edge], ...]
## (prev/next edges at v inside that face). Open fans start at a boundary.
static func fan(m, v: int) -> Array:
	var faces: PackedInt32Array = m.vert_faces(v)
	if faces.is_empty():
		return []
	var info := {}
	for fi in faces:
		var f: PackedInt32Array = m.faces[fi]
		var k: int = m.corner_of(fi, v)
		info[fi] = [ekey(f[(k + f.size() - 1) % f.size()], v), ekey(v, f[(k + 1) % f.size()])]
	# Start: a face whose prev edge has no other face (boundary), else any.
	var start: int = faces[0]
	for fi in faces:
		if m.edge_faces(info[fi][0]).size() == 1:
			start = fi
			break
	var out := []
	var cur := start
	var seen := {}
	while cur >= 0 and not seen.has(cur):
		seen[cur] = true
		out.append([cur, info[cur][0], info[cur][1]])
		var nxt := -1
		for g in m.edge_faces(info[cur][1]):
			if g != cur and info.has(g) and not seen.has(g):
				nxt = g
		cur = nxt
	return out

## Edge bevel. Builds the topology with `segments` profile segments; vertex
## positions follow bevel_update(m, data, width).
static func bevel_edges(m, se: Dictionary, segments := 1) -> Dictionary:
	m.ensure_topology()
	var sel := {}
	for e in se:
		if m.edge_faces(e).size() == 2:
			sel[e] = true
	if sel.is_empty():
		return {"error": "Select edges between two faces"}
	segments = maxi(segments, 1)
	var verts := {}
	# Faces of every selected edge, F1 = the face running a -> b.
	var edge_faces := {}
	for e in sel:
		verts[e.x] = true
		verts[e.y] = true
		var ef: PackedInt32Array = m.edge_faces(e)
		var f1: int = ef[0]
		var f2: int = ef[1]
		var k: int = m.corner_of(f1, e.x)
		var f1v: PackedInt32Array = m.faces[f1]
		if f1v[(k + 1) % f1v.size()] == e.y:
			edge_faces[e] = [f1, f2, e.x, e.y]
		else:
			edge_faces[e] = [f1, f2, e.y, e.x]
	var maps := {}
	for fi in m.faces.size():
		for v in m.faces[fi]:
			if verts.has(v):
				maps[fi] = PfOps._uv_map(m, fi)
				break
	var specs := []          # new vertex position rules
	var corner_pts := {}     # [face, v] -> Array of new vertex ids (in winding order)
	var face_side := {}      # [face, edge] -> vertex id of that face's corner on edge side at v (keyed by v too)
	var caps := []
	var max_w := INF
	for v in verts:
		var fz := fan(m, v)
		if fz.is_empty():
			continue
		# Slide points on unselected edges: amount from the faces sliding along.
		var slide_dir := {}   # edge -> Vector3 accumulated (unit dir / sin)
		var slide_cnt := {}
		var bis := {}         # face -> direction for a face with both edges selected
		for it in fz:
			var fi: int = it[0]
			var pe: Vector2i = it[1]
			var ne: Vector2i = it[2]
			var p: int = pe.x if pe.y == v else pe.y
			var n: int = ne.x if ne.y == v else ne.y
			var dp: Vector3 = (m.verts[p] - m.verts[v])
			var dn: Vector3 = (m.verts[n] - m.verts[v])
			var a := dp.normalized()
			var b := dn.normalized()
			var s := clampf(a.cross(b).length(), 0.05, 1.0)
			var sp: bool = sel.has(pe)
			var sn: bool = sel.has(ne)
			if sp and sn:
				var h := (a + b)
				var half := clampf(sqrt((1.0 - a.dot(b)) * 0.5), 0.05, 1.0)   # sin(theta/2)
				bis[fi] = h.normalized() / half if h.length_squared() > 1e-12 else Vector3.ZERO
				max_w = minf(max_w, minf(dp.length(), dn.length()) * 0.5 * half)
			elif sn:
				slide_dir[pe] = slide_dir.get(pe, Vector3.ZERO) + a / s
				slide_cnt[pe] = slide_cnt.get(pe, 0) + 1
				max_w = minf(max_w, dp.length() * 0.5 * s)
			elif sp:
				slide_dir[ne] = slide_dir.get(ne, Vector3.ZERO) + b / s
				slide_cnt[ne] = slide_cnt.get(ne, 0) + 1
				max_w = minf(max_w, dn.length() * 0.5 * s)
		var slide_vid := {}
		for e in slide_dir:
			var nv: int = m.add_vertex(m.verts[v])
			specs.append({"v": nv, "o": m.verts[v], "d": slide_dir[e] / float(slide_cnt[e])})
			slide_vid[e] = nv
		var ring := []   # cyclic points around v for the cap test
		for it in fz:
			var fi: int = it[0]
			var pe: Vector2i = it[1]
			var ne: Vector2i = it[2]
			var pts := []
			if bis.has(fi):
				var nv: int = m.add_vertex(m.verts[v])
				specs.append({"v": nv, "o": m.verts[v], "d": bis[fi]})
				pts = [nv]
				face_side[[fi, pe]] = nv
				face_side[[fi, ne]] = nv
			else:
				var pin = slide_vid.get(pe, null)
				var pout = slide_vid.get(ne, null)
				if sel.has(ne):
					pts = [pin]
					face_side[[fi, ne]] = pin
				elif sel.has(pe):
					pts = [pout]
					face_side[[fi, pe]] = pout
				else:
					if pin != null:
						pts.append(pin)
					if pin == null or pout == null:
						pts.append(v)
					if pout != null and pout != pin:
						pts.append(pout)
			corner_pts[[fi, v]] = pts
			ring.append_array(pts)
			if sel.has(ne):
				ring.append(["profile", ne, v])
		var nsel := 0
		for e in m.vert_edges(v):
			if sel.has(e):
				nsel += 1
		caps.append([v, ring, fz, nsel])
	if max_w == INF:
		max_w = 1e9
	# Rebuild the faces touching beveled vertices with their corner points.
	for key in corner_pts:
		var fi: int = key[0]
		var v: int = key[1]
		var f: PackedInt32Array = m.faces[fi]
		var uv: PackedVector2Array = m.uvs[fi]
		var u2: PackedVector2Array = m.uv2s[fi]
		var k: int = m.corner_of(fi, v)
		var pts: Array = corner_pts[key]
		if pts.size() == 1 and pts[0] == v:
			continue
		f.remove_at(k)
		var cu := uv[k]
		var cu2 := u2[k]
		uv.remove_at(k)
		u2.remove_at(k)
		for j in range(pts.size() - 1, -1, -1):
			f.insert(k, pts[j])
			uv.insert(k, cu)
			u2.insert(k, cu2)
		m.faces[fi] = f
		m.uvs[fi] = uv
		m.uv2s[fi] = u2
	# Profile points and strips along every selected edge.
	var profile := {}   # [edge, v] -> Array of ids from F1 side to F2 side (incl. ends)
	var strips := {}
	for e in sel:
		var f1: int = edge_faces[e][0]
		var f2: int = edge_faces[e][1]
		for end in [e.x, e.y]:
			var p1 = face_side.get([f1, e], null)
			var p2 = face_side.get([f2, e], null)
			var pf1 = p1 if p1 != null else end
			var pf2 = p2 if p2 != null else end
			var row := [pf1]
			for s in range(1, segments):
				var nv: int = m.add_vertex(m.verts[end])
				specs.append({"v": nv, "bez": [pf1, end, pf2, float(s) / segments], "o": m.verts[end]})
				row.append(nv)
			row.append(pf2)
			profile[[e, end]] = row
		strips[e] = [f1, f2]
	# Correct side lookup: face_side was keyed per (face, edge) without the
	# end vertex; resolve per end by checking which new vertex lies at that end.
	# (Each face holds one corner per end of e: pick the one in corner_pts.)
	for e in sel:
		var f1: int = strips[e][0]
		var f2: int = strips[e][1]
		for end in [e.x, e.y]:
			var a = _corner_on(corner_pts, f1, end, e, sel)
			var b = _corner_on(corner_pts, f2, end, e, sel)
			var row: Array = profile[[e, end]]
			row[0] = a
			row[row.size() - 1] = b
			for sp in specs:
				if sp.has("bez") and row.has(sp["v"]):
					sp["bez"][0] = a
					sp["bez"][2] = b
	var new_faces := {}
	for e in sel:
		var f1: int = strips[e][0]
		var f2: int = strips[e][1]
		# Orientation: in F1 the edge runs a -> b.
		var a: int = edge_faces[e][2]
		var b: int = edge_faces[e][3]
		var ra: Array = profile[[e, a]]
		var rb: Array = profile[[e, b]]
		var mat: int = m.face_mat[f1]
		var smooth: bool = m.face_smooth[f1] != 0
		for s in segments:
			var q := PackedInt32Array([rb[s], ra[s], ra[s + 1], rb[s + 1]])
			new_faces[PfOps.add_face(m, q, PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]), mat, smooth)] = true
	# A vertex with one beveled edge: the profile goes into the face that
	# holds both profile ends (Blender: the end face gains the profile points).
	for c in caps:
		if c[3] != 1 or segments < 2:
			continue
		var v: int = c[0]
		for e in sel:
			if e.x != v and e.y != v:
				continue
			var row: Array = profile[[e, v]]
			var inner := row.slice(1, row.size() - 1)
			for fi in m.faces.size():
				var f: PackedInt32Array = m.faces[fi]
				var n := f.size()
				for k in n:
					var a := f[k]
					var b := f[(k + 1) % n]
					var seq := []
					if a == row[0] and b == row[row.size() - 1]:
						seq = inner
					elif a == row[row.size() - 1] and b == row[0]:
						seq = inner.duplicate()
						seq.reverse()
					else:
						continue
					var uv: PackedVector2Array = m.uvs[fi]
					var u2: PackedVector2Array = m.uv2s[fi]
					for j in range(seq.size() - 1, -1, -1):
						f.insert(k + 1, seq[j])
						uv.insert(k + 1, uv[k])
						u2.insert(k + 1, u2[k])
					m.faces[fi] = f
					m.uvs[fi] = uv
					m.uv2s[fi] = u2
					break
	# Caps where 3+ distinct points remain around a vertex.
	for c in caps:
		var v: int = c[0]
		if c[3] == 1:
			continue
		var pts := []
		for item in c[1]:
			if item is Array and item[0] == "profile":
				var e: Vector2i = item[1]
				var row: Array = profile[[e, v]]
				# Interior profile points, oriented from the previous face side.
				var inner := row.slice(1, row.size() - 1)
				if pts.size() > 0 and pts[pts.size() - 1] == row[row.size() - 1]:
					inner.reverse()
				pts.append_array(inner)
			else:
				if pts.is_empty() or pts[pts.size() - 1] != item:
					pts.append(item)
		if pts.size() > 1 and pts[0] == pts[pts.size() - 1]:
			pts.remove_at(pts.size() - 1)
		var uniq := {}
		for p in pts:
			uniq[p] = true
		if uniq.size() >= 3 and uniq.size() == pts.size() and not pts.has(v):
			pts.reverse()   # caps face the outside: opposite to the fan order
			new_faces[PfOps.add_face(m, PackedInt32Array(pts))] = true
	m.invalidate()
	var drop := {}
	for v in verts:
		if m.vert_faces(v).is_empty():
			drop[v] = true
	var data := {"specs": specs, "maps": maps, "max_w": max_w, "faces": new_faces}
	if not drop.is_empty():
		var remap := PfOps.remove_verts(m, drop)
		data = _remap_data(data, remap)
	return data

static func _corner_on(corner_pts: Dictionary, fi: int, end: int, e: Vector2i, _sel: Dictionary):
	var pts: Array = corner_pts.get([fi, end], [end])
	return pts[0] if pts.size() == 1 else pts[0]

static func _orig_dir(m, fi: int, e: Vector2i, _corner_pts: Dictionary) -> int:
	# Returns +1 when face fi (before rebuilding) ran e.x -> e.y. After the
	# corner rebuild the original vertices are replaced; decide from the
	# remaining winding: the corner for e.x comes right before the one for e.y.
	var f: PackedInt32Array = m.faces[fi]
	var ia := -1
	var ib := -1
	var pa: Array = _corner_pts.get([fi, e.x], [e.x])
	var pb: Array = _corner_pts.get([fi, e.y], [e.y])
	for k in f.size():
		if f[k] == pa[pa.size() - 1]:
			ia = k
		if f[k] == pb[0]:
			ib = k
	if ia >= 0 and ib >= 0 and (ia + 1) % f.size() == ib:
		return 1
	return -1

static func _remap_data(data: Dictionary, remap: Dictionary) -> Dictionary:
	for sp in data["specs"]:
		sp["v"] = remap.get(sp["v"], sp["v"])
		if sp.has("bez"):
			var bz: Array = sp["bez"]
			bz[0] = remap.get(bz[0], bz[0])
			bz[2] = remap.get(bz[2], bz[2])
	return data

## Places the bevel vertices for `width` (clamped to avoid overlaps).
static func bevel_update(m, data: Dictionary, width: float) -> float:
	var w := clampf(width, 0.0, float(data["max_w"]))
	for sp in data["specs"]:
		if sp.has("d"):
			m.verts[sp["v"]] = (sp["o"] as Vector3) + (sp["d"] as Vector3) * w
	for sp in data["specs"]:
		if sp.has("bez"):
			var bz: Array = sp["bez"]
			var t: float = bz[3]
			var p0: Vector3 = m.verts[bz[0]]
			var p2: Vector3 = m.verts[bz[2]]
			var c: Vector3 = sp["o"]
			m.verts[sp["v"]] = p0 * (1.0 - t) * (1.0 - t) + c * 2.0 * t * (1.0 - t) + p2 * t * t
	var maps: Dictionary = data["maps"]
	for fi in maps:
		if fi >= m.faces.size():
			continue
		var f: PackedInt32Array = m.faces[fi]
		var uv: PackedVector2Array = m.uvs[fi]
		for k in f.size():
			uv[k] = PfOps._uv_eval(maps[fi], m.verts[f[k]], uv[k])
		m.uvs[fi] = uv
	m.invalidate()
	return w

## Vertex bevel: each selected vertex is cut off (one new vertex per edge).
static func bevel_verts(m, sv: Dictionary) -> Dictionary:
	m.ensure_topology()
	var specs := []
	var new_faces := {}
	var max_w := INF
	var maps := {}
	for v in sv:
		for fi in m.vert_faces(v):
			maps[fi] = PfOps._uv_map(m, fi)
	var done := 0
	for v in sv:
		var fz := fan(m, v)
		if fz.is_empty():
			continue
		var closed_fan: bool = fz.size() == m.vert_edges(v).size()
		var on_edge := {}
		for e in m.vert_edges(v):
			var w: int = e.x if e.y == v else e.y
			var d: Vector3 = m.verts[w] - m.verts[v]
			max_w = minf(max_w, d.length() * 0.5)
			var nv: int = m.add_vertex(m.verts[v])
			specs.append({"v": nv, "o": m.verts[v], "d": d.normalized()})
			on_edge[e] = nv
		var ring := PackedInt32Array()
		for it in fz:
			var fi: int = it[0]
			var a: int = on_edge[it[1]]
			var b: int = on_edge[it[2]]
			var f: PackedInt32Array = m.faces[fi]
			var uv: PackedVector2Array = m.uvs[fi]
			var u2: PackedVector2Array = m.uv2s[fi]
			var k: int = m.corner_of(fi, v)
			f[k] = a
			f.insert(k + 1, b)
			uv.insert(k + 1, uv[k])
			u2.insert(k + 1, u2[k])
			m.faces[fi] = f
			m.uvs[fi] = uv
			m.uv2s[fi] = u2
			if ring.is_empty() or ring[ring.size() - 1] != a:
				ring.append(a)
			ring.append(b)
		if ring.size() > 1 and ring[0] == ring[ring.size() - 1]:
			ring.remove_at(ring.size() - 1)
		if ring.size() >= 3 and closed_fan:
			ring.reverse()
			new_faces[PfOps.add_face(m, ring)] = true
		m.invalidate()
		done += 1
	if done == 0:
		return {"error": "Select vertices with faces"}
	m.invalidate()
	var drop := {}
	for v in sv:
		if m.vert_faces(v).is_empty() and m.vert_edges(v).is_empty():
			drop[v] = true
	var data := {"specs": specs, "maps": maps, "max_w": max_w if max_w != INF else 1e9, "faces": new_faces}
	if not drop.is_empty():
		data = _remap_data(data, PfOps.remove_verts(m, drop))
	return data


# ==============================================================================
# P — Separate, Ctrl+J — Join
# ==============================================================================

## Copies faces `fs` into a new mesh (materials and flags kept).
static func extract(m, fs: Dictionary):
	var out = PfMesh.new()
	out.materials = m.materials.duplicate()
	out.world_uv = m.world_uv
	out.texel_density = m.texel_density
	out.has_uv2 = m.has_uv2
	var map := {}
	for fi in fs:
		var f := PackedInt32Array()
		for v in m.faces[fi]:
			if not map.has(v):
				map[v] = out.add_vertex(m.verts[v])
			f.append(map[v])
		PfOps.add_face(out, f, m.uvs[fi].duplicate(), m.face_mat[fi], m.face_smooth[fi] != 0, m.uv2s[fi].duplicate())
	for e in m.sharp_edges:
		if map.has(e.x) and map.has(e.y):
			out.sharp_edges[ekey(map[e.x], map[e.y])] = true
	for e in m.seam_edges:
		if map.has(e.x) and map.has(e.y):
			out.seam_edges[ekey(map[e.x], map[e.y])] = true
	for e in m.wire_edges:
		if map.has(e.x) and map.has(e.y):
			out.wire_edges[ekey(map[e.x], map[e.y])] = true
	return out

## Multi-object edit: owner of every face (tags of new faces spread from
## their tagged neighbours; anything left goes to `fallback`).
static func resolve_tags(m, fallback: int) -> PackedInt32Array:
	m.ensure_topology()
	var tags: PackedInt32Array = m.face_tag.duplicate()
	tags.resize(m.faces.size())
	var changed := true
	while changed:
		changed = false
		for fi in m.faces.size():
			if tags[fi] >= 0:
				continue
			for e in m.face_edges(fi):
				for g in m.edge_faces(e):
					if tags[g] >= 0:
						tags[fi] = tags[g]
						changed = true
						break
				if tags[fi] >= 0:
					break
	for fi in tags.size():
		if tags[fi] < 0:
			tags[fi] = fallback
	return tags

## Splits a combined mesh into one mesh per owner, each in its own space
## (`to_local[i]`: combined space -> object i space). Loose wire edges and
## vertices without faces go to `fallback`.
static func split_by_tags(m, owners: int, to_local: Array, fallback: int) -> Array:
	var tags := resolve_tags(m, fallback)
	var groups := []
	for i in owners:
		groups.append({})
	for fi in m.faces.size():
		groups[clampi(tags[fi], 0, owners - 1)][fi] = true
	var out := []
	for i in owners:
		var part = extract(m, groups[i])
		if i == fallback:
			var used := {}
			for f in groups[i]:
				for v in m.faces[f]:
					used[v] = true
			var vmap := {}
			for e in m.wire_edges:
				for v in [e.x, e.y]:
					if not used.has(v) and not vmap.has(v):
						vmap[v] = part.add_vertex(m.verts[v])
			for e in m.wire_edges:
				if vmap.has(e.x) and vmap.has(e.y):
					part.wire_edges[ekey(vmap[e.x], vmap[e.y])] = true
		var xf: Transform3D = to_local[i]
		for v in part.verts.size():
			part.verts[v] = xf * part.verts[v]
		if xf.basis.determinant() < 0.0:
			var all := {}
			for fi in part.faces.size():
				all[fi] = true
			PfOps.flip(part, all)
		part.face_tag.fill(-1)
		out.append(part)
	return out

## Groups of faces for Separate: "selection" (one group), "loose" (connected
## parts), "material" (per slot).
static func separate_groups(m, kind: String, sf: Dictionary) -> Array:
	match kind:
		"selection":
			return [sf] if not sf.is_empty() else []
		"loose":
			var all := {}
			for fi in m.faces.size():
				all[fi] = true
			return PfOps._face_regions(m, all)
		"material":
			var by := {}
			for fi in m.faces.size():
				var s: int = m.face_mat[fi]
				if not by.has(s):
					by[s] = {}
				by[s][fi] = true
			return by.values()
	return []

## Appends `other` (in its own space) into `m` with `xf` (other -> m space).
## Materials are merged by identity.
static func join_into(m, other, xf: Transform3D) -> void:
	var slot_map := {}
	for i in other.materials.size():
		var mat = other.materials[i]
		var at: int = m.materials.find(mat) if mat != null else -1
		if at < 0:
			m.materials.append(mat)
			at = m.materials.size() - 1
		slot_map[i] = at
	var first: int = m.faces.size()
	m.append_mesh(other, xf)
	for fi in range(first, m.faces.size()):
		m.face_mat[fi] = slot_map.get(m.face_mat[fi], 0)
	# A mirrored transform flips the winding: fix it.
	if xf.basis.determinant() < 0.0:
		var fs := {}
		for fi in range(first, m.faces.size()):
			fs[fi] = true
		PfOps.flip(m, fs)


# ==============================================================================
# Triangles (e.g. CSG / Boolean result) -> PfMesh
# ==============================================================================

## Godot ArrayMesh (clockwise triangles) -> welded PfMesh with corner UVs,
## material slots by material identity and coplanar triangle pairs joined.
static func from_array_mesh(am: ArrayMesh, slot_materials: Array = []):
	var m = PfMesh.new()
	m.materials = slot_materials.duplicate()
	var lookup := {}
	for si in am.get_surface_count():
		var arr := am.surface_get_arrays(si)
		var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV] if arr[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(pos.size()))
		var mat := am.surface_get_material(si)
		var slot: int = m.materials.find(mat) if mat != null else 0
		if slot < 0:
			m.materials.append(mat)
			slot = m.materials.size() - 1
		for t in range(0, idx.size() - 2, 3):
			var corners := [idx[t], idx[t + 2], idx[t + 1]]   # CW -> CCW
			var f := PackedInt32Array()
			var fu := PackedVector2Array()
			for c in corners:
				var key := pos[c].snapped(Vector3.ONE * 1e-5)
				if not lookup.has(key):
					lookup[key] = m.add_vertex(pos[c])
				f.append(lookup[key])
				fu.append(uv[c] if c < uv.size() else Vector2.ZERO)
			if f[0] == f[1] or f[1] == f[2] or f[0] == f[2]:
				continue
			if (m.verts[f[1]] - m.verts[f[0]]).cross(m.verts[f[2]] - m.verts[f[0]]).length_squared() < 1e-16:
				continue
			m.add_face(f, fu, slot)
	var all := {}
	for fi in m.faces.size():
		all[fi] = true
	if not all.is_empty():
		PfOps.tris_to_quads(m, all)
	return m

## Edges used by != 2 faces (Boolean needs closed meshes).
static func open_edges(m) -> int:
	m.ensure_topology()
	var n := 0
	for e in m.edges():
		if m.edge_faces(e).size() != 2:
			n += 1
	return n

# ==============================================================================
# Material slots (Blender: slot list per object, faces store a slot index)
# ==============================================================================

static func slot_count(m) -> int:
	var n: int = maxi(m.materials.size(), 1)
	for s in m.face_mat:
		n = maxi(n, s + 1)
	return n

static func add_slot(m) -> int:
	m.materials.resize(slot_count(m) + 1)
	return m.materials.size() - 1

## Blender: faces of the removed slot fall back to the previous slot.
static func remove_slot(m, slot: int) -> void:
	m.materials.resize(slot_count(m))
	m.materials.remove_at(slot)
	for fi in m.face_mat.size():
		if m.face_mat[fi] > slot or (m.face_mat[fi] == slot and slot > 0):
			m.face_mat[fi] -= 1
	m.invalidate()

static func set_slot_material(m, slot: int, mat: Material) -> void:
	m.materials.resize(maxi(slot_count(m), slot + 1))
	m.materials[slot] = mat

static func assign_slot(m, sf: Dictionary, slot: int) -> void:
	m.materials.resize(maxi(slot_count(m), slot + 1))
	for fi in sf:
		m.face_mat[fi] = slot
	m.invalidate()
