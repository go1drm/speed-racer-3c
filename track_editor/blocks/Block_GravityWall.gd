@tool
extends Node3D
## ============================================================
## 机关 - 反重力墙面 (GravityWall)
## ============================================================
## 一面竖直矩形墙板, 玩家车被吸附力压在 +Z 朝向的"正面"上行驶,
## 等于把垂直墙面变成了"水平地面". 适合做立体迷宫 / loop 的一段直线壁.
##
## 几何 (block local 空间):
##   板沿 X 方向 wall_width 宽, 沿 Y 方向 wall_height 高, 沿 Z 方向 wall_thickness 厚
##   板中心放在 (0, wall_height/2, 0), 让板的底边贴 block 的 Y=0 (跟地面平齐)
##   "行驶面" = 板的 +Z 一侧 (block 旋转后由用户决定朝哪)
##
## 物理:
##   1) Trigger Area3D 是一个比墙稍大的盒子 (在 +Z 方向多包 capture_padding 厚度)
##      gravity_space_override = REPLACE, gravity = 0  → 区域内屏蔽默认 Y 重力
##   2) 每物理帧遍历 Area 内的 RigidBody3D, 施加力:
##      force = -wall_normal × gravity_strength × mass
##      wall_normal = block.basis.z (墙面正面朝向)
##      负号让力 "朝向墙" (从 +Z 一侧把车压到墙面 Z=0 处)
##   3) 离表面距离 d > fade_distance 时力衰减为 0 (车飞太远了, 让它自由下落)
##
## 与反重力圆柱的差异:
##   圆柱: 吸附方向 = 朝向中心轴 (径向, 每帧根据车位置算)
##   墙面: 吸附方向 = 恒定 -wall_normal (整面墙都是同一个力方向)
##
## 球体驱动注意:
##   车的 ground_ray 朝 -Y, 在垂直墙面上时检测不到墙 (墙在 +Z 不在 -Y)
##   → _is_airborne=true, 引擎力略削减但吸附力让车贴住墙面
##   完美方案需要让 ground_ray 朝 -wall_normal, 但侵入 car.gd 太大. 当前是简化版.
##
## 子节点:
##   WallMesh (MeshInstance3D)        — 墙板视觉
##   SolidBody (StaticBody3D, layer=1) — 实体碰撞 (车撞得到 + 能站在上面)
##   PickBody (StaticBody3D, layer=1<<5) — 编辑器选中盒
##   Trigger (Area3D)                 — 包裹墙面的吸附触发区
## ============================================================

# ============================================================
# 几何参数
# ============================================================
## 墙宽 (沿 block local +X 方向)
@export var wall_width: float = 30.0:
	set(v):
		wall_width = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 墙高 (沿 block local +Y 方向, 从 Y=0 起算)
@export var wall_height: float = 12.0:
	set(v):
		wall_height = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 墙厚 (沿 block local +Z 方向, 行驶面 = +Z 一侧)
@export var wall_thickness: float = 1.0:
	set(v):
		wall_thickness = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 触发区在 +Z 行驶面外多包多少厚度 (米)
##   推荐 4~8: 至少够一个车长(5m)能从远处冲来就被抓到
@export var capture_padding: float = 5.0:
	set(v):
		capture_padding = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()

# ============================================================
# 物理参数
# ============================================================
## 吸附力强度 (m/s²). 跟项目重力 (29) 同量级以上才能稳定贴墙
##   推荐 35~60: 35=轻贴, 50=稳贴, 60=超强吸附
@export var gravity_strength: float = 40.0
## 是否抵消区域内的默认 Y 重力 (1=抵消, 0=不抵消)
@export_range(0, 1, 1) var override_gravity: int = 1
## 离表面距离 fade_distance 米后吸附力衰减为 0
@export var fade_distance: float = 6.0

# ============================================================
# 视觉参数
# ============================================================
## 墙面主色 (默认科幻紫蓝)
@export var wall_color: Color = Color(0.4, 0.5, 0.95, 1.0):
	set(v):
		wall_color = v
		if is_inside_tree(): _rebuild()
## 表面网格线色 (营造重力网格感)
@export var grid_color: Color = Color(0.3, 0.85, 1.0, 1.0):
	set(v):
		grid_color = v
		if is_inside_tree(): _rebuild()
## 网格自发光强度 (0=暗, 2=明显发光)
@export var grid_emission: float = 1.0

# ============================================================
# 内部
# ============================================================
var _wall_mesh: MeshInstance3D = null
var _solid_body: StaticBody3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_wall_mesh = null
	_solid_body = null
	_pick_body = null
	_trigger_area = null

	# ---------- 1. 墙板 mesh ----------
	# BoxMesh 默认中心在原点, 我们要底边贴 Y=0, 所以中心 Y = wall_height/2
	_wall_mesh = MeshInstance3D.new()
	_wall_mesh.name = "WallMesh"
	var box := BoxMesh.new()
	box.size = Vector3(wall_width, wall_height, wall_thickness)
	_wall_mesh.mesh = box
	_wall_mesh.position = Vector3(0.0, wall_height * 0.5, 0.0)
	var wm := StandardMaterial3D.new()
	wm.albedo_color = wall_color
	wm.metallic = 0.55
	wm.roughness = 0.4
	wm.emission_enabled = true
	wm.emission = grid_color
	wm.emission_energy_multiplier = grid_emission * 0.25
	_wall_mesh.material_override = wm
	add_child(_wall_mesh)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_wall_mesh.owner = get_tree().edited_scene_root

	# ---------- 1b. 网格线 (沿墙面 X/Y 方向若干横竖线) ----------
	# 视觉网格 = 在 +Z 行驶面上方略凸出 (+Z 0.06m) 摆若干扁长条 BoxMesh
	# 每 4m 一条横线 + 每 4m 一条竖线, 营造科幻"反重力轨道"风
	var grid_mat := StandardMaterial3D.new()
	grid_mat.albedo_color = grid_color
	grid_mat.emission_enabled = true
	grid_mat.emission = grid_color
	grid_mat.emission_energy_multiplier = grid_emission
	grid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var grid_spacing: float = 4.0
	var line_thickness: float = 0.08
	# 横线 (沿 X 全宽, 在 Y=k×spacing 处, 厚度 line_thickness)
	var num_h_lines: int = int(wall_height / grid_spacing)
	for i in range(1, num_h_lines + 1):
		var hline := MeshInstance3D.new()
		hline.name = "HLine_%d" % i
		var hbox := BoxMesh.new()
		hbox.size = Vector3(wall_width, line_thickness, line_thickness * 0.5)
		hline.mesh = hbox
		# 凸出 +Z 行驶面外侧 (墙面 +Z 在 wall_thickness/2, 凸出 +0.04)
		hline.position = Vector3(0.0, i * grid_spacing, wall_thickness * 0.5 + 0.04)
		hline.material_override = grid_mat
		add_child(hline)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			hline.owner = get_tree().edited_scene_root
	# 竖线 (沿 Y 全高, 在 X=±k×spacing 处)
	var num_v_lines: int = int(wall_width / grid_spacing)
	for i in range(num_v_lines + 1):
		var vline := MeshInstance3D.new()
		vline.name = "VLine_%d" % i
		var vbox := BoxMesh.new()
		vbox.size = Vector3(line_thickness, wall_height, line_thickness * 0.5)
		vline.mesh = vbox
		var x_pos: float = -wall_width * 0.5 + i * (wall_width / num_v_lines)
		vline.position = Vector3(x_pos, wall_height * 0.5, wall_thickness * 0.5 + 0.04)
		vline.material_override = grid_mat
		add_child(vline)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			vline.owner = get_tree().edited_scene_root

	# ---------- 2. 实体碰撞 (StaticBody3D layer=1) ----------
	# 关键: 没这个车会直接穿墙 (跟反重力圆柱旧 bug 一样)
	_solid_body = StaticBody3D.new()
	_solid_body.name = "SolidBody"
	_solid_body.collision_layer = 1   # 地面/赛道层, 车的 ray + collision 都检测
	_solid_body.collision_mask = 0
	var solid_shape := CollisionShape3D.new()
	solid_shape.name = "SolidShape"
	var sbox := BoxShape3D.new()
	sbox.size = Vector3(wall_width, wall_height, wall_thickness)
	solid_shape.shape = sbox
	solid_shape.position = Vector3(0.0, wall_height * 0.5, 0.0)
	_solid_body.add_child(solid_shape)
	add_child(_solid_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_solid_body.owner = get_tree().edited_scene_root
		solid_shape.owner = get_tree().edited_scene_root

	# ---------- 3. 编辑器选中盒 ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(wall_width + 0.5, wall_height + 0.5, wall_thickness + 0.5)
	pick_shape.shape = pbox
	pick_shape.position = Vector3(0.0, wall_height * 0.5, 0.0)
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 4. 触发 Area3D ----------
	# 几何: 比墙更宽更高, +Z 方向在墙外多包 capture_padding 厚度 (-Z 也包一半防车从背面冲来)
	# 中心: 比墙的中心略偏 +Z (因为 +Z 是行驶面, 车主要在那侧)
	_trigger_area = Area3D.new()
	_trigger_area.name = "Trigger"
	_trigger_area.monitoring = false
	_trigger_area.monitorable = false
	add_child(_trigger_area)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_trigger_area.owner = get_tree().edited_scene_root
	var trig_shape := CollisionShape3D.new()
	trig_shape.name = "TriggerShape"
	var tbox := BoxShape3D.new()
	# 触发盒尺寸: 宽高略大于墙, 厚度 = wall_thickness + capture_padding (主要在 +Z 一侧)
	# 数学: 触发盒厚度 = 墙厚 + capture_padding(+Z 一侧捕获)
	#       触发盒中心 Z = capture_padding/2 (向 +Z 偏移让 +Z 一侧捕获更多)
	tbox.size = Vector3(wall_width + 1.0, wall_height + 1.0, wall_thickness + capture_padding)
	trig_shape.shape = tbox
	trig_shape.position = Vector3(0.0, wall_height * 0.5, capture_padding * 0.5)
	_trigger_area.add_child(trig_shape)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		trig_shape.owner = get_tree().edited_scene_root

	# ---------- 5. 仅运行时: 激活触发器 + 吸附逻辑 ----------
	if not Engine.is_editor_hint():
		_runtime_init_trigger()


func _runtime_init_trigger() -> void:
	if _trigger_area == null:
		return
	_trigger_area.monitoring = true
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2  # 探测 layer=2 的赛车
	if override_gravity == 1:
		_trigger_area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
		_trigger_area.gravity = 0.0
		_trigger_area.gravity_direction = Vector3(0, -1, 0)
	set_physics_process(true)
	print("[Block_GravityWall] 反重力墙面已激活 (宽 %.1f × 高 %.1f, +Z 朝向行驶面)" % [wall_width, wall_height])


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _trigger_area == null or not _trigger_area.monitoring:
		return
	# 墙面正面法线 (世界空间) = block local +Z 方向
	# 数学: wall_normal = block.basis.z   (Godot Transform3D 的 basis.z 已经归一化)
	# 吸附力方向 = -wall_normal (从 +Z 一侧把车压向 -Z 即墙面)
	var wall_normal: Vector3 = global_transform.basis.z.normalized()
	# 墙面参考点 (世界空间): 取墙面 +Z 一侧的中心 (z = wall_thickness/2)
	# 这是用来算"车到墙面的距离"的参考
	var wall_surface_center: Vector3 = global_transform * Vector3(0.0, wall_height * 0.5, wall_thickness * 0.5)
	for body in _trigger_area.get_overlapping_bodies():
		if not (body is RigidBody3D):
			continue
		var car: RigidBody3D = body as RigidBody3D
		# ---- 计算车到墙面的有符号距离 ----
		# 数学: d = (car_pos - wall_surface_center) · wall_normal
		#       d > 0: 车在 +Z 一侧 (行驶面外, 我们要把它吸到墙)
		#       d < 0: 车在 -Z 一侧 (墙背面, 不该吸 — 玩家从背面冲入应该穿不过去因为 Solid 挡着)
		var R_vec: Vector3 = car.global_position - wall_surface_center
		var d: float = R_vec.dot(wall_normal)
		# 车在 +Z 行驶面上 (d ≈ 1m, 球心 1m 高)
		# 边缘衰减:
		#   d > fade_distance: 衰减为 0 (飞太远不强拉)
		#   d in [0, fade_distance]: 1 → 0 线性衰减
		#   d ≤ 0: 衰减 0 (车在墙背面, 不该吸)
		var fade: float = 0.0
		if d > 0.0 and d < fade_distance:
			fade = 1.0 - d / fade_distance
		elif d > 0.0 and d >= fade_distance:
			fade = 0.0
		# 力 = -wall_normal × gravity_strength × fade × mass
		# 朝向墙的 -Z 方向把车压住
		var force: Vector3 = -wall_normal * gravity_strength * fade * car.mass
		car.apply_central_force(force)
		# === 输入合理化 ===
		# 用户反馈: "在反重力墙面上按前会向上方冲出墙壁"
		# 真凶: car.gd 的 _apply_engine_and_brake 用 ground_ray 朝 -Y 打的法线做切平面投影
		#       墙是垂直的, 朝 -Y 打不到墙 → 退化为 UP → 推力沿水平面 → 直接冲出墙
		# 修复: 每帧告诉 car "当前贴附面的外法线" = wall_normal (墙的 +Z 朝外)
		#       car._apply_engine_and_brake 优先用这个法线做切平面投影
		#       玩家按前 = 沿墙面切线方向 (沿墙面纵向走) → 不会冲出墙
		# 镜头不动: 我们不旋转 car_mesh, 镜头继续用 Vector3.UP 看车 (符合用户"镜头不用跟随")
		if car.has_method("apply_anti_gravity_orientation"):
			car.apply_anti_gravity_orientation(wall_normal)


# ============================================================
# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "wall_width",       "label": "墙宽(m)",          "min": 2.0, "max": 200.0,"step": 1.0,  "value": wall_width},
		{"key": "wall_height",      "label": "墙高(m)",          "min": 1.0, "max": 100.0,"step": 0.5,  "value": wall_height},
		{"key": "wall_thickness",   "label": "墙厚(m)",          "min": 0.2, "max": 10.0, "step": 0.1,  "value": wall_thickness},
		{"key": "capture_padding",  "label": "吸附扩展(m)",      "min": 0.5, "max": 30.0, "step": 0.5,  "value": capture_padding},
		{"key": "gravity_strength", "label": "吸附力(m/s²)",     "min": 5.0, "max": 100.0,"step": 1.0,  "value": gravity_strength},
		{"key": "fade_distance",    "label": "边缘衰减(m)",      "min": 0.5, "max": 30.0, "step": 0.5,  "value": fade_distance},
		{"key": "override_gravity", "label": "屏蔽默认重力(0/1)","min": 0.0, "max": 1.0,  "step": 1.0,  "value": float(override_gravity)},
		{"key": "grid_emission",    "label": "网格发光强度",     "min": 0.0, "max": 5.0,  "step": 0.1,  "value": grid_emission},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"wall_width":       wall_width = value
		"wall_height":      wall_height = value
		"wall_thickness":   wall_thickness = value
		"capture_padding":  capture_padding = value
		"gravity_strength": gravity_strength = value
		"fade_distance":    fade_distance = value
		"override_gravity":
			override_gravity = int(value)
			if _trigger_area:
				if override_gravity == 1:
					_trigger_area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
					_trigger_area.gravity = 0.0
				else:
					_trigger_area.gravity_space_override = Area3D.SPACE_OVERRIDE_DISABLED
		"grid_emission":    grid_emission = value
