## ============================================================
##  TrackWallTagger.gd
##  自动识别赛道中的"墙" MeshInstance, 为它们创建独立的 StaticBody3D + ConcaveCollisionShape3D
##  并打 group="wall" + collision_layer=4 标签, 让 car.gd 在 _integrate_forces 里
##  能精确区分撞到的是墙还是地面.
##
##  使用方式:
##    1. 把这个脚本挂在 track.tscn 里的一个 Node3D 上 (作为 Track 的 child 或 sibling 都行)
##    2. 配置 scan_root_path 指向赛道根节点 (默认 "../" 即父节点 = Track)
##    3. (可选) 调整 wall_keywords 增删关键字
##    4. 运行游戏, 控制台会打印识别报告 [TrackWallTagger]
##    5. 默认 dry_run=false 会真正创建独立 collider; 设 true 只打印不创建
## ============================================================
extends Node3D

## 扫描根节点的 NodePath. 默认 "../" = 这个 WallTagger 节点的父节点 (即 Track)
## 如果想扫描整个场景, 设为 "/root" 或具体路径
@export_node_path("Node") var scan_root_path: NodePath = NodePath("..")

## 墙关键字白名单: MeshInstance3D 名字 / 它的材质名 / 父节点名 含这些关键字 → 视为墙
## 大小写不敏感. 默认覆盖中英文常见词
@export var wall_keywords: Array[String] = [
	"wall", "Wall",
	"fence", "Fence",
	"barrier", "Barrier",
	"guardrail", "GuardRail", "guard_rail",
	"墙", "围栏", "护栏", "挡板", "栏杆"
]

## 干跑模式: true=只扫描+打印不创建独立 collider, false=正常工作创建 wall body
@export var dry_run: bool = false

## 是否详细打印每个 MeshInstance3D 的诊断 (墙和非墙都打印名字)
## 启动诊断时建议设 true, 能看清 glb 里 mesh 的命名是什么样
@export var verbose_diagnostic: bool = true

## 独立 wall body 的 collision_layer (推荐 4, 即第 3 层)
## car.gd 不需要改 collision_mask (默认能撞到所有层), 只是用 layer 区分
@export_flags_3d_physics var wall_body_layer: int = 4

## 独立 wall body 的 collision_mask (墙不需要主动检测什么, 设 0 即可, 反正是 StaticBody)
@export_flags_3d_physics var wall_body_mask: int = 0

## 物理材质: 给独立 wall body 用. 默认无, 走全局物理. 想给墙特殊弹性/摩擦时设
@export var wall_physics_material: PhysicsMaterial = null


func _ready() -> void:
	# 等一帧让 glb 实例化完成
	await get_tree().process_frame
	_scan_and_tag_walls()


func _scan_and_tag_walls() -> void:
	print("[TrackWallTagger] === 开始扫描赛道墙 MeshInstance3D ===")
	print("[TrackWallTagger]   scan_root_path = ", scan_root_path)
	print("[TrackWallTagger]   关键字白名单: ", wall_keywords)
	print("[TrackWallTagger]   dry_run = ", dry_run)
	print("[TrackWallTagger]   wall_body_layer = ", wall_body_layer)

	var scan_root: Node = get_node_or_null(scan_root_path)
	if scan_root == null:
		print("[TrackWallTagger] ⚠️ 找不到 scan_root_path = %s, 跳过" % str(scan_root_path))
		return
	print("[TrackWallTagger]   实际扫描根节点: %s (类型 %s)" % [scan_root.name, scan_root.get_class()])

	var all_meshes: Array[MeshInstance3D] = []
	_collect_meshes(scan_root, all_meshes)
	print("[TrackWallTagger]   找到 %d 个 MeshInstance3D" % all_meshes.size())

	var wall_count: int = 0
	var ground_count: int = 0
	var matched_meshes: Array[MeshInstance3D] = []

	for mi in all_meshes:
		var is_wall: bool = _is_wall_mesh(mi)
		if is_wall:
			wall_count += 1
			matched_meshes.append(mi)
			if verbose_diagnostic:
				print("[TrackWallTagger]   🧱 墙: %s (路径=%s)" % [mi.name, mi.get_path()])
		else:
			ground_count += 1
			if verbose_diagnostic:
				print("[TrackWallTagger]   🟫 地: %s" % mi.name)

	print("[TrackWallTagger] === 扫描完成: %d 墙 / %d 地面 ===" % [wall_count, ground_count])

	if dry_run:
		print("[TrackWallTagger] dry_run=true, 不创建独立 collider, 仅诊断结束")
		return

	# 为每个识别到的墙 mesh 创建独立 StaticBody3D + CollisionShape
	var created: int = 0
	for mi in matched_meshes:
		if _create_wall_body_for(mi):
			created += 1
	print("[TrackWallTagger] === 创建完成: 为 %d 个墙 mesh 创建了独立 wall body ===" % created)


# 递归收集 root 节点下所有 MeshInstance3D
func _collect_meshes(root: Node, out_list: Array[MeshInstance3D]) -> void:
	if root is MeshInstance3D:
		out_list.append(root)
	for child in root.get_children():
		_collect_meshes(child, out_list)


# 判断 MeshInstance3D 是否是墙
# 检查: 节点名 / 父节点名 / 各 surface 的材质名 是否含关键字
func _is_wall_mesh(mi: MeshInstance3D) -> bool:
	# 1) 节点名
	if _name_matches_wall(mi.name):
		return true
	# 2) 父节点名 (有些工具把材质名放在父节点上)
	var p: Node = mi.get_parent()
	if p and _name_matches_wall(p.name):
		return true
	# 3) 各 surface 的材质名
	var m: Mesh = mi.mesh
	if m == null:
		return false
	for i in range(m.get_surface_count()):
		var mat: Material = mi.get_active_material(i)
		if mat == null:
			mat = m.surface_get_material(i)
		if mat and _name_matches_wall(mat.resource_name):
			return true
	return false


# 检查字符串是否包含任何 wall 关键字 (大小写不敏感)
func _name_matches_wall(name_str: String) -> bool:
	if name_str.is_empty():
		return false
	var lower: String = name_str.to_lower()
	for kw in wall_keywords:
		if kw.is_empty():
			continue
		if lower.contains(kw.to_lower()):
			return true
	return false


# 为单个 MeshInstance3D 创建独立的 StaticBody3D + ConcavePolygonShape3D
# 步骤:
#   1) 用 mi.mesh.create_trimesh_shape() 拿到该 mesh 的独立 ConcavePolygonShape3D
#   2) 创建 StaticBody3D 节点, 加到 mi 父节点下 (这样 transform 跟着走)
#   3) StaticBody3D 上挂 CollisionShape3D + shape
#   4) 打 group="wall" + collision_layer=wall_body_layer
# 注: 这个独立 collider 和原来 track 的合并 trimesh 是叠加的 (Godot 物理会都报告 contact)
#     car.gd 在 _integrate_forces 里优先匹配 wall group 的 contact 来识别墙
func _create_wall_body_for(mi: MeshInstance3D) -> bool:
	if mi.mesh == null:
		return false
	var shape: Shape3D = mi.mesh.create_trimesh_shape()
	if shape == null:
		print("[TrackWallTagger] ⚠️ 无法为 %s 创建 trimesh shape, 跳过" % mi.name)
		return false

	# 创建 StaticBody3D
	var sb: StaticBody3D = StaticBody3D.new()
	sb.name = mi.name + "_WallBody"
	sb.collision_layer = wall_body_layer
	sb.collision_mask = wall_body_mask
	if wall_physics_material:
		sb.physics_material_override = wall_physics_material
	sb.add_to_group("wall")

	# 创建 CollisionShape3D
	var cs: CollisionShape3D = CollisionShape3D.new()
	cs.name = "WallCollision"
	cs.shape = shape

	sb.add_child(cs)

	# 把 sb 加到 mi 同级父节点下, 让它继承 mi 的全局变换
	# 注意: shape 数据本身是 mi.mesh 的 local 坐标, 所以 sb 必须用 mi 的 global_transform
	var parent: Node = mi.get_parent()
	if parent == null:
		print("[TrackWallTagger] ⚠️ %s 没有父节点, 跳过" % mi.name)
		sb.queue_free()
		return false
	parent.add_child(sb)
	sb.global_transform = mi.global_transform
	return true
