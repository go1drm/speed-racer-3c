# 🔥 基础 3C 高压线

> **2026-05-12 基础3C 第一版定型稿**
>
> 以下所有代码和参数已经被用户亲手调校到满意的手感。
> **任何 AI/开发者要改动这些内容, 必须先在对话框里明确声明改动范围并征求同意, 严禁擅自修改!**

---

## ⚠️ 为什么有这份文档?

基础 3C (Character / Camera / Control) 经历了**几十轮反复调校**才达到当前的手感:
- 漂移入/出弯的曲线
- 松前打滑 + 松前漂移 + 三喷组合
- 反打回正动画 + 物理减速
- 撞墙硬碰硬反弹 + 弹墙掉头 + 防吸住
- 空喷离地瞬间触发 + 滞空感下压力
- 镜头 Y 稳定 + 前瞻焦点
- 落地瞬秒不弹跳 + 不悬浮

这些手感是**系统性的平衡**, 动一个参数会牵一发动全身。所以:
1. **用户在 Tuner UI 里调过的值是神圣的** — 代码里不能擅自改 @export 默认值或 tune.cfg
2. **涉及 3C 的代码改动需要先问用户** — 不能主动重构"核心三件套"
3. **新功能优先新加参数 + 默认关闭** — 不能关了旧功能或改旧默认

---

## 🔒 受保护的文件 (改动需先问用户)

| 文件 | 为什么受保护 |
|---|---|
| `car.gd` | 赛车物理核心 3000+ 行, 80% 是被调过的平衡点 |
| `Camera3D.gd` | 镜头所有跟随/拉远/稳定机制都被反复调过 |
| `Tuner.gd` | 调参 UI 本身 + 参数定义, 改错了整个调参系统会崩 |
| `HUD.gd` | 漂移弹字/状态信号的协议已与 car.gd 绑定 |

**不受保护的**: 新加的独立特效(`BoostFX/DriftFX/GlassShatterFX`)、工具脚本(`TrackSetup/TrackSwitcher/CarSwitcher`)、新增赛道/特效。

---

## 🧱 受保护的参数 (Tuner 可见参数的默认值)

### 💡 关键规则
- 用户在 Tuner UI 里调过的参数值会保存到 `user://tune.cfg`, **这个值是神圣的**
- `Tuner._load_from_file()` 已经有**越界放宽逻辑**: 即使后续代码把 min/max 改了, 加载时也会 clamp 而不是丢弃
- 但是 **@export 默认值** 就是用户的"重置"目标, 不许擅自改

### 🛑 绝对不能动的默认值 (都在 `car.gd` 顶部 @export 定义)

#### 基础移动
- `max_speed` / `top_speed_boosted` / `engine_force_max` / `brake_force_max`
- `steering_deg` / `turn_speed` / `turn_speed_high_speed_mult` / `high_speed_threshold`

#### 漂移系统
- `drift_min_speed` / `drift_min_angle_to_boost` / `drift_max_duration`
- `drift_steer_mult` / `drift_accel_mult` / `drift_counter_steer_mult`
- `drift_engage_duration` / `drift_disengage_duration` / `drift_head_yaw_duration_ref`
- `drift_body_tilt` / `drift_yaw_offset_tuck` / `drift_yaw_offset_side`
- `drift_exit_boost_duration` / `drift_exit_boost_mult`
- `post_drift_steer_cooldown` / `post_drift_steer_mult`

#### 松前 / 三喷
- `songqian_drift_enabled` / `songqian_yaw_limit_deg` / `songqian_yaw_speed_deg`
- `songqian_drift_kick_impulse` / `songqian_drift_boost_duration`
- `songqian_enter_kick_impulse` / `songqian_steer_mult`
- `songqian_back_*` 全套

#### 反打
- `drift_counter_lean_mult` / `drift_counter_lean_smooth`
- `drift_counter_decel_enabled` / `drift_counter_decel` / `drift_counter_decel_min_steer`

#### 喷射
- `mini_boost_power` / `mini_boost_time`
- `double_boost_power` / `double_boost_time` / `double_charge_hold_time` / `double_charge_window`
- `nitro_power` / `nitro_time` / `nitro_require_throttle`
- `stack_link_window` / `stack_breakthrough_top_mult` / `stack_max_breakthrough`
- `air_boost_power` / `air_boost_time` / `air_boost_downforce`
- `landing_boost_power` / `landing_boost_time` / `landing_boost_press_window`
- `landing_impact_absorb`

#### 撞墙物理
- `slope_as_wall_enabled` / `slope_wall_angle_deg` / `wall_normal_y_threshold`
- `wall_reflect_normal_factor` / `wall_reflect_tangent_keep_max/min/lerp_speed`
- `wall_hit_kickback` / `wall_straight_tangent_kill`
- `wall_turnaround_*` 全套
- `wall_hit_cooldown` / `wall_unstick_offset` / `wall_hit_speed_cap_mult` / `wall_hit_lock_duration`

#### 地面物理
- `plain_vy_zero_threshold` / `plain_downforce` / `plain_downforce_vy_gate`
- `slope_stick_force` / `slope_stick_max_vy` / `slope_stick_max_deg`
- `slope_align_thrust` / `slope_gravity_compensation`
- `uphill_assist_*` 全套

#### 集气
- `charge_nitro_full` / `charge_per_lateral_m` / `charge_yaw_rate_weight`
- `max_nitro_stock` / `crash_charge_penalty`

#### 镜头 (在 `Camera3D.gd`)
- `lerp_speed` / `max_follow_lag` / `offset.*`
- `nitro_zoom_*` / `double_zoom_*` / `mini_zoom_*`
- `y_stabilizer_enabled` / `y_deadzone` / `y_follow_speed_mult` / `y_force_follow_vy`
- `lookahead_distance` / `lookahead_height`

---

## ✅ 允许的改动

1. **新增功能参数**: 加 `@export` 新变量, 注册进 `Tuner.PARAMS` 里新 group, 默认关闭或保守值
2. **隐藏废弃参数**: 用 `__hidden_start / __hidden_end` 包住, 保留变量定义兼容旧 cfg
3. **调整 UI 分组/标签/tooltip**: 不改参数名和默认值
4. **新增独立模块**: 新的 `.gd` 文件 / 新特效 / 新赛道
5. **修 bug**: 对明确的 bug 可以改 (比如 parse error、空指针), 但修完要在 CHANGELOG 说明

---

## 🔄 如何正确提出改动申请

当 AI 想改上面受保护的东西时, 必须先在对话框里这样声明:

```
⚠️ 涉及基础3C改动通告:
- 文件: car.gd
- 改动: 修改 drift_engage_duration 默认值 0.15 → 0.20
- 原因: <原因>
- 影响: 入漂过渡会变慢一点, 手感变柔和
请问是否同意? (y/n)
```

**用户回复 "y" 或 "同意" 才能动手, 否则只能加新参数不覆盖默认。**

---

_本高压线声明于 2026-05-12 基础3C 第一版定型时建立。_
