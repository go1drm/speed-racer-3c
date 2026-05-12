extends Node3D
## ============================================================
##  喷射特效控制器
##  状态完全跟随 car.gd: 每帧从父对象拉 is_boosting + boost_type
##  这样就不会出现 BoostFX 自己计时跑完了但 car 还在喷的"特效丢失"问题
## ============================================================

@onready var mini_fx: GPUParticles3D = $MiniFX
@onready var double_fx: GPUParticles3D = $DoubleFX
@onready var nitro_fx: GPUParticles3D = $NitroFX
@onready var nitro_light: OmniLight3D = $NitroLight
@onready var air_fx: GPUParticles3D = $AirFX
@onready var air_light: OmniLight3D = $AirLight
@onready var landing_fx: GPUParticles3D = $LandingFX
@onready var landing_light: OmniLight3D = $LandingLight

# ---------------- 颜色配置 ----------------
# 小喷/双喷统一蓝色
const W_COLOR_ALBEDO := Color(0.4, 0.8, 1.0, 1.0)
const W_COLOR_EMISSION := Color(0.3, 0.7, 1.0, 1.0)

# 氮气三档颜色 (0=蓝 / 1=金 / 2=红)
const NITRO_COLORS := {
	"blue": {"albedo": Color(0.3, 0.7, 1.0, 1.0), "emission": Color(0.2, 0.6, 1.0, 1.0), "light": Color(0.35, 0.85, 1.0, 1.0)},
	"gold": {"albedo": Color(1.0, 0.85, 0.25, 1.0), "emission": Color(1.0, 0.7, 0.1, 1.0), "light": Color(1.0, 0.8, 0.2, 1.0)},
	"red":  {"albedo": Color(1.0, 0.35, 0.25, 1.0), "emission": Color(1.0, 0.2, 0.05, 1.0), "light": Color(1.0, 0.4, 0.25, 1.0)},
}

# ---------------- 增强倍率(突破次数 0/1/2) ----------------
# 现在改成 @export 让 Tuner 调
@export_group("FX Strength")
## 氮气基础粒子数量(0 突破时)
@export var nitro_amount_base: int = 80
## 氮气粒子数量随突破次数倍率 [0次, 1次(金), 2次(红)]
@export var nitro_amount_mult_0: float = 1.0
@export var nitro_amount_mult_1: float = 1.3
@export var nitro_amount_mult_2: float = 1.7
## 氮气粒子大小倍率
@export var nitro_scale_mult_0: float = 1.0
@export var nitro_scale_mult_1: float = 1.15
@export var nitro_scale_mult_2: float = 1.3
## 氮气灯光强度倍率
@export var nitro_light_energy_mult_0: float = 1.0
@export var nitro_light_energy_mult_1: float = 1.3
@export var nitro_light_energy_mult_2: float = 1.7
## 氮气粒子速度倍率
@export var nitro_velocity_mult_0: float = 1.0
@export var nitro_velocity_mult_1: float = 1.15
@export var nitro_velocity_mult_2: float = 1.3
## 全局粒子量缩放: 整体喷射特效强度倍率(空喷/落地喷/小喷/双喷/氮气都受影响). 0.5 = 减半, 1.0 = 默认, 2.0 = 双倍
@export var fx_global_amount_mult: float = 1.0:
	set(v):
		fx_global_amount_mult = v
		_apply_global_amount()

# 当前展示的 boost 类型(跟随 car.boost_type 而变)
var _shown_type: String = ""

# 缓存的原始参数(只读一次, 之后乘倍率)
var _nitro_base_scale_min: float = 1.3
var _nitro_base_scale_max: float = 2.2
var _nitro_base_velocity_min: float = 28.0
var _nitro_base_velocity_max: float = 38.0
var _nitro_base_light_energy: float = 4.0
# 各特效原始 amount, 用于全局缩放时还原
var _mini_base_amount: int = 40
var _double_base_amount: int = 80
var _air_base_amount: int = 160
var _landing_base_amount: int = 120


func _ready() -> void:
	mini_fx.emitting = false
	double_fx.emitting = false
	nitro_fx.emitting = false
	nitro_light.visible = false
	air_fx.emitting = false
	air_light.visible = false
	landing_fx.emitting = false
	landing_light.visible = false
	# 缓存基础参数
	var nitro_pm: ParticleProcessMaterial = nitro_fx.process_material
	if nitro_pm:
		_nitro_base_scale_min = nitro_pm.scale_min
		_nitro_base_scale_max = nitro_pm.scale_max
		_nitro_base_velocity_min = nitro_pm.initial_velocity_min
		_nitro_base_velocity_max = nitro_pm.initial_velocity_max
	_nitro_base_light_energy = nitro_light.light_energy
	# 缓存各特效原始 amount
	_mini_base_amount = mini_fx.amount
	_double_base_amount = double_fx.amount
	if has_node("AirFX"):
		_air_base_amount = air_fx.amount
	if has_node("LandingFX"):
		_landing_base_amount = landing_fx.amount
	# 应用蓝色到 mini/double
	_apply_w_color(mini_fx)
	_apply_w_color(double_fx)
	_apply_global_amount()


func _process(_delta: float) -> void:
	# 每帧从 car 拉真实状态(car 是 BoostFX 的父节点的父节点: car/CarMesh/BoostFX)
	# fx_node 在 car.gd 里通过 car_mesh.add_child(fx_node) 挂接
	var car: Node = _find_car()
	var target_type: String = ""
	if car and car.get("is_boosting"):
		target_type = car.get("boost_type")
	if target_type != _shown_type:
		_apply_state(target_type)
		_shown_type = target_type


func _find_car() -> Node:
	# 向上找 RigidBody3D 父对象
	var n: Node = self
	while n:
		if n is RigidBody3D:
			return n
		n = n.get_parent()
	return null


func _apply_state(type_name: String) -> void:
	# 先全关
	mini_fx.emitting = false
	double_fx.emitting = false
	nitro_fx.emitting = false
	nitro_light.visible = false
	air_fx.emitting = false
	air_light.visible = false
	landing_fx.emitting = false
	landing_light.visible = false
	# 再按类型开
	match type_name:
		"mini":
			mini_fx.emitting = true
		"double":
			double_fx.emitting = true
		"nitro":
			nitro_fx.emitting = true
			nitro_light.visible = true
		"air":
			air_fx.emitting = true
			air_light.visible = true
		"landing":
			landing_fx.emitting = true
			landing_light.visible = true


# 兼容旧调用: car.gd 仍可调 play_boost(name, duration), 这里只是同步触发(实际状态由 _process 拉)
func play_boost(type_name: String, _duration: float) -> void:
	# 立即应用一次, 避免下一帧才生效造成 1-2 帧延迟
	_apply_state(type_name)
	_shown_type = type_name


# 兼容旧调用: car.gd 中 _force_end_boost 会调 _stop_all()
func _stop_all() -> void:
	_apply_state("")
	_shown_type = ""


func set_nitro_variant(variant: String, breakthrough_count: int) -> void:
	# 应用颜色
	var col_data = NITRO_COLORS.get(variant, NITRO_COLORS["blue"])
	var mat: StandardMaterial3D = nitro_fx.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = col_data["albedo"]
		mat.emission = col_data["emission"]
		mat.emission_energy_multiplier = 8.0 * (1.0 + 0.4 * breakthrough_count)
	var pm: ParticleProcessMaterial = nitro_fx.process_material
	if pm:
		pm.color = col_data["albedo"]
	nitro_light.light_color = col_data["light"]
	# 应用强度增强(用 export 参数)
	var idx: int = clampi(breakthrough_count, 0, 2)
	var amount_mults := [nitro_amount_mult_0, nitro_amount_mult_1, nitro_amount_mult_2]
	var scale_mults := [nitro_scale_mult_0, nitro_scale_mult_1, nitro_scale_mult_2]
	var light_mults := [nitro_light_energy_mult_0, nitro_light_energy_mult_1, nitro_light_energy_mult_2]
	var vel_mults := [nitro_velocity_mult_0, nitro_velocity_mult_1, nitro_velocity_mult_2]
	nitro_fx.amount = int(nitro_amount_base * amount_mults[idx] * fx_global_amount_mult)
	nitro_light.light_energy = _nitro_base_light_energy * light_mults[idx]
	if pm:
		var s_mult: float = scale_mults[idx]
		var v_mult: float = vel_mults[idx]
		pm.scale_min = _nitro_base_scale_min * s_mult
		pm.scale_max = _nitro_base_scale_max * s_mult
		pm.initial_velocity_min = _nitro_base_velocity_min * v_mult
		pm.initial_velocity_max = _nitro_base_velocity_max * v_mult


func _apply_global_amount() -> void:
	# 把 fx_global_amount_mult 应用到所有 fx 的 amount 上
	# 氮气的 amount 由 set_nitro_variant 调用时已经乘过, 这里只处理其他几种
	if mini_fx:
		mini_fx.amount = maxi(1, int(_mini_base_amount * fx_global_amount_mult))
	if double_fx:
		double_fx.amount = maxi(1, int(_double_base_amount * fx_global_amount_mult))
	if has_node("AirFX") and air_fx:
		air_fx.amount = maxi(1, int(_air_base_amount * fx_global_amount_mult))
	if has_node("LandingFX") and landing_fx:
		landing_fx.amount = maxi(1, int(_landing_base_amount * fx_global_amount_mult))


func _apply_w_color(particles: GPUParticles3D) -> void:
	var mat: StandardMaterial3D = particles.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = W_COLOR_ALBEDO
		mat.emission = W_COLOR_EMISSION
	var pm: ParticleProcessMaterial = particles.process_material
	if pm:
		pm.color = W_COLOR_ALBEDO
