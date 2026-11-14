## PfPaint — Vertex Paint (Paint tab): brush strokes on face-corner colours,
## Blender-style: LMB paints the primary colour, Ctrl+LMB the secondary one,
## F / Shift+F radius / strength, S samples, Shift+K fills, X swaps colours.
@tool
extends RefCounted

const PfPicking := preload("res://addons/polyforge/editor/pf_picking.gd")
const BLENDS := [["mix", "Mix"], ["add", "Add"], ["subtract", "Subtract"], ["multiply", "Multiply"]]

var color := Color(1, 1, 1)
var color2 := Color(0, 0, 0)
var radius := 50.0          # screen px (before editor scale)
var strength := 1.0
var blend := "mix"
var mask := false           # only the selected faces (Blender's face selection masking)
var front_only := true
var stroking := false
var _before: Dictionary = {}
var _secondary := false

func begin(s, cam: Camera3D, mouse: Vector2, secondary: bool, mirror_x: bool) -> void:
	s.mesh.has_colors = true
	s.mesh.fill_colors()
	_before = s.snapshot()
	_secondary = secondary
	stroking = true
	dab(s, cam, mouse, mirror_x)

func end(s) -> void:
	if stroking:
		stroking = false
		s.commit_undo("Paint Stroke", _before)

## One brush dab at `mouse`: corners of vertices under the brush blend towards
## the brush colour (smooth falloff).
func dab(s, cam: Camera3D, mouse: Vector2, mirror_x: bool) -> void:
	var m = s.mesh
	var gx: Transform3D = s.node.global_transform
	var eye: Vector3 = gx.affine_inverse() * cam.global_position
	var r := radius * EditorInterface.get_editor_scale()
	var w := {}
	for v in m.verts.size():
		if s.is_vert_hidden(v):
			continue
		var pts: Array = [m.verts[v]]
		if mirror_x:
			pts.append(Vector3(-m.verts[v].x, m.verts[v].y, m.verts[v].z))
		var best := 0.0
		for p in pts:
			var sp = PfPicking.project(s, cam, p)
			if sp == null:
				continue
			var d := (sp as Vector2).distance_to(mouse)
			if d >= r or (not s.xray and s.bvh().occluded(eye, p)):
				continue
			var t := 1.0 - d / r
			best = maxf(best, t * t * (3.0 - 2.0 * t))
		if best > 0.0:
			w[v] = best
	if w.is_empty():
		return
	var col := color2 if _secondary else color
	var sf: Dictionary = s.selected_faces() if mask else {}
	for fi in m.faces.size():
		if (mask and not sf.has(fi)) or s.is_face_hidden(fi):
			continue
		if front_only and not s.xray and m.face_normal(fi).dot(eye - m.face_center(fi)) <= 0.0:
			continue
		var f: PackedInt32Array = m.faces[fi]
		var c: PackedColorArray = m.colors[fi]
		var changed := false
		for k in f.size():
			if w.has(f[k]):
				c[k] = _blend(c[k], col, float(w[f[k]]) * strength)
				changed = true
		if changed:
			m.colors[fi] = c
	s.rebuild(true)

func _blend(a: Color, b: Color, t: float) -> Color:
	var r: Color
	match blend:
		"add": r = a + b * t
		"subtract": r = a - b * t
		"multiply": r = a.lerp(a * b, t)
		_: r = a.lerp(b, t)
	return Color(clampf(r.r, 0, 1), clampf(r.g, 0, 1), clampf(r.b, 0, 1), 1.0)

## S: the colour under the mouse (nearest corner of the face hit) -> brush.
func sample(s, cam: Camera3D, mouse: Vector2) -> bool:
	var r := PfPicking._to_local(s, cam, mouse)
	var hit: Dictionary = s.bvh().raycast(r[0], r[1])
	if hit.is_empty():
		return false
	var m = s.mesh
	m.fill_colors()
	var fi: int = hit["face"]
	var best := 0
	for k in m.faces[fi].size():
		if (m.verts[m.faces[fi][k]] as Vector3).distance_to(hit["point"]) < (m.verts[m.faces[fi][best]] as Vector3).distance_to(hit["point"]):
			best = k
	color = m.colors[fi][best] if m.has_colors else Color.WHITE
	return true

## Shift+K (Set Vertex Colors): the selected faces (all when none) get the
## brush colour — sharp borders at their edges.
func fill(s) -> void:
	var m = s.mesh
	m.has_colors = true
	m.fill_colors()
	var before: Dictionary = s.snapshot()
	var sf: Dictionary = s.selected_faces()
	for fi in m.faces.size():
		if (sf.is_empty() or sf.has(fi)) and not s.is_face_hidden(fi):
			var c := PackedColorArray()
			c.resize(m.faces[fi].size())
			c.fill(color)
			m.colors[fi] = c
	s.commit_undo("Set Vertex Colors", before)
