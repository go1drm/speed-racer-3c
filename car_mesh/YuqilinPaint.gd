extends Node
## ============================================================
##  YuqilinPaint - 给玉麒麟 FBX 强制套上 PNG 贴图
##  原因: FBX 内部材质引用 .psd / .dds, Godot 加载不全 → 部分 surface 是灰色/绿色
##
##  v3 (2026-06-02): 资源换到 1-3 文件夹 (HNCar_10046_PBR.FBX), 每套贴图后缀变了
##                   且新增 Mask 贴图 4 套, 用户要求"全部都要用上"
##
##  贴图通道 (QQ 飞车 PBR 工作流约定):
##    Paint     -> Albedo 主色  (NCar_10046_Paint_PBR{suffix}.png)
##    RMA       -> R=Roughness, G=Metallic, B=AO  (NCar_10046_RMA_PBR{suffix}.png)
##    Mask      -> 多色蒙版 (装饰区域指示)  (NCar_10046_Mask1_PBR{suffix}.png)
##                 用 detail_albedo + BLEND_MODE_MIX, 让 Mask 颜色叠加到主车漆上
##                 实现"装饰条/拉花/特殊纹路"等多色细节
##    Normal    -> 法线 (本套资源车身已无独立 Normal, 仅轮子有)
## ============================================================

# 主贴图目录 (车身 4 套贴图 = Paint + RMA + Mask 共 12 张)
const TEX_BASE := "res://assets/custom_cars/1_玉麒麟/00084_S至尊·瑞兽（麒麟）1-3/"
# 轮子贴图目录 (3 张: Albedo + RMA + Normal)
const WHEEL_BASE := "res://assets/custom_cars/1_玉麒麟/00084_S至尊·瑞兽（麒麟）1-3/Wheel/"

# 候选后缀 (按 1-3 资源实际命名: NCar_10046_Paint_PBR{suffix}.png)
# 4 套贴图实际是\"车身 4 个不同部位\"的贴图 (大小不同: 3683/2647/2767/3020 KB)
# 不是\"4 套整车换装\". surface[0/1/2/3] 各对应车身不同区域 (主体/装甲/龙鳞/龙翼等),
# 由用户在 Tuner 里为每个 surface 独立选择套哪一套贴图 (因为 FBX surface 顺序不一定
# 和后缀的字典序对齐, 需要试出正确的映射)
const TEX_SUFFIXES := ["", "00", "_001", "_01"]

# 4 个 surface 各自指定套哪一套贴图 (0~3 = TEX_SUFFIXES 索引)
# 默认: surface[0]→后缀"" / surface[1]→后缀"00" / surface[2]→后缀"_001" / surface[3]→后缀"_01"
# 用户可以独立调每个 surface 用哪套, 调出协调的车身配色
@export_range(0, 3, 1) var surface_0_paint: int = 0
@export_range(0, 3, 1) var surface_1_paint: int = 1
@export_range(0, 3, 1) var surface_2_paint: int = 2
@export_range(0, 3, 1) var surface_3_paint: int = 3

# 车漆清漆层强度 (模拟车漆表面那层亮镜面). 0=没清漆, 1=最强. 推荐 0.4~0.7
@export_range(0.0, 1.0, 0.05) var clearcoat_strength: float = 0.5
# 清漆粗糙度 (越小越像新车). 0=镜面, 1=磨砂
@export_range(0.0, 1.0, 0.02) var clearcoat_roughness: float = 0.1
# 厚度贴图驱动的次表面散射强度. 0=关闭, 0.1~0.3 =轻微透感
# (1-3 资源已无 Thickness 贴图, 此参数当前无效, 保留以防 Tuner UI 还引用)
@export_range(0.0, 1.0, 0.05) var subsurf_strength: float = 0.0
# 法线贴图强度 (仅轮子用, 车身 1-3 无 Normal)
@export_range(0.0, 3.0, 0.05) var normal_scale: float = 1.0
# 备用车漆色 (如果 surface 在 4 套里都匹配不上, 用这个色 + 默认 PBR 套兜底)
@export var fallback_paint_color: Color = Color(0.85, 0.85, 0.9, 1.0)
# 车漆调色 (Tint): 与 albedo 贴图相乘, 实现"涂装换色"效果
# StandardMaterial3D 的 albedo_color * albedo_texture 是逐像素相乘 (PBR 工作流标准做法)
# Color.WHITE = 不调色 (原贴图色), 其他色 = 把车漆主色叠加该色调
@export var paint_color_tint: Color = Color.WHITE

# Mask 装饰强度 (0=不显示装饰, 1=Mask 完全覆盖到主 albedo)
# Mask 通过 ShaderMaterial 的 mask_strength uniform 控制
@export_range(0.0, 1.0, 0.05) var mask_blend: float = 1.0

# Mask R 通道对应的装饰色 (默认金边)
# Mask 在 PBR 工作流是 RGB 多色蒙版, R 通道亮的区域用此色
@export var mask_color_r: Color = Color(1.0, 0.75, 0.2, 1.0)
# Mask G 通道对应的装饰色 (默认暗装饰)
@export var mask_color_g: Color = Color(0.1, 0.1, 0.1, 1.0)
# Mask B 通道对应的装饰色 (默认接近白色高光区)
@export var mask_color_b: Color = Color(0.95, 0.95, 0.95, 1.0)
# 全局 metallic 倍率 (RMA.g 的额外缩放)
@export_range(0.0, 2.0, 0.05) var metallic_mult: float = 1.0
# 全局 roughness 倍率 (RMA.r 的额外缩放)
@export_range(0.0, 2.0, 0.05) var roughness_mult: float = 1.0
# AO 强度 (0=关 AO, 1=完全用 RMA.b 的 AO)
@export_range(0.0, 1.0, 0.05) var ao_strength: float = 1.0


# 共享的 PBR Shader 资源 (整个 Painter 加载一次, 所有车身材质共享)
const PBR_SHADER: Shader = preload("res://car_mesh/yuqilin_pbr.gdshader")


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

	# 3) 按 MeshInstance 类型决定材质 + 主车身 surface 索引独立映射贴图
	# ============================================================
	# v5 修复 (2026-06-02 用户反馈"涂装方案肯定不对"):
	#
	# 4 套贴图实际是\"车身 4 个不同部位\"的贴图 (PNG 大小 3683/2647/2767/3020 KB
	# 相差很大, 不是同尺寸的 4 套换装).
	#
	# FBX 里 Car_Lod0_Mesh 有 surface[0/1/2/3] 4 个 — 各对应车身不同区域
	# (车身/龙鳞/龙翼/装饰等). 但 FBX surface 顺序不一定按字典序映射到 4 套贴图.
	# 让用户为每个 surface 独立选哪一套, 试出协调的组合.
	#
	# 数学:
	#   surface_X_paint (0~3) → TEX_SUFFIXES[surface_X_paint]
	#   surface[0] 用 mats_by_suffix[TEX_SUFFIXES[surface_0_paint]]
	#   surface[1] 用 mats_by_suffix[TEX_SUFFIXES[surface_1_paint]]
	#   依次类推
	# ============================================================
	# 把 4 个 surface 映射打包成数组方便循环
	var surface_paint_choice: Array[int] = [surface_0_paint, surface_1_paint, surface_2_paint, surface_3_paint]
	var max_suffix: int = TEX_SUFFIXES.size() - 1
	print("[YuqilinPaint] surface→贴图映射: surface[0]→%d  surface[1]→%d  surface[2]→%d  surface[3]→%d" % surface_paint_choice)

	var applied: int = 0
	var preserved: int = 0
	for mi in mis:
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		var node_name: String = String((mi as Node).name).to_lower()
		var is_wheel: bool = "wheel" in node_name
		var is_body: bool = "lod0_mesh" in node_name
		for i in range(m.get_surface_count()):
			if is_wheel:
				(mi as MeshInstance3D).set_surface_override_material(i, wheel_mat)
				applied += 1
			elif is_body:
				# 主车身: 每个 surface 索引用用户在 Tuner 里指定的那套贴图
				# 数学: chosen_idx = surface_X_paint (其中 X = i, 但 i > 3 时 fallback 到 surface_0)
				var chosen_idx: int
				if i < surface_paint_choice.size():
					chosen_idx = clampi(surface_paint_choice[i], 0, max_suffix)
				else:
					# i >= 4 (FBX surface 超出 4 个) → 用 surface_0 的设置
					chosen_idx = clampi(surface_paint_choice[0], 0, max_suffix)
				var suffix: String = TEX_SUFFIXES[chosen_idx]
				var chosen_mat: Material = mats_by_suffix.get(suffix, mats_by_suffix[""])
				(mi as MeshInstance3D).set_surface_override_material(i, chosen_mat)
				applied += 1
			else:
				# 其他部件 (Steering 等): 保留 FBX 原材质
				(mi as MeshInstance3D).set_surface_override_material(i, null)
				preserved += 1
				if i == 0:
					print("[YuqilinPaint]   保留原材质: %s (非车身/非轮子部件)" % (mi as Node).name)
	print("[YuqilinPaint] 已替换 %d 个 surface (车身按4 surface独立映射 + 轮子) + 保留 %d 个 FBX 原材质" % [applied, preserved])


func _build_car_material(suffix: String) -> ShaderMaterial:
	# ============================================================
	# 用 ShaderMaterial + 自写 PBR shader 正确实现 RMA + Mask
	# 旧版用 StandardMaterial3D 的问题:
	#   · RMA 的 metallic/roughness/AO 三通道要分别 hook 到 3 个 *_texture 槽
	#     虽然 StandardMaterial3D 支持, 但 AO 渲染容易被忽视
	#   · Mask 完全没法用: StandardMaterial3D 的 detail_albedo 只能简单 mix,
	#     不支持 \"R/G/B 各通道分别染不同色\" 的多色蒙版
	# 新版 ShaderMaterial 直接在 fragment 里:
	#   · paint × tint → ALBEDO
	#   · mask R/G/B → mix 三种装饰色
	#   · rma.r/g/b → ROUGHNESS / METALLIC / AO (各带倍率)
	# ============================================================
	var mat := ShaderMaterial.new()
	mat.shader = PBR_SHADER

	# ---- Paint 主色贴图 ----
	var paint_path: String = TEX_BASE + "NCar_10046_Paint_PBR" + suffix + ".png"
	var paint := _try_load(paint_path) as Texture2D
	if paint:
		mat.set_shader_parameter("paint_tex", paint)
		print("[YuqilinPaint]   套贴图 [%s] Paint OK" % suffix)
	else:
		push_warning("[YuqilinPaint] Paint 加载失败: " + paint_path)
		# 没有贴图时给一张纯白的 1x1 贴图, 让 paint_tint 直接生效作为基础色
		var fallback_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		fallback_img.set_pixel(0, 0, Color.WHITE)
		var fallback_tex := ImageTexture.create_from_image(fallback_img)
		mat.set_shader_parameter("paint_tex", fallback_tex)

	# ---- RMA 贴图 (R=Roughness, G=Metallic, B=AO) ----
	var rma_path: String = TEX_BASE + "NCar_10046_RMA_PBR" + suffix + ".png"
	var rma := _try_load(rma_path) as Texture2D
	if rma:
		mat.set_shader_parameter("rma_tex", rma)
	else:
		push_warning("[YuqilinPaint] RMA 加载失败: " + rma_path)
		# fallback: 一张 (R=0.3 Roughness, G=0.6 Metallic, B=1.0 AO 无暗) 的 1x1 贴图
		# 让车身在 RMA 缺失时仍然有合理的 PBR 表现 (略亮金属感)
		var fallback_rma_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		fallback_rma_img.set_pixel(0, 0, Color(0.3, 0.6, 1.0, 1.0))
		var fallback_rma_tex := ImageTexture.create_from_image(fallback_rma_img)
		mat.set_shader_parameter("rma_tex", fallback_rma_tex)

	# ---- Mask 贴图 (RGB 多色蒙版) ----
	var mask_path: String = TEX_BASE + "NCar_10046_Mask1_PBR" + suffix + ".png"
	var mask := _try_load(mask_path) as Texture2D
	if mask:
		mat.set_shader_parameter("mask_tex", mask)
		print("[YuqilinPaint]   套贴图 [%s] Mask OK" % suffix)
	else:
		# 没有 mask = 全黑贴图 (mix 权重 0, 不显示任何装饰色)
		var blank_mask_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		blank_mask_img.set_pixel(0, 0, Color(0, 0, 0, 1))
		var blank_mask_tex := ImageTexture.create_from_image(blank_mask_img)
		mat.set_shader_parameter("mask_tex", blank_mask_tex)

	# ---- Shader 参数: 主车漆调色 + Mask 装饰色 + 强度倍率 ----
	mat.set_shader_parameter("paint_tint", paint_color_tint)
	mat.set_shader_parameter("mask_color_r", mask_color_r)
	mat.set_shader_parameter("mask_color_g", mask_color_g)
	mat.set_shader_parameter("mask_color_b", mask_color_b)
	mat.set_shader_parameter("mask_strength", mask_blend)
	mat.set_shader_parameter("metallic_mult", metallic_mult)
	mat.set_shader_parameter("roughness_mult", roughness_mult)
	mat.set_shader_parameter("ao_strength", ao_strength)

	# 注意: clearcoat 和 subsurface 暂不支持 (ShaderMaterial 走 shader_type=spatial 的话
	# 可以加这些 effect, 但需要在 shader 里写额外 light_pass 处理. 当前 shader 已是 \"够用\"版本)
	# 如果用户后续要调 clearcoat, 我们可以扩展 shader 加 CLEARCOAT 输出

	return mat


func _build_wheel_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_BACK

	var albedo := _try_load(WHEEL_BASE + "Wheel_10046_PBR.png") as Texture2D
	if albedo:
		mat.albedo_texture = albedo
	else:
		push_warning("[YuqilinPaint] Wheel albedo 加载失败")
		mat.albedo_color = Color(0.15, 0.15, 0.18, 1)

	var rma := _try_load(WHEEL_BASE + "Wheel_10046_RMA_PBR.png") as Texture2D
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
		push_warning("[YuqilinPaint] Wheel RMA 加载失败")
		mat.metallic = 0.85
		mat.roughness = 0.4

	var normal := _try_load(WHEEL_BASE + "Wheel_10046_Normal_PBR.png") as Texture2D
	if normal:
		mat.normal_enabled = true
		mat.normal_texture = normal
		mat.normal_scale = normal_scale
	else:
		push_warning("[YuqilinPaint] Wheel Normal 加载失败")

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
