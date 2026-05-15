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

# ============================================================
# 视觉 mesh 分段数: 512 段足够丝滑 (用户要求)
# 90° 弯半径 20m: 弧长 31.4m, 每段 0.06m, 视觉上完全看不出折线
# ============================================================
const SEGMENTS: int = 512

# ============================================================
# 碰撞 mesh 分段数 (v9 方案: 参考青花瓷地图, 回到 trimesh)
# ============================================================
# 青花瓷地图用 FBX 建模师做的 mesh + create_trimesh_collision(), 完全不抖.
# 青花瓷不抖的原因: 建模师做的三角形接近正方形, 长宽比 ≈ 1:1.
#
# 我们之前抖的原因:
#   v1~v7: 4096 段 × 单列 quad, 三角形长宽比 25m : 0.008m = 3125:1 (极端!)
#   v8: ConvexPolygon 楔形体, 段与段之间接缝比 trimesh 更糟
#
# v9 方案 (视觉/碰撞分离 + 高质量正方形三角形 trimesh):
#   · 视觉 mesh: 512 段 × 单列 (纯视觉, 不参与碰撞)
#   · 碰撞 mesh: 单独生成, 段数和列数让三角形接近正方形
#     碰撞段数 = COLLISION_SEGMENTS (沿弧线方向)
#     碰撞列数 = 动态计算, 使每个三角形的长宽比 ≈ 1:1
#     然后调用 create_trimesh_collision() (跟青花瓷完全一样的做法)
#
# 数学 (90° 弯 R=20m, 路宽 25m):
#   弧长 = 31.4m, 碰撞段数 128, 每段弧长 ≈ 0.25m
#   碰撞列数 = round(25m / 0.25m) = 100
#   三角形 ≈ 0.25m × 0.25m, 接近正方形 ✅
#   总碰撞三角形 = 128 × 100 × 2 = 25,600 (极轻量)
const COLLISION_SEGMENTS: int = 128

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
	# 每个 ring 的 Y 偏移用正弦曲线平滑过渡 (入口/出口切线水平, 中间最陡)
	# 数学: y(t) = total_rise × (t - sin(2πt) / (2π))
	#   y(0) = 0, y(1) = total_rise, y'(0) = 0, y'(1) = 0
	#   这样弯道入口/出口与前后平地无缝衔接, 不会有阶梯感
	# 每个 ring 的半宽 = lerp(entry_width/2, exit_width/2, t)  (路宽渐变)
	var rings: Array = []
	for i in range(SEGMENTS + 1):
		var theta: float = td * float(i) * seg_angle
		var rot := Basis(Vector3.UP, -theta)
		var p_center: Vector3 = center_local + rot * Vector3(R * td, 0.0, 0.0)
		# 正弦曲线坡度 Y 偏移: 入口/出口切线水平, 中间最陡
		var t: float = float(i) / float(SEGMENTS)
		p_center.y += total_rise * (t - sin(TAU * t) / TAU)
		var right_dir: Vector3 = rot * Vector3.RIGHT
		var fwd_dir: Vector3 = rot * Vector3(0.0, 0.0, -1.0)
		# 当前 ring 的半宽 (lerp 入口出口)
		var hw_ring: float = lerpf(entry_width * 0.5, exit_width * 0.5, t)
		rings.append({"pos": p_center, "right": right_dir, "fwd": fwd_dir, "hw": hw_ring})

	# 拼路面顶面 + 中心带 + 左右路缘 + 左右墙
	# 视觉 mesh: 每个 ring 之间 1 个 quad (单列, 4096 段已经极致丝滑)
	# 碰撞体: 后面单独用 ConvexPolygon 楔形体生成 (不走 trimesh)
	for i in range(SEGMENTS):
		var r0: Dictionary = rings[i]
		var r1: Dictionary = rings[i + 1]
		var hw0: float = float(r0["hw"])
		var hw1: float = float(r1["hw"])
		# 路面顶面 (单列 quad)
		var p0_l: Vector3 = r0["pos"] + r0["right"] * (-hw0) + Vector3.UP * top_y
		var p0_r: Vector3 = r0["pos"] + r0["right"] * (hw0) + Vector3.UP * top_y
		var p1_l: Vector3 = r1["pos"] + r1["right"] * (-hw1) + Vector3.UP * top_y
		var p1_r: Vector3 = r1["pos"] + r1["right"] * (hw1) + Vector3.UP * top_y
		_emit_quad(st, p0_l, p0_r, p1_r, p1_l, Vector3.UP)

		# 中心带 (蓝色细带) 顶面
		var pa0_l: Vector3 = r0["pos"] + r0["right"] * (-pat_half_w) + Vector3.UP * pat_y
		var pa0_r: Vector3 = r0["pos"] + r0["right"] * (pat_half_w) + Vector3.UP * pat_y
		var pa1_l: Vector3 = r1["pos"] + r1["right"] * (-pat_half_w) + Vector3.UP * pat_y
		var pa1_r: Vector3 = r1["pos"] + r1["right"] * (pat_half_w) + Vector3.UP * pat_y
		_emit_quad(st_pat, pa0_l, pa0_r, pa1_r, pa1_l, Vector3.UP)

		# 左路缘顶面 (路面外缘 → 外缘 + kerb_w) — 路缘只有 0.5m 宽, 不需要宽度细分
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

	# ============================================================
	# 路面碰撞: 参考青花瓷地图, 用高质量正方形三角形 trimesh (v9)
	# ============================================================
	# 青花瓷地图: FBX mesh + create_trimesh_collision() = 不抖
	# 关键: 三角形接近正方形 (长宽比 ≈ 1:1)
	#
	# 我们的做法: 单独生成一个"碰撞专用 mesh" (不显示),
	# 段数和列数让三角形接近正方形, 然后 create_trimesh_collision()
	# ============================================================
	var st_col := SurfaceTool.new()
	st_col.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 碰撞 mesh 不需要材质 (不显示), 但 SurfaceTool 需要至少 commit 一次
	# 收集碰撞用的 ring
	var col_rings: Array = []
	for ci in range(COLLISION_SEGMENTS + 1):
		var ct: float = float(ci) / float(COLLISION_SEGMENTS)
		var c_theta: float = td * ct * total_angle
		var c_rot := Basis(Vector3.UP, -c_theta)
		var c_pos: Vector3 = center_local + c_rot * Vector3(R * td, 0.0, 0.0)
		c_pos.y += total_rise * (ct - sin(TAU * ct) / TAU)
		var c_right: Vector3 = c_rot * Vector3.RIGHT
		var c_hw: float = lerpf(entry_width * 0.5, exit_width * 0.5, ct)
		col_rings.append({"pos": c_pos, "right": c_right, "hw": c_hw})
	# 动态计算宽度列数: 让三角形接近正方形
	# 弧长/段 = R × total_angle / COLLISION_SEGMENTS
	# 列数 = round(平均路宽 / (弧长/段))
	var seg_arc_len: float = R * total_angle / float(COLLISION_SEGMENTS)
	var avg_hw: float = (entry_width + exit_width) * 0.5
	var col_cols: int = maxi(4, roundi(avg_hw / seg_arc_len))
	# 生成碰撞 mesh 三角形 (只有顶面, 不需要底面/侧面)
	for ci in range(COLLISION_SEGMENTS):
		var cr0 = col_rings[ci]
		var cr1 = col_rings[ci + 1]
		var chw0: float = float(cr0["hw"])
		var chw1: float = float(cr1["hw"])
		for cj in range(col_cols):
			var u0: float = float(cj) / float(col_cols)
			var u1: float = float(cj + 1) / float(col_cols)
			# ring0 左右
			var cx0_l: float = lerpf(-chw0, chw0, u0)
			var cx0_r: float = lerpf(-chw0, chw0, u1)
			# ring1 左右
			var cx1_l: float = lerpf(-chw1, chw1, u0)
			var cx1_r: float = lerpf(-chw1, chw1, u1)
			var cp0l: Vector3 = cr0["pos"] + cr0["right"] * cx0_l + Vector3.UP * top_y
			var cp0r: Vector3 = cr0["pos"] + cr0["right"] * cx0_r + Vector3.UP * top_y
			var cp1l: Vector3 = cr1["pos"] + cr1["right"] * cx1_l + Vector3.UP * top_y
			var cp1r: Vector3 = cr1["pos"] + cr1["right"] * cx1_r + Vector3.UP * top_y
			_emit_quad(st_col, cp0l, cp0r, cp1r, cp1l, Vector3.UP)
	# 提交碰撞 mesh (隐藏, 只用于生成 trimesh 碰撞)
	var col_mi := MeshInstance3D.new()
	col_mi.name = "CollisionMesh"
	col_mi.mesh = st_col.commit()
	col_mi.visible = false  # 不显示, 纯碰撞用
	add_child(col_mi)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		col_mi.owner = get_tree().edited_scene_root
	col_mi.create_trimesh_collision()
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		for c in col_mi.get_children():
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