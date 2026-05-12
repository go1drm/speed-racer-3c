# 自定义赛道导入指南

## 📂 文件放置路径
把你的 FBX 文件直接拖/复制到这个目录：

```
c:\Users\shilohuang\Downloads\3d_car_sphere-master\assets\custom_tracks\
```

例如：`my_track.fbx`、`my_track.bin`（如果有）、贴图文件夹

---

## ⚠️ Godot 4 对 FBX 的支持

Godot 4 **支持 FBX 导入**，但有两个注意点：

1. **2024+ 版本的 Godot 4** 内置了 FBX 导入器（基于 ufbx），无需额外配置。
2. 老版本 Godot 4 需要装 FBX2glTF 工具。本项目用的是 Godot 4.6.1 ✅ 已内置。

### 直接导入 FBX
1. 把 `.fbx` 文件复制到本目录
2. Godot 编辑器会自动检测并生成 `.import` 文件
3. 如果出现"格式不支持"错误，按下面**备选方案**

### 备选方案：转成 GLB 再导入（推荐）
推荐先把 FBX 转成 GLB 格式，效果更稳定：

**方法 A：Blender 导出（最稳）**
1. 用 Blender 打开 FBX
2. 文件 → 导出 → glTF 2.0 (.glb/.gltf)
3. 选择 **glTF Binary (.glb)** 格式
4. 把导出的 `.glb` 放到本目录

**方法 B：在线转换器**
- https://products.aspose.app/3d/conversion/fbx-to-glb
- https://anyconv.com/fbx-to-glb-converter/

---

## 🏁 导入到游戏中

把文件放进来后，告诉我**文件名**和你的需求（比如"替换当前赛道"还是"作为新关卡"），我会帮你：

1. 把模型挂进 `track.tscn`
2. 处理碰撞（需要为赛道生成 trimesh collision shape）
3. 调整起始点和摄像机
4. 设置材质（如果需要）

---

## 📋 推荐的 FBX 导出设置（如果你在用 Blender/Maya）

- **比例**：1 单位 = 1 米（Godot 标准）
- **坐标系**：Y up（Godot 也是 Y up，这样不会倒置）
- **包含贴图**：选 "Embed Textures"（避免贴图缺失）
- **三角化网格**：开启（提升导入兼容性）
- **应用变换**：导出前在 DCC 软件里 Apply All Transforms（避免缩放问题）

---

## 当前已有的赛道资源

- `assets/track_2.glb` - 当前默认赛道（被 `track.tscn` 引用）
- `assets/GLTF format/` - Kenny.nl 城市套装（房屋、车辆等装饰）
