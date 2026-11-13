## PfBvh — bounding volume hierarchy over a PfMesh's triangles (mesh-local
## space) for fast ray casts: face picking and occlusion tests for selection
## without X-Ray.
@tool
extends RefCounted

const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const LEAF := 6

var _a := PackedVector3Array()
var _b := PackedVector3Array()
var _c := PackedVector3Array()
var _face := PackedInt32Array()
# Flat node arrays: bounds, children (or -1) and triangle ranges.
var _nmin := PackedVector3Array()
var _nmax := PackedVector3Array()
var _left := PackedInt32Array()
var _right := PackedInt32Array()
var _start := PackedInt32Array()
var _count := PackedInt32Array()
var _order := PackedInt32Array()


func build(m, skip_faces := {}) -> void:
	_a.clear(); _b.clear(); _c.clear(); _face.clear()
	for fi in m.faces.size():
		if skip_faces.has(fi):
			continue
		var f: PackedInt32Array = m.faces[fi]
		var tris := PfBuild.triangulate(m, fi)
		for t in range(0, tris.size(), 3):
			_a.append(m.verts[f[tris[t]]])
			_b.append(m.verts[f[tris[t + 1]]])
			_c.append(m.verts[f[tris[t + 2]]])
			_face.append(fi)
	_nmin.clear(); _nmax.clear(); _left.clear(); _right.clear(); _start.clear(); _count.clear()
	_order = PackedInt32Array(range(_a.size()))
	if _a.size() > 0:
		_build_node(0, _a.size())

func triangle_count() -> int:
	return _a.size()

func _build_node(s: int, n: int) -> int:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for i in range(s, s + n):
		var t := _order[i]
		lo = lo.min(_a[t]).min(_b[t]).min(_c[t])
		hi = hi.max(_a[t]).max(_b[t]).max(_c[t])
	var id := _nmin.size()
	_nmin.append(lo); _nmax.append(hi)
	_left.append(-1); _right.append(-1)
	_start.append(s); _count.append(n)
	if n <= LEAF:
		return id
	var ext := hi - lo
	var axis := 0 if ext.x >= ext.y and ext.x >= ext.z else (1 if ext.y >= ext.z else 2)
	# Sort the range by centroid on the axis, split in the middle.
	var items := []
	for i in range(s, s + n):
		var t := _order[i]
		items.append([(_a[t][axis] + _b[t][axis] + _c[t][axis]), t])
	items.sort_custom(func(x, y): return x[0] < y[0])
	for i in n:
		_order[s + i] = items[i][1]
	var half := n / 2
	var l := _build_node(s, half)
	var r := _build_node(s + half, n - half)
	_left[id] = l
	_right[id] = r
	return id

static func _ray_box(o: Vector3, inv: Vector3, lo: Vector3, hi: Vector3, tmax: float) -> bool:
	var t0 := 0.0
	var t1 := tmax
	for k in 3:
		var a := (lo[k] - o[k]) * inv[k]
		var b := (hi[k] - o[k]) * inv[k]
		if a > b:
			var tmp := a
			a = b
			b = tmp
		t0 = maxf(t0, a)
		t1 = minf(t1, b)
		if t0 > t1:
			return false
	return true

## Nearest hit along the ray: {"t": float, "face": int, "point": Vector3} or {}.
func raycast(origin: Vector3, dir: Vector3, max_t := INF) -> Dictionary:
	if _nmin.is_empty():
		return {}
	var inv := Vector3(1.0 / dir.x if dir.x != 0.0 else INF, 1.0 / dir.y if dir.y != 0.0 else INF, 1.0 / dir.z if dir.z != 0.0 else INF)
	var best_t := max_t
	var best_f := -1
	var stack := [0]
	while not stack.is_empty():
		var nd: int = stack.pop_back()
		if not _ray_box(origin, inv, _nmin[nd], _nmax[nd], best_t):
			continue
		if _left[nd] < 0:
			for i in range(_start[nd], _start[nd] + _count[nd]):
				var t := _order[i]
				var hit = Geometry3D.ray_intersects_triangle(origin, dir, _a[t], _b[t], _c[t])
				if hit != null:
					var d: float = (hit - origin).dot(dir)
					if d > 0.0 and d < best_t:
						best_t = d
						best_f = _face[t]
		else:
			stack.append(_left[nd])
			stack.append(_right[nd])
	if best_f < 0:
		return {}
	return {"t": best_t, "face": best_f, "point": origin + dir * best_t}

## True when something lies between `eye` and `point` (mesh-local).
func occluded(eye: Vector3, point: Vector3, rel_eps := 1e-3) -> bool:
	var d := point - eye
	var dist := d.length()
	if dist < 1e-9:
		return false
	var hit := raycast(eye, d / dist, dist * (1.0 - rel_eps) - 1e-4)
	return not hit.is_empty()
