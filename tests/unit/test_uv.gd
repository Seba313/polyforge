## UV operator tests (headless): godot --headless --path . -s tests/unit/test_uv.gd
extends SceneTree

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfUvOps := preload("res://addons/polyforge/core/pf_uvops.gd")
const PfUv := preload("res://addons/polyforge/core/pf_uv.gd")

var fails := 0

func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		fails += 1

func all_faces(m) -> Dictionary:
	var d := {}
	for f in m.faces.size():
		d[f] = true
	return d

func in_unit(m, ch := 0) -> bool:
	for f in m.faces.size():
		for u in (m.uvs[f] if ch == 0 else m.uv2s[f]):
			if u.x < -1e-4 or u.y < -1e-4 or u.x > 1.0001 or u.y > 1.0001:
				return false
	return true

func ratios(m) -> Array:
	var out := []
	for f in m.faces.size():
		var a := PfUvOps._areas(m, 0, {f: true})
		if a.y > 1e-9:
			out.append(a.x / a.y)
	return out

func spread(r: Array) -> float:
	var mn: float = r.min()
	var mx: float = r.max()
	return (mx - mn) / maxf(mx, 1e-12)

func same_winding(m) -> bool:
	var sgn := 0
	for f in m.faces.size():
		var u: PackedVector2Array = m.uvs[f]
		var a := 0.0
		for k in u.size():
			a += u[k].cross(u[(k + 1) % u.size()])
		var s := 1 if a > 0.0 else -1
		if sgn == 0:
			sgn = s
		elif s != sgn:
			return false
	return true

func no_overlap(m, isl: Array) -> bool:
	for i in isl.size():
		for j in range(i + 1, isl.size()):
			var a: Rect2 = PfUvOps.island_bounds(m, 0, isl[i]).grow(-1e-4)
			var b: Rect2 = PfUvOps.island_bounds(m, 0, isl[j]).grow(-1e-4)
			if a.intersects(b):
				return false
	return true

func _init() -> void:
	print("== islands / reset")
	var g = PfPrim.grid(2, 2)
	check(PfUvOps.islands(g, 0, all_faces(g)).size() == 1, "grid default UVs: one island")
	PfUvOps.reset(g, 0, all_faces(g))
	check(PfUvOps.islands(g, 0, all_faces(g)).size() == 4, "Reset: every face its own 0..1 island")
	print("== unwrap (LSCM)")
	g = PfPrim.grid(4, 4)
	for f in g.faces.size():
		g.uvs[f].fill(Vector2.ZERO)
	PfUvOps.unwrap(g, 0, all_faces(g))
	check(in_unit(g) and spread(ratios(g)) < 0.02, "flat grid: undistorted, inside 0..1 (spread %.4f)" % spread(ratios(g)))
	check(same_winding(g), "consistent winding")
	var c = PfPrim.cube()
	for e in c.edges():
		c.seam_edges[e] = true
	PfUvOps.unwrap(c, 0, all_faces(c))
	var isl := PfUvOps.islands(c, 0, all_faces(c))
	check(isl.size() == 6 and in_unit(c) and no_overlap(c, isl), "cube with all seams: 6 packed islands, no overlap")
	check(spread(ratios(c)) < 0.02, "cube islands same scale")
	var aligned := true
	for i in isl:
		var r := PfUvOps.island_bounds(c, 0, i)
		aligned = aligned and absf(r.size.x * r.size.y - PfUvOps._areas(c, 0, i).x) < 1e-4
	check(aligned, "unwrapped square islands are axis-aligned (not rotated 45°)")
	var cyl = PfPrim.cylinder(16)
	for e in cyl.edges():
		var a: Vector3 = cyl.verts[e.x]
		var b: Vector3 = cyl.verts[e.y]
		if is_equal_approx(a.y, b.y) or (is_equal_approx(a.x, 1.0) and is_equal_approx(b.x, 1.0)):
			cyl.seam_edges[e] = true
	PfUvOps.unwrap(cyl, 0, all_faces(cyl))
	isl = PfUvOps.islands(cyl, 0, all_faces(cyl))
	check(isl.size() == 3, "cylinder (rim + one vertical seam): 3 islands (got %d)" % isl.size())
	var side := []
	for f in cyl.faces.size():
		if cyl.faces[f].size() == 4:
			var a2 := PfUvOps._areas(cyl, 0, {f: true})
			side.append(a2.x / a2.y)
	check(spread(side) < 0.05, "cylinder side opened flat (spread %.4f)" % spread(side))
	check(in_unit(cyl) and no_overlap(cyl, isl), "packed into 0..1 without overlap")
	print("== pins")
	g = PfPrim.grid(2, 1)
	var v0 := -1
	var v1 := -1
	for v in g.verts.size():
		if g.verts[v].is_equal_approx(Vector3(-1, 0, 1)):
			v0 = v
		if g.verts[v].is_equal_approx(Vector3(1, 0, 1)):
			v1 = v
	for f in g.faces.size():
		for k in g.faces[f].size():
			if g.faces[f][k] == v0:
				g.uvs[f][k] = Vector2(0.2, 0.2)
			if g.faces[f][k] == v1:
				g.uvs[f][k] = Vector2(0.8, 0.2)
	PfUvOps.unwrap(g, 0, all_faces(g), 0.0, {v0: true, v1: true})
	var kept := true
	for f in g.faces.size():
		for k in g.faces[f].size():
			if g.faces[f][k] == v0 and not g.uvs[f][k].is_equal_approx(Vector2(0.2, 0.2)):
				kept = false
	check(kept, "pinned vertices keep their UVs")
	print("== projections, pack, scale, density")
	c = PfPrim.cube()
	PfUvOps.smart_project(c, 0, all_faces(c))
	isl = PfUvOps.islands(c, 0, all_faces(c))
	check(isl.size() == 6 and in_unit(c) and no_overlap(c, isl), "Smart UV Project cube: 6 islands packed")
	check(spread(ratios(c)) < 0.02, "same scale")
	c = PfPrim.cube()
	PfUvOps.cube_project(c, 0, all_faces(c))
	check(in_unit(c), "Cube Projection (size 2) fills 0..1")
	var s = PfPrim.uv_sphere(16, 8)
	PfUvOps.wrap_project(s, 0, all_faces(s), true)
	var okv := true
	for f in s.faces.size():
		for u in s.uvs[f]:
			if u.y < -1e-4 or u.y > 1.0001:
				okv = false
	check(okv, "Sphere Projection: V in 0..1")
	c = PfPrim.box(Vector3(4, 1, 1), Vector3i.ONE)
	for e in c.edges():
		c.seam_edges[e] = true
	PfUvOps.unwrap(c, 0, all_faces(c), 256.0)
	check(is_equal_approx(PfUv.measured_uv_per_metre(c, 0), 1.0), "World-Scale unwrap: 256 px/m on 256 px texture = 1 UV/m")
	c.has_uv2 = false
	PfUvOps.smart_project(c, 1, all_faces(c))
	check(c.has_uv2 and in_unit(c, 1), "UV2 channel written, has_uv2 set")
	print("== stage 3B: lightmap pack, stitch, split")
	c = PfPrim.cylinder(12)
	PfUvOps.lightmap_pack(c, 1, all_faces(c), 0.02)
	isl = PfUvOps.islands(c, 1, all_faces(c))
	check(isl.size() == c.faces.size() and in_unit(c, 1) and no_overlap(c, isl), "Lightmap Pack: one island per face, 0..1, no overlap")
	c = PfPrim.cube()
	for e in c.edges():
		c.seam_edges[e] = true
	PfUvOps.unwrap(c, 0, all_faces(c))
	# two faces sharing an edge: select all their corners, stitch
	var e0: Vector2i = c.edges()[0]
	var two: PackedInt32Array = c.edge_faces(e0)
	var keys := {}
	for f in two:
		for k in c.faces[f].size():
			keys[Vector2i(f, k)] = true
	var moved: int = PfUvOps.stitch(c, 0, keys)
	var joined := true
	for v in [e0.x, e0.y]:
		var a: Vector2 = c.uvs[two[0]][c.corner_of(two[0], v)]
		var b: Vector2 = c.uvs[two[1]][c.corner_of(two[1], v)]
		joined = joined and a.is_equal_approx(b)
	check(moved >= 2 and joined, "Stitch joins UVs of a shared edge (%d verts)" % moved)
	keys = {Vector2i(0, 0): true, Vector2i(0, 1): true, Vector2i(0, 2): true, Vector2i(0, 3): true, Vector2i(1, 0): true}
	check(PfUvOps.split_selection(c, keys).size() == 4, "Split Selection keeps only fully selected faces")
	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)
