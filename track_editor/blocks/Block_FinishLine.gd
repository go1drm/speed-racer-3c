@tool
extends Node3D
## ============================================================
## 终点 (Finish Line) — 编辑器机关
## ============================================================
## 一个带地面光环特效的圆环结构，圆环中心插着一面旗子。
## 赛车撞进该范围 0.2 秒后，被传送回出生点。
##
## 子节点结构 (rebuild 后):
##   Ring (MeshInstance3D)           — 圆环 (TorusMesh), 竖直放置
##   FlagPole (MeshInstance3D)       — 旗杆 (CylinderMesh)
##   FlagCloth (MeshInstance3D)      — 旗面 (BoxMesh, 薄片)
##   GroundHalo (MeshInstance3D)     — 地面光环 (圆形发光面片)
##   PickBody (StaticBody3D)         — 编辑器选中盒
##     PickShape (CollisionShape3D)
##   Trigger (Area3D)                — 运行时触发区 (圆柱形)
##     TriggerShape (CollisionShape3D)
##
## 可编辑参数:
##   radius:       圆环半径 (m)              默认 5.0
##   ring_thickness: 圆环管粗细 (m)          默认 0.3
##   height:       圆环中心高度 (m)          默认 3.0
##   teleport_delay: 传送延迟 (秒)           默认 0.2
##   color_r/g/b:  主题颜色
## ============================================================

# ============================================================
# 几何参数
# ============================================================
@export var radius: float = 5.0:
	set(v):
		radius = clampf(v, 2.0, 30.0)
		if is_inside_tree() and not _loading:
			_rebuild()
@export var ring_thickness: float = 0.3:
	set(v):
		ring_thickness = clampf(v, 0.1, 2.0)
		if is_inside_tree() and not _loading:
			_rebuild()
@export var height: float = 3.0:
	set(v):
		height = clampf(v, 1.0, 15.0)
		if is_inside_tree() and not _loading:
			_rebuild()

## 传送延迟 (秒): 车进入触发区后等待这么久再传送回出生点
@export var teleport_delay: float = 0.2:
	set(v):
		teleport_delay = clampf(v, 0.0, 3.0)

## 主题颜色
@export var color_r: float = 1.0:
	set(v):
		color_r = clampf(v, 0.0, 1.0)
		if is_inside_tree() and not _loading:
			_rebuild()
@export var color_g: float = 0.3:
	set(v):
		color_g = clampf(v, 0.0, 1.0)
		if is_inside_tree() and not _loading:
			_rebuild()
@export var color_b: float = 0.3:
	set(v):
		color_b = clampf(v, 0.0, 1.0)
		if is_inside_tree() and not _loading:
			_rebuild()

# 批量加载标志 (TrackRunner 加载时避免每个参数都 rebuild)
var _loading: bool = false

# 内部节点引用
var _ring_mesh: MeshInstance3D = null
var _flag_pole: MeshInstance3D = null
var _flag_cloth: MeshInstance3D = null
var _ground_halo: MeshInstance3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null

# 运行时: 正在等待传送的车 { car_instance_id: timer_node }
var _pending_teleports: Dictionary = {}


func _ready() -> void:
	_rebuild()


# ============================================================
# 重建几何 + 选中盒 + 触发器
# ============================================================
func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_ring_mesh = null
	_flag_pole = null
	_flag_cloth = null
	_ground_halo = null
	_pick_body = null
	_trigger_area = null
	_pending_teleports.clear()

	var col := Color(color_r, color_g, color_b)

	# ---------- 1. 地面光环 (圆形发光面片) ----------
	_ground_halo = MeshInstance3D.new()
	_ground_halo.name = "GroundHalo"
	var halo_mesh := CylinderMesh.new()
	halo_mesh.top_radius = radius + 0.5
	halo_mesh.bottom_radius = radius + 0.5
	halo_mesh.height = 0.02
	halo_mesh.radial_segments = 64
	_ground_halo.mesh = halo_mesh
	_ground_halo.position = Vector3(0.0, 0.05, 0.0)
	var halo_mat := StandardMaterial3D.new()
	halo_mat.albedo_color = Color(col.r, col.g, col.b, 0.4)
	halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	halo_mat.emission_enabled = true
	halo_mat.emission = col
	halo_mat.emission_energy_multiplier = 2.0
	halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	halo_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ground_halo.material_override = halo_mat
	add_child(_ground_halo)

	# ---------- 2. 圆环 (竖直放置的 Torus) ----------
	_ring_mesh = MeshInstance3D.new()
	_ring_mesh.name = "Ring"
	var torus := TorusMesh.new()
	torus.inner_radius = radius - ring_thickness
	torus.outer_radius = radius + ring_thickness
	torus.rings = 48
	torus.ring_segments = 24
	_ring_mesh.mesh = torus
	# 圆环默认在 XZ 平面, 旋转 90° 让它竖直 (绕 X 轴)
	_ring_mesh.rotation.x = deg_to_rad(90.0)
	_ring_mesh.position = Vector3(0.0, height, 0.0)
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = col
	ring_mat.emission_enabled = true
	ring_mat.emission = col
	ring_mat.emission_energy_multiplier = 1.5
	ring_mat.metallic = 0.6
	ring_mat.roughness = 0.3
	_ring_mesh.material_override = ring_mat
	add_child(_ring_mesh)

	# ---------- 3. 旗杆 (圆柱) ----------
	_flag_pole = MeshInstance3D.new()
	_flag_pole.name = "FlagPole"
	var pole_mesh := CylinderMesh.new()
	var pole_height: float = height + radius + 1.5
	pole_mesh.top_radius = 0.08
	pole_mesh.bottom_radius = 0.08
	pole_mesh.height = pole_height
	_flag_pole.mesh = pole_mesh
	_flag_pole.position = Vector3(0.0, pole_height * 0.5, 0.0)
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.8, 0.8, 0.8)
	pole_mat.metallic = 0.9
	pole_mat.roughness = 0.2
	_flag_pole.material_override = pole_mat
	add_child(_flag_pole)

	# ---------- 4. 旗面 (薄片 BoxMesh) ----------
	_flag_cloth = MeshInstance3D.new()
	_flag_cloth.name = "FlagCloth"
	var cloth_mesh := BoxMesh.new()
	cloth_mesh.size = Vector3(1.5, 1.0, 0.05)
	_flag_cloth.mesh = cloth_mesh
	# 旗面挂在旗杆顶部偏右
	_flag_cloth.position = Vector3(0.75, pole_height - 0.5, 0.0)
	var cloth_mat := StandardMaterial3D.new()
	cloth_mat.albedo_color = col
	cloth_mat.emission_enabled = true
	cloth_mat.emission = col
	cloth_mat.emission_energy_multiplier = 1.0
	cloth_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_flag_cloth.material_override = cloth_mat
	add_child(_flag_cloth)

	# ---------- 5. 编辑器选中盒 ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(radius * 2.0 + 1.0, height + radius + 2.0, radius * 2.0 + 1.0)
	pick_shape.shape = pbox
	pick_shape.position = Vector3(0.0, (height + radius + 2.0) * 0.5, 0.0)
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)

	# ---------- 6. 触发 Area3D (圆柱形) ----------
	_trigger_area = Area3D.new()
	_trigger_area.name = "Trigger"
	_trigger_area.monitoring = false
	_trigger_area.monitorable = false
	add_child(_trigger_area)
	var trigger_shape := CollisionShape3D.new()
	trigger_shape.name = "TriggerShape"
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = height * 2.0 + 2.0
	trigger_shape.shape = cyl
	trigger_shape.position = Vector3(0.0, height, 0.0)
	_trigger_area.add_child(trigger_shape)

	# ---------- 7. 运行时激活触发器 ----------
	if not Engine.is_editor_hint():
		_runtime_init_trigger()


# ============================================================
# 运行时触发器初始化
# ============================================================
func _runtime_init_trigger() -> void:
	if _trigger_area == null:
		return
	_trigger_area.monitoring = true
	_trigger_area.monitorable = false
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2   # 探测 layer=2 的车
	if not _trigger_area.body_entered.is_connected(_on_car_entered):
		_trigger_area.body_entered.connect(_on_car_entered)
	if not _trigger_area.body_exited.is_connected(_on_car_exited):
		_trigger_area.body_exited.connect(_on_car_exited)
	print("[Block_FinishLine] 运行时触发器已激活: radius=%.1f delay=%.2f" % [radius, teleport_delay])


# ============================================================
# 触发: 车进入 → 延迟后传送回出生点
# ============================================================
func _on_car_entered(body: Node) -> void:
	if not body.has_method("_reset_to_origin"):
		return
	var key: int = body.get_instance_id()
	if _pending_teleports.has(key):
		return   # 已经在等待传送了
	# 创建延迟计时器
	var timer := get_tree().create_timer(teleport_delay)
	_pending_teleports[key] = timer
	timer.timeout.connect(func() -> void:
		_pending_teleports.erase(key)
		# 再次确认车还在触发区内 (可能已经开出去了)
		if _trigger_area and _trigger_area.get_overlapping_bodies().has(body):
			# 先通知 HUD 停止计时 (在传送之前, 这样 HUD 能拿到最终时间)
			if body.has_signal("finish_line_reached"):
				body.emit_signal("finish_line_reached")
			body.call("_reset_to_origin")
			print("[Block_FinishLine] 传送! 车已回到出生点")
	)


func _on_car_exited(body: Node) -> void:
	var key: int = body.get_instance_id()
	# 车离开触发区: 取消待传送 (还没到 0.2 秒就开出去了)
	if _pending_teleports.has(key):
		_pending_teleports.erase(key)


# ============================================================
# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "radius",         "label": "半径 (m)",       "min": 2.0,  "max": 30.0, "step": 0.5,  "value": radius},
		{"key": "ring_thickness", "label": "环粗细 (m)",     "min": 0.1,  "max": 2.0,  "step": 0.05, "value": ring_thickness},
		{"key": "height",         "label": "环中心高 (m)",   "min": 1.0,  "max": 15.0, "step": 0.5,  "value": height},
		{"key": "teleport_delay", "label": "传送延迟 (秒)",  "min": 0.0,  "max": 3.0,  "step": 0.05, "value": teleport_delay},
		{"key": "color_r",        "label": "颜色 R",         "min": 0.0,  "max": 1.0,  "step": 0.05, "value": color_r},
		{"key": "color_g",        "label": "颜色 G",         "min": 0.0,  "max": 1.0,  "step": 0.05, "value": color_g},
		{"key": "color_b",        "label": "颜色 B",         "min": 0.0,  "max": 1.0,  "step": 0.05, "value": color_b},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"radius":         radius = value
		"ring_thickness": ring_thickness = value
		"height":         height = value
		"teleport_delay": teleport_delay = value
		"color_r":        color_r = value
		"color_g":        color_g = value
		"color_b":        color_b = value
