@tool
extends Node3D
## ============================================================
## 机关 - 固定跳板 (FlipBoard)
## ============================================================
## 水平放置的薄板. 玩家车踩上后:
##   1) 板子绕底部铰链\"翻起\"动画 (0° → flip_angle_deg, 默认 75°)
##   2) 给车一个**固定方向**的冲量 (沿 block local +Z + Y 朝上, 模拟弹板把车拍飞)
##      注: 是"固定方向"= block 旋转决定方向, 不依赖车的入射方向
##   3) flip_recover_delay 秒后板子缓慢回落到水平, 等下一个玩家
##
## 数学:
##   v_kick = (block.basis × Vector3(0, sin(angle), cos(angle))) × kick_speed
##   linear_velocity += v_kick   (累加, 保留水平惯性, 用户说\"把玩家弹飞\")
##   实际把车的速度直接覆盖比较合适, 否则反向冲过来的车会被弱化:
##     linear_velocity.y = max(linear_velocity.y, kick_y)
##     linear_velocity.x/z 加上 kick 的 xz 分量 (沿 block 的 +Z)
##
## 子节点:
##   FlipMesh   (MeshInstance3D)  — 翻板薄板, 通过 rotation_x 控制翻起角度
##   PickBody   (StaticBody3D)    — 编辑器选中盒
##   Trigger    (Area3D)          — 触发盒 (覆盖板子表面)
## ============================================================

# ============================================================
# 几何参数
# ============================================================
## 板子宽度 (X 方向, 米)
@export var board_width: float = 6.0:
	set(v):
		board_width = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 板子长度 (Z 方向, 米). 这也是\"翻起后顶部高度\"的近似 (因为绕近端铰链翻)
@export var board_length: float = 3.5:
	set(v):
		board_length = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 板子厚度 (Y 方向, 米)
@export var board_thickness: float = 0.25:
	set(v):
		board_thickness = clampf(v, 0.05, 1.0)
		if is_inside_tree(): _rebuild()

# ============================================================
# 弹射参数
# ============================================================
## 翻起角度 (度). 0=不翻, 75°=接近垂直但留一点角度让冲量方向有水平分量
@export var flip_angle_deg: float = 75.0:
	set(v):
		flip_angle_deg = clampf(v, 0.001, 100000.0)
## 翻起动画时长 (秒). 越短越像\"啪\"地一拍, 推荐 0.08~0.2
@export var flip_anim_duration: float = 0.12
## 翻起后停留时长 (秒, 在最高位停多久才往回落)
@export var flip_hold_duration: float = 0.4
## 回落动画时长 (秒)
@export var flip_recover_duration: float = 0.6
## 弹射速度 (m/s). 给车的总速度大小
##   实际方向 = block local 的 (0, sin(angle), cos(angle))
##   即斜向上, 沿 block +Z 方向 (block 旋转决定推车方向)
##   推荐 25 ~ 60. 25 = 中等弹跳, 60 = 飞天炮
@export var kick_speed: float = 35.0
## 冷却时间 (秒). 同一辆车进入触发的最小间隔, 防止物理帧多次触发
@export var retrigger_cooldown: float = 1.0

# ============================================================
# 视觉参数
# ============================================================
## 板子颜色
@export var board_color: Color = Color(1.0, 0.45, 0.1, 1.0):
	set(v):
		board_color = v
		if is_inside_tree(): _rebuild()
## 边缘警示条颜色 (黑黄相间用纯色简化为黄)
@export var edge_color: Color = Color(1.0, 0.85, 0.1, 1.0)

# ============================================================
# 内部
# ============================================================
var _flip_mesh: MeshInstance3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null
var _recent_triggered: Dictionary = {}   # car.get_instance_id() -> cooldown_end_time
var _is_flipping: bool = false             # 当前是否在翻起/回落动画中
var _flip_tween: Tween = null


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_flip_mesh = null
	_pick_body = null
	_trigger_area = null
	_is_flipping = false
	_flip_tween = null

	var hw: float = board_width * 0.5
	# 翻板用一个 \"枢轴节点\" 包住 mesh, 让翻起绕近端 (Z = -hl) 边铰链转动
	# 数学: 把 mesh 平移到 (0, 0, +half_length), 让枢轴在 (0, 0, 0) (= 近端铰链)
	#       然后旋转枢轴的 X 轴就能让板子绕近端翻起 (像盖子翻开)
	var hl: float = board_length * 0.5

	# ---------- 1. 翻板枢轴 (Node3D) + 板子 mesh ----------
	# 枢轴在原点 (= 近端铰链), 旋转此节点让板子翻起
	var pivot := Node3D.new()
	pivot.name = "FlipPivot"
	# 枢轴位置: 把铰链放在 z=-hl (block 的近玩家端), 让板子整体在 z=0~+block_length 范围
	pivot.position = Vector3(0.0, board_thickness * 0.5, -hl)
	add_child(pivot)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		pivot.owner = get_tree().edited_scene_root

	_flip_mesh = MeshInstance3D.new()
	_flip_mesh.name = "FlipMesh"
	var bm := BoxMesh.new()
	bm.size = Vector3(board_width, board_thickness, board_length)
	_flip_mesh.mesh = bm
	# 板子 mesh 偏移让其前端正对铰链
	_flip_mesh.position = Vector3(0.0, 0.0, hl)
	var board_mat := StandardMaterial3D.new()
	board_mat.albedo_color = board_color
	board_mat.metallic = 0.4
	board_mat.roughness = 0.5
	board_mat.emission_enabled = true
	board_mat.emission = board_color
	board_mat.emission_energy_multiplier = 0.25
	_flip_mesh.material_override = board_mat
	pivot.add_child(_flip_mesh)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_flip_mesh.owner = get_tree().edited_scene_root

	# ---------- 2. 警示边条 (沿板子三个外边, 黄色) ----------
	var edge_mat := StandardMaterial3D.new()
	edge_mat.albedo_color = edge_color
	edge_mat.emission_enabled = true
	edge_mat.emission = edge_color
	edge_mat.emission_energy_multiplier = 1.0
	edge_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# 远端边 (z = +board_length, 是板子翻起后的"顶端")
	var edge_far := MeshInstance3D.new()
	var edge_far_mesh := BoxMesh.new()
	edge_far_mesh.size = Vector3(board_width, board_thickness * 1.05, 0.15)
	edge_far.mesh = edge_far_mesh
	edge_far.position = Vector3(0.0, 0.01, board_length - 0.075)
	edge_far.material_override = edge_mat
	pivot.add_child(edge_far)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		edge_far.owner = get_tree().edited_scene_root
	# 左/右长边
	for sx in [-1.0, 1.0]:
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = Vector3(0.15, board_thickness * 1.05, board_length)
		bar.mesh = bar_mesh
		bar.position = Vector3(sx * (hw - 0.075), 0.01, board_length * 0.5)
		bar.material_override = edge_mat
		pivot.add_child(bar)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			bar.owner = get_tree().edited_scene_root

	# ---------- 3. 编辑器选中盒 ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(board_width + 0.5, max(board_thickness, 0.4), board_length + 0.5)
	pick_shape.shape = pbox
	pick_shape.position = Vector3(0.0, board_thickness * 0.5, 0.0)
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 4. 触发 Area3D (覆盖板子顶面 + 上方 1m, 让飞过的车也能踩) ----------
	_trigger_area = Area3D.new()
	_trigger_area.name = "Trigger"
	_trigger_area.monitoring = false
	_trigger_area.monitorable = false
	add_child(_trigger_area)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_trigger_area.owner = get_tree().edited_scene_root
	var trigger_shape := CollisionShape3D.new()
	trigger_shape.name = "TriggerShape"
	var tbox := BoxShape3D.new()
	tbox.size = Vector3(board_width, 1.5, board_length)
	trigger_shape.shape = tbox
	trigger_shape.position = Vector3(0.0, 0.75, 0.0)   # 板面以上 0~1.5m
	_trigger_area.add_child(trigger_shape)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		trigger_shape.owner = get_tree().edited_scene_root

	# ---------- 5. 仅运行时: 激活触发器 ----------
	if not Engine.is_editor_hint():
		_runtime_init_trigger()


func _runtime_init_trigger() -> void:
	if _trigger_area == null:
		return
	_trigger_area.monitoring = true
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2  # 探测 layer=2 的赛车
	if not _trigger_area.body_entered.is_connected(_on_car_entered):
		_trigger_area.body_entered.connect(_on_car_entered)
	print("[Block_FlipBoard] 跳板触发器已激活")


func _on_car_entered(body: Node) -> void:
	# 只处理 RigidBody3D (= car)
	if not (body is RigidBody3D):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = body.get_instance_id()
	if _recent_triggered.has(key) and float(_recent_triggered[key]) > now:
		return
	_recent_triggered[key] = now + retrigger_cooldown

	# ---- 给车固定方向冲量 ----
	# kick 方向 (block local) = (0, sin(angle), cos(angle))
	# 经 block 的 global_transform.basis 变换到世界空间
	# 数学: 板子翻起 angle 度, 板面法线在 local 是 (0, cos, -sin) 但我们要"沿板面外法线"
	#       简化: 用一个固定的发射方向 (0, sin, cos), 即斜上方 + 朝 block +Z
	#       angle = 90° 时方向 = (0,1,0) 纯朝上; angle = 0° 时方向 = (0,0,1) 纯朝前
	#       默认 75° → (0, 0.97, 0.26): 主要朝上 + 一点点朝 block +Z 推
	var ang: float = deg_to_rad(flip_angle_deg)
	var local_dir: Vector3 = Vector3(0.0, sin(ang), cos(ang))
	var world_dir: Vector3 = (global_transform.basis * local_dir).normalized()
	var car: RigidBody3D = body as RigidBody3D

	# 弹飞方向: 从机关中心指向赛车 (水平) + 跳板角度决定的向上分量
	# 初始速度不参与计算, 纯由机关参数决定弹出轨迹
	var horiz_dir: Vector3 = (car.global_position - global_position)
	horiz_dir.y = 0.0
	if horiz_dir.length() < 0.1:
		horiz_dir = (global_transform.basis * Vector3(0, 0, 1))
		horiz_dir.y = 0.0
	horiz_dir = horiz_dir.normalized()
	# 用跳板角度决定向上比例: sin(angle)=向上, cos(angle)=水平
	var up_ratio: float = sin(ang)
	var horiz_ratio: float = cos(ang)
	var dir: Vector3 = (Vector3.UP * up_ratio + horiz_dir * horiz_ratio).normalized()
	var new_v: Vector3 = dir * kick_speed
	if car.has_method("apply_jump_pad_kick"):
		car.apply_jump_pad_kick(new_v, 0.5)
	else:
		car.linear_velocity = new_v
	# 随机小角速度
	car.angular_velocity = Vector3(
		randf_range(-2.0, 2.0), randf_range(-1.0, 1.0), randf_range(-2.0, 2.0)
	)
	# 震屏反馈
	if car.has_signal("camera_shake_requested"):
		car.emit_signal("camera_shake_requested", 0.8, 0.2)

	# ---- 启动板子翻起动画 ----
	_play_flip_animation()
	print("[Block_FlipBoard] 弹飞 P%d, kick=%.1f m/s 方向=%s" %
		[car.get("player_id") if "player_id" in car else 0, kick_speed, str(world_dir)])


# 翻起 → 停留 → 回落 三段动画
func _play_flip_animation() -> void:
	var pivot: Node3D = get_node_or_null("FlipPivot") as Node3D
	if pivot == null:
		return
	if _flip_tween and _flip_tween.is_valid():
		_flip_tween.kill()
	_is_flipping = true
	_flip_tween = create_tween()
	# 阶段1: 快速翻起 (绕 pivot 的 X 轴负方向旋转, 让板子近端为铰链, 远端往上抬)
	# 数学: rotation.x 从 0 → -flip_angle_rad (负值让 +Z 板面朝上抬起)
	var flip_rad: float = -deg_to_rad(flip_angle_deg)
	_flip_tween.tween_property(pivot, "rotation:x", flip_rad, flip_anim_duration).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# 阶段2: 停留
	_flip_tween.tween_interval(flip_hold_duration)
	# 阶段3: 缓慢回落
	_flip_tween.tween_property(pivot, "rotation:x", 0.0, flip_recover_duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	_flip_tween.tween_callback(func(): _is_flipping = false)


# ============================================================
# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "board_width",          "label": "宽度 (X, m)",     "min": 1.0, "max": 30.0, "step": 0.5,  "value": board_width},
		{"key": "board_length",         "label": "长度 (Z, m)",     "min": 0.5, "max": 20.0, "step": 0.5,  "value": board_length},
		{"key": "board_thickness",      "label": "厚度 (Y, m)",     "min": 0.05,"max": 1.0,  "step": 0.05, "value": board_thickness},
		{"key": "flip_angle_deg",       "label": "翻起角度(度)",    "min": 0.0, "max": 90.0, "step": 5.0,  "value": flip_angle_deg},
		{"key": "kick_speed",           "label": "弹射速度(m/s)",   "min": 5.0, "max": 100.0,"step": 1.0,  "value": kick_speed},
		{"key": "flip_anim_duration",   "label": "翻起动画(s)",     "min": 0.02,"max": 1.0,  "step": 0.02, "value": flip_anim_duration},
		{"key": "flip_hold_duration",   "label": "停留时长(s)",     "min": 0.0, "max": 3.0,  "step": 0.1,  "value": flip_hold_duration},
		{"key": "flip_recover_duration","label": "回落时长(s)",     "min": 0.05,"max": 3.0,  "step": 0.05, "value": flip_recover_duration},
		{"key": "retrigger_cooldown",   "label": "复触发冷却(s)",   "min": 0.1, "max": 5.0,  "step": 0.1,  "value": retrigger_cooldown},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"board_width":          board_width = value
		"board_length":         board_length = value
		"board_thickness":      board_thickness = value
		"flip_angle_deg":       flip_angle_deg = value
		"kick_speed":           kick_speed = value
		"flip_anim_duration":   flip_anim_duration = value
		"flip_hold_duration":   flip_hold_duration = value
		"flip_recover_duration":flip_recover_duration = value
		"retrigger_cooldown":   retrigger_cooldown = value
