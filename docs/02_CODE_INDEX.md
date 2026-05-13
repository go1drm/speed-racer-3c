# 代码知识库索引

> 2026-05-12 定型版。给后来的人 / AI 快速找到"功能 X 在哪里"。

---

## 🚗 car.gd (核心物理 + 状态机, 3000+ 行)

### 顶层定义 (行号近似, 以实际为准)

| 区域 | 行号 | 内容 |
|---|---|---|
| 脚本头 | 1~50 | extends RigidBody3D + 文档头注释 |
| 信号定义 | ~500 | drift_started/ended, boost_triggered, wall_crashed, songqian_state_changed, songqian_back_boost_triggered, camera_shake_requested, ... |
| 基础移动 @export | ~60~150 | max_speed / top_speed_boosted / engine_force_max / brake_force_max / steering_deg / turn_speed / 摩擦系数 |
| 漂移基础 @export | ~150~250 | drift_min_speed / drift_min_angle_to_boost / drift_steer_mult / drift_body_tilt / drift_engage_duration / 反打系列 |
| 松前 @export | ~200~280 | songqian_drift_enabled / songqian_yaw_limit_deg / songqian_drift_kick_impulse / songqian_back_*  |
| 集气 @export | ~250~300 | charge_nitro_full / charge_per_lateral_m / charge_yaw_rate_weight |
| 喷射 @export | ~300~380 | mini_boost_power / double_boost_* / nitro_* / stack_* / drift_nitro_* |
| 撞墙物理 @export | ~380~430 | slope_as_wall_* / wall_reflect_* / wall_hit_* / wall_turnaround_* / wall_unstick_* |
| 空喷/落地喷 @export | ~430~490 | air_boost_* / landing_boost_* / landing_impact_absorb |
| 地面物理 @export | ~490~540 | ground_stick_* / plain_* / slope_stick_* / slope_align_* / uphill_assist_* |
| 曲线 @export | ~540~570 | engine_force_curve / friction_*_curve / drift_*_curve / boost_*_curve |
| 状态枚举 + 变量 | ~570~650 | State enum (NORMAL/DRIFT), 所有 _XX_t / _XX_left 运行时状态 |

### 核心函数

| 函数 | 职责 |
|---|---|
| `_ready()` | 出生点对齐, 接信号, 挂 BoostFX/DriftFX, 启动撞墙物理自检 |
| `_physics_process(delta)` | 主更新循环: 读输入 → 更新空中状态 → 地面物理 → 发 HUD 信号 |
| `_read_input(delta)` | 油门/刹车/转向/漂移/喷射按键处理 (倒车方向反转等) |
| `_update_air_state(delta, on_ground)` | 起飞/落地检测, _is_airborne 维护, 落地预输入回放 |
| `_apply_engine_and_brake(delta)` | 引擎推力 + 刹车 + 喷射推力 + 空喷下压力 + 反打减速 |
| `_apply_friction(delta)` | 前后向+侧向摩擦(带曲线), 漂移打滑衰减, 惯性感增强, 向心力拉力 |
| `_apply_ground_stick(delta)` | 防弹+贴附(平地/坡面两种处理) |
| `_apply_landing_physics()` | 落地瞬间 Y 速度吸收 + angular_velocity 清零 |
| `_try_start_drift()` | 尝试入漂: 速度/CD/Q 释放等检查 |
| `_end_drift(success, manual, failed)` | 退漂: 清松前状态 + 开小喷窗口 or failed |
| `_try_boost_w()` | W 键入口: 空中立即空喷 / 落地喷 / 小喷/双喷窗口 / 氮气 / 叠喷接力 |
| `_start_boost(type, power, time)` | 统一 boost 启动, type= mini/double/nitro/air/landing/wall_bounce/songqian_back |
| `_trigger_songqian_drift()` | 松前漂移: 踩回油门触发, 巨大冲量 + 爆发期 |
| `_trigger_songqian_back_boost(yaw)` | 三喷 (松前后退喷): 按 Q+W+角度足够触发 |
| `_update_visuals(delta)` | 车身侧倾 / 车头 yaw / 松前 yaw 偏移 / 地面法线对齐 / 弹墙掉头 yaw 插值 |
| `_calc_songqian_yaw_deg()` | 计算当前车头相对起漂方向的偏角 (用于三喷判定) |
| `_integrate_forces(state)` | Godot 物理回调: 撞墙反弹 (硬碰硬 + 弹墙掉头 + 防吸住), 锁速窗口 |
| `_on_body_entered(body)` | 接触监听兜底 (当前仅作为调试点) |
| `_spawn_glass_shatter(pos, n, speed)` | 撞墙时生成玻璃渣特效 |
| `_log_wall_physics_status()` | 启动 1.5s 后打印撞墙参数自检 (⚠️ 标注问题值) |

### 关键状态机

**drift 状态机** (State.NORMAL ↔ State.DRIFT):
- 入: `_try_start_drift()` (Q + 速度够 + 不在 CD)
- 出: `_end_drift()` (Q手动/低速/超时/撞墙/车正自动退)

**松前粘性锁定** (_is_in_songqian):
- 入口: `_update_visuals` 里 DRIFT + throttle<0.05
- 出口: `_trigger_songqian_drift` (踩回油门) / `_end_drift` (漂移结束)

**叠喷链** (_stack_chain_seq):
- 每次触发 boost 时追加 'C'(nitro) 或 'W'(mini/double/air/landing)
- 合法链: CW / CWW / WCW (其他组合无突破)
- 每次突破极速 ×stack_breakthrough_top_mult, 上限 stack_max_breakthrough

**撞墙反弹** (`_integrate_forces`):
- 冷却期 (_wall_hit_cooldown_left > 0) → 跳过反弹
- 聚合所有 wall contact 的平均法线
- 计算 into_wall 速度 → 切向衰减 + 法向反弹 e + Kickback + slide_boost(废弃)
- 硬位移 wall_unstick_offset 脱离接触面
- 启动锁速窗口 + 记录弹墙掉头 target_yaw

---

## 🎥 Camera3D.gd

肩后视角跟随相机。

| 函数 | 职责 |
|---|---|
| `_process(delta)` | FOV 变化 + 震屏 |
| `_physics_process(delta)` | 主跟随: XZ 用 lerp_speed 追 target 位置, Y 走稳定器逻辑 |
| `_stable_look_target()` | 返回 look_at 目标点: 车位置 + 车头方向 × lookahead_distance, Y 经过稳定 |
| `_on_camera_shake_requested(intensity, duration)` | 触发震屏 (oct-noise) |

**关键机制**:
- Y 稳定器: 死区内"极慢追"代替"完全不动", 消除坑洼路面一抖一停
- 前瞻焦点: 用**车头方向**(不是速度), 漂移时车头朝侧不会让镜头甩飞
- 喷射拉远: 氮气/双喷/小喷各自有独立的 zoom 倍率+持续时间+FOV 增量

---

## 🎨 Tuner.gd

调参 UI。TAB 切换显示。

**三级分类标记**:
- `__page` 顶级页签
- `__group` 页内大标题 (黄色)
- `__sub` 小标题 (浅蓝)
- `__hidden_start/__hidden_end` 包住已废弃参数 (不显示, 但加载兼容)

**数据源**:
- `PARAMS` — car.gd 主参数
- `CAR_MESH_PARAMS` — 玉麒麟外观 (YuqilinTuning 的 @export)
- `BOOST_FX_PARAMS` — BoostFX 喷射火焰特效
- `FX_PARAMS` — DriftFX 漂移特效
- `CAM_PARAMS` — Camera3D 镜头

**关键函数**:
- `_build_ui()` — 构建整个调参面板 + 竖排 tab + 每行 slider+spin+曲线按钮
- `_load_from_file()` — 加载 user://tune.cfg, 越界值自动放宽 row 范围 (不丢弃!)
- `_dispatch_apply(kind, prop, v)` — 按 kind (car/cam/fx/car_mesh/boost_fx) 分发应用

---

## 💨 BoostFX.gd / .tscn

喷射火焰特效 (GPU 粒子)。玉麒麟有 5 个 tailpipe, SUV 1 个。

| 关键变量 | 职责 |
|---|---|
| `flame_target_length` | 目标焰长 (米), 内部算 lifetime |
| `nitro_amount_base` / `_mult_0/1/2` | 氮气粒子量 (0/1/2 次突破) |
| `stars_*` | 星星散粒层 (颜色/数量/重力) |

---

## 🛞 DriftFX.gd / .tscn

漂移特效: 轮胎发光 + 胎印 trail + 火焰附着。

- `permanent_marks` — 胎印永久保留 (会卡)
- `tire_mark_only_rear` — 只后轮留印
- `glow_energy` — 轮胎发光

---

## 💥 GlassShatterFX.gd / .tscn (新增)

撞墙玻璃渣特效。由 car.gd 的 `_spawn_glass_shatter()` 实例化到接触点。

`configure_by_impact(speed, normal)` — 按撞击速度缩放粒子量, normal 决定炸开方向。

---

## 🧱 TrackWallTagger.gd (新增)

赛道墙识别器。挂在场景里作为 Track 的 sibling:
- `_ready` 后扫描父节点下所有 MeshInstance3D
- 按 `wall_keywords` 白名单 (wall/fence/barrier/墙/围栏...) 识别
- 为每个墙 mesh 创建独立 StaticBody3D + ConcaveCollisionShape3D
- 打 `wall` group + `collision_layer=4`
- car.gd `_integrate_forces` 优先识别带标签的 contact

**干跑模式** (`dry_run=true`): 只扫描打印不创建 body, 用于诊断 glb 里 mesh 命名。

---

## 🎨 YuqilinPaint.gd

玉麒麟 PBR 材质智能映射。FBX 材质名是自动编号 `Material #2720`, 没后缀线索,
所以**按 material instance ID 稳定映射** 4 套贴图, 轮子单独按节点名识别。

- `rebuild_materials()` — 重建所有材质 (YuqilinTuning 改参数时调)

---

## 🔧 YuqilinTuning.gd

玉麒麟外观调参 (挂在 CarMesh 根节点)。`@export` 的参数会被 Tuner 自动捕获:
- `fbx_scale / fbx_rot_y_deg / fbx_offset_y`
- `clearcoat_strength / clearcoat_roughness / normal_scale / subsurf_strength`
- setter 会触发 YuqilinPaint.rebuild_materials() 实时更新

---

## 🖼️ HUD.gd / .tscn

屏幕 UI:
- 速度显示 (km/h)
- 集气槽 (0~charge_nitro_full)
- 氮气格 (0~max_nitro_stock)
- 漂移弹字 (漂移/松前/松前漂移/退漂-小喷-双喷-氮气/三喷/空喷/落地喷/弹墙/撞墙)
- 叠喷链显示 (CWW/WCW 等)

连接 car.gd 的所有信号: `drift_started/ended`, `boost_triggered`, `wall_crashed`, `songqian_state_changed`, `songqian_back_boost_triggered`, `charge_changed`, `speed_changed`, `nitro_stock_changed`, `drift_charge_level_changed`, `boost_window_opened`, ...

---

## 🗺️ 场景文件

| 场景 | 用途 |
|---|---|
| `track_qinghuaci.tscn` | **默认场景** (小而精的青花瓷赛道) |
| `track.tscn` | 大赛道 (合并 trimesh) + 挂 TrackWallTagger |
| `car.tscn` | 默认赛车场景 (玉麒麟) |
| `car_suv.tscn` | 备用赛车 (SUV) |
| `test_scene.tscn` | 纯物理测试场景 |

---

## 🔗 自动加载 (Autoload)

| 脚本 | 用途 |
|---|---|
| `TrackSwitcher.gd` (`*`) | 监听按键切赛道 (未用?) |
| `CarSwitcher.gd` (`*`) | F3 切换车型 (玉麒麟 ↔ SUV) |

---

## 📊 关键数据流

```
玩家按键
  ↓
car.gd _read_input()
  ↓  state 转换
car.gd _update_drift_intensity / _try_start_drift / _end_drift
  ↓  物理力
car.gd _apply_engine_and_brake + _apply_friction
  ↓
RigidBody3D 移动 + _integrate_forces (撞墙时)
  ↓
car.gd _update_visuals (视觉 yaw/侧倾/弹墙掉头动画)
  ↓
emit_signal
  ↓
HUD.gd (弹字) + Camera3D.gd (镜头跟随) + BoostFX/DriftFX (特效)
```

---

## 🛠️ 常用调试命令

```powershell
# 读最新 godot 日志
Get-ChildItem "$env:APPDATA\Godot\app_userdata\简单飞车试验场\logs\" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { Get-Content -Encoding UTF8 $_.FullName -Tail 100 }

# 搜撞墙 log
Get-Content -Encoding UTF8 "$env:APPDATA\Godot\app_userdata\简单飞车试验场\logs\godot.log" | Select-String "撞墙|wall"

# 搜 parse error
Get-Content -Encoding UTF8 "$env:APPDATA\Godot\app_userdata\简单飞车试验场\logs\godot.log" | Select-String "ERROR|SCRIPT ERROR|Parse Error"
```

---

_本索引于 2026-05-12 基础3C 定型时建立。后续新加文件请追加在对应模块。_
