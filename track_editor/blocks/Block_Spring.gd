extends Node3D
class_name Block_Spring
## ============================================================
##  弹簧机关 (Spring Launcher)
## ============================================================
## 类似地刺的表现: 间隔一段时间后弹出, 撞到赛车会飞得很远.
## 与地刺的区别: 弹簧弹出时是水平/斜方向推, 而不是向上弹飞.
## ============================================================

@export_group("弹簧体")
@export_range(0.3, 3.0, 0.1) var spring_radius: float = 0.8
@export_range(1.0, 8.0, 0.5) var spring_length: float = 3.0
@export_range(0.2, 2.0, 0.1) var base_size: float = 1.0

@export_group("节奏")
@export_range(0.1, 5.0, 0.1) var extend_time: float = 0.8
@export_range(0.1, 5.0, 0.1) var retract_time: float = 2.0
@export_range(0.01, 0.5, 0.01) var extend_speed: float = 0.06
@export_range(0.01, 0.5, 0.01) var retract_speed: float = 0.2
@export_range(0.0, 10.0, 0.1) var phase_offset: float = 0.0

@export_group("弹飞")
@export_range(10.0, 100.0, 5.0) var launch_speed: float = 50.0
@export_range(0.0, 1.0, 0.1) var launch_up_ratio: float = 0.2
@export_range(0.1, 2.0, 0.1) var retrigger_cooldown: float = 0.5

@export_group("视觉")
@export var base_color: Color = Color(0.3, 0.3, 0.35)
@export var spring_color: Color = Color(0.2, 0.8, 0.3)


# ---- 内部 ----
var _spring_mesh: Node3D = null
var _base_body: StaticBody3D = null
var _trigger_area: Area3D = null
var _time: float = 0.0
var _is_extended: bool = false
var _extend_progress: float = 0.0  # 0=缩回, 1=完全伸出
var _recent_triggered: Dictionary = {}


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_spring_mesh = null
	_base_body = null
	_trigger_area = null

	# --- 底座 ---
	_base_body = StaticBody3D.new()
	_base_body.name = "SpringBase"
	_base_body.collision_layer = 1
	_base_body.collision_mask = 0
	var base_mi := MeshInstance3D.new()
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(base_size, base_size, base_size)
	base_mi.mesh = bmesh
	base_mi.position = Vector3(0.0, base_size * 0.5, 0.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = base_color
	bmat.metallic = 0.5
	bmat.roughness = 0.6
	base_mi.material_override = bmat
	_base_body.add_child(base_mi)
	var bcol := CollisionShape3D.new()
	var bbox := BoxShape3D.new()
	bbox.size = Vector3(base_size, base_size, base_size)
	bcol.shape = bbox
	bcol.position = Vector3(0.0, base_size * 0.5, 0.0)
	_base_body.add_child(bcol)
	add_child(_base_body)

	# --- 弹簧体 (支柱=立方体, 顶端=板子) ---
	_spring_mesh = Node3D.new()
	_spring_mesh.name = "SpringBody"
	# 支柱 (立方体)
	var smi := MeshInstance3D.new()
	var pillar_mesh := BoxMesh.new()
	pillar_mesh.size = Vector3(spring_radius * 0.6, spring_length, spring_radius * 0.6)
	smi.mesh = pillar_mesh
	var smat := StandardMaterial3D.new()
	smat.albedo_color = spring_color
	smat.metallic = 0.6
	smat.roughness = 0.3
	smat.emission_enabled = true
	smat.emission = spring_color
	smat.emission_energy_multiplier = 0.5
	smi.material_override = smat
	smi.position = Vector3(0.0, spring_length * 0.5, 0.0)
	_spring_mesh.add_child(smi)
	# 顶端板子 (扁平方块, 撞击面)
	var head := MeshInstance3D.new()
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(spring_radius * 2.5, 0.25, spring_radius * 2.5)
	head.mesh = head_mesh
	head.position = Vector3(0.0, spring_length + 0.125, 0.0)
	var hmat := StandardMaterial3D.new()
	hmat.albedo_color = Color(0.9, 0.2, 0.2)
	hmat.emission_enabled = true
	hmat.emission = Color(0.9, 0.2, 0.2)
	hmat.emission_energy_multiplier = 1.0
	hmat.metallic = 0.4
	hmat.roughness = 0.5
	head.material_override = hmat
	_spring_mesh.add_child(head)
	# 初始缩回位置
	_spring_mesh.position = Vector3(0.0, base_size - spring_length, 0.0)
	add_child(_spring_mesh)

	# --- 碰撞体 (顶端板子, AnimatableBody3D 跟随动画) ---
	var spring_body := AnimatableBody3D.new()
	spring_body.name = "SpringHitBody"
	spring_body.collision_layer = 1
	spring_body.collision_mask = 0
	var scol := CollisionShape3D.new()
	var sbox := BoxShape3D.new()
	sbox.size = Vector3(spring_radius * 2.5, 0.3, spring_radius * 2.5)
	scol.shape = sbox
	scol.position = Vector3(0.0, spring_length + 0.15, 0.0)
	spring_body.add_child(scol)
	_spring_mesh.add_child(spring_body)

	# --- Trigger Area (弹飞检测, 覆盖板子上方空间) ---
	_trigger_area = Area3D.new()
	_trigger_area.name = "LaunchArea"
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2
	_trigger_area.monitoring = true
	var tshape := CollisionShape3D.new()
	var tbox := BoxShape3D.new()
	tbox.size = Vector3(spring_radius * 3.0, 3.0, spring_radius * 3.0)
	tshape.shape = tbox
	tshape.position = Vector3(0.0, base_size + spring_length + 1.5, 0.0)
	_trigger_area.add_child(tshape)
	add_child(_trigger_area)

	_time = phase_offset
	_is_extended = false
	_extend_progress = 0.0


func _physics_process(delta: float) -> void:
	if _spring_mesh == null:
		return
	_time += delta
	var cycle: float = extend_time + retract_time + extend_speed + retract_speed
	if cycle < 0.01:
		return
	var phase: float = fmod(_time, cycle)

	# 状态机: 伸出动画 → 保持伸出 → 缩回动画 → 保持缩回
	if phase < extend_speed:
		# 伸出动画
		_extend_progress = phase / maxf(extend_speed, 0.001)
		_is_extended = false
	elif phase < extend_speed + extend_time:
		# 完全伸出
		_extend_progress = 1.0
		_is_extended = true
	elif phase < extend_speed + extend_time + retract_speed:
		# 缩回动画
		var retract_phase: float = phase - extend_speed - extend_time
		_extend_progress = 1.0 - retract_phase / maxf(retract_speed, 0.001)
		_is_extended = false
	else:
		# 完全缩回
		_extend_progress = 0.0
		_is_extended = false

	_extend_progress = clampf(_extend_progress, 0.0, 1.0)

	# 更新弹簧位置 (从缩回到伸出)
	var y_retracted: float = base_size - spring_length
	var y_extended: float = base_size
	_spring_mesh.position.y = lerpf(y_retracted, y_extended, _extend_progress)

	# 弹飞检测 (伸出 > 50% 时激活)
	if _extend_progress > 0.5 and _trigger_area:
		for body in _trigger_area.get_overlapping_bodies():
			_try_launch(body)


func _try_launch(body: Node) -> void:
	if not body is RigidBody3D:
		return
	var car: RigidBody3D = body as RigidBody3D
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = car.get_instance_id()
	if _recent_triggered.has(key) and float(_recent_triggered[key]) > now:
		return
	_recent_triggered[key] = now + retrigger_cooldown

	# 弹飞方向: 从机关中心指向赛车 (水平) + 向上分量
	# 初始速度不参与计算, 纯由机关参数决定
	var dir: Vector3 = (car.global_position - global_position)
	dir.y = 0.0
	if dir.length() < 0.1:
		dir = Vector3(0.0, 0.0, 1.0)
	dir = dir.normalized()
	dir = (Vector3.UP * launch_up_ratio + dir * (1.0 - launch_up_ratio)).normalized()

	var new_v: Vector3 = dir * launch_speed
	if car.has_method("apply_jump_pad_kick"):
		car.apply_jump_pad_kick(new_v, 0.5)
	else:
		car.linear_velocity = new_v
	car.angular_velocity = Vector3(
		randf_range(-3.0, 3.0), randf_range(-2.0, 2.0), randf_range(-3.0, 3.0)
	)


func reset_state() -> void:
	_time = phase_offset
	_is_extended = false
	_extend_progress = 0.0
	_recent_triggered.clear()


func get_editable_params() -> Array:
	return [
		{"key": "spring_radius", "label": "弹簧半径(m)", "min": 0.3, "max": 3.0, "step": 0.1, "value": spring_radius},
		{"key": "spring_length", "label": "弹簧长度(m)", "min": 1.0, "max": 8.0, "step": 0.5, "value": spring_length},
		{"key": "base_size", "label": "底座大小(m)", "min": 0.2, "max": 2.0, "step": 0.1, "value": base_size},
		{"key": "extend_time", "label": "伸出持续(s)", "min": 0.1, "max": 5.0, "step": 0.1, "value": extend_time},
		{"key": "retract_time", "label": "缩回持续(s)", "min": 0.1, "max": 5.0, "step": 0.1, "value": retract_time},
		{"key": "extend_speed", "label": "伸出动画(s)", "min": 0.01, "max": 0.5, "step": 0.01, "value": extend_speed},
		{"key": "retract_speed", "label": "缩回动画(s)", "min": 0.01, "max": 0.5, "step": 0.01, "value": retract_speed},
		{"key": "phase_offset", "label": "相位偏移(s)", "min": 0.0, "max": 10.0, "step": 0.1, "value": phase_offset},
		{"key": "launch_speed", "label": "弹飞速度(m/s)", "min": 10.0, "max": 100.0, "step": 5.0, "value": launch_speed},
		{"key": "launch_up_ratio", "label": "弹飞向上比例", "min": 0.0, "max": 1.0, "step": 0.1, "value": launch_up_ratio},
		{"key": "retrigger_cooldown", "label": "触发冷却(s)", "min": 0.1, "max": 2.0, "step": 0.1, "value": retrigger_cooldown},
	]

var _rebuild_pending: bool = false

func set_editable_param(key: String, value: float) -> void:
	match key:
		"spring_radius": spring_radius = value
		"spring_length": spring_length = value
		"base_size": base_size = value
		"extend_time": extend_time = value
		"retract_time": retract_time = value
		"extend_speed": extend_speed = value
		"retract_speed": retract_speed = value
		"phase_offset": phase_offset = value
		"launch_speed": launch_speed = value
		"launch_up_ratio": launch_up_ratio = value
		"retrigger_cooldown": retrigger_cooldown = value
	if not _rebuild_pending:
		_rebuild_pending = true
		call_deferred("_deferred_rebuild")

func _deferred_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()
