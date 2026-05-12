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
## 松前(漂移中松开前进键)时, drift_extra_decel 的倍率.
## 数学: final_decel = drift_extra_decel × lerp(1.0, songqian_mult, _drift_slip_factor)
## 默认 0.3 = 松前时额外能耗只保留 30%, 让车滑得更远. 设 1.0 = 不变, 设 0 = 松前完全没能耗
@export_range(0.0, 3.0, 0.05) var drift_extra_decel_songqian_mult: float = 0.3

# ---------------- 松前漂移 (DRIFT 状态下的子状态: 漂移中松开前进键) ----------------
# 概念定义 (用户最终规则):
#   "松前" = 漂移中松开前进键 (但保持按住入弯方向键). 赛车保持 DRIFT 状态, 但:
#     · 车头会朝 drift_dir 方向慢慢偏, 相对起漂时车头方向最多偏到 90°
#     · 车体继续以惯性运动(摩擦力降到极低)
#     · **粘性锁定**: 一旦进入松前就保持松前状态
#     · 玩家行动选项:
#         踩回前进键 → **自动触发"松前漂移"** (给推力爆发, 切回普通漂移)
#         按 Q + W + 角度足够 → 触发"三喷"(松前后退喷, 沿车头反方向)
#         按 Q (单独) → 静默吞掉
#         按 W (单独) → 静默吞掉
#         撞墙/低速/超时 → 漂移结束(_end_drift)
#
# 状态变量:
#   _is_in_songqian = bool 粘性锁定. 入口=松油门, 出口=_trigger_songqian_drift / _end_drift
@export var songqian_drift_enabled: bool = true
## 松前车头偏移上限(度): 相对起漂时车头方向最多偏的角度. 90° = 横到底(车身完全侧向)
@export_range(0.0, 180.0, 1.0) var songqian_yaw_limit_deg: float = 90.0
## 松前车头偏移速度(度/秒): 多快达到上限角. 推荐 60~120
@export_range(10.0, 360.0, 5.0) var songqian_yaw_speed_deg: float = 90.0
## 松前漂移触发(踩回前进键自动)的冲量(沿车头方向, 单位 m/s² × mass)
@export var songqian_drift_kick_impulse: float = 14.0
## 松前漂移爆发期持续时间(秒). 复用 _drift_exit_boost_left/_mult 机制
@export_range(0.1, 2.0, 0.05) var songqian_drift_boost_duration: float = 0.7
## 进入松前时的"小加速"冲量 (沿车体当前运动方向). 模拟"打滑滑行"的轻微势能保留
## 设 0 = 不加速(纯惯性); 推荐 3~6
@export var songqian_enter_kick_impulse: float = 4.0

## 【松前转向倍率】松前期间转向倍率 (相对漂移转向再乘这个数)
## 动机: 松前 = 轮胎打滑状态, 物理上车头不应该再灵敏响应方向键, 否则车头会乱甩
##       松前下原本走 drift_steer_mult (默认 1.6) 太灵敏, 玩家一动方向就甩飞
## 数学: 松前期间 turn_mult = drift_steer_mult × songqian_steer_mult
## 例: 0.3 = 松前转向只剩漂移转向的 30%, 让车头摆动很缓慢
## 设 1.0 = 不限制, 设 0.0 = 完全禁止松前期间转向
@export_range(0.0, 1.5, 0.05) var songqian_steer_mult: float = 0.3

# ---------------- 三喷 (松前后退喷) ----------------
# 概念: 松前打滑状态下, 车身相对起漂方向旋转超过 songqian_back_min_yaw_deg 时,
#       同时按 Q + W 触发"后退喷". 沿车头反方向给一次性大冲量.
#       后退喷结束后允许蓄双喷, 玩家用双喷指法即可接出双喷, 完成"三喷"组合.
#
# 触发链路 (玩家视角):
#   1) 漂移中松开 W → 进入松前
#   2) 车头相对起漂方向偏过去 (达到 songqian_back_min_yaw_deg, 默认 60°)
#   3) 按住 Q (drift) + 按 W (boost) → 触发后退喷! 弹字"三喷"
#   4) 玩家不松手, 持续按住 Q 蓄能 → 蓄满后按 W → 接力双喷, 三段完成
@export_group("Songqian Back Boost (三喷)")
## 三喷开关
@export var songqian_back_boost_enabled: bool = true
## 三喷触发的最小车头偏角 (度): 相对起漂方向偏过此角度才能触发. 推荐 60~90
## 数学: |当前车头与 _drift_start_forward 的夹角| ≥ 此值
@export_range(0.0, 180.0, 1.0) var songqian_back_min_yaw_deg: float = 60.0
## 三喷推力 (沿车头反方向, m/s² × mass). 推荐 80~150
@export var songqian_back_boost_power: float = 110.0
## 三喷持续时间 (秒)
@export_range(0.1, 2.0, 0.05) var songqian_back_boost_time: float = 0.5
## 三喷冲量 (除了持续推力, 还给一次性瞬时冲量, 让车头反向"嘭"一下). 推荐 8~15
@export var songqian_back_kick_impulse: float = 10.0

# ---------------- (废弃) NORMAL 状态打滑车身角度限制 ----------------
# 这套逻辑原本是误解需求时加的, 现在松前=DRIFT 子状态而非 NORMAL 打滑
# 保留 export 兼容旧 cfg, 但实际不再生效 (drift_slip_cap_enabled 设 false)
# 真正的"车头 90° 限制"在 songqian_yaw_limit_deg 里管理
@export var drift_slip_cap_enabled: bool = false
@export_range(10.0, 180.0, 1.0) var drift_slip_cap_angle_deg: float = 90.0

# ---------------- 漂移打滑 (松开前进键时) ----------------
# 机制: 漂移中玩家松开 W 键 → 赛车进入"打滑"状态: 前后/侧向摩擦被大幅削减
# 数学:
#   · slip_factor = 0 (油门满) ~ 1 (完全松开), 按 1 - clamp(throttle, 0, 1) 平滑计算
#   · long_k 和 lat_k 在漂移中会被 ×(1 - slip_factor × drift_slip_friction_cut)
#     drift_slip_friction_cut = 1.0 时: 完全松油门 → 摩擦系数 = 0 (纯惯性滑行)
#     drift_slip_friction_cut = 0.9 时: 完全松油门 → 摩擦保留 10%
# 效果: 漂移中松开前进键, 车会沿惯性继续划出去, 不受前后摩擦拖慢, 也没有侧向抓地把车头拉回
@export var drift_slip_enabled: bool = true               ## 是否启用漂移打滑机制
@export_range(0.0, 1.0, 0.05) var drift_slip_friction_cut: float = 1.0    ## 完全松油门时摩擦削减比例 (1.0=完全打滑, 0.0=不打滑)
@export_range(0.0, 20.0, 0.5) var drift_slip_smooth: float = 8.0          ## 打滑系数过渡平滑速度(越大响应越锐利)

# ---------------- 漂移手感: 惯性感 & 向心力感 ----------------
# 【惯性感】= "车被甩出去之后按现在的速度方向飞"的感觉. 通过降低漂移时沿"运动方向"的摩擦实现.
# 【向心力感】= "车头牵着车速一起走"的感觉. 通过施加一个把 linear_velocity 向 forward 方向拉的加速度实现.
#
# 数学:
#   惯性增强: 漂移时, 把"沿速度方向"的 long+lat 合成摩擦按 (1 - drift_inertia_boost × drift_intensity) 缩减
#            0.0=不增强(原样); 1.0=漂移中摩擦(除空气阻力)完全被忽视(车一直滑)
#   向心力 : 每帧施加 F_cp = mass × drift_centripetal_pull × drift_intensity × (forward - v_dir) × v_horizontal
#            单位: m/s² × 速度大小(为了让高速弯更粘). 0 = 关闭; 10~30 推荐
@export_range(0.0, 1.0, 0.02) var drift_inertia_boost: float = 0.0        ## 漂移惯性增强(削减漂移中沿惯性方向的摩擦)
@export_range(0.0, 50.0, 0.5) var drift_centripetal_pull: float = 0.0     ## 漂移向心拉力系数(车头把速度方向带过去)
## 向心拉力与速度的耦合曲线: X=0→低速弯, X=1→drift_head_yaw_duration_ref 秒时的速度参考
@export var drift_centripetal_curve: Curve                                ## 可选, 留空则线性

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

# ---------------- 反打减速 (用户最新需求) ----------------
# 设计动机:
#   漂移中玩家"反打"(steer 与 drift_dir 异号) 在真实物理里相当于"轮胎重新抓地+方向相反",
#   会引发一次明显的减速 / 抓地反应. 旧版本只做了"侧倾回正"视觉效果, 没有物理减速,
#   导致反打感觉"车身回正了但速度没变化", 不真实.
#
# 实现:
#   每帧检测: state == DRIFT + steer_input 与 drift_dir 异号 + |steer_input| ≥ 阈值
#   若满足:   沿当前水平速度 v_horiz 反向施加一个减速力 = drift_counter_decel × |steer| × mass
#   位置:     在 _apply_engine_and_brake 末尾(其他推力/刹车都算完之后) 单独施加, 不和引擎打架
#
# 数学:
#   F_brake = -v_horiz_normalized × drift_counter_decel × |steer_input| × mass
#   |steer| 越大减速越强, 给玩家"踩多深抓多深"的细腻手感
#
## 反打减速开关
@export var drift_counter_decel_enabled: bool = true
## 反打减速强度 (m/s² × mass, 即每秒减多少 m/s 速度. |steer|=1 时的全力减速)
## 数学: F = drift_counter_decel × |steer_input| × mass, 沿 -v_horiz 方向施加
## 推荐 6~14: 6 = 轻微减速感; 10 = 明显抓地刹车; 14+ = 急停感
@export_range(0.0, 30.0, 0.1) var drift_counter_decel: float = 8.0
## 反打减速最小输入阈值: |steer_input| ≥ 此值才触发减速
## 防止"轻微反打/方向键抖动"也减速, 推荐 0.2~0.4
@export_range(0.0, 1.0, 0.01) var drift_counter_decel_min_steer: float = 0.25

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

# ---------------- 真实反弹物理 (v2 重写) ----------------
@export_group("Wall Reflect (Realistic)")
## 真实反弹: 切向速度保留比例 (0=切向速度归零, 1=切向速度完全保留)
## 推荐 0.85~0.95: 擦墙后基本不掉速, 像真实赛车
@export_range(0.0, 1.0, 0.05) var wall_reflect_tangent_keep: float = 0.9
## 真实反弹: 法线方向反弹系数 (恢复系数 e)
## 0=完全吸收无弹回(粘墙), 1=完美弹性(撞回去和撞过来一样快), 推荐 0.3~0.5
@export_range(0.0, 1.0, 0.05) var wall_reflect_normal_factor: float = 0.4
## 真实反弹: 擦墙临界角(度) - 车头与墙面夹角小于此值视为擦墙, 不施加额外摩擦
## 90°=正面撞(完全弹回), 0°=平行墙(完全擦过). 推荐 20°
@export_range(0.0, 90.0, 1.0) var wall_grazing_angle_deg: float = 20.0
## 真实反弹: 玻璃渣特效场景
@export var glass_shatter_fx_scene: PackedScene = preload("res://GlassShatterFX.tscn")
## 玻璃渣触发的最小撞击速度 (m/s) - 低于此速度的轻碰不出特效
@export var glass_shatter_min_speed: float = 3.0

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
## 0 = 只要腾空就能空喷 (防抖可用 0.03 左右)
@export var air_boost_min_air_time: float = 0.0
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

## 【空喷滞空感】空喷期间, 空中每帧施加的向下力 (只在 _is_airborne=true 时生效)
## 动机: 空喷本身是水平向前推力, 如果没有向下的"压力", 赛车会因为推力 + 惯性飞得老远
##       这个下压力给一种"悬浮中滑翔"的手感, 让空喷感觉有"重量"而不是火箭起飞
## 单位: m/s² (会乘 mass 成力), 相当于额外重力. 设 0 = 关闭. 推荐 3~10
## 例: 5.0 = 额外 5m/s² 向下, 相当于额外半个重力(默认重力 9.8)
@export var air_boost_downforce: float = 5.0

## 落地预输入缓冲时间(秒): 玩家在空中按下的 W/Q, 若在此时间内尚未被消费, 落地瞬间会自动回放为 just_pressed
## 用途: 玩家"快落地时按键"不会被吞, 比如提前按 W 求落地喷、提前按 Q 求落地后起漂
## 推荐 0.2~0.4. 0 = 禁用
@export var landing_input_buffer_time: float = 0.3

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
## 注: 当 landing_hard_stick = true 时, 此参数被忽略(直接强制 Y=0)
@export var landing_impact_absorb: float = 0.85

## 【硬落地】落地瞬间是否直接把 Y 速度归零 (不留任何下落动量, 杜绝弹跳)
## 默认 false: 因为原生 _apply_ground_stick 的 plain_vy_zero_threshold + plain_downforce 已经能防弹
##           而 hard_stick=true 会和原生防弹"打架"导致车在落地后半秒内悬浮(Y 位置无法稳定下沉)
## true  = 落地瞬间 linear_velocity.y 强制 = 0 (慎用, 会导致悬浮)
## false = 走 landing_impact_absorb 比例吸收(原行为, 推荐)
@export var landing_hard_stick: bool = false

## 【压地窗口】落地后 N 秒内, 每帧把向上的 Y 速度 clamp 到 0 (彻底消除二次弹跳)
## 默认 0: 关闭. 因为原生 _apply_ground_stick 的 plain_vy_zero_threshold(默认 5) 已经能在每帧把
##        Y>0 的小弹归零, 再叠这个窗口会和原生机制重复触发, 导致落地半秒诡异悬浮.
## 推荐 0 (关闭). 仅在原生防弹失效时才考虑开
@export_range(0.0, 1.0, 0.01) var landing_stick_duration: float = 0.0

## 【压地最小下落速度阈值】只有以足够速度砸下来才启用压地窗口
## 单位 m/s, 推荐 1.5~3.0. 设 0 = 任何落地都压
@export var landing_stick_min_fall_speed: float = 1.5

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
## 松前状态变化: active=true 进入松前, false 离开松前 (供 HUD 显示"松前"提示)
signal songqian_state_changed(active: bool)
## 三喷 (松前后退喷) 触发: 携带角度信息供 HUD 显示
signal songqian_back_boost_triggered(yaw_deg: float)

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
# ---- 双喷蓄能资格 ----
# 规则: 只有"退漂小喷"(即 _consume_boost_window 路径触发的 mini) 允许按住 Q 蓄双喷.
# 空喷(air)、落地喷(landing)、双喷自身(double)、氮气(nitro) 都 **不** 允许蓄双喷.
# 这是为了避免"空喷立刻蓄双喷 → 无需漂移也能无限叠加"的廉价操作, 双喷必须奖励给真正完成漂移的玩家.
var _can_charge_double: bool = false
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
# 压地窗口: 落地后此秒数内, 每帧把向上 Y 速度 clamp 0, 彻底消除二次弹跳
var _landing_stick_left: float = 0.0
var _landing_boost_arm_left: float = 0.0         # 稳定落地后落地喷的按键窗口剩余时间
var _wall_drift_protect_left: float = 0.0         # (已废弃, 保留避免其他地方的未来引用) 撞墙断漂已改为立即断+CD
var _drift_lockout_left: float = 0.0              # 撞墙断漂后的入漂冷却剩余秒数, >0 时按 Q 无法入漂
# 撞墙断漂后, 玩家必须先松开 Q 再重新按下才能再次入漂
# 防止"按住 Q 撞墙→CD 走完→Q 还按着→自动续漂"
var _require_release_q: bool = false
var _post_drift_steer_cooldown_left: float = 0.0  # 退漂转向冷却剩余秒数
# 反打时车身倾斜衰减系数, 平滑到 1.0(正打/不打) ~ drift_counter_lean_mult(完全反打)
var _counter_lean_factor: float = 1.0
# 漂移打滑系数 (0=完全抓地, 1=完全打滑即摩擦归零)
# 每帧由 _apply_friction 按 throttle_input 驱动, 在 DRIFT 状态下才有意义
var _drift_slip_factor: float = 0.0

# ---- 松前 (DRIFT 子状态) ----
# 起漂瞬间记录的"起漂时车头方向"(XZ 平面归一化), 用于松前 yaw 偏移上限计算
var _drift_start_forward: Vector3 = Vector3.FORWARD
# 累计的松前 yaw 偏移角(度): 0=未偏, 增长方向跟 drift_dir 一致, 上限 songqian_yaw_limit_deg
# 退出松前(踩油门)后逐渐回零
var _songqian_yaw_offset: float = 0.0
# 当前帧是否处于松前状态 (由 _read_input/_process 维护, 用于 Q 键判定和退漂区分)
var _is_in_songqian: bool = false
# 松前小加速是否已经发放 (一次性, 进入松前时发一次)
var _songqian_kick_given: bool = false

# ---- 落地预输入缓冲 ----
# 机制: 在空中按下 W 或 Q 的"最近一次 just_pressed" 会被记录.
# 落地瞬间(_is_airborne: true → false) 检查缓冲:
#   · 若 W 在 landing_input_buffer_time 秒内按过 → 落地后立刻补触发一次 _try_boost_w
#     (这样玩家"快落地时按 W"不会被吞, 能稳定触发落地喷/接续连喷)
#   · 若 Q 在 landing_input_buffer_time 秒内按过 且 落地后仍 NORMAL → 落地后立刻尝试入漂
#     (用于"在空中提前按 Q 准备落地后起漂")
# 起飞前若处于 DRIFT, 空中按 Q 不会断漂(_read_input 里空中忽略 Q 的退漂意图), 落地自然延续
var _pending_landing_w_left: float = 0.0   # 预输入 W 剩余有效秒数 (倒计时)
var _pending_landing_q_left: float = 0.0   # 预输入 Q 剩余有效秒数 (倒计时)

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

	# ---- 落地预输入缓冲: 空中按 W/Q 会刷新缓冲计时 ----
	# 每帧倒计时, 直到落地瞬间被消费或时间耗尽
	if _pending_landing_w_left > 0.0:
		_pending_landing_w_left -= get_physics_process_delta_time()
		if _pending_landing_w_left < 0.0:
			_pending_landing_w_left = 0.0
	if _pending_landing_q_left > 0.0:
		_pending_landing_q_left -= get_physics_process_delta_time()
		if _pending_landing_q_left < 0.0:
			_pending_landing_q_left = 0.0

	# Q 点按: 漂移意图优先(喷气和漂移可共存)
	#   · 空中 + DRIFT: 忽略, 不打断漂移 (空中保持漂移状态, 落地延续)
	#   · 空中 + NORMAL: 记录到预输入缓冲, 落地时回放
	#   · 地面 + NORMAL → 启动入漂宽限期
	#   · 地面 + DRIFT → 手动退漂(不喷)
	if Input.is_action_just_pressed("drift") and not _require_release_q:
		if _is_airborne:
			if state == State.NORMAL:
				# 空中按 Q 求落地后起漂 → 缓冲, 落地瞬间回放
				_pending_landing_q_left = landing_input_buffer_time
				print("[Car] 空中 Q 预输入缓冲 (%.2fs)" % landing_input_buffer_time)
			# 空中 + DRIFT: 直接忽略, 漂移保持
		else:
			if state == State.NORMAL:
				# 立即尝试一次, 不行就启动宽限期
				if not _try_start_drift():
					_drift_input_grace_left = drift_input_grace_window
			else:
				# DRIFT 状态下按 Q (松前漂移规则, 用户最终修订):
				#   · 松前中按 Q + 同时按住 W + 车头偏角足够 → 触发"三喷"(后退喷)
				#   · 松前中按 Q (其他情况) → **静默吞掉**, 漂移继续
				#     【关键】松前漂移的触发方式已改为"踩回前进键"自动触发, Q 不再参与松前漂移触发
				#     松前状态下绝对不允许通过按 Q 退漂/断漂, 想退漂请先踩回前进键退出松前
				#   · 满油门按 Q (非松前) → 普通手动退漂(原行为)
				if songqian_drift_enabled and _is_in_songqian:
					# 检查三喷触发: Q 同帧 + W 持续按住 + 车头偏角 ≥ 阈值
					if songqian_back_boost_enabled and Input.is_action_pressed("boost"):
						var cur_yaw_deg: float = _calc_songqian_yaw_deg()
						if absf(cur_yaw_deg) >= songqian_back_min_yaw_deg:
							_trigger_songqian_back_boost(cur_yaw_deg)
						else:
							print("[Car] 三喷条件不足: 偏角 %.1f° < %d° 阈值" % [cur_yaw_deg, int(songqian_back_min_yaw_deg)])
					else:
						# 松前下按 Q: 静默吞掉, 不退漂不弹字, 仅打 log
						print("[Car] 松前下按 Q 被吞 (松前漂移由'踩回前进键'触发, 三喷需同时按 W)")
				else:
					_end_drift(false, true)   # 普通手动按 Q 退漂(原行为, 走正常退漂窗口逻辑)
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
		# 空中按 W: 除了现有"空喷意图缓存", 同时设置落地预输入缓冲
		# 这样如果落地瞬间空喷条件没满足(例如 air_time 太短), 落地后也能回放 W 给落地喷/窗口消费
		if _is_airborne:
			_pending_landing_w_left = landing_input_buffer_time
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
	# === 视觉车头方向 ===
	# car_mesh.basis.z = 骨架朝向(被 steer 控制), 但漂移时车壳额外被拧过 drift_yaw_offset
	# 所以"玩家眼睛看到的车头" = 骨架朝向 × body_mesh.rotation.y
	# 推力沿这个方向施加, 漂移时按 W 推力就是冲着尖尖去的, 不会感觉"沿镜头方向"
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	if body_mesh and absf(body_mesh.rotation.y) > 0.001:
		var b: Basis = car_mesh.global_transform.basis.rotated(car_mesh.global_transform.basis.y, body_mesh.rotation.y)
		forward = -b.z
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
		# 【三喷特殊】songqian_back 的推力沿车头反方向 (-forward), 不沿 velocity
		# 这是"后退喷"的本质: 车在松前打滑, 车头朝侧面, "后退"= 朝车头反方向推
		# 实际效果是把赛车朝运动方向继续推, 但来源是车尾喷射, 视觉/音效上有"反向爆发"感
		if boost_type == "songqian_back":
			vel_dir = car_mesh.global_transform.basis.z   # +Z 是车尾方向 (= -forward)
			vel_dir.y = 0.0
			if vel_dir.length() > 0.001:
				vel_dir = vel_dir.normalized()
		apply_central_force(vel_dir * boost_power * mass)

	# ============ 空喷滞空感 (下压力) ============
	# 只在空喷进行中 + 离地时施加一个向下的力
	# 数学: F = (0, -air_boost_downforce, 0) * mass    (相当于额外重力)
	# 效果: 赛车在空中不会被水平推力推飞, 会更快回到地面, 给"悬浮滑翔"的手感
	# 不生效条件: 不在空喷 / 落地后(压地窗口和正常重力接管)
	if is_boosting and boost_type == "air" and _is_airborne and air_boost_downforce > 0.0:
		apply_central_force(Vector3(0.0, -air_boost_downforce, 0.0) * mass)

	# ============ 反打减速 ============
	# 漂移中反打 (steer_input 与 drift_dir 异号) → 沿水平速度反向施加减速力
	# 模拟"轮胎反向抓地"的真实物理: 方向猛拉到反方向时车身会被拽住一下
	# 数学: F = -v_horiz_normalized × drift_counter_decel × |steer_input| × mass
	# 条件: state==DRIFT, drift_dir!=0, steer 与 drift_dir 异号, |steer|≥阈值, 速度>1m/s 避免低速抖
	# 注: 不和引擎/刹车/喷射打架, 是单独的"抓地刹车"力, 想要的就是它能叠加在喷射推力上
	if drift_counter_decel_enabled and state == State.DRIFT and drift_dir != 0.0 and current_speed > 1.0:
		var steer_sign: float = signf(steer_input)
		if steer_sign != 0.0 and steer_sign != signf(drift_dir):
			var steer_mag: float = absf(steer_input)
			if steer_mag >= drift_counter_decel_min_steer:
				var brake_dir: Vector3 = -v_horiz.normalized()
				var brake_force: float = drift_counter_decel * steer_mag * mass
				apply_central_force(brake_dir * brake_force)


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

	# -------- 漂移打滑 (松开前进键时) --------
	# 目标 slip_target:
	#   · 非漂移  → 0 (完全抓地)
	#   · 漂移中  → 1 - clamp(throttle_input, 0, 1)
	#     → 满油门(1.0)时 slip_target=0; 完全松开(0)时 slip_target=1
	#     → 倒车(throttle<0)时 slip_target=1 (也算完全松开前进)
	# _drift_slip_factor 用 drift_slip_smooth 速度平滑插值到 slip_target, 避免瞬时跳变
	# 最终摩擦系数: k *= (1 - _drift_slip_factor × drift_slip_friction_cut)
	#   · drift_slip_friction_cut=1.0 时: 完全松油门 → k×0 → 前后/侧向摩擦归零 (纯惯性)
	#   · drift_slip_friction_cut=0.5 时: 完全松油门 → k×0.5 → 摩擦保留 50%
	if drift_slip_enabled and state == State.DRIFT:
		var slip_target: float = 1.0 - clampf(throttle_input, 0.0, 1.0)
		_drift_slip_factor = lerpf(_drift_slip_factor, slip_target, clampf(drift_slip_smooth * delta, 0.0, 1.0))
		var friction_mult: float = clampf(1.0 - _drift_slip_factor * drift_slip_friction_cut, 0.0, 1.0)
		long_k *= friction_mult
		lat_k *= friction_mult
	else:
		# 非漂移或关闭打滑: slip_factor 平滑回零, 下次入漂从抓地开始
		_drift_slip_factor = lerpf(_drift_slip_factor, 0.0, clampf(drift_slip_smooth * delta, 0.0, 1.0))

	# -------- 【惯性感增强】 --------
	# 削减漂移中"按速度方向"的摩擦, 让车在漂移中被甩出去后能保持原速度方向更久
	# 数学: inertia_mult = 1 - drift_inertia_boost × drift_intensity
	#   · 值 = 1 时(默认): 不变
	#   · 值 = 0 时: 漂移达到 intensity=1 时, long/lat 摩擦都归零 (纯惯性)
	# 与打滑机制叠加: 两者乘在一起, 任意一个机制把摩擦压到 0 就是 0
	if state == State.DRIFT and drift_inertia_boost > 0.0:
		var inertia_mult: float = clampf(1.0 - drift_inertia_boost * drift_intensity, 0.0, 1.0)
		long_k *= inertia_mult
		lat_k *= inertia_mult

	# 沿各自速度分量反方向施加冲量
	var long_impulse: Vector3 = -forward * v_long * long_k * delta
	var lat_impulse: Vector3  = -right   * v_lat  * lat_k  * delta
	apply_central_impulse((long_impulse + lat_impulse) * mass)

	# -------- 【向心力感】 --------
	# 漂移中主动施加一个把 linear_velocity 向 forward(视觉车头)方向拉的加速度
	# 数学: F_cp = mass × drift_centripetal_pull × drift_intensity × cp_time_k × (forward_xz - v_dir_xz) × speed
	#   · drift_centripetal_pull: 基础拉力强度(单位 m/s², 但实际乘了速度所以是"速度相关力")
	#   · drift_intensity: 漂移强度 0~1, 漂得越深拉力越强
	#   · cp_time_k: 从 drift_centripetal_curve 采样, X=drift_elapsed/drift_head_yaw_duration_ref 归一化
	#   · (forward - v_dir): 指向"车头希望速度去哪", 即"向心差向量", 沿这个方向施力
	#   · speed: 乘速度让高速弯拉力更大 (QQ飞车高速弯"吸"的感觉)
	# 效果: 速度方向会慢慢被拉向车头方向 → 漂移弧线更"粘", 向心感强
	# 使用已有的局部变量: v (水平惯性), total_speed (水平速度大小)
	if state == State.DRIFT and drift_centripetal_pull > 0.0 and drift_intensity > 0.01 and total_speed > 1.0:
		var v_dir_xz: Vector3 = v / total_speed   # v 已是 XZ 平面(y=0), 归一化
		var fwd_xz: Vector3 = forward
		fwd_xz.y = 0.0
		if fwd_xz.length() > 0.001:
			fwd_xz = fwd_xz.normalized()
		else:
			fwd_xz = v_dir_xz
		var cp_diff: Vector3 = fwd_xz - v_dir_xz
		# cp_diff 长度 0~2, 方向上"从当前速度指向车头方向"
		var cp_t_norm: float = clampf(drift_elapsed / maxf(drift_head_yaw_duration_ref, 0.1), 0.0, 1.0)
		var cp_time_k: float = _sample_curve_safe(drift_centripetal_curve, cp_t_norm, 1.0)
		var cp_force: Vector3 = cp_diff * drift_centripetal_pull * drift_intensity * cp_time_k * total_speed * mass
		apply_central_force(cp_force)

	# 空气阻力(与速度平方成正比, 沿惯性反向)
	if total_speed > 0.5 and friction_air_drag > 0.0:
		var air_force: Vector3 = -v.normalized() * friction_air_drag * total_speed * total_speed * mass
		apply_central_force(air_force)

	# 漂移额外能耗(整体沿惯性反向, 强度与 drift_intensity 成正比)
	# 松前(油门松开)时, 额外能耗按 drift_extra_decel_songqian_mult 插值降低
	#   _drift_slip_factor 0~1 表示"松前程度"(0=满油门, 1=完全松开)
	#   decel_mult = lerp(1.0, songqian_mult, _drift_slip_factor)
	# 例: songqian_mult=0.3 时, 满油门→1.0 倍能耗; 完全松前→0.3 倍能耗, 车滑得更远
	if drift_intensity > 0.01 and total_speed > 0.5:
		var decel_mult: float = lerpf(1.0, drift_extra_decel_songqian_mult, clampf(_drift_slip_factor, 0.0, 1.0))
		apply_central_force(-v.normalized() * drift_extra_decel * drift_intensity * decel_mult * mass)


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
	# ---- (已废弃) 压地窗口 ----
	# 这套机制和原生 _apply_ground_stick (plain_vy_zero_threshold + plain_downforce) 打架,
	# 在 _apply_ground_stick 把 v.y 已经管好的情况下, 又每帧 clamp 一次, 反而让 Y 速度
	# 长时间被压成 0, 物理引擎无法正常让车贴地下沉, 表现为"落地后悬浮半秒".
	# 已彻底禁用. _landing_stick_left 字段保留但不再驱动任何物理行为.
	# landing_stick_duration / landing_stick_min_fall_speed 参数也保留(避免旧 cfg 报错), 但无效.
	_landing_stick_left = 0.0

	# 【已废弃倒计时】_air_boost_armed 现在是"本次腾空空喷已触发"的去重标记
	# 由 _try_boost_w 在空中按 W 时置 true, 由 _maybe_trigger_air_boost 在落地时置 false
	# 不再需要 _air_boost_armed_left 倒计时让意图过期 (空喷立即触发, 没有"等落地"的等待期了)
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
			# 起飞瞬间清角速度: 防止空中翻滚 (配合下面"空中每帧清"双重保险)
			angular_velocity = Vector3.ZERO
			emit_signal("airborne_started")
		_air_time += delta
		# 空中每帧持续把角速度归零, 杜绝接触摩擦/碰撞累积的角动量在空中转车
		# (车身姿态由 car_mesh 控制, RigidBody 的旋转不影响视觉, 但会影响碰撞接触, 所以也清掉)
		angular_velocity = Vector3.ZERO
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

			# ---- 落地预输入回放 ----
			# 玩家在空中缓冲的 W/Q, 落地瞬间一次性消费. 执行顺序: Q 先 (尝试起漂), 再 W (兼容落地喷/窗口消费)
			# 【新规则】空喷已经在空中按 W 时立刻触发了, 这里 W 回放主要给"落地喷需要按 W 触发"的场景用
			#         _try_boost_w 内部会因为 _is_airborne=false 跳过空喷分支, 直接走落地喷/窗口消费/双喷
			if _pending_landing_q_left > 0.0 and state == State.NORMAL and not _require_release_q:
				print("[Car] 落地预输入回放 Q → 尝试起漂")
				if not _try_start_drift():
					_drift_input_grace_left = drift_input_grace_window
				_pending_landing_q_left = 0.0
			if _pending_landing_w_left > 0.0:
				print("[Car] 落地预输入回放 W → _try_boost_w (走落地喷/窗口路径)")
				_try_boost_w()
				_pending_landing_w_left = 0.0

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
	# 落地缓冲: Y 方向下落动量 + 角动量统一清理
	#
	# 【新规则】只要 landing_impact_absorb > 0 就直接强制归零 Y 速度 + 清角速度
	#   设计理由:
	#     · 用户反馈"落地还是一次弹跳" → 根因是保留的 15% 下落速度被接触约束反弹
	#     · 把 landing_impact_absorb 当成"开关"用最简单粗暴: >0 就完全吸收, =0 才走原物理
	#     · 同时清 angular_velocity, 防止空中累积的角动量在落地瞬间转出"翻滚"
	#   旧规则保留: landing_hard_stick = true 时也走相同路径(它原本就是"强制归零"语义)
	#
	# 数学:
	#   v.y = 0 (强制, 无下落动量 → 无反弹源)
	#   angular_velocity = Vector3.ZERO (无翻滚)
	#
	# 不会和原生 _apply_ground_stick 打架的原因:
	#   _apply_ground_stick 的 plain_vy_zero_threshold 是处理"v.y > 0 的弹起", 我们这里是"v.y < 0 的下落归零"
	#   两者方向相反, 各管各的, 不冲突 (这次和"压地窗口"那次不一样, 那次是同方向重复 clamp)
	var fall_speed: float = -linear_velocity.y   # 下落速度(正数 = 在向下)
	if landing_hard_stick or landing_impact_absorb > 0.0:
		var v: Vector3 = linear_velocity
		v.y = 0.0
		linear_velocity = v
		angular_velocity = Vector3.ZERO
		print("[Car] 落地: Y 速度归零 + 清角速度 (原下落速度 %.1f m/s, 下落动量已吸收, 杜绝弹跳)" % fall_speed)

	# 启动压地窗口: 已废弃 (与原生 _apply_ground_stick 打架, 导致悬浮)
	# 这段保留 print 兼容旧调试日志, 不再设置 _landing_stick_left
	# (原生防弹机制已经能处理弹跳, 不需要再叠一层)
	# 旧 cfg 里 landing_stick_duration / landing_stick_min_fall_speed 还在, 但不再驱动行为

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
	# 【新规则】空喷现在在空中按 W 时**立即**触发(_try_boost_w), 落地时不再"释放"空喷.
	# 这里只做清理工作: 把"本次腾空已用空喷"标记复位, 让下一次起飞可以再触发空喷.
	# 返回 false: 落地时不会再走 _start_boost("air") 路径, 所以"是否触发了空喷"始终是 false.
	if _air_boost_armed:
		print("[Car] 落地: 重置空喷标记 (本次腾空空喷已在空中触发, air_time=%.2f)" % air_time)
		_air_boost_armed = false
		_air_boost_armed_left = 0.0
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
	# 【倒车方向反转】真实赛车里, 倒车时"按左 = 车屁股往左移动 = 车头朝右转"
	# 和前进时"按左 = 车头朝左转"方向是反的. 玩家在倒车时会本能地按"想去的方向"
	# 判断: 玩家踩刹车键(throttle<0) + 车正在向后开(沿车头方向投影 < 0)
	# 数学: effective_steer = steer_input × (是否倒车 ? -1 : 1)
	#       这个 effective_steer 只用于"算 turn_rad", 其他依赖 steer_input 的判定
	#       (反打缩减/侧倾/起漂方向等)继续用原 steer_input, 因为那些是"按键意图"语义
	var fwd_xz: Vector3 = -car_mesh.global_transform.basis.z
	fwd_xz.y = 0.0
	var long_speed_now: float = linear_velocity.dot(fwd_xz.normalized()) if fwd_xz.length() > 0.001 else 0.0
	var is_reversing: bool = (throttle_input < -0.01) and (long_speed_now < -0.3)
	var effective_steer: float = -steer_input if is_reversing else steer_input
	# 【松前转向限制】松前期间车体打滑, 转向必须显著变钝, 否则玩家手指一动车头就甩飞
	# 应用顺序: 在所有其他 mult 计算完之后 × songqian_steer_mult
	if state == State.DRIFT and _is_in_songqian:
		turn_mult *= songqian_steer_mult
	var turn_rad: float = deg_to_rad(steering_deg) * effective_steer * turn_mult
	# 【空中禁止转向】起飞期间车身朝向锁定为起飞瞬间的方向
	# 转向需要轮胎抓地才合理, 空中凭空转车头不符合物理直觉, 也会破坏"落地延续漂移"的感觉
	# 落地瞬间恢复正常转向
	if _is_airborne:
		turn_rad = 0.0

	var new_basis: Basis = car_mesh.global_transform.basis.rotated(
		car_mesh.global_transform.basis.y, turn_rad
	)
	car_mesh.global_transform.basis = car_mesh.global_transform.basis.slerp(
		new_basis, turn_speed * delta
	)
	car_mesh.global_transform = car_mesh.global_transform.orthonormalized()

	# ============ 松前 (DRIFT 子状态) yaw 偏移 + 状态维护 + 进入小加速 ============
	# 概念: 漂移中松开前进键(throttle 低), 车头会朝 drift_dir 方向慢慢偏(软性叠加)
	#       松前期间 _songqian_yaw_offset 朝 ±songqian_yaw_limit_deg 插值, 离开松前回零
	#       注: 这个 limit 只限制"额外叠加层", 不限制"基础转向 + 叠加"的总偏角
	#
	# 状态变量维护:
	#   _is_in_songqian: 粘性锁定. 进入=松油门, 退出=踩回油门(触发松前漂移) 或 _end_drift
	#   _songqian_kick_given: 进入松前时给一次性"小加速"冲量, 一次有效, 离开松前后可再次触发
	#
	# 数学:
	#   target_offset = is_songqian ? songqian_yaw_limit_deg × drift_dir : 0
	#   _songqian_yaw_offset 用 songqian_yaw_speed_deg/秒 速率向 target 推进
	#   每帧把 car_mesh.basis 额外绕 Y 旋转 (delta_offset_rad)
	if state == State.DRIFT and songqian_drift_enabled and not _is_airborne and drift_dir != 0.0:
		var was_in_songqian: bool = _is_in_songqian
		# ============ 松前状态机 (粘性锁定版, 用户最终规则) ============
		# 旧规则 (实时): _is_in_songqian = throttle_input < 0.05 (跟随油门实时切换)
		# 新规则 (粘性): 一旦进入松前就**锁定**, 退出方式只有两个:
		#   a) 玩家踩回前进键(throttle_input >= 0.05) → 自动触发**松前漂移**(_trigger_songqian_drift)
		#      = 给巨大冲量 + 爆发期 + 车头回正, 状态切回普通漂移
		#   b) 漂移本身结束(_end_drift 调用) → 由 _end_drift 清 _is_in_songqian
		#
		# 状态机:
		#   未在松前 + throttle 低 → 进入松前(_is_in_songqian=true), 给小加速冲量
		#   在松前   + throttle 高 → 自动松前漂移(由 _trigger_songqian_drift 清 _is_in_songqian)
		#   在松前   + throttle 低 → 维持松前 (车头继续偏, 摩擦低)
		if not _is_in_songqian and throttle_input < 0.05:
			# 进入松前: 给一次"小加速"沿当前运动方向(车体保留打滑势能)
			_is_in_songqian = true
			if not _songqian_kick_given:
				var v_xz: Vector3 = linear_velocity
				v_xz.y = 0.0
				if v_xz.length() > 1.0 and songqian_enter_kick_impulse > 0.0:
					apply_central_impulse(v_xz.normalized() * songqian_enter_kick_impulse * mass)
					print("[Car] 松前小加速! 冲量=%.1f 沿 %s" % [songqian_enter_kick_impulse, str(v_xz.normalized())])
				_songqian_kick_given = true
		elif _is_in_songqian and throttle_input >= 0.05:
			# 在松前期间踩回前进键 → 自动触发松前漂移!
			# 这里不直接清 _is_in_songqian, 而是由 _trigger_songqian_drift 内部清
			# (它会发 songqian_state_changed(false) 信号 + 重置 yaw + 给冲量)
			print("[Car] 松前期间踩回前进键 → 自动触发松前漂移!")
			_trigger_songqian_drift()
		# 状态变化通知 HUD (用于 drift_label 切换显示"松前"/"漂移")
		# 注: 进入松前时这里发, 退出由 _trigger_songqian_drift 或 _end_drift 内部发
		if _is_in_songqian and not was_in_songqian:
			emit_signal("songqian_state_changed", true)

		# Yaw 偏移更新 (恢复到旧的软性叠加实现)
		# 旧实现: _songqian_yaw_offset 是"额外叠加在 car_mesh.basis 上的旋转量",
		#        松前期间朝 drift_dir 方向插值到 songqian_yaw_limit_deg, 离开松前回零.
		# 已知不足: 这个 limit 只限制"额外叠加层", 不限制"基础转向 + 叠加"的总偏角,
        #          所以视觉上车头能转过 90° (和基础转向叠加).
        #          这个 90° 上限的真正语义之后单独再讨论怎么实现, 先恢复正常漂移可玩性.
		var target_offset_deg: float = (songqian_yaw_limit_deg * drift_dir) if _is_in_songqian else 0.0
		var step_deg: float = songqian_yaw_speed_deg * delta
		var prev_offset: float = _songqian_yaw_offset
		_songqian_yaw_offset = move_toward(_songqian_yaw_offset, target_offset_deg, step_deg)
		# 每帧应用增量到 car_mesh basis (绕 Y 轴)
		var delta_offset_rad: float = deg_to_rad(_songqian_yaw_offset - prev_offset)
		if absf(delta_offset_rad) > 0.0001:
			car_mesh.global_transform.basis = car_mesh.global_transform.basis.rotated(
				car_mesh.global_transform.basis.y, delta_offset_rad
			)
			car_mesh.global_transform = car_mesh.global_transform.orthonormalized()
	else:
		# 非漂移状态: 清松前标志 + 平滑回零(下次入漂从 0 开始)
		if _is_in_songqian:
			# 之前还在松前 → 现在退出, 通知 HUD 关掉松前显示
			_is_in_songqian = false
			emit_signal("songqian_state_changed", false)
		_songqian_kick_given = false
		if absf(_songqian_yaw_offset) > 0.01:
			_songqian_yaw_offset = move_toward(_songqian_yaw_offset, 0.0, songqian_yaw_speed_deg * delta)

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
	# 【关键】只在地面时对齐, 空中保持起飞时的车身姿态
	# 旧 bug: 空中 ground_ray 也可能 is_colliding (默认射 4 米向下),
	#         飞跃陡坡时下方法线倾斜, 导致车头朝下/朝上, 不符合"飞行中保持水平"的直觉
	if not _is_airborne and ground_ray.is_colliding():
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
# ============================================================
#  松前漂移触发: DRIFT 状态 + 松前(松油门) + 玩家踩回前进键 → 自动触发
#  (旧规则是"按 Q + 前进 + 方向"三键同按, 用户最终修订为"踩回前进键"自动触发)
#  效果: 不退漂, 给沿车头方向一次性冲量 + 爆发期重置, 让赛车从松前打滑中
#        重新点燃漂移势能. 比退漂再起漂更连贯, 是高级玩家的"再加速"操作.
#  调用方:
#    · _update_visuals: 检测到 _is_in_songqian + throttle_input >= 0.05 时调用
# ============================================================
func _trigger_songqian_drift() -> void:
	if state != State.DRIFT:
		return
	# 1) 沿车头方向施加一次性大冲量
	var fwd_kick: Vector3 = -car_mesh.global_transform.basis.z
	fwd_kick.y = 0.0
	if fwd_kick.length() > 0.001:
		fwd_kick = fwd_kick.normalized()
		apply_central_impulse(fwd_kick * songqian_drift_kick_impulse * mass)
	# 2) 把退漂爆发期(_drift_exit_boost_left)重置为松前漂移专用时长
	#    虽然变量名叫"exit boost", 但它在 _apply_engine_and_brake 里也用作"近期入漂/退漂的推力增益"
	_drift_exit_boost_left = songqian_drift_boost_duration
	# 3) 重置松前 yaw 偏移 + 状态 (车头回正, 重新点燃漂移势能)
	_songqian_yaw_offset = 0.0
	if _is_in_songqian:
		_is_in_songqian = false
		# 通知 HUD: 松前漂移触发瞬间立刻关掉"松前"提示, 显示回"漂移"
		emit_signal("songqian_state_changed", false)
	_songqian_kick_given = false
	print("[Car] 松前漂移触发! 巨大冲量=%.1f 爆发=%.2fs (drift 不中断, 朝车头入弯方向冲)"
		% [songqian_drift_kick_impulse, songqian_drift_boost_duration])


# ============================================================
#  计算"车头当前方向" vs "起漂时车头方向" 的有符号偏角 (度)
#  正值 = 朝 drift_dir 方向偏 (符合直觉的"漂移甩头方向")
#  负值 = 朝相反方向偏 (反打/异常情况)
# ============================================================
func _calc_songqian_yaw_deg() -> float:
	if car_mesh == null:
		return 0.0
	var fwd_now: Vector3 = -car_mesh.global_transform.basis.z
	fwd_now.y = 0.0
	var start_fwd: Vector3 = _drift_start_forward
	start_fwd.y = 0.0
	if fwd_now.length() < 0.001 or start_fwd.length() < 0.001:
		return 0.0
	fwd_now = fwd_now.normalized()
	start_fwd = start_fwd.normalized()
	var dot_v: float = clampf(fwd_now.dot(start_fwd), -1.0, 1.0)
	var cross_y: float = start_fwd.cross(fwd_now).y
	# raw_angle: cross.y > 0 时车头在 start 的左侧 (Godot 是 +Y 朝上, 左手系)
	var raw_angle_deg: float = rad_to_deg(acos(dot_v)) * signf(cross_y)
	# 乘 drift_dir 把"朝入弯方向偏"映射为正数
	# drift_dir = signf(steer_input), 入漂时按左 → drift_dir=正 → 此乘法让左偏=正
	return raw_angle_deg * drift_dir


# ============================================================
#  三喷 (松前后退喷) 触发: 松前状态 + 车头偏角足够 + 同帧 Q + W
#  效果: 沿车头反方向给一次性大冲量 + 一段后退推力, 然后允许蓄双喷接力
#  数学:
#    瞬时冲量 = -fwd × songqian_back_kick_impulse × mass
#    持续推力 = 由 _start_boost("songqian_back", power, time) 在 _apply_engine_and_brake 反向施加
#    完成后: _can_charge_double = true, 玩家持续按 Q 蓄能即可接力双喷 = 三喷完成
# ============================================================
func _trigger_songqian_back_boost(yaw_deg: float) -> void:
	if state != State.DRIFT:
		return
	if car_mesh == null:
		return
	# 1) 沿车头反方向施加一次性瞬时冲量 ("嘭"一下推走)
	var back_dir: Vector3 = car_mesh.global_transform.basis.z   # +Z 是车尾方向
	back_dir.y = 0.0
	if back_dir.length() > 0.001:
		back_dir = back_dir.normalized()
		apply_central_impulse(back_dir * songqian_back_kick_impulse * mass)
	# 2) 启动持续后退推力 boost (走标准 _start_boost 路径, 沾叠喷接力机制的光)
	_start_boost("songqian_back", songqian_back_boost_power, songqian_back_boost_time)
	# 3) 关键: 允许蓄双喷, 让玩家用双喷指法接出双喷 = 三喷
	_can_charge_double = true
	# 4) 退漂爆发期借用一下, 让接力双喷推力起步更猛
	_drift_exit_boost_left = drift_exit_boost_duration
	# 5) 重置松前 yaw 偏移记录 (可选, 让车头视觉回正)
	_songqian_yaw_offset = 0.0
	# 6) 通知 HUD 弹"三喷" 字
	emit_signal("songqian_back_boost_triggered", yaw_deg)
	print("[Car] 三喷触发! 偏角=%.1f° 冲量=%.1f 持续推力=%.1f×%.2fs (允许蓄双喷接力)"
		% [yaw_deg, songqian_back_kick_impulse, songqian_back_boost_power, songqian_back_boost_time])


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
	# 记录起漂时车头方向, 供松前 yaw 偏移上限做参考
	_drift_start_forward = -car_mesh.global_transform.basis.z
	_drift_start_forward.y = 0.0
	if _drift_start_forward.length() > 0.001:
		_drift_start_forward = _drift_start_forward.normalized()
	# 重置松前累计 yaw 偏移
	_songqian_yaw_offset = 0.0
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
	# 松前下任何方式断漂(自动/手动/低速/撞墙)都自动算 failed: 不开小喷窗口
	# 因为"松前断漂不算是正常的漂移断漂"
	if _is_in_songqian and not failed:
		failed = true
		print("[Car] 松前下断漂 → 自动转为 failed (不开小喷窗口)")
	# 【关键】松前是粘性锁定状态, 漂移结束时必须显式清掉, 否则下次入漂会残留
	# 同时通知 HUD 关掉"松前"提示
	if _is_in_songqian:
		_is_in_songqian = false
		_songqian_kick_given = false
		emit_signal("songqian_state_changed", false)
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
	# 【空中漂移延续】起飞前在漂移状态 → 空中期间:
	#   · 不累计 drift_elapsed (否则空中飞得久会自己超时断漂)
	#   · 不做自动退漂 / 低速断漂判定 (空中车身姿态算不准, 也没有"地面抓地"这回事)
	#   · 撞墙断漂仍然走 _integrate_forces 的物理路径, 不影响
	# 落地后 drift_elapsed 从冻结点继续累计, 自动退漂/低速断漂恢复判定
	if _is_airborne:
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
	# 0) 空中按 W: 【新规则】离地瞬间按 W 立刻触发空喷推力, 不再等落地
	#    旧逻辑: 缓存意图 → 落地瞬间释放. 玩家反馈"在空中按 W 没感觉, 落地才爆发, 操作脱节"
	#    新逻辑: 空中按 W 立即 _start_boost("air", ...) 给推力, 让"飞起来再加速"成为可感知的操作
	#    数学/状态:
	#      _air_boost_armed = true (作为"本次腾空已用过空喷"的去重标记, 防止:
	#        a) 同一次跳跃里多次按 W 重复空喷
	#        b) 落地时 _maybe_trigger_air_boost 再次触发 (改成检测此标记就跳过)
	#        c) 落地预输入回放 _pending_landing_w_left 也跳过空喷只走落地喷/窗口路径)
	#      触发条件: air_boost_enabled + 离地 + 当前腾空时间 ≥ air_boost_min_air_time
	#      不满足 min_air_time 的: 不空喷, 也不缓存(因为没法及时反馈), 走原本的"空中无效 W"
	if air_boost_enabled and _is_airborne and not _air_boost_armed:
		if _air_time >= air_boost_min_air_time:
			_air_boost_armed = true                  # 标记"本次腾空空喷资格已消费"
			_air_boost_armed_left = 0.0              # 不再用倒计时, 留 0 兼容旧字段
			_start_boost("air", air_boost_power, air_boost_time)  # 立即给推进力
			emit_signal("air_boost_triggered", _air_time)         # 复用同一信号 → HUD 弹"空喷 X.Xs飞跃"
			if air_boost_shake > 0.0:
				emit_signal("camera_shake_requested", air_boost_shake, 0.25)
			print("[Car] 空喷立即触发 (空中按 W)! air_time=%.2f power=%.1f" % [_air_time, air_boost_power])
			# 配置成"覆盖窗口逻辑"时直接返回, 不再尝试漂移/双喷/窗口路径
			if air_boost_overrides_window:
				return
		else:
			# 腾空时间还不够, 不空喷也不缓存 (空中无 W 窗口, 没意义)
			print("[Car] 空中按 W 但腾空不足 (%.2fs < %.2fs), 忽略" % [_air_time, air_boost_min_air_time])
			emit_signal("boost_triggered", "insufficient")
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
	#    例外: 松前状态下按 W 不触发任何小喷, 因为松前断漂不算正常退漂
	#         玩家想喷射必须先踩回油门 → 退出松前 → 按 W 退漂走正常窗口
	print("[Car] 按 W! state=", state, " angle=%.1f" % drift_accum_angle_deg, " win_left=%.2f" % boost_window_left, " win_lvl=", boost_window_level)
	if state == State.DRIFT:
		if _is_in_songqian:
			print("[Car]   松前状态下 W 无效 (松前不能小喷)")
			emit_signal("boost_triggered", "insufficient")
			return
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
		# 退漂小喷: 这是唯一允许蓄双喷的 mini 来源
		# 置 true 前设好, _start_boost 会被调用, 里面有"其他路径置 false"的兜底, 所以这里要在调用后再置 true
		_start_boost("mini", mini_boost_power, mini_boost_time)
		_can_charge_double = true
		print("[Car] 小喷释放! (退漂小喷, 允许蓄双喷)")
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

	# 蓄能条件 (所有条件必须同时满足):
	#   · is_boosting == true  (必须在喷射中)
	#   · _can_charge_double == true  (**核心**: 只有"主动做出的 W 段"允许蓄, 见 _start_boost 的资格管理)
	#     资格来源:
	#       退漂小喷  → true  (_consume_boost_window 置)
	#       CW 第二段 W(氮气延续 mini) → true  (_start_boost 氮气延续分支置)
	#       其他全部 → false
	#   · state == NORMAL  (双喷期间禁止再蓄, 防止无限双喷; 漂移中按 Q 是退漂不蓄能)
	#   · 当前叠喷链未完成 CWW/WCW (完成终结后必须等新链, 防止 CWWWW 之类)
	#   · 撞墙后入漂 CD / 必须松开 Q 锁都不在 (蓄能阶段视为"准漂移", 同样受限)
	var cur_seq_str: String = ""
	for ch in _stack_chain_seq:
		cur_seq_str += ch
	var chain_completed: bool = (cur_seq_str == "cww" or cur_seq_str == "wcw")
	var drift_locked: bool = _drift_lockout_left > 0.0 or _require_release_q
	var allow_charge: bool = (
		is_boosting
		and _can_charge_double
		and state == State.NORMAL
		and not chain_completed
		and not drift_locked
	)
	if not allow_charge:
		# 离开蓄能条件时清零进度
		if _double_charge_t > 0.0:
			_double_charge_t = 0.0
			emit_signal("double_charge_progress", 0.0)
			_set_double_charge_fx(false)
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
# ============================================================
#  Stack Boost 接力体系
# ============================================================
# 字母约定:
#   c = nitro (氮气, 唯一的 C 系)
#   w = mini / double / air / landing (任何 W 系喷射, 都可以加入叠喷链)
#
# 合法叠喷链 (只有这三种, 严格按 QQ 飞车手感):
#   "cw"   → 2 段, 突破 1 次. 已完成叠喷, 弹字 "CW", 但允许追加成 cww
#   "cww"  → 3 段, 突破 2 次. 终结型, 弹字 "CWW", 之后必须新开链
#   "wcw"  → 3 段, 突破 1 次. 终结型, 弹字 "WCW", 之后必须新开链
#
# 其他过渡前缀:
#   "w"    → 单段, 不算叠喷, 不弹字
#   "wc"   → 2 段过渡, 不算"已完成的叠喷", 不弹字, 但允许追加成 wcw
#   其他   → 全部新开链
#
# 接力判定:
#   · 当前还在喷 → 用当前 boost_type 作为前一段 (无缝接力)
#   · 当前没在喷 但 上一段结束在 stack_link_window 秒内 → 仍算接力
#   · 否则 → 新开链
#
# 突破极速:
#   · effective_top *= stack_breakthrough_top_mult ^ _stack_breakthrough_count
#   · 仅在 _stack_current_breakthrough = true 的段才享受 (即"已突破"的那一段)
#   · CW 的 W 段: breakthrough = 1
#   · CWW 的最后 W 段: breakthrough = 2
#   · WCW 的最后 W 段: breakthrough = 1
#
# 推力衰减:
#   · 越靠后的段推力越低, 用 stack_power_decay[chain_index] 取系数
#   · 例 stack_power_decay = [1.0, 0.85, 0.72, 0.6]: 第 0 段 100%, 第 1 段 85%...
# ============================================================
func _check_and_apply_stack_boost(new_type: String) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0

	# === 1. 计算 letter (本段在叠喷序列里的字母) ===
	# c = nitro; w = 其他所有 (mini/double/air/landing)
	# 即: 空喷和落地喷也作为 w 加入叠喷链, 这样 "漂移退漂小喷 → 落地喷" 也算合法的 ww 续接
	var letter: String = "c" if new_type == "nitro" else "w"

	# === 2. 接力判定 ===
	# prev_type: 串接的前一段类型
	#   · 还在喷 → 用 boost_type (无缝接力, 例如氮气末段按 W)
	#   · 不在喷 → 用记录的 _last_boost_type (前一段已结束)
	var prev_type: String = boost_type if is_boosting else _last_boost_type
	var time_since_last: float = now - _last_boost_end_time
	# time_linked: 是否在接力窗口内
	#   · 还在喷 → 永远算接力
	#   · 不在喷 → 看距离上一段结束的时间是否 <= stack_link_window
	var time_linked: bool = prev_type != "" and (is_boosting or time_since_last <= stack_link_window)

	# === 3. 当前序列字符串 (用于状态机判断) ===
	var cur_seq: String = ""
	for ch in _stack_chain_seq:
		cur_seq += ch

	# === 4. 合法续接白名单 ===
	# 哪些 (cur_seq + letter) 是允许"接在原链后面"的:
	#   ""    + "c" → "c"     起步 (任何字母都允许新建链)
	#   ""    + "w" → "w"
	#   "c"   + "w" → "cw"    CW 已完成 (2 段叠喷, 突破=1)
	#   "cw"  + "w" → "cww"   CWW 完成 (终结, 突破=2)
	#   "w"   + "c" → "wc"    WC 过渡 (不算完成, 仅前缀)
	#   "wc"  + "w" → "wcw"   WCW 完成 (终结, 突破=1)
	# 其他全部不合法 → 新开链:
	#   "cww" + 任何 (终结后必须新链)
	#   "wcw" + 任何 (终结后必须新链)
	#   "c"   + "c" (cc 不合法)
	#   "cw"  + "c" (cwc 不合法)
	#   "w"   + "w" (ww 不合法 - 不算叠喷, 但仍执行后续 boost, 只是新链开始)
	#   "wc"  + "c" (wcc 不合法)
	#   "wcw" / "cww" 后追加任何 (已终结)
	var next_seq: String = cur_seq + letter
	var legal_extension: bool = false
	if time_linked:
		match next_seq:
			"cw", "cww", "wc", "wcw":
				legal_extension = true

	# === 5. 不合法续接 → 新开链 ===
	if not legal_extension:
		_stack_chain_index = 0
		_stack_breakthrough_count = 0
		_stack_current_breakthrough = false
		_stack_chain_seq = [letter] as Array[String]
		print("[Stack] 新链开始: ", new_type, " seq=", _stack_chain_seq)
		return

	# === 6. 合法续接 → 链 +1 ===
	_stack_chain_index += 1
	_stack_chain_seq.append(letter)

	# === 7. 突破计数表 (按"完成型/中间型"分别配置) ===
	# 这是叠喷数学核心, 改动这里务必对照下表逐行算:
	#
	#   next_seq | 突破次数 | 是否本段突破 | 弹字           | 说明
	#   ---------|---------|------------|---------------|-------------
	#   cw       | 1       | 是         | "CW"           | C 后接 W, 完成 CW
	#   cww      | 2       | 是         | "CWW"          | 已 CW 后再加 W, 终结
	#   wc       | 0       | 否         | (不弹)         | W 后接 C, 仅前缀, 还没完成 WCW
	#   wcw      | 1       | 是         | "WCW"          | 已 WC 后再加 W, 终结
	var should_set_breakthrough: bool = false
	match next_seq:
		"cw":
			# CW 完成: 突破 1 次 (氮气推到顶后接 W → 极速 +1 档)
			_stack_breakthrough_count = 1
			should_set_breakthrough = true
		"cww":
			# CWW 完成: 突破 2 次 (CW 之后再加一段 W, 累计极速 +2 档)
			_stack_breakthrough_count = 2
			should_set_breakthrough = true
		"wc":
			# WC 过渡: 不增加突破 (玩家刚把氮气接上 W, 还没完成 WCW)
			should_set_breakthrough = false
		"wcw":
			# WCW 完成: 突破 1 次 (W → C → W 三段, 最后一段 W 享受极速突破)
			_stack_breakthrough_count = 1
			should_set_breakthrough = true

	# 限制最大突破次数 (防止异常配置导致极速无限叠)
	if _stack_breakthrough_count > stack_max_breakthrough:
		_stack_breakthrough_count = stack_max_breakthrough
	_stack_current_breakthrough = should_set_breakthrough

	# === 8. 弹字提示 (HUD 自己过滤哪些 combo_name 真的弹) ===
	# combo_name = 序列字母大写, 例如 "cw" → "CW", "wcw" → "WCW"
	var combo_name: String = next_seq.to_upper()
	emit_signal("combo_triggered", combo_name, _stack_breakthrough_count)

	print("[Stack] 接力 %s->%s seq=%s 突破=%d %s" % [
		prev_type, new_type, next_seq, _stack_breakthrough_count,
		"(本段享受突破)" if should_set_breakthrough else "(本段不享受突破)"
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
	# ---- 双喷蓄能资格管理 ----
	# 规则: 只有"玩家主动做出的有意义 W 操作"允许蓄双喷:
	#   ✅ 退漂小喷(boost_window 的 mini 释放)           → _consume_boost_window 里置 true
	#   ✅ 氮气末段按 W 的 mini 延续段(CW 的第二段 W)    → 下面的氮气延续分支里置 true
	#   ❌ 空喷 air           (被动, 空中按 W 落地触发)
	#   ❌ 落地喷 landing     (被动, 落地窗口按 W)
	#   ❌ 氮气 nitro         (自身, 不能自己蓄自己)
	#   ❌ 双喷 double        (自身, 防止连续无限蓄)
	# 默认清零, 进入各路径后再按需置 true
	if type_name == "air" or type_name == "landing" or type_name == "nitro" or type_name == "double":
		_can_charge_double = false

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
		# ★ 氮气延续出 mini 段(CW 的第二段 W) → 允许继续蓄第三段 double (形成 CWW)
		# 氮气延续出 double 段本身就是最终段, 蓄能无意义, 不重新置 true (默认已在上面清零)
		if type_name == "mini":
			_can_charge_double = true
			print("[Boost] 氮气延续出 mini: 允许蓄第三段双喷 (CW → CWW 路径)")
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
			# ============================================================
			#  真实反弹物理 (基于 撞击点 + 撞击速度 + 撞击角度)
			# ============================================================
			# 1) 收集数据
			# get_contact_local_position 返回接触点相对刚体局部坐标
			# 转世界坐标需要乘上刚体 transform
			var local_contact: Vector3 = state_phys.get_contact_local_position(i)
			var contact_pos: Vector3 = state_phys.transform * local_contact
			var v: Vector3 = state_phys.linear_velocity
			var into_wall: float = -v.dot(n)  # 朝墙冲的速率(正值=朝墙冲)
			if into_wall <= 0.5:
				continue  # 速度太小不触发, 跳过
			
			# 2) 速度分解: 法线分量 + 切线分量
			#    v_normal = (v · n) × n  (沿法线的投影分量, 朝向墙)
			#    v_tangent = v - v_normal  (沿墙面的切向)
			var v_normal: Vector3 = n * v.dot(n)
			var v_tangent: Vector3 = v - v_normal
			
			# 3) 撞击角度: 车头与墙面切平面的夹角
			#    撞击角=车头方向与墙面法线之间的偏移
			#    n.dot(car_forward) > 0 → 车头朝墙(撞墙) ; <0 → 车尾朝墙
			#    incidence_dot ∈ [0, 1]: 0=擦墙(平行), 1=正撞(垂直)
			var fwd_for_angle: Vector3 = car_forward
			fwd_for_angle.y = 0.0
			if fwd_for_angle.length() > 0.001:
				fwd_for_angle = fwd_for_angle.normalized()
			var incidence_dot: float = absf(fwd_for_angle.dot(-n))   # |cos(angle)|, 1=正面 0=平行
			var incidence_angle_rad: float = acos(clampf(incidence_dot, 0.0, 1.0))
			var incidence_angle_deg: float = rad_to_deg(incidence_angle_rad)
			# 与"擦墙临界"对比: 入射角 < grazing → 擦墙(切向几乎全保留, 法线弱反弹)
			#                  入射角 > grazing → 真实弹回
			# 注: 这里 "入射角" 我们定义成"远离擦墙的角度" — 0=正面撞墙, 90=平行墙
			# 因为 incidence_dot=1 是正面撞, 对应 acos=0 角度. 所以 90-incidence_angle_deg = 与切平面夹角
			# 用 "面对墙面" 的角度更直观: face_angle = 90 - incidence_angle_deg (0=擦, 90=正面)
			var face_angle_deg: float = 90.0 - incidence_angle_deg
			var is_grazing: bool = face_angle_deg < wall_grazing_angle_deg
			
			# 4) 反弹速度计算:
			#    new_v = v_tangent × tangent_keep - v_normal × normal_factor
			#    切向保留: 擦墙时几乎全保留(0.9~0.95), 正面撞时切向小本来就少
			#    法线反弹: -v_normal × normal_factor (反方向 = 弹回墙外)
			var tangent_keep: float = wall_reflect_tangent_keep
			if not is_grazing:
				# 非擦墙(正撞或大角度): 切向也损失一点(墙摩擦)
				tangent_keep *= 0.85
			var new_v: Vector3 = v_tangent * tangent_keep + n * (into_wall * wall_reflect_normal_factor)
			# 沿法线方向额外推开一点点防止贴墙
			new_v += n * slope_wall_push_back
			
			# 5) 弹墙推力 (尾/侧撞), 保留原逻辑作为"快速擦墙加速"奖励
			#    判定: 撞击点位于车后或侧面 (用法线投影)
			if wall_bounce_boost_enabled:
				var rear_factor: float = n.dot(car_forward)   # 越大说明墙在车后(尾撞)
				var side_factor: float = absf(n.dot(car_right))   # 越大说明侧撞
				var is_rear_or_side: bool = rear_factor > wall_bounce_rear_threshold or side_factor > wall_bounce_side_threshold
				if is_rear_or_side and into_wall > wall_bounce_min_into_speed:
					new_v += car_forward * wall_bounce_forward_speed
					emit_signal("boost_triggered", "wall_bounce")
					print("[Car] 弹墙推力! rear=%.2f side=%.2f face_angle=%.0f° boost=%.1f"
						% [rear_factor, side_factor, face_angle_deg, wall_bounce_forward_speed])
			
			state_phys.linear_velocity = new_v
			absorbed = true
			
			# 6) 撞墙特效: 玻璃渣 (在接触点位置一次性播放)
			if into_wall >= glass_shatter_min_speed and glass_shatter_fx_scene:
				_spawn_glass_shatter(contact_pos, n, into_wall)
			
			# 7) 漂移中撞墙 → 立即失败断漂: 本次不给小喷, 并进入入漂冷却
			if state == State.DRIFT:
				_end_drift(false, false, true)
				if wall_drift_lockout_time > 0.0:
					_drift_lockout_left = wall_drift_lockout_time
				_drift_input_grace_left = 0.0
				_require_release_q = true
				print("[Car] 撞墙断漂! face_angle=%.0f° into=%.1fm/s CD=%.2fs"
					% [face_angle_deg, into_wall, wall_drift_lockout_time])
			# 8) 蓄能阶段视为"准漂移", 撞墙也要打断
			if _double_charge_t > 0.0 or _double_armed:
				_double_charge_t = 0.0
				_double_armed = false
				_double_armed_left = 0.0
				emit_signal("double_charge_progress", 0.0)
				emit_signal("double_charge_lost")
				_set_double_charge_fx(false)
				print("[Car] 撞墙打断双喷蓄能/资格")
			# 9) 震屏: 强度按撞击速度缩放
			if slope_wall_shake > 0.0:
				var shake_amp: float = slope_wall_shake * clampf(into_wall / 15.0, 0.3, 2.0)
				emit_signal("camera_shake_requested", shake_amp, 0.25)


# 玻璃渣特效生成: 在世界坐标 contact_pos 实例化, 由特效自己 queue_free
# normal: 墙面法线(玻璃渣朝这个方向炸开); impact_speed: 撞击速度(粒子量随之缩放)
func _spawn_glass_shatter(contact_pos: Vector3, normal: Vector3, impact_speed: float) -> void:
	if glass_shatter_fx_scene == null:
		return
	var fx: Node3D = glass_shatter_fx_scene.instantiate()
	# 挂到 current_scene (而不是 car), 这样车开走特效不会跟着移动
	get_tree().current_scene.add_child(fx)
	fx.global_position = contact_pos
	# 调用特效自己的配置接口
	if fx.has_method("configure_by_impact"):
		fx.configure_by_impact(impact_speed, normal)
	print("[Car] 玻璃渣特效 @ %s 速度=%.1fm/s" % [str(contact_pos), impact_speed])


# ============================================================
#  HUD 信号
# ============================================================
func _emit_hud_signals() -> void:
	var kmh: float = linear_velocity.length() * 3.6
	emit_signal("speed_changed", kmh)
	emit_signal("charge_changed", charge, charge_nitro_full)
