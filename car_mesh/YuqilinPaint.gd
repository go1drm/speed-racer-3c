extends Node
## ============================================================
##  YuqilinPaint - 给玉麒麟 FBX 强制套上 PNG 贴图
##  原因: FBX 内部材质引用 .psd / .dds, Godot 加载不全 → 部分 surface 是灰色/绿色
##
##  绿色车身的根因(用户反馈):
##    surface 顺序不固定, 之前按 index 套贴图会把 RMA(R=粗糙G=金属B=AO)的绿色金属
##    通道当成 Albedo 主色, 渲染出来就是绿色. 现在改成"根据原材质名匹配后缀"
##
##  贴图通道 (QQ 飞车 PBR 工作流约定):
##    Paint     -> Albedo 主色
##    RMA       -> R=Roughness, G=Metallic, B=AO
##    Normal    -> 法线 (在另一个 textures/ 子目录)
##    Mask      -> 多色蒙版 (StandardMaterial3D 不支持, 仅诊断)
##    Thickness -> 次表面厚度 (SSS, 默认关)
## ============================================================

# 主贴图目录
const TEX_BASE := "res://assets/custom_cars/1_玉麒麟/00084_S至尊·瑞兽（麒麟）1-2/"
# 法线贴图目录
const NORMAL_BASE := "res://assets/custom_cars/1_玉麒麟/00084_NCar_10045_S至尊·瑞兽（麒麟）1-2/textures/"
# 轮子贴图目录
const WHEEL_BASE := "res://assets/custom_cars/1_玉麒麟/00084_S至尊·瑞兽（麒麟）1-2/Wheel/"

# 候选后缀 (按车身常见顺序优先级)
const TEX_SUFFIXES := ["", "_000", "_0001", "_01"]

# 车漆清漆层强度 (模拟车漆表面那层亮镜面). 0=没清漆, 1=最强. 推荐 0.4~0.7
@export_range(0.0, 1.0, 0.05) var clearcoat_strength: float = 0.5
# 清漆粗糙度 (越小越像新车). 0=镜面, 1=磨砂
@export_range(0.0, 1.0, 0.02) var clearcoat_roughness: float = 0.1
# 厚度贴图驱动的次表面散射强度. 0=关闭, 0.1~0.3 =轻微透感
@export_range(0.0, 1.0, 0.05) var subsurf_strength: float = 0.0
# 法线贴图强度
@export_range(0.0, 3.0, 0.05) var normal_scale: float = 1.0
# 备用车漆色 (如果 surface 在 4 套里都匹配不上, 用这个色 + 默认 PBR 套兜底)
@export var fallback_paint_color: Color = Color(0.85, 0.85, 0.9, 1.0)


func _ready() -> void:
	await get_tree().process_frame
	rebuild_materials()


# 重建并应用所有材质. YuqilinTuning 改参数后会调这个让效果实时生效
func rebuild_materials() -> void:
	var parent: Node = get_parent()
	if parent == null:
		return

	# 1) 全部 MeshInstance3D 列表 + 每个 surface 的材质名诊断
	var mis: Array = _find_mesh_instances(parent)
	print("[YuqilinPaint] === FBX 材质诊断 (rebuild) ===")
	for mi in mis:
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		var path: String = (mi as Node).get_path()
		print("[YuqilinPaint]   MeshInstance: ", mi.name, " 路径=", path)
		for i in range(m.get_surface_count()):
			var orig_mat: Material = m.surface_get_material(i)
			var orig_name: String = ""
			if orig_mat:
				orig_name = orig_mat.resource_name
			print("[YuqilinPaint]     surface[%d] mat='%s' (resource=%s)" % [i, orig_name, str(orig_mat)])

	# 2) 预加载: 4 套车身材质 + 1 套轮子材质
	var mats_by_suffix: Dictionary = {}
	for suffix in TEX_SUFFIXES:
		mats_by_suffix[suffix] = _build_car_material(suffix)
	var wheel_mat := _build_wheel_material()
	print("[YuqilinPaint] 准备好 %d 套车身材质 + 1 套轮子材质" % mats_by_suffix.size())

	# 3) 第一遍扫描: 收集所有"非轮子"surface 用到的唯一原材质 RID
	#    按"出现顺序"分配后缀, 保证同一原材质 ID 永远对应同一套贴图 (稳定映射)
	#    FBX 材质名是 "Material #2720" 这种自动编号, 不含 _000/_01 这种后缀线索,
	#    所以靠名字匹配会失效, 必须按 instance ID 唯一映射
	var rid_to_suffix: Dictionary = {}   # int(material_rid) -> suffix(String)
	var suffix_idx: int = 0
	for mi in mis:
		# 跳过轮子: 轮子按节点名识别, 不参与车身材质槽编号
		if "wheel" in String((mi as Node).name).to_lower():
			continue
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		for i in range(m.get_surface_count()):
			var orig_mat: Material = m.surface_get_material(i)
			if orig_mat == null:
				continue
			var rid_key: int = orig_mat.get_instance_id()
			if not rid_to_suffix.has(rid_key):
				# 新材质 ID, 分配下一个后缀 (循环利用 4 套)
				var assigned: String = TEX_SUFFIXES[suffix_idx % TEX_SUFFIXES.size()]
				rid_to_suffix[rid_key] = assigned
				suffix_idx += 1
				print("[YuqilinPaint]   材质映射: '%s' (rid=%d) → 后缀 '%s'" % [orig_mat.resource_name, rid_key, assigned])

	# 4) 第二遍: 实际应用. 轮子用 wheel_mat, 其他按 rid 查表
	var applied: int = 0
	for mi in mis:
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		var is_wheel: bool = "wheel" in String((mi as Node).name).to_lower()
		for i in range(m.get_surface_count()):
			var chosen_mat: Material
			if is_wheel:
				chosen_mat = wheel_mat
			else:
				var orig_mat: Material = m.surface_get_material(i)
				var suffix: String = ""
				if orig_mat and rid_to_suffix.has(orig_mat.get_instance_id()):
					suffix = rid_to_suffix[orig_mat.get_instance_id()]
				chosen_mat = mats_by_suffix.get(suffix, mats_by_suffix[""])
			(mi as MeshInstance3D).set_surface_override_material(i, chosen_mat)
			applied += 1
	print("[YuqilinPaint] 已替换 %d 个 surface 材质 (按材质ID稳定映射)" % applied)


# 根据材质名/节点名选择对应的 PBR 材质
func _pick_material_by_name(name_hint: String, mats: Dictionary, wheel_mat: Material) -> Material:
	# 轮子优先: wheel / 10045_wheel 等
	if "wheel" in name_hint:
		return wheel_mat
	# 后缀匹配 (从最具体的 _0001 开始, 否则 _0001 会被 _000 误匹配)
	if "_0001" in name_hint:
		return mats.get("_0001", mats[""])
	if "_000" in name_hint:
		return mats.get("_000", mats[""])
	if "_01" in name_hint:
		return mats.get("_01", mats[""])
	# 默认主车身
	return mats[""]


func _build_car_material(suffix: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_BACK

	# ---- Albedo (车漆主色) ----
	var paint_path: String = TEX_BASE + "NCar_10045_Paint_PBR" + suffix + ".png"
	var paint := _try_load(paint_path) as Texture2D
	if paint:
		mat.albedo_texture = paint
		print("[YuqilinPaint]   套贴图 [%s] Paint OK" % suffix)
	else:
		push_warning("[YuqilinPaint] Paint 加载失败: " + paint_path)
		mat.albedo_color = fallback_paint_color

	# ---- RMA (R=Roughness, G=Metallic, B=AO) ----
	var rma_path: String = TEX_BASE + "NCar_10045_RMA_PBR" + suffix + ".png"
	var rma := _try_load(rma_path) as Texture2D
	if rma:
		mat.roughness_texture = rma
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.roughness = 1.0
		mat.metallic_texture = rma
		mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		mat.metallic = 1.0
		mat.ao_enabled = true
		mat.ao_texture = rma
		mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	else:
		mat.metallic = 0.6
		mat.roughness = 0.3

	# ---- Normal ----
	# Normal 只有 "" 和 "_01" 两套, 其他后缀复用 ""
	var normal_suffix: String = suffix if suffix in ["", "_01"] else ""
	var normal_path: String = NORMAL_BASE + "NCar_10045_Normal_PBR" + normal_suffix + ".png"
	var normal_tex := _try_load(normal_path) as Texture2D
	if normal_tex:
		mat.normal_enabled = true
		mat.normal_texture = normal_tex
		mat.normal_scale = normal_scale

	# ---- Clearcoat ----
	if clearcoat_strength > 0.0:
		mat.clearcoat_enabled = true
		mat.clearcoat = clearcoat_strength
		mat.clearcoat_roughness = clearcoat_roughness

	# ---- Subsurface (Thickness 驱动) ----
	if subsurf_strength > 0.0 and suffix == "":
		var thick_path: String = TEX_BASE + "NCar_10045_Thickness03_PBR.png"
		var thick := _try_load(thick_path) as Texture2D
		if thick:
			mat.subsurf_scatter_enabled = true
			mat.subsurf_scatter_strength = subsurf_strength
			mat.subsurf_scatter_texture = thick

	return mat


func _build_wheel_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_BACK

	var albedo := _try_load(WHEEL_BASE + "Wheel_10045_PBR.png") as Texture2D
	if albedo:
		mat.albedo_texture = albedo
	else:
		mat.albedo_color = Color(0.15, 0.15, 0.18, 1)

	var rma := _try_load(WHEEL_BASE + "Wheel_10045_RMA_PBR.png") as Texture2D
	if rma:
		mat.roughness_texture = rma
		mat.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		mat.metallic_texture = rma
		mat.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		mat.metallic = 1.0
		mat.roughness = 1.0
		mat.ao_enabled = true
		mat.ao_texture = rma
		mat.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	else:
		mat.metallic = 0.85
		mat.roughness = 0.4

	var normal := _try_load(WHEEL_BASE + "Wheel_10045_Normal_PBR.png") as Texture2D
	if normal == null:
		normal = _try_load(NORMAL_BASE + "Wheel_10045_Normal_PBR.png") as Texture2D
	if normal:
		mat.normal_enabled = true
		mat.normal_texture = normal
		mat.normal_scale = normal_scale

	return mat


# 静默加载: 路径不存在不抛错, 直接返回 null
func _try_load(path: String) -> Resource:
	if not ResourceLoader.exists(path):
		return null
	return load(path)


func _find_mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_mesh_instances(c))
	return out
