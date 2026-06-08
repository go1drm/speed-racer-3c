@tool
extends Node3D
## ============================================================
## 毒图机关 - 毒雾区 (ToxicFog)
## ============================================================
## 一片半透明绿色雾状区域. 玩家车进入后:
##   持续给 car._toxic_extra_damping 设置一个 > 0 的值
##   _apply_friction 里会基于这个值给 linear_velocity 一个独立阻尼
##   离开毒雾区瞬间 set 回 0 (停止减速)
##
## 玩法价值:
##   · 毒雾不能"瞬间"扣速, 是持续性减速 → 玩家必须用氮气/小喷顶过去
##   · 配合"窄路 + 毒雾", 强迫玩家精准控制
##   · 多个毒雾区域可以串联, 形成"毒雾走廊"
##
## 子节点结构 (rebuild 后):
##   FogVolume (MeshInstance3D)      — 半透明绿色立方体 (代表雾区边界)
##   FogParticles (GPUParticles3D)   — 区域内的飘动绿粒子 (营造雾感)
##   PickBody (StaticBody3D)         — 编辑器选中盒
##   FogArea (Area3D)                — 触发区, body_entered 进入 + body_exited 离开
##
## 跟踪设计:
##   _cars_in_fog: Set[int] (instance_id) 表示当前有哪些车在雾区里
##   每物理帧给所有这些车 set("_toxic_extra_damping", damping_strength)
##   body_exited 时移出 set 并把 damping 归 0
##   这种"持续 set"的方式比单次触发更稳, 即使多个雾区重叠也能正确处理 (取最强的)
## ============================================================

# ============================================================
# 几何参数
# ============================================================
## 雾区宽度 (X, 米). 默认 12, 整段路宽
@export var fog_width: float = 12.0:
	set(v):
		fog_width = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()
## 雾区长度 (Z, 米). 默认 15, 让玩家"穿过"一段时间
@export var fog_length: float = 15.0:
	set(v):
		fog_length = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()
## 雾区高度 (Y, 米). 默认 6, 覆盖大部分跳跃高度
@export var fog_height: float = 6.0:
	set(v):
		fog_height = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			_rebuild()

# ============================================================
# 减速参数 (写到 car._toxic_extra_damping)
# ============================================================
## 阻尼强度 (1/s). 越大减速越猛
## 数学: linear_velocity *= exp(-damping × dt) 每秒, 即 1.0 → 1秒衰减到 36.8%
## 推荐: 0.5 = 温和, 1.0 = 中等, 2.0 = 强 (顶速直接腰斩)
@export var damping_strength: float = 1.2:
	set(v): damping_strength = clampf(v, 0.001, 100000.0)

# ============================================================
# 视觉参数
# ============================================================
## 雾区颜色 (默认绿色)
@export var fog_color_r: float = 0.3:
	set(v): fog_color_r = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
@export var fog_color_g: float = 0.85:
	set(v): fog_color_g = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
@export var fog_color_b: float = 0.25:
	set(v): fog_color_b = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
## 雾区可见度 (0=完全透明仅粒子, 1=不透明)
@export var fog_alpha: float = 0.18:
	set(v): fog_alpha = clampf(v, 0.0, 1.0); if is_inside_tree(): _rebuild()
## 雾粒子数量
@export var particle_count: int = 60:
	set(v): particle_count = clampi(v, 0, 300); if is_inside_tree(): _rebuild()

# ============================================================
# 内部节点引用
# ============================================================
var _fog_volume: MeshInstance3D = null
var _fog_particles: GPUParticles3D = null
var _pick_body: StaticBody3D = null
var _fog_area: Area3D = null

# 当前在雾区里的车: { car_instance_id: car_node }
var _cars_in_fog: Dictionary = {}


func _ready() -> void:
	_rebuild()
	# 必须每物理帧推送 damping 到车上 (因为车每帧都会重置 _toxic_extra_damping=0 吗? 没有,
	# 但保险起见持续 set, 这样多个雾区重叠时取"最后一个 set"的值)
	# 注意: 我们让 _process 而不是 _physics_process, 因为 damping 不需要那么精确, 节省性能
	# 编辑器里也跑没关系, _cars_in_fog 是空的, 没有副作用
	set_process(true)


# ============================================================
# 重建几何
# ============================================================
func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_fog_volume = null
	_fog_particles = null
	_pick_body = null
	_fog_area = null
	_cars_in_fog.clear()

	var hh: float = fog_height * 0.5

	# ---------- 1. 雾区视觉 (半透明绿色立方体) ----------
	_fog_volume = MeshInstance3D.new()
	_fog_volume.name = "FogVolume"
	var bm := BoxMesh.new()
	bm.size = Vector3(fog_width, fog_height, fog_length)
	_fog_volume.mesh = bm
	_fog_volume.position = Vector3(0.0, hh, 0.0)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(fog_color_r, fog_color_g, fog_color_b, fog_alpha)
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.emission_enabled = true
	fmat.emission = Color(fog_color_r, fog_color_g, fog_color_b)
	fmat.emission_energy_multiplier = 0.4
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 加色混合让雾透出去内部物体仍可见 (经典毒雾效果)
	fmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_fog_volume.material_override = fmat
	add_child(_fog_volume)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_fog_volume.owner = get_tree().edited_scene_root

	# ---------- 2. 雾粒子 (在雾区内随机飘动) ----------
	if particle_count > 0:
		_fog_particles = GPUParticles3D.new()
		_fog_particles.name = "FogParticles"
		_fog_particles.amount = particle_count
		_fog_particles.lifetime = 4.0
		_fog_particles.emitting = true
		_fog_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fog_particles.position = Vector3(0.0, hh, 0.0)
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 1.0
		sm.radial_segments = 6
		sm.rings = 3
		_fog_particles.draw_pass_1 = sm
		var pmat := StandardMaterial3D.new()
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pmat.albedo_color = Color(fog_color_r, fog_color_g, fog_color_b, 0.5)
		pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pmat.emission_enabled = true
		pmat.emission = Color(fog_color_r, fog_color_g, fog_color_b)
		pmat.emission_energy_multiplier = 1.5
		pmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		_fog_particles.material_override = pmat
		var proc := ParticleProcessMaterial.new()
		proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		proc.emission_box_extents = Vector3(fog_width * 0.5, fog_height * 0.5, fog_length * 0.5)
		proc.direction = Vector3(0, 0.3, 0)
		proc.spread = 180.0
		proc.initial_velocity_min = 0.5
		proc.initial_velocity_max = 1.5
		proc.gravity = Vector3(0, 0.1, 0)
		proc.scale_min = 0.6
		proc.scale_max = 1.4
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

	# ---------- 3. 编辑器选中盒 ----------
	_pick_body = StaticBody3D.new()
	_pick_body.name = "PickBody"
	_pick_body.collision_layer = 1 << 5
	_pick_body.collision_mask = 0
	_pick_body.position = Vector3(0.0, hh, 0.0)
	var pick_shape := CollisionShape3D.new()
	pick_shape.name = "PickShape"
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(fog_width + 0.2, fog_height + 0.2, fog_length + 0.2)
	pick_shape.shape = pbox
	_pick_body.add_child(pick_shape)
	add_child(_pick_body)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_pick_body.owner = get_tree().edited_scene_root
		pick_shape.owner = get_tree().edited_scene_root

	# ---------- 4. 雾触发 Area3D ----------
	_fog_area = Area3D.new()
	_fog_area.name = "FogArea"
	_fog_area.monitoring = false
	_fog_area.monitorable = false
	_fog_area.position = Vector3(0.0, hh, 0.0)
	add_child(_fog_area)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		_fog_area.owner = get_tree().edited_scene_root
	var fog_shape := CollisionShape3D.new()
	fog_shape.name = "FogShape"
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(fog_width, fog_height, fog_length)
	fog_shape.shape = fbox
	_fog_area.add_child(fog_shape)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		fog_shape.owner = get_tree().edited_scene_root

	# ---------- 5. 仅运行时: 激活触发器 ----------
	if not Engine.is_editor_hint():
		_runtime_init_trigger()


func _runtime_init_trigger() -> void:
	if _fog_area == null:
		return
	_fog_area.monitoring = true
	_fog_area.monitorable = false
	_fog_area.collision_layer = 0
	_fog_area.collision_mask = 2  # 探测车
	if not _fog_area.body_entered.is_connected(_on_car_entered):
		_fog_area.body_entered.connect(_on_car_entered)
	if not _fog_area.body_exited.is_connected(_on_car_exited):
		_fog_area.body_exited.connect(_on_car_exited)
	print("[Block_ToxicFog] 毒雾区已激活: damping=%.2f size=%.0f×%.0f×%.0f"
		% [damping_strength, fog_width, fog_height, fog_length])


# ============================================================
# 进/出毒雾区
# ============================================================
func _on_car_entered(body: Node) -> void:
	# 必须是有 _toxic_extra_damping 字段的 RigidBody3D (= 我们的 car)
	if not (body is RigidBody3D):
		return
	if not "_toxic_extra_damping" in body:
		return
	_cars_in_fog[body.get_instance_id()] = body
	print("[Block_ToxicFog] 车 %s 进入毒雾区" % body.name)


func _on_car_exited(body: Node) -> void:
	if not (body is RigidBody3D):
		return
	var key: int = body.get_instance_id()
	if _cars_in_fog.has(key):
		_cars_in_fog.erase(key)
		# 离开毒雾时把车的 damping 立即归 0
		# 注意: 如果车同时在另一个雾区里, 那个雾区的 _process 会再次 set, 不会有副作用
		if "_toxic_extra_damping" in body:
			body.set("_toxic_extra_damping", 0.0)
		print("[Block_ToxicFog] 车 %s 离开毒雾区" % body.name)


# ============================================================
# 每帧把 damping 持续 set 到所有"在雾区内"的车上
# ============================================================
# 用 _process 而不是 _physics_process, damping 不需要 60Hz 那么精确
func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _cars_in_fog.is_empty():
		return
	# 遍历所有在雾区内的车, 持续 set damping
	# 用 keys() 拿快照防止"在 erase 时 iterate"导致问题
	var keys: Array = _cars_in_fog.keys()
	for key in keys:
		var car: Node = _cars_in_fog.get(key)
		if not is_instance_valid(car):
			_cars_in_fog.erase(key)
			continue
		if "_toxic_extra_damping" in car:
			# 取 max 让"多雾区重叠"时用最强值, 而不是后写覆盖前写
			var cur: float = float(car.get("_toxic_extra_damping"))
			car.set("_toxic_extra_damping", maxf(cur, damping_strength))


# ============================================================
# 编辑器接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "fog_width",        "label": "宽度 (X, m)",      "min": 1.0, "max": 100.0,"step": 0.5,  "value": fog_width},
		{"key": "fog_length",       "label": "长度 (Z, m)",      "min": 1.0, "max": 100.0,"step": 0.5,  "value": fog_length},
		{"key": "fog_height",       "label": "高度 (Y, m)",      "min": 0.5, "max": 30.0, "step": 0.5,  "value": fog_height},
		{"key": "damping_strength", "label": "阻尼强度 (1/s)",   "min": 0.0, "max": 10.0, "step": 0.1,  "value": damping_strength},
		{"key": "fog_alpha",        "label": "雾不透明度",       "min": 0.0, "max": 1.0,  "step": 0.02, "value": fog_alpha},
		{"key": "particle_count",   "label": "粒子数量",         "min": 0.0, "max": 300.0,"step": 5.0,  "value": float(particle_count)},
		{"key": "fog_color_r",      "label": "雾色 R",           "min": 0.0, "max": 1.0,  "step": 0.05, "value": fog_color_r},
		{"key": "fog_color_g",      "label": "雾色 G",           "min": 0.0, "max": 1.0,  "step": 0.05, "value": fog_color_g},
		{"key": "fog_color_b",      "label": "雾色 B",           "min": 0.0, "max": 1.0,  "step": 0.05, "value": fog_color_b},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"fog_width":        fog_width = value
		"fog_length":       fog_length = value
		"fog_height":       fog_height = value
		"damping_strength": damping_strength = value
		"fog_alpha":        fog_alpha = value
		"particle_count":   particle_count = int(value)
		"fog_color_r":      fog_color_r = value
		"fog_color_g":      fog_color_g = value
		"fog_color_b":      fog_color_b = value
