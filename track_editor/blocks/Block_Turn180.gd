@tool
extends "res://track_editor/blocks/Block_Turn90Left.gd"
## U 形弯 (180°) — 复用 Block_Turn90Left 的 _build_curved_road, 默认 angle 改成 180°

func _ready() -> void:
	if get_child_count() > 0 and not Engine.is_editor_hint():
		return
	if block_id.is_empty():
		block_id = "turn_180"
	# 父类默认 angle_deg=90, 这里改 180 (但保留用户改过的值 — 如果不是默认 90 就不动)
	if angle_deg == 90.0:
		angle_deg = 180.0
	# 左转 U 弯
	_build_curved_road(deg_to_rad(angle_deg), turn_dir)
