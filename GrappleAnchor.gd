@tool
extends Node3D
class_name GrappleAnchor
## ============================================================
##  钩索锚点 (Apex 探路者风格)
##  - 编辑器友好: @tool 脚本, 实时可视化, 编辑器里调位置即所见即所得
##  - 自动加入 "grapple_anchors" 组, GrappleHook 通过 group 全局检索
##  - 子节点结构 (代码生成, 不需要手动加):
##      MeshInstance3D ("Vis")  : 发光球, 让玩家在场景里能看到锚点
##      Area3D ("Detect")        : "玩家进入此球范围才能瞄准"的检测区
##  - 编辑器内修改 anchor_radius / detect_radius 会立即重建可视化球
## ============================================================

## 视觉球半径 (米). 越大锚点越显眼
@export var anchor_radius: float = 1.5: set = _set_anchor_radius
## 玩家进入此球形范围才能瞄准本锚点 (米). 必须 >= anchor_radius
## 数学: 玩家车距 < detect_radius → 进入"可瞄准"列表
##       超出 max_distance(GrappleHook 里设) 也不能钩
@export var detect_radius: float = 25.0: set = _set_detect_radius
## 锚点发光颜色 (HDR, modulate ×1.5 当 emission 用)
@export var anchor_color: Color = Color(0.3, 0.85, 1.0, 1.0): set = _set_anchor_color
## "高亮模式" - 玩家瞄准本锚点时 GrappleHook 会调这个 setter 切到高亮色
## 内部状态, 不在 inspector 暴露
var _highlighted: bool = false

# 内部节点引用 (代码生成, 第一次 _ready 创建)
var _vis_mesh: MeshInstance3D = null
var _detect_area: Area3D = null
var _detect_collider: CollisionShape3D = null


func _ready() -> void:
	# group 注册 - 让 GrappleHook 用 get_nodes_in_group 全局找
	if not is_in_group("grapple_anchors"):
		add_to_group("grapple_anchors")
	_ensure_visuals()


# ------------------------------------------------------------
# 视觉构建 (代码生成 MeshInstance3D + Area3D, 不需要手动 .tscn)
# 这样 GrappleAnchor.tscn 可以是个空 Node3D + 脚本, 直接 instance 即可
# ------------------------------------------------------------
func _ensure_visuals() -> void:
	# 视觉球 (发光锚点)
	if _vis_mesh == null:
		_vis_mesh = get_node_or_null("Vis") as MeshInstance3D
	if _vis_mesh == null:
		_vis_mesh = MeshInstance3D.new()
		_vis_mesh.name = "Vis"
		add_child(_vis_mesh)
		# 编辑器中也要可见, 设 owner 让它跟着场景保存
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			_vis_mesh.owner = get_tree().edited_scene_root
	_rebuild_vis_mesh()

	# Area3D 检测玩家是否进入瞄准范围 (运行时才用, 编辑器里也建好但不必连信号)
	if _detect_area == null:
		_detect_area = get_node_or_null("Detect") as Area3D
	if _detect_area == null:
		_detect_area = Area3D.new()
		_detect_area.name = "Detect"
		_detect_area.monitoring = false   # GrappleHook 用主动距离判定, 不依赖信号
		_detect_area.monitorable = false
		add_child(_detect_area)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			_detect_area.owner = get_tree().edited_scene_root
	if _detect_collider == null:
		_detect_collider = _detect_area.get_node_or_null("Shape") as CollisionShape3D
	if _detect_collider == null:
		_detect_collider = CollisionShape3D.new()
		_detect_collider.name = "Shape"
		_detect_area.add_child(_detect_collider)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			_detect_collider.owner = get_tree().edited_scene_root
	_rebuild_detect_shape()


func _rebuild_vis_mesh() -> void:
	if _vis_mesh == null:
		return
	# 球体 mesh
	var sphere := SphereMesh.new()
	sphere.radius = anchor_radius
	sphere.height = anchor_radius * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	_vis_mesh.mesh = sphere
	# 发光材质 (HDR emission, 即使在白天也很显眼)
	var mat := StandardMaterial3D.new()
	var col := anchor_color
	if _highlighted:
		# 高亮: 颜色变金, 强度更高
		col = Color(1.0, 0.85, 0.25, 1.0)
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 2.5 if _highlighted else 1.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # 让球永远很亮, 不被光照影响
	_vis_mesh.material_override = mat


func _rebuild_detect_shape() -> void:
	if _detect_collider == null:
		return
	var shape := SphereShape3D.new()
	shape.radius = maxf(detect_radius, anchor_radius)
	_detect_collider.shape = shape


func _set_anchor_radius(v: float) -> void:
	anchor_radius = maxf(0.1, v)
	_rebuild_vis_mesh()


func _set_detect_radius(v: float) -> void:
	detect_radius = maxf(anchor_radius, v)
	_rebuild_detect_shape()


func _set_anchor_color(c: Color) -> void:
	anchor_color = c
	_rebuild_vis_mesh()


# ------------------------------------------------------------
# 高亮 API (供 GrappleHook 在选中本锚点时调用)
# ------------------------------------------------------------
func set_highlighted(on: bool) -> void:
	if _highlighted == on:
		return
	_highlighted = on
	_rebuild_vis_mesh()


# ------------------------------------------------------------
# 编辑器 Gizmo (运行时也保留, 看起来更醒目)
# ------------------------------------------------------------
func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		# 运行时让锚点缓慢自转 + 上下浮动, 视觉更醒目
		if _vis_mesh:
			_vis_mesh.rotation.y += delta * 0.8
			# 浮动动画: ±0.15m
			_vis_mesh.position.y = sin(Time.get_ticks_msec() / 600.0) * 0.15
