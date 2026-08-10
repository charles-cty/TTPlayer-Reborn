# TTPlayer Reborn（千千静听复刻版）

一个基于 Qt6 / C++ 的千千静听（TTPlayer）**个人研究项目**，支持原版皮肤格式，还原经典播放器界面与交互。

> ⚠️ 本项目还有很多 bug，功能不太完善，请谨慎使用。

## 皮肤预览

| | |
|---|---|
| ![Classic](classic.png) | ![Skin1](skin1.png) |
| **Classic** 经典皮肤，本程序的默认皮肤 | **Skin1** 千千静听 5.x 某个版本的默认皮肤 |
| ![Serein](serein.png) | ![Subaru](subaru.png) |
| **Serein Flat** Codex 生成的皮肤 | **Subaru Offbeat** Codex 生成的皮肤 |

> Serein Flat 与 Subaru Offbeat 为 Codex 辅助生成的皮肤，可自行优化修改。

## 皮肤使用

- 皮肤文件为 `.skn`（配合同名 `.skn.xml` 描述文件）格式，可直接使用原版千千静听皮肤。
- 将皮肤文件放入**程序运行目录下的 `Skin` 文件夹**（注意：首字母大写，没有末尾的 `s`），启动程序后即可在皮肤菜单中切换。
- 仓库 `skins/` 目录内置了多套皮肤，可自行复制到上述 `Skin` 文件夹中使用。

## 功能

- 🎵 音频播放（基于 FFmpeg 解码 + SDL2 输出，支持 libsoxr 重采样）
- 🎨 原版千千静听皮肤解析与渲染
- 📋 播放列表，兼容原版 TTBL 播放列表格式（含逆向实现的加载逻辑）
- 📝 歌词显示（LRC）
- 🎚 均衡器与 DSP 链
- 🪟 多窗口界面：主播放器、播放列表、歌词、均衡器，支持窗口吸附与联动（参照原版行为逆向实现）

## 编译环境

已在以下环境编译成功：

- **Windows**
- **Kubuntu（Linux）**

其他系统未尝试。

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
├── skins/                  # 皮肤文件（.skn / .xml），使用时复制到程序目录 Skin/ 下
```

## 已知问题

项目仍处于早期阶段，存在较多 bug 与未实现功能,仅供交流学习。




## 说明

- 本项目为个人学习与怀旧用途的复刻，未包含原版千千静听程序本体。版权归相关方面所有。
- `skins/` 内皮肤版仅仅包含自带皮肤和ai生成的两个皮肤，由于功能尚未实现很多皮肤不能完全展示，例如桌面歌词以及最小化模式，但是经过了上百个皮肤测试，拥有较好的兼容性。