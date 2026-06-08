extends Node3D
class_name Block_Spike
## ============================================================
##  地刺机关 (Spike Trap)
## ============================================================

@export_group("尺寸")
@export_range(0.5, 30.0, 0.5) var base_width: float = 4.0
@export_range(0.5, 30.0, 0.5) var base_depth: float = 4.0
@export_range(0.05, 1.0, 0.05) var base_thickness: float = 0.15
@export_range(0.5, 8.0, 0.1) var spike_height: float = 2.5
@export_range(0.05, 1.0, 0.05) var spike_radius: float = 0.15
@export_range(1, 10, 1) var spike_rows: int = 3
@export_range(1, 10, 1) var spike_cols: int = 3

@export_group("节奏")
@export_range(0.1, 5.0, 0.05) var spike_up_time: float = 1.0
@export_range(0.1, 5.0, 0.05) var spike_down_time: float = 1.5
@export_range(0.01, 1.0, 0.01) var spike_rise_time: float = 0.08
@export_range(0.01, 1.0, 0.01) var spike_fall_time: float = 0.3
@export_range(0.0, 10.0, 0.1) var spike_phase_offset: float = 0.0

@export_group("弹飞")
@export_range(5.0, 60.0, 1.0) var launch_impulse: float = 30.0
@export_range(0.0, 1.0, 0.05) var launch_up_ratio: float = 0.7
@export_range(0.1, 1.5, 0.05) var launch_skip_stick: float = 0.5
@export_range(0.1, 3.0, 0.1) var retrigger_cooldown: float = 0.8

@export_group("视觉")
@export var base_color: Color = Color(0.25, 0.25, 0.28)
@export var spike_color: Color = Color(0.7, 0.15, 0.15)
@export_range(0.0, 1.0, 0.05) var spike_metallic: float = 0.8

var _spikes_root: Node3D = null
var _trigger_area: Area3D = null
var _base_body: StaticBody3D = null
var _time: float = 0.0
var _is_up: bool = false
var _recent_triggered: Dictionary = {}


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_spikes_root = null
	_trigger_area = null
	_base_body = null

	# --- 底座 ---
	# 底座显示在赛道表面之上, 但尽量与地面齐平 (只微抬避免 z-fighting)
	var base_y_offset: float = 0.005  # 极小抬升, 仅防 z-fighting 闪烁
	_base_body = StaticBody3D.new()
	_base_body.name = "BaseBody"
	_base_body.collision_layer = 1
	_base_body.collision_mask = 0
	var base_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(base_width, base_thickness, base_depth)
	base_shape.shape = box
	base_shape.position = Vector3(0.0, base_y_offset + base_thickness * 0.5, 0.0)
	_base_body.add_child(base_shape)
	var base_mesh_inst := MeshInstance3D.new()
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(base_width, base_thickness, base_depth)
	base_mesh_inst.mesh = bmesh
	base_mesh_inst.position = Vector3(0.0, base_y_offset + base_thickness * 0.5, 0.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = base_color
	bmat.metallic = 0.5
	bmat.roughness = 0.6
	# 渲染优先级: 确保底座在同平面物体之上
	bmat.render_priority = 1
	base_mesh_inst.material_override = bmat
	_base_body.add_child(base_mesh_inst)
	add_child(_base_body)

	# --- 尖刺组 (动画容器) ---
	var base_top: float = base_y_offset + base_thickness  # 底座顶面实际 Y
	_spikes_root = Node3D.new()
	_spikes_root.name = "SpikesRoot"
	_spikes_root.position = Vector3(0.0, -spike_height + base_top, 0.0)
	add_child(_spikes_root)

	var smat := StandardMaterial3D.new()
	smat.albedo_color = spike_color
	smat.metallic = spike_metallic
	smat.roughness = 0.3
	var spacing_x: float = base_width / maxf(spike_cols, 1)
	var spacing_z: float = base_depth / maxf(spike_rows, 1)
	var start_x: float = -base_width * 0.5 + spacing_x * 0.5
	var start_z: float = -base_depth * 0.5 + spacing_z * 0.5
	for row in range(spike_rows):
		for col in range(spike_cols):
			var cone := MeshInstance3D.new()
			var cmesh := CylinderMesh.new()
			cmesh.top_radius = 0.0
			cmesh.bottom_radius = spike_radius
			cmesh.height = spike_height
			cmesh.radial_segments = 8
			cone.mesh = cmesh
			cone.material_override = smat
			cone.position = Vector3(
				start_x + col * spacing_x,
				spike_height * 0.5,
				start_z + row * spacing_z
			)
			_spikes_root.add_child(cone)

	# --- 刺体实体碰撞 (AnimatableBody3D, 跟随 _spikes_root 动画) ---
	# 用户需求 (2026-06-03): "不能接受穿模"
	# 刺突起时车撞上去会被实体挡住 (不会穿过刺体)
	var spike_body := AnimatableBody3D.new()
	spike_body.name = "SpikeBody"
	spike_body.collision_layer = 1   # 车能撞到
	spike_body.collision_mask = 0
	var spike_phys := PhysicsMaterial.new()
	spike_phys.bounce = 0.5
	spike_phys.friction = 0.8
	spike_body.physics_material_override = spike_phys
	var spike_col := CollisionShape3D.new()
	var spike_box := BoxShape3D.new()
	spike_box.size = Vector3(base_width * 0.85, spike_height * 0.8, base_depth * 0.85)
	spike_col.shape = spike_box
	spike_col.position = Vector3(0.0, spike_height * 0.5, 0.0)
	spike_body.add_child(spike_col)
	_spikes_root.add_child(spike_body)

	# --- Trigger Area3D: 固定在底座上方 (不跟随刺体动!) ---
	# 真凶修复 (2026-06-03): 旧版 trigger 挂在 _spikes_root 下, 跟刺体一起缩回地下
	# → 车永远进不了 trigger → 弹飞永远不触发
	# 修复: trigger 挂在 self (Block_Spike 根) 下, 固定覆盖刺突起后的空间
	_trigger_area = Area3D.new()
	_trigger_area.name = "TriggerArea"
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2   # car layer
	_trigger_area.monitoring = true
	var tshape := CollisionShape3D.new()
	var tbox := BoxShape3D.new()
	# 覆盖范围: 底座顶面到刺尖的完整空间
	tbox.size = Vector3(base_width, spike_height + 1.0, base_depth)
	tshape.shape = tbox
	# 中心: 底座顶面 + spike_height/2 + 0.5 向上多一点确保球心车能碰到
	tshape.position = Vector3(0.0, base_top + (spike_height + 1.0) * 0.5, 0.0)
	_trigger_area.add_child(tshape)
	add_child(_trigger_area)   # 挂在 self 下, 不跟 _spikes_root 动!

	_time = spike_phase_offset
	_is_up = false


func _physics_process(delta: float) -> void:
	if _spikes_root == null:
		return
	_time += delta
	var cycle: float = spike_rise_time + spike_up_time + spike_fall_time + spike_down_time
	if cycle < 0.01:
		return
	var phase: float = fmod(_time, cycle)

	var t_norm: float = 0.0
	if phase < spike_rise_time:
		t_norm = phase / maxf(spike_rise_time, 0.001)
	elif phase < spike_rise_time + spike_up_time:
		t_norm = 1.0
	elif phase < spike_rise_time + spike_up_time + spike_fall_time:
		var fall_phase: float = phase - spike_rise_time - spike_up_time
		t_norm = 1.0 - fall_phase / maxf(spike_fall_time, 0.001)
	else:
		t_norm = 0.0

	t_norm = clampf(t_norm, 0.0, 1.0)
	_is_up = t_norm > 0.3   # 刺升到 30% 以上就算"危险"
	var base_top_y: float = 0.005 + base_thickness  # 与 _rebuild 中 base_y_offset 一致
	var y_retracted: float = -spike_height + base_top_y
	var y_extended: float = base_top_y
	_spikes_root.position.y = lerpf(y_retracted, y_extended, t_norm)

	# 每帧主动检测 + 弹飞
	if _is_up and _trigger_area:
		for body in _trigger_area.get_overlapping_bodies():
			_try_launch(body)


func _try_launch(body: Node) -> void:
	if not _is_up:
		return
	if not body is RigidBody3D:
		return
	var car: RigidBody3D = body as RigidBody3D
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = car.get_instance_id()
	if _recent_triggered.has(key) and float(_recent_triggered[key]) > now:
		return
	_recent_triggered[key] = now + retrigger_cooldown

	var car_pos: Vector3 = car.global_position
	var spike_pos: Vector3 = global_position
	var horiz_dir: Vector3 = (car_pos - spike_pos)
	horiz_dir.y = 0.0
	if horiz_dir.length() > 0.001:
		horiz_dir = horiz_dir.normalized()
	else:
		horiz_dir = Vector3(0.0, 0.0, 1.0)
	var launch_dir: Vector3 = (Vector3.UP * launch_up_ratio + horiz_dir * (1.0 - launch_up_ratio)).normalized()
	var new_v: Vector3 = launch_dir * launch_impulse

	if car.has_method("apply_jump_pad_kick"):
		car.apply_jump_pad_kick(new_v, launch_skip_stick)
	else:
		car.linear_velocity = new_v
	print("[Spike] 弹飞! dir=", launch_dir, " impulse=", launch_impulse)


func reset_state() -> void:
	## 按 B 复位时重置地刺节奏 (从头开始循环)
	_time = spike_phase_offset
	_is_up = false
	_recent_triggered.clear()


func get_editable_params() -> Array:
	return [
		{"key": "base_width", "label": "底座宽度(m)", "min": 0.5, "max": 30.0, "step": 0.5, "value": base_width},
		{"key": "base_depth", "label": "底座深度(m)", "min": 0.5, "max": 30.0, "step": 0.5, "value": base_depth},
		{"key": "spike_height", "label": "刺高度(m)", "min": 0.5, "max": 8.0, "step": 0.1, "value": spike_height},
		{"key": "spike_radius", "label": "刺半径(m)", "min": 0.05, "max": 1.0, "step": 0.05, "value": spike_radius},
		{"key": "spike_rows", "label": "刺行数", "min": 1, "max": 10, "step": 1, "value": spike_rows},
		{"key": "spike_cols", "label": "刺列数", "min": 1, "max": 10, "step": 1, "value": spike_cols},
		{"key": "spike_up_time", "label": "突起持续(s)", "min": 0.1, "max": 5.0, "step": 0.05, "value": spike_up_time},
		{"key": "spike_down_time", "label": "缩回持续(s)", "min": 0.1, "max": 5.0, "step": 0.05, "value": spike_down_time},
		{"key": "spike_rise_time", "label": "升起动画(s)", "min": 0.01, "max": 1.0, "step": 0.01, "value": spike_rise_time},
		{"key": "spike_fall_time", "label": "缩回动画(s)", "min": 0.01, "max": 1.0, "step": 0.01, "value": spike_fall_time},
		{"key": "spike_phase_offset", "label": "相位偏移(s)", "min": 0.0, "max": 10.0, "step": 0.1, "value": spike_phase_offset},
		{"key": "launch_impulse", "label": "弹飞冲量(m/s)", "min": 5.0, "max": 60.0, "step": 1.0, "value": launch_impulse},
		{"key": "launch_up_ratio", "label": "弹飞向上比例", "min": 0.0, "max": 1.0, "step": 0.05, "value": launch_up_ratio},
		{"key": "launch_skip_stick", "label": "防弹豁免(s)", "min": 0.1, "max": 1.5, "step": 0.05, "value": launch_skip_stick},
		{"key": "retrigger_cooldown", "label": "触发冷却(s)", "min": 0.1, "max": 3.0, "step": 0.1, "value": retrigger_cooldown},
	]

func set_editable_param(key: String, value: float) -> void:
	match key:
		"base_width": base_width = value
		"base_depth": base_depth = value
		"spike_height": spike_height = value
		"spike_radius": spike_radius = value
		"spike_rows": spike_rows = int(value)
		"spike_cols": spike_cols = int(value)
		"spike_up_time": spike_up_time = value
		"spike_down_time": spike_down_time = value
		"spike_rise_time": spike_rise_time = value
		"spike_fall_time": spike_fall_time = value
		"spike_phase_offset": spike_phase_offset = value
		"launch_impulse": launch_impulse = value
		"launch_up_ratio": launch_up_ratio = value
		"launch_skip_stick": launch_skip_stick = value
		"retrigger_cooldown": retrigger_cooldown = value
	_rebuild()
