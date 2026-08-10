# TTPlayer.xml 配置实现说明

## 1. 文件位置与生命周期

- 配置文件名固定为 `TTPlayer.xml`。
- 主路径：与可执行文件同目录。
  - 例如：`/home/john/Downloads/TTPlayer-main/build/TTPlayer.xml`
- 启动读取流程：
  1. 先读可执行文件同目录 `TTPlayer.xml`。
  2. 若不存在或读取失败，则尝试读取旧路径（`QStandardPaths::AppConfigLocation/TTPlayer.xml`）。
  3. 若旧路径读取成功，会在内存中使用该配置；退出时再写回到可执行文件同目录。
  4. 若都没有，程序仍可正常启动，使用内置默认值。
- 退出写回流程：
  - 在 `Application::saveState()`（由 `aboutToQuit` 触发）保存到可执行文件同目录。
  - 运行过程中不主动落盘（例如切换皮肤时不会立即写文件），统一在退出时保存。

## 2. 当前支持的 XML 结构

- 写出格式采用原版风格：
  - 根节点：`<ttplayer version="5.7.9">`
  - 子节点采用属性式配置（如 `<Player .../>`）。
- 读取兼容两种格式：
  1. 原版属性式（`<Player Volume="..." .../>`）
  2. 旧复刻版文本子节点式（`<Player><Volume>...</Volume></Player>`）

## 3. 已接入生效参数（读取并参与运行）

### Player

- `PlayerWnd` -> 主窗口位置与大小
- `LyricWnd` -> 歌词窗口位置与大小
- `EqualizerWnd` -> 均衡器窗口位置与大小
- `PlayListWnd` -> 播放列表窗口位置与大小
- `LyricVisible` -> 歌词窗口可见性
- `EqualizerVisible` -> 均衡器窗口可见性
- `PlayListVisible` -> 播放列表窗口可见性
- `TopMost` / `AlwaysOnTop` -> 窗口置顶
- `PlayMode` -> 播放模式（repeatMode）
- `Shuffle`（扩展字段）-> 随机播放
- `Volume` -> 音量
- `Mute` -> 静音
- `Balance` -> 声道平衡
- `PlayingFileName` -> 上次播放文件
- `SplitOnLists`（若出现在 Player）-> 列表分割条位置

### Playback

- `RepeatMode`（扩展字段）-> 播放模式（作为 `Player.PlayMode` 的后备）
- `Shuffle`（扩展字段）-> 随机播放（后备）

### Equalizer

- `Current` -> 解析为 `preamp:band0,...,band9`
- `Custom` -> 同上（`Current` 缺失时后备）
- `Enabled`（扩展字段）-> 均衡器开关
- `Preamp`（扩展字段）-> 均衡器前级
- `Band0..Band9`（扩展字段）-> 10 段增益

### Histroy

- `SplitOnLists` -> 列表分割条位置

### Skin

- `Path`（扩展字段）-> 复刻版皮肤选择 ID/路径（优先）
- `PackageName` -> 当 `Path` 缺失时作为回退

## 4. 当前仅占位（会写出，但尚未接入逻辑）

下面字段目前主要用于保持原版结构兼容或未来扩展，当前不会驱动实际功能：

### Player（部分）

- `PlayerWnd2` `LyricWnd2` `MiniMode` `DesklrcWnd`
- `LyricTopMost` `TopMost2` `LyricTopMost2` `LyricVisible2`
- `OpaqueWhenActive` `AlphaPercent` `WindowShadow`
- `AutoSwitchList` `PlayFollowCursor` `PlayLists` `ActiveList`
- `PlayingTime` `PlayingFileSubTrack` `ShowElapsedTime`
- `CheckAssociation` `AutoAssociate` `FirstRun_552` `UserWord` `UserWordMD5`

### General

- 当前写出的 `General` 节点全部为占位（如 `TrayIcon` `Snap_Windows` 等）。

### Device

- 当前写出的 `Device` 节点全部为占位。

### HotKey

- 当前写出的 `HotKey` 节点全部为占位。

### Visual

- 当前写出的 `Visual` 节点全部为占位（可视化实际主要由皮肤/窗口逻辑控制）。

### FullScreen

- 当前写出的 `FullScreen` 节点全部为占位。

### DeskLrc

- 当前写出的 `DeskLrc` 节点全部为占位。

### Lyric

- 当前写出的 `Lyric` 节点为占位（歌词窗口样式主要来源于皮肤 XML）。

### PlayList

- 当前写出的 `PlayList` 颜色与字体字段为占位（列表主题主要来源于皮肤与推断逻辑）。

### Library / Network / Convert / Plugin

- 这些节点当前写出但未接入功能逻辑。

### Equalizer（部分）

- `Profile` `ProfileLast` `Surround` 目前仅占位。

### Histroy（部分）

- 除 `SplitOnLists` 外，其余属性当前占位。

## 5. 复刻版新增扩展字段

以下字段不是原版固定语义，用于复刻版保证状态完整：

- `Player.Shuffle`
- `Playback.RepeatMode`
- `Playback.Shuffle`
- `Equalizer.Enabled`
- `Equalizer.Preamp`
- `Equalizer.Band0..Band9`
- `Skin.Path`

这些字段与原版字段并存，不影响原版属性的兼容读取。
