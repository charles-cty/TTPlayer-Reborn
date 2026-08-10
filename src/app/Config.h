#pragma once
#include <QString>
#include <QPoint>
#include <QSize>
#include <QMap>

// 程序配置管理类，负责保存与恢复用户设置，包括音量、EQ、窗口位置、皮肤、播放模式等。
class Config {
public:
    Config();

    // 从文件加载配置。返回是否成功。
    bool load(const QString& filePath);
    // 将当前配置保存到文件。返回是否成功。
    bool save(const QString& filePath) const;

    // 播放器状态
    int volume() const { return volume_; }
    void setVolume(int v) { volume_ = v; }

    bool muted() const { return muted_; }
    void setMuted(bool m) { muted_ = m; }

    int balance() const { return balance_; }
    void setBalance(int b) { balance_ = b; }

    // 均衡器
    bool eqEnabled() const { return eqEnabled_; }
    void setEqEnabled(bool e) { eqEnabled_ = e; }
    float eqPreamp() const { return eqPreamp_; }
    void setEqPreamp(float p) { eqPreamp_ = p; }
    float eqBand(int index) const;
    void setEqBand(int index, float gain);

    // 窗口位置
    QPoint playerPos() const { return playerPos_; }
    void setPlayerPos(const QPoint& p) { playerPos_ = p; }
    QSize playerSize() const { return playerSize_; }
    void setPlayerSize(const QSize& s) { playerSize_ = s; }
    QPoint lyricPos() const { return lyricPos_; }
    void setLyricPos(const QPoint& p) { lyricPos_ = p; }
    QSize lyricSize() const { return lyricSize_; }
    void setLyricSize(const QSize& s) { lyricSize_ = s; }
    QPoint eqPos() const { return eqPos_; }
    void setEqPos(const QPoint& p) { eqPos_ = p; }
    QSize eqSize() const { return eqSize_; }
    void setEqSize(const QSize& s) { eqSize_ = s; }
    QPoint playlistPos() const { return playlistPos_; }
    void setPlaylistPos(const QPoint& p) { playlistPos_ = p; }
    QSize playlistSize() const { return playlistSize_; }
    void setPlaylistSize(const QSize& s) { playlistSize_ = s; }
    int playlistSplitPos() const { return playlistSplitPos_; }
    void setPlaylistSplitPos(int p) { playlistSplitPos_ = p; }

    // 窗口可见性
    bool lyricVisible() const { return lyricVisible_; }
    void setLyricVisible(bool v) { lyricVisible_ = v; }
    bool eqVisible() const { return eqVisible_; }
    void setEqVisible(bool v) { eqVisible_ = v; }
    bool playlistVisible() const { return playlistVisible_; }
    void setPlaylistVisible(bool v) { playlistVisible_ = v; }
    bool alwaysOnTop() const { return alwaysOnTop_; }
    void setAlwaysOnTop(bool v) { alwaysOnTop_ = v; }

    // 皮肤设置
    QString skinPath() const { return skinPath_; }
    void setSkinPath(const QString& p) { skinPath_ = p; }

    // 播放模式
    int repeatMode() const { return repeatMode_; }
    void setRepeatMode(int m) { repeatMode_ = m; }
    bool shuffle() const { return shuffle_; }
    void setShuffle(bool s) { shuffle_ = s; }

    // 最后播放的文件
    QString lastFile() const { return lastFile_; }
    void setLastFile(const QString& f) { lastFile_ = f; }

    // 播放列表目录（空字符串代表使用默认路径：可执行文件目录下的 PlayList/）。
    QString playlistDir() const { return playlistDir_; }
    void setPlaylistDir(const QString& d) { playlistDir_ = d; }

    // 播放列表数量（标签页数）。
    int playlistCount() const { return playlistCount_; }
    void setPlaylistCount(int c) { playlistCount_ = qMax(1, c); }

    // 当前活跃播放列表索引。
    int activeList() const { return activeList_; }
    void setActiveList(int a) { activeList_ = qMax(0, a); }

    // 获取默认配置文件路径：可执行文件所在目录下的 TTPlayer.xml。
    static QString defaultPath();
    // 历史配置文件路径（旧版本写入位置），用于启动时兼容迁移。
    static QString legacyPath();

private:
    int volume_ = 80;
    bool muted_ = false;
    int balance_ = 0;

    bool eqEnabled_ = false;
    float eqPreamp_ = 0.0f;
    float eqBands_[10] = {};

    QPoint playerPos_{100, 100};
    QSize playerSize_{318, 188};
    QPoint lyricPos_{100, 400};
    QSize lyricSize_{290, 116};
    QPoint eqPos_{400, 100};
    QSize eqSize_{290, 148};
    QPoint playlistPos_{400, 400};
    QSize playlistSize_{290, 116};
    int playlistSplitPos_ = 55;

    bool lyricVisible_ = true;
    bool eqVisible_ = true;
    bool playlistVisible_ = true;
    bool alwaysOnTop_ = false;

    QString skinPath_;
    int repeatMode_ = 2;
    bool shuffle_ = false;
    QString lastFile_;
    QString playlistDir_;   // 播放列表目录，空则用默认路径。
    int playlistCount_ = 1;
    int activeList_ = 0;
};
