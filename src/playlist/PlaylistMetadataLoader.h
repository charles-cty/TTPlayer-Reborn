#pragma once
#include <QObject>
#include <QThread>
#include <QMutex>
#include <QWaitCondition>
#include <QSet>
#include <QHash>
#include <QVector>
#include <QString>
#include <deque>
#include <atomic>

// 后台元数据加载器。
//
// 用法：
//   1. 构造后调用 startLoading(paths) 启动后台加载线程。
//   2. 监听 metadataReady 信号更新 PlaylistEntry。
//   3. 如需立即获取某首曲目元数据（例如即将播放），调用 requestPriorityForPath(path)。
//   4. 析构时自动停止线程（最多等待 2 秒）。
//
// 线程安全说明：
//   - paths_ 在 startLoading() 调用后只读，两个线程均可安全访问。
//   - pendingQueue_/doneSet_/cache_ 均由 mutex_ 保护。
//   - metadataReady 信号通过 Qt 队列连接传递到主线程，不会有数据竞争。
class PlaylistMetadataLoader : public QObject {
    Q_OBJECT
public:
    explicit PlaylistMetadataLoader(QObject* parent = nullptr);
    ~PlaylistMetadataLoader() override;

    // 从主线程调用：设置待加载路径并启动工作线程。
    // 每个 PlaylistMetadataLoader 实例只能调用一次。
    void startLoading(QVector<QString> paths);

    // 从主线程调用：请求优先加载指定索引。
    // - 若该索引已加载完毕 → 立即（同步）重新发出 metadataReady 信号。
    // - 若未加载         → 将该索引移到队列头部并唤醒工作线程。
    void requestPriority(int index);

    // 从主线程调用：按文件路径请求优先加载。
    // 适用于播放列表重排后的场景，避免 UI 侧沿用过时的行号。
    void requestPriorityForPath(const QString& filePath);

    // 从主线程调用：取消所有待处理工作（不等待线程结束）。
    void cancel();

    // 是否已完成全部加载（线程安全）。
    bool isFinished() const { return finishedFlag_.load(std::memory_order_relaxed); }

signals:
    // 每完成一首曲目的元数据加载时发出（队列连接，投递到主线程）。
    // 同时携带原始路径，供 UI 在重排后按路径重新定位条目。
    void metadataReady(int index, QString filePath, QString title, QString artist, QString album, qint64 durationMs);
    // 所有曲目元数据就绪时发出（队列连接，投递到主线程）。
    void allMetadataLoaded(int loadedCount, qint64 elapsedMs);

private slots:
    // 在工作线程中执行的入口槽。
    void doWork();

private:
    struct CachedMeta {
        QString title;
        QString artist;
        QString album;
        qint64  durationMs = 0;
    };

    QThread*              workerThread_;
    QVector<QString>      paths_;        // 启动后只读，线程安全
    mutable QMutex        mutex_;
    QWaitCondition        cond_;
    std::deque<int>       pendingQueue_; // 队列头优先级最高
    QSet<int>             doneSet_;      // 已处理的索引
    QHash<int, CachedMeta> cache_;       // 已加载元数据的缓存

    std::atomic<bool>     stopFlag_{false};
    std::atomic<bool>     finishedFlag_{false};
};
