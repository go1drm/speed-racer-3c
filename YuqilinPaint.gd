extends Node
## ============================================================
##  YuqilinPaint - 给玉麒麟 FBX 强制套上 PNG 贴图
##  原因: FBX 内部材质引用 .psd, Godot 无法加载 → 全是灰色
##
##  策略: FBX 同目录有 4 套 PBR 贴图(默认/_000/_0001/_01),
##        每套对应一个材质槽. 通过遍历每个 MeshInstance3D 的 surface,
##        按 surface_index 套对应贴图
## ============================================================

const TEX_BASE := "res://assets/custom_cars/1_玉麒麟/00084_S至尊·瑞兽（麒麟）1-2/"
# 4 套 PBR 贴图 (按 FBX 材质槽顺序: 0, 1, 2, 3)
# 经验: FBX 材质 ID 顺序 = 文件名后缀 ""=主车漆, "_000"=辅, "_0001"=轮/细节, "_01"=玻璃/透明
const TEX_SUFFIXES := ["", "_01", "_000", "_0001"]


func _ready() -> void:
	await get_tree().process_frame
	var parent: Node = get_parent()
	if parent == null:
		return

	# 1) 全部 MeshInstance3D 列表 + 每个 surface 的材质名诊断
	var mis: Array = _find_mesh_instances(parent)
	print("[YuqilinPaint] === FBX 材质诊断 ===")
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

	# 2) 预加载 4 套材质
	var mats: Array = []
	for suffix in TEX_SUFFIXES:
		var mat := _build_material(suffix)
		mats.append(mat)
	print("[YuqilinPaint] 准备好 %d 套材质" % mats.size())

	# 3) 应用: 默认按 surface_index 取对应材质
	#    如果某个 mesh 有 N 个 surface, 第 i 个 surface 用 mats[i]
	#    超出 mats 数量的用 mats[0] 兜底
	var applied: int = 0
	for mi in mis:
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		for i in range(m.get_surface_count()):
			var mat_idx: int = clampi(i, 0, mats.size() - 1)
			(mi as MeshInstance3D).set_surface_override_material(i, mats[mat_idx])
			applied += 1
	print("[YuqilinPaint] 已替换 %d 个 surface 材质" % applied)


func _build_material(suffix: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_BACK

	var paint_path: String = TEX_BASE + "NCar_10045_Paint_PBR" + suffix + ".png"
	var rma_path: String = TEX_BASE + "NCar_10045_RMA_PBR" + suffix + ".png"
	var mask_path: String = TEX_BASE + "NCar_10045_Mask1_PBR" + suffix + ".png"

	var paint := load(paint_path) as Texture2D
	if paint:
		mat.albedo_texture = paint
	else:
		push_warning("[YuqilinPaint] Paint 加载失败: " + paint_path)
		mat.albedo_color = Color(0.5, 0.7, 0.65, 1)

	var rma := load(rma_path) as Texture2D
	if rma:
		# RMA: R=Roughness, G=Metallic, B=AO
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
		mat.metallic = 0.6
		mat.roughness = 0.3

	# Mask 通道: 在 QQ飞车里通常做车漆配色遮罩, 暂不参与渲染
	var _mask := load(mask_path)
	if _mask == null:
		pass  # 静默忽略

	return mat


func _find_mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_mesh_instances(c))
	return out
