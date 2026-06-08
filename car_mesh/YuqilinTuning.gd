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

## 车漆调色 (与 albedo 贴图相乘). Color.WHITE = 原贴图色, 其他色叠加色调
## 例: Color.RED 把车身染红色, Color(0.5,0.7,1.0) 偏蓝调
## 接近纯色时贴图细节会被盖掉, 推荐保持每通道至少 0.3 让细节可见
@export var paint_color: Color = Color.WHITE:
	set(v):
		paint_color = v
		_apply_to_painter()

## Mask 装饰强度 (车漆装饰区域显示强度). 0=不显示装饰图案, 1=完全显示
## Mask 是 PBR 多色蒙版, 标识车身上的装饰花纹/边线区域
@export_range(0.0, 1.0, 0.05) var mask_blend: float = 0.6:
	set(v):
		mask_blend = v
		_apply_to_painter()

## 4 个车身 surface 各自指定套哪一套贴图 (0~3 = TEX_SUFFIXES 索引: ""/00/_001/_01)
## 4 套贴图实际是\"车身 4 个不同部位\"的贴图 (大小 3683/2647/2767/3020 KB 相差大),
## 但 FBX surface 顺序不一定和后缀字典序对齐. 让你为每个 surface 独立选, 试出协调组合.
##
## 默认: surface[0]→0(""), surface[1]→1("00"), surface[2]→2("_001"), surface[3]→3("_01")
## 如果默认效果是青紫拼接, 试一些其他排列, 比如 0/0/0/0 (整车一套), 或 0/2/1/3 等
@export_range(0, 3, 1) var surface_0_paint: int = 0:
	set(v):
		surface_0_paint = v
		_apply_to_painter()

@export_range(0, 3, 1) var surface_1_paint: int = 1:
	set(v):
		surface_1_paint = v
		_apply_to_painter()

@export_range(0, 3, 1) var surface_2_paint: int = 2:
	set(v):
		surface_2_paint = v
		_apply_to_painter()

@export_range(0, 3, 1) var surface_3_paint: int = 3:
	set(v):
		surface_3_paint = v
		_apply_to_painter()

# ---------------- Mask 多色装饰参数 (透传给 Painter ShaderMaterial) ----------------
## Mask R 通道装饰色 (常用于车身金边/拉花区域, 默认金黄)
@export var mask_color_r: Color = Color(1.0, 0.75, 0.2, 1.0):
	set(v):
		mask_color_r = v
		_apply_to_painter()

## Mask G 通道装饰色 (常用于车身暗部装饰, 默认接近黑)
@export var mask_color_g: Color = Color(0.1, 0.1, 0.1, 1.0):
	set(v):
		mask_color_g = v
		_apply_to_painter()

## Mask B 通道装饰色 (常用于高光区/亮饰, 默认接近白)
@export var mask_color_b: Color = Color(0.95, 0.95, 0.95, 1.0):
	set(v):
		mask_color_b = v
		_apply_to_painter()

# ---------------- RMA 倍率 (透传给 Painter ShaderMaterial) ----------------
## 全局 metallic 倍率 (RMA.g 通道之上再乘). 0=完全非金属, 1=贴图原值, 2=超金属感
@export_range(0.0, 2.0, 0.05) var metallic_mult: float = 1.0:
	set(v):
		metallic_mult = v
		_apply_to_painter()

## 全局 roughness 倍率. 0=完全镜面, 1=贴图原值, 2=超磨砂
@export_range(0.0, 2.0, 0.05) var roughness_mult: float = 1.0:
	set(v):
		roughness_mult = v
		_apply_to_painter()

## AO (环境遮蔽) 强度. 0=关闭 AO, 1=完全用 RMA.b 的 AO
@export_range(0.0, 1.0, 0.05) var ao_strength: float = 1.0:
	set(v):
		ao_strength = v
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
	# 透传车漆调色
	if "paint_color_tint" in painter:
		painter.set("paint_color_tint", paint_color)
	# 透传 Mask 装饰强度
	if "mask_blend" in painter:
		painter.set("mask_blend", mask_blend)
	# 透传 4 个 surface 各自的贴图选择
	if "surface_0_paint" in painter:
		painter.set("surface_0_paint", surface_0_paint)
	if "surface_1_paint" in painter:
		painter.set("surface_1_paint", surface_1_paint)
	if "surface_2_paint" in painter:
		painter.set("surface_2_paint", surface_2_paint)
	if "surface_3_paint" in painter:
		painter.set("surface_3_paint", surface_3_paint)
	# 透传 Mask 三色装饰
	if "mask_color_r" in painter:
		painter.set("mask_color_r", mask_color_r)
	if "mask_color_g" in painter:
		painter.set("mask_color_g", mask_color_g)
	if "mask_color_b" in painter:
		painter.set("mask_color_b", mask_color_b)
	# 透传 RMA 倍率
	if "metallic_mult" in painter:
		painter.set("metallic_mult", metallic_mult)
	if "roughness_mult" in painter:
		painter.set("roughness_mult", roughness_mult)
	if "ao_strength" in painter:
		painter.set("ao_strength", ao_strength)
	# 再让 Painter 重建材质 (如果它有 rebuild 方法)
	if painter.has_method("rebuild_materials"):
		painter.call("rebuild_materials")
