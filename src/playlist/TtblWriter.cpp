#include "TtblWriter.h"
#include <QFile>
#include <QFileInfo>
#include <QDir>
#include <QDebug>

namespace {

void writeU16Le(QByteArray& buf, quint16 v) {
    buf.append(static_cast<char>(v & 0xFF));
    buf.append(static_cast<char>((v >> 8) & 0xFF));
}

void writeU32Le(QByteArray& buf, quint32 v) {
    buf.append(static_cast<char>(v & 0xFF));
    buf.append(static_cast<char>((v >> 8) & 0xFF));
    buf.append(static_cast<char>((v >> 16) & 0xFF));
    buf.append(static_cast<char>((v >> 24) & 0xFF));
}

void writeI32Le(QByteArray& buf, qint32 v) {
    writeU32Le(buf, static_cast<quint32>(v));
}

// 将 QString 编码为 UTF-16LE 字节数组（不含 BOM，不含终止符）。
QByteArray toUtf16Le(const QString& s) {
    if (s.isEmpty()) return {};
    QByteArray result;
    result.resize(s.size() * 2);
    for (int i = 0; i < s.size(); ++i) {
        const ushort ch = s.at(i).unicode();
        result[i * 2]     = static_cast<char>(ch & 0xFF);
        result[i * 2 + 1] = static_cast<char>((ch >> 8) & 0xFF);
    }
    return result;
}

void writeUtf16LeField(QByteArray& buf, const QString& s) {
    const QByteArray encoded = toUtf16Le(s);
    writeU32Le(buf, static_cast<quint32>(encoded.size()));
    buf.append(encoded);
}

} // namespace

QByteArray TtblWriter::serialize(const QVector<PlaylistEntry>& entries,
                                 const QString& listName,
                                 int currentIndex) const {
    QByteArray buf;
    buf.reserve(128 + entries.size() * 256);

    // --- 文件头 ---
    buf.append("TTBL");                            // magic
    writeI32Le(buf, 3);                            // version = 3
    writeI32Le(buf, currentIndex);                 // currentIndex
    writeU32Le(buf, static_cast<quint32>(entries.size()));  // countField
    writeUtf16LeField(buf, listName);              // list_name

    // --- 记录 ---
    for (const PlaylistEntry& e : entries) {
        // 路径（使用原始路径，Linux 路径也可以直接写入）
        writeUtf16LeField(buf, e.filePath);

        // marker = 6（普通文件）
        writeU16Le(buf, 0x0006);

        // 标题：优先使用 artist - title 格式（若有艺术家），否则直接使用 title
        QString titleStr = e.title;
        if (!e.artist.isEmpty() && !titleStr.isEmpty()) {
            titleStr = e.artist + QStringLiteral(" - ") + titleStr;
        }
        writeUtf16LeField(buf, titleStr);

        // 时长（毫秒，uint32）
        writeU32Le(buf, static_cast<quint32>(qMax<int64_t>(0, e.durationMs)));
    }

    return buf;
}

bool TtblWriter::write(const QString& filePath,
                       const QVector<PlaylistEntry>& entries,
                       const QString& listName,
                       int currentIndex) const {
    const QString dir = QFileInfo(filePath).absolutePath();
    if (!dir.isEmpty()) {
        QDir().mkpath(dir);
    }

    QFile f(filePath);
    if (!f.open(QIODevice::WriteOnly)) {
        qWarning() << "[TtblWriter] cannot open for write:" << filePath;
        return false;
    }

    const QByteArray data = serialize(entries, listName, currentIndex);
    const qint64 written = f.write(data);
    if (written != data.size()) {
        qWarning() << "[TtblWriter] short write:" << written << "/" << data.size();
        return false;
    }

    qDebug() << "[TtblWriter] saved" << entries.size() << "entries to" << filePath;
    return true;
}
