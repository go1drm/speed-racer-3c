extends RigidBody3D
## ============================================================
##  QQ飞车式车辆控制器 —— by 炸弹猫
##  架构：隐形球形刚体(物理) + 独立视觉车壳(表现)
##  特色：漂移蓄力 / 小喷 / 双喷 / 氮气 / 甩尾 & 侧身漂移
## ============================================================

# ---------------- 基础移动参数 ----------------
@export_group("Movement")
@export var max_speed: float = 45.0             ## 正常最高时速（m/s 近似）
@export var acceleration: float = 55.0          ## 加速力（越大起步越猛）
@export var brake_force: float = 80.0           ## 刹车/倒车力
@export var steering_deg: float = 28.0          ## 前轮视觉转角
@export var turn_speed: float = 3.2             ## 车头指向跟随速度
@export var turn_stop_limit: float = 0.6        ## 多慢才停止转向
@export var ground_friction: float = 6.0        ## 地面侧向摩擦（越大越抓地）
@export var natural_decel: float = 2.5          ## 无油门时的自然减速

# ---------------- 漂移参数 ----------------
@export_group("Drift")
@export var drift_friction: float = 1.2         ## 漂移时的侧向摩擦（越小越滑）
@export var drift_steer_mult: float = 1.55      ## 漂移时转向增幅
@export var drift_min_speed: float = 12.0       ## 最低触发漂移的车速
@export var drift_body_tilt: float = 22.0       ## 漂移时车身额外倾斜（度）
@export var drift_yaw_offset_tuck: float = 18.0 ## 甩尾漂移：车头偏离速度方向的角度
@export var drift_yaw_offset_side: float = 35.0 ## 侧身漂移：车头偏离速度方向的角度
@export var side_drift_threshold: float = 0.65  ## 进入漂移时有多少反打才算"侧身"

# ---------------- 喷射参数 ----------------
@export_group("Boost")
@export var charge_max: float = 100.0           ## 蓄力槽容量
@export var charge_rate: float = 55.0           ## 漂移时每秒蓄力
@export var mini_boost_cost: float = 35.0       ## 小喷消耗
@export var mini_boost_power: float = 22.0      ## 小喷推进力
@export var mini_boost_time: float = 0.6        ## 小喷持续秒数
@export var double_boost_window: float = 0.35   ## 小喷后多少秒内再喷出发"双喷"
@export var double_boost_power: float = 40.0    ## 双喷推进力
@export var double_boost_time: float = 0.9      ## 双喷持续
@export var nitro_full_cost: float = 100.0      ## 氮气消耗整槽
@export var nitro_power: float = 55.0           ## 氮气推进力
@export var nitro_time: float = 2.2             ## 氮气持续
@export var boost_speed_multiplier: float = 1.55 ## 喷射时最高速放宽倍数

# ---------------- 视觉 ----------------
@export_group("Visual")
@export var body_tilt: float = 28.0             ## 过弯视觉侧倾幅度
@export var sphere_offset: Vector3 = Vector3.DOWN

# ---------------- 节点引用 ----------------
@onready var car_mesh: Node3D = $CarMesh
@onready var body_mesh: Node3D = $CarMesh/suv2
@onready var ground_ray: RayCast3D = $CarMesh/RayCast3D
@onready var right_wheel: Node3D = $CarMesh/suv2/wheel_frontRight
@onready var left_wheel: Node3D = $CarMesh/suv2/wheel_frontLeft

# ---------------- 自动加载 HUD ----------------
@export var auto_spawn_hud: bool = true
@export var hud_scene: PackedScene = preload("res://HUD.tscn")

# ---------------- 信号（供 UI / 音效订阅） ----------------
signal speed_changed(kmh: float)
signal charge_changed(value: float, max_value: float)
signal drift_started(mode: String)      ## "tuck"=甩尾 "side"=侧身
signal drift_ended(charge_gained: float)
signal boost_triggered(type: String)    ## "mini" / "double" / "nitro"

# ---------------- 状态机 ----------------
enum State { NORMAL, DRIFT, BOOST }
var state: int = State.NORMAL

# ---------------- 运行时变量 ----------------
var throttle_input: float = 0.0      # -1..1
var steer_input: float = 0.0         # -1..1 (+左 -右，和原版保持一致)

# 漂移
var drift_mode: String = ""          # "tuck" / "side"
var drift_dir: float = 0.0           # +1 向左漂 / -1 向右漂
var drift_yaw_offset: float = 0.0    # 当前偏航角度（度）
var charge: float = 0.0              # 当前蓄力值

# 喷射
var boost_type: String = ""          # "mini" / "double" / "nitro"
var boost_time_left: float = 0.0     # 当前喷射剩余
var boost_power: float = 0.0         # 当前喷射推力
var last_mini_end_time: float = -999.0  # 上次小喷结束时刻（用于双喷判定）

# ============================================================
#  主循环
# ============================================================
func _ready() -> void:
	if auto_spawn_hud and hud_scene:
		# 延迟一帧添加，等场景树就绪
		call_deferred("_spawn_hud")


func _spawn_hud() -> void:
	if get_tree().current_scene.find_child("HUD", true, false):
		return  # 已有 HUD
	var hud: CanvasLayer = hud_scene.instantiate()
	hud.name = "HUD"
	get_tree().current_scene.add_child(hud)
	# 添加到树后再设置 car_path 并触发连接
	hud.car_path = hud.get_path_to(self)
	hud.call_deferred("_connect_to_car")


func _physics_process(delta: float) -> void:
	_read_input()
	_update_boost_timer(delta)
	_update_state()

	# 让视觉车壳跟随球体
	car_mesh.position = position + sphere_offset

	if ground_ray.is_colliding():
		_apply_drive_force(delta)
		_apply_lateral_friction(delta)

	_update_visuals(delta)
	_emit_hud_signals()


# ============================================================
#  输入
# ============================================================
func _read_input() -> void:
	throttle_input = Input.get_axis("brake", "accelerate")
	steer_input = Input.get_axis("steer_right", "steer_left")

	# 漂移触发（按住 shift 且有速度且有油门）
	if Input.is_action_just_pressed("drift"):
		_try_start_drift()
	if Input.is_action_just_released("drift"):
		_try_end_drift()

	# 氮气
	if Input.is_action_just_pressed("nitro"):
		_try_nitro()


# ============================================================
#  驱动力 / 刹车
# ============================================================
func _apply_drive_force(_delta: float) -> void:
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	var current_speed: float = linear_velocity.dot(forward)
	var speed_cap: float = max_speed * (boost_speed_multiplier if state == State.BOOST else 1.0)

	# 主驱动力
	if throttle_input > 0.01:
		if current_speed < speed_cap:
			apply_central_force(forward * acceleration * throttle_input * mass)
	elif throttle_input < -0.01:
		# 倒车 / 刹车
		apply_central_force(forward * brake_force * throttle_input * mass)
	else:
		# 松开油门：自然减速（仅减少前向分量）
		var fwd_vel: Vector3 = forward * current_speed
		apply_central_force(-fwd_vel.normalized() * natural_decel * mass if fwd_vel.length() > 0.1 else Vector3.ZERO)

	# 喷射推进力（叠加在主驱动上）
	if state == State.BOOST:
		apply_central_force(forward * boost_power * mass)


# ============================================================
#  侧向摩擦（决定"抓地 vs 打滑"的关键）
# ============================================================
func _apply_lateral_friction(delta: float) -> void:
	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed: float = linear_velocity.dot(right)

	var friction: float = drift_friction if state == State.DRIFT else ground_friction
	# 通过速度积分的方式吃掉侧向分量
	var correction: Vector3 = -right * lateral_speed * friction * delta
	apply_central_impulse(correction * mass)


# ============================================================
#  车头指向 / 漂移偏航
# ============================================================
func _update_visuals(delta: float) -> void:
	# 车速太慢不做朝向更新，避免抖动
	if linear_velocity.length() < turn_stop_limit:
		return

	# 前轮视觉转角
	var wheel_turn: float = deg_to_rad(steering_deg) * steer_input
	right_wheel.rotation.y = wheel_turn
	left_wheel.rotation.y = wheel_turn

	# 决定本帧目标偏航速率
	var turn_mult: float = drift_steer_mult if state == State.DRIFT else 1.0
	var turn_rad: float = deg_to_rad(steering_deg) * steer_input * turn_mult

	var new_basis: Basis = car_mesh.global_transform.basis.rotated(
		car_mesh.global_transform.basis.y, turn_rad
	)
	car_mesh.global_transform.basis = car_mesh.global_transform.basis.slerp(
		new_basis, turn_speed * delta
	)
	car_mesh.global_transform = car_mesh.global_transform.orthonormalized()

	# 视觉车身倾斜（普通过弯 + 漂移额外倾）
	var lean_base: float = -steer_input * linear_velocity.length() / body_tilt
	var lean_drift: float = 0.0
	if state == State.DRIFT:
		lean_drift = deg_to_rad(drift_body_tilt) * drift_dir
	body_mesh.rotation.z = lerp(body_mesh.rotation.z, lean_base + lean_drift, 6.0 * delta)

	# 漂移时车壳额外 yaw 偏离速度方向（甩尾/侧身的视觉核心）
	if state == State.DRIFT:
		var target_yaw: float = deg_to_rad(drift_yaw_offset) * drift_dir
		body_mesh.rotation.y = lerp(body_mesh.rotation.y, target_yaw, 4.5 * delta)
	else:
		body_mesh.rotation.y = lerp(body_mesh.rotation.y, 0.0, 5.0 * delta)

	# 沿地面法线对齐
	if ground_ray.is_colliding():
		var n: Vector3 = ground_ray.get_collision_normal()
		var xform: Transform3D = _align_with_y(car_mesh.global_transform, n)
		car_mesh.global_transform = car_mesh.global_transform.interpolate_with(xform, 10.0 * delta)


func _align_with_y(xform: Transform3D, new_y: Vector3) -> Transform3D:
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	return xform.orthonormalized()


# ============================================================
#  漂移系统
# ============================================================
func _try_start_drift() -> void:
	if state == State.DRIFT:
		return
	if linear_velocity.length() < drift_min_speed:
		return
	if absf(steer_input) < 0.2:
		return
	if throttle_input < 0.1:
		return

	# 判定甩尾 / 侧身：按下漂移瞬间如果方向盘反打（过弯中突然反向），就是侧身
	# 简化版本：根据进入瞬间的侧向速度方向和转向方向是否一致
	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed: float = linear_velocity.dot(right)
	# steer_input > 0 向左，lateral_speed 正代表向右滑 → 若反向 = 反打 = 侧身
	var counter_steer: bool = signf(lateral_speed) != signf(steer_input) and absf(lateral_speed) > side_drift_threshold * 2.0

	drift_dir = signf(steer_input) if steer_input != 0.0 else 1.0
	if counter_steer:
		drift_mode = "side"
		drift_yaw_offset = drift_yaw_offset_side
	else:
		drift_mode = "tuck"
		drift_yaw_offset = drift_yaw_offset_tuck

	state = State.DRIFT
	emit_signal("drift_started", drift_mode)


func _try_end_drift() -> void:
	if state != State.DRIFT:
		return
	var gained: float = charge
	state = State.NORMAL
	# 退出漂移时，根据蓄力值自动触发小喷（QQ飞车经典）
	if gained >= mini_boost_cost:
		_trigger_mini_boost()
	emit_signal("drift_ended", gained)
	charge = 0.0


# ============================================================
#  喷射系统
# ============================================================
func _update_boost_timer(delta: float) -> void:
	# 漂移中蓄力
	if state == State.DRIFT:
		charge = minf(charge + charge_rate * delta, charge_max)

	# 喷射计时
	if state == State.BOOST:
		boost_time_left -= delta
		if boost_time_left <= 0.0:
			_end_boost()


func _trigger_mini_boost() -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	# 双喷判定：上次小喷结束在窗口内
	if now - last_mini_end_time <= double_boost_window:
		_start_boost("double", double_boost_power, double_boost_time)
	else:
		_start_boost("mini", mini_boost_power, mini_boost_time)


func _try_nitro() -> void:
	if charge < nitro_full_cost:
		return
	charge = 0.0
	_start_boost("nitro", nitro_power, nitro_time)


func _start_boost(type_name: String, power: float, duration: float) -> void:
	boost_type = type_name
	boost_power = power
	boost_time_left = duration
	state = State.BOOST
	emit_signal("boost_triggered", type_name)


func _end_boost() -> void:
	if boost_type == "mini":
		last_mini_end_time = Time.get_ticks_msec() / 1000.0
	boost_type = ""
	boost_power = 0.0
	boost_time_left = 0.0
	state = State.NORMAL


# ============================================================
#  状态机维护（处理优先级：BOOST > DRIFT > NORMAL）
# ============================================================
func _update_state() -> void:
	# 目前状态由事件驱动，这里留空做兜底
	pass


# ============================================================
#  HUD 信号
# ============================================================
func _emit_hud_signals() -> void:
	var kmh: float = linear_velocity.length() * 3.6
	emit_signal("speed_changed", kmh)
	emit_signal("charge_changed", charge, charge_max)
