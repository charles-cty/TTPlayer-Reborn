#include "TtblParser.h"
#include <QFile>
#include <QDebug>

namespace {

// --- 小工具函数 ---

inline quint16 readU16(const QByteArray& d, int off) {
    return static_cast<quint16>(static_cast<unsigned char>(d[off]))
         | (static_cast<quint16>(static_cast<unsigned char>(d[off+1])) << 8);
}

inline quint32 readU32(const QByteArray& d, int off) {
    return static_cast<quint32>(static_cast<unsigned char>(d[off]))
         | (static_cast<quint32>(static_cast<unsigned char>(d[off+1])) << 8)
         | (static_cast<quint32>(static_cast<unsigned char>(d[off+2])) << 16)
         | (static_cast<quint32>(static_cast<unsigned char>(d[off+3])) << 24);
}

inline qint32 readI32(const QByteArray& d, int off) {
    return static_cast<qint32>(readU32(d, off));
}

// 读取 UTF-16LE 字符串（byte_count 为字节数）。
inline QString readUtf16Le(const QByteArray& d, int off, int byte_count) {
    if (byte_count <= 0) return {};
    return QString::fromUtf16(
        reinterpret_cast<const char16_t*>(d.constData() + off),
        byte_count / 2);
}

// 检查范围是否安全，支持 int + int 安全加法。
bool inBounds(int offset, int size, int dataSize) {
    return offset >= 0 && size >= 0 && offset <= dataSize - size;
}

} // namespace

QVector<TtblEntry> TtblParser::parse(const QString& filePath, TtblHeader* headerOut) {
    QFile f(filePath);
    if (!f.open(QIODevice::ReadOnly))
        return {};
    return parse(f.readAll(), headerOut);
}

// TTBL 格式（小尾序）。
// 头部：
//   magic[4] = "TTBL"
//   version(i32)  已见 v3, v5
//   currentIndex(i32)
//   countField(u32)   可能与实际条目数不符（手动删除时不更新）
//   list_name_len(u32)
//   list_name[list_name_len]  UTF-16LE
//   仅 v5+： title_fmt_len(u32) + title_fmt[...] + default_fmt_len(u32) + default_fmt[...]
// 记录（循环至 EOF）：
//   path_len(u32) + path[path_len]  UTF-16LE
//   marker(u16)
//   若 marker==6（普通文件）: title_len(u32) + title[title_len] + duration_ms(u32)
//   若 marker==7（CUE轨）:  track_num(u16) + title_len(u32) + title[title_len] + duration_ms(u32)
QVector<TtblEntry> TtblParser::parse(const QByteArray& data, TtblHeader* headerOut) {
    QVector<TtblEntry> entries;
    const int dataSize = data.size();

    // 验证最小头部 (4+4+4+4+4 = 20 字节)
    if (dataSize < 20 || data.left(4) != "TTBL") {
        qWarning() << "[TtblParser] invalid magic or too short";
        return entries;
    }

    TtblHeader hdr;
    hdr.version       = readI32(data, 4);
    hdr.currentIndex  = readI32(data, 8);
    hdr.recordCount   = readU32(data, 12);
    quint32 nameLen   = readU32(data, 16);

    int off = 20;
    if (!inBounds(off, static_cast<int>(nameLen), dataSize)) {
        qWarning() << "[TtblParser] list_name out of bounds";
        return entries;
    }
    hdr.listName = readUtf16Le(data, off, static_cast<int>(nameLen));
    off += static_cast<int>(nameLen);

    // v5+ 有額外两个字段
    if (hdr.version >= 5) {
        if (off + 4 > dataSize) return entries;
        quint32 titleFmtLen = readU32(data, off); off += 4;
        if (!inBounds(off, static_cast<int>(titleFmtLen), dataSize)) return entries;
        off += static_cast<int>(titleFmtLen);

        if (off + 4 > dataSize) return entries;
        quint32 defaultFmtLen = readU32(data, off); off += 4;
        if (!inBounds(off, static_cast<int>(defaultFmtLen), dataSize)) return entries;
        off += static_cast<int>(defaultFmtLen);
    }

    // 解析记录
    int entryIndex = 0;
    while (off + 6 <= dataSize) {
        // 读取路径
        if (off + 4 > dataSize) break;
        quint32 pathLen = readU32(data, off);
        if (pathLen == 0 || pathLen > 8192) break;  // 超大路径长度视为贪败符
        if (!inBounds(off + 4, static_cast<int>(pathLen), dataSize)) break;
        QString filePath = readUtf16Le(data, off + 4, static_cast<int>(pathLen));
        off += 4 + static_cast<int>(pathLen);

        // 读取 marker
        if (off + 2 > dataSize) break;
        quint16 marker = readU16(data, off); off += 2;

        TtblEntry entry;
        entry.filePath = filePath;

        if (marker == 0x0006) {
            // 普通文件
            if (off + 4 > dataSize) break;
            quint32 titleLen = readU32(data, off); off += 4;
            if (!inBounds(off, static_cast<int>(titleLen), dataSize)) break;
            entry.title = readUtf16Le(data, off, static_cast<int>(titleLen));
            off += static_cast<int>(titleLen);
            if (off + 4 > dataSize) break;
            entry.durationMs  = static_cast<int64_t>(readU32(data, off)); off += 4;
            entry.isCueTrack  = false;
            entry.trackNumber = 0;
        } else if (marker == 0x0007) {
            // CUE 轨
            if (off + 2 > dataSize) break;
            entry.trackNumber = static_cast<int>(readU16(data, off)); off += 2;
            if (off + 4 > dataSize) break;
            quint32 titleLen = readU32(data, off); off += 4;
            if (!inBounds(off, static_cast<int>(titleLen), dataSize)) break;
            entry.title = readUtf16Le(data, off, static_cast<int>(titleLen));
            off += static_cast<int>(titleLen);
            if (off + 4 > dataSize) break;
            entry.durationMs = static_cast<int64_t>(readU32(data, off)); off += 4;
            entry.isCueTrack = true;
        } else {
            qWarning() << "[TtblParser] unknown marker" << Qt::hex << marker
                       << "at offset" << Qt::dec << (off - 2) << "entry" << entryIndex;
            break;
        }

        entries.append(entry);
        entryIndex++;
    }

    if (off != dataSize) {
        qWarning() << "[TtblParser] parsed" << entries.size() << "entries,"
                   << "final offset" << off << "(file size" << dataSize << ")"
                   << "remaining" << (dataSize - off) << "bytes";
    } else {
        qDebug() << "[TtblParser] OK: parsed" << entries.size()
                 << "entries from" << dataSize << "bytes"
                 << "listName=" << hdr.listName;
    }

    if (headerOut)
        *headerOut = hdr;

    return entries;
}
