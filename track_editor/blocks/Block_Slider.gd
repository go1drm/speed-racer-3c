extends Node3D
class_name Block_Slider
## ============================================================
##  往复滑块机关 (Slider / Moving Platform)
## ============================================================
## 一个沿固定轨道往复运动的立方体平台.
## 赛车可以乘坐它像电梯一样上下或横穿悬崖.
##
## 物理原理:
##   平台是 AnimatableBody3D (运动学物体), 每帧通过设置 global_transform 移动.
##   物理引擎自动计算碰撞推力, 站在上面的 RigidBody (赛车) 会被平台"带着走".
##   AnimatableBody3D 设置 transform 时会推开碰撞体 — 这是 Godot 官方方案.
##
## 3C 照顾:
##   - 平台表面高摩擦 (赛车不会滑下去)
##   - 平台启动/停止有加减速缓动 (不会突然甩飞赛车)
##   - 轨道两端有减速区 (平滑换向)
## ============================================================

@export_group("平台")
## 平台宽度 (X方向, 米)
@export_range(3.0, 20.0, 0.5) var platform_width: float = 6.0
## 平台长度 (Z方向, 赛车行进方向, 米)
@export_range(3.0, 20.0, 0.5) var platform_length: float = 8.0
## 平台厚度 (Y方向, 米)
@export_range(0.3, 3.0, 0.1) var platform_thickness: float = 0.6
## 平台颜色
@export var platform_color: Color = Color(0.35, 0.5, 0.6)

@export_group("轨道")
## 起点偏移 (相对机关位置, 米)
@export var start_offset: Vector3 = Vector3(0.0, 0.0, 0.0)
## 终点偏移 (相对机关位置, 米) — 决定滑块运动方向和距离
## 默认水平移动 20m (沿 X 轴). 改 Y 分量可做电梯, 改 Z 分量可做前后移动
@export var end_offset: Vector3 = Vector3(20.0, 0.0, 0.0)
## 移动速度 (m/s)
@export_range(1.0, 30.0, 0.5) var move_speed: float = 5.0
## 端点停留时间 (秒, 到达端点后暂停多久再返回)
@export_range(0.0, 5.0, 0.1) var pause_at_ends: float = 0.5
## 缓动区比例 (0~0.5, 越大减速区越长)
@export_range(0.0, 0.5, 0.05) var ease_ratio: float = 0.2

@export_group("轨道视觉")
## 是否显示轨道导轨
@export var show_rail: bool = true
## 导轨颜色
@export var rail_color: Color = Color(0.3, 0.3, 0.35)

@export_group("物理")
## 平台表面摩擦力 (高值防止赛车滑动)
@export_range(0.5, 3.0, 0.1) var surface_friction: float = 1.5


# ---- 内部 ----
var _platform: AnimatableBody3D = null
var _platform_area: Area3D = null   # 平台上方检测区, 用于"粘"住赛车
var _progress: float = 0.0      # 0 = start_offset, 1 = end_offset
var _direction: float = 1.0     # 1=去程, -1=回程
var _pause_timer: float = 0.0   # 端点暂停计时
var _total_distance: float = 0.0
var _prev_platform_pos: Vector3 = Vector3.ZERO  # 上一帧平台位置, 用于计算 delta


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_platform = null
	_progress = 0.0
	_direction = 1.0
	_pause_timer = 0.0
	_total_distance = start_offset.distance_to(end_offset)

	# --- 轨道导轨 (视觉) ---
	if show_rail and _total_distance > 0.1:
		var rail_mesh := MeshInstance3D.new()
		rail_mesh.name = "RailMesh"
		# 用细长的 BoxMesh 表示轨道
		var rmesh := BoxMesh.new()
		rmesh.size = Vector3(0.15, 0.15, _total_distance)
		rail_mesh.mesh = rmesh
		# 轨道中点
		var mid: Vector3 = (start_offset + end_offset) * 0.5
		rail_mesh.position = mid
		# 朝向: 从 start 指向 end
		if _total_distance > 0.01:
			var dir: Vector3 = (end_offset - start_offset).normalized()
			rail_mesh.look_at_from_position(mid, mid + dir, Vector3.UP)
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = rail_color
		rmat.metallic = 0.6
		rmat.roughness = 0.4
		rail_mesh.material_override = rmat
		add_child(rail_mesh)
		# 第二根导轨 (平行偏移)
		var rail2 := rail_mesh.duplicate() as MeshInstance3D
		rail2.position += Vector3(platform_width * 0.4, 0.0, 0.0)
		add_child(rail2)
		var rail3 := rail_mesh.duplicate() as MeshInstance3D
		rail3.position -= Vector3(platform_width * 0.4, 0.0, 0.0)
		add_child(rail3)

	# --- 平台 (AnimatableBody3D) ---
	_platform = AnimatableBody3D.new()
	_platform.name = "SliderPlatform"
	_platform.collision_layer = 1
	_platform.collision_mask = 0
	_platform.sync_to_physics = true

	# 物理材质 (高摩擦防止赛车打滑)
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = surface_friction
	phys_mat.bounce = 0.0
	_platform.physics_material_override = phys_mat

	# 碰撞形状
	var col := CollisionShape3D.new()
	var cbox := BoxShape3D.new()
	cbox.size = Vector3(platform_width, platform_thickness, platform_length)
	col.shape = cbox
	_platform.add_child(col)

	# 视觉
	var pmesh_inst := MeshInstance3D.new()
	var pmesh := BoxMesh.new()
	pmesh.size = Vector3(platform_width, platform_thickness, platform_length)
	pmesh_inst.mesh = pmesh
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = platform_color
	pmat.metallic = 0.3
	pmat.roughness = 0.6
	pmesh_inst.material_override = pmat
	_platform.add_child(pmesh_inst)

	# --- 平台上方检测区 (Area3D) ---
	# 用于检测站在平台上的赛车, 平台下降时主动同步赛车位置防止陷落
	_platform_area = Area3D.new()
	_platform_area.name = "PlatformStickArea"
	_platform_area.collision_layer = 0
	_platform_area.collision_mask = 2  # car layer
	_platform_area.monitoring = true
	_platform_area.monitorable = false
	var area_shape := CollisionShape3D.new()
	var area_box := BoxShape3D.new()
	# 检测区: 比平台稍宽, 上方延伸几米 (涵盖赛车球心高度)
	area_box.size = Vector3(platform_width + 1.0, 4.0, platform_length + 1.0)
	area_shape.shape = area_box
	# 中心在平台顶面上方 2m (4m高的一半)
	area_shape.position = Vector3(0.0, platform_thickness * 0.5 + 2.0, 0.0)
	_platform_area.add_child(area_shape)
	_platform.add_child(_platform_area)

	# 初始位置
	_platform.position = start_offset
	_prev_platform_pos = global_position + global_transform.basis * start_offset
	add_child(_platform)


func _physics_process(delta: float) -> void:
	if _platform == null or _total_distance < 0.01:
		return

	# 端点暂停
	if _pause_timer > 0.0:
		_pause_timer -= delta
		return

	# 匀速推进 progress (不用缓动乘速度, 改用 smoothstep 插值位置)
	var step: float = (move_speed * delta) / _total_distance
	_progress += step * _direction

	# 到达端点
	if _progress >= 1.0:
		_progress = 1.0
		_direction = -1.0
		_pause_timer = pause_at_ends
	elif _progress <= 0.0:
		_progress = 0.0
		_direction = 1.0
		_pause_timer = pause_at_ends

	# 用缓动曲线映射 progress → 实际位置比例 (两端慢中间快)
	var eased_t: float = _ease_progress(_progress)

	# 更新平台位置 (世界坐标)
	var target_local: Vector3 = start_offset.lerp(end_offset, eased_t)
	var new_platform_pos: Vector3 = global_position + global_transform.basis * target_local
	_platform.global_transform = Transform3D(
		global_transform.basis,
		new_platform_pos
	)

	# --- 粘附逻辑: 平台移动时同步上方的赛车 ---
	# AnimatableBody3D 上升时能推车, 但下降/水平移动时车会脱离
	# 解决: 每帧把平台的位移 delta 也加到站在上面的赛车身上
	var platform_delta: Vector3 = new_platform_pos - _prev_platform_pos
	_prev_platform_pos = new_platform_pos
	if _platform_area and platform_delta.length() > 0.001:
		for body in _platform_area.get_overlapping_bodies():
			if body is RigidBody3D:
				# 只在赛车实际在平台上方时同步 (不要同步平台下方穿过的)
				var car_bottom: float = body.global_position.y - 1.0  # 球心约高 1m
				var platform_top: float = new_platform_pos.y + platform_thickness * 0.5
				if car_bottom < platform_top + 2.0 and car_bottom > platform_top - 1.0:
					# 移动赛车: 直接修改位置确保跟随
					body.global_position += platform_delta
					# 如果平台在下降, 还要确保赛车竖直速度不会导致弹跳
					if platform_delta.y < -0.001:
						# 把赛车的竖直速度限制为不超过平台下降速度 (避免反弹)
						var plat_vy: float = platform_delta.y / delta
						if body.linear_velocity.y > plat_vy:
							body.linear_velocity.y = plat_vy


func _ease_progress(t: float) -> float:
	## 缓动映射: 输入线性 0~1, 输出带两端减速的 0~1
	## 两端有 ease_ratio 比例的减速区, 中间匀速
	if ease_ratio < 0.001:
		return t
	# 加速区 (0 → ease_ratio): smoothstep 0→1 映射到 0→ease_ratio 输出
	if t < ease_ratio:
		var local: float = t / ease_ratio  # 0~1
		return ease_ratio * (local * local * (3.0 - 2.0 * local))
	# 减速区 (1-ease_ratio → 1): smoothstep 1→0 映射
	elif t > (1.0 - ease_ratio):
		var local: float = (1.0 - t) / ease_ratio  # 1~0
		return 1.0 - ease_ratio * (local * local * (3.0 - 2.0 * local))
	# 中间匀速区: 线性插值
	else:
		var mid_range: float = 1.0 - 2.0 * ease_ratio
		var mid_t: float = (t - ease_ratio) / mid_range  # 0~1 在中间段
		return ease_ratio + mid_t * mid_range


func reset_state() -> void:
	## 按 B 复位时重置滑块位置到起点
	_progress = 0.0
	_direction = 1.0
	_pause_timer = 0.0
	if _platform:
		var start_world: Vector3 = global_position + global_transform.basis * start_offset
		_platform.global_transform = Transform3D(global_transform.basis, start_world)
		_prev_platform_pos = start_world


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "platform_width", "label": "平台宽度(m)", "min": 3.0, "max": 20.0, "step": 0.5, "value": platform_width},
		{"key": "platform_length", "label": "平台长度(m)", "min": 3.0, "max": 20.0, "step": 0.5, "value": platform_length},
		{"key": "platform_thickness", "label": "平台厚度(m)", "min": 0.3, "max": 3.0, "step": 0.1, "value": platform_thickness},
		{"key": "move_speed", "label": "移动速度(m/s)", "min": 1.0, "max": 30.0, "step": 0.5, "value": move_speed},
		{"key": "end_offset_x", "label": "终点X偏移(m)", "min": -50.0, "max": 50.0, "step": 1.0, "value": end_offset.x},
		{"key": "end_offset_y", "label": "终点Y偏移(m)", "min": -50.0, "max": 50.0, "step": 1.0, "value": end_offset.y},
		{"key": "end_offset_z", "label": "终点Z偏移(m)", "min": -50.0, "max": 50.0, "step": 1.0, "value": end_offset.z},
		{"key": "pause_at_ends", "label": "端点停留(s)", "min": 0.0, "max": 5.0, "step": 0.1, "value": pause_at_ends},
		{"key": "ease_ratio", "label": "缓动区比例", "min": 0.0, "max": 0.5, "step": 0.05, "value": ease_ratio},
		{"key": "surface_friction", "label": "表面摩擦力", "min": 0.5, "max": 3.0, "step": 0.1, "value": surface_friction},
	]

var _rebuild_pending: bool = false

func set_editable_param(key: String, value: float) -> void:
	match key:
		"platform_width": platform_width = value
		"platform_length": platform_length = value
		"platform_thickness": platform_thickness = value
		"move_speed": move_speed = value
		"end_offset_x": end_offset.x = value
		"end_offset_y": end_offset.y = value
		"end_offset_z": end_offset.z = value
		"pause_at_ends": pause_at_ends = value
		"ease_ratio": ease_ratio = value
		"surface_friction": surface_friction = value
	if not _rebuild_pending:
		_rebuild_pending = true
		call_deferred("_deferred_rebuild")

func _deferred_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()
