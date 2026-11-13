## PfPrimitives — Shift+A primitives with Blender's defaults and Blender-like
## default UVs, plus conversion of Godot's PrimitiveMesh resources.
##
## Godot is Y-up: Blender's "up" (Z) becomes +Y, so cylinders, cones and the
## grid stand / lie the way a Blender user expects.
@tool
extends RefCounted

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")

const KINDS := ["cube", "plane", "circle", "uv_sphere", "ico_sphere", "cylinder", "cone", "torus", "grid"]
const LABELS := {
	"cube": "Cube", "plane": "Plane", "circle": "Circle", "uv_sphere": "UV Sphere",
	"ico_sphere": "Ico Sphere", "cylinder": "Cylinder", "cone": "Cone", "torus": "Torus", "grid": "Grid",
}


static func create(kind: String):
	match kind:
		"cube": return cube()
		"plane": return plane()
		"circle": return circle()
		"uv_sphere": return uv_sphere()
		"ico_sphere": return ico_sphere()
		"cylinder": return cylinder()
		"cone": return cone()
		"torus": return torus()
		"grid": return grid()
	return null


# ==============================================================================
# Box / plane / grid
# ==============================================================================

## Blender's default cube UV layout (cross): cell = Rect2 in UV space.
const _CUBE_CELLS := {
	"+Z": Rect2(0.375, 0.50, 0.25, 0.25),   # front
	"+Y": Rect2(0.375, 0.25, 0.25, 0.25),   # top
	"-Z": Rect2(0.375, 0.00, 0.25, 0.25),   # back
	"-Y": Rect2(0.375, 0.75, 0.25, 0.25),   # bottom
	"-X": Rect2(0.125, 0.50, 0.25, 0.25),   # left
	"+X": Rect2(0.625, 0.50, 0.25, 0.25),   # right
}

static func cube(size := 2.0):
	return box(Vector3.ONE * size, Vector3i.ONE)

## Box with `seg` faces along each axis. Sides: origin corner, u axis, v axis
## (u x v = outward normal so corners come out CCW from outside).
static func box(size: Vector3, seg: Vector3i):
	var m = PfMesh.new()
	var h := size * 0.5
	var sides := [
		["+X", Vector3(h.x, -h.y, h.z), Vector3(0, 0, -size.z), Vector3(0, size.y, 0), seg.z, seg.y],
		["-X", Vector3(-h.x, -h.y, -h.z), Vector3(0, 0, size.z), Vector3(0, size.y, 0), seg.z, seg.y],
		["+Z", Vector3(-h.x, -h.y, h.z), Vector3(size.x, 0, 0), Vector3(0, size.y, 0), seg.x, seg.y],
		["-Z", Vector3(h.x, -h.y, -h.z), Vector3(-size.x, 0, 0), Vector3(0, size.y, 0), seg.x, seg.y],
		["+Y", Vector3(-h.x, h.y, h.z), Vector3(size.x, 0, 0), Vector3(0, 0, -size.z), seg.x, seg.z],
		["-Y", Vector3(-h.x, -h.y, -h.z), Vector3(size.x, 0, 0), Vector3(0, 0, size.z), seg.x, seg.z],
	]
	var lookup := {}
	for s in sides:
		_grid_side(m, lookup, s[1], s[2], s[3], maxi(s[4], 1), maxi(s[5], 1), _CUBE_CELLS[s[0]])
	return m

static func plane(size := 2.0):
	return grid(1, 1, size)

## Blender grid: x/y subdivisions = number of faces per side, lying on XZ,
## facing +Y. UV 0..1.
static func grid(x_sub := 10, y_sub := 10, size := 2.0):
	var m = PfMesh.new()
	var h := size * 0.5
	_grid_side(m, {}, Vector3(-h, 0, h), Vector3(size, 0, 0), Vector3(0, 0, -size), maxi(x_sub, 1), maxi(y_sub, 1), Rect2(0, 0, 1, 1))
	return m

static func _grid_side(m, lookup: Dictionary, o: Vector3, u: Vector3, v: Vector3, nu: int, nv: int, cell: Rect2) -> void:
	var idx := []
	for j in nv + 1:
		var row := []
		for i in nu + 1:
			row.append(_vid(m, lookup, o + u * (float(i) / nu) + v * (float(j) / nv)))
		idx.append(row)
	for j in nv:
		for i in nu:
			var f := PackedInt32Array([idx[j][i], idx[j][i + 1], idx[j + 1][i + 1], idx[j + 1][i]])
			var uv := PackedVector2Array()
			for c in [[i, j], [i + 1, j], [i + 1, j + 1], [i, j + 1]]:
				var s := float(c[0]) / nu
				var t := float(c[1]) / nv
				uv.append(cell.position + Vector2(s, 1.0 - t) * cell.size)
			m.add_face(f, uv)

## Shared vertex by (snapped) position, so box sides weld along their edges.
static func _vid(m, lookup: Dictionary, p: Vector3) -> int:
	var key := p.snapped(Vector3.ONE * 1e-5)
	if lookup.has(key):
		return lookup[key]
	var i: int = m.add_vertex(p)
	lookup[key] = i
	return i


# ==============================================================================
# Circle / cylinder / cone
# ==============================================================================

static func _ring_point(r: float, y: float, i: int, n: int) -> Vector3:
	var a := TAU * float(i) / n
	return Vector3(r * cos(a), y, -r * sin(a))

## Circle filled with an n-gon (Blender's "Fill Type: N-Gon").
static func circle(verts := 32, radius := 1.0):
	var m = PfMesh.new()
	var f := PackedInt32Array()
	var uv := PackedVector2Array()
	for i in verts:
		f.append(m.add_vertex(_ring_point(radius, 0.0, i, verts)))
		var a := TAU * float(i) / verts
		uv.append(Vector2(0.5 + 0.5 * cos(a), 0.5 - 0.5 * sin(a)))
	m.add_face(f, uv)
	return m

static func cylinder(verts := 32, radius := 1.0, depth := 2.0):
	return _cyl(verts, radius, radius, depth, 1, true, true, false)

static func cone(verts := 32, radius1 := 1.0, radius2 := 0.0, depth := 2.0):
	return _cyl(verts, radius1, radius2, depth, 1, true, radius2 > 0.0, false)

## Side strip in the lower half of UV space, caps as discs in the upper half
## (like Blender's cylinder). rb/rt = bottom/top radius; rt == 0 -> apex.
static func _cyl(n: int, rb: float, rt: float, depth: float, rings: int, cap_bottom: bool, cap_top: bool, smooth_sides: bool):
	var m = PfMesh.new()
	n = maxi(n, 3)
	rings = maxi(rings, 1)
	var h := depth * 0.5
	var levels := []   # rows of vertex ids, bottom -> top
	var apex := -1
	for r in rings + 1:
		var t := float(r) / rings
		var rad := lerpf(rb, rt, t)
		var y := lerpf(-h, h, t)
		if r == rings and rt <= 0.0:
			apex = m.add_vertex(Vector3(0, h, 0))
			break
		var row := []
		for i in n:
			row.append(m.add_vertex(_ring_point(rad, y, i, n)))
		levels.append(row)
	for r in levels.size() - 1:
		for i in n:
			var i2 := (i + 1) % n
			var f := PackedInt32Array([levels[r][i], levels[r][i2], levels[r + 1][i2], levels[r + 1][i]])
			var v0 := 1.0 - 0.5 * float(r) / rings
			var v1 := 1.0 - 0.5 * float(r + 1) / rings
			var u0 := float(i) / n
			var u1 := float(i + 1) / n
			m.add_face(f, PackedVector2Array([Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1)]), 0, smooth_sides)
	if apex >= 0:
		var last: Array = levels[levels.size() - 1]
		var vb := 1.0 - 0.5 * float(rings - 1) / rings
		for i in n:
			var i2 := (i + 1) % n
			var um := (float(i) + 0.5) / n
			m.add_face(PackedInt32Array([last[i], last[i2], apex]),
				PackedVector2Array([Vector2(float(i) / n, vb), Vector2(float(i + 1) / n, vb), Vector2(um, 0.5)]), 0, smooth_sides)
	if cap_top and apex < 0:
		var top: Array = levels[levels.size() - 1]
		var f := PackedInt32Array()
		var uv := PackedVector2Array()
		for i in n:
			f.append(top[i])
			var a := TAU * float(i) / n
			uv.append(Vector2(0.25 + 0.24 * cos(a), 0.25 - 0.24 * sin(a)))
		m.add_face(f, uv)
	if cap_bottom:
		var bot: Array = levels[0]
		var f := PackedInt32Array()
		var uv := PackedVector2Array()
		for i in range(n - 1, -1, -1):
			f.append(bot[i])
			var a := TAU * float(i) / n
			uv.append(Vector2(0.75 + 0.24 * cos(a), 0.25 + 0.24 * sin(a)))
		m.add_face(f, uv)
	if smooth_sides:
		_mark_cap_edges_sharp(m)
	return m

## Smooth sides + flat caps: the cap rims are sharp edges.
static func _mark_cap_edges_sharp(m) -> void:
	for fi in m.faces.size():
		if m.face_smooth[fi] != 0:
			continue
		for e in m.face_edges(fi):
			m.sharp_edges[e] = true


# ==============================================================================
# Spheres / torus
# ==============================================================================

static func uv_sphere(segments := 32, rings := 16, radius := 1.0, smooth := false, height := -1.0):
	var m = PfMesh.new()
	segments = maxi(segments, 3)
	rings = maxi(rings, 2)
	var ys := (height * 0.5 / radius) if height > 0.0 else 1.0
	var top: int = m.add_vertex(Vector3(0, radius * ys, 0))
	var ring_ids := []
	for k in range(1, rings):
		var phi := PI * float(k) / rings
		var row := []
		for i in segments:
			var a := TAU * float(i) / segments
			row.append(m.add_vertex(Vector3(radius * sin(phi) * cos(a), radius * cos(phi) * ys, -radius * sin(phi) * sin(a))))
		ring_ids.append(row)
	var bottom: int = m.add_vertex(Vector3(0, -radius * ys, 0))
	for i in segments:
		var i2 := (i + 1) % segments
		var u0 := float(i) / segments
		var u1 := float(i + 1) / segments
		var v1 := 1.0 / rings
		m.add_face(PackedInt32Array([ring_ids[0][i], ring_ids[0][i2], top]),
			PackedVector2Array([Vector2(u0, v1), Vector2(u1, v1), Vector2((u0 + u1) * 0.5, 0.0)]), 0, smooth)
	for k in rings - 2:
		for i in segments:
			var i2 := (i + 1) % segments
			var u0 := float(i) / segments
			var u1 := float(i + 1) / segments
			var vt := float(k + 1) / rings
			var vb := float(k + 2) / rings
			m.add_face(PackedInt32Array([ring_ids[k + 1][i], ring_ids[k + 1][i2], ring_ids[k][i2], ring_ids[k][i]]),
				PackedVector2Array([Vector2(u0, vb), Vector2(u1, vb), Vector2(u1, vt), Vector2(u0, vt)]), 0, smooth)
	var last: Array = ring_ids[ring_ids.size() - 1]
	for i in segments:
		var i2 := (i + 1) % segments
		var u0 := float(i) / segments
		var u1 := float(i + 1) / segments
		var vt := float(rings - 1) / rings
		m.add_face(PackedInt32Array([bottom, last[i2], last[i]]),
			PackedVector2Array([Vector2((u0 + u1) * 0.5, 1.0), Vector2(u1, vt), Vector2(u0, vt)]), 0, smooth)
	return m

static func ico_sphere(subdivisions := 2, radius := 1.0):
	var t := (1.0 + sqrt(5.0)) / 2.0
	var pts := [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	var tris := [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
	]
	var vp: Array = []
	for p in pts:
		vp.append((p as Vector3).normalized())
	for s in maxi(subdivisions - 1, 0):
		var mid := {}
		var nt := []
		for tr in tris:
			var m3 := []
			for k in 3:
				var a: int = tr[k]
				var b: int = tr[(k + 1) % 3]
				var key := Vector2i(mini(a, b), maxi(a, b))
				if not mid.has(key):
					vp.append(((vp[a] as Vector3) + (vp[b] as Vector3)).normalized())
					mid[key] = vp.size() - 1
				m3.append(mid[key])
			nt.append([tr[0], m3[0], m3[2]])
			nt.append([tr[1], m3[1], m3[0]])
			nt.append([tr[2], m3[2], m3[1]])
			nt.append([m3[0], m3[1], m3[2]])
		tris = nt
	var m = PfMesh.new()
	for p in vp:
		m.add_vertex((p as Vector3) * radius)
	for tr in tris:
		var f := PackedInt32Array(tr)
		var a: Vector3 = m.verts[f[0]]
		var b: Vector3 = m.verts[f[1]]
		var c: Vector3 = m.verts[f[2]]
		if (b - a).cross(c - a).dot(a + b + c) < 0.0:
			f = PackedInt32Array([f[0], f[2], f[1]])
		var uv := PackedVector2Array()
		for v in f:
			var p: Vector3 = m.verts[v] / radius
			uv.append(Vector2(0.5 + atan2(-p.z, p.x) / TAU, acos(clampf(p.y, -1.0, 1.0)) / PI))
		# Seam fix: keep a triangle's U values on one side of the wrap.
		var umax := maxf(uv[0].x, maxf(uv[1].x, uv[2].x))
		for k in 3:
			if umax - uv[k].x > 0.5:
				uv[k].x += 1.0
		m.add_face(f, uv)
	return m

static func torus(major_segments := 48, minor_segments := 12, major_radius := 1.0, minor_radius := 0.25, smooth := false):
	var m = PfMesh.new()
	var ids := []
	for i in major_segments:
		var a := TAU * float(i) / major_segments
		var row := []
		for j in minor_segments:
			var b := TAU * float(j) / minor_segments
			var rr := major_radius + minor_radius * cos(b)
			row.append(m.add_vertex(Vector3(rr * cos(a), minor_radius * sin(b), -rr * sin(a))))
		ids.append(row)
	for i in major_segments:
		var i2 := (i + 1) % major_segments
		for j in minor_segments:
			var j2 := (j + 1) % minor_segments
			# Corner order: along the major ring (i -> i2) then up the tube.
			var f := PackedInt32Array([ids[i][j], ids[i2][j], ids[i2][j2], ids[i][j2]])
			var u0 := float(i) / major_segments
			var u1 := float(i + 1) / major_segments
			var v0 := 1.0 - float(j) / minor_segments
			var v1 := 1.0 - float(j + 1) / minor_segments
			var uv := PackedVector2Array([Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1), Vector2(u0, v1)])
			var fi: int = m.add_face(f, uv, 0, smooth)
			# Outward = away from the tube centre.
			var a := TAU * (float(i) + 0.5) / major_segments
			var tube_c := Vector3(major_radius * cos(a), 0, -major_radius * sin(a))
			if m.face_normal(fi).dot(m.face_center(fi) - tube_c) < 0.0:
				m.faces[fi] = PackedInt32Array([f[0], f[3], f[2], f[1]])
				m.uvs[fi] = PackedVector2Array([uv[0], uv[3], uv[2], uv[1]])
	return m


# ==============================================================================
# Godot PrimitiveMesh -> PfMesh
# ==============================================================================

static func supports(mesh: Mesh) -> bool:
	return mesh is BoxMesh or mesh is PlaneMesh or mesh is CylinderMesh or mesh is SphereMesh \
		or mesh is TorusMesh or mesh is PrismMesh

## Builds the equivalent Polyforge primitive from the resource's parameters
## (not from its triangles). Returns null for unsupported types.
static func from_godot(mesh: Mesh):
	var m = null
	if mesh is BoxMesh:
		var b := mesh as BoxMesh
		m = box(b.size, Vector3i(b.subdivide_width + 1, b.subdivide_height + 1, b.subdivide_depth + 1))
	elif mesh is PlaneMesh:   # QuadMesh is a PlaneMesh too
		var p := mesh as PlaneMesh
		m = PfMesh.new()
		var g = grid(p.subdivide_width + 1, p.subdivide_depth + 1, 1.0)
		# The grid faces +Y with its X/Z extents = size.x / size.y.
		var xf := Transform3D(Basis.from_scale(Vector3(p.size.x, 1, p.size.y)), Vector3.ZERO)
		match p.orientation:
			PlaneMesh.FACE_X:
				# +Y -> +X (rotate -90 deg about Z); extents: Y = size.y, Z = size.x.
				xf = Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3.ZERO) \
					* Transform3D(Basis.from_scale(Vector3(p.size.y, 1, p.size.x)), Vector3.ZERO)
			PlaneMesh.FACE_Z:
				# +Y -> +Z (rotate +90 deg about X); extents: X = size.x, Y = size.y.
				xf = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO) * xf
		xf.origin = p.center_offset
		m.append_mesh(g, xf)
	elif mesh is CylinderMesh:
		var c := mesh as CylinderMesh
		m = _cyl(c.radial_segments, c.bottom_radius, c.top_radius, c.height, c.rings + 1, c.cap_bottom, c.cap_top and c.top_radius > 0.0, true)
	elif mesh is SphereMesh:
		var s := mesh as SphereMesh
		m = uv_sphere(s.radial_segments, maxi(s.rings, 2), s.radius, true, s.height)
	elif mesh is TorusMesh:
		var t := mesh as TorusMesh
		var major := (t.inner_radius + t.outer_radius) * 0.5
		var minor := absf(t.outer_radius - t.inner_radius) * 0.5
		m = torus(t.rings, t.ring_segments, major, minor, true)
	elif mesh is PrismMesh:
		m = _prism(mesh as PrismMesh)
	if m != null and mesh is PrimitiveMesh and (mesh as PrimitiveMesh).material != null:
		m.materials = [(mesh as PrimitiveMesh).material]
	return m

static func _prism(p: PrismMesh):
	var m = PfMesh.new()
	var h := p.size * 0.5
	var apex_x := lerpf(-h.x, h.x, p.left_to_right)
	var a: int = m.add_vertex(Vector3(-h.x, -h.y, h.z))
	var b: int = m.add_vertex(Vector3(h.x, -h.y, h.z))
	var c: int = m.add_vertex(Vector3(apex_x, h.y, h.z))
	var d: int = m.add_vertex(Vector3(-h.x, -h.y, -h.z))
	var e: int = m.add_vertex(Vector3(h.x, -h.y, -h.z))
	var f: int = m.add_vertex(Vector3(apex_x, h.y, -h.z))
	var t := p.left_to_right
	m.add_face(PackedInt32Array([a, b, c]), PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(t, 0)]))
	m.add_face(PackedInt32Array([e, d, f]), PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1.0 - t, 0)]))
	m.add_face(PackedInt32Array([b, e, f, c]), PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]))
	m.add_face(PackedInt32Array([d, a, c, f]), PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]))
	m.add_face(PackedInt32Array([d, e, b, a]), PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]))
	return m


# ==============================================================================
# Parameters (Adjust Last Operation)
# ==============================================================================

## Editable parameters per primitive: [key, label, type, default, min, max].
const PARAMS := {
	"cube": [["size", "Size", "float", 2.0, 0.001, 1000.0]],
	"plane": [["size", "Size", "float", 2.0, 0.001, 1000.0]],
	"circle": [["verts", "Vertices", "int", 32, 3, 500], ["radius", "Radius", "float", 1.0, 0.001, 1000.0]],
	"uv_sphere": [["segments", "Segments", "int", 32, 3, 500], ["rings", "Rings", "int", 16, 3, 500], ["radius", "Radius", "float", 1.0, 0.001, 1000.0]],
	"ico_sphere": [["subdivisions", "Subdivisions", "int", 2, 1, 6], ["radius", "Radius", "float", 1.0, 0.001, 1000.0]],
	"cylinder": [["verts", "Vertices", "int", 32, 3, 500], ["radius", "Radius", "float", 1.0, 0.001, 1000.0], ["depth", "Depth", "float", 2.0, 0.001, 1000.0]],
	"cone": [["verts", "Vertices", "int", 32, 3, 500], ["radius1", "Radius 1", "float", 1.0, 0.0, 1000.0], ["radius2", "Radius 2", "float", 0.0, 0.0, 1000.0], ["depth", "Depth", "float", 2.0, 0.001, 1000.0]],
	"torus": [["major_segments", "Major Segments", "int", 48, 3, 256], ["minor_segments", "Minor Segments", "int", 12, 3, 256], ["major_radius", "Major Radius", "float", 1.0, 0.001, 1000.0], ["minor_radius", "Minor Radius", "float", 0.25, 0.001, 1000.0]],
	"grid": [["x_sub", "X Subdivisions", "int", 10, 1, 500], ["y_sub", "Y Subdivisions", "int", 10, 1, 500], ["size", "Size", "float", 2.0, 0.001, 1000.0]],
}

static func default_params(kind: String) -> Dictionary:
	var out := {}
	for p in PARAMS.get(kind, []):
		out[p[0]] = p[3]
	return out

static func create_with(kind: String, p: Dictionary):
	var d := default_params(kind)
	d.merge(p, true)
	match kind:
		"cube": return cube(d["size"])
		"plane": return plane(d["size"])
		"circle": return circle(int(d["verts"]), d["radius"])
		"uv_sphere": return uv_sphere(int(d["segments"]), int(d["rings"]), d["radius"])
		"ico_sphere": return ico_sphere(int(d["subdivisions"]), d["radius"])
		"cylinder": return cylinder(int(d["verts"]), d["radius"], d["depth"])
		"cone":
			var c = cone(int(d["verts"]), d["radius1"], d["radius2"], d["depth"])
			return c
		"torus": return torus(int(d["major_segments"]), int(d["minor_segments"]), d["major_radius"], d["minor_radius"])
		"grid": return grid(int(d["x_sub"]), int(d["y_sub"]), d["size"])
	return null
