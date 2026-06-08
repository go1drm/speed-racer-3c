extends Node3D
class_name Block_Windmill
## ============================================================
##  大风车机关 (Windmill) — 第5版: 严密物理碰撞
## ============================================================
## 使用 AnimatableBody3D 实现扇叶实体碰撞, 车绝对不能穿模.
##
## 核心原理:
##   AnimatableBody3D 不嵌套在旋转节点下,
##   而是每帧在 _physics_process 中手动计算全局 Transform 并赋值.
##   Godot 物理引擎会根据两帧之间的 Transform 差异自动推开碰撞的 RigidBody.
##   这是 Godot 官方推荐的"运动学物体推刚体"方案.
##
## 结构:
##   柱子 (StaticBody3D + CylinderMesh)
##   BladesVisual (Node3D, 每帧 rotate_y — 纯视觉)
##     └─ N 个扇叶 MeshInstance3D
##   N 个 AnimatableBody3D (直接挂在 self 下, 不在旋转层级内)
##     └─ CollisionShape3D (BoxShape3D)
## ============================================================

@export_group("柱子")
## 柱子高度 (米)
@export_range(1.0, 30.0, 0.5) var pole_height: float = 6.0
## 柱子半径 (米)
@export_range(0.1, 3.0, 0.1) var pole_radius: float = 0.5
## 柱子颜色
@export var pole_color: Color = Color(0.4, 0.35, 0.3)

@export_group("扇叶")
## 扇叶数量
@export_range(2, 8, 1) var blade_count: int = 4
## 扇叶长度 (从中心到尖端, 米)
@export_range(2.0, 30.0, 0.5) var blade_length: float = 8.0
## 扇叶宽度 (厚度方向, 米)
@export_range(0.2, 5.0, 0.1) var blade_width: float = 1.5
## 扇叶厚度 (碰撞方向, 米)
@export_range(0.1, 2.0, 0.1) var blade_thickness: float = 0.4
## 扇叶安装高度 (从地面算, 米) — 扇叶中心 Y
@export_range(0.5, 25.0, 0.5) var blade_height: float = 2.0
## 扇叶颜色
@export var blade_color: Color = Color(0.85, 0.2, 0.2)

@export_group("旋转")
## 旋转速度 (度/秒, 正=逆时针俯视)
@export_range(-360.0, 360.0, 5.0) var rotation_speed_deg: float = 90.0

@export_group("推力")
## 额外推力倍率: 碰撞时除了物理引擎自带的推力外, 额外施加的切线力倍数
##   0 = 纯靠物理碰撞推 (可能推力不够猛)
##   50 = 额外加力让车飞出去 (配合碰撞, 不穿模且有力度)
##   推荐 30~80
@export_range(0.0, 200.0, 5.0) var push_force: float = 50.0


# ---- 内部 ----
var _blades_visual: Node3D = null          # 纯视觉旋转节点
var _blade_bodies: Array[AnimatableBody3D] = []  # 碰撞体列表
var _current_angle_rad: float = 0.0        # 当前旋转角度


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_blades_visual = null
	_blade_bodies.clear()
	_current_angle_rad = 0.0

	# --- 柱子 ---
	var pole_body := StaticBody3D.new()
	pole_body.name = "PoleBody"
	pole_body.collision_layer = 1
	pole_body.collision_mask = 0
	var pole_shape := CollisionShape3D.new()
	var pcyl := CylinderShape3D.new()
	pcyl.radius = pole_radius
	pcyl.height = pole_height
	pole_shape.shape = pcyl
	pole_shape.position = Vector3(0.0, pole_height * 0.5, 0.0)
	pole_body.add_child(pole_shape)
	var pole_mesh := MeshInstance3D.new()
	var pmesh := CylinderMesh.new()
	pmesh.top_radius = pole_radius
	pmesh.bottom_radius = pole_radius
	pmesh.height = pole_height
	pmesh.radial_segments = 12
	pole_mesh.mesh = pmesh
	pole_mesh.position = Vector3(0.0, pole_height * 0.5, 0.0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = pole_color
	pmat.metallic = 0.3
	pmat.roughness = 0.7
	pole_mesh.material_override = pmat
	pole_body.add_child(pole_mesh)
	add_child(pole_body)

	# --- 扇叶视觉组 (纯视觉, 跟随角度旋转) ---
	_blades_visual = Node3D.new()
	_blades_visual.name = "BladesVisual"
	_blades_visual.position = Vector3(0.0, blade_height, 0.0)
	add_child(_blades_visual)

	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = blade_color
	bmat.metallic = 0.6
	bmat.roughness = 0.4

	for i in range(blade_count):
		var angle_rad: float = TAU * float(i) / float(blade_count)

		# -- 视觉 mesh (挂在旋转组下, 自动跟旋转) --
		var blade_vis := Node3D.new()
		blade_vis.name = "BladeVis_%d" % i
		blade_vis.rotation.y = angle_rad
		_blades_visual.add_child(blade_vis)

		var blade_mesh := MeshInstance3D.new()
		var bbmesh := BoxMesh.new()
		bbmesh.size = Vector3(blade_length, blade_width, blade_thickness)
		blade_mesh.mesh = bbmesh
		blade_mesh.material_override = bmat
		blade_mesh.position = Vector3(blade_length * 0.5, 0.0, 0.0)
		blade_vis.add_child(blade_mesh)

		# -- AnimatableBody3D (直接挂在 self 下, 不在任何旋转层级内) --
		# 每帧手动设置 global_transform → 物理引擎自动推开碰到的 RigidBody
		var abody := AnimatableBody3D.new()
		abody.name = "BladeBody_%d" % i
		# collision_layer = 1 (世界), 让车 (layer 2, mask 1) 能碰到
		abody.collision_layer = 1
		abody.collision_mask = 0  # 不检测别人, 只被别人碰
		# sync_to_physics = true: 确保物理引擎严格同步位置
		abody.sync_to_physics = true
		var cshape := CollisionShape3D.new()
		var cbox := BoxShape3D.new()
		# 碰撞盒比视觉稍大一点点, 确保不穿模
		cbox.size = Vector3(blade_length, blade_width, blade_thickness + 0.1)
		cshape.shape = cbox
		abody.add_child(cshape)
		add_child(abody)
		_blade_bodies.append(abody)

	# 初始化物理体位置
	_update_blade_transforms(0.0)


func _physics_process(delta: float) -> void:
	if _blades_visual == null:
		return

	# 更新角度
	_current_angle_rad += deg_to_rad(rotation_speed_deg) * delta

	# 旋转视觉
	_blades_visual.rotation.y = _current_angle_rad

	# 更新每个 AnimatableBody3D 的 global_transform
	# 这是实现严密物理碰撞的核心:
	#   物理引擎会根据上一帧和本帧的 transform 差异计算出碰撞推力
	#   自动推开任何 RigidBody, 绝不穿模
	_update_blade_transforms(delta)


func _update_blade_transforms(_delta: float) -> void:
	## 手动计算每个扇叶 AnimatableBody3D 的全局位置/旋转
	## 不依赖节点层级, 直接数学计算
	var center: Vector3 = global_position + Vector3(0.0, blade_height, 0.0)
	var windmill_basis: Basis = global_transform.basis

	for i in range(_blade_bodies.size()):
		var blade_angle: float = _current_angle_rad + TAU * float(i) / float(blade_count)
		var abody: AnimatableBody3D = _blade_bodies[i]

		# 扇叶中心偏移: 沿扇叶方向(局部X)偏移 blade_length/2
		# 扇叶方向在水平面 (Y轴旋转): cos(angle) 朝 X, -sin(angle) 朝 Z (Godot 坐标系)
		var local_dir := Vector3(cos(blade_angle), 0.0, -sin(blade_angle))
		var blade_center_offset: Vector3 = local_dir * (blade_length * 0.5)

		# 全局位置 = 风车中心 + 旋转后的偏移
		var gpos: Vector3 = center + windmill_basis * blade_center_offset

		# 全局旋转 = 风车基础旋转 × 绕 Y 旋转 blade_angle
		var blade_basis := windmill_basis * Basis(Vector3.UP, blade_angle)

		# 设置 global_transform (触发物理引擎碰撞推力计算)
		abody.global_transform = Transform3D(blade_basis, gpos)

	# --- 额外推力: 对碰撞中的车施加切线力 (增强"扫飞"感) ---
	if push_force > 0.01:
		var axis: Vector3 = (windmill_basis * Vector3.UP).normalized()
		for abody in _blade_bodies:
			# 检测当前帧碰撞的物体 (通过 PhysicsServer 射线不可行,
			# 用 Area3D 重叠代替 — 但这里已经去掉 Area3D 了)
			# 改用: 遍历场景中的车, 检查距扇叶的距离
			# 这会在下面的 _apply_extra_push 里做
			pass
	_apply_extra_push()


func _apply_extra_push() -> void:
	## 对每个扇叶范围内的车施加额外切线力 (增强扫飞感)
	## 检测方式: 遍历所有 AnimatableBody3D, 用 PhysicsDirectSpaceState
	##   做 box intersect 查询范围内的 RigidBody
	if push_force < 0.01:
		return

	var space_state := get_world_3d().direct_space_state
	if space_state == null:
		return

	var axis: Vector3 = (global_transform.basis * Vector3.UP).normalized()
	var center: Vector3 = global_position + Vector3(0.0, blade_height, 0.0)

	for abody in _blade_bodies:
		# 用 intersect_shape 查询扇叶碰撞盒范围内的物体
		var query := PhysicsShapeQueryParameters3D.new()
		var qbox := BoxShape3D.new()
		# 检测范围比实际碰撞盒再大一点, 确保临近的车也受力
		qbox.size = Vector3(blade_length + 0.5, blade_width + 0.5, blade_thickness + 1.0)
		query.shape = qbox
		query.transform = abody.global_transform
		query.collision_mask = 2  # car layer
		query.exclude = [abody.get_rid()]

		var results: Array[Dictionary] = space_state.intersect_shape(query, 8)
		for result in results:
			var collider = result.get("collider")
			if collider == null or not collider is RigidBody3D:
				continue
			var car: RigidBody3D = collider as RigidBody3D
			# 切线方向 = 旋转轴 × (车位置 - 旋转中心)
			var r: Vector3 = car.global_position - center
			var tangent: Vector3 = axis.cross(r)
			if tangent.length() < 0.001:
				continue
			tangent = tangent.normalized()
			if rotation_speed_deg < 0.0:
				tangent = -tangent
			# 施加额外切线力 (F = push_force × mass → 加速度恒定)
			car.apply_central_force(tangent * push_force * car.mass)



func reset_state() -> void:
	## 按 B 复位时重置风车旋转角度到 0
	_current_angle_rad = 0.0


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "pole_height", "label": "柱子高度(m)", "min": 1.0, "max": 30.0, "step": 0.5, "value": pole_height},
		{"key": "pole_radius", "label": "柱子半径(m)", "min": 0.1, "max": 3.0, "step": 0.1, "value": pole_radius},
		{"key": "blade_count", "label": "扇叶数量", "min": 2, "max": 8, "step": 1, "value": blade_count},
		{"key": "blade_length", "label": "扇叶长度(m)", "min": 2.0, "max": 30.0, "step": 0.5, "value": blade_length},
		{"key": "blade_width", "label": "扇叶宽度(m)", "min": 0.2, "max": 5.0, "step": 0.1, "value": blade_width},
		{"key": "blade_thickness", "label": "扇叶厚度(m)", "min": 0.1, "max": 2.0, "step": 0.1, "value": blade_thickness},
		{"key": "blade_height", "label": "扇叶高度(m)", "min": 0.5, "max": 25.0, "step": 0.5, "value": blade_height},
		{"key": "rotation_speed_deg", "label": "旋转速度(°/s)", "min": -360.0, "max": 360.0, "step": 5.0, "value": rotation_speed_deg},
		{"key": "push_force", "label": "额外推力(m/s²)", "min": 0.0, "max": 200.0, "step": 5.0, "value": push_force},
	]

func set_editable_param(key: String, value: float) -> void:
	match key:
		"pole_height": pole_height = value
		"pole_radius": pole_radius = value
		"blade_count": blade_count = int(value)
		"blade_length": blade_length = value
		"blade_width": blade_width = value
		"blade_thickness": blade_thickness = value
		"blade_height": blade_height = value
		"rotation_speed_deg": rotation_speed_deg = value
		"push_force": push_force = value
	_rebuild()
