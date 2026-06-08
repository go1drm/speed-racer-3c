extends Node3D
class_name Block_TriggerSpring
## ============================================================
##  触发式弹簧 (Trigger Spring)
## ============================================================
## 平时隐藏在地面下, 只有赛车压上去时才瞬间弹出并弹飞赛车.
## 弹出后经过冷却时间缩回, 等待下一次触发.
## ============================================================

@export_group("弹簧体")
@export_range(0.5, 4.0, 0.1) var pad_width: float = 2.5
@export_range(0.5, 4.0, 0.1) var pad_depth: float = 2.5
@export_range(0.5, 6.0, 0.5) var spring_height: float = 3.0

@export_group("弹飞")
@export_range(10.0, 120.0, 5.0) var launch_speed: float = 55.0
@export_range(0.0, 1.0, 0.05) var launch_up_ratio: float = 0.6
@export_range(0.0, 1.0, 0.05) var launch_forward_ratio: float = 0.4

@export_group("节奏")
## 弹出动画时间 (越短越爆发)
@export_range(0.02, 0.5, 0.01) var extend_duration: float = 0.08
## 完全伸出后保持多久再缩回
@export_range(0.1, 3.0, 0.1) var hold_time: float = 0.6
## 缩回动画时间
@export_range(0.05, 1.0, 0.05) var retract_duration: float = 0.4
## 缩回后到下次可触发的冷却
@export_range(0.0, 5.0, 0.1) var cooldown: float = 1.0

@export_group("视觉")
@export var pad_color: Color = Color(0.95, 0.6, 0.1)
@export var base_color: Color = Color(0.25, 0.25, 0.3)
@export var spring_coil_color: Color = Color(0.7, 0.7, 0.75)


# ---- 内部 ----
enum State { IDLE, EXTENDING, HOLDING, RETRACTING, COOLDOWN }
var _state: int = State.IDLE
var _timer: float = 0.0
var _extend_progress: float = 0.0  # 0=缩回, 1=完全伸出

var _pad_node: Node3D = null       # 弹射板 (上下移动)
var _base_body: StaticBody3D = null
var _detect_area: Area3D = null    # 检测赛车触碰
var _launched_ids: Dictionary = {} # 本次弹出已弹飞的车 (防重复)


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_pad_node = null
	_base_body = null
	_detect_area = null
	_state = State.IDLE
	_timer = 0.0
	_extend_progress = 0.0

	# --- 底座 (地面上的凹槽框) ---
	_base_body = StaticBody3D.new()
	_base_body.name = "TriggerSpringBase"
	_base_body.collision_layer = 1
	_base_body.collision_mask = 0
	var base_mi := MeshInstance3D.new()
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(pad_width + 0.4, 0.2, pad_depth + 0.4)
	base_mi.mesh = bmesh
	base_mi.position = Vector3(0.0, -0.1, 0.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = base_color
	bmat.metallic = 0.4
	bmat.roughness = 0.7
	base_mi.material_override = bmat
	_base_body.add_child(base_mi)
	var bcol := CollisionShape3D.new()
	var bbox := BoxShape3D.new()
	bbox.size = Vector3(pad_width + 0.4, 0.2, pad_depth + 0.4)
	bcol.shape = bbox
	bcol.position = Vector3(0.0, -0.1, 0.0)
	_base_body.add_child(bcol)
	add_child(_base_body)

	# --- 弹射板 (压上去的那个面, 会弹起) ---
	_pad_node = Node3D.new()
	_pad_node.name = "SpringPad"
	# 板面
	var pad_mi := MeshInstance3D.new()
	var pmesh := BoxMesh.new()
	pmesh.size = Vector3(pad_width, 0.15, pad_depth)
	pad_mi.mesh = pmesh
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = pad_color
	pmat.metallic = 0.3
	pmat.roughness = 0.5
	pmat.emission_enabled = true
	pmat.emission = pad_color * 0.5
	pmat.emission_energy_multiplier = 0.3
	pad_mi.material_override = pmat
	pad_mi.position = Vector3(0.0, 0.075, 0.0)
	_pad_node.add_child(pad_mi)
	# 弹簧线圈装饰 (几个环)
	for i in range(3):
		var coil := MeshInstance3D.new()
		var cmesh := TorusMesh.new()
		cmesh.inner_radius = pad_width * 0.15
		cmesh.outer_radius = pad_width * 0.22
		cmesh.rings = 12
		cmesh.ring_segments = 8
		coil.mesh = cmesh
		var cmat := StandardMaterial3D.new()
		cmat.albedo_color = spring_coil_color
		cmat.metallic = 0.7
		cmat.roughness = 0.3
		coil.material_override = cmat
		coil.position = Vector3(0.0, -spring_height * (float(i + 1) / 4.0), 0.0)
		coil.rotation.x = deg_to_rad(90)
		_pad_node.add_child(coil)
	# 初始位置: 缩在地面 (板面与地面齐平)
	_pad_node.position = Vector3(0.0, 0.0, 0.0)
	add_child(_pad_node)

	# --- 检测区域 (赛车压上板面即触发) ---
	_detect_area = Area3D.new()
	_detect_area.name = "DetectArea"
	_detect_area.collision_layer = 0
	_detect_area.collision_mask = 2
	_detect_area.monitoring = true
	_detect_area.monitorable = false
	var dshape := CollisionShape3D.new()
	var dbox := BoxShape3D.new()
	dbox.size = Vector3(pad_width + 1.0, 3.0, pad_depth + 1.0)
	dshape.shape = dbox
	dshape.position = Vector3(0.0, 1.5, 0.0)
	_detect_area.add_child(dshape)
	add_child(_detect_area)


func _physics_process(delta: float) -> void:
	if _pad_node == null or _detect_area == null:
		return

	match _state:
		State.IDLE:
			# 检测赛车是否压在上面
			for body in _detect_area.get_overlapping_bodies():
				if body is RigidBody3D:
					_trigger()
					break
		State.EXTENDING:
			_timer -= delta
			_extend_progress = 1.0 - (_timer / maxf(extend_duration, 0.001))
			_extend_progress = clampf(_extend_progress, 0.0, 1.0)
			_update_pad_position()
			# 弹出过程中弹飞接触到的车
			if _extend_progress > 0.3:
				_launch_overlapping()
			if _timer <= 0.0:
				_state = State.HOLDING
				_timer = hold_time
				_extend_progress = 1.0
				_update_pad_position()
		State.HOLDING:
			_timer -= delta
			# 保持弹出状态, 期间仍然弹飞接触到的车
			_launch_overlapping()
			if _timer <= 0.0:
				_state = State.RETRACTING
				_timer = retract_duration
		State.RETRACTING:
			_timer -= delta
			_extend_progress = _timer / maxf(retract_duration, 0.001)
			_extend_progress = clampf(_extend_progress, 0.0, 1.0)
			_update_pad_position()
			if _timer <= 0.0:
				_state = State.COOLDOWN
				_timer = cooldown
				_extend_progress = 0.0
				_update_pad_position()
		State.COOLDOWN:
			_timer -= delta
			if _timer <= 0.0:
				_state = State.IDLE
				_launched_ids.clear()


func _trigger() -> void:
	_state = State.EXTENDING
	_timer = extend_duration
	_launched_ids.clear()


func _update_pad_position() -> void:
	# 从地面 (y=0) 弹到 spring_height
	_pad_node.position.y = _extend_progress * spring_height


func _launch_overlapping() -> void:
	for body in _detect_area.get_overlapping_bodies():
		if body is RigidBody3D:
			_try_launch(body)


func _try_launch(car: RigidBody3D) -> void:
	var key: int = car.get_instance_id()
	if _launched_ids.has(key):
		return
	_launched_ids[key] = true

	# 弹飞方向: 从机关中心指向赛车 (水平) + 向上分量
	# 初始速度不参与计算, 纯由机关参数决定
	var horiz_dir: Vector3 = (car.global_position - global_position)
	horiz_dir.y = 0.0
	if horiz_dir.length() < 0.1:
		horiz_dir = Vector3(0.0, 0.0, 1.0)
	horiz_dir = horiz_dir.normalized()
	var dir: Vector3 = (Vector3.UP * launch_up_ratio + horiz_dir * (1.0 - launch_up_ratio)).normalized()

	# 用 apply_jump_pad_kick 统一接口 (覆写速度 + 防弹豁免 + 强制空中)
	var new_v: Vector3 = dir * launch_speed
	if car.has_method("apply_jump_pad_kick"):
		car.apply_jump_pad_kick(new_v, 0.5)
	else:
		car.linear_velocity = new_v
	# 随机小角速度 (视觉翻滚感)
	car.angular_velocity = Vector3(
		randf_range(-2.0, 2.0), randf_range(-1.0, 1.0), randf_range(-2.0, 2.0)
	)


func reset_state() -> void:
	_state = State.IDLE
	_timer = 0.0
	_extend_progress = 0.0
	_launched_ids.clear()
	if _pad_node:
		_pad_node.position.y = 0.0


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "pad_width", "label": "板面宽度(m)", "min": 0.5, "max": 4.0, "step": 0.1, "value": pad_width},
		{"key": "pad_depth", "label": "板面深度(m)", "min": 0.5, "max": 4.0, "step": 0.1, "value": pad_depth},
		{"key": "spring_height", "label": "弹出高度(m)", "min": 0.5, "max": 6.0, "step": 0.5, "value": spring_height},
		{"key": "launch_speed", "label": "弹飞速度(m/s)", "min": 10.0, "max": 120.0, "step": 5.0, "value": launch_speed},
		{"key": "launch_up_ratio", "label": "向上比例", "min": 0.0, "max": 1.0, "step": 0.05, "value": launch_up_ratio},
		{"key": "launch_forward_ratio", "label": "向前比例", "min": 0.0, "max": 1.0, "step": 0.05, "value": launch_forward_ratio},
		{"key": "extend_duration", "label": "弹出速度(s)", "min": 0.02, "max": 0.5, "step": 0.01, "value": extend_duration},
		{"key": "hold_time", "label": "保持时间(s)", "min": 0.1, "max": 3.0, "step": 0.1, "value": hold_time},
		{"key": "retract_duration", "label": "缩回速度(s)", "min": 0.05, "max": 1.0, "step": 0.05, "value": retract_duration},
		{"key": "cooldown", "label": "冷却时间(s)", "min": 0.0, "max": 5.0, "step": 0.1, "value": cooldown},
	]

var _rebuild_pending: bool = false

func set_editable_param(key: String, value: float) -> void:
	match key:
		"pad_width": pad_width = value
		"pad_depth": pad_depth = value
		"spring_height": spring_height = value
		"launch_speed": launch_speed = value
		"launch_up_ratio": launch_up_ratio = value
		"launch_forward_ratio": launch_forward_ratio = value
		"extend_duration": extend_duration = value
		"hold_time": hold_time = value
		"retract_duration": retract_duration = value
		"cooldown": cooldown = value
	if not _rebuild_pending:
		_rebuild_pending = true
		call_deferred("_deferred_rebuild")

func _deferred_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()
