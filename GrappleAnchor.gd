@tool
extends Node3D
class_name GrappleAnchor
## ============================================================
##  钩索锚点 — 使用自定义 FBX 无人机模型
##  - 编辑器友好: @tool 脚本, 实时可视化, 编辑器里调位置即所见即所得
##  - 自动加入 "grapple_anchors" 组, GrappleHook 通过 group 全局检索
##  - 子节点结构 (代码生成, 不需要手动加):
##      Node3D ("Vis")           : FBX 模型实例 (无人机 + 等离子体特效)
##      Area3D ("Detect")        : "玩家进入此球范围才能瞄准"的检测区
##  - 编辑器内修改 anchor_radius / detect_radius 会立即重建
## ============================================================

## FBX 模型路径
const ANCHOR_MODEL_PATH: String = "res://assets/custom_objs/钩索锚点/钩索锚点.fbx"

## 模型缩放系数 (调整模型大小以匹配 anchor_radius)
@export var anchor_radius: float = 1.5: set = _set_anchor_radius
## 玩家进入此球形范围才能瞄准本锚点 (米). 必须 >= anchor_radius
## 数学: 玩家车距 < detect_radius → 进入"可瞄准"列表
##       超出 max_distance(GrappleHook 里设) 也不能钩
## 注意: 此值应 >= GrappleHook.max_distance(默认40m), 否则会限制实际射程
@export var detect_radius: float = 60.0: set = _set_detect_radius
## 锚点发光颜色 (用于高亮时的 modulate 叠加)
@export var anchor_color: Color = Color(0.3, 0.85, 1.0, 1.0): set = _set_anchor_color
## "高亮模式" - 玩家瞄准本锚点时 GrappleHook 会调这个 setter 切到高亮色
## 内部状态, 不在 inspector 暴露
var _highlighted: bool = false

# 内部节点引用 (代码生成, 第一次 _ready 创建)
var _vis_root: Node3D = null           # FBX 模型实例根节点
var _detect_area: Area3D = null
var _detect_collider: CollisionShape3D = null
# 缓存模型中的 MeshInstance3D 列表 (用于高亮 modulate)
var _mesh_instances: Array[MeshInstance3D] = []


func _ready() -> void:
	# group 注册 - 让 GrappleHook 用 get_nodes_in_group 全局找
	if not is_in_group("grapple_anchors"):
		add_to_group("grapple_anchors")
	_ensure_visuals()


# ------------------------------------------------------------
# 视觉构建 (加载 FBX 模型 + Area3D 检测区)
# ------------------------------------------------------------
func _ensure_visuals() -> void:
	# 加载 FBX 模型
	if _vis_root == null:
		var existing: Node = get_node_or_null("Vis")
		if existing != null:
			# 检查是否是旧的 SphereMesh 球体 (MeshInstance3D 直接作为 Vis)
			# 新版 Vis 应该是 FBX 实例 (根节点是 Node3D, 子节点含多个 MeshInstance3D)
			if existing is MeshInstance3D:
				# 旧版球体, 删除它, 重新创建 FBX 模型
				existing.queue_free()
			else:
				_vis_root = existing as Node3D
	if _vis_root == null:
		var scene: PackedScene = load(ANCHOR_MODEL_PATH) as PackedScene
		if scene == null:
			push_error("[GrappleAnchor] 无法加载模型: %s" % ANCHOR_MODEL_PATH)
			return
		_vis_root = scene.instantiate()
		_vis_root.name = "Vis"
		add_child(_vis_root)
		if Engine.is_editor_hint() and get_tree() and get_tree().edited_scene_root:
			_vis_root.owner = get_tree().edited_scene_root
		# 移除 FBX 中自带的灯光 (太多灯光影响性能)
		_remove_lights(_vis_root)
	# 缓存所有 MeshInstance3D (用于高亮)
	_mesh_instances.clear()
	_collect_mesh_instances(_vis_root)
	# 应用缩放
	_apply_model_scale()

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


## 移除节点树中所有灯光节点 (FBX 自带的灯光太多, 运行时不需要)
func _remove_lights(node: Node) -> void:
	var to_remove: Array[Node] = []
	for child in node.get_children():
		if child is Light3D:
			to_remove.append(child)
		# 也移除灯光的 Target 节点 (名字含 _Target)
		elif child.name.ends_with("_Target"):
			to_remove.append(child)
		else:
			_remove_lights(child)
	for n in to_remove:
		n.queue_free()


## 递归收集所有 MeshInstance3D
func _collect_mesh_instances(node: Node) -> void:
	if node is MeshInstance3D:
		_mesh_instances.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_mesh_instances(child)


## 根据 anchor_radius 调整模型缩放 (FBX 原始大小约 1m, 按比例缩放)
func _apply_model_scale() -> void:
	if _vis_root == null:
		return
	# FBX 模型原始尺寸约 1m 左右, 用 anchor_radius 作为缩放因子
	# 基础缩放 2.5 (用户要求放大到 2.5 倍)
	var s: float = (anchor_radius / 1.5) * 2.5
	_vis_root.scale = Vector3(s, s, s)


func _rebuild_detect_shape() -> void:
	if _detect_collider == null:
		return
	var shape := SphereShape3D.new()
	shape.radius = maxf(detect_radius, anchor_radius)
	_detect_collider.shape = shape


func _set_anchor_radius(v: float) -> void:
	anchor_radius = maxf(0.1, v)
	_apply_model_scale()


func _set_detect_radius(v: float) -> void:
	detect_radius = maxf(anchor_radius, v)
	_rebuild_detect_shape()


func _set_anchor_color(c: Color) -> void:
	anchor_color = c
	_apply_highlight()


# ------------------------------------------------------------
# 高亮 API (供 GrappleHook 在选中本锚点时调用)
# ------------------------------------------------------------
func set_highlighted(on: bool) -> void:
	if _highlighted == on:
		return
	_highlighted = on
	_apply_highlight()


## 应用高亮效果: 通过 material_overlay 叠加发光层
func _apply_highlight() -> void:
	if _vis_root == null:
		return
	if _highlighted:
		# 高亮: 叠加金色半透明发光层
		var overlay := StandardMaterial3D.new()
		overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		overlay.albedo_color = Color(1.0, 0.85, 0.25, 0.4)
		overlay.emission_enabled = true
		overlay.emission = Color(1.0, 0.85, 0.25, 1.0)
		overlay.emission_energy_multiplier = 3.0
		overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		for mi in _mesh_instances:
			if is_instance_valid(mi):
				mi.material_overlay = overlay
	else:
		# 取消高亮: 移除 overlay
		for mi in _mesh_instances:
			if is_instance_valid(mi):
				mi.material_overlay = null


# ------------------------------------------------------------
# 运行时动画: 自转 + 浮动
# ------------------------------------------------------------
# ------------------------------------------------------------
# 被扯动画 (钩住时模型朝玩家方向被扯一下再回弹)
# ------------------------------------------------------------
var _tug_active: bool = false
var _tug_elapsed: float = 0.0
var _tug_duration: float = 0.3
var _tug_offset: Vector3 = Vector3.ZERO   # 当前帧的偏移量
var _tug_direction: Vector3 = Vector3.ZERO # 朝玩家的方向 (单位向量)
var _tug_max_dist: float = 2.0            # 最大被扯距离

## 播放被扯动画: 模型朝 player_pos 方向移动 tug_dist 米, 然后弹回
func play_tug_animation(player_pos: Vector3, tug_dist: float, tug_dur: float) -> void:
	if _vis_root == null:
		return
	_tug_direction = (player_pos - global_position).normalized()
	_tug_max_dist = tug_dist
	_tug_duration = maxf(0.05, tug_dur)
	_tug_elapsed = 0.0
	_tug_active = true


func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		# 运行时让锚点缓慢自转 + 上下浮动, 视觉更醒目
		if _vis_root:
			_vis_root.rotation.y += delta * 0.8
			# 浮动动画: ±0.15m
			var float_y: float = sin(Time.get_ticks_msec() / 600.0) * 0.15

			# 被扯动画叠加
			if _tug_active:
				_tug_elapsed += delta
				var t: float = _tug_elapsed / _tug_duration
				if t >= 1.0:
					_tug_active = false
					_tug_offset = Vector3.ZERO
				else:
					# 前半段快速拉向玩家, 后半段弹回 (用 sin 曲线)
					var progress: float = sin(t * PI)
					_tug_offset = _tug_direction * _tug_max_dist * progress

			_vis_root.position = _tug_offset + Vector3(0, float_y, 0)
