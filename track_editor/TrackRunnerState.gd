extends Node
## ============================================================
##  TrackRunner 跨场景状态单例 (autoload)
##
##  作用: 在切换到 TrackRunner.tscn 之前, 由调用方 (TrackEditor 测试 / SceneSelectorUI 加载)
##        把"应该加载哪个 .tres 赛道"写在这里, TrackRunner._ready 时读取.
##  原因: change_scene_to_file 不支持参数, 必须用 autoload 单例传递状态
## ============================================================

# 下一次进入 TrackRunner 时要加载的赛道资源路径 (绝对的 res:// 或 user:// 路径)
# 空字符串 = 默认加载 user://tracks/_test.tres
var track_to_load: String = ""

# 当前赛道的显示名称 (由 TrackRunner/TrackSetup 设置, HUD 读取)
var track_display_name: String = ""

# 上次保存编辑器状态用于"返回编辑器"功能 (未来扩展)
var last_editor_track_path: String = ""
