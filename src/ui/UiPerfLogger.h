#pragma once

#include <QDebug>
#include <QString>

class UiPerfLogger {
public:
    UiPerfLogger(const char* owner, const char* operation, qint64 slowMs, int sampleInterval)
        : owner_(QString::fromLatin1(owner))
        , operation_(QString::fromLatin1(operation))
        , slowMs_(slowMs)
        , sampleInterval_(sampleInterval) {}

    void note(qint64 elapsedMs, const QString& extra = {}) {
        if (!enabled_) {
            return;
        }

        ++count_;
        totalMs_ += elapsedMs;
        if (elapsedMs > maxMs_) {
            maxMs_ = elapsedMs;
        }
        if (elapsedMs >= slowMs_) {
            ++slowCount_;
        }

        const bool shouldLog =
            elapsedMs >= slowMs_ ||
            count_ == 1 ||
            (sampleInterval_ > 0 && (count_ % sampleInterval_) == 0);
        if (!shouldLog) {
            return;
        }

        QString message =
            QStringLiteral("[UiPerf][%1] %2 #%3 elapsed=%4ms avg=%5ms max=%6ms slow=%7")
                .arg(owner_)
                .arg(operation_)
                .arg(count_)
                .arg(elapsedMs)
                .arg(QString::number(averageMs(), 'f', 2))
                .arg(maxMs_)
                .arg(slowCount_);
        if (!extra.isEmpty()) {
            message.append(QLatin1Char(' '));
            message.append(extra);
        }
        qDebug().noquote() << message;
    }

    void setEnabled(bool enabled, bool resetStats = false) {
        enabled_ = enabled;
        if (resetStats) {
            reset();
        }
    }

    void reset() {
        count_ = 0;
        totalMs_ = 0;
        maxMs_ = 0;
        slowCount_ = 0;
    }

    double averageMs() const {
        return count_ > 0
            ? static_cast<double>(totalMs_) / static_cast<double>(count_)
            : 0.0;
    }

private:
    QString owner_;
    QString operation_;
    qint64 slowMs_ = 0;
    int sampleInterval_ = 0;
    bool enabled_ = false;
    int count_ = 0;
    qint64 totalMs_ = 0;
    qint64 maxMs_ = 0;
    int slowCount_ = 0;
};
