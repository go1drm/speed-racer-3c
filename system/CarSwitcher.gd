extends Node
## ============================================================
##  赛车切换器 - 全局 AutoLoad 单例
##  · F3 → SUV (car_suv.tscn) - 旧默认
##  · F4 → 玉麒麟 (car.tscn) - 当前默认
## ============================================================

const CAR_SUV: String = "res://core/car_suv.tscn"
const CAR_DEFAULT: String = "res://core/car.tscn"   # 玉麒麟


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F3:
			print("[CarSwitcher] 切换到 SUV")
			_replace_car(CAR_SUV)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F4:
			print("[CarSwitcher] 切换到玉麒麟")
			_replace_car(CAR_DEFAULT)
			get_viewport().set_input_as_handled()


func _replace_car(scene_path: String) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		push_warning("[CarSwitcher] 没有 current_scene")
		return
	var old_car := scene.find_child("Car", true, false)
	if old_car == null:
		push_warning("[CarSwitcher] 场景里找不到 Car 节点")
		return

	# 记录旧车位置
	var parent: Node = old_car.get_parent()
	var mesh_pos: Vector3 = Vector3.ZERO
	var mesh_basis: Basis = Basis.IDENTITY
	var old_car_mesh: Node = old_car.find_child("CarMesh", false, false)
	if old_car_mesh and old_car_mesh is Node3D:
		mesh_pos = (old_car_mesh as Node3D).global_position
		mesh_basis = (old_car_mesh as Node3D).global_transform.basis
	else:
		# 兜底
		if old_car is Node3D:
			mesh_pos = (old_car as Node3D).global_position + Vector3(0, 1, 0)

	# 清理 HUD / Tuner (新车 _ready 会重新 spawn)
	for child_name in ["HUD", "Tuner"]:
		var n := scene.find_child(child_name, true, false)
		if n:
			n.queue_free()

	# 删除旧车
	old_car.name = "_CarOld_" + str(Time.get_ticks_msec())
	old_car.queue_free()

	# 延迟到下一帧, 让 queue_free 完成
	call_deferred("_spawn_new_car", parent, scene_path, mesh_pos, mesh_basis)


func _spawn_new_car(parent: Node, scene_path: String, mesh_pos: Vector3, mesh_basis: Basis) -> void:
	await get_tree().process_frame

	if not is_instance_valid(parent):
		push_warning("[CarSwitcher] parent 已失效")
		return
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_warning("[CarSwitcher] 加载失败: %s" % scene_path)
		return

	var new_car: Node = packed.instantiate()
	new_car.name = "Car"

	# ========= 关键: 入树前把 CarMesh 的 transform 改为目标位置 =========
	# CarMesh 是 top_level=true, 它入树后的 global_transform 会等于它的 transform
	# (因为 top_level 忽略父节点变换)
	var new_car_mesh: Node = new_car.find_child("CarMesh", false, false)
	if new_car_mesh and new_car_mesh is Node3D:
		var t := Transform3D(mesh_basis, mesh_pos)
		(new_car_mesh as Node3D).transform = t

	# 同时把 Car 本身的 transform 也预置好 (让 _ready 里看到正确的初始 global_position)
	if new_car is Node3D:
		# RigidBody 位置 = mesh 位置 - sphere_offset (默认 DOWN = (0,-1,0))
		# 所以 RigidBody 应该在 mesh 位置上方 1 单位
		(new_car as Node3D).transform = Transform3D(Basis.IDENTITY, mesh_pos + Vector3(0, 1, 0))

	# 现在 add: _ready 跑时 car_mesh.global_position 就是 mesh_pos
	parent.add_child(new_car)

	# 清零速度
	if new_car is RigidBody3D:
		(new_car as RigidBody3D).linear_velocity = Vector3.ZERO
		(new_car as RigidBody3D).angular_velocity = Vector3.ZERO

	# 修正场景相机 target 指向新 CarMesh
	var scene := get_tree().current_scene
	if scene and new_car_mesh:
		_update_camera_target_recursive(scene, new_car_mesh)

	print("[CarSwitcher] 新车已生成: ", scene_path, " at mesh=", mesh_pos)


func _update_camera_target_recursive(node: Node, car_mesh: Node) -> void:
	if node is Camera3D and "target" in node:
		node.set("target", car_mesh)
	for c in node.get_children():
		_update_camera_target_recursive(c, car_mesh)
