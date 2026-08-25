#include "PlaylistManager.h"
#include "audio/Metadata.h"
#include <QDebug>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QRandomGenerator>
#include <algorithm>

namespace {

// 将时长转换成可读的文本格式，例如 "03:45" 或 "1:02:30"。
QString formatDurationText(int64_t durationMs) {
    const int totalSeconds = static_cast<int>(qMax<int64_t>(0, durationMs) / 1000);
    const int hours = totalSeconds / 3600;
    const int minutes = (totalSeconds / 60) % 60;
    const int seconds = totalSeconds % 60;

    if (hours > 0) {
        return QStringLiteral("%1:%2:%3")
            .arg(hours)
            .arg(minutes, 2, 10, QChar('0'))
            .arg(seconds, 2, 10, QChar('0'));
    }

    return QStringLiteral("%1:%2")
        .arg(minutes, 2, 10, QChar('0'))
        .arg(seconds, 2, 10, QChar('0'));
}

PlaylistEntry buildEntryForPath(const QString& path) {
    PlaylistEntry entry;
    entry.filePath = path;
    QFileInfo fi(path);
    entry.title = fi.completeBaseName();

    AudioFileMetadata meta;
    if (readAudioFileMetadata(path.toUtf8().constData(), meta)) {
        const QString title = QString::fromUtf8(meta.title.c_str()).trimmed();
        const QString artist = QString::fromUtf8(meta.artist.c_str()).trimmed();
        const QString album = QString::fromUtf8(meta.album.c_str()).trimmed();
        if (!title.isEmpty()) {
            entry.title = title;
        }
        entry.artist = artist;
        entry.album = album;
        entry.durationMs = meta.duration_ms;
    }

    return entry;
}
}

// 向播放列表添加单个音频文件，并通过 FFmpeg 提取标签元信息。
// 添加单个音频文件到播放列表，并提取标题、艺术家、专辑和时长等元数据。
void PlaylistManager::addFile(const QString& path) {
    insertFile(entries_.size(), path);
}

void PlaylistManager::insertFile(int index, const QString& path) {
    const int insertAt = qBound(0, index, entries_.size());
    entries_.insert(insertAt, buildEntryForPath(path));
    if (currentIndex_ >= insertAt) {
        ++currentIndex_;
    }
    if (currentIndex_ < 0) currentIndex_ = 0;
}

// 批量添加多个音频文件到播放列表。
void PlaylistManager::addFiles(const QStringList& paths) {
    insertFiles(entries_.size(), paths, {});
}

void PlaylistManager::insertFiles(int index, const QStringList& paths) {
    insertFiles(index, paths, {});
}

void PlaylistManager::addFiles(
    const QStringList& paths,
    const std::function<bool(int processed, int total, const QString& currentPath)>& progressCallback) {
    insertFiles(entries_.size(), paths, progressCallback);
}

void PlaylistManager::insertFiles(
    int index,
    const QStringList& paths,
    const std::function<bool(int processed, int total, const QString& currentPath)>& progressCallback) {
    QElapsedTimer totalTimer;
    totalTimer.start();

    const int insertStart = qBound(0, index, entries_.size());
    entries_.reserve(entries_.size() + paths.size());
    qint64 metadataLoopNs = 0;
    qint64 maxFileNs = 0;
    QString maxFilePath;
    QVector<QPair<qint64, QString>> topSlowFiles;
    topSlowFiles.reserve(5);

    auto updateTopSlow = [&topSlowFiles](qint64 fileNs, const QString& path) {
        if (topSlowFiles.size() < 5) {
            topSlowFiles.append({fileNs, path});
        } else {
            int minIndex = 0;
            for (int i = 1; i < topSlowFiles.size(); ++i) {
                if (topSlowFiles[i].first < topSlowFiles[minIndex].first) {
                    minIndex = i;
                }
            }
            if (fileNs > topSlowFiles[minIndex].first) {
                topSlowFiles[minIndex] = {fileNs, path};
            }
        }
    };

    int processedCount = 0;
    for (const auto& p : paths) {
        if (progressCallback && !progressCallback(processedCount, paths.size(), p)) {
            break;
        }

        QElapsedTimer fileTimer;
        fileTimer.start();
        entries_.insert(insertStart + processedCount, buildEntryForPath(p));
        const qint64 fileNs = fileTimer.nsecsElapsed();
        metadataLoopNs += fileNs;
        if (fileNs > maxFileNs) {
            maxFileNs = fileNs;
            maxFilePath = p;
        }
        updateTopSlow(fileNs, p);
        ++processedCount;
    }

    if (currentIndex_ >= insertStart) {
        currentIndex_ += processedCount;
    }
    if (currentIndex_ < 0 && !entries_.isEmpty()) {
        currentIndex_ = 0;
    }

    if (progressCallback) {
        progressCallback(processedCount, paths.size(), QString());
    }

    std::sort(topSlowFiles.begin(), topSlowFiles.end(),
              [](const auto& a, const auto& b) { return a.first > b.first; });

    const qint64 totalMs = totalTimer.elapsed();
    const double metadataLoopMs = static_cast<double>(metadataLoopNs) / 1000000.0;
    const double avgMs = processedCount == 0
        ? 0.0
        : metadataLoopMs / static_cast<double>(processedCount);
    const double maxFileMs = static_cast<double>(maxFileNs) / 1000000.0;

    qDebug().noquote()
        << QStringLiteral("[ImportPerf][PlaylistManager] addFiles count=%1 total=%2ms metadata_loop=%3ms avg_per_file=%4ms max_file=%5ms path=\"%6\"")
               .arg(processedCount)
               .arg(totalMs)
               .arg(metadataLoopMs, 0, 'f', 3)
               .arg(avgMs, 0, 'f', 3)
               .arg(maxFileMs, 0, 'f', 3)
               .arg(maxFilePath);

    if (!topSlowFiles.isEmpty()) {
        QStringList topLines;
        topLines.reserve(topSlowFiles.size());
        for (const auto& item : topSlowFiles) {
            const double itemMs = static_cast<double>(item.first) / 1000000.0;
            topLines.append(QStringLiteral("%1ms:%2")
                                .arg(itemMs, 0, 'f', 3)
                                .arg(QFileInfo(item.second).fileName()));
        }
        qDebug().noquote()
            << QStringLiteral("[ImportPerf][PlaylistManager] top_slow_files %1")
                   .arg(topLines.join(QStringLiteral(", ")));
    }
}

// 删除指定索引的列表项，并更新当前播放索引。
void PlaylistManager::removeIndex(int index) {
    if (index < 0 || index >= entries_.size()) return;
    entries_.removeAt(index);
    if (currentIndex_ > index) {
        --currentIndex_;
    }
    if (currentIndex_ >= entries_.size())
        currentIndex_ = entries_.size() - 1;
    if (entries_.isEmpty()) {
        currentIndex_ = -1;
    }
}

// 清空播放列表。
void PlaylistManager::clear() {
    entries_.clear();
    currentIndex_ = -1;
}

// 将指定条目上移一位。
void PlaylistManager::moveUp(int index) {
    if (index <= 0 || index >= entries_.size()) return;
    std::swap(entries_[index], entries_[index - 1]);
    if (currentIndex_ == index) currentIndex_--;
    else if (currentIndex_ == index - 1) currentIndex_++;
}

// 将指定条目下移一位。
void PlaylistManager::moveDown(int index) {
    if (index < 0 || index >= entries_.size() - 1) return;
    std::swap(entries_[index], entries_[index + 1]);
    if (currentIndex_ == index) currentIndex_++;
    else if (currentIndex_ == index + 1) currentIndex_--;
}

// 返回当前播放文件的路径。
QString PlaylistManager::currentFile() const {
    if (currentIndex_ < 0 || currentIndex_ >= entries_.size()) return {};
    return entries_[currentIndex_].filePath;
}

// 设置当前播放索引，并确保索引在有效范围内。
void PlaylistManager::setCurrentIndex(int idx) {
    if (entries_.isEmpty()) {
        currentIndex_ = -1;
        return;
    }

    if (idx < 0) {
        return;
    }

    currentIndex_ = qBound(0, idx, entries_.size() - 1);
}

// 查找指定文件路径在播放列表中的位置。
int PlaylistManager::indexOfFile(const QString& path) const {
    for (int i = 0; i < entries_.size(); ++i) {
        if (entries_[i].filePath == path) {
            return i;
        }
    }
    return -1;
}

// 获取下一首文件路径，根据当前循环模式和随机模式决定行为。
QString PlaylistManager::nextFile() {
    if (entries_.isEmpty()) return {};

    if (repeatMode_ == 1) {
        // 单曲循环
        return currentFile();
    }

    if (shuffle_) {
        int idx = QRandomGenerator::global()->bounded(entries_.size());
        currentIndex_ = idx;
        return entries_[idx].filePath;
    }

    currentIndex_++;
    if (currentIndex_ >= entries_.size()) {
        if (repeatMode_ == 2) {
            currentIndex_ = 0;
        } else {
            currentIndex_ = entries_.size() - 1;
            return {};
        }
    }
    return entries_[currentIndex_].filePath;
}

// 获取上一首文件路径，根据当前循环或随机模式决定行为。
QString PlaylistManager::prevFile() {
    if (entries_.isEmpty()) return {};

    if (repeatMode_ == 1) {
        // 单曲循环
        return currentFile();
    }

    if (shuffle_) {
        int idx = QRandomGenerator::global()->bounded(entries_.size());
        currentIndex_ = idx;
        return entries_[idx].filePath;
    }

    currentIndex_--;
    if (currentIndex_ < 0) {
        if (repeatMode_ == 2) {
            currentIndex_ = entries_.size() - 1;
        } else {
            currentIndex_ = 0;
            return {};
        }
    }
    return entries_[currentIndex_].filePath;
}

// 计算播放列表中所有条目的总时长。
int64_t PlaylistManager::totalDurationMs() const {
    int64_t total = 0;
    for (const auto& entry : entries_) {
        total += qMax<int64_t>(0, entry.durationMs);
    }
    return total;
}

// 生成用于列表显示的文本，包含序号、艺术家、标题和时长信息。
QString PlaylistManager::displayText(int index) const {
    if (index < 0 || index >= entries_.size()) return {};
    const auto& e = entries_[index];
    QString title = e.title.isEmpty() ? QFileInfo(e.filePath).completeBaseName() : e.title;
    if (!e.artist.isEmpty()) {
        title = e.artist + QStringLiteral(" - ") + title;
    }

    QString text = QStringLiteral("%1. %2").arg(index + 1).arg(title);
    if (e.durationMs > 0) {
        text += QStringLiteral("  [%1]").arg(formatDurationText(e.durationMs));
    }
    return text;
}
