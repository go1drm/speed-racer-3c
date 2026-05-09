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
# curve_prop_or_empty: 如果非空, 表示该参数(如喷射时长)对应有一条曲线参数(如 mini_boost_curve)可调
const PARAMS := [
	["__group", "[b]基础移动[/b]"],
	["max_speed",                 "最高速 (m/s)",       10.0, 150.0, 1.0,
		"车辆能达到的最高速度(米/秒)。喷射时会临时突破此上限。", ""],
	["acceleration",              "加速度",             10.0, 200.0, 1.0,
		"踩油门时施加在车辆上的推进力。越大起步越猛, 但容易甩尾。", ""],
	["brake_force",               "刹车力",             10.0, 200.0, 1.0,
		"踩刹车时施加的反向力, 越大越急停。", ""],
	["steering_deg",              "前轮转角(度)",       5.0,  60.0,  0.5,
		"前轮视觉转角, 同时也是车头朝向的转向幅度上限。", ""],
	["turn_speed",                "车头响应速度",       0.5,  8.0,   0.1,
		"车头朝向 lerp 到目标方向的速度, 越大手感越灵敏(也越甩)。", ""],
	["turn_speed_high_speed_mult","高速转向衰减倍率",   0.1,  1.0,   0.05,
		"高速时转向速度会衰减到这个倍率, 防止高速过弯打滑甩尾。", ""],
	["high_speed_threshold",      "高速衰减阈值(m/s)",  5.0,  80.0,  1.0,
		"超过此速度后开始应用'高速转向衰减倍率'。", ""],
	["ground_friction",           "地面侧向抗滑摩擦",   0.5,  15.0,  0.1,
		"正常行驶时轮胎侧向抗侧滑力。沿'车身侧向速度分量的反方向'施加, 越大越难甩尾。", ""],
	["natural_decel",             "滚动摩擦(松油门)",   0.0,  10.0,  0.1,
		"松开油门/刹车时的滚动摩擦, 沿'车头前后方向速度分量的反方向'施加, 不踩油门时车会自然减速。", ""],

	["__group", "[b]漂移[/b]"],
	["drift_friction",            "漂移侧向抗滑摩擦",   0.0,  5.0,   0.05,
		"漂移时的侧向抗侧滑力, 远小于正常值让车能甩起来。沿'车身侧向速度反向'施加。", ""],
	["drift_steer_mult",          "漂移转向增幅",       1.0,  3.5,   0.05,
		"漂移时车头响应速度的倍率, 让漂移可以更快拉角度。", ""],
	["drift_min_speed",           "最低入漂车速",       0.0,  30.0,  0.5,
		"低于此速度无法触发漂移。", ""],
	["drift_body_tilt",           "漂移车身侧倾(度)",   0.0,  60.0,  1.0,
		"漂移时车身往内侧倾斜的最大角度, 仅视觉效果。", ""],
	["drift_yaw_offset_tuck",     "甩尾yaw偏移(度)",    0.0,  60.0,  1.0,
		"甩尾型漂移车头相对运动方向的偏转角度。", ""],
	["drift_yaw_offset_side",     "侧身yaw偏移(度)",    0.0,  80.0,  1.0,
		"侧身型漂移(反打入漂)车头相对运动方向的偏转, 比甩尾更夸张。", ""],
	["side_drift_threshold",      "侧身触发侧速阈值",   0.0,  8.0,   0.1,
		"反打入漂时, 横向速度超过此值则进入侧身漂(否则甩尾漂)。", ""],
	["drift_min_angle_to_boost",  "小喷资格累积角(度)",   0.0,  120.0, 1.0,
		"漂移期间车头转过此累计角度后, 退漂可触发小喷。", ""],
	["drift_min_angle_to_double", "(已废弃)双喷累积角(度)",   0.0,  180.0, 1.0,
		"已废弃: 现在双喷靠'小喷期间按住 Q 蓄能'触发。", ""],
	["drift_max_duration",        "漂移最长持续(秒, 0=不限)",   0.0,  30.0,  0.5,
		"漂移最长持续秒数, 超时强制断漂。设为 0 = 不限时(只要速度足够就一直漂)。", ""],
	["drift_break_speed_ratio",   "低速断漂阈值倍率",   0.0,  1.0,   0.05,
		"漂移时速度低于(最低入漂车速 × 此值)会触发低速宽限期。", ""],
	["drift_low_speed_grace_time","低速断漂宽限秒数",   0.0,  2.0,   0.05,
		"触发低速后给玩家多少秒'挽救'机会, 期间猛打方向继续漂可避免断漂。0=立即断漂(旧行为)。", ""],
	["drift_grace_save_angle",    "宽限期挽救所需角度", 0.0,  60.0,  0.5,
		"宽限期内车头再转过此角度即视为挽救成功, 取消断漂。", ""],
	["drift_accel_mult",          "漂移加速倍率",       0.0,  1.5,   0.05,
		"漂移时油门加速效果的倍率, <1 表示漂移会让加速变慢。", ""],
	["drift_passive_decel",       "(旧)漂移前后向阻力", 0.0,  30.0,  0.5,
		"旧参数, 现已与'漂移惯性阻力'合并(取较大值生效)。建议用下方新参数。", ""],
	["drift_inertial_decel",      "漂移惯性阻力(能耗)", 0.0,  30.0,  0.5,
		"漂移时沿惯性方向反向施加的总阻力, 等价于'总能耗摩擦'。作用在车身前后向速度反向, 让漂移明显减速。", ""],
	["drift_max_speed",           "漂移最高速度(m/s)",  0.0,  100.0, 0.5,
		"漂移时速度软上限。超过此值会施加反向刹车力。0 = 不限速(允许漂移期间继续加速到正常最高速)。", ""],
	["drift_speed_brake_strength","漂移超速刹车强度",   0.0,  60.0,  0.5,
		"漂移超过最高速度时反向刹车力的强度。越大刹得越急, 让漂移更明显减速。", ""],
	["drift_counter_steer_break_time", "反打断漂秒数",  0.05, 1.5,   0.05,
		"漂移中持续反向打方向超过此时长会自动退漂。", ""],

	["__group", "[b]集气公式[/b]"],
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

	["__group", "[b]喷射[/b]"],
	["mini_boost_cost",           "小喷消耗(已废弃)",   5.0,  100.0, 1.0,
		"已废弃, 保留兼容。", ""],
	["mini_boost_power",          "小喷推进力",         5.0,  100.0, 1.0,
		"小喷的基础推进力, 实时力 = 此值 × 力度曲线在当前进度的采样。", "mini_boost_curve"],
	["mini_boost_time",           "小喷持续(秒)",       0.1,  3.0,   0.05,
		"小喷持续时长。", ""],
	["double_boost_window",       "双喷窗口(秒)",       0.05, 2.0,   0.05,
		"(已废弃: 旧版退漂双喷窗口) 现已被双喷蓄能机制取代。", ""],
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
	["boost_speed_multiplier",    "喷射最高速倍率",     1.0,  3.0,   0.05,
		"喷射期间车辆最高速被临时放大的倍率。", ""],

	["__group", "[b]视觉[/b]"],
	["body_tilt",                 "过弯侧倾敏感度",     5.0,  120.0, 1.0,
		"数值越大, 过弯侧倾感越迟钝(可以理解为'稳'); 越小越夸张。", ""],
	["body_tilt_max_deg",         "过弯最大侧倾角(度)", 0.0,  45.0,  0.5,
		"过弯时车身最大侧倾角, 防止高速侧翻。", ""],
	["head_yaw_deg",              "车头左右拧头幅度(度)", 0.0,  20.0,  0.5,
		"非漂移时按方向键车头会做轻微 yaw 摆动, 这是幅度。", ""],

	["__group", "[b]地面物理(防弹跳)[/b]"],
	["ground_stick_enabled",      "落地吸附开关",       0,    1,     1,
		"1=接触地面时抑制微弹; 0=保留原始物理弹跳。", ""],
	["ground_stick_vy_threshold", "上弹速度归零阈值",   0.0,  20.0,  0.1,
		"接触地面时, 若 Y 速度向上小于此值则直接归零, 消除橡皮球效应。", ""],
	["ground_stick_down_clamp",   "下坠速度上限",       0.0,  50.0,  0.5,
		"0=不限; >0 时限制车辆下坠速度的绝对值。", ""],
	["slope_as_wall_enabled",     "斜面视为墙",         0,    1,     1,
		"1=陡斜面会被当作墙壁吸收速度+反推; 0=允许爬坡。", ""],
	["slope_wall_angle_deg",      "斜面墙阈值(度)",     20.0, 85.0,  1.0,
		"法线与竖直方向夹角 ≥ 此值视为墙壁。值越小越严格(更多缓坡都视为墙)。", ""],
	["slope_wall_bounce_absorb",  "撞斜面吸收速度比例", 0.0,  1.0,   0.05,
		"撞斜面时沿法线速度被吸收的比例, 1=完全停下。", ""],
	["slope_wall_push_back",      "撞斜面反推速度",     0.0,  20.0,  0.5,
		"撞墙后沿法线方向额外推开的速度, 防止卡墙。", ""],
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
	["lerp_speed",                "镜头跟随速度",              0.5,  15.0, 0.1,
		"相机插值速度, 越大越紧贴车辆。", ""],
	["nitro_zoom_duration",       "氮气拉远持续(秒)",          0.0,  6.0,  0.1,
		"氮气期间镜头拉远效果持续时间。", ""],
	["nitro_fov_boost",           "氮气FOV增量(度)",           0.0,  30.0, 0.5,
		"氮气期间 FOV 临时增加多少度, 增强速度感。", "nitro_zoom_curve"],
	["double_zoom_scale",         "双喷拉远倍率",              0.0,  2.0,  0.05,
		"双喷拉远偏移 = 氮气偏移 × 此值。", "double_zoom_curve"],
	["double_zoom_duration",      "双喷拉远持续(秒)",          0.0,  3.0,  0.05,
		"双喷期间镜头拉远持续秒数。", ""],
	["double_fov_boost",          "双喷FOV增量(度)",           0.0,  20.0, 0.5,
		"双喷期间 FOV 增加量。", ""],
	["mini_zoom_scale",           "小喷拉远倍率(0=不拉)",      0.0,  1.5,  0.05,
		"小喷拉远偏移 = 氮气偏移 × 此值, 0 表示小喷不拉远。", "mini_zoom_curve"],
	["mini_zoom_duration",        "小喷拉远持续(秒)",          0.0,  2.0,  0.05,
		"小喷期间镜头拉远持续秒数。", ""],
	["mini_fov_boost",            "小喷FOV增量(度)",           0.0,  15.0, 0.5,
		"小喷期间 FOV 增加量。", ""],
	["zoom_lerp_speed",           "拉远/FOV平滑速度",          0.5,  15.0, 0.1,
		"镜头偏移和 FOV 变化的平滑速度, 越大变化越突兀。", ""],
	["shake_y_factor",            "震动 Y 衰减系数",            0.0,  2.0,  0.05,
		"垂直方向震动相对水平的衰减比例。", ""],
	["shake_z_factor",            "震动 Z 衰减系数",            0.0,  2.0,  0.05,
		"前后方向震动相对水平的衰减比例。", ""],
]

# 曲线属性默认范围(都是 0..1 → 0..1+)
const CURVE_PROPS := {
	"mini_boost_curve":   {"target": "car"},
	"double_boost_curve": {"target": "car"},
	"nitro_boost_curve":  {"target": "car"},
	"mini_zoom_curve":    {"target": "cam"},
	"double_zoom_curve":  {"target": "cam"},
	"nitro_zoom_curve":   {"target": "cam"},
}

const SAVE_PATH := "user://tune.cfg"

# ============================================================
#  生命周期
# ============================================================
func _ready() -> void:
	_build_ui()
	visible = true
	_panel.visible = true
	call_deferred("_bind_car")


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
		if not prop in car:
			continue
		var v = car.get(prop)
		_defaults[prop] = v
		if _rows.has(prop):
			_rows[prop].slider.set_value_no_signal(float(v))
			_rows[prop].spin.set_value_no_signal(float(v))

	# FX 参数
	var fx = _get_drift_fx()
	if fx:
		for p in FX_PARAMS:
			var prop: String = p[0]
			if not prop in fx:
				continue
			var v = fx.get(prop)
			_defaults[prop] = v
			if _rows.has(prop):
				_rows[prop].slider.set_value_no_signal(float(v))
				_rows[prop].spin.set_value_no_signal(float(v))

	# CAM 参数
	var cam = _get_camera()
	if cam:
		for p in CAM_PARAMS:
			var prop: String = p[0]
			if not prop in cam:
				continue
			var v = cam.get(prop)
			_defaults[prop] = v
			if _rows.has(prop):
				_rows[prop].slider.set_value_no_signal(float(v))
				_rows[prop].spin.set_value_no_signal(float(v))

	# 加载所有曲线: 用预设 LINEAR_FULL 兜底
	for cprop in CURVE_PROPS.keys():
		var c: Curve = _build_preset_curve("LINEAR_FULL")
		_curves[cprop] = c
		_apply_curve_to_target(cprop, c)

	_load_from_file()


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
func _apply_to(target: Object, prop: String, v: float) -> void:
	if not target or not prop in target:
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
		_:
			_apply_to(car, prop, v)


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
	_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_panel.offset_left = 10
	_panel.offset_top = 10
	_panel.offset_right = 470
	_panel.offset_bottom = -10
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	_panel.add_child(root)

	var title := Label.new()
	title.text = "🔧 调参面板  (TAB 切换 · 点击参数名改范围 · 🎨 编辑曲线)"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(title)

	# 工具栏
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	root.add_child(tools)
	var btn_reset := Button.new(); btn_reset.text = "重置默认"; btn_reset.pressed.connect(_on_reset); tools.add_child(btn_reset)
	var btn_save := Button.new(); btn_save.text = "保存"; btn_save.pressed.connect(_on_save); tools.add_child(btn_save)
	var btn_load := Button.new(); btn_load.text = "加载"; btn_load.pressed.connect(_on_load); tools.add_child(btn_load)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(440, 540)
	root.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)

	for p in PARAMS:
		if p[0] == "__group":
			_add_group_header(list, p[1])
			continue
		_add_param_row(list, p, "car")

	_add_group_header(list, "[b]漂移特效[/b]")
	for p in FX_PARAMS:
		_add_param_row(list, p, "fx")

	_add_group_header(list, "[b]镜头(氮气/双喷拉远)[/b]")
	for p in CAM_PARAMS:
		_add_param_row(list, p, "cam")


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


# 单行参数: [prop, label, vmin, vmax, step, tooltip, curve_prop]
func _add_param_row(parent: Node, p: Array, kind: String) -> void:
	var prop: String = p[0]
	var label_text: String = p[1]
	var vmin: float = float(p[2])
	var vmax: float = float(p[3])
	var step: float = float(p[4])
	var tooltip: String = p[5] if p.size() > 5 else ""
	var curve_prop: String = p[6] if p.size() > 6 else ""

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	# 参数名(可点击修改范围)
	var name_btn := Button.new()
	name_btn.text = label_text
	name_btn.flat = true
	name_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_btn.custom_minimum_size = Vector2(170, 0)
	name_btn.add_theme_font_size_override("font_size", 12)
	name_btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	name_btn.tooltip_text = tooltip
	name_btn.pressed.connect(func(): _open_range_editor(prop))
	row.add_child(name_btn)

	var slider := HSlider.new()
	slider.min_value = vmin
	slider.max_value = vmax
	slider.step = step
	slider.custom_minimum_size = Vector2(120, 20)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.tooltip_text = tooltip
	row.add_child(slider)

	var spin := SpinBox.new()
	spin.min_value = vmin
	spin.max_value = vmax
	spin.step = step
	spin.custom_minimum_size = Vector2(70, 0)
	spin.tooltip_text = tooltip
	row.add_child(spin)

	# 曲线编辑按钮(仅对绑定 curve_prop 的参数显示)
	var curve_btn: Button = null
	if curve_prop != "":
		curve_btn = Button.new()
		curve_btn.text = "🎨"
		curve_btn.tooltip_text = "编辑曲线: " + curve_prop
		curve_btn.custom_minimum_size = Vector2(28, 0)
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
	for prop in _rows.keys():
		var row = _rows[prop]
		var kind: String = row.get("kind", "car")
		var src: Object = null
		match kind:
			"fx": src = fx
			"cam": src = cam
			_: src = car
		if src and prop in src:
			cfg.set_value("tune", prop, src.get(prop))
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
	cfg.save(SAVE_PATH)
	print("[Tuner] 已保存到 ", SAVE_PATH)


func _on_load() -> void:
	_load_from_file()


func _load_from_file() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err != OK:
		return
	# 范围
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
	# 数值
	if cfg.has_section("tune"):
		for prop in cfg.get_section_keys("tune"):
			var v = cfg.get_value("tune", prop)
			var kind: String = _rows[prop].get("kind", "car") if _rows.has(prop) else "car"
			_dispatch_apply(kind, prop, float(v))
			if _rows.has(prop):
				_rows[prop].slider.set_value_no_signal(float(v))
				_rows[prop].spin.set_value_no_signal(float(v))
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
	print("[Tuner] 已从 ", SAVE_PATH, " 加载")
