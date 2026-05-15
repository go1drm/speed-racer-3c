@tool
extends TrackBlock
## 90° 左弯 — 连续 ArrayMesh 弯道路面 (替代之前的"N 段矩形拼接")
##
## 几何参数:
##   半径 R = 12 米 (沿赛道中心线), 总弧长 = π × 12 / 2 ≈ 18.85 米
##   段数 N = 24 (每段 3.75°, 视觉非常平滑)
##
## 数学:
##   圆心 C = (-R × TURN_DIR, 0, 0) (左弯 +1 → 圆心 -X 侧)
##   入口在本地 (0, 0, 0), 朝 -Z (车头方向)
##   弧上第 i 个采样点 (i ∈ [0, N]) 的角度 θ = i × seg_angle
##   该点中心位置 P_center = C + Basis(UP, -TURN_DIR × θ) × (R × TURN_DIR, 0, 0)
##   该点切线方向 (车头朝向) = Basis(UP, -TURN_DIR × θ) × Vector3(0, 0, -1)
##   左右路面边缘 = P_center ± right_dir × (ROAD_WIDTH / 2)
##     其中 right_dir = Basis(UP, -TURN_DIR × θ) × Vector3.RIGHT
##
## ArrayMesh 构造方式:
##   生成 (N+1) × 2 个顶点 (路面顶面: 左边缘 + 右边缘)
##   每两条相邻 ring 之间 4 个顶点拼成 2 个三角形 (一个 quad)
##   再加底面 (Y = -ROAD_THICKNESS) 同样的 (N+1)×2 顶点 + 三角化
##   再加左右两侧"墙面" (3D 厚度), 让弯道有真实立体感
##
## 碰撞:
##   弯道碰撞用 N 段 BoxShape3D, 每段是路面的一小段
##   (用 ConvexPolygonShape 也行, 但 BoxShape 性能更好且对球体足够准)
##
## ⚠️ 注意: ArrayMesh 顶点的法向计算用 (右边缘 - 左边缘) × (前进方向) 算出向上,
##   但车在路面上方滚, 需要 normal 朝 +Y. 三角形绕序 CCW 即可让正面朝上.

## 可编辑参数:
##   angle_deg       : 弧度角 (默认 90°). 子类 Turn180 会改成 180°
##   radius          : 半径 (默认 12m). 影响弯道大小
##   total_pitch_deg : 沿弧线总抬升角度 (默认 0°). 弯道两端高度差 = R × angle × sin(pitch). 用于做"上坡弯"
##   turn_dir        : +1=左弯, -1=右弯 (内部用, Right 子类设 -1)

@export var angle_deg: float = 90.0:
	set(v):
		angle_deg = clampf(v, 5.0, 360.0)
		if is_inside_tree():
			rebuild()
@export var radius: float = 20.0:
	set(v):
		radius = clampf(v, 3.0, 80.0)
		if is_inside_tree():
			rebuild()
@export var total_pitch_deg: float = 0.0:
	set(v):
		total_pitch_deg = clampf(v, -45.0, 45.0)
		if is_inside_tree():
			rebuild()
@export var turn_dir: float = 1.0:
	set(v):
		turn_dir = signf(v) if absf(v) > 0.5 else 1.0
		if is_inside_tree():
			rebuild()

# 弯道分段数: 控制视觉 mesh 圆弧的"圆滑程度" + 物理 trimesh 顶点密度
# v7 改用 create_trimesh_collision (青花瓷做法) 后, 段数主要影响视觉圆滑度
# 32 段: 90° 弯每段 2.8°, 视觉看着圆滑 (人眼分不出比 64 段更圆); 半径 20m 时弧长 ~1m
# 物理 trimesh 直接从视觉 mesh 顶点生成, 三角形数量足够细
# 性能: 视觉 mesh ~32 个 quad, 物理 trimesh ~64 个三角形, 相当轻量
const SEGMENTS: int = 32

func _ready() -> void:
	if get_child_count() > 0 and not Engine.is_editor_hint():
		return
	if block_id.is_empty():
		block_id = "turn_90_left"
	_build_curved_road(deg_to_rad(angle_deg), turn_dir)


# ------------------------------------------------------------
#  可编辑参数接口
# ------------------------------------------------------------
func get_editable_params() -> Array:
	return [
		{"key": "angle_deg",       "label": "弧度角 (°)",   "min": 5.0,   "max": 360.0, "step": 1.0,  "value": angle_deg},
		{"key": "radius",          "label": "半径 (m)",     "min": 3.0,   "max": 80.0,  "step": 0.5,  "value": radius},
		{"key": "total_pitch_deg", "label": "总坡度 (°)",   "min": -45.0, "max": 45.0,  "step": 0.5,  "value": total_pitch_deg},
		{"key": "entry_width",     "label": "入口宽 (m)",   "min": 3.0,   "max": 80.0,  "step": 0.5,  "value": entry_width},
		{"key": "exit_width",      "label": "出口宽 (m)",   "min": 3.0,   "max": 80.0,  "step": 0.5,  "value": exit_width},
		{"key": "wall_height",     "label": "墙高 (m)",     "min": 0.0,   "max": 15.0,  "step": 0.25, "value": wall_height},
		{"key": "wall_left_in",    "label": "左墙·入口段 (0/1)",  "min": 0.0, "max": 1.0, "step": 1.0, "value": 1.0 if wall_left_in else 0.0},
		{"key": "wall_left_out",   "label": "左墙·出口段 (0/1)",  "min": 0.0, "max": 1.0, "step": 1.0, "value": 1.0 if wall_left_out else 0.0},
		{"key": "wall_right_in",   "label": "右墙·入口段 (0/1)",  "min": 0.0, "max": 1.0, "step": 1.0, "value": 1.0 if wall_right_in else 0.0},
		{"key": "wall_right_out",  "label": "右墙·出口段 (0/1)",  "min": 0.0, "max": 1.0, "step": 1.0, "value": 1.0 if wall_right_out else 0.0},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"angle_deg":
			angle_deg = value
		"radius":
			radius = value
		"total_pitch_deg":
			total_pitch_deg = value
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
	for c in get_children():
		c.queue_free()
	entry_anchor = null
	exit_anchor = null
	_build_curved_road(deg_to_rad(angle_deg), turn_dir)


# 构建连续弧形路面 + 碰撞 + 路缘 + 入口/出口锚点
# 参数 total_angle 和 td 留下作为参数 (而不是只读 angle_deg/turn_dir 实例字段)
# 是为了让子类 Turn180/Turn90Right 在 _ready 里直接用不同值调用而不必先 set
func _build_curved_road(total_angle: float, td: float) -> void:
	var R: float = radius
	var center_local: Vector3 = Vector3(-R * td, 0.0, 0.0)
	var seg_angle: float = total_angle / float(SEGMENTS)
	# 总坡度: 沿弧线弧长方向, 从 0 抬升到 H_total = R × total_angle × tan(pitch)
	# 实际我们用一个简化模型: 第 i 个 ring 的 Y 偏移 = (i / N) × R × total_angle × tan(pitch_rad)
	# 这样起点 y=0, 终点 y = R × total_angle × tan(pitch) = 弧长 × tan(pitch)
	var pitch_rad: float = deg_to_rad(total_pitch_deg)
	var arc_length: float = R * total_angle
	var total_rise: float = arc_length * tan(pitch_rad)
	# 路面 ArrayMesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_make_road_material())

	# 中心带 (青花瓷蓝细带) 的 ArrayMesh
	var st_pat := SurfaceTool.new()
	st_pat.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_pat.set_material(_make_pattern_material())

	# 路缘 (左右两侧红白条) 的 ArrayMesh — 路面外 25cm + 高 15cm
	var st_kerb_l := SurfaceTool.new()
	st_kerb_l.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_kerb_l.set_material(_make_kerb_material())
	var st_kerb_r := SurfaceTool.new()
	st_kerb_r.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_kerb_r.set_material(_make_kerb_material())

	# 沿弧线生成顶点条带
	# 路宽渐变: 入口宽 entry_width, 出口宽 exit_width, 每个 ring 按进度 t lerp
	var pat_half_w: float = 0.3   # 中心带半宽 0.3 米
	var kerb_w: float = 0.5
	var top_y: float = ROAD_THICKNESS * 0.5
	var pat_y: float = top_y + 0.011                # 中心带在路面上方 1.1cm 防 z-fighting
	var kerb_top_y: float = top_y + 0.075           # 路缘顶面 (路面上方 7.5cm)
	var wall_top_offset: float = wall_height        # 墙顶相对路面顶的高度 (路面 top_y + this)

	# 墙的 SurfaceTool (左右各一; 仅 wall_height > 0 时使用)
	var st_wall_l := SurfaceTool.new()
	var st_wall_r := SurfaceTool.new()
	if wall_height >= 0.05:
		st_wall_l.begin(Mesh.PRIMITIVE_TRIANGLES)
		st_wall_l.set_material(_make_wall_material())
		st_wall_r.begin(Mesh.PRIMITIVE_TRIANGLES)
		st_wall_r.set_material(_make_wall_material())

	# 收集 (N+1) ring 的"中心点 + right_dir + 半宽"
	# 每个 ring 的 Y 偏移按弧长进度 (i / N) × total_rise 线性抬升, 让弯道有上下坡效果
	# 每个 ring 的半宽 = lerp(entry_width/2, exit_width/2, t)  (路宽渐变)
	var rings: Array = []
	for i in range(SEGMENTS + 1):
		var theta: float = td * float(i) * seg_angle
		var rot := Basis(Vector3.UP, -theta)
		var p_center: Vector3 = center_local + rot * Vector3(R * td, 0.0, 0.0)
		# 加坡度 Y 偏移: 进度 t ∈ [0, 1], y = t × total_rise
		var t: float = float(i) / float(SEGMENTS)
		p_center.y += t * total_rise
		var right_dir: Vector3 = rot * Vector3.RIGHT
		var fwd_dir: Vector3 = rot * Vector3(0.0, 0.0, -1.0)
		# 当前 ring 的半宽 (lerp 入口出口)
		var hw_ring: float = lerpf(entry_width * 0.5, exit_width * 0.5, t)
		rings.append({"pos": p_center, "right": right_dir, "fwd": fwd_dir, "hw": hw_ring})

	# 拼路面顶面 + 中心带 + 左右路缘 + 左右墙
	for i in range(SEGMENTS):
		var r0: Dictionary = rings[i]
		var r1: Dictionary = rings[i + 1]
		var hw0: float = float(r0["hw"])
		var hw1: float = float(r1["hw"])
		# 路面顶面 (用每个 ring 自己的半宽)
		var p0_l: Vector3 = r0["pos"] + r0["right"] * (-hw0) + Vector3.UP * top_y
		var p0_r: Vector3 = r0["pos"] + r0["right"] * (hw0) + Vector3.UP * top_y
		var p1_l: Vector3 = r1["pos"] + r1["right"] * (-hw1) + Vector3.UP * top_y
		var p1_r: Vector3 = r1["pos"] + r1["right"] * (hw1) + Vector3.UP * top_y
		_emit_quad(st, p0_l, p0_r, p1_r, p1_l, Vector3.UP)

		# 中心带 (蓝色细带) 顶面 — 中心带宽度不渐变, 始终是 pat_half_w
		var pa0_l: Vector3 = r0["pos"] + r0["right"] * (-pat_half_w) + Vector3.UP * pat_y
		var pa0_r: Vector3 = r0["pos"] + r0["right"] * (pat_half_w) + Vector3.UP * pat_y
		var pa1_l: Vector3 = r1["pos"] + r1["right"] * (-pat_half_w) + Vector3.UP * pat_y
		var pa1_r: Vector3 = r1["pos"] + r1["right"] * (pat_half_w) + Vector3.UP * pat_y
		_emit_quad(st_pat, pa0_l, pa0_r, pa1_r, pa1_l, Vector3.UP)

		# 左路缘顶面 (路面外缘 → 外缘 + kerb_w)
		var kl0_in: Vector3 = r0["pos"] + r0["right"] * (-hw0) + Vector3.UP * kerb_top_y
		var kl0_ou: Vector3 = r0["pos"] + r0["right"] * (-hw0 - kerb_w) + Vector3.UP * kerb_top_y
		var kl1_in: Vector3 = r1["pos"] + r1["right"] * (-hw1) + Vector3.UP * kerb_top_y
		var kl1_ou: Vector3 = r1["pos"] + r1["right"] * (-hw1 - kerb_w) + Vector3.UP * kerb_top_y
		_emit_quad(st_kerb_l, kl0_ou, kl0_in, kl1_in, kl1_ou, Vector3.UP)

		# 右路缘顶面
		var kr0_in: Vector3 = r0["pos"] + r0["right"] * (hw0) + Vector3.UP * kerb_top_y
		var kr0_ou: Vector3 = r0["pos"] + r0["right"] * (hw0 + kerb_w) + Vector3.UP * kerb_top_y
		var kr1_in: Vector3 = r1["pos"] + r1["right"] * (hw1) + Vector3.UP * kerb_top_y
		var kr1_ou: Vector3 = r1["pos"] + r1["right"] * (hw1 + kerb_w) + Vector3.UP * kerb_top_y
		_emit_quad(st_kerb_r, kr0_in, kr0_ou, kr1_ou, kr1_in, Vector3.UP)

		# 左右墙 (从路面顶 top_y 升到 top_y + wall_height, 朝内的法向)
		# 用户要求: 可以单独取消"左/右 × 入口段/出口段"4 块墙做半段开口
		# 入口段 = 前半 (i < SEGMENTS/2); 出口段 = 后半 (i >= SEGMENTS/2)
		if wall_height >= 0.05:
			var is_out_seg: bool = (i >= SEGMENTS / 2)
			var draw_left: bool = (wall_left_out if is_out_seg else wall_left_in)
			var draw_right: bool = (wall_right_out if is_out_seg else wall_right_in)
			# 左墙: 在路面外缘 (-hw)
			if draw_left:
				var wl0_b: Vector3 = r0["pos"] + r0["right"] * (-hw0) + Vector3.UP * top_y
				var wl0_t: Vector3 = wl0_b + Vector3.UP * wall_top_offset
				var wl1_b: Vector3 = r1["pos"] + r1["right"] * (-hw1) + Vector3.UP * top_y
				var wl1_t: Vector3 = wl1_b + Vector3.UP * wall_top_offset
				_emit_quad(st_wall_l, wl0_b, wl0_t, wl1_t, wl1_b, r0["right"])
			# 右墙: 在路面外缘 (+hw)
			if draw_right:
				var wr0_b: Vector3 = r0["pos"] + r0["right"] * (hw0) + Vector3.UP * top_y
				var wr0_t: Vector3 = wr0_b + Vector3.UP * wall_top_offset
				var wr1_b: Vector3 = r1["pos"] + r1["right"] * (hw1) + Vector3.UP * top_y
				var wr1_t: Vector3 = wr1_b + Vector3.UP * wall_top_offset
				_emit_quad(st_wall_r, wr0_b, wr0_t, wr1_t, wr1_b, -r0["right"])

	# 路面 mesh
	# 不调 generate_normals (cull_disabled 双面渲染, 法向用 _emit_quad 里 set_normal 提供的就够)
	var mesh_road: ArrayMesh = st.commit()
	var mi_road := MeshInstance3D.new()
	mi_road.mesh = mesh_road
	add_child(mi_road)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		mi_road.owner = get_tree().edited_scene_root

	# 中心带 mesh
	var mi_pat := MeshInstance3D.new()
	mi_pat.mesh = st_pat.commit()
	add_child(mi_pat)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		mi_pat.owner = get_tree().edited_scene_root

	# 路缘 mesh (左右各一)
	var mi_kl := MeshInstance3D.new()
	mi_kl.mesh = st_kerb_l.commit()
	add_child(mi_kl)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		mi_kl.owner = get_tree().edited_scene_root
	var mi_kr := MeshInstance3D.new()
	mi_kr.mesh = st_kerb_r.commit()
	add_child(mi_kr)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		mi_kr.owner = get_tree().edited_scene_root

	# 墙 mesh + 物理碰撞 (左右各一; 仅 wall_height >= 0.05 时生成)
	if wall_height >= 0.05:
		var mi_wl := MeshInstance3D.new()
		mi_wl.mesh = st_wall_l.commit()
		add_child(mi_wl)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			mi_wl.owner = get_tree().edited_scene_root
		var mi_wr := MeshInstance3D.new()
		mi_wr.mesh = st_wall_r.commit()
		add_child(mi_wr)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			mi_wr.owner = get_tree().edited_scene_root
		# 墙的物理: 沿弧线每段一个 BoxShape, 厚 0.3m, 高 wall_height
		# 墙的 box 中心 = ring 路面边缘 + 高度一半向上, basis 朝车前进方向
		var wall_thick: float = 0.3
		for i in range(SEGMENTS):
			var r0: Dictionary = rings[i]
			var r1: Dictionary = rings[i + 1]
			var hw0w: float = float(r0["hw"])
			var hw1w: float = float(r1["hw"])
			var hw_mid: float = (hw0w + hw1w) * 0.5
			# 段中点 + 段方向
			var seg_mid: Vector3 = (r0["pos"] + r1["pos"]) * 0.5
			var seg_yaw: float = -td * (float(i) + 0.5) * seg_angle
			var seg_basis_w := Basis(Vector3.UP, seg_yaw)
			seg_basis_w = seg_basis_w.rotated(seg_basis_w * Vector3.RIGHT, deg_to_rad(total_pitch_deg))
			# 段长度
			var seg_len_w: float = r0["pos"].distance_to(r1["pos"]) * 1.05
			# 左墙: 中点在 mid + right × (-hw_mid), 高度 wall_height/2 上方
			# 同 mesh: 按 i 段位置判断该墙段是否启用
			var is_out_seg_w: bool = (i >= SEGMENTS / 2)
			var draw_left_w: bool = (wall_left_out if is_out_seg_w else wall_left_in)
			var draw_right_w: bool = (wall_right_out if is_out_seg_w else wall_right_in)
			for sgn: float in [-1.0, 1.0]:
				# sgn = -1 = 左, +1 = 右
				if sgn < 0.0 and not draw_left_w:
					continue
				if sgn > 0.0 and not draw_right_w:
					continue
				var wall_center_local: Vector3 = seg_mid + seg_basis_w.x * (sgn * hw_mid) + Vector3.UP * (top_y + wall_height * 0.5)
				var body_w := StaticBody3D.new()
				add_child(body_w)
				body_w.transform = Transform3D(seg_basis_w, wall_center_local)
				if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
					body_w.owner = get_tree().edited_scene_root
				var col_w := CollisionShape3D.new()
				var sh_w := BoxShape3D.new()
				sh_w.size = Vector3(wall_thick, wall_height, seg_len_w)
				col_w.shape = sh_w
				body_w.add_child(col_w)
				if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
					col_w.owner = get_tree().edited_scene_root

	# 碰撞: 沿弧线放 N 段 BoxShape (对球体碰撞足够准, 性能好)
	# ============================================================
	# 弯道路面碰撞: 用 create_trimesh_collision (青花瓷地图同款做法)
	# ============================================================
	# 历史所有失败方案:
	#   v1: 逐段独立 BoxShape (yaw+pitch 旋转)  → box 跟视觉错位, 抖
	#   v2: BoxShape look_at 风格               → 段法线在 ring 边界突变, 抖
	#   v3: 整条 ConcavePolygonShape3D 手写      → 法线连续了, 但球-trimesh 边界抖
	#   v4: 逐段 ConvexPolygonShape3D 共享 ring  → 抖
	#   v5: SEGMENTS 64                         → 抖
	#   v6: SEGMENTS 512                        → 抖
	#
	# 真相: 抖动来自"手搓段拼接 trimesh"在三角形对角线分布上的微小法线不一致.
	#       青花瓷地图用建模师做的 FBX, 调用 mi.create_trimesh_collision(),
	#       Godot 内建 API 直接从 mesh 顶点生成最优 trimesh, 完全不抖.
	#
	# v7 (本次, 终极方案):
	#   1. 把视觉路面 mesh (mesh_road) 直接调用 create_trimesh_collision()
	#      Godot 自动从 ArrayMesh 顶点生成 ConcavePolygonShape3D,
	#      几何 100% 跟视觉一致, 法线由顶点位置决定, 不会有手搓 basis 错误.
	#   2. 视觉 mesh 是单面 (顶面), 不会从下方撞墙. 车只会从上方接触.
	#   3. 完全跟青花瓷地图相同的物理形态, 用户已验证青花瓷不抖.
	# ============================================================
	# 注意: 这里的视觉路面 mesh_road 在前面 commit 过, 直接 create_trimesh_collision
	#       会在 mi_road 下挂一个 StaticBody3D__col 子节点. 这就是青花瓷的做法.
	mi_road.create_trimesh_collision()
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		# 让自动生成的 StaticBody3D 也归 edited_scene_root, 不然 .tscn 保存不下来
		for c in mi_road.get_children():
			if c is StaticBody3D:
				c.owner = get_tree().edited_scene_root
				for cc in c.get_children():
					if cc is CollisionShape3D:
						cc.owner = get_tree().edited_scene_root

	# 路缘 (kerb) 也加 trimesh 碰撞, 让车碾上路缘有"咯噔"反馈而不是穿过
	# 旧版只有路面有碰撞, 路缘视觉浮起 7.5cm 但车开过去无感
	mi_kl.create_trimesh_collision()
	mi_kr.create_trimesh_collision()
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		for mi_kerb: MeshInstance3D in [mi_kl, mi_kr]:
			for c in mi_kerb.get_children():
				if c is StaticBody3D:
					c.owner = get_tree().edited_scene_root
					for cc in c.get_children():
						if cc is CollisionShape3D:
							cc.owner = get_tree().edited_scene_root

	# 入口/出口锚点
	entry_anchor = Marker3D.new()
	entry_anchor.name = "EntryAnchor"
	entry_anchor.position = Vector3.ZERO
	add_child(entry_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		entry_anchor.owner = get_tree().edited_scene_root

	# 出口位置 = 圆心 + 旋转后偏移 + Y抬升 (沿弧线终点高度 = total_rise)
	# 出口 basis: 同时包含 yaw (整个 td*total_angle) 和 pitch (沿前进倾斜)
	var exit_yaw: float = -td * total_angle
	var exit_basis := Basis(Vector3.UP, exit_yaw)
	exit_basis = exit_basis.rotated(exit_basis * Vector3.RIGHT, deg_to_rad(total_pitch_deg))
	var exit_pos: Vector3 = center_local + Basis(Vector3.UP, exit_yaw) * Vector3(R * td, 0.0, 0.0)
	exit_pos.y += total_rise
	exit_anchor = Marker3D.new()
	exit_anchor.name = "ExitAnchor"
	exit_anchor.transform = Transform3D(exit_basis, exit_pos)
	add_child(exit_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		exit_anchor.owner = get_tree().edited_scene_root


# 把一个 quad (4 个顶点, 顺时针看法向朝外) 拆成 2 个三角形 emit 给 SurfaceTool
# 顶点顺序: a → b → c → d, 三角形 (a, b, c) 和 (a, c, d)
# normal 是给 SurfaceTool 提示的法向 (但 generate_normals 会重算, 所以这个仅供 lighting 兜底)
func _emit_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	st.set_normal(n); st.add_vertex(a)
	st.set_normal(n); st.add_vertex(b)
	st.set_normal(n); st.add_vertex(c)
	st.set_normal(n); st.add_vertex(a)
	st.set_normal(n); st.add_vertex(c)
	st.set_normal(n); st.add_vertex(d)
