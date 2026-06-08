@tool
extends Node3D
class_name TrackBlock
## ============================================================
##  赛道积木基类 (青花瓷风格, 程序化 mesh + StaticBody 碰撞)
##
##  每块积木提供:
##   · 程序化生成的路面 mesh (BoxMesh / 弯道用 ArrayMesh)
##   · StaticBody3D + CollisionShape3D 物理
##   · EntryAnchor (Marker3D) 入口锚点 — 朝向 +Z (车从 +Z 进来)
##   · ExitAnchor (Marker3D)  出口锚点 — 朝向 -Z (车从 -Z 出去)
##   · @export block_id: 标识符, 保存赛道时用
##
##  磁吸对齐数学:
##   · 拼接两块时, 让 newBlock.EntryAnchor.global_transform == prevBlock.ExitAnchor.global_transform
##   · 即:  new_block.global_transform = prev.ExitAnchor.global_transform × EntryAnchor.transform.inverse()
##
##  约定 (重要!):
##   · 每块积木的本地坐标系: 入口在 (0, 0, +Z_half), 出口在 (0, 0, -Z_half) 或弯道终点
##   · 路面厚度: 默认 0.3 米 (够车球碰撞探测)
##   · 路面宽度: 8 米 (够 2 辆车并行)
##   · 颜色: 青花瓷 — 路面 #f5f7fb (米白) + 中心带状纹饰 #1e4d8a (深蓝)
## ============================================================

## 积木 ID, 用于 RaceTrackData 序列化
@export var block_id: String = ""

## 入口路宽 (米). 默认 25m = 10 车宽 (一辆车 ≈ 2.5m)
## 用户要求: 基础标准提到 25m, 让车在赛道里跑得开 (旧默认 15m 太窄, 弯道几乎贴墙)
## 每个 Block 子类都可以覆盖, 也可以让玩家通过编辑器调
##
## setter clamp 策略 (2026-06-02 高压线):
##   只做"防崩溃硬极限" (0.05 ~ 1000), 让玩家在弹窗里扩展 min/max 后能输入任意合理值
##   UI 默认友好范围由 get_editable_params() 的 min/max 控制 (3~80, 旧值)
##   旧版 clampf(v, 0.001, 100000.0) 把 setter 也卡死 → 弹窗改了 min 也没用 → 违反高压线
@export var entry_width: float = 25.0:
	set(v):
		entry_width = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			rebuild()
## 出口路宽 (米). 与 entry_width 不同时实现"路宽渐变"(锥形赛道)
@export var exit_width: float = 25.0:
	set(v):
		exit_width = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			rebuild()
## 两侧墙的高度 (米). 0 = 无墙(只有路缘), >0 = 加垂直墙防止车飞出
@export var wall_height: float = 2.5:
	set(v):
		wall_height = clampf(v, 0.001, 100000.0)
		if is_inside_tree():
			rebuild()

# ============================================================
# 部分墙面开关 (用户要求"取消部分墙面")
# 把整段路面墙拆成 4 块: 左/右 × 入口段(前半)/出口段(后半)
# 玩家可以独立打开/关掉任一块, 做"半段开口"让车飞出去
# 全 true = 整段两侧墙都有 (默认, 兼容旧赛道)
# 全 false = 完全没墙
# 单独开比如 wall_left_in=true 其他 false → 只有左墙的前半段
# ============================================================
@export var wall_left_in: bool = true:
	set(v):
		wall_left_in = v
		if is_inside_tree():
			rebuild()
@export var wall_left_out: bool = true:
	set(v):
		wall_left_out = v
		if is_inside_tree():
			rebuild()
@export var wall_right_in: bool = true:
	set(v):
		wall_right_in = v
		if is_inside_tree():
			rebuild()
@export var wall_right_out: bool = true:
	set(v):
		wall_right_out = v
		if is_inside_tree():
			rebuild()

# 共享常量 (子类用)
# ROAD_WIDTH 现在是"默认路宽", 实际路宽由 entry_width/exit_width 决定
# 用户要求: 基础宽度 15m → 25m, 弯道半径 12m → 20m, 让赛车跑得开
const ROAD_WIDTH: float = 25.0
const DEFAULT_TURN_RADIUS: float = 20.0
const ROAD_THICKNESS: float = 0.3
const COLOR_ROAD: Color = Color(0.96, 0.97, 0.99)         # 青花瓷白
const COLOR_PATTERN: Color = Color(0.12, 0.30, 0.55)      # 青花瓷蓝
const COLOR_KERB: Color = Color(0.88, 0.10, 0.10)         # 路缘红 (经典赛道路缘)

# 入口/出口节点 (子类构建时 add)
var entry_anchor: Marker3D = null
var exit_anchor: Marker3D = null


func _ready() -> void:
	# 子类应在它们自己的 _ready 里 build_geometry()
	pass


# ------------------------------------------------------------
#  共享工具函数
# ------------------------------------------------------------

## 用 BoxMesh 创建一段路面 + 碰撞 + 材质
##   length_z : Z 方向长度 (米)
##   parent   : 把 mesh 节点挂到哪个父节点, 默认 self
##   transform: 路面相对父节点的额外变换 (默认 IDENTITY)
##   返回 [MeshInstance3D, StaticBody3D]
## 用 SurfaceTool 创建一段路面 + 碰撞 + 材质 (支持 entry/exit 不同宽度的渐变路面)
##   length_z   : Z 方向长度 (米). 入口在 +Z=length/2, 出口在 -Z=length/2
##   parent     : 把 mesh 节点挂到哪个父节点, 默认 self
##   xform      : 路面相对父节点的额外变换 (默认 IDENTITY, 直道一般用 IDENTITY)
##   返回 [MeshInstance3D, StaticBody3D]
##
## 注意: entry_width 和 exit_width 是实例属性, 不需要参数. 渐变实现:
##   入口端 (z = +length/2) 的左右边缘 = ±entry_width/2
##   出口端 (z = -length/2) 的左右边缘 = ±exit_width/2
##   形成梯形 (上窄下宽 or 上宽下窄)
func _build_box_road_segment(length_z: float, parent: Node = self, xform: Transform3D = Transform3D.IDENTITY) -> Array:
	var hw_in: float = entry_width * 0.5
	var hw_out: float = exit_width * 0.5
	var hl: float = length_z * 0.5
	var top_y: float = ROAD_THICKNESS * 0.5
	var bot_y: float = -ROAD_THICKNESS * 0.5

	# 路面顶面 (双面渲染, 顶点顺序无所谓)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_make_road_material())
	# 入口端 (z = +hl): 左 (-hw_in, top, +hl), 右 (+hw_in, top, +hl)
	# 出口端 (z = -hl): 左 (-hw_out, top, -hl), 右 (+hw_out, top, -hl)
	var v_top_in_l := Vector3(-hw_in, top_y, hl)
	var v_top_in_r := Vector3(hw_in, top_y, hl)
	var v_top_out_l := Vector3(-hw_out, top_y, -hl)
	var v_top_out_r := Vector3(hw_out, top_y, -hl)
	# 顶面 quad: in_l, in_r, out_r, out_l
	_emit_tri(st, v_top_in_l, v_top_in_r, v_top_out_r, Vector3.UP)
	_emit_tri(st, v_top_in_l, v_top_out_r, v_top_out_l, Vector3.UP)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	parent.add_child(mi)
	mi.transform = xform
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		mi.owner = get_tree().edited_scene_root

	# 物理碰撞: 梯形 → 用 ConvexPolygonShape3D (8 个顶点的凸盒)
	# 8 个顶点: 入口/出口 × 左/右 × 顶/底 = 8
	var body := StaticBody3D.new()
	parent.add_child(body)
	body.transform = xform
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		body.owner = get_tree().edited_scene_root
	var col := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		v_top_in_l, v_top_in_r, v_top_out_l, v_top_out_r,
		Vector3(-hw_in, bot_y, hl), Vector3(hw_in, bot_y, hl),
		Vector3(-hw_out, bot_y, -hl), Vector3(hw_out, bot_y, -hl),
	])
	col.shape = shape
	body.add_child(col)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		col.owner = get_tree().edited_scene_root
	return [mi, body]


# 给 SurfaceTool 加一个三角形 (3 顶点 + 法向)
# 双面渲染下不用太担心 winding, set_normal 给的法向供 lighting 用
func _emit_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	st.set_normal(n); st.add_vertex(a)
	st.set_normal(n); st.add_vertex(b)
	st.set_normal(n); st.add_vertex(c)


## 创建路缘 (沿 X 方向两侧的红白条纹) — 直道版本, 支持 entry/exit 宽度渐变
##   length_z, parent, xform 同上
##
## 用户需求 (2026-06-02): "所有直道都不需要两侧红色的路沿(可以留有颜色 但是不要有高度)"
## 修复: 把 kerb_y 从 ROAD_THICKNESS*0.5 + 0.075 (凸出 7.5cm) 改成 + 0.002 (贴地 2mm)
##       2mm 偏移只是为了防止 z-fighting (跟路面同 Y 平面会闪烁), 视觉上完全是平的
##       车开过路缘时不再被凸起的 7.5cm 弹一下, 红白颜色装饰仍然保留
func _build_kerbs(length_z: float, parent: Node = self, xform: Transform3D = Transform3D.IDENTITY) -> void:
	# 注: 数组字面量 [-1.0, 1.0] 会被推断为 Array (Variant), 循环变量类型未知 → 编译报错
	# 解决: 显式声明 sign_x: float, 让类型检查通过
	# 路缘宽度 0.5m, 在路面外侧
	for sign_x: float in [-1.0, 1.0]:
		var hw_in: float = entry_width * 0.5
		var hw_out: float = exit_width * 0.5
		var hl: float = length_z * 0.5
		var kerb_w: float = 0.5
		# kerb_y: 紧贴路面顶部, 仅 +2mm 防止 z-fighting (旧版 +7.5cm 凸出, 用户反馈"不要高度")
		var kerb_y: float = ROAD_THICKNESS * 0.5 + 0.002
		# 路缘是一个梯形薄板, 沿路面外边缘
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(_make_kerb_material())
		# 路面外缘 (in/out) → 路缘外缘 (in/out)
		var p_in_inner := Vector3(sign_x * hw_in, kerb_y, hl)
		var p_in_outer := Vector3(sign_x * (hw_in + kerb_w), kerb_y, hl)
		var p_out_inner := Vector3(sign_x * hw_out, kerb_y, -hl)
		var p_out_outer := Vector3(sign_x * (hw_out + kerb_w), kerb_y, -hl)
		_emit_tri(st, p_in_inner, p_in_outer, p_out_outer, Vector3.UP)
		_emit_tri(st, p_in_inner, p_out_outer, p_out_inner, Vector3.UP)
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		parent.add_child(mi)
		mi.transform = xform
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			mi.owner = get_tree().edited_scene_root


## 创建两侧高墙 (防止车飞出) — 直道版本, 支持渐变 + 高度 + **部分墙面开关**
## wall_height = 0 时不画
##   length_z, parent, xform 同上
## 用户要求: 可以单独取消左/右 × 入/出口段, 做"半段开口"让车飞出去
##   wall_left_in / wall_left_out / wall_right_in / wall_right_out 控制 4 段
##   实现: 一条整墙拆成"入口端→中点"+"中点→出口端"两段, 每段单独决定要不要画
func _build_walls(length_z: float, parent: Node = self, xform: Transform3D = Transform3D.IDENTITY) -> void:
	if wall_height < 0.05:
		return
	# 4 段开关查表 (sign_x → in/out 段 → bool)
	# sign_x = -1 = 左墙 (look from above, -X 边); +1 = 右墙
	var enable_table: Dictionary = {
		Vector2(-1.0, 0.0): wall_left_in,    # 左 + 入口段
		Vector2(-1.0, 1.0): wall_left_out,   # 左 + 出口段
		Vector2(1.0, 0.0):  wall_right_in,   # 右 + 入口段
		Vector2(1.0, 1.0):  wall_right_out,  # 右 + 出口段
	}
	# 用户要求: 墙段在编辑器场景里可点击切换 (有/无). 实现:
	# 不管 enable=true/false 都生成"点击命中盒" (Area3D + meta), 但只有 enable=true 时才生成
	# 实体墙 mesh + 碰撞. 点击命中盒会被 _pick_placed_block_at_mouse 识别, 然后由编辑器调
	# set_wall_segment_enabled() 切换.
	for sign_x: float in [-1.0, 1.0]:
		# 沿 Z 把墙分成两段 (入口端 hl→0, 出口端 0→-hl)
		# z_start, z_end, is_out_segment(0=in, 1=out)
		var segments: Array = [
			[length_z * 0.5,  0.0,             0.0],   # 入口端
			[0.0,             -length_z * 0.5, 1.0],   # 出口端
		]
		for seg in segments:
			var z_a: float = float(seg[0])
			var z_b: float = float(seg[1])
			var seg_kind: float = float(seg[2])
			var enabled: bool = bool(enable_table.get(Vector2(sign_x, seg_kind), true))
			# 始终生成"点击命中盒" (含元信息), 让编辑器能 raycast 命中
			_emit_wall_pick_box(sign_x, z_a, z_b, length_z, seg_kind, parent, xform)
			# 只在启用时生成实体墙 mesh + 物理碰撞
			if enabled:
				_emit_wall_segment(sign_x, z_a, z_b, length_z, parent, xform)


# 生成墙段的"点击命中盒" — 一个 Area3D + 浅色框线 mesh, 用于编辑器内点击识别
# Area3D 不参与物理 (collision_layer=独立通道, mask=0), 仅用于 raycast 命中
# meta:
#   is_wall_pick: true (识别)
#   wall_side: -1.0=左, +1.0=右
#   wall_seg:  0.0=入口段, 1.0=出口段
# 这个命中盒**始终**生成 (不论墙是否启用), 让玩家能"加回墙": 点击空缺位置也能命中
func _emit_wall_pick_box(sign_x: float, z_a: float, z_b: float, length_z: float, seg_kind: float, parent: Node, xform: Transform3D) -> void:
	var hl: float = length_z * 0.5
	var t_a: float = clampf((hl - z_a) / maxf(length_z, 0.001), 0.0, 1.0)
	var t_b: float = clampf((hl - z_b) / maxf(length_z, 0.001), 0.0, 1.0)
	var hw_a: float = lerpf(entry_width * 0.5, exit_width * 0.5, t_a)
	var hw_b: float = lerpf(entry_width * 0.5, exit_width * 0.5, t_b)
	var top_y: float = ROAD_THICKNESS * 0.5
	var wall_top_y: float = top_y + wall_height
	var p_a_b := Vector3(sign_x * hw_a, top_y, z_a)        # 入口侧底
	var p_a_t := Vector3(sign_x * hw_a, wall_top_y, z_a)   # 入口侧顶
	var p_b_b := Vector3(sign_x * hw_b, top_y, z_b)        # 出口侧底
	var p_b_t := Vector3(sign_x * hw_b, wall_top_y, z_b)   # 出口侧顶
	var area := Area3D.new()
	area.name = "WallPick_%s_%s" % ["L" if sign_x < 0 else "R", "in" if seg_kind < 0.5 else "out"]
	area.set_meta("is_wall_pick", true)
	area.set_meta("wall_side", sign_x)
	area.set_meta("wall_seg", seg_kind)
	# 用独立 layer 通道避免和车物理碰撞冲突. layer=1<<6=64 (第 7 位), 跟加速带的 1<<5 也不冲突
	area.collision_layer = 1 << 6
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = false
	parent.add_child(area)
	area.transform = xform
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		area.owner = get_tree().edited_scene_root
	var col := CollisionShape3D.new()
	var sh := ConvexPolygonShape3D.new()
	# 命中盒比墙稍微凸出一点 (0.4m) 让玩家更好点中
	var thick: float = 0.4
	var p_a_b_o := p_a_b + Vector3(sign_x * thick, 0.0, 0.0)
	var p_a_t_o := p_a_t + Vector3(sign_x * thick, 0.0, 0.0)
	var p_b_b_o := p_b_b + Vector3(sign_x * thick, 0.0, 0.0)
	var p_b_t_o := p_b_t + Vector3(sign_x * thick, 0.0, 0.0)
	sh.points = PackedVector3Array([
		p_a_b, p_a_t, p_b_b, p_b_t,
		p_a_b_o, p_a_t_o, p_b_b_o, p_b_t_o,
	])
	col.shape = sh
	area.add_child(col)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		col.owner = get_tree().edited_scene_root


# 切换某段墙的启用状态 (编辑器点击墙段时调)
# side: -1=左, +1=右; seg: 0=入口, 1=出口
# 切换后调 rebuild() 重新生成墙
func set_wall_segment_enabled(side: float, seg: float, enabled: bool) -> void:
	if side < 0:
		if seg < 0.5:
			wall_left_in = enabled
		else:
			wall_left_out = enabled
	else:
		if seg < 0.5:
			wall_right_in = enabled
		else:
			wall_right_out = enabled


# 切换某段墙 (编辑器点击墙段时调). 不传 enabled = toggle 当前值
func toggle_wall_segment(side: float, seg: float) -> void:
	var cur: bool = false
	if side < 0:
		cur = wall_left_in if seg < 0.5 else wall_left_out
	else:
		cur = wall_right_in if seg < 0.5 else wall_right_out
	set_wall_segment_enabled(side, seg, not cur)


# 生成一段墙 (4 顶点 + 物理碰撞), 给 _build_walls 内部用
# z_a, z_b 是该段在本地 Z 的起止 (z_a 在入口侧, z_b 在出口侧, z_a > z_b)
# 整段长度 length_z 用于按 Z 比例 lerp 路宽渐变 (entry/exit_width)
func _emit_wall_segment(sign_x: float, z_a: float, z_b: float, length_z: float, parent: Node, xform: Transform3D) -> void:
	# Z 在 [-hl, +hl] 区间内对应宽度 lerp(entry, exit)
	var hl: float = length_z * 0.5
	var t_a: float = clampf((hl - z_a) / maxf(length_z, 0.001), 0.0, 1.0)   # 入口=0, 出口=1
	var t_b: float = clampf((hl - z_b) / maxf(length_z, 0.001), 0.0, 1.0)
	var hw_a: float = lerpf(entry_width * 0.5, exit_width * 0.5, t_a)
	var hw_b: float = lerpf(entry_width * 0.5, exit_width * 0.5, t_b)
	var top_y: float = ROAD_THICKNESS * 0.5
	var wall_top_y: float = top_y + wall_height
	var p_a_b := Vector3(sign_x * hw_a, top_y, z_a)        # 入口侧底
	var p_a_t := Vector3(sign_x * hw_a, wall_top_y, z_a)   # 入口侧顶
	var p_b_b := Vector3(sign_x * hw_b, top_y, z_b)        # 出口侧底
	var p_b_t := Vector3(sign_x * hw_b, wall_top_y, z_b)   # 出口侧顶
	var n: Vector3 = Vector3(-sign_x, 0.0, 0.0)            # 朝内的 normal
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_make_wall_material())
	_emit_tri(st, p_a_b, p_a_t, p_b_t, n)
	_emit_tri(st, p_a_b, p_b_t, p_b_b, n)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	parent.add_child(mi)
	mi.transform = xform
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		mi.owner = get_tree().edited_scene_root
	# 物理碰撞 (薄盒 ConvexPolygon, 向外扩 wall_thick)
	var wall_thick: float = 0.3
	var p_a_b_o := p_a_b + Vector3(sign_x * wall_thick, 0.0, 0.0)
	var p_a_t_o := p_a_t + Vector3(sign_x * wall_thick, 0.0, 0.0)
	var p_b_b_o := p_b_b + Vector3(sign_x * wall_thick, 0.0, 0.0)
	var p_b_t_o := p_b_t + Vector3(sign_x * wall_thick, 0.0, 0.0)
	var body := StaticBody3D.new()
	parent.add_child(body)
	body.transform = xform
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		body.owner = get_tree().edited_scene_root
	var col := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		p_a_b, p_a_t, p_b_b, p_b_t,
		p_a_b_o, p_a_t_o, p_b_b_o, p_b_t_o,
	])
	col.shape = shape
	body.add_child(col)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		col.owner = get_tree().edited_scene_root


## 创建中心装饰带 (青花瓷蓝色细带, 模拟瓷器纹饰)
func _build_center_pattern(length_z: float, parent: Node = self, xform: Transform3D = Transform3D.IDENTITY) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.6, 0.02, length_z * 0.95)   # 略短, 看起来更精致
	mi.mesh = mesh
	mi.material_override = _make_pattern_material()
	parent.add_child(mi)
	# 路面顶面之上 1cm, 避免 z-fighting
	mi.transform = xform * Transform3D(Basis(), Vector3(0.0, ROAD_THICKNESS * 0.5 + 0.011, 0.0))
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		mi.owner = get_tree().edited_scene_root


## 创建入口/出口 Marker3D
##   entry 在 +Z, 朝 +Z (车从 +Z 进来 → 车头朝 -Z, 即朝 entry 内部)
##   exit  在 -Z, 朝 -Z
func _build_entry_exit(half_z: float) -> void:
	entry_anchor = Marker3D.new()
	entry_anchor.name = "EntryAnchor"
	entry_anchor.position = Vector3(0.0, 0.0, half_z)
	# entry 朝向: 车从 +Z 来, 进入积木后车头朝 -Z. Marker3D basis -Z = "前进方向"
	# 默认 Marker basis 就是 -Z 朝前, 我们让 entry 的 -Z 指向 -Z (积木内部) → 不需要 rotate
	add_child(entry_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		entry_anchor.owner = get_tree().edited_scene_root

	exit_anchor = Marker3D.new()
	exit_anchor.name = "ExitAnchor"
	exit_anchor.position = Vector3(0.0, 0.0, -half_z)
	# exit 朝向: 车出去后还是朝 -Z, 所以 exit basis -Z 也指向 -Z, 同样不 rotate
	add_child(exit_anchor)
	if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
		exit_anchor.owner = get_tree().edited_scene_root


# ------------------------------------------------------------
#  材质 (青花瓷风)
# ------------------------------------------------------------
func _make_road_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = COLOR_ROAD
	m.roughness = 0.55
	m.metallic = 0.0
	# 双面渲染: 弯道用 ArrayMesh 时 winding order 容易反, 关掉 culling 可以保证两面都可见
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _make_kerb_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = COLOR_KERB
	m.roughness = 0.4
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _make_pattern_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = COLOR_PATTERN
	m.roughness = 0.3
	m.emission_enabled = true
	m.emission = COLOR_PATTERN
	m.emission_energy_multiplier = 0.3
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## 墙的材质 (深蓝色, 轻微透明感, 让玩家看到路两侧但不挡视线)
func _make_wall_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.20, 0.35, 0.55, 0.8)   # 半透明深青蓝
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.6
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


# ------------------------------------------------------------
#  公共接口 (供 TrackEditor 用)
# ------------------------------------------------------------

## 返回入口锚点的世界 transform (磁吸对齐用)
func get_entry_world_transform() -> Transform3D:
	if entry_anchor == null:
		return global_transform
	return entry_anchor.global_transform

## 返回出口锚点的世界 transform
func get_exit_world_transform() -> Transform3D:
	if exit_anchor == null:
		return global_transform
	return exit_anchor.global_transform

## 给定"前一块的出口锚点世界 transform", 返回"本块应该放置到的世界 transform"
## 数学: new_block.global = prev.exit_world × EntryAnchor.local.inverse()
func compute_attach_transform(prev_exit_world: Transform3D) -> Transform3D:
	if entry_anchor == null:
		return prev_exit_world
	# entry_anchor 是 self 的子节点, 它的 transform (相对 self) 就是入口锚点的本地变换
	var entry_local: Transform3D = entry_anchor.transform
	return prev_exit_world * entry_local.inverse()


# ------------------------------------------------------------
#  可编辑参数接口 (供 TrackEditor 选中面板用)
# ------------------------------------------------------------
## 返回此积木暴露的可编辑参数列表
## 每项格式: {"key": String, "label": String, "min": float, "max": float, "step": float, "value": float}
##   key   : 参数名 (例如 "length"/"angle"/"radius"/"slope_total_deg")
##   label : UI 显示文字
##   min/max/step: SpinBox 范围
##   value : 当前值
##
## 子类应该覆盖此函数返回自己的参数集.
## 默认返回空数组 = "这个积木没有可编辑参数"
func get_editable_params() -> Array:
	return []


## 设置某个可编辑参数. 子类应覆盖, 改完字段后调 rebuild() 重新生成 mesh
## 默认空实现 (不报错, 让基类调用安全)
func set_editable_param(_key: String, _value: float) -> void:
	pass


## 重新生成 mesh + 入口/出口锚点
## 子类覆盖, 默认: 清空所有子节点 → 重新调 _ready 里的构建逻辑
func rebuild() -> void:
	# 清掉所有子节点 (mesh + 碰撞 + 入口/出口锚点)
	for c in get_children():
		c.queue_free()
	entry_anchor = null
	exit_anchor = null
	# 子类应覆盖 rebuild 在清空后调自己的 _build_xxx 函数
