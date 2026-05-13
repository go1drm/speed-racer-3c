extends CanvasLayer
## 调参 UI —— TAB 切换 · 即时生效 · 保存/加载 user://tune.cfg
## 增强:
##  - 每个参数 tooltip 自然语言描述
##  - 点击参数名弹窗编辑 min/max
##  - 喷射力度/镜头拉远等"随时间变化"参数支持曲线编辑器(20+预设)

@export var car_path: NodePath
var car: Node = null

# row 数据: prop -> {slider, spin, kind, name_btn, min, max, step, curve_prop, curve_btn}
var _rows: Dictionary = {}
var _defaults: Dictionary = {}      # prop -> default scalar value
var _curves: Dictionary = {}        # curve_prop -> Curve 对象
var _panel: PanelContainer

# 参数定义: [prop, label, min, max, step, tooltip, curve_prop_or_empty]
# curve_prop_or_empty: 如果非空, 表示该参数关联一条曲线(可点 🎨 编辑)
#
# 三级分类标记 (基础3C定型版 V1):
#   __page  : 顶级页签 (左侧 tab 栏的一项, 重写 current_list)
#   __group : 页内大标题 (高亮黄色, 视觉分组)
#   __sub   : 大标题下的小标题 (浅蓝细字)
#   __hidden_start / __hidden_end : 包裹的参数被隐藏(不显示在 UI), 但仍兼容旧 cfg 加载
const PARAMS := [
	["__page", "🚗 基础移动"],
	["__group", "极速 & 油门"],
	["max_speed",                 "巡航极速 (m/s)",     10.0, 200.0, 0.5,
		"无喷射时车辆能达到的最高速度。引擎曲线 X=1 对应到这个值。", ""],
	["top_speed_boosted",         "喷射极速 (m/s)",     10.0, 300.0, 0.5,
		"小喷/双喷/氮气期间车辆能达到的最高速度。喷射时引擎曲线 X=1 对应到这个值, 让喷射阶段也是从 0 推到 1, 同样有'越接近顶速越乏力'的曲线感。", ""],
	["__sub", "转向"],
	["steering_deg",              "前轮转角(度)",       5.0,  60.0,  0.5,
		"前轮视觉转角, 同时也是车头朝向的转向幅度上限。", ""],
	["turn_speed",                "车头响应速度",       0.5,  8.0,   0.1,
		"车头朝向 lerp 到目标方向的速度, 越大手感越灵敏(也越甩)。", ""],
	["turn_speed_high_speed_mult","高速转向衰减倍率",   0.1,  1.0,   0.05,
		"高速时转向速度会衰减到这个倍率, 防止高速过弯打滑甩尾。", ""],
	["high_speed_threshold",      "高速衰减阈值(m/s)",  5.0,  80.0,  1.0,
		"超过此速度后开始应用'高速转向衰减倍率'。", ""],

	["__group", "动力 (引擎/刹车)"],
	["engine_force_max",          "引擎最大推力",       10.0, 300.0, 1.0,
		"引擎峰值推力. 实际推力 = 此值 × 引擎曲线在当前速度比的采样 × 油门. 调大=加速更猛.", "engine_force_curve"],
	["brake_force_max",           "刹车最大力",         10.0, 300.0, 1.0,
		"刹车峰值力, 配合刹车曲线实现高速刹车更强的真实感.", "brake_force_curve"],
	["engine_idle_drag",          "松油门引擎拖曳",     0.0,  20.0,  0.1,
		"松油门时沿前进方向反向施加的力, 模拟引擎刹车/滚阻.", ""],
	["__sub", "倒车"],
	["reverse_threshold",         "刹车→倒车切换阈值",  0.0,  10.0,  0.1,
		"车头方向速度低于此值时, 按下刹车键切换为倒车模式. 推荐 1.5.", ""],
	["reverse_force_mult",        "倒车推力倍率",       0.0,  2.0,   0.05,
		"倒车推力相对前进推力的倍率. 0.5=倒车力是前进的一半.", ""],
	["reverse_max_speed",         "倒车最高速度(m/s)",  1.0,  40.0,  0.5,
		"倒车时 long_speed 不能低于 -此值, 防止倒车太快.", ""],

	["__group", "摩擦 - 正常行驶"],
	["friction_long_normal",      "前后向摩擦",         0.0,  20.0,  0.1,
		"正常行驶前后方向摩擦系数(等效力 = k × 速度). 影响低速松油门减速感.", "friction_long_speed_curve_normal"],
	["friction_lat_normal",       "侧向抓地",           0.0,  30.0,  0.1,
		"正常行驶侧向抓地力(抗侧滑). 越大过弯越稳.", "friction_lat_speed_curve_normal"],
	["friction_air_drag",         "空气阻力系数",       0.0,  0.5,   0.005,
		"与速度平方成正比的总阻力(沿惯性反向), 决定顶速手感. 调大→更难达到极速.", ""],

	["__page", "🎯 漂移系统"],
	["__group", "摩擦 - 漂移状态"],
	["friction_long_drift",       "漂移前后摩擦",       0.0,  20.0,  0.1,
		"漂移时前后向摩擦(通常比正常低, 让车滑得更远).", "friction_long_speed_curve_drift"],
	["friction_lat_drift",        "漂移侧向抓地",       0.0,  15.0,  0.1,
		"漂移时侧向抓地(需要远小于正常值, 否则甩不出去).", "friction_lat_speed_curve_drift"],
	["drift_extra_decel",         "漂移额外能耗",       0.0,  20.0,  0.1,
		"漂移时额外沿惯性反向施加的整体减速力(模拟轮胎打滑功耗).", ""],
	["drift_extra_decel_songqian_mult", "松前能耗倍率",  0.0,  3.0,   0.05,
		"松前(松开油门)时 drift_extra_decel 的倍率. 0.3=松前时能耗只剩 30% 车滑得更远, 1.0=不变.", ""],
	["__group", "松前 (松油门漂)"],
	["songqian_drift_enabled",    "松前漂移开关",       0.0,  1.0,   1.0,
		"1=开启: 漂移中松油门=松前. 松前下车头朝入弯方向偏, 按 Q 触发松前漂移(冲量+爆发, 不退漂). 0=关闭: 漂移中按 Q 一律退漂.", ""],
	["songqian_yaw_limit_deg",    "车头偏移上限(度)",   0.0,  180.0, 1.0,
		"松前车头相对起漂时方向最多偏的角度. 90° = 车身完全侧向. 推荐 60~90.", ""],
	["songqian_yaw_speed_deg",    "车头偏移速度(度/秒)", 10.0, 360.0, 5.0,
		"松前车头朝偏移上限达到的速度. 越大偏越快. 推荐 60~120.", ""],
	["songqian_drift_kick_impulse", "踩油门触发冲量",   0.0,  50.0,  0.5,
		"松前下踩回油门触发松前漂移时, 沿车头方向的一次性'巨大'冲量(单位 m/s²×mass). 推荐 14~25.", ""],
	["songqian_drift_boost_duration", "松前漂移爆发时长", 0.1, 2.0,  0.05,
		"松前漂移触发后, 推力爆发期持续秒数.", ""],
	["songqian_drift_cooldown",     "松前漂移CD",         0.0,  5.0,   0.05,
		"两次松前漂移之间的最小冷却时间(秒), 全局生效不会因起漂清零. CD 期内再次'松前+踩油门'只切回普通漂移、不给冲量, 防止反复抖油门 exploit. 设 0=无 CD(可无限连发); 推荐 0.6~1.2.", ""],
	["songqian_enter_kick_impulse", "进入松前小加速",   0.0,  20.0,  0.5,
		"刚进入松前(漂移中松油门瞬间)时, 沿当前运动方向的一次性小冲量. 模拟打滑势能保留, 0=纯惯性, 推荐 3~6.", ""],
	["songqian_steer_mult",       "松前转向倍率",       0.0,  1.5,   0.05,
		"松前期间转向倍率(相对漂移转向再乘这个数). 数学: turn_mult = drift_steer_mult × songqian_steer_mult. 0.3=松前转向只剩漂移转向的 30%, 防止松前下方向乱甩.", ""],

	["__group", "三喷 (松前后退喷)"],
	["songqian_back_boost_enabled", "三喷开关",         0,    1,     1,
		"1=启用三喷(松前后退喷): 松前下车头偏角足够时按 Q+W 触发. 0=禁用.", ""],
	["songqian_back_min_yaw_deg", "触发最小偏角(度)",   0.0,  180.0, 1.0,
		"三喷需要车头相对起漂方向至少偏过这么多度才能触发. 推荐 60~90.", ""],
	["songqian_back_boost_power", "三喷推力",            10.0, 200.0, 1.0,
		"三喷的持续推力(沿车头反方向). 推荐 80~150.", ""],
	["songqian_back_boost_time",  "三喷持续(秒)",        0.1,  2.0,   0.05,
		"三喷推力持续秒数.", ""],
	["songqian_back_kick_impulse","三喷瞬时冲量",        0.0,  30.0,  0.5,
		"三喷触发瞬间沿车头反方向给的一次性冲量, 让车'嘭'一下推出去. 推荐 8~15.", ""],

	["__group", "打滑 (松油门=滑)"],
	["drift_slip_enabled",        "打滑总开关",         0.0,  1.0,   1.0,
		"是否启用'漂移中松开前进键=打滑'. 关闭后漂移摩擦不受油门影响.", ""],
	["drift_slip_friction_cut",   "打滑摩擦削减",       0.0,  1.0,   0.05,
		"完全松开前进键时摩擦削减比例. 1.0=摩擦归零(纯惯性打滑), 0.5=摩擦保留一半.", ""],
	["drift_slip_smooth",         "打滑过渡速度",       1.0,  20.0,  0.5,
		"打滑强度过渡平滑速度. 越大越锐利, 越小越柔和.", ""],
	["drift_inertia_boost",       "惯性感增强",         0.0,  1.0,   0.05,
		"漂移中沿惯性方向的摩擦削减. 0=不变, 1=漂到深度时摩擦(除空气)归零. 推荐 0.3~0.6.", ""],
	["drift_centripetal_pull",    "向心力拉力",         0.0,  50.0,  0.5,
		"漂移中把速度方向往车头方向拉的拉力. 0=关闭, 推荐 5~20. 大弧线过弯的'粘'感来源.", "drift_centripetal_curve"],

	["__group", "触发与限制"],
	["drift_min_speed",           "最低入漂车速",       0.0,  30.0,  0.5,
		"低于此速度无法触发漂移。", ""],
	["drift_min_angle_to_boost",  "小喷资格累积角(度)", 0.0,  120.0, 1.0,
		"漂移期间车头转过此累计角度后, 退漂可触发小喷。", ""],
	["drift_max_duration",        "漂移最长持续(秒)",   0.0,  30.0,  0.5,
		"漂移最长持续秒数。0 = 不限时(只要速度足够就一直漂)。", ""],
	["drift_break_speed_ratio",   "低速断漂阈值倍率",   0.0,  1.0,   0.05,
		"漂移时速度低于(最低入漂车速 × 此值)会触发低速宽限期。", ""],
	["drift_low_speed_grace_time","低速宽限秒数",       0.0,  2.0,   0.05,
		"低速触发后给玩家多少秒'挽救'机会, 期间猛打方向继续漂可避免断漂。", ""],
	["drift_grace_save_angle",    "宽限期挽救所需角度", 0.0,  60.0,  0.5,
		"宽限期内车头再转过此角度即视为挽救成功, 取消断漂。", ""],
	["drift_max_speed",           "漂移最高速度(m/s)",  0.0,  100.0, 0.5,
		"漂移时速度软上限。超过此值会施加反向刹车力。0 = 不限速。", ""],
	["drift_speed_brake_strength","漂移超速刹车强度",   0.0,  60.0,  0.5,
		"漂移超过最高速度时反向刹车力的强度. 实际施加 = 此值 × 超速比例 × 时间曲线(随漂移持续时间变化).", "drift_speed_brake_curve"],
	["drift_counter_steer_break_time", "反打断漂秒数",  0.05, 1.5,   0.05,
		"漂移中持续反向打方向超过此时长会自动退漂。", ""],
	["drift_auto_exit_enabled",   "车正自动退漂",       0,    1,     1,
		"1=车头摆正且无侧向速度时自动退出漂移; 0=只手动 Q/低速/超时退漂。", ""],
	["drift_auto_exit_lat_speed", "自动退漂侧速阈值",   0.0,  10.0,  0.1,
		"侧向速度小于此值视为'无侧滑'(m/s)。", ""],
	["drift_auto_exit_angle_deg", "自动退漂角度阈值(度)", 0.0, 30.0,  0.5,
		"车头方向与运动方向夹角小于此值视为'摆正'。", ""],
	["drift_auto_exit_time",      "自动退漂去抖时长(秒)", 0.0, 1.0,   0.01,
		"满足'摆正+无侧滑'条件持续此秒数后才真正退漂。", ""],
	["drift_auto_exit_protect_time","自动退漂保护期(秒)",  0.0, 1.5,   0.01,
		"刚入漂的多少秒内不启用自动退漂. 防止入漂瞬间车头还没甩出来就被误判摆正而退漂.", ""],


	["__group", "动态曲线"],
	["drift_engage_duration",     "入漂过渡时长(秒)",   0.0,  1.5,   0.01,
		"从直行切到漂移, drift_intensity 从 0 到 1 的过渡时间. 小=灵敏, 大=柔和.", "drift_engage_curve"],
	["drift_disengage_duration",  "退漂过渡时长(秒)",   0.0,  1.5,   0.01,
		"退漂时 drift_intensity 从 1 回到 0 的时间.", "drift_disengage_curve"],
	["drift_head_yaw_duration_ref","车头曲线时间基准(秒)", 0.2, 6.0,  0.1,
		"车头 yaw/侧倾曲线的 X 轴基准秒数. 漂移持续此秒数后曲线采样到达 1.0.", "drift_head_yaw_curve"],
	["drift_steer_mult",          "漂移转向倍率",       1.0,  4.0,   0.05,
		"漂移时转向速度相对正常的倍率, 数值越大漂移中越容易拉角度.", ""],
	["drift_accel_mult",          "漂移油门效率",       0.0,  1.5,   0.05,
		"漂移时油门实际有效比例. 会与 drift_intensity 插值应用.", ""],
	["drift_exit_boost_duration", "退漂爆发期时长(秒)", 0.0,  2.0,   0.05,
		"入漂/退漂瞬间触发的推力爆发期时长. 0=禁用.", ""],
	["drift_exit_boost_mult",     "退漂爆发期推力倍率", 1.0,  3.0,   0.05,
		"爆发期开始时的推力倍率, 之后线性衰减回 1.0.", ""],
	["post_drift_steer_cooldown", "退漂转向冷却时长(秒)", 0.0, 1.5,   0.01,
		"退漂瞬间转向倍率被衰减, 在此秒数内线性回到 100%.", ""],
	["post_drift_steer_mult",     "退漂转向冷却起始倍率", 0.0,  1.0,   0.05,
		"退漂瞬间转向倍率. 0.5=只剩 50% 然后平滑回到 100%.", ""],

	["__group", "反打 (真实赛车过弯反打)"],
	["__sub",   "★新机制 (drift_counter_enabled=true 时生效)"],
	["drift_counter_enabled",          "反打新机制开关",       0, 1, 1,
		"★真实反打核心开关★ 1=启用: 漂移中玩家按下'与漂角方向相反'的方向键 → 车头朝速度向量缓慢回正, 按到位松手即可直线出弯. 0=关闭, 回退到旧机制 (减速+前向阻力+锁定, 由下方旧参数控制).", ""],
	["drift_counter_angular_speed_deg", "反打回正角速度(°/s)", 10.0, 360.0, 5.0,
		"完全反打时车头朝速度向量回正的角速度. 实际角速度 = 此值 × |steer| × ramp(response_time) × drift_intensity. 推荐 60~180: 60 缓慢, 120 流畅 (QQ 飞车手感), 180 利索.", ""],
	["drift_counter_deadzone_deg",     "反打死区(°)",         0.0, 20.0, 0.5,
		"漂角 |slip_angle| 小于此值 (度) 时不触发反打回正, 避免车头在 0 附近抖动. 推荐 2~8.", ""],
	["drift_counter_response_time",    "反打响应时间(s)",     0.0, 2.0,  0.05,
		"反打从'刚开始按'到'达到峰值回正速度'的累计秒数. 用 smoothstep 加速曲线. 0=一按就满速; 0.3~0.8=有蓄势感. 反打中断立即清零.", ""],

	["__sub",   "车身视觉 (车身侧倾/车头 yaw 动画, 与物理层独立)"],
	["drift_counter_lean_mult",        "反打车头回正目标",    0.0, 1.0,  0.05,
		"车身视觉层: 漂移反打时车头 yaw 偏转衰减到的最低倍率 (仅影响 body_mesh.rotation.y 视觉, 不影响物理). 0=车头完全朝运动方向回正; 1=反打不影响车头偏转.", ""],
	["drift_counter_lean_smooth",      "反打车头回正速度",    1.0, 20.0, 0.5,
		"车身视觉: 反打/松开时车头 yaw 的恢复过渡平滑速度. 越大越锐利.", ""],

	["__sub",   "旧机制 (drift_counter_enabled=false 时才生效, 不建议)"],
	["drift_counter_steer_mult",       "旧-反打转向缩减",     0.0, 1.0,  0.05,
		"[已废弃] 旧机制: 漂移中反打方向的转向倍率. 0.35=反打时角速度只剩 35%. 新机制下此参数不再生效.", ""],
	["drift_counter_lock_until_exit_enabled", "旧-反打锁定到退漂", 0, 1, 1,
		"[已废弃] 旧'反打锁定'开关, 仅在 drift_counter_enabled=false 时生效. 新机制不使用此机制.", ""],
	["drift_counter_decel_enabled",    "旧-反打减速开关",     0,   1,    1,
		"[已废弃] 旧'反打=刹车'机制, 仅在 drift_counter_enabled=false 时生效.", ""],
	["drift_counter_decel",            "旧-反打减速强度",     0.0, 30.0, 0.1,
		"[已废弃] 旧机制减速力. 新机制下不生效.", ""],
	["drift_counter_decel_min_steer",  "旧-反打最小输入阈值", 0.0, 1.0,  0.01,
		"[已废弃] 旧机制阈值. 新机制下不生效.", ""],
	["drift_counter_throttle_friction_enabled", "旧-反打+前进摩擦开关", 0, 1, 1,
		"[已废弃] 旧机制. 新机制下不生效.", ""],
	["drift_counter_throttle_friction", "旧-反打+前进摩擦强度", 0.0, 30.0, 0.1,
		"[已废弃] 旧机制. 新机制下不生效.", ""],
	["drift_counter_lat_grip_mult",    "旧-反打侧向抓地倍率", 0.0, 1.0,  0.01,
		"[已废弃] 旧'反打=车顺惯性甩出'机制. 新机制用 yaw 回正替代.", ""],





	["__page", "💨 喷射"],
	["__group", "集气公式"],
	["charge_nitro_full",         "一格氮气=多少集气",  20.0, 300.0, 5.0,
		"集气槽多满才升级为一格氮气, 越大越难攒。", ""],
	["charge_per_lateral_m",      "侧滑米数权重",       0.0,  10.0,  0.1,
		"漂移时每米侧滑提供多少集气。", ""],
	["charge_yaw_rate_weight",    "车头角速度权重",     0.0,  10.0,  0.1,
		"车头转动越快, 集气越快, 此参数为权重。", ""],
	["charge_min_per_sec",        "兜底集气/秒",        0.0,  60.0,  1.0,
		"哪怕完全直线漂, 每秒也至少有此基础集气。", ""],
	["crash_charge_penalty",      "撞墙保留比例",       0.0,  1.0,   0.05,
		"撞墙后当前漂移已积累的集气保留多少(0.2 = 损失 80%)。", ""],
	["max_nitro_stock",           "氮气槽上限",         1,    5,     1,
		"最多能囤积多少格氮气。", ""],
	["instant_nitro_settle",      "集气满立即结算氮气", 0,    1,     1,
		"1=集气满立刻得到一格氮气可立即用; 0=漂移结束才结算(平衡向)。", ""],

	["__group", "喷射类型"],
	["mini_boost_power",          "小喷推进力",         5.0,  100.0, 1.0,
		"小喷的基础推进力, 实时力 = 此值 × 力度曲线在当前进度的采样。", "mini_boost_curve"],
	["mini_boost_time",           "小喷持续(秒)",       0.1,  3.0,   0.05,
		"小喷持续时长。", ""],
	["double_boost_power",        "双喷推进力",         10.0, 150.0, 1.0,
		"双喷基础推进力, 可绑定力度曲线。", "double_boost_curve"],
	["double_boost_time",         "双喷持续(秒)",       0.1,  3.0,   0.05,
		"双喷持续时长。", ""],
	["double_charge_hold_time",   "双喷蓄能时长(按住Q秒)", 0.1,  2.0,   0.05,
		"小喷期间需要按住 Q 多长时间才能解锁双喷。", ""],
	["double_charge_window",      "双喷蓄满后有效秒数", 0.2,  3.0,   0.05,
		"双喷蓄满后, 多久内不按 W 会失效。", ""],
	["nitro_power",               "氮气推进力",         20.0, 200.0, 1.0,
		"氮气基础推进力, 可绑定力度曲线。", "nitro_boost_curve"],
	["nitro_time",                "氮气持续(秒)",       0.5,  6.0,   0.1,
		"氮气持续时长。", ""],
	["nitro_require_throttle",    "松手中断氮气",       0,    1,     1,
		"1=松开前进键立即中断氮气(QQ飞车手感); 0=氮气按时间跑完无视油门。", ""],
	["mini_boost_shake",          "小喷震屏",           0.0,  2.0,   0.05,
		"小喷触发时震屏强度。0=不震。", ""],
	["double_boost_shake",        "双喷震屏",           0.0,  2.0,   0.05,
		"双喷触发时震屏强度。0=不震。", ""],
	["nitro_boost_shake",         "氮气震屏",           0.0,  2.0,   0.05,
		"氮气触发时震屏强度。0=不震。", ""],

	["__group", "叠喷 (连喷接力)"],
	["stack_link_window",         "连喷接力窗口(秒)",   0.0,  1.5,   0.05,
		"前一段喷射结束后多少秒内开新喷算'接力'。窗口越大越容易接, 太大失去操作感。", ""],
	["stack_breakthrough_top_mult", "突破极速倍率",     1.0,  2.0,   0.01,
		"每次成功突破极速时, 极速被提升的倍率(乘法叠加)。1.18 = 突破后极速 ×1.18, 二段突破 ×1.18²≈1.39。", ""],
	["stack_max_breakthrough",    "最大突破次数",       0,    5,     1,
		"叠喷链中能突破极速的最大次数, 超过后再多接也不再加速。", ""],

	["__group", "漂移氮气 (过弯增强)"],
	["drift_nitro_max_speed_mult","漂移氮气极速倍率",   1.0,  3.0,   0.05,
		"漂移中放氮气时, 漂移最高速度上限的提升倍率(默认 1.5 = 提升 50%)。", ""],
	["drift_nitro_steer_mult",    "漂移氮气转向倍率",   1.0,  3.0,   0.05,
		"漂移中放氮气时, 漂移转向倍率额外加强(过弯更急更猛)。", ""],
	["drift_nitro_lat_grip_mult", "漂移氮气侧向抓地倍率", 0.5, 3.0,  0.05,
		"漂移中放氮气时, 侧向抓地额外加成。>1 让车不甩飞更稳, <1 让车更滑。", ""],
	["drift_nitro_body_tilt_mult","漂移氮气侧倾倍率",   0.5,  2.5,   0.05,
		"漂移中放氮气时, 车身侧倾视觉额外倍率(纯视觉效果)。", ""],

	["__page", "✨ 视觉"],
	["__group", "车身姿态 (非漂移)"],
	["body_tilt",                 "过弯侧倾敏感度",     5.0,  120.0, 1.0,
		"数值越大, 过弯侧倾感越迟钝(可以理解为'稳'); 越小越夸张。", ""],
	["body_tilt_max_deg",         "过弯最大侧倾角(度)", 0.0,  45.0,  0.5,
		"过弯时车身最大侧倾角, 防止高速侧翻。", ""],
	["head_yaw_deg",              "车头左右拧头幅度(度)", 0.0,  20.0,  0.5,
		"非漂移时按方向键车头会做轻微 yaw 摆动, 这是幅度。", ""],

	["__group", "漂移姿态 (车身倾斜+yaw)"],
	["drift_body_tilt",           "漂移车身侧倾(度)",   0.0,  60.0,  1.0,
		"漂移时车身往内侧倾斜的最大角度, 仅视觉效果。", "drift_body_tilt_curve"],
	["drift_yaw_offset_tuck",     "甩尾yaw偏移(度)",    0.0,  60.0,  1.0,
		"甩尾型漂移车头相对运动方向的偏转角度。", ""],
	["drift_yaw_offset_side",     "侧身yaw偏移(度)",    0.0,  80.0,  1.0,
		"侧身型漂移(反打入漂)车头相对运动方向的偏转, 比甩尾更夸张。", ""],
	["side_drift_threshold",      "侧身触发侧速阈值",   0.0,  8.0,   0.1,
		"反打入漂时, 横向速度超过此值则进入侧身漂(否则甩尾漂)。", ""],

	["__page", "⛰️ 地面物理"],
	["__group", "防弹 + 贴附 (统一机制)"],
	["ground_stick_enabled",      "防弹+贴附总开关",    0,    1,     1,
		"1=启用统一的防弹/贴附机制; 0=纯物理, 会有弹跳。", ""],
	["plain_slope_threshold_deg", "平地/坡面切换(度)",  0.0,  30.0,  0.5,
		"小于此坡度视为平地(走强防弹), 大于等于则视为坡面(走温和贴附)。8 度合理。", ""],
	["plain_vy_zero_threshold",   "平地向上速度归零阈值", 0.0, 20.0, 0.1,
		"平地上 Y 向上速度 < 此值时直接置 0, 消除橡皮球效应。5 推荐。", ""],
	["plain_downforce",           "平地持续下压力",     0.0,  40.0,  0.5,
		"平地上向下施加的力(N/kg), 主动消除三角网格微弹。8 推荐, 太大会'粘地板'。", ""],
	["plain_downforce_vy_gate",   "下压力触发阈值",     0.0,  5.0,   0.05,
		"只在 Y 速度 > 此值时施加下压力。0.3=轻微抬起就压(推荐), 0=永远压(会干扰爬坡助力), 2+=只压大弹跳。", ""],
	["plain_vy_down_clamp",       "平地下坠速度上限",   0.0,  50.0,  0.5,
		"0=不限; >0 时限制平地上下坠速度绝对值。防止从高空砸地又弹飞。", ""],
	["slope_stick_force",         "坡面贴附力",         0.0,  40.0,  0.5,
		"坡面上沿法线反向加力, 防止过坎/接缝飞车。8 推荐。", ""],
	["slope_stick_max_vy",        "坡面贴附 Y 速度上限", 0.0,  10.0,  0.1,
		"Y 速度绝对值小于此值才贴附, 保护真跳跃/空喷不被吸回。2.5 合理。", ""],
	["slope_stick_max_deg",       "坡面贴附最大坡度(度)", 5.0, 90.0,  1.0,
		"超过此坡度(峭壁)不再贴附, 避免拉住爬墙车。60 合理。", ""],

	["__page", "🧱 撞墙物理"],
	["__group", "墙判定 + 总开关"],
	["slope_as_wall_enabled",     "斜面视为墙",         0,    1,     1,
		"1=陡斜面会被当作墙壁吸收速度+反推; 0=允许爬坡。", ""],
	["slope_wall_angle_deg",      "斜面墙阈值(度)",     20.0, 85.0,  1.0,
		"法线与竖直方向夹角 ≥ 此值视为墙壁。值越小越严格(更多斜面被当墙). 推荐 50~65°.", ""],
	["slope_wall_push_back",      "撞墙反推速度",       0.0,  20.0,  0.5,
		"撞墙后沿法线方向额外推开的速度, 防止卡墙。", ""],

	["__group", "弹墙推力 (尾/侧撞奖励)"],
	["wall_bounce_boost_enabled", "弹墙推力开关",       0,    1,     1,
		"1=漂移撞墙时车的尾/侧撞墙会获得弹墙加速; 0=纯撞墙吸收.", ""],
	["wall_bounce_rear_threshold","尾撞判定阈值",       0.0,  1.0,   0.05,
		"接触法线沿车头方向投影 > 此值视为尾撞. 0.4 推荐.", ""],
	["wall_bounce_side_threshold","侧撞判定阈值",       0.0,  1.0,   0.05,
		"接触法线沿车右方向投影绝对值 > 此值视为侧撞. 0.6 推荐.", ""],
	["wall_bounce_min_into_speed","触发最小撞墙速度",   0.0,  20.0,  0.1,
		"撞墙速度小于此值不触发弹推, 防止蹭墙也飞.", ""],
	["wall_bounce_forward_speed", "弹墙推力大小(m/s)",  0.0,  30.0,  0.5,
		"沿车头方向叠加的速度. 6 推荐.", ""],
	["wall_drift_lockout_time",   "撞墙断漂入漂CD(秒)", 0.0,  2.0,   0.05,
		"漂移中撞墙立即断漂(本次无小喷), 此秒数内按 Q 无法重新入漂. 0.5 推荐.", ""],
	["wall_crash_shake",          "撞墙震屏",           0.0,  2.0,   0.05,
		"撞墙时震屏强度。0=不震。", ""],

	["__group", "硬碰硬反弹 V3"],
	["wall_reflect_tangent_keep_max", "切向保留(擦墙)", 0.0, 1.0, 0.05,
		"撞击力极小(擦墙)时切向保留比例. 推荐 0.85~0.95: 擦墙基本不掉速.", ""],
	["wall_reflect_tangent_keep_min", "切向保留(正撞)", 0.0, 1.0, 0.05,
		"撞击力极大(正撞)时切向保留比例. 推荐 0.2~0.4.", ""],
	["wall_reflect_tangent_lerp_speed", "切向插值参考速度", 1.0, 50.0, 0.5,
		"切向减速插值的参考 v_normal (m/s). 18 = 大约 65km/h 正撞时切向减到最低. 越小越敏感, 越大越宽容.", ""],
	["wall_reflect_normal_factor","反弹: 法向反弹系数 e", 0.0,  1.0,   0.05,
		"恢复系数 e: 0=完全吸收无弹回, 1=完美弹性. 硬碰硬推荐 0.55~0.75. 数学: v_n_new = -v_n_old × e.", ""],
	["wall_hit_kickback",         "Kickback 法线推开速度", 0.0, 30.0,  0.5,
		"撞墙后沿法线推开的瞬时速度 (m/s). 二次方缩放: into=10→1.0×, into=20→4.0×, 高速撞墙真砰一下飞出去. 0=关闭, 推荐 5~15.", ""],
	["wall_straight_tangent_kill", "正撞切向擦除",      0.0,  1.0,   0.05,
		"【弹墙掉头】正撞(非擦墙)时额外衰减切向速度. 1.0=正撞时切向完全清零(车完全沿法线弹回, 最像QQ飞车), 0.0=关闭. 推荐 0.6~0.9.", ""],
	["wall_grazing_angle_deg",    "擦墙临界角(度)",     0.0,  90.0,  1.0,
		"车头与墙面夹角 < 此值时算擦墙(切向额外保留 +15%). 0=平行墙, 90=正面撞. 推荐 15~25.", ""],
	["glass_shatter_min_speed",   "玻璃渣触发最小速度", 0.0,  20.0,  0.5,
		"撞击速度低于此值不出玻璃渣特效, 避免轻碰也碎. 推荐 3 m/s.", ""],

	["__group", "弹墙掉头 (车身 yaw 跟随)"],
	["wall_normal_y_threshold",   "墙判定: 法线 n.y 宽松阈值", 0.0, 1.0, 0.05,
		"【V2 双重判定】法线 n.y < 此值时强制视为墙(不论 slope_wall_angle_deg). 防止用户把 angle_deg 调太严导致弧形墙撞了没反应. 0.7 ≈ 法线与 Y 轴夹角 > 45°. 推荐 0.6~0.75.", ""],
	["wall_turnaround_enabled",   "掉头开关",           0,    1,     1,
		"【弹墙掉头】1=撞墙时车身 yaw 跟着反弹方向转, 车头对准'车要去的地方'(QQ飞车核心视觉). 0=只弹物理车头不转.", ""],
	["wall_turnaround_min_into",  "弹墙掉头: 最小触发速度", 0.0, 30.0, 0.5,
		"【弹墙掉头】低于此撞击速度(m/s)的轻碰不触发车身转向. 推荐 5~10, 5=轻碰也掉头 10=只有明显撞击才掉头.", ""],
	["wall_turnaround_duration",  "弹墙掉头: 持续时长(秒)", 0.0, 1.5, 0.01,
		"【弹墙掉头】车身 yaw 平滑转过去的秒数. 0=瞬间硬切, 0.3=QQ飞车风格平滑转向, 0.5+=慢动作. 推荐 0.25~0.4.", ""],
	["wall_turnaround_max_deg",   "弹墙掉头: 最大角度", 0.0, 180.0, 5.0,
		"【弹墙掉头】单次掉头最多转这么多度. 180=允许原路返回掉头, 120=最多转120°保留一些切向. 推荐 120~180.", ""],
	["wall_turnaround_min_deg",   "弹墙掉头: 最小角度", 0.0, 90.0, 1.0,
		"【弹墙掉头】角差小于此值不触发掉头(避免擦墙时车头抖动). 推荐 15~30.", ""],

	["__group", "防吸住 (V4 关键修复)"],
	["wall_hit_cooldown",         "撞墙冷却(秒)",       0.0,  1.0,   0.01,
		"【V4 防吸住】撞墙触发反弹后此秒数内不再触发新反弹. 解决 trimesh 每帧报告 contact 导致的'撞墙吸住'循环. 推荐 0.10~0.20. 0=关闭(易吸住).", ""],
	["wall_unstick_offset",       "撞墙硬位移(米)",     0.0, 0.5, 0.01,
		"【V4 防吸住】撞墙瞬间沿法线方向硬位移车的位置, 物理上立即脱离接触面. 推荐 0.05~0.15.", ""],
	["wall_hit_speed_cap_mult",   "锁速倍率",           0.5,  2.0,   0.05,
		"撞墙后锁速 cap = max(撞前速度,撞后速度) × 此倍率. 1.5=允许 kickback 飞50%. 推荐 1.3~1.6.", ""],
	["wall_hit_lock_duration",    "锁速时长(秒)",       0.0, 1.5,   0.05,
		"撞墙后锁速窗口持续秒数. 0=关闭, 推荐 0.2~0.5.", ""],
	["wall_hit_cancel_boost",     "撞墙取消 boost",     0,    1,     1,
		"1=撞墙瞬间取消正在进行的 boost. QQ飞车风格建议设 0(撞墙过弯时不要打断喷射). 默认 0.", ""],

	["__page", "⛰️ 坡道"],
	["__group", "推力/重力补偿"],
	["slope_align_thrust",        "推力沿坡面切向",     0,    1,     1,
		"1=上坡时推力沿坡面向上, 不再'水平推'(推荐); 0=老的水平推力, 上坡掉速明显。", ""],
	["slope_gravity_compensation","上坡重力补偿",       0.0,  1.5,   0.05,
		"上坡时额外施力抵消重力沿坡面分量。0=无补偿(掉速明显), 0.85=抵消 85%(推荐), 1.0=完全抵消。下坡不补偿。", ""],
	["slope_compensation_max_deg","补偿最大坡度(度)",   0.0,  90.0,  1.0,
		"超过此坡度不再补偿, 防止峭壁也能往上冲。45 度合理。", ""],

	["__group", "上坡爬升助力"],
	["uphill_assist_enabled",     "上坡助力开关",       0,    1,     1,
		"1=上坡时给额外推力, 克服推力曲线高速段衰减带来的爬坡乏力; 0=禁用(只靠引擎曲线和重力补偿)。", ""],
	["uphill_assist_force",       "助力基础强度",       0.0,  60.0,  0.5,
		"上坡助力的基础推力(直接加到引擎上, 单位与引擎峰值推力同). 推荐 4~10. 这个值会再乘坡度曲线 × 速度曲线 × 油门 × 喷射倍率。", ""],
	["uphill_assist_min_deg",     "触发最小坡度(度)",   0.0,  30.0,  0.5,
		"小于此坡度不施加助力, 避免平地有'莫名加速'。4 度合理。", ""],
	["uphill_assist_max_deg",     "助力最大坡度(度)",   5.0,  90.0,  1.0,
		"助力曲线 X=1 对应的坡度. 超过此角度时助力不再增加。", "uphill_assist_slope_curve"],
	["uphill_assist_require_throttle","需要踩油门",     0,    1,     1,
		"1=只在踩油门时给助力(QQ飞车默认); 0=松油门也给(防溜车下坡)。", ""],
	["uphill_assist_boost_mult",  "喷射期间助力倍率",   0.5,  3.0,   0.05,
		"喷射状态下助力额外乘这个值. 1.0=不变, 1.5=喷射上坡更猛。", "uphill_assist_speed_curve"],


	["__page", "🛫 空喷 / 落地喷"],
	["__group", "空喷 (空中按 W)"],
	["air_boost_enabled",         "空喷开关",           0,    1,     1,
		"1=空中按 W 立即触发空喷(离地瞬间生效); 0=禁用。", ""],
	["air_boost_min_air_time",    "空喷最小腾空(秒)",   0.0,  1.5,   0.01,
		"离地不足这么久按 W 不会触发空喷(防止小颠簸误触发)。0.18 推荐。", ""],
	["air_boost_power",           "空喷推进力",         5.0,  150.0, 1.0,
		"空喷基础推力 × 力度曲线在当前进度的采样。", "air_boost_curve"],
	["air_boost_time",            "空喷持续(秒)",       0.1,  3.0,   0.05,
		"空喷持续秒数。", ""],
	["air_boost_downforce",       "空喷滞空感下压力",   0.0,  30.0,  0.5,
		"空喷期间在空中每帧施加的向下加速度(m/s², 会乘 mass)。给空喷一种'悬浮被推进'的手感, 而不是火箭起飞。0=关闭, 推荐 3~10。", ""],
	["air_boost_shake",           "空喷震屏强度",       0.0,  2.0,   0.05,
		"空喷释放瞬间的震屏强度, 0 = 不震。", ""],
	["air_landing_speed_recover", "落地水平速度补偿",   0.0,  1.0,   0.05,
		"飞行中空气阻力会损耗水平速度, 落地把它拉回。0=不补偿, 1=完全保留起飞前速度, 0.85 推荐。", ""],

	["__group", "落地喷"],
	["landing_boost_enabled",     "落地喷开关",         0,    1,     1,
		"1=飞行足够久后, 稳定落地开启按 W 窗口手动触发(不自动); 0=禁用。", ""],
	["landing_boost_min_air_time","落地喷最小腾空(秒)", 0.0,  3.0,   0.05,
		"必须飞这么久才能触发落地喷。0.8 推荐, 比空喷门槛高。", ""],
	["landing_boost_power",       "落地喷推进力",       5.0,  120.0, 1.0,
		"落地喷基础推力。", "landing_boost_curve"],
	["landing_boost_time",        "落地喷持续(秒)",     0.1,  2.0,   0.05,
		"落地喷持续秒数。", ""],
	["landing_boost_press_window","落地喷按键窗口(秒)", 0.1,  2.0,   0.05,
		"稳定落地后, 玩家可按 W 触发落地喷的时间窗口。0.5 推荐, 太短会错过。", ""],

	["__group", "加速带 / 弹射器"],
	["speed_pad_sustain_power",  "加速带持续推力",     0.0,  60.0,  0.5,
		"加速带触发后, 沿车头方向的持续推力 (m/s² × mass), 随 duration 线性衰减. 加速带本身还有'瞬时增速冲量'(kick), 这个参数是冲量之后的持续段. 0=只有瞬时冲量不持续; 推荐 15~25.", ""],
	["landing_stable_time",       "落地稳定判定(秒)",   0.0,  0.5,   0.005,
		"连续接地此秒数才视为'真正落地'并开放按键窗口, 避免刚蹭一下就触发。0.08 推荐。", ""],
	["landing_stable_max_vy",     "落地稳定 Y 速度上限", 0.0, 20.0, 0.2,
		"Y 速度绝对值超过此值就不算'稳定'(还在砸地过程中)。4 合理。", ""],
	["landing_boost_shake",       "落地喷震屏强度",     0.0,  2.0,   0.05,
		"落地喷触发时震屏强度。", ""],
	["landing_impact_absorb",     "落地冲击吸收",       0.0,  1.0,   0.05,
		"落地瞬间 Y 方向冲击吸收比例。0=保留下落动能造成弹跳, 1=完全吸收平稳落地, 0.85 推荐。", ""],

	# ========================================================
	# 隐藏区: 已废弃 / 不生效参数 (保留兼容旧 cfg, 但不显示在 UI)
	# ========================================================
	["__hidden_start"],
	["air_boost_intent_window",   "(已废弃)空喷意图窗口", 0.1, 5.0,   0.05,
		"【已废弃】旧的'空中按 W 缓存意图等落地'机制, 现在空喷在空中按 W 时立即触发, 不再需要意图窗口.", ""],
	["air_boost_overrides_window","(已废弃)空喷覆盖窗口", 0,   1,     1,
		"【已废弃】配合旧空喷意图窗口逻辑.", ""],
	["landing_boost_stacks_with_air", "(已废弃)落地喷叠加空喷", 0, 1, 1,
		"【已废弃】旧参数, 按键触发模式下用不上.", ""],
	["landing_hard_stick",        "(已废弃)落地强制Y速归零", 0,  1,     1,
		"【已废弃慎用】1=落地瞬间直接把 Y 速度强制为 0. 会和 plain_vy_zero_threshold 防弹打架, 可能导致悬浮.", ""],
	["landing_stick_duration",    "(已废弃)落地压地窗口", 0.0,  1.0,   0.01,
		"【已废弃】这套'压地窗口'机制和原生 plain_vy_zero_threshold + plain_downforce 冲突, 导致落地半秒诡异悬浮.", ""],
	["landing_stick_min_fall_speed","(已废弃)压地最小下落速度",  0.0,  10.0,  0.1,
		"【已废弃】配合压地窗口的阈值, 已禁用。", ""],
	["wall_reflect_tangent_keep", "(已废弃)反弹切向保留(单一)", 0.0,  1.0,   0.05,
		"【已废弃】>0 时优先生效(覆盖 keep_max/keep_min/lerp_speed). 现在用插值模式更好.", ""],
	["wall_slide_boost",          "(已废弃)撞墙切向推力", 0.0, 25.0, 0.5,
		"【已废弃】沿墙面切向推力=滑墙而过. 用户要的是'弹墙掉头', 不是'滑墙'. 保留兼容旧 cfg.", ""],
	["slope_wall_bounce_absorb",  "(已废弃)撞斜面吸收", 0.0,  1.0,   0.05,
		"【已废弃】旧的简单反弹机制, 现在走 wall_reflect_normal_factor.", ""],
	["slope_wall_shake",          "(已废弃)撞斜面震屏", 0.0,  2.0,   0.05,
		"【已废弃】统一用 wall_crash_shake.", ""],
	["__hidden_end"],
]

# 仅当 CarMesh 节点上挂了支持调参的脚本(如 YuqilinTuning) 时才显示
const CAR_MESH_PARAMS := [
	["fbx_scale",                 "玉麒麟整体缩放",            0.001, 5.0,  0.001,
		"玉麒麟 FBX 整体缩放. FBX 原始 ≈ 3×5×3m, 0.025 让车变成约 7.5×12×7.5cm; 1.0 = 原始尺寸.", ""],
	["fbx_rot_y_deg",             "玉麒麟 Y 轴旋转(度)",       -180.0, 180.0, 1.0,
		"车头朝向修正. 0 = FBX 默认; 180 = 车头翻转(QQ飞车端游 FBX 通常需要 180 才能让车头朝 -Z).", ""],
	["fbx_offset_y",              "玉麒麟 Y 偏移(米)",         -3.0, 3.0,  0.01,
		"上下平移车身, 用于让车底贴 RigidBody 球体顶端. + = 车上移.", ""],
	["clearcoat_strength",        "车漆清漆强度",              0.0,  1.0,  0.05,
		"车漆表面那层亮镜面层强度. 0=没清漆(磨砂感), 0.5=一般车漆(默认), 1.0=最强(湿漆/新车感).", ""],
	["clearcoat_roughness",       "车漆清漆粗糙度",            0.0,  1.0,  0.02,
		"清漆层的粗糙度. 0=镜面反射(像新车), 0.3=哑光, 1=磨砂. 推荐 0.05~0.15.", ""],
	["normal_scale",              "法线贴图强度",              0.0,  3.0,  0.05,
		"车身/轮子法线贴图的强度. 0=平坦(无凹凸细节), 1=正常, 2+=过度(不真实). 推荐 0.8~1.5.", ""],
	["subsurf_strength",          "次表面散射强度",            0.0,  1.0,  0.05,
		"车漆的'透感'(阳光下边缘透光). 0=关闭(节省性能), 0.1~0.3 = 轻微透感. 默认 0.", ""],
]

# BoostFX 强度参数(应用到所有 BoostFX 实例, 玉麒麟 5 个 tailpipe 都同步)
const BOOST_FX_PARAMS := [
	["__group", "形状 — 尺寸"],
	["flame_target_length",       "焰柱目标长度(米)",          0.5,  10.0, 0.1,
		"主焰柱尾焰长度. 玉麒麟车身约 5.3m, 推荐 2.5=半个车身. 公式: length = velocity × lifetime.", ""],
	["flame_width_mult",          "焰柱宽度系数",              0.1,  3.0, 0.05,
		"主焰柱粒子粗细. 1.0=默认(约排气管宽), 小=更细, 大=更粗.", ""],
	["__group", "强度"],
	["fx_global_amount_mult",     "喷射特效全局强度",          0.1,  3.0, 0.05,
		"全部喷射特效粒子量倍率(空喷/落地喷/小喷/双喷/氮气). 0.5=减半, 1.0=默认, 太大可能掉帧.", ""],
	["nitro_amount_base",         "氮气基础粒子数",            10,   400, 5,
		"氮气基础粒子数量(0 突破时). 越大越浓.", ""],
	["nitro_amount_mult_0",       "氮气量·0突破倍率",          0.5,  3.0, 0.05,
		"未突破极速时的粒子量倍率.", ""],
	["nitro_amount_mult_1",       "氮气量·1突破倍率(金)",      0.5,  3.0, 0.05,
		"突破1次(金色氮气)时的粒子量倍率.", ""],
	["nitro_amount_mult_2",       "氮气量·2突破倍率(红)",      0.5,  3.0, 0.05,
		"突破2次(红色氮气)时的粒子量倍率.", ""],
	["nitro_scale_mult_0",        "氮气尺寸·0突破",            0.3,  3.0, 0.05,
		"未突破时粒子大小倍率.", ""],
	["nitro_scale_mult_1",        "氮气尺寸·1突破(金)",        0.3,  3.0, 0.05,
		"突破1次时粒子大小倍率.", ""],
	["nitro_scale_mult_2",        "氮气尺寸·2突破(红)",        0.3,  3.0, 0.05,
		"突破2次时粒子大小倍率.", ""],
	["nitro_light_energy_mult_0", "氮气光强·0突破",            0.0,  4.0, 0.05,
		"未突破时灯光强度倍率.", ""],
	["nitro_light_energy_mult_1", "氮气光强·1突破(金)",        0.0,  4.0, 0.05,
		"突破1次时灯光强度倍率.", ""],
	["nitro_light_energy_mult_2", "氮气光强·2突破(红)",        0.0,  4.0, 0.05,
		"突破2次时灯光强度倍率.", ""],
	["nitro_velocity_mult_0",     "氮气速度·0突破",            0.3,  3.0, 0.05,
		"未突破时粒子速度倍率.", ""],
	["nitro_velocity_mult_1",     "氮气速度·1突破(金)",        0.3,  3.0, 0.05,
		"突破1次时粒子速度倍率.", ""],
	["nitro_velocity_mult_2",     "氮气速度·2突破(红)",        0.3,  3.0, 0.05,
		"突破2次时粒子速度倍率.", ""],
	["__group", "星星散粒"],
	["stars_enabled",             "星星开关",                  0.0,  1.0,  1.0,
		"是否显示星星散粒层. 0=全部关闭, 1=启用.", ""],
	["stars_amount_mult",         "星星数量倍率",              0.0,  3.0,  0.1,
		"星星数量整体倍率. 0=没有星星, 1=默认, 2=双倍.", ""],
	["stars_scale_mult",          "星星大小倍率",              0.3,  3.0,  0.05,
		"星星粒子尺寸倍率. 默认 1.0, 想要更小的金色点就调小.", ""],
	["stars_gravity_y",           "星星重力Y",                 -5.0, 5.0,  0.1,
		"星星的 Y 方向重力. 负=往下飘(参考图), 0=悬浮, 正=往上.", ""],
]


const FX_PARAMS := [
	["permanent_marks",           "胎印永久",                  0, 1, 1,
		"1=胎印永不消失(后期会很卡); 0=按生命周期淡出。", ""],
	["tire_mark_only_rear",       "只有后轮留胎印",            0, 1, 1,
		"1=只有后轮; 0=四轮都留。", ""],
	["tire_mark_lifetime",        "胎印淡出时长(秒)",          1.0,  30.0, 0.5,
		"胎印从生成到完全消失的秒数。", ""],
	["tire_mark_interval",        "胎印放置间隔(秒)",          0.01, 0.2,  0.005,
		"两次放置胎印之间的最小间隔, 越小胎印越密。", ""],
	["glow_energy",               "轮胎发光强度",              0.0,  20.0, 0.5,
		"漂移时轮胎/胎印发光强度。", ""],
]

const CAM_PARAMS := [
	["lerp_speed",                "镜头跟随速度",              0.5,  30.0, 0.1,
		"相机插值速度, 越大越紧贴车辆. 高速下若值太小, 相机会被车甩开造成'拉远'感.", ""],
	["max_follow_lag",            "最大滞后距离",              0.0,  30.0, 0.1,
		"相机到车的最大允许距离. 超出立即拉回, 防止高速被甩开. 0 = 不限制.", ""],
	["base_fov_override",         "基础 FOV 覆盖值",           30.0, 120.0,0.5,
		"配合'启用FOV覆盖'使用, 强制把相机 FOV 设成这个值. 越小越像长焦(压缩感), 越大越广角(速度感).", ""],
	["use_base_fov_override",     "启用FOV覆盖",               0,    1,    1,
		"1=用'基础 FOV 覆盖值'强制设定 FOV; 0=沿用场景/玩家在编辑器设的 FOV.", ""],
	["offset.x",                  "基础偏移 X (左右)",         -20.0, 20.0, 0.1,
		"相机基础偏移 X 分量(本地坐标). >0 车辆本地右方.", ""],
	["offset.y",                  "基础偏移 Y (上下)",         -10.0, 20.0, 0.1,
		"相机基础偏移 Y 分量. >0 车辆上方.", ""],
	["offset.z",                  "基础偏移 Z (前后)",         -10.0, 20.0, 0.1,
		"相机基础偏移 Z 分量. >0 车辆后方(通常跟随相机用正值).", ""],
	["nitro_zoom_offset.x",       "氮气拉远 X",                -10.0, 10.0, 0.05,
		"氮气拉远向量 X 分量, 在 offset 基础上额外叠加.", ""],
	["nitro_zoom_offset.y",       "氮气拉远 Y",                -10.0, 10.0, 0.05,
		"氮气拉远向量 Y 分量, 通常轻微抬高.", ""],
	["nitro_zoom_offset.z",       "氮气拉远 Z",                -10.0, 10.0, 0.05,
		"氮气拉远向量 Z 分量, 通常正值把镜头推后.", ""],
	["nitro_zoom_duration",       "氮气拉远持续(秒)",          0.0,  6.0,  0.1,
		"氮气期间镜头拉远效果持续时间.", ""],
	["nitro_fov_boost",           "氮气FOV增量(度)",           0.0,  30.0, 0.5,
		"氮气期间 FOV 临时增加多少度, 增强速度感.", "nitro_zoom_curve"],
	["double_zoom_scale",         "双喷拉远倍率",              0.0,  2.0,  0.05,
		"双喷拉远偏移 = 氮气偏移 × 此值.", "double_zoom_curve"],
	["double_zoom_duration",      "双喷拉远持续(秒)",          0.0,  3.0,  0.05,
		"双喷期间镜头拉远持续秒数.", ""],
	["double_fov_boost",          "双喷FOV增量(度)",           0.0,  20.0, 0.5,
		"双喷期间 FOV 增加量.", ""],
	["mini_zoom_scale",           "小喷拉远倍率(0=不拉)",      0.0,  1.5,  0.05,
		"小喷拉远偏移 = 氮气偏移 × 此值, 0 表示小喷不拉远.", "mini_zoom_curve"],
	["mini_zoom_duration",        "小喷拉远持续(秒)",          0.0,  2.0,  0.05,
		"小喷期间镜头拉远持续秒数.", ""],
	["mini_fov_boost",            "小喷FOV增量(度)",           0.0,  15.0, 0.5,
		"小喷期间 FOV 增加量.", ""],
	["zoom_lerp_speed",           "拉远/FOV平滑速度",          0.5,  15.0, 0.1,
		"镜头偏移和 FOV 变化的平滑速度, 越大变化越突兀.", ""],
	["shake_y_factor",            "震动 Y 衰减系数",            0.0,  2.0,  0.05,
		"垂直方向震动相对水平的衰减比例.", ""],
	["shake_z_factor",            "震动 Z 衰减系数",            0.0,  2.0,  0.05,
		"前后方向震动相对水平的衰减比例.", ""],
	["y_stabilizer_enabled",      "Y 稳定器开关",              0,    1,    1,
		"1=过滤平地微抖引起的相机抖动(推荐); 0=相机 Y 完全跟车.", ""],
	["y_deadzone",                "Y 死区(米)",                0.0,  1.0,  0.01,
		"相机与车 Y 差距小于此值时'极慢追'而非完全不动(消除一抖一停). 坑洼路面 0.3 推荐, 大=稳但大起伏响应慢, 小=灵敏但易抖.", ""],
	["y_follow_speed_mult",       "Y 跟随速度倍率",            0.0,  2.0,  0.05,
		"死区外 Y 方向 lerp 速度的倍率(相对水平). 0.2 推荐(坑洼路面), 越小越慢追 Y 变化.", ""],
	["y_force_follow_vy",         "Y 强制跟随速度阈值",        0.0,  20.0, 0.1,
		"车 Y 速度绝对值超过此值时立即完全跟随(起跳/落地). 3.0 推荐.", ""],
	["lookahead_distance",        "焦点前瞻距离(米)",          0.0,  15.0, 0.1,
		"焦点向车头方向偏移多少米. 0=镜头完全看车(可能从上往下看), 3~6=镜头看到车前方一点路(推荐). 用车头方向(不是速度), 漂移时不会甩飞.", ""],
	["lookahead_height",          "焦点高度偏移(米)",          -3.0, 5.0,  0.1,
		"焦点 Y 偏移. 0=与车同高(可能镜头俯视), 0.3~0.8=焦点在车前上方一点(推荐), 让镜头平视前方而不是俯视赛车.", ""],
]

# 曲线属性默认范围(都是 0..1 → 0..1+)
const CURVE_PROPS := {
	"mini_boost_curve":   {"target": "car"},
	"double_boost_curve": {"target": "car"},
	"nitro_boost_curve":  {"target": "car"},
	"mini_zoom_curve":    {"target": "cam"},
	"double_zoom_curve":  {"target": "cam"},
	"nitro_zoom_curve":   {"target": "cam"},
	# V2 曲线
	"engine_force_curve":                 {"target": "car"},
	"brake_force_curve":                  {"target": "car"},
	"friction_long_speed_curve_normal":   {"target": "car"},
	"friction_lat_speed_curve_normal":    {"target": "car"},
	"friction_long_speed_curve_drift":    {"target": "car"},
	"friction_lat_speed_curve_drift":     {"target": "car"},
	"drift_engage_curve":                 {"target": "car"},
	"drift_disengage_curve":              {"target": "car"},
	"drift_head_yaw_curve":               {"target": "car"},
	"drift_body_tilt_curve":              {"target": "car"},
	"drift_centripetal_curve":            {"target": "car"},
	"drift_speed_brake_curve":            {"target": "car"},
	"air_boost_curve":                    {"target": "car"},
	"landing_boost_curve":                {"target": "car"},
	"uphill_assist_slope_curve":          {"target": "car"},
	"uphill_assist_speed_curve":          {"target": "car"},
}

## cfg 保存路径
## ⚠️ 历史教训: 之前用 "user://tune.cfg", 但 user:// 在 Godot 里会被解析为
##   %APPDATA%\Godot\app_userdata\<config/name>\tune.cfg
##   只要 project.godot 里的 config/name 一改, user:// 就指向新目录, 旧 cfg 读不到,
##   用户会以为"调好的参数全丢了"。
## 解决方案: 用项目固定别名 "SimpleRacerLab" 作为 app_userdata 子目录, 绕开 config/name。
##   这样不管以后项目名怎么改中文/英文/加 emoji, cfg 都落在同一个地方。
## 迁移: 启动时如果固定目录没 cfg, 会自动从 user:// 和几个历史目录名尝试继承一次。
const STABLE_PROJECT_ALIAS := "SimpleRacerLab"
## 历史 user_data 目录名候选 (按优先级), 用于首次启动自动迁移旧 cfg
const LEGACY_USER_DIR_NAMES: Array[String] = [
	"3d_car_sphere",       # 原始项目文件夹名 (最常见, 长期使用)
	"StarDust Racers",     # 早期项目名
	"SpeedRacer3C",        # 更早期项目名
	"简单飞车试验场",       # 2026-05-12 定型稿改的新名
]

## 返回 cfg 保存目录的绝对路径 (app_userdata\SimpleRacerLab)
## 做法: 拿当前 user_data_dir (app_userdata\<config_name>), 上一层得到 app_userdata, 再拼别名
static func _stable_cfg_dir() -> String:
	var current := OS.get_user_data_dir()            # 例: .../app_userdata/简单飞车试验场
	var parent := current.get_base_dir()              # 例: .../app_userdata
	return parent.path_join(STABLE_PROJECT_ALIAS)     # 例: .../app_userdata/SimpleRacerLab

static func _stable_cfg_path() -> String:
	return _stable_cfg_dir().path_join("tune.cfg")

## 该常量保留给老代码引用; 实际读写走 _stable_cfg_path()
const SAVE_PATH := "user://tune.cfg"

# ============================================================
#  生命周期
# ============================================================
func _ready() -> void:
	# 首启动 cfg 迁移: 确保旧项目名下调好的 tune.cfg 能继承到稳定目录
	# (详见 _ensure_cfg_migrated 注释)
	_ensure_cfg_migrated()
	_build_ui()
	visible = true
	_panel.visible = true
	call_deferred("_bind_car")
	# 延迟一帧等 _bind_car 完成, 再自动从 cfg 恢复参数
	call_deferred("_auto_load_on_start")


## 启动时自动加载 cfg (如果稳定目录有 tune.cfg)
## 这样用户不需要每次手动按"加载"按钮
func _auto_load_on_start() -> void:
	var p := _stable_cfg_path()
	if FileAccess.file_exists(p):
		_load_from_file()


## cfg 迁移: 首次启动 (或改完项目名后第一次启动) 时,
## 如果稳定目录 app_userdata\SimpleRacerLab\tune.cfg 不存在,
## 就从 LEGACY_USER_DIR_NAMES 里按优先级找一个现存的 tune.cfg 复制过来。
## 注意: 这是"继承", 只读不删旧的。旧目录的 cfg 保留, 万一出问题还能手动回滚。
func _ensure_cfg_migrated() -> void:
	var stable_path := _stable_cfg_path()
	if FileAccess.file_exists(stable_path):
		return  # 已经有了, 不动
	var stable_dir := _stable_cfg_dir()
	# 先确保稳定目录存在
	DirAccess.make_dir_recursive_absolute(stable_dir)
	# 到 app_userdata 上层去找历史目录
	var app_userdata_root := OS.get_user_data_dir().get_base_dir()
	for legacy_name in LEGACY_USER_DIR_NAMES:
		var legacy_path := app_userdata_root.path_join(legacy_name).path_join("tune.cfg")
		if FileAccess.file_exists(legacy_path):
			var bytes := FileAccess.get_file_as_bytes(legacy_path)
			var out := FileAccess.open(stable_path, FileAccess.WRITE)
			if out:
				out.store_buffer(bytes)
				out.close()
				print("[Tuner] cfg 首次迁移: ", legacy_path, " → ", stable_path, " (", bytes.size(), " 字节)")
			else:
				push_warning("[Tuner] cfg 迁移失败: 无法写入 %s" % stable_path)
			return
	print("[Tuner] 稳定目录无 cfg, 历史目录也无 cfg, 首次使用默认值")




func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_panel.visible = not _panel.visible
			get_viewport().set_input_as_handled()


func _bind_car() -> void:
	if car_path.is_empty() or not has_node(car_path):
		push_warning("Tuner: car_path 未找到")
		return
	car = get_node(car_path)

	# 同步 car 参数默认值
	for p in PARAMS:
		if p[0] == "__group":
			continue
		var prop: String = p[0]
		if not _has_prop(car, prop):
			continue
		var v = _read_prop(car, prop)
		_defaults[prop] = v
		if _rows.has(prop):
			_rows[prop].slider.set_value_no_signal(float(v))
			_rows[prop].spin.set_value_no_signal(float(v))

	# FX 参数
	var fx = _get_drift_fx()
	if fx:
		for p in FX_PARAMS:
			var prop: String = p[0]
			if not _has_prop(fx, prop):
				continue
			var v = _read_prop(fx, prop)
			_defaults[prop] = v
			if _rows.has(prop):
				_rows[prop].slider.set_value_no_signal(float(v))
				_rows[prop].spin.set_value_no_signal(float(v))

	# CAM 参数
	var cam = _get_camera()
	if cam:
		for p in CAM_PARAMS:
			var prop: String = p[0]
			if not _has_prop(cam, prop):
				continue
			var v = _read_prop(cam, prop)
			_defaults[prop] = v
			if _rows.has(prop):
				_rows[prop].slider.set_value_no_signal(float(v))
				_rows[prop].spin.set_value_no_signal(float(v))

	# CarMesh 参数 (玉麒麟外观调参)
	var car_mesh = _get_car_mesh()
	if car_mesh:
		for p in CAR_MESH_PARAMS:
			var prop: String = p[0]
			if not _has_prop(car_mesh, prop):
				continue
			var v = _read_prop(car_mesh, prop)
			_defaults[prop] = v
			if _rows.has(prop):
				_rows[prop].slider.set_value_no_signal(float(v))
				_rows[prop].spin.set_value_no_signal(float(v))

	# BoostFX 参数 (从第一个 BoostFX 读初始值)
	var bfx = _get_boost_fx_first()
	if bfx:
		for p in BOOST_FX_PARAMS:
			var prop: String = p[0]
			if not _has_prop(bfx, prop):
				continue
			var v = _read_prop(bfx, prop)
			_defaults[prop] = v
			if _rows.has(prop):
				_rows[prop].slider.set_value_no_signal(float(v))
				_rows[prop].spin.set_value_no_signal(float(v))

	# 加载所有曲线: 优先复用目标对象已有曲线(如 car.gd V2 默认值), 否则用 LINEAR_FULL 兜底
	for cprop in CURVE_PROPS.keys():
		var existing: Curve = _read_curve_from_target(cprop)
		var c: Curve = existing if existing != null and existing.point_count > 1 else _build_preset_curve("LINEAR_FULL")
		_curves[cprop] = c
		_apply_curve_to_target(cprop, c)

	_load_from_file()


func _read_curve_from_target(curve_prop: String) -> Curve:
	var meta = CURVE_PROPS.get(curve_prop, {})
	var target_name: String = meta.get("target", "car")
	var target: Object = car
	if target_name == "cam":
		target = _get_camera()
	elif target_name == "fx":
		target = _get_drift_fx()
	if target and curve_prop in target:
		var v = target.get(curve_prop)
		if v is Curve:
			return v
	return null


# ============================================================
#  目标对象
# ============================================================
func _get_drift_fx() -> Node:
	if not car:
		return null
	for c in car.get_children():
		if c.name == "DriftFX" or c.get_script() and str(c.get_script().resource_path).ends_with("DriftFX.gd"):
			return c
	return null


# 获取所有 BoostFX 实例 (玉麒麟有 5 个 tailpipe → 5 个; SUV 是 1 个)
func _get_boost_fx_all() -> Array:
	var out: Array = []
	if car == null:
		return out
	_collect_boost_fx_recursive(car, out)
	return out


func _collect_boost_fx_recursive(node: Node, out: Array) -> void:
	for c in node.get_children():
		var s: Script = c.get_script() as Script
		if s != null and str(s.resource_path).ends_with("BoostFX.gd"):
			out.append(c)
		else:
			_collect_boost_fx_recursive(c, out)


# 返回第一个 BoostFX, 用于读取初始值
func _get_boost_fx_first() -> Node:
	var arr := _get_boost_fx_all()
	if arr.is_empty():
		return null
	return arr[0]


func _get_camera() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return _find_camera_recursive(scene)


func _find_camera_recursive(node: Node) -> Node:
	if node is Camera3D:
		return node
	for c in node.get_children():
		var found: Node = _find_camera_recursive(c)
		if found:
			return found
	return null


# ============================================================
#  应用值
# ============================================================
func _read_prop(target: Object, prop: String):
	# 支持 "vec.x" 形式读取 Vector3 分量
	if target == null:
		return null
	if "." in prop:
		var parts: PackedStringArray = prop.split(".")
		if parts.size() == 2 and parts[0] in target:
			var vec = target.get(parts[0])
			if vec is Vector3:
				match parts[1]:
					"x": return vec.x
					"y": return vec.y
					"z": return vec.z
		return null
	if prop in target:
		return target.get(prop)
	return null


func _has_prop(target: Object, prop: String) -> bool:
	if target == null:
		return false
	if "." in prop:
		var parts: PackedStringArray = prop.split(".")
		return parts.size() == 2 and parts[0] in target and (target.get(parts[0]) is Vector3)
	return prop in target


func _apply_to(target: Object, prop: String, v: float) -> void:
	if not target:
		return
	# 支持 Vector3 分量访问: "offset.x" / "nitro_zoom_offset.y" 等
	if "." in prop:
		var parts: PackedStringArray = prop.split(".")
		if parts.size() == 2:
			var base_prop: String = parts[0]
			var comp: String = parts[1]
			if base_prop in target:
				var vec = target.get(base_prop)
				if vec is Vector3:
					match comp:
						"x": vec.x = v
						"y": vec.y = v
						"z": vec.z = v
					target.set(base_prop, vec)
					return
		return
	if not prop in target:
		return
	var current = target.get(prop)
	if typeof(current) == TYPE_INT:
		target.set(prop, int(round(v)))
	elif typeof(current) == TYPE_BOOL:
		target.set(prop, v >= 0.5)
	else:
		target.set(prop, v)


func _dispatch_apply(kind: String, prop: String, v: float) -> void:
	match kind:
		"fx":
			_apply_to(_get_drift_fx(), prop, v)
		"cam":
			_apply_to(_get_camera(), prop, v)
		"car_mesh":
			_apply_to(_get_car_mesh(), prop, v)
		"boost_fx":
			# 应用到所有 BoostFX (玉麒麟 5 个 tailpipe 都同步)
			for fx in _get_boost_fx_all():
				_apply_to(fx, prop, v)
		_:
			_apply_to(car, prop, v)


func _get_car_mesh() -> Node:
	# 返回 car 节点下的 CarMesh (可能是 YuqilinMesh 等带 export 调参属性的脚本)
	if car == null:
		return null
	return car.get_node_or_null("CarMesh")


func _apply_curve_to_target(curve_prop: String, curve: Curve) -> void:
	var meta = CURVE_PROPS.get(curve_prop, {})
	var target_name: String = meta.get("target", "car")
	var target: Object = car
	if target_name == "cam":
		target = _get_camera()
	elif target_name == "fx":
		target = _get_drift_fx()
	if target and curve_prop in target:
		target.set(curve_prop, curve)


# ============================================================
#  UI 构建
# ============================================================
func _build_ui() -> void:
	_panel = PanelContainer.new()
	# 左侧 1/3 屏幕宽
	_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	var vp_w: float = float(get_viewport().get_visible_rect().size.x)
	if vp_w <= 0.0:
		vp_w = 1280.0
	var panel_w: int = int(clampf(vp_w / 3.0, 340.0, 520.0))
	_panel.offset_left = 8
	_panel.offset_top = 8
	_panel.offset_right = 8 + panel_w
	_panel.offset_bottom = -8
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# 监听视口大小变化, 动态调整宽度
	get_viewport().size_changed.connect(_on_viewport_resize)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	_panel.add_child(root)

	var title := Label.new()
	title.text = "🔧 调参  (TAB 切换显示)"
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	root.add_child(title)

	# 工具栏
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 4)
	root.add_child(tools)
	var btn_reset := Button.new(); btn_reset.text = "重置"; btn_reset.add_theme_font_size_override("font_size", 11); btn_reset.pressed.connect(_on_reset); tools.add_child(btn_reset)
	var btn_save := Button.new(); btn_save.text = "保存"; btn_save.add_theme_font_size_override("font_size", 11); btn_save.pressed.connect(_on_save); tools.add_child(btn_save)
	var btn_load := Button.new(); btn_load.text = "加载"; btn_load.add_theme_font_size_override("font_size", 11); btn_load.pressed.connect(_on_load); tools.add_child(btn_load)

	# === 竖排 tab: 左侧 ItemList 做侧边栏, 右侧 VBox 装参数页 ===
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 4)
	root.add_child(body)

	_tab_list = ItemList.new()
	_tab_list.custom_minimum_size = Vector2(90, 0)
	_tab_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_list.add_theme_font_size_override("font_size", 11)
	_tab_list.allow_reselect = true
	body.add_child(_tab_list)

	# 右侧: 一个 ScrollContainer, 里面根据当前 tab 显示对应 VBox
	_tab_content_holder = Panel.new()
	_tab_content_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_content_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_tab_content_holder)
	var holder_vb := VBoxContainer.new()
	holder_vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder_vb.offset_left = 2
	holder_vb.offset_right = -2
	holder_vb.offset_top = 2
	holder_vb.offset_bottom = -2
	_tab_content_holder.add_child(holder_vb)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder_vb.add_child(scroll)

	var pages_root := VBoxContainer.new()
	pages_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pages_root)
	_pages_root = pages_root

	# 解析 PARAMS: 支持三级分类
	#   __page : 顶级页签 (左侧 tab 栏的一项)
	#   __group: 页内大标题 (高亮黄色, 视觉分组)
	#   __sub  : 大标题下的小标题 (浅色细字)
	#   __hidden_start / __hidden_end : 包裹的参数被隐藏(不显示在 UI), 但仍兼容旧 cfg
	# 兼容旧版: 若 PARAMS 顶部没有 __page, 第一段 __group 自动创建一个 tab
	var current_list: VBoxContainer = null
	var current_tab_name: String = ""
	var hidden_mode: bool = false
	for p in PARAMS:
		if p[0] == "__hidden_start":
			hidden_mode = true
			continue
		if p[0] == "__hidden_end":
			hidden_mode = false
			continue
		if hidden_mode:
			continue   # 跳过所有 hidden 区参数, 不显示但 _bind_car 仍会读取它们
		if p[0] == "__page":
			# 顶级页签
			current_tab_name = _strip_bbcode(p[1])
			current_list = _create_tab_page(current_tab_name)
		elif p[0] == "__group":
			# 页内大标题
			if current_list == null:
				current_tab_name = _strip_bbcode(p[1])
				current_list = _create_tab_page(current_tab_name)
			else:
				_add_group_header(current_list, _strip_bbcode(p[1]))
		elif p[0] == "__sub":
			# 大标题下的小标题
			if current_list != null:
				_add_sub_header(current_list, _strip_bbcode(p[1]))
		else:
			if current_list == null:
				current_tab_name = "其他"
				current_list = _create_tab_page(current_tab_name)
			_add_param_row(current_list, p, "car")

	# FX / CAM 各自一个 Tab
	var fx_list: VBoxContainer = _create_tab_page("漂移特效")
	for p in FX_PARAMS:
		_add_param_row(fx_list, p, "fx")

	var cam_list: VBoxContainer = _create_tab_page("镜头")
	for p in CAM_PARAMS:
		_add_param_row(cam_list, p, "cam")

	# 玉麒麟外观调参 Tab (只对挂了 YuqilinTuning 脚本的 CarMesh 生效, 否则参数不会被应用)
	var car_mesh_list: VBoxContainer = _create_tab_page("玉麒麟外观")
	for p in CAR_MESH_PARAMS:
		_add_param_row(car_mesh_list, p, "car_mesh")

	# 喷射特效强度 Tab (BoostFX)
	var bfx_list: VBoxContainer = _create_tab_page("喷射特效强度")
	for p in BOOST_FX_PARAMS:
		_add_param_row(bfx_list, p, "boost_fx")

	# 默认选中第一个 tab
	if _tab_list.item_count > 0:
		_tab_list.select(0)
		_on_tab_selected(0)
	_tab_list.item_selected.connect(_on_tab_selected)


# 竖排 tab 相关状态
var _tab_list: ItemList
var _tab_content_holder: Panel
var _pages_root: VBoxContainer
var _tab_pages: Array[VBoxContainer] = []


func _on_viewport_resize() -> void:
	if _panel == null:
		return
	var vp_w: float = float(get_viewport().get_visible_rect().size.x)
	if vp_w <= 0.0:
		return
	var panel_w: int = int(clampf(vp_w / 3.0, 340.0, 520.0))
	_panel.offset_right = 8 + panel_w


func _create_tab_page(tab_name: String) -> VBoxContainer:
	_tab_list.add_item(tab_name)
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 2)
	page.visible = false
	_pages_root.add_child(page)
	_tab_pages.append(page)
	return page


func _on_tab_selected(idx: int) -> void:
	for i in range(_tab_pages.size()):
		_tab_pages[i].visible = (i == idx)


# 简单去除 [b][/b] 等 bbcode 标签, 用于 Tab 标题
func _strip_bbcode(s: String) -> String:
	var out: String = s
	out = out.replace("[b]", "").replace("[/b]", "")
	out = out.replace("[i]", "").replace("[/i]", "")
	return out


func _add_group_header(parent: Node, title_text: String) -> void:
	var sep := HSeparator.new()
	parent.add_child(sep)
	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.scroll_active = false
	lbl.text = "[color=#ffcc66]%s[/color]" % title_text
	lbl.add_theme_font_size_override("normal_font_size", 15)
	parent.add_child(lbl)


# 小标题 (大标题下的子分组). 比 group 字号小, 颜色浅, 不加分隔线
func _add_sub_header(parent: Node, title_text: String) -> void:
	var lbl := RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.scroll_active = false
	lbl.text = "[color=#aac4e8]· %s[/color]" % title_text
	lbl.add_theme_font_size_override("normal_font_size", 12)
	parent.add_child(lbl)


# 单行参数: [prop, label, vmin, vmax, step, tooltip, curve_prop]
func _add_param_row(parent: Node, p: Array, kind: String) -> void:
	var prop: String = p[0]
	# 特殊行: __group 在 tab 内插入章节标题(非参数行)
	# 主 PARAMS 走页签分页不会到这里, BoostFX/FX/CAM 等 tab 内部分组时用
	if prop == "__group":
		var section_label := Label.new()
		section_label.text = _strip_bbcode(p[1])
		section_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.25, 1.0))
		section_label.add_theme_font_size_override("font_size", 13)
		parent.add_child(section_label)
		return
	var label_text: String = p[1]
	var vmin: float = float(p[2])
	var vmax: float = float(p[3])
	var step: float = float(p[4])
	var tooltip: String = p[5] if p.size() > 5 else ""
	var curve_prop: String = p[6] if p.size() > 6 else ""

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	parent.add_child(row)

	# 参数名(可点击修改范围)
	var name_btn := Button.new()
	name_btn.text = label_text
	name_btn.flat = true
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.custom_minimum_size = Vector2(120, 0)
	name_btn.clip_text = true
	name_btn.add_theme_font_size_override("font_size", 11)
	name_btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	name_btn.tooltip_text = tooltip
	name_btn.pressed.connect(func(): _open_range_editor(prop))
	row.add_child(name_btn)

	var slider := HSlider.new()
	slider.min_value = vmin
	slider.max_value = vmax
	slider.step = step
	slider.custom_minimum_size = Vector2(80, 18)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.tooltip_text = tooltip
	row.add_child(slider)

	var spin := SpinBox.new()
	spin.min_value = vmin
	spin.max_value = vmax
	spin.step = step
	spin.custom_minimum_size = Vector2(58, 0)
	spin.tooltip_text = tooltip
	# 调窄 SpinBox 里的数值显示区域
	var line_edit: LineEdit = spin.get_line_edit()
	if line_edit:
		line_edit.add_theme_font_size_override("font_size", 11)
	row.add_child(spin)

	# 曲线编辑按钮(仅对绑定 curve_prop 的参数显示)
	var curve_btn: Button = null
	if curve_prop != "":
		curve_btn = Button.new()
		curve_btn.text = "🎨"
		curve_btn.tooltip_text = "编辑曲线: " + curve_prop
		curve_btn.custom_minimum_size = Vector2(24, 0)
		curve_btn.add_theme_font_size_override("font_size", 11)
		curve_btn.pressed.connect(func(): _open_curve_editor(curve_prop))
		row.add_child(curve_btn)

	# 双向绑定
	slider.value_changed.connect(func(v: float) -> void:
		spin.set_value_no_signal(v)
		_dispatch_apply(kind, prop, v)
	)
	spin.value_changed.connect(func(v: float) -> void:
		slider.set_value_no_signal(v)
		_dispatch_apply(kind, prop, v)
	)

	_rows[prop] = {
		"slider": slider, "spin": spin, "kind": kind,
		"name_btn": name_btn, "min": vmin, "max": vmax, "step": step,
		"curve_prop": curve_prop, "curve_btn": curve_btn,
		"label": label_text, "tooltip": tooltip
	}


# ============================================================
#  范围编辑弹窗
# ============================================================
func _open_range_editor(prop: String) -> void:
	if not _rows.has(prop):
		return
	var row = _rows[prop]
	var dlg := AcceptDialog.new()
	dlg.title = "编辑范围: " + row.label
	dlg.dialog_hide_on_ok = true
	dlg.min_size = Vector2(360, 180)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	dlg.add_child(vb)

	var tip := Label.new()
	tip.text = row.tooltip
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	tip.add_theme_font_size_override("font_size", 12)
	tip.custom_minimum_size = Vector2(340, 0)
	vb.add_child(tip)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	vb.add_child(grid)

	var lbl_min := Label.new(); lbl_min.text = "最小值"; grid.add_child(lbl_min)
	var sp_min := SpinBox.new(); sp_min.allow_lesser = true; sp_min.allow_greater = true; sp_min.step = row.step; sp_min.value = row.min; grid.add_child(sp_min)
	var lbl_max := Label.new(); lbl_max.text = "最大值"; grid.add_child(lbl_max)
	var sp_max := SpinBox.new(); sp_max.allow_lesser = true; sp_max.allow_greater = true; sp_max.step = row.step; sp_max.value = row.max; grid.add_child(sp_max)
	var lbl_step := Label.new(); lbl_step.text = "步长"; grid.add_child(lbl_step)
	var sp_step := SpinBox.new(); sp_step.allow_lesser = true; sp_step.allow_greater = true; sp_step.step = 0.001; sp_step.value = row.step; grid.add_child(sp_step)

	dlg.confirmed.connect(func():
		var new_min: float = sp_min.value
		var new_max: float = sp_max.value
		var new_step: float = sp_step.value
		if new_max <= new_min:
			new_max = new_min + maxf(new_step, 0.001)
		row.min = new_min
		row.max = new_max
		row.step = new_step
		row.slider.min_value = new_min
		row.slider.max_value = new_max
		row.slider.step = new_step
		row.spin.min_value = new_min
		row.spin.max_value = new_max
		row.spin.step = new_step
		# 把当前值夹紧到新范围
		var cur_v: float = clampf(row.spin.value, new_min, new_max)
		row.spin.value = cur_v
		row.slider.value = cur_v
	)
	add_child(dlg)
	dlg.popup_centered()


# ============================================================
#  曲线编辑器
# ============================================================
const CURVE_PRESETS := [
	"LINEAR_FULL", "LINEAR_FADE_IN", "LINEAR_FADE_OUT",
	"CONSTANT_FULL", "CONSTANT_HALF",
	"EASE_IN_QUAD", "EASE_OUT_QUAD", "EASE_IN_OUT_QUAD",
	"EASE_IN_CUBIC", "EASE_OUT_CUBIC", "EASE_IN_OUT_CUBIC",
	"EASE_OUT_EXPO", "EASE_OUT_BACK",
	"BOOST_KICK",      # 起始猛 → 衰减
	"BOOST_RAMP",      # 平缓上升 → 顶部
	"BOOST_PULSE",     # 高 → 低 → 高(脉冲感)
	"BOOST_BELL",      # 钟形(中间最强)
	"BOOST_SUSTAIN",   # 起始爆发 + 保持
	"NITRO_CLASSIC",   # 类似 QQ 飞车氮气曲线
	"DRIFT_BOOST",     # 退漂小喷曲线: 起步爆发后衰减
]


func _build_preset_curve(name: String) -> Curve:
	var c := Curve.new()
	c.bake_resolution = 100
	match name:
		"LINEAR_FULL":
			c.add_point(Vector2(0.0, 1.0))
			c.add_point(Vector2(1.0, 1.0))
		"LINEAR_FADE_IN":
			c.add_point(Vector2(0.0, 0.0))
			c.add_point(Vector2(1.0, 1.0))
		"LINEAR_FADE_OUT":
			c.add_point(Vector2(0.0, 1.0))
			c.add_point(Vector2(1.0, 0.0))
		"CONSTANT_FULL":
			c.add_point(Vector2(0.0, 1.0))
			c.add_point(Vector2(1.0, 1.0))
		"CONSTANT_HALF":
			c.add_point(Vector2(0.0, 0.5))
			c.add_point(Vector2(1.0, 0.5))
		"EASE_IN_QUAD":
			for i in range(11):
				var t: float = i / 10.0
				c.add_point(Vector2(t, t * t))
		"EASE_OUT_QUAD":
			for i in range(11):
				var t: float = i / 10.0
				c.add_point(Vector2(t, 1.0 - (1.0 - t) * (1.0 - t)))
		"EASE_IN_OUT_QUAD":
			for i in range(11):
				var t: float = i / 10.0
				var v: float
				if t < 0.5:
					v = 2.0 * t * t
				else:
					v = 1.0 - pow(-2.0 * t + 2.0, 2.0) / 2.0
				c.add_point(Vector2(t, v))
		"EASE_IN_CUBIC":
			for i in range(11):
				var t: float = i / 10.0
				c.add_point(Vector2(t, t * t * t))
		"EASE_OUT_CUBIC":
			for i in range(11):
				var t: float = i / 10.0
				c.add_point(Vector2(t, 1.0 - pow(1.0 - t, 3.0)))
		"EASE_IN_OUT_CUBIC":
			for i in range(11):
				var t: float = i / 10.0
				var v: float
				if t < 0.5:
					v = 4.0 * t * t * t
				else:
					v = 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0
				c.add_point(Vector2(t, v))
		"EASE_OUT_EXPO":
			for i in range(11):
				var t: float = i / 10.0
				var v: float = 1.0 if t >= 1.0 else 1.0 - pow(2.0, -10.0 * t)
				c.add_point(Vector2(t, v))
		"EASE_OUT_BACK":
			var c1: float = 1.70158
			var c3: float = c1 + 1.0
			for i in range(11):
				var t: float = i / 10.0
				c.add_point(Vector2(t, 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0)))
		"BOOST_KICK":
			c.add_point(Vector2(0.0, 1.5))
			c.add_point(Vector2(0.2, 1.2))
			c.add_point(Vector2(0.6, 0.8))
			c.add_point(Vector2(1.0, 0.4))
		"BOOST_RAMP":
			c.add_point(Vector2(0.0, 0.4))
			c.add_point(Vector2(0.5, 0.8))
			c.add_point(Vector2(1.0, 1.2))
		"BOOST_PULSE":
			c.add_point(Vector2(0.0, 1.3))
			c.add_point(Vector2(0.3, 0.6))
			c.add_point(Vector2(0.6, 1.2))
			c.add_point(Vector2(1.0, 0.5))
		"BOOST_BELL":
			c.add_point(Vector2(0.0, 0.4))
			c.add_point(Vector2(0.5, 1.3))
			c.add_point(Vector2(1.0, 0.4))
		"BOOST_SUSTAIN":
			c.add_point(Vector2(0.0, 1.4))
			c.add_point(Vector2(0.15, 1.0))
			c.add_point(Vector2(0.85, 1.0))
			c.add_point(Vector2(1.0, 0.7))
		"NITRO_CLASSIC":
			c.add_point(Vector2(0.0, 1.6))
			c.add_point(Vector2(0.1, 1.3))
			c.add_point(Vector2(0.4, 1.1))
			c.add_point(Vector2(0.8, 0.9))
			c.add_point(Vector2(1.0, 0.6))
		"DRIFT_BOOST":
			c.add_point(Vector2(0.0, 1.8))
			c.add_point(Vector2(0.3, 1.0))
			c.add_point(Vector2(1.0, 0.5))
		_:
			c.add_point(Vector2(0.0, 1.0))
			c.add_point(Vector2(1.0, 1.0))
	return c


func _open_curve_editor(curve_prop: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "曲线编辑: " + curve_prop
	dlg.min_size = Vector2(620, 480)
	dlg.dialog_hide_on_ok = true

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	dlg.add_child(vb)

	# 预设选择
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	vb.add_child(preset_row)
	var lbl := Label.new(); lbl.text = "预设:"; preset_row.add_child(lbl)
	var opt := OptionButton.new()
	for name in CURVE_PRESETS:
		opt.add_item(name)
	preset_row.add_child(opt)

	# 曲线编辑控件
	var cur: Curve = _curves.get(curve_prop, _build_preset_curve("LINEAR_FULL"))
	var editor := _CurveEditor.new()
	editor.set_curve(cur)
	editor.custom_minimum_size = Vector2(580, 320)
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(editor)

	var hint := Label.new()
	hint.text = "拖拽点修改 / 双击空白添加 / 右键删除点。X 轴=时间归一化(0~1), Y 轴=力度倍率(0~2)"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vb.add_child(hint)

	opt.item_selected.connect(func(idx: int) -> void:
		var preset_name: String = CURVE_PRESETS[idx]
		var new_curve: Curve = _build_preset_curve(preset_name)
		_curves[curve_prop] = new_curve
		editor.set_curve(new_curve)
		_apply_curve_to_target(curve_prop, new_curve)
	)

	dlg.confirmed.connect(func():
		_curves[curve_prop] = editor.get_curve()
		_apply_curve_to_target(curve_prop, editor.get_curve())
	)

	add_child(dlg)
	dlg.popup_centered()


# ============================================================
#  内嵌曲线编辑控件
# ============================================================
class _CurveEditor extends Control:
	var _curve: Curve = null
	var _y_max: float = 2.0   # Y 轴上限(力度倍率最大显示 2)
	var _drag_idx: int = -1
	var _hover_idx: int = -1
	const POINT_RADIUS: float = 6.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func set_curve(c: Curve) -> void:
		_curve = c
		queue_redraw()

	func get_curve() -> Curve:
		return _curve

	func _draw() -> void:
		var rect: Rect2 = Rect2(Vector2.ZERO, size)
		# 背景
		draw_rect(rect, Color(0.12, 0.12, 0.15, 1.0), true)
		# 网格
		var grid_col: Color = Color(0.25, 0.25, 0.30, 1.0)
		for i in range(11):
			var x: float = i / 10.0 * size.x
			draw_line(Vector2(x, 0), Vector2(x, size.y), grid_col, 1.0)
		for i in range(9):
			var y: float = i / 8.0 * size.y
			draw_line(Vector2(0, y), Vector2(size.x, y), grid_col, 1.0)
		# Y=1 基准线(高亮: 力度 1.0 = 不缩放)
		var base_y: float = size.y * (1.0 - 1.0 / _y_max)
		draw_line(Vector2(0, base_y), Vector2(size.x, base_y), Color(0.9, 0.7, 0.3, 0.5), 1.5)
		# 曲线本体
		if _curve:
			var prev: Vector2 = _to_pixel(0.0, _curve.sample(0.0))
			var samples: int = 80
			for i in range(1, samples + 1):
				var t: float = float(i) / samples
				var p: Vector2 = _to_pixel(t, _curve.sample(t))
				draw_line(prev, p, Color(0.3, 0.95, 1.0, 1.0), 2.0)
				prev = p
			# 控制点
			for i in range(_curve.point_count):
				var pt: Vector2 = _curve.get_point_position(i)
				var px: Vector2 = _to_pixel(pt.x, pt.y)
				var col: Color = Color(1.0, 0.85, 0.25, 1.0)
				if i == _hover_idx:
					col = Color(1.0, 0.4, 0.6, 1.0)
				draw_circle(px, POINT_RADIUS, col)
				draw_arc(px, POINT_RADIUS, 0, TAU, 16, Color(0, 0, 0, 1), 1.5)
		# 边框
		draw_rect(rect, Color(0.5, 0.5, 0.55, 1), false, 1.5)
		# 坐标标注
		var lbl_color := Color(0.85, 0.85, 0.9)
		var f := ThemeDB.fallback_font
		var fs: int = 11
		draw_string(f, Vector2(4, size.y - 4), "0,0", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, lbl_color)
		draw_string(f, Vector2(size.x - 28, size.y - 4), "1,0", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, lbl_color)
		draw_string(f, Vector2(4, 12), "0,%.1f" % _y_max, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, lbl_color)
		draw_string(f, Vector2(4, base_y - 2), "y=1.0", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.95, 0.75, 0.3))

	func _to_pixel(t: float, v: float) -> Vector2:
		var x: float = clampf(t, 0.0, 1.0) * size.x
		var y: float = (1.0 - clampf(v / _y_max, 0.0, 1.0)) * size.y
		return Vector2(x, y)

	func _from_pixel(p: Vector2) -> Vector2:
		var t: float = clampf(p.x / size.x, 0.0, 1.0)
		var v: float = (1.0 - clampf(p.y / size.y, 0.0, 1.0)) * _y_max
		return Vector2(t, v)

	func _find_point_at(p: Vector2) -> int:
		if _curve == null:
			return -1
		for i in range(_curve.point_count):
			var pt: Vector2 = _curve.get_point_position(i)
			var px: Vector2 = _to_pixel(pt.x, pt.y)
			if px.distance_to(p) < POINT_RADIUS + 4.0:
				return i
		return -1

	func _gui_input(event: InputEvent) -> void:
		if _curve == null:
			return
		if event is InputEventMouseButton:
			var mb: InputEventMouseButton = event
			if mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if mb.double_click:
						# 双击空白添加点
						var idx: int = _find_point_at(mb.position)
						if idx == -1:
							var tv: Vector2 = _from_pixel(mb.position)
							_curve.add_point(tv)
							queue_redraw()
					else:
						_drag_idx = _find_point_at(mb.position)
				else:
					_drag_idx = -1
			elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
				var idx2: int = _find_point_at(mb.position)
				if idx2 != -1 and _curve.point_count > 2:
					_curve.remove_point(idx2)
					queue_redraw()
		elif event is InputEventMouseMotion:
			var mm: InputEventMouseMotion = event
			if _drag_idx >= 0 and _drag_idx < _curve.point_count:
				var tv2: Vector2 = _from_pixel(mm.position)
				# 首尾点 X 锁定
				if _drag_idx == 0:
					tv2.x = 0.0
				elif _drag_idx == _curve.point_count - 1:
					tv2.x = 1.0
				_curve.set_point_offset(_drag_idx, tv2.x)
				_curve.set_point_value(_drag_idx, tv2.y)
				queue_redraw()
			else:
				var hi: int = _find_point_at(mm.position)
				if hi != _hover_idx:
					_hover_idx = hi
					queue_redraw()


# ============================================================
#  按钮动作: 重置/保存/加载
# ============================================================
func _on_reset() -> void:
	for prop in _defaults.keys():
		var v = _defaults[prop]
		var kind: String = _rows[prop].get("kind", "car") if _rows.has(prop) else "car"
		_dispatch_apply(kind, prop, float(v))
		if _rows.has(prop):
			_rows[prop].slider.set_value_no_signal(float(v))
			_rows[prop].spin.set_value_no_signal(float(v))
	# 曲线重置回 LINEAR_FULL
	for cprop in CURVE_PROPS.keys():
		var c: Curve = _build_preset_curve("LINEAR_FULL")
		_curves[cprop] = c
		_apply_curve_to_target(cprop, c)


func _on_save() -> void:
	var cfg := ConfigFile.new()
	var fx = _get_drift_fx()
	var cam = _get_camera()
	var cmesh = _get_car_mesh()
	var bfx = _get_boost_fx_first()
	for prop in _rows.keys():
		var row = _rows[prop]
		var kind: String = row.get("kind", "car")
		var src: Object = null
		match kind:
			"fx": src = fx
			"cam": src = cam
			"car_mesh": src = cmesh
			"boost_fx": src = bfx
			_: src = car
		if _has_prop(src, prop):
			cfg.set_value("tune", prop, _read_prop(src, prop))
		# 同时保存范围
		cfg.set_value("range", prop, [row.min, row.max, row.step])
	# 保存曲线: 序列化点列表
	for cprop in _curves.keys():
		var c: Curve = _curves[cprop]
		var pts: Array = []
		for i in range(c.point_count):
			var pt: Vector2 = c.get_point_position(i)
			pts.append([pt.x, pt.y])
		cfg.set_value("curves", cprop, pts)
	var save_path := _stable_cfg_path()
	# 确保稳定目录存在
	DirAccess.make_dir_recursive_absolute(_stable_cfg_dir())
	cfg.save(save_path)
	print("[Tuner] 已保存到 ", save_path)


func _on_load() -> void:
	_load_from_file()


func _load_from_file() -> void:
	var cfg := ConfigFile.new()
	var load_path := _stable_cfg_path()
	var err := cfg.load(load_path)
	if err != OK:
		return
	# 范围(必须先加载范围, 才能用新范围去校验数值合法性)
	if cfg.has_section("range"):
		for prop in cfg.get_section_keys("range"):
			if not _rows.has(prop):
				continue
			var arr = cfg.get_value("range", prop, null)
			if typeof(arr) != TYPE_ARRAY or arr.size() < 3:
				continue
			var row = _rows[prop]
			row.min = float(arr[0]); row.max = float(arr[1]); row.step = float(arr[2])
			row.slider.min_value = row.min; row.slider.max_value = row.max; row.slider.step = row.step
			row.spin.min_value = row.min; row.spin.max_value = row.max; row.spin.step = row.step
	# 数值: 只加载当前 PARAMS 中存在的 prop, 越界值放宽到 clamp 而不是丢弃
	# (高压线: 永远不要丢弃用户保存的值! 哪怕越界也尽量回填, 提示一下就行)
	if cfg.has_section("tune"):
		for prop in cfg.get_section_keys("tune"):
			if not _rows.has(prop):
				continue   # 已废弃的旧参数, 忽略
			var v = cfg.get_value("tune", prop)
			var fv: float = float(v)
			var row = _rows[prop]
			# 越界时自动放宽 row 范围, 把用户调过的值放进去
			if fv < row.min:
				push_warning("[Tuner] %s 加载值 %.3f 低于当前最小 %.3f, 自动放宽下限" % [prop, fv, row.min])
				row.min = fv
				row.slider.min_value = fv; row.spin.min_value = fv
			if fv > row.max:
				push_warning("[Tuner] %s 加载值 %.3f 高于当前最大 %.3f, 自动放宽上限" % [prop, fv, row.max])
				row.max = fv
				row.slider.max_value = fv; row.spin.max_value = fv
			var kind: String = row.get("kind", "car")
			_dispatch_apply(kind, prop, fv)
			row.slider.set_value_no_signal(fv)
			row.spin.set_value_no_signal(fv)
	# 曲线
	if cfg.has_section("curves"):
		for cprop in cfg.get_section_keys("curves"):
			var pts = cfg.get_value("curves", cprop, [])
			if typeof(pts) != TYPE_ARRAY or pts.is_empty():
				continue
			var c := Curve.new()
			c.bake_resolution = 100
			for p in pts:
				if typeof(p) == TYPE_ARRAY and p.size() >= 2:
					c.add_point(Vector2(float(p[0]), float(p[1])))
			_curves[cprop] = c
			_apply_curve_to_target(cprop, c)
	print("[Tuner] 已从 ", load_path, " 加载")
