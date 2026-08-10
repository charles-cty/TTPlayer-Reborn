#pragma once
#include "audio/AudioEngine.h"
#include "skin/SkinData.h"
#include "UiPerfLogger.h"
#include <QWidget>
#include <QThread>
#include <QTimer>
#include <QVector>
#include <vector>

// 可视化显示控件，负责绘制频谱和模糊示波图。
class VisualWidget : public QWidget {
    Q_OBJECT
public:
    enum Mode { Spectrum, BlurScope, None };

    explicit VisualWidget(AudioEngine* engine, QWidget* parent = nullptr);
    ~VisualWidget() override;
    void setPerfLoggingEnabled(bool enabled);

    // 设置可视化显示模式（频谱、模糊示波图或无）。
    void setMode(Mode mode);
    Mode mode() const { return mode_; }
    // 设置皮肤可视化配置（颜色、帧率等）。
    void setSkinConfig(const VisualConfig& config);
    // 设置父窗口背景，使本控件自行绘制背景以避免触发父窗口重绘。
    void setParentBackground(const QPixmap& bg);

protected:
    void paintEvent(QPaintEvent*) override;
    void showEvent(QShowEvent*) override;
    void hideEvent(QHideEvent*) override;

private slots:
    void refresh();
    void onComputeFinished(const QVector<float>& bandValues,
                           const QVector<float>& wave,
                           int mode,
                           qint64 workerElapsedMs);

signals:
    void computeRequested(const QVector<float>& raw, int bands, int mode);

private:
    void drawSpectrum(QPainter& p);
    void drawBlurScope(QPainter& p);
    void updateRefreshTimer();
    bool shouldAnimate() const;

    AudioEngine* engine_;
    Mode mode_ = Spectrum;
    QTimer timer_;
    QThread computeThread_;
    QObject* computeWorker_ = nullptr;
    bool workerBusy_ = false;

    // 频谱数据
    std::vector<float> spectrumData_;
    std::vector<float> peakData_;
    int bandCount() const;
    VisualConfig config_;
    QPixmap parentBackground_;
    UiPerfLogger refreshPerf_{"VisualWidget", "refresh", 4, 30};
    UiPerfLogger paintPerf_{"VisualWidget", "paint", 4, 30};
    UiPerfLogger resultPerf_{"VisualWidget", "apply_result", 4, 30};

    // 模糊示波图历史数据
    std::vector<std::vector<float>> scopeHistory_;
    static constexpr int kScopeLength = 256;
    static constexpr int kScopeHistoryMax = 4;
};
