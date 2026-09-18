# Tracy：拖动与 live resize 执行耗时

Tracy 是开发时的可选 DLL。Windows Pascal 的 ttplayer/tests Profile 配置通过 `ENABLE_TRACY` 启用插桩，按 exe 同目录加载 `tttracy.dll`。Release、Debug、HeapTrc 默认编译为空操作，即使目录里残留 DLL 也不会加载它；发布时无需携带此 DLL。分析工具版本与 `third_party/tracy` 子模块保持一致。

## 构建与部署

在配置好 MSVC x64 编译器的 Windows 终端中：

```powershell
git submodule update --init --recursive
pwsh -File tools/build-tracy-win.ps1
pwsh -File tools/build-pascal.ps1 -Project ttplayer -Config Profile
```

MSVC Profile 使用优化、调试符号和静态 CRT，产物不依赖 MSVC Debug DLL。Tracy 的构建树位于 `build/windows/tracy/profile/`；同一次构建也会生成 MCP 所需的 `build/windows/tracy/profile/python/TracyServerBindings*.pyd`（文件名带 Python ABI 标签），并使用当前 `python.exe` 实际导入该模块进行 ABI 检查。`tools/build-pascal.ps1 -Config Profile` 会在缺失时自动构建，并把 `tttracy.dll` 和 PDB 复制到 `build/windows/pascal/profile/`。

缺 DLL 时插桩为空操作；缺少所需导出时禁用插桩并向 Windows 调试输出报告不兼容。zone 上下文现在使用 64 位值和 v2 导出，必须一起重建 Pascal 程序与 DLL，旧版 DLL 不兼容。DLL 查找每进程只尝试一次，更新后重启程序并重新采集。

shim 按线程缓存每个 zone 名称及其源位置，首次遇到名称时分配，重复 begin/end 不再逐次分配源位置或 new/delete 上下文。缓存保留到进程退出，保证 Tracy 异步读取元数据时指针有效；名称应为固定标签，不要拼入尺寸或时间戳。初始化或缓存分配失败时 begin 返回空上下文，不让 C++ 异常跨越 Pascal ABI。Tracy 自身的事件队列等内部设施仍可能分配内存。

回归检查：构建 `tttracy_test` target 后运行 `build/windows/tracy/profile/tools/tracyshim/Profile/tttracy_test.exe`，验证重复 zone 无 shim 分配、嵌套上下文、元数据生命周期和分配失败处理。另分别构建 tests 的 Profile 与 Release 并运行 `build/windows/pascal/profile/tests.exe --suite=TTracyTest --format=plain`，在同目录保留 DLL，验证启用及禁用路径。Profile 下若放有 DLL，测试要求它能加载且 ABI 匹配。

## 固定统计口径

| Tracy 名称 | 类型 | 测量内容 |
|---|---|---|
| `Resize.Lyric.Update` | 不连续 frame + 同名 CPU zone | 歌词窗口一次有效更新的墙钟执行耗时 |
| `Resize.Playlist.Update` | 不连续 frame + 同名 CPU zone | 播放列表窗口一次有效更新的墙钟执行耗时 |
| `Drag.SnapMove` / `Snap.ApplyDrag` | CPU zone | 拖动中的吸附计算及窗口联动 |
| `Drag.Begin` / `Drag.End` | CPU zone | 手势开始和结束时的管理器处理 |
| `Window.SetWindowRgn` | CPU zone | 已插桩的 Region 提交调用耗时 |
| `Window.SetWindowPos` | CPU zone | 已插桩的窗口位置提交调用耗时 |
| `Render.PlayerFrame` | CPU zone | 主播放器离屏渲染耗时 |

每个 `Resize.<窗口>.Update` 父 zone 内另有阶段 zone：

- `Resize.<窗口>.Render`：本次 RenderFrame 离屏渲染。
- `Resize.<窗口>.Region`：本次 BuildRegion，包括形状构建及内部 Window 子 zone；跳过 Region 时没有这一项。
- `Resize.<窗口>.Bounds`：实际调用 SetBounds 的阶段；尺寸未变时没有这一项。
- `Resize.<窗口>.Paint`：Invalidate 到同步 Update 返回，包括期间的同步重绘。

`<窗口>` 为 `Lyric` 或 `Playlist`。在主线程时间线点击一次 Update zone，其信息窗口的 Child zones 可查看这些阶段。顶部同名 frame 条自身不能展开。正常完成的有效更新至少会执行 Render 和 Paint 阶段；若只看见 Update 而没有这两项，先确认打开的是新采集中的具体线程 zone。

每次 `ApplyResizeDecision` 先排除 idle 和既不提交窗口尺寸、也不重建 chrome 的决策。有效更新以一对 FrameStart/FrameEnd 及一个父 zone 包住原更新流程：计算目标尺寸、RenderFrame、BuildRegion、SetBounds、Invalidate、同步 Update。缩小、放大及最终 commit 都使用同一边界，不改变原先的缩放算法和 32 ms 合帧策略。

frame **每次有效更新一个**，不是整次手势一个，也不是两次调度事件之间的间隔。异常退出通过 finally 关闭；同一窗口重入时计入外层更新，避免 frame 重叠。Start/End 使用同一个持久名称指针。

这些更新耗时不是 DWM 实际呈现时间或鼠标到屏幕的端到端延迟。zone 的墙钟执行耗时也包含调用内阻塞和线程被抢占的时间。当前不记录提交间隔曲线；仅凭更新耗时不能排除更新之间的调度停顿。

## 查看单次长更新

1. 重启程序、重新采集，分别连续放大、缩小、松手，再单独拖动。
2. frame set 选择对应的 `Resize.Lyric.Update` 或 `Resize.Playlist.Update`，不要选旧的 `Resize`、`UI` 或 `Drag` 事件间隔轨道。
3. 找到长 frame 并放大其时间范围；在线程时间线上选择同名父 zone，查看 duration 和内部 `Window.SetWindowRgn` 等子 zone。
4. 查看 Frame Statistics 的分布、Max/P99 和样本数。

## 查看拖动与吸附

拖动不再生成 frame，也不再记录 `Drag.Update` 父 zone。在线程时间线查看 `Drag.SnapMove` → `Snap.ApplyDrag` 及实际发生的 `Window.SetWindowPos` 等子 zone。开始/结束处理仍通过 `Drag.Begin`、`Drag.End` zone 观察。原有 FApplyingDrag 防重入保护和业务调用顺序保持不变。

这些 zone 只测量已插桩的业务处理。Windows 原生拖动、其它消息处理和 DWM 呈现不在完整覆盖范围内；若这些 zone 都短但实际拖动仍卡顿，不能据此排除消息/调度问题。

若更新执行耗时短但实际操作仍有停顿，继续检查合帧/调度和输入节奏。若单次更新本身长，再对比其子 zone：只有 `SetWindowRgn` 自身长才能把这次长尾归因于它。其它未插桩时间仍需细分，不能凭热点总量推断。

旧 `Resize` 在 BeginGesture/Sample/Tick/Commit 入口打连续标记，包含未实际更新的调度事件；其“小于 10 ms”的分布与新 frame 不可直接比较。从本口径建立新基线，固定皮肤、窗口、尺寸范围、播放状态和连续缩放动作，再比较优化前后。不要预设新的耗时分布必须“大部分低、少数高”。

已删除 `UI`/`Drag` 连续 frame、`Drag.Update` frame/父 zone、`Resize.Decide`/`Resize.Tick` 调度 zone，以及渲染原语的高频消息标记。当前只保留实际 resize 更新帧及阶段 zone、窗口操作 zone、主播放器渲染 zone 和少量吸附业务 zone。重启程序并重新采集后生效，旧 capture 的内容不会改变。DTrace 可继续交叉验证 CPU 热点。
