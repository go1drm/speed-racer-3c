# 简单飞车试验场 改动日志

> 按"功能模块"分类记录每次改动: **何时 / 改了什么 / 为什么改 / 受影响文件**。
> 新增条目请放到对应分类的最上方（倒序时间）。
> 时间格式: `YYYY-MM-DD HH:MM`

---

## 分类约定

| 标签 | 含义 |
|---|---|
| **【3C-车】** | 角色（赛车）本体: 物理、动力、刹车、加速、漂移、惯性、推力方向 |
| **【3C-相机】** | 相机: 跟随、震屏、视角、FOV、漂移视角偏移 |
| **【3C-控制】** | 输入: 键位、按键宽限期、连击、按住/点按判定、CD |
| **【漂移】** | 漂移系统: 入漂/退漂、宽限期、强度曲线、车身侧倾、车头 yaw、撞墙断漂、低速断漂 |
| **【喷射/连喷】** | 小喷/双喷/氮气、CW/WC/CWW/WCW 接力、突破极速、推力衰减、蓄能 |
| **【FX】** | 视觉/粒子/音效: BoostFX、DriftFX、HUD 弹字、震屏 |
| **【HUD】** | 抬头显示: 速度、氮气槽、连喷指示、combo 弹字 |
| **【赛道】** | Track 场景: 地形、墙体、起点、传送带、checkpoint、新赛道 |
| **【车型】** | 车壳/模型: SUV、玉麒麟、FBX 导入、贴图、tailpipe、轮子 |
| **【Tuner】** | Tuner 调参面板: 新参数、Tab 分组、UI 排版、保存/加载 |
| **【物理/碰撞】** | RigidBody3D 配置、碰撞层、contact_monitor、斜面墙、弹墙 |
| **【架构】** | 全局架构: AutoLoad、信号系统、CarSwitcher/TrackSwitcher、热切换 |
| **【工程】** | 日志、调试工具、文档、git、编译警告/错误修复 |

---

## 2026-05

### 2026-05-13 14:08 【3C-车】反打重构 + 加速带 + 多 bug 修复
- 【3C-车-反打】真实赛车反打机制重构 (新开关 `drift_counter_enabled`, 默认 true):
  - 漂角 = 车头 XZ 与速度向量 XZ 的有符号夹角. 玩家按"与漂角相反"的方向 → 车头朝速度向量缓慢回正 (默认 120°/s, |steer| × ramp 调制), 直到漂角进入死区 (默认 4°)
  - 反打期间暂停向心力 → 速度向量保持原方向, 玩家看到"车身仍在漂、车头先回正"的 QQ 飞车手感
  - 旧机制 (反打减速 / 反打前向阻力 / 反打侧向抓地下降 / 反打 turn_mult 缩减 / 反打锁定 / 连续反打疲劳) 全部由新开关绕过, @export 默认值与 cfg 兼容
  - 新参数 (Tuner): `drift_counter_enabled` / `drift_counter_angular_speed_deg=120` / `drift_counter_deadzone_deg=4` / `drift_counter_response_time=0.5`
  - 文件: `car.gd`, `Tuner.gd`
- 【3C-车-加速带】赛道白色方块加速带 + 弹射器:
  - `TrackSetup.gd` 自动识别 FBX 里 mesh 名带 `AddSpeed` / `Shoot` 的 MeshInstance3D, 创建 Area3D + BoxShape3D 触发器 (不生成物理碰撞, 车可穿过)
  - 新建 `SpeedPad.gd` 处理 body_entered 信号, 调用 `car.apply_speed_pad_boost(kick, dur, type)`
  - 车端: 瞬时冲量 (沿车头) + 持续推力 (`speed_pad_sustain_power=18`, 线性衰减) + 顶速临时放宽到 `top_speed_boosted`
  - 注意: Area3D collision_mask 必须设 2 (匹配 car 的 collision_layer=2)
  - 默认参数: 加速带 kick=20 m/s dur=0.4s; 弹射器 kick=40 m/s dur=0.5s
  - 文件: `TrackSetup.gd`, `SpeedPad.gd`(新), `car.gd`, `Tuner.gd`
- 【3C-车-叠喷】air / landing 加入氮气延续白名单:
  - 旧逻辑: 氮气中只有 mini/double 能延续氮气时长; air 和 landing 会强制打断氮气
  - 新逻辑: air/landing 也算 W 系小喷, 也能延续氮气 + 沾叠喷链 (CW/CWW 等组合现在对 air/landing 生效)
  - air/landing 仍**不**开放"蓄双喷资格" (它们是被动触发, 保留原设计意图)
  - 文件: `car.gd::_start_boost`
- 【3C-车-松前漂移】CD 改成全局生效:
  - 新参数 `songqian_drift_cooldown=0.8s` 替代旧 `songqian_drift_max_per_drift` 次数限制
  - CD 不因起漂清零, 跨多次漂移生效 (彻底封死"反复抖油门"刷冲量)
  - 物理层倒计时统一在 `_physics_process` 衰减
- 【3C-车】其他 bug 修复:
  - 引擎软封顶用 `current_speed` 替代 `long_speed`, 修"前进+转向无限加速"bug
  - 码表只取水平速度 (`linear_velocity` 去 Y 分量), 修"按住前进+转向数值虚高"bug
- 【UI】HUD 操作提示精简到 ↑↓←→QWE 6 键 + 加署名小字 "本简易 DEMO 用于快速还原玩法原型 by.shilohuang"; 松前漂移触发瞬间弹"松前漂移"字 (青绿色)
- 【工程】Tuner cfg 路径稳定化:
  - 改用 `app_userdata/SimpleRacerLab/tune.cfg` 作为固定路径, 不再随 `config/name` 改变
  - 启动时自动从历史目录 (`3d_car_sphere`/`StarDust Racers`/`SpeedRacer3C`/`简单飞车试验场`) 继承旧 cfg
  - 启动时自动 load (不需要按"加载"按钮)

### 2026-05-12 🎉 基础3C 第一版定型 + 项目重命名

**【工程】** 项目改名 `3d_car_sphere` → **简单飞车试验场**
- `project.godot` 的 `application/config/name` 更新
- 默认场景从 `track.tscn` 切到 **`track_qinghuaci.tscn`** (小赛道调参更方便)
- 日志路径随之变为 `%APPDATA%\Godot\app_userdata\简单飞车试验场\logs\godot*.log`

**【Tuner】** 参数面板三级分类重构 + 隐藏废弃参数
- 新增分类标记: `__page` (页签) / `__group` (大标题) / `__sub` (小标题) / `__hidden_start/end` (包裹隐藏参数)
- 页签重新划分: 🚗基础移动 / 🎯漂移系统 / 💨喷射 / ✨视觉 / ⛰️地面物理 / 🧱撞墙物理 / ⛰️坡道 / 🛫空喷落地喷 + 原有的玉麒麟外观 / 漂移特效 / 镜头 / 喷射特效强度
- 废弃参数集中到隐藏区 (不显示在 UI 但 cfg 加载兼容):
  - `wall_reflect_tangent_keep` / `wall_slide_boost` / `slope_wall_bounce_absorb` / `slope_wall_shake`
  - `landing_hard_stick` / `landing_stick_duration` / `landing_stick_min_fall_speed`
  - `air_boost_intent_window` / `air_boost_overrides_window` / `landing_boost_stacks_with_air`
- UI 增加 `_add_sub_header()` 小标题渲染

**【工程】** 建立 `docs/` 项目文档体系
- `docs/00_README.md` - 项目总入口 + 快速开始 + 目录导航
- `docs/01_HIGH_VOLTAGE.md` - **基础3C 高压线** 声明, AI/开发者改 3C 前必须先问用户
- `docs/02_CODE_INDEX.md` - 代码知识库索引 (每个文件/每个函数的职责)
- `docs/CHANGELOG.md` - 本日志
- (下一步) `docs/03_FEATURES.xlsx` - 3C 功能+参数总表

**【架构】** 定型版核心 3C 模块总结:
- 基础移动 (引擎/刹车/倒车/转向/摩擦)
- 漂移 (入漂/退漂 + 松前 + 三喷 + 反打+减速 + 集气)
- 喷射 (小喷/双喷/氮气/叠喷CWW/WCW + 漂移氮气 + 空喷立即触发 + 落地喷按键窗口)
- 撞墙物理 (硬碰硬反弹 + 弹墙掉头 + 防吸住 + 弹墙推力)
- 地面物理 (防弹+贴附 + 坡道补偿 + 上坡助力)
- 视觉 (车身侧倾 + 漂移 yaw + 玉麒麟材质)
- 镜头 (Y 稳定 + 前瞻焦点 + 喷射拉远)

---



### 2026-05-12 14:30 【漂移】松前完整规则: 不能小喷 + 严格3键松前漂移 + 松前断漂不开窗口 + 进入小加速
- 设计澄清(用户进一步定义):
  1) 松前 = 打滑阶段, **不能用小喷** (W 在松前下无效, 必须踩回油门退出松前再 W)
  2) 松前下任何方式断漂都不算"正常断漂", **不开小喷窗口** (复用 failed 标记)
  3) 松前漂移触发严格条件: 必须 **前进键 + 方向键 + Q** 同时按下 (松开前进键后单按 Q 是断漂)
  4) 松前是"打滑滑行" → 漂移时巨大推力, **进入松前**也给一个**小加速**冲量保留打滑势能
- 改动 1: car.gd `_read_input` Q 键 DRIFT 分支重写
  - 松前中 (`_is_in_songqian == true`):
    - + 前进键按住 + 方向输入 → `_trigger_songqian_drift()` (松前漂移)
    - + 缺前进键或方向 → `_end_drift(false, true, true)` (松前断漂, failed=true 不开窗口)
  - 非松前(满油按Q): 原 `_end_drift(false, true)` 走正常退漂窗口
- 改动 2: car.gd `_try_boost_w` DRIFT 分支加松前判定
  - `if _is_in_songqian: emit "insufficient"; return` (松前下 W 完全无效)
- 改动 3: car.gd `_end_drift` 顶部加松前自动 failed
  - `if _is_in_songqian and not failed: failed = true` (统一拦截所有"松前下断漂"路径, 包括低速/超时/手动)
- 改动 4: car.gd `_update_visuals` 松前段
  - 维护 `_is_in_songqian` 状态变量 (每帧根据 throttle 重算)
  - 进入松前瞬间 (`_is_in_songqian: false→true` 边沿) 给一次 `songqian_enter_kick_impulse` 沿当前运动方向冲量
  - `_songqian_kick_given` 标记防止重复给, 退出松前时重置(下次再松前可再加速)
- 改动 5: car.gd `_trigger_songqian_drift` 触发后清 `_is_in_songqian` 和 `_songqian_kick_given`
- 改动 6: 新 export `songqian_enter_kick_impulse` (默认 4.0), Tuner 同步
- 改动 7: Tuner 文案更新强调"巨大冲量是松前漂移灵魂"
- 状态表 (松前/松前漂移决策):

  | 当前状态 | 按键 | 行为 |
  |---|---|---|
  | DRIFT 满油 (非松前) | W | 退漂 + 开小喷窗口 (原行为) |
  | DRIFT 满油 | Q | 退漂 (manual) |
  | DRIFT 松前 | W | **无效** (打印 insufficient) |
  | DRIFT 松前 | Q (无前/无方向) | **松前断漂** (failed=true, 不开窗口) |
  | DRIFT 松前 | Q + 前 + 方向 | **松前漂移** (巨大冲量+爆发, drift 不中断) |
  | 进入松前瞬间 | -- | **小加速** 沿运动方向(一次性) |

- 数学:
  - 松前判定: `_is_in_songqian = (state == DRIFT and throttle_input < 0.05)`
  - 松前漂移触发: `is_action_just_pressed("drift") and is_action_pressed("accelerate") and abs(steer_input) >= 0.15`
  - 进入小加速: `apply_central_impulse(v.normalized() × songqian_enter_kick_impulse × mass)` (一次性)
  - 松前漂移巨大冲量: `apply_central_impulse(forward × songqian_drift_kick_impulse × mass)`
  - failed 自动转换: 在 `_end_drift` 顶部 `if _is_in_songqian and not failed: failed = true`
- 原因: 用户连续 3 条澄清, 完整定义松前规则
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-12 14:15 【漂移】重新定义"松前": DRIFT 子状态 (上一版误解, 已纠正)
- **概念纠正**: 松前不是 NORMAL 状态. 用户的真正定义是:
  - 松前 = 漂移中**松开前进键**(但保持按住入弯方向键)
  - 赛车保持 DRIFT 状态, 但车头会朝 drift_dir 方向慢慢偏 (相对起漂时方向最多 90°)
  - 退出方式: 踩回油门(回正常漂) / 按 Q 触发松前漂移 / 退漂(W/超时/低速)
- 改动 1: car.gd `_try_start_drift` 回退到原版 (移除上一版的 NORMAL+横速 起漂分支)
- 改动 2: car.gd `_read_input` 中 DRIFT 按 Q 的逻辑分支
  - **松前下按 Q** (`throttle_input < 0.05`) → 调 `_trigger_songqian_drift()` (不退漂)
  - **满油按 Q** → 走原 `_end_drift(manual=true)` 退漂
- 改动 3: car.gd 新增 `_trigger_songqian_drift()` 函数
  - 沿车头方向施加 `songqian_drift_kick_impulse × mass` 冲量
  - 把 `_drift_exit_boost_left` 重置为 `songqian_drift_boost_duration`(默认 0.7s)
  - 把 `_songqian_yaw_offset` 清零(车头回正, 重新点燃漂移势能)
- 改动 4: car.gd `_update_visuals` 加松前 yaw 偏移逻辑
  - 仅在 `state == DRIFT` 且松前开关开 时启用
  - 目标偏移: 松前(throttle<0.05) → `songqian_yaw_limit_deg × drift_dir`; 满油 → 0
  - `_songqian_yaw_offset` 用 `move_toward` 按 `songqian_yaw_speed_deg/秒`(默认 90°/s) 推进到目标
  - 每帧把 car_mesh basis 额外绕 Y 旋转 `(_songqian_yaw_offset - prev_offset)` 度
  - 退出 DRIFT 后偏移平滑回零
- 改动 5: car.gd 新增 2 个状态变量
  - `_drift_start_forward`: 起漂时车头方向(XZ 平面归一化), 入漂时记录
  - `_songqian_yaw_offset`: 累计松前 yaw 偏移角(度)
- 改动 6: 废弃上一版的 `drift_slip_cap_enabled / drift_slip_cap_angle_deg` (NORMAL 状态打滑限制)
  - 保留 export 兼容旧 cfg, 但 enabled 默认改 false
  - 真正的"车头 90° 限制"在 `songqian_yaw_limit_deg` 里管理
- 改动 7: Tuner 参数行更新, 5 个新参数:
  - `songqian_drift_enabled` / `songqian_yaw_limit_deg` / `songqian_yaw_speed_deg`
  - `songqian_drift_kick_impulse` / `songqian_drift_boost_duration`
  - 移除 `songqian_detect_lat_speed` (NORMAL 路径已不存在) 和上一版废弃参数行
- 数学:
  - 松前判定: `state == DRIFT and throttle_input < 0.05`
  - 偏移更新: `_songqian_yaw_offset = move_toward(_songqian_yaw_offset, target, speed × delta)`
  - target = (松前 ? songqian_yaw_limit_deg : 0) × drift_dir
  - 应用到 basis: `basis.rotated(basis.y, deg_to_rad(_songqian_yaw_offset - prev_offset))` 每帧增量
  - 触发松前漂移: `apply_central_impulse(forward × kick × mass)` 一次性冲量
- 原因: 上一版我误把"松前"理解成 NORMAL 状态打滑后起漂. 用户澄清后纠正:
  "松前就是漂移中松前进键, 车头会偏直到 90°, 按 Q 触发松前漂移获得推力, 不退漂"
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-12 13:25 【物理/碰撞】【FX】重写撞墙物理 + 玻璃渣特效
- 改动 1: 新建 `GlassShatterFX.tscn` + `GlassShatterFX.gd`
  - 一次性玻璃渣 GPUParticles3D, 25 颗银白半透明粒子, 高重力, 高角速度(自旋)
  - `configure_by_impact(speed, normal)` 接口: 按撞击速度自动调整粒子量(10~50)和速度
  - 自动 1.2 秒后 queue_free, 不留垃圾
- 改动 2: car.gd `_integrate_forces` 撞墙物理重写
  - **真实反弹模型**: 把速度分解为法线 + 切线分量分别处理
    - `v_normal = (v · n) × n` (沿法线投影)
    - `v_tangent = v - v_normal` (沿墙面切向)
    - `new_v = v_tangent × wall_reflect_tangent_keep + n × into_wall × wall_reflect_normal_factor + push_back`
  - **撞击角度判定**: 计算车头与墙面切平面的夹角 `face_angle_deg`
    - 小于 `wall_grazing_angle_deg` (默认 20°) = 擦墙(切向几乎全保留)
    - 大于则视为正撞, 切向额外乘 0.85
  - **撞击点用 `state_phys.transform * get_contact_local_position(i)`** 转世界坐标
  - **震屏强度按撞击速度缩放**: `shake = base × clamp(into/15, 0.3, 2.0)`
- 改动 3: car.gd 新增 5 个 export 参数
  - `wall_reflect_tangent_keep` (默认 0.9): 切向保留
  - `wall_reflect_normal_factor` (默认 0.4): 法向反弹系数 (恢复系数 e)
  - `wall_grazing_angle_deg` (默认 20°): 擦墙临界角
  - `glass_shatter_fx_scene`: 玻璃渣场景引用
  - `glass_shatter_min_speed` (默认 3.0): 触发玻璃渣的最小撞击速度
- 改动 4: car.gd 新增 `_spawn_glass_shatter(pos, normal, speed)` 函数
  - 实例化挂到 `current_scene` 而非 car (车开走特效不会跟着)
  - 调用 fx 自己的 `configure_by_impact` 配置
- 改动 5: Tuner 新增 4 个反弹相关参数行(在斜面墙组下)
- 数学示例:
  - 正面撞墙 (face_angle=90°, into=15 m/s): new_v = v_tangent×0.85×0.9 + n×15×0.4 = 强弹回
  - 擦墙 (face_angle=10°, into=2 m/s): 大概率不触发(<glass_shatter_min_speed); 触发时 new_v = v_tangent×0.9 + n×2×0.4 = 几乎不掉速
- 原因: 用户反馈"撞墙不够真实, 应该跟撞击点位/速度/车身角度有关. 撞墙后要在撞击点位放玻璃渣"
- 注: 暂未改主碰撞体形状(球体驱动核心). 撞击点是球面接触点, 体感优先靠新反弹公式
- 文件: `car.gd`, `Tuner.gd`, `GlassShatterFX.tscn`(新), `GlassShatterFX.gd`(新)

### 2026-05-12 13:20 【漂移】松前漂移: 打滑后方向+Q 冲量起漂 + 打滑车身角度上限
- 改动 1: car.gd `_try_start_drift` 增加"松前打滑"识别
  - 新条件: NORMAL + 横向速度 > `songqian_detect_lat_speed` (4 m/s) → 是松前打滑状态
  - 油门要求放宽: 普通入漂仍要 throttle≥0.05; 松前打滑下可以 throttle=0 直接 Q+方向起漂
- 改动 2: 松前起漂 = 入漂瞬间额外两个增益
  - 沿车头方向施加一次性冲量 `songqian_drift_kick_impulse × mass` (默认 14)
  - 把 `_drift_exit_boost_left` 设为 `songqian_drift_boost_duration` (默认 0.7s, 比普通入漂的 0.6 略长)
  - 配合 `_drift_exit_boost_mult` 的现有爆发倍率, 让玩家感受"打滑后突然重新冲起来"
- 改动 3: car.gd `_update_visuals` 加打滑车身角度上限
  - NORMAL + `_drift_slip_factor > 0.3` 时, 车身相对运动方向最多横出 `drift_slip_cap_angle_deg` (默认 90°)
  - 超过则用 `Basis.looking_at` 把车身朝向拉回 cap 内, slerp 平滑过渡
- 改动 4: car.gd 新增 6 个 export 参数 (松前起漂 4 个 + 角度上限 2 个), Tuner 同步加行
- 数学:
  - 松前起漂条件: `lat_spd >= songqian_detect_lat_speed` (4 m/s)
  - 冲量公式: `apply_central_impulse(forward × songqian_drift_kick_impulse × mass)`
  - 角度上限: `if acos(forward·v_dir) > deg_to_rad(cap_angle): basis.slerp(LookAt(target), 10×delta)`
- 原因: 用户要求"松前打滑过后可以方向+Q 发动松前漂移获得较大推力" + "打滑状态车身最多 90° 横向滑出"
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-12 13:15 【漂移】松前 (松开前进键) 额外能耗倍率
- 改动: car.gd `_apply_friction` 中 `drift_extra_decel` 应用一个松前倍率插值
  - `decel_mult = lerp(1.0, drift_extra_decel_songqian_mult, _drift_slip_factor)`
  - `_drift_slip_factor` 复用打滑机制的 0~1 平滑量, 0=满油门, 1=完全松开
  - 默认 `drift_extra_decel_songqian_mult = 0.3` → 松前时能耗只剩 30%, 车滑得更远
- 原因: 用户反馈"松前时漂移额外能耗也与正常漂移不同, 给个配置". 这跟之前的"松前打滑摩擦归零"互补 — 一个管摩擦力, 一个管整体能耗
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-12 12:55 【FX】粒子特效 v2: 细长焰柱 + 金色星星散粒, 尺寸缩到排气管宽
- 改动 1: `BoostFX.tscn` 重构
  - 主焰柱粒子 mesh 缩小 (radius 0.04~0.05, 之前 0.05~0.09, 减少 30~50%)
  - 主焰柱 scale 缩到排气管宽度级别 (0.08~0.25, 之前 0.5~1.2)
  - 主焰柱 velocity 配合 lifetime 让尾焰长度 ≈ 2.5m (半个玉麒麟车身)
  - spread 缩到 3~4° (细窄而非扇形炸开)
  - **氮气主色改为紫蓝** (参考图里的主色调, 原为青蓝)
  - 新增 3 个星星散粒子节点: `MiniStar` / `DoubleStar` / `NitroStar`
    · 金色粒子 (albedo 1.0, 0.85, 0.35), blend_mode=ADD
    · 数量稀疏 (10~22 基础量), lifetime 略长, spread 大(18~22°) 让星星散开
    · 轻微负向重力让星星往下飘(参考图效果)
  - 空喷/落地喷保持原样式但粒子也同步缩小一档
- 改动 2: `BoostFX.gd` 重写
  - 新增状态切换同步 Star 子节点: 主焰柱开 → 星星同步开(受 stars_enabled 总开关)
  - 新增 @export 可调参数:
    · `flame_target_length`: 主焰柱长度(米), 自动算 velocity = length / lifetime
    · `flame_width_mult`: 主焰柱粒子粗细倍率
    · `stars_enabled` / `stars_amount_mult` / `stars_scale_mult` / `stars_color` / `stars_gravity_y`
  - 保留原 `fx_global_amount_mult` / 氮气突破强度系列参数
- 改动 3: `Tuner.gd` "喷射特效强度" Tab 分 3 个 section: 【形状-尺寸】/【强度】/【星星散粒】
  - 新增对应 7 个可调行
  - `_add_param_row` 支持 `__group` 作为 section 标题在同一 tab 内分节
- 数学:
  - 焰柱长度 ≈ `initial_velocity × lifetime`. 例 2.5m = 6.25 m/s × 0.4s
  - 焰柱宽度 ≈ `scale × mesh.radius × 2`. 默认 0.08~0.25 × 0.04 × 2 ≈ 0.006~0.02m (非常细)
  - 与 flame_width_mult 叠加可放大
- 原因: 用户反馈"粒子太大晃眼睛, 要像参考图那样排气管宽+半车身长+金色星星, 可配置"
- 文件: `BoostFX.tscn`, `BoostFX.gd`, `Tuner.gd`

### 2026-05-12 12:50 【3C-控制】空中禁止转向
- 改动: `_update_visuals` 中 `turn_rad = 0.0` 如果 `_is_airborne == true`
- 原因: 用户指定"空中不可转向, 落地才可以转". 转向本质需要轮胎抓地, 凭空转车头不符合直觉
- 配合: 已有的"空中保持漂移状态""落地预输入缓冲"共同构成"起飞→空中锁定→落地延续"的完整手感链路
- 文件: `car.gd`

### 2026-05-12 11:40 【3C-车】【漂移】惯性感 + 向心力感 双参
- 改动: car.gd 新增 2 个手感参数 + 1 个可选曲线, Tuner 同步添加
  - `drift_inertia_boost` (0~1): 漂移时"沿惯性方向的摩擦削减比例". 0=原样, 1=漂移深度时摩擦归零(纯惯性)
  - `drift_centripetal_pull` (m/s²): 漂移时"把速度方向拉向车头"的拉力. 推荐 5~20
  - `drift_centripetal_curve` (Curve): 向心拉力随漂移时间变化的倍率曲线, 可选. X=drift_elapsed 归一化
- 数学:
  - 惯性感: 在 `_apply_friction` 的摩擦系数叠乘一层 `inertia_mult = 1 - drift_inertia_boost × drift_intensity`, 与打滑机制叠加
  - 向心力: `F_cp = mass × drift_centripetal_pull × drift_intensity × cp_time_k × (forward_xz - v_dir_xz) × current_speed`
    · 方向: 从当前速度方向指向车头方向的差向量
    · 乘 current_speed: 让高速弯拉力更大 (QQ飞车"高速弯吸弧线"感)
- 原因: 用户反馈"漂移过程中惯性感和向心力感不足, 希望能通过参数调出手感". 这俩参数可以配合打滑/抓地一起调, 组合出从"轻飘"到"重粘"的不同风格
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-12 11:38 【漂移】【3C-控制】空中保持漂移状态 + 落地预输入缓冲
- 改动 1: `_check_drift_timeout` 开头加入 `if _is_airborne: return`
  - 效果: 空中不累计 drift_elapsed, 不做自动退漂/低速断漂判定. 起飞前若 DRIFT, 空中保持, 落地后状态无缝延续
  - 注: 撞墙断漂走 `_integrate_forces` 的物理路径, 不受影响
- 改动 2: `_read_input` 里 Q 键分支
  - 空中 + DRIFT: 忽略 Q (空中按 Q 不打断漂移)
  - 空中 + NORMAL: 写入 `_pending_landing_q_left = landing_input_buffer_time` 作为落地预输入
  - 地面: 与原来一致
- 改动 3: `_read_input` 里 W 键分支
  - 空中按 W: 除现有空喷意图缓存外, 同时写入 `_pending_landing_w_left = landing_input_buffer_time`
- 改动 4: `_update_air_state` 落地瞬间(_is_airborne true→false)消费预输入
  - Q: 若 NORMAL 且缓冲有效 → 回放一次 just_pressed 逻辑 (尝试起漂 / 启动宽限期)
  - W: 若空喷未触发 → 回放 `_try_boost_w` (兼容落地喷 / 小喷窗口 / 双喷)
- 改动 5: 新增 export `landing_input_buffer_time` (默认 0.3s), Tuner 可调
- 原因: 用户要求"空中无法操控加速撞向, 落地瞬间能操作, 落地前一段时间给预输入, 起飞前漂移状态落地延续"
- 文件: `car.gd`

### 2026-05-12 11:35 【喷射/连喷】空喷判定放宽: 车头腾空就可空喷
- 改动: `air_boost_min_air_time` 默认值 0.18 → 0.0
- 原因: 用户反馈"空喷判定太晚了, 检测到车头腾空就应该可以空喷"
- 后续: 若需防抖动(例如过坎短暂离地不算), 可在 Tuner 里把值调到 0.03~0.05
- 文件: `car.gd`

### 2026-05-12 11:05 【漂移】漂移中松开前进键 = 打滑 (前后/侧向摩擦短暂归零)
- 改动:
  - car.gd 新增 `drift_slip_enabled / drift_slip_friction_cut / drift_slip_smooth` 三个 export 参数
  - car.gd 新增状态变量 `_drift_slip_factor` (0=抓地, 1=完全打滑)
  - `_apply_friction` 在 DRIFT 状态下按 throttle_input 驱动打滑:
    - `slip_target = 1.0 - clamp(throttle_input, 0, 1)` (满油门 0, 完全松开 1, 倒车也按 1 算)
    - `_drift_slip_factor` 用 `drift_slip_smooth` 速度平滑插值
    - 最终 `long_k *= (1 - _drift_slip_factor × drift_slip_friction_cut)`, `lat_k *= 同` 
    - 默认参数 `drift_slip_friction_cut=1.0` → 完全松油门时摩擦归零
  - Tuner 新增这三个参数行
- 数学示例 (油门从 1.0 松到 0):
  - slip_target: 0 → 1
  - _drift_slip_factor 平滑过渡到 1
  - friction_mult = 1 - 1 × 1 = 0 → 纵向/侧向摩擦都归零 → 车纯惯性沿惯性方向滑行
- 原因: 用户要求"漂移中松开前进键车辆进入打滑状态, 漂移前后摩擦、漂移侧向抓地短暂视为 0"
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-12 11:00 【HUD】【炫点】所有炫点文案改中文; 修复 CWW 接不上双喷
- 改动 1: HUD 炫点文案全部中文
  - "小  喷" → "小喷"
  - "D O U B L E !" → "双喷"
  - "N I T R O !!" → "氮气"
  - "空喷！Xs 飞跃" → "空喷  X秒飞跃"
  - "落地喷 +Xs" → "落地喷  +X秒"
  - "叠喷 " + combo → "叠喷  %s" (保留 CW/CWW/WCW 英文序列名, 这是技巧代号, 不翻译)
- 改动 2: car.gd 修复 CWW 蓄不起来的 BUG
  - 原问题: `_start_boost` 开头把 `_can_charge_double = false` 无条件置零. 但 CWW 路径 = 氮气 C + 氮气末按W(mini延续) + 再蓄W(double). 第二段 mini 进入 `_start_boost` 时 flag 被清零 → 蓄能条件不满足 → CWW 蓄不起来
  - 修复: `_start_boost` 开头只在 type == air/landing/nitro/double 时清零; 氮气延续分支若 type==mini 显式置 `_can_charge_double = true`
  - 另外去掉蓄能条件里的 `boost_type == "mini"` 兜底 (氮气延续段 boost_type 还是 nitro, 这个兜底会把合法 CWW 蓄能误杀)

- 数学/状态表 (修复后):

  | 路径 | 触发时 `_can_charge_double` | 允许蓄双喷 |
  |---|---|---|
  | 退漂小喷 `_consume_boost_window("mini")` | **true** (手动置) | ✅ |
  | 氮气末按 W 的 mini 延续段 (CW 的第二段) | **true** (氮气分支置) | ✅ CWW |
  | 氮气末按 W 的 double 延续段 (WCW 的最终段) | false | ❌ 无意义 |
  | 空喷 `_start_boost("air")` | false (顶部清零) | ❌ |
  | 落地喷 `_start_boost("landing")` | false | ❌ |
  | 氮气 `_start_boost("nitro")` | false | ❌ |
  | 双喷自身 `_start_boost("double")` | false | ❌ |

- 原因: 1) 用户要求"炫点中英文风格要中文化, 氮气就显示氮气" 2) 用户反馈"CWW 现在放不出来, 因为 CW 过后就接不上双喷了"
- 文件: `HUD.gd`, `car.gd`

### 2026-05-12 10:55 【HUD】【炫点】确立设计原则 + 三项整改
- 定义: **炫点 = HUD 中央弹字**. 只反馈"玩家做出了什么技巧", 不做"现在按 W"/"按住 Q 蓄能"这种教学
- 改动 1: `_on_boost_window_opened` 删除 "按 W！双喷/小喷" 中央弹字, 只保留灯效状态提示
- 改动 2: `_on_boost_window_closed` 删除相应的渐隐处理, 只熄灯
- 改动 3: `_on_double_charge_ready` 删除 "按 W！双喷" 弹字, 只把灯切到 "W!"
- 改动 4: `_on_air_boost_armed` 删除 "空喷锁定" 中间状态弹字 (空喷真正完成在 `_on_air_boost_triggered`, 那里才弹"空喷！Xs 飞跃")
- 改动 5: `_on_drift_started` 中央弹字统一为 **"漂移"**, 不再区分 "DRIFT · 甩尾" / "DRIFT · 侧身"
  - 理由: 炫点里"漂移就是漂移", 甩尾/侧身是内部技巧分类, 由 mode 参数保留供后续颜色区分或成就系统使用
- 原因: 用户要求"炫点中不应该出现任何教学. 做出技巧后立刻反馈做了什么技巧" + "漂移就是漂移"
- 文件: `HUD.gd`

### 2026-05-12 10:50 【喷射/连喷】只有退漂小喷才能蓄双喷
- 改动: 新增状态变量 `_can_charge_double: bool` (默认 false)
  - `_start_boost` 函数开头: 每次调用都先置 false (任何 air/landing/nitro/double/氮气延续段都会清零)
  - `_consume_boost_window` 释放"退漂小喷"后: 调 `_start_boost` → 立即再把 `_can_charge_double = true` 置回
  - `_update_double_charge` 蓄能条件多加一项: `_can_charge_double == true`
- 数学/状态表:

  | 触发 boost 的路径 | _can_charge_double | 允许蓄双喷 |
  |---|---|---|
  | 退漂小喷 `_consume_boost_window("mini")` | **true** | ✅ |
  | 空喷 `_start_boost("air")` | false | ❌ |
  | 落地喷 `_start_boost("landing")` | false | ❌ |
  | 氮气 `_start_boost("nitro")` | false | ❌ |
  | 双喷 `_start_boost("double")` | false | ❌ |
  | 氮气延续段(内部路径 type="mini"/"double") | false | ❌ |

- 原因: 用户指定"只有退漂后的那个小喷可以触发双喷蓄能, 空喷/落地喷/双喷都不行". 避免"空喷立即蓄双喷"的廉价循环, 双喷必须奖励真正完成漂移的玩家
- 文件: `car.gd`

### 2026-05-12 10:30 【喷射/连喷】重写连喷状态机: CW/CWW/WCW 三种合法叠喷, 空喷/落地喷可作 W
- 改动: 
  - **car.gd `_check_and_apply_stack_boost`**: 重写整个连喷接力状态机, 加入完整的数学注释表
    - 字母规则: `c=nitro`, `w=mini/double/air/landing` (空喷/落地喷也参与叠喷)
    - 合法叠喷只有三种: `CW` (突破1次, 弹字) / `CWW` (突破2次, 终结弹字) / `WCW` (突破1次, 终结弹字)
    - 过渡前缀: `WC` (不弹字, 仅 WCW 中间态)
    - 删除旧代码里的"空喷/落地喷不参与叠喷"逻辑 (它们其实可以作为 W 加入链)
  - **HUD.gd `_on_combo_triggered`**: 弹字白名单从 `{CWW, WCW}` 扩展到 `{CW, CWW, WCW}`, CW 持续时间略短(0.2 vs 0.4)
- 原因: 用户反馈"CW 不生效但实际 CW 喷可以生效" — 原因是旧 HUD 故意不弹 CW 字, 玩家以为没生效。同时旧代码错误地认为"小喷不能叠氮气", 把 wc/wcw 也判为合法是矛盾的。重写后规则清晰
- 文件: `car.gd`, `HUD.gd`

### 2026-05-12 10:35 【喷射/连喷】双喷蓄能阶段视为"准漂移"状态, 受漂移限制
- 改动: `car.gd _update_double_charge`: 蓄能条件多加一项 `drift_locked = _drift_lockout_left > 0.0 or _require_release_q`. 撞墙后入漂 CD / 必须松开 Q 锁期间, 双喷蓄能也无法进行
- 改动: `car.gd _integrate_forces`: 撞墙断漂时不仅打断 DRIFT 状态, 同时清空 `_double_charge_t` 蓄能进度 + `_double_armed` 已蓄满资格, 发 `double_charge_lost` 信号通知 HUD
- 原因: 用户要求"双喷蓄能阶段也属于漂移状态的一种, 要受漂移状态限制". 之前撞墙断了 DRIFT 但蓄能继续, 蓄能完按 W 还能放双喷, 不符合"撞墙惩罚"语义
- 文件: `car.gd`

### 2026-05-12 10:30 【3C-车】漂移推力沿视觉车头方向 (允许漂移轨迹被改变)
- 改动: `_apply_engine_and_brake`: `forward` 由 `-car_mesh.basis.z` (骨架朝向, 与镜头一致) 改为 `-(car_mesh.basis × body_mesh.rotation.y).z` (视觉车头, 含漂移时的 yaw_offset)
- 数学:
  - 漂移时 body_mesh.rotation.y = drift_yaw_offset × drift_dir × intensity × 时间曲线 (一般 18°~35°)
  - 推力方向 = car_mesh 朝向绕其 Y 轴再旋转 yaw_offset 后的 -Z
  - 引擎主推力 / 刹车 / 倒车 / 爬坡助力 / 引擎空转阻力 全部受影响 (沿 thrust_dir = forward 投影到坡面)
  - long_speed = v_horiz·forward 也用视觉车头, 漂移时此值小于真实纵向速度, 引擎曲线给更高倍率 → 漂移时按 W 推力反馈更冲
- 原因: 用户反馈"漂移过程中按前进键推力是镜头前方而不是车头前方". 改为视觉车头后, 漂移时推力会把车往视觉车头方向带, **轨迹被改变** (这是用户明确想要的反馈)
- 文件: `car.gd`

### 2026-05-12 10:13 【工程】建立 CHANGELOG 体系
- 改动: 新建 `docs/CHANGELOG.md`，约定按【3C】【赛道】等分类记录每次改动的时间、内容、原因
- 原因: 长期开发需要可追溯的功能演进史，方便回溯何时引入了某机制 / 何时改过某个手感参数
- 文件: `docs/CHANGELOG.md`

### 2026-05-11 21:50 【漂移】撞墙后必须松开 Q 才能续漂（双重锁）
- 改动: 新增 `_require_release_q` flag。撞墙断漂瞬间置 true，必须等玩家松开 Q (`is_action_pressed("drift") == false`) 才能解除；期间所有 Q 输入对入漂无效。同时清空 `_drift_input_grace_left`
- 原因: 仅 0.5s 入漂 CD 不足以阻止"按住 Q 撞墙→CD 后立即续漂"。增加"必须松开 Q"硬要求才能彻底兜住
- 文件: `car.gd`

### 2026-05-11 21:44 【物理/碰撞】启用 contact_monitor 让撞墙检测真正生效
- 改动: `car.tscn` 和 `car_suv.tscn` 的 RigidBody3D 加上 `contact_monitor = true` + `max_contacts_reported = 8`
- 原因: 之前 `_integrate_forces` 里的 `state_phys.get_contact_count()` 永远返回 0，导致整段撞墙断漂、弹墙推力、斜面吸收逻辑从未触发。Godot 默认 contact_monitor=false 会节流不上报碰撞
- 文件: `car.tscn`, `car_suv.tscn`

### 2026-05-11 21:30 【漂移】移除"按住 Q 自动续漂"机制
- 改动: 删除 `_drift_resume_armed` 状态变量及相关逻辑（`_read_input` 中续漂段、`_end_drift` 中设置 armed flag）
- 原因: 该机制让所有自动断漂（低速/超时/车头摆正）只要玩家还按着 Q 就会立即续上，从玩家视角看就是"按住 Q 永远断不了"。砍掉后断漂就是断漂
- 文件: `car.gd`

### 2026-05-11 21:15 【漂移】撞墙立即失败断漂 + 入漂 CD + 不给小喷
- 改动:
  - `_end_drift` 增加 `failed: bool` 参数；`failed=true` 时跳过 boost_window_opened，不给小喷奖励
  - 新增 `_drift_lockout_left` 计时器；`_try_start_drift` 最前面检查，CD 期间按 Q 不响应
  - `_integrate_forces` 撞墙分支：DRIFT 状态下立即调 `_end_drift(failed=true)` + 设置 CD = `wall_drift_lockout_time`
  - 参数语义反转：旧 `wall_drift_protect_time`（撞墙后**不**断漂保护期）→ 新 `wall_drift_lockout_time`（撞墙立即断+此秒数内按 Q 无效）
- 原因: 用户要求 QQ 飞车风格的"撞墙惩罚"：本次漂移作废、短 CD 内不能再起漂
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-11 20:56 【漂移】反打车身回正 + 退漂转向冷却
- 改动:
  - 新增 `_counter_lean_factor` + `drift_counter_lean_mult`/`drift_counter_lean_smooth` 参数。lean_drift 公式末尾乘 `_counter_lean_factor`：正打=1.0(完整侧倾)，反打=0.0(车身回正)，按 |steer_input| 平滑插值
  - 退漂瞬间转向倍率会被衰减到 `post_drift_steer_mult` (默认 0.5)，在 `post_drift_steer_cooldown` 秒(默认 0.35)内线性回到 1.0
- 原因:
  - 反打侧倾：之前正打反打都同样幅度倾斜，反打时甚至更夸张。改后"正打=入漂动画前进，反打=入漂动画倒放"
  - 退漂冷却：漂移时被压制的转向在退漂瞬间全部解除，造成甩飞感
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-11 20:43 【工程】修复 Tuner.gd Variant 推断 Parse Error
- 改动: `_collect_boost_fx_recursive` 中 `var s := c.get_script()` → `var s: Script = c.get_script() as Script`
- 原因: Godot 4.6 把"Variant 类型推断"警告强制升级成 Error。`get_script()` 返回 Variant，用 `:=` 推断会报错导致 Tuner 加载失败、连带 HUD 报 `_bind_car: Method not found`
- 文件: `Tuner.gd`

### 2026-05-11 较早 【车型】玉麒麟（QQ飞车真实车型）集成
- 改动: 
  - 新增 `YuqilinMesh.tscn` + `YuqilinPaint.gd`(运行时 PBR 材质替换) + `YuqilinTuning.gd`(外观参数)
  - 修复 FBX 内 .psd 贴图缺失导致灰模问题：Painter 脚本运行时遍历所有 MeshInstance3D 用 `set_surface_override_material` 替换为基于同目录 PNG 重建的 StandardMaterial3D
  - 修复 CarSwitcher 第 9 行 `;` 注释(GDScript 不支持) → 改为 `#`
  - 修复热切车坠落: CarMesh top_level=true 导致父节点 transform 不传递, add_child 之前先把 mesh transform 预置好
  - 玉麒麟外观参数(scale/rotation/y_offset)保存到 tune.cfg
- 原因: 用户希望接入真实 QQ 飞车 FBX 模型「玉麒麟」作为默认车
- 文件: `YuqilinMesh.tscn`, `YuqilinPaint.gd`, `YuqilinTuning.gd`, `CarSwitcher.gd`, `car.tscn`, `car_suv.tscn`

### 2026-05-11 较早 【喷射/连喷】Stack Boost 接力体系 + BoostFX 多 tailpipe
- 改动:
  - 实现 CW/WC/CWW/WCW 连喷接力：`stack_link_window` 内启动新 boost = 接力，链 +1
  - 极速突破: CWW 突破 +2, WCW 突破 +1, `effective_top *= stack_breakthrough_top_mult ^ count`
  - 推力衰减曲线 `stack_power_decay = [1.0, 0.85, 0.72, 0.6]`
  - BoostFX 改为多实例挂在每个 tailpipe 子节点（玉麒麟 5 个，SUV 1 个）
- 原因: 实现 QQ 飞车连喷手感
- 文件: `car.gd`, `BoostFX.gd`, `BoostFX.tscn`

### 2026-05-11 较早 【漂移】撞墙弹墙推力 + 退漂推力爆发期 + 反打转向缩减
- 改动:
  - 后半身/侧面撞墙时给沿车头方向的"弹墙推力" `wall_bounce_forward_speed`，让"被卡住"变成"擦墙加速"
  - `_drift_exit_boost_left`: 退漂瞬间触发推力爆发期 `drift_exit_boost_duration` 秒内推力 ×`drift_exit_boost_mult`
  - `drift_counter_steer_mult`: 漂移时反打方向转向缩减到 35%（QQ飞车手感"左漂右打卡一下"）
- 原因: 漂移手感打磨
- 文件: `car.gd`, `Tuner.gd`

### 2026-05-11 较早 【3C-车】坡面物理整合: 推力沿切向 + 重力补偿 + 爬升助力 + 坡面贴附
- 改动:
  - `slope_align_thrust=true`: 引擎推力投影到坡面切平面，不再向上突起
  - `slope_gravity_compensation`: 沿坡面方向补偿 g·sin(slope) 减少上坡掉速
  - `uphill_assist_*`: 爬坡时额外助力（带速度曲线，越快助力越弱）
  - `slope_stick_force`: 坡面下压力，防止飞车
  - RayCast3D target_position 从 (0,-1,0) 加长到 (0,-4,0) 防止过坎脱地
- 原因: 球体驱动赛车上坡严重掉速 + 飞车 + 抖动
- 文件: `car.gd`, `car.tscn`

### 2026-05-11 较早 【架构】CarSwitcher / TrackSwitcher AutoLoad 热切换
- 改动: F3 切 SUV，F4 切玉麒麟，F1/F2 切赛道。AutoLoad 单例处理：清理旧 HUD/Tuner/Car、记录旧 mesh transform、延迟一帧 spawn 新车
- 原因: 调参时不重启游戏即可切车型/赛道对比手感
- 文件: `CarSwitcher.gd`, `TrackSwitcher.gd`, `project.godot`

### 2026-05-11 较早 【Tuner】Tab 分页签化 + 1/3 屏幕竖排 ItemList
- 改动: Godot TabContainer 不支持垂直方向 → 用 ItemList 自定义实现。每个 Tab 是一组参数，左侧 1/3 屏宽
- 原因: 参数变多后单列滚动不便定位
- 文件: `Tuner.gd`, `Tuner.tscn`

### 2026-05-11 较早 【喷射/连喷】空喷 / 落地喷
- 改动: 新增腾空累计时间 `_air_time`，落地后 `_landing_boost_arm_left` 按键窗口内按 W 触发落地喷；空中按 W 触发空喷
- 原因: 玩法多样化
- 文件: `car.gd`, `Tuner.gd`

---

## 历史里程碑（更早期，粗粒度）

- 项目起点: fork 自 GitHub 公开的 3D Car Sphere demo（球体驱动单赛车小 demo）
- 初版改造: 加 HUD、Tuner、漂移系统、氮气、连喷
- QQ 飞车风手感打磨: 入漂宽限期、车头 yaw 偏移、车身侧倾、低速断漂、车头摆正自动退漂

---

## 编辑约定

1. **时间精确到分钟**，使用 IDE 当前时间
2. **改动写"做了什么"**，不只是说"修了 bug"
3. **原因写清楚**用户的需求或现象，让未来的自己能秒回忆
4. **文件列表**只写主要改动文件，资源/uid 不用列
5. **参数命名变化** 一定要双向标注：`旧名 → 新名`
