## PfUi — Polyforge's widgets: the "Polyforge" menu in the 3D editor bar,
## the Edit Mode bar (Mesh Edit | UV Edit tabs, select modes, X-Ray, pivot,
## options), popup menus (context, pivot, Shift+A) and the settings dialog.
## Everything calls back into the plugin through plugin.run_action(name, arg).
@tool
extends RefCounted

const PfPrim := preload("res://addons/polyforge/core/pf_primitives.gd")
const PfKeymap := preload("res://addons/polyforge/editor/pf_keymap.gd")
const PfOrient := preload("res://addons/polyforge/editor/pf_orient.gd")
const PfOps2 := preload("res://addons/polyforge/core/pf_ops2.gd")
const PfI18n := preload("res://addons/polyforge/editor/pf_i18n.gd")

const PIVOTS := [["bbox", "Bounding Box Center"], ["cursor", "3D Cursor"], ["median", "Median Point"], ["individual", "Individual Origins"], ["active", "Active Element"]]
const CONTEXT_ITEMS := [
	["select_all", "Select All", "A"], ["select_none", "Select None", "Alt+A"], ["select_invert", "Invert", "Ctrl+I"],
	["select_linked", "Select Linked", "Ctrl+L"], ["select_more", "Select More", "Ctrl+Numpad +"], ["select_less", "Select Less", "Ctrl+Numpad -"],
	["-", "", ""],
	["hide", "Hide", "H"], ["hide_unselected", "Hide Unselected", "Shift+H"], ["reveal", "Reveal Hidden", "Alt+H"],
	["-", "", ""],
	["shade_smooth", "Shade Smooth", ""], ["shade_flat", "Shade Flat", ""],
	["mark_sharp", "Mark Sharp", ""], ["clear_sharp", "Clear Sharp", ""],
]
const DENSITIES := [128.0, 256.0, 512.0]
const OVERLAYS := [["overlay_stats", "Statistics"], ["overlay_edge_length", "Edge Length"],
	["overlay_face_orientation", "Face Orientation"], ["overlay_normals", "Face Normals"]]
const SNAP_TARGETS := [["increment", "Increment"], ["vertex", "Vertex"], ["edge", "Edge"], ["face", "Face"]]
const FALLOFFS := [["smooth", "Smooth"], ["sphere", "Sphere"], ["root", "Root"], ["inverse_square", "Inverse Square"],
	["sharp", "Sharp"], ["linear", "Linear"], ["constant", "Constant"]]

var plugin: EditorPlugin = null
var menu_btn: MenuButton
var add_popup: PopupMenu
var edit_bar: HBoxContainer
var tab_mesh: Button
var tab_uv: Button
var tab_paint: Button
var paint_box: HBoxContainer
var paint_col: ColorPickerButton
var paint_col2: ColorPickerButton
var paint_blend: OptionButton
var paint_radius: SpinBox
var paint_strength: SpinBox
var paint_mask: Button
var paint_front: Button
var paint_preview: Button
var mode_btns: Array[Button] = []
var xray_btn: Button
var focus_btn: Button
var pivot_btn: OptionButton
var orient_btn: OptionButton
var gizmo_btn: MenuButton
var orient_menu: PopupMenu
var op_menu: PopupMenu          # generic operator menu (X, M, Alt+E, Ctrl+V/E/F...)
var search_popup: PopupPanel
var search_edit: LineEdit
var search_list: ItemList
var merge_dist_dialog: ConfirmationDialog
var merge_dist_spin: SpinBox
var options_btn: MenuButton
var mat_btn: Button
var prop_btn: MenuButton
var overlays_btn: MenuButton
var snap_btn: MenuButton
var density_popup: PopupMenu
var context_menu: PopupMenu
var pivot_menu: PopupMenu
var add_menu: PopupMenu
var settings_dialog: ConfirmationDialog
var density_dialog: ConfirmationDialog
var density_spin: SpinBox
var save_dialog: EditorFileDialog
var _syncing := false
var _settings_widgets := {}


func build(p: EditorPlugin) -> void:
	plugin = p
	var base := EditorInterface.get_base_control()
	# --- Polyforge menu (always visible) ---
	menu_btn = MenuButton.new()
	menu_btn.text = "Polyforge"
	menu_btn.icon = _logo_icon()
	menu_btn.flat = false
	menu_btn.theme_type_variation = &"FlatMenuButton"
	var pm := menu_btn.get_popup()
	add_popup = PopupMenu.new()
	add_popup.name = "AddMesh"
	for i in PfPrim.KINDS.size():
		add_popup.add_item(PfPrim.LABELS[PfPrim.KINDS[i]], i)
	add_popup.id_pressed.connect(func(id): plugin.run_action("add_object", PfPrim.KINDS[id]))
	pm.add_child(add_popup)
	pm.add_submenu_node_item("Add Mesh", add_popup)
	pm.add_separator()
	pm.add_item("Toggle Edit Mode  (Tab)", 10)
	pm.add_item("Local View  (Numpad /)", 11)
	pm.add_separator()
	pm.add_item("Join Selected Meshes  (Ctrl+J)", 12)
	var bool_popup := PopupMenu.new()
	bool_popup.name = "Boolean"
	bool_popup.add_item("Union", 0)
	bool_popup.add_item("Difference", 1)
	bool_popup.add_item("Intersect", 2)
	bool_popup.id_pressed.connect(func(id): plugin.run_action("obj_boolean", ["union", "difference", "intersect"][id]))
	pm.add_child(bool_popup)
	pm.add_submenu_node_item("Boolean (active ← others)", bool_popup)
	pm.add_separator()
	pm.add_item("Settings…", 20)
	pm.add_item("Shortcuts…", 21)
	pm.id_pressed.connect(_on_main_menu)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, menu_btn)

	# --- Edit Mode bar (visible only in Edit Mode) ---
	edit_bar = HBoxContainer.new()
	edit_bar.visible = false
	var tg := ButtonGroup.new()
	tab_mesh = _toggle("Mesh Edit", "Mesh Edit workspace (Ctrl+PageUp/PageDown)", tg)
	tab_uv = _toggle("UV Edit", "UV Edit workspace: UV view next to the 3D view", tg)
	tab_mesh.button_pressed = true
	tab_mesh.toggled.connect(func(on): if on and not _syncing: plugin.run_action("tab", 0))
	tab_uv.toggled.connect(func(on): if on and not _syncing: plugin.run_action("tab", 1))
	tab_paint = _toggle("Paint", "Vertex Paint workspace: brush colours onto the mesh", tg)
	tab_paint.toggled.connect(func(on): if on and not _syncing: plugin.run_action("tab", 2))
	edit_bar.add_child(tab_mesh)
	edit_bar.add_child(tab_uv)
	edit_bar.add_child(tab_paint)
	edit_bar.add_child(VSeparator.new())
	_build_paint_box()
	var mg := ButtonGroup.new()
	for i in 3:
		var b := _toggle(["Vertex", "Edge", "Face"][i], PfI18n.t(["Vertex select mode (1)", "Edge select mode (2)", "Face select mode (3)"][i]), mg)
		var mode := i + 1
		b.toggled.connect(func(on): if on and not _syncing: plugin.run_action("set_mode", mode))
		mode_btns.append(b)
		edit_bar.add_child(b)
	edit_bar.add_child(VSeparator.new())
	xray_btn = _toggle("X-Ray", "Toggle X-Ray (Alt+Z)", null)
	xray_btn.toggled.connect(func(on): if not _syncing: plugin.run_action("xray_set", on))
	edit_bar.add_child(xray_btn)
	focus_btn = _toggle("Focus", "Dim everything except the edited object (Alt+F)", null)
	focus_btn.toggled.connect(func(on): if not _syncing: plugin.run_action("focus_set", on))
	edit_bar.add_child(focus_btn)
	pivot_btn = OptionButton.new()
	pivot_btn.flat = true
	pivot_btn.focus_mode = Control.FOCUS_NONE
	pivot_btn.tooltip_text = "Transform Pivot Point (.)"
	for i in PIVOTS.size():
		pivot_btn.add_item(PIVOTS[i][1], i)
	pivot_btn.item_selected.connect(func(i): if not _syncing: plugin.run_action("pivot", PIVOTS[i][0]))
	edit_bar.add_child(pivot_btn)
	orient_btn = OptionButton.new()
	orient_btn.flat = true
	orient_btn.focus_mode = Control.FOCUS_NONE
	orient_btn.tooltip_text = "Transform Orientation (,): first X/Y/Z press uses it, second press Global"
	for i in PfOrient.NAMES.size():
		orient_btn.add_item(PfOrient.LABELS[PfOrient.NAMES[i]], i)
	orient_btn.item_selected.connect(func(i): if not _syncing: plugin.run_action("orientation", PfOrient.NAMES[i]))
	edit_bar.add_child(orient_btn)
	gizmo_btn = MenuButton.new()
	gizmo_btn.text = "Gizmo"
	gizmo_btn.flat = false
	gizmo_btn.theme_type_variation = &"FlatMenuButton"
	gizmo_btn.tooltip_text = "Optional transform gizmo (Ctrl+`)"
	var gp := gizmo_btn.get_popup()
	gp.hide_on_checkable_item_selection = false
	gp.add_check_item("Move", 0)
	gp.add_check_item("Rotate", 1)
	gp.add_check_item("Scale", 2)
	gp.id_pressed.connect(func(id):
		var kind: String = ["move", "rotate", "scale"][id]
		plugin.run_action("gizmo_set", [kind, not bool(plugin.gizmo.get("show_" + kind))]))
	edit_bar.add_child(gizmo_btn)
	prop_btn = MenuButton.new()
	prop_btn.text = "Proportional"
	prop_btn.flat = false
	prop_btn.theme_type_variation = &"FlatMenuButton"
	prop_btn.tooltip_text = "Proportional Editing (O), falloff (Shift+O); wheel / PageUp / PageDown changes the size while transforming"
	var pp := prop_btn.get_popup()
	pp.hide_on_checkable_item_selection = false
	pp.add_check_item("Enabled (O)", 100)
	pp.add_check_item("Connected Only", 101)
	pp.add_separator("Mesh Symmetry")
	for a in 3:
		pp.add_check_item(PfI18n.t("Mirror %s") % "XYZ"[a], 200 + a)
	pp.add_separator("Falloff")
	for i in FALLOFFS.size():
		pp.add_radio_check_item(FALLOFFS[i][1], i)
	pp.id_pressed.connect(_on_proportional)
	edit_bar.add_child(prop_btn)
	snap_btn = MenuButton.new()
	snap_btn.flat = false
	snap_btn.theme_type_variation = &"FlatMenuButton"
	snap_btn.tooltip_text = "Snapping (Shift+Tab; Ctrl inverts while transforming), Snap To (Ctrl+Shift+Tab)"
	var snp := snap_btn.get_popup()
	snp.hide_on_checkable_item_selection = false
	snp.add_check_item("Snapping (Shift+Tab)", 100)
	snp.add_separator("Snap To")
	for i in SNAP_TARGETS.size():
		snp.add_radio_check_item(SNAP_TARGETS[i][1], i)
	snp.id_pressed.connect(func(id): plugin.run_action("snap_toggle" if id == 100 else "snap_target", null if id == 100 else SNAP_TARGETS[id][0]))
	edit_bar.add_child(snap_btn)
	overlays_btn = MenuButton.new()
	overlays_btn.text = "Overlays"
	overlays_btn.flat = false
	overlays_btn.theme_type_variation = &"FlatMenuButton"
	var ovp := overlays_btn.get_popup()
	ovp.hide_on_checkable_item_selection = false
	for i in OVERLAYS.size():
		ovp.add_check_item(OVERLAYS[i][1], i)
	ovp.id_pressed.connect(func(id): plugin.run_action("overlay", OVERLAYS[id][0]))
	edit_bar.add_child(overlays_btn)
	_build_material_panel(base)
	options_btn = MenuButton.new()
	options_btn.text = "Options"
	options_btn.flat = false
	options_btn.theme_type_variation = &"FlatMenuButton"
	var op := options_btn.get_popup()
	op.hide_on_checkable_item_selection = false
	op.add_check_item("Correct Face Attributes", 1)
	op.set_item_tooltip(0, "Moving vertices does not stretch the UVs (Blender option)")
	op.add_separator("World-Scale UV (optional)")
	op.add_check_item("World-Scale UV (this object)", 2)
	density_popup = PopupMenu.new()
	density_popup.name = "Density"
	density_popup.add_radio_check_item("Project default", 0)
	for i in DENSITIES.size():
		density_popup.add_radio_check_item("%d px/m" % DENSITIES[i], i + 1)
	density_popup.add_radio_check_item("Custom…", 9)
	density_popup.id_pressed.connect(_on_density)
	op.add_child(density_popup)
	op.add_submenu_node_item("Texel Density", density_popup)
	op.add_separator()
	op.add_item("Save Mesh As…", 5)
	op.id_pressed.connect(_on_options)
	op.about_to_popup.connect(sync)
	edit_bar.add_child(options_btn)
	plugin.add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, edit_bar)

	# --- popups ---
	context_menu = PopupMenu.new()
	for it in CONTEXT_ITEMS:
		if it[0] == "-":
			context_menu.add_separator()
		else:
			context_menu.add_item(it[1] + ("    " + it[2] if it[2] != "" else ""))
			context_menu.set_item_metadata(context_menu.item_count - 1, it[0])
	context_menu.index_pressed.connect(func(i): plugin.run_action(str(context_menu.get_item_metadata(i))))
	base.add_child(context_menu)
	pivot_menu = PopupMenu.new()
	for i in PIVOTS.size():
		pivot_menu.add_radio_check_item(PIVOTS[i][1], i)
	pivot_menu.id_pressed.connect(func(i): plugin.run_action("pivot", PIVOTS[i][0]))
	base.add_child(pivot_menu)
	orient_menu = PopupMenu.new()
	for i in PfOrient.NAMES.size():
		orient_menu.add_radio_check_item(PfOrient.LABELS[PfOrient.NAMES[i]], i)
	orient_menu.id_pressed.connect(func(i): plugin.run_action("orientation", PfOrient.NAMES[i]))
	base.add_child(orient_menu)
	op_menu = PopupMenu.new()
	op_menu.index_pressed.connect(func(i):
		var md = op_menu.get_item_metadata(i)
		if md is Array:
			plugin.run_action(md[0], md[1]))
	base.add_child(op_menu)
	_build_search(base)
	merge_dist_dialog = ConfirmationDialog.new()
	merge_dist_dialog.title = "Merge by Distance"
	merge_dist_spin = SpinBox.new()
	merge_dist_spin.min_value = 0.0
	merge_dist_spin.max_value = 100.0
	merge_dist_spin.step = 0.0001
	merge_dist_spin.value = 0.0001
	merge_dist_spin.suffix = "m"
	merge_dist_dialog.add_child(merge_dist_spin)
	merge_dist_dialog.confirmed.connect(func(): plugin.run_action("merge", ["distance", merge_dist_spin.value]))
	base.add_child(merge_dist_dialog)
	add_menu = PopupMenu.new()
	for i in PfPrim.KINDS.size():
		add_menu.add_item(PfPrim.LABELS[PfPrim.KINDS[i]], i)
	add_menu.id_pressed.connect(func(id): plugin.run_action("add_mesh_pick", PfPrim.KINDS[id]))
	base.add_child(add_menu)

	density_dialog = ConfirmationDialog.new()
	density_dialog.title = "Custom Texel Density"
	density_spin = SpinBox.new()
	density_spin.min_value = 1
	density_spin.max_value = 100000
	density_spin.suffix = "px/m"
	density_spin.value = 256
	density_dialog.add_child(density_spin)
	density_dialog.confirmed.connect(func(): plugin.run_action("texel_density", density_spin.value))
	base.add_child(density_dialog)

	save_dialog = EditorFileDialog.new()
	save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	save_dialog.add_filter("*.tres", "Text resource")
	save_dialog.add_filter("*.res", "Binary resource")
	save_dialog.file_selected.connect(func(path): plugin.run_action("save_mesh_as", path))
	base.add_child(save_dialog)
	_build_settings_dialog(base)
	# Blender names everywhere (the editor would translate only some words).
	for n in [menu_btn, edit_bar, context_menu, pivot_menu, orient_menu, op_menu, add_menu, search_popup, merge_dist_dialog, density_dialog, settings_dialog]:
		if n != null:
			n.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
			PfI18n.localize(n)

## The Polyforge logo in the editor's text colour (works with light themes).
func _logo_icon() -> Texture2D:
	var svg := FileAccess.get_file_as_string("res://addons/polyforge/icons/polyforge.svg")
	if svg.is_empty():
		return null
	var col := EditorInterface.get_editor_theme().get_color(&"font_color", &"Button")
	var img := Image.new()
	if img.load_svg_from_string(svg.replace("#ffffff", "#" + col.to_html(false)), 16.0 * EditorInterface.get_editor_scale() / 97.2) != OK:
		return null
	return ImageTexture.create_from_image(img)

func teardown() -> void:
	if menu_btn:
		plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, menu_btn)
		menu_btn.queue_free()
	if edit_bar:
		_flat_menu_row(false)
		plugin.remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, edit_bar)
		edit_bar.queue_free()
	for n in [context_menu, pivot_menu, orient_menu, op_menu, search_popup, merge_dist_dialog, add_menu, density_dialog, save_dialog, settings_dialog]:
		if n != null and is_instance_valid(n):
			n.queue_free()

func _toggle(text: String, tip: String, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = true
	b.theme_type_variation = &"FlatButton"
	accent_toggle(b)
	b.focus_mode = Control.FOCUS_NONE
	if group != null:
		b.button_group = group
	return b


## Refreshes widget states from the plugin.
func sync() -> void:
	_syncing = true
	var s = plugin.session
	edit_bar.visible = s != null
	_flat_menu_row(s != null)
	if s != null:
		# Collision shapes have no UVs / materials: no UV Edit tab, no Options.
		tab_uv.disabled = s.is_shape()
		tab_paint.disabled = s.is_shape()
		paint_box.visible = plugin.tab == 2 and not s.is_shape()
		for c in [pivot_btn, orient_btn, gizmo_btn, prop_btn, snap_btn]:
			c.visible = not paint_box.visible
		var pt = plugin.paint
		paint_col.color = pt.color
		paint_col2.color = pt.color2
		paint_blend.select(maxi(pt.BLENDS.map(func(b): return b[0]).find(pt.blend), 0))
		paint_radius.value = pt.radius
		paint_strength.value = pt.strength
		paint_mask.button_pressed = pt.mask
		paint_front.button_pressed = pt.front_only
		paint_preview.button_pressed = bool(plugin.settings.get_pref("paint_preview"))
		options_btn.visible = not s.is_shape()
		mat_btn.visible = not s.is_shape()
		var pp := prop_btn.get_popup()
		var on := bool(plugin.settings.get_pref("proportional"))
		var sym := ""
		for a in 3:
			if bool(plugin.settings.get_pref("mirror_axes")[a]):
				sym += "XYZ"[a]
		prop_btn.text = PfI18n.t("Proportional: On" if on else "Proportional") + (" · %s " % PfI18n.t("Mirror") + sym if sym != "" else "")
		pp.set_item_checked(pp.get_item_index(100), on)
		pp.set_item_checked(pp.get_item_index(101), bool(plugin.settings.get_pref("prop_connected")))
		for i in FALLOFFS.size():
			pp.set_item_checked(pp.get_item_index(i), FALLOFFS[i][0] == plugin.settings.get_pref("prop_falloff"))
		var son := bool(plugin.settings.get_pref("snap_on"))
		var stg := str(plugin.settings.get_pref("snap_target"))
		snap_btn.text = PfI18n.t("Snap: %s") % PfI18n.t(stg.capitalize()) if son else PfI18n.t("Snap")
		snap_btn.get_popup().set_item_checked(snap_btn.get_popup().get_item_index(100), son)
		for i in SNAP_TARGETS.size():
			snap_btn.get_popup().set_item_checked(snap_btn.get_popup().get_item_index(i), SNAP_TARGETS[i][0] == stg)
		for i in OVERLAYS.size():
			overlays_btn.get_popup().set_item_checked(i, bool(plugin.settings.get_pref(OVERLAYS[i][0])))
		var axes: Array = plugin.settings.get_pref("mirror_axes")
		for a in 3:
			pp.set_item_checked(pp.get_item_index(200 + a), bool(axes[a]))
		mat_btn.button_pressed = bool(plugin.settings.get_pref("material_panel"))
		tab_mesh.button_pressed = plugin.tab == 0 or s.is_shape()
		tab_uv.button_pressed = plugin.tab == 1 and not s.is_shape()
		tab_paint.button_pressed = plugin.tab == 2 and not s.is_shape()
		for i in 3:
			mode_btns[i].button_pressed = s.mode == i + 1
		xray_btn.button_pressed = s.xray
		focus_btn.button_pressed = bool(plugin.settings.get_pref("focus_mode"))
		for i in PIVOTS.size():
			if PIVOTS[i][0] == plugin.pivot_mode:
				pivot_btn.select(i)
		orient_btn.select(maxi(PfOrient.NAMES.find(plugin.orientation), 0))
		var gp := gizmo_btn.get_popup()
		for i in 3:
			gp.set_item_checked(i, bool(plugin.gizmo.get("show_" + ["move", "rotate", "scale"][i])))
		var op := options_btn.get_popup()
		op.set_item_checked(op.get_item_index(1), bool(plugin.settings.get_pref("correct_face_attributes")))
		op.set_item_checked(op.get_item_index(2), s.mesh.world_uv)
		var td: float = s.mesh.texel_density
		for i in density_popup.item_count:
			density_popup.set_item_checked(i, false)
		var id := 9
		if td <= 0.0:
			id = 0
		else:
			for i in DENSITIES.size():
				if is_equal_approx(td, DENSITIES[i]):
					id = i + 1
		density_popup.set_item_checked(density_popup.get_item_index(id), true)
		density_popup.set_item_text(density_popup.get_item_index(0), PfI18n.t("Project default (%d px/m)") % plugin.settings.project_texel_density())
		density_popup.set_item_text(density_popup.get_item_index(9), PfI18n.t("Custom… (%d px/m)") % td if id == 9 else PfI18n.t("Custom…"))
	_syncing = false

func _on_proportional(id: int) -> void:
	if id == 100:
		plugin.run_action("proportional", null)
	elif id == 101:
		plugin.run_action("prop_connected", null)
	elif id >= 200:
		plugin.run_action("symmetry", id - 200)
	else:
		plugin.run_action("prop_falloff", FALLOFFS[id][0])

func _on_main_menu(id: int) -> void:
	match id:
		10: plugin.run_action("toggle_edit")
		11: plugin.run_action("local_view")
		12: plugin.run_action("obj_join")
		20: open_settings()
		21: _show_shortcuts()

func _on_options(id: int) -> void:
	match id:
		1: plugin.run_action("correct_face_attributes", not bool(plugin.settings.get_pref("correct_face_attributes")))
		2: plugin.run_action("world_uv", not plugin.session.mesh.world_uv)
		5:
			save_dialog.current_file = (plugin.session.node.name if plugin.session else "mesh") + ".tres"
			save_dialog.popup_file_dialog()
	sync()

func _on_density(id: int) -> void:
	if id == 0:
		plugin.run_action("texel_density", 0.0)
	elif id == 9:
		density_spin.value = plugin.settings.density_for(plugin.session.mesh)
		density_dialog.popup_centered(Vector2i(320, 100))
	else:
		plugin.run_action("texel_density", DENSITIES[id - 1])
	sync()

## Pressed toggles use the editor accent colour, like Godot's toolbar tools.
static func accent_toggle(b: Button) -> void:
	var acc := EditorInterface.get_editor_theme().get_color(&"accent_color", &"Editor")
	for c in [&"font_pressed_color", &"font_hover_pressed_color"]:
		b.add_theme_color_override(c, acc)

## Godot wraps the 3D menu row in a panel; in Edit Mode the row is drawn flat
## (like the toolbar above it). Restored when leaving Edit Mode.
func _flat_menu_row(on: bool) -> void:
	var pc := edit_bar.get_parent().get_parent() as PanelContainer if edit_bar.get_parent() != null else null
	if pc == null:
		return
	if on:
		pc.add_theme_stylebox_override(&"panel", StyleBoxEmpty.new())
	else:
		pc.remove_theme_stylebox_override(&"panel")

## Paint tab controls: colours, blend, radius, strength, mask, front faces, preview.
func _build_paint_box() -> void:
	paint_box = HBoxContainer.new()
	var sc := EditorInterface.get_editor_scale()
	paint_col = ColorPickerButton.new()
	paint_col.tooltip_text = "Primary colour (LMB)"
	paint_col.custom_minimum_size = Vector2(28, 20) * sc
	paint_col.edit_alpha = false
	paint_col.color_changed.connect(func(c): plugin.run_action("paint_set", ["color", c]))
	paint_box.add_child(paint_col)
	paint_col2 = ColorPickerButton.new()
	paint_col2.tooltip_text = "Secondary colour (Ctrl+LMB); X swaps"
	paint_col2.custom_minimum_size = Vector2(20, 14) * sc
	paint_col2.edit_alpha = false
	paint_col2.color_changed.connect(func(c): plugin.run_action("paint_set", ["color2", c]))
	paint_box.add_child(paint_col2)
	paint_blend = OptionButton.new()
	paint_blend.flat = true
	paint_blend.focus_mode = Control.FOCUS_NONE
	paint_blend.tooltip_text = "Blend mode"
	for b in plugin.paint.BLENDS:
		paint_blend.add_item(b[1])
	paint_blend.item_selected.connect(func(i): plugin.run_action("paint_set", ["blend", plugin.paint.BLENDS[i][0]]))
	paint_box.add_child(paint_blend)
	paint_radius = SpinBox.new()
	paint_radius.min_value = 2
	paint_radius.max_value = 500
	paint_radius.suffix = "px"
	paint_radius.tooltip_text = "Brush radius (F)"
	paint_radius.value_changed.connect(func(v): if not _syncing: plugin.run_action("paint_set", ["radius", v]))
	paint_box.add_child(paint_radius)
	paint_strength = SpinBox.new()
	paint_strength.min_value = 0.0
	paint_strength.max_value = 1.0
	paint_strength.step = 0.05
	paint_strength.tooltip_text = "Brush strength (Shift+F)"
	paint_strength.value_changed.connect(func(v): if not _syncing: plugin.run_action("paint_set", ["strength", v]))
	paint_box.add_child(paint_strength)
	paint_mask = _toggle("Mask", "Paint only the selected faces (face selection masking)", null)
	paint_mask.toggled.connect(func(on): if not _syncing: plugin.run_action("paint_set", ["mask", on]))
	paint_box.add_child(paint_mask)
	paint_front = _toggle("Front Faces", "Paint only faces facing the view", null)
	paint_front.toggled.connect(func(on): if not _syncing: plugin.run_action("paint_set", ["front_only", on]))
	paint_box.add_child(paint_front)
	paint_preview = _toggle("Preview", "Show the vertex colours instead of the material while painting", null)
	paint_preview.toggled.connect(func(on): if not _syncing: plugin.run_action("paint_set", ["preview", on]))
	paint_box.add_child(paint_preview)
	paint_box.add_child(VSeparator.new())
	edit_bar.add_child(paint_box)

## "Material" toggles the material slot strip right of the 3D view (PfMatPanel).
func _build_material_panel(_base: Control) -> void:
	mat_btn = _toggle("Material", "Material slots panel: assign to selected faces, select by slot", null)
	mat_btn.toggled.connect(func(on): if not _syncing: plugin.run_action("mat_panel", on))
	edit_bar.add_child(mat_btn)

func popup_at(menu: PopupMenu, screen_pos: Vector2) -> void:
	menu.reset_size()
	menu.position = Vector2i(screen_pos)
	menu.popup()

func any_popup_open() -> bool:
	for p in [op_menu, context_menu, pivot_menu, orient_menu, add_menu, search_popup]:
		if p != null and is_instance_valid(p) and p.visible:
			return true
	return false

## Operator menu: items = [[label, action, arg], ["-"], ...] (Blender menus).
func popup_ops(title: String, items: Array, screen_pos: Vector2) -> void:
	op_menu.clear()
	op_menu.add_separator(PfI18n.t(title))
	for it in items:
		if it[0] == "-":
			op_menu.add_separator()
			continue
		op_menu.add_item(PfI18n.t(it[0]))
		var i := op_menu.item_count - 1
		op_menu.set_item_metadata(i, [it[1], it[2] if it.size() > 2 else null])
		if it.size() > 3 and it[3] == false:
			op_menu.set_item_disabled(i, true)
	popup_at(op_menu, screen_pos)

func _build_search(base: Control) -> void:
	search_popup = PopupPanel.new()
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(380, 320)
	search_edit = LineEdit.new()
	search_edit.placeholder_text = "Search operators…"
	search_list = ItemList.new()
	search_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(search_edit)
	v.add_child(search_list)
	search_popup.add_child(v)
	search_edit.text_changed.connect(func(_t): _fill_search())
	search_edit.text_submitted.connect(func(_t): _run_search(0 if search_list.get_selected_items().is_empty() else search_list.get_selected_items()[0]))
	search_list.item_activated.connect(_run_search)
	base.add_child(search_popup)

func open_search(screen_pos: Vector2) -> void:
	search_edit.text = ""
	_fill_search()
	search_popup.position = Vector2i(screen_pos)
	search_popup.popup()
	search_edit.grab_focus()

func _fill_search() -> void:
	search_list.clear()
	var q := search_edit.text.strip_edges().to_lower()
	for op in plugin.search_operators():
		var label := PfI18n.t(op[0])
		if q == "" or (op[0] as String).to_lower().contains(q) or label.to_lower().contains(q):
			search_list.add_item(label)
			search_list.set_item_metadata(search_list.item_count - 1, op)
	if search_list.item_count > 0:
		search_list.select(0)

func _run_search(i: int) -> void:
	if i < 0 or i >= search_list.item_count:
		return
	var op = search_list.get_item_metadata(i)
	search_popup.hide()
	plugin.run_action(op[1], op[2] if op.size() > 2 else null)

func popup_merge_distance() -> void:
	merge_dist_dialog.popup_centered(Vector2i(300, 100))

func popup_orientation(screen_pos: Vector2) -> void:
	for i in PfOrient.NAMES.size():
		orient_menu.set_item_checked(i, PfOrient.NAMES[i] == plugin.orientation)
	popup_at(orient_menu, screen_pos)

func popup_pivot(screen_pos: Vector2) -> void:
	for i in PIVOTS.size():
		pivot_menu.set_item_checked(i, PIVOTS[i][0] == plugin.pivot_mode)
	popup_at(pivot_menu, screen_pos)


# ==============================================================================
# Settings dialog
# ==============================================================================

func _build_settings_dialog(base: Control) -> void:
	settings_dialog = ConfirmationDialog.new()
	settings_dialog.title = "Polyforge Settings"
	settings_dialog.ok_button_text = "Save"
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 460)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)
	settings_dialog.add_child(scroll)

	v.add_child(_header("Edit Mode"))
	var g := GridContainer.new()
	g.columns = 2
	v.add_child(g)
	_settings_widgets["frame_color"] = _row(g, "Frame colour", ColorPickerButton.new())
	var w := SpinBox.new()
	w.min_value = 1
	w.max_value = 8
	_settings_widgets["frame_width"] = _row(g, "Frame width (px)", w)
	_settings_widgets["right_click_select"] = _row(g, "Right Click Select", CheckBox.new())
	var sn := SpinBox.new()
	sn.min_value = 0.001
	sn.max_value = 100
	sn.step = 0.001
	sn.suffix = "m"
	_settings_widgets["snap_increment"] = _row(g, "Ctrl snap increment", sn)
	_settings_widgets["local_view_frame"] = _row(g, "Local View frames the selection", CheckBox.new())

	v.add_child(_header("Object Mode shortcuts (optional)"))
	var g2 := GridContainer.new()
	g2.columns = 2
	v.add_child(g2)
	_settings_widgets["object_mode_shortcuts"] = _row(g2, "Enable Blender shortcuts in Object Mode", CheckBox.new())
	for action in PfKeymap.OBJECT:
		var le := LineEdit.new()
		le.placeholder_text = PfKeymap.text_of(PfKeymap.OBJECT, action)
		le.custom_minimum_size.x = 140
		_settings_widgets["obj:" + action] = _row(g2, PfKeymap.LABELS.get(action, action), le)

	v.add_child(_header("Project defaults (World-Scale UV, optional)"))
	var g3 := GridContainer.new()
	g3.columns = 2
	v.add_child(g3)
	_settings_widgets["project_world_uv"] = _row(g3, "New objects use World-Scale UV", CheckBox.new())
	var td := SpinBox.new()
	td.min_value = 1
	td.max_value = 100000
	td.suffix = "px/m"
	_settings_widgets["project_texel"] = _row(g3, "Texel density (128 / 256 / 512 / custom)", td)

	settings_dialog.confirmed.connect(_save_settings)
	base.add_child(settings_dialog)

func _header(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 15)
	return l

func _row(g: GridContainer, label: String, ctl: Control) -> Control:
	var l := Label.new()
	l.text = label
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_child(l)
	g.add_child(ctl)
	return ctl

func open_settings() -> void:
	var st = plugin.settings
	(_settings_widgets["frame_color"] as ColorPickerButton).color = st.get_pref("frame_color")
	(_settings_widgets["frame_width"] as SpinBox).value = st.get_pref("frame_width")
	(_settings_widgets["right_click_select"] as CheckBox).button_pressed = st.get_pref("right_click_select")
	(_settings_widgets["snap_increment"] as SpinBox).value = st.get_pref("snap_increment")
	(_settings_widgets["local_view_frame"] as CheckBox).button_pressed = st.get_pref("local_view_frame")
	(_settings_widgets["object_mode_shortcuts"] as CheckBox).button_pressed = st.get_pref("object_mode_shortcuts")
	var km: Dictionary = st.get_pref("object_keymap")
	for action in PfKeymap.OBJECT:
		(_settings_widgets["obj:" + action] as LineEdit).text = str(km.get(action, ""))
	(_settings_widgets["project_world_uv"] as CheckBox).button_pressed = st.world_uv_default()
	(_settings_widgets["project_texel"] as SpinBox).value = st.project_texel_density()
	settings_dialog.popup_centered()

func _save_settings() -> void:
	var st = plugin.settings
	st.set_pref("frame_color", (_settings_widgets["frame_color"] as ColorPickerButton).color)
	st.set_pref("frame_width", int((_settings_widgets["frame_width"] as SpinBox).value))
	st.set_pref("right_click_select", (_settings_widgets["right_click_select"] as CheckBox).button_pressed)
	st.set_pref("snap_increment", (_settings_widgets["snap_increment"] as SpinBox).value)
	st.set_pref("local_view_frame", (_settings_widgets["local_view_frame"] as CheckBox).button_pressed)
	st.set_pref("object_mode_shortcuts", (_settings_widgets["object_mode_shortcuts"] as CheckBox).button_pressed)
	var km := {}
	for action in PfKeymap.OBJECT:
		var t := (_settings_widgets["obj:" + action] as LineEdit).text.strip_edges()
		if t != "":
			km[action] = t
	st.set_pref("object_keymap", km)
	var wuv := (_settings_widgets["project_world_uv"] as CheckBox).button_pressed
	var ptd := (_settings_widgets["project_texel"] as SpinBox).value
	if wuv != st.world_uv_default() or not is_equal_approx(ptd, st.project_texel_density()):
		st.set_project_defaults(wuv, ptd)
	plugin.update_overlays()

func _show_shortcuts() -> void:
	var d := AcceptDialog.new()
	d.title = PfI18n.t("Polyforge shortcuts")
	var t := RichTextLabel.new()
	t.custom_minimum_size = Vector2(520, 480)
	t.bbcode_enabled = true
	var txt := PfI18n.t("[b]Always (3D viewport)[/b]\n")
	for a in PfKeymap.GLOBAL:
		txt += "%s   —   %s\n" % [PfKeymap.text_of(PfKeymap.GLOBAL, a), PfI18n.t(PfKeymap.LABELS.get(a, a))]
	txt += PfI18n.t("\n[b]Edit Mode[/b]\n")
	for a in PfKeymap.EDIT:
		txt += "%s   —   %s\n" % [PfKeymap.text_of(PfKeymap.EDIT, a), PfI18n.t(PfKeymap.LABELS.get(a, a))]
	txt += PfI18n.t("Click / Shift+click — select / extend   Alt+click — loop   Ctrl+Alt+click — ring\n")
	txt += PfI18n.t("LMB drag — box select (Shift: extend, Ctrl: subtract)   Right click — context menu (hold: fly)\n")
	txt += PfI18n.t("\n[b]Object Mode (optional, Settings)[/b]\n")
	var km: Dictionary = plugin.settings.get_pref("object_keymap")
	for a in PfKeymap.OBJECT:
		txt += "%s   —   %s\n" % [PfKeymap.text_of(PfKeymap.OBJECT, a, km), PfI18n.t(PfKeymap.LABELS.get(a, a))]
	t.text = txt
	d.add_child(t)
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)
	EditorInterface.get_base_control().add_child(d)
	d.popup_centered()
