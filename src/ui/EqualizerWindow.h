#pragma once
#include "skin/SkinData.h"
#include "skin/SkinButton.h"
#include "audio/AudioEngine.h"
#include "WindowMovePerfLogger.h"
#include <QWidget>
#include <QVector>
#include <QPair>
#include <array>

// 均衡器窗口，显示 10 波段调节和预设菜单。
class EqualizerWindow : public QWidget {
    Q_OBJECT
public:
    explicit EqualizerWindow(AudioEngine* engine, QWidget* parent = nullptr);
    // 应用皮肤到均衡器窗口，包括按钮、滑块和标题。
    void applySkin(const SkinData& skin);

signals:
    void windowMoved(QPoint delta);
    void dragStarted();
    void dragFinished();
    void closeRequested();
    void visibilityChanged(bool visible);

protected:
    void paintEvent(QPaintEvent*) override;
    void mousePressEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void moveEvent(QMoveEvent*) override;
    void showEvent(QShowEvent*) override;
    void hideEvent(QHideEvent*) override;

private slots:
    void showProfileMenu();
    void applyPreset(const std::array<double,10>& bands, double preamp);

private:
    void resetSkinControls();
    void syncEqualizerControlState(bool enabled);

    AudioEngine* engine_;
    QPixmap background_;
    QPixmap titlePixmap_;
    QRect titleRect_;
    SkinElement closeElement_;

    SkinButton* btnEnabled_  = nullptr;
    SkinButton* btnProfile_  = nullptr;
    SkinButton* btnReset_    = nullptr;
    SkinSlider* sliderPreamp_   = nullptr;
    SkinSlider* sliderBalance_  = nullptr;
    SkinSlider* sliderSurround_ = nullptr;
    QVector<SkinSlider*> eqSliders_;  // 10 bands
    double surroundValue_ = 0.0;

    int eqInterval_ = 2;
    bool dragging_ = false;
    QPoint dragStart_;
    bool dragSessionActive_ = false;
    bool dragUsingSystemMove_ = false;
    bool lastMoveEventObserved_ = false;
    qint64 lastWindowMovedEmitMs_ = 0;
    WindowMovePerfLogger movePerf_{"EqualizerWindow"};

    // 均衡器预设：{名称, {10 波段增益}, 前置增益}
    struct EqPreset {
        QString name;
        std::array<double,10> bands;
        double preamp;
    };
    QVector<EqPreset> presets_;
    void initPresets();
};
