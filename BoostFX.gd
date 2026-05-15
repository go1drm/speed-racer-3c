extends Node3D
## ============================================================
##  喷射特效控制器 (v2: 双层结构 主焰柱 + 星星散粒)
##  状态完全跟随 car.gd: 每帧从父对象拉 is_boosting + boost_type
##  这样就不会出现 BoostFX 自己计时跑完了但 car 还在喷的"特效丢失"问题
##
##  节点树 (参考 BoostFX.tscn):
##    · MiniFX + MiniStar        (小喷 蓝色细焰柱 + 金色星星)
##    · DoubleFX + DoubleStar    (双喷)
##    · NitroFX + NitroStar      (氮气 紫蓝 + 金色星星 - 参考图风格)
##    · AirFX / LandingFX        (空喷/落地喷 保留原样, 无星星层)
##
##  尺寸设计:
##    · 粒子宽度 ≈ 排气管宽 (scale 0.08~0.25)
##    · 焰柱长度 ≈ 玉麒麟车身一半 (~2.5m) = lifetime × velocity
##    · 可通过 @export 的 *_length / *_width / *_star_count 整体调整
## ============================================================

@onready var mini_fx: GPUParticles3D = $MiniFX
@onready var mini_star: GPUParticles3D = $MiniStar
@onready var double_fx: GPUParticles3D = $DoubleFX
@onready var double_star: GPUParticles3D = $DoubleStar
@onready var nitro_fx: GPUParticles3D = $NitroFX
@onready var nitro_star: GPUParticles3D = $NitroStar
@onready var nitro_light: OmniLight3D = $NitroLight
@onready var air_fx: GPUParticles3D = $AirFX
@onready var air_light: OmniLight3D = $AirLight
@onready var landing_fx: GPUParticles3D = $LandingFX
@onready var landing_light: OmniLight3D = $LandingLight

# ---------------- 颜色配置 ----------------
const W_COLOR_ALBEDO := Color(0.5, 0.85, 1.0, 1.0)
const W_COLOR_EMISSION := Color(0.3, 0.7, 1.0, 1.0)

# 氮气三档颜色 (blue=0次, gold=1次突破, red=2次突破)
const NITRO_COLORS := {
	"blue": {"albedo": Color(0.55, 0.45, 1.0, 1.0), "emission": Color(0.45, 0.35, 1.0, 1.0), "light": Color(0.6, 0.5, 1.0, 1.0)},
	"gold": {"albedo": Color(1.0, 0.85, 0.25, 1.0), "emission": Color(1.0, 0.7, 0.1, 1.0), "light": Color(1.0, 0.8, 0.2, 1.0)},
	"red":  {"albedo": Color(1.0, 0.35, 0.25, 1.0), "emission": Color(1.0, 0.2, 0.05, 1.0), "light": Color(1.0, 0.4, 0.25, 1.0)},
}

# ============================================================
#  @export 可调参数 (Tuner 友好)
# ============================================================

@export_group("Shape - 尺寸")
## 【焰柱目标长度】(米) - 主焰柱尾焰的大致长度. 公式: lifetime × initial_velocity ≈ length
## 玉麒麟车身 ~5.3m, 推荐 2~3m (半个车身)
@export_range(0.5, 10.0, 0.1) var flame_target_length: float = 2.5:
	set(v):
		flame_target_length = v
		_apply_length_to_all()
## 【焰柱宽度系数】 - 所有主焰柱粒子 scale 的统一缩放. 1.0=默认(约排气管宽), 小=更细, 大=更粗
@export_range(0.1, 3.0, 0.05) var flame_width_mult: float = 1.0:
	set(v):
		flame_width_mult = v
		_apply_width_to_all()

@export_group("Strength - 强度")
## 氮气基础粒子数量 (0 突破时)
@export var nitro_amount_base: int = 80
## 氮气粒子数量随突破次数倍率 [0次, 1次(金), 2次(红)]
@export var nitro_amount_mult_0: float = 1.0
@export var nitro_amount_mult_1: float = 1.3
@export var nitro_amount_mult_2: float = 1.7
## 氮气粒子大小倍率 (乘在 flame_width_mult 上)
@export var nitro_scale_mult_0: float = 1.0
@export var nitro_scale_mult_1: float = 1.15
@export var nitro_scale_mult_2: float = 1.3
## 氮气灯光强度倍率
@export var nitro_light_energy_mult_0: float = 1.0
@export var nitro_light_energy_mult_1: float = 1.3
@export var nitro_light_energy_mult_2: float = 1.7
## 氮气粒子速度倍率 (焰柱长度的细分控制; 与 flame_target_length 叠加)
@export var nitro_velocity_mult_0: float = 1.0
@export var nitro_velocity_mult_1: float = 1.15
@export var nitro_velocity_mult_2: float = 1.3

## 全局粒子量缩放: 0.5=减半, 1.0=默认, 2.0=双倍
@export var fx_global_amount_mult: float = 1.0:
	set(v):
		fx_global_amount_mult = v
		_apply_global_amount()

@export_group("Stars - 星星散粒")
## 星星总开关: false 时全部星星层隐藏
@export var stars_enabled: bool = true:
	set(v):
		stars_enabled = v
		_apply_stars_visible()
## 星星数量倍率 (每种 boost 独立配置基础量, 这个是全局乘数)
@export_range(0.0, 3.0, 0.1) var stars_amount_mult: float = 1.0:
	set(v):
		stars_amount_mult = v
		_apply_star_amounts()
## 星星大小倍率
@export_range(0.3, 3.0, 0.05) var stars_scale_mult: float = 1.0:
	set(v):
		stars_scale_mult = v
		_apply_star_scales()
## 星星颜色 (默认金色, 参考图里的四角金星)
@export var stars_color: Color = Color(1.0, 0.85, 0.35, 1.0):
	set(v):
		stars_color = v
		_apply_star_colors()
## 星星重力 (负数=往下飘, 0=悬浮, 正数=往上)
@export_range(-5.0, 5.0, 0.1) var stars_gravity_y: float = -0.5:
	set(v):
		stars_gravity_y = v
		_apply_star_gravity()

# ============================================================
#  内部状态
# ============================================================

var _shown_type: String = ""   # 当前展示的 boost 类型(跟随 car.boost_type)

# 各 star 节点的基础 amount (从 tscn 里读一次, 之后乘 mult 还原)
var _mini_star_base_amount: int = 10
var _double_star_base_amount: int = 14
var _nitro_star_base_amount: int = 22

# 主焰柱基础 amount
var _mini_base_amount: int = 35
var _double_base_amount: int = 55
var _air_base_amount: int = 100
var _landing_base_amount: int = 80

# 氮气粒子的基础 scale / velocity (用于 set_nitro_variant 计算)
var _nitro_base_scale_min: float = 0.12
var _nitro_base_scale_max: float = 0.25
var _nitro_base_velocity_min: float = 7.0
var _nitro_base_velocity_max: float = 9.0
var _nitro_base_light_energy: float = 3.5


func _ready() -> void:
	mini_fx.emitting = false
	mini_star.emitting = false
	double_fx.emitting = false
	double_star.emitting = false
	nitro_fx.emitting = false
	nitro_star.emitting = false
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

	_mini_base_amount = mini_fx.amount
	_double_base_amount = double_fx.amount
	if has_node("AirFX"):
		_air_base_amount = air_fx.amount
	if has_node("LandingFX"):
		_landing_base_amount = landing_fx.amount

	_mini_star_base_amount = mini_star.amount
	_double_star_base_amount = double_star.amount
	_nitro_star_base_amount = nitro_star.amount

	# 应用蓝色到 mini/double (氮气由 set_nitro_variant 动态控制)
	_apply_w_color(mini_fx)
	_apply_w_color(double_fx)
	_apply_global_amount()


func _process(_delta: float) -> void:
	# 每帧从 car 拉真实状态(car 是 BoostFX 的父节点的父节点: car/CarMesh/BoostFX)
	var car: Node = _find_car()
	var target_type: String = ""
	if car and car.get("is_boosting"):
		target_type = car.get("boost_type")
	if target_type != _shown_type:
		_apply_state(target_type)
		_shown_type = target_type


func _find_car() -> Node:
	var n: Node = self
	while n:
		if n is RigidBody3D:
			return n
		n = n.get_parent()
	return null


# ============================================================
#  状态切换: 开关 FX + Star 节点对
# ============================================================
func _apply_state(type_name: String) -> void:
	# 先全关 (FX 主焰柱 + Star 散粒)
	mini_fx.emitting = false
	mini_star.emitting = false
	double_fx.emitting = false
	double_star.emitting = false
	nitro_fx.emitting = false
	nitro_star.emitting = false
	nitro_light.visible = false
	air_fx.emitting = false
	air_light.visible = false
	landing_fx.emitting = false
	landing_light.visible = false
	# 按类型开 (Star 节点受 stars_enabled 总开关控制)
	match type_name:
		"mini":
			mini_fx.emitting = true
			mini_star.emitting = stars_enabled
		"double":
			double_fx.emitting = true
			double_star.emitting = stars_enabled
		"nitro":
			nitro_fx.emitting = true
			nitro_star.emitting = stars_enabled
			nitro_light.visible = true
		"air", "grapple_boost":
			air_fx.emitting = true
			air_light.visible = true
		"landing":
			landing_fx.emitting = true
			landing_light.visible = true
		"grapple_nitro":
			# 钩索氮气弹射: 同时播放氮气焰柱 + 空喷特效 (双重视觉表现强力推进)
			nitro_fx.emitting = true
			nitro_star.emitting = stars_enabled
			nitro_light.visible = true
			air_fx.emitting = true
			air_light.visible = true


func play_boost(type_name: String, _duration: float) -> void:
	# 用户要求: 加速带视为氮气, 走 nitro 视觉 (蓝色喷射焰柱) 而不是把所有 FX 关掉
	# _apply_state 的 match 没有 "speed_pad" 分支, 直接传进去会全关 → 喷管不冒火
	# 修复: 把 "speed_pad" 在 FX 层面映射成 "nitro"
	var visual_type: String = type_name
	if type_name == "speed_pad":
		visual_type = "nitro"
	# grapple_boost 和 grapple_nitro 已在 _apply_state 中有对应分支, 直接传入
	_apply_state(visual_type)
	_shown_type = visual_type


func _stop_all() -> void:
	_apply_state("")
	_shown_type = ""


# ============================================================
#  氮气变体: 颜色 + 强度随突破次数变化
# ============================================================
func set_nitro_variant(variant: String, breakthrough_count: int) -> void:
	# 应用颜色
	var col_data = NITRO_COLORS.get(variant, NITRO_COLORS["blue"])
	var mat: StandardMaterial3D = nitro_fx.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = col_data["albedo"]
		mat.emission = col_data["emission"]
		mat.emission_energy_multiplier = 6.0 * (1.0 + 0.4 * breakthrough_count)
	var pm: ParticleProcessMaterial = nitro_fx.process_material
	if pm:
		pm.color = col_data["albedo"]
	nitro_light.light_color = col_data["light"]
	# 应用强度增强
	var idx: int = clampi(breakthrough_count, 0, 2)
	var amount_mults := [nitro_amount_mult_0, nitro_amount_mult_1, nitro_amount_mult_2]
	var scale_mults := [nitro_scale_mult_0, nitro_scale_mult_1, nitro_scale_mult_2]
	var light_mults := [nitro_light_energy_mult_0, nitro_light_energy_mult_1, nitro_light_energy_mult_2]
	var vel_mults := [nitro_velocity_mult_0, nitro_velocity_mult_1, nitro_velocity_mult_2]
	nitro_fx.amount = int(nitro_amount_base * amount_mults[idx] * fx_global_amount_mult)
	nitro_light.light_energy = _nitro_base_light_energy * light_mults[idx]
	if pm:
		var s_mult: float = scale_mults[idx] * flame_width_mult
		var v_mult: float = vel_mults[idx]
		pm.scale_min = _nitro_base_scale_min * s_mult
		pm.scale_max = _nitro_base_scale_max * s_mult
		# 速度由 flame_target_length 和 lifetime 决定, 再乘突破倍率
		var target_vel: float = flame_target_length / maxf(nitro_fx.lifetime, 0.01)
		pm.initial_velocity_min = target_vel * 0.85 * v_mult
		pm.initial_velocity_max = target_vel * 1.1 * v_mult


# ============================================================
#  全局缩放 / 宽度 / 长度应用
# ============================================================
func _apply_global_amount() -> void:
	# 把 fx_global_amount_mult 应用到所有主焰柱 + 星星 amount 上
	# 氮气主体的 amount 由 set_nitro_variant 调用时已经乘过(突破加成), 这里只处理其他几种
	if mini_fx:
		mini_fx.amount = maxi(1, int(_mini_base_amount * fx_global_amount_mult))
	if double_fx:
		double_fx.amount = maxi(1, int(_double_base_amount * fx_global_amount_mult))
	if has_node("AirFX") and air_fx:
		air_fx.amount = maxi(1, int(_air_base_amount * fx_global_amount_mult))
	if has_node("LandingFX") and landing_fx:
		landing_fx.amount = maxi(1, int(_landing_base_amount * fx_global_amount_mult))
	_apply_star_amounts()


func _apply_length_to_all() -> void:
	# 把 flame_target_length 应用到 mini/double/nitro 主焰柱速度上
	# 公式: velocity = length / lifetime
	# 注: 氮气的速度每次 set_nitro_variant 时会重新算, 这里算个兜底
	_set_length(mini_fx, flame_target_length)
	_set_length(double_fx, flame_target_length)
	_set_length(nitro_fx, flame_target_length)


func _set_length(fx: GPUParticles3D, length: float) -> void:
	if fx == null:
		return
	var pm: ParticleProcessMaterial = fx.process_material
	if pm == null:
		return
	var target_vel: float = length / maxf(fx.lifetime, 0.01)
	pm.initial_velocity_min = target_vel * 0.85
	pm.initial_velocity_max = target_vel * 1.1


func _apply_width_to_all() -> void:
	# 把 flame_width_mult 应用到 mini/double 的 scale 上
	# 氮气的 scale 在 set_nitro_variant 里会考虑 flame_width_mult
	_set_width(mini_fx, 0.08, 0.2, flame_width_mult)
	_set_width(double_fx, 0.1, 0.22, flame_width_mult)


func _set_width(fx: GPUParticles3D, base_min: float, base_max: float, mult: float) -> void:
	if fx == null:
		return
	var pm: ParticleProcessMaterial = fx.process_material
	if pm == null:
		return
	pm.scale_min = base_min * mult
	pm.scale_max = base_max * mult


# ============================================================
#  星星相关: 总开关 / 数量 / 大小 / 颜色 / 重力
# ============================================================
func _apply_stars_visible() -> void:
	# 立即根据当前 _shown_type 重新启用 star 节点
	# 若 stars_enabled=false, 直接关掉所有 star
	if not stars_enabled:
		if mini_star: mini_star.emitting = false
		if double_star: double_star.emitting = false
		if nitro_star: nitro_star.emitting = false
	else:
		# 重新应用一次状态让对应 star 开起来
		_apply_state(_shown_type)


func _apply_star_amounts() -> void:
	var g: float = fx_global_amount_mult * stars_amount_mult
	if mini_star:
		mini_star.amount = maxi(1, int(_mini_star_base_amount * g))
	if double_star:
		double_star.amount = maxi(1, int(_double_star_base_amount * g))
	if nitro_star:
		nitro_star.amount = maxi(1, int(_nitro_star_base_amount * g))


func _apply_star_scales() -> void:
	# mini/double/nitro 星星的 base scale 分别是 (0.18,0.35) / (0.2,0.4) / (0.25,0.5)
	_set_star_scale(mini_star, 0.18, 0.35, stars_scale_mult)
	_set_star_scale(double_star, 0.2, 0.4, stars_scale_mult)
	_set_star_scale(nitro_star, 0.25, 0.5, stars_scale_mult)


func _set_star_scale(star: GPUParticles3D, base_min: float, base_max: float, mult: float) -> void:
	if star == null:
		return
	var pm: ParticleProcessMaterial = star.process_material
	if pm:
		pm.scale_min = base_min * mult
		pm.scale_max = base_max * mult


func _apply_star_colors() -> void:
	for star in [mini_star, double_star, nitro_star]:
		if star == null:
			continue
		var mat: StandardMaterial3D = star.material_override as StandardMaterial3D
		if mat:
			mat.albedo_color = stars_color
			# emission 保持原有色调 + 根据 albedo 稍微暗一点
			mat.emission = Color(stars_color.r * 0.9, stars_color.g * 0.85, stars_color.b * 0.55, 1.0)
		var pm: ParticleProcessMaterial = star.process_material
		if pm:
			pm.color = stars_color


func _apply_star_gravity() -> void:
	for star in [mini_star, double_star, nitro_star]:
		if star == null:
			continue
		var pm: ParticleProcessMaterial = star.process_material
		if pm:
			var g: Vector3 = pm.gravity
			g.y = stars_gravity_y
			pm.gravity = g


# ============================================================
#  Mini/Double 蓝色应用(氮气由 variant 动态控制)
# ============================================================
func _apply_w_color(particles: GPUParticles3D) -> void:
	var mat: StandardMaterial3D = particles.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = W_COLOR_ALBEDO
		mat.emission = W_COLOR_EMISSION
	var pm: ParticleProcessMaterial = particles.process_material
	if pm:
		pm.color = W_COLOR_ALBEDO
