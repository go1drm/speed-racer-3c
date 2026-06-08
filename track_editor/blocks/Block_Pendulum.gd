extends Node3D
class_name Block_Pendulum
## ============================================================
##  钟摆平台机关 (Pendulum Platform)
## ============================================================
## 一块平台被上方某点挂住, 做简谐运动 (钟摆).
## 赛车可以乘坐它去往前方.
##
## 物理原理:
##   使用 AnimatableBody3D, 每帧手动计算钟摆运动的位置.
##   简谐运动公式: θ(t) = max_angle × sin(ω×t + phase)
##   ω = 2π / period
##   平台位置 = 圆心 + 摆臂长度 × sin(θ) 水平 + cos(θ) 垂直
##
## 为什么不用 RigidBody + Joint:
##   因为需要精确控制摆动节奏和幅度, 且 AnimatableBody3D 能稳定带动赛车.
##   RigidBody 钟摆会因赛车重量改变周期, 不可控.
##
## 3C 照顾:
##   - 平台表面高摩擦 (赛车不滑落)
##   - 摆动平滑无突变 (简谐运动本身就是连续的)
##   - 平台始终保持水平 (赛车不会因倾斜翻车)
## ============================================================

@export_group("平台")
## 平台宽度 (X, 米)
@export_range(3.0, 20.0, 0.5) var platform_width: float = 6.0
## 平台长度 (Z, 赛车行进方向, 米)
@export_range(3.0, 20.0, 0.5) var platform_length: float = 8.0
## 平台厚度 (Y, 米)
@export_range(0.3, 2.0, 0.1) var platform_thickness: float = 0.5
## 平台颜色
@export var platform_color: Color = Color(0.4, 0.35, 0.5)

@export_group("摆动")
## 摆臂长度 (从悬挂点到平台中心, 米)
@export_range(3.0, 30.0, 0.5) var arm_length: float = 10.0
## 最大摆动角度 (度, 从垂直位置算起)
@export_range(5.0, 75.0, 5.0) var max_angle_deg: float = 30.0
## 摆动周期 (秒, 一个完整来回)
@export_range(1.0, 10.0, 0.5) var period: float = 4.0
## 初始相位 (度, 0=从中间开始, 90=从最右开始)
@export_range(0.0, 360.0, 15.0) var phase_deg: float = 0.0
## 摆动方向轴 (0=沿X轴摆(左右), 1=沿Z轴摆(前后))
@export_range(0, 1, 1) var swing_axis: int = 0

@export_group("悬挂点")
## 悬挂点高度 (相对机关位置向上, 米)
@export_range(5.0, 40.0, 1.0) var hang_height: float = 15.0
## 是否显示绳子/连杆
@export var show_rope: bool = true
## 绳子颜色
@export var rope_color: Color = Color(0.6, 0.55, 0.4)

@export_group("物理")
## 平台表面摩擦力
@export_range(0.5, 3.0, 0.1) var surface_friction: float = 1.5


# ---- 内部 ----
var _platform: AnimatableBody3D = null
var _rope_mesh: MeshInstance3D = null
var _time: float = 0.0


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_platform = null
	_rope_mesh = null
	_time = 0.0

	# --- 悬挂点视觉 (小球标记) ---
	var hang_marker := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.3
	hm.height = 0.6
	hang_marker.mesh = hm
	hang_marker.position = Vector3(0.0, hang_height, 0.0)
	var hmat := StandardMaterial3D.new()
	hmat.albedo_color = Color(0.7, 0.3, 0.2)
	hmat.metallic = 0.6
	hang_marker.material_override = hmat
	add_child(hang_marker)

	# --- 绳子/连杆 (会每帧更新) ---
	if show_rope:
		_rope_mesh = MeshInstance3D.new()
		_rope_mesh.name = "RopeMesh"
		var rm := CylinderMesh.new()
		rm.top_radius = 0.06
		rm.bottom_radius = 0.06
		rm.height = arm_length
		rm.radial_segments = 6
		_rope_mesh.mesh = rm
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = rope_color
		rmat.metallic = 0.3
		_rope_mesh.material_override = rmat
		add_child(_rope_mesh)

	# --- 平台 (AnimatableBody3D) ---
	_platform = AnimatableBody3D.new()
	_platform.name = "PendulumPlatform"
	_platform.collision_layer = 1
	_platform.collision_mask = 0
	_platform.sync_to_physics = true

	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = surface_friction
	phys_mat.bounce = 0.0
	_platform.physics_material_override = phys_mat

	var col := CollisionShape3D.new()
	var cbox := BoxShape3D.new()
	cbox.size = Vector3(platform_width, platform_thickness, platform_length)
	col.shape = cbox
	_platform.add_child(col)

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

	add_child(_platform)

	# 初始位置
	_update_pendulum_position(0.0)


func _physics_process(delta: float) -> void:
	if _platform == null:
		return
	_time += delta
	_update_pendulum_position(_time)


func _update_pendulum_position(t: float) -> void:
	## 简谐运动: θ = max_angle × sin(ω×t + phase)
	## 平台位置 = 悬挂点 + 摆臂方向 × arm_length
	var omega: float = TAU / maxf(period, 0.1)
	var phase_rad: float = deg_to_rad(phase_deg)
	var theta: float = deg_to_rad(max_angle_deg) * sin(omega * t + phase_rad)

	# 悬挂点 (世界坐标)
	var hang_pos: Vector3 = global_position + Vector3(0.0, hang_height, 0.0)

	# 平台位置: 悬挂点 + 摆臂终点
	# swing_axis=0: 沿X轴摆 (左右), swing_axis=1: 沿Z轴摆 (前后)
	var platform_offset: Vector3
	if swing_axis == 0:
		# 沿 X 摆: X = sin(θ) × arm, Y = -cos(θ) × arm
		platform_offset = Vector3(sin(theta) * arm_length, -cos(theta) * arm_length, 0.0)
	else:
		# 沿 Z 摆: Z = sin(θ) × arm, Y = -cos(θ) × arm
		platform_offset = Vector3(0.0, -cos(theta) * arm_length, sin(theta) * arm_length)

	var plat_world_pos: Vector3 = hang_pos + global_transform.basis * platform_offset

	# 平台保持水平 (不随摆动倾斜, 赛车更好驾驶)
	_platform.global_transform = Transform3D(global_transform.basis, plat_world_pos)

	# 更新绳子视觉 (从悬挂点到平台中心)
	if _rope_mesh:
		var rope_center: Vector3 = (hang_pos + plat_world_pos) * 0.5
		var rope_dir: Vector3 = (plat_world_pos - hang_pos)
		var rope_len: float = rope_dir.length()
		_rope_mesh.global_position = rope_center
		# 让圆柱朝向平台方向
		if rope_len > 0.01:
			var up: Vector3 = rope_dir.normalized()
			# 构造 basis: Y 轴沿绳子方向
			var arbitrary: Vector3 = Vector3.RIGHT if absf(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
			var side: Vector3 = up.cross(arbitrary).normalized()
			var fwd: Vector3 = side.cross(up).normalized()
			_rope_mesh.global_transform.basis = Basis(side, up, fwd)
		# 更新绳子长度
		var rm: CylinderMesh = _rope_mesh.mesh as CylinderMesh
		if rm and absf(rm.height - rope_len) > 0.01:
			rm.height = rope_len


func reset_state() -> void:
	## 按 B 复位时重置钟摆计时 (从初始相位重新开始)
	_time = 0.0


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "platform_width", "label": "平台宽度(m)", "min": 3.0, "max": 20.0, "step": 0.5, "value": platform_width},
		{"key": "platform_length", "label": "平台长度(m)", "min": 3.0, "max": 20.0, "step": 0.5, "value": platform_length},
		{"key": "platform_thickness", "label": "平台厚度(m)", "min": 0.3, "max": 2.0, "step": 0.1, "value": platform_thickness},
		{"key": "arm_length", "label": "摆臂长度(m)", "min": 3.0, "max": 30.0, "step": 0.5, "value": arm_length},
		{"key": "max_angle_deg", "label": "最大摆角(°)", "min": 5.0, "max": 75.0, "step": 5.0, "value": max_angle_deg},
		{"key": "period", "label": "摆动周期(s)", "min": 1.0, "max": 10.0, "step": 0.5, "value": period},
		{"key": "phase_deg", "label": "初始相位(°)", "min": 0.0, "max": 360.0, "step": 15.0, "value": phase_deg},
		{"key": "swing_axis", "label": "摆动轴(0=左右,1=前后)", "min": 0, "max": 1, "step": 1, "value": swing_axis},
		{"key": "hang_height", "label": "悬挂点高度(m)", "min": 5.0, "max": 40.0, "step": 1.0, "value": hang_height},
		{"key": "surface_friction", "label": "表面摩擦力", "min": 0.5, "max": 3.0, "step": 0.1, "value": surface_friction},
	]

var _rebuild_pending: bool = false

func set_editable_param(key: String, value: float) -> void:
	match key:
		"platform_width": platform_width = value
		"platform_length": platform_length = value
		"platform_thickness": platform_thickness = value
		"arm_length": arm_length = value
		"max_angle_deg": max_angle_deg = value
		"period": period = value
		"phase_deg": phase_deg = value
		"swing_axis": swing_axis = int(value)
		"hang_height": hang_height = value
		"surface_friction": surface_friction = value
	if not _rebuild_pending:
		_rebuild_pending = true
		call_deferred("_deferred_rebuild")

func _deferred_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()
