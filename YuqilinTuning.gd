extends Node3D
## ============================================================
##  YuqilinTuning - 玉麒麟外观运行时调参代理
##  挂在 YuqilinMesh 根上 (= car.gd 找 body_mesh 的目标的父级)
##
##  调整对象 = FBXCar (FBX 实例本身), 不动 suv2
##  · suv2 由 car.gd 用作 body_mesh 做侧倾/head yaw, 不能被覆盖
##  · tailpipe 挂在 FBXCar 子节点下, 会跟随 FBXCar 旋转/缩放
##  · 轮子在 suv2 直接下面, 不受 fbx_scale 影响
##
##  另外: 车漆材质参数 (clearcoat / normal_scale / subsurf) 也集中在这,
##  通过 Tuner UI 修改时实时把新值同步给 Painter, 由 Painter 重建材质
## ============================================================

# ---------------- FBX 几何变换 ----------------
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

# ---------------- 车漆材质参数 (透传给 Painter) ----------------
## 清漆层强度 (车漆表面那层亮镜面). 0=没清漆, 1=最强. 推荐 0.4~0.7
@export_range(0.0, 1.0, 0.05) var clearcoat_strength: float = 0.5:
	set(v):
		clearcoat_strength = v
		_apply_to_painter()

## 清漆粗糙度 (越小越像新车). 0=镜面, 1=磨砂
@export_range(0.0, 1.0, 0.02) var clearcoat_roughness: float = 0.1:
	set(v):
		clearcoat_roughness = v
		_apply_to_painter()

## 法线贴图强度 (车身细节凹凸感)
@export_range(0.0, 3.0, 0.05) var normal_scale: float = 1.0:
	set(v):
		normal_scale = v
		_apply_to_painter()

## 次表面散射强度 (车漆的"润"感, 阳光下边缘透光). 0=关
@export_range(0.0, 1.0, 0.05) var subsurf_strength: float = 0.0:
	set(v):
		subsurf_strength = v
		_apply_to_painter()


func _ready() -> void:
	_apply_to_fbx()
	# 等 Painter 在子节点 _ready 完成后再同步一次
	await get_tree().process_frame
	_apply_to_painter()


func _apply_to_fbx() -> void:
	var fbx: Node = get_node_or_null("suv2/FBXCar")
	if fbx == null or not fbx is Node3D:
		return
	var b := Basis().rotated(Vector3.UP, deg_to_rad(fbx_rot_y_deg))
	b = b.scaled(Vector3.ONE * fbx_scale)
	(fbx as Node3D).transform = Transform3D(b, Vector3(0, fbx_offset_y, 0))


# 把当前参数透传给 Painter, 让它重新构建并应用所有材质
func _apply_to_painter() -> void:
	var painter: Node = get_node_or_null("suv2/FBXCar/Painter")
	if painter == null:
		return
	# 先把参数设过去
	if "clearcoat_strength" in painter:
		painter.set("clearcoat_strength", clearcoat_strength)
	if "clearcoat_roughness" in painter:
		painter.set("clearcoat_roughness", clearcoat_roughness)
	if "normal_scale" in painter:
		painter.set("normal_scale", normal_scale)
	if "subsurf_strength" in painter:
		painter.set("subsurf_strength", subsurf_strength)
	# 再让 Painter 重建材质 (如果它有 rebuild 方法)
	if painter.has_method("rebuild_materials"):
		painter.call("rebuild_materials")
