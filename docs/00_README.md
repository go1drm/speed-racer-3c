# 简单飞车试验场 — 项目文档总入口

> 一个用 Godot 4.6 制作的 QQ 飞车风格 3C 飞车试验场。
> 基础3C 第一版定型稿: **2026-05-12**

---

## 📑 文档导航

| 文档 | 说明 |
|---|---|
| [00_README.md](./00_README.md) | (本文档) 项目总入口、文档导航 |
| [01_HIGH_VOLTAGE.md](./01_HIGH_VOLTAGE.md) | **🔥 基础3C 高压线** — 改动这些代码/参数前必须先问用户! |
| [02_CODE_INDEX.md](./02_CODE_INDEX.md) | 代码知识库索引 — 每个文件 / 每个函数的职责说明 |
| [03_FEATURES.xlsx](./03_FEATURES.xlsx) | 3C 功能 + 参数总表 (Excel) |
| [CHANGELOG.md](./CHANGELOG.md) | 改动日志 (按时间倒序) |

---

## 🚀 快速开始

### 启动游戏
- **默认场景**: `track_qinghuaci.tscn` (青花瓷赛道)
- **备选场景**: `track.tscn` (合并 trimesh 大赛道)
- **F3** = 切车 (玉麒麟 ↔ SUV)
- **TAB** = 显示/隐藏 Tuner 调参面板
- **WSAD/方向键** = 油门刹车转向; **Q** = 漂移; **W** = 喷射; **E** = 氮气

### 启用文件日志
在 `project.godot` 已默认开启 `[debug] file_logging/enable_file_logging=true`,
日志路径: `%APPDATA%\Godot\app_userdata\简单飞车试验场\logs\godot*.log`

---

## 🎯 核心 3C 模块 (基础3C定型版 V1)

| 模块 | 主代码 | Tuner 页签 | 关键功能 |
|---|---|---|---|
| 基础移动 | `car.gd` | 🚗 基础移动 | 引擎/刹车/转向/倒车/摩擦 |
| 漂移系统 | `car.gd` | 🎯 漂移系统 | 普通漂/松前/三喷/反打/集气 |
| 喷射 | `car.gd`+`BoostFX.gd` | 💨 喷射 | 小喷/双喷/氮气/叠喷/漂移氮气 |
| 撞墙物理 | `car.gd`+`TrackWallTagger.gd` | 🧱 撞墙物理 | 硬碰硬反弹+弹墙掉头+防吸住 |
| 地面物理 | `car.gd` | ⛰️ 地面物理 | 防弹+贴附+坡道 |
| 空喷/落地喷 | `car.gd` | 🛫 空喷 / 落地喷 | 离地瞬间空喷+落地按键喷 |
| 视觉 | `car.gd`+`HUD.gd` | ✨ 视觉 | 车身姿态+漂移 yaw/侧倾 |
| 镜头 | `Camera3D.gd` | 🎥 镜头 | 跟随/拉远/Y稳定/前瞻 |

---

## 🛡️ 重要约定

1. **基础3C 高压线**: 任何会动到 `car.gd` / `Camera3D.gd` / `Tuner.gd` 核心 3C 代码或参数的改动, **必须先在对话框里向用户声明并征求同意**, 不许擅自修改! 见 [01_HIGH_VOLTAGE.md](./01_HIGH_VOLTAGE.md).

2. **新参数必须进 Tuner**: 任何新加的 @export 参数, 都要在 `Tuner.gd` 里登记 + 写 tooltip。

3. **改动必写日志**: 每次有意义的改动结束都在 `CHANGELOG.md` 顶部追加一条记录。

4. **每次改完必须跑游戏验证**: 因为 GDScript 是动态语言, lint 不能保证 parse error。
   流程: `read_lints` → 启动游戏 → 等几秒读 `godot.log` 头部 + 搜 `ERROR/SCRIPT ERROR/Parse Error`,
   全无报错才算改动真的生效 (Godot 在 parse error 时会回退用编译缓存版本, 容易误判)。

---

## 📂 项目目录结构

```
简单飞车试验场/
├── project.godot          # Godot 项目配置 (config_name=简单飞车试验场, 默认场景=track_qinghuaci.tscn)
├── docs/                  # 项目文档 (本目录)
│
├── car.gd                 # 【核心】赛车物理 + 状态机 (3000 行+)
├── car.tscn               # 默认赛车场景 (玉麒麟)
├── car_suv.tscn           # 备用赛车场景 (SUV)
├── CarSwitcher.gd         # F3 切车自动注入
│
├── Camera3D.gd            # 【核心】跟随相机 (含 Y 稳定/前瞻/拉远/震屏)
│
├── HUD.gd                 # HUD UI (速度/集气/漂移弹字)
├── HUD.tscn
│
├── Tuner.gd               # 【核心】调参 UI (TAB 切换, 三级分类页签→分组→参数)
├── Tuner.tscn
│
├── BoostFX.gd / .tscn     # 喷射火焰特效 (小喷/双喷/氮气/空喷/落地喷)
├── DriftFX.gd / .tscn     # 漂移特效 (轮胎发光/胎印/火焰)
├── GlassShatterFX.gd      # 撞墙玻璃渣特效
│
├── YuqilinPaint.gd        # 玉麒麟 PBR 材质智能映射
├── YuqilinTuning.gd       # 玉麒麟外观调参 (clearcoat/normal/SSS)
├── YuqilinMesh.tscn
│
├── TrackSetup.gd          # 赛道初始化辅助
├── TrackSwitcher.gd       # 赛道切换
├── TrackWallTagger.gd     # 【新】扫描赛道 mesh 自动识别墙体
├── track.tscn             # 大赛道 (合并 trimesh)
├── track_qinghuaci.tscn   # 【默认】青花瓷小赛道
│
├── assets/                # 美术资源 (车模/赛道/贴图)
└── scripts/               # 工具脚本
```

---

## 📞 联系信息

项目作者: shilohuang
合作伙伴: AI 助手 (炸弹猫 ⊂(◉‿◉)つ)

