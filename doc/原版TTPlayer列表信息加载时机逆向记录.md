# 原版 TTPlayer 列表信息加载时机逆向记录

本文档只基于以下真实对象分析：

- `TTPlayerv5.7.9/PlayList/0000.ttbl`
- `TTPlayerv5.7.9/TTPlayer.exe`
- `TTPlayerv5.7.9/ttpcomm.dll`
- `TTPlayerv5.7.9/TTPlayer.xml`

没有参考仓库中已有逆向文档。

## 1. 要回答的问题

原版播放列表支持这些排序项：

- 按显示标题
- 按文件名
- 按路径名
- 按专辑名
- 按文件时间
- 按音轨序号
- 按播放长度

但 `TTBL` 文件里已确认稳定存在的字段只有：

- 路径
- 显示标题
- 时长
- 若干固定整数

`TTBL` 中没有发现专辑名和音轨号的持久化字段。

因此关键问题是：

- 原版什么时候得到“专辑名 / 音轨号 / 文件时间”这些排序字段？

## 2. 已确认：`TTBL` 只够支撑一部分排序

从 [原版TTPlayer播放列表TTBL格式逆向记录.md](/home/john/Downloads/TTPlayer-main/ttplayer-reborn/doc/原版TTPlayer播放列表TTBL格式逆向记录.md) 的样本可知，每条记录稳定包含：

- 文件路径
- 显示标题
- 时长毫秒

这三类字段足够直接支撑：

- 按显示标题
- 按文件名
- 按路径名
- 按播放长度

但不够支撑：

- 按专辑名
- 按音轨序号

其中“按文件时间”不需要写进 `TTBL`，运行时直接查文件系统即可。

## 3. 二进制里的直接证据

### 3.1 `TTPlayer.exe` 中的播放列表配置名

主程序里能直接看到这些配置键：

- `ReadInfoMode`
- `SaveTags`
- `TagTitleFormat`
- `DefTitleFormat`
- `TitleNumber`

这些字符串都位于 `TTPlayer.exe` 数据段中，说明播放列表模块自己就区分：

- 是否保存标签信息
- 是否读取文件信息
- 如何生成标题

对应样本配置 `TTPlayer.xml`：

```xml
<PlayList
    CreateNewVerPlayList="0"
    LibraryMode="0"
    ReadInfoMode="0"
    TitleNumber="1"
    SaveTags="0"
    TagFormat="1"
    TagTitleFormat="%A - %T"
    DefTitleFormat="%F"
/>
```

这里最关键的是：

- `SaveTags="0"`
- `ReadInfoMode="0"`

### 3.1.1 `ReadInfoMode / SaveTags / TagTitleFormat` 不是死字符串

这几个配置键不只是“出现在字符串表里”，而是能在 `TTPlayer.exe` 的真实代码路径里看到引用。

在 `TTPlayer.exe` 反汇编中，地址 `0x4bbedd` 到 `0x4bc1bf` 附近存在一段连续配置读取代码，反复把下列字符串地址压栈并调用同一组配置访问函数：

- `0x5211d4` -> `ReadInfoMode`
- `0x5211c8` -> `TitleNumber`
- `0x5211b8` -> `IgnoreBadFiles`
- `0x5211a4` -> `SaveRelativePath`
- `0x521198` -> `SaveTags`
- `0x52118c` -> `TagFormat`
- `0x521180` -> `ClickRating`
- `0x521170` -> `TagTitleFormat`

这说明：

- `ReadInfoMode` 是播放列表/标签路径里的活跃配置
- `SaveTags` 也是活跃配置
- 原版确实在运行时区分“显示标题格式”和“标签读取/保存策略”

换句话说，`TTPlayer.xml` 里的这些键不是摆设，而是实际参与播放列表行为控制。

### 3.2 `ttpcomm.dll` 中的标签字段与排序字段名

在 `ttpcomm.dll` 里可以直接看到这些字符串：

- `Title`
- `Album`
- `Artist`
- `Tracknumber`
- `Album sort order`
- `Title sort order`
- `Tagging time`
- `Comment`
- `Content type (Genre)`

这说明：

- 原版确实有独立的“标签读取 / 标签对象 / 排序键”子系统
- 至少“专辑名”和“音轨号”这些字段不是临时 UI 文案，而是有稳定内部名称
- 排序并不是单纯围绕 `TTBL` 字段展开

### 3.2.1 `ttpcomm.dll` 里存在“标签字段描述表”

继续看 `ttpcomm.dll` 的 `.rdata/.data`，可以确认这些字符串不是零散文本，而是被组织成一张连续字段表。

例如在 `.rdata` 中可以稳定看到这样的成对内容：

- `Album sort order` -> `TSOA`
- `Album` -> `TALB`
- `Artist` -> `TPE1`
- `Tracknumber` -> `TRCK`
- `Title sort order` -> `TSOT`

进一步在 `.data` 可见一组重复结构，典型项形如：

```text
0x60028df8  0x60028df0  0x00000002  0x60028130  0x00000000
   Album       TALB          2        same fnptr     0

0x60028ddc  0x60028dd4  0x00000002  0x60028130  0x00000000
 Album sort    TSOA          2        same fnptr     0

0x60028f30  0x60028f28  0x00000002  0x60028130  0x00000000
 Tracknumber   TRCK          2        same fnptr     0

0x6002909c  0x60029094  0x00000002  0x60028130  0x00000000
 Title sort    TSOT          2        same fnptr     0
```

虽然没有完整类型信息，但这已经足够说明：

- `ttpcomm.dll` 内部维护了一张“标签字段描述表”
- 每个字段至少绑定了：
  - 可读名称
  - 对应标签帧名
  - 统一类型码
  - 统一处理函数
- `Album / Tracknumber / Title sort order` 这些字段属于同一套标签元数据系统

这比单纯“字符串里出现过这些词”要强很多，它更像原版真正用于读标签、比较、显示的一张字段注册表。

### 3.3 `TTBL` 与 `ttpcomm.dll` 的职责明显不同

综合样本可见：

- `TTBL` 负责列表持久化
- `ttpcomm.dll` 负责标签字段和排序键

这两个职责是分离的。

### 3.4 `TTPlayer.exe` 里会构造带字段描述指针的对象

在 `TTPlayer.exe` 里，地址 `0x41d706` 开始有一个对象初始化函数，会把 `0x51c028` 写入对象首地址，并清空后续多个字段：

```asm
41d721: mov [eax], 0x51c028
...
41d736: mov byte ptr [eax+0x50], 1
41d73a: mov byte ptr [eax+0x51], 1
```

另一个更直观的构造点在 `0x420bad` 一带：

```asm
420bad: lea eax, [ebx+0x178]
420bb3: mov esi, 0x51c028
420bb8: mov [eax], esi
420bbd: call 0x404794

420bc2: lea eax, [ebx+0x124]
420bc8: mov [eax], esi
420bcd: call 0x404794
```

也就是说，主程序会把同一个字段描述/虚表指针 `0x51c028` 塞进两个内部子对象，再调用统一初始化逻辑。

这里虽然还没把 `0x51c028` 精确还原成 C++ 类名，但可以确定：

- 主程序内部确实存在“字段对象 / 比较器对象 / 标签字段对象”这一类结构
- 这些对象不是从 `TTBL` 直接反序列化出来的文本块
- 更像是在程序启动或模块初始化时统一构造，然后在列表/排序代码里复用

## 4. 能排除什么

### 4.1 不是“保存列表时就把全部标签写进 `TTBL`”

原因：

- 样本 `TTBL` 记录结构中没有稳定的专辑名字段
- 也没有稳定的音轨号字段
- 若原版把这些字段持久化了，按当前样本大小和结构，应该能在记录尾部观察到额外长度块，但没有

所以可以排除：

- “原版靠 `TTBL` 持久化全部排序字段”

### 4.2 不是“只靠显示标题字符串去伪造专辑排序/音轨排序”

原因：

- `Title` 和 `Album`、`Tracknumber` 在二进制里是独立字段名
- `ttpcomm.dll` 还出现了 `Album sort order`、`Title sort order`
- 这更像真实标签字段，而不是从显示标题里再拆

所以也可以排除：

- “专辑名 / 音轨号只是从标题文本里猜出来的”

## 5. 最可能的工作流

基于现有证据，我认为原版最可能是下面这套流程：

1. 加载 `TTBL`
2. 立刻用 `TTBL` 中已有的：
   - 路径
   - 显示标题
   - 时长
   来构建列表 UI
3. 对于 `Album`、`Tracknumber`、可能还有 `Artist/Genre/Year` 这类字段：
   - 通过 `ttpcomm.dll` 的标签读取层从音频文件重新读取
   - 然后缓存到内存中的播放项对象

这就解释了为什么：

- 列表文件本身不需要保存所有标签
- 原版仍然可以按专辑名和音轨号排序

## 6. “到底是打开列表时读，还是排序时才读？”

这是本轮逆向里最核心、但还不能 100% 实锤的问题。

### 6.1 已确定的下界

最晚在执行以下排序之一之前，原版必须已经拿到这些字段：

- 按专辑名
- 按音轨序号

否则比较函数没有数据可用。

### 6.2 两种可能实现

#### 方案 A：打开列表后统一补读

流程：

- 载入 `TTBL`
- 先显示列表
- 然后批量扫描文件标签，把 `Album/Tracknumber/...` 填进内存

优点：

- 后续各种排序都快
- 比较函数简单

缺点：

- 打开大列表时会额外有一轮标签 I/O

#### 方案 B：第一次用到该字段时按需读

流程：

- 平时只用 `TTBL`
- 用户第一次点“按专辑名排序”时，才逐项补读 `Album`
- 第一次点“按音轨序号排序”时，才逐项补读 `Tracknumber`

优点：

- 打开列表更快

缺点：

- 第一次执行某些排序时会明显卡顿
- 需要字段级缓存

## 7. 目前我更倾向哪一种

结合这轮新增证据，我现在更倾向于：

- **原版在打开列表后，不会立刻把所有标签完整持久化回 `TTBL`**
- **但它很可能会尽早把“可参与排序的字段定义”准备好**
- **真正的 `Album / Tracknumber` 值，则在运行期通过 `ttpcomm.dll` 这套字段系统按文件读取并缓存**

也就是说，更像下面这种分层：

1. `TTBL` 恢复路径、显示标题、时长，保证列表秒开
2. `TTPlayer.exe` 初始化字段对象、排序器和配置
3. `ttpcomm.dll` 按字段描述表读取标签值
4. 排序逻辑使用内存中的字段值，而不是依赖 `TTBL` 持久化

## 8. 目前最稳的结论

截至这轮逆向，下面这些点已经可以认为是高置信结论：

- `TTBL` 不保存完整标签集合，至少没有稳定保存 `Album` 和 `Tracknumber`
- `ReadInfoMode` / `SaveTags` / `TagTitleFormat` 是真实参与播放列表逻辑的配置
- `ttpcomm.dll` 内部有一张标签字段描述表，不是零散字符串
- `Album`、`Tracknumber`、`Album sort order`、`Title sort order` 都在这套字段系统里
- `TTPlayer.exe` 会构造引用同一字段描述指针的内部对象，说明排序/字段访问是“对象化”的运行时逻辑

## 9. 仍未完全实锤的点

还差最后一刀才能 100% 说清楚的是：

- `Album / Tracknumber` 的真实标签值，是在“列表载入后统一补读”，还是“第一次触发相关排序时按需读”

当前证据更偏向“运行时读 + 内存缓存”，但还不能仅凭现有片段把读取时机钉死。

## 10. 下一步最值得继续挖的方向

如果继续逆向，最值的是：

1. 追排序菜单命令 ID 对应的处理函数
2. 在这些函数附近找是否调用了标签字段填充逻辑
3. 继续追 `0x51c028` 所代表对象的虚表/方法表
4. 找 `TTPlayer.exe` 和 `ttpcomm.dll` 之间谁在请求 `Album / Tracknumber` 的真实值
