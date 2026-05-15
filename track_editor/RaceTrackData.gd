@tool
extends Resource
class_name RaceTrackData
## ============================================================
##  赛道数据资源 (序列化为 .tres 文件)
##
##  设计原则:
##   · 不存大块网格, 只存"用了哪些积木 + 放在哪里"
##   · 同样不存 GrappleAnchor 的 mesh, 只存位置/半径/颜色
##   · 加载时由 TrackLoader 把这些数据 instance 出真正的节点
##
##  存储路径建议: user://tracks/<name>.tres
## ============================================================

## 赛道显示名 (中文 OK), 用于 UI 列表
@export var track_name: String = "未命名赛道"

## 积木数组. 每项格式: {"id": String, "transform": Transform3D, "params": Dictionary}
##   id        : 对应 track_editor/blocks/<id>.tscn 的文件名 (不含扩展名)
##                例: "straight_short", "turn_90_left"
##   transform : 该积木实例的世界变换 (Transform3D, 编辑器里拖放后的最终位置)
##   params    : (可选) 该积木的可编辑参数字典, 例如 {"length": 25.0, "entry_width": 12.0, ...}
##                由 TrackBlock.get_editable_params() 收集 → save 时存; load 时通过 set_editable_param 应用
##                旧赛道资源没这个字段时, 用积木默认参数 (兼容老存档)
@export var blocks: Array[Dictionary] = []

## 出生点 (Car 节点的初始位置). 默认 (0, 5, 0), 编辑器会让用户自定义
@export var spawn_position: Vector3 = Vector3(0.0, 5.0, 0.0)
## 出生点朝向 (绕 Y 轴弧度). 0 = 朝 -Z 方向 (Godot 默认车头朝向)
@export var spawn_yaw_rad: float = 0.0

## 钩索锚点列表. 每项格式:
##   {"position": Vector3, "anchor_radius": float, "detect_radius": float, "color": Color}
@export var grapple_anchors: Array[Dictionary] = []

## 元数据 (创建时间 / 备注 / 版本号), 仅供 UI 展示, 不影响加载
@export var meta: Dictionary = {}

# ============================================================
# 初始地面 (Ground) 配置
# 用户要求: 编辑器左侧能开关基础地面 + 改它颜色
# 数据存这里, 由 TrackRunner 加载赛道时应用到场景里的 Ground 节点
# ============================================================
## 是否显示初始基础地面 (false = 隐藏, 玩家落出地图掉下去)
@export var ground_enabled: bool = true
## 地面颜色 (默认是浅灰色, 之前的白色太刺眼用户要求改)
@export var ground_color: Color = Color(0.45, 0.5, 0.55, 1.0)


# ============================================================
# 工具方法 (用于编辑器/加载器, 不是必须)
# ============================================================

## 添加一个积木条目 (编辑器用)
## params: 可编辑参数字典, 由 TrackBlock.get_editable_params() 收集得到
##         {"length": 25.0, "entry_width": 12.0, ...}
##         为空时表示"用积木的默认参数"
func add_block(id: String, xform: Transform3D, params: Dictionary = {}) -> void:
	blocks.append({"id": id, "transform": xform, "params": params})

## 添加一个钩索锚点条目
func add_anchor(pos: Vector3, anchor_r: float = 1.5, detect_r: float = 25.0, col: Color = Color(0.3, 0.85, 1.0)) -> void:
	grapple_anchors.append({
		"position": pos,
		"anchor_radius": anchor_r,
		"detect_radius": detect_r,
		"color": col,
	})

## 序列化保存到 user://tracks/<name>.tres
## 返回保存路径; 失败返回空字符串
static func save_to_user(data: RaceTrackData, file_name: String) -> String:
	if file_name.is_empty():
		push_warning("[RaceTrackData] save: 文件名为空")
		return ""
	# 文件名安全化 (避免奇怪字符)
	var safe := file_name
	for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		safe = safe.replace(ch, "_")
	if not safe.ends_with(".tres"):
		safe += ".tres"
	var dir := "user://tracks"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var full_path: String = dir.path_join(safe)
	var err := ResourceSaver.save(data, full_path)
	if err != OK:
		push_warning("[RaceTrackData] 保存失败 err=%d 路径=%s" % [err, full_path])
		return ""
	print("[RaceTrackData] 已保存: ", full_path)
	return full_path


## 列出 user://tracks/ 下所有 .tres 文件 (返回完整 res:// 风格路径数组)
static func list_user_tracks() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open("user://tracks")
	if dir == null:
		# 目录还没创建, 返回空数组
		return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.get_extension().to_lower() == "tres":
			out.append("user://tracks/" + f)
		f = dir.get_next()
	dir.list_dir_end()
	return out
