## Mesh operation tests (headless):
##   godot --headless --path . -s tests/unit/test_ops.gd
extends SceneTree

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfOps := preload("res://addons/polyforge/core/pf_ops.gd")
const PfSelect := preload("res://addons/polyforge/core/pf_select.gd")

var fails := 0

func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		fails += 1

func _init() -> void:
	_delete()
	_dissolve()
	_merge()
	_extrude()
	_inset()
	_duplicate_and_fill()
	_normals_tris()
	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)

func closed(m) -> bool:
	m.ensure_topology()
	for e in m.edges():
		if m.edge_faces(e).size() != 2:
			return false
	return true

func volume(m) -> float:
	var vol := 0.0
	for fi in m.faces.size():
		var f: PackedInt32Array = m.faces[fi]
		for k in range(1, f.size() - 1):
			vol += m.verts[f[0]].dot(m.verts[f[k]].cross(m.verts[f[k + 1]])) / 6.0
	return vol

func consistent(m) -> bool:
	# Every interior edge is used in opposite directions by its two faces.
	var seen := {}
	for f in m.faces:
		for k in f.size():
			var d := Vector2i(f[k], f[(k + 1) % f.size()])
			if seen.has(d):
				return false
			seen[d] = true
	return true

func face_with_normal(m, n: Vector3) -> int:
	for fi in m.faces.size():
		if m.face_normal(fi).is_equal_approx(n):
			return fi
	return -1

func verts_where(m, cond: Callable) -> Dictionary:
	var out := {}
	for v in m.verts.size():
		if cond.call(m.verts[v]):
			out[v] = true
	return out

func ok_mesh(m, name: String) -> void:
	check(m.validate() == "", "%s valid (%s)" % [name, m.validate()])


func _delete() -> void:
	print("== delete (X)")
	var c = PfPrim.cube()
	PfOps.delete(c, "verts", {0: true}, {}, {})
	check(c.verts.size() == 7 and c.faces.size() == 3, "delete vertex: 7 verts, 3 faces left")
	ok_mesh(c, "after delete vertex")
	c = PfPrim.cube()
	PfOps.delete(c, "faces", {}, {}, {face_with_normal(c, Vector3.UP): true})
	check(c.verts.size() == 8 and c.faces.size() == 5, "delete one face: 5 faces, all 8 verts still used")
	c = PfPrim.cube()
	var all_f := {}
	for i in 6:
		all_f[i] = true
	PfOps.delete(c, "only_faces", {}, {}, all_f)
	check(c.faces.is_empty() and c.edges().size() == 12 and c.verts.size() == 8, "Only Faces: 12 wire edges and 8 verts stay")
	c = PfPrim.cube()
	var e0: Vector2i = c.edges()[0]
	PfOps.delete(c, "edges", {}, {e0: true}, {})
	check(c.faces.size() == 4 and c.verts.size() == 8 and c.edge_id(e0) < 0, "delete edge: its 2 faces go, the edge goes")
	c = PfPrim.cube()
	PfOps.delete(c, "faces", {}, {}, all_f)
	check(c.verts.is_empty() and c.faces.is_empty(), "delete all faces: nothing left")

func _dissolve() -> void:
	print("== dissolve (Ctrl+X)")
	var g = PfPrim.grid(2, 2)
	PfOps.dissolve_faces(g, {0: true, 1: true, 2: true, 3: true})
	check(g.faces.size() == 1 and g.faces[0].size() == 8 and g.verts.size() == 8, "dissolve 2x2 faces -> one 8-gon, centre vertex removed")
	ok_mesh(g, "dissolved grid")
	check(g.face_normal(0).is_equal_approx(Vector3.UP), "orientation kept")
	g = PfPrim.grid(2, 1)
	var mid := Vector2i(-1, -1)
	for e in g.edges():
		if g.edge_faces(e).size() == 2:
			mid = e
	PfOps.dissolve_edges(g, {mid: true})
	check(g.faces.size() == 1 and g.faces[0].size() == 4 and g.verts.size() == 4, "dissolve middle edge of 2 quads -> 1 quad (chain verts dissolved)")
	g = PfPrim.grid(2, 2)
	var center := verts_where(g, func(p): return p.is_zero_approx())
	PfOps.dissolve_verts(g, center)
	check(g.faces.size() == 1 and g.faces[0].size() == 8 and g.verts.size() == 8, "dissolve centre vertex -> one 8-gon")
	var c = PfPrim.cube()
	var r: Dictionary = PfOps.dissolve_faces(c, {0: true})
	check(r.has("error"), "dissolve a single face -> message")

func _merge() -> void:
	print("== merge (M)")
	var c = PfPrim.cube()
	var top := verts_where(c, func(p): return p.y > 0)
	var r: Dictionary = PfOps.merge_at(c, top, Vector3(0, 1, 0))
	check(c.verts.size() == 5 and c.faces.size() == 5, "top 4 verts at center -> pyramid (5 verts, 5 faces)")
	check(closed(c) and volume(c) > 0.0 and consistent(c), "pyramid closed, outward, consistent")
	check(r["verts"].size() == 1 and c.verts[r["verts"].keys()[0]].is_equal_approx(Vector3(0, 1, 0)), "merged vertex selected at the target")
	var two = PfPrim.cube()
	two.append_mesh(PfPrim.cube())
	r = PfOps.merge_by_distance(two, {}, 0.001)
	check(r["removed"] == 8 and two.verts.size() == 8 and two.faces.size() == 6, "by distance: duplicate cube welded (8 removed, duplicate faces gone)")
	var g = PfPrim.grid(4, 1)
	var sel := verts_where(g, func(p): return p.x < -0.4)
	sel.merge(verts_where(g, func(p): return p.x > 0.4))
	r = PfOps.merge_collapse(g, sel)
	check(r["verts"].size() == 2, "collapse: two separate groups -> two vertices")
	ok_mesh(g, "collapsed grid")

func _extrude() -> void:
	print("== extrude (E / Alt+E)")
	var p = PfPrim.plane()
	var r: Dictionary = PfOps.extrude_region(p, {}, {}, {0: true})
	check(p.verts.size() == 8 and p.faces.size() == 5, "extrude a plane: 8 verts, 1 + 4 side faces")
	for v in r["verts"]:
		p.verts[v] += Vector3.UP
	check(consistent(p), "box without bottom: consistent winding")
	var outward := true
	for fi in r["side_faces"]:
		var n: Vector3 = p.face_normal(fi)
		var c: Vector3 = p.face_center(fi)
		if n.dot(Vector3(c.x, 0, c.z)) <= 0.0:
			outward = false
	check(outward, "side faces face outward")
	check(r["normal"].is_equal_approx(Vector3.UP), "region normal = +Y (move along it)")
	var c = PfPrim.cube()
	var top := face_with_normal(c, Vector3.UP)
	r = PfOps.extrude_region(c, {}, {}, {top: true})
	for v in r["verts"]:
		c.verts[v] += Vector3.UP
	check(c.verts.size() == 12 and c.faces.size() == 10 and closed(c) and volume(c) > 0.0 and consistent(c), "extrude cube top: 12 verts, 10 faces, closed & outward")
	check(c.bounds().size.is_equal_approx(Vector3(2, 3, 2)), "taller by 1")
	var g = PfPrim.grid(1, 1)
	var be: Vector2i = g.edges()[0]
	r = PfOps.extrude_region(g, {be.x: true, be.y: true}, {be: true}, {})
	check(g.faces.size() == 2 and g.verts.size() == 6 and consistent(g), "extrude a boundary edge -> new quad, consistent")
	var lone = PfMesh.new()
	lone.add_vertex(Vector3.ZERO)
	r = PfOps.extrude_region(lone, {0: true}, {}, {})
	check(lone.verts.size() == 2 and lone.edges().size() == 1, "extrude a loose vertex -> vertex + wire edge")
	var cube = PfPrim.cube()
	var cl: Dictionary = {}
	for i in 6:
		cl[i] = true
	check(PfOps.extrude_region(cube, {}, {}, cl).has("error"), "closed region -> message")
	c = PfPrim.cube()
	r = PfOps.extrude_individual(c, {0: true, 1: true})
	check(c.faces.size() == 14 and c.verts.size() == 16, "individual faces: 2 faces -> 8 sides, 8 new verts")
	for v in r["dirs"]:
		c.verts[v] += (r["dirs"][v] as Vector3) * 0.5
	check(consistent(c), "individual extrusion consistent")

func _inset() -> void:
	print("== inset (I)")
	var c = PfPrim.cube()
	var top := face_with_normal(c, Vector3.UP)
	var d: Dictionary = PfOps.inset(c, {top: true})
	PfOps.inset_update(c, d, 0.25)
	check(c.verts.size() == 12 and c.faces.size() == 10, "inset top: 12 verts, 10 faces")
	check(closed(c) and consistent(c) and is_equal_approx(volume(c), 8.0), "closed, consistent, same volume")
	var inner_ok := true
	for it in d["inner"]:
		var p: Vector3 = c.verts[it["v"]]
		if not (is_equal_approx(absf(p.x), 0.75) and is_equal_approx(absf(p.z), 0.75)):
			inner_ok = false
	check(inner_ok, "inner corners 0.25 in from the edges")
	var uv_ok := true
	for fi in c.faces.size():
		if c.uvs[fi].size() != c.faces[fi].size():
			uv_ok = false
	check(uv_ok, "UVs on every corner")
	var c2 = PfPrim.cube()
	var front := face_with_normal(c2, Vector3.BACK)
	var t2 := face_with_normal(c2, Vector3.UP)
	d = PfOps.inset(c2, {front: true, t2: true})
	check(c2.verts.size() == 8 + 6, "region inset of 2 faces: 6 new verts (shared boundary loop)")
	var c3 = PfPrim.cube()
	d = PfOps.inset(c3, {face_with_normal(c3, Vector3.BACK): true, face_with_normal(c3, Vector3.UP): true}, true)
	check(c3.verts.size() == 8 + 8, "individual inset: 8 new verts")
	PfOps.inset_update(c3, d, 0.2)
	check(consistent(c3), "individual inset consistent")

func _duplicate_and_fill() -> void:
	print("== duplicate (Shift+D), make edge/face (F)")
	var c = PfPrim.cube()
	var all_v := {}
	for v in 8:
		all_v[v] = true
	var all_f := {}
	for f in 6:
		all_f[f] = true
	var r: Dictionary = PfOps.duplicate_geometry(c, all_v, PfSelect.verts_to_edges(c, all_v), all_f)
	check(c.verts.size() == 16 and c.faces.size() == 12 and r["verts"].size() == 8 and r["faces"].size() == 6, "duplicate cube: new copy selected")
	var two = PfMesh.new()
	two.add_vertex(Vector3.ZERO)
	two.add_vertex(Vector3.RIGHT)
	r = PfOps.make_edge_face(two, {0: true, 1: true}, {})
	check(two.edges().size() == 1 and two.wire_edges.size() == 1, "F on two vertices -> edge")
	check(PfOps.make_edge_face(two, {0: true, 1: true}, {}).has("error"), "F again -> already exists")
	c = PfPrim.cube()
	var top := face_with_normal(c, Vector3.UP)
	var tv := {}
	for v in c.faces[top]:
		tv[v] = true
	PfOps.delete(c, "only_faces", {}, {}, {top: true})
	r = PfOps.make_edge_face(c, tv, PfSelect.verts_to_edges(c, tv))
	check(c.faces.size() == 6 and closed(c) and volume(c) > 0.0 and consistent(c), "F on the hole's edge loop -> face oriented like its neighbours")
	var pts = PfMesh.new()
	for p in [Vector3(0, 0, 0), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 1)]:
		pts.add_vertex(p)
	r = PfOps.make_edge_face(pts, {0: true, 1: true, 2: true, 3: true}, {}, Vector3.UP)
	check(pts.faces.size() == 1 and pts.face_normal(0).is_equal_approx(Vector3.UP), "F on loose vertices -> face sorted around its centre, facing the viewer")
	check(PfOps.make_edge_face(pts, {0: true, 1: true, 2: true, 3: true}, {}, Vector3.UP).has("error") and pts.faces.size() == 1, "F again on the same vertices -> no duplicate face")
	var tq = PfMesh.new()
	for p in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, -1), Vector3(0, 0, -1)]:
		tq.add_vertex(p)
	tq.add_face(PackedInt32Array([0, 1, 2]))
	tq.add_face(PackedInt32Array([0, 2, 3]))
	r = PfOps.make_edge_face(tq, {0: true, 1: true, 2: true, 3: true}, {}, Vector3.UP, {0: true, 1: true})
	check(not r.has("error") and tq.faces.size() == 1 and tq.faces[0].size() == 4 and tq.face_normal(0).is_equal_approx(Vector3.UP), "F on two adjacent triangles -> one quad (Blender)")

func _normals_tris() -> void:
	print("== normals, triangulate, tris to quads, smooth")
	var c = PfPrim.cube()
	PfOps.flip(c, {0: true, 3: true})
	check(not consistent(c), "(control) flipped faces are inconsistent")
	var all_f := {}
	for f in 6:
		all_f[f] = true
	PfOps.recalc_normals(c, all_f)
	check(consistent(c) and volume(c) > 0.0, "Recalculate Outside fixes them")
	PfOps.recalc_normals(c, all_f, true)
	check(volume(c) < 0.0, "Recalculate Inside points them in")
	c = PfPrim.cube()
	var r: Dictionary = PfOps.triangulate(c, all_f)
	check(c.faces.size() == 12 and closed(c) and consistent(c) and volume(c) > 0.0, "triangulate cube -> 12 triangles")
	var tri := {}
	for f in c.faces.size():
		tri[f] = true
	r = PfOps.tris_to_quads(c, tri)
	check(c.faces.size() == 6 and closed(c) and consistent(c), "tris to quads -> back to 6 quads")
	var g = PfPrim.grid(2, 2)
	var center := verts_where(g, func(p): return p.is_zero_approx())
	var cv: int = center.keys()[0]
	g.verts[cv] = Vector3(0, 1, 0)
	PfOps.smooth_verts(g, center)
	check(is_equal_approx(g.verts[cv].y, 0.5), "smooth vertices halves the bump (factor 0.5)")
