## PfLocalView — Blender's Local View (Numpad /): only the selected objects
## (and their children) stay visible in the editor viewport.
##
## Hiding goes straight to the RenderingServer: node `visible` properties are
## never touched, so the scene is not marked as modified, nothing reaches the
## saved file or the undo history. Lights keep lighting the objects.
@tool
extends RefCounted

var active := false
var _keep := {}        # instance id -> true
var _hidden := {}      # instance RID -> VisualInstance3D (weak: checked on use)
var _root: Node = null


func enter(root: Node, selected: Array) -> bool:
	if root == null or selected.is_empty():
		return false
	_root = root
	_keep.clear()
	for n in selected:
		if n is Node:
			_keep[n.get_instance_id()] = true
			for c in (n as Node).find_children("*", "", true, false):
				_keep[c.get_instance_id()] = true
	active = true
	refresh()
	return true

## Re-applies hiding (Godot may restore visibility when a node changes).
func refresh() -> void:
	if not active or _root == null or not is_instance_valid(_root):
		return
	for vi in _root.find_children("*", "VisualInstance3D", true, false):
		if vi is Light3D or _keep.has(vi.get_instance_id()):
			continue
		var rid: RID = (vi as VisualInstance3D).get_instance()
		if rid.is_valid():
			RenderingServer.instance_set_visible(rid, false)
			_hidden[rid] = vi

func exit() -> void:
	for rid in _hidden:
		var vi = _hidden[rid]
		if is_instance_valid(vi) and (vi as VisualInstance3D).get_instance() == rid:
			RenderingServer.instance_set_visible(rid, (vi as VisualInstance3D).is_visible_in_tree())
	_hidden.clear()
	_keep.clear()
	_root = null
	active = false

func is_hidden(n: Node) -> bool:
	return active and n is VisualInstance3D and _hidden.has((n as VisualInstance3D).get_instance())
