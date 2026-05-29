extends Node3D
## ============================================================
##  漂移视觉总管：轮胎发光 + 火焰附着 + 连续胎印
##  胎印实现：ImmediateMesh 的连续 trail 带, 不是离散方块
## ============================================================

# ---------------- 胎印 ----------------
@export_group("Tire Marks")
@export var permanent_marks: bool = true            ## 永久胎印
@export var tire_mark_lifetime: float = 6.0         ## 非永久寿命
@export var tire_mark_width: float = 0.25            ## 胎印宽度(米)
@export var tire_mark_alpha: float = 0.55            ## 胎印不透明度 (0~1, 越低越淡)
@export var tire_mark_color: Color = Color(0.05, 0.04, 0.04)
@export var tire_mark_only_rear: bool = true        ## 仅后轮
@export var tire_mark_min_segment: float = 0.1     ## 两个采样点最小间距(米),避免静止抖动
@export var tire_mark_max_points_per_trail: int = 2000  ## 单条 trail 最多顶点数

# ---------------- 轮胎发光 ----------------
@export_group("Wheel Glow")
@export var glow_color: Color = Color(1.0, 0.35, 0.1)
@export var glow_energy: float = 6.0

# ---------------- 内部 ----------------
var _car_body: RigidBody3D = null
var _car_mesh: Node3D = null
var _wheels: Array[Node3D] = []
var _wheel_orig_mats: Array = []
var _glow_mat_cache: Array = []

# 火焰粒子
var _flames: Array[GPUParticles3D] = []

# 胎印 trail：每个产生胎印的轮子对应一条 trail
# trail = { mesh_inst: MeshInstance3D, im: ImmediateMesh, mat: StandardMaterial3D,
#           last_pos: Vector3, last_normal: Vector3, points: Array[{pos,normal}] }
var _active_trails: Dictionary = {}   # wheel_index -> trail
var _completed_trails: Array = []     # 已结束的 trail 列表(用于淡出 / 数量管理)

# 状态
var _drifting: bool = false


func _ready() -> void:
	pass


# ============================================================
#  绑定
# ============================================================
func set_car(car: RigidBody3D) -> void:
	_car_body = car
	if not car.has_node("CarMesh"):
		push_warning("[DriftFX] 找不到 CarMesh")
		return
	_car_mesh = car.get_node("CarMesh")
	_collect_wheels()
	_create_flames_at_rear_wheels()


func _collect_wheels() -> void:
	_wheels.clear()
	_wheel_orig_mats.clear()
	_glow_mat_cache.clear()
	var wheel_paths := [
		"suv2/wheel_frontLeft",
		"suv2/wheel_frontRight",
		"suv2/wheel_backLeft",
		"suv2/wheel_backRight",
	]
	for p in wheel_paths:
		if not _car_mesh.has_node(p):
			print("[DriftFX] 找不到轮子: ", p)
			continue
		var w := _car_mesh.get_node(p) as Node3D
		_wheels.append(w)

		var mi := w as MeshInstance3D
		if mi and mi.mesh:
			var orig_mat := mi.get_active_material(0)
			_wheel_orig_mats.append(orig_mat)
			var glow := (orig_mat.duplicate() if orig_mat else StandardMaterial3D.new()) as StandardMaterial3D
			if glow:
				glow.emission_enabled = true
				glow.emission = glow_color
				glow.emission_energy_multiplier = glow_energy
			_glow_mat_cache.append(glow)
		else:
			_wheel_orig_mats.append(null)
			_glow_mat_cache.append(null)
	print("[DriftFX] 收集到 ", _wheels.size(), " 个轮子")


func _create_flames_at_rear_wheels() -> void:
	_flames.clear()
	for idx in [2, 3]:
		if idx >= _wheels.size():
			continue
		var wheel := _wheels[idx]
		if not wheel:
			continue
		var flame := _build_flame_particle()
		wheel.add_child(flame)
		flame.position = Vector3(0, 0.2, 0)
		_flames.append(flame)


func _build_flame_particle() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 60
	p.lifetime = 0.5
	p.emitting = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var sm := SphereMesh.new()
	sm.radius = 0.054
	sm.height = 0.108
	p.draw_pass_1 = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.55, 0.1, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.3, 0.05, 1.0)
	mat.emission_energy_multiplier = 8.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	p.material_override = mat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	proc.emission_sphere_radius = 0.03
	proc.direction = Vector3(0, 0.6, 1)
	proc.spread = 25.0
	proc.initial_velocity_min = 0.9
	proc.initial_velocity_max = 1.8
	proc.gravity = Vector3(0, -0.6, 0)
	proc.scale_min = 0.18
	proc.scale_max = 0.45
	proc.color = Color(1.0, 0.6, 0.15, 1)
	p.process_material = proc
	return p


# ============================================================
#  外部 API
# ============================================================
func set_drifting(on: bool) -> void:
	_drifting = on
	for f in _flames:
		if f:
			f.emitting = on
	for i in range(_wheels.size()):
		var w := _wheels[i] as MeshInstance3D
		if not w:
			continue
		if on:
			if i < _glow_mat_cache.size() and _glow_mat_cache[i]:
				w.material_override = _glow_mat_cache[i]
		else:
			w.material_override = null

	# 漂移结束: 关闭所有活跃 trail
	if not on:
		_finalize_active_trails()


func clear_all_marks() -> void:
	for t in _completed_trails:
		if is_instance_valid(t.mesh_inst):
			t.mesh_inst.queue_free()
	_completed_trails.clear()
	for k in _active_trails.keys():
		var t = _active_trails[k]
		if is_instance_valid(t.mesh_inst):
			t.mesh_inst.queue_free()
	_active_trails.clear()


# ============================================================
#  每帧采样 + 推 trail
# ============================================================
func _process(_delta: float) -> void:
	if not _drifting or not _car_body or not _car_mesh:
		return

	var indices: Array
	if tire_mark_only_rear:
		indices = [2, 3]
	else:
		indices = [0, 1, 2, 3]

	for i in indices:
		if i >= _wheels.size() or not _wheels[i]:
			continue
		_extend_trail(i, _wheels[i])


func _extend_trail(wheel_idx: int, wheel: Node3D) -> void:
	# 射线找到轮子下方地面点
	var space := get_world_3d().direct_space_state
	var wheel_pos: Vector3 = wheel.global_position
	var q := PhysicsRayQueryParameters3D.create(
		wheel_pos + Vector3(0, 1.0, 0),
		wheel_pos + Vector3(0, -3.0, 0)
	)
	q.exclude = [_car_body.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		# 离地了, 结束这条 trail
		if _active_trails.has(wheel_idx):
			_finish_trail(wheel_idx)
		return

	var ground_pos: Vector3 = hit.position + Vector3(0, 0.05, 0)
	var ground_normal: Vector3 = hit.normal

	# 拿到/新建该轮子的 trail
	if not _active_trails.has(wheel_idx):
		_start_new_trail(wheel_idx, ground_pos, ground_normal)
		return

	var trail = _active_trails[wheel_idx]
	# 距离上一个采样点足够远才追加 (避免静止时 mesh 退化)
	if ground_pos.distance_to(trail.last_pos) < tire_mark_min_segment:
		return

	trail.points.append({"pos": ground_pos, "normal": ground_normal})
	trail.last_pos = ground_pos
	trail.last_normal = ground_normal

	# 顶点数过多, 切段(开新 trail)
	if trail.points.size() >= tire_mark_max_points_per_trail:
		_finish_trail(wheel_idx)
		_start_new_trail(wheel_idx, ground_pos, ground_normal)
		return

	_rebuild_trail_mesh(trail)


func _start_new_trail(wheel_idx: int, pos: Vector3, normal: Vector3) -> void:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(tire_mark_color.r, tire_mark_color.g, tire_mark_color.b, tire_mark_alpha)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 1
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(mi)

	_active_trails[wheel_idx] = {
		"mesh_inst": mi,
		"im": im,
		"mat": mat,
		"last_pos": pos,
		"last_normal": normal,
		"points": [{"pos": pos, "normal": normal}],
	}


func _rebuild_trail_mesh(trail) -> void:
	var im: ImmediateMesh = trail.im
	var pts: Array = trail.points
	if pts.size() < 2:
		return

	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)

	var half_w: float = tire_mark_width * 0.5
	for i in range(pts.size()):
		var p: Vector3 = pts[i].pos
		var n: Vector3 = pts[i].normal
		# tangent (前进方向): 用相邻点之差
		var tangent: Vector3
		if i == 0:
			tangent = (pts[i + 1].pos - p)
		elif i == pts.size() - 1:
			tangent = (p - pts[i - 1].pos)
		else:
			tangent = (pts[i + 1].pos - pts[i - 1].pos)
		tangent = tangent.normalized()
		# 横向方向 = normal × tangent (沿地面横切)
		var side: Vector3 = n.cross(tangent).normalized()

		var left: Vector3 = p - side * half_w
		var right: Vector3 = p + side * half_w
		# triangle strip: 交替推 left 和 right
		im.surface_add_vertex(left)
		im.surface_add_vertex(right)

	im.surface_end()


func _finish_trail(wheel_idx: int) -> void:
	if not _active_trails.has(wheel_idx):
		return
	var trail = _active_trails[wheel_idx]
	_active_trails.erase(wheel_idx)
	if not permanent_marks:
		trail["age"] = 0.0
	_completed_trails.append(trail)


func _finalize_active_trails() -> void:
	for k in _active_trails.keys():
		_finish_trail(k)


# 非永久模式才需要淡出; 这里简化暂不实现淡出, 永久模式下 _completed_trails 一直保留
