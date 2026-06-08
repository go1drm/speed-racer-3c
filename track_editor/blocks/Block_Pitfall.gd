@tool
extends Node3D
## ============================================================
## 毒图机关 - 毒坑 (Pitfall) 
## ============================================================
## 一片"看着就想绕开"的死亡区. 玩家车进入触发区域:
##   1) 立刻调 car.respawn_to_spawn() 把车送回出生点
##   2) 自身震屏 + 锁定一个 retrigger 冷却防止反复触发
##
## 视觉:
##   · 一个红黑相间警示图案的下沉式凹槽 (薄板, 顶面贴在 Y=0 略低 0.3m, 强调"坑")
##   · 凹槽外圈一圈黄黑警示线
##   · 上方持续往上飘"绿色毒雾粒子"提示玩家这是危险区
##
## 子节点结构 (rebuild 后):
##   PitVis  (MeshInstance3D)        — 凹槽底面 (黑红方块网格警示)
##   WarnRing (MeshInstance3D)       — 黄黑警示边
##   FogParticles (GPUParticles3D)   — 上方毒雾粒子
##   PickBody (StaticBody3D)         — 编辑器选中盒
##   Trigger (Area3D)                — 触发区, 进入即复位
##
## 注: 这是真正的"坑", 没有路面也没有墙, 玩家如果落下去会触发复位
##     与赛道现有的"无底空洞"+ Y<kill_y 不同, 这个机关单独可放在任何路面上
## ============================================================

# ============================================================
# 几何参数
# ============================================================
## 毒坑宽度 (X, 米). 默认 8 = 大部分赛道宽度的 1/3
@export var pit_width: float = 8.0:
	set(v):
		pit_width = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()
## 毒坑长度 (Z, 米). 默认 6, 短到玩家可以勉强跳过去
@export var pit_length: float = 6.0:
	set(v):
		pit_length = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()
## 触发区高度 (Y, 米). 车进入这个 Y 范围才算掉坑
## 设大一点 (默认 4m) 让飞过头的车也会触发, 避免 "贴着地面飞过去就免疫" 的 bug
@export var trigger_height: float = 4.0:
	set(v):
		trigger_height = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()
## 触发后冷却 (秒). 防止 1 帧多次触发 (复位完物理还没让车离开就又触发)
@export var retrigger_cooldown: float = 1.5

# ============================================================
# 视觉参数
# ============================================================
## 凹槽颜色 (默认偏黑红, 警示)
@export var pit_color_r: float = 0.15:
	set(v): pit_color_r = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
@export var pit_color_g: float = 0.05:
	set(v): pit_color_g = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
@export var pit_color_b: float = 0.05:
	set(v): pit_color_b = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()

## 毒雾粒子数量 (越多越浓)
@export var fog_count: int = 30:
	set(v): fog_count = clampi(v, 0, 200); if is_inside_tree(): _rebuild()
## 毒雾上升高度 (米)
@export var fog_height: float = 3.0:
	set(v): fog_height = clampf(v, 0.001, 100000.0); if is_inside_tree(): _rebuild()
## 毒雾颜色 (默认绿色 = 经典"毒"配色)
@export var fog_color_r: float = 0.3:
	set(v): fog_color_r = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
@export var fog_color_g: float = 0.85:
	set(v): fog_color_g = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
@export var fog_color_b: float = 0.25:
	set(v): fog_color_b = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()

# ============================================================
# 内部节点引用
# ============================================================
var _pit_vis: MeshInstance3D = null
var _warn_ring: MeshInstance3D = null
var _fog_particles: GPUParticles3D = null
var _pick_body: StaticBody3D = null
var _trigger_area: Area3D = null

# 冷却字典: { car.get_instance_id(): cooldown_end_time }
var _recent_triggered: Dictionary = {}


func _ready() -> void:
	_rebuild()


# ============================================================
# 重建几何 + 视觉 + 触发器
# ============================================================
func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_pit_vis = null
	_warn_ring = null
	_fog_particles = null
	_pick_body = null
	_trigger_area = null

	var hw: float = pit_width * 0.5
	var hl: float = pit_length * 0.5

	# ---------- 1. 凹槽底面 (深色薄板, 在路面下 0.3m 营造"坑"感) ----------
	_pit_vis = MeshInstance3D.new()
	_pit_vis.name = "PitVis"
	var bm := BoxMesh.new()
	bm.size = Vector3(pit_width, 0.05, pit_length)
	_pit_vis.mesh = bm
	_pit_vis.position = Vector3(0.0, -0.3, 0.0)  # 沉下 0.3m 看着像凹槽
	var pit_mat := StandardMaterial3D.new()
	pit_mat.albedo_color = Color(pit_color_r, pit_color_g, pit_color_b, 1.0)
	pit_mat.emission_enabled = true
	# 红色微发光让暗处也明显
	pit_mat.emission = Color(0.5, 0.05, 0.05)
	pit_mat.emission_energy_multiplier = 0.3
	pit_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_pit_vis.material_override = pit_mat
	add_child(_pit_vis)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pit_vis.owner = get_tree().edited_scene_root

	# ---------- 2. 警示边框 (黄黑相间环) ----------
	# 实现: 用 4 条细长 BoxMesh 围成一圈
	_warn_ring = MeshInstance3D.new()
	_warn_ring.name = "WarnRing"
	add_child(_warn_ring)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_warn_ring.owner = get_tree().edited_scene_root
	var ring_thick: float = 0.4
	var ring_height: float = 0.15
	var ring_y: float = 0.05  # 略微高于路面让玩家看见
	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(1.0, 0.85, 0.1, 1.0)  # 警示黄
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(1.0, 0.85, 0.1)
	ring_mat.emission_energy_multiplier = 1.2
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# 4 边: 左/右 (沿 Z 长), 上/下 (沿 X 长)
	for side in [-1, 1]:
		# X 方向边 (沿 Z 走的两条, 在 ±hw)
		var bar_x := MeshInstance3D.new()
		var bar_x_mesh := BoxMesh.new()
		bar_x_mesh.size = Vector3(ring_thick, ring_height, pit_length + ring_thick)
		bar_x.mesh = bar_x_mesh
		bar_x.position = Vector3(side * (hw + ring_thick * 0.5), ring_y, 0.0)
		bar_x.material_override = ring_mat
		_warn_ring.add_child(bar_x)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			bar_x.owner = get_tree().edited_scene_root
		# Z 方向边 (沿 X 走的两条, 在 ±hl)
		var bar_z := MeshInstance3D.new()
		var bar_z_mesh := BoxMesh.new()
		bar_z_mesh.size = Vector3(pit_width, ring_height, ring_thick)
		bar_z.mesh = bar_z_mesh
		bar_z.position = Vector3(0.0, ring_y, side * (hl + ring_thick * 0.5))
		bar_z.material_override = ring_mat
		_warn_ring.add_child(bar_z)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			bar_z.owner = get_tree().edited_scene_root

	# ---------- 3. 毒雾粒子 (绿色, 持续上升) ----------
	if fog_count > 0:
		_fog_particles = GPUParticles3D.new()
		_fog_particles.name = "FogParticles"
		_fog_particles.amount = fog_count
		_fog_particles.lifetime = 2.5
		_fog_particles.emitting = true
		_fog_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fog_particles.position = Vector3(0.0, 0.0, 0.0)
		# 球形 mesh 当雾粒
		var sm := SphereMesh.new()
		sm.radius = 0.4
		sm.height = 0.8
		sm.radial_segments = 6
		sm.rings = 3
		_fog_particles.draw_pass_1 = sm
		# 半透明发光绿
		var fmat := StandardMaterial3D.new()
		fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fmat.albedo_color = Color(fog_color_r, fog_color_g, fog_color_b, 0.45)
		fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fmat.emission_enabled = true
		fmat.emission = Color(fog_color_r, fog_color_g, fog_color_b)
		fmat.emission_energy_multiplier = 1.0
		fmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_fog_particles.material_override = fmat
		# 处理材质: 从底面散布, 上升, 渐隐
		var proc := ParticleProcessMaterial.new()
		proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		proc.emission_box_extents = Vector3(hw * 0.9, 0.1, hl * 0.9)
		proc.direction = Vector3(0, 1, 0)
		proc.spread = 15.0
		proc.initial_velocity_min = fog_height / 2.5 * 0.7
		proc.initial_velocity_max = fog_height / 2.5 * 1.3
		proc.gravity = Vector3(0, 0.2, 0)  # 微微浮起
		proc.scale_min = 0.6
		proc.scale_max = 1.2
		# 透明度淡入淡出
		var ac := Curve.new()
		ac.add_point(Vector2(0.0, 0.0))
		ac.add_point(Vector2(0.3, 1.0))
		ac.add_point(Vector2(1.0, 0.0))
		var actex := CurveTexture.new()
		actex.curve = ac
		proc.alpha_curve = actex
		_fog_particles.process_material = proc
		add_child(_fog_particles)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			_fog_particles.owner = get_tree().edited_scene_root

	# ---------- 4. 编辑器选中盒 ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(pit_width + 0.5, 0.6, pit_length + 0.5)
	pick_shape.shape = pbox
	pick_shape.position = Vector3(0.0, 0.05, 0.0)
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 5. 触发 Area3D ----------
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
	tbox.size = Vector3(pit_width, trigger_height, pit_length)
	trigger_shape.shape = tbox
	# 触发盒中心抬高到 trigger_height/2 让它从地面到 trigger_height 米都覆盖
	trigger_shape.position = Vector3(0.0, trigger_height * 0.5, 0.0)
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
	_trigger_area.monitorable = false
	_trigger_area.collision_layer = 0
	_trigger_area.collision_mask = 2  # 探测 layer=2 的赛车
	if not _trigger_area.body_entered.is_connected(_on_car_entered):
		_trigger_area.body_entered.connect(_on_car_entered)
	print("[Block_Pitfall] 毒坑触发器已激活")


func _on_car_entered(body: Node) -> void:
	# 只处理有 respawn_to_spawn 方法的 body (= car)
	if not body.has_method("respawn_to_spawn"):
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = body.get_instance_id()
	if _recent_triggered.has(key) and float(_recent_triggered[key]) > now:
		return
	_recent_triggered[key] = now + retrigger_cooldown
	body.respawn_to_spawn()


# ============================================================
# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "pit_width",          "label": "宽度 (m, X)",     "min": 1.0, "max": 60.0, "step": 0.5,  "value": pit_width},
		{"key": "pit_length",         "label": "长度 (m, Z)",     "min": 1.0, "max": 60.0, "step": 0.5,  "value": pit_length},
		{"key": "trigger_height",     "label": "触发高 (m, Y)",   "min": 0.5, "max": 30.0, "step": 0.5,  "value": trigger_height},
		{"key": "retrigger_cooldown", "label": "复触发冷却(s)",   "min": 0.1, "max": 5.0,  "step": 0.1,  "value": retrigger_cooldown},
		{"key": "fog_count",          "label": "毒雾粒子数",      "min": 0.0, "max": 200.0,"step": 5.0,  "value": float(fog_count)},
		{"key": "fog_height",         "label": "毒雾高度 (m)",    "min": 0.5, "max": 15.0, "step": 0.5,  "value": fog_height},
		{"key": "pit_color_r",        "label": "凹槽 R",          "min": 0.0, "max": 1.0,  "step": 0.05, "value": pit_color_r},
		{"key": "pit_color_g",        "label": "凹槽 G",          "min": 0.0, "max": 1.0,  "step": 0.05, "value": pit_color_g},
		{"key": "pit_color_b",        "label": "凹槽 B",          "min": 0.0, "max": 1.0,  "step": 0.05, "value": pit_color_b},
		{"key": "fog_color_r",        "label": "毒雾 R",          "min": 0.0, "max": 1.0,  "step": 0.05, "value": fog_color_r},
		{"key": "fog_color_g",        "label": "毒雾 G",          "min": 0.0, "max": 1.0,  "step": 0.05, "value": fog_color_g},
		{"key": "fog_color_b",        "label": "毒雾 B",          "min": 0.0, "max": 1.0,  "step": 0.05, "value": fog_color_b},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"pit_width":          pit_width = value
		"pit_length":         pit_length = value
		"trigger_height":     trigger_height = value
		"retrigger_cooldown": retrigger_cooldown = value
		"fog_count":          fog_count = int(value)
		"fog_height":         fog_height = value
		"pit_color_r":        pit_color_r = value
		"pit_color_g":        pit_color_g = value
		"pit_color_b":        pit_color_b = value
		"fog_color_r":        fog_color_r = value
		"fog_color_g":        fog_color_g = value
		"fog_color_b":        fog_color_b = value
