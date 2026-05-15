@tool
extends "res://track_editor/blocks/Block_StraightShort.gd"
## 直道长 — 复用 StraightShort 的逻辑, 仅默认长度不同 (75m vs 25m)
## 用户要求: 宽度基础 25m, 长直道默认 = 短直道 ×3 = 75m

func _ready() -> void:
	if get_child_count() > 0 and not Engine.is_editor_hint():
		return
	if block_id.is_empty():
		block_id = "straight_long"
	# 父类默认 length=25, 改成 long 的默认值 75 (仅在仍是父类默认时改)
	if length == 25.0:
		length = 75.0
	_build_straight()
