#pragma once
#include <QVector>
#include <QString>
#include <QByteArray>
#include "TtblParser.h"
#include "PlaylistManager.h"

// 将播放列表条目序列化为 .ttbl 二进制格式。
// 输出与原版 TTPlayer 兼容的 version=3 文件。
class TtblWriter {
public:
    // 将条目写入文件，返回是否成功。
    // listName: 播放列表名称（显示在标签页上）。
    // currentIndex: 当前播放索引（写入文件头）。
    bool write(const QString& filePath,
               const QVector<PlaylistEntry>& entries,
               const QString& listName,
               int currentIndex = -1) const;

    // 将条目序列化为字节数组（供调试或测试使用）。
    QByteArray serialize(const QVector<PlaylistEntry>& entries,
                         const QString& listName,
                         int currentIndex = -1) const;
};
