## PfMesh — editable polygon mesh, modelled after Blender's BMesh.
##
## - vertices are shared between faces (moving a vertex moves every face corner),
## - faces are n-gons: vertex index lists, counter-clockwise seen from outside
##   (Blender / right-hand rule; the builder flips them for Godot),
## - UVs live on face corners (loops), so UV seams exist naturally,
## - per face: material slot and smooth flag; per edge: sharp and seam flags.
##
## Pure data + topology queries, no editor dependency. No class_name on purpose:
## load it with preload("res://addons/polyforge/core/pf_mesh.gd").
@tool
extends RefCounted

const FORMAT_VERSION := 1
const META_KEY := "polyforge"

var verts := PackedVector3Array()
var faces: Array[PackedInt32Array] = []
var uvs: Array[PackedVector2Array] = []    # per face, one UV per corner
var uv2s: Array[PackedVector2Array] = []   # per face; used only when has_uv2
var has_uv2 := false
var face_mat := PackedInt32Array()
var face_smooth := PackedByteArray()
## Session-only tag per face (multi-object edit: index of the owning object,
## -1 = unknown, e.g. a face created by an operator).
var face_tag := PackedInt32Array()
var sharp_edges := {}   # Vector2i(min, max) -> true
var seam_edges := {}    # Vector2i(min, max) -> true
## Loose ("wire") edges that belong to no face (Blender keeps them, e.g. after
## Delete > Only Faces or F on two vertices). Not rendered in the game mesh.
var wire_edges := {}    # Vector2i(min, max) -> true
var uv_pins := {}       # vertex -> true (UV pinned for Unwrap)
var materials: Array = []   # Material per slot (may contain null)
## World-Scale UV (MeshBuilder-style) for this object; texel density in px/m
## (0 = project default).
var world_uv := false
var texel_density := 0.0

# --- topology cache -----------------------------------------------------------
var _topo_valid := false
var _edges: Array[Vector2i] = []
var _edge_index := {}        # Vector2i -> edge id
var _edge_faces: Array = []  # edge id -> PackedInt32Array of faces
var _vert_faces: Array = []  # vertex -> PackedInt32Array of faces
var _vert_edges: Array = []  # vertex -> PackedInt32Array of edge ids


static func ekey(a: int, b: int) -> Vector2i:
	return Vector2i(a, b) if a < b else Vector2i(b, a)


# ==============================================================================
# Construction
# ==============================================================================

func add_vertex(p: Vector3) -> int:
	verts.append(p)
	_topo_valid = false
	return verts.size() - 1

## Adds a face (CCW from outside). `corner_uvs` may be empty (zero UVs).
func add_face(idx: PackedInt32Array, corner_uvs := PackedVector2Array(), mat := 0, smooth := false) -> int:
	faces.append(idx)
	var u := corner_uvs
	if u.size() != idx.size():
		u = PackedVector2Array()
		u.resize(idx.size())
	uvs.append(u)
	var u2 := PackedVector2Array()
	u2.resize(idx.size())
	uv2s.append(u2)
	face_mat.append(mat)
	face_smooth.append(1 if smooth else 0)
	face_tag.append(-1)
	_topo_valid = false
	return faces.size() - 1

func face_count() -> int:
	return faces.size()

func invalidate() -> void:
	_topo_valid = false

func duplicate_mesh():
	var m = get_script().new()
	m.from_dict(to_dict())
	return m


# ==============================================================================
# Serialization (plain packed arrays: no scripts end up in scene files)
# ==============================================================================

func to_dict() -> Dictionary:
	var sizes := PackedInt32Array()
	var flat := PackedInt32Array()
	var fuv := PackedVector2Array()
	var fuv2 := PackedVector2Array()
	for i in faces.size():
		sizes.append(faces[i].size())
		flat.append_array(faces[i])
		fuv.append_array(uvs[i])
		if has_uv2:
			fuv2.append_array(uv2s[i])
	var sharp := PackedInt32Array()
	for k in sharp_edges:
		sharp.append(k.x)
		sharp.append(k.y)
	var seam := PackedInt32Array()
	for k in seam_edges:
		seam.append(k.x)
		seam.append(k.y)
	return {
		"version": FORMAT_VERSION,
		"verts": verts.duplicate(),
		"face_sizes": sizes,
		"face_verts": flat,
		"uv": fuv,
		"uv2": fuv2,
		"has_uv2": has_uv2,
		"face_mat": face_mat.duplicate(),
		"face_smooth": face_smooth.duplicate(),
		"face_tag": face_tag.duplicate(),
		"sharp": sharp,
		"seam": seam,
		"wire": _pairs(wire_edges),
		"pins": PackedInt32Array(uv_pins.keys()),
		"materials": materials.duplicate(),
		"world_uv": world_uv,
		"texel_density": texel_density,
	}

func from_dict(d: Dictionary) -> bool:
	if int(d.get("version", 0)) < 1:
		return false
	verts = (d.get("verts", PackedVector3Array()) as PackedVector3Array).duplicate()
	var sizes: PackedInt32Array = d.get("face_sizes", PackedInt32Array())
	var flat: PackedInt32Array = d.get("face_verts", PackedInt32Array())
	var fuv: PackedVector2Array = d.get("uv", PackedVector2Array())
	var fuv2: PackedVector2Array = d.get("uv2", PackedVector2Array())
	has_uv2 = bool(d.get("has_uv2", false))
	faces.clear()
	uvs.clear()
	uv2s.clear()
	var o := 0
	for s in sizes:
		faces.append(flat.slice(o, o + s))
		uvs.append(fuv.slice(o, o + s) if fuv.size() >= o + s else _zeros(s))
		uv2s.append(fuv2.slice(o, o + s) if has_uv2 and fuv2.size() >= o + s else _zeros(s))
		o += s
	face_mat = (d.get("face_mat", PackedInt32Array()) as PackedInt32Array).duplicate()
	face_smooth = (d.get("face_smooth", PackedByteArray()) as PackedByteArray).duplicate()
	face_mat.resize(faces.size())
	face_smooth.resize(faces.size())
	face_tag = (d.get("face_tag", PackedInt32Array()) as PackedInt32Array).duplicate()
	if face_tag.size() != faces.size():
		face_tag.resize(faces.size())
		face_tag.fill(-1)
	sharp_edges.clear()
	var sharp: PackedInt32Array = d.get("sharp", PackedInt32Array())
	for i in range(0, sharp.size() - 1, 2):
		sharp_edges[ekey(sharp[i], sharp[i + 1])] = true
	seam_edges.clear()
	var seam: PackedInt32Array = d.get("seam", PackedInt32Array())
	for i in range(0, seam.size() - 1, 2):
		seam_edges[ekey(seam[i], seam[i + 1])] = true
	wire_edges.clear()
	var wire: PackedInt32Array = d.get("wire", PackedInt32Array())
	for i in range(0, wire.size() - 1, 2):
		wire_edges[ekey(wire[i], wire[i + 1])] = true
	uv_pins.clear()
	for v in d.get("pins", PackedInt32Array()):
		uv_pins[v] = true
	materials = (d.get("materials", []) as Array).duplicate()
	world_uv = bool(d.get("world_uv", false))
	texel_density = float(d.get("texel_density", 0.0))
	_topo_valid = false
	return true

static func _pairs(d: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k in d:
		out.append(k.x)
		out.append(k.y)
	return out

static func _zeros(n: int) -> PackedVector2Array:
	var a := PackedVector2Array()
	a.resize(n)
	return a


# ==============================================================================
# Topology
# ==============================================================================

func ensure_topology() -> void:
	if _topo_valid:
		return
	_edges.clear()
	_edge_index.clear()
	# Build with plain Arrays (reference types), then freeze to packed arrays:
	# a PackedInt32Array read out of an Array is a copy, so appending to it
	# in place would be lost.
	var ef: Array = []
	var vf: Array = []
	var ve: Array = []
	vf.resize(verts.size())
	ve.resize(verts.size())
	for v in verts.size():
		vf[v] = []
		ve[v] = []
	for fi in faces.size():
		var f := faces[fi]
		var n := f.size()
		for k in n:
			var a := f[k]
			var b := f[(k + 1) % n]
			(vf[a] as Array).append(fi)
			var key := ekey(a, b)
			var ei: int = _edge_index.get(key, -1)
			if ei < 0:
				ei = _edges.size()
				_edges.append(key)
				_edge_index[key] = ei
				ef.append([])
				(ve[key.x] as Array).append(ei)
				(ve[key.y] as Array).append(ei)
			(ef[ei] as Array).append(fi)
	# Wire edges: edges without faces (dropped if a face now uses them).
	for key in wire_edges.keys():
		if _edge_index.has(key) or key.x >= verts.size() or key.y >= verts.size() or key.x == key.y:
			wire_edges.erase(key)
			continue
		var ei := _edges.size()
		_edges.append(key)
		_edge_index[key] = ei
		ef.append([])
		(ve[key.x] as Array).append(ei)
		(ve[key.y] as Array).append(ei)
	_edge_faces.resize(ef.size())
	for i in ef.size():
		_edge_faces[i] = PackedInt32Array(ef[i])
	_vert_faces.resize(vf.size())
	_vert_edges.resize(ve.size())
	for v in vf.size():
		_vert_faces[v] = PackedInt32Array(vf[v])
		_vert_edges[v] = PackedInt32Array(ve[v])
	_topo_valid = true

func edges() -> Array[Vector2i]:
	ensure_topology()
	return _edges

func edge_id(key: Vector2i) -> int:
	ensure_topology()
	return _edge_index.get(key, -1)

func edge_faces(key: Vector2i) -> PackedInt32Array:
	ensure_topology()
	var ei: int = _edge_index.get(key, -1)
	return _edge_faces[ei] if ei >= 0 else PackedInt32Array()

func vert_faces(v: int) -> PackedInt32Array:
	ensure_topology()
	return _vert_faces[v] if v < _vert_faces.size() else PackedInt32Array()

func vert_edges(v: int) -> Array[Vector2i]:
	ensure_topology()
	var out: Array[Vector2i] = []
	if v < _vert_edges.size():
		for ei in _vert_edges[v]:
			out.append(_edges[ei])
	return out

func face_edges(fi: int) -> Array[Vector2i]:
	var f := faces[fi]
	var out: Array[Vector2i] = []
	for k in f.size():
		out.append(ekey(f[k], f[(k + 1) % f.size()]))
	return out

func is_boundary_edge(key: Vector2i) -> bool:
	return edge_faces(key).size() == 1

## Newell normal (unnormalized: length = 2 * area).
func face_normal_raw(fi: int) -> Vector3:
	var f := faces[fi]
	var n := Vector3.ZERO
	for k in f.size():
		var a := verts[f[k]]
		var b := verts[f[(k + 1) % f.size()]]
		n.x += (a.y - b.y) * (a.z + b.z)
		n.y += (a.z - b.z) * (a.x + b.x)
		n.z += (a.x - b.x) * (a.y + b.y)
	return n

func face_normal(fi: int) -> Vector3:
	var n := face_normal_raw(fi)
	return n.normalized() if n.length_squared() > 1e-24 else Vector3.ZERO

func face_center(fi: int) -> Vector3:
	var c := Vector3.ZERO
	for v in faces[fi]:
		c += verts[v]
	return c / float(maxi(faces[fi].size(), 1))

func face_area(fi: int) -> float:
	return face_normal_raw(fi).length() * 0.5

## Index of vertex v inside face fi (-1 when not a corner).
func corner_of(fi: int, v: int) -> int:
	var f := faces[fi]
	for k in f.size():
		if f[k] == v:
			return k
	return -1

func bounds() -> AABB:
	if verts.is_empty():
		return AABB()
	var bb := AABB(verts[0], Vector3.ZERO)
	for p in verts:
		bb = bb.expand(p)
	return bb


# ==============================================================================
# Editing helpers used by operations
# ==============================================================================

## Merges another mesh into this one (used by Shift+A in Edit Mode).
## Returns the new vertex indices.
func append_mesh(other, xf := Transform3D.IDENTITY) -> PackedInt32Array:
	var base := verts.size()
	var new_idx := PackedInt32Array()
	for p in other.verts:
		new_idx.append(add_vertex(xf * p))
	for fi in other.faces.size():
		var f := PackedInt32Array()
		for v in other.faces[fi]:
			f.append(v + base)
		var nf := add_face(f, other.uvs[fi].duplicate(), other.face_mat[fi], other.face_smooth[fi] != 0)
		if other.has_uv2:
			uv2s[nf] = other.uv2s[fi].duplicate()
	if other.has_uv2:
		has_uv2 = true
	for k in other.sharp_edges:
		sharp_edges[Vector2i(k.x + base, k.y + base)] = true
	for k in other.seam_edges:
		seam_edges[Vector2i(k.x + base, k.y + base)] = true
	for k in other.wire_edges:
		wire_edges[Vector2i(k.x + base, k.y + base)] = true
	return new_idx

## Checks internal consistency. Returns an empty string when valid.
func validate() -> String:
	if uvs.size() != faces.size() or uv2s.size() != faces.size():
		return "uv arrays out of sync"
	if face_mat.size() != faces.size() or face_smooth.size() != faces.size():
		return "face attribute arrays out of sync"
	for fi in faces.size():
		var f := faces[fi]
		if f.size() < 3:
			return "face %d has %d corners" % [fi, f.size()]
		if uvs[fi].size() != f.size():
			return "face %d uv count" % fi
		var seen := {}
		for v in f:
			if v < 0 or v >= verts.size():
				return "face %d bad vertex %d" % [fi, v]
			if seen.has(v):
				return "face %d repeats vertex %d" % [fi, v]
			seen[v] = true
	return ""
