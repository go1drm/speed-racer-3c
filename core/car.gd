extends RigidBody3D
## ============================================================
##  QQ飞车式车辆控制器 v3 —— 炸弹猫精调版

const DriftSystemScript := preload("res://core/DriftSystem.gd")
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

# ---------------- 双人模式 ----------------
## 玩家 ID: 0=1P(键盘), 1=2P(手柄). 由 CoopMode 设置
var player_id: int = 0

## 获取当前玩家对应的 action 名 (双人模式下 2P 用 p2_ 前缀)
func _act(base_action: String) -> String:
	if player_id == 0:
		return base_action
	return "p2_" + base_action

# ---------------- 基础移动 ----------------
@export_group("Movement")
@export var max_speed: float = 45.0              ## 巡航极速(无喷射时能达到的最高速度, m/s)
@export var top_speed_boosted: float = 70.0      ## 喷射极速(小喷/双喷/氮气期间的最高速度, m/s)
@export var air_top_speed: float = 55.0          ## 空中极速(空中喷射时的最高速度, m/s). 空中叠喷可突破此限制
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
## 漂移额外能耗曲线: X=漂移时间归一化(0~drift_head_yaw_duration_ref), Y=能耗倍率
@export var drift_extra_decel_curve: Curve
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
## 【松前漂移 CD】两次松前漂移之间的最小冷却时间(秒) —— 全局生效, 不因起漂重置
##   背景: 玩家发现"松油门→松前→踩前进键→松前漂移→再松→再踩"可以反复触发,
##         每次都吃巨大冲量, 让车一直加速, 体验上是个 bug.
##   规则: 触发松前漂移后开始计时, CD 期内再次"松前+踩油门"只把状态切回普通漂移、
##         车头回正, **不给冲量、不重置爆发期**(玩家可以正常退出松前继续游戏, 但拿不到爆发).
##   计时: 触发瞬间 _songqian_drift_cd_left = songqian_drift_cooldown,
##         每物理帧 -= delta. **不**在 _start_drift 起漂时清零, CD 是全局冷却,
##         不管玩家是连续漂移还是中间退出, 两次松前漂移之间都至少间隔此秒数.
##   设 0 = 无 CD (回到旧行为, 可无限触发); 推荐 0.6~1.2 秒.
@export_range(0.0, 5.0, 0.05) var songqian_drift_cooldown: float = 0.8
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
@export_range(5.0, 200.0, 1.0) var drift_inertia_speed_ref: float = 50.0 ## 惯性感曲线速度参考值(m/s): 曲线 X=1 对应此速度. 低于此速度惯性强, 高于减弱
@export var drift_inertia_speed_curve: Curve                              ## 惯性感随速度的缩放曲线: X=speed/speed_ref(0~1), Y=惯性感倍率(0~1). 低速Y高=外移多, 高速Y低=不飞出
@export_range(0.0, 50.0, 0.5) var drift_centripetal_pull: float = 0.0     ## 漂移向心拉力系数(车头把速度方向带过去)
## 向心拉力与速度的耦合曲线: X=0→低速弯, X=1→drift_head_yaw_duration_ref 秒时的速度参考
@export var drift_centripetal_curve: Curve                                ## 可选, 留空则线性

# ---------------- QQ飞车漂移系统 (新) ----------------
@export_group("QQ Speed Drift System")
## QQ飞车漂移系统开关: true=使用QQ飞车力学模型, false=使用旧系统
@export var qqspeed_drift_enabled: bool = false
## 漂移视觉效果开关 (车身侧倾、yaw偏移)
@export var qqspeed_drift_visual: bool = true
## 起漂最低速度 (内部单位, 默认18)
@export var qqsd_start_vec: float = 18.0
## 高速漂退漂钳速
@export var qqsd_end_vec_first: float = 50.0
## 低速漂退漂钳速
@export var qqsd_end_vec_second: float = 16.0
## 侧滑摩擦系数 (漂移角越大减速越猛)
@export_range(0.0, 5.0, 0.01) var qqsd_slid_fric_force: float = 1.2
## 滚动摩擦系数 (漂移角越小减速越猛)
@export_range(0.0, 5.0, 0.01) var qqsd_roll_fric_force: float = 1.0
## 回扳判定角度 (度, 45°是黄金漂移角)
@export_range(10.0, 90.0, 1.0) var qqsd_banner_angle_deg: float = 45.0
## 方向键扭矩基础 (反扳模式)
@export_range(0.0, 20.0, 0.1) var qqsd_dir_key_twist: float = 5.9
## 反扳扭矩扣减量
@export_range(0.0, 5.0, 0.1) var qqsd_dir_key_twist_param_a: float = 0.5
## 反扳扭矩保底量
@export_range(0.0, 5.0, 0.1) var qqsd_dir_key_twist_param_b: float = 1.5
## 顺扳扭矩基础 (反按方向键回正)
@export_range(0.0, 20.0, 0.1) var qqsd_banner_key_twist: float = 6.0
## 顺扳扭矩下限扣减量
@export_range(0.0, 5.0, 0.1) var qqsd_banner_key_twist_param_a: float = 1.2
## 顺扳扭矩上限附加量
@export_range(0.0, 5.0, 0.1) var qqsd_banner_key_twist_param_b: float = 0.0
## 自动回正扭矩基础
@export_range(0.0, 30.0, 0.1) var qqsd_banner_twist: float = 4.2
## 自动回正扭矩增长指数
@export_range(0.5, 3.0, 0.1) var qqsd_banner_twist_param_a: float = 1.3
## 最大角速度上限 (rad/s)
@export_range(0.5, 15.0, 0.1) var qqsd_max_wec: float = 3.5
## 方向键助推力基础
@export_range(0.0, 10.0, 0.1) var qqsd_dir_key_force: float = 1.5
## 油门驱动力基础
@export_range(0.0, 30.0, 0.5) var qqsd_dir_up_key_force: float = 10.0
## 回扳侧推力基础
@export_range(0.0, 20.0, 0.1) var qqsd_banner_vec_force: float = 6.0
## 全松键反向力
@export_range(0.0, 10.0, 0.1) var qqsd_release_key_force: float = 3.0
## 撞墙速度衰减倍率 (0.5=打对折)
@export_range(0.0, 1.0, 0.05) var qqsd_wall_crash_speed_mult: float = 0.5
## 速度效果系数 (内部单位到游戏单位的转换)
@export_range(0.1, 5.0, 0.1) var qqsd_vec_effect: float = 1.0
## 角速度效果系数
@export_range(0.1, 10.0, 0.1) var qqsd_wec_effect: float = 3.7

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
## 漂移低速推力: 入弯时速度过低, 给予玩家一个朝车头方向+原速度方向的推力帮助起速
@export var drift_low_speed_push: float = 12.0           ## 推力强度(m/s²)
## 低速推力速度阈值(drift_min_speed 的倍率). 速度低于 drift_min_speed × 此值 时触发推力
@export var drift_low_speed_push_threshold: float = 1.2
## 原速度方向推力占比: 0=全部朝车头, 1=全部朝原速度方向, 0.5=各一半
@export_range(0.0, 1.0, 0.05) var drift_low_speed_push_velocity_ratio: float = 0.4
## 低速推力曲线: X=当前速度/阈值速度(0=静止,1=阈值), Y=推力倍率. 推荐速度越低推力越大
@export var drift_low_speed_push_curve: Curve

# ---------------- 漂移自动回正 (漂移持续一段时间后车头自动朝速度方向缓慢回正) ----------------
@export_group("Drift Auto Straighten")
## 漂移自动回正开关: 1=启用, 0=关闭
@export var drift_auto_straighten_enabled: bool = true
## 漂移持续多少秒后开始自动回正 (给玩家充分的漂移操作时间)
@export var drift_auto_straighten_delay: float = 1.5
## 自动回正最大角速度 (度/秒). 实际速度 = 此值 × 曲线采样值
@export var drift_auto_straighten_speed_deg: float = 45.0
## 自动回正速度随时间的变化曲线: X=0 是 delay 时刻, X=1 是 delay + duration_ref 时刻
## 推荐: 从 0 缓慢上升到 1 (先慢后快, 给玩家反应时间)
@export var drift_auto_straighten_curve: Curve

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

## 漂移反打时车头 yaw 偏转衰减到的最低倍率: 1.0=反打不影响车头偏转, 0.0=反打时车头完全朝运动方向回正
## 推荐 0.0~0.2: 反打 → 前轮回正 → 车头跟着朝运动方向慢慢转回来
## 注: 不再控制车身侧倾, 侧倾在漂移期间始终保持完整(让漂移姿态视觉一致)
@export_range(0.0, 1.0, 0.01) var drift_counter_lean_mult: float = 0.0
## 反打时车头 yaw 回正的过渡平滑系数(越大回正/恢复越快) —— 这是"满速度"
## 实际生效速度会被 drift_counter_response_time 调制 (前期慢、后期才达到此值)
@export var drift_counter_lean_smooth: float = 4.0
## 【反打响应时间】反打从"刚开始按"到"达到峰值回正速度"的累计时间(秒)
##   背景: 真实物理 + 玩家手感, 反打不应该一按就最快, 而是有个加速过程
##         (前轮从打满到反向打满需要时间, 配合"轮胎慢慢从滑动转为反向抓地"的感受)
##   实现: 累计连续反打时长 _counter_steer_hold_time, 反打中断立即清零;
##         实际平滑速度 = drift_counter_lean_smooth × smoothstep(0, response_time, hold_time)
##         smoothstep 让起步柔和(不是线性), 玩家感觉"按下去先慢、转着转着突然就快了"
##   设 0 = 不蓄势, 一按就满速 (回到旧线性指数平滑行为)
##   推荐 0.3~0.8: 太短没"蓄势感", 太长玩家以为按键失灵
@export_range(0.0, 2.0, 0.05) var drift_counter_response_time: float = 0.5



# ---------------- 反打锁定 (反 exploit) ----------------
# 设计动机:
#   正打 turn_mult = 1.0, 反打 turn_mult ×= drift_counter_steer_mult (默认 0.35).
#   两者数值差距大 → 玩家来回快速切换转向方向时, turn_mult 在 1.0 ↔ 0.35 之间瞬时跳变,
#   镜头跟随出现跳变. 玩家发现: 只要单帧反打就能把视觉感受统一成"反打速度",
#   实际上他只是在 spam 转向输入. 这就是 spam 来回反打 exploit.
#
# 解决方案 (用户最终规则):
#   "漂移过程中一旦反打, 之后再正打转向速度也等同于反打速度, 直到退漂结束."
#   一次性单向锁: _counter_steer_used_in_this_drift 在反打瞬间置 true,
#   置 true 后所有正打也按反打速度走, 退漂(_start_drift/_end_drift) 才清回 false.
#   这彻底封死 spam 反打获益: 反打一次就废掉这次漂移剩余阶段的爽快正打.
#
## 反打锁定开关 (true=反打过的漂移转向永远按反打速度直到退漂; false=旧行为, 实时切换)
@export var drift_counter_lock_until_exit_enabled: bool = true

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
## 【设计说明】这个机制本质是"反打=刹车", 体感偏硬. 真正实现"反打=车顺惯性甩出去"的是
## 新参数 drift_counter_lat_grip_mult (反打时侧向抓地下降). 两个机制可以共存:
##   想要"刹车感"反打: 这个开 + drift_counter_decel 调高
##   想要"甩出感"反打: 这个关 (或调小 decel) + drift_counter_lat_grip_mult 调到 0.2~0.5
@export var drift_counter_decel_enabled: bool = true
## 反打减速强度 (m/s² × mass, 即每秒减多少 m/s 速度. |steer|=1 时的全力减速)
## 数学: F = drift_counter_decel × |steer_input| × mass, 沿 -v_horiz 方向施加
## 推荐 6~14: 6 = 轻微减速感; 10 = 明显抓地刹车; 14+ = 急停感
@export_range(0.0, 30.0, 0.1) var drift_counter_decel: float = 8.0
## 反打减速最小输入阈值: |steer_input| ≥ 此值才触发减速
## 防止"轻微反打/方向键抖动"也减速, 推荐 0.2~0.4
@export_range(0.0, 1.0, 0.01) var drift_counter_decel_min_steer: float = 0.25

# ---------------- 反打+前进 额外向前摩擦 (用户最新需求) ----------------
# 设计动机:
#   单纯的"反打减速"只在玩家反打时减速. 但玩家边反打边按前进键时, 引擎推力会和反打减速对冲,
#   导致反打体验变弱(车感觉还在加速). 真实物理上, "反打+踩油门" = 轮胎打滑+反向推力,
#   应该有显著的"前进方向摩擦感", 让玩家明显感到"踩油门也无法继续加速".
#
# 实现:
#   每帧检测: state==DRIFT + 反打 (steer 与 drift_dir 异号) + |steer| ≥ 阈值 + throttle_input > 0.05
#   若满足:   沿 -forward 方向额外施加摩擦力, 大小 = drift_counter_throttle_friction × |steer| × throttle × mass
#   位置:     在反打减速之后, 紧挨着, 不和引擎打架(只是把"前进方向"上的有效推力削弱)
#
# 数学:
#   F = -forward × drift_counter_throttle_friction × |steer_input| × throttle_input × mass
#   注: 不是 -v_horiz, 而是 -forward, 这样反打+前进时削弱的是"车头方向"上的推进
#       (反打减速 drift_counter_decel 是沿 -v_horiz, 处理"侧向滑行"那部分)
#
## 反打+前进时额外向前摩擦开关
@export var drift_counter_throttle_friction_enabled: bool = true
## 反打+前进时额外向前摩擦强度 (m/s² × mass)
## 数学: F = drift_counter_throttle_friction × |steer_input| × throttle_input × mass, 沿 -forward 方向施加
## 推荐 4~12: 4 = 轻微对抗感; 8 = 明显"踩油门也加不上速"; 12+ = 反打瞬间抓死
@export_range(0.0, 30.0, 0.1) var drift_counter_throttle_friction: float = 8.0

# ---------------- 反打 = 侧向抓地下降 (用户最新规则: "反打=车身顺惯性甩出去") ----------------
# 设计动机:
#   旧实现把"反打"当成"刹车" (drift_counter_decel + drift_counter_throttle_friction),
#   结果反打感觉像撞墙: 车被瞬间拽住, 完全不顺手.
#   真实物理上, 反打 = 玩家把前轮扭到反方向 → 但车身惯性还在原方向 → 前轮抓不住 →
#   车继续沿原惯性方向甩出去 (经典欠转向 understeer / 推头)
#
# 实现:
#   每帧检测: state==DRIFT + 反打 (steer 与 drift_dir 异号) + |steer| ≥ 反打减速最小输入阈值
#   若满足:   把 _apply_friction 里的 lat_k (侧向抓地系数) 乘以 drift_counter_lat_grip_mult
#             这样侧向摩擦下降 → 车不再被拽回打方向键的方向 → 顺惯性甩出去
#
# 数学:
#   反打强度 cs = clampf((|steer| - 阈值) / (1 - 阈值), 0, 1)  (阈值之上线性归一化)
#   实际倍率 = lerpf(1.0, drift_counter_lat_grip_mult, cs)
#   1.0 = 完全不缩 (不打/正打), drift_counter_lat_grip_mult = 完全反打
#
## 反打侧向抓地倍率 (反打时 lat_k *= 此值)
## 0.0 = 完全无侧向抓地, 车100%顺惯性甩出 (太滑)
## 0.3 = 强反打感, 车明显甩出去, 仍有一点抓地保留
## 0.6 = 温和反打, 车微微甩
## 1.0 = 关闭机制 (不影响侧向摩擦)
## 推荐 0.2~0.5
@export_range(0.0, 1.0, 0.01) var drift_counter_lat_grip_mult: float = 0.3

# ---------------- 集气公式参数 ----------------
@export_group("Charge Formula")
@export var charge_nitro_full: float = 100.0
@export var charge_per_lateral_m: float = 2.2
@export var charge_yaw_rate_weight: float = 1.8
@export var charge_min_per_sec: float = 12.0
@export var crash_charge_penalty: float = 0.2
@export var max_nitro_stock: int = 2
@export var instant_nitro_settle: bool = true
## 出生/复位时自带氮气: 开关
@export var spawn_nitro_enabled: bool = true
## 出生/复位时自带氮气格数
@export var spawn_nitro_stock: int = 2
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

## 空中喷射效率: 所有喷射(小喷/双喷/氮气/空喷/落地喷/钩索弹射等)在空中时推力的缩放比例
## 1.0 = 空中和地面推力一样; 0.6 = 空中只有地面 60% 的推力; 1.5 = 空中比地面强 50%
@export var boost_air_efficiency: float = 1.0

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
#   · V6 统一法线投影: 不再区分平地/坡面, 所有判断基于速度沿法线的投影
#   · 平地(法线≈UP): 法线投影 ≈ v.y, 效果和旧平地分支一样
#   · 坡面(法线沿坡面): 投影自然正确, 不存在策略切换边界
#   · plain_slope_threshold_deg 已废弃(V6不再使用), 保留变量兼容旧 cfg
@export_group("Ground Physics")
## 防弹跳总开关
@export var ground_stick_enabled: bool = true
## [V6 废弃] 旧版平地/坡面切换阈值. V6 统一法线投影后不再使用, 保留兼容旧 cfg
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

# ---------------- 真实反弹物理 (v3 硬碰硬) ----------------
# 设计目标 (用户最终需求): 撞墙要"硬碰硬", 像 QQ 飞车一样可以"撞墙过弯"
#   1) 擦墙: 切向几乎全保留 (擦墙不掉速, 让玩家敢往墙上贴)
#   2) 正撞: 弹得猛, 法线方向有强反弹 + 二次方缩放的 kickback (高速撞砰一下飞出去)
#   3) 撞墙过弯: 沿墙面切向额外推力, 让车能贴着墙滑出去过弯 (QQ 飞车的核心手感)
#   4) 撞完锁速宽松: cap = max(撞前, 撞后) × 倍率, 不会把 kickback 自己拍下去
@export_group("Wall Reflect (Realistic)")
## 切向速度保留比例 - 撞越狠减得越多 (从 keep_max 到 keep_min 之间按撞击速度插值)
## keep_max = 撞击速度极小时(擦墙)的切向保留比例 (推荐 0.85~0.95, 让擦墙基本不掉速)
@export_range(0.0, 1.0, 0.05) var wall_reflect_tangent_keep_max: float = 0.9
## keep_min = 撞击速度极大时(正撞)的切向保留比例 (推荐 0.2~0.4)
@export_range(0.0, 1.0, 0.05) var wall_reflect_tangent_keep_min: float = 0.3
## 切向减速插值参考速度 (m/s): 撞击 v_normal 达到此值时, tangent_keep 完全降到 keep_min
## 推荐 15~25: 大约相当于 50~80km/h 正撞
@export var wall_reflect_tangent_lerp_speed: float = 18.0
## 兼容旧参数: wall_reflect_tangent_keep (单一保留比例)
## 设 > 0 时优先生效, 跳过 keep_max/keep_min/lerp_speed 三件套. 默认 0 = 用新版插值
@export_range(0.0, 1.0, 0.05) var wall_reflect_tangent_keep: float = 0.0
## 法线方向反弹系数 (恢复系数 e)
## 0=完全吸收无弹回(粘墙), 1=完美弹性, 推荐 0.55~0.75 (硬碰硬)
@export_range(0.0, 1.0, 0.05) var wall_reflect_normal_factor: float = 0.65
## 【硬碰硬 kickback V3】撞墙后沿法线方向额外推开的瞬时速度 (m/s)
## V3 数学修复: 用 (into_wall/10)² 二次方缩放, 高速撞才"砰"一下被弹飞
##   into_wall=5  → scale=0.25→clamp 0.5×    (低速擦墙: 推 0.5×kickback)
##   into_wall=10 → scale=1.0×                 (中速撞墙: 推 1.0×kickback)
##   into_wall=20 → scale=4.0×                 (高速撞墙: 推 4.0×kickback, 真的砰一下飞出去)
##   into_wall=30 → scale=9→clamp 4.0×         (上限保护)
## 推荐 5~15. 设 0 = 关闭
@export var wall_hit_kickback: float = 8.0
## 【QQ 飞车撞墙过弯】(已废弃 - 用户要的是"弹墙掉头"不是"滑墙")
## 沿墙面切向方向的额外推力 (m/s). 保留参数兼容旧 cfg, 默认 0 = 关闭
## 要\"弹墙掉头\"手感请用 wall_reflect_normal_factor + wall_hit_kickback + wall_turnaround_* 参数
@export var wall_slide_boost: float = 0.0
## 【弹墙掉头 — 切向擦除】正撞时沿墙面切向速度的衰减比例 (额外叠加在 tangent_keep 之上)
## 目的: 正撞时玩家速度大部分应该被"弹回反方向", 而不是"被保留沿墙滑"
## 数学: 正撞 (face_angle >= wall_grazing_angle_deg) 时,
##       v_tangent 在标准 tangent_keep 之上再乘以 (1 - wall_straight_tangent_kill)
## 1.0 = 正撞时切向完全清零 (车完全沿法线弹回, 最 QQ飞车)
## 0.5 = 正撞时切向再减一半 (擦墙不受影响)
## 0.0 = 关闭此机制 (旧行为)
## 推荐 0.6~0.9
@export_range(0.0, 1.0, 0.05) var wall_straight_tangent_kill: float = 0.7
## 【弹墙掉头】墙判定法线 n.y 宽松阈值
## 防止用户把 slope_wall_angle_deg 调太严(如 80°), 弧形墙的法线达不到阈值导致撞墙完全没反应
## 数学: n.y < 0.7 ≈ 法线与 Y 轴夹角 > 45°. 推荐 0.6~0.75
## 设 1.0 = 完全依赖 slope_wall_angle_deg 严格判定 (不推荐)
@export_range(0.0, 1.0, 0.05) var wall_normal_y_threshold: float = 0.7
## 【硬碰硬 锁速】撞墙后短暂窗口内, 整车水平速度上限被 clamp
## V3 修复: cap = max(撞前速度, 撞后速度) × wall_hit_speed_cap_mult
##   不再是"撞后速度 × 倍率", 防止 kickback 被自己的 cap 立刻拍下去
## 1.0=锁死撞前速度上限, 1.05=允许微涨, 1.5=允许大涨 (kickback 飞得多远不限)
@export_range(0.5, 2.0, 0.05) var wall_hit_speed_cap_mult: float = 1.5
## 【硬碰硬 锁速】撞墙后锁速窗口持续时间 (秒). 设 0 = 关闭锁速
## 推荐 0.2~0.5: 短了感觉不到, 长了会卡顿
@export_range(0.0, 1.5, 0.05) var wall_hit_lock_duration: float = 0.3
## 【硬碰硬 清 boost】撞墙瞬间是否取消正在进行的 boost (小喷/双喷/氮气)
## true = 撞墙取消所有喷射, 让"撞击-减速"更明确
## false = 撞墙不影响 boost (旧行为)
@export var wall_hit_cancel_boost: bool = false

## 【防吸住 V4】撞墙后, 撞墙物理触发的冷却时间 (秒). 该窗口内不再触发新的反弹
## 解决: trimesh 撞墙时每物理帧都报告 contact + 每帧都触发反弹, 反弹瞬间被接触约束拽回 → "吸住"
## 推荐 0.1~0.2: 太短防不住, 太长玩家二次撞墙没反应
@export_range(0.0, 1.0, 0.01) var wall_hit_cooldown: float = 0.15

## 【防吸住 V4】撞墙瞬间沿法线方向硬位移 (米), 让车物理上立即脱离接触面
## 不依赖速度推开 (那种方式在每帧 contact 报告下会被立即拽回)
## 推荐 0.05~0.15: 0.05=5cm 微推开足以脱离, 0.15=15cm 更安全
## 设 0 = 关闭硬位移 (回到旧行为, 容易吸住)
@export_range(0.0, 0.5, 0.01) var wall_unstick_offset: float = 0.08

# ---------------- 弹墙掉头 (车身 yaw 跟随反弹方向旋转) ----------------
# 概念: QQ 飞车撞墙时, 车不光物理上被弹开, **车头也跟着转向**被弹开的方向
#       这样车撞完墙的下一刻不会车头朝墙, 而是车头朝场地中央, 玩家立刻能继续驾驶
# 实现:
#   撞墙瞬间 _integrate_forces 计算 new_v 后, 把该速度方向设为目标 yaw
#   然后在 _update_visuals 里每帧把 car_mesh 的 yaw 插值到 _wall_turnaround_target_yaw
#   wall_turnaround_duration 控制插值速度 (0=瞬间转, 0.3=0.3秒内转过去)
## 弹墙掉头总开关
@export_group("Wall Turnaround (弹墙掉头)")
@export var wall_turnaround_enabled: bool = true
## 弹墙掉头生效的最小撞击速度 (m/s): 低于此速度的轻碰不触发车身转向
## 推荐 5~10: 5 = 轻碰也会掉头, 10 = 只有明显撞击才掉头
@export var wall_turnaround_min_into: float = 7.0
## 弹墙掉头持续时间 (秒): 车身 yaw 在此秒数内从"撞墙瞬间 yaw"平滑到"反弹方向 yaw"
## 0 = 瞬间转过去 (硬切), 0.25~0.4 = QQ 飞车风格的平滑"被撞飞"转向
## 推荐 0.3
@export_range(0.0, 1.5, 0.01) var wall_turnaround_duration: float = 0.3
## 弹墙掉头最大旋转角度 (度): 限制单次掉头的最大角度, 防止小角度擦墙也强制大转向
## 正常撞墙入射角大 → 反弹方向差异大, 掉头角也大. 此参数是硬上限
## 推荐 120~180: 180=允许 180° 原路返回, 120=最多转 120° (保留一些切向运动)
@export_range(0.0, 180.0, 5.0) var wall_turnaround_max_deg: float = 150.0
## 弹墙掉头最小旋转角度 (度): 小于此角度的掉头直接跳过(擦墙时避免抖头)
## 推荐 15~30
@export_range(0.0, 90.0, 1.0) var wall_turnaround_min_deg: float = 20.0
## 擦墙临界角(度) - 车头与墙面切平面夹角小于此值视为擦墙, 不施加额外切向摩擦
## 90°=正面撞(完全弹回), 0°=平行墙(完全擦过). 推荐 15~25°
@export_range(0.0, 90.0, 1.0) var wall_grazing_angle_deg: float = 20.0
## 玻璃渣特效场景
@export var glass_shatter_fx_scene: PackedScene = preload("res://fx/GlassShatterFX.tscn")
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

# ---------------- 加速带 / 弹射器 (Speed Pad) ----------------
# 由赛道上的 Area3D (SpeedPad.gd) 触发: 车穿过加速带白色方块时
# 调用 car.apply_speed_pad_boost(kick, duration, pad_type) 给一次"增速 + 短暂持续推力"
#
# 【实现】两段式:
#   1) 瞬时冲量: apply_central_impulse(forward × kick × mass), 让车速立刻 +kick m/s
#   2) 持续推力: _speed_pad_boost_left > 0 时, _apply_engine_and_brake 每帧沿 forward
#      施加一个衰减力, 让"加速感"在 duration 秒内逐渐消退而不是瞬间结束
#
# 【顶速放宽】加速带持续期内, effective_top 临时抬高到 top_speed_boosted (喷射极速),
#   让加速带能把速度真正顶上去, 而不是被 max_speed 软封顶吃掉
## 加速带持续推力基础值 (m/s² × mass). 在 duration 时间内沿 forward 持续施力
## 数学: F = _speed_pad_boost_power × (t_left / duration) × mass  // 线性衰减
@export var speed_pad_sustain_power: float = 18.0
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
## V5 改进: 不仅清当前帧法向速度, 还施加预抵消冲量对抗 solver 反弹
## 数学: 预抵消冲量 = fall_speed × absorb × landing_anti_bounce_mult × mass
## 注: 当 landing_hard_stick = true 时, 此参数被忽略(直接强制 Y=0)
@export var landing_impact_absorb: float = 0.85

## 【落地稳压窗口时长】落地后持续 N 秒, 每帧清法向分离速度 + 施加向下压力, 彻底消除弹跳
## 数学: 窗口内每帧 v_along_n > 0 → 清零; 同时施加 -n × landing_settle_downforce × mass
## 0.35 推荐 (覆盖物理引擎 settle 全过程). 太短压不住高速落地反弹, 太长会影响起跳响应
@export_range(0.05, 1.0, 0.01) var landing_settle_duration: float = 0.35

## 【落地稳压向下压力】settle 窗口内每帧沿法线向下施加的力 (N/kg)
## 主动把球压回地面, 对抗 Godot 物理 solver 在碰撞后产生的反弹分离速度
## 8 推荐. 太小压不住高速落地, 太大会让车"粘"在地上影响起跳
@export_range(0.0, 40.0, 0.5) var landing_settle_downforce: float = 8.0

## 【预抵消反弹冲量系数】落地帧额外施加向下冲量 = fall_speed × absorb × 此值 × mass
## 预存一个向下动量, 抵消 solver 在下一帧产生的反弹速度
## 0.5 推荐 (solver 反弹通常是落地速度的 30~60%, 取中间值). 0=不施加预抵消
@export_range(0.0, 2.0, 0.05) var landing_anti_bounce_mult: float = 0.5

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

# ---------------- 时间回溯 (Rewind) ----------------
# 用户要求: 按住 R 键 → 不停倒退到之前的位置, 状态/速度都消失
# 实现: 每物理帧把 (position, basis) 写到环形 buffer, 按 R 时从 buffer 末尾向前回放
# 多按越久回放速度越快 (rewind_speed_ramp_per_sec 累加)
@export_group("Rewind (R 键)")
## 回溯开关
@export var rewind_enabled: bool = true
## 历史 buffer 长度 (秒). 默认 8 秒 = 480 帧 @ 60fps. 越长内存占越多但能倒得越远
@export_range(1.0, 30.0, 0.5) var rewind_buffer_seconds: float = 8.0
## 回放基础速度 (倍率). 1.0 = 1 秒回放消耗 1 秒历史; 2.0 = 1 秒消耗 2 秒
@export_range(0.5, 8.0, 0.5) var rewind_speed_base: float = 2.0
## 回放速度斜坡: 按住 R 越久, 回放速度每秒额外增加这么多 (上限 rewind_speed_max)
@export_range(0.0, 4.0, 0.1) var rewind_speed_ramp_per_sec: float = 0.8
## 回放速度上限
@export_range(1.0, 12.0, 0.5) var rewind_speed_max: float = 6.0
## 回溯时是否冻结物理 (true = freeze + 看不到颠簸; false = 仅每帧覆盖位置)
@export var rewind_freeze_physics: bool = true

# ---------------- 自定义位置模式 (FreeFly) ----------------
# 用户要求: 按小键盘 0 进入【自定义位置模式】, 不再受任何物理影响
#   方向键改水平面坐标, Shift 升高, Ctrl 下降, 速度可配置, 越按越快, 相机拉远
#   再按 0 退出, 回到 3C 状态
@export_group("FreeFly (小键盘 0)")
## FreeFly 开关
@export var freefly_enabled: bool = true
## FreeFly 基础移动速度 (m/s)
@export_range(2.0, 60.0, 1.0) var freefly_speed_base: float = 12.0
## FreeFly 持续按方向键, 每秒速度额外增加这么多 m/s (上限 freefly_speed_max)
@export_range(0.0, 60.0, 1.0) var freefly_speed_ramp_per_sec: float = 16.0
## FreeFly 速度上限
@export_range(5.0, 120.0, 1.0) var freefly_speed_max: float = 50.0
## Shift 升高速度 (m/s, 也按同样的 ramp 累加)
@export_range(2.0, 30.0, 1.0) var freefly_lift_speed: float = 10.0
## FreeFly 模式下相机距离的额外乘数 (Camera3D.gd 读这个)
@export_range(1.0, 4.0, 0.1) var freefly_camera_distance_mult: float = 1.6


# ============================================================
#  🦘 跳跃系统 (Jump)
# ============================================================
# 用户需求 (2026-06-02): "为赛车加跳跃功能, 是核心功能,
#   当没有钩索可以勾的时候按空格使用 (空格优先发钩索, 找不到锚点 fallback 跳跃)"
#
# 输入路由 (在 _read_input 里):
#   按空格 → _grapple_hook.try_fire()
#     IDLE + 钩到锚点 → return true → 进入钩索, 不跳
#     IDLE + 找不到锚点 → return false → fallback _try_jump()  ← 新增
#     非 IDLE (已在钩索中) → return false → 钩索处理释放, 不跳
#
# 跳跃逻辑:
#   一段跳: 在地面 (on_ground=true) 时按空格且找不到锚点 → 给 v.y 一个冲量
#           调 apply_jump_pad_kick() 走防弹豁免 (跟蘑菇/反重力机关一样)
#           保留水平速度, 可选额外车头方向推力 (jump_forward_kick)
#   二段跳: 一段跳后未触地 + jump_double_enabled + 二段跳次数未用 → 再跳
#           二段跳冲量较小 (jump_double_impulse), 视觉上可选车身翻转
#
# 视觉表现:
#   起跳压扁 (squash): car_mesh.scale.y *= (1 - amount) 短时间, 然后回弹
#   起跳震屏 + 落地震屏 (camera_shake_requested 信号)
#   二段跳车身前空翻 (绕 X 轴转 360°, 持续 1/(speed/360) 秒)
#
# 数学:
#   跳跃高度 h = v² / (2g), g=29 (项目重力)
#     jump_impulse = 25 m/s → h ≈ 10.8 m
#     jump_double_impulse = 18 m/s → 二段跳从顶点再爬 ≈ 5.6 m
@export_group("Jump (跳跃)")
## 跳跃总开关 (0=禁用整套跳跃, 1=启用. 空格找不到锚点时 fallback)
@export var jump_enabled: bool = true
## 二段跳开关 (0=只允许地面跳, 1=允许空中再跳一次)
@export var jump_double_enabled: bool = true
## 一段跳冲量 (m/s). 直接设为新的 v.y, 然后走 apply_jump_pad_kick 防弹豁免
##   推荐 15~35: 15=轻跳过 1.2m 障碍, 25=能跳到 ~10m 高, 35=能跳到 ~21m 高
##   公式: h = v² / (2g), g=29 (项目重力)
@export_range(5.0, 60.0, 0.5) var jump_impulse: float = 25.0
## 二段跳冲量 (m/s). 一般比一段跳小, 给爬坡/补救用
##   推荐 12~25, 默认 18 = 从顶点再爬 ~5.6m
@export_range(5.0, 60.0, 0.5) var jump_double_impulse: float = 18.0
## 跳跃时保留水平速度的比例 (0~1)
##   1.0 (默认) = 完全保留 (跳起来按惯性继续前飞, 不干扰玩家方向控制)
##   0.0 = 跳起来水平速度归零
##   推荐 1.0 (用户高压线: 跳跃不要碰水平方向)
@export_range(0.0, 1.0, 0.05) var jump_horizontal_keep: float = 1.0
## [废弃] 跳跃水平方向是否重定向到车头方向 — 用户反馈"重定向 = 强行设置车头朝向", 已禁用.
## 当前跳跃逻辑完全保留水平速度向量, 不重定向. 此参数仅用于兼容旧 cfg, 改它无效.
@export var jump_redirect_horizontal_to_forward: bool = false
## 跳跃最低前飞速度 (m/s). 保证即使静止/低速按空格也朝车头方向飞.
##   数学: horiz_speed = max(|v.xz| × keep, jump_forward_kick)
##   0 = 静止跳只有 Y 分量 (会被角速度漂向一侧, 用户反馈"不朝车头")
##   10 (默认) = 静止跳也沿车头飞 10 m/s, 感觉明确"朝前跳"
##   推荐 5~15
@export_range(0.0, 30.0, 0.5) var jump_forward_kick: float = 10.0
## 跳跃冷却 (秒). 防止连按空格爆跳
@export_range(0.0, 2.0, 0.05) var jump_cooldown: float = 0.15
## 跳跃后防弹豁免窗口 (秒). 跟蘑菇/反重力一样跳过 _apply_ground_stick 的下压力
##   太短 → 跳起来立刻被压回. 太长 → 落地了还在豁免会乱
@export_range(0.05, 1.5, 0.05) var jump_skip_stick: float = 0.4
## 漂移中是否允许跳 (0=禁止, 1=允许. 默认禁止防止漂移段被跳跃打断)
@export var jump_allow_in_drift: bool = false
## 起跳压扁视觉开关 (1=有压扁动画, 0=纯物理跳)
@export var jump_squash_enabled: bool = true
## 起跳压扁强度 (0~0.5). car_mesh.scale.y 在跳跃瞬间 = (1 - amount)
##   0.25 = Y 方向压扁到 0.75 (压扁 25%), 看起来"蹲跳"
@export_range(0.0, 0.5, 0.01) var jump_squash_amount: float = 0.2
## 起跳压扁恢复时长 (秒). 压扁到恢复正常的总时间
@export_range(0.05, 0.6, 0.01) var jump_squash_duration: float = 0.18
## 起跳震屏强度 (0~3). 0 = 无震屏
@export_range(0.0, 3.0, 0.05) var jump_takeoff_shake: float = 0.3
## 落地震屏强度 (0~3). 跳跃后第一次触地触发
@export_range(0.0, 3.0, 0.05) var jump_landing_shake: float = 0.6
## 二段跳前空翻开关 (1=空中翻转视觉, 0=平跳)
@export var jump_air_flip_enabled: bool = true
## 二段跳前空翻速度 (度/秒). 360 = 1 秒翻一圈
@export_range(0.0, 1080.0, 5.0) var jump_air_flip_speed: float = 540.0
## 落地烟尘开关 (1=触发 DriftFX 落地烟雾, 0=无). 如果 DriftFX 节点存在
@export var jump_landing_dust_enabled: bool = true


# ---------------- 节点 ----------------
@onready var car_mesh: Node3D = get_node_or_null("CarMesh")
@onready var body_mesh: Node3D = get_node_or_null("CarMesh/suv2")
@onready var ground_ray: RayCast3D = get_node_or_null("CarMesh/RayCast3D")
@onready var right_wheel: Node3D = get_node_or_null("CarMesh/suv2/wheel_frontRight")
@onready var left_wheel: Node3D = get_node_or_null("CarMesh/suv2/wheel_frontLeft")

@export var auto_spawn_hud: bool = true
@export var hud_scene: PackedScene = preload("res://ui/HUD.tscn")
@export var fx_scene: PackedScene = preload("res://fx/BoostFX.tscn")
@export var drift_fx_scene: PackedScene = preload("res://fx/DriftFX.tscn")
@export var tuner_scene: PackedScene = preload("res://ui/Tuner.tscn")
@export var auto_spawn_tuner: bool = true
## 钩索系统场景. spawn 在 car 节点下作为子节点, 通过 _grapple_active 状态字段
## 反向影响 car 物理 (引擎抑制 / 摩擦削减), 通过空格键 (project.godot 里的 grapple action) 触发
@export var grapple_hook_scene: PackedScene = preload("res://grapple/GrappleHook.tscn")
@export var auto_spawn_grapple: bool = true
## 自由钩索 (蜘蛛侠式无锚点拉起). 与原钩索互斥, free_grapple_enabled=true 时原钩索不生效
@export var free_grapple_scene: PackedScene = null  # 由 Tuner 或手动设置
@export var auto_spawn_free_grapple: bool = true

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
## 松前漂移触发: 在松前状态下踩回前进键瞬间发出, 供 HUD 弹"松前漂移"字
##   payload: count_in_this_drift = 这次入漂以来累计第几次触发(从 1 开始)
signal songqian_drift_triggered(count_in_this_drift: int)
## 三喷 (松前后退喷) 触发: 携带角度信息供 HUD 显示
signal songqian_back_boost_triggered(yaw_deg: float)
signal reset_to_origin_triggered                          ## 按B/终点传送回出生点时发出
signal finish_line_reached                                ## 到达终点机关时发出 (由终点机关调用)

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
var _stack_chain_types: Array[String] = []    # 叠喷链中每段的具体 boost type: ["grapple_nitro", "grapple_boost", "air"] 等

# ---- 钩索叠喷 (独立系统, 不走普通叠喷逻辑) ----
var _grapple_stack_chain_index: int = 0               # 钩索叠喷链中当前段索引
var _grapple_stack_breakthrough_count: int = 0        # 钩索叠喷已突破次数
var _grapple_stack_current_breakthrough: bool = false  # 当前段是否处于钩索叠喷突破状态
var _grapple_stack_chain_seq: Array[String] = []      # 钩索叠喷链字母序: ["c", "w", "w"]
var _grapple_stack_chain_types: Array[String] = []    # 钩索叠喷链具体类型
var _grapple_stack_cww_done: bool = false              # CWW 终结后禁止再触发空喷

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
var _drift_inertia_active: bool = false  # 惯性感开关: 入漂 true, 退漂瞬间 false

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

# QQ飞车漂移系统实例
var _drift_system: RefCounted = null

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
# 【V4 落地稳压窗口, 与 export 参数无关】
# 用户反馈钩爪落地多次弹跳, 尤其下坡斜面. _apply_landing_physics 在落地这一帧已经做了
# "速度法向清零 + 法向位置 clamp", 但接下来 1~3 帧物理引擎的接触约束还在 settle, 可能有微弹.
# 这个窗口在落地后 0.18s 内每帧执行"沿法线分离速度清零", 直到完全稳定.
# 不走 _landing_stick_left / landing_stick_duration 的 export 路径, 避免"用户改了 cfg 关闭 → V4 失效"
var _v4_landing_settle_left: float = 0.0
# V5: settle 窗口时长现在走 @export landing_settle_duration, 不再用 const

# ============================================================
# 路面法线低通滤波 — 解决弯坡 trimesh 抖动
# ============================================================
# 用户反馈: 弯坡车身像"上台阶"一样抖. 调研结论:
#   抖动根因 = ground_ray 命中 trimesh 时, 法线 = 被命中那个三角形的面法线.
#   trimesh 是无数个三角形拼的, 三角形 A 跟 B 法线虽然差不多, 但有微小差异.
#   球-trimesh 接触时每帧命中的三角形可能跳变 (saddle 问题), 导致 ground_ray 拿到的法线
#   每帧抖动几度, 反复触发 _apply_ground_stick 里"沿法线 v 投影 → 清掉分离速度",
#   产生肉眼可见的"颤动"或"上台阶"感.
# 修复: 用一阶低通滤波 (指数衰减) 平滑法线 — 这是 GT Sport / Forza 等赛车游戏的标准做法.
#   smoothed = lerp(smoothed, raw, 1 - exp(-dt / tau))
#   tau (时间常数) 越大越平滑, 越小越跟手.
#   tau = 0.06s ≈ 4 帧 @ 60fps, 平滑掉单帧抖动但不影响真实斜坡过渡反应
var _smoothed_ground_normal: Vector3 = Vector3.UP   # 上一帧平滑后的法线
var _smoothed_normal_initialized: bool = false
# 时间常数: 0.06s ≈ 4 帧 @ 60Hz 视觉 / 14 物理帧 @ 240Hz
# 用户反馈: tau=0.15s 太大, 上坡时法线响应慢 0.15s, 期间 thrust_dir 还是水平的,
#          going_uphill 判定失败, 重力补偿/上坡助力全跳过 → 车开不上坡.
# 折中值 0.06s: 单帧抖动 (1~2 帧) 仍能滤掉, 真实坡度切换 (0.3s+) 跟得上.
const GROUND_NORMAL_SMOOTH_TAU: float = 0.06


# 每帧统一更新平滑路面法线, 在 _physics_process 里调一次
# 之后所有需要"路面法线"的代码 (_apply_ground_stick / _apply_engine_and_brake 的
# slope_align_thrust 投影 / _update_visuals 的贴坡) 都用 _smoothed_ground_normal,
# 不再各自调 ground_ray.get_collision_normal() 拿 raw 法线 (那是 trimesh 抖动的源头)
func _update_smoothed_ground_normal(delta: float, on_ground: bool) -> void:
	if not on_ground or ground_ray == null or not ground_ray.is_colliding():
		# 离地: 重置滤波器, 下次贴地从干净状态开始
		_smoothed_normal_initialized = false
		return
	var raw_n: Vector3 = ground_ray.get_collision_normal().normalized()
	# 防御: 极端情况返回 (0,0,0), 用 UP 兜底
	if raw_n.length_squared() < 0.01:
		raw_n = Vector3.UP
	if not _smoothed_normal_initialized:
		_smoothed_ground_normal = raw_n
		_smoothed_normal_initialized = true
	else:
		# 一阶低通滤波 (指数衰减): tau 越大越平滑
		var alpha: float = 1.0 - exp(-delta / GROUND_NORMAL_SMOOTH_TAU)
		_smoothed_ground_normal = _smoothed_ground_normal.lerp(raw_n, alpha).normalized()

# ---- 时间回溯 (Rewind) 状态 ----
# 环形 buffer 每帧记 (pos, basis_yaw, mesh_basis, time)
# capacity = round(rewind_buffer_seconds * 60)  (60 fps)
# write_index 写入位置, 满了覆盖最旧的
# size = 当前 buffer 实际填了多少帧
# rewind_active = 当前是否在回溯中
# rewind_pressed_t = 按住 R 已经多久 (用来 ramp 回放速度)
# rewind_cursor = 当前回放到 buffer 里哪一帧 (从最新一帧 size-1 往 0 倒退)
var _rewind_buffer: Array = []   # Array of {"pos": Vector3, "mesh_xform": Transform3D}
var _rewind_capacity: int = 480
var _rewind_write_idx: int = 0
var _rewind_size: int = 0
var _rewind_active: bool = false
var _rewind_pressed_t: float = 0.0
var _rewind_cursor: float = 0.0   # 用 float 让 ramp 速度可以非整数
var _last_r_press_t: float = -999.0   # 上一次按 R 时间, 用来检测双击 (双击 = 复位, 单按 = 回溯)

# ---- 自定义位置模式 (FreeFly) 状态 ----
# 进入: KEY_KP_0 切换 (再按一次退出)
# 退出后清掉所有速度, 恢复物理
var _freefly_active: bool = false
var _freefly_pressed_t: float = 0.0   # 任意方向键累计按住时间, 用来 ramp 速度
var _freefly_was_freeze: bool = false   # 进入前的 freeze 状态备份
var _freefly_was_gravity_scale: float = 1.0
var _freefly_was_collision_layer: int = 1
var _freefly_was_collision_mask: int = 1

var _landing_boost_arm_left: float = 0.0         # 稳定落地后落地喷的按键窗口剩余时间
var _wall_drift_protect_left: float = 0.0         # (已废弃, 保留避免其他地方的未来引用) 撞墙断漂已改为立即断+CD
var _drift_lockout_left: float = 0.0              # 撞墙断漂后的入漂冷却剩余秒数, >0 时按 Q 无法入漂
# 撞墙断漂后, 玩家必须先松开 Q 再重新按下才能再次入漂
# 防止"按住 Q 撞墙→CD 走完→Q 还按着→自动续漂"
var _require_release_q: bool = false
var _p2_debug_timer: float = 0.0  # 2P 调试计时器 (每秒打印一次输入状态)
var _post_drift_steer_cooldown_left: float = 0.0  # 退漂转向冷却剩余秒数
# 撞墙锁速窗口 (硬碰硬反弹)
var _wall_hit_lock_left: float = 0.0    # 锁速窗口剩余秒数
var _wall_hit_speed_cap: float = 0.0    # 锁速窗口期内的最大水平速度 (m/s)
# 撞墙冷却 (防吸住): 撞墙触发反弹后此秒数内不再触发新的反弹
var _wall_hit_cooldown_left: float = 0.0
# 弹墙掉头 (车身 yaw 跟随反弹方向)
var _wall_turnaround_left: float = 0.0       # 掉头动画剩余秒数
var _wall_turnaround_total: float = 0.0      # 本次掉头总时长 (用于 normalize)
var _wall_turnaround_start_yaw: float = 0.0  # 撞墙瞬间的车身 yaw (世界坐标, 弧度)
var _wall_turnaround_target_yaw: float = 0.0 # 反弹后目标 yaw (弧度)
# 反打时车头 yaw 偏转衰减系数, 平滑到 1.0(正打/不打=完整偏转) ~ drift_counter_lean_mult(完全反打=朝运动方向回正)
var _counter_lean_factor: float = 1.0
# ---- 加速带 / 弹射器状态 ----
# 剩余持续推力时间 (秒). > 0 时 _apply_engine_and_brake 会沿 forward 施加衰减推力
var _speed_pad_boost_left: float = 0.0
# 本次加速带的总时长 (用于线性衰减进度计算)
var _speed_pad_boost_total: float = 0.0
# 本次加速带的推力强度 (m/s², 全时段峰值)
var _speed_pad_boost_power: float = 0.0
# 【反打响应蓄势时长】连续反打累计秒数, 0=刚开始/未反打, response_time=已蓄满到峰值
# 反打满足条件每帧 += delta, 反打中断立即清零, 用 smoothstep 计算实际回正速度倍率
var _counter_steer_hold_time: float = 0.0
# 【反打锁定 flag】本次漂移是否反打过
# 入漂时清 false, 反打的瞬间置 true, 退漂时清 false
# 一旦置 true, 后续即使玩家正打, turn_mult 也按反打速度走, 直到这次漂移结束
var _counter_steer_used_in_this_drift: bool = false
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
# 【松前漂移 CD】剩余冷却时间(秒). >0 表示在 CD, 不能再次触发松前漂移.
#   _trigger_songqian_drift 成功时 = songqian_drift_cooldown
#   _start_drift 起漂时清 0 (新一轮漂移立即可用)
#   每物理帧由 _physics_process 衰减
var _songqian_drift_cd_left: float = 0.0

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

# ---- 钩索系统状态 ----
# _grapple_active = true 表示玩家当前正被钩索拉着 (GrappleHook 进入 ATTACHED 时置 true, 释放时置 false)
# 这个 flag 让 car 物理 _apply_engine_and_brake / _apply_friction / _apply_friction 末端
# 决定: 钩索期间是否抑制引擎力, 摩擦削减多少 (具体倍率/开关参数都在 GrappleHook.gd 里, 这里只读 flag)
# 由 GrappleHook 通过 car.set("_grapple_active", true/false) 直接修改 (而不是走信号), 因为物理读取需要每帧实时
var _grapple_active: bool = false
# ---- 自由钩索状态 ----
# _free_grapple_active = true 表示玩家当前处于自由钩索状态 (拉起/下坠/弹射中)
# 自由钩索期间: 禁止漂移、禁止小喷、禁止原钩索
var _free_grapple_active: bool = false
# 绳子(CoopMode)摩擦削减倍率: 由 CoopMode 每帧设置, 1.0=正常, <1.0=削减摩擦(后车卡墙时被拉动更容易)
var _rope_friction_mult: float = 1.0

# ---- 跳跃台/弹簧冲击窗口 ----
# 外部机关 (FlipBoard 跳板 / SpringMushroom 弹簧蘑菇 / GravityCylinder 反重力等) 给车一个
# 大的瞬时速度时, 必须在短时间内绕过 _apply_ground_stick 的防弹机制(plain_vy_zero_threshold +
# plain_downforce + slope_stick_force), 否则:
#   · 22 m/s 的弹力被 plain_downforce=8 N/kg 持续往下压(总减速 g=29 + 8 = 37 m/s²) → 弹得不高
#   · 即使初始 v.y > plain_vy_zero_threshold(5), 弹起到峰值后回落时若 ground_ray 又命中蘑菇盖
#     会触发 v -= n*v_along_n 把残余 Y 速度吃掉 → 看起来"弹力不足"
# 这个倒计时窗口在 _apply_ground_stick 顶部直接 return, 让弹力完整作用 (类似钩索期间).
var _jump_pad_kick_left: float = 0.0

# ---- 反重力定向窗口 ----
# 用户反馈 (2026-06-02): "反重力时镜头不用跟随, 但输入要更合理.
#                         在反重力墙面上一按前就会向上方冲出反重力墙壁"
# 真凶: _apply_engine_and_brake 用 ground_ray 朝 -Y 打的法线做 slope_align_thrust 切平面投影.
#       但反重力墙面是垂直的, ground_ray 朝 -Y 打不到墙 → ground_n 退化为 UP →
#       forward 被投影到水平面 → 玩家按 W 推力沿水平方向 → 直接把车推离墙面 → "冲出"
# 修复: 反重力机关每帧调 apply_anti_gravity_orientation(world_normal) 告诉 car 当前贴附面的法线
#       _apply_engine_and_brake / _apply_friction 在窗口期内用 _anti_gravity_normal 替换 ground_n
#       这样推力 / 摩擦都沿"反重力面切平面" → 玩家按前 = 沿墙面走, 不会冲出
#
# 镜头不变: 我们不旋转 car_mesh (镜头 look_at 用 Vector3.UP 始终保持地面视角)
#           只改"输入响应方向", 用户视角不变, 输入合理化 — 完全符合用户需求
#
# 字段:
#   _anti_gravity_normal: Vector3 — 反重力面的"外法线"(从车朝外的方向)
#                                   = -吸附力方向 (吸附力是把车压向面, 法线是反过来)
#   _anti_gravity_left: float — 倒计时秒数, > 0 表示窗口激活
#                               反重力机关每帧调一次会把这个重置成 ANTI_GRAVITY_WINDOW
var _anti_gravity_normal: Vector3 = Vector3.ZERO
var _anti_gravity_left: float = 0.0
const ANTI_GRAVITY_WINDOW: float = 0.1   # 100ms 窗口, 60Hz 物理也安全 (机关每帧调时持续保持激活)


## 公开接口 — 反重力机关每帧调用, 告诉 car 当前贴附面的法线方向
##
## 参数:
##   normal: 世界空间的反重力面"外法线" (从车朝外, 即贴附时车在 normal 方向那一侧)
##           墙面: normal = wall_normal (墙的 +Z 朝外)
##           圆柱: normal = radial_dir (从中心轴指向车的径向方向)
##           弧面: 同圆柱
##   duration: 窗口长度. 默认 0.1s, 机关每帧重置即可保持激活
##
## 内部行为:
##   _anti_gravity_normal = normal
##   _anti_gravity_left = max(_anti_gravity_left, duration)
##   _apply_engine_and_brake / _apply_friction 检测到 _anti_gravity_left > 0 就用这个法线做切平面投影
func apply_anti_gravity_orientation(normal: Vector3, duration: float = 0.1) -> void:
	if normal.length() < 0.001:
		return
	_anti_gravity_normal = normal.normalized()
	_anti_gravity_left = maxf(_anti_gravity_left, duration)


## 公开接口 — 给玩家施加一个"跳跃台冲击" (弹簧蘑菇 / 跳板 / 反重力机关用)
##
## 作用:
##   1) 把 linear_velocity 设为指定值 (覆盖, 不累加 — 调用方自己组装好向量再传)
##   2) 在 skip_stick_seconds 秒内让 _apply_ground_stick 跳过 (绕开防弹/下压力/坡面贴附)
##   3) 立刻把 _is_airborne 标记为 true (空中状态), 让车感觉"真的飞起来了"
##
## 参数:
##   new_velocity: 弹后 car.linear_velocity 直接被设为这个值
##   skip_stick_seconds: 防弹机制跳过窗口长度. 推荐 0.25~0.5
##                       太短 → 弹起后立刻被压回. 太长 → 落地后还在跳过防弹会乱
func apply_jump_pad_kick(new_velocity: Vector3, skip_stick_seconds: float = 0.35) -> void:
	linear_velocity = new_velocity
	_jump_pad_kick_left = maxf(_jump_pad_kick_left, skip_stick_seconds)
	# 立刻进入空中状态, 让 _apply_engine_and_brake / 其他系统按"空中"处理
	_is_airborne = true
	_air_time = 0.0
	# 不清角速度: 机关会在调用后自行设置随机小角速度 (视觉翻滚感)
# ============================================================
# 毒图玩法 - 外部干预通道
# ============================================================
# 毒雾减速倍率: 由 Block_ToxicFog 每帧设置 (车在毒雾区域内时), 1.0=正常, <1.0=减速
# 数学:
#   _toxic_slow_mult 直接乘到引擎力 + 反向给一个阻尼力
#   实际生效在 _apply_engine_and_brake (引擎力 *= mult) 和 _apply_friction (额外加阻尼)
# 0.3 = 引擎只剩 30% + 强阻尼  ;  0.6 = 较温和减速  ;  1.0 = 无影响
# Block_ToxicFog 每帧调 car.set("_toxic_slow_mult", val), 离开毒雾时 set 回 1.0
var _toxic_slow_mult: float = 1.0
# 毒雾额外线性阻尼系数 (1/s). 与 _toxic_slow_mult 配合, _apply_friction 里加这个 damping
# 数学: linear_velocity -= linear_velocity * _toxic_extra_damping * delta
# 0.0 = 无阻尼, 1.0 = 1秒衰减到 1/e ≈ 37%, 2.0 = 0.5s衰减到 37%, 推荐 0.5~2.0
var _toxic_extra_damping: float = 0.0
# 钩索系统节点引用 (由 _spawn_grapple_hook 在 _ready 后填入, 给 _read_input 路由空格键用)
var _grapple_hook: Node = null
# 自由钩索节点引用
var _free_grapple: Node = null
# 钩索释放后车头摆正倒计时 (秒). GrappleHook._release() 设置此值, 每帧递减
# > 0 时在空中朝向对齐代码段中做车头→速度方向的平滑 slerp
# 正常从跳台飞出不会触发 (因为 _grapple_active 从未为 true, GrappleHook 不会设此值)
var _grapple_release_align_left: float = 0.0

# ---- 🦘 跳跃运行时状态 ----
# _jump_cooldown_left: 冷却倒计时, > 0 时按空格也无法跳 (防止连按)
# _jump_double_left: 当前还能用几次"二段跳" (落地后重置成 1, 用一次扣到 0)
# _jump_was_airborne_last_frame: 上一帧是否在空中, 用于检测"刚落地"瞬间触发落地震屏/烟尘
# _jump_pending_landing: 跳跃后还没落地, 用于决定要不要触发落地反馈 (避免普通空中也触发)
# _jump_squash_left: 起跳压扁动画倒计时 (秒). > 0 时 _update_jump_visuals 在 car_mesh 上设缩放
# _jump_squash_total: 当次压扁动画总时长 (用来算插值进度 t = 1 - left/total)
# _jump_flip_left: 二段跳前空翻倒计时 (秒). > 0 时每帧给 car_mesh 加 X 轴转动
# _jump_flip_total: 当次空翻总时长
var _jump_cooldown_left: float = 0.0
var _jump_double_left: int = 0
var _jump_was_airborne_last_frame: bool = false
var _jump_pending_landing: bool = false
var _jump_squash_left: float = 0.0
var _jump_squash_total: float = 0.0
var _jump_flip_left: float = 0.0
var _jump_flip_total: float = 0.0
# === 跳跃豁免窗口 (2026-06-02 用户反馈"跳跃后抽搐+强行改镜头"修复) ===
# 真凶: 跳跃路径上有 5 个独立系统会"消费"跳跃事件造成视觉/物理跳变:
#   1) _apply_landing_physics 落地清角动量 → flip 旋转中突变 = 抽搐
#   2) _pending_landing_w_left / q_left 落地回放 → 自动触发落地喷/起漂 = 改镜头
#   3) _air_boost_armed 跳跃中按 W → 自动空喷 → FOV 推升 = 改镜头
#   4) _landing_stick_left 上次压地窗口残留 → 跳跃 Y 速度被 clamp = 跳不起来
#   5) flip 期间被外部清角动量 → 视觉旋转和物理 transform 错位
# 解决: 用一个"跳跃激活窗口" _jump_active_left, 期间下面这些系统全部豁免
#   起跳时设: _jump_active_left = jump_skip_stick + JUMP_LAND_GRACE
#   落地后再保留 JUMP_LAND_GRACE 让落地反馈 (震屏/烟尘) 自然完成
#   每帧 _physics_process 倒计时, 0 后系统自动恢复正常行为
const JUMP_LAND_GRACE: float = 0.25   # 落地后保留豁免的额外秒数
var _jump_active_left: float = 0.0

# 钩索弹射窗口: 释放钩索后一定时间内按 W 可触发独立的钩索弹射
# _grapple_boost_window_left > 0 表示当前在窗口内
var _grapple_boost_window_left: float = 0.0
# 钩索弹射是否已消耗 (每次释放只能用一次)
var _grapple_boost_used: bool = false
# 起钩绳长比例 (由 GrappleHook 释放时传入, 用于缩放弹射推力)
var _grapple_boost_dist_ratio: float = 0.0
# 钩索氮气弹射是否已触发 (每次释放只能用一次)
var _grapple_nitro_boost_used: bool = false
# 本次钩索拉动时间 (秒, 由 GrappleHook 释放时传入, 用于钩索弹射最小时间判定)
var _grapple_pull_time: float = 0.0
# 本次钩索荡动位移 (米, 由 GrappleHook 释放时传入, 用于钩索弹射位移条件判定)
var _grapple_swing_distance: float = 0.0

# 初始朝向(由 _ready 记录, 用于复位时恢复)
var _initial_car_mesh_basis: Basis = Basis.IDENTITY
var _initial_car_mesh_position: Vector3 = Vector3.ZERO
var _initial_recorded: bool = false
# 复位冻结帧数: > 0 时每帧强制清零速度并锁定位置, 防止复位后被物理弹走
var _reset_freeze_frames: int = 0

# ============================================================
#  Lifecycle
# ============================================================
func _ready() -> void:
	# 初始化 V2 默认曲线(玩家没设时给合理值)
	_init_default_curves()
	# 初始化 QQ飞车漂移系统
	_drift_system = DriftSystemScript.new()
	_sync_drift_system_params()
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
	# 注: 之前为修弯坡抖动加过 lock_rotation=true 和地面每帧清角速度,
	#     但这两改动会让球完全不滚动, 间接抹掉了 PhysicsMaterial.friction 的效果,
	#     导致地面摩擦力肉眼可见变弱. 已回滚, 保持原 RigidBody 行为.
	# trimesh 赛道撞击会同时报告多个三角面 contact, 4 个不够用
	# 撞墙时常见 6~10 个接触点 (车球底+车球侧+车球前等), 调到 16 保证不丢
	max_contacts_reported = 16
	body_entered.connect(_on_body_entered)
	# 撞墙物理参数自检 + 提示 (帮用户识别 cfg 是否调到了不利于撞墙手感的值)
	# 用 timer 延迟 1.5s, 等 Tuner 的 cfg 完全加载完之后再打 log, 看到的才是真正运行时值
	get_tree().create_timer(1.5).timeout.connect(_log_wall_physics_status)

	# 记录 CarMesh 的初始位置和朝向 — 延迟到物理稳定后执行
	# 原因: TrackRunner 在 add_child(car) 之后才设置 CarMesh 的 global_position (因为 top_level=true)
	#        TrackSetup._adjust_car_spawn 会 await 两帧物理后才把 Car 落到地面
	# 所以必须等足够久, 让所有外部调整完成后再记录最终出生点
	call_deferred("_deferred_record_initial_position")

	# 出生时: 直接把刚体对齐到 CarMesh 的位置(你在编辑器里调好的位置)
	call_deferred("_snap_to_car_mesh_origin")

	if auto_spawn_hud and hud_scene:
		call_deferred("_spawn_hud")
	if auto_spawn_tuner and tuner_scene:
		call_deferred("_spawn_tuner")
	if auto_spawn_grapple and grapple_hook_scene:
		call_deferred("_spawn_grapple_hook")
	if auto_spawn_free_grapple:
		call_deferred("_spawn_free_grapple")
	if fx_scene:
		# 不在这里 instantiate, 让 _attach_fx 根据 tailpipe 数量决定挂几个
		call_deferred("_attach_fx")
	if drift_fx_scene:
		drift_fx_node = drift_fx_scene.instantiate()
		call_deferred("_attach_drift_fx")
	# 时间回溯 buffer 初始化 (capacity = 60fps × 配置秒数)
	_rewind_capacity = max(60, int(round(rewind_buffer_seconds * 60.0)))
	_rewind_buffer.resize(_rewind_capacity)
	_rewind_write_idx = 0
	_rewind_size = 0


func _deferred_record_initial_position() -> void:
	# 等 2 帧物理再记录出生点, 确保:
	#   - TrackRunner 的 spawn_pos 设置已生效
	#   - 物理引擎已稳定 (车已落地)
	#   - TrackSetup._adjust_car_spawn 可能还需要额外覆盖 (它 await 2 帧后调 _record_initial_position)
	await get_tree().physics_frame
	await get_tree().physics_frame
	# 如果 TrackSetup 已经覆盖了 (通过直接调 _record_initial_position), 不再重复
	if _initial_recorded:
		return
	_record_initial_position()

func _record_initial_position() -> void:
	# 记录 CarMesh 的当前位置和朝向作为出生点
	# 此时所有外部调整(TrackRunner/TrackSetup)应该已经完成
	if car_mesh:
		_initial_car_mesh_basis = car_mesh.global_transform.basis
		_initial_car_mesh_position = car_mesh.global_position
		_initial_recorded = true
		# 进入地图时自带氮气
		if spawn_nitro_enabled:
			nitro_stock = mini(spawn_nitro_stock, max_nitro_stock)
			emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
		print("[Car] 记录出生点位置: ", _initial_car_mesh_position)


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
#  钩索系统挂接
# ============================================================
# 把 GrappleHook 节点挂在 car 自己下面 (作为子节点), 这样:
#   1. _grapple_active 状态在 car 自己身上, GrappleHook 通过 get_parent() 反向修改
#   2. GrappleHook 的 _physics_process 会自然每帧执行
#   3. 锚点查找走 get_tree().get_nodes_in_group("grapple_anchors") 全局检索
# 不放在 current_scene 上是因为钩索逻辑必须能拿到 car 引用, 挂在 car 下最直接
func _spawn_grapple_hook() -> void:
	if _grapple_hook != null:
		return
	if find_child("GrappleHook", false, false):
		_grapple_hook = get_node_or_null("GrappleHook")
		if _grapple_hook != null and _grapple_hook.has_signal("grapple_boost_window_opened"):
			if not _grapple_hook.is_connected("grapple_boost_window_opened", _on_grapple_boost_window_opened):
				_grapple_hook.connect("grapple_boost_window_opened", _on_grapple_boost_window_opened)
		return
	var hook: Node = grapple_hook_scene.instantiate()
	hook.name = "GrappleHook"
	add_child(hook)
	# 让 GrappleHook 自动用父节点(本 car)作为 RigidBody3D, 不需要额外设 car_path
	_grapple_hook = hook
	# 连接钩索弹射窗口信号
	if hook.has_signal("grapple_boost_window_opened"):
		hook.connect("grapple_boost_window_opened", _on_grapple_boost_window_opened)
	print("[Car] GrappleHook 已挂载")


func _spawn_free_grapple() -> void:
	if _free_grapple != null:
		return
	if find_child("FreeGrapple", false, false):
		_free_grapple = get_node_or_null("FreeGrapple")
		return
	# FreeGrapple 不需要 .tscn, 直接实例化脚本节点
	var fg := Node3D.new()
	fg.name = "FreeGrapple"
	var script: GDScript = load("res://grapple/FreeGrapple.gd") as GDScript
	if script == null:
		return
	fg.set_script(script)
	add_child(fg)
	_free_grapple = fg
	print("[Car] FreeGrapple 已挂载")


func _on_grapple_boost_window_opened(dist_ratio: float, pull_time: float = 0.0, swing_distance: float = 0.0) -> void:
	# 钩索释放成功后, 开启弹射窗口
	if _grapple_hook == null:
		return
	var window_time: float = float(_grapple_hook.get("grapple_boost_window"))
	_grapple_boost_window_left = window_time
	_grapple_boost_used = false
	_grapple_nitro_boost_used = false
	_grapple_boost_dist_ratio = dist_ratio
	_grapple_pull_time = pull_time
	_grapple_swing_distance = swing_distance
	# 钩索释放时重置空喷标记: 钩索拉动期间可能已在空中消耗过空喷,
	# 释放后应允许玩家再次触发空喷 (释放本身算一次新的"起飞")
	_air_boost_armed = false
	_air_boost_armed_left = 0.0
	print("[Car] 弹射窗口开启: %.2fs, 绳长比例=%.2f, 拉动时间=%.2f, 荡动位移=%.1fm" % [window_time, dist_ratio, pull_time, swing_distance])


# ============================================================
#  主循环
# ============================================================
func _physics_process(delta: float) -> void:
	if not car_mesh or not body_mesh:
		return
	# 反重力窗口倒计时 (机关每帧调 apply_anti_gravity_orientation 会重置, 所以这里只是清理过期窗口)
	# 离开反重力机关时, 0.1s 内倒计时归零, _apply_engine_and_brake 自动回到正常 ground_n 切平面
	if _anti_gravity_left > 0.0:
		_anti_gravity_left -= delta
		if _anti_gravity_left <= 0.0:
			_anti_gravity_left = 0.0
			_anti_gravity_normal = Vector3.ZERO
	# === 时间回溯 / 自定义位置模式 优先级最高 ===
	# 这两个模式下不跑正常 3C 逻辑, 完全接管 transform
	if _rewind_active:
		_update_rewind(delta)
		# 仍然要消化输入事件 (不然按其他键会堆积), 但不做物理
		_read_input()
		return
	if _freefly_active:
		_update_freefly(delta)
		_read_input()
		return
	# === 正常 3C 流程 ===
	# 复位冻结: 按 B 复位后短暂锁定位置和速度, 防止被物理弹走
	if _reset_freeze_frames > 0:
		_reset_freeze_frames -= 1
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		global_position = _initial_car_mesh_position - sphere_offset
		if car_mesh:
			car_mesh.global_position = _initial_car_mesh_position
		return
	# 录制当前帧到 rewind buffer (在 _read_input 之前, 这样 R 按下时立即用到的是最新帧)
	if rewind_enabled:
		_record_rewind_frame()
	_read_input()
	_update_boost_timer(delta)
	_update_stack_chain_timeout()    # 叠喷链超时清理
	_update_drift_intensity(delta)    # V2: 平滑的 0~1 漂移强度
	# 退漂推力爆发期倒计时
	if _drift_exit_boost_left > 0.0:
		_drift_exit_boost_left -= delta
		if _drift_exit_boost_left < 0.0:
			_drift_exit_boost_left = 0.0
	# 松前漂移 CD 倒计时 (CD 期内, 再次"松前+踩油门"不给冲量, 只切回普通漂移)
	if _songqian_drift_cd_left > 0.0:
		_songqian_drift_cd_left -= delta
		if _songqian_drift_cd_left < 0.0:
			_songqian_drift_cd_left = 0.0
	# 加速带持续推力倒计时
	if _speed_pad_boost_left > 0.0:
		_speed_pad_boost_left -= delta
		if _speed_pad_boost_left < 0.0:
			_speed_pad_boost_left = 0.0
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

	# car_mesh 视觉位置: 用平滑追随 RigidBody 位置, 而不是 1:1 复制
	# 抖动修复: 球-trimesh 接触每帧让 RigidBody 位置颤动几毫米, 直接复制让视觉车也颤
	# 用一阶低通追随 (tau=0.02s ≈ 1.2 帧), 对真实运动几乎无延迟感, 但能滤掉单帧位置抖动
	# 注意: 只对 Y 分量做平滑 (XZ 1:1, 因为玩家会盯着横向位置, 任何延迟都明显)
	var target_mesh_pos: Vector3 = position + sphere_offset
	if _is_airborne or not _smoothed_normal_initialized:
		# 空中或刚贴地: 直接同步, 不平滑 (避免出生 / 落地视觉延迟)
		car_mesh.position = target_mesh_pos
	else:
		# 贴地状态: Y 分量加平滑滤波. 这是抖动最明显的方向 (球 Y 因接触点切换抖)
		const MESH_POS_TAU: float = 0.02
		var alpha: float = 1.0 - exp(-delta / MESH_POS_TAU)
		var cur: Vector3 = car_mesh.position
		# X/Z 直接同步 (横向运动延迟玩家最敏感), Y 用低通
		car_mesh.position = Vector3(target_mesh_pos.x, lerpf(cur.y, target_mesh_pos.y, alpha), target_mesh_pos.z)

	# 地面判定: 优先 ground_ray, 但如果 ray 因抬升/接缝偶尔脱离, 再做一次"短程宽探测"
	# 避免一帧物理全跳过造成的顿挫
	var on_ground: bool = ground_ray != null and ground_ray.is_colliding()
	if not on_ground:
		on_ground = _fallback_ground_check()
	# === 关键: 每帧更新平滑路面法线, 让所有用法都拿到去抖后的法线 ===
	# 这是抖动修复的核心 — trimesh 三角形切换让 raw 法线每帧抖几度,
	# 这里统一过滤一次, 后面 _apply_ground_stick / _apply_engine_and_brake (slope_align_thrust)
	# / _update_visuals (贴坡) 全都用 _smoothed_ground_normal 而不是各自重新读 raw.
	_update_smoothed_ground_normal(delta, on_ground)
	# 起飞/落地检测 + 空喷/落地喷处理
	_update_air_state(delta, on_ground)
	# 跳跃倒计时 + 落地反馈 (震屏/烟尘/重置二段跳)
	# 必须在 _update_air_state 之后, 这样 _is_airborne 已经更新
	_update_jump_state(delta, on_ground)
	if on_ground:
		# 注: 之前为修弯坡抖动加过 angular_velocity = Vector3.ZERO,
		#     但配合 lock_rotation=true 一起会让 friction 失效, 已回滚.
		if qqspeed_drift_enabled and _drift_system != null and _drift_system.is_drifting:
			# QQ飞车漂移系统: 漂移中由 DriftSystem 统一处理力和扭矩
			_apply_qqspeed_drift(delta)
			_apply_ground_stick(delta)
		else:
			_apply_engine_and_brake(delta)
			_apply_friction(delta)
			_apply_ground_stick(delta)

	# 喷射推力: 无论空中/地面都施加(空中时按 boost_air_efficiency 缩放)
	_apply_boost_thrust(delta)

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
	# Rewind / FreeFly 期间完全屏蔽 3C 输入 (避免 W 触发氮气, Q 触发漂移等)
	if _rewind_active or _freefly_active:
		throttle_input = 0.0
		steer_input = 0.0
		return

	# 双人模式: 根据 player_id 选择不同的输入 action
	var act_accel: String = "accelerate" if player_id == 0 else "p2_accelerate"
	var act_brake: String = "brake" if player_id == 0 else "p2_brake"
	var act_steer_r: String = "steer_right" if player_id == 0 else "p2_steer_right"
	var act_steer_l: String = "steer_left" if player_id == 0 else "p2_steer_left"
	var act_drift: String = "drift" if player_id == 0 else "p2_drift"
	var act_boost: String = "boost" if player_id == 0 else "p2_boost"
	var act_nitro: String = "nitro" if player_id == 0 else "p2_nitro"
	var act_grapple: String = "grapple" if player_id == 0 else "p2_grapple"

	throttle_input = Input.get_axis(act_brake, act_accel)
	steer_input = Input.get_axis(act_steer_r, act_steer_l)

	# 2P 手柄摇杆: 基于角度的前进/刹车判定
	# 360° 圆形中只有最下方 40° (±20°) 视为刹车, 其余 320° 都视为前进
	if player_id == 1:
		var raw_x: float = Input.get_axis("p2_steer_left", "p2_steer_right")  # -1=左, +1=右
		var raw_y: float = Input.get_axis("p2_accelerate", "p2_brake")        # -1=上, +1=下
		var stick_len: float = Vector2(raw_x, raw_y).length()
		if stick_len > 0.15:  # 摇杆有有效输入 (超过死区)
			# 计算摇杆角度: atan2(y, x), 纯向下=90°, 纯向上=-90°
			var angle_deg: float = rad_to_deg(atan2(raw_y, raw_x))
			# 只有角度在 70°~110° (纯向下 ±20°) 时才算刹车
			# 其他所有方向都视为前进 (throttle_input >= 0)
			var is_brake_zone: bool = (angle_deg >= 70.0 and angle_deg <= 110.0)
			if not is_brake_zone:
				# 不在刹车区: 强制满油门前进
				# 无论摇杆推向哪个方向(左/右/上/斜向), 只要不在刹车区就全速前进
				throttle_input = 1.0
		# 转向保持不变 (steer_input 已经由 get_axis 正确计算)

	# 2P 输入调试: 每秒打印一次输入状态 (帮助诊断手柄是否被正确读取)
	if player_id == 1:
		_p2_debug_timer += get_physics_process_delta_time()
		if _p2_debug_timer >= 1.0:
			_p2_debug_timer = 0.0
			var spd: float = linear_velocity.length()
			print("[Car P1 输入] throttle=%.2f steer=%.2f speed=%.1f airborne=%s" % [throttle_input, steer_input, spd, str(_is_airborne)])

	# 撞墙断漂后: 需要玩家先松开 Q 才能解除"禁止再次入漂"flag
	if _require_release_q and not Input.is_action_pressed(act_drift):
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
	if Input.is_action_just_pressed(act_drift) and not _require_release_q and not _free_grapple_active:
		if player_id == 1:
			print("[Car P1] RB/LB 按下检测到! airborne=%s state=%s" % [str(_is_airborne), State.keys()[state]])
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
					if songqian_back_boost_enabled and Input.is_action_pressed(act_boost):
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
		if not Input.is_action_pressed(act_drift):
			_drift_input_grace_left = 0.0
		else:
			if _try_start_drift():
				_drift_input_grace_left = 0.0
			else:
				_drift_input_grace_left -= get_physics_process_delta_time()
				if _drift_input_grace_left < 0.0:
					_drift_input_grace_left = 0.0

	# W 小喷：NORMAL 时如果刚好蓄满可直接小喷 / DRIFT 时角度够了退漂+小喷
	if Input.is_action_just_pressed(act_boost):
		# 空中按 W: 除了现有"空喷意图缓存", 同时设置落地预输入缓冲
		# 这样如果落地瞬间空喷条件没满足(例如 air_time 太短), 落地后也能回放 W 给落地喷/窗口消费
		if _is_airborne:
			_pending_landing_w_left = landing_input_buffer_time
		_try_boost_w()

	# E 氮气
	if Input.is_action_just_pressed(act_nitro):
		_try_nitro()

	# 空格 钩索/自由钩索 + 跳跃 fallback
	#
	# 优先级: 自由钩索 (若启用) > 原钩索 > 跳跃
	#   自由钩索 enabled + 有充能/正在飞行中 → 自由钩索消费
	#   自由钩索 disabled → 走原钩索逻辑
	#   原钩索 IDLE + try_fire 钩到锚点 → 进入钩索流程, 不跳
	#   原钩索 IDLE + try_fire 失败 → fallback _try_jump()
	#   原钩索 非 IDLE → 钩索处理释放, 不跳
	if Input.is_action_just_pressed(act_grapple):
		var consumed: bool = false
		# ---- 自由钩索优先 ----
		if _free_grapple != null and bool(_free_grapple.get("free_grapple_enabled")):
			var fg_state: int = int(_free_grapple.get("state"))
			var fg_charges: int = int(_free_grapple.get("_charges"))
			var fg_launched: bool = bool(_free_grapple.get("_has_launched"))
			# IDLE + 有充能 → 触发拉起
			if fg_state == 0 and fg_charges > 0:
				_free_grapple.call("_trigger_pull")
				consumed = true
			# FALLING + 已发射 + 有充能 → 接续下一次钩索 (空中连续使用)
			elif fg_state == 2 and fg_launched and fg_charges > 0:
				_free_grapple.call("_trigger_pull")
				consumed = true
			# FALLING + 未发射 → 触发弹射
			elif fg_state == 2 and not fg_launched:
				_free_grapple.call("_trigger_launch")
				consumed = true
			# PULLING / LAUNCHING 中 → 消费掉空格(不做任何事, 防止误触跳跃)
			elif fg_state != 0:
				consumed = true
		# ---- 原钩索 (自由钩索未启用或未消费) ----
		if not consumed and _grapple_hook != null and _grapple_hook.has_method("try_fire"):
			# 自由钩索启用时原钩索不生效
			if _free_grapple == null or not bool(_free_grapple.get("free_grapple_enabled")):
				var was_idle: bool = true
				if _grapple_hook.has_method("is_idle"):
					was_idle = bool(_grapple_hook.call("is_idle"))
				var hooked: bool = bool(_grapple_hook.call("try_fire"))
				consumed = hooked or not was_idle
		# ---- fallback 跳跃 ----
		if not consumed:
			_try_jump()
	elif Input.is_action_just_released(act_grapple):
		# 松开空格: 只给原钩索处理释放 (自由钩索不需要松开逻辑)
		if _free_grapple == null or not bool(_free_grapple.get("free_grapple_enabled")):
			if _grapple_hook != null and _grapple_hook.has_method("try_release"):
				_grapple_hook.call("try_release")

	# 2P 复位 (LT 扳机): 类似 B 键的快速回到出生点
	if player_id == 1 and Input.is_action_just_pressed("p2_reset"):
		_reset_to_origin()
		print("[Car] 2P LT: 快速回到出生点")


func _unhandled_input(event: InputEvent) -> void:
	# 双人模式: 2P 不响应键盘事件和手柄按钮事件
	# (2P 的所有输入通过 _read_input 中的 p2_* action 处理, 不走 _unhandled_input)
	if player_id != 0:
		if event is InputEventKey or event is InputEventJoypadButton:
			return
	# R 键: 按住回溯, 松开退出 (用户要求"按住 R 不停倒退")
	# 双击 R 仍然能复位 (300ms 内连按 2 次 = 旧的复位行为)
	if event is InputEventKey and not event.echo:
		var ek: InputEventKey = event
		if ek.keycode == KEY_R or ek.physical_keycode == KEY_R:
			if ek.pressed:
				# 检测双击: 上一次按 R 是不是 < 0.3s 内
				var now: float = Time.get_ticks_msec() / 1000.0
				if now - _last_r_press_t < 0.30:
					# 双击 → 复位到出生点 (旧行为, 给玩家保留)
					_reset_to_origin()
					_last_r_press_t = -999.0
				else:
					_last_r_press_t = now
					if rewind_enabled and not _freefly_active:
						_start_rewind()
			else:
				# 松开 R → 退出回溯
				if _rewind_active:
					_stop_rewind()
			get_viewport().set_input_as_handled()
		# 小键盘 0 (KEY_KP_0): 切换自定义位置模式
		elif (ek.keycode == KEY_KP_0 or ek.physical_keycode == KEY_KP_0) and ek.pressed:
			if player_id == 0 and freefly_enabled and not _rewind_active:
				_toggle_freefly()
			get_viewport().set_input_as_handled()
		# B 键: 快速回到出生点 (任何地图中按 B 立即复位)
		elif (ek.keycode == KEY_B or ek.physical_keycode == KEY_B) and ek.pressed:
			_reset_to_origin()
			print("[Car] B 键: 快速回到出生点")
			get_viewport().set_input_as_handled()


func _reset_to_origin() -> void:
	if not _initial_recorded:
		_auto_place_on_ground()
		return
	# 安全检查: 如果出生点在原点附近 (可能是未正确初始化), 打印警告
	if _initial_car_mesh_position.length() < 0.1:
		push_warning("[Car] P%d 出生点异常 (接近原点), 尝试 _auto_place_on_ground" % player_id)
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
	# 退出钩索状态
	if _grapple_hook and _grapple_hook.has_method("force_release"):
		_grapple_hook.call("force_release")
	# 复位时清空绳子缠绕锚点 (防止复位后绳子还绕着旧路径)
	var coop = get_node_or_null("/root/CoopMode")
	if coop and coop.get("_rope_connected"):
		coop._rope_wrap_points.clear()
	# 出生/复位自带氮气
	if spawn_nitro_enabled:
		nitro_stock = mini(spawn_nitro_stock, max_nitro_stock)
		emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)
	# 短暂冻结物理防止车被弹走 (下一帧 _physics_process 会检查此标志)
	_reset_freeze_frames = 3
	emit_signal("reset_to_origin_triggered")
	print("[Car] P%d 已复位到出生点: pos=%s basis_z=%s" % [player_id, str(_initial_car_mesh_position), str(_initial_car_mesh_basis.z)])


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
	# 漂移额外能耗曲线: X=漂移时间归一化, Y=能耗倍率. 默认前期低后期高
	if drift_extra_decel_curve == null:
		var c6b := Curve.new()
		c6b.add_point(Vector2(0.0, 0.5))
		c6b.add_point(Vector2(0.4, 0.8))
		c6b.add_point(Vector2(0.7, 1.0))
		c6b.add_point(Vector2(1.0, 1.5))
		drift_extra_decel_curve = c6b
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
	# 惯性感速度曲线: X=speed/top_speed, Y=惯性感倍率
	#   低速(0~0.3): Y=1.0 → 满惯性, 外移多好过弯
	#   中速(0.3~0.6): Y=0.7 → 逐渐收
	#   高速(0.6~1.0): Y=0.3 → 惯性感很弱, 控制车不飞出去
	if drift_inertia_speed_curve == null:
		var c_inertia := Curve.new()
		c_inertia.add_point(Vector2(0.0, 1.0))
		c_inertia.add_point(Vector2(0.3, 1.0))
		c_inertia.add_point(Vector2(0.6, 0.7))
		c_inertia.add_point(Vector2(1.0, 0.3))
		drift_inertia_speed_curve = c_inertia
	# 漂移超速刹车强度随时间变化曲线:
	#   前期(0~0.4): 0.0~0.1 → 刚入漂几乎不掉速, 保持冲劲
	#   中期(0.4~0.7): 0.1~0.6 → 逐渐开始拖
	#   后期(0.7~1.0): 0.6~1.4 → 长时间漂越拖越凶, 迫使玩家早点退漂
	if drift_speed_brake_curve == null:
		var c11 := Curve.new()
		c11.add_point(Vector2(0.0, 0.0))
		c11.add_point(Vector2(0.4, 0.1))
		c11.add_point(Vector2(0.7, 0.6))
		c11.add_point(Vector2(1.0, 1.4))
		drift_speed_brake_curve = c11
	# 漂移低速推力曲线: 速度越低推力越大(X=0静止→最大推力, X=1阈值速度→推力消失)
	if drift_low_speed_push_curve == null:
		var c11b := Curve.new()
		c11b.add_point(Vector2(0.0, 1.5))
		c11b.add_point(Vector2(0.3, 1.2))
		c11b.add_point(Vector2(0.7, 0.6))
		c11b.add_point(Vector2(1.0, 0.0))
		drift_low_speed_push_curve = c11b
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

## 同步 QQ飞车漂移系统参数 (从 car 的 export 变量同步到 DriftSystem 实例)
func _sync_drift_system_params() -> void:
	if _drift_system == null:
		return
	_drift_system.start_vec = qqsd_start_vec
	_drift_system.end_vec_first = qqsd_end_vec_first
	_drift_system.end_vec_second = qqsd_end_vec_second
	_drift_system.slid_fric_force = qqsd_slid_fric_force
	_drift_system.roll_fric_force = qqsd_roll_fric_force
	_drift_system.banner_angle_deg = qqsd_banner_angle_deg
	_drift_system.dir_key_twist = qqsd_dir_key_twist
	_drift_system.dir_key_twist_param_a = qqsd_dir_key_twist_param_a
	_drift_system.dir_key_twist_param_b = qqsd_dir_key_twist_param_b
	_drift_system.banner_key_twist = qqsd_banner_key_twist
	_drift_system.banner_key_twist_param_a = qqsd_banner_key_twist_param_a
	_drift_system.banner_key_twist_param_b = qqsd_banner_key_twist_param_b
	_drift_system.banner_twist = qqsd_banner_twist
	_drift_system.banner_twist_param_a = qqsd_banner_twist_param_a
	_drift_system.max_wec = qqsd_max_wec
	_drift_system.dir_key_force = qqsd_dir_key_force
	_drift_system.dir_up_key_force = qqsd_dir_up_key_force
	_drift_system.banner_vec_force = qqsd_banner_vec_force
	_drift_system.release_key_force = qqsd_release_key_force
	_drift_system.wall_crash_speed_mult = qqsd_wall_crash_speed_mult
	_drift_system.vec_effect = qqsd_vec_effect
	_drift_system.wec_effect = qqsd_wec_effect
	_drift_system.visual_enabled = qqspeed_drift_visual

## QQ飞车漂移物理: 每帧调用, 替代旧的 _apply_friction + _apply_engine_and_brake 中的漂移部分
func _apply_qqspeed_drift(delta: float) -> void:
	if _drift_system == null or not _drift_system.is_drifting:
		return
	# 同步参数 (Tuner 可能随时改)
	_sync_drift_system_params()
	# 准备输入
	var v_horiz: Vector3 = linear_velocity
	v_horiz.y = 0.0
	var speed: float = v_horiz.length()
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	forward.y = 0.0
	if forward.length() > 0.001:
		forward = forward.normalized()
	var velocity_dir: Vector3 = Vector3.ZERO
	if speed > 0.5:
		velocity_dir = v_horiz.normalized()
	else:
		velocity_dir = forward
	var shift_pressed: bool = Input.is_action_pressed(_act("drift"))
	# 调用 DriftSystem 更新
	var result: Dictionary = _drift_system.update(
		delta, speed, forward, velocity_dir,
		steer_input, throttle_input, shift_pressed, _is_airborne
	)
	# 处理退漂
	if result["exit_drift"]:
		var is_normal: bool = result["exit_normal"]
		# 撞墙速度衰减
		var wall_mult: float = result["wall_speed_mult"]
		if wall_mult < 1.0:
			linear_velocity *= wall_mult
		# 退漂钳速
		var clamp_spd: float = result["clamp_speed"]
		if clamp_spd > 0.0:
			var cur_h_speed: float = Vector3(linear_velocity.x, 0, linear_velocity.z).length()
			if cur_h_speed > clamp_spd:
				var ratio: float = clamp_spd / cur_h_speed
				linear_velocity.x *= ratio
				linear_velocity.z *= ratio
		_drift_system.end_drift(is_normal)
		_end_drift(is_normal, false, not is_normal)
		return
	# 施加力
	# 沿速度方向的力 (加速/减速)
	var force_along: float = result["force_along_velocity"]
	if absf(force_along) > 0.001 and speed > 0.5:
		apply_central_force(velocity_dir * force_along * mass)
	elif absf(force_along) > 0.001:
		apply_central_force(forward * force_along * mass)
	# 侧向力 (回扳侧推)
	var force_lat: float = result["force_lateral"]
	if absf(force_lat) > 0.001:
		var right: Vector3 = car_mesh.global_transform.basis.x
		right.y = 0.0
		if right.length() > 0.001:
			right = right.normalized()
		apply_central_force(right * force_lat * mass)
	# 扭矩 → 直接旋转车头 (通过 angular_velocity 或直接旋转 car_mesh)
	# QQ飞车的扭矩是控制车头旋转, 不是物理刚体扭矩
	var torque_yaw: float = _drift_system.drift_angular_velocity
	if absf(torque_yaw) > 0.001:
		var yaw_rad: float = torque_yaw * delta
		var new_basis: Basis = car_mesh.global_transform.basis.rotated(Vector3.UP, yaw_rad)
		car_mesh.global_transform.basis = new_basis.orthonormalized()


# ============================================================
#  V2 - 引擎动力 + 刹车(带曲线)
# ============================================================
func _apply_engine_and_brake(_delta: float) -> void:
	# === 钩索抑制引擎 ===
	# 钩索激活时, 如果 GrappleHook 配置了 disable_engine_during_pull, 完全跳过引擎/刹车/助力等
	# 让钩索拉力主导. 摩擦/重力/碰撞等其他力照常生效, 只是玩家油门不再起作用.
	# 数学含义: F_total 在钩索期间 = F_grapple + F_friction + F_gravity, 而不再叠加 F_engine
	# 这避免了"玩家踩油门 vs 钩索拉力"互相打架, 也让玩家能体验到"被绳子拽着无法挣脱"的手感
	if _grapple_active and _grapple_hook != null and bool(_grapple_hook.get("disable_engine_during_pull")):
		return
	# 自由钩索期间也抑制引擎力 (拉力/重力减弱由 FreeGrapple 自己管)
	if _free_grapple_active:
		return
	# === 视觉车头方向 ===
	# car_mesh.basis.z = 骨架朝向(被 steer 控制), 但漂移时车壳额外被拧过 drift_yaw_offset
	# 所以"玩家眼睛看到的车头" = 骨架朝向 × body_mesh.rotation.y
	# 推力沿这个方向施加, 漂移时按 W 推力就是冲着尖尖去的, 不会感觉"沿镜头方向"
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	if body_mesh and absf(body_mesh.rotation.y) > 0.001:
		var b: Basis = car_mesh.global_transform.basis.rotated(car_mesh.global_transform.basis.y, body_mesh.rotation.y)
		forward = -b.z
	# 坡面切向: forward 投影到"地面切平面"上(消除垂直分量), 保证推力沿坡面走
	# 用 raw collision_normal 而不是 _smoothed_ground_normal:
	# 旧 bug: 用平滑法线时, 刚上坡的 1 个 tau 时间窗 (~60ms) 内 thrust_dir.y 仍是 0,
	#         going_uphill 判定失败 → 重力补偿/上坡助力全跳过 → 车开不上坡.
	# 修复: 物理力相关的法线读 raw, 拿到当前帧的真实坡度. 只有视觉贴坡 (_update_visuals)
	#       才用平滑法线避免视觉颤抖.
	#
	# 反重力优先级最高: 反重力窗口激活时, 用机关推过来的法线 (墙面/圆柱/弧面的外法线)
	# 替代 ground_ray 法线. 这样玩家按前 = 沿反重力面切线方向, 不会冲出墙
	var ground_n: Vector3 = Vector3.UP
	if _anti_gravity_left > 0.0 and _anti_gravity_normal.length_squared() > 0.01:
		# 反重力贴附面优先 (墙面/圆柱/弧面的外法线)
		ground_n = _anti_gravity_normal
	elif ground_ray and ground_ray.is_colliding():
		var raw_gn: Vector3 = ground_ray.get_collision_normal().normalized()
		if raw_gn.length_squared() >= 0.01:
			ground_n = raw_gn
	var thrust_dir: Vector3 = forward
	# DEBUG: 每 60 帧打印一次引擎 forward 方向，跟跳跃对比
	if Engine.get_physics_frames() % 60 == 0 and throttle_input > 0.5:
		print("[ENGINE] forward=", forward, " basis.z=", car_mesh.global_transform.basis.z, " body.rot.y=", rad_to_deg(body_mesh.rotation.y) if body_mesh else 0)
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
	# 加速带持续期内, 顶速也放宽到喷射极速, 让加速带能把速度顶上去
	if _speed_pad_boost_left > 0.0:
		effective_top = maxf(effective_top, top_speed_boosted)
	# 叠喷突破: 当前段处于突破状态时, 极速被临时拔高
	if is_boosting and _stack_current_breakthrough and _stack_breakthrough_count > 0:
		effective_top *= pow(stack_breakthrough_top_mult, _stack_breakthrough_count)
	# 钩索叠喷突破 (独立参数)
	if is_boosting and _grapple_stack_current_breakthrough and _grapple_stack_breakthrough_count > 0:
		var g_mult: float = 1.25
		if _grapple_hook:
			g_mult = float(_grapple_hook.get("grapple_stack_breakthrough_mult"))
		effective_top *= pow(g_mult, _grapple_stack_breakthrough_count)
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
		# 【bug 修复 2026-05-13】之前用 long_speed (= v 投影到车头方向):
		#   玩家边按前进边转向时, 车头持续旋转, long_speed = current_speed × cos(夹角) 永远 < current_speed,
		#   于是 long_speed 永远 < effective_top, 引擎一直加力, current_speed 突破极速无限增长.
		# 改用 current_speed (实际水平速度大小), 让"速度大小"真正受 effective_top 约束.
		if current_speed < effective_top:
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

	# 【已移至 _apply_boost_thrust】喷射推力 / 加速带持续推力 / 空喷下压力
	# 现在独立于 on_ground 判定, 空中也能施加喷射推力

	# ============ 反打减速 ============
	# 漂移中反打(steer 与 drift_dir 异号)时, 沿 -v_horiz 方向施加减速力
	if drift_counter_decel_enabled and state == State.DRIFT and drift_dir != 0.0 and current_speed > 1.0:
		var steer_sign: float = signf(steer_input)
		if steer_sign != 0.0 and steer_sign != signf(drift_dir):
			var steer_mag: float = absf(steer_input)
			if steer_mag >= drift_counter_decel_min_steer:
				var brake_dir: Vector3 = -v_horiz.normalized()
				var brake_force: float = drift_counter_decel * steer_mag * mass
				apply_central_force(brake_dir * brake_force)
				# ============ 反打+前进 额外向前摩擦 (旧机制, 同上绕过) ============
				if drift_counter_throttle_friction_enabled and throttle_input > 0.05:
					var fric_force: float = drift_counter_throttle_friction * steer_mag * throttle_input * mass
					apply_central_force(-forward * fric_force)


# ============================================================
#  喷射推力: 独立于引擎/摩擦, 空中/地面都施加
#  空中时按 boost_air_efficiency 缩放推力
# ============================================================
func _apply_boost_thrust(_delta: float) -> void:
	var forward: Vector3 = -car_mesh.global_transform.basis.z
	forward.y = 0.0
	if forward.length() > 0.001:
		forward = forward.normalized()
	else:
		forward = Vector3.FORWARD

	var v_horiz: Vector3 = linear_velocity
	v_horiz.y = 0.0
	var current_speed: float = v_horiz.length()

	# ============ 空中喷射: 冲量 + 极速限制 ============
	# 空中有独立的极速限制 (air_top_speed), 空中叠喷可突破此限制
	if _is_airborne and is_boosting and boost_power > 0.0:
		var vel_dir: Vector3 = v_horiz
		if vel_dir.length() > 1.0:
			vel_dir = vel_dir.normalized()
		else:
			vel_dir = forward
		# 空中极速计算: 基础 air_top_speed, 叠喷突破时提升
		# 钩索弹射/钩索氮气弹射使用 top_speed_boosted 作为基础 (不被较低的 air_top_speed 限住)
		var air_effective_top: float = air_top_speed
		if boost_type == "grapple_boost" or boost_type == "grapple_nitro":
			air_effective_top = maxf(top_speed_boosted, air_top_speed)
		# 普通叠喷突破
		if _stack_current_breakthrough and _stack_breakthrough_count > 0:
			air_effective_top *= pow(stack_breakthrough_top_mult, _stack_breakthrough_count)
		# 钩索叠喷突破
		if _grapple_stack_current_breakthrough and _grapple_stack_breakthrough_count > 0:
			var g_mult: float = 1.25
			if _grapple_hook:
				g_mult = float(_grapple_hook.get("grapple_stack_breakthrough_mult"))
			air_effective_top *= pow(g_mult, _grapple_stack_breakthrough_count)
		air_effective_top = maxf(air_effective_top, 1.0)
		# 只有当前速度 < 空中极速时才施加冲量
		if current_speed < air_effective_top:
			# 冲量 = boost_power × air_efficiency × delta (等效加速度直接加到速度)
			var impulse_strength: float = boost_power * boost_air_efficiency * _delta
			apply_central_impulse(vel_dir * impulse_strength * mass)
		# 空中喷射不走下面的地面逻辑, 直接处理加速带后返回
		if _speed_pad_boost_left > 0.0:
			var pad_dir: Vector3 = forward
			var pad_progress: float = clampf(_speed_pad_boost_left / maxf(_speed_pad_boost_total, 0.01), 0.0, 1.0)
			if current_speed < air_effective_top:
				apply_central_impulse(pad_dir * _speed_pad_boost_power * pad_progress * _delta * mass)
		# 空喷滞空感 (下压力)
		if boost_type == "air" and air_boost_downforce > 0.0:
			apply_central_force(Vector3(0.0, -air_boost_downforce, 0.0) * mass)
		return

	# ============ 地面喷射: 持续力 + 极速限制 ============
	# 当前生效的极速
	var effective_top: float = top_speed_boosted if is_boosting else max_speed
	if _speed_pad_boost_left > 0.0:
		effective_top = maxf(effective_top, top_speed_boosted)
	if is_boosting and _stack_current_breakthrough and _stack_breakthrough_count > 0:
		effective_top *= pow(stack_breakthrough_top_mult, _stack_breakthrough_count)
	# 钩索叠喷突破 (独立参数)
	if is_boosting and _grapple_stack_current_breakthrough and _grapple_stack_breakthrough_count > 0:
		var g_mult2: float = 1.25
		if _grapple_hook:
			g_mult2 = float(_grapple_hook.get("grapple_stack_breakthrough_mult"))
		effective_top *= pow(g_mult2, _grapple_stack_breakthrough_count)
	if state == State.DRIFT and drift_max_speed > 0.0:
		var dms: float = drift_max_speed
		if _is_drift_nitro():
			dms *= drift_nitro_max_speed_mult
		effective_top = minf(effective_top, dms)
	effective_top = maxf(effective_top, 1.0)

	# 地面法线
	var ground_n: Vector3 = Vector3.UP
	if ground_ray and ground_ray.is_colliding():
		var raw_gn: Vector3 = ground_ray.get_collision_normal().normalized()
		if raw_gn.length_squared() >= 0.01:
			ground_n = raw_gn

	# 喷射推力沿车头方向 (跟引擎力方向一致, 不沿速度方向)
	# 退漂时速度方向偏离车头很大, 如果沿速度方向推会失控
	# 只有空中喷射和机关关联(加速带)才沿速度方向
	if is_boosting and current_speed < effective_top:
		var thrust_dir: Vector3 = forward
		# 【三喷特殊】songqian_back 的推力沿车头反方向 (-forward)
		if boost_type == "songqian_back":
			thrust_dir = car_mesh.global_transform.basis.z   # +Z 是车尾方向
			thrust_dir.y = 0.0
			if thrust_dir.length() > 0.001:
				thrust_dir = thrust_dir.normalized()
		# 喷射推力投影到坡面切向(防止上坡时喷射向斜上, 导致飞车/脱地)
		if slope_align_thrust and not _is_airborne:
			var dir_on_slope: Vector3 = thrust_dir - ground_n * thrust_dir.dot(ground_n)
			if dir_on_slope.length() > 0.001:
				thrust_dir = dir_on_slope.normalized()
		apply_central_force(thrust_dir * boost_power * mass)

	# ============ 加速带 / 弹射器 持续推力 ============
	if _speed_pad_boost_left > 0.0 and current_speed < effective_top:
		var pad_dir: Vector3 = forward
		if slope_align_thrust and not _is_airborne:
			var pad_on_slope: Vector3 = pad_dir - ground_n * pad_dir.dot(ground_n)
			if pad_on_slope.length() > 0.001:
				pad_dir = pad_on_slope.normalized()
		var pad_progress: float = clampf(_speed_pad_boost_left / maxf(_speed_pad_boost_total, 0.01), 0.0, 1.0)
		apply_central_force(pad_dir * _speed_pad_boost_power * pad_progress * mass)

	# ============ 空喷滞空感 (下压力) ============
	if is_boosting and boost_type == "air" and _is_airborne and air_boost_downforce > 0.0:
		apply_central_force(Vector3(0.0, -air_boost_downforce, 0.0) * mass)

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
	# 钩索叠喷突破 (独立参数)
	if is_boosting and _grapple_stack_current_breakthrough and _grapple_stack_breakthrough_count > 0:
		var g_mult3: float = 1.25
		if _grapple_hook:
			g_mult3 = float(_grapple_hook.get("grapple_stack_breakthrough_mult"))
		ref_speed *= pow(g_mult3, _grapple_stack_breakthrough_count)
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
	# 数学: inertia_mult = 1 - drift_inertia_boost × drift_intensity × speed_curve_sample
	#   speed_curve: X = 当前速度/巡航极速 (0~1), Y = 惯性感倍率 (0~1)
	#     低速 Y 高 → 惯性感强 → 外移多好过弯
	#     高速 Y 低 → 惯性感弱 → 控制车不飞出去
	#   没配曲线时默认 Y=1 (全速域等效, 跟旧行为一致)
	# 退漂时立即取消 (不跟 drift_intensity 渐退), 直到下一次入漂才重新生效
	if _drift_inertia_active and drift_inertia_boost > 0.0:
		var speed_t: float = clampf(v.length() / maxf(drift_inertia_speed_ref, 1.0), 0.0, 1.0)
		var speed_k: float = _sample_curve_safe(drift_inertia_speed_curve, speed_t, 1.0)
		var inertia_mult: float = clampf(1.0 - drift_inertia_boost * drift_intensity * speed_k, 0.0, 1.0)
		long_k *= inertia_mult
		lat_k *= inertia_mult

	# -------- 【反打 = 侧向抓地下降】--------
	# 反打时侧向抓地系数下降, 让车顺惯性甩出去
	if state == State.DRIFT and drift_dir != 0.0 and drift_counter_lat_grip_mult < 1.0:
		var s_sign: float = signf(steer_input)
		if s_sign != 0.0 and s_sign != signf(drift_dir):
			var s_mag: float = absf(steer_input)
			if s_mag >= drift_counter_decel_min_steer:
				var thr: float = drift_counter_decel_min_steer
				var cs: float = clampf((s_mag - thr) / maxf(1.0 - thr, 0.001), 0.0, 1.0)
				var grip_mult: float = lerpf(1.0, drift_counter_lat_grip_mult, cs)
				lat_k *= grip_mult

	# === 钩索摩擦削减 ===
	# 钩索激活时, 按 friction_mult_during_pull 倍率削减前后/侧向摩擦
	# 让车被拉得更顺, 不至于摩擦把拉力吃掉
	# 数学: long_k *= mult, lat_k *= mult.   mult=0 → 完全无摩擦; mult=1 → 不变; mult=0.2 → 削 80%
	if _grapple_active and _grapple_hook != null:
		var grapple_friction_mult: float = float(_grapple_hook.get("friction_mult_during_pull"))
		long_k *= grapple_friction_mult
		lat_k  *= grapple_friction_mult
	# 自由钩索期间: 摩擦大幅削减让拉力能有效把车拉起来
	if _free_grapple_active:
		long_k *= 0.1
		lat_k  *= 0.1

	# === 绳子(CoopMode)摩擦削减 ===
	# 后车被绳子拉着卡墙时, CoopMode 会设置 _rope_friction_mult < 1.0
	# 降低摩擦让后车能被前车拉动, 不至于摩擦把拉力完全吃掉
	if _rope_friction_mult < 1.0:
		long_k *= _rope_friction_mult
		lat_k  *= _rope_friction_mult

	# === 毒图毒雾区减速 (Block_ToxicFog) ===
	# 玩法: 进入毒雾区域 → 引擎力 + 摩擦双重削减, 强迫玩家用氮气/小喷顶过去
	# 数学:
	#   long_k *= _toxic_slow_mult  (摩擦反过来变小不削减反而抓地? 不, 这里是"被毒雾拖慢"的语义,
	#                                 实际是给一个独立的"反向阻尼"在下面 long_impulse 后施加)
	#   注意: 摩擦削减不能让车减速, 反而让车更滑. 真正的减速来自 _toxic_extra_damping
	#         所以这里只是占位, 真正生效是下面的"额外阻尼"分支
	# 由 Block_ToxicFog 每帧 set("_toxic_slow_mult", v) + set("_toxic_extra_damping", d)
	# 不在毒雾区时这两个值=1.0/0.0, 此分支 no-op

	# 沿各自速度分量反方向施加冲量
	var long_impulse: Vector3 = -forward * v_long * long_k * delta
	var lat_impulse: Vector3  = -right   * v_lat  * lat_k  * delta
	apply_central_impulse((long_impulse + lat_impulse) * mass)

	# === 毒雾额外阻尼 (Block_ToxicFog 设置) ===
	# 数学: 给一个独立的速度衰减脉冲, 与已有摩擦/引擎独立
	#   damp_imp = -linear_velocity * _toxic_extra_damping * delta * mass
	# 推导: 一阶阻尼方程 dv/dt = -k*v 的离散化, k=_toxic_extra_damping
	#       这样 v(t) = v0 * exp(-k*t), k=1.0 → 1秒后衰减到 1/e ≈ 36.8%
	# 注意: 这是无方向偏向的纯衰减, 不影响转向, 只是"拖慢"
	if _toxic_extra_damping > 0.001:
		var v_now: Vector3 = linear_velocity
		# 不衰减 Y 方向 (重力/跳跃保持原样, 只拖慢水平移动)
		var v_horiz: Vector3 = Vector3(v_now.x, 0.0, v_now.z)
		var damp_dv: Vector3 = -v_horiz * _toxic_extra_damping * delta
		apply_central_impulse(damp_dv * mass)

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

	# -------- 【漂移低速推力】--------
	# 入弯时速度过低, 给予玩家朝车头方向+原速度方向的推力帮助起速
	# 条件: 处于漂移状态 && 速度低于阈值
	# 数学: F = (forward×(1-ratio) + velocity_dir×ratio) × push × curve × mass
	if state == State.DRIFT and drift_low_speed_push > 0.0 and drift_intensity > 0.01:
		var push_threshold_speed: float = drift_min_speed * drift_low_speed_push_threshold
		if total_speed < push_threshold_speed:
			var speed_ratio_push: float = clampf(total_speed / maxf(push_threshold_speed, 0.01), 0.0, 1.0)
			var push_curve_k: float = _sample_curve_safe(drift_low_speed_push_curve, speed_ratio_push, 1.0)
			# 车头方向
			var push_fwd: Vector3 = -car_mesh.global_transform.basis.z
			push_fwd.y = 0.0
			if push_fwd.length() > 0.001:
				push_fwd = push_fwd.normalized()
			# 原速度方向(有速度时用速度方向, 无速度时退化为车头方向)
			var push_vel: Vector3 = push_fwd
			if total_speed > 0.5:
				push_vel = v.normalized()
			# 混合: ratio=0 全车头, ratio=1 全速度方向
			var push_dir: Vector3 = push_fwd.lerp(push_vel, drift_low_speed_push_velocity_ratio).normalized()
			apply_central_force(push_dir * drift_low_speed_push * push_curve_k * mass)

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
		var decel_t_norm: float = clampf(drift_elapsed / maxf(drift_head_yaw_duration_ref, 0.01), 0.0, 1.0)
		var decel_curve_k: float = _sample_curve_safe(drift_extra_decel_curve, decel_t_norm, 1.0)
		var decel_mult: float = lerpf(1.0, drift_extra_decel_songqian_mult, clampf(_drift_slip_factor, 0.0, 1.0))
		apply_central_force(-v.normalized() * drift_extra_decel * decel_curve_k * drift_intensity * decel_mult * mass)


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
#  🦘 跳跃系统
# ============================================================
# 用户需求 (2026-06-02): 当空格找不到钩索锚点时, fallback 到跳跃
#
# 调用方: _read_input 在 _grapple_hook.try_fire() 返回 false 且 was_idle=true 时调用
#         (即"在 IDLE 状态尝试钩索但找不到锚点")
#
# 跳跃判定:
#   1) jump_enabled = false → 不跳
#   2) _jump_cooldown_left > 0 → 冷却中不跳 (防止连按)
#   3) state==DRIFT 且 jump_allow_in_drift=false → 漂移中不跳
#   4) 钩索 ATTACHED → 不跳 (其实 was_idle 检查已过滤, 这里冗余防御)
#   5) on_ground → 一段跳 (jump_impulse), 重置 _jump_double_left = 1 (二段跳次数)
#   6) 空中 + jump_double_enabled + _jump_double_left > 0 → 二段跳 (jump_double_impulse)
#       - 视觉: 给 car_mesh 绕 X 轴前空翻 (jump_air_flip_speed × 1s)
#   7) 其他 (空中 + 已用完二段跳) → 不跳
func _try_jump() -> void:
	if not jump_enabled:
		return
	if _jump_cooldown_left > 0.0:
		return
	# 漂移中拦截 (除非允许)
	if state == State.DRIFT and not jump_allow_in_drift:
		return
	# 钩索/自由钩索中不跳
	if _grapple_active or _free_grapple_active:
		return

	# 当前是否在地面 (优先 ground_ray, 兜底 fallback 短程探测)
	var on_ground: bool = (ground_ray != null and ground_ray.is_colliding()) or _fallback_ground_check()

	# 决定跳跃类型 + 冲量
	var impulse_y: float = 0.0
	var is_double: bool = false
	if on_ground:
		# 一段跳: 落地时重置二段跳次数 (即使没用过, 触地后重置成 1)
		impulse_y = jump_impulse
		_jump_double_left = 1   # 跳起来后还能再用 1 次二段跳
	elif jump_double_enabled and _jump_double_left > 0:
		# 二段跳
		impulse_y = jump_double_impulse
		_jump_double_left -= 1
		is_double = true
	else:
		# 不允许跳
		return

	# === 应用跳跃冲量 (2026-06-02 v5: 重定向到车头方向 + 保留角速度) ===
	#
	# 用户反馈历程:
	#   v1 (保留 v.xz × 0.95):       "不朝车头跳"   ← 转弯/侧滑时 v.xz ≠ 车头
	#   v2 (重定向叠 body_mesh.y):   "每次往右跳"  ← steer 残留让 body_mesh.y ≠ 0
	#   v3 (重定向到 -basis.z + 清角速度): "强行设置车头朝向" ← 角速度被清, 车头冻结
	#   v4 (完全不动只改 Y):         "朝车身右侧跳"  ← v.xz 跟车头不一致 (转弯惯性)
	#   v5 (重定向到 -basis.z + 保留角速度): ← 当前正确版
	#
	# 用户最终诉求 (2026-06-02): "按 W 加速度方向 = 车头方向 = 跳跃方向"
	#   引擎力的 forward 就是 -car_mesh.basis.z, 玩家按 W 加速沿这个方向
	#   跳跃也应该沿这个方向 → 用 -car_mesh.basis.z 重定向水平速度
	#
	# 但 v3 翻车的真凶是 apply_jump_pad_kick 内部 angular_velocity = ZERO
	#   → 玩家在转弯中按空格, 车头瞬间停止旋转 → 感觉"被强行冻结"
	#   → 修复: 跳跃 kick 不清 angular_velocity, 让转弯延续
	#
	# 数学:
	#   horiz_speed = |v.xz| × jump_horizontal_keep   (保留水平速度大小)
	#   v_new.xz = forward × horiz_speed              (方向 = 车头, 跟引擎力方向一致)
	#   v_new.y  = impulse_y                           (覆盖 Y)
	#   不动 angular_velocity                          (玩家转弯继续)
	var v: Vector3 = linear_velocity
	# 车头方向: 必须跟 _apply_engine_and_brake 的 forward 100% 一致！
	# 用户定义 (2026-06-02): "前方 = 我按前进键加速度的方向"
	# _apply_engine_and_brake line 2267-2270:
	#   forward = -car_mesh.basis.z
	#   if body_mesh and abs(body_mesh.rotation.y) > 0.001:
	#       forward = -(basis.rotated(basis.y, body_mesh.rotation.y)).z
	# 这里完全照抄 (包括 body_mesh 偏转). 之前 v2 往右偏的真凶是
	# steer_input → body_mesh.rotation.y → fwd 偏. 但用户确认"按 W 加速度方向 = 车头",
	# 这个方向就是引擎力方向, 必须包含 body_mesh.rotation.y, 否则跟引擎力方向不一致
	var fwd: Vector3 = -car_mesh.global_transform.basis.z
	if body_mesh and absf(body_mesh.rotation.y) > 0.001:
		var b: Basis = car_mesh.global_transform.basis.rotated(car_mesh.global_transform.basis.y, body_mesh.rotation.y)
		fwd = -b.z
	fwd.y = 0.0
	if fwd.length_squared() > 0.001:
		fwd = fwd.normalized()
	else:
		fwd = Vector3.ZERO

	# 水平速度: 大小保留, 方向重定向到车头 + 保证最低前飞速度
	# 真凶 (2026-06-02 日志确认): 玩家几乎静止时按空格 → horiz_speed ≈ 0
	# → fwd × 0 = 无水平分量 → 跳起来只有 Y → 被残余角速度漂向一侧 → "不朝车头"
	# 修复: 保证跳跃水平速度至少 = jump_forward_kick (默认 10 m/s), 这样即使静止跳也朝车头飞
	var horiz_speed: float = Vector2(v.x, v.z).length() * jump_horizontal_keep
	# 保底: 静止/低速时用 jump_forward_kick 作为最低前飞速度
	horiz_speed = maxf(horiz_speed, jump_forward_kick)
	var v_horiz: Vector3 = fwd * horiz_speed
	# 兜底: 如果 fwd 算错(车几乎垂直时 fwd≈0), 保留原向避免水平速度归零
	if fwd.length_squared() < 0.001:
		v_horiz = Vector3(v.x * jump_horizontal_keep, 0.0, v.z * jump_horizontal_keep)

	var new_v: Vector3 = v_horiz + Vector3(0.0, impulse_y, 0.0)

	# DEBUG: 打印所有方向 让我精确对比
	print("[JUMP v6] fwd=", fwd, " body_mesh.rot.y=", rad_to_deg(body_mesh.rotation.y) if body_mesh else 0)
	print("[JUMP v6] v_before=", v, " new_v=", new_v, " horiz_speed=", Vector2(v.x, v.z).length())
	print("[JUMP v6] car_mesh.basis.z=", car_mesh.global_transform.basis.z)

	# 跳跃专用 kick: 设 linear_velocity + 防弹豁免, **不清角速度** (高压线!)
	linear_velocity = new_v
	_jump_pad_kick_left = maxf(_jump_pad_kick_left, jump_skip_stick)
	_is_airborne = true
	_air_time = 0.0

	# === 跳跃豁免窗口 (修 2026-06-02 抽搐+改镜头 bug) ===
	# 起跳瞬间清掉所有可能"消费跳跃事件"的状态:
	#   _pending_landing_w_left / q_left: 落地预输入缓冲 (回放会自动触发落地喷/起漂)
	#   _landing_stick_left: 上次落地的压地窗口残留 (会把跳跃 Y 速度 clamp 到 0)
	#   _air_boost_armed: 空喷资格标记 (避免跳跃中按 W 误触空喷)
	#   _pending_landing: 上次落地的稳定等待 (会触发 _maybe_trigger_landing_boost)
	# 然后开启豁免窗口, 期间 _update_air_state / _try_boost_w / _apply_landing_physics 跳过
	_pending_landing_w_left = 0.0
	_pending_landing_q_left = 0.0
	_landing_stick_left = 0.0
	_air_boost_armed = false
	_air_boost_armed_left = 0.0
	_pending_landing = false
	_landing_stable_t = 0.0
	# 豁免窗口 = 防弹时长 + 落地后再宽限 0.25s, 至少 1.0s 兜底
	_jump_active_left = maxf(jump_skip_stick + JUMP_LAND_GRACE, 1.0)

	# 冷却启动
	_jump_cooldown_left = jump_cooldown
	# 标记: 跳跃后还没落地 (用于决定要不要触发落地反馈)
	_jump_pending_landing = true

	# === 视觉表现 ===
	# 起跳压扁 (squash)
	if jump_squash_enabled and jump_squash_duration > 0.001:
		_jump_squash_left = jump_squash_duration
		_jump_squash_total = jump_squash_duration
	# 二段跳前空翻 (绕 X 轴转一圈)
	if is_double and jump_air_flip_enabled and jump_air_flip_speed > 0.001:
		# 持续时间 = 360 / speed (转完一圈)
		var flip_dur: float = 360.0 / jump_air_flip_speed
		_jump_flip_left = flip_dur
		_jump_flip_total = flip_dur

	# 起跳震屏
	if jump_takeoff_shake > 0.001 and has_signal("camera_shake_requested"):
		emit_signal("camera_shake_requested", jump_takeoff_shake, 0.15)

	# 标记空中 (apply_jump_pad_kick 内部已经设了, 这里冗余防御)
	_is_airborne = true
	print("[Car] 跳跃! type=%s impulse=%.1f m/s 高度~%.1fm 冷却=%.2fs"
		% ["二段跳" if is_double else "一段跳", impulse_y, impulse_y * impulse_y / 58.0, jump_cooldown])


## 跳跃倒计时 + 落地反馈 (在 _physics_process 里调用, 或集成到 _update_air_state)
##
## 落地反馈触发条件:
##   _jump_pending_landing 为 true (跳跃过, 还没落地反馈过)
##   + 上一帧在空中 (_jump_was_airborne_last_frame=true)
##   + 这一帧落地 (on_ground=true)
##
## 落地反馈内容:
##   1) 落地震屏 (jump_landing_shake)
##   2) 落地烟尘 (jump_landing_dust_enabled + DriftFX 节点存在则触发)
##   3) 重置 _jump_double_left = 1 (落地后又能二段跳一次)
##   4) 清掉 squash/flip 残留视觉
func _update_jump_state(delta: float, on_ground: bool) -> void:
	# 倒计时
	if _jump_cooldown_left > 0.0:
		_jump_cooldown_left = maxf(0.0, _jump_cooldown_left - delta)
	if _jump_squash_left > 0.0:
		_jump_squash_left = maxf(0.0, _jump_squash_left - delta)
	if _jump_flip_left > 0.0:
		_jump_flip_left = maxf(0.0, _jump_flip_left - delta)
		# flip 结束帧把 body_mesh.rotation.x 归零, 防止视觉残留 (-TAU 数值在内部)
		if _jump_flip_left <= 0.0 and body_mesh != null:
			body_mesh.rotation.x = 0.0
	# 跳跃豁免窗口倒计时: 只在还在空中时持续, 落地后切到 JUMP_LAND_GRACE 缓刑
	if _jump_active_left > 0.0:
		# 落地瞬间把窗口压缩到 JUMP_LAND_GRACE (如果当前剩余更多, 也压缩到刚好够落地反馈)
		# 这样跳跃在地面停留 0.25s 后系统自动恢复, 玩家立刻能用空喷/落地喷/漂移等
		if on_ground and _jump_pending_landing == false and _jump_active_left > JUMP_LAND_GRACE:
			# _jump_pending_landing 已被下面的落地反馈逻辑置 false (说明落地反馈已完成)
			_jump_active_left = JUMP_LAND_GRACE
		_jump_active_left = maxf(0.0, _jump_active_left - delta)

	# 落地反馈检测: 上一帧空中 + 这一帧落地 + 跳跃过 (_jump_pending_landing)
	if on_ground and _jump_was_airborne_last_frame and _jump_pending_landing:
		_jump_pending_landing = false
		_jump_double_left = 1   # 落地重置二段跳次数
		# 落地震屏
		if jump_landing_shake > 0.001 and has_signal("camera_shake_requested"):
			# 震屏强度按 v.y 缩放, 但更温柔: clamp(|v.y|/20, 0.6, 1.0)
			# 旧版 (|v.y|/15, 0.5, 1.5) 容易把 0.6 默认值放大到 0.9 → 镜头震得过头
			# 新版上限 1.0 = 不放大, 只在落得很轻时缩小到 0.6
			var vy_abs: float = absf(linear_velocity.y)
			var shake_scale: float = clampf(vy_abs / 20.0, 0.6, 1.0)
			emit_signal("camera_shake_requested", jump_landing_shake * shake_scale, 0.18)
		# 落地烟尘 (复用 DriftFX 节点的 trigger; DriftFX 没暴露 play_landing 就跳过)
		if jump_landing_dust_enabled and drift_fx_node != null and drift_fx_node.has_method("play_boost"):
			# 借用 mini 喷射的烟雾视觉做"落地烟尘"(暂时复用, 避免新加大量 fx 资产)
			# 后续可在 DriftFX 加专门 play_landing_dust 方法
			drift_fx_node.call("play_boost", "mini", 0.15)
		# 清掉视觉残留
		_jump_squash_left = 0.0
		_jump_flip_left = 0.0

	# 更新 last_frame 状态 (供下一帧检测落地瞬间用)
	_jump_was_airborne_last_frame = not on_ground


## 跳跃视觉应用 — 在 _update_visuals 末尾调用 (车壳已有的 yaw/tilt 之后再叠加压扁/翻转)
##
## squash 数学 (起跳压扁→恢复):
##   t = 1 - _jump_squash_left / _jump_squash_total   (0=起跳瞬间, 1=结束)
##   插值曲线: 起跳时 (t<0.3) 压扁加深; 之后回弹 (t>0.3) 逐渐恢复到 1.0
##   scale_y = 1 - amount * sin(π × clamp(t, 0, 1))
##     t=0: scale_y = 1 - 0 = 1 (起跳瞬间还没压)... 不对, 应该 t=0 时已经压
##   修正: t=0 起跳瞬间立刻压到底, 然后回弹到 1
##         scale_y = lerp(1-amount, 1.0, sqrt(t))   √ 让回弹前段快后段慢
##   X/Z 反向变化: 压扁时变粗 (体积大致守恒)
##     scale_xz = 1 + amount * 0.5 × (1 - sqrt(t))
##
## flip 数学 (二段跳前空翻):
##   t_flip = 1 - _jump_flip_left / _jump_flip_total
##   附加旋转角度 = -2π × t_flip   (绕 car_mesh local X 轴, 负号 = 前空翻方向)
func _apply_jump_visuals() -> void:
	if car_mesh == null or body_mesh == null:
		return
	# squash — 在 body_mesh 上做缩放 (不能动 car_mesh.scale! car_mesh.basis 参与物理计算,
	# scale ≠ 1 会让 basis 非 normalized → Godot 内部 get_quaternion/set_axis_angle 报错:
	#   "Basis must be normalized in order to be casted to a Quaternion")
	if _jump_squash_left > 0.0 and _jump_squash_total > 0.001:
		var t: float = clampf(1.0 - _jump_squash_left / _jump_squash_total, 0.0, 1.0)
		var t_smooth: float = sqrt(t)   # 起跳压到底 → 平滑回弹
		var scale_y: float = lerpf(1.0 - jump_squash_amount, 1.0, t_smooth)
		var scale_xz: float = lerpf(1.0 + jump_squash_amount * 0.5, 1.0, t_smooth)
		body_mesh.scale = Vector3(scale_xz, scale_y, scale_xz)
	elif body_mesh.scale != Vector3.ONE:
		body_mesh.scale = Vector3.ONE

	# flip (二段跳前空翻): 给 car_mesh 在 X 轴上叠加旋转
	# 注意: car_mesh.rotation 是世界 yaw + body_mesh.rotation.x 是过弯侧倾,
	#       这里我们直接改 body_mesh.rotation.x 的偏移 (避免和现有 tilt 冲突, 用 body_mesh)
	# 先简化: 只在 flip_left>0 时 set, 结束时归零
	if body_mesh != null:
		if _jump_flip_left > 0.0 and _jump_flip_total > 0.001:
			var t_flip: float = clampf(1.0 - _jump_flip_left / _jump_flip_total, 0.0, 1.0)
			# 前空翻 = 绕 body_mesh local X 轴转 -360° (车头朝下→朝后→朝上→回正)
			body_mesh.rotation.x = -TAU * t_flip


# ============================================================
#  空喷 / 落地喷
# ============================================================
func _update_air_state(delta: float, on_ground: bool) -> void:
	# === 跳跃豁免 (修 2026-06-02 抽搐+改镜头 bug) ===
	# 跳跃激活窗口期内, 整个空喷/落地喷状态机彻底跳过:
	#   · 不调 _apply_landing_physics → 不会清角动量打断 flip 旋转
	#   · 不调 _maybe_trigger_air_boost → 不会自动空喷 → 不改 FOV
	#   · 不进入 _pending_landing 稳定等待 → 不触发落地喷自动消费
	#   · 不回放落地预输入 W/Q → 不强制起漂/落地喷
	# 仍然维护 _is_airborne 和 _air_time 基本字段 (其他系统读),
	# 让玩家在空中正常受重力/能转向, 但所有"自动消费跳跃"的副作用全免
	if _jump_active_left > 0.0:
		# 维护基本状态, 避免其他系统读到陈旧值
		# 关键 (2026-06-03): 如果 _jump_pad_kick_left > 0 (机关正在弹飞车), 强制 airborne
		# 否则 ground_ray 命中地面会把 _is_airborne 设 false → 引擎/摩擦按地面算 → 弹力被吃
		var was_air: bool = _is_airborne
		if _jump_pad_kick_left > 0.0:
			_is_airborne = true   # 机关弹飞途中: 强制空中
		else:
			_is_airborne = not on_ground
		if _is_airborne:
			_air_time += delta
		else:
			if was_air:
				_air_time = 0.0
		return

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

	# === 机关弹飞保护 (2026-06-03, 更新 2026-06-05) ===
	# _jump_pad_kick_left > 0 = 机关正在弹飞车 (地刺/弹簧/跳板/蘑菇等)
	# 期间: 强制空中 + 不可操控(纯抛物线) + 保留机关给的随机角速度
	# 不清 angular_velocity (让机关给的随机旋转自然衰减)
	if _jump_pad_kick_left > 0.0:
		if not _is_airborne:
			_is_airborne = true
			_air_time = 0.0
		_air_time += delta
		return

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
	# 【V4 - 斜面也零弹跳, 钩爪落地修复】
	# 用户反馈 "用钩爪释放落地后还是多次弹跳, 尤其落在下坡斜面上"
	# 根因诊断:
	#   1) 之前 V3 把车 clamp 到 hit_point.y + sphere_radius (垂直 +Y), 但下坡斜面上
	#      ground_ray 垂直向下打到斜面得到的 hit_point 与"球真正接触斜面的最近点"不在同一位置.
	#      正确做法是沿斜面 **法线** 抬升: 球心 = hit_point + normal * sphere_radius
	#      这样无论斜面多陡, 球都精确贴在斜面上, 不会浮空.
	#   2) _apply_ground_stick 在斜面上只施加微弱拉力 (slope_stick_force), 压不住高速落地的反弹.
	#      需要在落地这一帧把"沿法线方向的速度分量"也清掉, 而不只是 v.y=0.
	#      数学: v_normal = v.dot(n) * n   (速度沿法线的投影)
	#            如果 v_normal 是"远离地面"的(即 v.dot(n) > 0), 把它从 v 里减掉
	#            v = v - v_normal      (保留切向分量, 消除法向分离速度)
	#   3) 钩爪释放后 V3 路径的"v.y=0 + Y clamp" 在斜面上没用 → 现在 V4 的法向投影 + 法向 clamp 处理了.
	#
	# 数学:
	#   if ground_ray.is_colliding():
	#       n = ground_ray.collision_normal.normalized()    (斜面外法线, 朝上)
	#       hit_point = ground_ray.get_collision_point()
	#       # 1) 速度法向分量清零: 消除"沿法线弹起"的速度
	#       v_along_n = linear_velocity.dot(n)
	#       if v_along_n > 0:                              (在远离地面)
	#           linear_velocity -= n * v_along_n           (保留切向, 消除法向)
	#       else:                                            (砸下来)
	#           linear_velocity -= n * v_along_n           (砸下分量也清, 让车落"稳", 不要继续往下穿)
	#       (其实统一减掉就行, 不分情况)
	#       # 2) 位置沿法线抬升, 让球精确贴在斜面上
	#       target_pos = hit_point + n * sphere_radius
	#       if (current_pos - hit_point).dot(n) < sphere_radius:    (穿透 / 浮空)
	#           移动到 target_pos
	#   3) 角速度清零 (避免空中累积的旋转把车带飞)
	var fall_speed: float = -linear_velocity.y
	if landing_hard_stick or landing_impact_absorb > 0.0:
		angular_velocity = Vector3.ZERO
		# === V4 修改: 斜面友好的速度法向清零 + 法向位置 clamp ===
		var sphere_radius: float = 1.5
		if ground_ray and ground_ray.is_colliding():
			var n: Vector3 = ground_ray.get_collision_normal().normalized()
			# 防御: collision_normal 极少数情况返回 0 (打到平面边缘), 兜底用 +Y
			if n.length_squared() < 0.01:
				n = Vector3.UP
			var hit_point: Vector3 = ground_ray.get_collision_point()
			# 1) 速度沿法线分量整个清掉 (消除分离速度 + 砸地穿透速度)
			# 切向分量保留 → 车继续按"沿斜面方向"的水平动能滑行, 该走还走
			var v_along_n: float = linear_velocity.dot(n)
			var v: Vector3 = linear_velocity - n * v_along_n
			linear_velocity = v
			# 【V5 改进】预抵消物理引擎 solver 反弹:
			# 问题: 落地帧清了法向速度, 但 Godot 物理引擎在下一个物理步的碰撞 solver
			#       会根据穿透深度重新计算接触响应, 产生新的"分离速度"(反弹).
			#       landing_impact_absorb 名义上是"吸收比例", 但之前只清了当前帧的法向速度,
			#       没有预防 solver 在后续帧产生的反弹.
			# 修复: 落地帧额外施加一个沿法线向下的瞬时冲量, 主动抵消 solver 将要产生的反弹.
			#       冲量大小 = fall_speed × landing_impact_absorb × mass × 0.5
			#       (0.5 是经验系数: solver 反弹通常是落地速度的 30~60%, 取中间值)
			#       这样 solver 产生的反弹速度被这个"预存"的向下动量抵消, 球不会弹起.
			# 数学: impulse = -n × fall_speed × absorb × mass × 0.5
			#       fall_speed > 0 表示砸下来的速度 (已取反), 越大说明砸得越狠, 需要越大的预抵消
			if fall_speed > 0.5 and landing_impact_absorb > 0.0 and landing_anti_bounce_mult > 0.0:
				var anti_bounce_impulse: float = fall_speed * landing_impact_absorb * landing_anti_bounce_mult
				apply_central_impulse(-n * anti_bounce_impulse * mass)
			# 2) 位置沿法线 clamp: 球心 = hit_point + n * sphere_radius
			# 仅当 (车心 - hit_point) · n < sphere_radius 时才推 (避免把已经合理悬空的车往下拽)
			var car_to_hit: Vector3 = global_position - hit_point
			var dist_along_n: float = car_to_hit.dot(n)
			if dist_along_n < sphere_radius:
				# 穿透了或者贴太近, 沿法线方向推到 sphere_radius
				var push_dist: float = sphere_radius - dist_along_n
				if push_dist < 5.0:   # 防御: > 5m 一般是 ray 命中错的物体
					global_position += n * push_dist
					print("[Car] V4 落地法向修正: 沿 n=%s 推 %.3fm (slope=%.0f°, 原下落速度 %.1f m/s)" % [
						str(n.snapped(Vector3(0.01, 0.01, 0.01))),
						push_dist,
						rad_to_deg(acos(clampf(n.y, 0.0, 1.0))),
						fall_speed,
					])
		else:
			# 兜底: ground_ray 没命中 (车飞太高 / ray 距离不够), 走旧 v.y=0 逻辑
			var v: Vector3 = linear_velocity
			v.y = 0.0
			linear_velocity = v
			print("[Car] 落地无 ray 命中: 仅清 v.y (原下落速度 %.1f m/s)" % fall_speed)
		# 【V3 保留】落地瞬间车身姿态立即摆正: 保留 yaw, 清掉 pitch/roll
		# pitch/roll 在地面上由 _update_visuals 的"贴坡"逻辑接管
		if car_mesh:
			var cur_basis: Basis = car_mesh.global_transform.basis
			var fwd: Vector3 = -cur_basis.z
			fwd.y = 0.0
			if fwd.length() > 0.001:
				fwd = fwd.normalized()
				var yaw_only: float = atan2(fwd.x, fwd.z) + PI
				var new_basis := Basis(Vector3.UP, yaw_only)
				var pos_mesh: Vector3 = car_mesh.global_transform.origin
				car_mesh.global_transform = Transform3D(new_basis, pos_mesh).orthonormalized()

	# 启动 V4 落地稳压窗口 (0.18s, 内部独立, 与已废弃的 _landing_stick_left 不冲突)
	# 见 _apply_v4_landing_settle 函数 — 在 _physics_process 每帧调
	_v4_landing_settle_left = landing_settle_duration

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
	# V6 统一法线投影防弹+贴附. 不再区分平地/坡面两套策略.
	# 所有判断都基于速度沿地面法线的投影, 平地(法线≈UP)和坡面行为自然统一.
	if not ground_stick_enabled:
		return
	# === 钩索抑制防弹/贴附 ===
	# 钩索激活时必须跳过整个防弹+贴附逻辑, 让拉力能真正把车拉飞起来:
	#   1) plain_vy_zero_threshold=5 会在 Y>0 且 <5 时强制 v.y=0, 钩索给的上抬速度全被吞
	#   2) plain_downforce 下压力抵消 pull_upward_bias / arc_upward_force 往上的力
	#   3) slope_stick_force 坡面贴附力也会把车按在坡面
	# 钩索期间车应该完全脱离地面物理, 像飞行道具一样被绳子拽着走.
	# 释放钩索后 _grapple_active 清 false, 防弹机制自动恢复, 落地正常走 _apply_landing_physics.
	if _grapple_active or _free_grapple_active:
		return
	# === 跳跃台/弹簧冲击窗口 ===
	# 机关 (FlipBoard / SpringMushroom / GravityCylinder) 调 apply_jump_pad_kick() 设置的
	# 短时窗口, 期间跳过整个 ground_stick 让弹力 / 冲量真正作用.
	# 否则 plain_downforce=8 持续向下压, plain_vy_zero_threshold=5 反复吃 Y 速度
	# → 22 m/s 的弹力实际只飞 1~2m 高 (用户感受"弹力不足")
	if _jump_pad_kick_left > 0.0:
		_jump_pad_kick_left -= _delta
		return
	if ground_ray == null or not ground_ray.is_colliding():
		# 离开地面时重置滤波器, 下次贴地从新法线开始, 不带历史误差
		_smoothed_normal_initialized = false
		return

	# 物理力相关法线读 raw, 不读平滑法线 (滞后会让斜面物理判定失败).
	# 平滑法线只用于视觉贴坡 / thrust 投影方向 (那里能容忍 60ms 延迟换防抖).
	var n: Vector3 = ground_ray.get_collision_normal().normalized()
	if n.length_squared() < 0.01:
		n = Vector3.UP
	var cos_a: float = clampf(n.y, 0.0, 1.0)
	var slope_deg: float = rad_to_deg(acos(cos_a))
	var v: Vector3 = linear_velocity

	# === V5 落地稳压窗口 (落地后 0.35s) ===
	# 用户反馈: 高处落地仍有 1 次弹跳. V4 的 0.18s 窗口 + 0.05 阈值不够压住高速碰撞.
	# V5 改进:
	#   1) 窗口加到 0.35s, 覆盖物理引擎 settle 全过程
	#   2) 取消 0.05 阈值, 任何 > 0 的法向分离速度都清零 (零弹跳)
	#   3) 位置 clamp 放宽 push 上限 (0.5 → 2.0), 高速砸地穿透也能修正
	#   4) 额外施加向下冲量, 主动把球压回地面 (对抗 solver 反弹)
	# 注意: 切向分量保留, 不影响转向/加速/漂移. 钩索期间已在上面 return 了.
	if _v4_landing_settle_left > 0.0:
		_v4_landing_settle_left -= _delta
		var v_along_n2: float = v.dot(n)
		# V5: 任何远离地面的法向速度都清零 (> 0 即清, 不留阈值)
		# 数学: v_along_n > 0 表示球正在远离地面 (弹起), 清掉后球只保留切向滑行
		if v_along_n2 > 0.0:
			v -= n * v_along_n2
			linear_velocity = v
		# V5: 位置 clamp — 确保球心距地面 = sphere_radius, 不浮空也不穿透
		var hit_pt: Vector3 = ground_ray.get_collision_point()
		var d_along_n: float = (global_position - hit_pt).dot(n)
		var sphere_radius: float = 1.5
		if d_along_n < sphere_radius - 0.01:
			var push: float = (sphere_radius - d_along_n)
			if push < 2.0:   # V5: 放宽到 2m, 高速砸地穿透也能修正
				global_position += n * push
		# V5: 额外施加沿法线向下的力, 主动对抗 solver 在下一帧产生的反弹
		# 力度 = landing_settle_downforce × mass (温和但持续, settle 窗口内每帧都压)
		if landing_settle_downforce > 0.0:
			apply_central_force(-n * landing_settle_downforce * mass)

	# ============ V6 统一法线投影防弹 (不再区分平地/坡面) ============
	# 旧方案: 用 plain_slope_threshold_deg 切换两套策略 (平地用 v.y, 坡面用法线投影)
	# 问题: trimesh 法线帧间跳变 (7°→9°→6°→10°), 导致每帧在两套策略间反复切换,
	#        平地分支 v.y=0 吃掉上坡 Y 分量, 坡面分支又放开 → 上坡抖动/阶梯感
	# V6 修复: 统一用法线投影, 不管坡度多少都走同一套逻辑:
	#   1) 速度沿法线分量 > 0 (远离地面) 且 < 阈值 → 清零 (防弹)
	#   2) 沿法线方向施加下压力 (贴附)
	# 平地时法线 ≈ UP, 法线投影 ≈ v.y, 效果和旧平地分支一样
	# 坡面时法线沿坡面, 投影自然正确, 不存在策略切换边界
	# plain_slope_threshold_deg 参数保留兼容旧 cfg, 但不再影响行为

	# --- 1) 法线投影防弹: 远离地面的小速度直接清零 ---
	# 数学: v_along_n = v · n, > 0 表示球正在远离地面 (弹起)
	# 清掉后球只保留切向滑行, 不影响转向/加速/漂移
	var v_along_n_unified: float = v.dot(n)
	if v_along_n_unified > 0.0 and v_along_n_unified < plain_vy_zero_threshold:
		v -= n * v_along_n_unified
		linear_velocity = v

	# --- 2) 下坠速度上限 (沿法线方向) ---
	# 旧方案只限 v.y, 现在改为限法线分量, 坡面上也能正确限速
	if plain_vy_down_clamp > 0.0:
		var v_along_n_down: float = v.dot(n)
		if v_along_n_down < -plain_vy_down_clamp:
			v -= n * (v_along_n_down + plain_vy_down_clamp)
			linear_velocity = v

	# --- 3) 沿法线下压力: 只在车"弹起"时施加 ---
	# v_along_n > gate 表示球正在远离地面 (微弹/悬浮), 沿法线反向压回
	# 平地时 -n ≈ DOWN, 效果和旧方案一样; 坡面时沿坡面法线压, 更合理
	# 注意: 重新读 v_along_n (可能被上面清零了)
	var v_along_n_for_df: float = linear_velocity.dot(n)
	if plain_downforce > 0.0 and v_along_n_for_df > plain_downforce_vy_gate:
		apply_central_force(-n * plain_downforce * mass)

	# --- 4) 坡面贴附力: 非峭壁 + 未真跳跃时, 持续沿法线压住 ---
	# 这里用 slope_stick_force 而不是 plain_downforce, 两者独立可调:
	#   plain_downforce = 防弹 (只在弹起时), slope_stick_force = 贴附 (持续)
	# slope_stick_max_vy 用法线投影判断 (而非旧方案的 absf(v.y)), 坡面上更准确
	var v_normal_abs: float = absf(linear_velocity.dot(n))
	if slope_deg <= slope_stick_max_deg and v_normal_abs < slope_stick_max_vy and slope_stick_force > 0.0:
		apply_central_force(-n * slope_stick_force * mass)


# ============================================================
#  视觉 + 车头朝向 (含高速转向衰减)
# ============================================================
func _update_visuals(delta: float) -> void:
	if not car_mesh or not body_mesh:
		return
	# 低速/停车时依然允许摆动车头 (QQ飞车风格: 原地也能转向)
	# 只在"零输入 + 极低速"时跳过转向 (避免无输入时的视觉 yaw 微抖)
	if linear_velocity.length() < turn_stop_limit and not _grapple_active and not _free_grapple_active and absf(steer_input) < 0.05:
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
	# 反打锁定: 一旦反打过, 本次漂移剩余时间内正打速度也等同于反打速度
	if state == State.DRIFT and drift_dir != 0.0 and drift_intensity > 0.01:
		var is_counter_now: bool = (signf(steer_input) != 0.0 and signf(steer_input) != signf(drift_dir))
		if is_counter_now:
			if not _counter_steer_used_in_this_drift:
				print("[Car] 反打锁定触发: 本次漂移剩余时间内正打速度=反打速度")
			_counter_steer_used_in_this_drift = true
		var use_counter_speed: bool = is_counter_now or (drift_counter_lock_until_exit_enabled and _counter_steer_used_in_this_drift)
		if use_counter_speed:
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
	# 【例外: 钩索期间】真实飞行物理: 空中没有摩擦咬方向, 车头应该被惯性带着跟随速度向量
	#   玩家按方向键 → swing 侧向力推速度向量偏转 → 车头跟着偏 (自然正反馈)
	#   所以这里 turn_rad 置 0 禁用"方向键直接转车头", 车头朝向由下面的"追随速度向量"段接管
	if _is_airborne:
		turn_rad = 0.0

	# ============ 【漂移自动回正】 ============
	# 设计: 漂移持续超过 drift_auto_straighten_delay 秒后, 如果玩家没有按方向键,
	#       车头自动朝速度方向缓慢回正. 回正速度由曲线控制, 从慢到快.
	# 触发条件: state==DRIFT + 不在空中 + 玩家没按方向 + 超过延迟时间
	# 不与反打冲突: 反打时 steer_input != 0, 不会进入此段
	if drift_auto_straighten_enabled and state == State.DRIFT and not _is_airborne \
			and absf(steer_input) < 0.05 and drift_elapsed > drift_auto_straighten_delay:
		var f_xz_as: Vector3 = -car_mesh.global_transform.basis.z
		f_xz_as.y = 0.0
		var v_xz_as: Vector3 = linear_velocity
		v_xz_as.y = 0.0
		if f_xz_as.length() > 0.001 and v_xz_as.length() > 1.0:
			f_xz_as = f_xz_as.normalized()
			var v_dir_as: Vector3 = v_xz_as.normalized()
			var dot_as: float = clampf(f_xz_as.dot(v_dir_as), -1.0, 1.0)
			var cross_y_as: float = f_xz_as.cross(v_dir_as).y
			var slip_as: float = acos(dot_as) * signf(cross_y_as)
			# 只在漂角大于一个小死区时才回正 (避免 0 附近抖动)
			if absf(slip_as) > deg_to_rad(2.0):
				# 曲线采样: X = (drift_elapsed - delay) / duration_ref, 归一化到 [0,1]
				var t_since_delay: float = drift_elapsed - drift_auto_straighten_delay
				var t_norm_as: float = clampf(t_since_delay / maxf(drift_head_yaw_duration_ref, 0.1), 0.0, 1.0)
				var curve_k: float = 1.0
				if drift_auto_straighten_curve != null:
					curve_k = drift_auto_straighten_curve.sample(t_norm_as)
				var straighten_rate: float = deg_to_rad(drift_auto_straighten_speed_deg) * curve_k
				# 方向: slip 正(车头在速度右侧) → turn_rad 取正(往右转回正)
				# 限幅: 不超过当前漂角绝对值 (避免过冲)
				var straighten_amount: float = minf(straighten_rate * delta, absf(slip_as))
				turn_rad += straighten_amount * signf(slip_as)

	# QQ飞车漂移系统: 漂移中车头旋转由 _apply_qqspeed_drift 中的 DriftSystem 控制
	# 这里只处理非漂移状态的转向
	if not (qqspeed_drift_enabled and _drift_system != null and _drift_system.is_drifting):
		var new_basis: Basis = car_mesh.global_transform.basis.rotated(
			car_mesh.global_transform.basis.y, turn_rad
		)
		car_mesh.global_transform.basis = car_mesh.global_transform.basis.slerp(
			new_basis, turn_speed * delta
		)
		car_mesh.global_transform = car_mesh.global_transform.orthonormalized()

	# ============================================================
	# 【空中车头跟随速度方向 / 钩索切线对齐】(真实飞行物理 / Apex swing)
	# ============================================================
	# 三种空中情况, 三套朝向逻辑:
	#   情况 A: 钩索激活 + 玩家有方向键输入 → 车头朝 "圆弧切线" 方向
	#     物理直觉: 玩家用钩索 swing 转圈时, 切线方向 = 圆周运动的瞬时速度方向
	#     数学: 切线 = (anchor → car).cross(Vector3.UP) 的水平分量
	#           方向符号由 steer_input 决定: 左打 = 顺时针(从上往下看), 右打 = 逆时针
	#           tangent = (car_pos - anchor).cross(Vector3.UP).normalized() × signf(-steer_input)
	#           注: 这里 steer_input 左为正 (Godot Input.get_axis 在 car.gd 第 1158 行的约定)
	#           所以"按左 → 想顺时针绕锚点"对应 -steer_input 为负 → tangent 取反 (顺时针正向)
	#
	#   情况 B: 钩索激活 + 无方向输入 → 车头朝速度向量 (退化为正常空中漂)
	#
	#   情况 C: 非钩索空中 (起跳/落地阶段) → 【保持起飞瞬间车头朝向, 不强制对齐速度】
	#     用户反馈: 飞出高台时车头被强制摆正成速度方向 → 出现一次意料外的镜头摆动.
	#     原因: 起跳后水平速度 v_xz 方向不一定跟原本车头朝向完全一致 (高速时确实大致同向,
	#           但低速 / 漂移中 / 撞过墙后会有偏差), 强制对齐时 max_rate=2 rad/s 也足以产生
	#           一次明显的视觉转头, 镜头跟着转就是用户感受到的"摆动".
	#     修复: 非钩索空中跳过 target_fwd 对齐. 车头朝向由起飞前的最后一帧决定, 落地前不动.
	#           漂移中起跳保留漂移姿态, 直跑起跳保留直跑姿态, 完全符合直觉.
	# ============================================================
	# 共同实现: 计算 target_fwd 后, 用 base_rate 的角速度平滑 lerp 车头朝它转
	# 触发条件: _is_airborne 且速度 > 0.5 m/s 且 (钩索激活 OR 钩索释放后摆正倒计时 > 0)
	# 钩索释放后摆正: _grapple_release_align_left > 0 时, 车头朝速度方向平滑对齐
	# 正常从跳台飞出不触发 (因为 _grapple_active 从未为 true, _grapple_release_align_left 始终为 0)
	if _grapple_release_align_left > 0.0:
		_grapple_release_align_left -= delta
		if _grapple_release_align_left < 0.0:
			_grapple_release_align_left = 0.0
	# 钩索弹射窗口倒计时
	if _grapple_boost_window_left > 0.0:
		_grapple_boost_window_left -= delta
		if _grapple_boost_window_left < 0.0:
			_grapple_boost_window_left = 0.0
	var _do_airborne_align: bool = _grapple_active or _grapple_release_align_left > 0.0
	if _is_airborne and linear_velocity.length() > 0.5 and _do_airborne_align:
		var v_xz: Vector3 = linear_velocity
		v_xz.y = 0.0
		if v_xz.length() > 0.5:
			var target_fwd: Vector3 = v_xz.normalized()
			# === 情况 A: 钩索 + 方向键 → 切线对齐 ===
			# 用一个独立的 dead_zone 避免 steer 微小输入也启动切线模式 (玩家手抖)
			var grapple_steer_threshold: float = 0.15
			var _is_grapple_counter_steer: bool = false
			if _grapple_active and _grapple_hook != null and absf(steer_input) >= grapple_steer_threshold:
				# 检查是否处于反打状态
				if "is_counter_steering" in _grapple_hook:
					_is_grapple_counter_steer = bool(_grapple_hook.get("is_counter_steering"))
				# 反打时: 不使用切线方向, 保持使用实际速度方向 (target_fwd = v_xz.normalized())
				# 因为反打时车还在往原方向运动, 车头不应该立刻转向新方向
				if not _is_grapple_counter_steer:
					var anchor_pos: Vector3 = _grapple_hook.call("get_anchor_position") as Vector3 \
						if _grapple_hook.has_method("get_anchor_position") else Vector3.ZERO
					if anchor_pos != Vector3.ZERO:
						# 锚点 → 车 的水平向量
						var radial: Vector3 = global_position - anchor_pos
						radial.y = 0.0
						if radial.length() > 0.5:
							# 切线 = radial × UP, 然后按 steer 决定方向
							# radial × UP 给出"沿圆周逆时针(从上往下看)"的切线方向
							# steer_input 左为正, 玩家按左 = 想绕得"看起来逆时针"在画面上 = 朝负 X 方向
							# (注: 由于 yaw 朝向和 steer_input 的对应是引擎层的事, 我们让 swing_side_force 的方向和切线一致)
							var tangent_ccw: Vector3 = radial.cross(Vector3.UP).normalized()
							# steer 正(按左) → 顺时针(取反) ; steer 负(按右) → 逆时针
							target_fwd = tangent_ccw * (-signf(steer_input))
			# else: 沿用 v_xz.normalized() (速度向量)

			var cur_fwd: Vector3 = -car_mesh.global_transform.basis.z
			cur_fwd.y = 0.0
			if cur_fwd.length() > 0.001 and target_fwd.length() > 0.001:
				cur_fwd = cur_fwd.normalized()
				target_fwd = target_fwd.normalized()
				# 有符号夹角 (cur → target 的 Y 轴旋转量)
				var dot_ct: float = clampf(cur_fwd.dot(target_fwd), -1.0, 1.0)
				var cross_y: float = cur_fwd.cross(target_fwd).y
				var angle_diff: float = atan2(cross_y, dot_ct)
				# 对齐速率: 用户反馈车身朝向跳变, 改成"指数衰减平滑 + max rate 限速"双保险
				# 数学:
				#   smooth_t > 0: 用 t = 1 - exp(-delta / smooth_t) 做插值, 给"丝滑跟随"感
				#                 turn = angle_diff × t, 但仍受 max_rate × delta 卡死, 防止瞬时大跳
				#   smooth_t = 0: 退化到旧行为, 直接用 max_rate × delta 卡死 (线性过渡)
				# 参数走 GrappleHook 的 facing_max_rate_rad / facing_smooth_time, 玩家可在 Tuner 调
				var max_rate: float = 6.0
				var smooth_t: float = 0.15
				if _grapple_active and _grapple_hook != null:
					var mult: float = float(_grapple_hook.get("swing_yaw_speed_mult"))
					max_rate = float(_grapple_hook.get("facing_max_rate_rad")) * mult
					smooth_t = float(_grapple_hook.get("facing_smooth_time"))
					# 反打时降低车头转速: 车还在往原方向运动, 车头不应该快速转向新方向
					if _is_grapple_counter_steer:
						var counter_mult: float = float(_grapple_hook.get("swing_counter_yaw_rate_mult")) if "swing_counter_yaw_rate_mult" in _grapple_hook else 0.3
						max_rate *= counter_mult
				elif _grapple_release_align_left > 0.0:
					# 钩索释放后摆正: 用温和的速率让车头平滑转向速度方向
					# 比钩索期间慢 (不突兀), 但比普通空中快 (有明确的"摆正"意图)
					# 数学: max_rate=4 rad/s ≈ 230°/s, smooth_t=0.2 给丝滑过渡
					max_rate = 4.0
					smooth_t = 0.2
				else:
					# 非钩索空中 (正常起跳) 用较慢的 base 速率
					max_rate = 2.0
					smooth_t = 0.0   # 普通空中沿用旧行为
				# 计算这一帧目标转角
				var turn_this_frame: float = 0.0
				if smooth_t > 0.0001:
					# 指数衰减: 离目标越远转得越快, 越近越缓
					var t: float = 1.0 - exp(-delta / smooth_t)
					var smooth_step: float = angle_diff * t
					# 但仍卡 max_rate × delta 上限, 防止 swing_yaw_speed_mult 拉爆时一帧跳变
					var rate_limit: float = max_rate * delta
					if absf(smooth_step) > rate_limit:
						smooth_step = signf(smooth_step) * rate_limit
					turn_this_frame = smooth_step
				else:
					# 旧行为: max_rate × delta 直接限速线性过渡
					var step_rad: float = clampf(max_rate * delta, 0.0, absf(angle_diff))
					turn_this_frame = signf(angle_diff) * step_rad
				car_mesh.global_transform.basis = car_mesh.global_transform.basis.rotated(
					Vector3.UP, turn_this_frame
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
	# ---------- 反打回正系数 (供下方"车头 yaw 回正"使用) ----------
	# 【2026-05-13 重构】反打的视觉本质是"车头朝反方向缓慢转回来", **不是**"车身从倾斜回正"。
	#   旧版本错误地把这个系数应用在 lean_drift 上(车身侧倾衰减), 玩家反打时看到车身慢慢站起来,
	#   但车头还是横甩状态, 体感不对. 真实物理上反打 = 前轮回正 → 车头跟着转回来 →
	#   配合"反打=车顺惯性甩出去"的 lat_grip 下降, 玩家反打时看到的是
	#   "车头朝反方向转回来, 但车身仍然在惯性方向甩出"的复合效果.
	# 【2026-05-13 二次改进 - 响应时间】反打不是一按就最快, 而是有"蓄势加速"过程:
	#   累计连续反打时长 _counter_steer_hold_time, smoothstep 调制实际回正速度
	#   - hold_time=0 (刚反打) → 倍率 0 → 几乎不动
	#   - hold_time=response_time (已按住够久) → 倍率 1 → 满速回正
	#   - 反打中断 → hold_time 立即清 0, 下次重新蓄势
	# 目标系数:
	#   · 不打 / 正打(steer_input 与 drift_dir 同号或为 0) → 1.0 (保持完整车头偏转)
	#   · 完全反打(steer_input 与 drift_dir 异号) → drift_counter_lean_mult (一般 0.0~0.2,
	#     即车头偏转衰减到原值的 0~20%, 等价"车头朝运动方向转回")
	var counter_target: float = 1.0
	var is_counter_steering: bool = false
	if state == State.DRIFT and drift_dir != 0.0 and signf(steer_input) != 0.0:
		# 反打判定: steer 与 drift_dir 异号
		if signf(steer_input) != signf(drift_dir):
			var cs_old: float = clampf(absf(steer_input), 0.0, 1.0)
			counter_target = lerpf(1.0, drift_counter_lean_mult, cs_old)
			is_counter_steering = true
	# 累计反打蓄势时长: 反打中 += delta; 不反打/松手 立即清 0
	if is_counter_steering:
		_counter_steer_hold_time += delta
	else:
		_counter_steer_hold_time = 0.0

	# smoothstep 加速曲线: 起步柔和, 越按越快达到满速
	# 数学: ramp = smoothstep(0, response_time, hold_time)
	#   · response_time=0 → 直接给 1.0 (旧行为, 无蓄势)
	#   · hold_time=0 → ramp=0 → 实际平滑速度=0 → 车头几乎不转
	#   · hold_time=response_time → ramp=1 → 实际平滑速度=lean_smooth (满速)
	var ramp: float = 1.0
	if drift_counter_response_time > 0.001:
		ramp = smoothstep(0.0, drift_counter_response_time, _counter_steer_hold_time)
	var effective_smooth: float = drift_counter_lean_smooth * ramp
	_counter_lean_factor = lerpf(_counter_lean_factor, counter_target, clampf(effective_smooth * delta, 0.0, 1.0))
	# 车身侧倾: 反打时跟随 _counter_lean_factor 回正(与车头 yaw 同步)
	# 漂移氮气时, 侧倾视觉额外加成(更夸张的过弯姿态)
	var tilt_nitro_mult: float = drift_nitro_body_tilt_mult if _is_drift_nitro() else 1.0
	lean_drift = deg_to_rad(drift_body_tilt) * drift_dir * drift_intensity * tilt_time_k * tilt_nitro_mult * _counter_lean_factor
	# QQ飞车漂移系统: 视觉开关关闭时不显示漂移侧倾和 yaw 偏移
	if qqspeed_drift_enabled and not qqspeed_drift_visual:
		lean_drift = 0.0
	body_mesh.rotation.z = lerp(body_mesh.rotation.z, lean_base + lean_drift, 6.0 * delta)

	# ============ V2 车头 yaw (漂移时偏转 + 时间曲线动态晃动) ============
	# 非漂移的"拧头"基础量
	var base_head_yaw: float = deg_to_rad(head_yaw_deg) * steer_input
	# 漂移偏转量: 基础 × drift_intensity × 时间曲线(可以让车头在漂移中段更甩)
	# 【反打回正】最后乘上 _counter_lean_factor: 反打越猛, 车头越朝运动方向转回来
	var yaw_time_k: float = _sample_curve_safe(drift_head_yaw_curve, drift_t_norm, 1.0)
	var drift_yaw_rad: float = deg_to_rad(drift_yaw_offset) * drift_dir * drift_intensity * yaw_time_k * _counter_lean_factor
	# QQ飞车漂移系统: 视觉开关关闭时不显示 yaw 偏移
	if qqspeed_drift_enabled and not qqspeed_drift_visual:
		drift_yaw_rad = 0.0
	# 两者插值合并(drift_intensity=0 时全用 base, =1 时全用 drift)
	var target_head_yaw: float = lerpf(base_head_yaw, drift_yaw_rad, drift_intensity)
	body_mesh.rotation.y = lerp(body_mesh.rotation.y, target_head_yaw, 6.0 * delta)

	# 沿地面法线对齐
	# 【关键】只在地面时对齐, 空中保持起飞时的车身姿态
	# 旧 bug: 空中 ground_ray 也可能 is_colliding (默认射 4 米向下),
	#         飞跃陡坡时下方法线倾斜, 导致车头朝下/朝上, 不符合"飞行中保持水平"的直觉
	# 法线选择: 用 _smoothed_ground_normal (一阶低通滤波过的) 减少 trimesh 三角形切换造成的视觉抖动.
	# 插值速率: 10×delta 是历史调过的稳定值, 不要改.
	#   (尝试过降到 6×delta 减少残余颤动, 但 240Hz 物理下 car_mesh.basis 跟物理球姿态脱节,
	#    导致 _apply_friction 里 right=car_mesh.basis.x 算出来的 v_lat 方向过时, 摩擦投影偏 →
	#    用户感受到"打滑得厉害". 已改回 10×delta.)
	if not _is_airborne and ground_ray.is_colliding() and _smoothed_normal_initialized:
		var n: Vector3 = _smoothed_ground_normal
		var xform: Transform3D = _align_with_y(car_mesh.global_transform, n)
		car_mesh.global_transform = car_mesh.global_transform.interpolate_with(xform, 10.0 * delta)

	# ============ 弹墙掉头 (车身 yaw 跟着反弹方向旋转) ============
	# 撞墙瞬间 _integrate_forces 记录了 _wall_turnaround_start_yaw / _target_yaw / _total / _left
	# 每帧按剩余时间计算进度 t ∈ [0,1], 把 car_mesh 的 yaw 插值过去
	# 数学:
	#   t = 1.0 - (_wall_turnaround_left / _wall_turnaround_total)  (0=开始, 1=结束)
	#   用 smoothstep 让前期转得快后期转得慢, 更像"被撞飞一下"的手感
	#   target_yaw_now = lerp(start_yaw, target_yaw, smoothstep(t))
	# 完成后清 _wall_turnaround_left = 0, 玩家恢复正常控制
	if _wall_turnaround_left > 0.0:
		_wall_turnaround_left -= delta
		if _wall_turnaround_left < 0.0:
			_wall_turnaround_left = 0.0
		var t: float = 1.0 - (_wall_turnaround_left / maxf(_wall_turnaround_total, 0.001))
		t = clampf(t, 0.0, 1.0)
		# smoothstep: 3t² - 2t³, 前快后慢
		var smooth_t: float = t * t * (3.0 - 2.0 * t)
		# 用最短路径插值 (归一化 diff 到 [-π, π])
		var yaw_diff_total: float = _wall_turnaround_target_yaw - _wall_turnaround_start_yaw
		while yaw_diff_total > PI:
			yaw_diff_total -= TAU
		while yaw_diff_total < -PI:
			yaw_diff_total += TAU
		var current_yaw_target: float = _wall_turnaround_start_yaw + yaw_diff_total * smooth_t
		# 直接设 car_mesh 的世界 yaw (绕 Y 轴)
		# 保留 car_mesh 当前 pitch/roll, 只改 yaw
		# 做法: 以当前 basis 的 Y 轴为旋转轴, 算增量 yaw 应用
		var fwd_now: Vector3 = -car_mesh.global_transform.basis.z
		fwd_now.y = 0.0
		var current_yaw_now: float = 0.0
		if fwd_now.length() > 0.001:
			fwd_now = fwd_now.normalized()
			current_yaw_now = atan2(-fwd_now.x, -fwd_now.z)
		var yaw_step: float = current_yaw_target - current_yaw_now
		while yaw_step > PI:
			yaw_step -= TAU
		while yaw_step < -PI:
			yaw_step += TAU
		if absf(yaw_step) > 0.0001:
			car_mesh.global_transform.basis = car_mesh.global_transform.basis.rotated(
				Vector3.UP, yaw_step
			)
			car_mesh.global_transform = car_mesh.global_transform.orthonormalized()

	prev_yaw = car_mesh.rotation.y

	# 跳跃视觉 (起跳压扁 + 二段跳前空翻) — 在所有标准 yaw/tilt 处理后叠加
	# 注意: 必须放在末尾, 否则 body_mesh 的 rotation.x 可能被后续 tilt 覆盖
	_apply_jump_visuals()


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
	# 【松前漂移 CD】CD 期内再次"松前+踩油门"只把状态切回普通漂移, 车头回正,
	#   不给冲量、不重置爆发期, 防止"反复抖动油门" exploit.
	#   注: 即使 CD 命中也要把 _is_in_songqian 清掉, 不然玩家会卡在"松前但踩着油门"的诡异状态.
	if _songqian_drift_cd_left > 0.0:
		_songqian_yaw_offset = 0.0
		if _is_in_songqian:
			_is_in_songqian = false
			emit_signal("songqian_state_changed", false)
		_songqian_kick_given = false
		print("[Car] 松前漂移在 CD 中 (%.2fs 剩余), 本次踩油门不给冲量(只退出松前)"
			% _songqian_drift_cd_left)
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
	# 4) 开启 CD + 发信号给 HUD 弹"松前漂移"字
	_songqian_drift_cd_left = songqian_drift_cooldown
	emit_signal("songqian_drift_triggered", 1)  # 1 = 仅作"已触发"的 ack, HUD 不再显示次数
	print("[Car] 松前漂移触发! 巨大冲量=%.1f 爆发=%.2fs CD=%.2fs"
		% [songqian_drift_kick_impulse, songqian_drift_boost_duration, songqian_drift_cooldown])


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
	# 2P 调试: 打印漂移条件 (帮助诊断为什么漂移不出来)
	if player_id == 1:
		var spd: float = linear_velocity.length()
		print("[Car P1] 漂移条件: speed=%.1f(需>%.1f) steer=%.2f(需>0.15) throttle=%.2f(需>0.05)" % [spd, drift_min_speed, steer_input, throttle_input])
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
	_drift_inertia_active = true
	drift_accum_charge = 0.0
	drift_accum_angle_deg = 0.0
	drift_elapsed = 0.0
	_low_speed_grace_left = 0.0
	_grace_start_angle = 0.0
	_auto_exit_t = 0.0
	# 反打锁定 flag 起漂清 0: 每轮新漂移都从"未反打"状态开始, 正打重新爽快
	_counter_steer_used_in_this_drift = false
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
	_stack_chain_types.clear()
	# 钩索叠喷链也一并清零
	_grapple_stack_chain_index = 0
	_grapple_stack_breakthrough_count = 0
	_grapple_stack_current_breakthrough = false
	_grapple_stack_chain_seq.clear()
	_grapple_stack_chain_types.clear()
	_grapple_stack_cww_done = false
	# 记录入漂时车头方向(XZ 投影), 后续每帧以此为基准算 yaw 变化
	var _fwd0: Vector3 = -car_mesh.global_transform.basis.z
	_prev_forward_xz = Vector2(_fwd0.x, _fwd0.z).normalized()
	_drift_charge_level = "none"
	emit_signal("drift_charge_level_changed", "none")
	# 【松前漂移 CD】注: CD 不在起漂时清零, 它是"全局冷却"——
	#   不管玩家是连漂还是中间停了一段, 两次松前漂移之间始终保持
	#   songqian_drift_cooldown 秒的间隔, 防止"狂抖油门连续吃冲量"。
	#   CD 衰减只在 _physics_process 里随时间发生。
	emit_signal("drift_started", drift_mode)
	if drift_fx_node and drift_fx_node.has_method("set_drifting"):
		drift_fx_node.set_drifting(true)
	# QQ飞车漂移系统: 同步启动
	if qqspeed_drift_enabled and _drift_system != null:
		_sync_drift_system_params()
		var spd: float = linear_velocity.length()
		_drift_system.try_start_drift(spd, drift_dir)
	print("[Car] 进入漂移 mode=", drift_mode, " fx=", drift_fx_node != null, " qqsd=%s" % str(qqspeed_drift_enabled), " (lockout=%.2f grace=%.2f Qpressed=%s)" % [_drift_lockout_left, _drift_input_grace_left, str(Input.is_action_pressed(_act("drift")))])
	return true


func _end_drift(_success_boost: bool = false, manual: bool = false, failed: bool = false) -> void:
	if state != State.DRIFT:
		return
	_drift_inertia_active = false  # 退漂瞬间关闭惯性感
	# QQ飞车漂移系统: 同步结束
	if qqspeed_drift_enabled and _drift_system != null and _drift_system.is_drifting:
		_drift_system.end_drift(not failed)
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
	# 重置反打回正系数, 下次入漂从满 1.0 开始(完整车头偏转)
	_counter_lean_factor = 1.0
	# 清反打蓄势时长, 下次入漂的反打需要重新蓄势加速
	_counter_steer_hold_time = 0.0
	# 清反打锁定 flag, 下次入漂从"未反打"状态开始(正打重新爽快)
	_counter_steer_used_in_this_drift = false
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
	# QQ飞车漂移系统: 退漂由 DriftSystem.update() 在 _apply_qqspeed_drift 中处理
	if qqspeed_drift_enabled and _drift_system != null and _drift_system.is_drifting:
		# 仍然累计 drift_elapsed 和集气用的角度 (保留集气系统)
		if not _is_airborne:
			drift_elapsed += delta
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
		# 已在宽限期: 倒计时, 到期则强制断漂
		if _low_speed_grace_left > 0.0:
			_low_speed_grace_left -= delta
			# 宽限到期 → 真正断漂 (只有速度恢复才能取消宽限期, 角度不再作为挽救条件)
			if _low_speed_grace_left <= 0.0:
				_low_speed_grace_left = 0.0
				_end_drift(false)
				print("[Car] 自动断漂: 低速宽限期结束, 速度未恢复")
		else:
			# 第一次进入低速: 启动宽限期
			if drift_low_speed_grace_time > 0.0:
				_low_speed_grace_left = drift_low_speed_grace_time
				_grace_start_angle = drift_accum_angle_deg
				print("[Car] 进入低速宽限期 %.2fs (速度=%.1f m/s)" % [drift_low_speed_grace_time, linear_velocity.length()])
			else:
				# 没设宽限期 → 直接断漂(兼容旧行为)
				_end_drift(false)
				print("[Car] 自动断漂: 速度过低(无宽限)")
	else:
		# 速度恢复: 取消宽限期
		if _low_speed_grace_left > 0.0:
			print("[Car] 速度恢复, 退出宽限期")
			_low_speed_grace_left = 0.0

	# ============ 反打超时断漂 ============
	# 连续反打时长 _counter_steer_hold_time 超过 drift_counter_steer_break_time 则立即断漂
	# 正常退漂 (给小喷窗口, 不标记 failed — 反打退漂不是惩罚)
	if drift_counter_steer_break_time > 0.0 and _counter_steer_hold_time >= drift_counter_steer_break_time:
		print("[Car] 反打超时断漂: 连续反打 %.2fs >= %.2fs (正常退漂, 给小喷)" % [_counter_steer_hold_time, drift_counter_steer_break_time])
		_counter_steer_hold_time = 0.0
		_end_drift(false, true, false)
		return


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
	# === 自由钩索期间禁止所有小喷/氮气弹射 ===
	if _free_grapple_active:
		return
	# === 跳跃豁免 (修 2026-06-02 改镜头 bug) ===
	# 跳跃中按 W 不触发空喷/落地喷/钩索弹射, 让玩家纯粹享受跳跃过程
	# 普通的引擎推力 (在 _apply_engine_and_brake) 不在这里, 所以 W 仍能加速车速
	# 只是不会触发"自动空喷+FOV 推升"那种"被改镜头"的副作用
	if _jump_active_left > 0.0:
		return
	# -1) 钩索弹射: 释放钩索后窗口内按 W, 触发独立的钩索弹射 (与空喷互不干扰)
	#     优先级最高: 如果在弹射窗口内, 直接消耗窗口触发弹射, 不走后续逻辑
	#     条件: 位移条件优先 (荡动位移 >= min_swing_distance), 否则退回时间条件
	if _grapple_boost_window_left > 0.0 and not _grapple_boost_used and _grapple_hook != null:
		if bool(_grapple_hook.get("grapple_boost_enabled")):
			var min_swing_dist: float = float(_grapple_hook.get("grapple_boost_min_swing_distance"))
			var min_pull: float = float(_grapple_hook.get("grapple_boost_min_pull_time"))
			# 条件判定: 位移条件优先, 时间条件备选
			var condition_met: bool = false
			if min_swing_dist > 0.0:
				condition_met = _grapple_swing_distance >= min_swing_dist
			elif min_pull > 0.0:
				condition_met = _grapple_pull_time >= min_pull
			else:
				condition_met = true  # 两个条件都为0, 无限制
			if condition_met:
				_grapple_boost_used = true
				var g_power: float = float(_grapple_hook.get("grapple_boost_power"))
				var g_time: float = float(_grapple_hook.get("grapple_boost_time"))
				var g_shake: float = float(_grapple_hook.get("grapple_boost_shake"))
				# 绳长曲线缩放推力
				var length_curve: Curve = _grapple_hook.get("grapple_boost_length_curve") as Curve
				var length_mult: float = 1.0
				if length_curve != null:
					length_mult = length_curve.sample(_grapple_boost_dist_ratio)
				var final_power: float = g_power * length_mult
				_start_boost("grapple_boost", final_power, g_time)
				if g_shake > 0.0:
					emit_signal("camera_shake_requested", g_shake, 0.2)
				emit_signal("boost_triggered", "grapple_boost")
				print("[Car] 钩索弹射! power=%.1f (绳长倍率=%.2f), time=%.2f" % [final_power, length_mult, g_time])
				return
			else:
				print("[Car] 钩索弹射条件不足: 荡动位移 %.1fm (需%.1fm), 拉动时间 %.2fs (需%.2fs)" % [_grapple_swing_distance, float(_grapple_hook.get("grapple_boost_min_swing_distance")), _grapple_pull_time, float(_grapple_hook.get("grapple_boost_min_pull_time"))])

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
	# 钩索叠喷 CWW 终结后, 本次窗口期内禁止再触发空喷
	if air_boost_enabled and _is_airborne and not _air_boost_armed and not _grapple_stack_cww_done:
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
		# 角度不够时 W 无效, 不断漂 (只有小喷可释放时才允许退漂)
		if drift_accum_angle_deg < drift_min_angle_to_boost:
			print("[Car]   角度不足 W 无效 (%.1f° < %.1f°, 不断漂)" % [drift_accum_angle_deg, drift_min_angle_to_boost])
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
	if Input.is_action_pressed(_act("drift")):
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
	# 钩索挂着时不能释放氮气 (必须先释放钩索才能放氮气)
	if _grapple_hook != null and _grapple_hook.has_method("is_attached") and _grapple_hook.is_attached():
		print("[Car] 钩索挂着, 不能释放氮气")
		emit_signal("boost_triggered", "blocked_grapple")
		return
	# QQ 飞车氮气规则:
	#   1) 不能在氮气进行中再放氮气(防 CC / 氮气叠氮气)
	#   2) 小喷/双喷进行中可以放氮气(支持 WCW 路径)
	#   3) 漂移中可以放氮气(漂移氮气过弯增强)
	if is_boosting and (boost_type == "nitro" or boost_type == "grapple_nitro"):
		print("[Car] 氮气进行中, 不能再放氮气")
		emit_signal("boost_triggered", "blocked_boosting")
		return

	# 钩索氮气弹射: 在钩索弹射窗口内释放氮气, 叠加形成强力推进
	var is_grapple_nitro: bool = false
	if _grapple_boost_window_left > 0.0 and not _grapple_nitro_boost_used and _grapple_hook != null:
		if bool(_grapple_hook.get("grapple_nitro_boost_enabled")):
			is_grapple_nitro = true
			_grapple_nitro_boost_used = true

	nitro_stock -= 1
	emit_signal("nitro_stock_changed", nitro_stock, max_nitro_stock)

	if is_grapple_nitro:
		# 钩索氮气弹射: 氮气基础 + 额外推力/时间
		var extra_power: float = float(_grapple_hook.get("grapple_nitro_extra_power"))
		var extra_time: float = float(_grapple_hook.get("grapple_nitro_extra_time"))
		var g_shake: float = float(_grapple_hook.get("grapple_nitro_shake"))
		var g_fov: float = float(_grapple_hook.get("grapple_nitro_fov_boost"))
		# 绳长曲线也影响额外推力
		var length_curve: Curve = _grapple_hook.get("grapple_boost_length_curve") as Curve
		var length_mult: float = 1.0
		if length_curve != null:
			length_mult = length_curve.sample(_grapple_boost_dist_ratio)
		var final_power: float = nitro_power + extra_power * length_mult
		var final_time: float = nitro_time + extra_time
		_start_boost("grapple_nitro", final_power, final_time)
		if g_shake > 0.0:
			emit_signal("camera_shake_requested", g_shake, 0.3)
		# 额外 FOV 效果通过临时增加 cam_fov_boost 实现 (由 Camera3D 读取)
		# 这里直接用 boost_triggered 信号通知 HUD
		emit_signal("boost_triggered", "grapple_nitro")
		print("[Car] 钩索氮气弹射! power=%.1f (绳长倍率=%.2f), time=%.2f" % [final_power, length_mult, final_time])
	else:
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
	# === 钩索叠喷分流: 钩索相关类型走独立系统 ===
	# 钩索叠喷的参与者: grapple_nitro(C), grapple_boost(W), air(W, 仅在钩索链进行中)
	var is_grapple_type: bool = (new_type == "grapple_nitro" or new_type == "grapple_boost")
	# 如果当前钩索叠喷链已经在进行中, air 也加入钩索叠喷链
	var grapple_chain_active: bool = _grapple_stack_chain_seq.size() > 0
	if is_grapple_type or (new_type == "air" and grapple_chain_active):
		_check_grapple_stack_boost(new_type)
		return

	var now: float = Time.get_ticks_msec() / 1000.0

	# === 1. 计算 letter (本段在叠喷序列里的字母) ===
	# c = nitro / grapple_nitro; w = 其他所有 (mini/double/air/landing/grapple_boost)
	# 即: 空喷/落地喷/钩索弹射也作为 w 加入叠喷链
	var letter: String = "c" if (new_type == "nitro" or new_type == "grapple_nitro") else "w"

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

	# [DEBUG] 叠喷判定详细日志
	print("[Stack DEBUG] new_type=%s letter=%s is_boosting=%s boost_type=%s prev_type=%s time_linked=%s cur_seq='%s' chain_types=%s" % [
		new_type, letter, str(is_boosting), boost_type, prev_type, str(time_linked), cur_seq, str(_stack_chain_types)])

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
		_stack_chain_types = [new_type] as Array[String]
		print("[Stack] 新链开始: ", new_type, " seq=", _stack_chain_seq)
		return

	# === 6. 合法续接 → 链 +1 ===
	_stack_chain_index += 1
	_stack_chain_seq.append(letter)
	_stack_chain_types.append(new_type)

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
	# 注: 钩索叠喷已走独立系统 (_check_grapple_stack_boost), 这里只处理普通叠喷
	var combo_name: String = next_seq.to_upper()
	emit_signal("combo_triggered", combo_name, _stack_breakthrough_count)

	print("[Stack] 接力 %s->%s seq=%s 突破=%d %s" % [
		prev_type, new_type, next_seq, _stack_breakthrough_count,
		"(本段享受突破)" if should_set_breakthrough else "(本段不享受突破)"
	])


# ============================================================
#  钩索叠喷 (独立系统, 与普通叠喷完全分离)
#
#  规则 (2026-05-15 重新定义):
#   【钩索释放】接【氮气】→ 显示"氮气弹射" (不算叠喷, 仅弹字)
#   【钩索释放】接【氮气】接【空喷】→ 显示"弹射CW" (突破1)
#   【钩索释放】接【氮气】接【钩索弹射】→ 显示"钩索弹射CW" (突破1)
#   【钩索释放】接【氮气】接【钩索弹射】接【空喷】→ 显示"钩索弹射CWW" (突破2)
#   【钩索释放】接【钩索弹射】→ 显示"钩索弹射" (不算叠喷)
#   【钩索释放】接【钩索弹射】接【空喷】→ 不形成叠喷, 各自独立
#
#  字母约定:
#   c = grapple_nitro (氮气弹射)
#   w = grapple_boost (钩索弹射) 或 air (空喷)
#
#  合法叠喷链 (必须以 c 开头):
#   "cw"  → 弹射CW 或 钩索弹射CW (取决于 W 段是 air 还是 grapple_boost)
#   "cww" → 钩索弹射CWW (第一个 W 必须是 grapple_boost, 第二个 W 必须是 air)
#
#  参数全部从 GrappleHook 节点读取, 与普通叠喷参数完全独立
# ============================================================
func _check_grapple_stack_boost(new_type: String) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0

	# === 1. 计算 letter ===
	var letter: String = "c" if new_type == "grapple_nitro" else "w"

	# === 2. 接力判定 ===
	var prev_type: String = boost_type if is_boosting else _last_boost_type
	var time_since_last: float = now - _last_boost_end_time
	var grapple_window: float = 0.5
	if _grapple_hook:
		grapple_window = float(_grapple_hook.get("grapple_stack_link_window"))
	var time_linked: bool = prev_type != "" and (is_boosting or time_since_last <= grapple_window)

	# === 3. 当前序列 ===
	var cur_seq: String = ""
	for ch in _grapple_stack_chain_seq:
		cur_seq += ch

	print("[GrappleStack] new_type=%s letter=%s prev_type=%s time_linked=%s cur_seq='%s' types=%s" % [
		new_type, letter, prev_type, str(time_linked), cur_seq, str(_grapple_stack_chain_types)])

	# === 4. 合法续接判定 ===
	var next_seq: String = cur_seq + letter
	var legal_extension: bool = false
	if time_linked:
		match next_seq:
			"cw":
				# c 后接 w: 合法 (氮气弹射后接钩索弹射或空喷)
				legal_extension = true
			"cww":
				# cw 后接 w: 只有当第一个 w 是 grapple_boost 且第二个 w 是 air 时才合法
				if _grapple_stack_chain_types.size() >= 2:
					var first_w_type: String = _grapple_stack_chain_types[1]
					if first_w_type == "grapple_boost" and new_type == "air":
						legal_extension = true

	# === 5. 不合法 → 新开链 ===
	if not legal_extension:
		_grapple_stack_chain_index = 0
		_grapple_stack_breakthrough_count = 0
		_grapple_stack_current_breakthrough = false
		_grapple_stack_chain_seq = [letter] as Array[String]
		_grapple_stack_chain_types = [new_type] as Array[String]
		# grapple_nitro 单独开链时弹"氮气弹射"
		if new_type == "grapple_nitro":
			emit_signal("combo_triggered", "氮气弹射", 0)
			print("[GrappleStack] 氮气弹射 (新链开始)")
		# grapple_boost 单独不弹叠喷字 (HUD 会通过 boost_triggered 弹"钩索弹射")
		return

	# === 6. 合法续接 → 链 +1 ===
	_grapple_stack_chain_index += 1
	_grapple_stack_chain_seq.append(letter)
	_grapple_stack_chain_types.append(new_type)

	# === 7. 突破计数 + 弹字 ===
	var should_set_breakthrough: bool = false
	var max_bt: int = 2
	if _grapple_hook:
		max_bt = int(_grapple_hook.get("grapple_stack_max_breakthrough"))

	var combo_name: String = ""
	match next_seq:
		"cw":
			_grapple_stack_breakthrough_count = 1
			should_set_breakthrough = true
			# 根据 W 段类型决定弹字
			if new_type == "grapple_boost":
				combo_name = "钩索弹射CW"
			else:
				combo_name = "弹射CW"
		"cww":
			_grapple_stack_breakthrough_count = 2
			should_set_breakthrough = true
			combo_name = "钩索弹射CWW"
			_grapple_stack_cww_done = true  # CWW 终结, 禁止后续空喷

	if _grapple_stack_breakthrough_count > max_bt:
		_grapple_stack_breakthrough_count = max_bt
	_grapple_stack_current_breakthrough = should_set_breakthrough

	# === 8. 弹字 ===
	if combo_name != "":
		emit_signal("combo_triggered", combo_name, _grapple_stack_breakthrough_count)

	print("[GrappleStack] 接力 %s->%s seq=%s combo='%s' 突破=%d" % [
		prev_type, new_type, next_seq, combo_name, _grapple_stack_breakthrough_count
	])


## 钩索叠喷推力衰减 (从 GrappleHook 节点读取独立参数)
func _grapple_stack_decayed_power(base_power: float) -> float:
	var decay_arr: Array[float] = [1.0, 0.9, 0.8]
	if _grapple_hook:
		var arr = _grapple_hook.get("grapple_stack_power_decay")
		if arr is Array and arr.size() > 0:
			decay_arr = arr
	if decay_arr.is_empty():
		return base_power
	var idx: int = clampi(_grapple_stack_chain_index, 0, decay_arr.size() - 1)
	return base_power * decay_arr[idx]


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
	# --- 普通叠喷链超时 ---
	if now - _last_boost_end_time > stack_link_window:
		if _stack_chain_index > 0 or _stack_breakthrough_count > 0:
			print("[Stack] 连喷链超时断开, 链清零")
		_last_boost_type = ""
		_stack_chain_index = 0
		_stack_breakthrough_count = 0
		_stack_current_breakthrough = false
	# --- 钩索叠喷链超时 (使用独立窗口参数) ---
	var grapple_window: float = 0.5
	if _grapple_hook:
		grapple_window = float(_grapple_hook.get("grapple_stack_link_window"))
	if now - _last_boost_end_time > grapple_window:
		if _grapple_stack_chain_index > 0 or _grapple_stack_breakthrough_count > 0:
			print("[GrappleStack] 钩索叠喷链超时断开, 链清零")
		_grapple_stack_chain_index = 0
		_grapple_stack_breakthrough_count = 0
		_grapple_stack_current_breakthrough = false
		_grapple_stack_chain_seq.clear()
		_grapple_stack_chain_types.clear()
		_grapple_stack_cww_done = false  # 链清零时解除 CWW 空喷禁止


# ============================================================
#  毒图玩法 - 公开接口 (供 Block_Pitfall / Block_LaserGate 调用)
# ============================================================
## 毒坑复位: 把车送回出生点 + 清状态. 包装 _reset_to_origin() 让它对外可用
## 由 Block_Pitfall.gd 在赛车进入毒坑触发区时调用
func respawn_to_spawn() -> void:
	# 内部调 _reset_to_origin (它已经处理: 清速度、归位、震屏、信号通知)
	# 这里包一层公开方法是为了:
	#   1) 对外暴露 stable API, 不依赖私有方法名
	#   2) 未来可以加"扣分/特殊提示"等毒图专用副作用而不污染 _reset_to_origin
	_reset_to_origin()
	# 额外: 给 HUD 一个明显的"中毒/坠落"震屏 (强度比手动 R 复位大)
	emit_signal("camera_shake_requested", 1.5, 0.4)
	print("[Car] 毒坑触发! P%d 已复位" % player_id)


## 激光命中: 由 Block_LaserGate.gd 在激光面与赛车碰撞时调用
##   impulse_back: 沿赛车前方向反向施加的冲量 (m/s × mass), 让车被弹回去
##   slow_factor : 速度直接 ×= 此值 (0~1). 0.5 = 速度砍半. 1.0 = 不砍
##   shake       : 摄像机震屏强度 (0~3 推荐). 0 = 不震
## 数学:
##   linear_velocity *= slow_factor
##   apply_central_impulse(-forward * impulse_back * mass)
##   设计意图: 激光像电网, 命中后车子被推后并掉速, 但不直接复位 (留给毒坑做)
func apply_laser_hit(impulse_back: float = 8.0, slow_factor: float = 0.4, shake: float = 1.2) -> void:
	# 1) 速度直接砍 (sqrt 风格也可以, 但线性 × 更直观, 玩家在 Tuner 调起来好理解)
	if slow_factor < 1.0:
		linear_velocity *= clampf(slow_factor, 0.0, 1.0)
	# 2) 反向冲量 (沿当前车头反向). 用 car_mesh 的 -basis.z 是车头朝向更准
	if impulse_back > 0.001:
		var fwd: Vector3 = -car_mesh.global_transform.basis.z if car_mesh else -global_transform.basis.z
		fwd.y = 0.0
		if fwd.length() > 0.001:
			fwd = fwd.normalized()
			# 注意: 是 -fwd 让车被弹回去 (反向冲量 = 朝车尾方向推)
			apply_central_impulse(-fwd * impulse_back * mass)
	# 3) 震屏
	if shake > 0.001 and has_signal("camera_shake_requested"):
		emit_signal("camera_shake_requested", shake, 0.3)
	# 4) 钩索/漂移中也要被打断 (激光命中 = 大事件, 比加速带还猛)
	if state == State.DRIFT:
		_end_drift(false, true, true)   # manual=true, failed=true (惩罚性退漂, 不开窗口)
	# 钩索状态被打断 (沿用钩索系统的强制释放路径)
	if _grapple_active and _grapple_hook != null and _grapple_hook.has_method("_release"):
		_grapple_hook.call("_release", false)
	print("[Car] P%d 激光命中! impulse=%.1f slow=%.2f" % [player_id, impulse_back, slow_factor])


# ============================================================
#  加速带 / 弹射器 对外接口 (被 SpeedPad.gd 的 Area3D 调用)
# ============================================================
func apply_speed_pad_boost(speed_kick: float, duration: float, pad_type: String = "addspeed") -> void:
	# ============================================================
	# 加速带触发: "视为释放了一个氮气", 但不参与叠喷链
	# ============================================================
	# 用户要求:
	# 1) 踩到加速带要弹炫点 (复用 boost_triggered 信号 → HUD 自动弹中文 "加速带")
	# 2) 视为释放氮气: 走 _start_boost("speed_pad", power, duration) 路径,
	#    boost_type=speed_pad 让 fx_node.play_boost("speed_pad") 放喷射特效
	# 3) 但不触发叠喷判定: 跳过 _check_and_apply_stack_boost (不让加速带计入 CW/CWW 链)
	#    实现: 临时绕过 _start_boost, 直接手写一份"无叠喷版"
	# 4) 中断松前: _is_in_songqian=true 时, 加速带触发 → 退漂 + 清松前
	#    (松前是 DRIFT 子态, 加速带应该把车从漂移状态拉出来到正常喷射)
	# ============================================================
	var fwd: Vector3 = -car_mesh.global_transform.basis.z if car_mesh else -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.001:
		return
	fwd = fwd.normalized()

	# ----- 1. 中断松前 (松前 = DRIFT 子状态), 顺便退漂 -----
	# 直接清 _is_in_songqian + 通知 HUD; 如果还在 DRIFT 状态, 调 _end_drift(true) 走断漂路径
	# (true = manual, 让退漂走"主动结束"分支, 不开小喷窗口避免和加速带氮气冲突)
	if _is_in_songqian:
		_is_in_songqian = false
		_songqian_kick_given = false
		_songqian_yaw_offset = 0.0
		emit_signal("songqian_state_changed", false)
		print("[Car] 加速带打断松前")
	if state == State.DRIFT:
		# end_drift 内部会清松前 + 关漂移视觉. manual=true 不开小喷窗口
		_end_drift(true)

	# ----- 2. 瞬时冲量 (沿车头水平方向 +speed_kick m/s) -----
	apply_central_impulse(fwd * speed_kick * mass)

	# ----- 3. "氮气式"喷射: 不走 _start_boost (它会触发叠喷), 手写无叠喷版 -----
	# 关键: 不调 _check_and_apply_stack_boost, 不动 _stack_chain_index/_stack_breakthrough_count
	# 这样 CW/CWW/WCW 链不被加速带打断也不计入
	# boost_type 用 "speed_pad" 让 fx_node 能针对性出特效 (FX 默认 fallback 到 nitro 视觉)
	boost_type = "speed_pad"
	boost_base_power = speed_pad_sustain_power
	boost_power = speed_pad_sustain_power
	boost_total_time = duration
	boost_time_left = duration
	is_boosting = true
	# 蓄双喷资格清零 (加速带是被动触发, 不是玩家主动 W 操作, 不开放蓄能)
	_can_charge_double = false

	# ----- 4. 持续推力段 (复用旧的 _speed_pad_boost_left / _apply_engine_and_brake 逻辑) -----
	if duration > 0.0 and speed_pad_sustain_power > 0.0:
		_speed_pad_boost_left = duration
		_speed_pad_boost_total = duration
		_speed_pad_boost_power = speed_pad_sustain_power

	# ----- 5. 触发炫点 + 喷射特效 + 摇屏 -----
	# boost_triggered 信号 → HUD._on_boost_triggered → 中文炫点 (需要 HUD 加 "speed_pad" 文案分支)
	emit_signal("boost_triggered", "speed_pad")
	# fx_node.play_boost: 让喷管喷射 (FX 没有 "speed_pad" 时会 fallback 到 nitro 视觉)
	if fx_node and fx_node.has_method("play_boost"):
		fx_node.play_boost("speed_pad", duration)
	for i in range(1, fx_nodes.size()):
		var fn: Node = fx_nodes[i]
		if fn and fn.has_method("play_boost"):
			fn.play_boost("speed_pad", duration)
	# 摇屏 (用 nitro 的力度, 避免新加 export)
	emit_signal("camera_shake_requested", maxf(nitro_boost_shake, 0.25), 0.25)

	print("[Car] 加速带触发 (type=%s) kick=%.1f m/s dur=%.2f sustain=%.1f"
		% [pad_type, speed_kick, duration, speed_pad_sustain_power])


func _start_boost(type_name: String, power: float, duration: float) -> void:
	# ---- 双喷蓄能资格管理 ----
	# 规则: 只有"玩家主动做出的有意义 W 操作"允许蓄双喷:
	#   ✅ 退漂小喷(boost_window 的 mini 释放)           → _consume_boost_window 里置 true
	#   ✅ 氮气末段按 W 的 mini 延续段(CW 的第二段 W)    → 下面的氮气延续分支里置 true
	#   ❌ 空喷 air           (被动, 空中按 W 落地触发)
	#   ❌ 落地喷 landing     (被动, 落地窗口按 W)
	#   ❌ 氮气 nitro         (自身, 不能自己蓄自己)
	#   ❌ 双喷 double        (自身, 防止连续无限蓄)
	#   ❌ 钩索弹射 grapple_boost / grapple_nitro (窗口触发, 不开放蓄双喷)
	# 默认清零, 进入各路径后再按需置 true
	if type_name == "air" or type_name == "landing" or type_name == "nitro" or type_name == "double" \
			or type_name == "grapple_boost" or type_name == "grapple_nitro":
		_can_charge_double = false

	# 【特殊路径】氮气进行中按 W 释放小喷类: 不打断氮气, 延续之
	# 【2026-05-13 修订】"小喷类"包括 mini / double / air / landing
	#   原版只允许 mini/double 延续, 导致空喷/落地喷直接打断氮气, 不符合"它们也是 W 系小喷"的语义.
	#   现在: 氮气进行中, 触发任意 W 段都延续氮气 + 走叠喷判定 (cw/cww 等也对 air/landing 生效).
	#   · 不替换 boost_type(氮气视觉/逻辑保留)
	#   · 但走叠喷判定(突破计数+1, combo 弹字)
	#   · 把小喷/双喷/空喷/落地喷的 duration 加到 boost_time_left, 让氮气延长
	#   · 推力可以被衰减后的本段推力增强(取较大者保持氮气感)
	# 【2026-05-15 修订】grapple_nitro 也视为"氮气进行中", 使 grapple_boost/air 等 W 段
	#   不会打断钩索氮气弹射, 从而保证 grapple_nitro → grapple_boost → air 能形成完整的 CWW 链
	if is_boosting and (boost_type == "nitro" or boost_type == "grapple_nitro") and \
			(type_name == "mini" or type_name == "double" or type_name == "air" or type_name == "landing" or type_name == "grapple_boost"):
		print("[Boost DEBUG] 走氮气延续路径: boost_type=%s type_name=%s" % [boost_type, type_name])
		_check_and_apply_stack_boost(type_name)
		# 钩索类型使用独立的推力衰减
		var dp_extend: float
		if type_name == "grapple_boost" or (type_name == "air" and _grapple_stack_chain_seq.size() > 0):
			dp_extend = _grapple_stack_decayed_power(power)
		else:
			dp_extend = _stack_decayed_power(power)
		boost_time_left += duration
		boost_total_time += duration
		boost_base_power = maxf(boost_base_power, nitro_power) + dp_extend * 0.5
		boost_power = boost_base_power
		emit_signal("boost_triggered", type_name)
		_emit_nitro_variant()
		# ★ 氮气延续出 mini 段(CW 的第二段 W) → 允许继续蓄第三段 double (形成 CWW)
		# 氮气延续出 double 段本身就是最终段, 蓄能无意义, 不重新置 true (默认已在上面清零)
		# air / landing 是被动触发的 W 段, 玩家"无意识做出", 不开放蓄双喷资格 (保持原设计意图)
		if type_name == "mini":
			_can_charge_double = true
			print("[Boost] 氮气延续出 mini: 允许蓄第三段双喷 (CW → CWW 路径)")
		print("[Boost] 氮气延续: 接 %s, 剩余=%.2f, 突破=%d" % [type_name, boost_time_left, _stack_breakthrough_count])
		return

	# 叠喷判定: 在覆盖 boost_type 之前先判断
	_check_and_apply_stack_boost(type_name)
	# 应用推力衰减(根据当前在链中的位置, 钩索类型使用独立衰减)
	var dp: float
	if type_name == "grapple_boost" or type_name == "grapple_nitro" or (type_name == "air" and _grapple_stack_chain_seq.size() > 0):
		dp = _grapple_stack_decayed_power(power)
	else:
		dp = _stack_decayed_power(power)

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
#  撞墙物理状态自检 (启动时输出当前关键参数, 帮用户判断 cfg 是否合理)
# ============================================================
func _log_wall_physics_status() -> void:
	print("[Car] === 撞墙物理参数自检 ===")
	print("[Car]   slope_as_wall_enabled = %s" % str(slope_as_wall_enabled))
	print("[Car]   slope_wall_angle_deg = %.1f° %s" % [slope_wall_angle_deg,
		"⚠️ 太严, 弧形墙可能识别不到, 推荐 50~65°" if slope_wall_angle_deg > 70 else "✓"])
	print("[Car]   wall_normal_y_threshold = %.2f (n.y < 此值强制视为墙)" % wall_normal_y_threshold)
	print("[Car]   wall_reflect_normal_factor = %.2f %s" % [wall_reflect_normal_factor,
		"⚠️ 太低, 反弹很弱, 推荐 0.55~0.75" if wall_reflect_normal_factor < 0.4 else "✓"])
	print("[Car]   wall_straight_tangent_kill = %.2f (正撞切向擦除, 0=关闭) %s" % [wall_straight_tangent_kill,
		"⚠️ 0=正撞也保留切向, 不易掉头, 推荐 0.6~0.9" if wall_straight_tangent_kill < 0.3 else "✓"])
	print("[Car]   wall_hit_kickback = %.1f m/s %s" % [wall_hit_kickback,
		"⚠️ 0=关闭" if wall_hit_kickback < 0.5 else "✓ (高速撞墙会×4 倍放大)"])
	print("[Car]   wall_slide_boost = %.1f m/s %s" % [wall_slide_boost,
		"✓ (已关闭, 不再滑墙)" if wall_slide_boost < 0.5 else "⚠️ >0 会让车沿墙滑, 弹墙掉头请设 0"])
	print("[Car]   wall_hit_speed_cap_mult = %.2f %s" % [wall_hit_speed_cap_mult,
		"⚠️ <1.3 会拍掉 kickback, 推荐 1.3~1.6" if wall_hit_speed_cap_mult < 1.3 and wall_hit_lock_duration > 0.01 else "✓"])
	print("[Car]   wall_hit_lock_duration = %.2fs" % wall_hit_lock_duration)
	print("[Car]   wall_hit_cancel_boost = %s %s" % [str(wall_hit_cancel_boost),
		"⚠️ true 会打断撞墙过弯时的喷射" if wall_hit_cancel_boost else "✓"])
	print("[Car] === 防吸住参数 (V4) ===")
	print("[Car]   wall_hit_cooldown = %.2fs %s" % [wall_hit_cooldown,
		"⚠️ 0=关闭, 撞墙易吸住" if wall_hit_cooldown < 0.01 else "✓"])
	print("[Car]   wall_unstick_offset = %.2fm %s" % [wall_unstick_offset,
		"⚠️ 0=关闭硬位移, 易吸住" if wall_unstick_offset < 0.001 else "✓"])
	print("[Car] === 弹墙掉头参数 ===")
	print("[Car]   wall_turnaround_enabled = %s" % str(wall_turnaround_enabled))
	print("[Car]   wall_turnaround_min_into = %.1f m/s" % wall_turnaround_min_into)
	print("[Car]   wall_turnaround_duration = %.2fs (0=瞬间, 0.3=QQ飞车风)" % wall_turnaround_duration)
	print("[Car]   wall_turnaround_max_deg = %.0f° (最大掉头角度上限)" % wall_turnaround_max_deg)
	print("[Car]   wall_turnaround_min_deg = %.0f° (小于此角度不掉头)" % wall_turnaround_min_deg)


# ============================================================
#  撞墙 - 旧的扣气逻辑
#  注: 真实反弹物理在 _integrate_forces 里 (能拿到精确的 contact normal/position)
#       这里只做"扣气"和"震屏"的兜底, 不再做反弹物理
# ============================================================
func _on_body_entered(_body: Node) -> void:
	if state != State.DRIFT:
		return
	# 注: speed_loss 判定不可靠 (与 _integrate_forces 同帧但顺序难控)
	#     真正的撞墙判定走 _integrate_forces 路径, 那里能拿到 contact normal
	#     这里仅作为"漂移中接触任何东西" 的兜底监听, 真正扣气逻辑已移到 _integrate_forces
	pass


# ============================================================
#  墙/地面区分 + 真实反弹物理 (硬碰硬 + QQ 飞车撞墙过弯)
#  在物理回调 _integrate_forces 里跑, 这里才能拿到有效 contact data
# ============================================================
# 墙/地面判定逻辑 (V2 - 双重 fallback):
#   1) 优先看接触体 group: 在 "wall" 组 → 强制视为墙 ; "ground" 组 → 强制视为地面
#   2) 没 group 时双重判定 (任一满足就算墙):
#      a) n.angle_to(Vector3.UP) >= slope_wall_angle_deg (严格, 用户可调)
#      b) n.y < wall_normal_y_threshold (宽松兜底, 默认 0.7)
#         例: n.y=0.5 → angle≈60°, 即使用户调到 80°也能识别
#         (防止用户把 angle_deg 调太严, 弧形墙的法线达不到阈值, 撞墙完全没反应)
#
# 这样既兼容当前赛道(整个 trimesh 一个 collider 没分组), 也支持未来分场景标签
func _integrate_forces(state_phys: PhysicsDirectBodyState3D) -> void:
	# 撞墙锁速窗口: 每帧 clamp 水平速度上限
	# 【V3 修复】cap 现在用"撞前速度 × 倍率", 不是"撞后速度", 这样 kickback 能突破 cap
	# 防止刚撞完又被引擎/喷射推力推回墙的尴尬循环
	if _wall_hit_lock_left > 0.0:
		_wall_hit_lock_left -= state_phys.step
		if _wall_hit_lock_left < 0.0:
			_wall_hit_lock_left = 0.0
		var v_now: Vector3 = state_phys.linear_velocity
		var vh: Vector3 = v_now
		vh.y = 0.0
		var sp: float = vh.length()
		if sp > _wall_hit_speed_cap and _wall_hit_speed_cap > 0.001:
			# 等比缩放水平分量到 cap, Y 保留 (重力不被锁)
			var scale: float = _wall_hit_speed_cap / sp
			v_now.x *= scale
			v_now.z *= scale
			state_phys.linear_velocity = v_now

	if not slope_as_wall_enabled:
		return
	# 撞墙冷却倒计时 (防吸住): 上一次反弹后此秒数内不再触发新反弹
	# 让车有时间真正离开墙, 防止每物理帧都触发反弹被接触约束拽回的"吸住"循环
	if _wall_hit_cooldown_left > 0.0:
		_wall_hit_cooldown_left -= state_phys.step
		if _wall_hit_cooldown_left < 0.0:
			_wall_hit_cooldown_left = 0.0
		# 冷却中, 跳过本帧的反弹处理 (但仍要让车走正常物理, 不然就真吸住了)
		return

	var contact_count: int = state_phys.get_contact_count()
	if contact_count <= 0:
		return
	var wall_threshold_rad: float = deg_to_rad(slope_wall_angle_deg)
	# 用车头方向判断撞击点是车的哪一侧
	var car_forward: Vector3 = -car_mesh.global_transform.basis.z if car_mesh else Vector3.FORWARD
	var car_right: Vector3 = car_mesh.global_transform.basis.x if car_mesh else Vector3.RIGHT

	# ============================================================
	# 【V4 防吸住】聚合所有 wall contact, 用平均法线 + 平均接触点 触发一次反弹
	# 旧版: 每帧只处理第一个 wall contact, 但 trimesh 边角处法线方向不一致
	#       (n.y=0.5/0.7/0.3 同时存在), 单点法线乱跳导致反弹方向不稳定
	# 新版: 把所有"被识别为墙"的 contact 法线归一化后求和再归一化 (得到主导墙面方向)
	#       用这个稳定法线触发一次反弹, 物理上更稳定
	# ============================================================
	var wall_normal_sum: Vector3 = Vector3.ZERO
	var wall_pos_sum: Vector3 = Vector3.ZERO
	var wall_n_count: int = 0
	var has_wall_group_contact: bool = false   # 是否有带"wall"标签的精确 contact
	var contact_count_all: int = contact_count

	for i in range(contact_count):
		var n: Vector3 = state_phys.get_contact_local_normal(i)
		# 墙/地面判定 V3 (优先级: wall group > ground group > collision_layer & 4 > 法线 fallback):
		var is_wall: bool = false
		var contact_body: Node = state_phys.get_contact_collider_object(i)
		if contact_body and contact_body is Node:
			if (contact_body as Node).is_in_group("wall"):
				is_wall = true
				has_wall_group_contact = true
			elif (contact_body as Node).is_in_group("ground"):
				is_wall = false   # 强制地面
			else:
				# 没标签 → 检查 collision_layer 是否带 wall layer (4)
				if contact_body.has_method("get_collision_layer"):
					var layer: int = contact_body.collision_layer
					if (layer & 4) != 0:
						is_wall = true
						has_wall_group_contact = true
				if not is_wall:
					# 还是没识别 → 法线角度兜底
					is_wall = (n.angle_to(Vector3.UP) >= wall_threshold_rad) or (n.y < wall_normal_y_threshold)
		else:
			is_wall = (n.angle_to(Vector3.UP) >= wall_threshold_rad) or (n.y < wall_normal_y_threshold)

		if is_wall:
			# 优先级机制: 如果出现了带 wall group 的 contact, 后续就只聚合 wall group 的 contact
			# (避免同时把 trimesh fallback 法线和 wall body 法线混在一起平均)
			if has_wall_group_contact:
				var is_this_group: bool = false
				if contact_body and contact_body is Node:
					if (contact_body as Node).is_in_group("wall"):
						is_this_group = true
					elif contact_body.has_method("get_collision_layer") and (contact_body.collision_layer & 4) != 0:
						is_this_group = true
				if not is_this_group:
					continue   # 已有 group contact, 这个 fallback 法线不参与平均

			wall_normal_sum += n.normalized()
			wall_pos_sum += state_phys.get_contact_local_position(i)
			wall_n_count += 1

	# 没有任何 wall contact → 不是撞墙, 直接返回
	if wall_n_count == 0:
		return

	# 聚合: 平均法线 (归一化后求和再归一化, 得到"主导墙面方向")
	var n: Vector3 = wall_normal_sum.normalized()
	var local_contact: Vector3 = wall_pos_sum / float(wall_n_count)
	var contact_pos: Vector3 = state_phys.transform * local_contact

	# 撞前速度
	var v: Vector3 = state_phys.linear_velocity
	var into_wall: float = -v.dot(n)
	if into_wall <= 0.5:
		return   # 速度太小不触发

	# ============================================================
	#  硬碰硬反弹物理 (基于聚合的稳定法线)
	# ============================================================
	# 速度分解
	var v_normal: Vector3 = n * v.dot(n)
	var v_tangent: Vector3 = v - v_normal

	# 撞击角度
	var fwd_for_angle: Vector3 = car_forward
	fwd_for_angle.y = 0.0
	if fwd_for_angle.length() > 0.001:
		fwd_for_angle = fwd_for_angle.normalized()
	var incidence_dot: float = absf(fwd_for_angle.dot(-n))
	var incidence_angle_rad: float = acos(clampf(incidence_dot, 0.0, 1.0))
	var incidence_angle_deg: float = rad_to_deg(incidence_angle_rad)
	var face_angle_deg: float = 90.0 - incidence_angle_deg
	var is_grazing: bool = face_angle_deg < wall_grazing_angle_deg

	# 切向减速插值
	var tangent_keep: float
	if wall_reflect_tangent_keep > 0.001:
		tangent_keep = wall_reflect_tangent_keep
		if not is_grazing:
			tangent_keep *= 0.85
	else:
		var t: float = clampf(into_wall / maxf(wall_reflect_tangent_lerp_speed, 0.1), 0.0, 1.0)
		tangent_keep = lerpf(wall_reflect_tangent_keep_max, wall_reflect_tangent_keep_min, t)
		if is_grazing:
			tangent_keep = minf(tangent_keep + 0.15, 1.0)

	# 弹墙掉头切向擦除
	if not is_grazing and wall_straight_tangent_kill > 0.001:
		tangent_keep *= (1.0 - wall_straight_tangent_kill)

	# 反弹速度 = 切向衰减 + 法线弹回
	var new_v: Vector3 = v_tangent * tangent_keep + n * (into_wall * wall_reflect_normal_factor)

	# Kickback 沿法线 (二次方缩放)
	if wall_hit_kickback > 0.0:
		var k_ratio: float = into_wall / 10.0
		var kickback_scale: float = clampf(k_ratio * k_ratio, 0.5, 4.0)
		new_v += n * (wall_hit_kickback * kickback_scale)

	# 已废弃: wall_slide_boost (默认 0)
	if wall_slide_boost > 0.001 and v_tangent.length() > 1.0:
		var slide_dir: Vector3 = v_tangent.normalized()
		var slide_scale: float = clampf(v_tangent.length() / 20.0, 0.3, 2.0)
		new_v += slide_dir * (wall_slide_boost * slide_scale)

	# 沿法线推开防贴墙
	new_v += n * slope_wall_push_back

	# 弹墙推力 (尾/侧撞)
	if wall_bounce_boost_enabled:
		var rear_factor: float = n.dot(car_forward)
		var side_factor: float = absf(n.dot(car_right))
		var is_rear_or_side: bool = rear_factor > wall_bounce_rear_threshold or side_factor > wall_bounce_side_threshold
		if is_rear_or_side and into_wall > wall_bounce_min_into_speed:
			new_v += car_forward * wall_bounce_forward_speed
			emit_signal("boost_triggered", "wall_bounce")
			print("[Car] 弹墙推力! rear=%.2f side=%.2f face_angle=%.0f° boost=%.1f"
				% [rear_factor, side_factor, face_angle_deg, wall_bounce_forward_speed])

	state_phys.linear_velocity = new_v

	# ============================================================
	# 【V4 防吸住】撞墙瞬间硬位移 - 把车沿法线方向硬推开几厘米
	# 不依赖速度推开 (那种方式被接触约束立即拽回), 直接改 transform.origin
	# 这是脱离 trimesh 接触面的"暴力但有效"的方式
	# ============================================================
	if wall_unstick_offset > 0.001:
		var xform: Transform3D = state_phys.transform
		xform.origin += n * wall_unstick_offset
		state_phys.transform = xform

	# 启动撞墙冷却 (防吸住): 后续 wall_hit_cooldown 秒不再触发新反弹
	_wall_hit_cooldown_left = wall_hit_cooldown

	# 启动锁速窗口 (防止撞完又被引擎/喷射推回墙, cap=max(撞前,撞后)*mult)
	if wall_hit_lock_duration > 0.0:
		var pre_v: Vector3 = v
		pre_v.y = 0.0
		var new_vh_cap: Vector3 = new_v
		new_vh_cap.y = 0.0
		var pre_speed: float = pre_v.length()
		var post_speed: float = new_vh_cap.length()
		_wall_hit_speed_cap = maxf(pre_speed, post_speed) * wall_hit_speed_cap_mult
		_wall_hit_lock_left = wall_hit_lock_duration

	# 弹墙掉头: 记录车身 yaw 旋转目标
	if wall_turnaround_enabled and into_wall >= wall_turnaround_min_into and car_mesh:
		var new_v_horiz: Vector3 = new_v
		new_v_horiz.y = 0.0
		if new_v_horiz.length() > 1.0:
			var target_dir: Vector3 = new_v_horiz.normalized()
			var target_yaw: float = atan2(-target_dir.x, -target_dir.z)
			var fwd: Vector3 = -car_mesh.global_transform.basis.z
			fwd.y = 0.0
			var current_yaw: float = 0.0
			if fwd.length() > 0.001:
				fwd = fwd.normalized()
				current_yaw = atan2(-fwd.x, -fwd.z)
			var yaw_diff: float = target_yaw - current_yaw
			while yaw_diff > PI:
				yaw_diff -= TAU
			while yaw_diff < -PI:
				yaw_diff += TAU
			var yaw_diff_deg: float = rad_to_deg(absf(yaw_diff))
			if yaw_diff_deg >= wall_turnaround_min_deg:
				if yaw_diff_deg > wall_turnaround_max_deg:
					var clamped_diff: float = deg_to_rad(wall_turnaround_max_deg) * signf(yaw_diff)
					target_yaw = current_yaw + clamped_diff
				_wall_turnaround_start_yaw = current_yaw
				_wall_turnaround_target_yaw = target_yaw
				_wall_turnaround_total = maxf(wall_turnaround_duration, 0.001)
				_wall_turnaround_left = _wall_turnaround_total

	# 撞墙取消 boost (可选)
	if wall_hit_cancel_boost and is_boosting:
		is_boosting = false
		boost_time_left = 0.0
		_drift_exit_boost_left = 0.0
		print("[Car] 撞墙取消 boost (type=%s)" % boost_type)

	# 玻璃渣特效
	if into_wall >= glass_shatter_min_speed and glass_shatter_fx_scene:
		_spawn_glass_shatter(contact_pos, n, into_wall)

	# 漂移中撞墙 → 立即失败断漂
	if state == State.DRIFT:
		_end_drift(false, false, true)
		if wall_drift_lockout_time > 0.0:
			_drift_lockout_left = wall_drift_lockout_time
		_drift_input_grace_left = 0.0
		_require_release_q = true
		var lost: float = drift_accum_charge * (1.0 - crash_charge_penalty)
		charge = maxf(charge - lost, 0.0)
		drift_accum_charge *= crash_charge_penalty
		emit_signal("wall_crashed", lost)
		print("[Car] 撞墙断漂! face=%.0f° into=%.1fm/s CD=%.2fs lost=%.1f wall_n=%d/%d %s"
			% [face_angle_deg, into_wall, wall_drift_lockout_time, lost, wall_n_count, contact_count_all,
				"[group]" if has_wall_group_contact else "[fallback]"])
	else:
		var pre_speed_log: float = v.length()
		var post_speed_log: float = new_v.length()
		var turnaround_info: String = ""
		if _wall_turnaround_left > 0.0:
			turnaround_info = " turnaround=%.0f°" % rad_to_deg(absf(_wall_turnaround_target_yaw - _wall_turnaround_start_yaw))
		print("[Car] 撞墙! face=%.0f° into=%.1f n=(%.2f,%.2f,%.2f) keep=%.2f e=%.2f kick=%.1f×%.2f speed:%.1f→%.1f wall_n=%d/%d %s unstick=%.2f cd=%.2fs%s"
			% [face_angle_deg, into_wall, n.x, n.y, n.z, tangent_keep, wall_reflect_normal_factor,
				wall_hit_kickback, clampf((into_wall/10.0)*(into_wall/10.0), 0.5, 4.0),
				pre_speed_log, post_speed_log, wall_n_count, contact_count_all,
				"[group]" if has_wall_group_contact else "[fallback]",
				wall_unstick_offset, wall_hit_cooldown, turnaround_info])

	# 蓄能阶段视为"准漂移", 撞墙也要打断
	if _double_charge_t > 0.0 or _double_armed:
		_double_charge_t = 0.0
		_double_armed = false
		_double_armed_left = 0.0
		emit_signal("double_charge_progress", 0.0)
		emit_signal("double_charge_lost")
		_set_double_charge_fx(false)
		print("[Car] 撞墙打断双喷蓄能/资格")

	# 震屏强度按撞击速度缩放
	var shake_intensity: float = maxf(wall_crash_shake, slope_wall_shake)
	if shake_intensity > 0.0:
		var shake_amp: float = shake_intensity * clampf(into_wall / 10.0, 0.5, 2.5)
		emit_signal("camera_shake_requested", shake_amp, 0.3)


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
	# 【bug 修复 2026-05-13】码表只取"水平速度", 不含 Y 分量.
	# 旧实现 linear_velocity.length() 把 Y 也算进去, 导致:
	#   · 按"前进+转向"时, 球体驱动 + 坡道补偿/上坡助力会让 Y 有几 m/s 的分量
	#     被开根号一并算进 |v|, 码表数字明显虚高 (玩家实际行驶速度并未那么快)
	#   · 跳跃/落地瞬间码表蹦字
	# 新实现: 只取水平面速度, 跟引擎/物理软封顶 (current_speed) 一致, 显示与体感对齐.
	var v_horiz: Vector3 = linear_velocity
	v_horiz.y = 0.0
	var kmh: float = v_horiz.length() * 3.6
	emit_signal("speed_changed", kmh)
	emit_signal("charge_changed", charge, charge_nitro_full)


# ============================================================
#  时间回溯 (Rewind, R 键) + 自定义位置模式 (FreeFly, 小键盘 0)
# ============================================================
# 这两个功能都直接接管 transform, 跳过正常 3C 物理.
# 见 _physics_process 入口的早 return 分支.

# 每物理帧记录一帧到环形 buffer
# 内容: 车球 RigidBody 的 global_position + CarMesh 的 global_transform
# 不存 linear_velocity (回溯时强制清零, 不需要恢复)
func _record_rewind_frame() -> void:
	if _rewind_capacity <= 0 or _rewind_buffer.is_empty():
		return
	var mesh_xform: Transform3D = car_mesh.global_transform if car_mesh else Transform3D.IDENTITY
	_rewind_buffer[_rewind_write_idx] = {
		"pos": global_position,
		"mesh_xform": mesh_xform,
	}
	_rewind_write_idx = (_rewind_write_idx + 1) % _rewind_capacity
	if _rewind_size < _rewind_capacity:
		_rewind_size += 1


# 进入回溯模式: 启动 freeze + 记录起点 cursor
func _start_rewind() -> void:
	if not rewind_enabled or _rewind_size <= 0:
		return
	_rewind_active = true
	_rewind_pressed_t = 0.0
	# cursor 从最新一帧 (size-1) 开始, 向 0 方向倒退
	_rewind_cursor = float(_rewind_size - 1)
	# 冻结物理, 速度归零
	if rewind_freeze_physics:
		freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# 退出漂移/喷射状态 (用户要求"状态消失")
	state = State.NORMAL
	is_boosting = false
	boost_time_left = 0.0
	drift_intensity = 0.0
	print("[Car] Rewind start, buffer size=", _rewind_size)


# 退出回溯: 解冻, 速度清零, 清掉 buffer (避免未来帧残留)
func _stop_rewind() -> void:
	if not _rewind_active:
		return
	_rewind_active = false
	freeze = false
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# 简单做法: 直接 reset 整个 buffer, 让录制重新开始
	_rewind_size = 0
	_rewind_write_idx = 0
	print("[Car] Rewind stop, velocity zeroed")


# 每物理帧倒带 cursor 并应用对应 buffer 帧到 car
func _update_rewind(delta: float) -> void:
	if _rewind_size <= 0:
		_stop_rewind()
		return
	# 累计按键时长 -> 加速度斜坡
	_rewind_pressed_t += delta
	var speed: float = rewind_speed_base + _rewind_pressed_t * rewind_speed_ramp_per_sec
	speed = minf(speed, rewind_speed_max)
	# cursor 每秒倒退 60 * speed 帧
	_rewind_cursor -= speed * 60.0 * delta
	if _rewind_cursor < 0.0:
		_rewind_cursor = 0.0
	# 实际 buffer 索引: oldest_idx + cursor_int (mod capacity)
	# oldest_idx = (write_idx - size + capacity) % capacity
	var cursor_int: int = int(_rewind_cursor)
	cursor_int = clampi(cursor_int, 0, _rewind_size - 1)
	var oldest_idx: int = (_rewind_write_idx - _rewind_size + _rewind_capacity) % _rewind_capacity
	var actual_idx: int = (oldest_idx + cursor_int) % _rewind_capacity
	var frame = _rewind_buffer[actual_idx]
	if frame == null or not (frame is Dictionary):
		return
	var fdict: Dictionary = frame
	if fdict.is_empty():
		return
	# 应用到 car
	global_position = fdict["pos"]
	if car_mesh:
		car_mesh.global_transform = fdict["mesh_xform"]
	# 持续 0 速度 (freeze 已经能保证, 双保险)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


# 进入/退出 FreeFly (自定义位置模式, 小键盘 0)
func _toggle_freefly() -> void:
	if not freefly_enabled:
		return
	if _freefly_active:
		_exit_freefly()
	else:
		_enter_freefly()


func _enter_freefly() -> void:
	_freefly_active = true
	_freefly_pressed_t = 0.0
	# 备份 + 切到 freeze + 关碰撞 (用户要求"不再受任何物理影响")
	_freefly_was_freeze = freeze
	_freefly_was_gravity_scale = gravity_scale
	_freefly_was_collision_layer = collision_layer
	_freefly_was_collision_mask = collision_mask
	freeze = true
	gravity_scale = 0.0
	# 关碰撞 mask 让车不被推但仍能被探测
	collision_mask = 0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# 退出 3C 状态
	state = State.NORMAL
	is_boosting = false
	boost_time_left = 0.0
	print("[Car] FreeFly ON: WASD move, Shift up, Ctrl down, KP_0 again to exit")


func _exit_freefly() -> void:
	_freefly_active = false
	freeze = _freefly_was_freeze
	gravity_scale = _freefly_was_gravity_scale
	collision_layer = _freefly_was_collision_layer
	collision_mask = _freefly_was_collision_mask
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	print("[Car] FreeFly OFF, velocity zeroed, physics restored")


# 每物理帧处理 FreeFly 的方向键移动
# 参考系: 用 car_mesh 的车头朝向 (-Z) 作为前向
# 这样玩家"按前 = 车头方向移动", 直觉一致
func _update_freefly(delta: float) -> void:
	# 收集输入方向
	var dir_local: Vector3 = Vector3.ZERO
	if Input.is_action_pressed("accelerate"):
		dir_local.z -= 1.0   # 前 (-Z 是 Godot 默认 forward)
	if Input.is_action_pressed("brake"):
		dir_local.z += 1.0   # 后
	if Input.is_action_pressed("steer_left"):
		dir_local.x -= 1.0   # 左
	if Input.is_action_pressed("steer_right"):
		dir_local.x += 1.0   # 右
	# 升降 (Shift = 升, Ctrl = 降)
	var lift: float = 0.0
	if Input.is_key_pressed(KEY_SHIFT):
		lift += 1.0
	if Input.is_key_pressed(KEY_CTRL):
		lift -= 1.0
	# 累计按键时长 -> 速度斜坡 (任意方向键按住都累加)
	if dir_local.length() > 0.001 or absf(lift) > 0.001:
		_freefly_pressed_t += delta
	else:
		_freefly_pressed_t = 0.0
	var speed: float = freefly_speed_base + _freefly_pressed_t * freefly_speed_ramp_per_sec
	speed = minf(speed, freefly_speed_max)
	var lift_speed: float = freefly_lift_speed + _freefly_pressed_t * freefly_speed_ramp_per_sec * 0.6
	lift_speed = minf(lift_speed, freefly_speed_max)
	# 把局部方向转成世界方向 (用 car_mesh 朝向, 但只取 yaw, 避免空中翻车后视角乱)
	if dir_local.length() > 0.001 and car_mesh:
		dir_local = dir_local.normalized()
		var fwd: Vector3 = -car_mesh.global_transform.basis.z
		fwd.y = 0.0
		var yaw: float = 0.0
		if fwd.length() > 0.001:
			fwd = fwd.normalized()
			yaw = atan2(fwd.x, fwd.z)
		# +PI 因为 -Z 是车头, basis 的 yaw 用 atan2 反推
		var yaw_basis := Basis(Vector3.UP, yaw + PI)
		var world_dir: Vector3 = yaw_basis * dir_local
		global_position += world_dir * speed * delta
	if absf(lift) > 0.001:
		global_position += Vector3.UP * lift * lift_speed * delta
	# CarMesh 跟随刚体位置 (因为我们关了正常物理, _physics_process 后续逻辑不会跑)
	if car_mesh:
		car_mesh.global_position = global_position + sphere_offset
