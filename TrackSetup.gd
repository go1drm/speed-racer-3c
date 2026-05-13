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


const SpeedPadScript := preload("res://SpeedPad.gd")

## 加速带/弹射器推力配置 (可在场景里覆盖)
@export_group("Speed Pads (加速带 / 弹射器)")
## 加速带推力 (沿车头水平方向, 单位 m/s 目标增速)
@export var addspeed_kick: float = 20.0
## 加速带持续施力时长 (秒)
@export var addspeed_duration: float = 0.4
## 弹射器推力 (比加速带更猛)
@export var shoot_kick: float = 40.0
## 弹射器持续施力时长
@export var shoot_duration: float = 0.5


func _collect_and_generate(node: Node) -> int:
	var generated: int = 0
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		# [调试可选] 需要查 mesh 名时把下面两行改成 print, 现在静默
		# var mat_name: String = mi.mesh.surface_get_material(0).resource_name if (mi.mesh and mi.mesh.get_surface_count() > 0 and mi.mesh.surface_get_material(0)) else ""
		# print("[TrackDebug] mesh: name='%s' path=%s mat='%s'" % [mi.name, mi.get_path(), mat_name])
		# 【加速带 / 弹射器识别】 按 mesh 名字区分
		# FBX 里命名规律:
		#   Collider_AddSpeed_*_OverlayPhy → 白色加速带
		#   Collider_Shoot_*_OverlayPhy    → 弹射器/跳台
		# 这些 mesh 不生成 trimesh 碰撞 (车要能穿过), 而是用 Area3D 做触发器
		var mesh_name_upper: String = mi.name.to_upper()
		if "ADDSPEED" in mesh_name_upper:
			_convert_to_speed_pad(mi, "addspeed", addspeed_kick, addspeed_duration)
			return 0   # 不计入普通碰撞数; 子节点也不必再递归因为 mi 已处理
		elif "SHOOT" in mesh_name_upper:
			_convert_to_speed_pad(mi, "shoot", shoot_kick, shoot_duration)
			return 0
		# 其他 mesh: 普通 trimesh 碰撞
		if mi.mesh and not _already_has_collision(mi):
			mi.create_trimesh_collision()
			generated += 1
	for c in node.get_children():
		generated += _collect_and_generate(c)
	return generated


## 把一个 MeshInstance3D 转成"加速带触发区":
##   1) 隐藏它的原 StaticBody 碰撞 (如果有)
##   2) 在它的位置创建 Area3D + BoxShape3D (从 mesh.get_aabb() 取尺寸)
##   3) Area3D 挂上 SpeedPad.gd 并设置类型/参数
##   4) 车进入 Area → SpeedPad 调 car.apply_speed_pad_boost()
## mesh 本体保留显示, 只是不参与物理碰撞
func _convert_to_speed_pad(mi: MeshInstance3D, pad_type: String, kick: float, duration: float) -> void:
	# 如果已经有 StaticBody 子节点(之前生成过), 删掉它的碰撞, 避免挡路
	for c in mi.get_children():
		if c is StaticBody3D:
			c.queue_free()
	# 从 mesh 的 AABB 拿尺寸建 BoxShape3D
	if not mi.mesh:
		push_warning("[TrackSetup] %s 没有 mesh, 跳过加速带生成" % mi.name)
		return
	var aabb: AABB = mi.mesh.get_aabb()
	var box := BoxShape3D.new()
	box.size = aabb.size.abs()
	# 创建 Area3D 和 CollisionShape3D
	var area := Area3D.new()
	area.name = "SpeedPadArea"
	var shape_node := CollisionShape3D.new()
	shape_node.shape = box
	# Area 位置: mesh 的全局位置 + mesh AABB 中心的偏移 (因为 AABB 中心不一定是 mesh 原点)
	shape_node.transform.origin = aabb.position + aabb.size * 0.5
	area.add_child(shape_node)
	# 把 Area 挂成 mi 的子节点, 这样会跟随 mi 的全局变换
	mi.add_child(area)
	# 脚本和参数
	area.set_script(SpeedPadScript)
	area.set("pad_type", pad_type)
	area.set("boost_speed_kick", kick)
	area.set("boost_duration", duration)
	print("[TrackSetup] 加速带: %s type=%s kick=%.1f dur=%.2f size=%s"
		% [mi.name, pad_type, kick, duration, box.size])


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
