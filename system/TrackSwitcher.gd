extends Node
## ============================================================
##  赛道切换器 - 全局 AutoLoad 单例
##  · F1 → track.tscn           (默认赛道)
##  · F2 → track_qinghuaci.tscn (青花瓷赛道)
##  · F3 → track_paiweilali.tscn(派位拉力赛道)
##  · F4 → 切换 SceneSelectorUI 显示
##
##  在任意场景中按键即可切换, 无需每张场景配置
##
##  数据驱动: TRACKS 是单一真相源, SceneSelectorUI 通过它生成按钮列表,
##  以后再加新地图只需在 TRACKS 数组里加一项即可, UI 自动出现新按钮.
## ============================================================

## 场景列表: [{path, name, hotkey, hotkey_label}]
##   path:        场景资源路径
##   name:        UI 上显示的中文名
##   hotkey:      Godot KEY_* 常量, 用于 _unhandled_input 快捷键; 0 = 无快捷键
##   hotkey_label: 快捷键的显示文本 (UI 按钮上显示, 比如 "F1")
const TRACKS: Array = [
	{
		"path": "res://tracks/track.tscn",
		"name": "Track 1 (默认赛道)",
		"hotkey": KEY_F1,
		"hotkey_label": "F1",
	},
	{
		"path": "res://tracks/track_qinghuaci.tscn",
		"name": "Track 2 (青花瓷)",
		"hotkey": KEY_F2,
		"hotkey_label": "F2",
	},
	{
		"path": "res://tracks/track_paiweilali.tscn",
		"name": "Track 3 (派位拉力)",
		"hotkey": KEY_F3,
		"hotkey_label": "F3",
	},
]

# 场景切换信号 (供其他系统监听)
signal scene_switching(path: String, display_name: String)


## 切换到指定场景路径 (供 UI / 快捷键统一调用)
## 单一入口确保切换时机一致, 减少重复代码
func switch_to(path: String) -> void:
	var info: Dictionary = _find_track_info(path)
	var name: String = info.get("name", path)
	print("[TrackSwitcher] 切换到 ", name, " (", path, ")")
	emit_signal("scene_switching", path, name)
	get_tree().change_scene_to_file(path)


func _find_track_info(path: String) -> Dictionary:
	for t in TRACKS:
		if t["path"] == path:
			return t
	return {}


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	# 快捷键路由 (从 TRACKS 表自动生成, 加新地图无需改这里)
	for t in TRACKS:
		var hk: int = int(t.get("hotkey", 0))
		if hk != 0 and event.keycode == hk:
			switch_to(t["path"])
			get_viewport().set_input_as_handled()
			return
