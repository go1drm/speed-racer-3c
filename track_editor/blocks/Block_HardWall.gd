extends Node3D
class_name Block_HardWall
## ============================================================
##  硬墙机关 (Hard Wall)
## ============================================================
## 一面坚硬的墙壁. 赛车撞上后按物理碰撞正常回弹 (不是弹簧墙那种夸张弹飞,
## 也不是软墙那种减速吸收). 就是一面普通的刚性墙.
##
## 物理:
##   StaticBody3D layer=1, PhysicsMaterial bounce=0.6 (可调)
##   车撞上去速度按法线反射 × bounce 系数回弹
##   bounce=0 → 完全不弹 (贴墙停); bounce=1 → 完美弹性碰撞
##   推荐 0.4~0.7 = 有回弹感但不夸张
##
## 视觉:
##   BoxMesh (长×高×厚), 深灰色金属质感 + 红色条纹警示带
## ============================================================

@export_group("尺寸")
## 墙宽度 (X 方向, 米)
@export_range(0.5, 100.0, 0.5) var wall_width: float = 10.0
## 墙高度 (Y 方向, 米)
@export_range(0.5, 30.0, 0.5) var wall_height: float = 5.0
## 墙厚度 (Z 方向, 米)
@export_range(0.1, 5.0, 0.1) var wall_thickness: float = 0.6

@export_group("物理")
## 回弹系数 (0=完全不弹, 1=完美弹性, 0.6=推荐硬墙手感)
@export_range(0.0, 1.0, 0.05) var bounce: float = 0.6
## 摩擦系数 (车贴墙滑动时的阻力)
@export_range(0.0, 2.0, 0.1) var friction: float = 0.5

@export_group("视觉")
## 墙体主颜色
@export var wall_color: Color = Color(0.35, 0.35, 0.38)
## 警示条纹颜色 (墙顶/墙底各一条)
@export var stripe_color: Color = Color(0.9, 0.2, 0.1)
## 金属感
@export_range(0.0, 1.0, 0.05) var metallic: float = 0.7
## 粗糙度
@export_range(0.0, 1.0, 0.05) var roughness: float = 0.4

var _body: StaticBody3D = null


func _ready() -> void:
	_rebuild()


func _rebuild() -> void:
	for c in get_children():
		c.queue_free()
	_body = null

	# --- StaticBody3D (硬墙碰撞体) ---
	_body = StaticBody3D.new()
	_body.name = "WallBody"
	_body.collision_layer = 1
	_body.collision_mask = 0
	# PhysicsMaterial: bounce 控制回弹力度
	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = bounce
	phys_mat.friction = friction
	_body.physics_material_override = phys_mat

	# 碰撞形状
	var col_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(wall_width, wall_height, wall_thickness)
	col_shape.shape = box
	col_shape.position = Vector3(0.0, wall_height * 0.5, 0.0)
	_body.add_child(col_shape)

	# --- 视觉: 主墙体 ---
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "WallMesh"
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(wall_width, wall_height, wall_thickness)
	mesh_inst.mesh = bmesh
	mesh_inst.position = Vector3(0.0, wall_height * 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = wall_color
	mat.metallic = metallic
	mat.roughness = roughness
	mesh_inst.material_override = mat
	_body.add_child(mesh_inst)

	# --- 视觉: 顶部警示条纹 ---
	var stripe_h: float = 0.3
	var top_stripe := MeshInstance3D.new()
	var ts_mesh := BoxMesh.new()
	ts_mesh.size = Vector3(wall_width, stripe_h, wall_thickness + 0.02)
	top_stripe.mesh = ts_mesh
	top_stripe.position = Vector3(0.0, wall_height - stripe_h * 0.5, 0.0)
	var smat := StandardMaterial3D.new()
	smat.albedo_color = stripe_color
	smat.metallic = 0.3
	smat.roughness = 0.5
	smat.emission_enabled = true
	smat.emission = stripe_color
	smat.emission_energy_multiplier = 0.3
	top_stripe.material_override = smat
	_body.add_child(top_stripe)

	# --- 视觉: 底部警示条纹 ---
	var bot_stripe := MeshInstance3D.new()
	var bs_mesh := BoxMesh.new()
	bs_mesh.size = Vector3(wall_width, stripe_h, wall_thickness + 0.02)
	bot_stripe.mesh = bs_mesh
	bot_stripe.position = Vector3(0.0, stripe_h * 0.5, 0.0)
	bot_stripe.material_override = smat
	_body.add_child(bot_stripe)

	add_child(_body)


# ---- TrackEditor 接口 ----
func get_editable_params() -> Array:
	return [
		{"key": "wall_width", "label": "墙宽度(m)", "min": 0.5, "max": 100.0, "step": 0.5, "value": wall_width},
		{"key": "wall_height", "label": "墙高度(m)", "min": 0.5, "max": 30.0, "step": 0.5, "value": wall_height},
		{"key": "wall_thickness", "label": "墙厚度(m)", "min": 0.1, "max": 5.0, "step": 0.1, "value": wall_thickness},
		{"key": "bounce", "label": "回弹系数", "min": 0.0, "max": 1.0, "step": 0.05, "value": bounce},
		{"key": "friction", "label": "摩擦系数", "min": 0.0, "max": 2.0, "step": 0.1, "value": friction},
		{"key": "metallic", "label": "金属感", "min": 0.0, "max": 1.0, "step": 0.05, "value": metallic},
		{"key": "roughness", "label": "粗糙度", "min": 0.0, "max": 1.0, "step": 0.05, "value": roughness},
	]

func set_editable_param(key: String, value: float) -> void:
	match key:
		"wall_width": wall_width = value
		"wall_height": wall_height = value
		"wall_thickness": wall_thickness = value
		"bounce": bounce = value
		"friction": friction = value
		"metallic": metallic = value
		"roughness": roughness = value
	_rebuild()
