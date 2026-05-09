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
@onready var drift_label: Label = $Root/DriftLabel
@onready var boost_label: Label = $Root/BoostLabel
@onready var crash_label: Label = $Root/CrashLabel

const COLOR_EMPTY := Color(0.22, 0.22, 0.28, 0.85)
const COLOR_NITRO := Color(0.25, 0.9, 1.0, 1.0)

var _drift_timer: float = 0.0
var _boost_timer: float = 0.0
var _crash_timer: float = 0.0


func _ready() -> void:
	drift_label.modulate.a = 0.0
	boost_label.modulate.a = 0.0
	crash_label.modulate.a = 0.0
	_paint_nitro_slots(0)
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


func _process(delta: float) -> void:
	if _drift_timer > 0.0:
		_drift_timer -= delta
		drift_label.modulate.a = clampf(_drift_timer, 0.0, 1.0)
	if _boost_timer > 0.0:
		_boost_timer -= delta
		boost_label.modulate.a = clampf(_boost_timer / 1.2, 0.0, 1.0)
	if _crash_timer > 0.0:
		_crash_timer -= delta
		crash_label.modulate.a = clampf(_crash_timer, 0.0, 1.0)


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
	var txt := ""
	var col := Color.WHITE
	if mode == "tuck":
		txt = "DRIFT · 甩尾"
		col = Color(1.0, 0.65, 0.2)
	else:
		txt = "DRIFT · 侧身"
		col = Color(1.0, 0.3, 0.5)
	drift_label.text = txt
	drift_label.modulate = Color(col.r, col.g, col.b, 1.0)
	_drift_timer = 1.2


func _on_drift_ended(_gained: float, _succeeded: bool = false) -> void:
	_drift_timer = 0.2


func _on_boost_triggered(type_name: String) -> void:
	var txt := ""
	var col := Color.WHITE
	match type_name:
		"mini":
			txt = "小  喷"
			col = Color(1.0, 0.75, 0.2)
		"double":
			txt = "D O U B L E !"
			col = Color(1.0, 0.35, 0.45)
		"nitro":
			txt = "N I T R O !!"
			col = Color(0.25, 0.95, 1.0)
	boost_label.text = txt
	boost_label.modulate = Color(col.r, col.g, col.b, 1.0)
	_boost_timer = 1.2


func _on_wall_crashed(lost_amount: float) -> void:
	crash_label.text = "撞墙！集气 -%d" % int(lost_amount)
	crash_label.modulate = Color(1.0, 0.3, 0.3, 1.0)
	_crash_timer = 1.0


func _on_boost_window_opened(level: String, _duration: float) -> void:
	if level == "double":
		boost_label.text = "按 W！双喷"
		boost_label.modulate = Color(1.0, 0.4, 0.6, 1.0)
	else:
		boost_label.text = "按 W！小喷"
		boost_label.modulate = Color(1.0, 0.85, 0.25, 1.0)
	_boost_timer = 0.5  # 短暂显示, 因为窗口本身只有 0.4 秒


func _on_boost_window_closed() -> void:
	# 让提示快速消失(避免和喷射触发后的提示叠加)
	if _boost_timer > 0.15:
		_boost_timer = 0.15
