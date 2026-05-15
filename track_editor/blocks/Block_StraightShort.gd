@tool
extends TrackBlock
## 直道 — 可编辑长度 / 入口宽 / 出口宽 / 墙高
## 入口在 +Z=length/2, 出口在 -Z=length/2 (本地坐标系)
##
## 可编辑参数:
##   length: 5~120m, 默认 25m (短直道一格 = 路面宽度的 1 倍, 与 25m 宽匹配)
##   entry_width / exit_width / wall_height 在父类 TrackBlock 里定义, 这里继承

@export var length: float = 25.0:
	set(v):
		length = maxf(v, 1.0)
		if is_inside_tree():
			rebuild()

func _ready() -> void:
	if get_child_count() > 0 and not Engine.is_editor_hint():
		return   # 已构建过 (重复 _ready 防御)
	if block_id.is_empty():
		block_id = "straight_short"
	_build_straight()


func _build_straight() -> void:
	# 一段直路面 + 两侧墙 + 路缘 + 中心带, 中心位置在 (0,0,0), 长度沿 Z
	_build_box_road_segment(length)
	_build_walls(length)
	_build_kerbs(length)
	_build_center_pattern(length)
	_build_entry_exit(length * 0.5)


# ------------------------------------------------------------
#  可编辑参数接口 (除了 length 自身, 还暴露父类的 entry/exit/wall)
# ------------------------------------------------------------
func get_editable_params() -> Array:
	# wall_left_in/out / wall_right_in/out 用 0/1 数值显示 (0=关 1=开)
	# 这样不用单独写 bool checkbox, 复用现有 SpinBox UI
	return [
		{"key": "length",       "label": "长度 (m)",   "min": 1.0, "max": 120.0, "step": 0.5, "value": length},
		{"key": "entry_width",  "label": "入口宽 (m)", "min": 3.0, "max": 80.0, "step": 0.5, "value": entry_width},
		{"key": "exit_width",   "label": "出口宽 (m)", "min": 3.0, "max": 80.0, "step": 0.5, "value": exit_width},
		{"key": "wall_height",  "label": "墙高 (m)",   "min": 0.0, "max": 15.0, "step": 0.25, "value": wall_height},
		{"key": "wall_left_in",   "label": "左墙·入口段 (0/1)",  "min": 0.0, "max": 1.0, "step": 1.0, "value": 1.0 if wall_left_in else 0.0},
		{"key": "wall_left_out",  "label": "左墙·出口段 (0/1)",  "min": 0.0, "max": 1.0, "step": 1.0, "value": 1.0 if wall_left_out else 0.0},
		{"key": "wall_right_in",  "label": "右墙·入口段 (0/1)",  "min": 0.0, "max": 1.0, "step": 1.0, "value": 1.0 if wall_right_in else 0.0},
		{"key": "wall_right_out", "label": "右墙·出口段 (0/1)",  "min": 0.0, "max": 1.0, "step": 1.0, "value": 1.0 if wall_right_out else 0.0},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"length":
			length = value
		"entry_width":
			entry_width = value
		"exit_width":
			exit_width = value
		"wall_height":
			wall_height = value
		"wall_left_in":
			wall_left_in = value >= 0.5
		"wall_left_out":
			wall_left_out = value >= 0.5
		"wall_right_in":
			wall_right_in = value >= 0.5
		"wall_right_out":
			wall_right_out = value >= 0.5


func rebuild() -> void:
	# 清掉所有子节点 (mesh + 碰撞 + 入口/出口锚点)
	for c in get_children():
		c.queue_free()
	entry_anchor = null
	exit_anchor = null
	# 重新构建
	_build_straight()

