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
var rope_stiffness: float = 800.0      ## 绳子刚度 (N/m, 弹簧系数)
var rope_damping: float = 50.0         ## 绳子阻尼 (防止无限振荡)
var rope_elasticity: float = 2.0       ## 弹性余量 (米): 超过自然长度多少才开始施力
var rope_max_force: float = 5000.0     ## 绳子最大拉力 (N, 防止瞬间弹飞)
var rope_visual_thickness: float = 0.12 ## 绳子视觉粗细 (米)
var rope_color: Color = Color(0.9, 0.75, 0.2, 1.0)  ## 绳子颜色

## 内部状态
var _active: bool = false              ## 当前是否在双人模式运行中
var _car_1p: RigidBody3D = null        ## 1P 赛车引用
var _car_2p: RigidBody3D = null        ## 2P 赛车引用
var _rope_connected: bool = false      ## 绳子是否已连接
var _rope_mesh: MeshInstance3D = null   ## 绳子视觉 mesh
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


func _physics_process(delta: float) -> void:
	if not _active or not _rope_connected:
		return
	if _car_1p == null or _car_2p == null:
		return
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

	# 中间分割线 (纯视觉装饰)
	var sep := ColorRect.new()
	sep.name = "SplitLine"
	sep.color = Color(0.15, 0.15, 0.2, 0.9)
	sep.set_anchors_preset(Control.PRESET_CENTER)
	sep.custom_minimum_size = Vector2(4, 0)
	sep.size = Vector2(4, get_viewport().get_visible_rect().size.y)
	sep.position.x = get_viewport().get_visible_rect().size.x * 0.5 - 2
	sep.position.y = 0
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


## 连接/断开绳子
func _toggle_rope() -> void:
	_rope_connected = not _rope_connected
	if _rope_connected:
		_create_rope_visual()
		print("[CoopMode] 绳子已连接! 长度=%.1fm" % rope_length)
	else:
		_cleanup_rope_visual()
		print("[CoopMode] 绳子已断开!")


## 绳子物理: 弹簧-阻尼模型
func _apply_rope_physics(delta: float) -> void:
	var pos_1p: Vector3 = _car_1p.global_position
	var pos_2p: Vector3 = _car_2p.global_position
	var diff: Vector3 = pos_2p - pos_1p
	var distance: float = diff.length()

	# 只有超过 (自然长度 + 弹性余量) 才施力
	var stretch: float = distance - rope_length - rope_elasticity
	if stretch <= 0.0:
		return  # 绳子松弛, 不施力

	# 弹簧力方向: 从各自位置指向对方
	var direction: Vector3 = diff.normalized()

	# 弹簧力 = 刚度 × 拉伸量
	var spring_force: float = rope_stiffness * stretch

	# 阻尼力: 沿绳子方向的相对速度 × 阻尼系数
	var rel_vel: Vector3 = _car_2p.linear_velocity - _car_1p.linear_velocity
	var rel_vel_along_rope: float = rel_vel.dot(direction)
	var damping_force: float = rope_damping * rel_vel_along_rope

	# 总力 (限制最大值防止弹飞)
	var total_force: float = minf(spring_force + damping_force, rope_max_force)
	total_force = maxf(total_force, 0.0)  # 不施压力, 只施拉力

	# 对两辆车施加相反方向的力
	var force_vec: Vector3 = direction * total_force
	_car_1p.apply_central_force(force_vec)        # 1P 被拉向 2P
	_car_2p.apply_central_force(-force_vec)       # 2P 被拉向 1P


## 创建绳子视觉
func _create_rope_visual() -> void:
	_cleanup_rope_visual()
	_rope_mesh = MeshInstance3D.new()
	_rope_mesh.name = "CoopRopeVis"
	var cyl := CylinderMesh.new()
	cyl.top_radius = rope_visual_thickness
	cyl.bottom_radius = rope_visual_thickness
	cyl.height = 1.0
	cyl.radial_segments = 8
	_rope_mesh.mesh = cyl
	_rope_mat = StandardMaterial3D.new()
	_rope_mat.albedo_color = rope_color
	_rope_mat.emission_enabled = true
	_rope_mat.emission = rope_color
	_rope_mat.emission_energy_multiplier = 0.5
	_rope_mesh.material_override = _rope_mat
	get_tree().current_scene.add_child(_rope_mesh)


## 更新绳子视觉位置
func _update_rope_visual() -> void:
	if _rope_mesh == null or _car_1p == null or _car_2p == null:
		return
	var p0: Vector3 = _car_1p.global_position
	var p1: Vector3 = _car_2p.global_position
	var mid: Vector3 = (p0 + p1) * 0.5
	var rope_vec: Vector3 = p1 - p0
	var rope_len: float = rope_vec.length()
	if rope_len < 0.01:
		_rope_mesh.visible = false
		return
	_rope_mesh.visible = true
	var up_hint: Vector3 = Vector3.UP
	if absf(rope_vec.normalized().dot(Vector3.UP)) > 0.99:
		up_hint = Vector3.RIGHT
	_rope_mesh.look_at_from_position(mid, p1, up_hint)
	_rope_mesh.rotate_object_local(Vector3.RIGHT, deg_to_rad(90.0))
	_rope_mesh.scale = Vector3(1.0, rope_len, 1.0)

	# 绳子颜色随拉伸程度变化 (松弛=金色, 拉紧=红色)
	if _rope_mat:
		var stretch_amount: float = rope_len - rope_length
		var tension: float = clampf(stretch_amount / maxf(rope_elasticity * 2.0, 1.0), 0.0, 1.0)
		var col: Color = rope_color.lerp(Color(1.0, 0.2, 0.1), tension)
		_rope_mat.albedo_color = col
		_rope_mat.emission = col


## 清理绳子视觉
func _cleanup_rope_visual() -> void:
	if _rope_mesh:
		_rope_mesh.queue_free()
		_rope_mesh = null
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
