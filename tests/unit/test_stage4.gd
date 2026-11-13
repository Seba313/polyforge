## Stage 4 core tests (headless):
##   godot --headless --path . -s tests/unit/test_stage4.gd
extends SceneTree

const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfOps2 := preload("res://addons/polyforge/core/pf_ops2.gd")
const PfSelect := preload("res://addons/polyforge/core/pf_select.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")

var fails := 0

func check(cond: bool, msg: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + msg)
	if not cond:
		fails += 1

func _init() -> void:
	_material_slots()
	_select_similar()
	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)

func _material_slots() -> void:
	print("== material slots")
	var c = PfPrim.cube()
	c.materials = []
	check(PfOps2.slot_count(c) == 1, "empty slot list still has slot 0")
	var red := StandardMaterial3D.new()
	var s1: int = PfOps2.add_slot(c)
	PfOps2.set_slot_material(c, s1, red)
	PfOps2.assign_slot(c, {0: true, 1: true}, s1)
	var am: ArrayMesh = PfBuild.build(c)
	check(s1 == 1 and am.get_surface_count() == 2 and am.surface_get_material(1) == red, "slot 1 with 2 faces -> second surface with its material")
	var s2: int = PfOps2.add_slot(c)
	PfOps2.assign_slot(c, {2: true}, s2)
	PfOps2.remove_slot(c, 1)
	check(PfOps2.slot_count(c) == 2 and c.face_mat[0] == 0 and c.face_mat[2] == 1, "removing slot 1: its faces fall back to slot 0, slot 2 becomes 1")

func _select_similar() -> void:
	print("== select similar")
	var g = PfPrim.grid(4, 4, 2.0)
	var c = PfPrim.cube()
	c.face_mat[3] = 1
	c.face_mat[5] = 1
	check(PfSelect.similar(c, PfSelect.Mode.FACE, {3: true}, "material").keys().size() == 2, "Material: both slot-1 faces")
	check(PfSelect.similar(c, PfSelect.Mode.FACE, {0: true}, "sides").size() == 6, "Polygon Sides: all quads")
	check(PfSelect.similar(c, PfSelect.Mode.FACE, {0: true}, "normal").size() == 1, "Normal: only the face itself on a cube")
	check(PfSelect.similar(g, PfSelect.Mode.FACE, {0: true}, "coplanar").size() == g.faces.size(), "Co-planar: whole flat grid")
	check(PfSelect.similar(c, PfSelect.Mode.EDGE, {c.edges()[0]: true}, "length").size() == 12, "Length: all cube edges")
	check(PfSelect.similar(c, PfSelect.Mode.EDGE, {c.edges()[0]: true}, "direction").size() == 4, "Direction: 4 parallel cube edges")
	check(PfSelect.similar(c, PfSelect.Mode.VERTEX, {0: true}, "edges").size() == 8, "Connecting Edges: all cube corners")
