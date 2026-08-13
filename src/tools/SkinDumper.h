#pragma once
#include <QString>

// 皮肤数据导出工具：把 SkinEngine 解析出的 SkinData 序列化为规范化 JSON。
//
// 该 JSON 是 Lazarus 重写版皮肤解析的验收契约（differential testing 的基准端）：
// Pascal 侧 ttdump 输出同样格式，两者逐字节比对即可发现解析差异。
// 输出经过规范化处理，保证跨实现可比：
//   - 对象键按字典序排列
//   - 颜色统一为小写 "#rrggbb"，无效颜色输出 null
//   - 矩形统一为 {x, y, w, h}
//   - 字体归一化为 {family, pixel_size, bold, italic}
//   - 只记录图像的名称与尺寸，不含像素数据
namespace SkinDumper {

// 加载指定皮肤（.skn 文件或已解压目录）并将 SkinData 写入 outPath。
// 返回进程退出码：0 表示成功。
int run(const QString& skinPath, const QString& outPath);

}  // namespace SkinDumper
