extends Node
## ============================================================
##  赛道切换器 - 全局 AutoLoad 单例
##  · F1 → track.tscn           (默认赛道)
##  · F2 → track_qinghuaci.tscn (青花瓷赛道)
##
##  在任意场景中按键即可切换, 无需每张场景配置
## ============================================================

const TRACK_MAIN: String = "res://track.tscn"
const TRACK_QINGHUACI: String = "res://track_qinghuaci.tscn"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			print("[TrackSwitcher] 切换到 Track 1 (默认赛道)")
			get_tree().change_scene_to_file(TRACK_MAIN)
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F2:
			print("[TrackSwitcher] 切换到 Track 2 (青花瓷)")
			get_tree().change_scene_to_file(TRACK_QINGHUACI)
			get_viewport().set_input_as_handled()
