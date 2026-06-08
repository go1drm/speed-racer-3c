extends Node3D
class_name Block_FaceWall
## ============================================================
##  笑脸墙来了 (Face Wall Rush)
## ============================================================
## 玩法:
##   一条长直道 (~400m), 不断从末端生成告示牌+3面墙向玩家冲来.
##   告示牌显示3个表情(随机, 可重复), 对应接下来3面墙的正确答案.
##   每面墙有左/中/右三个门(打乱的表情), 只有选对的门能安全通过.
##   选错 → 被墙撞飞 (巨大冲量弹飞).
##
## 结构:
##   长直道地板 (StaticBody3D + BoxMesh)
##   两侧护栏 (StaticBody3D)
##   波次生成器: 每隔一段时间从末端生成一组 (告示牌 + 3面墙)
##   每组以固定速度朝玩家方向移动
## ============================================================

# --- 表情定义 ---
# Godot 4 的 Label3D 默认字体不渲染 emoji, 改用中文大字+颜色区分
enum Face { SMILE, COLD, CRY }
const FACE_TEXT: Dictionary = {
	Face.SMILE: "笑",
	Face.COLD: "冷",
	Face.CRY: "哭",
}
const FACE_COLORS: Dictionary = {
	Face.SMILE: Color(1.0, 0.85, 0.0),   # 金黄 — 笑脸
	Face.COLD: Color(0.4, 0.7, 1.0),     # 冰蓝 — 冷脸
	Face.CRY: Color(0.4, 0.2, 0.9),      # 紫蓝 — 哭脸
}

@export_group("直道")
## 直道总长度 (米)
@export_range(100.0, 1000.0, 10.0) var track_length: float = 400.0
## 直道宽度 (米) — 3个门并排
@export_range(8.0, 40.0, 1.0) var track_width: float = 18.0
## 护栏高度 (米)
@export_range(1.0, 10.0, 0.5) var rail_height: float = 4.0
## 地板颜色
@export var floor_color: Color = Color(0.15, 0.15, 0.2)

@export_group("波次")
## 波次生成间隔 (秒) — 每隔多久生成一组(告示牌+3墙)
@export_range(2.0, 20.0, 0.5) var wave_interval: float = 6.0
## 墙/告示牌移动速度 (m/s)
@export_range(10.0, 100.0, 5.0) var wall_speed: float = 30.0
## 告示牌与第一面墙的间距 (米)
@export_range(5.0, 50.0, 1.0) var sign_to_wall_gap: float = 15.0
## 墙与墙之间的间距 (米)
@export_range(3.0, 30.0, 1.0) var wall_to_wall_gap: float = 10.0

@export_group("墙体")
## 墙高度 (米)
@export_range(2.0, 15.0, 0.5) var wall_height: float = 5.0
## 墙厚度 (米)
@export_range(0.3, 3.0, 0.1) var wall_thickness: float = 1.0
## 门宽度 (米) — 每个门的通道宽度
@export_range(2.0, 10.0, 0.5) var door_width: float = 4.0
## 墙体颜色
@export var wall_color: Color = Color(0.6, 0.6, 0.65)
## 正确门颜色
@export var correct_door_color: Color = Color(0.2, 0.8, 0.3)
## 错误门颜色 (被撞时)
@export var wrong_door_color: Color = Color(0.8, 0.2, 0.2)

@export_group("弹飞")
## 被墙撞飞的冲量 (m/s)
@export_range(10.0, 100.0, 5.0) var hit_impulse: float = 40.0
## 弹飞向上比例
@export_range(0.0, 1.0, 0.05) var hit_up_ratio: float = 0.6
## 弹飞后豁免时间 (s)
@export_range(0.1, 3.0, 0.1) var hit_skip_stick: float = 0.8

@export_group("告示牌")
## 告示牌高度 (米, 牌子本体高度)
@export_range(2.0, 10.0, 0.5) var sign_height: float = 5.0
## 告示牌宽度 (米)
@export_range(1.0, 8.0, 0.5) var sign_width: float = 3.0
## 告示牌安装高度 (米, 牌子底部距地面)
@export_range(3.0, 20.0, 0.5) var sign_mount_height: float = 6.0
## 告示牌侧边偏移 (米, 从赛道边缘向外偏移, 像红绿灯挂在路侧)
@export_range(0.0, 10.0, 0.5) var sign_side_offset: float = 2.0


# ---- 内部 ----
var _floor_body: StaticBody3D = null
var _rail_left: StaticBody3D = null
var _rail_right: StaticBody3D = null
var _wave_timer: float = 0.0
var _active_waves: Array = []  # Array of { "nodes": Array[Node3D], "sign_faces": Array[int], "walls": Array[Dictionary] }
var _player_z: float = 0.0  # 玩家所在 Z 位置 (用于清理已经过去的波次)


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	# 清除所有子节点
	for c in get_children():
		c.queue_free()
	_floor_body = null
	_rail_left = null
	_rail_right = null
	_active_waves.clear()
	_wave_timer = 0.0

	# --- 地板 ---
	_floor_body = StaticBody3D.new()
	_floor_body.name = "Floor"
	_floor_body.collision_layer = 1
	_floor_body.collision_mask = 0
	var floor_shape := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(track_width, 0.5, track_length)
	floor_shape.shape = fbox
	floor_shape.position = Vector3(0.0, -0.25, -track_length * 0.5)
	_floor_body.add_child(floor_shape)
	var floor_mesh := MeshInstance3D.new()
	var fmesh := BoxMesh.new()
	fmesh.size = Vector3(track_width, 0.5, track_length)
	floor_mesh.mesh = fmesh
	floor_mesh.position = Vector3(0.0, -0.25, -track_length * 0.5)
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = floor_color
	fmat.metallic = 0.1
	fmat.roughness = 0.9
	floor_mesh.material_override = fmat
	_floor_body.add_child(floor_mesh)
	add_child(_floor_body)

	# --- 左护栏 ---
	_rail_left = _create_rail(Vector3(-track_width * 0.5 - 0.25, rail_height * 0.5, -track_length * 0.5))
	add_child(_rail_left)

	# --- 右护栏 ---
	_rail_right = _create_rail(Vector3(track_width * 0.5 + 0.25, rail_height * 0.5, -track_length * 0.5))
	add_child(_rail_right)


func _create_rail(pos: Vector3) -> StaticBody3D:
	var rail := StaticBody3D.new()
	rail.collision_layer = 1
	rail.collision_mask = 0
	var shape := CollisionShape3D.new()
	var rbox := BoxShape3D.new()
	rbox.size = Vector3(0.5, rail_height, track_length)
	shape.shape = rbox
	shape.position = pos
	rail.add_child(shape)
	var rmesh := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(0.5, rail_height, track_length)
	rmesh.mesh = rm
	rmesh.position = pos
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.3, 0.3, 0.35)
	rmat.metallic = 0.4
	rmat.roughness = 0.5
	rmesh.material_override = rmat
	rail.add_child(rmesh)
	return rail


func _wave_passed(wave: Dictionary) -> bool:
	## 检查波次是否已经完全通过玩家位置 (Z > 50m 超过起点)
	for node in wave["nodes"]:
		if node != null and is_instance_valid(node):
			if node.position.z < 50.0:
				return false
	return true


func _spawn_wave() -> void:
	## 生成一组: 1个告示牌 + 3面墙
	## 从直道末端 (Z = -track_length) 开始
	## 告示牌在赛道侧边(像红绿灯), 墙在赛道中间

	# 随机3个表情 (对应3面墙的正确答案, 可重复)
	var answers: Array = []
	for _i in range(3):
		answers.append(randi() % 3)  # 0=SMILE, 1=COLD, 2=CRY

	var spawn_z: float = -track_length
	var wave_nodes: Array = []

	# --- 告示牌 (路侧, 像红绿灯) ---
	var sign_node := _create_sign(answers)
	# 告示牌放在赛道右侧外边 (track_width/2 + sign_side_offset)
	var sign_x: float = track_width * 0.5 + sign_side_offset
	sign_node.position = Vector3(sign_x, 0.0, spawn_z)
	add_child(sign_node)
	wave_nodes.append(sign_node)

	# --- 3面墙 ---
	# 第一面墙在告示牌后方 sign_to_wall_gap 米
	# 后续墙之间间距 wall_to_wall_gap
	var wall_data: Array = []
	for wi in range(3):
		var wall_z: float
		if wi == 0:
			wall_z = spawn_z - sign_to_wall_gap
		else:
			wall_z = spawn_z - sign_to_wall_gap - wi * wall_to_wall_gap
		var correct_face: int = answers[wi]
		var wall_info: Dictionary = _create_wall(correct_face, wall_z)
		wall_info["node"].position = Vector3(0.0, 0.0, wall_z)
		add_child(wall_info["node"])
		wave_nodes.append(wall_info["node"])
		wall_data.append(wall_info)

	_active_waves.append({
		"nodes": wave_nodes,
		"answers": answers,
		"walls": wall_data,
	})


func _create_sign(faces: Array) -> Node3D:
	## 创建告示牌: 路侧红绿灯样式, 3个表情从上到下排列
	## faces[0] = 第1面墙答案 (顶部), faces[1] = 第2面墙 (中间), faces[2] = 第3面墙 (底部)
	var root := Node3D.new()
	root.name = "SignBoard"

	# 柱子 (从地面到牌子)
	var pole_h: float = sign_mount_height + sign_height
	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.12
	pm.bottom_radius = 0.15
	pm.height = pole_h
	pole.mesh = pm
	pole.position = Vector3(0.0, pole_h * 0.5, 0.0)
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.4, 0.4, 0.45)
	pmat.metallic = 0.5
	pole.material_override = pmat
	root.add_child(pole)

	# 牌子背板 (竖长方形, 像红绿灯信号箱)
	var board_mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(sign_width, sign_height, 0.3)
	board_mesh.mesh = bm
	board_mesh.position = Vector3(0.0, sign_mount_height + sign_height * 0.5, 0.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.12, 0.12, 0.15)
	bmat.metallic = 0.4
	bmat.roughness = 0.5
	board_mesh.material_override = bmat
	root.add_child(board_mesh)

	# 3个表情从上到下排列 (间距 = sign_height / 4)
	# faces[0] 在最上面 = 第1面墙的正确答案
	var vert_spacing: float = sign_height / 4.0
	for i in range(3):
		var face_id: int = faces[i]
		# Y 位置: 顶部 → 中间 → 底部
		var y_pos: float = sign_mount_height + sign_height - vert_spacing * (i + 1) + vert_spacing * 0.5

		# 彩色圆形灯 (像红绿灯)
		var lamp := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = vert_spacing * 0.35
		sm.height = vert_spacing * 0.7
		lamp.mesh = sm
		lamp.position = Vector3(0.0, y_pos, 0.2)
		var smat := StandardMaterial3D.new()
		smat.albedo_color = FACE_COLORS[face_id]
		smat.emission_enabled = true
		smat.emission = FACE_COLORS[face_id]
		smat.emission_energy_multiplier = 1.5
		lamp.material_override = smat
		root.add_child(lamp)

		# 表情中文字 (从上到下)
		var label := Label3D.new()
		label.text = FACE_TEXT[face_id]
		label.font_size = 160
		label.outline_size = 10
		label.modulate = Color.WHITE
		label.position = Vector3(0.0, y_pos, 0.4)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		root.add_child(label)

	return root


func _create_wall(correct_face: int, _wall_z: float) -> Dictionary:
	## 创建一面墙: 3个门 (左/中/右), 其中一个是正确答案
	## 返回 { "node": Node3D, "doors": Array[Dictionary] }
	var root := Node3D.new()
	root.name = "Wall"

	# 决定门的表情排列 (打乱, 确保 correct_face 在其中一个位置)
	var door_faces: Array = _generate_door_layout(correct_face)

	# 门的X位置: 左/中/右
	var lane_width: float = track_width / 3.0
	var door_positions: Array = [
		-lane_width,  # 左
		0.0,          # 中
		lane_width,   # 右
	]

	var doors: Array = []

	for i in range(3):
		var face_id: int = door_faces[i]
		var is_correct: bool = (face_id == correct_face)
		var x_pos: float = door_positions[i]

		# 门框 (视觉)
		var door_frame := MeshInstance3D.new()
		var dfm := BoxMesh.new()
		dfm.size = Vector3(door_width, wall_height, wall_thickness)
		door_frame.mesh = dfm
		door_frame.position = Vector3(x_pos, wall_height * 0.5, 0.0)
		var dmat := StandardMaterial3D.new()
		dmat.albedo_color = FACE_COLORS[face_id]
		dmat.emission_enabled = true
		dmat.emission = FACE_COLORS[face_id] * 0.3
		dmat.emission_energy_multiplier = 0.5
		dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		dmat.albedo_color.a = 0.7
		door_frame.material_override = dmat
		root.add_child(door_frame)

		# 门上表情 (中文大字)
		var label := Label3D.new()
		label.text = FACE_TEXT[face_id]
		label.font_size = 256
		label.outline_size = 16
		label.modulate = Color.WHITE
		label.position = Vector3(x_pos, wall_height * 0.5, wall_thickness * 0.5 + 0.1)
		root.add_child(label)

		# Area3D 检测车通过
		var area := Area3D.new()
		area.name = "DoorArea_%d" % i
		area.collision_layer = 0
		area.collision_mask = 2  # car layer
		area.monitoring = true
		var ashape := CollisionShape3D.new()
		var abox := BoxShape3D.new()
		abox.size = Vector3(door_width, wall_height, wall_thickness + 2.0)
		ashape.shape = abox
		ashape.position = Vector3(x_pos, wall_height * 0.5, 0.0)
		area.add_child(ashape)
		root.add_child(area)

		doors.append({
			"area": area,
			"face": face_id,
			"correct": is_correct,
			"triggered": {},  # car_id -> bool (防重复触发)
		})

	# 墙体 (门之间的实体部分) — 用 AnimatableBody3D 确保碰撞
	# 左墙段、中左柱、中右柱、右墙段
	var wall_segments: Array = _create_wall_segments(root, door_positions)

	var wall_info: Dictionary = {
		"node": root,
		"doors": doors,
		"correct_face": correct_face,
		"segments": wall_segments,
	}

	# 连接 Area3D 信号用 _physics_process 轮询代替 (更可靠)
	# 在 _physics_process 中检查每个 door area 的重叠体

	return wall_info


func _create_wall_segments(root: Node3D, door_positions: Array) -> Array:
	## 创建墙的实体碰撞部分 (门之间和两侧的墙壁)
	## 使用 AnimatableBody3D 确保物理碰撞严密
	var segments: Array = []
	var lane_width: float = track_width / 3.0
	var half_track: float = track_width * 0.5

	# 计算每个墙段的位置和尺寸
	# 布局: [左墙段] [左门] [中左柱] [中门] [中右柱] [右门] [右墙段]
	var segment_defs: Array = []

	# 左侧墙 (从左边界到左门左边缘)
	var left_door_left: float = door_positions[0] - door_width * 0.5
	var left_wall_width: float = left_door_left - (-half_track)
	if left_wall_width > 0.1:
		segment_defs.append({
			"x": (-half_track + left_door_left) * 0.5,
			"w": left_wall_width,
		})

	# 左门和中门之间的柱子
	var left_door_right: float = door_positions[0] + door_width * 0.5
	var mid_door_left: float = door_positions[1] - door_width * 0.5
	var pillar1_width: float = mid_door_left - left_door_right
	if pillar1_width > 0.1:
		segment_defs.append({
			"x": (left_door_right + mid_door_left) * 0.5,
			"w": pillar1_width,
		})

	# 中门和右门之间的柱子
	var mid_door_right: float = door_positions[1] + door_width * 0.5
	var right_door_left: float = door_positions[2] - door_width * 0.5
	var pillar2_width: float = right_door_left - mid_door_right
	if pillar2_width > 0.1:
		segment_defs.append({
			"x": (mid_door_right + right_door_left) * 0.5,
			"w": pillar2_width,
		})

	# 右侧墙 (从右门右边缘到右边界)
	var right_door_right: float = door_positions[2] + door_width * 0.5
	var right_wall_width: float = half_track - right_door_right
	if right_wall_width > 0.1:
		segment_defs.append({
			"x": (right_door_right + half_track) * 0.5,
			"w": right_wall_width,
		})

	# 创建每个墙段
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = wall_color
	wmat.metallic = 0.4
	wmat.roughness = 0.5

	for seg in segment_defs:
		var abody := AnimatableBody3D.new()
		abody.name = "WallSeg"
		abody.collision_layer = 1
		abody.collision_mask = 0
		var cshape := CollisionShape3D.new()
		var cbox := BoxShape3D.new()
		cbox.size = Vector3(seg["w"], wall_height, wall_thickness)
		cshape.shape = cbox
		cshape.position = Vector3(seg["x"], wall_height * 0.5, 0.0)
		abody.add_child(cshape)

		var wmesh := MeshInstance3D.new()
		var wm := BoxMesh.new()
		wm.size = Vector3(seg["w"], wall_height, wall_thickness)
		wmesh.mesh = wm
		wmesh.position = Vector3(seg["x"], wall_height * 0.5, 0.0)
		wmesh.material_override = wmat
		abody.add_child(wmesh)

		root.add_child(abody)
		segments.append(abody)

	return segments


func _generate_door_layout(correct_face: int) -> Array:
	## 生成3个门的表情排列: 三种表情各出现一次(不重复), 然后打乱位置
	## 墙面规则: 笑/冷/哭 三种必须都有, 只是位置随机
	var faces: Array = [Face.SMILE, Face.COLD, Face.CRY]
	# Fisher-Yates 打乱顺序
	for i in range(faces.size() - 1, 0, -1):
		var j: int = randi() % (i + 1)
		var tmp: int = faces[i]
		faces[i] = faces[j]
		faces[j] = tmp
	return faces


func _physics_process(delta: float) -> void:
	# 波次生成计时
	_wave_timer += delta
	if _wave_timer >= wave_interval:
		_wave_timer -= wave_interval
		_spawn_wave()

	# 移动所有活跃波次
	var waves_to_remove: Array = []
	for i in range(_active_waves.size()):
		var wave: Dictionary = _active_waves[i]
		var nodes: Array = wave["nodes"]
		var all_gone: bool = true
		for node in nodes:
			if node == null or not is_instance_valid(node):
				continue
			all_gone = false
			node.position.z += wall_speed * delta
		if all_gone or _wave_passed(wave):
			waves_to_remove.append(i)

	# 墙门检测
	for wave in _active_waves:
		if not wave.has("walls"):
			continue
		for wall_info in wave["walls"]:
			if not wall_info.has("doors"):
				continue
			for door in wall_info["doors"]:
				var area: Area3D = door["area"]
				if area == null or not is_instance_valid(area):
					continue
				for body in area.get_overlapping_bodies():
					if not body is RigidBody3D:
						continue
					var car: RigidBody3D = body as RigidBody3D
					var car_id: int = car.get_instance_id()
					if door["triggered"].has(car_id):
						continue
					door["triggered"][car_id] = true
					if not door["correct"]:
						_hit_car(car, wall_info["node"])

	# 清理已通过的波次
	for i in range(waves_to_remove.size() - 1, -1, -1):
		var idx: int = waves_to_remove[i]
		var wave: Dictionary = _active_waves[idx]
		for node in wave["nodes"]:
			if node != null and is_instance_valid(node):
				node.queue_free()
		_active_waves.remove_at(idx)


func _hit_car(car: RigidBody3D, wall_node: Node3D) -> void:
	## 车选错门, 被墙撞飞
	var wall_pos: Vector3 = wall_node.global_position if is_instance_valid(wall_node) else global_position
	var car_pos: Vector3 = car.global_position
	var push_dir: Vector3 = (car_pos - wall_pos)
	push_dir.y = 0.0
	if push_dir.length() > 0.001:
		push_dir = push_dir.normalized()
	else:
		push_dir = Vector3(0.0, 0.0, 1.0)

	var launch_dir: Vector3 = (Vector3.UP * hit_up_ratio + push_dir * (1.0 - hit_up_ratio)).normalized()
	var new_v: Vector3 = launch_dir * hit_impulse

	if car.has_method("apply_jump_pad_kick"):
		car.apply_jump_pad_kick(new_v, hit_skip_stick)
	else:
		car.linear_velocity = new_v

	print("[FaceWall] 撞飞! impulse=", hit_impulse)


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "track_length", "label": "直道长度(m)", "min": 100.0, "max": 1000.0, "step": 10.0, "value": track_length},
		{"key": "track_width", "label": "直道宽度(m)", "min": 8.0, "max": 40.0, "step": 1.0, "value": track_width},
		{"key": "rail_height", "label": "护栏高度(m)", "min": 1.0, "max": 10.0, "step": 0.5, "value": rail_height},
		{"key": "wave_interval", "label": "波次间隔(s)", "min": 2.0, "max": 20.0, "step": 0.5, "value": wave_interval},
		{"key": "wall_speed", "label": "移动速度(m/s)", "min": 10.0, "max": 100.0, "step": 5.0, "value": wall_speed},
		{"key": "sign_to_wall_gap", "label": "告示牌到第1面墙(m)", "min": 5.0, "max": 80.0, "step": 1.0, "value": sign_to_wall_gap},
		{"key": "wall_to_wall_gap", "label": "墙与墙间距(m)", "min": 3.0, "max": 50.0, "step": 1.0, "value": wall_to_wall_gap},
		{"key": "wall_height", "label": "墙高度(m)", "min": 2.0, "max": 15.0, "step": 0.5, "value": wall_height},
		{"key": "wall_thickness", "label": "墙厚度(m)", "min": 0.3, "max": 3.0, "step": 0.1, "value": wall_thickness},
		{"key": "door_width", "label": "门宽度(m)", "min": 2.0, "max": 10.0, "step": 0.5, "value": door_width},
		{"key": "hit_impulse", "label": "撞飞冲量(m/s)", "min": 10.0, "max": 100.0, "step": 5.0, "value": hit_impulse},
		{"key": "hit_up_ratio", "label": "弹飞向上比", "min": 0.0, "max": 1.0, "step": 0.05, "value": hit_up_ratio},
		{"key": "hit_skip_stick", "label": "弹飞豁免(s)", "min": 0.1, "max": 3.0, "step": 0.1, "value": hit_skip_stick},
		{"key": "sign_height", "label": "告示牌高度(m)", "min": 2.0, "max": 10.0, "step": 0.5, "value": sign_height},
		{"key": "sign_width", "label": "告示牌宽度(m)", "min": 1.0, "max": 8.0, "step": 0.5, "value": sign_width},
		{"key": "sign_mount_height", "label": "告示牌安装高度(m)", "min": 3.0, "max": 20.0, "step": 0.5, "value": sign_mount_height},
		{"key": "sign_side_offset", "label": "告示牌侧偏(m)", "min": 0.0, "max": 10.0, "step": 0.5, "value": sign_side_offset},
	]

var _rebuild_pending: bool = false

func set_editable_param(key: String, value: float) -> void:
	match key:
		"track_length": track_length = value
		"track_width": track_width = value
		"rail_height": rail_height = value
		"wave_interval": wave_interval = value
		"wall_speed": wall_speed = value
		"sign_to_wall_gap": sign_to_wall_gap = value
		"wall_to_wall_gap": wall_to_wall_gap = value
		"wall_height": wall_height = value
		"wall_thickness": wall_thickness = value
		"door_width": door_width = value
		"hit_impulse": hit_impulse = value
		"hit_up_ratio": hit_up_ratio = value
		"hit_skip_stick": hit_skip_stick = value
		"sign_height": sign_height = value
		"sign_width": sign_width = value
		"sign_mount_height": sign_mount_height = value
		"sign_side_offset": sign_side_offset = value
	# 延迟 rebuild: 批量调用 set_editable_param 时只 rebuild 一次
	# (apply_mechanism_defaults 会连续调用多个参数, 不应每次都重建)
	if not _rebuild_pending:
		_rebuild_pending = true
		call_deferred("_deferred_rebuild")

func _deferred_rebuild() -> void:
	_rebuild_pending = false
	_rebuild()
