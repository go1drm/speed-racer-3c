// ============================================================
//  Yuqilin PBR Shader — 玉麒麟车身 PBR 着色器
// ============================================================
//  正确实现 QQ 飞车端游 PBR 工作流的多色车漆系统:
//
//  Paint   (Albedo 主色) × paint_tint               → ALBEDO 基础车漆
//  RMA     (R=Rough, G=Metallic, B=AO)             → 分别映射到 ROUGHNESS / METALLIC / AO
//  Mask    (R/G/B 三通道蒙版, 标识不同装饰区域)      → 用 R/G/B 作为权重 mix 三种装饰色
//
//  Mask 用法 (核心):
//    R 通道亮度 → mix(albedo, mask_color_r, R × strength)   ; 装饰色 1 区域 (常用: 金边)
//    G 通道亮度 → mix(albedo, mask_color_g, G × strength)   ; 装饰色 2 区域 (常用: 暗部装饰)
//    B 通道亮度 → mix(albedo, mask_color_b, B × strength)   ; 装饰色 3 区域 (常用: 高光区)
//    顺序叠加, 后者覆盖前者
//
//  Clearcoat: 走 Godot SpatialShader 内置 clearcoat 渲染管线 (set_shader_parameter 控制)
// ============================================================

shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// ---- 主贴图 ----
uniform sampler2D paint_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rma_tex   : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D mask_tex  : filter_linear_mipmap, repeat_enable, hint_default_black;

// ---- 主车漆调色 (与 paint 贴图相乘) ----
uniform vec4 paint_tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);

// ---- Mask 三个通道对应的装饰色 ----
// 用户可在 Tuner 里独立选每种装饰色
uniform vec4 mask_color_r : source_color = vec4(1.0, 0.75, 0.2, 1.0);   // 金边 (默认金黄)
uniform vec4 mask_color_g : source_color = vec4(0.1, 0.1, 0.1, 1.0);    // 暗装饰 (默认黑)
uniform vec4 mask_color_b : source_color = vec4(0.95, 0.95, 0.95, 1.0); // 高光区 (默认接近白)

// ---- Mask 整体强度 (0=不显示装饰, 1=完全用 mask 色覆盖) ----
uniform float mask_strength : hint_range(0.0, 1.0) = 1.0;

// ---- AO 强度 (0=关闭 AO, 1=完全应用) ----
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;

// ---- 全局 metallic / roughness 缩放 (RMA 贴图基础上再乘) ----
uniform float metallic_mult  : hint_range(0.0, 2.0) = 1.0;
uniform float roughness_mult : hint_range(0.0, 2.0) = 1.0;


void fragment() {
	// ---- 1. 采样三张贴图 ----
	vec4 paint_sample = texture(paint_tex, UV);
	vec4 rma         = texture(rma_tex, UV);
	vec4 mask        = texture(mask_tex, UV);

	// ---- 2. 主车漆 (paint × tint) ----
	// 数学: albedo_base = paint.rgb × paint_tint.rgb (逐像素相乘)
	// 这是 PBR 标准做法 (StandardMaterial3D 也是这样)
	vec3 albedo = paint_sample.rgb * paint_tint.rgb;

	// ---- 3. Mask 多色装饰叠加 ----
	// 数学:
	//   w_r = mask.r × strength       ; R 通道权重 (0~1)
	//   albedo = mix(albedo, mask_color_r, w_r)
	//   依次对 G/B 重复
	// 顺序叠加意味着最后一个覆盖前面的 (B 优先级最高)
	// 推荐 Mask 设计时让三个通道在不同区域亮 (无重叠)
	float w_r = mask.r * mask_strength;
	float w_g = mask.g * mask_strength;
	float w_b = mask.b * mask_strength;
	albedo = mix(albedo, mask_color_r.rgb, w_r);
	albedo = mix(albedo, mask_color_g.rgb, w_g);
	albedo = mix(albedo, mask_color_b.rgb, w_b);

	// ---- 4. RMA 通道映射 ----
	// RMA 贴图: R=Roughness, G=Metallic, B=AO  (QQ飞车端游约定)
	// 各自乘以全局倍率, 让 Tuner 能调整
	ALBEDO = albedo;
	ROUGHNESS = clamp(rma.r * roughness_mult, 0.0, 1.0);
	METALLIC = clamp(rma.g * metallic_mult, 0.0, 1.0);
	// AO 通过 mix 应用 (Godot 4 推荐做法, 不直接给 AO_LIGHT_AFFECT)
	// ao_factor = 1.0 时无 AO 效果, ao_factor = rma.b 时全 AO
	float ao_factor = mix(1.0, rma.b, ao_strength);
	AO = ao_factor;
	AO_LIGHT_AFFECT = 1.0;
}
