## Stage 2B operator tests (headless):
##   godot --headless --path . -s tests/unit/test_ops2.gd
extends SceneTree

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfOps := preload("res://addons/polyforge/core/pf_ops.gd")
const PfOps2 := preload("res://addons/polyforge/core/pf_ops2.gd")

var fails := 0

func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		fails += 1

func _init() -> void:
	_connect()
	_loopcut()
	_bevel()
	_bevel_verts()
	_bevel_split_end()
	_separate_join()
	_multi_split()
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
	var seen := {}
	for f in m.faces:
		for k in f.size():
			var d := Vector2i(f[k], f[(k + 1) % f.size()])
			if seen.has(d):
				return false
			seen[d] = true
	return true

func solid(m, name: String) -> void:
	check(m.validate() == "" and closed(m) and consistent(m) and volume(m) > 0.0,
		"%s: valid, closed, consistent, outward (%s, closed %s, cons %s, vol %.3f)" % [name, m.validate(), closed(m), consistent(m), volume(m)])

func edge_where(m, cond: Callable) -> Vector2i:
	for e in m.edges():
		if cond.call(m.verts[e.x], m.verts[e.y]):
			return e
	return Vector2i(-1, -1)

func _connect() -> void:
	print("== J connect vertex path")
	var c = PfPrim.cube()
	var top := -1
	for fi in c.faces.size():
		if c.face_normal(fi).is_equal_approx(Vector3.UP):
			top = fi
	var f: PackedInt32Array = c.faces[top]
	var r: Dictionary = PfOps2.connect_path(c, [f[0], f[2]])
	check(c.faces.size() == 7 and r["edges"].size() == 1, "diagonal across the top face splits it")
	solid(c, "after J")
	check(PfOps2.connect_path(c, [f[0], f[1]]).has("error"), "already an edge -> message")

func _loopcut() -> void:
	print("== Ctrl+R loop cut and slide")
	var c = PfPrim.cube()
	var e := edge_where(c, func(a, b): return is_equal_approx(a.y, b.y) and is_equal_approx(a.z, b.z) and a.y > 0 and a.z > 0)
	check(PfOps2.loop_preview(c, e, 1).size() == 4, "preview: 4 lines around the cube")
	var r: Dictionary = PfOps2.loop_cut(c, e, 1)
	check(c.verts.size() == 12 and c.faces.size() == 10 and r["edges"].size() == 4, "1 cut: 12 verts, 10 faces, a 4-edge loop selected")
	solid(c, "after loop cut")
	var xs := {}
	for v in r["verts"]:
		xs[snappedf(c.verts[v].x, 0.001)] = true
	check(xs.size() == 1 and xs.has(0.0), "new loop in the middle (x = 0)")
	PfOps2.loop_slide(c, r, 0.5)
	xs.clear()
	for v in r["verts"]:
		xs[snappedf(c.verts[v].x, 0.001)] = true
	check(xs.size() == 1 and absf(xs.keys()[0]) > 0.4, "slide 0.5 moves the loop (x = %s)" % [xs.keys()])
	solid(c, "after slide")
	var uv_ok := true
	for fi in c.faces.size():
		for u in c.uvs[fi]:
			if u.x < -0.01 or u.x > 1.01 or u.y < -0.01 or u.y > 1.01:
				uv_ok = false
	check(uv_ok, "UVs stay inside the original layout")
	var c3 = PfPrim.cube()
	r = PfOps2.loop_cut(c3, e, 3)
	check(c3.verts.size() == 8 + 12 and c3.faces.size() == 6 - 4 + 16, "3 cuts: 12 new verts, 4 faces become 16")
	solid(c3, "3 cuts")
	var cyl = PfPrim.cylinder(8)
	var side := edge_where(cyl, func(a, b): return absf(a.y - b.y) > 1.0)
	r = PfOps2.loop_cut(cyl, side, 1)
	check(cyl.faces.size() == 8 * 2 + 2 and cyl.faces[0].size() >= 3, "cylinder: ring around the sides, caps keep their shape")
	solid(cyl, "cylinder loop cut")

func _bevel() -> void:
	print("== Ctrl+B edge bevel")
	var c = PfPrim.cube()
	var e := edge_where(c, func(a, b): return a.y > 0 and b.y > 0 and a.z > 0 and b.z > 0)
	var d: Dictionary = PfOps2.bevel_edges(c, {e: true}, 1)
	PfOps2.bevel_update(c, d, 0.2)
	check(c.faces.size() == 7 and c.verts.size() == 10, "one edge, 1 segment: 7 faces, 10 verts (got %d / %d)" % [c.faces.size(), c.verts.size()])
	solid(c, "single edge bevel")
	c = PfPrim.cube()
	e = edge_where(c, func(a, b): return a.y > 0 and b.y > 0 and a.z > 0 and b.z > 0)
	d = PfOps2.bevel_edges(c, {e: true}, 3)
	PfOps2.bevel_update(c, d, 0.3)
	check(c.faces.size() == 9, "one edge, 3 segments: 9 faces (got %d)" % c.faces.size())
	solid(c, "3-segment bevel")
	c = PfPrim.cube()
	var all := {}
	for ee in c.edges():
		all[ee] = true
	d = PfOps2.bevel_edges(c, all, 1)
	PfOps2.bevel_update(c, d, 0.2)
	check(c.faces.size() == 26, "all 12 edges: 6 + 12 strips + 8 corner caps = 26 faces (got %d)" % c.faces.size())
	solid(c, "full bevel")
	c = PfPrim.cube()
	d = PfOps2.bevel_edges(c, all, 2)
	PfOps2.bevel_update(c, d, 0.25)
	solid(c, "full bevel, 2 segments")
	var c7 = PfPrim.cube()
	var e7 := edge_where(c7, func(a, b): return a.y > 0 and b.y > 0 and a.z > 0 and b.z > 0)
	PfOps2.bevel_update(c7, PfOps2.bevel_edges(c7, {e7: true}, 3), 0.3)
	var big := 0
	for f in c7.faces:
		if f.size() == 7:
			big += 1
	check(big == 2, "3 segments on one edge: both end faces become 7-gons (Blender)")
	c = PfPrim.cube()
	var two := {}
	for ee in c.edges():
		var a: Vector3 = c.verts[ee.x]
		var b: Vector3 = c.verts[ee.y]
		if a.y > 0 and b.y > 0 and (a.z > 0 and b.z > 0 or a.x > 0 and b.x > 0):
			two[ee] = true
	d = PfOps2.bevel_edges(c, two, 1)
	PfOps2.bevel_update(c, d, 0.2)
	solid(c, "two edges meeting at a corner")
	var w := PfOps2.bevel_update(c, d, 50.0)
	check(w <= 1.0, "width clamped so geometry does not overlap (%.3f)" % w)

func _bevel_verts() -> void:
	print("== Ctrl+Shift+B vertex bevel")
	var c = PfPrim.cube()
	var v := -1
	for i in c.verts.size():
		if c.verts[i].is_equal_approx(Vector3.ONE):
			v = i
	var d: Dictionary = PfOps2.bevel_verts(c, {v: true})
	PfOps2.bevel_update(c, d, 0.3)
	check(c.faces.size() == 7 and c.verts.size() == 10, "corner cut: 7 faces, 10 verts")
	solid(c, "vertex bevel")

func _separate_join() -> void:
	print("== P separate / Ctrl+J join")
	var two = PfPrim.cube()
	two.append_mesh(PfPrim.cube(), Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)))
	var groups: Array = PfOps2.separate_groups(two, "loose", {})
	check(groups.size() == 2, "loose parts: 2 groups")
	var part = PfOps2.extract(two, groups[1])
	check(part.verts.size() == 8 and part.faces.size() == 6, "extracted part is a full cube")
	solid(part, "extracted")
	var a = PfPrim.cube()
	var b = PfPrim.cube()
	var mat := StandardMaterial3D.new()
	b.materials = [mat]
	PfOps2.join_into(a, b, Transform3D(Basis.IDENTITY, Vector3(3, 0, 0)))
	check(a.verts.size() == 16 and a.faces.size() == 12 and a.materials.has(mat), "join: 16 verts, 12 faces, materials merged")
	var c = PfPrim.cube()
	PfOps2.join_into(c, PfPrim.cube(), Transform3D(Basis.from_scale(Vector3(-1, 1, 1)), Vector3(4, 0, 0)))
	check(volume(c) > 0.0 and consistent(c), "mirrored join keeps outward faces")


func _multi_split() -> void:
	print("== multi-object edit: combined mesh split back by face owner")
	var comb = PfMesh.new()
	var xa := Transform3D(Basis.IDENTITY, Vector3(-3, 0, 0))
	var xb := Transform3D(Basis.from_scale(Vector3(-1, 1, 1)), Vector3(3, 0, 0))   # mirrored object
	for i in 2:
		var first: int = comb.faces.size()
		PfOps2.join_into(comb, PfPrim.cube(), xa if i == 0 else xb)
		for fi in range(first, comb.faces.size()):
			comb.face_tag[fi] = i
	# Extrude the top face of object 0 inside the combined mesh.
	var top := -1
	for fi in comb.faces.size():
		if comb.face_tag[fi] == 0 and comb.face_normal(fi).is_equal_approx(Vector3.UP):
			top = fi
	var r: Dictionary = PfOps.extrude_region(comb, {}, {}, {top: true})
	for v in r["verts"]:
		comb.verts[v] += Vector3.UP
	var parts: Array = PfOps2.split_by_tags(comb, 2, [xa.affine_inverse(), xb.affine_inverse()], 1)
	check(parts[0].faces.size() == 10 and parts[1].faces.size() == 6, "new side faces follow their owner (10 / 6 faces)")
	solid(parts[0], "object 0 back in its own space")
	solid(parts[1], "mirrored object 1 back in its own space")
	check(parts[1].bounds().size.is_equal_approx(Vector3(2, 2, 2)) and parts[0].bounds().size.is_equal_approx(Vector3(2, 3, 2)), "local sizes correct")


func _oriented(m) -> bool:
	var seen := {}
	for f in m.faces:
		for k in f.size():
			var e := Vector2i(f[k], f[(k + 1) % f.size()])
			if seen.has(e):
				return false
			seen[e] = true
	return true

func _bevel_split_end() -> void:
	print("== bevel: end region split into several faces (inner L corner)")
	for seg in [1, 3]:
		var m = PfMesh.new()
		var poly := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 0.2), Vector2(0.2, 0.2), Vector2(0.2, 1), Vector2(0, 1)]
		for p in poly:
			m.add_vertex(Vector3(p.x, p.y, 0.0))
		for p in poly:
			m.add_vertex(Vector3(p.x, p.y, 1.0))
		m.add_face(PackedInt32Array([6, 7, 8, 9]))
		m.add_face(PackedInt32Array([6, 9, 10, 11]))
		m.add_face(PackedInt32Array([3, 2, 1, 0]))
		m.add_face(PackedInt32Array([5, 4, 3, 0]))
		for i in 6:
			var j := (i + 1) % 6
			m.add_face(PackedInt32Array([i, j, j + 6, i + 6]))
		var d: Dictionary = PfOps2.bevel_edges(m, {PfMesh.ekey(3, 9): true}, seg)
		PfOps2.bevel_update(m, d, 0.1)
		m.invalidate()
		check(closed(m) and _oriented(m) and m.validate() == "", "%d segment(s): no holes, consistent winding" % seg)
