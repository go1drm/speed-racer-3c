extends "res://track_editor/blocks/Block_Turn90Left.gd"
class_name Block_FragileTurn
## ============================================================
##  易碎弯道 (Fragile Turn)
## ============================================================
## 与普通 90° 弯道一样, 但被赛车踩过后碎裂消失. 逻辑同 Block_FragileStraight.
## ============================================================

@export_group("碎裂")
@export_range(0.1, 10.0, 0.1) var break_delay: float = 1.0
@export_range(0.05, 3.0, 0.05) var break_duration: float = 0.4
@export_range(0.0, 30.0, 0.5) var respawn_time: float = 5.0
@export var break_flash_color: Color = Color(1.0, 0.3, 0.1, 0.8)

enum FragState { SOLID, BREAKING, GONE, RESPAWNING }
var _frag_state: int = FragState.SOLID
var _frag_timer: float = 0.0
var _trigger_area: Area3D = null


func _ready() -> void:
	super._ready()
	_setup_fragile_trigger()


func _setup_fragile_trigger() -> void:
	_trigger_area = Area3D.new()
	_trigger_area.name = "FragileTrigger"
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2
	_trigger_area.monitoring = true
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	# 弯道半径 → 用 sphere 覆盖大致弯道区域
	sphere.radius = maxf(entry_width, 10.0)
	shape.shape = sphere
	shape.position = Vector3(0.0, 2.0, 0.0)
	_trigger_area.add_child(shape)
	add_child(_trigger_area)
	_trigger_area.body_entered.connect(_on_car_step)


func _on_car_step(body: Node) -> void:
	if _frag_state != FragState.SOLID:
		return
	if not body is RigidBody3D:
		return
	_frag_state = FragState.BREAKING
	_frag_timer = break_delay


func _physics_process(delta: float) -> void:
	match _frag_state:
		FragState.SOLID:
			pass
		FragState.BREAKING:
			_frag_timer -= delta
			if _frag_timer <= 0.0:
				_frag_timer = break_duration
				_frag_state = FragState.GONE
			else:
				var flash: float = sin(_frag_timer * 15.0) * 0.5 + 0.5
				_set_opacity(lerpf(1.0, 0.5, flash))
		FragState.GONE:
			_frag_timer -= delta
			var t: float = clampf(1.0 - _frag_timer / maxf(break_duration, 0.01), 0.0, 1.0)
			_set_opacity(1.0 - t)
			if _frag_timer <= 0.0:
				_set_collision_enabled(false)
				visible = false
				if respawn_time > 0.001:
					_frag_timer = respawn_time
					_frag_state = FragState.RESPAWNING
		FragState.RESPAWNING:
			_frag_timer -= delta
			if _frag_timer <= 0.0:
				_frag_state = FragState.SOLID
				_set_collision_enabled(true)
				visible = true
				_set_opacity(1.0)


func _set_opacity(alpha: float) -> void:
	for child in _get_all_mesh_instances(self):
		var mat: Material = child.get_active_material(0)
		if mat is StandardMaterial3D:
			var smat: StandardMaterial3D = mat as StandardMaterial3D
			if alpha < 0.99:
				smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				smat.albedo_color.a = alpha
			else:
				smat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
				smat.albedo_color.a = 1.0


func _set_collision_enabled(enabled: bool) -> void:
	for child in _get_all_static_bodies(self):
		(child as StaticBody3D).collision_layer = 1 if enabled else 0


func _get_all_mesh_instances(node: Node) -> Array:
	var result: Array = []
	if node is MeshInstance3D:
		result.append(node)
	for c in node.get_children():
		result.append_array(_get_all_mesh_instances(c))
	return result


func _get_all_static_bodies(node: Node) -> Array:
	var result: Array = []
	if node is StaticBody3D:
		result.append(node)
	for c in node.get_children():
		result.append_array(_get_all_static_bodies(c))
	return result


func reset_state() -> void:
	## 按 B 复位时恢复路面为完整状态
	_frag_state = FragState.SOLID
	_frag_timer = 0.0
	visible = true
	for child in get_children():
		if child is StaticBody3D:
			child.collision_layer = 1


func get_editable_params() -> Array:
	var params: Array = super.get_editable_params()
	params.append_array([
		{"key": "break_delay", "label": "碎裂延迟(s)", "min": 0.1, "max": 10.0, "step": 0.1, "value": break_delay},
		{"key": "break_duration", "label": "碎裂时长(s)", "min": 0.05, "max": 3.0, "step": 0.05, "value": break_duration},
		{"key": "respawn_time", "label": "恢复时间(s)", "min": 0.0, "max": 30.0, "step": 0.5, "value": respawn_time},
	])
	return params

func set_editable_param(key: String, value: float) -> void:
	match key:
		"break_delay": break_delay = value
		"break_duration": break_duration = value
		"respawn_time": respawn_time = value
		_: super.set_editable_param(key, value)
