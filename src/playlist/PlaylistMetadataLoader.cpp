#include "PlaylistMetadataLoader.h"
#include "audio/Metadata.h"
#include <QElapsedTimer>
#include <QDebug>

PlaylistMetadataLoader::PlaylistMetadataLoader(QObject* parent)
    : QObject(parent)
    , workerThread_(new QThread(this))
{
    // 注意：PlaylistMetadataLoader 本身留在主线程（不调用 moveToThread）。
    // doWork 槽通过 Qt::DirectConnection 在工作线程上下文中直接调用，
    // 避免了将 QObject 移动到子线程的复杂性。
    // 从 doWork 发出的信号会自动以队列连接方式投递到接收者所在线程。
    connect(workerThread_, &QThread::started,
            this, &PlaylistMetadataLoader::doWork,
            Qt::DirectConnection);
}

PlaylistMetadataLoader::~PlaylistMetadataLoader() {
    cancel();
    workerThread_->quit();
    if (!workerThread_->wait(2000)) {
        workerThread_->terminate();
        workerThread_->wait(500);
    }
}

void PlaylistMetadataLoader::startLoading(QVector<QString> paths) {
    paths_ = std::move(paths);

    // 构建初始队列（按顺序 0, 1, 2, ...）。
    {
        QMutexLocker lk(&mutex_);
        pendingQueue_.clear();
        doneSet_.clear();
        cache_.clear();
        for (int i = 0; i < paths_.size(); ++i)
            pendingQueue_.push_back(i);
    }

    workerThread_->start(QThread::LowPriority);
}

void PlaylistMetadataLoader::requestPriority(int index) {
    if (index < 0 || index >= paths_.size())
        return;

    QMutexLocker lk(&mutex_);

    if (doneSet_.contains(index)) {
        // 已加载完毕 → 从缓存中同步重新发射信号。
        const CachedMeta& m = cache_[index];
        const QString filePath = paths_.value(index);
        lk.unlock();
        // 此处在主线程直接 emit（Qt 队列连接会将信号投递到接收者所在线程）。
        emit metadataReady(index, filePath, m.title, m.artist, m.album, m.durationMs);
        return;
    }

    // 将该索引移到队列最前面。
    auto it = std::find(pendingQueue_.begin(), pendingQueue_.end(), index);
    if (it != pendingQueue_.end())
        pendingQueue_.erase(it);
    pendingQueue_.push_front(index);
    cond_.wakeOne();
}

void PlaylistMetadataLoader::requestPriorityForPath(const QString& filePath) {
    const int index = paths_.indexOf(filePath);
    if (index >= 0) {
        requestPriority(index);
    }
}

void PlaylistMetadataLoader::cancel() {
    stopFlag_.store(true, std::memory_order_release);
    cond_.wakeAll();
}

// 在工作线程中运行。
void PlaylistMetadataLoader::doWork() {
    QElapsedTimer timer;
    timer.start();
    int loadedCount = 0;
    const int totalCount = paths_.size();

    // 外层以「已加载数量」作为结束条件，确保全部处理完毕后能正常退出。
    while (loadedCount < totalCount) {
        if (stopFlag_.load(std::memory_order_acquire))
            break;

        int idx = -1;
        {
            QMutexLocker lk(&mutex_);
            // 等待队列有任务或收到停止信号
            while (pendingQueue_.empty() && !stopFlag_.load(std::memory_order_relaxed)) {
                cond_.wait(&mutex_);
            }
            if (stopFlag_.load(std::memory_order_relaxed))
                break;
            idx = pendingQueue_.front();
            pendingQueue_.pop_front();
        }

        if (idx < 0 || idx >= paths_.size())
            continue;

        const QString& path = paths_[idx];
        QString title, artist, album;
        qint64 durationMs = 0;

        AudioFileMetadata meta;
        if (readAudioFileMetadata(path.toUtf8().constData(), meta)) {
            title  = QString::fromUtf8(meta.title.c_str()).trimmed();
            artist = QString::fromUtf8(meta.artist.c_str()).trimmed();
            album  = QString::fromUtf8(meta.album.c_str()).trimmed();
            durationMs = meta.duration_ms;
        }

        // 存入缓存并标记完成。
        {
            QMutexLocker lk(&mutex_);
            doneSet_.insert(idx);
            cache_[idx] = {title, artist, album, durationMs};
        }

        ++loadedCount;
        // 通过队列连接投递到主线程。
        emit metadataReady(idx, path, title, artist, album, durationMs);
    }

    if (!stopFlag_.load(std::memory_order_relaxed)) {
        // 正常完成（非取消）
        finishedFlag_.store(true, std::memory_order_release);
        emit allMetadataLoaded(loadedCount, timer.elapsed());
    }
}
