extends Node3D
## ============================================================
##  赛道启动脚本 - 挂到自定义/FBX 赛道的场景根节点
##  作用:
##   1) 为 Track 子树里所有 MeshInstance3D 生成 trimesh 碰撞
##      (FBX 导入默认没有 StaticBody/CollisionShape)
##   2) 从 Car 配置位置的正上方射线找地面, 把车落在地面
## ============================================================

## 是否自动为 Track 子节点生成碰撞
@export var auto_generate_collision: bool = true
## 是否自动调整 Car 到地面
@export var auto_find_spawn: bool = true
## Track 节点的相对路径(默认 "Track")
@export var track_node_path: NodePath = NodePath("Track")
## Car 节点的相对路径(默认 "Car")
@export var car_node_path: NodePath = NodePath("Car")
## 起始点射线长度
@export var spawn_ray_distance: float = 1000.0
## 起始点 Y 上方偏移(落地后的高度)
@export var spawn_y_offset: float = 2.0


func _ready() -> void:
	if auto_generate_collision:
		_generate_track_collision()
	if auto_find_spawn:
		call_deferred("_adjust_car_spawn")


func _generate_track_collision() -> void:
	var track: Node = get_node_or_null(track_node_path)
	if not track:
		push_warning("[TrackSetup] 找不到 Track 节点, 跳过碰撞生成")
		return
	var count: int = _collect_and_generate(track)
	print("[TrackSetup] 为 Track 生成了 %d 个碰撞网格" % count)


func _collect_and_generate(node: Node) -> int:
	var generated: int = 0
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		if mi.mesh and not _already_has_collision(mi):
			mi.create_trimesh_collision()
			generated += 1
	for c in node.get_children():
		generated += _collect_and_generate(c)
	return generated


func _already_has_collision(mi: MeshInstance3D) -> bool:
	# 判断是否已经有 StaticBody 包裹(create_trimesh_collision 会把 body 作为子节点添加)
	for c in mi.get_children():
		if c is StaticBody3D:
			return true
	# 父节点已经是 StaticBody3D 的情况
	var p: Node = mi.get_parent()
	if p is StaticBody3D:
		return true
	return false


func _adjust_car_spawn() -> void:
	var car: Node3D = get_node_or_null(car_node_path)
	if not car:
		return
	# 等两帧物理让碰撞生成落地
	await get_tree().physics_frame
	await get_tree().physics_frame

	var space := get_world_3d().direct_space_state
	var origin: Vector3 = car.global_position
	var from: Vector3 = Vector3(origin.x, origin.y + spawn_ray_distance, origin.z)
	var to: Vector3   = Vector3(origin.x, origin.y - spawn_ray_distance, origin.z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	if car is RigidBody3D:
		query.exclude = [car.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		push_warning("[TrackSetup] Car 正下方找不到地面, 保持原位")
		return
	var target_pos: Vector3 = hit.position + Vector3(0, spawn_y_offset, 0)
	car.global_position = target_pos
	if car is RigidBody3D:
		car.linear_velocity = Vector3.ZERO
		car.angular_velocity = Vector3.ZERO
	# 通知 car 内部自己也复位(如果有该方法)
	if car.has_method("_snap_to_car_mesh_origin"):
		pass  # 保持当前已设置的位置
	# CarMesh top_level 同步
	var car_mesh: Node3D = car.get_node_or_null("CarMesh")
	if car_mesh and car_mesh.top_level:
		car_mesh.global_position = target_pos + Vector3(0, -1, 0)  # sphere_offset 默认 DOWN
	print("[TrackSetup] Car 已落到: ", target_pos)
