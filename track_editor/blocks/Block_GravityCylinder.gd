@tool
extends Node3D
## ============================================================
## 机关 - 反重力圆柱 (GravityCylinder)
## ============================================================
## 横躺的圆柱体, 玩家车在外表面滑行, 像 loop 轨道一样可以"倒挂"过去:
##   1) 进入触发区时: Area3D.gravity_space_override = REPLACE, gravity=0
##      → 区域内默认 Y 重力被屏蔽
##   2) 每物理帧主动给车施加 \"朝向圆柱中心轴\" 的吸附力 (= 自定义重力)
##      → 车会贴在圆柱外表面, 沿圆周走可以倒挂朝下开
##   3) 离开触发区时 Area 设置失效, 车恢复正常 Y 重力
##
## 物理 (核心数学):
##   设圆柱中心轴方向 axis_dir (block local 默认 +X)
##   车位置 P, 圆柱中心 C (= block.global_position)
##   车到轴的位移 R = P - C
##   R 沿 axis 的分量: R_axis = R · axis_dir × axis_dir
##   R 垂直于 axis 的分量: R_radial = R - R_axis     ← 这是 "离轴的径向" 向量
##   吸附力方向: -R_radial.normalized()              ← 朝向轴 (车被吸附到表面)
##   力大小: gravity_strength × car.mass             ← 模拟自定义重力
##
##   外表面行驶意味着力是\"朝向轴\" (向心力 = 重力)
##   离心力(向外) 由车的速度自然产生, 与吸附力平衡 → 车贴外表面跑
##
## 球体驱动注意事项:
##   car 的 RayCast 朝 -Y, 在圆柱顶/侧时会脱地 (检测不到地面)
##   → airborne=true, 引擎力略削减, 但车仍能被吸附力贴住表面
##   完美的解决要让 RayCast 朝 \"-radial_dir\" 方向, 但侵入 car.gd 太大
##   当前简化版: 只施加力, 不改 RayCast. 视觉/手感会有点漂浮但不影响玩法
##
## 子节点:
##   CylinderMesh (MeshInstance3D)  — 圆柱外观
##   PickBody (StaticBody3D)        — 编辑器选中盒
##   Trigger (Area3D)               — 包裹圆柱的扩大圆柱触发盒
##                                     gravity_space_override=REPLACE 屏蔽默认重力
## ============================================================

# ============================================================
# 几何参数
# ============================================================
## 圆柱半径 (米). 玩家车在这个半径的外表面上行驶
@export var cylinder_radius: float = 8.0:
	set(v):
		cylinder_radius = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 圆柱长度 (米, 沿轴向). 默认轴沿 block local +X
@export var cylinder_length: float = 30.0:
	set(v):
		cylinder_length = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 触发区扩展半径 (米). 在 cylinder_radius 之外多包裹这么多, 让车进入早一点抓到
##   推荐 3~6 (车长约 5m, 至少要够一个车长的"接近吸附距离")
@export var capture_padding: float = 4.0:
	set(v):
		capture_padding = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()

# ============================================================
# 物理参数
# ============================================================
## 吸附力强度 (m/s², 模拟自定义重力加速度)
##   推荐与 Godot 默认重力 (29) 相近, 太弱会被离心力甩开, 太强会硬贴死
##   30~50 = 强吸附, 离心力到一定速度才能挣脱
##   < 20 = 弱吸附, 慢车容易掉下圆柱
@export var gravity_strength: float = 35.0
## 是否抵消玩家在区域内的默认 Y 重力 (1=抵消, 0=不抵消和默认重力叠加)
##   默认 1 = 让吸附力是唯一作用力, 这才是\"反重力圆柱\"该有的体验
##   设 0 时车会同时被 Y 重力 + 圆柱吸附拉扯, 表现混乱
@export_range(0, 1, 1) var override_gravity: int = 1
## 边缘衰减距离 (米). 离开圆柱表面 fade_distance 后吸附力线性减弱到 0
##   防止车飞离表面太远后还被强行拉回
@export var fade_distance: float = 8.0

# ============================================================
# 视觉参数
# ============================================================
## 圆柱主色 (默认科幻紫蓝)
@export var cylinder_color: Color = Color(0.4, 0.5, 0.95, 1.0):
	set(v):
		cylinder_color = v
		if is_inside_tree(): _rebuild()
## 表面网格线颜色 (营造"重力网格"科幻感)
@export var grid_color: Color = Color(0.3, 0.85, 1.0, 1.0):
	set(v):
		grid_color = v
		if is_inside_tree(): _rebuild()
## 网格自发光强度 (0=暗, 2=明显发光)
@export var grid_emission: float = 1.2

# ============================================================
# 内部
# ============================================================
var _cyl_mesh: MeshInstance3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null
var _solid_body: StaticBody3D = null   # 真实物理碰撞体, 让车能撞/站到圆柱表面


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_cyl_mesh = null
	_pick_body = null
	_trigger_area = null
	_solid_body = null

	# ---------- 1. 圆柱 mesh ----------
	# Godot CylinderMesh 默认沿 Y 轴, 我们要沿 +X 轴, 所以加 90° rotation_z
	_cyl_mesh = MeshInstance3D.new()
	_cyl_mesh.name = "CylinderMesh"
	var cyl := CylinderMesh.new()
	cyl.top_radius = cylinder_radius
	cyl.bottom_radius = cylinder_radius
	cyl.height = cylinder_length
	cyl.radial_segments = 32
	cyl.rings = 1
	_cyl_mesh.mesh = cyl
	# 让圆柱沿 X 轴: rotate Z by 90°
	_cyl_mesh.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	# 圆柱中心放在原点, 上半部分超出地平面 (cylinder_radius 高度) 让车能从下方爬上来
	_cyl_mesh.position = Vector3(0.0, cylinder_radius, 0.0)
	var cm := StandardMaterial3D.new()
	cm.albedo_color = cylinder_color
	cm.metallic = 0.6
	cm.roughness = 0.35
	cm.emission_enabled = true
	cm.emission = grid_color
	cm.emission_energy_multiplier = grid_emission * 0.3
	# 用 detail 网格贴图模拟"重力网格" — 这里用纯色, 后续可换 grid texture
	_cyl_mesh.material_override = cm
	add_child(_cyl_mesh)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_cyl_mesh.owner = get_tree().edited_scene_root

	# ---------- 1a. 固体碰撞圆柱 (让车能撞/站在表面!) ----------
	# v2 修复 (2026-06-02 用户反馈"驶向它时直接穿过去了"):
	#   旧版只有视觉 mesh + Area3D 触发 + PickBody 编辑器选中盒, 没有任何 layer=1 (地面层)
	#   的实体碰撞 → 车直接从圆柱视觉里穿过去! 修复: 加一个 StaticBody3D layer=1 让车能撞.
	#
	# layer/mask 解释:
	#   layer = 1 (地面/赛道层) → 车的 ground_ray + 物理碰撞会检测到这个圆柱
	#   mask = 0  → 这个圆柱本身不需要"检测其他物体" (静态物体)
	# 形状: CylinderShape3D 沿 X 轴 (与 mesh 一致)
	_solid_body = StaticBody3D.new()
	_solid_body.name = "SolidBody"
	_solid_body.collision_layer = 1   # 第 1 层 = 默认地面层, 车的 ray + collision 都检测这层
	_solid_body.collision_mask = 0
	# 略增加摩擦, 让车在圆柱表面有抓地感, 但物理材质摩擦只在球-球/球-trimesh 接触时才生效
	# 这里圆柱是 primitive, Godot 用默认接触模型, 摩擦从车的 PhysicsMaterialOverride 决定
	var solid_shape := CollisionShape3D.new()
	solid_shape.name = "SolidShape"
	var solid_cyl := CylinderShape3D.new()
	solid_cyl.radius = cylinder_radius
	solid_cyl.height = cylinder_length
	solid_shape.shape = solid_cyl
	# 沿 X 轴 (与 mesh 一致): rotate Z 90°
	solid_shape.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	solid_shape.position = Vector3(0.0, cylinder_radius, 0.0)
	_solid_body.add_child(solid_shape)
	add_child(_solid_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_solid_body.owner = get_tree().edited_scene_root
		solid_shape.owner = get_tree().edited_scene_root

	# ---------- 1b. 网格圆环装饰 (沿圆柱长度方向每 4m 一圈, 营造科幻轨道感) ----------
	var ring_spacing: float = 4.0
	var num_rings: int = int(cylinder_length / ring_spacing) + 1
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = grid_color
	ring_mat.emission_enabled = true
	ring_mat.emission = grid_color
	ring_mat.emission_energy_multiplier = grid_emission
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in range(num_rings + 1):
		var ring := MeshInstance3D.new()
		ring.name = "Ring_%d" % i
		var torus := TorusMesh.new()
		torus.inner_radius = cylinder_radius - 0.1
		torus.outer_radius = cylinder_radius + 0.15  # 略凸出表面让网格可见
		torus.ring_segments = 8
		torus.rings = 32
		ring.mesh = torus
		# Torus 默认在 XZ 平面 (绕 Y 轴), 转到 YZ 平面 (绕 X 轴)
		ring.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
		# 沿 X 方向均匀分布
		var x_pos: float = -cylinder_length * 0.5 + i * (cylinder_length / num_rings)
		ring.position = Vector3(x_pos, cylinder_radius, 0.0)
		ring.material_override = ring_mat
		add_child(ring)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			ring.owner = get_tree().edited_scene_root

	# ---------- 2. 编辑器选中盒 (用扩大圆柱) ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pcyl := CylinderShape3D.new()
	pcyl.radius = cylinder_radius + 0.5
	pcyl.height = cylinder_length + 0.5
	pick_shape.shape = pcyl
	# 选中盒同样沿 X 轴
	pick_shape.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	pick_shape.position = Vector3(0.0, cylinder_radius, 0.0)
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 3. 触发 Area3D (扩大版圆柱, 包住车的"接近吸附区域") ----------
	# 关键: gravity_space_override=REPLACE + gravity=0 让 Area 内的车不受默认重力
	# 然后 _physics_process 自己 apply_central_force 给吸附力
	_trigger_area = Area3D.new()
	_trigger_area.name = "Trigger"
	_trigger_area.monitoring = false
	_trigger_area.monitorable = false
	add_child(_trigger_area)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_trigger_area.owner = get_tree().edited_scene_root
	var trigger_shape := CollisionShape3D.new()
	trigger_shape.name = "TriggerShape"
	var tcyl := CylinderShape3D.new()
	tcyl.radius = cylinder_radius + capture_padding
	tcyl.height = cylinder_length
	trigger_shape.shape = tcyl
	trigger_shape.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	trigger_shape.position = Vector3(0.0, cylinder_radius, 0.0)
	_trigger_area.add_child(trigger_shape)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		trigger_shape.owner = get_tree().edited_scene_root

	# ---------- 4. 仅运行时: 激活触发器 + 吸附逻辑 ----------
	if not Engine.is_editor_hint():
		_runtime_init_trigger()


func _runtime_init_trigger() -> void:
	if _trigger_area == null:
		return
	_trigger_area.monitoring = true
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2  # 探测 layer=2 的赛车
	# 关键: 屏蔽 Area 内的默认重力 (让我们自己施加吸附力时不被默认 Y 重力干扰)
	if override_gravity == 1:
		_trigger_area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
		_trigger_area.gravity = 0.0   # 大小为 0 即无重力
		_trigger_area.gravity_direction = Vector3(0, -1, 0)  # 方向无所谓 (大小=0)
	# 启动每帧吸附力施加
	set_physics_process(true)
	print("[Block_GravityCylinder] 反重力圆柱已激活 (轴沿 +X, 半径 %.1f, 长 %.1f)" % [cylinder_radius, cylinder_length])


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _trigger_area == null or not _trigger_area.monitoring:
		return
	# 圆柱中心轴 (世界空间)
	# 数学: axis_dir = block 的 +X 方向, 经 global_transform 变换到世界
	#       cylinder_center = block 的 (0, cylinder_radius, 0) → 世界
	var axis_dir: Vector3 = (global_transform.basis * Vector3(1, 0, 0)).normalized()
	var cyl_center: Vector3 = global_transform * Vector3(0.0, cylinder_radius, 0.0)
	# 遍历所有在 Area 内的 RigidBody3D, 施加吸附力
	for body in _trigger_area.get_overlapping_bodies():
		if not (body is RigidBody3D):
			continue
		var car: RigidBody3D = body as RigidBody3D
		# ---- 计算车到轴的径向位移 ----
		# 数学:
		#   R = car.global_position - cyl_center
		#   R_axis = (R · axis_dir) × axis_dir   (沿轴的分量)
		#   R_radial = R - R_axis                 (垂直于轴, 即"径向")
		#   distance_to_axis = R_radial.length()
		var R_vec: Vector3 = car.global_position - cyl_center
		var R_axis_scalar: float = R_vec.dot(axis_dir)
		var R_radial: Vector3 = R_vec - axis_dir * R_axis_scalar
		var dist_to_axis: float = R_radial.length()
		if dist_to_axis < 0.01:
			# 车几乎在轴上 (异常情况, 可能掉到中心了), 不施加吸附
			continue
		# 径向单位向量 (从轴指向车)
		var radial_dir: Vector3 = R_radial / dist_to_axis

		# ---- 吸附力 = -radial_dir × gravity_strength × mass ----
		# 数学:
		#   离表面距离 d_surface = dist_to_axis - cylinder_radius
		#   d_surface > 0: 车在表面外侧 (我们要吸附, 力朝 -radial_dir = 朝轴方向)
		#   d_surface < 0: 车进入圆柱内部 (异常, 也吸到表面 → 力朝 +radial_dir 朝外推)
		# 边缘衰减:
		#   d_surface > fade_distance: 衰减为 0 (车飞太远了, 让它自由下落不强拉回)
		#   d_surface in [0, fade_distance]: 线性衰减 1 → 0
		#   d_surface ≤ 0 (在内部): 不衰减 (满力推到外面)
		var d_surface: float = dist_to_axis - cylinder_radius
		var fade: float = 1.0
		if d_surface > 0.0:
			if d_surface >= fade_distance:
				fade = 0.0
			else:
				fade = 1.0 - d_surface / fade_distance
		# 力向量 (吸附朝向轴)
		var force: Vector3 = -radial_dir * gravity_strength * fade * car.mass
		# 但若车进入圆柱内部, 反向把它推回外面 (避免穿模)
		if d_surface < -0.5:
			force = radial_dir * gravity_strength * 2.0 * car.mass
		car.apply_central_force(force)
		# 输入合理化: 告诉 car 当前贴附面的外法线 = radial_dir (从中心轴指向车那一侧)
		# 这样 _apply_engine_and_brake 会把推力投影到圆柱表面切平面, 玩家按前不会冲离表面
		if car.has_method("apply_anti_gravity_orientation"):
			car.apply_anti_gravity_orientation(radial_dir)


# ============================================================
# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "cylinder_radius",  "label": "圆柱半径(m)",     "min": 1.0, "max": 50.0, "step": 0.5,  "value": cylinder_radius},
		{"key": "cylinder_length",  "label": "圆柱长度(m)",     "min": 2.0, "max": 200.0,"step": 1.0,  "value": cylinder_length},
		{"key": "capture_padding",  "label": "吸附扩展(m)",     "min": 0.5, "max": 20.0, "step": 0.5,  "value": capture_padding},
		{"key": "gravity_strength", "label": "吸附力(m/s²)",    "min": 5.0, "max": 80.0, "step": 1.0,  "value": gravity_strength},
		{"key": "fade_distance",    "label": "边缘衰减(m)",     "min": 0.5, "max": 30.0, "step": 0.5,  "value": fade_distance},
		{"key": "override_gravity", "label": "屏蔽默认重力(0/1)","min": 0.0,"max": 1.0,  "step": 1.0,  "value": float(override_gravity)},
		{"key": "grid_emission",    "label": "网格发光强度",    "min": 0.0, "max": 5.0,  "step": 0.1,  "value": grid_emission},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"cylinder_radius":  cylinder_radius = value
		"cylinder_length":  cylinder_length = value
		"capture_padding":  capture_padding = value
		"gravity_strength": gravity_strength = value
		"fade_distance":    fade_distance = value
		"override_gravity":
			override_gravity = int(value)
			# 实时应用到运行中的 Area
			if _trigger_area:
				if override_gravity == 1:
					_trigger_area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
					_trigger_area.gravity = 0.0
				else:
					_trigger_area.gravity_space_override = Area3D.SPACE_OVERRIDE_DISABLED
		"grid_emission":    grid_emission = value
