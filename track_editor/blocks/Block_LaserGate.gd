@tool
extends Node3D
## ============================================================
## 毒图机关 - 激光闸门 (LaserGate)
## ============================================================
## 一面像素薄激光板, 周期性沿"扫动方向"在最低/最高位置之间往复运动.
## 玩家车进入激光面包围盒时:
##   1) 调 car.apply_laser_hit(impulse, slow, shake) 大幅扣速 + 反向冲量 + 强震屏
##   2) 钩索/漂移被打断, 玩家被弹回
##
## 玩家挑战:
##   · 看激光节奏, 算准时机加速冲过 (类似经典平台跳跃的"激光门")
##   · 激光区会有冲量但不会复位, 撞了还能继续, 但代价巨大
##
## 子节点结构 (rebuild 后):
##   LaserBeam (MeshInstance3D)      — 红色发光薄板 (永远朝运动法线方向)
##   GateFrame (MeshInstance3D x2)   — 两侧的"门框"金属柱, 标记激光的运动轨道
##   PickBody (StaticBody3D)         — 编辑器选中盒
##   Trigger (Area3D)                — 激光面附近的触发盒 (跟着激光移动)
##
## 扫动方向:
##   sweep_axis: 0=Y(上下扫), 1=X(左右扫)
##   激光面始终垂直于车前进方向 (Z轴垂直于面), 运动方向决定了它在哪个轴上摆
## ============================================================

# ============================================================
# 几何参数
# ============================================================
## 激光面宽度 (X 方向, 米). 上下扫动模式下相当于"门的宽度"
@export var laser_width: float = 12.0:
	set(v):
		laser_width = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()
## 激光面高度 (Y 方向, 米). 上下扫动模式下相当于"门的高度"
@export var laser_height: float = 5.0:
	set(v):
		laser_height = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()
## 激光面厚度 (Z 方向, 米). 触发判定厚度, 视觉用 0.2m
@export var laser_thickness: float = 0.5:
	set(v):
		laser_thickness = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()

# ============================================================
# 扫动参数
# ============================================================
## 扫动模式: 0=上下扫(沿Y), 1=左右扫(沿X)
## 上下扫: 玩家需要算时机, 激光在低位时车冲过去
## 左右扫: 玩家需要"切线时机", 像 QQ飞车的激光门
@export_enum("Y轴(上下)", "X轴(左右)") var sweep_axis: int = 0:
	set(v):
		sweep_axis = clampi(v, 0, 1)
		if is_inside_tree():
			_rebuild()
## 扫动振幅 (米). 激光中心在 [-amp, +amp] 间往复
@export var sweep_amplitude: float = 3.0:
	set(v):
		sweep_amplitude = clampf(v, 0.001, 100000.0)
## 扫动周期 (秒). 一来一回的总时长. 越短激光来回越快
@export var sweep_period: float = 2.5:
	set(v):
		sweep_period = clampf(v, 0.001, 100000.0)
## 扫动相位偏移 (0~1, 比例化). 让多个闸门可以错峰
## 0 = 从中点开始, 0.25 = 起始就在最高点, 0.5 = 在另一边的中点向下, 0.75 = 在最低点
@export var sweep_phase: float = 0.0:
	set(v):
		sweep_phase = clampf(v, 0.0, 1.0)

# ============================================================
# 命中行为参数 (传给 car.apply_laser_hit)
# ============================================================
## 反向冲量 (m/s × mass, 沿车头反向). 0 = 不反推, 推荐 6~12
@export var hit_impulse: float = 8.0:
	set(v): hit_impulse = clampf(v, 0.001, 100000.0)
## 速度衰减比例 (0~1). 0.4 = 命中后速度砍到原 40%, 推荐 0.3~0.6
@export var hit_slow_factor: float = 0.4:
	set(v): hit_slow_factor = clampf(v, 0.0, 1.0)
## 命中震屏强度
@export var hit_shake: float = 1.2:
	set(v): hit_shake = clampf(v, 0.0, 3.0)
## 同一辆车命中后的冷却 (秒), 防止激光"扫过来"重复触发
@export var retrigger_cooldown: float = 0.6

# ============================================================
# 视觉参数
# ============================================================
## 激光颜色 (默认刺眼红, 警示性)
@export var laser_color_r: float = 1.0:
	set(v): laser_color_r = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
@export var laser_color_g: float = 0.15:
	set(v): laser_color_g = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
@export var laser_color_b: float = 0.15:
	set(v): laser_color_b = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
## 激光发光强度 (越大越刺眼, 会 bloom)
@export var laser_emission: float = 4.0:
	set(v): laser_emission = clampf(v, 0.001, 100000.0); if is_inside_tree(): _rebuild()

# ============================================================
# 内部节点引用
# ============================================================
var _laser_beam: MeshInstance3D = null
var _laser_mat: StandardMaterial3D = null
var _gate_frame: Node3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null
var _trigger_shape_node: CollisionShape3D = null

# 运行时状态
var _time_elapsed: float = 0.0
var _recent_triggered: Dictionary = {}


func _ready() -> void:
	_rebuild()


# ============================================================
# 重建几何
# ============================================================
func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_laser_beam = null
	_laser_mat = null
	_gate_frame = null
	_pick_body = null
	_trigger_area = null
	_trigger_shape_node = null

	# ---------- 1. 门框 (两根金属柱, 标记激光最大行程) ----------
	# 门框只是装饰, 让玩家肉眼看见"激光在这两点之间扫"
	_gate_frame = Node3D.new()
	_gate_frame.name = "GateFrame"
	add_child(_gate_frame)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_gate_frame.owner = get_tree().edited_scene_root
	var frame_thick: float = 0.4
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.3, 0.3, 0.35, 1.0)
	frame_mat.metallic = 0.8
	frame_mat.roughness = 0.4
	# 门框沿 X 方向铺两根 (在激光宽度两端). 高度=激光高度+amp*2 让玩家看到完整行程
	for side in [-1.0, 1.0]:
		var col := MeshInstance3D.new()
		var col_mesh := BoxMesh.new()
		# 左右扫: 门框是水平的两条 (上下); 上下扫: 门框是垂直的两条 (左右)
		if sweep_axis == 0:  # 上下扫 → 门框是左右两条垂直柱子
			col_mesh.size = Vector3(frame_thick, laser_height + sweep_amplitude * 2.0, frame_thick)
			col.position = Vector3(side * (laser_width * 0.5 + frame_thick * 0.5),
				(laser_height + sweep_amplitude * 2.0) * 0.5, 0.0)
		else:  # 左右扫 → 门框是上下两条水平柱子
			col_mesh.size = Vector3(laser_width + sweep_amplitude * 2.0, frame_thick, frame_thick)
			col.position = Vector3(0.0, laser_height * 0.5 + side * (laser_height * 0.5 + frame_thick * 0.5), 0.0)
		col.mesh = col_mesh
		col.material_override = frame_mat
		_gate_frame.add_child(col)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			col.owner = get_tree().edited_scene_root

	# ---------- 2. 激光面 (红色发光薄板) ----------
	_laser_beam = MeshInstance3D.new()
	_laser_beam.name = "LaserBeam"
	var bm := BoxMesh.new()
	# 激光视觉厚度比触发盒薄, 看起来像一条线
	bm.size = Vector3(laser_width, laser_height, 0.2)
	_laser_beam.mesh = bm
	# 初始位置: y = laser_height/2 (底部贴地), 由 _process 每帧根据 sweep_phase 设
	_laser_beam.position = Vector3(0.0, laser_height * 0.5, 0.0)
	_laser_mat = StandardMaterial3D.new()
	_laser_mat.albedo_color = Color(laser_color_r, laser_color_g, laser_color_b, 0.7)
	_laser_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_laser_mat.emission_enabled = true
	_laser_mat.emission = Color(laser_color_r, laser_color_g, laser_color_b)
	_laser_mat.emission_energy_multiplier = laser_emission
	_laser_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_laser_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_laser_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD  # 激光加色混合更刺眼
	_laser_beam.material_override = _laser_mat
	add_child(_laser_beam)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_laser_beam.owner = get_tree().edited_scene_root

	# ---------- 3. 编辑器选中盒 ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	_pick_body.position = Vector3(0.0, laser_height * 0.5 + sweep_amplitude * 0.5, 0.0)
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	# 选中盒覆盖整个扫动行程
	if sweep_axis == 0:
		pbox.size = Vector3(laser_width + 0.2, laser_height + sweep_amplitude * 2.0 + 0.2, laser_thickness + 0.2)
	else:
		pbox.size = Vector3(laser_width + sweep_amplitude * 2.0 + 0.2, laser_height + 0.2, laser_thickness + 0.2)
	pick_shape.shape = pbox
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 4. 触发 Area3D (跟随激光面运动) ----------
	_trigger_area = Area3D.new()
	_trigger_area.name = "Trigger"
	_trigger_area.monitoring = false
	_trigger_area.monitorable = false
	add_child(_trigger_area)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_trigger_area.owner = get_tree().edited_scene_root
	_trigger_shape_node = CollisionShape3D.new()
	_trigger_shape_node.name = "TriggerShape"
	var tbox := BoxShape3D.new()
	# 触发盒比视觉略厚, 让玩家不会"刚好擦边"逃过判定
	tbox.size = Vector3(laser_width, laser_height, laser_thickness)
	_trigger_shape_node.shape = tbox
	_trigger_shape_node.position = Vector3(0.0, laser_height * 0.5, 0.0)
	_trigger_area.add_child(_trigger_shape_node)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_trigger_shape_node.owner = get_tree().edited_scene_root

	# ---------- 5. 仅运行时: 激活触发器 ----------
	if not Engine.is_editor_hint():
		_runtime_init_trigger()


func _runtime_init_trigger() -> void:
	if _trigger_area == null:
		return
	_trigger_area.monitoring = true
	_trigger_area.monitorable = false
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2  # 探测车
	if not _trigger_area.body_entered.is_connected(_on_car_entered):
		_trigger_area.body_entered.connect(_on_car_entered)
	print("[Block_LaserGate] 激光闸门已激活: amp=%.1f period=%.1fs axis=%d" % [sweep_amplitude, sweep_period, sweep_axis])


# ============================================================
# 每帧更新激光位置 (运行时和编辑器都执行让所见即所得)
# ============================================================
func _process(delta: float) -> void:
	# 编辑器里也让激光"演示扫动" 让玩家在编辑器里就能看到效果
	_time_elapsed += delta
	# 数学:
	#   t = (_time_elapsed / sweep_period + sweep_phase) mod 1
	#   y = sin(2π × t) × sweep_amplitude
	# sin 自带"中心-极大-中心-极小-中心"循环, 完美模拟激光来回扫
	if sweep_period < 0.001:
		return
	var t: float = fmod(_time_elapsed / sweep_period + sweep_phase, 1.0)
	var offset: float = sin(t * TAU) * sweep_amplitude
	# 应用到激光面 + 触发盒
	var base_pos := Vector3(0.0, laser_height * 0.5, 0.0)
	if sweep_axis == 0:
		# 上下扫: 沿 Y 移动
		base_pos.y += offset
	else:
		# 左右扫: 沿 X 移动
		base_pos.x += offset
	if _laser_beam:
		_laser_beam.position = base_pos
	if _trigger_shape_node:
		_trigger_shape_node.position = base_pos


# ============================================================
# 命中处理
# ============================================================
func _on_car_entered(body: Node) -> void:
	if not body.has_method("apply_laser_hit"):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = body.get_instance_id()
	if _recent_triggered.has(key) and float(_recent_triggered[key]) > now:
		return
	_recent_triggered[key] = now + retrigger_cooldown
	body.apply_laser_hit(hit_impulse, hit_slow_factor, hit_shake)


# ============================================================
func reset_state() -> void:
	## 按 B 复位时重置激光闸门周期 (从头开始)
	_time_elapsed = 0.0


# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "laser_width",         "label": "激光宽度 (X, m)",  "min": 1.0, "max": 60.0, "step": 0.5,  "value": laser_width},
		{"key": "laser_height",        "label": "激光高度 (Y, m)",  "min": 0.5, "max": 30.0, "step": 0.5,  "value": laser_height},
		{"key": "laser_thickness",     "label": "触发厚度 (Z, m)",  "min": 0.1, "max": 5.0,  "step": 0.1,  "value": laser_thickness},
		{"key": "sweep_axis",          "label": "扫动轴 0=Y 1=X",   "min": 0.0, "max": 1.0,  "step": 1.0,  "value": float(sweep_axis)},
		{"key": "sweep_amplitude",     "label": "扫动振幅 (m)",     "min": 0.0, "max": 30.0, "step": 0.5,  "value": sweep_amplitude},
		{"key": "sweep_period",        "label": "扫动周期 (s)",     "min": 0.3, "max": 10.0, "step": 0.1,  "value": sweep_period},
		{"key": "sweep_phase",         "label": "相位偏移 (0~1)",   "min": 0.0, "max": 1.0,  "step": 0.05, "value": sweep_phase},
		{"key": "hit_impulse",         "label": "命中反推冲量",     "min": 0.0, "max": 50.0, "step": 1.0,  "value": hit_impulse},
		{"key": "hit_slow_factor",     "label": "命中速度比",       "min": 0.0, "max": 1.0,  "step": 0.05, "value": hit_slow_factor},
		{"key": "hit_shake",           "label": "命中震屏",         "min": 0.0, "max": 3.0,  "step": 0.05, "value": hit_shake},
		{"key": "retrigger_cooldown",  "label": "重触发冷却 (s)",   "min": 0.1, "max": 5.0,  "step": 0.1,  "value": retrigger_cooldown},
		{"key": "laser_color_r",       "label": "激光 R",           "min": 0.0, "max": 1.0,  "step": 0.05, "value": laser_color_r},
		{"key": "laser_color_g",       "label": "激光 G",           "min": 0.0, "max": 1.0,  "step": 0.05, "value": laser_color_g},
		{"key": "laser_color_b",       "label": "激光 B",           "min": 0.0, "max": 1.0,  "step": 0.05, "value": laser_color_b},
		{"key": "laser_emission",      "label": "激光发光强度",     "min": 0.0, "max": 20.0, "step": 0.2,  "value": laser_emission},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"laser_width":         laser_width = value
		"laser_height":        laser_height = value
		"laser_thickness":     laser_thickness = value
		"sweep_axis":          sweep_axis = int(value)
		"sweep_amplitude":     sweep_amplitude = value
		"sweep_period":        sweep_period = value
		"sweep_phase":         sweep_phase = value
		"hit_impulse":         hit_impulse = value
		"hit_slow_factor":     hit_slow_factor = value
		"hit_shake":           hit_shake = value
		"retrigger_cooldown":  retrigger_cooldown = value
		"laser_color_r":       laser_color_r = value
		"laser_color_g":       laser_color_g = value
		"laser_color_b":       laser_color_b = value
		"laser_emission":      laser_emission = value
