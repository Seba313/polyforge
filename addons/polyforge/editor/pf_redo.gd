## PfRedo — Blender's "Adjust Last Operation" panel (F9): the parameters of
## the last operator, bottom-left in the 3D view. Changing a value undoes the
## operator and runs it again with the new values (one undo step stays).
## The panel disappears as soon as anything else changes the undo history.
@tool
extends RefCounted

var label := ""
var params: Array = []        # [{key, label, type: "float"/"int"/"bool", value, min, max}]
var run: Callable = Callable() # (values: Dictionary) -> void, from the state before, commits
var history: UndoRedo = null
var version := -1
var action_name := ""   # the history's current action when registered
var panel: PanelContainer = null
var _host: Control = null
var _collapsed := false
var _applying := false


func register(p_label: String, p_params: Array, p_run: Callable, p_history: UndoRedo) -> void:
	label = p_label
	params = p_params
	run = p_run
	history = p_history
	version = history.get_version() if history != null else -1
	action_name = history.get_current_action_name() if history != null else ""

func clear() -> void:
	run = Callable()
	params = []
	hide()

func is_current() -> bool:
	# Version alone is not enough: undo + a new step reaches the same number.
	return run.is_valid() and history != null and history.get_version() == version \
		and history.get_current_action_name() == action_name

func values() -> Dictionary:
	var out := {}
	for p in params:
		out[p["key"]] = p["value"]
	return out

## Applies new values: undo the operator, run it again.
func apply_values(new_values: Dictionary) -> void:
	if not is_current() or _applying:
		return
	_applying = true
	for p in params:
		if new_values.has(p["key"]):
			p["value"] = new_values[p["key"]]
	var keep_label := label
	var keep_params := params
	var keep_run := run
	var h := history
	h.undo()
	keep_run.call(values_of(keep_params))
	# The run registered again (new version); keep our parameter list.
	label = keep_label
	params = keep_params
	run = keep_run
	history = h
	version = h.get_version()
	action_name = h.get_current_action_name()
	_applying = false

static func values_of(ps: Array) -> Dictionary:
	var out := {}
	for p in ps:
		out[p["key"]] = p["value"]
	return out


# ==============================================================================
# Panel
# ==============================================================================

func show_in(host: Control) -> void:
	if host == null or not is_current():
		hide()
		return
	if panel != null and is_instance_valid(panel) and _host == host and panel.get_meta("label", "") == label + str(version):
		return
	hide()
	_host = host
	panel = PanelContainer.new()
	panel.name = "PolyforgeAdjustLastOperation"
	panel.set_meta("label", label + str(version))
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	panel.add_child(v)
	var head := Button.new()
	head.flat = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	head.text = ("▸ " if _collapsed else "▾ ") + label
	head.focus_mode = Control.FOCUS_NONE
	v.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.visible = not _collapsed
	v.add_child(grid)
	head.pressed.connect(func():
		_collapsed = not _collapsed
		grid.visible = not _collapsed
		head.text = ("▸ " if _collapsed else "▾ ") + label
		panel.reset_size()
		_place())
	for p in params:
		var l := Label.new()
		l.text = p["label"]
		grid.add_child(l)
		var key: String = p["key"]
		match p["type"]:
			"bool":
				var cb := CheckBox.new()
				cb.button_pressed = bool(p["value"])
				cb.focus_mode = Control.FOCUS_NONE
				cb.toggled.connect(func(on): apply_values({key: on}))
				grid.add_child(cb)
			_:
				var sb := SpinBox.new()
				sb.min_value = float(p.get("min", -100000.0))
				sb.max_value = float(p.get("max", 100000.0))
				sb.step = 1.0 if p["type"] == "int" else 0.001
				sb.allow_greater = p["type"] == "float"
				sb.allow_lesser = p["type"] == "float" and float(p.get("min", -1.0)) < 0.0
				sb.value = float(p["value"])
				sb.custom_minimum_size.x = 110
				sb.value_changed.connect(func(val): apply_values({key: int(val) if p["type"] == "int" else val}))
				grid.add_child(sb)
	host.add_child(panel)
	panel.reset_size()
	_place()

func _place() -> void:
	if panel == null or _host == null:
		return
	panel.position = Vector2(10, _host.size.y - panel.size.y - 34)

func hide() -> void:
	if panel != null and is_instance_valid(panel):
		panel.queue_free()
	panel = null
	_host = null
