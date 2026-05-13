"""
生成 3C 功能 + 参数总表 Excel.
输出到 docs/03_FEATURES.xlsx
"""
import sys
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

OUT = Path(__file__).parent.parent / "docs" / "03_FEATURES.xlsx"

# ============================================================
# 数据定义: (页签, 大标题, 小标题, 参数名, 参数中文名, 单位/范围, 默认值, tooltip说明)
# 小标题为空表示直接在大标题下
# ============================================================

FEATURES = [
    # ============ 🚗 基础移动 ============
    ("🚗 基础移动", "极速 & 油门", "", "max_speed", "巡航极速", "m/s 10~200", "70", "无喷射时最高速度"),
    ("🚗 基础移动", "极速 & 油门", "", "top_speed_boosted", "喷射极速", "m/s 10~300", "120", "喷射期间最高速度"),
    ("🚗 基础移动", "极速 & 油门", "", "engine_force_max", "引擎最大推力", "10~300", "80", "引擎峰值推力, 配合曲线"),
    ("🚗 基础移动", "极速 & 油门", "", "brake_force_max", "刹车最大力", "10~300", "120", "刹车峰值力, 配合曲线"),
    ("🚗 基础移动", "极速 & 油门", "", "engine_idle_drag", "松油门引擎拖曳", "0~20", "3", "模拟引擎刹车/滚阻"),
    ("🚗 基础移动", "转向", "", "steering_deg", "前轮转角", "度 5~60", "35", "前轮最大转角=车头转向幅度上限"),
    ("🚗 基础移动", "转向", "", "turn_speed", "车头响应速度", "0.5~8", "3.5", "车头 lerp 到目标方向的速度"),
    ("🚗 基础移动", "转向", "", "turn_speed_high_speed_mult", "高速转向衰减倍率", "0.1~1", "0.55", "高速转向变钝防甩尾"),
    ("🚗 基础移动", "转向", "", "high_speed_threshold", "高速衰减阈值", "m/s 5~80", "20", "超过此速度开始应用高速衰减"),
    ("🚗 基础移动", "倒车", "", "reverse_threshold", "刹车→倒车切换阈值", "0~10", "1.5", "车头方向速度<此值+刹车键→倒车"),
    ("🚗 基础移动", "倒车", "", "reverse_force_mult", "倒车推力倍率", "0~2", "0.5", "倒车推力相对前进的倍率"),
    ("🚗 基础移动", "倒车", "", "reverse_max_speed", "倒车最高速度", "m/s 1~40", "10", "倒车最高速"),
    ("🚗 基础移动", "摩擦 - 正常行驶", "", "friction_long_normal", "前后向摩擦", "0~20", "2", "低速松油门减速感"),
    ("🚗 基础移动", "摩擦 - 正常行驶", "", "friction_lat_normal", "侧向抓地", "0~30", "15", "过弯抗侧滑, 越大越稳"),
    ("🚗 基础移动", "摩擦 - 正常行驶", "", "friction_air_drag", "空气阻力系数", "0~0.5", "0.02", "与速度平方成正比的阻力"),

    # ============ 🎯 漂移系统 ============
    ("🎯 漂移系统", "摩擦 - 漂移状态", "", "friction_long_drift", "漂移前后摩擦", "0~20", "1", "漂移时通常比正常低让车滑更远"),
    ("🎯 漂移系统", "摩擦 - 漂移状态", "", "friction_lat_drift", "漂移侧向抓地", "0~15", "4", "需远小于正常值否则甩不出去"),
    ("🎯 漂移系统", "摩擦 - 漂移状态", "", "drift_extra_decel", "漂移额外能耗", "0~20", "5", "模拟轮胎打滑的整体减速"),
    ("🎯 漂移系统", "摩擦 - 漂移状态", "", "drift_extra_decel_songqian_mult", "松前能耗倍率", "0~3", "0.3", "松前时能耗降低, 车滑更远"),

    ("🎯 漂移系统", "松前 (松油门漂)", "", "songqian_drift_enabled", "松前漂移开关", "0/1", "1", "漂移中松油门=松前; 踩回=松前漂移"),
    ("🎯 漂移系统", "松前 (松油门漂)", "", "songqian_yaw_limit_deg", "车头偏移上限", "度 0~180", "90", "松前车头最多偏离起漂方向的角度"),
    ("🎯 漂移系统", "松前 (松油门漂)", "", "songqian_yaw_speed_deg", "车头偏移速度", "度/秒 10~360", "90", "多快达到偏移上限"),
    ("🎯 漂移系统", "松前 (松油门漂)", "", "songqian_drift_kick_impulse", "踩油门触发冲量", "0~50", "14", "踩回油门触发松前漂移的巨大冲量"),
    ("🎯 漂移系统", "松前 (松油门漂)", "", "songqian_drift_boost_duration", "松前漂移爆发时长", "秒 0.1~2", "0.7", "松前漂移后推力爆发期"),
    ("🎯 漂移系统", "松前 (松油门漂)", "", "songqian_enter_kick_impulse", "进入松前小加速", "0~20", "4", "刚松油门瞬间的一次性小冲量"),
    ("🎯 漂移系统", "松前 (松油门漂)", "", "songqian_steer_mult", "松前转向倍率", "0~1.5", "0.3", "松前期间转向变钝, 防止方向乱甩"),

    ("🎯 漂移系统", "三喷 (松前后退喷)", "", "songqian_back_boost_enabled", "三喷开关", "0/1", "1", "松前下车头偏角够+Q+W触发"),
    ("🎯 漂移系统", "三喷 (松前后退喷)", "", "songqian_back_min_yaw_deg", "触发最小偏角", "度 0~180", "60", "车头偏离起漂方向的最小角度"),
    ("🎯 漂移系统", "三喷 (松前后退喷)", "", "songqian_back_boost_power", "三喷推力", "10~200", "110", "沿车头反方向的持续推力"),
    ("🎯 漂移系统", "三喷 (松前后退喷)", "", "songqian_back_boost_time", "三喷持续", "秒 0.1~2", "0.5", ""),
    ("🎯 漂移系统", "三喷 (松前后退喷)", "", "songqian_back_kick_impulse", "三喷瞬时冲量", "0~30", "10", "触发瞬间的一次性冲量"),

    ("🎯 漂移系统", "打滑 (松油门=滑)", "", "drift_slip_enabled", "打滑总开关", "0/1", "1", "漂移中松前进键=打滑摩擦减少"),
    ("🎯 漂移系统", "打滑 (松油门=滑)", "", "drift_slip_friction_cut", "打滑摩擦削减", "0~1", "1", "完全松油门时摩擦被削减的比例"),
    ("🎯 漂移系统", "打滑 (松油门=滑)", "", "drift_slip_smooth", "打滑过渡速度", "1~20", "8", "打滑强度过渡平滑速度"),
    ("🎯 漂移系统", "打滑 (松油门=滑)", "", "drift_inertia_boost", "惯性感增强", "0~1", "0.4", "漂深时沿惯性方向摩擦被削减"),
    ("🎯 漂移系统", "打滑 (松油门=滑)", "", "drift_centripetal_pull", "向心力拉力", "0~50", "10", "大弧线过弯的'粘'感来源"),

    ("🎯 漂移系统", "触发与限制", "", "drift_min_speed", "最低入漂车速", "0~30", "8", "低于此速度无法触发漂移"),
    ("🎯 漂移系统", "触发与限制", "", "drift_min_angle_to_boost", "小喷资格累积角", "度 0~120", "30", "累计车头转过此角度后退漂可小喷"),
    ("🎯 漂移系统", "触发与限制", "", "drift_max_duration", "漂移最长持续", "秒 0~30", "0", "0=不限时"),
    ("🎯 漂移系统", "触发与限制", "", "drift_break_speed_ratio", "低速断漂阈值倍率", "0~1", "0.6", "速度<(最低×此值)触发低速宽限"),
    ("🎯 漂移系统", "触发与限制", "", "drift_low_speed_grace_time", "低速宽限秒数", "秒 0~2", "0.6", "低速后多少秒内可以挽救"),
    ("🎯 漂移系统", "触发与限制", "", "drift_grace_save_angle", "宽限期挽救所需角度", "度 0~60", "15", "宽限期内再转此角度=挽救成功"),
    ("🎯 漂移系统", "触发与限制", "", "drift_max_speed", "漂移最高速度", "m/s 0~100", "50", "漂移时速度软上限, 0=不限"),
    ("🎯 漂移系统", "触发与限制", "", "drift_speed_brake_strength", "漂移超速刹车强度", "0~60", "20", "配合曲线"),
    ("🎯 漂移系统", "触发与限制", "", "drift_input_grace_window", "Q 输入宽限期", "秒 0~0.5", "0.1", "Q 按下后方向键就位也能入漂"),
    ("🎯 漂移系统", "触发与限制", "", "drift_auto_exit_enabled", "车正自动退漂", "0/1", "1", "车头摆正+无侧滑自动退漂"),
    ("🎯 漂移系统", "触发与限制", "", "drift_auto_exit_lat_speed", "自动退漂侧速阈值", "m/s 0~10", "1", ""),
    ("🎯 漂移系统", "触发与限制", "", "drift_auto_exit_angle_deg", "自动退漂角度阈值", "度 0~30", "4", ""),
    ("🎯 漂移系统", "触发与限制", "", "drift_auto_exit_time", "自动退漂去抖时长", "秒 0~1", "0.15", ""),
    ("🎯 漂移系统", "触发与限制", "", "drift_auto_exit_protect_time", "自动退漂保护期", "秒 0~1.5", "0.3", "刚入漂不启用自动退漂"),

    ("🎯 漂移系统", "动态曲线", "", "drift_engage_duration", "入漂过渡时长", "秒 0~1.5", "0.15", "drift_intensity 0→1 时间"),
    ("🎯 漂移系统", "动态曲线", "", "drift_disengage_duration", "退漂过渡时长", "秒 0~1.5", "0.15", "drift_intensity 1→0 时间"),
    ("🎯 漂移系统", "动态曲线", "", "drift_head_yaw_duration_ref", "车头曲线时间基准", "秒 0.2~6", "1.5", "车头 yaw/侧倾曲线 X 轴基准"),
    ("🎯 漂移系统", "动态曲线", "", "drift_steer_mult", "漂移转向倍率", "1~4", "1.6", "漂移时转向灵敏度"),
    ("🎯 漂移系统", "动态曲线", "", "drift_accel_mult", "漂移油门效率", "0~1.5", "0.7", "漂移时油门实际比例"),
    ("🎯 漂移系统", "动态曲线", "", "drift_exit_boost_duration", "退漂爆发期时长", "秒 0~2", "0.5", "入/退漂瞬间推力爆发期"),
    ("🎯 漂移系统", "动态曲线", "", "drift_exit_boost_mult", "退漂爆发期推力倍率", "1~3", "1.5", ""),
    ("🎯 漂移系统", "动态曲线", "", "post_drift_steer_cooldown", "退漂转向冷却时长", "秒 0~1.5", "0.35", "防止退漂瞬间转向超灵敏甩飞"),
    ("🎯 漂移系统", "动态曲线", "", "post_drift_steer_mult", "退漂转向冷却起始倍率", "0~1", "0.5", ""),

    ("🎯 漂移系统", "反打 (回正动画+减速)", "", "drift_counter_steer_mult", "反打转向缩减倍率", "0~1", "0.35", "反打时角速度缩减"),
    ("🎯 漂移系统", "反打 (回正动画+减速)", "", "drift_counter_lean_mult", "反打侧倾衰减目标", "0~1", "0", "0=反打时车身完全回正"),
    ("🎯 漂移系统", "反打 (回正动画+减速)", "", "drift_counter_lean_smooth", "反打回正过渡速度", "1~20", "4", "侧倾恢复过渡速度"),
    ("🎯 漂移系统", "反打 (回正动画+减速)", "", "drift_counter_decel_enabled", "反打减速开关", "0/1", "1", "反打时物理减速(新增)"),
    ("🎯 漂移系统", "反打 (回正动画+减速)", "", "drift_counter_decel", "反打减速强度", "0~30", "8", "沿水平速度反向减速 F"),
    ("🎯 漂移系统", "反打 (回正动画+减速)", "", "drift_counter_decel_min_steer", "反打减速最小输入", "0~1", "0.25", "防止方向键抖动也减速"),

    ("🎯 漂移系统", "集气 (氮气累积)", "", "charge_nitro_full", "一格氮气=多少集气", "20~300", "100", "越大越难攒"),
    ("🎯 漂移系统", "集气 (氮气累积)", "", "charge_per_lateral_m", "侧滑米数权重", "0~10", "2", ""),
    ("🎯 漂移系统", "集气 (氮气累积)", "", "charge_yaw_rate_weight", "车头角速度权重", "0~10", "1", ""),
    ("🎯 漂移系统", "集气 (氮气累积)", "", "charge_min_per_sec", "兜底集气/秒", "0~60", "15", "直线漂也能攒"),
    ("🎯 漂移系统", "集气 (氮气累积)", "", "crash_charge_penalty", "撞墙保留比例", "0~1", "0.2", "0.2=撞墙损失 80% 已积累"),
    ("🎯 漂移系统", "集气 (氮气累积)", "", "max_nitro_stock", "氮气槽上限", "1~5", "2", "最多囤积几格"),
    ("🎯 漂移系统", "集气 (氮气累积)", "", "instant_nitro_settle", "集气满立即结算氮气", "0/1", "1", "1=立即; 0=漂移结束才结算"),

    # ============ 💨 喷射 ============
    ("💨 喷射", "小喷", "", "mini_boost_power", "小喷推进力", "5~100", "30", "配合曲线"),
    ("💨 喷射", "小喷", "", "mini_boost_time", "小喷持续", "秒 0.1~3", "0.4", ""),
    ("💨 喷射", "小喷", "", "mini_boost_shake", "小喷震屏", "0~2", "0.3", ""),
    ("💨 喷射", "双喷 (小喷接力)", "", "double_boost_power", "双喷推进力", "10~150", "50", ""),
    ("💨 喷射", "双喷 (小喷接力)", "", "double_boost_time", "双喷持续", "秒 0.1~3", "0.7", ""),
    ("💨 喷射", "双喷 (小喷接力)", "", "double_charge_hold_time", "双喷蓄能时长", "秒 0.1~2", "0.4", "按住 Q 多久解锁双喷"),
    ("💨 喷射", "双喷 (小喷接力)", "", "double_charge_window", "双喷蓄满后有效秒数", "0.2~3", "1.2", "蓄满后多久不按 W 会失效"),
    ("💨 喷射", "双喷 (小喷接力)", "", "double_boost_shake", "双喷震屏", "0~2", "0.5", ""),
    ("💨 喷射", "氮气", "", "nitro_power", "氮气推进力", "20~200", "70", ""),
    ("💨 喷射", "氮气", "", "nitro_time", "氮气持续", "秒 0.5~6", "2.5", ""),
    ("💨 喷射", "氮气", "", "nitro_require_throttle", "松手中断氮气", "0/1", "1", "1=QQ飞车手感"),
    ("💨 喷射", "氮气", "", "nitro_boost_shake", "氮气震屏", "0~2", "0.7", ""),
    ("💨 喷射", "叠喷 (连喷接力)", "", "stack_link_window", "连喷接力窗口", "秒 0~1.5", "0.6", ""),
    ("💨 喷射", "叠喷 (连喷接力)", "", "stack_breakthrough_top_mult", "突破极速倍率", "1~2", "1.18", "每次突破极速被提升"),
    ("💨 喷射", "叠喷 (连喷接力)", "", "stack_max_breakthrough", "最大突破次数", "0~5", "2", "CWW/WCW 最多 2 次突破"),
    ("💨 喷射", "漂移氮气 (过弯增强)", "", "drift_nitro_max_speed_mult", "漂移氮气极速倍率", "1~3", "1.5", ""),
    ("💨 喷射", "漂移氮气 (过弯增强)", "", "drift_nitro_steer_mult", "漂移氮气转向倍率", "1~3", "1.3", ""),
    ("💨 喷射", "漂移氮气 (过弯增强)", "", "drift_nitro_lat_grip_mult", "漂移氮气侧向抓地倍率", "0.5~3", "1.5", ""),
    ("💨 喷射", "漂移氮气 (过弯增强)", "", "drift_nitro_body_tilt_mult", "漂移氮气侧倾倍率", "0.5~2.5", "1.3", "视觉效果"),

    # ============ 🧱 撞墙物理 ============
    ("🧱 撞墙物理", "墙判定 + 总开关", "", "slope_as_wall_enabled", "撞墙物理总开关", "0/1", "1", ""),
    ("🧱 撞墙物理", "墙判定 + 总开关", "", "slope_wall_angle_deg", "墙判定严格阈值", "度 20~85", "50", "法线与竖直>此值=墙"),
    ("🧱 撞墙物理", "墙判定 + 总开关", "", "slope_wall_push_back", "撞墙反推速度", "0~20", "4", "沿法线额外推开防卡墙"),
    ("🧱 撞墙物理", "弹墙推力 (尾/侧撞奖励)", "", "wall_bounce_boost_enabled", "弹墙推力开关", "0/1", "1", ""),
    ("🧱 撞墙物理", "弹墙推力 (尾/侧撞奖励)", "", "wall_bounce_rear_threshold", "尾撞判定阈值", "0~1", "0.4", ""),
    ("🧱 撞墙物理", "弹墙推力 (尾/侧撞奖励)", "", "wall_bounce_side_threshold", "侧撞判定阈值", "0~1", "0.6", ""),
    ("🧱 撞墙物理", "弹墙推力 (尾/侧撞奖励)", "", "wall_bounce_min_into_speed", "触发最小撞墙速度", "0~20", "3", ""),
    ("🧱 撞墙物理", "弹墙推力 (尾/侧撞奖励)", "", "wall_bounce_forward_speed", "弹墙推力大小", "m/s 0~30", "6", "沿车头方向叠加"),
    ("🧱 撞墙物理", "弹墙推力 (尾/侧撞奖励)", "", "wall_drift_lockout_time", "撞墙断漂入漂CD", "秒 0~2", "0.5", ""),
    ("🧱 撞墙物理", "弹墙推力 (尾/侧撞奖励)", "", "wall_crash_shake", "撞墙震屏", "0~2", "0.5", ""),
    ("🧱 撞墙物理", "硬碰硬反弹 V3", "", "wall_reflect_tangent_keep_max", "切向保留(擦墙)", "0~1", "0.9", "撞击力小时切向保留高"),
    ("🧱 撞墙物理", "硬碰硬反弹 V3", "", "wall_reflect_tangent_keep_min", "切向保留(正撞)", "0~1", "0.3", "撞击力大时切向保留低"),
    ("🧱 撞墙物理", "硬碰硬反弹 V3", "", "wall_reflect_tangent_lerp_speed", "切向插值参考速度", "1~50", "18", "切向减速的参考 v_normal"),
    ("🧱 撞墙物理", "硬碰硬反弹 V3", "", "wall_reflect_normal_factor", "反弹法向系数 e", "0~1", "0.65", "恢复系数"),
    ("🧱 撞墙物理", "硬碰硬反弹 V3", "", "wall_hit_kickback", "Kickback 法线推开速度", "m/s 0~30", "8", "二次方缩放, 高速撞砰一下飞"),
    ("🧱 撞墙物理", "硬碰硬反弹 V3", "", "wall_straight_tangent_kill", "正撞切向擦除", "0~1", "0.7", "1=正撞时切向完全清零"),
    ("🧱 撞墙物理", "硬碰硬反弹 V3", "", "wall_grazing_angle_deg", "擦墙临界角", "度 0~90", "20", "<此角算擦墙切向额外+15%"),
    ("🧱 撞墙物理", "硬碰硬反弹 V3", "", "glass_shatter_min_speed", "玻璃渣触发最小速度", "m/s 0~20", "3", ""),
    ("🧱 撞墙物理", "弹墙掉头 (V4 新增)", "", "wall_normal_y_threshold", "墙判定宽松阈值", "0~1", "0.7", "n.y<此值强制视为墙"),
    ("🧱 撞墙物理", "弹墙掉头 (V4 新增)", "", "wall_turnaround_enabled", "掉头开关", "0/1", "1", "撞墙时车身 yaw 跟着反弹方向转"),
    ("🧱 撞墙物理", "弹墙掉头 (V4 新增)", "", "wall_turnaround_min_into", "掉头最小触发速度", "m/s 0~30", "7", ""),
    ("🧱 撞墙物理", "弹墙掉头 (V4 新增)", "", "wall_turnaround_duration", "掉头持续时长", "秒 0~1.5", "0.3", "0=瞬间硬切; 0.3=QQ飞车风"),
    ("🧱 撞墙物理", "弹墙掉头 (V4 新增)", "", "wall_turnaround_max_deg", "掉头最大角度", "度 0~180", "150", ""),
    ("🧱 撞墙物理", "弹墙掉头 (V4 新增)", "", "wall_turnaround_min_deg", "掉头最小角度", "度 0~90", "20", "<此角不触发, 避免擦墙抖头"),
    ("🧱 撞墙物理", "防吸住 (V4 关键)", "", "wall_hit_cooldown", "撞墙冷却", "秒 0~1", "0.15", "反弹后此窗口内不触发新反弹"),
    ("🧱 撞墙物理", "防吸住 (V4 关键)", "", "wall_unstick_offset", "撞墙硬位移", "米 0~0.5", "0.08", "直接修改 transform 脱离接触面"),
    ("🧱 撞墙物理", "防吸住 (V4 关键)", "", "wall_hit_speed_cap_mult", "锁速倍率", "0.5~2", "1.5", ""),
    ("🧱 撞墙物理", "防吸住 (V4 关键)", "", "wall_hit_lock_duration", "锁速时长", "秒 0~1.5", "0.3", ""),
    ("🧱 撞墙物理", "防吸住 (V4 关键)", "", "wall_hit_cancel_boost", "撞墙取消 boost", "0/1", "0", "1=撞墙打断喷射; 默认 0"),

    # ============ ⛰️ 地面物理 ============
    ("⛰️ 地面物理", "防弹 + 贴附", "", "ground_stick_enabled", "总开关", "0/1", "1", ""),
    ("⛰️ 地面物理", "防弹 + 贴附", "", "plain_slope_threshold_deg", "平地/坡面切换", "度 0~30", "8", "<此坡度=平地走强防弹"),
    ("⛰️ 地面物理", "防弹 + 贴附", "平地防弹", "plain_vy_zero_threshold", "向上速度归零阈值", "0~20", "5", "Y>0 且 <此值直接归零"),
    ("⛰️ 地面物理", "防弹 + 贴附", "平地防弹", "plain_downforce", "持续下压力", "N/kg 0~40", "8", ""),
    ("⛰️ 地面物理", "防弹 + 贴附", "平地防弹", "plain_downforce_vy_gate", "下压力触发阈值", "0~5", "0.3", "只在 Y>此值时压"),
    ("⛰️ 地面物理", "防弹 + 贴附", "平地防弹", "plain_vy_down_clamp", "下坠速度上限", "0~50", "0", "0=不限"),
    ("⛰️ 地面物理", "防弹 + 贴附", "坡面贴附", "slope_stick_force", "坡面贴附力", "0~40", "8", "沿法线反向防飞车"),
    ("⛰️ 地面物理", "防弹 + 贴附", "坡面贴附", "slope_stick_max_vy", "坡面贴附 Y 速度上限", "0~10", "2.5", "保护真跳跃不被吸回"),
    ("⛰️ 地面物理", "防弹 + 贴附", "坡面贴附", "slope_stick_max_deg", "坡面贴附最大坡度", "度 5~90", "60", "超此坡度不贴附"),

    ("⛰️ 坡道", "推力/重力补偿", "", "slope_align_thrust", "推力沿坡面切向", "0/1", "1", "上坡推力沿坡面不再水平推"),
    ("⛰️ 坡道", "推力/重力补偿", "", "slope_gravity_compensation", "上坡重力补偿", "0~1.5", "0.85", "抵消重力沿坡面分量"),
    ("⛰️ 坡道", "推力/重力补偿", "", "slope_compensation_max_deg", "补偿最大坡度", "度 0~90", "45", ""),
    ("⛰️ 坡道", "上坡爬升助力", "", "uphill_assist_enabled", "助力开关", "0/1", "1", ""),
    ("⛰️ 坡道", "上坡爬升助力", "", "uphill_assist_force", "助力基础强度", "0~60", "6", ""),
    ("⛰️ 坡道", "上坡爬升助力", "", "uphill_assist_min_deg", "触发最小坡度", "度 0~30", "4", ""),
    ("⛰️ 坡道", "上坡爬升助力", "", "uphill_assist_max_deg", "助力最大坡度", "度 5~90", "30", "曲线 X=1 对应的坡度"),
    ("⛰️ 坡道", "上坡爬升助力", "", "uphill_assist_require_throttle", "需要踩油门", "0/1", "1", ""),
    ("⛰️ 坡道", "上坡爬升助力", "", "uphill_assist_boost_mult", "喷射期间助力倍率", "0.5~3", "1.2", ""),

    # ============ 🛫 空喷/落地喷 ============
    ("🛫 空喷/落地喷", "空喷 (空中按 W)", "", "air_boost_enabled", "空喷开关", "0/1", "1", "空中按 W 立即触发 (V3 离地瞬间)"),
    ("🛫 空喷/落地喷", "空喷 (空中按 W)", "", "air_boost_min_air_time", "空喷最小腾空", "秒 0~1.5", "0.18", "防颠簸误触发"),
    ("🛫 空喷/落地喷", "空喷 (空中按 W)", "", "air_boost_power", "空喷推进力", "5~150", "50", ""),
    ("🛫 空喷/落地喷", "空喷 (空中按 W)", "", "air_boost_time", "空喷持续", "秒 0.1~3", "0.8", ""),
    ("🛫 空喷/落地喷", "空喷 (空中按 W)", "", "air_boost_downforce", "空喷滞空感下压力", "m/s² 0~30", "5", "给空喷一种悬浮被推进的手感"),
    ("🛫 空喷/落地喷", "空喷 (空中按 W)", "", "air_boost_shake", "空喷震屏强度", "0~2", "0.5", ""),
    ("🛫 空喷/落地喷", "空喷 (空中按 W)", "", "air_landing_speed_recover", "落地水平速度补偿", "0~1", "0.85", "飞行中空气阻力损耗, 落地拉回"),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_boost_enabled", "落地喷开关", "0/1", "1", ""),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_boost_min_air_time", "落地喷最小腾空", "秒 0~3", "0.8", "比空喷门槛高"),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_boost_power", "落地喷推进力", "5~120", "40", ""),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_boost_time", "落地喷持续", "秒 0.1~2", "0.6", ""),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_boost_press_window", "落地喷按键窗口", "秒 0.1~2", "0.5", "稳定落地后按 W 的时间窗"),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_stable_time", "落地稳定判定", "秒 0~0.5", "0.08", "连续接地此秒数才算真落地"),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_stable_max_vy", "落地稳定 Y 速度上限", "0~20", "4", ""),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_boost_shake", "落地喷震屏", "0~2", "0.4", ""),
    ("🛫 空喷/落地喷", "落地喷", "", "landing_impact_absorb", "落地冲击吸收", "0~1", "0.85", "0=保留下落动能造成弹跳; 1=完全吸收"),

    # ============ ✨ 视觉 ============
    ("✨ 视觉", "车身姿态 (非漂移)", "", "body_tilt", "过弯侧倾敏感度", "5~120", "30", "越大越稳"),
    ("✨ 视觉", "车身姿态 (非漂移)", "", "body_tilt_max_deg", "过弯最大侧倾角", "度 0~45", "15", "防高速侧翻"),
    ("✨ 视觉", "车身姿态 (非漂移)", "", "head_yaw_deg", "车头左右拧头幅度", "度 0~20", "8", "非漂移时的车头摆动"),
    ("✨ 视觉", "漂移姿态", "", "drift_body_tilt", "漂移车身侧倾", "度 0~60", "25", "配合曲线"),
    ("✨ 视觉", "漂移姿态", "", "drift_yaw_offset_tuck", "甩尾 yaw 偏移", "度 0~60", "25", "甩尾型漂移车头偏转"),
    ("✨ 视觉", "漂移姿态", "", "drift_yaw_offset_side", "侧身 yaw 偏移", "度 0~80", "50", "侧身型漂移(反打入漂)更夸张"),
    ("✨ 视觉", "漂移姿态", "", "side_drift_threshold", "侧身触发侧速阈值", "0~8", "3", "横向速度>此值=侧身漂"),

    # ============ 🎥 镜头 ============
    ("🎥 镜头", "跟随", "", "lerp_speed", "镜头跟随速度", "0.5~30", "8", "越大越紧贴车辆"),
    ("🎥 镜头", "跟随", "", "max_follow_lag", "最大滞后距离", "0~30", "12", "超出立即拉回; 0=不限"),
    ("🎥 镜头", "跟随", "", "base_fov_override", "基础 FOV 覆盖值", "30~120", "75", ""),
    ("🎥 镜头", "跟随", "", "use_base_fov_override", "启用 FOV 覆盖", "0/1", "1", ""),
    ("🎥 镜头", "跟随", "偏移", "offset.x", "基础偏移 X", "-20~20", "0", ""),
    ("🎥 镜头", "跟随", "偏移", "offset.y", "基础偏移 Y", "-10~20", "3", ""),
    ("🎥 镜头", "跟随", "偏移", "offset.z", "基础偏移 Z", "-10~20", "7", "跟随相机通常用正值(车后)"),
    ("🎥 镜头", "喷射拉远", "氮气", "nitro_zoom_offset.x/y/z", "氮气拉远向量", "-10~10", "(0, 0.5, 2)", ""),
    ("🎥 镜头", "喷射拉远", "氮气", "nitro_zoom_duration", "氮气拉远持续", "秒 0~6", "1.5", ""),
    ("🎥 镜头", "喷射拉远", "氮气", "nitro_fov_boost", "氮气 FOV 增量", "度 0~30", "8", "配合曲线"),
    ("🎥 镜头", "喷射拉远", "双喷", "double_zoom_scale", "双喷拉远倍率", "0~2", "0.6", "氮气偏移 × 此值"),
    ("🎥 镜头", "喷射拉远", "双喷", "double_zoom_duration", "双喷拉远持续", "秒 0~3", "0.8", ""),
    ("🎥 镜头", "喷射拉远", "双喷", "double_fov_boost", "双喷 FOV 增量", "度 0~20", "4", ""),
    ("🎥 镜头", "喷射拉远", "小喷", "mini_zoom_scale", "小喷拉远倍率", "0~1.5", "0", "0=小喷不拉远"),
    ("🎥 镜头", "喷射拉远", "小喷", "mini_zoom_duration", "小喷拉远持续", "秒 0~2", "0.3", ""),
    ("🎥 镜头", "喷射拉远", "小喷", "mini_fov_boost", "小喷 FOV 增量", "度 0~15", "2", ""),
    ("🎥 镜头", "喷射拉远", "", "zoom_lerp_speed", "拉远/FOV平滑速度", "0.5~15", "5", ""),
    ("🎥 镜头", "Y 稳定 + 前瞻", "", "y_stabilizer_enabled", "Y 稳定器开关", "0/1", "1", "过滤坑洼路面微抖"),
    ("🎥 镜头", "Y 稳定 + 前瞻", "", "y_deadzone", "Y 死区", "米 0~1", "0.3", "死区内极慢追(不抖)"),
    ("🎥 镜头", "Y 稳定 + 前瞻", "", "y_follow_speed_mult", "Y 跟随速度倍率", "0~2", "0.2", ""),
    ("🎥 镜头", "Y 稳定 + 前瞻", "", "y_force_follow_vy", "Y 强制跟随速度阈值", "0~20", "3", "起跳/落地立即跟随"),
    ("🎥 镜头", "Y 稳定 + 前瞻", "", "lookahead_distance", "焦点前瞻距离", "米 0~15", "3", "焦点沿车头方向偏移"),
    ("🎥 镜头", "Y 稳定 + 前瞻", "", "lookahead_height", "焦点高度偏移", "米 -3~5", "0.5", ""),
    ("🎥 镜头", "震屏", "", "shake_y_factor", "震动 Y 衰减系数", "0~2", "0.6", ""),
    ("🎥 镜头", "震屏", "", "shake_z_factor", "震动 Z 衰减系数", "0~2", "0.5", ""),

    # ============ 🎨 玉麒麟外观 ============
    ("🎨 玉麒麟外观", "尺寸/朝向", "", "fbx_scale", "FBX 整体缩放", "0.001~5", "0.025", "FBX 原始 3×5×3m, 0.025=7.5×12×7.5cm"),
    ("🎨 玉麒麟外观", "尺寸/朝向", "", "fbx_rot_y_deg", "Y 轴旋转", "度 -180~180", "180", "QQ飞车 FBX 通常需 180°"),
    ("🎨 玉麒麟外观", "尺寸/朝向", "", "fbx_offset_y", "Y 偏移", "米 -3~3", "0", ""),
    ("🎨 玉麒麟外观", "车漆材质", "", "clearcoat_strength", "清漆强度", "0~1", "0.5", "0=磨砂 0.5=一般 1=湿漆"),
    ("🎨 玉麒麟外观", "车漆材质", "", "clearcoat_roughness", "清漆粗糙度", "0~1", "0.1", "0=镜面 0.3=哑光"),
    ("🎨 玉麒麟外观", "车漆材质", "", "normal_scale", "法线贴图强度", "0~3", "1", ""),
    ("🎨 玉麒麟外观", "车漆材质", "", "subsurf_strength", "次表面散射强度", "0~1", "0", "车漆的透感, 默认关"),

    # ============ 🔥 喷射特效强度 (BoostFX) ============
    ("🔥 喷射特效", "形状 - 尺寸", "", "flame_target_length", "焰柱目标长度", "米 0.5~10", "2.5", "玉麒麟车身 5.3m, 推荐半车身"),
    ("🔥 喷射特效", "形状 - 尺寸", "", "flame_width_mult", "焰柱宽度系数", "0.1~3", "1", ""),
    ("🔥 喷射特效", "强度", "", "fx_global_amount_mult", "全局强度", "0.1~3", "1", ""),
    ("🔥 喷射特效", "强度", "氮气基础", "nitro_amount_base", "氮气基础粒子数", "10~400", "100", "0 突破时"),
    ("🔥 喷射特效", "强度", "突破倍率", "nitro_amount_mult_0/1/2", "氮气量 0/1/2 突破倍率", "0.5~3", "1/1.5/2", "0=默认 1=金 2=红"),
    ("🔥 喷射特效", "强度", "突破倍率", "nitro_scale_mult_0/1/2", "氮气尺寸 0/1/2 突破倍率", "0.3~3", "1/1.3/1.6", ""),
    ("🔥 喷射特效", "强度", "突破倍率", "nitro_light_energy_mult_0/1/2", "氮气光强 0/1/2 突破倍率", "0~4", "1/1.5/2.5", ""),
    ("🔥 喷射特效", "强度", "突破倍率", "nitro_velocity_mult_0/1/2", "氮气速度 0/1/2 突破倍率", "0.3~3", "1/1.2/1.5", ""),
    ("🔥 喷射特效", "星星散粒", "", "stars_enabled", "星星开关", "0/1", "1", ""),
    ("🔥 喷射特效", "星星散粒", "", "stars_amount_mult", "星星数量倍率", "0~3", "1", ""),
    ("🔥 喷射特效", "星星散粒", "", "stars_scale_mult", "星星大小倍率", "0.3~3", "1", ""),
    ("🔥 喷射特效", "星星散粒", "", "stars_gravity_y", "星星重力 Y", "-5~5", "-0.5", ""),

    # ============ 🛞 漂移特效 (DriftFX) ============
    ("🛞 漂移特效", "胎印", "", "permanent_marks", "胎印永久", "0/1", "0", "1=永不消失 (会卡)"),
    ("🛞 漂移特效", "胎印", "", "tire_mark_only_rear", "只有后轮留胎印", "0/1", "1", ""),
    ("🛞 漂移特效", "胎印", "", "tire_mark_lifetime", "胎印淡出时长", "秒 1~30", "5", ""),
    ("🛞 漂移特效", "胎印", "", "tire_mark_interval", "胎印放置间隔", "秒 0.01~0.2", "0.03", ""),
    ("🛞 漂移特效", "发光", "", "glow_energy", "轮胎发光强度", "0~20", "4", ""),
]


# ============================================================
# 工具函数
# ============================================================

def _header_style():
    return {
        "font": Font(name="Microsoft YaHei", size=11, bold=True, color="FFFFFF"),
        "fill": PatternFill("solid", start_color="2F5496"),
        "align": Alignment(horizontal="center", vertical="center", wrap_text=True),
    }


def _page_style():
    return {
        "font": Font(name="Microsoft YaHei", size=12, bold=True, color="FFFFFF"),
        "fill": PatternFill("solid", start_color="C00000"),
        "align": Alignment(horizontal="left", vertical="center"),
    }


def _group_style():
    return {
        "font": Font(name="Microsoft YaHei", size=11, bold=True, color="000000"),
        "fill": PatternFill("solid", start_color="FFE699"),
        "align": Alignment(horizontal="left", vertical="center"),
    }


def _sub_style():
    return {
        "font": Font(name="Microsoft YaHei", size=10, italic=True, color="2F5496"),
        "fill": PatternFill("solid", start_color="DDEBF7"),
        "align": Alignment(horizontal="left", vertical="center", indent=1),
    }


def _normal_font():
    return Font(name="Microsoft YaHei", size=10)


def _border():
    thin = Side(border_style="thin", color="BFBFBF")
    return Border(left=thin, right=thin, top=thin, bottom=thin)


def build_sheet_features(wb):
    ws = wb.active
    ws.title = "3C 功能参数总表"

    # 标题行
    headers = ["页签", "大标题", "小标题", "参数名", "中文名", "单位/范围", "默认值", "说明"]
    hs = _header_style()
    for col_idx, h in enumerate(headers, 1):
        cell = ws.cell(row=1, column=col_idx, value=h)
        cell.font = hs["font"]
        cell.fill = hs["fill"]
        cell.alignment = hs["align"]
        cell.border = _border()

    ws.row_dimensions[1].height = 28

    # 数据行: 按页签/大标题/小标题合并单元格
    row_idx = 2
    last_page = None
    last_group = None
    last_sub = None

    # 为合并先收集每块的起止行
    page_ranges = {}  # page -> (start, end)
    group_ranges = {}  # (page, group) -> (start, end)
    sub_ranges = {}  # (page, group, sub) -> (start, end)

    for i, (page, group, sub, prop, label, unit, default, desc) in enumerate(FEATURES):
        ws.cell(row=row_idx, column=1, value=page).font = _normal_font()
        ws.cell(row=row_idx, column=2, value=group).font = _normal_font()
        ws.cell(row=row_idx, column=3, value=sub).font = _normal_font()
        ws.cell(row=row_idx, column=4, value=prop).font = Font(name="Consolas", size=10)
        ws.cell(row=row_idx, column=5, value=label).font = _normal_font()
        ws.cell(row=row_idx, column=6, value=unit).font = Font(name="Consolas", size=10, color="606060")
        ws.cell(row=row_idx, column=7, value=default).font = Font(name="Consolas", size=10, color="0070C0", bold=True)
        ws.cell(row=row_idx, column=8, value=desc).font = _normal_font()
        for c in range(1, 9):
            ws.cell(row=row_idx, column=c).border = _border()
            ws.cell(row=row_idx, column=c).alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)

        if page != last_page:
            # 为之前的 page 染色
            if last_page and last_page in page_ranges:
                ps = page_ranges[last_page]
                page_ranges[last_page] = (ps[0], row_idx - 1)
            page_ranges[page] = (row_idx, row_idx)
            last_page = page
            last_group = None
            last_sub = None
        else:
            page_ranges[page] = (page_ranges[page][0], row_idx)

        gkey = (page, group)
        if (page, group) != (last_page, last_group):
            if last_page and last_group is not None and (last_page, last_group) in group_ranges:
                gs = group_ranges[(last_page, last_group)]
                group_ranges[(last_page, last_group)] = (gs[0], row_idx - 1)
            group_ranges[gkey] = (row_idx, row_idx)
            last_group = group
            last_sub = None
        else:
            group_ranges[gkey] = (group_ranges[gkey][0], row_idx)

        if sub:
            skey = (page, group, sub)
            if (page, group, sub) != (last_page, last_group, last_sub):
                sub_ranges[skey] = (row_idx, row_idx)
                last_sub = sub
            else:
                sub_ranges[skey] = (sub_ranges[skey][0], row_idx)

        row_idx += 1

    # 合并单元格 + 染色
    ps = _page_style()
    gs = _group_style()
    sbs = _sub_style()
    for page, (rs, re) in page_ranges.items():
        if rs != re:
            ws.merge_cells(start_row=rs, start_column=1, end_row=re, end_column=1)
        c = ws.cell(row=rs, column=1)
        c.font = ps["font"]
        c.fill = ps["fill"]
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)

    for (page, group), (rs, re) in group_ranges.items():
        if rs != re:
            ws.merge_cells(start_row=rs, start_column=2, end_row=re, end_column=2)
        c = ws.cell(row=rs, column=2)
        c.font = gs["font"]
        c.fill = gs["fill"]
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)

    for (page, group, sub), (rs, re) in sub_ranges.items():
        if rs != re:
            ws.merge_cells(start_row=rs, start_column=3, end_row=re, end_column=3)
        c = ws.cell(row=rs, column=3)
        c.font = sbs["font"]
        c.fill = sbs["fill"]
        c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)

    # 列宽
    widths = [14, 18, 14, 32, 18, 18, 10, 50]
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(i)].width = w

    # 冻结首行
    ws.freeze_panes = "A2"


def build_sheet_features_summary(wb):
    ws = wb.create_sheet("模块总览")
    modules = [
        ("🚗 基础移动", "car.gd", "引擎/刹车/转向/倒车/摩擦"),
        ("🎯 漂移系统", "car.gd", "入漂/退漂/松前/三喷/反打/集气/曲线"),
        ("💨 喷射", "car.gd + BoostFX.gd", "小喷/双喷/氮气/叠喷CWW/WCW/漂移氮气"),
        ("🧱 撞墙物理", "car.gd + TrackWallTagger.gd", "硬碰硬反弹 + 弹墙掉头 + 防吸住"),
        ("⛰️ 地面物理", "car.gd", "防弹+贴附/平地/坡面"),
        ("⛰️ 坡道", "car.gd", "推力切向投影/重力补偿/上坡助力"),
        ("🛫 空喷/落地喷", "car.gd", "离地瞬间空喷 + 落地按键喷"),
        ("✨ 视觉", "car.gd + HUD.gd", "车身姿态/漂移 yaw+侧倾"),
        ("🎥 镜头", "Camera3D.gd", "跟随/Y稳定/前瞻/喷射拉远/震屏"),
        ("🎨 玉麒麟外观", "YuqilinTuning.gd + YuqilinPaint.gd", "FBX 缩放/旋转/PBR 材质"),
        ("🔥 喷射特效", "BoostFX.gd", "焰柱/氮气/星星散粒"),
        ("🛞 漂移特效", "DriftFX.gd", "胎印/轮胎发光/火焰附着"),
    ]
    hs = _header_style()
    headers = ["模块", "主代码", "功能摘要"]
    for i, h in enumerate(headers, 1):
        c = ws.cell(row=1, column=i, value=h)
        c.font = hs["font"]; c.fill = hs["fill"]; c.alignment = hs["align"]; c.border = _border()
    ws.row_dimensions[1].height = 28

    for r, (mod, code, summary) in enumerate(modules, 2):
        ws.cell(row=r, column=1, value=mod).font = Font(name="Microsoft YaHei", size=11, bold=True)
        ws.cell(row=r, column=2, value=code).font = Font(name="Consolas", size=10, color="2F5496")
        ws.cell(row=r, column=3, value=summary).font = Font(name="Microsoft YaHei", size=10)
        for c in range(1, 4):
            ws.cell(row=r, column=c).border = _border()
            ws.cell(row=r, column=c).alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)
        ws.row_dimensions[r].height = 22

    ws.column_dimensions["A"].width = 18
    ws.column_dimensions["B"].width = 40
    ws.column_dimensions["C"].width = 50


def build_sheet_key_bindings(wb):
    ws = wb.create_sheet("按键说明")
    hs = _header_style()
    for i, h in enumerate(["按键", "功能"], 1):
        c = ws.cell(row=1, column=i, value=h)
        c.font = hs["font"]; c.fill = hs["fill"]; c.alignment = hs["align"]; c.border = _border()
    ws.row_dimensions[1].height = 28
    keys = [
        ("W / ↑", "油门 (前进)"),
        ("S / ↓", "刹车 / 倒车"),
        ("A / ←", "左转向 / 漂移左入弯"),
        ("D / →", "右转向 / 漂移右入弯"),
        ("Q", "漂移触发 / 退漂 / 松前漂移(松前下踩回油门自动触发) / 三喷(松前下+W)"),
        ("W (已漂移中)", "蓄双喷 / 接力喷射"),
        ("E", "氮气 (需要先攒满集气)"),
        ("TAB", "显示/隐藏 Tuner 调参面板"),
        ("F3", "切车 (玉麒麟 ↔ SUV)"),
    ]
    for r, (k, f) in enumerate(keys, 2):
        ws.cell(row=r, column=1, value=k).font = Font(name="Consolas", size=11, bold=True)
        ws.cell(row=r, column=2, value=f).font = Font(name="Microsoft YaHei", size=10)
        for c in range(1, 3):
            ws.cell(row=r, column=c).border = _border()
            ws.cell(row=r, column=c).alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)
    ws.column_dimensions["A"].width = 25
    ws.column_dimensions["B"].width = 80


def build_sheet_changelog(wb):
    ws = wb.create_sheet("里程碑")
    hs = _header_style()
    for i, h in enumerate(["日期", "里程碑"], 1):
        c = ws.cell(row=1, column=i, value=h)
        c.font = hs["font"]; c.fill = hs["fill"]; c.alignment = hs["align"]; c.border = _border()
    ws.row_dimensions[1].height = 28
    events = [
        ("2026-05-12", "🎉 基础 3C 第一版定型. 项目改名'简单飞车试验场'. Tuner 三级分类 + 隐藏废弃参数. 文档体系建立."),
        ("2026-05-12 前", "撞墙物理 V4 (防吸住 + 弹墙掉头). TrackWallTagger 墙识别."),
        ("2026-05-12 前", "撞墙物理 V3 (硬碰硬反弹 + kickback). 反打减速 + 两段式回正."),
        ("2026-05-12 前", "松前 + 三喷系统完善. 松前粘性锁定."),
        ("2026-05-12 前", "空喷改为离地瞬间触发 + 滞空感下压力. 落地瞬秒(不悬浮/不弹跳)."),
        ("2026-05-12 前", "玉麒麟车模 + PBR 材质智能映射 (按 material instance ID)."),
        ("2026-05-12 前", "镜头 Y 稳定改为极慢追 + 前瞻焦点(避免俯视)."),
        ("2026-05-12 前", "倒车方向反转修复. 反打车身回正动画."),
        ("更早", "叠喷 CWW/WCW 突破极速. 漂移氮气过弯增强. Tuner 曲线编辑器."),
    ]
    for r, (d, e) in enumerate(events, 2):
        ws.cell(row=r, column=1, value=d).font = Font(name="Consolas", size=10, bold=True)
        ws.cell(row=r, column=2, value=e).font = Font(name="Microsoft YaHei", size=10)
        for c in range(1, 3):
            ws.cell(row=r, column=c).border = _border()
            ws.cell(row=r, column=c).alignment = Alignment(horizontal="left", vertical="center", wrap_text=True)
        ws.row_dimensions[r].height = 32
    ws.column_dimensions["A"].width = 16
    ws.column_dimensions["B"].width = 100


def main():
    wb = Workbook()
    build_sheet_features(wb)
    build_sheet_features_summary(wb)
    build_sheet_key_bindings(wb)
    build_sheet_changelog(wb)
    OUT.parent.mkdir(exist_ok=True)
    wb.save(str(OUT))
    print(f"[OK] 已生成 {OUT} (共 {len(FEATURES)} 个参数)")


if __name__ == "__main__":
    main()
