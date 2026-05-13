extends CanvasLayer
## ============================================================
##  赛车 HUD —— 车速 / 集气槽 / 双氮气格 / 漂移&喷射提示 / 撞墙提示
## ============================================================

@export var car_path: NodePath

@onready var speed_label: Label = $Root/SpeedBox/SpeedLabel
@onready var charge_bar: ProgressBar = $Root/ChargeBox/ChargeBar
@onready var charge_label: Label = $Root/ChargeBox/ChargeLabel
@onready var nitro_slot_1: ColorRect = $Root/ChargeBox/NitroRow/Slot1
@onready var nitro_slot_2: ColorRect = $Root/ChargeBox/NitroRow/Slot2
@onready var boost_lamp: PanelContainer = $Root/ChargeBox/NitroRow/BoostLamp
@onready var boost_lamp_core: PanelContainer = $Root/ChargeBox/NitroRow/BoostLamp/LampCore
@onready var boost_lamp_icon: TextureRect = $Root/ChargeBox/NitroRow/BoostLamp/LampCore/FlameIcon
@onready var boost_lamp_label: Label = $Root/ChargeBox/NitroRow/BoostLamp/LampCore/BoostLampLabel
@onready var drift_label: Label = $Root/DriftLabel
@onready var boost_label: Label = $Root/BoostLabel
@onready var crash_label: Label = $Root/CrashLabel

# ---------------- 弹字保留时长 ----------------
@export_group("Popup Timing")
## 弹字完整保留秒数(满 alpha 不衰减)
@export var popup_hold_time: float = 1.4
## 弹字渐隐秒数
@export var popup_fade_time: float = 0.6
## 漂移提示完整保留秒数
@export var drift_hold_time: float = 1.0
## 漂移提示渐隐秒数
@export var drift_fade_time: float = 0.4
## 撞墙提示完整保留秒数
@export var crash_hold_time: float = 0.8
## 撞墙提示渐隐秒数
@export var crash_fade_time: float = 0.5

# ---------------- 颜色 ----------------
const COLOR_EMPTY := Color(0.22, 0.22, 0.28, 0.85)
const COLOR_NITRO := Color(0.25, 0.9, 1.0, 1.0)
const LAMP_OFF_COLOR := Color(0.35, 0.35, 0.4, 1.0)         # 灭灯: 灰
const LAMP_MINI_COLOR := Color(0.3, 0.7, 1.0, 1.0)          # 小喷可用: 蓝
const LAMP_DOUBLE_COLOR := Color(0.45, 0.85, 1.0, 1.0)      # 双喷可用: 浅蓝(与小喷区分)
# 小喷/双喷弹字色 (蓝)
const W_COLOR_BLUE := Color(0.4, 0.8, 1.0, 1.0)
# 氮气三档颜色 (0=蓝 / 1=金 / 2=红)
const NITRO_COLOR_BLUE := Color(0.25, 0.85, 1.0, 1.0)
const NITRO_COLOR_GOLD := Color(1.0, 0.85, 0.25, 1.0)
const NITRO_COLOR_RED := Color(1.0, 0.3, 0.25, 1.0)

# ---------------- 弹字 timers (hold + fade) ----------------
# drift / boost / crash 各有: _hold_left(满 alpha 倒计时), _fade_left(渐隐倒计时)
var _drift_hold_left: float = 0.0
var _drift_fade_left: float = 0.0
var _boost_hold_left: float = 0.0
var _boost_fade_left: float = 0.0
var _crash_hold_left: float = 0.0
var _crash_fade_left: float = 0.0

# 小喷灯状态
var _lamp_active: bool = false
var _lamp_pulse_t: float = 0.0
var _lamp_base_color: Color = LAMP_OFF_COLOR

# 当前氮气颜色变体(由 car 通过 nitro_variant_changed 信号同步)
var _current_nitro_variant: String = "blue"
# combo 字保护: 这个时刻之前 boost_triggered 不覆盖 boost_label
var _combo_protect_until: float = 0.0
# 松前状态: 进入松前时, drift_label 锁定为"松前"满 alpha 持续显示, 不走 hold/fade 衰减
# 离开松前(踩回油门 / 退漂 / 触发松前漂移)时解锁, 走正常 fade
var _songqian_active: bool = false
# 松前提示颜色 (用青绿色, 区分于"漂移"的橙红/紫红)
const SONGQIAN_COLOR := Color(0.4, 1.0, 0.85, 1.0)


func _ready() -> void:
	drift_label.modulate.a = 0.0
	boost_label.modulate.a = 0.0
	crash_label.modulate.a = 0.0
	_paint_nitro_slots(0)
	_set_boost_lamp_off()
	call_deferred("_connect_to_car")


func _connect_to_car() -> void:
	if car_path.is_empty() or not has_node(car_path):
		push_warning("HUD: 找不到 car_path")
		return
	var car: Node = get_node(car_path)
	if car.is_connected("speed_changed", _on_speed_changed):
		return
	car.connect("speed_changed", _on_speed_changed)
	car.connect("charge_changed", _on_charge_changed)
	car.connect("nitro_stock_changed", _on_nitro_stock_changed)
	car.connect("drift_started", _on_drift_started)
	car.connect("drift_ended", _on_drift_ended)
	car.connect("boost_triggered", _on_boost_triggered)
	car.connect("wall_crashed", _on_wall_crashed)
	if car.has_signal("boost_window_opened"):
		car.connect("boost_window_opened", _on_boost_window_opened)
		car.connect("boost_window_closed", _on_boost_window_closed)
	if car.has_signal("drift_charge_level_changed"):
		car.connect("drift_charge_level_changed", _on_drift_charge_level_changed)
	if car.has_signal("double_charge_progress"):
		car.connect("double_charge_progress", _on_double_charge_progress)
		car.connect("double_charge_ready", _on_double_charge_ready)
		car.connect("double_charge_lost", _on_double_charge_lost)
	if car.has_signal("combo_triggered"):
		car.connect("combo_triggered", _on_combo_triggered)
	if car.has_signal("nitro_variant_changed"):
		car.connect("nitro_variant_changed", _on_nitro_variant_changed)
	if car.has_signal("air_boost_triggered"):
		car.connect("air_boost_triggered", _on_air_boost_triggered)
	if car.has_signal("air_boost_armed"):
		car.connect("air_boost_armed", _on_air_boost_armed)
	if car.has_signal("landing_boost_triggered"):
		car.connect("landing_boost_triggered", _on_landing_boost_triggered)
	if car.has_signal("songqian_state_changed"):
		car.connect("songqian_state_changed", _on_songqian_state_changed)
	if car.has_signal("songqian_drift_triggered"):
		car.connect("songqian_drift_triggered", _on_songqian_drift_triggered)
	if car.has_signal("songqian_back_boost_triggered"):
		car.connect("songqian_back_boost_triggered", _on_songqian_back_boost_triggered)


# ============================================================
#  弹字 hold + fade 工具函数
#  调用 _show_popup_X(...) 重置 hold 和 fade 计时, 抢占现有显示内容
# ============================================================
func _show_boost_popup(text: String, color: Color, hold: float = -1.0, fade: float = -1.0) -> void:
	boost_label.text = text
	boost_label.modulate = Color(color.r, color.g, color.b, 1.0)
	_boost_hold_left = hold if hold >= 0.0 else popup_hold_time
	_boost_fade_left = fade if fade >= 0.0 else popup_fade_time


func _show_drift_popup(text: String, color: Color) -> void:
	drift_label.text = text
	drift_label.modulate = Color(color.r, color.g, color.b, 1.0)
	_drift_hold_left = drift_hold_time
	_drift_fade_left = drift_fade_time


func _show_crash_popup(text: String, color: Color) -> void:
	crash_label.text = text
	crash_label.modulate = Color(color.r, color.g, color.b, 1.0)
	_crash_hold_left = crash_hold_time
	_crash_fade_left = crash_fade_time


func _process(delta: float) -> void:
	# 漂移弹字: 松前期间锁定常驻满 alpha; 否则走 hold → fade 标准流程
	if _songqian_active:
		drift_label.modulate.a = 1.0
		# 松前期间清零计时器, 避免离开松前后还残留计时
		_drift_hold_left = 0.0
		_drift_fade_left = drift_fade_time
	elif _drift_hold_left > 0.0:
		_drift_hold_left -= delta
		drift_label.modulate.a = 1.0
	elif _drift_fade_left > 0.0:
		_drift_fade_left -= delta
		drift_label.modulate.a = clampf(_drift_fade_left / maxf(drift_fade_time, 0.001), 0.0, 1.0)
	# 喷射/combo 弹字
	if _boost_hold_left > 0.0:
		_boost_hold_left -= delta
		boost_label.modulate.a = 1.0
	elif _boost_fade_left > 0.0:
		_boost_fade_left -= delta
		boost_label.modulate.a = clampf(_boost_fade_left / maxf(popup_fade_time, 0.001), 0.0, 1.0)
	# 撞墙弹字
	if _crash_hold_left > 0.0:
		_crash_hold_left -= delta
		crash_label.modulate.a = 1.0
	elif _crash_fade_left > 0.0:
		_crash_fade_left -= delta
		crash_label.modulate.a = clampf(_crash_fade_left / maxf(crash_fade_time, 0.001), 0.0, 1.0)
	# 小喷灯亮起时做呼吸脉冲 + 心跳缩放(更明显)
	if _lamp_active:
		_lamp_pulse_t += delta * 7.0
		var pulse: float = 0.6 + 0.4 * sin(_lamp_pulse_t)   # 0.2 ~ 1.0
		# 核心灯芯用高强度 modulate(HDR 感) + scale 心跳
		var col := _lamp_base_color
		# 亮度增强: r/g/b 乘 1.2~2.0 产生发光效果(利用 Godot modulate HDR)
		var glow_k: float = 1.4 + 0.6 * pulse   # 1.4 ~ 2.0
		if boost_lamp_core:
			boost_lamp_core.modulate = Color(col.r * glow_k, col.g * glow_k, col.b * glow_k, 1.0)
			# 心跳缩放: 0.92 ~ 1.08
			var s: float = 0.92 + 0.16 * pulse
			boost_lamp_core.scale = Vector2(s, s)
			boost_lamp_core.pivot_offset = boost_lamp_core.size * 0.5
		# Label 跟随亮度变化
		if boost_lamp_label:
			boost_lamp_label.modulate = Color(1, 1, 1, 0.8 + 0.2 * pulse)


func _on_speed_changed(kmh: float) -> void:
	speed_label.text = "%d" % int(kmh)


func _on_charge_changed(value: float, max_value: float) -> void:
	charge_bar.max_value = max_value
	charge_bar.value = value
	charge_label.text = "%d / %d" % [int(value), int(max_value)]
	var fill := charge_bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill:
		if value >= max_value * 0.95:
			fill.bg_color = Color(0.25, 0.95, 1.0)  # 将成一个氮气
		elif value >= 35:
			fill.bg_color = Color(1.0, 0.8, 0.15)
		else:
			fill.bg_color = Color(1.0, 0.45, 0.1)


func _on_nitro_stock_changed(stock: int, _max_stock: int) -> void:
	_paint_nitro_slots(stock)


func _paint_nitro_slots(stock: int) -> void:
	if nitro_slot_1:
		nitro_slot_1.color = COLOR_NITRO if stock >= 1 else COLOR_EMPTY
	if nitro_slot_2:
		nitro_slot_2.color = COLOR_NITRO if stock >= 2 else COLOR_EMPTY


func _on_drift_started(mode: String) -> void:
	# 【炫点】漂移就是漂移, 不叫甩尾.
	# "甩尾漂移"(tuck) 和 "侧身漂移"(side) 是内部技巧分类, 用于其他系统(比如成就/奖励), 不在中央弹字里区分.
	# mode 参数保留, 仅用于后续如果要区分颜色/特效时用
	var txt: String = "漂移"
	var col: Color = Color(1.0, 0.65, 0.2) if mode == "tuck" else Color(1.0, 0.3, 0.5)
	_show_drift_popup(txt, col)


func _on_drift_ended(_gained: float, _succeeded: bool = false) -> void:
	# 退漂时让漂移提示快速渐隐(给后续 boost/combo 弹字让位)
	# 同时强制清松前锁: 漂移结束后, "松前"提示绝不能继续常驻
	# (有时候 car.gd 的 songqian_state_changed(false) 信号会和 drift_ended 同帧到达, 顺序不确定; 这里兜底)
	_songqian_active = false
	_drift_hold_left = 0.0
	_drift_fade_left = minf(_drift_fade_left, 0.2)


func _on_boost_triggered(type_name: String) -> void:
	print("[HUD] boost_triggered: ", type_name)
	# insufficient/blocked 等屏蔽类型不显示任何提示
	if type_name == "insufficient" or type_name.begins_with("blocked_"):
		return
	# combo 保护期内: 不覆盖 combo 弹字(但灯还是要切换)
	var now: float = Time.get_ticks_msec() / 1000.0
	var combo_protected: bool = now < _combo_protect_until
	if not combo_protected:
		var txt := ""
		var col := Color.WHITE
		# 【炫点文案】除了 CW/CWW/WCW 这类序列名保留英文字母外, 其他全部中文
		match type_name:
			"mini":
				txt = "小喷"
				col = W_COLOR_BLUE
			"double":
				txt = "双喷"
				col = W_COLOR_BLUE
			"nitro":
				txt = "氮气"
				col = _nitro_color_for_variant(_current_nitro_variant)
		_show_boost_popup(txt, col)
	# 小喷触发: 灯保持蓝色, 不再加额外提示文字
	if type_name == "mini":
		_set_boost_lamp_on(LAMP_MINI_COLOR, "")
	# 双喷或氮气结束: 熄灯
	elif type_name in ["double", "nitro"]:
		_set_boost_lamp_off()


# combo 弹字: 三种合法叠喷都弹字
# combo_name 取值:
#   "CW"  → 2 段叠喷(突破 1 次), 弹字
#   "CWW" → 3 段终结(突破 2 次), 弹字
#   "WCW" → 3 段终结(突破 1 次), 弹字
#   "WC"  → WCW 的过渡前缀, 不弹 (玩家还没完成 WCW)
#   其他  → 不弹
func _on_combo_triggered(combo_name: String, breakthrough_count: int) -> void:
	# 只有这三个 combo 弹字, 其他过渡前缀(WC) 静默
	if combo_name != "CW" and combo_name != "CWW" and combo_name != "WCW":
		return
	# 颜色按突破次数:
	#   2 次突破(CWW)        → 红色 (最强)
	#   1 次突破(CW / WCW)   → 金色
	#   0 次突破             → 蓝色 (理论上不会到这里)
	var col: Color
	if breakthrough_count >= 2:
		col = NITRO_COLOR_RED
	elif breakthrough_count == 1:
		col = NITRO_COLOR_GOLD
	else:
		col = W_COLOR_BLUE
	# CW 是 2 段叠喷, 持续时间略短; CWW/WCW 是终结型, 持续更长
	var combo_hold: float = popup_hold_time + (0.4 if combo_name != "CW" else 0.2)
	# 【炫点文案】"叠喷" 为中文前缀, CWW 等序列名保留英文 (就是玩家识别的技巧代号)
	_show_boost_popup("叠喷  %s" % combo_name, col, combo_hold, popup_fade_time)
	_combo_protect_until = Time.get_ticks_msec() / 1000.0 + combo_hold + popup_fade_time * 0.5
	print("[HUD] combo: %s 突破=%d" % [combo_name, breakthrough_count])


func _on_nitro_variant_changed(variant: String) -> void:
	_current_nitro_variant = variant


func _nitro_color_for_variant(variant: String) -> Color:
	match variant:
		"gold": return NITRO_COLOR_GOLD
		"red":  return NITRO_COLOR_RED
		_:      return NITRO_COLOR_BLUE


func _on_wall_crashed(lost_amount: float) -> void:
	_show_crash_popup("撞墙！集气 -%d" % int(lost_amount), Color(1.0, 0.3, 0.3, 1.0))


func _on_air_boost_armed() -> void:
	# 空中按 W: 仅"意图锁定"的中间状态, 还没真正完成空喷技巧.
	# 【炫点】原则不弹字, 完成时在 _on_air_boost_triggered 里弹"空喷！Xs 飞跃"
	pass


# ============================================================
#  松前状态显示 (在 drift_label 位置常驻"松前")
# ============================================================
# 设计:
#   · 进入松前 → drift_label 立刻改为"松前"满 alpha, 用青绿色区分"漂移"
#   · 松前期间 → _process 锁定 alpha=1.0, 不衰减 (玩家不踩回油门就一直显示)
#   · 离开松前 → 如果车还在漂(_drift_hold_left/_drift_fade_left 由 drift_started 信号管理)
#                  之前 _on_drift_started 就已经把"漂移"和它的颜色记好了, 但被我们覆盖了
#                  所以离开松前时主动恢复一次"漂移"显示, 走 hold + fade 流程
#                若已经退漂(state→NORMAL), car.gd 已经发过 drift_ended, 这里走快速渐隐即可
func _on_songqian_state_changed(active: bool) -> void:
	if active:
		_songqian_active = true
		drift_label.text = "松前"
		drift_label.modulate = Color(SONGQIAN_COLOR.r, SONGQIAN_COLOR.g, SONGQIAN_COLOR.b, 1.0)
		print("[HUD] 进入松前 → 显示松前提示")
	else:
		_songqian_active = false
		# 离开松前: 恢复"漂移"显示走 hold→fade. 如果车已经退漂了, drift_ended 已把 hold/fade 清零
		# 这里再 show 一次会让"漂移"短暂闪一下, 不优雅. 折衷: 直接进入 fade 阶段, 让"松前"两字渐隐消失
		drift_label.text = "漂移"
		drift_label.modulate = Color(1.0, 0.3, 0.5, 1.0)  # 默认漂移色
		_drift_hold_left = 0.3   # 给 0.3s 短暂保持, 让"漂移"两字一闪而过
		_drift_fade_left = drift_fade_time
		print("[HUD] 离开松前 → 恢复漂移显示")


func _on_air_boost_triggered(air_time: float) -> void:
	# 【炫点文案】中文. 气泡时长参数保留原 default (不带 hold/fade 参数)
	_show_boost_popup("空喷  %.1f秒飞跃" % air_time, Color(1.0, 0.5, 0.95, 1.0))
	_combo_protect_until = Time.get_ticks_msec() / 1000.0 + 0.4


func _on_landing_boost_triggered(air_time: float) -> void:
	# 【炫点文案】中文.
	_show_boost_popup("落地喷  +%.1f秒" % air_time, Color(0.5, 1.0, 0.7, 1.0), 0.9, 0.4)


# 三喷 (松前后退喷) 触发: 弹红色"三喷"字, 突出高级技巧感
# yaw_deg = 触发瞬间车头偏角 (供调试/未来扩展)
func _on_songqian_back_boost_triggered(_yaw_deg: float) -> void:
	# 红色 = 最强, 和"叠喷 CWW"颜色对齐. 持续时间长一点凸显成就感
	_show_boost_popup("三喷  后退爆发", NITRO_COLOR_RED, 1.6, 0.6)
	_combo_protect_until = Time.get_ticks_msec() / 1000.0 + 1.6
	print("[HUD] 三喷弹字 (偏角 %.1f°)" % _yaw_deg)


# 松前漂移触发: 在 boost_label 上弹 "松前漂移" 字, 用青绿色与"松前"提示色对齐
# (历史: payload 之前是"次数", 现在 car.gd 改成 CD 模式, 此参数固定传 1, 仅作触发 ack)
func _on_songqian_drift_triggered(_count_unused: int) -> void:
	_show_boost_popup("松前漂移", SONGQIAN_COLOR, 1.2, 0.5)
	print("[HUD] 松前漂移弹字")



func _on_boost_window_opened(level: String, _duration: float) -> void:
	# 【炫点】原则: 中央弹字只反馈"玩家做出了什么技巧", 不做"现在按 W"这类教学
	# 这里是"小喷/双喷窗口开启"事件, 属于"可以做什么"而非"已经做了什么" → 不弹字
	# 仅用灯效提示(灯亮+闪 W 字样, 这是 UI 持续性状态提示, 不是"炫点"弹字)
	if level == "double":
		_set_boost_lamp_on(LAMP_DOUBLE_COLOR, "W")
	else:
		_set_boost_lamp_on(LAMP_MINI_COLOR, "W")


func _on_boost_window_closed() -> void:
	# 窗口关闭: 熄灯即可, 无需弹字
	_set_boost_lamp_off()


# ============================================================
#  小喷指示灯 (圆形, 通过 LampCore.modulate + scale 实现发光脉冲)
# ============================================================
func _set_boost_lamp_on(color: Color, label_text: String) -> void:
	_lamp_active = true
	_lamp_pulse_t = 0.0
	_lamp_base_color = color
	# LampCore 立即给满色(初始 modulate > 1 产生发光感)
	if boost_lamp_core:
		boost_lamp_core.modulate = Color(color.r * 1.8, color.g * 1.8, color.b * 1.8, 1.0)
	if boost_lamp_label:
		boost_lamp_label.text = label_text
		boost_lamp_label.modulate = Color(1, 1, 1, 1)


func _set_boost_lamp_off() -> void:
	_lamp_active = false
	_lamp_pulse_t = 0.0
	_lamp_base_color = LAMP_OFF_COLOR
	# 灯芯变回灰暗, scale 复位
	if boost_lamp_core:
		boost_lamp_core.modulate = LAMP_OFF_COLOR
		boost_lamp_core.scale = Vector2.ONE
	if boost_lamp_label:
		boost_lamp_label.text = "W"
		boost_lamp_label.modulate = Color(1, 1, 1, 0.55)


# 漂移过程中实时等级变化(由 car.gd 发出)
func _on_drift_charge_level_changed(level: String) -> void:
	match level:
		"double":
			_set_boost_lamp_on(LAMP_DOUBLE_COLOR, "W")
		"mini":
			_set_boost_lamp_on(LAMP_MINI_COLOR, "W")
		_:
			_set_boost_lamp_off()


# 双喷蓄能进度: progress 0~1, 灯色从蓝渐变到浅蓝
func _on_double_charge_progress(progress: float) -> void:
	if progress <= 0.0:
		# 蓄能取消: 回到当前真实状态对应的灯色
		if _car_is_mini_boosting():
			_set_boost_lamp_on(LAMP_MINI_COLOR, "")
		else:
			_set_boost_lamp_off()
		return
	# 颜色从蓝(mini)插值到浅蓝(double)
	var col: Color = LAMP_MINI_COLOR.lerp(LAMP_DOUBLE_COLOR, progress)
	_lamp_active = true
	_lamp_base_color = col
	if boost_lamp_core:
		boost_lamp_core.modulate = Color(col.r * 1.8, col.g * 1.8, col.b * 1.8, 1.0)
	if boost_lamp_label:
		boost_lamp_label.text = ""


# 双喷蓄满: 灯变亮 + "W!" 文字提示, 但**不**在炫点里弹"按 W！双喷"这种教学字
# (玩家已经把蓄能做完了, 这只是"可以按 W 消费"的 UI 状态, 不是刚完成的技巧反馈)
func _on_double_charge_ready() -> void:
	_set_boost_lamp_on(LAMP_DOUBLE_COLOR, "W!")


# 双喷资格失效(超时/已释放/入漂清空 等)
func _on_double_charge_lost() -> void:
	if _car_is_mini_boosting():
		_set_boost_lamp_on(LAMP_MINI_COLOR, "")
	else:
		_set_boost_lamp_off()


func _car_is_mini_boosting() -> bool:
	if car_path.is_empty() or not has_node(car_path):
		return false
	var c: Node = get_node(car_path)
	return c.get("is_boosting") and c.get("boost_type") == "mini"
