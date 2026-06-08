@tool
extends Node3D
## ============================================================
## 机关 - 反重力弧面跳台 (GravityArc)
## ============================================================
## 一段从地面平缓翘起到指定角度的圆弧曲面, 玩家车在外凸侧 (上表面) 行驶,
## 被吸附力沿弧面贴住, 等于一个"沿曲线扬起的跳台". 车顶到弧顶时被弹射出去
## (惯性 + 弧顶切线方向 = 自然飞跃).
##
## 几何模型 — 圆弧切片:
##   设圆心在 block local (0, arc_radius, 0)  (行驶面下方 arc_radius 处)
##   弧从角度 0 (块底, 即地面切点) 到 arc_angle (弧顶) 取一段
##   弧的"行驶面" = 圆周 (P = center + (sin θ × arc_radius, -cos θ × arc_radius, 0))
##                 × X 方向延伸 width
##   一系列短段拼接构造 mesh + collision (避免用复杂 ConcaveMesh)
##
## 数学 (圆弧切片关键点):
##   行驶面在 +Z 方向延伸宽度 width, 沿圆周方向延伸 arc_angle 度
##   每段 segment 是一个细长 box (沿圆周 ds=arc_radius×Δθ 长 + 宽 width + 厚 thickness)
##   旋转每段让其切线沿圆周, 即段 i 的中心角 = i×Δθ + Δθ/2, 法线 (朝车) = -radial_dir
##
## 物理:
##   1) Trigger Area3D 是一个比弧面外凸侧大的"环形扇形"近似 (用 ConvexPolygon 也行,
##      简化版用一个略大的扇形 box list 拼出来, 或者直接用一个 BoxShape3D 包住整个弧面)
##   2) 每物理帧给区域内的车施加 force = -radial_dir × gravity × mass
##      radial_dir = (车位置 - 弧圆心)在弧平面上的投影 → 单位向量
##      跟反重力圆柱完全一样的数学
##
## 玩法:
##   车从弧底 (Y=0 处) 加速冲上弧面, 被吸附力压住贴着弧面跑,
##   到弧顶时车头方向 = 弧顶切线 (自然朝外飞)
##   离开 trigger area 后吸附力消失, 车按当前速度向量自由飞行
##
## 与反重力圆柱的差异:
##   圆柱: 圆心在 block (0, R, 0), 整个 360° 包围 (车可以倒挂一圈)
##   弧面: 圆心也在 (0, R, 0), 但只取 arc_angle 度 (90° = quarter pipe, 180° = 半管)
##         车只能从弧底到弧顶, 不会倒挂
##
## 子节点:
##   ArcSegments (Node3D)             — 容器: 内含 N 段 BoxMesh + N 段 StaticBody3D 拼成弧面
##   PickBody (StaticBody3D)          — 编辑器选中盒 (一个大 box 包住整段弧)
##   Trigger (Area3D)                 — 弧面外凸侧的吸附触发区
## ============================================================

# ============================================================
# 几何参数
# ============================================================
## 圆弧半径 (米). 越大弧越缓, 越小越陡
@export var arc_radius: float = 12.0:
	set(v):
		arc_radius = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 弧的角度跨度 (度). 90°=quarter pipe (从地面翘到垂直), 60°=平缓跳台, 180°=半管(可倒挂)
@export_range(15.0, 180.0, 1.0) var arc_angle_deg: float = 75.0:
	set(v):
		arc_angle_deg = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 弧面宽度 (沿 block local +X 方向, 与车行驶方向垂直)
@export var arc_width: float = 12.0:
	set(v):
		arc_width = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 弧面厚度 (米). 弧面板的厚度, 影响视觉与碰撞
@export var arc_thickness: float = 0.6:
	set(v):
		arc_thickness = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 弧面分段数. 越多越平滑越精细, 但 collision 段数多一点点性能开销
##   推荐 12~24: 12=粗糙看得到棱角, 18=平滑, 24=非常平滑
@export_range(6, 48, 1) var num_segments: int = 18:
	set(v):
		num_segments = clampi(v, 6, 48)
		if is_inside_tree(): _rebuild()
## 触发区在弧面外多包多少厚度 (米)
@export var capture_padding: float = 5.0:
	set(v):
		capture_padding = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()

# ============================================================
# 物理参数
# ============================================================
## 吸附力强度 (m/s²)
@export var gravity_strength: float = 40.0
@export_range(0, 1, 1) var override_gravity: int = 1
@export var fade_distance: float = 6.0

# ============================================================
# 视觉参数
# ============================================================
@export var arc_color: Color = Color(0.4, 0.5, 0.95, 1.0):
	set(v):
		arc_color = v
		if is_inside_tree(): _rebuild()
@export var grid_color: Color = Color(0.3, 0.85, 1.0, 1.0):
	set(v):
		grid_color = v
		if is_inside_tree(): _rebuild()
@export var grid_emission: float = 1.2

# ============================================================
# 内部
# ============================================================
var _seg_root: Node3D = null
var _solid_root: StaticBody3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_seg_root = null
	_solid_root = null
	_pick_body = null
	_trigger_area = null

	var arc_angle: float = deg_to_rad(arc_angle_deg)
	var dtheta: float = arc_angle / float(num_segments)
	# 每段沿圆周长度 ds = arc_radius × dtheta
	var ds: float = arc_radius * dtheta
	# 圆心 (block local) — 弧面下方 arc_radius 处
	var arc_center: Vector3 = Vector3(0.0, arc_radius, 0.0)

	# ---------- 1. 弧面视觉 + 实体碰撞 (合在一起循环生成 N 段) ----------
	# 视觉用 N 段 BoxMesh 拼成弧, 碰撞用同样的 N 段 BoxShape3D 放在同一个 StaticBody3D 下
	# 这样能避免用 ArrayMesh + ConcavePolygonShape3D 的复杂度, 性能也更好
	_seg_root = Node3D.new()
	_seg_root.name = "ArcSegments"
	add_child(_seg_root)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_seg_root.owner = get_tree().edited_scene_root

	_solid_root = StaticBody3D.new()
	_solid_root.name = "SolidBody"
	_solid_root.collision_layer = 1   # 地面层
	_solid_root.collision_mask = 0
	add_child(_solid_root)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_solid_root.owner = get_tree().edited_scene_root

	var seg_mat := StandardMaterial3D.new()
	seg_mat.albedo_color = arc_color
	seg_mat.metallic = 0.55
	seg_mat.roughness = 0.4
	seg_mat.emission_enabled = true
	seg_mat.emission = grid_color
	seg_mat.emission_energy_multiplier = grid_emission * 0.25

	# 段长稍微比 ds 长一点 (×1.02), 让相邻段重叠一点点防止视觉缝隙
	var seg_len_visual: float = ds * 1.02
	for i in range(num_segments):
		# 段中心角 = (i + 0.5) × dtheta  (从 0 到 arc_angle 的中点采样)
		var theta: float = (float(i) + 0.5) * dtheta
		# 段中心位置 (block local):
		# 数学: 行驶面 = 圆心 + (sin θ × R, -cos θ × R, 0) 沿 X 延伸
		#       但我们要"行驶面在弧外"(凸侧), 所以从圆心朝外取 P = center + radial_dir × R
		#       radial_dir = 从圆心指向弧面的方向, 弧从地面翘起 → P.y > 0, P.z 不变
		#       让弧"沿 +Z 方向翘起 (即车从 -Z 进入, 沿弧到 +Z 顶部飞出)":
		#         radial_dir = (0, -cos(θ-arc_angle), sin(θ-arc_angle))?
		#       简化: 让弧底 (θ=0) 在地面 Y=0 处, θ=arc_angle 顶端在 Y=arc_radius×(1-cos arc_angle), Z=arc_radius×sin arc_angle
		#       即:
		#         P = arc_center + Vector3(0, -cos(θ)×R, sin(θ)×R)
		#           = (0, R - R×cos(θ), R×sin(θ))
		#         θ=0: P=(0,0,0) 弧底贴地✓
		#         θ=π/2: P=(0,R,R) 弧顶在 (0, R, R)
		var seg_center_local: Vector3 = arc_center + Vector3(0.0, -arc_radius * cos(theta), arc_radius * sin(theta))
		# 段法线 (朝车一侧, 即弧凸侧的外法线):
		#   radial_dir = (P - center) / R = (0, -cos θ, sin θ)
		#   外法线 = radial_dir 本身 (从圆心指向外面)
		var radial_local: Vector3 = (seg_center_local - arc_center) / arc_radius
		# 段切线 (沿圆周方向, 用于段的"长方向"):
		#   d/dθ of P = (0, sin θ, cos θ) × R, 归一化 = (0, sin θ, cos θ)
		var tangent_local: Vector3 = Vector3(0.0, sin(theta), cos(theta))

		# === 视觉 BoxMesh ===
		# Box 默认沿 ±Y±X±Z 各 0.5, 我们自定义 size = (width, thickness, ds_visual)
		# 段在 block local 下: 中心 = seg_center_local, 但 box 默认朝向 ±X/±Y/±Z
		# 需要让 box 的"长方向" (默认 Z) 对齐到 tangent_local, "厚方向" (默认 Y) 对齐 radial_local
		# 用 Transform3D 构造 basis:
		#   basis.x = +X (世界, 因为我们沿 X 延伸宽度, 不旋转)
		#   basis.y = radial_local (法线方向 — box 厚度方向)
		#   basis.z = tangent_local (切线方向 — box 长方向)
		# 但 +X × radial_local = ? 必须保证三轴正交+右手系
		# 简化: 先构造 basis = look_at(tangent), up=radial, 然后再加 X 轴
		# 实际更简单: 直接在 X-radial-tangent 张成的局部系里, 然后旋转使 Y=radial, Z=tangent
		# Godot 的 Transform3D.looking_at 接受 -Z 朝向 + up, 我们要 box 的 +Z=tangent, +Y=radial
		#   look_at 默认 -Z 朝目标; 所以让段朝向 -tangent 方向 + up=radial 即可让 +Z=tangent
		#   等等更简洁: 直接构造 basis = Basis(x_axis, y_axis, z_axis)
		var x_axis: Vector3 = Vector3.RIGHT
		var y_axis: Vector3 = radial_local
		var z_axis: Vector3 = tangent_local
		# 确保正交右手系: x = y × z 重新计算 (radial 和 tangent 已经正交因为来自圆周不同方向)
		x_axis = y_axis.cross(z_axis).normalized()
		var seg_basis: Basis = Basis(x_axis, y_axis, z_axis)
		var seg_xform: Transform3D = Transform3D(seg_basis, seg_center_local)

		var seg_mesh := MeshInstance3D.new()
		seg_mesh.name = "Seg_%d" % i
		var sbox := BoxMesh.new()
		# size: X=width, Y=thickness, Z=ds_visual (长方向沿切线)
		sbox.size = Vector3(arc_width, arc_thickness, seg_len_visual)
		seg_mesh.mesh = sbox
		seg_mesh.transform = seg_xform
		seg_mesh.material_override = seg_mat
		_seg_root.add_child(seg_mesh)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			seg_mesh.owner = get_tree().edited_scene_root

		# === 实体碰撞 BoxShape3D ===
		# 同样的 transform + 同样的 size, 加到 _solid_root 下
		var col := CollisionShape3D.new()
		col.name = "Col_%d" % i
		var cbox := BoxShape3D.new()
		cbox.size = Vector3(arc_width, arc_thickness, ds)   # 碰撞段不重叠 (避免内表面接触卡顿)
		col.shape = cbox
		col.transform = seg_xform
		_solid_root.add_child(col)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			col.owner = get_tree().edited_scene_root

	# ---------- 2. 网格装饰 (沿弧顶外侧每段中心放一根横竖光带) ----------
	# 简化: 在弧顶端 (θ=arc_angle 处) 放一条发光横线, 标识"弧的边界"
	# 这够装饰用, 不在每段画网格 (会过密, 性能差)
	var grid_mat := StandardMaterial3D.new()
	grid_mat.albedo_color = grid_color
	grid_mat.emission_enabled = true
	grid_mat.emission = grid_color
	grid_mat.emission_energy_multiplier = grid_emission
	grid_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# 顶端边线
	var top_theta: float = arc_angle
	var top_radial: Vector3 = Vector3(0.0, -cos(top_theta), sin(top_theta))
	var top_tangent: Vector3 = Vector3(0.0, sin(top_theta), cos(top_theta))
	var top_pos: Vector3 = arc_center + top_radial * (arc_radius + arc_thickness * 0.5 + 0.04)
	var top_line := MeshInstance3D.new()
	top_line.name = "EdgeTop"
	var tlbox := BoxMesh.new()
	tlbox.size = Vector3(arc_width, 0.06, 0.06)
	top_line.mesh = tlbox
	var tl_basis: Basis = Basis(top_radial.cross(top_tangent).normalized(), top_radial, top_tangent)
	top_line.transform = Transform3D(tl_basis, top_pos)
	top_line.material_override = grid_mat
	add_child(top_line)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		top_line.owner = get_tree().edited_scene_root
	# 侧边光带 (沿 X 两侧画 2 条沿弧的发光线, 营造跳台轨道感)
	for sign_x in [-1.0, 1.0]:
		for i in range(num_segments):
			var theta_i: float = (float(i) + 0.5) * dtheta
			var radial_i: Vector3 = Vector3(0.0, -cos(theta_i), sin(theta_i))
			var tangent_i: Vector3 = Vector3(0.0, sin(theta_i), cos(theta_i))
			var pos_i: Vector3 = arc_center + radial_i * (arc_radius + arc_thickness * 0.5 + 0.04)
			pos_i.x = sign_x * arc_width * 0.5
			var sbar := MeshInstance3D.new()
			sbar.name = "SideBar_%s_%d" % ["L" if sign_x < 0 else "R", i]
			var sbarbox := BoxMesh.new()
			sbarbox.size = Vector3(0.08, 0.08, ds * 1.02)
			sbar.mesh = sbarbox
			var sbar_basis: Basis = Basis(radial_i.cross(tangent_i).normalized(), radial_i, tangent_i)
			sbar.transform = Transform3D(sbar_basis, pos_i)
			sbar.material_override = grid_mat
			add_child(sbar)
			if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
				sbar.owner = get_tree().edited_scene_root

	# ---------- 3. 编辑器选中盒 ----------
	# 用一个大 box 包住整个弧 (从底 0 到顶, 沿 +Z 方向)
	# 数学: 弧顶 P = (0, R(1-cos arc_angle), R sin arc_angle)
	#       包围盒尺寸: X=width+1, Y=R(1-cos arc_angle)+1, Z=R sin arc_angle+1
	#       中心: (0, Y/2, Z/2)
	var arc_top_y: float = arc_radius * (1.0 - cos(arc_angle))
	var arc_top_z: float = arc_radius * sin(arc_angle)
	# 注意 arc_angle > 90° 时 sin 仍 > 0 但开始减少, 中点不再合适. 简化: 用半径作为最大边界
	var pick_y: float = max(arc_top_y, arc_radius * 0.5) + 1.0
	var pick_z: float = max(arc_top_z, arc_radius) + 1.0

	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(arc_width + 1.0, pick_y, pick_z)
	pick_shape.shape = pbox
	pick_shape.position = Vector3(0.0, pick_y * 0.5, pick_z * 0.5 - 0.5)
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 4. Trigger Area3D ----------
	# 简化: 用一个比 PickBody 略大的 box 包住整个弧外侧
	# 真正完美的话需要做扇形 ConvexPolygonShape3D, 但 BoxShape 在 90° 弧时已经够用
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
	tbox.size = Vector3(arc_width + 1.0, pick_y + capture_padding, pick_z + capture_padding)
	trig_shape.shape = tbox
	trig_shape.position = Vector3(0.0, (pick_y + capture_padding) * 0.5 - capture_padding * 0.25, (pick_z + capture_padding) * 0.5 - capture_padding * 0.5)
	_trigger_area.add_child(trig_shape)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		trig_shape.owner = get_tree().edited_scene_root

	# ---------- 5. 仅运行时: 激活吸附 ----------
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
	print("[Block_GravityArc] 反重力弧面已激活 (R=%.1f, %.1f°, 宽 %.1f, %d 段)" %
		[arc_radius, arc_angle_deg, arc_width, num_segments])


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _trigger_area == null or not _trigger_area.monitoring:
		return
	# 弧的圆心 (世界空间) = block local (0, arc_radius, 0) 经 global_transform 变换
	# 注意: 弧的"轴"是 block local +X 方向 (因为弧是 YZ 平面里的圆 × X 方向延伸)
	# 数学: 跟反重力圆柱完全一样, 只是这里圆心在弧"下方" (block 原点 + R*Y)
	var arc_center_world: Vector3 = global_transform * Vector3(0.0, arc_radius, 0.0)
	# 弧的"轴方向" = block.basis.x (沿 X 延伸的方向)
	var axis_dir: Vector3 = global_transform.basis.x.normalized()
	# 弧角度范围 (用于过滤"车在弧外侧但角度超出弧段范围"的情况)
	var arc_angle_max: float = deg_to_rad(arc_angle_deg)

	for body in _trigger_area.get_overlapping_bodies():
		if not (body is RigidBody3D):
			continue
		var car: RigidBody3D = body as RigidBody3D
		# ---- 计算车到弧轴的径向位移 ----
		# 数学 (跟圆柱完全一样):
		#   R = car.global_position - arc_center
		#   R_axis = (R · axis_dir) × axis_dir
		#   R_radial = R - R_axis  (垂直于 X 轴的分量, 在 YZ 弧平面里)
		var R_vec: Vector3 = car.global_position - arc_center_world
		var R_axis_scalar: float = R_vec.dot(axis_dir)
		var R_radial: Vector3 = R_vec - axis_dir * R_axis_scalar
		var dist_to_axis: float = R_radial.length()
		if dist_to_axis < 0.01:
			continue
		var radial_dir: Vector3 = R_radial / dist_to_axis

		# ---- 角度过滤: 车的位置角度必须在 [0, arc_angle_max] 范围内 ----
		# 数学: 把 R_radial 投影到 block local YZ 平面 (用 global_transform.basis.y/z 当基)
		#       angle = atan2(z, -y)  (因为 θ=0 对应 -Y 方向, 即弧底; θ=π/2 对应 +Z, 即弧顶)
		# 简化: 在 block local 空间算 angle
		var R_local: Vector3 = global_transform.basis.inverse() * R_radial
		# R_local.y = 在 block 局部的 Y 分量, R_local.z = Z 分量
		# 数学: 弧上 P-center = (0, -R cos θ, R sin θ), 即 local Y/R = -cos θ, local Z/R = sin θ
		#       → θ = atan2(local_z, -local_y)
		var theta_local: float = atan2(R_local.z, -R_local.y)
		# 角度在 [0, arc_angle_max] 内才施加吸附力 (车飞出弧顶以外不再拉它)
		if theta_local < -0.1 or theta_local > arc_angle_max + 0.1:
			continue

		# ---- 边缘衰减 ----
		var d_surface: float = dist_to_axis - arc_radius
		var fade: float = 1.0
		if d_surface > 0.0:
			if d_surface >= fade_distance:
				fade = 0.0
			else:
				fade = 1.0 - d_surface / fade_distance
		# 力 = -radial_dir × gravity_strength × fade × mass
		var force: Vector3 = -radial_dir * gravity_strength * fade * car.mass
		# 内部 (车进入弧内) 推到外面 (跟圆柱一样)
		if d_surface < -0.5:
			force = radial_dir * gravity_strength * 2.0 * car.mass
		car.apply_central_force(force)
		# 输入合理化: 告诉 car 当前贴附面的外法线 = radial_dir
		if car.has_method("apply_anti_gravity_orientation"):
			car.apply_anti_gravity_orientation(radial_dir)


# ============================================================
# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "arc_radius",       "label": "弧半径(m)",        "min": 2.0, "max": 100.0,"step": 0.5,  "value": arc_radius},
		{"key": "arc_angle_deg",    "label": "弧角度(°)",        "min": 15.0,"max": 180.0,"step": 1.0,  "value": arc_angle_deg},
		{"key": "arc_width",        "label": "弧宽(m)",          "min": 2.0, "max": 100.0,"step": 0.5,  "value": arc_width},
		{"key": "arc_thickness",    "label": "弧厚(m)",          "min": 0.2, "max": 5.0,  "step": 0.1,  "value": arc_thickness},
		{"key": "num_segments",     "label": "分段数(精度)",     "min": 6.0, "max": 48.0, "step": 1.0,  "value": float(num_segments)},
		{"key": "capture_padding",  "label": "吸附扩展(m)",      "min": 0.5, "max": 30.0, "step": 0.5,  "value": capture_padding},
		{"key": "gravity_strength", "label": "吸附力(m/s²)",     "min": 5.0, "max": 100.0,"step": 1.0,  "value": gravity_strength},
		{"key": "fade_distance",    "label": "边缘衰减(m)",      "min": 0.5, "max": 30.0, "step": 0.5,  "value": fade_distance},
		{"key": "override_gravity", "label": "屏蔽默认重力(0/1)","min": 0.0, "max": 1.0,  "step": 1.0,  "value": float(override_gravity)},
		{"key": "grid_emission",    "label": "网格发光强度",     "min": 0.0, "max": 5.0,  "step": 0.1,  "value": grid_emission},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"arc_radius":       arc_radius = value
		"arc_angle_deg":    arc_angle_deg = value
		"arc_width":        arc_width = value
		"arc_thickness":    arc_thickness = value
		"num_segments":     num_segments = int(value)
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
