extends Node3D
## ============================================================
##  漂移视觉总管：轮胎发光 + 火焰附着 + 永久胎印
## ============================================================

# ---------------- 胎印 ----------------
@export_group("Tire Marks")
@export var permanent_marks: bool = true            ## 永久胎印(不会淡出/不会被回收)
@export var tire_mark_lifetime: float = 6.0         ## 非永久模式下的胎印寿命
@export var tire_mark_interval: float = 0.025       ## 放置间隔(秒)
@export var tire_mark_size: Vector2 = Vector2(0.45, 0.7)
@export var tire_mark_max: int = 1500               ## 上限(防爆显存; 永久模式下也兜底)

# ---------------- 轮胎发光 ----------------
@export_group("Wheel Glow")
@export var glow_color: Color = Color(1.0, 0.35, 0.1)  ## 漂移时轮胎发光颜色
@export var glow_energy: float = 6.0                   ## 发光强度

# 由 car.gd 通过 set_car 注入
var _car_body: RigidBody3D = null
var _car_mesh: Node3D = null
var _wheels: Array[Node3D] = []     # 4 个轮子节点(MeshInstance3D)
var _wheel_orig_mats: Array = []    # 每个轮子原始材质 (备份用)
var _glow_mat_cache: Array = []     # 漂移时切换到的发光材质

# 火焰粒子（动态创建，附着在每个后轮位置）
var _flames: Array[GPUParticles3D] = []

# 状态
var _drifting: bool = false
var _timer: float = 0.0
var _marks: Array = []
var _shared_mark_mesh: QuadMesh = null
var _shared_mark_mat: StandardMaterial3D = null


func _ready() -> void:
	# 准备共享胎印资源
	_shared_mark_mesh = QuadMesh.new()
	_shared_mark_mesh.size = tire_mark_size
	_shared_mark_mat = StandardMaterial3D.new()
	_shared_mark_mat.albedo_color = Color(0.04, 0.04, 0.04, 0.92)
	_shared_mark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_shared_mark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func set_car(car: RigidBody3D) -> void:
	_car_body = car
	if not car.has_node("CarMesh"):
		push_warning("[DriftFX] 找不到 CarMesh 子节点")
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

		# 备份原材质（如果是 MeshInstance3D 才有 surface_override）
		var mi := w as MeshInstance3D
		if mi and mi.mesh:
			# 用 surface 0 的当前材质作为底
			var orig_mat := mi.get_active_material(0)
			_wheel_orig_mats.append(orig_mat)
			# 创建发光版本（基于原材质 duplicate, 加上 emission）
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
	# 在每个后轮上创建一个火焰粒子节点（作为后轮的子节点，自动跟随）
	_flames.clear()
	var rear_indices := [2, 3]   # 后左、后右
	for idx in rear_indices:
		if idx >= _wheels.size():
			continue
		var wheel := _wheels[idx]
		if not wheel:
			continue
		var flame := _build_flame_particle()
		# 直接挂到轮子上，火焰会跟着轮子的所有变换走
		wheel.add_child(flame)
		flame.position = Vector3(0, 0.2, 0)
		_flames.append(flame)
	print("[DriftFX] 创建 ", _flames.size(), " 团火焰")


func _build_flame_particle() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 60
	p.lifetime = 0.5
	p.emitting = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# 火焰 mesh (尺寸是之前的 30%)
	var sm := SphereMesh.new()
	sm.radius = 0.054
	sm.height = 0.108
	p.draw_pass_1 = sm

	# 发光材质
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.55, 0.1, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.3, 0.05, 1.0)
	mat.emission_energy_multiplier = 8.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	p.material_override = mat

	# 粒子运动 (速度也缩 30%)
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
	proc.hue_variation_min = -0.08
	proc.hue_variation_max = 0.1
	p.process_material = proc
	return p


# ============================================================
#  公开 API（由 car.gd 调用）
# ============================================================
func set_drifting(on: bool) -> void:
	_drifting = on
	# 火焰开关
	for f in _flames:
		if f:
			f.emitting = on
	# 轮胎发光开关
	for i in range(_wheels.size()):
		var w := _wheels[i] as MeshInstance3D
		if not w:
			continue
		if on:
			if i < _glow_mat_cache.size() and _glow_mat_cache[i]:
				w.material_override = _glow_mat_cache[i]
		else:
			w.material_override = null   # 恢复原渲染（使用 mesh 自带材质）


func clear_all_marks() -> void:
	for m in _marks:
		if is_instance_valid(m.node):
			m.node.queue_free()
	_marks.clear()


# ============================================================
#  胎印生成
# ============================================================
func _process(delta: float) -> void:
	# 永久模式不需要淡出 (节省性能)
	if not permanent_marks:
		_update_mark_fadeout(delta)

	# 漂移中持续放置胎印
	if not _drifting or not _car_body or not _car_mesh:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = tire_mark_interval
	# 4 个轮子各放一个（前轮也漂移甩出胎印更真实）
	for w in _wheels:
		if w:
			_spawn_mark_under_wheel(w)


func _update_mark_fadeout(delta: float) -> void:
	for i in range(_marks.size() - 1, -1, -1):
		var m = _marks[i]
		m.life -= delta
		if m.life <= 0.0:
			if is_instance_valid(m.node):
				m.node.queue_free()
			_marks.remove_at(i)
		else:
			var alpha: float = clampf(m.life / tire_mark_lifetime, 0.0, 1.0) * 0.92
			if is_instance_valid(m.node):
				var mat := m.node.material_override as StandardMaterial3D
				if mat:
					mat.albedo_color = Color(0.04, 0.04, 0.04, alpha)


func _spawn_mark_under_wheel(wheel: Node3D) -> void:
	# 从轮子位置正下方做射线
	var wheel_pos: Vector3 = wheel.global_position
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		wheel_pos + Vector3(0, 0.5, 0),
		wheel_pos + Vector3(0, -1.5, 0)
	)
	q.exclude = [_car_body.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return

	var m := MeshInstance3D.new()
	m.mesh = _shared_mark_mesh
	m.material_override = _shared_mark_mat.duplicate()
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# 朝向：Y=地面法线, Z=车身前进方向投影到地面
	var up: Vector3 = hit.normal
	var car_basis := _car_mesh.global_transform.basis
	var fwd: Vector3 = -car_basis.z
	fwd = fwd - up * fwd.dot(up)
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	else:
		fwd = fwd.normalized()
	var right: Vector3 = up.cross(fwd).normalized()
	fwd = right.cross(up).normalized()

	var basis := Basis(right, up, fwd)
	m.global_transform = Transform3D(basis, hit.position + up * 0.05)

	get_tree().current_scene.add_child(m)
	if not permanent_marks:
		_marks.append({"node": m, "life": tire_mark_lifetime})

	# 数量上限保护（即便永久也有上限防显存爆炸）
	while _marks.size() > tire_mark_max:
		var oldest = _marks.pop_front()
		if is_instance_valid(oldest.node):
			oldest.node.queue_free()
