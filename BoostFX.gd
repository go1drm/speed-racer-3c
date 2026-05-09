extends Node3D
## ============================================================
##  喷射特效控制器
##  三种特效：小喷(mini) / 双喷(double) / 氮气(nitro)
##  视觉区分：颜色 + 尺寸 + 持续时长 + 是否带拖影
## ============================================================

@onready var mini_fx: GPUParticles3D = $MiniFX
@onready var double_fx: GPUParticles3D = $DoubleFX
@onready var nitro_fx: GPUParticles3D = $NitroFX
@onready var nitro_light: OmniLight3D = $NitroLight

var _active_timer: float = 0.0
var _active_type: String = ""


func _ready() -> void:
	# 初始全部关闭
	mini_fx.emitting = false
	double_fx.emitting = false
	nitro_fx.emitting = false
	nitro_light.visible = false


func _process(delta: float) -> void:
	if _active_timer > 0.0:
		_active_timer -= delta
		if _active_timer <= 0.0:
			_stop_all()


func play_boost(type_name: String, duration: float) -> void:
	_stop_all()
	_active_type = type_name
	_active_timer = duration
	match type_name:
		"mini":
			mini_fx.emitting = true
		"double":
			double_fx.emitting = true
		"nitro":
			nitro_fx.emitting = true
			nitro_light.visible = true


func _stop_all() -> void:
	mini_fx.emitting = false
	double_fx.emitting = false
	nitro_fx.emitting = false
	nitro_light.visible = false
	_active_type = ""
	_active_timer = 0.0
