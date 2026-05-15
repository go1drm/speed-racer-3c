"""
一次性脚本: 往 track.tscn 里插入 3 个 GrappleAnchor 实例 + ext_resource

数学定位:
  CarMesh 在 track.tscn 的 top_level transform (世界空间):
    [0.0025831, 0, 0.999997,  0, 1, 0,  -0.999997, 0, 0.0025831,  -24.195219, 0, 42.964237]
  也就是:
    - 基点: (-24.2, 0, 42.96)
    - 车头朝向 (-Z 在 FBX 里是车头, 代入 basis.z = (0.99997, 0, 0.00258),
               所以 -basis.z ≈ (-0.99997, 0, -0.00258), 约 "世界 -X" 方向是车头)
  结论: 车大约往 **世界 -X 方向** 开. 所以锚点要放在 -X 方向一点的空中.

  放 3 个锚点:
    A: (-34, 10, 42.5)   车头正前方 10m, 高 10m
    B: (-48, 14, 38)     更远一些, 偏左 5m, 高 14m
    C: (-62, 18, 46)     更远, 偏右, 高 18m (做成阶梯状, 玩家能连续钩)

运行: python scripts/add_grapple_anchors.py
幂等: 如果已经存在 GrappleAnchor 节点就不重复插入
"""

import os
import re

TSCN_PATH = os.path.join(os.path.dirname(__file__), "..", "track.tscn")
TSCN_PATH = os.path.abspath(TSCN_PATH)

ANCHOR_UID = "uid://b1xgrappleanchor01"
ANCHOR_RES_PATH = "res://GrappleAnchor.tscn"
ANCHOR_EXT_ID = "grapple_anchor_ext"

ANCHORS = [
    ("GrappleAnchor_A", (-34.0, 10.0, 42.5),  (0.3, 0.85, 1.0, 1.0),  25.0, 1.5),
    ("GrappleAnchor_B", (-48.0, 14.0, 38.0),  (0.4, 1.0, 0.85, 1.0),  25.0, 1.5),
    ("GrappleAnchor_C", (-62.0, 18.0, 46.0),  (1.0, 0.6, 0.3, 1.0),   30.0, 1.8),
]


def build_anchor_nodes():
    """生成 3 个锚点节点的 tscn 片段"""
    lines = []
    for name, (x, y, z), (r, g, b, a), det, rad in ANCHORS:
        # 位置是世界空间 (parent="." 下, 没有层级 transform 叠加)
        tr = f"Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, {x}, {y}, {z})"
        lines.append(f'\n[node name="{name}" parent="." instance=ExtResource("{ANCHOR_EXT_ID}")]')
        lines.append(f'transform = {tr}')
        lines.append(f'anchor_radius = {rad}')
        lines.append(f'detect_radius = {det}')
        lines.append(f'anchor_color = Color({r}, {g}, {b}, {a})')
    return "\n".join(lines) + "\n"


def main():
    with open(TSCN_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    # 幂等检查: 已有 GrappleAnchor 就跳过
    if "GrappleAnchor_A" in content or 'ExtResource("grapple_anchor_ext")' in content:
        print("[add_grapple_anchors] 已存在锚点节点, 跳过")
        return

    # 1. 插入 ext_resource: 在最后一个 ext_resource 之后插入
    # 查找最后一个 [ext_resource ...] 行
    ext_pattern = re.compile(r'(\[ext_resource[^\]]*\][^\n]*\n)', re.MULTILINE)
    matches = list(ext_pattern.finditer(content))
    if not matches:
        raise RuntimeError("找不到 [ext_resource] 行, 无法插入")
    last_ext = matches[-1]
    insert_pos = last_ext.end()

    ext_line = (
        f'[ext_resource type="PackedScene" uid="{ANCHOR_UID}" '
        f'path="{ANCHOR_RES_PATH}" id="{ANCHOR_EXT_ID}"]\n'
    )
    content = content[:insert_pos] + ext_line + content[insert_pos:]

    # 2. 在 [editable path="Car"] 之前插入锚点节点
    # 如果找不到 [editable, 就插入到文件末尾
    anchor_block = build_anchor_nodes()
    editable_idx = content.rfind('[editable path=')
    if editable_idx == -1:
        content = content.rstrip() + "\n" + anchor_block
    else:
        # 往前找到行首
        line_start = content.rfind('\n', 0, editable_idx) + 1
        content = content[:line_start] + anchor_block + "\n" + content[line_start:]

    with open(TSCN_PATH, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"[add_grapple_anchors] 已插入 {len(ANCHORS)} 个锚点到 {TSCN_PATH}")
    for name, pos, _, _, _ in ANCHORS:
        print(f"  - {name} @ {pos}")


if __name__ == "__main__":
    main()
