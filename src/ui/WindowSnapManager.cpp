#include "WindowSnapManager.h"
#include <QGuiApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QPaintEvent>
#include <QPainter>
#include <QRect>
#include <QScreen>
#include <QSet>
#include <QWidget>
#include <QWindow>
#include <climits>

namespace {

constexpr int kMovePerfSampleInterval = 20;

class SnapDebugOverlay : public QWidget {
public:
    SnapDebugOverlay() {
        setAttribute(Qt::WA_TransparentForMouseEvents);
        setAttribute(Qt::WA_NoSystemBackground);
        setAttribute(Qt::WA_TranslucentBackground);
        setWindowFlag(Qt::FramelessWindowHint);
        setWindowFlag(Qt::WindowStaysOnTopHint);
        setWindowFlag(Qt::ToolTip);
        setWindowFlag(Qt::WindowDoesNotAcceptFocus);
        updateBounds();
        show();
    }

    void setPoints(const QPoint& original, const QPoint& visibleFrame, const QPoint& target, bool visible) {
        originalPoint_ = original;
        visibleFramePoint_ = visibleFrame;
        targetPoint_ = target;
        visible_ = visible;
        updateBounds();
        update();
    }

protected:
    void paintEvent(QPaintEvent*) override {
        if (!visible_) {
            return;
        }

        QPainter painter(this);
        painter.setRenderHint(QPainter::Antialiasing, true);

        const QPoint original = originalPoint_ - geometry().topLeft();
        const QPoint visibleFrame = visibleFramePoint_ - geometry().topLeft();
        const QPoint target = targetPoint_ - geometry().topLeft();
        const int radius = 5;

        painter.setPen(Qt::NoPen);
        painter.setBrush(QColor(0, 200, 0, 192));
        painter.drawEllipse(original, radius, radius);

        painter.setBrush(QColor(0, 128, 255, 192));
        painter.drawEllipse(visibleFrame, radius, radius);

        painter.setBrush(QColor(200, 0, 0, 192));
        painter.drawEllipse(target, radius, radius);
    }

private:
    void updateBounds() {
        QRect bounds;
        for (QScreen* screen : QGuiApplication::screens()) {
            bounds = bounds.united(screen->geometry());
        }
        setGeometry(bounds);
    }

    QPoint originalPoint_;
    QPoint visibleFramePoint_;
    QPoint targetPoint_;
    bool visible_ = false;
};

} // namespace

WindowSnapManager::WindowSnapManager(QObject* parent)
    : QObject(parent) {}

QString WindowSnapManager::widgetDebugName(QWidget* widget) const {
    if (!widget) {
        return QStringLiteral("null");
    }
    if (widget == mainWindow_) {
        return QStringLiteral("PlayerWindow");
    }
    return QString::fromLatin1(widget->metaObject()->className());
}

void WindowSnapManager::beginMovePerfSession(QWidget* leader) {
    movePerf_.clear();
    movePerf_.active = true;
    movePerf_.leaderName = widgetDebugName(leader);
    movePerf_.timer.start();

    qDebug().noquote()
        << QStringLiteral("[MovePerf][WindowSnapManager] drag_begin leader=\"%1\" group_size=%2 snap_threshold=%3 live_attach=%4")
               .arg(movePerf_.leaderName)
               .arg(dragSession_.moveGroup.size())
               .arg(snapThreshold_)
               .arg(liveAttachOnMainDragEnabled_ ? 1 : 0);
}

void WindowSnapManager::logMovePerfSummary(const QString& reason) {
    if (!movePerf_.active) {
        return;
    }

    const qint64 sessionMs = movePerf_.timer.isValid() ? movePerf_.timer.elapsed() : 0;
    qDebug().noquote()
        << QStringLiteral("[MovePerf][WindowSnapManager] drag_end leader=\"%1\" reason=\"%2\" session=%3ms main_moves=%4 avg_main=%5ms max_main=%6ms move_group_avg=%7ms move_group_max=%8ms move_group_windows=%9 live_snap_avg=%10ms live_snap_max=%11ms live_snap_applied=%12 connected_avg=%13ms connected_max=%14ms connected_windows=%15 sub_moves=%16 avg_sub=%17ms max_sub=%18ms sub_snap_avg=%19ms sub_snap_max=%20ms sub_snap_applied=%21 finish_avg=%22ms finish_max=%23ms finish_snap_avg=%24ms finish_snap_max=%25ms finish_snap_applied=%26 rebuild_avg=%27ms rebuild_max=%28ms")
               .arg(movePerf_.leaderName)
               .arg(reason)
               .arg(sessionMs)
               .arg(movePerf_.mainMoveTotal.count)
               .arg(QString::number(movePerf_.mainMoveTotal.averageMs(), 'f', 2))
               .arg(movePerf_.mainMoveTotal.maxMs)
               .arg(QString::number(movePerf_.moveGroup.averageMs(), 'f', 2))
               .arg(movePerf_.moveGroup.maxMs)
               .arg(movePerf_.moveGroup.totalMovedWindows)
               .arg(QString::number(movePerf_.liveSnap.averageMs(), 'f', 2))
               .arg(movePerf_.liveSnap.maxMs)
               .arg(movePerf_.liveSnap.appliedCount)
               .arg(QString::number(movePerf_.connectedMove.averageMs(), 'f', 2))
               .arg(movePerf_.connectedMove.maxMs)
               .arg(movePerf_.connectedMove.totalMovedWindows)
               .arg(movePerf_.subMoveTotal.count)
               .arg(QString::number(movePerf_.subMoveTotal.averageMs(), 'f', 2))
               .arg(movePerf_.subMoveTotal.maxMs)
               .arg(QString::number(movePerf_.subSnap.averageMs(), 'f', 2))
               .arg(movePerf_.subSnap.maxMs)
               .arg(movePerf_.subSnap.appliedCount)
               .arg(QString::number(movePerf_.finishTotal.averageMs(), 'f', 2))
               .arg(movePerf_.finishTotal.maxMs)
               .arg(QString::number(movePerf_.finishSnap.averageMs(), 'f', 2))
               .arg(movePerf_.finishSnap.maxMs)
               .arg(movePerf_.finishSnap.appliedCount)
               .arg(QString::number(movePerf_.rebuildGraph.averageMs(), 'f', 2))
               .arg(movePerf_.rebuildGraph.maxMs);

    movePerf_.clear();
}

void WindowSnapManager::ensureDebugOverlay() {
    if (!debugOverlay_) {
        debugOverlay_ = new SnapDebugOverlay();
        debugOverlay_->setVisible(false);
    }
}

void WindowSnapManager::updateDebugOverlay() {
    if (!debugOverlay_) {
        return;
    }
    auto* overlay = static_cast<SnapDebugOverlay*>(debugOverlay_);
    overlay->setPoints(debugOriginalPoint_, debugVisibleFramePoint_, debugTargetPoint_, debugPointsVisible_);
    overlay->setVisible(debugPointsVisible_);
}

void WindowSnapManager::clearDebugOverlay() {
    debugPointsVisible_ = false;
    updateDebugOverlay();
}

// 设置主窗口并重建当前窗口吸附关系图。
void WindowSnapManager::setMainWindow(QWidget* main) {
    mainWindow_ = main;
    rebuildSnapGraph();
}

void WindowSnapManager::addSubWindow(QWidget* sub) {
    if (!sub) {
        return;
    }

    SubEntry entry;
    entry.widget = sub;
    subs_.append(entry);
}

// 主窗口移动时同步移动与主窗口相连的所有吸附子窗口。
void WindowSnapManager::onMainMoved(QPoint delta) {
    if (syncing_ || !mainWindow_ || delta.isNull()) {
        return;
    }

    if (dragSession_.active() && dragSession_.leader == mainWindow_) {
        QElapsedTimer totalTimer;
        totalTimer.start();
        const QPoint totalDelta = mainWindow_->pos() - dragSession_.leaderStartPos;
        QElapsedTimer phaseTimer;
        phaseTimer.start();
        const int movedWindows = moveDragGroup(totalDelta);
        const qint64 moveGroupMs = phaseTimer.elapsed();

        phaseTimer.restart();
        const QPoint liveSnapShift = finalSnapGroupToStaticWindows();
        const qint64 liveSnapMs = phaseTimer.elapsed();
        const qint64 totalMs = totalTimer.elapsed();

        if (movePerf_.active) {
            movePerf_.mainMoveTotal.add(totalMs);
            movePerf_.moveGroup.add(moveGroupMs, movedWindows);
            movePerf_.liveSnap.add(liveSnapMs, 0, !liveSnapShift.isNull());

            const bool shouldLog =
                totalMs >= 8 ||
                movePerf_.mainMoveTotal.count == 1 ||
                (movePerf_.mainMoveTotal.count % kMovePerfSampleInterval) == 0;
            if (shouldLog) {
                qDebug().noquote()
                    << QStringLiteral("[MovePerf][WindowSnapManager] main_move #%1 leader=\"%2\" delta=(%3,%4) total=%5ms move_group=%6ms moved_windows=%7 live_snap=%8ms live_snap_shift=(%9,%10)")
                           .arg(movePerf_.mainMoveTotal.count)
                           .arg(movePerf_.leaderName)
                           .arg(delta.x())
                           .arg(delta.y())
                           .arg(totalMs)
                           .arg(moveGroupMs)
                           .arg(movedWindows)
                           .arg(liveSnapMs)
                           .arg(liveSnapShift.x())
                           .arg(liveSnapShift.y());
            }
        }
        return;
    }

    QElapsedTimer timer;
    timer.start();
    const int movedWindows = moveConnectedSubWindows(delta);
    const qint64 totalMs = timer.elapsed();

    if (movePerf_.active) {
        movePerf_.connectedMove.add(totalMs, movedWindows);
        const bool shouldLog =
            totalMs >= 8 ||
            movePerf_.connectedMove.count == 1 ||
            (movePerf_.connectedMove.count % kMovePerfSampleInterval) == 0;
        if (shouldLog) {
            qDebug().noquote()
                << QStringLiteral("[MovePerf][WindowSnapManager] connected_move #%1 leader=\"%2\" delta=(%3,%4) total=%5ms moved_windows=%6")
                       .arg(movePerf_.connectedMove.count)
                       .arg(movePerf_.leaderName)
                       .arg(delta.x())
                       .arg(delta.y())
                       .arg(totalMs)
                       .arg(movedWindows);
        }
    }
}

// 子窗口移动后触发，处理拖动会话结束后的最终吸附。
void WindowSnapManager::onSubMoved(QWidget* sub, QPoint /*delta*/) {
    if (syncing_ || !mainWindow_ || !sub) {
        return;
    }

    if (dragSession_.active() && dragSession_.leader == sub) {
        QElapsedTimer totalTimer;
        totalTimer.start();
        QElapsedTimer phaseTimer;
        phaseTimer.start();
        const QPoint snapShift = finalSnapDraggedSub();
        const qint64 snapMs = phaseTimer.elapsed();
        const qint64 totalMs = totalTimer.elapsed();

        if (movePerf_.active) {
            movePerf_.subMoveTotal.add(totalMs);
            movePerf_.subSnap.add(snapMs, 0, !snapShift.isNull());

            const bool shouldLog =
                totalMs >= 8 ||
                movePerf_.subMoveTotal.count == 1 ||
                (movePerf_.subMoveTotal.count % kMovePerfSampleInterval) == 0;
            if (shouldLog) {
                qDebug().noquote()
                    << QStringLiteral("[MovePerf][WindowSnapManager] sub_move #%1 leader=\"%2\" window=\"%3\" total=%4ms final_snap=%5ms snap_shift=(%6,%7)")
                           .arg(movePerf_.subMoveTotal.count)
                           .arg(movePerf_.leaderName)
                           .arg(widgetDebugName(sub))
                           .arg(totalMs)
                           .arg(snapMs)
                           .arg(snapShift.x())
                           .arg(snapShift.y());
            }
        }
    }
}

void WindowSnapManager::onDragStarted(QWidget* leader) {
    beginDragSession(leader);
    clearDebugOverlay();
}

void WindowSnapManager::onDragFinished(QWidget* leader) {
    finishDragSession(leader);
    clearDebugOverlay();
}

// 重新计算所有窗口之间的吸附关系，并更新连接树。
void WindowSnapManager::rebuildSnapGraph() {
    if (!mainWindow_) {
        return;
    }

    clearAllAnchors();

    bool changed = true;
    while (changed) {
        changed = false;
        for (int i = 0; i < subs_.size(); ++i) {
            if (!subs_[i].widget || !subs_[i].widget->isVisible() || isSnapped(i)) {
                continue;
            }
            if (trySnap(i)) {
                changed = true;
            }
        }
    }

    rebuildChildren();
    refreshOffsets();
}

int WindowSnapManager::findSubIndex(QWidget* widget) const {
    for (int i = 0; i < subs_.size(); ++i) {
        if (subs_[i].widget == widget) {
            return i;
        }
    }
    return NoAnchor;
}

QWidget* WindowSnapManager::anchorWidget(int subIndex) const {
    if (!mainWindow_ || subIndex < 0 || subIndex >= subs_.size()) {
        return nullptr;
    }

    const int anchor = subs_[subIndex].anchor;
    if (anchor == MainAnchor) {
        return mainWindow_;
    }
    if (anchor >= 0 && anchor < subs_.size()) {
        return subs_[anchor].widget;
    }
    return nullptr;
}

bool WindowSnapManager::isSnapped(int subIndex) const {
    return subIndex >= 0 &&
           subIndex < subs_.size() &&
           subs_[subIndex].anchor != NoAnchor;
}

// 判断指定子窗口是否直接或间接连接到主窗口。
bool WindowSnapManager::isConnectedToMain(int subIndex) const {
    if (!mainWindow_ || !isSnapped(subIndex)) {
        return false;
    }

    QSet<int> visited;
    int cursor = subIndex;
    while (cursor >= 0 && cursor < subs_.size()) {
        if (visited.contains(cursor)) {
            return false;
        }
        visited.insert(cursor);

        const int anchor = subs_[cursor].anchor;
        if (anchor == MainAnchor) {
            return true;
        }
        if (anchor < 0 || anchor >= subs_.size()) {
            return false;
        }
        cursor = anchor;
    }

    return false;
}

bool WindowSnapManager::wouldCreateCycle(int movingIndex, int anchorIndex) const {
    if (movingIndex < 0 || movingIndex >= subs_.size()) {
        return true;
    }
    if (anchorIndex == MainAnchor) {
        return false;
    }
    if (anchorIndex < 0 || anchorIndex >= subs_.size()) {
        return true;
    }

    QSet<int> visited;
    int cursor = anchorIndex;
    while (cursor >= 0 && cursor < subs_.size()) {
        if (cursor == movingIndex || visited.contains(cursor)) {
            return true;
        }
        visited.insert(cursor);

        const int next = subs_[cursor].anchor;
        if (next == MainAnchor || next == NoAnchor) {
            return false;
        }
        cursor = next;
    }

    return false;
}

QRect WindowSnapManager::connectedGroupRectExcluding(int excludeIndex) const {
    if (!mainWindow_ || !mainWindow_->isVisible()) {
        return {};
    }

    QRect groupRect(mainWindow_->pos(), mainWindow_->size());
    bool hasAny = true;

    for (int i = 0; i < subs_.size(); ++i) {
        if (i == excludeIndex || !subs_[i].widget || !subs_[i].widget->isVisible()) {
            continue;
        }
        if (!isConnectedToMain(i)) {
            continue;
        }
        groupRect = groupRect.united(QRect(subs_[i].widget->pos(), subs_[i].widget->size()));
        hasAny = true;
    }

    return hasAny ? groupRect : QRect();
}

bool WindowSnapManager::trySnapToAnchor(const QRect& movingRect,
                                        const QRect& anchorRect,
                                        QPoint& outSnapPos,
                                        int& outDistance) const {
    const int threshold = snapThreshold_;
    const QPoint movingTopLeft = movingRect.topLeft();
    bool found = false;

    const bool overlapsHorizontally = movingRect.right() >= anchorRect.left() - threshold &&
                                      movingRect.left() <= anchorRect.right() + threshold;
    const bool overlapsVertically = movingRect.bottom() >= anchorRect.top() - threshold &&
                                    movingRect.top() <= anchorRect.bottom() + threshold;
    const bool overlapsArea = movingRect.intersects(anchorRect) ||
                              movingRect.contains(anchorRect) ||
                              anchorRect.contains(movingRect);

    auto consider = [&](QPoint candidatePos) {
        if (qAbs(candidatePos.x() - anchorRect.left()) <= threshold) {
            candidatePos.setX(anchorRect.left());
        }
        if (qAbs(candidatePos.y() - anchorRect.top()) <= threshold) {
            candidatePos.setY(anchorRect.top());
        }

        const int dist = (candidatePos - movingTopLeft).manhattanLength();
        if (!found || dist < outDistance) {
            outDistance = dist;
            outSnapPos = candidatePos;
            found = true;
        }
    };

    if (overlapsHorizontally &&
        qAbs(movingRect.top() - (anchorRect.bottom() + 1)) <= threshold) {
        consider(QPoint(movingRect.left(), anchorRect.bottom() + 1));
    }
    if (overlapsHorizontally &&
        qAbs(movingRect.bottom() + 1 - anchorRect.top()) <= threshold) {
        consider(QPoint(movingRect.left(), anchorRect.top() - movingRect.height()));
    }
    if (overlapsVertically &&
        qAbs(movingRect.left() - (anchorRect.right() + 1)) <= threshold) {
        consider(QPoint(anchorRect.right() + 1, movingRect.top()));
    }
    if (overlapsVertically &&
        qAbs(movingRect.right() + 1 - anchorRect.left()) <= threshold) {
        consider(QPoint(anchorRect.left() - movingRect.width(), movingRect.top()));
    }

    // 一些皮肤会让歌词/播放列表/均衡器窗口与主窗口重叠或共享同一角点。
    // 原版还允许“同侧边对齐”的重叠布局，例如 LX-iPlay 的主窗口/歌词/播放列表：
    // 它们共享 left/right 边，但 y 区间明显重叠，并不是传统的上下左右贴边。
    // 如果这里只识别四个角重合，就会把这类原生布局拆散。
    if (overlapsArea) {
        if (qAbs(movingRect.left() - anchorRect.left()) <= threshold) {
            consider(QPoint(anchorRect.left(), movingRect.top()));
        }
        if (qAbs(movingRect.right() - anchorRect.right()) <= threshold) {
            consider(QPoint(anchorRect.right() - movingRect.width() + 1, movingRect.top()));
        }
        if (qAbs(movingRect.top() - anchorRect.top()) <= threshold) {
            consider(QPoint(movingRect.left(), anchorRect.top()));
        }
        if (qAbs(movingRect.bottom() - anchorRect.bottom()) <= threshold) {
            consider(QPoint(movingRect.left(), anchorRect.bottom() - movingRect.height() + 1));
        }

        if (qAbs(movingRect.left() - anchorRect.left()) <= threshold &&
            qAbs(movingRect.top() - anchorRect.top()) <= threshold) {
            consider(QPoint(anchorRect.left(), anchorRect.top()));
        }
        if (qAbs(movingRect.right() - anchorRect.right()) <= threshold &&
            qAbs(movingRect.top() - anchorRect.top()) <= threshold) {
            consider(QPoint(anchorRect.right() - movingRect.width() + 1, anchorRect.top()));
        }
        if (qAbs(movingRect.left() - anchorRect.left()) <= threshold &&
            qAbs(movingRect.bottom() - anchorRect.bottom()) <= threshold) {
            consider(QPoint(anchorRect.left(), anchorRect.bottom() - movingRect.height() + 1));
        }
        if (qAbs(movingRect.right() - anchorRect.right()) <= threshold &&
            qAbs(movingRect.bottom() - anchorRect.bottom()) <= threshold) {
            consider(QPoint(anchorRect.right() - movingRect.width() + 1,
                            anchorRect.bottom() - movingRect.height() + 1));
        }
    }

    return found;
}

QRect WindowSnapManager::screenGeometryForRect(const QRect& rect) const {
    if (!rect.isValid()) {
        return {};
    }

    QScreen* screen = QGuiApplication::screenAt(rect.center());
    if (!screen && mainWindow_ && mainWindow_->windowHandle()) {
        screen = mainWindow_->windowHandle()->screen();
    }
    if (!screen) {
        screen = QGuiApplication::primaryScreen();
    }
    if (!screen) {
        return {};
    }

    return screen->availableGeometry();
}

// ── 独立轴吸附：分别计算 X 和 Y 方向的最佳对齐 ──

bool WindowSnapManager::trySnapXAxis(const QRect& movingRect,
                                     const QRect& anchorRect,
                                     int& outNewX,
                                     int& outXDist) const {
    const int threshold = snapThreshold_;
    bool found = false;

    const bool overlapsVertically = movingRect.bottom() >= anchorRect.top() - threshold &&
                                    movingRect.top() <= anchorRect.bottom() + threshold;
    const bool overlapsArea = movingRect.intersects(anchorRect) ||
                              movingRect.contains(anchorRect) ||
                              anchorRect.contains(movingRect);

    auto consider = [&](int candidateX, int dist) {
        if (!found || dist < outXDist) {
            outXDist = dist;
            outNewX = candidateX;
            found = true;
        }
    };

    // 左边缘 → 锚点右边缘 + 1（左右相邻）
    if (overlapsVertically) {
        int dist = qAbs(movingRect.left() - (anchorRect.right() + 1));
        if (dist <= threshold) {
            consider(anchorRect.right() + 1, dist);
        }
    }

    // 右边缘 + 1 → 锚点左边缘（右左相邻）
    if (overlapsVertically) {
        int dist = qAbs(movingRect.right() + 1 - anchorRect.left());
        if (dist <= threshold) {
            consider(anchorRect.left() - movingRect.width(), dist);
        }
    }

    // 重叠区域内的同侧对齐
    if (overlapsArea || overlapsVertically) {
        {
            int dist = qAbs(movingRect.left() - anchorRect.left());
            if (dist <= threshold) {
                consider(anchorRect.left(), dist);
            }
        }
        {
            int dist = qAbs(movingRect.right() - anchorRect.right());
            if (dist <= threshold) {
                consider(anchorRect.right() - movingRect.width() + 1, dist);
            }
        }
    }

    return found;
}

bool WindowSnapManager::trySnapYAxis(const QRect& movingRect,
                                     const QRect& anchorRect,
                                     int& outNewY,
                                     int& outYDist) const {
    const int threshold = snapThreshold_;
    bool found = false;

    const bool overlapsHorizontally = movingRect.right() >= anchorRect.left() - threshold &&
                                      movingRect.left() <= anchorRect.right() + threshold;
    const bool overlapsArea = movingRect.intersects(anchorRect) ||
                              movingRect.contains(anchorRect) ||
                              anchorRect.contains(movingRect);

    auto consider = [&](int candidateY, int dist) {
        if (!found || dist < outYDist) {
            outYDist = dist;
            outNewY = candidateY;
            found = true;
        }
    };

    // 上边缘 → 锚点下边缘 + 1（上下相邻）
    if (overlapsHorizontally) {
        int dist = qAbs(movingRect.top() - (anchorRect.bottom() + 1));
        if (dist <= threshold) {
            consider(anchorRect.bottom() + 1, dist);
        }
    }

    // 下边缘 + 1 → 锚点上边缘（下上相邻）
    if (overlapsHorizontally) {
        int dist = qAbs(movingRect.bottom() + 1 - anchorRect.top());
        if (dist <= threshold) {
            consider(anchorRect.top() - movingRect.height(), dist);
        }
    }

    // 重叠区域内的同侧对齐
    if (overlapsArea || overlapsHorizontally) {
        {
            int dist = qAbs(movingRect.top() - anchorRect.top());
            if (dist <= threshold) {
                consider(anchorRect.top(), dist);
            }
        }
        {
            int dist = qAbs(movingRect.bottom() - anchorRect.bottom());
            if (dist <= threshold) {
                consider(anchorRect.bottom() - movingRect.height() + 1, dist);
            }
        }
    }

    return found;
}

bool WindowSnapManager::trySnapXAxisToScreen(const QRect& movingRect,
                                             int& outNewX,
                                             int& outXDist) const {
    const QRect screenRect = screenGeometryForRect(movingRect);
    if (!screenRect.isValid()) {
        return false;
    }

    const int threshold = snapThreshold_;
    bool found = false;

    auto consider = [&](int candidateX, int dist) {
        if (!found || dist < outXDist) {
            outXDist = dist;
            outNewX = candidateX;
            found = true;
        }
    };

    {
        int dist = qAbs(movingRect.left() - screenRect.left());
        if (dist <= threshold) {
            consider(screenRect.left(), dist);
        }
    }
    {
        int dist = qAbs(movingRect.right() - screenRect.right());
        if (dist <= threshold) {
            consider(screenRect.right() - movingRect.width() + 1, dist);
        }
    }

    return found;
}

bool WindowSnapManager::trySnapYAxisToScreen(const QRect& movingRect,
                                             int& outNewY,
                                             int& outYDist) const {
    const QRect screenRect = screenGeometryForRect(movingRect);
    if (!screenRect.isValid()) {
        return false;
    }

    const int threshold = snapThreshold_;
    bool found = false;

    auto consider = [&](int candidateY, int dist) {
        if (!found || dist < outYDist) {
            outYDist = dist;
            outNewY = candidateY;
            found = true;
        }
    };

    {
        int dist = qAbs(movingRect.top() - screenRect.top());
        if (dist <= threshold) {
            consider(screenRect.top(), dist);
        }
    }
    {
        int dist = qAbs(movingRect.bottom() - screenRect.bottom());
        if (dist <= threshold) {
            consider(screenRect.bottom() - movingRect.height() + 1, dist);
        }
    }

    return found;
}

bool WindowSnapManager::trySnapToScreenEdges(const QRect& movingRect,
                                             QPoint& outSnapPos,
                                             int& outDistance) const {
    const QRect screenRect = screenGeometryForRect(movingRect);
    if (!screenRect.isValid()) {
        return false;
    }

    const int threshold = snapThreshold_;
    const QPoint movingTopLeft = movingRect.topLeft();
    bool found = false;

    auto consider = [&](QPoint candidatePos) {
        const int dist = (candidatePos - movingTopLeft).manhattanLength();
        if (!found || dist < outDistance) {
            outDistance = dist;
            outSnapPos = candidatePos;
            found = true;
        }
    };

    const bool nearLeft = qAbs(movingRect.left() - screenRect.left()) <= threshold;
    const bool nearRight = qAbs(movingRect.right() - screenRect.right()) <= threshold;
    const bool nearTop = qAbs(movingRect.top() - screenRect.top()) <= threshold;
    const bool nearBottom = qAbs(movingRect.bottom() - screenRect.bottom()) <= threshold;

    if (nearLeft) {
        consider(QPoint(screenRect.left(), movingRect.top()));
    }
    if (nearRight) {
        consider(QPoint(screenRect.right() - movingRect.width() + 1, movingRect.top()));
    }
    if (nearTop) {
        consider(QPoint(movingRect.left(), screenRect.top()));
    }
    if (nearBottom) {
        consider(QPoint(movingRect.left(), screenRect.bottom() - movingRect.height() + 1));
    }

    if (nearLeft && nearTop) {
        consider(QPoint(screenRect.left(), screenRect.top()));
    }
    if (nearRight && nearTop) {
        consider(QPoint(screenRect.right() - movingRect.width() + 1, screenRect.top()));
    }
    if (nearLeft && nearBottom) {
        consider(QPoint(screenRect.left(), screenRect.bottom() - movingRect.height() + 1));
    }
    if (nearRight && nearBottom) {
        consider(QPoint(screenRect.right() - movingRect.width() + 1,
                        screenRect.bottom() - movingRect.height() + 1));
    }

    return found;
}

bool WindowSnapManager::trySnapResizeToAnchor(const QRect& movingRect,
                                              Qt::Edges resizeEdges,
                                              const QRect& anchorRect,
                                              QRect& outSnapRect,
                                              int& outDistance) const {
    const int threshold = snapThreshold_;
    const bool overlapsHorizontally = movingRect.right() >= anchorRect.left() - threshold &&
                                      movingRect.left() <= anchorRect.right() + threshold;
    const bool overlapsVertically = movingRect.bottom() >= anchorRect.top() - threshold &&
                                    movingRect.top() <= anchorRect.bottom() + threshold;
    bool found = false;

    auto consider = [&](const QRect& candidateRect) {
        if (candidateRect.width() <= 0 || candidateRect.height() <= 0) {
            return;
        }

        int dist = 0;
        if (resizeEdges.testFlag(Qt::RightEdge)) {
            dist += qAbs(candidateRect.right() - movingRect.right());
        }
        if (resizeEdges.testFlag(Qt::BottomEdge)) {
            dist += qAbs(candidateRect.bottom() - movingRect.bottom());
        }

        if (!found || dist < outDistance) {
            outDistance = dist;
            outSnapRect = candidateRect;
            found = true;
        }
    };

    if (resizeEdges.testFlag(Qt::RightEdge) && overlapsVertically) {
        if (qAbs(movingRect.right() - anchorRect.right()) <= threshold) {
            QRect candidate = movingRect;
            candidate.setRight(anchorRect.right());
            consider(candidate);
        }
        if (qAbs(movingRect.right() + 1 - anchorRect.left()) <= threshold) {
            QRect candidate = movingRect;
            candidate.setRight(anchorRect.left() - 1);
            consider(candidate);
        }
    }

    if (resizeEdges.testFlag(Qt::BottomEdge) && overlapsHorizontally) {
        if (qAbs(movingRect.bottom() - anchorRect.bottom()) <= threshold) {
            QRect candidate = movingRect;
            candidate.setBottom(anchorRect.bottom());
            consider(candidate);
        }
        if (qAbs(movingRect.bottom() + 1 - anchorRect.top()) <= threshold) {
            QRect candidate = movingRect;
            candidate.setBottom(anchorRect.top() - 1);
            consider(candidate);
        }
    }

    return found;
}

bool WindowSnapManager::trySnapResizeToScreenEdges(const QRect& movingRect,
                                                   Qt::Edges resizeEdges,
                                                   QRect& outSnapRect,
                                                   int& outDistance) const {
    const QRect screenRect = screenGeometryForRect(movingRect);
    if (!screenRect.isValid()) {
        return false;
    }

    const int threshold = snapThreshold_;
    bool found = false;

    auto consider = [&](const QRect& candidateRect) {
        if (candidateRect.width() <= 0 || candidateRect.height() <= 0) {
            return;
        }

        int dist = 0;
        if (resizeEdges.testFlag(Qt::RightEdge)) {
            dist += qAbs(candidateRect.right() - movingRect.right());
        }
        if (resizeEdges.testFlag(Qt::BottomEdge)) {
            dist += qAbs(candidateRect.bottom() - movingRect.bottom());
        }

        if (!found || dist < outDistance) {
            outDistance = dist;
            outSnapRect = candidateRect;
            found = true;
        }
    };

    if (resizeEdges.testFlag(Qt::RightEdge) &&
        qAbs(movingRect.right() - screenRect.right()) <= threshold) {
        QRect candidate = movingRect;
        candidate.setRight(screenRect.right());
        consider(candidate);
    }

    if (resizeEdges.testFlag(Qt::BottomEdge) &&
        qAbs(movingRect.bottom() - screenRect.bottom()) <= threshold) {
        QRect candidate = movingRect;
        candidate.setBottom(screenRect.bottom());
        consider(candidate);
    }

    return found;
}

void WindowSnapManager::rebuildChildren() {
    for (auto& entry : subs_) {
        entry.children.clear();
    }

    for (int i = 0; i < subs_.size(); ++i) {
        const int anchor = subs_[i].anchor;
        if (anchor >= 0 && anchor < subs_.size()) {
            subs_[anchor].children.append(i);
        }
    }
}

void WindowSnapManager::clearAllAnchors() {
    for (auto& entry : subs_) {
        entry.anchor = NoAnchor;
        entry.snapOffset = {};
        entry.children.clear();
    }
}

void WindowSnapManager::beginDragSession(QWidget* leader) {
    if (!mainWindow_ || syncing_ || !leader) {
        return;
    }

    rebuildChildren();
    dragSession_.clear();
    dragSession_.leader = leader;

    if (leader == mainWindow_) {
        dragSession_.leaderIndex = MainAnchor;
        dragSession_.leaderStartPos = mainWindow_->pos();
        for (int i = 0; i < subs_.size(); ++i) {
            if (!subs_[i].widget || !subs_[i].widget->isVisible() || !isConnectedToMain(i)) {
                continue;
            }
            dragSession_.moveGroup.append(i);
            dragSession_.moveGroupStartPos.append(subs_[i].widget->pos());
        }
        beginMovePerfSession(leader);
        return;
    }

    // 参考原版：仅主窗口拖动会联动窗口组。
    // 子窗口拖动仅影响自身位置与后续吸附关系，不带动其他窗口。
    const int leaderIndex = findSubIndex(leader);
    if (leaderIndex == NoAnchor) {
        dragSession_.clear();
        return;
    }
    dragSession_.leaderIndex = leaderIndex;
    dragSession_.leaderStartPos = leader->pos();
    beginMovePerfSession(leader);
}

void WindowSnapManager::finishDragSession(QWidget* leader) {
    if (!dragSession_.active() || dragSession_.leader != leader) {
        return;
    }

    QElapsedTimer totalTimer;
    totalTimer.start();
    QElapsedTimer phaseTimer;
    phaseTimer.start();

    // 在清除拖动会话前，按方向执行最终吸附：
    // 永远是"被拖动的对象"移动去贴"静止的对象"。
    QPoint finalSnapShift;
    if (dragSession_.leader == mainWindow_) {
        finalSnapShift = finalSnapGroupToStaticWindows();
    } else {
        finalSnapShift = finalSnapDraggedSub();
    }
    const qint64 finishSnapMs = phaseTimer.elapsed();

    phaseTimer.restart();
    dragSession_.clear();
    // 仅重建吸附关系图，不移动任何窗口。
    rebuildSnapGraphInPlace();
    const qint64 rebuildGraphMs = phaseTimer.elapsed();
    const qint64 totalMs = totalTimer.elapsed();

    if (movePerf_.active) {
        movePerf_.finishTotal.add(totalMs);
        movePerf_.finishSnap.add(finishSnapMs, 0, !finalSnapShift.isNull());
        movePerf_.rebuildGraph.add(rebuildGraphMs);
        logMovePerfSummary(QStringLiteral("drag_finished"));
    }
}

int WindowSnapManager::moveDragGroup(const QPoint& totalDelta) {
    if (!dragSession_.active() || totalDelta.isNull()) {
        return 0;
    }

    int movedWindows = 0;
    syncing_ = true;
    for (int i = 0; i < dragSession_.moveGroup.size(); ++i) {
        const int subIndex = dragSession_.moveGroup[i];
        if (subIndex < 0 || subIndex >= subs_.size()) {
            continue;
        }
        auto& entry = subs_[subIndex];
        if (!entry.widget || !entry.widget->isVisible()) {
            continue;
        }
        const QPoint targetPos = dragSession_.moveGroupStartPos[i] + totalDelta;
        if (entry.widget->pos() == targetPos) {
            continue;
        }
        entry.widget->move(targetPos);
        ++movedWindows;
    }
    syncing_ = false;
    return movedWindows;
}

void WindowSnapManager::tryAttachUnsnappedWindowsToDragGroup(const QPoint& /*totalDelta*/) {
    // 实时吸附在当前架构下无法正确工作：PlayerWindow::mouseMoveEvent
    // 在下一帧用鼠标坐标直接覆盖窗口位置，导致此处的位移被撤销，
    // 同时新加入 moveGroup 的窗口基线位置会出错（数据腐败）。
    // 改为在 finishDragSession 中通过 finalSnapGroupToStaticWindows 统一处理。
}

// 尝试将一个子窗口吸附到主窗口或其他已连接窗口。
// 使用独立双轴吸附：X 和 Y 方向分别从所有锚点中选取最优，再合并。
bool WindowSnapManager::trySnap(int movingIndex, bool moveToSnap) {
    if (!mainWindow_ || movingIndex < 0 || movingIndex >= subs_.size()) {
        return false;
    }

    auto& entry = subs_[movingIndex];
    if (!entry.widget) {
        return false;
    }

    const QRect movingRect(entry.widget->pos(), entry.widget->size());

    // 独立轴追踪
    int bestXDist = INT_MAX, bestYDist = INT_MAX;
    int bestNewX = movingRect.left(), bestNewY = movingRect.top();
    int xAnchor = NoAnchor, yAnchor = NoAnchor;
    bool hasXSnap = false, hasYSnap = false;

    auto considerAnchorAxes = [&](int anchorIndex, const QRect& anchorRect) {
        int newX, xDist = INT_MAX;
        if (trySnapXAxis(movingRect, anchorRect, newX, xDist) && xDist < bestXDist) {
            bestXDist = xDist;
            bestNewX = newX;
            xAnchor = anchorIndex;
            hasXSnap = true;
        }

        int newY, yDist = INT_MAX;
        if (trySnapYAxis(movingRect, anchorRect, newY, yDist) && yDist < bestYDist) {
            bestYDist = yDist;
            bestNewY = newY;
            yAnchor = anchorIndex;
            hasYSnap = true;
        }
    };

    // 检查主窗口
    if (mainWindow_->isVisible()) {
        considerAnchorAxes(MainAnchor, QRect(mainWindow_->pos(), mainWindow_->size()));
    }

    // 检查已连接窗口组的外接矩形
    const QRect connectedGroupRect = connectedGroupRectExcluding(movingIndex);
    if (connectedGroupRect.isValid() &&
        connectedGroupRect != QRect(mainWindow_->pos(), mainWindow_->size())) {
        considerAnchorAxes(MainAnchor, connectedGroupRect);
    }

    // 检查其他已连接子窗口
    for (int i = 0; i < subs_.size(); ++i) {
        if (i == movingIndex || !isConnectedToMain(i) || wouldCreateCycle(movingIndex, i)) {
            continue;
        }
        if (!subs_[i].widget || !subs_[i].widget->isVisible()) {
            continue;
        }
        considerAnchorAxes(i, QRect(subs_[i].widget->pos(), subs_[i].widget->size()));
    }

    if (!hasXSnap && !hasYSnap) {
        if (dragSession_.active()) {
            clearDebugOverlay();
        }
        return false;
    }

    QPoint bestPos(hasXSnap ? bestNewX : movingRect.left(),
                   hasYSnap ? bestNewY : movingRect.top());

    // 确定主锚点（用于连接树）：选距离更小的轴对应的锚点
    int bestAnchor = NoAnchor;
    if (hasXSnap && hasYSnap) {
        bestAnchor = (bestXDist <= bestYDist) ? xAnchor : yAnchor;
    } else if (hasXSnap) {
        bestAnchor = xAnchor;
    } else {
        bestAnchor = yAnchor;
    }

    if (dragSession_.active()) {
        ensureDebugOverlay();
        debugOriginalPoint_ = movingRect.topLeft();
        debugVisibleFramePoint_ = entry.widget->frameGeometry().topLeft();
        debugTargetPoint_ = bestPos;
        debugPointsVisible_ = true;
        updateDebugOverlay();
    }

    if (moveToSnap) {
        syncing_ = true;
        entry.widget->move(bestPos);
        syncing_ = false;
    } else {
        // 不移动窗口：仅当窗口已处于吸附位置附近时建立关系
        if ((bestPos - entry.widget->pos()).manhattanLength() > 2) {
            return false;
        }
    }

    entry.anchor = bestAnchor;
    if (bestAnchor == MainAnchor) {
        entry.snapOffset = entry.widget->pos() - mainWindow_->pos();
    } else {
        entry.snapOffset = entry.widget->pos() - subs_[bestAnchor].widget->pos();
    }

    return true;
}

void WindowSnapManager::onSubResized(QWidget* sub, Qt::Edges edges) {
    if (syncing_ || !mainWindow_ || !sub || edges == Qt::Edges()) {
        return;
    }

    const int movingIndex = findSubIndex(sub);
    if (movingIndex == NoAnchor) {
        return;
    }

    const QRect movingRect(sub->pos(), sub->size());
    QRect bestRect = movingRect;
    int bestDistance = INT_MAX;

    auto considerRect = [&](const QRect& anchorRect) {
        if (!anchorRect.isValid()) {
            return;
        }
        QRect snappedRect;
        int distance = INT_MAX;
        if (!trySnapResizeToAnchor(movingRect, edges, anchorRect, snappedRect, distance)) {
            return;
        }
        if (distance < bestDistance) {
            bestDistance = distance;
            bestRect = snappedRect;
        }
    };

    considerRect(QRect(mainWindow_->pos(), mainWindow_->size()));

    const QRect connectedGroupRect = connectedGroupRectExcluding(movingIndex);
    if (connectedGroupRect.isValid()) {
        considerRect(connectedGroupRect);
    }

    for (int i = 0; i < subs_.size(); ++i) {
        if (i == movingIndex || !subs_[i].widget || !subs_[i].widget->isVisible()) {
            continue;
        }
        considerRect(QRect(subs_[i].widget->pos(), subs_[i].widget->size()));
    }

    {
        QRect snappedRect;
        int distance = INT_MAX;
        if (trySnapResizeToScreenEdges(movingRect, edges, snappedRect, distance) &&
            distance < bestDistance) {
            bestDistance = distance;
            bestRect = snappedRect;
        }
    }

    if (bestRect.size() == sub->size()) {
        return;
    }

    syncing_ = true;
    sub->resize(bestRect.size());
    syncing_ = false;
}

void WindowSnapManager::onSubResizeFinished(QWidget* sub, Qt::Edges edges) {
    onSubResized(sub, edges);
    rebuildSnapGraphInPlace();
}

// 执行主窗口拖动结束后的最终对齐，以吸附到静止窗口。
// 使用独立双轴吸附：X 和 Y 方向分别选取最优 shift 再合并。
QPoint WindowSnapManager::finalSnapGroupToStaticWindows() {
    if (!mainWindow_ || !dragSession_.active() || dragSession_.leader != mainWindow_) {
        return {};
    }

    int bestXShiftDist = INT_MAX, bestYShiftDist = INT_MAX;
    int bestXShift = 0, bestYShift = 0;
    bool hasXShift = false, hasYShift = false;

    // 辅助：对 movingRect 检查锚点的 X/Y 轴吸附，将结果转为 shift
    auto accumulateAxes = [&](const QRect& movingRect, const QRect& anchorRect) {
        int newX, xDist = INT_MAX;
        if (trySnapXAxis(movingRect, anchorRect, newX, xDist) && xDist < bestXShiftDist) {
            bestXShiftDist = xDist;
            bestXShift = newX - movingRect.left();
            hasXShift = true;
        }

        int newY, yDist = INT_MAX;
        if (trySnapYAxis(movingRect, anchorRect, newY, yDist) && yDist < bestYShiftDist) {
            bestYShiftDist = yDist;
            bestYShift = newY - movingRect.top();
            hasYShift = true;
        }
    };

    auto accumulateScreenAxes = [&](const QRect& movingRect) {
        int newX, xDist = INT_MAX;
        if (trySnapXAxisToScreen(movingRect, newX, xDist) && xDist < bestXShiftDist) {
            bestXShiftDist = xDist;
            bestXShift = newX - movingRect.left();
            hasXShift = true;
        }

        int newY, yDist = INT_MAX;
        if (trySnapYAxisToScreen(movingRect, newY, yDist) && yDist < bestYShiftDist) {
            bestYShiftDist = yDist;
            bestYShift = newY - movingRect.top();
            hasYShift = true;
        }
    };

    for (int i = 0; i < subs_.size(); ++i) {
        if (isSnapped(i) || !subs_[i].widget || !subs_[i].widget->isVisible()) {
            continue;
        }

        const QRect staticRect(subs_[i].widget->pos(), subs_[i].widget->size());

        // 检查主窗口边缘
        accumulateAxes(QRect(mainWindow_->pos(), mainWindow_->size()), staticRect);

        // 检查联动组中各成员边缘
        for (int g : dragSession_.moveGroup) {
            if (g < 0 || g >= subs_.size() || !subs_[g].widget || !subs_[g].widget->isVisible()) {
                continue;
            }
            accumulateAxes(QRect(subs_[g].widget->pos(), subs_[g].widget->size()), staticRect);
        }
    }

    // 屏幕边缘
    accumulateScreenAxes(QRect(mainWindow_->pos(), mainWindow_->size()));
    for (int g : dragSession_.moveGroup) {
        if (g < 0 || g >= subs_.size() || !subs_[g].widget || !subs_[g].widget->isVisible()) {
            continue;
        }
        accumulateScreenAxes(QRect(subs_[g].widget->pos(), subs_[g].widget->size()));
    }

    const QPoint bestGroupShift(hasXShift ? bestXShift : 0, hasYShift ? bestYShift : 0);

    if (bestGroupShift.isNull()) {
        return {};
    }

    if (dragSession_.active()) {
        ensureDebugOverlay();
        debugOriginalPoint_ = mainWindow_->pos();
        debugVisibleFramePoint_ = mainWindow_->frameGeometry().topLeft();
        debugTargetPoint_ = mainWindow_->frameGeometry().topLeft() + bestGroupShift;
        debugPointsVisible_ = true;
        updateDebugOverlay();
    }

    // 整个联合体（主窗口 + 已吸附子窗口）统一平移
    syncing_ = true;
    mainWindow_->move(mainWindow_->pos() + bestGroupShift);
    for (int g : dragSession_.moveGroup) {
        if (g < 0 || g >= subs_.size() || !subs_[g].widget || !subs_[g].widget->isVisible()) {
            continue;
        }
        subs_[g].widget->move(subs_[g].widget->pos() + bestGroupShift);
    }
    syncing_ = false;
    return bestGroupShift;
}

// 执行拖动子窗口结束后的最终吸附。
// 使用独立双轴吸附：X 和 Y 方向分别选取最优位置再合并。
QPoint WindowSnapManager::finalSnapDraggedSub() {
    if (!mainWindow_ || !dragSession_.active() || dragSession_.leader == mainWindow_) {
        return {};
    }

    const int leaderIndex = dragSession_.leaderIndex;
    if (leaderIndex < 0 || leaderIndex >= subs_.size()) {
        return {};
    }

    auto& entry = subs_[leaderIndex];
    if (!entry.widget) {
        return {};
    }

    const QRect movingRect(entry.widget->pos(), entry.widget->size());

    int bestXDist = INT_MAX, bestYDist = INT_MAX;
    int bestNewX = movingRect.left(), bestNewY = movingRect.top();
    bool hasXSnap = false, hasYSnap = false;

    auto considerAxes = [&](const QRect& anchorRect) {
        int newX, xDist = INT_MAX;
        if (trySnapXAxis(movingRect, anchorRect, newX, xDist) && xDist < bestXDist) {
            bestXDist = xDist;
            bestNewX = newX;
            hasXSnap = true;
        }

        int newY, yDist = INT_MAX;
        if (trySnapYAxis(movingRect, anchorRect, newY, yDist) && yDist < bestYDist) {
            bestYDist = yDist;
            bestNewY = newY;
            hasYSnap = true;
        }
    };

    // 主窗口
    if (mainWindow_->isVisible()) {
        considerAxes(QRect(mainWindow_->pos(), mainWindow_->size()));
    }

    // 已连接窗口组外接矩形
    const QRect connectedGroupRect = connectedGroupRectExcluding(leaderIndex);
    if (connectedGroupRect.isValid() &&
        connectedGroupRect != QRect(mainWindow_->pos(), mainWindow_->size())) {
        considerAxes(connectedGroupRect);
    }

    // 其他子窗口
    for (int i = 0; i < subs_.size(); ++i) {
        if (i == leaderIndex || !subs_[i].widget || !subs_[i].widget->isVisible()) {
            continue;
        }
        considerAxes(QRect(subs_[i].widget->pos(), subs_[i].widget->size()));
    }

    // 屏幕边缘
    {
        int newX, xDist = INT_MAX;
        if (trySnapXAxisToScreen(movingRect, newX, xDist) && xDist < bestXDist) {
            bestXDist = xDist;
            bestNewX = newX;
            hasXSnap = true;
        }
        int newY, yDist = INT_MAX;
        if (trySnapYAxisToScreen(movingRect, newY, yDist) && yDist < bestYDist) {
            bestYDist = yDist;
            bestNewY = newY;
            hasYSnap = true;
        }
    }

    if (!hasXSnap && !hasYSnap) {
        clearDebugOverlay();
        return {};
    }

    const QPoint oldPos = entry.widget->pos();
    const QPoint bestPos(hasXSnap ? bestNewX : movingRect.left(),
                         hasYSnap ? bestNewY : movingRect.top());

    if (dragSession_.active()) {
        ensureDebugOverlay();
        debugOriginalPoint_ = movingRect.topLeft();
        debugVisibleFramePoint_ = entry.widget->frameGeometry().topLeft();
        debugTargetPoint_ = bestPos;
        debugPointsVisible_ = true;
        updateDebugOverlay();
    }

    syncing_ = true;
    entry.widget->move(bestPos);
    syncing_ = false;
    return bestPos - oldPos;
}

void WindowSnapManager::rebuildSnapGraphInPlace() {
    if (!mainWindow_) {
        return;
    }

    clearAllAnchors();

    bool changed = true;
    while (changed) {
        changed = false;
        for (int i = 0; i < subs_.size(); ++i) {
            if (!subs_[i].widget || !subs_[i].widget->isVisible() || isSnapped(i)) {
                continue;
            }
            if (trySnap(i, false)) {
                changed = true;
            }
        }
    }

    rebuildChildren();
    refreshOffsets();
}

void WindowSnapManager::refreshOffsets() {
    for (int i = 0; i < subs_.size(); ++i) {
        if (!isSnapped(i) || !subs_[i].widget) {
            continue;
        }

        QWidget* anchor = anchorWidget(i);
        if (!anchor) {
            subs_[i].anchor = NoAnchor;
            subs_[i].snapOffset = {};
            continue;
        }

        subs_[i].snapOffset = subs_[i].widget->pos() - anchor->pos();
    }
}

int WindowSnapManager::moveConnectedSubWindows(const QPoint& delta) {
    if (delta.isNull() || !mainWindow_) {
        return 0;
    }

    int movedWindows = 0;
    syncing_ = true;
    for (int i = 0; i < subs_.size(); ++i) {
        auto& entry = subs_[i];
        if (!entry.widget || !entry.widget->isVisible() || !isConnectedToMain(i)) {
            continue;
        }
        entry.widget->move(entry.widget->pos() + delta);
        ++movedWindows;
    }
    syncing_ = false;
    return movedWindows;
}
