#pragma once
#include <QByteArray>
#include <QVector>
#include <QString>

// 原版 TTPlayer .ttbl 二进制播放列表条目。
// metadataLoaded 固定为 false，由调用方后台填充 title/artist/durationMs。
struct TtblEntry {
    QString filePath;   // Windows 路径（含 Z:\ 前缀），调用方负责映射本地路径。
    QString title;      // TTBL 内嵌标题（若非空可直接使用）。
    QString artist;     // 暂未从 TTBL 提取，留空。
    int64_t durationMs = 0;
    int     trackNumber = 0;  // 仅 CUE 轨（marker==7）有效，其余为 0。
    bool    isCueTrack  = false;
};

// 播放列表头部信息（来自 TTBL 文件头）。
struct TtblHeader {
    int     version      = 3;
    int     currentIndex = -1;  // 原始当前播放索引
    quint32 recordCount  = 0;   // 文件头中的计数（可能与实际条目数不符）
    QString listName;           // 播放列表名称
};

// 解析 .ttbl 格式播放列表文件（支持 version 3 和 version 5）。
class TtblParser {
public:
    // 从文件路径解析，返回条目列表。
    QVector<TtblEntry> parse(const QString& filePath, TtblHeader* headerOut = nullptr);
    // 从内存数据解析。
    QVector<TtblEntry> parse(const QByteArray& data, TtblHeader* headerOut = nullptr);
};
