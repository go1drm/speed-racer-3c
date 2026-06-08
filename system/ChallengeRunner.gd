extends Node
class_name ChallengeRunnerSingleton
const ChallengeDataScript = preload("res://system/ChallengeData.gd")
## ============================================================
##  闯关运行器 (AutoLoad 单例)
## ============================================================
## 负责: 加载闯关数据 → 按序切换关卡 → 终点触发下一关 → 转场动效 → 统计

## ---- 状态 ----
var is_running: bool = false
var challenge_data: Resource = null
var current_stage: int = 0            # 当前关卡索引 (从0开始)
var total_time: float = 0.0           # 总用时 (秒)
var stage_time: float = 0.0           # 当前关卡用时
var total_resets: int = 0             # 总复位次数
var _timing: bool = false             # 是否正在计时
var _transitioning: bool = false      # 是否正在转场中

## ---- 转场 UI ----
var _transition_layer: CanvasLayer = null
var _transition_rect: TextureRect = null   # shader 格子旗
var _transition_shader: ShaderMaterial = null
var _stage_label: Label = null

## ---- 结算 UI ----
var _result_layer: CanvasLayer = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_create_transition_ui()
	_load_transition_params_from_cfg()


func _process(delta: float) -> void:
	if is_running and _timing and not _transitioning:
		total_time += delta
		stage_time += delta


## ============================================================
##  公共接口
## ============================================================

## 开始闯关 (由 SceneSelectorUI 调用)
func start_challenge(data: Resource) -> void:
	challenge_data = data
	current_stage = 0
	total_time = 0.0
	stage_time = 0.0
	total_resets = 0
	is_running = true
	_timing = false
	_transitioning = false
	_load_stage(0)


## 通知终点到达 (由 Block_FinishLine 或 car 信号触发)
func on_finish_reached() -> void:
	if not is_running or _transitioning:
		return
	_timing = false
	current_stage += 1
	if current_stage >= challenge_data.track_sequence.size():
		# 全部通关
		_show_result()
	else:
		# 下一关
		_do_transition(current_stage)


## 通知复位 (由 car 的 reset 信号触发)
func on_reset() -> void:
	if is_running:
		total_resets += 1


## 停止闯关 (手动退出)
func stop_challenge() -> void:
	is_running = false
	_timing = false
	challenge_data = null
	_hide_transition()
	_hide_result()


## ============================================================
##  内部: 加载关卡
## ============================================================
func _load_stage(stage_idx: int) -> void:
	current_stage = stage_idx
	stage_time = 0.0
	var track_path: String = challenge_data.track_sequence[stage_idx]
	# 设置 TrackRunnerState 让 TrackRunner 加载对应赛道
	TrackRunnerState.track_to_load = track_path
	TrackRunnerState.track_display_name = challenge_data.challenge_name + " - 第%d关" % (stage_idx + 1)
	# 切到 TrackRunner 场景
	get_tree().change_scene_to_file("res://track_editor/TrackRunner.tscn")
	# 延迟显示关卡提示 (等场景加载完)
	await get_tree().process_frame
	await get_tree().process_frame
	_show_stage_banner(stage_idx)
	_timing = true
	# 连接 finish_line 和 reset 信号
	await get_tree().process_frame
	_connect_car_signals()


## 连接 car 的信号
func _connect_car_signals() -> void:
	# 找 Car 节点 (TrackRunner 加载后 Car 在 /root/TrackRunner/ 下)
	var cars: Array = get_tree().get_nodes_in_group("player_car")
	if cars.is_empty():
		# 尝试直接找 RigidBody3D
		for node in get_tree().get_nodes_in_group(""):
			pass
		# 用 find 方式
		var root: Node = get_tree().current_scene
		if root:
			for child in root.get_children():
				if child is RigidBody3D and child.has_signal("finish_line_reached"):
					_connect_single_car(child)
					return
			# 递归找
			_find_and_connect_car(root)
	else:
		for car in cars:
			_connect_single_car(car)


func _find_and_connect_car(node: Node) -> void:
	for child in node.get_children():
		if child is RigidBody3D and child.has_signal("finish_line_reached"):
			_connect_single_car(child)
			return
		_find_and_connect_car(child)


func _connect_single_car(car: Node) -> void:
	if car.has_signal("finish_line_reached") and not car.is_connected("finish_line_reached", _on_car_finish):
		car.connect("finish_line_reached", _on_car_finish)
	if car.has_signal("reset_to_origin_triggered") and not car.is_connected("reset_to_origin_triggered", _on_car_reset):
		car.connect("reset_to_origin_triggered", _on_car_reset)


func _on_car_finish() -> void:
	on_finish_reached()


func _on_car_reset() -> void:
	on_reset()


## ============================================================
##  转场动效 (格子旗 shader 擦除 + 大字关卡数)
## ============================================================
func _create_transition_ui() -> void:
	_transition_layer = CanvasLayer.new()
	_transition_layer.name = "ChallengeTransition"
	_transition_layer.layer = 100
	_transition_layer.visible = false
	add_child(_transition_layer)

	# Universal Transition Shader 全屏遮罩
	_transition_rect = TextureRect.new()
	_transition_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_transition_rect.stretch_mode = TextureRect.STRETCH_TILE
	_transition_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 底色纹理 (从 cfg 读取颜色, 默认柔和深蓝灰)
	_rebuild_transition_texture()
	# Shader material (Universal Transition Shader by Chris-Baker)
	var shader := load("res://system/transition.gdshader") as Shader
	if shader:
		_transition_shader = ShaderMaterial.new()
		_transition_shader.shader = shader
		_transition_shader.set_shader_parameter("progress", 0.0)
		_transition_shader.set_shader_parameter("transition_type", 0)
		_transition_shader.set_shader_parameter("grid_size", Vector2(8.0, 6.0))
		_transition_shader.set_shader_parameter("from_center", true)
		_transition_shader.set_shader_parameter("invert", false)
		_transition_shader.set_shader_parameter("basic_feather", 0.15)
		_transition_shader.set_shader_parameter("stagger", Vector2(0.3, 0.0))
		_transition_shader.set_shader_parameter("stagger_frequency", Vector2i(2, 2))
		_transition_shader.set_shader_parameter("use_sprite_alpha", false)
		_transition_shader.set_shader_parameter("use_transition_texture", false)
		_transition_rect.material = _transition_shader
	_transition_layer.add_child(_transition_rect)

	# 关卡标题
	_stage_label = Label.new()
	_stage_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stage_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_stage_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage_label.add_theme_font_size_override("font_size", 130)
	_stage_label.add_theme_constant_override("shadow_offset_x", 4)
	_stage_label.add_theme_constant_override("shadow_offset_y", 4)
	_stage_label.add_theme_constant_override("outline_size", 5)
	_stage_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_label_colors()
	_transition_layer.add_child(_stage_label)


## 底色/文字颜色 (可从 Tuner cfg 配置)
var transition_bg_color: Color = Color(0.12, 0.15, 0.25, 1.0)    # 柔和深蓝灰
var transition_text_color: Color = Color(1.0, 0.92, 0.4, 1.0)    # 暖金黄
var transition_outline_color: Color = Color(0.2, 0.1, 0.0, 0.9)  # 深棕描边


func _rebuild_transition_texture() -> void:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(transition_bg_color)
	_transition_rect.texture = ImageTexture.create_from_image(img)


func _apply_label_colors() -> void:
	_stage_label.add_theme_color_override("font_color", transition_text_color)
	_stage_label.add_theme_color_override("font_shadow_color", Color(transition_outline_color.r, transition_outline_color.g, transition_outline_color.b, 0.8))
	_stage_label.add_theme_color_override("font_outline_color", transition_outline_color)


func _show_stage_banner(stage_idx: int) -> void:
	_stage_label.text = "第 %d 关" % (stage_idx + 1)
	_stage_label.modulate = Color(1, 1, 1, 1)
	_transition_layer.visible = true
	# 全覆盖遮住画面 (此时新场景正在初始化, 车在回到出生点)
	if _transition_shader:
		_transition_shader.set_shader_parameter("progress", 1.0)
	# 等足够久让场景完全加载+车稳定在出生点 (遮罩全程覆盖, 玩家看不到)
	var tw := create_tween()
	tw.tween_interval(1.8)  # 等1.8秒: 场景加载+车物理稳定
	# 格子旗退出 (progress 1→0, 此时车已安静地待在出生点)
	if _transition_shader:
		tw.tween_method(func(v: float) -> void:
			_transition_shader.set_shader_parameter("progress", v)
		, 1.0, 0.0, 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(_stage_label, "modulate:a", 0.0, 0.5)
	tw.tween_callback(func() -> void:
		_transition_layer.visible = false
	)


func _do_transition(next_stage: int) -> void:
	_transitioning = true
	_transition_layer.visible = true
	_stage_label.text = ""
	_stage_label.modulate = Color(1, 1, 1, 0)
	if _transition_shader:
		_transition_shader.set_shader_parameter("progress", 0.0)

	var tw := create_tween()
	# 格子旗扫入 (progress 0→1)
	if _transition_shader:
		tw.tween_method(func(v: float) -> void:
			_transition_shader.set_shader_parameter("progress", v)
		, 0.0, 1.0, 0.5).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	tw.tween_interval(0.2)
	# 显示关卡文字
	tw.tween_callback(func() -> void:
		_stage_label.text = "第 %d 关" % (next_stage + 1)
		_stage_label.modulate = Color(1, 1, 1, 1)
	)
	tw.tween_interval(1.0)
	# 加载下一关 (在格子旗完全覆盖时切场景, 玩家看不到加载过程)
	tw.tween_callback(func() -> void:
		_load_stage(next_stage)
	)
	tw.tween_interval(0.3)
	tw.tween_callback(func() -> void:
		_transitioning = false
	)


func _hide_transition() -> void:
	if _transition_layer:
		_transition_layer.visible = false
		if _transition_shader:
			_transition_shader.set_shader_parameter("progress", 0.0)


## ============================================================
##  通关结算
## ============================================================
func _show_result() -> void:
	is_running = false
	_timing = false
	if _result_layer == null:
		_result_layer = CanvasLayer.new()
		_result_layer.name = "ChallengeResult"
		_result_layer.layer = 101
		add_child(_result_layer)

	# 清理旧 UI
	for c in _result_layer.get_children():
		c.queue_free()

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(600, 400)
	panel.position = Vector2(-300, -200)
	_result_layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "🏁 闯关完成!"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", Color(1, 0.85, 0.2))
	vbox.add_child(title)

	var name_label := Label.new()
	name_label.text = challenge_data.challenge_name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 28)
	vbox.add_child(name_label)

	var time_label := Label.new()
	var minutes: int = int(total_time) / 60
	var seconds: float = fmod(total_time, 60.0)
	time_label.text = "总用时: %d:%05.2f" % [minutes, seconds]
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_label.add_theme_font_size_override("font_size", 36)
	time_label.add_theme_color_override("font_color", Color.WHITE)
	vbox.add_child(time_label)

	var reset_label := Label.new()
	reset_label.text = "复位次数: %d" % total_resets
	reset_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	reset_label.add_theme_font_size_override("font_size", 28)
	vbox.add_child(reset_label)

	var stages_label := Label.new()
	stages_label.text = "通过关卡: %d 关" % challenge_data.track_sequence.size()
	stages_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stages_label.add_theme_font_size_override("font_size", 24)
	vbox.add_child(stages_label)

	var btn := Button.new()
	btn.text = "返回"
	btn.custom_minimum_size = Vector2(200, 50)
	btn.pressed.connect(func() -> void:
		_hide_result()
		stop_challenge()
		get_tree().change_scene_to_file("res://tracks/track_qinghuaci.tscn")
	)
	vbox.add_child(btn)

	_result_layer.visible = true


func _hide_result() -> void:
	if _result_layer:
		_result_layer.visible = false
		for c in _result_layer.get_children():
			c.queue_free()


## 从 tuner.cfg 的 [transition] 段加载已保存的转场参数
func _load_transition_params_from_cfg() -> void:
	if _transition_shader == null:
		return
	var cfg := ConfigFile.new()
	if cfg.load("user://tuner.cfg") != OK:
		return
	if not cfg.has_section("transition"):
		return
	var params: Dictionary = {}
	for key in cfg.get_section_keys("transition"):
		params[key] = cfg.get_value("transition", key, 0.0)
	# 应用到 shader
	if params.has("transition_type"):
		_transition_shader.set_shader_parameter("transition_type", int(params["transition_type"]))
	if params.has("grid_size_x") or params.has("grid_size_y"):
		_transition_shader.set_shader_parameter("grid_size", Vector2(params.get("grid_size_x", 8.0), params.get("grid_size_y", 6.0)))
	if params.has("from_center"):
		_transition_shader.set_shader_parameter("from_center", params["from_center"] > 0.5)
	if params.has("invert"):
		_transition_shader.set_shader_parameter("invert", params["invert"] > 0.5)
	if params.has("basic_feather"):
		_transition_shader.set_shader_parameter("basic_feather", params["basic_feather"])
	if params.has("edges"):
		_transition_shader.set_shader_parameter("edges", int(params["edges"]))
	if params.has("shape_feather"):
		_transition_shader.set_shader_parameter("shape_feather", params["shape_feather"])
	if params.has("sectors"):
		_transition_shader.set_shader_parameter("sectors", int(params["sectors"]))
	if params.has("clock_feather"):
		_transition_shader.set_shader_parameter("clock_feather", params["clock_feather"])
	if params.has("stagger_x") or params.has("stagger_y"):
		_transition_shader.set_shader_parameter("stagger", Vector2(params.get("stagger_x", 0.3), params.get("stagger_y", 0.0)))
	if params.has("rotation_angle"):
		_transition_shader.set_shader_parameter("rotation_angle", params["rotation_angle"])
	if params.has("progress_bias_x") or params.has("progress_bias_y"):
		_transition_shader.set_shader_parameter("progress_bias", Vector2(params.get("progress_bias_x", 0.0), params.get("progress_bias_y", 0.0)))
	# 颜色
	if params.has("bg_r"):
		transition_bg_color = Color(params.get("bg_r", 0.12), params.get("bg_g", 0.15), params.get("bg_b", 0.25))
		_rebuild_transition_texture()
	if params.has("text_r"):
		transition_text_color = Color(params.get("text_r", 1.0), params.get("text_g", 0.92), params.get("text_b", 0.4))
	if params.has("outline_r"):
		transition_outline_color = Color(params.get("outline_r", 0.2), params.get("outline_g", 0.1), params.get("outline_b", 0.0))
	_apply_label_colors()
