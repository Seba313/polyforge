## GPU test of the Edit Mode overlay (needs a display, not --headless):
##   godot --path . --resolution 64x64 -s tests/gpu/test_overlay.gd
## Renders a cube with the overlay and checks: selected face tinted, selected
## edge orange, back edges hidden by depth, visible with X-Ray.
extends SceneTree

const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const PfOverlay := preload("res://addons/polyforge/editor/pf_overlay.gd")
const PfSession := preload("res://addons/polyforge/editor/pf_session.gd")

var fails := 0
var vp: SubViewport
var cam: Camera3D

func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		fails += 1

func _init() -> void:
	_run.call_deferred()

func px(p: Vector3, dy := 0) -> Color:
	var img := vp.get_texture().get_image()
	var s := cam.unproject_position(p)
	return img.get_pixel(int(s.x), int(s.y) + dy)

func orange(c: Color) -> bool:
	return c.r > 0.9 and c.g > 0.4 and c.g < 0.7 and c.b < 0.2

func _run() -> void:
	print("== Edit Mode overlay rendering (GPU)")
	vp = SubViewport.new()
	vp.size = Vector2i(200, 200)
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	var mi := MeshInstance3D.new()
	mi.mesh = PfBuild.build(PfPrim.cube())
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.5, 0.5, 0.5)
	mi.material_override = mat
	vp.add_child(mi)
	cam = Camera3D.new()
	cam.position = Vector3(0, 0, 6)
	vp.add_child(cam)
	await RenderingServer.frame_post_draw
	var s = PfSession.new()
	s.start(null, mi, PfPrim.cube())
	s.mode = 3
	var front := -1
	for fi in s.mesh.faces.size():
		if s.mesh.face_normal(fi).is_equal_approx(Vector3.BACK):
			front = fi
	s.select_many([front], "set")
	var ov = PfOverlay.new()
	ov.create(mi.get_world_3d().scenario)
	ov.update(s)
	for i in 5:
		await RenderingServer.frame_post_draw
	var c := px(Vector3(0.3, 0.3, 1))
	check(c.r > c.b + 0.1 and c.r > 0.55, "selected face tinted orange %s" % c)
	check(orange(px(Vector3(0, 1, 1))), "selected edge drawn orange")
	# Back edge (z = -1) lies behind the front face: hidden without X-Ray.
	var back := px(Vector3(0, 0.999, -1))
	var bg := px(Vector3(0, 0.5, -1))
	check(back.is_equal_approx(bg), "back edge hidden by the mesh")
	s.set_mode(1)
	s.deselect_all()
	s.xray = true
	ov.update(s)
	for i in 5:
		await RenderingServer.frame_post_draw
	var bx := px(Vector3(0, 0.999, -1))
	check(not bx.is_equal_approx(bg), "X-Ray: back edge visible through the mesh")
	var vtx := px(Vector3(1, 1, 1))
	check(vtx.r < 0.2 and vtx.g < 0.2, "vertex mode: unselected vertices drawn black (points) %s" % vtx)
	ov.free_all()
	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)
