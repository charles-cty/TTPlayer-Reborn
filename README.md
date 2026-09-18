# TTPlayer Reborn（千千静听复刻版）

一个基于 Qt6 / C++ 的千千静听（TTPlayer）**个人研究项目**，支持原版皮肤格式，还原经典播放器界面与交互。同时正在进行 Lazarus/FPC 重写，以实现更好的跨平台支持。

> ⚠️ 本项目仍处于早期阶段，存在较多 bug 与未实现功能，仅供交流学习。

---

## 皮肤预览

| | |
|---|---|
| ![Classic](classic.png) | ![Skin1](skin1.png) |
| **Classic** 经典皮肤，本程序默认皮肤 | **Skin1** 千千静听 5.x 某版本默认皮肤 |
| ![Serein](serein.png) | ![Subaru](subaru.png) |
| **Serein Flat** Codex 辅助生成 | **Subaru Offbeat** Codex 辅助生成 |

> Serein Flat 与 Subaru Offbeat 为 Codex 辅助生成的皮肤，可自行优化修改。

---

## 功能

- 🎵 音频播放（FFmpeg 解码 + SDL2 输出）
- 🎨 原版千千静听皮肤格式（`.skn`）解析与渲染，兼容上百套皮肤
- 📋 播放列表，兼容原版 TTBL 格式
- 📝 歌词显示（LRC）
- 🎚 均衡器与 DSP 链
- 🪟 多窗口界面：主播放器、播放列表、歌词、均衡器，支持窗口吸附与联动

---

## 目录结构

```
TTPlayer-Reborn/
├── CMakeLists.txt            # Qt/C++ 构建配置
├── Skin/                     # 内置皮肤（.skn + .skn.xml 侧车布局）
│
├── src/                      # Qt C++ 源代码（当前可运行版本）
│   ├── app/                  # Application 顶层管理、Config
│   ├── audio/                # AudioEngine、Decoder、DspChain、Equalizer、AudioOutput
│   ├── skin/                 # SkinEngine、SkinParser、SkinButton（皮肤引擎）
│   ├── ui/                   # PlayerWindow、PlaylistWindow、LyricWindow、EqualizerWindow
│   │                         #   VisualWidget（频谱动画）、WindowSnapManager（窗口吸附）
│   ├── lyric/                # LrcParser
│   ├── playlist/             # PlaylistManager、TtblParser/Writer、MetadataLoader
│   └── tools/                # 测试辅助工具
│       ├── SkinDumper         # --dump-skin：皮肤解析结果序列化为 JSON
│       └── FrameDumper        # --dump-frames：窗口渲染快照（golden 生成）
│
├── pascal/                   # Lazarus/FPC 重写（进行中，见 docs/lazarus-rewrite.md）
│   ├── src/
│   │   ├── skin/             # USkinTypes、USkinXmlParser、USkinLoader、USkinJsonDump
│   │   ├── render/           # USkinRender（渲染原语，Qt source-over 精确复刻）
│   │   ├── backend/          # UPlayerBackend（IPlayerBackend 接口 + TStubBackend 桩）
│   │   ├── playlist/         # UPlaylistModel
│   │   └── ui/               # Player/Playlist/EQ/Lyric + WindowSnap
│   ├── tests/                # FPCUnit 测试（Layer 2/3/4 + Playlist + WindowSnap）
│   │   ├── UTestLayer2.pas   # 渲染快照测试
│   │   ├── UTestLayer3.pas   # 解析逻辑 expect 测试
│   │   ├── UTestMetamorphic.pas  # Metamorphic 测试
│   │   ├── UTestPlaylistModel.pas
│   │   └── UTestWindowSnap.pas   # 窗口吸附 + MR-4
│   ├── vendor/bgrabitmap/    # BGRABitmap v11.6.6（git submodule）
│   ├── ttdump.lpi/.lpr       # Pascal 侧皮肤 JSON dump 工具
│   └── tests.lpi/.lpr        # FPCUnit 测试可执行文件
│
├── tests/
│   ├── golden/
│   │   ├── skinjson/         # Layer 1 基准：Qt 皮肤解析 JSON（11 套皮肤）
│   │   ├── frames/           # Layer 2 基准：Qt 渲染 PNG（各窗口各状态）
│   │   └── masks/            # 像素比对时排除的文本/动画区域掩码
│   └── artifacts/            # 测试失败时的三联对比图（本地产物，不入库）
│
├── tools/                    # 构建与测试脚本（PowerShell，Windows 侧运行）
│   ├── test-all.ps1          # ★ 统一测试入口（Layer 1-4 全部测试）
│   ├── test-layer1.ps1       # Layer 1 差分测试
│   ├── gen-golden.ps1        # 从 Qt 版生成 golden 基准数据
│   ├── build-pascal.ps1      # lazbuild 构建全部 Lazarus 工程（Windows；LAZARUS_DIR）
│   ├── build-pascal-linux.sh # FPC + Lazarus GTK3 构建（FPC / LAZARUS_DIR）
│   └── test-gtk3-wayland.sh  # Linux FPCUnit + XWayland/X11 --probe
│
└── docs/
    ├── testing.md                   # 测试体系详细文档
    ├── lazarus-rewrite.md           # Lazarus 重写计划与进展
    └── debugging-and-profiling.md   # 符号、WinDbg、ETW、DTrace、perf
```

---

## 皮肤使用

皮肤文件为 `.skn` 格式（ZIP 包，内含 BMP 位图 + XML 配置），可直接使用原版千千静听皮肤：

1. 将 `.skn` 文件（及同名 `.skn.xml` 侧车布局，可选）放入程序运行目录下的 `Skin/` 文件夹。
2. 启动程序后在托盘右键菜单中切换皮肤。

`Skin/` 目录已内置多套皮肤，可直接使用。

---

## 构建

产品 GUI 是 Lazarus/FPC（`pascal/` 的 `ttplayer`）。音频是无 Qt 的 C++ 库 `ttcore`（Windows `ttcore.dll`，Linux `libttcore.so`）。仓库里的 Qt 程序是对照/遗留实现。

脚本**不写死** Lazarus / MSYS2 / FPC 安装路径，一律用环境变量或 `PATH`。已在 Windows（MSYS2 MinGW64 + 官方 Lazarus）和 Linux（发行版包 + 自装 FPC/Lazarus GTK3）编译成功。

构建配置三种（CMake `CMAKE_BUILD_TYPE` / Lazarus `--bm` 同名）：

| 配置 | 含义 |
|---|---|
| **Debug** | 低优化 + 调试信息（Windows 另用 cv2pdb 把 DWARF 转成 PDB） |
| **Release** | 优化、无调试信息 |
| **Profile** | 与 Release 相同的优化，加上调试信息与帧指针，给采样 profiler 用。Windows 同样走 cv2pdb |

另有 Lazarus **HeapTrc**（`-gh`），只用于堆诊断，不是第四种发布配置。HeapTrc / PageHeap、WinDbg、ETW、DTrace 见 [docs/debugging-and-profiling.md](docs/debugging-and-profiling.md)。

### 环境变量

| 变量 | 平台 | 含义 |
|---|---|---|
| `MSYS2_ROOT` | Windows | MSYS2 安装根目录（含 `usr\bin\bash.exe` 与 `mingw64\bin`） |
| `MSYS2_BASH` | Windows | 可选，MSYS2 `bash.exe` 的完整路径 |
| `MINGW64_BIN` | Windows | 可选，MinGW64 `bin` 目录；不设则用 `%MSYS2_ROOT%\mingw64\bin` |
| `LAZARUS_DIR` | 两端 | Lazarus 根目录（含 `lazbuild` / `lazbuild.exe`） |
| `LAZBUILD` | 两端 | 可选，`lazbuild` 可执行文件的完整路径 |
| `FPC` | Linux | `fpc` 可执行文件路径；不设则用 `PATH` 上的 `fpc` |
| `LCL_PLATFORM` | Linux | LCL widgetset，默认 `gtk3` |
| `SDL2_PREFIX` | Windows | 可选，官方 MinGW SDL2 根目录（含 `include/SDL2` 与 `bin/SDL2.dll`）。不设则用 mingw64 的 `pkg-config sdl2` |
| `CV2PDB` | Windows | 可选，`cv2pdb64.exe` 路径；Debug/Profile 未设时脚本会下载 |

Windows 上若已把 MinGW64 `bin` 和 `lazbuild` 加入 `PATH`，对应变量可省略；找不到工具时脚本会提示要设哪一个。

运行时日志（Pascal `ULog`，详见 [debugging-and-profiling.md](docs/debugging-and-profiling.md) 的 Pascal 日志一节）：

| 变量 | 含义 |
|---|---|
| `TTPLAYER_LOG` | 日志文件路径，或 `off` / `stdout` / `stderr`。未设则 exe 旁 `<program>.log` |
| `TTPLAYER_LOG_LEVEL` | `off` `error` `warn` `info` `debug` `trace`。未设则 `info` |
| `TTPLAYER_LOG_TOPICS` | 逗号分隔的 topic（如 `skin,snap`）；空 = 全部 |

### Linux 依赖包

不要用 Ubuntu apt 的 `lazarus` / `fp-compiler`（当前是 3.0，没有 LCL GTK3）。FPC 与 Lazarus（GTK3 widgetset）自行安装，再用上表变量指向它们。其余用发行版包：

```bash
sudo apt install git cmake g++ pkg-config make \
  libavformat-dev libavcodec-dev libavutil-dev libswresample-dev libsdl2-dev \
  libgtk-3-dev libx11-dev libxext-dev
```

| 包 | 用途 |
|---|---|
| `git` `cmake` `g++` `pkg-config` `make` | 检出 submodule、编 `ttcore` |
| `libavformat-dev` `libavcodec-dev` `libavutil-dev` `libswresample-dev` | FFmpeg 音频解码/重采样/标签（`libttcore.so`） |
| `libsdl2-dev` | SDL2 音频输出 |
| `libgtk-3-dev` | LCL GTK3（`ttplayer` / `skinpreview`） |
| `libx11-dev` `libxext-dev` | X11 与 XShape（无边框异形窗；Linux 只支持 X11 / XWayland） |

运行 GUI 需要 `DISPLAY`（Xorg 或 XWayland）。不要自备 kitchen-sink FFmpeg 前缀，走 pkg-config。

Qt 对照版另需 Qt6 Widgets、QuaZip-Qt6；Linux 可选 Qt6 DBus（MPRIS）、X11 全局快捷键。

### Windows 依赖

1. **MSYS2 MinGW64**（编 `ttcore` 与静态 FFmpeg，不是 MSVC）：

```bash
pacman -S --needed git make \
  mingw-w64-x86_64-gcc \
  mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-ninja \
  mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-SDL2 \
  mingw-w64-x86_64-zlib \
  mingw-w64-x86_64-libiconv
```

2. **Lazarus**（官方安装包，内含 FPC；编 `ttplayer`）。不要用 MSYS2 里的 Lazarus。

3. Debug / Profile 转 PDB 需要本机 Visual Studio 的 `mspdb140.dll`（`cv2pdb`）。MSVC **不**用来编译。详见 [docs/debugging-and-profiling.md](docs/debugging-and-profiling.md)。

**运行时自包含**：只要 `ttcore.dll`（FFmpeg + MinGW CRT 已静态打进 DLL）和旁边的 `SDL2.dll`。不依赖 MSYS2、不依赖 MinGW CRT DLL。

### 构建 ttcore + Pascal `ttplayer`

**Linux**

```bash
git submodule update --init --depth 1
export FPC=/path/to/fpc
export LAZARUS_DIR=/path/to/lazarus
bash tools/build-ttcore-linux.sh              # 默认 Debug；可 --config Profile
bash tools/build-pascal-linux.sh              # ttdump + tests + skinpreview + ttplayer
bash tools/build-pascal-linux.sh --config Debug
bash tools/test-gtk3-wayland.sh
```

**Windows（PowerShell）**

FFmpeg 不走 pacman 共享包：从 `third_party/ffmpeg`（shallow submodule，pin n8.1.2）编音频-only 静态库，再打进 `ttcore.dll`。所有产物统一放在 `build/<platform>/<component>/<config>/`；Windows Pascal 运行时位于 `build/windows/pascal/<config>/`。

```powershell
$env:MSYS2_ROOT  = 'X:\path\to\msys64'
$env:LAZARUS_DIR = 'X:\path\to\lazarus'
# 可选：$env:SDL2_PREFIX = 'X:\path\to\SDL2'   # 含 include\SDL2 与 bin\SDL2.dll

git submodule update --init --depth 1
pwsh tools/build-ffmpeg-win.ps1
pwsh tools/build-ttcore-win.ps1                 # 默认 Debug
pwsh tools/build-ttcore-win.ps1 -Config Profile
pwsh tools/build-pascal.ps1                     # ttdump + tests + skinpreview + ttplayer
pwsh tools/build-pascal.ps1 -Config Profile
```

`tools/build-ttcore-win.ps1` 在静态 FFmpeg 前缀缺失时会自动调用 `build-ffmpeg-win.ps1`。

### 构建 Qt 对照版

| 依赖 | 用途 |
|---|---|
| Qt6 Widgets | GUI |
| FFmpeg（avformat/avcodec/avutil/swresample） | 与 ttcore 相同 |
| SDL2 | 音频输出 |
| QuaZip-Qt6 | 皮肤 ZIP |
| Qt6 DBus（可选，Linux） | MPRIS |
| X11（可选，Linux） | 全局快捷键 |

```bash
# Linux：先装上一节的发行版包，再装发行版 Qt6 Widgets / QuaZip-Qt6
cmake --preset qt-linux-debug     # 或 qt-linux-release / qt-linux-profile
cmake --build --preset qt-linux-debug
```

Windows 同样用 MSYS2 MinGW64（`MSYS2_ROOT`），不要写死安装路径；推荐直接运行 `pwsh tools/build-qt-win.ps1 -Config Debug`。

---

## 测试

> 详见 [docs/testing.md](docs/testing.md)

```powershell
# 运行全部测试（Layer 1 差分 + Layer 2/3/4 FPCUnit）
pwsh tools/test-all.ps1

# 仅 Layer 1（Qt vs Pascal 解析差分）
pwsh tools/test-layer1.ps1

# 重新生成 golden 基准（Qt 版需已编译）
pwsh tools/gen-golden.ps1 -SkipBuild
```

**测试状态以实际运行为准**：`tools/test-all.ps1` 任一层失败即以非零退出码结束。各层当前覆盖范围见 [docs/testing.md](docs/testing.md)。

| 层级 | 方法 | 覆盖内容 |
|---|---|---|
| Layer 1 | Differential | 11 套皮肤解析 JSON 与 Qt 版差分为零 |
| Layer 2 | Snapshot | 11 套皮肤 player/EQ/lyric/playlist 帧像素一致（容差 ±1，文本走 mask） |
| Layer 3 | Expect | LOGFONT/position/color/bool + LRC + TTBL |
| Layer 4 | Metamorphic | 滑块数学性质 + 色键变形 + 位置解析独立性 |
| Layer 5 | GUI 冒烟 | 四窗口渲染、换肤、EQ 开关、窗口吸附 |

---

## 已知问题 / 限制

- Qt 版仍有较多 bug，功能不完善。
- Lazarus 重写版（`pascal/`）四个皮肤窗口 + Windows 吸附已可运行；音频仍为 `TStubBackend`（ttcore 抽库未开始）。
- Lazarus Linux 只支持 X11（XWayland / Xorg，`GDK_BACKEND=x11`），不支持 Wayland 客户端。GTK3 皮肤窗：无 CSD、XShape、标题栏拖动、吸附、置顶（对齐 Windows）。
- LCL GTK3 的 `Handle` 是 `TGtk3Widget` 对象，不是 `GtkWidget*`；已在 `UPlatformWindow` 中转换，避免 `gtk_widget_get_window` Access violation。

---

## 说明

本项目为个人学习与怀旧用途的复刻，未包含原版千千静听程序本体，版权归相关方所有。`Skin/` 内皮肤包含自带皮肤和 AI 辅助生成的皮肤，经过上百套皮肤兼容性测试。
