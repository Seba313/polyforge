## Generates res://test_scene.tscn: a Polyforge cube, a Godot BoxMesh (Tab
## converts it), a floor, a light and an environment.
##   godot --headless --path . -s tools/make_test_scene.gd
extends SceneTree

const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")

func _init() -> void:
	var root := Node3D.new()
	root.name = "TestScene"
	var cube := MeshInstance3D.new()
	cube.name = "Cube"
	cube.mesh = PfBuild.build(PfPrim.cube())
	cube.position = Vector3(0, 1, 0)
	_add(root, cube)
	var box := MeshInstance3D.new()
	box.name = "GodotBox"
	box.mesh = BoxMesh.new()
	box.position = Vector3(3, 0.5, 0)
	_add(root, box)
	# Collision shapes editable in Edit Mode (concave trimesh + convex hull).
	var body := StaticBody3D.new()
	body.name = "Body"
	body.position = Vector3(-3, 0, 0)
	_add(root, body)
	var concave := CollisionShape3D.new()
	concave.name = "ConcaveShape"
	concave.shape = BoxMesh.new().create_trimesh_shape()
	concave.position = Vector3(0, 0.5, 0)
	body.add_child(concave)
	concave.owner = root
	var convex := CollisionShape3D.new()
	convex.name = "ConvexShape"
	var cyl := CylinderMesh.new()
	cyl.radial_segments = 16
	cyl.rings = 0
	convex.shape = cyl.create_convex_shape()
	convex.position = Vector3(0, 1, 3)
	body.add_child(convex)
	convex.owner = root
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "Floor"
	var pm := PlaneMesh.new()
	pm.size = Vector2(12, 12)
	floor_mi.mesh = pm
	_add(root, floor_mi)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	_add(root, sun)
	var env := WorldEnvironment.new()
	env.name = "WorldEnvironment"
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_SKY
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = ProceduralSkyMaterial.new()
	_add(root, env)
	var ps := PackedScene.new()
	ps.pack(root)
	var err := ResourceSaver.save(ps, "res://test_scene.tscn")
	print("make_test_scene: ", "OK" if err == OK else "error %d" % err)
	quit(err)

func _add(root: Node, n: Node) -> void:
	root.add_child(n)
	n.owner = root
