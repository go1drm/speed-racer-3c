extends Node3D
## ============================================================
##  漂移特效：胎印 + 漂焰
##  挂在场景根, 通过 set_car(car) 绑定车, 每帧自己跟随车身后方
## ============================================================

@export var tire_mark_lifetime: float = 6.0
@export var tire_mark_interval: float = 0.03
@export var tire_mark_size: Vector2 = Vector2(0.8, 1.2)
@export var tire_mark_max: int = 400

@onready var flame_left: GPUParticles3D = $FlameLeft
@onready var flame_right: GPUParticles3D = $FlameRight

var _drifting: bool = false
var _timer: float = 0.0
var _car_body: RigidBody3D = null
var _car_mesh: Node3D = null
var _marks: Array = []
var _tire_mark_mesh: QuadMesh = null


func _ready() -> void:
	flame_left.emitting = false
	flame_right.emitting = false
	_tire_mark_mesh = QuadMesh.new()
	_tire_mark_mesh.size = tire_mark_size


func set_car(car: RigidBody3D) -> void:
	_car_body = car
	# CarMesh 在 car 节点下
	if car.has_node("CarMesh"):
		_car_mesh = car.get_node("CarMesh")


func set_drifting(on: bool) -> void:
	_drifting = on
	if flame_left:
		flame_left.emitting = on
	if flame_right:
		flame_right.emitting = on
	print("[DriftFX] set_drifting=", on, " flame_left=", flame_left, " flame_right=", flame_right,
		" my_global_pos=", global_position, " car_mesh=", _car_mesh)


func _process(delta: float) -> void:
	# 1. 每帧跟随到车身位置（用 car_mesh 的 global_transform, 因为它有正确的车头朝向）
	if _car_mesh and is_instance_valid(_car_mesh):
		global_transform = _car_mesh.global_transform

	# 2. 更新胎印淡出
	for i in range(_marks.size() - 1, -1, -1):
		var m = _marks[i]
		m.life -= delta
		if m.life <= 0.0:
			if is_instance_valid(m.node):
				m.node.queue_free()
			_marks.remove_at(i)
		else:
			var alpha: float = clampf(m.life / tire_mark_lifetime, 0.0, 1.0) * 0.85
			if is_instance_valid(m.node):
				var mat := m.node.material_override as StandardMaterial3D
				if mat:
					mat.albedo_color = Color(0.05, 0.05, 0.05, alpha)

	# 3. 漂移时生成胎印
	if not _drifting or not _car_body or not _car_mesh:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = tire_mark_interval
	_spawn_tire_marks()


func _spawn_tire_marks() -> void:
	# 从车身后方两侧往下射线找地面, 生成胎印
	var car_xform: Transform3D = _car_mesh.global_transform
	var rear_local: Vector3 = Vector3(0, 0, 0.8)     # 车尾(+Z 是后方因为 forward 是 -Z)
	var side: float = 0.55
	for s in [-1, 1]:
		var local_pos: Vector3 = rear_local + Vector3(side * s, 0, 0)
		var world_pos: Vector3 = car_xform * local_pos
		_spawn_single_mark(world_pos, car_xform.basis)


func _spawn_single_mark(from_pos: Vector3, car_basis: Basis) -> void:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		from_pos + Vector3(0, 1.0, 0),
		from_pos + Vector3(0, -2.5, 0)
	)
	q.exclude = [_car_body.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return

	var m := MeshInstance3D.new()
	m.mesh = _tire_mark_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.05, 0.05, 0.85)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material_override = mat

	# 朝向: Y 轴=地面法线, Z 轴=车身前进方向的地面投影
	var up: Vector3 = hit.normal
	var fwd: Vector3 = -car_basis.z
	fwd = (fwd - up * fwd.dot(up))
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	else:
		fwd = fwd.normalized()
	var right: Vector3 = up.cross(fwd).normalized()
	fwd = right.cross(up).normalized()

	var basis := Basis(right, up, fwd)
	m.global_transform = Transform3D(basis, hit.position + up * 0.03)

	get_tree().current_scene.add_child(m)
	_marks.append({"node": m, "life": tire_mark_lifetime})

	while _marks.size() > tire_mark_max:
		var oldest = _marks.pop_front()
		if is_instance_valid(oldest.node):
			oldest.node.queue_free()
