#pragma once

#include <QDebug>
#include <QElapsedTimer>
#include <QPoint>
#include <QString>

class WindowMovePerfLogger {
public:
    explicit WindowMovePerfLogger(const char* windowName)
        : windowName_(QString::fromLatin1(windowName)) {}

    bool active() const { return active_; }

    void beginSession(const QString& mode,
                      const QPoint& startPos,
                      const QString& playbackState) {
        active_ = true;
        mode_ = mode;
        playbackState_ = playbackState;
        startPos_ = startPos;
        resetStats();
        sessionTimer_.start();

        qDebug().noquote()
            << QStringLiteral("[MovePerf][%1] drag_begin mode=\"%2\" playback=\"%3\" start=(%4,%5)")
                   .arg(windowName_)
                   .arg(mode_)
                   .arg(playbackState_)
                   .arg(startPos.x())
                   .arg(startPos.y());
    }

    void noteMoveRequest(const QPoint& from,
                         const QPoint& to,
                         qint64 totalMs,
                         qint64 emitWindowMovedMs) {
        if (!active_) {
            return;
        }

        ++moveRequestCount_;
        moveRequestTotalMs_ += totalMs;
        if (totalMs > moveRequestMaxMs_) {
            moveRequestMaxMs_ = totalMs;
        }
        if (totalMs >= kSlowMoveRequestMs) {
            ++slowMoveRequestCount_;
        }

        const bool shouldLog =
            totalMs >= kSlowMoveRequestMs ||
            moveRequestCount_ == 1 ||
            (moveRequestCount_ % kSampleInterval) == 0;
        if (!shouldLog) {
            return;
        }

        qDebug().noquote()
            << QStringLiteral("[MovePerf][%1] move_call #%2 mode=\"%3\" from=(%4,%5) to=(%6,%7) total=%8ms emit_windowMoved=%9ms")
                   .arg(windowName_)
                   .arg(moveRequestCount_)
                   .arg(mode_)
                   .arg(from.x())
                   .arg(from.y())
                   .arg(to.x())
                   .arg(to.y())
                   .arg(totalMs)
                   .arg(emitWindowMovedMs);
    }

    void noteMoveEvent(const QPoint& from,
                       const QPoint& to,
                       const QPoint& delta,
                       qint64 emitWindowMovedMs,
                       bool forceLog = false) {
        if (!active_) {
            return;
        }

        ++moveEventCount_;
        moveEventEmitTotalMs_ += emitWindowMovedMs;
        if (emitWindowMovedMs > moveEventEmitMaxMs_) {
            moveEventEmitMaxMs_ = emitWindowMovedMs;
        }
        if (emitWindowMovedMs >= kSlowMoveEventMs) {
            ++slowMoveEventCount_;
        }

        const bool shouldLog =
            forceLog ||
            emitWindowMovedMs >= kSlowMoveEventMs ||
            moveEventCount_ == 1 ||
            (moveEventCount_ % kSampleInterval) == 0;
        if (!shouldLog) {
            return;
        }

        qDebug().noquote()
            << QStringLiteral("[MovePerf][%1] move_event #%2 mode=\"%3\" from=(%4,%5) to=(%6,%7) delta=(%8,%9) emit_windowMoved=%10ms")
                   .arg(windowName_)
                   .arg(moveEventCount_)
                   .arg(mode_)
                   .arg(from.x())
                   .arg(from.y())
                   .arg(to.x())
                   .arg(to.y())
                   .arg(delta.x())
                   .arg(delta.y())
                   .arg(emitWindowMovedMs);
    }

    void endSession(const QPoint& endPos, const QString& reason) {
        if (!active_) {
            return;
        }

        const qint64 sessionMs = sessionTimer_.isValid() ? sessionTimer_.elapsed() : 0;
        const qint64 travelDistance = (endPos - startPos_).manhattanLength();
        const double avgMoveRequestMs = moveRequestCount_ > 0
            ? static_cast<double>(moveRequestTotalMs_) / static_cast<double>(moveRequestCount_)
            : 0.0;
        const double avgMoveEventMs = moveEventCount_ > 0
            ? static_cast<double>(moveEventEmitTotalMs_) / static_cast<double>(moveEventCount_)
            : 0.0;

        qDebug().noquote()
            << QStringLiteral("[MovePerf][%1] drag_end mode=\"%2\" playback=\"%3\" reason=\"%4\" session=%5ms start=(%6,%7) end=(%8,%9) distance=%10 move_calls=%11 avg_move_call=%12ms max_move_call=%13ms slow_move_calls=%14 move_events=%15 avg_emit=%16ms max_emit=%17ms slow_emit=%18")
                   .arg(windowName_)
                   .arg(mode_)
                   .arg(playbackState_)
                   .arg(reason)
                   .arg(sessionMs)
                   .arg(startPos_.x())
                   .arg(startPos_.y())
                   .arg(endPos.x())
                   .arg(endPos.y())
                   .arg(travelDistance)
                   .arg(moveRequestCount_)
                   .arg(QString::number(avgMoveRequestMs, 'f', 2))
                   .arg(moveRequestMaxMs_)
                   .arg(slowMoveRequestCount_)
                   .arg(moveEventCount_)
                   .arg(QString::number(avgMoveEventMs, 'f', 2))
                   .arg(moveEventEmitMaxMs_)
                   .arg(slowMoveEventCount_);

        active_ = false;
        mode_.clear();
        playbackState_.clear();
        startPos_ = {};
        resetStats();
    }

private:
    void resetStats() {
        moveRequestCount_ = 0;
        moveRequestTotalMs_ = 0;
        moveRequestMaxMs_ = 0;
        slowMoveRequestCount_ = 0;
        moveEventCount_ = 0;
        moveEventEmitTotalMs_ = 0;
        moveEventEmitMaxMs_ = 0;
        slowMoveEventCount_ = 0;
    }

    static constexpr qint64 kSlowMoveRequestMs = 8;
    static constexpr qint64 kSlowMoveEventMs = 4;
    static constexpr int kSampleInterval = 20;

    QString windowName_;
    bool active_ = false;
    QString mode_;
    QString playbackState_;
    QPoint startPos_;
    QElapsedTimer sessionTimer_;

    int moveRequestCount_ = 0;
    qint64 moveRequestTotalMs_ = 0;
    qint64 moveRequestMaxMs_ = 0;
    int slowMoveRequestCount_ = 0;

    int moveEventCount_ = 0;
    qint64 moveEventEmitTotalMs_ = 0;
    qint64 moveEventEmitMaxMs_ = 0;
    int slowMoveEventCount_ = 0;
};
