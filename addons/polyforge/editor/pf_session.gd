## PfSession — one Edit Mode session on a MeshInstance3D (its ArrayMesh) or a
## CollisionShape3D (Convex / Concave shape): the PfMesh being edited,
## selection (Blender semantics per select mode), hidden elements, writing the
## result back, undo snapshots.
@tool
extends RefCounted

const PfI18n := preload("res://addons/polyforge/editor/pf_i18n.gd")
const PfMesh := preload("res://addons/polyforge/core/pf_mesh.gd")
const PfBuild := preload("res://addons/polyforge/core/pf_build.gd")
const PfSelect := preload("res://addons/polyforge/core/pf_select.gd")
const PfBvh := preload("res://addons/polyforge/core/pf_bvh.gd")
const PfShape := preload("res://addons/polyforge/core/pf_shape.gd")
const PfOps2 := preload("res://addons/polyforge/core/pf_ops2.gd")

enum { VERTEX = 1, EDGE = 2, FACE = 3 }

signal changed   # geometry or selection changed (overlay refresh)

var plugin: EditorPlugin = null
var node: Node3D = null      # MeshInstance3D or CollisionShape3D
var mesh = null              # PfMesh
var amesh: ArrayMesh = null  # mesh target: the node's mesh (rebuilt in place)
var shape: Shape3D = null    # shape target: the node's shape (rewritten in place)
var kind := "mesh"           # "mesh", "convex", "concave"
var note := ""               # message for the user after a rebuild (e.g. hull)
## Multi-object edit: every edited MeshInstance3D with its mesh and the
## transform from its space into the combined (active object's) space. The
## active object is the last member; `node` is the active one.
var members: Array = []
var mode := VERTEX

# Primary selection of the current mode (Blender: switching modes converts).
var sel_v := {}
var sel_e := {}
var sel_f := {}
var history: Array = []      # selection order; last = active element
var hidden_v := {}
var hidden_f := {}
var xray := false

var _derived_valid := false
var _dv := {}
var _de := {}
var _df := {}
var _bvh = null
var _display_mesh: ArrayMesh = null


# ==============================================================================
# Lifecycle
# ==============================================================================

func start(p_plugin: EditorPlugin, n: Node3D, m) -> void:
	plugin = p_plugin
	node = n
	mesh = m
	if n is CollisionShape3D:
		shape = (n as CollisionShape3D).shape
		kind = PfShape.kind_of(shape)
	else:
		amesh = (n as MeshInstance3D).mesh as ArrayMesh
		kind = "mesh"
	_invalidate()

## Multi-object edit on several meshes (combined mesh, face tags = owner).
func start_multi(p_plugin: EditorPlugin, nodes: Array, m) -> void:
	start(p_plugin, nodes[nodes.size() - 1], m)
	members.clear()
	var inv: Transform3D = node.global_transform.affine_inverse()
	for n in nodes:
		members.append({"node": n, "amesh": (n as MeshInstance3D).mesh, "xf": inv * (n as Node3D).global_transform})

func is_multi() -> bool:
	return members.size() > 1

func is_shape() -> bool:
	return kind != "mesh"

func is_valid() -> bool:
	return node != null and is_instance_valid(node) and node.is_inside_tree() and (amesh != null or shape != null)

## The resource the session writes into (to detect it being replaced).
func target_resource() -> Resource:
	return shape if is_shape() else amesh

func current_node_resource() -> Resource:
	if node is CollisionShape3D:
		return (node as CollisionShape3D).shape
	return (node as MeshInstance3D).mesh

## Final build (tangents + metadata) and cleanup when leaving Edit Mode.
func finish() -> void:
	if is_valid():
		_set_display_override(false)
		rebuild(false)
		var res_list := [target_resource()]
		for mb in members:
			if mb["amesh"] != amesh:
				res_list.append(mb["amesh"])
		for res in res_list:
			if res != null and res.resource_path != "" and not res.resource_path.contains("::"):
				ResourceSaver.save(res)
	node = null


# ==============================================================================
# Selection
# ==============================================================================

func _invalidate() -> void:
	_derived_valid = false
	_bvh = null
	changed.emit()

func _selection_changed() -> void:
	_derived_valid = false
	changed.emit()

func primary() -> Dictionary:
	match mode:
		EDGE: return sel_e
		FACE: return sel_f
	return sel_v

func _ensure_derived() -> void:
	if _derived_valid:
		return
	match mode:
		VERTEX:
			_dv = sel_v
			_de = PfSelect.verts_to_edges(mesh, sel_v)
			_df = PfSelect.verts_to_faces(mesh, sel_v)
		EDGE:
			_de = sel_e
			_dv = PfSelect.edges_to_verts(sel_e)
			_df = PfSelect.edges_to_faces(mesh, sel_e)
		FACE:
			_df = sel_f
			_dv = PfSelect.faces_to_verts(mesh, sel_f)
			_de = PfSelect.faces_to_edges(mesh, sel_f)
	_derived_valid = true

func selected_verts() -> Dictionary:
	_ensure_derived()
	return _dv

func selected_edges() -> Dictionary:
	_ensure_derived()
	return _de

func selected_faces() -> Dictionary:
	_ensure_derived()
	return _df

func set_mode(new_mode: int) -> void:
	if new_mode == mode:
		return
	_ensure_derived()
	var v := _dv.duplicate()
	var e := _de.duplicate()
	var f := _df.duplicate()
	mode = new_mode
	sel_v = v if mode == VERTEX else {}
	sel_e = e if mode == EDGE else {}
	sel_f = f if mode == FACE else {}
	# Keep only active elements of the new kind in the history.
	history = history.filter(func(x): return primary().has(x))
	_selection_changed()

## All visible elements of the current mode.
func all_elements() -> Array:
	var out := []
	match mode:
		VERTEX:
			for v in mesh.verts.size():
				if not is_vert_hidden(v):
					out.append(v)
		EDGE:
			for e in mesh.edges():
				if not is_edge_hidden(e):
					out.append(e)
		FACE:
			for fi in mesh.faces.size():
				if not is_face_hidden(fi):
					out.append(fi)
	return out

func select_all() -> void:
	var p := primary()
	for x in all_elements():
		p[x] = true
	_selection_changed()

func deselect_all() -> void:
	primary().clear()
	history.clear()
	_selection_changed()

func invert() -> void:
	var p := primary()
	var nu := {}
	for x in all_elements():
		if not p.has(x):
			nu[x] = true
	p.clear()
	p.merge(nu)
	history.clear()
	_selection_changed()

## Replaces / extends the selection with `elems` (Array). `mode_op`:
## "set", "add", "sub".
func select_many(elems: Array, mode_op := "set") -> void:
	var p := primary()
	if mode_op == "set":
		p.clear()
		history.clear()
	for x in elems:
		if mode_op == "sub":
			p.erase(x)
			history.erase(x)
		else:
			p[x] = true
	_selection_changed()

## Blender click: plain = only this (active); shift = toggle/activate.
func click_select(elem, extend: bool) -> void:
	var p := primary()
	if elem == null:
		if not extend:
			deselect_all()
		return
	if not extend:
		p.clear()
		history.clear()
		p[elem] = true
		history.append(elem)
	elif not p.has(elem):
		p[elem] = true
		history.erase(elem)
		history.append(elem)
	elif active() != elem:
		history.erase(elem)
		history.append(elem)
	else:
		p.erase(elem)
		history.erase(elem)
	_selection_changed()

func active() -> Variant:
	var p := primary()
	for i in range(history.size() - 1, -1, -1):
		if p.has(history[i]):
			return history[i]
	return null


# ==============================================================================
# Hide / reveal
# ==============================================================================

func is_face_hidden(fi: int) -> bool:
	if hidden_f.has(fi):
		return true
	if hidden_v.is_empty():
		return false
	for v in mesh.faces[fi]:
		if hidden_v.has(v):
			return true
	return false

func is_vert_hidden(v: int) -> bool:
	if hidden_v.has(v):
		return true
	if hidden_f.is_empty() and hidden_v.is_empty():
		return false
	var vf: PackedInt32Array = mesh.vert_faces(v)
	if vf.is_empty():
		return false
	for fi in vf:
		if not is_face_hidden(fi):
			return false
	return true

func is_edge_hidden(e: Vector2i) -> bool:
	if hidden_f.is_empty() and hidden_v.is_empty():
		return false
	if is_vert_hidden(e.x) or is_vert_hidden(e.y):
		return true
	var ef: PackedInt32Array = mesh.edge_faces(e)
	if ef.is_empty():
		return false
	for fi in ef:
		if not is_face_hidden(fi):
			return false
	return true

func hidden_face_set() -> Dictionary:
	var out := {}
	if hidden_f.is_empty() and hidden_v.is_empty():
		return out
	for fi in mesh.faces.size():
		if is_face_hidden(fi):
			out[fi] = true
	return out

## H (unselected = false) / Shift+H (unselected = true).
func hide(unselected: bool) -> void:
	_ensure_derived()
	match mode:
		VERTEX:
			for v in mesh.verts.size():
				if _dv.has(v) != unselected:
					hidden_v[v] = true
		EDGE:
			var target := {}
			if unselected:
				for e in mesh.edges():
					if not _de.has(e):
						target[e] = true
			else:
				target = _de
			for e in target:
				for fi in mesh.edge_faces(e):
					hidden_f[fi] = true
		FACE:
			for fi in mesh.faces.size():
				if _df.has(fi) != unselected:
					hidden_f[fi] = true
	# Hidden elements are deselected.
	var p := primary()
	for x in p.keys():
		if (mode == VERTEX and is_vert_hidden(x)) or (mode == EDGE and is_edge_hidden(x)) or (mode == FACE and is_face_hidden(x)):
			p.erase(x)
	_after_hide_change()

## Alt+H: reveal everything and select what was revealed (Blender).
func reveal() -> void:
	var was_hidden := []
	for x in all_elements_including_hidden():
		if (mode == VERTEX and is_vert_hidden(x)) or (mode == EDGE and is_edge_hidden(x)) or (mode == FACE and is_face_hidden(x)):
			was_hidden.append(x)
	hidden_v.clear()
	hidden_f.clear()
	for x in was_hidden:
		primary()[x] = true
	_after_hide_change()

func all_elements_including_hidden() -> Array:
	match mode:
		EDGE: return mesh.edges().duplicate()
		FACE: return range(mesh.faces.size())
	return range(mesh.verts.size())

func _after_hide_change() -> void:
	_bvh = null
	_selection_changed()
	_set_display_override(not hidden_f.is_empty() or not hidden_v.is_empty())

## Hidden faces are left out of what the viewport draws, without touching the
## real mesh resource: the node's render instance gets a display mesh.
func _set_display_override(on: bool) -> void:
	if not is_valid() or is_shape() or is_multi():
		return
	var inst: RID = (node as VisualInstance3D).get_instance()
	if on:
		_display_mesh = PfBuild.build(mesh, _display_mesh if _display_mesh != null else ArrayMesh.new(), true, hidden_face_set(), false)
		RenderingServer.instance_set_base(inst, _display_mesh.get_rid())
	elif _display_mesh != null:
		RenderingServer.instance_set_base(inst, amesh.get_rid())
		_display_mesh = null

func has_display_override() -> bool:
	return _display_mesh != null


# ==============================================================================
# Geometry updates
# ==============================================================================

## Rebuilds the node's mesh. `fast` while dragging (no tangents / metadata).
func rebuild(fast := false) -> void:
	if not is_valid():
		return
	mesh.invalidate()
	if is_shape():
		if kind == "convex" and not fast and not _rehull():
			changed.emit()
			return
		PfShape.write(shape, mesh)
		_bvh = null
		_derived_valid = false
		changed.emit()
		return
	if is_multi():
		var to_local := []
		for mb in members:
			to_local.append((mb["xf"] as Transform3D).affine_inverse())
		var parts: Array = PfOps2.split_by_tags(mesh, members.size(), to_local, members.size() - 1)
		for i in members.size():
			if is_instance_valid(members[i]["node"]):
				PfBuild.build(parts[i], members[i]["amesh"], fast, {}, not fast)
		_bvh = null
		_derived_valid = false
		changed.emit()
		return
	PfBuild.build(mesh, amesh, fast, {}, not fast)
	if _display_mesh != null:
		PfBuild.build(mesh, _display_mesh, true, hidden_face_set(), false)
		RenderingServer.instance_set_base((node as VisualInstance3D).get_instance(), _display_mesh.get_rid())
	_bvh = null
	_derived_valid = false
	changed.emit()

## Convex shapes are always convex: after an edit the hull is recomputed and
## vertices that ended up inside it are dropped (selection remapped).
func _rehull() -> bool:
	var r: Dictionary = PfShape.rehull(mesh)
	if r.is_empty():
		note = "Convex shape is flat — not applied to the collision shape until it has volume again"
		return false
	var remap: Dictionary = r["remap"]
	var dropped: int = mesh.verts.size() - remap.size()
	var same_faces: bool = r["mesh"].faces.size() == mesh.faces.size() and dropped == 0
	mesh.from_dict(r["mesh"].to_dict())
	if dropped > 0:
		note = PfI18n.t("%d vertex(es) ended up inside the convex hull and were removed") % dropped
	var nv := {}
	for v in sel_v:
		if remap.has(v):
			nv[remap[v]] = true
	sel_v = nv
	var ne := {}
	for e in sel_e:
		if remap.has(e.x) and remap.has(e.y):
			var k := PfMesh.ekey(remap[e.x], remap[e.y])
			if mesh.edge_id(k) >= 0:
				ne[k] = true
	sel_e = ne
	if not same_faces:
		sel_f = {}
	var nh := []
	for x in history:
		if x is int and mode == VERTEX and remap.has(x):
			nh.append(remap[x])
		elif x is Vector2i and ne.has(x):
			nh.append(x)
		elif x is int and mode == FACE and same_faces:
			nh.append(x)
	history = nh
	hidden_v.clear()
	hidden_f.clear()
	return true

## Selection after a topology-changing operator (result of PfOps), expressed
## in the current select mode. Hidden state is cleared.
func set_selection_result(r: Dictionary) -> void:
	mesh.invalidate()
	hidden_v.clear()
	hidden_f.clear()
	_set_display_override(false)
	history.clear()
	var v: Dictionary = r.get("verts", {})
	var e: Dictionary = r.get("edges", {})
	var f: Dictionary = r.get("faces", {})
	sel_v = {}
	sel_e = {}
	sel_f = {}
	match mode:
		VERTEX:
			sel_v = v.duplicate()
			if sel_v.is_empty():
				sel_v = PfSelect.faces_to_verts(mesh, f)
				sel_v.merge(PfSelect.edges_to_verts(e))
		EDGE:
			sel_e = e.duplicate()
			if sel_e.is_empty():
				sel_e = PfSelect.faces_to_edges(mesh, f) if not f.is_empty() else PfSelect.verts_to_edges(mesh, v)
		FACE:
			sel_f = f.duplicate()
			if sel_f.is_empty():
				sel_f = PfSelect.verts_to_faces(mesh, v)
	_bvh = null
	_derived_valid = false
	changed.emit()

func bvh():
	if _bvh == null:
		_bvh = PfBvh.new()
		_bvh.build(mesh, hidden_face_set())
	return _bvh


# ==============================================================================
# Undo (whole-mesh snapshots, selection included — like Blender)
# ==============================================================================

func snapshot() -> Dictionary:
	return {
		"mesh": mesh.to_dict(),
		"mode": mode,
		"sel_v": sel_v.duplicate(), "sel_e": sel_e.duplicate(), "sel_f": sel_f.duplicate(),
		"history": history.duplicate(),
	}

func restore(snap: Dictionary) -> void:
	mesh.from_dict(snap["mesh"])
	mode = int(snap.get("mode", mode))
	sel_v = (snap.get("sel_v", {}) as Dictionary).duplicate()
	sel_e = (snap.get("sel_e", {}) as Dictionary).duplicate()
	sel_f = (snap.get("sel_f", {}) as Dictionary).duplicate()
	history = (snap.get("history", []) as Array).duplicate()
	hidden_v.clear()
	hidden_f.clear()
	_set_display_override(false)
	rebuild(false)

## Registers an already-applied change as one undo step.
func commit_undo(action: String, before: Dictionary) -> void:
	if plugin == null or not is_valid():
		return
	rebuild(false)
	var after := snapshot()
	var ur := plugin.get_undo_redo()
	ur.create_action("Polyforge: " + action, UndoRedo.MERGE_DISABLE, node)
	if is_multi():
		var ids := []
		var xfs := []
		for mb in members:
			ids.append((mb["node"] as Node).get_instance_id())
			xfs.append(mb["xf"])
		ur.add_do_method(plugin, "_pf_restore_multi", ids, xfs, after)
		ur.add_undo_method(plugin, "_pf_restore_multi", ids, xfs, before)
	else:
		ur.add_do_method(plugin, "_pf_restore", node.get_instance_id(), after)
		ur.add_undo_method(plugin, "_pf_restore", node.get_instance_id(), before)
	ur.commit_action(false)


# ==============================================================================
# Helpers for operators
# ==============================================================================

## Mesh-local position of the active element (or null).
func active_position() -> Variant:
	var a = active()
	if a == null:
		return null
	match mode:
		VERTEX: return mesh.verts[a]
		EDGE: return (mesh.verts[a.x] + mesh.verts[a.y]) * 0.5
		FACE: return mesh.face_center(a)
	return null
