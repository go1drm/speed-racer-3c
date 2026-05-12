extends RigidBody3D
## ============================================================
##  QQ飞车式车辆控制器 v3 —— 炸弹猫精调版
##  操作：↑↓←→ 方向 · Q 点按入漂 · W 小喷退漂 · E 氮气
##  核心：点按Q入漂 → 方向键控制漂移角度 → 角度足够后按W退漂+小喷
##  集气公式：侧向滑移距离 × 基础率 + 车头角速度 × 权重
##  撞墙：当前漂移累计集气 × 0.2（扣80%）
## ============================================================

# ============================================================
#  QQ飞车式车辆控制器 v4 —— 炸弹猫精调版(V2 物理独一套)
#  操作：↑↓←→ 方向 · Q 点按入漂 · W 小喷退漂 · E 氮气
#  物理模型:
#    · 引擎推力 = engine_force_max × 引擎曲线(当前速度/当前极速) × 油门
#    · 摩擦沿惯性方向反向分解为 long / lat 两层, 各有速度曲线
#    · 漂移状态用 drift_intensity (0~1) 平滑插值, 所有表现随之渐变
# ============================================================

# ============================================================
#  默认值: AI 配平版 (用户主动要求采用)
#  数学推导: engine_force_max=14, friction_long=0.08, air_drag=0.0015
#  目标顶速 ~42 m/s (max_speed=45 难以达到, 体现"越接近顶速越乏力")
# ============================================================

# ---------------- 基础移动 ----------------
@export_group("Movement")
@export var max_speed: float = 45.0              ## 巡航极速(无喷射时能达到的最高速度, m/s)
@export var top_speed_boosted: float = 70.0      ## 喷射极速(小喷/双喷/氮气期间的最高速度, m/s)
@export var steering_deg: float = 28.0           ## 前轮视觉转角
@export var turn_speed: float = 3.2              ## 普通转向响应速度
@export var turn_speed_high_speed_mult: float = 0.45  ## 高速时转向衰减到的倍率(防甩)
@export var high_speed_threshold: float = 25.0   ## 多少 m/s 以上开始衰减转向
@export var turn_stop_limit: float = 0.6

# ---------------- 动力 ----------------
@export_group("Engine Power")
@export var engine_force_max: float = 14.0              ## 引擎峰值推力
@export var engine_force_curve: Curve                    ## 速度比 → 推力倍率
@export var brake_force_max: float = 40.0               ## 刹车峰值力
@export var brake_force_curve: Curve                     ## 速度比 → 刹车倍率
@export var engine_idle_drag: float = 1.2               ## 松油门时沿前进方向反向施加的引擎拖曳

# ---------------- 后退 ----------------
## 车头方向速度低于此阈值时, 按"后退"处理. 高于则按"刹车"处理. 推荐 1.5
@export var reverse_threshold: float = 1.5
## 倒车推力倍率(相对前进推力). 0.5 = 倒车力是前进力的一半
@export var reverse_force_mult: float = 0.5
## 倒车最高速度(m/s). 倒车 long_speed 不能低于 -此值
@export var reverse_max_speed: float = 12.0

# ---------------- 摩擦(正常状态) ----------------
@export_group("Friction Normal")
@export var friction_long_normal: float = 0.08           ## 正常前后滚动摩擦系数(等效力=k·v)
@export var friction_lat_normal: float = 14.0            ## 正常侧向抓地摩擦
@export var friction_air_drag: float = 0.0015            ## 空气阻力系数(与 v² 成正比, 主导顶速)
@export var friction_long_speed_curve_normal: Curve      ## 速度比 → 前后摩擦倍率
@export var friction_lat_speed_curve_normal: Curve       ## 速度比 → 侧向抓地倍率

# ---------------- 摩擦(漂移状态) ----------------
@export_group("Friction Drift")
@export var friction_long_drift: float = 0.04            ## 漂移前后摩擦基础
@export var friction_lat_drift: float = 2.5              ## 漂移侧向抓地基础(远小于正常值)
@export var friction_long_speed_curve_drift: Curve
@export var friction_lat_speed_curve_drift: Curve
@export var drift_extra_decel: float = 2.5               ## 漂移额外整体减速(沿惯性反向)

# ---------------- 漂移触发与状态 ----------------
@export_group("Drift")
@export var drift_min_speed: float = 10.0
@export var drift_body_tilt: float = 22.0
@export var drift_yaw_offset_tuck: float = 18.0
@export var drift_yaw_offset_side: float = 35.0
@export var side_drift_threshold: float = 1.2
## Q 输入宽限期(秒): 按下 Q 后这么久内只要方向键就位就立即入漂(QQ飞车手感)
@export var drift_input_grace_window: float = 0.18
@export var drift_min_angle_to_boost: float = 10.0       ## 小喷资格累积角(度)
@export var drift_max_duration: float = 5.0              ## 漂移最长持续(秒), 0 = 不限时
@export var drift_break_speed_ratio: float = 0.5         ## 低速断漂速度倍率阈值
@export var drift_low_speed_grace_time: float = 0.6      ## 低速触发后的挽救窗口
@export var drift_grace_save_angle: float = 8.0          ## 挽救期内再转过此角度(度)即取消断漂
@export var drift_auto_exit_enabled: bool = true         ## 车头摆正 + 无侧滑时自动退漂
@export var drift_auto_exit_lat_speed: float = 1.5
@export var drift_auto_exit_angle_deg: float = 6.0
@export var drift_auto_exit_time: float = 0.15
## 入漂后多少秒内不启用自动退漂(防止刚入漂时车头还没甩出来就被误判摆正退漂)
@export var drift_auto_exit_protect_time: float = 0.3
@export var drift_max_speed: float = 30.0                ## 漂移速度软上限(0 = 不限)
@export var drift_speed_brake_strength: float = 18.0     ## 超过漂移上限时反向刹车力
@export var drift_speed_brake_curve: Curve               ## 刹车强度随漂移持续时间的倍率曲线(X=0→刚入漂, X=1→到达 drift_head_yaw_duration_ref 秒)
@export var drift_counter_steer_break_time: float = 0.25 ## 反打超过此时长断漂

# ---------------- 漂移动态(插值+曲线) ----------------
@export_group("Drift Dynamics")
@export var drift_engage_duration: float = 0.18          ## 入漂 intensity 0→1 过渡秒数
@export var drift_disengage_duration: float = 0.28       ## 退漂 1→0 过渡秒数
@export var drift_engage_curve: Curve                    ## 入漂曲线
@export var drift_disengage_curve: Curve                 ## 退漂曲线
@export var drift_head_yaw_curve: Curve                  ## 车头 yaw 随漂移时间的变化倍率
@export var drift_body_tilt_curve: Curve                 ## 车身侧倾随漂移时间的变化倍率
@export var drift_head_yaw_duration_ref: float = 2.0     ## 车头曲线采样 X=1 对应的漂移秒数
@export var drift_steer_mult: float = 1.6                ## 漂移时转向速度倍率
@export var drift_accel_mult: float = 0.55               ## 漂移时油门有效推力倍率
## 漂移中反打方向时的转向缩减倍率 (QQ飞车手感: 左漂右打/右漂左打会卡一下)
## 0.3 = 反打时转向只剩 30%; 1.0 = 不缩减
@export var drift_counter_steer_mult: float = 0.35
## 退漂后推力爆发期时长(秒). 入漂和退漂瞬间会触发同样的爆发
@export var drift_exit_boost_duration: float = 0.6
## 退漂爆发期推力倍率. 例如 1.5 = 此期间引擎推力 × 1.5, 产生"起步冲劲"
@export var drift_exit_boost_mult: float = 1.5

# ---------------- 退漂转向冷却 ----------------
## 退漂后转向冷却时长(秒): 退漂瞬间转向倍率会被衰减到 post_drift_steer_mult,
## 在此秒数内线性回到 1.0. 避免"漂移压制解除→车头突然超灵敏"的不适感. 0=禁用
@export var post_drift_steer_cooldown: float = 0.35
## 退漂转向冷却起始倍率(0~1): 0.5 = 退漂瞬间转向只剩 50%, 然后平滑回到 100%
@export_range(0.0, 1.0, 0.01) var post_drift_steer_mult: float = 0.5

## 漂移反打时车身侧倾衰减到的最低倍率: 1.0=反打不影响侧倾, 0.0=反打时车身完全回正
## 推荐 0.0~0.2: 反打 → 类似正打入漂的逆播放, 慢慢把车身从倾斜回正
@export_range(0.0, 1.0, 0.01) var drift_counter_lean_mult: float = 0.0
## 反打时车身倾斜回正的过渡平滑系数(越大回正/恢复越快)
@export var drift_counter_lean_smooth: float = 4.0

# ---------------- 集气公式参数 ----------------
@export_group("Charge Formula")
@export var charge_nitro_full: float = 100.0
@export var charge_per_lateral_m: float = 2.2
@export var charge_yaw_rate_weight: float = 1.8
@export var charge_min_per_sec: float = 12.0
@export var crash_charge_penalty: float = 0.2
@export var max_nitro_stock: int = 2
@export var instant_nitro_settle: bool = true
@export var wall_crash_speed_loss: float = 6.0
## 撞墙震屏(默认 0)
@export var wall_crash_shake: float = 0.0

# ---------------- 喷射 ----------------
@export_group("Boost")
@export var mini_boost_power: float = 24.0
@export var mini_boost_time: float = 0.55
@export var mini_boost_curve: Curve
@export var boost_window_time: float = 1.2
@export var double_boost_power: float = 42.0
@export var double_boost_time: float = 0.85
@export var double_boost_curve: Curve
@export var double_charge_hold_time: float = 0.4
@export var double_charge_window: float = 0.6
@export var nitro_power: float = 58.0
@export var nitro_time: float = 2.2
@export var nitro_boost_curve: Curve
## 松开前进键是否中断氮气 (QQ飞车手感: 放氮气必须踩油门)
@export var nitro_require_throttle: bool = true
## 各喷射震屏强度(默认 0 = 不震). 0~2 范围
@export var mini_boost_shake: float = 0.0
@export var double_boost_shake: float = 0.0
@export var nitro_boost_shake: float = 0.0

# ---------------- 叠喷(连喷) ----------------
@export_group("Stack Boost")
## 叠喷链接续判定窗口: 前一段 boost 结束后多少秒内开新 boost 算"接力"
@export var stack_link_window: float = 0.35
## 突破极速倍率: 每次成功突破极速时的额外加成(乘到 effective_top 上)
@export var stack_breakthrough_top_mult: float = 1.18
## 突破极速最大叠加次数(与策划设计一致, cww 最多 2 次)
@export var stack_max_breakthrough: int = 3
## 叠喷推力衰减: 第 N 段连喷的推力倍率 [第1段, 第2段, 第3段, ...]
## 例 cw: 第1段 nitro=1.0, 第2段 mini=0.85
##    cww: nitro=1.0, mini=0.85, double=0.7
@export var stack_power_decay: Array[float] = [1.0, 0.85, 0.72, 0.6]

# ---------------- 漂移氮气(过弯增强) ----------------
@export_group("Drift Nitro")
## 漂移中放氮气时, 漂移最高速度上限的提升倍率(默认 1.5 = 提升 50%)
@export var drift_nitro_max_speed_mult: float = 1.5
## 漂移中放氮气时, 转向速度倍率(让车头甩得更猛, 过弯更急)
@export var drift_nitro_steer_mult: float = 1.5
## 漂移中放氮气时, 侧向抓地额外倍率(>1 让车更稳不甩飞, <1 让车更滑)
@export var drift_nitro_lat_grip_mult: float = 1.3
## 漂移中放氮气时, 车身侧倾视觉额外倍率(更夸张的过弯姿态)
@export var drift_nitro_body_tilt_mult: float = 1.2

# ---------------- 视觉 ----------------
@export_group("Visual")
@export var body_tilt: float = 28.0
@export var body_tilt_max_deg: float = 12.0
@export var head_yaw_deg: float = 4.0
@export var sphere_offset: Vector3 = Vector3.DOWN

# ---------------- 地面物理(统一模块: 防弹 + 坡道) ----------------
# 机制说明:
#   · 平地(坡度 < plain_slope_threshold_deg): 强防弹 -> 每帧把 Y 向上速度归零 + 向下压力
#   · 坡面(坡度 >= 阈值): 温和贴附 -> 只加沿法线的贴附力, 不强制改 Y 速度
#   · 两套机制用坡度平滑切换, 不干扰爬坡/飞跃
@export_group("Ground Physics")
## 防弹跳总开关
@export var ground_stick_enabled: bool = true
## 平地/坡面切换阈值(度): 小于此值视为"平地", 执行强防弹
@export var plain_slope_threshold_deg: float = 8.0
## 平地上"向上速度"归零阈值: v.y > 0 且 < 此值 => 直接置 0 (防橡皮球效应)
@export var plain_vy_zero_threshold: float = 5.0
## 平地上持续向下压力(N/kg): 哪怕检测到贴地也向下施压, 消除微弹. 推荐 5~15
@export var plain_downforce: float = 8.0
## 下压力触发阈值(m/s): 只在 Y 速度 > 此值时施加下压力.
## 0.3 = 车轻微抬起就压 (推荐); 0 = 永远施压(会压死爬坡助力); 大值(2+) = 只压大弹跳
@export var plain_downforce_vy_gate: float = 0.3
## 平地下坠速度上限(绝对值): 限制平地上 Y 向下速度, 防止从高空砸地弹飞. 0=不限
@export var plain_vy_down_clamp: float = 0.0

## 坡面贴附力(N/kg): 上坡时沿坡面法线反向加力, 防过坎飞车. 8 推荐
@export var slope_stick_force: float = 8.0
## 坡面贴附时 Y 速度上限: 超过此值认为在真跳跃, 不贴附
@export var slope_stick_max_vy: float = 2.5
## 坡面贴附生效的坡度上限: 超过此角度(峭壁)不再贴附. 默认 60 度
@export var slope_stick_max_deg: float = 60.0

# ---------------- 斜面作为墙 ----------------
@export_group("Slope as Wall")
@export var slope_as_wall_enabled: bool = true
@export var slope_wall_angle_deg: float = 50.0
@export var slope_wall_bounce_absorb: float = 0.75
@export var slope_wall_push_back: float = 4.0
## 撞斜面墙震屏(默认 0)
@export var slope_wall_shake: float = 0.0

# ---------------- 弹墙推力(尾/侧撞墙加速) ----------------
@export_group("Wall Bounce Boost")
## 是否启用弹墙推力
@export var wall_bounce_boost_enabled: bool = true
## 撞击点法线沿车头方向投影 > 此值 → 视为尾撞. 0.3~0.6 范围合理
@export var wall_bounce_rear_threshold: float = 0.4
## 撞击点法线沿车右方向投影绝对值 > 此值 → 视为侧撞
@export var wall_bounce_side_threshold: float = 0.6
## 触发弹墙的最小撞墙速度(m/s). 太小则蹭一下也触发
@export var wall_bounce_min_into_speed: float = 3.0
## 弹墙推力大小(直接加到 linear_velocity 沿车头方向, m/s)
@export var wall_bounce_forward_speed: float = 6.0
## 漂移撞墙后的入漂冷却(秒): 撞墙立即断漂(本次不给小喷), 此秒数内按 Q 无法重新漂移
@export var wall_drift_lockout_time: float = 0.5

# ---------------- 坡道 (推力/重力补偿) ----------------
@export_group("Slope")
## 推力沿坡面切向投影: 上坡时推力方向会沿坡面向上, 不再"水平推"
@export var slope_align_thrust: bool = true
## 上坡重力补偿倍率: 0=无补偿(掉速明显), 1=完全抵消重力沿坡面分量, 建议 0.7~0.9
## 下坡时不补偿(让车自然加速)
@export var slope_gravity_compensation: float = 0.85
## 最大补偿角度(度): 超过此角度不再补偿(防止峭壁也能往上冲)
@export var slope_compensation_max_deg: float = 45.0

# ---------------- 上坡爬升助力(独立于重力补偿的额外推力) ----------------
## 这是为了照顾"用户的引擎曲线高速段推力衰减很猛"的设计:
## 上坡时由于推力曲线本来就弱 + 重力分量, 速度无法拉起来. 这个机制额外给一份推力
## 与 slope_gravity_compensation 是不同维度: 重力补偿只抵消下滑力, 这个是真的爬坡加力
@export_group("Uphill Assist")
## 是否启用上坡爬升助力
@export var uphill_assist_enabled: bool = true
## 助力基础强度(直接加到引擎推力上, 单位与 engine_force_max 同). 推荐 4~10
@export var uphill_assist_force: float = 8.0
## 助力随坡度的强度曲线: X=坡度归一化(0=平地, 1=对应 uphill_assist_max_deg 度)
## Y=力度倍率(乘到 uphill_assist_force 上)
@export var uphill_assist_slope_curve: Curve
## 助力曲线 X=1 对应的坡度(度). 超过此角度时直接取曲线 X=1 的值
@export var uphill_assist_max_deg: float = 35.0
## 触发助力的最小坡度(度): 小于此值不施加助力(避免平地有"莫名加速")
@export var uphill_assist_min_deg: float = 4.0
## 助力是否随当前速度衰减: 1=只在低速时给(高速不再助推, 不破坏顶速曲线), 0=不衰减
## 这个曲线 X=当前速度比(speed/max_speed), Y=助力倍率. 推荐设成"低速 1.0, 高速 0.3"
@export var uphill_assist_speed_curve: Curve
## 助力是否需要踩油门: true=只在 throttle>0 时给(QQ飞车默认), false=松油门也给(防溜车)
@export var uphill_assist_require_throttle: bool = true
## 喷射期间助力倍率: 喷射状态下助力额外乘这个值. 1.0=不变, 1.5=喷射上坡更猛
@export var uphill_assist_boost_mult: float = 1.5

# ---------------- 空喷 / 落地喷 ----------------
@export_group("Air & Landing Boost")
## 空喷开关: 空中按 W 缓存意图, 落地瞬间释放一段加速
@export var air_boost_enabled: bool = true
## 空喷需要的最小腾空时间(秒): 离地不足这么久就不算"飞跃", 按 W 只走原本的 W 逻辑
@export var air_boost_min_air_time: float = 0.18
## 空喷意图缓存窗口(秒): 在空中按下 W 后, 多长时间内落地都算空喷有效
@export var air_boost_intent_window: float = 1.5
## 空喷推进力
@export var air_boost_power: float = 38.0
## 空喷持续时间(秒)
@export var air_boost_time: float = 0.7
## 空喷力度曲线(X=0→刚释放, X=1→末尾)
@export var air_boost_curve: Curve
## 空喷落地速度损失补偿: 落地碰撞会有一定下压速度被吸收, 这里把损失乘回(1.0=完全补偿)
## 0=不补偿, 1=完全保留腾空前水平动能
@export var air_landing_speed_recover: float = 0.85
## 空喷落地震屏强度
@export var air_boost_shake: float = 0.0
## 空喷与正常 W 链路冲突时的优先级: true=空喷会覆盖小喷窗口逻辑, false=反之
@export var air_boost_overrides_window: bool = true

## 落地喷开关: 飞跃足够久 + 按 W 才触发(类似空喷但门槛更高). 不会自动触发
@export var landing_boost_enabled: bool = true
## 落地喷的最小腾空时间(秒): 必须飞这么久且按 W 才能奖励
@export var landing_boost_min_air_time: float = 0.8
## 落地喷推进力
@export var landing_boost_power: float = 22.0
## 落地喷持续时间(秒)
@export var landing_boost_time: float = 0.45
## 落地喷力度曲线
@export var landing_boost_curve: Curve
## 落地喷与空喷可以叠加: true=两者同时生效(力度叠加, 时长取较长); false=空喷优先, 落地喷被吞掉
@export var landing_boost_stacks_with_air: bool = false
## 落地喷震屏强度
@export var landing_boost_shake: float = 0.0

## 落地喷窗口(秒): 稳定落地后, 玩家可按 W 触发落地喷的时间窗口
@export var landing_boost_press_window: float = 0.5

## 落地稳定判定: 连续此秒数车身处于地面才视为"真正落地"再触发喷射. 避免蹭到一下就触发
@export var landing_stable_time: float = 0.08
## 落地后 Y 速度上限: 下落速度绝对值超过此值时不算"稳定落地"(还在砸地), 防止触发过早
@export var landing_stable_max_vy: float = 4.0

## 落地缓冲: 落地瞬间 Y 方向冲击吸收比例 (0=完全保留下落动能造成弹跳, 1=完全吸收平稳落地)
@export var landing_impact_absorb: float = 0.85

# ---------------- 节点 ----------------
@onready var car_mesh: Node3D = get_node_or_null("CarMesh")
@onready var body_mesh: Node3D = get_node_or_null("CarMesh/suv2")
@onready var ground_ray: RayCast3D = get_node_or_null("CarMesh/RayCast3D")
@onready var right_wheel: Node3D = get_node_or_null("CarMesh/suv2/wheel_frontRight")
@onready var left_wheel: Node3D = get_node_or_null("CarMesh/suv2/wheel_frontLeft")

@export var auto_spawn_hud: bool = true
@export var hud_scene: PackedScene = preload("res://HUD.tscn")
@export var fx_scene: PackedScene = preload("res://BoostFX.tscn")
@export var drift_fx_scene: PackedScene = preload("res://DriftFX.tscn")
@export var tuner_scene: PackedScene = preload("res://Tuner.tscn")
@export var auto_spawn_tuner: bool = true

# ---------------- 信号 ----------------
signal speed_changed(kmh: float)
signal charge_changed(value: float, max_value: float)
signal nitro_stock_changed(stock: int, max_stock: int)
signal drift_started(mode: String)
signal drift_ended(charge_gained_this_round: float, succeeded: bool)
signal boost_triggered(type: String)
signal wall_crashed(lost_amount: float)
signal camera_shake_requested(intensity: float, duration: float)
signal boost_window_opened(level: String, duration: float)   ## 退漂后小喷/双喷窗口开启
signal boost_window_closed                                    ## 窗口关闭(用满或超时)
signal drift_charge_level_changed(level: String)              ## 漂移中等级变化: "none"/"mini"/"double"
signal double_charge_progress(progress: float)                ## 小喷期间按住Q的蓄能进度 0~1
signal double_charge_ready                                    ## 双喷蓄满, 可按 W 释放
signal double_charge_lost                                     ## 双喷资格失效
## 连喷组合喷触发: combo_name = "CW"/"CWW"/"WCW"等, breakthrough = 当前突破次数
signal combo_triggered(combo_name: String, breakthrough_count: int)
## 氮气颜色变体改变: variant = "blue"/"purple"/"gold"
signal nitro_variant_changed(variant: String)
## 起飞 / 落地事件
signal airborne_started
signal airborne_ended(air_time: float)
## 空喷意图被缓存(空中按 W)
signal air_boost_armed
## 空喷成功释放(落地瞬间)
signal air_boost_triggered(air_time: float)
## 落地喷自动奖励触发
signal landing_boost_triggered(air_time: float)

# ---------------- 状态 ----------------
enum State { NORMAL, DRIFT }
var state: int = State.NORMAL
var is_boosting: bool = false
var boost_type: String = ""
var boost_time_left: float = 0.0
var boost_power: float = 0.0
var boost_base_power: float = 0.0     # 喷射基础力度(用于曲线缩放)
var boost_total_time: float = 0.0     # 喷射总时长(用于归一化进度)
var last_mini_end_time: float = -999.0

# 叠喷(连喷)状态
var _last_boost_type: String = ""             # 上一段 boost 类型("mini"/"double"/"nitro"/"")
var _last_boost_end_time: float = -999.0      # 上一段 boost 结束时刻(s); 当前正在喷时也实时更新, 接力检测用
var _stack_chain_index: int = 0               # 当前在叠喷链中是第几段(从 0 开始)
var _stack_breakthrough_count: int = 0        # 当前叠喷链已成功突破极速的次数
var _stack_current_breakthrough: bool = false # 当前 boost 段本身是否处于"突破"状态
var _stack_chain_seq: Array[String] = []      # 叠喷链中每段的字母序: ["c", "w", "w"] 等

# Q 输入宽限期: 按 Q 时方向键还没到位 → 给一段时间等方向键, 期间一旦满足就入漂
var _drift_input_grace_left: float = 0.0

# 退漂推力爆发期: 入漂/退漂瞬间触发, 给一段短时间的推力加成, 产生"起步冲劲"
# 用时间衰减而不是改曲线, 避免"越快越强"的曲线被改采样反而变弱
var _drift_exit_boost_left: float = 0.0    # 爆发期剩余秒数

# 输入
var throttle_input: float = 0.0
var steer_input: float = 0.0

# 漂移
var drift_mode: String = ""
var drift_dir: float = 0.0
var drift_yaw_offset: float = 0.0
var drift_accum_charge: float = 0.0
var drift_accum_angle_deg: float = 0.0      # 漂移累计车头转过的角度(度)
var drift_elapsed: float = 0.0              # 漂移已持续时间
var drift_counter_steer_time: float = 0.0
var prev_yaw: float = 0.0
var _prev_forward_xz: Vector2 = Vector2.ZERO   # 上一帧车头水平投影方向(用于稳定算 yaw delta)

# 低速断漂宽限期
var _low_speed_grace_left: float = 0.0   # 宽限剩余秒数, >0 表示正在判断中
var _grace_start_angle: float = 0.0       # 进入宽限期时的累计角度(用于判挽救)
var _auto_exit_t: float = 0.0             # 已满足"车头摆正"条件的累计时间(去抖用)

# V2 漂移强度(0~1 平滑过渡, 驱动摩擦/视觉所有漂移表现)
var drift_intensity: float = 0.0        # 0=纯直线, 1=完全漂移
var _drift_intensity_vel: float = 0.0   # 用于平滑过渡的内部速率

# 退漂窗口期: 窗口内按 W 才能放出本次漂移积累的小喷/双喷
var boost_window_left: float = 0.0                # 窗口剩余秒数, 0 表示无窗口
var boost_window_level: String = ""               # 窗口可释放等级 "mini" / "double"

# 漂移中实时等级 (用于 HUD 小喷灯)
var _drift_charge_level: String = "none"          # "none"/"mini"/"double"

# 双喷蓄能状态(小喷期间按住 Q 蓄能)
var _double_charge_t: float = 0.0     # 当前已按住 Q 的累计时间
var _double_armed: bool = false       # 双喷已蓄满, 可按 W 释放
var _double_armed_left: float = 0.0   # 蓄满后剩余有效秒数

# 氮气槽
var charge: float = 0.0
var nitro_stock: int = 0
var _pending_nitro: int = 0      # 漂移期间累计待结算的氮气格(等退漂时一次性发放)

# 特效
# 特效
var fx_node: Node3D = null              # 第一个 BoostFX (兼容旧引用, 用于 play_boost / set_nitro_variant 等单点调用)
var fx_nodes: Array[Node3D] = []        # 所有 BoostFX 实例 (按 tailpipe 数量挂多个)
var drift_fx_node: Node3D = null

# 撞墙检测
var _last_frame_speed: float = 0.0

# 空喷 / 落地喷状态
var _is_airborne: bool = false                  # 当前是否离地
var _air_time: float = 0.0                       # 当前/上次腾空累计秒数
var _air_boost_armed: bool = false               # 空中按 W 后, 已缓存空喷意图
var _air_boost_armed_left: float = 0.0           # 缓存剩余有效秒数
var _pre_airborne_horizontal_speed: float = 0.0  # 起飞瞬间记录的水平速度(用于落地补偿)

# 落地稳定判定
var _pending_landing: bool = false               # 已检测到接地, 正在等待稳定
var _landing_stable_t: float = 0.0               # 已连续接地秒数
var _pending_landing_air_time: float = 0.0       # 触发本次 pending 的腾空时间
var _last_air_time_for_trigger: float = 0.0      # 最近一次可用于触发的腾空时间(给 W 按键判定用)
var _landing_boost_arm_left: float = 0.0         # 稳定落地后落地喷的按键窗口剩余时间
var _wall_drift_protect_left: float = 0.0         # (已废弃, 保留避免其他地方的未来引用) 撞墙断漂已改为立即断+CD
var _drift_lockout_left: float = 0.0              # 撞墙断漂后的入漂冷却剩余秒数, >0 时按 Q 无法入漂
# 撞墙断漂后, 玩家必须先松开 Q 再重新按下才能再次入漂
# 防止"按住 Q 撞墙→CD 走完→Q 还按着→自动续漂"
var _require_release_q: bool = false
var _post_drift_steer_cooldown_left: float = 0.0  # 退漂转向冷却剩余秒数
# 反打时车身倾斜衰减系数, 平滑到 1.0(正打/不打) ~ drift_counter_lean_mult(完全反打)
var _counter_lean_factor: float = 1.0

# 初始朝向(由 _ready 记录, 用于复位时恢复)
var _initial_car_mesh_basis: Basis = Basis.IDENTITY
var _initial_car_mesh_position: Vector3 = Vector3.ZERO
var _initial_recorded: bool = false

# ============================================================
#  Lifecycle
# ============================================================
func _ready() -> void:
	# 初始化 V2 默认曲线(玩家没设时给合理值)
	_init_default_curves()
	# 如果关键节点缺失, 至少把 Tuner 和 HUD 起来, 方便诊断/调整
	if not car_mesh or not body_mesh:
		push_error("[Car] 关键节点缺失! 车辆控制禁用, 但会启动 Tuner/HUD 以便诊断。")
		if car_mesh:
			print("[Car] CarMesh 子节点: ", car_mesh.get_children())
		if auto_spawn_hud and hud_scene:
			call_deferred("_spawn_hud")
		if auto_spawn_tuner and tuner_scene:
			call_deferred("_spawn_tuner")
		return

	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)

	# 记录 CarMesh 的初始位置和朝向(由 glb/tscn 设置, 代表美术摆好的出生点)
	_initial_car_mesh_basis = car_mesh.global_transform.basis
	_initial_car_mesh_position = car_mesh.global_position
	_initial_recorded = true

	# 出生时: 直接把刚体对齐到 CarMesh 的位置(你在编辑器里调好的位置)
	call_deferred("_snap_to_car_mesh_origin")

	if auto_spawn_hud and hud_scene:
		call_deferred("_spawn_hud")
	if auto_spawn_tuner and tuner_scene:
		call_deferred("_spawn_tuner")
	if fx_scene:
		# 不在这里 instantiate, 让 _attach_fx 根据 tailpipe 数量决定挂几个
		call_deferred("_attach_fx")
	if drift_fx_scene:
		drift_fx_node = drift_fx_scene.instantiate()
		call_deferred("_attach_drift_fx")


func _snap_to_car_mesh_origin() -> void:
	# 刚体位置 = CarMesh 位置 - sphere_offset (因为之后 _physics_process 里会做 car_mesh.pos = pos + sphere_offset)
	if not _initial_recorded:
		return
	global_position = _initial_car_mesh_position - sphere_offset
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# CarMesh 的位置和朝向保持原样, 不需要动
	if body_mesh:
		body_mesh.rotation = Vector3.ZERO
	print("[Car] 出生点对齐到 CarMesh 位置: ", _initial_car_mesh_position)


func _auto_place_on_ground() -> void:
	# 如果 CarMesh 有独立位置(top_level=true, 由 glb 场景带的初始位置), 优先从 CarMesh 正上方射线
	# 这样能对齐到美术放置的赛道起点, 而不是 tscn 里随手写的 transform
	var origin_xz: Vector3 = global_position
	if car_mesh and car_mesh.top_level:
		origin_xz = car_mesh.global_position
		origin_xz.y = global_position.y  # Y 用刚体的, 等下用射线校正

	var from: Vector3 = Vector3(origin_xz.x, origin_xz.y + 500.0, origin_xz.z)
	var to:   Vector3 = Vector3(origin_xz.x, origin_xz.y - 1000.0, origin_xz.z)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		push_warning("Car: 出生点正下方找不到地面，保持原位")
		return

	var target_pos: Vector3 = hit.position + Vector3(0, 2.0, 0)
	global_position = target_pos
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO

	# CarMesh 是 top_level=true 的独立坐标节点，必须手动同步
	if car_mesh:
		car_mesh.global_position = target_pos + sphere_offset
		# 恢复初始朝向(glb/tscn 设置的赛道起点方向)
		if _initial_recorded:
			car_mesh.global_transform.basis = _initial_car_mesh_basis
		else:
			car_mesh.global_rotation = Vector3.ZERO
	if body_mesh:
		body_mesh.rotation = Vector3.ZERO

	print("[Car] 出生点已校正到: ", target_pos)


func _attach_fx() -> void:
	if not fx_scene or not car_mesh:
		return
	# 收集所有以 "tailpipe" 开头命名的节点 (深度遍历, 因为 tailpipe 可能挂在 suv2 下)
	var tailpipes: Array[Node3D] = []
	_collect_tailpipes_recursive(car_mesh, tailpipes)
	if tailpipes.is_empty():
		# 兼容老 SUV: 只挂一个在车后位置
		var single: Node3D = fx_scene.instantiate()
		car_mesh.add_child(single)
		single.position = Vector3(0, 0.2, 0.8)
		fx_nodes.append(single)
		fx_node = single
		print("[Car] BoostFX 挂载: 1 个 (老 SUV 模式)")
		return
	# 玉麒麟模式: 每个 tailpipe 挂一个 BoostFX
	for tp in tailpipes:
		var fx: Node3D = fx_scene.instantiate()
		tp.add_child(fx)
		# 不再额外偏移, tailpipe 节点位置即喷口
		fx.position = Vector3.ZERO
		fx_nodes.append(fx)
	fx_node = fx_nodes[0]
	print("[Car] BoostFX 挂载: ", fx_nodes.size(), " 个 (tailpipe 模式)")


func _collect_tailpipes_recursive(node: Node, out: Array) -> void:
	for c in node.get_children():
		if c is Node3D and c.name.begins_with("tailpipe"):
			out.append(c)
		# 继续深入(允许嵌套, 但不进入已经是 tailpipe 的节点的子树)
		else:
			_collect_tailpipes_recursive(c, out)


func _attach_drift_fx() -> void:
	if not drift_fx_node:
		print("[Car] drift_fx_node 是 null, 跳过挂接")
		return
	# 挂在 car 节点下作为子节点 (DriftFX 内部会自己找轮子)
	add_child(drift_fx_node)
	if drift_fx_node.has_method("set_car"):
		drift_fx_node.set_car(self)
	print("[Car] DriftFX 已挂载")


func _spawn_hud() -> void:
	if get_tree().current_scene.find_child("HUD", true, false):
		return
	var hud: CanvasLayer = hud_scene.instantiate()
	hud.name = "HUD"
	get_tree().current_scene.add_child(hud)
	hud.car_path = hud.get_path_to(self)
	hud.call_deferred("_connect_to_car")


func _spawn_tuner() -> void:
	if get_tree().current_scene.find_child("Tuner", true, false):
		return
	var tuner: CanvasLayer = tuner_scene.instantiate()
	tuner.name = "Tuner"
	get_tree().current_scene.add_child(tuner)
	tuner.set("car_path", tuner.get_path_to(self))
	tuner.call_deferred("_bind_car")


# ============================================================
#  主循环
# ============================================================
func _physics_process(delta: float) -> void:
	if not car_mesh or not body_mesh:
		return
	_read_input()
	_update_boost_timer(delta)
	_update_stack_chain_timeout()    # 叠喷链超时清理
	_update_drift_intensity(delta)    # V2: 平滑的 0~1 漂移强度
	# 退漂推力爆发期倒计时
	if _drift_exit_boost_left > 0.0:
		_drift_exit_boost_left -= delta
		if _drift_exit_boost_left < 0.0:
			_drift_exit_boost_left = 0.0
	# 退漂转向冷却倒计时
	if _post_drift_steer_cooldown_left > 0.0:
		_post_drift_steer_cooldown_left -= delta
		if _post_drift_steer_cooldown_left < 0.0:
			_post_drift_steer_cooldown_left = 0.0
	# 撞墙断漂入漂冷却倒计时
	if _drift_lockout_left > 0.0:
		_drift_lockout_left -= delta
		if _drift_lockout_left < 0.0:
			_drift_lockout_left = 0.0

	car_mesh.position = position + sphere_offset

	# 地面判定: 优先 ground_ray, 但如果 ray 因抬升/接缝偶尔脱离, 再做一次"短程宽探测"
	# 避免一帧物理全跳过造成的顿挫
	var on_ground: bool = ground_ray != null and ground_ray.is_colliding()
	if not on_ground:
		on_ground = _fallback_ground_check()
	# 起飞/落地检测 + 空喷/落地喷处理
	_update_air_state(delta, on_ground)
	if on_ground:
		_apply_engine_and_brake(delta)
		_apply_friction(delta)
		_apply_ground_stick(delta)

	_update_drift_charge(delta)
	_check_drift_timeout(delta)
	_update_boost_window(delta)
	_update_double_charge(delta)
	_update_visuals(delta)
	_emit_hud_signals()
	_last_frame_speed = linear_velocity.length()


# ============================================================
#  输入
# ============================================================
func _read_input() -> void:
	throttle_input = Input.get_axis("brake", "accelerate")
	steer_input = Input.get_axis("steer_right", "steer_left")

	# 撞墙断漂后: 需要玩家先松开 Q 才能解除"禁止再次入漂"flag
	if _require_release_q and not Input.is_action_pressed("drift"):
		_require_release_q = false
		print("[Car] Q 已松开, 解除撞墙后禁漂锁")

	# Q 点按: 漂移意图优先(喷气和漂移可共存)
	#   · NORMAL → 启动入漂宽限期(0.18s 内方向键凑齐就入漂, QQ飞车手感)
	#   · DRIFT → 手动退漂(不喷)
	if Input.is_action_just_pressed("drift") and not _require_release_q:
		if state == State.NORMAL:
			# 立即尝试一次, 不行就启动宽限期
			if not _try_start_drift():
				_drift_input_grace_left = drift_input_grace_window
		else:
			_end_drift(false, true)   # 手动按 Q 退漂(不喷, manual=true 不允许按住续漂)
	# 宽限期内: 每帧重试入漂(直到成功或宽限期结束)
	if _drift_input_grace_left > 0.0 and state == State.NORMAL and not _require_release_q:
		# 玩家松开 Q 取消宽限期(避免持续按住 Q 时一直尝试)
		if not Input.is_action_pressed("drift"):
			_drift_input_grace_left = 0.0
		else:
			if _try_start_drift():
				_drift_input_grace_left = 0.0
			else:
				_drift_input_grace_left -= get_physics_process_delta_time()
				if _drift_input_grace_left < 0.0:
					_drift_input_grace_left = 0.0

	# W 小喷：NORMAL 时如果刚好蓄满可直接小喷 / DRIFT 时角度够了退漂+小喷
	if Input.is_action_just_pressed("boost"):
		_try_boost_w()

	# E 氮气
	if Input.is_action_just_pressed("nitro"):
		_try_nitro()


func _unhandled_input(event: InputEvent) -> void:
	# R 键复位到初始出生点（回到你在编辑器里调好的 CarMesh 位置）
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R or event.physical_keycode == KEY_R:
			_reset_to_origin()
			get_viewport().set_input_as_handled()


func _reset_to_origin() -> void:
	if not _initial_recorded:
		_auto_place_on_ground()
		return
	global_position = _initial_car_mesh_position - sphere_offset
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	if car_mesh:
		car_mesh.global_position = _initial_car_mesh_position
		car_mesh.global_transform.basis = _initial_car_mesh_basis
	if body_mesh:
		body_mesh.rotation = Vector3.ZERO
	# 退出漂移/喷射状态
	state = State.NORMAL
	is_boosting = false
	boost_time_left = 0.0
	print("[Car] 已复位到出生点")


# ============================================================
#  物理模型核心三件套 —— 炸弹猫精调版
#  1) _update_drift_intensity: 漂移强度 0~1 平滑过渡
#  2) _apply_engine_and_brake: 带曲线的引擎/刹车动力系统
#  3) _apply_friction: 速度分解 + 曲线化的摩擦层(沿惯性反向)
# ============================================================

func _update_drift_intensity(delta: float) -> void:
	# 目标强度: DRIFT 状态 → 1.0; 否则 → 0.0
	var target: float = 1.0 if state == State.DRIFT else 0.0
	if absf(drift_intensity - target) < 0.001:
		drift_intensity = target
		return
	var dur: float
	var curve: Curve
	if target > drift_intensity:
		dur = maxf(drift_engage_duration, 0.001)
		curve = drift_engage_curve
	else:
		dur = maxf(drift_disengage_duration, 0.001)
		curve = drift_disengage_curve
	# 线性推进内部时间, 用曲线把进度映射成最终 intensity
	var step: float = delta / dur
	if target > drift_intensity:
		# 入漂: 进度从 drift_intensity 推到 1
		# 用当前 intensity 作为曲线采样输入的基础, 曲线能改变响应形状
		var t: float = drift_intensity + step
		t = clampf(t, 0.0, 1.0)
		drift_intensity = _sample_curve_safe(curve, t, t)
	else:
		# 退漂: 进度从 drift_intensity 推到 0
		var t2: float = drift_intensity - step
		t2 = clampf(t2, 0.0, 1.0)
		drift_intensity = _sample_curve_safe(curve, t2, t2)


func _sample_curve_safe(c: Curve, t: float, fallback: float) -> float:
	if c == null or c.point_count <= 1:
		return fallback
	return c.sample(clampf(t, 0.0, 1.0))


func _init_default_curves() -> void:
	# 引擎推力曲线: 配合 engine_force_max=14, friction_long=0.08, air_drag=0.0015 配平
	# 推演(NORMAL 状态, top=45):
	#   v=0:  F=14×1.0=14 N, a≈14 m/s² (强起步)
	#   v=15: F=14×0.7=9.8, 摩擦≈1.54, 净=8.3 (前段仍快)
	#   v=30: F=14×0.45=6.3, 摩擦≈3.75, 净=2.55 (明显放缓)
	#   v=40: F≈4.48, 摩擦≈5.6, 净≈0 (稳定在 ~42)
	# 0→40 约 4-5 秒, 0→20 约 1.5 秒 = 真实跑车手感
	if engine_force_curve == null:
		var c := Curve.new()
		c.add_point(Vector2(0.0, 1.00))
		c.add_point(Vector2(0.2, 0.85))
		c.add_point(Vector2(0.4, 0.65))
		c.add_point(Vector2(0.6, 0.45))
		c.add_point(Vector2(0.8, 0.32))
		c.add_point(Vector2(1.0, 0.22))
		engine_force_curve = c
	# 刹车: 高速更强(动能大需要大刹车), 低速弱(防瞬停)
	if brake_force_curve == null:
		var c2 := Curve.new()
		c2.add_point(Vector2(0.0, 0.6))
		c2.add_point(Vector2(0.4, 1.0))
		c2.add_point(Vector2(1.0, 1.2))
		brake_force_curve = c2
	# 正常前后摩擦: 恒定 1.0
	if friction_long_speed_curve_normal == null:
		var c3 := Curve.new()
		c3.add_point(Vector2(0.0, 1.0)); c3.add_point(Vector2(1.0, 1.0))
		friction_long_speed_curve_normal = c3
	# 正常侧向抓地: 低速满格, 高速轻微衰减(让高速转向自然难一点)
	if friction_lat_speed_curve_normal == null:
		var c4 := Curve.new()
		c4.add_point(Vector2(0.0, 1.1))
		c4.add_point(Vector2(0.6, 1.0))
		c4.add_point(Vector2(1.0, 0.75))
		friction_lat_speed_curve_normal = c4
	# 漂移前后摩擦: 恒定 1.0
	if friction_long_speed_curve_drift == null:
		var c5 := Curve.new()
		c5.add_point(Vector2(0.0, 1.0)); c5.add_point(Vector2(1.0, 1.0))
		friction_long_speed_curve_drift = c5
	# 漂移侧向抓地: 低速很低(甩得开), 中速稍涨(可控), 高速微弱(长甩)
	if friction_lat_speed_curve_drift == null:
		var c6 := Curve.new()
		c6.add_point(Vector2(0.0, 0.8))
		c6.add_point(Vector2(0.5, 1.2))
		c6.add_point(Vector2(1.0, 1.0))
		friction_lat_speed_curve_drift = c6
	# 入漂: ease-out(起始快, 末端缓)
	if drift_engage_curve == null:
		var c7 := Curve.new()
		c7.add_point(Vector2(0.0, 0.0))
		c7.add_point(Vector2(0.3, 0.7))
		c7.add_point(Vector2(1.0, 1.0))
		drift_engage_curve = c7
	# 退漂: ease-in(开始稳, 末端快)
	if drift_disengage_curve == null:
		var c8 := Curve.new()
		c8.add_point(Vector2(0.0, 0.0))
		c8.add_point(Vector2(0.7, 0.3))
		c8.add_point(Vector2(1.0, 1.0))
		drift_disengage_curve = c8
	# 车头 yaw 时间曲线: 入漂车头快速偏到位, 中段微幅晃动, 末段稳住
	if drift_head_yaw_curve == null:
		var c9 := Curve.new()
		c9.add_point(Vector2(0.0, 0.9))
		c9.add_point(Vector2(0.3, 1.1))
		c9.add_point(Vector2(0.6, 0.95))
		c9.add_point(Vector2(1.0, 1.0))
		drift_head_yaw_curve = c9
	# 车身侧倾时间曲线: 入漂略微过冲, 后稳定
	if drift_body_tilt_curve == null:
		var c10 := Curve.new()
		c10.add_point(Vector2(0.0, 0.7))
		c10.add_point(Vector2(0.25, 1.15))
		c10.add_point(Vector2(1.0, 1.0))
		drift_body_tilt_curve = c10
	# 漂移超速刹车强度随时间变化曲线:
	#   前期(0~0.3): 0.15~0.4 → 刚入漂几乎不掉速, 保持冲劲
	#   中期(0.3~0.7): 0.4~1.0 → 逐渐开始拖
	#   后期(0.7~1.0): 1.0~1.4 → 长时间漂越拖越凶, 迫使玩家早点退漂
	if drift_speed_brake_curve == null:
		var c11 := Curve.new()
		c11.add_point(Vector2(0.0, 0.15))
		c11.add_point(Vector2(0.3, 0.4))
		c11.add_point(Vector2(0.7, 1.0))
		c11.add_point(Vector2(1.0, 1.4))
		drift_speed_brake_curve = c11
	# 空喷曲线: 起步爆发 + 中段保持 + 末尾衰减
	if air_boost_curve == null:
		var c12 := Curve.new()
		c12.add_point(Vector2(0.0, 1.5))
		c12.add_point(Vector2(0.3, 1.1))
		c12.add_point(Vector2(0.8, 0.85))
		c12.add_point(Vector2(1.0, 0.5))
		air_boost_curve = c12
	# 落地喷曲线: 比空喷更短的爆发(只是个'飞跃完成奖励')
	if landing_boost_curve == null:
		var c13 := Curve.new()
		c13.add_point(Vector2(0.0, 1.3))
		c13.add_point(Vector2(0.4, 1.0))
		c13.add_point(Vector2(1.0, 0.6))
		landing_boost_curve = c13
	# 上坡爬升助力 - 坡度曲线: 平地 0, 中坡爆发, 大坡略减(避免峭壁还往上冲)
	if uphill_assist_slope_curve == null:
		var c14 := Curve.new()
		c14.add_point(Vector2(0.0, 0.0))   # 0% 坡度: 不助推
		c14.add_point(Vector2(0.2, 0.6))   # 20%: 开始
		c14.add_point(Vector2(0.5, 1.2))   # 50%: 峰值(中坡最舒服)
		c14.add_point(Vector2(0.8, 1.0))
		c14.add_point(Vector2(1.0, 0.7))   # 接近最大: 略减
		uphill_assist_slope_curve = c14
	# 上坡爬升助力 - 速度曲线: 低速时全力助推, 高速时减少(不破坏顶速曲线)
	if uphill_assist_speed_curve == null:
		var c15 := Curve.new()
		c15.add_point(Vector2(0.0, 1.0))
		c15.add_point(Vector2(0.5, 0.85))
		c15.add_point(Vector2(0.8, 0.5))
		c15.add_point(Vector2(1.0, 0.3))   # 接近顶速: 弱助推
		uphill_assist_speed_curve = c15


# ============================================================
#  V2 - 引擎动力 + 刹车(带曲线)
# ============================================================
func _apply_engine_and_brake(_delta: float) -> void:
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	# 坡面切向: forward 投影到"地面切平面"上(消除垂直分量), 保证推力沿坡面走
	# 若 ground_ray 拿到了地面法线, 用它; 否则退化为世界水平(保持老行为)
	var ground_n: Vector3 = Vector3.UP
	if ground_ray and ground_ray.is_colliding():
		ground_n = ground_ray.get_collision_normal().normalized()
	var thrust_dir: Vector3 = forward
	if slope_align_thrust:
		# 把 forward 投影到垂直于 ground_n 的平面上
		thrust_dir = (forward - ground_n * forward.dot(ground_n))
		if thrust_dir.length() > 0.001:
			thrust_dir = thrust_dir.normalized()
		else:
			thrust_dir = forward

	var v_horiz: Vector3 = linear_velocity
	v_horiz.y = 0.0
	var current_speed: float = v_horiz.length()
	var long_speed: float = v_horiz.dot(forward)

	# 当前生效的极速: 喷射时用 boosted, 否则用 max_speed
	var effective_top: float = top_speed_boosted if is_boosting else max_speed
	# 叠喷突破: 当前段处于突破状态时, 极速被临时拔高
	if is_boosting and _stack_current_breakthrough and _stack_breakthrough_count > 0:
		effective_top *= pow(stack_breakthrough_top_mult, _stack_breakthrough_count)
	# 漂移上限叠加(取较小者). 漂移氮气时上限提升, 让过弯更快
	if state == State.DRIFT and drift_max_speed > 0.0:
		var drift_top: float = drift_max_speed
		if _is_drift_nitro():
			drift_top *= drift_nitro_max_speed_mult
		effective_top = minf(effective_top, drift_top)
	effective_top = maxf(effective_top, 1.0)
	# speed_ratio: 当前速度占当前极速的比例(0~1+)
	var speed_ratio: float = clampf(current_speed / effective_top, 0.0, 1.2)

	# 上坡重力补偿: 当 forward 指向坡上时(forward.y > 0), 额外施加一个力抵消重力沿坡面分量
	# 数学: 重力 = g*mass, 沿坡面反方向的分量 = g*mass*sin(slope_angle)
	#       slope_angle = acos(ground_n.y)
	#       简化: sin(slope) ≈ sqrt(1 - ground_n.y²), 然后乘 forward.y 的符号
	var slope_angle_cos: float = clampf(ground_n.y, -1.0, 1.0)
	var slope_angle_deg: float = rad_to_deg(acos(slope_angle_cos))
	var going_uphill: bool = thrust_dir.y > 0.02
	if slope_gravity_compensation > 0.0 and going_uphill and slope_angle_deg <= slope_compensation_max_deg and throttle_input > 0.01:
		var g_strength: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) * gravity_scale
		var sin_slope: float = sqrt(maxf(1.0 - slope_angle_cos * slope_angle_cos, 0.0))
		# 补偿力: 沿 thrust_dir 方向, 大小 = g·sin(slope)·compensation·throttle·mass
		var comp_force: Vector3 = thrust_dir * g_strength * sin_slope * slope_gravity_compensation * throttle_input * mass
		apply_central_force(comp_force)

	# 上坡爬升助力(独立机制, 用于克服推力曲线高速段衰减带来的爬坡乏力)
	if uphill_assist_enabled and going_uphill and slope_angle_deg >= uphill_assist_min_deg:
		var allow_assist: bool = (not uphill_assist_require_throttle) or (throttle_input > 0.01)
		if allow_assist:
			# 坡度归一化: 0~1 对应 min_deg~max_deg (超过 max 锁 1.0)
			var slope_range: float = maxf(uphill_assist_max_deg - uphill_assist_min_deg, 0.001)
			var slope_t: float = clampf((slope_angle_deg - uphill_assist_min_deg) / slope_range, 0.0, 1.0)
			var slope_k: float = _sample_curve_safe(uphill_assist_slope_curve, slope_t, 1.0)
			# 速度衰减: 高速时助推减少, 不破坏用户调好的顶速曲线
			var speed_k: float = _sample_curve_safe(uphill_assist_speed_curve, speed_ratio, 1.0)
			# 喷射期间倍率
			var boost_k: float = uphill_assist_boost_mult if is_boosting else 1.0
			# 油门强度: 踩多深给多少(松油门时如果 require_throttle=false 用 1.0)
			var throttle_k: float = throttle_input if uphill_assist_require_throttle else 1.0
			throttle_k = maxf(throttle_k, 0.0)
			var assist_mag: float = uphill_assist_force * slope_k * speed_k * boost_k * throttle_k
			if assist_mag > 0.001:
				apply_central_force(thrust_dir * assist_mag * mass)

	# 油门
	if throttle_input > 0.01:
		var engine_k: float = _sample_curve_safe(engine_force_curve, speed_ratio, 1.0)
		# 漂移强度越大, 油门效率越低(插值)
		var eff_mult: float = lerpf(1.0, drift_accel_mult, drift_intensity)
		# 退漂推力爆发: 爆发期内推力临时加成(线性衰减, 越接近末尾加成越少)
		var exit_boost_k: float = 1.0
		if _drift_exit_boost_left > 0.0 and drift_exit_boost_duration > 0.0:
			var t_ratio: float = clampf(_drift_exit_boost_left / drift_exit_boost_duration, 0.0, 1.0)
			# 倍率从 drift_exit_boost_mult 线性衰减到 1.0
			exit_boost_k = lerpf(1.0, drift_exit_boost_mult, t_ratio)
		# 软封顶: 仅当尚未达到极速时施加推力(超过则交给摩擦自然减速)
		if long_speed < effective_top:
			apply_central_force(thrust_dir * engine_force_max * engine_k * throttle_input * eff_mult * exit_boost_k * mass)
	elif throttle_input < -0.01:
		# 后退/刹车混合逻辑:
		#   · 车正在向前(long_speed > reverse_threshold): 先做"刹车"(沿运动反向施力)
		#   · 车基本停下或已在后退: 切换为"倒车"(沿车头反方向引擎推力)
		# reverse_threshold 给一点滞回, 防止抖动
		if long_speed > reverse_threshold:
			# === 刹车段 ===
			var brake_k: float = _sample_curve_safe(brake_force_curve, speed_ratio, 1.0)
			if current_speed > 0.3:
				var brake_dir: Vector3 = -v_horiz.normalized()
				apply_central_force(brake_dir * brake_force_max * brake_k * absf(throttle_input) * mass)
		else:
			# === 倒车段 ===
			# 倒车有自己的极速上限, 防止倒车冲上天
			if long_speed > -reverse_max_speed:
				var rev_k: float = _sample_curve_safe(engine_force_curve, speed_ratio, 1.0)
				var rev_eff_mult: float = lerpf(1.0, drift_accel_mult, drift_intensity)
				apply_central_force(-thrust_dir * engine_force_max * reverse_force_mult * rev_k * absf(throttle_input) * rev_eff_mult * mass)
	else:
		# 松油门: 引擎拖曳(沿前进方向反向)
		if absf(long_speed) > 0.1:
			apply_central_force(-forward * signf(long_speed) * engine_idle_drag * mass)

	# 漂移超速软封顶(独立机制, 处理纯漂移压速度). 漂移氮气时上限同步提升
	if state == State.DRIFT and drift_max_speed > 0.0:
		var dms: float = drift_max_speed
		if _is_drift_nitro():
			dms *= drift_nitro_max_speed_mult
		if current_speed > dms:
			var over_ratio: float = (current_speed - dms) / dms
			over_ratio = minf(over_ratio, 1.5)
			# 刹车强度随漂移时间变化: 归一化到 drift_head_yaw_duration_ref(同其他漂移曲线)
			var brake_t_norm: float = clampf(drift_elapsed / maxf(drift_head_yaw_duration_ref, 0.1), 0.0, 1.0)
			var brake_time_k: float = _sample_curve_safe(drift_speed_brake_curve, brake_t_norm, 1.0)
			apply_central_force(-v_horiz.normalized() * drift_speed_brake_strength * over_ratio * brake_time_k * mass)

	# 喷射推力沿惯性方向(但同样受 effective_top 限制)
	if is_boosting and current_speed < effective_top:
		var vel_dir: Vector3 = v_horiz
		if vel_dir.length() > 1.0:
			vel_dir = vel_dir.normalized()
		else:
			vel_dir = forward
		# 喷射推力也投影到坡面切向(防止上坡时喷射向斜上, 导致飞车/脱地)
		if slope_align_thrust:
			var vel_on_slope: Vector3 = vel_dir - ground_n * vel_dir.dot(ground_n)
			if vel_on_slope.length() > 0.001:
				vel_dir = vel_on_slope.normalized()
		apply_central_force(vel_dir * boost_power * mass)


# ============================================================
#  V2 - 摩擦: 速度分解 + 曲线调制
#  所有摩擦沿"该速度分量反方向"施加, 即惯性反向 ✓
# ============================================================
func _apply_friction(delta: float) -> void:
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	var right: Vector3 = car_mesh.global_transform.basis.x
	var v: Vector3 = linear_velocity
	v.y = 0.0
	var total_speed: float = v.length()
	# 用当前生效的极速做参考(与引擎逻辑一致, 同样受叠喷突破影响)
	var ref_speed: float = top_speed_boosted if is_boosting else max_speed
	if is_boosting and _stack_current_breakthrough and _stack_breakthrough_count > 0:
		ref_speed *= pow(stack_breakthrough_top_mult, _stack_breakthrough_count)
	ref_speed = maxf(ref_speed, 1.0)
	var speed_ratio: float = clampf(total_speed / ref_speed, 0.0, 1.2)

	var v_long: float = v.dot(forward)
	var v_lat: float = v.dot(right)

	# NORMAL 与 DRIFT 两套参数按 drift_intensity 插值
	var long_k_normal: float = friction_long_normal * _sample_curve_safe(friction_long_speed_curve_normal, speed_ratio, 1.0)
	var long_k_drift: float  = friction_long_drift  * _sample_curve_safe(friction_long_speed_curve_drift,  speed_ratio, 1.0)
	var lat_k_normal: float  = friction_lat_normal  * _sample_curve_safe(friction_lat_speed_curve_normal,  speed_ratio, 1.0)
	var lat_k_drift: float   = friction_lat_drift   * _sample_curve_safe(friction_lat_speed_curve_drift,   speed_ratio, 1.0)

	var long_k: float = lerpf(long_k_normal, long_k_drift, drift_intensity)
	var lat_k: float  = lerpf(lat_k_normal,  lat_k_drift,  drift_intensity)
	# 漂移氮气过弯增强: 侧向抓地额外加成, 让车不甩飞同时能拉大角度
	if _is_drift_nitro():
		lat_k *= drift_nitro_lat_grip_mult

	# 沿各自速度分量反方向施加冲量
	var long_impulse: Vector3 = -forward * v_long * long_k * delta
	var lat_impulse: Vector3  = -right   * v_lat  * lat_k  * delta
	apply_central_impulse((long_impulse + lat_impulse) * mass)

	# 空气阻力(与速度平方成正比, 沿惯性反向)
	if total_speed > 0.5 and friction_air_drag > 0.0:
		var air_force: Vector3 = -v.normalized() * friction_air_drag * total_speed * total_speed * mass
		apply_central_force(air_force)

	# 漂移额外能耗(整体沿惯性反向, 强度与 drift_intensity 成正比)
	if drift_intensity > 0.01 and total_speed > 0.5:
		apply_central_force(-v.normalized() * drift_extra_decel * drift_intensity * mass)


# 短程宽松地面探测: 当 ground_ray 偶发脱离时用球体中心沿世界 -Y 再探一下
# 2.5 米的探测距离足以覆盖过坎、接缝抬升、坡面切向探测偏差等情况
func _fallback_ground_check() -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var from: Vector3 = global_position
	var to: Vector3 = global_position + Vector3(0, -2.5, 0)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [self.get_rid()]
	var hit := space.intersect_ray(q)
	return not hit.is_empty()


# ============================================================
#  空喷 / 落地喷
# ============================================================
func _update_air_state(delta: float, on_ground: bool) -> void:
	# 空喷意图缓存倒计时
	if _air_boost_armed:
		_air_boost_armed_left -= delta
		if _air_boost_armed_left <= 0.0:
			_air_boost_armed = false
			_air_boost_armed_left = 0.0
			print("[Car] 空喷意图超时失效")
	# 落地喷按键窗口倒计时
	if _landing_boost_arm_left > 0.0:
		_landing_boost_arm_left -= delta
		if _landing_boost_arm_left <= 0.0:
			_landing_boost_arm_left = 0.0
			print("[Car] 落地喷窗口关闭")

	if not on_ground:
		# 离地中: 累计空中时间; 若之前在等稳定落地, 取消等待
		if _pending_landing:
			_pending_landing = false
			_landing_stable_t = 0.0
		if not _is_airborne:
			_is_airborne = true
			_air_time = 0.0
			# 记录起飞瞬间的水平速度, 落地后用于补偿
			var hv: Vector3 = linear_velocity; hv.y = 0.0
			_pre_airborne_horizontal_speed = hv.length()
			emit_signal("airborne_started")
		_air_time += delta
	else:
		# 在地面
		if _is_airborne:
			# 刚触地: 进入"等待稳定"阶段, 不立即触发落地喷
			_pending_landing_air_time = _air_time
			_last_air_time_for_trigger = _air_time
			_is_airborne = false
			emit_signal("airborne_ended", _air_time)
			# 初步落地缓冲: 吸收下落动能, 恢复水平速度
			_apply_landing_physics()
			# 立即把空喷触发(空喷要的是"着地瞬间爆发", 不需要稳定)
			_maybe_trigger_air_boost(_pending_landing_air_time)
			# 落地喷进入稳定等待
			_pending_landing = true
			_landing_stable_t = 0.0
			_air_time = 0.0

		# 稳定性判定: 连续接地 + Y 速度不大 = 真正落地
		if _pending_landing:
			if absf(linear_velocity.y) < landing_stable_max_vy:
				_landing_stable_t += delta
				if _landing_stable_t >= landing_stable_time:
					# 稳定落地 -> 现在开放落地喷触发窗口(玩家需按 W 触发, 不自动)
					_pending_landing = false
					_landing_stable_t = 0.0
					# 不自动触发; 如果玩家已经 arm 了 air_boost 但空中时间足够落地喷, 现在触发落地喷
					_maybe_trigger_landing_boost_if_armed(_pending_landing_air_time)
			else:
				# Y 速度还大, 重置稳定计时(可能还在下坠 or 二次弹)
				_landing_stable_t = 0.0


func _apply_landing_physics() -> void:
	# 落地缓冲: 把 Y 方向下落速度按比例吸收, 减少弹跳
	if landing_impact_absorb > 0.0 and linear_velocity.y < 0.0:
		var v: Vector3 = linear_velocity
		v.y *= (1.0 - clampf(landing_impact_absorb, 0.0, 1.0))
		linear_velocity = v

	# 水平速度补偿: 飞行过程中空气阻力可能让 horizontal speed 缩水, 落地把它拉回起飞前
	if air_landing_speed_recover > 0.0 and _pre_airborne_horizontal_speed > 0.5:
		var hv: Vector3 = linear_velocity; hv.y = 0.0
		var cur_h: float = hv.length()
		if cur_h < _pre_airborne_horizontal_speed and cur_h > 0.5:
			var target_h: float = lerpf(cur_h, _pre_airborne_horizontal_speed, clampf(air_landing_speed_recover, 0.0, 1.0))
			var scale_k: float = target_h / cur_h
			var v2: Vector3 = linear_velocity
			v2.x *= scale_k
			v2.z *= scale_k
			linear_velocity = v2


func _maybe_trigger_air_boost(air_time: float) -> bool:
	# 空喷: 玩家在空中按过 W + 腾空够 -> 落地瞬间爆发
	if air_boost_enabled and _air_boost_armed and air_time >= air_boost_min_air_time:
		_air_boost_armed = false
		_air_boost_armed_left = 0.0
		_start_boost("air", air_boost_power, air_boost_time)
		emit_signal("air_boost_triggered", air_time)
		if air_boost_shake > 0.0:
			emit_signal("camera_shake_requested", air_boost_shake, 0.25)
		print("[Car] 空喷释放! air_time=%.2f power=%.1f" % [air_time, air_boost_power])
		return true
	elif _air_boost_armed and air_time < air_boost_min_air_time:
		# 意图还在, 但这次腾空不够 -> 保留意图(可能接下来就要再飞一次)
		print("[Car] 空喷意图保留: 本次腾空不足(%.2fs < %.2fs)" % [air_time, air_boost_min_air_time])
	return false


func _maybe_trigger_landing_boost_if_armed(air_time: float) -> void:
	# 落地喷: 现在需要玩家显式按 W(落地后的 armed 状态). 不自动触发.
	# 实际触发点在 _try_boost_w 里的"落地喷 pending"分支处理
	# 这里只是记录"刚刚稳定落地, 可以接受落地喷按键"
	if landing_boost_enabled and air_time >= landing_boost_min_air_time:
		_landing_boost_arm_left = landing_boost_press_window
		print("[Car] 落地喷窗口开启(需按 W) air_time=%.2f window=%.2f" % [air_time, landing_boost_press_window])


func _apply_ground_stick(_delta: float) -> void:
	# 统一的"防弹 + 贴附"逻辑. 根据坡度自动切换两种策略, 互不干扰.
	if not ground_stick_enabled:
		return
	if ground_ray == null or not ground_ray.is_colliding():
		return

	var n: Vector3 = ground_ray.get_collision_normal().normalized()
	var cos_a: float = clampf(n.y, 0.0, 1.0)
	var slope_deg: float = rad_to_deg(acos(cos_a))
	var v: Vector3 = linear_velocity

	if slope_deg < plain_slope_threshold_deg:
		# ============ 平地: 强防弹 ============
		# 核心原则: 下压力只在车"真的弹起来"(Y 速度 > 0)时施加
		# 这样才不会干扰上坡助力/重力补偿(它们沿 thrust_dir 施力, 不产生 Y>0)
		# 1) 向上速度超阈值的"小弹"直接归零
		if v.y > 0.0 and v.y < plain_vy_zero_threshold:
			v.y = 0.0
			linear_velocity = v
		# 2) 下坠速度上限
		if plain_vy_down_clamp > 0.0 and v.y < -plain_vy_down_clamp:
			v.y = -plain_vy_down_clamp
			linear_velocity = v
		# 3) 向下压力: 只在车处于"刚弹起 or 悬浮微抬"状态时施加
		#    Y 速度 > 小阈值 → 主动压回地面
		#    Y 速度 <= 0 (贴地或正在下落) → 不压 (让引擎/重力自由发挥)
		if plain_downforce > 0.0 and v.y > plain_downforce_vy_gate:
			apply_central_force(Vector3.DOWN * plain_downforce * mass)
	else:
		# ============ 坡面: 温和贴附 ============
		# 只在"未起跳"(Y 速度较小)且"非峭壁"时贴附
		if slope_deg <= slope_stick_max_deg and absf(v.y) < slope_stick_max_vy and slope_stick_force > 0.0:
			# 沿坡面法线反方向施力, 让车"扣"在坡上
			apply_central_force(-n * slope_stick_force * mass)


# ============================================================
#  视觉 + 车头朝向 (含高速转向衰减)
# ============================================================
func _update_visuals(delta: float) -> void:
	if not car_mesh or not body_mesh:
		return
	if linear_velocity.length() < turn_stop_limit:
		prev_yaw = car_mesh.rotation.y
		return

	if right_wheel and left_wheel:
		var wheel_turn: float = deg_to_rad(steering_deg) * steer_input
		right_wheel.rotation.y = wheel_turn
		left_wheel.rotation.y = wheel_turn

	# 【关键】高速转向衰减：速度越快，转向响应越慢
	var speed: float = linear_velocity.length()
	var speed_factor: float = 1.0
	if state != State.DRIFT and speed > high_speed_threshold:
		var over: float = (speed - high_speed_threshold) / maxf(max_speed - high_speed_threshold, 1.0)
		over = clampf(over, 0.0, 1.0)
		speed_factor = lerpf(1.0, turn_speed_high_speed_mult, over)

	# 转向倍率: 用 drift_intensity 在 速度衰减(speed_factor) 和 漂移倍率 之间平滑插值
	# 漂移氮气时, 漂移转向倍率额外加强(过弯更急更猛)
	var effective_drift_steer: float = drift_steer_mult
	if _is_drift_nitro():
		effective_drift_steer *= drift_nitro_steer_mult
	var turn_mult: float = lerpf(speed_factor, effective_drift_steer, drift_intensity)
	# 退漂转向冷却: 退漂后 N 秒内, 转向倍率被衰减到 post_exit_steer_mult, 平滑回到 1
	# 避免"漂移压制 → 退漂瞬间车头突然超灵敏甩飞"的不适感
	if _post_drift_steer_cooldown_left > 0.0 and post_drift_steer_cooldown > 0.0:
		var t_ratio: float = clampf(_post_drift_steer_cooldown_left / post_drift_steer_cooldown, 0.0, 1.0)
		# 倍率从 post_drift_steer_mult 线性回到 1.0
		var k: float = lerpf(1.0, post_drift_steer_mult, t_ratio)
		turn_mult *= k
	# 反打缩减: 漂移中玩家往"漂移方向的反向"打方向时, 角速度受限制
	#   drift_dir 为漂移方向(-1=左漂, 1=右漂), steer_input 为玩家输入(正=左打, 负=右打)
	#   反打判定: drift_dir 与 steer_input 同号 → 同向(拉角度, 正常); 异号 → 反打(缩减)
	#   注: steer_input 正=左打对应正向漂移方向(drift_dir=1 右漂? 不对, 应再验证方向约定)
	# 按 _try_start_drift: drift_dir = signf(steer_input) → 漂移方向 = 当时的打向
	# 所以"反打" = steer_input 与 drift_dir 异号
	if state == State.DRIFT and drift_dir != 0.0 and drift_intensity > 0.01:
		if signf(steer_input) != 0.0 and signf(steer_input) != signf(drift_dir):
			# 反打: 按漂移强度插值应用缩减(drift_intensity=1 时完全缩减)
			var counter_mult: float = lerpf(1.0, drift_counter_steer_mult, drift_intensity)
			turn_mult *= counter_mult
	var turn_rad: float = deg_to_rad(steering_deg) * steer_input * turn_mult

	var new_basis: Basis = car_mesh.global_transform.basis.rotated(
		car_mesh.global_transform.basis.y, turn_rad
	)
	car_mesh.global_transform.basis = car_mesh.global_transform.basis.slerp(
		new_basis, turn_speed * delta
	)
	car_mesh.global_transform = car_mesh.global_transform.orthonormalized()

	# ============ V2 车身侧倾(带 drift_intensity 插值 + 时间曲线) ============
	var max_lean_rad: float = deg_to_rad(body_tilt_max_deg)
	var lean_base: float = clampf(-steer_input * linear_velocity.length() / body_tilt, -max_lean_rad, max_lean_rad)
	var lean_drift: float = 0.0
	# 漂移时间归一化(用 drift_head_yaw_duration_ref 作为曲线完成点)
	var drift_t_norm: float = clampf(drift_elapsed / maxf(drift_head_yaw_duration_ref, 0.1), 0.0, 1.0)
	var tilt_time_k: float = _sample_curve_safe(drift_body_tilt_curve, drift_t_norm, 1.0)
	# ---------- 反打回正: 反打时车身侧倾衰减, 类似"正打入漂的逆播放" ----------
	# 目标系数:
	#   · 不打 / 正打(steer_input 与 drift_dir 同号或为 0) → 1.0 (保持完整侧倾)
	#   · 完全反打(steer_input 与 drift_dir 异号) → drift_counter_lean_mult (一般 0.0, 即完全回正)
	# 用 |steer_input| 作为反打强度, 平滑到目标
	var counter_target: float = 1.0
	if state == State.DRIFT and drift_dir != 0.0 and signf(steer_input) != 0.0 and signf(steer_input) != signf(drift_dir):
		var cs: float = clampf(absf(steer_input), 0.0, 1.0)
		counter_target = lerpf(1.0, drift_counter_lean_mult, cs)
	_counter_lean_factor = lerpf(_counter_lean_factor, counter_target, clampf(drift_counter_lean_smooth * delta, 0.0, 1.0))
	# 平滑过渡: drift_intensity(0~1) × 时间曲线 × 配置角度 × 漂移方向 × 反打回正系数
	# 漂移氮气时, 侧倾视觉额外加成(更夸张的过弯姿态)
	var tilt_nitro_mult: float = drift_nitro_body_tilt_mult if _is_drift_nitro() else 1.0
	lean_drift = deg_to_rad(drift_body_tilt) * drift_dir * drift_intensity * tilt_time_k * tilt_nitro_mult * _counter_lean_factor
	body_mesh.rotation.z = lerp(body_mesh.rotation.z, lean_base + lean_drift, 6.0 * delta)

	# ============ V2 车头 yaw (漂移时偏转 + 时间曲线动态晃动) ============
	# 非漂移的"拧头"基础量
	var base_head_yaw: float = deg_to_rad(head_yaw_deg) * steer_input
	# 漂移偏转量: 基础 × drift_intensity × 时间曲线(可以让车头在漂移中段更甩)
	var yaw_time_k: float = _sample_curve_safe(drift_head_yaw_curve, drift_t_norm, 1.0)
	var drift_yaw_rad: float = deg_to_rad(drift_yaw_offset) * drift_dir * drift_intensity * yaw_time_k
	# 两者插值合并(drift_intensity=0 时全用 base, =1 时全用 drift)
	var target_head_yaw: float = lerpf(base_head_yaw, drift_yaw_rad, drift_intensity)
	body_mesh.rotation.y = lerp(body_mesh.rotation.y, target_head_yaw, 6.0 * delta)

	# 沿地面法线对齐
	if ground_ray.is_colliding():
		var n: Vector3 = ground_ray.get_collision_normal()
		var xform: Transform3D = _align_with_y(car_mesh.global_transform, n)
		car_mesh.global_transform = car_mesh.global_transform.interpolate_with(xform, 10.0 * delta)

	prev_yaw = car_mesh.rotation.y


func _align_with_y(xform: Transform3D, new_y: Vector3) -> Transform3D:
	xform.basis.y = new_y
	xform.basis.x = -xform.basis.z.cross(new_y)
	return xform.orthonormalized()


# ============================================================
#  漂移
# ============================================================
func _try_start_drift() -> bool:
	if state == State.DRIFT:
		return false
	# 撞墙断漂冷却中: 按 Q 不响应
	if _drift_lockout_left > 0.0:
		print("[Car] _try_start_drift 被 CD 拦截 lockout=%.2fs" % _drift_lockout_left)
		return false
	if linear_velocity.length() < drift_min_speed:
		return false
	if absf(steer_input) < 0.15:
		return false
	if throttle_input < 0.05:
		return false

	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed: float = linear_velocity.dot(right)
	var counter_steer: bool = (
		signf(lateral_speed) != signf(steer_input)
		and absf(lateral_speed) > side_drift_threshold
	)

	drift_dir = signf(steer_input) if steer_input != 0.0 else 1.0
	if counter_steer:
		drift_mode = "side"
		drift_yaw_offset = drift_yaw_offset_side
	else:
		drift_mode = "tuck"
		drift_yaw_offset = drift_yaw_offset_tuck

	state = State.DRIFT
	drift_accum_charge = 0.0
	drift_accum_angle_deg = 0.0
	drift_elapsed = 0.0
	_low_speed_grace_left = 0.0
	_grace_start_angle = 0.0
	_auto_exit_t = 0.0
	# 入漂瞬间: 触发推力爆发期, 产生"重新起步"的冲劲
	_drift_exit_boost_left = drift_exit_boost_duration
	# 入漂时清空双喷蓄能(漂移期间按 Q 是退漂, 不能误蓄能)
	if _double_charge_t > 0.0:
		_double_charge_t = 0.0
		emit_signal("double_charge_progress", 0.0)
	if _double_armed:
		_double_armed = false
		_double_armed_left = 0.0
		emit_signal("double_charge_lost")
	# 入漂时断叠喷链: 漂移是"节奏断点", 退漂后的小喷应该作为新链起点
	# 例: 氮气→W(cw, 氮气延续)→入漂→退漂W → 这个 W 不应该算 cww
	_last_boost_type = ""
	_stack_chain_index = 0
	_stack_breakthrough_count = 0
	_stack_current_breakthrough = false
	_stack_chain_seq.clear()
	# 记录入漂时车头方向(XZ 投影), 后续每帧以此为基准算 yaw 变化
	var _fwd0: Vector3 = -car_mesh.global_transform.basis.z
	_prev_forward_xz = Vector2(_fwd0.x, _fwd0.z).normalized()
	_drift_charge_level = "none"
	emit_signal("drift_charge_level_changed", "none")
	emit_signal("drift_started", drift_mode)
	if drift_fx_node and drift_fx_node.has_method("set_drifting"):
		drift_fx_node.set_drifting(true)
	print("[Car] 进入漂移 mode=", drift_mode, " fx=", drift_fx_node != null, " (lockout=%.2f grace=%.2f Qpressed=%s)" % [_drift_lockout_left, _drift_input_grace_left, str(Input.is_action_pressed("drift"))])
	return true


func _end_drift(_success_boost: bool = false, manual: bool = false, failed: bool = false) -> void:
	if state != State.DRIFT:
		return
	var final_angle: float = drift_accum_angle_deg
	var gained: float = drift_accum_charge
	state = State.NORMAL
	drift_accum_charge = 0.0
	drift_accum_angle_deg = 0.0
	drift_elapsed = 0.0
	drift_mode = ""
	_low_speed_grace_left = 0.0
	_grace_start_angle = 0.0
	_auto_exit_t = 0.0
	# 退漂瞬间: 触发推力爆发期, 让刚出漂的车头有"重新冲起来"的加速感
	_drift_exit_boost_left = drift_exit_boost_duration
	# 退漂转向冷却: 防止转向"瞬间变敏感"
	_post_drift_steer_cooldown_left = post_drift_steer_cooldown
	# 重置反打回正系数, 下次入漂从满 1.0 开始(完整侧倾)
	_counter_lean_factor = 1.0
	# 延迟结算氮气: 漂移期间积累的格子, 退漂时一次性发放
	if _pending_nitro > 0:
		nitro_stock = mini(nitro_stock + _pending_nitro, max_nitro_stock)
		_pending_nitro = 0
		emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
	# 漂移结束: 通知 HUD 灭灯(交给窗口期接管显示)
	if _drift_charge_level != "none":
		_drift_charge_level = "none"
		emit_signal("drift_charge_level_changed", "none")
	# 根据完成度评级开启小喷窗口(双喷不再走这条路, 改为小喷期间按 Q 蓄能)
	# 失败断漂(撞墙) 强制无窗口, 不给小喷奖励
	if not failed and final_angle >= drift_min_angle_to_boost:
		boost_window_level = "mini"
		boost_window_left = boost_window_time
		emit_signal("boost_window_opened", "mini", boost_window_time)
		print("[Car] 退漂窗口: 小喷可用 (角度=%.1f)" % final_angle)
	else:
		boost_window_level = ""
		boost_window_left = 0.0
		if failed:
			print("[Car] 退漂失败(撞墙): 本次不给小喷 (角度=%.1f)" % final_angle)
		else:
			print("[Car] 退漂: 完成度不足无窗口 (角度=%.1f)" % final_angle)
	emit_signal("drift_ended", gained, boost_window_level != "")
	if drift_fx_node and drift_fx_node.has_method("set_drifting"):
		drift_fx_node.set_drifting(false)


func _check_drift_timeout(delta: float) -> void:
	if state != State.DRIFT:
		return
	drift_elapsed += delta
	# 每秒打印一次漂移状态供调试
	if int(drift_elapsed * 2.0) != int((drift_elapsed - delta) * 2.0):
		print("[Car] 漂移中 elapsed=%.1f angle=%.1f° lvl=%s grace=%.2f" % [drift_elapsed, drift_accum_angle_deg, _drift_charge_level, _low_speed_grace_left])
	# drift_max_duration <= 0 表示不限时
	if drift_max_duration > 0.0 and drift_elapsed >= drift_max_duration:
		_end_drift(false)
		return

	# ============ 自动退漂: 车头摆正 + 无侧向惯性 ============
	# 保护期: 刚入漂的 drift_auto_exit_protect_time 秒内不参与自动退漂判定
	#   否则刚入漂时车头与运动方向天然一致(角度≈0°, 侧速≈0), 会立即被判"摆正"而退漂
	if drift_auto_exit_enabled and car_mesh and drift_elapsed >= drift_auto_exit_protect_time:
		var v: Vector3 = linear_velocity
		v.y = 0.0
		var spd: float = v.length()
		# 速度极低时不参与判定(交给低速宽限期处理)
		if spd > 1.0:
			var fwd: Vector3 = -car_mesh.global_transform.basis.z
			var rht: Vector3 = car_mesh.global_transform.basis.x
			var lat_spd: float = absf(v.dot(rht))
			# 车头与运动方向夹角(取绝对值, 单位度)
			var v_dir: Vector3 = v.normalized()
			var dot_v: float = clampf(fwd.dot(v_dir), -1.0, 1.0)
			var angle_deg: float = rad_to_deg(acos(dot_v))
			# 同时满足: 侧向速度小 + 车头与运动方向夹角小
			if lat_spd < drift_auto_exit_lat_speed and angle_deg < drift_auto_exit_angle_deg:
				_auto_exit_t += delta
				if _auto_exit_t >= drift_auto_exit_time:
					print("[Car] 自动退漂: 车头摆正(angle=%.1f° lat=%.2f m/s 持续%.2fs)" % [angle_deg, lat_spd, _auto_exit_t])
					_auto_exit_t = 0.0
					_end_drift(false)
					return
			else:
				_auto_exit_t = 0.0
		else:
			_auto_exit_t = 0.0
	else:
		_auto_exit_t = 0.0

	# (撞墙断漂已改为立即断+入漂CD, 这里无需保护期)

	var low_speed: bool = linear_velocity.length() < drift_min_speed * drift_break_speed_ratio
	if low_speed:
		# 已在宽限期: 倒计时 + 检查"挽救"
		if _low_speed_grace_left > 0.0:
			_low_speed_grace_left -= delta
			# 期间车头再转过 grace_save_angle 即视为挽救成功, 退出宽限期
			if drift_accum_angle_deg - _grace_start_angle >= drift_grace_save_angle:
				print("[Car] 低速挽救成功! 转过 %.1f° (>= %.1f°)" % [drift_accum_angle_deg - _grace_start_angle, drift_grace_save_angle])
				_low_speed_grace_left = 0.0
				return
			# 宽限到期 → 真正断漂
			if _low_speed_grace_left <= 0.0:
				_low_speed_grace_left = 0.0
				_end_drift(false)
				print("[Car] 自动断漂: 低速宽限期结束未挽救")
		else:
			# 第一次进入低速: 启动宽限期
			if drift_low_speed_grace_time > 0.0:
				_low_speed_grace_left = drift_low_speed_grace_time
				_grace_start_angle = drift_accum_angle_deg
				print("[Car] 进入低速宽限期 %.2fs (累计角度=%.1f°)" % [drift_low_speed_grace_time, drift_accum_angle_deg])
			else:
				# 没设宽限期 → 直接断漂(兼容旧行为)
				_end_drift(false)
				print("[Car] 自动断漂: 速度过低(无宽限)")
	else:
		# 速度恢复: 取消宽限期
		if _low_speed_grace_left > 0.0:
			print("[Car] 速度恢复, 退出宽限期")
			_low_speed_grace_left = 0.0


# ============================================================
#  集气公式
# ============================================================
func _update_drift_charge(delta: float) -> void:
	if state != State.DRIFT:
		return

	var right: Vector3 = car_mesh.global_transform.basis.x
	var lateral_speed_abs: float = absf(linear_velocity.dot(right))
	var lateral_contrib: float = lateral_speed_abs * charge_per_lateral_m * delta

	# 【关键】用 basis.z 在 XZ 平面投影的夹角算 yaw_delta, 避免欧拉角跳变 bug
	var fwd: Vector3 = -car_mesh.global_transform.basis.z
	var fwd_xz: Vector2 = Vector2(fwd.x, fwd.z).normalized()
	var yaw_delta_rad: float = 0.0
	if _prev_forward_xz.length() > 0.01:
		yaw_delta_rad = _prev_forward_xz.angle_to(fwd_xz)
	_prev_forward_xz = fwd_xz

	var yaw_rate_abs: float = absf(yaw_delta_rad) / maxf(delta, 0.0001)
	var yaw_contrib: float = yaw_rate_abs * charge_yaw_rate_weight

	# 累积角度(绝对值, 任意方向都算)
	drift_accum_angle_deg += rad_to_deg(absf(yaw_delta_rad))

	var floor_contrib: float = charge_min_per_sec * delta
	var inc: float = lateral_contrib + yaw_contrib + floor_contrib
	drift_accum_charge += inc
	charge += inc

	while charge >= charge_nitro_full and nitro_stock + _pending_nitro < max_nitro_stock:
		charge -= charge_nitro_full
		if instant_nitro_settle:
			# 立即结算: 直接加格子, 触发 HUD 闪光
			nitro_stock += 1
			emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
		else:
			# 延迟结算: 进入待发放队列, 退漂时统一加
			_pending_nitro += 1
	# 集气槽夹紧(防止溢出): 满栏时锁在 99
	if nitro_stock + _pending_nitro >= max_nitro_stock:
		charge = minf(charge, charge_nitro_full - 1.0)

	# 实时等级判定: 通知 HUD 小喷灯(双喷不再在漂移中亮, 改为小喷期间按 Q 蓄能时亮)
	var new_level: String = "none"
	if drift_accum_angle_deg >= drift_min_angle_to_boost:
		new_level = "mini"
	if new_level != _drift_charge_level:
		_drift_charge_level = new_level
		emit_signal("drift_charge_level_changed", new_level)


func angle_difference(a: float, b: float) -> float:
	var d: float = fmod(b - a + PI, TAU)
	if d < 0.0:
		d += TAU
	return d - PI


# ============================================================
#  喷射
# ============================================================
func _try_boost_w() -> void:
	# 0) 空中按 W: 缓存空喷意图(优先于其他判定, 因为空中本来也接不到漂移/窗口/双喷)
	#    满足条件: 已离地超过 air_boost_min_air_time
	#    不满足: 也允许缓存, 落地时若仍未到达最小腾空时间, 则按"普通无效 W"处理
	if air_boost_enabled and _is_airborne:
		_air_boost_armed = true
		_air_boost_armed_left = air_boost_intent_window
		emit_signal("air_boost_armed")
		print("[Car] 空喷意图已缓存 (air_time=%.2f)" % _air_time)
		# 如果配置成"覆盖窗口逻辑", 直接返回, 不再尝试漂移/双喷/窗口路径
		if air_boost_overrides_window:
			return

	# 0.5) 落地喷: 在稳定落地后的按键窗口内按 W -> 触发
	if landing_boost_enabled and _landing_boost_arm_left > 0.0 and not _is_airborne:
		var air_t: float = _last_air_time_for_trigger
		_landing_boost_arm_left = 0.0
		_start_boost("landing", landing_boost_power, landing_boost_time)
		emit_signal("landing_boost_triggered", air_t)
		if landing_boost_shake > 0.0:
			emit_signal("camera_shake_requested", landing_boost_shake, 0.18)
		print("[Car] 落地喷触发! air_time=%.2f" % air_t)
		return

	# 1) 双喷蓄满 + 小喷中 → 直接接力释放双喷
	if _double_armed:
		print("[Car] 双喷接力释放!")
		_double_armed = false
		_double_armed_left = 0.0
		emit_signal("double_charge_lost")
		# 关闭双喷蓄能 FX(双喷自己不需要胎印)
		if state != State.DRIFT:
			_set_double_charge_fx(false)
		# 双喷释放后清掉本次连喷蓄能进度, 防止双喷期间继续蓄出无限双喷
		_double_charge_t = 0.0
		emit_signal("double_charge_progress", 0.0)
		_start_boost("double", double_boost_power, double_boost_time)
		return

	# 2) 漂移中按 W: 立即退漂(进入窗口判定)
	print("[Car] 按 W! state=", state, " angle=%.1f" % drift_accum_angle_deg, " win_left=%.2f" % boost_window_left, " win_lvl=", boost_window_level)
	if state == State.DRIFT:
		_end_drift(false, true)   # W 喷退漂也是玩家明确动作, manual=true
		print("[Car]   退漂后 win_left=%.2f" % boost_window_left, " win_lvl=", boost_window_level)
		# 如果窗口立即开了, 顺势直接释放对应等级喷射
		if boost_window_left > 0.0:
			_consume_boost_window()
		return

	# 3) NORMAL 状态按 W: 看有没有窗口可消耗
	if boost_window_left > 0.0:
		print("[Car]   NORMAL 状态消耗窗口")
		_consume_boost_window()
		return

	# 既不在漂, 也没窗口, 也没蓄好双喷 → 啥也不做
	print("[Car]   无效按 W (无窗口/不漂移)")
	emit_signal("boost_triggered", "insufficient")


func _consume_boost_window() -> void:
	# 现在只处理小喷窗口(双喷走 _double_armed 路径)
	if boost_window_level == "mini":
		_start_boost("mini", mini_boost_power, mini_boost_time)
		print("[Car] 小喷释放!")
	# 关闭窗口
	boost_window_level = ""
	boost_window_left = 0.0
	emit_signal("boost_window_closed")


# ============================================================
#  双喷蓄能 (小喷期间按住 Q 一段时间 → 双喷就绪 → 按 W 释放)
# ============================================================
func _update_double_charge(delta: float) -> void:
	# 双喷已就绪: 倒计时, 超时失效
	if _double_armed:
		_double_armed_left -= delta
		if _double_armed_left <= 0.0:
			_double_armed = false
			_double_armed_left = 0.0
			emit_signal("double_charge_lost")
			# 超时没放: 关闭蓄能 FX
			if state != State.DRIFT:
				_set_double_charge_fx(false)
			print("[Car] 双喷资格超时失效")
		return

	# 蓄能条件:
	#   · 必须在 mini 或 nitro 中 + NORMAL 状态(双喷期间禁止再蓄, 防止无限双喷)
	#   · 当前链已完成叠喷(CWW/WCW) → 禁蓄能(必须等新链)
	#   · 漂移中按 Q 是退漂, 也不蓄能
	var cur_seq_str: String = ""
	for ch in _stack_chain_seq:
		cur_seq_str += ch
	var chain_completed: bool = (cur_seq_str == "cww" or cur_seq_str == "wcw")
	if not is_boosting or boost_type == "double" or chain_completed or state != State.NORMAL:
		# 离开蓄能条件时清零进度
		if _double_charge_t > 0.0:
			_double_charge_t = 0.0
			emit_signal("double_charge_progress", 0.0)
		return

	# 任意喷射期间持续按住 Q
	if Input.is_action_pressed("drift"):
		_double_charge_t += delta
		var prog: float = clampf(_double_charge_t / maxf(double_charge_hold_time, 0.001), 0.0, 1.0)
		emit_signal("double_charge_progress", prog)
		# 蓄能期间开启胎印/火焰视觉(即使不在 DRIFT state)
		_set_double_charge_fx(true)
		if _double_charge_t >= double_charge_hold_time:
			_double_armed = true
			_double_armed_left = double_charge_window
			_double_charge_t = 0.0
			emit_signal("double_charge_ready")
			emit_signal("double_charge_progress", 1.0)
			print("[Car] 双喷已蓄满, 可按 W")
	else:
		# 松开 Q: 进度重置
		if _double_charge_t > 0.0:
			_double_charge_t = 0.0
			emit_signal("double_charge_progress", 0.0)
		# 没按 Q 时: 如果不在漂移中, 关闭蓄能视觉
		if state != State.DRIFT:
			_set_double_charge_fx(false)


# 双喷蓄能期间的 FX 开关(独立于 DRIFT state). 漂移期间由 set_drifting 接管, 这里不冲突
var _double_charge_fx_on: bool = false
func _set_double_charge_fx(on: bool) -> void:
	if on == _double_charge_fx_on:
		return
	_double_charge_fx_on = on
	# 漂移中由 set_drifting 主导; 非漂移中才由蓄能主导胎印
	if state == State.DRIFT:
		return
	if drift_fx_node and drift_fx_node.has_method("set_drifting"):
		drift_fx_node.set_drifting(on)


func _update_boost_window(delta: float) -> void:
	if boost_window_left <= 0.0:
		return
	boost_window_left -= delta
	if boost_window_left <= 0.0:
		boost_window_left = 0.0
		boost_window_level = ""
		emit_signal("boost_window_closed")


func _try_nitro() -> void:
	if nitro_stock <= 0:
		return
	# QQ 飞车氮气规则:
	#   1) 不能在氮气进行中再放氮气(防 CC / 氮气叠氮气)
	#   2) 小喷/双喷进行中可以放氮气(支持 WCW 路径)
	#   3) 漂移中可以放氮气(漂移氮气过弯增强)
	if is_boosting and boost_type == "nitro":
		print("[Car] 氮气进行中, 不能再放氮气")
		emit_signal("boost_triggered", "blocked_boosting")
		return
	nitro_stock -= 1
	emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
	_start_boost("nitro", nitro_power, nitro_time)


# ============================================================
#  叠喷(连喷)系统
#
#  规则:
#   · 接力判定: 前一段 boost 结束后 stack_link_window 秒内启动新 boost = 接力, 链 +1
#   · 突破极速判定: 当前段是 W(mini/double) 且前一段是 C(nitro) → 突破 +1
#       cw   → C-W   1 次突破 (氮气末段接小喷)
#       cww  → C-W-W 2 次突破 (氮气接小喷, 再蓄双喷)
#       ww   → W-W   0 次突破 (漂移→小喷→双喷, 不产生极速突破)
#       注: 小喷不能叠氮气, 所以不存在 wc/wcw 路径
#   · 推力衰减: 越靠后的段推力越低, 用 stack_power_decay[i] 取系数
#   · 极速突破: 突破时 effective_top *= stack_breakthrough_top_mult ^ count, 但仅在当前 boost 是
#     "已突破段"时才生效, 普通段(如 ww 的小喷/双喷)不享受突破上限
# ============================================================
func _check_and_apply_stack_boost(new_type: String) -> void:
	# 空喷/落地喷不参与 CWW/WCW 叠喷判定, 也不打断现有链
	if new_type == "air" or new_type == "landing":
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	# 接力的"前一段"类型:
	#   · 如果当前还在喷(无缝接力, 例如氮气末段按 W) → 用 boost_type
	#   · 否则 → 用记录的 _last_boost_type
	var prev_type: String = boost_type if is_boosting else _last_boost_type
	var time_since_last: float = now - _last_boost_end_time
	var time_linked: bool = prev_type != "" and (is_boosting or time_since_last <= stack_link_window)

	# 当前段在序列里的字母 (c=nitro, w=mini/double)
	var letter: String = "c" if new_type == "nitro" else "w"

	# === 状态机: 只有 CWW / WCW 两种合法叠喷, 其他全部新开链 ===
	# 当前序列拼字符串方便判断
	var cur_seq: String = ""
	for ch in _stack_chain_seq:
		cur_seq += ch
	# 链合法接力的前缀白名单(只有这些前缀允许追加对应字母):
	#   "c"  + "w" → "cw"   (CWW 前缀)
	#   "cw" + "w" → "cww"  (CWW 完成, 之后强制断链)
	#   "w"  + "c" → "wc"   (WCW 前缀)
	#   "wc" + "w" → "wcw"  (WCW 完成, 之后强制断链)
	# 其他所有组合(ww, cc, wcc, cww+任何, wcw+任何...)都视为新开链
	var legal_extension: bool = false
	if time_linked:
		var next_seq: String = cur_seq + letter
		if next_seq == "cw" or next_seq == "cww" or next_seq == "wc" or next_seq == "wcw":
			legal_extension = true

	if not legal_extension:
		_stack_chain_index = 0
		_stack_breakthrough_count = 0
		_stack_current_breakthrough = false
		_stack_chain_seq = [letter] as Array[String]
		print("[Stack] 新链开始: ", new_type, " seq=", _stack_chain_seq)
		return

	# 合法接力, 链 +1
	_stack_chain_index += 1
	_stack_chain_seq.append(letter)
	var new_seq: String = cur_seq + letter

	# 突破判定: 只在最后一段 W (cww 的第二个 w / wcw 的最后 w) 时突破
	# 第一段单 W 或 cw 的中间 W 不算突破, 因为还没完成完整叠喷
	var should_breakthrough: bool = (new_seq == "cww" or new_seq == "wcw")
	if should_breakthrough and _stack_breakthrough_count < stack_max_breakthrough:
		# CWW 完成 = 2 次突破(C 后接两个 W); WCW 完成 = 1 次突破(只有最后那个 W)
		if new_seq == "cww":
			_stack_breakthrough_count = 2
		else:
			_stack_breakthrough_count = 1
		_stack_current_breakthrough = true
	else:
		_stack_current_breakthrough = false

	# combo 名字 = 序列字母大写
	var combo_name: String = new_seq.to_upper()
	emit_signal("combo_triggered", combo_name, _stack_breakthrough_count)

	print("[Stack] 接力 %s->%s seq=%s 突破=%d" % [
		prev_type, new_type, new_seq, _stack_breakthrough_count
	])


func _stack_decayed_power(base_power: float) -> float:
	if stack_power_decay.is_empty():
		return base_power
	var idx: int = clampi(_stack_chain_index, 0, stack_power_decay.size() - 1)
	return base_power * stack_power_decay[idx]


# 漂移过弯增强: 漂移 + 氮气同时存在时返回 true
func _is_drift_nitro() -> bool:
	return state == State.DRIFT and is_boosting and boost_type == "nitro"


func _update_stack_chain_timeout() -> void:
	# 仅在不喷射时检测链超时. 喷射中链是"活的", 不计时
	if is_boosting:
		return
	if _last_boost_type == "":
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_boost_end_time > stack_link_window:
		# 链已断: 清零(下次 _start_boost 会被识别为新链)
		if _stack_chain_index > 0 or _stack_breakthrough_count > 0:
			print("[Stack] 连喷链超时断开, 链清零")
		_last_boost_type = ""
		_stack_chain_index = 0
		_stack_breakthrough_count = 0
		_stack_current_breakthrough = false


func _start_boost(type_name: String, power: float, duration: float) -> void:
	# 【特殊路径】氮气进行中按 W 释放小喷/双喷: 不打断氮气, 延续之
	#   · 不替换 boost_type(氮气视觉/逻辑保留)
	#   · 但走叠喷判定(突破计数+1, combo 弹字)
	#   · 把小喷/双喷的 duration 加到 boost_time_left, 让氮气延长
	#   · 推力可以被衰减后的小喷/双喷推力增强(取较大者保持氮气感)
	if is_boosting and boost_type == "nitro" and (type_name == "mini" or type_name == "double"):
		_check_and_apply_stack_boost(type_name)
		var dp_extend: float = _stack_decayed_power(power)
		boost_time_left += duration
		boost_total_time += duration
		boost_base_power = maxf(boost_base_power, nitro_power) + dp_extend * 0.5
		boost_power = boost_base_power
		emit_signal("boost_triggered", type_name)
		_emit_nitro_variant()
		print("[Boost] 氮气延续: 接 %s, 剩余=%.2f, 突破=%d" % [type_name, boost_time_left, _stack_breakthrough_count])
		return

	# 叠喷判定: 在覆盖 boost_type 之前先判断
	_check_and_apply_stack_boost(type_name)
	# 应用推力衰减(根据当前在链中的位置)
	var dp: float = _stack_decayed_power(power)

	boost_type = type_name
	boost_base_power = dp
	boost_power = dp
	boost_total_time = duration
	boost_time_left = duration
	is_boosting = true
	emit_signal("boost_triggered", type_name)
	if type_name == "nitro":
		_emit_nitro_variant()

	# 震屏: 全部由 Tuner 中可调参数控制, 默认全 0
	var shake := {"mini": mini_boost_shake, "double": double_boost_shake, "nitro": nitro_boost_shake}
	var sh_amp: float = shake.get(type_name, 0.0)
	if sh_amp > 0.0:
		emit_signal("camera_shake_requested", sh_amp, duration)

	if fx_node and fx_node.has_method("play_boost"):
		fx_node.play_boost(type_name, duration)
	# 多喷口: 同步广播给其他 fx_nodes
	for i in range(1, fx_nodes.size()):
		var fn: Node = fx_nodes[i]
		if fn and fn.has_method("play_boost"):
			fn.play_boost(type_name, duration)


func _emit_nitro_variant() -> void:
	# 氮气颜色变体: 突破次数 0=blue / 1=gold / 2=red (3 及以上保持 red)
	var variant: String = "blue"
	if _stack_breakthrough_count >= 2:
		variant = "red"
	elif _stack_breakthrough_count == 1:
		variant = "gold"
	emit_signal("nitro_variant_changed", variant)
	if fx_node and fx_node.has_method("set_nitro_variant"):
		fx_node.set_nitro_variant(variant, _stack_breakthrough_count)
	for i in range(1, fx_nodes.size()):
		var fn: Node = fx_nodes[i]
		if fn and fn.has_method("set_nitro_variant"):
			fn.set_nitro_variant(variant, _stack_breakthrough_count)


func _update_boost_timer(delta: float) -> void:
	if not is_boosting:
		return
	# 氮气中松开前进键 → 立即结束氮气(QQ飞车手感)
	# 用 0.05 的微小死区避免抖动
	if nitro_require_throttle and boost_type == "nitro" and throttle_input < 0.05:
		print("[Car] 氮气松手中断: throttle=%.2f, 剩余 %.2fs → 立即结束" % [throttle_input, boost_time_left])
		# 直接走结束分支(别等下一帧)
		_force_end_boost()
		return
	boost_time_left -= delta
	# 应用曲线: 进度 0..1 → 曲线值 → 缩放当前推力
	var progress: float = 1.0 - clampf(boost_time_left / maxf(boost_total_time, 0.0001), 0.0, 1.0)
	var curve: Curve = _get_boost_curve(boost_type)
	if curve:
		boost_power = boost_base_power * curve.sample(progress)
	else:
		boost_power = boost_base_power
	if boost_time_left <= 0.0:
		_force_end_boost()


func _force_end_boost() -> void:
	if not is_boosting:
		return
	if boost_type == "mini":
		last_mini_end_time = Time.get_ticks_msec() / 1000.0
	# 记录刚结束的 boost 类型和时刻, 供下一段叠喷判定 (air/landing 不进入叠喷历史)
	if boost_type != "air" and boost_type != "landing":
		_last_boost_type = boost_type
		_last_boost_end_time = Time.get_ticks_msec() / 1000.0
	var ended_type: String = boost_type
	is_boosting = false
	boost_type = ""
	boost_power = 0.0
	boost_base_power = 0.0
	boost_time_left = 0.0
	# 停掉粒子特效(尤其是被松手中断的氮气, 不停的话尾焰还在)
	if fx_node and fx_node.has_method("_stop_all"):
		fx_node._stop_all()
	for i in range(1, fx_nodes.size()):
		var fn: Node = fx_nodes[i]
		if fn and fn.has_method("_stop_all"):
			fn._stop_all()
	# 喷射结束: 蓄能进度未完成 → 清零(避免灯残留)
	if _double_charge_t > 0.0:
		_double_charge_t = 0.0
		emit_signal("double_charge_progress", 0.0)
	# 注: 已 armed(蓄满) 的双喷资格不清, 让玩家在 double_charge_window 期间还能按 W 释放
	# 即使小喷自然结束了, 双喷资格依然有效, 直到 _double_armed_left 倒计时结束才失效
	# 清掉双喷蓄能期间的胎印/火焰 FX(如果有)
	if state != State.DRIFT and not _double_armed:
		_set_double_charge_fx(false)
	print("[Car] boost 结束: ", ended_type)


func _get_boost_curve(type_name: String) -> Curve:
	match type_name:
		"mini":
			return mini_boost_curve
		"double":
			return double_boost_curve
		"nitro":
			return nitro_boost_curve
		"air":
			return air_boost_curve
		"landing":
			return landing_boost_curve
	return null


# ============================================================
#  撞墙
# ============================================================
func _on_body_entered(_body: Node) -> void:
	if state != State.DRIFT:
		return
	# 【修复】只有真正撞墙才扣气: 用"速度大小骤降"判定
	# 保存上一帧速度, 本帧碰撞后若速度损失 > 阈值才算撞墙
	var cur_speed: float = linear_velocity.length()
	var speed_loss: float = _last_frame_speed - cur_speed
	if speed_loss < wall_crash_speed_loss:
		return   # 轻微擦碰, 不算
	var lost: float = drift_accum_charge * (1.0 - crash_charge_penalty)
	charge = maxf(charge - lost, 0.0)
	drift_accum_charge *= crash_charge_penalty
	emit_signal("wall_crashed", lost)
	if wall_crash_shake > 0.0:
		emit_signal("camera_shake_requested", wall_crash_shake, 0.25)


# ============================================================
#  斜面墙 + 接触法线检测 (在物理回调中才能拿到有效 contact)
# ============================================================
func _integrate_forces(state_phys: PhysicsDirectBodyState3D) -> void:
	if not slope_as_wall_enabled:
		return
	var contact_count: int = state_phys.get_contact_count()
	if contact_count <= 0:
		return
	var wall_threshold_rad: float = deg_to_rad(slope_wall_angle_deg)
	var absorbed: bool = false
	# 用车头方向判断撞击点是车的哪一侧
	var car_forward: Vector3 = -car_mesh.global_transform.basis.z if car_mesh else Vector3.FORWARD
	var car_right: Vector3 = car_mesh.global_transform.basis.x if car_mesh else Vector3.RIGHT
	for i in range(contact_count):
		var n: Vector3 = state_phys.get_contact_local_normal(i)
		# n 与 Y 轴夹角: 0°=纯地面, 90°=纯墙
		var angle_to_up: float = n.angle_to(Vector3.UP)
		if angle_to_up >= wall_threshold_rad and not absorbed:
			# 投影出沿法线方向的速度分量, 抵消掉
			var v: Vector3 = state_phys.linear_velocity
			var into_wall: float = -v.dot(n)  # 朝墙冲的速率(正值)
			if into_wall > 0.5:
				v += n * into_wall * slope_wall_bounce_absorb
				# 沿法线推开一点, 避免卡墙
				v += n * slope_wall_push_back
				# === 后半身/侧面撞墙: 额外给沿车头方向的"弹墙推力" ===
				# 判定撞击点位于车的哪部分: 用接触点法线 n 投影到车头/车右轴
				#   n.dot(car_forward) > 0 → 法线指向车头方向 → 撞击点在车后半 (墙在车后)
				#   n.dot(car_forward) < 0 → 撞击点在车前半 (墙在车前, 头撞墙)
				#   |n.dot(car_right)| 大 → 侧撞 (无论前后)
				if wall_bounce_boost_enabled:
					var rear_factor: float = n.dot(car_forward)   # 越大说明墙在车后(尾撞)
					var side_factor: float = absf(n.dot(car_right))   # 越大说明侧撞
					var is_rear_or_side: bool = rear_factor > wall_bounce_rear_threshold or side_factor > wall_bounce_side_threshold
					if is_rear_or_side and into_wall > wall_bounce_min_into_speed:
						# 沿车头方向加一个推力(让车从"被卡住"变成"擦墙加速")
						v += car_forward * wall_bounce_forward_speed
						emit_signal("boost_triggered", "wall_bounce")
						print("[Car] 弹墙推力! rear_factor=%.2f side_factor=%.2f boost=%.1f" % [rear_factor, side_factor, wall_bounce_forward_speed])
				state_phys.linear_velocity = v
				absorbed = true
				# 漂移中撞墙 → 立即失败断漂: 本次不给小喷, 并进入入漂冷却
				if state == State.DRIFT:
					_end_drift(false, false, true)
					if wall_drift_lockout_time > 0.0:
						_drift_lockout_left = wall_drift_lockout_time
					# 强制清空入漂宽限期, 防止"按住 Q 撞墙"瞬间残留的 grace 在 CD 之后立即续上
					_drift_input_grace_left = 0.0
					# 标记需要"松开再按"才能续漂(避免按住 Q 在 CD 结束时被 is_action_pressed 自动接住)
					_require_release_q = true
					print("[Car] 撞墙断漂! CD=%.2fs (需要松开 Q 后重按才能再漂)" % wall_drift_lockout_time)
				if slope_wall_shake > 0.0:
					emit_signal("camera_shake_requested", slope_wall_shake, 0.2)


# ============================================================
#  HUD 信号
# ============================================================
func _emit_hud_signals() -> void:
	var kmh: float = linear_velocity.length() * 3.6
	emit_signal("speed_changed", kmh)
	emit_signal("charge_changed", charge, charge_nitro_full)
