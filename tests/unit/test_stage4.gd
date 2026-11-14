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
	_translations()
	_vertex_colors()
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

func _translations() -> void:
	print("== translations (i18n/*.po)")
	var tr: Translation = load("res://addons/polyforge/i18n/pl.po")
	check(tr != null and tr.get_message_count() > 400, "pl.po loads (%d messages)" % (tr.get_message_count() if tr else 0))
	check(tr.get_message("Extrude") == "Wyciągnij" and tr.get_message("EDIT MODE · %s") == "TRYB EDYCJI · %s", "Polish entries")
	check(tr.get_message("\n[b]Edit Mode[/b]\n") == "\n[b]Tryb edycji[/b]\n", "escaped newlines survive")
	var bad := 0
	for id in tr.get_message_list():
		if String(tr.get_message(id)).count("%") != String(id).count("%"):
			bad += 1
			print("    placeholder mismatch: ", id)
	check(bad == 0, "every translation keeps the same %-placeholders")

func _vertex_colors() -> void:
	print("== vertex colours (face corner)")
	var PfOps := load("res://addons/polyforge/core/pf_ops.gd")
	var c = PfPrim.cube()
	c.has_colors = true
	c.fill_colors()
	check(c.colors.size() == 6 and c.colors[0][0] == Color.WHITE, "unset colours default to white")
	for fi in c.faces.size():
		var a := PackedColorArray()
		for k in c.faces[fi].size():
			a.append(Color(0, 0, 1) if fi == 0 else Color(1, 0, 0))
		c.colors[fi] = a
	var d = PfMesh.new()
	d.from_dict(c.to_dict())
	check(d.has_colors and d.colors[0][1] == Color(0, 0, 1) and d.colors[1][0] == Color(1, 0, 0), "round trip keeps per-corner colours (hard edge)")
	var am: ArrayMesh = PfBuild.build(c)
	var arr := am.surface_get_arrays(0)
	check(arr[Mesh.ARRAY_COLOR] != null and (arr[Mesh.ARRAY_COLOR] as PackedColorArray).size() == (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), "ArrayMesh gets a COLOR array")
	var f0: PackedInt32Array = c.faces[0].duplicate()
	PfOps.flip(c, {0: true})
	check(c.colors[0].size() == 4 and c.faces[0] != f0, "flip keeps colours aligned with corners")
	var r: Dictionary = PfOps.extrude_individual(c, {1: true})
	c.fill_colors()
	check(not r.has("error") and c.colors[1][0] == Color(1, 0, 0) and c.colors[c.faces.size() - 1][0] == Color(1, 0, 0), "extrude: faces keep / inherit the neighbour colour")
	var ok: bool = c.validate() == ""
	for fi in c.faces.size():
		ok = ok and c.colors[fi].size() == c.faces[fi].size()
	check(ok, "after an operator every face has corner colours again (%s)" % c.validate())
