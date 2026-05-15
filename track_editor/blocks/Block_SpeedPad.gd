@tool
extends Node3D
## ============================================================
## 加速带 (Speed Pad) — 编辑器机关
## ============================================================
## 这是"机关"类的第一个成员: 一个铺在地面上的彩色矩形面片
## 车 (RigidBody3D) 撞到面片时给一次"沿车头方向的瞬时增速 + 短暂持续推力"
##
## 设计修订记录:
## ============================================================
## 子节点结构 (rebuild 后):
##   Vis (MeshInstance3D)            — 彩色发光矩形面片 (顶面可见, 微微悬浮 3cm 防 z-fighting)
##   PickBody (StaticBody3D)         — 编辑器选中盒, 让鼠标 raycast 能命中加速带选中
##     PickShape (CollisionShape3D)  — BoxShape3D, 跟视觉面片同尺寸但抬高一点便于点中
##   Trigger (Area3D)                — 运行时触发盒, _ready_runtime 里手动激活 monitoring + 接信号
##     TriggerShape (CollisionShape3D) — BoxShape3D, 触发范围 = width × thickness × length
## ============================================================
## 修复点 (用户反馈):
## ============================================================
## ❌ Bug1 旧版: 只有 Area3D 没有 StaticBody → _pick_placed_block_at_mouse 选不中
##    ✅ 新版: 加 PickBody (StaticBody3D + BoxShape3D) 用于 raycast 命中. layer/mask 走默认 1,
##       与 _pick_placed_block_at_mouse 的 intersect_ray 兼容. 编辑器/运行时都启用 (运行时也无害,
##       因为车的 mask 不包含 layer 1, 不会和它做物理碰撞, 只参与 ray query)
##
## ❌ Bug2 旧版: 运行时调 _trigger_area.set_script(SpeedPad.gd) 后, _ready 不会再触发
##    (因为 Area 已经在 SceneTree 里了, _ready 是 enter_tree 才触发的). 导致 monitoring 没开,
##    body_entered 也没接信号 → 车撞过去毫无反应.
##    ✅ 新版: 不再用 set_script 这种取巧方式. Block_SpeedPad 自己实现"运行时初始化":
##       _runtime_init_trigger() 在非 @tool 模式下手动:
##         1) monitoring=true, monitorable=false
##         2) collision_mask=2 (匹配 car.collision_layer=2)
##         3) collision_layer=0 (Area 不参与物理)
##         4) body_entered.connect(_on_car_entered)
##         5) 直接在自己脚本里实现冷却字典 + 调 car.apply_speed_pad_boost()
##       这样不依赖 SpeedPad.gd 的 _ready 时机, 100% 可靠.
##
## ============================================================
## 可编辑参数 (与积木走同一套 get_editable_params 接口):
##   width:       面片宽度 (X 方向, m)            默认 8.0
##   length:      面片长度 (Z 方向, m)            默认 5.0
##   thickness:   触发区高度 (Y 方向, m)          默认 2.5
##   speed_kick:  瞬时增速 (m/s)                  默认 20.0
##   duration:    持续推力时长 (秒)               默认 0.4
##   color_r/g/b: 面片颜色 (3 个 0~1 滑块)
##
## 序列化:
##   走 RaceTrackData.blocks 数组, id="speed_pad", params 字典存所有可编辑参数
##   TrackRunner 加载时实例化此积木 → _ready 自动 _rebuild + _runtime_init_trigger 接管触发逻辑

# ============================================================
# 几何 / 颜色
# ============================================================
@export var width: float = 8.0:
	set(v):
		width = clampf(v, 1.0, 60.0)
		if is_inside_tree():
			_rebuild()
@export var length: float = 5.0:
	set(v):
		length = clampf(v, 1.0, 60.0)
		if is_inside_tree():
			_rebuild()
## 触发区高度 (Area3D 的 box 高度, 决定车多高时还能触发)
## 注意: 视觉面片永远很薄 (0.05m), 这个只影响触发区
@export var thickness: float = 2.5:
	set(v):
		thickness = clampf(v, 0.5, 10.0)
		if is_inside_tree():
			_rebuild()

## 颜色用 3 个 0~1 float 表示, 这样能复用积木编辑器的 SpinBox 接口 (不用单独做 ColorPicker)
## 默认黄色 (高亮显眼, 跟 QQ飞车的加速带一致)
@export var color_r: float = 1.0:
	set(v):
		color_r = clampf(v, 0.0, 1.0)
		if is_inside_tree():
			_rebuild()
@export var color_g: float = 0.85:
	set(v):
		color_g = clampf(v, 0.0, 1.0)
		if is_inside_tree():
			_rebuild()
@export var color_b: float = 0.20:
	set(v):
		color_b = clampf(v, 0.0, 1.0)
		if is_inside_tree():
			_rebuild()

# ============================================================
# 行为参数 (运行时由 _on_car_entered 读取)
# ============================================================
## 瞬时增速 (m/s, 沿车头方向). 推荐 15~30
@export var speed_kick: float = 15.0:
	set(v):
		speed_kick = clampf(v, 0.0, 100.0)
## 持续推力时长 (秒). 用户要求: 加速带应该有持续加速感, 不是单纯给一次力
## 1.5 秒 = 短氮气感. 想要更持久的弹射器调到 2~3 秒
@export var duration: float = 1.5:
	set(v):
		duration = clampf(v, 0.0, 5.0)

## 触发冷却 (秒). 同一辆车在此时间内重复进入不会再次触发
@export var retrigger_cooldown: float = 0.5

# ============================================================
# 内部节点引用 (rebuild 后赋值)
# ============================================================
var _vis_mesh: MeshInstance3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null

# 运行时冷却字典: { car.get_instance_id(): cooldown_end_time }
# 用 _on_car_entered 时间戳判断, 避免重复触发
var _recent_triggered: Dictionary = {}


func _ready() -> void:
	# 编辑器场景里如果已经有手动放好的子节点, 不重建
	if get_child_count() > 0 and not Engine.is_editor_hint():
		# 运行时如果有保留的子节点 (不太可能), 仍然走 _rebuild 保证状态一致
		pass
	_rebuild()


# ============================================================
# 重建几何 + 选中盒 + 触发器
# ============================================================
# 修改 width/length/thickness/颜色 时调用 (set 里触发)
# 第一次 _ready 时也调
func _rebuild() -> void:
	# 清掉旧子节点
	for c in get_children():
		c.queue_free()
	_vis_mesh = null
	_pick_body = null
	_trigger_area = null

	# ---------- 1. 视觉面片 ----------
	_vis_mesh = MeshInstance3D.new()
	_vis_mesh.name = "Vis"
	var bm := BoxMesh.new()
	bm.size = Vector3(width, 0.05, length)
	_vis_mesh.mesh = bm
	# 抬起 0.15m 让加速带显著盖在赛道路面上 (旧值 0.03m 太薄, 被路面遮住看不见)
	# 触发盒底部不抬, 这样视觉浮在路面上但车开过去仍能命中
	_vis_mesh.position = Vector3(0.0, 0.15, 0.0)
	var mat := StandardMaterial3D.new()
	var col := Color(color_r, color_g, color_b, 0.85)
	mat.albedo_color = col
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(color_r, color_g, color_b)
	mat.emission_energy_multiplier = 1.4
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_vis_mesh.material_override = mat
	add_child(_vis_mesh)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_vis_mesh.owner = get_tree().edited_scene_root

	# ---------- 2. 编辑器选中盒 (StaticBody3D + BoxShape3D) ----------
	# 这一步是关键修复: 之前没这个节点 → ray 命中不到加速带 → 选不中
	# 选中盒尺寸 = 视觉面片 + 一点 padding (Y 给 0.5m 让玩家更容易点中)
	# layer=1 (默认), 与 ray query 兼容; 不参与物理 (车 mask 不含 1)
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	# collision_layer=1 让默认 ray query 能命中. 车 mask=1 也会和它做接触
	# 但车的 mask 实际上是 1 (即 collision_mask = 1, 默认值), 这就有问题——
	# 如果加速带 PickBody.layer=1, 车会和它做物理碰撞, 然后整辆车撞墙了!
	# 解决: 把 PickBody 的 layer 设到一个独立通道 (例如 layer 8 = 第 4 位 = mask 值 8)
	# 同时 _pick_placed_block_at_mouse 的 ray query 不指定 collision_mask, 默认 0xFFFFFFFF 全开,
	# 所以选中盒在第 4 位也能被命中. 安全又不影响物理.
	_pick_body.collision_layer = 1 << 5   # 第 6 位 (= 32), 远离车的 1/2/3 通道
	_pick_body.collision_mask = 0          # 选中盒不主动检测任何东西
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	# 选中盒 Y 给 0.6m 让鼠标更容易点中 (面片本身只有 0.05m 极薄)
	pbox.size = Vector3(width, 0.6, length)
	pick_shape.shape = pbox
	pick_shape.position = Vector3(0.0, 0.3, 0.0)
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 3. 触发 Area3D ----------
	# 编辑器里关 monitoring (避免误触), 运行时由 _runtime_init_trigger 启用
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
	tbox.size = Vector3(width, thickness, length)
	trigger_shape.shape = tbox
	trigger_shape.position = Vector3(0.0, thickness * 0.5, 0.0)
	_trigger_area.add_child(trigger_shape)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		trigger_shape.owner = get_tree().edited_scene_root

	# ---------- 4. 仅运行时: 激活触发器 ----------
	# 修复点: 不再用 set_script(SpeedPad.gd) — 那种方式 _ready 不会触发.
	# 直接在本脚本里手动初始化 + 接信号. 这样 100% 可靠, 不依赖时机.
	if not Engine.is_editor_hint():
		_runtime_init_trigger()


# ============================================================
# 运行时触发器初始化 (非 @tool 模式才走这里)
# ============================================================
# 在 _rebuild 末尾被调, 此时 _trigger_area 已经在 SceneTree 里
# 必做的几件事:
#   1) monitoring=true (Area3D 默认 false, 不开就收不到 body_entered)
#   2) collision_mask=2 (匹配 car.tscn 里 car 的 collision_layer=2)
#      注意 car.collision_layer 不是默认 1 而是 2, 这是个老坑
#   3) collision_layer=0 (Area 自己不参与物理)
#   4) 接 body_entered → _on_car_entered
func _runtime_init_trigger() -> void:
	if _trigger_area == null:
		return
	_trigger_area.monitoring = true
	_trigger_area.monitorable = false
	_trigger_area.collision_layer = 0   # Area 不主动占 layer
	_trigger_area.collision_mask = 2    # 探测 layer=2 的车
	# 接信号 (避免重复连接)
	if not _trigger_area.body_entered.is_connected(_on_car_entered):
		_trigger_area.body_entered.connect(_on_car_entered)
	print("[Block_SpeedPad] 运行时触发器已激活: kick=%.1f dur=%.2f" % [speed_kick, duration])


# ============================================================
# 触发: 车进入 → 调 car.apply_speed_pad_boost
# ============================================================
func _on_car_entered(body: Node) -> void:
	# 只处理有 apply_speed_pad_boost 方法的 body (= car)
	if not body.has_method("apply_speed_pad_boost"):
		return
	# 冷却检查: 同一辆车 retrigger_cooldown 秒内不重复触发
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = body.get_instance_id()
	if _recent_triggered.has(key) and float(_recent_triggered[key]) > now:
		return
	_recent_triggered[key] = now + retrigger_cooldown
	body.apply_speed_pad_boost(speed_kick, duration, "addspeed")
	print("[Block_SpeedPad] 触发! kick=%.1f dur=%.2f" % [speed_kick, duration])


# ============================================================
# 编辑器接口 (供 TrackEditor 选中面板用)
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "width",      "label": "宽度 (m, X)",     "min": 1.0,  "max": 60.0,  "step": 0.5,  "value": width},
		{"key": "length",     "label": "长度 (m, Z)",     "min": 1.0,  "max": 60.0,  "step": 0.5,  "value": length},
		{"key": "thickness",  "label": "触发高 (m, Y)",   "min": 0.5,  "max": 10.0,  "step": 0.5,  "value": thickness},
		{"key": "speed_kick", "label": "瞬时增速 (m/s)",  "min": 0.0,  "max": 100.0, "step": 1.0,  "value": speed_kick},
		{"key": "duration",   "label": "持续推力 (秒)",   "min": 0.0,  "max": 5.0,   "step": 0.1,  "value": duration},
		{"key": "color_r",    "label": "颜色 R",          "min": 0.0,  "max": 1.0,   "step": 0.05, "value": color_r},
		{"key": "color_g",    "label": "颜色 G",          "min": 0.0,  "max": 1.0,   "step": 0.05, "value": color_g},
		{"key": "color_b",    "label": "颜色 B",          "min": 0.0,  "max": 1.0,   "step": 0.05, "value": color_b},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"width":      width = value
		"length":     length = value
		"thickness":  thickness = value
		"speed_kick": speed_kick = value
		"duration":   duration = value
		"color_r":    color_r = value
		"color_g":    color_g = value
		"color_b":    color_b = value
