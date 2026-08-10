#pragma once
#include "skin/SkinData.h"
#include "skin/SkinButton.h"
#include "audio/AudioEngine.h"
#include "VisualWidget.h"
#include "UiPerfLogger.h"
#include "WindowMovePerfLogger.h"
#include <QWidget>
#include <QLabel>
#include <QElapsedTimer>
#include <QTimer>
#include <QPoint>
#include <QMap>

// 主播放器窗口，负责显示皮肤界面、处理用户交互、显示播放信息和可视化。
class PlayerWindow : public QWidget {
    Q_OBJECT
public:
    explicit PlayerWindow(AudioEngine* engine, QWidget* parent = nullptr);

    // 应用皮肤数据到窗口
    void applySkin(const SkinData& skin);
    // 设置辅助窗口（歌词、均衡器、列表）的开关状态按钮
    void setAuxWindowToggleStates(bool lyricVisible, bool equalizerVisible, bool playlistVisible);

signals:
    void lyricToggled(bool visible);
    void equalizerToggled(bool visible);
    void playlistToggled(bool visible);
    void miniModeRequested();
    void prevRequested();
    void nextRequested();
    void minimizeRequested();
    void exitRequested();
    void openFileRequested();
    void contextMenuRequested(const QPoint& globalPos);
    void windowMoved(QPoint delta);
    void dragStarted();
    void dragFinished();

protected:
    void paintEvent(QPaintEvent* event) override;
    void contextMenuEvent(QContextMenuEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void moveEvent(QMoveEvent* event) override;

private slots:
    void onPlayClicked();
    void onStopClicked();
    void onPrevClicked();
    void onNextClicked();
    void onStateChanged(AudioEngine::State state);
    void onPositionChanged(int64_t posMs);
    void onDurationChanged(int64_t durMs);
    void updateDisplay();

private:
    // 删除旧皮肤控件并清理状态。
    void resetSkinWidgets();
    // 根据皮肤元素创建按钮控件。
    void createButtons(const SkinWindow& skinWnd);
    // 创建进度条和音量滑块。
    void createSliders(const SkinWindow& skinWnd);
    // 创建可视化控件并设置位置。
    void createVisual(const SkinWindow& skinWnd);
    // 根据当前背景图更新窗口遮罩，支持不规则边界。
    void updateWindowMask();
    // 绘制 LED 时间显示。
    void drawLedTime(QPainter& p, const SkinElement& elem, int64_t timeMs, bool elapsed);
    // 返回 LED 时间实际会绘制到的区域，兼容字模超出元素矩形的老皮肤。
    QRect ledPaintBounds() const;
    // 绘制曲目信息文字。
    void drawInfoText(QPainter& p, const SkinElement& elem, const QString& text);
    // 刷新可视化显示状态（频谱/模糊/封面）。
    void refreshVisualState();
    // 尝试加载嵌入或旁侧封面图片。
    QPixmap loadCoverArt() const;
    // 格式化毫秒为 MM:SS 字符串。
    QString formatTime(int64_t ms) const;

    AudioEngine* engine_;
    QPixmap background_;
    QPixmap ledDigits_;           // number.bmp 数码管精灵图

    // 按钮控件
    SkinButton* btnPlay_ = nullptr;
    SkinButton* btnPause_ = nullptr;
    SkinButton* btnStop_ = nullptr;
    SkinButton* btnPrev_ = nullptr;
    SkinButton* btnNext_ = nullptr;
    SkinButton* btnMute_ = nullptr;
    SkinButton* btnOpen_ = nullptr;
    SkinButton* btnLyric_ = nullptr;
    SkinButton* btnEqualizer_ = nullptr;
    SkinButton* btnPlaylist_ = nullptr;
    SkinButton* btnMiniMode_ = nullptr;
    SkinButton* btnMinimize_ = nullptr;
    SkinButton* btnExit_ = nullptr;

    // 滑块控件
    SkinSlider* sliderProgress_ = nullptr;
    SkinSlider* sliderVolume_ = nullptr;
    VisualWidget* visualWidget_ = nullptr;

    // 文本绘制用的皮肤元素引用
    SkinElement elemInfo_;
    SkinElement elemLed_;
    SkinElement elemStereo_;
    SkinElement elemStatus_;
    SkinElement elemVisual_;
    SkinElement elemIcon_;

    // 状态数据
    int64_t currentPosMs_ = 0;
    int64_t durationMs_ = 0;
    bool showElapsed_ = true;
    int infoScrollOffset_ = 0;
    enum VisualMode {
        VisualSpectrum,
        VisualBlurScope,
        VisualCover,
        VisualNone
    };
    VisualMode visualMode_ = VisualSpectrum;
    QPixmap coverArt_;
    QString coverArtTrack_;

    // 拖拽相关
    bool dragging_ = false;
    QPoint dragStartPos_;
    bool dragSessionActive_ = false;
    bool dragUsingSystemMove_ = false;
    bool lastMoveEventObserved_ = false;
    qint64 lastWindowMovedEmitMs_ = 0;
    WindowMovePerfLogger movePerf_{"PlayerWindow"};
    UiPerfLogger paintPerf_{"PlayerWindow", "paint", 4, 30};
    UiPerfLogger displayPerf_{"PlayerWindow", "display_tick", 4, 30};
    UiPerfLogger positionPerf_{"PlayerWindow", "position_slot", 2, 40};
    QElapsedTimer positionClock_;
    qint64 lastPositionSignalMs_ = -1;

    QTimer* displayTimer_;
};
