extends Node3D
class_name FreeGrapple
## ============================================================
##  自由钩索 (Free Grapple)
##
##  与原 GrappleHook 完全独立、互斥. 开启自由钩索后原钩索不生效.
##
##  状态机:
##    IDLE      → 空闲, 有充能时按空格触发
##    PULLING   → 绳索收缩中, 持续把车拉向锚点 (绳子可见)
##    FALLING   → 绳断甩出后, 空中可调整车头朝向, 可按空格发射
##    LAUNCHING → 发射加速中 (沿车头方向冲刺)
##    WALL_HIT  → 撞墙中断
##
##  流程:
##    空格 → 射出钩索抓住前方虚拟锚点 → 绳索收缩拉车 → 靠近锚点
##    → 绳断, 沿速度方向甩出 → 空中调整车头 → 按空格沿车头发射
##
##  充能系统:
##    · 最多 N 层充能 (max_charges), 每次使用氮气获得 1 层
##    · 每次触发消耗 1 层
##
##  按键:
##    · 空格 (IDLE + 有充能): 射出钩索
##    · 空格 (FALLING): 沿车头方向发射
## ============================================================

# ============ 状态枚举 ============
enum State { IDLE, PULLING, FALLING, LAUNCHING, WALL_HIT }
var state: int = State.IDLE

# ============ 节点引用 ============
@export var car_path: NodePath
var car: RigidBody3D = null
var car_mesh: Node3D = null

# ============ 参数 ============

@export_group("开关")
## 自由钩索总开关
@export var free_grapple_enabled: bool = true

## ==================== 直线钩索 ====================
@export_group("直线-锚点")
## 锚点基础偏移: X=右, Y=上, Z=前方基础距离
@export var anchor_offset: Vector3 = Vector3(0.0, 5.0, 15.0)
## 前方距离随水平速度增加的系数
@export_range(0.0, 3.0, 0.05) var anchor_speed_scale: float = 0.8
## 高度随水平速度增加的系数
@export_range(0.0, 1.0, 0.02) var anchor_height_speed_scale: float = 0.15
## 高度随向上速度增加的系数
@export_range(0.0, 2.0, 0.05) var anchor_height_upspeed_scale: float = 0.5

@export_group("直线-收绳")
## 射出动画时长 (秒)
@export_range(0.2, 2.0, 0.02) var rope_taut_delay: float = 0.5
## 收绳速度 (米/秒)
@export_range(5.0, 80.0, 1.0) var reel_speed: float = 35.0
## 朝锚点拉力 (N × mass)
@export_range(30.0, 500.0, 5.0) var pull_force: float = 180.0
## 收绳最大时长 (秒)
@export_range(0.5, 5.0, 0.1) var pull_max_time: float = 2.5
## 直线断绳夹角 (度): 绳子与锚点正下方垂线的夹角
## 车经过锚点正下方时 θ=0°, 被拉起后 θ 增大
## 90° = 车升到与锚点同高(锚点正前方), 断绳!
@export_range(30.0, 150.0, 5.0) var break_angle_deg: float = 90.0
## 重力抵消比例
@export_range(0.0, 1.0, 0.05) var pull_gravity_cancel: float = 0.8

@export_group("直线-甩出")
## 甩出速度倍率
@export_range(1.0, 3.0, 0.05) var fling_speed_mult: float = 1.2
## 甩出保底速度 (m/s)
@export_range(5.0, 40.0, 1.0) var fling_min_speed: float = 18.0

@export_group("直线-空中")
## 空中转向速度 (rad/s)
@export_range(0.5, 8.0, 0.1) var air_turn_speed: float = 2.5
## 漂移键转向倍率
@export_range(1.0, 5.0, 0.1) var air_drift_turn_mult: float = 2.0
## 空中重力倍率
@export_range(0.1, 5.0, 0.05) var fall_gravity_mult: float = 0.5
## 空中阻力
@export_range(0.0, 2.0, 0.02) var air_drag: float = 0.3

@export_group("直线-发射")
## 发射速度 (m/s)
@export_range(10.0, 80.0, 1.0) var launch_speed: float = 35.0
## 发射后无重力时间 (秒)
@export_range(0.0, 1.5, 0.05) var launch_float_time: float = 0.4
## 发射持续时间 (秒)
@export_range(0.1, 2.0, 0.05) var launch_duration: float = 0.5
## 发射后重力倍率
@export_range(1.0, 5.0, 0.1) var post_launch_gravity_mult: float = 2.5

## ==================== 过弯钩索 ====================
@export_group("过弯-锚点")
## 锚点定位模式: 0=车头方向, 1=速度方向
## 车头方向: 锚点基于 car_mesh 的 -basis.z (车头朝向) 计算
## 速度方向: 锚点基于 car.linear_velocity 的水平分量方向计算
@export_range(0, 1, 1) var swing_anchor_mode: int = 0

## ---------- 方案1: 车头方向锚点参数 ----------
## 车头方向锚点偏移: X=侧向微偏, Y=高度, Z=车头前方基础距离
@export var swing_anchor_offset: Vector3 = Vector3(2.0, 8.0, 18.0)
## 前方距离随水平速度系数
@export_range(0.0, 3.0, 0.05) var swing_anchor_speed_scale: float = 0.8
## 高度随水平速度系数
@export_range(0.0, 1.0, 0.02) var swing_anchor_height_speed_scale: float = 0.1
## 高度随向上速度系数
@export_range(0.0, 2.0, 0.05) var swing_anchor_height_upspeed_scale: float = 0.3

## ---------- 方案2: 速度方向锚点参数 ----------
## 速度方向锚点偏移: X=侧向微偏, Y=高度, Z=速度方向前方基础距离
@export var swing_vel_anchor_offset: Vector3 = Vector3(2.0, 8.0, 18.0)
## 前方距离随水平速度系数
@export_range(0.0, 3.0, 0.05) var swing_vel_anchor_speed_scale: float = 0.8
## 高度随水平速度系数
@export_range(0.0, 1.0, 0.02) var swing_vel_anchor_height_speed_scale: float = 0.1
## 高度随向上速度系数
@export_range(0.0, 2.0, 0.05) var swing_vel_anchor_height_upspeed_scale: float = 0.3

## ---------- 通用偏转 ----------
## 漂移基础偏转角度 (度)
@export_range(0.0, 90.0, 1.0) var drift_base_yaw_deg: float = 30.0
## 方向键额外偏转角度 (度)
@export_range(0.0, 90.0, 1.0) var steer_extra_yaw_deg: float = 45.0

@export_group("过弯-收绳")
## 过弯钩索挂住后是否无视墙体碰撞 (穿墙). 让漂移过弯时绳子拉着车穿过弯道内墙
@export var swing_ignore_wall: bool = true
## 过弯射出动画时长 (秒)
@export_range(0.1, 1.5, 0.02) var swing_rope_taut_delay: float = 0.3
## 过弯收绳速度 (米/秒)
@export_range(5.0, 80.0, 1.0) var swing_reel_speed: float = 20.0
## 过弯拉力 (N × mass)
@export_range(30.0, 500.0, 5.0) var swing_pull_force: float = 220.0
## 过弯收绳最大时长 (秒)
@export_range(0.3, 3.0, 0.05) var swing_duration: float = 1.2
## 过弯断绳累计角度 (度): 车绕锚点扫过的累计角度超过此值就断绳
## 90° = 过了一个直角弯, 120° = 过了大约1/3圈
@export_range(30.0, 360.0, 5.0) var swing_break_swept_deg: float = 90.0
## 过弯重力抵消
@export_range(0.0, 1.0, 0.05) var swing_gravity_cancel: float = 0.9
## 松手断绳
@export var release_on_steer_up: bool = true
## 松手容错 (秒)
@export_range(0.0, 0.3, 0.02) var steer_release_grace: float = 0.08
## 扭矩修正强度 (rad/s²)
@export_range(0.0, 15.0, 0.5) var swing_torque: float = 6.0

@export_group("过弯-甩出")
## 过弯甩出速度倍率
@export_range(1.0, 3.0, 0.05) var swing_fling_speed_mult: float = 1.1
## 过弯甩出保底速度 (m/s)
@export_range(5.0, 40.0, 1.0) var swing_fling_min_speed: float = 15.0

@export_group("过弯-空中")
## 过弯后空中转向速度
@export_range(0.5, 8.0, 0.1) var swing_air_turn_speed: float = 3.0
## 过弯后漂移键转向倍率
@export_range(1.0, 5.0, 0.1) var swing_air_drift_turn_mult: float = 2.5
## 过弯后空中重力倍率
@export_range(0.1, 5.0, 0.05) var swing_fall_gravity_mult: float = 1.0
## 过弯后空中阻力
@export_range(0.0, 2.0, 0.02) var swing_air_drag: float = 0.2

@export_group("过弯-发射")
## 过弯后发射速度 (m/s)
@export_range(10.0, 80.0, 1.0) var swing_launch_speed: float = 30.0
## 过弯后发射无重力时间
@export_range(0.0, 1.5, 0.05) var swing_launch_float_time: float = 0.3
## 过弯后发射持续时间
@export_range(0.1, 2.0, 0.05) var swing_launch_duration: float = 0.4

## ==================== 通用 ====================
@export_group("通用")
## 碰撞豁免时间 (秒)
@export_range(0.0, 2.0, 0.05) var collision_exempt_time: float = 0.3

@export_group("镜头效果")
## 发射时震屏强度 (0=无震屏)
@export_range(0.0, 3.0, 0.1) var launch_shake_intensity: float = 1.2
## 发射时震屏时长 (秒)
@export_range(0.0, 0.8, 0.05) var launch_shake_duration: float = 0.3
## 发射时 FOV 增量 (度). 产生冲击加速感
@export_range(0.0, 30.0, 0.5) var launch_fov_boost: float = 12.0
## 甩出时震屏强度
@export_range(0.0, 3.0, 0.1) var fling_shake_intensity: float = 0.6
## 甩出时 FOV 增量
@export_range(0.0, 20.0, 0.5) var fling_fov_boost: float = 6.0

@export_group("充能")
## 最大充能层数
@export_range(1, 5, 1) var max_charges: int = 3
## 每次使用氮气获得的充能层数
@export_range(1, 3, 1) var charge_per_nitro: int = 1
## 充能冷却时间 (秒)
@export_range(0.0, 5.0, 0.1) var charge_cooldown: float = 1.0

@export_group("视觉")
## 钩索线颜色
@export var rope_color: Color = Color(0.9, 0.75, 0.2, 1.0)
## 钩索线粗细 (米)
@export_range(0.02, 0.3, 0.01) var fg_rope_thickness: float = 0.12

@export_group("绳索物理")
## 绳子节点数
@export_range(8, 48, 1) var fg_rope_node_count: int = 16
## Verlet 距离约束迭代次数
@export_range(1, 30, 1) var fg_rope_constraint_iters: int = 20
## 绳子受到的重力 (仅视觉)
@export_range(0.0, 80.0, 0.5) var fg_rope_gravity: float = 10.0
## 空气阻力/阻尼
@export_range(0.0, 0.5, 0.005) var fg_rope_damping: float = 0.08

# ============ 运行时状态 ============
var _charges: int = 0
var _charge_cooldown_left: float = 0.0
var _state_timer: float = 0.0
var _anchor_world_pos: Vector3 = Vector3.ZERO
var _initial_rope_length: float = 30.0
var _current_rope_length: float = 30.0  ## 当前允许的最大绳长 (每帧缩短)
var _exempt_timer: float = 0.0
var _launch_timer: float = 0.0
var _wall_hit: bool = false
var _has_launched: bool = false  ## 本次飞行是否已发射过
var _swing_dir: float = 0.0     ## 本次钩索的偏转方向 (-1=左, 0=直线, 1=右)
var _is_swing_hook: bool = false ## 本次是否是过弯钩索 (有偏转)
var _steer_release_timer: float = 0.0  ## 松开方向键的计时器

# --- 直线钩索: 垂线夹角断绳 ---
var _passed_below_anchor: bool = false   ## 车是否已经过锚点正下方
var _straight_prev_angle: float = 999.0  ## 历史最小垂线夹角 (用于检测θ开始回升)
var _straight_base_angle: float = 0.0    ## 经过正下方时的θ (断绳 = base + break_angle_deg)

# --- 过弯钩索: 累计扫过角度断绳 ---
# 抓住瞬间 "锚点→车" 的水平方向 (起始方向)
var _swing_prev_dir: Vector3 = Vector3.FORWARD
# 累计扫过角度 (弧度)
var _swing_swept_angle: float = 0.0
var _hook_drift_broken: bool = false   ## 钩索挂住时是否已断漂
var _original_collision_mask: int = 0
var _original_collision_layer: int = 0

# 视觉
var _rope_mat: StandardMaterial3D = null
var _rope_segments: Array[MeshInstance3D] = []
var _verlet_pos: PackedVector3Array = PackedVector3Array()
var _verlet_old: PackedVector3Array = PackedVector3Array()
var _verlet_rest_len: float = 1.0
var _verlet_inited: bool = false

# 信号
signal state_changed(new_state: int)
signal charges_changed(current: int, max_val: int)
signal launch_ready(ready: bool)


func _ready() -> void:
	call_deferred("_deferred_init")


func _deferred_init() -> void:
	if not car_path.is_empty() and has_node(car_path):
		car = get_node(car_path) as RigidBody3D
	if car == null:
		var p: Node = get_parent()
		if p is RigidBody3D:
			car = p as RigidBody3D
	if car:
		car_mesh = car.get_node_or_null("CarMesh")
		_original_collision_layer = car.collision_layer
		_original_collision_mask = car.collision_mask
		if car.has_signal("boost_triggered"):
			car.connect("boost_triggered", _on_boost_triggered)
	_build_rope_visual()
	_charges = max_charges
	emit_signal("charges_changed", _charges, max_charges)
	print("[FreeGrapple] 初始化完成: car=%s, enabled=%s, charges=%d" % [str(car != null), str(free_grapple_enabled), _charges])


func _physics_process(delta: float) -> void:
	if not free_grapple_enabled or car == null:
		return

	if _charge_cooldown_left > 0.0:
		_charge_cooldown_left -= delta

	# FOV 冲击衰减
	if cam_fov_boost > 0.01:
		cam_fov_boost = maxf(cam_fov_boost - _fov_decay_speed * delta, 0.0)

	_update_collision_exempt(delta)

	match state:
		State.IDLE:
			pass
		State.PULLING:
			_update_pulling(delta)
		State.FALLING:
			_update_falling(delta)
		State.LAUNCHING:
			_update_launching(delta)
		State.WALL_HIT:
			_update_wall_hit(delta)

	_update_rope_visual()


# ============================================================
#  PULLING: 绳索收缩, 把车拉向锚点
# ============================================================

func _update_pulling(delta: float) -> void:
	_state_timer += delta

	var to_anchor: Vector3 = _anchor_world_pos - car.global_position
	var dist: float = to_anchor.length()
	if dist < 0.01:
		_fling_release()
		return

	# 1. 超时 → 强制断绳甩出 (过弯钩索有独立时长)
	var max_time: float = swing_duration if _is_swing_hook else pull_max_time
	if _state_timer >= max_time:
		_fling_release()
		return

	# 2. 绳子射出延迟 (直线/过弯各自独立)
	var cur_taut_delay: float = swing_rope_taut_delay if _is_swing_hook else rope_taut_delay
	if _state_timer < cur_taut_delay:
		return

	# 2.5 钩索挂住的第一帧: 重新计算锚点 + 设 _free_grapple_active + 强制断漂 + 过弯穿墙
	if not _hook_drift_broken:
		_hook_drift_broken = true
		# ====== 关键: 锚点在此刻(抓住瞬间)重新确定 ======
		# 射出阶段的锚点只是绳头飞行的视觉目标,
		# 真正的锚点坐标以抓住瞬间的车头位置/速度为准
		_compute_anchor_position()
		_initial_rope_length = car.global_position.distance_to(_anchor_world_pos)
		_current_rope_length = _initial_rope_length

		# --- 初始化断绳判定数据 ---
		if _is_swing_hook:
			# 过弯钩索: 记录 "锚点→车" 水平方向作为起始, 累计角度归零
			var radial: Vector3 = car.global_position - _anchor_world_pos
			radial.y = 0.0
			if radial.length() > 0.01:
				_swing_prev_dir = radial.normalized()
			else:
				_swing_prev_dir = Vector3.FORWARD
			_swing_swept_angle = 0.0
		else:
			# 直线钩索: 初始化 "经过正下方" 检测
			_passed_below_anchor = false
			_straight_prev_angle = 999.0  # 初始极大值, 第一帧一定会更新
			_straight_base_angle = 0.0
		# 现在才设 flag (射出阶段不设, 保留正常摩擦让漂移维持到此刻)
		if car and "_free_grapple_active" in car:
			car.set("_free_grapple_active", true)
		# 过弯钩索: 挂住后无视墙体碰撞 (穿墙荡弯)
		if _is_swing_hook and swing_ignore_wall:
			_disable_wall_collision()
		if car and "state" in car:
			var car_state_now: int = int(car.get("state"))
			if car_state_now == 1:  # State.DRIFT
				car.set("state", 0)  # State.NORMAL
				if "drift_dir" in car:
					car.set("drift_dir", 0.0)
				if "drift_intensity" in car:
					car.set("drift_intensity", 0.0)
				if "_is_in_songqian" in car:
					car.set("_is_in_songqian", false)
				# 要求松开Q才能重新入漂 (防止落地后自动续漂)
				if "_require_release_q" in car:
					car.set("_require_release_q", true)
				if "_drift_system" in car and car.get("_drift_system") != null:
					var ds = car.get("_drift_system")
					if ds.has_method("end_drift"):
						ds.call("end_drift", false)

	# 3. 过弯钩索: 松开方向键 → 断绳甩出 (让玩家控制荡多久)
	if _is_swing_hook and release_on_steer_up:
		var steer_now: float = Input.get_axis("steer_right", "steer_left")
		if absf(steer_now) < 0.05:
			steer_now = Input.get_axis("ui_right", "ui_left")
		var holding_swing_dir: bool = (steer_now * _swing_dir) > 0.1
		if not holding_swing_dir:
			_steer_release_timer += delta
			if _steer_release_timer >= steer_release_grace:
				_fling_release()
				return
		else:
			_steer_release_timer = 0.0

	# 4. 收绳: 每帧缩短允许绳长
	var cur_reel: float = swing_reel_speed if _is_swing_hook else reel_speed
	_current_rope_length -= cur_reel * delta
	_current_rope_length = maxf(_current_rope_length, 0.0)

	# 5. 断绳条件 (直线和过弯完全不同的判定方式)
	if _is_swing_hook:
		# ---- 过弯钩索: 累计扫过角度断绳 ----
		# 每帧计算 "锚点→车" 水平方向的增量角度, 累加到 _swing_swept_angle
		var radial_now: Vector3 = car.global_position - _anchor_world_pos
		radial_now.y = 0.0
		if radial_now.length() > 0.01:
			var dir_now: Vector3 = radial_now.normalized()
			# 用 atan2 求增量角 (带符号, 但我们只关心绝对值累计)
			var cross_y: float = _swing_prev_dir.x * dir_now.z - _swing_prev_dir.z * dir_now.x
			var dot_val: float = _swing_prev_dir.dot(dir_now)
			var delta_angle: float = absf(atan2(cross_y, dot_val))
			# 过滤掉过大的突变 (可能是瞬移/穿墙导致, 超过 30°/帧 不合理)
			if delta_angle < deg_to_rad(30.0):
				_swing_swept_angle += delta_angle
			_swing_prev_dir = dir_now

		if _swing_swept_angle >= deg_to_rad(swing_break_swept_deg):
			print("[FreeGrapple] 过弯断绳! 累计扫过角度=%.1f° (阈值=%.1f°)" % [rad_to_deg(_swing_swept_angle), swing_break_swept_deg])
			_fling_release()
			return
	else:
		# ---- 直线钩索: 垂线夹角断绳 ----
		# 车先飞向锚点, 经过锚点正下方 (θ 达到最小值然后回升),
		# 之后被绳子向上拉起, θ 不断增大.
		#
		# 几何:
		#   θ = Vector3.DOWN 与 (锚点→车) 的夹角
		#   θ=0°  : 车在锚点正下方
		#   θ=90° : 车升到与锚点同高
		#   θ>90° : 车飞到锚点上方
		#
		# 关键: 只有车 **经过正下方之后** 才开始判定断绳!
		# 断绳条件: θ ≥ _straight_base_angle + break_angle_deg
		#   即从"过正下方时的角度"再被拉起 break_angle_deg 度才断
		#   这样无论车水平速度多大, 都需要真正被绳子拉起足够角度
		var anchor_to_car: Vector3 = car.global_position - _anchor_world_pos
		if anchor_to_car.length() > 0.01:
			var dir_to_car: Vector3 = anchor_to_car.normalized()
			var angle_rad: float = Vector3.DOWN.angle_to(dir_to_car)
			var angle_deg: float = rad_to_deg(angle_rad)

			if not _passed_below_anchor:
				# 还没经过正下方: 检测 θ 是否开始回升 (过了最低点)
				if angle_deg > _straight_prev_angle + 0.5:
					# θ 开始增大了 → 已经过了正下方最低点
					_passed_below_anchor = true
					_straight_base_angle = _straight_prev_angle
					print("[FreeGrapple] 直线: 已过锚点正下方! base_θ=%.1f°, 断绳阈值=%.1f°+%.1f°=%.1f°" % [_straight_base_angle, _straight_base_angle, break_angle_deg, _straight_base_angle + break_angle_deg])
				_straight_prev_angle = minf(angle_deg, _straight_prev_angle)
			else:
				# 已经过正下方: θ 需要从 base 再增大 break_angle_deg 度才断绳
				var threshold_deg: float = _straight_base_angle + break_angle_deg
				if angle_deg >= threshold_deg:
					print("[FreeGrapple] 直线断绳! 垂线夹角=%.1f° (base=%.1f° + 阈值%.1f° = %.1f°)" % [angle_deg, _straight_base_angle, break_angle_deg, threshold_deg])
					_fling_release()
					return

	# 5. 绳索约束: 车超出当前允许绳长时, 去掉远离锚点的速度分量 + 施加拉力
	var pull_dir: Vector3 = to_anchor.normalized()
	# 安全: 拉力方向不允许朝下 (防止把车压进地面)
	if pull_dir.y < 0.0:
		pull_dir.y = 0.0
		if pull_dir.length_squared() > 0.001:
			pull_dir = pull_dir.normalized()
		else:
			pull_dir = Vector3.UP

	var cur_pull_force: float = swing_pull_force if _is_swing_hook else pull_force
	var cur_gravity_cancel: float = swing_gravity_cancel if _is_swing_hook else pull_gravity_cancel

	if dist > _current_rope_length:
		var vel: Vector3 = car.linear_velocity
		var radial_speed: float = vel.dot(pull_dir)
		if radial_speed < 0.0:
			var new_vel: Vector3 = vel - pull_dir * radial_speed
			if new_vel.y < 0.0 and vel.y >= 0.0:
				new_vel.y = 0.0
			car.linear_velocity = new_vel
		var overshoot: float = dist - _current_rope_length
		var constraint_force: float = cur_pull_force * clampf(overshoot / 5.0, 0.2, 1.5)
		car.apply_central_force(pull_dir * constraint_force * car.mass)
	else:
		car.apply_central_force(pull_dir * cur_pull_force * 0.5 * car.mass)

	# 6. 重力抵消
	# 过弯钩索: 完全抵消重力 (1.0), 不允许残余重力把车压进地面
	# 直线钩索: 按 pull_gravity_cancel 比例抵消 (默认 0.8)
	var effective_gravity_cancel: float = 1.0 if _is_swing_hook else cur_gravity_cancel
	car.apply_central_force(Vector3.UP * 9.8 * car.mass * effective_gravity_cancel)

	# 7. 过弯扭矩修正: 让车头朝钩索切线方向转 (绕锚点荡时车头跟着转)
	if _is_swing_hook and swing_torque > 0.01 and car_mesh:
		# 切线方向 = 锚点到车的向量 × UP (垂直于绳子的水平方向)
		var radial: Vector3 = (car.global_position - _anchor_world_pos)
		radial.y = 0.0
		if radial.length() > 0.1:
			# 切线 = radial 旋转90° (根据 swing_dir 决定方向)
			var tangent: Vector3 = Vector3(-radial.z, 0.0, radial.x).normalized() * _swing_dir
			# 当前车头方向
			var car_fwd: Vector3 = -car_mesh.global_transform.basis.z
			car_fwd.y = 0.0
			car_fwd = car_fwd.normalized()
			# 计算车头与切线方向的偏差角 (有符号)
			var cross_y: float = car_fwd.x * tangent.z - car_fwd.z * tangent.x
			# 施加扭矩让车头朝切线方向转
			car_mesh.rotate_y(swing_torque * cross_y * delta)

	# 8. 地面防陷保护 (仅过弯钩索! 直线钩索需要车飞离地面, 不能阻止)
	# 用短距射线探测地面, 如果车太贴地或陷入地面则强制抬起
	# 球体半径 = 1.5 (与 car.gd 一致)
	if _is_swing_hook:
		const SWING_SPHERE_RADIUS: float = 1.5
		var ground_protect_ray_len: float = SWING_SPHERE_RADIUS + 1.5  # 探 3m 够了
		var space: PhysicsDirectSpaceState3D = car.get_world_3d().direct_space_state
		if space:
			var ray_from: Vector3 = car.global_position
			var ray_to: Vector3 = ray_from + Vector3.DOWN * ground_protect_ray_len
			var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
			query.collision_mask = _original_collision_mask
			query.exclude = [car.get_rid()]
			var result: Dictionary = space.intersect_ray(query)
			if result.size() > 0:
				var hit_pos: Vector3 = result["position"]
				var hit_normal: Vector3 = result["normal"]
				# 车球心沿法线方向到地面的距离
				var dist_to_ground: float = (ray_from - hit_pos).dot(hit_normal)
				# 如果球心距地面 < 球半径 (即球体陷入/刚好接触地面)
				var min_clearance: float = SWING_SPHERE_RADIUS + 0.05  # 留 5cm 余量
				if dist_to_ground < min_clearance:
					# 强制把车抬到安全高度
					var correction: float = min_clearance - dist_to_ground
					car.global_position += hit_normal * correction
					# 清除向下速度分量 (沿法线方向)
					var v: Vector3 = car.linear_velocity
					var v_along_n: float = v.dot(hit_normal)
					if v_along_n < 0.0:
						car.linear_velocity = v - hit_normal * v_along_n

	# 9. 撞墙检测 (过弯穿墙时跳过, 因为车已经可以穿过墙体)
	if not (_is_swing_hook and swing_ignore_wall):
		if _exempt_timer <= 0.0 and _detect_wall_collision():
			_enter_state(State.WALL_HIT)


# ============================================================
#  FALLING: 空中自由调整车头朝向, 可按空格发射
# ============================================================

func _update_falling(delta: float) -> void:
	_state_timer += delta

	# 使用对应参数集 (直线 vs 过弯)
	var cur_grav: float = swing_fall_gravity_mult if _is_swing_hook else fall_gravity_mult
	var cur_drag: float = swing_air_drag if _is_swing_hook else air_drag
	var cur_turn: float = swing_air_turn_speed if _is_swing_hook else air_turn_speed
	var cur_drift_mult: float = swing_air_drift_turn_mult if _is_swing_hook else air_drift_turn_mult

	# 重力
	var gravity_adjust: float = (1.0 - cur_grav) * 9.8 * car.mass
	car.apply_central_force(Vector3.UP * gravity_adjust)

	# 空气阻力
	if cur_drag > 0.001:
		var vel: Vector3 = car.linear_velocity
		var speed: float = vel.length()
		if speed > 1.0:
			car.apply_central_force(-vel.normalized() * speed * cur_drag * car.mass)

	# 空中转向: 只有未发射时可以调整车头
	if not _has_launched:
		var steer_input: float = Input.get_axis("steer_right", "steer_left")
		if absf(steer_input) < 0.05:
			steer_input = Input.get_axis("ui_right", "ui_left")
		var drift_held: bool = Input.is_action_pressed("drift")
		var turn_mult: float = cur_drift_mult if drift_held else 1.0
		if car_mesh and absf(steer_input) > 0.1:
			car_mesh.rotate_y(cur_turn * turn_mult * steer_input * delta)

	# 着地检测 (前 0.3s 不检测)
	if _state_timer > 0.3 and _is_on_ground():
		_enter_state(State.IDLE)

	# 撞墙检测
	if _detect_wall_collision():
		_enter_state(State.WALL_HIT)


# ============================================================
#  LAUNCHING: 发射加速中
# ============================================================

func _update_launching(delta: float) -> void:
	_launch_timer += delta

	var cur_float_time: float = swing_launch_float_time if _is_swing_hook else launch_float_time
	var cur_duration: float = swing_launch_duration if _is_swing_hook else launch_duration

	# 发射期间减弱重力
	if _launch_timer < cur_float_time:
		var gravity_cancel: float = 9.8 * car.mass * 0.9
		car.apply_central_force(Vector3.UP * gravity_cancel)

	# 发射结束 → 自由落体
	if _launch_timer >= cur_duration:
		_enter_state(State.FALLING)

	# 着地检测
	if _is_on_ground():
		_enter_state(State.IDLE)

	# 撞墙检测
	if _detect_wall_collision():
		_enter_state(State.WALL_HIT)


func _update_wall_hit(_delta: float) -> void:
	_wall_hit = true
	_restore_collision()
	_enter_state(State.IDLE)


# ============================================================
#  状态切换
# ============================================================

func _enter_state(new_state: int) -> void:
	# 退出旧状态
	match state:
		State.FALLING:
			emit_signal("launch_ready", false)

	state = new_state
	_state_timer = 0.0

	match new_state:
		State.IDLE:
			_restore_collision()
			_hide_rope()
			_wall_hit = false
			_has_launched = false
			if car and "_free_grapple_active" in car:
				car.set("_free_grapple_active", false)
			# 恢复防弹下压力
			if car and "_jump_pad_kick_left" in car:
				car.set("_jump_pad_kick_left", 0.0)
		State.PULLING:
			pass  # flag 在挂住施力时设 (不在进入 PULLING 时设, 保留射出阶段的正常摩擦)
		State.FALLING:
			if car and "_free_grapple_active" in car:
				car.set("_free_grapple_active", true)
			if not _has_launched:
				emit_signal("launch_ready", true)
		State.LAUNCHING:
			if car and "_free_grapple_active" in car:
				car.set("_free_grapple_active", true)
			emit_signal("launch_ready", false)
		State.WALL_HIT:
			pass

	emit_signal("state_changed", new_state)


# ============================================================
#  触发动作
# ============================================================

## 按空格 (IDLE 或 弹射后FALLING): 射出钩索. 支持空中接续
func _trigger_pull() -> void:
	if _charges <= 0:
		return
	_charges -= 1
	emit_signal("charges_changed", _charges, max_charges)

	# 注意: 不在射出阶段设 _free_grapple_active (否则摩擦降低会导致提前断漂)
	# 改在钩索挂住施力时 (_hook_drift_broken 那里) 才设 flag

	_has_launched = false
	_steer_release_timer = 0.0
	_hook_drift_broken = false

	# 判断是否过弯钩索: 正在漂移时触发 = 过弯钩索
	var drift_d: float = 0.0
	if car and "drift_dir" in car and "state" in car:
		var car_state: int = int(car.get("state"))
		if car_state == 1:  # State.DRIFT
			drift_d = float(car.get("drift_dir"))

	_is_swing_hook = absf(drift_d) > 0.1
	_swing_dir = drift_d  # 记录漂移方向 (用于松手断绳检测和扭矩修正)

	# ====== 锚点坐标不在此处确定! ======
	# 锚点实际坐标在钩索抓住的瞬间 (_hook_drift_broken 那帧) 才计算
	# 射出阶段只给一个临时的视觉目标 (绳头飞向的方向)
	_compute_anchor_position()  # 临时锚点, 用于绳头飞行视觉

	_initial_rope_length = car.global_position.distance_to(_anchor_world_pos)
	_current_rope_length = _initial_rope_length

	# 不禁用碰撞 (保留地面碰撞, 防止陷地)
	_exempt_timer = 0.0

	# 免疫防弹下压力: 设一个长的 kick 窗口跳过 _apply_ground_stick
	# 整个钩索期间 (射出+收绳) 都不受防弹下压影响
	if car and "_jump_pad_kick_left" in car:
		car.set("_jump_pad_kick_left", 99.0)  # 足够长, 钩索结束时会清掉

	# 清除向下速度分量 (确保不会被重力压着跑不动)
	var cur_vel: Vector3 = car.linear_velocity
	cur_vel.y = maxf(cur_vel.y, 0.0)
	car.linear_velocity = cur_vel

	_enter_state(State.PULLING)
	_show_rope()
	var mode_str: String = "直线"
	if _is_swing_hook:
		mode_str = "过弯(车头)" if swing_anchor_mode == 0 else "过弯(速度)"
	print("[FreeGrapple] 射出钩索! 模式=%s, 临时锚点=%s, 绳长=%.1f" % [mode_str, str(_anchor_world_pos), _initial_rope_length])


## 计算锚点位置 (直线/过弯; 过弯支持 车头方向/速度方向 两种模式)
func _compute_anchor_position() -> void:
	var vel: Vector3 = car.linear_velocity
	var horizontal_speed: float = Vector2(vel.x, vel.z).length()
	var upward_speed: float = maxf(vel.y, 0.0)

	if _is_swing_hook:
		if swing_anchor_mode == 1:
			# ---- 方案2: 速度方向决定锚点位置 ----
			# 前方方向 = 水平速度方向 (而非车头朝向)
			var vel_h: Vector3 = Vector3(vel.x, 0.0, vel.z)
			var vel_forward: Vector3
			if vel_h.length() > 0.5:
				vel_forward = vel_h.normalized()
			elif car_mesh:
				# 速度太小时回退到车头方向
				vel_forward = -car_mesh.global_transform.basis.z
				vel_forward.y = 0.0
				vel_forward = vel_forward.normalized()
			else:
				vel_forward = Vector3.FORWARD

			var vel_right: Vector3 = vel_forward.cross(Vector3.UP).normalized()

			var fwd_dist: float = swing_vel_anchor_offset.z + horizontal_speed * swing_vel_anchor_speed_scale
			var height: float = swing_vel_anchor_offset.y + horizontal_speed * swing_vel_anchor_height_speed_scale + upward_speed * swing_vel_anchor_height_upspeed_scale
			var side_offset: float = swing_vel_anchor_offset.x

			var origin: Vector3 = car.global_position
			if car_mesh:
				origin = car_mesh.global_position
			_anchor_world_pos = origin \
				+ vel_forward * fwd_dist \
				+ vel_right * (_swing_dir * side_offset) \
				+ Vector3.UP * height
		else:
			# ---- 方案1: 车头方向决定锚点位置 (原逻辑) ----
			var fwd_dist: float = swing_anchor_offset.z + horizontal_speed * swing_anchor_speed_scale
			var height: float = swing_anchor_offset.y + horizontal_speed * swing_anchor_height_speed_scale + upward_speed * swing_anchor_height_upspeed_scale
			var side_offset: float = swing_anchor_offset.x

			if car_mesh:
				var origin: Vector3 = car_mesh.global_position
				var basis: Basis = car_mesh.global_transform.basis
				var forward: Vector3 = -basis.z
				var right: Vector3 = basis.x
				_anchor_world_pos = origin \
					+ forward * fwd_dist \
					+ right * (-_swing_dir * side_offset) \
					+ Vector3.UP * height
			else:
				_anchor_world_pos = car.global_position + Vector3(-_swing_dir * side_offset, height, -fwd_dist)
	else:
		# 直线钩索: 锚点在车头正前方
		var forward_dist: float = anchor_offset.z + horizontal_speed * anchor_speed_scale
		var height: float = anchor_offset.y + horizontal_speed * anchor_height_speed_scale + upward_speed * anchor_height_upspeed_scale

		if car_mesh:
			var origin: Vector3 = car_mesh.global_position
			var basis: Basis = car_mesh.global_transform.basis
			var forward: Vector3 = -basis.z
			var right: Vector3 = basis.x
			_anchor_world_pos = origin \
				+ forward * forward_dist \
				+ right * anchor_offset.x \
				+ Vector3.UP * height
		else:
			_anchor_world_pos = car.global_position + Vector3(0, height, -forward_dist)


## 绳断甩出: 靠近锚点/超时 → 绳断, 沿当前速度甩出
func _fling_release() -> void:
	_hide_rope()
	# 恢复碰撞 (过弯穿墙时在挂住阶段禁用了碰撞)
	# 如果车正嵌在墙里, 延迟恢复碰撞 (等车飞出去后再恢复, 避免被弹飞)
	if _is_swing_hook and swing_ignore_wall:
		if _is_inside_wall():
			_exempt_timer = collision_exempt_time
		else:
			_restore_collision()
	else:
		_restore_collision()

	var vel: Vector3 = car.linear_velocity
	var speed: float = vel.length()
	var fling_dir: Vector3
	if speed > 1.0:
		fling_dir = vel.normalized()
	elif car_mesh:
		fling_dir = -car_mesh.global_transform.basis.z
	else:
		fling_dir = Vector3.FORWARD
	# 不让甩出方向完全朝下
	fling_dir.y = maxf(fling_dir.y, -0.2)
	fling_dir = fling_dir.normalized()

	var cur_fling_mult: float = swing_fling_speed_mult if _is_swing_hook else fling_speed_mult
	var cur_fling_min: float = swing_fling_min_speed if _is_swing_hook else fling_min_speed
	var fling_speed: float = maxf(speed * cur_fling_mult, cur_fling_min)
	car.linear_velocity = fling_dir * fling_speed

	_enter_state(State.FALLING)
	_apply_camera_effect(fling_shake_intensity, 0.2, fling_fov_boost)
	print("[FreeGrapple] 绳断甩出! 速度=%.1f" % fling_speed)


## 按空格 (FALLING): 沿车头方向发射
func _trigger_launch() -> void:
	if state != State.FALLING:
		return
	if _has_launched:
		return  # 每次飞行只能发射一次

	_has_launched = true
	_enter_state(State.LAUNCHING)
	_launch_timer = 0.0

	var cur_launch_speed: float = swing_launch_speed if _is_swing_hook else launch_speed
	var forward: Vector3 = -car_mesh.global_transform.basis.z if car_mesh else Vector3.FORWARD
	forward.y = clampf(forward.y, -0.3, 0.3)
	forward = forward.normalized()
	car.linear_velocity = forward * cur_launch_speed
	_apply_camera_effect(launch_shake_intensity, launch_shake_duration, launch_fov_boost)
	print("[FreeGrapple] 发射! 方向=%s, 速度=%.1f" % [str(forward), cur_launch_speed])


# ============================================================
#  镜头效果
# ============================================================

## 当前 FOV 增量 (Camera3D 每帧读取并叠加)
var cam_fov_boost: float = 0.0
var _fov_decay_speed: float = 20.0  # FOV 回落速度 (度/秒)

func _apply_camera_effect(shake_intensity: float, shake_duration: float, fov_add: float) -> void:
	# 震屏
	if car and shake_intensity > 0.01 and car.has_signal("camera_shake_requested"):
		car.emit_signal("camera_shake_requested", shake_intensity, shake_duration)
	# FOV 冲击 (瞬间拉大, 自动衰减回 0)
	cam_fov_boost = fov_add


# ============================================================
#  充能
# ============================================================

func _on_boost_triggered(boost_type: String = "") -> void:
	if boost_type == "nitro" or boost_type == "c":
		_add_charge()

func _add_charge() -> void:
	if _wall_hit:
		return
	if state != State.IDLE:
		return
	if _charge_cooldown_left > 0.0:
		return
	_charges = mini(_charges + charge_per_nitro, max_charges)
	_charge_cooldown_left = charge_cooldown
	emit_signal("charges_changed", _charges, max_charges)

func get_charges() -> int:
	return _charges


# ============================================================
#  碰撞豁免
# ============================================================

func _update_collision_exempt(delta: float) -> void:
	if _exempt_timer > 0.0:
		_exempt_timer -= delta
		if _exempt_timer <= 0.0:
			if _is_inside_wall():
				_exempt_timer = 0.05
			else:
				_restore_collision()

func _disable_wall_collision() -> void:
	if car == null:
		return
	_original_collision_mask = car.collision_mask
	_original_collision_layer = car.collision_layer
	car.collision_mask = 0
	car.collision_layer = 0

func _restore_collision() -> void:
	if car == null:
		return
	car.collision_mask = _original_collision_mask
	car.collision_layer = _original_collision_layer

func _is_inside_wall() -> bool:
	if car == null:
		return false
	var space: PhysicsDirectSpaceState3D = car.get_world_3d().direct_space_state
	if space == null:
		return false
	var pos: Vector3 = car.global_position
	var dirs: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]
	for d in dirs:
		var query := PhysicsRayQueryParameters3D.create(pos, pos + d * 0.5)
		query.collision_mask = _original_collision_mask
		query.exclude = [car.get_rid()]
		var result: Dictionary = space.intersect_ray(query)
		if result.size() > 0:
			return true
	return false


# ============================================================
#  地面/墙壁检测
# ============================================================

func _is_on_ground() -> bool:
	if car == null:
		return false
	var space: PhysicsDirectSpaceState3D = car.get_world_3d().direct_space_state
	if space == null:
		return false
	var pos: Vector3 = car.global_position
	var query := PhysicsRayQueryParameters3D.create(pos, pos + Vector3.DOWN * 1.5)
	query.collision_mask = _original_collision_mask
	query.exclude = [car.get_rid()]
	var result: Dictionary = space.intersect_ray(query)
	return result.size() > 0

func _detect_wall_collision() -> bool:
	if car == null:
		return false
	if _exempt_timer > 0.0:
		return false
	var vel: Vector3 = car.linear_velocity
	if vel.length() < 1.0:
		return false
	var space: PhysicsDirectSpaceState3D = car.get_world_3d().direct_space_state
	if space == null:
		return false
	var pos: Vector3 = car.global_position
	var dir: Vector3 = vel.normalized()
	var query := PhysicsRayQueryParameters3D.create(pos, pos + dir * 2.0)
	query.collision_mask = _original_collision_mask
	query.exclude = [car.get_rid()]
	var result: Dictionary = space.intersect_ray(query)
	if result.size() > 0:
		var normal: Vector3 = result["normal"]
		if normal.dot(Vector3.UP) < 0.5:
			return true
	return false


# ============================================================
#  视觉: 钩索线 (Verlet 绳索)
# ============================================================

func _build_rope_visual() -> void:
	_rope_mat = StandardMaterial3D.new()
	_rope_mat.albedo_color = rope_color
	_rope_mat.emission_enabled = false
	_rope_mat.roughness = 0.95
	_rope_mat.metallic = 0.0
	_rope_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

func _show_rope() -> void:
	_verlet_inited = false

func _hide_rope() -> void:
	for seg in _rope_segments:
		if seg and is_instance_valid(seg):
			seg.queue_free()
	_rope_segments.clear()
	_verlet_pos = PackedVector3Array()
	_verlet_old = PackedVector3Array()
	_verlet_inited = false

func _init_verlet(from_pos: Vector3, to_pos: Vector3) -> void:
	_verlet_pos.clear()
	_verlet_old.clear()
	for i in range(fg_rope_node_count):
		var t: float = float(i) / float(fg_rope_node_count - 1)
		var p: Vector3 = from_pos.lerp(to_pos, t)
		_verlet_pos.append(p)
		_verlet_old.append(p)
	var total_len: float = from_pos.distance_to(to_pos) * 1.005
	_verlet_rest_len = total_len / float(fg_rope_node_count - 1)
	_verlet_inited = true

func _update_rope_visual() -> void:
	if car == null:
		return
	# 绳子只在 PULLING 状态可见
	if state != State.PULLING:
		if _rope_segments.size() > 0:
			_hide_rope()
		return

	var from_pos: Vector3 = car.global_position + Vector3(0, 0.5, 0)

	# 射出动画: 绳头从车飞向锚点
	# 飞行进度: 0 = 刚射出(绳头在车上), 1 = 到达锚点
	var cur_taut: float = swing_rope_taut_delay if _is_swing_hook else rope_taut_delay
	var fly_duration: float = maxf(cur_taut - 0.1, 0.05)  # 在延迟结束前0.1s到达
	var fly_progress: float = clampf(_state_timer / fly_duration, 0.0, 1.0)
	# ease-out: 开始快结尾慢 (钩索飞出的感觉)
	var eased: float = 1.0 - (1.0 - fly_progress) * (1.0 - fly_progress)

	# 绳头位置: 从车飞向锚点
	var to_pos: Vector3
	if fly_progress < 1.0:
		# 射出中: 绳头还没到锚点
		to_pos = from_pos.lerp(_anchor_world_pos, eased)
	else:
		# 已挂住: 绳头固定在锚点
		to_pos = _anchor_world_pos

	var current_dist: float = from_pos.distance_to(to_pos)
	if current_dist < 0.1:
		# 绳头还在车上, 不渲染
		if _rope_segments.size() > 0:
			_hide_rope()
		return

	# 绳子长度: 射出时松弛(比直线长50%), 拉紧后贴合(比直线长2%)
	var slack_mult: float
	if fly_progress < 1.0:
		slack_mult = 1.50  # 射出阶段: 大幅松弛, 剧烈甩动
	else:
		var taut_p: float = clampf((_state_timer - fly_duration) / 0.1, 0.0, 1.0)
		slack_mult = lerpf(1.30, 1.05, taut_p)  # 挂住后逐渐收紧
	var target_rest_total: float = current_dist * slack_mult
	_verlet_rest_len = target_rest_total / float(fg_rope_node_count - 1)

	if not _verlet_inited or _verlet_pos.size() != fg_rope_node_count:
		_init_verlet(from_pos, to_pos)

	# Verlet 积分
	var dt: float = get_physics_process_delta_time()
	if dt <= 0.0:
		dt = 1.0 / 60.0
	dt = minf(dt, 1.0 / 30.0)

	# 射出阶段: 绳子松弛下垂; 拉紧后: 强制直线
	var is_flying: bool = fly_progress < 1.0
	var taut_progress: float = clampf((_state_timer - fly_duration) / 0.1, 0.0, 1.0) if not is_flying else 0.0

	if taut_progress >= 1.0:
		# 完全拉紧: 所有节点强制在直线上 (一根笔直的绳子)
		for i in range(1, fg_rope_node_count - 1):
			var t_ratio: float = float(i) / float(fg_rope_node_count - 1)
			var line_pos: Vector3 = from_pos.lerp(to_pos, t_ratio)
			_verlet_old[i] = line_pos
			_verlet_pos[i] = line_pos
	else:
		# 射出/过渡阶段: Verlet 物理模拟
		var grav_scale: float
		var damp_scale: float
		if is_flying:
			grav_scale = 2.5   # 射出时重力加倍 → 绳子剧烈下坠甩动
			damp_scale = 0.02  # 几乎无阻尼 → 保持甩动动量
		else:
			grav_scale = 1.0 - taut_progress
			damp_scale = lerpf(0.02, fg_rope_damping, taut_progress)
		var gravity_vec: Vector3 = Vector3(0, -fg_rope_gravity * grav_scale, 0) * dt * dt

		for i in range(1, fg_rope_node_count - 1):
			var pos: Vector3 = _verlet_pos[i]
			var old: Vector3 = _verlet_old[i]
			var vel: Vector3 = (pos - old) * (1.0 - damp_scale)
			var t_ratio: float = float(i) / float(fg_rope_node_count - 1)
			var line_target: Vector3 = from_pos.lerp(to_pos, t_ratio)
			var pull_strength: float
			if is_flying:
				pull_strength = 0.005  # 极弱回弹, 让绳子自由甩
			else:
				pull_strength = lerpf(0.05, 0.8, taut_progress)
			var pull_to_line: Vector3 = (line_target - pos) * pull_strength
			var new_pos: Vector3 = pos + vel + gravity_vec + pull_to_line
			_verlet_old[i] = pos
			_verlet_pos[i] = new_pos

	# 锁定端点
	_verlet_pos[0] = from_pos
	_verlet_old[0] = from_pos
	_verlet_pos[fg_rope_node_count - 1] = to_pos
	_verlet_old[fg_rope_node_count - 1] = to_pos

	# 距离约束
	for _iter in range(fg_rope_constraint_iters):
		for i in range(fg_rope_node_count - 1):
			var p0: Vector3 = _verlet_pos[i]
			var p1: Vector3 = _verlet_pos[i + 1]
			var diff: Vector3 = p1 - p0
			var seg_dist: float = diff.length()
			if seg_dist < 0.0001:
				continue
			var error: float = seg_dist - _verlet_rest_len
			var correction: Vector3 = diff.normalized() * error * 0.5
			if i == 0:
				_verlet_pos[i + 1] -= correction
			elif i + 1 == fg_rope_node_count - 1:
				_verlet_pos[i] += correction
			else:
				_verlet_pos[i] += correction
				_verlet_pos[i + 1] -= correction

	# 确保 MeshInstance3D 段数够
	var seg_count: int = fg_rope_node_count - 1
	while _rope_segments.size() < seg_count:
		var seg := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = fg_rope_thickness * 0.5
		cyl.bottom_radius = fg_rope_thickness * 0.5
		cyl.height = 1.0
		cyl.radial_segments = 6
		seg.mesh = cyl
		if _rope_mat:
			seg.material_override = _rope_mat
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().current_scene.add_child(seg)
		_rope_segments.append(seg)
	while _rope_segments.size() > seg_count:
		var extra: MeshInstance3D = _rope_segments.pop_back()
		if extra and is_instance_valid(extra):
			extra.queue_free()

	# 更新每段圆柱
	for i in range(seg_count):
		var seg: MeshInstance3D = _rope_segments[i]
		if seg == null or not is_instance_valid(seg):
			continue
		var p0: Vector3 = _verlet_pos[i]
		var p1: Vector3 = _verlet_pos[i + 1]
		var seg_dir: Vector3 = p1 - p0
		var seg_len: float = seg_dir.length()
		if seg_len < 0.001:
			seg.visible = false
			continue
		seg.visible = true
		var cyl_mesh: CylinderMesh = seg.mesh as CylinderMesh
		if cyl_mesh:
			cyl_mesh.height = seg_len
			cyl_mesh.top_radius = fg_rope_thickness * 0.5
			cyl_mesh.bottom_radius = fg_rope_thickness * 0.5
		var mid_pt: Vector3 = (p0 + p1) * 0.5
		var y_ax: Vector3 = seg_dir.normalized()
		var x_ax: Vector3 = Vector3.UP.cross(y_ax)
		if x_ax.length_squared() < 0.001:
			x_ax = Vector3.RIGHT.cross(y_ax)
		x_ax = x_ax.normalized()
		var z_ax: Vector3 = x_ax.cross(y_ax).normalized()
		seg.global_transform = Transform3D(Basis(x_ax, y_ax, z_ax), mid_pt)
