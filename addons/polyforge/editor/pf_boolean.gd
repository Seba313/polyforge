## PfBoolean — Union / Difference / Intersect through Godot's CSG (Manifold,
## C++). The inputs are Polyforge meshes in one common space; the result comes
## back as a PfMesh (coplanar triangle pairs joined into quads).
@tool
extends RefCounted

const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const PfOps2 := preload("res://addons/polyforge/core/pf_ops2.gd")

const OPS := {"union": CSGShape3D.OPERATION_UNION, "difference": CSGShape3D.OPERATION_SUBTRACTION, "intersect": CSGShape3D.OPERATION_INTERSECTION}

## Async: `await PfBoolean.compute(host, base, cutters, "difference")`.
## Returns {"mesh": PfMesh} or {"error": text}.
static func compute(host: Node, base, cutters: Array, op: String) -> Dictionary:
	var open := PfOps2.open_edges(base)
	for c in cutters:
		open += PfOps2.open_edges(c)
	if open > 0:
		return {"error": "Boolean needs closed meshes (%d open edge(s))" % open}
	var comb := CSGCombiner3D.new()
	host.add_child(comb)
	var a := CSGMesh3D.new()
	a.mesh = PfBuild.build(base, null, false, {}, false)
	comb.add_child(a)
	for c in cutters:
		var b := CSGMesh3D.new()
		b.mesh = PfBuild.build(c, null, false, {}, false)
		b.operation = OPS.get(op, CSGShape3D.OPERATION_SUBTRACTION)
		comb.add_child(b)
	await host.get_tree().process_frame
	var baked: ArrayMesh = comb.bake_static_mesh()
	if baked == null:
		await host.get_tree().process_frame
		baked = comb.bake_static_mesh()
	comb.queue_free()
	if baked == null or baked.get_surface_count() == 0:
		return {"error": "Boolean result is empty"}
	var mats: Array = base.materials.duplicate()
	for c in cutters:
		for mt in c.materials:
			if not mats.has(mt):
				mats.append(mt)
	var res = PfOps2.from_array_mesh(baked, mats)
	res.world_uv = base.world_uv
	res.texel_density = base.texel_density
	return {"mesh": res}
