## PfUv — UV helpers that do not need the editor:
##   - World-Scale UV (optional, MeshBuilder-style): cube projection at a texel
##     density in px/m, independent of the texture resolution
##     (256 px/m: a 256 px texture tiles every 1 m, a 512 px one every 2 m),
##   - UV correction while vertices move (Blender's "Correct Face Attributes",
##     and the always-on protection of World-Scale UV).
@tool
extends RefCounted

const DEFAULT_TEXEL_DENSITY := 256.0
const DEFAULT_TEXTURE_PX := Vector2(256, 256)


# ==============================================================================
# Texel density
# ==============================================================================

## Texture size in pixels behind a material slot (albedo), or 256x256.
static func material_texture_px(mat: Material) -> Vector2:
	var tex: Texture2D = null
	if mat is BaseMaterial3D:
		tex = (mat as BaseMaterial3D).albedo_texture
	elif mat is ShaderMaterial:
		for pname in ["albedo_texture", "texture_albedo"]:
			var t = (mat as ShaderMaterial).get_shader_parameter(pname)
			if t is Texture2D:
				tex = t
				break
	if tex == null or tex.get_width() <= 0:
		return DEFAULT_TEXTURE_PX
	return Vector2(tex.get_width(), tex.get_height())

## UV units per metre for a face, given the density (px/m).
static func uv_per_metre(m, fi: int, density: float) -> Vector2:
	var slot: int = m.face_mat[fi]
	var mat: Material = m.materials[slot] if slot >= 0 and slot < m.materials.size() else null
	var px := material_texture_px(mat)
	return Vector2(density / px.x, density / px.y)

## MeshBuilder-style cube projection: each face is projected along its
## dominant axis, in world units scaled to the texel density. `faces` empty =
## all faces.
static func cube_project_world(m, density: float, faces := PackedInt32Array()) -> void:
	var list := faces
	if list.is_empty():
		list = PackedInt32Array(range(m.faces.size()))
	for fi in list:
		var n: Vector3 = m.face_normal(fi)
		var k := uv_per_metre(m, fi, density)
		var uv := PackedVector2Array()
		for v in m.faces[fi]:
			uv.append(_cube_coord(m.verts[v], n) * k)
		m.uvs[fi] = uv

## Planar coordinates (metres) of p for a face with normal n: right = +U,
## up = -V (texture rows go down), not mirrored when seen from outside.
static func _cube_coord(p: Vector3, n: Vector3) -> Vector2:
	var a := n.abs()
	if a.x >= a.y and a.x >= a.z:
		return Vector2(-p.z * signf(n.x) if n.x != 0.0 else -p.z, -p.y)
	if a.z >= a.y:
		return Vector2(p.x * (signf(n.z) if n.z != 0.0 else 1.0), -p.y)
	return Vector2(p.x, p.z * (signf(n.y) if n.y != 0.0 else 1.0))

## Measured density of a face in UV units per metre (average of both axes).
static func measured_uv_per_metre(m, fi: int) -> float:
	var area3 := 0.0
	var area2 := 0.0
	var f: PackedInt32Array = m.faces[fi]
	var uv: PackedVector2Array = m.uvs[fi]
	for k in range(1, f.size() - 1):
		area3 += (m.verts[f[k]] - m.verts[f[0]]).cross(m.verts[f[k + 1]] - m.verts[f[0]]).length() * 0.5
		var a := uv[k] - uv[0]
		var b := uv[k + 1] - uv[0]
		area2 += absf(a.x * b.y - a.y * b.x) * 0.5
	if area3 <= 1e-12:
		return 0.0
	return sqrt(area2 / area3)


# ==============================================================================
# UV correction while moving vertices
# ==============================================================================
#
# Per affected face, at capture time:
#   - the face plane gets an orthonormal frame (u, v) -> planar coords P,
#   - an affine map UV = M * P + t is least-squares fitted to the current UVs
#     (texel density + every user UV edit: offset, rotation, scale, flip), with
#     a per-corner residual for non-affine tweaks.
# On update the frame follows the face's rotation (shortest arc between old and
# new normal) and the moved corners get UV = M * P_new + t_new + residual:
#   - partly moved faces: t_new pinned by the unmoved corners (they keep UVs),
#   - fully moved faces (only when `full_faces` is set, i.e. World-Scale UV +
#     Scale): t_new pinned at the pivot -> the texture keeps its density and
#     adds tiles instead of stretching.
# Faces moved rigidly as a whole keep their UVs (the texture travels along).

## `moved`: vertex -> true. Returns correction records.
static func capture(m, moved: Dictionary, full_faces := false) -> Array:
	var records: Array = []
	for fi in m.faces.size():
		var f: PackedInt32Array = m.faces[fi]
		var n_moved := 0
		for v in f:
			if moved.has(v):
				n_moved += 1
		if n_moved == 0:
			continue
		var full := n_moved == f.size()
		if full and not full_faces:
			continue
		var n: Vector3 = m.face_normal(fi)
		if n == Vector3.ZERO:
			continue
		var u := _perp(n)
		var v := n.cross(u)
		var P := PackedVector2Array()
		for vi in f:
			var p: Vector3 = m.verts[vi]
			P.append(Vector2(p.dot(u), p.dot(v)))
		var uv: PackedVector2Array = m.uvs[fi].duplicate()
		var fit := _fit_affine(P, uv)
		if fit.is_empty():
			continue
		var mx: Transform2D = fit["m"]
		var resid := PackedVector2Array()
		for k in f.size():
			resid.append(uv[k] - mx * P[k])
		var flags := PackedByteArray()
		for vi in f:
			flags.append(1 if moved.has(vi) else 0)
		records.append({"face": fi, "moved": flags, "full": full, "n": n, "u": u, "v": v,
			"m": mx, "resid": resid, "uv": uv})
	return records

## Recomputes UVs of the captured faces from the current positions.
## `pivot` (mesh-local) anchors fully moved faces.
static func apply(m, records: Array, pivot := Vector3.ZERO) -> void:
	for rec in records:
		var fi: int = rec["face"]
		if fi >= m.faces.size():
			continue
		var f: PackedInt32Array = m.faces[fi]
		var flags: PackedByteArray = rec["moved"]
		if flags.size() != f.size():
			continue
		var mx: Transform2D = rec["m"]
		var resid: PackedVector2Array = rec["resid"]
		var uv_old: PackedVector2Array = rec["uv"]
		var n_old: Vector3 = rec["n"]
		var u: Vector3 = rec["u"]
		var v: Vector3 = rec["v"]
		var n_new: Vector3 = m.face_normal(fi)
		if n_new != Vector3.ZERO and n_new.dot(n_old) < 0.999999:
			var q := _arc(n_old, n_new)
			u = q * u
			v = q * v
		var P := PackedVector2Array()
		for vi in f:
			var p: Vector3 = m.verts[vi]
			P.append(Vector2(p.dot(u), p.dot(v)))
		var t_new := Vector2.ZERO
		if bool(rec["full"]):
			# UV at the pivot stays where it was before the move.
			var uvp := mx.basis_xform(Vector2(pivot.dot(rec["u"]), pivot.dot(rec["v"]))) + mx.origin
			t_new = uvp - mx.basis_xform(Vector2(pivot.dot(u), pivot.dot(v)))
		else:
			var acc := Vector2.ZERO
			var cnt := 0
			for k in f.size():
				if flags[k] == 0:
					acc += uv_old[k] - resid[k] - mx.basis_xform(P[k])
					cnt += 1
			if cnt == 0:
				continue
			t_new = acc / float(cnt)
		var out: PackedVector2Array = m.uvs[fi]
		for k in f.size():
			if flags[k] == 1:
				out[k] = mx.basis_xform(P[k]) + t_new + resid[k]
		m.uvs[fi] = out


static func _perp(n: Vector3) -> Vector3:
	var a := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return a.cross(n).normalized()

## Shortest-arc rotation taking unit vector a onto unit vector b.
static func _arc(a: Vector3, b: Vector3) -> Quaternion:
	var c := a.cross(b)
	var d := a.dot(b)
	if d < -0.999999:
		return Quaternion(_perp(a), PI)
	return Quaternion(c.x, c.y, c.z, 1.0 + d).normalized()

## Least-squares affine UV = M * P + t. {} when degenerate.
static func _fit_affine(P: PackedVector2Array, UV: PackedVector2Array) -> Dictionary:
	var n := P.size()
	var pc := Vector2.ZERO
	var uc := Vector2.ZERO
	for k in n:
		pc += P[k]
		uc += UV[k]
	pc /= n
	uc /= n
	var sxx := 0.0
	var sxy := 0.0
	var syy := 0.0
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	for k in n:
		var dp := P[k] - pc
		var du := UV[k] - uc
		sxx += dp.x * dp.x
		sxy += dp.x * dp.y
		syy += dp.y * dp.y
		a += du * dp.x
		b += du * dp.y
	var det := sxx * syy - sxy * sxy
	if absf(det) < 1e-14:
		return {}
	var i00 := syy / det
	var i01 := -sxy / det
	var i11 := sxx / det
	var mx := Transform2D(a * i00 + b * i01, a * i01 + b * i11, Vector2.ZERO)
	mx.origin = uc - mx.basis_xform(pc)
	return {"m": mx}
