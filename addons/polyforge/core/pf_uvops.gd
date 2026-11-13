## PfUvOps — UV operators (Blender semantics) on a PfMesh, for UV1 or UV2
## (channel 0 / 1): Unwrap (LSCM, split along seams), Smart UV Project, Cube /
## Cylinder / Sphere projection, Project from View, Reset, Pack Islands,
## Average Islands Scale, texel density, UV islands.
@tool
extends RefCounted

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const PfUv := preload("res://addons/polyforge/core/pf_uv.gd")

const EPS := 1e-5


static func get_uv(m, ch: int, fi: int) -> PackedVector2Array:
	return m.uvs[fi] if ch == 0 else m.uv2s[fi]

static func set_uv(m, ch: int, fi: int, uv: PackedVector2Array) -> void:
	if ch == 0:
		m.uvs[fi] = uv
	else:
		m.uv2s[fi] = uv
		m.has_uv2 = true


# ==============================================================================
# Islands
# ==============================================================================

## UV islands among `faces`: faces joined across edges whose UVs match at both
## ends. Returns Array of Dictionaries (face -> true).
static func islands(m, ch: int, faces: Dictionary) -> Array:
	m.ensure_topology()
	var seen := {}
	var out := []
	for f0 in faces:
		if seen.has(f0):
			continue
		var isl := {}
		var stack := [f0]
		while not stack.is_empty():
			var f: int = stack.pop_back()
			if seen.has(f):
				continue
			seen[f] = true
			isl[f] = true
			var fv: PackedInt32Array = m.faces[f]
			var fu := get_uv(m, ch, f)
			for k in fv.size():
				var a := fv[k]
				var b := fv[(k + 1) % fv.size()]
				for g in m.edge_faces(PfMesh.ekey(a, b)):
					if g == f or seen.has(g) or not faces.has(g):
						continue
					var gu := get_uv(m, ch, g)
					var ka: int = m.corner_of(g, a)
					var kb: int = m.corner_of(g, b)
					if fu[k].distance_to(gu[ka]) < EPS and fu[(k + 1) % fv.size()].distance_to(gu[kb]) < EPS:
						stack.append(g)
		out.append(isl)
	return out

static func island_bounds(m, ch: int, isl: Dictionary) -> Rect2:
	var r := Rect2()
	var first := true
	for f in isl:
		for u in get_uv(m, ch, f):
			if first:
				r = Rect2(u, Vector2.ZERO)
				first = false
			else:
				r = r.expand(u)
	return r

static func _areas(m, ch: int, faces: Dictionary) -> Vector2:   # (uv area, 3d area)
	var a2 := 0.0
	var a3 := 0.0
	for f in faces:
		var fv: PackedInt32Array = m.faces[f]
		var u := get_uv(m, ch, f)
		for k in range(1, fv.size() - 1):
			a3 += (m.verts[fv[k]] - m.verts[fv[0]]).cross(m.verts[fv[k + 1]] - m.verts[fv[0]]).length() * 0.5
			var p := u[k] - u[0]
			var q := u[k + 1] - u[0]
			a2 += absf(p.x * q.y - p.y * q.x) * 0.5
	return Vector2(a2, a3)

## Transforms the UVs of a set of faces with xf (UV space).
static func transform_faces(m, ch: int, faces: Dictionary, xf: Transform2D) -> void:
	for f in faces:
		var u := get_uv(m, ch, f)
		for k in u.size():
			u[k] = xf * u[k]
		set_uv(m, ch, f, u)


# ==============================================================================
# Unwrap (LSCM)
# ==============================================================================

## Charts for unwrapping: faces connected across non-seam edges; corners of
## one vertex are split where a seam passes (tubes open along their seam).
## Returns {"charts": [faces dicts], "group": {Vector2i(face, corner): id}}.
static func charts(m, faces: Dictionary) -> Dictionary:
	m.ensure_topology()
	var parent := {}
	var find := func(x):
		var r = x
		while parent[r] != r:
			r = parent[r]
		var c = x
		while parent[c] != r:
			var n = parent[c]
			parent[c] = r
			c = n
		return r
	for f in faces:
		for k in m.faces[f].size():
			var key := Vector2i(f, k)
			parent[key] = key
	var face_par := {}
	for f in faces:
		face_par[f] = f
	var ffind := func(x):
		var r = x
		while face_par[r] != r:
			r = face_par[r]
		face_par[x] = r
		return r
	for e in m.edges():
		if m.seam_edges.has(e):
			continue
		var ef: PackedInt32Array = m.edge_faces(e)
		if ef.size() != 2 or not faces.has(ef[0]) or not faces.has(ef[1]):
			continue
		var ra = ffind.call(ef[0])
		var rb = ffind.call(ef[1])
		if ra != rb:
			face_par[ra] = rb
		for v in [e.x, e.y]:
			var ca := Vector2i(ef[0], m.corner_of(ef[0], v))
			var cb := Vector2i(ef[1], m.corner_of(ef[1], v))
			var x = find.call(ca)
			var y = find.call(cb)
			if x != y:
				parent[x] = y
	var by := {}
	for f in faces:
		var r = ffind.call(f)
		if not by.has(r):
			by[r] = {}
		by[r][f] = true
	var group := {}
	for key in parent:
		group[key] = find.call(key)
	return {"charts": by.values(), "group": group}

## LSCM of one chart. `pinned`: group -> fixed UV. Writes channel `ch`.
## Returns false when the chart is degenerate.
static func lscm_chart(m, ch: int, chart: Dictionary, group: Dictionary, pinned := {}) -> bool:
	var ids := {}       # group -> unknown index
	var pos := []       # 3D position per index
	var tris := []      # [i0, i1, i2]
	for f in chart:
		var fv: PackedInt32Array = m.faces[f]
		var t := PfBuild.triangulate(m, f)
		var gi := []
		for k in fv.size():
			var g = group[Vector2i(f, k)]
			if not ids.has(g):
				ids[g] = pos.size()
				pos.append(m.verts[fv[k]])
			gi.append(ids[g])
		for j in range(0, t.size(), 3):
			tris.append([gi[t[j]], gi[t[j + 1]], gi[t[j + 2]]])
	var n := pos.size()
	if n < 3:
		return false
	# Pins: user pins, else the two vertices farthest apart.
	var fixed := {}
	for g in pinned:
		if ids.has(g):
			fixed[ids[g]] = pinned[g]
	if fixed.size() < 2:
		fixed.clear()
		var a := 0
		var b := 0
		var best := -1.0
		for i in n:
			var d: float = (pos[i] as Vector3).distance_squared_to(pos[0])
			if d > best:
				best = d
				a = i
		best = -1.0
		for i in n:
			var d: float = (pos[i] as Vector3).distance_squared_to(pos[a])
			if d > best:
				best = d
				b = i
		if best <= 1e-20:
			return false
		fixed[a] = Vector2(0, 0)
		fixed[b] = Vector2(sqrt(best), 0)
	# Free unknown numbering: x = [u0, v0, u1, v1, ...] of free vertices.
	var col := {}
	var nfree := 0
	for i in n:
		if not fixed.has(i):
			col[i] = nfree
			nfree += 1
	# Rows (sparse): two per triangle.
	var rows := []   # [cols PackedInt32Array, vals PackedFloat64Array, rhs]
	for t in tris:
		var p0: Vector3 = pos[t[0]]
		var p1: Vector3 = pos[t[1]]
		var p2: Vector3 = pos[t[2]]
		var e1 := p1 - p0
		var e2 := p2 - p0
		var nrm := e1.cross(e2)
		var area2 := nrm.length()
		if area2 < 1e-14:
			continue
		var xa := e1.normalized()
		var ya := nrm.cross(e1).normalized()
		var lx := [0.0, e1.length(), e2.dot(xa)]
		var ly := [0.0, 0.0, e2.dot(ya)]
		var s := 1.0 / sqrt(area2)
		var re_c := PackedInt32Array()
		var re_v := PackedFloat64Array()
		var im_c := PackedInt32Array()
		var im_v := PackedFloat64Array()
		var re_b := 0.0
		var im_b := 0.0
		for j in 3:
			var wr: float = (lx[(j + 2) % 3] - lx[(j + 1) % 3]) * s
			var wi: float = (ly[(j + 2) % 3] - ly[(j + 1) % 3]) * s
			var vi: int = t[j]
			if fixed.has(vi):
				var uv: Vector2 = fixed[vi]
				re_b -= wr * uv.x - wi * uv.y
				im_b -= wi * uv.x + wr * uv.y
			else:
				var c: int = col[vi] * 2
				re_c.append_array([c, c + 1])
				re_v.append_array([wr, -wi])
				im_c.append_array([c, c + 1])
				im_v.append_array([wi, wr])
		rows.append([re_c, re_v, re_b])
		rows.append([im_c, im_v, im_b])
	var x := _cg(rows, nfree * 2)
	var uvs := []
	uvs.resize(n)
	for i in n:
		uvs[i] = fixed[i] if fixed.has(i) else Vector2(x[col[i] * 2], x[col[i] * 2 + 1])
	# Conformal maps can come out mirrored: keep the faces counter-clockwise.
	var signed := 0.0
	for t in tris:
		var a: Vector2 = uvs[t[0]]
		var b: Vector2 = uvs[t[1]]
		var c: Vector2 = uvs[t[2]]
		signed += (b - a).cross(c - a)
	var flip := signed > 0.0 and pinned.size() < 2   # texture V points down
	for f in chart:
		var u := get_uv(m, ch, f)
		for k in u.size():
			var p: Vector2 = uvs[ids[group[Vector2i(f, k)]]]
			u[k] = Vector2(p.x, -p.y) if flip else p
		set_uv(m, ch, f, u)
	return true

## Least squares A x = b by conjugate gradient on the normal equations.
static func _cg(rows: Array, nx: int) -> PackedFloat64Array:
	var x := PackedFloat64Array()
	x.resize(nx)
	if nx == 0:
		return x
	var atb := PackedFloat64Array()
	atb.resize(nx)
	for r in rows:
		var cs: PackedInt32Array = r[0]
		var vs: PackedFloat64Array = r[1]
		for j in cs.size():
			atb[cs[j]] += vs[j] * r[2]
	var mul := func(v: PackedFloat64Array) -> PackedFloat64Array:
		var out := PackedFloat64Array()
		out.resize(nx)
		for r in rows:
			var cs: PackedInt32Array = r[0]
			var vs: PackedFloat64Array = r[1]
			var d := 0.0
			for j in cs.size():
				d += vs[j] * v[cs[j]]
			for j in cs.size():
				out[cs[j]] += vs[j] * d
		return out
	var rr := atb.duplicate()
	var p := rr.duplicate()
	var rs := 0.0
	for i in nx:
		rs += rr[i] * rr[i]
	var tol := maxf(rs * 1e-20, 1e-30)
	for it in mini(nx * 4, 4000):
		if rs <= tol:
			break
		var ap: PackedFloat64Array = mul.call(p)
		var pap := 0.0
		for i in nx:
			pap += p[i] * ap[i]
		if absf(pap) < 1e-30:
			break
		var alpha := rs / pap
		var rs2 := 0.0
		for i in nx:
			x[i] += alpha * p[i]
			rr[i] -= alpha * ap[i]
			rs2 += rr[i] * rr[i]
		var beta := rs2 / rs
		for i in nx:
			p[i] = rr[i] + beta * p[i]
		rs = rs2
	return x

## Unwrap: LSCM per chart (seams cut), then pack into 0..1 (Blender), or
## scale to the texel density when `density` > 0 (World-Scale UV).
static func unwrap(m, ch: int, faces: Dictionary, density := 0.0, pins := {}) -> int:
	var c := charts(m, faces)
	var group: Dictionary = c["group"]
	var pinned := {}
	for key in group:
		if pins.has(m.faces[key.x][key.y]):
			pinned[group[key]] = get_uv(m, ch, key.x)[key.y]
	var done := 0
	for chart in c["charts"]:
		if lscm_chart(m, ch, chart, group, pinned):
			done += 1
	if pinned.size() >= 2:
		return done
	_finish(m, ch, c["charts"], density)
	return done

## After a projection: scale islands to density (World-Scale) or pack 0..1.
static func _finish(m, ch: int, parts: Array, density: float) -> void:
	if density > 0.0:
		for p in parts:
			set_density(m, ch, p, density)
		pack(m, ch, parts, false)
	else:
		average_scale(m, ch, parts)
		pack(m, ch, parts, true)


# ==============================================================================
# Projections
# ==============================================================================

## Smart UV Project: faces grouped by normal (angle limit), each group
## projected flat along its normal, then packed.
static func smart_project(m, ch: int, faces: Dictionary, angle_deg := 66.0, density := 0.0) -> void:
	m.ensure_topology()
	var lim := cos(deg_to_rad(angle_deg))
	var seen := {}
	var parts := []
	for f0 in faces:
		if seen.has(f0):
			continue
		var n0: Vector3 = m.face_normal(f0)
		var grp := {}
		var stack := [f0]
		while not stack.is_empty():
			var f: int = stack.pop_back()
			if seen.has(f):
				continue
			seen[f] = true
			grp[f] = true
			for e in m.face_edges(f):
				for g in m.edge_faces(e):
					if faces.has(g) and not seen.has(g) and m.face_normal(g).dot(n0) >= lim:
						stack.append(g)
		var n := Vector3.ZERO
		for f in grp:
			n += m.face_normal_raw(f)
		_planar(m, ch, grp, n.normalized() if n.length_squared() > 1e-20 else n0)
		parts.append(grp)
	_finish(m, ch, parts, density)

static func _planar(m, ch: int, grp: Dictionary, n: Vector3) -> void:
	var u := (Vector3.UP if absf(n.y) < 0.9 else Vector3.BACK).cross(n).normalized()
	if absf(n.y) >= 0.9:
		u = Vector3.RIGHT if n.y > 0 else Vector3.RIGHT
	var v := n.cross(u).normalized()
	for f in grp:
		var uv := PackedVector2Array()
		for vi in m.faces[f]:
			var p: Vector3 = m.verts[vi]
			uv.append(Vector2(p.dot(u), -p.dot(v)))
		set_uv(m, ch, f, uv)

## Cube Projection (Blender: cube size, default 2 m -> -1..1 maps to 0..1).
static func cube_project(m, ch: int, faces: Dictionary, cube_size := 2.0, density := 0.0) -> void:
	for f in faces:
		var n: Vector3 = m.face_normal(f)
		var uv := PackedVector2Array()
		for vi in m.faces[f]:
			var c := PfUv._cube_coord(m.verts[vi], n)
			uv.append(c / cube_size + Vector2(0.5, 0.5))
		set_uv(m, ch, f, uv)
	if density > 0.0:
		for isl in islands(m, ch, faces):
			set_density(m, ch, isl, density)

## Cylinder (axis Y) / Sphere projection around the selection centre.
static func wrap_project(m, ch: int, faces: Dictionary, sphere: bool) -> void:
	var c := Vector3.ZERO
	var cnt := 0
	var lo := INF
	var hi := -INF
	for f in faces:
		for vi in m.faces[f]:
			c += m.verts[vi]
			cnt += 1
			lo = minf(lo, m.verts[vi].y)
			hi = maxf(hi, m.verts[vi].y)
	if cnt == 0:
		return
	c /= float(cnt)
	for f in faces:
		var uv := PackedVector2Array()
		for vi in m.faces[f]:
			var d: Vector3 = m.verts[vi] - c
			var u := 0.5 + atan2(-d.z, d.x) / TAU
			var v := 0.0
			if sphere:
				v = 0.5 - asin(clampf(d.normalized().y, -1.0, 1.0)) / PI if d.length_squared() > 1e-20 else 0.5
			else:
				v = 1.0 - (m.verts[vi].y - lo) / maxf(hi - lo, 1e-9)
			uv.append(Vector2(u, v))
		var umax := 0.0
		for p in uv:
			umax = maxf(umax, p.x)
		for k in uv.size():
			if umax - uv[k].x > 0.5:
				uv[k].x += 1.0
		set_uv(m, ch, f, uv)

## Project from View: screen positions via `to_screen` (mesh-local point ->
## Vector2); bounds = fit the result into 0..1.
static func project_view(m, ch: int, faces: Dictionary, to_screen: Callable, bounds: bool, px_per_unit := 1.0) -> void:
	for f in faces:
		var uv := PackedVector2Array()
		for vi in m.faces[f]:
			uv.append((to_screen.call(m.verts[vi]) as Vector2) / px_per_unit)
		set_uv(m, ch, f, uv)
	if bounds:
		_fit(m, ch, faces)

static func _fit(m, ch: int, faces: Dictionary) -> void:
	var r := island_bounds(m, ch, faces)
	var s := maxf(r.size.x, r.size.y)
	if s < 1e-12:
		return
	transform_faces(m, ch, faces, Transform2D(0.0, Vector2.ONE / s, 0.0, -r.position / s))

## Reset: every face fills the 0..1 square (quads: corners; n-gons: circle).
static func reset(m, ch: int, faces: Dictionary) -> void:
	for f in faces:
		var n: int = m.faces[f].size()
		var uv := PackedVector2Array()
		if n == 4:
			uv = PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
		else:
			for k in n:
				var a := TAU * float(k) / n
				uv.append(Vector2(0.5 + 0.5 * cos(a), 0.5 - 0.5 * sin(a)))
		set_uv(m, ch, f, uv)


# ==============================================================================
# Pack / scale / density
# ==============================================================================

## Average Islands Scale: every island gets the same UV area per 3D area.
static func average_scale(m, ch: int, parts: Array) -> void:
	var tot := Vector2.ZERO
	for p in parts:
		tot += _areas(m, ch, p)
	if tot.x <= 1e-20 or tot.y <= 1e-20:
		return
	var target := tot.x / tot.y
	for p in parts:
		var a := _areas(m, ch, p)
		if a.x <= 1e-20 or a.y <= 1e-20:
			continue
		var s := sqrt(target / (a.x / a.y))
		var c := island_bounds(m, ch, p).get_center()
		transform_faces(m, ch, p, Transform2D(0.0, Vector2(s, s), 0.0, c - c * s))

## Scales an island to `density` px/m (texture size from the face material).
static func set_density(m, ch: int, isl: Dictionary, density: float) -> void:
	var a := _areas(m, ch, isl)
	if a.x <= 1e-20 or a.y <= 1e-20:
		return
	var f0: int = isl.keys()[0]
	var k := PfUv.uv_per_metre(m, f0, density)
	var want := k.x * k.y
	var s := sqrt(want / (a.x / a.y))
	var c := island_bounds(m, ch, isl).get_center()
	transform_faces(m, ch, isl, Transform2D(0.0, Vector2(s, s), 0.0, c - c * s))

## Pack Islands: shelf packing; `fit` scales everything into 0..1 (Blender),
## otherwise islands keep their size (World-Scale UV).
## Rotates an island to its smallest bounding rectangle (candidate angles =
## directions of its UV edges); the current angle wins ties. Pinned islands stay.
static func align_rotation(m, ch: int, isl: Dictionary) -> void:
	var pts := PackedVector2Array()
	var angles := {}
	for f in isl:
		var u := get_uv(m, ch, f)
		for k in u.size():
			if m.uv_pins.has(m.faces[f][k]):
				return
			pts.append(u[k])
			var d: Vector2 = u[(k + 1) % u.size()] - u[k]
			if d.length_squared() > 1e-16:
				angles[snappedf(fposmod(d.angle(), PI * 0.5), 1e-6)] = true
	if pts.size() < 3:
		return
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= pts.size()
	var best := 0.0
	var best_area := _rot_area(pts, 0.0) * (1.0 - 1e-4)
	for a in angles:
		var ar := _rot_area(pts, -float(a))
		if ar < best_area:
			best_area = ar
			best = -float(a)
	if best != 0.0:
		transform_faces(m, ch, isl, Transform2D(0.0, c) * Transform2D(best, Vector2.ZERO) * Transform2D(0.0, -c))

static func _rot_area(pts: PackedVector2Array, a: float) -> float:
	var r := Rect2()
	var xf := Transform2D(a, Vector2.ZERO)
	for i in pts.size():
		var p := xf * pts[i]
		r = Rect2(p, Vector2.ZERO) if i == 0 else r.expand(p)
	return r.size.x * r.size.y

static func pack(m, ch: int, parts: Array, fit := true, margin := 0.01, rotate := true) -> void:
	if parts.is_empty():
		return
	if rotate:
		for p in parts:
			align_rotation(m, ch, p)
	var boxes := []
	var area := 0.0
	for p in parts:
		var r := island_bounds(m, ch, p)
		boxes.append([p, r])
		area += (r.size.x + margin) * (r.size.y + margin)
	boxes.sort_custom(func(a, b): return a[1].size.y > b[1].size.y)
	var width := maxf(sqrt(area) * 1.15, 1e-6)
	for b in boxes:
		width = maxf(width, b[1].size.x + margin)
	var x := 0.0
	var y := 0.0
	var row_h := 0.0
	var maxx := 0.0
	for b in boxes:
		var r: Rect2 = b[1]
		if x > 0.0 and x + r.size.x > width:
			x = 0.0
			y += row_h + margin
			row_h = 0.0
		transform_faces(m, ch, b[0], Transform2D(0.0, Vector2.ONE, 0.0, Vector2(x, y) - r.position))
		x += r.size.x + margin
		maxx = maxf(maxx, x)
		row_h = maxf(row_h, r.size.y)
	if fit:
		var total := maxf(maxx, y + row_h)
		if total > 1e-12:
			var s := (1.0 - 2.0 * margin) / total
			for b in boxes:
				transform_faces(m, ch, b[0], Transform2D(0.0, Vector2(s, s), 0.0, Vector2(margin, margin)))


# ==============================================================================
# Stage 3B: Lightmap Pack, Stitch, Split, snapping helpers
# ==============================================================================

## Lightmap Pack: every face its own flat island (scale by area), packed into
## 0..1 with a margin. Meant for UV2 (lightmaps), works on any channel.
static func lightmap_pack(m, ch: int, faces: Dictionary, margin := 0.02) -> void:
	m.ensure_topology()
	var parts := []
	for f in faces:
		var one := {f: true}
		_planar(m, ch, one, m.face_normal(f))
		parts.append(one)
	average_scale(m, ch, parts)
	pack(m, ch, parts, true, margin, true)

## Stitch: selected corners (Vector2i(face, corner) keys) that share a mesh
## vertex but sit apart move to their midpoint. Returns how many vertices moved.
static func stitch(m, ch: int, keys: Dictionary) -> int:
	var by_vert := {}
	for key in keys:
		var v: int = m.faces[key.x][key.y]
		if not by_vert.has(v):
			by_vert[v] = []
		by_vert[v].append(key)
	var moved := 0
	for v in by_vert:
		var ks: Array = by_vert[v]
		if ks.size() < 2:
			continue
		var c := Vector2.ZERO
		var spread := false
		var p0: Vector2 = get_uv(m, ch, ks[0].x)[ks[0].y]
		for key in ks:
			var p: Vector2 = get_uv(m, ch, key.x)[key.y]
			c += p
			spread = spread or p.distance_to(p0) > 1e-6
		if not spread:
			continue
		c /= ks.size()
		for key in ks:
			var u := get_uv(m, ch, key.x)
			u[key.y] = c
			set_uv(m, ch, key.x, u)
		moved += 1
	return moved

## Split Selection: keeps only the corners of fully selected faces, so moving
## them no longer drags the neighbouring faces (Blender's Y).
static func split_selection(m, keys: Dictionary) -> Dictionary:
	var count := {}
	for key in keys:
		count[key.x] = count.get(key.x, 0) + 1
	var out := {}
	for f in count:
		if count[f] == m.faces[f].size():
			for k in m.faces[f].size():
				out[Vector2i(f, k)] = true
	return out
