#pragma once
#include <QString>
#include <QStringList>
#include <QVector>
#include <functional>

// 歌曲列表项，包含文件路径、元数据和时长信息。
struct PlaylistEntry {
    QString filePath;
    QString title;
    QString artist;
    QString album;
    int64_t durationMs = 0;
    bool valid = true;
    // 是否已通过 FFmpeg 完整加载过元数据（title/artist/album/durationMs）。
    // false 表示这是从 TTBL 快速加载的路径占位，元数据尚待后台填充。
    bool metadataLoaded = false;
};

// 播放列表管理类，支持增删、移动、随机、循环和显示文本构建。
class PlaylistManager {
public:
    PlaylistManager() = default;

    // 添加单个文件到播放列表。
    void addFile(const QString& path);
    void insertFile(int index, const QString& path);
    // 批量添加多个文件到播放列表。
    void addFiles(const QStringList& paths);
    void insertFiles(int index, const QStringList& paths);
    void addFiles(const QStringList& paths,
                  const std::function<bool(int processed, int total, const QString& currentPath)>& progressCallback);
    void insertFiles(int index, const QStringList& paths,
                     const std::function<bool(int processed, int total, const QString& currentPath)>& progressCallback);
    // 移除指定索引的列表项。
    void removeIndex(int index);
    // 清空整个播放列表。
    void clear();

    // 上移指定项。
    void moveUp(int index);
    // 下移指定项。
    void moveDown(int index);

    int count() const { return entries_.size(); }
    bool isEmpty() const { return entries_.isEmpty(); }

    const PlaylistEntry& at(int index) const { return entries_[index]; }
    PlaylistEntry& at(int index) { return entries_[index]; }

    QString fileAt(int index) const {
        if (index < 0 || index >= entries_.size()) return {};
        return entries_[index].filePath;
    }

    void removeAt(int index) { removeIndex(index); }

    int currentIndex() const { return currentIndex_; }
    // 设置当前播放索引。
    void setCurrentIndex(int idx);
    // 查找文件在列表中的索引。
    int indexOfFile(const QString& path) const;

    // 获取当前播放文件路径。
    QString currentFile() const;
    // 获取下一首文件路径。
    QString nextFile();
    // 获取上一首文件路径。
    QString prevFile();
    // 计算播放列表总时长。
    int64_t totalDurationMs() const;

    // 随机播放支持
    void setShuffle(bool on) { shuffle_ = on; }
    bool isShuffle() const { return shuffle_; }

    // 重复模式：0=不重复，1=单曲循环，2=列表循环
    void setRepeatMode(int mode) { repeatMode_ = mode; }
    int repeatMode() const { return repeatMode_; }

    // 返回用于列表显示的条目文本。
    QString displayText(int index) const;

    const QVector<PlaylistEntry>& entries() const { return entries_; }
    void setEntries(QVector<PlaylistEntry> entries) { entries_ = std::move(entries); }

private:
    QVector<PlaylistEntry> entries_;
    int currentIndex_ = -1;
    bool shuffle_ = false;
    int repeatMode_ = 2; // 默认列表循环
};
