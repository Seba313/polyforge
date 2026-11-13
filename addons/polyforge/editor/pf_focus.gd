## PfFocus — optional Focus mode: everything except the edited object is
## dimmed in the editor viewport. The edited object gets a stencil-writing
## overlay through the RenderingServer (its node and materials are untouched)
## and a full-screen quad darkens every pixel without that stencil.
@tool
extends RefCounted

const WRITE := """shader_type spatial;
render_mode unshaded, depth_draw_never, blend_mix, cull_disabled;
stencil_mode write, compare_always, 1;
void fragment() { ALBEDO = vec3(0.0); ALPHA = 0.0; }
"""
const DIM := """shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, blend_mix, fog_disabled;
stencil_mode read, compare_not_equal, 1;
uniform float amount = 0.6;
void vertex() { POSITION = vec4(VERTEX.xy, 1.0, 1.0); }
void fragment() { ALBEDO = vec3(0.05); ALPHA = amount; }
"""

var active := false
var _writer: ShaderMaterial = null
var _dim: ShaderMaterial = null
var _quad: QuadMesh = null
var _inst := RID()
var _target: VisualInstance3D = null
var _extra: Array = []      # further edited objects (multi-object edit)

func enable(target: VisualInstance3D, amount := 0.6, others: Array = []) -> void:
	disable()
	if target == null or not target.is_inside_tree():
		return
	_writer = ShaderMaterial.new()
	_writer.shader = Shader.new()
	_writer.shader.code = WRITE
	_writer.render_priority = -128
	_dim = ShaderMaterial.new()
	_dim.shader = Shader.new()
	_dim.shader.code = DIM
	_dim.render_priority = -127
	_dim.set_shader_parameter("amount", amount)
	_quad = QuadMesh.new()
	_quad.size = Vector2(2, 2)
	_quad.material = _dim
	_inst = RenderingServer.instance_create2(_quad.get_rid(), target.get_world_3d().scenario)
	RenderingServer.instance_set_extra_visibility_margin(_inst, 1e9)
	RenderingServer.instance_geometry_set_cast_shadows_setting(_inst, RenderingServer.SHADOW_CASTING_SETTING_OFF)
	RenderingServer.instance_geometry_set_flag(_inst, RenderingServer.INSTANCE_FLAG_IGNORE_OCCLUSION_CULLING, true)
	_target = target
	RenderingServer.instance_geometry_set_material_overlay(target.get_instance(), _writer.get_rid())
	_extra = []
	for o in others:
		if o is VisualInstance3D and o != target and (o as Node).is_inside_tree():
			RenderingServer.instance_geometry_set_material_overlay((o as VisualInstance3D).get_instance(), _writer.get_rid())
			_extra.append(o)
	active = true

func disable() -> void:
	if _inst.is_valid():
		RenderingServer.free_rid(_inst)
	_inst = RID()
	if _target != null and is_instance_valid(_target) and _target is GeometryInstance3D:
		var own: Material = (_target as GeometryInstance3D).material_overlay
		RenderingServer.instance_geometry_set_material_overlay(_target.get_instance(), own.get_rid() if own != null else RID())
	for o in _extra:
		if is_instance_valid(o) and o is GeometryInstance3D:
			var own2: Material = (o as GeometryInstance3D).material_overlay
			RenderingServer.instance_geometry_set_material_overlay((o as VisualInstance3D).get_instance(), own2.get_rid() if own2 != null else RID())
	_extra = []
	_target = null
	active = false
