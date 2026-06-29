extends Node
## ============================================================
## CoopMode.gd — 双人共玩模式主控制器 (Autoload 单例)
## ============================================================
## 功能:
##   · 通过 Tuner TAB 配置开启/关闭双人模式
##   · 分屏: 左右两个 SubViewport, 分别给 1P 和 2P
##   · 1P 用键盘控制, 2P 用手柄控制
##   · 按 L 键在两名玩家之间生成/断开绳子
##   · 绳子有固定长度 + 微小弹性, 产生左右拉扯力
##   · 双 HUD 适配: 两名玩家各有独立的氮气槽/小喷灯/炫点
## ============================================================

## 双人模式是否启用 (由 Tuner 控制)
var coop_enabled: bool = false:
	set(v):
		coop_enabled = v
		if v and not _active:
			call_deferred("activate_coop")
		elif not v and _active:
			call_deferred("deactivate_coop")

## 绳子参数 (由 Tuner 控制)
var rope_length: float = 20.0          ## 绳子自然长度 (米)
var rope_stiffness: float = 200.0      ## 绳子刚度 (N/m, 弹簧系数) — 降低让绳子更柔软
var rope_damping: float = 30.0         ## 绳子阻尼 (防止无限振荡)
var rope_elasticity: float = 3.0       ## 弹性余量 (米): 超过自然长度多少才开始施力
var rope_max_force: float = 1500.0     ## 绳子最大拉力 (N) — 降低防止压制引擎
var rope_front_pull_ratio: float = 0.15 ## 前车(领先车)受到的回拉力比例 (0=前车不受影响)
var rope_rear_pull_ratio: float = 1.0   ## 后车(落后车)受到的拉力比例 (1=全力拽)
var rope_rear_steer_freedom: float = 0.7 ## 后车转向自由度 (0=完全被拽着走无法转向, 1=可以自由转向)
var rope_visual_thickness: float = 0.12 ## 绳子视觉粗细 (米)
var rope_color: Color = Color(0.9, 0.75, 0.2, 1.0)  ## 绳子颜色

## ============================================================
## 真·绳子视觉系统 (适用模式1/2, 模式3铁链有自己的金属外观)
## ============================================================
## 核心思路:
##   1. 把每段路径 (1P→锚点 / 锚点→2P) 细分成 N 个采样点
##   2. 给每个采样点加抛物线 sag (中段往下垂, 模拟松弛绳子的自然垂坠)
##   3. 维护 _rope_smoothed_points: 每帧用指数衰减朝 target 插值 (= Q 弹延迟感)
##   4. 加横向摆动 sin(t × freq) 让绳子"动起来"不像死棍
##   5. 用相邻采样点对生成 N 段细圆柱 mesh, 在 GPU 看起来就是一条平滑曲线
## 数学:
##   sag_offset(t) = -4 × t × (1-t) × sag_max   (抛物线: t=0或1时无垂坠, t=0.5时最大)
##   sag_max = max(0, natural_length - direct_distance) × sag_factor × 0.5
##   smoothed = lerp(smoothed, target, 1 - exp(-wobble_speed × dt))   (指数衰减插值)
## ============================================================
## 每段路径细分数 (越大绳子越平滑但段数越多, 8 通常够). 直道+绳子 = 8 段; 缠绕过角时每段都是 8
var rope_subdivisions: int = 10
## 垂坠强度系数 (0=完全直, 1=按松弛量原样垂, 推荐 0.3~0.7)
##   sag_max ∝ slack × sag_factor, slack = natural_length - direct_distance
##   绳子绷直时无 sag, 越松弛中段越垂
var rope_sag_factor: float = 0.5
## Q 弹收敛速度 (1/s). 越小绳子越软("过分 Q 弹"), 越大越僵硬跟手
##   alpha = 1 - exp(-wobble_speed × dt)
##   wobble_speed=15 → 物理帧 (1/240s) 内 alpha ≈ 0.06, 约 0.15s 跟到位
var rope_wobble_speed: float = 18.0
## 摆动频率 (Hz), 横向小抖. 注: 频率仅决定摆动多快, 幅度由 wobble_energy 决定
var rope_wobble_freq: float = 3.5
## 摆动幅度峰值 (米). 实际摆动 = 此值 × _rope_wobble_energy
##   _rope_wobble_energy ∈ [0, 1] 由"绳子受扰动"事件累积, 静止时自然衰减到 0
##   端点 envelope=0, 中段最大
var rope_wobble_amp: float = 0.18
## 摆动能量衰减系数 (1/s). 越大静止后停得越快
##   energy *= exp(-decay × dt) 每帧
##   decay=2.0 → 1秒后衰减到 13%, 2秒后 1.8% 几乎完全停下
##   decay=4.0 → 0.5秒衰减到 13% (停得更快)
##   推荐 1.5~3.0
var rope_wobble_decay: float = 2.0
## 摆动能量触发增益: dL/dt 转换为 energy 增量的系数
##   energy_gain = (path_len 每秒变化率, 米/秒) × trigger_gain × dt
##   trigger_gain=0.05 + dL/dt=10 m/s + dt=4ms → energy 增加 0.002
##   累积 0.5 秒大概到 energy=0.25 (中等摆动)
##   触发条件: 绳子被拽伸或车快速分开/靠近时, 路径长度变化率高 → 摆动能量上去
##   推荐 0.04~0.1
var rope_wobble_trigger_gain: float = 0.06
## 摆动能量"低速过滤阈值" (米/秒). 路径变化率 < 此值时不增加能量
##   避免日常缓慢移动也累积摆动 (用户要的"静止时完全不摆动")
##   推荐 1.0~3.0
var rope_wobble_min_trigger_speed: float = 1.5
## 内部状态: 每个采样点的"已平滑位置". 大小 = 总采样点数, 重连时清空
var _rope_smoothed_points: PackedVector3Array = PackedVector3Array()
## 摆动相位累加 (rad)
var _rope_wobble_phase: float = 0.0
## 摆动能量 (0~1). 受扰动时加, 自然衰减. 实际摆动幅度 = rope_wobble_amp × energy
var _rope_wobble_energy: float = 0.0
## 上一帧的绳子总路径长度 (米). 用于计算 dL/dt 触发摆动能量
var _rope_last_path_len: float = 0.0

## 后车卡墙摩擦削减参数 (由 Tuner 控制)
var rope_friction_mult_when_pulled: float = 0.15  ## 后车被绳子拉时的摩擦倍率 (0=无摩擦, 1=正常摩擦). 越小后车越容易被拉动
var rope_stuck_speed_threshold: float = 3.0       ## 后车速度低于此值(km/h)且绳子拉紧时, 视为卡住, 开始削减摩擦
## 防坠坑拉扯阻力: 当绳子拉力方向有向下分量 (拉向坑/低处) 时, 给后车额外的刹车阻力
## 防止队友在高处被绳子拉下坑. 值越大越不容易被拉下去
var rope_edge_resist_force: float = 800.0         ## 坠坑抵抗力 (N), 当拉力方向向下时施加反向制动
var rope_edge_resist_y_threshold: float = -0.15   ## 拉力方向 Y 分量低于此值时触发 (越负=越陡才触发)
var rope_edge_resist_speed_cap: float = 8.0       ## 只有后车速度(km/h)低于此值时才施加抵抗 (高速行驶中不触发)

## 绳子缠绕系统参数 (由 Tuner 控制)
var rope_wrap_enabled: bool = true          ## 绳子缠绕开关 (true=绳子沿墙面缠绕, false=绳子可穿墙)
var rope_wrap_offset: float = 1.5           ## 锚点离墙面的偏移距离 (米), 越大绳子越远离墙面
var rope_wrap_max_anchors: int = 20         ## 最大缠绕锚点数量
var rope_wrap_min_spacing: float = 2.0      ## 锚点之间的最小间距 (米), 防止重复添加
var rope_wrap_min_seg_len: float = 0.5      ## 最短段检测阈值 (米), 太短的段不检测

## ============================================================
## 绳子模式2: 距离档位系统 (5档颜色 + 效果)
## ============================================================
## 模式2总开关 (由 Tuner 控制)
var rope_mode2_enabled: bool = false
## 5档距离阈值 (米): 两车距离 < 阈值[i] 则为第 i+1 档
## 档位1(最近/绿色) → 档位5(最远/红色)
var rope_mode2_dist_1: float = 8.0    ## 距离 < 此值 = 1档(绿色)
var rope_mode2_dist_2: float = 15.0   ## 距离 < 此值 = 2档(黄绿)
var rope_mode2_dist_3: float = 22.0   ## 距离 < 此值 = 3档(黄色)
var rope_mode2_dist_4: float = 30.0   ## 距离 < 此值 = 4档(橙色)
## 距离 >= dist_4 = 5档(红色)

## 1档效果: 自动集气 (每秒给两车增加 charge 点数)
var rope_mode2_tier1_charge_per_sec: float = 30.0
## 2档效果: 两车获得速度加成倍率
var rope_mode2_tier2_speed_mult: float = 1.05
## 3档效果: 无特殊效果 (中性档位)
## 4档效果: 后车获得轻微前车拉力
var rope_mode2_tier4_pull_force: float = 500.0
## 5档效果: 后车获得强力前车拉力 (类似原版绳子拉扯)
var rope_mode2_tier5_pull_force: float = 1500.0

## 5档颜色 (由 Tuner 控制, 默认绿→红渐变)
var rope_mode2_color_1: Color = Color(0.0, 1.0, 0.2, 1.0)   ## 1档: 绿色
var rope_mode2_color_2: Color = Color(0.5, 1.0, 0.0, 1.0)   ## 2档: 黄绿
var rope_mode2_color_3: Color = Color(1.0, 1.0, 0.0, 1.0)   ## 3档: 黄色
var rope_mode2_color_4: Color = Color(1.0, 0.5, 0.0, 1.0)   ## 4档: 橙色
var rope_mode2_color_5: Color = Color(1.0, 0.1, 0.0, 1.0)   ## 5档: 红色

## 内部状态: 当前档位 (1~5, 0=未激活)
var _rope_mode2_current_tier: int = 0

## ============================================================
## 绳子模式3: 毒图铁链 (Hardcore Iron Chain) — 完全无弹性 + 双向 1:1 拉拽
## ============================================================
## 设计目标: 给"毒图"专用的高难度绳子玩法
##   · 铁链 = 完全没有弹性, 链长是硬上限
##   · 两车距离 d > rope_length3 时, 用 PBD (Position Based Dynamics) 风格的位置硬约束
##     直接把两车沿绳方向拉近到 rope_length3, 同时反向折算到速度
##   · 不分前/后车, 双向 1:1 等量拉拽 → 急转/急刹会瞬间把另一车鞭甩出去
##   · 数学 (PBD 距离约束):
##       n = (pos_a - pos_b).normalized()
##       error = d - rope_length3                              ; 当前超出量
##       correction = error / 2                                ; 每车承担一半 (1:1 = 双向同权)
##       pos_a' = pos_a - n * correction                       ; a 朝 b 拉近
##       pos_b' = pos_b + n * correction                       ; b 朝 a 拉近
##     额外把"沿绳方向的远离速度"投影掉, 模拟链子绷直瞬间的能量传递 (鞭甩)
## ============================================================
## 模式3总开关 (与 mode2 互斥, 同时只有一个激活)
var rope_mode3_enabled: bool = false
## 铁链长度 (米). 这是硬上限, 两车不可能距离超过此值
## 数学: 每物理帧检测 |pos_a - pos_b|, 超了就强行拉回
var rope_mode3_length: float = 18.0
## 动量耦合开关 (旧名: 鞭甩开关): 1=启用沿绳速度强制相等(真·铁链, 互相扯), 0=只做位置约束(可能仍可独立行动)
var rope_mode3_whip_enabled: bool = true
## 收敛速度全局倍率 (0~1) — 对 rope_mode3_pull_rate 的整体缩放
##   1.0 = 用 pull_rate 原值收敛 (标准)
##   0.5 = 收敛速度减半 (拽得更慢, 后车追前车需要更长时间)
##   0.0 = 完全不耦合 (退化为只有位置硬约束 + jerk)
## 旧版本这是"瞬间耦合强度", 新版本改为"渐进收敛速率倍率"
var rope_mode3_whip_strength: float = 1.0
## 张力收敛速率 (1/s) — 真·铁链拽的核心参数
## 物理意义: 一阶低通滤波器的衰减常数, 时间常数 τ = 1/pull_rate
##   pull_rate=6.0 → τ≈0.17s, 95% 收敛 ≈ 0.5s, 99.7% 收敛 ≈ 1s
##   pull_rate=3.0 → τ≈0.33s, 拽得明显更慢更"沉"
##   pull_rate=15.0 → τ≈0.07s, 几乎瞬间同速
## 数学:
##   每物理帧 alpha = 1 - exp(-pull_rate × dt)
##   后车沿绳速度 += (前车沿绳速度 - 后车沿绳速度) × alpha
##   等价于一阶 ODE: dv_rear/dt = pull_rate × (v_front - v_rear)
## 推荐 4~10. 配合 whip_strength 全局调整
var rope_mode3_pull_rate: float = 6.0
## 前车反作用系数 (0~1) — 后车的"重量感"传递回前车的比例
##   0.0 = 前车完全不被拖累, 开车人体验最爽 (推荐默认)
##   0.1 = 前车微微被拖慢 10% 速度差, 略有"拽东西"重量感
##   1.0 = 完全动量守恒 (前车减速等量于后车加速, 但开车人会觉得"开不动")
## 物理意义: 前车朝"后车速度"方向收敛的比例
## 数学: v_front' = v_front + (v_rear - v_front) × alpha × front_drag_ratio
## 推荐 0~0.2 (毒图玩法本来就要让带头开的人能开起来)
var rope_mode3_front_drag_ratio: float = 0.05
## 链节绷直瞬间的反向冲量 (m/s² × mass): 模拟铁链"咣当"撞击感
## 关键: 只在"从松弛刚绷紧"那一瞬间触发一次, 不会每帧累加
##   _was_taut=false → true 时触发一次, 持续绷紧时不再触发
##   这样避免"每帧都给减速冲量把车按死"的问题
##   推荐 0~6: 0=完全无冲量(纯位置+主导拽), 3=轻微撞击, 6=明显甩动感
var rope_mode3_jerk_impulse: float = 3.0
## 视觉: 链节段数 (越多越像铁链, 越少越像棍子)
var rope_mode3_chain_segments: int = 12
## 视觉: 单个链节粗细 (米)
var rope_mode3_chain_thickness: float = 0.18
## 视觉: 铁链颜色 (默认银灰金属色)
var rope_mode3_chain_color: Color = Color(0.55, 0.58, 0.62, 1.0)
## 视觉: 链节金属感 emission (低值, 仅在阴影里有点反光)
var rope_mode3_chain_emission: float = 0.15
## 内部: 缓存上一帧的链节透明状态, 避免重复刷新材质
var _mode3_chain_segments_cache: Array[MeshInstance3D] = []
## 内部: 上一帧链子是否绷紧 (用于"刚绷紧瞬间"检测, 防止每帧重复 jerk)
##   每帧检查 error > 0.05 → 本帧绷紧
##   was_taut=false → 本帧绷紧 = "刚绷紧" 触发一次 jerk
##   was_taut=true 持续绷紧 → 不再 jerk
##   was_taut=true 本帧松弛 → 重置 was_taut=false (链子恢复松弛, 等待下次绷紧)
var _rope_mode3_was_taut: bool = false

## 模式2集气粒子特效参数 (Tuner 可调)
var rope_mode2_charge_particle_count: int = 40       ## 粒子数量
var rope_mode2_charge_particle_radius: float = 2.5   ## 发射球半径 (粒子从多远聚合)
var rope_mode2_charge_particle_speed: float = 3.0    ## 粒子聚合速度
var rope_mode2_charge_particle_size: float = 0.08    ## 粒子大小
var rope_mode2_charge_particle_color: Color = Color(0.3, 0.6, 1.0, 0.9)  ## 粒子颜色 (蓝色)

## ============================================================
## 模式2: 尾流能量系统 (后车尾随前车积累能量, 满后可突进)
## ============================================================
## 尾流能量参数 (Tuner 可调)
var rope_mode2_slipstream_enabled: bool = true        ## 尾流能量系统开关
var rope_mode2_slipstream_max_energy: float = 100.0   ## 尾流能量上限
var rope_mode2_slipstream_charge_rate: float = 25.0   ## 尾流能量积累速度 (每秒)
var rope_mode2_slipstream_decay_rate: float = 10.0    ## 不在尾流中时能量衰减速度 (每秒)
var rope_mode2_slipstream_min_dist: float = 3.0       ## 尾流生效最小距离 (米, 太近不算尾流)
var rope_mode2_slipstream_max_dist: float = 25.0      ## 尾流生效最大距离 (米, 太远不算尾流)
var rope_mode2_slipstream_angle_threshold: float = 45.0  ## 尾流角度阈值 (度): 后车必须在前车身后此角度范围内
var rope_mode2_slipstream_boost_power: float = 800.0  ## 尾流突进推力
var rope_mode2_slipstream_boost_duration: float = 1.5 ## 尾流突进持续时间 (秒)
var rope_mode2_slipstream_boost_cooldown: float = 2.0 ## 尾流突进冷却时间 (秒, 突进后多久才能再次积累)

## 尾流能量内部状态
var _slipstream_energy_1p: float = 0.0   ## 1P 的尾流能量
var _slipstream_energy_2p: float = 0.0   ## 2P 的尾流能量
var _slipstream_cooldown_1p: float = 0.0 ## 1P 突进冷却剩余时间
var _slipstream_cooldown_2p: float = 0.0 ## 2P 突进冷却剩余时间
var _slipstream_particles_1p: GPUParticles3D = null  ## 1P 尾流粒子特效
var _slipstream_particles_2p: GPUParticles3D = null  ## 2P 尾流粒子特效

## 内部状态: 集气粒子特效
var _charge_particles_1p: GPUParticles3D = null
var _charge_particles_2p: GPUParticles3D = null

## 绳子缠绕系统内部状态
var _rope_wrap_points: Array[Vector3] = []  ## 绳子缠绕锚点列表 (沿墙面的拐点)
var _rope_total_length: float = 0.0         ## 绳子当前总路径长度 (含缠绕)
var _rope_has_penetration: bool = false     ## 绳子当前是否有穿墙段 (true=有穿墙, 不施加拉力)

## 内部状态
var _active: bool = false              ## 当前是否在双人模式运行中
var _car_1p: RigidBody3D = null        ## 1P 赛车引用
var _car_2p: RigidBody3D = null        ## 2P 赛车引用
var _rope_connected: bool = false      ## 绳子是否已连接
var _rope_segments: Array[MeshInstance3D] = []  ## 绳子各段的视觉 mesh
var _rope_mat: StandardMaterial3D = null

## 分屏节点
var _viewport_1p: SubViewport = null
var _viewport_2p: SubViewport = null
var _camera_1p: Camera3D = null
var _camera_2p: Camera3D = null
var _canvas_layer: CanvasLayer = null
var _hbox: HBoxContainer = null

## HUD 节点
var _hud_1p: CanvasLayer = null        ## 1P 的 HUD (左半屏)
var _hud_2p: CanvasLayer = null        ## 2P 的 HUD (右半屏)
var _original_hud: CanvasLayer = null  ## 原始 HUD (隐藏)

## 绳索救援 (按键拉队友飞到自己身边) 状态
## 语义: 1P按ALT → 把2P拉到1P身边 (救援队友); 2P按手柄A → 把1P拉到2P身边
var _follow_active: bool = false          ## 是否正在救援飞行中
var _follow_src: RigidBody3D = null        ## 正在被拉过来的车 (队友)
var _follow_target: RigidBody3D = null     ## 发起救援的车 (自己, 用于实时获取位置)
var _follow_start_pos: Vector3 = Vector3.ZERO  ## 被救队友的起始位置
var _follow_target_pos: Vector3 = Vector3.ZERO ## 目标位置 (发起者当前位置)
var _follow_start_basis: Basis = Basis.IDENTITY ## 被救队友的起始朝向
var _follow_elapsed: float = 0.0          ## 已飞行时间
var _follow_duration: float = 0.5         ## 飞行总时长 (秒)
var _follow_initiator_is_1p: bool = true  ## true=1P发起救援, false=2P发起救援
## 救援 UI (现在通过 _hud_1p/_hud_2p 各自显示, 不再用全局 CanvasLayer)
## 救援期间绳索变色: 保存原始绳子颜色 (结束后恢复)
var _rescue_rope_orig_color: Color = Color.WHITE
var _rescue_rope_orig_emission: bool = false
var _rescue_rope_orig_emission_color: Color = Color.BLACK
var _rescue_rope_orig_emission_energy: float = 0.0

## 原始场景备份
var _original_camera: Camera3D = null


func _ready() -> void:
	set_process(false)
	set_physics_process(false)
	add_to_group("coop_mode")


func _input(event: InputEvent) -> void:
	# L 键: 连接/断开绳子
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_L and _active and _car_1p and _car_2p:
			_toggle_rope()

	# 绳索救援: 按下时把队友拉到自己身边 (仅绳子连接时可用)
	if _active and _rope_connected and _car_1p and _car_2p and not _follow_active:
		# 1P (键盘 ALT): 1P 发起救援 → 把 2P 拉到 1P 身边
		if event is InputEventKey and event.pressed and not event.echo:
			if event.keycode == KEY_ALT or event.physical_keycode == KEY_ALT:
				_start_rescue(_car_2p, _car_1p, true)
		# 2P (手柄 A): 2P 发起救援 → 把 1P 拉到 2P 身边
		if event.is_action_pressed("p2_rope_follow") and not event.is_echo():
			_start_rescue(_car_1p, _car_2p, false)

	# 尾流突进: 模式2下后车能量满时按键触发
	if _active and _rope_connected and rope_mode2_enabled and rope_mode2_slipstream_enabled:
		if event is InputEventKey and event.pressed and not event.echo:
			# 1P (键盘 1): 1P 尾流突进
			if event.keycode == KEY_1:
				_try_slipstream_boost(_car_1p, true)
		# 2P (手柄 Z键/LB): 2P 尾流突进
		if event.is_action_pressed("p2_slipstream_boost") and not event.is_echo():
			_try_slipstream_boost(_car_2p, false)


func _physics_process(delta: float) -> void:
	if not _active:
		return
	if _car_1p == null or _car_2p == null:
		return
	# 追随飞行更新 (优先于绳子物理)
	if _follow_active:
		_update_follow(delta)
	# 绳子物理
	if _rope_connected and not _follow_active:
		if rope_mode3_enabled:
			# 模式3 (毒图铁链): 优先级最高, 与 mode2 互斥
			# 与 mode2 一样, 它接管整段拉力, 不再走弹簧 mode1
			_apply_rope_mode3(delta)
			_hide_slipstream_hud()
		elif rope_mode2_enabled:
			_apply_rope_mode2(delta)
			# 尾流能量系统更新
			if rope_mode2_slipstream_enabled:
				_update_slipstream_energy(delta)
				_update_slipstream_hud()
			else:
				_hide_slipstream_hud()
		else:
			_apply_rope_physics(delta)
			_hide_slipstream_hud()
		_update_rope_visual()
		_check_rope_star_collection()
	elif not _rope_connected:
		_hide_slipstream_hud()


## 激活双人模式 (由 Tuner 或外部调用)
func activate_coop() -> void:
	if _active:
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	# 查找当前场景中的赛车
	_car_1p = _find_car_in_scene()
	if _car_1p == null:
		push_warning("[CoopMode] 找不到 1P 赛车, 无法启动双人模式")
		return
	# 设置 1P 的 player_id
	if "player_id" in _car_1p:
		_car_1p.set("player_id", 0)
	# 实例化 2P 赛车
	_spawn_2p_car()
	# 设置分屏
	_setup_split_screen()
	# 设置双 HUD
	_setup_dual_hud()
	_active = true
	set_process(true)
	set_physics_process(true)
	print("[CoopMode] 双人模式已激活!")


## 停用双人模式
func deactivate_coop() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	set_physics_process(false)
	_rope_connected = false
	_cleanup_split_screen()
	_cleanup_dual_hud()
	_cleanup_2p_car()
	_cleanup_rope_visual()
	_cleanup_charge_particles()
	_reset_slipstream()
	print("[CoopMode] 双人模式已停用")


## 查找场景中的赛车
func _find_car_in_scene() -> RigidBody3D:
	var root: Node = get_tree().current_scene
	if root == null:
		return null
	return _find_car_recursive(root)


func _find_car_recursive(node: Node) -> RigidBody3D:
	if node is RigidBody3D and "throttle_input" in node:
		return node as RigidBody3D
	for child in node.get_children():
		var result: RigidBody3D = _find_car_recursive(child)
		if result != null:
			return result
	return null


## 实例化 2P 赛车
func _spawn_2p_car() -> void:
	var car_scene: PackedScene = load("res://core/car.tscn") as PackedScene
	if car_scene == null:
		push_error("[CoopMode] 无法加载 car.tscn")
		return
	_car_2p = car_scene.instantiate() as RigidBody3D
	# 设置 2P 的 player_id
	if "player_id" in _car_2p:
		_car_2p.set("player_id", 1)
	# 禁用 2P 的 Tuner 和 HUD 自动生成 (CoopMode 自己管 HUD)
	if "auto_spawn_tuner" in _car_2p:
		_car_2p.set("auto_spawn_tuner", false)
	if "auto_spawn_hud" in _car_2p:
		_car_2p.set("auto_spawn_hud", false)
	# 添加到场景树 (触发 _ready)
	get_tree().current_scene.add_child(_car_2p)
	# 冻结 2P 物理, 防止在 _finalize_2p_spawn 完成前自由落体
	_car_2p.freeze = true
	# ---- 同步 1P 的所有 3C 参数到 2P (在 add_child 之后, _ready 已完成) ----
	_sync_car_params(_car_1p, _car_2p)
	# 延迟执行位置/朝向设置和运行时状态初始化
	# 等待 TrackSetup 对 1P 完成 _adjust_car_spawn 后再设置 2P 的位置
	call_deferred("_finalize_2p_spawn")


## 延迟完成 2P 赛车的位置/朝向设置
## 等待 TrackSetup._adjust_car_spawn 完成后 (它 await 了两帧物理),
## 再把 2P 放到 1P 旁边, 确保位置和朝向都正确
func _finalize_2p_spawn() -> void:
	if _car_1p == null or _car_2p == null:
		return
	# 再等几帧, 确保 TrackSetup._adjust_car_spawn 已完成 (它 await 两帧物理)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _car_1p == null or _car_2p == null:
		return

	# 获取 1P 的最终位置和朝向 (TrackSetup 已经把 1P 落到地面了)
	var car_mesh_1p: Node3D = _car_1p.get_node_or_null("CarMesh")
	var car_mesh_2p: Node3D = _car_2p.get_node_or_null("CarMesh")
	if car_mesh_1p == null or car_mesh_2p == null:
		push_error("[CoopMode] 找不到 CarMesh 节点")
		return

	# 计算 2P 的生成位置: 在 1P 右侧 5m (沿 1P 的本地 X 轴)
	var right_dir: Vector3 = car_mesh_1p.global_transform.basis.x.normalized()
	var spawn_offset: Vector3 = right_dir * 5.0
	var spawn_pos_mesh: Vector3 = car_mesh_1p.global_position + spawn_offset
	var sphere_off: Vector3 = _car_2p.get("sphere_offset") if "sphere_offset" in _car_2p else Vector3.DOWN

	# 设置 2P 刚体位置
	_car_2p.global_position = spawn_pos_mesh - sphere_off
	_car_2p.linear_velocity = Vector3.ZERO
	_car_2p.angular_velocity = Vector3.ZERO

	# 设置 2P CarMesh 位置和朝向 (与 1P 完全一致)
	car_mesh_2p.global_position = spawn_pos_mesh
	car_mesh_2p.global_transform.basis = car_mesh_1p.global_transform.basis

	# 重新记录 2P 的出生点 (覆盖 _ready 中记录的高空位置)
	# 直接设置内部变量确保出生点一定正确 (不依赖 has_method 的行为)
	_car_2p.set("_initial_car_mesh_position", car_mesh_2p.global_position)
	_car_2p.set("_initial_car_mesh_basis", car_mesh_2p.global_transform.basis)
	_car_2p.set("_initial_recorded", true)
	print("[CoopMode] 2P 出生点已强制设置: pos=%s" % str(car_mesh_2p.global_position))

	# 重新初始化 2P 的运行时状态
	_reinit_runtime_state(_car_2p)

	# ---- 同步 1P 子节点的参数到 2P 子节点 ----
	# Tuner 加载 cfg 时 2P 还不存在, 所以 grapple/car_mesh/boost_fx 参数只应用到了 1P
	# 这里从 1P 的子节点复制所有 @export 属性到 2P 的对应子节点
	_sync_child_node_params(_car_1p, _car_2p, "GrappleHook")
	_sync_child_node_params(_car_1p, _car_2p, "CarMesh")
	# BoostFX 挂在 CarMesh 下面, 需要遍历同步
	_sync_boost_fx_params(_car_1p, _car_2p)

	# 解冻 2P 物理 (位置和朝向已设置完毕)
	_car_2p.freeze = false
	# 强制重置 2P 的空中状态 (防止 freeze 期间被错误标记为 airborne)
	_car_2p.set("_is_airborne", false)

	# 初始化分屏摄像机位置 (避免从 (0,0,0) 开始 lerp 的视觉跳变)
	if _camera_1p and car_mesh_1p and "offset" in _camera_1p:
		var cam_target: Transform3D = car_mesh_1p.global_transform.translated_local(_camera_1p.offset)
		_camera_1p.global_position = cam_target.origin
		_camera_1p.look_at(car_mesh_1p.global_position, Vector3.UP)
	if _camera_2p and car_mesh_2p and "offset" in _camera_2p:
		var cam_target: Transform3D = car_mesh_2p.global_transform.translated_local(_camera_2p.offset)
		_camera_2p.global_position = cam_target.origin
		_camera_2p.look_at(car_mesh_2p.global_position, Vector3.UP)

	print("[CoopMode] 2P 赛车已生成, 位置: %s, 朝向与 1P 一致" % str(spawn_pos_mesh))


## 重新初始化赛车的运行时状态 (在参数同步后调用)
func _reinit_runtime_state(car: RigidBody3D) -> void:
	if car == null:
		return
	# 重新初始化氮气存量 (用同步后的 spawn_nitro_stock)
	if "spawn_nitro_enabled" in car and "spawn_nitro_stock" in car and "max_nitro_stock" in car:
		if car.spawn_nitro_enabled:
			car.nitro_stock = mini(car.spawn_nitro_stock, car.max_nitro_stock)
			if car.has_signal("nitro_stock_changed"):
				car.emit_signal("nitro_stock_changed", car.nitro_stock, car.max_nitro_stock)
	# 重新初始化曲线 (如果同步后曲线为 null, 用默认曲线)
	if car.has_method("_init_default_curves"):
		car._init_default_curves()


## 将 src 赛车的所有 @export 属性同步到 dst 赛车 (3C 参数完全一致)
func _sync_car_params(src: RigidBody3D, dst: RigidBody3D) -> void:
	if src == null or dst == null:
		return
	var synced_count: int = 0
	for prop_info in src.get_property_list():
		var prop_name: String = prop_info["name"]
		if prop_name in ["player_id", "global_position", "global_rotation", "position", "rotation", "transform", "global_transform"]:
			continue
		var usage: int = prop_info["usage"]
		if not (usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR):
			continue
		if prop_name in ["script", "name", "owner", "scene_file_path", "unique_name_in_owner"]:
			continue
		if prop_name in dst:
			var val = src.get(prop_name)
			if val is Curve:
				val = val.duplicate() if val != null else null
			dst.set(prop_name, val)
			synced_count += 1
	print("[CoopMode] 已同步 %d 个参数从 1P → 2P" % synced_count)


## 同步指定子节点的所有 @export 属性 (从 1P 的子节点复制到 2P 的同名子节点)
func _sync_child_node_params(src_car: RigidBody3D, dst_car: RigidBody3D, child_name: String) -> void:
	if src_car == null or dst_car == null:
		return
	var src_node: Node = src_car.get_node_or_null(child_name)
	var dst_node: Node = dst_car.get_node_or_null(child_name)
	if src_node == null or dst_node == null:
		return
	var synced: int = 0
	for prop_info in src_node.get_property_list():
		var prop_name: String = prop_info["name"]
		if prop_name in ["script", "name", "owner", "position", "rotation", "transform", "global_transform", "global_position", "global_rotation"]:
			continue
		var usage: int = prop_info["usage"]
		if not (usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR):
			continue
		if prop_name in dst_node:
			var val = src_node.get(prop_name)
			if val is Curve:
				val = val.duplicate() if val != null else null
			dst_node.set(prop_name, val)
			synced += 1
	if synced > 0:
		print("[CoopMode] 已同步 %s 的 %d 个参数到 2P" % [child_name, synced])


## 同步 BoostFX 参数 (BoostFX 挂在 CarMesh/tailpipe 下面, 可能有多个)
func _sync_boost_fx_params(src_car: RigidBody3D, dst_car: RigidBody3D) -> void:
	if src_car == null or dst_car == null:
		return
	var src_mesh: Node = src_car.get_node_or_null("CarMesh")
	var dst_mesh: Node = dst_car.get_node_or_null("CarMesh")
	if src_mesh == null or dst_mesh == null:
		return
	# 递归收集所有 BoostFX 节点 (通过检查是否有 "boost_speed" 属性来识别)
	var src_fx_list: Array = []
	var dst_fx_list: Array = []
	_collect_boost_fx_recursive(src_mesh, src_fx_list)
	_collect_boost_fx_recursive(dst_mesh, dst_fx_list)
	# 按索引一一对应同步
	var count: int = mini(src_fx_list.size(), dst_fx_list.size())
	if count == 0:
		return
	for i in range(count):
		var src_fx: Node = src_fx_list[i]
		var dst_fx: Node = dst_fx_list[i]
		for prop_info in src_fx.get_property_list():
			var prop_name: String = prop_info["name"]
			if prop_name in ["script", "name", "owner", "position", "rotation", "transform", "global_transform"]:
				continue
			var usage: int = prop_info["usage"]
			if not (usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR):
				continue
			if prop_name in dst_fx:
				var val = src_fx.get(prop_name)
				if val is Curve:
					val = val.duplicate() if val != null else null
				dst_fx.set(prop_name, val)
	print("[CoopMode] 已同步 %d 个 BoostFX 节点的参数到 2P" % count)


## 递归收集所有 BoostFX 节点 (通过脚本路径 "BoostFX.gd" 识别, 与 Tuner 一致)
func _collect_boost_fx_recursive(node: Node, out: Array) -> void:
	for child in node.get_children():
		var s: Script = child.get_script() as Script
		if s != null and str(s.resource_path).ends_with("BoostFX.gd"):
			out.append(child)
		else:
			_collect_boost_fx_recursive(child, out)


## ============================================================
##  分屏设置
##  设计: CanvasLayer layer=-1 (在 HUD/Tuner/SceneSelector 之下)
##  所有 Control 节点 mouse_filter=IGNORE (不拦截输入)
##  Tuner(layer=1) / HUD(layer=1) / SceneSelector(layer=10) 正常显示在最上层
## ============================================================
func _setup_split_screen() -> void:
	# 保存原始摄像机
	_original_camera = get_viewport().get_camera_3d()
	if _original_camera:
		_original_camera.current = false

	# 创建 CanvasLayer 用于分屏渲染 (layer=-1, 在所有 UI 之下)
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.name = "CoopSplitScreen"
	_canvas_layer.layer = -1
	get_tree().current_scene.add_child(_canvas_layer)

	# 创建水平分割容器 (不拦截鼠标)
	_hbox = HBoxContainer.new()
	_hbox.name = "SplitHBox"
	_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hbox.add_theme_constant_override("separation", 4)
	_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_layer.add_child(_hbox)

	# 1P SubViewportContainer + SubViewport
	var vpc_1p := SubViewportContainer.new()
	vpc_1p.name = "VPC_1P"
	vpc_1p.stretch = true
	vpc_1p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc_1p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc_1p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hbox.add_child(vpc_1p)

	_viewport_1p = SubViewport.new()
	_viewport_1p.name = "Viewport_1P"
	_viewport_1p.handle_input_locally = false
	_viewport_1p.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vpc_1p.add_child(_viewport_1p)

	# 2P SubViewportContainer + SubViewport
	var vpc_2p := SubViewportContainer.new()
	vpc_2p.name = "VPC_2P"
	vpc_2p.stretch = true
	vpc_2p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vpc_2p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vpc_2p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hbox.add_child(vpc_2p)

	_viewport_2p = SubViewport.new()
	_viewport_2p.name = "Viewport_2P"
	_viewport_2p.handle_input_locally = false
	_viewport_2p.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vpc_2p.add_child(_viewport_2p)

	# 为每个 viewport 创建摄像机 (使用与单人模式完全一致的 Camera3D.gd 脚本)
	var cam_script: GDScript = load("res://core/Camera3D.gd") as GDScript
	var car_mesh_1p: Node3D = _car_1p.get_node_or_null("CarMesh") if _car_1p else null
	var car_mesh_2p: Node3D = _car_2p.get_node_or_null("CarMesh") if _car_2p else null

	_camera_1p = Camera3D.new()
	_camera_1p.name = "Camera_1P"
	_camera_1p.current = true
	if cam_script:
		_camera_1p.set_script(cam_script)
		# 复制原始摄像机的参数 (如果有)
		if _original_camera and _original_camera.get_script() == cam_script:
			_copy_camera_params(_original_camera, _camera_1p)
		_camera_1p.target = car_mesh_1p
	_viewport_1p.add_child(_camera_1p)

	_camera_2p = Camera3D.new()
	_camera_2p.name = "Camera_2P"
	_camera_2p.current = true
	if cam_script:
		_camera_2p.set_script(cam_script)
		if _original_camera and _original_camera.get_script() == cam_script:
			_copy_camera_params(_original_camera, _camera_2p)
		_camera_2p.target = car_mesh_2p
	_viewport_2p.add_child(_camera_2p)

	# 将场景的 World3D 共享给两个 viewport
	var world: World3D = get_tree().current_scene.get_viewport().world_3d
	_viewport_1p.world_3d = world
	_viewport_2p.world_3d = world

	# 中间分割线 (纯视觉装饰, 使用锚点自适应窗口大小)
	var sep := ColorRect.new()
	sep.name = "SplitLine"
	sep.color = Color(0.15, 0.15, 0.2, 0.9)
	# 锚点: 水平居中 (0.5), 垂直铺满 (0~1)
	sep.anchor_left = 0.5
	sep.anchor_right = 0.5
	sep.anchor_top = 0.0
	sep.anchor_bottom = 1.0
	# offset: 左右各偏移2px (总宽4px), 上下为0 (铺满)
	sep.offset_left = -2
	sep.offset_right = 2
	sep.offset_top = 0
	sep.offset_bottom = 0
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_layer.add_child(sep)

	print("[CoopMode] 分屏已设置 (layer=-1, 不遮挡 Tuner/HUD)")


## ============================================================
##  双 HUD 适配
##  设计:
##   · 隐藏原始 HUD (它是全屏布局, 不适合分屏)
##   · 为 1P 和 2P 各创建一个 HUD 实例
##   · 1P HUD 定位到左半屏, 2P HUD 定位到右半屏
##   · 两个 HUD 各自连接到对应的赛车, 独立显示氮气/小喷灯/炫点
## ============================================================
func _setup_dual_hud() -> void:
	# 隐藏原始 HUD
	_original_hud = get_tree().current_scene.find_child("HUD", true, false) as CanvasLayer
	if _original_hud:
		_original_hud.visible = false

	var hud_scene: PackedScene = load("res://ui/HUD.tscn") as PackedScene
	if hud_scene == null:
		push_warning("[CoopMode] 无法加载 HUD.tscn, 跳过 HUD 适配")
		return

	# 创建 1P HUD (左半屏)
	_hud_1p = hud_scene.instantiate() as CanvasLayer
	_hud_1p.name = "HUD_1P"
	_hud_1p.layer = 2  # 在分屏之上, 但在 Tuner/SceneSelector 之下
	get_tree().current_scene.add_child(_hud_1p)
	_hud_1p.car_path = _hud_1p.get_path_to(_car_1p)
	# 调整 1P HUD Root 控件到左半屏
	_adapt_hud_to_half(_hud_1p, true)
	# 注: HUD._ready 中已有 call_deferred("_connect_to_car"), car_path 在同帧内设置完毕

	# 创建 2P HUD (右半屏)
	_hud_2p = hud_scene.instantiate() as CanvasLayer
	_hud_2p.name = "HUD_2P"
	_hud_2p.layer = 2
	get_tree().current_scene.add_child(_hud_2p)
	_hud_2p.car_path = _hud_2p.get_path_to(_car_2p)
	# 调整 2P HUD Root 控件到右半屏
	_adapt_hud_to_half(_hud_2p, false)

	# 延迟同步: HUD 的 _connect_to_car 是 deferred 的, 需要等它完成后再触发状态同步
	# 等 2 帧确保 HUD 信号连接完毕, 然后让两辆车重新发出当前状态信号
	call_deferred("_deferred_sync_hud_state")

	print("[CoopMode] 双 HUD 已设置 (1P=左半屏, 2P=右半屏)")


## 延迟同步 HUD 状态: 让两辆车重新发出当前氮气/集气等信号, 确保 HUD 显示正确
func _deferred_sync_hud_state() -> void:
	# 再等一帧, 确保 HUD._connect_to_car 的 deferred 调用已完成
	await get_tree().process_frame
	await get_tree().process_frame
	# 让两辆车重新发出当前状态信号
	if _car_1p and "nitro_stock" in _car_1p and "max_nitro_stock" in _car_1p:
		_car_1p.emit_signal("nitro_stock_changed", _car_1p.nitro_stock, _car_1p.max_nitro_stock)
	if _car_2p and "nitro_stock" in _car_2p and "max_nitro_stock" in _car_2p:
		_car_2p.emit_signal("nitro_stock_changed", _car_2p.nitro_stock, _car_2p.max_nitro_stock)
	# 同步集气槽
	if _car_1p and _car_1p.has_signal("charge_changed"):
		var charge: float = _car_1p.get("_drift_charge") if "_drift_charge" in _car_1p else 0.0
		var max_charge: float = _car_1p.get("charge_nitro_full") if "charge_nitro_full" in _car_1p else 100.0
		_car_1p.emit_signal("charge_changed", charge, max_charge)
	if _car_2p and _car_2p.has_signal("charge_changed"):
		var charge: float = _car_2p.get("_drift_charge") if "_drift_charge" in _car_2p else 0.0
		var max_charge: float = _car_2p.get("charge_nitro_full") if "charge_nitro_full" in _car_2p else 100.0
		_car_2p.emit_signal("charge_changed", charge, max_charge)
	print("[CoopMode] HUD 状态已同步 (1P nitro=%d, 2P nitro=%d)" % [
		_car_1p.nitro_stock if _car_1p and "nitro_stock" in _car_1p else -1,
		_car_2p.nitro_stock if _car_2p and "nitro_stock" in _car_2p else -1
	])


## 将 HUD 的 Root 控件适配到半屏
## is_left: true=左半屏, false=右半屏
func _adapt_hud_to_half(hud: CanvasLayer, is_left: bool) -> void:
	var root: Control = hud.get_node_or_null("Root")
	if root == null:
		return
	# 取消全屏 preset, 改为手动设置锚点到半屏
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	if is_left:
		# 左半屏: anchor_right = 0.5
		root.anchor_left = 0.0
		root.anchor_right = 0.5
	else:
		# 右半屏: anchor_left = 0.5
		root.anchor_left = 0.5
		root.anchor_right = 1.0
	root.anchor_top = 0.0
	root.anchor_bottom = 1.0
	root.offset_left = 0
	root.offset_right = 0
	root.offset_top = 0
	root.offset_bottom = 0
	# 不拦截鼠标 (让 Tuner 的 TAB 面板可以正常操作)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_mouse_ignore_recursive(root)

	# 缩小字体和 UI 元素以适配半屏宽度
	# 速度表
	var speed_label: Label = hud.get_node_or_null("Root/SpeedBox/SpeedLabel")
	if speed_label:
		speed_label.add_theme_font_size_override("font_size", 52)
	# 集气槽
	var charge_box: VBoxContainer = hud.get_node_or_null("Root/ChargeBox")
	if charge_box:
		# 缩小集气槽宽度
		charge_box.offset_left = -140
		charge_box.offset_right = 140
	# 操作提示 (分屏下隐藏, 太占空间)
	var help_label: Label = hud.get_node_or_null("Root/HelpLabel")
	if help_label:
		help_label.visible = false
	# 署名 (分屏下隐藏)
	var sig_label: Label = hud.get_node_or_null("Root/SignatureLabel")
	if sig_label:
		sig_label.visible = false

	# 添加玩家标识 (左上角显示 "1P" 或 "2P")
	var player_tag := Label.new()
	player_tag.name = "PlayerTag"
	player_tag.text = "1P" if is_left else "2P"
	player_tag.add_theme_font_size_override("font_size", 28)
	player_tag.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3, 0.9) if is_left else Color(0.3, 0.9, 1.0, 0.9))
	player_tag.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	player_tag.add_theme_constant_override("outline_size", 4)
	player_tag.position = Vector2(10, 10)
	root.add_child(player_tag)


## 递归设置所有 Control 子节点的 mouse_filter 为 IGNORE
func _set_mouse_ignore_recursive(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_set_mouse_ignore_recursive(child)


## 清理双 HUD
func _cleanup_dual_hud() -> void:
	if _hud_1p:
		_hud_1p.queue_free()
		_hud_1p = null
	if _hud_2p:
		_hud_2p.queue_free()
		_hud_2p = null
	# 恢复原始 HUD
	if _original_hud:
		_original_hud.visible = true
		_original_hud = null


## 清理分屏
func _cleanup_split_screen() -> void:
	if _canvas_layer:
		_canvas_layer.queue_free()
		_canvas_layer = null
	_hbox = null
	_viewport_1p = null
	_viewport_2p = null
	_camera_1p = null
	_camera_2p = null
	if _original_camera:
		_original_camera.current = true
		_original_camera = null


## 清理 2P 赛车
func _cleanup_2p_car() -> void:
	if _car_2p:
		_car_2p.queue_free()
		_car_2p = null


## 绳索救援: 发起者按键 → 把队友拉到自己身边
## rescued_car: 被救的车 (将飞向发起者)
## initiator_car: 发起救援的车 (目标位置)
## initiator_is_1p: true=1P发起, false=2P发起
func _start_rescue(rescued_car: RigidBody3D, initiator_car: RigidBody3D, initiator_is_1p: bool) -> void:
	if rescued_car == null or initiator_car == null:
		return
	_follow_active = true
	_follow_src = rescued_car         # 被拉过来的队友
	_follow_target = initiator_car    # 发起者 (目标)
	_follow_initiator_is_1p = initiator_is_1p
	_follow_start_pos = rescued_car.global_position
	_follow_target_pos = initiator_car.global_position
	# 记录被救队友的起始朝向
	var src_mesh: Node3D = rescued_car.get_node_or_null("CarMesh")
	if src_mesh:
		_follow_start_basis = src_mesh.global_transform.basis
	else:
		_follow_start_basis = Basis.IDENTITY
	_follow_elapsed = 0.0
	# 被救的车冻结物理
	rescued_car.linear_velocity = Vector3.ZERO
	rescued_car.angular_velocity = Vector3.ZERO
	# 清空缠绕锚点
	_rope_wrap_points.clear()
	# 绳索变色: 救援时绳子变金色脉冲发光
	if _rope_mat:
		_rescue_rope_orig_color = _rope_mat.albedo_color
		_rescue_rope_orig_emission = _rope_mat.emission_enabled
		_rescue_rope_orig_emission_color = _rope_mat.emission if _rope_mat.emission_enabled else Color.BLACK
		_rescue_rope_orig_emission_energy = _rope_mat.emission_energy_multiplier
		_rope_mat.albedo_color = Color(1.0, 0.8, 0.15, 1.0)  # 金色
		_rope_mat.emission_enabled = true
		_rope_mat.emission = Color(1.0, 0.75, 0.1)
		_rope_mat.emission_energy_multiplier = 4.0
	# 显示救援 UI
	_show_rescue_ui(initiator_is_1p)
	var who: String = "1P" if initiator_is_1p else "2P"
	print("[CoopMode] %s 发起救援, 把队友拉到身边!" % who)

## 绳索救援: 每帧更新被救队友的飞行位置 + UI进度
func _update_follow(delta: float) -> void:
	if _follow_src == null:
		_follow_active = false
		_hide_rescue_ui()
		return
	_follow_elapsed += delta
	var t: float = clampf(_follow_elapsed / _follow_duration, 0.0, 1.0)
	# 实时更新目标位置 (发起者可能还在移动)
	if _follow_target:
		_follow_target_pos = _follow_target.global_position
	# 加速曲线: t^2 (ease-in, 越来越快)
	var eased_t: float = t * t
	# 插值位置
	_follow_src.global_position = _follow_start_pos.lerp(_follow_target_pos, eased_t)
	# 飞行中保持速度为零 (由位置插值驱动, 不走物理)
	_follow_src.linear_velocity = Vector3.ZERO
	_follow_src.angular_velocity = Vector3.ZERO
	# 飞行中缓动朝向: 被救队友朝向平滑过渡到发起者朝向
	var src_mesh: Node3D = _follow_src.get_node_or_null("CarMesh")
	if src_mesh and _follow_target:
		var target_mesh: Node3D = _follow_target.get_node_or_null("CarMesh")
		if target_mesh:
			var start_quat: Quaternion = Quaternion(_follow_start_basis)
			var target_quat: Quaternion = Quaternion(target_mesh.global_transform.basis)
			var rot_t: float = t * t * (3.0 - 2.0 * t)  # smoothstep
			var current_quat: Quaternion = start_quat.slerp(target_quat, rot_t)
			src_mesh.global_transform.basis = Basis(current_quat)
	# 更新救援进度 UI
	_update_rescue_progress(t)
	# 到达终点
	if t >= 1.0:
		_follow_src.global_position = _follow_target_pos
		_follow_src.linear_velocity = Vector3.ZERO
		_follow_src.angular_velocity = Vector3.ZERO
		if src_mesh and _follow_target:
			var target_mesh: Node3D = _follow_target.get_node_or_null("CarMesh")
			if target_mesh:
				src_mesh.global_transform.basis = target_mesh.global_transform.basis
		_follow_active = false
		_follow_src = null
		_follow_target = null
		# 恢复绳索颜色
		_restore_rope_color()
		# 显示"队友已到达!"完成提示
		_show_rescue_complete()
		print("[CoopMode] 救援完成, 队友已到达!")
	# 飞行中也更新绳子视觉
	if _rope_connected:
		_update_rope_visual()


# ============================================================
#  救援 UI 系统
# ============================================================

## 恢复绳索到救援前的颜色
func _restore_rope_color() -> void:
	if _rope_mat:
		_rope_mat.albedo_color = _rescue_rope_orig_color
		_rope_mat.emission_enabled = _rescue_rope_orig_emission
		_rope_mat.emission = _rescue_rope_orig_emission_color
		_rope_mat.emission_energy_multiplier = _rescue_rope_orig_emission_energy


## 显示救援 UI — 分别在 1P 和 2P 的 HUD 上显示不同文本
## 发起者看到: "🚨 你已对队友发起救援"
## 被救者看到: "🔗 队友正在救援你!"
func _show_rescue_ui(initiator_is_1p: bool) -> void:
	_hide_rescue_ui()
	# 发起者的 HUD / 被救者的 HUD
	var initiator_hud: CanvasLayer = _hud_1p if initiator_is_1p else _hud_2p
	var rescued_hud: CanvasLayer = _hud_2p if initiator_is_1p else _hud_1p
	if initiator_hud and initiator_hud.has_method("show_rescue_text"):
		initiator_hud.call("show_rescue_text", "🚨 你已对队友发起救援")
	if rescued_hud and rescued_hud.has_method("show_rescue_text"):
		rescued_hud.call("show_rescue_text", "🔗 队友正在救援你!")


## 更新救援进度
func _update_rescue_progress(progress: float) -> void:
	# 更新两个 HUD 的进度条
	if _hud_1p and _hud_1p.has_method("update_rescue_progress"):
		_hud_1p.call("update_rescue_progress", progress)
	if _hud_2p and _hud_2p.has_method("update_rescue_progress"):
		_hud_2p.call("update_rescue_progress", progress)
	# 绳索脉冲发光
	if _rope_mat:
		var pulse: float = 3.0 + sin(_follow_elapsed * 12.0) * 1.5
		_rope_mat.emission_energy_multiplier = pulse


## 显示救援完成提示 — 分别在两边显示
func _show_rescue_complete() -> void:
	_hide_rescue_ui()
	var initiator_hud: CanvasLayer = _hud_1p if _follow_initiator_is_1p else _hud_2p
	var rescued_hud: CanvasLayer = _hud_2p if _follow_initiator_is_1p else _hud_1p
	if initiator_hud and initiator_hud.has_method("show_rescue_done"):
		initiator_hud.call("show_rescue_done", "✅ 队友已到达!")
	if rescued_hud and rescued_hud.has_method("show_rescue_done"):
		rescued_hud.call("show_rescue_done", "✅ 救援完成!")


## 隐藏救援 UI
func _hide_rescue_ui() -> void:
	if _hud_1p and _hud_1p.has_method("hide_rescue_text"):
		_hud_1p.call("hide_rescue_text")
	if _hud_2p and _hud_2p.has_method("hide_rescue_text"):
		_hud_2p.call("hide_rescue_text")


func _toggle_rope() -> void:
	_rope_connected = not _rope_connected
	if _rope_connected:
		_rope_wrap_points.clear()
		_create_rope_visual()
		print("[CoopMode] 绳子已连接! 长度=%.1fm" % rope_length)
	else:
		_rope_wrap_points.clear()
		_cleanup_rope_visual()
		_cleanup_charge_particles()
		_reset_slipstream()
		# 绳子断开时恢复两车摩擦
		if _car_1p and "_rope_friction_mult" in _car_1p:
			_car_1p.set("_rope_friction_mult", 1.0)
		if _car_2p and "_rope_friction_mult" in _car_2p:
			_car_2p.set("_rope_friction_mult", 1.0)
		print("[CoopMode] 绳子已断开!")


## ============================================================
## 绳子模式3: 毒图铁链 (PBD 距离硬约束 + 鞭甩)
## ============================================================
## 每物理帧:
##   1. 沿用 mode1/2 的缠绕检测 (绳子不穿墙)
##   2. 计算总路径长度 _rope_total_length (含缠绕锚点)
##   3. 如果 _rope_total_length > rope_mode3_length: 进入 PBD 校正
##      a) 沿"链子第一段方向 dir_1p"和"最后一段方向 dir_2p"分别拉两车
##      b) 修正量 = (_rope_total_length - rope_mode3_length) * 0.5 (1:1 双向)
##      c) 拉位置 + 反向冲量 (jerk_impulse) + 速度投影 (whip_strength)
##   4. 不到 rope_mode3_length 时绳子松弛, 不施加任何力
## 数学详细:
##   设链超出量 error = _rope_total_length - rope_mode3_length
##   pos_1p_new = pos_1p + dir_1p * (error * 0.5)   (dir_1p 指向 2P 方向)
##   pos_2p_new = pos_2p + dir_2p * (error * 0.5)   (dir_2p 指向 1P 方向)
##   注: dir_1p, dir_2p 在缠绕情况下沿绳路径切线, 不是直线方向
## ============================================================
func _apply_rope_mode3(delta: float) -> void:
	var pos_1p: Vector3 = _car_1p.global_position
	var pos_2p: Vector3 = _car_2p.global_position

	# ---- 1. 缠绕检测 (与 mode1/2 共用, 铁链同样不穿墙) ----
	_update_rope_wrap(pos_1p, pos_2p)

	# ---- 2. 计算总路径长度 ----
	var path_points: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	_rope_total_length = 0.0
	for i in range(path_points.size() - 1):
		_rope_total_length += path_points[i].distance_to(path_points[i + 1])

	# ---- 3. 不超长就什么都不做 (绳子松弛) ----
	# 注意: 用一个很小的 epsilon (0.05m) 防止数值噪声反复触发
	var error: float = _rope_total_length - rope_mode3_length
	if error <= 0.05:
		# 模式3不削减摩擦, 因为铁链松弛时双方应该完全自由
		_car_1p.set("_rope_friction_mult", 1.0)
		_car_2p.set("_rope_friction_mult", 1.0)
		# 链子恢复松弛 → 重置绷紧标志, 让下次绷紧能再触发 jerk
		_rope_mode3_was_taut = false
		return

	# ---- 4. 计算两端的拉力切线方向 (沿绳路径首段/末段) ----
	# 1P 端: 从 1P 指向第一个有效拐点 (跳过太近的锚点, 防止抖动)
	var dir_1p: Vector3 = Vector3.ZERO
	for pi in range(1, path_points.size()):
		var diff: Vector3 = path_points[pi] - path_points[0]
		if diff.length() > 0.5:
			dir_1p = diff.normalized()
			break
	if dir_1p == Vector3.ZERO:
		dir_1p = (path_points[path_points.size() - 1] - path_points[0]).normalized()
	# 2P 端: 从 2P 指向最后一个有效拐点
	var dir_2p: Vector3 = Vector3.ZERO
	var last_idx: int = path_points.size() - 1
	for pi in range(last_idx - 1, -1, -1):
		var diff: Vector3 = path_points[pi] - path_points[last_idx]
		if diff.length() > 0.5:
			dir_2p = diff.normalized()
			break
	if dir_2p == Vector3.ZERO:
		dir_2p = (path_points[0] - path_points[last_idx]).normalized()

	# ============================================================
	# ---- 5. 张力拉拽 (开车人不被拖累 + 后车被持续拽起来) ----
	# ============================================================
	# 用户反馈历程:
	#   v1: PBD 只修位置不传速度 → "只修距离不互相扯"
	#   v2: 动量守恒耦合 (v_avg) → "都开不动" (双方都减速到 v_avg)
	#   v3: 主导拽 (瞬间速度赋值) → "瞬移不像拽"
	#   v4: 渐进收敛 (一阶低通) → "还是拖不动"
	#   v5 (本版): 渐进收敛 + 位置修正按 front_share 分担 (前车几乎不被拉)
	#
	# v5 关键洞察 — "拖不动"的真正原因是 PBD 位置约束:
	#   旧版每帧 PBD 双向各 50% 修正: pos_1p += dir_1p × error × 0.5
	#   前车想跑 0.04m/帧 → 距离 +0.04 → PBD 把前车拉回 0.02 → 净位移砍半!
	#   不管速度耦合多好, 位置约束直接让前车实际只跑一半路程
	#   修复: 让 front_drag_ratio 同时控制 "速度反作用" 和 "位置修正分担":
	#     ratio=0   → 后车 100% 位置修正, 前车 0%   (前车完全自由开 ✓ 推荐)
	#     ratio=0.5 → 双方各 50%  (经典 PBD, 前车被拖累)
	#     ratio=1.0 → 前车 100%   (反常用, 前车被拽回去, 后车不动)
	# ============================================================

	# 计算 n_chain (从 1P 指向 2P 的瞬时连线方向, 统一速度分量坐标系)
	var n_chain: Vector3 = pos_2p - pos_1p
	var n_chain_len: float = n_chain.length()
	if n_chain_len < 0.001:
		_car_1p.set("_rope_friction_mult", 1.0)
		_car_2p.set("_rope_friction_mult", 1.0)
		return
	n_chain = n_chain / n_chain_len

	# 读两车 linear_velocity (位置修正分担判定 + 速度耦合都要用)
	var v1: Vector3 = _car_1p.linear_velocity
	var v2: Vector3 = _car_2p.linear_velocity
	# 主导方判定: 用整体速度大小 (修复"垂直方向传不了速度"的关键)
	# 旧版用 rate_1p = -v1.dot(n_chain) vs rate_2p = +v2.dot(n_chain) (沿绳贡献率),
	# 但当车的运动垂直于绳子时 v.dot(n_chain) = 0, rate 全为 0, 主导判定失效
	# 新版: 直接看 |v1| 和 |v2|, 速度大的车是 "前车" (主导拽)
	# 这样不论几何关系, 只要有一辆车在动, 系统就能正确分配主导方
	var is_1p_front: bool = v1.length() >= v2.length()

	# ============================================================
	# 5a) 位置硬约束 — 按 front_share 分担修正比例 (核心修复!)
	# ============================================================
	# 数学:
	#   front_share = front_drag_ratio   ∈ [0, 1]   ; 前车承担位置修正比例
	#   rear_share  = 1 - front_share              ; 后车承担位置修正比例
	#   验证: front_share + rear_share = 1, 距离总修正量 = error (完整闭合距离约束)
	# 默认 front_drag_ratio=0.05 → 后车承担 95% 位置修正, 前车几乎不被拉
	var front_share: float = clampf(rope_mode3_front_drag_ratio, 0.0, 1.0)
	var rear_share: float = 1.0 - front_share
	if is_1p_front:
		# 1P 是前车 → 1P 用 front_share (默认很小), 2P 用 rear_share (默认很大)
		_car_1p.global_position += dir_1p * error * front_share
		_car_2p.global_position += dir_2p * error * rear_share
	else:
		# 2P 是前车
		_car_1p.global_position += dir_1p * error * rear_share
		_car_2p.global_position += dir_2p * error * front_share

	# ============================================================
	# 5b) 速度向量复制 — 拖着走 (\"被绳子绑住的麻袋\"语义)
	# ============================================================
	# 用户反馈历程:
	#   v1 PBD 位置修正           → 不互相扯
	#   v2 动量守恒 v_avg          → 都开不动
	#   v3 主导拽 (瞬间速度赋值)    → 瞬移不像拽
	#   v4 渐进收敛 (一阶低通)      → 摩擦吃掉, 拖不动
	#   v5 全向速度收敛            → 同样被摩擦吃掉
	#   v6 强制 pull_dir × |v_front| 沿绳赋值 → \"后车飞过前车 + 主导反转 + 来回震荡\"
	#   v7 (本版) 直接复制速度向量 → 两车并行同步移动, 没有飞过去现象
	#
	# v6 为什么挂了 (推导):
	#   1P 朝 +x 跑 v1=(20,0,0), 2P 静止 v2=0
	#   v6: pull_dir = (1P-2P).normalized() = +x 方向
	#       2P.velocity = pull_dir × 20 = (20,0,0)  ← 看起来对
	#   但下一物理帧:
	#       1P 在 +x 跑了 (0.083, 0, 0), 2P 也跑了 (0.083, 0, 0) — 同步 ✓
	#   问题来自\"瞬移\"的初始过冲:
	#       2P 被瞬时赋速度 20, 但 2P 当前没踩油门, 引擎力 = 0,
	#       2P 还有 \"linear_damp 默认重力影响\" 等让速度有抖动
	#       同时 1P 受惯性短暂可能比 2P 快或慢一帧 → speed_diff 翻转 → 2P 反成主导
	#       → 1P 被强制设速度 = pull_dir × |v_2P| 朝 2P 方向飞过去
	#       → 来回震荡 = \"前车走不动 + 后车原地速度变化\"
	#
	# v7 修复 (语义): 把后车的整个速度向量\"复制\"成前车的速度向量
	#   1P 朝 +x 跑 v1=(20,0,0) → 2P.velocity = (20, rear_y, 0)
	#   两车水平速度向量完全相等 → 移动方向相同, 速度大小相同
	#   距离不会增长 (绳子保持张紧) → PBD 几乎不需要修正
	#   主导方 = 永远是速度大的那辆, 但因为复制后两车速度一致, 不再震荡
	#   下一帧物理引擎会让 2P 因摩擦/阻力略减速, speed_diff 重新出现, 再复制一次
	#   → 持续\"复制\" 维持同步
	#
	# 关键差异: v6 用 pull_dir 强行让后车朝前车方向飞 (会过冲)
	#           v7 直接复制速度向量 (两车同向同速 → 不可能过冲)
	#
	# 摩擦绕过 (依旧重要):
	#   设 _rope_friction_mult = 0 让 _apply_friction 屏蔽摩擦
	#   否则后车被复制的速度立刻被自身摩擦吃掉, 又得重新被复制, 视觉上看起来\"颤抖\"
	#
	# whip_strength 的新语义:
	#   1.0 → 完全复制 (后车速度 = 前车速度, 100% 同步, 真·铁链)
	#   0.5 → 后车速度 lerp(self, front, 0.5) 半复制 (柔和过渡, 有点滞后感)
	#   0.0 → 不复制 (退化为只有位置硬约束)
	#
	# 主导方判定: 不再用阈值, 直接 speed_1 vs speed_2, 速度大者就是前车
	#   阈值会导致 \"刚好均势\" 时不拽 → 前车继续靠惯性而后车开始减速 → 速度差立刻
	#   超阈值再触发 → 抖动. 取消阈值后, 永远复制, 平滑.
	# ============================================================
	if rope_mode3_whip_enabled and rope_mode3_whip_strength > 0.001:
		var speed_1: float = v1.length()
		var speed_2: float = v2.length()
		# 触发: 至少要有一辆车在动 (避免双方静止时被链子绑死后无意义触发)
		# 阈值 0.5 m/s 防数值噪声: 真静止时浮点抖动可能让 speed > 0
		if speed_1 + speed_2 > 0.5:
			# 主导方判定: 速度大者 = 前车, 不要阈值, 避免抖动
			var front_car: RigidBody3D
			var rear_car: RigidBody3D
			var v_front_full: Vector3
			if speed_1 >= speed_2:
				front_car = _car_1p
				rear_car = _car_2p
				v_front_full = v1
			else:
				front_car = _car_2p
				rear_car = _car_1p
				v_front_full = v2

			# === 速度向量复制 (用户要的"无视车头, 直接设置值") ===
			# 数学:
			#   target_xz = (v_front.x, 0, v_front.z)  ← 复制前车水平速度向量
			#   保留 rear.y                            ← 重力/跳跃不被破坏
			#   按 whip_strength lerp 过渡:
			#     copied = lerp(rear_current, target_full, whip_strength)
			#     whip=1 → copied = target (硬复制)
			#     whip=0.5 → 半路 (柔和过渡)
			var rear_v: Vector3 = rear_car.linear_velocity
			# 目标 = 前车速度的水平分量, Y 用后车自己的 (重力/跳跃保持)
			var target_v: Vector3 = Vector3(v_front_full.x, rear_v.y, v_front_full.z)
			# whip_strength 控制\"复制完整度\". 1.0=完全复制, 0.5=半复制, 0=不动
			var copied: Vector3 = rear_v.lerp(target_v, rope_mode3_whip_strength)
			rear_car.linear_velocity = copied
			# 摩擦绕过: car.gd 里 if mult < 1.0 → long_k *= mult, 0=完全屏蔽
			# 这是关键! 否则后车自己的摩擦会立刻把刚复制的速度吃回去
			rear_car.set("_rope_friction_mult", 0.0)
			# 前车一直自由 (速度不动, 摩擦保持正常 1.0, 它就是\"开车的人\")
			# 不需要任何针对前车的操作 — 前车正常开正常受摩擦, 用户体验= 完全自由

	# 5c) 反向冲量 (jerk): 只在"链子从松弛刚绷紧"那一瞬间触发一次
	# 旧版 bug: 每物理帧都触发 → 240Hz × 8 m/s 冲量 = 把车按死在原地
	# 现版: was_taut=false → true 那一帧才给一次 jerk, 持续绷紧时不再加
	# error > 0.05 已经在函数顶部 "不超长直接 return" 过滤过了, 所以这里 error 一定 > 0.05
	# 即本帧"链子是绷紧的". 检查 _rope_mode3_was_taut 区分"刚绷紧"和"持续绷紧"
	if not _rope_mode3_was_taut and rope_mode3_jerk_impulse > 0.01:
		# === 刚绷紧的瞬间 === (上一帧 was_taut=false, 本帧 error>0.05 → 链子刚被拽紧)
		# 给两车朝对方方向一次性冲量, 模拟"咣当"撞击
		# 用 sqrt(error) 让超出量很小时也有点撞击感, 超出大时不至于过分大
		var jerk_mag: float = rope_mode3_jerk_impulse * sqrt(error)
		_car_1p.apply_central_impulse(dir_1p * jerk_mag * _car_1p.mass)
		_car_2p.apply_central_impulse(dir_2p * jerk_mag * _car_2p.mass)
		print("[Mode3] 铁链绷紧! error=%.2fm jerk=%.2f" % [error, jerk_mag])
	# 标记本帧为绷紧状态, 下一帧持续绷紧时跳过 jerk
	_rope_mode3_was_taut = true

	# ---- 6. 摩擦设置 ----
	# 旧版无脑把两车都设 1.0, 但这会**覆盖掉 5b 段把后车 mult 设为 0 的硬赋值**
	# (硬赋值后 _apply_friction 会立即把刚赋的速度吃掉 → 用户感受"还是拉不动")
	#
	# 新版: 5b 段已经为后车设好了 0.0 (链子绷紧 + 主导方拽), 这里不要再覆盖!
	# 前车一直是 1.0 (它正常受摩擦, 模拟开车人正常体感)
	# 如果这帧没有主导方 (5b 没进 if has_dominator 分支), 两车 mult 都保持上一帧值,
	#   不会出问题: 因为顶部"链子松弛 return 分支"已经把它们设回 1.0
	#
	# 这段历史上是写在 5b 之后的, 改成只设 1P (假设它是前车), 错了也没关系:
	# 因为两车情况都被 5b 正确处理过. 这里只兜底一种情况:
	#   两车速度都很小但还硬绷着 (has_dominator=false), 此时摩擦应该正常
	if not (rope_mode3_whip_enabled and rope_mode3_whip_strength > 0.001):
		# 张力开关被关 → 摩擦保持正常 (回退到纯位置约束模式)
		_car_1p.set("_rope_friction_mult", 1.0)
		_car_2p.set("_rope_friction_mult", 1.0)
	# else: 5b 段已经为后车正确设了 0.0 (拽中) 或者保持上次的值 (均势/无主导)
	# 注: 上面 5b 没碰前车的 mult, 所以前车的 mult 永远保持 1.0
	# (Tuner 里手动设的值会被这里覆盖? 不会, 因为这是"绳子摩擦削减", 不是车的"基础摩擦")


## ============================================================
## 绳子模式2: 距离档位系统逻辑
## ============================================================
func _apply_rope_mode2(delta: float) -> void:
	var pos_1p: Vector3 = _car_1p.global_position
	var pos_2p: Vector3 = _car_2p.global_position

	# ---- 0. 缠绕检测: 绳子不穿墙, 沿墙面缠绕 (与模式1共用) ----
	_update_rope_wrap(pos_1p, pos_2p)

	# ---- 1. 计算绳子总路径长度 (含缠绕锚点) ----
	var path_points: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	_rope_total_length = 0.0
	for i in range(path_points.size() - 1):
		_rope_total_length += path_points[i].distance_to(path_points[i + 1])

	# 使用绳子总路径长度作为距离判断依据 (含缠绕, 比直线距离更准确)
	var dist: float = _rope_total_length

	# ---- 2. 计算当前档位 (1~5) ----
	var tier: int = 5  # 默认最远档
	if dist < rope_mode2_dist_1:
		tier = 1
	elif dist < rope_mode2_dist_2:
		tier = 2
	elif dist < rope_mode2_dist_3:
		tier = 3
	elif dist < rope_mode2_dist_4:
		tier = 4
	_rope_mode2_current_tier = tier

	# ---- 3. 根据档位施加效果 ----
	match tier:
		1:
			# 1档: 自动集气 (两车都获得 charge)
			_mode2_auto_charge(delta)
			_mode2_reset_friction()
		2:
			# 2档: 速度加成 (给两车施加沿运动方向的推力)
			_mode2_speed_boost(delta)
			_mode2_reset_friction()
		3:
			# 3档: 中性, 无特殊效果
			_mode2_reset_friction()
		4:
			# 4档: 后车获得轻微前车拉力
			_ensure_charge_particles_emitting(false)
			_mode2_rear_pull(delta, rope_mode2_tier4_pull_force)
		5:
			# 5档: 后车获得强力前车拉力
			_ensure_charge_particles_emitting(false)
			_mode2_rear_pull(delta, rope_mode2_tier5_pull_force)


## 模式2辅助: 恢复两车摩擦为正常值 (1~3档不拉扯时调用)
func _mode2_reset_friction() -> void:
	if _car_1p and "_rope_friction_mult" in _car_1p:
		_car_1p.set("_rope_friction_mult", 1.0)
	if _car_2p and "_rope_friction_mult" in _car_2p:
		_car_2p.set("_rope_friction_mult", 1.0)
	# 非1档时停止集气粒子
	if _rope_mode2_current_tier != 1:
		_ensure_charge_particles_emitting(false)


## 模式2效果: 自动集气 (1档)
func _mode2_auto_charge(delta: float) -> void:
	# 启动集气粒子特效
	_ensure_charge_particles_emitting(true)

	var charge_inc: float = rope_mode2_tier1_charge_per_sec * delta
	# 给两辆车都增加 charge
	for car in [_car_1p, _car_2p]:
		if car == null:
			continue
		if "charge" in car and "charge_nitro_full" in car and "nitro_stock" in car and "max_nitro_stock" in car:
			car.charge += charge_inc
			# 检查是否集满一格
			var _pending: int = car.get("_pending_nitro") if "_pending_nitro" in car else 0
			while car.charge >= car.charge_nitro_full and car.nitro_stock + _pending < car.max_nitro_stock:
				car.charge -= car.charge_nitro_full
				car.nitro_stock += 1
				car.emit_signal("nitro_stock_changed", car.nitro_stock, car.max_nitro_stock)
			# 夹紧防溢出
			if car.nitro_stock + _pending >= car.max_nitro_stock:
				car.charge = minf(car.charge, car.charge_nitro_full - 1.0)
			# 通知 HUD 更新集气槽
			if car.has_signal("charge_changed"):
				car.emit_signal("charge_changed", car.charge, car.charge_nitro_full)


## 模式2效果: 速度加成 (2档)
func _mode2_speed_boost(delta: float) -> void:
	# 给两车沿运动方向施加一个小推力, 模拟速度加成
	var boost_accel: float = (rope_mode2_tier2_speed_mult - 1.0) * 50.0  # 转换为加速度
	for car in [_car_1p, _car_2p]:
		if car == null:
			continue
		var vel: Vector3 = car.linear_velocity
		if vel.length() > 1.0:
			var push_dir: Vector3 = vel.normalized()
			car.apply_central_force(push_dir * boost_accel * car.mass)


## 模式2效果: 后车拉力 (4档/5档) - 复刻模式1的完整绳子物理
## 包含: 沿路径拉力方向、前后车分配、转向自由度、摩擦削减、卡墙处理
## 注: 与模式1不同, 模式2的拉力是固定值(不依赖弹簧拉伸), 阻尼只用于防止过冲
func _mode2_rear_pull(delta: float, pull_force: float) -> void:
	var pos_1p: Vector3 = _car_1p.global_position
	var pos_2p: Vector3 = _car_2p.global_position

	# ---- 1. 沿绳子路径计算各端拉力方向 (与模式1一致) ----
	var path_points: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)

	# 1P 端: 从 1P 指向第一个有效节点 (跳过距离太近的锚点)
	var dir_1p: Vector3 = Vector3.ZERO
	for pi in range(1, path_points.size()):
		var diff: Vector3 = path_points[pi] - path_points[0]
		if diff.length() > 0.5:
			dir_1p = diff.normalized()
			break
	if dir_1p == Vector3.ZERO:
		dir_1p = (path_points[path_points.size() - 1] - path_points[0]).normalized()

	# 2P 端: 从 2P 指向最后一个有效节点 (跳过距离太近的锚点)
	var dir_2p: Vector3 = Vector3.ZERO
	var last_idx: int = path_points.size() - 1
	for pi in range(last_idx - 1, -1, -1):
		var diff: Vector3 = path_points[pi] - path_points[last_idx]
		if diff.length() > 0.5:
			dir_2p = diff.normalized()
			break
	if dir_2p == Vector3.ZERO:
		dir_2p = (path_points[0] - path_points[last_idx]).normalized()

	# ---- 2. 判断谁是前车/后车 ----
	# 规则: 绳子通往身后的是前车, 绳子通往身前的是后车; 两车情况相同则看谁速度高
	var is_1p_front: bool = _is_1p_front_car(dir_1p, dir_2p)

	# ---- 3. 计算拉力 ----
	# 模式2: 直接使用配置的 pull_force, 不依赖弹簧拉伸量
	# 后车获得全力拉向前车, 前车受到轻微回拉
	var force_front: float = pull_force * rope_front_pull_ratio
	var force_rear: float = pull_force * rope_rear_pull_ratio

	# 阻尼: 只对后车已经在朝前车运动时施加减速(防止过冲), 不抵消拉力本身
	var rear_car: RigidBody3D
	var front_car: RigidBody3D
	var rear_pull_dir: Vector3
	var front_pull_dir: Vector3

	if is_1p_front:
		# 1P 是前车, 2P 是后车
		rear_car = _car_2p
		front_car = _car_1p
		rear_pull_dir = dir_2p
		front_pull_dir = dir_1p
	else:
		# 2P 是前车, 1P 是后车
		rear_car = _car_1p
		front_car = _car_2p
		rear_pull_dir = dir_1p
		front_pull_dir = dir_2p

	# 后车朝前车方向的速度 (正值=正在靠近前车)
	var rear_approach_speed: float = rear_car.linear_velocity.dot(rear_pull_dir)
	# 只有后车已经在快速靠近时才施加阻尼 (防止过冲), 否则不减弱拉力
	if rear_approach_speed > 0.0:
		var damping_reduction: float = rope_damping * rear_approach_speed * 0.3
		force_rear = maxf(force_rear - damping_reduction, pull_force * 0.2)  # 最少保留20%拉力

	# clamp 到最大力
	force_front = clampf(force_front, 0.0, rope_max_force)
	force_rear = clampf(force_rear, 0.0, rope_max_force)

	# ---- 4. 施加力 (后车有转向自由度) ----
	# 前车: 纯中心力回拉 (轻微)
	front_car.apply_central_force(front_pull_dir * force_front)
	# 后车: 带转向自由度的拉力
	_apply_force_with_steer_freedom(rear_car, rear_pull_dir * force_rear, rope_rear_steer_freedom)

	# ---- 5. 后车摩擦削减 + 卡墙处理 ----
	# 摩擦削减: 拉力越大摩擦越小
	var stretch: float = _rope_total_length - rope_length - rope_elasticity
	var stretch_ratio: float = clampf(stretch / maxf(rope_length, 1.0), 0.0, 1.0)
	var target_friction: float = lerpf(1.0, rope_friction_mult_when_pulled, stretch_ratio)
	rear_car.set("_rope_friction_mult", target_friction)

	# 卡墙处理: 后车速度低于阈值时
	var rear_speed_kmh: float = rear_car.linear_velocity.length() * 3.6
	if rear_speed_kmh < rope_stuck_speed_threshold:
		# (a) 抬升力: 让后车脱离地面摩擦
		rear_car.apply_central_force(Vector3.UP * rear_car.mass * 5.0)
		# (b) 墙面滑动修正: 检测后车前方是否有墙, 将拉力修正为沿墙面切线方向
		var space_state: PhysicsDirectSpaceState3D = rear_car.get_world_3d().direct_space_state
		if space_state:
			var ray_start: Vector3 = rear_car.global_position
			var ray_end: Vector3 = ray_start + rear_pull_dir * 3.0
			var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
			query.collision_mask = 1  # 只检测静态环境
			query.exclude = [_car_1p.get_rid(), _car_2p.get_rid()]
			var result: Dictionary = space_state.intersect_ray(query)
			if result.size() > 0:
				# 前方有墙! 将拉力投影到墙面切线方向
				var wall_normal: Vector3 = result["normal"]
				var slide_dir: Vector3 = rear_pull_dir - wall_normal * rear_pull_dir.dot(wall_normal)
				if slide_dir.length() > 0.1:
					slide_dir = slide_dir.normalized()
					var slide_force: float = rear_car.mass * 15.0
					rear_car.apply_central_force(slide_dir * slide_force)

	# 前车保持正常摩擦
	front_car.set("_rope_friction_mult", 1.0)


## ============================================================
## 模式2集气粒子特效: 蓝色粒子聚合效果
## ============================================================

## 创建单个车的集气粒子 (蓝色粒子从外向内聚合到车身)
func _create_charge_particle_for_car(car: RigidBody3D) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "CoopChargeParticles"
	p.amount = rope_mode2_charge_particle_count
	p.lifetime = 0.8
	p.emitting = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.explosiveness = 0.0
	p.randomness = 0.3

	# 粒子 mesh: 小球
	var sm := SphereMesh.new()
	sm.radius = rope_mode2_charge_particle_size
	sm.height = rope_mode2_charge_particle_size * 2.0
	sm.radial_segments = 6
	sm.rings = 3
	p.draw_pass_1 = sm

	# 材质: 蓝色发光半透明 (加法混合)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = rope_mode2_charge_particle_color
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.5, 1.0, 1.0)
	mat.emission_energy_multiplier = 6.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	p.material_override = mat

	# 粒子处理材质: 球形发射 + 负速度 (向内聚合)
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	proc.emission_sphere_radius = rope_mode2_charge_particle_radius
	# 负方向 = 粒子从球面向中心聚合
	proc.direction = Vector3(0, 0, 0)
	proc.spread = 180.0
	# 使用 attractor 效果: 初始速度向外, 但被重力拉回中心
	# 实际做法: 初始速度为负 (radial_velocity) 让粒子向内飞
	proc.radial_velocity_min = -rope_mode2_charge_particle_speed
	proc.radial_velocity_max = -rope_mode2_charge_particle_speed * 0.6
	proc.initial_velocity_min = 0.0
	proc.initial_velocity_max = 0.5
	proc.gravity = Vector3(0, 0.5, 0)  # 轻微上浮感
	proc.scale_min = 0.5
	proc.scale_max = 1.2
	# 粒子颜色渐变: 从外到内越来越亮
	proc.color = rope_mode2_charge_particle_color
	# 生命周期内缩小 (到达中心时消失)
	var scale_curve := CurveTexture.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))   # 出生时正常大小
	curve.add_point(Vector2(0.7, 0.8))   # 中途略缩
	curve.add_point(Vector2(1.0, 0.0))   # 到达中心时消失
	scale_curve.curve = curve
	proc.scale_curve = scale_curve
	# 透明度渐变: 出生时半透明, 中间最亮, 消失时淡出
	var alpha_curve := CurveTexture.new()
	var a_curve := Curve.new()
	a_curve.add_point(Vector2(0.0, 0.3))  # 出生时较淡
	a_curve.add_point(Vector2(0.4, 1.0))  # 中间最亮
	a_curve.add_point(Vector2(1.0, 0.0))  # 消失
	alpha_curve.curve = a_curve
	proc.alpha_curve = alpha_curve

	p.process_material = proc

	# 挂载到车身上
	car.add_child(p)
	p.position = Vector3(0, 0.8, 0)  # 稍微抬高到车身中部

	return p


## 确保集气粒子处于正确的发射状态
func _ensure_charge_particles_emitting(emitting: bool) -> void:
	# 1P 粒子
	if _car_1p:
		if _charge_particles_1p == null and emitting:
			_charge_particles_1p = _create_charge_particle_for_car(_car_1p)
		if _charge_particles_1p and _charge_particles_1p.emitting != emitting:
			_charge_particles_1p.emitting = emitting
	# 2P 粒子
	if _car_2p:
		if _charge_particles_2p == null and emitting:
			_charge_particles_2p = _create_charge_particle_for_car(_car_2p)
		if _charge_particles_2p and _charge_particles_2p.emitting != emitting:
			_charge_particles_2p.emitting = emitting


## 清理集气粒子 (绳子断开或模式切换时调用)
func _cleanup_charge_particles() -> void:
	if _charge_particles_1p and is_instance_valid(_charge_particles_1p):
		_charge_particles_1p.queue_free()
	_charge_particles_1p = null
	if _charge_particles_2p and is_instance_valid(_charge_particles_2p):
		_charge_particles_2p.queue_free()
	_charge_particles_2p = null


## 获取模式2当前档位对应的颜色
func _get_mode2_tier_color() -> Color:
	match _rope_mode2_current_tier:
		1: return rope_mode2_color_1
		2: return rope_mode2_color_2
		3: return rope_mode2_color_3
		4: return rope_mode2_color_4
		5: return rope_mode2_color_5
		_: return rope_mode2_color_3


## 绳子物理: 非对称 + 缠绕 + 后车转向自由度
func _apply_rope_physics(delta: float) -> void:
	var pos_1p: Vector3 = _car_1p.global_position
	var pos_2p: Vector3 = _car_2p.global_position

	# ---- 1. 缠绕检测: 绳子不穿墙, 沿墙面缠绕 ----
	_update_rope_wrap(pos_1p, pos_2p)

	# ---- 2. 计算绳子总路径长度 (含缠绕锚点) ----
	var path_points: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	_rope_total_length = 0.0
	for i in range(path_points.size() - 1):
		_rope_total_length += path_points[i].distance_to(path_points[i + 1])

	# 只有超过 (自然长度 + 弹性余量) 才施力
	var stretch: float = _rope_total_length - rope_length - rope_elasticity
	if stretch <= 0.0:
		return  # 绳子松弛, 不施力

	# ---- 3. 计算各端的拉力方向 (沿绳子路径的第一段/最后一段) ----
	# 1P 端: 从 1P 指向第一个有效节点 (跳过距离太近的锚点)
	var dir_1p: Vector3 = Vector3.ZERO
	for pi in range(1, path_points.size()):
		var diff: Vector3 = path_points[pi] - path_points[0]
		if diff.length() > 0.5:  # 至少 0.5m 才算有效方向
			dir_1p = diff.normalized()
			break
	if dir_1p == Vector3.ZERO:
		dir_1p = (path_points[path_points.size() - 1] - path_points[0]).normalized()

	# 2P 端: 从 2P 指向最后一个有效节点 (跳过距离太近的锚点)
	var dir_2p: Vector3 = Vector3.ZERO
	var last_idx: int = path_points.size() - 1
	for pi in range(last_idx - 1, -1, -1):
		var diff: Vector3 = path_points[pi] - path_points[last_idx]
		if diff.length() > 0.5:  # 至少 0.5m 才算有效方向
			dir_2p = diff.normalized()
			break
	if dir_2p == Vector3.ZERO:
		dir_2p = (path_points[0] - path_points[last_idx]).normalized()

	# ---- 4. 计算弹簧力 ----
	var spring_force: float = rope_stiffness * sqrt(stretch) * sqrt(stretch + 1.0)

	# 阻尼力: 沿绳子方向的相对速度
	var rel_vel_1p: float = _car_1p.linear_velocity.dot(dir_1p)
	var rel_vel_2p: float = _car_2p.linear_velocity.dot(dir_2p)
	var damping_1p: float = -rope_damping * rel_vel_1p * 0.5
	var damping_2p: float = -rope_damping * rel_vel_2p * 0.5

	# ---- 5. 判断谁是前车/后车 ----
	# 规则: 绳子通往身后的是前车, 绳子通往身前的是后车; 两车情况相同则看谁速度高
	var is_1p_front: bool = _is_1p_front_car(dir_1p, dir_2p)

	var force_1p: float  # 施加到 1P 的力大小
	var force_2p: float  # 施加到 2P 的力大小

	if is_1p_front:
		# 1P 是前车, 2P 是后车
		force_1p = clampf((spring_force + damping_1p) * rope_front_pull_ratio, 0.0, rope_max_force)
		force_2p = clampf((spring_force + damping_2p) * rope_rear_pull_ratio, 0.0, rope_max_force)
	else:
		# 2P 是前车, 1P 是后车
		force_1p = clampf((spring_force + damping_1p) * rope_rear_pull_ratio, 0.0, rope_max_force)
		force_2p = clampf((spring_force + damping_2p) * rope_front_pull_ratio, 0.0, rope_max_force)

	# ---- 6. 施加力 (后车有转向自由度) ----
	if is_1p_front:
		# 1P 是前车, 2P 是后车
		# 前车: 纯中心力 (回拉, 不影响转向)
		_car_1p.apply_central_force(dir_1p * force_1p)
		# 后车: 根据 rope_rear_steer_freedom 混合中心力和偏移力
		_apply_force_with_steer_freedom(_car_2p, dir_2p * force_2p, rope_rear_steer_freedom)
	else:
		# 2P 是前车, 1P 是后车
		# 前车: 纯中心力 (回拉, 不影响转向)
		_car_2p.apply_central_force(dir_2p * force_2p)
		# 后车: 根据 rope_rear_steer_freedom 混合中心力和偏移力
		_apply_force_with_steer_freedom(_car_1p, dir_1p * force_1p, rope_rear_steer_freedom)

	# ---- 7. 后车摩擦削减: 绳子拉紧时始终削减后车摩擦, 确保拉力能有效传递 ----
	var rear_car: RigidBody3D
	var front_car: RigidBody3D
	var rear_pull_dir: Vector3  # 后车被拉的方向
	if is_1p_front:
		rear_car = _car_2p
		front_car = _car_1p
		rear_pull_dir = dir_2p
	else:
		rear_car = _car_1p
		front_car = _car_2p
		rear_pull_dir = dir_1p

	# 绳子拉紧时, 始终对后车削减摩擦 (让绳子拉力能有效传递)
	# 削减程度: 拉伸越大, 摩擦越小 (线性插值)
	var stretch_ratio: float = clampf(stretch / rope_length, 0.0, 1.0)  # 拉伸比例 0~1
	var target_friction: float = lerpf(1.0, rope_friction_mult_when_pulled, stretch_ratio)
	rear_car.set("_rope_friction_mult", target_friction)

	# 后车速度 (km/h)
	var rear_speed_kmh: float = rear_car.linear_velocity.length() * 3.6
	# 绳子拉紧 + 后车速度低于阈值 → 额外脱困手段
	if rear_speed_kmh < rope_stuck_speed_threshold:
		# (a) 抬升力: 给后车一个向上的力, 让它脱离地面摩擦
		rear_car.apply_central_force(Vector3.UP * rear_car.mass * 5.0)
		# (b) 墙面滑动修正: 检测后车前方是否有墙, 如果有则将拉力修正为沿墙面切线方向
		var space_state: PhysicsDirectSpaceState3D = rear_car.get_world_3d().direct_space_state
		if space_state:
			# 从后车位置沿拉力方向射线检测墙面
			var ray_start: Vector3 = rear_car.global_position
			var ray_end: Vector3 = ray_start + rear_pull_dir * 3.0
			var query := PhysicsRayQueryParameters3D.create(ray_start, ray_end)
			query.collision_mask = 1  # 只检测静态环境
			query.exclude = [_car_1p.get_rid(), _car_2p.get_rid()]
			var result: Dictionary = space_state.intersect_ray(query)
			if result.size() > 0:
				# 前方有墙! 将拉力投影到墙面切线方向 (去掉法线分量)
				var wall_normal: Vector3 = result["normal"]
				# 拉力在墙面上的投影 = 拉力 - (拉力·法线)×法线
				var slide_dir: Vector3 = rear_pull_dir - wall_normal * rear_pull_dir.dot(wall_normal)
				if slide_dir.length() > 0.1:
					slide_dir = slide_dir.normalized()
					# 施加沿墙面滑动的额外力 (帮助后车绕过墙角)
					var slide_force: float = rear_car.mass * 15.0
					rear_car.apply_central_force(slide_dir * slide_force)
	# 前车始终保持正常摩擦
	front_car.set("_rope_friction_mult", 1.0)


## 判断 1P 是否为前车
## 规则: 绳子通往身后的是前车, 绳子通往身前的是后车; 两车情况相同则看谁速度高
## dir_1p: 从 1P 指向绳子路径的方向 (指向对方)
## dir_2p: 从 2P 指向绳子路径的方向 (指向对方)
## 返回 true = 1P 是前车, false = 2P 是前车
func _is_1p_front_car(dir_1p: Vector3, dir_2p: Vector3) -> bool:
	# 获取两车的朝向 (forward = -basis.z)
	var mesh_1p: Node3D = _car_1p.get_node_or_null("CarMesh")
	var mesh_2p: Node3D = _car_2p.get_node_or_null("CarMesh")
	var fwd_1p: Vector3 = -mesh_1p.global_transform.basis.z if mesh_1p else _car_1p.linear_velocity.normalized()
	var fwd_2p: Vector3 = -mesh_2p.global_transform.basis.z if mesh_2p else _car_2p.linear_velocity.normalized()

	# 计算绳子方向与车辆朝向的点积
	# dot > 0: 绳子在身前 (该车是后车)
	# dot < 0: 绳子在身后 (该车是前车)
	var dot_1p: float = fwd_1p.dot(dir_1p)  # 1P 的绳子方向与朝向的关系
	var dot_2p: float = fwd_2p.dot(dir_2p)  # 2P 的绳子方向与朝向的关系

	# 得分越小(越负) = 绳子越在身后 = 越是前车
	# 如果差异明显 (>0.3), 直接判断
	if absf(dot_1p - dot_2p) > 0.3:
		return dot_1p < dot_2p  # 1P 的 dot 更小 = 绳子更在身后 = 1P 是前车

	# 两车情况相似, 看谁速度高 (速度高的是前车)
	var speed_1p: float = _car_1p.linear_velocity.length()
	var speed_2p: float = _car_2p.linear_velocity.length()
	return speed_1p >= speed_2p


## 施加带转向自由度的力
## freedom=0: 纯中心力(车头被拽着对齐); freedom=1: 力施加在车尾(车头可自由转向)
func _apply_force_with_steer_freedom(car: RigidBody3D, force: Vector3, freedom: float) -> void:
	if freedom <= 0.01:
		# 纯中心力
		car.apply_central_force(force)
		return
	# 混合: 一部分中心力 + 一部分偏移力(在车尾施力产生扭矩)
	var central_ratio: float = 1.0 - freedom
	var offset_ratio: float = freedom
	# 中心力部分
	car.apply_central_force(force * central_ratio)
	# 偏移力部分: 在车尾施力 (沿车头反方向偏移)
	var car_mesh: Node3D = car.get_node_or_null("CarMesh")
	if car_mesh:
		var rear_offset: Vector3 = car_mesh.global_transform.basis.z * 1.5  # 车尾方向偏移 1.5m
		car.apply_force(force * offset_ratio, rear_offset)
	else:
		car.apply_central_force(force * offset_ratio)


## ---- 绳子缠绕系统 ----

## 更新绳子缠绕锚点 (多次迭代射线检测, 确保每一段都不穿墙)
func _update_rope_wrap(pos_1p: Vector3, pos_2p: Vector3) -> void:
	# 缠绕开关关闭时, 清空锚点并跳过检测
	if not rope_wrap_enabled:
		_rope_wrap_points.clear()
		_rope_has_penetration = false
		return

	var space_state: PhysicsDirectSpaceState3D = _car_1p.get_world_3d().direct_space_state
	if space_state == null:
		return

	var exclude_rids: Array[RID] = [_car_1p.get_rid(), _car_2p.get_rid()]

	# ---- 添加新锚点: 多次迭代, 直到所有段都不穿墙或达到迭代上限 ----
	var max_total_iterations: int = 50  # 总迭代上限 (防止极端情况死循环)
	var total_iterations: int = 0
	var found_collision: bool = true

	while found_collision and total_iterations < max_total_iterations:
		found_collision = false
		var path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)

		for i in range(path.size() - 1):
			var seg_start: Vector3 = path[i]
			var seg_end: Vector3 = path[i + 1]
			var seg_len: float = seg_start.distance_to(seg_end)
			# 跳过太短的段
			if seg_len < rope_wrap_min_seg_len:
				continue

			# 双向射线检测: 正向 + 反向, 确保不遗漏穿墙
			var query := PhysicsRayQueryParameters3D.create(seg_start, seg_end)
			query.collision_mask = 1  # 只检测静态环境 (layer 1)
			query.exclude = exclude_rids
			var result: Dictionary = space_state.intersect_ray(query)

			# 如果正向没检测到, 尝试反向
			var hit_pos: Vector3
			var hit_normal: Vector3
			var has_hit: bool = false
			if result.size() > 0:
				hit_pos = result["position"]
				hit_normal = result["normal"]
				has_hit = true
			else:
				# 反向射线: seg_end → seg_start
				var rev_query := PhysicsRayQueryParameters3D.create(seg_end, seg_start)
				rev_query.collision_mask = 1
				rev_query.exclude = exclude_rids
				var rev_result: Dictionary = space_state.intersect_ray(rev_query)
				if rev_result.size() > 0:
					hit_pos = rev_result["position"]
					hit_normal = rev_result["normal"]
					has_hit = true

			if has_hit:

				# 计算锚点位置: 碰撞点沿法线偏移
				var anchor: Vector3 = hit_pos + hit_normal * rope_wrap_offset

				# 确保锚点不在墙内: 从锚点沿法线方向射线检测
				var inside_check := PhysicsRayQueryParameters3D.create(anchor, anchor + hit_normal * 0.5)
				inside_check.collision_mask = 1
				inside_check.exclude = exclude_rids
				# 反向检测: 从锚点向墙内射线, 如果命中说明锚点在墙外(正确)
				var reverse_check := PhysicsRayQueryParameters3D.create(anchor, anchor - hit_normal * 0.5)
				reverse_check.collision_mask = 1
				reverse_check.exclude = exclude_rids
				var reverse_result: Dictionary = space_state.intersect_ray(reverse_check)
				if reverse_result.size() == 0:
					# 从锚点向墙内射线没命中, 说明锚点可能在墙内, 增大偏移
					anchor = hit_pos + hit_normal * (rope_wrap_offset * 2.5)

				# 双向验证: 确保 seg_start→anchor 和 anchor→seg_end 都不穿墙
				# 如果 seg_start→anchor 穿墙, 在碰撞点处再加一个锚点
				var check_start := PhysicsRayQueryParameters3D.create(seg_start, anchor)
				check_start.collision_mask = 1
				check_start.exclude = exclude_rids
				var check_start_result: Dictionary = space_state.intersect_ray(check_start)
				if check_start_result.size() > 0:
					# seg_start→anchor 仍穿墙, 用新碰撞点重新计算锚点
					var new_hit_pos: Vector3 = check_start_result["position"]
					var new_hit_normal: Vector3 = check_start_result["normal"]
					anchor = new_hit_pos + new_hit_normal * rope_wrap_offset
					# 再次反向验证
					var rv2 := PhysicsRayQueryParameters3D.create(anchor, anchor - new_hit_normal * 0.5)
					rv2.collision_mask = 1
					rv2.exclude = exclude_rids
					if space_state.intersect_ray(rv2).size() == 0:
						anchor = new_hit_pos + new_hit_normal * (rope_wrap_offset * 2.5)

				# 避免与已有锚点太近 (防止重复添加)
				var too_close: bool = false
				var close_anchor_idx: int = -1
				for eidx in range(_rope_wrap_points.size()):
					if _rope_wrap_points[eidx].distance_to(anchor) < rope_wrap_min_spacing:
						too_close = true
						close_anchor_idx = eidx
						break
				# 也检查是否与两端太近
				if anchor.distance_to(pos_1p) < rope_wrap_min_spacing or anchor.distance_to(pos_2p) < rope_wrap_min_spacing:
					too_close = true
					close_anchor_idx = -1  # 不能移动端点

				if not too_close:
					# 正确的插入位置: path 中第 i 段穿墙 (path[i]→path[i+1])
					# path = [1P, anchor0, anchor1, ..., anchorN, 2P]
					# 第 i 段对应 _rope_wrap_points 中的第 i 个位置 (在第 i 个锚点之前插入)
					# 但 path[0]=1P 不是锚点, 所以实际插入位置 = i
					var insert_idx: int = clampi(i, 0, _rope_wrap_points.size())
					_rope_wrap_points.insert(insert_idx, anchor)
					found_collision = true
					total_iterations += 1
					break  # 重新从头检测所有段
				elif close_anchor_idx >= 0:
					# 附近已有锚点但绳子仍穿墙 → 将已有锚点移动到新计算的位置
					# (比简单推远更准确)
					var old_anchor: Vector3 = _rope_wrap_points[close_anchor_idx]
					var new_anchor: Vector3 = (old_anchor + anchor) * 0.5 + hit_normal * rope_wrap_offset * 0.5
					_rope_wrap_points[close_anchor_idx] = new_anchor
					found_collision = true
					total_iterations += 1
					break  # 重新从头检测

		total_iterations += 1

	# ---- 解缠: 检查锚点是否可以被移除 ----
	_try_unwrap_points(pos_1p, pos_2p, space_state)

	# ---- 最终验证: 确保绳子路径中没有穿墙段 ----
	var final_path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	_rope_has_penetration = false
	for i in range(final_path.size() - 1):
		var seg_start: Vector3 = final_path[i]
		var seg_end: Vector3 = final_path[i + 1]
		if seg_start.distance_to(seg_end) < 0.1:
			continue
		# 正向检测
		var fq := PhysicsRayQueryParameters3D.create(seg_start, seg_end)
		fq.collision_mask = 1
		fq.exclude = exclude_rids
		if space_state.intersect_ray(fq).size() > 0:
			_rope_has_penetration = true
			break
		# 反向检测
		var fq_rev := PhysicsRayQueryParameters3D.create(seg_end, seg_start)
		fq_rev.collision_mask = 1
		fq_rev.exclude = exclude_rids
		if space_state.intersect_ray(fq_rev).size() > 0:
			_rope_has_penetration = true
			break

	# ---- 限制最大锚点数 (防止极端情况下无限增长) ----
	while _rope_wrap_points.size() > rope_wrap_max_anchors:
		_rope_wrap_points.remove_at(_rope_wrap_points.size() / 2)


## 尝试解除不再需要的缠绕锚点 (遍历所有锚点, 循环直到无法再移除)
func _try_unwrap_points(pos_1p: Vector3, pos_2p: Vector3, space_state: PhysicsDirectSpaceState3D) -> void:
	if _rope_wrap_points.size() == 0:
		return

	var exclude_rids: Array[RID] = [_car_1p.get_rid(), _car_2p.get_rid()]

	# 循环检查, 直到一轮中没有任何锚点被移除
	var removed_any: bool = true
	var max_iterations: int = _rope_wrap_points.size() + 5  # 安全上限防止死循环
	while removed_any and max_iterations > 0:
		removed_any = false
		max_iterations -= 1

		# 构建完整路径: [1P, anchor0, anchor1, ..., anchorN, 2P]
		var path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)

		# 从后往前遍历锚点 (倒序遍历, 移除时不影响前面的索引)
		var anchor_idx: int = _rope_wrap_points.size() - 1
		while anchor_idx >= 0:
			var path_idx: int = anchor_idx + 1  # 锚点在 path 中的索引
			var prev_node: Vector3 = path[path_idx - 1]  # 前一个节点 (1P 或上一个锚点)
			var next_node: Vector3 = path[path_idx + 1]  # 后一个节点 (下一个锚点或 2P)

			# 双向射线检测: 确保跳过这个锚点后, 前后节点之间真的不穿墙
			var can_remove: bool = true

			# 正向: prev_node → next_node
			if prev_node.distance_to(next_node) > 0.1:
				var q1 := PhysicsRayQueryParameters3D.create(prev_node, next_node)
				q1.collision_mask = 1
				q1.exclude = exclude_rids
				if space_state.intersect_ray(q1).size() > 0:
					can_remove = false

			# 反向: next_node → prev_node (捕获单面碰撞体的情况)
			if can_remove and prev_node.distance_to(next_node) > 0.1:
				var q2 := PhysicsRayQueryParameters3D.create(next_node, prev_node)
				q2.collision_mask = 1
				q2.exclude = exclude_rids
				if space_state.intersect_ray(q2).size() > 0:
					can_remove = false

			if can_remove:
				# 不穿墙了! 这个锚点不再需要, 移除
				_rope_wrap_points.remove_at(anchor_idx)
				removed_any = true
				# 重新构建路径 (锚点已变化)
				path = _get_rope_path(pos_1p, pos_2p)
			anchor_idx -= 1


## 获取赛车的"视觉绳子绑定点" — 用于绳子渲染的端点
## 不要用 car.global_position! 那是物理球心(空中 1m 位置), 跟视觉车身错位
##
## 球体驱动架构特殊性:
##   car (RigidBody3D)        ← 球心 (空中, 物理位置)
##   └── CarMesh (top_level)   ← 视觉车身 (贴地, 真正看到的位置)
##
## 如果绳子端点用球心 → 绳子从空中出发, 接到视觉车身上看起来"奇怪弯折"
## 修复: 优先用 CarMesh.global_position (视觉车身位置), 让绳子从车身自然出发
##
## 注: 物理拉力依然施加在 car.global_position (球心) — 这是正确的, 球心才是质心
func _get_rope_visual_anchor(car_node: RigidBody3D) -> Vector3:
	if car_node == null:
		return Vector3.ZERO
	# 取 CarMesh (视觉车身) 位置. CarMesh 是 top_level=true, 它的 global_position
	# 就是玩家眼睛看到的车身位置 (贴地的)
	var car_mesh: Node3D = car_node.get_node_or_null("CarMesh") as Node3D
	if car_mesh != null:
		# 加 0.4m 上偏移, 模拟绳子绑在车顶/车尾保险杠上方一点
		# 这样绳子端点不会从车底盘出发, 看起来更自然
		return car_mesh.global_position + Vector3(0.0, 0.4, 0.0)
	# 退化: 没有 CarMesh 就用球心 (向下偏移 0.5m 模拟绳子接近地面)
	return car_node.global_position + Vector3(0.0, -0.5, 0.0)


## 获取绳子完整路径 (1P → 缠绕锚点们 → 2P)
func _get_rope_path(pos_1p: Vector3, pos_2p: Vector3) -> Array[Vector3]:
	var path: Array[Vector3] = [pos_1p]
	for pt in _rope_wrap_points:
		path.append(pt)
	path.append(pos_2p)
	return path


## 创建绳子视觉 (材质共享, 段数动态管理)
## 真绳子材质: 高粗糙度 + 无发光 + 金麻色 = 编织绳子质感
func _create_rope_visual() -> void:
	_cleanup_rope_visual()
	# 重置平滑点 (上次断绳的残留状态会让绳子从奇怪的位置弹出来)
	_rope_smoothed_points = PackedVector3Array()
	_rope_wobble_phase = 0.0
	_rope_mat = StandardMaterial3D.new()
	_rope_mat.albedo_color = rope_color
	# 真绳子: 不发光 + 高粗糙度 (像编织麻绳, 不是发光霓虹管)
	# 注: 模式2(档位变色)和模式3(铁链)会在 _update_rope_visual 里覆盖这些设置
	_rope_mat.emission_enabled = false
	_rope_mat.roughness = 0.95   # 几乎不反光, 模拟粗糙表面
	_rope_mat.metallic = 0.0
	_rope_mat.cull_mode = BaseMaterial3D.CULL_DISABLED


## 更新绳子视觉位置 — 真·绳子 (sag 垂坠 + Q 弹平滑 + 多段曲线)
## 此函数从 _physics_process 调用, 用 physics delta 保证 240Hz 物理下的平滑
func _update_rope_visual() -> void:
	if _car_1p == null or _car_2p == null:
		return
	# 关键: 视觉端点用 CarMesh 的位置 (= 玩家眼睛看到的车身位置), 不是球心
	# 球体驱动架构: car 是空中的球, CarMesh top_level 单独贴地, 用 car.global_position
	# 会导致绳子从空中出发到地面车身, 视觉上"弯折"
	var pos_1p: Vector3 = _get_rope_visual_anchor(_car_1p)
	var pos_2p: Vector3 = _get_rope_visual_anchor(_car_2p)
	var path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	if path.size() < 2:
		return

	# ---- 1. 计算 sag (绳子松弛量决定中段垂多深) ----
	# natural_len 取决于当前模式. 模式3用 rope_mode3_length, 模式1/2用 rope_length
	var natural_len: float = rope_length
	if rope_mode3_enabled:
		natural_len = rope_mode3_length
	# direct_len = 实际绳子总路径长度 (走缠绕锚点的总长). 已在物理帧里算过, 用 _rope_total_length
	# 但 _rope_total_length 在 mode1 if-stretch<0 时不会更新, 这里重新算一遍保证有效
	var actual_path_len: float = 0.0
	for i in range(path.size() - 1):
		actual_path_len += path[i].distance_to(path[i + 1])
	# slack = "绳子比当前路径长了多少". slack > 0 时绳子可以垂下来; slack ≤ 0 时绷直无垂坠
	var slack: float = maxf(natural_len - actual_path_len, 0.0)
	# sag_max = 中段最大垂坠量 (米)
	# 数学 (旧版): sag_max = slack × sag_factor × 0.5
	#   bug: 绳长 18m 两车距离 5m → slack=13 → sag=3.25m
	#        绳子中段下垂 3 米, 视觉上压在车身上 (用户反馈"绳子缠绕赛车本身")
	# 数学 (新版): sag_max = min(slack × sag_factor × 0.5, direct × 0.3, ABS_MAX)
	#   多重约束:
	#     ① slack × factor × 0.5  ← 原始逻辑 (松弛量决定垂坠基础)
	#     ② direct × 0.3          ← 距离近时不允许垂太深 (距离 5m → 上限 1.5m)
	#                              物理直觉: 两车很近时绳子团成一坨在中间, 不会垂得很深
	#     ③ ABS_MAX = 2.0 m       ← 绝对上限, 任何情况下不会比这更深
	#                              (车身高约 1m, sag 上限 2m 视觉上不会覆盖车头)
	# 模式3 (铁链) 重力下垂被金属刚性吸收, 所以乘 0.4 弱化
	var direct_dist: float = path[0].distance_to(path[path.size() - 1])
	const SAG_ABS_MAX: float = 2.0   # 绝对上限 (米), 防止任何极端情况下绳子下垂过深压到车
	var sag_max: float = slack * rope_sag_factor * 0.5
	sag_max = minf(sag_max, direct_dist * 0.3)   # 与两车直线距离挂钩的相对上限
	sag_max = minf(sag_max, SAG_ABS_MAX)         # 绝对上限兜底
	if rope_mode3_enabled:
		sag_max *= 0.4

	# ---- 2. 沿路径生成 raw target points (含 sag 抛物线垂坠) ----
	# 总采样点数 = 路径段数 × subdivisions + 1 (端点)
	var subs: int = maxi(rope_subdivisions, 2)
	var raw_points: PackedVector3Array = PackedVector3Array()
	for i in range(path.size() - 1):
		var p0: Vector3 = path[i]
		var p1: Vector3 = path[i + 1]
		# 当前段细分: 输出 subs 个点 (j=0..subs-1, t=0..1-1/subs)
		# 下一段会以 t=0 开头自然衔接, 所以本段不输出 j=subs (避免重复)
		# 但最后一段需要补上 j=subs (= p1, 即终点)
		var n: int = subs if i < path.size() - 2 else subs + 1
		for j in range(n):
			var t: float = float(j) / float(subs)
			# 路径线性插值
			var pt: Vector3 = p0.lerp(p1, t)
			# Sag: 抛物线 4t(1-t), t=0 或 1 时为 0, t=0.5 时为 1
			# 注意: sag 应该让绳子在世界 -Y 方向下垂 (重力)
			# 但是如果路径本身已经是斜的, 单纯减 Y 会让绳子穿地
			# 这里简单处理: 只在 sag_max > 0 时减 Y, 路径斜的话垂坠仍指世界下
			var sag_t: float = 4.0 * t * (1.0 - t)
			pt.y -= sag_t * sag_max
			raw_points.append(pt)
	var total_samples: int = raw_points.size()

	# ---- 3. 平滑: smoothed_points 朝 raw_points 做指数衰减 lerp (Q 弹核心) ----
	# 第一次或采样点数变了 (绕了新锚点等) → 直接用 raw 不做 lerp 避免一次性弹飞
	if _rope_smoothed_points.size() != total_samples:
		_rope_smoothed_points = raw_points.duplicate()
		_rope_last_path_len = actual_path_len  # 同步基线, 避免本帧虚假触发摆动
	# 用 physics delta (从 _physics_process 调用本函数, 应该是 1/240 = 4ms)
	var dt: float = get_physics_process_delta_time()
	# alpha = 1 - exp(-wobble_speed × dt). 例如 dt=0.004, speed=18 → alpha ≈ 0.069
	# 物理意义: 每帧把 smoothed 朝 target 拉近 7%, 大约 0.16s 完成 95% 收敛
	var alpha: float = 1.0 - exp(-rope_wobble_speed * dt)

	# ---- 3a. 摆动能量管理 (用户要求: 静止时不摆, 拉伸/扰动时才摆) ----
	# 数学:
	#   触发: dL/dt = (actual_path_len - _rope_last_path_len) / dt   ; 路径长度变化率 m/s
	#         如果 |dL/dt| > min_trigger_speed:
	#             energy += (|dL/dt| - min_trigger_speed) × trigger_gain × dt
	#   衰减: energy *= exp(-wobble_decay × dt)
	#   钳制: energy ∈ [0, 1]
	# 物理意义:
	#   绳子被快速拉伸 (dL/dt > 0, 比如车互相远离) → 累积摆动能量
	#   绳子被快速放松 (dL/dt < 0, 比如车互相靠近, 也会导致绳子甩动) → 也累积
	#   两车几乎不动 (|dL/dt| ≈ 0) → 不累积, 已有能量自然衰减
	# 注: 这是用户专门要求的"符合物理的真实绳子"行为
	var dL: float = actual_path_len - _rope_last_path_len
	_rope_last_path_len = actual_path_len
	var dL_speed: float = absf(dL) / maxf(dt, 0.0001)   # 米/秒
	if dL_speed > rope_wobble_min_trigger_speed:
		# 超过阈值才累积能量 (过滤微小漂移)
		var excess: float = dL_speed - rope_wobble_min_trigger_speed
		_rope_wobble_energy += excess * rope_wobble_trigger_gain * dt
	# 衰减 (始终执行, 不管有没有触发)
	_rope_wobble_energy *= exp(-rope_wobble_decay * dt)
	# 钳制
	_rope_wobble_energy = clampf(_rope_wobble_energy, 0.0, 1.0)
	# 当能量低于一个很小的阈值时直接归零 (避免"无限小"的浮点抖动)
	if _rope_wobble_energy < 0.005:
		_rope_wobble_energy = 0.0

	# 摆动相位: 只在 energy > 0 时推进, 静止时不动 (省一点 CPU 也避免相位累积)
	if _rope_wobble_energy > 0.0:
		_rope_wobble_phase += dt * rope_wobble_freq * TAU

	for i in range(total_samples):
		var target: Vector3 = raw_points[i]
		# 端点 (i=0 或 i=total_samples-1) 必须贴车, 不做平滑也不抖动
		# 否则绳子会脱离车身浮空看起来超假
		if i == 0 or i == total_samples - 1:
			_rope_smoothed_points[i] = target
			continue
		# 中段: 指数衰减 lerp, 但靠近端点时增强 alpha 让它\"也跟着瞬时\"
		# ============================================================
		# 用户反馈: \"赛车有速度时, 靠近赛车段的绳子会弯折\"
		# 原因: 端点不做 lerp 直接 = target (瞬时跟车),
		#       但相邻采样点 (i=1) 用 alpha~0.07 慢慢追,
		#       高速移动时 (车每帧瞬移 0.08m), 端点和 i=1 之间产生明显落差
		#       → 视觉上看起来车身附近\"折\"了一下
		# 修复: 让 alpha 在靠近端点时趋近 1.0 (跟车瞬时无滞后),
		#       中段保持原 alpha (Q 弹感保留)
		# 数学:
		#   t_g = i / (total-1) ∈ [0, 1]
		#   edge_proximity = (1 - sin(t_g × π))^2 ∈ [0, 1]
		#       t_g=0 或 1 → edge_proximity = 1 (端点附近)
		#       t_g=0.5  → edge_proximity = 0 (中段)
		#       平方让\"端点附近\" 更陡峭, 只有 ~10% 区域受影响, 不破坏中段 Q 弹
		#   alpha_local = lerp(alpha, 1.0, edge_proximity)
		#       端点附近 alpha_local → 1 (瞬时跟车)
		#       中段 alpha_local = alpha (原 Q 弹)
		# ============================================================
		var t_g_for_alpha: float = float(i) / float(total_samples - 1)
		var edge_proximity: float = pow(1.0 - sin(t_g_for_alpha * PI), 2.0)
		var alpha_local: float = lerp(alpha, 1.0, edge_proximity)
		var smoothed: Vector3 = _rope_smoothed_points[i].lerp(target, alpha_local)
		# 横向摆动: 中段最大, 两端 0 (用 sin(πt) 包络)
		# t_global ∈ (0, 1), 越靠中间 envelope 越大 (sin(π × 0.5) = 1)
		var t_global: float = float(i) / float(total_samples - 1)
		var envelope: float = sin(t_global * PI)
		# 关键: wobble_amp 实际值 = 配置峰值 × 当前能量 (能量为 0 时完全不摆)
		var actual_amp: float = rope_wobble_amp * _rope_wobble_energy
		if envelope > 0.01 and actual_amp > 0.001 and sag_max < natural_len * 0.5:
			# 摆动只在 sag 不太大时启用 (绳子绷紧时也允许小幅抖, 但松弛太多不抖防穿地)
			# 用 envelope × actual_amp × sin(phase + 频率沿绳分布) 实现"行波"感
			var wobble_phase_local: float = _rope_wobble_phase + t_global * 6.0
			# Y 方向小幅抖 (主要)
			smoothed.y += sin(wobble_phase_local) * actual_amp * envelope * 0.5
			# X 方向 (用 cos 错相位避免同步) — 让绳子有"扭转"感
			smoothed.x += cos(wobble_phase_local * 1.3) * actual_amp * envelope * 0.3
		_rope_smoothed_points[i] = smoothed

	# ---- 4. 用平滑后的相邻点对生成绳子 mesh ----
	var seg_count: int = total_samples - 1
	# 动态扩容
	while _rope_segments.size() < seg_count:
		var seg := MeshInstance3D.new()
		seg.name = "CoopRopeSeg_%d" % _rope_segments.size()
		var cyl := CylinderMesh.new()
		cyl.top_radius = rope_visual_thickness
		cyl.bottom_radius = rope_visual_thickness
		cyl.height = 1.0
		cyl.radial_segments = 6   # 细一点节省 GPU, 6 边形圆柱看着已经够圆
		seg.mesh = cyl
		if _rope_mat:
			seg.material_override = _rope_mat
		# 关阴影投射: 64+ 段绳子投阴影会很贵
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().current_scene.add_child(seg)
		_rope_segments.append(seg)
	# 隐藏多余的段
	for i in range(_rope_segments.size()):
		_rope_segments[i].visible = i < seg_count
	# 同步每段的位置和朝向
	for i in range(seg_count):
		var p0: Vector3 = _rope_smoothed_points[i]
		var p1: Vector3 = _rope_smoothed_points[i + 1]
		var seg_vec: Vector3 = p1 - p0
		var seg_len: float = seg_vec.length()
		var seg_mesh: MeshInstance3D = _rope_segments[i]
		if seg_len < 0.001:
			seg_mesh.visible = false
			continue
		var mid: Vector3 = (p0 + p1) * 0.5
		var up_hint: Vector3 = Vector3.UP
		if absf(seg_vec.normalized().dot(Vector3.UP)) > 0.99:
			up_hint = Vector3.RIGHT
		seg_mesh.look_at_from_position(mid, p1, up_hint)
		seg_mesh.rotate_object_local(Vector3.RIGHT, deg_to_rad(90.0))
		seg_mesh.scale = Vector3(1.0, seg_len, 1.0)

	# ---- 5. 颜色 / 材质: 模式3=金属铁链, 模式2=档位颜色, 模式1=拉伸程度变色 ----
	if _rope_mat:
		if rope_mode3_enabled:
			# 模式3: 金属铁链外观
			_rope_mat.albedo_color = rope_mode3_chain_color
			_rope_mat.emission = rope_mode3_chain_color * 0.5
			_rope_mat.emission_energy_multiplier = rope_mode3_chain_emission
			_rope_mat.emission_enabled = rope_mode3_chain_emission > 0.01
			_rope_mat.metallic = 0.85
			_rope_mat.roughness = 0.4
			# 同步链节粗细
			for seg in _rope_segments:
				if seg and seg.mesh is CylinderMesh:
					var cyl: CylinderMesh = seg.mesh
					if not is_equal_approx(cyl.top_radius, rope_mode3_chain_thickness):
						cyl.top_radius = rope_mode3_chain_thickness
						cyl.bottom_radius = rope_mode3_chain_thickness
		elif rope_mode2_enabled:
			# 模式2: 档位颜色 (绿/黄/红等), 保留低发光让档位颜色更醒目
			var tier_col: Color = _get_mode2_tier_color()
			_rope_mat.albedo_color = tier_col
			_rope_mat.emission_enabled = true
			_rope_mat.emission = tier_col
			_rope_mat.emission_energy_multiplier = 1.2
			_rope_mat.metallic = 0.0
			_rope_mat.roughness = 0.7
			# 模式2 用绳子粗细
			for seg in _rope_segments:
				if seg and seg.mesh is CylinderMesh:
					var cyl: CylinderMesh = seg.mesh
					if not is_equal_approx(cyl.top_radius, rope_visual_thickness):
						cyl.top_radius = rope_visual_thickness
						cyl.bottom_radius = rope_visual_thickness
		else:
			# 模式1: 真·绳子. 颜色随拉伸变化 (松弛=金麻色, 拉紧=偏红)
			# 关键: 不开 emission_enabled, 让绳子是粗糙麻绳质感, 不是发光的霓虹管
			var stretch_amount: float = _rope_total_length - rope_length
			var tension: float = clampf(stretch_amount / maxf(rope_elasticity * 2.0, 1.0), 0.0, 1.0)
			var col: Color = rope_color.lerp(Color(0.85, 0.25, 0.15), tension)
			_rope_mat.albedo_color = col
			_rope_mat.emission_enabled = false
			_rope_mat.metallic = 0.0
			_rope_mat.roughness = 0.95
			# 同步绳子粗细
			for seg in _rope_segments:
				if seg and seg.mesh is CylinderMesh:
					var cyl: CylinderMesh = seg.mesh
					if not is_equal_approx(cyl.top_radius, rope_visual_thickness):
						cyl.top_radius = rope_visual_thickness
						cyl.bottom_radius = rope_visual_thickness


## 清理绳子视觉
func _cleanup_rope_visual() -> void:
	for seg in _rope_segments:
		if seg and is_instance_valid(seg):
			seg.queue_free()
	_rope_segments.clear()
	_rope_mat = null
	# 清空平滑/能量缓存, 否则下次连绳会从旧位置弹出来或者继承旧能量
	_rope_smoothed_points = PackedVector3Array()
	_rope_wobble_phase = 0.0
	_rope_wobble_energy = 0.0
	_rope_last_path_len = 0.0
	# 重置模式3绷紧标志, 下次连绳第一次绷紧时能正常 jerk
	_rope_mode3_was_taut = false


## 每帧更新分屏摄像机 (跟随各自的赛车)
func _process(delta: float) -> void:
	if not _active:
		return
	_update_split_cameras(delta)


## 更新分屏摄像机跟随
## 注: Camera3D.gd 脚本自动处理跟随逻辑, 这里不需要手动更新
## 但保留此函数以备将来需要额外处理 (如绳子拉紧时的镜头反应)
func _update_split_cameras(delta: float) -> void:
	pass


## 复制摄像机参数 (从原始摄像机复制 @export 属性到分屏摄像机)
func _copy_camera_params(src: Camera3D, dst: Camera3D) -> void:
	if src == null or dst == null:
		return
	for prop_info in src.get_property_list():
		var prop_name: String = prop_info["name"]
		# 跳过不应复制的属性
		if prop_name in ["target", "current", "script", "name", "owner", "position", "rotation", "transform", "global_transform", "global_position", "global_rotation"]:
			continue
		var usage: int = prop_info["usage"]
		if not (usage & PROPERTY_USAGE_STORAGE and usage & PROPERTY_USAGE_EDITOR):
			continue
		if prop_name in dst:
			var val = src.get(prop_name)
			if val is Curve:
				val = val.duplicate() if val != null else null
			dst.set(prop_name, val)


## ============================================================
## 尾流能量系统: 后车尾随前车积累能量, 满后可突进
## ============================================================

## 每物理帧更新尾流能量 (在 _physics_process 中调用)
func _update_slipstream_energy(delta: float) -> void:
	if _car_1p == null or _car_2p == null:
		return

	# 更新冷却计时器
	if _slipstream_cooldown_1p > 0.0:
		_slipstream_cooldown_1p -= delta
	if _slipstream_cooldown_2p > 0.0:
		_slipstream_cooldown_2p -= delta

	# 判断前后车
	var pos_1p: Vector3 = _car_1p.global_position
	var pos_2p: Vector3 = _car_2p.global_position
	var dir_1p_to_2p: Vector3 = (pos_2p - pos_1p).normalized()
	var dir_2p_to_1p: Vector3 = -dir_1p_to_2p

	var is_1p_front: bool = _is_1p_front_car(dir_1p_to_2p, dir_2p_to_1p)

	# 确定前车和后车
	var front_car: RigidBody3D = _car_1p if is_1p_front else _car_2p
	var rear_car: RigidBody3D = _car_2p if is_1p_front else _car_1p
	var is_rear_1p: bool = not is_1p_front  # 后车是否是1P

	# 计算两车距离
	var dist: float = pos_1p.distance_to(pos_2p)

	# 判断后车是否在前车的尾流区域内
	var in_slipstream: bool = _check_in_slipstream(front_car, rear_car, dist)

	# 更新后车的尾流能量
	if is_rear_1p:
		_update_single_slipstream(delta, in_slipstream, true)
		# 2P 是前车, 不积累尾流能量, 衰减
		_decay_slipstream(delta, false)
	else:
		_update_single_slipstream(delta, in_slipstream, false)
		# 1P 是前车, 不积累尾流能量, 衰减
		_decay_slipstream(delta, true)


## 检查后车是否在前车的尾流区域内
func _check_in_slipstream(front_car: RigidBody3D, rear_car: RigidBody3D, dist: float) -> bool:
	# 距离检查
	if dist < rope_mode2_slipstream_min_dist or dist > rope_mode2_slipstream_max_dist:
		return false

	# 角度检查: 后车必须在前车身后的锥形区域内
	var front_mesh: Node3D = front_car.get_node_or_null("CarMesh")
	var front_fwd: Vector3
	if front_mesh:
		front_fwd = -front_mesh.global_transform.basis.z
	else:
		front_fwd = front_car.linear_velocity.normalized()

	if front_fwd.length_squared() < 0.01:
		return false

	# 从前车指向后车的方向
	var to_rear: Vector3 = (rear_car.global_position - front_car.global_position).normalized()
	# 后车应该在前车的身后 (与前车朝向相反的方向)
	var dot: float = front_fwd.dot(to_rear)
	# dot < 0 表示后车在前车身后
	# 将角度阈值转换为 cos 值 (注意是负方向)
	var angle_cos: float = cos(deg_to_rad(rope_mode2_slipstream_angle_threshold))
	# 后车在前车身后的锥形区域: dot < -cos(threshold)
	return dot < -angle_cos


## 更新单个玩家的尾流能量 (积累)
func _update_single_slipstream(delta: float, in_slipstream: bool, is_1p: bool) -> void:
	var cooldown: float = _slipstream_cooldown_1p if is_1p else _slipstream_cooldown_2p
	if cooldown > 0.0:
		# 冷却中, 不积累
		return

	if in_slipstream:
		# 在尾流中, 积累能量
		if is_1p:
			_slipstream_energy_1p = minf(_slipstream_energy_1p + rope_mode2_slipstream_charge_rate * delta, rope_mode2_slipstream_max_energy)
		else:
			_slipstream_energy_2p = minf(_slipstream_energy_2p + rope_mode2_slipstream_charge_rate * delta, rope_mode2_slipstream_max_energy)
	else:
		# 不在尾流中, 衰减能量
		_decay_slipstream(delta, is_1p)


## 衰减尾流能量
func _decay_slipstream(delta: float, is_1p: bool) -> void:
	if is_1p:
		_slipstream_energy_1p = maxf(_slipstream_energy_1p - rope_mode2_slipstream_decay_rate * delta, 0.0)
	else:
		_slipstream_energy_2p = maxf(_slipstream_energy_2p - rope_mode2_slipstream_decay_rate * delta, 0.0)


## 尝试使用尾流突进 (按键触发)
func _try_slipstream_boost(car: RigidBody3D, is_1p: bool) -> void:
	if car == null:
		return

	var energy: float = _slipstream_energy_1p if is_1p else _slipstream_energy_2p
	var cooldown: float = _slipstream_cooldown_1p if is_1p else _slipstream_cooldown_2p

	# 检查能量是否满
	if energy < rope_mode2_slipstream_max_energy:
		print("[CoopMode] 尾流突进失败: 能量不足 (%.1f/%.1f)" % [energy, rope_mode2_slipstream_max_energy])
		return

	# 检查冷却
	if cooldown > 0.0:
		print("[CoopMode] 尾流突进失败: 冷却中 (%.1fs)" % cooldown)
		return

	# 消耗能量
	if is_1p:
		_slipstream_energy_1p = 0.0
		_slipstream_cooldown_1p = rope_mode2_slipstream_boost_cooldown
	else:
		_slipstream_energy_2p = 0.0
		_slipstream_cooldown_2p = rope_mode2_slipstream_boost_cooldown

	# 给后车施加 boost (使用 car 的 _start_boost 方法)
	if car.has_method("_start_boost"):
		car._start_boost("slipstream", rope_mode2_slipstream_boost_power, rope_mode2_slipstream_boost_duration)
		print("[CoopMode] 尾流突进! %s 获得 power=%.0f, duration=%.1fs" % ["1P" if is_1p else "2P", rope_mode2_slipstream_boost_power, rope_mode2_slipstream_boost_duration])
	else:
		# 备用方案: 直接施加冲量
		var car_mesh: Node3D = car.get_node_or_null("CarMesh")
		var boost_dir: Vector3
		if car_mesh:
			boost_dir = -car_mesh.global_transform.basis.z
		else:
			boost_dir = car.linear_velocity.normalized()
		if boost_dir.length_squared() < 0.01:
			boost_dir = Vector3.FORWARD
		car.apply_central_impulse(boost_dir * rope_mode2_slipstream_boost_power * 0.5)
		print("[CoopMode] 尾流突进(冲量模式)! %s" % ["1P" if is_1p else "2P"])

	# HUD 弹字反馈
	var hud = _hud_1p if is_1p else _hud_2p
	if hud and hud.has_method("show_slipstream_boost_popup"):
		hud.show_slipstream_boost_popup()


## 重置尾流能量状态 (绳子断开时调用)
func _reset_slipstream() -> void:
	_slipstream_energy_1p = 0.0
	_slipstream_energy_2p = 0.0
	_slipstream_cooldown_1p = 0.0
	_slipstream_cooldown_2p = 0.0
	if _slipstream_particles_1p and is_instance_valid(_slipstream_particles_1p):
		_slipstream_particles_1p.queue_free()
		_slipstream_particles_1p = null
	if _slipstream_particles_2p and is_instance_valid(_slipstream_particles_2p):
		_slipstream_particles_2p.queue_free()
		_slipstream_particles_2p = null
	_hide_slipstream_hud()


## 更新 HUD 上的尾流能量显示
func _update_slipstream_hud() -> void:
	# 确保尾流 UI 已创建
	if _hud_1p and _hud_1p.has_method("create_slipstream_ui"):
		if _hud_1p.get("_slipstream_container") == null:
			_hud_1p.create_slipstream_ui()
		_hud_1p.update_slipstream_ui(_slipstream_energy_1p, rope_mode2_slipstream_max_energy, _slipstream_cooldown_1p)
	if _hud_2p and _hud_2p.has_method("create_slipstream_ui"):
		if _hud_2p.get("_slipstream_container") == null:
			_hud_2p.create_slipstream_ui()
		_hud_2p.update_slipstream_ui(_slipstream_energy_2p, rope_mode2_slipstream_max_energy, _slipstream_cooldown_2p)


## 隐藏 HUD 上的尾流能量显示
func _hide_slipstream_hud() -> void:
	if _hud_1p and _hud_1p.has_method("hide_slipstream_ui"):
		_hud_1p.hide_slipstream_ui()
	if _hud_2p and _hud_2p.has_method("hide_slipstream_ui"):
		_hud_2p.hide_slipstream_ui()


# ============================================================
#  绳子吃星星系统
# ============================================================
var _star_collected_total: int = 0          ## 本局已收集星星总数
var _star_combo: int = 0                    ## 当前连击数
var _star_combo_timer: float = 0.0          ## 连击宽容倒计时 (秒)
const STAR_COMBO_WINDOW: float = 0.4        ## 连击宽容窗口 (秒)

## 获取当前星星收集总数 (供 HUD 读取)
func get_star_count() -> int:
	return _star_collected_total

## 赛车直接碰到星星时由 Block_StarTrail 调用
func on_star_collected_by_car(star_world_pos: Vector3 = Vector3.INF) -> void:
	_star_collected_total += 1
	_star_combo += 1
	_star_combo_timer = STAR_COMBO_WINDOW
	_flash_rope_on_star_collect()
	_spawn_spiral_fx(star_world_pos)
	_update_star_hud(star_world_pos)

## 获取当前连击数
func get_star_combo() -> int:
	return _star_combo

## 每物理帧检测绳子路径是否穿过星星碰撞球
func _check_rope_star_collection() -> void:
	if _car_1p == null or _car_2p == null:
		return
	# 连击倒计时
	var dt: float = get_physics_process_delta_time()
	if _star_combo_timer > 0.0:
		_star_combo_timer -= dt
		if _star_combo_timer <= 0.0:
			_star_combo = 0  # 连击断裂

	# 获取绳子路径 (含缠绕锚点)
	var pos_1p: Vector3 = _get_rope_visual_anchor(_car_1p)
	var pos_2p: Vector3 = _get_rope_visual_anchor(_car_2p)
	var rope_path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	if rope_path.size() < 2:
		return

	# 遍历场景中所有绳星轨迹
	var trails: Array = get_tree().get_nodes_in_group("star_trails")
	for trail in trails:
		if not trail.has_method("get_uncollected_stars"):
			continue
		var stars: Array = trail.call("get_uncollected_stars")
		for star_info in stars:
			var star_pos: Vector3 = star_info["world_pos"]
			var radius: float = star_info["radius"]
			var star_idx: int = star_info["index"]
			# 检测: 绳子路径中任意线段是否穿过星星球
			if _rope_intersects_sphere(rope_path, star_pos, radius):
				trail.call("collect_star", star_idx)
				_star_collected_total += 1
				_star_combo += 1
				_star_combo_timer = STAR_COMBO_WINDOW
				# 绳子短暂发光反馈
				_flash_rope_on_star_collect()
				# 螺旋缠绕效果
				_spawn_spiral_fx(star_pos)
				# 通知 HUD 更新 (传星星世界坐标)
				_update_star_hud(star_pos)


## 线段组是否穿过球体 (宽松判定: 线段到球心最短距离 < 半径)
func _rope_intersects_sphere(path: Array[Vector3], center: Vector3, radius: float) -> bool:
	for i in range(path.size() - 1):
		var a: Vector3 = path[i]
		var b: Vector3 = path[i + 1]
		var ab: Vector3 = b - a
		var ab_len_sq: float = ab.length_squared()
		if ab_len_sq < 0.0001:
			if a.distance_to(center) < radius:
				return true
			continue
		# 投影参数 t, 限制在 [0,1]
		var t: float = clampf((center - a).dot(ab) / ab_len_sq, 0.0, 1.0)
		var closest: Vector3 = a + ab * t
		if closest.distance_to(center) < radius:
			return true
	return false


## 绳子短暂发光 (收集反馈)
func _flash_rope_on_star_collect() -> void:
	if _rope_mat == null:
		return
	# 临时高亮: 保存原色 → 改成金色高 emission → 0.15s 后恢复
	var orig_emission_enabled: bool = _rope_mat.emission_enabled
	var orig_emission: Color = _rope_mat.emission if _rope_mat.emission_enabled else Color.BLACK
	var orig_energy: float = _rope_mat.emission_energy_multiplier
	_rope_mat.emission_enabled = true
	_rope_mat.emission = Color(1.0, 0.9, 0.3)
	_rope_mat.emission_energy_multiplier = 6.0
	# 用 tween 恢复
	var tw: Tween = create_tween()
	tw.tween_interval(0.15)
	tw.tween_callback(func() -> void:
		if _rope_mat:
			_rope_mat.emission_enabled = orig_emission_enabled
			_rope_mat.emission = orig_emission
			_rope_mat.emission_energy_multiplier = orig_energy
	)


## 星星缠绕绳子的螺旋运动效果 — 粒子紧贴绳子从碰撞点向两端缠绕
## center: 星星被收集时的世界坐标 (碰撞点)
## 实现: 获取当前绳子路径, 找到碰撞点在路径上的最近点, 然后生成两组粒子
##       一组向 1P 方向缠绕, 一组向 2P 方向缠绕. 每个粒子沿路径前进并绕路径
##       切线螺旋旋转 (半径很小, 紧贴绳子表面)
func _spawn_spiral_fx(center: Vector3) -> void:
	if center == Vector3.INF:
		return
	if _car_1p == null or _car_2p == null:
		return
	# 获取绳子路径
	var pos_1p: Vector3 = _get_rope_visual_anchor(_car_1p)
	var pos_2p: Vector3 = _get_rope_visual_anchor(_car_2p)
	var rope_path: Array[Vector3] = _get_rope_path(pos_1p, pos_2p)
	if rope_path.size() < 2:
		return

	# 计算路径累积长度
	var cum_len: Array[float] = [0.0]
	for i in range(1, rope_path.size()):
		cum_len.append(cum_len[i - 1] + rope_path[i].distance_to(rope_path[i - 1]))
	var total_len: float = cum_len[cum_len.size() - 1]
	if total_len < 0.5:
		return

	# 找碰撞点在绳子路径上的最近投影 t (0~1 归一化)
	var best_t: float = 0.5
	var best_dist: float = INF
	for i in range(rope_path.size() - 1):
		var a: Vector3 = rope_path[i]
		var b: Vector3 = rope_path[i + 1]
		var ab: Vector3 = b - a
		var ab_len_sq: float = ab.length_squared()
		var local_t: float = 0.0
		if ab_len_sq > 0.0001:
			local_t = clampf((center - a).dot(ab) / ab_len_sq, 0.0, 1.0)
		var closest: Vector3 = a + ab * local_t
		var d: float = closest.distance_to(center)
		if d < best_dist:
			best_dist = d
			# 全局 t = (cum_len[i] + local_t * seg_len) / total_len
			var seg_len: float = cum_len[i + 1] - cum_len[i]
			best_t = (cum_len[i] + local_t * seg_len) / total_len

	# 沿路径采样一个世界坐标 (t ∈ [0,1])
	# 返回 {pos: Vector3, tangent: Vector3}
	var _sample_path := func(t_val: float) -> Dictionary:
		var target_len: float = t_val * total_len
		var seg_i: int = 0
		for i in range(1, cum_len.size()):
			if cum_len[i] >= target_len:
				seg_i = i - 1
				break
			seg_i = i - 1
		var seg_len: float = cum_len[seg_i + 1] - cum_len[seg_i]
		var lt: float = (target_len - cum_len[seg_i]) / maxf(seg_len, 0.001)
		var pos: Vector3 = rope_path[seg_i].lerp(rope_path[seg_i + 1], lt)
		var tangent: Vector3 = (rope_path[seg_i + 1] - rope_path[seg_i]).normalized()
		return {"pos": pos, "tangent": tangent}

	# 创建效果根节点
	var fx_root := Node3D.new()
	get_tree().current_scene.add_child(fx_root)

	# 粒子材质 (金色发光半透明)
	var star_mat := StandardMaterial3D.new()
	star_mat.albedo_color = Color(1.0, 0.9, 0.2, 0.85)
	star_mat.emission_enabled = true
	star_mat.emission = Color(1.0, 0.85, 0.1)
	star_mat.emission_energy_multiplier = 3.5
	star_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	star_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# 共享球体 mesh
	var shared_sphere := SphereMesh.new()
	shared_sphere.radius = 0.12
	shared_sphere.height = 0.24
	shared_sphere.radial_segments = 6
	shared_sphere.rings = 3

	# 每个方向 3 个粒子, 共 6 个
	var particles_per_dir: int = 3
	var all_particles: Array[MeshInstance3D] = []
	for i in range(particles_per_dir * 2):
		var mi := MeshInstance3D.new()
		mi.mesh = shared_sphere
		mi.material_override = star_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fx_root.add_child(mi)
		all_particles.append(mi)

	# 动画参数
	var duration: float = 0.7          # 总时长
	var spiral_radius: float = 0.35    # 螺旋半径 (紧贴绳子)
	var spiral_turns: float = 4.0      # 螺旋圈数
	var steps: int = 24

	var tw := fx_root.create_tween()
	for step in range(steps):
		var progress: float = float(step + 1) / float(steps)
		tw.tween_callback(func() -> void:
			# 粒子 [0..particles_per_dir-1] 向 1P 方向 (t 递减)
			# 粒子 [particles_per_dir..end] 向 2P 方向 (t 递增)
			for pi in range(all_particles.size()):
				var dir_sign: float = -1.0 if pi < particles_per_dir else 1.0
				var local_idx: int = pi % particles_per_dir
				# 每个粒子有相位偏移让它们不重叠
				var phase_offset: float = float(local_idx) * TAU / float(particles_per_dir)
				# 当前 t 在路径上的位置
				var current_t: float = best_t + dir_sign * progress * (1.0 - best_t if dir_sign > 0.0 else best_t)
				current_t = clampf(current_t, 0.0, 1.0)
				var sample: Dictionary = _sample_path.call(current_t)
				var path_pos: Vector3 = sample["pos"]
				var tangent: Vector3 = sample["tangent"]
				# 计算垂直于切线的螺旋偏移
				var up: Vector3 = Vector3.UP
				var right: Vector3 = tangent.cross(up).normalized()
				if right.length_squared() < 0.01:
					right = Vector3.RIGHT
				var local_up: Vector3 = right.cross(tangent).normalized()
				# 螺旋角度
				var angle: float = progress * spiral_turns * TAU + phase_offset
				var r: float = spiral_radius * (1.0 - progress * 0.4)  # 越远越收紧
				var offset: Vector3 = right * cos(angle) * r + local_up * sin(angle) * r
				all_particles[pi].global_position = path_pos + offset
				# 缩小渐隐
				all_particles[pi].scale = Vector3.ONE * (1.0 - progress * 0.6)
		)
		tw.tween_interval(duration / float(steps))
	tw.tween_callback(func() -> void:
		fx_root.queue_free()
	)


## 通知 HUD 更新星星计数 (传递星星世界坐标用于飞行动效)
func _update_star_hud(star_world_pos: Vector3 = Vector3.INF) -> void:
	if _hud_1p and _hud_1p.has_method("update_star_count"):
		_hud_1p.call("update_star_count", _star_collected_total, _star_combo, star_world_pos)
	if _hud_2p and _hud_2p.has_method("update_star_count"):
		_hud_2p.call("update_star_count", _star_collected_total, _star_combo, star_world_pos)
