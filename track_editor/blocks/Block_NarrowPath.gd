extends Node3D
class_name Block_NarrowPath
## ============================================================
##  窄道机关 (Narrow Path) — 贝塞尔曲线路径
## ============================================================
## 用 ArrayMesh 生成一整条连续曲面网格 (1 个 mesh + 1 个碰撞体)
## 比 N 个 BoxMesh 段性能好得多, 且完全无缝.
## ============================================================

@export_group("路面")
@export_range(2.0, 15.0, 0.5) var path_width: float = 4.0
## 终点宽度 (如果 <= 0 则与 path_width 相同, 实现宽度渐变)
@export_range(0.0, 15.0, 0.5) var end_width: float = 0.0
@export_range(0.1, 2.0, 0.1) var path_thickness: float = 0.3
## 颜色限制: 0=正常(所有车可走), 1=仅红色车(1P), 2=仅蓝色车(2P)
@export_range(0, 2, 1) var color_mode: int = 0

@export_group("路径")
@export var end_offset: Vector3 = Vector3(0.0, 0.0, -30.0)
@export var curve_offset: Vector3 = Vector3(0.0, 0.0, 0.0)
## 终点侧控制点偏移 (三次贝塞尔第二控制点, 全零=退化为二次)
@export var curve_offset_end: Vector3 = Vector3(0.0, 0.0, 0.0)
@export_range(12, 120, 1) var segment_count: int = 72

@export_group("视觉")
@export var road_color: Color = Color(0.4, 0.4, 0.45)
@export var rail_color: Color = Color(0.7, 0.3, 0.1)
@export_range(0.0, 2.0, 0.1) var edge_glow: float = 0.5

## Hermite 模式: 当 hermite_from_tan 非零时启用, _rebuild 用 Hermite 插值代替贝塞尔
## 这些值是本地空间切线向量 (由 TrackEditor 连接时设置)
var hermite_from_tan: Vector3 = Vector3.ZERO
var hermite_to_tan: Vector3 = Vector3.ZERO

# ---- 内部 ----
var _road_body: StaticBody3D = null
var _road_mesh: MeshInstance3D = null
var _color_area: Area3D = null  # 颜色限制检测区
var _excluded_cars: Dictionary = {}  # 被排斥的车 {instance_id: true}
var _edge_mesh_l: MeshInstance3D = null
var _edge_mesh_r: MeshInstance3D = null
# 控制点手柄
var _handle_start: Node3D = null
var _handle_mid: Node3D = null
var _handle_end: Node3D = null
var _handle_lines: Node3D = null
var _handles_visible: bool = false


func _ready() -> void:
	_rebuild()
	# 如果有颜色限制, 延迟几帧后给场景中所有车上色 (开局就显示颜色)
	if color_mode > 0:
		call_deferred("_deferred_color_all_cars")


func _deferred_color_all_cars() -> void:
	# 等场景完全加载
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	# 找所有 RigidBody3D (collision_layer & 2 = 车)
	_find_and_glow_cars(get_tree().root)


func _physics_process(_delta: float) -> void:
	# 颜色限制: 错色车的碰撞被禁用 (穿透掉下去), 所有车闪烁对应颜色光芒
	if color_mode == 0 or _color_area == null or _road_body == null:
		return
	var allowed_id: int = color_mode - 1  # 1→id0(红), 2→id1(蓝)
	for body in _color_area.get_overlapping_bodies():
		if not body is RigidBody3D:
			continue
		var pid: int = _get_car_player_id(body)
		var key: int = body.get_instance_id()
		if pid != allowed_id:
			# 错色车: 禁用碰撞让它穿透
			if not _excluded_cars.has(key):
				_excluded_cars[key] = true
				_road_body.add_collision_exception_with(body)
		else:
			# 正确颜色: 恢复碰撞
			if _excluded_cars.has(key):
				_excluded_cars.erase(key)
				_road_body.remove_collision_exception_with(body)
		# 让车闪烁自己的颜色 (无论对错色)
		_ensure_car_glow(body, pid)
	# 离开区域的车恢复碰撞
	var to_remove: Array = []
	for key in _excluded_cars.keys():
		var still_in: bool = false
		for body in _color_area.get_overlapping_bodies():
			if body.get_instance_id() == key:
				still_in = true
				break
		if not still_in:
			to_remove.append(key)
	for key in to_remove:
		_excluded_cars.erase(key)


func _get_car_player_id(body: Node3D) -> int:
	if "player_id" in body:
		return body.player_id
	if body.has_method("get_player_id"):
		return body.get_player_id()
	return 0


var _glowing_cars: Dictionary = {}  # {instance_id: true}

func _ensure_car_glow(car: Node3D, player_id: int) -> void:
	var key: int = car.get_instance_id()
	if _glowing_cars.has(key):
		return
	_glowing_cars[key] = true
	var glow_color: Color = Color(0.9, 0.15, 0.1) if player_id == 0 else Color(0.1, 0.3, 0.95)
	# 找车身 MeshInstance3D 加 emission
	var mesh_root: Node = car
	for child in car.get_children():
		if "car_mesh" in child.name.to_lower() or "carmesh" in child.name.to_lower():
			mesh_root = child
			break
	_apply_glow_recursive(mesh_root, glow_color)


func _find_and_glow_cars(node: Node) -> void:
	if node is RigidBody3D and node.collision_layer & 2 != 0:
		var pid: int = _get_car_player_id(node)
		_ensure_car_glow(node, pid)
	for child in node.get_children():
		_find_and_glow_cars(child)


func _apply_glow_recursive(node: Node, color: Color) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		var mat: Material = mi.material_override
		if mat == null and mi.mesh and mi.mesh.get_surface_count() > 0:
			mat = mi.mesh.surface_get_material(0)
		if mat is StandardMaterial3D:
			var smat: StandardMaterial3D = mat.duplicate()
			smat.emission_enabled = true
			smat.emission = color
			smat.emission_energy_multiplier = 1.2
			mi.material_override = smat
	for child in node.get_children():
		_apply_glow_recursive(child, color)


func _rebuild() -> void:
	var keep_set: Array = [_handle_start, _handle_mid, _handle_end, _handle_lines]
	for c in get_children():
		if c in keep_set:
			continue
		remove_child(c)
		c.queue_free()
	_road_body = null
	_road_mesh = null

	var points: Array[Vector3] = _calc_bezier_points()
	if points.size() < 2:
		return

	# 计算每个点的 right 向量 (沿路面宽度方向)
	var rights: Array[Vector3] = []
	for i in range(points.size()):
		var dir: Vector3
		if i == 0:
			dir = (points[1] - points[0]).normalized()
		elif i == points.size() - 1:
			dir = (points[i] - points[i - 1]).normalized()
		else:
			dir = (points[i + 1] - points[i - 1]).normalized()
		var up := Vector3.UP
		var right: Vector3 = dir.cross(up).normalized()
		if right.length_squared() < 0.01:
			right = Vector3.RIGHT
		rights.append(right)

	# ---- 计算逐点宽度 (支持渐变) ----
	var actual_end_w: float = end_width if end_width > 0.0 else path_width
	var widths: Array[float] = []
	for i in range(points.size()):
		var t: float = float(i) / float(points.size() - 1)
		widths.append(lerpf(path_width, actual_end_w, t))

	# ---- 路面 ArrayMesh (一条连续 strip) ----
	var road_mat := StandardMaterial3D.new()
	# 颜色模式: 红/蓝染色
	var actual_road_color: Color = road_color
	if color_mode == 1:
		actual_road_color = Color(0.85, 0.2, 0.15)  # 红色路面
	elif color_mode == 2:
		actual_road_color = Color(0.15, 0.3, 0.9)   # 蓝色路面
	road_mat.albedo_color = actual_road_color
	if color_mode > 0:
		road_mat.emission_enabled = true
		road_mat.emission = actual_road_color * 0.4
		road_mat.emission_energy_multiplier = 0.6
	road_mat.metallic = 0.3
	road_mat.roughness = 0.7

	_road_mesh = MeshInstance3D.new()
	_road_mesh.mesh = _build_strip_mesh(points, rights, path_width, 0.0, widths)
	_road_mesh.material_override = road_mat
	
	# 碰撞: 用多段 BoxShape3D (比 trimesh 光滑, 车球不会卡在面边缘)
	_road_body = StaticBody3D.new()
	_road_body.name = "RoadBody"
	_road_body.collision_layer = 1
	_road_body.collision_mask = 0
	# 低摩擦物理材质: 防止车球卡在 Box 边缘
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = 0.1
	phys_mat.bounce = 0.0
	_road_body.physics_material_override = phys_mat
	var box_interval: int = maxi(points.size() / 30, 2)  # 更密的 box (约30段)
	for bi in range(0, points.size() - 1, box_interval):
		var bi_end: int = mini(bi + box_interval, points.size() - 1)
		var bp0: Vector3 = points[bi]
		var bp1: Vector3 = points[bi_end]
		var b_center: Vector3 = (bp0 + bp1) * 0.5
		var b_dir: Vector3 = (bp1 - bp0)
		var mid_idx: int = (bi + bi_end) / 2
		var box_w: float = widths[mid_idx] if mid_idx < widths.size() else path_width
		var b_len: float = b_dir.length() + box_w * 0.6  # 加大 overlap 防卡缝
		if b_len < 0.01:
			continue
		b_dir = b_dir.normalized()
		var b_right: Vector3 = b_dir.cross(Vector3.UP).normalized()
		if b_right.length() < 0.01:
			b_right = Vector3.RIGHT
		var b_basis := Basis()
		b_basis.z = -b_dir
		b_basis.x = b_right
		b_basis.y = b_dir.cross(b_right).normalized()
		var bcol := CollisionShape3D.new()
		var bbox := BoxShape3D.new()
		bbox.size = Vector3(box_w, path_thickness + 0.1, b_len)
		bcol.shape = bbox
		bcol.transform = Transform3D(b_basis, b_center)
		_road_body.add_child(bcol)
	_road_body.add_child(_road_mesh)
	add_child(_road_body)

	# ---- 边缘发光条 ----
	if edge_glow > 0.01:
		var glow_mat := StandardMaterial3D.new()
		glow_mat.albedo_color = Color(0.9, 0.7, 0.2)
		glow_mat.emission_enabled = true
		glow_mat.emission = Color(0.9, 0.7, 0.2)
		glow_mat.emission_energy_multiplier = edge_glow
		# 左边缘 (使用逐点宽度)
		var el_pts: Array[Vector3] = []
		for i in range(points.size()):
			var w_i: float = widths[i] if i < widths.size() else path_width
			el_pts.append(points[i] - rights[i] * w_i * 0.5 + Vector3.UP * (path_thickness * 0.5 + 0.02))
		_edge_mesh_l = MeshInstance3D.new()
		_edge_mesh_l.mesh = _build_strip_mesh(el_pts, rights, 0.1, 0.0)
		_edge_mesh_l.material_override = glow_mat
		add_child(_edge_mesh_l)
		# 右边缘
		var er_pts: Array[Vector3] = []
		for i in range(points.size()):
			var w_i2: float = widths[i] if i < widths.size() else path_width
			er_pts.append(points[i] + rights[i] * w_i2 * 0.5 + Vector3.UP * (path_thickness * 0.5 + 0.02))
		_edge_mesh_r = MeshInstance3D.new()
		_edge_mesh_r.mesh = _build_strip_mesh(er_pts, rights, 0.1, 0.0)
		_edge_mesh_r.material_override = glow_mat
		add_child(_edge_mesh_r)

	# 坠落检测已移除 (掉下去不复位, 跟易碎窄道一致)

	# ---- 颜色限制区域 (color_mode > 0 时创建 Area3D 检测错色车) ----
	_color_area = null
	_excluded_cars.clear()
	if color_mode > 0:
		_color_area = Area3D.new()
		_color_area.name = "ColorRestrictArea"
		_color_area.collision_layer = 0
		_color_area.collision_mask = 2  # 检测车 (layer 2)
		_color_area.monitoring = true
		_color_area.monitorable = false
		# 覆盖整条路径的大 Box
		var area_col := CollisionShape3D.new()
		var area_box := BoxShape3D.new()
		var extent: Vector3 = end_offset.abs() + Vector3(path_width + 2.0, 5.0, path_width + 2.0)
		area_box.size = Vector3(maxf(extent.x, path_width + 4.0), 6.0, maxf(extent.z, 10.0))
		area_col.shape = area_box
		area_col.position = end_offset * 0.5 + Vector3(0.0, 2.0, 0.0)
		_color_area.add_child(area_col)
		add_child(_color_area)

	_update_handles()


## 构建一条 strip mesh (沿 center_points 路径, 宽度渐变, Y 抬高 y_offset)
## widths: 如果提供则逐点指定宽度(渐变); 为空则全用 width
func _build_strip_mesh(center_points: Array[Vector3], right_dirs: Array[Vector3], width: float, y_offset: float, widths: Array[float] = []) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n: int = center_points.size()
	for i in range(n):
		var w: float = widths[i] if i < widths.size() else width
		var half_w: float = w * 0.5
		var c: Vector3 = center_points[i] + Vector3.UP * y_offset
		var r: Vector3 = right_dirs[i] if i < right_dirs.size() else Vector3.RIGHT
		var left: Vector3 = c - r * half_w
		var right_pt: Vector3 = c + r * half_w
		var uv_v: float = float(i) / float(n - 1)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.0, uv_v))
		st.add_vertex(left)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(1.0, uv_v))
		st.add_vertex(right_pt)
	for i in range(n - 1):
		var bl: int = i * 2
		var br: int = i * 2 + 1
		var tl: int = (i + 1) * 2
		var tr: int = (i + 1) * 2 + 1
		st.add_index(bl)
		st.add_index(tl)
		st.add_index(br)
		st.add_index(br)
		st.add_index(tl)
		st.add_index(tr)
	st.generate_normals()
	return st.commit()


func _calc_bezier_points() -> Array[Vector3]:
	var p0 := Vector3.ZERO
	var p3 := end_offset
	var result: Array[Vector3] = []

	# Hermite 模式: 精确匹配两端切线方向 (由连接功能设置)
	if hermite_from_tan.length_squared() > 0.001:
		var dist: float = p3.length()
		var m0: Vector3 = hermite_from_tan * dist
		var m1: Vector3 = hermite_to_tan * dist
		for i in range(segment_count + 1):
			var t: float = float(i) / float(segment_count)
			var t2: float = t * t
			var t3: float = t2 * t
			var h00: float = 2.0*t3 - 3.0*t2 + 1.0
			var h10: float = t3 - 2.0*t2 + t
			var h01: float = -2.0*t3 + 3.0*t2
			var h11: float = t3 - t2
			result.append(h00*p0 + h10*m0 + h01*p3 + h11*m1)
		return result

	# 三次贝塞尔 (curve_offset_end 非零)
	if curve_offset_end.length_squared() > 0.001:
		var p1: Vector3 = curve_offset
		var p2: Vector3 = p3 + curve_offset_end
		for i in range(segment_count + 1):
			var t: float = float(i) / float(segment_count)
			var omt: float = 1.0 - t
			result.append(omt*omt*omt * p0 + 3.0*omt*omt*t * p1 + 3.0*omt*t*t * p2 + t*t*t * p3)
		return result

	# 二次贝塞尔 (默认/兼容旧数据)
	var mid: Vector3 = (p0 + p3) * 0.5 + curve_offset
	for i in range(segment_count + 1):
		var t: float = float(i) / float(segment_count)
		var omt: float = 1.0 - t
		result.append(omt * omt * p0 + 2.0 * omt * t * mid + t * t * p3)
	return result





# ============================================================
#  控制点手柄
# ============================================================
func show_handles() -> void:
	if _handle_start == null:
		_create_handles()
	_handles_visible = true
	if _handle_start: _handle_start.visible = true
	if _handle_mid: _handle_mid.visible = true
	if _handle_end: _handle_end.visible = true
	if _handle_lines: _handle_lines.visible = true


func hide_handles() -> void:
	_handles_visible = false
	if _handle_start: _handle_start.visible = false
	if _handle_mid: _handle_mid.visible = false
	if _handle_end: _handle_end.visible = false
	if _handle_lines: _handle_lines.visible = false


func _create_handles() -> void:
	_handle_start = _make_handle_sphere(Color(0.2, 0.9, 0.2), "HandleStart")
	_handle_mid = _make_handle_sphere(Color(0.9, 0.9, 0.2), "HandleMid")
	_handle_end = _make_handle_sphere(Color(0.9, 0.2, 0.2), "HandleEnd")
	add_child(_handle_start)
	add_child(_handle_mid)
	add_child(_handle_end)
	_handle_lines = Node3D.new()
	_handle_lines.name = "HandleLines"
	add_child(_handle_lines)
	_update_handles()


func _make_handle_sphere(color: Color, handle_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = handle_name
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.5
	sm.height = 3.0
	sm.radial_segments = 16
	sm.rings = 8
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 0.8)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5
	mi.material_override = mat
	root.add_child(mi)
	root.visible = false
	return root


func _update_handles() -> void:
	if _handle_start == null:
		return
	# 手柄球抬高到路面上方 2m, 方便点击且不被路面遮挡
	var handle_y_lift := Vector3(0.0, 2.0, 0.0)
	_handle_start.position = Vector3.ZERO + handle_y_lift
	_handle_end.position = end_offset + handle_y_lift
	_handle_mid.position = end_offset * 0.5 + curve_offset + handle_y_lift
	if _handle_lines:
		for c in _handle_lines.get_children():
			c.queue_free()
		_draw_handle_line(_handle_start.position, _handle_mid.position, Color(0.5, 0.9, 0.5, 0.6))
		_draw_handle_line(_handle_mid.position, _handle_end.position, Color(0.9, 0.5, 0.5, 0.6))


func _draw_handle_line(from: Vector3, to: Vector3, color: Color) -> void:
	var length: float = from.distance_to(to)
	if length < 0.01:
		return
	var mid_pos: Vector3 = (from + to) * 0.5
	var dir: Vector3 = (to - from).normalized()
	var mi := MeshInstance3D.new()
	var cmesh := CylinderMesh.new()
	cmesh.top_radius = 0.04
	cmesh.bottom_radius = 0.04
	cmesh.height = length
	cmesh.radial_segments = 4
	mi.mesh = cmesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b)
	mat.emission_energy_multiplier = 0.8
	mi.material_override = mat
	mi.position = mid_pos
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.RIGHT
	mi.look_at_from_position(mid_pos, mid_pos + dir, up)
	mi.rotation.x += deg_to_rad(90)
	_handle_lines.add_child(mi)


# ============================================================
#  端点接口 (供 TrackEditor 吸附 + 连接)
# ============================================================
func get_start_width() -> float:
	return path_width

func get_end_width() -> float:
	return end_width if end_width > 0.0 else path_width

func get_start_world_pos() -> Vector3:
	return global_position

func get_end_world_pos() -> Vector3:
	return global_position + global_transform.basis * end_offset

func get_nearest_endpoint(world_pos: Vector3) -> String:
	var d_start: float = world_pos.distance_to(get_start_world_pos())
	var d_end: float = world_pos.distance_to(get_end_world_pos())
	return "start" if d_start < d_end else "end"

## 获取末端的切线方向 (世界坐标, 归一化) — 贝塞尔曲线在 t=1 的切线
func get_end_tangent_world() -> Vector3:
	var p3 := end_offset
	var tangent_local: Vector3
	if curve_offset_end.length_squared() > 0.001:
		# 三次贝塞尔: B'(1) = 3(P3-P2), P2 = p3 + curve_offset_end
		var p2: Vector3 = p3 + curve_offset_end
		tangent_local = (p3 - p2).normalized()
	else:
		# 二次贝塞尔: B'(1) = 2(P2-P1)
		var p1: Vector3 = end_offset * 0.5 + curve_offset
		tangent_local = (p3 - p1).normalized()
	if tangent_local.length() < 0.001:
		tangent_local = end_offset.normalized()
	return (global_transform.basis * tangent_local).normalized()

## 获取首端的切线方向 (世界坐标, 归一化) — 贝塞尔曲线在 t=0 的切线
func get_start_tangent_world() -> Vector3:
	var tangent_local: Vector3
	if curve_offset_end.length_squared() > 0.001:
		# 三次贝塞尔: B'(0) = 3(P1-P0), P1 = curve_offset
		tangent_local = curve_offset.normalized()
	else:
		# 二次贝塞尔: B'(0) = 2(P1-P0)
		var p1: Vector3 = end_offset * 0.5 + curve_offset
		tangent_local = p1.normalized()
	if tangent_local.length() < 0.001:
		tangent_local = end_offset.normalized()
	return (global_transform.basis * tangent_local).normalized()


# ============================================================
#  手柄拖拽接口
# ============================================================
func pick_handle_at(ray_origin: Vector3, ray_dir: Vector3) -> String:
	if not _handles_visible:
		return ""
	# 根据相机距离动态放大命中半径 (远看时球在屏幕上很小, 需要更大容差)
	var cam_dist: float = ray_origin.distance_to(global_position)
	var hit_radius: float = clampf(cam_dist * 0.04, 1.5, 8.0)
	var best: String = ""
	var best_dist: float = hit_radius + 1.0
	var handles: Array = [
		["start", _handle_start],
		["mid", _handle_mid],
		["end", _handle_end],
	]
	for pair in handles:
		var hname: String = pair[0]
		var h: Node3D = pair[1]
		if h == null or not h.visible:
			continue
		var h_pos: Vector3 = h.global_position
		var to_h: Vector3 = h_pos - ray_origin
		var proj: float = to_h.dot(ray_dir)
		if proj < 0.0:
			continue
		var closest: Vector3 = ray_origin + ray_dir * proj
		var dist: float = closest.distance_to(h_pos)
		if dist < hit_radius and dist < best_dist:
			best_dist = dist
			best = hname
	return best


func move_handle_to(handle_name: String, world_pos: Vector3) -> void:
	var local_pos: Vector3 = global_transform.affine_inverse() * world_pos
	match handle_name:
		"start":
			# 移动起点但保持终点世界位置不变 (调整 end_offset 补偿)
			var old_end_world: Vector3 = get_end_world_pos()
			var old_mid_world: Vector3 = global_position + global_transform.basis * (end_offset * 0.5 + curve_offset)
			global_position = world_pos
			# 终点和中间控制点的世界位置不变, 反算新的本地偏移
			end_offset = global_transform.affine_inverse() * old_end_world
			var new_mid_local: Vector3 = global_transform.affine_inverse() * old_mid_world
			curve_offset = new_mid_local - end_offset * 0.5
		"end":
			end_offset = local_pos
		"mid":
			curve_offset = local_pos - end_offset * 0.5
	_rebuild()


func reset_state() -> void:
	pass


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "color_mode", "label": "颜色限制(0通用/1红/2蓝)", "min": 0.0, "max": 2.0, "step": 1.0, "value": float(color_mode)},
		{"key": "path_width", "label": "起点宽度(m)", "min": 2.0, "max": 15.0, "step": 0.5, "value": path_width},
		{"key": "end_width", "label": "终点宽度(m)(0=同起点)", "min": 0.0, "max": 15.0, "step": 0.5, "value": end_width},
		{"key": "path_thickness", "label": "路面厚度(m)", "min": 0.1, "max": 2.0, "step": 0.1, "value": path_thickness},
		{"key": "end_offset_x", "label": "终点X偏移(m)", "min": -80.0, "max": 80.0, "step": 1.0, "value": end_offset.x},
		{"key": "end_offset_y", "label": "终点Y偏移(m)", "min": -40.0, "max": 40.0, "step": 1.0, "value": end_offset.y},
		{"key": "end_offset_z", "label": "终点Z偏移(m)", "min": -100.0, "max": 100.0, "step": 1.0, "value": end_offset.z},
		{"key": "curve_offset_x", "label": "起点切线X(m)", "min": -40.0, "max": 40.0, "step": 0.5, "value": curve_offset.x},
		{"key": "curve_offset_y", "label": "起点切线Y(m)", "min": -20.0, "max": 20.0, "step": 0.5, "value": curve_offset.y},
		{"key": "curve_offset_z", "label": "起点切线Z(m)", "min": -40.0, "max": 40.0, "step": 0.5, "value": curve_offset.z},
		{"key": "curve_offset_end_x", "label": "终点切线X(m)", "min": -40.0, "max": 40.0, "step": 0.5, "value": curve_offset_end.x},
		{"key": "curve_offset_end_y", "label": "终点切线Y(m)", "min": -20.0, "max": 20.0, "step": 0.5, "value": curve_offset_end.y},
		{"key": "curve_offset_end_z", "label": "终点切线Z(m)", "min": -40.0, "max": 40.0, "step": 0.5, "value": curve_offset_end.z},
		{"key": "segment_count", "label": "分段数", "min": 12.0, "max": 120.0, "step": 1.0, "value": float(segment_count)},
		{"key": "edge_glow", "label": "边缘发光强度", "min": 0.0, "max": 2.0, "step": 0.1, "value": edge_glow},
		# Hermite 切线 (连接道序列化用, UI 隐藏)
		{"key": "hermite_from_tan_x", "label": "", "min": -99.0, "max": 99.0, "step": 0.1, "value": hermite_from_tan.x, "hidden": true},
		{"key": "hermite_from_tan_y", "label": "", "min": -99.0, "max": 99.0, "step": 0.1, "value": hermite_from_tan.y, "hidden": true},
		{"key": "hermite_from_tan_z", "label": "", "min": -99.0, "max": 99.0, "step": 0.1, "value": hermite_from_tan.z, "hidden": true},
		{"key": "hermite_to_tan_x", "label": "", "min": -99.0, "max": 99.0, "step": 0.1, "value": hermite_to_tan.x, "hidden": true},
		{"key": "hermite_to_tan_y", "label": "", "min": -99.0, "max": 99.0, "step": 0.1, "value": hermite_to_tan.y, "hidden": true},
		{"key": "hermite_to_tan_z", "label": "", "min": -99.0, "max": 99.0, "step": 0.1, "value": hermite_to_tan.z, "hidden": true},
	]


var _rebuild_pending: bool = false

func set_editable_param(key: String, value: float) -> void:
	match key:
		"color_mode": color_mode = int(value)
		"path_width": path_width = value
		"end_width": end_width = value
		"path_thickness": path_thickness = value
		"end_offset_x": end_offset.x = value
		"end_offset_y": end_offset.y = value
		"end_offset_z": end_offset.z = value
		"curve_offset_x": curve_offset.x = value
		"curve_offset_y": curve_offset.y = value
		"curve_offset_z": curve_offset.z = value
		"curve_offset_end_x": curve_offset_end.x = value
		"curve_offset_end_y": curve_offset_end.y = value
		"curve_offset_end_z": curve_offset_end.z = value
		"segment_count": segment_count = int(value)
		"edge_glow": edge_glow = value
		"hermite_from_tan_x": hermite_from_tan.x = value
		"hermite_from_tan_y": hermite_from_tan.y = value
		"hermite_from_tan_z": hermite_from_tan.z = value
		"hermite_to_tan_x": hermite_to_tan.x = value
		"hermite_to_tan_y": hermite_to_tan.y = value
		"hermite_to_tan_z": hermite_to_tan.z = value

	if not _rebuild_pending:
		_rebuild_pending = true
		call_deferred("_deferred_rebuild")

func _deferred_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()
