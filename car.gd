extends RigidBody3D
## ============================================================
##  QQ飞车式车辆控制器 v3 —— 炸弹猫精调版
##  操作：↑↓←→ 方向 · Q 点按入漂 · W 小喷退漂 · E 氮气
##  核心：点按Q入漂 → 方向键控制漂移角度 → 角度足够后按W退漂+小喷
##  集气公式：侧向滑移距离 × 基础率 + 车头角速度 × 权重
##  撞墙：当前漂移累计集气 × 0.2（扣80%）
## ============================================================

# ---------------- 基础移动 ----------------
@export_group("Movement")
@export var max_speed: float = 45.0
@export var acceleration: float = 55.0
@export var brake_force: float = 80.0
@export var steering_deg: float = 28.0           ## 前轮视觉转角
@export var turn_speed: float = 3.2              ## 普通转向响应速度
@export var turn_speed_high_speed_mult: float = 0.45  ## 高速时转向衰减到的倍率(新增: 防甩)
@export var high_speed_threshold: float = 25.0   ## 多少 m/s 以上开始衰减转向
@export var turn_stop_limit: float = 0.6
@export var ground_friction: float = 6.0         ## (旧)正常状态侧向抗滑摩擦
@export var natural_decel: float = 2.5           ## (旧)松油门滚动摩擦, 沿惯性反向

# ---------------- 漂移 ----------------
@export_group("Drift")
@export var drift_friction: float = 1.0
@export var drift_steer_mult: float = 1.6
@export var drift_min_speed: float = 10.0
@export var drift_body_tilt: float = 22.0
@export var drift_yaw_offset_tuck: float = 18.0
@export var drift_yaw_offset_side: float = 35.0
@export var side_drift_threshold: float = 1.2
@export var drift_min_angle_to_boost: float = 10.0  ## 完成度低门槛(度): 小喷资格
@export var drift_min_angle_to_double: float = 25.0  ## (旧逻辑保留, 已废弃) 双喷资格累积角(度)
@export var drift_max_duration: float = 5.0         ## 漂移最长持续(秒), 设为 0 = 不限时
@export var drift_break_speed_ratio: float = 0.5
@export var drift_low_speed_grace_time: float = 0.6   ## 低速触发后给玩家多少秒"挽救"窗口
@export var drift_grace_save_angle: float = 8.0       ## 宽限期内车头再转过此角度(度)即取消断漂
@export var drift_accel_mult: float = 0.35           ## 漂移时油门加速力倍率 (越小越减速感)
@export var drift_passive_decel: float = 8.0        ## (旧)漂移惯性反向阻力, 与 drift_inertial_decel 等价
@export var drift_inertial_decel: float = 8.0        ## 漂移时沿惯性方向反向施加的阻力(总能耗摩擦)
@export var drift_max_speed: float = 30.0            ## 漂移时速度软上限(m/s); <=0 时禁用此限制
@export var drift_speed_brake_strength: float = 18.0  ## 超过上限时的反向刹车力强度
@export var drift_counter_steer_break_time: float = 0.25  ## 反向打方向超过此时长(秒)断漂

# ---------------- 集气公式参数 ----------------
@export_group("Charge Formula")
@export var charge_nitro_full: float = 100.0
@export var charge_per_lateral_m: float = 2.2
@export var charge_yaw_rate_weight: float = 1.8
@export var charge_min_per_sec: float = 12.0
@export var crash_charge_penalty: float = 0.2
@export var max_nitro_stock: int = 2
@export var instant_nitro_settle: bool = true       ## 集气满立即生成氮气格(false=本次漂移结束才结算)
@export var wall_crash_speed_loss: float = 6.0     ## 一帧速度损失超过此值(m/s)才算撞墙

# ---------------- 喷射 ----------------
@export_group("Boost")
@export var mini_boost_cost: float = 35.0           ## 已废弃, 保留兼容
@export var mini_boost_power: float = 24.0
@export var mini_boost_time: float = 0.55
@export var mini_boost_curve: Curve                  ## 小喷力度随时间曲线 (0~1 输入, 0~1+ 输出)
@export var boost_window_time: float = 1.2           ## 退漂后多少秒内按 W 才能放出小喷/双喷
@export var double_boost_window: float = 0.35
@export var double_boost_power: float = 42.0
@export var double_boost_time: float = 0.85
@export var double_boost_curve: Curve                ## 双喷力度随时间曲线
@export var double_charge_hold_time: float = 0.4   ## 小喷期间按住 Q 多少秒可解锁双喷
@export var double_charge_window: float = 0.6      ## 解锁后, 多少秒内不按 W 会失效
@export var nitro_power: float = 58.0
@export var nitro_time: float = 2.2
@export var nitro_boost_curve: Curve                 ## 氮气力度随时间曲线
@export var boost_speed_multiplier: float = 1.55

# ---------------- 视觉 ----------------
@export_group("Visual")
@export var body_tilt: float = 28.0                  ## 过弯侧倾对速度的敏感度(越大越迟钝)
@export var body_tilt_max_deg: float = 12.0          ## 过弯车身最大侧倾角(度) - 防侧翻
@export var head_yaw_deg: float = 4.0                ## 非漂移时车头左右"拧头"幅度(度)
@export var sphere_offset: Vector3 = Vector3.DOWN

# ---------------- 地面物理(防弹跳) ----------------
@export_group("Ground Physics")
@export var ground_stick_enabled: bool = true         ## 落地抑制反弹总开关
@export var ground_stick_vy_threshold: float = 3.0    ## 接触地面且 Y 速度向上小于此值(m/s)直接归零, 防微弹
@export var ground_stick_down_clamp: float = 0.0      ## 接触地面时向下速度限制(0=不限制, 保留下坠感; 设>0 会夹紧)
@export var slope_as_wall_enabled: bool = true        ## 把陡斜面视为墙壁
@export var slope_wall_angle_deg: float = 50.0        ## 斜面法线与竖直方向夹角 ≥ 此值视为墙(度)。越小越严格(地面→墙)
@export var slope_wall_bounce_absorb: float = 0.75    ## 撞斜面墙时吸收多少速度(0=完全弹, 1=完全停)
@export var slope_wall_push_back: float = 4.0         ## 撞斜面墙时沿法线方向推开多少(m/s)

# ============================================================
#  V2 丝滑物理模型 (炸弹猫重制版)
# ============================================================
# 设计哲学: 一切"突变"都用曲线插值, 一切摩擦都沿惯性反向, 漂移是 0~1 平滑状态
# ============================================================
@export_group("V2 - Engine Power")
@export var use_v2_physics: bool = true                ## 总开关: 启用 V2 动力/摩擦/漂移模型
@export var engine_force_max: float = 90.0             ## 引擎最大推力(低速时的峰值力)
@export var engine_force_curve: Curve                   ## 速度比(0~1) → 推力倍率, 典型: 低速高, 接近顶速低
@export var brake_force_max_v2: float = 110.0          ## 刹车最大力
@export var brake_force_curve: Curve                    ## 速度比 → 刹车力倍率
@export var engine_idle_drag: float = 4.0              ## 松油门时引擎拖曳力(沿前进方向反向, 模拟引擎刹车)

@export_group("V2 - Friction Normal")
@export var friction_long_normal: float = 2.5          ## 正常状态前后方向基础摩擦(滚阻)
@export var friction_lat_normal: float = 14.0          ## 正常状态侧向基础抓地摩擦
@export var friction_air_drag: float = 0.05            ## 空气阻力系数(与速度平方成正比, 决定顶速手感)
@export var friction_long_speed_curve_normal: Curve    ## 速度比 → 前后摩擦倍率
@export var friction_lat_speed_curve_normal: Curve     ## 速度比 → 侧向抓地倍率(典型: 高速抓地↓)

@export_group("V2 - Friction Drift")
@export var friction_long_drift: float = 1.2           ## 漂移时前后摩擦基础值(滑得更远)
@export var friction_lat_drift: float = 2.5            ## 漂移时侧向抓地基础值(低→允许甩)
@export var friction_long_speed_curve_drift: Curve
@export var friction_lat_speed_curve_drift: Curve
@export var drift_extra_decel: float = 6.0             ## 漂移时额外整体减速力(沿惯性反向, 让漂移有能耗感)

@export_group("V2 - Drift Dynamics")
@export var drift_engage_duration: float = 0.18        ## 入漂 drift_intensity 0→1 过渡秒数
@export var drift_disengage_duration: float = 0.28     ## 退漂 1→0 过渡秒数
@export var drift_engage_curve: Curve                   ## 入漂 drift_intensity 变化曲线 (0→1 输入, 0→1 输出)
@export var drift_disengage_curve: Curve                ## 退漂 drift_intensity 变化曲线
@export var drift_head_yaw_curve: Curve                 ## 漂移期间车头 yaw 偏移随"漂移已持续归一化时间"变化(0~1 → 强度倍率)
@export var drift_body_tilt_curve: Curve                ## 车身侧倾随漂移时间的变化倍率
@export var drift_head_yaw_duration_ref: float = 2.0   ## 车头曲线采样时用的时间基准(漂移 X 秒后采样点到曲线末端)
@export var drift_steer_mult_v2: float = 1.6           ## 漂移时转向速度倍率(与 drift_intensity 插值)
@export var drift_accel_mult_v2: float = 0.55          ## 漂移时油门有效推力倍率

# ---------------- 节点 ----------------
@onready var car_mesh: Node3D = get_node_or_null("CarMesh")
@onready var body_mesh: Node3D = get_node_or_null("CarMesh/suv2")
@onready var ground_ray: RayCast3D = get_node_or_null("CarMesh/RayCast3D")
@onready var right_wheel: Node3D = get_node_or_null("CarMesh/suv2/wheel_frontRight")
@onready var left_wheel: Node3D = get_node_or_null("CarMesh/suv2/wheel_frontLeft")

@export var auto_spawn_hud: bool = true
@export var hud_scene: PackedScene = preload("res://HUD.tscn")
@export var fx_scene: PackedScene = preload("res://BoostFX.tscn")
@export var drift_fx_scene: PackedScene = preload("res://DriftFX.tscn")
@export var tuner_scene: PackedScene = preload("res://Tuner.tscn")
@export var auto_spawn_tuner: bool = true

# ---------------- 信号 ----------------
signal speed_changed(kmh: float)
signal charge_changed(value: float, max_value: float)
signal nitro_stock_changed(stock: int, max_stock: int)
signal drift_started(mode: String)
signal drift_ended(charge_gained_this_round: float, succeeded: bool)
signal boost_triggered(type: String)
signal wall_crashed(lost_amount: float)
signal camera_shake_requested(intensity: float, duration: float)
signal boost_window_opened(level: String, duration: float)   ## 退漂后小喷/双喷窗口开启
signal boost_window_closed                                    ## 窗口关闭(用满或超时)
signal drift_charge_level_changed(level: String)              ## 漂移中等级变化: "none"/"mini"/"double"
signal double_charge_progress(progress: float)                ## 小喷期间按住Q的蓄能进度 0~1
signal double_charge_ready                                    ## 双喷蓄满, 可按 W 释放
signal double_charge_lost                                     ## 双喷资格失效

# ---------------- 状态 ----------------
enum State { NORMAL, DRIFT }
var state: int = State.NORMAL
var is_boosting: bool = false
var boost_type: String = ""
var boost_time_left: float = 0.0
var boost_power: float = 0.0
var boost_base_power: float = 0.0     # 喷射基础力度(用于曲线缩放)
var boost_total_time: float = 0.0     # 喷射总时长(用于归一化进度)
var last_mini_end_time: float = -999.0

# 输入
var throttle_input: float = 0.0
var steer_input: float = 0.0

# 漂移
var drift_mode: String = ""
var drift_dir: float = 0.0
var drift_yaw_offset: float = 0.0
var drift_accum_charge: float = 0.0
var drift_accum_angle_deg: float = 0.0      # 漂移累计车头转过的角度(度)
var drift_elapsed: float = 0.0              # 漂移已持续时间
var drift_counter_steer_time: float = 0.0
var prev_yaw: float = 0.0
var _prev_forward_xz: Vector2 = Vector2.ZERO   # 上一帧车头水平投影方向(用于稳定算 yaw delta)

# 低速断漂宽限期
var _low_speed_grace_left: float = 0.0   # 宽限剩余秒数, >0 表示正在判断中
var _grace_start_angle: float = 0.0       # 进入宽限期时的累计角度(用于判挽救)

# V2 漂移强度(0~1 平滑过渡, 驱动摩擦/视觉所有漂移表现)
var drift_intensity: float = 0.0        # 0=纯直线, 1=完全漂移
var _drift_intensity_vel: float = 0.0   # 用于平滑过渡的内部速率

# 退漂窗口期: 窗口内按 W 才能放出本次漂移积累的小喷/双喷
var boost_window_left: float = 0.0                # 窗口剩余秒数, 0 表示无窗口
var boost_window_level: String = ""               # 窗口可释放等级 "mini" / "double"

# 漂移中实时等级 (用于 HUD 小喷灯)
var _drift_charge_level: String = "none"          # "none"/"mini"/"double"

# 双喷蓄能状态(小喷期间按住 Q 蓄能)
var _double_charge_t: float = 0.0     # 当前已按住 Q 的累计时间
var _double_armed: bool = false       # 双喷已蓄满, 可按 W 释放
var _double_armed_left: float = 0.0   # 蓄满后剩余有效秒数

# 氮气槽
var charge: float = 0.0
var nitro_stock: int = 0
var _pending_nitro: int = 0      # 漂移期间累计待结算的氮气格(等退漂时一次性发放)

# 特效
var fx_node: Node3D = null
var drift_fx_node: Node3D = null

# 撞墙检测
var _last_frame_speed: float = 0.0

# 初始朝向(由 _ready 记录, 用于复位时恢复)
var _initial_car_mesh_basis: Basis = Basis.IDENTITY
var _initial_car_mesh_position: Vector3 = Vector3.ZERO
var _initial_recorded: bool = false

# ============================================================
#  Lifecycle
# ============================================================
func _ready() -> void:
	# 初始化 V2 默认曲线(玩家没设时给合理值)
	_init_default_v2_curves()
	# 如果关键节点缺失, 至少把 Tuner 和 HUD 起来, 方便诊断/调整
	if not car_mesh or not body_mesh:
		push_error("[Car] 关键节点缺失! 车辆控制禁用, 但会启动 Tuner/HUD 以便诊断。")
		if car_mesh:
			print("[Car] CarMesh 子节点: ", car_mesh.get_children())
		if auto_spawn_hud and hud_scene:
			call_deferred("_spawn_hud")
		if auto_spawn_tuner and tuner_scene:
			call_deferred("_spawn_tuner")
		return

	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)

	# 记录 CarMesh 的初始位置和朝向(由 glb/tscn 设置, 代表美术摆好的出生点)
	_initial_car_mesh_basis = car_mesh.global_transform.basis
	_initial_car_mesh_position = car_mesh.global_position
	_initial_recorded = true

	# 出生时: 直接把刚体对齐到 CarMesh 的位置(你在编辑器里调好的位置)
	call_deferred("_snap_to_car_mesh_origin")

	if auto_spawn_hud and hud_scene:
		call_deferred("_spawn_hud")
	if auto_spawn_tuner and tuner_scene:
		call_deferred("_spawn_tuner")
	if fx_scene:
		fx_node = fx_scene.instantiate()
		call_deferred("_attach_fx")
	if drift_fx_scene:
		drift_fx_node = drift_fx_scene.instantiate()
		call_deferred("_attach_drift_fx")


func _snap_to_car_mesh_origin() -> void:
	# 刚体位置 = CarMesh 位置 - sphere_offset (因为之后 _physics_process 里会做 car_mesh.pos = pos + sphere_offset)
	if not _initial_recorded:
		return
	global_position = _initial_car_mesh_position - sphere_offset
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# CarMesh 的位置和朝向保持原样, 不需要动
	if body_mesh:
		body_mesh.rotation = Vector3.ZERO
	print("[Car] 出生点对齐到 CarMesh 位置: ", _initial_car_mesh_position)


func _auto_place_on_ground() -> void:
	# 如果 CarMesh 有独立位置(top_level=true, 由 glb 场景带的初始位置), 优先从 CarMesh 正上方射线
	# 这样能对齐到美术放置的赛道起点, 而不是 tscn 里随手写的 transform
	var origin_xz: Vector3 = global_position
	if car_mesh and car_mesh.top_level:
		origin_xz = car_mesh.global_position
		origin_xz.y = global_position.y  # Y 用刚体的, 等下用射线校正

	var from: Vector3 = Vector3(origin_xz.x, origin_xz.y + 500.0, origin_xz.z)
	var to:   Vector3 = Vector3(origin_xz.x, origin_xz.y - 1000.0, origin_xz.z)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		push_warning("Car: 出生点正下方找不到地面，保持原位")
		return

	var target_pos: Vector3 = hit.position + Vector3(0, 2.0, 0)
	global_position = target_pos
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

	# CarMesh 是 top_level=true 的独立坐标节点，必须手动同步
	if car_mesh:
		car_mesh.global_position = target_pos + sphere_offset
		# 恢复初始朝向(glb/tscn 设置的赛道起点方向)
		if _initial_recorded:
			car_mesh.global_transform.basis = _initial_car_mesh_basis
		else:
			car_mesh.global_rotation = Vector3.ZERO
	if body_mesh:
		body_mesh.rotation = Vector3.ZERO

	print("[Car] 出生点已校正到: ", target_pos)


func _attach_fx() -> void:
	if fx_node and car_mesh:
		car_mesh.add_child(fx_node)
		fx_node.position = Vector3(0, 0.2, 0.8)


func _attach_drift_fx() -> void:
	if not drift_fx_node:
		print("[Car] drift_fx_node 是 null, 跳过挂接")
		return
	# 挂在 car 节点下作为子节点 (DriftFX 内部会自己找轮子)
	add_child(drift_fx_node)
	if drift_fx_node.has_method("set_car"):
		drift_fx_node.set_car(self)
	print("[Car] DriftFX 已挂载")


func _spawn_hud() -> void:
	if get_tree().current_scene.find_child("HUD", true, false):
		return
	var hud: CanvasLayer = hud_scene.instantiate()
	hud.name = "HUD"
	get_tree().current_scene.add_child(hud)
	hud.car_path = hud.get_path_to(self)
	hud.call_deferred("_connect_to_car")


func _spawn_tuner() -> void:
	if get_tree().current_scene.find_child("Tuner", true, false):
		return
	var tuner: CanvasLayer = tuner_scene.instantiate()
	tuner.name = "Tuner"
	get_tree().current_scene.add_child(tuner)
	tuner.set("car_path", tuner.get_path_to(self))
	tuner.call_deferred("_bind_car")


# ============================================================
#  主循环
# ============================================================
func _physics_process(delta: float) -> void:
	if not car_mesh or not body_mesh:
		return
	_read_input()
	_update_boost_timer(delta)
	_update_drift_intensity(delta)    # V2: 平滑的 0~1 漂移强度

	car_mesh.position = position + sphere_offset

	if ground_ray and ground_ray.is_colliding():
		if use_v2_physics:
			_apply_v2_engine_and_brake(delta)
			_apply_v2_friction(delta)
		else:
			_apply_drive_force(delta)
			_apply_lateral_friction(delta)
		_apply_ground_stick(delta)

	_update_drift_charge(delta)
	_check_drift_timeout(delta)
	_update_boost_window(delta)
	_update_double_charge(delta)
	_update_visuals(delta)
	_emit_hud_signals()
	_last_frame_speed = linear_velocity.length()


# ============================================================
#  输入
# ============================================================
func _read_input() -> void:
	throttle_input = Input.get_axis("brake", "accelerate")
	steer_input = Input.get_axis("steer_right", "steer_left")

	# Q 点按：NORMAL 时入漂，DRIFT 时手动退漂(不喷)
	# 例外: 小喷期间按 Q 是为了蓄能双喷, 不入漂
	if Input.is_action_just_pressed("drift"):
		if is_boosting and boost_type == "mini":
			pass  # 小喷期间按 Q 留给双喷蓄能逻辑处理, 这里不入漂
		elif state == State.NORMAL:
			_try_start_drift()
		else:
			_end_drift(false)   # 手动退漂不喷

	# W 小喷：NORMAL 时如果刚好蓄满可直接小喷 / DRIFT 时角度够了退漂+小喷
	if Input.is_action_just_pressed("boost"):
		_try_boost_w()

	# E 氮气
	if Input.is_action_just_pressed("nitro"):
		_try_nitro()


func _unhandled_input(event: InputEvent) -> void:
	# R 键复位到初始出生点（回到你在编辑器里调好的 CarMesh 位置）
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R or event.physical_keycode == KEY_R:
			_reset_to_origin()
			get_viewport().set_input_as_handled()


func _reset_to_origin() -> void:
	if not _initial_recorded:
		_auto_place_on_ground()
		return
	global_position = _initial_car_mesh_position - sphere_offset
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	if car_mesh:
		car_mesh.global_position = _initial_car_mesh_position
		car_mesh.global_transform.basis = _initial_car_mesh_basis
	if body_mesh:
		body_mesh.rotation = Vector3.ZERO
	# 退出漂移/喷射状态
	state = State.NORMAL
	is_boosting = false
	boost_time_left = 0.0
	print("[Car] 已复位到出生点")


# ============================================================
#  驱动力
# ============================================================
func _apply_drive_force(_delta: float) -> void:
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	var current_speed: float = linear_velocity.dot(forward)
	var speed_cap: float = max_speed * (boost_speed_multiplier if is_boosting else 1.0)
	# 漂移时如果设了上限, 取较小者作为本次的速度封顶
	if state == State.DRIFT and drift_max_speed > 0.0:
		speed_cap = minf(speed_cap, drift_max_speed)

	# 漂移中: 油门加速被大幅削弱
	var accel_mult: float = drift_accel_mult if state == State.DRIFT else 1.0

	if throttle_input > 0.01:
		if current_speed < speed_cap:
			apply_central_force(forward * acceleration * throttle_input * accel_mult * mass)
	elif throttle_input < -0.01:
		# 刹车: 沿当前速度反向施力(正确的惯性反向, 不再硬绑车头)
		var v_horiz: Vector3 = linear_velocity
		v_horiz.y = 0.0
		if v_horiz.length() > 0.5:
			apply_central_force(-v_horiz.normalized() * brake_force * absf(throttle_input) * mass)

	# 漂移速度软封顶: 超过 drift_max_speed 时按超出比例施加反向刹车力
	if state == State.DRIFT and drift_max_speed > 0.0:
		var total_speed: float = linear_velocity.length()
		if total_speed > drift_max_speed:
			var over_ratio: float = (total_speed - drift_max_speed) / drift_max_speed
			over_ratio = minf(over_ratio, 1.5)  # 防过度刹车
			# 沿当前速度反方向施力(整体减速)
			var brake_dir: Vector3 = -linear_velocity.normalized()
			apply_central_force(brake_dir * drift_speed_brake_strength * over_ratio * mass)

	# 喷射推力沿当前速度方向施加(防侧翻)
	if is_boosting:
		var vel_dir: Vector3 = linear_velocity
		vel_dir.y = 0.0
		if vel_dir.length() > 1.0:
			vel_dir = vel_dir.normalized()
		else:
			vel_dir = forward
		apply_central_force(vel_dir * boost_power * mass)


# ============================================================
#  V2 丝滑物理模型 —— 炸弹猫重制版
#  三件套:
#   1) _update_drift_intensity: 漂移强度 0~1 平滑过渡
#   2) _apply_v2_engine_and_brake: 带曲线的引擎/刹车动力系统
#   3) _apply_v2_friction: 速度分解 + 曲线化的 3 层摩擦
# ============================================================

func _update_drift_intensity(delta: float) -> void:
	# 目标强度: DRIFT 状态 → 1.0; 否则 → 0.0
	var target: float = 1.0 if state == State.DRIFT else 0.0
	if absf(drift_intensity - target) < 0.001:
		drift_intensity = target
		return
	var dur: float
	var curve: Curve
	if target > drift_intensity:
		dur = maxf(drift_engage_duration, 0.001)
		curve = drift_engage_curve
	else:
		dur = maxf(drift_disengage_duration, 0.001)
		curve = drift_disengage_curve
	# 线性推进内部时间, 用曲线把进度映射成最终 intensity
	var step: float = delta / dur
	if target > drift_intensity:
		# 入漂: 进度从 drift_intensity 推到 1
		# 用当前 intensity 作为曲线采样输入的基础, 曲线能改变响应形状
		var t: float = drift_intensity + step
		t = clampf(t, 0.0, 1.0)
		drift_intensity = _sample_curve_safe(curve, t, t)
	else:
		# 退漂: 进度从 drift_intensity 推到 0
		var t2: float = drift_intensity - step
		t2 = clampf(t2, 0.0, 1.0)
		drift_intensity = _sample_curve_safe(curve, t2, t2)


func _sample_curve_safe(c: Curve, t: float, fallback: float) -> float:
	if c == null or c.point_count <= 1:
		return fallback
	return c.sample(clampf(t, 0.0, 1.0))


func _init_default_v2_curves() -> void:
	# 引擎推力: 低速 1.4(起步爽) → 顶速 0.3(逼近上限乏力)
	if engine_force_curve == null:
		var c := Curve.new()
		c.add_point(Vector2(0.0, 1.4))
		c.add_point(Vector2(0.5, 1.0))
		c.add_point(Vector2(1.0, 0.3))
		engine_force_curve = c
	# 刹车: 高速更强(动能大需要大刹车), 低速弱(防瞬停)
	if brake_force_curve == null:
		var c2 := Curve.new()
		c2.add_point(Vector2(0.0, 0.6))
		c2.add_point(Vector2(0.4, 1.0))
		c2.add_point(Vector2(1.0, 1.2))
		brake_force_curve = c2
	# 正常前后摩擦: 恒定 1.0
	if friction_long_speed_curve_normal == null:
		var c3 := Curve.new()
		c3.add_point(Vector2(0.0, 1.0)); c3.add_point(Vector2(1.0, 1.0))
		friction_long_speed_curve_normal = c3
	# 正常侧向抓地: 低速满格, 高速轻微衰减(让高速转向自然难一点)
	if friction_lat_speed_curve_normal == null:
		var c4 := Curve.new()
		c4.add_point(Vector2(0.0, 1.1))
		c4.add_point(Vector2(0.6, 1.0))
		c4.add_point(Vector2(1.0, 0.75))
		friction_lat_speed_curve_normal = c4
	# 漂移前后摩擦: 恒定 1.0
	if friction_long_speed_curve_drift == null:
		var c5 := Curve.new()
		c5.add_point(Vector2(0.0, 1.0)); c5.add_point(Vector2(1.0, 1.0))
		friction_long_speed_curve_drift = c5
	# 漂移侧向抓地: 低速很低(甩得开), 中速稍涨(可控), 高速微弱(长甩)
	if friction_lat_speed_curve_drift == null:
		var c6 := Curve.new()
		c6.add_point(Vector2(0.0, 0.8))
		c6.add_point(Vector2(0.5, 1.2))
		c6.add_point(Vector2(1.0, 1.0))
		friction_lat_speed_curve_drift = c6
	# 入漂: ease-out(起始快, 末端缓)
	if drift_engage_curve == null:
		var c7 := Curve.new()
		c7.add_point(Vector2(0.0, 0.0))
		c7.add_point(Vector2(0.3, 0.7))
		c7.add_point(Vector2(1.0, 1.0))
		drift_engage_curve = c7
	# 退漂: ease-in(开始稳, 末端快)
	if drift_disengage_curve == null:
		var c8 := Curve.new()
		c8.add_point(Vector2(0.0, 0.0))
		c8.add_point(Vector2(0.7, 0.3))
		c8.add_point(Vector2(1.0, 1.0))
		drift_disengage_curve = c8
	# 车头 yaw 时间曲线: 入漂车头快速偏到位, 中段微幅晃动, 末段稳住
	if drift_head_yaw_curve == null:
		var c9 := Curve.new()
		c9.add_point(Vector2(0.0, 0.9))
		c9.add_point(Vector2(0.3, 1.1))
		c9.add_point(Vector2(0.6, 0.95))
		c9.add_point(Vector2(1.0, 1.0))
		drift_head_yaw_curve = c9
	# 车身侧倾时间曲线: 入漂略微过冲, 后稳定
	if drift_body_tilt_curve == null:
		var c10 := Curve.new()
		c10.add_point(Vector2(0.0, 0.7))
		c10.add_point(Vector2(0.25, 1.15))
		c10.add_point(Vector2(1.0, 1.0))
		drift_body_tilt_curve = c10


# ============================================================
#  V2 - 引擎动力 + 刹车(带曲线)
# ============================================================
func _apply_v2_engine_and_brake(_delta: float) -> void:
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	var v_horiz: Vector3 = linear_velocity
	v_horiz.y = 0.0
	var current_speed: float = v_horiz.length()
	var long_speed: float = v_horiz.dot(forward)

	# 速度归一化 (用 max_speed 做基准, 即便喷射时超速也只是 > 1)
	var ref_speed: float = maxf(max_speed, 1.0)
	var speed_ratio: float = clampf(current_speed / ref_speed, 0.0, 1.2)

	# 油门
	if throttle_input > 0.01:
		var engine_k: float = _sample_curve_safe(engine_force_curve, speed_ratio, 1.0)
		# 漂移强度越大, 油门效率越低(插值)
		var eff_mult: float = lerpf(1.0, drift_accel_mult_v2, drift_intensity)
		# 考虑顶速软封顶: 接近顶速时自然不再加速
		var speed_cap: float = max_speed * (boost_speed_multiplier if is_boosting else 1.0)
		if state == State.DRIFT and drift_max_speed > 0.0:
			speed_cap = minf(speed_cap, drift_max_speed)
		if long_speed < speed_cap:
			apply_central_force(forward * engine_force_max * engine_k * throttle_input * eff_mult * mass)
	elif throttle_input < -0.01:
		# 刹车: 沿惯性反向, 力度按当前速度比用曲线
		var brake_k: float = _sample_curve_safe(brake_force_curve, speed_ratio, 1.0)
		if current_speed > 0.3:
			var brake_dir: Vector3 = -v_horiz.normalized()
			apply_central_force(brake_dir * brake_force_max_v2 * brake_k * absf(throttle_input) * mass)
	else:
		# 松油门: 引擎拖曳(沿前进方向反向)
		if absf(long_speed) > 0.1:
			apply_central_force(-forward * signf(long_speed) * engine_idle_drag * mass)

	# 漂移超速软封顶(保留旧机制)
	if state == State.DRIFT and drift_max_speed > 0.0 and current_speed > drift_max_speed:
		var over_ratio: float = (current_speed - drift_max_speed) / drift_max_speed
		over_ratio = minf(over_ratio, 1.5)
		apply_central_force(-v_horiz.normalized() * drift_speed_brake_strength * over_ratio * mass)

	# 喷射推力沿惯性方向
	if is_boosting:
		var vel_dir: Vector3 = v_horiz
		if vel_dir.length() > 1.0:
			vel_dir = vel_dir.normalized()
		else:
			vel_dir = forward
		apply_central_force(vel_dir * boost_power * mass)


# ============================================================
#  V2 - 摩擦: 速度分解 + 曲线调制
#  所有摩擦沿"该速度分量反方向"施加, 即惯性反向 ✓
# ============================================================
func _apply_v2_friction(delta: float) -> void:
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	var right: Vector3 = car_mesh.global_transform.basis.x
	var v: Vector3 = linear_velocity
	v.y = 0.0
	var total_speed: float = v.length()
	var ref_speed: float = maxf(max_speed, 1.0)
	var speed_ratio: float = clampf(total_speed / ref_speed, 0.0, 1.2)

	var v_long: float = v.dot(forward)
	var v_lat: float = v.dot(right)

	# NORMAL 与 DRIFT 两套参数按 drift_intensity 插值
	var long_k_normal: float = friction_long_normal * _sample_curve_safe(friction_long_speed_curve_normal, speed_ratio, 1.0)
	var long_k_drift: float  = friction_long_drift  * _sample_curve_safe(friction_long_speed_curve_drift,  speed_ratio, 1.0)
	var lat_k_normal: float  = friction_lat_normal  * _sample_curve_safe(friction_lat_speed_curve_normal,  speed_ratio, 1.0)
	var lat_k_drift: float   = friction_lat_drift   * _sample_curve_safe(friction_lat_speed_curve_drift,   speed_ratio, 1.0)

	var long_k: float = lerpf(long_k_normal, long_k_drift, drift_intensity)
	var lat_k: float  = lerpf(lat_k_normal,  lat_k_drift,  drift_intensity)

	# 沿各自速度分量反方向施加冲量
	var long_impulse: Vector3 = -forward * v_long * long_k * delta
	var lat_impulse: Vector3  = -right   * v_lat  * lat_k  * delta
	apply_central_impulse((long_impulse + lat_impulse) * mass)

	# 空气阻力(与速度平方成正比, 沿惯性反向)
	if total_speed > 0.5 and friction_air_drag > 0.0:
		var air_force: Vector3 = -v.normalized() * friction_air_drag * total_speed * total_speed * mass
		apply_central_force(air_force)

	# 漂移额外能耗(整体沿惯性反向, 强度与 drift_intensity 成正比)
	if drift_intensity > 0.01 and total_speed > 0.5:
		apply_central_force(-v.normalized() * drift_extra_decel * drift_intensity * mass)


func _apply_lateral_friction(delta: float) -> void:
	# ============================================================
	# 正确的摩擦力模型: 把速度分解到车头 long(前后) / lat(侧向) 两轴
	# 每个分量各自沿"该分量反方向"(即惯性该分量方向的反向)施加阻力
	# 合力 = 两个方向反向阻力之和, 整体朝"惯性反方向"指向
	# ============================================================
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	var right: Vector3 = car_mesh.global_transform.basis.x
	# Y 分量不参与地面摩擦(由地面物理处理)
	var v: Vector3 = linear_velocity
	v.y = 0.0

	# 速度分解
	var v_long: float = v.dot(forward)    # 前进方向速度(正=前, 负=倒)
	var v_lat: float = v.dot(right)       # 侧向速度(漂移时很大)

	# 侧向摩擦: 漂移时小(drift_friction), 正常时大(ground_friction)
	var lat_k: float = drift_friction if state == State.DRIFT else ground_friction

	# 前进方向滚动摩擦: 松油门时生效(natural_decel), 漂移时叠加额外能耗
	# 踩油门/刹车时不施加滚动摩擦(否则与驱动力冲突)
	var long_k: float = 0.0
	if state == State.DRIFT:
		# 漂移: 用 drift_inertial_decel 作为整体能耗, 同时叠加 drift_passive_decel 兼容
		long_k = maxf(drift_inertial_decel, drift_passive_decel)
	elif absf(throttle_input) < 0.05:
		# 正常松油门: 滚动摩擦
		long_k = natural_decel

	# 沿"该方向速度分量的反方向"施加阻力(惯性反向)
	# 用冲量形式: impulse = -velocity_component * k * delta
	var lat_impulse: Vector3 = -right * v_lat * lat_k * delta
	var long_impulse: Vector3 = -forward * v_long * long_k * delta
	apply_central_impulse((lat_impulse + long_impulse) * mass)


# ============================================================
#  地面吸附(防弹跳)
# ============================================================
func _apply_ground_stick(_delta: float) -> void:
	if not ground_stick_enabled:
		return
	var v: Vector3 = linear_velocity
	# 接触地面时若 Y 速度朝上且小于阈值, 直接归零(防微弹)
	if v.y > 0.0 and v.y < ground_stick_vy_threshold:
		v.y = 0.0
		linear_velocity = v
	# 可选: 限制向下速度
	if ground_stick_down_clamp > 0.0 and v.y < -ground_stick_down_clamp:
		v.y = -ground_stick_down_clamp
		linear_velocity = v


# ============================================================
#  视觉 + 车头朝向 (含高速转向衰减)
# ============================================================
func _update_visuals(delta: float) -> void:
	if not car_mesh or not body_mesh:
		return
	if linear_velocity.length() < turn_stop_limit:
		prev_yaw = car_mesh.rotation.y
		return

	if right_wheel and left_wheel:
		var wheel_turn: float = deg_to_rad(steering_deg) * steer_input
		right_wheel.rotation.y = wheel_turn
		left_wheel.rotation.y = wheel_turn

	# 【关键】高速转向衰减：速度越快，转向响应越慢
	var speed: float = linear_velocity.length()
	var speed_factor: float = 1.0
	if state != State.DRIFT and speed > high_speed_threshold:
		var over: float = (speed - high_speed_threshold) / maxf(max_speed - high_speed_threshold, 1.0)
		over = clampf(over, 0.0, 1.0)
		speed_factor = lerpf(1.0, turn_speed_high_speed_mult, over)

	# 转向倍率: V2 用 drift_intensity 插值, 旧路径保持 state 判断
	var turn_mult: float
	if use_v2_physics:
		turn_mult = lerpf(speed_factor, drift_steer_mult_v2, drift_intensity)
	else:
		turn_mult = drift_steer_mult if state == State.DRIFT else speed_factor
	var turn_rad: float = deg_to_rad(steering_deg) * steer_input * turn_mult

	var new_basis: Basis = car_mesh.global_transform.basis.rotated(
		car_mesh.global_transform.basis.y, turn_rad
	)
	car_mesh.global_transform.basis = car_mesh.global_transform.basis.slerp(
		new_basis, turn_speed * delta
	)
	car_mesh.global_transform = car_mesh.global_transform.orthonormalized()

	# ============ V2 车身侧倾(带 drift_intensity 插值 + 时间曲线) ============
	var max_lean_rad: float = deg_to_rad(body_tilt_max_deg)
	var lean_base: float = clampf(-steer_input * linear_velocity.length() / body_tilt, -max_lean_rad, max_lean_rad)
	var lean_drift: float = 0.0
	# 漂移时间归一化(用 drift_head_yaw_duration_ref 作为曲线完成点)
	var drift_t_norm: float = clampf(drift_elapsed / maxf(drift_head_yaw_duration_ref, 0.1), 0.0, 1.0)
	var tilt_time_k: float = _sample_curve_safe(drift_body_tilt_curve, drift_t_norm, 1.0)
	# 平滑过渡: drift_intensity(0~1) × 时间曲线 × 配置角度 × 漂移方向
	lean_drift = deg_to_rad(drift_body_tilt) * drift_dir * drift_intensity * tilt_time_k
	body_mesh.rotation.z = lerp(body_mesh.rotation.z, lean_base + lean_drift, 6.0 * delta)

	# ============ V2 车头 yaw (漂移时偏转 + 时间曲线动态晃动) ============
	# 非漂移的"拧头"基础量
	var base_head_yaw: float = deg_to_rad(head_yaw_deg) * steer_input
	# 漂移偏转量: 基础 × drift_intensity × 时间曲线(可以让车头在漂移中段更甩)
	var yaw_time_k: float = _sample_curve_safe(drift_head_yaw_curve, drift_t_norm, 1.0)
	var drift_yaw_rad: float = deg_to_rad(drift_yaw_offset) * drift_dir * drift_intensity * yaw_time_k
	# 两者插值合并(drift_intensity=0 时全用 base, =1 时全用 drift)
	var target_head_yaw: float = lerpf(base_head_yaw, drift_yaw_rad, drift_intensity)
	body_mesh.rotation.y = lerp(body_mesh.rotation.y, target_head_yaw, 6.0 * delta)

	# 沿地面法线对齐
	if ground_ray.is_colliding():
		var n: Vector3 = ground_ray.get_collision_normal()
		var xform: Transform3D = _align_with_y(car_mesh.global_transform, n)
		car_mesh.global_transform = car_mesh.global_transform.interpolate_with(xform, 10.0 * delta)

	prev_yaw = car_mesh.rotation.y


func _align_with_y(xform: Transform3D, new_y: Vector3) -> Transform3D:
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	return xform.orthonormalized()


# ============================================================
#  漂移
# ============================================================
func _try_start_drift() -> void:
	if state == State.DRIFT:
		return
	if linear_velocity.length() < drift_min_speed:
		return
	if absf(steer_input) < 0.15:
		return
	if throttle_input < 0.05:
		return

	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed: float = linear_velocity.dot(right)
	var counter_steer: bool = (
		signf(lateral_speed) != signf(steer_input)
		and absf(lateral_speed) > side_drift_threshold
	)

	drift_dir = signf(steer_input) if steer_input != 0.0 else 1.0
	if counter_steer:
		drift_mode = "side"
		drift_yaw_offset = drift_yaw_offset_side
	else:
		drift_mode = "tuck"
		drift_yaw_offset = drift_yaw_offset_tuck

	state = State.DRIFT
	drift_accum_charge = 0.0
	drift_accum_angle_deg = 0.0
	drift_elapsed = 0.0
	_low_speed_grace_left = 0.0
	_grace_start_angle = 0.0
	# 记录入漂时车头方向(XZ 投影), 后续每帧以此为基准算 yaw 变化
	var _fwd0: Vector3 = -car_mesh.global_transform.basis.z
	_prev_forward_xz = Vector2(_fwd0.x, _fwd0.z).normalized()
	_drift_charge_level = "none"
	emit_signal("drift_charge_level_changed", "none")
	emit_signal("drift_started", drift_mode)
	if drift_fx_node and drift_fx_node.has_method("set_drifting"):
		drift_fx_node.set_drifting(true)
	print("[Car] 进入漂移 mode=", drift_mode, " fx=", drift_fx_node != null)


func _end_drift(_success_boost: bool = false) -> void:
	if state != State.DRIFT:
		return
	var final_angle: float = drift_accum_angle_deg
	var gained: float = drift_accum_charge
	state = State.NORMAL
	drift_accum_charge = 0.0
	drift_accum_angle_deg = 0.0
	drift_elapsed = 0.0
	drift_mode = ""
	_low_speed_grace_left = 0.0
	_grace_start_angle = 0.0
	# 延迟结算氮气: 漂移期间积累的格子, 退漂时一次性发放
	if _pending_nitro > 0:
		nitro_stock = mini(nitro_stock + _pending_nitro, max_nitro_stock)
		_pending_nitro = 0
		emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
	# 漂移结束: 通知 HUD 灭灯(交给窗口期接管显示)
	if _drift_charge_level != "none":
		_drift_charge_level = "none"
		emit_signal("drift_charge_level_changed", "none")
	# 根据完成度评级开启小喷窗口(双喷不再走这条路, 改为小喷期间按 Q 蓄能)
	if final_angle >= drift_min_angle_to_boost:
		boost_window_level = "mini"
		boost_window_left = boost_window_time
		emit_signal("boost_window_opened", "mini", boost_window_time)
		print("[Car] 退漂窗口: 小喷可用 (角度=%.1f)" % final_angle)
	else:
		boost_window_level = ""
		boost_window_left = 0.0
		print("[Car] 退漂: 完成度不足无窗口 (角度=%.1f)" % final_angle)
	emit_signal("drift_ended", gained, boost_window_level != "")
	if drift_fx_node and drift_fx_node.has_method("set_drifting"):
		drift_fx_node.set_drifting(false)


func _check_drift_timeout(delta: float) -> void:
	if state != State.DRIFT:
		return
	drift_elapsed += delta
	# 每秒打印一次漂移状态供调试
	if int(drift_elapsed * 2.0) != int((drift_elapsed - delta) * 2.0):
		print("[Car] 漂移中 elapsed=%.1f angle=%.1f° lvl=%s grace=%.2f" % [drift_elapsed, drift_accum_angle_deg, _drift_charge_level, _low_speed_grace_left])
	# drift_max_duration <= 0 表示不限时
	if drift_max_duration > 0.0 and drift_elapsed >= drift_max_duration:
		_end_drift(false)
		return

	var low_speed: bool = linear_velocity.length() < drift_min_speed * drift_break_speed_ratio
	if low_speed:
		# 已在宽限期: 倒计时 + 检查"挽救"
		if _low_speed_grace_left > 0.0:
			_low_speed_grace_left -= delta
			# 期间车头再转过 grace_save_angle 即视为挽救成功, 退出宽限期
			if drift_accum_angle_deg - _grace_start_angle >= drift_grace_save_angle:
				print("[Car] 低速挽救成功! 转过 %.1f° (>= %.1f°)" % [drift_accum_angle_deg - _grace_start_angle, drift_grace_save_angle])
				_low_speed_grace_left = 0.0
				return
			# 宽限到期 → 真正断漂
			if _low_speed_grace_left <= 0.0:
				_low_speed_grace_left = 0.0
				_end_drift(false)
				print("[Car] 自动断漂: 低速宽限期结束未挽救")
		else:
			# 第一次进入低速: 启动宽限期
			if drift_low_speed_grace_time > 0.0:
				_low_speed_grace_left = drift_low_speed_grace_time
				_grace_start_angle = drift_accum_angle_deg
				print("[Car] 进入低速宽限期 %.2fs (累计角度=%.1f°)" % [drift_low_speed_grace_time, drift_accum_angle_deg])
			else:
				# 没设宽限期 → 直接断漂(兼容旧行为)
				_end_drift(false)
				print("[Car] 自动断漂: 速度过低(无宽限)")
	else:
		# 速度恢复: 取消宽限期
		if _low_speed_grace_left > 0.0:
			print("[Car] 速度恢复, 退出宽限期")
			_low_speed_grace_left = 0.0


# ============================================================
#  集气公式
# ============================================================
func _update_drift_charge(delta: float) -> void:
	if state != State.DRIFT:
		return

	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed_abs: float = absf(linear_velocity.dot(right))
	var lateral_contrib: float = lateral_speed_abs * charge_per_lateral_m * delta

	# 【关键】用 basis.z 在 XZ 平面投影的夹角算 yaw_delta, 避免欧拉角跳变 bug
	var fwd: Vector3 = -car_mesh.global_transform.basis.z
	var fwd_xz: Vector2 = Vector2(fwd.x, fwd.z).normalized()
	var yaw_delta_rad: float = 0.0
	if _prev_forward_xz.length() > 0.01:
		yaw_delta_rad = _prev_forward_xz.angle_to(fwd_xz)
	_prev_forward_xz = fwd_xz

	var yaw_rate_abs: float = absf(yaw_delta_rad) / maxf(delta, 0.0001)
	var yaw_contrib: float = yaw_rate_abs * charge_yaw_rate_weight

	# 累积角度(绝对值, 任意方向都算)
	drift_accum_angle_deg += rad_to_deg(absf(yaw_delta_rad))

	var floor_contrib: float = charge_min_per_sec * delta
	var inc: float = lateral_contrib + yaw_contrib + floor_contrib
	drift_accum_charge += inc
	charge += inc

	while charge >= charge_nitro_full and nitro_stock + _pending_nitro < max_nitro_stock:
		charge -= charge_nitro_full
		if instant_nitro_settle:
			# 立即结算: 直接加格子, 触发 HUD 闪光
			nitro_stock += 1
			emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
		else:
			# 延迟结算: 进入待发放队列, 退漂时统一加
			_pending_nitro += 1
	# 集气槽夹紧(防止溢出): 满栏时锁在 99
	if nitro_stock + _pending_nitro >= max_nitro_stock:
		charge = minf(charge, charge_nitro_full - 1.0)

	# 实时等级判定: 通知 HUD 小喷灯(双喷不再在漂移中亮, 改为小喷期间按 Q 蓄能时亮)
	var new_level: String = "none"
	if drift_accum_angle_deg >= drift_min_angle_to_boost:
		new_level = "mini"
	if new_level != _drift_charge_level:
		_drift_charge_level = new_level
		emit_signal("drift_charge_level_changed", new_level)


func angle_difference(a: float, b: float) -> float:
	var d: float = fmod(b - a + PI, TAU)
	if d < 0.0:
		d += TAU
	return d - PI


# ============================================================
#  喷射
# ============================================================
func _try_boost_w() -> void:
	# 1) 双喷蓄满 + 小喷中 → 直接接力释放双喷
	if _double_armed:
		print("[Car] 双喷接力释放!")
		_double_armed = false
		_double_armed_left = 0.0
		emit_signal("double_charge_lost")
		_start_boost("double", double_boost_power, double_boost_time)
		return

	# 2) 漂移中按 W: 立即退漂(进入窗口判定)
	print("[Car] 按 W! state=", state, " angle=%.1f" % drift_accum_angle_deg, " win_left=%.2f" % boost_window_left, " win_lvl=", boost_window_level)
	if state == State.DRIFT:
		_end_drift()
		print("[Car]   退漂后 win_left=%.2f" % boost_window_left, " win_lvl=", boost_window_level)
		# 如果窗口立即开了, 顺势直接释放对应等级喷射
		if boost_window_left > 0.0:
			_consume_boost_window()
		return

	# 3) NORMAL 状态按 W: 看有没有窗口可消耗
	if boost_window_left > 0.0:
		print("[Car]   NORMAL 状态消耗窗口")
		_consume_boost_window()
		return

	# 既不在漂, 也没窗口, 也没蓄好双喷 → 啥也不做
	print("[Car]   无效按 W (无窗口/不漂移)")
	emit_signal("boost_triggered", "insufficient")


func _consume_boost_window() -> void:
	# 现在只处理小喷窗口(双喷走 _double_armed 路径)
	if boost_window_level == "mini":
		_start_boost("mini", mini_boost_power, mini_boost_time)
		print("[Car] 小喷释放!")
	# 关闭窗口
	boost_window_level = ""
	boost_window_left = 0.0
	emit_signal("boost_window_closed")


# ============================================================
#  双喷蓄能 (小喷期间按住 Q 一段时间 → 双喷就绪 → 按 W 释放)
# ============================================================
func _update_double_charge(delta: float) -> void:
	# 双喷已就绪: 倒计时, 超时失效
	if _double_armed:
		_double_armed_left -= delta
		if _double_armed_left <= 0.0:
			_double_armed = false
			_double_armed_left = 0.0
			emit_signal("double_charge_lost")
			print("[Car] 双喷资格超时失效")
		return

	# 必须满足: 正在小喷 + 不在漂移状态(漂移按 Q 是退漂)
	if not is_boosting or boost_type != "mini":
		# 离开小喷状态时清零进度
		if _double_charge_t > 0.0:
			_double_charge_t = 0.0
			emit_signal("double_charge_progress", 0.0)
		return

	# 小喷期间持续按住 Q
	if Input.is_action_pressed("drift"):
		_double_charge_t += delta
		var prog: float = clampf(_double_charge_t / maxf(double_charge_hold_time, 0.001), 0.0, 1.0)
		emit_signal("double_charge_progress", prog)
		if _double_charge_t >= double_charge_hold_time:
			_double_armed = true
			_double_armed_left = double_charge_window
			_double_charge_t = 0.0
			emit_signal("double_charge_ready")
			emit_signal("double_charge_progress", 1.0)
			print("[Car] 双喷已蓄满, 可按 W")
	else:
		# 松开 Q: 进度重置
		if _double_charge_t > 0.0:
			_double_charge_t = 0.0
			emit_signal("double_charge_progress", 0.0)


func _update_boost_window(delta: float) -> void:
	if boost_window_left <= 0.0:
		return
	boost_window_left -= delta
	if boost_window_left <= 0.0:
		boost_window_left = 0.0
		boost_window_level = ""
		emit_signal("boost_window_closed")


func _try_nitro() -> void:
	if nitro_stock <= 0:
		return
	nitro_stock -= 1
	emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
	_start_boost("nitro", nitro_power, nitro_time)


func _start_boost(type_name: String, power: float, duration: float) -> void:
	boost_type = type_name
	boost_base_power = power
	boost_power = power
	boost_total_time = duration
	boost_time_left = duration
	is_boosting = true
	emit_signal("boost_triggered", type_name)

	var shake := {"mini": 0.3, "double": 0.55, "nitro": 0.85}
	emit_signal("camera_shake_requested", shake.get(type_name, 0.3), duration)

	if fx_node and fx_node.has_method("play_boost"):
		fx_node.play_boost(type_name, duration)


func _update_boost_timer(delta: float) -> void:
	if not is_boosting:
		return
	boost_time_left -= delta
	# 应用曲线: 进度 0..1 → 曲线值 → 缩放当前推力
	var progress: float = 1.0 - clampf(boost_time_left / maxf(boost_total_time, 0.0001), 0.0, 1.0)
	var curve: Curve = _get_boost_curve(boost_type)
	if curve:
		boost_power = boost_base_power * curve.sample(progress)
	else:
		boost_power = boost_base_power
	if boost_time_left <= 0.0:
		if boost_type == "mini":
			last_mini_end_time = Time.get_ticks_msec() / 1000.0
		is_boosting = false
		boost_type = ""
		boost_power = 0.0
		boost_base_power = 0.0


func _get_boost_curve(type_name: String) -> Curve:
	match type_name:
		"mini":
			return mini_boost_curve
		"double":
			return double_boost_curve
		"nitro":
			return nitro_boost_curve
	return null


# ============================================================
#  撞墙
# ============================================================
func _on_body_entered(_body: Node) -> void:
	if state != State.DRIFT:
		return
	# 【修复】只有真正撞墙才扣气: 用"速度大小骤降"判定
	# 保存上一帧速度, 本帧碰撞后若速度损失 > 阈值才算撞墙
	var cur_speed: float = linear_velocity.length()
	var speed_loss: float = _last_frame_speed - cur_speed
	if speed_loss < wall_crash_speed_loss:
		return   # 轻微擦碰, 不算
	var lost: float = drift_accum_charge * (1.0 - crash_charge_penalty)
	charge = maxf(charge - lost, 0.0)
	drift_accum_charge *= crash_charge_penalty
	emit_signal("wall_crashed", lost)
	emit_signal("camera_shake_requested", 0.4, 0.25)


# ============================================================
#  斜面墙 + 接触法线检测 (在物理回调中才能拿到有效 contact)
# ============================================================
func _integrate_forces(state_phys: PhysicsDirectBodyState3D) -> void:
	if not slope_as_wall_enabled:
		return
	var contact_count: int = state_phys.get_contact_count()
	if contact_count <= 0:
		return
	var wall_threshold_rad: float = deg_to_rad(slope_wall_angle_deg)
	var absorbed: bool = false
	for i in range(contact_count):
		var n: Vector3 = state_phys.get_contact_local_normal(i)
		# n 与 Y 轴夹角: 0°=纯地面, 90°=纯墙
		var angle_to_up: float = n.angle_to(Vector3.UP)
		if angle_to_up >= wall_threshold_rad and not absorbed:
			# 投影出沿法线方向的速度分量, 抵消掉
			var v: Vector3 = state_phys.linear_velocity
			var into_wall: float = -v.dot(n)  # 朝墙冲的速率(正值)
			if into_wall > 0.5:
				v += n * into_wall * slope_wall_bounce_absorb
				# 沿法线推开一点, 避免卡墙
				v += n * slope_wall_push_back
				state_phys.linear_velocity = v
				absorbed = true
				emit_signal("camera_shake_requested", 0.35, 0.2)


# ============================================================
#  HUD 信号
# ============================================================
func _emit_hud_signals() -> void:
	var kmh: float = linear_velocity.length() * 3.6
	emit_signal("speed_changed", kmh)
	emit_signal("charge_changed", charge, charge_nitro_full)
