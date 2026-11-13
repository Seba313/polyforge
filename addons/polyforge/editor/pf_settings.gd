## PfSettings — Polyforge's own settings. Never touches Godot's editor
## settings or shortcuts:
##   - user preferences: <editor config dir>/polyforge.cfg
##   - project defaults: ProjectSettings "polyforge/..." (written only when the
##     user changes them in the Polyforge settings dialog)
@tool
extends RefCounted

const SECTION := "prefs"
const DEFAULTS := {
	"frame_color": Color(1.0, 0.78, 0.1),
	"frame_width": 2,
	"right_click_select": false,
	"object_mode_shortcuts": false,
	"object_keymap": {},          # action -> shortcut text overrides
	"correct_face_attributes": false,
	"snap_increment": 0.1,
	"uv_panel_width": 420,
	"local_view_frame": true,
	"last_tab": 0,
	"orientation": "global",
	"gizmo_move": false,
	"gizmo_rotate": false,
	"gizmo_scale": false,
	"focus_mode": false,
	"focus_amount": 0.6,
	"proportional": false,
	"prop_connected": false,
	"prop_falloff": "smooth",
	"prop_size": 1.0,
	"mirror_axes": [false, false, false],
	"overlay_stats": false,
	"snap_on": false,
	"snap_target": "increment",
	"overlay_edge_length": false,
	"overlay_face_orientation": false,
	"overlay_normals": false,
}
const PROJECT_WORLD_UV := "polyforge/uv/world_scale_uv_default"
const PROJECT_TEXEL := "polyforge/uv/texel_density"

var _cfg := ConfigFile.new()
var _path := ""

func _init(path := "") -> void:
	_path = path
	if _path.is_empty() and Engine.is_editor_hint():
		_path = EditorInterface.get_editor_paths().get_config_dir().path_join("polyforge.cfg")
	if not _path.is_empty() and FileAccess.file_exists(_path):
		_cfg.load(_path)

func get_pref(key: String) -> Variant:
	return _cfg.get_value(SECTION, key, DEFAULTS.get(key))

func set_pref(key: String, value: Variant) -> void:
	_cfg.set_value(SECTION, key, value)
	if not _path.is_empty():
		_cfg.save(_path)

## Project-wide default for new objects.
func world_uv_default() -> bool:
	return bool(ProjectSettings.get_setting(PROJECT_WORLD_UV, false))

func project_texel_density() -> float:
	return float(ProjectSettings.get_setting(PROJECT_TEXEL, 256.0))

func set_project_defaults(world_uv: bool, texel: float) -> void:
	ProjectSettings.set_setting(PROJECT_WORLD_UV, world_uv)
	ProjectSettings.set_setting(PROJECT_TEXEL, texel)
	ProjectSettings.save()

## Effective density of a mesh (object override or project default).
func density_for(m) -> float:
	return m.texel_density if m.texel_density > 0.0 else project_texel_density()
