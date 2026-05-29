extends RefCounted
class_name DriftSystem
## ============================================================
##  QQ飞车漂移物理系统
##  实现文档中描述的完整力学模型:
##   - 7种力: 侧滑摩擦、滚动摩擦、油门驱动力、方向键助推力、回扳侧推力、松键反向力、撞墙衰减
##   - 2种扭矩: 方向键扭矩(反扳U型/顺扳线性)、回扳扭矩(自动回正)
##   - 9种退漂条件 + 退漂钳速
## ============================================================

# ============================================================
#  配置参数 (对应 DriftCfg.lua)
# ============================================================

## 起漂最低速度 (内部单位)
var start_vec: float = 18.0
## 高速漂退漂钳速
var end_vec_first: float = 50.0
## 低速漂退漂钳速
var end_vec_second: float = 16.0
## 侧滑摩擦系数
var slid_fric_force: float = 1.2
## 滚动摩擦系数
var roll_fric_force: float = 1.0
## 回扳判定角度 (度)
var banner_angle_deg: float = 45.0

## 方向键扭矩基础 (反扳模式: 顺按方向键维持漂移)
var dir_key_twist: float = 5.9
## 反扳扭矩扣减量
var dir_key_twist_param_a: float = 0.5
## 反扳扭矩保底量
var dir_key_twist_param_b: float = 1.5

## 顺扳扭矩基础 (反按方向键回正车头)
var banner_key_twist: float = 6.0
## 顺扳扭矩下限扣减量
var banner_key_twist_param_a: float = 1.2
## 顺扳扭矩上限附加量
var banner_key_twist_param_b: float = 0.0

## 自动回正扭矩基础
var banner_twist: float = 4.2
## 自动回正扭矩增长指数
var banner_twist_param_a: float = 1.3

## 起漂初始角速度 (rad/s)
var start_wec: float = 0.8
## 最大角速度上限 (rad/s)
var max_wec: float = 3.5
## 退漂时"几乎不转"判定阈值
var clock_wec: float = 0.0  # 注: 文档说明实际生效值是 0 (Bug)

## 方向键助推力基础
var dir_key_force: float = 1.5
## 方向键助推速度修正 A
var dir_key_force_param_a: float = 4.0
## 方向键助推速度修正 B
var dir_key_force_param_b: float = 10.0

## 油门驱动力基础
var dir_up_key_force: float = 10.0
## 油门驱动速度修正 A
var dir_up_key_force_param_a: float = 2.0
## 油门驱动速度修正 B
var dir_up_key_force_param_b: float = 14.0

## 回扳侧推力基础
var banner_vec_force: float = 6.0
## 回扳侧推速度修正 A
var banner_vec_force_param_a: float = 0.2
## 回扳侧推速度修正 B
var banner_vec_force_param_b: float = 0.8
## 回扳侧推速度修正 C
var banner_vec_force_param_c: float = 64.0

## 全松键反向力
var release_key_force: float = 3.0

## 撞墙速度衰减倍率
var wall_crash_speed_mult: float = 0.5
## 撞墙累积时长阈值 (秒)
var wall_collision_time_threshold: float = 0.3

## 漂移角 > 此值强制退漂 (度)
var max_drift_angle_deg: float = 135.0
## 漂移角 < 此值持续 N 秒退漂 (度)
var min_drift_angle_deg: float = 4.0
## 漂移角过小持续时间阈值 (秒)
var min_angle_duration: float = 0.8

## 小刮漂定时器 (秒) - 起漂后 N 秒内没甩到 banner_angle+5° 则退漂
var xiaogua_timer: float = 0.6
## 大漂定时器 (秒) - 角度从 ≥50° 回落后的兜底退漂
var banner_fallback_timer: float = 0.8

## 速度效果系数 (内部单位到游戏单位的转换)
var vec_effect: float = 1.0
## 角速度效果系数
var wec_effect: float = 3.7

## 视觉开关: 是否启用漂移视觉效果(车身侧倾、yaw偏移)
var visual_enabled: bool = true

# ============================================================
#  运行时状态
# ============================================================

## 是否正在漂移
var is_drifting: bool = false
## 漂移方向: -1=左漂, +1=右漂
var drift_dir: float = 0.0
## 当前漂移角 (弧度, 车头朝向与运动方向的夹角)
var drift_angle_rad: float = 0.0
## 当前漂移角速度 (rad/s, 车头旋转速度)
var drift_angular_velocity: float = 0.0
## 漂移已持续时间
var drift_elapsed: float = 0.0
## 起漂时的速度 (内部单位)
var start_speed: float = 0.0
## 是否为高速漂 (起漂速度 > end_vec_first)
var is_high_speed_drift: bool = false

## Banner 状态: 是否曾甩过 banner_angle+5° 大角度
var banner_triggered: bool = false
## 撞墙累积时间
var wall_collision_time: float = 0.0
## 是否正在撞墙
var is_colliding_wall: bool = false
## 漂移角过小累积时间
var small_angle_time: float = 0.0
## 小刮漂定时器剩余
var xiaogua_timer_left: float = 0.0
## 大漂兜底定时器剩余 (-1 = 未激活)
var banner_fallback_timer_left: float = -1.0

## 退漂类型
enum DriftEndType { NONE, NORMAL, ABNORMAL }
var last_end_type: int = DriftEndType.NONE

## 上一帧漂移角 (用于边沿检测)
var _prev_drift_angle_rad: float = 0.0

# ============================================================
#  公共接口
# ============================================================

## 尝试起漂. 返回 true 表示成功起漂
func try_start_drift(speed: float, steer_dir: float) -> bool:
	if is_drifting:
		return false
	if speed < start_vec * vec_effect:
		return false
	if absf(steer_dir) < 0.15:
		return false

	is_drifting = true
	drift_dir = signf(steer_dir)
	drift_angle_rad = 0.0
	drift_angular_velocity = start_wec * drift_dir
	drift_elapsed = 0.0
	start_speed = speed / vec_effect  # 转为内部单位
	is_high_speed_drift = start_speed > end_vec_first
	banner_triggered = false
	wall_collision_time = 0.0
	is_colliding_wall = false
	small_angle_time = 0.0
	xiaogua_timer_left = xiaogua_timer
	banner_fallback_timer_left = -1.0
	_prev_drift_angle_rad = 0.0
	last_end_type = DriftEndType.NONE
	return true

## 结束漂移 (外部调用, 如撞墙等)
func end_drift(is_normal: bool = true) -> void:
	if not is_drifting:
		return
	is_drifting = false
	last_end_type = DriftEndType.NORMAL if is_normal else DriftEndType.ABNORMAL
	drift_angular_velocity = 0.0

## 通知撞墙
func notify_wall_collision() -> void:
	is_colliding_wall = true

## 通知离开墙
func notify_wall_clear() -> void:
	is_colliding_wall = false
	wall_collision_time = 0.0

## 获取退漂钳速 (内部单位 → 游戏单位)
func get_exit_clamp_speed() -> float:
	if is_high_speed_drift:
		return end_vec_first * vec_effect
	else:
		return end_vec_second * vec_effect

## 获取当前漂移角 (度)
func get_drift_angle_deg() -> float:
	return rad_to_deg(absf(drift_angle_rad))

# ============================================================
#  每帧更新 (在 car._physics_process 中调用)
#  返回一个 Dictionary 包含本帧要施加的力和扭矩
# ============================================================

## 主更新函数
## 参数:
##   delta: 物理帧时间
##   speed: 当前水平速度大小 (游戏单位 m/s)
##   forward: 车头朝向 (归一化, XZ平面)
##   velocity_dir: 速度方向 (归一化, XZ平面)
##   steer_input: 方向键输入 (-1~+1)
##   throttle_input: 油门输入 (0~1)
##   shift_pressed: 漂移键是否按下
##   is_airborne: 是否在空中
## 返回:
##   Dictionary {
##     "force_along_velocity": float,  # 沿速度方向的力 (正=加速, 负=减速)
##     "force_lateral": float,         # 沿车体侧向的力 (回扳侧推)
##     "torque_yaw": float,            # 绕 Y 轴的扭矩 (正=左转)
##     "exit_drift": bool,             # 是否应该退漂
##     "exit_normal": bool,            # 退漂类型是否正常
##     "clamp_speed": float,           # 退漂钳速 (-1 = 不钳)
##     "wall_speed_mult": float,       # 撞墙速度倍率 (1.0 = 不变)
##   }
func update(delta: float, speed: float, forward: Vector3, velocity_dir: Vector3,
		steer_input: float, throttle_input: float, shift_pressed: bool, is_airborne: bool) -> Dictionary:

	var result := {
		"force_along_velocity": 0.0,
		"force_lateral": 0.0,
		"torque_yaw": 0.0,
		"exit_drift": false,
		"exit_normal": true,
		"clamp_speed": -1.0,
		"wall_speed_mult": 1.0,
	}

	if not is_drifting:
		return result

	# 空中不处理漂移物理 (保持状态但不施力/不退漂)
	if is_airborne:
		return result

	drift_elapsed += delta
	var internal_speed: float = speed / maxf(vec_effect, 0.001)

	# ============ 计算漂移角 ============
	# 漂移角 = 车头朝向与速度方向的夹角
	if velocity_dir.length() > 0.01 and forward.length() > 0.01:
		var dot_val: float = clampf(forward.dot(velocity_dir), -1.0, 1.0)
		drift_angle_rad = acos(dot_val)
		# 带符号: 用叉积 Y 分量判断方向
		var cross_y: float = forward.cross(velocity_dir).y
		if cross_y < 0.0:
			drift_angle_rad = -drift_angle_rad
	var abs_angle: float = absf(drift_angle_rad)
	var angle_deg: float = rad_to_deg(abs_angle)

	# ============ Banner 状态管理 ============
	var banner_add_rad: float = deg_to_rad(banner_angle_deg + 5.0)
	var banner_dec_rad: float = deg_to_rad(banner_angle_deg - 5.0)

	# 角度穿过 banner_angle+5° 上升沿 → Banner = true
	if abs_angle >= banner_add_rad and absf(_prev_drift_angle_rad) < banner_add_rad:
		banner_triggered = true

	# 角度穿过 banner_angle+5° 下降沿 → Banner = false, 启动兜底定时器
	if abs_angle < banner_add_rad and absf(_prev_drift_angle_rad) >= banner_add_rad:
		banner_triggered = false
		banner_fallback_timer_left = banner_fallback_timer

	# ============ 退漂条件检查 ============

	# 条件 3.1: 撞墙累积
	if is_colliding_wall:
		wall_collision_time += delta
		if wall_collision_time > wall_collision_time_threshold:
			result["exit_drift"] = true
			result["exit_normal"] = false
			result["wall_speed_mult"] = wall_crash_speed_mult
			_prev_drift_angle_rad = abs_angle
			return result
	else:
		wall_collision_time = 0.0

	# 条件 3.2: 角度回落判定 (最常见)
	# 本帧漂移角 < 40° 且上一帧 >= 40° 且松 Shift
	if abs_angle < banner_dec_rad and absf(_prev_drift_angle_rad) >= banner_dec_rad:
		if not shift_pressed:
			result["exit_drift"] = true
			result["exit_normal"] = true
			result["clamp_speed"] = get_exit_clamp_speed()
			_prev_drift_angle_rad = abs_angle
			return result

	# 条件 3.3: 高速漂速度掉破 FirstEndVec
	if is_high_speed_drift and internal_speed < end_vec_first:
		if not shift_pressed or absf(steer_input) < 0.1:
			result["exit_drift"] = true
			result["exit_normal"] = true
			result["clamp_speed"] = get_exit_clamp_speed()
			_prev_drift_angle_rad = abs_angle
			return result

	# 条件 3.4: 高速漂速度掉到 SecondEndVec
	if is_high_speed_drift and internal_speed < end_vec_second:
		result["exit_drift"] = true
		result["exit_normal"] = true
		result["clamp_speed"] = get_exit_clamp_speed()
		_prev_drift_angle_rad = abs_angle
		return result

	# 条件 3.5: 低速漂速度掉到 SecondEndVec
	if not is_high_speed_drift and internal_speed < end_vec_second:
		result["exit_drift"] = true
		result["exit_normal"] = false
		_prev_drift_angle_rad = abs_angle
		return result

	# 条件 3.6: 漂移角过大
	if angle_deg > max_drift_angle_deg:
		result["exit_drift"] = true
		result["exit_normal"] = true
		_prev_drift_angle_rad = abs_angle
		return result

	# 条件 3.7: 漂移角过小持续
	if angle_deg < min_drift_angle_deg:
		small_angle_time += delta
		if small_angle_time >= min_angle_duration:
			result["exit_drift"] = true
			result["exit_normal"] = false
			_prev_drift_angle_rad = abs_angle
			return result
	else:
		small_angle_time = 0.0

	# 条件 3.8: 大漂兜底定时器
	if banner_fallback_timer_left > 0.0:
		banner_fallback_timer_left -= delta
		if banner_fallback_timer_left <= 0.0:
			if abs_angle <= deg_to_rad(banner_angle_deg) and not banner_triggered:
				result["exit_drift"] = true
				result["exit_normal"] = true
				result["clamp_speed"] = get_exit_clamp_speed()
				_prev_drift_angle_rad = abs_angle
				return result

	# 条件 3.9: 小刮漂定时器
	if xiaogua_timer_left > 0.0:
		xiaogua_timer_left -= delta
		if xiaogua_timer_left <= 0.0:
			if abs_angle <= deg_to_rad(banner_angle_deg) and not banner_triggered:
				result["exit_drift"] = true
				result["exit_normal"] = true
				result["clamp_speed"] = get_exit_clamp_speed()
				_prev_drift_angle_rad = abs_angle
				return result

	# ============ 计算力 ============

	# 判断按键状态
	var has_throttle: bool = throttle_input > 0.05
	var has_steer: bool = absf(steer_input) > 0.1
	var steer_same_as_drift: bool = has_steer and signf(steer_input) == signf(drift_dir)
	var steer_opposite: bool = has_steer and signf(steer_input) != signf(drift_dir)
	var all_released: bool = not has_throttle and not has_steer and not shift_pressed

	var total_decel_force: float = 0.0

	# --- 力 1: 侧滑摩擦 = slid_fric_force × sin(漂移角) ---
	var slid_friction: float = slid_fric_force * sin(abs_angle)
	total_decel_force += slid_friction

	# --- 力 2: 滚动摩擦 = roll_fric_force × cos(漂移角) ---
	var roll_friction: float = roll_fric_force * cos(abs_angle)
	total_decel_force += roll_friction

	# 减速力沿速度反方向
	result["force_along_velocity"] = -total_decel_force

	# --- 力 3: 油门驱动力 ---
	if has_throttle:
		# 公式: fDirUpKeyForce + fDirUpKeyForceParamA × v / (fDirUpKeyForceParamB + v)
		var engine_force: float = dir_up_key_force + dir_up_key_force_param_a * internal_speed / (dir_up_key_force_param_b + internal_speed)
		result["force_along_velocity"] += engine_force * throttle_input

	# --- 力 4: 方向键助推力 (漂移同向按键时) ---
	if steer_same_as_drift:
		# 公式: (fDirKeyForce + fDirKeyForceParamA × v / (fDirKeyForceParamB + v)) × cos(漂移角)
		var dir_force: float = (dir_key_force + dir_key_force_param_a * internal_speed / (dir_key_force_param_b + internal_speed)) * cos(abs_angle)
		result["force_along_velocity"] += dir_force

	# --- 力 5: 回扳侧推力 (反扳时) ---
	if steer_opposite:
		# fFactor = fBannerVecForceParamA + fBannerVecForceParamB × v² / fBannerVecForceParamC
		var f_factor: float = banner_vec_force_param_a + banner_vec_force_param_b * internal_speed * internal_speed / banner_vec_force_param_c
		# fpFac = 漂移角(度) / 45° - 1
		var fp_fac: float = angle_deg / banner_angle_deg - 1.0
		var lateral_force: float = banner_vec_force * f_factor * fp_fac
		result["force_lateral"] = lateral_force * (-drift_dir)  # 推向漂移反方向(回正)

	# --- 力 6: 松键反向力 ---
	if all_released:
		result["force_along_velocity"] -= release_key_force

	# ============ 计算扭矩 ============
	var total_torque: float = 0.0

	if has_steer:
		if steer_same_as_drift:
			# --- 反扳模式 (顺按方向键维持漂移) ---
			# FactorA = 1 - sin(2 × 漂移角)
			var factor_a: float = 1.0 - sin(2.0 * abs_angle)
			factor_a = maxf(factor_a, 0.0)
			# fKeyTwist = (fDirKeyTwist - ParamA) × FactorA + ParamB
			var key_twist: float = (dir_key_twist - dir_key_twist_param_a) * factor_a + dir_key_twist_param_b
			total_torque = key_twist * drift_dir
		else:
			# --- 顺扳模式 (反按方向键回正车头) ---
			# fKeyTwistMin = fBannerKeyTwist - ParamA
			# fKeyTwistMax = fBannerKeyTwist + ParamB
			# fKeyTwist = Min + (Max - Min) × (2θ/π)
			var twist_min: float = banner_key_twist - banner_key_twist_param_a
			var twist_max: float = banner_key_twist + banner_key_twist_param_b
			var key_twist: float = twist_min + (twist_max - twist_min) * (2.0 * abs_angle / PI)
			# 顺扳方向: 与漂移方向相反 (回正)
			total_torque = key_twist * (-drift_dir)

		# 特殊情况: 漂移角 > 90° 时反向加倍
		if angle_deg > 90.0:
			total_torque *= -2.0

	# --- 回扳扭矩 (自动回正) ---
	# 公式: banner_twist × (2θ/π)^banner_twist_param_a
	var auto_straighten: float = banner_twist * pow(2.0 * abs_angle / PI, banner_twist_param_a)
	# 方向: 与漂移方向相反 (把车头拉回来)
	total_torque += auto_straighten * (-signf(drift_angle_rad))

	# 角速度上限
	drift_angular_velocity += total_torque * wec_effect * delta
	drift_angular_velocity = clampf(drift_angular_velocity, -max_wec, max_wec)

	result["torque_yaw"] = total_torque

	# 记录上一帧漂移角
	_prev_drift_angle_rad = abs_angle

	return result
