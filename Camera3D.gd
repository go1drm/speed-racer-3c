extends Camera3D
## ============================================================
##  赛车跟随相机 + 震动 + 氮气/双喷拉远
## ============================================================

# ---------------- 跟随 ----------------
@export_group("Follow")
## 相机插值速度, 越大越紧贴车(也越生硬). 过小 + 高速 = 车跑出屏幕
@export var lerp_speed: float = 3.0
## 基础偏移(相对车辆本地坐标). Z+ = 车后方, Y+ = 车上方
@export var offset: Vector3 = Vector3.ZERO
## 相机到车的最大允许距离. 超出立即 clamp 回来, 防止高速时被远远甩开
## 0 = 不限制(老行为)
@export var max_follow_lag: float = 8.0
## 基础 FOV(度)
@export var base_fov_override: float = 75.0
## 是否在 _ready 用 base_fov_override 覆盖场景初始 FOV
@export var use_base_fov_override: bool = false

@export var target: Node

# ---------------- 氮气/双喷镜头 ----------------
@export_group("Boost Camera")
@export var nitro_zoom_offset: Vector3 = Vector3(0, 0.3, 1.5)   ## 氮气时镜头额外偏移(本地坐标)
@export var nitro_zoom_duration: float = 2.2                     ## 氮气拉远持续秒数
@export var nitro_fov_boost: float = 8.0                         ## 氮气时 FOV 增量(度), 0=不变
@export var nitro_zoom_curve: Curve                              ## 氮气拉远强度随时间曲线
@export var double_zoom_scale: float = 0.4                       ## 双喷相对氮气的缩放倍率
@export var double_zoom_duration: float = 0.9                    ## 双喷拉远持续秒数
@export var double_fov_boost: float = 4.0                        ## 双喷时 FOV 增量(度)
@export var double_zoom_curve: Curve                             ## 双喷拉远强度随时间曲线
@export var mini_zoom_scale: float = 0.0                         ## 小喷相对氮气的缩放倍率(0=不拉)
@export var mini_zoom_duration: float = 0.5
@export var mini_fov_boost: float = 0.0
@export var mini_zoom_curve: Curve                               ## 小喷拉远强度随时间曲线
@export var zoom_lerp_speed: float = 3.5                         ## 镜头偏移和 FOV 平滑速度

# ---------------- 震动 ----------------
@export_group("Shake")
@export var shake_y_factor: float = 0.7                          ## 震动 Y 分量衰减(相对 X)
@export var shake_z_factor: float = 0.3                          ## 震动 Z 分量衰减(相对 X)

# ---------------- Y 轴稳定(平地抖动过滤) ----------------
@export_group("Y Stabilizer")
## 启用 Y 轴稳定器: 过滤平地上微小起伏造成的相机抖动
@export var y_stabilizer_enabled: bool = true
## Y 偏差死区(米): 相机 Y 与目标 Y 的差距小于此值时不跟随. 0.15 推荐
## 大 = 稳相机但大起伏响应慢; 小 = 灵敏但还会抖
@export var y_deadzone: float = 0.15
## Y 跟随速度乘数: 在 deadzone 外, Y 方向的 lerp 速度倍率(相对水平). 小=更慢追 Y
@export var y_follow_speed_mult: float = 0.35
## 强制跟随 Y 的速度阈值(m/s): Y 速度超过此值(起跳/落地) 立即完全跟随. 3.0 推荐
@export var y_force_follow_vy: float = 3.0

var _shake_timer: float = 0.0
var _shake_intensity: float = 0.0
var _shake_duration: float = 0.0

var _zoom_extra: Vector3 = Vector3.ZERO
var _zoom_target: Vector3 = Vector3.ZERO
var _zoom_left: float = 0.0          # 当前拉远剩余秒数
var _zoom_total: float = 0.0         # 当前拉远总时长(用于曲线归一化)
var _zoom_base_offset: Vector3 = Vector3.ZERO  # 基础拉远向量(用于曲线缩放)
var _zoom_base_fov: float = 0.0      # 基础拉远 FOV 增量
var _zoom_curve: Curve = null        # 当前拉远适用的曲线

var _base_fov: float = 75.0
var _fov_target_boost: float = 0.0
var _fov_current_boost: float = 0.0

# Y 稳定: 维护一个平滑的"视觉 Y 目标", 同样做死区过滤
var _stable_look_y: float = 0.0
var _stable_look_y_inited: bool = false


func _ready() -> void:
	if use_base_fov_override:
		fov = base_fov_override
	_base_fov = fov
	# 自动连接车上的震动请求
	if target and target.get_parent() and target.get_parent().has_signal("camera_shake_requested"):
		target.get_parent().connect("camera_shake_requested", _on_shake)
		target.get_parent().connect("boost_triggered", _on_boost)


func _physics_process(delta: float) -> void:
	if not target:
		return

	# 拉远计时
	if _zoom_left > 0.0:
		_zoom_left -= delta
		if _zoom_left <= 0.0:
			_zoom_left = 0.0
			_zoom_total = 0.0
			_zoom_target = Vector3.ZERO
			_fov_target_boost = 0.0
			_zoom_curve = null
		else:
			# 应用曲线: 进度 0..1 → 曲线值 → 缩放当前 zoom_target / fov_target
			var prog: float = 1.0 - clampf(_zoom_left / maxf(_zoom_total, 0.0001), 0.0, 1.0)
			var k: float = 1.0
			if _zoom_curve:
				k = _zoom_curve.sample(prog)
			_zoom_target = _zoom_base_offset * k
			_fov_target_boost = _zoom_base_fov * k

	# 镜头偏移 + FOV 平滑
	_zoom_extra = _zoom_extra.lerp(_zoom_target, delta * zoom_lerp_speed)
	_fov_current_boost = lerpf(_fov_current_boost, _fov_target_boost, delta * zoom_lerp_speed)
	fov = _base_fov + _fov_current_boost

	var effective_offset: Vector3 = offset + _zoom_extra
	var target_pos: Transform3D = target.global_transform.translated_local(effective_offset)

	if y_stabilizer_enabled:
		# 分离 XZ 和 Y: XZ 正常跟随, Y 做死区 + 速度感知过滤
		var target_origin: Vector3 = target_pos.origin
		var cur_origin: Vector3 = global_position
		# XZ: 正常 lerp
		var new_xz_t: float = lerp_speed * delta
		var new_pos: Vector3 = cur_origin
		new_pos.x = lerpf(cur_origin.x, target_origin.x, new_xz_t)
		new_pos.z = lerpf(cur_origin.z, target_origin.z, new_xz_t)
		# Y: 看车的 Y 速度, 平地微抖时不动
		var car_vy: float = 0.0
		if target.get_parent() and "linear_velocity" in target.get_parent():
			car_vy = absf(target.get_parent().linear_velocity.y)
		var dy: float = target_origin.y - cur_origin.y
		if absf(car_vy) > y_force_follow_vy:
			# 起跳/落地: 立即完全跟随
			new_pos.y = lerpf(cur_origin.y, target_origin.y, new_xz_t)
		elif absf(dy) > y_deadzone:
			# 超出死区: 慢速追赶
			new_pos.y = lerpf(cur_origin.y, target_origin.y, new_xz_t * y_follow_speed_mult)
		else:
			# 死区内: 相机 Y 不动
			new_pos.y = cur_origin.y
		global_position = new_pos
		# basis (旋转) 单独插值, 用 XZ 速度
		global_transform.basis = global_transform.basis.slerp(target_pos.basis, new_xz_t)
	else:
		global_transform = global_transform.interpolate_with(target_pos, lerp_speed * delta)

	# 最大滞后距离限制: 高速行驶时防止相机被甩开造成"拉远"
	if max_follow_lag > 0.0:
		var to_target: Vector3 = target_pos.origin - global_position
		var dist: float = to_target.length()
		if dist > max_follow_lag:
			# 把相机直接拉回 max_follow_lag 范围内
			global_position = target_pos.origin - to_target.normalized() * max_follow_lag

	look_at(_stable_look_target(), Vector3.UP)

	# 应用震动（在 look_at 之后叠加小偏移）
	if _shake_timer > 0.0:
		_shake_timer -= delta
		var falloff: float = clampf(_shake_timer / _shake_duration, 0.0, 1.0)
		var amp: float = _shake_intensity * falloff
		var shake_offset: Vector3 = Vector3(
			randf_range(-amp, amp),
			randf_range(-amp, amp) * shake_y_factor,
			randf_range(-amp, amp) * shake_z_factor
		)
		global_position += shake_offset


func _stable_look_target() -> Vector3:
	# 返回一个 Y 经过稳定的 look_at 目标点. XZ 用车实际位置, Y 用平滑+死区后的值
	var tp: Vector3 = target.global_position
	if not y_stabilizer_enabled:
		return tp
	if not _stable_look_y_inited:
		_stable_look_y = tp.y
		_stable_look_y_inited = true
	var car_vy: float = 0.0
	if target.get_parent() and "linear_velocity" in target.get_parent():
		car_vy = absf(target.get_parent().linear_velocity.y)
	var dy: float = tp.y - _stable_look_y
	if absf(car_vy) > y_force_follow_vy:
		# 起跳/落地: 立即跟随
		_stable_look_y = tp.y
	elif absf(dy) > y_deadzone:
		# 超出死区: 慢速追
		_stable_look_y = lerpf(_stable_look_y, tp.y, 0.25)
	# 死区内: 保持不变
	return Vector3(tp.x, _stable_look_y, tp.z)


func _on_shake(intensity: float, duration: float) -> void:
	# 取较大值，避免叠加后震到吐
	if intensity > _shake_intensity * (_shake_timer / maxf(_shake_duration, 0.001)):
		_shake_intensity = intensity
		_shake_duration = duration
		_shake_timer = duration


func _on_boost(type_name: String) -> void:
	match type_name:
		"nitro":
			_zoom_base_offset = nitro_zoom_offset
			_zoom_base_fov = nitro_fov_boost
			_zoom_total = nitro_zoom_duration
			_zoom_left = nitro_zoom_duration
			_zoom_curve = nitro_zoom_curve
			_zoom_target = _zoom_base_offset
			_fov_target_boost = _zoom_base_fov
		"double":
			_zoom_base_offset = nitro_zoom_offset * double_zoom_scale
			_zoom_base_fov = double_fov_boost
			_zoom_total = double_zoom_duration
			_zoom_left = double_zoom_duration
			_zoom_curve = double_zoom_curve
			_zoom_target = _zoom_base_offset
			_fov_target_boost = _zoom_base_fov
		"mini":
			if mini_zoom_scale > 0.0 or mini_fov_boost > 0.0:
				_zoom_base_offset = nitro_zoom_offset * mini_zoom_scale
				_zoom_base_fov = mini_fov_boost
				_zoom_total = mini_zoom_duration
				_zoom_left = mini_zoom_duration
				_zoom_curve = mini_zoom_curve
				_zoom_target = _zoom_base_offset
				_fov_target_boost = _zoom_base_fov
