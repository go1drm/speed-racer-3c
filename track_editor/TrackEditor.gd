extends Node3D
## ============================================================
##  赛道编辑器 — 主控制器
##
##  职责:
##   · 提供 3D 视口 + 自由飞行相机 (WASD+鼠标右键)
##   · 左侧 UI 面板: 选积木 / 选锚点工具 / 保存 / 加载 / 测试
##   · 鼠标左键: 放置当前选中的工具 (积木 or 锚点)
##   · 鼠标右键拖动: 旋转视角
##   · 滚轮: 视角前后
##   · 数字键 1~7: 快速选积木
##   · A 键: 切到锚点工具
##   · Ctrl+Z: 撤销最近一次添加
##   · 鼠标 hover 在已放置积木/锚点上, 按 Delete 删除
##   · F5: 测试当前赛道 (生成临时 .tscn 并切换场景)
##
##  数据流:
##   编辑期间, 所有积木 instance 在 _placed_root 节点下作为子节点
##   _placed_blocks: Array[Dictionary] 记录每个积木的 {id, node}, 用于撤销/保存/序列化
##   _placed_anchors: Array[Dictionary] 同上 {pos, anchor_radius, detect_radius, color, node}
##
##  保存:
##   把 _placed_blocks/_placed_anchors 转成 RaceTrackData, save 到 user://tracks/<name>.tres
## ============================================================

# 用 preload 拿到类引用, 避免 class_name 注册顺序问题导致 parse error
# (class_name 在跨文件引用时如果初次解析失败会进入"未注册"状态, 直到重启编辑器才修复;
#  preload 则强制按文件路径解析, 总是有效)
const RaceTrackDataScript := preload("res://track_editor/RaceTrackData.gd")
const TrackBlockScript    := preload("res://track_editor/TrackBlock.gd")

# 积木资源映射 (id -> .tscn 路径)
# 注意: speed_pad / spawn_point / anchor 也走这套, 但它们是"机关"不是"路段积木"
# 在 BLOCK_INFO 里只列路段积木, 机关单独走 MECHANISM_INFO
const BLOCK_LIBRARY: Dictionary = {
	"straight_short": "res://track_editor/blocks/straight_short.tscn",
	"straight_long":  "res://track_editor/blocks/straight_long.tscn",
	"turn_90_left":   "res://track_editor/blocks/turn_90_left.tscn",
	"turn_90_right":  "res://track_editor/blocks/turn_90_right.tscn",
	"turn_180":       "res://track_editor/blocks/turn_180.tscn",
	"speed_pad":      "res://track_editor/blocks/speed_pad.tscn",
	"finish_line":    "res://track_editor/blocks/finish_line.tscn",
	"wall":           "res://track_editor/blocks/wall.tscn",
	# === 毒图机关 ===
	# pitfall   : 毒坑 (触发即复位)
	# laser_gate: 激光闸门 (周期扫动 + 命中冲击)
	# toxic_fog : 毒雾区 (持续减速)
	"pitfall":        "res://track_editor/blocks/pitfall.tscn",
	"laser_gate":     "res://track_editor/blocks/laser_gate.tscn",
	"toxic_fog":      "res://track_editor/blocks/toxic_fog.tscn",
	# === 物理趣味机关 ===
	# flip_board       : 固定跳板 (踩上翻起 + 固定方向冲量)
	# spring_mushroom  : 弹簧蘑菇 (向上弹力, 保留水平速度)
	# gravity_cylinder : 反重力圆柱 (吸附到表面可倒挂)
	# gravity_wall     : 反重力墙面 (吸附到墙面行驶)
	# gravity_arc      : 反重力弧面 (沿弧面吸附行驶, 像扬起跳台)
	"flip_board":       "res://track_editor/blocks/flip_board.tscn",
	"spring_mushroom":  "res://track_editor/blocks/spring_mushroom.tscn",
	"gravity_cylinder": "res://track_editor/blocks/gravity_cylinder.tscn",
	"gravity_wall":     "res://track_editor/blocks/gravity_wall.tscn",
	"gravity_arc":      "res://track_editor/blocks/gravity_arc.tscn",
	"spike":            "res://track_editor/blocks/spike.tscn",
	"windmill":         "res://track_editor/blocks/windmill.tscn",
	"fragile_narrow":   "res://track_editor/blocks/fragile_narrow.tscn",
	"pithole":          "res://track_editor/blocks/pithole.tscn",
	"hard_wall":        "res://track_editor/blocks/hard_wall.tscn",
	"face_wall":        "res://track_editor/blocks/face_wall.tscn",
	"seesaw":           "res://track_editor/blocks/seesaw.tscn",
	"slider":           "res://track_editor/blocks/slider.tscn",
	"pendulum":         "res://track_editor/blocks/pendulum.tscn",
	"color_gate":       "res://track_editor/blocks/color_gate.tscn",
	"narrow_path":      "res://track_editor/blocks/narrow_path.tscn",
	"spring":           "res://track_editor/blocks/spring.tscn",
	"trigger_spring":   "res://track_editor/blocks/trigger_spring.tscn",
	"star_trail":       "res://track_editor/blocks/star_trail.tscn",
	"right_angle_path": "res://track_editor/blocks/right_angle_path.tscn",
}

# 路段积木显示信息 (UI 列表用)
# 窄道系列已取代旧积木成为主要赛道构建工具
const BLOCK_INFO: Array = [
	{"id": "narrow_path",      "label": "🛤️ 窄道",     "hotkey": KEY_1},
	{"id": "fragile_narrow",   "label": "💔 易碎窄道",  "hotkey": KEY_2},
	{"id": "right_angle_path", "label": "📐 直角窄道",  "hotkey": KEY_3},
	{"id": "star_trail",       "label": "⭐ 绳星轨迹",  "hotkey": KEY_4},
]

# 机关显示信息 (UI 机关栏用) — 独立于路段积木, 走机关栏 UI
# 用户要求: 加速带 / 钩索锚点 / 出生点 都属于机关, 未来新增机关也加这里
# 每项格式:
#   id     : 唯一标识 (与 _placed_items 的 id 字段一致, 序列化用)
#   label  : UI 显示名
#   hotkey : 可选热键 (0 表示无). 数字键 1~5 已经被路段积木占用, 机关用 6/7/8
#   kind   : 内部分类: "block"=走 BLOCK_LIBRARY tscn 实例化; "anchor"=代码生成锚点; "spawn"=唯一出生点
const MECHANISM_INFO: Array = [
	{"id": "speed_pad",   "label": "🟨 加速带",  "hotkey": KEY_6, "kind": "block"},
	{"id": "finish_line", "label": "🏁 终点",    "hotkey": KEY_9, "kind": "block"},
	{"id": "wall",        "label": "🧱 墙",      "hotkey": KEY_0, "kind": "block"},
	{"id": "anchor",      "label": "🪝 钩索锚点", "hotkey": KEY_7, "kind": "anchor"},
	{"id": "spawn_point", "label": "🟢 出生点",  "hotkey": KEY_8, "kind": "spawn"},
	# === 毒图机关 (无热键, 用鼠标点击放置) ===
	{"id": "pitfall",     "label": "🕳️ 毒坑",    "hotkey": 0,     "kind": "block"},
	{"id": "laser_gate",  "label": "⚡ 激光闸门", "hotkey": 0,     "kind": "block"},
	{"id": "toxic_fog",   "label": "🌪️ 毒雾区",  "hotkey": 0,     "kind": "block"},
	# === 物理趣味机关 ===
	{"id": "flip_board",       "label": "🪂 固定跳板",   "hotkey": 0, "kind": "block"},
	{"id": "spring_mushroom",  "label": "🍄 弹簧蘑菇",   "hotkey": 0, "kind": "block"},
	{"id": "gravity_cylinder", "label": "🌀 反重力圆柱", "hotkey": 0, "kind": "block"},
	{"id": "gravity_wall",     "label": "🧱 反重力墙面", "hotkey": 0, "kind": "block"},
	{"id": "gravity_arc",      "label": "🌈 反重力弧面", "hotkey": 0, "kind": "block"},
	{"id": "spike",            "label": "🔺 地刺",       "hotkey": 0, "kind": "block"},
	{"id": "windmill",         "label": "🌀 大风车",     "hotkey": 0, "kind": "block"},
	{"id": "fragile_narrow",   "label": "💔 易碎窄道",   "hotkey": 0, "kind": "block"},
	{"id": "pithole",          "label": "🕳️ 凹坑",       "hotkey": 0, "kind": "block"},
	{"id": "hard_wall",        "label": "🧱 硬墙",       "hotkey": 0, "kind": "block"},
	{"id": "face_wall",        "label": "😊 笑脸墙来了", "hotkey": 0, "kind": "block"},
	{"id": "seesaw",           "label": "⚖️ 跷跷板",     "hotkey": 0, "kind": "block"},
	{"id": "slider",           "label": "🛗 往复滑块",   "hotkey": 0, "kind": "block"},
	{"id": "pendulum",         "label": "🕰️ 钟摆平台",   "hotkey": 0, "kind": "block"},
	{"id": "color_gate",       "label": "🚦 红蓝门",     "hotkey": 0, "kind": "block"},
	{"id": "spring",           "label": "🔵 弹簧",      "hotkey": 0, "kind": "block"},
	{"id": "trigger_spring",   "label": "🟠 触发弹簧",  "hotkey": 0, "kind": "block"},
]

# 工具枚举: 当前鼠标点击会做什么
# SELECT  : 默认工具, 鼠标点击=选中已放置积木, hover 高亮 (不放新积木)
# BLOCK   : 选了具体积木, 鼠标点击=放新积木 (按 ESC 切回 SELECT). 也用于加速带等"机关型 .tscn"
# ANCHOR  : 锚点工具, 鼠标点击=放钩索锚点 (按 ESC 切回 SELECT)
# SPAWN   : 出生点工具, 鼠标点击=移动唯一出生点到鼠标位置 (出生点全场只一个, 不会"放置多次")
# PRESET  : 放预设组合
enum Tool { SELECT, BLOCK, ANCHOR, PRESET, SPAWN }
var _current_tool: int = Tool.SELECT
var _selected_block_id: String = "straight_short"

# Hover 状态 (仅 SELECT 模式下生效)
# _hovered_block_index: 鼠标当前悬停的积木索引, -1 表示没 hover
# 进入 / 离开 hover 时给 mesh 加 / 去蓝色 emission
var _hovered_block_index: int = -1
var _hover_highlight_orig_mats: Dictionary = {}   # MeshInstance3D -> 原 material_override

# 节点引用 (在 _ready 解析)
@onready var _cam: Camera3D = $EditorCamera
@onready var _placed_root: Node3D = $PlacedItems
@onready var _ground: Node3D = $Ground
# 初始地面 (Ground) 配置 — 用户要求左侧面板能开关 + 改颜色
# 数据保存到 RaceTrackData, TrackRunner 加载时应用到场景里的 Ground 节点
# 编辑器场景里也即时构造一个对应的 PlaneMesh + 颜色 (走 _rebuild_editor_ground)
var _ground_enabled: bool = true
var _ground_color: Color = Color(0.45, 0.5, 0.55, 1.0)
# 当前打开的赛道文件路径 (用于"保存"覆盖写入). 空 = 新建赛道, "保存"行为等同"另存为"
var _current_track_path: String = ""
var _ground_mesh_inst: MeshInstance3D = null   # 编辑器内可见的地面 mesh, _rebuild_editor_ground 创建
@onready var _ui: CanvasLayer = $UI
# 预览节点 (跟随鼠标显示半透明积木/锚点)
var _preview_node: Node3D = null
# 已放置物 (路段积木 + 加速带 + 钩索锚点 + 出生点) 统一存这一个数组
# 每条字典格式: {"id": String, "node": Node3D, "kind": String}
#   kind ∈ {"block", "speed_pad", "anchor", "spawn"}
#     "block"     : 路段积木 (直道/弯道), 走 BLOCK_LIBRARY tscn 实例化, 走 RaceTrackData.blocks
#     "speed_pad" : 加速带, 也走 BLOCK_LIBRARY tscn 实例化, 也走 RaceTrackData.blocks (运行时由 SpeedPad.gd 触发)
#     "anchor"    : 钩索锚点, 代码生成视觉, 走 RaceTrackData.grapple_anchors
#     "spawn"     : 唯一出生点, 不能被删除 (clear/delete 都跳过), 走 RaceTrackData.spawn_position/yaw
# 这样选中/拖拽/Undo/参数编辑全部自动适用所有 kind, 不再需要单独的 _placed_anchors 数组
var _placed_blocks: Array = []

# 自由相机控制
var _cam_yaw: float = 0.0
var _cam_pitch: float = -0.4    # 默认略往下看
var _cam_distance: float = 50.0  # 视点距离 (滚轮控制)
var _cam_focus: Vector3 = Vector3.ZERO   # 相机看的中心点 (WASD 平移)
const CAM_MOVE_SPEED: float = 30.0
const CAM_MOVE_SPEED_MAX: float = 150.0   # 长按加速后的最大速度
const CAM_ACCEL_DELAY: float = 0.4        # 按住多久后开始加速 (秒)
const CAM_ACCEL_RAMP: float = 2.5         # 加速斜率 (每秒倍率增长)
const CAM_ROTATE_SENSITIVITY: float = 0.005
const CAM_ZOOM_SPEED: float = 5.0
var _is_rotating_cam: bool = false
# 长按加速: 累计按住 WASD 的时间
var _cam_move_hold_time: float = 0.0
# A 键焦点诊断: 第一次按 A 触发"焦点抢救"时打印一行, 帮助定位 Bug
var _logged_a_focus: bool = false

# 出生点位置 (玩家在编辑器里可见, 默认在第一块入口)
var _spawn_marker: Node3D = null
var _spawn_position: Vector3 = Vector3(0.0, 1.0, 0.0)
var _spawn_yaw: float = 0.0

# ---- 网格吸附 ----
# 整个编辑器世界用网格规划, 默认 4m × 4m × 1m (XZ 大间距, Y 小间距方便上下叠斜坡)
# 鼠标位置自动吸附到最近的网格点, 让玩家不用担心积木首尾对齐
# UI 上有滑块可改, 也可以临时按住 Alt 关闭吸附 (自由放置)
var _grid_step_xz: float = 4.0
var _grid_step_y: float  = 1.0
var _grid_snap_enabled: bool = true
var _grid_step_xz_label: Label = null
var _grid_step_xz_slider: HSlider = null
var _grid_step_y_label: Label = null
var _grid_step_y_slider: HSlider = null
# 当前放置的 Y 高度 (Shift + 滚轮可调, 让玩家在不同层叠积木)
# BLOCK 模式: 预览节点的 Y = 鼠标地面点 + _place_y_offset
# 0 = 贴地, 4 = 放在地面上方 4m, -4 = 在地面下 4m (做地下隧道)
var _place_y_offset: float = 0.0
var _y_offset_label: Label = null
# 网格地面 mesh 节点引用 (在 _build_grid_mesh 创建)
var _grid_mesh_node: MeshInstance3D = null

# ---- 已选中积木 (点击已放置的积木后选中, UI 显示坐标 SpinBox 可调) ----
# 选中后会高亮该积木 (覆盖 emission 黄色), 点空白处取消选中
# Ctrl+点击 = 多选 (加入 / 移出 _selected_block_indices). 多选时:
#   · _selected_block_index = -1 (单选指针失效)
#   · _selected_block_indices.size() >= 2
#   · 参数面板隐藏积木参数, 只显示坐标 (改坐标 = 对所有选中做"相对第一项的偏移"应用)
#   · 出现 "💾 保存为预设" 按钮, 点击把当前组合写入 user://block_presets.tres
# 单选时: _selected_block_index >= 0 且 _selected_block_indices = [_selected_block_index]
var _selected_block_index: int = -1   # _placed_blocks 数组的索引, -1 = 未选中
var _selected_block_indices: Array = []   # Array[int] 多选索引 (单选时 [_selected_block_index])
var _selected_anchor_index: int = -1  # _placed_anchors 索引
# ---- 已选中积木的"鼠标拖动重新摆放" ----
# 点击已选中积木后, 按住鼠标左键拖动 → 在 XZ 平面跟随鼠标 (保留原 Y / 应用网格吸附)
# 多选时整组一起平移 (delta = new_first_pos - old_first_pos), 与 SpinBox 改坐标的语义一致
# 状态:
#   _is_dragging_selected: 是否在拖动中
#   _drag_start_mouse_world: 拖动开始时鼠标的世界点 (XZ 平面 = first node 的 Y 高度)
#   _drag_start_positions: Array[Vector3] 各选中节点拖动开始时的 global_position 备份
#   _drag_vertical_mode: 是否处于"纵向 Y 拖拽"模式 (按住 Shift 进入)
#                        在此模式下鼠标移动只改变选中物的 Y 高度, XZ 不变
var _is_dragging_selected: bool = false
var _drag_start_mouse_world: Vector3 = Vector3.ZERO
var _drag_start_positions: Array = []   # Array[Vector3]
var _drag_plane_y: float = 0.0           # 拖动用的水平面 Y (取第一个选中积木的 Y)
var _drag_vertical_mode: bool = false    # true = Shift 按下进入 Y 拖拽模式
# ---- 窄道手柄拖拽 ----
var _is_dragging_handle: bool = false
var _dragging_handle_name: String = ""   # "start"/"mid"/"end" 或 "wall_L_0"/"wall_R_1" 等
var _dragging_handle_block: Node3D = null
var _drag_handle_plane_y: float = 0.0
# 手柄模式: 0=路径手柄, 1=左墙手柄, 2=右墙手柄
var _wall_handle_mode: int = 0  # H 键循环切换
# 3D 世界中线长度标签
var _path_length_label_3d: Label3D = null
# 手柄拖拽 undo: 拖拽前的参数快照
var _drag_handle_params_before: Dictionary = {}
var _drag_handle_block_idx: int = -1
# 选中编辑面板的 SpinBox 引用 (在 _build_ui 创建, _on_selection_changed 时更新)
var _sel_panel: VBoxContainer = null
var _sel_x_spin: SpinBox = null
var _sel_y_spin: SpinBox = null
var _sel_z_spin: SpinBox = null
var _sel_yaw_spin: SpinBox = null
var _sel_pitch_spin: SpinBox = null
var _sel_roll_spin: SpinBox = null
var _sel_title_label: Label = null
# 动态参数区域 (根据选中积木的 get_editable_params() 实时构建 SpinBox)
var _sel_params_container: VBoxContainer = null
# 拖拽坐标标签的状态: 哪个标签正在被拖
# {label: Label 节点, axis_kind: "pos"/"rot", axis: 0/1/2, start_x: float, start_value: float}
var _drag_label_state: Dictionary = {}
# 选中高亮材质 (黄色描边 + 呼吸闪烁)
var _selection_highlight_orig_mats: Dictionary = {}  # MeshInstance3D -> 原材质 (取消选中时还原)
var _selection_highlight_mats: Array = []            # 选中节点的克隆材质数组, 呼吸动画时直接改它们的 emission_energy
var _breathe_t: float = 0.0                          # 呼吸动画时间累积 (秒), 用于 sin 计算

# 放置时的额外姿态调整 (相对磁吸出口锚点应用)
# yaw   : 绕世界 Y 轴, 让玩家"扭"积木水平方向 (如把直道转 30° 接出叉路)
# pitch : 绕本地 X 轴, 让直道变斜坡 (上坡 +pitch, 下坡 -pitch)
# roll  : 绕本地 Z 轴, 让积木侧倾 (做 banked turn / 倾斜跳台)
# 这三个值会叠加到 _compute_attach_transform_for_preview 的输出上, 也写到放置后的节点 global_transform
# 用 UI Slider 改, 也用快捷键 Q/E (yaw)、R/F (pitch)、Z/X (roll) 微调
var _place_yaw_deg: float = 0.0
var _place_pitch_deg: float = 0.0
var _place_roll_deg: float = 0.0
# UI 滑块引用 (在 _build_ui 里赋值, _set_place_*_deg 时同步刷新)
var _yaw_slider: HSlider = null
var _yaw_label: Label = null
var _pitch_slider: HSlider = null
var _pitch_label: Label = null
var _roll_slider: HSlider = null
var _roll_label: Label = null
# 放置角度的 SpinBox (用户要求: 可拖拽数字 + 直接键入), 与上面 slider 双向同步
var _yaw_spin: SpinBox = null
var _pitch_spin: SpinBox = null
var _roll_spin: SpinBox = null

# ---- 编辑器持久化设置 ----
# 存放在 user://editor_settings.cfg, 启动时加载, 改了立即写回. 内容:
#   [spin_steps] 各 SpinBox 的步长 (key = "pos"/"rot"/"param:length" 等, value = 0.01~10.0)
#   [param_ranges] 机关参数的 min/max/step 覆盖 (key = "<block_id>:<param_key>", value = {min,max,step})
#   _spin_step_overrides 是内存里的字典, key 用约定: "pos"(三个坐标共用)/"rot"(三个角度共用)/"param:<参数key>"
const EDITOR_SETTINGS_PATH := "user://editor_settings.cfg"
var _spin_step_overrides: Dictionary = {}   # key -> step (float)
# 用户在弹窗里改的"参数范围"覆盖, 重建参数面板时优先用这个
# key 格式: "<block_id>:<param_key>" 例 "gravity_cylinder:gravity_strength"
# value 格式: {"min": float, "max": float, "step": float}  (任意字段缺失走 get_editable_params 默认)
var _param_range_overrides: Dictionary = {}

# ---- 连续修改合并 (防止爆 undo 栈) ----
# 用户需求 (2026-06-02): "参数填写应该可以 ctrl+z 回溯"
# 原 bug: SpinBox value_changed 在拖拽/连续输入时每帧触发, 每次都 _undo_push,
#         拖一下要按几十次 Ctrl+Z 才回到原值
# 修复: 用 "idle merge" 模式
#   每次 value_changed 不立刻 push, 而是更新 _pending_undo (内存缓存最新的 new_value)
#   连续 PARAM_UNDO_FLUSH_DELAY 秒没新修改 → 自动 flush 一条 undo 入栈
#   Ctrl+Z 之前也要先 flush (避免丢失最后一段未入栈的修改)
#
# _pending_undo 结构 (空 = 没有待 flush):
#   {"op": "param"/"color"/"range", "index", "key", "old_value", "new_value", "timer"}
#   timer 倒计时, 在 _process 里 -=delta, ≤0 就 flush
const PARAM_UNDO_FLUSH_DELAY: float = 0.4
var _pending_undo: Dictionary = {}

# ---- 视觉参数 (用户可调, 持久化到 editor_settings.cfg [visual]) ----
# 默认值与 TrackEditor.tscn 里 sub_resource Env1 / DirectionalLight3D 一致
# 改了立即应用到 WorldEnvironment.environment 和 DirectionalLight3D
var _visual_sun_energy: float = 1.6        # 太阳光 (DirectionalLight3D.light_energy)
var _visual_ambient_energy: float = 1.4    # 环境光 (Environment.ambient_light_energy)
var _visual_sky_contribution: float = 0.55 # 天空对环境光贡献 (Environment.ambient_light_sky_contribution)
var _visual_exposure: float = 1.1          # tonemap 曝光 (Environment.tonemap_exposure)
# UI 引用 (滑块 + label, 改值时同步刷新文字显示)
var _vis_sun_label: Label = null
var _vis_amb_label: Label = null
var _vis_sky_label: Label = null
var _vis_exp_label: Label = null

# ---- 积木组合预设 (Ctrl 多选 → 保存为预设) ----
# 保存到 user://block_presets.cfg (ConfigFile 格式, 比 .tres 更稳, 不需要 Resource 自定义类)
# 内部存格式 (一个 section/preset):
#   [preset_<index>]
#   name = "组合A"
#   item_0_id = "straight_short"
#   item_0_xform = "1,0,0,0,1,0,0,0,1,0,0,0"   (Transform3D 12 个 float, 逗号分隔)
#   item_1_id = ...
#   item_1_xform = ...
#   item_count = 3
const BLOCK_PRESETS_PATH := "user://block_presets.cfg"
var _block_presets: Array = []          # Array of preset dicts
var _bottom_blocks_hbox: HBoxContainer = null   # 底部积木 HBox 引用 (动态加预设按钮)
# 机关栏宽度同步: 让机关栏的 ScrollContainer 自动 match 积木栏 panel 宽度 (用户要求"一样宽")
var _bottom_blocks_panel: PanelContainer = null  # 积木栏 panel 引用 (用于读宽度)
var _mech_scroll: ScrollContainer = null         # 机关栏 ScrollContainer 引用 (用于设宽度)

# ---- 当前正在放置的预设 (Tool.PRESET 模式时用) ----
# 选了某个预设后, 进入 PRESET 模式: 鼠标移动 = 整组预览跟随, 点击 = 整组放下
var _current_preset_index: int = -1   # _block_presets 里的索引
var _preset_preview_nodes: Array = [] # PRESET 模式下的预览节点列表


func _ready() -> void:
	# 先加载持久化设置 (步长 overrides + 视觉参数), 再 build UI 这样 SpinBox 就能用对的步长
	_load_editor_settings()
	_load_block_presets()
	_build_ui()
	# 关键修复: 把所有 Button / OptionButton / CheckBox 等的 focus_mode 设成 NONE
	# 否则点过任何按钮后, 焦点留在按钮上, A/D 等字母键会被 Button 当成焦点导航键吞掉,
	# 导致 WASD 平移视角"按 A 没反应". 这是 Godot 4 的默认行为, 需要主动关掉.
	# (LineEdit / SpinBox 不在此列表, 它们的焦点是合法编辑场景, 由 _physics_process 单独判断)
	_disable_button_focus_recursive(_ui)
	_build_spawn_marker()
	_build_grid_mesh()
	_rebuild_editor_ground()
	# 应用从 cfg 加载的视觉参数到场景灯光/环境 (覆盖 .tscn 里的默认值)
	_apply_visual_settings()
	_update_camera_transform()
	# 默认 SELECT 模式 (玩家可以直接点已放置的积木选中, ESC 也是回到这个模式)
	# 选了积木按钮 / 数字键 1-7 才进 BLOCK 放置模式
	_set_tool(Tool.SELECT, "")
	# 如果 SceneSelectorUI / 上一次 F5 测试通过 TrackRunnerState.last_editor_track_path 指定了
	# "打开已有赛道", 自动加载. 这样玩家从 TrackRunner 按 ESC 返编辑器时不会丢失刚搭的赛道.
	# 注意: 不清掉 last_editor_track_path, 这样多次 F5 测试 ↔ 编辑器循环都能保留状态;
	#       只有玩家点"清空"按钮时才主动清掉
	var st: Node = get_node_or_null("/root/TrackRunnerState")
	if st and "last_editor_track_path" in st:
		var p: String = String(st.get("last_editor_track_path"))
		if p != "" and (FileAccess.file_exists(ProjectSettings.globalize_path(p)) or ResourceLoader.exists(p)):
			_load_track_data(p)
		# 恢复 F5 测试前的正式赛道路径 (避免 _test.tres 覆盖导致"保存"变"另存为")
		if "original_track_path" in st:
			var orig: String = String(st.get("original_track_path"))
			if orig != "":
				_current_track_path = orig


# ============================================================
#  UI 构建
# ============================================================
func _build_ui() -> void:
	# 左侧工具栏面板 (固定宽 260, 加 ScrollContainer 让内容能滚动)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	panel.offset_left = 8
	panel.offset_top = 8
	panel.offset_right = 8 + 260
	panel.offset_bottom = -8
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.13, 0.94)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	sb.border_color = Color(1.0, 0.85, 0.3, 0.6)
	sb.border_width_left = 1; sb.border_width_right = 1
	sb.border_width_top = 1; sb.border_width_bottom = 1
	panel.add_theme_stylebox_override("panel", sb)
	_ui.add_child(panel)

	# ScrollContainer 让左面板内容超出时能滚动 (修复"内容太长看不到下面")
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vb)

	# 标题
	var title := Label.new()
	title.text = "🛣️ 赛道编辑器"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	vb.add_child(title)

	# 操作说明 (折叠在小字)
	var hint := RichTextLabel.new()
	hint.bbcode_enabled = true
	hint.fit_content = true
	hint.scroll_active = false
	hint.text = "[color=#aaa]默认=选择模式 (hover 高亮, 点选, Ctrl+点击多选) | 选积木后变放置模式 (ESC 退出) | 右键=旋转视角 | 滚轮=缩放 | WASD=平移 | 1-5 选积木 | 6-8 机关 | Alt 开吸附 | Del 删除 | R 旋转 | Ctrl+Z 撤销 | Ctrl+Y 重做 | F5 测试[/color]"
	hint.add_theme_font_size_override("normal_font_size", 11)
	vb.add_child(hint)

	vb.add_child(HSeparator.new())

	# 选择模式按钮 (默认工具, 点 UI 也能切回)
	var select_btn := Button.new()
	select_btn.text = "  👆 选择模式 (默认, ESC 返回)"
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.custom_minimum_size = Vector2(220, 30)
	select_btn.add_theme_font_size_override("font_size", 12)
	select_btn.add_theme_color_override("font_color", Color(0.6, 0.95, 1.0))
	select_btn.pressed.connect(func() -> void:
		_set_tool(Tool.SELECT, "")
	)
	vb.add_child(select_btn)

	vb.add_child(HSeparator.new())

	# 锚点 / 加速带 / 出生点等"机关"已移到底部机关栏 (与积木栏紧贴, 见 _build_ui 末尾)
	# 这里左侧栏不再放机关按钮 (避免重复入口 + 节省左侧空间)

	vb.add_child(HSeparator.new())

	# 注: 放置角度滑块组已经从左侧移到右下角 (RightDock 里). 在 _build_right_dock 函数构建.
	# 这里只保留左侧栏的"全局功能" (网格吸附 / 操作按钮 / 返回主菜单)

	# ============================================================
	# 已选中积木编辑面板 (点击已放置积木后显示三维坐标 SpinBox)
	# 设计要点 (用户反馈):
	#   1) 用户要求加锚点 — 改用 BOTTOM_RIGHT preset, 不会超出屏幕
	#   2) 用户要求步长 = 0.01 (默认), SpinBox 右键能改步长 + 持久化保存
	#   3) Ctrl 多选时显示 "💾 保存为预设" 按钮
	# 实际节点结构: 这个 sel_panel_outer 是 RightDock 的子节点 (在 _build_right_dock 创建),
	#              这里仅保留对其内部 _sel_panel 子节点的填充逻辑.
	# 设计: 默认隐藏整个 sel_panel_outer (面板容器), 仅在 _selected_block_index >= 0 时 visible=true
	#       SpinBox 改值 → 立即更新选中节点的 global_position 或 basis
	var sel_panel_outer: PanelContainer = _build_right_dock()
	# 右下角的"组合面板"已经在 _build_right_dock() 里建完, 这里不再插入任何选中编辑内容.
	# (sel_panel_outer 是 _build_right_dock 返回的下半部分 panel, 默认 visible=false)

	vb.add_child(HSeparator.new())

	# ============================================================
	# 网格吸附设置
	# ============================================================
	var grid_label := Label.new()
	grid_label.text = "🔲 网格吸附"
	grid_label.add_theme_font_size_override("font_size", 13)
	grid_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	vb.add_child(grid_label)

	var grid_cb := CheckBox.new()
	grid_cb.text = " 启用网格吸附 (按 Alt 临时开启)"
	grid_cb.button_pressed = _grid_snap_enabled
	grid_cb.add_theme_font_size_override("font_size", 11)
	grid_cb.toggled.connect(func(on: bool) -> void: _grid_snap_enabled = on)
	vb.add_child(grid_cb)

	_grid_step_xz_label = Label.new()
	_grid_step_xz_label.text = "XZ 步长: %.1f m" % _grid_step_xz
	_grid_step_xz_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(_grid_step_xz_label)
	_grid_step_xz_slider = HSlider.new()
	_grid_step_xz_slider.min_value = 0.5
	_grid_step_xz_slider.max_value = 10.0
	_grid_step_xz_slider.step = 0.5
	_grid_step_xz_slider.value = _grid_step_xz
	_grid_step_xz_slider.custom_minimum_size = Vector2(220, 16)
	_grid_step_xz_slider.value_changed.connect(func(v: float) -> void:
		_grid_step_xz = v
		_grid_step_xz_label.text = "XZ 步长: %.1f m" % v
		_rebuild_grid_lines()
	)
	vb.add_child(_grid_step_xz_slider)

	# Y 步长 (放置 Y 高度按这个步长 Shift+滚轮调)
	_grid_step_y_label = Label.new()
	_grid_step_y_label.text = "Y 步长: %.1f m" % _grid_step_y
	_grid_step_y_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(_grid_step_y_label)
	_grid_step_y_slider = HSlider.new()
	_grid_step_y_slider.min_value = 0.25
	_grid_step_y_slider.max_value = 5.0
	_grid_step_y_slider.step = 0.25
	_grid_step_y_slider.value = _grid_step_y
	_grid_step_y_slider.custom_minimum_size = Vector2(220, 16)
	_grid_step_y_slider.value_changed.connect(func(v: float) -> void:
		_grid_step_y = v
		_grid_step_y_label.text = "Y 步长: %.1f m" % v
	)
	vb.add_child(_grid_step_y_slider)

	# 当前 Y 高度层显示 (Shift+滚轮 调)
	_y_offset_label = Label.new()
	_y_offset_label.text = "Y 高度层: %.1f m  (Shift+滚轮)" % _place_y_offset
	_y_offset_label.add_theme_font_size_override("font_size", 11)
	_y_offset_label.add_theme_color_override("font_color", Color(0.4, 0.95, 1.0))
	vb.add_child(_y_offset_label)
	# Y 高度归零按钮
	var btn_y_zero := Button.new()
	btn_y_zero.text = "↺ Y 高度归零"
	btn_y_zero.custom_minimum_size = Vector2(220, 24)
	btn_y_zero.add_theme_font_size_override("font_size", 11)
	btn_y_zero.pressed.connect(func() -> void: _set_place_y_offset(0.0))
	vb.add_child(btn_y_zero)

	# 拖拽快捷键提示 (用户需求 2026-06-02: 按住 Shift 纵向拖拽)
	var drag_hint := Label.new()
	drag_hint.text = "💡 拖拽机关时按住 Shift = 改 Y 高度"
	drag_hint.add_theme_font_size_override("font_size", 11)
	drag_hint.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	drag_hint.tooltip_text = "选中机关后用鼠标拖动:\n· 默认 = XZ 平面横向移动 (无吸附)\n· 按住 Shift = 改 Y 高度 (纵向)\n· 按住 Alt = 启用网格吸附"
	vb.add_child(drag_hint)

	vb.add_child(HSeparator.new())

	# 操作按钮
	var actions_label := Label.new()
	actions_label.text = "🛠️ 操作"
	actions_label.add_theme_font_size_override("font_size", 13)
	actions_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	vb.add_child(actions_label)

	var btn_save := Button.new()
	btn_save.text = "💾 保存"
	btn_save.custom_minimum_size = Vector2(220, 32)
	btn_save.tooltip_text = "覆盖保存到当前打开的赛道文件 (如果是新赛道则弹出另存为)"
	btn_save.pressed.connect(_on_save_overwrite_pressed)
	vb.add_child(btn_save)

	var btn_save_as := Button.new()
	btn_save_as.text = "💾 另存为..."
	btn_save_as.custom_minimum_size = Vector2(220, 32)
	btn_save_as.tooltip_text = "输入新名字保存为一个新的赛道文件"
	btn_save_as.pressed.connect(_on_save_pressed)
	vb.add_child(btn_save_as)

	var btn_load := Button.new()
	btn_load.text = "📂 加载赛道..."
	btn_load.custom_minimum_size = Vector2(220, 32)
	btn_load.pressed.connect(_on_load_pressed)
	vb.add_child(btn_load)

	# 删除已保存的赛道文件 (从 user://tracks/ 删 .tres)
	# 用户要求: "现在没有删除赛道的功能". 单独按钮, 弹文件选择对话框 + 二次确认
	var btn_delete := Button.new()
	btn_delete.text = "❌ 删除已保存赛道..."
	btn_delete.custom_minimum_size = Vector2(220, 28)
	btn_delete.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
	btn_delete.pressed.connect(_on_delete_track_pressed)
	vb.add_child(btn_delete)

	var btn_test := Button.new()
	btn_test.text = "▶ 测试 (F5)"
	btn_test.custom_minimum_size = Vector2(220, 32)
	btn_test.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6))
	btn_test.pressed.connect(_on_test_pressed)
	vb.add_child(btn_test)

	var btn_clear := Button.new()
	btn_clear.text = "🗑️ 清空"
	btn_clear.custom_minimum_size = Vector2(220, 28)
	btn_clear.pressed.connect(_on_clear_pressed)
	vb.add_child(btn_clear)

	var btn_back := Button.new()
	btn_back.text = "◀ 返回主菜单"
	btn_back.custom_minimum_size = Vector2(220, 28)
	btn_back.pressed.connect(_on_back_pressed)
	vb.add_child(btn_back)

	vb.add_child(HSeparator.new())

	# ============================================================
	# 🌍 初始地面 (Ground) - 用户要求左侧能开关 + 调色
	# ============================================================
	# 数据存到 RaceTrackData.ground_enabled / ground_color, TrackRunner 加载时应用
	# 编辑器内的 mesh 由 _rebuild_editor_ground 生成 (位于 $Ground 节点下), 改值即时刷新
	var ground_label := Label.new()
	ground_label.text = "🌍 初始地面"
	ground_label.add_theme_font_size_override("font_size", 13)
	ground_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	vb.add_child(ground_label)
	# 开关 CheckBox
	var ground_chk := CheckBox.new()
	ground_chk.text = "  显示初始地面"
	ground_chk.button_pressed = _ground_enabled
	ground_chk.add_theme_font_size_override("font_size", 11)
	ground_chk.toggled.connect(func(p: bool) -> void:
		_ground_enabled = p
		_rebuild_editor_ground()
	)
	vb.add_child(ground_chk)
	# 颜色 ColorPickerButton (色盘 + 实时预览)
	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 4)
	vb.add_child(color_row)
	var col_lbl := Label.new()
	col_lbl.text = "  地面颜色"
	col_lbl.add_theme_font_size_override("font_size", 11)
	col_lbl.custom_minimum_size = Vector2(80, 24)
	color_row.add_child(col_lbl)
	var ground_color_btn := ColorPickerButton.new()
	ground_color_btn.color = _ground_color
	ground_color_btn.edit_alpha = false
	ground_color_btn.focus_mode = Control.FOCUS_NONE
	ground_color_btn.custom_minimum_size = Vector2(120, 24)
	var picker := ground_color_btn.get_picker()
	if picker:
		picker.color_mode = ColorPicker.MODE_RGB
		picker.picker_shape = ColorPicker.SHAPE_HSV_RECTANGLE
	ground_color_btn.color_changed.connect(func(c: Color) -> void:
		_ground_color = c
		# 即时刷新编辑器 mesh 颜色 (不重建, 直接改材质)
		if _ground_mesh_inst and _ground_mesh_inst.material_override is StandardMaterial3D:
			(_ground_mesh_inst.material_override as StandardMaterial3D).albedo_color = c
	)
	color_row.add_child(ground_color_btn)

	vb.add_child(HSeparator.new())

	# ============================================================
	# 视觉参数 (灯光 / 环境亮度 / 曝光) — 用户反馈: 编辑器太黑可以调
	# 改值实时应用到 WorldEnvironment.environment + DirectionalLight3D, 持久化到 cfg
	# ============================================================
	var visual_label := Label.new()
	visual_label.text = "🎨 视觉参数"
	visual_label.add_theme_font_size_override("font_size", 13)
	visual_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	vb.add_child(visual_label)

	# 太阳光强度 (DirectionalLight3D.light_energy)
	_vis_sun_label = Label.new()
	_vis_sun_label.text = "太阳光: %.2f" % _visual_sun_energy
	_vis_sun_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(_vis_sun_label)
	var sun_slider := HSlider.new()
	sun_slider.min_value = 0.0
	sun_slider.max_value = 4.0
	sun_slider.step = 0.05
	sun_slider.value = _visual_sun_energy
	sun_slider.custom_minimum_size = Vector2(220, 16)
	sun_slider.value_changed.connect(func(v: float) -> void:
		_visual_sun_energy = v
		_vis_sun_label.text = "太阳光: %.2f" % v
		_apply_visual_settings()
		_save_editor_settings()
	)
	vb.add_child(sun_slider)

	# 环境光强度 (Environment.ambient_light_energy)
	_vis_amb_label = Label.new()
	_vis_amb_label.text = "环境光: %.2f" % _visual_ambient_energy
	_vis_amb_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(_vis_amb_label)
	var amb_slider := HSlider.new()
	amb_slider.min_value = 0.0
	amb_slider.max_value = 4.0
	amb_slider.step = 0.05
	amb_slider.value = _visual_ambient_energy
	amb_slider.custom_minimum_size = Vector2(220, 16)
	amb_slider.value_changed.connect(func(v: float) -> void:
		_visual_ambient_energy = v
		_vis_amb_label.text = "环境光: %.2f" % v
		_apply_visual_settings()
		_save_editor_settings()
	)
	vb.add_child(amb_slider)

	# 天空贡献 (Environment.ambient_light_sky_contribution: 0=纯 ambient_color, 1=纯天空采样)
	_vis_sky_label = Label.new()
	_vis_sky_label.text = "天空贡献: %.2f" % _visual_sky_contribution
	_vis_sky_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(_vis_sky_label)
	var sky_slider := HSlider.new()
	sky_slider.min_value = 0.0
	sky_slider.max_value = 1.0
	sky_slider.step = 0.05
	sky_slider.value = _visual_sky_contribution
	sky_slider.custom_minimum_size = Vector2(220, 16)
	sky_slider.value_changed.connect(func(v: float) -> void:
		_visual_sky_contribution = v
		_vis_sky_label.text = "天空贡献: %.2f" % v
		_apply_visual_settings()
		_save_editor_settings()
	)
	vb.add_child(sky_slider)

	# 曝光 (Environment.tonemap_exposure)
	_vis_exp_label = Label.new()
	_vis_exp_label.text = "曝光: %.2f" % _visual_exposure
	_vis_exp_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(_vis_exp_label)
	var exp_slider := HSlider.new()
	exp_slider.min_value = 0.3
	exp_slider.max_value = 3.0
	exp_slider.step = 0.05
	exp_slider.value = _visual_exposure
	exp_slider.custom_minimum_size = Vector2(220, 16)
	exp_slider.value_changed.connect(func(v: float) -> void:
		_visual_exposure = v
		_vis_exp_label.text = "曝光: %.2f" % v
		_apply_visual_settings()
		_save_editor_settings()
	)
	vb.add_child(exp_slider)

	# 视觉参数重置按钮
	var btn_vis_reset := Button.new()
	btn_vis_reset.text = "↺ 视觉参数恢复默认"
	btn_vis_reset.custom_minimum_size = Vector2(220, 26)
	btn_vis_reset.add_theme_font_size_override("font_size", 11)
	btn_vis_reset.pressed.connect(func() -> void:
		_visual_sun_energy = 1.6
		_visual_ambient_energy = 1.4
		_visual_sky_contribution = 0.55
		_visual_exposure = 1.1
		sun_slider.set_value_no_signal(_visual_sun_energy)
		amb_slider.set_value_no_signal(_visual_ambient_energy)
		sky_slider.set_value_no_signal(_visual_sky_contribution)
		exp_slider.set_value_no_signal(_visual_exposure)
		_vis_sun_label.text = "太阳光: %.2f" % _visual_sun_energy
		_vis_amb_label.text = "环境光: %.2f" % _visual_ambient_energy
		_vis_sky_label.text = "天空贡献: %.2f" % _visual_sky_contribution
		_vis_exp_label.text = "曝光: %.2f" % _visual_exposure
		_apply_visual_settings()
		_save_editor_settings()
	)
	vb.add_child(btn_vis_reset)

	# ============================================================
	# 底部积木栏 (横向布局)
	# 用户反馈: UI 占位太大 (没有缩略图就做小一点) → 按钮缩到 80×52, 文字单行
	# 同时在右侧追加"自定义预设"按钮 (用 Ctrl 多选 + 保存预设按钮生成)
	# ============================================================
	# 底部锚定 (CENTER_BOTTOM): 居中 + 自适应宽度
	# 用 CenterContainer 包裹 PanelContainer 让它根据内容自适应宽度
	# 避免预设变多时按钮挤出去
	var blocks_anchor := Control.new()
	blocks_anchor.name = "BottomBlockAnchor"
	blocks_anchor.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	blocks_anchor.offset_top = -68
	blocks_anchor.offset_bottom = -8
	blocks_anchor.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui.add_child(blocks_anchor)
	var blocks_center := CenterContainer.new()
	blocks_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	blocks_center.mouse_filter = Control.MOUSE_FILTER_PASS
	blocks_anchor.add_child(blocks_center)
	var blocks_panel := PanelContainer.new()
	blocks_panel.name = "BottomBlockBar"
	blocks_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var bb_sb := StyleBoxFlat.new()
	bb_sb.bg_color = Color(0.10, 0.10, 0.13, 0.94)
	bb_sb.corner_radius_top_left = 8
	bb_sb.corner_radius_top_right = 8
	bb_sb.corner_radius_bottom_left = 8
	bb_sb.corner_radius_bottom_right = 8
	bb_sb.content_margin_left = 8
	bb_sb.content_margin_right = 8
	bb_sb.content_margin_top = 4
	bb_sb.content_margin_bottom = 4
	bb_sb.border_color = Color(1.0, 0.85, 0.3, 0.6)
	bb_sb.border_width_left = 1; bb_sb.border_width_right = 1
	bb_sb.border_width_top = 1; bb_sb.border_width_bottom = 1
	blocks_panel.add_theme_stylebox_override("panel", bb_sb)
	blocks_center.add_child(blocks_panel)
	_bottom_blocks_panel = blocks_panel   # 保存引用, 让机关栏宽度自动同步 (见 _process)
	var bb_h := HBoxContainer.new()
	bb_h.add_theme_constant_override("separation", 4)
	blocks_panel.add_child(bb_h)
	_bottom_blocks_hbox = bb_h   # 保存引用, 后面动态加预设按钮
	for info in BLOCK_INFO:
		var btn := Button.new()
		var hk_name: String = OS.get_keycode_string(info["hotkey"])
		# 文字单行 (积木名 + 快捷键), 不再换行 — 用户要求缩小
		btn.text = "%s [%s]" % [info["label"], hk_name]
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.custom_minimum_size = Vector2(82, 52)
		btn.add_theme_font_size_override("font_size", 10)
		btn.tooltip_text = "数字键 %s 也可" % hk_name
		var bid: String = info["id"]
		btn.pressed.connect(func() -> void:
			_set_tool(Tool.BLOCK, bid)
		)
		bb_h.add_child(btn)
		btn.set_meta("block_id", bid)

	# 预设区分隔条 + 动态预设按钮 (启动时根据 _block_presets 填充, 保存预设后调 _rebuild_preset_buttons)
	_rebuild_preset_buttons()

	# ============================================================
	# 机关栏 (紧贴积木栏上方, 独立 panel)
	# 用户要求: 加速带 / 钩索锚点 / 出生点 等"特殊功能地图元素"集中在这里
	#   未来新增机关 (传送门/检查点/Boost 圈等) 也加到 MECHANISM_INFO 数组里, 自动出现
	# 布局: BOTTOM_WIDE 居中, 在积木栏 (-68) 上方再 +60px
	# ============================================================
	var mech_anchor := Control.new()
	mech_anchor.name = "BottomMechAnchor"
	mech_anchor.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	mech_anchor.offset_top = -132   # 积木栏 -68 - 自身 56 - 间距 8
	mech_anchor.offset_bottom = -76
	mech_anchor.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui.add_child(mech_anchor)
	var mech_center := CenterContainer.new()
	mech_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	mech_center.mouse_filter = Control.MOUSE_FILTER_PASS
	mech_anchor.add_child(mech_center)
	var mech_panel := PanelContainer.new()
	mech_panel.name = "BottomMechBar"
	mech_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var mech_sb := StyleBoxFlat.new()
	mech_sb.bg_color = Color(0.12, 0.10, 0.08, 0.94)   # 暖棕色, 跟积木栏区分
	mech_sb.corner_radius_top_left = 8
	mech_sb.corner_radius_top_right = 8
	mech_sb.corner_radius_bottom_left = 8
	mech_sb.corner_radius_bottom_right = 8
	mech_sb.content_margin_left = 8
	mech_sb.content_margin_right = 8
	mech_sb.content_margin_top = 4
	mech_sb.content_margin_bottom = 4
	mech_sb.border_color = Color(1.0, 0.55, 0.25, 0.7)   # 橙色边框, 区别积木栏的金色
	mech_sb.border_width_left = 1; mech_sb.border_width_right = 1
	mech_sb.border_width_top = 1; mech_sb.border_width_bottom = 1
	mech_panel.add_theme_stylebox_override("panel", mech_sb)
	mech_center.add_child(mech_panel)
	# === 机关栏内部: HScrollContainer 让按钮多了能横向滚动 ===
	# 用户需求 (2026-06-02): 机关栏宽度跟积木栏一致 (用户先要求"加滚动条", 后又要"一样宽")
	# 设计:
	#   PanelContainer (mech_panel)
	#     └─ ScrollContainer (mech_scroll, 宽度自动跟随 _bottom_blocks_panel.size.x)
	#         └─ HBoxContainer (mech_h, 装所有按钮)
	# 关键参数:
	#   mech_scroll.custom_minimum_size.x = 在 _process 里每帧根据 blocks_panel 宽度同步
	#   horizontal_scroll_mode = AUTO            ← 内容超过宽度时自动出滚动条
	#   vertical_scroll_mode = SCROLL_MODE_DISABLED ← 不允许竖滚 (按钮只一排)
	var mech_scroll := ScrollContainer.new()
	mech_scroll.name = "MechScroll"
	mech_scroll.custom_minimum_size = Vector2(400, 56)   # 初始宽度兜底, 之后由 _process 同步
	mech_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	mech_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mech_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	mech_panel.add_child(mech_scroll)
	_mech_scroll = mech_scroll   # 保存引用, 让 _process 能同步宽度
	var mech_h := HBoxContainer.new()
	mech_h.add_theme_constant_override("separation", 4)
	mech_scroll.add_child(mech_h)
	# 机关栏小标题 (左侧)
	var mech_title := Label.new()
	mech_title.text = "⚙️ 机关"
	mech_title.add_theme_font_size_override("font_size", 11)
	mech_title.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
	mech_title.custom_minimum_size = Vector2(50, 0)
	mech_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mech_h.add_child(mech_title)
	for info in MECHANISM_INFO:
		var btn := Button.new()
		var hk_name: String = OS.get_keycode_string(info["hotkey"]) if info.has("hotkey") and info["hotkey"] != 0 else ""
		btn.text = "%s [%s]" % [info["label"], hk_name] if hk_name != "" else String(info["label"])
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.custom_minimum_size = Vector2(110, 44)
		btn.add_theme_font_size_override("font_size", 10)
		btn.tooltip_text = "数字键 %s 也可" % hk_name if hk_name != "" else String(info["label"])
		var mid: String = String(info["id"])
		var mkind: String = String(info.get("kind", "block"))
		btn.pressed.connect(func() -> void:
			_set_mechanism_tool(mid, mkind)
		)
		mech_h.add_child(btn)
		btn.set_meta("mech_id", mid)

	# 状态条 (顶部居中显示当前工具/状态, 避免遮挡右下角的角度+选中面板)
	var status := Label.new()
	status.name = "StatusLabel"
	status.set_anchors_preset(Control.PRESET_CENTER_TOP)
	status.offset_left = -400
	status.offset_top = 8
	status.offset_right = 400
	status.offset_bottom = 32
	status.add_theme_font_size_override("font_size", 12)
	status.add_theme_color_override("font_color", Color(1, 1, 1))
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ui.add_child(status)


func _set_tool(tool: int, block_id: String) -> void:
	# 切工具中断拖动 (避免拖动一半切走了选中, 但 _is_dragging_selected 还在)
	if _is_dragging_selected:
		_end_drag_selected()
	_current_tool = tool
	if tool == Tool.BLOCK:
		_selected_block_id = block_id
	# 离开 PRESET 模式时清掉预设预览 + 重置选中预设索引
	# 进入 PRESET 模式时索引由调用方 (预设按钮 pressed 闭包) 在 _set_tool 之前设好
	if tool != Tool.PRESET:
		_clear_preset_preview()
		_current_preset_index = -1
	# 切工具时清掉 hover 高亮 (避免离开 SELECT 模式后蓝色高亮残留)
	_clear_hover_highlight()
	_rebuild_preview()
	_update_status()


# 机关栏按钮统一入口 (id, kind):
#   kind="block"  → 走 Tool.BLOCK + .tscn 实例化 (加速带 / 未来其他 .tscn 机关都走这个)
#   kind="anchor" → 走 Tool.ANCHOR (代码生成锚点视觉)
#   kind="spawn"  → 走 Tool.SPAWN (唯一出生点, 鼠标点 = 移动)
# 这样未来加新机关只要往 MECHANISM_INFO 加一项 + (如果是 block 类) 加到 BLOCK_LIBRARY 就行
func _set_mechanism_tool(mech_id: String, kind: String) -> void:
	match kind:
		"block":
			_set_tool(Tool.BLOCK, mech_id)
		"anchor":
			_set_tool(Tool.ANCHOR, "")
		"spawn":
			_set_tool(Tool.SPAWN, "")
		_:
			push_warning("[TrackEditor] 未知机关 kind: %s" % kind)


# ============================================================
#  右下角"组合面板" (放置角度 + 已选中积木编辑) 构建
# ============================================================
# 之前放置角度滑块在左侧栏, 但用户反馈左侧已经够长 + 选中编辑面板要锚点防超屏,
# 所以把放置角度也挪到右下角. RightDock = VBoxContainer:
#   · 上 = pose_panel (始终可见, 角度滑块 + 归零)
#   · 下 = sel_panel_outer (默认隐藏, 选中后显示, 内含坐标/旋转/参数 SpinBox + 操作按钮)
# 返回 sel_panel_outer 给 _build_ui 用 (其实 _sel_panel.meta["outer_panel"] 也存了, 这里返回方便)
func _build_right_dock() -> PanelContainer:
	var right_dock := VBoxContainer.new()
	right_dock.name = "RightDock"
	# ============================================================
	# 多分辨率自适应 (用户反馈: 720p / 1080p 下面板顶部超屏)
	# ============================================================
	# 旧实现: PRESET_BOTTOM_RIGHT + offset_top=-760 (从底部往上 760px)
	#         在窗口高度 < 760+76 = 836px 时面板顶部跑到屏幕外
	# 新实现: PRESET_RIGHT_WIDE (右侧全高), 顶部留 40px 给 status label,
	#         底部留 76px 给积木栏 (-68 自身 -8 边距)
	#         这样无论窗口多高都自动占满可用纵向空间, sel_panel 走 SIZE_EXPAND_FILL 吃剩余
	# 内部 sel_scroll 是 ScrollContainer, 内容超过会出垂直滚动条
	right_dock.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	right_dock.offset_left = -340
	right_dock.offset_top = 40         # 留给顶部 status label (offset_top=8, height=24)
	right_dock.offset_right = -8
	right_dock.offset_bottom = -76     # 留底部积木栏 (高 60+8=68 + 边距)
	right_dock.add_theme_constant_override("separation", 6)
	# 容器自身不吃事件, 让子 panel 自己 STOP
	right_dock.mouse_filter = Control.MOUSE_FILTER_PASS
	_ui.add_child(right_dock)

	# ---- 子面板 1: 放置角度 ----
	var pose_panel := PanelContainer.new()
	pose_panel.name = "PosePanel"
	pose_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# pose 面板是\"固定高度\" (Yaw/Pitch/Roll 三行), 贴 right_dock 顶部
	# 旧值 SIZE_SHRINK_END 在 PRESET_BOTTOM_RIGHT 时让它贴底部, 现在 RIGHT_WIDE 应该贴顶
	pose_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	pose_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var pose_sb := StyleBoxFlat.new()
	pose_sb.bg_color = Color(0.10, 0.10, 0.13, 0.94)
	pose_sb.corner_radius_top_left = 8; pose_sb.corner_radius_top_right = 8
	pose_sb.corner_radius_bottom_left = 8; pose_sb.corner_radius_bottom_right = 8
	pose_sb.content_margin_left = 10; pose_sb.content_margin_right = 10
	pose_sb.content_margin_top = 8; pose_sb.content_margin_bottom = 8
	pose_sb.border_color = Color(1.0, 0.85, 0.3, 0.6)
	pose_sb.border_width_left = 1; pose_sb.border_width_right = 1
	pose_sb.border_width_top = 1; pose_sb.border_width_bottom = 1
	pose_panel.add_theme_stylebox_override("panel", pose_sb)
	right_dock.add_child(pose_panel)
	var pose_vb := VBoxContainer.new()
	pose_vb.add_theme_constant_override("separation", 4)
	pose_panel.add_child(pose_vb)

	var pose_label := Label.new()
	pose_label.text = "🎚️ 放置角度 (作用于下一次放置)"
	pose_label.add_theme_font_size_override("font_size", 12)
	pose_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.3))
	pose_vb.add_child(pose_label)
	var pose_hint := Label.new()
	pose_hint.text = "  拖动滑块或点击数值改值"
	pose_hint.add_theme_font_size_override("font_size", 10)
	pose_hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	pose_vb.add_child(pose_hint)

	# Yaw 行: [Y° 拖拽标签] [滑块] [SpinBox 可填写]
	# 用户要求: 滑块旁要能直接看到数字 + 可拖拽数字 + 可键入. 沿用积木选中面板的 _make_drag_label/_make_coord_spin
	# step_per_pixel = 1.0 = 拖一像素改 1 度, 比较顺手
	_yaw_label = Label.new()
	_yaw_label.text = "Yaw (水平转向):  0.0°"
	_yaw_label.add_theme_font_size_override("font_size", 11)
	pose_vb.add_child(_yaw_label)
	var yaw_h := HBoxContainer.new()
	yaw_h.add_theme_constant_override("separation", 4)
	pose_vb.add_child(yaw_h)
	yaw_h.add_child(_make_place_drag_label("Y°", "place_yaw", 1.0))
	_yaw_slider = HSlider.new()
	_yaw_slider.min_value = -180.0; _yaw_slider.max_value = 180.0
	_yaw_slider.step = 1.0; _yaw_slider.value = 0.0
	_yaw_slider.custom_minimum_size = Vector2(220, 16)
	_yaw_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_yaw_slider.value_changed.connect(func(v: float) -> void: _set_place_yaw_deg(v))
	yaw_h.add_child(_yaw_slider)
	_yaw_spin = _make_coord_spin(-180.0, 180.0, 0.5)
	_yaw_spin.value_changed.connect(func(v: float) -> void: _set_place_yaw_deg(v))
	yaw_h.add_child(_yaw_spin)

	_pitch_label = Label.new()
	_pitch_label.text = "Pitch (上下坡):  0.0°"
	_pitch_label.add_theme_font_size_override("font_size", 11)
	pose_vb.add_child(_pitch_label)
	var pitch_h := HBoxContainer.new()
	pitch_h.add_theme_constant_override("separation", 4)
	pose_vb.add_child(pitch_h)
	pitch_h.add_child(_make_place_drag_label("P°", "place_pitch", 0.5))
	_pitch_slider = HSlider.new()
	_pitch_slider.min_value = -45.0; _pitch_slider.max_value = 45.0
	_pitch_slider.step = 0.5; _pitch_slider.value = 0.0
	_pitch_slider.custom_minimum_size = Vector2(220, 16)
	_pitch_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pitch_slider.value_changed.connect(func(v: float) -> void: _set_place_pitch_deg(v))
	pitch_h.add_child(_pitch_slider)
	_pitch_spin = _make_coord_spin(-45.0, 45.0, 0.1)
	_pitch_spin.value_changed.connect(func(v: float) -> void: _set_place_pitch_deg(v))
	pitch_h.add_child(_pitch_spin)

	_roll_label = Label.new()
	_roll_label.text = "Roll (侧倾):  0.0°"
	_roll_label.add_theme_font_size_override("font_size", 11)
	pose_vb.add_child(_roll_label)
	var roll_h := HBoxContainer.new()
	roll_h.add_theme_constant_override("separation", 4)
	pose_vb.add_child(roll_h)
	roll_h.add_child(_make_place_drag_label("R°", "place_roll", 0.5))
	_roll_slider = HSlider.new()
	_roll_slider.min_value = -30.0; _roll_slider.max_value = 30.0
	_roll_slider.step = 0.5; _roll_slider.value = 0.0
	_roll_slider.custom_minimum_size = Vector2(220, 16)
	_roll_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roll_slider.value_changed.connect(func(v: float) -> void: _set_place_roll_deg(v))
	roll_h.add_child(_roll_slider)
	_roll_spin = _make_coord_spin(-30.0, 30.0, 0.1)
	_roll_spin.value_changed.connect(func(v: float) -> void: _set_place_roll_deg(v))
	roll_h.add_child(_roll_spin)

	var btn_zero := Button.new()
	btn_zero.text = "↺ 角度归零"
	btn_zero.custom_minimum_size = Vector2(0, 24)
	btn_zero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_zero.add_theme_font_size_override("font_size", 11)
	btn_zero.pressed.connect(func() -> void:
		_set_place_yaw_deg(0.0)
		_set_place_pitch_deg(0.0)
		_set_place_roll_deg(0.0)
	)
	pose_vb.add_child(btn_zero)

	# ---- 子面板 2: 已选中积木编辑面板 ----
	var sel_panel_outer := PanelContainer.new()
	sel_panel_outer.name = "SelectedPanel"
	sel_panel_outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel_panel_outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 用户反馈: 参数面板末几行 (右墙·入口段/出口段, "复制角度·放置"按钮等) 点击会穿透到 3D 场景.
	# 历史 bug:
	# - 之前给 panel 设 custom_minimum_size = (330, 200), 但参数行可能 10+ 条 (加速带 8 + 坐标 2),
	#   超出 200 后内容溢出在 panel rect 之外 → 鼠标点中超出区域 → 命中检查失败 → 事件穿透.
	# 修复:
	# - panel 设宽度 330, 但**不**强制最小高度. SIZE_EXPAND_FILL 会让它吃掉 right_dock 的剩余空间.
	# - 内部 sel_scroll 是 ScrollContainer, 内容超出 panel 高度会自动出垂直滚动条.
	# - 这样无论参数行多少, panel rect 始终覆盖所有可见行.
	sel_panel_outer.custom_minimum_size = Vector2(330, 0)
	sel_panel_outer.mouse_filter = Control.MOUSE_FILTER_STOP
	sel_panel_outer.visible = false
	var sel_sb := StyleBoxFlat.new()
	sel_sb.bg_color = Color(0.10, 0.12, 0.15, 0.95)
	sel_sb.corner_radius_top_left = 8; sel_sb.corner_radius_top_right = 8
	sel_sb.corner_radius_bottom_left = 8; sel_sb.corner_radius_bottom_right = 8
	sel_sb.content_margin_left = 10; sel_sb.content_margin_right = 10
	sel_sb.content_margin_top = 8; sel_sb.content_margin_bottom = 8
	sel_sb.border_color = Color(0.5, 1.0, 0.7, 0.6)
	sel_sb.border_width_left = 1; sel_sb.border_width_right = 1
	sel_sb.border_width_top = 1; sel_sb.border_width_bottom = 1
	sel_panel_outer.add_theme_stylebox_override("panel", sel_sb)
	right_dock.add_child(sel_panel_outer)
	var sel_scroll := ScrollContainer.new()
	sel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sel_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	sel_panel_outer.add_child(sel_scroll)
	_sel_panel = VBoxContainer.new()
	_sel_panel.add_theme_constant_override("separation", 4)
	_sel_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_panel.set_meta("outer_panel", sel_panel_outer)
	sel_scroll.add_child(_sel_panel)

	_sel_title_label = Label.new()
	_sel_title_label.text = "📌 已选中积木"
	_sel_title_label.add_theme_font_size_override("font_size", 13)
	_sel_title_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.7))
	_sel_panel.add_child(_sel_title_label)

	# 位置 SpinBox 一行 (X / Y / Z), 用户要求步长 0.01 + 右键 SpinBox 改步长 + 持久化
	# _get_spin_step 从 _spin_step_overrides 拿用户保存的步长, 默认 0.01
	var pos_step: float = _get_spin_step("pos", 0.01)
	var pos_h := HBoxContainer.new()
	pos_h.add_theme_constant_override("separation", 4)
	_sel_panel.add_child(pos_h)
	pos_h.add_child(_make_drag_label("X", "pos", 0, pos_step * 5.0))
	_sel_x_spin = _make_coord_spin(-9999.0, 9999.0, pos_step)
	_sel_x_spin.value_changed.connect(func(v: float) -> void: _on_sel_pos_changed(0, v))
	_attach_spin_step_menu(_sel_x_spin, "pos")
	pos_h.add_child(_sel_x_spin)
	pos_h.add_child(_make_drag_label("Y", "pos", 1, pos_step * 5.0))
	_sel_y_spin = _make_coord_spin(-9999.0, 9999.0, pos_step)
	_sel_y_spin.value_changed.connect(func(v: float) -> void: _on_sel_pos_changed(1, v))
	_attach_spin_step_menu(_sel_y_spin, "pos")
	pos_h.add_child(_sel_y_spin)
	pos_h.add_child(_make_drag_label("Z", "pos", 2, pos_step * 5.0))
	_sel_z_spin = _make_coord_spin(-9999.0, 9999.0, pos_step)
	_sel_z_spin.value_changed.connect(func(v: float) -> void: _on_sel_pos_changed(2, v))
	_attach_spin_step_menu(_sel_z_spin, "pos")
	pos_h.add_child(_sel_z_spin)

	# 角度 SpinBox 一行 (Yaw / Pitch / Roll)
	var rot_step: float = _get_spin_step("rot", 0.01)
	var rot_h := HBoxContainer.new()
	rot_h.add_theme_constant_override("separation", 4)
	_sel_panel.add_child(rot_h)
	rot_h.add_child(_make_drag_label("Y°", "rot", 0, rot_step * 5.0))
	_sel_yaw_spin = _make_coord_spin(-180.0, 180.0, rot_step)
	_sel_yaw_spin.value_changed.connect(func(v: float) -> void: _on_sel_rot_changed(0, v))
	_attach_spin_step_menu(_sel_yaw_spin, "rot")
	rot_h.add_child(_sel_yaw_spin)
	rot_h.add_child(_make_drag_label("P°", "rot", 1, rot_step * 5.0))
	_sel_pitch_spin = _make_coord_spin(-90.0, 90.0, rot_step)
	_sel_pitch_spin.value_changed.connect(func(v: float) -> void: _on_sel_rot_changed(1, v))
	_attach_spin_step_menu(_sel_pitch_spin, "rot")
	rot_h.add_child(_sel_pitch_spin)
	rot_h.add_child(_make_drag_label("R°", "rot", 2, rot_step * 5.0))
	_sel_roll_spin = _make_coord_spin(-90.0, 90.0, rot_step)
	_sel_roll_spin.value_changed.connect(func(v: float) -> void: _on_sel_rot_changed(2, v))
	_attach_spin_step_menu(_sel_roll_spin, "rot")
	rot_h.add_child(_sel_roll_spin)

	# 动态参数容器 (单选时根据 get_editable_params 构建; 多选时隐藏)
	_sel_params_container = VBoxContainer.new()
	_sel_params_container.add_theme_constant_override("separation", 3)
	_sel_panel.add_child(_sel_params_container)

	# 选中操作按钮 (复制角度→放置 / 取消选中 / 多选时显示"💾 保存为预设")
	var sel_btns := HBoxContainer.new()
	sel_btns.name = "SelButtons"
	sel_btns.add_theme_constant_override("separation", 4)
	_sel_panel.add_child(sel_btns)
	var btn_copy_rot := Button.new()
	btn_copy_rot.name = "CopyRot"
	btn_copy_rot.text = "复制角度→放置"
	btn_copy_rot.tooltip_text = "把选中积木的 yaw/pitch/roll 复制到上方放置滑块"
	btn_copy_rot.add_theme_font_size_override("font_size", 11)
	btn_copy_rot.pressed.connect(_on_copy_sel_rotation_to_place)
	sel_btns.add_child(btn_copy_rot)
	var btn_save_preset := Button.new()
	btn_save_preset.name = "SavePreset"
	btn_save_preset.text = "💾 保存为预设"
	btn_save_preset.tooltip_text = "把当前选中的多个积木保存为组合, 可一次性放下"
	btn_save_preset.add_theme_font_size_override("font_size", 11)
	btn_save_preset.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	btn_save_preset.pressed.connect(_on_save_preset_pressed)
	btn_save_preset.visible = false
	sel_btns.add_child(btn_save_preset)
	var btn_deselect := Button.new()
	btn_deselect.text = "取消选中"
	btn_deselect.add_theme_font_size_override("font_size", 11)
	btn_deselect.pressed.connect(func() -> void: _select_block(-1))
	sel_btns.add_child(btn_deselect)

	return sel_panel_outer


# ============================================================
#  SpinBox 步长 + 持久化设置
# ============================================================

# 加载 user://editor_settings.cfg 到 _spin_step_overrides
# 文件格式 (ConfigFile):
#   [spin_steps]
#   pos = 0.5
#   rot = 1.0
#   "param:length" = 0.5
func _load_editor_settings() -> void:
	var cf := ConfigFile.new()
	var err := cf.load(EDITOR_SETTINGS_PATH)
	if err != OK:
		return  # 文件不存在 / 解析失败, 用默认值
	if cf.has_section("spin_steps"):
		for k in cf.get_section_keys("spin_steps"):
			_spin_step_overrides[String(k)] = float(cf.get_value("spin_steps", k, 0.01))
	# 机关参数 min/max/step 覆盖
	# 存储格式: cf.get_value("param_ranges", "<block_id>:<param_key>") = Dictionary{min,max,step}
	# ConfigFile 直接支持 Dictionary 序列化
	if cf.has_section("param_ranges"):
		for k in cf.get_section_keys("param_ranges"):
			var v = cf.get_value("param_ranges", k, {})
			if v is Dictionary:
				_param_range_overrides[String(k)] = v
	# 视觉参数 (亮度 / 曝光). 如果文件里没存就保持默认值
	if cf.has_section("visual"):
		_visual_sun_energy = float(cf.get_value("visual", "sun_energy", _visual_sun_energy))
		_visual_ambient_energy = float(cf.get_value("visual", "ambient_energy", _visual_ambient_energy))
		_visual_sky_contribution = float(cf.get_value("visual", "sky_contribution", _visual_sky_contribution))
		_visual_exposure = float(cf.get_value("visual", "exposure", _visual_exposure))


# 保存 _spin_step_overrides + _visual_* 到 user://editor_settings.cfg
func _save_editor_settings() -> void:
	var cf := ConfigFile.new()
	for k in _spin_step_overrides.keys():
		cf.set_value("spin_steps", k, _spin_step_overrides[k])
	# 机关参数 min/max 覆盖
	for k in _param_range_overrides.keys():
		cf.set_value("param_ranges", k, _param_range_overrides[k])
	cf.set_value("visual", "sun_energy", _visual_sun_energy)
	cf.set_value("visual", "ambient_energy", _visual_ambient_energy)
	cf.set_value("visual", "sky_contribution", _visual_sky_contribution)
	cf.set_value("visual", "exposure", _visual_exposure)
	var err := cf.save(EDITOR_SETTINGS_PATH)
	if err != OK:
		push_warning("[TrackEditor] 保存 editor_settings.cfg 失败 err=%d" % err)


# 把当前 _visual_* 应用到场景节点 (WorldEnvironment 和 DirectionalLight3D)
# 改了立即看效果, 不用等下次启动
func _apply_visual_settings() -> void:
	var we: WorldEnvironment = get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.environment:
		we.environment.ambient_light_energy = _visual_ambient_energy
		we.environment.ambient_light_sky_contribution = _visual_sky_contribution
		we.environment.tonemap_exposure = _visual_exposure
	var sun: DirectionalLight3D = get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun:
		sun.light_energy = _visual_sun_energy


# 取某个 SpinBox 的步长, 没设置就用 default
func _get_spin_step(key: String, default_value: float) -> float:
	return float(_spin_step_overrides.get(key, default_value))


# 设步长 (持久化), 同时刷新所有同 key 的 SpinBox.step
func _set_spin_step(key: String, step: float) -> void:
	_spin_step_overrides[key] = step
	_save_editor_settings()
	# 找到所有 meta("spin_step_key")=key 的 SpinBox 刷新
	if _sel_panel:
		_apply_spin_step_recursive(_sel_panel, key, step)
	# 动态参数 SpinBox 也要刷
	if _sel_params_container:
		_apply_spin_step_recursive(_sel_params_container, key, step)


func _apply_spin_step_recursive(node: Node, key: String, step: float) -> void:
	for c in node.get_children():
		if c is SpinBox and c.has_meta("spin_step_key") and String(c.get_meta("spin_step_key")) == key:
			(c as SpinBox).step = step
		_apply_spin_step_recursive(c, key, step)


# 给 SpinBox 加右键菜单, 让用户选步长 (0.001/0.01/0.1/0.5/1.0/5.0)
# key = "pos"/"rot"/"param:<参数key>", 用于持久化区分不同 SpinBox 的步长
func _attach_spin_step_menu(spin: SpinBox, key: String) -> void:
	spin.set_meta("spin_step_key", key)
	# Godot SpinBox 内部有 LineEdit, 给 SpinBox 自身的 gui_input 加右键监听就行
	spin.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb: InputEventMouseButton = event
			if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT:
				_show_spin_step_menu(spin, key, mb.global_position)
				spin.accept_event()
	)


# 弹出步长选择菜单
func _show_spin_step_menu(spin: SpinBox, key: String, screen_pos: Vector2) -> void:
	var pm := PopupMenu.new()
	pm.name = "SpinStepMenu"
	var steps := [0.001, 0.01, 0.1, 0.5, 1.0, 5.0]
	var current_step: float = spin.step
	for i in range(steps.size()):
		var s: float = steps[i]
		var text: String = "步长 = %s" % str(s)
		if absf(s - current_step) < 0.0001:
			text = "✓ " + text
		pm.add_item(text, i)
	_ui.add_child(pm)
	pm.popup(Rect2i(int(screen_pos.x), int(screen_pos.y), 1, 1))
	pm.id_pressed.connect(func(id: int) -> void:
		if id < 0 or id >= steps.size():
			return
		_set_spin_step(key, steps[id])
		pm.queue_free()
	)
	pm.popup_hide.connect(func() -> void:
		# 延迟一帧释放, 避免和 id_pressed 冲突
		pm.queue_free()
	)


# ============================================================
#  组合预设 (Ctrl 多选 → 保存预设, 在底部积木栏显示)
# ============================================================

# 加载 user://block_presets.cfg 到 _block_presets
# 格式见 BLOCK_PRESETS_PATH 上方注释. 用 ConfigFile 是为了避免 Resource 自定义类的序列化坑
func _load_block_presets() -> void:
	_block_presets.clear()
	var cf := ConfigFile.new()
	var err := cf.load(BLOCK_PRESETS_PATH)
	if err != OK:
		return  # 文件不存在 / 解析失败, 用空数组
	for sec in cf.get_sections():
		if not sec.begins_with("preset_"):
			continue
		var pname: String = String(cf.get_value(sec, "name", sec))
		var count: int = int(cf.get_value(sec, "item_count", 0))
		var items: Array = []
		for i in range(count):
			var bid: String = String(cf.get_value(sec, "item_%d_id" % i, ""))
			var xs: String = String(cf.get_value(sec, "item_%d_xform" % i, ""))
			if bid.is_empty() or xs.is_empty():
				continue
			var xf: Transform3D = _string_to_transform3d(xs)
			# 读 params (老预设没这字段时 = 空字典 → 用默认参数)
			var iparams: Dictionary = cf.get_value(sec, "item_%d_params" % i, {})
			items.append({"id": bid, "rel_xform": xf, "params": iparams})
		_block_presets.append({"name": pname, "items": items})


# 保存 _block_presets 到 user://block_presets.cfg
func _save_block_presets() -> void:
	var cf := ConfigFile.new()
	for i in range(_block_presets.size()):
		var p: Dictionary = _block_presets[i]
		var sec: String = "preset_%d" % i
		cf.set_value(sec, "name", String(p.get("name", "")))
		var items: Array = p.get("items", [])
		cf.set_value(sec, "item_count", items.size())
		for j in range(items.size()):
			var it: Dictionary = items[j]
			cf.set_value(sec, "item_%d_id" % j, String(it.get("id", "")))
			var xf: Transform3D = it.get("rel_xform", Transform3D.IDENTITY)
			cf.set_value(sec, "item_%d_xform" % j, _transform3d_to_string(xf))
			# params 字典 (积木自定义参数, 例如 length / entry_width 等)
			# ConfigFile 直接支持 Dictionary 序列化
			cf.set_value(sec, "item_%d_params" % j, it.get("params", {}))
	var err := cf.save(BLOCK_PRESETS_PATH)
	if err != OK:
		push_warning("[TrackEditor] 保存预设失败 err=%d" % err)


# Transform3D 序列化: 12 个 float (basis 9 个 + origin 3 个) 逗号分隔成字符串
func _transform3d_to_string(xf: Transform3D) -> String:
	var b: Basis = xf.basis
	var o: Vector3 = xf.origin
	return "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f" % [
		b.x.x, b.x.y, b.x.z,
		b.y.x, b.y.y, b.y.z,
		b.z.x, b.z.y, b.z.z,
		o.x, o.y, o.z,
	]


func _string_to_transform3d(s: String) -> Transform3D:
	var parts: PackedStringArray = s.split(",")
	if parts.size() < 12:
		return Transform3D.IDENTITY
	var b := Basis(
		Vector3(float(parts[0]), float(parts[1]), float(parts[2])),
		Vector3(float(parts[3]), float(parts[4]), float(parts[5])),
		Vector3(float(parts[6]), float(parts[7]), float(parts[8])),
	)
	var o := Vector3(float(parts[9]), float(parts[10]), float(parts[11]))
	return Transform3D(b, o)


# 重建底部积木栏的预设按钮 (在 _bottom_blocks_hbox 末尾)
# 先清掉所有 has_meta("preset_index") 的旧按钮, 再按 _block_presets 重建
func _rebuild_preset_buttons() -> void:
	if _bottom_blocks_hbox == null:
		return
	# 清旧
	for c in _bottom_blocks_hbox.get_children():
		if c.has_meta("preset_index") or c.has_meta("preset_separator"):
			c.queue_free()
	# 没预设就不加分隔条
	if _block_presets.is_empty():
		return
	var sep := VSeparator.new()
	sep.set_meta("preset_separator", true)
	_bottom_blocks_hbox.add_child(sep)
	for i in range(_block_presets.size()):
		var p: Dictionary = _block_presets[i]
		var pname: String = String(p.get("name", "预设%d" % (i + 1)))
		var items: Array = p.get("items", [])
		var btn := Button.new()
		btn.text = "🧩 %s\n(%d 块)" % [pname, items.size()]
		btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.custom_minimum_size = Vector2(82, 52)
		btn.add_theme_font_size_override("font_size", 10)
		btn.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
		btn.tooltip_text = "点击 = 放置预设组合\n右键 = 删除此预设"
		btn.set_meta("preset_index", i)
		var idx: int = i
		btn.pressed.connect(func() -> void:
			# 关键顺序: 必须先设 _current_preset_index 再 _set_tool(PRESET, "")
			# 因为 _set_tool 内部会调 _rebuild_preview, _rebuild_preview 在 PRESET 分支
			# 用 _current_preset_index 决定要建哪几个积木. idx 已经 < 0 时啥都不建 → bug.
			_current_preset_index = idx
			_set_tool(Tool.PRESET, "")
		)
		btn.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
				_confirm_delete_preset(idx)
		)
		_bottom_blocks_hbox.add_child(btn)


# "保存为预设" 按钮回调: 把当前 _selected_block_indices 选中的积木保存成一组
# 第一个积木的 transform 作为 base, 其他积木存相对 base 的 rel_xform
# 这样未来放置时按光标对齐第一个积木的位置, 其它积木就能自动对齐过去
func _on_save_preset_pressed() -> void:
	if _selected_block_indices.size() < 2:
		return  # 单选不算预设 (单选直接用积木栏)
	# 弹输入名字对话框
	var dlg := AcceptDialog.new()
	dlg.title = "保存预设组合"
	var vb := VBoxContainer.new()
	dlg.add_child(vb)
	var lbl := Label.new()
	lbl.text = "预设名称 (会显示在底部积木栏右侧):"
	vb.add_child(lbl)
	var le := LineEdit.new()
	le.text = "组合_%d块" % _selected_block_indices.size()
	le.custom_minimum_size = Vector2(280, 28)
	vb.add_child(le)
	dlg.confirmed.connect(func() -> void:
		_do_save_preset(le.text)
	)
	add_child(dlg)
	dlg.popup_centered()


func _do_save_preset(preset_name: String) -> void:
	if _selected_block_indices.is_empty():
		return
	# 第一个选中积木的 transform 作为 base
	var first_idx: int = int(_selected_block_indices[0])
	if first_idx < 0 or first_idx >= _placed_blocks.size():
		return
	var base_node: Node3D = _placed_blocks[first_idx]["node"]
	if base_node == null:
		return
	var base_xform: Transform3D = base_node.global_transform
	var base_inv: Transform3D = base_xform.affine_inverse()
	var items: Array = []
	for idx in _selected_block_indices:
		var i: int = int(idx)
		if i < 0 or i >= _placed_blocks.size():
			continue
		var d: Dictionary = _placed_blocks[i]
		var n: Node3D = d["node"]
		if n == null:
			continue
		# rel = base⁻¹ × node : 在 base 局部坐标系下的 transform
		var rel: Transform3D = base_inv * n.global_transform
		# 同时把积木自定义参数也存进预设, 这样下次放预设时这些参数也能恢复
		# (例如用户把一组直道调成不同长度组合, 保存预设后下次放出来还是这些长度)
		var iparams: Dictionary = _collect_block_params(n)
		items.append({"id": String(d["id"]), "rel_xform": rel, "params": iparams})
	_block_presets.append({"name": preset_name, "items": items})
	_save_block_presets()
	_rebuild_preset_buttons()


# 右键预设按钮 → 弹确认删除
func _confirm_delete_preset(idx: int) -> void:
	if idx < 0 or idx >= _block_presets.size():
		return
	var dlg := ConfirmationDialog.new()
	dlg.title = "删除预设"
	dlg.dialog_text = "删除预设 \"%s\"? (不可撤销)" % String(_block_presets[idx].get("name", ""))
	dlg.confirmed.connect(func() -> void:
		_block_presets.remove_at(idx)
		_save_block_presets()
		_rebuild_preset_buttons()
		# 如果当前正在放这个预设, 退出 PRESET 模式
		if _current_tool == Tool.PRESET and _current_preset_index == idx:
			_set_tool(Tool.SELECT, "")
		_current_preset_index = -1
	)
	add_child(dlg)
	dlg.popup_centered()


# 清掉 PRESET 模式下的预览节点
# 注意: 不在这里清 _current_preset_index, 因为 _rebuild_preview 会先调 _clear_preset_preview 再用
# _current_preset_index 重新生成预览. 退出 PRESET 模式时由 _set_tool 在 if tool != Tool.PRESET 分支
# 单独清 _current_preset_index = -1
func _clear_preset_preview() -> void:
	for n in _preset_preview_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_preset_preview_nodes.clear()





# ============================================================
#  放置姿态 setter (UI 滑块/键盘快捷键 共用入口)
# ============================================================
func _set_place_yaw_deg(v: float) -> void:
	_place_yaw_deg = clampf(v, -180.0, 180.0)
	if _yaw_slider and absf(_yaw_slider.value - _place_yaw_deg) > 0.01:
		_yaw_slider.set_value_no_signal(_place_yaw_deg)
	if _yaw_spin and absf(_yaw_spin.value - _place_yaw_deg) > 0.01:
		_yaw_spin.set_value_no_signal(_place_yaw_deg)
	if _yaw_label:
		_yaw_label.text = "Yaw (水平转向):  %.1f°" % _place_yaw_deg

func _set_place_pitch_deg(v: float) -> void:
	_place_pitch_deg = clampf(v, -45.0, 45.0)
	if _pitch_slider and absf(_pitch_slider.value - _place_pitch_deg) > 0.01:
		_pitch_slider.set_value_no_signal(_place_pitch_deg)
	if _pitch_spin and absf(_pitch_spin.value - _place_pitch_deg) > 0.01:
		_pitch_spin.set_value_no_signal(_place_pitch_deg)
	if _pitch_label:
		_pitch_label.text = "Pitch (上下坡):  %.1f°" % _place_pitch_deg

func _set_place_roll_deg(v: float) -> void:
	_place_roll_deg = clampf(v, -30.0, 30.0)
	if _roll_slider and absf(_roll_slider.value - _place_roll_deg) > 0.01:
		_roll_slider.set_value_no_signal(_place_roll_deg)
	if _roll_spin and absf(_roll_spin.value - _place_roll_deg) > 0.01:
		_roll_spin.set_value_no_signal(_place_roll_deg)
	if _roll_label:
		_roll_label.text = "Roll (侧倾):  %.1f°" % _place_roll_deg


# 设置当前放置 Y 高度 (Shift+滚轮 / UI Label / 程序调用统一入口)
# 改了之后:
#   1) 同步 UI label 显示
#   2) 重建网格层指示 (在新 Y 高度画一个青色框, 让玩家看到自己当前在哪一层)
func _set_place_y_offset(v: float) -> void:
	_place_y_offset = clampf(v, -200.0, 200.0)
	if _y_offset_label:
		_y_offset_label.text = "Y 高度层: %.1f m  (Shift+滚轮)" % _place_y_offset
	_rebuild_grid_lines()


# 把当前 yaw/pitch/roll 转成额外的 Basis (YXZ 欧拉角顺序, 与 get_euler 一致)
# 应用方式: final_xform = base_xform * extra_basis (本地坐标系叠加, 让斜坡跟着磁吸方向走)
func _get_place_extra_basis() -> Basis:
	var euler := Vector3(deg_to_rad(_place_pitch_deg), deg_to_rad(_place_yaw_deg), deg_to_rad(_place_roll_deg))
	return Basis.from_euler(euler)


# ============================================================
#  已选中积木编辑工具
# ============================================================

# 创建一个紧凑的坐标 SpinBox
func _make_coord_spin(min_v: float, max_v: float, step: float) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = step
	sp.value = 0.0
	sp.custom_minimum_size = Vector2(60, 24)
	sp.add_theme_font_size_override("font_size", 11)
	# 让 SpinBox 不抢键盘焦点 (避免输入数字时影响编辑器快捷键)
	sp.alignment = HORIZONTAL_ALIGNMENT_CENTER
	return sp


# 创建一个可左右拖拽改值的坐标标签 (类似 Blender / 3D 软件的拖拽数值条)
# 鼠标左键按住标签 → 左右拖动 → 每像素 = step_per_pixel 改值
# axis_kind: "pos" / "rot" / "param"
# axis: 0/1/2 (pos→XYZ, rot→Yaw/Pitch/Roll), param 模式时这个是参数名 hash 不用
# 用 lambda 闭包记录哪个 SpinBox 被拖
func _make_drag_label(text: String, axis_kind: String, axis: int, step_per_pixel: float) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 11)
	# 加视觉提示: 鼠标 hover 时变金黄色, 暗示"可以拖"
	lb.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	lb.mouse_filter = Control.MOUSE_FILTER_STOP   # 必须 STOP 才能接收 GUI input
	lb.mouse_default_cursor_shape = Control.CURSOR_HSIZE   # 双向箭头光标 (暗示左右拖)
	lb.tooltip_text = "左右拖动改值 (每像素 = %.2f)" % step_per_pixel
	# 给 Label 加最小宽度让它好点
	lb.custom_minimum_size = Vector2(20, 24)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 接收 gui_input 处理拖拽
	lb.gui_input.connect(func(event: InputEvent) -> void: _on_drag_label_gui_input(lb, axis_kind, axis, step_per_pixel, event))
	return lb


# 处理拖拽标签的鼠标事件 (按下记录起始, 移动累积偏移改 SpinBox.value)
func _on_drag_label_gui_input(lb: Label, axis_kind: String, axis: int, step_per_pixel: float, event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# 开始拖拽: 记录起始 X + 当前 SpinBox 值
				var spin: SpinBox = _get_spin_for_drag(axis_kind, axis)
				if spin == null:
					return
				_drag_label_state = {
					"label": lb,
					"axis_kind": axis_kind,
					"axis": axis,
					"step_per_pixel": step_per_pixel,
					"spin": spin,
					"start_x": mb.global_position.x,
					"start_value": spin.value,
				}
			else:
				_drag_label_state.clear()
	elif event is InputEventMouseMotion:
		if _drag_label_state.is_empty():
			return
		if _drag_label_state.get("label") != lb:
			return
		# 计算累积像素偏移 → 目标值
		var mm: InputEventMouseMotion = event
		var dx: float = mm.global_position.x - float(_drag_label_state["start_x"])
		var step_pp: float = float(_drag_label_state["step_per_pixel"])
		var new_value: float = float(_drag_label_state["start_value"]) + dx * step_pp
		var spin: SpinBox = _drag_label_state["spin"]
		if spin == null:
			return
		# clamp 到 SpinBox 范围, 然后赋值 (会触发 value_changed 信号 → 更新积木)
		spin.value = clampf(new_value, spin.min_value, spin.max_value)


# 根据 axis_kind 找对应 SpinBox (pos→x/y/z, rot→yaw/pitch/roll, place_*→放置面板的 SpinBox)
func _get_spin_for_drag(axis_kind: String, axis: int) -> SpinBox:
	if axis_kind == "pos":
		match axis:
			0: return _sel_x_spin
			1: return _sel_y_spin
			2: return _sel_z_spin
	elif axis_kind == "rot":
		match axis:
			0: return _sel_yaw_spin
			1: return _sel_pitch_spin
			2: return _sel_roll_spin
	# 放置面板拖拽 (axis 不用, 直接看 axis_kind)
	elif axis_kind == "place_yaw":
		return _yaw_spin
	elif axis_kind == "place_pitch":
		return _pitch_spin
	elif axis_kind == "place_roll":
		return _roll_spin
	return null


# 给放置面板用的 drag-label, 复用 _on_drag_label_gui_input 但 axis_kind 走 place_yaw/pitch/roll
# 拖动这个标签 = 拖动对应 SpinBox 的 value = 触发 value_changed → _set_place_*_deg → 更新 slider/label/预览
func _make_place_drag_label(text: String, axis_kind: String, step_per_pixel: float) -> Label:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 11)
	lb.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	lb.mouse_filter = Control.MOUSE_FILTER_STOP
	lb.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	lb.tooltip_text = "左右拖动改值 (每像素 = %.2f°)" % step_per_pixel
	lb.custom_minimum_size = Vector2(20, 24)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# axis 参数不用 (传 0 占位), 完全靠 axis_kind 区分
	lb.gui_input.connect(func(event: InputEvent) -> void: _on_drag_label_gui_input(lb, axis_kind, 0, step_per_pixel, event))
	return lb


# 选中第 idx 个已放置积木 (-1 = 取消选中)
# 同步: 高亮该节点 mesh + 显示 _sel_panel + 写入 SpinBox
# 单选: _selected_block_index = idx, _selected_block_indices = [idx]
# 多选请用 _toggle_select_block (Ctrl+点击)
func _select_block(idx: int) -> void:
	# 选中切换 = flush 未提交的参数 undo (防止改完一个机关没等 0.4s 就切到另一个, 丢失最后一段修改)
	_flush_pending_undo()
	# 隐藏旧选中窄道的控制点手柄
	for old_idx in _selected_block_indices:
		var oi: int = int(old_idx)
		if oi >= 0 and oi < _placed_blocks.size():
			var onode: Node3D = _placed_blocks[oi].get("node")
			if onode != null and onode.has_method("hide_handles"):
				onode.call("hide_handles")
	# 先清掉旧选中高亮 + hover 高亮 (避免两套叠加)
	_clear_selection_highlight()
	_clear_hover_highlight()
	_selected_block_index = idx
	if idx < 0:
		_selected_block_indices.clear()
	else:
		_selected_block_indices = [idx]
	# 新选中的窄道: 显示控制点手柄
	if idx >= 0 and idx < _placed_blocks.size():
		var new_node: Node3D = _placed_blocks[idx].get("node")
		if new_node != null and new_node.has_method("show_handles"):
			new_node.call("show_handles")
	_refresh_selection_ui()


# Ctrl+点击切换选择: 在 _selected_block_indices 里加/移除 idx
# 多选时面板模式切换:
#   · 1 个选中 = 标准单选 UI (有积木参数 / 复制角度按钮 / 隐藏保存预设按钮)
#   · 2+ 个选中 = 多选 UI (隐藏积木参数 / 显示保存预设按钮 / 改坐标=对所有应用相对偏移)
func _toggle_select_block(idx: int) -> void:
	_clear_selection_highlight()
	_clear_hover_highlight()
	if idx < 0 or idx >= _placed_blocks.size():
		return
	if _selected_block_indices.has(idx):
		_selected_block_indices.erase(idx)
	else:
		_selected_block_indices.append(idx)
	# 同步 _selected_block_index: 多选时指向第一项 (用于"主选中"显示)
	if _selected_block_indices.is_empty():
		_selected_block_index = -1
	else:
		_selected_block_index = int(_selected_block_indices[0])
	_refresh_selection_ui()


# 根据当前 _selected_block_indices 状态刷新整个右下角面板
# 单选 vs 多选 UI 切换都在这里做
func _refresh_selection_ui() -> void:
	if _sel_panel == null:
		return
	var outer_panel: Control = null
	if _sel_panel.has_meta("outer_panel"):
		outer_panel = _sel_panel.get_meta("outer_panel")
	# 拿"保存为预设"按钮和"复制角度"按钮的引用 (在 _build_right_dock 命名了)
	var save_preset_btn: Button = _sel_panel.find_child("SavePreset", true, false) as Button
	var copy_rot_btn: Button = _sel_panel.find_child("CopyRot", true, false) as Button
	if _selected_block_indices.is_empty():
		if outer_panel:
			outer_panel.visible = false
		_clear_path_length_label_3d()
		_update_status()
		return
	if outer_panel:
		outer_panel.visible = true
	# 给所有选中的积木加高亮 (多选时全部呼吸闪烁)
	for i in _selected_block_indices:
		var ii: int = int(i)
		if ii >= 0 and ii < _placed_blocks.size():
			var n: Node3D = _placed_blocks[ii]["node"]
			if n != null:
				_apply_selection_highlight(n)
	# 单选 vs 多选
	if _selected_block_indices.size() == 1:
		# === 单选 UI ===
		if save_preset_btn:
			save_preset_btn.visible = false
		if copy_rot_btn:
			copy_rot_btn.visible = true
		var data: Dictionary = _placed_blocks[_selected_block_index]
		var node: Node3D = data["node"]
		_sel_title_label.text = "📌 选中: %s  [#%d]" % [String(data["id"]), _selected_block_index]
		# 窄道类: 在 3D 世界中显示中线长度标签
		_update_path_length_label_3d(node)
		var pos: Vector3 = node.global_position
		_sel_x_spin.set_value_no_signal(pos.x)
		_sel_y_spin.set_value_no_signal(pos.y)
		_sel_z_spin.set_value_no_signal(pos.z)
		var euler: Vector3 = node.global_transform.basis.get_euler()
		_sel_yaw_spin.set_value_no_signal(rad_to_deg(euler.y))
		_sel_pitch_spin.set_value_no_signal(rad_to_deg(euler.x))
		_sel_roll_spin.set_value_no_signal(rad_to_deg(euler.z))
		# 单选时角度 SpinBox 都可改
		_sel_yaw_spin.editable = true; _sel_pitch_spin.editable = true; _sel_roll_spin.editable = true
		# 显示积木参数
		_rebuild_sel_param_rows(node)
	else:
		# === 多选 UI ===
		# 标题
		_sel_title_label.text = "📌 多选: %d 块积木  (改坐标=整体偏移)" % _selected_block_indices.size()
		if save_preset_btn:
			save_preset_btn.visible = true
		if copy_rot_btn:
			copy_rot_btn.visible = false
		# 坐标 SpinBox 显示第一项的位置 (作为"参考点"). 改值 = 整体偏移 (delta = new - old, 应用到所有)
		var first_idx: int = int(_selected_block_indices[0])
		var first_node: Node3D = _placed_blocks[first_idx]["node"]
		var fp: Vector3 = first_node.global_position
		_sel_x_spin.set_value_no_signal(fp.x)
		_sel_y_spin.set_value_no_signal(fp.y)
		_sel_z_spin.set_value_no_signal(fp.z)
		# 多选下角度 SpinBox 不可改 (各积木角度可能不同, 改了语义模糊)
		_sel_yaw_spin.set_value_no_signal(0.0)
		_sel_pitch_spin.set_value_no_signal(0.0)
		_sel_roll_spin.set_value_no_signal(0.0)
		_sel_yaw_spin.editable = false; _sel_pitch_spin.editable = false; _sel_roll_spin.editable = false
		# 多选时清空积木参数 (不同积木类型参数不一致, 不展示)
		for c in _sel_params_container.get_children():
			c.queue_free()
		var multi_hint := Label.new()
		multi_hint.text = "  (多选下不显示单块参数)"
		multi_hint.add_theme_font_size_override("font_size", 10)
		multi_hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_sel_params_container.add_child(multi_hint)
	_update_status()





# 根据选中积木的 get_editable_params 重建参数 SpinBox 行
# 之前的行先全 queue_free, 再按返回的字典生成
# 用户要求: color_r/color_g/color_b 三连参数自动合并成一个 ColorPickerButton (色盘 + 实时预览)
# 不要再用三条独立 SpinBox 滑 R/G/B
func _rebuild_sel_param_rows(node: Node3D) -> void:
	if _sel_params_container == null:
		return
	# 清掉旧 rows
	for c in _sel_params_container.get_children():
		c.queue_free()
	if node == null or not node.has_method("get_editable_params"):
		return
	var params: Array = node.call("get_editable_params")
	if params.is_empty():
		return
	# 拿 block_id 用作 param_range_overrides 的 key 前缀 (各机关共用同样的范围 override)
	var block_id: String = ""
	if _selected_block_index >= 0 and _selected_block_index < _placed_blocks.size():
		block_id = String(_placed_blocks[_selected_block_index].get("id", ""))
	# 检测 color_r/g/b 三连参数, 后面循环渲染时跳过它们, 改用单独一行 ColorPickerButton
	# 设计: 只要 params 同时包含 "color_r"+"color_g"+"color_b" 就合并; 不强制必须连续
	var has_color: bool = false
	var color_value := Color(1.0, 1.0, 1.0)
	var color_keys: Array[String] = ["color_r", "color_g", "color_b"]
	var color_present: Dictionary = {}
	for p in params:
		var k: String = String(p.get("key", ""))
		if k in color_keys:
			color_present[k] = float(p.get("value", 1.0))
	if color_present.size() == 3:
		has_color = true
		color_value = Color(
			float(color_present.get("color_r", 1.0)),
			float(color_present.get("color_g", 1.0)),
			float(color_present.get("color_b", 1.0))
		)
	# 加分隔小标题
	var hdr := Label.new()
	hdr.text = "  ⚙️ 积木参数"
	hdr.add_theme_font_size_override("font_size", 11)
	hdr.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	_sel_params_container.add_child(hdr)
	# 每个 param 一行: [可拖标签] [SpinBox]
	for p in params:
		var key: String = String(p.get("key", ""))
		# 跳过隐藏参数 (仅用于序列化, 不在 UI 显示)
		if p.get("hidden", false):
			continue
		# 跳过 color_r/g/b 三连 — 它们由下面的 ColorPickerButton 统一管理
		if has_color and key in color_keys:
			continue
		var label: String = String(p.get("label", key))
		var def_min: float = float(p.get("min", -1000.0))
		var def_max: float = float(p.get("max", 1000.0))
		var default_step: float = float(p.get("step", 0.1))
		# 用户可在弹窗里覆盖 min/max/step (持久化到 [param_ranges])
		# 优先级: override > get_editable_params 默认
		var range_override: Dictionary = {}
		var range_key: String = block_id + ":" + key
		if _param_range_overrides.has(range_key):
			range_override = _param_range_overrides[range_key]
		var min_v: float = float(range_override.get("min", def_min))
		var max_v: float = float(range_override.get("max", def_max))
		# step 仍然走 _spin_step_overrides 的体系 (右键菜单调步长), 但 range 弹窗里也能改
		# 若 range_override 里有 step, 用它作为 default; 否则用 get_editable_params 的 step
		var step_default: float = float(range_override.get("step", default_step))
		var step: float = _get_spin_step("param:" + key, step_default)
		var value: float = float(p.get("value", 0.0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_sel_params_container.add_child(row)
		# 可拖拽标签 (拖一像素 = step × 5 让玩家好操作)
		# 用户需求 (2026-06-02): 标签右键点击弹窗调 min/max/step (像 Tuner 一样)
		# 仍用 Label 而不是 Button: 因为 Button 的 pressed 信号和左键拖动会打架,
		#   Button 还会消费点击 → 拖拽过程中误触发 pressed → 弹窗反复跳出
		# 方案: Label + 左键拖动 (原行为) + 右键点击 (新, 打开范围弹窗)
		var step_pp: float = step * 5.0
		var lb := Label.new()
		lb.text = "  " + label
		lb.add_theme_font_size_override("font_size", 11)
		lb.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		lb.mouse_filter = Control.MOUSE_FILTER_STOP
		lb.mouse_default_cursor_shape = Control.CURSOR_HSIZE
		lb.tooltip_text = "左键点击改 min/max/step | 左键拖动改值 (每像素 = %.2f) | 右键也能开 min/max 弹窗" % step_pp
		lb.custom_minimum_size = Vector2(110, 24)
		row.add_child(lb)
		# 右键点击打开范围编辑弹窗 (绑在 gui_input 同时, 同一个 lambda 既处理拖拽也处理右键)
		var p_capture: Dictionary = p.duplicate()
		var bid_capture: String = block_id
		var label_capture: String = label
		# SpinBox
		var sp := _make_coord_spin(min_v, max_v, step)
		sp.set_value_no_signal(value)
		sp.custom_minimum_size = Vector2(80, 24)
		_attach_spin_step_menu(sp, "param:" + key)
		row.add_child(sp)
		# 改值时调 set_editable_param + 同步刷新坐标 SpinBox
		# 用户需求 (2026-06-02): "参数填写应该可以 ctrl+z 回溯"
		# 旧 bug: 每次 value_changed 都 _undo_push, 拖一下要按几十次 Ctrl+Z 才回到原值
		# 修复: 用 _queue_pending_undo (合并 0.4s 内连续修改成一条 undo)
		var key_capture: String = key
		var old_value_holder: Array = [value]   # 单元素数组让闭包能改它 (类似 ref)
		sp.value_changed.connect(func(v: float) -> void:
			if _selected_block_index < 0 or _selected_block_index >= _placed_blocks.size():
				return
			var n: Node3D = _placed_blocks[_selected_block_index].get("node")
			if n == null or not n.has_method("set_editable_param"):
				return
			# 合并连续修改: old_value_holder[0] 永远是"这一段连续编辑的起点"
			# _queue_pending_undo 内部会判断: 同一 idx+key 持续修改 → 只更新 new_value
			#                                  不同目标或超时 → flush 旧的入栈, 开新的
			_queue_pending_undo("param", _selected_block_index, key_capture, old_value_holder[0], v)
			n.call("set_editable_param", key_capture, v)
			# 注: 不更新 old_value_holder[0], 让连续修改的 old 保持不变 (拖完后整段算一次 undo)
			# 重新应用选中高亮 (rebuild 后 mesh 是新的, 旧的 _selection_highlight_orig_mats 引用失效)
			_clear_selection_highlight()
			_apply_selection_highlight(n)
		)
		# 给标签加交互: 左键点击=打开范围弹窗 / 左键拖动=改值 / 右键=打开范围弹窗
		# 用户反馈 (2026-06-02): "点击机关参数标签没法调整 min/max"
		# 真凶: 旧版只有右键打开弹窗, 用户左键点击不响应 → 直觉是左键点击就该弹窗
		# 修复: 在 mb.released 时判断: 鼠标位移 < 4px → 算"点击"开弹窗, ≥ 4px → 算"拖动结束"什么都不做
		# press_state 用 Array 单元素 holder 让闭包能跨调用持久化状态
		# [active(bool), start_global_x(float), start_global_y(float)]
		var sp_ref: SpinBox = sp
		var step_pp_capture: float = step_pp
		var press_state: Array = [false, 0.0, 0.0]   # 闭包共享状态: 这次按下是否还在持续 + 起始位置
		lb.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton:
				var mbtn: InputEventMouseButton = event
				# 右键: 任何时候都直接打开弹窗 (兼容旧操作习惯 + 桌面右键弹窗范式)
				if mbtn.button_index == MOUSE_BUTTON_RIGHT and mbtn.pressed:
					_open_param_range_editor(bid_capture, p_capture, label_capture, sp_ref)
					return
				# 左键: 区分"点击"和"拖动"
				if mbtn.button_index == MOUSE_BUTTON_LEFT:
					if mbtn.pressed:
						# 按下: 记录起点, 让原拖拽逻辑也能正常进行
						press_state[0] = true
						press_state[1] = mbtn.global_position.x
						press_state[2] = mbtn.global_position.y
					else:
						# 松开: 判断鼠标位移
						if bool(press_state[0]):
							var dx_total: float = absf(mbtn.global_position.x - float(press_state[1]))
							var dy_total: float = absf(mbtn.global_position.y - float(press_state[2]))
							press_state[0] = false
							# 位移 < 4px 视为"点击"而非拖动 → 打开范围弹窗
							if dx_total < 4.0 and dy_total < 4.0:
								# 先把原拖拽状态清掉 (避免 _drag_label_state 残留 = 这个 lb)
								_drag_label_state.clear()
								_open_param_range_editor(bid_capture, p_capture, label_capture, sp_ref)
								return
			# 其他情况 (左键拖动 motion / 左键 release 但是真拖动) 走原拖拽逻辑
			_on_param_drag_label_input(lb, sp_ref, step_pp_capture, event)
		)
	# ============================================================
	# 颜色行 (ColorPickerButton): 拖拽色盘 + 实时预览
	# ============================================================
	# 用 Godot 内建的 ColorPickerButton: 一个色块按钮, 点击弹出完整 ColorPicker (色环+RGB+HSV+十六进制)
	# 优点: 完全的色盘拖拽体验, 玩家拖动就实时看到机关颜色变化
	# 仅当积木支持 color_r/g/b 三连参数时才显示
	if has_color:
		var color_row := HBoxContainer.new()
		color_row.add_theme_constant_override("separation", 4)
		_sel_params_container.add_child(color_row)
		var color_lbl := Label.new()
		color_lbl.text = "  🎨 颜色"
		color_lbl.add_theme_font_size_override("font_size", 11)
		color_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		color_lbl.custom_minimum_size = Vector2(110, 24)
		color_lbl.tooltip_text = "点击打开色盘 → 拖拽选色, 实时预览"
		color_row.add_child(color_lbl)
		var cpb := ColorPickerButton.new()
		cpb.color = color_value
		cpb.custom_minimum_size = Vector2(180, 28)
		# 关掉 alpha 通道 (积木颜色不需要透明度), 同时让色盘看起来更聚焦
		cpb.edit_alpha = false
		# 不让按钮抢键盘焦点, 否则点完色盘后 A/D 还是会被按钮当导航键吞掉
		cpb.focus_mode = Control.FOCUS_NONE
		# 色盘显示模式: HSV 圆环 (最常用) + RGB sliders
		var picker := cpb.get_picker()
		if picker:
			picker.color_mode = ColorPicker.MODE_RGB
			# 色盘形状: HSV 矩形 (Godot 4 ColorPicker 默认就是这个, 拖拽很顺手)
			picker.picker_shape = ColorPicker.SHAPE_HSV_RECTANGLE
		color_row.add_child(cpb)
		# 实时预览: color_changed 在拖拽过程中持续触发 (sampled 模式)
		# 每次 changed 直接调 set_editable_param("color_r/g/b", ...) 三次, 让积木重建几何颜色
		# Undo: 颜色改动统一作为一条记录, 用 holder 暂存上一次稳定颜色 (color_changed 太频繁, 不每帧 push)
		var color_old_holder: Array = [color_value]
		cpb.color_changed.connect(func(c: Color) -> void:
			if _selected_block_index < 0 or _selected_block_index >= _placed_blocks.size():
				return
			var n: Node3D = _placed_blocks[_selected_block_index].get("node")
			if n == null or not n.has_method("set_editable_param"):
				return
			# 直接应用 (不入 undo 栈, 拖动期间频繁触发, 入栈会爆栈)
			n.call("set_editable_param", "color_r", c.r)
			n.call("set_editable_param", "color_g", c.g)
			n.call("set_editable_param", "color_b", c.b)
			_clear_selection_highlight()
			_apply_selection_highlight(n)
		)
		# popup_closed: 玩家点完色盘关掉时, 把"打开前 → 关闭时"作为一次 undo 操作入栈
		# 这样长时间拖色盘只产生一条 undo 记录, 而不是几百条 frame-by-frame 记录
		cpb.popup_closed.connect(func() -> void:
			var old_c: Color = color_old_holder[0]
			var new_c: Color = cpb.color
			# 只在颜色确实变了时入栈 (避免点开看一眼又关掉也产生 undo)
			if old_c != new_c and _selected_block_index >= 0 and _selected_block_index < _placed_blocks.size():
				# 把 R/G/B 三个 param undo 合并 (按 key 分别 push 三条)
				_undo_push({"op": "param", "index": _selected_block_index, "key": "color_r", "old_value": old_c.r, "new_value": new_c.r})
				_undo_push({"op": "param", "index": _selected_block_index, "key": "color_g", "old_value": old_c.g, "new_value": new_c.g})
				_undo_push({"op": "param", "index": _selected_block_index, "key": "color_b", "old_value": old_c.b, "new_value": new_c.b})
			color_old_holder[0] = new_c
		)

	# === [设为默认] 按钮 (用户需求 2026-06-03) ===
	# 一键把当前机关的所有参数传递到 Tuner 的 🎯 机关默认值 Tab 并保存
	var set_default_btn := Button.new()
	set_default_btn.text = "📌 设为默认"
	set_default_btn.tooltip_text = "把当前机关的所有参数设为该类型机关的默认值\n(影响新放置的同类机关 + 未手调过的已放置同类机关)"
	set_default_btn.add_theme_font_size_override("font_size", 11)
	set_default_btn.add_theme_color_override("font_color", Color(0.5, 1.0, 0.7))
	set_default_btn.custom_minimum_size = Vector2(120, 26)
	set_default_btn.focus_mode = Control.FOCUS_NONE
	set_default_btn.pressed.connect(func() -> void:
		_set_current_block_as_default()
	)
	_sel_params_container.add_child(set_default_btn)


# 把当前选中机关的所有参数设为该类型的默认值 (传递到 Tuner 🎯 机关默认值 Tab)
func _set_current_block_as_default() -> void:
	if _selected_block_index < 0 or _selected_block_index >= _placed_blocks.size():
		return
	var entry: Dictionary = _placed_blocks[_selected_block_index]
	var block_id: String = String(entry.get("id", ""))
	var node: Node3D = entry.get("node")
	if node == null or not node.has_method("get_editable_params") or block_id.is_empty():
		return
	# 收集当前所有参数
	var params: Array = node.call("get_editable_params")
	if params.is_empty():
		return
	# 找 Tuner 节点, 调用 _set_mechanism_default 逐个设置
	var tuner_node: Node = get_tree().current_scene.find_child("Tuner", true, false)
	if tuner_node == null:
		push_warning("[TrackEditor] 找不到 Tuner 节点, 无法设为默认")
		return
	var count: int = 0
	for p in params:
		var key: String = String(p.get("key", ""))
		var value: float = float(p.get("value", 0.0))
		if key.is_empty():
			continue
		if tuner_node.has_method("_set_mechanism_default"):
			tuner_node.call("_set_mechanism_default", block_id, key, value)
			count += 1
	# 手动触发保存 (Tuner 的 _request_autosave 可能被禁用了, 直接调 _on_save)
	if tuner_node.has_method("_on_save"):
		tuner_node.call("_on_save")
	print("[TrackEditor] 📌 已把 %s 的 %d 个参数设为默认值" % [block_id, count])


# 参数 SpinBox 行的拖拽 (与坐标拖拽逻辑一致, 但闭包捕获不一样, 单独写一个)
func _on_param_drag_label_input(lb: Label, spin: SpinBox, step_per_pixel: float, event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag_label_state = {
					"label": lb,
					"axis_kind": "param",
					"axis": 0,
					"step_per_pixel": step_per_pixel,
					"spin": spin,
					"start_x": mb.global_position.x,
					"start_value": spin.value,
				}
			else:
				_drag_label_state.clear()
	elif event is InputEventMouseMotion:
		if _drag_label_state.is_empty() or _drag_label_state.get("label") != lb:
			return
		var mm: InputEventMouseMotion = event
		var dx: float = mm.global_position.x - float(_drag_label_state["start_x"])
		var new_value: float = float(_drag_label_state["start_value"]) + dx * step_per_pixel
		spin.value = clampf(new_value, spin.min_value, spin.max_value)


# 机关参数 min/max/step 范围编辑弹窗 (用户右键参数标签触发)
# 用户需求 (2026-06-02): "所有机关的参数的最大值和最小值 都要可以调整 就跟tab里的参数一样"
#
# 参数:
#   block_id: 机关 ID (如 "gravity_cylinder"), 用作持久化 key 前缀
#   param_dict: 完整 get_editable_params() 返回的某一项 ({key,label,min,max,step,value})
#   label: 显示名 (用于弹窗标题)
#   target_spin: 当前 SpinBox 引用, 改 min/max 后立刻应用到 UI
#
# 持久化:
#   保存到 _param_range_overrides["<block_id>:<key>"] = {min, max, step}
#   下次打开同样的机关 + 同样的参数时, _rebuild_sel_param_rows 会优先读这个值
func _open_param_range_editor(block_id: String, param_dict: Dictionary, label: String, target_spin: SpinBox) -> void:
	var key: String = String(param_dict.get("key", ""))
	if key.is_empty():
		return
	var range_key: String = block_id + ":" + key
	# 当前显示值: 优先 override, fallback 默认
	var def_min: float = float(param_dict.get("min", -1000.0))
	var def_max: float = float(param_dict.get("max", 1000.0))
	var def_step: float = float(param_dict.get("step", 0.1))
	var cur_min: float = def_min
	var cur_max: float = def_max
	var cur_step: float = def_step
	if _param_range_overrides.has(range_key):
		var ov: Dictionary = _param_range_overrides[range_key]
		cur_min = float(ov.get("min", def_min))
		cur_max = float(ov.get("max", def_max))
		cur_step = float(ov.get("step", def_step))

	var dlg := AcceptDialog.new()
	dlg.title = "编辑参数范围: " + label
	dlg.dialog_hide_on_ok = true
	dlg.min_size = Vector2(360, 220)
	# 添加 "重置默认" 按钮 (左下)
	dlg.add_button("重置默认", true, "reset_default")

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	dlg.add_child(vb)

	var tip := Label.new()
	tip.text = "机关 [%s] 的参数 [%s]\n默认范围 %.2f ~ %.2f, 步长 %.3f" % [block_id, label, def_min, def_max, def_step]
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_color_override("font_color", Color(0.85, 0.85, 0.9))
	tip.add_theme_font_size_override("font_size", 11)
	tip.custom_minimum_size = Vector2(340, 0)
	vb.add_child(tip)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)

	var lbl_min := Label.new(); lbl_min.text = "最小值"; grid.add_child(lbl_min)
	var sp_min := SpinBox.new()
	sp_min.allow_lesser = true
	sp_min.allow_greater = true
	sp_min.step = cur_step
	sp_min.min_value = -1e9
	sp_min.max_value = 1e9
	sp_min.value = cur_min
	grid.add_child(sp_min)

	var lbl_max := Label.new(); lbl_max.text = "最大值"; grid.add_child(lbl_max)
	var sp_max := SpinBox.new()
	sp_max.allow_lesser = true
	sp_max.allow_greater = true
	sp_max.step = cur_step
	sp_max.min_value = -1e9
	sp_max.max_value = 1e9
	sp_max.value = cur_max
	grid.add_child(sp_max)

	var lbl_step := Label.new(); lbl_step.text = "步长"; grid.add_child(lbl_step)
	var sp_step := SpinBox.new()
	sp_step.allow_lesser = true
	sp_step.allow_greater = true
	sp_step.step = 0.001
	sp_step.min_value = 0.0001
	sp_step.max_value = 1000.0
	sp_step.value = cur_step
	grid.add_child(sp_step)

	# 确认: 写入 _param_range_overrides + 应用到当前 SpinBox + 持久化 + push undo
	dlg.confirmed.connect(func() -> void:
		var nmin: float = sp_min.value
		var nmax: float = sp_max.value
		var nstep: float = sp_step.value
		# 防呆: max 必须严格大于 min, 否则 SpinBox 会卡死
		if nmax <= nmin:
			nmax = nmin + maxf(nstep, 0.001)
		# Undo: range op 一次性 push (弹窗确认是离散动作, 不需要合并)
		# had_override 记录 "之前是否有 override", undo 时决定是删 override 还是改回旧值
		if _selected_block_index >= 0 and _selected_block_index < _placed_blocks.size():
			_undo_push({
				"op": "range",
				"index": _selected_block_index,
				"key": key,
				"old_min": cur_min,
				"old_max": cur_max,
				"old_step": cur_step,
				"new_min": nmin,
				"new_max": nmax,
				"new_step": nstep,
				"had_override": _param_range_overrides.has(range_key),
			})
		_param_range_overrides[range_key] = {"min": nmin, "max": nmax, "step": nstep}
		_save_editor_settings()
		# 立刻应用到当前选中的 SpinBox (重建参数面板太重, 只改一个 SpinBox 即可)
		if target_spin and is_instance_valid(target_spin):
			target_spin.min_value = nmin
			target_spin.max_value = nmax
			target_spin.step = nstep
			# 当前值若超出新范围 → clamp 到新边界
			var clamped_v: float = clampf(target_spin.value, nmin, nmax)
			target_spin.value = clamped_v
	)
	# "重置默认" 按钮: 删除 override + 应用默认值到 SpinBox + 持久化
	dlg.custom_action.connect(func(action: StringName) -> void:
		if action == "reset_default":
			_param_range_overrides.erase(range_key)
			_save_editor_settings()
			if target_spin and is_instance_valid(target_spin):
				target_spin.min_value = def_min
				target_spin.max_value = def_max
				target_spin.step = def_step
				target_spin.value = clampf(target_spin.value, def_min, def_max)
			dlg.hide()
	)
	add_child(dlg)
	dlg.popup_centered()


# SpinBox 改值: 同步到选中节点的 transform
# axis: 0=X, 1=Y, 2=Z
func _on_sel_pos_changed(axis: int, v: float) -> void:
	if _selected_block_index < 0 or _selected_block_index >= _placed_blocks.size():
		return
	var first: Node3D = _placed_blocks[_selected_block_index]["node"]
	if first == null:
		return
	# 单选: 直接改第一项
	# 多选: 改值 = "把第一项移到 v" 的偏移, 应用到所有选中
	# 例: 第一项 X 原 = 5, 用户改成 8 → delta = 3, 所有选中的 X += 3
	# 这样的语义保留每个积木相对位置不变, 只是整体平移
	var old_pos: Vector3 = first.global_position
	var delta: Vector3 = Vector3.ZERO
	match axis:
		0: delta.x = v - old_pos.x
		1: delta.y = v - old_pos.y
		2: delta.z = v - old_pos.z
	# Undo: 记录所有选中积木的旧位置和新位置
	var idx_arr: Array = _selected_block_indices.duplicate()
	var old_positions: Array = []
	var new_positions: Array = []
	for i in idx_arr:
		var ii: int = int(i)
		if ii >= 0 and ii < _placed_blocks.size():
			var n: Node3D = _placed_blocks[ii]["node"]
			if n != null:
				old_positions.append(n.global_position)
	if _selected_block_indices.size() <= 1:
		# 单选: 只动这一个
		first.global_position = old_pos + delta
	else:
		# 多选: 全部平移 delta
		for i in _selected_block_indices:
			var ii: int = int(i)
			if ii >= 0 and ii < _placed_blocks.size():
				var n: Node3D = _placed_blocks[ii]["node"]
				if n != null:
					n.global_position += delta
	# 收集新位置
	for i in idx_arr:
		var ii: int = int(i)
		if ii >= 0 and ii < _placed_blocks.size():
			var n: Node3D = _placed_blocks[ii]["node"]
			if n != null:
				new_positions.append(n.global_position)
	# 入 undo 栈
	if not old_positions.is_empty():
		_undo_push({
			"op": "move",
			"indices": idx_arr,
			"old_positions": old_positions,
			"new_positions": new_positions,
		})
	# 选中里有 spawn 时同步回 _spawn_position
	for idx in _selected_block_indices:
		var i2: int = int(idx)
		if i2 >= 0 and i2 < _placed_blocks.size() and String(_placed_blocks[i2].get("kind", "")) == "spawn":
			_sync_spawn_from_placed()
			break


# 角度 SpinBox 改值: 用欧拉角 (YXZ 顺序) 重建 basis
# Godot 默认欧拉顺序 EULER_ORDER_YXZ: Vector3(pitch_x, yaw_y, roll_z)
# 读取时 get_euler() 返回 (pitch, yaw, roll), 写回时用 Basis.from_euler 保证一致
# axis: 0=Yaw, 1=Pitch, 2=Roll
func _on_sel_rot_changed(_axis: int, _v: float) -> void:
	# 多选时角度 SpinBox 已 editable=false, 这里再加一层保护避免误改
	if _selected_block_indices.size() > 1:
		return
	if _selected_block_index < 0 or _selected_block_index >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[_selected_block_index]["node"]
	if node == null:
		return
	# Undo: 记录旋转前的 transform
	var old_xform: Transform3D = node.global_transform
	# 不分轴, 直接重组 basis (从所有 SpinBox 读最新值)
	var yaw_r: float = deg_to_rad(_sel_yaw_spin.value)
	var pitch_r: float = deg_to_rad(_sel_pitch_spin.value)
	var roll_r: float = deg_to_rad(_sel_roll_spin.value)
	# 用 Basis.from_euler 保证与 get_euler() 的读写一致性 (YXZ 顺序)
	var euler := Vector3(pitch_r, yaw_r, roll_r)
	var b := Basis.from_euler(euler)
	var pos: Vector3 = node.global_position
	var new_xform := Transform3D(b, pos)
	node.global_transform = new_xform
	# 入 undo 栈 (复用 rotate op)
	_undo_push({
		"op": "rotate",
		"indices": [_selected_block_index],
		"old_xforms": [old_xform],
		"new_xforms": [new_xform],
	})
	# spawn 同步
	if String(_placed_blocks[_selected_block_index].get("kind", "")) == "spawn":
		_sync_spawn_from_placed()


# "复制角度到当前放置滑块" 按钮: 把选中积木的 yaw/pitch/roll 同步到 _place_*_deg
# 玩家可以"以这个积木的角度为基准, 继续放下一块"
func _on_copy_sel_rotation_to_place() -> void:
	if _selected_block_index < 0 or _selected_block_index >= _placed_blocks.size():
		return
	_set_place_yaw_deg(_sel_yaw_spin.value)
	_set_place_pitch_deg(_sel_pitch_spin.value)
	_set_place_roll_deg(_sel_roll_spin.value)


# R 键: 顺时针旋转选中积木 (单选/多选都支持) 90°
# "顺时针" 从上往下看 (+Y 朝上, 玩家俯视视角) = 绕 Y 轴 -90° (右手定则反向)
#
# 单选: 直接 basis = Basis(UP, -π/2) × 原 basis, 位置不变
# 多选: 以第一个积木的世界位置为 pivot, 所有积木:
#   1) basis 同样左乘旋转
#   2) position 也绕 pivot 旋转 (相对位置 = pos - pivot, 旋转后 + pivot)
#   这样整组的相对几何关系保持, 整体看像是把这一组"扭"了 90°
#
# 为什么顺时针 = -90° 而不是 +90°:
# Godot 用左手坐标系? 不, 是右手. Vector3.UP=(0,1,0), 绕它的正向旋转 (右手定则: 拇指朝 +Y, 四指
# 从 +X 弯向 +Z) → 即 +X 转向 +Z. 但玩家从上往下看时, +Z 在屏幕"下方", +X 在屏幕"右方".
# +X 转向 +Z = 从右转向下 = 逆时针 (从上看).
# 所以"从上看顺时针" = -90° = -π/2.
# ============================================================
#  鼠标拖动选中积木重新摆放位置
# ============================================================
# 用户要求: 选中积木后应该可以重新摆放它的位置
# 设计:
#   1) 鼠标左键点中 (已选中的) 积木 → 进入拖动模式 (_begin_drag_selected)
#   2) 拖动期间在 _process 调 _update_drag_selected, 让选中积木在 XZ 平面跟随鼠标
#      Y 高度保持不变 (拖动平面 = 第一个选中积木的 Y), 这样不会"拖到地下"
#   3) 多选时整组一起平移 (delta = 当前鼠标点 - 起始鼠标点 应用到所有选中节点的备份位置)
#   4) 鼠标松开 (_end_drag_selected) → 同步 SpinBox 显示新坐标, 结束
#   5) 网格吸附 (Alt 关闭) 同样适用 — _snap_to_grid 应用在第一个积木的目标位置上
func _begin_drag_selected() -> void:
	if _selected_block_indices.is_empty():
		return
	var first_idx: int = int(_selected_block_indices[0])
	if first_idx < 0 or first_idx >= _placed_blocks.size():
		return
	var first_node: Node3D = _placed_blocks[first_idx]["node"]
	if first_node == null:
		return
	# 拖动平面 Y = 第一个选中积木的 Y (这样积木不会被拖到地下/天上)
	_drag_plane_y = first_node.global_position.y
	# 默认进入横向模式 (Shift 按下时 _update_drag_selected 会自动切换到纵向)
	_drag_vertical_mode = Input.is_key_pressed(KEY_SHIFT)
	var mp_world: Vector3
	if _drag_vertical_mode:
		mp_world = _project_mouse_to_vertical_plane(first_node.global_position)
	else:
		mp_world = _project_mouse_to_y(_drag_plane_y)
	if mp_world == Vector3.INF:
		return
	_drag_start_mouse_world = mp_world
	# 备份所有选中节点的起始位置
	_drag_start_positions.clear()
	for idx in _selected_block_indices:
		var i: int = int(idx)
		if i >= 0 and i < _placed_blocks.size():
			var n: Node3D = _placed_blocks[i]["node"]
			if n != null:
				_drag_start_positions.append(n.global_position)
			else:
				_drag_start_positions.append(Vector3.ZERO)
		else:
			_drag_start_positions.append(Vector3.ZERO)
	_is_dragging_selected = true


func _update_drag_selected() -> void:
	if not _is_dragging_selected or _selected_block_indices.is_empty():
		return
	# === 模式切换检测 (按住 Shift = 纵向 Y 拖拽) ===
	# 用户需求 (2026-06-02): "横向拖拽很方便, 希望按住快捷键纵向拖拽"
	# 选 Shift 因为它和 Alt(临时关网格) / Ctrl(多选) 都不冲突, 也跟 Shift+滚轮调放置高度
	# 在不同上下文 (拖拽 vs 滚轮) 也不冲突
	#
	# 模式切换数学:
	#   切换瞬间不能直接切, 否则会跳变 — 鼠标在原模式投影到 plane A, 切到新模式投影到
	#   plane B, delta 的"起点"变了, 物体会瞬移. 解决: 切换时重置 _drag_start_positions
	#   为各物体的"当前位置", 同时重置 _drag_start_mouse_world 为新模式当前鼠标投影
	#   → 切换后这一帧 delta = 0, 不会跳变, 之后按新模式累积 delta
	var want_vertical: bool = Input.is_key_pressed(KEY_SHIFT)
	if want_vertical != _drag_vertical_mode:
		_drag_vertical_mode = want_vertical
		# 重置起始位置 = 所有选中物体的当前位置
		_drag_start_positions.clear()
		for idx in _selected_block_indices:
			var i: int = int(idx)
			if i >= 0 and i < _placed_blocks.size():
				var n: Node3D = _placed_blocks[i]["node"]
				if n != null:
					_drag_start_positions.append(n.global_position)
				else:
					_drag_start_positions.append(Vector3.ZERO)
			else:
				_drag_start_positions.append(Vector3.ZERO)
		# 重置起始鼠标世界点为新模式下的投影
		var first_pos: Vector3 = _drag_start_positions[0]
		if _drag_vertical_mode:
			var mp_v: Vector3 = _project_mouse_to_vertical_plane(first_pos)
			if mp_v != Vector3.INF:
				_drag_start_mouse_world = mp_v
		else:
			_drag_plane_y = first_pos.y
			var mp_h: Vector3 = _project_mouse_to_y(_drag_plane_y)
			if mp_h != Vector3.INF:
				_drag_start_mouse_world = mp_h
		# 切换帧不应用 delta, 等下一帧自然累积
		return

	# === 应用 delta (按当前模式) ===
	var mp_world: Vector3
	if _drag_vertical_mode:
		# 纵向模式: 投影到"过第一个物体, 法线 = 相机 forward 在 XZ 的水平投影"的垂直平面
		mp_world = _project_mouse_to_vertical_plane(_drag_start_positions[0] if not _drag_start_positions.is_empty() else Vector3.ZERO)
	else:
		mp_world = _project_mouse_to_y(_drag_plane_y)
	if mp_world == Vector3.INF:
		return
	# delta = 当前鼠标点 - 起始鼠标点
	var delta: Vector3 = mp_world - _drag_start_mouse_world
	if _drag_vertical_mode:
		# 纵向模式: 只保留 Y 分量, XZ 全部清零 (鼠标的 X/Z 分量来自垂直平面投影, 不该影响物体)
		delta = Vector3(0.0, delta.y, 0.0)
		# Y 网格吸附 (用 _grid_step_y 步长, 按 Alt 启用)
		if _grid_snap_enabled and Input.is_key_pressed(KEY_ALT) and not _drag_start_positions.is_empty() and _grid_step_y > 0.001:
			var first_target_y: float = _drag_start_positions[0].y + delta.y
			var snapped_y: float = roundf(first_target_y / _grid_step_y) * _grid_step_y
			delta.y = snapped_y - _drag_start_positions[0].y
	else:
		# 横向模式: Y 不动, 只用 XZ
		delta.y = 0.0
		# 网格吸附: 把"第一个积木的目标新位置"吸附到网格, 再反推 delta
		# (这样多选整组平移时, 第一个积木齐, 其他保持相对偏移)
		if _grid_snap_enabled and Input.is_key_pressed(KEY_ALT) and not _drag_start_positions.is_empty():
			var first_target: Vector3 = _drag_start_positions[0] + delta
			var snapped: Vector3 = _snap_to_grid(first_target)
			delta = snapped - _drag_start_positions[0]
			delta.y = 0.0
	for j in range(_selected_block_indices.size()):
		var idx: int = int(_selected_block_indices[j])
		if idx < 0 or idx >= _placed_blocks.size() or j >= _drag_start_positions.size():
			continue
		var n: Node3D = _placed_blocks[idx]["node"]
		if n != null:
			n.global_position = _drag_start_positions[j] + delta


func _end_drag_selected() -> void:
	if not _is_dragging_selected:
		return
	_is_dragging_selected = false
	# Undo: 把"拖动开始位置 → 拖动结束位置"做成 move op 入栈
	# 只在确实移动了 (delta > 0.001) 时才入栈, 避免单纯点击也产生 undo 项
	if not _drag_start_positions.is_empty() and not _selected_block_indices.is_empty():
		var indices_capture: Array = _selected_block_indices.duplicate()
		var old_positions: Array = _drag_start_positions.duplicate()
		var new_positions: Array = []
		var moved: bool = false
		for j in range(indices_capture.size()):
			var idx: int = int(indices_capture[j])
			if idx >= 0 and idx < _placed_blocks.size() and j < old_positions.size():
				var n: Node3D = _placed_blocks[idx].get("node")
				if n != null:
					new_positions.append(n.global_position)
					if n.global_position.distance_to(old_positions[j]) > 0.001:
						moved = true
				else:
					new_positions.append(old_positions[j])
		if moved:
			_undo_push({
				"op": "move",
				"indices": indices_capture,
				"old_positions": old_positions,
				"new_positions": new_positions,
			})
	_drag_start_positions.clear()
	# 如果拖了 spawn marker, 同步回 _spawn_position/_yaw
	for idx in _selected_block_indices:
		var i: int = int(idx)
		if i >= 0 and i < _placed_blocks.size() and String(_placed_blocks[i].get("kind", "")) == "spawn":
			_sync_spawn_from_placed()
			break
	_sync_sel_spinbox_from_node()


# 鼠标射线与 y=plane_y 平面求交, 失败 (相机射线水平 / 反向) 返回 Vector3.INF
func _project_mouse_to_y(plane_y: float) -> Vector3:
	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mp)
	var dir: Vector3 = _cam.project_ray_normal(mp)
	if absf(dir.y) < 0.001:
		return Vector3.INF
	var t: float = (plane_y - from.y) / dir.y
	if t < 0.0:
		return Vector3.INF
	return from + dir * t


# 鼠标射线与"过 plane_origin 的垂直平面"求交 — 用于 Shift+拖拽的纵向 Y 拖动
# 平面定义:
#   平面经过 plane_origin (通常是物体当前位置)
#   平面法线 = 相机 forward 在 XZ 平面的水平投影 (反向, 让平面正对相机)
#   即: 一个垂直于地面、迎面对着相机的平面
# 数学:
#   cam_fwd_xz = (cam.forward.x, 0, cam.forward.z).normalized()
#   平面法线 n = -cam_fwd_xz   (指向相机)
#   平面方程: (P - plane_origin) · n = 0
#   求 ray: from + t*dir 与平面交
#     t = (plane_origin - from) · n / (dir · n)
# 这样设计的好处:
#   · 鼠标向上移 → 交点 Y 上升 → 物体上升 (符合直觉)
#   · 平面始终迎面对着相机, 鼠标灵敏度最高
#   · 物体 X/Z 不会因为投影到平面而漂移 (因为我们最终只取 delta.y)
func _project_mouse_to_vertical_plane(plane_origin: Vector3) -> Vector3:
	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mp)
	var dir: Vector3 = _cam.project_ray_normal(mp)
	# 相机 forward = -basis.z
	var cam_fwd: Vector3 = -_cam.global_transform.basis.z
	var n: Vector3 = Vector3(cam_fwd.x, 0.0, cam_fwd.z)
	var n_len: float = n.length()
	if n_len < 0.001:
		# 相机几乎垂直俯视 (cam forward ≈ ±Y), 没有有效水平方向
		# 退化: 用 Vector3(0,0,-1) 兜底, 让纵向拖拽至少能用 (虽然手感没这么好)
		n = Vector3(0.0, 0.0, -1.0)
	else:
		n = n / n_len   # 归一化
	# 法线翻反, 让平面"迎面对着相机"
	n = -n
	var denom: float = dir.dot(n)
	if absf(denom) < 0.0001:
		return Vector3.INF
	var t: float = (plane_origin - from).dot(n) / denom
	if t < 0.0:
		return Vector3.INF
	return from + dir * t


func _rotate_selected_blocks_90_cw() -> void:
	if _selected_block_indices.is_empty():
		return
	var rot_basis: Basis = Basis(Vector3.UP, deg_to_rad(-90.0))
	# 以第一个选中积木的位置为 pivot
	var first_idx: int = int(_selected_block_indices[0])
	if first_idx < 0 or first_idx >= _placed_blocks.size():
		return
	var first_node: Node3D = _placed_blocks[first_idx].get("node")
	if first_node == null:
		return
	var pivot: Vector3 = first_node.global_position
	# 备份 old transforms 给 undo 用
	var old_xforms: Array = []
	var new_xforms: Array = []
	var idx_arr: Array = _selected_block_indices.duplicate()
	for idx in idx_arr:
		var i: int = int(idx)
		if i < 0 or i >= _placed_blocks.size():
			continue
		var n: Node3D = _placed_blocks[i].get("node")
		if n == null:
			continue
		var old_xf: Transform3D = n.global_transform
		old_xforms.append(old_xf)
		# 旋转方向: 整体绕 pivot 旋转 → 相对位置先减 pivot, 再左乘 rot_basis, 再加回 pivot
		var rel_pos: Vector3 = old_xf.origin - pivot
		var new_origin: Vector3 = rot_basis * rel_pos + pivot
		var new_basis: Basis = (rot_basis * old_xf.basis).orthonormalized()
		var new_xf: Transform3D = Transform3D(new_basis, new_origin)
		n.global_transform = new_xf
		new_xforms.append(new_xf)
	# 入 undo 栈
	if not old_xforms.is_empty():
		_undo_push({
			"op": "rotate",
			"indices": idx_arr,
			"old_xforms": old_xforms,
			"new_xforms": new_xforms,
		})
	# 同步 spawn (如果选中里有 spawn)
	for idx in idx_arr:
		var i: int = int(idx)
		if i >= 0 and i < _placed_blocks.size() and String(_placed_blocks[i].get("kind", "")) == "spawn":
			_sync_spawn_from_placed()
			break
	_sync_sel_spinbox_from_node()


# 仅同步 SpinBox (X/Y/Z + Yaw/Pitch/Roll) 显示, 不动高亮材质和参数面板
# 用于"修改选中节点 transform 后刷新 UI 显示"的轻量场景
func _sync_sel_spinbox_from_node() -> void:
	if _selected_block_indices.is_empty():
		return
	var first_idx: int = int(_selected_block_indices[0])
	if first_idx < 0 or first_idx >= _placed_blocks.size():
		return
	var n: Node3D = _placed_blocks[first_idx]["node"]
	if n == null:
		return
	var pos: Vector3 = n.global_position
	if _sel_x_spin: _sel_x_spin.set_value_no_signal(pos.x)
	if _sel_y_spin: _sel_y_spin.set_value_no_signal(pos.y)
	if _sel_z_spin: _sel_z_spin.set_value_no_signal(pos.z)
	# 多选时角度 SpinBox 显示 0 (语义模糊), 单选时显示真实角度
	if _selected_block_indices.size() == 1:
		var euler: Vector3 = n.global_transform.basis.get_euler()
		if _sel_yaw_spin: _sel_yaw_spin.set_value_no_signal(rad_to_deg(euler.y))
		if _sel_pitch_spin: _sel_pitch_spin.set_value_no_signal(rad_to_deg(euler.x))
		if _sel_roll_spin: _sel_roll_spin.set_value_no_signal(rad_to_deg(euler.z))


# 在选中积木的所有 MeshInstance3D 上叠加亮黄色 emission, 方便玩家看清哪个被选了
# 同时把克隆的材质存到 _selection_highlight_mats, 用于呼吸动画 (_update_selection_breathe 改 emission_energy)
func _apply_selection_highlight(root: Node) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			# 备份原 material_override (用于取消选中时还原), 然后克隆并加亮
			_selection_highlight_orig_mats[mi] = mi.material_override
			# 优先级:
			#   1) material_override 已存在 (例如 pattern mesh) → duplicate 它
			#   2) 否则取 mesh.surface_get_material(0) (用 SurfaceTool 时材质挂 surface 上, 例如 road/kerb/wall)
			#   3) 都没有 → 新建 StandardMaterial3D
			# 之前 bug: 只看 material_override → 路面 mi 取不到原 material → 新建空白 mat
			# → emission 加上去看不出来 → 用户报"呼吸灯效果消失"
			var src_mat: StandardMaterial3D = null
			if mi.material_override is StandardMaterial3D:
				src_mat = mi.material_override as StandardMaterial3D
			elif mi.mesh and mi.mesh.get_surface_count() > 0:
				var surf_mat: Material = mi.mesh.surface_get_material(0)
				if surf_mat is StandardMaterial3D:
					src_mat = surf_mat as StandardMaterial3D
			var new_mat: StandardMaterial3D
			if src_mat:
				new_mat = src_mat.duplicate() as StandardMaterial3D
			else:
				new_mat = StandardMaterial3D.new()
			new_mat.emission_enabled = true
			new_mat.emission = Color(1.0, 0.9, 0.2)
			new_mat.emission_energy_multiplier = 0.6
			mi.material_override = new_mat
			# 收集到呼吸动画列表 (动画时改 emission_energy_multiplier 在 0.2 ~ 1.2 之间 sin 振荡)
			_selection_highlight_mats.append(new_mat)
		_apply_selection_highlight(child)


func _clear_selection_highlight() -> void:
	for mi in _selection_highlight_orig_mats.keys():
		if is_instance_valid(mi):
			(mi as MeshInstance3D).material_override = _selection_highlight_orig_mats[mi]
	_selection_highlight_orig_mats.clear()
	_selection_highlight_mats.clear()
	_breathe_t = 0.0


# 选中积木的呼吸闪烁动画: emission_energy = base + amp × sin(2π × freq × t)
# base = 0.7, amp = 0.5 → 范围 0.2 ~ 1.2 (柔和明亮变化), freq = 1.5 Hz (1.5 次/秒)
func _update_selection_breathe(delta: float) -> void:
	if _selection_highlight_mats.is_empty():
		return
	_breathe_t += delta
	var energy: float = 0.7 + 0.5 * sin(_breathe_t * TAU * 1.5)
	for m in _selection_highlight_mats:
		if m is StandardMaterial3D:
			(m as StandardMaterial3D).emission_energy_multiplier = energy


# Hover 高亮 (SELECT 模式独有, 鼠标悬停积木时显示蓝色 emission)
# 与"选中高亮"互斥: 如果积木已经被选中, 不再叠加 hover 高亮 (避免冲突)
var _hovered_block_orig_mats: Dictionary = {}    # 当前 hover 积木的原材质备份

func _update_hover_highlight() -> void:
	var picked: int = _pick_placed_block_at_mouse()
	# hover 不能和"已选中"冲突 (单选/多选都判断, _selected_block_indices 包含所有选中索引)
	if _selected_block_indices.has(picked):
		picked = -1
	if picked == _hovered_block_index:
		return
	# 清掉旧 hover 高亮
	_clear_hover_highlight()
	_hovered_block_index = picked
	if picked < 0 or picked >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[picked]["node"]
	if node == null:
		return
	_apply_hover_highlight(node)


func _apply_hover_highlight(root: Node) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			# 不要 hover 已经被选中的 (选中走呼吸动画, 不在 _hovered_block_orig_mats 里)
			if _selection_highlight_orig_mats.has(mi):
				continue
			_hovered_block_orig_mats[mi] = mi.material_override
			# 同选中高亮: material_override 优先 → surface_get_material(0) 兜底
			var src_mat: StandardMaterial3D = null
			if mi.material_override is StandardMaterial3D:
				src_mat = mi.material_override as StandardMaterial3D
			elif mi.mesh and mi.mesh.get_surface_count() > 0:
				var surf_mat: Material = mi.mesh.surface_get_material(0)
				if surf_mat is StandardMaterial3D:
					src_mat = surf_mat as StandardMaterial3D
			var new_mat: StandardMaterial3D
			if src_mat:
				new_mat = src_mat.duplicate() as StandardMaterial3D
			else:
				new_mat = StandardMaterial3D.new()
			new_mat.emission_enabled = true
			new_mat.emission = Color(0.3, 0.7, 1.0)        # 蓝色 hover
			new_mat.emission_energy_multiplier = 0.5
			mi.material_override = new_mat
		_apply_hover_highlight(child)


func _clear_hover_highlight() -> void:
	for mi in _hovered_block_orig_mats.keys():
		if is_instance_valid(mi):
			(mi as MeshInstance3D).material_override = _hovered_block_orig_mats[mi]
	_hovered_block_orig_mats.clear()
	_hovered_block_index = -1


# 鼠标点击时: 用射线打到 _placed_root 子节点的 StaticBody3D, 找最近的积木
# 返回 _placed_blocks 数组的索引 (-1 = 没打到)
func _pick_placed_block_at_mouse() -> int:
	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mp)
	var to: Vector3 = from + _cam.project_ray_normal(mp) * 1000.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	# 只检测 body, 不要命中墙段 area (墙段交互走 _pick_wall_segment_at_mouse 单独处理)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var result := space.intersect_ray(query)
	if result.is_empty():
		return -1
	var hit_node: Node = result["collider"]
	# 向上找父节点直到匹配某个 _placed_blocks 里的 node
	var cur: Node = hit_node
	while cur:
		for i in range(_placed_blocks.size()):
			if _placed_blocks[i]["node"] == cur:
				return i
		cur = cur.get_parent()
	return -1


# 检测鼠标位置下是否命中墙段 Area3D, 命中则返回 {block_index, side, seg}, 否则返回空字典
# 用于编辑器"选中积木后点击墙段切换墙体"功能
func _pick_wall_segment_at_mouse() -> Dictionary:
	var mp: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mp)
	var to: Vector3 = from + _cam.project_ray_normal(mp) * 1000.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false   # 只查 area, 让 raycast 优先识别墙段 (而不是路面 trimesh)
	# 用 layer 1<<6 过滤, 只命中墙 pick area
	query.collision_mask = 1 << 6
	var result := space.intersect_ray(query)
	if result.is_empty():
		return {}
	var hit: Node = result["collider"]
	if not hit.has_meta("is_wall_pick"):
		return {}
	# 找它对应的 _placed_blocks 索引
	var cur: Node = hit
	while cur:
		for i in range(_placed_blocks.size()):
			if _placed_blocks[i]["node"] == cur:
				return {
					"block_index": i,
					"side": float(hit.get_meta("wall_side", -1.0)),
					"seg": float(hit.get_meta("wall_seg", 0.0)),
				}
		cur = cur.get_parent()
	return {}


# ============================================================
#  出生点 marker (绿色立方体, 让用户看到出生位置)
#  用户要求: 出生点也是机关, 可被选中/拖拽 (但不能删除)
#  实现: 创建 marker 后立即 append 到 _placed_blocks 用 kind="spawn"
#       这样选中/hover/拖拽/_pick 全自动适用
# ============================================================
func _build_spawn_marker() -> void:
	# 用 Node3D 作为根节点, 包含车身 BoxMesh + 车头箭头 (指示朝向)
	_spawn_marker = Node3D.new()
	_spawn_marker.name = "SpawnMarker"
	# 车身 BoxMesh (半透明绿色)
	var body_mi := MeshInstance3D.new()
	body_mi.name = "BodyMesh"
	var box := BoxMesh.new()
	box.size = Vector3(2.5, 1.0, 4.5)   # 模拟车身大小
	body_mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 1.0, 0.4, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color(0.3, 1.0, 0.4)
	mat.emission_energy_multiplier = 0.6
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	body_mi.material_override = mat
	_spawn_marker.add_child(body_mi)
	# 车头箭头 (指示车头朝向 = -Z 方向)
	# 用 PrismMesh 做三角形箭头, 放在车身前方
	var arrow_mi := MeshInstance3D.new()
	arrow_mi.name = "ArrowMesh"
	var prism := PrismMesh.new()
	prism.size = Vector3(1.8, 0.3, 1.5)   # 宽 1.8m, 高 0.3m, 深 1.5m
	arrow_mi.mesh = prism
	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.albedo_color = Color(1.0, 1.0, 0.2, 0.8)
	arrow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	arrow_mat.emission_enabled = true
	arrow_mat.emission = Color(1.0, 1.0, 0.2)
	arrow_mat.emission_energy_multiplier = 1.2
	arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow_mi.material_override = arrow_mat
	# PrismMesh 默认尖端朝 +Y, 需要旋转让尖端朝 -Z (车头方向)
	arrow_mi.rotation.x = deg_to_rad(90.0)   # 尖端从 +Y 转到 -Z
	arrow_mi.position = Vector3(0.0, 0.5, -3.0)   # 放在车身前方
	_spawn_marker.add_child(arrow_mi)
	# 添加 StaticBody3D 让 raycast 能命中 (否则 _pick_placed_block_at_mouse 选不到)
	var body := StaticBody3D.new()
	var col_shape := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(2.5, 1.0, 4.5)
	col_shape.shape = sh
	body.add_child(col_shape)
	_spawn_marker.add_child(body)
	# 父节点用 _placed_root 而不是 self, 这样跟其他 placed 项视觉/逻辑统一
	_placed_root.add_child(_spawn_marker)
	_spawn_marker.position = _spawn_position
	_spawn_marker.rotation.y = _spawn_yaw
	# 接入 _placed_blocks (kind="spawn"), 让选中/拖拽统一
	_placed_blocks.append({"id": "spawn_point", "node": _spawn_marker, "kind": "spawn"})


# ============================================================
#  网格地面绘制 (3D 可见网格, 让玩家直观看到吸附位置)
# ============================================================
# 用 ImmediateMesh + PRIMITIVE_LINES 画两层网格:
#   1) XZ 平面网格 (y=0): 主网格 (灰色细线, 间距 = _grid_step_xz, 默认 4m), 副网格 (亮线, 每 5×主线一条)
#   2) 当前 Y 高度的"吸附层"指示线 (青色虚拟方框, 在鼠标当前 Y 高度画 5×5 个网格点 + 框)
#      这层会跟着 _place_y_offset 上下移动, 让玩家明确看到自己当前在哪一层放积木
# 网格总范围: 200m × 200m (足够大), 主线灰色 alpha 0.4, 副线浅黄 alpha 0.7


# ============================================================
# 递归关闭 Button / OptionButton / CheckBox 等的焦点导航
# ============================================================
# 修复 A 键不工作的根本方案: 玩家点过左侧"积木"按钮后, Button 拿到焦点
# 之后按 A/D 字母键时, Godot 默认把它们当成焦点导航键吞掉, 导致 WASD 失效.
# 解决方案: 把所有这类按钮的 focus_mode = FOCUS_NONE, 它们就永远不接受键盘焦点.
# 副作用: 玩家不能用 Tab 在按钮间切换 — 但编辑器是鼠标操作为主, 可接受.
# 不影响: LineEdit / SpinBox / TextEdit (它们需要焦点才能编辑, 由 _physics_process 单独保护)
func _disable_button_focus_recursive(node: Node) -> void:
	if node == null:
		return
	# Button / CheckBox / OptionButton / MenuButton 等都继承自 BaseButton
	if node is BaseButton:
		(node as BaseButton).focus_mode = Control.FOCUS_NONE
	for c in node.get_children():
		_disable_button_focus_recursive(c)


# ============================================================
# 编辑器内的地面平面 (用户能开关 + 调色)
# ============================================================
# 之前编辑器场景里 Ground 节点是空的 — 用户看到的"白色陆地"实际上是 TrackRunner.tscn 里的
# 静态 PlaneMesh. 编辑器里也构造一个等效的 mesh 让玩家能"所见即所得"地预览.
# 鼠标 raycast (_get_mouse_world_point) 用 plane y=_place_y_offset 不依赖这个 mesh 碰撞,
# 所以本地面 mesh 不需要 collision, 只是视觉.
func _rebuild_editor_ground() -> void:
	if _ground == null:
		return
	# 清掉旧 mesh
	if _ground_mesh_inst != null:
		_ground_mesh_inst.queue_free()
		_ground_mesh_inst = null
	if not _ground_enabled:
		return
	_ground_mesh_inst = MeshInstance3D.new()
	_ground_mesh_inst.name = "EditorGroundMesh"
	var pm := PlaneMesh.new()
	pm.size = Vector2(800, 800)   # 800m × 800m 够大
	_ground_mesh_inst.mesh = pm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _ground_color
	# 地面只接受光照不投射阴影 (不然会出现奇怪的赛道阴影投在地面上)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_ground_mesh_inst.material_override = mat
	# 略微下沉 5cm 避免和路面 z-fighting
	_ground_mesh_inst.position = Vector3(0.0, -0.05, 0.0)
	_ground.add_child(_ground_mesh_inst)


func _build_grid_mesh() -> void:
	_grid_mesh_node = $GridLines
	if _grid_mesh_node == null:
		push_warning("[TrackEditor] 找不到 GridLines 节点")
		return
	_grid_mesh_node.visible = true
	_rebuild_grid_lines()


# 重建网格线 mesh. 在 _grid_step_xz / _grid_step_y / _place_y_offset 改变时调
func _rebuild_grid_lines() -> void:
	if _grid_mesh_node == null:
		return
	var im := ImmediateMesh.new()
	# 共用一个 unshaded 双面材质 (vertex_color 让我们对每条线指定颜色)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var half_size: float = 200.0  # 网格半径 (向四周延伸 200m)
	var step: float = maxf(_grid_step_xz, 0.01)
	var color_minor := Color(0.5, 0.5, 0.55, 0.35)
	var color_major := Color(1.0, 0.85, 0.3, 0.6)
	# 主线: y=0 平面, 沿 X 方向画一组线 (从 -half 到 +half, 每 step 间距)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	# 沿 Z 移动画 X 方向线
	var z: float = -half_size
	while z <= half_size + 0.01:
		# 每 5 倍主线高亮一次
		var is_major: bool = absf(fmod(z, step * 5.0)) < 0.01
		var c: Color = color_major if is_major else color_minor
		im.surface_set_color(c)
		im.surface_add_vertex(Vector3(-half_size, 0.0, z))
		im.surface_set_color(c)
		im.surface_add_vertex(Vector3(half_size, 0.0, z))
		z += step
	# 沿 X 移动画 Z 方向线
	var x: float = -half_size
	while x <= half_size + 0.01:
		var is_major2: bool = absf(fmod(x, step * 5.0)) < 0.01
		var c2: Color = color_major if is_major2 else color_minor
		im.surface_set_color(c2)
		im.surface_add_vertex(Vector3(x, 0.0, -half_size))
		im.surface_set_color(c2)
		im.surface_add_vertex(Vector3(x, 0.0, half_size))
		x += step
	im.surface_end()

	# 当前 Y 高度的"吸附层"指示框 (青色边框 + 中心十字)
	# 仅在 _place_y_offset 不等于 0 时画 (0 时已经和地面网格重合了)
	if absf(_place_y_offset) > 0.01:
		im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
		var y: float = _place_y_offset
		var box_half: float = 30.0   # 当前层指示框半径 (30m × 30m)
		var col_layer := Color(0.4, 0.95, 1.0, 0.9)
		# 4 条边
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(-box_half, y, -box_half))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(box_half, y, -box_half))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(box_half, y, -box_half))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(box_half, y, box_half))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(box_half, y, box_half))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(-box_half, y, box_half))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(-box_half, y, box_half))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(-box_half, y, -box_half))
		# 中心十字 (X / Z 各 10m)
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(-10.0, y, 0.0))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(10.0, y, 0.0))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(0.0, y, -10.0))
		im.surface_set_color(col_layer); im.surface_add_vertex(Vector3(0.0, y, 10.0))
		im.surface_end()

	_grid_mesh_node.mesh = im





# ============================================================
#  鼠标拾取 (射线检测地面/积木)
# ============================================================
func _get_mouse_world_point() -> Vector3:
	# 从鼠标位置发射射线打到 y=_place_y_offset 平面, 返回交点
	# 平面 y=_place_y_offset 让玩家能在不同高度层放置积木 (Shift+滚轮调高度)
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mouse_pos)
	var dir: Vector3 = _cam.project_ray_normal(mouse_pos)
	# 与 y=_place_y_offset 平面求交: from.y + t×dir.y = y_target → t = (y_target - from.y) / dir.y
	if absf(dir.y) < 0.001:
		return Vector3.ZERO
	var t: float = (_place_y_offset - from.y) / dir.y
	if t < 0.0:
		return Vector3.ZERO
	return from + dir * t


## C 键表面吸附: 从鼠标射线 raycast 到场景中的碰撞体 (道路/窄道表面)
## 返回 {"position": Vector3, "normal": Vector3} 或空字典
func _raycast_surface_at_mouse() -> Dictionary:
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = _cam.project_ray_origin(mouse_pos)
	var dir: Vector3 = _cam.project_ray_normal(mouse_pos)
	var space_state: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state
	if space_state == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * 2000.0)
	query.collision_mask = 1  # 只检测 layer 1 (道路/积木的碰撞层)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	# 排除预览节点自身的碰撞体, 防止 raycast 打到自己导致机关越吸越近
	if _preview_node != null:
		var exclude_rids: Array[RID] = []
		_collect_body_rids(_preview_node, exclude_rids)
		query.exclude = exclude_rids
	var result: Dictionary = space_state.intersect_ray(query)
	if result.is_empty():
		return {}
	return {"position": result["position"], "normal": result["normal"]}


## 递归收集节点树下所有 CollisionObject3D 的 RID (用于 raycast 排除)
func _collect_body_rids(node: Node, out: Array[RID]) -> void:
	if node is CollisionObject3D:
		out.append(node.get_rid())
	for child in node.get_children():
		_collect_body_rids(child, out)


# ============================================================
#  预览节点 (鼠标 hover 显示半透明积木/锚点)
# ============================================================
func _rebuild_preview() -> void:
	if _preview_node:
		_preview_node.queue_free()
		_preview_node = null
	# PRESET 模式: 不用 _preview_node, 用 _preset_preview_nodes (一组节点)
	_clear_preset_preview()
	if _current_tool == Tool.SELECT:
		# SELECT 模式不需要预览节点 (鼠标 hover 高亮直接作用于已放置积木)
		return
	if _current_tool == Tool.BLOCK:
		var path: String = BLOCK_LIBRARY.get(_selected_block_id, "")
		if path == "":
			return
		var packed: PackedScene = load(path)
		if packed == null:
			return
		_preview_node = packed.instantiate()
		_make_node_transparent(_preview_node, 0.45)
		add_child(_preview_node)
	elif _current_tool == Tool.PRESET:
		# 实例化预设里所有积木, 都做半透明, 整组以 (0,0,0) 为基准放在 _preset_preview_nodes
		# _process 里会把第一项移到鼠标位置, 其它项按 rel_xform 跟着走
		if _current_preset_index < 0 or _current_preset_index >= _block_presets.size():
			return
		var preset: Dictionary = _block_presets[_current_preset_index]
		var items: Array = preset.get("items", [])
		for it in items:
			var bid: String = String(it.get("id", ""))
			var bpath: String = BLOCK_LIBRARY.get(bid, "")
			if bpath == "":
				continue
			var bpk: PackedScene = load(bpath)
			if bpk == null:
				continue
			var n: Node3D = bpk.instantiate()
			_make_node_transparent(n, 0.45)
			add_child(n)
			# 暂时把 transform 放成 rel_xform (相对第一项), _process 会再 base*rel
			var rel: Transform3D = it.get("rel_xform", Transform3D.IDENTITY)
			n.transform = rel
			_preset_preview_nodes.append(n)
	else:
		# Tool.ANCHOR / Tool.SPAWN 都用一个简单的 mesh 预览
		_preview_node = MeshInstance3D.new()
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if _current_tool == Tool.SPAWN:
			# 出生点预览: 绿色车形盒
			var box := BoxMesh.new()
			box.size = Vector3(2.5, 1.0, 4.5)
			(_preview_node as MeshInstance3D).mesh = box
			mat.albedo_color = Color(0.3, 1.0, 0.4, 0.45)
			mat.emission_enabled = true
			mat.emission = Color(0.3, 1.0, 0.4)
			mat.emission_energy_multiplier = 0.4
		else:
			# 锚点预览: 青色半透明球
			var sphere := SphereMesh.new()
			sphere.radius = 1.5
			sphere.height = 3.0
			(_preview_node as MeshInstance3D).mesh = sphere
			mat.albedo_color = Color(0.3, 0.85, 1.0, 0.5)
		(_preview_node as MeshInstance3D).material_override = mat
		add_child(_preview_node)


func _make_node_transparent(node: Node, alpha: float) -> void:
	# 递归把所有 MeshInstance3D 的材质 alpha 调低
	# 注: 为了不污染原 .tscn 的材质 cache, 用 material_override 覆盖
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.material_override is StandardMaterial3D:
			var orig_mat := mi.material_override as StandardMaterial3D
			var new_mat := orig_mat.duplicate() as StandardMaterial3D
			new_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			var c: Color = new_mat.albedo_color
			c.a = alpha
			new_mat.albedo_color = c
			mi.material_override = new_mat
		# 关掉碰撞 (StaticBody3D), 避免预览节点跟已放置积木碰撞
	if node is StaticBody3D:
		(node as StaticBody3D).collision_layer = 0
		(node as StaticBody3D).collision_mask = 0
	for c in node.get_children():
		_make_node_transparent(c, alpha)


# ============================================================
#  鼠标位置更新预览
# ============================================================
func _process(delta: float) -> void:
	# 机关栏宽度同步: 让机关栏 ScrollContainer 的可视宽度等于积木栏 panel 宽度
	# 用户需求 (2026-06-02): "机关栏太长了 现在有进度条 可以改成跟积木栏一样宽"
	# 实现: 每帧读 blocks_panel.size.x (由 CenterContainer 自适应内容算出)
	#       减 16 = 减去 mech_panel 的 content_margin (左右各 8) 让 scroll 内容区跟 blocks 视觉对齐
	#       超过 16px 差异才同步, 避免微小浮动反复触发 layout
	if _bottom_blocks_panel != null and _mech_scroll != null:
		var target_w: float = maxf(_bottom_blocks_panel.size.x - 16.0, 200.0)
		if absf(_mech_scroll.custom_minimum_size.x - target_w) > 0.5:
			_mech_scroll.custom_minimum_size.x = target_w
	# 粘贴预览跟随鼠标
	_update_paste_preview()
	# 选中积木呼吸闪烁动画 (用 sin 让 emission 强度上下变化)
	# 即使 _preview_node 为 null 也要跑, 否则 SELECT 模式下闪烁停了
	_update_selection_breathe(delta)
	# 待 flush 的 undo (参数/颜色/范围连续修改) 倒计时
	# 用户拖完 SpinBox 或色盘后停手 PARAM_UNDO_FLUSH_DELAY 秒, 自动 push 一条 undo
	if not _pending_undo.is_empty():
		var t: float = float(_pending_undo.get("timer", 0.0)) - delta
		if t <= 0.0:
			_flush_pending_undo()
		else:
			_pending_undo["timer"] = t
	# SELECT 模式: 处理鼠标 hover 高亮 + 选中拖动
	if _current_tool == Tool.SELECT:
		# 手柄拖拽优先
		if _is_dragging_handle:
			_update_drag_handle()
			return
		# 拖动优先, 拖动时不更新 hover (避免 hover 蓝色闪烁覆盖选中黄色)
		if _is_dragging_selected:
			_update_drag_selected()
		else:
			_update_hover_highlight()
		return
	# PRESET 模式: 跟随鼠标移动整组预览
	if _current_tool == Tool.PRESET:
		if _preset_preview_nodes.is_empty():
			return
		var pp: Vector3 = _get_mouse_world_point()
		if pp == Vector3.ZERO:
			return
		if _grid_snap_enabled and Input.is_key_pressed(KEY_ALT):
			pp = _snap_to_grid(pp)
		# 第一项放在鼠标位置 + 应用 UI 角度; 其它项按 rel_xform 跟着第一项走
		# rel_xform 已在 _rebuild_preview 写到 n.transform, 所以只要把每个 n 的 global =
		#   base_xform * rel  (rel = stored transform)
		var base_basis: Basis = _get_place_extra_basis()
		var base_xform := Transform3D(base_basis, pp).orthonormalized()
		var preset: Dictionary = _block_presets[_current_preset_index]
		var items: Array = preset.get("items", [])
		for i in range(_preset_preview_nodes.size()):
			var n: Node3D = _preset_preview_nodes[i]
			if n == null or i >= items.size():
				continue
			var rel: Transform3D = items[i].get("rel_xform", Transform3D.IDENTITY)
			n.global_transform = (base_xform * rel).orthonormalized()
		return
	# BLOCK / ANCHOR / SPAWN 模式: 跟随鼠标的预览节点
	if _preview_node == null:
		return
	# C 键吸附: 机关/出生点/锚点吸附到道路/窄道表面 (raycast 到物理碰撞体表面)
	# 优先尝试 C 键吸附 (即使平面交点失败也能靠 raycast 找到道路)
	var _surface_snapped: bool = false
	var p: Vector3 = Vector3.ZERO
	if Input.is_key_pressed(KEY_C) and _current_tool in [Tool.BLOCK, Tool.SPAWN, Tool.ANCHOR]:
		var snap_result: Dictionary = _raycast_surface_at_mouse()
		if not snap_result.is_empty():
			p = snap_result["position"] + Vector3.UP * 0.05  # 微抬防 z-fighting
			_surface_snapped = true
	if not _surface_snapped:
		p = _get_mouse_world_point()
		if p == Vector3.ZERO:
			return
	# 网格吸附 (按住 Alt 可临时关闭, 让玩家精细微调)
	if not _surface_snapped and _grid_snap_enabled and Input.is_key_pressed(KEY_ALT):
		p = _snap_to_grid(p)
	if _current_tool == Tool.BLOCK:
		# 窄道吸附预览: 如果正在放窄道且选中了已有窄道, 预览位置+朝向吸附到端点
		var narrow_snap_basis: Basis = Basis.IDENTITY
		var narrow_snapped: bool = false
		if (_selected_block_id == "narrow_path" or _selected_block_id == "fragile_narrow") and not _selected_block_indices.is_empty():
			var sel_idx: int = int(_selected_block_indices[0])
			if sel_idx >= 0 and sel_idx < _placed_blocks.size():
				var sel_node: Node3D = _placed_blocks[sel_idx].get("node")
				if sel_node != null and sel_node.has_method("get_end_world_pos"):
					var nearest: String = sel_node.call("get_nearest_endpoint", p)
					var snap_pos: Vector3
					var tangent: Vector3
					if nearest == "end":
						snap_pos = sel_node.call("get_end_world_pos")
						tangent = sel_node.call("get_end_tangent_world")
					else:
						snap_pos = sel_node.call("get_start_world_pos")
						tangent = -sel_node.call("get_start_tangent_world")  # 反向: 新窄道从这里出发
					# 只在鼠标距端点 < 15m 时吸附
					if p.distance_to(snap_pos) < 15.0:
						p = snap_pos
						# 对齐朝向: 让新窄道的 -Z (前进方向) 对齐切线方向
						if tangent.length() > 0.01:
							var fwd: Vector3 = tangent.normalized()
							var up := Vector3.UP
							var right: Vector3 = up.cross(fwd).normalized()
							if right.length() < 0.01:
								right = Vector3.RIGHT
							up = fwd.cross(right).normalized()
							narrow_snap_basis = Basis(right, up, -fwd)
							narrow_snapped = true
		var basis: Basis = narrow_snap_basis if narrow_snapped else _get_place_extra_basis()
		_preview_node.global_transform = Transform3D(basis, p).orthonormalized()
	elif _current_tool == Tool.SPAWN:
		# 出生点预览: 跟随鼠标 + 应用 yaw 滑块 (让玩家可以调整出生朝向)
		var basis2: Basis = Basis(Vector3.UP, deg_to_rad(_place_yaw_deg))
		_preview_node.global_transform = Transform3D(basis2, p).orthonormalized()
	else:
		# 锚点: 鼠标地面位置 + 默认 8m 高度
		_preview_node.global_position = p + Vector3(0.0, 8.0, 0.0)


# 把世界点吸附到网格 (XZ 用 _grid_step_xz, Y 用 _grid_step_y)
func _snap_to_grid(p: Vector3) -> Vector3:
	var step_xz: float = maxf(_grid_step_xz, 0.01)
	var step_y: float = maxf(_grid_step_y, 0.01)
	return Vector3(
		round(p.x / step_xz) * step_xz,
		round(p.y / step_y) * step_y,
		round(p.z / step_xz) * step_xz
	)


## (保留这个函数以备未来"磁吸模式"用, 但当前不再调用)
## 计算预览积木如果磁吸到上一块出口的位置, 然后叠加 yaw/pitch/roll
## 当前自由放置流程不调用此函数
func _compute_attach_transform_for_preview(_mouse_p: Vector3) -> Transform3D:
	if _placed_blocks.is_empty():
		return Transform3D.IDENTITY
	var last_data: Dictionary = _placed_blocks[-1]
	var last_node: Node3D = last_data["node"]
	if last_node == null or not last_node.has_method("get_exit_world_transform"):
		return Transform3D.IDENTITY
	var prev_exit_world: Transform3D = last_node.call("get_exit_world_transform")
	if _preview_node and _preview_node.has_method("compute_attach_transform"):
		var x: Transform3D = _preview_node.call("compute_attach_transform", prev_exit_world)
		x.basis = x.basis * _get_place_extra_basis()
		return x.orthonormalized()
	return prev_exit_world


# ============================================================
#  输入处理
# ============================================================
# ============================================================
# 检查鼠标是否处在编辑器 UI 面板之上 (用于 _unhandled_input 兜底拦截)
# ============================================================
# 设计思路: 遍历 _ui (CanvasLayer) 下所有 Control, 找出 mouse_filter == STOP 且
#           可见的 Control, 把它们的 global_rect 累加, 看鼠标是不是在其中.
# 为什么需要: Godot 4 的 Container (VBox/HBox/ScrollContainer) 默认 mouse_filter=PASS
#           理论上 PanelContainer 设了 STOP 就会拦截, 但实测某些 layout/anchor 组合
#           下点击仍会穿透到 _unhandled_input. 这是 Godot 已知的边界 case.
# 性能: 每次点击调一次, 遍历整棵 UI 树, 通常 < 100 个 Control, 完全可承受.
func _is_mouse_over_ui_panel(mp: Vector2) -> bool:
	if _ui == null:
		return false
	return _check_ui_hit_recursive(_ui, mp)


# 递归检查 node 树, 命中任何"可见 + STOP filter + 鼠标在 rect 内"的 Control 即返回 true
func _check_ui_hit_recursive(node: Node, mp: Vector2) -> bool:
	if node == null:
		return false
	if node is Control:
		var c: Control = node
		# 不可见的 Control 跳过 (面板隐藏时不算 UI 命中)
		if c.visible and c.mouse_filter == Control.MOUSE_FILTER_STOP:
			# get_global_rect 给的是相对 viewport 的屏幕坐标, 与 get_mouse_position 一致
			var r: Rect2 = c.get_global_rect()
			if r.has_point(mp):
				return true
	# 即使 node 自己没命中也要检查子节点 (PASS 的容器内可能套着 STOP 的子 panel)
	for ch in node.get_children():
		if _check_ui_hit_recursive(ch, mp):
			return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	# 鼠标在 UI 面板上时 (mouse_filter STOP) 不会到这里, 所以这里只处理视口的输入
	# 但是: 实际测试发现某些情况 (Container 默认 PASS, 子控件没拿到事件) 鼠标点击会穿透到这里,
	# 导致用户点参数面板里的 SpinBox/标签/按钮时, 这里以为是"点击空白处" → _select_block(-1)
	# → 整个参数面板被隐藏 = 用户感受到的"点一下面板就关闭".
	# 兜底修复: 鼠标点击 (按键) 时手动检查鼠标是否处在某个 STOP 类 UI Control 之上, 是就忽略
	# 仅对 InputEventMouseButton 做这层检查; MouseMotion 和键盘事件不影响, 让原逻辑跑
	if event is InputEventMouseButton:
		var mb_check: InputEventMouseButton = event
		if mb_check.pressed:
			var mp: Vector2 = get_viewport().get_mouse_position()
			if _is_mouse_over_ui_panel(mp):
				return





	# === 鼠标按键 ===
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			# 粘贴模式: 点击 = 确认放下 (优先级最高)
			if _paste_mode:
				_confirm_paste()
				return
			# 左键行为按工具模式分流:
			#   SELECT 模式: 点击 = 选中已放置积木; 点空白 = 取消选中 (不会放新积木!)
			#   BLOCK 模式 : 点击 = 放新积木 (玩家选了具体积木后才进 BLOCK 模式)
			#   ANCHOR 模式: 点击 = 放钩索锚点
			if _current_tool == Tool.SELECT:
				# 用户要求: 选中积木后可以点击它的墙段切换有/无墙
				# 墙段命中要在普通积木命中之前判定 (因为墙段 area 在 body 里面, body 优先 raycast 命中会盖过)
				# 仅在"当前已经选中了积木 + 不是 Ctrl+点击 + 不是空白"时启用墙段交互
				if not mb.ctrl_pressed and not _selected_block_indices.is_empty():
					var wall_hit: Dictionary = _pick_wall_segment_at_mouse()
					if not wall_hit.is_empty():
						var hit_idx: int = int(wall_hit["block_index"])
						# 必须是当前选中的积木的墙段才能切换 (避免点别的积木的墙误操作)
						if _selected_block_indices.has(hit_idx):
							var bnode: Node3D = _placed_blocks[hit_idx].get("node")
							if bnode != null and bnode.has_method("toggle_wall_segment"):
								# 切换前记录状态做 undo (用 param op, key="wall_xx" 编码 side+seg)
								var side: float = float(wall_hit["side"])
								var seg: float = float(wall_hit["seg"])
								var key: String = ("wall_left_" if side < 0 else "wall_right_") + ("in" if seg < 0.5 else "out")
								var old_v: bool = bnode.get(key)
								bnode.call("toggle_wall_segment", side, seg)
								# Undo: 把 bool 编码为 0/1 复用 param op
								_undo_push({
									"op": "param",
									"index": hit_idx,
									"key": key,
									"old_value": 1.0 if old_v else 0.0,
									"new_value": 0.0 if old_v else 1.0,
								})
								# 切完墙后重新刷新选中高亮 (rebuild 后 mesh 是新的)
								_clear_selection_highlight()
								_apply_selection_highlight(bnode)
								# 同步参数面板的 4 个 0/1 SpinBox 显示
								_refresh_selection_ui()
								return
				# 窄道手柄检测: 已选中窄道时, 点击手柄球体 → 进入手柄拖拽模式
				if not _selected_block_indices.is_empty():
					var handle_hit: String = _pick_narrow_path_handle_at_mouse()
					if handle_hit != "":
						# 墙壁节点: 双击切换 active, 单击拖拽
						if handle_hit.begins_with("wall_") and mb.double_click:
							_wall_toggle_node_by_name(handle_hit)
							return
						_begin_drag_handle(handle_hit)
						return
				var picked: int = _pick_placed_block_at_mouse()
				# Ctrl+点击 = 多选切换 (加入/移出)
				if mb.ctrl_pressed and picked >= 0:
					_toggle_select_block(picked)
				elif picked >= 0:
					# 点的是积木 — 几个分支:
					#   a) 已经在选中里 → 进入"拖动重新摆放"模式 (用户要求: 选中后可以鼠标拖动)
					#   b) 不在选中里 → 单选这一个 + 立即进入拖动 (这样"点中并拖"一气呵成)
					if not _selected_block_indices.has(picked):
						_select_block(picked)
					# 启动拖动
					_begin_drag_selected()
				else:
					# 空白处取消选中
					if not _selected_block_indices.is_empty():
						_select_block(-1)
			else:
				# BLOCK / ANCHOR / PRESET 模式: 直接放置
				_place_at_mouse()
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			# 鼠标左键松开 → 结束拖动 (无论之前是否在拖)
			if _is_dragging_handle:
				_end_drag_handle()
			elif _is_dragging_selected:
				_end_drag_selected()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_is_rotating_cam = mb.pressed
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			# Shift+滚轮 = 放置 Y 高度 +1 步; 普通滚轮 = 相机 zoom in
			if mb.shift_pressed:
				_set_place_y_offset(_place_y_offset + _grid_step_y)
			else:
				_cam_distance = maxf(_cam_distance - CAM_ZOOM_SPEED, 2.0)
				_update_camera_transform()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if mb.shift_pressed:
				_set_place_y_offset(_place_y_offset - _grid_step_y)
			else:
				_cam_distance = minf(_cam_distance + CAM_ZOOM_SPEED, 300.0)
				_update_camera_transform()

	# === 鼠标移动 (旋转视角) ===
	elif event is InputEventMouseMotion and _is_rotating_cam:
		var mm: InputEventMouseMotion = event
		_cam_yaw -= mm.relative.x * CAM_ROTATE_SENSITIVITY
		_cam_pitch = clampf(_cam_pitch - mm.relative.y * CAM_ROTATE_SENSITIVITY, -1.55, 1.2)
		_update_camera_transform()

	# === 键盘 ===
	elif event is InputEventKey and event.pressed and not event.echo:
		# 数字键 1~7 选积木
		for info in BLOCK_INFO:
			if event.keycode == info["hotkey"]:
				_set_tool(Tool.BLOCK, info["id"])
				return
		# 机关栏快捷键 (6/7/8) - 跟 BLOCK_INFO 走同一个分支但 kind 来自 MECHANISM_INFO
		for minfo in MECHANISM_INFO:
			if minfo.has("hotkey") and event.keycode == minfo["hotkey"]:
				_set_mechanism_tool(String(minfo["id"]), String(minfo.get("kind", "block")))
				return
		match event.keycode:
			# A 键: 不再切换锚点工具 (避免与 WASD 平移冲突). 锚点工具只能从 UI 按钮进入
			KEY_DELETE:
				_delete_under_cursor()
			KEY_F5:
				_on_test_pressed()
			KEY_ESCAPE:
				# 粘贴模式下 ESC = 取消粘贴 (优先级最高)
				if _paste_mode:
					_cancel_paste()
					return
				# ESC 行为 (用户要求: 编辑器场景下 ESC 绝不返回主场景):
				#   · 当前在 BLOCK / ANCHOR 工具 → 切回 SELECT 模式 (退出当前工具)
				#   · 当前在 SELECT 但有选中 → 取消选中
				#   · SELECT 且无选中 → 不做任何事 (留在编辑器, 玩家想退出走 UI 按钮 ◀ 返回主菜单)
				if _current_tool != Tool.SELECT:
					_set_tool(Tool.SELECT, "")
				elif not _selected_block_indices.is_empty():
					_select_block(-1)
				# else: 留在编辑器, 不再 _on_back_pressed
			KEY_Z:
				if event.ctrl_pressed:
					if event.shift_pressed:
						# Ctrl+Shift+Z = 重做 (跟 Ctrl+Y 同效)
						_redo_last()
					else:
						_undo_last()
			KEY_Y:
				# Ctrl+Y = 重做
				if event.ctrl_pressed:
					_redo_last()
			KEY_C:
				# Ctrl+C = 复制选中
				if event.ctrl_pressed and not _selected_block_indices.is_empty():
					_copy_selected()
			KEY_V:
				# Ctrl+V = 粘贴 (进入预览模式跟随鼠标)
				if event.ctrl_pressed and not _clipboard.is_empty():
					_start_paste_preview()
			KEY_D:
				# Ctrl+D = 原地复制 (偏移 +2m 在相机右方向, 立即放下)
				if event.ctrl_pressed and not _selected_block_indices.is_empty():
					_duplicate_in_place()
			KEY_J:
				# J 键 = 连接两段窄道 (在选中的两段之间生成普通窄道连接)
				if _selected_block_indices.size() == 2:
					_join_narrow_paths("narrow_path")
			KEY_K:
				# K 键 = 连接两段窄道 (在选中的两段之间生成易碎窄道连接)
				if _selected_block_indices.size() == 2:
					_join_narrow_paths("fragile_narrow")
			KEY_L:
				# L 键 = 在选中的道路/窄道中线上生成绳星轨迹 (每3颗一组)
				if not _selected_block_indices.is_empty():
					_generate_star_trails_on_selected()
			KEY_EQUAL:
				# + 键 = 直角窄道新增节点 / 墙壁模式下新增墙节点
				if _wall_handle_mode > 0:
					_wall_add_node_at_center()
				else:
					_right_angle_add_waypoint()
			KEY_MINUS:
				# - 键 = 直角窄道删除末尾节点 / 墙壁模式下删除末尾墙节点
				if _wall_handle_mode > 0:
					_wall_remove_last_node()
				else:
					_right_angle_remove_waypoint()
			KEY_H:
				# H 键 = 切换手柄模式 (路径 → 左墙 → 右墙 → 路径)
				_toggle_wall_handle_mode()
			KEY_U:
				# U 键 = 墙壁模式下快捷开关整面墙壁 (全部节点 active 切换)
				_wall_toggle_all()
			KEY_R:
				# R 键 = 顺时针旋转 yaw +90°, 行为按当前模式区分:
				#   · SELECT 模式 + 已选中积木 → 旋转选中的积木 (单选/多选都支持, 多选时整组绕第一个旋转)
				#   · BLOCK / PRESET / ANCHOR 放置模式 → 旋转下一次放置的预览 (即 _place_yaw_deg += 90)
				#     这样玩家在拿着积木对着鼠标看预览时, R 一下立刻看到预览转 90°, 不用回到滑块上拖
				# 数学: place_yaw_deg ∈ [-180,180], +90 后 wrap 回区间. _set_place_yaw_deg 内部已经 clamp,
				#   但 clamp 不是 wrap, 所以这里手动 wrap 让连按 4 次 R 回到 0 而不是停在 180
				if _current_tool == Tool.SELECT and not _selected_block_indices.is_empty():
					_rotate_selected_blocks_90_cw()
				elif _current_tool != Tool.SELECT:
					var new_yaw: float = _place_yaw_deg + 90.0
					# wrap 到 (-180, 180]: 先 +180 取模 360 再 -180
					while new_yaw > 180.0:
						new_yaw -= 360.0
					while new_yaw <= -180.0:
						new_yaw += 360.0
					_set_place_yaw_deg(new_yaw)
					_rebuild_preview()   # 立即让预览反映新 yaw


# WASD 平移 (持续按)
# A 键不工作的历史: 旧版有特殊条件 `Input.is_key_pressed(KEY_A) and not _is_rotating_cam`
# (本意是右键拖动旋转视角时不响应 A), 但这条件在某些情况下卡住 — 比如鼠标焦点丢失
# 后 _is_rotating_cam 可能没被还原. 而且 W/S/D 都没这条件, 单 A 不一致.
# 修复: 去掉 _is_rotating_cam 条件, A 跟 W/S/D 完全一致.
# 焦点保护: 当 SpinBox / LineEdit 拿到键盘焦点时, 整个 WASD 都不响应,
# 否则按 A 会同时给 SpinBox 输入字母 + 平移视角.
func _physics_process(delta: float) -> void:
	# 焦点在 LineEdit (含 SpinBox 内部 LineEdit) 时, 跳过 WASD
	# 让玩家在编辑参数时 A 键能正常输入字母, 不会被相机抢走
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit:
		return
	# 用 input 直接读, 持续按住生效
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		move.z += 1.0
	if Input.is_key_pressed(KEY_A):
		# 去掉了 not _is_rotating_cam 限制, A 跟 WSD 一样无条件响应
		# 关键修复: 按下 A 时, 如果焦点在 Button 等 Control 上, 主动 release_focus
		# 否则 Godot 4 的 Button 默认会把方向键/A/D 当焦点导航键吞掉, 导致看似按了 A 但相机不动
		# 注意: 这里只在按 A 时 release, 其他时候保留焦点不影响 SpinBox 编辑
		if focus_owner != null and not (focus_owner is LineEdit):
			# 调试打印 (一次性 throttle), 让用户/我能看到是不是焦点抢走了 A
			if not _logged_a_focus:
				print("[TrackEditor] A键按下, 焦点在: %s (类型 %s), 已 release" % [focus_owner.name, focus_owner.get_class()])
				_logged_a_focus = true
			focus_owner.release_focus()
		move.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		# 同样的焦点抢救处理 (D 也会被 Button 当导航键)
		if focus_owner != null and not (focus_owner is LineEdit):
			focus_owner.release_focus()
		move.x += 1.0
	# Q/E 键: 相机焦点上下移动 (深入底部/升高)
	if Input.is_key_pressed(KEY_Q):
		move.y -= 1.0
	if Input.is_key_pressed(KEY_E):
		move.y += 1.0
	if move.length_squared() > 0.0:
		# 长按加速: 累计按住时间, 超过延迟后逐渐提速
		_cam_move_hold_time += delta
		var speed: float = CAM_MOVE_SPEED
		if _cam_move_hold_time > CAM_ACCEL_DELAY:
			var accel_time: float = _cam_move_hold_time - CAM_ACCEL_DELAY
			speed = minf(CAM_MOVE_SPEED + accel_time * CAM_ACCEL_RAMP * CAM_MOVE_SPEED, CAM_MOVE_SPEED_MAX)
		var speed_scaled: float = speed * delta
		# 分离水平和垂直移动: 水平 (XZ) 相对相机朝向, 垂直 (Y) 用世界坐标
		var vert: float = move.y
		var horiz := Vector3(move.x, 0.0, move.z)
		if horiz.length_squared() > 0.0:
			horiz = horiz.normalized()
		var yaw_basis := Basis(Vector3.UP, _cam_yaw)
		_cam_focus += yaw_basis * horiz * speed_scaled
		_cam_focus.y += vert * speed_scaled
		_update_camera_transform()
	else:
		# 松开按键, 重置累计时间
		_cam_move_hold_time = 0.0


func _update_camera_transform() -> void:
	# 球面相机: 焦点 _cam_focus, yaw + pitch + 距离 _cam_distance
	var basis := Basis(Vector3.UP, _cam_yaw) * Basis(Vector3.RIGHT, _cam_pitch)
	var offset: Vector3 = basis * Vector3(0.0, 0.0, _cam_distance)
	_cam.global_position = _cam_focus + offset
	_cam.look_at(_cam_focus, Vector3.UP)


# ============================================================
#  放置/删除/撤销
# ============================================================
func _place_at_mouse() -> void:
	# PRESET 模式: 把 _preset_preview_nodes 的当前 transform 一组都实例化下来
	if _current_tool == Tool.PRESET:
		if _preset_preview_nodes.is_empty():
			return
		if _current_preset_index < 0 or _current_preset_index >= _block_presets.size():
			return
		var preset: Dictionary = _block_presets[_current_preset_index]
		var items: Array = preset.get("items", [])
		var added_indices: Array = []
		for i in range(_preset_preview_nodes.size()):
			var pv: Node3D = _preset_preview_nodes[i]
			if pv == null or i >= items.size():
				continue
			var bid: String = String(items[i].get("id", ""))
			var bpath: String = BLOCK_LIBRARY.get(bid, "")
			if bpath == "":
				continue
			var bpk: PackedScene = load(bpath)
			if bpk == null:
				continue
			var n: Node3D = bpk.instantiate()
			_placed_root.add_child(n)
			n.global_transform = pv.global_transform
			# 应用预设里保存的积木参数 (length / entry_width 等)
			var iparams: Dictionary = items[i].get("params", {})
			_apply_block_params(n, iparams)
			_placed_blocks.append({"id": bid, "node": n, "kind": "block"})
			added_indices.append(_placed_blocks.size() - 1)
		# Undo: 整组放预设算一个操作
		if not added_indices.is_empty():
			_undo_push({"op": "add_many", "indices": added_indices})
		_update_status()
		return
	# SPAWN 模式: 把出生点 marker 搬到鼠标位置 (出生点全场只一个, 不会"放置多次")
	if _current_tool == Tool.SPAWN:
		var sp: Vector3 = _get_mouse_world_point()
		if sp == Vector3.ZERO:
			return
		# C 键吸附: 出生点也能吸附到道路表面
		if Input.is_key_pressed(KEY_C):
			var snap_result: Dictionary = _raycast_surface_at_mouse()
			if not snap_result.is_empty():
				sp = snap_result["position"] + Vector3.UP * 0.05
		elif _grid_snap_enabled and Input.is_key_pressed(KEY_ALT):
			sp = _snap_to_grid(sp)
		# 微抬 0.5m 让车不会嵌入路面
		sp.y += 0.5
		var old_pos: Vector3 = _spawn_position
		var old_yaw: float = _spawn_yaw
		_spawn_position = sp
		_spawn_yaw = deg_to_rad(_place_yaw_deg)
		if _spawn_marker:
			_spawn_marker.position = _spawn_position
			_spawn_marker.rotation.y = _spawn_yaw
		# 同步到 _placed_blocks 里那条 spawn 记录 (如果有, _build_spawn_marker 时就 append 进去了)
		_sync_spawn_to_placed()
		_undo_push({"op": "spawn_move", "old_pos": old_pos, "old_yaw": old_yaw, "new_pos": _spawn_position, "new_yaw": _spawn_yaw})
		_update_status()
		return
	if _preview_node == null:
		return
	if _current_tool == Tool.BLOCK:
		# 实例化一个新的, 不是直接用 preview (preview 还要继续跟着鼠标)
		var path: String = BLOCK_LIBRARY.get(_selected_block_id, "")
		var packed: PackedScene = load(path)
		if packed == null:
			return
		var node: Node3D = packed.instantiate()
		_placed_root.add_child(node)
		# 用 preview 的当前 transform 作为放置位置
		node.global_transform = _preview_node.global_transform
		# 窄道吸附: preview 已在正确位置+朝向 (在 _process 的预览跟随中计算好了)
		# node.global_transform = _preview_node.global_transform 已经包含了吸附位置和朝向
		# 应用 Tuner 机关默认值 (用户需求 2026-06-03: 机关 Tab 配置所有默认参数)
		# 优先找 Tuner 节点 (如果存在); 否则直接从 cfg 文件读
		var tuner_node: Node = get_tree().current_scene.find_child("Tuner", true, false)
		if tuner_node and tuner_node.has_method("apply_mechanism_defaults"):
			tuner_node.call("apply_mechanism_defaults", node, _selected_block_id)
		else:
			_apply_mechanism_defaults_from_cfg(node, _selected_block_id)
		# kind: speed_pad 是机关, 其他都是路段积木 (速度带也能选中拖拽参数, 但序列化时按 kind 区分)
		var kind: String = "speed_pad" if _selected_block_id == "speed_pad" else "block"
		_placed_blocks.append({"id": _selected_block_id, "node": node, "kind": kind})
		_undo_push({"op": "add", "index": _placed_blocks.size() - 1})
		# 第一块路段积木: 自动设置出生点在它的入口前方 5m (车朝积木方向开)
		# 加速带不算 "第一块路段", 跳过自动出生点逻辑
		if kind == "block" and _count_blocks_of_kind("block") == 1 and node.has_method("get_entry_world_transform"):
			var entry_xform: Transform3D = node.call("get_entry_world_transform")
			# 出生点 = entry 位置 + 朝 +Z 方向 5m (因为车要朝 -Z 进入)
			# entry basis -Z 是车前进方向, 所以出生点应该在 entry 的 +Z 那侧
			_spawn_position = entry_xform.origin + entry_xform.basis.z * 5.0 + Vector3.UP * 1.0
			# 出生 yaw: 让车 -Z 朝 entry.basis 的 -Z, 即车 yaw = entry yaw
			# 用 atan2 从 basis 里抽出 Y 旋转
			var fwd: Vector3 = -entry_xform.basis.z
			_spawn_yaw = atan2(fwd.x, fwd.z)
			if _spawn_marker:
				_spawn_marker.position = _spawn_position
				_spawn_marker.rotation.y = _spawn_yaw
			_sync_spawn_to_placed()
		_update_status()
	else:
		# 锚点
		var pos: Vector3 = _preview_node.global_position
		var anchor_node: Node3D = _create_anchor_visual(pos, 1.5, 25.0, Color(0.3, 0.85, 1.0))
		_placed_root.add_child(anchor_node)
		# 锚点统一进 _placed_blocks (kind="anchor"), 这样选中/拖拽/Undo 都自动可用
		# 锚点参数 (anchor_radius / detect_radius / color) 存到 node 上 (用 set_meta), 序列化时再读出
		anchor_node.set_meta("anchor_radius", 1.5)
		anchor_node.set_meta("detect_radius", 60.0)
		anchor_node.set_meta("anchor_color", Color(0.3, 0.85, 1.0))
		_placed_blocks.append({"id": "anchor", "node": anchor_node, "kind": "anchor"})
		_undo_push({"op": "add", "index": _placed_blocks.size() - 1})
		_update_status()


# 统计 _placed_blocks 中 kind == 指定值 的条数
# 用于"第一块路段自动设出生点"判定 (排除加速带/锚点/出生点)
func _count_blocks_of_kind(target_kind: String) -> int:
	var n: int = 0
	for d in _placed_blocks:
		if String(d.get("kind", "block")) == target_kind:
			n += 1
	return n


# 把当前 _spawn_position / _spawn_yaw 同步到 _placed_blocks 里那条 spawn 记录
# (因为 spawn marker 也接入了选中/拖拽体系, 需要让它的 transform 跟主状态一致)
func _sync_spawn_to_placed() -> void:
	if _spawn_marker == null:
		return
	_spawn_marker.position = _spawn_position
	_spawn_marker.rotation.y = _spawn_yaw
	# 找 _placed_blocks 里 kind=="spawn" 的那条, 更新 transform
	for d in _placed_blocks:
		if String(d.get("kind", "")) == "spawn":
			var n: Node3D = d.get("node")
			if n != null:
				n.position = _spawn_position
				n.rotation.y = _spawn_yaw
			return


# 反过来: 玩家拖拽 spawn marker 后, 把 marker.transform 同步回 _spawn_position/_yaw
# 在拖拽结束 / 选中改坐标 SpinBox 时调用
func _sync_spawn_from_placed() -> void:
	if _spawn_marker == null:
		return
	_spawn_position = _spawn_marker.position
	_spawn_yaw = _spawn_marker.rotation.y


# 创建一个锚点视觉节点 (球) + StaticBody3D 让能被鼠标 raycast 选中
func _create_anchor_visual(pos: Vector3, anchor_r: float, _detect_r: float, col: Color) -> Node3D:
	var node := Node3D.new()
	node.position = pos
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = anchor_r
	sphere.height = anchor_r * 2.0
	mi.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 1.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	node.add_child(mi)
	# 加 StaticBody3D + SphereShape 让 raycast 能命中 (使它能被选中/hover)
	# 注意: 用一个稍大的"选中盒" (1.5 倍视觉半径) 让玩家更容易点中小锚点
	var body := StaticBody3D.new()
	# 编辑器内的锚点不参与运行时碰撞 (只用于鼠标 raycast 选中), 所以 layer/mask 都设到独立通道
	# 但用默认值 1 即可, 因为 _pick_placed_block_at_mouse 用的是 direct_space_state.intersect_ray, 不挑 layer
	var col_shape := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = anchor_r * 1.5
	col_shape.shape = sh
	body.add_child(col_shape)
	node.add_child(body)
	return node


# ============================================================
#  Undo / Redo 栈 (Ctrl+Z / Ctrl+Y)
# ============================================================
# 用户要求: 编辑器内所有操作都可以 Ctrl+Z 撤回, Ctrl+Y 重做
# 操作类型 (op):
#   "add"        : 添加单个 _placed_blocks 项. data: {index}
#   "add_many"   : 添加一组 _placed_blocks 项 (放预设). data: {indices: Array[int]}
#   "delete"     : 删除一组 _placed_blocks 项. data: {snapshots: Array[{kind, id, xform, params, anchor_meta, list_index}]}
#   "move"       : 拖动 / 改坐标 SpinBox. data: {indices: Array[int], old_positions: Array[V3], new_positions: Array[V3]}
#   "rotate"     : R 键旋转 90° 一组. data: {indices: Array[int], old_xforms, new_xforms}
#   "param"      : 改可编辑参数. data: {index, key, old_value, new_value}
#   "spawn_move" : 移动出生点. data: {old_pos, old_yaw, new_pos, new_yaw}
#
# 栈策略:
#   _undo_stack: 普通 Array, push 末尾, pop 末尾 = 撤销
#   _redo_stack: 撤销时把 op push 进来, 重做时再 pop 出来 apply
#   每次新操作 (_undo_push) 清空 redo_stack (经典分支砍断)
#   栈大小上限 200 (防止内存爆炸)
const UNDO_STACK_LIMIT: int = 200
var _undo_stack: Array = []
var _redo_stack: Array = []
# undo 时是否保持选中: param / range 等"原地修改"型操作设 true,
# add / delete / move 等会改变 _placed_blocks 数组结构的设 false
var _undo_keep_selection: bool = false

# ---- 复制粘贴 (2026-06-03) ----
# 剪贴板: 保存选中积木的 id + 参数 + 相对位置 (相对第一个积木)
# 结构: Array[Dictionary] 每项 {"id", "rel_xform": Transform3D, "params": {key: value}}
# _clipboard_base_basis: 第一个积木的旋转 (粘贴时用它恢复整组的绝对朝向)
# 粘贴时进入预览模式 (跟预设放置一样, 跟随鼠标, 点击放下)
var _clipboard: Array = []
var _clipboard_base_basis: Basis = Basis()
# 粘贴预览节点列表 (跟鼠标走, 点击确认放置, ESC/右键取消)
var _paste_preview_nodes: Array = []
var _paste_mode: bool = false


func _undo_push(op_data: Dictionary) -> void:
	_undo_stack.append(op_data)
	if _undo_stack.size() > UNDO_STACK_LIMIT:
		_undo_stack.pop_front()
	_redo_stack.clear()   # 新操作砍断重做分支


# 加入"连续修改"的 pending undo (合并模式, 防止爆栈)
# kind: "param" / "color" / "range" — 不同 kind 之间不合并 (即使 idx/key 相同)
# old_v_if_new: 只有第一次 (创建 pending) 时使用; 后续合并修改时忽略 (保持原始 old_value)
# new_v: 每次合并都更新成最新值
# extra: 可选额外 dict (例: range op 携带 old_min/max/step + new_min/max/step)
func _queue_pending_undo(kind: String, idx: int, key: String, old_v: float, new_v: float, extra: Dictionary = {}) -> void:
	# 如果 pending 已经存在, 但 kind/idx/key 不同 → 先 flush 旧的, 再开新的
	if not _pending_undo.is_empty():
		var same_target: bool = (
			String(_pending_undo.get("op", "")) == kind
			and int(_pending_undo.get("index", -2)) == idx
			and String(_pending_undo.get("key", "")) == key
		)
		if not same_target:
			_flush_pending_undo()
		else:
			# 同一个目标的连续修改 → 只更新 new_value + 重置 timer
			_pending_undo["new_value"] = new_v
			_pending_undo["timer"] = PARAM_UNDO_FLUSH_DELAY
			# 范围修改的话 extra 里也合并最新 new_min/max/step
			for k in extra.keys():
				if String(k).begins_with("new_"):
					_pending_undo[k] = extra[k]
			return
	# 新 pending: 记录 old_v 作为"这一段连续修改的起点"
	var entry: Dictionary = {
		"op": kind,
		"index": idx,
		"key": key,
		"old_value": old_v,
		"new_value": new_v,
		"timer": PARAM_UNDO_FLUSH_DELAY,
	}
	for k in extra.keys():
		entry[k] = extra[k]
	_pending_undo = entry


# 立刻把 pending undo push 到 _undo_stack (在 Ctrl+Z / 切换选中 / 切换工具前调用)
# 用户没改完就按 Ctrl+Z 也能撤销最近的修改, 不会"丢失最后 0.4s 内的改动"
func _flush_pending_undo() -> void:
	if _pending_undo.is_empty():
		return
	var entry: Dictionary = _pending_undo
	_pending_undo = {}
	# 只在 old_value != new_value 时才入栈 (单纯点击 SpinBox 不算编辑)
	# range op 单独判断 (extra 字段)
	var op_kind: String = String(entry.get("op", ""))
	var changed: bool = false
	if op_kind == "range":
		# 范围编辑: old_min/max/step 任一变 = 算改了
		changed = (
			float(entry.get("old_min", 0.0)) != float(entry.get("new_min", 0.0))
			or float(entry.get("old_max", 0.0)) != float(entry.get("new_max", 0.0))
			or float(entry.get("old_step", 0.0)) != float(entry.get("new_step", 0.0))
		)
	else:
		changed = absf(float(entry.get("old_value", 0.0)) - float(entry.get("new_value", 0.0))) > 0.000001
	if changed:
		_undo_stack.append(entry)
		if _undo_stack.size() > UNDO_STACK_LIMIT:
			_undo_stack.pop_front()
		_redo_stack.clear()


# 从 _placed_blocks 索引数组拿"快照" (用于 delete 操作的 undo, 删除前先存)
# snapshot 包含: kind / id / xform / params (积木) / anchor_meta (锚点) / list_index
func _make_block_snapshots(indices: Array) -> Array:
	var out: Array = []
	# 从大到小排序, 这样 delete 时不影响 list_index
	var sorted_indices: Array = indices.duplicate()
	sorted_indices.sort()
	for i in sorted_indices:
		var idx: int = int(i)
		if idx < 0 or idx >= _placed_blocks.size():
			continue
		var d: Dictionary = _placed_blocks[idx]
		var node: Node3D = d.get("node")
		if node == null:
			continue
		var snap: Dictionary = {
			"kind": String(d.get("kind", "block")),
			"id": String(d.get("id", "")),
			"xform": node.global_transform,
			"list_index": idx,
		}
		# 积木 / 加速带都存 params (它们都实现 get_editable_params)
		if node.has_method("get_editable_params"):
			snap["params"] = _collect_block_params(node)
		# 锚点存它的 meta (anchor_radius / detect_radius / anchor_color)
		if String(d.get("kind", "")) == "anchor":
			snap["anchor_meta"] = {
				"anchor_radius": node.get_meta("anchor_radius", 1.5),
"detect_radius": node.get_meta("detect_radius", 60.0),
				"anchor_color":  node.get_meta("anchor_color", Color(0.3, 0.85, 1.0)),
			}
		out.append(snap)
	return out


# 根据 snapshot 数组重新创建被删除的项, 还原到原 list_index 位置
func _restore_from_snapshots(snapshots: Array) -> Array:
	var restored_indices: Array = []
	# 按 list_index 从小到大插入, 这样能正确还原原来的顺序
	var sorted_snaps: Array = snapshots.duplicate()
	sorted_snaps.sort_custom(func(a, b): return int(a.get("list_index", 0)) < int(b.get("list_index", 0)))
	for snap in sorted_snaps:
		var s: Dictionary = snap
		var kind: String = String(s.get("kind", "block"))
		var node: Node3D = null
		if kind == "anchor":
			var meta: Dictionary = s.get("anchor_meta", {})
			node = _create_anchor_visual(Vector3.ZERO, float(meta.get("anchor_radius", 1.5)),
				float(meta.get("detect_radius", 60.0)), meta.get("anchor_color", Color(0.3, 0.85, 1.0)))
			node.set_meta("anchor_radius", meta.get("anchor_radius", 1.5))
			node.set_meta("detect_radius", meta.get("detect_radius", 60.0))
			node.set_meta("anchor_color", meta.get("anchor_color", Color(0.3, 0.85, 1.0)))
		elif kind == "spawn":
			# 出生点不应该出现在 delete snapshot 里 (它不能被删, 只能移动)
			continue
		else:
			# block / speed_pad
			var bpath: String = BLOCK_LIBRARY.get(s.get("id", ""), "")
			if bpath == "":
				continue
			var packed: PackedScene = load(bpath)
			if packed == null:
				continue
			node = packed.instantiate()
			# 应用参数
			var p: Dictionary = s.get("params", {})
			if not p.is_empty():
				_apply_block_params(node, p)
		_placed_root.add_child(node)
		node.global_transform = s.get("xform", Transform3D.IDENTITY)
		# 插入到原 list_index (如果越界就 append)
		var li: int = int(s.get("list_index", _placed_blocks.size()))
		var entry: Dictionary = {"id": s.get("id", ""), "node": node, "kind": kind}
		if li >= _placed_blocks.size():
			_placed_blocks.append(entry)
			restored_indices.append(_placed_blocks.size() - 1)
		else:
			_placed_blocks.insert(li, entry)
			restored_indices.append(li)
	return restored_indices


func _undo_last() -> void:
	# 先把还没入栈的连续修改 (拖拽 SpinBox 等) flush 掉
	# 这样用户拖完立刻按 Ctrl+Z 也能撤销最近的改动
	_flush_pending_undo()
	if _undo_stack.is_empty():
		print("[TrackEditor] Undo: 栈空")
		return
	var op: Dictionary = _undo_stack.pop_back()
	_apply_undo(op)
	# 撤销后这个 op 入 redo 栈, 给 Ctrl+Y 用
	_redo_stack.append(op)
	if _redo_stack.size() > UNDO_STACK_LIMIT:
		_redo_stack.pop_front()
	_update_status()


func _redo_last() -> void:
	_flush_pending_undo()   # 同样防止丢失最近修改
	if _redo_stack.is_empty():
		print("[TrackEditor] Redo: 栈空")
		return
	var op: Dictionary = _redo_stack.pop_back()
	_apply_redo(op)
	# 重做后再入 undo 栈
	_undo_stack.append(op)
	if _undo_stack.size() > UNDO_STACK_LIMIT:
		_undo_stack.pop_front()
	_update_status()


# 撤销一个操作 (反方向应用)
# 一些 op (param/range) 不希望清掉选中, 让 SpinBox 即时刷新成新值
# 通过 _undo_keep_selection 标记: 子分支里设 true, 末尾的清选就跳过
func _apply_undo(op: Dictionary) -> void:
	_undo_keep_selection = false
	var op_name: String = String(op.get("op", ""))
	match op_name:
		"add":
			# 撤销添加 = 删除该项, 把删前的 snapshot 存到 op 里供 redo 用
			var idx: int = int(op.get("index", -1))
			if idx >= 0 and idx < _placed_blocks.size():
				op["snapshot"] = _make_block_snapshots([idx])
				_remove_block_silent(idx)
		"add_many":
			var indices: Array = op.get("indices", [])
			op["snapshots"] = _make_block_snapshots(indices)
			# 从大到小删, 避免索引重排
			var sorted_idx: Array = indices.duplicate()
			sorted_idx.sort()
			sorted_idx.reverse()
			for i in sorted_idx:
				_remove_block_silent(int(i))
		"delete":
			# 撤销删除 = 还原 snapshot
			var snaps: Array = op.get("snapshots", [])
			_restore_from_snapshots(snaps)
		"move":
			# 撤销移动 = 应用 old_positions
			var indices: Array = op.get("indices", [])
			var old_pos: Array = op.get("old_positions", [])
			for i in range(indices.size()):
				var idx: int = int(indices[i])
				if idx >= 0 and idx < _placed_blocks.size() and i < old_pos.size():
					var n: Node3D = _placed_blocks[idx].get("node")
					if n != null:
						n.global_position = old_pos[i]
			_sync_spawn_from_placed_if_needed(indices)
		"rotate":
			var indices: Array = op.get("indices", [])
			var old_xforms: Array = op.get("old_xforms", [])
			for i in range(indices.size()):
				var idx: int = int(indices[i])
				if idx >= 0 and idx < _placed_blocks.size() and i < old_xforms.size():
					var n: Node3D = _placed_blocks[idx].get("node")
					if n != null:
						n.global_transform = old_xforms[i]
			_sync_spawn_from_placed_if_needed(indices)
		"param":
			var idx: int = int(op.get("index", -1))
			var key: String = String(op.get("key", ""))
			var old_v: float = float(op.get("old_value", 0.0))
			if idx >= 0 and idx < _placed_blocks.size():
				var n: Node3D = _placed_blocks[idx].get("node")
				if n != null and n.has_method("set_editable_param"):
					n.call("set_editable_param", key, old_v)
			# 保持原选中, 刷新参数 UI 让 SpinBox 显示新值 (撤销后的值)
			# (默认末尾会 _select_block(-1) 清掉, 我们标记不清)
			_undo_keep_selection = true
		"range":
			# 范围编辑 undo: 还原 _param_range_overrides + 重建参数面板让 SpinBox 范围回到旧值
			var idx: int = int(op.get("index", -1))
			var key: String = String(op.get("key", ""))
			var range_key: String = ""
			if idx >= 0 and idx < _placed_blocks.size():
				range_key = String(_placed_blocks[idx].get("id", "")) + ":" + key
			var old_min: float = float(op.get("old_min", 0.0))
			var old_max: float = float(op.get("old_max", 1.0))
			var old_step: float = float(op.get("old_step", 0.1))
			var had_override: bool = bool(op.get("had_override", false))
			if had_override:
				_param_range_overrides[range_key] = {"min": old_min, "max": old_max, "step": old_step}
			else:
				# 之前没有 override (即用默认), 撤销 = 删掉这条 override
				_param_range_overrides.erase(range_key)
			_save_editor_settings()
			_undo_keep_selection = true
		"spawn_move":
			_spawn_position = op.get("old_pos", Vector3.ZERO)
			_spawn_yaw = float(op.get("old_yaw", 0.0))
			_sync_spawn_to_placed()
		"param_change":
			# 手柄拖拽整体参数变化: 恢复 before 快照
			var idx2: int = int(op.get("index", -1))
			if idx2 >= 0 and idx2 < _placed_blocks.size():
				var n2: Node3D = _placed_blocks[idx2].get("node")
				if n2 != null:
					_apply_block_params(n2, op.get("before", {}))
			_undo_keep_selection = true
	# 撤销可能影响选中, 默认清掉. 但 param / range op 例外: 保持选中并刷新参数面板
	# 让 SpinBox 立刻显示撤销后的值 (用户视觉反馈"我的撤销生效了")
	if _undo_keep_selection and _selected_block_index >= 0 and _selected_block_index < _placed_blocks.size():
		var sel_n: Node3D = _placed_blocks[_selected_block_index].get("node")
		_rebuild_sel_param_rows(sel_n)
		_sync_sel_spinbox_from_node()
	else:
		_select_block(-1)
		_refresh_selection_ui()


# 重做一个操作 (正方向再次应用)
func _apply_redo(op: Dictionary) -> void:
	_undo_keep_selection = false
	var op_name: String = String(op.get("op", ""))
	match op_name:
		"add":
			# 重做添加 = 从 snapshot 还原
			var snaps: Array = op.get("snapshot", [])
			var new_idx: Array = _restore_from_snapshots(snaps)
			if not new_idx.is_empty():
				op["index"] = new_idx[0]
		"add_many":
			var snaps: Array = op.get("snapshots", [])
			var new_idx: Array = _restore_from_snapshots(snaps)
			op["indices"] = new_idx
		"delete":
			# 重做删除
			var snaps: Array = op.get("snapshots", [])
			var to_delete: Array = []
			for s in snaps:
				to_delete.append(int(s.get("list_index", -1)))
			to_delete.sort()
			to_delete.reverse()
			for i in to_delete:
				_remove_block_silent(int(i))
		"move":
			var indices: Array = op.get("indices", [])
			var new_pos: Array = op.get("new_positions", [])
			for i in range(indices.size()):
				var idx: int = int(indices[i])
				if idx >= 0 and idx < _placed_blocks.size() and i < new_pos.size():
					var n: Node3D = _placed_blocks[idx].get("node")
					if n != null:
						n.global_position = new_pos[i]
			_sync_spawn_from_placed_if_needed(indices)
		"rotate":
			var indices: Array = op.get("indices", [])
			var new_xforms: Array = op.get("new_xforms", [])
			for i in range(indices.size()):
				var idx: int = int(indices[i])
				if idx >= 0 and idx < _placed_blocks.size() and i < new_xforms.size():
					var n: Node3D = _placed_blocks[idx].get("node")
					if n != null:
						n.global_transform = new_xforms[i]
			_sync_spawn_from_placed_if_needed(indices)
		"param":
			var idx: int = int(op.get("index", -1))
			var key: String = String(op.get("key", ""))
			var new_v: float = float(op.get("new_value", 0.0))
			if idx >= 0 and idx < _placed_blocks.size():
				var n: Node3D = _placed_blocks[idx].get("node")
				if n != null and n.has_method("set_editable_param"):
					n.call("set_editable_param", key, new_v)
			_undo_keep_selection = true
		"range":
			# 重做范围编辑: 应用 new_min/max/step
			var idx: int = int(op.get("index", -1))
			var key: String = String(op.get("key", ""))
			var range_key: String = ""
			if idx >= 0 and idx < _placed_blocks.size():
				range_key = String(_placed_blocks[idx].get("id", "")) + ":" + key
			var new_min: float = float(op.get("new_min", 0.0))
			var new_max: float = float(op.get("new_max", 1.0))
			var new_step: float = float(op.get("new_step", 0.1))
			_param_range_overrides[range_key] = {"min": new_min, "max": new_max, "step": new_step}
			_save_editor_settings()
			_undo_keep_selection = true
		"spawn_move":
			_spawn_position = op.get("new_pos", Vector3.ZERO)
			_spawn_yaw = float(op.get("new_yaw", 0.0))
			_sync_spawn_to_placed()
		"param_change":
			# 重做手柄拖拽: 应用 after 快照
			var idx2: int = int(op.get("index", -1))
			if idx2 >= 0 and idx2 < _placed_blocks.size():
				var n2: Node3D = _placed_blocks[idx2].get("node")
				if n2 != null:
					_apply_block_params(n2, op.get("after", {}))
			_undo_keep_selection = true
	if _undo_keep_selection and _selected_block_index >= 0 and _selected_block_index < _placed_blocks.size():
		var sel_n: Node3D = _placed_blocks[_selected_block_index].get("node")
		_rebuild_sel_param_rows(sel_n)
		_sync_sel_spinbox_from_node()
	else:
		_select_block(-1)
		_refresh_selection_ui()


# 移动 / 旋转操作影响到 spawn marker 时, 把 marker.transform 同步回 _spawn_position/_yaw
# 因为 spawn marker 也接入了选中体系, 玩家可能"选中 spawn 一起拖动"
func _sync_spawn_from_placed_if_needed(indices: Array) -> void:
	for i in indices:
		var idx: int = int(i)
		if idx >= 0 and idx < _placed_blocks.size():
			if String(_placed_blocks[idx].get("kind", "")) == "spawn":
				_sync_spawn_from_placed()
				return


# 安静地从 _placed_blocks 移除一项 (queue_free 节点 + 数组 remove_at, 不更新 status / 不弹 undo)
# 出生点 (kind="spawn") 不能被删除, 直接跳过
func _remove_block_silent(idx: int) -> void:
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var d: Dictionary = _placed_blocks[idx]
	if String(d.get("kind", "")) == "spawn":
		# 出生点不允许 silent 删除, 它必须始终存在
		return
	var n: Node3D = d.get("node")
	if n != null:
		n.queue_free()
	_placed_blocks.remove_at(idx)


func _delete_under_cursor() -> void:
	# 优先: 如果有选中的积木, 直接删它们 (单选/多选都支持)
	# 多选时一次删多块 — 注意从大到小删, 避免数组重排导致索引失效
	# 用户要求: 出生点不能被删除 (它必须始终存在)
	if not _selected_block_indices.is_empty():
		# 先过滤掉 spawn (不能删)
		var deletable: Array = []
		for idx in _selected_block_indices:
			var i: int = int(idx)
			if i >= 0 and i < _placed_blocks.size():
				if String(_placed_blocks[i].get("kind", "")) != "spawn":
					deletable.append(i)
		if deletable.is_empty():
			print("[TrackEditor] 选中的全是出生点, 出生点不允许删除")
			return
		# Undo: 先存快照
		var snapshots: Array = _make_block_snapshots(deletable)
		_undo_push({"op": "delete", "snapshots": snapshots})
		# 从大到小删
		var sorted_idx: Array = deletable.duplicate()
		sorted_idx.sort()
		sorted_idx.reverse()
		for i in sorted_idx:
			_remove_block_silent(int(i))
		_select_block(-1)
		_update_status()
		return
	# 兜底: 鼠标地面位置最近的积木 (8m 内)
	var p: Vector3 = _get_mouse_world_point()
	if p == Vector3.ZERO:
		return
	var best_idx: int = -1
	var best_dist: float = 999999.0
	for i in range(_placed_blocks.size()):
		var d: Dictionary = _placed_blocks[i]
		# 出生点不能在兜底删除流程里被命中 (玩家想删的是积木/锚点/加速带)
		if String(d.get("kind", "")) == "spawn":
			continue
		var n: Node3D = d.get("node")
		if n == null:
			continue
		var dist: float = n.global_position.distance_to(p)
		if dist < best_dist and dist < 8.0:
			best_dist = dist
			best_idx = i
	if best_idx >= 0:
		var snaps: Array = _make_block_snapshots([best_idx])
		_undo_push({"op": "delete", "snapshots": snaps})
		_remove_block_silent(best_idx)
	_update_status()


# ============================================================
#  保存 / 加载 / 测试
# ============================================================
func _on_save_overwrite_pressed() -> void:
	# "保存" 按钮: 覆盖当前打开的赛道文件
	# 如果没有当前文件 (新建赛道) → 等同"另存为" (弹出名字对话框)
	if _current_track_path.is_empty() or _current_track_path.ends_with("_test.tres"):
		_on_save_pressed()
		return
	# 从路径提取名字 (去掉目录 + 扩展名)
	var track_name: String = _current_track_path.get_file().get_basename()
	var data: Resource = _build_track_data(track_name)
	var saved_path: String = RaceTrackDataScript.save_to_user(data, track_name)
	if saved_path != "":
		_current_track_path = saved_path
		print("[TrackEditor] 已覆盖保存: ", saved_path)


func _on_save_pressed() -> void:
	# "另存为" 按钮: 弹出输入名字对话框
	var dlg := AcceptDialog.new()
	dlg.title = "保存赛道"
	dlg.dialog_hide_on_ok = true
	var vb := VBoxContainer.new()
	dlg.add_child(vb)
	var lbl := Label.new(); lbl.text = "请输入赛道名 (会保存到 user://tracks/<名字>.tres)"; vb.add_child(lbl)
	var le := LineEdit.new()
	# 注意: get_unix_time_from_system() 返回 float, 必须先 int() 才能用 % 取模
	le.text = "MyTrack_%d" % (int(Time.get_unix_time_from_system()) % 100000)
	le.custom_minimum_size = Vector2(300, 30)
	vb.add_child(le)
	dlg.confirmed.connect(func() -> void:
		var data: Resource = _build_track_data(le.text)
		var saved_path: String = RaceTrackDataScript.save_to_user(data, le.text)
		if saved_path != "":
			_current_track_path = saved_path
			print("[TrackEditor] 已另存为: ", saved_path)
	)
	add_child(dlg)
	dlg.popup_centered()


func _on_load_pressed() -> void:
	var paths: Array = RaceTrackDataScript.list_user_tracks()
	var dlg := AcceptDialog.new()
	dlg.title = "加载赛道"
	dlg.dialog_hide_on_ok = false   # 用列表点击直接加载
	var vb := VBoxContainer.new()
	dlg.add_child(vb)
	var lbl := Label.new(); lbl.text = "选择一个赛道:"; vb.add_child(lbl)
	if paths.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "(还没保存过赛道)"
		empty_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		vb.add_child(empty_lbl)
	for p in paths:
		var btn := Button.new()
		btn.text = String(p).get_file()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(380, 32)
		var path_capture: String = String(p)
		btn.pressed.connect(func() -> void:
			_load_track_data(path_capture)
			dlg.queue_free()
		)
		vb.add_child(btn)
	add_child(dlg)
	dlg.popup_centered_ratio(0.5)


# 删除已保存的赛道文件 (从 user://tracks/ 删 .tres)
# 用户要求: 列出所有保存的赛道, 点击一个 → 二次确认 → 物理删除
# 安全: 删除当前正在编辑的 track 不会清空内存里的内容 (那需要点"清空"按钮)
func _on_delete_track_pressed() -> void:
	var paths: Array = RaceTrackDataScript.list_user_tracks()
	var dlg := AcceptDialog.new()
	dlg.title = "删除已保存赛道"
	dlg.dialog_hide_on_ok = false
	var vb := VBoxContainer.new()
	dlg.add_child(vb)
	var lbl := Label.new()
	lbl.text = "点击要删除的赛道 (会有二次确认):"
	lbl.add_theme_color_override("font_color", Color(1.0, 0.7, 0.5))
	vb.add_child(lbl)
	if paths.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "(还没保存过赛道)"
		empty_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		vb.add_child(empty_lbl)
	for p in paths:
		var btn := Button.new()
		btn.text = "❌ " + String(p).get_file()
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.custom_minimum_size = Vector2(380, 32)
		btn.add_theme_color_override("font_color", Color(1.0, 0.5, 0.5))
		var path_capture: String = String(p)
		btn.pressed.connect(func() -> void:
			_confirm_delete_track(path_capture, dlg)
		)
		vb.add_child(btn)
	add_child(dlg)
	dlg.popup_centered_ratio(0.5)


# 二次确认 + 实际删除
func _confirm_delete_track(path: String, parent_dlg: AcceptDialog) -> void:
	var confirm := ConfirmationDialog.new()
	confirm.title = "确认删除"
	confirm.dialog_text = "确定要删除赛道文件吗？\n\n%s\n\n此操作不可撤销 (但内存里的赛道不受影响)" % path.get_file()
	confirm.confirmed.connect(func() -> void:
		# DirAccess.remove_absolute 走全局路径; ResourceLoader 路径要用 globalize
		var abs_path: String = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
		var err: int = DirAccess.remove_absolute(abs_path)
		if err == OK:
			print("[TrackEditor] 已删除赛道: ", path)
		else:
			push_warning("[TrackEditor] 删除赛道失败 err=%d 路径=%s" % [err, abs_path])
		# 关掉父对话框, 重新打开新的让列表刷新
		if parent_dlg:
			parent_dlg.queue_free()
	)
	add_child(confirm)
	confirm.popup_centered()


func _on_test_pressed() -> void:
	# 把当前编辑器内容写入 user://tracks/_test.tres, 然后切换到 track_runner 场景
	# 同时把 _test.tres 路径写到 TrackRunnerState.last_editor_track_path,
	# 这样玩家从 TrackRunner 按 ESC 返回编辑器时会自动加载 _test.tres, 不丢失刚才的赛道
	var data: Resource = _build_track_data("_test")
	var saved_path: String = RaceTrackDataScript.save_to_user(data, "_test")
	if saved_path != "":
		var st: Node = get_node_or_null("/root/TrackRunnerState")
		if st:
			st.set("last_editor_track_path", saved_path)
			st.set("track_to_load", saved_path)
			# 保存当前正式赛道路径, 回来后恢复 (避免 _test.tres 覆盖正式路径导致"保存"变"另存为")
			st.set("original_track_path", _current_track_path)
	# 切换到 runner 场景
	get_tree().change_scene_to_file("res://track_editor/TrackRunner.tscn")


func _on_clear_pressed() -> void:
	# 二次确认避免误触
	var dlg := ConfirmationDialog.new()
	dlg.title = "确认清空"
	dlg.dialog_text = "清空所有积木和机关? (出生点保留, 此操作不可撤销)"
	dlg.confirmed.connect(func() -> void:
		_select_block(-1)
		# 删所有非 spawn 的项 (保留出生点)
		var keep: Array = []
		for d in _placed_blocks:
			if String(d.get("kind", "")) == "spawn":
				keep.append(d)
			else:
				if d.get("node") != null:
					d["node"].queue_free()
		_placed_blocks = keep
		# 清空 undo / redo (清空操作本身不进栈, 不可撤销)
		_undo_stack.clear()
		_redo_stack.clear()
		_update_status()
	)
	add_child(dlg)
	dlg.popup_centered()


func _on_back_pressed() -> void:
	# 切回主场景 (qinghuaci)
	get_tree().change_scene_to_file("res://tracks/track_qinghuaci.tscn")


# ============================================================
#  数据序列化/反序列化
# ============================================================
func _build_track_data(track_display_name: String) -> Resource:
	var data: Resource = RaceTrackDataScript.new()
	data.set("track_name", track_display_name)
	# 遍历所有 placed_blocks, 按 kind 分流到 RaceTrackData 不同字段
	# block / speed_pad → blocks (走 add_block, 含 params)
	# anchor → grapple_anchors (走 add_anchor)
	# spawn → 跳过 (单独写 spawn_position/spawn_yaw_rad)
	for entry in _placed_blocks:
		var node: Node3D = entry.get("node")
		if node == null:
			continue
		var kind: String = String(entry.get("kind", "block"))
		var bid: String = String(entry.get("id", ""))
		match kind:
			"block", "speed_pad":
				# Bug 修复: 通过 get_editable_params 收集所有参数当前值
				var params: Dictionary = _collect_block_params(node)
				data.call("add_block", bid, node.global_transform, params)
			"anchor":
				var ar: float = node.get_meta("anchor_radius", 1.5)
				var dr: float = node.get_meta("detect_radius", 60.0)
				var col: Color = node.get_meta("anchor_color", Color(0.3, 0.85, 1.0))
				data.call("add_anchor", node.global_position, ar, dr, col)
			"spawn":
				pass   # 出生点单独序列化
	data.set("spawn_position", _spawn_position)
	data.set("spawn_yaw_rad", _spawn_yaw)
	# 用户要求: 把"初始地面开关 + 颜色"序列化到 RaceTrackData
	data.set("ground_enabled", _ground_enabled)
	data.set("ground_color", _ground_color)
	return data


# ============================================================
#  复制 / 粘贴 / 原地复制 (2026-06-03)
# ============================================================

## Ctrl+C: 复制选中积木到剪贴板 (多选保持相对位置 + 完整参数)
func _copy_selected() -> void:
	_clipboard.clear()
	if _selected_block_indices.is_empty():
		return
	# 第一个选中积木作为 base (rel_xform 的基准)
	var first_idx: int = int(_selected_block_indices[0])
	if first_idx < 0 or first_idx >= _placed_blocks.size():
		return
	var first_node: Node3D = _placed_blocks[first_idx]["node"]
	if first_node == null:
		return
	var base_inv: Transform3D = first_node.global_transform.inverse()
	_clipboard_base_basis = first_node.global_transform.basis   # 保存第一个积木的旋转
	for idx in _selected_block_indices:
		var i: int = int(idx)
		if i < 0 or i >= _placed_blocks.size():
			continue
		var entry: Dictionary = _placed_blocks[i]
		var node: Node3D = entry["node"]
		if node == null:
			continue
		var rel: Transform3D = base_inv * node.global_transform
		var params: Dictionary = _collect_block_params(node)
		_clipboard.append({
			"id": String(entry["id"]),
			"rel_xform": rel,
			"params": params,
		})
	print("[TrackEditor] 复制 %d 个积木到剪贴板" % _clipboard.size())


## Ctrl+V: 进入粘贴预览模式 (跟随鼠标, 点击放下, ESC 取消)
func _start_paste_preview() -> void:
	if _clipboard.is_empty():
		return
	# 如果已经在粘贴模式, 先取消旧的
	if _paste_mode:
		_cancel_paste()
	_paste_mode = true
	# 实例化预览节点 (半透明, 跟鼠标走)
	for item in _clipboard:
		var bid: String = item["id"]
		var bpath: String = BLOCK_LIBRARY.get(bid, "")
		if bpath == "":
			continue
		var packed: PackedScene = load(bpath)
		if packed == null:
			continue
		var node: Node3D = packed.instantiate()
		add_child(node)
		# 应用复制的参数到预览节点 (让预览外形跟原机关一致, 不是默认外形)
		var params: Dictionary = item.get("params", {})
		if not params.is_empty() and node.has_method("set_editable_param"):
			for k in params.keys():
				node.call("set_editable_param", String(k), float(params[k]))
		# 半透明化 (在参数应用后做, 因为 set_editable_param 可能 rebuild mesh)
		_make_node_transparent(node, 0.45)
		# 设初始 transform (相对第一个的 rel_xform, 实际位置 _process 每帧更新)
		node.transform = item["rel_xform"]
		_paste_preview_nodes.append(node)
	print("[TrackEditor] 粘贴预览: %d 个积木跟随鼠标 (点击放下, ESC 取消)" % _paste_preview_nodes.size())


## 粘贴预览每帧跟随鼠标 (在 _process 里调)
func _update_paste_preview() -> void:
	if not _paste_mode or _paste_preview_nodes.is_empty():
		return
	# 第一个节点跟鼠标 (投影到 place_y 高度水平面)
	var mp_world: Vector3 = _project_mouse_to_y(_place_y_offset)
	if mp_world == Vector3.INF:
		return
	# 网格吸附
	if _grid_snap_enabled and Input.is_key_pressed(KEY_ALT):
		mp_world = _snap_to_grid(mp_world)
	# 第一个节点的位置 = 鼠标投影点, 旋转 = 复制时的旋转 (保持朝向)
	var base_xform := Transform3D(_clipboard_base_basis, mp_world)
	for i in range(_paste_preview_nodes.size()):
		if i >= _clipboard.size():
			break
		var rel: Transform3D = _clipboard[i]["rel_xform"]
		_paste_preview_nodes[i].global_transform = base_xform * rel


## 点击确认粘贴
func _confirm_paste() -> void:
	if not _paste_mode or _paste_preview_nodes.is_empty():
		return
	# 把预览节点转为正式放置的积木
	var new_indices: Array = []
	for i in range(_paste_preview_nodes.size()):
		var preview: Node3D = _paste_preview_nodes[i]
		if i >= _clipboard.size():
			break
		var item: Dictionary = _clipboard[i]
		var bid: String = item["id"]
		var bpath: String = BLOCK_LIBRARY.get(bid, "")
		if bpath == "":
			continue
		var packed: PackedScene = load(bpath)
		if packed == null:
			continue
		var node: Node3D = packed.instantiate()
		_placed_root.add_child(node)
		node.global_transform = preview.global_transform
		# 应用参数
		var params: Dictionary = item["params"]
		if not params.is_empty() and node.has_method("set_editable_param"):
			for k in params.keys():
				node.call("set_editable_param", String(k), float(params[k]))
		var kind: String = "speed_pad" if bid == "speed_pad" else "block"
		_placed_blocks.append({"id": bid, "node": node, "kind": kind})
		new_indices.append(_placed_blocks.size() - 1)
	# 清理预览
	for pn in _paste_preview_nodes:
		pn.queue_free()
	_paste_preview_nodes.clear()
	_paste_mode = false
	# Undo: 当做 add 批量操作
	if not new_indices.is_empty():
		_undo_push({"op": "add_batch", "indices": new_indices})
	# 选中新放置的
	_selected_block_indices = new_indices
	if not new_indices.is_empty():
		_selected_block_index = new_indices[0]
	_refresh_selection_ui()
	_update_status()
	print("[TrackEditor] 粘贴 %d 个积木" % new_indices.size())


## ESC / 右键: 取消粘贴
func _cancel_paste() -> void:
	for pn in _paste_preview_nodes:
		pn.queue_free()
	_paste_preview_nodes.clear()
	_paste_mode = false


## Ctrl+D: 原地复制 (选中积木偏移 +2m 后立即放下)
func _duplicate_in_place() -> void:
	if _selected_block_indices.is_empty():
		return
	# 先复制到剪贴板
	_copy_selected()
	if _clipboard.is_empty():
		return
	# 计算偏移方向: 相机的右方向在水平面投影 (XZ)
	var offset_dir: Vector3 = Vector3(1.0, 0.0, 0.0)
	if _cam:
		offset_dir = _cam.global_transform.basis.x
		offset_dir.y = 0.0
		if offset_dir.length() > 0.001:
			offset_dir = offset_dir.normalized()
		else:
			offset_dir = Vector3(1.0, 0.0, 0.0)
	var offset: Vector3 = offset_dir * 2.0
	# 第一个选中积木的位置 + 偏移 = base 位置, 旋转保持跟原积木一致
	var first_idx: int = int(_selected_block_indices[0])
	var first_node: Node3D = _placed_blocks[first_idx]["node"]
	var base_pos: Vector3 = first_node.global_position + offset
	var base_xform := Transform3D(_clipboard_base_basis, base_pos)
	# 直接放置 (不进入预览模式)
	var new_indices: Array = []
	for i in range(_clipboard.size()):
		var item: Dictionary = _clipboard[i]
		var bid: String = item["id"]
		var bpath: String = BLOCK_LIBRARY.get(bid, "")
		if bpath == "":
			continue
		var packed: PackedScene = load(bpath)
		if packed == null:
			continue
		var node: Node3D = packed.instantiate()
		_placed_root.add_child(node)
		node.global_transform = base_xform * item["rel_xform"]
		# 应用参数
		var params: Dictionary = item["params"]
		if not params.is_empty() and node.has_method("set_editable_param"):
			for k in params.keys():
				node.call("set_editable_param", String(k), float(params[k]))
		var kind: String = "speed_pad" if bid == "speed_pad" else "block"
		_placed_blocks.append({"id": bid, "node": node, "kind": kind})
		new_indices.append(_placed_blocks.size() - 1)
	if not new_indices.is_empty():
		_undo_push({"op": "add_batch", "indices": new_indices})
	# 选中新放置的副本
	_selected_block_indices = new_indices
	if not new_indices.is_empty():
		_selected_block_index = new_indices[0]
	_refresh_selection_ui()
	_update_status()
	print("[TrackEditor] 原地复制 %d 个积木 (偏移 +2m)" % new_indices.size())


# 从积木节点收集所有 editable_params 当前值, 返回 {key: value} 字典
# 给保存赛道用. 没有 get_editable_params 方法的积木返回空字典 (兼容)
func _collect_block_params(node: Node3D) -> Dictionary:
	var out: Dictionary = {}
	if node == null or not node.has_method("get_editable_params"):
		return out
	var params: Array = node.call("get_editable_params")
	for p in params:
		var key: String = String(p.get("key", ""))
		if key.is_empty():
			continue
		out[key] = float(p.get("value", 0.0))
	# 墙壁曲线序列化: 把左右 WallCurve 节点数据编码为特殊参数
	if node.has_method("get_wall_curve_left"):
		var wl: WallCurve = node.call("get_wall_curve_left")
		for wi in range(wl.nodes.size()):
			out["_wl_t_%d" % wi] = float(wl.nodes[wi]["t"])
			out["_wl_a_%d" % wi] = 1.0 if bool(wl.nodes[wi]["active"]) else 0.0
		out["_wl_count"] = float(wl.nodes.size())
	if node.has_method("get_wall_curve_right"):
		var wr: WallCurve = node.call("get_wall_curve_right")
		for wi in range(wr.nodes.size()):
			out["_wr_t_%d" % wi] = float(wr.nodes[wi]["t"])
			out["_wr_a_%d" % wi] = 1.0 if bool(wr.nodes[wi]["active"]) else 0.0
		out["_wr_count"] = float(wr.nodes.size())
	return out


# 把存档里 params 字典应用回新实例化的积木节点
# 注意: 必须按 length 在 entry/exit_width 之前应用吗?
#  → 实际所有 setter 都会触发 rebuild(), 多次 rebuild 浪费但不会出错.
#    优化: 一次性 set 所有属性, 但 setter 各自 rebuild — 最后一次 rebuild 是对的.
#  → 简单实现就行: for k, v 直接 set_editable_param.
func _apply_block_params(node: Node3D, params: Dictionary) -> void:
	if node == null or params.is_empty() or not node.has_method("set_editable_param"):
		return
	# 先应用普通参数 (跳过 _wl_ / _wr_ 开头的墙壁序列化数据)
	for k in params.keys():
		if String(k).begins_with("_wl_") or String(k).begins_with("_wr_"):
			continue
		node.call("set_editable_param", String(k), float(params[k]))
	# 恢复 WallCurve 数据
	if node.has_method("get_wall_curve_left") and params.has("_wl_count"):
		var wl: WallCurve = node.call("get_wall_curve_left")
		var count: int = int(params["_wl_count"])
		wl.nodes.clear()
		for wi in range(count):
			var t: float = float(params.get("_wl_t_%d" % wi, 0.0))
			var active: bool = float(params.get("_wl_a_%d" % wi, 1.0)) > 0.5
			wl.nodes.append({"t": t, "active": active})
		if wl.nodes.size() < 2:
			wl.nodes = [{"t": 0.0, "active": true}, {"t": 1.0, "active": true}]
	if node.has_method("get_wall_curve_right") and params.has("_wr_count"):
		var wr: WallCurve = node.call("get_wall_curve_right")
		var count_r: int = int(params["_wr_count"])
		wr.nodes.clear()
		for wi in range(count_r):
			var t: float = float(params.get("_wr_t_%d" % wi, 0.0))
			var active: bool = float(params.get("_wr_a_%d" % wi, 1.0)) > 0.5
			wr.nodes.append({"t": t, "active": active})
		if wr.nodes.size() < 2:
			wr.nodes = [{"t": 0.0, "active": true}, {"t": 1.0, "active": true}]
	# 最终 rebuild (墙壁数据恢复后需要重建)
	if node.has_method("_rebuild") and (params.has("_wl_count") or params.has("_wr_count")):
		node.call("_rebuild")


func _load_track_data(path: String) -> void:
	var res: Resource = load(path) as Resource
	if res == null or not ("blocks" in res):
		push_warning("[TrackEditor] %s 不是有效的 RaceTrackData" % path)
		return
	# 记录当前打开的赛道路径 (用于"保存"按钮覆盖写入)
	_current_track_path = path
	# 清空 (保留出生点)
	_select_block(-1)
	var keep_spawn: Dictionary = {}
	for d in _placed_blocks:
		if String(d.get("kind", "")) == "spawn":
			keep_spawn = d
		else:
			if d.get("node") != null:
				d["node"].queue_free()
	_placed_blocks.clear()
	if not keep_spawn.is_empty():
		_placed_blocks.append(keep_spawn)
	# 重新 instance 路段积木 / 加速带
	var blocks_data: Array = res.get("blocks")
	for b in blocks_data:
		var bid: String = b.get("id", "")
		var bxform: Transform3D = b.get("transform", Transform3D.IDENTITY)
		var bparams: Dictionary = b.get("params", {})
		var bpath: String = BLOCK_LIBRARY.get(bid, "")
		if bpath == "":
			push_warning("[TrackEditor] 未知积木 id: %s" % bid)
			continue
		var packed: PackedScene = load(bpath)
		var node: Node3D = packed.instantiate()
		_placed_root.add_child(node)
		node.global_transform = bxform
		_apply_block_params(node, bparams)
		var k: String = "speed_pad" if bid == "speed_pad" else "block"
		_placed_blocks.append({"id": bid, "node": node, "kind": k})
	# 锚点
	var anchors_data: Array = res.get("grapple_anchors")
	for a in anchors_data:
		var ap: Vector3 = a.get("position", Vector3.ZERO)
		var ar: float = a.get("anchor_radius", 1.5)
		var dr: float = a.get("detect_radius", 60.0)
		var col: Color = a.get("color", Color(0.3, 0.85, 1.0))
		var anode := _create_anchor_visual(ap, ar, dr, col)
		anode.set_meta("anchor_radius", ar)
		anode.set_meta("detect_radius", dr)
		anode.set_meta("anchor_color", col)
		_placed_root.add_child(anode)
		_placed_blocks.append({"id": "anchor", "node": anode, "kind": "anchor"})
	# 出生点
	_spawn_position = res.get("spawn_position")
	_spawn_yaw = res.get("spawn_yaw_rad")
	_sync_spawn_to_placed()
	# 加载初始地面配置 (兼容旧赛道 — 没字段时用默认值)
	if "ground_enabled" in res:
		_ground_enabled = bool(res.get("ground_enabled"))
	if "ground_color" in res:
		_ground_color = res.get("ground_color")
	_rebuild_editor_ground()
	# 清空 undo / redo (加载是个"新起点", 不应该撤回到上一张赛道)
	_undo_stack.clear()
	_redo_stack.clear()
	_update_status()


func _update_status() -> void:
	var status: Label = _ui.get_node_or_null("StatusLabel") as Label
	if status == null:
		return
	var tool_name: String
	match _current_tool:
		Tool.SELECT:
			if _selected_block_indices.size() > 1:
				tool_name = "选择模式 - 多选 %d 块 (Ctrl+点击 加/移; 改坐标=整体偏移)" % _selected_block_indices.size()
			else:
				tool_name = "选择模式 (鼠标悬停高亮, 点击选中, Ctrl+点击 多选, ESC 返回)"
		Tool.BLOCK:
			tool_name = "放置: %s  (ESC 返回)" % _selected_block_id
		Tool.ANCHOR:
			tool_name = "放置钩索锚点  (ESC 返回)"
		Tool.SPAWN:
			tool_name = "移动出生点 (点鼠标位置=移到那里, ESC 返回)"
		Tool.PRESET:
			var pn: String = ""
			if _current_preset_index >= 0 and _current_preset_index < _block_presets.size():
				pn = String(_block_presets[_current_preset_index].get("name", ""))
			tool_name = "放置预设组合: %s  (ESC 返回)" % pn
		_:
			tool_name = "?"
	# 统计各类型项数
	var n_block: int = 0
	var n_pad: int = 0
	var n_anchor: int = 0
	for d in _placed_blocks:
		match String(d.get("kind", "block")):
			"block": n_block += 1
			"speed_pad": n_pad += 1
			"anchor": n_anchor += 1
	status.text = "[%s] | 积木 %d | 加速带 %d | 锚点 %d | Undo:%d Redo:%d" % [
		tool_name, n_block, n_pad, n_anchor, _undo_stack.size(), _redo_stack.size()]


# ============================================================
#  窄道手柄拖拽
# ============================================================
## 检测鼠标是否命中了选中窄道的手柄, 返回手柄名 ("start"/"mid"/"end") 或 ""
## 用屏幕空间距离判定 (把手柄世界坐标投影到屏幕, 比 3D 射线检测更可靠)
func _pick_narrow_path_handle_at_mouse() -> String:
	var mp: Vector2 = get_viewport().get_mouse_position()
	var screen_hit_radius: float = 40.0
	# 墙壁模式下放大命中半径 (墙节点标记比路径手柄小)
	if _wall_handle_mode > 0:
		screen_hit_radius = 60.0
	var best: String = ""
	var best_screen_dist: float = screen_hit_radius + 1.0

	# 墙壁手柄模式: 检测墙壁节点标记
	if _wall_handle_mode > 0 and not _selected_block_indices.is_empty():
		var idx: int = int(_selected_block_indices[0])
		if idx >= 0 and idx < _placed_blocks.size():
			var node: Node3D = _placed_blocks[idx].get("node")
			if node != null and node.has_method("get_wall_curve_left"):
				var side_str: String = "L" if _wall_handle_mode == 1 else "R"
				var curve: WallCurve = node.call("get_wall_curve_left") if _wall_handle_mode == 1 else node.call("get_wall_curve_right")
				var points: Array = node.call("_calc_bezier_points") if node.has_method("_calc_bezier_points") else []
				var n: int = points.size()
				if n >= 2:
					for wi in range(curve.nodes.size()):
						var t: float = float(curve.nodes[wi]["t"])
						var pt_idx: int = clampi(int(t * float(n - 1)), 0, n - 1)
						var pt_local: Vector3 = points[pt_idx] as Vector3
						# 计算 right 方向
						var dir: Vector3
						if pt_idx < n - 1:
							dir = ((points[pt_idx + 1] as Vector3) - pt_local).normalized()
						else:
							dir = (pt_local - (points[pt_idx - 1] as Vector3)).normalized()
						var right: Vector3 = dir.cross(Vector3.UP).normalized()
						if right.length_squared() < 0.01:
							right = Vector3.RIGHT
						var pw: float = node.get("path_width") if "path_width" in node else 4.0
						var side_mult: float = -1.0 if _wall_handle_mode == 1 else 1.0
						var wall_h: float = node.get("wall_height") if "wall_height" in node else 2.5
						var thickness: float = node.get("path_thickness") if "path_thickness" in node else 0.3
						var marker_pos: Vector3 = pt_local + right * (pw * 0.5 * side_mult)
						marker_pos.y += thickness * 0.5 + wall_h + 0.5
						var marker_world: Vector3 = node.global_transform * marker_pos
						if not _cam.is_position_behind(marker_world):
							var screen_pos: Vector2 = _cam.unproject_position(marker_world)
							var dist: float = mp.distance_to(screen_pos)
							if dist < screen_hit_radius and dist < best_screen_dist:
								best_screen_dist = dist
								best = "wall_%s_%d" % [side_str, wi]
		return best

	for sel_idx in _selected_block_indices:
		var i: int = int(sel_idx)
		if i < 0 or i >= _placed_blocks.size():
			continue
		var bid: String = String(_placed_blocks[i].get("id", ""))
		if bid != "narrow_path" and bid != "fragile_narrow" and bid != "star_trail" and bid != "right_angle_path":
			continue
		var node: Node3D = _placed_blocks[i].get("node")
		if node == null:
			continue
		# 检查手柄是否可见 (路径模式下才需要)
		if not node.get("_handles_visible"):
			continue

		# 直角窄道: 用 pick_handle_at 的多节点模式
		if bid == "right_angle_path":
			var waypoints: Array = node.get("waypoints") if "waypoints" in node else []
			var handle_lift := Vector3(0.0, 2.0, 0.0)
			for wi in range(waypoints.size()):
				var wp_local: Vector3 = waypoints[wi] as Vector3
				var wp_world: Vector3 = node.global_transform * (wp_local + handle_lift)
				if _cam.is_position_behind(wp_world):
					continue
				var screen_pos: Vector2 = _cam.unproject_position(wp_world)
				var dist: float = mp.distance_to(screen_pos)
				if dist < screen_hit_radius and dist < best_screen_dist:
					best_screen_dist = dist
					best = "handle_%d" % wi
			continue

		# 窄道/绳星: 三手柄模式 (start/mid/end)
		if not node.has_method("get_end_world_pos"):
			continue
		var handle_lift := Vector3(0.0, 2.0, 0.0)
		var positions: Dictionary = {
			"start": node.global_position + handle_lift,
			"end": node.call("get_end_world_pos") + handle_lift,
			"mid": node.global_position + node.global_transform.basis * (node.get("end_offset") * 0.5 + node.get("curve_offset")) + handle_lift,
		}
		for hname in positions.keys():
			var world_pos: Vector3 = positions[hname]
			if not _cam.is_position_behind(world_pos):
				var screen_pos: Vector2 = _cam.unproject_position(world_pos)
				var dist: float = mp.distance_to(screen_pos)
				if dist < screen_hit_radius and dist < best_screen_dist:
					best_screen_dist = dist
					best = hname
	return best


## 开始拖拽手柄
func _begin_drag_handle(handle_name: String) -> void:
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null or not node.has_method("move_handle_to"):
		return
	_is_dragging_handle = true
	_dragging_handle_name = handle_name
	_dragging_handle_block = node
	_drag_handle_block_idx = idx
	# 记录拖拽前参数快照 (用于 undo)
	_drag_handle_params_before = _collect_block_params(node)
	# 拖动平面 Y = 手柄当前位置的 Y
	if handle_name.begins_with("wall_"):
		# 墙壁节点拖拽: wall_L_0 / wall_R_1 等
		_drag_handle_plane_y = node.global_position.y + node.get("wall_height") if "wall_height" in node else 2.5
	elif handle_name.begins_with("handle_"):
		# 直角窄道多节点模式
		var wi: int = int(handle_name.split("_")[1])
		var waypoints: Array = node.get("waypoints") if "waypoints" in node else []
		if wi >= 0 and wi < waypoints.size():
			var wp_world: Vector3 = node.global_transform * (waypoints[wi] as Vector3)
			_drag_handle_plane_y = wp_world.y
		else:
			_drag_handle_plane_y = node.global_position.y
	else:
		match handle_name:
			"start":
				_drag_handle_plane_y = node.global_position.y
			"end":
				_drag_handle_plane_y = node.call("get_end_world_pos").y
			"mid":
				var mid_pos: Vector3 = node.global_position + node.global_transform.basis * ((node.get("end_offset") as Vector3) * 0.5 + (node.get("curve_offset") as Vector3))
				_drag_handle_plane_y = mid_pos.y


## 每帧更新手柄拖拽 (鼠标跟随)
func _update_drag_handle() -> void:
	if not _is_dragging_handle or _dragging_handle_block == null:
		return
	var mp_world: Vector3
	if Input.is_key_pressed(KEY_SHIFT):
		# Shift = 纵向模式: 只改 Y, XZ 保持手柄当前位置不动
		var handle_xz: Vector3 = _get_current_handle_pos()
		var vert_pos: Vector3 = _project_mouse_to_vertical_plane(handle_xz)
		if vert_pos == Vector3.INF:
			return
		mp_world = Vector3(handle_xz.x, vert_pos.y, handle_xz.z)
	else:
		# 默认 = 水平模式: XZ 跟随鼠标, Y 保持手柄平面高度
		mp_world = _project_mouse_to_y(_drag_handle_plane_y)
		if mp_world == Vector3.INF:
			return
	# 网格吸附
	if _grid_snap_enabled and Input.is_key_pressed(KEY_ALT):
		mp_world = _snap_to_grid(mp_world)
	# 墙壁节点拖拽: 将世界坐标转为路径上的 t 值
	if _dragging_handle_name.begins_with("wall_"):
		_update_wall_node_drag(mp_world)
	elif _dragging_handle_name.begins_with("handle_"):
		var wi: int = int(_dragging_handle_name.split("_")[1])
		_dragging_handle_block.call("move_handle_to", wi, mp_world)
	else:
		_dragging_handle_block.call("move_handle_to", _dragging_handle_name, mp_world)


## 获取当前拖拽中手柄的世界位置 (用于 Shift 纵向模式保持 XZ)
func _get_current_handle_pos() -> Vector3:
	if _dragging_handle_block == null:
		return Vector3.ZERO
	# 直角窄道多节点模式
	if _dragging_handle_name.begins_with("handle_"):
		var wi: int = int(_dragging_handle_name.split("_")[1])
		var waypoints: Array = _dragging_handle_block.get("waypoints") if "waypoints" in _dragging_handle_block else []
		if wi >= 0 and wi < waypoints.size():
			return _dragging_handle_block.global_transform * (waypoints[wi] as Vector3)
		return _dragging_handle_block.global_position
	# 窄道三手柄模式
	match _dragging_handle_name:
		"start":
			return _dragging_handle_block.global_position
		"end":
			return _dragging_handle_block.call("get_end_world_pos")
		"mid":
			var eo: Vector3 = _dragging_handle_block.get("end_offset")
			var co: Vector3 = _dragging_handle_block.get("curve_offset")
			return _dragging_handle_block.global_position + _dragging_handle_block.global_transform.basis * (eo * 0.5 + co)
	return Vector3.ZERO


## 结束手柄拖拽
func _end_drag_handle() -> void:
	# Undo: 记录拖拽后参数快照, push undo op
	if _dragging_handle_block != null and _drag_handle_block_idx >= 0:
		var params_after: Dictionary = _collect_block_params(_dragging_handle_block)
		if params_after != _drag_handle_params_before:
			_undo_push({"op": "param_change", "index": _drag_handle_block_idx, "before": _drag_handle_params_before, "after": params_after})
	_is_dragging_handle = false
	_dragging_handle_name = ""
	_dragging_handle_block = null
	_drag_handle_block_idx = -1
	_drag_handle_params_before = {}
	# 刷新参数面板 (手柄拖拽改了 end_offset/curve_offset)
	_refresh_selection_ui()


## 墙壁节点拖拽: 将鼠标世界坐标投影到路径上, 得到新的 t 值
func _update_wall_node_drag(world_pos: Vector3) -> void:
	if _dragging_handle_block == null:
		return
	# 解析 "wall_L_0" → side="left", index=0
	var parts: PackedStringArray = _dragging_handle_name.split("_")
	if parts.size() < 3:
		return
	var side_char: String = parts[1]  # "L" or "R"
	var node_idx: int = int(parts[2])
	var side: String = "left" if side_char == "L" else "right"

	# 获取路径点
	var node: Node3D = _dragging_handle_block
	if not node.has_method("_calc_bezier_points"):
		return
	var points: Array = node.call("_calc_bezier_points")
	if points.size() < 2:
		return

	# 将 world_pos 转为本地坐标
	var local_pos: Vector3 = node.global_transform.affine_inverse() * world_pos

	# 找路径上最近的点, 得到 t 值
	var best_t: float = 0.0
	var best_dist: float = 999999.0
	var n: int = points.size()
	for i in range(n):
		var d: float = (points[i] as Vector3).distance_to(local_pos)
		if d < best_dist:
			best_dist = d
			best_t = float(i) / float(n - 1)
	# clamp t 到 [0, 1]
	best_t = clampf(best_t, 0.0, 1.0)

	# 更新节点 t 值
	if node.has_method("wall_move_node"):
		node.call("wall_move_node", side, node_idx, best_t)


## 墙壁节点双击: 切换 active 状态 (有墙↔无墙)
func _wall_toggle_node_by_name(handle_name: String) -> void:
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null or not node.has_method("wall_toggle_node"):
		return
	var parts: PackedStringArray = handle_name.split("_")
	if parts.size() < 3:
		return
	var side_char: String = parts[1]
	var node_idx: int = int(parts[2])
	var side: String = "left" if side_char == "L" else "right"
	node.call("wall_toggle_node", side, node_idx)
	_refresh_selection_ui()


# ============================================================
#  窄道拟合连接 (J=普通窄道 / K=易碎窄道)
#  在两段窄道之间生成一段拟合连接道:
#  - 使用 Block_NarrowPath/Block_FragileNarrow .tscn (保证序列化/运行时正常)
#  - 不旋转节点, 用世界坐标直接设 end_offset = to - from (起终点精确)
#  - curve_offset 用 Hermite 插值的 t=0.5 中点推导 (弯曲自然)
# ============================================================
func _join_narrow_paths(join_type: String = "narrow_path") -> void:
	if _selected_block_indices.size() != 2:
		return
	var idx_a: int = int(_selected_block_indices[0])
	var idx_b: int = int(_selected_block_indices[1])
	if idx_a < 0 or idx_a >= _placed_blocks.size() or idx_b < 0 or idx_b >= _placed_blocks.size():
		return
	var node_a: Node3D = _placed_blocks[idx_a].get("node")
	var node_b: Node3D = _placed_blocks[idx_b].get("node")
	if node_a == null or node_b == null:
		return
	var bid_a: String = String(_placed_blocks[idx_a].get("id", ""))
	var bid_b: String = String(_placed_blocks[idx_b].get("id", ""))
	var joinable_ids: Array = ["narrow_path", "fragile_narrow", "right_angle_path", "star_trail"]
	if bid_a not in joinable_ids:
		return
	if bid_b not in joinable_ids:
		return
	if not node_a.has_method("get_end_world_pos") or not node_b.has_method("get_end_world_pos"):
		return

	# 获取 4 端点
	var a_start: Vector3 = node_a.global_position
	var a_end: Vector3 = node_a.call("get_end_world_pos")
	var b_start: Vector3 = node_b.global_position
	var b_end: Vector3 = node_b.call("get_end_world_pos")

	# 宽度
	var a_start_w: float = node_a.call("get_start_width") if node_a.has_method("get_start_width") else node_a.get("path_width")
	var a_end_w: float = node_a.call("get_end_width") if node_a.has_method("get_end_width") else node_a.get("path_width")
	var b_start_w: float = node_b.call("get_start_width") if node_b.has_method("get_start_width") else node_b.get("path_width")
	var b_end_w: float = node_b.call("get_end_width") if node_b.has_method("get_end_width") else node_b.get("path_width")

	# 找最近的端点对
	var combos: Array = [
		{"d": a_end.distance_to(b_start),
		 "from_pos": a_end, "from_tan": node_a.call("get_end_tangent_world"), "from_w": a_end_w,
		 "to_pos": b_start, "to_tan": node_b.call("get_start_tangent_world"), "to_w": b_start_w},
		{"d": a_end.distance_to(b_end),
		 "from_pos": a_end, "from_tan": node_a.call("get_end_tangent_world"), "from_w": a_end_w,
		 "to_pos": b_end, "to_tan": -node_b.call("get_end_tangent_world"), "to_w": b_end_w},
		{"d": b_end.distance_to(a_start),
		 "from_pos": b_end, "from_tan": node_b.call("get_end_tangent_world"), "from_w": b_end_w,
		 "to_pos": a_start, "to_tan": node_a.call("get_start_tangent_world"), "to_w": a_start_w},
		{"d": a_start.distance_to(b_start),
		 "from_pos": a_start, "from_tan": -node_a.call("get_start_tangent_world"), "from_w": a_start_w,
		 "to_pos": b_start, "to_tan": node_b.call("get_start_tangent_world"), "to_w": b_start_w},
	]
	var best: Dictionary = combos[0]
	for c in combos:
		if c["d"] < best["d"]:
			best = c

	var from_pos: Vector3 = best["from_pos"]
	var from_tan: Vector3 = best["from_tan"].normalized()
	var from_w: float = best["from_w"]
	var to_pos: Vector3 = best["to_pos"]
	var to_tan: Vector3 = best["to_tan"].normalized()
	var to_w: float = best["to_w"]

	# 实例化 Block (走序列化系统, 运行时正常加载)
	var tscn_path: String = BLOCK_LIBRARY.get(join_type, "")
	var packed: PackedScene = load(tscn_path)
	if packed == null:
		return
	var node: Node3D = packed.instantiate()
	_placed_root.add_child(node)

	# 不旋转, 起点精确 = from_pos
	node.global_position = from_pos
	node.rotation = Vector3.ZERO

	# end_offset 精确 = to_pos - from_pos (无旋转时 local == world offset)
	var end_off: Vector3 = to_pos - from_pos
	var dist: float = end_off.length()
	node.set("end_offset", end_off)

	# 宽度
	node.set("path_width", from_w)
	node.set("end_width", to_w)

	# Hermite 模式: 设置本地空间的切线方向 (Block 的 _rebuild 会用 Hermite 插值)
	# from_tan/to_tan 是世界方向, 无旋转时 local == world
	node.set("hermite_from_tan", from_tan)
	node.set("hermite_to_tan", to_tan)

	# 关闭发光避免异形
	if node.get("edge_glow") != null:
		node.set("edge_glow", 0.0)

	# rebuild
	if node.has_method("_rebuild"):
		node.call("_rebuild")

	# 注册
	_placed_blocks.append({"id": join_type, "node": node, "kind": "block"})
	_undo_push({"op": "add", "index": _placed_blocks.size() - 1})
	var type_label: String = "窄道" if join_type == "narrow_path" else "易碎窄道"
	print("[TrackEditor] 拟合连接: %s, 宽度 %.1f→%.1f m, 距离=%.1fm" % [type_label, from_w, to_w, dist])


## 从 Tuner cfg 文件直接读取机关默认值并应用到节点 (当 Tuner 节点不存在时的 fallback)
func _apply_mechanism_defaults_from_cfg(node: Node3D, block_id: String) -> void:
	if not node.has_method("set_editable_param"):
		return
	# Tuner cfg 路径: 跟 Tuner.gd 的 _stable_cfg_path() 一致
	# 开发时 = res://config/tune.cfg (globalize 后是绝对路径)
	# 导出后 = exe旁/config/tune.cfg
	var cfg_path: String
	if OS.has_feature("editor") or OS.is_debug_build():
		cfg_path = ProjectSettings.globalize_path("res://config/tune.cfg")
	else:
		cfg_path = OS.get_executable_path().get_base_dir().path_join("config").path_join("tune.cfg")
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return
	if not cfg.has_section("mechanism_defaults"):
		return
	# 遍历 [mechanism_defaults] 段, 找 "block_id:key" 前缀匹配的条目
	var prefix: String = block_id + ":"
	for full_key in cfg.get_section_keys("mechanism_defaults"):
		if not String(full_key).begins_with(prefix):
			continue
		var param_key: String = String(full_key).substr(prefix.length())
		var value: float = float(cfg.get_value("mechanism_defaults", full_key, 0.0))
		node.call("set_editable_param", param_key, value)


# ============================================================
#  L 键: 在选中道路/窄道中线上生成绳星轨迹 (每3颗一组)
#  核心: 取道路的贝塞尔曲线中线世界坐标点, 按每3颗分段,
#        每段用实际曲线上的起终点构建 star_trail 的 end_offset
# ============================================================
func _generate_star_trails_on_selected() -> void:
	var star_trail_path: String = BLOCK_LIBRARY.get("star_trail", "")
	if star_trail_path.is_empty():
		return
	var star_packed: PackedScene = load(star_trail_path) as PackedScene
	if star_packed == null:
		return

	var added_indices: Array = []
	for sel_idx in _selected_block_indices:
		var idx: int = int(sel_idx)
		if idx < 0 or idx >= _placed_blocks.size():
			continue
		var src_node: Node3D = _placed_blocks[idx].get("node")
		if src_node == null:
			continue

		# 获取道路中线的世界坐标点序列
		var world_points: Array[Vector3] = _get_road_center_world_points(src_node, _placed_blocks[idx])
		if world_points.size() < 2:
			continue

		# 计算路径总长
		var total_len: float = 0.0
		for i in range(1, world_points.size()):
			total_len += world_points[i].distance_to(world_points[i - 1])
		if total_len < 1.0:
			continue

		# 每3颗一组, 按路径长度均分
		var stars_per_group: int = 3
		var group_len: float = minf(total_len, 30.0)
		var num_groups: int = maxi(int(total_len / group_len), 1)
		if total_len <= group_len * 1.2:
			num_groups = 1

		# 预计算累积长度便于按 t 采样
		var cum_lengths: Array[float] = [0.0]
		for i in range(1, world_points.size()):
			cum_lengths.append(cum_lengths[i - 1] + world_points[i].distance_to(world_points[i - 1]))

		for g in range(num_groups):
			var t_start: float = float(g) / float(num_groups)
			var t_end: float = float(g + 1) / float(num_groups)
			var group_start_world: Vector3 = _sample_path_at_t(world_points, cum_lengths, total_len, t_start)
			var group_end_world: Vector3 = _sample_path_at_t(world_points, cum_lengths, total_len, t_end)
			var group_end_offset: Vector3 = group_end_world - group_start_world

			# 计算起终点的切线方向 (用于 Hermite 精确拟合弯曲)
			var tan_start: Vector3 = _sample_tangent_at_t(world_points, cum_lengths, total_len, t_start)
			var tan_end: Vector3 = _sample_tangent_at_t(world_points, cum_lengths, total_len, t_end)
			# Hermite 切线需归一化 (Block_StarTrail 内部会乘 dist)
			tan_start = tan_start.normalized()
			tan_end = tan_end.normalized()

			var trail: Node3D = star_packed.instantiate()
			_placed_root.add_child(trail)
			trail.global_position = group_start_world

			if trail.has_method("set_editable_param"):
				trail.call("set_editable_param", "end_offset_x", group_end_offset.x)
				trail.call("set_editable_param", "end_offset_y", group_end_offset.y)
				trail.call("set_editable_param", "end_offset_z", group_end_offset.z)
				trail.call("set_editable_param", "star_count", float(stars_per_group))
				# 用 Hermite 切线精确拟合弯曲 (比 curve_offset 更准)
				trail.call("set_editable_param", "hermite_from_tan_x", tan_start.x)
				trail.call("set_editable_param", "hermite_from_tan_y", tan_start.y)
				trail.call("set_editable_param", "hermite_from_tan_z", tan_start.z)
				trail.call("set_editable_param", "hermite_to_tan_x", tan_end.x)
				trail.call("set_editable_param", "hermite_to_tan_y", tan_end.y)
				trail.call("set_editable_param", "hermite_to_tan_z", tan_end.z)

			# 应用 Tuner 默认值
			var tuner_node: Node = get_tree().current_scene.find_child("Tuner", true, false)
			if tuner_node and tuner_node.has_method("apply_mechanism_defaults"):
				tuner_node.call("apply_mechanism_defaults", trail, "star_trail")
			else:
				_apply_mechanism_defaults_from_cfg(trail, "star_trail")

			_placed_blocks.append({"id": "star_trail", "node": trail, "kind": "block"})
			added_indices.append(_placed_blocks.size() - 1)

	if not added_indices.is_empty():
		_undo_push({"op": "add_many", "indices": added_indices})
		_update_status()
		print("[TrackEditor] L键: 在选中道路上生成了 %d 组绳星轨迹" % added_indices.size())


## 在 3D 世界中显示选中窄道的中线长度
func _update_path_length_label_3d(node: Node3D) -> void:
	# 清除旧标签
	if _path_length_label_3d != null and is_instance_valid(_path_length_label_3d):
		_path_length_label_3d.queue_free()
		_path_length_label_3d = null
	if node == null:
		return
	# 获取路径点 (支持所有窄道类型)
	var pts: Array = []
	if node.has_method("_calc_bezier_points"):
		pts = node.call("_calc_bezier_points")
	elif node.has_method("_bezier_at"):
		# FragileNarrow: 用采样获取点
		for i in range(49):
			var t: float = float(i) / 48.0
			pts.append(node.call("_bezier_at", t))
	elif node.has_method("get_end_world_pos"):
		# 简单两点
		pts = [Vector3.ZERO, node.global_transform.affine_inverse() * node.call("get_end_world_pos")]
	if pts.size() < 2:
		return
	var path_len: float = 0.0
	for pi in range(1, pts.size()):
		path_len += (pts[pi] as Vector3).distance_to(pts[pi - 1] as Vector3)
	# 标签位于路径中点上方
	var mid_idx: int = pts.size() / 2
	var mid_local: Vector3 = pts[mid_idx] as Vector3
	var mid_world: Vector3 = node.global_transform * mid_local
	_path_length_label_3d = Label3D.new()
	_path_length_label_3d.text = "%.1f m" % path_len
	_path_length_label_3d.font_size = 96
	_path_length_label_3d.pixel_size = 0.01
	_path_length_label_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_path_length_label_3d.no_depth_test = true
	_path_length_label_3d.modulate = Color(1.0, 1.0, 1.0, 1.0)
	_path_length_label_3d.outline_modulate = Color(0.0, 0.0, 0.0, 1.0)
	_path_length_label_3d.outline_size = 12
	_path_length_label_3d.global_position = mid_world + Vector3(0.0, 8.0, 0.0)
	add_child(_path_length_label_3d)


## 清除 3D 长度标签 (取消选中时调用)
func _clear_path_length_label_3d() -> void:
	if _path_length_label_3d != null and is_instance_valid(_path_length_label_3d):
		_path_length_label_3d.queue_free()
		_path_length_label_3d = null


# ============================================================
#  H 键: 墙壁手柄模式切换
#  模式 0 = 路径手柄 (默认, start/mid/end)
#  模式 1 = 左墙手柄 (显示左墙节点, 可拖拽 t 值, 点击切 active)
#  模式 2 = 右墙手柄 (同上)
# ============================================================
func _toggle_wall_handle_mode() -> void:
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null:
		return
	# 只有有墙壁系统的窄道才能切换
	if not node.has_method("get_wall_curve_left"):
		return
	_wall_handle_mode = (_wall_handle_mode + 1) % 3
	# 隐藏旧手柄, 显示新手柄
	if node.has_method("hide_handles"):
		node.call("hide_handles")
	match _wall_handle_mode:
		0:
			if node.has_method("show_handles"):
				node.call("show_handles")
			_show_wall_mode_label("路径手柄")
		1:
			_show_wall_mode_label("◀ 左墙 ▶  (拖拽/双击/U全开关/+增/-删)")
		2:
			_show_wall_mode_label("◀ 右墙 ▶  (拖拽/双击/U全开关/+增/-删)")
	# 触发 rebuild 显示/隐藏对应墙壁标记
	if node.has_method("_rebuild"):
		node.call("_rebuild")


var _wall_mode_label_3d: Label3D = null

func _show_wall_mode_label(text: String) -> void:
	print("[TrackEditor] %s" % text)
	# 在选中物上方显示模式标签 (2秒后消失)
	if _wall_mode_label_3d and is_instance_valid(_wall_mode_label_3d):
		_wall_mode_label_3d.queue_free()
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null:
		return
	_wall_mode_label_3d = Label3D.new()
	_wall_mode_label_3d.text = text
	_wall_mode_label_3d.font_size = 64
	_wall_mode_label_3d.pixel_size = 0.01
	_wall_mode_label_3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_wall_mode_label_3d.no_depth_test = true
	_wall_mode_label_3d.modulate = Color(0.3, 0.9, 1.0, 1.0)
	_wall_mode_label_3d.outline_modulate = Color(0.0, 0.0, 0.0, 1.0)
	_wall_mode_label_3d.outline_size = 10
	_wall_mode_label_3d.global_position = node.global_position + Vector3(0.0, 6.0, 0.0)
	add_child(_wall_mode_label_3d)
	# 2秒后淡出
	var tw := create_tween()
	tw.tween_interval(1.5)
	tw.tween_property(_wall_mode_label_3d, "modulate:a", 0.0, 0.5)
	tw.tween_callback(func() -> void:
		if _wall_mode_label_3d and is_instance_valid(_wall_mode_label_3d):
			_wall_mode_label_3d.queue_free()
			_wall_mode_label_3d = null
	)


## 墙壁模式下: 在路径中间添加一个新墙节点
func _wall_add_node_at_center() -> void:
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null:
		return
	var side: String = "left" if _wall_handle_mode == 1 else "right"
	if node.has_method("wall_add_node"):
		# 在中间位置(0.5)添加, 如果已有则在最后两个节点中间
		var curve: WallCurve = node.call("get_wall_curve_left") if side == "left" else node.call("get_wall_curve_right")
		var last_t: float = 0.5
		if curve.nodes.size() >= 2:
			var t0: float = float(curve.nodes[curve.nodes.size() - 2]["t"])
			var t1: float = float(curve.nodes[curve.nodes.size() - 1]["t"])
			last_t = (t0 + t1) * 0.5
		node.call("wall_add_node", side, last_t, true)
	_refresh_selection_ui()


## 墙壁模式下: 删除最后一个非端点墙节点
func _wall_remove_last_node() -> void:
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null:
		return
	var side: String = "left" if _wall_handle_mode == 1 else "right"
	if node.has_method("wall_remove_node"):
		var curve: WallCurve = node.call("get_wall_curve_left") if side == "left" else node.call("get_wall_curve_right")
		if curve.nodes.size() > 2:
			node.call("wall_remove_node", side, curve.nodes.size() - 2)
	_refresh_selection_ui()


## U 键: 墙壁模式下快捷开关整面墙壁 (全部节点 active ↔ inactive)
func _wall_toggle_all() -> void:
	if _wall_handle_mode == 0:
		return
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null or not node.has_method("get_wall_curve_left"):
		return
	var side: String = "left" if _wall_handle_mode == 1 else "right"
	var curve: WallCurve = node.call("get_wall_curve_left") if side == "left" else node.call("get_wall_curve_right")
	# 判断当前状态: 如果大部分 active 则全关, 否则全开
	var active_count: int = 0
	for nd in curve.nodes:
		if bool(nd["active"]):
			active_count += 1
	var new_state: bool = active_count <= curve.nodes.size() / 2
	for nd in curve.nodes:
		nd["active"] = new_state
	# rebuild
	if node.has_method("_rebuild"):
		node.call("_rebuild")
	_show_wall_mode_label("墙壁 %s: %s" % [side, "全部开启" if new_state else "全部关闭"])
	_refresh_selection_ui()


## 直角窄道: 新增节点
func _right_angle_add_waypoint() -> void:
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var bid: String = String(_placed_blocks[idx].get("id", ""))
	if bid != "right_angle_path":
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null or not node.has_method("add_waypoint"):
		return
	node.call("add_waypoint")
	_refresh_selection_ui()
	print("[TrackEditor] 直角窄道: 新增节点 (共 %d)" % (node.get("waypoints") as Array).size())


## 直角窄道: 删除末尾节点
func _right_angle_remove_waypoint() -> void:
	if _selected_block_indices.is_empty():
		return
	var idx: int = int(_selected_block_indices[0])
	if idx < 0 or idx >= _placed_blocks.size():
		return
	var bid: String = String(_placed_blocks[idx].get("id", ""))
	if bid != "right_angle_path":
		return
	var node: Node3D = _placed_blocks[idx].get("node")
	if node == null or not node.has_method("remove_last_waypoint"):
		return
	node.call("remove_last_waypoint")
	_refresh_selection_ui()
	print("[TrackEditor] 直角窄道: 删除末尾节点 (共 %d)" % (node.get("waypoints") as Array).size())


## 获取道路中线的世界坐标点序列
func _get_road_center_world_points(node: Node3D, block_entry: Dictionary) -> Array[Vector3]:
	var bid: String = String(block_entry.get("id", ""))
	# NarrowPath: 有 _calc_bezier_points() 返回本地坐标 Array[Vector3]
	if node.has_method("_calc_bezier_points"):
		var local_pts: Array = node.call("_calc_bezier_points")
		var world_pts: Array[Vector3] = []
		for lp in local_pts:
			world_pts.append(node.global_transform * (lp as Vector3))
		return world_pts
	# FragileNarrow: 有 _bezier_at(t) 按参数采样
	if node.has_method("_bezier_at"):
		var world_pts: Array[Vector3] = []
		var sample_count: int = 48
		for i in range(sample_count + 1):
			var t: float = float(i) / float(sample_count)
			var local_pt: Vector3 = node.call("_bezier_at", t)
			world_pts.append(node.global_transform * local_pt)
		return world_pts
	# 路段积木: 有 get_end_world_pos
	if node.has_method("get_end_world_pos"):
		return [node.global_position, node.call("get_end_world_pos") as Vector3]
	# fallback: 用 -Z × length
	var length: float = 20.0
	if "length" in node:
		length = float(node.get("length"))
	var start: Vector3 = node.global_position
	var end_pos: Vector3 = start + node.global_transform.basis * Vector3(0.0, 0.0, -length)
	return [start, end_pos]


## 沿路径按归一化参数 t ∈ [0,1] 采样世界坐标
func _sample_path_at_t(points: Array[Vector3], cum_lengths: Array[float], total_len: float, t: float) -> Vector3:
	var target_len: float = t * total_len
	for i in range(1, cum_lengths.size()):
		if cum_lengths[i] >= target_len:
			var seg_start_len: float = cum_lengths[i - 1]
			var seg_len: float = cum_lengths[i] - seg_start_len
			var local_t: float = (target_len - seg_start_len) / maxf(seg_len, 0.001)
			return points[i - 1].lerp(points[i], local_t)
	return points[points.size() - 1]


## 沿路径按归一化参数 t ∈ [0,1] 采样切线方向 (非归一化)
func _sample_tangent_at_t(points: Array[Vector3], cum_lengths: Array[float], total_len: float, t: float) -> Vector3:
	var target_len: float = t * total_len
	for i in range(1, cum_lengths.size()):
		if cum_lengths[i] >= target_len:
			# 切线 = 当前段方向, 用前后点插值更平滑
			var seg_dir: Vector3 = points[i] - points[i - 1]
			if seg_dir.length() < 0.001:
				# 退化段, 向后看
				if i + 1 < points.size():
					return points[i + 1] - points[i]
				return Vector3(0.0, 0.0, -1.0)
			return seg_dir.normalized()
	# 末尾
	if points.size() >= 2:
		return (points[points.size() - 1] - points[points.size() - 2]).normalized()
	return Vector3(0.0, 0.0, -1.0)
