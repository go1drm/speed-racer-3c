extends CanvasLayer
## ============================================================
##  场景选择 UI - 全局 AutoLoad 单例
##
##  · 屏幕右上角常驻一个小"地图"按钮, 鼠标点击展开列表
##  · 列表里每一项是一个场景按钮, 点击切换
##  · 数据来源: TrackSwitcher.TRACKS, 加新地图无需改 UI
##  · 快捷键: F4 切换面板显示
##  · 切换场景后 (autoload 持久化, 不会因切场景销毁) UI 自动维持
## ============================================================

# UI 节点
var _toggle_btn: Button          # 右上角"地图"按钮
var _panel: PanelContainer        # 列表面板 (展开时显示)
var _list_vbox: VBoxContainer     # 列表内容 vbox
var _expanded: bool = false       # 列表是否展开


func _ready() -> void:
	# layer 设高一些, 确保覆盖在 HUD/Tuner 之上 (Tuner 在自己的 CanvasLayer 默认 layer=1)
	layer = 10
	_build_ui()
	# 监听场景切换信号, 切换后高亮当前场景
	if Engine.has_singleton("TrackSwitcher"):
		pass
	# autoload 名字 = TrackSwitcher (project.godot 配置)
	var ts: Node = get_node_or_null("/root/TrackSwitcher")
	if ts and ts.has_signal("scene_switching"):
		ts.connect("scene_switching", _on_scene_switching)
	# 视口尺寸变化时重新定位
	get_viewport().size_changed.connect(_relayout)
	_relayout()


func _build_ui() -> void:
	# 右上角小按钮 (常驻可见)
	_toggle_btn = Button.new()
	_toggle_btn.text = "🗺️ 地图"
	_toggle_btn.tooltip_text = "切换地图 (M 键 / F4)"
	_toggle_btn.focus_mode = Control.FOCUS_NONE   # 禁止键盘焦点, 防止空格键误触发
	_toggle_btn.add_theme_font_size_override("font_size", 13)
	_toggle_btn.custom_minimum_size = Vector2(80, 32)
	# 用 StyleBox 定制按钮外观, 让它在游戏中醒目
	var btn_normal := StyleBoxFlat.new()
	btn_normal.bg_color = Color(0.12, 0.12, 0.16, 0.92)
	btn_normal.border_color = Color(1.0, 0.85, 0.3, 1.0)
	btn_normal.border_width_left = 1
	btn_normal.border_width_right = 1
	btn_normal.border_width_top = 1
	btn_normal.border_width_bottom = 1
	btn_normal.corner_radius_top_left = 6
	btn_normal.corner_radius_top_right = 6
	btn_normal.corner_radius_bottom_left = 6
	btn_normal.corner_radius_bottom_right = 6
	btn_normal.content_margin_left = 8
	btn_normal.content_margin_right = 8
	btn_normal.content_margin_top = 4
	btn_normal.content_margin_bottom = 4
	_toggle_btn.add_theme_stylebox_override("normal", btn_normal)
	_toggle_btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_toggle_btn.pressed.connect(_on_toggle_pressed)
	add_child(_toggle_btn)

	# 列表面板 (默认隐藏)
	_panel = PanelContainer.new()
	_panel.visible = false
	var panel_sb := StyleBoxFlat.new()
	panel_sb.bg_color = Color(0.08, 0.08, 0.10, 0.95)
	panel_sb.corner_radius_top_left = 8
	panel_sb.corner_radius_top_right = 8
	panel_sb.corner_radius_bottom_left = 8
	panel_sb.corner_radius_bottom_right = 8
	panel_sb.content_margin_left = 12
	panel_sb.content_margin_right = 12
	panel_sb.content_margin_top = 10
	panel_sb.content_margin_bottom = 10
	panel_sb.border_color = Color(1.0, 0.85, 0.3, 0.7)
	panel_sb.border_width_left = 1
	panel_sb.border_width_right = 1
	panel_sb.border_width_top = 1
	panel_sb.border_width_bottom = 1
	_panel.add_theme_stylebox_override("panel", panel_sb)
	# Tuner 用 mouse_filter STOP, 鼠标在面板上时不会传给 3D 视口 (避免误触发其他系统)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	_panel.add_child(vb)

	# 标题
	var title := Label.new()
	title.text = "🗺️  选择地图"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vb.add_child(title)

	var sep := HSeparator.new()
	vb.add_child(sep)

	# 列表本体
	_list_vbox = VBoxContainer.new()
	_list_vbox.add_theme_constant_override("separation", 4)
	vb.add_child(_list_vbox)

	_rebuild_track_buttons()


func _rebuild_track_buttons() -> void:
	# 清空旧按钮
	for c in _list_vbox.get_children():
		c.queue_free()
	# 按 TrackSwitcher.TRACKS 列表生成按钮 (autoload 单例)
	var ts: Node = get_node_or_null("/root/TrackSwitcher")
	if ts == null:
		push_warning("[SceneSelectorUI] 找不到 TrackSwitcher autoload")
		return
	var tracks: Array = ts.get("TRACKS")
	if tracks == null:
		return
	var current_path: String = _current_scene_path()
	# 加载用户的"地图名 override"映射 (用户重命名内置地图后写到这里)
	# 内置地图原本写死在 TrackSwitcher.TRACKS 是 const, 不能改 const, 所以走 user override
	# user 赛道 (.tres) 不需要走 override, 它们改 track_name 字段直接重保存就行
	var name_overrides: Dictionary = _load_map_name_overrides()
	for t in tracks:
		var path: String = t.get("path", "")
		var orig_name: String = t.get("name", path)
		# 如果用户改过名, 用 override 显示
		var display_name: String = String(name_overrides.get(path, orig_name))
		var hotkey_label: String = t.get("hotkey_label", "")
		var is_current: bool = (path == current_path)
		# 一行 = HBox: [✏️ 重命名] [▶ 切换场景]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_list_vbox.add_child(row)
		# 重命名按钮 (内置地图也能改名, 改完写到 user override)
		var rn := Button.new()
		rn.text = "✏️"
		rn.tooltip_text = "重命名此地图\n(原名: %s)" % orig_name
		rn.custom_minimum_size = Vector2(32, 36)
		rn.focus_mode = Control.FOCUS_NONE
		rn.add_theme_font_size_override("font_size", 13)
		rn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		var path_capture_rn: String = path
		var orig_name_capture: String = orig_name
		var current_display_capture: String = display_name
		rn.pressed.connect(func() -> void:
			_show_rename_builtin_dialog(path_capture_rn, current_display_capture, orig_name_capture)
		)
		row.add_child(rn)
		# 主切换按钮
		var btn := Button.new()
		var label_text: String = ("✓ %s" % display_name) if is_current else ("  %s" % display_name)
		if hotkey_label != "":
			label_text += "    [%s]" % hotkey_label
		btn.text = label_text
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(244, 36)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", 13)
		if is_current:
			btn.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
			btn.disabled = true
		else:
			btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
		btn.pressed.connect(func() -> void:
			ts.call("switch_to", path)
			_set_expanded(false)
		)
		row.add_child(btn)

	# ================= 赛道编辑器入口 + 用户赛道 =================
	# 一条分隔线后追加: 1) "🛠️ 赛道编辑器" 进入编辑器场景  2) 列出 user://tracks/*.tres
	var sep2 := HSeparator.new()
	_list_vbox.add_child(sep2)
	var editor_label := Label.new()
	editor_label.text = "🛠️  赛道编辑器"
	editor_label.add_theme_font_size_override("font_size", 13)
	editor_label.add_theme_color_override("font_color", Color(0.5, 0.95, 1.0))
	_list_vbox.add_child(editor_label)

	# 进入编辑器按钮
	var editor_btn := Button.new()
	editor_btn.text = "  打开编辑器(创建/修改赛道)"
	editor_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	editor_btn.custom_minimum_size = Vector2(280, 36)
	editor_btn.focus_mode = Control.FOCUS_NONE
	editor_btn.add_theme_font_size_override("font_size", 13)
	editor_btn.add_theme_color_override("font_color", Color(0.5, 0.95, 1.0))
	editor_btn.pressed.connect(func() -> void:
		_set_expanded(false)
		get_tree().change_scene_to_file("res://track_editor/TrackEditor.tscn")
	)
	_list_vbox.add_child(editor_btn)

	# 列出 user://tracks/*.tres (玩家保存的赛道)
	var user_tracks: Array = _list_user_tracks()
	if user_tracks.is_empty():
		var hint := Label.new()
		hint.text = "  (尚无保存的赛道, 进入编辑器创建吧～)"
		hint.add_theme_font_size_override("font_size", 11)
		hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
		_list_vbox.add_child(hint)
	else:
		for ut in user_tracks:
			var ut_path: String = ut.get("path", "")
			var ut_name: String = ut.get("name", ut_path.get_file())
			# 一行 = HBox: [✏️ 重命名] [▶ 试玩]
			# 用户要求: 每个赛道前面加一个小按钮做重命名 (改 RaceTrackData.track_name 并重保存)
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 4)
			_list_vbox.add_child(row)
			var rn_btn := Button.new()
			rn_btn.text = "✏️"
			rn_btn.tooltip_text = "重命名此赛道"
			rn_btn.custom_minimum_size = Vector2(32, 32)
			rn_btn.focus_mode = Control.FOCUS_NONE
			rn_btn.add_theme_font_size_override("font_size", 13)
			rn_btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
			var path_for_rename: String = ut_path
			var name_for_rename: String = ut_name
			rn_btn.pressed.connect(func() -> void:
				_show_rename_dialog(path_for_rename, name_for_rename)
			)
			row.add_child(rn_btn)
			var ub := Button.new()
			ub.text = "▶ %s" % ut_name
			ub.alignment = HORIZONTAL_ALIGNMENT_LEFT
			ub.custom_minimum_size = Vector2(244, 32)
			ub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ub.focus_mode = Control.FOCUS_NONE
			ub.add_theme_font_size_override("font_size", 12)
			ub.add_theme_color_override("font_color", Color(0.85, 0.95, 0.85))
			ub.tooltip_text = "试玩此赛道  (右键: 在编辑器中打开)"
			ub.pressed.connect(func() -> void:
				_play_user_track(ut_path)
			)
			# 右键 = 在编辑器中打开
			ub.gui_input.connect(func(ev: InputEvent) -> void:
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
					_open_in_editor(ut_path)
			)
			row.add_child(ub)


# ============================================================
# 地图名 override (供内置地图改名用, 因为 TrackSwitcher.TRACKS 是 const 不能改)
# 存储位置: user://map_name_overrides.cfg, 格式 [overrides] "res://xxx.tscn" = "新名字"
# ============================================================
const MAP_NAME_OVERRIDES_PATH := "user://map_name_overrides.cfg"


func _load_map_name_overrides() -> Dictionary:
	var out: Dictionary = {}
	var cf := ConfigFile.new()
	var err := cf.load(MAP_NAME_OVERRIDES_PATH)
	if err != OK:
		return out
	if cf.has_section("overrides"):
		for k in cf.get_section_keys("overrides"):
			out[String(k)] = String(cf.get_value("overrides", k, ""))
	return out


func _save_map_name_overrides(overrides: Dictionary) -> void:
	var cf := ConfigFile.new()
	for k in overrides.keys():
		cf.set_value("overrides", String(k), String(overrides[k]))
	cf.save(MAP_NAME_OVERRIDES_PATH)


# 内置地图重命名对话框: 写入 user override (不改 TrackSwitcher.TRACKS const)
# 注: 提供"恢复原名"选项, 让用户撤销
func _show_rename_builtin_dialog(map_path: String, current_name: String, original_name: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "重命名地图"
	var vb := VBoxContainer.new()
	dlg.add_child(vb)
	var lbl := Label.new()
	lbl.text = "新名字 (留空 = 恢复原名):"
	vb.add_child(lbl)
	var le := LineEdit.new()
	le.text = current_name
	le.custom_minimum_size = Vector2(280, 28)
	vb.add_child(le)
	var hint := Label.new()
	hint.text = "原始名: %s" % original_name
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	vb.add_child(hint)
	dlg.confirmed.connect(func() -> void:
		var new_name: String = le.text.strip_edges()
		var overrides: Dictionary = _load_map_name_overrides()
		if new_name.is_empty() or new_name == original_name:
			# 留空或与原名相同 = 移除 override (恢复默认)
			overrides.erase(map_path)
		else:
			overrides[map_path] = new_name
		_save_map_name_overrides(overrides)
		_rebuild_track_buttons()
	)
	add_child(dlg)
	dlg.popup_centered()


# 重命名对话框: 改 RaceTrackData.track_name 并重新保存到原文件
# 注: 文件名保持不变, 只改资源里的 track_name 显示名
func _show_rename_dialog(track_path: String, current_name: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "重命名赛道"
	var vb := VBoxContainer.new()
	dlg.add_child(vb)
	var lbl := Label.new()
	lbl.text = "新名字 (改 track_name, 文件名保持不变):"
	vb.add_child(lbl)
	var le := LineEdit.new()
	le.text = current_name
	le.custom_minimum_size = Vector2(280, 28)
	vb.add_child(le)
	dlg.confirmed.connect(func() -> void:
		_do_rename_track(track_path, le.text)
	)
	add_child(dlg)
	dlg.popup_centered()


func _do_rename_track(track_path: String, new_name: String) -> void:
	new_name = new_name.strip_edges()
	if new_name.is_empty():
		return
	var res = ResourceLoader.load(track_path)
	if res == null:
		push_warning("[SceneSelectorUI] 重命名失败: 无法加载 %s" % track_path)
		return
	res.set("track_name", new_name)
	var err := ResourceSaver.save(res, track_path)
	if err != OK:
		push_warning("[SceneSelectorUI] 重命名保存失败 err=%d" % err)
		return
	# 重建按钮列表显示新名字
	_rebuild_track_buttons()


# 列出 user://tracks/*.tres 文件 (供"加载用户赛道"用)
# 返回 Array of {"path": String, "name": String}
func _list_user_tracks() -> Array:
	var out: Array = []
	var dir_path := "user://tracks"
	# 确保目录存在 (DirAccess.make_dir_recursive_absolute 不会报错)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	d.list_dir_begin()
	while true:
		var fname: String = d.get_next()
		if fname == "":
			break
		if d.current_is_dir():
			continue
		# 跳过隐藏文件 / 非 .tres
		if fname.begins_with(".") or not fname.ends_with(".tres"):
			continue
		# _test.tres 是 TrackEditor 的"测试沙盒", 不显示在列表
		if fname == "_test.tres":
			continue
		var full_path := dir_path + "/" + fname
		var display_name := fname.get_basename()   # 去掉扩展名
		# 尝试读 RaceTrackData 拿真正的 track_name
		var res = ResourceLoader.load(full_path)
		if res != null and "track_name" in res:
			var tn: String = String(res.get("track_name"))
			if tn != "":
				display_name = tn
		out.append({"path": full_path, "name": display_name})
	d.list_dir_end()
	return out


# 进入 TrackRunner 试玩用户保存的赛道
func _play_user_track(track_path: String) -> void:
	_set_expanded(false)
	var st: Node = get_node_or_null("/root/TrackRunnerState")
	if st:
		st.set("track_to_load", track_path)
	get_tree().change_scene_to_file("res://track_editor/TrackRunner.tscn")


# 在编辑器中打开已有赛道 (设置编辑器初始加载路径, 然后切到编辑器)
func _open_in_editor(track_path: String) -> void:
	_set_expanded(false)
	var st: Node = get_node_or_null("/root/TrackRunnerState")
	if st:
		st.set("last_editor_track_path", track_path)
	get_tree().change_scene_to_file("res://track_editor/TrackEditor.tscn")


func _current_scene_path() -> String:
	var s: Node = get_tree().current_scene
	if s == null:
		return ""
	return s.scene_file_path


func _on_toggle_pressed() -> void:
	_set_expanded(not _expanded)


func _set_expanded(on: bool) -> void:
	_expanded = on
	if on:
		_rebuild_track_buttons()   # 展开时重建一次, 让"当前场景"高亮反映最新切换结果
	_panel.visible = on
	_relayout()


func _relayout() -> void:
	# 右上角定位: 按钮在最右上, 列表面板在按钮正下方
	var vp: Vector2 = get_viewport().get_visible_rect().size
	if vp.x <= 0.0:
		return
	# 按钮: 右上角, 距离边缘 12px
	var btn_size: Vector2 = _toggle_btn.size if _toggle_btn.size.x > 0 else _toggle_btn.custom_minimum_size
	if btn_size.x <= 0.0:
		btn_size = Vector2(80, 32)
	_toggle_btn.position = Vector2(vp.x - btn_size.x - 12, 12)
	# 面板: 按钮下方
	if _panel.visible:
		# 等一帧让 PanelContainer 算出真实尺寸, 再贴到右上
		await get_tree().process_frame
		var p_size: Vector2 = _panel.size
		if p_size.x <= 0.0:
			p_size = Vector2(320, 200)
		_panel.position = Vector2(vp.x - p_size.x - 12, 12 + btn_size.y + 6)


func _unhandled_input(event: InputEvent) -> void:
	# M 键 / F4 切换面板显示
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F4 or event.keycode == KEY_M or event.physical_keycode == KEY_M:
			_set_expanded(not _expanded)
			get_viewport().set_input_as_handled()
		# ESC 关闭面板 (如果展开中)
		elif event.keycode == KEY_ESCAPE and _expanded:
			_set_expanded(false)
			get_viewport().set_input_as_handled()


# 由 TrackSwitcher.scene_switching 触发
func _on_scene_switching(_path: String, _display_name: String) -> void:
	# 切换瞬间收起面板, 避免新场景一进来面板还展着
	_set_expanded(false)
