# 原版千千静听 (TTPlayer) v5.7.9 逆向工程分析

> **本文档来源**：对原版 TTPlayer v5.7.9 的 TTPlayer.xml / Skin XML / ttpres.dll 字符串 / 皮肤位图进行逐项提取和测量，仅记录确认来自原版的数据，不包括任何推测或复刻版的修改。
>
> **最后更新**：基于 TTPlayerv5.7.9/ 目录下所有静态资源的完整扫描。

---

## 一、主窗口 (PlayerWindow)

### 1.1 皮肤几何（Skin.xml → `<player_window>`）

背景图像：`player_skin.bmp`（268×165 px）

| 元素 | position (x1,y1,x2,y2) | image | 说明 |
|------|------------------------|-------|------|
| play | 8,125,38,155 | play.bmp (120×30, 4态) | 播放按钮，与 pause 坐标重叠，播放时显示 pause |
| pause | 8,125,38,155 | pause.bmp (120×30, 4态) | 暂停按钮，停止/暂停时显示 |
| stop | 43,130,63,150 | stop.bmp (80×20, 4态) | 停止 |
| prev | 70,130,90,150 | prev.bmp (80×20, 4态) | 上一首 |
| next | 95,130,115,150 | next.bmp (80×20, 4态) | 下一首 |
| mute | 122,130,142,150 | mute.bmp (80×20, 4态) | 静音切换 |
| open | 130,3,149,22 | open.bmp (76×19, 4态) | 打开文件 |
| lyric | 158,3,177,22 | lyric.bmp (76×19, 4态) | 歌词窗口切换 |
| equalizer | 180,3,199,22 | equalizer.bmp (76×19, 4态) | 均衡器窗口切换 |
| playlist | 202,3,221,22 | playlist.bmp (76×19, 4态) | 播放列表窗口切换 |
| minimize | 229,6,244,21 | minimize.bmp (60×15, 4态) | 最小化到托盘 |
| exit | 245,6,260,21 | exit.bmp (60×15, 4态) | 退出程序 |
| progress | 18,106,248,117 | thumb: progress_thumb.bmp (92×11) | 进度条（无填充图像） |
| volume | 151,130,217,148 | thumb: volume_thumb.bmp; fill: volume_fill.bmp (63×6) | 音量条，水平 |
| visual | 11,30,147,78 | — | 可视化区域，点击切换模式 |
| icon | 8,86,24,102 | — | 显示曲目信息图标 |
| info | 28,88,258,100 | — | 滚动文字信息，color=#ffff06, bkgnd=#000000, SimSun 12pt |
| led | 204,32,254,45 | number.bmp (120×13) | LED 时间显示，右对齐 |
| stereo | 210,50,254,62 | — | Stereo/Mono 标签，color=#00ffff, bkgnd=#212741, SimSun 12pt, 右对齐 |
| status | 181,65,254,77 | — | 比特率/采样率状态，color=#dcdcdc, bkgnd=#212741, SimSun 12pt, 右对齐 |

**按钮精灵帧布局（4态水平排列）**：normal → hover → pressed → disabled（从左到右，每帧宽度 = 图像宽度 ÷ 4）

### 1.2 主窗口右键菜单（ttpres.dll 字符串 Main Menu 段，行 135–187）

```
Main Menu
├── 播放/暂停
├── 停止
├── 上一首
├── 下一首
├── Play Mode（播放模式）→
│   ├── (&S) 单曲
│   ├── (&I)
│   ├── (&N) 下一首
│   ├── (&C) 循环
│   ├── (&R) 随机
│   ├── (&F)
│   └── (&A)
├── ──────────
├── Lyric（歌词秀）→
│   ├── (&D)...
│   └── (&L)...
├── (&E) 均衡器
├── (&C) 关闭
├── (&U) URL
├── 打开文件(&R)
├── (U)...
├── (&M) 静音
├──  ->
├──  ->
├── (&T) 置顶
├── (&F) 全屏
├── (&P)... 选项
├── Player（播放器信息）
├── ──────────
├── (&P) 播放
├── (&P) 暂停
├── (&S) 停止
├── (&B) 声道平衡
├── (&F) 全帧
├── (&R) 刷新
├── (&N) 新建
├── (&O)... 打开文件
├──  C&D/VCD
├──  &URL
├── (&C)
├── Windows →
│   ├── (&L) 歌词   F2
│   ├── (&E) 均衡器 F3
│   ├── (&P) 播放列表 F4
│   └── (&B) 声道平衡 F11
├── (&I) 文件信息
├── (&M) 迷你模式
├── (&R) 重复
├── (&T) 置顶
├── Visual（可视化）→
│   ├── (&G)
│   ├── (&S)
│   ├── (&O)
│   ├── (&T)
│   ├── (&N)
│   ├── (&F)
│   └── (&P)... 选项
├── ──────────
├── 选项设置...
└── 退出 (&X)
```

> 注：以上为从 ttpres.dll Unicode 字符串流推断的完整菜单结构。中文标签由资源DLL内 MENU 资源决定，字符串流仅保留加速键。

### 1.3 系统托盘

- `TrayIcon=1` — 默认启用系统托盘图标
- 最小化时隐藏主窗口，只留托盘图标
- 双击托盘图标 → 还原主窗口
- 托盘右键菜单与主窗口右键菜单共用同一套菜单结构（精简版）

### 1.4 迷你模式

- `mini_skin.bmp`：144×25 px（有独立皮肤背景图像）
- `MiniMode=0`（默认关闭）
- `TopMost2=1`（迷你模式下自动置顶）
- `PlayerWnd2=794,507,1126,533`（迷你模式窗口位置记忆）
- 切换快捷键：Ctrl+Shift+W

---

## 二、均衡器窗口 (EqualizerWindow)

### 2.1 皮肤几何（Skin.xml → `<equalizer_window>`）

背景图像：`equalizer_skin.bmp`（268×165 px），`eq_interval="2"`（频段间距 2px）

| 元素 | position (x1,y1,x2,y2) | image |
|------|------------------------|-------|
| close | 245,6,260,21 | exit.bmp (60×15, 4态) |
| enabled | 12,33,31,52 | eq_enabled.bmp (76×19, 4态) |
| profile | 34,33,53,52 | eq_profile.bmp (76×19, 4态) |
| reset | 56,33,75,52 | eq_reset.bmp (76×19, 4态) |
| balance（水平） | 111,39,162,48 | thumb: eq_balance.bmp (76×9) |
| surround（水平） | 203,39,254,48 | thumb: eq_balance.bmp |
| preamp（垂直） | 13,74,31,154 | thumb: eq_thumb.bmp (40×18); fill: eq_fill.bmp (9×80) |
| eqfactor（垂直，10条） | 59,74,77,154 | thumb: eq_thumb.bmp; fill: eq_fill.bmp |

> `eqfactor` 是 10 个频段的整体描述，从 x=59 开始，每条间距为 `eq_interval=2`px，宽 18px。
> `profile` 和 `reset` 按钮**含下拉箭头**，按下时整个 76×19px 单元整体移位 1px（按钮与箭头共用精灵格，不分离）。

### 2.2 配置（TTPlayer.xml → Equalizer 节）

| 参数 | 值 | 说明 |
|------|----|------|
| Profile | -2 | 当前使用预设索引（-2=自定义） |
| ProfileLast | -1 | 上次使用的预设 |
| Surround | 0 | 环绕声增益 |
| Custom | `0:0,0,0,0,0,0,0,0,0,0` | 自定义预设（格式: preamp:f1,f2,...,f10） |
| Current | `0:0,0,0,0,0,0,0,0,0,0` | 当前运行中的频段值 |

频段顺序：31Hz, 62Hz, 125Hz, 250Hz, 500Hz, 1kHz, 2kHz, 4kHz, 8kHz, 16kHz  
范围：preamp 和各频段均为 **-12 ~ +12 dB**

### 2.3 原版 EQ 内置预设（11个）

| 预设名 | preamp | 31 | 62 | 125 | 250 | 500 | 1k | 2k | 4k | 8k | 16k |
|--------|--------|----|----|-----|-----|-----|----|----|----|----|-----|
| 平坦 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 摇滚 | 0 | 4 | 3 | -2 | -4 | -2 | 2 | 4 | 7 | 7 | 6 |
| 流行 | 0 | -1 | 3 | 5 | 5 | 3 | -1 | -2 | -2 | -1 | -1 |
| 古典 | 0 | 4 | 4 | 3 | 3 | 0 | 0 | 0 | -3 | -3 | -4 |
| 爵士 | 0 | 0 | 0 | 0 | 3 | 3 | 3 | 0 | -2 | -2 | -2 |
| 舞曲 | 0 | 4 | 7 | 5 | 0 | 2 | 4 | 6 | 6 | 5 | 0 |
| 重金属 | 0 | 4 | 3 | 1 | 4 | 3 | 0 | -2 | 0 | 4 | 4 |
| 人声 | 0 | -2 | -2 | 0 | 2 | 5 | 5 | 3 | 1 | 0 | -1 |
| 轻音乐 | 0 | 3 | 1 | 0 | -1 | -1 | 0 | 1 | 3 | 3 | 4 |
| 低音加强 | 0 | 6 | 5 | 3 | 1 | 0 | 0 | 0 | 0 | 0 | 0 |
| 高音加强 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 3 | 5 | 5 | 6 |

---

## 三、播放列表窗口 (PlaylistWindow)

### 3.1 皮肤几何（Skin.xml → `<playlist_window>`）

背景图像：`playlist_skin.bmp`（268×90 px），九宫格缩放，`resize_rect="14,54,254,76"`，`resize_tile="1"`

| 元素 | position (x1,y1,x2,y2) | image | 说明 |
|------|------------------------|-------|------|
| title | 0,8,55,21 | playlist_title.bmp (55×13) | 窗口标题区，居中 |
| close | 245,6,260,21 | exit.bmp | 关闭按钮 |
| **toolbar** | **8,24,260,44** | **playlist_toolbar.bmp (224×16, 8bpp)** | **工具栏（单一统一元素）** |
| scrollbar | — | buttons: scrollbar_button.bmp (39×26); thumb: scrollbar_thumb.bmp (39×24); bar: scrollbar_bar.bmp (13×6) | 自定义垂直滚动条 |
| playlist | 9,50,259,82 | — | 列表内容区，随窗口拉伸扩展 |

### 3.2 工具栏位图结构（关键逆向发现）

- `playlist_toolbar.bmp`：**224×16 px，8bpp（调色板位图）**
- 每个图标格：**16×16 px**
- 224 ÷ 16 = **14 个图标格**（即 14 个工具栏按钮位置）
- 整个工具栏是**皮肤中的一个 `<toolbar>` 元素**，不拆分为独立 `<button>` 元素
- **按下行为**：点击某个按钮区域时，该按钮所属的复合组（图标格+箭头格）**整体向右下各移 1px**
- **7 组复合按钮**：每组由 2 个连续的 16×16 精灵格组成（主图标 + 下拉箭头），点击图标执行默认动作，点击箭头弹出下拉菜单

**像素级逆向分析确认的 7 组 14 格按钮布局**（通过 PIL 提取每个 16×16 格的实际图案）：

| 格号 | 图案描述 | 组号 | 功能 |
|------|----------|------|------|
| 0 | 蓝色十字 (+) | 0:添加 | 主图标点击：直接添加文件 |
| 1 | 黑色下拉箭头 (▼) | 0:添加 | 下拉菜单：文件/文件夹/URL |
| 2 | 红色横杠 (–) | 1:删除 | 主图标点击：删除选中项 |
| 3 | 黑色下拉箭头 (▼) | 1:删除 | 下拉菜单：列表删除/清空/删除重复/删除无效 |
| 4 | 彩色文件列表图标 | 2:文件信息 | 主图标点击：显示文件属性 |
| 5 | 竖线+下拉箭头 | 2:文件信息 | 下拉菜单：文件属性/定位正在播放 |
| 6 | 蓝A红Z字母 | 3:排序 | 主图标/下拉均弹出排序菜单 |
| 7 | 小图标+下拉箭头 | 3:排序 | 排序菜单：按文件名/标题/路径/随机/反转 |
| 8 | 蓝色望远镜 | 4:搜索 | 主图标点击：打开搜索对话框 |
| 9 | 竖线+下拉箭头 | 4:搜索 | 下拉菜单：搜索/清除搜索 |
| 10 | 白色重叠文档 | 5:选择 | 主图标点击：全选 |
| 11 | 小图标+下拉箭头 | 5:选择 | 下拉菜单：全选/反选/取消选择 |
| 12 | 绿色循环箭头 | 6:杂项 | 主图标/下拉均弹出杂项菜单 |
| 13 | 绿角+下拉箭头 | 6:杂项 | 杂项菜单：上移/下移 |

> **重要纠正**：之前推断的 14 个独立按钮是错误的。实际通过位图像素分析确认为 **7 组复合按钮**，每组 2 格（偶数格=主图标，奇数格=下拉箭头）。格 1、3、5、7、9、11、13 的图案均为小型下拉三角箭头（仅 9-17 个非透明像素），不是独立功能按钮。

### 3.3 播放列表右键菜单（PlayList 段，行 188–283）

**PlayList（列表空白区或标题区右键）：**
```
PlayList
├── (&P) 播放
├── (&I)... 文件信息
├── freedb 查询
├── 评分 (&1)~(&5), (&E) 清除评分
├── ──────────
├── (&E) 编辑
├── (&P) 播放模式 →
│   ├── (&T) 标题
│   ├── (&C) 循环
│   ├── (&P) 播放
│   └── (&C)... 其他
├── (&C)... 格式转换
├── (&F)... 搜索/定位（独立对话框）
├── (&D) 删除
├── (&O)... 打开位置
├── ──────────
├── (&F)... 添加文件
├── (&R)... 刷新信息
├── (&O)... 排序选项
├── ──────────
├── App Icon (&D)
├── (&C)... 选择应用图标
├── Skin (&O)... 选择皮肤
├── Playlists（播放列表管理）→
│   ├── (&W)
│   ├── (&N) 新建
│   ├── (&A)... 导入
│   ├── (&S)... 保存
│   ├── (&D) 删除
│   └── (&R) 重命名
├── profile →
│   ├── (&P)...
│   ├──  ->
│   └──  ->
├── Library（音乐库）→
│   ├── (&I)... 导入
│   ├── (&S)... 扫描
│   ├── (&A) 添加目录
│   ├── (&D) 删除目录
│   ├── (&R) 刷新
│   └── (&O)... 选项
└── PROFILE → (&P)...
```

**PlayList Item（列表歌曲条目右键）：**
```
PlayList Item
├── DOWNLOADING（下载中）→
│   ├── (&S) 停止
│   ├── (&P) 暂停
│   ├── (&E) 继续
│   └── (&A) 加入列表
├── DOWNLOADED（已下载）→
│   ├── (&P) 播放
│   ├── (&D)... 删除
│   ├── (&E) 编辑
│   ├── (&L) 列表
│   ├── (&R) 重试
│   └── (&A) 操作
└── ──────────
```

### 3.4 播放列表配置（TTPlayer.xml → PlayList 节，完整版）

| 参数 | 值 | 说明 |
|------|----|------|
| Font | `-11,...,Tahoma` | 11px Tahoma |
| Color_Text | `#0080ff` | 普通文字色（蓝） |
| Color_Hilight | `#00ff00` | 播放中高亮色（绿） |
| Color_Bkgnd | `#000000` | 背景色（黑） |
| Color_Number | `#008000` | 序号颜色（暗绿） |
| Color_Duration | `#c08020` | 时长颜色（金黄） |
| Color_Select | `#3269c8` | 选中行颜色（蓝） |
| Color_Bkgnd2 | `#202020` | 交替行颜色（深灰） |
| CreateNewVerPlayList | 0 | 新建列表不使用新版格式 |
| LibraryMode | 0 | 非音乐库模式 |
| ItemTips | 1 | 鼠标悬停提示 |
| DisableDelFile | 1 | 禁止从磁盘删除文件（仅从列表移除） |
| EnableDragDrop | 1 | 启用拖拽 |
| ReadInfoMode | 0 | 快速读标签模式 |
| TitleNumber | 1 | 显示序号 |
| IgnoreBadFiles | 0 | 不忽略损坏文件 |
| SaveRelativePath | 1 | 保存相对路径 |
| SaveTags | 0 | 不随列表保存标签 |
| TagFormat | 1 | 标签格式版本 |
| ClickRating | 0 | 点击不触发评分 |
| TagTitleFormat | `%A - %T` | 已有标签时的显示格式 |
| DefTitleFormat | `%F` | 无标签时显示文件名 |

### 3.5 多播放列表

| 参数 | 值 | 说明 |
|------|----|------|
| PlayLists | 1 | 当前列表数量 |
| ActiveList | 0 | 活动列表序号（0 起） |
| strDefaultList | [默认] | 默认列表名 |
| SplitOnLists | 55 | 列表/文件区分隔线位置 (px) |
| MenuBarPlayList | 0 | 不在菜单栏显示播放列表 |

支持的播放列表文件格式（ttpres.dll 行 436–438）：
- `.ttbl`（千千二进制格式）
- `.ttpl`（千千播放列表）
- `.m3u` / `.m3u8`

---

## 四、歌词窗口 (LyricWindow)

### 4.1 皮肤几何（Skin.xml → `<lyric_window>`）

背景图像：`lyric_skin.bmp`（268×60 px），九宫格缩放，`resize_rect="14,34,256,42"`，`resize_tile="1"`

| 元素 | position (x1,y1,x2,y2) | image |
|------|------------------------|-------|
| title | 0,8,55,21 | lyric_title.bmp (55×13) |
| close | 245,6,260,21 | exit.bmp |
| lyric | 8,28,260,52 | — （歌词显示区，随窗口拉伸） |

### 4.2 歌词配置（TTPlayer.xml → Lyric 节，完整版）

| 参数 | 值 | 说明 |
|------|----|------|
| Font | `-12,...,宋体` | 12px 宋体 |
| TextColor | `#0080c0` | 未播放行颜色 |
| HilightColor | `#00ff00` | 当前播放行高亮颜色 |
| BkgndColor | `#000000` | 背景色 |
| ScrollMode | 0 | 0=逐行显示 |
| ScrollMode2 | 1 | 1=平滑滚动（与 ScrollMode 配合） |
| CharSet | 0 | 自动检测字符集 |
| TextAlign | 0 | 0=居中 1=左 2=右 |
| RowInterval | 3 | 行间距 (px) |
| FadeIndex | 0 | 淡入淡出行索引偏移 |
| FadeHilight | 0 | 淡出高亮 |
| KaraokeMode | 1 | 卡拉OK逐字着色 |
| Transparent | 0 | 普通模式下不透明 |
| TransSkin | 1 | 跟随皮肤透明度 |
| ScrollModeFS | 0 | 全屏滚动模式 |
| TextAlignFS | 1 | 全屏居左对齐 |
| RowIntervalFS | 4 | 全屏行间距 |
| FadeIndexFS | 10 | 全屏淡出偏移 |
| AutoFontFS | 1 | 全屏自动字体大小 |
| FontFS | `60,...,微软雅黑` | 全屏用 60pt 微软雅黑 |
| TextColorFS | `#0080c0` | 全屏文字色 |
| HilightColorFS | `#00ff00` | 全屏高亮色 |
| AutoLoadLyric | 1 | 自动加载同名 LRC |
| AutoSaveLyricTag | 1 | 自动将歌词写入音频标签 |
| DontLoadLyricTag | 0 | 不阻止从标签加载歌词 |
| AutoVisible | 0 | 播放时不自动弹出歌词窗口 |
| AutoWidth | 1 | 自动调整宽度 |
| AutoWidthOnlyVert | 1 | 仅垂直方向自动宽度 |
| DragLyric | 1 | 鼠标拖拽调整歌词时间偏移 |
| MouseWheelAdjust | 0 | 滚轮不调整偏移 |
| SaveCompress | 0 | 不压缩保存 |
| TrimSpaces | 1 | 去掉行首尾空格 |
| LyricSaveMode | 1 | 保存模式 |
| AddInIndex | 0 | 使用默认歌词插件 |
| AutoDownLoad | 1 | 自动下载歌词 |
| DownLoadWhenFullInfo | 1 | 完整信息时才自动下载 |
| AutoAssociate | 0 | 不自动关联歌词文件 |
| AutoSelectDownload | 1 | 自动选择下载结果 |
| OverWrite | 0 | 不覆盖已有歌词 |
| SameFileTitle | 0 | 不匹配同名文件标题 |
| SaveToSoundFolder | 0 | 不保存到音频文件目录 |
| DownLoadFolder | `\Lyrics\` | 歌词下载保存目录 |
| NewLineAfterTag | 1 | 标签后换行 |
| DisplayMode | 0 | 0=逐行滚动 1=整页 |
| Folders_Count | 4 | 歌词搜索路径数量 |
| Folders_0 | `<Sound Folder>` | 音频文件同目录 |
| Folders_3 | `<Lyrics Download Folder>` | 歌词下载目录 |

**歌词下载接口（ttpres.dll 行 386）**：  
`http://ttplayer.qianqian.com/geci/download.php`

---

## 五、桌面歌词 (Desktop Lyric / DeskLrc)

### 5.1 配置（TTPlayer.xml → DeskLrc 节，完整版）

| 参数 | 值 | 说明 |
|------|----|------|
| Profile | 0 | 当前颜色方案索引 |
| Lines | 2 | 显示行数 |
| Align | 3 | 文字对齐 |
| BkgndAlpha | 0 | 背景不透明度（0=完全透明背景） |
| TextAlpha | 255 | 文字不透明度（完全不透明） |
| Topmost | 1 | 始终置顶 |
| KaraokeMode | 1 | 卡拉OK逐字变色 |
| AutoWidth | 0 | 不自动宽度 |
| UnlockWhenClose | 1 | 关闭时解锁位置 |
| BkgTransp | 0 | 不使用系统透明窗口 |
| Smooth | 1 | 平滑滚动 |
| Border | 0 | 无描边 |
| Shadow | 1 | 有文字阴影 |
| BkgndShow | 0 | 不显示背景色块 |
| Font | `-34,...` | 约 34px 字体 |
| BorderColor | `#ffffff` | 描边颜色 |
| ShadowColor | `#141414` | 阴影颜色（近黑） |
| BkgndColor | `#ffffff` | 背景色 |

### 5.2 三种颜色方案（Profile 0–2）

| 方案 | 名称 | 歌词渐变色 (B Color) | 进度色 (P Color) |
|------|------|---------------------|-----------------|
| 0/1 | 千千物语 | #0080ff → #00ffff → #0080ff（蓝渐变） | #ff8080 → #ff0000 → #ff8080 |
| 2 | 盛夏果实 | #25980a → #81f900（绿渐变） | #fde800 → #ff7800 → #fff600 |
| 3 | 桃之夭夭 | (GBK乱码，颜色值未能提取) | — |

窗口位置：`DesklrcWnd=624,807,1323,922`

---

## 六、选项设置窗口 (Options)

### 6.1 总述

- `LastActivePage=12`（从0计数，至少 13 页）
- 对话框使用 `SysTabControl32` 切换页面
- 各页使用标准 Windows 控件（`SysListView32`、`msctls_trackbar32`、`ComboBoxEx32`、`msctls_updown32`、`msctls_hotkey32` 等）
- ttpres.dll 对话框资源中可见控件序列与 TTPlayer.xml 配置节一一对应

### 6.2 选项页对应关系（共 13 页，页号 0–12）

| 页号 | 页名（推断） | 对应 TTPlayer.xml 节 | 主要控件类型 |
|------|------------|---------------------|------------|
| 0 | 常规 (General) | `<General>` | 复选框组、下拉框 |
| 1 | 播放 (Playback) | `<Playback>` | 复选框、滑块、Spinner |
| 2 | 输出设备 (Device) | `<Device>` | SysListView32（设备列表）、Slider |
| 3 | 插件 (Plugin) | `<Plugin>` | SysListView32 |
| 4 | 均衡器 (Equalizer) | `<Equalizer>` | Trackbar×12 |
| 5 | 格式转换 (Convert) | `<Convert>` | 下拉框、Spinner、Browse |
| 6 | 歌词 (Lyric) | `<Lyric>` | 复选框、颜色按钮、字体按钮 |
| 7 | 播放列表 (PlayList) | `<PlayList>` | 复选框组、颜色按钮 |
| 8 | 音乐库 (Library) | `<Library>` | SysListView32、复选框 |
| 9 | 网络 (Network) | `<Network>` | 编辑框、freedb 配置 |
| 10 | 热键 (HotKey) | `<HotKey>` | SysListView32 + msctls_hotkey32×2 |
| 11 | 皮肤 (Skin) | `<Skin>` | SysListView32（皮肤列表） |
| 12 | 文件关联 (Association) | （系统注册表） | SysListView32（格式列表） |

### 6.3 常规 (General) 页参数

| 参数 | 值 | 说明 |
|------|----|------|
| StartupMinimize | 0 | 启动时不最小化 |
| TrayIcon | 1 | 显示系统托盘图标 |
| Fade_Windows | 0 | 窗口显隐不淡入淡出 |
| ShowHotKeyInTips | 1 | 提示中显示快捷键 |
| TipsOnOpen | 0 | 打开文件时不提示 |
| MenuTips | 1 | 菜单提示 |
| MenuBarPlayList | 0 | 不在菜单栏显示列表 |
| ScrollTitle | 1 | 标题栏滚动显示歌曲名 |
| SendTitleToMSN | 0 | 不发送到 MSN 状态 |
| Snap_Windows | 65546 | 窗口吸附配置（低16位=阈值像素，高16位=行为标志） |
| TitleSlideInterval | 65541 | 标题滚动速度配置 |
| CheckUpdateDays | -1 | 不自动检查更新 |
| AutoShutDown | 0 | 不自动关机 |
| ShutDownTime | `00:00:00` | 自动关机时间 |
| ClearListOnCmd | 0 | 命令行不清空列表 |
| DefaultListOnCmd | 1 | 命令行使用默认列表 |
| strDefaultList | [默认] | 默认列表名 |
| AppIconFile | — | 应用图标文件路径 |
| MP3ReadTagPriority | 67633152 | ID3 标签读取优先级位掩码 |
| MP3WriteTagType | 5 | 写入 ID3v1+v2 |
| MP3ID3v2Encoding | 0 | ID3v2 编码（0=UTF-8；选项：UTF-8 / ID3v2默认 / Shift-JIS） |
| MP3ID3v2Padding | 1 | ID3v2 保留填充字节 |

### 6.4 播放 (Playback) 页参数

| 参数 | 值 | 说明 |
|------|----|------|
| AutoPlay | 0 | 启动时不自动播放 |
| ContinuePlay | 0 | 不继续上次播放位置 |
| StopWhenFail | 0 | 读取失败时不停止 |
| TracksInterval | 0 | 曲目切换间隔 (ms) |
| ThreadPriority | 15 | 解码线程优先级 |
| FileBuffer | 16384 | 文件读取缓冲区 (KB) |
| SoundFadeMode | 15 | 淡入淡出使用场景位掩码（0b1111=全部4种场景） |
| FadeDuration | `300,500,800,800` | 淡入/淡出/暂停/继续 各时长 (ms) |
| TrackFadeDur | 5000 | 交叉淡入淡出时长 (ms) = 5 秒 |
| AutoGain | 1 | 启用 ReplayGain 自动增益 |
| AutoScanGain | 0 | 不自动扫描 Gain 值 |
| SkipScanGain | 0 | 不跳过扫描 |

### 6.5 输出设备 (Device) 页参数

| 参数 | 值 | 说明 |
|------|----|------|
| DeviceType | `{DEF00000-9C6D-47ED-AAF1-4DDA8F2B5C03}` | 当前设备 GUID（DirectSound） |
| OutputBits | 16 | 输出位深 |
| BufferDuration | 1000 | 缓冲区时长 (ms) |
| HardwareBuffer | 1 | 使用硬件缓冲区 |
| CreatePrimary | 0 | 不创建主缓冲区 |
| ResampleRate | 0 | 不重采样（0=输出原始率） |
| SsrcMode | 1 | 使用 SSRC 重采样器 |
| Dither | 0 | 不使用抖动 |

输出设备类型（ttpres.dll 行 353–395）：
- `waveOut (Windows)`
- `DirectSound`
- `(Kernel Streaming)`
- `ASIO (Steinberg Audio Stream I/O API)`

声道格式支持（ttpres.dll 行 390–392）：`5.1`、`6.1`、`7.1`

### 6.6 热键 (HotKey) 页参数

全局热键：`Global=0`（默认关闭）  
热键数量：`KeyMap_Count=54`

格式：`命令ID:a(应用内键码,修饰符),g(全局键码,修饰符)`  
修饰符：0=无，6=Ctrl，10=Ctrl+Alt，12=Ctrl+Shift，14=Ctrl+Shift+Alt

**54 条热键完整列表（含命令ID）：**

| 命令ID | 应用内键 | 全局键 | 说明 |
|--------|---------|--------|------|
| 57664 | F1(112) | 无 | 帮助/关于 |
| 32100 | F2(113) | 无 | 歌词窗口 |
| 32101 | F3(114) | 无 | 均衡器窗口 |
| 32102 | F4(115) | 无 | 播放列表窗口 |
| 32104 | F11(122) | 无 | 声道平衡 |
| 32000 | F5(116) | Ctrl+F5 | 最小化 |
| 32002 | F6(117) | Ctrl+F6 | 上一首 |
| 32003 | F7(118) | Ctrl+F7 | 下一首 |
| 32004 | F8(119) | Ctrl+F8 | 播放/暂停 |
| 32005 | Ctrl+←(37+Ctrl) | Ctrl+Alt+← | 快退 |
| 32006 | Ctrl+→(39+Ctrl) | Ctrl+Alt+→ | 快进 |
| 32010 | Ctrl+↑(38+Ctrl) | Ctrl+Alt+↑ | 音量+ |
| 32011 | Ctrl+↓(40+Ctrl) | Ctrl+Alt+↓ | 音量- |
| 32007 | Ctrl+S | Ctrl+Alt+S | 停止 |
| 32008 | Ctrl+D | Ctrl+Alt+D | 打开/关闭状态 |
| 32009 | Ctrl+U | Ctrl+Alt+U | 打开 URL |
| 32103 | Ctrl+I | 无 | 文件信息 |
| 57601 | Ctrl+O | 无 | 打开文件 |
| 57602 | Ctrl+Shift+C | 无 | 格式转换 |
| 32300 | Ctrl+E | 无 | 均衡器开关 |
| 32521 | Ctrl+F | 无 | 搜索/定位 |
| 32522 | Ctrl+P | 无 | 选项设置 |
| 32525 | 未分配 | 未分配 | — |
| 32580 | 未分配 | 未分配 | — |
| 32588 | 未分配 | 未分配 | — |
| 32212 | Ctrl+M | Ctrl+Alt+M | 静音 |
| 32213 | Ctrl+Shift+W | Ctrl+Alt+W | 迷你模式 |
| 32215 | Ctrl+Shift+T | Ctrl+Alt+T | 窗口置顶 |
| 1033 | Ctrl+Shift+V | Ctrl+Alt+V | 可视化切换 |
| 2151 | Ctrl+Shift+B | Ctrl+Alt+B | 声道平衡 |
| 32569 | 未分配 | 未分配 | — |
| 32570 | 未分配 | 未分配 | — |
| 32571 | Ctrl+J | 无 | 跳转到指定时间 |
| 32815 | Ctrl+L | Ctrl+Alt+L | 歌词窗口 |
| 32813 | 未分配 | 未分配 | — |
| 32812 | 未分配 | 未分配 | — |
| 32804 | 未分配 | 未分配 | — |
| 32814 | 未分配 | 未分配 | — |
| 32805 | 未分配 | 未分配 | — |
| 32806 | 未分配 | 未分配 | — |
| 32807 | 未分配 | 未分配 | — |
| 32808 | 未分配 | 未分配 | — |
| 32809 | 未分配 | 未分配 | — |
| 32810 | 未分配 | 未分配 | — |
| 32811 | 未分配 | 未分配 | — |
| 32820 | 未分配 | 未分配 | — |
| 32821 | 未分配 | 未分配 | — |
| 32836 | Ctrl+T | 无 | 歌词时间调整 |
| 32837 | Ctrl+Shift+E | Ctrl+E | EQ 配置 |
| 32840 | F9(120) | 无 | 播放/暂停（备用） |
| 32841 | F10(121) | 无 | 停止（备用） |
| 32842 | Ctrl+Delete | 无 | 从列表删除 |
| 32230 | Ctrl+Shift+F | Ctrl+F | 全屏 |
| 57665 | Ctrl+Shift+X | 无 | 退出 |

### 6.7 格式转换 (Convert) 页参数

| 参数 | 值 | 说明 |
|------|----|------|
| WriterIndex | 0 | 输出编码器索引 |
| OutputBits | 0 | 输出位深（0=同源文件） |
| ResampleRate | 0 | 重采样率（0=不重采样） |
| ReplayGain | 0 | 不应用 ReplayGain |
| Equalizer | 0 | 不应用均衡器 |
| Surround | 0 | 不应用环绕声 |
| Folder | — | 输出目录 |
| SaveMode | 1 | 保存模式 |
| AddNumber | 0 | 不在文件名加序号 |
| AddToPlayList | 0 | 转换后不加入播放列表 |
| ThreadPriority | 0 | 线程优先级 |

### 6.8 网络 (Network) 页参数

| 参数 | 值 | 说明 |
|------|----|------|
| Proxy_Type | 0 | 0=无代理 |
| Proxy_Server | — | 代理服务器 |
| Proxy_Port | 0 | 代理端口 |
| FreedbAutoQuery | 1 | 插入CD自动查询 freedb |
| ShowInfoWhenFail | 0 | 查询失败不提示 |
| FreedbServer | — | 自定义 freedb（空=默认 freedb.org） |
| DoCache | 1 | 启用缓存 |
| CacheSpaceSize | 600 | 缓存上限 600 MB |
| DownloadFolder | — | 下载保存目录 |
| CreateFolderByAritst | 0 | 不按艺术家建子目录（注：原版属性拼写为 Aritst） |
| ReplaceFile | 0 | 不替换已有文件 |
| DownloadWhenListen | 0 | 收听时不自动下载 |
| DownloadLrc | 0 | 不下载歌词 |
| MaxDownTasks | 3 | 最大并行下载任务数 |

### 6.9 音乐库 (Library) 页参数

| 参数 | 值 | 说明 |
|------|----|------|
| Enabled | 0 | 音乐库功能默认关闭 |
| Valid | 0 | 库数据无效（未扫描） |
| MonitorDir | 0 | 不监控目录变化 |
| Directories_Count | 0 | 无监控目录 |
| MaxItemCount | 92 | 最大显示条目数 |

---

## 七、可视化效果

### 7.1 配置（TTPlayer.xml → Visual 节）

| 参数 | 值 | 说明 |
|------|----|------|
| SpectrumTopColor | `#ff0080` | 频谱顶部（品红） |
| SpectrumBtmColor | `#0080ff` | 频谱底部（蓝） |
| SpectrumMidColor | `#ffff00` | 频谱中部（黄） |
| SpectrumPeakColor | `#ffffff` | 峰值线（白） |
| SpectrumWide | 0 | 频谱条宽（0=窄1px） |
| BlurSpeed | 3 | 示波器余晖消退速度 |
| Blur | 1 | 启用余晖模糊 |
| TextColor | `#c1aafd` | 可视化文字颜色（淡紫） |
| Font | `-11,...,Tahoma` | 11px Tahoma |
| BlurScopeColor | `#00ffff` | 示波器线条（青） |
| Type | 2 | 当前类型（2=频谱分析） |
| FramesPerSec | 25 | 渲染帧率 |

### 7.2 可视化类型（ttpres.dll Visual 菜单段 行 180–187）

| 类型 | 加速键 | 推测名称 |
|------|--------|---------|
| — | &G | Goom特效 |
| — | &S | 频谱分析(Spectrum) |
| — | &O | 示波器/其他 |
| — | &T | 文字 |
| — | &N | 无可视化 |
| — | &F | 全屏 |
| — | &P... | 选项... |

### 7.3 全屏可视化配置（TTPlayer.xml → FullScreen 节）

全屏模式下可视化充满屏幕，并叠加显示歌词。配置项包括：
- `VisualType` — 全屏使用的可视化类型
- `PosRelation_*` — 歌词与可视化区域的相对位置（All/Goom/Spectrum/BlurScope 各有一套）
- `LrcSize_*` — 各可视化类型下的歌词字体大小

---

## 八、音频处理链

### 8.1 解码器插件 (AddIn/ 目录，13个)

| 文件 | 格式支持 |
|------|----------|
| ttp_aac.dll | AAC / AAC+ / M4A / MP4 |
| ttp_ac3dts.dll | AC3 / DTS |
| ttp_ape.dll | Monkey's Audio (APE) |
| ttp_asf.dll | Window Media (WMA / WMV / ASF) |
| ttp_flac.dll | FLAC |
| ttp_mod.dll | MOD / S3M / XM / IT |
| ttp_mpc.dll | Musepack (MPC) |
| ttp_ogg.dll | OGG Vorbis |
| ttp_rm.dll | RealMedia (RM / RA) |
| ttp_tak.dll | TAK |
| ttp_enc.dll | 格式转换编码器 |
| ttp_clienc.dll | 命令行编码器 |
| ttp_lrcsh.dll | 歌词秀插件 |

**内置支持格式**（ttpres.dll 文件过滤字符串，行 418–441）：
- MP3 / mp3PRO (`*.mp3;*.mp2;*.mp1;*.mpa;*.mp3pro`)
- WAVE (`*.wav`)
- AIFF (`*.aif;*.aifc;*.aiff`)
- AU/SND (`*.au;*.snd`)
- MIDI (`*.mid;*.midi;*.rmi`)
- CUE (`*.cue`)
- CD 音轨 (`*.cda`)

**Winamp2 插件接口**（ttpres.dll 行 369）：支持 `dsp_*.dll` 格式的 DSP 插件

### 8.2 DSP 处理链（依据配置节顺序推断）

1. **解码** → PCM 浮点
2. **均衡器**（10频段 Biquad IIR，preamp + 10×频段）
3. **前置放大**（preamp: -12 ~ +12 dB）
4. **环绕声**（Surround）
5. **声道平衡**（Balance: 10 = 微右偏，范围 0~100，50=居中）
6. **重采样**（SSRC，`SsrcMode=1`，可选，默认不重采样）
7. **ReplayGain 自动增益**（`AutoGain=1`）
8. **淡入淡出**（SoundFadeMode=15，4种场景均启用，时长 300/500/800/800ms）
9. **交叉淡入**（TrackFadeDur=5000ms，曲目切换时 5 秒交叉渐变）
10. **输出**（DirectSound / waveOut / ASIO / KS，OutputBits=16，BufferDuration=1000ms）

### 8.3 标签读写配置

| 参数 | 值 | 说明 |
|------|----|------|
| MP3ReadTagPriority | 67633152 | 读取优先级位掩码（控制 ID3v2/v1/文件名顺序） |
| MP3WriteTagType | 5 | 写入 ID3v1+ID3v2 |
| MP3ID3v2Encoding | 0 | 0=UTF-8（选项：UTF-8 / ID3v2默认 / Shift-JIS） |
| MP3ID3v2Padding | 1 | ID3v2 预留填充字节 |

支持的标签格式（ttpres.dll 行 371–372）：`ID3v1/v2`、`Vorbis Comment`

---

## 九、皮肤系统

### 9.1 皮肤文件列表

| 皮肤文件 | 风格 |
|----------|------|
| Classic.skn | 经典银灰色（`PackageName=Classic.skn`，默认） |
| HiFi.skn | HiFi 高保真 |
| TT-07.skn | TT-07 |
| orange.skn | 橙色主题 |
| WMP10.skn | Windows Media Player 10 仿制 |
| ArcticAMP.skn | 北极冰蓝 |
| Relunamp.skn | Reluna 风格 |
| Winamp Modern.skn | Winamp 现代风格 |

### 9.2 皮肤包结构

每个 `.skn` 是 ZIP 包，包含：
- `Skin.xml` — 窗口/元素布局（坐标 + 图像绑定）
- `PlayList.xml` — 播放列表字体/颜色（覆盖 TTPlayer.xml 配置）
- `Lyric.xml` — 歌词字体/颜色
- `Visual.xml` — 可视化颜色参数
- 各 `.bmp` 精灵图（水平 N 态排列，N 通常=4）

### 9.3 Classic.skn 全部位图精确尺寸

| 文件 | 尺寸(px) | 用途 |
|------|----------|------|
| player_skin.bmp | 268×165 | 主窗口背景 |
| equalizer_skin.bmp | 268×165 | 均衡器背景 |
| playlist_skin.bmp | 268×90 | 播放列表背景（可拉伸） |
| lyric_skin.bmp | 268×60 | 歌词背景（可拉伸） |
| mini_skin.bmp | 144×25 | 迷你模式背景 |
| play.bmp | 120×30 | 播放按钮（4×30px） |
| pause.bmp | 120×30 | 暂停按钮（4×30px） |
| stop.bmp | 80×20 | 停止按钮（4×20px） |
| prev.bmp | 80×20 | 上一首（4×20px） |
| next.bmp | 80×20 | 下一首（4×20px） |
| mute.bmp | 80×20 | 静音（4×20px） |
| open.bmp | 76×19 | 打开文件（4×19px） |
| lyric.bmp | 76×19 | 歌词窗口开关（4×19px） |
| equalizer.bmp | 76×19 | 均衡器开关（4×19px） |
| playlist.bmp | 76×19 | 播放列表开关（4×19px） |
| minimize.bmp | 60×15 | 最小化（4×15px） |
| exit.bmp | 60×15 | 退出/关闭（4×15px） |
| **playlist_toolbar.bmp** | **224×16** | **工具栏精灵（8bpp，14格×16px）** |
| eq_enabled.bmp | 76×19 | EQ 启用（4×19px） |
| eq_profile.bmp | 76×19 | EQ 预设（4×19px） |
| eq_reset.bmp | 76×19 | EQ 重置（4×19px） |
| eq_balance.bmp | 76×9 | 水平滑块把手 |
| eq_fill.bmp | 9×80 | 垂直滑块填充 |
| eq_thumb.bmp | 40×18 | 垂直滑块把手 |
| progress_thumb.bmp | 92×11 | 进度条把手 |
| volume_fill.bmp | 63×6 | 音量条填充 |
| volume_thumb.bmp | 40×18 | 音量条把手 |
| scrollbar_button.bmp | 39×26 | 滚动条上下按钮（2格×13px高） |
| scrollbar_thumb.bmp | 39×24 | 滚动条拖块 |
| scrollbar_bar.bmp | 13×6 | 滚动条轨道 |
| number.bmp | 120×13 | LED 数字精灵（0-9+符号，共10+列） |
| lyric_title.bmp | 55×13 | 歌词窗口标题图像 |
| playlist_title.bmp | 55×13 | 播放列表标题图像 |

### 9.4 九宫格缩放（可拉伸窗口）

适用于歌词窗口（lyric_skin.bmp）和播放列表窗口（playlist_skin.bmp）：
- `resize_rect="x1,y1,x2,y2"` — 中央可拉伸区域（外侧固定）
- `resize_tile="1"` — 平铺而非拉伸填充中央区域
- 四角固定、四边沿轴铺贴、中央平铺填充

---

## 十、窗口行为与布局

### 10.1 窗口吸附 (Snap)

- `Snap_Windows=65546` — 吸附配置（低16位=阈值像素数，高16位=行为标志位）
- 子窗口拖到主窗口附近时自动磁性吸附贴合
- 拖动主窗口时，所有已吸附子窗口跟随移动（群组移动）
- 拖动子窗口时带动主窗口，主窗口再带动其他吸附子窗口

### 10.2 窗口透明度

- `AlphaPercent=0` — 透明度（0=不透明，100=完全透明）
- `OpaqueWhenActive=0` — 鼠标悬停时不强制不透明
- `WindowShadow=0` — 不使用窗口阴影

### 10.3 窗口置顶

- `TopMost=0` / `LyricTopMost=0` — 主窗口和歌词窗口非置顶（普通模式）
- `TopMost2=1` — 迷你模式下主窗口置顶
- `LyricTopMost2=0` — 迷你模式下歌词不置顶
- 主窗口与歌词窗口**独立**配置置顶

### 10.4 窗口位置格式

格式：`"x1,y1,x2,y2"` — 对应 Windows `RECT`（左上角 + 右下角）

| 窗口 | 配置项 | 当前记录值 |
|------|--------|-----------|
| 主窗口（普通） | PlayerWnd | 1652,121,1920,286 |
| 主窗口（迷你） | PlayerWnd2 | 794,507,1126,533 |
| 歌词窗口 | LyricWnd | 1115,131,1383,296 |
| 均衡器 | EqualizerWnd | 1652,286,1920,451 |
| 播放列表 | PlayListWnd | 1652,451,1920,615 |
| 桌面歌词 | DesklrcWnd | 624,807,1323,922 |

---

## 十一、播放模式

`PlayMode=3`（默认列表循环）

| 值 | 中文名 | 行为 |
|----|--------|------|
| 0 | 单曲播放 | 播完当前曲目停止 |
| 1 | 单曲循环 | 无限重复当前曲目 |
| 2 | 顺序播放 | 播到列表末尾停止 |
| 3 | 列表循环 | 循环播放整个列表 |
| 4 | 随机播放 | 随机选下一首 |

其他相关配置：
- `AutoSwitchList=0` — 不自动切换到下一列表
- `PlayFollowCursor=0` — 浏览列表时不跳转播放

---

## 十二、文件信息对话框

触发：`Ctrl+I`，显示当前曲目详细信息。

ttpres.dll 字符串确认的信息字段（行 88–93, 463–485）：

| 字段 | 模板变量 |
|------|---------|
| 艺术家 | `%(Artist)` |
| 标题 | `%(Title)` |
| 专辑 | `%(Album)` |
| 格式信息 | `%(Format)` |
| 时长 | `%(Duration)` |
| 音轨号 | `%(Tracknumber)` |
| 流派 | `%(Genre)` |
| 日期 | `%(Date)` |
| 文件名 | `%(Filename)` |

对话框包含 5 组信息视图（ttpres.dll 行 463–485 的 5 个多行模板），通过 `SysTabControl32` 切换。

---

## 十三、搜索对话框（独立窗口）

**原版搜索是独立浮动对话框窗口，不是任何窗口内嵌的搜索框。**

- 触发：工具栏第 10 号按钮 或 `Ctrl+F`
- ttpres.dll 行 204 `(&F)...` 表示弹出独立对话框（`...` 通常指模态对话框）
- 对话框内含搜索文本框和"查找"按钮
- 搜索结果以**高亮/定位**方式在播放列表中标记匹配项，不过滤隐藏其他条目
- 匹配范围：标题、艺术家、专辑、文件名

---

## 十四、Lyric Edit 对话框

ttpres.dll 行 256 `Lyric Edit`，行 257–261 确认操作项：
- `(&I)` — 信息/插入
- `(&R)` — 重置
- `(&D)` — 删除行
- `(&T)` — 时间轴调整
- `(&C)` — 确认/取消

功能：手动编辑 LRC 歌词的时间标签（插入行、删除行、调整时间轴偏移）

---

## 十五、网络与在线功能

| 功能 | 说明 |
|------|------|
| 歌词下载 | 接口：`http://ttplayer.qianqian.com/geci/download.php`，`MaxDownTasks=3` |
| FreeDB 查询 | CD 信息自动查询，默认服务器 freedb.org |
| 在线主页 | `http://www.qianqian.com`（行 486），版本号 5.7（行 487） |
| 代理支持 | HTTP/SOCKS 代理（Proxy_Type/Server/Port/UserName/Password） |
| 下载缓存 | `CacheSpaceSize=600` MB（行 98 提示：600MB–2GB 范围） |

---

## 十六、格式转换功能

- 触发：`Ctrl+Shift+C`（命令ID 57602）
- 对话框使用 `SysTabControl32` 多页
- 对话框含 `msctls_progress32` 进度条（批量转换进度显示）
- 转换配置：输出格式/位深/采样率/ReplayGain/均衡/环绕/输出目录/命名规则

---

## 十七、Histroy（历史记录）节

| 参数 | 值 | 说明 |
|------|----|------|
| LastActivePage | 12 | 上次选项窗口页号（0起，共13页） |
| SplitOnLists | 55 | 播放列表区域分隔线位置 (px) |
| EQCProfile | `.tteq_cfg` | 上次 EQ 配置文件路径 |
| LRCProfile | `.ttlr_cfg` | 上次歌词配置文件路径 |
| PLCProfile | `.ttpl_cfg` | 上次播放列表配置文件路径 |
| AdvanceFileInfo | 0 | 不使用高级文件信息 |
| CheckSubFolder | 1 | 扫描时包含子目录 |

---

## 附录 A：关键文件说明

| 文件 | 类型 | 说明 |
|------|------|------|
| TTPlayer.xml | 文本（GBK/UTF-8）| 全局持久化配置，所有参数为 XML 属性 |
| TTPlayer.rll | 纯文本 UTF-8 | 单行 LRC 路径字符串（**不是**资源库） |
| ttpres.dll | PE32 DLL (297KB) | 界面资源（MENU/STRINGTABLE/DIALOG），Unicode 字符串 |
| ttpcomm.dll | PE32 DLL (202KB) | 通信/工具函数库 |
| AddIn/*.dll | PE32 DLL | 音频解码插件（13个） |
| Skin/*.skn | ZIP 包 | 皮肤包，含 XML + BMP |
| PlayList/0000.ttbl | 二进制 | 千千播放列表（.ttbl 格式） |

## 附录 B：Classic.skn Lyric.xml / PlayList.xml 原始颜色

**Lyric.xml（Classic 皮肤歌词颜色，覆盖 TTPlayer.xml 中的 Lyric 节）：**
- Font：`-12,...,宋体`
- TextColor：`#0080c0`
- HilightColor：`#00ff00`
- BkgndColor：`#000000`

**PlayList.xml（Classic 皮肤播放列表颜色，覆盖 TTPlayer.xml 中的 PlayList 节）：**
- Font：`-12,...,宋体`（注：PlayList.xml 用 12px，TTPlayer.xml 用 11px Tahoma）
- Color_Text：`#0080ff`
- Color_Hilight：`#00ff00`
- Color_Bkgnd：`#000000`
- Color_Number：`#008000`
- Color_Duration：`#c08020`
- Color_Select：`#3269c8`
- Color_Bkgnd2：`#202020`

**Visual.xml（Classic 皮肤可视化颜色）：**
- SpectrumTopColor：`#ff0080`
- SpectrumBtmColor：`#0080ff`
- SpectrumMidColor：`#ffff00`
- SpectrumPeakColor：`#ffffff`
- SpectrumWide：0
- BlurSpeed：3
- Blur：1
- BlurScopeColor：`#00ffff`

---

*仅记录原版 TTPlayerv5.7.9/ 静态文件中可直接验证的数据。*
