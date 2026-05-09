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
@export var ground_friction: float = 6.0
@export var natural_decel: float = 2.5

# ---------------- 漂移 ----------------
@export_group("Drift")
@export var drift_friction: float = 1.0
@export var drift_steer_mult: float = 1.6
@export var drift_min_speed: float = 10.0
@export var drift_body_tilt: float = 22.0
@export var drift_yaw_offset_tuck: float = 18.0
@export var drift_yaw_offset_side: float = 35.0
@export var side_drift_threshold: float = 1.2
@export var drift_min_angle_to_boost: float = 15.0  ## 退漂小喷最低累积角度(度)
@export var drift_max_duration: float = 5.0          ## 漂移最长时间 (防一直漂)
@export var drift_break_speed_ratio: float = 0.5     ## 速度低于 drift_min_speed * 此值时自动断漂
@export var drift_accel_mult: float = 0.35           ## 漂移时油门加速力倍率 (越小越减速感)
@export var drift_passive_decel: float = 8.0        ## 漂移时被动减速力 (模拟打滑能耗)
@export var drift_counter_steer_break_time: float = 0.25  ## 反向打方向超过此时长(秒)断漂

# ---------------- 集气公式参数 ----------------
@export_group("Charge Formula")
@export var charge_nitro_full: float = 100.0
@export var charge_per_lateral_m: float = 2.2
@export var charge_yaw_rate_weight: float = 1.8
@export var charge_min_per_sec: float = 12.0
@export var crash_charge_penalty: float = 0.2
@export var max_nitro_stock: int = 2
@export var wall_crash_speed_loss: float = 6.0     ## 一帧速度损失超过此值(m/s)才算撞墙

# ---------------- 喷射 ----------------
@export_group("Boost")
@export var mini_boost_cost: float = 35.0
@export var mini_boost_power: float = 24.0
@export var mini_boost_time: float = 0.55
@export var double_boost_window: float = 0.35
@export var double_boost_power: float = 42.0
@export var double_boost_time: float = 0.85
@export var nitro_power: float = 58.0
@export var nitro_time: float = 2.2
@export var boost_speed_multiplier: float = 1.55

# ---------------- 视觉 ----------------
@export_group("Visual")
@export var body_tilt: float = 28.0                  ## 过弯侧倾对速度的敏感度(越大越迟钝)
@export var body_tilt_max_deg: float = 12.0          ## 过弯车身最大侧倾角(度) - 防侧翻
@export var head_yaw_deg: float = 4.0                ## 非漂移时车头左右"拧头"幅度(度)
@export var sphere_offset: Vector3 = Vector3.DOWN

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
var drift_accum_charge: float = 0.0
var drift_accum_angle_deg: float = 0.0      # 漂移累计车头转过的角度(度)
var drift_elapsed: float = 0.0              # 漂移已持续时间
var drift_counter_steer_time: float = 0.0   # 反向打方向已持续时间
var prev_yaw: float = 0.0

# 氮气槽
var charge: float = 0.0
var nitro_stock: int = 0

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

	car_mesh.position = position + sphere_offset

	if ground_ray and ground_ray.is_colliding():
		_apply_drive_force(delta)
		_apply_lateral_friction(delta)

	_update_drift_charge(delta)
	_check_drift_timeout(delta)
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
	if Input.is_action_just_pressed("drift"):
		if state == State.NORMAL:
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

	# 漂移中: 油门加速被大幅削弱, 而且额外有被动减速力 (模拟轮胎打滑能量损失)
	var accel_mult: float = drift_accel_mult if state == State.DRIFT else 1.0

	if throttle_input > 0.01:
		if current_speed < speed_cap:
			apply_central_force(forward * acceleration * throttle_input * accel_mult * mass)
	elif throttle_input < -0.01:
		apply_central_force(forward * brake_force * throttle_input * mass)
	else:
		var fwd_vel: Vector3 = forward * current_speed
		if fwd_vel.length() > 0.1:
			apply_central_force(-fwd_vel.normalized() * natural_decel * mass)

	# 漂移时持续被动减速(QQ飞车经典手感)
	if state == State.DRIFT and current_speed > 0.5:
		apply_central_force(-forward * drift_passive_decel * mass)

	# 喷射推力沿当前速度方向施加(防侧翻)
	if is_boosting:
		var vel_dir: Vector3 = linear_velocity
		vel_dir.y = 0.0
		if vel_dir.length() > 1.0:
			vel_dir = vel_dir.normalized()
		else:
			vel_dir = forward
		apply_central_force(vel_dir * boost_power * mass)


func _apply_lateral_friction(delta: float) -> void:
	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed: float = linear_velocity.dot(right)
	var friction: float = drift_friction if state == State.DRIFT else ground_friction
	var correction: Vector3 = -right * lateral_speed * friction * delta
	apply_central_impulse(correction * mass)


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

	var turn_mult: float = drift_steer_mult if state == State.DRIFT else speed_factor
	var turn_rad: float = deg_to_rad(steering_deg) * steer_input * turn_mult

	var new_basis: Basis = car_mesh.global_transform.basis.rotated(
		car_mesh.global_transform.basis.y, turn_rad
	)
	car_mesh.global_transform.basis = car_mesh.global_transform.basis.slerp(
		new_basis, turn_speed * delta
	)
	car_mesh.global_transform = car_mesh.global_transform.orthonormalized()

	# 车身侧倾（钳制在最大角度内，防止高速侧翻）
	var max_lean_rad: float = deg_to_rad(body_tilt_max_deg)
	var lean_base: float = clampf(-steer_input * linear_velocity.length() / body_tilt, -max_lean_rad, max_lean_rad)
	var lean_drift: float = 0.0
	if state == State.DRIFT:
		lean_drift = deg_to_rad(drift_body_tilt) * drift_dir
	body_mesh.rotation.z = lerp(body_mesh.rotation.z, lean_base + lean_drift, 6.0 * delta)

	# 车头 yaw 偏移
	if state == State.DRIFT:
		var target_yaw: float = deg_to_rad(drift_yaw_offset) * drift_dir
		body_mesh.rotation.y = lerp(body_mesh.rotation.y, target_yaw, 4.5 * delta)
	else:
		# 正常行驶：按方向键时车头做轻微左右"拧头"摆动（QQ飞车风格）
		var target_head_yaw: float = deg_to_rad(head_yaw_deg) * steer_input
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
	emit_signal("drift_started", drift_mode)
	if drift_fx_node and drift_fx_node.has_method("set_drifting"):
		drift_fx_node.set_drifting(true)
	print("[Car] 进入漂移 mode=", drift_mode, " fx=", drift_fx_node != null)


func _end_drift(success_boost: bool) -> void:
	if state != State.DRIFT:
		return
	var gained: float = drift_accum_charge
	state = State.NORMAL
	drift_accum_charge = 0.0
	drift_accum_angle_deg = 0.0
	drift_elapsed = 0.0
	drift_mode = ""
	emit_signal("drift_ended", gained, success_boost)
	if drift_fx_node and drift_fx_node.has_method("set_drifting"):
		drift_fx_node.set_drifting(false)


func _check_drift_timeout(delta: float) -> void:
	if state != State.DRIFT:
		return
	drift_elapsed += delta
	if drift_elapsed >= drift_max_duration:
		_end_drift(false)
		return
	# 速度不够自动断漂
	if linear_velocity.length() < drift_min_speed * drift_break_speed_ratio:
		_end_drift(false)
		print("[Car] 自动断漂: 速度过低")


# ============================================================
#  集气公式
# ============================================================
func _update_drift_charge(delta: float) -> void:
	if state != State.DRIFT:
		return

	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed_abs: float = absf(linear_velocity.dot(right))
	var lateral_contrib: float = lateral_speed_abs * charge_per_lateral_m * delta

	var yaw_delta: float = angle_difference(prev_yaw, car_mesh.rotation.y)
	var yaw_rate_abs: float = absf(yaw_delta) / maxf(delta, 0.0001)
	var yaw_contrib: float = yaw_rate_abs * charge_yaw_rate_weight

	# 累积角度（只计与漂移方向一致的 yaw 变化）
	if signf(yaw_delta) == signf(drift_dir) or drift_dir == 0.0:
		drift_accum_angle_deg += rad_to_deg(absf(yaw_delta))

	var floor_contrib: float = charge_min_per_sec * delta
	var inc: float = lateral_contrib + yaw_contrib + floor_contrib
	drift_accum_charge += inc
	charge += inc

	while charge >= charge_nitro_full and nitro_stock < max_nitro_stock:
		charge -= charge_nitro_full
		nitro_stock += 1
		emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
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
	var now: float = Time.get_ticks_msec() / 1000.0

	# 情况 A：在漂移中 → 要求累计角度足够才能退漂小喷
	if state == State.DRIFT:
		if drift_accum_angle_deg < drift_min_angle_to_boost:
			print("[Car] 小喷失败: 角度不够 ", drift_accum_angle_deg, " < ", drift_min_angle_to_boost)
			emit_signal("boost_triggered", "insufficient")
			return
		if charge < mini_boost_cost:
			print("[Car] 小喷失败: 集气不够 ", charge, " < ", mini_boost_cost)
			emit_signal("boost_triggered", "insufficient")
			return
		charge -= mini_boost_cost
		_end_drift(true)
		_start_boost("mini", mini_boost_power, mini_boost_time)
		print("[Car] 小喷触发!")
		return

	# 情况 B：正在喷射中 → 小喷尾巴接双喷(QQ飞车经典连喷)
	if is_boosting and boost_type == "mini" and charge >= mini_boost_cost:
		charge -= mini_boost_cost
		_start_boost("double", double_boost_power, double_boost_time)
		print("[Car] 双喷触发 (小喷中接续)!")
		return

	# 情况 C：小喷刚结束的窗口内 → 双喷
	if now - last_mini_end_time <= double_boost_window and charge >= mini_boost_cost:
		charge -= mini_boost_cost
		_start_boost("double", double_boost_power, double_boost_time)
		print("[Car] 双喷触发 (窗口内)!")
		return

	# 其它情况 (非漂移、非喷射、窗口外): 如果集气够也能直接小喷
	if charge >= mini_boost_cost:
		charge -= mini_boost_cost
		_start_boost("mini", mini_boost_power, mini_boost_time)
		print("[Car] 普通小喷 (静态集气触发)")


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

	var shake := {"mini": 0.3, "double": 0.55, "nitro": 0.85}
	emit_signal("camera_shake_requested", shake.get(type_name, 0.3), duration)

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
#  HUD 信号
# ============================================================
func _emit_hud_signals() -> void:
	var kmh: float = linear_velocity.length() * 3.6
	emit_signal("speed_changed", kmh)
	emit_signal("charge_changed", charge, charge_nitro_full)
