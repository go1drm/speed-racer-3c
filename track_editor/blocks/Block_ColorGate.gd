extends Node3D
class_name Block_ColorGate
## ============================================================
##  红蓝门机关 (Color Gate)
## ============================================================
## 一扇门可以设置为红门或蓝门 (通过参数切换).
##
## 规则:
##   - 当赛车靠近门时, 1P 车身闪耀红光, 2P 车身闪耀蓝光
##   - 红光车能通过红门, 蓝光车能通过蓝门
##   - 颜色不匹配的车撞到门会被弹飞 (强力冲量)
##
## 物理结构:
##   门框: 两个竖柱 + 横梁 (StaticBody3D, 碰撞层)
##   门面: Area3D 检测区, 判断谁进入
##   当匹配颜色的车进入 → 暂时禁用碰撞让车通过
##   当不匹配的车进入 → 保持碰撞 + 给予弹飞冲量
##
## 颜色约定:
##   gate_color_mode = 0 → 红门 (1P 可通过)
##   gate_color_mode = 1 → 蓝门 (2P 可通过)
## ============================================================

@export_group("门体")
## 门宽 (两柱间距, 米)
@export_range(4.0, 30.0, 1.0) var gate_width: float = 10.0
## 门高 (米)
@export_range(3.0, 15.0, 0.5) var gate_height: float = 6.0
## 柱子半径 (米)
@export_range(0.2, 2.0, 0.1) var pillar_radius: float = 0.5
## 门面厚度 (米, 碰撞 + 视觉)
@export_range(0.2, 3.0, 0.1) var gate_thickness: float = 0.5

@export_group("颜色模式")
## 0 = 红门 (1P可通过), 1 = 蓝门 (2P可通过)
@export_range(0, 1, 1) var gate_color_mode: int = 0

@export_group("效果")
## 检测范围 (靠近多远时车身开始发光, 米)
@export_range(5.0, 40.0, 1.0) var glow_detect_range: float = 15.0
## 车身发光强度
@export_range(0.5, 5.0, 0.1) var car_glow_intensity: float = 2.0
## 弹飞速度 (不匹配时, 直接覆写车速, m/s)
@export_range(10.0, 120.0, 5.0) var reject_impulse: float = 60.0
## 弹飞方向: 水平反弹 + 向上抬升比例
@export_range(0.0, 1.0, 0.1) var reject_up_ratio: float = 0.5


# ---- 内部 ----
var _gate_body: StaticBody3D = null       # 门面碰撞体
var _detect_area: Area3D = null            # 大范围检测区 (发光提示)
var _pass_area: Area3D = null              # 门面通过判定区
var _gate_mesh: MeshInstance3D = null       # 门面视觉 mesh (用于颜色动画)
var _gate_material: StandardMaterial3D = null
var _pillar_l_mesh: MeshInstance3D = null
var _pillar_r_mesh: MeshInstance3D = null
var _beam_mesh: MeshInstance3D = null

# 正在发光的车身列表: {car_node: 原始材质字典}
var _glowing_cars: Dictionary = {}
# 已允许通过的车 (临时禁用碰撞)
var _passing_cars: Array = []


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_gate_body = null
	_detect_area = null
	_pass_area = null
	_gate_mesh = null
	_glowing_cars.clear()
	_passing_cars.clear()

	var color_red := Color(0.9, 0.15, 0.1)
	var color_blue := Color(0.1, 0.3, 0.95)
	var gate_color: Color = color_red if gate_color_mode == 0 else color_blue

	# --- 左右柱子 (纯视觉 + 碰撞在 gate_body 内) ---
	var pillar_body := StaticBody3D.new()
	pillar_body.name = "PillarBody"
	pillar_body.collision_layer = 1
	pillar_body.collision_mask = 0

	# 左柱
	_pillar_l_mesh = _make_pillar(Vector3(-gate_width * 0.5, gate_height * 0.5, 0.0), gate_color)
	pillar_body.add_child(_pillar_l_mesh)
	var lcol := CollisionShape3D.new()
	var lcyl := CylinderShape3D.new()
	lcyl.radius = pillar_radius
	lcyl.height = gate_height
	lcol.shape = lcyl
	lcol.position = Vector3(-gate_width * 0.5, gate_height * 0.5, 0.0)
	pillar_body.add_child(lcol)

	# 右柱
	_pillar_r_mesh = _make_pillar(Vector3(gate_width * 0.5, gate_height * 0.5, 0.0), gate_color)
	pillar_body.add_child(_pillar_r_mesh)
	var rcol := CollisionShape3D.new()
	var rcyl := CylinderShape3D.new()
	rcyl.radius = pillar_radius
	rcyl.height = gate_height
	rcol.shape = rcyl
	rcol.position = Vector3(gate_width * 0.5, gate_height * 0.5, 0.0)
	pillar_body.add_child(rcol)

	# 横梁
	_beam_mesh = MeshInstance3D.new()
	_beam_mesh.name = "Beam"
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(gate_width + pillar_radius * 2, pillar_radius * 1.5, pillar_radius * 1.5)
	_beam_mesh.mesh = bmesh
	_beam_mesh.position = Vector3(0.0, gate_height, 0.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = gate_color
	bmat.emission_enabled = true
	bmat.emission = gate_color
	bmat.emission_energy_multiplier = 0.6
	bmat.metallic = 0.5
	bmat.roughness = 0.4
	_beam_mesh.material_override = bmat
	pillar_body.add_child(_beam_mesh)
	# 横梁碰撞
	var bcol := CollisionShape3D.new()
	var bbox := BoxShape3D.new()
	bbox.size = Vector3(gate_width + pillar_radius * 2, pillar_radius * 1.5, pillar_radius * 1.5)
	bcol.shape = bbox
	bcol.position = Vector3(0.0, gate_height, 0.0)
	pillar_body.add_child(bcol)

	add_child(pillar_body)

	# --- 门面 (碰撞墙 - 会根据匹配情况临时 disable) ---
	_gate_body = StaticBody3D.new()
	_gate_body.name = "GateWall"
	_gate_body.collision_layer = 1
	_gate_body.collision_mask = 0

	var gate_col := CollisionShape3D.new()
	gate_col.name = "GateCol"
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(gate_width - pillar_radius * 2, gate_height - pillar_radius * 1.5, gate_thickness)
	gate_col.shape = gbox
	gate_col.position = Vector3(0.0, gate_height * 0.5, 0.0)
	_gate_body.add_child(gate_col)

	# 门面视觉 (半透明彩色面板)
	_gate_mesh = MeshInstance3D.new()
	_gate_mesh.name = "GateMesh"
	var gmesh := BoxMesh.new()
	gmesh.size = Vector3(gate_width - pillar_radius * 2, gate_height - pillar_radius * 1.5, gate_thickness * 0.5)
	_gate_mesh.mesh = gmesh
	_gate_mesh.position = Vector3(0.0, gate_height * 0.5, 0.0)
	_gate_material = StandardMaterial3D.new()
	_gate_material.albedo_color = Color(gate_color.r, gate_color.g, gate_color.b, 0.4)
	_gate_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_gate_material.emission_enabled = true
	_gate_material.emission = gate_color
	_gate_material.emission_energy_multiplier = 1.0
	_gate_material.metallic = 0.3
	_gate_material.roughness = 0.5
	_gate_mesh.material_override = _gate_material
	_gate_body.add_child(_gate_mesh)

	add_child(_gate_body)

	# --- 大范围检测区 (车身发光提示) ---
	_detect_area = Area3D.new()
	_detect_area.name = "GlowDetectArea"
	_detect_area.collision_layer = 0
	_detect_area.collision_mask = 2  # 车层
	var dshape := CollisionShape3D.new()
	var dsphere := SphereShape3D.new()
	dsphere.radius = glow_detect_range
	dshape.shape = dsphere
	dshape.position = Vector3(0.0, gate_height * 0.5, 0.0)
	_detect_area.add_child(dshape)
	_detect_area.body_entered.connect(_on_detect_entered)
	_detect_area.body_exited.connect(_on_detect_exited)
	add_child(_detect_area)

	# --- 门面通过判定区 (紧贴门面, 判断是否匹配) ---
	_pass_area = Area3D.new()
	_pass_area.name = "PassArea"
	_pass_area.collision_layer = 0
	_pass_area.collision_mask = 2  # 车层
	var pshape := CollisionShape3D.new()
	var pbox := BoxShape3D.new()
	# 比门面稍大一点, 确保车进入时能检测到
	pbox.size = Vector3(gate_width, gate_height, gate_thickness + 2.0)
	pshape.shape = pbox
	pshape.position = Vector3(0.0, gate_height * 0.5, 0.0)
	_pass_area.add_child(pshape)
	_pass_area.body_entered.connect(_on_pass_entered)
	_pass_area.body_exited.connect(_on_pass_exited)
	add_child(_pass_area)


func _make_pillar(pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cmesh := CylinderMesh.new()
	cmesh.top_radius = pillar_radius
	cmesh.bottom_radius = pillar_radius
	cmesh.height = gate_height
	cmesh.radial_segments = 12
	mi.mesh = cmesh
	mi.position = pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.4
	mat.metallic = 0.4
	mat.roughness = 0.5
	mi.material_override = mat
	return mi


# ---- 检测: 靠近时车身发光 ----
func _on_detect_entered(body: Node3D) -> void:
	if not _is_car(body):
		return
	var player_id: int = _get_player_id(body)
	_apply_car_glow(body, player_id)


func _on_detect_exited(body: Node3D) -> void:
	if not _is_car(body):
		return
	_remove_car_glow(body)


# ---- 门面通过判定 ----
func _on_pass_entered(body: Node3D) -> void:
	if not _is_car(body):
		return
	var player_id: int = _get_player_id(body)
	# 匹配规则: 红门(mode=0) → 1P(id=0)可通过; 蓝门(mode=1) → 2P(id=1)可通过
	var can_pass: bool = (gate_color_mode == 0 and player_id == 0) or \
						  (gate_color_mode == 1 and player_id == 1)
	if can_pass:
		# 暂时禁用门面碰撞让车通过
		_passing_cars.append(body)
		_gate_body.collision_layer = 0
		# 门面视觉变更透明表示可通过
		if _gate_material:
			_gate_material.albedo_color.a = 0.1
			_gate_material.emission_energy_multiplier = 0.3
	else:
		# 弹飞! 给车施加反方向冲量
		_reject_car(body)


func _on_pass_exited(body: Node3D) -> void:
	if body in _passing_cars:
		_passing_cars.erase(body)
		# 所有通过的车都走了, 恢复碰撞
		if _passing_cars.is_empty():
			_gate_body.collision_layer = 1
			if _gate_material:
				_gate_material.albedo_color.a = 0.4
				_gate_material.emission_energy_multiplier = 1.0


func _reject_car(body: Node3D) -> void:
	## 猛猛弹飞不匹配的车 — 直接覆写速度确保飞出去
	if body is RigidBody3D:
		var rb: RigidBody3D = body as RigidBody3D
		# 方向: 从门面中心指向车 + 向上抬升
		var dir: Vector3 = (rb.global_position - global_position)
		dir.y = 0.0
		if dir.length() < 0.1:
			dir = -global_transform.basis.z  # 回退: 用门面法线方向
		dir = dir.normalized()
		dir.y = reject_up_ratio
		dir = dir.normalized()
		# 直接设速度 (不用 impulse, 确保无论车多重都飞一样远)
		rb.linear_velocity = dir * reject_impulse
		# 加旋转让视觉更猛
		rb.angular_velocity = Vector3(
			randf_range(-5.0, 5.0),
			randf_range(-3.0, 3.0),
			randf_range(-5.0, 5.0)
		)


# ---- 车身发光效果 ----
func _apply_car_glow(car: Node3D, player_id: int) -> void:
	## 给车身所有 MeshInstance3D 加 emission
	if car in _glowing_cars:
		return  # 已经在发光
	var glow_color: Color = Color(0.9, 0.15, 0.1) if player_id == 0 else Color(0.1, 0.3, 0.95)
	var originals: Dictionary = {}

	# 找 car_mesh 子节点下的所有 MeshInstance3D
	var mesh_parent: Node = car
	# 如果车有 car_mesh 子节点 (StarDust Racers 结构)
	var cm := car.get_node_or_null("CarMesh")
	if cm == null:
		cm = car.get_node_or_null("car_mesh")
	if cm:
		mesh_parent = cm

	for child in _get_all_mesh_instances(mesh_parent):
		var mi: MeshInstance3D = child
		var orig_mat = mi.material_override
		originals[mi] = orig_mat
		# 创建发光材质覆盖
		var glow_mat: StandardMaterial3D
		if orig_mat is StandardMaterial3D:
			glow_mat = orig_mat.duplicate() as StandardMaterial3D
		else:
			glow_mat = StandardMaterial3D.new()
			if orig_mat:
				glow_mat.albedo_color = Color(0.5, 0.5, 0.5)
		glow_mat.emission_enabled = true
		glow_mat.emission = glow_color
		glow_mat.emission_energy_multiplier = car_glow_intensity
		mi.material_override = glow_mat

	_glowing_cars[car] = originals


func _remove_car_glow(car: Node3D) -> void:
	## 移除车身发光, 恢复原始材质
	if car not in _glowing_cars:
		return
	var originals: Dictionary = _glowing_cars[car]
	for mi in originals.keys():
		if is_instance_valid(mi):
			mi.material_override = originals[mi]
	_glowing_cars.erase(car)


func _get_all_mesh_instances(node: Node) -> Array:
	var result: Array = []
	if node is MeshInstance3D:
		result.append(node)
	for child in node.get_children():
		result.append_array(_get_all_mesh_instances(child))
	return result


# ---- 工具函数 ----
func _is_car(body: Node3D) -> bool:
	## 判断是不是赛车 (RigidBody3D + 在车层)
	return body is RigidBody3D and body.collision_layer & 2 != 0


func _get_player_id(body: Node3D) -> int:
	## 获取赛车的玩家 ID (0=1P, 1=2P)
	## StarDust Racers 里车的 player_id: 0=1P(键盘), 1=2P(手柄)
	if body.has_method("get_player_id"):
		return body.get_player_id()
	if "player_id" in body:
		return body.player_id
	# 回退: 通过名字判断
	var n: String = body.name.to_lower()
	if "p2" in n or "player2" in n or "2" in n:
		return 1  # 2P = id 1
	return 0  # 默认 1P = id 0


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "gate_width", "label": "门宽(m)", "min": 4.0, "max": 30.0, "step": 1.0, "value": gate_width},
		{"key": "gate_height", "label": "门高(m)", "min": 3.0, "max": 15.0, "step": 0.5, "value": gate_height},
		{"key": "pillar_radius", "label": "柱半径(m)", "min": 0.2, "max": 2.0, "step": 0.1, "value": pillar_radius},
		{"key": "gate_thickness", "label": "门面厚度(m)", "min": 0.2, "max": 3.0, "step": 0.1, "value": gate_thickness},
		{"key": "gate_color_mode", "label": "颜色(0红1蓝)", "min": 0.0, "max": 1.0, "step": 1.0, "value": float(gate_color_mode)},
		{"key": "glow_detect_range", "label": "发光检测距离(m)", "min": 5.0, "max": 40.0, "step": 1.0, "value": glow_detect_range},
		{"key": "car_glow_intensity", "label": "车身发光强度", "min": 0.5, "max": 5.0, "step": 0.1, "value": car_glow_intensity},
		{"key": "reject_impulse", "label": "弹飞冲量", "min": 5.0, "max": 80.0, "step": 1.0, "value": reject_impulse},
		{"key": "reject_up_ratio", "label": "弹飞上抬比例", "min": 0.0, "max": 1.0, "step": 0.1, "value": reject_up_ratio},
	]


var _rebuild_pending: bool = false

func set_editable_param(key: String, value: float) -> void:
	match key:
		"gate_width": gate_width = value
		"gate_height": gate_height = value
		"pillar_radius": pillar_radius = value
		"gate_thickness": gate_thickness = value
		"gate_color_mode": gate_color_mode = int(value)
		"glow_detect_range": glow_detect_range = value
		"car_glow_intensity": car_glow_intensity = value
		"reject_impulse": reject_impulse = value
		"reject_up_ratio": reject_up_ratio = value
	if not _rebuild_pending:
		_rebuild_pending = true
		call_deferred("_deferred_rebuild")

func _deferred_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()


func reset_state() -> void:
	## 按 B 复位时: 清除车身发光 + 恢复门面碰撞 + 清通过列表
	for car in _glowing_cars.keys():
		if is_instance_valid(car):
			_remove_car_glow(car)
	_glowing_cars.clear()
	_passing_cars.clear()
	if _gate_body:
		_gate_body.collision_layer = 1
	if _gate_material:
		_gate_material.albedo_color.a = 0.4
		_gate_material.emission_energy_multiplier = 1.0
