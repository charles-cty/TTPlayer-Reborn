# TTPlayer (千千静听) v5.7.9 完整逆向工程分析文档

> 基于 TTPlayer.xml 主配置、所有皮肤 XML 文件、PlayList 二进制格式、AddIn 插件目录及 ttplayer-reborn 源码的综合分析。  
> 编写日期：2026年4月8日  
> 用途：TTPlayer Reborn 后续开发参考

---

## 目录

1. [整体架构概述](#1-整体架构概述)
2. [窗口体系](#2-窗口体系)
3. [主播放器窗口 (PlayerWindow)](#3-主播放器窗口-playerwindow)
4. [均衡器窗口 (EqualizerWindow)](#4-均衡器窗口-equalizerwindow)
5. [播放列表窗口 (PlaylistWindow)](#5-播放列表窗口-playlistwindow)
6. [歌词窗口 (LyricWindow)](#6-歌词窗口-lyricwindow)
7. [桌面歌词 (DeskLrc)](#7-桌面歌词-desklrc)
8. [迷你模式 (MiniMode)](#8-迷你模式-minimode)
9. [右键菜单体系](#9-右键菜单体系)
10. [播放模式](#10-播放模式)
11. [音频引擎与DSP](#11-音频引擎与dsp)
12. [皮肤系统](#12-皮肤系统)
13. [播放列表管理](#13-播放列表管理)
14. [歌词系统](#14-歌词系统)
15. [可视化效果](#15-可视化效果)
16. [窗口行为](#16-窗口行为)
17. [快捷键系统](#17-快捷键系统)
18. [插件体系 (AddIn)](#18-插件体系-addin)
19. [格式转换 (Convert)](#19-格式转换-convert)
20. [网络功能](#20-网络功能)
21. [媒体库 (Library)](#21-媒体库-library)
22. [全屏可视化](#22-全屏可视化)
23. [系统托盘](#23-系统托盘)
24. [配置文件格式](#24-配置文件格式)
25. [尚未实现的功能清单](#25-尚未实现的功能清单)

---

## 1. 整体架构概述

TTPlayer v5.7.9 是一个多窗口音频播放器，窗口组成：

| 窗口 | 说明 | 可独立显示/隐藏 |
|------|------|:---:|
| 主播放器窗口 | 核心控制界面 | ✓ (始终可见或最小化) |
| 均衡器窗口 | 10段 EQ + 前置放大 + 平衡 | ✓ |
| 播放列表窗口 | 多列表管理 | ✓ |
| 歌词窗口 | 同步滚动歌词 | ✓ |
| 桌面歌词窗口 | 独立桌面悬浮歌词 | ✓ |
| 迷你模式 | 精简播放条 | ✓ (与主窗口互斥) |

所有子窗口支持与主窗口吸附联动。

---

## 2. 窗口体系

### 2.1 窗口坐标配置

每个皮肤通过 `PlayerWnd`、`EqualizerWnd`、`PlayListWnd`、`LyricWnd` 指定窗口默认坐标（格式 `x1,y1,x2,y2`）。

| 配置项 | 说明 |
|--------|------|
| `PlayerWnd` | 正常模式主窗口位置 |
| `PlayerWnd2` | 迷你模式主窗口位置 |
| `LyricWnd` / `LyricWnd2` | 歌词窗口位置（正常/迷你） |
| `EqualizerWnd` | 均衡器窗口位置 |
| `PlayListWnd` | 播放列表窗口位置 |
| `DesklrcWnd` | 桌面歌词窗口位置 |

### 2.2 窗口可见性标志

```
LyricVisible="1"    / EqualizerVisible="1"    / PlayListVisible="1"
```

### 2.3 窗口层序

```
TopMost="0"          → 主窗口是否置顶
LyricTopMost="0"     → 歌词窗口是否置顶  
TopMost2="1"         → 迷你模式置顶
LyricTopMost2="0"    → 迷你歌词置顶
```

### 2.4 窗口透明度

```
OpaqueWhenActive="0"   → 激活时不透明
AlphaPercent="0"       → 透明度百分比 (0=不透明)
WindowShadow="0"       → 窗口阴影
```

---

## 3. 主播放器窗口 (PlayerWindow)

### 3.1 按钮列表

根据皮肤 XML 和 SkinParser 解析，主窗口包含以下按钮元素：

| 按钮类型 (XML type) | 功能 | 状态数 | 说明 |
|---|---|---|---|
| `play` | 播放 | 4 (normal/hover/pressed/disabled) | 播放时隐藏，显示 pause |
| `pause` | 暂停 | 4 | 暂停时隐藏，显示 play |
| `stop` | 停止 | 4 | 停止播放 |
| `prev` | 上一曲 | 4 | |
| `next` | 下一曲 | 4 | |
| `mute` | 静音切换 | Toggle (按下/松开) | 可切换状态 |
| `open` | 打开文件 | 4 | 弹出文件选择对话框 |
| `lyric` | 歌词窗口开关 | Toggle | 显示/隐藏歌词窗口 |
| `equalizer` | 均衡器开关 | Toggle | 显示/隐藏均衡器窗口 |
| `playlist` | 播放列表开关 | Toggle | 显示/隐藏播放列表 |
| `minimize` | 最小化 | 4 | 最小化到系统托盘 |
| `exit` | 退出 | 4 | 关闭程序 |

### 3.2 滑块控件

| 滑块类型 (XML type) | 功能 | 属性 |
|---|---|---|
| `progress` | 播放进度 | 水平，范围 0~duration，含 bar_image + thumb_image + fill_image |
| `volume` | 音量 | 水平/垂直，范围 0~100 |

### 3.3 文本/显示区域

| 元素类型 | 功能 | 说明 |
|---|---|---|
| `info` | 歌曲标题显示 | 支持滚动字幕（当文字超出宽度时自动左滚） |
| `led` | LED 数字时间显示 | 使用 `number.bmp` 字符精灵图（含 0-9 : -）|
| `stereo` | 立体声/单声道指示 | 文字显示 "Stereo" / "Mono" |
| `status` | 状态信息 | 显示采样率、EQ 状态等 |
| `visual` | 可视化区域 | 频谱/波形/封面三种模式，点击切换 |

### 3.4 可视化区域行为

点击 `visual` 区域循环切换三种模式：
1. **频谱 (Spectrum)** — 频谱柱状图
2. **波形 (BlurScope)** — 模糊示波器
3. **封面 (Cover)** — 显示专辑封面（支持内嵌封面 + 同目录封面图片自动搜索）

封面搜索顺序：
- 内嵌封面（从音频文件 metadata 提取）
- `{同名}.jpg/jpeg/png`
- `cover.jpg/jpeg/png`
- `folder.jpg/jpeg/png`
- `front.jpg/jpeg/png`
- `album.jpg/jpeg/png`

### 3.5 时间显示

- `ShowElapsedTime="1"` → 显示已播放时间（0=显示剩余时间）
- LED 显示格式：`MM:SS`

---

## 4. 均衡器窗口 (EqualizerWindow)

### 4.1 按钮列表

| 按钮类型 | 功能 | 说明 |
|---|---|---|
| `enabled` | EQ 启用/禁用 | Toggle 按钮 |
| `profile` | 预设方案选择 | 点击弹出预设菜单 |
| `reset` | 重置 | 所有频段归零 |

### 4.2 滑块控件

| 滑块类型 | 功能 | 说明 |
|---|---|---|
| `preamp` | 前置放大 | 垂直，范围 -12dB ~ +12dB |
| `balance` | 声道平衡 | 范围 -100 ~ +100 |
| `eqfactor` | EQ 频段 | 10 个垂直滑块，间距由 `eq_interval` 属性控制 |

### 4.3 EQ 频段

10 段均衡器，频率分布：
```
32Hz / 64Hz / 125Hz / 250Hz / 500Hz / 1kHz / 2kHz / 4kHz / 8kHz / 16kHz
```

### 4.4 内置预设方案

| 预设名称 | 说明 |
|---|---|
| 平坦 | 全部归零 |
| 摇滚 | 低高频增强 |
| 流行 | 中频增强 |
| 古典 | 低频增强，高频衰减 |
| 爵士 | 中频增强 |
| 舞曲 | 全频增强偏低 |
| 重金属 | 低高频增强 |
| 人声 | 中高频增强 |
| 轻音乐 | 高频微增 |
| 低音加强 | 低频段增强 |
| 高音加强 | 高频段增强 |

### 4.5 原版额外功能（配置中可见但 Reborn 未完全实现）

- `Surround="0"` — 环绕声效果开关
- `Custom` / `Current` — 自定义和当前 EQ 配置存储
- `Profile="-2"` / `ProfileLast="-1"` — 预设编号记忆

---

## 5. 播放列表窗口 (PlaylistWindow)

### 5.1 窗口元素

| 元素类型 | 功能 | 说明 |
|---|---|---|
| `playlist` | 列表区域 | 可调大小的歌曲列表 |
| `toolbar` | 工具栏 | 横排图标按钮 |
| `title` | 标题栏 | 窗口标题区域 |
| `close` | 关闭按钮 | 隐藏播放列表窗口 |

### 5.2 工具栏按钮（从左到右）

| 索引 | 功能 | 说明 |
|---|---|---|
| 0 | 添加 | 弹出添加子菜单 |
| 1 | 删除选中 | 删除选中条目 |
| 2 | 播放选中 | 播放当前选中曲目 |
| 3 | 清空列表 | 清除所有条目 |

### 5.3 添加子菜单

```
文件(F)...     → 打开文件对话框，多选
文件夹(D)...   → 选择文件夹，递归扫描音频文件
添加 URL...    → URL 添加（原版功能）
```

### 5.4 列表操作功能

- **双击条目** → 立即播放该曲目
- **拖放支持** → 从文件管理器拖入音频文件
- **右键菜单** → 详见右键菜单章节
- **交替行背景色** → `Color_Bkgnd` / `Color_Bkgnd2` 交替
- **自定义颜色** → 文字/高亮/选中/编号/时长各有独立颜色

### 5.5 播放列表颜色配置

| 配置项 | 说明 | Classic 默认值 |
|---|---|---|
| `Color_Text` | 普通文字颜色 | #0080ff |
| `Color_Hilight` | 当前播放高亮颜色 | #00ff00 |
| `Color_Bkgnd` | 背景色 | #000000 |
| `Color_Number` | 编号颜色 | #008000 |
| `Color_Duration` | 时长颜色 | #c08020 |
| `Color_Select` | 选中项背景色 | #3269c8 |
| `Color_Bkgnd2` | 交替行背景色 | #202020 |

### 5.6 显示格式配置（原版 TTPlayer.xml）

```xml
TitleNumber="1"        → 显示编号
TagTitleFormat="%A - %T"  → 标签标题格式：艺术家 - 标题
DefTitleFormat="%F"       → 默认标题格式：文件名
TagFormat="1"             → 标签格式类型
```

格式占位符：
- `%A` — 艺术家
- `%T` — 标题
- `%F` — 文件名
- `%L` — 专辑
- `%N` — 曲目号

### 5.7 原版额外功能

| 配置项 | 说明 |
|---|---|
| `LibraryMode="0"` | 媒体库模式 |
| `ItemTips="1"` | 列表项提示 |
| `DisableDelFile="1"` | 禁止删除文件 |
| `EnableDragDrop="1"` | 启用拖放 |
| `ReadInfoMode="0"` | 读取信息模式 |
| `IgnoreBadFiles="0"` | 忽略无效文件 |
| `SaveRelativePath="1"` | 保存相对路径 |
| `SaveTags="0"` | 保存标签信息 |
| `ClickRating="0"` | 点击评分 |
| `CreateNewVerPlayList="0"` | 创建新版播放列表 |

---

## 6. 歌词窗口 (LyricWindow)

### 6.1 窗口元素

| 元素类型 | 功能 |
|---|---|
| `lyric` | 歌词显示区域 |
| `title` | 标题栏 |
| `close` | 关闭按钮 |

### 6.2 歌词功能

- **同步滚动** — 当前行高亮，自动滚动居中
- **卡拉OK模式** — `KaraokeMode="1"` 逐字高亮
- **自动加载** — `AutoLoadLyric="1"` 播放时自动搜索歌词
- **自动下载** — `AutoDownLoad="1"` 从网络下载歌词
- **编码切换** — 右键菜单可手动切换歌词编码

### 6.3 编码支持

| 编码 | 说明 |
|---|---|
| AutoDetect | 自动检测 (UTF-8 → 本地) |
| UTF-8 | |
| GBK | 简体中文 |
| BIG5 | 繁体中文 |
| ShiftJIS | 日文 |
| EUC-KR | 韩文 |
| Latin1 | 西欧 |

### 6.4 歌词配置（原版完整）

| 配置项 | 说明 |
|---|---|
| `ScrollMode="0"` | 滚动模式 |
| `ScrollMode2="1"` | 备用滚动模式 |
| `TextAlign="0"` | 文字对齐方式 |
| `RowInterval="3"` | 行间距 |
| `FadeIndex="0"` | 淡出索引 |
| `FadeHilight="0"` | 高亮淡出 |
| `KaraokeMode="1"` | 卡拉OK模式 |
| `Transparent="0"` | 歌词区域透明 |
| `TransSkin="1"` | 皮肤透明 |
| `DragLyric="1"` | 允许拖动歌词调整时间 |
| `MouseWheelAdjust="0"` | 鼠标滚轮调整 |
| `AutoWidth="1"` | 自动宽度 |
| `AutoWidthOnlyVert="1"` | 仅垂直自动 |
| `AutoVisible="0"` | 自动显示 |
| `DisplayMode="0"` | 显示模式 |

### 6.5 歌词搜索路径

```
Folders_0="<Sound Folder>"             → 音频文件所在目录
Folders_1=""                            → 自定义路径1
Folders_2=""                            → 自定义路径2  
Folders_3="<Lyrics Download Folder>"    → 歌词下载目录
```

### 6.6 歌词下载配置

| 配置项 | 说明 |
|---|---|
| `AutoDownLoad="1"` | 自动下载 |
| `DownLoadWhenFullInfo="1"` | 信息完整时才下载 |
| `AutoAssociate="0"` | 自动关联 |
| `AutoSelectDownload="1"` | 自动选择下载结果 |
| `OverWrite="0"` | 覆盖已有歌词 |
| `SameFileTitle="0"` | 使用同文件名 |
| `SaveToSoundFolder="0"` | 保存到音频目录 |
| `DownLoadFolder="\Lyrics\"` | 下载保存目录 |
| `LyricSaveMode="1"` | 歌词保存模式 |

---

## 7. 桌面歌词 (DeskLrc)

原版 TTPlayer 的特色功能之一。独立浮于桌面的歌词显示。

### 7.1 配置

| 配置项 | 说明 |
|---|---|
| `Lines="2"` | 显示行数 |
| `Align="3"` | 对齐方式 |
| `BkgndAlpha="0"` | 背景透明度 |
| `TextAlpha="255"` | 文字不透明度 |
| `Topmost="1"` | 始终置顶 |
| `KaraokeMode="1"` | 卡拉OK模式 |
| `AutoWidth="0"` | 自动宽度 |
| `UnlockWhenClose="1"` | 关闭时解锁 |
| `BkgTransp="0"` | 背景透过 |
| `Smooth="1"` | 平滑渲染 |
| `Border="0"` | 边框 |
| `Shadow="1"` | 阴影 |
| `BkgndShow="0"` | 显示背景 |

### 7.2 字体

```
Font="-34,0,0,0,700,0,0,0,1,0,0,4,0,"
```
高度 34px，粗体 (700 weight)。

### 7.3 颜色方案（多预设）

桌面歌词支持多种颜色预设（渐变色），每个预设包含：

- **背景色** (BColor1-3)：歌词未唱到部分的渐变
- **播放色** (PColor1-3)：当前卡拉OK播放部分的渐变

| 预设 | 名称 | 背景渐变 | 播放渐变 |
|---|---|---|---|
| 默认 | (default) | 蓝→青→蓝 | 粉→红→粉 |
| 预设1 | 千千物语 | 蓝→青→蓝 | 粉→红→粉 |
| 预设2 | 盛夏果实 | 绿→亮绿 | 黄→橙→黄 |
| 预设3 | 桃之夭夭 | 紫→浅紫 | 粉白→玫红→粉白 |

---

## 8. 迷你模式 (MiniMode)

`MiniMode="0"` — 当前是否处于迷你模式

迷你模式使用 `mini_window` 皮肤定义，是一个极简播放条，通常在桌面顶部显示。

皮肤中的 `PlayerWnd2` 存储迷你模式窗口坐标。

---

## 9. 右键菜单体系

### 9.1 主窗口右键菜单

主窗口右键菜单由 Application 的 `trayMenu_` 提供，包含：

```
显示主窗口
──────────
打开文件...
导入调试目录音乐          (Reborn 调试功能)
播放/暂停
停止
上一首
下一首
静音切换
音量 +5
音量 -5
──────────
☑ 歌词窗口                (可勾选)
☑ 均衡器                  (可勾选)
☑ 播放列表                (可勾选)
──────────
退出
```

### 9.2 原版主窗口右键菜单（原版功能，更丰富）

根据原版 TTPlayer 的设计，完整菜单应包括：

```
打开文件(O)...              Ctrl+O
添加文件(A)...
添加文件夹...
添加 URL...
──────────
播放/暂停(P)                Space
停止(S)
上一首(V)                   Z
下一首(N)                   B
──────────
播放模式(M)  →  单次播放
                单曲循环
                全部循环
                随机播放
                顺序播放
──────────
音效 →          均衡器
                环绕声
                播放速度
──────────
歌词(L)  →      显示歌词窗口
                桌面歌词
                搜索歌词...
                歌词编辑器
──────────
皮肤(K)  →      (已安装皮肤列表)
                浏览更多皮肤...
──────────
迷你模式(I)                 Ctrl+M
窗口置顶(T)
──────────
选项设置(R)...              Ctrl+P
──────────
关于千千静听...
──────────
退出(X)                     Alt+F4
```

### 9.3 播放列表窗口右键菜单（列表区域）

```
播放(P)
──────────
添加(A) →   文件(F)...
            文件夹(D)...
──────────
从列表删除(D)
──────────
清空列表(L)
──────────
排序(S) →   按文件名排序
            按标题排序
            随机排序
            反转排序
──────────
播放模式(M) →  单次播放    (radio)
               单曲循环    (radio)  
               全部循环    (radio)
               随机播放    (checkbox)
──────────
文件属性(I)
```

### 9.4 播放列表窗口标题栏右键菜单

```
添加文件(A)...
添加文件夹(F)...
──────────
清空列表(L)
```

### 9.5 歌词窗口右键菜单

```
歌词编码(E) →   自动检测    (radio)
                UTF-8       (radio)
                GBK         (radio)
                BIG5        (radio)
                Shift-JIS   (radio)
                EUC-KR      (radio)
                Latin1      (radio)
```

### 9.6 原版歌词窗口完整右键菜单

```
搜索歌词...
歌词编辑...
──────────
滚动方式  →  自动滚动
             手动滚动
──────────
对齐方式  →  左对齐
             居中
             右对齐
──────────
字体...
颜色...
──────────
歌词编码  →  自动检测
             UTF-8
             GBK / BIG5 / Shift-JIS / EUC-KR
──────────
歌词时间调整  →  提前 0.5 秒
                 延后 0.5 秒
                 恢复默认
──────────
关联到当前歌曲
取消关联
```

---

## 10. 播放模式

### 10.1 模式列表

| 编号 | 模式 | 说明 |
|---|---|---|
| 0 | 单次播放 | 播完当前列表停止 |
| 1 | 单曲循环 | 当前曲目无限循环 |
| 2 | 全部循环 | 列表播完重头开始 |
| 3 | 随机播放 | 随机选择下一曲 |

TTPlayer.xml 中 `PlayMode="3"` 表示默认随机播放模式。

### 10.2 相关配置

| 配置项 | 说明 |
|---|---|
| `AutoSwitchList="0"` | 播放完一个列表后是否自动切换到下一个列表 |
| `PlayFollowCursor="0"` | 播放时跟随光标 |

---

## 11. 音频引擎与DSP

### 11.1 DSP 处理链

处理顺序：
1. **均衡器 (Equalizer)** — 10 段 IIR 参量均衡
2. **声道平衡 (Balance)** — 左右声道增益调整
3. **音量 (Volume)** — 增益 + 静音
4. **淡入淡出 (Fade)** — 可配置

### 11.2 播放配置（原版）

| 配置项 | 说明 |
|---|---|
| `AutoPlay="0"` | 启动时自动播放 |
| `ContinuePlay="0"` | 记忆播放位置 |
| `StopWhenFail="0"` | 失败时停止 |
| `TracksInterval="0"` | 曲目间隔（毫秒） |
| `ThreadPriority="15"` | 播放线程优先级 |
| `FileBuffer="16384"` | 文件缓冲区大小 |
| `SoundFadeMode="15"` | 淡入淡出模式 (位标志) |
| `FadeDuration="300,500,800,800"` | 淡入淡出时长 |
| `TrackFadeDur="5000"` | 曲目间交叉淡入淡出 |
| `AutoGain="1"` | 自动增益（ReplayGain） |
| `AutoScanGain="0"` | 自动扫描增益 |
| `SkipScanGain="0"` | 跳过增益扫描 |

### 11.3 输出设备配置

| 配置项 | 说明 |
|---|---|
| `DeviceType` | 音频设备 GUID |
| `OutputBits="16"` | 输出位深 |
| `BufferDuration="1000"` | 缓冲时长 |
| `HardwareBuffer="1"` | 使用硬件缓冲 |
| `CreatePrimary="0"` | 创建主缓冲区 |
| `ResampleRate="0"` | 重采样率 (0=不重采样) |
| `SsrcMode="1"` | SSRC 重采样模式 |
| `Dither="0"` | 抖动处理 |

### 11.4 支持的音频格式

根据 AddIn 插件和打开文件对话框：

| 格式 | 插件 |
|---|---|
| AAC | ttp_aac.dll |
| AC3/DTS | ttp_ac3dts.dll |
| APE (Monkey's Audio) | ttp_ape.dll |
| ASF/WMA | ttp_asf.dll |
| FLAC | ttp_flac.dll |
| MOD/S3M/XM/IT | ttp_mod.dll |
| MPC (Musepack) | ttp_mpc.dll |
| OGG Vorbis | ttp_ogg.dll |
| RealMedia (RM/RA) | ttp_rm.dll |
| TAK | ttp_tak.dll |
| MP3 | 内置 |
| WAV | 内置 |
| CUE Sheet | 内置 |
| OPUS | (Reborn 支持) |

### 11.5 编码器/转换器插件

| 插件 | 功能 |
|---|---|
| ttp_enc.dll | 编码器（格式转换输出） |
| ttp_clienc.dll | 命令行编码器接口 |

### 11.6 其他插件

| 插件 | 功能 |
|---|---|
| ttp_lrcsh.dll | 歌词搜索 (Lyric Search) |

---

## 12. 皮肤系统

### 12.1 皮肤文件格式

- `.skn` — 二进制打包皮肤文件（包含 Skin.xml + 所有 BMP 资源）
- `.skn.xml` — 皮肤配色配置（覆盖默认颜色/字体）
- `Default.xml` — 系统默认配色

### 12.2 皮肤 XML 结构 (Skin.xml)

```xml
<skin version="2" name="..." author="..." url="..." email="..." transparent_color="#FF00FF">
    <player_window image="main.bmp">
        <play position="16,88,30,100" image="play.bmp"/>
        <pause position="16,88,30,100" image="pause.bmp"/>
        <stop position="32,88,46,100" image="stop.bmp"/>
        <prev position="0,88,14,100" image="prev.bmp"/>
        <next position="48,88,62,100" image="next.bmp"/>
        <mute position="..."/>
        <open position="..."/>
        <lyric position="..."/>
        <equalizer position="..."/>
        <playlist position="..."/>
        <minimize position="..."/>
        <exit position="..."/>
        <progress position="..." thumb_image="..." bar_image="..." fill_image="..."/>
        <volume position="..." thumb_image="..."/>
        <info position="..." color="#..." font="..." font_size="..."/>
        <led position="..." image="number.bmp"/>
        <stereo position="..."/>
        <status position="..."/>
        <visual position="..."/>
    </player_window>
    
    <mini_window image="mini.bmp">
        <!-- 迷你模式按钮 -->
    </mini_window>
    
    <equalizer_window image="eq.bmp" position="..." eq_interval="2">
        <enabled position="..."/>
        <profile position="..."/>
        <reset position="..."/>
        <preamp position="..." vertical="true"/>
        <balance position="..."/>
        <eqfactor position="..." vertical="true"/>
    </equalizer_window>
    
    <playlist_window image="pl.bmp" position="..." resize_rect="..." resize_tile="1">
        <playlist position="..."/>
        <toolbar position="..." image="toolbar.bmp"/>
        <title position="..." image="title.bmp"/>
        <close position="..." image="close.bmp"/>
    </playlist_window>
    
    <lyric_window image="lrc.bmp" position="..." resize_rect="..." resize_tile="1">
        <lyric position="..."/>
        <title position="..."/>
        <close position="..."/>
    </lyric_window>
</skin>
```

### 12.3 按钮精灵图 (Sprite Sheet)

每个按钮图片按水平排列多种状态：
- **1 态** — 只有普通状态
- **2 态** — 普通 / 按下
- **3 态** — 普通 / 悬停 / 按下
- **4 态** — 普通 / 悬停 / 按下 / 禁用

判断逻辑：图片宽度 ÷ 按钮宽度 = 状态数（必须整除）。

### 12.4 透明色

默认透明色 `#FF00FF`（品红），该颜色像素在渲染时变为全透明。

### 12.5 九宫格缩放 (Nine-Slice)

播放列表和歌词窗口支持通过 `resize_rect` + `resize_tile` 实现九宫格拉伸：
- 四角保持不变
- 四边水平/垂直平铺
- 中心区域双向平铺

### 12.6 已收录皮肤

| 皮肤名称 | 文件 | 特点 |
|---|---|---|
| Classic | Classic.skn | 经典千千静听默认皮肤 |
| HiFi | HiFi.skn | 深色调 HiFi 风格 |
| TT-07 | TT-07.skn | 深灰蓝色调 |
| Orange | orange.skn | 橙色主题 |
| WMP10 | WMP10.skn | 仿 WMP10 风格 |
| ArcticAMP | ArcticAMP.skn | 北极蓝灰风格 |
| Winamp Modern | Winamp Modern.skn | 仿 Winamp Modern |
| Relunamp | Relunamp.skn | (仅二进制,无xml) |

### 12.7 每个皮肤的配色数据

各皮肤通过 `.skn.xml` 定义独立的可视化、歌词、播放列表颜色：

| 皮肤 | 频谱颜色 | 歌词文字 | 歌词高亮 | 歌词背景 |
|---|---|---|---|---|
| Classic | 粉→蓝(渐变) | #0080c0 | #00ff00 | #000000 |
| Default | #27435f(统一) | #8bbac6 | #ffffff | #31475b |
| HiFi | 同Classic | #979cae | #ffff00 | #001e1c |
| TT-07 | #626161(统一) | #5a5a5a | #05d3ff | #060606 |
| Orange | 黑→橙 | #800000 | #ffffff | #f58a43 |
| WMP10 | 同Classic | #0080c0 | #00ff00 | #000000 |
| ArcticAMP | 同Classic | #565c70 | #2c2f38 | #959bad |
| Winamp Modern | #ffffff(统一) | #80b0ff | #ffffff | #1c3d7d |

---

## 13. 播放列表管理

### 13.1 多列表支持

```
PlayLists="1"      → 播放列表数量
ActiveList="0"     → 当前活动列表索引
```

原版支持多个播放列表，可切换。

### 13.2 TTBL 播放列表格式

- 文件名：`0000.ttbl`（按编号递增）
- 格式：二进制
- 魔数：`TTBL`（文件头 4 字节）
- 字符串编码：UTF-16LE
- 存储内容：文件路径、标题、艺术家、时长

### 13.3 排序功能

| 排序方式 | 说明 |
|---|---|
| 按文件名排序 | 按文件路径字母序 |
| 按标题排序 | 按显示标题字母序 |
| 随机排序 | Fisher-Yates 洗牌算法 |
| 反转排序 | 反转当前顺序 |

### 13.4 原版额外排序（未实现）

- 按艺术家排序
- 按专辑排序
- 按时长排序
- 按添加时间排序
- 按文件大小排序

### 13.5 播放列表条目信息

```cpp
struct PlaylistEntry {
    QString filePath;     // 文件完整路径
    QString title;        // 标题
    QString artist;       // 艺术家
    QString album;        // 专辑
    int64_t durationMs;   // 时长（毫秒）
    bool valid;           // 文件是否有效
};
```

---

## 14. 歌词系统

### 14.1 LRC 格式

标准 LRC 歌词格式：

```
[ti:标题]
[ar:艺术家]
[al:专辑]
[offset:0]
[00:12.34]歌词文本第一行
[00:15.67]歌词文本第二行
```

### 14.2 歌词搜索策略

1. 同目录下同名 `.lrc` 文件
2. 配置的歌词搜索目录
3. 歌词下载目录

### 14.3 原版歌词功能（完整）

| 功能 | 说明 |
|---|---|
| 自动加载 | 播放曲目时自动搜索歌词 |
| 自动下载 | 从网络下载歌词 |
| 歌词标签存储 | 将歌词嵌入音频文件标签 |
| 歌词时间调整 | 手动拖拽或快捷键调整时间 |
| 歌词编辑器 | 内置歌词编辑功能 |
| 卡拉OK模式 | 逐字高亮 |
| 多行显示 | 可配置显示行数 |
| 去空格 | `TrimSpaces="1"` |
| 压缩保存 | `SaveCompress="0"` |

---

## 15. 可视化效果

### 15.1 可视化类型配置

```xml
<Visual>
    Type="4"              → 可视化类型编号
    FramesPerSec="25"     → 帧率
</Visual>
```

### 15.2 频谱可视化配色

| 配置项 | 说明 | Classic 默认 |
|---|---|---|
| `SpectrumTopColor` | 频谱顶部颜色 | #ff0080 |
| `SpectrumMidColor` | 频谱中部颜色 | #ffff00 |
| `SpectrumBtmColor` | 频谱底部颜色 | #0080ff |
| `SpectrumPeakColor` | 峰值颜色 | #ffffff |
| `SpectrumWide` | 宽频谱模式 | 0 |

### 15.3 BlurScope 配色

| 配置项 | 说明 |
|---|---|
| `BlurScopeColor` | 波形颜色 |
| `BlurSpeed` | 模糊速度 |
| `Blur` | 是否模糊 |
| `TextColor` | 文字颜色 |

### 15.4 已实现的可视化模式

| 模式 | 说明 |
|---|---|
| Spectrum | 频谱柱状图 (20 bands) |
| BlurScope | 模糊示波器 (256 samples, 4层历史) |
| Cover | 专辑封面显示 |

### 15.5 全屏可视化

原版支持全屏可视化模式：

```xml
<FullScreen>
    VisualType="1"
    PosRelationAll="0"
    LrcSizeAll="2"
    PosRelationGoom="1"       → Goom 可视化插件
    LrcSizeGoom="2"
    PosRelationSpectrum="0"
    LrcSizeSpectrum="2"
    PosRelationBlurScope="1"
    LrcSizeBlurScope="2"
</FullScreen>
```

---

## 16. 窗口行为

### 16.1 窗口吸附 (Snap)

```
Snap_Windows="65546"    → 吸附参数
```

吸附机制 (WindowSnapManager)：
- **吸附阈值** — 默认 20px
- **吸附检测** — 子窗口边缘接近主窗口或其他子窗口时自动对齐
- **联动移动** — 主窗口移动时所有吸附的子窗口同步移动
- **脱离** — 手动将子窗口拖离阈值 ×2 距离时解除吸附
- **Wayland 兼容** — 使用位置轮询定时器保证联动

### 16.2 窗口拖拽

所有窗口支持无边框拖拽：
- 优先使用 `windowHandle()->startSystemMove()` (原生拖拽)
- 回退方案：手动计算坐标偏移

### 16.3 窗口缩放

播放列表窗口和歌词窗口支持右下角/右边/下边缘缩放：
- 使用 `resizeEdgesForPosition()` 检测边缘区域 (8px 内)
- 光标自动变为对应方向的缩放图标
- 最小尺寸限制为皮肤基础尺寸

### 16.4 最小化行为

点击最小化按钮：
- 隐藏所有窗口（主窗口 + 子窗口）
- 在系统托盘显示提示
- 双击托盘图标恢复

### 16.5 标题栏滚动

```
ScrollTitle="1"           → 启用标题栏文字滚动
TitleSlideInterval="65541" → 滚动间隔
```

---

## 17. 快捷键系统

### 17.1 快捷键配置结构

```
Global="0"              → 全局快捷键是否启用
KeyMap_Count="54"       → 快捷键映射总数
KeyMap_N="command_id:a(key,mod),g(key,mod)"
```

格式说明：
- `a(key,mod)` — 程序内快捷键 (key=虚拟键码, mod=修饰符)
- `g(key,mod)` — 全局快捷键

### 17.2 已知快捷键映射

| 快捷键 | 功能 | 说明 |
|---|---|---|
| F1 | 关于/帮助 | |
| F2-F4 | 功能键 | |
| F9 | 功能 | |
| Space | 播放/暂停 | |
| Z | 上一曲 | |
| X | 下一曲 | |
| C | 停止 | |
| V | 播放 | |
| Ctrl+O | 打开文件 | |
| Ctrl+C | 关闭 | |
| Ctrl+E | 均衡器 | |
| Ctrl+F | 搜索 | |
| Ctrl+P | 播放列表 | |
| Ctrl+M | 迷你模式 | |
| Ctrl+W | 窗口置顶 | |
| Ctrl+T | 标签编辑器 | |
| Ctrl+V | 视图切换 | |
| Ctrl+B | 均衡器 | |
| Left | 快退 | |
| Right | 快进 | |
| Up | 音量增大 | |
| Down | 音量减小 | |
| Ctrl+S | 停止 | |
| Ctrl+D | 设备 | |
| Ctrl+U | URL | |
| Ctrl+I | 信息 | |
| Ctrl+L | 歌词 | |
| Ctrl+E | EQ | |
| Del | 删除 | Ctrl+Del |
| Ctrl+J | 跳转 | |

---

## 18. 插件体系 (AddIn)

### 18.1 已安装插件

所有插件位于 `AddIn/` 目录：

| 文件 | 功能 | 类型 |
|---|---|---|
| ttp_aac.dll | AAC 解码 | 输入插件 |
| ttp_ac3dts.dll | AC3/DTS 解码 | 输入插件 |
| ttp_ape.dll | APE (Monkey's Audio) 解码 | 输入插件 |
| ttp_asf.dll | ASF/WMA 解码 | 输入插件 |
| ttp_clienc.dll | 命令行编码器 | 输出插件 |
| ttp_enc.dll | 编码器 | 输出插件 |
| ttp_flac.dll | FLAC 解码 | 输入插件 |
| ttp_lrcsh.dll | 歌词搜索 | 功能插件 |
| ttp_mod.dll | MOD 音乐解码 | 输入插件 |
| ttp_mpc.dll | Musepack 解码 | 输入插件 |
| ttp_ogg.dll | OGG Vorbis 解码 | 输入插件 |
| ttp_rm.dll | RealMedia 解码 | 输入插件 |
| ttp_tak.dll | TAK 解码 | 输入插件 |

### 18.2 插件配置

```xml
<Plugin>
    Folder="...\TTPlayerv5.7.9\Plugins\"   → 插件搜索目录
    Modules_Count="0"                       → 已加载模块数
</Plugin>
```

---

## 19. 格式转换 (Convert)

原版 TTPlayer 内置格式转换功能：

```xml
<Convert>
    WriterIndex="0"        → 编码器索引
    OutputBits="0"         → 输出位深 (0=源格式)
    ResampleRate="0"       → 重采样率 (0=保持)
    ReplayGain="0"         → ReplayGain 应用
    Equalizer="0"          → 转换时应用 EQ
    Surround="0"           → 转换时应用环绕声
    Folder=""              → 输出目录
    SaveMode="1"           → 保存模式
    AddNumber="0"          → 添加编号
    AddToPlayList="0"      → 转换后加入播放列表
    ThreadPriority="0"     → 转换线程优先级
</Convert>
```

---

## 20. 网络功能

### 20.1 网络代理

```xml
<Network>
    Proxy_Type="0"          → 0=直连, 1=HTTP, 2=SOCKS
    Proxy_Server=""
    Proxy_Port="0"
    Proxy_UserName=""
    Proxy_Password=""
</Network>
```

### 20.2 CDDB (FreeDB)

```
FreedbAutoQuery="1"      → 自动查询 CD 信息
ShowInfoWhenFail="0"
FreedbServer=""
```

### 20.3 在线音乐

```
AcceptRecomList="0"       → 接受推荐列表
DownloadFolder=""         → 下载目录
CreateFolderByAritst="0"  → 按艺术家建目录
DownloadWhenListen="0"    → 边听边下
DownloadLrc="0"           → 下载歌词
MaxDownTasks="3"          → 最大下载任务数
```

### 20.4 缓存

```
DoCache="1"
CacheSpaceSize="600"     → 缓存空间大小 (MB)
CacheFolder="..."
```

---

## 21. 媒体库 (Library)

```xml
<Library>
    Enabled="0"             → 是否启用
    Valid="0"
    MonitorDir="0"          → 监控目录变化
    Directories_Count="0"   → 监控目录数
    MaxItemCount="92"       → 最大条目数
</Library>
```

媒体库功能包括：
- 自动扫描指定目录
- 目录变化监控
- 分类浏览（艺术家/专辑/流派）

---

## 22. 全屏可视化

原版支持全屏可视化播放模式，配有多种可视化效果：
- **频谱** — 全屏频谱显示
- **BlurScope** — 全屏模糊示波器
- **Goom** — Goom 可视化插件
- 全屏模式下可叠加歌词显示

---

## 23. 系统托盘

### 23.1 托盘基本行为

- `TrayIcon="1"` — 显示托盘图标
- 单击/双击：显示主窗口
- 右键菜单：快速操作菜单
- 最小化时显示 balloon 提示

### 23.2 其他

```
Fade_Windows="0"          → 窗口淡入淡出效果
ShowHotKeyInTips="1"      → 提示中显示快捷键
TipsOnOpen="0"            → 打开时显示提示
MenuTips="1"              → 菜单提示
MenuBarPlayList="0"       → 菜单栏播放列表
```

---

## 24. 配置文件格式

### 24.1 TTPlayer.xml 结构

```xml
<ttplayer version="5.7.9">
    <Player .../>        <!-- 播放器主配置 -->
    <General .../>       <!-- 通用设置 -->
    <Playback .../>      <!-- 播放参数 -->
    <Device .../>        <!-- 音频设备 -->
    <HotKey .../>        <!-- 快捷键 -->
    <Visual .../>        <!-- 可视化 -->
    <FullScreen .../>    <!-- 全屏设置 -->
    <DeskLrc .../>       <!-- 桌面歌词 -->
    <Lyric .../>         <!-- 歌词设置 -->
    <PlayList .../>      <!-- 播放列表设置 -->
    <Library .../>       <!-- 媒体库 -->
    <Network .../>       <!-- 网络设置 -->
    <Convert .../>       <!-- 格式转换 -->
    <Equalizer .../>     <!-- 均衡器 -->
    <Skin .../>          <!-- 皮肤选择 -->
    <Plugin .../>        <!-- 插件 -->
    <Histroy .../>       <!-- 历史记录 -->
</ttplayer>
```

### 24.2 皮肤配色 XML (.skn.xml)

每个皮肤可附带一个同名 `.xml` 文件覆盖默认颜色：

```xml
<ttplayer version="5.7.9">
    <Player .../>         <!-- 窗口默认坐标 -->
    <Visual .../>         <!-- 可视化颜色 -->
    <Lyric .../>          <!-- 歌词颜色/字体 -->
    <PlayList .../>       <!-- 播放列表颜色/字体 -->
</ttplayer>
```

### 24.3 ID3 标签配置

```
MP3ReadTagPriority="67633152"   → 标签读取优先级位图
MP3WriteTagType="5"             → 写入标签类型 (ID3v1+ID3v2)
MP3ID3v2Encoding="0"           → ID3v2 编码 (0=UTF-16)
MP3ID3v2Padding="1"            → ID3v2 填充
```

---

## 25. 尚未实现的功能清单

以下是原版 TTPlayer 具备但 TTPlayer Reborn 尚未完全实现的功能，按优先级排列：

### 25.1 高优先级（核心体验）

| 功能 | 原版行为 | 当前状态 |
|---|---|---|
| 迷你模式 | 精简播放条 + 独立皮肤 | ❌ 未实现 |
| 桌面歌词 | 独立悬浮窗 + 卡拉OK着色 | ❌ 未实现 |
| 多播放列表 | 多标签页列表切换 | ❌ 仅单列表 |
| TTBL 列表保存 | 保存/加载播放列表 | ❌ 仅解析 |
| 完整主窗口右键菜单 | 播放模式/音效/皮肤切换 | ⚠️ 部分实现 |
| 歌词时间调整 | 拖拽/快捷键微调歌词同步 | ❌ 未实现 |
| 歌词自动下载 | 在线搜索下载歌词 | ❌ 未实现 |
| 窗口置顶 | 全局/歌词独立置顶 | ❌ 未实现 |

### 25.2 中优先级（增强功能）

| 功能 | 原版行为 | 当前状态 |
|---|---|---|
| ReplayGain | 自动增益标准化 | ❌ 未实现 |
| 交叉淡入淡出 | 曲目切换淡入淡出 | ⚠️ 框架存在 |
| 环绕声效果 | DSP 环绕声处理 | ❌ 未实现 |
| 格式转换 | 内置音频格式转换 | ❌ 未实现 |
| 标签编辑器 | 编辑 ID3/APE 标签 | ❌ 未实现 |
| 文件属性详情 | 显示比特率/采样率/编码等 | ⚠️ 简陋 |
| 完整排序 | 按艺术家/专辑/时长等排序 | ⚠️ 部分实现 |
| 皮肤切换 | 运行时切换皮肤 | ❌ 未实现 |
| 播放速度调整 | 变速播放 | ❌ 未实现 |
| 全屏可视化 | 全屏可视化+歌词 | ❌ 未实现 |

### 25.3 低优先级（完善功能）

| 功能 | 原版行为 | 当前状态 |
|---|---|---|
| 媒体库 | 目录扫描/分类浏览 | ❌ 未实现 |
| 全局快捷键 | 系统级热键 | ❌ 未实现 |
| CDDB 查询 | 自动获取 CD 信息 | ❌ 未实现 |
| 网络代理 | HTTP/SOCKS 代理 | ❌ 未实现 |
| 启动最小化 | `StartupMinimize` | ❌ 未实现 |
| 窗口淡入淡出 | 打开/关闭窗口的动画 | ❌ 未实现 |
| 发送标题到 MSN | `SendTitleToMSN` | ❌ 过时功能 |
| 定时关机 | `AutoShutDown` + `ShutDownTime` | ❌ 未实现 |
| 文件关联检查 | `CheckAssociation` / `AutoAssociate` | ❌ 未实现 |
| 自定义图标 | `AppIconFile` | ❌ 未实现 |
| 歌词编辑器 | 内置歌词编辑 | ❌ 未实现 |
| CUE Sheet 分轨 | 支持 CUE 中的子曲目 | ⚠️ 需验证 |

---

## 附录 A: 完整窗口元素类型汇总

### 按钮元素 (用于所有窗口)

```
play, pause, stop, prev, next, mute, open
lyric, equalizer, playlist, minimize, exit
enabled, profile, reset, close
```

### 滑块元素

```
progress, volume, preamp, balance, eqfactor
```

### 显示元素

```
info, led, stereo, status, visual
lyric, playlist, toolbar, title
```

---

## 附录 B: 配色快速参考

### Classic 经典皮肤完整配色

```
主窗口信息文字:    自定义 (皮肤内 info 元素 color 属性)
频谱顶部:         #ff0080 (粉)
频谱中部:         #ffff00 (黄)
频谱底部:         #0080ff (蓝)
频谱峰值:         #ffffff (白)
歌词普通文字:     #0080c0 (湖蓝)
歌词高亮文字:     #00ff00 (亮绿)
歌词背景:         #000000 (黑)
列表文字:         #0080ff (蓝)
列表高亮:         #00ff00 (绿)
列表背景:         #000000 (黑)
列表编号:         #008000 (暗绿)
列表时长:         #c08020 (金色)
列表选中:         #3269c8 (蓝)
列表交替背景:     #202020 (深灰)
```

### Default (新版默认) 完整配色

```
频谱:             #27435f (统一深蓝灰)
歌词普通:         #8bbac6 (浅蓝灰)
歌词高亮:         #ffffff (白)
歌词背景:         #31475b (深蓝灰)
列表文字:         #8bbac6
列表高亮:         #ffffff
列表背景:         #4b6782
列表选中:         #88aacb
列表交替背景:     #405b76
```

---

*文档结束 — TTPlayer (千千静听) v5.7.9 完整逆向工程分析*
