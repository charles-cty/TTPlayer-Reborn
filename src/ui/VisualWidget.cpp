#include "VisualWidget.h"
#include <algorithm>
#include <QElapsedTimer>
#include <QHideEvent>
#include <QObject>
#include <QPaintEvent>
#include <QPainter>
#include <QLinearGradient>
#include <QShowEvent>
#include <cmath>

namespace {
template <typename Samples>
float goertzelMagnitude(const Samples& samples, int startBin, int endBin) {
    if (samples.empty() || startBin > endBin) {
        return 0.0f;
    }

    const int sampleCount = static_cast<int>(samples.size());
    float total = 0.0f;
    int usedBins = 0;

    for (int bin = startBin; bin <= endBin; ++bin) {
        if (bin <= 0 || bin >= sampleCount / 2) {
            continue;
        }

        const float omega = 2.0f * static_cast<float>(M_PI) * static_cast<float>(bin) /
                            static_cast<float>(sampleCount);
        const float coeff = 2.0f * std::cos(omega);
        float q0 = 0.0f;
        float q1 = 0.0f;
        float q2 = 0.0f;

        for (float sample : samples) {
            q0 = coeff * q1 - q2 + sample;
            q2 = q1;
            q1 = q0;
        }

        const float real = q1 - q2 * std::cos(omega);
        const float imag = q2 * std::sin(omega);
        total += std::sqrt(real * real + imag * imag) / static_cast<float>(sampleCount);
        ++usedBins;
    }

    return usedBins > 0 ? total / static_cast<float>(usedBins) : 0.0f;
}

QString playbackStateText(const AudioEngine* engine) {
    if (!engine) {
        return QStringLiteral("no_engine");
    }

    switch (engine->state()) {
    case AudioEngine::Stopped:
        return QStringLiteral("stopped");
    case AudioEngine::Playing:
        return QStringLiteral("playing");
    case AudioEngine::Paused:
        return QStringLiteral("paused");
    }

    return QStringLiteral("unknown");
}

QString visualModeText(VisualWidget::Mode mode) {
    switch (mode) {
    case VisualWidget::Spectrum:
        return QStringLiteral("spectrum");
    case VisualWidget::BlurScope:
        return QStringLiteral("blurscope");
    case VisualWidget::None:
        return QStringLiteral("none");
    }

    return QStringLiteral("unknown");
}

class VisualComputeWorker : public QObject {
    Q_OBJECT
public slots:
    void process(const QVector<float>& raw, int bands, int mode) {
        QElapsedTimer timer;
        timer.start();

        QVector<float> bandValues(bands, 0.0f);
        const int maxBin = qMax(0, raw.size() / 2 - 1);
        if (bands > 0 && maxBin > 0) {
            for (int i = 0; i < bands; ++i) {
                const float startRatio = static_cast<float>(i) / static_cast<float>(bands);
                const float endRatio = static_cast<float>(i + 1) / static_cast<float>(bands);
                const int startBin = qMax(1, static_cast<int>(std::pow(maxBin, startRatio)));
                const int endBin = qMax(startBin, static_cast<int>(std::pow(maxBin, endRatio)));
                const float energy = goertzelMagnitude(raw, startBin, endBin);
                bandValues[i] = std::clamp(std::sqrt(energy) * 6.0f, 0.0f, 1.0f);
            }
        }

        QVector<float> wave;
        if (mode == static_cast<int>(VisualWidget::BlurScope)) {
            constexpr int scopeLength = 256;
            wave.fill(0.0f, scopeLength);
            const int sampleCount = qMin(raw.size(), scopeLength);
            for (int i = 0; i < sampleCount; ++i) {
                wave[i] = raw[i];
            }
        }

        emit computeFinished(bandValues, wave, mode, timer.elapsed());
    }

signals:
    void computeFinished(const QVector<float>& bandValues,
                         const QVector<float>& wave,
                         int mode,
                         qint64 workerElapsedMs);
};
}

// 构造可视化控件，初始化频谱缓存并开启刷新定时器。
VisualWidget::VisualWidget(AudioEngine* engine, QWidget* parent)
    : QWidget(parent)
    , engine_(engine)
    , spectrumData_(20, 0.0f)
    , peakData_(20, 0.0f)
{
    setMinimumSize(1, 1);
    // 不设置 WA_OpaquePaintEvent 或 WA_TranslucentBackground：
    // 父窗口（PlayerWindow）先绘制皮肤背景，本控件再在其上绘制可视化内容。
    // 未绘制区域会自然显示底层皮肤背景。

    auto* worker = new VisualComputeWorker();
    computeWorker_ = worker;
    computeWorker_->moveToThread(&computeThread_);
    connect(this, &VisualWidget::computeRequested,
            worker, &VisualComputeWorker::process,
            Qt::QueuedConnection);
    connect(worker, &VisualComputeWorker::computeFinished,
            this, &VisualWidget::onComputeFinished,
            Qt::QueuedConnection);
    connect(&computeThread_, &QThread::finished, computeWorker_, &QObject::deleteLater);
    computeThread_.start();

    connect(&timer_, &QTimer::timeout, this, &VisualWidget::refresh);
    timer_.setInterval(33); // 约 30fps
    updateRefreshTimer();
}

VisualWidget::~VisualWidget() {
    timer_.stop();
    computeThread_.quit();
    computeThread_.wait();
}

void VisualWidget::setPerfLoggingEnabled(bool enabled) {
    refreshPerf_.setEnabled(enabled, enabled);
    paintPerf_.setEnabled(enabled, enabled);
    resultPerf_.setEnabled(enabled, enabled);
}

void VisualWidget::setMode(Mode mode) {
    if (mode_ == mode) {
        return;
    }

    mode_ = mode;
    if (mode_ != BlurScope) {
        scopeHistory_.clear();
    }
    updateRefreshTimer();
    update();
}

// 计算当前控件宽度下可容纳的频谱柱数量。
int VisualWidget::bandCount() const {
    const int gap = config_.spectrumWide ? 2 : 1;
    const int preferredBarWidth = config_.spectrumWide ? 4 : 3;
    const int count = (width() + gap) / (preferredBarWidth + gap);
    return qBound(8, count, 48);
}

// 更新皮肤可视化配置并调整刷新帧率。
void VisualWidget::setSkinConfig(const VisualConfig& config) {
    config_ = config;
    updateRefreshTimer();
    update();
}

// 设置父窗口背景，使本控件自行绘制背景以避免触发父窗口重绘级联。
void VisualWidget::setParentBackground(const QPixmap& bg) {
    parentBackground_ = bg;
    setAttribute(Qt::WA_OpaquePaintEvent, !bg.isNull());
}

void VisualWidget::showEvent(QShowEvent* event) {
    QWidget::showEvent(event);
    updateRefreshTimer();
}

void VisualWidget::hideEvent(QHideEvent* event) {
    QWidget::hideEvent(event);
    updateRefreshTimer();
}

bool VisualWidget::shouldAnimate() const {
    return mode_ != None && isVisible();
}

void VisualWidget::updateRefreshTimer() {
    const int fps = qBound(10, config_.framesPerSec > 0 ? config_.framesPerSec : 30, 120);
    timer_.setInterval(1000 / fps);
    if (shouldAnimate()) {
        if (!timer_.isActive()) {
            timer_.start();
        }
    } else {
        timer_.stop();
    }
}

// 定时刷新频谱或模糊波形数据。
void VisualWidget::refresh() {
    if (!engine_ || !shouldAnimate()) {
        return;
    }

    QElapsedTimer totalTimer;
    totalTimer.start();

    const int bands = bandCount();
    if (static_cast<int>(spectrumData_.size()) != bands) {
        spectrumData_.assign(bands, 0.0f);
        peakData_.assign(bands, 0.0f);
    }

    if (engine_->state() != AudioEngine::Playing) {
        QElapsedTimer phaseTimer;
        phaseTimer.start();
        phaseTimer.restart();
        for (int i = 0; i < bands; ++i) {
            spectrumData_[i] *= 0.80f;
            peakData_[i] *= 0.92f;
        }
        const qint64 decayMs = phaseTimer.elapsed();

        phaseTimer.restart();
        update();
        const qint64 queueUpdateMs = phaseTimer.elapsed();

        refreshPerf_.note(
            totalTimer.elapsed(),
            QStringLiteral("state=\"%1\" mode=\"%2\" bands=%3 decay=%4ms queue_update=%5ms size=%6x%7")
                .arg(playbackStateText(engine_))
                .arg(visualModeText(mode_))
                .arg(bands)
                .arg(decayMs)
                .arg(queueUpdateMs)
                .arg(width())
                .arg(height()));
        return;
    }

    if (workerBusy_) {
        refreshPerf_.note(
            totalTimer.elapsed(),
            QStringLiteral("state=\"%1\" mode=\"%2\" bands=%3 dispatch=\"busy\" size=%4x%5")
                .arg(playbackStateText(engine_))
                .arg(visualModeText(mode_))
                .arg(bands)
                .arg(width())
                .arg(height()));
        return;
    }

    QElapsedTimer phaseTimer;
    phaseTimer.start();
    QVector<float> raw(1024, 0.0f);
    engine_->getSpectrumData(raw.data(), raw.size());
    const qint64 getSpectrumMs = phaseTimer.elapsed();

    workerBusy_ = true;
    emit computeRequested(raw, bands, static_cast<int>(mode_));

    refreshPerf_.note(
        totalTimer.elapsed(),
        QStringLiteral("state=\"%1\" mode=\"%2\" bands=%3 get_spectrum=%4ms dispatch=\"queued\" size=%5x%6")
            .arg(playbackStateText(engine_))
            .arg(visualModeText(mode_))
            .arg(bands)
            .arg(getSpectrumMs)
            .arg(width())
            .arg(height()));
}

void VisualWidget::onComputeFinished(const QVector<float>& bandValues,
                                     const QVector<float>& wave,
                                     int mode,
                                     qint64 workerElapsedMs) {
    workerBusy_ = false;

    if (!engine_ || engine_->state() != AudioEngine::Playing || !shouldAnimate()) {
        return;
    }
    if (mode != static_cast<int>(mode_)) {
        return;
    }

    QElapsedTimer totalTimer;
    totalTimer.start();

    if (static_cast<int>(spectrumData_.size()) != bandValues.size()) {
        spectrumData_.assign(static_cast<size_t>(bandValues.size()), 0.0f);
        peakData_.assign(static_cast<size_t>(bandValues.size()), 0.0f);
    }

    QElapsedTimer phaseTimer;
    phaseTimer.start();
    for (int i = 0; i < bandValues.size(); ++i) {
        const float value = bandValues[i];
        if (value > spectrumData_[i]) {
            spectrumData_[i] = value;
        } else {
            spectrumData_[i] = spectrumData_[i] * 0.85f + value * 0.15f;
        }

        if (spectrumData_[i] > peakData_[i]) {
            peakData_[i] = spectrumData_[i];
        } else {
            peakData_[i] = std::max(0.0f, peakData_[i] - 0.01f);
        }
    }
    const qint64 smoothMs = phaseTimer.elapsed();

    phaseTimer.restart();
    if (mode_ == BlurScope) {
        std::vector<float> localWave(kScopeLength, 0.0f);
        const int sampleCount = std::min<int>(wave.size(), kScopeLength);
        for (int i = 0; i < sampleCount; ++i) {
            localWave[i] = wave[i];
        }
        scopeHistory_.push_back(std::move(localWave));
        if (static_cast<int>(scopeHistory_.size()) > kScopeHistoryMax) {
            scopeHistory_.erase(scopeHistory_.begin());
        }
    }
    const qint64 blurScopeMs = phaseTimer.elapsed();

    phaseTimer.restart();
    update();
    const qint64 queueUpdateMs = phaseTimer.elapsed();

    resultPerf_.note(
        totalTimer.elapsed(),
        QStringLiteral("mode=\"%1\" worker_elapsed=%2ms smooth=%3ms blur_scope=%4ms queue_update=%5ms size=%6x%7")
            .arg(visualModeText(mode_))
            .arg(workerElapsedMs)
            .arg(smoothMs)
            .arg(blurScopeMs)
            .arg(queueUpdateMs)
            .arg(width())
            .arg(height()));
}

// 绘制当前可视化模式的内容。
void VisualWidget::paintEvent(QPaintEvent* event) {
    QElapsedTimer totalTimer;
    totalTimer.start();

    QPainter p(this);
    // 绘制父窗口背景在本控件区域的部分，避免触发父窗口重绘。
    if (!parentBackground_.isNull()) {
        p.drawPixmap(0, 0, parentBackground_, x(), y(), width(), height());
    }

    if (mode_ == Spectrum)
        drawSpectrum(p);
    else if (mode_ == BlurScope)
        drawBlurScope(p);

    const QRect dirtyBounds = event ? event->region().boundingRect() : rect();
    const int rectCount = event ? event->region().rectCount() : 1;
    paintPerf_.note(
        totalTimer.elapsed(),
        QStringLiteral("mode=\"%1\" playback=\"%2\" dirty=%3x%4 rects=%5 size=%6x%7")
            .arg(visualModeText(mode_))
            .arg(playbackStateText(engine_))
            .arg(dirtyBounds.width())
            .arg(dirtyBounds.height())
            .arg(rectCount)
            .arg(width())
            .arg(height()));
}

// 绘制频谱柱图。
void VisualWidget::drawSpectrum(QPainter& p) {
    int w = width();
    int h = height();
    const int bands = std::max(1, static_cast<int>(spectrumData_.size()));
    int barWidth = std::max(2, (w - bands + 1) / bands);

    QLinearGradient grad(0, h, 0, 0);
    grad.setColorAt(0.0, config_.spectrumBtmColor);
    grad.setColorAt(0.5, config_.spectrumMidColor);
    grad.setColorAt(1.0, config_.spectrumTopColor);

    const int gap = config_.spectrumWide ? 2 : 1;
    barWidth = std::max(2, (w - (bands - 1) * gap) / bands);

    for (int i = 0; i < bands; i++) {
        int x = i * (barWidth + gap);
        int barH = static_cast<int>(spectrumData_[i] * h);
        barH = std::min(barH, h);

        // 频谱柱
        QRect barRect(x, h - barH, barWidth, barH);
        p.fillRect(barRect, QBrush(grad));

        // 峰值指示线
        int peakY = h - static_cast<int>(peakData_[i] * h);
        peakY = std::max(0, peakY);
        p.setPen(config_.spectrumPeakColor);
        p.drawLine(x, peakY, x + barWidth - 1, peakY);
    }
}

// 绘制模糊示波图。
void VisualWidget::drawBlurScope(QPainter& p) {
    int w = width();
    int h = height();
    int midY = h / 2;

    // 绘制旧的波形轨迹，透明度逐渐降低
    for (int t = 0; t < (int)scopeHistory_.size(); t++) {
        float alpha = (t + 1.0f) / scopeHistory_.size();
        const int a = static_cast<int>(alpha * (config_.blur ? 200 : 255));
        QColor scopeColor = config_.blurScopeColor;
        scopeColor.setAlpha(a);
        p.setPen(scopeColor);

        const auto& wave = scopeHistory_[t];
        for (int i = 1; i < (int)wave.size() && i < w; i++) {
            int y0 = midY - static_cast<int>(wave[i - 1] * midY);
            int y1 = midY - static_cast<int>(wave[i] * midY);
            p.drawLine(i - 1, y0, i, y1);
        }
    }
}

#include "VisualWidget.moc"
