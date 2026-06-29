class_name Block_StarTrail
extends Node3D
## ============================================================
##  绳星轨迹 — 沿贝塞尔曲线均匀排列星星, 双人绳子碰到即收集
##
##  编辑器行为: 跟窄道一样可拖 start/mid/end 手柄拉出曲线
##  运行时行为:
##    · 星星沿曲线等距分布 (star_count 颗)
##    · 每颗星星有较大碰撞球 (star_collect_radius)
##    · CoopMode 每物理帧检测绳子路径是否穿过星星碰撞球
##    · 吃到后: 星星播放爆光动画 → 隐藏 → 通知全局计数
##    · 连击: 0.4s 内吃到下一颗 combo+1, 超时断连击
## ============================================================

@export_group("路径")
@export var end_offset: Vector3 = Vector3(0.0, 0.0, -30.0)
@export var curve_offset: Vector3 = Vector3(0.0, 0.0, 0.0)
@export var curve_offset_end: Vector3 = Vector3(0.0, 0.0, 0.0)
@export_range(12, 120, 1) var segment_count: int = 48

@export_group("星星")
@export_range(1, 50, 1) var star_count: int = 8
@export_range(0.5, 5.0, 0.1) var star_collect_radius: float = 2.5
@export_range(0.3, 3.0, 0.1) var star_visual_size: float = 0.6
@export_range(0.0, 10.0, 0.1) var star_height_offset: float = 1.5

@export_group("视觉")
@export var star_color: Color = Color(1.0, 0.9, 0.2, 1.0)
@export_range(0.0, 5.0, 0.1) var star_emission: float = 2.5
@export var trail_line_color: Color = Color(1.0, 0.85, 0.3, 0.4)
@export_range(-180.0, 180.0, 5.0) var star_rotation_x: float = -90.0
@export_range(-180.0, 180.0, 5.0) var star_rotation_y: float = 0.0
@export_range(-180.0, 180.0, 5.0) var star_rotation_z: float = 0.0

# Hermite 切线 (连接用, 通常由编辑器自动设置)
var hermite_from_tan: Vector3 = Vector3.ZERO
var hermite_to_tan: Vector3 = Vector3.ZERO

# --- 运行时状态 ---
var _stars: Array[Dictionary] = []  # [{node, collected, position_local}]
var _trail_mesh: MeshInstance3D = null
var _handle_start: Node3D = null
var _handle_mid: Node3D = null
var _handle_end: Node3D = null
var _handle_lines: Node3D = null
var _handles_visible: bool = false


func _ready() -> void:
	_rebuild()
	# 加入 group 供 CoopMode 查找
	add_to_group("star_trails")


## 判断当前是否在编辑器场景中 (TrackEditor)
func _is_in_editor() -> bool:
	var scene: Node = get_tree().current_scene if get_tree() else null
	if scene == null:
		return false
	return scene.name == "TrackEditor" or scene.has_method("_place_at_mouse")


# ============================================================
#  构建
# ============================================================
func _rebuild() -> void:
	# 清除旧星星和轨迹 (保留手柄)
	var keep_set: Array = [_handle_start, _handle_mid, _handle_end, _handle_lines]
	for c in get_children():
		if c in keep_set:
			continue
		remove_child(c)
		c.queue_free()
	_stars.clear()
	_trail_mesh = null

	var points: Array[Vector3] = _calc_bezier_points()
	if points.size() < 2:
		return

	# --- 绘制轨迹线 (仅编辑器中显示, 游戏中不显示) ---
	if Engine.is_editor_hint() or _is_in_editor():
		_build_trail_visual(points)

	# --- 沿曲线等距放星星 ---
	var star_positions: Array[Vector3] = _distribute_stars_along_path(points, star_count)
	for i in range(star_positions.size()):
		var pos: Vector3 = star_positions[i]
		var star_node: Node3D = _create_star_visual(pos)
		add_child(star_node)
		_stars.append({"node": star_node, "collected": false, "local_pos": pos})

	# --- 碰撞体 (仅编辑器, 让 raycast 选中) ---
	if Engine.is_editor_hint() or _is_in_editor():
		_build_pick_collision(points)

	_update_handles()


func _build_pick_collision(points: Array[Vector3]) -> void:
	# 沿曲线每隔几个点放一个小 BoxShape3D, 让编辑器 raycast 能选中
	# collision_layer = layer 6 only: 赛车只检测 layer 1, 不会撞到 layer 6
	# 编辑器 _pick_placed_block_at_mouse 的 raycast 没设 mask, 默认全 layer 都检测
	var body := StaticBody3D.new()
	body.name = "PickBody"
	body.collision_layer = 1 << 5  # layer 6 only — 赛车不碰, 编辑器能选
	body.collision_mask = 0
	var interval: int = maxi(points.size() / 10, 2)
	for i in range(0, points.size() - 1, interval):
		var i_end: int = mini(i + interval, points.size() - 1)
		var p0: Vector3 = points[i]
		var p1: Vector3 = points[i_end]
		var center: Vector3 = (p0 + p1) * 0.5
		var seg_dir: Vector3 = p1 - p0
		var seg_len: float = seg_dir.length()
		if seg_len < 0.01:
			continue
		seg_dir = seg_dir.normalized()
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(2.0, 2.0, seg_len + 1.0)
		col.shape = box
		var b_right: Vector3 = seg_dir.cross(Vector3.UP).normalized()
		if b_right.length() < 0.01:
			b_right = Vector3.RIGHT
		var b_basis := Basis()
		b_basis.z = -seg_dir
		b_basis.x = b_right
		b_basis.y = seg_dir.cross(b_right).normalized()
		col.transform = Transform3D(b_basis, center)
		body.add_child(col)
	add_child(body)


func _build_trail_visual(points: Array[Vector3]) -> void:
	# 用 ImmediateMesh 画一条虚线 (半透明)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var trail_width: float = 0.15
	for i in range(points.size()):
		var p: Vector3 = points[i]
		var dir: Vector3
		if i == 0:
			dir = (points[1] - points[0]).normalized()
		elif i == points.size() - 1:
			dir = (points[i] - points[i - 1]).normalized()
		else:
			dir = (points[i + 1] - points[i - 1]).normalized()
		var right: Vector3 = dir.cross(Vector3.UP).normalized()
		if right.length_squared() < 0.01:
			right = Vector3.RIGHT
		st.set_normal(Vector3.UP)
		st.add_vertex(p - right * trail_width)
		st.add_vertex(p + right * trail_width)
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()

	_trail_mesh = MeshInstance3D.new()
	_trail_mesh.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = trail_line_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(trail_line_color.r, trail_line_color.g, trail_line_color.b)
	mat.emission_energy_multiplier = 1.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_trail_mesh.material_override = mat
	_trail_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_trail_mesh)


const STAR_MODEL_PATH: String = "res://assets/custom_objs/绳星/绳星.fbx"

func _create_star_visual(local_pos: Vector3) -> Node3D:
	var root := Node3D.new()
	root.position = local_pos + Vector3(0.0, star_height_offset, 0.0)
	# 尝试加载 FBX 模型
	var model_scene: PackedScene = load(STAR_MODEL_PATH) as PackedScene
	if model_scene != null:
		var model: Node3D = model_scene.instantiate()
		model.name = "StarMesh"
		# 缩放 + 旋转 (用户可配置)
		model.scale = Vector3.ONE * star_visual_size
		model.rotation_degrees = Vector3(star_rotation_x, star_rotation_y, star_rotation_z)
		root.add_child(model)
		# 给所有 MeshInstance3D 加发光材质
		_apply_star_material_recursive(model)
	else:
		# fallback: 临时球体
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = star_visual_size
		sm.height = star_visual_size * 2.0
		sm.radial_segments = 8
		sm.rings = 4
		mi.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = star_color
		mat.emission_enabled = true
		mat.emission = star_color
		mat.emission_energy_multiplier = star_emission
		mat.metallic = 0.7
		mat.roughness = 0.2
		mi.material_override = mat
		mi.name = "StarMesh"
		root.add_child(mi)
	# 游戏运行时: 加 Area3D 让赛车也能吃到星星
	if not _is_in_editor():
		var area := Area3D.new()
		area.name = "StarArea"
		area.collision_layer = 0
		area.collision_mask = 2  # layer 2 = 赛车 body
		area.monitoring = true
		area.monitorable = false
		var col := CollisionShape3D.new()
		var sphere := SphereShape3D.new()
		sphere.radius = star_collect_radius
		col.shape = sphere
		area.add_child(col)
		root.add_child(area)
		var star_idx: int = _stars.size()  # 当前正在构建的索引
		area.body_entered.connect(_on_car_touch_star.bind(star_idx))
	return root


func _apply_star_material_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = star_color
		mat.emission_enabled = true
		mat.emission = star_color
		mat.emission_energy_multiplier = star_emission
		mat.metallic = 0.7
		mat.roughness = 0.2
		mi.material_override = mat
	for child in node.get_children():
		_apply_star_material_recursive(child)


func _distribute_stars_along_path(points: Array[Vector3], count: int) -> Array[Vector3]:
	if count <= 0 or points.size() < 2:
		return []
	# 计算路径总长
	var lengths: Array[float] = [0.0]
	var total: float = 0.0
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
		lengths.append(total)
	if total < 0.01:
		return [points[0]]
	# 等距分布
	var result: Array[Vector3] = []
	for s in range(count):
		var t: float = (float(s) + 0.5) / float(count)  # 居中分布
		var target_len: float = t * total
		# 二分查找所在段
		var seg: int = 0
		for j in range(1, lengths.size()):
			if lengths[j] >= target_len:
				seg = j - 1
				break
		var seg_len: float = lengths[seg + 1] - lengths[seg]
		var local_t: float = (target_len - lengths[seg]) / maxf(seg_len, 0.001)
		result.append(points[seg].lerp(points[seg + 1], local_t))
	return result


# ============================================================
#  贝塞尔曲线 (跟窄道一致)
# ============================================================
func _calc_bezier_points() -> Array[Vector3]:
	var p0 := Vector3.ZERO
	var p3 := end_offset
	var result: Array[Vector3] = []
	# Hermite 模式
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
	# 三次贝塞尔
	if curve_offset_end.length_squared() > 0.001:
		var p1: Vector3 = curve_offset
		var p2: Vector3 = p3 + curve_offset_end
		for i in range(segment_count + 1):
			var t: float = float(i) / float(segment_count)
			var omt: float = 1.0 - t
			result.append(omt*omt*omt * p0 + 3.0*omt*omt*t * p1 + 3.0*omt*t*t * p2 + t*t*t * p3)
		return result
	# 二次贝塞尔
	var mid: Vector3 = (p0 + p3) * 0.5 + curve_offset
	for i in range(segment_count + 1):
		var t: float = float(i) / float(segment_count)
		var omt: float = 1.0 - t
		result.append(omt * omt * p0 + 2.0 * omt * t * mid + t * t * p3)
	return result


# ============================================================
#  运行时: 绳子碰撞检测接口 (由 CoopMode 每帧调用)
# ============================================================

## 获取所有未收集星星的世界坐标和半径
## 返回 [{world_pos: Vector3, radius: float, index: int}]
func get_uncollected_stars() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(_stars.size()):
		if _stars[i]["collected"]:
			continue
		var node: Node3D = _stars[i]["node"]
		if node == null:
			continue
		out.append({
			"world_pos": node.global_position,
			"radius": star_collect_radius,
			"index": i,
		})
	return out


## 收集指定星星 (播放爆光 + 隐藏), 返回是否成功收集 (用于外部计数)
func collect_star(index: int) -> bool:
	if index < 0 or index >= _stars.size():
		return false
	if _stars[index]["collected"]:
		return false
	_stars[index]["collected"] = true
	var node: Node3D = _stars[index]["node"]
	if node == null:
		return true
	# 爆光动画: 放大 + 高 emission → 缩小消失
	_play_collect_fx(node)
	return true


## 赛车碰到星星的回调 (Area3D body_entered)
func _on_car_touch_star(body: Node3D, star_index: int) -> void:
	if star_index < 0 or star_index >= _stars.size():
		return
	if _stars[star_index]["collected"]:
		return
	# 确认是赛车 (RigidBody3D)
	if not (body is RigidBody3D):
		return
	if not collect_star(star_index):
		return
	# 获取星星世界坐标
	var star_world: Vector3 = Vector3.INF
	if star_index >= 0 and star_index < _stars.size():
		var snode: Node3D = _stars[star_index]["node"]
		if snode:
			star_world = snode.global_position
	# 通知 CoopMode 更新计数 (有绳子模式时走 CoopMode 统一计数)
	var coop_nodes: Array = get_tree().get_nodes_in_group("coop_mode")
	var notified: bool = false
	for coop in coop_nodes:
		if coop.has_method("on_star_collected_by_car"):
			coop.call("on_star_collected_by_car", star_world)
			notified = true
	# 没有 CoopMode (单人模式): 直接更新 HUD
	if not notified:
		_solo_star_count += 1
		_notify_hud_directly(star_world)


## 单人模式星星计数 (没有 CoopMode 时用)
var _solo_star_count: int = 0

func _notify_hud_directly(star_world_pos: Vector3 = Vector3.INF) -> void:
	var hud: Node = get_tree().current_scene.find_child("HUD", true, false)
	if hud and hud.has_method("update_star_count"):
		hud.call("update_star_count", _solo_star_count, 0, star_world_pos)


func _play_collect_fx(star_node: Node3D) -> void:
	# 直接缩小消失 (不闪光)
	var tw: Tween = create_tween()
	tw.tween_property(star_node, "scale", Vector3(0.01, 0.01, 0.01), 0.15)
	tw.tween_callback(func() -> void: star_node.visible = false)


func _flash_all_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 1.0, 0.7, 1.0)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.9, 0.3)
		mat.emission_energy_multiplier = 6.0
		mat.metallic = 1.0
		mat.roughness = 0.0
		mi.material_override = mat
	for child in node.get_children():
		_flash_all_meshes(child)


## 获取已收集数量
func get_collected_count() -> int:
	var count: int = 0
	for s in _stars:
		if s["collected"]:
			count += 1
	return count


## 获取星星总数
func get_total_count() -> int:
	return _stars.size()


## 重置所有星星 (复位时调用)
func reset_state() -> void:
	for i in range(_stars.size()):
		_stars[i]["collected"] = false
		var node: Node3D = _stars[i]["node"]
		if node:
			node.visible = true
			node.scale = Vector3.ONE
			# 递归恢复所有 MeshInstance3D 的材质为正常发光状态
			_restore_star_material_recursive(node)
	_solo_star_count = 0


func _restore_star_material_recursive(node: Node) -> void:
	if node is MeshInstance3D:
		var mi: MeshInstance3D = node as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = star_color
		mat.emission_enabled = true
		mat.emission = star_color
		mat.emission_energy_multiplier = star_emission
		mat.metallic = 0.7
		mat.roughness = 0.2
		mi.material_override = mat
	for child in node.get_children():
		_restore_star_material_recursive(child)


# ============================================================
#  控制点手柄 (跟窄道一模一样)
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
	var handle_y_lift := Vector3(0.0, 2.0, 0.0)
	_handle_start.position = Vector3.ZERO + handle_y_lift
	_handle_end.position = end_offset + handle_y_lift
	_handle_mid.position = end_offset * 0.5 + curve_offset + handle_y_lift


func get_start_world_pos() -> Vector3:
	return global_position

func get_end_world_pos() -> Vector3:
	return global_position + global_transform.basis * end_offset

func get_nearest_endpoint(world_pos: Vector3) -> String:
	var d_start: float = world_pos.distance_to(get_start_world_pos())
	var d_end: float = world_pos.distance_to(get_end_world_pos())
	return "start" if d_start < d_end else "end"

func pick_handle_at(ray_origin: Vector3, ray_dir: Vector3) -> String:
	if not _handles_visible:
		return ""
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
			var old_end_world: Vector3 = get_end_world_pos()
			var old_mid_world: Vector3 = global_position + global_transform.basis * (end_offset * 0.5 + curve_offset)
			global_position = world_pos
			end_offset = global_transform.affine_inverse() * old_end_world
			var new_mid_local: Vector3 = global_transform.affine_inverse() * old_mid_world
			curve_offset = new_mid_local - end_offset * 0.5
		"end":
			end_offset = local_pos
		"mid":
			curve_offset = local_pos - end_offset * 0.5
	_rebuild()


# ============================================================
#  TrackEditor 参数接口
# ============================================================
func get_editable_params() -> Array:
	return [
		{"key": "star_count", "label": "星星数量", "min": 1.0, "max": 50.0, "step": 1.0, "value": float(star_count)},
		{"key": "star_collect_radius", "label": "收集半径(m)", "min": 0.5, "max": 5.0, "step": 0.1, "value": star_collect_radius},
		{"key": "star_height_offset", "label": "星星高度偏移(m)", "min": 0.0, "max": 10.0, "step": 0.1, "value": star_height_offset},
		{"key": "star_visual_size", "label": "星星大小(m)", "min": 0.3, "max": 3.0, "step": 0.1, "value": star_visual_size},
		{"key": "star_emission", "label": "发光强度", "min": 0.0, "max": 5.0, "step": 0.1, "value": star_emission},
		{"key": "star_rotation_x", "label": "星星旋转X(°)", "min": -180.0, "max": 180.0, "step": 5.0, "value": star_rotation_x},
		{"key": "star_rotation_y", "label": "星星旋转Y(°)", "min": -180.0, "max": 180.0, "step": 5.0, "value": star_rotation_y},
		{"key": "star_rotation_z", "label": "星星旋转Z(°)", "min": -180.0, "max": 180.0, "step": 5.0, "value": star_rotation_z},
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
		# Hermite (hidden)
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
		"star_count": star_count = int(value)
		"star_collect_radius": star_collect_radius = value
		"star_height_offset": star_height_offset = value
		"star_visual_size": star_visual_size = value
		"star_emission": star_emission = value
		"star_rotation_x": star_rotation_x = value
		"star_rotation_y": star_rotation_y = value
		"star_rotation_z": star_rotation_z = value
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
