## PfSaveGuard — internal child of the node being edited (never saved, not
## shown in the Scene dock). Godot sends every node in the edited scene
## NOTIFICATION_EDITOR_PRE_SAVE / POST_SAVE around saving, whatever triggered
## the save: the guard completes the mesh (tangents + metadata) and takes the
## temporary gizmo lock off for the duration of the save.
@tool
extends Node

var pre_save: Callable = Callable()
var post_save: Callable = Callable()

func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE and pre_save.is_valid():
		pre_save.call()
	elif what == NOTIFICATION_EDITOR_POST_SAVE and post_save.is_valid():
		post_save.call()
