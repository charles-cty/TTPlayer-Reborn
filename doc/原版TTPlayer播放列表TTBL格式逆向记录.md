# 原版 TTPlayer 播放列表 `TTBL` 格式逆向记录

本文档只基于原版安装目录中的真实文件和二进制做分析：

- `TTPlayerv5.7.9/PlayList/0000.ttbl`
- `TTPlayerv5.7.9/TTPlayer.exe`

没有参考仓库中现成的逆向文档。

## 1. 结论概览

原版播放列表文件 `*.ttbl` 是一个：

- 小端序二进制格式
- 文件头以 ASCII `"TTBL"` 开始
- 后续字符串统一为 UTF-16LE
- 字符串前带 32 位长度字段
- 每个播放项是固定结构的重复记录块

已经可以稳定解析出：

- 文件魔数
- 文件版本
- 当前索引字段
- 一个 32 位计数字段
- 列表名
- 标题格式字符串
- 默认标题格式字符串
- 每首歌的路径
- 每首歌的显示标题
- 每首歌的时长（毫秒）
- 每首歌后面两个固定整数

## 2. 文件头

`0000.ttbl` 开头 0x36 字节可以稳定解出：

```text
00 54 54 42 4c                      "TTBL"
04 05 00 00 00                      version = 5
08 ff ff ff ff                      current_index = -1
0c 52 00 00 00                      count_field = 82
10 08 00 00 00                      list_name_len = 8
14 5b 00 d8 9e a4 8b 5d 00          "[默认]"
1c 0e 00 00 00                      title_fmt_len = 14
20 25 00 41 00 20 00 2d 00 20 00
   25 00 54 00                      "%A - %T"
2e 04 00 00 00                      default_fmt_len = 4
32 25 00 46 00                      "%F"
```

对应结构：

```c
struct TTBLHeaderV5 {
    char magic[4];          // "TTBL"
    uint32_t version;       // 样本为 5
    int32_t currentIndex;   // 样本为 -1
    uint32_t countField;    // 样本为 82，语义存在疑点，见后文
    uint32_t listNameLen;   // UTF-16LE 字节数，不含结尾 0
    char16_t listName[];
    uint32_t titleFmtLen;   // UTF-16LE 字节数
    char16_t titleFmt[];
    uint32_t defaultFmtLen; // UTF-16LE 字节数
    char16_t defaultFmt[];
};
```

### 2.1 已确认点

- 长度字段是 `uint32_t`
- 长度单位是“字节数”，不是字符数
- UTF-16LE 字符串都不带结尾 `0x0000`
- 样本里的三个全局字符串分别是：
  - 列表名：`[默认]`
  - 标题格式：`%A - %T`
  - 默认标题格式：`%F`

这些值和原版 `TTPlayer.xml` 里的相关配置是能互相对上的，但格式本身可以独立从 `ttbl` 解出。

## 3. 播放项记录结构

从偏移 `0x36` 开始进入播放项区。单条记录可以按下面结构稳定解析：

```c
struct TTBLItemV5 {
    uint32_t pathLen;       // UTF-16LE 字节数
    char16_t path[];

    uint32_t itemMarker;    // 样本恒为 0x46

    uint32_t titleLen;      // UTF-16LE 字节数
    char16_t title[];

    uint32_t durationMs;    // 时长，毫秒
    uint32_t flag1;         // 样本恒为 2
    uint32_t flag2;         // 样本恒为 0
};
```

## 4. 首条记录示例

首条记录从 `0x36` 开始：

```text
36 48 00 00 00                         pathLen = 72
3a ...                                 path = "G:\\许镜清《西游记主题音乐会》\\01. 云宫迅音(乐队演奏版).wav"
82 46 00 00 00                         itemMarker = 0x46
86 1e 00 00 00                         titleLen = 30
8a ...                                 title = "01. 云宫迅音(乐队演奏版)"
a8 48 26 05 00                         durationMs = 337480
ac 02 00 00 00                         flag1 = 2
b0 00 00 00 00                         flag2 = 0
```

### 4.1 字段解释

- `pathLen = 72`
  - 对应 36 个 UTF-16LE 代码单元
  - 正好能覆盖完整路径，不包含额外结尾空字符
- `itemMarker = 0x46`
  - 十六进制 `0x46` 是 ASCII `'F'`
  - 在样本 92 条记录中全部相同
  - 高概率表示“文件项（File）”
- `titleLen = 30`
  - 对应 15 个 UTF-16LE 代码单元
- `durationMs = 337480`
  - 即 337.480 秒，约 5 分 37 秒
- `flag1 = 2`
  - 样本 92 条记录全部为 2
- `flag2 = 0`
  - 样本 92 条记录全部为 0

## 5. 按该结构解析样本文件

按上述结构从 `0x36` 顺序解析，`0000.ttbl` 可以完整读出 92 条记录，直到文件结束，没有额外尾部块、校验块或压缩块。

已验证的条目类型包括：

- `wav`
- `flac`
- 中英文混合路径
- UTF-16LE 标题
- 标题与文件名不同的情况

例如：

- `G:\许镜清《西游记主题音乐会》\01. 云宫迅音(乐队演奏版).wav`
  - 标题：`01. 云宫迅音(乐队演奏版)`
- `G:\music\we find ourselves.flac`
  - 标题：`JODA - We Find Ourselves`
- `G:\music\Natural+-+Imagine+Dragons.flac`
  - 标题：`Imagine Dragons - Natural`

这说明 `ttbl` 保存的是“路径 + 已解析好的显示标题 + 时长”，不是只有路径。

## 6. 关于头部 `countField` 的异常

这是当前最重要的未完全确定点。

样本头部：

- `countField = 82`

但按记录结构顺序解析到 EOF：

- 能读出 92 条完整记录

这意味着以下三种可能性里至少有一种成立：

1. `countField` 才是“逻辑有效条目数”，文件尾部多出来的 10 条是旧数据残留。
2. `countField` 不是总条目数，而是别的统计值。
3. 原版写文件时可能只更新头和前部数据，不总是截断旧文件尾部。

### 6.1 我更倾向的解释

高概率是第 1 或第 3 种，即：

- 头里的 `countField` 更值得信任
- 文件尾部可能存在旧记录残留

原因：

- `82` 是一个非常像“条目数”的值
- 尾部多出来的记录仍然是完全合法的旧记录块
- 这类“覆盖写入但未截断”的现象在旧 Windows 程序里并不少见

因此如果要做兼容读取，建议：

- **优先按 `countField` 读取**
- 调试模式下可以继续尝试向后扫描，检查是否还有残留记录
- 不要默认把 EOF 前所有看起来合法的记录都当成当前有效列表

## 7. `TTPlayer.exe` 里的旁证

从 `TTPlayer.exe` 可直接看到这些字符串：

- `TTBL`
- `ttplaylist`
- `PlayList`
- `PlayListPath`
- `AddToPlayList`
- `CreateNewVerPlayList`
- `strDefaultList`

这些字符串不能单独证明字段布局，但能说明：

- 原版确实显式区分 `PlayList`
- 程序内部知道“新版本播放列表”这一概念
- `TTBL` 是程序原生使用的正式格式，不是外部插件格式

其中 `CreateNewVerPlayList` 和样本头里的 `version = 5` 是能相互印证的。

## 8. 当前可复现的解析规则

如果只是为了兼容读取原版 `ttbl`，当前可以使用这套规则：

1. 读取 4 字节魔数，必须为 `TTBL`
2. 读取 `uint32_t version`
3. 读取 `int32_t currentIndex`
4. 读取 `uint32_t countField`
5. 依次读取 3 个“长度 + UTF-16LE 字符串”
6. 从当前位置开始按记录结构读取播放项
7. 兼容模式下：
   - 保守策略：只读取 `countField` 条
   - 调试策略：额外尝试扫描 EOF，并报告是否存在尾部残留记录

## 9. 推荐的数据结构

```c
struct TTBLFile {
    uint32_t version;
    int32_t currentIndex;
    uint32_t countField;
    std::u16string listName;
    std::u16string titleFormat;
    std::u16string defaultTitleFormat;
    std::vector<TTBLItemV5> items;
};
```

## 10. 已确认 / 高概率 / 未确认

### 10.1 已确认

- 魔数是 `TTBL`
- 版本字段样本为 `5`
- 字符串编码是 UTF-16LE
- 字符串长度单位是字节
- 每条记录都包含：
  - 文件路径
  - 一个固定 `0x46`
  - 标题
  - 时长毫秒
  - `2`
  - `0`

### 10.2 高概率

- `0x46` 表示 `File`
- `durationMs` 就是毫秒时长
- 头里的 3 个字符串分别对应：
  - 列表名
  - 展示格式
  - 默认展示格式

### 10.3 仍未完全确认

- `countField` 的最终语义
- `flag1 = 2` 的准确含义
- `flag2 = 0` 的准确含义
- 是否存在其他 `itemMarker`（例如目录、URL、CUE 子轨道）

## 11. 兼容实现建议

如果后续要在 `ttplayer-reborn` 里做原版兼容读写，建议策略是：

- 读取时：
  - 先严格按头部解析
  - 默认信任 `countField`
  - 提供调试开关扫描尾部残留项
- 写入时：
  - 重新生成完整文件
  - 明确截断旧文件
  - 不要复用旧尾部内容

这样可以避免把原版可能留下的“历史残留记录”误读成当前播放列表内容。
