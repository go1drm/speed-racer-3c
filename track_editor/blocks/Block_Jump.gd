@tool
extends TrackBlock
## 跳台 — 短斜坡终止, 没有"出口路面"接力, 让车飞出去
## 整体长度 8m, 起跳角 ~20°, 下一块直接在地面+前方 ~10m 处接
##
## 入口: (0, 0, +4), 出口: (0, 1.5, -4) — 出口位置稍微抬高让下一块平地能接上
## 严格说跳台后应该是空 → 落地, 但作为可拼接积木我们假设玩家飞过 5~10m 后落到下一块直道上

const LENGTH: float = 8.0
const RAMP_HEIGHT: float = 2.5

func _ready() -> void:
	if get_child_count() > 0 and not Engine.is_editor_hint():
		return
	block_id = "jump"
	# 跳台 = 一段越来越陡的斜坡 (用 2 段直道近似: 前半平缓, 后半陡)
	#   段1 (后半段): 长 4m, 抬升 2.5m, 仰角 ~32°
	#   段2 (前半段): 长 4m, 平地
	var pitch1: float = atan2(RAMP_HEIGHT, 4.0)
	# 段1 在 -Z=2 (中点), 抬升中点 1.25m
	var seg1_len: float = sqrt(4.0 * 4.0 + RAMP_HEIGHT * RAMP_HEIGHT)
	var seg1_basis := Basis(Vector3.RIGHT, -pitch1)
	var seg1_center := Vector3(0.0, RAMP_HEIGHT * 0.5, -2.0)
	_build_box_road_segment(seg1_len, self, Transform3D(seg1_basis, seg1_center))
	_build_kerbs(seg1_len, self, Transform3D(seg1_basis, seg1_center))
	# 段2 (平地, +Z 端): 长 4m, 在 +Z=2 中点
	_build_box_road_segment(4.0, self, Transform3D(Basis(), Vector3(0.0, 0.0, 2.0)))
	_build_kerbs(4.0, self, Transform3D(Basis(), Vector3(0.0, 0.0, 2.0)))
	# 中心带 (整段 8m)
	_build_center_pattern(LENGTH)

	# 入口
	entry_anchor = Marker3D.new()
	entry_anchor.name = "EntryAnchor"
	entry_anchor.position = Vector3(0.0, 0.0, LENGTH * 0.5)
	add_child(entry_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		entry_anchor.owner = get_tree().edited_scene_root

	# 出口 (在跳台末端高点, 但朝 -Z 平视, 让下一块接平地直道)
	exit_anchor = Marker3D.new()
	exit_anchor.name = "ExitAnchor"
	exit_anchor.position = Vector3(0.0, RAMP_HEIGHT, -LENGTH * 0.5)
	add_child(exit_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		exit_anchor.owner = get_tree().edited_scene_root
