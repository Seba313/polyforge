## PfMatPanel — material slots as a vertical strip right of the 3D view
## (toggled by the "Material" button): a thumbnail picker per slot with
## Assign / Select / Deselect / Remove icons under it, "Add" at the bottom.
@tool
extends PanelContainer

const PfOps2 := preload("res://addons/polyforge/core/pf_ops2.gd")
const PfI18n := preload("res://addons/polyforge/editor/pf_i18n.gd")
const ACTIONS := [["mat_assign", "ImportCheck", "Assign material to the selected faces"],
	["mat_select", "ToolSelect", "Select faces with this material"],
	["mat_deselect", "Close", "Deselect faces with this material"],
	["mat_slot_remove", "Remove", "Remove Material Slot"]]

var plugin: EditorPlugin = null
var _list: VBoxContainer
var _sig := ""
var _gap_host: Control = null

func _init() -> void:
	name = "PolyforgeMaterials"
	auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	var scale := EditorInterface.get_editor_scale()
	custom_minimum_size.x = 112.0 * scale
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override(&"separation", int(10 * scale))
	v.add_child(_list)
	v.add_child(HSeparator.new())
	var add := Button.new()
	add.text = PfI18n.t("Add")
	add.tooltip_text = PfI18n.t("Add Material Slot")
	add.icon = EditorInterface.get_editor_theme().get_icon(&"Add", &"EditorIcons")
	add.focus_mode = Control.FOCUS_NONE
	add.pressed.connect(func(): plugin.run_action("mat_slot_add"))
	v.add_child(add)

## Rebuilds the slot list when slots, materials or face counts changed.
func refresh() -> void:
	if plugin == null or plugin.session == null:
		return
	var m = plugin.session.mesh
	var n: int = PfOps2.slot_count(m)
	var used := {}
	for s in m.face_mat:
		used[s] = used.get(s, 0) + 1
	var sig := str(n, used, m.materials.map(func(x): x.get_instance_id() if x != null else 0))
	if sig == _sig:
		return
	_sig = sig
	for c in _list.get_children():
		c.queue_free()
	var theme := EditorInterface.get_editor_theme()
	var scale := EditorInterface.get_editor_scale()
	for i in n:
		var box := VBoxContainer.new()
		var label := Label.new()
		label.text = PfI18n.t("Slot %d · %d faces") % [i, used.get(i, 0)]
		label.add_theme_font_size_override(&"font_size", int(11 * scale))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(label)
		var picker := EditorResourcePicker.new()
		picker.base_type = "Material"
		picker.edited_resource = m.materials[i] if i < m.materials.size() else null
		picker.custom_minimum_size.y = 80.0 * scale
		picker.resource_changed.connect(func(r):
			plugin.active_slot = i
			plugin.run_action("mat_set", r))
		box.add_child(picker)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		for a in ACTIONS:
			if a[0] == "mat_slot_remove" and n <= 1:
				continue
			var b := Button.new()
			b.icon = theme.get_icon(a[1], &"EditorIcons")
			b.tooltip_text = PfI18n.t(a[2])
			b.flat = true
			b.focus_mode = Control.FOCUS_NONE
			var act: String = a[0]
			b.pressed.connect(func():
				plugin.active_slot = i
				plugin.run_action(act))
			row.add_child(b)
		box.add_child(row)
		_list.add_child(box)

# --- one outer Edit Mode frame with the 3D view (no left edge here) ----------

func _draw() -> void:
	if plugin == null or plugin.session == null:
		return
	var w := float(plugin.settings.get_pref("frame_width"))
	var col: Color = plugin.settings.get_pref("frame_color")
	draw_rect(Rect2(size.x - w, 0, w, size.y), col)
	draw_rect(Rect2(0, 0, size.x, w), col)
	draw_rect(Rect2(0, size.y - w, size.x, w), col)
	var vpc := EditorInterface.get_editor_viewport_3d(0).get_parent() as Control
	var a := get_parent() as Control
	while a != null and vpc != null and not a.is_ancestor_of(vpc):
		a = a.get_parent() as Control
	if a != _gap_host:
		if _gap_host != null and is_instance_valid(_gap_host) and _gap_host.draw.is_connected(_draw_gap):
			_gap_host.draw.disconnect(_draw_gap)
		_gap_host = a
		if a != null:
			a.draw.connect(_draw_gap)
	if _gap_host != null:
		_gap_host.queue_redraw()

func _draw_gap() -> void:
	if plugin == null or plugin.session == null or not is_visible_in_tree():
		return
	var vpc := EditorInterface.get_editor_viewport_3d(0).get_parent() as Control
	var w := float(plugin.settings.get_pref("frame_width"))
	var inv := _gap_host.get_global_transform().affine_inverse()
	var x0: float = (inv * vpc.get_global_rect().end).x
	var a: Vector2 = inv * get_global_rect().position
	if a.x > x0:
		_gap_host.draw_rect(Rect2(x0, a.y, a.x - x0, w), plugin.settings.get_pref("frame_color"))
		_gap_host.draw_rect(Rect2(x0, a.y + size.y - w, a.x - x0, w), plugin.settings.get_pref("frame_color"))

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED or what == NOTIFICATION_VISIBILITY_CHANGED:
		queue_redraw()
		if _gap_host != null and is_instance_valid(_gap_host):
			_gap_host.queue_redraw()
	elif what == NOTIFICATION_EXIT_TREE and _gap_host != null and is_instance_valid(_gap_host):
		if _gap_host.draw.is_connected(_draw_gap):
			_gap_host.draw.disconnect(_draw_gap)
		_gap_host.queue_redraw()
		_gap_host = null
