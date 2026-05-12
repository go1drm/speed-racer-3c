extends GPUParticles3D
## ============================================================
##  玻璃渣碎开特效 - 一次性播放后自动 queue_free
##  撞墙时由 car.gd 实例化, 放到接触点上播一次
## ============================================================

@export var auto_free_delay: float = 1.2      # 播放完后多久释放自己(应该 >= lifetime)


func _ready() -> void:
	emitting = true
	# 播完就释放
	var t := get_tree().create_timer(auto_free_delay)
	t.timeout.connect(queue_free)


# 外部调用: 按撞击参数调整视觉强度
# impact_speed: 撞击速度(m/s), 越大玻璃渣越多越远
# impact_dir: 墙面法线方向, 玻璃渣主体朝这个方向散开
func configure_by_impact(impact_speed: float, impact_normal: Vector3) -> void:
	# 粒子量按速度缩放: 5 m/s → 15 颗, 20 m/s → 40 颗 (上限 50)
	amount = clampi(int(10 + impact_speed * 2.0), 10, 50)
	# 方向: 沿墙面法线外推 (玻璃渣从撞击点往外炸)
	var pm: ParticleProcessMaterial = process_material
	if pm and impact_normal.length() > 0.01:
		var n: Vector3 = impact_normal.normalized()
		pm.direction = n
		# 速度: 撞击速度的一半(不至于飞太远)
		var base_speed: float = clampf(impact_speed * 0.5, 3.0, 15.0)
		pm.initial_velocity_min = base_speed * 0.7
		pm.initial_velocity_max = base_speed * 1.3
