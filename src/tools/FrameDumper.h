#pragma once
#include <QString>

// 帧快照导出工具：对每个窗口按固定状态矩阵渲染 PNG（Layer 2 快照测试的基准端）。
//
// 状态矩阵定义见 FrameDumper.cpp 顶部注释与 docs/testing.md。
// 同时输出 masks.json：文本类元素的矩形列表，像素对比时排除
// （跨实现的文本光栅化无法逐像素一致；位图字体不在此列）。
namespace FrameDumper {

// 加载皮肤并把全部状态帧写入 outDir。返回进程退出码：0 表示成功。
int run(const QString& skinPath, const QString& outDir);

}  // namespace FrameDumper
