extends Node3D
class_name GrappleHook
## ============================================================
##  钩索系统 (Apex 探路者风格)
##
##  状态机:
##    IDLE      → 空闲, 玩家按空格则尝试找锚点
##    SHOOTING  → 绳子从车飞向锚点 (视觉过渡, 短暂)
##    ATTACHED  → 钩中锚点, 每物理帧给车施加拉力
##    RELEASING → 释放瞬间 (给一次冲量 + 切到 IDLE)
##
##  力学模型 (核心数学):
##    每帧拉力 F = pull_force_max
##              × force_time_curve.sample(progress)         # 时间曲线: 启动→峰值→收尾
##              × speed_response_curve.sample(v / speed_ref) # 速度曲线: 慢速更猛, 高速少给(避免飞出)
##              × distance_factor                            # 越远拉得越用力, 接近时 ramp down
##    拉力方向 = (anchor_pos - car_pos).normalized() + 上抬偏置 (pull_upward_bias)
##    可选弧线: arc_curve 控制"额外向上分量"的曲线, 让被拉时有抛物感而不是直线
##
##  瞄准辅助:
##    - 玩家按空格的瞬间, 在 max_distance 内 + 在车前方锥形(aim_max_screen_dot)内
##      的所有 GrappleAnchor 中, 选择"角度最接近车头/速度方向"的最佳锚点
##    - aim_priority_speed_weight = 0 → 完全按"距离 + 角度"
##                                = 高 → 偏好沿速度方向的锚点
##
##  与 car.gd 的解耦:
##    - 通过 @export car_path 拿到 RigidBody3D
##    - 拉力用 car.apply_central_force(...), 释放冲量用 car.apply_central_impulse(...)
##    - 钩索期间向 car 设置 _grapple_active = true, car.gd 可读这个状态做摩擦/引擎抑制
##    - 信号 grapple_state_changed(state, anchor_pos) 给 HUD/Camera
##
##  所有调参全部走 @export, Tuner 用 kind="grapple" 分支统一应用
## ============================================================

# ---------------- 状态枚举 ----------------
enum State { IDLE, SHOOTING, ATTACHED, RELEASING }
var state: int = State.IDLE

# ---------------- 节点引用 ----------------
@export var car_path: NodePath
var car: RigidBody3D = null
# 绳子视觉: 改用 CylinderMesh (见 _build_rope_mesh) — 旧的 ImmediateMesh + LINE_STRIP 已废弃
# 因为 GPU 强制线宽 1px, rope_thickness 参数完全没效果, 用户看到的绳子永远像头发丝
var _rope_mesh_inst: MeshInstance3D = null
var _rope_mat: StandardMaterial3D = null
# ATTACHED 状态绳子贴合调试日志 throttle (避免每帧刷屏, 进入 ATTACHED 时打一次, 退出时重置)
var _logged_attached_rope: bool = false

# ============================================================
#  调参 (全部接 Tuner, kind="grapple")
# ============================================================

@export_group("Core")
## 钩索总开关. 0=禁用整套钩索系统, 1=启用
@export var grapple_enabled: bool = true
## 最大射程 (米). 玩家车与锚点距离 > 此值无法钩中
@export_range(5.0, 100.0, 0.5) var max_distance: float = 40.0
## 最小射程 (米). 距离 < 此值不触发(贴脸不钩)
@export_range(0.0, 5.0, 0.1) var min_distance: float = 2.0
## 绳子飞出时的视觉速度 (米/秒). 越大绳子越"瞬移"过去
@export_range(20.0, 500.0, 5.0) var attach_speed: float = 200.0

@export_group("Pull Force")
## 拉力总持续时间 (秒). 钩中后开始倒计时, 到时自动释放
@export_range(0.2, 5.0, 0.05) var pull_duration: float = 1.4
## 拉力峰值 (m/s², 内部会乘 mass). 实际加速度 = 此值 × 力曲线 × 速度曲线 × 距离因子
@export_range(5.0, 300.0, 1.0) var pull_force_max: float = 80.0
## 力随时间变化曲线 (X=进度0~1, Y=力倍率0~2). 默认 Tuner 给 BOOST_KICK 起始猛→衰减
@export var force_time_curve: Curve
## 速度响应曲线 (X=v/speed_ref 0~1, Y=力倍率). 默认 LINEAR_FADE_OUT 让高速时少给力
## 数学: 当车速 v 接近 speed_ref 时, 力衰减; 防止"高速钩索把车甩出去离谱"
@export var speed_response_curve: Curve
## 速度参考值 (m/s). speed_response_curve 的 X=1 对应到这个车速
@export_range(10.0, 100.0, 1.0) var speed_ref: float = 50.0

@export_group("Pull Direction")
## 拉力方向的"上抬偏置": 0=纯指向锚点, 1=完全向上.
## 取值 0.0~0.5 让车被拉时有"轻微抬升"的感觉(更接近 Apex 钩索手感)
@export_range(0.0, 1.0, 0.02) var pull_upward_bias: float = 0.15
## 弧线曲线 (X=进度0~1, Y=额外向上加速度倍率0~2). 让被拉过程像"抛物线"而非直线
@export var arc_curve: Curve
## 额外向上加速度峰值 (m/s² × mass). 配合 arc_curve 使用
@export_range(0.0, 50.0, 0.5) var arc_upward_force: float = 12.0

@export_group("Release")
## 接近锚点的释放距离 (米). 当车与锚点距离 < 此值, 自动释放(避免直接撞锚点)
@export_range(0.5, 10.0, 0.1) var release_distance: float = 2.5
## 释放瞬间沿当前运动方向的冲量 (m/s × mass). 让玩家"被甩出去"
@export_range(0.0, 30.0, 0.5) var release_kick_impulse: float = 8.0
## 释放瞬间额外向上冲量 (m/s × mass). 让玩家被甩起腾空一下
@export_range(0.0, 20.0, 0.5) var release_upward_kick: float = 4.0
## 释放冲量与起钩绳长的关系曲线 (X=起钩距离/max_distance 0~1, Y=冲量倍率 0~3)
## 数学: 实际释放冲量 = release_kick_impulse × curve.sample(initial_distance / max_distance)
## 默认: 近距离 0.4 (短绳冲量小), 中距离 1.0 (标准), 远距离 1.8 (长绳甩得更猛)
## 设计意图: 长绳积累的动能更大, 释放时应该获得更大的甩出速度, 类似 Apex 远距离钩索的爆发感
@export var release_distance_curve: Curve
## 释放后车头摆正持续时间 (秒). 钩索释放瞬间, 如果车头没朝速度方向, 会在此时间内平滑摆正
## 数学: 释放后 car._grapple_release_align_left = 此值, 每帧递减, >0 时做车头→速度方向的 slerp
## 0 = 不摆正 (释放后车头保持原样); 0.3~0.5 = 推荐 (丝滑摆正, 不突兀)
## 注意: 正常从跳台飞出不会触发 (因为 _grapple_active 从未为 true, 不走此逻辑)
@export_range(0.0, 2.0, 0.05) var release_align_duration: float = 0.4
## 玩家松开空格是否能提前释放. 1=松开就释放, 0=必须等到时间到/距离够
@export var release_on_button_release: bool = true
## 【自动甩出: 反向拽保护】当车直线钩正前方锚点 + 玩家无侧向输入时, 拉力会把车减速到反向
## 这种情况下应该在车减速到几乎停止前自动甩出, 否则玩家会被绳子"拽得倒退", 体验差
## 启用后每帧检测: 没有左右方向键明显输入 + 车速 < auto_release_speed_threshold → 自动释放
@export var auto_release_on_stall: bool = true
## 触发自动甩出的车速阈值 (m/s). 车速降到此值以下且没有侧向输入 → 自动释放
@export_range(0.0, 30.0, 0.5) var auto_release_speed_threshold: float = 6.0
## 自动甩出的侧向输入死区: |steer_input| 小于此值视为"没在 swing"
@export_range(0.0, 1.0, 0.05) var auto_release_steer_deadzone: float = 0.15

@export_group("Aim Assist")
## 瞄准辅助锥角 (度) — 半锥角!! 总可瞄准范围 = 此值 × 2
##   60 = 总锥角 120° (车头左右各 60° 都能瞄到, Apex 推荐手感)
##   45 = 总锥角 90°
##   30 = 总锥角 60° (严格)
## 锚点与"车头方向"的水平夹角 < 此值才进候选
@export_range(5.0, 90.0, 1.0) var aim_assist_angle_deg: float = 60.0
## 瞄准时是否优先选"沿速度方向"的锚点. 0=只看角度, >0=越大越偏向速度方向
@export_range(0.0, 5.0, 0.1) var aim_priority_speed_weight: float = 1.0
## 距离权重: 选锚点时距离越近优先级越高的乘数. 越大越偏向近锚点
@export_range(0.0, 5.0, 0.1) var aim_priority_distance_weight: float = 1.0

@export_group("Car Interaction")
## 钩索期间是否抑制引擎力. 1=抑制(玩家不能踩油门抢方向), 0=保留引擎
@export var disable_engine_during_pull: bool = true
## 钩索期间摩擦倍率. 0=完全无摩擦让车滑出去, 1=保持原摩擦, 0.3=削减 70%
@export_range(0.0, 1.0, 0.05) var friction_mult_during_pull: float = 0.2
## 钩索期间是否中断漂移 (DRIFT 状态会被强制结束). 1=中断, 0=保留
@export var cancel_drift_on_grapple: bool = true

# ====================================================
# 空中操控 (让玩家能"借助钩索荡起来")
# ====================================================
# 设计: Apex 探路者钩索的精髓 = 玩家按方向键能把自己"甩"出弧线, 而不是被绳子直线拽过去
# 实现方式: 在主拉力 (沿 anchor 方向) 之外, 额外施加两股玩家可控的力:
#   1) 侧向推力 = 车头右方向 × steer_input × swing_side_force
#      → 按左/右方向键能让车绕锚点荡成弧线 (类似钟摆向侧面推)
#   2) 前推力 = 车头前方向 × throttle_input × swing_forward_force
#      → 按前进键加速 swing, 后退键减速/反向 (帮玩家调整能量)
#   3) yaw 转向 = 直接给 car_mesh 转一下朝向, 让玩家"钩着绳子转圈"的视觉
#      这个走 car._update_visuals 已经在处理, 我们只要不抑制 engine 即可自动生效
@export_group("Swing Control (钩索期间的空中操控)")
## 空中操控总开关. 1=启用下面三股力, 0=完全禁用 (玩家被纯粹拽过去, 不能操控)
@export var swing_control_enabled: bool = true
## 侧向推力: 车头右方向 × steer_input × 此值 × mass (N). 
## 让玩家按方向键能把钩索荡成弧线, 而不是直线拉过去
## 推荐 20~40. 大了过灵敏, 小了手感弱
@export_range(0.0, 120.0, 1.0) var swing_side_force: float = 30.0
## 前推力: 车头前方向 × throttle_input × 此值 × mass (N)
## 让玩家按前进键能"加速 swing", 后退键"减速/倒荡"
## 注意: throttle_input 范围是 -1~+1, 所以这个力可以是正也可以是负
## 推荐 15~30
@export_range(0.0, 100.0, 1.0) var swing_forward_force: float = 20.0
## 距离-推力曲线 (X=起钩瞬间车到锚点的距离 / max_distance, Y=推力倍率 0~2).
## 用户要求: 起钩距离决定 ATTACHED 期间的"空中前进推力大小".
## 解读: X=0 表示发射时贴脸 (距离=0); X=1 表示发射时刚好在 max_distance.
##   默认: 短距离推力 0.6 (近距离不需要太多前进推, 拉力本身就够), 远距离 1.5 (弧线挂得久, 需要更多推力)
##   玩家可在 Tuner → 钩索 Tab 调整这条曲线.
@export var distance_force_curve: Curve
## 钩索期间的 yaw 转向响应速度倍率 (相对 car.turn_speed 的倍数)
## 钩索期间车其实是"空中姿态", 转起来应该比地面慢但还要能转
## 实现方式: 通过给 car.linear_velocity 加侧向力间接影响路径, 视觉 yaw 走 car 自己的 _update_visuals
## 这里仅保留作为未来"直接改 car_mesh yaw"的扩展位
@export_range(0.0, 3.0, 0.05) var swing_yaw_speed_mult: float = 1.0
## 钩索期间车头朝向跟随的最大角速度 (rad/s)
## 用户反馈: 车身朝向太容易跳变. 把"一帧最多转多少角度"卡死, 哪怕 angle_diff 很大也按这个速度过渡
## 推荐 3~6, 越小越平滑但跟手差; 6 是默认手感
@export_range(0.5, 20.0, 0.1) var facing_max_rate_rad: float = 6.0
## 跟随过渡时长 (秒). 0 = 用上面 max_rate 直接限速; >0 = 用指数衰减插值, 让车头从当前朝向逐渐对齐目标
## 体验: 0.15 ≈ "丝滑跟随", 0.0 ≈ "立刻对齐 (旧行为)"
@export_range(0.0, 1.0, 0.01) var facing_smooth_time: float = 0.15
## 重力抵消比例: 钩索期间每帧主动施加一个抵消重力的力. 1=完全抵消(像 Apex 那样完全由绳子控制)
## 0=保留全部重力(车会自然下坠, 绳子和重力博弈), 0.5=抵消一半
## 推荐 0.7~0.9 让玩家感觉"被绳子轻轻拎着", 不会砸下来
@export_range(0.0, 1.5, 0.05) var gravity_compensation: float = 0.8

@export_group("Camera Effect")
## 钩索期间 FOV 增量 (度). 镜头会拉远突出"被甩"的感觉
@export_range(0.0, 40.0, 0.5) var cam_fov_boost: float = 12.0
## FOV 增量随进度变化曲线 (X=进度, Y=倍率). 让 FOV 启动急剧, 后段保持
@export var cam_fov_curve: Curve
## 钩索期间镜头横滚角度 (度). 朝拉力方向倾斜镜头, 像 Apex 那样
@export_range(0.0, 30.0, 0.5) var cam_roll_deg: float = 12.0
## roll 随进度变化曲线
@export var cam_roll_curve: Curve
## 钩索期间持续震动强度
@export_range(0.0, 3.0, 0.05) var cam_shake_intensity: float = 0.15
## 释放瞬间的震动强度 (大幅震一下凸显爆发)
@export_range(0.0, 5.0, 0.05) var cam_shake_release: float = 1.2

@export_group("Rope Visual")
## 绳子粗细 (米)
## 用户要求: 绳子要粗一点 (旧默认 0.05m 像头发丝, 改成 0.08m 看着像真绳子)
@export_range(0.01, 0.5, 0.01) var rope_thickness: float = 0.08
## 绳子颜色
## 用户要求: 黑色绳子 (旧默认是浅蓝白色, 跟氮气特效太接近不显眼)
@export var rope_color: Color = Color(0.05, 0.05, 0.05, 1.0)
## 绳子起点偏移 (相对车 transform 本地坐标). 让绳子从车头/车顶发出, 而不是车球心
@export var rope_origin_offset: Vector3 = Vector3(0.0, 0.5, -0.5)

# ---------------- 信号 ----------------
## 状态变化: IDLE/SHOOTING/ATTACHED/RELEASING
signal grapple_state_changed(state_str: String, anchor_pos: Vector3)
## 锚点高亮变化(供 HUD 显示瞄准提示)
signal anchor_focus_changed(anchor: Node)
## 拉动进度更新, progress=0~1, 给 Camera 用做 FOV/roll 平滑
signal grapple_progress(progress: float, anchor_pos: Vector3, pull_dir: Vector3)
## 钩索触发(锁定锚点) 和 释放
signal grapple_started(anchor_pos: Vector3)
signal grapple_released(success: bool)

# ---------------- 内部状态 ----------------
var _current_anchor: Node = null
var _focus_anchor: Node = null   # 当前正在被高亮的锚点(瞄准提示)
var _pull_elapsed: float = 0.0   # 当前拉动已经过的秒数
var _shoot_elapsed: float = 0.0  # SHOOTING 状态已经过的秒数
var _shoot_total: float = 0.0    # SHOOTING 状态预计总秒数 (= 距离 / attach_speed)
var _rope_visible_t: float = 0.0 # 绳子可见进度 (SHOOTING 时 0→1, ATTACHED 时保持 1)
# 起钩瞬间车到锚点的初始距离 (米). 用户要求: 这个距离决定 ATTACHED 期间空中前进推力大小.
# 由 _start_shoot 记录, ATTACHED 期间用 distance_force_curve.sample(d/max_distance) 缩放 swing_forward_force.
var _initial_grapple_distance: float = 0.0
# 自动甩出 (反向拽保护) 状态
var _attach_initial_speed: float = 0.0   # 钩住瞬间记录的车速, 用于判断"是否被减速到很低"
# 给玩家一段缓冲时间不触发 stall 检测 (刚钩住时车会先沿径向加速一段时间, 不算 stall)
var _stall_grace_left: float = 0.0
const _STALL_GRACE_TIME: float = 0.25   # 钩住后 0.25s 内不做 stall 自动甩出判定


func _ready() -> void:
	# 解析车路径
	if not car_path.is_empty() and has_node(car_path):
		car = get_node(car_path) as RigidBody3D
	if car == null and get_parent() is RigidBody3D:
		# 如果没设 car_path 但被挂在 Car 节点下, 自动用父节点
		car = get_parent() as RigidBody3D
	if car == null:
		push_warning("[GrappleHook] 找不到 car (car_path 没设, 父节点也不是 RigidBody3D)")
	# 默认曲线兜底 (Tuner 加载 cfg 时会覆盖)
	_init_default_curves()
	# 构建绳子视觉
	_build_rope_mesh()


func _init_default_curves() -> void:
	if force_time_curve == null:
		# BOOST_KICK 风格: 起始 1.5 倍 → 收尾 0.4 倍, 让玩家有"嘭"一下被拽出去的感觉
		force_time_curve = Curve.new()
		force_time_curve.add_point(Vector2(0.0, 1.5))
		force_time_curve.add_point(Vector2(0.2, 1.2))
		force_time_curve.add_point(Vector2(0.6, 0.9))
		force_time_curve.add_point(Vector2(1.0, 0.4))
	if speed_response_curve == null:
		# LINEAR_FADE_OUT: 慢速 1.0 倍 → 高速 0.3 倍, 防止高速钩索甩飞
		speed_response_curve = Curve.new()
		speed_response_curve.add_point(Vector2(0.0, 1.0))
		speed_response_curve.add_point(Vector2(0.5, 0.7))
		speed_response_curve.add_point(Vector2(1.0, 0.3))
	if arc_curve == null:
		# 钟形: 中段最高(模拟抛物线峰), 起末段低
		arc_curve = Curve.new()
		arc_curve.add_point(Vector2(0.0, 0.2))
		arc_curve.add_point(Vector2(0.5, 1.0))
		arc_curve.add_point(Vector2(1.0, 0.3))
	if cam_fov_curve == null:
		# FADE_IN_OUT: 启动急速拉满, 中段保持, 末段稍降
		cam_fov_curve = Curve.new()
		cam_fov_curve.add_point(Vector2(0.0, 0.0))
		cam_fov_curve.add_point(Vector2(0.15, 1.0))
		cam_fov_curve.add_point(Vector2(0.85, 0.9))
		cam_fov_curve.add_point(Vector2(1.0, 0.3))
	if cam_roll_curve == null:
		# 类似 FOV, 但更快达峰
		cam_roll_curve = Curve.new()
		cam_roll_curve.add_point(Vector2(0.0, 0.0))
		cam_roll_curve.add_point(Vector2(0.2, 1.0))
		cam_roll_curve.add_point(Vector2(0.85, 1.0))
		cam_roll_curve.add_point(Vector2(1.0, 0.0))
	if distance_force_curve == null:
		# 距离-推力曲线: x=起钩距离/max_distance (0~1), y=推力倍率 (0~2)
		# 默认: 近距离 0.6 (近距离拉力本身就够, 不需要太多前进推);
		#       中距离 1.0 (标准推力);
		#       远距离 1.5 (弧线挂得久, 需要更多推力维持速度).
		# 玩家可在 Tuner → 钩索 Tab 调这条曲线
		distance_force_curve = Curve.new()
		distance_force_curve.add_point(Vector2(0.0, 0.6))
		distance_force_curve.add_point(Vector2(0.5, 1.0))
		distance_force_curve.add_point(Vector2(1.0, 1.5))
	if release_distance_curve == null:
		# 释放冲量-绳长曲线: x=起钩距离/max_distance (0~1), y=冲量倍率 (0~3)
		# 默认: 近距离 0.4 (短绳冲量小, 不需要甩太远);
		#       中距离 1.0 (标准冲量);
		#       远距离 1.8 (长绳积累动能大, 释放甩得更猛).
		# 设计: 模拟真实钩索物理 — 绳越长, 摆动弧越大, 释放时切线速度越高
		release_distance_curve = Curve.new()
		release_distance_curve.add_point(Vector2(0.0, 0.4))
		release_distance_curve.add_point(Vector2(0.5, 1.0))
		release_distance_curve.add_point(Vector2(1.0, 1.8))


# ============================================================
# 绳子视觉重写 (Apex Legends 风格): 用 Godot 内建 look_at_from_position API
# ============================================================
# 历史 (失败的方案):
# v1: ImmediateMesh + LINE_STRIP        → GPU 强制 1px 线宽, 看不见
# v2: CylinderMesh + 手搓 basis 数学     → basis 构造太脆弱, 经常出问题
# v3: top_level=true 挂 GrappleHook 子   → top_level 不解耦渲染层级, visibility 干扰
# v4: 挂场景根 + 手搓 basis              → 仍然有 basis 出错的概率
#
# v5 (本次, 最终方案): 抄 Apex Titanfall 的 grapple 实现
# 1. 绳子是个 ArrayMesh 圆柱, 但**几何特殊**:
#    - 底面 (一端) 在 node 原点 (0, 0, 0)
#    - 顶面 (另一端) 在 node 局部 (0, 0, -1)  ← 沿 -Z 方向
#    - 半径 = rope_thickness, 顶面只是一个圆 (没盖, 因为绳子两端会被节点遮住)
# 2. 每帧调 Godot 内建 API: _rope_mesh_inst.look_at_from_position(p0, p1, up)
#    → 让节点位于 p0 (车), -Z 朝向 p1 (锚点)
#    → Godot 自己算 basis, 100% 不会有 basis 错误
#    → 因为圆柱顶面在节点局部 (0,0,-1), look_at 后顶面正好被推到 (p1-p0).normalized() 方向上 1 米处
# 3. 绳子长度通过 **scale.z = |p1-p0|** 控制
#    → 圆柱底面 (在 node 原点 = p0) 不动, 顶面被拉到 p0 + (-Z) × len = p0 + (p1-p0) = p1
#    → 完美贴合两端
# 4. 挂在 GrappleHook 节点下 (它本身位置无所谓, 因为子节点用 global_transform 完全自定位)
# ============================================================
var _rope_array_mesh: ArrayMesh = null


func _build_rope_mesh() -> void:
	if _rope_mesh_inst != null:
		return
	# 用 ArrayMesh 手写圆柱: 底面在 (0,0,0), 顶面在 (0,0,-1), 半径 = rope_thickness
	# 这样圆柱沿 -Z 延伸 1 米, 配合 look_at 的 -Z 朝目标语义完美贴合两端
	_rope_array_mesh = _build_rope_cylinder_mesh(rope_thickness)
	_rope_mesh_inst = MeshInstance3D.new()
	_rope_mesh_inst.name = "RopeCyl"
	_rope_mesh_inst.mesh = _rope_array_mesh
	# Unshaded 黑色: 绳子在阴影里也清晰可见, 不被光照模糊
	_rope_mat = StandardMaterial3D.new()
	_rope_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rope_mat.albedo_color = rope_color
	_rope_mat.disable_receive_shadows = true
	# 关闭剔除让玩家从绳子任意角度都看到 (圆柱内部也可见)
	_rope_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_rope_mesh_inst.material_override = _rope_mat
	_rope_mesh_inst.visible = false
	# 直接挂在 GrappleHook 节点下: 我们每帧用 global_transform 完全自定位, 父节点位置无所谓
	# 不再用 top_level / 场景根, 这些都是过去失败方案的残留, Apex 风格只需要简单挂载
	add_child(_rope_mesh_inst)


# 构造一个朝 -Z 延伸 1 米、半径 r 的圆柱 ArrayMesh
# 顶点布局:
#   底面圆环 N 个顶点 (z=0)
#   顶面圆环 N 个顶点 (z=-1)
# 三角形: 侧面 N×2 个三角形 (一圈两面)
# 不画顶/底盖 (没必要, 玩家看不到端面)
func _build_rope_cylinder_mesh(r: float) -> ArrayMesh:
	const N: int = 8   # 8 边形圆柱足够圆滑, 比 16 省一半 GPU
	var verts: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var indices: PackedInt32Array = PackedInt32Array()
	# 底面 N 个顶点 (z=0)
	for i in range(N):
		var ang: float = (TAU / N) * i
		var x: float = cos(ang) * r
		var y: float = sin(ang) * r
		verts.append(Vector3(x, y, 0.0))
		normals.append(Vector3(cos(ang), sin(ang), 0.0))
	# 顶面 N 个顶点 (z=-1)
	for i in range(N):
		var ang2: float = (TAU / N) * i
		var x2: float = cos(ang2) * r
		var y2: float = sin(ang2) * r
		verts.append(Vector3(x2, y2, -1.0))
		normals.append(Vector3(cos(ang2), sin(ang2), 0.0))
	# 侧面三角形: 每个 i 配 i+1, 底/顶各 1 顶点 = 4 个顶点 → 2 个三角
	# 顶点编号: 底 = 0..N-1, 顶 = N..2N-1
	for i in range(N):
		var ni: int = (i + 1) % N
		var b0: int = i
		var b1: int = ni
		var t0: int = i + N
		var t1: int = ni + N
		# 三角 1: b0 - t0 - b1 (右手系朝外)
		indices.append(b0); indices.append(t0); indices.append(b1)
		# 三角 2: b1 - t0 - t1
		indices.append(b1); indices.append(t0); indices.append(t1)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return am


# ============================================================
#  公共接口: 玩家按下空格 (由 car.gd 路由调用)
# ============================================================
func try_fire() -> bool:
	if not grapple_enabled:
		return false
	if state != State.IDLE:
		# 已经在钩索流程里了, 第二次按空格意味着"提前释放"
		if state == State.ATTACHED:
			_release(true)
		return false
	if car == null:
		return false
	# 找最佳锚点
	var anchor: Node = _find_best_anchor()
	if anchor == null:
		print("[Grapple] 找不到合适的锚点")
		return false
	_start_shoot(anchor)
	return true


func try_release() -> void:
	# 玩家松开空格时调用 (如果开启了 release_on_button_release)
	if state == State.ATTACHED and release_on_button_release:
		_release(true)


# ============================================================
#  锚点选择
# ============================================================
func _find_best_anchor() -> Node:
	if car == null:
		return null
	var anchors: Array = get_tree().get_nodes_in_group("grapple_anchors")
	if anchors.is_empty():
		return null

	var car_pos: Vector3 = car.global_position
	var car_forward: Vector3 = -car.global_transform.basis.z   # car 节点的 -Z 是车头方向
	# 但 car 是 RigidBody, basis 不一定代表车头. 真正的车头在 car_mesh.
	# car.gd 里 car_mesh 是 top_level=true 的独立朝向, 用 car_mesh.global_transform 更准
	var car_mesh: Node3D = car.get_node_or_null("CarMesh") as Node3D
	if car_mesh != null:
		car_forward = -car_mesh.global_transform.basis.z
	car_forward.y = 0.0
	if car_forward.length() < 0.001:
		car_forward = Vector3.FORWARD
	car_forward = car_forward.normalized()

	# 速度方向 (用于 aim_priority_speed_weight)
	var v: Vector3 = car.linear_velocity
	v.y = 0.0
	var v_dir: Vector3 = v.normalized() if v.length() > 1.0 else car_forward

	var best: Node = null
	var best_score: float = -INF
	var aim_cos_threshold: float = cos(deg_to_rad(aim_assist_angle_deg))

	for a in anchors:
		if not (a is Node3D):
			continue
		var ap: Vector3 = (a as Node3D).global_position
		var to_a: Vector3 = ap - car_pos
		var dist: float = to_a.length()
		if dist > max_distance or dist < min_distance:
			continue
		# 检查锚点自己的 detect_radius (玩家必须在锚点检测范围内才能瞄准)
		if "detect_radius" in a:
			var dr: float = float(a.get("detect_radius"))
			if dist > dr:
				continue
		# 锥角判定: 用水平方向的 cos 做主判定 (让仰角不影响"前方锥"语义)
		# 但允许向上/向下的锚点进入候选 (只要水平投影在锥内)
		var to_a_flat_norm: Vector3 = Vector3(to_a.x, 0.0, to_a.z)
		if to_a_flat_norm.length() < 0.001:
			# 锚点正上/正下方: 当作 0° (绝对正前)
			to_a_flat_norm = car_forward
		else:
			to_a_flat_norm = to_a_flat_norm.normalized()
		var cos_to_forward: float = car_forward.dot(to_a_flat_norm)
		if cos_to_forward < aim_cos_threshold:
			continue
		# Score = 角度分 + 距离分 + 速度方向分
		var angle_score: float = cos_to_forward    # 越接近 1 越好
		var dist_score: float = 1.0 - clampf(dist / max_distance, 0.0, 1.0)   # 越近越好
		var speed_score: float = 0.0
		if aim_priority_speed_weight > 0.0:
			speed_score = v_dir.dot(to_a_flat_norm)
		var total: float = angle_score \
			+ dist_score * aim_priority_distance_weight \
			+ speed_score * aim_priority_speed_weight
		if total > best_score:
			best_score = total
			best = a
	return best


# ============================================================
#  状态切换
# ============================================================
func _start_shoot(anchor: Node) -> void:
	_current_anchor = anchor
	if anchor != null and anchor.has_method("set_highlighted"):
		anchor.set_highlighted(true)
	state = State.SHOOTING
	_shoot_elapsed = 0.0
	# SHOOTING 阶段时间 = 距离 / attach_speed, 至少 0.05s 让视觉看到绳子飞出
	var dist: float = (anchor as Node3D).global_position.distance_to(_rope_origin_world())
	_shoot_total = maxf(dist / maxf(attach_speed, 1.0), 0.05)
	# 记录起钩瞬间的初始距离, ATTACHED 期间用它查 distance_force_curve 缩放推力
	# 用户要求: x=距离 y=推力, 这个距离决定后续空中操控前进推力大小
	_initial_grapple_distance = dist
	_rope_mesh_inst.visible = true
	emit_signal("grapple_state_changed", "SHOOTING", (anchor as Node3D).global_position)


func _start_attach() -> void:
	state = State.ATTACHED
	_pull_elapsed = 0.0
	# 通知 car 进入钩索状态 (car.gd 会读这个 flag 做摩擦/引擎抑制)
	if car != null and "_grapple_active" in car:
		car.set("_grapple_active", true)
	# 中断漂移
	if cancel_drift_on_grapple and car != null and car.has_method("_end_drift"):
		# 通过判 state 字段安全调用
		if "state" in car and "State" in car:
			# car.State.DRIFT 是 enum, 取值 1 (NORMAL=0, DRIFT=1)
			if int(car.get("state")) == 1:
				car.call("_end_drift", false, true, false)   # manual=true, failed=false 走正常退漂
	# === 记录初速度 (反向拽自动甩出用) ===
	if car != null:
		_attach_initial_speed = car.linear_velocity.length()
		# 给玩家一小段宽限时间, 避免刚钩住车速还没起来就被自动释放
		_stall_grace_left = _STALL_GRACE_TIME
	emit_signal("grapple_state_changed", "ATTACHED", (_current_anchor as Node3D).global_position)
	emit_signal("grapple_started", (_current_anchor as Node3D).global_position)


func _release(success: bool) -> void:
	if state == State.IDLE:
		return
	# 释放冲量
	if state == State.ATTACHED and car != null:
		var anchor_pos: Vector3 = (_current_anchor as Node3D).global_position
		var to_anchor: Vector3 = anchor_pos - car.global_position
		# 沿"接近锚点的切线方向"给冲量更接近 Apex 手感:
		# 但简单起见, 沿当前速度方向给, 同时叠一个向上分量
		var v_dir: Vector3 = car.linear_velocity
		if v_dir.length() < 1.0:
			# 速度太小就用"绳子方向"作为切线
			v_dir = to_anchor
		v_dir.y = 0.0
		if v_dir.length() > 0.001:
			v_dir = v_dir.normalized()
		else:
			v_dir = -car.global_transform.basis.z
			v_dir.y = 0.0
			v_dir = v_dir.normalized()
		# === 释放冲量与起钩绳长正相关 ===
		# 数学: kick = release_kick_impulse × release_distance_curve.sample(initial_distance / max_distance)
		# 长绳积累动能大 → 释放甩出速度更大 (Apex 远距离钩索爆发感)
		var dist_ratio: float = clampf(_initial_grapple_distance / maxf(max_distance, 0.001), 0.0, 1.0)
		var dist_kick_mult: float = _sample_curve_safe(release_distance_curve, dist_ratio, 1.0)
		var actual_kick: float = release_kick_impulse * dist_kick_mult
		# 沿运动方向冲量
		car.apply_central_impulse(v_dir * actual_kick * car.mass)
		# 向上冲量 (腾空感) — 也受距离曲线影响
		car.apply_central_impulse(Vector3.UP * release_upward_kick * dist_kick_mult * car.mass)
		# === 通知 car 进入释放后车头摆正状态 ===
		# 钩索释放时车头可能没朝速度方向 (swing 过程中车头跟随锚点切线),
		# 需要在释放后短暂时间内帮车头平滑转向速度方向, 让玩家出钩索后能直线跑
		# 注意: 正常从跳台飞出不触发 (因为 _grapple_active 从未为 true)
		if release_align_duration > 0.0 and "_grapple_release_align_left" in car:
			car.set("_grapple_release_align_left", release_align_duration)
			print("[Grapple] 释放: 车头摆正 %.2fs, 冲量倍率 %.2f (起钩距离 %.1fm)" % [release_align_duration, dist_kick_mult, _initial_grapple_distance])
		# 释放震动
		if cam_shake_release > 0.0 and car.has_signal("camera_shake_requested"):
			car.emit_signal("camera_shake_requested", cam_shake_release, 0.25)
	# 取消高亮
	if _current_anchor != null and _current_anchor.has_method("set_highlighted"):
		_current_anchor.set_highlighted(false)
	# 通知 car 退出钩索状态
	if car != null and "_grapple_active" in car:
		car.set("_grapple_active", false)
	# 隐藏绳子
	_rope_mesh_inst.visible = false
	state = State.IDLE
	_pull_elapsed = 0.0
	_shoot_elapsed = 0.0
	emit_signal("grapple_released", success)
	emit_signal("grapple_state_changed", "IDLE", Vector3.ZERO)
	_current_anchor = null


# ============================================================
#  物理更新 (主循环)
# ============================================================
func _physics_process(delta: float) -> void:
	if not grapple_enabled or car == null:
		_update_focus_only()   # 即使禁用也维护"瞄准锚点高亮"
		return
	match state:
		State.IDLE:
			_update_focus_only()
		State.SHOOTING:
			_update_shooting(delta)
		State.ATTACHED:
			_update_attached(delta)
		State.RELEASING:
			pass   # 一帧瞬态, 不应该停留


func _update_focus_only() -> void:
	# IDLE 时找出"如果按空格会钩到的锚点", 让它高亮 (类似 Apex 紫色描边)
	var best: Node = _find_best_anchor()
	if best != _focus_anchor:
		# 旧的取消高亮
		if _focus_anchor != null and _focus_anchor.has_method("set_highlighted"):
			_focus_anchor.set_highlighted(false)
		_focus_anchor = best
		if _focus_anchor != null and _focus_anchor.has_method("set_highlighted"):
			_focus_anchor.set_highlighted(true)
		emit_signal("anchor_focus_changed", _focus_anchor)


func _update_shooting(delta: float) -> void:
	_shoot_elapsed += delta
	# 绳子可见进度 0→1
	_rope_visible_t = clampf(_shoot_elapsed / maxf(_shoot_total, 0.001), 0.0, 1.0)
	_redraw_rope(_rope_visible_t)
	# 完成飞出后切到 ATTACHED
	if _shoot_elapsed >= _shoot_total:
		_start_attach()


func _update_attached(delta: float) -> void:
	if _current_anchor == null:
		_release(false)
		return
	_pull_elapsed += delta
	var progress: float = clampf(_pull_elapsed / maxf(pull_duration, 0.001), 0.0, 1.0)

	# === 拉力计算 ===
	var anchor_pos: Vector3 = (_current_anchor as Node3D).global_position
	var car_pos: Vector3 = car.global_position
	var to_anchor: Vector3 = anchor_pos - car_pos
	var dist: float = to_anchor.length()

	# 自动释放: 接近锚点
	if dist < release_distance:
		_release(true)
		return
	# 自动释放: 时间到
	if progress >= 1.0:
		_release(true)
		return

	# 拉力方向 = (to_anchor 单位向量) + 上抬偏置
	var pull_dir: Vector3 = to_anchor.normalized()
	# 上抬偏置: 把方向"抬高"一些, 让车被拉时不只是直线冲过去, 还有点抬升感
	if pull_upward_bias > 0.0:
		pull_dir = (pull_dir.lerp(Vector3.UP, pull_upward_bias)).normalized()

	# 力大小 = peak × 时间曲线 × 速度曲线 × 距离因子
	var v_speed: float = car.linear_velocity.length()
	var time_k: float = _sample_curve_safe(force_time_curve, progress, 1.0)
	var speed_k: float = _sample_curve_safe(speed_response_curve, clampf(v_speed / maxf(speed_ref, 0.001), 0.0, 1.0), 1.0)
	# 距离因子: 越远拉得越用力, 接近时降一点 (避免接近锚点时还猛拉超过头)
	var dist_factor: float = clampf(dist / maxf(max_distance, 0.001), 0.05, 1.0)
	var force_mag: float = pull_force_max * time_k * speed_k * dist_factor

	# 主拉力 (沿 pull_dir, 单位 m/s² × mass)
	car.apply_central_force(pull_dir * force_mag * car.mass)

	# 弧线: 额外向上加速度 (抛物感), 由 arc_curve 控制
	if arc_upward_force > 0.0 and arc_curve != null:
		var arc_k: float = _sample_curve_safe(arc_curve, progress, 0.0)
		car.apply_central_force(Vector3.UP * arc_upward_force * arc_k * car.mass)

	# ============================================================
	# 空中操控 (Apex 风格 swing)
	# ============================================================
	# 让玩家按方向键能把钩索荡成弧线, 按前/后能调能量, 借助绳子转一圈
	#
	# 数学:
	#   steer_input = Input.get_axis("steer_right", "steer_left")  (范围 -1~+1)
	#     左键 → steer_input 正, 右键 → 负 (car.gd 的约定, 与 Godot 默认相反)
	#   throttle_input = Input.get_axis("brake", "accelerate")  (范围 -1~+1)
	#
	#   侧向力 = car_right × steer_input × swing_side_force × mass
	#     car_right 是车头 basis.x (右方向的世界向量)
	#     但因为 steer_input 左是正, 按左方向键给车一个向左的力就需要 -car_right × steer_input
	#     (这样按 ← 车往左荡, 按 → 车往右荡, 符合直觉)
	#
	#   前进力 = car_forward × throttle_input × swing_forward_force × mass
	#     car_forward = -basis.z, 按 ↑ 加速朝车头方向, 按 ↓ 反向减速
	#
	#   重力抵消 = Vector3.UP × gravity × gravity_compensation × mass
	#     主动抵消重力, 让玩家感觉"被绳子拎着", 不会因为重力往下砸
	#
	# 施力时机: 在主拉力之后, 这样玩家输入"叠加"在拉力之上, 不会覆盖拉力约束
	if swing_control_enabled and car != null:
		# 取车头朝向. 优先用 CarMesh 的 basis (因为 CarMesh 是 top_level 独立朝向的)
		var car_basis: Basis = car.global_transform.basis
		var car_mesh_node: Node3D = car.get_node_or_null("CarMesh") as Node3D
		if car_mesh_node != null:
			car_basis = car_mesh_node.global_transform.basis
		var car_forward: Vector3 = -car_basis.z   # -Z 是车头
		var car_right: Vector3 = car_basis.x      # +X 是车右
		# 读玩家输入 (用 car 里已经读过的字段, 避免重复读 Input)
		var steer_in: float = 0.0
		var throttle_in: float = 0.0
		if "steer_input" in car:
			steer_in = float(car.get("steer_input"))
		if "throttle_input" in car:
			throttle_in = float(car.get("throttle_input"))

		# 1) 侧向力: 按方向键把车往侧面推, 产生 swing 弧线
		# steer_in 左=正, 所以向左力 = -car_right × steer_in
		if swing_side_force > 0.0 and absf(steer_in) > 0.01:
			var side_force: Vector3 = -car_right * steer_in * swing_side_force * car.mass
			car.apply_central_force(side_force)

		# 2) 前进力: 按前进键加速 swing, 按刹车键减速
		# 用户要求: 起钩瞬间的距离决定 ATTACHED 期间空中前进推力大小.
		# 数学: ratio = clamp(_initial_grapple_distance / max_distance, 0, 1)
		#       force_mult = distance_force_curve.sample(ratio)   (0~2)
		#       fwd_force = car_forward × throttle_input × swing_forward_force × force_mult × mass
		# 玩家可调曲线: 想"短距离起钩弱推 / 长距离起钩猛推"或反过来都行
		if swing_forward_force > 0.0 and absf(throttle_in) > 0.01:
			var dist_ratio: float = clampf(_initial_grapple_distance / maxf(max_distance, 0.001), 0.0, 1.0)
			var force_mult: float = _sample_curve_safe(distance_force_curve, dist_ratio, 1.0)
			var fwd_force: Vector3 = car_forward * throttle_in * swing_forward_force * force_mult * car.mass
			car.apply_central_force(fwd_force)

		# 3) 重力抵消: 让车"飘"起来, 不被重力拉下去
		if gravity_compensation > 0.0:
			# Godot 默认重力 9.8 m/s². 直接从 ProjectSettings 读, 保险起见兜底
			var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
			var gravity_scale: float = 1.0
			if "gravity_scale" in car:
				gravity_scale = float(car.get("gravity_scale"))
			var comp_force: Vector3 = Vector3.UP * g * gravity_scale * gravity_compensation * car.mass
			car.apply_central_force(comp_force)

	# ============================================================
	# 任务4: 反向拽自动甩出 (Stall Auto-Release)
	# ============================================================
	# 物理直觉: 玩家直线钩住正前方锚点 → 拉力把车减速 → 经过锚点(其实达不到, 因为 release_distance)
	# 但实际情况: 距离 > release_distance + 玩家不打方向 → 拉力把车减速到接近 0, 甚至反向
	# 这种情况下应该在车彻底停下/反向之前自动 release, 把车朝当前速度方向甩出去
	#
	# 触发条件 (全部满足):
	#   · auto_release_on_stall = true
	#   · _stall_grace_left ≤ 0 (过了起始宽限期, 让车有时间被加速)
	#   · |steer_input| < auto_release_steer_deadzone (玩家没在 swing)
	#   · 当前车速 < auto_release_speed_threshold (车快停了)
	# 数学:
	#   v_speed = car.linear_velocity.length()
	#   stall = (steer 死区内) AND (v_speed < threshold)
	# 时序: stall 检测放在主拉力之后, swing 之后, 绳子约束之前. 因为 stall 一旦触发立即 release+return.
	if _stall_grace_left > 0.0:
		_stall_grace_left -= delta
	if auto_release_on_stall and _stall_grace_left <= 0.0:
		var steer_in_check: float = 0.0
		if "steer_input" in car:
			steer_in_check = float(car.get("steer_input"))
		if absf(steer_in_check) < auto_release_steer_deadzone:
			# 玩家没在 swing, 检查车速是否被减速到很低
			var v_now: float = car.linear_velocity.length()
			if v_now < auto_release_speed_threshold:
				print("[Grapple] 反向拽保护: 车速降到 %.1f m/s + 无侧向输入, 自动甩出" % v_now)
				_release(true)
				return

	# 持续震动 (轻微, 让玩家感觉绳子有张力)
	if cam_shake_intensity > 0.0 and car.has_signal("camera_shake_requested"):
		# 用极短 duration 0.08, 让 camera 的 _on_shake 不断刷新, 形成持续抖动
		car.emit_signal("camera_shake_requested", cam_shake_intensity, 0.08)

	# 绳子重绘 (始终可见)
	_redraw_rope(1.0)
	# 通知 Camera 应用 FOV/roll
	emit_signal("grapple_progress", progress, anchor_pos, pull_dir)


# ============================================================
#  绳子可视化 (ImmediateMesh)
#  用 PRIMITIVE_LINE_STRIP 画一条多段线, 模拟"绳子飞出"
#  飞出时只画一部分, attach 后画到全程
#  实际项目可以扩展成 sin 摆动让绳子更生动, 这里先简化
# ============================================================
func _rope_origin_world() -> Vector3:
	if car == null:
		return global_position
	# 从车 + 局部偏移 (rope_origin_offset 在 car_mesh 本地坐标系)
	var car_mesh: Node3D = car.get_node_or_null("CarMesh") as Node3D
	if car_mesh != null:
		return car_mesh.global_transform * rope_origin_offset
	return car.global_transform * rope_origin_offset


func _redraw_rope(t: float) -> void:
	# ============================================================
	# Apex 风格绳子: Godot 内建 look_at_from_position API + Z scale
	# ============================================================
	# 核心数学 (圆柱 mesh 已构造为 z=0 → z=-1 沿 -Z 延伸 1 米):
	# 1. 节点位置 = p0 (车上), -Z 朝 p1 (锚点)
	# 2. scale.z = rope_len  →  原本顶面 (0,0,-1) 被拉到 (0,0,-rope_len)
	#                         本地 -Z 旋转后正好指向 p1, 所以世界坐标 = p0 + (p1-p0)/rope_len × rope_len = p1
	# 3. scale.x = scale.y = 1.0 → 圆柱粗细保持 rope_thickness 不变
	#
	# 用 look_at_from_position 而不是手搓 basis: Godot 引擎自己处理 up vector 和正交化,
	# 100% 不会有 basis 错误. 这是 Apex / Titanfall / 任何 AAA 钩索的标准实现.
	if _rope_mesh_inst == null:
		return
	if _current_anchor == null or t <= 0.0:
		_rope_mesh_inst.visible = false
		return
	var p0: Vector3 = _rope_origin_world()
	var p1: Vector3 = (_current_anchor as Node3D).global_position
	# 飞出阶段: 绳头从 p0 朝 p1 推进 t 比例; ATTACHED 时 t=1.0 → p_end = p1
	var p_end: Vector3 = p0.lerp(p1, t)
	var rope_vec: Vector3 = p_end - p0
	var rope_len: float = rope_vec.length()
	if rope_len < 0.01:
		# 长度太短: 隐藏 (但不影响下一帧, 因为下一帧 _redraw_rope 会再判断)
		_rope_mesh_inst.visible = false
		return
	# 关键调用: Godot 内建 look_at_from_position
	#   原型: look_at_from_position(position: Vector3, target: Vector3, up: Vector3 = Vector3.UP)
	#   效果: 节点 global_position = position, 节点的 -Z 朝向 target
	# 我们传 p0 (车) 作为 position, p_end (绳头当前位置) 作为 target
	# Godot 会自动处理: 当 (p_end - p0) 平行于 UP (Vector3(0,1,0)) 时, 自动选另一个 up 避免奇异
	# 但是为了万无一失, 我们手动选 up: 如果 rope_vec 接近垂直, 就用 RIGHT 当 up
	var up_hint: Vector3 = Vector3.UP
	if absf(rope_vec.normalized().dot(Vector3.UP)) > 0.99:
		up_hint = Vector3.RIGHT
	_rope_mesh_inst.look_at_from_position(p0, p_end, up_hint)
	# scale.z = rope_len: 圆柱 mesh 顶面在本地 (0,0,-1), 缩放 z 后变成 (0,0,-rope_len)
	# 节点经 look_at 后, 本地 -Z 已经朝 p_end, 所以世界顶面正好落在 p_end 上
	# 注意: 不要乘 (1, 1, rope_len), 因为 look_at 已经设过 basis, 直接用 scale 属性
	_rope_mesh_inst.scale = Vector3(1.0, 1.0, rope_len)
	_rope_mesh_inst.visible = true
	# 实时跟随颜色/粗细参数变化
	# 粗细变了要重建 mesh (因为 ArrayMesh 顶点写死了半径); 颜色变了改 material 即可
	if _rope_array_mesh != null and not is_equal_approx(_get_current_rope_radius(), rope_thickness):
		_rope_array_mesh = _build_rope_cylinder_mesh(rope_thickness)
		_rope_mesh_inst.mesh = _rope_array_mesh
	if _rope_mat and _rope_mat.albedo_color != rope_color:
		_rope_mat.albedo_color = rope_color
	# 调试日志: 进入 ATTACHED 第一帧打印 p0/p1, 帮助排查"绳子没贴合"
	if t >= 0.999 and not _logged_attached_rope:
		print("[GrappleHook] 绳子 ATTACHED p0(车)=%s p1(锚)=%s len=%.2f" % [p0, p1, rope_len])
		_logged_attached_rope = true
	if t < 0.999:
		_logged_attached_rope = false


# 取当前 _rope_array_mesh 实际编进去的半径 (从第一个顶点的 X 读)
# 用于检测"用户改了 rope_thickness 是否需要重建 mesh"
func _get_current_rope_radius() -> float:
	if _rope_array_mesh == null or _rope_array_mesh.get_surface_count() == 0:
		return 0.0
	var arrays: Array = _rope_array_mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return 0.0
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return 0.0
	# 第一个顶点是 (cos(0)*r, sin(0)*r, 0) = (r, 0, 0), x 就是当前半径
	return verts[0].x


func _sample_curve_safe(c: Curve, t: float, fallback: float) -> float:
	if c == null or c.point_count == 0:
		return fallback
	return c.sample(clampf(t, 0.0, 1.0))


# ============================================================
#  外部查询接口 (Camera/HUD 用)
# ============================================================
func is_attached() -> bool:
	return state == State.ATTACHED

func get_progress() -> float:
	if state != State.ATTACHED:
		return 0.0
	return clampf(_pull_elapsed / maxf(pull_duration, 0.001), 0.0, 1.0)

func get_anchor_position() -> Vector3:
	if _current_anchor == null:
		return Vector3.ZERO
	return (_current_anchor as Node3D).global_position
