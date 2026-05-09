extends Camera3D
## ============================================================
##  赛车跟随相机 + 震动 + 氮气/双喷拉远
## ============================================================

# ---------------- 跟随 ----------------
@export_group("Follow")
@export var lerp_speed: float = 3.0
@export var offset: Vector3 = Vector3.ZERO
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


func _ready() -> void:
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
	global_transform = global_transform.interpolate_with(target_pos, lerp_speed * delta)
	look_at(target.global_position, Vector3.UP)

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
