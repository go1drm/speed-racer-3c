@tool
extends Node3D
## ============================================================
## 可破碎墙 (Breakable Wall) — 编辑器机关
## ============================================================
## 半透明矩形立方体, 阻挡赛车行进 (与赛道墙相同物理行为)
## 被赛车高速撞击时会碎裂 (粒子动画 + 碎片飞散)
##
## 子节点结构 (rebuild 后):
##   WallMesh (MeshInstance3D)       — 半透明立方体视觉
##   WallBody (StaticBody3D)         — 物理碰撞 (阻挡赛车, collision_layer=4 = 墙)
##     WallShape (CollisionShape3D)  — BoxShape3D
##   PickBody (StaticBody3D)         — 编辑器选中盒
##     PickShape (CollisionShape3D)  — BoxShape3D
##   DetectArea (Area3D)             — 运行时检测赛车速度, 判断是否触发碎裂
##     DetectShape (CollisionShape3D)— BoxShape3D (略大于墙体)
##
## 碎裂逻辑:
##   赛车进入 DetectArea 时, 读取赛车速度. 若速度 > break_speed_threshold:
##     1) 隐藏 WallMesh
##     2) 禁用 WallBody 碰撞
##     3) 生成碎片粒子 (GPUParticles3D, 一次性爆发)
##     4) 碎片飞散完毕后 queue_free 粒子节点
## ============================================================

# ============================================================
# 可编辑参数
# ============================================================
## 墙体宽度 (X 方向, 米)
@export var wall_width: float = 8.0:
	set(v):
		wall_width = clampf(v, 0.5, 100.0)
		if is_inside_tree():
			_rebuild()
## 墙体高度 (Y 方向, 米)
@export var wall_height: float = 4.0:
	set(v):
		wall_height = clampf(v, 0.5, 30.0)
		if is_inside_tree():
			_rebuild()
## 墙体厚度 (Z 方向, 米)
@export var wall_depth: float = 0.5:
	set(v):
		wall_depth = clampf(v, 0.1, 20.0)
		if is_inside_tree():
			_rebuild()
## 透明度 (0=完全透明, 1=完全不透明)
@export var wall_alpha: float = 0.5:
	set(v):
		wall_alpha = clampf(v, 0.05, 1.0)
		if is_inside_tree():
			_rebuild()
## 墙体颜色 R
@export var color_r: float = 0.3:
	set(v):
		color_r = clampf(v, 0.0, 1.0)
		if is_inside_tree():
			_rebuild()
## 墙体颜色 G
@export var color_g: float = 0.6:
	set(v):
		color_g = clampf(v, 0.0, 1.0)
		if is_inside_tree():
			_rebuild()
## 墙体颜色 B
@export var color_b: float = 0.9:
	set(v):
		color_b = clampf(v, 0.0, 1.0)
		if is_inside_tree():
			_rebuild()
## 碎裂触发速度阈值 (m/s). 赛车速度超过此值撞墙时墙会碎
@export var break_speed_threshold: float = 25.0:
	set(v):
		break_speed_threshold = clampf(v, 5.0, 200.0)
## 碎片数量 (粒子数)
@export var shard_count: int = 24:
	set(v):
		shard_count = clampi(v, 8, 64)
## 碎片飞散速度 (m/s)
@export var shard_speed: float = 12.0:
	set(v):
		shard_speed = clampf(v, 2.0, 50.0)
## 碎片存活时间 (秒)
@export var shard_lifetime: float = 1.5:
	set(v):
		shard_lifetime = clampf(v, 0.5, 5.0)

# ============================================================
# 内部节点引用
# ============================================================
var _wall_mesh: MeshInstance3D = null
var _wall_body: StaticBody3D = null
var _pick_body: StaticBody3D = null
var _detect_area: Area3D = null
var _is_broken: bool = false


func _ready() -> void:
	_rebuild()


# ============================================================
# 重建几何
# ============================================================
func _rebuild() -> void:
	# 清掉旧子节点
	for c in get_children():
		c.queue_free()
	_wall_mesh = null
	_wall_body = null
	_pick_body = null
	_detect_area = null
	_is_broken = false

	var half_w: float = wall_width * 0.5
	var half_h: float = wall_height * 0.5
	var half_d: float = wall_depth * 0.5

	# ---------- 1. 视觉 mesh ----------
	_wall_mesh = MeshInstance3D.new()
	_wall_mesh.name = "WallMesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(wall_width, wall_height, wall_depth)
	_wall_mesh.mesh = box_mesh
	# 墙体底部贴地: 中心在 Y = half_h
	_wall_mesh.position = Vector3(0.0, half_h, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color_r, color_g, color_b, wall_alpha)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.4
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 轻微发光让墙在暗处也可见
	mat.emission_enabled = true
	mat.emission = Color(color_r, color_g, color_b)
	mat.emission_energy_multiplier = 0.3
	_wall_mesh.material_override = mat
	add_child(_wall_mesh)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_wall_mesh.owner = get_tree().edited_scene_root

	# ---------- 2. 物理碰撞体 (阻挡赛车) ----------
	# collision_layer = 1 | 4 = 5:
	#   bit 0 (layer 1): 让赛车默认 collision_mask=1 能碰到此墙 (产生物理阻挡)
	#   bit 2 (layer 4): 让 car.gd 的 _integrate_forces 识别为墙 (触发撞墙反弹逻辑)
	# 同时加入 "wall" group 让 car.gd 的 is_in_group("wall") 判定通过
	_wall_body = StaticBody3D.new()
	_wall_body.name = "WallBody"
	_wall_body.collision_layer = 5   # bit 0 + bit 2 = layer 1 + 墙层
	_wall_body.collision_mask = 0    # 墙不主动检测
	_wall_body.add_to_group("wall")
	_wall_body.position = Vector3(0.0, half_h, 0.0)
	var wall_shape := CollisionShape3D.new()
	wall_shape.name = "WallShape"
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(wall_width, wall_height, wall_depth)
	wall_shape.shape = wbox
	_wall_body.add_child(wall_shape)
	add_child(_wall_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_wall_body.owner = get_tree().edited_scene_root
		wall_shape.owner = get_tree().edited_scene_root

	# ---------- 3. 编辑器选中盒 ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5   # 第 6 位, 与加速带一致
	_pick_body.collision_mask = 0
	_pick_body.position = Vector3(0.0, half_h, 0.0)
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(wall_width + 0.2, wall_height + 0.2, wall_depth + 0.2)
	pick_shape.shape = pbox
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 4. 检测 Area3D (运行时判断赛车速度) ----------
	_detect_area = Area3D.new()
	_detect_area.name = "DetectArea"
	_detect_area.monitoring = false
	_detect_area.monitorable = false
	_detect_area.position = Vector3(0.0, half_h, 0.0)
	add_child(_detect_area)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_detect_area.owner = get_tree().edited_scene_root
	var detect_shape := CollisionShape3D.new()
	detect_shape.name = "DetectShape"
	var dbox := BoxShape3D.new()
	# 检测区域比墙体稍大, 让赛车在接触前一帧就能被检测到
	dbox.size = Vector3(wall_width + 1.0, wall_height + 1.0, wall_depth + 2.0)
	detect_shape.shape = dbox
	_detect_area.add_child(detect_shape)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		detect_shape.owner = get_tree().edited_scene_root

	# ---------- 5. 运行时初始化检测器 ----------
	if not Engine.is_editor_hint():
		_runtime_init_detect()


# ============================================================
# 运行时检测器初始化
# ============================================================
func _runtime_init_detect() -> void:
	if _detect_area == null:
		return
	_detect_area.monitoring = true
	_detect_area.monitorable = false
	_detect_area.collision_layer = 0
	_detect_area.collision_mask = 2   # 探测 layer=2 的赛车
	if not _detect_area.body_entered.is_connected(_on_car_entered):
		_detect_area.body_entered.connect(_on_car_entered)
	print("[Block_Wall] 运行时检测器已激活: break_threshold=%.1f m/s" % break_speed_threshold)


# ============================================================
# 赛车进入检测区域
# ============================================================
func _on_car_entered(body: Node) -> void:
	if _is_broken:
		return
	# 只处理有 linear_velocity 的 RigidBody3D (= 赛车)
	if not (body is RigidBody3D):
		return
	# 计算赛车朝向墙面法线方向的速度分量 (撞击速度)
	# 墙的法线方向 = 墙的局部 Z 轴在世界空间中的方向 (墙面朝向)
	# 只有赛车"撞向"墙面的速度分量才算, 从旁边经过或平行滑过不算
	var car_vel: Vector3 = (body as RigidBody3D).linear_velocity
	# 墙面法线: 取墙的全局 Z 轴方向 (BoxMesh 的前后面)
	var wall_normal: Vector3 = global_transform.basis.z.normalized()
	# 赛车速度在墙面法线方向的投影 (取绝对值, 不管从哪面撞)
	var impact_speed: float = absf(car_vel.dot(wall_normal))
	# 同时也检查 X 轴方向 (墙的侧面), 取两者中较大的作为撞击速度
	var wall_normal_x: Vector3 = global_transform.basis.x.normalized()
	var impact_speed_x: float = absf(car_vel.dot(wall_normal_x))
	var final_impact_speed: float = maxf(impact_speed, impact_speed_x)
	print("[Block_Wall] 检测到赛车接近: 总速度=%.1f, Z轴撞击速度=%.1f, X轴撞击速度=%.1f, 阈值=%.1f" % [car_vel.length(), impact_speed, impact_speed_x, break_speed_threshold])
	if final_impact_speed >= break_speed_threshold:
		_break_wall(body)


# ============================================================
# 碎裂逻辑
# ============================================================
func _break_wall(car_body: Node) -> void:
	_is_broken = true

	# 1) 隐藏墙体视觉
	if _wall_mesh:
		_wall_mesh.visible = false

	# 2) 禁用物理碰撞 (让赛车穿过)
	if _wall_body:
		_wall_body.collision_layer = 0
		_wall_body.collision_mask = 0
		# 禁用碰撞形状
		for child in _wall_body.get_children():
			if child is CollisionShape3D:
				child.disabled = true

	# 3) 关闭检测区域 (不再重复触发)
	if _detect_area:
		_detect_area.monitoring = false

	# 4) 生成碎片粒子效果
	_spawn_shatter_particles(car_body)

	print("[Block_Wall] 墙体碎裂! 赛车速度=%.1f m/s" % (car_body as RigidBody3D).linear_velocity.length())


# ============================================================
# 碎片粒子效果
# ============================================================
func _spawn_shatter_particles(car_body: Node) -> void:
	var particles := GPUParticles3D.new()
	particles.name = "ShatterFX"
	particles.emitting = true
	particles.one_shot = true
	particles.amount = shard_count
	particles.lifetime = shard_lifetime
	particles.explosiveness = 0.95   # 几乎同时爆发
	particles.position = Vector3(0.0, wall_height * 0.5, 0.0)

	# 粒子材质
	var pmat := ParticleProcessMaterial.new()
	# 碎片从墙中心向外爆发
	pmat.direction = Vector3(0.0, 0.3, 0.0)
	pmat.spread = 180.0   # 全方向
	pmat.initial_velocity_min = shard_speed * 0.5
	pmat.initial_velocity_max = shard_speed
	pmat.gravity = Vector3(0.0, -9.8, 0.0)
	pmat.angular_velocity_min = -360.0
	pmat.angular_velocity_max = 360.0
	# 碎片大小随时间缩小 (消失效果)
	pmat.scale_min = 0.3
	pmat.scale_max = 1.0
	# 发射形状: 盒形 (与墙体尺寸匹配)
	pmat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pmat.emission_box_extents = Vector3(wall_width * 0.5, wall_height * 0.5, wall_depth * 0.5)
	# 赛车撞击方向给碎片一个额外的初速度偏移
	if car_body is RigidBody3D:
		var car_vel: Vector3 = (car_body as RigidBody3D).linear_velocity.normalized()
		pmat.direction = (car_vel + Vector3(0.0, 0.5, 0.0)).normalized()
		pmat.spread = 60.0   # 主要朝撞击方向飞散

	particles.process_material = pmat

	# 碎片 mesh (小方块)
	var shard_mesh := BoxMesh.new()
	var shard_size: float = minf(wall_width, wall_height) * 0.08
	shard_size = clampf(shard_size, 0.1, 0.5)
	shard_mesh.size = Vector3(shard_size, shard_size, shard_size)
	particles.draw_pass_1 = shard_mesh

	# 碎片材质 (与墙体同色, 不透明)
	var shard_mat := StandardMaterial3D.new()
	shard_mat.albedo_color = Color(color_r, color_g, color_b, 1.0)
	shard_mat.emission_enabled = true
	shard_mat.emission = Color(color_r, color_g, color_b)
	shard_mat.emission_energy_multiplier = 0.5
	particles.material_override = shard_mat

	add_child(particles)

	# 粒子播放完毕后自动清理
	var timer := get_tree().create_timer(shard_lifetime + 0.5)
	timer.timeout.connect(func():
		if is_instance_valid(particles):
			particles.queue_free()
	)


# ============================================================
# 编辑器接口 (供 TrackEditor 选中面板用)
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "wall_width",            "label": "宽度 (m, X)",       "min": 0.5,  "max": 100.0, "step": 0.5,  "value": wall_width},
		{"key": "wall_height",           "label": "高度 (m, Y)",       "min": 0.5,  "max": 30.0,  "step": 0.5,  "value": wall_height},
		{"key": "wall_depth",            "label": "厚度 (m, Z)",       "min": 0.1,  "max": 20.0,  "step": 0.1,  "value": wall_depth},
		{"key": "wall_alpha",            "label": "透明度",            "min": 0.05, "max": 1.0,   "step": 0.05, "value": wall_alpha},
		{"key": "color_r",               "label": "颜色 R",           "min": 0.0,  "max": 1.0,   "step": 0.05, "value": color_r},
		{"key": "color_g",               "label": "颜色 G",           "min": 0.0,  "max": 1.0,   "step": 0.05, "value": color_g},
		{"key": "color_b",               "label": "颜色 B",           "min": 0.0,  "max": 1.0,   "step": 0.05, "value": color_b},
		{"key": "break_speed_threshold", "label": "碎裂速度阈值(m/s)","min": 5.0,  "max": 200.0, "step": 1.0,  "value": break_speed_threshold},
		{"key": "shard_count",           "label": "碎片数量",          "min": 8.0,  "max": 64.0,  "step": 1.0,  "value": float(shard_count)},
		{"key": "shard_speed",           "label": "碎片飞散速度(m/s)", "min": 2.0,  "max": 50.0,  "step": 1.0,  "value": shard_speed},
		{"key": "shard_lifetime",        "label": "碎片存活时间(秒)",  "min": 0.5,  "max": 5.0,   "step": 0.1,  "value": shard_lifetime},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"wall_width":            wall_width = value
		"wall_height":           wall_height = value
		"wall_depth":            wall_depth = value
		"wall_alpha":            wall_alpha = value
		"color_r":               color_r = value
		"color_g":               color_g = value
		"color_b":               color_b = value
		"break_speed_threshold": break_speed_threshold = value
		"shard_count":           shard_count = int(value)
		"shard_speed":           shard_speed = value
		"shard_lifetime":        shard_lifetime = value
