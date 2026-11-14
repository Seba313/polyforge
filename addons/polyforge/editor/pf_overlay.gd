## PfOverlay — Edit Mode wireframe drawn straight through the
## RenderingServer (no nodes in the scene, nothing saved): vertices as points,
## edges as lines, selected faces tinted. Blender colours: black / orange,
## active element white. With X-Ray everything draws on top, semi-transparent.
@tool
extends RefCounted

const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")

const COL_WIRE := Color(0.0, 0.0, 0.0, 1.0)
const COL_SEL := Color(1.0, 0.55, 0.05, 1.0)
const COL_ACTIVE := Color(1.0, 1.0, 1.0, 1.0)
const COL_FACE_SEL := Color(1.0, 0.55, 0.05, 0.22)
const COL_FACE_ACTIVE := Color(1.0, 1.0, 1.0, 0.18)
const COL_SHARP := Color(0.0, 0.85, 1.0, 1.0)
const COL_SEAM := Color(1.0, 0.1, 0.1, 1.0)
const COL_SHAPE := Color(0.35, 0.75, 1.0, 0.16)

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled, shadows_disabled%s;
uniform float point_size = 6.0;
uniform float bias = 1.002;
uniform float alpha_mul = 1.0;
void vertex() {
	POSITION = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	POSITION.z *= bias;   // reversed-Z: pull slightly toward the camera
	%s
}
void fragment() {
	vec3 c = COLOR.rgb;
	ALBEDO = mix(pow((c + vec3(0.055)) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
	ALPHA = COLOR.a * alpha_mul;
}
"""

const ORIENT_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled, shadows_disabled;
void fragment() {
	// Polyforge winding is Blender's (CCW from outside) = Godot back face.
	ALBEDO = FRONT_FACING ? vec3(0.8, 0.05, 0.05) : vec3(0.05, 0.2, 0.8);
	ALPHA = 0.45;
}
"""
const COL_NORMAL := Color(0.2, 0.9, 1.0, 1.0)
const KINDS := ["orient", "faces", "edges", "verts", "normals"]

## Optional overlays (Blender's Overlays popover), set by the plugin.
var show_orientation := false
var show_normals := false
var normal_size := 0.2

var _scenario := RID()
var _meshes := {}      # "verts"/"edges"/"faces" -> RID
var _instances := {}
var _mats := {}
var _xray := false


func create(scenario: RID) -> void:
	free_all()
	_scenario = scenario
	for kind in KINDS:
		var mrid := RenderingServer.mesh_create()
		var irid := RenderingServer.instance_create2(mrid, scenario)
		RenderingServer.instance_geometry_set_cast_shadows_setting(irid, RenderingServer.SHADOW_CASTING_SETTING_OFF)
		RenderingServer.instance_geometry_set_flag(irid, RenderingServer.INSTANCE_FLAG_IGNORE_OCCLUSION_CULLING, true)
		RenderingServer.instance_set_extra_visibility_margin(irid, 1e6)
		_meshes[kind] = mrid
		_instances[kind] = irid
	_build_materials()

func _build_materials() -> void:
	for kind in KINDS:
		var sh := Shader.new()
		# POINT_SIZE only for points: writing it stops triangles/lines from drawing.
		sh.code = ORIENT_SHADER if kind == "orient" else SHADER % [", depth_test_disabled" if _xray else "", "POINT_SIZE = point_size;" if kind == "verts" else ""]
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.render_priority = {"orient": 0, "faces": 1, "edges": 2, "normals": 2, "verts": 3}[kind]
		mat.set_shader_parameter("alpha_mul", 0.6 if _xray and kind != "verts" else 1.0)
		_mats[kind] = mat

func set_xray(on: bool) -> void:
	if on != _xray:
		_xray = on
		_build_materials()

func free_all() -> void:
	for k in _instances:
		RenderingServer.free_rid(_instances[k])
	for k in _meshes:
		RenderingServer.free_rid(_meshes[k])
	_instances.clear()
	_meshes.clear()
	_mats.clear()

func is_created() -> bool:
	return not _instances.is_empty()

func set_visible(on: bool) -> void:
	for k in _instances:
		RenderingServer.instance_set_visible(_instances[k], on)

func set_transform(xf: Transform3D) -> void:
	for k in _instances:
		RenderingServer.instance_set_transform(_instances[k], xf)


## Rebuilds the overlay geometry from the session state.
func update(s) -> void:
	if not is_created() or s == null or s.mesh == null:
		return
	set_xray(s.xray)
	var m = s.mesh
	var sv: Dictionary = s.selected_verts()
	var se: Dictionary = s.selected_edges()
	var sf: Dictionary = s.selected_faces()
	var act = s.active()
	# --- faces (selected tint) ---
	var fp := PackedVector3Array()
	var fc := PackedColorArray()
	if s.is_shape():
		# Collision shapes have no rendered surface: show every face lightly.
		for fi in m.faces.size():
			if sf.has(fi) or s.is_face_hidden(fi):
				continue
			var f: PackedInt32Array = m.faces[fi]
			for t in PfBuild.triangulate(m, fi):
				fp.append(m.verts[f[t]])
				fc.append(COL_SHAPE)
	for fi in sf:
		if s.is_face_hidden(fi):
			continue
		var col := COL_FACE_ACTIVE if (s.mode == 3 and act == fi) else COL_FACE_SEL
		var f: PackedInt32Array = m.faces[fi]
		var tris := PfBuild.triangulate(m, fi)
		for t in tris:
			fp.append(m.verts[f[t]])
			fc.append(col)
	_set_mesh(_meshes["faces"], Mesh.PRIMITIVE_TRIANGLES, fp, fc, _mats["faces"])
	# --- edges ---
	var ep := PackedVector3Array()
	var ec := PackedColorArray()
	for e in m.edges():
		if s.is_edge_hidden(e):
			continue
		var col := COL_WIRE
		if se.has(e):
			col = COL_ACTIVE if (s.mode == 2 and act == e) else COL_SEL
		elif m.seam_edges.has(e):
			col = COL_SEAM
		elif m.sharp_edges.has(e):
			col = COL_SHARP
		ep.append(m.verts[e.x])
		ep.append(m.verts[e.y])
		ec.append(col)
		ec.append(col)
	_set_mesh(_meshes["edges"], Mesh.PRIMITIVE_LINES, ep, ec, _mats["edges"])
	# --- vertices (vertex mode only, like Blender) ---
	var vp := PackedVector3Array()
	var vc := PackedColorArray()
	if s.mode == 1:
		for v in m.verts.size():
			if s.is_vert_hidden(v):
				continue
			vp.append(m.verts[v])
			vc.append(COL_ACTIVE if act == v else (COL_SEL if sv.has(v) else COL_WIRE))
	_set_mesh(_meshes["verts"], Mesh.PRIMITIVE_POINTS, vp, vc, _mats["verts"])
	# --- face orientation / normals (optional) ---
	var op := PackedVector3Array()
	var np := PackedVector3Array()
	for fi in m.faces.size():
		if s.is_face_hidden(fi):
			continue
		if show_orientation:
			var f: PackedInt32Array = m.faces[fi]
			for t in PfBuild.triangulate(m, fi):
				op.append(m.verts[f[t]])
		if show_normals:
			var c: Vector3 = m.face_center(fi)
			np.append(c)
			np.append(c + m.face_normal(fi) * normal_size)
	var oc := PackedColorArray()
	oc.resize(op.size())
	var nc := PackedColorArray()
	nc.resize(np.size())
	nc.fill(COL_NORMAL)
	_set_mesh(_meshes["orient"], Mesh.PRIMITIVE_TRIANGLES, op, oc, _mats["orient"])
	_set_mesh(_meshes["normals"], Mesh.PRIMITIVE_LINES, np, nc, _mats["normals"])
	set_transform(s.node.global_transform)

static func _set_mesh(mrid: RID, prim: int, pts: PackedVector3Array, cols: PackedColorArray, mat: ShaderMaterial) -> void:
	RenderingServer.mesh_clear(mrid)
	if pts.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	arr[Mesh.ARRAY_COLOR] = cols
	RenderingServer.mesh_add_surface_from_arrays(mrid, prim, arr)
	RenderingServer.mesh_surface_set_material(mrid, 0, mat.get_rid())
