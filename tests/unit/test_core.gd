## Core unit tests (headless, no editor):
##   godot --headless --path . -s tests/unit/test_core.gd
extends SceneTree

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfUv := preload("res://addons/polyforge/core/pf_uv.gd")
const PfSelect := preload("res://addons/polyforge/core/pf_select.gd")
const PfBvh := preload("res://addons/polyforge/core/pf_bvh.gd")

var fails := 0

func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		fails += 1

func _init() -> void:
	_no_class_name()
	_primitives()
	_build_winding_and_normals()
	_storage()
	_triangulation()
	_selection()
	_bvh()
	_uv_correction()
	_world_uv()
	_godot_primitives()
	_keymap()
	_shapes()
	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)


func _no_class_name() -> void:
	print("== no global class names in the addon")
	var bad := []
	var stack := ["res://addons/polyforge"]
	while not stack.is_empty():
		var dir: String = stack.pop_back()
		for d in DirAccess.get_directories_at(dir):
			stack.append(dir + "/" + d)
		for f in DirAccess.get_files_at(dir):
			if f.ends_with(".gd"):
				var src := FileAccess.get_file_as_string(dir + "/" + f)
				for line in src.split("\n"):
					if line.strip_edges().begins_with("class_name"):
						bad.append(dir + "/" + f)
	check(bad.is_empty(), "no class_name anywhere %s" % [bad])


func _closed_and_outward(m, name: String) -> void:
	check(m.validate() == "", "%s valid (%s)" % [name, m.validate()])
	# Closed: every edge has exactly two faces.
	var open := 0
	for e in m.edges():
		if m.edge_faces(e).size() != 2:
			open += 1
	check(open == 0, "%s is closed (%d open edges)" % [name, open])
	# Outward: signed volume positive.
	var vol := 0.0
	for fi in m.faces.size():
		var f: PackedInt32Array = m.faces[fi]
		for k in range(1, f.size() - 1):
			vol += m.verts[f[0]].dot(m.verts[f[k]].cross(m.verts[f[k + 1]])) / 6.0
	check(vol > 0.0, "%s faces point outward (volume %.3f)" % [name, vol])


func _primitives() -> void:
	print("== primitives (Blender defaults)")
	var c = PfPrim.cube()
	check(c.verts.size() == 8 and c.faces.size() == 6, "cube: 8 verts, 6 quads")
	check(c.bounds().size.is_equal_approx(Vector3(2, 2, 2)), "cube is 2 m like Blender")
	_closed_and_outward(c, "cube")
	var cyl = PfPrim.cylinder()
	check(cyl.faces.size() == 34 and cyl.verts.size() == 64, "cylinder: 32 sides + 2 n-gon caps, 64 verts")
	_closed_and_outward(cyl, "cylinder")
	var cone = PfPrim.cone()
	check(cone.verts.size() == 33, "cone: 32 + apex")
	_closed_and_outward(cone, "cone")
	var s = PfPrim.uv_sphere()
	check(s.faces.size() == 32 * 16 and s.verts.size() == 32 * 15 + 2, "uv sphere 32x16")
	_closed_and_outward(s, "uv sphere")
	var ico = PfPrim.ico_sphere()
	check(ico.faces.size() == 80 and ico.verts.size() == 42, "ico sphere (2 subdivisions): 80 tris, 42 verts")
	_closed_and_outward(ico, "ico sphere")
	var t = PfPrim.torus()
	check(t.faces.size() == 48 * 12, "torus 48x12")
	_closed_and_outward(t, "torus")
	var g = PfPrim.grid()
	check(g.faces.size() == 100 and g.verts.size() == 121, "grid 10x10")
	check(g.face_normal(0).is_equal_approx(Vector3.UP), "grid faces +Y")
	var circ = PfPrim.circle()
	check(circ.faces.size() == 1 and circ.faces[0].size() == 32 and circ.face_normal(0).is_equal_approx(Vector3.UP), "circle: one 32-gon facing up")
	for kind in PfPrim.KINDS:
		check(PfPrim.create(kind) != null, "create('%s')" % kind)


func _build_winding_and_normals() -> void:
	print("== ArrayMesh build: Godot winding, normals, surfaces")
	var c = PfPrim.cube()
	var am := PfBuild.build(c)
	check(am.get_surface_count() == 1, "one surface for one material slot")
	var arr := am.surface_get_arrays(0)
	var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	check(idx.size() == 36, "12 triangles")
	check(pos.size() == 24, "flat cube: 24 vertices (split normals)")
	var ok := true
	for t in range(0, idx.size(), 3):
		var a := pos[idx[t]]
		var b := pos[idx[t + 1]]
		var cc := pos[idx[t + 2]]
		# Godot front face is clockwise: (b-a)x(c-a) points INTO the surface.
		if (b - a).cross(cc - a).dot(nrm[idx[t]]) >= 0.0:
			ok = false
	check(ok, "triangles wound clockwise (Godot front faces)")
	check(arr[Mesh.ARRAY_TANGENT] != null, "tangents generated")
	check(am.has_meta(PfMesh.META_KEY), "edit data stored as mesh metadata")
	# Smooth shading: a smooth UV sphere shares normals -> fewer vertices.
	var s = PfPrim.uv_sphere(16, 8)
	for fi in s.faces.size():
		s.face_smooth[fi] = 1
	var sm := PfBuild.build(s)
	var sp: PackedVector3Array = sm.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var sn: PackedVector3Array = sm.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	var radial := true
	for i in sp.size():
		if sn[i].dot(sp[i].normalized()) < 0.95:
			radial = false
	check(radial, "smooth sphere normals are radial")
	# Sharp edge splits smooth normals.
	var c2 = PfPrim.cube()
	for fi in c2.faces.size():
		c2.face_smooth[fi] = 1
	var cn := PfBuild.compute_corner_normals(c2)
	check(not (cn[0][0] as Vector3).is_equal_approx(c2.face_normal(0)), "smooth cube corners averaged")
	for e in c2.edges():
		c2.sharp_edges[e] = true
	cn = PfBuild.compute_corner_normals(c2)
	check((cn[0][0] as Vector3).is_equal_approx(c2.face_normal(0)), "all-sharp smooth cube = flat normals")
	# Materials -> surfaces.
	var c3 = PfPrim.cube()
	c3.materials = [StandardMaterial3D.new(), StandardMaterial3D.new()]
	c3.face_mat[0] = 1
	var am3 := PfBuild.build(c3)
	check(am3.get_surface_count() == 2 and am3.surface_get_material(1) == c3.materials[1], "material slots -> surfaces with materials")
	# Rebuilding into the same ArrayMesh keeps the resource.
	var same := PfBuild.build(c3, am3)
	check(same == am3, "rebuild in place reuses the ArrayMesh")
	# Hidden faces left out of a display build.
	var disp := PfBuild.build(c, null, true, {0: true}, false)
	check(disp.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == 30, "skip_faces drops faces (fast build, 5 quads)")


func _storage() -> void:
	print("== storage round trip")
	var c = PfPrim.cylinder(8)
	c.sharp_edges[PfMesh.ekey(0, 1)] = true
	c.seam_edges[PfMesh.ekey(1, 2)] = true
	c.world_uv = true
	c.texel_density = 512.0
	c.has_uv2 = true
	c.uv2s[3][1] = Vector2(0.25, 0.75)
	var d: Dictionary = c.to_dict()
	var c2 = PfMesh.new()
	check(c2.from_dict(d), "from_dict")
	check(c2.verts == c.verts and c2.faces.size() == c.faces.size(), "verts and faces")
	var same := true
	for fi in c.faces.size():
		if c.faces[fi] != c2.faces[fi] or c.uvs[fi] != c2.uvs[fi] or c.uv2s[fi] != c2.uv2s[fi]:
			same = false
	check(same, "face corners, UV1 and UV2 identical")
	check(c2.sharp_edges.has(PfMesh.ekey(0, 1)) and c2.seam_edges.has(PfMesh.ekey(1, 2)), "sharp + seam edges")
	check(c2.world_uv and c2.texel_density == 512.0, "World-Scale UV settings")
	for v in d.values():
		check(not (v is Object and not v is Resource), "no script objects in stored data")
	# Survives a .tres save/load without the addon scripts.
	var am := PfBuild.build(c)
	ResourceSaver.save(am, "user://pf_store_test.tres")
	var txt := FileAccess.get_file_as_string("user://pf_store_test.tres")
	check(not txt.contains("res://addons/polyforge"), "saved mesh references no addon script")
	var back: ArrayMesh = ResourceLoader.load("user://pf_store_test.tres", "", ResourceLoader.CACHE_MODE_IGNORE)
	var c3 = PfMesh.new()
	check(back != null and c3.from_dict(back.get_meta(PfMesh.META_KEY)) and c3.faces.size() == c.faces.size(), "metadata survives save/load")


func _poly_area(pts: Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p: Vector3 = pts[i]
		var q: Vector3 = pts[(i + 1) % pts.size()]
		a += p.x * (-q.z) - q.x * (-p.z)
	return absf(a) * 0.5


func _triangulation() -> void:
	print("== n-gon triangulation (concave)")
	# L-shape on XZ, CCW seen from +Y.
	var m = PfMesh.new()
	var pts := [Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(2, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, -2), Vector3(0, 0, -2)]
	var f := PackedInt32Array()
	for p in pts:
		f.append(m.add_vertex(p))
	m.add_face(f)
	check(m.face_normal(0).is_equal_approx(Vector3.UP), "L-shape faces up")
	var tris := PfBuild.triangulate(m, 0)
	check(tris.size() == 12, "6-gon -> 4 triangles")
	var area := 0.0
	var all_ccw := true
	for t in range(0, tris.size(), 3):
		var a: Vector3 = pts[tris[t]]
		var b: Vector3 = pts[tris[t + 1]]
		var c: Vector3 = pts[tris[t + 2]]
		var cr := (b - a).cross(c - a)
		area += cr.length() * 0.5
		if cr.dot(Vector3.UP) <= 0.0:
			all_ccw = false
	check(is_equal_approx(area, 3.0), "triangles cover exactly the L area (%.3f)" % area)
	check(all_ccw, "every triangle keeps the face orientation")


func _selection() -> void:
	print("== selection topology (loops, rings, linked, grow)")
	var g = PfPrim.grid(4, 4)
	# Horizontal edge in the middle of the grid: loop runs across the grid.
	var mid := -1
	var e0 := Vector2i(-1, -1)
	for e in g.edges():
		var a: Vector3 = g.verts[e.x]
		var b: Vector3 = g.verts[e.y]
		if is_equal_approx(a.z, 0.0) and is_equal_approx(b.z, 0.0) and is_equal_approx(a.x + b.x, 0.5):
			e0 = e
	check(e0.x >= 0, "found an interior edge")
	var loop: Array[Vector2i] = PfSelect.edge_loop(g, e0)
	check(loop.size() == 4, "edge loop crosses the 4x4 grid (4 edges, got %d)" % loop.size())
	var ring: Dictionary = PfSelect.edge_ring(g, e0)
	check(ring["edges"].size() == 5 and ring["faces"].size() == 4, "edge ring: 5 edges, 4 faces")
	var cyl = PfPrim.cylinder(8)
	var side_bottom := Vector2i(-1, -1)
	for e in cyl.edges():
		if cyl.verts[e.x].y < 0 and cyl.verts[e.y].y < 0:
			side_bottom = e
			break
	check(PfSelect.edge_loop(cyl, side_bottom).size() == 8, "cylinder bottom rim loop = 8 edges (boundary between side and cap)")
	var two = PfPrim.cube()
	two.append_mesh(PfPrim.cube(), Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)))
	check(PfSelect.linked_faces(two, {0: true}).size() == 6, "linked: one cube of two")
	var grown: Dictionary = PfSelect.grow_verts(g, {12: true})
	check(grown.size() == 9, "grow from a middle vertex -> 3x3 vertices (got %d)" % grown.size())
	check(PfSelect.shrink_verts(g, grown).size() == 1, "shrink back -> 1")
	var vsel := {}
	for v in g.faces[0]:
		vsel[v] = true
	check(PfSelect.verts_to_faces(g, vsel).size() == 1 and PfSelect.verts_to_edges(g, vsel).size() == 4, "vertex -> edge/face mode conversion")


func _bvh() -> void:
	print("== BVH ray casts")
	var s = PfPrim.uv_sphere()
	var bvh = PfBvh.new()
	bvh.build(s)
	check(bvh.triangle_count() == 32 * 2 + 32 * 14 * 2, "all triangles in the BVH")
	var hit: Dictionary = bvh.raycast(Vector3(0, 0, 5), Vector3(0, 0, -1))
	check(not hit.is_empty() and absf(hit["point"].z - 1.0) < 0.02, "ray hits the front of the sphere")
	check(bvh.occluded(Vector3(0, 0, 5), Vector3(0, 0, -1)), "back point occluded")
	check(not bvh.occluded(Vector3(0, 0, 5), Vector3(0, 0, 1.0)), "front point visible")


func _uv_correction() -> void:
	print("== UV correction (Correct Face Attributes)")
	var c = PfPrim.cube()
	# Move the top front edge (+Y, +Z) by +1 on Z: top face stretches, front face moves.
	var moved := {}
	for v in c.verts.size():
		if c.verts[v].y > 0 and c.verts[v].z > 0:
			moved[v] = true
	var top := -1
	for fi in c.faces.size():
		if c.face_normal(fi).is_equal_approx(Vector3.UP):
			top = fi
	var d0 := PfUv.measured_uv_per_metre(c, top)
	var recs := PfUv.capture(c, moved)
	for v in moved:
		c.verts[v] += Vector3(0, 0, 1)
	PfUv.apply(c, recs)
	check(is_equal_approx(PfUv.measured_uv_per_metre(c, top), d0), "top face keeps its texel density")
	# Without correction the same move stretches.
	var c2 = PfPrim.cube()
	for v in moved:
		c2.verts[v] += Vector3(0, 0, 1)
	check(not is_equal_approx(PfUv.measured_uv_per_metre(c2, top), d0), "(control) without correction it stretches")


func _world_uv() -> void:
	print("== World-Scale UV (optional mode)")
	var c = PfPrim.box(Vector3(4, 1, 1), Vector3i.ONE)
	PfUv.cube_project_world(c, 256.0)
	var front := -1
	for fi in c.faces.size():
		if c.face_normal(fi).is_equal_approx(Vector3.BACK):
			front = fi
	var uv: PackedVector2Array = c.uvs[front]
	var w := 0.0
	for a in uv:
		for b in uv:
			w = maxf(w, absf(a.x - b.x))
	check(is_equal_approx(w, 4.0), "256 px/m, 256 px texture: 4 m wide face spans 4 tiles (%.3f)" % w)
	var mat := StandardMaterial3D.new()
	var img := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	mat.albedo_texture = ImageTexture.create_from_image(img)
	c.materials = [mat]
	PfUv.cube_project_world(c, 256.0)
	uv = c.uvs[front]
	w = 0.0
	for a in uv:
		for b in uv:
			w = maxf(w, absf(a.x - b.x))
	check(is_equal_approx(w, 2.0), "512 px texture: same face spans 2 tiles (256 px = 1 m rule)")
	PfUv.cube_project_world(c, 128.0)
	check(is_equal_approx(PfUv.measured_uv_per_metre(c, front), 0.25), "128 px/m on 512 px texture = 0.25 UV/m")
	# Scaling the whole object in World-Scale mode keeps the density.
	var c3 = PfPrim.cube()
	PfUv.cube_project_world(c3, 256.0)
	var d0 := PfUv.measured_uv_per_metre(c3, 0)
	var all := {}
	for v in c3.verts.size():
		all[v] = true
	var recs := PfUv.capture(c3, all, true)
	for v in c3.verts.size():
		c3.verts[v] *= 2.0
	PfUv.apply(c3, recs, Vector3.ZERO)
	check(is_equal_approx(PfUv.measured_uv_per_metre(c3, 0), d0), "S 2 on the whole object: density unchanged (tiles added)")


func _godot_primitives() -> void:
	print("== Godot PrimitiveMesh -> Polyforge")
	var bm := BoxMesh.new()
	bm.size = Vector3(1, 2, 3)
	bm.subdivide_width = 1
	var m = PfPrim.from_godot(bm)
	check(m != null and m.bounds().size.is_equal_approx(Vector3(1, 2, 3)), "BoxMesh size kept")
	check(m.faces.size() == 2 * 1 + 2 * 1 + 2 * 2 + 2 * 2 - 2, "BoxMesh subdivide_width=1 -> 10 faces (got %d)" % m.faces.size())
	_closed_and_outward(m, "converted box")
	var cm := CylinderMesh.new()
	cm.radial_segments = 16
	cm.rings = 0
	m = PfPrim.from_godot(cm)
	check(m != null and m.faces.size() == 18, "CylinderMesh 16 segments -> 16 sides + 2 caps")
	check(m.face_smooth[0] == 1 and not m.sharp_edges.is_empty(), "smooth sides, sharp cap rims (like Godot)")
	_closed_and_outward(m, "converted cylinder")
	var sm := SphereMesh.new()
	m = PfPrim.from_godot(sm)
	check(m != null and is_equal_approx(m.bounds().size.y, 1.0), "SphereMesh radius 0.5 height 1")
	var pm := PlaneMesh.new()
	pm.orientation = PlaneMesh.FACE_Z
	m = PfPrim.from_godot(pm)
	check(m != null and m.face_normal(0).is_equal_approx(Vector3.BACK), "PlaneMesh FACE_Z faces +Z")
	pm.orientation = PlaneMesh.FACE_X
	m = PfPrim.from_godot(pm)
	check(m != null and m.face_normal(0).is_equal_approx(Vector3.RIGHT), "PlaneMesh FACE_X faces +X")
	var tm := TorusMesh.new()
	check(PfPrim.from_godot(tm) != null, "TorusMesh")
	var mat := StandardMaterial3D.new()
	bm.material = mat
	check(PfPrim.from_godot(bm).materials == [mat], "PrimitiveMesh material -> slot 0")
	check(not PfPrim.supports(CapsuleMesh.new()), "CapsuleMesh reported unsupported")


func _keymap() -> void:
	print("== keymap: every shortcut text parses")
	const PfKeymap := preload("res://addons/polyforge/editor/pf_keymap.gd")
	var bad := []
	for table in [PfKeymap.GLOBAL, PfKeymap.EDIT, PfKeymap.OBJECT]:
		for action in table:
			for t in table[action]:
				if PfKeymap.parse(t)["code"] == KEY_NONE:
					bad.append(t)
	check(bad.is_empty(), "all shortcut names valid %s" % [bad])
	var ev := InputEventKey.new()
	ev.keycode = KEY_KP_ADD
	ev.ctrl_pressed = true
	check(PfKeymap.find(PfKeymap.EDIT, ev) == "select_more", "Ctrl+Numpad+ -> select_more")
	ev = InputEventKey.new()
	ev.keycode = KEY_TAB
	ev.ctrl_pressed = true
	check(PfKeymap.find(PfKeymap.GLOBAL, ev) == "", "Ctrl+Tab is not Tab (Godot scene switching stays)")


func _shapes() -> void:
	print("== collision shapes (convex / concave) <-> edit mesh")
	const PfShape := preload("res://addons/polyforge/core/pf_shape.gd")
	const PfHull := preload("res://addons/polyforge/core/pf_hull.gd")
	# Concave from a Godot box trimesh: 12 triangles -> 8 verts, 6 quads.
	var bm := BoxMesh.new()
	var cs: ConcavePolygonShape3D = bm.create_trimesh_shape()
	var m = PfShape.read(cs)
	check(m != null and m.verts.size() == 8 and m.faces.size() == 6, "trimesh box -> 8 vertices, 6 quads (got %d / %d)" % [m.verts.size() if m else -1, m.faces.size() if m else -1])
	_closed_and_outward(m, "concave box")
	var f2 := PfShape.to_faces(m)
	check(f2.size() == 36, "back to 12 triangles")
	# Same winding as Godot's own trimesh: normals of first triangles agree.
	var orig := cs.get_faces()
	var area_o := 0.0
	var area_n := 0.0
	for t in range(0, 36, 3):
		area_o += (orig[t + 1] - orig[t]).cross(orig[t + 2] - orig[t]).length()
		area_n += (f2[t + 1] - f2[t]).cross(f2[t + 2] - f2[t]).length()
	check(is_equal_approx(area_o, area_n), "same surface area")
	var vol := 0.0
	for t in range(0, 36, 3):
		vol += f2[t].dot(f2[t + 1].cross(f2[t + 2])) / 6.0
	var vol_o := 0.0
	for t in range(0, 36, 3):
		vol_o += orig[t].dot(orig[t + 1].cross(orig[t + 2])) / 6.0
	check(signf(vol) == signf(vol_o), "winding matches Godot's trimesh")
	# Edit + write + read back keeps quads via metadata.
	m.verts[0] += Vector3(0, 0.25, 0)
	PfShape.write(cs, m)
	var m2 = PfShape.read(cs)
	check(m2.faces.size() == 6 and m2.verts[0].is_equal_approx(m.verts[0]), "write/read keeps the quads (metadata)")
	cs.set_faces(PackedVector3Array())
	cs.set_faces(bm.create_trimesh_shape().get_faces())
	var fresh = PfShape.read(cs)
	var has_moved := false
	for v in fresh.verts:
		if v.is_equal_approx(m.verts[0]):
			has_moved = true
	check(not has_moved and fresh.verts.size() == 8, "shape changed elsewhere -> stale metadata ignored, rebuilt from the shape")
	# Convex.
	var cvx: ConvexPolygonShape3D = BoxMesh.new().create_convex_shape()
	var mc = PfShape.read(cvx)
	check(mc != null and mc.faces.size() == 6, "convex box hull -> 6 faces (got %d)" % (mc.faces.size() if mc else -1))
	_closed_and_outward(mc, "convex box")
	var cyl: ConvexPolygonShape3D = CylinderMesh.new().create_convex_shape()
	var my = PfShape.read(cyl)
	check(my != null, "convex cylinder hull")
	_closed_and_outward(my, "convex cylinder")
	var caps := 0
	for f in my.faces:
		if f.size() > 4:
			caps += 1
	check(caps == 2, "cylinder caps joined into 2 n-gons")
	# Re-hull drops a vertex pushed inside.
	var r: Dictionary = PfShape.rehull(mc)
	check(r["mesh"].verts.size() == 8, "rehull of an unchanged box keeps 8 vertices")
	mc.verts[0] = Vector3.ZERO
	r = PfShape.rehull(mc)
	check(r["mesh"].verts.size() == 7 and not r["remap"].has(0), "vertex moved inside is dropped by the hull")
	var rnd := PackedVector3Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 200:
		rnd.append(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)))
	var mr = PfShape.from_points(rnd)
	_closed_and_outward(mr, "hull of 200 random points")
	var convex := true
	for fi in mr.faces.size():
		var n: Vector3 = mr.face_normal(fi)
		var p0: Vector3 = mr.verts[mr.faces[fi][0]]
		for p in rnd:
			if (p - p0).dot(n) > 1e-5:
				convex = false
	check(convex, "every point lies inside the hull")
	check(PfHull.hull(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP, Vector3(1, 1, 0)])).is_empty(), "coplanar points -> no hull")
	var inner_first := PackedVector3Array([Vector3.ZERO])
	for c in BoxMesh.new().create_convex_shape().points:
		inner_first.append(c)
	var used_inner := false
	for t in PfHull.hull(inner_first):
		if 0 in t:
			used_inner = true
	check(not used_inner, "interior point given first is not part of the hull")
	# A point lying inside a flat face (on the cap of a box) is dropped too.
	var on_face := BoxMesh.new().create_convex_shape().points
	on_face.append(Vector3(0.1, 0.5, 0.1))
	var mf = PfShape.from_points(on_face)
	check(mf.verts.size() == 8 and mf.faces.size() == 6, "point inside a flat hull face is dropped (got %d verts)" % mf.verts.size())
