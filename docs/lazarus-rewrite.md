# Lazarus 重写计划

> 本文档描述将 TTPlayer Reborn 的 GUI 从 Qt6 C++ 重写为 Lazarus/FPC 的完整计划。最新进展见文末"当前状态"。

---

## 背景与可行性

TTPlayer Reborn 的 UI 本来就是**全自绘**（无边框 + `setMask` + 位图合成），皮肤格式与框架无关，渲染一致性由皮肤位图决定而非框架控件。这使 Qt→Lazarus 迁移的条件远好于一般 GUI 框架迁移：

- 不依赖 Qt 样式化控件（LCL 控件库贫弱的短板影响极小）
- 皮肤 `.skn` 格式（ZIP + BMP + XML）在 Pascal 中有完整对等实现（Zipper、fcl-xml）
- 音频层（FFmpeg+soxr+SDL2+TagLib）与 Qt GUI 耦合极浅，可独立抽库

估计工作量：2–4 个月（熟悉双方框架）。

---

## 技术选型

| 决策项 | 选择 | 说明 |
|---|---|---|
| 音频核心 | C++ → C ABI DLL/so | 现有代码编成 `ttcore.dll/libttcore.so`，Pascal 侧 FFI；不重写 |
| 绘图 | BGRABitmap | Lazarus 生态事实标准软渲染库；32-bit alpha、抗锯齿文本、渐变；跨平台渲染结果完全一致，解决 GTK/GDI 文本差异 |
| 异形窗口 | 区域裁剪 | Windows `SetWindowRgn` / Linux X11 Shape；从皮肤色键生成；与老 TTPlayer 原版行为一致 |
| Linux widgetset | GTK3 | 依赖更现代；Shape/置顶/EWMH 直接调 X11 绕开 LCL（GTK3 后端 bsNone 相关 bug 较多） |

### GTK3 风险与绕行

LCL GTK3 后端在以下方面已知不稳定：
- `bsNone`（无边框）+ 置顶 + Tool 窗口类型
- CSD（客户端装饰）可能引入隐性坐标 margin，影响窗口吸附计算

绕行方案：Shape/置顶/EWMH 直接调 X11 API，绕开 LCL；所有平台相关代码隔离在 `src/ui/platform` 单元（`{$IFDEF}`），必要时可退回 GTK2 或 Qt6 widgetset。

---

## 架构设计

```
ttcore.dll / libttcore.so    ← 现有 C++ 音频核心（C ABI）
  提供：open/play/pause/seek/volume/EQ/spectrum/metadata
  回调：进度、曲目结束、错误（函数指针，cdecl）
  注意：回调来自音频线程，Pascal 侧须 TThread.Queue 转主线程

Lazarus 工程（全自绘）
  src/backend/    IPlayerBackend 接口 + TStubBackend 桩（GUI 开发期使用）
  src/skin/       皮肤引擎（USkinTypes/USkinXmlParser/USkinLoader/USkinJsonDump）
  src/render/     渲染原语（USkinRender，QtPutImage 精确合成）
  src/ui/         PlayerForm/PlaylistForm/EqualizerForm/LyricForm（无边框自绘）
  src/ui/platform/ Windows/X11 平台特定调用（SetWindowRgn、XShape、EWMH）
```

### C ABI 边界约定

- 字符串：统一 UTF-8 `const char*`，由 C 侧管理生命周期
- 频谱数据：Pascal 侧传入缓冲区，C 侧填充（避免跨边界内存所有权）
- 回调：`cdecl` 函数指针，必须从主线程消费信号

---

## 移植顺序

> GUI 优先，音频抽库最后。每步都有可运行/可验证的里程碑。

**Step 0（已完成）**：IPlayerBackend 接口 + TStubBackend 桩（定时器假进度、固定频谱），GUI 全程不依赖真实音频。

**Step 1（已完成）**：皮肤引擎
- Zipper 解 .skn（~40 种元素类型）
- USkinXmlParser：Skin.xml / Lyric.xml / PlayList.xml / Visual.xml / 侧车布局
- LOGFONT 字符串解析（负高度换算：`px = Abs(lfHeight)`）
- 色键（`#FF00FF`）→ alpha 替换
- USkinRender：背景合成 + 按钮四态 + 滑块（bar/thumb/fill）+ LED 位图字体
- **验收**：11 套皮肤 JSON 差分为零（Layer 1）；10 套皮肤像素级一致（Layer 2）

**Step 2（下一步）**：PlayerForm
- `bsNone` 无边框窗口
- 色键生成 Shape 区域（换肤时 run-length 建 `HRGN`/`XRectangle[]`）
- 按钮命中测试、悬停/按下视觉状态
- 窗口拖动
- **关键**：此步同时在 Windows 和 GTK3 上验证，最早暴露 GTK3 风险

**Step 3**：PlaylistWindow（4.8k 行 C++，最大头）
- 虚拟列表、拖放、内嵌搜索

**Step 4**：EqualizerWindow

**Step 5**：LyricWindow + VisualWidget（频谱动画）

**Step 6**：WindowSnapManager（1.4k 行，Winamp 式窗口吸附）
- GTK3 CSD 坐标问题在此步验证

**Step 7（最后）**：ttcore 抽库 + FFI 对接，替换 TStubBackend

---

## 皮肤格式参考

皮肤文件为 `.skn`（ZIP 包），内含：
- `Skin.xml`：窗口定义、元素（按钮、滑块等）、坐标
- `Lyric.xml`、`PlayList.xml`、`Visual.xml`：各窗口配置
- 若干 BMP/PNG 图片资源

关键解析细节：
- 坐标格式：`x1,y1,x2,y2`（闭合区间），换算为 `{x, y, w=x2-x1, h=y2-y1}`
- 按钮精灵图：横向 N 帧（N=4：normal/hover/pressed/disabled），按不透明列区段或等分切割
- 滑块：`bar_image`（背景轨道）+ `thumb_image`（拖柄，多态）+ `fill_image`（填充）
- LOGFONT：`"-11,0,0,0,400,0,1,0,1,0,0,4,0,Tahoma"` → `PixelSize=Abs(-11)=11, Bold=(400<700)=false`
- 默认透明色：`#FF00FF`（可被皮肤 XML 覆盖）

---

## 当前状态（2026-08-13）

**已完成（Step 0–1 + 测试框架）**：

| 交付物 | 位置 |
|---|---|
| git 分支 `lazarus-rewrite` | — |
| BGRABitmap v11.6.6 | `pascal/vendor/bgrabitmap`（git submodule） |
| 皮肤引擎 | `pascal/src/skin/`（USkinTypes/USkinXmlParser/USkinLoader/USkinJsonDump） |
| 渲染原语 | `pascal/src/render/USkinRender` |
| 后端接口+桩 | `pascal/src/backend/UPlayerBackend` |
| Pascal dump 工具 | `pascal/ttdump.lpi` |
| Qt SkinDumper | `src/tools/SkinDumper.{h,cpp}` + `--dump-skin` |
| Qt FrameDumper | `src/tools/FrameDumper.{h,cpp}` + `--dump-frames` |
| Golden 基准（11 套皮肤） | `tests/golden/skinjson/`, `frames/`, `masks/` |
| 测试（11/11） | `tools/test-all.ps1` |

**下一步**：Step 2 — PlayerForm（无边框窗口 + Shape + 按钮交互）。

---

## 待定决策

- `Config`：QSettings 格式迁移到 FPC `TIniFile`？
- 双构建链（CMake + lazbuild）的顶层串联脚本形式？
