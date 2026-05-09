extends CanvasLayer
## ============================================================
##  赛车 HUD —— 车速 / 蓄力槽 / 漂移 & 喷射提示
## ============================================================

@export var car_path: NodePath

@onready var speed_label: Label = $Root/SpeedBox/SpeedLabel
@onready var speed_unit: Label = $Root/SpeedBox/UnitLabel
@onready var charge_bar: ProgressBar = $Root/ChargeBox/ChargeBar
@onready var charge_label: Label = $Root/ChargeBox/ChargeLabel
@onready var drift_label: Label = $Root/DriftLabel
@onready var boost_label: Label = $Root/BoostLabel
@onready var help_label: Label = $Root/HelpLabel

var _drift_timer: float = 0.0
var _boost_timer: float = 0.0


func _ready() -> void:
	drift_label.modulate.a = 0.0
	boost_label.modulate.a = 0.0
	# 延迟到下一帧再连，以便场景实例化后再设置 car_path
	call_deferred("_connect_to_car")


func _connect_to_car() -> void:
	if car_path.is_empty():
		push_warning("HUD: car_path 未设置")
		return
	if not has_node(car_path):
		push_warning("HUD: car_path 指向的节点不存在: %s" % car_path)
		return
	var car: Node = get_node(car_path)
	if not car.is_connected("speed_changed", _on_speed_changed):
		car.connect("speed_changed", _on_speed_changed)
		car.connect("charge_changed", _on_charge_changed)
		car.connect("drift_started", _on_drift_started)
		car.connect("drift_ended", _on_drift_ended)
		car.connect("boost_triggered", _on_boost_triggered)


func _process(delta: float) -> void:
	if _drift_timer > 0.0:
		_drift_timer -= delta
		drift_label.modulate.a = clampf(_drift_timer, 0.0, 1.0)
	if _boost_timer > 0.0:
		_boost_timer -= delta
		boost_label.modulate.a = clampf(_boost_timer / 1.2, 0.0, 1.0)


func _on_speed_changed(kmh: float) -> void:
	speed_label.text = "%d" % int(kmh)


func _on_charge_changed(value: float, max_value: float) -> void:
	charge_bar.max_value = max_value
	charge_bar.value = value
	charge_label.text = "%d / %d" % [int(value), int(max_value)]
	# 满槽变色提示
	var fill := charge_bar.get_theme_stylebox("fill") as StyleBoxFlat
	if fill:
		if value >= max_value:
			fill.bg_color = Color(0.2, 0.95, 1.0)  # 氮气就绪：青蓝
		elif value >= 35:
			fill.bg_color = Color(1.0, 0.8, 0.15)  # 可小喷：金黄
		else:
			fill.bg_color = Color(1.0, 0.45, 0.1)  # 积攒中：橙


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


func _on_drift_ended(gained: float) -> void:
	_drift_timer = 0.2  # 快速淡出


func _on_boost_triggered(type_name: String) -> void:
	var txt := ""
	var col := Color.WHITE
	match type_name:
		"mini":
			txt = "小喷！"
			col = Color(1.0, 0.75, 0.2)
		"double":
			txt = "DOUBLE! 双喷！"
			col = Color(1.0, 0.4, 0.6)
		"nitro":
			txt = "NITRO! 氮气！"
			col = Color(0.25, 0.95, 1.0)
	boost_label.text = txt
	boost_label.modulate = Color(col.r, col.g, col.b, 1.0)
	_boost_timer = 1.2
