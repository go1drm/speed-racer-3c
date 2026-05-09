extends Node3D
## ============================================================
##  漂移特效：胎印 + 漂焰
##  由 car.gd 控制：漂移时 set_drifting(true), 停止时 set_drifting(false)
## ============================================================

@export var tire_mark_lifetime: float = 4.0       ## 胎印存在时间(秒)
@export var tire_mark_interval: float = 0.04      ## 胎印放置间隔
@export var tire_mark_size: Vector2 = Vector2(0.4, 0.6)
@export var tire_mark_max: int = 300               ## 胎印最大数量(超过后自动清理最老的)

@onready var flame_left: GPUParticles3D = $FlameLeft
@onready var flame_right: GPUParticles3D = $FlameRight
@onready var tire_mark_root: Node3D = $TireMarkRoot

var _drifting: bool = false
var _timer: float = 0.0
var _car_body: RigidBody3D = null
var _marks: Array = []                             # 所有存活胎印
var _tire_mark_mesh: QuadMesh = null
var _tire_mark_mat: StandardMaterial3D = null


func _ready() -> void:
	flame_left.emitting = false
	flame_right.emitting = false

	# 预创建胎印共享的 mesh 和材质 (所有胎印共用)
	_tire_mark_mesh = QuadMesh.new()
	_tire_mark_mesh.size = tire_mark_size

	_tire_mark_mat = StandardMaterial3D.new()
	_tire_mark_mat.albedo_color = Color(0.05, 0.05, 0.05, 0.85)
	_tire_mark_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_tire_mark_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tire_mark_mat.no_depth_test = false


func set_car(car: RigidBody3D) -> void:
	_car_body = car


func set_drifting(on: bool) -> void:
	_drifting = on
	flame_left.emitting = on
	flame_right.emitting = on


func _process(delta: float) -> void:
	# 更新胎印生命周期（淡出 + 移除过期）
	for i in range(_marks.size() - 1, -1, -1):
		var m = _marks[i]
		m.life -= delta
		if m.life <= 0.0:
			m.node.queue_free()
			_marks.remove_at(i)
		else:
			var alpha: float = clampf(m.life / tire_mark_lifetime, 0.0, 1.0) * 0.85
			if m.node and is_instance_valid(m.node):
				var mat := m.node.material_override as StandardMaterial3D
				if mat:
					mat.albedo_color = Color(0.05, 0.05, 0.05, alpha)

	# 漂移中定期放置胎印
	if not _drifting or not _car_body:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = tire_mark_interval
	_spawn_tire_mark_pair()


func _spawn_tire_mark_pair() -> void:
	if not _car_body:
		return
	# 从车身后方两侧(对应后轮位置)往下射线, 在命中点生成胎印四边形
	var car_xform: Transform3D = global_transform   # DriftFX 自身已挂在 CarMesh 上, 用它的 transform
	var rear_offset: Vector3 = Vector3(0, 0, -0.6)  # 后方
	var side_offset: float = 0.5

	for side in [-1, 1]:
		var local_pos: Vector3 = rear_offset + Vector3(side_offset * side, 0, 0)
		var world_pos: Vector3 = car_xform * local_pos
		_spawn_single_mark(world_pos, car_xform.basis)


func _spawn_single_mark(from_pos: Vector3, car_basis: Basis) -> void:
	# 从给定位置上方 0.5m 向下射线 1m
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		from_pos + Vector3(0, 0.5, 0),
		from_pos + Vector3(0, -1.5, 0)
	)
	q.exclude = [_car_body.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return

	var m := MeshInstance3D.new()
	m.mesh = _tire_mark_mesh
	var mat := _tire_mark_mat.duplicate() as StandardMaterial3D
	m.material_override = mat

	# 朝向: 法线向上, 前进方向对齐车身 forward (投影到地面)
	var up: Vector3 = hit.normal
	var fwd: Vector3 = -car_basis.z
	fwd = (fwd - up * fwd.dot(up)).normalized()
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	var right: Vector3 = up.cross(fwd).normalized()
	fwd = right.cross(up).normalized()

	# QuadMesh 默认朝 +Z, 我们要它躺平朝 +Y, 所以构造 basis 时让 Z=fwd, Y=up
	var basis := Basis(right, up, fwd)
	m.global_transform = Transform3D(basis, hit.position + up * 0.02)

	# 加到世界场景(不要加在 CarMesh 下, 否则会跟着车走)
	get_tree().current_scene.add_child(m)
	_marks.append({"node": m, "life": tire_mark_lifetime})

	# 超过上限, 清理最老的
	while _marks.size() > tire_mark_max:
		var oldest = _marks.pop_front()
		if is_instance_valid(oldest.node):
			oldest.node.queue_free()


func clear_all_marks() -> void:
	for m in _marks:
		if is_instance_valid(m.node):
			m.node.queue_free()
	_marks.clear()
