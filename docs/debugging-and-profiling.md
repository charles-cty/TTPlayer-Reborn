# 调试与性能采样

产品 GUI 是 Lazarus/FPC（`pascal/`）。`ttcore` 是无 Qt 的 C++ FFI 库（Windows 上为 MinGW `ttcore.dll`，Linux 上为 `libttcore.so`）。仓库里的 Qt 程序是对照/遗留实现，不是发布目标。

本文管 **符号、崩溃栈、堆诊断、CPU 采样、Pascal 日志**。分层测试、FPCUnit、冒烟见 [testing.md](testing.md)。

## 编哪种配置

| 配置 | 用途 |
|---|---|
| **Debug** | 日常调试。低优化 + 调试信息。Windows 另把 DWARF 转成 PDB。 |
| **Release** | 发布。优化、无调试信息，不要拿来采样。 |
| **Profile** | 采样 profiler。优化与 Release 同级，保留调试信息与帧指针。Windows 同样出 PDB。 |
| **HeapTrc** | 只用于 Pascal 堆诊断（`-gh`），不是发布配置。产物是 `*_heaptrc`，单元目录与 Debug/Release/Profile 隔离。 |

默认构建是 Debug。函数级采样、对照优化前后，用 **Profile**：

```powershell
pwsh tools/build-ttcore-win.ps1 -Config Profile
pwsh tools/build-pascal.ps1 -Config Profile
```

```bash
bash tools/build-ttcore-linux.sh --config Profile
bash tools/build-pascal-linux.sh --config Profile
```

Windows 产物都在 `pascal\bin\`（`ttplayer.exe` / `skinpreview.exe` / `ttcore.dll` 及同名 `.pdb`，旁放 `SDL2.dll`）。Linux 在 `pascal/bin/`，符号是 ELF DWARF，没有 PDB。

`ttplayer` / `skinpreview` 找皮肤：先 `<exe>/Skin/`，没有再 `<exe>/../../Skin/`（仓库根）。两边都没有时仍用 exe 旁路径（安装布局）。

## 符号从哪来

### Windows：MinGW/FPC DWARF → sidecar PDB

工具链是 MSYS2 MinGW，不是 MSVC。PE 里是 DWARF。Debug / Profile 构建会跑 [rainers/cv2pdb](https://github.com/rainers/cv2pdb) **0.54**，在 exe/dll 旁边写出 `.pdb`。需要本机 Visual Studio 的 `mspdb140.dll`（构建脚本用 `vswhere` 把 VS `Common7\IDE` 加进 `PATH`）。

命令行必须是位置参数，**不要用 `-p`**：0.54 的 `-p` 是 embedded-pdb，不是输出路径。脚本实际调用：

```text
cv2pdb64.exe -C -n <exe> <exe> <exe>.pdb
```

`-C` 只给 C++ 名（`ttcore`）；Pascal 工程不加 `-C`。`-n` 表示写新 PDB。转换是 in-place PE。

C++ 侧 Profile 额外：`-g`、`-fno-omit-frame-pointer`、Windows 上 `-gdwarf-4`（cv2pdb 对 DWARF-5 不如 4 稳）。

### cv2pdb 之后 PE 头

转换后 PE 的 **TimeDateStamp 经常是 1970-01-01**。`editbin /RELEASE` 能补上 **CheckSum**，改不了时间戳。ETW / 部分符号加载器用时间戳把模块和 PDB 对上；对不上时，WinDbg 对着旁边的 PDB 往往仍能解名，WPA 则可能解不出。不要假定「有 `.pdb` 文件 = 所有工具都能用」。

### Linux

FPC/GCC 的 DWARF 留在二进制里。`gdb`、`perf` 直接用，不必转 PDB。

## 崩溃与调用栈（Windows）

WinDbg / `cdb` 加载 `pascal\bin\*.pdb` 后，**Pascal 名可用**，活进程 `k` 正常，`sxe av` 能在 Access Violation 停住。这是当前最可靠的函数级栈路径。

把符号路径指到产物目录（可再加微软公共符号服务器解系统 DLL）：

```powershell
$env:_NT_SYMBOL_PATH = 'C:\My\Repos\TTPlayer-Reborn\pascal\bin;srv*C:\symbols*https://msdl.microsoft.com/download/symbols'
cdb -g -G pascal\bin\ttplayer.exe
```

GUI 工程是 `-WG`（Windows 子系统），没有控制台。不要指望 `WriteLn` 出现在启动它的终端里；stdout 关闭时 `WriteLn` 会 `EInOutError`「File not open」。`skinpreview --probe` 在 `Output` 关闭时会跳过 `WriteLn`。需要看探测 JSON 时用 `--probe-out <file>`。

吸附挂钩：`HookSnapWindow` 在 form 为 nil 时直接返回（窗口还没建好、`--probe` 未进 `Application.Run` 时不要解引用）。

## Pascal 日志（ULog）

单元 `pascal/src/debug/ULog.pas`。任意 Pascal 单元 `uses ULog` 后调用 `LogInfo('topic', '...')` / `LogInfoFmt` / `LogDebug` 等。不依赖 LCL。GUI 默认写文件，不写 stdout。

默认文件是 exe 旁的 `<program>.log`（`ttplayer.exe` → `pascal/bin/ttplayer.log`）。默认级别 **info**。换肤几何走 topic `skin`；吸附/拖拽/缩放的状态变化走 topic `snap`（均为 info）：开始/结束拖拽、轴吸住或拉开、贴上边、重建吸附图、缩放起停。不要用日志记逐像素位移，那是 profiler / DTrace 的事。

行格式：

消息首字母大写、动词开头（`ApplySkinFile`、`Refit start`、`Drag end`、`Resize start`），词之间一个空格。

```text
---------- 2026-09-05 10:22:00 pid=1234 ttplayer.exe ----------
10:22:01.123 INFO  [skin] ApplySkinFile C:\...\Classic.skn
10:22:01.140 INFO  [skin] Refit start player=175,62 413x174 ...
10:22:15.010 INFO  [snap] Drag start player @452,210 413x174 group=3 held=-
10:22:16.200 INFO  [snap] Resize start 413x174
```

| 变量 | 含义 |
|---|---|
| `TTPLAYER_LOG` | 文件路径，或 `off` / `stdout` / `stderr`。未设则 exe 旁 `.log` |
| `TTPLAYER_LOG_LEVEL` | `off` `error` `warn` `info` `debug` `trace`。未设则 `info` |
| `TTPLAYER_LOG_TOPICS` | 逗号分隔的 topic；空或未设 = 全部。现有：`skin`、`snap` |

```powershell
# 默认 info 已含 skin / snap。只要看吸附：
$env:TTPLAYER_LOG_TOPICS = 'snap'
# 然后启动 pascal\bin\ttplayer.exe，看 pascal\bin\ttplayer.log
```

`stdout` / `stderr` 只在控制台程序（`tests`）或已打开的 Output 上有效；`-WG` 的 `ttplayer` 请用文件。写失败不抛、每行 Flush。测试里用 `SetLogDestination` / `SetLogLevel` 指到临时文件，不要依赖进程默认路径。

## 堆诊断（HeapTrc + PageHeap）

Pascal 堆和 C++ / CRT 堆不是同一套。泄漏、UAF、`0xC0000005` / `0xC0000374` 要按分配器分开看。

| 堆 | 工具 | 覆盖 |
|---|---|---|
| FPC 堆（Lazarus GUI、FPCUnit） | **HeapTrc**（`-gh`） | Linux 和 Windows 同一套 `--bm=HeapTrc` |
| `ttcore.dll` / FFmpeg / SDL / MinGW CRT | HeapTrc **看不见** | Windows 另开 **GFlags 完整 PageHeap** |

不要只用 GFlags 查 Pascal 堆，也不要以为 HeapTrc 能看到 `ttcore`。

### HeapTrc

工程开关是 Lazarus `--bm=HeapTrc`（`-gh` + `-gl` + `-dENABLE_HEAPTRC`）。产物是 `pascal/bin/*_heaptrc`（Windows 带 `.exe`），单元目录是 `lib/<proj>_heaptrc/`，与 `lib/<proj>/<Config>/` 隔离，**不要和 Debug/Release/Profile 混编**。

`UHeapTraceConfig` 在 `-dENABLE_HEAPTRC` 时打开 `HaltOnError`，dump 写到环境变量 `HEAPTRACEFILE`，未设则 `<exe>.heaptrc`。GUI（`ttplayer` / `skinpreview`）没有控制台，报告仍进这个文件。

`HEAPTRC_KEEP_RELEASED=1`：已释放块不复用，UAF 更容易变成 Invalid pointer，而不是静默踩到别的对象。

```powershell
pwsh tools/build-ttcore-win.ps1
pwsh tools/build-pascal.ps1 -HeapTrace
# 跑 HeapTrc 版 FPCUnit（test-all 会检查 dump）：
pwsh tools/test-all.ps1 -SkipLayer1 -SkipSmoke -HeapTrace

$env:HEAPTRACEFILE = 'C:\tmp\tests.heaptrc'
$env:HEAPTRC_KEEP_RELEASED = '1'
.\pascal\bin\ttplayer_heaptrc.exe
```

```bash
bash tools/build-pascal-linux.sh --heaptrc tests
SDL_AUDIODRIVER=dummy HEAPTRC_KEEP_RELEASED=1 \
  ./pascal/bin/tests_heaptrc --all --format=plain
# 报告：pascal/bin/tests_heaptrc.heaptrc
```

`tools/test-all.ps1 -HeapTrace` 会跑 `tests_heaptrc.exe`，并扫 dump 里的 Invalid pointer / Marked memory / unfreed blocks。那只是自动化入口，配置和解释以本节为准。

### PageHeap（Windows C++ 堆）

需要管理员，以及 Windows SDK Debuggers 里的 `gflags.exe`。按 **exe 文件名** 写 IFEO，不是路径。用完必须 Disable，否则以后每次运行该文件名都会又慢又吃内存。

```powershell
pwsh tools/pageheap.ps1 -Action Enable tests_heaptrc.exe ttplayer_heaptrc.exe
# …复现 AV / 0xC0000005 / 0xC0000374…
pwsh tools/pageheap.ps1 -Action Status
pwsh tools/pageheap.ps1 -Action Disable tests_heaptrc.exe ttplayer_heaptrc.exe
```

典型用法是 HeapTrc 构建 + PageHeap：Pascal 堆走 `.heaptrc`，`ttcore` 走页堆崩溃/调试器。

## CPU 采样：选哪条路

目标是 **Pascal GUI 的函数名**，不是只看 `ttcore.dll` / `win32u`。实测结论：

| 工具 | 采集 | 函数名 | 备注 |
|---|---|---|---|
| WinDbg / cdb | 活进程栈、崩溃 | 可用 | 不适合长时间 CPU 分布 |
| DTrace `profile-997` + `ustack()` | 可用（须 `-c` 拉起） | 大体可用，偶发错名 | 当前函数级采样的主路径 |
| ETW（xperf/WPR） | 模块级可用 | `xperf -symbols` **不可用**；WPA 是否解出 FPC 名 **未证实** | 只适合看模块/内核热点 |
| Linux `perf` | 可用 | DWARF 栈 | 无 PDB 问题 |

不要用 Release 采样。不要在没 PDB 的拷贝上解 Windows 用户栈。

### DTrace（Windows，函数级）

本机需已安装 Windows 版 DTrace。把符号路径指到 `pascal\bin`。

**用 `-c` 启动目标，不要 `-p` 附加。** 对已经在跑的 `ttplayer` 做 `dtrace -p <pid>` 会 **Permission denied**（完整性级别 / 会话 / pid provider 限制，未根治）。要对你正在拖的窗口采样，只能让 DTrace 把进程拉起来，再在窗口里操作。

GUI 没有控制台，脚本里对应用 `printf` 的输出看不见。把聚合写到 DTrace 自己的 stdout，或 `dtrace ... > %TEMP%\tt-sample.txt`。

约 1 kHz 采样 + 用户栈，跑 10 秒后退出的例子：

```powershell
$env:_NT_SYMBOL_PATH = 'C:\My\Repos\TTPlayer-Reborn\pascal\bin'
$script = @'
profile:::profile-997
/execname == "ttplayer.exe"/
{
    @[ustack(30)] = count();
}
tick-10s
{
    exit(0);
}
'@
Set-Content -Path $env:TEMP\tt-sample.d -Value $script -Encoding ascii
dtrace -c 'C:\My\Repos\TTPlayer-Reborn\pascal\bin\ttplayer.exe' -s $env:TEMP\tt-sample.d > $env:TEMP\tt-sample.txt
```

`skinpreview.exe` 同样可以（把 `execname` 和 `-c` 换成它）。`DTRACE_EXIT=0` 且文件里有 `ustack` 聚合即成功。

**读栈时：** 热点趋势（`NtUserSetWindowPos`、`NtUserSetWindowRgn`、`StretchDIBits`、BGRA `SETSIZE`）可信。单帧名字不能当唯一依据：cv2pdb 的 PDB 给 WinDbg `k` 够用，给 `ustack()` 会串名。曾经出现 `TMETHODLIST::ADD` 挂在 `GetSystemMetrics` 下面占约 13%，那是错名，不是真热点。

### ETW / xperf / WPA

采集（模块级 + 采样栈）可以。在管理员 PowerShell 里：

```powershell
xperf -on PROC_THREAD+LOADER+PROFILE -stackwalk Profile
# …复现卡顿…
xperf -d C:\temp\ttplayer.etl
```

**不要** 对这样的 ETL 跑 `xperf -symbols` 或 `xperf -i … -symbols -a profile -detail` 来解 Pascal 名：

- 本机若走了 IE/WinHTTP 代理，解析会长时间卡住（去拉符号服务器）。
- 清代理之后仍可能跑数分钟、吃掉约 1GB+ 内存，然后 **AV 退出**（`0xC0000005`）。把旁边的 PDB 藏起来，`profile -detail` 照样会挂，所以不完全是 cv2pdb 的锅。
- 解析过程会去微软符号服务器拉无关 PDB（例如 Defender `mpengine.pdb`），HTTP 404 刷屏，和本仓库 PDB 无关。
- `xperf -a fileversion` 一类不走栈符号的动作是快的；慢/崩的是给采样栈上符号。

WPA 里先滤到 `ttplayer.exe` 再 Load Symbols，是剩下的 GUI 路径，**没有实锤**能把 cv2pdb 的 FPC 名解到 ETW 栈上（TimeDateStamp 1970 可能是原因之一）。需要函数名时改用上一节 DTrace，或对 ETL 里的地址用 `cdb` `ln`。

### Linux `perf`

Profile 构建后：

```bash
perf record -g -p $(pgrep -n ttplayer) -- sleep 10
perf report
```

或 `perf record -g -- ./pascal/bin/ttplayer`。栈是 DWARF，没有 Windows 那套 PDB/时间戳问题。

## 读 live 缩放样本时

播放列表/歌词拖边不是固定 60fps 游戏循环。平时是 `Invalidate` → `WM_PAINT`。live 缩放时：

- 逻辑尺寸跟鼠标。
- `SetWindowPos` / 窗口 Region / 九宫格 chrome **合帧约 32ms**（`kLiveResizeCoalesceMs`，对齐 `GetTickCount64` 两个默认量子，避免写成 16ms 实际要等两次量子才到期）。第一下立刻改 HWND。
- 放大先画进 `FFrame` 再撑窗口，避免新边露出窗体底色。
- live Region 从新的九宫格帧 `BuildRegion`，不要把旧 alpha run 均匀拉伸（圆角半径是固定像素）。
- 缩小靠 HWND 裁切，不必每拍缩 Region。

因此样本里 `NtUserSetWindowPos` 不会跟每条 `MouseMove` 1:1。空闲接近 0 时，热点多半在 GDI/文本/DIB，而不是合帧定时器本身。

## 已知限制（未打通 / 只绕开）

这些没有写进代码注释，以本文为准。

**一直没打通**

- ETW 函数级符号：`xperf -symbols` 会挂或 AV；WPA 对 FPC PDB 未证实。
- cv2pdb 之后 `TimeDateStamp` 仍是 1970；`editbin /RELEASE` 只修 CheckSum。
- DTrace `-p` 附加 Permission denied；只能 `-c`。
- DTrace `ustack()` 偶发错名。

**绕开了、未根治**

| 问题 | 做法 |
|---|---|
| `xperf -symbols` 崩/挂 | 不用它；函数级走 DTrace 或 WinDbg |
| DTrace 不能附加 | `-c` 启动目标 |
| GUI 无控制台 | 不要靠 `WriteLn`；探测用 `--probe-out`；DTrace 聚合重定向到文件 |
| cv2pdb 0.54 没有可用的 `-p` 输出 PDB | 位置参数 `<exe> [new-exe] [pdb]`，加 `-n` |

**已经可用、不必再换工具的**

- WinDbg/cdb + `pascal\bin\*.pdb`：Pascal 名、活进程 `k`。
- DTrace `profile:::profile-997` + `ustack(30)` + `_NT_SYMBOL_PATH=pascal\bin`，`-c` 启动，10s 量级采样。
- ETW 采集本身（进程/模块/采样栈）；坏的是事后 `xperf` 符号解析。
