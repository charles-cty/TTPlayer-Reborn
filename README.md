# TTPlayer Reborn（千千静听复刻版）

一个基于 Qt6 / C++ 的千千静听（TTPlayer）复刻项目，支持原版皮肤格式，还原经典播放器界面与交互。

## 功能

- 🎵 音频播放（基于 FFmpeg 解码 + SDL2 输出，支持 libsoxr 重采样）
- 🎨 原版千千静听皮肤（`.skn` / `.xml`）解析与渲染，`skins/` 目录内置多套皮肤
- 📋 播放列表，兼容原版 TTBL 播放列表格式（含逆向实现的加载逻辑）
- 📝 歌词显示（LRC）
- 🎚 均衡器与 DSP 链
- 🪟 多窗口界面：主播放器、播放列表、歌词、均衡器，支持窗口吸附与联动（参照原版行为逆向实现）

## 依赖

| 依赖 | 说明 |
|---|---|
| Qt6 | Widgets / Multimedia / Network（DBus、X11 可选） |
| FFmpeg | libavformat / libavcodec / libavutil / libswresample |
| SDL2 | 音频输出 |
| TagLib | 音频标签读取 |
| libsoxr | 高质量重采样 |
| QuaZip | 皮肤文件解压 |

## 构建

```bash
cmake -B build
cmake --build build
./build/TTPlayerReborn
```

## 目录结构

```
├── CMakeLists.txt          # 构建配置
├── src/                    # 源代码
│   ├── app/                # 应用与配置
│   ├── audio/              # 音频引擎、解码、输出、DSP
│   ├── skin/               # 皮肤引擎与解析
│   ├── ui/                 # 播放器、歌词、播放列表、均衡器窗口
│   ├── lyric/              # LRC 解析
│   └── playlist/           # 播放列表（TTBL 格式）
├── skins/                  # 皮肤文件（.skn / .xml）
├── doc/                    # 逆向分析文档
└── TTPlayer_Original_Analysis.md
```

## 说明

- 本项目为个人学习与怀旧用途的逆向复刻，未包含原版千千静听程序本体。
- `skins/` 内皮肤版权归原作者所有，仅供学习交流。
- 已知问题与未实现功能见 `bug和未实现功能记录.md`。
