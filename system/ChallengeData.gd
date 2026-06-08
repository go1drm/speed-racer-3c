extends Resource
class_name ChallengeData
## ============================================================
##  闯关玩法数据 — 保存一组赛道序列
## ============================================================
## 存为 .tres 文件 (tracks/ 目录下)
## 由 SceneSelectorUI 的闯关编辑器创建和管理

## 闯关名称 (显示用)
@export var challenge_name: String = "未命名闯关"

## 赛道序列: 每项是赛道文件路径 (user://tracks/xxx.tres)
## 按数组顺序 = 关卡顺序 (index 0 = 第1关)
@export var track_sequence: Array[String] = []

## 保存到 tracks/ 目录
static func save_challenge(data: ChallengeData, file_name: String) -> String:
	var dir_path: String = "user://challenges/"
	if not DirAccess.dir_exists_absolute(dir_path):
		DirAccess.make_dir_recursive_absolute(dir_path)
	var safe_name: String = file_name.strip_edges().replace("/", "_").replace("\\", "_")
	if safe_name.is_empty():
		safe_name = "challenge"
	var full_path: String = dir_path + safe_name + ".tres"
	ResourceSaver.save(data, full_path)
	return full_path

## 扫描所有已保存的闯关
static func list_challenges() -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var dir_path: String = "user://challenges/"
	if not DirAccess.dir_exists_absolute(dir_path):
		return results
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return results
	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".tres"):
			var path: String = dir_path + fname
			var res: Resource = load(path)
			if res is ChallengeData:
				results.append({"path": path, "name": res.challenge_name, "count": res.track_sequence.size()})
		fname = dir.get_next()
	dir.list_dir_end()
	return results
