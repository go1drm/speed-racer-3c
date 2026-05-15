@tool
extends TrackBlock
## 上坡道 — 长度 15m, 高度差 +4m (大约 15° 仰角)
## 入口在 (0, 0, +7.5), 出口在 (0, 4, -7.5), 两端朝向都是 -Z

const LENGTH: float = 15.0
const HEIGHT: float = 4.0

func _ready() -> void:
	if get_child_count() > 0 and not Engine.is_editor_hint():
		return
	block_id = "ramp_up"
	# 路面是一段倾斜的直道. 用 BoxMesh 旋转一下 X 轴来表现仰角
	#   atan2(HEIGHT, LENGTH) 给出仰角
	var pitch_rad: float = atan2(HEIGHT, LENGTH)
	var seg_len: float = sqrt(LENGTH * LENGTH + HEIGHT * HEIGHT)   # 倾斜路面的实际长度
	# 路面中心 = (0, HEIGHT/2, 0), 旋转 -pitch (绕 X 轴, 让 -Z 端抬起)
	# 注: Godot 中绕 X 轴正向旋转, +Z 会朝下, -Z 朝上 → 我们想 -Z 抬起 (出口高), 所以用 -pitch
	var basis_pitched := Basis(Vector3.RIGHT, -pitch_rad)
	var center_local := Vector3(0.0, HEIGHT * 0.5, 0.0)
	var xform := Transform3D(basis_pitched, center_local)
	_build_box_road_segment(seg_len, self, xform)
	_build_kerbs(seg_len, self, xform)
	_build_center_pattern(seg_len, self, xform)

	# 入口 (低端, +Z=LENGTH/2, y=0)
	entry_anchor = Marker3D.new()
	entry_anchor.name = "EntryAnchor"
	entry_anchor.position = Vector3(0.0, 0.0, LENGTH * 0.5)
	add_child(entry_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		entry_anchor.owner = get_tree().edited_scene_root

	# 出口 (高端, -Z=LENGTH/2, y=HEIGHT, 朝 -Z 但仰角 0 — 让下一块平地接得上)
	#   实际物理: 车冲上坡到顶后, 车头会在最后那段 segment 沿坡度倾斜, 但下一块还是平的
	#   这是人为简化, 视觉过渡稍微生硬, 但物理稳
	exit_anchor = Marker3D.new()
	exit_anchor.name = "ExitAnchor"
	exit_anchor.position = Vector3(0.0, HEIGHT, -LENGTH * 0.5)
	add_child(exit_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		exit_anchor.owner = get_tree().edited_scene_root
