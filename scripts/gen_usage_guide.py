"""
生成 [简单飞车试验场] 使用指南 Excel
输出到 docs/使用指南_简单飞车试验场.xlsx

包含以下 Sheet:
  1. 项目概览          — 项目基本信息、技术栈、目录结构
  2. 操作指南          — 键盘/手柄操作映射、快捷键
  3. 架构总览          — 核心文件职责、数据流
  4. Tuner调参系统     — TAB页签说明、参数分类、使用方法
  5. 赛道编辑器        — 编辑器操作、积木/机关列表
  6. 开发新功能(表格)  — 填表即可开发: 编辑器机关/积木/3C/机制
  7. 工作流            — 开发流程、提交规范
  8. 高压线            — 绝对不能碰的规则
  9. 反馈与调整        — 留给各同学填写反馈
"""
import sys
from pathlib import Path
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side, numbers
from openpyxl.utils import get_column_letter

OUT = Path(__file__).parent.parent / "docs" / "使用指南_简单飞车试验场.xlsx"

# ============================================================
# 样式定义
# ============================================================
FONT_TITLE = Font(name="微软雅黑", size=16, bold=True, color="FFFFFF")
FONT_H1 = Font(name="微软雅黑", size=12, bold=True, color="1F4E79")
FONT_H2 = Font(name="微软雅黑", size=11, bold=True, color="2E75B6")
FONT_NORMAL = Font(name="微软雅黑", size=10)
FONT_CODE = Font(name="Consolas", size=10)
FONT_WARN = Font(name="微软雅黑", size=10, bold=True, color="CC0000")
FONT_HEADER = Font(name="微软雅黑", size=10, bold=True, color="FFFFFF")

FILL_TITLE = PatternFill("solid", fgColor="1F4E79")
FILL_HEADER = PatternFill("solid", fgColor="2E75B6")
FILL_LIGHT = PatternFill("solid", fgColor="D6E4F0")
FILL_WARN = PatternFill("solid", fgColor="FFC7CE")
FILL_GREEN = PatternFill("solid", fgColor="C6EFCE")
FILL_YELLOW = PatternFill("solid", fgColor="FFEB9C")

ALIGN_CENTER = Alignment(horizontal="center", vertical="center", wrap_text=True)
ALIGN_LEFT = Alignment(horizontal="left", vertical="center", wrap_text=True)
ALIGN_TOP = Alignment(horizontal="left", vertical="top", wrap_text=True)

THIN_BORDER = Border(
    left=Side(style="thin"),
    right=Side(style="thin"),
    top=Side(style="thin"),
    bottom=Side(style="thin"),
)


def set_col_widths(ws, widths: dict):
    for col, w in widths.items():
        ws.column_dimensions[get_column_letter(col)].width = w


def write_title_row(ws, row, title, col_span=6):
    """写一行大标题 (合并单元格)"""
    ws.merge_cells(start_row=row, start_column=1, end_row=row, end_column=col_span)
    cell = ws.cell(row=row, column=1, value=title)
    cell.font = FONT_TITLE
    cell.fill = FILL_TITLE
    cell.alignment = ALIGN_CENTER
    ws.row_dimensions[row].height = 30


def write_header_row(ws, row, headers: list):
    """写表头行"""
    for i, h in enumerate(headers, 1):
        cell = ws.cell(row=row, column=i, value=h)
        cell.font = FONT_HEADER
        cell.fill = FILL_HEADER
        cell.alignment = ALIGN_CENTER
        cell.border = THIN_BORDER
    ws.row_dimensions[row].height = 22


def write_data_row(ws, row, data: list, font=None, fill=None):
    """写数据行"""
    for i, d in enumerate(data, 1):
        cell = ws.cell(row=row, column=i, value=d)
        cell.font = font or FONT_NORMAL
        cell.alignment = ALIGN_LEFT
        cell.border = THIN_BORDER
        if fill:
            cell.fill = fill
    ws.row_dimensions[row].height = 18


def write_section(ws, row, title):
    """写分节标题"""
    cell = ws.cell(row=row, column=1, value=title)
    cell.font = FONT_H1
    ws.row_dimensions[row].height = 22
    return row + 1


# ============================================================
# Sheet 1: 项目概览
# ============================================================
def build_overview(wb):
    ws = wb.active
    ws.title = "项目概览"
    set_col_widths(ws, {1: 20, 2: 50, 3: 20, 4: 50})

    write_title_row(ws, 1, "🏎️ 简单飞车试验场 — 项目概览", 4)

    r = 3
    info = [
        ("项目名称", "简单飞车试验场"),
        ("引擎版本", "Godot 4.6.1 (Forward Plus)"),
        ("编程语言", "GDScript"),
        ("物理帧率", "240 Hz (physics_ticks_per_second=240)"),
        ("物理迭代", "32 次 (solver_iterations=32)"),
        ("默认场景", "track_qinghuaci.tscn (青花瓷赛道)"),
        ("项目定位", "QQ飞车风格 3C 飞车试验场, 用于验证赛车玩法原型"),
        ("支持人数", "1~2人 (键盘1P + 手柄2P, 分屏双人)"),
        ("核心特性", "漂移/松前/三喷/叠喷/钩索/撞墙反弹/赛道编辑器"),
    ]
    write_header_row(ws, r, ["属性", "值", "", ""]); r += 1
    for k, v in info:
        write_data_row(ws, r, [k, v, "", ""]); r += 1

    r += 1
    r = write_section(ws, r, "📂 核心目录结构")
    dirs = [
        ("文件/目录", "职责", "重要程度", "备注"),
        ("car.gd", "赛车物理核心 (5000+行)", "⭐⭐⭐⭐⭐", "受保护, 改动需先问负责人"),
        ("Camera3D.gd", "跟随相机 (Y稳定/前瞻/拉远/震屏)", "⭐⭐⭐⭐⭐", "受保护"),
        ("Tuner.gd", "调参UI系统 (TAB切换/保存加载)", "⭐⭐⭐⭐⭐", "受保护"),
        ("HUD.gd", "屏幕UI (速度/集气/弹字)", "⭐⭐⭐⭐", "受保护"),
        ("GrappleHook.gd", "钩索系统 (Apex风格)", "⭐⭐⭐⭐", ""),
        ("CoopMode.gd", "双人模式 (分屏+绳子)", "⭐⭐⭐⭐", ""),
        ("BoostFX.gd", "喷射火焰特效", "⭐⭐⭐", "可自由修改"),
        ("DriftFX.gd", "漂移特效 (胎印/发光)", "⭐⭐⭐", "可自由修改"),
        ("GlassShatterFX.gd", "撞墙玻璃渣特效", "⭐⭐", "可自由修改"),
        ("track_editor/", "赛道编辑器 (积木拼接)", "⭐⭐⭐⭐", ""),
        ("track_editor/TrackBlock.gd", "积木基类", "⭐⭐⭐⭐", "新积木继承此类"),
        ("track_editor/blocks/", "各种积木实现", "⭐⭐⭐", "新积木放这里"),
        ("SpeedPad.gd", "加速带 (FBX赛道用)", "⭐⭐⭐", ""),
        ("TrackWallTagger.gd", "赛道墙自动识别", "⭐⭐⭐", ""),
        ("tune.cfg", "参数配置文件 (Tuner保存)", "⭐⭐⭐⭐", "不要手动编辑"),
        ("defaults.cfg", "默认参数备份", "⭐⭐⭐", ""),
    ]
    write_header_row(ws, r, dirs[0]); r += 1
    for d in dirs[1:]:
        write_data_row(ws, r, list(d)); r += 1

    r += 1
    r = write_section(ws, r, "🔗 Autoload 单例")
    autos = [
        ("脚本", "用途"),
        ("TrackSwitcher.gd", "赛道切换管理"),
        ("CarSwitcher.gd", "F3 切换车型 (玉麒麟 ↔ SUV)"),
        ("SceneSelectorUI.gd", "场景选择UI"),
        ("TrackRunnerState.gd", "赛道编辑器运行状态"),
        ("CoopMode.gd", "双人共玩模式主控"),
        ("JoypadDebug.gd", "手柄调试信息"),
    ]
    write_header_row(ws, r, autos[0]); r += 1
    for a in autos[1:]:
        write_data_row(ws, r, list(a)); r += 1


# ============================================================
# Sheet 2: 操作指南
# ============================================================
def build_controls(wb):
    ws = wb.create_sheet("操作指南")
    set_col_widths(ws, {1: 18, 2: 22, 3: 22, 4: 40})

    write_title_row(ws, 1, "🎮 操作指南", 4)

    r = 3
    r = write_section(ws, r, "1P 键盘操作")
    keys = [
        ("功能", "按键", "Input Action", "说明"),
        ("油门/前进", "↑ (方向键上)", "accelerate", "持续按住加速"),
        ("刹车/倒车", "↓ (方向键下)", "brake", "低速时变为倒车"),
        ("左转", "← (方向键左)", "steer_left", ""),
        ("右转", "→ (方向键右)", "steer_right", ""),
        ("漂移", "Q", "drift", "按住进入漂移, 松开退出+小喷"),
        ("喷射/氮气", "W", "boost", "空中=空喷, 落地=落地喷, 漂移后=小喷/双喷, 有氮气=氮气"),
        ("氮气", "E", "nitro", "直接消耗氮气格喷射"),
        ("钩索", "空格", "grapple", "瞄准最近锚点发射钩索"),
        ("绳子追随", "Alt", "rope_follow", "绳子连接时, 吸附到另一名玩家位置"),
        ("绳子开关", "L", "-", "连接/断开双人绳子"),
        ("倒带", "R", "-", "按住回溯时间"),
        ("自定义位置", "小键盘0", "-", "进入FreeFly模式自由移动"),
        ("切车", "F3", "-", "玉麒麟 ↔ SUV"),
        ("调参面板", "TAB", "-", "显示/隐藏 Tuner 调参面板"),
        ("重置位置", "F5", "-", "重置车辆到出生点"),
    ]
    write_header_row(ws, r, keys[0]); r += 1
    for k in keys[1:]:
        write_data_row(ws, r, list(k)); r += 1

    r += 1
    r = write_section(ws, r, "2P 手柄操作")
    pad = [
        ("功能", "手柄按键", "Input Action", "说明"),
        ("油门/前进", "左摇杆 ↑", "p2_accelerate", ""),
        ("刹车/倒车", "左摇杆 ↓", "p2_brake", ""),
        ("左转", "左摇杆 ←", "p2_steer_left", ""),
        ("右转", "左摇杆 →", "p2_steer_right", ""),
        ("漂移", "B键", "p2_drift", ""),
        ("喷射", "L3 (左摇杆按下)", "p2_boost", ""),
        ("氮气", "RT (右扳机)", "p2_nitro", ""),
        ("钩索", "X键", "p2_grapple", ""),
        ("绳子追随", "A键", "p2_rope_follow", ""),
        ("重置位置", "LT (左扳机)", "p2_reset", ""),
    ]
    write_header_row(ws, r, pad[0]); r += 1
    for p in pad[1:]:
        write_data_row(ws, r, list(p)); r += 1

    r += 1
    r = write_section(ws, r, "赛道编辑器操作")
    editor = [
        ("功能", "按键", "", "说明"),
        ("放置积木", "鼠标左键", "", "选中积木后点击放置"),
        ("旋转视角", "鼠标右键拖动", "", ""),
        ("缩放", "滚轮", "", ""),
        ("快速选积木", "数字键 1~5", "", "直道短/长, 90°左/右弯, U弯"),
        ("快速选机关", "数字键 6~9,0", "", "加速带/锚点/出生点/终点/墙"),
        ("锚点工具", "A键", "", "切换到钩索锚点放置"),
        ("撤销", "Ctrl+Z", "", "撤销最近一次放置"),
        ("删除", "Delete", "", "hover在积木上按Delete删除"),
        ("测试赛道", "F5", "", "生成临时场景并切换测试"),
        ("取消选择", "ESC", "", "切回选择工具"),
    ]
    write_header_row(ws, r, editor[0]); r += 1
    for e in editor[1:]:
        write_data_row(ws, r, list(e)); r += 1


# ============================================================
# Sheet 3: 架构总览
# ============================================================
def build_architecture(wb):
    ws = wb.create_sheet("架构总览")
    set_col_widths(ws, {1: 25, 2: 50, 3: 30, 4: 30})

    write_title_row(ws, 1, "🏗️ 架构总览", 4)

    r = 3
    r = write_section(ws, r, "核心数据流")
    flow = [
        ("阶段", "描述", "涉及文件", "输出"),
        ("1. 输入读取", "读取键盘/手柄输入, 映射为油门/转向/漂移/喷射", "car.gd _read_input()", "throttle, steer, drift_pressed"),
        ("2. 状态转换", "根据输入+条件判断漂移入/出, 松前, 三喷", "car.gd _try_start_drift() 等", "State.NORMAL ↔ DRIFT"),
        ("3. 物理力计算", "引擎推力+摩擦+喷射+空喷下压力+反打减速", "car.gd _apply_engine_and_brake()", "apply_central_force"),
        ("4. 地面贴附", "防弹+贴附, 消除弹跳", "car.gd _apply_ground_stick()", "速度修正"),
        ("5. 撞墙反弹", "硬碰硬反弹+弹墙掉头+防吸住", "car.gd _integrate_forces()", "速度反弹+yaw动画"),
        ("6. 视觉更新", "车身侧倾/yaw偏移/地面法线对齐", "car.gd _update_visuals()", "车身Transform"),
        ("7. 信号发射", "通知HUD/Camera/特效", "car.gd emit_signal()", "各种信号"),
        ("8. HUD响应", "弹字/集气槽/速度显示", "HUD.gd", "UI更新"),
        ("9. 镜头跟随", "Y稳定+前瞻+拉远+震屏", "Camera3D.gd", "相机Transform"),
        ("10. 特效播放", "火焰/胎印/玻璃渣", "BoostFX/DriftFX/GlassShatterFX", "粒子/mesh"),
    ]
    write_header_row(ws, r, flow[0]); r += 1
    for f in flow[1:]:
        write_data_row(ws, r, list(f)); r += 1

    r += 1
    r = write_section(ws, r, "Tuner 调参系统架构")
    tuner = [
        ("概念", "说明", "示例", ""),
        ("__page", "顶级页签 (左侧TAB栏)", "🚗 基础移动", ""),
        ("__group", "页内大标题 (黄色)", "极速 & 油门", ""),
        ("__sub", "小标题 (浅蓝)", "", ""),
        ("kind", "参数应用目标", "car / cam / fx / grapple / coop / boost_fx", ""),
        ("PARAMS", "car.gd 主参数数组", "360+ 个参数", ""),
        ("CAM_PARAMS", "Camera3D.gd 参数", "镜头相关", ""),
        ("FX_PARAMS", "DriftFX.gd 参数", "漂移特效", ""),
        ("BOOST_FX_PARAMS", "BoostFX.gd 参数", "喷射火焰", ""),
        ("CAR_MESH_PARAMS", "YuqilinTuning.gd 参数", "车身外观", ""),
        ("tune.cfg", "参数持久化文件", "[tune] + [range] + [curves] + [color]", ""),
    ]
    write_header_row(ws, r, tuner[0]); r += 1
    for t in tuner[1:]:
        write_data_row(ws, r, list(t)); r += 1

    r += 1
    r = write_section(ws, r, "赛道编辑器架构")
    te = [
        ("组件", "文件", "职责", ""),
        ("编辑器主控", "track_editor/TrackEditor.gd", "3D视口+UI面板+放置/选中/删除逻辑", ""),
        ("积木基类", "track_editor/TrackBlock.gd", "程序化mesh+碰撞+入口/出口锚点+磁吸对齐", ""),
        ("赛道数据", "track_editor/RaceTrackData.gd", "序列化: 积木列表→.tres文件", ""),
        ("赛道运行器", "track_editor/TrackRunner.gd", "加载.tres→实例化积木→生成可跑赛道", ""),
        ("积木实现", "track_editor/blocks/Block_*.gd", "各种积木的具体几何+参数", ""),
    ]
    write_header_row(ws, r, te[0]); r += 1
    for t in te[1:]:
        write_data_row(ws, r, list(t)); r += 1


# ============================================================
# Sheet 4: Tuner调参系统
# ============================================================
def build_tuner(wb):
    ws = wb.create_sheet("Tuner调参系统")
    set_col_widths(ws, {1: 20, 2: 30, 3: 50})

    write_title_row(ws, 1, "🎛️ Tuner 调参系统使用说明", 3)

    r = 3
    r = write_section(ws, r, "TAB 页签一览")
    tabs = [
        ("页签名", "包含内容", "说明"),
        ("🚗 基础移动", "极速/油门/转向/倒车/摩擦", "赛车基础手感"),
        ("🎯 漂移系统", "漂移入出/松前/三喷/反打/集气/打滑", "漂移核心玩法"),
        ("💨 喷射", "小喷/双喷/氮气/叠喷/漂移氮气", "加速系统"),
        ("✨ 视觉", "车身姿态/侧倾/yaw偏移", "视觉表现"),
        ("⛰️ 地面物理", "防弹贴附/法线投影/下压力", "地面行驶稳定性"),
        ("🧱 撞墙物理", "墙判定/弹墙推力/硬碰硬反弹/弹墙掉头", "撞墙手感"),
        ("⛰️ 坡道", "上坡辅助/坡道对齐/重力补偿", "坡道行驶"),
        ("🛫 空喷/落地喷", "空喷/落地喷/落地缓冲", "空中玩法"),
        ("🕒 倒带/自定义", "倒带(R键)/自定义位置(KP0)", "调试工具"),
    ]
    write_header_row(ws, r, tabs[0]); r += 1
    for t in tabs[1:]:
        write_data_row(ws, r, list(t)); r += 1

    r += 1
    r = write_section(ws, r, "使用方法")
    usage = [
        "1. 游戏中按 TAB 键打开调参面板",
        "2. 左侧竖排 TAB 切换不同页签",
        "3. 每个参数有 Slider + SpinBox, 拖动或输入数值即时生效",
        "4. 修改后自动保存到 tune.cfg (无需手动保存)",
        "5. 带 📈 按钮的参数支持曲线编辑 (点击打开曲线编辑器)",
        "6. 参数 tooltip 悬停显示详细说明",
        "7. 所有参数支持 min/max/step 范围限制",
    ]
    for u in usage:
        ws.cell(row=r, column=1, value=u).font = FONT_NORMAL; r += 1

    r += 1
    r = write_section(ws, r, "参数 kind 分类")
    kinds = [
        ("kind值", "目标节点", "说明"),
        ("car", "car.gd (RigidBody3D)", "赛车物理参数, 最多"),
        ("cam", "Camera3D.gd", "镜头参数"),
        ("fx", "DriftFX.gd", "漂移特效参数"),
        ("boost_fx", "BoostFX.gd", "喷射火焰特效参数"),
        ("car_mesh", "YuqilinTuning.gd", "车身外观参数"),
        ("grapple", "GrappleHook.gd", "钩索参数"),
        ("coop", "CoopMode.gd", "双人模式/绳子参数"),
    ]
    write_header_row(ws, r, kinds[0]); r += 1
    for k in kinds[1:]:
        write_data_row(ws, r, list(k)); r += 1


# ============================================================
# Sheet 5: 赛道编辑器
# ============================================================
def build_track_editor(wb):
    ws = wb.create_sheet("赛道编辑器")
    set_col_widths(ws, {1: 18, 2: 20, 3: 15, 4: 40})

    write_title_row(ws, 1, "🛤️ 赛道编辑器使用指南", 4)

    r = 3
    r = write_section(ws, r, "路段积木列表")
    blocks = [
        ("积木ID", "显示名", "热键", "说明"),
        ("straight_short", "直道(短)", "1", "短直道, 可调长度/坡度"),
        ("straight_long", "直道(长)", "2", "长直道"),
        ("turn_90_left", "90°左弯", "3", "可调半径/banking"),
        ("turn_90_right", "90°右弯", "4", "可调半径/banking"),
        ("turn_180", "U形弯", "5", "180度掉头弯"),
    ]
    write_header_row(ws, r, blocks[0]); r += 1
    for b in blocks[1:]:
        write_data_row(ws, r, list(b)); r += 1

    r += 1
    r = write_section(ws, r, "机关列表")
    mechs = [
        ("机关ID", "显示名", "热键", "说明"),
        ("speed_pad", "🟨 加速带", "6", "车经过时给予瞬时增速+持续推力"),
        ("anchor", "🪝 钩索锚点", "7", "钩索可以钩中的锚点"),
        ("spawn_point", "🟢 出生点", "8", "车辆出生位置 (全场唯一)"),
        ("finish_line", "🏁 终点", "9", "终点线"),
        ("wall", "🧱 墙", "0", "独立墙体"),
    ]
    write_header_row(ws, r, mechs[0]); r += 1
    for m in mechs[1:]:
        write_data_row(ws, r, list(m)); r += 1

    r += 1
    r = write_section(ws, r, "积木可编辑参数 (选中后右侧面板)")
    params = [
        ("积木", "参数", "范围", "说明"),
        ("直道(短)", "length / slope_total_deg / entry_width / exit_width / wall_height", "3~60m / -45~45° / 3~80m", "长度/坡度/宽度/墙高"),
        ("90°弯", "radius / banking_deg / entry_width / exit_width / wall_height", "5~60m / -30~30°", "半径/倾斜/宽度/墙高"),
        ("上坡道", "length / height / entry_width / exit_width / wall_height", "3~60m / 0.5~20m", "正弦曲线曲面坡道"),
        ("加速带", "width / length / thickness / speed_kick / duration / color_r/g/b", "1~60m / 0~100m/s / 0~5s", "尺寸/推力/颜色"),
        ("所有积木", "wall_left_in / wall_left_out / wall_right_in / wall_right_out", "true/false", "4段墙独立开关"),
    ]
    write_header_row(ws, r, params[0]); r += 1
    for p in params[1:]:
        write_data_row(ws, r, list(p)); r += 1

    r += 1
    r = write_section(ws, r, "磁吸对齐原理")
    ws.cell(row=r, column=1, value="每块积木有 EntryAnchor (入口) 和 ExitAnchor (出口)").font = FONT_NORMAL; r += 1
    ws.cell(row=r, column=1, value="放置新积木时: new.global_transform = prev.ExitAnchor.global × new.EntryAnchor.local.inverse()").font = FONT_CODE; r += 1
    ws.cell(row=r, column=1, value="即: 新积木的入口对齐到前一块的出口, 实现无缝拼接").font = FONT_NORMAL; r += 1


# ============================================================
# Sheet 6: 开发新功能 (核心表格)
# ============================================================
def build_dev_guide(wb):
    ws = wb.create_sheet("开发新功能(填表)")
    set_col_widths(ws, {1: 18, 2: 25, 3: 35, 4: 35, 5: 35, 6: 25})

    write_title_row(ws, 1, "🔧 开发新功能 — 填表即可开发", 6)

    # --- 编辑器机关 ---
    r = 3
    r = write_section(ws, r, "A. 开发新的 [编辑器机关]")
    ws.cell(row=r, column=1, value="说明: 机关是放置在赛道上、车经过时触发效果的物体 (如加速带、减速带、弹射器、传送门等)").font = FONT_NORMAL; r += 2

    mech_headers = ["步骤", "你需要填写的内容", "示例 (加速带)", "你的新机关", "说明", "对应代码位置"]
    write_header_row(ws, r, mech_headers); r += 1
    mech_data = [
        ("1. 机关ID", "英文标识符 (小写+下划线)", "speed_pad", "", "唯一标识, 用于序列化", "MECHANISM_INFO.id"),
        ("2. 显示名", "中文名 (带emoji更好)", "🟨 加速带", "", "编辑器UI显示", "MECHANISM_INFO.label"),
        ("3. 热键", "数字键 6~0 中未占用的", "KEY_6", "", "快速选择热键", "MECHANISM_INFO.hotkey"),
        ("4. 触发方式", "Area3D / 碰撞 / 定时", "Area3D (车进入触发)", "", "车如何触发机关", "Block_XXX._runtime_init_trigger()"),
        ("5. 触发效果", "给车施加什么效果", "沿车头方向瞬时增速+持续推力", "", "核心玩法逻辑", "Block_XXX._on_car_entered()"),
        ("6. 可编辑参数", "列出所有可调参数", "width/length/speed_kick/duration/color", "", "编辑器右侧面板显示", "get_editable_params()"),
        ("7. 视觉表现", "机关长什么样", "黄色发光矩形面片", "", "MeshInstance3D", "_rebuild() 中构建"),
        ("8. 碰撞层", "collision_layer / mask", "layer=0, mask=2 (探测车)", "", "必须匹配car的layer=2", "Area3D设置"),
        ("9. 冷却机制", "是否需要冷却防重复触发", "0.5秒冷却", "", "防止同一次接触重复触发", "_recent_triggered字典"),
        ("10. Tuner参数", "是否需要加到Tuner调参", "speed_pad_sustain_power等", "", "如需运行时调参则加", "Tuner.gd PARAMS"),
    ]
    for d in mech_data:
        write_data_row(ws, r, list(d)); r += 1

    r += 1
    ws.cell(row=r, column=1, value="📁 文件创建清单:").font = FONT_H2; r += 1
    files_mech = [
        "  1. track_editor/blocks/Block_你的机关名.gd  (继承 Node3D, 参考 Block_SpeedPad.gd)",
        "  2. 在 TrackEditor.gd 的 BLOCK_LIBRARY 中注册 tscn 路径",
        "  3. 在 TrackEditor.gd 的 MECHANISM_INFO 中添加显示信息",
        "  4. (可选) 如需 Tuner 调参: 在 Tuner.gd PARAMS 中添加参数",
    ]
    for f in files_mech:
        ws.cell(row=r, column=1, value=f).font = FONT_CODE; r += 1

    # --- 编辑器积木 ---
    r += 2
    r = write_section(ws, r, "B. 开发新的 [编辑器积木]")
    ws.cell(row=r, column=1, value="说明: 积木是赛道的路段组成部分 (如直道、弯道、坡道、环形道等), 通过入口/出口锚点磁吸拼接").font = FONT_NORMAL; r += 2

    block_headers = ["步骤", "你需要填写的内容", "示例 (上坡道)", "你的新积木", "说明", "对应代码位置"]
    write_header_row(ws, r, block_headers); r += 1
    block_data = [
        ("1. 积木ID", "英文标识符", "ramp_up", "", "唯一标识", "block_id"),
        ("2. 显示名", "中文名", "上坡道", "", "UI显示", "BLOCK_INFO.label"),
        ("3. 热键", "数字键 1~5 中未占用的", "无 (用UI选)", "", "快速选择", "BLOCK_INFO.hotkey"),
        ("4. 几何形状", "路面形状描述", "正弦曲线曲面, 入口平→出口高", "", "核心mesh生成逻辑", "_build_smooth_ramp()"),
        ("5. 碰撞方式", "BoxShape / ConvexPolygon / Trimesh", "Trimesh (曲面精确碰撞)", "", "物理碰撞", "create_trimesh_collision()"),
        ("6. 入口/出口位置", "EntryAnchor和ExitAnchor的位置", "入口(0,0,+hl), 出口(0,height,-hl)", "", "磁吸对齐关键", "_build_entry_exit()"),
        ("7. 可编辑参数", "列出所有可调参数", "length/height/entry_width/exit_width/wall_height", "", "编辑器面板", "get_editable_params()"),
        ("8. 墙支持", "是否需要两侧墙", "是, 沿曲面高度变化", "", "防止车飞出", "_build_ramp_walls()"),
        ("9. 路缘/装饰", "是否需要路缘红条/中心蓝带", "是", "", "视觉美化", "_build_kerbs()/_build_center_pattern()"),
        ("10. 分段数", "视觉mesh分段 / 碰撞mesh分段", "视觉512段 / 碰撞128段", "", "精度vs性能", "SEGMENTS / COLLISION_SEGMENTS"),
    ]
    for d in block_data:
        write_data_row(ws, r, list(d)); r += 1

    r += 1
    ws.cell(row=r, column=1, value="📁 文件创建清单:").font = FONT_H2; r += 1
    files_block = [
        "  1. track_editor/blocks/Block_你的积木名.gd  (继承 TrackBlock, 参考 Block_Ramp.gd)",
        "  2. track_editor/blocks/你的积木名.tscn  (场景文件, 挂上面的脚本)",
        "  3. 在 TrackEditor.gd 的 BLOCK_LIBRARY 中注册",
        "  4. 在 TrackEditor.gd 的 BLOCK_INFO 中添加显示信息",
    ]
    for f in files_block:
        ws.cell(row=r, column=1, value=f).font = FONT_CODE; r += 1

    # --- 3C 相关 ---
    r += 2
    r = write_section(ws, r, "C. 开发新的 [3C相关] 功能")
    ws.cell(row=r, column=1, value="说明: 3C = Character(赛车) + Camera(镜头) + Control(操控). 新增3C功能必须走Tuner注册+默认关闭").font = FONT_NORMAL; r += 2

    cc_headers = ["步骤", "你需要填写的内容", "示例 (空喷)", "你的新功能", "说明", "对应代码位置"]
    write_header_row(ws, r, cc_headers); r += 1
    cc_data = [
        ("1. 功能名称", "中文名", "空喷 (空中按W)", "", "Tuner分组标题", "__group"),
        ("2. 触发条件", "什么时候触发", "空中+按W+腾空>0.18秒", "", "判定逻辑", "car.gd _try_boost_w()"),
        ("3. 效果描述", "触发后做什么", "沿车头方向持续推力+下压力", "", "物理效果", "car.gd _start_boost()"),
        ("4. 参数列表", "需要哪些可调参数", "enabled/min_air_time/power/time/downforce/shake", "", "全部加到Tuner", "Tuner.gd PARAMS"),
        ("5. 默认值", "每个参数的默认值", "enabled=1, min_air_time=0.18, power=60, time=0.8", "", "保守值, 默认关闭最安全", "@export 默认值"),
        ("6. 信号", "需要通知哪些系统", "boost_triggered → HUD弹字 + Camera震屏 + BoostFX火焰", "", "解耦通信", "emit_signal()"),
        ("7. 曲线", "是否需要力度曲线", "air_boost_curve (力随时间衰减)", "", "Tuner曲线编辑器", "@export var xxx_curve: Curve"),
        ("8. 视觉反馈", "玩家如何知道触发了", "震屏+火焰+HUD弹字'空喷!'", "", "手感反馈", "camera_shake + BoostFX"),
        ("9. 音效", "需要什么音效", "(待加)", "", "AudioStreamPlayer3D", ""),
        ("10. 高压线检查", "是否会影响已有3C手感", "不会, 新增独立功能", "", "⚠️ 影响已有则需先问负责人!", "docs/01_HIGH_VOLTAGE.md"),
    ]
    for d in cc_data:
        write_data_row(ws, r, list(d)); r += 1

    r += 1
    ws.cell(row=r, column=1, value="📁 代码修改清单:").font = FONT_H2; r += 1
    files_cc = [
        "  1. car.gd: 添加 @export 变量 + 实现逻辑函数",
        "  2. Tuner.gd PARAMS: 注册参数 (含 __page/__group/tooltip/min/max/step)",
        "  3. HUD.gd: (可选) 添加弹字/UI显示",
        "  4. Camera3D.gd: (可选) 添加镜头效果",
        "  5. BoostFX.gd / 新FX: (可选) 添加特效",
    ]
    for f in files_cc:
        ws.cell(row=r, column=1, value=f).font = FONT_CODE; r += 1

    # --- 新机制 ---
    r += 2
    r = write_section(ws, r, "D. 开发新的 [机制]")
    ws.cell(row=r, column=1, value="说明: 机制是独立的游戏系统 (如钩索、双人绳子、计时赛、道具系统等), 通常作为独立脚本+Autoload实现").font = FONT_NORMAL; r += 2

    sys_headers = ["步骤", "你需要填写的内容", "示例 (钩索系统)", "你的新机制", "说明", "对应代码位置"]
    write_header_row(ws, r, sys_headers); r += 1
    sys_data = [
        ("1. 机制名称", "中文名", "钩索系统 (Apex探路者风格)", "", "功能定位", ""),
        ("2. 核心玩法", "一句话描述", "按空格射出钩索, 钩中锚点后拉向目标", "", "玩法核心", ""),
        ("3. 状态机", "有哪些状态", "IDLE→SHOOTING→ATTACHED→RELEASING", "", "状态流转", "enum State"),
        ("4. 与car交互", "如何影响赛车", "apply_central_force拉力 + 释放冲量", "", "物理接口", "car.apply_central_force()"),
        ("5. 输入绑定", "用什么按键", "空格(1P) / X键(2P)", "", "project.godot [input]", "Input.is_action_just_pressed()"),
        ("6. 参数列表", "需要哪些可调参数", "max_distance/pull_force_max/pull_duration/...", "", "全部加Tuner", "Tuner.gd kind=xxx"),
        ("7. 场景需求", "需要什么场景元素", "GrappleAnchor锚点 (放在赛道上)", "", "编辑器机关", "GrappleAnchor.gd"),
        ("8. 视觉表现", "绳子/特效怎么画", "CylinderMesh绳子 + 发光材质", "", "MeshInstance3D", "_build_rope_mesh()"),
        ("9. 信号通知", "通知哪些系统", "grapple_state_changed → HUD + Camera", "", "解耦", "signal grapple_state_changed"),
        ("10. Autoload?", "是否需要全局单例", "否 (挂在car子节点)", "", "看是否跨场景", "project.godot [autoload]"),
    ]
    for d in sys_data:
        write_data_row(ws, r, list(d)); r += 1

    r += 1
    ws.cell(row=r, column=1, value="📁 文件创建清单:").font = FONT_H2; r += 1
    files_sys = [
        "  1. 你的机制名.gd  (核心逻辑脚本)",
        "  2. 你的机制名.tscn  (场景文件, 如需要)",
        "  3. Tuner.gd: 注册参数 (新建 kind 或复用已有 kind)",
        "  4. project.godot: (如需Autoload) 注册自动加载",
        "  5. car.gd: (如需) 添加交互接口函数",
        "  6. HUD.gd: (如需) 添加UI显示",
    ]
    for f in files_sys:
        ws.cell(row=r, column=1, value=f).font = FONT_CODE; r += 1


# ============================================================
# Sheet 7: 工作流
# ============================================================
def build_workflow(wb):
    ws = wb.create_sheet("工作流")
    set_col_widths(ws, {1: 8, 2: 25, 3: 55, 4: 25})

    write_title_row(ws, 1, "📋 开发工作流", 4)

    r = 3
    r = write_section(ws, r, "标准开发流程")
    flow = [
        ("序号", "步骤", "详细说明", "产出"),
        ("1", "拉取最新代码", "git pull origin feature/car-handling", "最新代码"),
        ("2", "打开 Godot 编辑器", "用 Godot 4.6.1 打开项目", "确认无报错"),
        ("3", "确认需求", "明确要开发什么功能, 参考本指南的'开发新功能'表格", "需求表格"),
        ("4", "创建功能分支", "git checkout -b feature/你的功能名", "新分支"),
        ("5", "编写代码", "参考已有实现 (Block_SpeedPad / GrappleHook 等)", "代码文件"),
        ("6", "注册 Tuner 参数", "所有新参数必须加到 Tuner.gd 对应位置", "参数可调"),
        ("7", "运行测试", "F5 运行游戏, 验证功能正常", "功能验证"),
        ("8", "检查日志", "查看 godot.log 无 ERROR/SCRIPT ERROR", "无报错"),
        ("9", "提交代码", "git add -A && git commit -m '描述'", "git提交"),
        ("10", "推送+合并", "git push && 发起 MR/PR", "代码合入"),
    ]
    write_header_row(ws, r, flow[0]); r += 1
    for f in flow[1:]:
        write_data_row(ws, r, list(f)); r += 1

    r += 1
    r = write_section(ws, r, "Tuner 参数注册规范")
    tuner_rules = [
        ("规则", "说明", "示例", ""),
        ("必须有 tooltip", "每个参数必须有中文说明", "\"落地瞬间冲击吸收比例。0=保留下落动能, 1=完全吸收\"", ""),
        ("必须有 min/max/step", "范围和步长必须合理", "[0.0, 1.0, 0.05]", ""),
        ("必须归属正确 kind", "car/cam/fx/grapple/coop/boost_fx", "kind=\"car\" (默认)", ""),
        ("必须放对 __page/__group", "找到逻辑上归属的页签和分组", "__page=🛫 空喷/落地喷, __group=空喷", ""),
        ("新功能默认关闭", "用 enabled=0 作为开关", "[\"xxx_enabled\", \"XX开关\", 0, 1, 1, ...]", ""),
        ("不能改已有参数默认值", "已调好的参数是神圣的", "⚠️ 违反=高压线!", ""),
    ]
    write_header_row(ws, r, tuner_rules[0]); r += 1
    for t in tuner_rules[1:]:
        write_data_row(ws, r, list(t)); r += 1

    r += 1
    r = write_section(ws, r, "Git 提交规范")
    git_rules = [
        "1. 只有负责人明确命令时才提交 git",
        "2. 所有代码+资源+配置 cfg 都必须上传到 git",
        "3. commit message 必须整合相比上一次版本改动了什么",
        "4. 格式: '功能名: 改动摘要\\n\\n详细列表'",
        "5. 不要提交 .godot/ 缓存目录 (已在 .gitignore 中)",
    ]
    for g in git_rules:
        ws.cell(row=r, column=1, value=g).font = FONT_NORMAL; r += 1


# ============================================================
# Sheet 8: 高压线
# ============================================================
def build_high_voltage(wb):
    ws = wb.create_sheet("⚡高压线")
    set_col_widths(ws, {1: 8, 2: 40, 3: 50})

    write_title_row(ws, 1, "⚡ 高压线 — 绝对不能碰的规则", 3)

    r = 3
    r = write_section(ws, r, "🔴 绝对禁止")
    rules = [
        ("序号", "规则", "原因"),
        ("1", "禁止擅自修改 car.gd 中已调好的 @export 默认值", "基础3C经过几十轮调校, 动一个参数牵一发动全身"),
        ("2", "禁止擅自修改 Camera3D.gd 的镜头跟随逻辑", "镜头手感是系统性平衡"),
        ("3", "禁止擅自修改 Tuner.gd 的参数定义结构", "改错了整个调参系统会崩"),
        ("4", "禁止擅自修改 tune.cfg 中用户调过的参数值", "用户调过的值是神圣的"),
        ("5", "禁止删除已有功能或改已有功能的默认行为", "新功能必须'新加+默认关闭', 不能关旧的"),
        ("6", "禁止未经测试就提交代码", "GDScript动态语言, lint不能保证无parse error"),
        ("7", "禁止手动编辑 tune.cfg", "只能通过 Tuner UI 修改, 否则格式可能损坏"),
    ]
    write_header_row(ws, r, rules[0]); r += 1
    for ru in rules[1:]:
        write_data_row(ws, r, list(ru), fill=FILL_WARN); r += 1

    r += 1
    r = write_section(ws, r, "🟡 需要先问负责人")
    ask = [
        ("序号", "场景", "怎么做"),
        ("1", "想改 car.gd 中的物理逻辑", "在群里声明: 文件+改动+原因+影响, 等负责人回复'同意'"),
        ("2", "想改 Camera3D.gd 的镜头行为", "同上"),
        ("3", "想改 HUD.gd 的信号协议", "同上"),
        ("4", "想改 Tuner.gd 的 UI 构建逻辑", "同上"),
        ("5", "想改 project.godot 的物理配置", "同上"),
    ]
    write_header_row(ws, r, ask[0]); r += 1
    for a in ask[1:]:
        write_data_row(ws, r, list(a), fill=FILL_YELLOW); r += 1

    r += 1
    r = write_section(ws, r, "🟢 可以自由修改")
    free = [
        ("序号", "范围", "说明"),
        ("1", "新增独立 .gd 脚本", "新功能用新文件, 不改已有核心"),
        ("2", "新增特效 (BoostFX/DriftFX/GlassShatterFX 等)", "特效文件不受保护"),
        ("3", "新增赛道/场景", "track_xxx.tscn"),
        ("4", "新增编辑器积木/机关", "track_editor/blocks/Block_XXX.gd"),
        ("5", "新增 Tuner 参数 (新 __group, 默认关闭)", "扩展不破坏"),
        ("6", "修复明确的 bug (parse error/空指针)", "修完在 CHANGELOG 说明"),
        ("7", "工具脚本 (scripts/ 目录)", "辅助工具随便加"),
    ]
    write_header_row(ws, r, free[0]); r += 1
    for f in free[1:]:
        write_data_row(ws, r, list(f), fill=FILL_GREEN); r += 1

    r += 1
    r = write_section(ws, r, "受保护文件列表")
    protected = [
        ("文件", "保护原因", "可以做的"),
        ("car.gd", "赛车物理核心, 80%是调过的平衡点", "只能新增@export+新函数, 不改已有逻辑"),
        ("Camera3D.gd", "镜头跟随/拉远/稳定都被反复调过", "只能新增参数, 不改已有行为"),
        ("Tuner.gd", "调参UI+参数定义", "只能新增参数条目, 不改结构"),
        ("HUD.gd", "信号协议已与car.gd绑定", "只能新增显示, 不改已有信号"),
        ("tune.cfg", "用户调过的参数值", "只能通过Tuner UI修改"),
    ]
    write_header_row(ws, r, protected[0]); r += 1
    for p in protected[1:]:
        write_data_row(ws, r, list(p)); r += 1


# ============================================================
# Sheet 9: 反馈与调整
# ============================================================
def build_feedback(wb):
    ws = wb.create_sheet("反馈与调整")
    set_col_widths(ws, {1: 12, 2: 15, 3: 20, 4: 40, 5: 20, 6: 20})

    write_title_row(ws, 1, "📝 反馈与调整记录", 6)

    r = 3
    ws.cell(row=r, column=1, value="请各位同学在下方记录使用过程中的问题、建议和调整需求:").font = FONT_NORMAL; r += 2

    headers = ["日期", "反馈人", "类型", "描述", "优先级", "状态"]
    write_header_row(ws, r, headers); r += 1

    # 类型选项说明
    types = ["Bug", "功能建议", "参数调整", "文档补充", "其他"]
    priorities = ["P0-紧急", "P1-重要", "P2-一般", "P3-低"]
    statuses = ["待处理", "处理中", "已完成", "搁置"]

    # 预填几行示例
    examples = [
        ("2026-05-21", "示例", "参数调整", "漂移入弯速度门槛太高, 建议从30降到25", "P2-一般", "待处理"),
        ("", "", "", "", "", ""),
        ("", "", "", "", "", ""),
        ("", "", "", "", "", ""),
        ("", "", "", "", "", ""),
    ]
    for e in examples:
        write_data_row(ws, r, list(e)); r += 1

    # 留出 50 行空白供填写
    for _ in range(50):
        write_data_row(ws, r, ["", "", "", "", "", ""]); r += 1

    r += 2
    ws.cell(row=r, column=1, value="类型选项: " + " / ".join(types)).font = FONT_NORMAL; r += 1
    ws.cell(row=r, column=1, value="优先级选项: " + " / ".join(priorities)).font = FONT_NORMAL; r += 1
    ws.cell(row=r, column=1, value="状态选项: " + " / ".join(statuses)).font = FONT_NORMAL; r += 1


# ============================================================
# 主函数
# ============================================================
def main():
    wb = Workbook()

    build_overview(wb)
    build_controls(wb)
    build_architecture(wb)
    build_tuner(wb)
    build_track_editor(wb)
    build_dev_guide(wb)
    build_workflow(wb)
    build_high_voltage(wb)
    build_feedback(wb)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    wb.save(str(OUT))
    print(f"[OK] Usage guide generated: {OUT}")
    print(f"   Sheets: {len(wb.sheetnames)}")


if __name__ == "__main__":
    main()
