extends Node3D
class_name Block_FragileNarrow
## ============================================================
##  易碎窄道 (Fragile Narrow Path)
## ============================================================
## 多段组成的窄道, 赛车压过后 x 秒该段脱离坠落, 失去承托能力.
## 视觉: 压过时出现裂纹, 倒计时结束后段翻转坠落消失.
## 复位时所有段恢复原位.
## ============================================================

@export_group("路面")
@export_range(2.0, 15.0, 0.5) var path_width: float = 4.0
## 终点宽度 (如果 <= 0 则与 path_width 相同, 实现宽度渐变)
@export_range(0.0, 15.0, 0.5) var end_width: float = 0.0
@export_range(0.1, 2.0, 0.1) var path_thickness: float = 0.3
## 颜色限制: 0=正常(所有车可走), 1=仅红色车(1P), 2=仅蓝色车(2P)
@export_range(0, 2, 1) var color_mode: int = 0

@export_group("路径")
@export var end_offset: Vector3 = Vector3(0.0, 0.0, -25.0)
@export var curve_offset: Vector3 = Vector3(0.0, 0.0, 0.0)
## 终点侧控制点偏移 (三次贝塞尔第二控制点, 全零=退化为二次)
@export var curve_offset_end: Vector3 = Vector3(0.0, 0.0, 0.0)
## 每段固定长度 (米), 越长的窄道自动分越多段
@export_range(1.0, 10.0, 0.5) var segment_length: float = 3.0

@export_group("碎裂")
## 赛车压过后多少秒开始坠落 (给车足够时间开过去)
@export_range(0.3, 5.0, 0.1) var break_delay: float = 1.5
## 坠落动画时间 (翻转+下落)
@export_range(0.1, 3.0, 0.1) var fall_duration: float = 1.0
## 坠落后多久恢复 (0=不恢复)
@export_range(0.0, 15.0, 0.5) var respawn_time: float = 5.0

@export_group("视觉")
@export var road_color: Color = Color(0.5, 0.35, 0.3)
@export var crack_color: Color = Color(0.9, 0.3, 0.1)
@export_range(0.0, 2.0, 0.1) var edge_glow: float = 0.4

## Hermite 模式: 当 hermite_from_tan 非零时启用
var hermite_from_tan: Vector3 = Vector3.ZERO
var hermite_to_tan: Vector3 = Vector3.ZERO

# ---- 内部 ----
# 每段: {body: StaticBody3D, mesh: MeshInstance3D, state: "solid"/"cracking"/"falling"/"gone", timer: float, original_pos: Vector3, original_basis: Basis}
var _segments: Array = []
var _fall_area: Area3D = null
# 控制点手柄 (与窄道完全一致)
var _handle_start: Node3D = null
var _handle_mid: Node3D = null
var _handle_end: Node3D = null
var _handle_lines: Node3D = null
var _handles_visible: bool = false


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	var keep_set: Array = [_handle_start, _handle_mid, _handle_end, _handle_lines]
	for c in get_children():
		if c in keep_set:
			continue
		remove_child(c)
		c.queue_free()
	_segments.clear()
	_fall_area = null

	# 计算段数和每段的曲线区间
	var approx_len: float = _approx_curve_length()
	var seg_count: int = int(ceilf(approx_len / maxf(segment_length, 0.5)))
	seg_count = clampi(seg_count, 3, 60)
	# 每段内部子采样点数 (让曲面平滑)
	var sub_samples: int = 8
	# 宽度渐变
	var actual_end_w: float = end_width if end_width > 0.0 else path_width

	var road_mat := StandardMaterial3D.new()
	var actual_road_color: Color = road_color
	if color_mode == 1:
		actual_road_color = Color(0.85, 0.2, 0.15)
	elif color_mode == 2:
		actual_road_color = Color(0.15, 0.3, 0.9)
	road_mat.albedo_color = actual_road_color
	if color_mode > 0:
		road_mat.emission_enabled = true
		road_mat.emission = actual_road_color * 0.4
		road_mat.emission_energy_multiplier = 0.6
	road_mat.metallic = 0.2
	road_mat.roughness = 0.8

	# 每段覆盖曲线的 [t_start, t_end] 区间, 用 ArrayMesh strip 生成平滑曲面
	for i in range(seg_count):
		var t_start: float = float(i) / float(seg_count)
		var t_end: float = float(i + 1) / float(seg_count)
		# 两端各延伸 overlap 防缝隙 (系数加大确保无缝)
		var t_overlap: float = 0.5 / float(seg_count)
		var t_a: float = maxf(t_start - t_overlap * 0.6, 0.0)
		var t_b: float = minf(t_end + t_overlap * 0.6, 1.0)

		# 子采样这段区间的点 + 逐点宽度
		var sub_points: Array[Vector3] = []
		var sub_rights: Array[Vector3] = []
		var sub_widths: Array[float] = []
		for j in range(sub_samples + 1):
			var t: float = lerpf(t_a, t_b, float(j) / float(sub_samples))
			var pt: Vector3 = _bezier_at(t)
			sub_points.append(pt)
			var tangent: Vector3 = _bezier_tangent_at(t)
			var up := Vector3.UP
			var right: Vector3 = tangent.cross(up).normalized()
			if right.length_squared() < 0.01:
				right = Vector3.RIGHT
			sub_rights.append(right)
			sub_widths.append(lerpf(path_width, actual_end_w, t))

		var seg_mesh: ArrayMesh = _build_strip_mesh(sub_points, sub_rights, path_width, 0.0, sub_widths)

		var body := StaticBody3D.new()
		body.name = "FragSeg_%d" % i
		body.collision_layer = 1
		body.collision_mask = 0
		var phys_mat := PhysicsMaterial.new()
		phys_mat.friction = 0.1
		phys_mat.bounce = 0.0
		body.physics_material_override = phys_mat

		# 碰撞 Box: 用段中心处的宽度
		var seg_start_pt: Vector3 = _bezier_at(t_start)
		var seg_end_pt: Vector3 = _bezier_at(t_end)
		var seg_mid: Vector3 = (seg_start_pt + seg_end_pt) * 0.5
		var seg_vec: Vector3 = seg_end_pt - seg_start_pt
		var seg_mid_t: float = (t_start + t_end) * 0.5
		var seg_w: float = lerpf(path_width, actual_end_w, seg_mid_t)
		var seg_box_len: float = seg_vec.length() + seg_w * 0.2
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(seg_w, path_thickness + 0.1, seg_box_len)
		col.shape = box
		var box_dir: Vector3 = seg_vec.normalized() if seg_vec.length() > 0.01 else Vector3(0, 0, -1)
		var box_up := Vector3.UP
		var box_right: Vector3 = box_dir.cross(box_up).normalized()
		if box_right.length() < 0.01:
			box_right = Vector3.RIGHT
		var box_basis := Basis()
		box_basis.z = -box_dir
		box_basis.x = box_right
		box_basis.y = box_dir.cross(box_right).normalized()
		col.transform = Transform3D(box_basis, seg_mid)
		body.add_child(col)

		var mi := MeshInstance3D.new()
		mi.mesh = seg_mesh
		mi.material_override = road_mat.duplicate()
		body.add_child(mi)

		# 检测 Area
		var seg_center: Vector3 = _bezier_at(seg_mid_t)
		var seg_dir: Vector3 = (_bezier_at(t_end) - _bezier_at(t_start))
		var seg_len: float = seg_dir.length()
		var area := Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 2
		area.monitoring = true
		area.monitorable = false
		var ashape := CollisionShape3D.new()
		var abox := BoxShape3D.new()
		abox.size = Vector3(seg_w + 2.0, 5.0, seg_len + 2.0)
		ashape.shape = abox
		var area_up := Vector3.UP
		var area_right: Vector3 = seg_dir.normalized().cross(area_up).normalized()
		if area_right.length() < 0.01:
			area_right = Vector3.RIGHT
		var area_basis := Basis()
		area_basis.z = -seg_dir.normalized()
		area_basis.x = area_right
		area_basis.y = seg_dir.normalized().cross(area_right).normalized()
		ashape.position = Vector3.ZERO
		area.add_child(ashape)
		area.transform = Transform3D(area_basis, seg_center + Vector3(0.0, 2.0, 0.0))
		body.add_child(area)

		add_child(body)

		var seg_data: Dictionary = {
			"body": body,
			"mesh": mi,
			"area": area,
			"state": "solid",
			"timer": 0.0,
			"original_xform": body.transform,
			"fall_vel": 0.0,
		}
		_segments.append(seg_data)

	# 坠落检测 (只在路面下方很深处, 避免误判正常行驶的车)
	_fall_area = Area3D.new()
	_fall_area.name = "FallDetect"
	_fall_area.collision_layer = 0
	_fall_area.collision_mask = 2
	_fall_area.monitoring = true
	var total_extent: Vector3 = end_offset.abs() + Vector3(10, 0, 10)
	var fshape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	# 检测区在路面下方 10~20m (只有真正掉下去才会触发)
	fbox.size = Vector3(maxf(total_extent.x, path_width) + 10, 6.0, maxf(total_extent.z, 10.0) + 10)
	fshape.shape = fbox
	fshape.position = end_offset * 0.5 + Vector3(0.0, -13.0, 0.0)
	_fall_area.add_child(fshape)
	add_child(_fall_area)
	_update_handles()








func _physics_process(delta: float) -> void:
	# 每帧主动检测: solid 状态的段如果有车在上面 → 触发碎裂
	# (不用信号, 因为车可能一开始就在 area 内/从上方落入, body_entered 不重复触发)
	for i in range(_segments.size()):
		var seg: Dictionary = _segments[i]
		if seg["state"] != "solid":
			continue
		var area: Area3D = seg["area"]
		if area == null:
			continue
		for body in area.get_overlapping_bodies():
			if body is RigidBody3D:
				seg["state"] = "cracking"
				seg["timer"] = break_delay
				# 只变色警告, 路面不动 (给车时间开过去)
				var mi: MeshInstance3D = seg["mesh"]
				if mi and mi.material_override:
					mi.material_override.albedo_color = crack_color
				break

	for seg in _segments:
		match seg["state"]:
			"cracking":
				seg["timer"] -= delta
				# 延迟期间路面完全不动, 只变色警告 (车可以正常开过去)
				# 最后 0.2 秒轻微抖动提醒"马上要塌了"
				if seg["timer"] < 0.2 and break_delay > 0.3:
					var body_c: StaticBody3D = seg["body"]
					var shake: float = randf_range(-0.02, 0.02)
					body_c.position.x += shake
					body_c.position.z += shake
				if seg["timer"] <= 0.0:
					seg["state"] = "falling"
					seg["timer"] = fall_duration
					seg["fall_vel"] = 0.5
					var body_c2: StaticBody3D = seg["body"]
					body_c2.collision_layer = 0
			"falling":
				seg["timer"] -= delta
				# 重力加速 (越来越快, 更自然)
				seg["fall_vel"] += 15.0 * delta
				var body_f: StaticBody3D = seg["body"]
				body_f.position.y -= seg["fall_vel"] * delta
				# 缓慢倾斜 (不疯狂旋转, 像真实塌落)
				var tilt_speed: float = 0.8 * (1.0 - seg["timer"] / fall_duration)
				body_f.rotation.x += tilt_speed * delta
				body_f.rotation.z += tilt_speed * 0.3 * delta
				# 逐渐透明 (淡出)
				var mi_f: MeshInstance3D = seg["mesh"]
				if mi_f and mi_f.material_override:
					var alpha: float = clampf(seg["timer"] / fall_duration, 0.0, 1.0)
					mi_f.material_override.albedo_color.a = alpha
					if mi_f.material_override.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA:
						mi_f.material_override.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				if seg["timer"] <= 0.0:
					seg["state"] = "gone"
					seg["timer"] = respawn_time
					body_f.visible = false
			"gone":
				if respawn_time > 0.0:
					seg["timer"] -= delta
					if seg["timer"] <= 0.0:
						_respawn_segment(seg)


func _respawn_segment(seg: Dictionary) -> void:
	seg["state"] = "solid"
	seg["timer"] = 0.0
	seg["fall_vel"] = 0.0
	var body: StaticBody3D = seg["body"]
	body.visible = true
	body.collision_layer = 1
	body.transform = seg["original_xform"]
	# 恢复颜色和透明度
	var mi: MeshInstance3D = seg["mesh"]
	if mi and mi.material_override:
		mi.material_override.albedo_color = Color(road_color.r, road_color.g, road_color.b, 1.0)
		mi.material_override.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED





func reset_state() -> void:
	for seg in _segments:
		_respawn_segment(seg)


func _bezier_at(t: float) -> Vector3:
	var p0 := Vector3.ZERO
	var p3 := end_offset
	# Hermite 模式
	if hermite_from_tan.length_squared() > 0.001:
		var dist: float = p3.length()
		var m0: Vector3 = hermite_from_tan * dist
		var m1: Vector3 = hermite_to_tan * dist
		var t2: float = t * t
		var t3: float = t2 * t
		var h00: float = 2.0*t3 - 3.0*t2 + 1.0
		var h10: float = t3 - 2.0*t2 + t
		var h01: float = -2.0*t3 + 3.0*t2
		var h11: float = t3 - t2
		return h00*p0 + h10*m0 + h01*p3 + h11*m1
	var omt: float = 1.0 - t
	if curve_offset_end.length_squared() > 0.001:
		var p1: Vector3 = curve_offset
		var p2: Vector3 = p3 + curve_offset_end
		return omt*omt*omt * p0 + 3.0*omt*omt*t * p1 + 3.0*omt*t*t * p2 + t*t*t * p3
	else:
		var mid: Vector3 = (p0 + p3) * 0.5 + curve_offset
		return omt * omt * p0 + 2.0 * omt * t * mid + t * t * p3

func _bezier_tangent_at(t: float) -> Vector3:
	var p0 := Vector3.ZERO
	var p3 := end_offset
	# Hermite 模式: 导数
	if hermite_from_tan.length_squared() > 0.001:
		var dist: float = p3.length()
		var m0: Vector3 = hermite_from_tan * dist
		var m1: Vector3 = hermite_to_tan * dist
		var t2: float = t * t
		var dh00: float = 6.0*t2 - 6.0*t
		var dh10: float = 3.0*t2 - 4.0*t + 1.0
		var dh01: float = -6.0*t2 + 6.0*t
		var dh11: float = 3.0*t2 - 2.0*t
		var tangent: Vector3 = dh00*p0 + dh10*m0 + dh01*p3 + dh11*m1
		return tangent.normalized() if tangent.length() > 0.001 else Vector3(0, 0, -1)
	if curve_offset_end.length_squared() > 0.001:
		var p1: Vector3 = curve_offset
		var p2: Vector3 = p3 + curve_offset_end
		var omt: float = 1.0 - t
		var tangent: Vector3 = 3.0*omt*omt*(p1-p0) + 6.0*omt*t*(p2-p1) + 3.0*t*t*(p3-p2)
		return tangent.normalized() if tangent.length() > 0.001 else Vector3(0, 0, -1)
	else:
		var mid: Vector3 = (p0 + p3) * 0.5 + curve_offset
		var tangent: Vector3 = 2.0 * (1.0 - t) * (mid - p0) + 2.0 * t * (p3 - mid)
		return tangent.normalized() if tangent.length() > 0.001 else Vector3(0, 0, -1)

func _approx_curve_length() -> float:
	var total: float = 0.0
	var prev: Vector3 = _bezier_at(0.0)
	for i in range(1, 21):
		var pt: Vector3 = _bezier_at(float(i) / 20.0)
		total += prev.distance_to(pt)
		prev = pt
	return total

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
		{"key": "segment_length", "label": "每段长度(m)", "min": 1.0, "max": 10.0, "step": 0.5, "value": segment_length},
		{"key": "break_delay", "label": "碎裂延迟(s)", "min": 0.1, "max": 5.0, "step": 0.1, "value": break_delay},
		{"key": "fall_duration", "label": "坠落时间(s)", "min": 0.1, "max": 3.0, "step": 0.1, "value": fall_duration},
		{"key": "respawn_time", "label": "恢复时间(s)", "min": 0.0, "max": 15.0, "step": 0.5, "value": respawn_time},
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
		"segment_length": segment_length = value
		"break_delay": break_delay = value
		"fall_duration": fall_duration = value
		"respawn_time": respawn_time = value
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


# ============================================================
#  控制点手柄 (与 Block_NarrowPath 完全一致)
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

func get_end_tangent_world() -> Vector3:
	var p3 := end_offset
	var tangent_local: Vector3
	if curve_offset_end.length_squared() > 0.001:
		var p2: Vector3 = p3 + curve_offset_end
		tangent_local = (p3 - p2).normalized()
	else:
		var p1: Vector3 = end_offset * 0.5 + curve_offset
		tangent_local = (p3 - p1).normalized()
	if tangent_local.length() < 0.001:
		tangent_local = end_offset.normalized()
	return (global_transform.basis * tangent_local).normalized()

func get_start_tangent_world() -> Vector3:
	var tangent_local: Vector3
	if curve_offset_end.length_squared() > 0.001:
		tangent_local = curve_offset.normalized()
	else:
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
		print("[FragileNarrow] pick_handle_at: handles not visible!")
		return ""
	# 根据相机距离动态放大命中半径
	var cam_dist: float = ray_origin.distance_to(global_position)
	var hit_radius: float = clampf(cam_dist * 0.05, 2.0, 10.0)
	print("[FragileNarrow] pick_handle_at: cam_dist=%.1f hit_radius=%.1f handles_visible=%s" % [cam_dist, hit_radius, str(_handles_visible)])
	var best: String = ""
	var best_dist: float = hit_radius + 1.0
	for pair in [["start", _handle_start], ["mid", _handle_mid], ["end", _handle_end]]:
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
			end_offset = global_transform.affine_inverse() * old_end_world
			var new_mid_local: Vector3 = global_transform.affine_inverse() * old_mid_world
			curve_offset = new_mid_local - end_offset * 0.5
		"end":
			end_offset = local_pos
		"mid":
			curve_offset = local_pos - end_offset * 0.5
	_rebuild()
