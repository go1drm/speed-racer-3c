extends Camera3D
## ============================================================
##  赛车跟随相机 + 震动支持
## ============================================================

@export var lerp_speed: float = 3.0
@export var offset: Vector3 = Vector3.ZERO
@export var target: Node
@export var nitro_zoom_offset: Vector3 = Vector3(0, 0.3, 1.5)   ## 氮气时镜头额外拉远

var _shake_timer: float = 0.0
var _shake_intensity: float = 0.0
var _shake_duration: float = 0.0

var _zoom_extra: Vector3 = Vector3.ZERO
var _zoom_target: Vector3 = Vector3.ZERO


func _ready() -> void:
	# 自动连接车上的震动请求
	if target and target.get_parent() and target.get_parent().has_signal("camera_shake_requested"):
		target.get_parent().connect("camera_shake_requested", _on_shake)
		target.get_parent().connect("boost_triggered", _on_boost)


func _physics_process(delta: float) -> void:
	if not target:
		return

	# 氮气镜头拉远的平滑
	_zoom_extra = _zoom_extra.lerp(_zoom_target, delta * 3.5)

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
			randf_range(-amp, amp) * 0.7,
			randf_range(-amp, amp) * 0.3
		)
		global_position += shake_offset


func _on_shake(intensity: float, duration: float) -> void:
	# 取较大值，避免叠加后震到吐
	if intensity > _shake_intensity * (_shake_timer / maxf(_shake_duration, 0.001)):
		_shake_intensity = intensity
		_shake_duration = duration
		_shake_timer = duration


func _on_boost(type_name: String) -> void:
	# 氮气时镜头拉远
	if type_name == "nitro":
		_zoom_target = nitro_zoom_offset
		await get_tree().create_timer(2.2).timeout
		_zoom_target = Vector3.ZERO
	elif type_name == "double":
		_zoom_target = nitro_zoom_offset * 0.4
		await get_tree().create_timer(0.9).timeout
		_zoom_target = Vector3.ZERO
