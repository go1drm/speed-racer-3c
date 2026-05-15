@tool
extends "res://track_editor/blocks/Block_Turn90Left.gd"
## 90° 右弯 — 复用左弯的 _build_curved_road, 仅 turn_dir 取反

func _ready() -> void:
	if get_child_count() > 0 and not Engine.is_editor_hint():
		return
	if block_id.is_empty():
		block_id = "turn_90_right"
	turn_dir = -1.0   # 右弯
	_build_curved_road(deg_to_rad(angle_deg), turn_dir)
