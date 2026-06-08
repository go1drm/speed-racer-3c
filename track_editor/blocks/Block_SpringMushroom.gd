@tool
extends Node3D
## ============================================================
## 机关 - 弹簧蘑菇 (SpringMushroom)
## ============================================================
## 经典弹簧床/蘑菇形机关. 玩家车带速度落到蘑菇盖上时:
##   1) 给一个向上的弹力 (linear_velocity.y += spring_velocity)
##   2) 完全保留原 X/Z 速度方向 (这是用户要求的关键: "保持原初速度方向不变")
##   3) 蘑菇视觉压扁→弹回动画 (Tween scale Y)
##
## 数学:
##   v_new.x = v_old.x                    ← 完全保留水平速度
##   v_new.z = v_old.z
##   v_new.y = max(v_old.y, 0) + spring_velocity   ← 累加向上速度, 但先把负 Y(下落) 截零避免抵消
##                                                    这样落得越快不会"消耗"弹力, 总能弹起 spring_velocity
##                                                    但如果原 Y 已经是正(上升中) 不抵消反而叠加
##
## 与 FlipBoard 区别:
##   FlipBoard 是固定方向冲量 (block 决定推哪儿)
##   SpringMushroom 是纯垂直弹力, 让玩家\"携带原速度跳过去\"
##
## 子节点结构:
##   StalkMesh (CylinderMesh)        — 蘑菇柄
##   CapMesh   (SphereMesh top half) — 蘑菇盖 (压扁球)
##   PickBody  (StaticBody3D)        — 编辑器选中盒
##   Trigger   (Area3D)              — 触发盒 (盖顶上方)
## ============================================================

# ============================================================
# 几何参数
# ============================================================
## 蘑菇盖半径 (米). 触发区也用这个
@export var cap_radius: float = 2.0:
	set(v):
		cap_radius = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 蘑菇盖高度 (米). 半球的高度
@export var cap_height: float = 1.2:
	set(v):
		cap_height = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 蘑菇柄高度 (米)
@export var stalk_height: float = 1.0:
	set(v):
		stalk_height = clampf(v, 0.001, 100000.0)
		if is_inside_tree(): _rebuild()
## 蘑菇柄半径 (米)
@export var stalk_radius: float = 0.6:
	set(v):
		stalk_radius = clampf(v, 0.1, 3.0)
		if is_inside_tree(): _rebuild()

# ============================================================
# 弹力参数
# ============================================================
## 向上弹力速度 (m/s). 直接累加到 linear_velocity.y
##   推荐 25~45: 25=能跳到 ~5m 高 (在 g=29+downforce=8=37 m/s² 减速下 v²/74)
##                30=能跳到 ~12m 高 (调用 apply_jump_pad_kick 跳过 downforce, 真实减速 g=29)
##                40=能跳到 ~27m 高
##   公式 (新): h ≈ v² / (2 × 29) (调用 apply_jump_pad_kick 后只受重力 g=29)
##   公式 (旧 fallback): h ≈ v² / (2 × 37) (受重力 + plain_downforce 双重减速)
@export var spring_velocity: float = 35.0
## 触发后冷却 (秒). 防止物理帧多次触发
@export var retrigger_cooldown: float = 0.5
## 视觉压扁动画时长 (秒). 蘑菇盖 scale Y 0→0.3→1.0 来回弹
@export var squish_duration: float = 0.18

# ============================================================
# 视觉参数
# ============================================================
## 蘑菇盖颜色 (默认红, 经典马里奥配色)
@export var cap_color: Color = Color(0.95, 0.15, 0.2, 1.0):
	set(v):
		cap_color = v
		if is_inside_tree(): _rebuild()
## 蘑菇柄颜色 (默认米白)
@export var stalk_color: Color = Color(0.95, 0.92, 0.85, 1.0):
	set(v):
		stalk_color = v
		if is_inside_tree(): _rebuild()
## 盖上是否带白点装饰 (经典蘑菇), 0=不要, 1=要
@export_range(0, 1, 1) var spots_enabled: int = 1:
	set(v):
		spots_enabled = clampi(v, 0, 1)
		if is_inside_tree(): _rebuild()

# ============================================================
# 内部
# ============================================================
var _cap_mesh: MeshInstance3D = null
var _stalk_mesh: MeshInstance3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null
var _recent_triggered: Dictionary = {}
var _squish_tween: Tween = null


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_cap_mesh = null
	_stalk_mesh = null
	_pick_body = null
	_trigger_area = null
	_squish_tween = null

	# ---------- 1. 蘑菇柄 (柱体) ----------
	if stalk_height > 0.001:
		_stalk_mesh = MeshInstance3D.new()
		_stalk_mesh.name = "StalkMesh"
		var cyl := CylinderMesh.new()
		cyl.top_radius = stalk_radius
		cyl.bottom_radius = stalk_radius * 1.15  # 底略粗
		cyl.height = stalk_height
		cyl.radial_segments = 16
		_stalk_mesh.mesh = cyl
		_stalk_mesh.position = Vector3(0.0, stalk_height * 0.5, 0.0)
		var stalk_mat := StandardMaterial3D.new()
		stalk_mat.albedo_color = stalk_color
		stalk_mat.metallic = 0.0
		stalk_mat.roughness = 0.7
		_stalk_mesh.material_override = stalk_mat
		add_child(_stalk_mesh)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			_stalk_mesh.owner = get_tree().edited_scene_root

	# ---------- 2. 蘑菇盖 (压扁的球, 取上半) ----------
	# 用 SphereMesh 整个球, 通过缩放 Y 让它扁
	# 数学: SphereMesh 默认 radius=0.5, 我们用 radius=cap_radius, scale.y = cap_height/cap_radius
	#       让球的"高"变成 cap_height
	_cap_mesh = MeshInstance3D.new()
	_cap_mesh.name = "CapMesh"
	var sm := SphereMesh.new()
	sm.radius = cap_radius
	sm.height = cap_radius * 2.0   # 球高 = 直径
	sm.radial_segments = 24
	sm.rings = 12
	_cap_mesh.mesh = sm
	# 把扁球放在柄顶, 同时只显示上半 (球心在柄顶+0, 球向下穿过柄)
	# 简化: 球心放在柄顶, 球的 -Y 半部分被柄盖住 (只露出上半球)
	_cap_mesh.position = Vector3(0.0, stalk_height, 0.0)
	# Y 缩放: 让球高度 = cap_height (球默认 height=2*radius, 所以 scale.y = cap_height / (2*radius))
	_cap_mesh.scale = Vector3(1.0, cap_height / (cap_radius * 2.0), 1.0)
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = cap_color
	cap_mat.metallic = 0.05
	cap_mat.roughness = 0.45
	cap_mat.emission_enabled = true
	cap_mat.emission = cap_color
	cap_mat.emission_energy_multiplier = 0.15
	_cap_mesh.material_override = cap_mat
	add_child(_cap_mesh)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_cap_mesh.owner = get_tree().edited_scene_root

	# ---------- 3. 蘑菇白点 (3 个小球随机散布在盖上) ----------
	if spots_enabled == 1:
		var spot_mat := StandardMaterial3D.new()
		spot_mat.albedo_color = Color(0.98, 0.98, 0.96, 1.0)
		spot_mat.metallic = 0.0
		spot_mat.roughness = 0.3
		# 用固定的 3 个角度位置 (避免随机不稳定)
		# 极坐标: (theta, phi) → 盖上一点
		# 简化为 4 个固定位置 ±cap 的 30~50% 偏移
		var spot_offsets: Array = [
			Vector3( 0.45 * cap_radius, 0.85 * cap_height, 0.20 * cap_radius),
			Vector3(-0.30 * cap_radius, 0.92 * cap_height,-0.40 * cap_radius),
			Vector3( 0.10 * cap_radius, 0.95 * cap_height, 0.55 * cap_radius),
		]
		for off in spot_offsets:
			var spot := MeshInstance3D.new()
			var spot_sm := SphereMesh.new()
			spot_sm.radius = cap_radius * 0.13
			spot_sm.height = cap_radius * 0.13 * 2.0
			spot_sm.radial_segments = 8
			spot_sm.rings = 5
			spot.mesh = spot_sm
			spot.position = Vector3(0.0, stalk_height, 0.0) + off
			spot.material_override = spot_mat
			add_child(spot)
			if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
				spot.owner = get_tree().edited_scene_root

	# ---------- 4. 编辑器选中盒 ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pcap := CapsuleShape3D.new()
	pcap.radius = max(cap_radius, stalk_radius) + 0.2
	pcap.height = stalk_height + cap_height
	pick_shape.shape = pcap
	pick_shape.position = Vector3(0.0, (stalk_height + cap_height) * 0.5, 0.0)
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 5. 触发 Area3D (蘑菇盖顶部一个圆柱区域, 让"踩到盖"的车触发) ----------
	_trigger_area = Area3D.new()
	_trigger_area.name = "Trigger"
	_trigger_area.monitoring = false
	add_child(_trigger_area)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_trigger_area.owner = get_tree().edited_scene_root
	var trigger_shape := CollisionShape3D.new()
	trigger_shape.name = "TriggerShape"
	var tcyl := CylinderShape3D.new()
	# 触发圆柱: 从地面起一直延伸到盖顶上方 (覆盖球心车 Y=1m + 任何高度落下的车)
	# 数学: 总高 = stalk_height + cap_height + 1.5 (盖顶上方 1.5m 缓冲), 范围 Y: 0 ~ 总高
	# 半径略大于盖, 让擦边掠过也能触发 (球心车的物理球半径=1.0 比盖中心略大)
	tcyl.radius = cap_radius * 1.05 + 0.5  # +0.5 确保从侧面冲来的车能撞到
	var total_h: float = stalk_height + cap_height + 1.5
	tcyl.height = total_h
	trigger_shape.shape = tcyl
	# 圆柱中心 = 总高的一半 (从地面 Y=0 起算)
	trigger_shape.position = Vector3(0.0, total_h * 0.5, 0.0)
	_trigger_area.add_child(trigger_shape)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		trigger_shape.owner = get_tree().edited_scene_root

	# ---------- 6. 仅运行时: 激活触发器 ----------
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
	print("[Block_SpringMushroom] 弹簧蘑菇触发器已激活")


func _on_car_entered(body: Node) -> void:
	if not (body is RigidBody3D):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = body.get_instance_id()
	if _recent_triggered.has(key) and float(_recent_triggered[key]) > now:
		return
	_recent_triggered[key] = now + retrigger_cooldown

	var car: RigidBody3D = body as RigidBody3D
	var v: Vector3 = car.linear_velocity
	# ---- 弹簧物理: 保留 XZ, Y 累加 spring_velocity ----
	# 数学:
	#   原 v = (vx, vy, vz)
	#   新 v.x = vx (不动)
	#   新 v.z = vz (不动)
	#   新 v.y = max(vy, 0) + spring_velocity
	#       max(vy, 0) 是关键: 如果车在下落 (vy<0) 先把它截到 0, 再加弹力
	#       否则下落速度会抵消弹力. 比如 vy=-15, spring=20 → 直接相加只剩 5,
	#       玩家会感觉"弹得很弱". 截零再加保证总弹起 spring_velocity
	v.y = maxf(v.y, 0.0) + spring_velocity
	# 用新接口绕开 _apply_ground_stick 的防弹/下压力 (短时窗口 0.4s 让弹力完整作用)
	# 旧版 car.linear_velocity = v 设完速度后, plain_downforce=8 m/s² 立刻向下压
	# → 22 m/s 弹力只能飞 6.5m 高 (用户感受"弹力不足"的根因)
	# 新版调 apply_jump_pad_kick: 0.4s 内跳过 ground_stick, 弹力完整作用
	# → 35 m/s 弹力能飞 21m 高 (公式: v²/2g = 35²/58 ≈ 21m)
	if car.has_method("apply_jump_pad_kick"):
		car.apply_jump_pad_kick(v, 0.4)
	else:
		# 后向兼容: 没有新接口的车 (理论上 StarDust Racers 所有车都有, 但兜底一下)
		car.linear_velocity = v

	# 震屏反馈 (轻微, 因为弹簧应该是\"啵\"的轻巧感不是\"砰\"的重击感)
	if car.has_signal("camera_shake_requested"):
		car.emit_signal("camera_shake_requested", 0.4, 0.15)

	# ---- 视觉压扁动画 ----
	_play_squish()
	print("[Block_SpringMushroom] P%d 被弹起 +%.1f m/s" %
		[car.get("player_id") if "player_id" in car else 0, spring_velocity])


# 蘑菇盖压扁→弹回视觉
func _play_squish() -> void:
	if _cap_mesh == null:
		return
	if _squish_tween and _squish_tween.is_valid():
		_squish_tween.kill()
	# 原始 Y scale = cap_height / (2*cap_radius) (在 _rebuild 里设的)
	var orig_y: float = cap_height / (cap_radius * 2.0)
	var squish_y: float = orig_y * 0.35   # 压扁到 35%
	_squish_tween = create_tween()
	# 阶段1: 快速压扁 (50ms, 模拟玩家踩下的瞬间)
	_squish_tween.tween_property(_cap_mesh, "scale:y", squish_y, 0.05).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	# 阶段2: 弹性回弹 (用 ELASTIC 模拟橡胶的"啵啵啵"颤动)
	_squish_tween.tween_property(_cap_mesh, "scale:y", orig_y, squish_duration).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# ============================================================
# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "cap_radius",         "label": "蘑菇盖半径(m)",   "min": 0.5, "max": 10.0, "step": 0.1, "value": cap_radius},
		{"key": "cap_height",         "label": "蘑菇盖高度(m)",   "min": 0.3, "max": 5.0,  "step": 0.1, "value": cap_height},
		{"key": "stalk_height",       "label": "柄高度(m)",       "min": 0.0, "max": 5.0,  "step": 0.1, "value": stalk_height},
		{"key": "stalk_radius",       "label": "柄半径(m)",       "min": 0.1, "max": 3.0,  "step": 0.1, "value": stalk_radius},
		{"key": "spring_velocity",    "label": "弹力速度(m/s)",   "min": 5.0, "max": 60.0, "step": 1.0, "value": spring_velocity},
		{"key": "retrigger_cooldown", "label": "复触发冷却(s)",   "min": 0.05,"max": 3.0,  "step": 0.05,"value": retrigger_cooldown},
		{"key": "squish_duration",    "label": "压扁动画(s)",     "min": 0.05,"max": 1.0,  "step": 0.02,"value": squish_duration},
		{"key": "spots_enabled",      "label": "白点装饰(0/1)",   "min": 0.0, "max": 1.0,  "step": 1.0, "value": float(spots_enabled)},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"cap_radius":         cap_radius = value
		"cap_height":         cap_height = value
		"stalk_height":       stalk_height = value
		"stalk_radius":       stalk_radius = value
		"spring_velocity":    spring_velocity = value
		"retrigger_cooldown": retrigger_cooldown = value
		"squish_duration":    squish_duration = value
		"spots_enabled":      spots_enabled = int(value)
