extends Node
## ============================================================
## CoopMode.gd — 双人共玩模式主控制器 (Autoload 单例)
## ============================================================
## 功能:
##   · 通过 Tuner TAB 配置开启/关闭双人模式
##   · 分屏: 左右两个 SubViewport, 分别给 1P 和 2P
##   · 1P 用键盘控制, 2P 用手柄控制
##   · 按 L 键在两名玩家之间生成/断开绳子
##   · 绳子有固定长度 + 微小弹性, 产生左右拉扯力
##   · 双 HUD 适配: 两名玩家各有独立的氮气槽/小喷灯/炫点
## ============================================================

## 双人模式是否启用 (由 Tuner 控制)
var coop_enabled: bool = false:
	set(v):
		coop_enabled = v
		if v and not _active:
			call_deferred("activate_coop")
		elif not v and _active:
			call_deferred("deactivate_coop")

## 绳子参数 (由 Tuner 控制)
var rope_length: float = 20.0          ## 绳子自然长度 (米)
var rope_stiffness: float = 200.0      ## 绳子刚度 (N/m, 弹簧系数) — 降低让绳子更柔软
var rope_damping: float = 30.0         ## 绳子阻尼 (防止无限振荡)
var rope_elasticity: float = 3.0       ## 弹性余量 (米): 超过自然长度多少才开始施力
var rope_max_force: float = 1500.0     ## 绳子最大拉力 (N) — 降低防止压制引擎
var rope_front_pull_ratio: float = 0.15 ## 前车(领先车)受到的回拉力比例 (0=前车不受影响)
var rope_rear_pull_ratio: float = 1.0   ## 后车(落后车)受到的拉力比例 (1=全力拽)
var rope_rear_steer_freedom: float = 0.7 ## 后车转向自由度 (0=完全被拽着走无法转向, 1=可以自由转向)
var rope_visual_thickness: float = 0.12 ## 绳子视觉粗细 (米)
var rope_color: Color = Color(0.9, 0.75, 0.2, 1.0)  ## 绳子颜色

## 后车卡墙摩擦削减参数 (由 Tuner 控制)
var rope_friction_mult_when_pulled: float = 0.15  ## 后车被绳子拉时的摩擦倍率 (0=无摩擦, 1=正常摩擦). 越小后车越容易被拉动
var rope_stuck_speed_threshold: float = 3.0       ## 后车速度低于此值(km/h)且绳子拉紧时, 视为卡住, 开始削减摩擦

## 绳子缠绕系统参数 (由 Tuner 控制)
var rope_wrap_enabled: bool = true          ## 绳子缠绕开关 (true=绳子沿墙面缠绕, false=绳子可穿墙)
var rope_wrap_offset: float = 1.5           ## 锚点离墙面的偏移距离 (米), 越大绳子越远离墙面
var rope_wrap_max_anchors: int = 20         ## 最大缠绕锚点数量
var rope_wrap_min_spacing: float = 2.0      ## 锚点之间的最小间距 (米), 防止重复添加
var rope_wrap_min_seg_len: float = 0.5      ## 最短段检测阈值 (米), 太短的段不检测

## 绳子缠绕系统内部状态
var _rope_wrap_points: Array[Vector3] = []  ## 绳子缠绕锚点列表 (沿墙面的拐点)
var _rope_total_length: float = 0.0         ## 绳子当前总路径长度 (含缠绕)
var _rope_has_penetration: bool = false     ## 绳子当前是否有穿墙段 (true=有穿墙, 不施加拉力)

## 内部状态
var _active: bool = false              ## 当前是否在双人模式运行中
var _car_1p: RigidBody3D = null        ## 1P 赛车引用
var _car_2p: RigidBody3D = null        ## 2P 赛车引用
var _rope_connected: bool = false      ## 绳子是否已连接
var _rope_segments: Array[MeshInstance3D] = []  ## 绳子各段的视觉 mesh
var _rope_mat: StandardMaterial3D = null

## 分屏节点
var _viewport_1p: SubViewport = null
var _viewport_2p: SubViewport = null
var _camera_1p: Camera3D = null
var _camera_2p: Camera3D = null
var _canvas_layer: CanvasLayer = null
var _hbox: HBoxContainer = null

## HUD 节点
var _hud_1p: CanvasLayer = null        ## 1P 的 HUD (左半屏)
var _hud_2p: CanvasLayer = null        ## 2P 的 HUD (右半屏)
var _original_hud: CanvasLayer = null  ## 原始 HUD (隐藏)

## 绳子追随 (吸附) 状态
var _follow_active: bool = false          ## 是否正在追随飞行中
var _follow_src: RigidBody3D = null        ## 正在飞行的车
var _follow_target: RigidBody3D = null     ## 飞行目标车 (用于实时获取朝向)
var _follow_start_pos: Vector3 = Vector3.ZERO  ## 飞行起点
var _follow_target_pos: Vector3 = Vector3.ZERO ## 飞行终点 (对方当前位置)
var _follow_start_basis: Basis = Basis.IDENTITY ## 飞行起始朝向
var _follow_elapsed: float = 0.0          ## 已飞行时间
var _follow_duration: float = 0.5         ## 飞行总时长 (秒)

## 原始场景备份
var _original_camera: Camera3D = null


func _ready() -> void:
	set_process(false)
	set_physics_process(false)


func _input(event: InputEvent) -> void:
	# L 键: 连接/断开绳子
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_L and _active and _car_1p and _car_2p:
			_toggle_rope()

	# 绳子追随: 按下时开始向另一名玩家加速飞行 (仅绳子连接时可用)
	if _active and _rope_connected and _car_1p and _car_2p and not _follow_active:
		# 1P (键盘 ALT): 1P 飞向 2P
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_ALT or event.physical_keycode == KEY_ALT:
				_start_follow(_car_1p, _car_2p)
				print("[CoopMode] 1P 开始追随飞向 2P")
		# 2P (手柄 A): 2P 飞向 1P
		if Input.is_action_just_pressed("p2_rope_follow"):
			_start_follow(_car_2p, _car_1p)
			print("[CoopMode] 2P 开始追随飞向 1P")


func _physics_process(delta: float) -> void:
	if not _active:
		return
	if _car_1p == null or _car_2p == null:
		return
	# 追随飞行更新 (优先于绳子物理)
	if _follow_active:
		_update_follow(delta)
	# 绳子物理
	if _rope_connected and not _follow_active:
		_apply_rope_physics(delta)
		_update_rope_visual()


## 激活双人模式 (由 Tuner 或外部调用)
func activate_coop() -> void:
	if _active:
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	# 查找当前场景中的赛车
	_car_1p = _find_car_in_scene()
	if _car_1p == null:
		push_warning("[CoopMode] 找不到 1P 赛车, 无法启动双人模式")
		return
	# 设置 1P 的 player_id
	if "player_id" in _car_1p:
		_car_1p.set("player_id", 0)
	# 实例化 2P 赛车
	_spawn_2p_car()
	# 设置分屏
	_setup_split_screen()
	# 设置双 HUD
	_setup_dual_hud()
	_active = true
	set_process(true)
	set_physics_process(true)
	print("[CoopMode] 双人模式已激活!")


## 停用双人模式
func deactivate_coop() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	set_physics_process(false)
	_rope_connected = false
	_cleanup_split_screen()
	_cleanup_dual_hud()
	_cleanup_2p_car()
	_cleanup_rope_visual()
	print("[CoopMode] 双人模式已停用")


## 查找场景中的赛车
func _find_car_in_scene() -> RigidBody3D:
	var root: Node = get_tree().current_scene
	if root == null:
		return null
	return _find_car_recursive(root)


func _find_car_recursive(node: Node) -> RigidBody3D:
	if node is RigidBody3D and "throttle_input" in node:
		return node as RigidBody3D
	for child in node.get_children():
		var result: RigidBody3D = _find_car_recursive(child)
		if result != null:
			return result
	return null


## 实例化 2P 赛车
func _spawn_2p_car() -> void:
	var car_scene: PackedScene = load("res://car.tscn") as PackedScene
	if car_scene == null:
		push_error("[CoopMode] 无法加载 car.tscn")
		return
	_car_2p = car_scene.instantiate() as RigidBody3D
	# 设置 2P 的 player_id
	if "player_id" in _car_2p:
		_car_2p.set("player_id", 1)
	# 禁用 2P 的 Tuner 和 HUD 自动生成 (CoopMode 自己管 HUD)
	if "auto_spawn_tuner" in _car_2p:
		_car_2p.set("auto_spawn_tuner", false)
	if "auto_spawn_hud" in _car_2p:
		_car_2p.set("auto_spawn_hud", false)
	# 添加到场景树 (触发 _ready)
	get_tree().current_scene.add_child(_car_2p)
	# 冻结 2P 物理, 防止在 _finalize_2p_spawn 完成前自由落体
	_car_2p.freeze = true
	# ---- 同步 1P 的所有 3C 参数到 2P (在 add_child 之后, _ready 已完成) ----
	_sync_car_params(_car_1p, _car_2p)
	# 延迟执行位置/朝向设置和运行时状态初始化
	# 等待 TrackSetup 对 1P 完成 _adjust_car_spawn 后再设置 2P 的位置
	call_deferred("_finalize_2p_spawn")


## 延迟完成 2P 赛车的位置/朝向设置
## 等待 TrackSetup._adjust_car_spawn 完成后 (它 await 了两帧物理),
## 再把 2P 放到 1P 旁边, 确保位置和朝向都正确
func _finalize_2p_spawn() -> void:
	if _car_1p == null or _car_2p == null:
		return
	# 再等几帧, 确保 TrackSetup._adjust_car_spawn 已完成 (它 await 两帧物理)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _car_1p == null or _car_2p == null:
		return

	# 获取 1P 的最终位置和朝向 (TrackSetup 已经把 1P 落到地面了)
	var car_mesh_1p: Node3D = _car_1p.get_node_or_null("CarMesh")
	var car_mesh_2p: Node3D = _car_2p.get_node_or_null("CarMesh")
	if car_mesh_1p == null or car_mesh_2p == null:
		push_error("[CoopMode] 找不到 CarMesh 节点")
		return

	# 计算 2P 的生成位置: 在 1P 右侧 5m (沿 1P 的本地 X 轴)
	var right_dir: Vector3 = car_mesh_1p.global_transform.basis.x.normalized()
	var spawn_offset: Vector3 = right_dir * 5.0
	var spawn_pos_mesh: Vector3 = car_mesh_1p.global_position + spawn_offset
	var sphere_off: Vector3 = _car_2p.get("sphere_offset") if "sphere_offset" in _car_2p else Vector3.DOWN

	# 设置 2P 刚体位置
	_car_2p.global_position = spawn_pos_mesh - sphere_off
	_car_2p.linear_velocity = Vector3.ZERO
	_car_2p.angular_velocity = Vector3.ZERO

	# 设置 2P CarMesh 位置和朝向 (与 1P 完全一致)
	car_mesh_2p.global_position = spawn_pos_mesh
	car_mesh_2p.global_transform.basis = car_mesh_1p.global_transform.basis

	# 重新记录 2P 的出生点 (覆盖 _ready 中记录的高空位置)
	# 直接设置内部变量确保出生点一定正确 (不依赖 has_method 的行为)
	_car_2p.set("_initial_car_mesh_position", car_mesh_2p.global_position)
	_car_2p.set("_initial_car_mesh_basis", car_mesh_2p.global_transform.basis)
	_car_2p.set("_initial_recorded", true)
	print("[CoopMode] 2P 出生点已强制设置: pos=%s" % str(car_mesh_2p.global_position))

	# 重新初始化 2P 的运行时状态
	_reinit_runtime_state(_car_2p)

	# ---- 同步 1P 子节点的参数到 2P 子节点 ----
	# Tuner 加载 cfg 时 2P 还不存在, 所以 grapple/car_mesh/boost_fx 参数只应用到了 1P
	# 这里从 1P 的子节点复制所有 @export 属性到 2P 的对应子节点
	_sync_child_node_params(_car_1p, _car_2p, "GrappleHook")
	_sync_child_node_params(_car_1p, _car_2p, "CarMesh")
	# BoostFX 挂在 CarMesh 下面, 需要遍历同步
	_sync_boost_fx_params(_car_1p, _car_2p)

	# 解冻 2P 物理 (位置和朝向已设置完毕)
	_car_2p.freeze = false
	# 强制重置 2P 的空中状态 (防止 freeze 期间被错误标记为 airborne)
	_car_2p.set("_is_airborne", false)

	# 初始化分屏摄像机位置 (避免从 (0,0,0) 开始 lerp 的视觉跳变)
	if _camera_1p and car_mesh_1p and "offset" in _camera_1p:
		var cam_target: Transform3D = car_mesh_1p.global_transform.translated_local(_camera_1p.offset)
		_camera_1p.global_position = cam_target.origin
		_camera_1p.look_at(car_mesh_1p.global_position, Vector3.UP)
	if _camera_2p and car_mesh_2p and "offset" in _camera_2p:
		var cam_target: Transform3D = car_mesh_2p.global_transform.translated_local(_camera_2p.offset)
		_camera_2p.global_position = cam_target.origin
		_camera_2p.look_at(car_mesh_2p.global_position, Vector3.UP)

	print("[CoopMode] 2P 赛车已生成, 位置: %s, 朝向与 1P 一致" % str(spawn_pos_mesh))


## 重新初始化赛车的运行时状态 (在参数同步后调用)
func _reinit_runtime_state(car: RigidBody3D) -> void:
	if car == null:
		return
	# 重新初始化氮气存量 (用同步后的 spawn_nitro_stock)
	if "spawn_nitro_enabled" in car and "spawn_nitro_stock" in car and "max_nitro_stock" in car:
		if car.spawn_nitro_enabled:
			car.nitro_stock = mini(car.spawn_nitro_stock, car.max_nitro_stock)
			if car.has_signal("nitro_stock_changed"):
				car.emit_signal("nitro_stock_changed", car.nitro_stock, car.max_nitro_stock)
	# 重新初始化曲线 (如果同步后曲线为 null, 用默认曲线)
	if car.has_method("_init_default_curves"):
		car._init_default_curves()


## 将 src 赛车的所有 @export 属性同步到 dst 赛车 (3C 参数完全一致)
func _sync_car_params(src: RigidBody3D, dst: RigidBody3D) -> void:
	if src == null or dst == null:
		return
	var synced_count: int = 0
	for prop_info in src.get_property_list():
		var prop_name: String = prop_info["name"]
		if prop_name in ["player_id", "global_position", "global_rotation", "position", "rotation", "transform", "global_transform"]:
			continue
		var usage: int = prop_info["usage"]
		if not (usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR):
			continue
		if prop_name in ["script", "name", "owner", "scene_file_path", "unique_name_in_owner"]:
			continue
		if prop_name in dst:
			var val = src.get(prop_name)
			if val is Curve:
				val = val.duplicate() if val != null else null
			dst.set(prop_name, val)
			synced_count += 1
	print("[CoopMode] 已同步 %d 个参数从 1P → 2P" % synced_count)


## 同步指定子节点的所有 @export 属性 (从 1P 的子节点复制到 2P 的同名子节点)
func _sync_child_node_params(src_car: RigidBody3D, dst_car: RigidBody3D, child_name: String) -> void:
	if src_car == null or dst_car == null:
		return
	var src_node: Node = src_car.get_node_or_null(child_name)
	var dst_node: Node = dst_car.get_node_or_null(child_name)
	if src_node == null or dst_node == null:
		return
	var synced: int = 0
	for prop_info in src_node.get_property_list():
		var prop_name: String = prop_info["name"]
		if prop_name in ["script", "name", "owner", "position", "rotation", "transform", "global_transform", "global_position", "global_rotation"]:
			continue
		var usage: int = prop_info["usage"]
		if not (usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR):
			continue
		if prop_name in dst_node:
			var val = src_node.get(prop_name)
			if val is Curve:
				val = val.duplicate() if val != null else null
			dst_node.set(prop_name, val)
			synced += 1
	if synced > 0:
		print("[CoopMode] 已同步 %s 的 %d 个参数到 2P" % [child_name, synced])


## 同步 BoostFX 参数 (BoostFX 挂在 CarMesh/tailpipe 下面, 可能有多个)
func _sync_boost_fx_params(src_car: RigidBody3D, dst_car: RigidBody3D) -> void:
	if src_car == null or dst_car == null:
		return
	var src_mesh: Node = src_car.get_node_or_null("CarMesh")
	var dst_mesh: Node = dst_car.get_node_or_null("CarMesh")
	if src_mesh == null or dst_mesh == null:
		return
	# 递归收集所有 BoostFX 节点 (通过检查是否有 "boost_speed" 属性来识别)
	var src_fx_list: Array = []
	var dst_fx_list: Array = []
	_collect_boost_fx_recursive(src_mesh, src_fx_list)
	_collect_boost_fx_recursive(dst_mesh, dst_fx_list)
	# 按索引一一对应同步
	var count: int = mini(src_fx_list.size(), dst_fx_list.size())
	if count == 0:
		return
	for i in range(count):
		var src_fx: Node = src_fx_list[i]
		var dst_fx: Node = dst_fx_list[i]
		for prop_info in src_fx.get_property_list():
			var prop_name: String = prop_info["name"]
			if prop_name in ["script", "name", "owner", "position", "rotation", "transform", "global_transform"]:
				continue
			var usage: int = prop_info["usage"]
			if not (usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR):
				continue
			if prop_name in dst_fx:
				var val = src_fx.get(prop_name)
				if val is Curve:
					val = val.duplicate() if val != null else null
				dst_fx.set(prop_name, val)
	print("[CoopMode] 已同步 %d 个 BoostFX 节点的参数到 2P" % count)


## 递归收集所有 BoostFX 节点 (通过脚本路径 "BoostFX.gd" 识别, 与 Tuner 一致)
func _collect_boost_fx_recursive(node: Node, out: Array) -> void:
	for child in node.get_children():
		var s: Script = child.get_script() as Script
		if s != null and str(s.resource_path).ends_with("BoostFX.gd"):
			out.append(child)
		else:
			_collect_boost_fx_recursive(child, out)


## ============================================================
##  分屏设置
##  设计: CanvasLayer layer=-1 (在 HUD/Tuner/SceneSelector 之下)
##  所有 Control 节点 mouse_filter=IGNORE (不拦截输入)
##  Tuner(layer=1) / HUD(layer=1) / SceneSelector(layer=10) 正常显示在最上层
## ============================================================
func _setup_split_screen() -> void:
	# 保存原始摄像机
	_original_camera = get_viewport().get_camera_3d()
	if _original_camera:
		_original_camera.current = false

	# 创建 CanvasLayer 用于分屏渲染 (layer=-1, 在所有 UI 之下)
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.name = "CoopSplitScreen"
	_canvas_layer.layer = -1
	get_tree().current_scene.add_child(_canvas_layer)

	# 创建水平分割容器 (不拦截鼠标)
	_hbox = HBoxContainer.new()
	_hbox.name = "SplitHBox"
	_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hbox.add_theme_constant_override("separation", 4)
	_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_layer.add_child(_hbox)

	# 1P SubViewportContainer + SubViewport
	var vpc_1p := SubViewportContainer.new()
	vpc_1p.name = "VPC_1P"
	vpc_1p.stretch = true
	vpc_1p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc_1p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc_1p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hbox.add_child(vpc_1p)

	_viewport_1p = SubViewport.new()
	_viewport_1p.name = "Viewport_1P"
	_viewport_1p.handle_input_locally = false
	_viewport_1p.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vpc_1p.add_child(_viewport_1p)

	# 2P SubViewportContainer + SubViewport
	var vpc_2p := SubViewportContainer.new()
	vpc_2p.name = "VPC_2P"
	vpc_2p.stretch = true
	vpc_2p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc_2p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc_2p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hbox.add_child(vpc_2p)

	_viewport_2p = SubViewport.new()
	_viewport_2p.name = "Viewport_2P"
	_viewport_2p.handle_input_locally = false
	_viewport_2p.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vpc_2p.add_child(_viewport_2p)

	# 为每个 viewport 创建摄像机 (使用与单人模式完全一致的 Camera3D.gd 脚本)
	var cam_script: GDScript = load("res://Camera3D.gd") as GDScript
	var car_mesh_1p: Node3D = _car_1p.get_node_or_null("CarMesh") if _car_1p else null
	var car_mesh_2p: Node3D = _car_2p.get_node_or_null("CarMesh") if _car_2p else null

	_camera_1p = Camera3D.new()
	_camera_1p.name = "Camera_1P"
	_camera_1p.current = true
	if cam_script:
		_camera_1p.set_script(cam_script)
		# 复制原始摄像机的参数 (如果有)
		if _original_camera and _original_camera.get_script() == cam_script:
			_copy_camera_params(_original_camera, _camera_1p)
		_camera_1p.target = car_mesh_1p
	_viewport_1p.add_child(_camera_1p)

	_camera_2p = Camera3D.new()
	_camera_2p.name = "Camera_2P"
	_camera_2p.current = true
	if cam_script:
		_camera_2p.set_script(cam_script)
		if _original_camera and _original_camera.get_script() == cam_script:
			_copy_camera_params(_original_camera, _camera_2p)
		_camera_2p.target = car_mesh_2p
	_viewport_2p.add_child(_camera_2p)

	# 将场景的 World3D 共享给两个 viewport
	var world: World3D = get_tree().current_scene.get_viewport().world_3d
	_viewport_1p.world_3d = world
	_viewport_2p.world_3d = world

	# 中间分割线 (纯视觉装饰, 使用锚点自适应窗口大小)
	var sep := ColorRect.new()
	sep.name = "SplitLine"
	sep.color = Color(0.15, 0.15, 0.2, 0.9)
	# 锚点: 水平居中 (0.5), 垂直铺满 (0~1)
	sep.anchor_left = 0.5
	sep.anchor_right = 0.5
	sep.anchor_top = 0.0
	sep.anchor_bottom = 1.0
	# offset: 左右各偏移2px (总宽4px), 上下为0 (铺满)
	sep.offset_left = -2
	sep.offset_right = 2
	sep.offset_top = 0
	sep.offset_bottom = 0
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_layer.add_child(sep)

	print("[CoopMode] 分屏已设置 (layer=-1, 不遮挡 Tuner/HUD)")


## ============================================================
##  双 HUD 适配
##  设计:
##   · 隐藏原始 HUD (它是全屏布局, 不适合分屏)
##   · 为 1P 和 2P 各创建一个 HUD 实例
##   · 1P HUD 定位到左半屏, 2P HUD 定位到右半屏
##   · 两个 HUD 各自连接到对应的赛车, 独立显示氮气/小喷灯/炫点
## ============================================================
func _setup_dual_hud() -> void:
	# 隐藏原始 HUD
	_original_hud = get_tree().current_scene.find_child("HUD", true, false) as CanvasLayer
	if _original_hud:
		_original_hud.visible = false

	var hud_scene: PackedScene = load("res://HUD.tscn") as PackedScene
	if hud_scene == null:
		push_warning("[CoopMode] 无法加载 HUD.tscn, 跳过 HUD 适配")
		return

	# 创建 1P HUD (左半屏)
	_hud_1p = hud_scene.instantiate() as CanvasLayer
	_hud_1p.name = "HUD_1P"
	_hud_1p.layer = 2  # 在分屏之上, 但在 Tuner/SceneSelector 之下
	get_tree().current_scene.add_child(_hud_1p)
	_hud_1p.car_path = _hud_1p.get_path_to(_car_1p)
	# 调整 1P HUD Root 控件到左半屏
	_adapt_hud_to_half(_hud_1p, true)
	# 注: HUD._ready 中已有 call_deferred("_connect_to_car"), car_path 在同帧内设置完毕

	# 创建 2P HUD (右半屏)
	_hud_2p = hud_scene.instantiate() as CanvasLayer
	_hud_2p.name = "HUD_2P"
	_hud_2p.layer = 2
	get_tree().current_scene.add_child(_hud_2p)
	_hud_2p.car_path = _hud_2p.get_path_to(_car_2p)
	# 调整 2P HUD Root 控件到右半屏
	_adapt_hud_to_half(_hud_2p, false)

	# 延迟同步: HUD 的 _connect_to_car 是 deferred 的, 需要等它完成后再触发状态同步
	# 等 2 帧确保 HUD 信号连接完毕, 然后让两辆车重新发出当前状态信号
	call_deferred("_deferred_sync_hud_state")

	print("[CoopMode] 双 HUD 已设置 (1P=左半屏, 2P=右半屏)")


## 延迟同步 HUD 状态: 让两辆车重新发出当前氮气/集气等信号, 确保 HUD 显示正确
func _deferred_sync_hud_state() -> void:
	# 再等一帧, 确保 HUD._connect_to_car 的 deferred 调用已完成
	await get_tree().process_frame
	await get_tree().process_frame
	# 让两辆车重新发出当前状态信号
	if _car_1p and "nitro_stock" in _car_1p and "max_nitro_stock" in _car_1p:
		_car_1p.emit_signal("nitro_stock_changed", _car_1p.nitro_stock, _car_1p.max_nitro_stock)
	if _car_2p and "nitro_stock" in _car_2p and "max_nitro_stock" in _car_2p:
		_car_2p.emit_signal("nitro_stock_changed", _car_2p.nitro_stock, _car_2p.max_nitro_stock)
	# 同步集气槽
	if _car_1p and _car_1p.has_signal("charge_changed"):
		var charge: float = _car_1p.get("_drift_charge") if "_drift_charge" in _car_1p else 0.0
		var max_charge: float = _car_1p.get("charge_nitro_full") if "charge_nitro_full" in _car_1p else 100.0
		_car_1p.emit_signal("charge_changed", charge, max_charge)
	if _car_2p and _car_2p.has_signal("charge_changed"):
		var charge: float = _car_2p.get("_drift_charge") if "_drift_charge" in _car_2p else 0.0
		var max_charge: float = _car_2p.get("charge_nitro_full") if "charge_nitro_full" in _car_2p else 100.0
		_car_2p.emit_signal("charge_changed", charge, max_charge)
	print("[CoopMode] HUD 状态已同步 (1P nitro=%d, 2P nitro=%d)" % [
		_car_1p.nitro_stock if _car_1p and "nitro_stock" in _car_1p else -1,
		_car_2p.nitro_stock if _car_2p and "nitro_stock" in _car_2p else -1
	])


## 将 HUD 的 Root 控件适配到半屏
## is_left: true=左半屏, false=右半屏
func _adapt_hud_to_half(hud: CanvasLayer, is_left: bool) -> void:
	var root: Control = hud.get_node_or_null("Root")
	if root == null:
		return
	# 取消全屏 preset, 改为手动设置锚点到半屏
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	if is_left:
		# 左半屏: anchor_right = 0.5
		root.anchor_left = 0.0
		root.anchor_right = 0.5
	else:
		# 右半屏: anchor_left = 0.5
		root.anchor_left = 0.5
		root.anchor_right = 1.0
	root.anchor_top = 0.0
	root.anchor_bottom = 1.0
	root.offset_left = 0
	root.offset_right = 0
	root.offset_top = 0
	root.offset_bottom = 0
	# 不拦截鼠标 (让 Tuner 的 TAB 面板可以正常操作)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_mouse_ignore_recursive(root)

	# 缩小字体和 UI 元素以适配半屏宽度
	# 速度表
	var speed_label: Label = hud.get_node_or_null("Root/SpeedBox/SpeedLabel")
	if speed_label:
		speed_label.add_theme_font_size_override("font_size", 52)
	# 集气槽
	var charge_box: VBoxContainer = hud.get_node_or_null("Root/ChargeBox")
	if charge_box:
		# 缩小集气槽宽度
		charge_box.offset_left = -140
		charge_box.offset_right = 140
	# 操作提示 (分屏下隐藏, 太占空间)
	var help_label: Label = hud.get_node_or_null("Root/HelpLabel")
	if help_label:
		help_label.visible = false
	# 署名 (分屏下隐藏)
	var sig_label: Label = hud.get_node_or_null("Root/SignatureLabel")
	if sig_label:
		sig_label.visible = false

	# 添加玩家标识 (左上角显示 "1P" 或 "2P")
	var player_tag := Label.new()
	player_tag.name = "PlayerTag"
	player_tag.text = "1P" if is_left else "2P"
	player_tag.add_theme_font_size_override("font_size", 28)
	player_tag.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3, 0.9) if is_left else Color(0.3, 0.9, 1.0, 0.9))
	player_tag.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	player_tag.add_theme_constant_override("outline_size", 4)
	player_tag.position = Vector2(10, 10)
	root.add_child(player_tag)


## 递归设置所有 Control 子节点的 mouse_filter 为 IGNORE
func _set_mouse_ignore_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_set_mouse_ignore_recursive(child)


## 清理双 HUD
func _cleanup_dual_hud() -> void:
	if _hud_1p:
		_hud_1p.queue_free()
		_hud_1p = null
	if _hud_2p:
		_hud_2p.queue_free()
		_hud_2p = null
	# 恢复原始 HUD
	if _original_hud:
		_original_hud.visible = true
		_original_hud = null


## 清理分屏
func _cleanup_split_screen() -> void:
	if _canvas_layer:
		_canvas_layer.queue_free()
		_canvas_layer = null
	_hbox = null
	_viewport_1p = null
	_viewport_2p = null
	_camera_1p = null
	_camera_2p = null
	if _original_camera:
		_original_camera.current = true
		_original_camera = null


## 清理 2P 赛车
func _cleanup_2p_car() -> void:
	if _car_2p:
		_car_2p.queue_free()
		_car_2p = null


## 绳子追随: 开始加速飞行
func _start_follow(src: RigidBody3D, target: RigidBody3D) -> void:
	if src == null or target == null:
		return
	_follow_active = true
	_follow_src = src
	_follow_target = target
	_follow_start_pos = src.global_position
	# 目标 = 对方当前位置 (无偏移, 直接飞到对方身边)
	_follow_target_pos = target.global_position
	# 记录起始朝向 (用于缓动插值到目标朝向)
	var src_mesh: Node3D = src.get_node_or_null("CarMesh")
	if src_mesh:
		_follow_start_basis = src_mesh.global_transform.basis
	else:
		_follow_start_basis = Basis.IDENTITY
	_follow_elapsed = 0.0
	# 飞行期间冻结物理 (不受重力/碰撞影响)
	src.linear_velocity = Vector3.ZERO
	src.angular_velocity = Vector3.ZERO
	# 清空缠绕锚点
	_rope_wrap_points.clear()

## 绳子追随: 每帧更新飞行位置 (加速曲线: ease-in) + 朝向缓动
func _update_follow(delta: float) -> void:
	if _follow_src == null:
		_follow_active = false
		return
	_follow_elapsed += delta
	var t: float = clampf(_follow_elapsed / _follow_duration, 0.0, 1.0)
	# 加速曲线: t^2 (ease-in, 越来越快)
	var eased_t: float = t * t
	# 插值位置
	_follow_src.global_position = _follow_start_pos.lerp(_follow_target_pos, eased_t)
	# 飞行中保持速度为零 (由位置插值驱动, 不走物理)
	_follow_src.linear_velocity = Vector3.ZERO
	_follow_src.angular_velocity = Vector3.ZERO
	# 飞行中缓动朝向: 从起始朝向平滑过渡到目标车的朝向
	var src_mesh: Node3D = _follow_src.get_node_or_null("CarMesh")
	if src_mesh and _follow_target:
		var target_mesh: Node3D = _follow_target.get_node_or_null("CarMesh")
		if target_mesh:
			# 用四元数 slerp 实现平滑朝向过渡
			var start_quat: Quaternion = Quaternion(_follow_start_basis)
			var target_quat: Quaternion = Quaternion(target_mesh.global_transform.basis)
			# 朝向使用 smoothstep 缓动 (开始慢-中间快-结束慢)
			var rot_t: float = t * t * (3.0 - 2.0 * t)
			var current_quat: Quaternion = start_quat.slerp(target_quat, rot_t)
			src_mesh.global_transform.basis = Basis(current_quat)
	# 到达终点
	if t >= 1.0:
		_follow_src.global_position = _follow_target_pos
		_follow_src.linear_velocity = Vector3.ZERO
		_follow_src.angular_velocity = Vector3.ZERO
		# 最终朝向完全对齐目标车
		if src_mesh and _follow_target:
			var target_mesh: Node3D = _follow_target.get_node_or_null("CarMesh")
			if target_mesh:
				src_mesh.global_transform.basis = target_mesh.global_transform.basis
		_follow_active = false
		_follow_src = null
		_follow_target = null
		print("[CoopMode] 追随飞行完成, 已到达目标位置")
	# 飞行中也更新绳子视觉
	if _rope_connected:
		_update_rope_visual()


func _toggle_rope() -> void:
	_rope_connected = not _rope_connected
	if _rope_connected:
		_rope_wrap_points.clear()
		_create_rope_visual()
		print("[CoopMode] 绳子已连接! 长度=%.1fm" % rope_length)
	else:
		_rope_wrap_points.clear()
		_cleanup_rope_visual()
		# 绳子断开时恢复两车摩擦
		if _car_1p and "_rope_friction_mult" in _car_1p:
			_car_1p.set("_rope_friction_mult", 1.0)
		if _car_2p and "_rope_friction_mult" in _car_2p:
			_car_2p.set("_rope_friction_mult", 1.0)
		print("[CoopMode] 绳子已断开!")


## 绳子物理: 非对称 + 缠绕 + 后车转向自由度
func _apply_rope_physics(delta: float) -> void:
	var pos_1p: Vector3 = _car_1p.global_position
	var pos_2p: Vector3 = _car_2p.global_position

	# ---- 1. 缠绕检测: 绳子不穿墙, 沿墙面缠绕 ----
	_update_rope_wrap(pos_1p, pos_2p)

	# ---- 2. 计算绳子总路径长度 (含缠绕锚点) ----
	var path_points: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	_rope_total_length = 0.0
	for i in range(path_points.size() - 1):
		_rope_total_length += path_points[i].distance_to(path_points[i + 1])

	# 只有超过 (自然长度 + 弹性余量) 才施力
	var stretch: float = _rope_total_length - rope_length - rope_elasticity
	if stretch <= 0.0:
		return  # 绳子松弛, 不施力

	# ---- 3. 计算各端的拉力方向 (沿绳子路径的第一段/最后一段) ----
	# 1P 端: 从 1P 指向第一个有效节点 (跳过距离太近的锚点)
	var dir_1p: Vector3 = Vector3.ZERO
	for pi in range(1, path_points.size()):
		var diff: Vector3 = path_points[pi] - path_points[0]
		if diff.length() > 0.5:  # 至少 0.5m 才算有效方向
			dir_1p = diff.normalized()
			break
	if dir_1p == Vector3.ZERO:
		dir_1p = (path_points[path_points.size() - 1] - path_points[0]).normalized()

	# 2P 端: 从 2P 指向最后一个有效节点 (跳过距离太近的锚点)
	var dir_2p: Vector3 = Vector3.ZERO
	var last_idx: int = path_points.size() - 1
	for pi in range(last_idx - 1, -1, -1):
		var diff: Vector3 = path_points[pi] - path_points[last_idx]
		if diff.length() > 0.5:  # 至少 0.5m 才算有效方向
			dir_2p = diff.normalized()
			break
	if dir_2p == Vector3.ZERO:
		dir_2p = (path_points[0] - path_points[last_idx]).normalized()

	# ---- 4. 计算弹簧力 ----
	var spring_force: float = rope_stiffness * sqrt(stretch) * sqrt(stretch + 1.0)

	# 阻尼力: 沿绳子方向的相对速度
	var rel_vel_1p: float = _car_1p.linear_velocity.dot(dir_1p)
	var rel_vel_2p: float = _car_2p.linear_velocity.dot(dir_2p)
	var damping_1p: float = -rope_damping * rel_vel_1p * 0.5
	var damping_2p: float = -rope_damping * rel_vel_2p * 0.5

	# ---- 5. 判断谁是前车/后车 ----
	var v1_pulling_away: float = _car_1p.linear_velocity.dot(-dir_1p)
	var v2_pulling_away: float = _car_2p.linear_velocity.dot(-dir_2p)

	var force_1p: float  # 施加到 1P 的力大小
	var force_2p: float  # 施加到 2P 的力大小

	if v1_pulling_away > v2_pulling_away:
		# 1P 是前车, 2P 是后车
		force_1p = clampf((spring_force + damping_1p) * rope_front_pull_ratio, 0.0, rope_max_force)
		force_2p = clampf((spring_force + damping_2p) * rope_rear_pull_ratio, 0.0, rope_max_force)
	else:
		# 2P 是前车, 1P 是后车
		force_1p = clampf((spring_force + damping_1p) * rope_rear_pull_ratio, 0.0, rope_max_force)
		force_2p = clampf((spring_force + damping_2p) * rope_front_pull_ratio, 0.0, rope_max_force)

	# ---- 6. 施加力 (后车有转向自由度) ----
	if v1_pulling_away > v2_pulling_away:
		# 1P 是前车, 2P 是后车
		# 前车: 纯中心力 (回拉, 不影响转向)
		_car_1p.apply_central_force(dir_1p * force_1p)
		# 后车: 根据 rope_rear_steer_freedom 混合中心力和偏移力
		_apply_force_with_steer_freedom(_car_2p, dir_2p * force_2p, rope_rear_steer_freedom)
	else:
		# 2P 是前车, 1P 是后车
		# 前车: 纯中心力 (回拉, 不影响转向)
		_car_2p.apply_central_force(dir_2p * force_2p)
		# 后车: 根据 rope_rear_steer_freedom 混合中心力和偏移力
		_apply_force_with_steer_freedom(_car_1p, dir_1p * force_1p, rope_rear_steer_freedom)

	# ---- 7. 后车摩擦削减: 绳子拉紧时始终削减后车摩擦, 确保拉力能有效传递 ----
	var rear_car: RigidBody3D
	var front_car: RigidBody3D
	var rear_pull_dir: Vector3  # 后车被拉的方向
	if v1_pulling_away > v2_pulling_away:
		rear_car = _car_2p
		front_car = _car_1p
		rear_pull_dir = dir_2p
	else:
		rear_car = _car_1p
		front_car = _car_2p
		rear_pull_dir = dir_1p

	# 绳子拉紧时, 始终对后车削减摩擦 (让绳子拉力能有效传递)
	# 削减程度: 拉伸越大, 摩擦越小 (线性插值)
	var stretch_ratio: float = clampf(stretch / rope_length, 0.0, 1.0)  # 拉伸比例 0~1
	var target_friction: float = lerpf(1.0, rope_friction_mult_when_pulled, stretch_ratio)
	rear_car.set("_rope_friction_mult", target_friction)

	# 后车速度 (km/h)
	var rear_speed_kmh: float = rear_car.linear_velocity.length() * 3.6
	# 绳子拉紧 + 后车速度低于阈值 → 额外脱困手段
	if rear_speed_kmh < rope_stuck_speed_threshold:
		# (a) 抬升力: 给后车一个向上的力, 让它脱离地面摩擦
		rear_car.apply_central_force(Vector3.UP * rear_car.mass * 5.0)
		# (b) 墙面滑动修正: 检测后车前方是否有墙, 如果有则将拉力修正为沿墙面切线方向
		var space_state: PhysicsDirectSpaceState3D = rear_car.get_world_3d().direct_space_state
		if space_state:
			# 从后车位置沿拉力方向射线检测墙面
			var ray_start: Vector3 = rear_car.global_position
			var ray_end: Vector3 = ray_start + rear_pull_dir * 3.0
			var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
			query.collision_mask = 1  # 只检测静态环境
			query.exclude = [_car_1p.get_rid(), _car_2p.get_rid()]
			var result: Dictionary = space_state.intersect_ray(query)
			if result.size() > 0:
				# 前方有墙! 将拉力投影到墙面切线方向 (去掉法线分量)
				var wall_normal: Vector3 = result["normal"]
				# 拉力在墙面上的投影 = 拉力 - (拉力·法线)×法线
				var slide_dir: Vector3 = rear_pull_dir - wall_normal * rear_pull_dir.dot(wall_normal)
				if slide_dir.length() > 0.1:
					slide_dir = slide_dir.normalized()
					# 施加沿墙面滑动的额外力 (帮助后车绕过墙角)
					var slide_force: float = rear_car.mass * 15.0
					rear_car.apply_central_force(slide_dir * slide_force)
	# 前车始终保持正常摩擦
	front_car.set("_rope_friction_mult", 1.0)


## 施加带转向自由度的力
## freedom=0: 纯中心力(车头被拽着对齐); freedom=1: 力施加在车尾(车头可自由转向)
func _apply_force_with_steer_freedom(car: RigidBody3D, force: Vector3, freedom: float) -> void:
	if freedom <= 0.01:
		# 纯中心力
		car.apply_central_force(force)
		return
	# 混合: 一部分中心力 + 一部分偏移力(在车尾施力产生扭矩)
	var central_ratio: float = 1.0 - freedom
	var offset_ratio: float = freedom
	# 中心力部分
	car.apply_central_force(force * central_ratio)
	# 偏移力部分: 在车尾施力 (沿车头反方向偏移)
	var car_mesh: Node3D = car.get_node_or_null("CarMesh")
	if car_mesh:
		var rear_offset: Vector3 = car_mesh.global_transform.basis.z * 1.5  # 车尾方向偏移 1.5m
		car.apply_force(force * offset_ratio, rear_offset)
	else:
		car.apply_central_force(force * offset_ratio)


## ---- 绳子缠绕系统 ----

## 更新绳子缠绕锚点 (多次迭代射线检测, 确保每一段都不穿墙)
func _update_rope_wrap(pos_1p: Vector3, pos_2p: Vector3) -> void:
	# 缠绕开关关闭时, 清空锚点并跳过检测
	if not rope_wrap_enabled:
		_rope_wrap_points.clear()
		_rope_has_penetration = false
		return

	var space_state: PhysicsDirectSpaceState3D = _car_1p.get_world_3d().direct_space_state
	if space_state == null:
		return

	# ---- 添加新锚点: 多次迭代, 直到所有段都不穿墙或达到迭代上限 ----
	var max_total_iterations: int = 30  # 总迭代上限 (防止极端情况死循环)
	var total_iterations: int = 0
	var found_collision: bool = true

	while found_collision and total_iterations < max_total_iterations:
		found_collision = false
		var path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)

		for i in range(path.size() - 1):
			var seg_start: Vector3 = path[i]
			var seg_end: Vector3 = path[i + 1]
			# 跳过太短的段
			if seg_start.distance_to(seg_end) < rope_wrap_min_seg_len:
				continue

			var query := PhysicsRayQueryParameters3D.create(seg_start, seg_end)
			query.collision_mask = 1  # 只检测静态环境 (layer 1)
			query.exclude = [_car_1p.get_rid(), _car_2p.get_rid()]
			var result: Dictionary = space_state.intersect_ray(query)
			if result.size() > 0:
				var hit_pos: Vector3 = result["position"]
				var hit_normal: Vector3 = result["normal"]

				# 计算锚点位置: 碰撞点沿法线偏移
				var actual_offset: float = rope_wrap_offset
				var anchor: Vector3 = hit_pos + hit_normal * actual_offset
				# Y 坐标约束
				anchor.y = clampf(anchor.y, minf(seg_start.y, seg_end.y) - 1.0, maxf(seg_start.y, seg_end.y) + 1.0)

				# 二次验证: 确保锚点不在墙内
				var verify_query := PhysicsRayQueryParameters3D.create(anchor, anchor + hit_normal * 1.0)
				verify_query.collision_mask = 1
				verify_query.exclude = [_car_1p.get_rid(), _car_2p.get_rid()]
				var verify_result: Dictionary = space_state.intersect_ray(verify_query)
				if verify_result.size() > 0:
					# 锚点在墙内, 使用更大偏移 (至少 2m) 确保脱离墙体
					anchor = anchor + hit_normal * maxf(rope_wrap_offset * 2.0, 2.0)

				# 三次验证: 从锚点向两端射线, 确保锚点位置合理
				# 如果从 seg_start 到 anchor 仍然穿墙, 说明锚点位置不对, 需要更大偏移
				var check_to_anchor := PhysicsRayQueryParameters3D.create(seg_start, anchor)
				check_to_anchor.collision_mask = 1
				check_to_anchor.exclude = [_car_1p.get_rid(), _car_2p.get_rid()]
				var check_result: Dictionary = space_state.intersect_ray(check_to_anchor)
				if check_result.size() > 0:
					# 从起点到锚点仍然穿墙, 用碰撞点作为新的锚点基础
					var new_hit: Vector3 = check_result["position"]
					var new_normal: Vector3 = check_result["normal"]
					anchor = new_hit + new_normal * rope_wrap_offset
					anchor.y = clampf(anchor.y, minf(seg_start.y, seg_end.y) - 1.0, maxf(seg_start.y, seg_end.y) + 1.0)

				# 避免与已有锚点太近 (防止重复添加)
				var too_close: bool = false
				var close_anchor_idx: int = -1
				for eidx in range(_rope_wrap_points.size()):
					if _rope_wrap_points[eidx].distance_to(anchor) < rope_wrap_min_spacing:
						too_close = true
						close_anchor_idx = eidx
						break
				# 也检查是否与两端太近
				if anchor.distance_to(pos_1p) < rope_wrap_min_spacing or anchor.distance_to(pos_2p) < rope_wrap_min_spacing:
					too_close = true
					close_anchor_idx = -1  # 不能移动端点

				if not too_close:
					# 插入到对应位置 (path[0]=1P, 所以锚点索引 = i-1 对应 _rope_wrap_points)
					var insert_idx: int = clampi(i - 1, 0, _rope_wrap_points.size())
					# 但如果 i=0 (1P到第一个节点穿墙), 插入到开头
					if i == 0:
						insert_idx = 0
					_rope_wrap_points.insert(insert_idx, anchor)
					found_collision = true
					total_iterations += 1
					break  # 重新从头检测所有段
				elif close_anchor_idx >= 0:
					# 附近已有锚点但绳子仍穿墙 → 将已有锚点向法线方向推远
					_rope_wrap_points[close_anchor_idx] = _rope_wrap_points[close_anchor_idx] + hit_normal * rope_wrap_offset
					found_collision = true
					total_iterations += 1
					break  # 重新从头检测

		total_iterations += 1

	# ---- 解缠: 检查锚点是否可以被移除 ----
	_try_unwrap_points(pos_1p, pos_2p, space_state)

	# ---- 最终验证: 确保绳子路径中没有穿墙段 ----
	# 如果仍有穿墙段, 标记绳子为"穿墙状态" (物理层可以据此调整行为)
	var final_path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	_rope_has_penetration = false
	for i in range(final_path.size() - 1):
		var seg_start: Vector3 = final_path[i]
		var seg_end: Vector3 = final_path[i + 1]
		if seg_start.distance_to(seg_end) < 0.1:
			continue
		var query := PhysicsRayQueryParameters3D.create(seg_start, seg_end)
		query.collision_mask = 1
		query.exclude = [_car_1p.get_rid(), _car_2p.get_rid()]
		var result: Dictionary = space_state.intersect_ray(query)
		if result.size() > 0:
			_rope_has_penetration = true
			break

	# ---- 限制最大锚点数 (防止极端情况下无限增长) ----
	while _rope_wrap_points.size() > rope_wrap_max_anchors:
		_rope_wrap_points.remove_at(_rope_wrap_points.size() / 2)


## 尝试解除不再需要的缠绕锚点 (遍历所有锚点, 循环直到无法再移除)
func _try_unwrap_points(pos_1p: Vector3, pos_2p: Vector3, space_state: PhysicsDirectSpaceState3D) -> void:
	if _rope_wrap_points.size() == 0:
		return

	# 循环检查, 直到一轮中没有任何锚点被移除
	var removed_any: bool = true
	var max_iterations: int = _rope_wrap_points.size() + 5  # 安全上限防止死循环
	while removed_any and max_iterations > 0:
		removed_any = false
		max_iterations -= 1

		# 构建完整路径: [1P, anchor0, anchor1, ..., anchorN, 2P]
		var path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)

		# 从后往前遍历锚点 (倒序遍历, 移除时不影响前面的索引)
		# path 中: index 0 = 1P, index 1~N = 锚点, index N+1 = 2P
		# 锚点 i 对应 path[i+1], 其前一个节点是 path[i], 后一个节点是 path[i+2]
		var anchor_idx: int = _rope_wrap_points.size() - 1
		while anchor_idx >= 0:
			var path_idx: int = anchor_idx + 1  # 锚点在 path 中的索引
			var prev_node: Vector3 = path[path_idx - 1]  # 前一个节点 (1P 或上一个锚点)
			var next_node: Vector3 = path[path_idx + 1]  # 后一个节点 (下一个锚点或 2P)

			# 如果跳过这个锚点, 前后两个节点之间不穿墙, 就移除它
			var query := PhysicsRayQueryParameters3D.create(prev_node, next_node)
			query.collision_mask = 1
			query.exclude = [_car_1p.get_rid(), _car_2p.get_rid()]
			var result: Dictionary = space_state.intersect_ray(query)
			if result.size() == 0:
				# 不穿墙了! 这个锚点不再需要, 移除
				_rope_wrap_points.remove_at(anchor_idx)
				removed_any = true
				# 重新构建路径 (锚点已变化)
				path = _get_rope_path(pos_1p, pos_2p)
			anchor_idx -= 1


## 获取绳子完整路径 (1P → 缠绕锚点们 → 2P)
func _get_rope_path(pos_1p: Vector3, pos_2p: Vector3) -> Array[Vector3]:
	var path: Array[Vector3] = [pos_1p]
	for pt in _rope_wrap_points:
		path.append(pt)
	path.append(pos_2p)
	return path


## 创建绳子视觉 (材质共享, 段数动态管理)
func _create_rope_visual() -> void:
	_cleanup_rope_visual()
	_rope_mat = StandardMaterial3D.new()
	_rope_mat.albedo_color = rope_color
	_rope_mat.emission_enabled = true
	_rope_mat.emission = rope_color
	_rope_mat.emission_energy_multiplier = 0.5


## 更新绳子视觉位置 (沿缠绕路径绘制所有段: 1P → 锚点1 → 锚点2 → ... → 2P)
func _update_rope_visual() -> void:
	if _car_1p == null or _car_2p == null:
		return
	var pos_1p: Vector3 = _car_1p.global_position
	var pos_2p: Vector3 = _car_2p.global_position
	var path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	var seg_count: int = path.size() - 1  # 段数 = 点数 - 1

	# 动态管理段 mesh 数量: 确保 _rope_segments 有足够的 MeshInstance3D
	while _rope_segments.size() < seg_count:
		var seg := MeshInstance3D.new()
		seg.name = "CoopRopeSeg_%d" % _rope_segments.size()
		var cyl := CylinderMesh.new()
		cyl.top_radius = rope_visual_thickness
		cyl.bottom_radius = rope_visual_thickness
		cyl.height = 1.0
		cyl.radial_segments = 8
		seg.mesh = cyl
		if _rope_mat:
			seg.material_override = _rope_mat
		get_tree().current_scene.add_child(seg)
		_rope_segments.append(seg)

	# 隐藏多余的段
	for i in range(_rope_segments.size()):
		if i < seg_count:
			_rope_segments[i].visible = true
		else:
			_rope_segments[i].visible = false

	# 更新每段的位置和朝向
	for i in range(seg_count):
		var p0: Vector3 = path[i]
		var p1: Vector3 = path[i + 1]
		var seg_vec: Vector3 = p1 - p0
		var seg_len: float = seg_vec.length()
		var seg_mesh: MeshInstance3D = _rope_segments[i]
		if seg_len < 0.01:
			seg_mesh.visible = false
			continue
		var mid: Vector3 = (p0 + p1) * 0.5
		var up_hint: Vector3 = Vector3.UP
		if absf(seg_vec.normalized().dot(Vector3.UP)) > 0.99:
			up_hint = Vector3.RIGHT
		seg_mesh.look_at_from_position(mid, p1, up_hint)
		seg_mesh.rotate_object_local(Vector3.RIGHT, deg_to_rad(90.0))
		seg_mesh.scale = Vector3(1.0, seg_len, 1.0)

	# 绳子颜色随拉伸程度变化 (松弛=金色, 拉紧=红色)
	if _rope_mat:
		var stretch_amount: float = _rope_total_length - rope_length
		var tension: float = clampf(stretch_amount / maxf(rope_elasticity * 2.0, 1.0), 0.0, 1.0)
		var col: Color = rope_color.lerp(Color(1.0, 0.2, 0.1), tension)
		_rope_mat.albedo_color = col
		_rope_mat.emission = col


## 清理绳子视觉
func _cleanup_rope_visual() -> void:
	for seg in _rope_segments:
		if seg and is_instance_valid(seg):
			seg.queue_free()
	_rope_segments.clear()
	_rope_mat = null


## 每帧更新分屏摄像机 (跟随各自的赛车)
func _process(delta: float) -> void:
	if not _active:
		return
	_update_split_cameras(delta)


## 更新分屏摄像机跟随
## 注: Camera3D.gd 脚本自动处理跟随逻辑, 这里不需要手动更新
## 但保留此函数以备将来需要额外处理 (如绳子拉紧时的镜头反应)
func _update_split_cameras(delta: float) -> void:
	pass


## 复制摄像机参数 (从原始摄像机复制 @export 属性到分屏摄像机)
func _copy_camera_params(src: Camera3D, dst: Camera3D) -> void:
	if src == null or dst == null:
		return
	for prop_info in src.get_property_list():
		var prop_name: String = prop_info["name"]
		# 跳过不应复制的属性
		if prop_name in ["target", "current", "script", "name", "owner", "position", "rotation", "transform", "global_transform", "global_position", "global_rotation"]:
			continue
		var usage: int = prop_info["usage"]
		if not (usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR):
			continue
		if prop_name in dst:
			var val = src.get(prop_name)
			if val is Curve:
				val = val.duplicate() if val != null else null
			dst.set(prop_name, val)
