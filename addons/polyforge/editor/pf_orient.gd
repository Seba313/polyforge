## PfOrient — Transform Orientations (Blender): world-space axes for
##   global  – world axes
##   local   – the object's axes
##   normal  – the selection: Z = average normal of the selected faces (or of
##             the faces around the selected edges / vertices), Y along the
##             active edge / the active face's longest edge
##   view    – the camera (X right, Y up, Z toward the viewer)
@tool
extends RefCounted

const NAMES := ["global", "local", "normal", "view"]
const LABELS := {"global": "Global", "local": "Local", "normal": "Normal", "view": "View"}

enum { VERTEX = 1, EDGE = 2, FACE = 3 }


static func basis(name: String, s, node: Node3D, camera: Camera3D) -> Basis:
	match name:
		"local":
			return node.global_transform.basis.orthonormalized() if node != null else Basis.IDENTITY
		"view":
			return camera.global_transform.basis.orthonormalized() if camera != null else Basis.IDENTITY
		"normal":
			if s == null:
				return node.global_transform.basis.orthonormalized() if node != null else Basis.IDENTITY
			var b = normal_basis(s)
			return b if b != null else Basis.IDENTITY
	return Basis.IDENTITY

## Normal orientation of an Edit Mode selection (world space) or null.
static func normal_basis(s) -> Variant:
	var m = s.mesh
	var gx: Transform3D = s.node.global_transform
	var nb := gx.basis.inverse().transposed()   # normals: inverse-transpose
	var z := Vector3.ZERO
	var y := Vector3.ZERO
	var act = s.active()
	match s.mode:
		FACE:
			var faces: Dictionary = s.selected_faces()
			if faces.is_empty():
				return null
			for fi in faces:
				z += m.face_normal_raw(fi)
			var f: int = act if act != null and faces.has(act) else faces.keys()[0]
			y = _longest_edge(m, f)
		EDGE:
			var edges: Dictionary = s.selected_edges()
			if edges.is_empty():
				return null
			var e: Vector2i = act if act != null and edges.has(act) else edges.keys()[0]
			y = m.verts[e.y] - m.verts[e.x]
			for ed in edges:
				for fi in m.edge_faces(ed):
					z += m.face_normal(fi)
		_:
			var verts: Dictionary = s.selected_verts()
			if verts.is_empty():
				return null
			for v in verts:
				for fi in m.vert_faces(v):
					z += m.face_normal(fi)
			if verts.size() == 2:
				var k: Array = verts.keys()
				y = m.verts[k[1]] - m.verts[k[0]]
	var zw := (nb * z)
	var yw := (gx.basis * y)
	if zw.length_squared() < 1e-12:
		if yw.length_squared() < 1e-12:
			return null
		zw = _any_perp(yw)
	zw = zw.normalized()
	yw -= zw * zw.dot(yw)
	if yw.length_squared() < 1e-12:
		yw = _any_perp(zw)
	yw = yw.normalized()
	var xw := yw.cross(zw)
	return Basis(xw, yw, zw)

static func _longest_edge(m, fi: int) -> Vector3:
	var f: PackedInt32Array = m.faces[fi]
	var best := Vector3.ZERO
	for k in f.size():
		var d: Vector3 = m.verts[f[(k + 1) % f.size()]] - m.verts[f[k]]
		if d.length_squared() > best.length_squared():
			best = d
	return best

static func _any_perp(v: Vector3) -> Vector3:
	var a := Vector3.UP if absf(v.normalized().dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return a.cross(v).normalized()
