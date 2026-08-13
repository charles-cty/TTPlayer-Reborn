# 测试体系文档

## 概述

TTPlayer Reborn 采用四层测试框架，保证 Lazarus/FPC 重写版与 Qt C++ 版的 **UI/UX 完全一致性**。测试由 `tools/test-all.ps1` 统一驱动。

```
tools/test-all.ps1
├── Layer 1  差分测试（test-layer1.ps1）
└── Layer 2/3/4  FPCUnit（pascal/bin/tests.exe）
    ├── Layer 2  快照测试（UTestLayer2）
    ├── Layer 3  Expect 测试（UTestLayer3）
    └── Layer 4  Metamorphic 测试（UTestMetamorphic）
```

**当前状态：11/11 通过**

---

## 分层说明

### Layer 1 — Differential Testing（差分测试）

**文件**：`tools/test-layer1.ps1`  
**方法**：Qt 版为参照实现，Pascal 版为被测实现，两者输出进行差分对比。

Qt 版提供 `--dump-skin <skn|dir> --out <file.json>` 命令行模式（`src/tools/SkinDumper.cpp`），将 `SkinData` 序列化为规范化 JSON：

- 键按字典序排列
- 颜色统一为小写 `#rrggbb`
- 矩形统一为 `{x, y, w, h}`
- 字体记录 `{family, pixel_size, bold, italic}`
- 图像只记录名称和尺寸，不含像素数据

Pascal 版 `ttdump.exe`（`pascal/ttdump.lpr`）输出格式与 Qt 版完全对应。

**运行**：
```powershell
pwsh tools/test-layer1.ps1           # 测试全部 11 套皮肤
pwsh tools/test-layer1.ps1 -Skin Classic  # 测试单个皮肤
```

**失败输出**：字段级差异路径，如 `$.equalizer_window.elements[2].thumb_resize_center: 期望 5 实际 0`。

---

### Layer 2 — Snapshot Testing（快照测试）

**文件**：`pascal/tests/UTestLayer2.pas`  
**方法**：离屏渲染 → 与 Qt 版 golden PNG 逐像素对比（容差 ±1，文本/动画区域排除）。

#### 状态矩阵

每套皮肤测试以下帧（`player_window`）：

| 帧名 | 状态 |
|---|---|
| `player__default` | 初始状态，进度 0，音量 100 |
| `player__progress37` | 进度 37%，音量 60% |
| `player__hover-play` | play 按钮悬停态 |
| `player__pressed-play` | play 按钮按下态 |
| `player__toggled-mute` | mute 按钮切换态 |

`equalizer__default` / `equalizer__sliders` / `lyric__default` / `playlist__default` 帧已生成，随后续窗口移植逐步接入测试。

#### 掩码机制

文本渲染（矢量字体）和时变内容（频谱动画）在跨实现时无法逐像素一致，通过 `tests/golden/masks/<皮肤>.json` 排除：

- 排除类型：`info`、`lyric`、`playlist`、`visual`、`stereo`、`status`、`icon`
- 排除区域内：弱断言（非空）
- 排除区域外：逐像素对比，容差 ≤ 1（8-bit 预乘往返的固有 ±1 舍入）

#### 失败诊断

测试失败时，在 `tests/artifacts/layer2/<皮肤>/` 下输出三联图：
- `<帧名>.expected.png` — Qt golden
- `<帧名>.actual.png` — Pascal 实际输出
- `<帧名>.diff.png` — 红色标注差异像素

#### 已知跳过

`Subaru_Offbeat_TTPlayer57`：Qt offscreen 模式下 `setMask` 导致渲染输出整体偏移 (+7, +11)，是 golden 生成端的问题，暂时跳过。修复 FrameDumper 渲染原点后重新启用。

#### Golden 生成

```powershell
# Qt 版需已编译（build-mingw64/TTPlayerReborn.exe）
pwsh tools/gen-golden.ps1 -SkipBuild   # 跳过编译步骤
pwsh tools/gen-golden.ps1              # 先编译再生成
```

`gen-golden.ps1` 对每套皮肤依次运行：
1. `--dump-skin` → `tests/golden/skinjson/<皮肤>.json`
2. `--dump-frames` → `tests/golden/frames/<皮肤>/<帧名>.png` + `tests/golden/masks/<皮肤>.json`

**何时需要重新生成**：修改 Qt 侧渲染逻辑（`PlayerWindow::paintEvent`、`SkinButton::paintEvent` 等）后，需重新生成 golden，然后重新跑 Layer 2 验证 Pascal 侧是否仍然一致。

---

### Layer 3 — Expect Testing（期望值测试）

**文件**：`pascal/tests/UTestLayer3.pas`  
**方法**：表驱动用例，期望值硬编码，覆盖解析器的边界条件。

| 用例 | 覆盖内容 |
|---|---|
| `TestParsePosition` | `x1,y1,x2,y2` → `{x,y,w,h}` 换算、空白容错、字段不足 |
| `TestParseColor` | `#rrggbb`、大写、`#rgb` 缩写、无效输入 |
| `TestParseLogFont` | 负/正高度、粗体（weight≥700）、字段不足 |
| `TestParseBool` | `1/true/yes/YES/0/no/空` |

---

### Layer 4 — Metamorphic Testing（变形测试）

**文件**：`pascal/tests/UTestMetamorphic.pas`  
**方法**：不验证具体输出值，而是验证两次调用结果之间必须满足的数学/语义关系。适用于"输出难以直接给出期望值，但关系是已知的"场景。

#### MR-1：滑块位置计算的数学性质

被测函数：`USkinRender.SliderValueToPos` / `SliderPosToValue`

| 变形关系 | 描述 |
|---|---|
| **MR-1a 单调性** | v1 < v2 → pos(v1) ≤ pos(v2)（水平滑块，101 个采样点） |
| **MR-1b 边界** | pos(min)=0，pos(max)=track-thumb；超出范围夹取 |
| **MR-1c 对称性** | pos(v) + pos(min+max−v) = track−thumb（允许 ±1 截断误差） |
| **MR-1d 往返一致** | posToValue(valueToPos(v)) ≈ v（误差 ≤ (max-min)/trackLen） |

#### MR-2：色键变形（transparent_color 替换不影响布局）

对同一 Skin.xml，分别用 `#ff00ff` 和 `#00ff00` 作为 `transparent_color` 解析，断言：
- 元素数量相同
- 各元素的 `type` 和 `position` 完全一致

**变形关系语义**：颜色替换是"不影响结果"的输入变换（在图像中无对应像素时），验证解析器没有把色键语义混入布局计算。

#### MR-3：位置解析与背景图尺寸无关

对同一 Skin.xml，分别搭配 275×116（Classic 尺寸）和 540×286（Subaru 尺寸）的背景图解析，断言各元素 `position` 完全一致。

**变形关系语义**：`position` 坐标来自 XML 文本，不应受图像尺寸影响。

#### 扩展计划

随后续模块移植，将补充：
- **MR-4 WindowSnapManager 对称性**：A 向 B 吸附的结果等价于 B 向 A 吸附（录制回放 + 角色互换）
- **MR-5 EQ 增益中性**：所有频段增益为 0 时，输出与无 EQ 等价

---

## 测试运行

### 完整测试套件

```powershell
pwsh tools/test-all.ps1
```

可选参数：
- `-SkipLayer1`：跳过 Layer 1
- `-SkipFPCUnit`：跳过 Layer 2/3/4

### 仅 FPCUnit

```powershell
# 运行全部 FPCUnit 测试（带详细输出）
.\pascal\bin\tests.exe -a --format=plain

# 只跑某个测试类
.\pascal\bin\tests.exe --suite=TMetamorphicTest --format=plain
```

### 构建后测试

```powershell
pwsh tools/build-pascal.ps1    # 构建
pwsh tools/test-all.ps1        # 测试
```

---

## 技术约束与注意事项

**渲染确定性**：golden 生成时固定 `QT_SCALE_FACTOR=1`，`QT_ENABLE_HIGHDPI_SCALING=0`，避免高 DPI 机器产出不一致的基准。

**合成精度**：`USkinRender` 中的 `QtPutImage` 精确复刻 Qt 的 premultiply/source-over/unpremultiply 整数舍入路径，使 Layer 2 在非文本区域达到逐像素一致（误差 ≤ 1）。

**文本排除**：矢量文本（info 歌曲名、歌词、播放列表条目）在不同渲染引擎间无法逐像素一致，通过 masks 机制排除。LED 位图字体（number.bmp）不排除，因其输出可精确复刻。

**BMP 加载**：32-bit BMP 的 alpha 通道全零（常见于旧皮肤），通过 `TBGRAReaderBMP.TransparencyOption := toOpaque` 强制不透明，与 Qt `QImage::fromData` 行为对齐。
