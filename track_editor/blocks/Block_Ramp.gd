@tool
extends TrackBlock
## ============================================================
##  上坡道 — 真正的曲面版本 (v2: ArrayMesh + trimesh 碰撞)
##
##  几何:
##    入口在 (0, 0, +LENGTH/2), 出口在 (0, HEIGHT, -LENGTH/2)
##    高度沿 Z 用正弦曲线插值: y(t) = HEIGHT × (t - sin(2πt) / (2π))
##    这样入口处切线水平 (dy/dz=0), 出口处切线也水平 (dy/dz=0)
##    车从平地驶入坡道和从坡道驶出到平地都是丝滑过渡, 没有阶梯感
##
##  数学 (正弦曲线高度函数):
##    t = (LENGTH/2 - z) / LENGTH  ∈ [0, 1]  (入口 t=0, 出口 t=1)
##    y(t) = HEIGHT × (t - sin(2πt) / (2π))
##    dy/dt = HEIGHT × (1 - cos(2πt))
##    在 t=0: dy/dt = 0 (入口处水平)
##    在 t=1: dy/dt = 0 (出口处水平)
##    在 t=0.5: dy/dt = 2×HEIGHT (中间最陡)
##
##  分段:
##    SEGMENTS = 4096 段, 每段约 0.0037m (LENGTH=15m 时)
##    视觉 ArrayMesh: (SEGMENTS+1) × 2 个顶点 (左右边缘) → SEGMENTS × 2 个三角形
##    碰撞: create_trimesh_collision 从视觉 mesh 生成, 完美贴合曲面
##    RTX 4080S 完全无压力 (4096 段 = 8192 个三角形, 对现代 GPU 微不足道)
##
##  可编辑参数:
##    length : 坡道长度 (默认 15m)
##    height : 坡道高度差 (默认 4m)
## ============================================================

@export var length: float = 15.0:
	set(v):
		length = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			rebuild()
@export var height: float = 4.0:
	set(v):
		height = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			rebuild()

## ============================================================
## 视觉 mesh 分段数: 512 段足够丝滑 (用户要求)
## 15m 坡道: 每段 0.03m, 视觉上完全看不出折线
## ============================================================
const SEGMENTS: int = 512

## ============================================================
## 碰撞 mesh 分段数 (v9 方案: 参考青花瓷地图, 用高质量正方形三角形 trimesh)
## 碰撞列数动态计算, 使三角形长宽比 ≈ 1:1
## 128 段: 15m 坑道每段 ~0.12m, 列数 = round(25m / 0.12m) ≈ 213
## 总碰撞三角形 = 128 × 213 × 2 ≈ 54,528 (极轻量)
const COLLISION_SEGMENTS: int = 128


func _ready() -> void:
	if get_child_count() > 0 and not Engine.is_editor_hint():
		return
	block_id = "ramp_up"
	_build_smooth_ramp()


func get_editable_params() -> Array:
	return [
		{"key": "length",      "label": "坡道长度 (m)", "min": 3.0,  "max": 60.0, "step": 0.5, "value": length},
		{"key": "height",      "label": "坡道高度 (m)", "min": 0.5,  "max": 20.0, "step": 0.5, "value": height},
		{"key": "entry_width", "label": "入口宽 (m)",   "min": 3.0,  "max": 80.0, "step": 0.5, "value": entry_width},
		{"key": "exit_width",  "label": "出口宽 (m)",   "min": 3.0,  "max": 80.0, "step": 0.5, "value": exit_width},
		{"key": "wall_height", "label": "墙高 (m)",     "min": 0.0,  "max": 15.0, "step": 0.5, "value": wall_height},
	]


func set_editable_param(key: String, value: float) -> void:
	match key:
		"length":
			length = value
		"height":
			height = value
		"entry_width":
			entry_width = value
		"exit_width":
			exit_width = value
		"wall_height":
			wall_height = value


func rebuild() -> void:
	for c in get_children():
		c.queue_free()
	entry_anchor = null
	exit_anchor = null
	_build_smooth_ramp()


## ============================================================
##  核心: 构建正弦曲线曲面坡道
## ============================================================
## 高度函数 (正弦曲线, 入口/出口切线水平):
##   t ∈ [0, 1], 入口 t=0, 出口 t=1
##   y(t) = HEIGHT × (t - sin(2πt) / (2π))
##   特性: y(0)=0, y(1)=HEIGHT, y'(0)=0, y'(1)=0
func _height_at_t(t: float) -> float:
	return height * (t - sin(TAU * t) / TAU)


## 坡面法线 (用于光照): 对高度函数求导得到切线, 再叉乘得法线
## dy/dt = HEIGHT × (1 - cos(2πt))
## 切线方向 (在 XZ 平面投影为 -Z): tangent = (0, dy/dz, -1).normalized()
##   其中 dy/dz = dy/dt × dt/dz = dy/dt × (-1/LENGTH)
## 法线 = tangent × right = 朝上偏
func _normal_at_t(t: float) -> Vector3:
	var dy_dt: float = height * (1.0 - cos(TAU * t))
	var dy_dz: float = -dy_dt / length   # dt/dz = -1/LENGTH
	# 切线沿 -Z 方向 (车前进方向), Y 分量 = dy_dz
	var tangent := Vector3(0.0, dy_dz, -1.0).normalized()
	var right := Vector3.RIGHT
	var n: Vector3 = right.cross(tangent).normalized()
	# 确保法线朝上
	if n.y < 0.0:
		n = -n
	return n


func _build_smooth_ramp() -> void:
	var hl: float = length * 0.5   # 半长
	var top_y: float = ROAD_THICKNESS * 0.5

	# ============================================================
	# 路面 ArrayMesh (曲面)
	# ============================================================
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_make_road_material())

	# 中心装饰带 (青花瓷蓝)
	var st_pat := SurfaceTool.new()
	st_pat.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_pat.set_material(_make_pattern_material())

	# 路缘 (左右红条)
	var st_kerb_l := SurfaceTool.new()
	st_kerb_l.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_kerb_l.set_material(_make_kerb_material())
	var st_kerb_r := SurfaceTool.new()
	st_kerb_r.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_kerb_r.set_material(_make_kerb_material())

	var pat_half_w: float = 0.3   # 中心带半宽
	var kerb_w: float = 0.5       # 路缘宽度
	var kerb_y_offset: float = 0.075   # 路缘高于路面

	# 收集 (SEGMENTS+1) 个 ring 的数据
	# 每个 ring: 中心点 + 法线 + 半宽 (路宽渐变)
	var rings: Array = []
	for i in range(SEGMENTS + 1):
		var t: float = float(i) / float(SEGMENTS)
		var z: float = hl - t * length   # 入口 z=+hl, 出口 z=-hl
		var y: float = _height_at_t(t) + top_y
		var n: Vector3 = _normal_at_t(t)
		var hw: float = lerpf(entry_width * 0.5, exit_width * 0.5, t)
		rings.append({"z": z, "y": y, "n": n, "hw": hw, "t": t})

	# 生成路面三角形 — 视觉 mesh 单列 (4096 段已经极致丝滑)
	# 碰撞体后面单独用 ConvexPolygon 生成 (不走 trimesh)
	for i in range(SEGMENTS):
		var r0 = rings[i]
		var r1 = rings[i + 1]
		var n0: Vector3 = r0.n
		var n1: Vector3 = r1.n
		var n_avg: Vector3 = ((n0 + n1) * 0.5).normalized()
		# 路面 quad (单列)
		var p0l := Vector3(-r0.hw, r0.y, r0.z)
		var p0r := Vector3(r0.hw, r0.y, r0.z)
		var p1l := Vector3(-r1.hw, r1.y, r1.z)
		var p1r := Vector3(r1.hw, r1.y, r1.z)
		_emit_tri(st, p0l, p0r, p1r, n_avg)
		_emit_tri(st, p0l, p1r, p1l, n_avg)
		# 中心装饰带 (路面上方 1.1cm) — 只有 0.6m 宽, 不需要宽度细分
		var pat_y0: float = r0.y + 0.011
		var pat_y1: float = r1.y + 0.011
		var pp0l := Vector3(-pat_half_w, pat_y0, r0.z)
		var pp0r := Vector3(pat_half_w, pat_y0, r0.z)
		var pp1l := Vector3(-pat_half_w, pat_y1, r1.z)
		var pp1r := Vector3(pat_half_w, pat_y1, r1.z)
		_emit_tri(st_pat, pp0l, pp0r, pp1r, n_avg)
		_emit_tri(st_pat, pp0l, pp1r, pp1l, n_avg)
		# 路缘 (左右各一条, 路面外侧) — 只有 0.5m 宽, 不需要宽度细分
		var ky0: float = r0.y + kerb_y_offset
		var ky1: float = r1.y + kerb_y_offset
		# 左路缘
		var kl0i := Vector3(-r0.hw, ky0, r0.z)
		var kl0o := Vector3(-r0.hw - kerb_w, ky0, r0.z)
		var kl1i := Vector3(-r1.hw, ky1, r1.z)
		var kl1o := Vector3(-r1.hw - kerb_w, ky1, r1.z)
		_emit_tri(st_kerb_l, kl0i, kl0o, kl1o, Vector3.UP)
		_emit_tri(st_kerb_l, kl0i, kl1o, kl1i, Vector3.UP)
		# 右路缘
		var kr0i := Vector3(r0.hw, ky0, r0.z)
		var kr0o := Vector3(r0.hw + kerb_w, ky0, r0.z)
		var kr1i := Vector3(r1.hw, ky1, r1.z)
		var kr1o := Vector3(r1.hw + kerb_w, ky1, r1.z)
		_emit_tri(st_kerb_r, kr0i, kr0o, kr1o, Vector3.UP)
		_emit_tri(st_kerb_r, kr0i, kr1o, kr1i, Vector3.UP)

	# 路面底面 (让坡道有厚度, 从下面看也有东西) — 单列
	for i in range(SEGMENTS):
		var r0 = rings[i]
		var r1 = rings[i + 1]
		var bot_offset: float = -ROAD_THICKNESS
		var b0l := Vector3(-r0.hw, r0.y + bot_offset, r0.z)
		var b0r := Vector3(r0.hw, r0.y + bot_offset, r0.z)
		var b1l := Vector3(-r1.hw, r1.y + bot_offset, r1.z)
		var b1r := Vector3(r1.hw, r1.y + bot_offset, r1.z)
		_emit_tri(st, b0r, b0l, b1l, Vector3.DOWN)
		_emit_tri(st, b0r, b1l, b1r, Vector3.DOWN)

	# 提交路面 mesh
	var road_mi := MeshInstance3D.new()
	road_mi.name = "RoadMesh"
	road_mi.mesh = st.commit()
	add_child(road_mi)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		road_mi.owner = get_tree().edited_scene_root

	# ============================================================
	# 碰撞: 参考青花瓷地图, 用高质量正方形三角形 trimesh (v9)
	# ============================================================
	# 单独生成碰撞专用 mesh (不显示), 三角形接近正方形
	# 然后 create_trimesh_collision() (跟青花瓷完全一样的做法)
	# ============================================================
	var st_col := SurfaceTool.new()
	st_col.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 动态计算宽度列数: 让三角形接近正方形
	var seg_len_c: float = length / float(COLLISION_SEGMENTS)
	var avg_w_c: float = (entry_width + exit_width) * 0.5
	var col_cols_c: int = maxi(4, roundi(avg_w_c / seg_len_c))
	for ci in range(COLLISION_SEGMENTS):
		var ct0: float = float(ci) / float(COLLISION_SEGMENTS)
		var ct1: float = float(ci + 1) / float(COLLISION_SEGMENTS)
		var cz0: float = hl - ct0 * length
		var cz1: float = hl - ct1 * length
		var cy0: float = _height_at_t(ct0) + top_y
		var cy1: float = _height_at_t(ct1) + top_y
		var chw0: float = lerpf(entry_width * 0.5, exit_width * 0.5, ct0)
		var chw1: float = lerpf(entry_width * 0.5, exit_width * 0.5, ct1)
		var cn0: Vector3 = _normal_at_t(ct0)
		var cn1: Vector3 = _normal_at_t(ct1)
		var cn_avg: Vector3 = ((cn0 + cn1) * 0.5).normalized()
		for cj in range(col_cols_c):
			var u0: float = float(cj) / float(col_cols_c)
			var u1: float = float(cj + 1) / float(col_cols_c)
			var cx0_l: float = lerpf(-chw0, chw0, u0)
			var cx0_r: float = lerpf(-chw0, chw0, u1)
			var cx1_l: float = lerpf(-chw1, chw1, u0)
			var cx1_r: float = lerpf(-chw1, chw1, u1)
			var cp0l := Vector3(cx0_l, cy0, cz0)
			var cp0r := Vector3(cx0_r, cy0, cz0)
			var cp1l := Vector3(cx1_l, cy1, cz1)
			var cp1r := Vector3(cx1_r, cy1, cz1)
			_emit_tri(st_col, cp0l, cp0r, cp1r, cn_avg)
			_emit_tri(st_col, cp0l, cp1r, cp1l, cn_avg)
	# 提交碰撞 mesh (隐藏, 只用于生成 trimesh 碰撞)
	var col_mi := MeshInstance3D.new()
	col_mi.name = "CollisionMesh"
	col_mi.mesh = st_col.commit()
	col_mi.visible = false
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

	# 中心装饰带 mesh
	var pat_mi := MeshInstance3D.new()
	pat_mi.name = "PatternMesh"
	pat_mi.mesh = st_pat.commit()
	add_child(pat_mi)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		pat_mi.owner = get_tree().edited_scene_root

	# 路缘 mesh
	var kerb_l_mi := MeshInstance3D.new()
	kerb_l_mi.name = "KerbLeftMesh"
	kerb_l_mi.mesh = st_kerb_l.commit()
	add_child(kerb_l_mi)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		kerb_l_mi.owner = get_tree().edited_scene_root
	var kerb_r_mi := MeshInstance3D.new()
	kerb_r_mi.name = "KerbRightMesh"
	kerb_r_mi.mesh = st_kerb_r.commit()
	add_child(kerb_r_mi)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		kerb_r_mi.owner = get_tree().edited_scene_root

	# 墙 (如果 wall_height > 0)
	_build_ramp_walls(rings)

	# ============================================================
	# 入口/出口锚点
	# ============================================================
	entry_anchor = Marker3D.new()
	entry_anchor.name = "EntryAnchor"
	entry_anchor.position = Vector3(0.0, 0.0, hl)
	add_child(entry_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		entry_anchor.owner = get_tree().edited_scene_root

	exit_anchor = Marker3D.new()
	exit_anchor.name = "ExitAnchor"
	exit_anchor.position = Vector3(0.0, height, -hl)
	add_child(exit_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		exit_anchor.owner = get_tree().edited_scene_root


## 构建坡道两侧墙 (沿曲面高度变化)
func _build_ramp_walls(rings: Array) -> void:
	if wall_height < 0.05:
		return
	for sign_x: float in [-1.0, 1.0]:
		var st_wall := SurfaceTool.new()
		st_wall.begin(Mesh.PRIMITIVE_TRIANGLES)
		st_wall.set_material(_make_wall_material())
		var n: Vector3 = Vector3(-sign_x, 0.0, 0.0)
		for i in range(SEGMENTS):
			var r0 = rings[i]
			var r1 = rings[i + 1]
			var x0: float = sign_x * r0.hw
			var x1: float = sign_x * r1.hw
			var bot0: float = r0.y
			var bot1: float = r1.y
			var top0: float = r0.y + wall_height
			var top1: float = r1.y + wall_height
			var pb0 := Vector3(x0, bot0, r0.z)
			var pt0 := Vector3(x0, top0, r0.z)
			var pb1 := Vector3(x1, bot1, r1.z)
			var pt1 := Vector3(x1, top1, r1.z)
			_emit_tri(st_wall, pb0, pt0, pt1, n)
			_emit_tri(st_wall, pb0, pt1, pb1, n)
		var wall_mi := MeshInstance3D.new()
		wall_mi.name = "Wall_%s" % ("L" if sign_x < 0 else "R")
		wall_mi.mesh = st_wall.commit()
		add_child(wall_mi)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			wall_mi.owner = get_tree().edited_scene_root
		# 墙碰撞
		wall_mi.create_trimesh_collision()