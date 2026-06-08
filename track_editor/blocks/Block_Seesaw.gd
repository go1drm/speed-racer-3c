extends Node3D
class_name Block_Seesaw
## ============================================================
##  跷跷板机关 (Seesaw)
## ============================================================
## 一个绕中心支点自由旋转的平台. 赛车站在一侧会使该侧下沉.
## 两辆车需要左右平衡通过, 单车需要快速冲过.
##
## 物理原理:
##   平台是 RigidBody3D, 通过 HingeJoint3D 连接到固定支点.
##   赛车 (RigidBody3D) 站在平台上时, 重力自然使一侧下压.
##   HingeJoint 限制只能绕一个轴旋转 (Z轴, 即赛车行进方向的横轴).
##   无需手动施力, 物理引擎自动处理重力+扭矩.
##
## 3C 照顾:
##   - 平台表面摩擦力适中 (不打滑也不粘)
##   - 平台有角度限制防止完全翻转
##   - 平台有轻微阻尼防止疯狂震荡
## ============================================================

@export_group("平台")
## 平台长度 (赛车行进方向, 米)
@export_range(4.0, 40.0, 1.0) var platform_length: float = 16.0
## 平台宽度 (左右方向, 即跷跷板的跷动方向, 米)
@export_range(4.0, 30.0, 1.0) var platform_width: float = 12.0
## 平台厚度 (米)
@export_range(0.2, 2.0, 0.1) var platform_thickness: float = 0.5
## 平台质量 (kg, 影响被赛车压动的难易程度)
@export_range(10.0, 500.0, 10.0) var platform_mass: float = 80.0
## 平台颜色
@export var platform_color: Color = Color(0.5, 0.45, 0.35)

@export_group("支点")
## 支点高度 (从地面到平台中心, 米)
@export_range(1.0, 15.0, 0.5) var pivot_height: float = 3.0
## 支点柱半径 (米)
@export_range(0.1, 1.0, 0.05) var pivot_radius: float = 0.3

@export_group("物理")
## 最大倾斜角度 (度, 超过此角度会被 joint 限制住)
@export_range(10.0, 80.0, 5.0) var max_tilt_deg: float = 35.0
## 角阻尼 (防止疯狂震荡, 越大越稳)
@export_range(0.0, 10.0, 0.5) var angular_damping_val: float = 2.0
## 平台表面摩擦力
@export_range(0.1, 2.0, 0.1) var surface_friction: float = 0.8
## 平台弹性 (0=不弹, 1=完全弹)
@export_range(0.0, 1.0, 0.05) var surface_bounce: float = 0.05


# ---- 内部 ----
var _platform_body: RigidBody3D = null
var _pivot_body: StaticBody3D = null
var _joint: HingeJoint3D = null


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_platform_body = null
	_pivot_body = null
	_joint = null

	# --- 支点柱 (固定, StaticBody3D) ---
	_pivot_body = StaticBody3D.new()
	_pivot_body.name = "PivotBody"
	_pivot_body.collision_layer = 1
	_pivot_body.collision_mask = 0
	# 柱子碰撞
	var pivot_shape := CollisionShape3D.new()
	var pcyl := CylinderShape3D.new()
	pcyl.radius = pivot_radius
	pcyl.height = pivot_height
	pivot_shape.shape = pcyl
	pivot_shape.position = Vector3(0.0, pivot_height * 0.5, 0.0)
	_pivot_body.add_child(pivot_shape)
	# 柱子视觉
	var pivot_mesh := MeshInstance3D.new()
	var pmesh := CylinderMesh.new()
	pmesh.top_radius = pivot_radius
	pmesh.bottom_radius = pivot_radius * 1.3
	pmesh.height = pivot_height
	pmesh.radial_segments = 12
	pivot_mesh.mesh = pmesh
	pivot_mesh.position = Vector3(0.0, pivot_height * 0.5, 0.0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.4, 0.4, 0.45)
	pmat.metallic = 0.5
	pmat.roughness = 0.5
	pivot_mesh.material_override = pmat
	_pivot_body.add_child(pivot_mesh)
	add_child(_pivot_body)

	# --- 平台 (RigidBody3D, 能被赛车重力压动) ---
	_platform_body = RigidBody3D.new()
	_platform_body.name = "PlatformBody"
	_platform_body.mass = platform_mass
	_platform_body.collision_layer = 1   # 世界层, 车能碰到
	_platform_body.collision_mask = 3    # 检测世界+车
	_platform_body.angular_damp = angular_damping_val
	_platform_body.linear_damp = 5.0     # 限制平移 (joint 管旋转, 但防意外位移)
	_platform_body.gravity_scale = 1.0
	# 锁定除 Z 轴旋转外的所有旋转 (跷跷板只绕 Z 轴跷)
	# 注: Godot 4 的 lock_rotation 会锁全部, 我们用 joint 限制替代
	_platform_body.can_sleep = false     # 防止平台睡眠后不响应

	# 物理材质 (影响赛车在平台上的手感)
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = surface_friction
	phys_mat.bounce = surface_bounce
	_platform_body.physics_material_override = phys_mat

	# 平台碰撞形状
	var plat_shape := CollisionShape3D.new()
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(platform_width, platform_thickness, platform_length)
	plat_shape.shape = pbox
	_platform_body.add_child(plat_shape)

	# 平台视觉
	var plat_mesh := MeshInstance3D.new()
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(platform_width, platform_thickness, platform_length)
	plat_mesh.mesh = bmesh
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = platform_color
	bmat.metallic = 0.2
	bmat.roughness = 0.7
	plat_mesh.material_override = bmat
	_platform_body.add_child(plat_mesh)

	# 中轴线标记 (一条沿 Z 轴 / 赛车行进方向的亮黄色线, 标示跷跷板支点位置)
	# 放在平台表面上方, 方便玩家一眼看到"重心线在哪"
	var axis_mesh := MeshInstance3D.new()
	axis_mesh.name = "AxisLine"
	var amesh := BoxMesh.new()
	# 沿 Z 方向 (赛车行进方向) 贯穿平台, 微凸出于平台表面
	amesh.size = Vector3(0.12, 0.12, platform_length + 0.5)
	axis_mesh.mesh = amesh
	axis_mesh.position = Vector3(0.0, platform_thickness * 0.5 + 0.06, 0.0)
	var amat := StandardMaterial3D.new()
	amat.albedo_color = Color(1.0, 0.85, 0.0)
	amat.emission_enabled = true
	amat.emission = Color(1.0, 0.85, 0.0)
	amat.emission_energy_multiplier = 1.2
	axis_mesh.material_override = amat
	_platform_body.add_child(axis_mesh)

	# 平台初始位置: 支点顶部
	_platform_body.position = Vector3(0.0, pivot_height, 0.0)
	add_child(_platform_body)

	# --- HingeJoint3D: 连接支点和平台, 只允许绕 Z 轴旋转 ---
	# (Z 轴 = 赛车行进方向, 所以跷跷板是左右跷动)
	_joint = HingeJoint3D.new()
	_joint.name = "SeesawHinge"
	# Joint 位置在支点顶部 (平台中心)
	_joint.position = Vector3(0.0, pivot_height, 0.0)
	# 旋转 joint 使其铰链轴对齐 Z 轴 (默认 HingeJoint 绕 local Z 旋转)
	# 我们需要跷跷板绕赛车行进方向(Z)的横轴跷 → 即绕 local Z
	_joint.node_a = _pivot_body.get_path()
	_joint.node_b = _platform_body.get_path()

	# 角度限制
	_joint.set("angular_limit/enable", true)
	_joint.set("angular_limit/lower", deg_to_rad(-max_tilt_deg))
	_joint.set("angular_limit/upper", deg_to_rad(max_tilt_deg))
	# 阻尼 (softness < 1 增加阻力)
	_joint.set("angular_limit/softness", 0.8)
	_joint.set("angular_limit/relaxation", 0.5)

	add_child(_joint)


func reset_state() -> void:
	## 按 B 复位时让跷跷板回正 (清除角速度, 回到水平)
	if _platform_body:
		_platform_body.angular_velocity = Vector3.ZERO
		_platform_body.linear_velocity = Vector3.ZERO
		# 回正: 只保留 Y 轴旋转 (水平朝向), 清掉 X/Z 倾斜
		var yaw: float = _platform_body.rotation.y
		_platform_body.rotation = Vector3(0.0, yaw, 0.0)


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "platform_length", "label": "平台长度(m)", "min": 4.0, "max": 40.0, "step": 1.0, "value": platform_length},
		{"key": "platform_width", "label": "平台宽度(m)", "min": 4.0, "max": 30.0, "step": 1.0, "value": platform_width},
		{"key": "platform_thickness", "label": "平台厚度(m)", "min": 0.2, "max": 2.0, "step": 0.1, "value": platform_thickness},
		{"key": "platform_mass", "label": "平台质量(kg)", "min": 10.0, "max": 500.0, "step": 10.0, "value": platform_mass},
		{"key": "pivot_height", "label": "支点高度(m)", "min": 1.0, "max": 15.0, "step": 0.5, "value": pivot_height},
		{"key": "pivot_radius", "label": "支点柱半径(m)", "min": 0.1, "max": 1.0, "step": 0.05, "value": pivot_radius},
		{"key": "max_tilt_deg", "label": "最大倾斜角(°)", "min": 10.0, "max": 80.0, "step": 5.0, "value": max_tilt_deg},
		{"key": "angular_damping_val", "label": "角阻尼", "min": 0.0, "max": 10.0, "step": 0.5, "value": angular_damping_val},
		{"key": "surface_friction", "label": "表面摩擦力", "min": 0.1, "max": 2.0, "step": 0.1, "value": surface_friction},
		{"key": "surface_bounce", "label": "表面弹性", "min": 0.0, "max": 1.0, "step": 0.05, "value": surface_bounce},
	]

var _rebuild_pending: bool = false

func set_editable_param(key: String, value: float) -> void:
	match key:
		"platform_length": platform_length = value
		"platform_width": platform_width = value
		"platform_thickness": platform_thickness = value
		"platform_mass": platform_mass = value
		"pivot_height": pivot_height = value
		"pivot_radius": pivot_radius = value
		"max_tilt_deg": max_tilt_deg = value
		"angular_damping_val": angular_damping_val = value
		"surface_friction": surface_friction = value
		"surface_bounce": surface_bounce = value
	if not _rebuild_pending:
		_rebuild_pending = true
		call_deferred("_deferred_rebuild")

func _deferred_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()
