extends Node3D
## ============================================================
##  YuqilinTuning - 玉麒麟外观运行时调参代理
##  挂在 YuqilinMesh 根上, 通过 setter 改 suv2/FBXCar 的 transform
##  
##  调整对象 = FBXCar (FBX 实例本身), 不动 suv2
##  · suv2 由 car.gd 用作 body_mesh 做侧倾/head yaw, 不能被覆盖
##  · tailpipe 挂在 FBXCar 子节点下, 会跟随 FBXCar 旋转/缩放
##  · 轮子在 suv2 直接下面, 不受 fbx_scale 影响 (只受 car.gd 转向)
## ============================================================

## 玉麒麟整体缩放
@export_range(0.001, 5.0, 0.001) var fbx_scale: float = 1.0:
	set(v):
		fbx_scale = v
		_apply_to_fbx()

## Y 轴旋转 (度): 用于车头朝向修正
@export_range(-180.0, 180.0, 1.0) var fbx_rot_y_deg: float = 0.0:
	set(v):
		fbx_rot_y_deg = v
		_apply_to_fbx()

## Y 偏移 (米): 让车底贴 RigidBody 球体顶端
@export_range(-3.0, 3.0, 0.01) var fbx_offset_y: float = 0.0:
	set(v):
		fbx_offset_y = v
		_apply_to_fbx()


func _ready() -> void:
	_apply_to_fbx()


func _apply_to_fbx() -> void:
	var fbx: Node = get_node_or_null("suv2/FBXCar")
	if fbx == null or not fbx is Node3D:
		return
	var b := Basis().rotated(Vector3.UP, deg_to_rad(fbx_rot_y_deg))
	b = b.scaled(Vector3.ONE * fbx_scale)
	(fbx as Node3D).transform = Transform3D(b, Vector3(0, fbx_offset_y, 0))


