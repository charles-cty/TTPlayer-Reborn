#include "EqualizerWindow.h"
#include <QPainter>
#include <QMouseEvent>
#include <QBitmap>
#include <QGuiApplication>
#include <QWindow>
#include <QMenu>
#include <QAction>
#include <QCursor>
#include <QElapsedTimer>

namespace {
bool shouldPreferManualMove() {
    return QGuiApplication::platformName() == "xcb";
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

// 均衡器窗口构造函数，初始化透明窗口和预设列表。
EqualizerWindow::EqualizerWindow(AudioEngine* engine, QWidget* parent)
    : QWidget(parent, Qt::FramelessWindowHint | Qt::Dialog)
    , engine_(engine)
{
    setAttribute(Qt::WA_TranslucentBackground);
    setMouseTracking(true);
    initPresets();
}

// 初始化默认均衡器预设列表。
void EqualizerWindow::initPresets() {
    presets_ = {
        { QStringLiteral("平坦"),    {  0, 0,  0,  0,  0,  0,  0,  0,  0,  0 }, 0 },
        { QStringLiteral("摇滚"),    {  4, 3, -2, -4, -2,  2,  4,  7,  7,  6 }, 0 },
        { QStringLiteral("流行"),    { -1, 3,  5,  5,  3, -1, -2, -2, -1, -1 }, 0 },
        { QStringLiteral("古典"),    {  4, 4,  3,  3,  0,  0,  0, -3, -3, -4 }, 0 },
        { QStringLiteral("爵士"),    {  0, 0,  0,  3,  3,  3,  0, -2, -2, -2 }, 0 },
        { QStringLiteral("舞曲"),    {  4, 7,  5,  0,  2,  4,  6,  6,  5,  0 }, 0 },
        { QStringLiteral("重金属"),  {  4, 3,  1,  4,  3,  0, -2,  0,  4,  4 }, 0 },
        { QStringLiteral("人声"),    { -2,-2,  0,  2,  5,  5,  3,  1,  0, -1 }, 0 },
        { QStringLiteral("轻音乐"),  {  3, 1,  0, -1, -1,  0,  1,  3,  3,  4 }, 0 },
        { QStringLiteral("低音加强"),{  6, 5,  3,  1,  0,  0,  0,  0,  0,  0 }, 0 },
        { QStringLiteral("高音加强"),{  0, 0,  0,  0,  0,  1,  3,  5,  5,  6 }, 0 },
    };
}

// 显示均衡器预设菜单。
void EqualizerWindow::showProfileMenu() {
    QMenu menu(this);
    for (int i = 0; i < presets_.size(); ++i) {
        QAction* act = menu.addAction(presets_[i].name);
        connect(act, &QAction::triggered, this, [this, i]() {
            applyPreset(presets_[i].bands, presets_[i].preamp);
        });
    }
    QPoint pos = btnProfile_
        ? btnProfile_->mapToGlobal(QPoint(0, btnProfile_->height()))
        : QCursor::pos();
    menu.exec(pos);
}

// 应用指定均衡器预设到滑块和引擎。
void EqualizerWindow::applyPreset(const std::array<double,10>& bands, double preamp) {
    for (int i = 0; i < 10 && i < eqSliders_.size(); ++i) {
        eqSliders_[i]->setValue(bands[i]);
        engine_->dspChain().equalizer.setBandGain(i, bands[i]);
    }
    if (sliderPreamp_) {
        sliderPreamp_->setValue(preamp);
        engine_->dspChain().equalizer.setPreamp(preamp);
    }
}

// 清理旧的皮肤控件，准备重新创建控件。
void EqualizerWindow::resetSkinControls() {
    qDeleteAll(findChildren<SkinButton*>(QString(), Qt::FindDirectChildrenOnly));
    qDeleteAll(findChildren<SkinSlider*>(QString(), Qt::FindDirectChildrenOnly));

    btnEnabled_ = nullptr;
    btnProfile_ = nullptr;
    btnReset_ = nullptr;
    sliderPreamp_ = nullptr;
    sliderBalance_ = nullptr;
    sliderSurround_ = nullptr;
    eqSliders_.clear();
    titlePixmap_ = {};
    titleRect_ = {};
    closeElement_ = {};
}

// 根据均衡器开关状态同步滑块的可用性。
void EqualizerWindow::syncEqualizerControlState(bool enabled) {
    // 原版行为：禁用均衡器时，前置增益和十波段滑块不可用。
    // 但平衡和环绕仍然可用。
    if (sliderPreamp_) {
        sliderPreamp_->setEnabled(enabled);
    }
    for (auto* slider : eqSliders_) {
        if (slider) {
            slider->setEnabled(enabled);
        }
    }
}

// 应用皮肤到均衡器窗口并创建按钮/滑块控件。
void EqualizerWindow::applySkin(const SkinData& skin) {
    const auto& wnd = skin.equalizerWindow;
    auto& equalizer = engine_->dspChain().equalizer;
    resetSkinControls();
    background_ = wnd.backgroundPixmap;
    eqInterval_ = wnd.eqInterval;

    clearMask();
    if (!background_.isNull()) {
        setFixedSize(background_.size());
        QBitmap mask = background_.mask();
        if (!mask.isNull()) setMask(mask);
    }

    for (const auto& elem : wnd.elements) {
        if (elem.type == "title") {
            titleRect_ = elem.position;
            titlePixmap_ = elem.statePixmaps[0];
        }
        else if (elem.type == "close") {
            closeElement_ = elem;
        }
        else if (elem.type == "enabled") {
            btnEnabled_ = new SkinButton(this);
            btnEnabled_->setSkinElement(elem);
            btnEnabled_->move(elem.position.topLeft());
            btnEnabled_->setToggleable(true);
            btnEnabled_->setUsePressedStateForToggle(true);
            btnEnabled_->setLockVisualWhenToggled(true);
            btnEnabled_->setToggled(equalizer.isEnabled());
            btnEnabled_->show();
            connect(btnEnabled_, &SkinButton::toggled, this, [this](bool on) {
                engine_->dspChain().equalizer.setEnabled(on);
                syncEqualizerControlState(on);
            });
        }
        else if (elem.type == "profile") {
            btnProfile_ = new SkinButton(this);
            btnProfile_->setSkinElement(elem);
            btnProfile_->move(elem.position.topLeft());
            btnProfile_->show();
            connect(btnProfile_, &SkinButton::clicked, this, &EqualizerWindow::showProfileMenu);
        }
        else if (elem.type == "reset") {
            btnReset_ = new SkinButton(this);
            btnReset_->setSkinElement(elem);
            btnReset_->move(elem.position.topLeft());
            btnReset_->show();
            connect(btnReset_, &SkinButton::clicked, this, [this]() {
                applyPreset({0,0,0,0,0,0,0,0,0,0}, 0);
            });
        }
        else if (elem.type == "preamp") {
            sliderPreamp_ = new SkinSlider(this);
            sliderPreamp_->setSkinElement(elem);
            sliderPreamp_->move(elem.position.topLeft());
            sliderPreamp_->setVertical(true);
            sliderPreamp_->setRange(-12, 12);
            sliderPreamp_->setValue(equalizer.preamp());
            sliderPreamp_->show();
            connect(sliderPreamp_, &SkinSlider::valueChanged, this, [this](double v) {
                engine_->dspChain().equalizer.setPreamp(v);
            });
        }
        else if (elem.type == "balance") {
            sliderBalance_ = new SkinSlider(this);
            sliderBalance_->setSkinElement(elem);
            sliderBalance_->move(elem.position.topLeft());
            sliderBalance_->setRange(-100, 100);
            sliderBalance_->setValue(engine_->dspChain().balance() * 100.0);
            sliderBalance_->show();
            connect(sliderBalance_, &SkinSlider::valueChanged, this, [this](double v) {
                engine_->setBalance(static_cast<int>(v));
            });
        }
        else if (elem.type == "surround") {
            sliderSurround_ = new SkinSlider(this);
            sliderSurround_->setSkinElement(elem);
            sliderSurround_->move(elem.position.topLeft());
            sliderSurround_->setRange(0, 100);
            sliderSurround_->setValue(surroundValue_);
            sliderSurround_->show();
            connect(sliderSurround_, &SkinSlider::valueChanged, this, [this](double v) {
                surroundValue_ = v;
            });
        }
        else if (elem.type == "eqfactor") {
            for (int band = 0; band < 10; ++band) {
                auto* slider = new SkinSlider(this);
                slider->setSkinElement(elem);
                int x = elem.position.left() + band * (elem.position.width() + eqInterval_);
                slider->move(x, elem.position.top());
                slider->setVertical(true);
                slider->setRange(-12, 12);
                slider->setValue(equalizer.bandGain(band));
                slider->show();
                connect(slider, &SkinSlider::valueChanged, this, [this, band](double v) {
                    engine_->dspChain().equalizer.setBandGain(band, v);
                });
                eqSliders_.append(slider);
            }
        }
    }

    // 关闭按钮（部分皮肤包含此按钮）
    if (!closeElement_.position.isEmpty()) {
        auto* btnClose = new SkinButton(this);
        btnClose->setSkinElement(closeElement_);
        btnClose->move(closeElement_.position.topLeft());
        btnClose->show();
        connect(btnClose, &SkinButton::clicked, this, [this]() {
            emit closeRequested();
        });
    }

    syncEqualizerControlState(equalizer.isEnabled());

    update();
}

void EqualizerWindow::paintEvent(QPaintEvent*) {
    QPainter p(this);
    if (!background_.isNull())
        p.drawPixmap(0, 0, background_);
    if (!titlePixmap_.isNull())
        p.drawPixmap(titleRect_.topLeft(), titlePixmap_);
}

void EqualizerWindow::moveEvent(QMoveEvent* e) {
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

void EqualizerWindow::showEvent(QShowEvent* e) {
    QWidget::showEvent(e);
    emit visibilityChanged(true);
}

void EqualizerWindow::hideEvent(QHideEvent* e) {
    QWidget::hideEvent(e);
    emit visibilityChanged(false);
}

void EqualizerWindow::mousePressEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        dragSessionActive_ = true;
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
        dragStart_ = e->globalPosition().toPoint() - pos();
        e->accept();
        return;
    }
}

void EqualizerWindow::mouseMoveEvent(QMouseEvent* e) {
    if (dragging_) {
        const QPoint fromPos = pos();
        const QPoint targetPos = e->globalPosition().toPoint() - dragStart_;
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
    }
}

void EqualizerWindow::mouseReleaseEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        dragging_ = false;
        if (dragSessionActive_) {
            dragSessionActive_ = false;
            emit dragFinished();
            movePerf_.endSession(pos(), QStringLiteral("mouse_release"));
        }
        dragUsingSystemMove_ = false;
        lastMoveEventObserved_ = false;
        lastWindowMovedEmitMs_ = 0;
    }
}
