extends RefCounted
class_name WallCurve
## ============================================================
##  墙壁曲线系统 — 控制窄道哪段有墙哪段没墙
## ============================================================
## 每个节点存为 Dictionary: {"t": float, "active": bool}
## 规则: 相邻两个 active=true 的节点之间生成墙壁.
## ============================================================

## 节点列表 (按 t 升序排列), 每个元素 = {"t": float, "active": bool}
var nodes: Array = []

## 墙壁参数
var wall_height: float = 2.5
var wall_thickness: float = 0.3
var wall_color: Color = Color(0.5, 0.5, 0.55)
var wall_emission: float = 0.0


func _init() -> void:
	nodes = [
		{"t": 0.0, "active": true},
		{"t": 1.0, "active": true},
	]


## 添加节点 (自动按 t 排序)
func add_node(t: float, active: bool = true) -> int:
	var new_node: Dictionary = {"t": t, "active": active}
	var insert_idx: int = 0
	for i in range(nodes.size()):
		if float(nodes[i]["t"]) > t:
			break
		insert_idx = i + 1
	nodes.insert(insert_idx, new_node)
	return insert_idx


## 删除指定索引的节点 (至少保留2个)
func remove_node(index: int) -> bool:
	if nodes.size() <= 2:
		return false
	if index < 0 or index >= nodes.size():
		return false
	nodes.remove_at(index)
	return true


## 移动节点的 t 值 (自动重排序)
func move_node(index: int, new_t: float) -> void:
	if index < 0 or index >= nodes.size():
		return
	new_t = clampf(new_t, 0.0, 1.0)
	nodes[index]["t"] = new_t
	nodes.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))


## 切换节点的 active 状态
func toggle_node(index: int) -> void:
	if index < 0 or index >= nodes.size():
		return
	nodes[index]["active"] = not bool(nodes[index]["active"])


## 获取需要生成墙壁的 t 区间列表
func get_wall_segments() -> Array:
	var segments: Array = []
	if nodes.size() < 2:
		return segments
	for i in range(nodes.size() - 1):
		if bool(nodes[i]["active"]) and bool(nodes[i + 1]["active"]):
			segments.append({"from_t": float(nodes[i]["t"]), "to_t": float(nodes[i + 1]["t"])})
	return segments


## 序列化为 Dictionary
func to_dict() -> Dictionary:
	return {
		"nodes": nodes.duplicate(true),
		"wall_height": wall_height,
		"wall_thickness": wall_thickness,
		"wall_color": [wall_color.r, wall_color.g, wall_color.b, wall_color.a],
		"wall_emission": wall_emission,
	}


## 从 Dictionary 反序列化
func from_dict(d: Dictionary) -> void:
	nodes.clear()
	if d.has("nodes"):
		for entry in d["nodes"]:
			nodes.append({"t": float(entry.get("t", 0.0)), "active": bool(entry.get("active", true))})
	if nodes.size() < 2:
		nodes = [{"t": 0.0, "active": true}, {"t": 1.0, "active": true}]
	if d.has("wall_height"):
		wall_height = float(d["wall_height"])
	if d.has("wall_thickness"):
		wall_thickness = float(d["wall_thickness"])
	if d.has("wall_color"):
		var c: Array = d["wall_color"]
		if c.size() >= 3:
			wall_color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]) if c.size() > 3 else 1.0)
	if d.has("wall_emission"):
		wall_emission = float(d["wall_emission"])
