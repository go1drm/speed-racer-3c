extends Camera3D
## ============================================================
##  赛车跟随相机 + 震动 + 氮气/双喷拉远
## ============================================================

# ---------------- 跟随 ----------------
@export_group("Follow")
## 相机插值速度, 越大越紧贴车(也越生硬). 过小 + 高速 = 车跑出屏幕
@export var lerp_speed: float = 3.0
## 基础偏移(相对车辆本地坐标). Z+ = 车后方, Y+ = 车上方
@export var offset: Vector3 = Vector3.ZERO
## 相机到车的最大允许距离. 超出立即 clamp 回来, 防止高速时被远远甩开
## 0 = 不限制(老行为)
@export var max_follow_lag: float = 8.0
## 基础 FOV(度)
@export var base_fov_override: float = 75.0
## 是否在 _ready 用 base_fov_override 覆盖场景初始 FOV
@export var use_base_fov_override: bool = false

@export var target: Node

# ---------------- 氮气/双喷镜头 ----------------
@export_group("Boost Camera")
@export var nitro_zoom_offset: Vector3 = Vector3(0, 0.3, 1.5)   ## 氮气时镜头额外偏移(本地坐标)
@export var nitro_zoom_duration: float = 2.2                     ## 氮气拉远持续秒数
@export var nitro_fov_boost: float = 8.0                         ## 氮气时 FOV 增量(度), 0=不变
@export var nitro_zoom_curve: Curve                              ## 氮气拉远强度随时间曲线
@export var double_zoom_scale: float = 0.4                       ## 双喷相对氮气的缩放倍率
@export var double_zoom_duration: float = 0.9                    ## 双喷拉远持续秒数
@export var double_fov_boost: float = 4.0                        ## 双喷时 FOV 增量(度)
@export var double_zoom_curve: Curve                             ## 双喷拉远强度随时间曲线
@export var mini_zoom_scale: float = 0.0                         ## 小喷相对氮气的缩放倍率(0=不拉)
@export var mini_zoom_duration: float = 0.5
@export var mini_fov_boost: float = 0.0
@export var mini_zoom_curve: Curve                               ## 小喷拉远强度随时间曲线
@export var zoom_lerp_speed: float = 3.5                         ## 镜头偏移和 FOV 平滑速度

# ---------------- 震动 ----------------
@export_group("Shake")
@export var shake_y_factor: float = 0.7                          ## 震动 Y 分量衰减(相对 X)
@export var shake_z_factor: float = 0.3                          ## 震动 Z 分量衰减(相对 X)

# ---------------- Y 轴稳定(平地抖动过滤) ----------------
@export_group("Y Stabilizer")
## 启用 Y 轴稳定器: 过滤平地上微小起伏造成的相机抖动
@export var y_stabilizer_enabled: bool = true
## Y 偏差死区(米): 相机 Y 与目标 Y 的差距小于此值时不跟随
## 大 = 稳相机但大起伏响应慢; 小 = 灵敏但还会抖. 坑洼路面建议 0.3+
@export var y_deadzone: float = 0.3
## Y 跟随速度乘数: 在 deadzone 外, Y 方向的 lerp 速度倍率(相对水平). 小=更慢追 Y
@export var y_follow_speed_mult: float = 0.2
## 强制跟随 Y 的速度阈值(m/s): Y 速度超过此值(起跳/落地) 立即完全跟随. 3.0 推荐
@export var y_force_follow_vy: float = 3.0

# ---------------- 前瞻焦点 (V2 新增) ----------------
@export_group("Look Ahead")
## 焦点向车头方向额外偏移多少米 (基于车头, 不基于速度, 所以漂移时不会甩飞)
## 0 = 镜头完全看车 (旧行为); 推荐 3~6 让玩家能看到前方一点路
@export_range(0.0, 15.0, 0.1) var lookahead_distance: float = 3.0
## 焦点向上偏移多少米 (避免镜头从上往下看车的问题)
@export_range(-3.0, 5.0, 0.1) var lookahead_height: float = 0.5

var _shake_timer: float = 0.0
var _shake_intensity: float = 0.0
var _shake_duration: float = 0.0

var _zoom_extra: Vector3 = Vector3.ZERO
var _zoom_target: Vector3 = Vector3.ZERO
var _zoom_left: float = 0.0          # 当前拉远剩余秒数
var _zoom_total: float = 0.0         # 当前拉远总时长(用于曲线归一化)
var _zoom_base_offset: Vector3 = Vector3.ZERO  # 基础拉远向量(用于曲线缩放)
var _zoom_base_fov: float = 0.0      # 基础拉远 FOV 增量
var _zoom_curve: Curve = null        # 当前拉远适用的曲线

var _base_fov: float = 75.0
var _fov_target_boost: float = 0.0
var _fov_current_boost: float = 0.0

# === 钩索镜头状态 ===
# 钩索系统通过 grapple_progress 信号驱动, 不走 boost zoom 通道, 而是单独叠加一层 FOV/roll
# 这样钩索可以和氮气/小喷的镜头反应**叠加**(玩家钩索时还能放氮气), 而不是互相覆盖
# _grapple_fov_extra : 钩索期间的 FOV 增量 (基于进度 + 曲线), 平滑过渡到 0
# _grapple_roll_target / current : 钩索期间的镜头横滚角度 (弧度), 平滑过渡
# _grapple_active_progress : 0~1, 钩索拉动进度 (从 GrappleHook 拿到), 0 = 没在钩索
var _grapple_fov_extra: float = 0.0
var _grapple_fov_target: float = 0.0
var _grapple_roll_current: float = 0.0
var _grapple_roll_target: float = 0.0
var _grapple_active_progress: float = 0.0
var _grapple_anchor_pos: Vector3 = Vector3.ZERO
var _grapple_pull_dir: Vector3 = Vector3.ZERO
# 钩索系统引用 (从 GrappleHook 那里读 cam_fov_boost / cam_roll_deg / 等)
var _grapple_hook_ref: Node = null

# Y 稳定: 维护一个平滑的"视觉 Y 目标", 同样做死区过滤
var _stable_look_y: float = 0.0
var _stable_look_y_inited: bool = false


func _ready() -> void:
	if use_base_fov_override:
		fov = base_fov_override
	_base_fov = fov
	# 自动连接车上的震动请求
	if target and target.get_parent() and target.get_parent().has_signal("camera_shake_requested"):
		target.get_parent().connect("camera_shake_requested", _on_shake)
		target.get_parent().connect("boost_triggered", _on_boost)
	# 连接钩索系统信号
	# GrappleHook 是 car 的子节点 (car.gd 在 _spawn_grapple_hook 里挂的)
	# 由于 GrappleHook 是 call_deferred 挂载的, 这里也用 call_deferred 等一帧再连
	call_deferred("_connect_grapple_signals")


func _connect_grapple_signals() -> void:
	if target == null or target.get_parent() == null:
		return
	var car_node: Node = target.get_parent()
	# GrappleHook 挂在 car 节点下, 名字是 "GrappleHook"
	var hook: Node = car_node.get_node_or_null("GrappleHook")
	if hook == null:
		# 还没挂上, 再等一帧
		await get_tree().process_frame
		hook = car_node.get_node_or_null("GrappleHook")
	if hook == null:
		print("[Camera3D] 找不到 GrappleHook 节点, 钩索镜头反应禁用")
		return
	_grapple_hook_ref = hook
	if hook.has_signal("grapple_progress"):
		hook.connect("grapple_progress", _on_grapple_progress)
	if hook.has_signal("grapple_state_changed"):
		hook.connect("grapple_state_changed", _on_grapple_state_changed)
	print("[Camera3D] 钩索镜头反应已连接")


func _physics_process(delta: float) -> void:
	if not target:
		return

	# 拉远计时
	if _zoom_left > 0.0:
		_zoom_left -= delta
		if _zoom_left <= 0.0:
			_zoom_left = 0.0
			_zoom_total = 0.0
			_zoom_target = Vector3.ZERO
			_fov_target_boost = 0.0
			_zoom_curve = null
		else:
			# 应用曲线: 进度 0..1 → 曲线值 → 缩放当前 zoom_target / fov_target
			var prog: float = 1.0 - clampf(_zoom_left / maxf(_zoom_total, 0.0001), 0.0, 1.0)
			var k: float = 1.0
			if _zoom_curve:
				k = _zoom_curve.sample(prog)
			_zoom_target = _zoom_base_offset * k
			_fov_target_boost = _zoom_base_fov * k

	# 镜头偏移 + FOV 平滑
	_zoom_extra = _zoom_extra.lerp(_zoom_target, delta * zoom_lerp_speed)
	_fov_current_boost = lerpf(_fov_current_boost, _fov_target_boost, delta * zoom_lerp_speed)

	# === 钩索 FOV/roll 平滑 (独立于 boost zoom 通道, 叠加在 boost FOV 之上) ===
	# 钩索期间 _grapple_fov_target 由 _on_grapple_progress 实时更新, 不在钩索时为 0
	# 用与 zoom_lerp_speed 一致的速度做平滑, 让进入/退出钩索都顺滑
	_grapple_fov_extra = lerpf(_grapple_fov_extra, _grapple_fov_target, delta * zoom_lerp_speed)
	_grapple_roll_current = lerpf(_grapple_roll_current, _grapple_roll_target, delta * zoom_lerp_speed)
	# 离开钩索后 target 已经清零, 但 extra 还在追, 自动衰减回 0

	fov = _base_fov + _fov_current_boost + _grapple_fov_extra

	var effective_offset: Vector3 = offset + _zoom_extra
	# === FreeFly 模式: 相机额外拉远 ===
	# 用户要求: 进入【自定义位置模式】时相机距离稍微拉远让玩家好操控
	# 实现: 检查 car 上的 _freefly_active 状态字段, 如果开了就把 effective_offset 乘上 freefly_camera_distance_mult
	# (这是相对车的本地坐标 offset, 乘大 → 相机离车更远)
	if target and target.get_parent() and "_freefly_active" in target.get_parent():
		if bool(target.get_parent().get("_freefly_active")):
			var mult: float = float(target.get_parent().get("freefly_camera_distance_mult"))
			if mult > 1.0:
				effective_offset *= mult
	var target_pos: Transform3D = target.global_transform.translated_local(effective_offset)

	if y_stabilizer_enabled:
		# 分离 XZ 和 Y: XZ 正常跟随, Y 做死区 + 速度感知过滤
		var target_origin: Vector3 = target_pos.origin
		var cur_origin: Vector3 = global_position
		# XZ: 正常 lerp
		var new_xz_t: float = lerp_speed * delta
		var new_pos: Vector3 = cur_origin
		new_pos.x = lerpf(cur_origin.x, target_origin.x, new_xz_t)
		new_pos.z = lerpf(cur_origin.z, target_origin.z, new_xz_t)
		# Y: 看车的 Y 速度, 平地微抖时极慢追(不抖), 大起伏时正常追
		var car_vy: float = 0.0
		if target.get_parent() and "linear_velocity" in target.get_parent():
			car_vy = absf(target.get_parent().linear_velocity.y)
		var dy: float = target_origin.y - cur_origin.y
		if absf(car_vy) > y_force_follow_vy:
			# 起跳/落地: 立即完全跟随
			new_pos.y = lerpf(cur_origin.y, target_origin.y, new_xz_t)
		elif absf(dy) > y_deadzone:
			# 超出死区: 慢速追赶
			new_pos.y = lerpf(cur_origin.y, target_origin.y, new_xz_t * y_follow_speed_mult)
		else:
			# 死区内: 极慢追赶 (而不是完全不动), 消除"一抖一停"
			# 数学: 在死区内仍然 lerp, 但用极小的 t (≤0.05), 视觉上感觉不到 Y 移动也不会抖
			new_pos.y = lerpf(cur_origin.y, target_origin.y, minf(new_xz_t * y_follow_speed_mult * 0.15, 0.05))
		global_position = new_pos
		# basis (旋转) 单独插值, 用 XZ 速度
		global_transform.basis = global_transform.basis.slerp(target_pos.basis, new_xz_t)
	else:
		global_transform = global_transform.interpolate_with(target_pos, lerp_speed * delta)

	# 最大滞后距离限制: 高速行驶时防止相机被甩开造成"拉远"
	if max_follow_lag > 0.0:
		var to_target: Vector3 = target_pos.origin - global_position
		var dist: float = to_target.length()
		if dist > max_follow_lag:
			# 把相机直接拉回 max_follow_lag 范围内
			global_position = target_pos.origin - to_target.normalized() * max_follow_lag

	look_at(_stable_look_target(), Vector3.UP)

	# === 钩索镜头横滚 (roll) ===
	# 钩索期间镜头朝拉力方向倾斜一点, 模拟"被甩动"的感觉 (类似 Apex 探路者)
	# roll 是绕 forward(-Z) 轴的旋转, 应用在 look_at 之后避免被覆盖
	if absf(_grapple_roll_current) > 0.001:
		# 用 rotate_object_local 绕本地 Z 轴 (即镜头看向的反方向, 也就是 -forward) 转
		rotate_object_local(Vector3(0, 0, 1), _grapple_roll_current)

	# 应用震动（在 look_at 之后叠加小偏移）
	if _shake_timer > 0.0:
		_shake_timer -= delta
		var falloff: float = clampf(_shake_timer / _shake_duration, 0.0, 1.0)
		var amp: float = _shake_intensity * falloff
		var shake_offset: Vector3 = Vector3(
			randf_range(-amp, amp),
			randf_range(-amp, amp) * shake_y_factor,
			randf_range(-amp, amp) * shake_z_factor
		)
		global_position += shake_offset


func _stable_look_target() -> Vector3:
	# 返回 look_at 目标点:
	#   · XZ: 车位置 + 车头方向 × lookahead_distance (前瞻, 让镜头不"完全看着车")
	#         车头方向 (不是速度方向) → 漂移时车头朝边上, 焦点也朝边上, 但镜头不会"甩飞"
	#         因为相机位置仍然由 target.global_transform.translated_local 算 (跟车走), 焦点偏移只是看哪
	#   · Y: 车 Y + lookahead_height + 平滑(防坑洼)
	var tp: Vector3 = target.global_position
	var lookahead_pos: Vector3 = tp
	if lookahead_distance > 0.0:
		var fwd: Vector3 = -target.global_transform.basis.z
		fwd.y = 0.0
		if fwd.length() > 0.001:
			lookahead_pos += fwd.normalized() * lookahead_distance
	lookahead_pos.y += lookahead_height

	if not y_stabilizer_enabled:
		return lookahead_pos

	# Y 平滑: 死区内"极慢追", 死区外"正常追"; 起跳/落地立即跟
	# 旧版"死区内完全不动"会造成"路面起伏在阈值附近一抖一停",
	# 改成"死区内仍然追但速度极慢"消除这个跳变
	if not _stable_look_y_inited:
		_stable_look_y = lookahead_pos.y
		_stable_look_y_inited = true
	var car_vy: float = 0.0
	if target.get_parent() and "linear_velocity" in target.get_parent():
		car_vy = absf(target.get_parent().linear_velocity.y)
	var dy: float = lookahead_pos.y - _stable_look_y
	if absf(car_vy) > y_force_follow_vy:
		# 起跳/落地: 立即跟随
		_stable_look_y = lookahead_pos.y
	elif absf(dy) > y_deadzone:
		# 超出死区: 正常追 (以前是 0.25, 还是用 0.25)
		_stable_look_y = lerpf(_stable_look_y, lookahead_pos.y, 0.25)
	else:
		# 死区内: 极慢追 (而非完全不动). 0.02 = 50 帧才追一半, 视觉上感觉不到, 也不会抖
		_stable_look_y = lerpf(_stable_look_y, lookahead_pos.y, 0.02)
	return Vector3(lookahead_pos.x, _stable_look_y, lookahead_pos.z)


func _on_shake(intensity: float, duration: float) -> void:
	# 取较大值，避免叠加后震到吐
	if intensity > _shake_intensity * (_shake_timer / maxf(_shake_duration, 0.001)):
		_shake_intensity = intensity
		_shake_duration = duration
		_shake_timer = duration


func _on_boost(type_name: String) -> void:
	match type_name:
		"nitro":
			_zoom_base_offset = nitro_zoom_offset
			_zoom_base_fov = nitro_fov_boost
			_zoom_total = nitro_zoom_duration
			_zoom_left = nitro_zoom_duration
			_zoom_curve = nitro_zoom_curve
			_zoom_target = _zoom_base_offset
			_fov_target_boost = _zoom_base_fov
		"double":
			_zoom_base_offset = nitro_zoom_offset * double_zoom_scale
			_zoom_base_fov = double_fov_boost
			_zoom_total = double_zoom_duration
			_zoom_left = double_zoom_duration
			_zoom_curve = double_zoom_curve
			_zoom_target = _zoom_base_offset
			_fov_target_boost = _zoom_base_fov
		"mini", "songqian_back":
			# 小喷 + 三喷的"后退喷"共用小喷镜头反应
			if mini_zoom_scale > 0.0 or mini_fov_boost > 0.0:
				_zoom_base_offset = nitro_zoom_offset * mini_zoom_scale
				_zoom_base_fov = mini_fov_boost
				_zoom_total = mini_zoom_duration
				_zoom_left = mini_zoom_duration
				_zoom_curve = mini_zoom_curve
				_zoom_target = _zoom_base_offset
				_fov_target_boost = _zoom_base_fov


# ============================================================
#  钩索镜头反应
# ============================================================
# GrappleHook 每物理帧 (在 ATTACHED 时) emit grapple_progress(progress, anchor_pos, pull_dir)
# 我们在这里:
#   1) FOV 增量: 按 progress 采样 cam_fov_curve, 得到当前应有的 FOV 增量目标值, 再走 zoom_lerp_speed 平滑
#   2) Roll: 计算"车头方向"和"拉力方向"的叉乘符号, 决定 roll 是正/负 (镜头往拉力方向倾斜)
#            roll 大小 = cam_roll_deg × cam_roll_curve.sample(progress) × roll_sign
# 钩索期间不影响 boost zoom 通道, 所以氮气 + 钩索可以同时生效, FOV 增量加在一起
func _on_grapple_progress(progress: float, anchor_pos: Vector3, pull_dir: Vector3) -> void:
	if _grapple_hook_ref == null:
		return
	_grapple_active_progress = progress
	_grapple_anchor_pos = anchor_pos
	_grapple_pull_dir = pull_dir
	# FOV 目标 = peak × 曲线在 progress 处的采样
	var fov_peak: float = float(_grapple_hook_ref.get("cam_fov_boost"))
	var fov_curve: Curve = _grapple_hook_ref.get("cam_fov_curve") as Curve
	var fov_k: float = 1.0
	if fov_curve != null and fov_curve.point_count > 0:
		fov_k = fov_curve.sample(clampf(progress, 0.0, 1.0))
	_grapple_fov_target = fov_peak * fov_k

	# Roll 目标 = peak_deg × 曲线 × 方向符号
	# 方向符号: 用 (车头.z × pull_dir.x - 车头.x × pull_dir.z) 的水平叉乘, > 0 表示拉力在车头左侧
	var roll_peak_deg: float = float(_grapple_hook_ref.get("cam_roll_deg"))
	var roll_curve: Curve = _grapple_hook_ref.get("cam_roll_curve") as Curve
	var roll_k: float = 1.0
	if roll_curve != null and roll_curve.point_count > 0:
		roll_k = roll_curve.sample(clampf(progress, 0.0, 1.0))
	# 车头方向 (水平投影)
	var fwd: Vector3 = -target.global_transform.basis.z
	fwd.y = 0.0
	# 用 car_mesh 的车头更准 (因为 target 是 CarMesh 但 basis 在跟车 mesh 走)
	if fwd.length() > 0.001:
		fwd = fwd.normalized()
	else:
		fwd = Vector3.FORWARD
	var pd: Vector3 = pull_dir
	pd.y = 0.0
	if pd.length() > 0.001:
		pd = pd.normalized()
	# 水平叉乘的 Y 分量 = 车头.x × pull.z - 车头.z × pull.x
	# > 0 → pull_dir 在车头左侧 → roll 正向(镜头左倾, 视觉上拉力在左所以镜头朝左滚)
	var cross_y: float = fwd.x * pd.z - fwd.z * pd.x
	var roll_sign: float = signf(cross_y)
	if roll_sign == 0.0:
		roll_sign = 1.0
	_grapple_roll_target = deg_to_rad(roll_peak_deg) * roll_k * roll_sign


func _on_grapple_state_changed(state_str: String, _anchor_pos: Vector3) -> void:
	# 离开钩索状态: 把 FOV/roll 目标都拉回 0, 让 _physics_process 的平滑自动衰减
	if state_str != "ATTACHED":
		_grapple_fov_target = 0.0
		_grapple_roll_target = 0.0
		_grapple_active_progress = 0.0
