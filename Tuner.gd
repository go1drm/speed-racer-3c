extends CanvasLayer
## 调参 UI —— TAB 切换 · 即时生效 · 保存/加载 user://tune.cfg

@export var car_path: NodePath
var car: Node = null
var _rows: Dictionary = {}      # prop -> {slider, spin}
var _defaults: Dictionary = {}  # prop -> default value
var _panel: PanelContainer

# 参数定义: [属性, 显示名, min, max, step] ; 以 "__group" 开头的是分组标题
const PARAMS := [
	["__group", "[b]基础移动[/b]"],
	["max_speed",                 "最高速 (m/s)",       10.0, 150.0, 1.0],
	["acceleration",              "加速度",             10.0, 200.0, 1.0],
	["brake_force",               "刹车力",             10.0, 200.0, 1.0],
	["steering_deg",              "前轮转角(度)",       5.0,  60.0,  0.5],
	["turn_speed",                "车头响应速度",       0.5,  8.0,   0.1],
	["turn_speed_high_speed_mult","高速转向衰减倍率",   0.1,  1.0,   0.05],
	["high_speed_threshold",      "高速衰减阈值(m/s)",  5.0,  80.0,  1.0],
	["ground_friction",           "地面侧向摩擦",       0.5,  15.0,  0.1],
	["natural_decel",             "松油门自然减速",     0.0,  10.0,  0.1],

	["__group", "[b]漂移[/b]"],
	["drift_friction",            "漂移时侧向摩擦",     0.0,  5.0,   0.05],
	["drift_steer_mult",          "漂移转向增幅",       1.0,  3.5,   0.05],
	["drift_min_speed",           "最低入漂车速",       0.0,  30.0,  0.5],
	["drift_body_tilt",           "漂移车身侧倾(度)",   0.0,  60.0,  1.0],
	["drift_yaw_offset_tuck",     "甩尾yaw偏移(度)",    0.0,  60.0,  1.0],
	["drift_yaw_offset_side",     "侧身yaw偏移(度)",    0.0,  80.0,  1.0],
	["side_drift_threshold",      "侧身触发侧速阈值",   0.0,  8.0,   0.1],
	["drift_min_angle_to_boost",  "退漂小喷最低累积角", 0.0,  120.0, 1.0],
	["drift_max_duration",        "漂移最长持续(秒)",   1.0,  15.0,  0.5],
	["drift_break_speed_ratio",   "低速断漂阈值倍率",   0.0,  1.0,   0.05],
	["drift_accel_mult",          "漂移加速倍率",       0.0,  1.5,   0.05],
	["drift_passive_decel",       "漂移被动减速力",     0.0,  30.0,  0.5],
	["drift_counter_steer_break_time", "反打断漂秒数",  0.05, 1.5,   0.05],

	["__group", "[b]集气公式[/b]"],
	["charge_nitro_full",         "一格氮气=多少集气",  20.0, 300.0, 5.0],
	["charge_per_lateral_m",      "侧滑米数权重",       0.0,  10.0,  0.1],
	["charge_yaw_rate_weight",    "车头角速度权重",     0.0,  10.0,  0.1],
	["charge_min_per_sec",        "兜底集气/秒",        0.0,  60.0,  1.0],
	["crash_charge_penalty",      "撞墙保留比例",       0.0,  1.0,   0.05],
	["max_nitro_stock",           "氮气槽上限",         1,    5,     1],

	["__group", "[b]喷射[/b]"],
	["mini_boost_cost",           "小喷消耗集气",       5.0,  100.0, 1.0],
	["mini_boost_power",          "小喷推进力",         5.0,  100.0, 1.0],
	["mini_boost_time",           "小喷持续(秒)",       0.1,  3.0,   0.05],
	["double_boost_window",       "双喷窗口(秒)",       0.05, 2.0,   0.05],
	["double_boost_power",        "双喷推进力",         10.0, 150.0, 1.0],
	["double_boost_time",         "双喷持续(秒)",       0.1,  3.0,   0.05],
	["nitro_power",               "氮气推进力",         20.0, 200.0, 1.0],
	["nitro_time",                "氮气持续(秒)",       0.5,  6.0,   0.1],
	["boost_speed_multiplier",    "喷射最高速倍率",     1.0,  3.0,   0.05],

	["__group", "[b]视觉[/b]"],
	["body_tilt",                 "过弯侧倾敏感度(越大越稳)",  5.0,  120.0, 1.0],
	["body_tilt_max_deg",         "过弯最大侧倾角(度)",        0.0,  45.0,  0.5],
	["head_yaw_deg",              "车头左右拧头幅度(度)",      0.0,  20.0,  0.5],
]

# 漂移特效相关参数（独立放, 因为目标对象是 DriftFX 不是 car）
const FX_PARAMS := [
	["permanent_marks",           "胎印永久(0=会淡出 1=永久)", 0, 1, 1],
	["tire_mark_only_rear",       "只有后轮留胎印(0=四轮 1=仅后轮)", 0, 1, 1],
	["tire_mark_lifetime",        "胎印淡出时长(秒)",          1.0,  30.0, 0.5],
	["tire_mark_interval",        "胎印放置间隔(秒)",          0.01, 0.2,  0.005],
	["glow_energy",               "轮胎发光强度",              0.0,  20.0, 0.5],
]

const SAVE_PATH := "user://tune.cfg"


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
	# 读取当前值并保存默认值 + 同步 UI
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

	# 同样加载 FX 参数默认值
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

	_load_from_file()


func _get_drift_fx() -> Node:
	if not car:
		return null
	for c in car.get_children():
		if c.name == "DriftFX" or c.get_script() and str(c.get_script().resource_path).ends_with("DriftFX.gd"):
			return c
	return null


func _apply_fx(prop: String, v: float) -> void:
	var fx = _get_drift_fx()
	if not fx:
		return
	if not prop in fx:
		return
	var current = fx.get(prop)
	if typeof(current) == TYPE_INT:
		fx.set(prop, int(round(v)))
	elif typeof(current) == TYPE_BOOL:
		fx.set(prop, v >= 0.5)
	else:
		fx.set(prop, v)


func _on_clear_marks() -> void:
	var fx = _get_drift_fx()
	if fx and fx.has_method("clear_all_marks"):
		fx.clear_all_marks()
		print("[Tuner] 已清除所有胎印")


# ============================================================
#  UI 构建
# ============================================================
func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_panel.offset_left = 10
	_panel.offset_top = 10
	_panel.offset_right = 430
	_panel.offset_bottom = -10
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.1, 0.88)
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

	# 标题
	var title := Label.new()
	title.text = "🔧 调参面板  (TAB 切换)"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	root.add_child(title)

	# 工具栏
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	root.add_child(tools)

	var btn_reset := Button.new()
	btn_reset.text = "重置默认"
	btn_reset.pressed.connect(_on_reset)
	tools.add_child(btn_reset)

	var btn_save := Button.new()
	btn_save.text = "保存"
	btn_save.pressed.connect(_on_save)
	tools.add_child(btn_save)

	var btn_load := Button.new()
	btn_load.text = "加载"
	btn_load.pressed.connect(_on_load)
	tools.add_child(btn_load)

	var hint := Label.new()
	hint.text = "  修改即时生效"
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	hint.add_theme_font_size_override("font_size", 12)
	tools.add_child(hint)

	# 滚动容器
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(400, 500)
	root.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)

	# 构建每一行
	for p in PARAMS:
		if p[0] == "__group":
			_add_group_header(list, p[1])
			continue
		_add_param_row(list, p[0], p[1], p[2], p[3], p[4])

	# 漂移特效参数（目标是 DriftFX, 用 _apply_fx 单独处理）
	_add_group_header(list, "[b]漂移特效[/b]")
	for p in FX_PARAMS:
		_add_param_row(list, p[0], p[1], p[2], p[3], p[4], true)


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


func _add_param_row(parent: Node, prop: String, label_text: String, vmin: float, vmax: float, step: float, is_fx: bool = false) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.custom_minimum_size = Vector2(180, 0)
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	row.add_child(name_lbl)

	var slider := HSlider.new()
	slider.min_value = vmin
	slider.max_value = vmax
	slider.step = step
	slider.custom_minimum_size = Vector2(130, 20)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var spin := SpinBox.new()
	spin.min_value = vmin
	spin.max_value = vmax
	spin.step = step
	spin.custom_minimum_size = Vector2(70, 0)
	row.add_child(spin)

	# 双向绑定
	slider.value_changed.connect(func(v: float) -> void:
		spin.set_value_no_signal(v)
		if is_fx:
			_apply_fx(prop, v)
		else:
			_apply(prop, v)
	)
	spin.value_changed.connect(func(v: float) -> void:
		slider.set_value_no_signal(v)
		if is_fx:
			_apply_fx(prop, v)
		else:
			_apply(prop, v)
	)

	_rows[prop] = {"slider": slider, "spin": spin, "is_fx": is_fx}


# ============================================================
#  应用到 car
# ============================================================
func _apply(prop: String, v: float) -> void:
	if not car:
		return
	if not prop in car:
		return
	# int 属性要转一下
	var current = car.get(prop)
	if typeof(current) == TYPE_INT:
		car.set(prop, int(round(v)))
	else:
		car.set(prop, v)


# ============================================================
#  按钮动作
# ============================================================
func _on_reset() -> void:
	for prop in _defaults.keys():
		var v = _defaults[prop]
		_apply(prop, float(v))
		if _rows.has(prop):
			_rows[prop].slider.set_value_no_signal(float(v))
			_rows[prop].spin.set_value_no_signal(float(v))


func _on_save() -> void:
	var cfg := ConfigFile.new()
	for prop in _rows.keys():
		if car and prop in car:
			cfg.set_value("tune", prop, car.get(prop))
	cfg.save(SAVE_PATH)
	print("[Tuner] 已保存到 ", SAVE_PATH)


func _on_load() -> void:
	_load_from_file()


func _load_from_file() -> void:
	var cfg := ConfigFile.new()
	var err := cfg.load(SAVE_PATH)
	if err != OK:
		return
	for prop in cfg.get_section_keys("tune"):
		var v = cfg.get_value("tune", prop)
		_apply(prop, float(v))
		if _rows.has(prop):
			_rows[prop].slider.set_value_no_signal(float(v))
			_rows[prop].spin.set_value_no_signal(float(v))
	print("[Tuner] 已从 ", SAVE_PATH, " 加载")
