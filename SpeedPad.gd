extends Area3D
## ============================================================
## 加速带 (Speed Pad) —— 赛道上的"白色方块"
##
## 工作原理:
##   1) TrackSetup 识别 FBX 里 mesh 名带 "AddSpeed" 的 MeshInstance3D,
##      不给它生成 trimesh 碰撞, 改成在它位置创建一个 Area3D (挂此脚本)
##      + 用 mesh 的 AABB 建 BoxShape3D 做触发范围
##   2) 车 (RigidBody3D) 进入 Area 时, _on_body_entered 触发, 给车施加"沿车头方向的前冲推力"
##   3) 车离开 Area 时, 冷却标记清零, 允许再次触发 (防止同一次接触持续触发)
##
## 调用 car.gd 接口: car.apply_speed_pad_boost(power, duration)
##   · power: 冲量强度 (m/s, 直接 × mass 成冲量)
##   · duration: 持续推力时间 (秒, 0=仅给一次瞬时冲量)
## ============================================================

## 加速带类型: "addspeed" (普通加速带, 白色方块) / "shoot" (强力弹射器, 跳台)
@export var pad_type: String = "addspeed"

## 推力强度 (沿车头水平方向). 作为"目标增加的速度", 越大冲量越强
## AddSpeed 推荐 15~25, Shoot 推荐 30~45
@export var boost_speed_kick: float = 20.0

## 持续推力时间 (秒). 0 = 仅一次性冲量; > 0 = 在此时间内持续施力
@export var boost_duration: float = 0.4

## 触发冷却 (秒). 车离开前重复进入不会重复触发
@export var retrigger_cooldown: float = 0.5

# 已经触发过的 car 字典: { car_instance_id: cooldown_end_time }
var _recent_triggered: Dictionary = {}


func _ready() -> void:
	# Area3D 默认不接收 body 信号, 要手动开启 monitoring
	monitoring = true
	monitorable = false   # 自己不需要被其他 Area 探测
	# ⚠️ car.tscn 里 car 的 collision_layer = 2 (不是默认 1)
	#    Area3D 默认 collision_mask = 1, 所以这里要改成 2 才能探测到车
	collision_mask = 2
	# Area 自己不参与物理碰撞, collision_layer 保持默认 1 (或设 0 更干净)
	collision_layer = 0
	# 连接信号
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node) -> void:
	# 只处理车 (car 在 "car" group 或是 RigidBody3D 且有 apply_speed_pad_boost 方法)
	if not body.has_method("apply_speed_pad_boost"):
		return
	# 冷却检查
	var now: float = Time.get_ticks_msec() / 1000.0
	var key: int = body.get_instance_id()
	if _recent_triggered.has(key) and _recent_triggered[key] > now:
		return
	_recent_triggered[key] = now + retrigger_cooldown
	# 触发加速
	body.apply_speed_pad_boost(boost_speed_kick, boost_duration, pad_type)
	print("[SpeedPad:", name, "] 触发! type=", pad_type, " kick=", boost_speed_kick, " dur=", boost_duration)
