extends RigidBody3D
## ============================================================
##  QQ飞车式车辆控制器 v2 —— 炸弹猫精调版
##  操作：↑↓←→ 方向 · Q 漂移（按住）· W 小喷 · E 氮气
##  漂移集气：漂移距离 × 车头摆动角速度权重（按你的公式）
##  撞墙：当前漂移累计的集气 × 0.2（扣80%）
##  氮气：集满 100 得 1 个，上限 2 个
## ============================================================

# ---------------- 基础移动 ----------------
@export_group("Movement")
@export var max_speed: float = 45.0
@export var acceleration: float = 55.0
@export var brake_force: float = 80.0
@export var steering_deg: float = 28.0
@export var turn_speed: float = 3.2
@export var turn_stop_limit: float = 0.6
@export var ground_friction: float = 6.0
@export var natural_decel: float = 2.5

# ---------------- 漂移 ----------------
@export_group("Drift")
@export var drift_friction: float = 1.0            ## 漂移时侧向摩擦（越小越滑）
@export var drift_steer_mult: float = 1.6          ## 漂移时转向增幅
@export var drift_min_speed: float = 10.0
@export var drift_body_tilt: float = 22.0
@export var drift_yaw_offset_tuck: float = 18.0
@export var drift_yaw_offset_side: float = 35.0
@export var side_drift_threshold: float = 1.2      ## 进入瞬间反向侧速多大算侧身

# ---------------- 集气公式参数 ----------------
@export_group("Charge Formula")
@export var charge_nitro_full: float = 100.0       ## 集满 100 = 1 个氮气
@export var charge_per_lateral_m: float = 2.2      ## 每米侧向滑移贡献的基础集气
@export var charge_yaw_rate_weight: float = 1.8    ## 车头角速度权重（越大侧身越值钱）
@export var charge_min_per_sec: float = 12.0       ## 漂移时的最低集气速率（兜底）
@export var crash_charge_penalty: float = 0.2      ## 撞墙后本次漂移已集气保留比例（=0.2 扣80%）
@export var max_nitro_stock: int = 2               ## 氮气槽上限

# ---------------- 喷射 ----------------
@export_group("Boost")
@export var mini_boost_cost: float = 35.0          ## 小喷消耗集气
@export var mini_boost_power: float = 24.0
@export var mini_boost_time: float = 0.55
@export var double_boost_window: float = 0.35      ## 小喷结束后多少秒内再按 W 触发双喷
@export var double_boost_power: float = 42.0
@export var double_boost_time: float = 0.85
@export var nitro_power: float = 58.0
@export var nitro_time: float = 2.2
@export var boost_speed_multiplier: float = 1.55

# ---------------- 视觉 ----------------
@export_group("Visual")
@export var body_tilt: float = 28.0
@export var sphere_offset: Vector3 = Vector3.DOWN

# ---------------- 节点 ----------------
@onready var car_mesh: Node3D = $CarMesh
@onready var body_mesh: Node3D = $CarMesh/suv2
@onready var ground_ray: RayCast3D = $CarMesh/RayCast3D
@onready var right_wheel: Node3D = $CarMesh/suv2/wheel_frontRight
@onready var left_wheel: Node3D = $CarMesh/suv2/wheel_frontLeft

@export var auto_spawn_hud: bool = true
@export var hud_scene: PackedScene = preload("res://HUD.tscn")
@export var fx_scene: PackedScene = preload("res://BoostFX.tscn")

# ---------------- 信号 ----------------
signal speed_changed(kmh: float)
signal charge_changed(value: float, max_value: float)
signal nitro_stock_changed(stock: int, max_stock: int)
signal drift_started(mode: String)
signal drift_ended(charge_gained_this_round: float)
signal boost_triggered(type: String)          ## "mini" / "double" / "nitro"
signal wall_crashed(lost_amount: float)
signal camera_shake_requested(intensity: float, duration: float)

# ---------------- 状态 ----------------
enum State { NORMAL, DRIFT }
var state: int = State.NORMAL
var is_boosting: bool = false
var boost_type: String = ""
var boost_time_left: float = 0.0
var boost_power: float = 0.0
var last_mini_end_time: float = -999.0

# 输入
var throttle_input: float = 0.0
var steer_input: float = 0.0

# 漂移
var drift_mode: String = ""
var drift_dir: float = 0.0
var drift_yaw_offset: float = 0.0
var drift_accum_charge: float = 0.0          # 本次漂移累计集气（撞墙时要扣）
var prev_yaw: float = 0.0                    # 车头上一帧 yaw（求角速度用）

# 氮气槽
var charge: float = 0.0
var nitro_stock: int = 0

# 特效
var fx_node: Node3D = null

# ============================================================
#  Lifecycle
# ============================================================
func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)

	if auto_spawn_hud and hud_scene:
		call_deferred("_spawn_hud")
	# 预生成特效节点挂在车壳上
	if fx_scene:
		fx_node = fx_scene.instantiate()
		call_deferred("_attach_fx")


func _attach_fx() -> void:
	if fx_node and car_mesh:
		car_mesh.add_child(fx_node)
		fx_node.position = Vector3(0, 0.2, 0.8)   # 车尾位置


func _spawn_hud() -> void:
	if get_tree().current_scene.find_child("HUD", true, false):
		return
	var hud: CanvasLayer = hud_scene.instantiate()
	hud.name = "HUD"
	get_tree().current_scene.add_child(hud)
	hud.car_path = hud.get_path_to(self)
	hud.call_deferred("_connect_to_car")


# ============================================================
#  主循环
# ============================================================
func _physics_process(delta: float) -> void:
	_read_input()
	_update_boost_timer(delta)

	car_mesh.position = position + sphere_offset

	if ground_ray.is_colliding():
		_apply_drive_force(delta)
		_apply_lateral_friction(delta)

	_update_drift_charge(delta)
	_update_visuals(delta)
	_emit_hud_signals()


# ============================================================
#  输入
# ============================================================
func _read_input() -> void:
	throttle_input = Input.get_axis("brake", "accelerate")
	steer_input = Input.get_axis("steer_right", "steer_left")

	# Q 漂移：按住进入 / 松手退出
	if Input.is_action_just_pressed("drift"):
		_try_start_drift()
	if Input.is_action_just_released("drift"):
		_try_end_drift()

	# W 小喷：主动按键，需要满足条件
	if Input.is_action_just_pressed("boost"):
		_try_boost_w()

	# E 氮气
	if Input.is_action_just_pressed("nitro"):
		_try_nitro()


# ============================================================
#  驱动力
# ============================================================
func _apply_drive_force(_delta: float) -> void:
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	var current_speed: float = linear_velocity.dot(forward)
	var speed_cap: float = max_speed * (boost_speed_multiplier if is_boosting else 1.0)

	if throttle_input > 0.01:
		if current_speed < speed_cap:
			apply_central_force(forward * acceleration * throttle_input * mass)
	elif throttle_input < -0.01:
		apply_central_force(forward * brake_force * throttle_input * mass)
	else:
		var fwd_vel: Vector3 = forward * current_speed
		if fwd_vel.length() > 0.1:
			apply_central_force(-fwd_vel.normalized() * natural_decel * mass)

	if is_boosting:
		apply_central_force(forward * boost_power * mass)


func _apply_lateral_friction(delta: float) -> void:
	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed: float = linear_velocity.dot(right)
	var friction: float = drift_friction if state == State.DRIFT else ground_friction
	var correction: Vector3 = -right * lateral_speed * friction * delta
	apply_central_impulse(correction * mass)


# ============================================================
#  视觉 + 车头朝向
# ============================================================
func _update_visuals(delta: float) -> void:
	if linear_velocity.length() < turn_stop_limit:
		prev_yaw = car_mesh.rotation.y
		return

	var wheel_turn: float = deg_to_rad(steering_deg) * steer_input
	right_wheel.rotation.y = wheel_turn
	left_wheel.rotation.y = wheel_turn

	var turn_mult: float = drift_steer_mult if state == State.DRIFT else 1.0
	var turn_rad: float = deg_to_rad(steering_deg) * steer_input * turn_mult

	var new_basis: Basis = car_mesh.global_transform.basis.rotated(
		car_mesh.global_transform.basis.y, turn_rad
	)
	car_mesh.global_transform.basis = car_mesh.global_transform.basis.slerp(
		new_basis, turn_speed * delta
	)
	car_mesh.global_transform = car_mesh.global_transform.orthonormalized()

	# 车身侧倾
	var lean_base: float = -steer_input * linear_velocity.length() / body_tilt
	var lean_drift: float = 0.0
	if state == State.DRIFT:
		lean_drift = deg_to_rad(drift_body_tilt) * drift_dir
	body_mesh.rotation.z = lerp(body_mesh.rotation.z, lean_base + lean_drift, 6.0 * delta)

	# 车头 yaw 偏移
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
	if absf(steer_input) < 0.2:
		return
	if throttle_input < 0.1:
		return

	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed: float = linear_velocity.dot(right)
	# 反打判定：侧向速度方向与转向方向相反，且有一定侧速
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
	emit_signal("drift_started", drift_mode)


func _try_end_drift() -> void:
	if state != State.DRIFT:
		return
	var gained: float = drift_accum_charge
	state = State.NORMAL
	drift_accum_charge = 0.0
	drift_mode = ""
	emit_signal("drift_ended", gained)


# ============================================================
#  集气公式（按照宝贝给的正确公式）
#    charge_per_frame = lateral_speed * dt * base_rate + yaw_rate * weight
# ============================================================
func _update_drift_charge(delta: float) -> void:
	if state != State.DRIFT:
		return

	# 1. 侧向滑移距离贡献
	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed_abs: float = absf(linear_velocity.dot(right))
	var lateral_contrib: float = lateral_speed_abs * charge_per_lateral_m * delta

	# 2. 车头角速度贡献（侧身漂的 yaw 变化更剧烈）
	var yaw_rate_abs: float = absf(angle_difference(prev_yaw, car_mesh.rotation.y)) / maxf(delta, 0.0001)
	var yaw_contrib: float = yaw_rate_abs * charge_yaw_rate_weight

	# 3. 兜底每秒最低速率
	var floor_contrib: float = charge_min_per_sec * delta

	var inc: float = lateral_contrib + yaw_contrib + floor_contrib
	drift_accum_charge += inc
	charge += inc

	# 满 100 转成一个氮气
	while charge >= charge_nitro_full and nitro_stock < max_nitro_stock:
		charge -= charge_nitro_full
		nitro_stock += 1
		emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
	# 如果氮气已满，集气也封顶
	if nitro_stock >= max_nitro_stock:
		charge = minf(charge, charge_nitro_full - 1.0)


func angle_difference(a: float, b: float) -> float:
	var d: float = fmod(b - a + PI, TAU)
	if d < 0.0:
		d += TAU
	return d - PI


# ============================================================
#  喷射
# ============================================================
func _try_boost_w() -> void:
	# 双喷判定（小喷结束后 0.35s 内又按 W）
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - last_mini_end_time <= double_boost_window and charge >= mini_boost_cost:
		charge -= mini_boost_cost
		_start_boost("double", double_boost_power, double_boost_time)
		return
	# 普通小喷：需要足够集气
	if charge >= mini_boost_cost:
		charge -= mini_boost_cost
		_start_boost("mini", mini_boost_power, mini_boost_time)


func _try_nitro() -> void:
	if nitro_stock <= 0:
		return
	nitro_stock -= 1
	emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
	_start_boost("nitro", nitro_power, nitro_time)


func _start_boost(type_name: String, power: float, duration: float) -> void:
	boost_type = type_name
	boost_power = power
	boost_time_left = duration
	is_boosting = true
	emit_signal("boost_triggered", type_name)

	# 镜头震动强度
	var shake := {"mini": 0.3, "double": 0.55, "nitro": 0.85}
	emit_signal("camera_shake_requested", shake.get(type_name, 0.3), duration)

	# 特效
	if fx_node and fx_node.has_method("play_boost"):
		fx_node.play_boost(type_name, duration)


func _update_boost_timer(delta: float) -> void:
	if not is_boosting:
		return
	boost_time_left -= delta
	if boost_time_left <= 0.0:
		if boost_type == "mini":
			last_mini_end_time = Time.get_ticks_msec() / 1000.0
		is_boosting = false
		boost_type = ""
		boost_power = 0.0


# ============================================================
#  撞墙扣气
# ============================================================
func _on_body_entered(_body: Node) -> void:
	if state != State.DRIFT:
		return
	var lost: float = drift_accum_charge * (1.0 - crash_charge_penalty)
	charge = maxf(charge - lost, 0.0)
	drift_accum_charge *= crash_charge_penalty
	emit_signal("wall_crashed", lost)
	emit_signal("camera_shake_requested", 0.4, 0.25)


# ============================================================
#  HUD 信号
# ============================================================
func _emit_hud_signals() -> void:
	var kmh: float = linear_velocity.length() * 3.6
	emit_signal("speed_changed", kmh)
	emit_signal("charge_changed", charge, charge_nitro_full)
