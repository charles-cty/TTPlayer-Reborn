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
| Linux widgetset | GTK3 + X11 | 只做 XWayland/Xorg（`GDK_BACKEND=x11`）。不支持 Wayland 客户端。Shape/置顶走 X11，绕开 LCL |

### GTK3 风险与绕行

LCL GTK3 后端在以下方面已知不稳定：
- `bsNone`（无边框）+ 置顶 + Tool 窗口类型
- CSD（客户端装饰）可能引入隐性坐标 margin，影响窗口吸附计算
- **HWND 不是 `GtkWidget*`**：GTK2 的 `Handle` 是控件指针；GTK3 的 `Handle` 是 `TGtk3Widget` 对象。对 Handle 直接调用 `gtk_widget_get_window` 会 `GTK_IS_WIDGET` 失败，严重时 Access violation（`G_DEBUG=fatal-criticals` 下为 SIGTRAP）

绕行方案：`UGdkX11Backend` 在 `Interfaces` 之前强制 `GDK_BACKEND=x11` 和 `GTK_CSD=0`。`ConfigurePlatformWindow` 再关 decorated / Motif 装饰（不要 `set_titlebar(nil)`）。Shape/置顶走 X11 + `gtk_window_set_keep_above`；拖动走 LCL capture。句柄转换见 `GdkWindowFromLCLHandle`。原生 Wayland 不在支持范围。

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
                  UWindowSnapMath / UWindowSnapManager / UFormSnap（窗口吸附）
  src/ui/platform/ Windows/X11 平台特定调用（SetWindowRgn、XShape、EWMH；Linux 仅 XWayland/Xorg）
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

**Step 2（已完成，Windows）**：PlayerForm
- `bsNone` 无边框窗口
- 色键生成 Shape 区域（`UPlatformWindow.ApplyAlphaShape`：Win `SetWindowRgn` / X11 `XShapeCombineRectangles`）
- 按钮命中测试、悬停/按下视觉状态
- 窗口拖动
- GTK3：`UPlatformWindow` 已在 WSL2/WSLg 上探测（见文末当前状态）

**Step 3（已完成）**：PlaylistWindow
- 虚拟列表、7 组工具栏菜单、皮肤滚动条、文件拖放、双击 OpenFile
- TTBL v3/v5 读写、列表内拖放重排、搜索对话框、多播放列表标签页
- 未移植：元数据加载器（等 ttcore / TagLib）

**Step 4（已完成）**：EqualizerWindow

**Step 5（已完成）**：LyricWindow + VisualWidget（频谱动画）
- LRC 解析 + 按 `TStubBackend` 假进度滚动高亮

**Step 6（已完成，Windows）**：WindowSnapManager（Winamp 式窗口吸附）
- 独立双轴吸附、主窗口联动组、子窗口单独拖动、松手吸附、屏幕边缘、缩放吸附
- 几何与图结构可在 NoLCL FPCUnit 中验证（MR-4）
- Windows：`TSnapFormAdapter` 子类化原生 WndProc 收取 `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE`（LCL `WindowProc` 收不到跨进程 `SendMessage`）；DPI≠100% 时 `GetBounds`/`MoveTo` 在 LCL 逻辑像素与 `GetWindowRect` 物理像素之间换算（`UDpiScale`）
- `src/ui/platform/`：Win `SetWindowRgn`；Linux 仅 X11 Shape + EWMH（`UGdkX11Backend` 强制 XWayland）。GTK3 用 `TryBeginCaptionDrag`（LCL capture）对齐 Windows 的 HTCAPTION + `OnDragStarted/Finished`；`PlatformGetWindowRect` 用 GDK client 几何，避开 CSD frame_extents。DPI/GDK_SCALE：皮肤与吸附在逻辑像素；`ApplyAlphaShape` 在 native 尺寸是均匀 UI 缩放时放大 Region/XShape。禁止把 CSD 宽高比当 DPI。皮肤视图：Windows Per-Monitor V2 下 LCL 客户区 = 皮肤×DPI/96；皮肤位图最近邻拉伸，播放列表/歌词在 dest 像素栅格化文字；GTK `GDK_SCALE≥2` 时 LCL 保持 1×（cairo 已设备缩放）。跨监视器 `WM_DPICHANGED` / 移动时 `RefreshViewScale`。

**Step 7（推迟）**：ttcore 抽库 + FFI 对接，替换 TStubBackend。音频核与 GUI 解耦，可等 GUI 与测试补齐后再做。

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

## 当前状态（2026-08-24）

**已完成（Step 0–6 + GUI/测试补齐）**。四个皮肤窗口可在 `skinpreview` 中同时显示，Windows 下支持 Winamp 式吸附；音频仍为 `TStubBackend`。

| 交付物 | 位置 |
|---|---|
| git 分支 `lazarus-rewrite` | — |
| BGRABitmap v11.6.6 | `pascal/vendor/bgrabitmap`（git submodule） |
| 皮肤引擎 | `pascal/src/skin/`（USkinTypes/USkinXmlParser/USkinLoader/USkinJsonDump） |
| 渲染原语 | `pascal/src/render/USkinRender`（QtPutImage 精确合成、九宫格、LED） |
| 后端接口+桩 | `pascal/src/backend/UPlayerBackend`（IPlayerBackend + TStubBackend） |
| 播放列表模型 | `pascal/src/playlist/UPlaylistModel` + `UTtbl` + `UPlaylistBook` |
| LRC 解析 | `pascal/src/lyric/ULrcParser` |
| PlayerForm | `pascal/src/ui/UPlayerForm`（无边框、Region、按钮交互、拖动、OnAuxToggle） |
| PlaylistForm | `pascal/src/ui/UPlaylistForm`（虚拟列表、工具栏、滚动条、拖放、TTBL、多标签、搜索、列表内 DnD） |
| EqualizerForm | `pascal/src/ui/UEqualizerForm`（10 波段 + preamp/balance/surround 滑块） |
| LyricForm | `pascal/src/ui/ULyricForm`（九宫格、LRC 滚动高亮、右/下边缘调整大小） |
| VisualWidget | `pascal/src/ui/UVisualWidget`（柱状频谱 + 模糊示波图动画） |
| WindowSnap | `pascal/src/ui/UWindowSnapMath` + `UWindowSnapManager` + `UFormSnap` |
| 平台窗口 | `pascal/src/ui/platform/UPlatformWindow` + `UAlphaShape` + `UDpiScale` + `USkinView` + `UWinDpiAware` + `UGdkX11Backend`（Win `SetWindowRgn` / X11 Shape + EWMH；GTK3 Handle→`TGtk3Widget`；强制 XWayland；DPI 视图缩放 + Per-Monitor V2） |
| Pascal 工具集 | `pascal/ttdump.lpi`、`pascal/skinpreview.lpi`、`pascal/ttplayer.lpi`、`pascal/tests.lpi` |
| Linux GTK3 构建 | `tools/build-pascal-linux.sh`（用户目录 FPC 3.2.2 + Lazarus 4.8，`--ws=gtk3`） |
| GTK3 探测 | `skinpreview --probe` + `tools/test-gtk3-wayland.sh` + `tools/smoke_gtk3_wayland.py` |
| Qt SkinDumper | `src/tools/SkinDumper.{h,cpp}` + `--dump-skin` |
| Qt FrameDumper | `src/tools/FrameDumper.{h,cpp}` + `--dump-frames`（捕帧前 `clearMask`，playlist/lyric 按 `baseSize`） |
| Golden 基准（11 套皮肤） | `tests/golden/skinjson/`, `frames/`, `masks/` |
| 测试（Windows 48/48；Linux FPCUnit 72/72，含 AlphaShape + DpiScale + NearestResample + snap Detach） | `tools/test-all.ps1`（Layer 1/2/3/4 + PlaylistModel + LRC + TTBL + WindowSnap/MR-4 + Layer 5）；Linux：`tools/test-gtk3-wayland.sh` |

**GTK3 + XWayland（WSL2/WSLg，2026-08-24）**

环境：Ubuntu 24.04 用户目录 FPC 3.2.2 + Lazarus 4.8。Linux **只做 X11**（`UGdkX11Backend` 在 `Interfaces` 之前写 `GDK_BACKEND=x11`、`GTK_CSD=0`）。WSLg 上即 XWayland（`DISPLAY=:0`）。原生 Wayland 客户端不支持。

| 探测 | 结果 |
|---|---|
| `skinpreview --probe` | `backend=x11`，`shape_supported=true`；四窗口须在；程序化吸附须合缝 |
| 无边框 | `CreateWnd`/`DoShow` 调 `ConfigurePlatformWindow`：`gtk_window_set_decorated(0)` + Motif 去装饰。禁止 `gtk_window_set_titlebar(nil)`（会恢复 CSD） |
| 拖动 / 吸附 | `TryBeginCaptionDrag` 按 `WMNCHitTest=HTCAPTION` 捕获鼠标，走同一套 `OnDragStarted/Move/Finished` |
| DPI | `UDpiScale` + `USkinView`：宽高均匀缩放到 125/150/200% 才换算，CSD 比不当 DPI。Shape 按 `XGetGeometry`（GDK_SCALE=2 时 X 窗口 2×，`gdk_window_get_width` 仍是逻辑尺寸）。吸附在逻辑像素；WSLg 原点对不齐时用 LCL 坐标。Windows：`UWinDpiAware` Per-Monitor V2，窗体按 `view_scale` 放大皮肤；皮肤位图最近邻拉伸（不用 GDI HALFTONE）；播放列表/歌词 TrueType 在 dest 像素栅格化（`fqFineClearTypeRGB`）。拖到另一监视器走 `WM_DPICHANGED`。GTK：`GDK_SCALE≥2` 时 `view_scale=1`，禁止 `SetBounds(skin*2)`（否则 X 窗口 4×） |
| 置顶 | `gtk_window_set_keep_above`（GDK 发 EWMH）。WSLg Weston 可能忽略 `_NET_WM_STATE_ABOVE` |
| 句柄 AV | 已修：LCL GTK3 `Handle` 是 `TGtk3Widget` |
| 关闭窗口 AV | 已修：`TFormSnapWindow.GetVisible` 在子窗 `BeforeDestruction.Hide` 时读悬空 `FForm`。`Detach` + `ClearWindows`，销毁中不重建吸附图 |
| 仍有的 LCL 噪音 | `gdk_pixbuf_get_from_surface` 0 尺寸 CRITICAL；ComboBox `GtkCssCustomGadget` 的 `set_has_window` |

未做：非 WSLg 的实体 Linux 桌面；原生 Wayland 客户端。

**下一步**：Step 7（ttcore 抽库 + FFI 对接，替换 `TStubBackend`）。元数据加载器随 TagLib/ttcore 一起做。

---

## 待定决策

- `Config`：QSettings 格式迁移到 FPC `TIniFile`？
- 双构建链（CMake + lazbuild）的顶层串联脚本形式？
