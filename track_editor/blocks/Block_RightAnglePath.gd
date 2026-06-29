extends Node3D
class_name Block_RightAnglePath
## ============================================================
##  直角窄道 (Right Angle Path) — 折线段路径
## ============================================================
## 由多个节点组成的折线路径, 相邻节点间为直线段, 转角处为直角.
## 玩家可动态新增/删除节点, 自动生成方方正正的矩形赛道.
## ============================================================

@export_group("路面")
@export_range(2.0, 15.0, 0.5) var path_width: float = 4.0
@export_range(0.1, 2.0, 0.1) var path_thickness: float = 0.3

@export_group("视觉")
@export var road_color: Color = Color(0.35, 0.35, 0.4)
@export var rail_color: Color = Color(0.2, 0.6, 0.9)
@export_range(0.0, 2.0, 0.1) var edge_glow: float = 0.5

@export_group("墙壁")
@export_range(0.0, 5.0, 0.1) var wall_height: float = 0.0  ## 默认0=无墙
@export_range(0.1, 1.0, 0.05) var wall_thickness: float = 0.3
@export var wall_color: Color = Color(0.2, 0.5, 0.9, 0.45)  ## 半透明蓝色
@export_range(0.0, 2.0, 0.1) var wall_emission: float = 0.6

@export_group("节点")
## 节点坐标列表 (本地空间, 第一个点固定为 Vector3.ZERO)
@export var waypoints: Array[Vector3] = [
	Vector3(0.0, 0.0, 0.0),
	Vector3(0.0, 0.0, -20.0),
	Vector3(15.0, 0.0, -20.0),
	Vector3(15.0, 0.0, -40.0),
]

# ---- 内部 ----
var _road_body: StaticBody3D = null
var _road_mesh: MeshInstance3D = null
var _edge_mesh_l: MeshInstance3D = null
var _edge_mesh_r: MeshInstance3D = null
# 墙壁系统
var _wall_curve_left: WallCurve = null
var _wall_curve_right: WallCurve = null
var _handles: Array[Node3D] = []
var _handle_lines: Node3D = null
var _handles_visible: bool = false
var _corner_meshes: Array[MeshInstance3D] = []


func _ready() -> void:
	if _wall_curve_left == null:
		_wall_curve_left = WallCurve.new()
	if _wall_curve_right == null:
		_wall_curve_right = WallCurve.new()
	_rebuild()


func _is_in_editor() -> bool:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return false
	return scene.name == "TrackEditor" or scene.has_method("_place_at_mouse")


func _rebuild() -> void:
	# 保留手柄节点
	var keep_set: Array = []
	for h in _handles:
		keep_set.append(h)
	if _handle_lines:
		keep_set.append(_handle_lines)
	for c in get_children():
		if c in keep_set:
			continue
		remove_child(c)
		c.queue_free()
	_road_body = null
	_road_mesh = null
	_edge_mesh_l = null
	_edge_mesh_r = null
	_corner_meshes.clear()

	if waypoints.size() < 2:
		return

	# 确保第一个点是原点
	waypoints[0] = Vector3.ZERO

	# 构建所有路段点 (直线段 + 转角处插入圆角或直角补面)
	var all_segments: Array[Dictionary] = _build_segments()
	if all_segments.is_empty():
		return

	# 路面材质
	var road_mat := StandardMaterial3D.new()
	road_mat.albedo_color = road_color
	road_mat.metallic = 0.3
	road_mat.roughness = 0.7

	# 构建路面 mesh
	_road_body = StaticBody3D.new()
	_road_body.name = "RoadBody"
	_road_body.collision_layer = 1
	_road_body.collision_mask = 0
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = 0.1
	phys_mat.bounce = 0.0
	_road_body.physics_material_override = phys_mat

	# 每段直线路面
	for seg in all_segments:
		var from: Vector3 = seg["from"]
		var to: Vector3 = seg["to"]
		_add_straight_segment(from, to, road_mat)

	# 转角处补面 (方形填充)
	for i in range(1, waypoints.size() - 1):
		_add_corner_fill(waypoints[i - 1], waypoints[i], waypoints[i + 1], road_mat)

	add_child(_road_body)

	# 墙壁生成
	_build_walls(all_segments)

	# 边缘发光 (仅编辑器显示, 游戏中不显示)
	if edge_glow > 0.01 and _is_in_editor():
		_build_edge_glow(all_segments)

	_update_handles()


## 构建直线段列表
func _build_segments() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in range(waypoints.size() - 1):
		result.append({"from": waypoints[i], "to": waypoints[i + 1]})
	return result


## 添加一段直线路面 (矩形)
func _add_straight_segment(from: Vector3, to: Vector3, mat: StandardMaterial3D) -> void:
	var dir: Vector3 = to - from
	var seg_len: float = dir.length()
	if seg_len < 0.01:
		return
	dir = dir.normalized()
	var right: Vector3 = dir.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT

	# 路面 mesh (矩形 quad)
	var mi := MeshInstance3D.new()
	mi.mesh = _build_quad_mesh(from, to, right, path_width, 0.0)
	mi.material_override = mat
	_road_body.add_child(mi)

	# 碰撞体 (BoxShape3D)
	var center: Vector3 = (from + to) * 0.5
	var bcol := CollisionShape3D.new()
	var bbox := BoxShape3D.new()
	bbox.size = Vector3(path_width, path_thickness + 0.1, seg_len)
	bcol.shape = bbox
	var b_basis := Basis()
	b_basis.z = -dir
	b_basis.x = right
	b_basis.y = dir.cross(right).normalized()
	bcol.transform = Transform3D(b_basis, center)
	_road_body.add_child(bcol)


## 构建矩形路面 mesh
func _build_quad_mesh(from: Vector3, to: Vector3, right: Vector3, width: float, y_offset: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_w: float = width * 0.5
	var y_up := Vector3(0.0, y_offset, 0.0)
	var fl: Vector3 = from - right * half_w + y_up
	var fr: Vector3 = from + right * half_w + y_up
	var tl: Vector3 = to - right * half_w + y_up
	var tr: Vector3 = to + right * half_w + y_up

	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(fl)
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(fr)
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(tl)
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(tr)

	st.add_index(0)
	st.add_index(2)
	st.add_index(1)
	st.add_index(1)
	st.add_index(2)
	st.add_index(3)
	return st.commit()


## 转角处填充补面 — 用外轮廓交点构建完整覆盖的多边形
## 原理: 拐角区域 = 入段末端宽度条 ∪ 出段起点宽度条 的并集
## 实现: 找到左/右两侧的外角交点, 与入段/出段的4个边缘点一起构成凸多边形
func _add_corner_fill(prev: Vector3, corner: Vector3, next: Vector3, mat: StandardMaterial3D) -> void:
	var dir_in: Vector3 = (corner - prev).normalized()
	var dir_out: Vector3 = (next - corner).normalized()
	var right_in: Vector3 = dir_in.cross(Vector3.UP).normalized()
	var right_out: Vector3 = dir_out.cross(Vector3.UP).normalized()
	if right_in.length_squared() < 0.01:
		right_in = Vector3.RIGHT
	if right_out.length_squared() < 0.01:
		right_out = Vector3.RIGHT

	var half_w: float = path_width * 0.5
	# 入段末端边缘
	var in_left: Vector3 = corner - right_in * half_w
	var in_right: Vector3 = corner + right_in * half_w
	# 出段起点边缘
	var out_left: Vector3 = corner - right_out * half_w
	var out_right: Vector3 = corner + right_out * half_w
	# 左侧外角交点
	var outer_left: Vector3 = _line_intersection_xz(in_left, dir_in, out_left, dir_out)
	if outer_left == Vector3.INF:
		outer_left = in_left
	else:
		outer_left.y = corner.y
	# 右侧外角交点
	var outer_right: Vector3 = _line_intersection_xz(in_right, dir_in, out_right, dir_out)
	if outer_right == Vector3.INF:
		outer_right = in_right
	else:
		outer_right.y = corner.y

	# 构建两个三角形覆盖整个拐角:
	# 三角形1: corner, in_left, out_left (内侧)
	# 三角形2: corner, in_right, out_right (内侧)
	# 三角形3: corner, in_left, in_right (入段端面)
	# 三角形4: corner, out_left, out_right (出段端面)
	# 三角形5: corner, outer_left, in_left or out_left (外角左)
	# 三角形6: corner, outer_right, in_right or out_right (外角右)
	# 简化: 直接用 6 个边缘点 + corner 做扇形, 但用正确的凸包顺序

	# 最可靠的方式: 两个大 quad 覆盖拐角
	# Quad A: in_left, in_right, out_left, out_right (原来的四边形)
	# Quad B (外角): corner 到外角交点的三角形

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 用 4 个三角形从 corner 辐射到 4 个边缘点 + 2 个外角点
	var fan_pts: Array[Vector3] = []
	fan_pts.append(in_left)
	# 左外角: 只有当 outer_left 不在 in_left 和 out_left 之间时才加
	if outer_left.distance_to(in_left) > 0.5 and outer_left.distance_to(out_left) > 0.5:
		fan_pts.append(outer_left)
	fan_pts.append(out_left)
	fan_pts.append(out_right)
	if outer_right.distance_to(in_right) > 0.5 and outer_right.distance_to(out_right) > 0.5:
		fan_pts.append(outer_right)
	fan_pts.append(in_right)

	# 三角扇形 center = corner
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(0.5, 0.5))
	st.add_vertex(corner)
	for i in range(fan_pts.size()):
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.0, 0.0))
		st.add_vertex(fan_pts[i])
	for i in range(fan_pts.size()):
		var ni: int = (i + 1) % fan_pts.size()
		st.add_index(0)
		st.add_index(i + 1)
		st.add_index(ni + 1)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	_road_body.add_child(mi)

	# 转角碰撞体 (方形 box)
	var bcol := CollisionShape3D.new()
	var bbox := BoxShape3D.new()
	bbox.size = Vector3(path_width, path_thickness + 0.1, path_width)
	bcol.shape = bbox
	bcol.position = corner
	_road_body.add_child(bcol)


## 生成墙壁 — 用 offset polygon 算法计算连续外轮廓线
## 核心: 先算出左/右的完整轮廓点序列 (在拐角处用线段交点而不是简单偏移)
## 然后沿轮廓线生成一整面连续的墙壁 strip
func _build_walls(_segments_unused: Array[Dictionary]) -> void:
	if wall_height < 0.01:
		return
	if _wall_curve_left == null:
		_wall_curve_left = WallCurve.new()
	if _wall_curve_right == null:
		_wall_curve_right = WallCurve.new()

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = wall_color
	wall_mat.metallic = 0.4
	wall_mat.roughness = 0.3
	wall_mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # 双面渲染
	if wall_color.a < 0.99:
		wall_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if wall_emission > 0.01:
		wall_mat.emission_enabled = true
		wall_mat.emission = Color(wall_color.r, wall_color.g, wall_color.b)
		wall_mat.emission_energy_multiplier = wall_emission

	if waypoints.size() < 2:
		return

	var half_w: float = path_width * 0.5
	# 计算左右完整轮廓点序列
	var left_outline: Array[Vector3] = _compute_offset_outline(-1.0, half_w)
	var right_outline: Array[Vector3] = _compute_offset_outline(1.0, half_w)

	# 计算轮廓线累积长度 (用于 t 映射)
	var left_cum: Array[float] = _compute_cum_lengths(left_outline)
	var right_cum: Array[float] = _compute_cum_lengths(right_outline)
	var left_total: float = left_cum[left_cum.size() - 1] if left_cum.size() > 0 else 0.0
	var right_total: float = right_cum[right_cum.size() - 1] if right_cum.size() > 0 else 0.0

	# 左墙
	if left_total > 0.1:
		for wall_seg in _wall_curve_left.get_wall_segments():
			_build_wall_strip_from_outline(left_outline, left_cum, left_total, float(wall_seg["from_t"]), float(wall_seg["to_t"]), -1.0, wall_mat)
	# 右墙
	if right_total > 0.1:
		for wall_seg in _wall_curve_right.get_wall_segments():
			_build_wall_strip_from_outline(right_outline, right_cum, right_total, float(wall_seg["from_t"]), float(wall_seg["to_t"]), 1.0, wall_mat)

	# 编辑器标记
	if _is_in_editor():
		if left_total > 0.1:
			_build_wall_markers_outline(left_outline, left_cum, left_total, _wall_curve_left)
		if right_total > 0.1:
			_build_wall_markers_outline(right_outline, right_cum, right_total, _wall_curve_right)


## 计算一侧的 offset 轮廓线 (side: -1=左, +1=右)
## 在拐角处: 外角用两段偏移线的交点, 内角直接用拐角点偏移
func _compute_offset_outline(side: float, offset: float) -> Array[Vector3]:
	var outline: Array[Vector3] = []
	var seg_count: int = waypoints.size() - 1
	if seg_count < 1:
		return outline

	# 每段的方向和 right
	var dirs: Array[Vector3] = []
	var normals: Array[Vector3] = []  # normal = right × side (偏移方向)
	for si in range(seg_count):
		var d: Vector3 = ((waypoints[si + 1] as Vector3) - (waypoints[si] as Vector3)).normalized()
		dirs.append(d)
		var r: Vector3 = d.cross(Vector3.UP).normalized()
		if r.length_squared() < 0.01:
			r = Vector3.RIGHT
		normals.append(r * side)

	# 第一个点: 起点偏移
	outline.append((waypoints[0] as Vector3) + normals[0] * offset)

	# 中间拐角点: 求前后两段偏移线的交点 (2D, Y 忽略)
	for ci in range(1, waypoints.size() - 1):
		var corner: Vector3 = waypoints[ci] as Vector3
		var n_prev: Vector3 = normals[ci - 1]
		var n_next: Vector3 = normals[ci]
		var d_prev: Vector3 = dirs[ci - 1]
		var d_next: Vector3 = dirs[ci]
		# 前段偏移线: P = corner + n_prev*offset, 方向 d_prev (从前段终点出发)
		# 后段偏移线: Q = corner + n_next*offset, 方向 d_next (从后段起点出发)
		var p0: Vector3 = corner + n_prev * offset
		var q0: Vector3 = corner + n_next * offset
		# 在 XZ 平面求两条射线交点 (忽略 Y)
		var intersection: Vector3 = _line_intersection_xz(p0, d_prev, q0, -d_next)
		if intersection != Vector3.INF:
			intersection.y = corner.y  # 保持同一高度
			outline.append(intersection)
		else:
			# 平行 (180° 调头), fallback 用简单偏移
			outline.append(corner + n_prev * offset)

	# 最后一个点: 终点偏移
	outline.append((waypoints[waypoints.size() - 1] as Vector3) + normals[seg_count - 1] * offset)
	return outline


## XZ 平面两射线交点: ray1 = p + t*d1, ray2 = q + s*d2
## 返回交点或 Vector3.INF (平行)
func _line_intersection_xz(p: Vector3, d1: Vector3, q: Vector3, d2: Vector3) -> Vector3:
	# 2D: 解 p.x + t*d1.x = q.x + s*d2.x, p.z + t*d1.z = q.z + s*d2.z
	var det: float = d1.x * d2.z - d1.z * d2.x
	if absf(det) < 0.0001:
		return Vector3.INF  # 平行
	var dx: float = q.x - p.x
	var dz: float = q.z - p.z
	var t: float = (dx * d2.z - dz * d2.x) / det
	return Vector3(p.x + t * d1.x, p.y, p.z + t * d1.z)


## 计算点序列的累积长度
func _compute_cum_lengths(pts: Array[Vector3]) -> Array[float]:
	var cum: Array[float] = [0.0]
	for i in range(1, pts.size()):
		cum.append(cum[i - 1] + pts[i].distance_to(pts[i - 1]))
	return cum


## 沿轮廓线在 [from_t, to_t] 区间生成墙壁 strip
func _build_wall_strip_from_outline(outline: Array[Vector3], cum: Array[float], total_len: float, from_t: float, to_t: float, side: float, mat: StandardMaterial3D) -> void:
	var n: int = outline.size()
	if n < 2:
		return
	# 找 t 对应的点索引区间
	var i_start: int = _find_index_at_t(cum, total_len, from_t)
	var i_end: int = _find_index_at_t(cum, total_len, to_t)
	if i_end <= i_start:
		i_end = i_start + 1
	i_end = mini(i_end, n - 1)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(i_start, i_end + 1):
		var edge: Vector3 = outline[i]
		var bottom: Vector3 = edge + Vector3(0.0, path_thickness * 0.5, 0.0)
		var top: Vector3 = bottom + Vector3(0.0, wall_height, 0.0)
		# 法线: 指向外侧 (用前后点差算切线→cross UP)
		var tangent: Vector3
		if i < n - 1:
			tangent = (outline[i + 1] - outline[i]).normalized()
		else:
			tangent = (outline[i] - outline[i - 1]).normalized()
		var normal: Vector3 = tangent.cross(Vector3.UP).normalized() * side
		if normal.length_squared() < 0.01:
			normal = Vector3.RIGHT * side
		var uv_v: float = float(i - i_start) / maxf(float(i_end - i_start), 1.0)
		st.set_normal(normal)
		st.set_uv(Vector2(0.0, uv_v))
		st.add_vertex(bottom)
		st.set_normal(normal)
		st.set_uv(Vector2(1.0, uv_v))
		st.add_vertex(top)
	var vert_count: int = i_end - i_start + 1
	for i in range(vert_count - 1):
		var bl: int = i * 2
		var tl: int = i * 2 + 1
		var br: int = (i + 1) * 2
		var tr: int = (i + 1) * 2 + 1
		if side > 0.0:
			st.add_index(bl); st.add_index(br); st.add_index(tl)
			st.add_index(tl); st.add_index(br); st.add_index(tr)
		else:
			st.add_index(bl); st.add_index(tl); st.add_index(br)
			st.add_index(tl); st.add_index(tr); st.add_index(br)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	add_child(mi)

	# 碰撞: 整段一个 box
	if _road_body and i_end > i_start:
		var p0: Vector3 = outline[i_start]
		var p1: Vector3 = outline[i_end]
		var wall_center: Vector3 = (p0 + p1) * 0.5 + Vector3(0.0, path_thickness * 0.5 + wall_height * 0.5, 0.0)
		var wall_len: float = p0.distance_to(p1)
		if wall_len > 0.1:
			var wall_dir: Vector3 = (p1 - p0).normalized()
			var bcol := CollisionShape3D.new()
			var bbox := BoxShape3D.new()
			bbox.size = Vector3(wall_thickness, wall_height, wall_len)
			bcol.shape = bbox
			var b_r: Vector3 = wall_dir.cross(Vector3.UP).normalized()
			if b_r.length() < 0.01:
				b_r = Vector3.RIGHT
			var b_basis := Basis()
			b_basis.z = -wall_dir
			b_basis.x = b_r
			b_basis.y = wall_dir.cross(b_r).normalized()
			bcol.transform = Transform3D(b_basis, wall_center)
			_road_body.add_child(bcol)


func _find_index_at_t(cum: Array[float], total_len: float, t: float) -> int:
	var target: float = t * total_len
	for i in range(1, cum.size()):
		if cum[i] >= target:
			return maxi(i - 1, 0)
	return cum.size() - 1


## 编辑器: 墙壁节点标记 (沿轮廓线定位)
func _build_wall_markers_outline(outline: Array[Vector3], cum: Array[float], total_len: float, curve: WallCurve) -> void:
	for node_data in curve.nodes:
		var t: float = float(node_data["t"])
		var active: bool = bool(node_data["active"])
		var i: int = _find_index_at_t(cum, total_len, t)
		var pos: Vector3 = outline[i] if i < outline.size() else Vector3.ZERO
		pos.y += path_thickness * 0.5 + wall_height + 0.5

		var marker := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(0.6, 0.6, 0.6)
		marker.mesh = box_mesh
		var mmat := StandardMaterial3D.new()
		if active:
			mmat.albedo_color = Color(0.1, 0.9, 0.2, 0.85)
			mmat.emission_enabled = true
			mmat.emission = Color(0.1, 0.9, 0.2)
			mmat.emission_energy_multiplier = 1.5
		else:
			mmat.albedo_color = Color(0.9, 0.15, 0.1, 0.85)
			mmat.emission_enabled = true
			mmat.emission = Color(0.9, 0.15, 0.1)
			mmat.emission_energy_multiplier = 1.5
		mmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		marker.material_override = mmat
		marker.position = pos
		add_child(marker)





## 获取左/右墙壁曲线
func get_wall_curve_left() -> WallCurve:
	if _wall_curve_left == null:
		_wall_curve_left = WallCurve.new()
	return _wall_curve_left

func get_wall_curve_right() -> WallCurve:
	if _wall_curve_right == null:
		_wall_curve_right = WallCurve.new()
	return _wall_curve_right

func wall_add_node(side: String, t: float, active: bool = true) -> void:
	var curve: WallCurve = _wall_curve_left if side == "left" else _wall_curve_right
	curve.add_node(t, active)
	_rebuild()

func wall_remove_node(side: String, index: int) -> void:
	var curve: WallCurve = _wall_curve_left if side == "left" else _wall_curve_right
	curve.remove_node(index)
	_rebuild()

func wall_toggle_node(side: String, index: int) -> void:
	var curve: WallCurve = _wall_curve_left if side == "left" else _wall_curve_right
	curve.toggle_node(index)
	_rebuild()

func wall_move_node(side: String, index: int, new_t: float) -> void:
	var curve: WallCurve = _wall_curve_left if side == "left" else _wall_curve_right
	curve.move_node(index, new_t)
	_rebuild()


## 边缘发光线
func _build_edge_glow(segments: Array[Dictionary]) -> void:
	var glow_mat := StandardMaterial3D.new()
	glow_mat.albedo_color = Color(0.2, 0.6, 0.9)
	glow_mat.emission_enabled = true
	glow_mat.emission = Color(0.2, 0.6, 0.9)
	glow_mat.emission_energy_multiplier = edge_glow
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.albedo_color.a = 0.8

	for seg in segments:
		var from: Vector3 = seg["from"]
		var to: Vector3 = seg["to"]
		var dir: Vector3 = (to - from).normalized()
		var right: Vector3 = dir.cross(Vector3.UP).normalized()
		if right.length_squared() < 0.01:
			right = Vector3.RIGHT
		var half_w: float = path_width * 0.5
		var y_lift := Vector3(0.0, path_thickness * 0.5 + 0.02, 0.0)
		# 左边缘
		var ml := MeshInstance3D.new()
		ml.mesh = _build_line_mesh(from - right * half_w + y_lift, to - right * half_w + y_lift, 0.08)
		ml.material_override = glow_mat
		add_child(ml)
		# 右边缘
		var mr := MeshInstance3D.new()
		mr.mesh = _build_line_mesh(from + right * half_w + y_lift, to + right * half_w + y_lift, 0.08)
		mr.material_override = glow_mat
		add_child(mr)


func _build_line_mesh(from: Vector3, to: Vector3, thickness: float) -> ArrayMesh:
	var dir: Vector3 = (to - from).normalized()
	var right: Vector3 = dir.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.01:
		right = Vector3.RIGHT
	var half_t: float = thickness * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(0.0, 0.0))
	st.add_vertex(from - right * half_t)
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(1.0, 0.0))
	st.add_vertex(from + right * half_t)
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(0.0, 1.0))
	st.add_vertex(to - right * half_t)
	st.set_normal(Vector3.UP)
	st.set_uv(Vector2(1.0, 1.0))
	st.add_vertex(to + right * half_t)
	st.add_index(0)
	st.add_index(2)
	st.add_index(1)
	st.add_index(1)
	st.add_index(2)
	st.add_index(3)
	return st.commit()


# ============================================================
#  节点增删
# ============================================================

## 在末尾添加一个新节点 (默认沿最后一段方向延伸 15m)
func add_waypoint() -> void:
	if waypoints.size() < 2:
		waypoints.append(Vector3(0.0, 0.0, -15.0))
	else:
		var last: Vector3 = waypoints[waypoints.size() - 1]
		var prev: Vector3 = waypoints[waypoints.size() - 2]
		var dir: Vector3 = (last - prev).normalized()
		# 自动转90度 (交替 X/Z)
		var new_dir: Vector3
		if absf(dir.x) > absf(dir.z):
			new_dir = Vector3(0.0, 0.0, -signf(dir.x) * 15.0)
		else:
			new_dir = Vector3(signf(dir.z) * 15.0, 0.0, 0.0)
		waypoints.append(last + new_dir)
	_rebuild()


## 删除最后一个节点 (至少保留2个)
func remove_last_waypoint() -> void:
	if waypoints.size() <= 2:
		return
	waypoints.pop_back()
	_rebuild()


## 在指定索引处插入节点 (中点)
func insert_waypoint_at(index: int) -> void:
	if index < 1 or index >= waypoints.size():
		return
	var mid: Vector3 = (waypoints[index - 1] + waypoints[index]) * 0.5
	waypoints.insert(index, mid)
	_rebuild()


## 删除指定索引的节点 (不能删首尾以外的最后一个)
func remove_waypoint_at(index: int) -> void:
	if waypoints.size() <= 2:
		return
	if index <= 0 or index >= waypoints.size():
		return
	waypoints.remove_at(index)
	_rebuild()


# ============================================================
#  手柄 (每个 waypoint 一个手柄球)
# ============================================================

func show_handles() -> void:
	if _handles.is_empty():
		_create_handles()
	_handles_visible = true
	for h in _handles:
		if h and is_instance_valid(h):
			h.visible = true
	if _handle_lines:
		_handle_lines.visible = true


func hide_handles() -> void:
	_handles_visible = false
	for h in _handles:
		if h and is_instance_valid(h):
			h.visible = false
	if _handle_lines:
		_handle_lines.visible = false


func _create_handles() -> void:
	for h in _handles:
		if h and is_instance_valid(h):
			h.queue_free()
	_handles.clear()
	for i in range(waypoints.size()):
		var color: Color
		if i == 0:
			color = Color(0.2, 0.9, 0.2)  # 绿=起点
		elif i == waypoints.size() - 1:
			color = Color(0.9, 0.2, 0.2)  # 红=终点
		else:
			color = Color(0.9, 0.9, 0.2)  # 黄=中间
		var h: Node3D = _make_handle_sphere(color, "Handle_%d" % i)
		add_child(h)
		_handles.append(h)
	if _handle_lines == null:
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
	# 确保手柄数量与 waypoints 一致
	if _handles.size() != waypoints.size():
		_create_handles()
		return
	var handle_y_lift := Vector3(0.0, 2.0, 0.0)
	for i in range(waypoints.size()):
		if i < _handles.size() and _handles[i] and is_instance_valid(_handles[i]):
			_handles[i].position = waypoints[i] + handle_y_lift
			_handles[i].visible = _handles_visible
	# 连线
	if _handle_lines:
		_handle_lines.visible = _handles_visible
		for c in _handle_lines.get_children():
			c.queue_free()
		if not _handles_visible:
			return
		for i in range(waypoints.size() - 1):
			_draw_handle_line(waypoints[i] + handle_y_lift, waypoints[i + 1] + handle_y_lift, Color(0.5, 0.7, 0.9, 0.6))


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
#  手柄拖拽接口 (供 TrackEditor 调用)
# ============================================================

## 在世界坐标 world_pos 位置寻找最近的手柄, 返回手柄索引 (-1=没找到)
func pick_handle_at(world_pos: Vector3, threshold: float = 4.0) -> int:
	var best_idx: int = -1
	var best_dist: float = threshold
	for i in range(_handles.size()):
		if i >= waypoints.size():
			break
		var handle_world: Vector3 = global_transform * (waypoints[i] + Vector3(0.0, 2.0, 0.0))
		var d: float = handle_world.distance_to(world_pos)
		if d < best_dist:
			best_dist = d
			best_idx = i
	return best_idx


## 移动指定手柄到新的世界坐标
func move_handle_to(handle_index: int, world_pos: Vector3) -> void:
	if handle_index < 0 or handle_index >= waypoints.size():
		return
	# 转换到本地坐标
	var local_pos: Vector3 = global_transform.affine_inverse() * world_pos
	# 第一个节点固定在原点
	if handle_index == 0:
		return
	waypoints[handle_index] = local_pos
	_rebuild()


# ============================================================
#  编辑器参数接口
# ============================================================

func get_editable_params() -> Array:
	var params: Array = [
		{"key": "path_width", "label": "路面宽度(m)", "min": 2.0, "max": 15.0, "step": 0.5, "value": path_width},
		{"key": "path_thickness", "label": "路面厚度(m)", "min": 0.1, "max": 2.0, "step": 0.1, "value": path_thickness},
		{"key": "edge_glow", "label": "边缘发光", "min": 0.0, "max": 2.0, "step": 0.1, "value": edge_glow},
		{"key": "wall_height", "label": "墙壁高度(m)", "min": 0.0, "max": 5.0, "step": 0.1, "value": wall_height},
		{"key": "wall_thickness", "label": "墙壁厚度(m)", "min": 0.1, "max": 1.0, "step": 0.05, "value": wall_thickness},
		{"key": "wall_emission", "label": "墙壁发光", "min": 0.0, "max": 2.0, "step": 0.1, "value": wall_emission},
		{"key": "wall_left_nodes", "label": "左墙节点数", "min": 2.0, "max": 20.0, "step": 1.0, "value": float(_wall_curve_left.nodes.size() if _wall_curve_left else 2)},
		{"key": "wall_right_nodes", "label": "右墙节点数", "min": 2.0, "max": 20.0, "step": 1.0, "value": float(_wall_curve_right.nodes.size() if _wall_curve_right else 2)},
		{"key": "waypoint_count", "label": "路径节点数", "min": 2.0, "max": 20.0, "step": 1.0, "value": float(waypoints.size())},
	]
	# 每个 waypoint 的 XYZ
	for i in range(waypoints.size()):
		if i == 0:
			continue  # 第一个点固定原点
		params.append({"key": "wp_%d_x" % i, "label": "节点%d X(m)" % i, "min": -100.0, "max": 100.0, "step": 1.0, "value": waypoints[i].x})
		params.append({"key": "wp_%d_y" % i, "label": "节点%d Y(m)" % i, "min": -50.0, "max": 50.0, "step": 0.5, "value": waypoints[i].y})
		params.append({"key": "wp_%d_z" % i, "label": "节点%d Z(m)" % i, "min": -100.0, "max": 100.0, "step": 1.0, "value": waypoints[i].z})
	return params


func set_editable_param(key: String, value: float) -> void:
	match key:
		"path_width": path_width = value
		"path_thickness": path_thickness = value
		"edge_glow": edge_glow = value
		"wall_height": wall_height = value
		"wall_thickness": wall_thickness = value
		"wall_emission": wall_emission = value
		"wall_left_nodes":
			var target_l: int = int(value)
			if _wall_curve_left:
				while _wall_curve_left.nodes.size() < target_l:
					var t_l: float = float(_wall_curve_left.nodes.size()) / float(target_l)
					_wall_curve_left.add_node(t_l, true)
				while _wall_curve_left.nodes.size() > target_l and _wall_curve_left.nodes.size() > 2:
					_wall_curve_left.remove_node(_wall_curve_left.nodes.size() - 2)
		"wall_right_nodes":
			var target_r2: int = int(value)
			if _wall_curve_right:
				while _wall_curve_right.nodes.size() < target_r2:
					var t_r2: float = float(_wall_curve_right.nodes.size()) / float(target_r2)
					_wall_curve_right.add_node(t_r2, true)
				while _wall_curve_right.nodes.size() > target_r2 and _wall_curve_right.nodes.size() > 2:
					_wall_curve_right.remove_node(_wall_curve_right.nodes.size() - 2)
		"waypoint_count":
			var target: int = int(value)
			while waypoints.size() < target:
				add_waypoint()
			while waypoints.size() > target and waypoints.size() > 2:
				remove_last_waypoint()
			return  # add/remove 已经 rebuild 了
		_:
			# wp_N_x / wp_N_y / wp_N_z
			if key.begins_with("wp_"):
				var parts: PackedStringArray = key.split("_")
				if parts.size() == 3:
					var idx: int = int(parts[1])
					var axis: String = parts[2]
					if idx > 0 and idx < waypoints.size():
						match axis:
							"x": waypoints[idx].x = value
							"y": waypoints[idx].y = value
							"z": waypoints[idx].z = value
	call_deferred("_deferred_rebuild")


func _deferred_rebuild() -> void:
	_rebuild()


# ============================================================
#  端点接口 (供 TrackEditor 吸附 / L键)
# ============================================================

func get_start_world_pos() -> Vector3:
	return global_position

func get_end_world_pos() -> Vector3:
	if waypoints.size() < 2:
		return global_position
	return global_position + global_transform.basis * waypoints[waypoints.size() - 1]

func get_start_width() -> float:
	return path_width

func get_end_width() -> float:
	return path_width

## 起点切线方向 (世界坐标, 归一化) — 第一段方向
func get_start_tangent_world() -> Vector3:
	if waypoints.size() < 2:
		return -global_transform.basis.z
	var dir_local: Vector3 = (waypoints[1] - waypoints[0]).normalized()
	return (global_transform.basis * dir_local).normalized()

## 终点切线方向 (世界坐标, 归一化) — 最后一段方向
func get_end_tangent_world() -> Vector3:
	if waypoints.size() < 2:
		return -global_transform.basis.z
	var n: int = waypoints.size()
	var dir_local: Vector3 = (waypoints[n - 1] - waypoints[n - 2]).normalized()
	return (global_transform.basis * dir_local).normalized()

## 获取路径中线点序列 (供 L 键生成绳星轨迹)
func _calc_bezier_points() -> Array[Vector3]:
	# 直角窄道没有贝塞尔, 直接返回 waypoints 作为路径点
	# 但每段中间插几个点让密度够
	var result: Array[Vector3] = []
	for i in range(waypoints.size() - 1):
		var from: Vector3 = waypoints[i]
		var to: Vector3 = waypoints[i + 1]
		var seg_len: float = from.distance_to(to)
		var num_sub: int = maxi(int(seg_len / 2.0), 1)
		for s in range(num_sub):
			var t: float = float(s) / float(num_sub)
			result.append(from.lerp(to, t))
	result.append(waypoints[waypoints.size() - 1])
	return result
