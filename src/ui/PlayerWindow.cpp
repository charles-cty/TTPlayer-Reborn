#include "PlayerWindow.h"
#include <QPainter>
#include <QMouseEvent>
#include <QFileDialog>
#include <QRegion>
#include <QBitmap>
#include <QContextMenuEvent>
#include <QWindow>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QElapsedTimer>

namespace {
// 尝试从音频文件所在目录加载封面图片，支持常见文件名。
QPixmap loadSidecarCover(const QString& audioFilePath) {
    if (audioFilePath.isEmpty()) {
        return {};
    }

    const QFileInfo audioInfo(audioFilePath);
    const QDir dir(audioInfo.absolutePath());
    const QStringList candidates = {
        audioInfo.completeBaseName() + ".jpg",
        audioInfo.completeBaseName() + ".jpeg",
        audioInfo.completeBaseName() + ".png",
        "cover.jpg",
        "cover.jpeg",
        "cover.png",
        "folder.jpg",
        "folder.jpeg",
        "folder.png",
        "front.jpg",
        "front.jpeg",
        "front.png",
        "album.jpg",
        "album.jpeg",
        "album.png"
    };

    for (const auto& candidate : candidates) {
        const QString path = dir.absoluteFilePath(candidate);
        QPixmap pixmap(path);
        if (!pixmap.isNull()) {
            return pixmap;
        }
    }

    return {};
}

// 判断是否优先使用手动拖动，而不是系统级窗口拖动。
bool shouldPreferManualMove() {
    // X11/XWayland下系统级拖拽回调存在额外延迟，联动窗口更容易出现波浪错位。
    return QGuiApplication::platformName() == "xcb";
}

Qt::Alignment horizontalAlignmentFor(const QString& align) {
    const QString lower = align.toLower();
    if (lower.contains("center")) {
        return Qt::AlignHCenter;
    }
    if (lower.contains("right")) {
        return Qt::AlignRight;
    }
    return Qt::AlignLeft;
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
}

PlayerWindow::PlayerWindow(AudioEngine* engine, QWidget* parent)
    : QWidget(parent, Qt::FramelessWindowHint | Qt::WindowSystemMenuHint)
    , engine_(engine)
{
    setAttribute(Qt::WA_TranslucentBackground);
    setMouseTracking(true);
    setFocusPolicy(Qt::ClickFocus);

    displayTimer_ = new QTimer(this);
    displayTimer_->setInterval(33); // 约 30fps 的显示刷新频率
    connect(displayTimer_, &QTimer::timeout, this, &PlayerWindow::updateDisplay);
    displayTimer_->start();

    // 连接音频引擎状态信号到界面更新回调
    connect(engine_, &AudioEngine::stateChanged, this, &PlayerWindow::onStateChanged);
    connect(engine_, &AudioEngine::positionChanged, this, &PlayerWindow::onPositionChanged);
    connect(engine_, &AudioEngine::durationChanged, this, &PlayerWindow::onDurationChanged);
    positionClock_.start();
}

// 重置当前皮肤控件，删除旧的按钮和滑块，清理缓存数据。
// 重置当前皮肤控件，删除旧的按钮与滑块，并清理状态数据。
void PlayerWindow::resetSkinWidgets() {
    qDeleteAll(findChildren<SkinButton*>(QString(), Qt::FindDirectChildrenOnly));
    qDeleteAll(findChildren<SkinSlider*>(QString(), Qt::FindDirectChildrenOnly));

    btnPlay_ = nullptr;
    btnPause_ = nullptr;
    btnStop_ = nullptr;
    btnPrev_ = nullptr;
    btnNext_ = nullptr;
    btnMute_ = nullptr;
    btnOpen_ = nullptr;
    btnLyric_ = nullptr;
    btnEqualizer_ = nullptr;
    btnPlaylist_ = nullptr;
    btnMiniMode_ = nullptr;
    btnMinimize_ = nullptr;
    btnExit_ = nullptr;

    sliderProgress_ = nullptr;
    sliderVolume_ = nullptr;

    if (visualWidget_) {
        visualWidget_->hide();
    }

    elemInfo_ = {};
    elemLed_ = {};
    elemStereo_ = {};
    elemStatus_ = {};
    elemVisual_ = {};
    elemIcon_ = {};
    ledDigits_ = {};
}

// 应用皮肤数据到主窗口，包括背景、按钮、滑块和视觉效果区域。
// 将新皮肤数据应用到主播放器窗口，包括背景、按钮、滑块和可视化布局。
void PlayerWindow::applySkin(const SkinData& skin) {
    const auto& wnd = skin.playerWindow;
    resetSkinWidgets();
    background_ = wnd.backgroundPixmap;

    if (!background_.isNull()) {
        setFixedSize(background_.size());
        updateWindowMask();
    }

    createButtons(wnd);
    createSliders(wnd);

    // 存储文本元素信息，供自定义绘制使用
    for (const auto& elem : wnd.elements) {
        if (elem.type == "info") elemInfo_ = elem;
        else if (elem.type == "led") { elemLed_ = elem; ledDigits_ = elem.statePixmaps[0]; }
        else if (elem.type == "stereo") elemStereo_ = elem;
        else if (elem.type == "status") elemStatus_ = elem;
        else if (elem.type == "visual") elemVisual_ = elem;
        else if (elem.type == "icon") elemIcon_ = elem;
    }

    createVisual(wnd);
    if (visualWidget_) {
        visualWidget_->setSkinConfig(skin.visualConfig);
        visualWidget_->setParentBackground(background_);
    }
    refreshVisualState();
    onStateChanged(engine_->state());

    if (!elemIcon_.statePixmaps[0].isNull()) {
        setWindowIcon(QIcon(elemIcon_.statePixmaps[0]));
    }

    update();
}

// 同步主窗口上辅助窗口开关按钮的选中状态。
void PlayerWindow::setAuxWindowToggleStates(bool lyricVisible, bool equalizerVisible, bool playlistVisible) {
    if (btnLyric_) {
        btnLyric_->setToggled(lyricVisible);
    }
    if (btnEqualizer_) {
        btnEqualizer_->setToggled(equalizerVisible);
    }
    if (btnPlaylist_) {
        btnPlaylist_->setToggled(playlistVisible);
    }
}

// 根据皮肤元素创建对应的各类按钮控件。
void PlayerWindow::createButtons(const SkinWindow& skinWnd) {
    auto makeBtn = [this, &skinWnd](const QString& type) -> SkinButton* {
        for (const auto& elem : skinWnd.elements) {
            if (elem.type == type) {
                auto* btn = new SkinButton(this);
                btn->setSkinElement(elem);
                btn->move(elem.position.topLeft());
                btn->show();
                return btn;
            }
        }
        return nullptr;
    };

    btnPlay_ = makeBtn("play");
    btnPause_ = makeBtn("pause");
    btnStop_ = makeBtn("stop");
    btnPrev_ = makeBtn("prev");
    btnNext_ = makeBtn("next");
    btnMute_ = makeBtn("mute");
    btnOpen_ = makeBtn("open");
    btnLyric_ = makeBtn("lyric");
    btnEqualizer_ = makeBtn("equalizer");
    btnPlaylist_ = makeBtn("playlist");
    btnMiniMode_ = makeBtn("minimode");
    btnMinimize_ = makeBtn("minimize");
    btnExit_ = makeBtn("exit");

    // 暂停按钮与播放按钮共享位置，初始时隐藏暂停按钮
    if (btnPause_) btnPause_->hide();

    // 连接按钮信号到对应的槽函数
    if (btnPlay_) connect(btnPlay_, &SkinButton::clicked, this, &PlayerWindow::onPlayClicked);
    if (btnPause_) connect(btnPause_, &SkinButton::clicked, this, &PlayerWindow::onPlayClicked);
    if (btnStop_) connect(btnStop_, &SkinButton::clicked, this, &PlayerWindow::onStopClicked);
    if (btnPrev_) connect(btnPrev_, &SkinButton::clicked, this, &PlayerWindow::onPrevClicked);
    if (btnNext_) connect(btnNext_, &SkinButton::clicked, this, &PlayerWindow::onNextClicked);
    if (btnMute_) {
        btnMute_->setToggleable(true);
        btnMute_->setUsePressedStateForToggle(true);
        btnMute_->setToggled(engine_->isMuted());
        connect(btnMute_, &SkinButton::toggled, this, [this](bool m) {
            engine_->setMuted(m);
        });
    }
    if (btnOpen_) connect(btnOpen_, &SkinButton::clicked, this, &PlayerWindow::openFileRequested);
    if (btnLyric_) {
        btnLyric_->setToggleable(true);
        btnLyric_->setUsePressedStateForToggle(true);
        connect(btnLyric_, &SkinButton::toggled, this, &PlayerWindow::lyricToggled);
    }
    if (btnEqualizer_) {
        btnEqualizer_->setToggleable(true);
        btnEqualizer_->setUsePressedStateForToggle(true);
        connect(btnEqualizer_, &SkinButton::toggled, this, &PlayerWindow::equalizerToggled);
    }
    if (btnPlaylist_) {
        btnPlaylist_->setToggleable(true);
        btnPlaylist_->setUsePressedStateForToggle(true);
        connect(btnPlaylist_, &SkinButton::toggled, this, &PlayerWindow::playlistToggled);
    }
    if (btnMiniMode_) connect(btnMiniMode_, &SkinButton::clicked, this, &PlayerWindow::miniModeRequested);
    if (btnMinimize_) connect(btnMinimize_, &SkinButton::clicked, this, &PlayerWindow::minimizeRequested);
    if (btnExit_) connect(btnExit_, &SkinButton::clicked, this, &PlayerWindow::exitRequested);
}

// 创建进度条和音量滑块控件，并绑定控制回调。
void PlayerWindow::createSliders(const SkinWindow& skinWnd) {
    for (const auto& elem : skinWnd.elements) {
        if (elem.type == "progress") {
            sliderProgress_ = new SkinSlider(this);
            sliderProgress_->setSkinElement(elem);
            sliderProgress_->move(elem.position.topLeft());
            sliderProgress_->setRange(0, 1.0);
            sliderProgress_->show();
            connect(sliderProgress_, &SkinSlider::valueChanged, this, [this](double v) {
                if (durationMs_ > 0) {
                    engine_->seek(static_cast<int64_t>(v * durationMs_));
                }
            });
        }
        else if (elem.type == "volume") {
            sliderVolume_ = new SkinSlider(this);
            sliderVolume_->setSkinElement(elem);
            sliderVolume_->move(elem.position.topLeft());
            sliderVolume_->setRange(0, 100);
            sliderVolume_->setValue(engine_->volume());
            sliderVolume_->show();
            connect(sliderVolume_, &SkinSlider::valueChanged, this, [this](double v) {
                engine_->setVolume(static_cast<int>(v));
            });
        }
    }
}

// 创建或更新可视化显示控件的位置和可见性。
void PlayerWindow::createVisual(const SkinWindow& skinWnd) {
    Q_UNUSED(skinWnd);

    if (elemVisual_.position.isEmpty()) {
        if (visualWidget_) {
            visualWidget_->hide();
        }
        return;
    }

    if (!visualWidget_) {
        visualWidget_ = new VisualWidget(engine_, this);
        visualWidget_->setAttribute(Qt::WA_TransparentForMouseEvents);
        visualWidget_->show();
    }

    visualWidget_->setGeometry(elemVisual_.position);
    visualWidget_->raise();
}

// 更新窗口遮罩，使窗口形状匹配皮肤背景的不规则边界。
void PlayerWindow::updateWindowMask() {
    clearMask();
    if (background_.isNull()) return;
    QBitmap mask = background_.mask();
    if (!mask.isNull()) {
        setMask(mask);
    }
}

void PlayerWindow::paintEvent(QPaintEvent* event) {
    QElapsedTimer totalTimer;
    totalTimer.start();

    QPainter p(this);
    p.setRenderHint(QPainter::SmoothPixmapTransform, false); // 保持像素级精确渲染

    const QRect dirty = event->rect();
    const QRect ledBounds = ledPaintBounds();

    // 仅在脏区域内绘制背景（避免半透明皮肤的全窗口合成开销）
    if (!background_.isNull()) {
        for (const QRect& r : event->region()) {
            p.drawPixmap(r, background_, r);
        }
    }

    if (!elemVisual_.position.isEmpty() && visualMode_ == VisualCover
        && dirty.intersects(elemVisual_.position)) {
        p.save();
        p.setClipRect(elemVisual_.position);
        if (!coverArt_.isNull()) {
            const QPixmap scaled = coverArt_.scaled(elemVisual_.position.size(), Qt::KeepAspectRatio, Qt::SmoothTransformation);
            const QPoint topLeft(
                elemVisual_.position.left() + (elemVisual_.position.width() - scaled.width()) / 2,
                elemVisual_.position.top() + (elemVisual_.position.height() - scaled.height()) / 2);
            p.drawPixmap(topLeft, scaled);
        } else {
            p.fillRect(elemVisual_.position, QColor(12, 12, 12));
            p.setPen(QColor(160, 200, 160));
            p.drawRect(elemVisual_.position.adjusted(0, 0, -1, -1));
            p.drawText(elemVisual_.position.adjusted(6, 6, -6, -6), Qt::AlignCenter,
                       engine_->currentAlbum().isEmpty() ? tr("No Cover") : engine_->currentAlbum());
        }
        p.restore();
    }

    if (!elemIcon_.position.isEmpty() && !elemIcon_.statePixmaps[0].isNull()
        && dirty.intersects(elemIcon_.position)) {
        p.drawPixmap(elemIcon_.position, elemIcon_.statePixmaps[0]);
    }

    // 绘制歌曲信息文本
    if (!elemInfo_.position.isEmpty() && dirty.intersects(elemInfo_.position)) {
        QString title = engine_->currentTitle();
        if (title.isEmpty()) title = tr("TTPlayer Reborn");
        drawInfoText(p, elemInfo_, title);
    }

    // 绘制 LED 时间显示
    if (!elemLed_.position.isEmpty() && !ledDigits_.isNull()
        && dirty.intersects(ledBounds)) {
        int64_t displayTime = showElapsed_ ? currentPosMs_ : (durationMs_ - currentPosMs_);
        drawLedTime(p, elemLed_, displayTime, showElapsed_);
    }

    // 绘制立体声/单声道指示器
    if (!elemStereo_.position.isEmpty() && dirty.intersects(elemStereo_.position)) {
        if (elemStereo_.bkgndColor.isValid())
            p.fillRect(elemStereo_.position, elemStereo_.bkgndColor);
        QFont stereoFont(elemStereo_.fontFamily.isEmpty() ? "SimSun" : elemStereo_.fontFamily);
        stereoFont.setPixelSize(elemStereo_.fontSize > 0 ? elemStereo_.fontSize : 12);
        p.setFont(stereoFont);
        p.setPen(elemStereo_.color);
        p.drawText(elemStereo_.position, horizontalAlignmentFor(elemStereo_.align) | Qt::AlignVCenter, "Stereo");
    }

    // 绘制状态文本（采样率、位深等）
    if (!elemStatus_.position.isEmpty() && dirty.intersects(elemStatus_.position)) {
        if (elemStatus_.bkgndColor.isValid())
            p.fillRect(elemStatus_.position, elemStatus_.bkgndColor);
        QFont statusFont(elemStatus_.fontFamily.isEmpty() ? "SimSun" : elemStatus_.fontFamily);
        statusFont.setPixelSize(elemStatus_.fontSize > 0 ? elemStatus_.fontSize : 12);
        p.setFont(statusFont);
        p.setPen(elemStatus_.color);
        p.drawText(elemStatus_.position, horizontalAlignmentFor(elemStatus_.align) | Qt::AlignVCenter,
                   QString("%1kHz").arg(44.1));
    }

    const QRect dirtyBounds = event->region().boundingRect();
    paintPerf_.note(
        totalTimer.elapsed(),
        QStringLiteral("dirty=%1x%2 rects=%3 playback=\"%4\" dragging=%5 visual_mode=%6")
            .arg(dirtyBounds.width())
            .arg(dirtyBounds.height())
            .arg(event->region().rectCount())
            .arg(playbackStateText(engine_))
            .arg(dragSessionActive_ ? 1 : 0)
            .arg(static_cast<int>(visualMode_)));
}

QRect PlayerWindow::ledPaintBounds() const {
    if (elemLed_.position.isEmpty() || ledDigits_.isNull()) {
        return elemLed_.position;
    }

    const int digitW = ledDigits_.width() / 12;
    const int digitH = ledDigits_.height();
    if (digitW <= 0 || digitH <= 0) {
        return elemLed_.position;
    }

    // 老皮肤里 led.position 可能只是对齐锚点，实际数字会画到矩形之外。
    const int64_t maxTimeMs = durationMs_ > 0 ? durationMs_ : currentPosMs_;
    const int minuteDigits = QString::number(qMax<int64_t>(99, maxTimeMs / 60000)).size();
    const int renderedWidth = (minuteDigits + 4) * digitW;

    int x = elemLed_.position.left();
    const QString lowerAlign = elemLed_.align.toLower();
    if (lowerAlign.contains("right")) {
        x += qMax(0, elemLed_.position.width() - renderedWidth);
    } else if (lowerAlign.contains("center")) {
        x += qMax(0, (elemLed_.position.width() - renderedWidth) / 2);
    }

    int y = elemLed_.position.top();
    if (elemLed_.position.height() >= digitH) {
        y += (elemLed_.position.height() - digitH) / 2;
    }

    return QRect(x, y, renderedWidth, digitH);
}

void PlayerWindow::drawLedTime(QPainter& p, const SkinElement& elem,
                                int64_t timeMs, bool elapsed) {
    // LED 数码显示：number.bmp 作为 "0123456789:-" 的精灵表
    // 每个字符单元的宽度为图像宽度的 1/12
    if (ledDigits_.isNull()) return;

    const int digitW = ledDigits_.width() / 12;
    const int digitH = ledDigits_.height();
    if (digitW <= 0) return;

    int totalSecs = static_cast<int>(std::abs(timeMs) / 1000);
    int mins = totalSecs / 60;
    int secs = totalSecs % 60;

    // 构建显示字符串：已过时间为 "MM:SS"，剩余时间为 "-MM:SS"
    QString timeStr;
    if (!elapsed && timeMs > 0)
        timeStr = QStringLiteral("-%1:%2").arg(mins, 2, 10, QChar('0')).arg(secs, 2, 10, QChar('0'));
    else
        timeStr = QStringLiteral("%1:%2").arg(mins, 2, 10, QChar('0')).arg(secs, 2, 10, QChar('0'));

    const int renderedWidth = timeStr.length() * digitW;

    // 根据元素位置矩形设置水平对齐方式
    int x = elem.position.left();
    const QString lowerAlign = elem.align.toLower();
    if (lowerAlign.contains("right")) {
        x += qMax(0, elem.position.width() - renderedWidth);
    } else if (lowerAlign.contains("center")) {
        x += qMax(0, (elem.position.width() - renderedWidth) / 2);
    }

    // 垂直对齐：使用元素上边缘，当高度足够时居中显示
    int y = elem.position.top();
    if (elem.position.height() >= digitH) {
        y += (elem.position.height() - digitH) / 2;
    }

    for (QChar ch : timeStr) {
        int idx;
        if (ch >= '0' && ch <= '9') idx = ch.unicode() - '0';
        else if (ch == ':') idx = 10;
        else if (ch == '-') idx = 11;
        else continue;

        p.drawPixmap(x, y, ledDigits_, idx * digitW, 0, digitW, digitH);
        x += digitW;
    }
}

// 根据当前播放状态刷新可视化窗口显示模式和封面图。
void PlayerWindow::refreshVisualState() {
    const QString currentTrack = engine_->currentFilePath();
    if (coverArtTrack_ != currentTrack) {
        coverArtTrack_ = currentTrack;
        coverArt_ = loadCoverArt();
    }

    if (!visualWidget_) {
        return;
    }

    visualWidget_->setVisible(visualMode_ != VisualCover && visualMode_ != VisualNone && !elemVisual_.position.isEmpty());
    if (visualMode_ == VisualSpectrum) {
        visualWidget_->setMode(VisualWidget::Spectrum);
    } else if (visualMode_ == VisualBlurScope) {
        visualWidget_->setMode(VisualWidget::BlurScope);
    } else {
        visualWidget_->setMode(VisualWidget::None);
    }
}

// 加载当前曲目的封面，优先使用嵌入封面，其次尝试旁侧封面文件。
QPixmap PlayerWindow::loadCoverArt() const {
    const QByteArray embedded = engine_->currentCoverArt();
    if (!embedded.isEmpty()) {
        QPixmap pixmap;
        if (pixmap.loadFromData(embedded)) {
            return pixmap;
        }
    }

    return loadSidecarCover(engine_->currentFilePath());
}

// 绘制滚动文本信息区域，例如当前播放曲目。
void PlayerWindow::drawInfoText(QPainter& p, const SkinElement& elem, const QString& text) {
    p.save();
    p.setClipRect(elem.position);
    if (elem.bkgndColor.isValid())
        p.fillRect(elem.position, elem.bkgndColor);
    QFont font(elem.fontFamily.isEmpty() ? "SimSun" : elem.fontFamily);
    font.setPixelSize(elem.fontSize > 0 ? elem.fontSize : 12);
    p.setFont(font);
    p.setPen(elem.color);

    // 简单的滚动文本效果
    QFontMetrics fm(font);
    int textW = fm.horizontalAdvance(text);
    int areaW = elem.position.width();
    int x = elem.position.left();
    int y = elem.position.top() + (elem.position.height() + fm.ascent() - fm.descent()) / 2;

    if (textW > areaW) {
        x -= infoScrollOffset_ % (textW + 50);
        p.drawText(x, y, text);
        p.drawText(x + textW + 50, y, text);
    } else {
        if (elem.align.toLower().contains("right")) {
            x += qMax(0, areaW - textW);
        } else if (elem.align.toLower().contains("center")) {
            x += qMax(0, (areaW - textW) / 2);
        }
        p.drawText(x, y, text);
    }
    p.restore();
}

void PlayerWindow::onPlayClicked() {
    if (engine_->state() == AudioEngine::Playing) {
        engine_->pause();
    } else if (engine_->state() == AudioEngine::Paused) {
        engine_->play();
    } else {
        // 如果当前处于停止状态且没有加载文件，则触发打开文件请求
        if (engine_->currentFilePath().isEmpty()) {
            emit openFileRequested();
        } else {
            engine_->play();
        }
    }
}

void PlayerWindow::onStopClicked() {
    engine_->stop();
}

void PlayerWindow::onPrevClicked() {
    emit prevRequested();
}

void PlayerWindow::onNextClicked() {
    emit nextRequested();
}

void PlayerWindow::onStateChanged(AudioEngine::State state) {
    if (btnPlay_ && btnPause_) {
        btnPlay_->setVisible(state != AudioEngine::Playing);
        btnPause_->setVisible(state == AudioEngine::Playing);
    }
    update();
}

void PlayerWindow::onPositionChanged(int64_t posMs) {
    QElapsedTimer totalTimer;
    totalTimer.start();

    qint64 sincePrevMs = -1;
    if (positionClock_.isValid()) {
        const qint64 nowMs = positionClock_.elapsed();
        if (lastPositionSignalMs_ >= 0) {
            sincePrevMs = nowMs - lastPositionSignalMs_;
        }
        lastPositionSignalMs_ = nowMs;
    }

    currentPosMs_ = posMs;
    QElapsedTimer phaseTimer;
    phaseTimer.start();
    if (sliderProgress_ && durationMs_ > 0) {
        sliderProgress_->setValue(static_cast<double>(posMs) / durationMs_);
    }
    const qint64 sliderMs = phaseTimer.elapsed();

    positionPerf_.note(
        totalTimer.elapsed(),
        QStringLiteral("interval_since_prev=%1ms pos=%2 duration=%3 slider_update=%4ms playback=\"%5\" dragging=%6")
            .arg(sincePrevMs)
            .arg(posMs)
            .arg(durationMs_)
            .arg(sliderMs)
            .arg(playbackStateText(engine_))
            .arg(dragSessionActive_ ? 1 : 0));
}

void PlayerWindow::onDurationChanged(int64_t durMs) {
    durationMs_ = durMs;
}

void PlayerWindow::updateDisplay() {
    QElapsedTimer totalTimer;
    totalTimer.start();

    infoScrollOffset_++;

    QElapsedTimer phaseTimer;
    phaseTimer.start();
    refreshVisualState();
    const qint64 refreshVisualMs = phaseTimer.elapsed();

    phaseTimer.restart();
    // 仅请求重绘实际变化的区域，避免半透明皮肤下全窗口合成开销
    if (!elemInfo_.position.isEmpty())
        update(elemInfo_.position);
    if (!elemLed_.position.isEmpty())
        update(ledPaintBounds());
    if (visualMode_ == VisualCover && !elemVisual_.position.isEmpty())
        update(elemVisual_.position);
    const qint64 queueUpdateMs = phaseTimer.elapsed();

    displayPerf_.note(
        totalTimer.elapsed(),
        QStringLiteral("refresh_visual=%1ms queue_update=%2ms playback=\"%3\" dragging=%4 visual_mode=%5 visual_visible=%6")
            .arg(refreshVisualMs)
            .arg(queueUpdateMs)
            .arg(playbackStateText(engine_))
            .arg(dragSessionActive_ ? 1 : 0)
            .arg(static_cast<int>(visualMode_))
            .arg(visualWidget_ && visualWidget_->isVisible() ? 1 : 0));
}

QString PlayerWindow::formatTime(int64_t ms) const {
    int secs = static_cast<int>(ms / 1000);
    return QString("%1:%2").arg(secs / 60, 2, 10, QChar('0')).arg(secs % 60, 2, 10, QChar('0'));
}

void PlayerWindow::contextMenuEvent(QContextMenuEvent* e) {
    emit contextMenuRequested(e->globalPos());
    e->accept();
}

// 窗口拖动处理逻辑
void PlayerWindow::mousePressEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        activateWindow();
        if (!elemVisual_.position.isEmpty() && elemVisual_.position.contains(e->position().toPoint())) {
            visualMode_ = static_cast<VisualMode>((static_cast<int>(visualMode_) + 1) % 4);
            refreshVisualState();
            update(elemVisual_.position);
            e->accept();
            return;
        }
        dragSessionActive_ = true;
        paintPerf_.setEnabled(true, true);
        displayPerf_.setEnabled(true, true);
        positionPerf_.setEnabled(true, true);
        if (visualWidget_) {
            visualWidget_->setPerfLoggingEnabled(true);
        }
        emit dragStarted();
        dragUsingSystemMove_ = false;
        lastMoveEventObserved_ = false;
        lastWindowMovedEmitMs_ = 0;
        const bool useSystemMove =
            !shouldPreferManualMove() && windowHandle() && windowHandle()->startSystemMove();
        dragUsingSystemMove_ = useSystemMove;
        movePerf_.beginSession(useSystemMove ? QStringLiteral("system") : QStringLiteral("manual"),
                               pos(),
                               playbackStateText(engine_));
        if (useSystemMove) {
            e->accept();
            return;
        }
        dragging_ = true;
        dragStartPos_ = e->globalPosition().toPoint() - pos();
        e->accept();
        return;
    }
    QWidget::mousePressEvent(e);
}

void PlayerWindow::mouseMoveEvent(QMouseEvent* e) {
    if (dragging_) {
        const QPoint fromPos = pos();
        const QPoint targetPos = e->globalPosition().toPoint() - dragStartPos_;
        if (targetPos != fromPos) {
            lastMoveEventObserved_ = false;
            lastWindowMovedEmitMs_ = 0;

            QElapsedTimer timer;
            timer.start();
            move(targetPos);
            movePerf_.noteMoveRequest(fromPos,
                                      pos(),
                                      timer.elapsed(),
                                      lastMoveEventObserved_ ? lastWindowMovedEmitMs_ : 0);
        }
        e->accept();
        return;
    }
    QWidget::mouseMoveEvent(e);
}

void PlayerWindow::mouseReleaseEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        dragging_ = false;
        if (dragSessionActive_) {
            dragSessionActive_ = false;
            emit dragFinished();
            movePerf_.endSession(pos(), QStringLiteral("mouse_release"));
        }
        paintPerf_.setEnabled(false);
        displayPerf_.setEnabled(false);
        positionPerf_.setEnabled(false);
        if (visualWidget_) {
            visualWidget_->setPerfLoggingEnabled(false);
        }
        dragUsingSystemMove_ = false;
        lastMoveEventObserved_ = false;
        lastWindowMovedEmitMs_ = 0;
        e->accept();
        return;
    }
    QWidget::mouseReleaseEvent(e);
}

void PlayerWindow::moveEvent(QMoveEvent* e) {
    QWidget::moveEvent(e);
    const QPoint delta = e->pos() - e->oldPos();
    if (!delta.isNull()) {
        QElapsedTimer timer;
        timer.start();
        emit windowMoved(delta);
        lastMoveEventObserved_ = true;
        lastWindowMovedEmitMs_ = timer.elapsed();
        if (movePerf_.active()) {
            movePerf_.noteMoveEvent(e->oldPos(),
                                    e->pos(),
                                    delta,
                                    lastWindowMovedEmitMs_,
                                    dragUsingSystemMove_);
        }
    }
}
