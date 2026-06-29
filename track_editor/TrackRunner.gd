extends Node3D
## ============================================================
##  赛道运行器 — 加载 RaceTrackData 并跑游戏模式
##
##  入口:
##   1) TrackEditor 点"测试" → 保存到 user://tracks/_test.tres → 切到本场景
##   2) SceneSelectorUI 点用户保存的赛道 → 设 _track_to_load → 切到本场景
##
##  本场景做的事:
##   · _ready 时根据全局变量 TrackRunnerState.track_to_load (默认 _test.tres) 加载数据
##   · 按 RaceTrackData 实例化所有积木+锚点
##   · 实例化 car.tscn, 放在 spawn_position
##   · 实例化 Camera3D, target = car/CarMesh
##   · 接入 TrackSetup (复用现有 _generate_track_collision 不必要因为积木自带碰撞,
##                       但保留 _adjust_car_spawn 的射线落地逻辑也行)
## ============================================================

# 这个全局变量记录"下次进 TrackRunner 应该加载哪个 .tres"
# 由 TrackEditor (测试) 或 SceneSelectorUI (加载用户赛道) 设置
# 用 autoload 单例 TrackRunnerState 暴露 (见 TrackRunnerState.gd)

func _ready() -> void:
	var path: String = _resolve_track_path()
	if path.is_empty():
		push_warning("[TrackRunner] 没有指定赛道路径, 默认加载 _test.tres")
		path = "user://tracks/_test.tres"
	if not FileAccess.file_exists(ProjectSettings.globalize_path(path)) and not ResourceLoader.exists(path):
		push_warning("[TrackRunner] 赛道文件不存在: %s" % path)
		# 创建空的占位以防崩溃 (生成基础地面 + 默认 car 位置)
		_spawn_default_car_and_camera(Vector3(0, 5, 0), 0.0)
		return
	var res: Resource = load(path) as Resource
	# 用 duck typing 判断: 只要有 blocks 字段就当 RaceTrackData 用
	# (避免 class_name RaceTrackData 注册失败时的 parse error)
	if res == null or not ("blocks" in res):
		push_warning("[TrackRunner] 资源不是 RaceTrackData: %s" % path)
		_spawn_default_car_and_camera(Vector3(0, 5, 0), 0.0)
		return
	_load_track(res)


# ESC 返回编辑器 (进入该地图的编辑器界面)
# 用户需求 (2026-06-03): "进入自定义地图后按 ESC 应该进入该地图的编辑器界面"
# 实现: 把当前加载的赛道路径写入 TrackRunnerState.last_editor_track_path,
#       TrackEditor._ready 会检测到这个路径并自动 _load_track_data 加载进编辑器
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			# 闯关模式下 ESC = 退出闯关
			var challenge_runner: Node = get_node_or_null("/root/ChallengeRunner")
			if challenge_runner and challenge_runner.get("is_running"):
				challenge_runner.call("stop_challenge")
			var st: Node = get_node_or_null("/root/TrackRunnerState")
			if st:
				var track_path: String = _resolve_track_path()
				st.set("last_editor_track_path", track_path)
			get_tree().change_scene_to_file("res://track_editor/TrackEditor.tscn")
			get_viewport().set_input_as_handled()


func _resolve_track_path() -> String:
	var st: Node = get_node_or_null("/root/TrackRunnerState")
	if st and "track_to_load" in st:
		var p: String = String(st.get("track_to_load"))
		if p != "":
			return p
	return "user://tracks/_test.tres"


func _load_track(data: Resource) -> void:
	# 1. 实例化积木
	var blocks_root := Node3D.new()
	blocks_root.name = "Blocks"
	add_child(blocks_root)
	var blocks_arr: Array = data.get("blocks")
	for b in blocks_arr:
		var bid: String = b.get("id", "")
		var bxform: Transform3D = b.get("transform", Transform3D.IDENTITY)
		# Bug 修复 (2026-05-14): 之前没读 params 字段, 导致编辑器里调好的 length / 弯道 angle / radius
		# 在测试场景里全变默认值. 现在读取 params 并通过 set_editable_param 应用回去.
		# 旧赛道没 params 字段 → 默认 {} → 用积木默认参数 (兼容)
		var bparams: Dictionary = b.get("params", {})
		var bpath: String = "res://track_editor/blocks/%s.tscn" % bid
		var packed: PackedScene = load(bpath) as PackedScene
		if packed == null:
			push_warning("[TrackRunner] 加载积木失败: %s" % bpath)
			continue
		var node: Node3D = packed.instantiate()
		blocks_root.add_child(node)
		node.global_transform = bxform
		# 在 add_child 之后再 set 参数, 因为 setter 内部 rebuild() 需要 is_inside_tree()
		# 各 setter 调用顺序无所谓, 最后一次 rebuild 会用所有最新值
		if not bparams.is_empty() and node.has_method("set_editable_param"):
			# 先应用普通参数 (跳过 _wl_ / _wr_ 开头的墙壁序列化数据)
			for k in bparams.keys():
				if String(k).begins_with("_wl_") or String(k).begins_with("_wr_"):
					continue
				node.call("set_editable_param", String(k), float(bparams[k]))
			# 恢复 WallCurve 数据 (编辑器里关闭的墙壁游戏中也要关闭)
			if node.has_method("get_wall_curve_left") and bparams.has("_wl_count"):
				var wl: WallCurve = node.call("get_wall_curve_left")
				var count: int = int(bparams["_wl_count"])
				wl.nodes.clear()
				for wi in range(count):
					var t: float = float(bparams.get("_wl_t_%d" % wi, 0.0))
					var active: bool = float(bparams.get("_wl_a_%d" % wi, 1.0)) > 0.5
					wl.nodes.append({"t": t, "active": active})
				if wl.nodes.size() < 2:
					wl.nodes = [{"t": 0.0, "active": true}, {"t": 1.0, "active": true}]
			if node.has_method("get_wall_curve_right") and bparams.has("_wr_count"):
				var wr: WallCurve = node.call("get_wall_curve_right")
				var count_r: int = int(bparams["_wr_count"])
				wr.nodes.clear()
				for wi in range(count_r):
					var t: float = float(bparams.get("_wr_t_%d" % wi, 0.0))
					var active: bool = float(bparams.get("_wr_a_%d" % wi, 1.0)) > 0.5
					wr.nodes.append({"t": t, "active": active})
				if wr.nodes.size() < 2:
					wr.nodes = [{"t": 0.0, "active": true}, {"t": 1.0, "active": true}]
			# 墙壁数据恢复后重建 (让新的 WallCurve 状态生效)
			if (bparams.has("_wl_count") or bparams.has("_wr_count")) and node.has_method("_rebuild"):
				node.call("_rebuild")

	# 2. 实例化钩索锚点
	var anchors_root := Node3D.new()
	anchors_root.name = "Anchors"
	add_child(anchors_root)
	var anchor_scene: PackedScene = load("res://grapple/GrappleAnchor.tscn") as PackedScene
	var anchors_arr: Array = data.get("grapple_anchors")
	if anchor_scene != null:
		for a in anchors_arr:
			var ap: Vector3 = a.get("position", Vector3.ZERO)
			var ar: float = a.get("anchor_radius", 1.5)
			var dr: float = a.get("detect_radius", 60.0)
			var col: Color = a.get("color", Color(0.3, 0.85, 1.0))
			var anode: Node3D = anchor_scene.instantiate()
			anchors_root.add_child(anode)
			anode.global_position = ap
			# 设置锚点参数 (GrappleAnchor.gd 的 setter 会重建可视化)
			if "anchor_radius" in anode:
				anode.set("anchor_radius", ar)
			if "detect_radius" in anode:
				anode.set("detect_radius", dr)
			if "anchor_color" in anode:
				anode.set("anchor_color", col)

	# 3. 实例化 Car
	var spawn_pos: Vector3 = data.get("spawn_position")
	var spawn_yaw: float = float(data.get("spawn_yaw_rad"))
	_spawn_default_car_and_camera(spawn_pos, spawn_yaw)

	# 4. 应用初始地面 (Ground) 配置
	# 用户要求: 编辑器能开关基础地面 + 改颜色, 数据存 RaceTrackData, 由 TrackRunner 应用
	var ground_node: Node = get_node_or_null("Ground")
	if ground_node != null:
		var ground_enabled: bool = bool(data.get("ground_enabled")) if "ground_enabled" in data else true
		ground_node.visible = ground_enabled
		# 旧 ground 节点可能是 StaticBody3D, 子节点 CollisionShape3D 也要跟着开关
		# 否则隐藏视觉但还能撞到 collision
		var col_shape: Node = ground_node.get_node_or_null("CollisionShape3D")
		if col_shape and col_shape is CollisionShape3D:
			(col_shape as CollisionShape3D).disabled = not ground_enabled
		# 颜色
		if "ground_color" in data:
			var ground_col: Color = data.get("ground_color")
			var ground_mi: Node = ground_node.get_node_or_null("MeshInstance3D")
			if ground_mi and ground_mi is MeshInstance3D:
				var mi: MeshInstance3D = ground_mi as MeshInstance3D
				# 优先 override 单实例材质 (旧 mesh 上的材质是共享 SubResource, 改了会污染所有 .tscn)
				var mat := StandardMaterial3D.new()
				mat.albedo_color = ground_col
				mi.material_override = mat

	print("[TrackRunner] 赛道加载完成: ", String(data.get("track_name")),
		" | 积木 ", blocks_arr.size(),
		" 锚点 ", anchors_arr.size())
	# 把赛道名称写入全局状态, 供 HUD 读取显示
	var st: Node = get_node_or_null("/root/TrackRunnerState")
	if st and "track_display_name" in st:
		st.set("track_display_name", String(data.get("track_name")))


func _reset_all_mechanisms() -> void:
	## 按 B 复位时重置所有机关状态 (节奏归零/门恢复/滑块归位等)
	var blocks_root: Node = get_node_or_null("Blocks")
	if blocks_root == null:
		return
	for child in blocks_root.get_children():
		if child.has_method("reset_state"):
			child.call("reset_state")


func _spawn_default_car_and_camera(spawn_pos: Vector3, spawn_yaw: float) -> void:
	# Car
	var car_scene: PackedScene = load("res://core/car.tscn") as PackedScene
	if car_scene == null:
		push_error("[TrackRunner] 无法加载 car.tscn")
		return
	var car: Node3D = car_scene.instantiate()
	add_child(car)
	# 设置 transform: 位置 + yaw 旋转
	var car_basis := Basis(Vector3.UP, spawn_yaw)
	car.global_transform = Transform3D(car_basis, spawn_pos)
	# CarMesh 是 top_level=true, 不会自动跟随父节点, 必须手动同步位置和朝向
	var car_mesh_node: Node3D = car.get_node_or_null("CarMesh")
	if car_mesh_node:
		var sphere_off: Vector3 = car.get("sphere_offset") if "sphere_offset" in car else Vector3.DOWN
		car_mesh_node.global_position = spawn_pos + sphere_off
		car_mesh_node.global_transform.basis = car_basis
	# Camera (复用现有 Camera3D.gd)
	var cam_script := load("res://core/Camera3D.gd")
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.set_script(cam_script)
	add_child(cam)
	cam.current = true
	cam.fov = 75.0
	# 让 Camera3D.gd 把 target 设为 car/CarMesh
	# 用 deferred 等 car 内部 onready 完成
	cam.call_deferred("set", "target", car.get_node_or_null("CarMesh"))
	# 加一点初始 transform (跟随相机会立刻 lerp 过去)
	cam.global_transform = Transform3D(Basis(), spawn_pos + Vector3(0, 6.5, 10))
	# 显式记录出生点 (确保按 B 能回到正确位置)
	# 必须 deferred: 等 car._ready() 完成, car_mesh 引用已初始化
	car.call_deferred("_record_initial_position")
	# 连接复位信号: 按 B 复位时重置所有机关状态
	if car.has_signal("reset_to_origin_triggered"):
		car.connect("reset_to_origin_triggered", _reset_all_mechanisms)
