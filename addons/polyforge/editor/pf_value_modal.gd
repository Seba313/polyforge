## PfValueModal — Blender-style modal for operators driven by one value
## (Inset thickness, Shrink/Fatten distance): the mouse distance to the pivot
## sets the value, digits type it, Ctrl snaps, Shift is precise,
## LMB / Enter confirm, RMB / Esc cancel. Extra keys (e.g. I = individual)
## go to `on_key`.
@tool
extends RefCounted

const PfI18n := preload("res://addons/polyforge/editor/pf_i18n.gd")

signal finished(committed: bool)

const PRECISION := 0.1

var active := false
var label := ""
## "inset": toward the pivot = more; "fatten": away = more (may go negative);
## "width": away = more (>= 0); "factor": along `axis_screen`, -1..1.
var kind := "inset"
var value := 0.0
var numeric := ""
var snap_increment := 0.1
var apply: Callable = Callable()   # (value: float) -> void
var on_key: Callable = Callable()  # (keycode: int) -> bool
var on_wheel: Callable = Callable() # (step: int) -> void (segments / cuts)
var axis_screen := Vector2.RIGHT    # "factor": screen vector of the full range
var name_override := ""             # header value name
var extra := ""                    # shown in the header (e.g. "Individual")
var swallow_lmb_release := false

var _camera: Camera3D = null
var _pivot := Vector3.ZERO
var _start := Vector2.ZERO
var _mouse := Vector2.ZERO
var _last := Vector2.ZERO
var _precision := false
var _snap := false
var _wpp := 0.01


func begin(p_label: String, p_kind: String, camera: Camera3D, mouse: Vector2, pivot_world: Vector3, p_apply: Callable) -> void:
	label = p_label
	kind = p_kind
	_camera = camera
	_pivot = pivot_world
	_start = mouse
	_mouse = mouse
	_last = mouse
	apply = p_apply
	numeric = ""
	extra = ""
	name_override = ""
	on_wheel = Callable()
	value = 0.0
	_precision = false
	_snap = false
	const PfGizmo := preload("res://addons/polyforge/editor/pf_gizmo.gd")
	_wpp = PfGizmo.world_per_px(camera, pivot_world)
	active = true
	_update()

func _pivot_screen() -> Vector2:
	return _camera.unproject_position(_pivot) if _camera != null else Vector2.ZERO

func _update() -> void:
	var num := _numeric()
	if num != null:
		value = float(num)
	else:
		if kind == "factor":
			var l2 := axis_screen.length_squared()
			value = clampf((_mouse - _start).dot(axis_screen) / maxf(l2, 1.0), -1.0, 1.0)
			if _snap:
				value = snappedf(value, 0.1 * (0.1 if _precision else 1.0))
		else:
			var ps := _pivot_screen()
			var d0 := _start.distance_to(ps)
			var d := _mouse.distance_to(ps)
			value = ((d0 - d) if kind == "inset" else (d - d0)) * _wpp
			if kind == "inset" or kind == "width":
				value = maxf(value, 0.0)
			if _snap:
				value = snappedf(value, snap_increment * (0.1 if _precision else 1.0))
	if apply.is_valid():
		apply.call(value)

func _numeric() -> Variant:
	if numeric.is_empty() or numeric in ["-", ".", "-."]:
		return null
	return numeric.to_float()

func handle_input(event: InputEvent) -> bool:
	if not active:
		return false
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var delta := mm.position - _last
		_last = mm.position
		_precision = mm.shift_pressed
		_snap = mm.ctrl_pressed
		_mouse += delta * (PRECISION if _precision else 1.0)
		_update()
		return true
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return true
		if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			if on_wheel.is_valid():
				on_wheel.call(1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
				_update()
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT:
			swallow_lmb_release = true
			_finish(true)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_finish(false)
		return true
	if event is InputEventKey:
		var k := event as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if code == KEY_CTRL or code == KEY_SHIFT:
			if code == KEY_CTRL:
				_snap = k.pressed
			else:
				_precision = k.pressed
			_update()
			return true
		if not k.pressed or k.echo:
			return true
		match code:
			KEY_ESCAPE:
				_finish(false)
			KEY_PAGEUP, KEY_PAGEDOWN:
				if on_wheel.is_valid():
					on_wheel.call(1 if code == KEY_PAGEUP else -1)
					_update()
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
				_finish(true)
			KEY_BACKSPACE:
				numeric = numeric.substr(0, maxi(numeric.length() - 1, 0))
				_update()
			KEY_MINUS, KEY_KP_SUBTRACT:
				numeric = numeric.substr(1) if numeric.begins_with("-") else "-" + numeric
				_update()
			KEY_PERIOD, KEY_KP_PERIOD, KEY_COMMA:
				if not numeric.contains("."):
					numeric += "."
					_update()
			_:
				var digit := -1
				if code >= KEY_0 and code <= KEY_9:
					digit = code - KEY_0
				elif code >= KEY_KP_0 and code <= KEY_KP_9:
					digit = code - KEY_KP_0
				if digit >= 0:
					numeric += str(digit)
					_update()
				elif on_key.is_valid() and on_key.call(code):
					_update()
		return true
	return true

## Re-applies the current value (after on_key changed the operation).
func refresh() -> void:
	_update()

func _finish(ok: bool) -> void:
	active = false
	finished.emit(ok)

func draw(ctl: Control) -> void:
	if not active or _camera == null:
		return
	var font := ctl.get_theme_default_font()
	var ps := _pivot_screen()
	ctl.draw_dashed_line(ps, _mouse, Color(1, 1, 1, 0.8), 1.0, 6.0)
	ctl.draw_circle(ps, 3.0, Color(1, 1, 1, 0.9))
	var name := name_override if name_override != "" else ("Thickness" if kind == "inset" else ("Factor" if kind == "factor" else ("Width" if kind == "width" else "Distance")))
	var txt := "%s  %s: %.4f%s%s" % [PfI18n.t(label), PfI18n.t(name), value, (" [%s|]" % numeric) if not numeric.is_empty() else "", ("  (" + PfI18n.t(extra) + ")") if extra != "" else ""]
	var pos := Vector2(12, 52)
	ctl.draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 6, Color(0, 0, 0, 0.9))
	ctl.draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color.WHITE)
	var help := PfI18n.t("LMB/Enter: confirm   RMB/Esc: cancel   Ctrl: snap   Shift: precision   type a number") + (PfI18n.t("   I: individual") if kind == "inset" else "") + (PfI18n.t("   Wheel / PgUp PgDn: segments") if on_wheel.is_valid() else "")
	var hp := Vector2(12, ctl.size.y - 12)
	ctl.draw_string_outline(font, hp, help, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 5, Color(0, 0, 0, 0.9))
	ctl.draw_string(font, hp, help, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.85))
