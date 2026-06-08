extends Node3D
class_name Block_Pithole
## ============================================================
##  凹坑机关 (Pithole)
## ============================================================
## 一个立方体区域, 覆盖的赛道部分碰撞禁用 + 视觉隐藏 = 路面缺口
##
## 实现:
##   · CollisionShape3D: 如果 shape 的世界 AABB 与凹坑 AABB 相交 → disabled
##   · MeshInstance3D: 如果 mesh 的世界 AABB 与凹坑 AABB 相交 → visible=false
##   · 每帧更新 (移动凹坑后自动刷新)
##   · 编辑器中: 半透明棕色方块; 游戏中: 全透明
## ============================================================

@export_group("尺寸")
@export_range(1.0, 100.0, 0.5) var pit_width: float = 10.0
@export_range(1.0, 50.0, 0.5) var pit_height: float = 6.0
@export_range(1.0, 100.0, 0.5) var pit_depth: float = 10.0

@export_group("视觉")
@export var editor_color: Color = Color(0.55, 0.35, 0.15, 0.35)

var _box_mesh: MeshInstance3D = null
var _affected_shapes: Array = []
var _affected_meshes: Array = []
var _pit_aabb: AABB = AABB()


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_box_mesh = null
	_restore_all()

	_box_mesh = MeshInstance3D.new()
	_box_mesh.name = "PitVisual"
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(pit_width, pit_height, pit_depth)
	_box_mesh.mesh = bmesh
	_box_mesh.position = Vector3(0.0, pit_height * 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = editor_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_box_mesh.material_override = mat
	_box_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_box_mesh)
	_update_aabb()


func _update_aabb() -> void:
	var center: Vector3 = global_position + Vector3(0.0, pit_height * 0.5, 0.0)
	var half: Vector3 = Vector3(pit_width * 0.5, pit_height * 0.5, pit_depth * 0.5)
	_pit_aabb = AABB(center - half, half * 2.0)


func _physics_process(_delta: float) -> void:
	_update_aabb()
	_restore_all()

	var parent: Node = get_parent()
	if parent == null:
		return

	for child in parent.get_children():
		if child == self:
			continue
		if not child is Node3D:
			continue
		_process_node_recursive(child)


func _process_node_recursive(node: Node) -> void:
	# CollisionShape3D: 用 shape 的世界 AABB 与凹坑相交判定
	if node is CollisionShape3D:
		var cs: CollisionShape3D = node as CollisionShape3D
		if cs.shape != null:
			var shape_aabb: AABB = _get_shape_world_aabb(cs)
			if _pit_aabb.intersects(shape_aabb):
				cs.disabled = true
				_affected_shapes.append(cs)

	# MeshInstance3D: 用 mesh 的世界 AABB 与凹坑相交判定
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		if mi != _box_mesh and mi.mesh != null:
			var mi_aabb: AABB = _transform_aabb(mi.get_aabb(), mi.global_transform)
			if _pit_aabb.intersects(mi_aabb):
				mi.visible = false
				_affected_meshes.append(mi)

	for c in node.get_children():
		_process_node_recursive(c)


func _get_shape_world_aabb(cs: CollisionShape3D) -> AABB:
	# 从 CollisionShape3D 的 shape 获取 local AABB, 然后转世界
	var s: Shape3D = cs.shape
	var local_aabb: AABB
	if s is BoxShape3D:
		var half: Vector3 = (s as BoxShape3D).size * 0.5
		local_aabb = AABB(-half, (s as BoxShape3D).size)
	elif s is SphereShape3D:
		var r: float = (s as SphereShape3D).radius
		local_aabb = AABB(Vector3(-r, -r, -r), Vector3(r * 2, r * 2, r * 2))
	elif s is CylinderShape3D:
		var r: float = (s as CylinderShape3D).radius
		var h: float = (s as CylinderShape3D).height
		local_aabb = AABB(Vector3(-r, -h * 0.5, -r), Vector3(r * 2, h, r * 2))
	elif s is CapsuleShape3D:
		var r: float = (s as CapsuleShape3D).radius
		var h: float = (s as CapsuleShape3D).height
		local_aabb = AABB(Vector3(-r, -h * 0.5, -r), Vector3(r * 2, h, r * 2))
	else:
		# 兜底: 用一个小盒子
		local_aabb = AABB(Vector3(-0.5, -0.5, -0.5), Vector3(1, 1, 1))
	return _transform_aabb(local_aabb, cs.global_transform)


func _restore_all() -> void:
	for cs in _affected_shapes:
		if is_instance_valid(cs):
			(cs as CollisionShape3D).disabled = false
	_affected_shapes.clear()
	for mi in _affected_meshes:
		if is_instance_valid(mi):
			(mi as MeshInstance3D).visible = true
	_affected_meshes.clear()


func _transform_aabb(aabb: AABB, xform: Transform3D) -> AABB:
	var min_v: Vector3 = xform * aabb.position
	var max_v: Vector3 = min_v
	for i in range(1, 8):
		var corner := Vector3(
			aabb.position.x + aabb.size.x * (1.0 if (i & 1) else 0.0),
			aabb.position.y + aabb.size.y * (1.0 if (i & 2) else 0.0),
			aabb.position.z + aabb.size.z * (1.0 if (i & 4) else 0.0)
		)
		var wc: Vector3 = xform * corner
		min_v = Vector3(minf(min_v.x, wc.x), minf(min_v.y, wc.y), minf(min_v.z, wc.z))
		max_v = Vector3(maxf(max_v.x, wc.x), maxf(max_v.y, wc.y), maxf(max_v.z, wc.z))
	return AABB(min_v, max_v - min_v)


func get_editable_params() -> Array:
	return [
		{"key": "pit_width", "label": "宽度(m)", "min": 1.0, "max": 100.0, "step": 0.5, "value": pit_width},
		{"key": "pit_height", "label": "高度(m)", "min": 1.0, "max": 50.0, "step": 0.5, "value": pit_height},
		{"key": "pit_depth", "label": "深度(m)", "min": 1.0, "max": 100.0, "step": 0.5, "value": pit_depth},
	]

func set_editable_param(key: String, value: float) -> void:
	match key:
		"pit_width": pit_width = value
		"pit_height": pit_height = value
		"pit_depth": pit_depth = value
	_rebuild()
