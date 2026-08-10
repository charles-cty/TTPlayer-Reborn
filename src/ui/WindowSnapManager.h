#pragma once
#include <QObject>
#include <QElapsedTimer>
#include <QPoint>
#include <QString>
#include <QVector>

class QRect;
class QWidget;

/**
 * WindowSnapManager - 实现原版千千静听的窗口联动移动机制。
 *
 * 工作原理：
 *  - 子窗口可吸附到主窗口，或吸附到已连接主窗口的子窗口。
 *  - 主窗口移动时，仅移动“直接或间接连接到主窗口”的吸附窗口。
 *  - 子窗口手动拖动只影响自身吸附状态，不会带动其他窗口移动。
 */
class WindowSnapManager : public QObject {
    Q_OBJECT
public:
    explicit WindowSnapManager(QObject* parent = nullptr);

    void setMainWindow(QWidget* main);
    void addSubWindow(QWidget* sub);

    int snapThreshold() const { return snapThreshold_; }
    void setSnapThreshold(int px) { snapThreshold_ = px; }
    bool liveAttachOnMainDragEnabled() const { return liveAttachOnMainDragEnabled_; }
    void setLiveAttachOnMainDragEnabled(bool enabled) { liveAttachOnMainDragEnabled_ = enabled; }

public slots:
    // 主窗口移动时调用（delta = 新位置 - 旧位置）
    void onMainMoved(QPoint delta);

    // 子窗口自身移动后调用，检测是否应吸附
    void onSubMoved(QWidget* sub, QPoint delta);
    void onSubResized(QWidget* sub, Qt::Edges edges);
    void onSubResizeFinished(QWidget* sub, Qt::Edges edges);
    void onDragStarted(QWidget* leader);
    void onDragFinished(QWidget* leader);
    void rebuildSnapGraph();

private:
    static constexpr int MainAnchor = -1;
    static constexpr int NoAnchor = -2;

    struct SubEntry {
        QWidget* widget = nullptr;
        int      anchor = NoAnchor; // 主窗口=MainAnchor，未吸附=NoAnchor，其他值为 subs_ 下标
        QPoint   snapOffset;        // 相对锚点左上角偏移
        QVector<int> children;
    };

    struct DragSession {
        QWidget* leader = nullptr;
        int      leaderIndex = NoAnchor;
        QPoint   leaderStartPos;
        QVector<int> moveGroup;
        QVector<QPoint> moveGroupStartPos;

        bool active() const { return leader != nullptr; }
        void clear() {
            leader = nullptr;
            leaderIndex = NoAnchor;
            leaderStartPos = {};
            moveGroup.clear();
            moveGroupStartPos.clear();
        }
    };

    struct MovePerfStat {
        int count = 0;
        qint64 totalMs = 0;
        qint64 maxMs = 0;
        int slowCount = 0;
        int totalMovedWindows = 0;
        int appliedCount = 0;

        void add(qint64 elapsedMs, int movedWindows = 0, bool applied = false) {
            ++count;
            totalMs += elapsedMs;
            if (elapsedMs > maxMs) {
                maxMs = elapsedMs;
            }
            if (elapsedMs >= 8) {
                ++slowCount;
            }
            totalMovedWindows += movedWindows;
            if (applied) {
                ++appliedCount;
            }
        }

        double averageMs() const {
            return count > 0
                ? static_cast<double>(totalMs) / static_cast<double>(count)
                : 0.0;
        }
    };

    struct MovePerfSession {
        bool active = false;
        QString leaderName;
        QElapsedTimer timer;
        MovePerfStat mainMoveTotal;
        MovePerfStat moveGroup;
        MovePerfStat liveSnap;
        MovePerfStat connectedMove;
        MovePerfStat subMoveTotal;
        MovePerfStat subSnap;
        MovePerfStat finishTotal;
        MovePerfStat finishSnap;
        MovePerfStat rebuildGraph;

        void clear() {
            active = false;
            leaderName.clear();
            timer.invalidate();
            mainMoveTotal = {};
            moveGroup = {};
            liveSnap = {};
            connectedMove = {};
            subMoveTotal = {};
            subSnap = {};
            finishTotal = {};
            finishSnap = {};
            rebuildGraph = {};
        }
    };

    int findSubIndex(QWidget* widget) const;
    QWidget* anchorWidget(int subIndex) const;
    bool isSnapped(int subIndex) const;
    bool isConnectedToMain(int subIndex) const;
    bool wouldCreateCycle(int movingIndex, int anchorIndex) const;
    bool trySnap(int movingIndex, bool moveToSnap = true);
    bool trySnapToAnchor(const QRect& movingRect,
                         const QRect& anchorRect,
                         QPoint& outSnapPos,
                         int& outDistance) const;
    bool trySnapToScreenEdges(const QRect& movingRect,
                              QPoint& outSnapPos,
                              int& outDistance) const;
    bool trySnapXAxis(const QRect& movingRect, const QRect& anchorRect,
                      int& outNewX, int& outXDist) const;
    bool trySnapYAxis(const QRect& movingRect, const QRect& anchorRect,
                      int& outNewY, int& outYDist) const;
    bool trySnapXAxisToScreen(const QRect& movingRect,
                              int& outNewX, int& outXDist) const;
    bool trySnapYAxisToScreen(const QRect& movingRect,
                              int& outNewY, int& outYDist) const;
    bool trySnapResizeToAnchor(const QRect& movingRect,
                               Qt::Edges resizeEdges,
                               const QRect& anchorRect,
                               QRect& outSnapRect,
                               int& outDistance) const;
    bool trySnapResizeToScreenEdges(const QRect& movingRect,
                                    Qt::Edges resizeEdges,
                                    QRect& outSnapRect,
                                    int& outDistance) const;
    QRect screenGeometryForRect(const QRect& rect) const;
    QRect connectedGroupRectExcluding(int excludeIndex) const;
    void rebuildChildren();
    void clearAllAnchors();
    void beginDragSession(QWidget* leader);
    void finishDragSession(QWidget* leader);
    int moveDragGroup(const QPoint& totalDelta);
    void tryAttachUnsnappedWindowsToDragGroup(const QPoint& totalDelta);
    QPoint finalSnapGroupToStaticWindows();
    QPoint finalSnapDraggedSub();
    void rebuildSnapGraphInPlace();
    void refreshOffsets();
    int moveConnectedSubWindows(const QPoint& delta);
    void ensureDebugOverlay();
    void updateDebugOverlay();
    void clearDebugOverlay();
    QString widgetDebugName(QWidget* widget) const;
    void beginMovePerfSession(QWidget* leader);
    void logMovePerfSummary(const QString& reason);

    QWidget*          mainWindow_ = nullptr;
    QVector<SubEntry> subs_;
    int               snapThreshold_ = 10;
    bool              liveAttachOnMainDragEnabled_ = true;
    bool              syncing_ = false;
    DragSession       dragSession_;

    QWidget*          debugOverlay_ = nullptr;
    QPoint            debugOriginalPoint_{};
    QPoint            debugVisibleFramePoint_{};
    QPoint            debugTargetPoint_{};
    bool              debugPointsVisible_ = false;
    MovePerfSession   movePerf_;
};
