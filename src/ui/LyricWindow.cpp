#include "LyricWindow.h"
#include <QPainter>
#include <QMouseEvent>
#include <QBitmap>
#include <QFile>
#include <QGuiApplication>
#include <QWindow>
#include <QCursor>
#include <QContextMenuEvent>
#include <QMenu>
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

QRect alignedRect(const QRect& baseRect, const QSize& baseSize, const QSize& currentSize,
                  const QString& align, const QSize& contentSize = {}) {
    const QSize finalSize = contentSize.isValid() ? contentSize : baseRect.size();
    QRect rect(baseRect.topLeft(), finalSize);
    const QString lowerAlign = align.toLower();

    if (lowerAlign.contains("center")) {
        rect.moveLeft((currentSize.width() - rect.width()) / 2);
    } else if (lowerAlign.contains("right")) {
        const int rightMargin = baseSize.width() - (baseRect.x() + baseRect.width());
        rect.moveLeft(currentSize.width() - rightMargin - rect.width());
    }

    if (lowerAlign.contains("bottom")) {
        const int bottomMargin = baseSize.height() - (baseRect.y() + baseRect.height());
        rect.moveTop(currentSize.height() - bottomMargin - rect.height());
    }

    return rect;
}

void drawHTiled(QPainter& painter, const QPixmap& tile, const QRect& rect) {
    if (tile.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    for (int x = rect.left(); x <= rect.right(); x += tile.width()) {
        const int drawW = qMin(tile.width(), rect.right() - x + 1);
        painter.drawPixmap(QRect(x, rect.top(), drawW, rect.height()), tile,
                           QRect(0, 0, drawW, tile.height()));
    }
}

void drawVTiled(QPainter& painter, const QPixmap& tile, const QRect& rect) {
    if (tile.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    for (int y = rect.top(); y <= rect.bottom(); y += tile.height()) {
        const int drawH = qMin(tile.height(), rect.bottom() - y + 1);
        painter.drawPixmap(QRect(rect.left(), y, rect.width(), drawH), tile,
                           QRect(0, 0, tile.width(), drawH));
    }
}

void drawTiled(QPainter& painter, const QPixmap& tile, const QRect& rect) {
    if (tile.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    for (int y = rect.top(); y <= rect.bottom(); y += tile.height()) {
        const int drawH = qMin(tile.height(), rect.bottom() - y + 1);
        for (int x = rect.left(); x <= rect.right(); x += tile.width()) {
            const int drawW = qMin(tile.width(), rect.right() - x + 1);
            painter.drawPixmap(QRect(x, y, drawW, drawH), tile,
                               QRect(0, 0, drawW, drawH));
        }
    }
}

void drawHorizontalSlice(QPainter& painter, const QPixmap& slice, const QRect& rect, bool tiled) {
    if (slice.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    if (tiled) {
        drawHTiled(painter, slice, rect);
    } else {
        painter.drawPixmap(rect, slice);
    }
}

void drawVerticalSlice(QPainter& painter, const QPixmap& slice, const QRect& rect, bool tiled) {
    if (slice.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    if (tiled) {
        drawVTiled(painter, slice, rect);
    } else {
        painter.drawPixmap(rect, slice);
    }
}

void drawCenterSlice(QPainter& painter, const QPixmap& slice, const QRect& rect, bool tiled) {
    if (slice.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    if (tiled) {
        drawTiled(painter, slice, rect);
    } else {
        painter.drawPixmap(rect, slice);
    }
}
}

// 构造歌词窗口，初始化透明背景、鼠标跟踪和歌词刷新定时器。
LyricWindow::LyricWindow(AudioEngine* engine, QWidget* parent)
    : QWidget(parent, Qt::FramelessWindowHint | Qt::Tool)
    , engine_(engine)
{
    setAttribute(Qt::WA_TranslucentBackground);
    setMouseTracking(true);
    setMinimumWidth(200);

    timer_ = new QTimer(this);
    timer_->setInterval(100);
    connect(timer_, &QTimer::timeout, this, &LyricWindow::updateLyric);
    timer_->start();
}

// 应用皮肤到歌词窗口，构建背景、按钮和文本样式。
void LyricWindow::applySkin(const SkinData& skin) {
    const auto& wnd = skin.lyricWindow;

    qDeleteAll(findChildren<SkinButton*>(QString(), Qt::FindDirectChildrenOnly));
    closeButton_ = nullptr;
    ontopButton_ = nullptr;

    // 应用 Lyric.xml 配置中的颜色和字体
    textColor_   = skin.lyricConfig.textColor;
    hilightColor_ = skin.lyricConfig.hilightColor;
    bkgndColor_  = skin.lyricConfig.bkgndColor;
    lyricFont_   = skin.lyricConfig.font;

    baseBackground_ = wnd.backgroundPixmap;
    baseSize_ = baseBackground_.isNull() ? QSize(268, 165) : baseBackground_.size();
    resizeRect_  = wnd.resizeRect;
    resizeTile_  = wnd.resizeTile;
    titlePixmap_ = {};
    titleRect_ = {};
    titleAlign_.clear();
    closeElement_ = {};
    ontopElement_ = {};
    elemLyric_ = {};

    for (const auto& elem : wnd.elements) {
        if (elem.type == "lyric") {
            elemLyric_ = elem;
        } else if (elem.type == "title") {
            titleRect_ = elem.position;
            titlePixmap_ = elem.statePixmaps[0];
            titleAlign_ = elem.align;
        } else if (elem.type == "close") {
            closeElement_ = elem;
        } else if (elem.type == "ontop") {
            ontopElement_ = elem;
        }
    }

    if (!closeElement_.position.isEmpty()) {
        closeButton_ = new SkinButton(this);
        connect(closeButton_, &SkinButton::clicked, this, [this]() {
            emit closeRequested();
        });
        closeButton_->setSkinElement(closeElement_);
        closeButton_->show();
    }
    if (!ontopElement_.position.isEmpty()) {
        ontopButton_ = new SkinButton(this);
        ontopButton_->setSkinElement(ontopElement_);
        ontopButton_->setToggleable(true);
        ontopButton_->setUsePressedStateForToggle(true);
        ontopButton_->setToggled(alwaysOnTop_);
        ontopButton_->show();
        connect(ontopButton_, &SkinButton::toggled, this, [this](bool enabled) {
            alwaysOnTop_ = enabled;
            emit alwaysOnTopToggled(enabled);
        });
    }

    setMinimumSize(baseSize_);
    setMaximumSize(QWIDGETSIZE_MAX, QWIDGETSIZE_MAX);
    // 不要在这里调用 resize()，layoutFromSkin() 会设置正确的尺寸。
    // 在 X11 上直接 resize(baseSize_) 可能导致窗口管理器异步应用较小尺寸，
    // 并在最终布局完成后再覆盖它。

    rebuildBackground();
    updateChromeGeometry();
    update();
}

// 设置置顶按钮状态并同步内部标志。
void LyricWindow::setAlwaysOnTopState(bool enabled) {
    alwaysOnTop_ = enabled;
    if (ontopButton_) {
        ontopButton_->setToggled(enabled);
    }
}

// 根据当前窗口大小和 9 宫格内容重建背景图像。
void LyricWindow::rebuildBackground() {
    if (baseBackground_.isNull()) {
        background_ = QPixmap(size());
        background_.fill(Qt::transparent);
        return;
    }

    if (resizeRect_.isEmpty()) {
        background_ = baseBackground_;
        return;
    }

    const int left = resizeRect_.left();
    const int top = resizeRect_.top();
    const int centerW = resizeRect_.width();
    const int centerH = resizeRect_.height();
    const int right = baseBackground_.width() - (resizeRect_.x() + resizeRect_.width());
    const int bottom = baseBackground_.height() - (resizeRect_.y() + resizeRect_.height());

    background_ = QPixmap(size());
    background_.fill(Qt::transparent);
    QPainter p(&background_);

    const QPixmap topLeft = baseBackground_.copy(0, 0, left, top);
    const QPixmap topMid = baseBackground_.copy(left, 0, centerW, top);
    const QPixmap topRight = baseBackground_.copy(baseBackground_.width() - right, 0, right, top);
    const QPixmap midLeft = baseBackground_.copy(0, top, left, centerH);
    const QPixmap mid = baseBackground_.copy(left, top, centerW, centerH);
    const QPixmap midRight = baseBackground_.copy(baseBackground_.width() - right, top, right, centerH);
    const QPixmap bottomLeft = baseBackground_.copy(0, baseBackground_.height() - bottom, left, bottom);
    const QPixmap bottomMid = baseBackground_.copy(left, baseBackground_.height() - bottom, centerW, bottom);
    const QPixmap bottomRight = baseBackground_.copy(baseBackground_.width() - right, baseBackground_.height() - bottom, right, bottom);

    p.drawPixmap(0, 0, topLeft);
    p.drawPixmap(width() - right, 0, topRight);
    p.drawPixmap(0, height() - bottom, bottomLeft);
    p.drawPixmap(width() - right, height() - bottom, bottomRight);

    drawHorizontalSlice(p, topMid, QRect(left, 0, width() - left - right, top), resizeTile_);
    drawHorizontalSlice(p, bottomMid, QRect(left, height() - bottom, width() - left - right, bottom), resizeTile_);
    drawVerticalSlice(p, midLeft, QRect(0, top, left, height() - top - bottom), resizeTile_);
    drawVerticalSlice(p, midRight, QRect(width() - right, top, right, height() - top - bottom), resizeTile_);
    drawCenterSlice(p, mid, QRect(left, top, width() - left - right, height() - top - bottom), resizeTile_);
}

// 更新关闭按钮和置顶按钮的位置，同时更新窗口遮罩。
void LyricWindow::updateChromeGeometry() {
    if (closeButton_ && !closeElement_.position.isEmpty()) {
        closeButton_->move(alignedRect(closeElement_.position, baseSize_, size(),
                                       closeElement_.align, closeButton_->size()).topLeft());
    }
    if (ontopButton_ && !ontopElement_.position.isEmpty()) {
        ontopButton_->move(alignedRect(ontopElement_.position, baseSize_, size(),
                                       ontopElement_.align, ontopButton_->size()).topLeft());
    }

    clearMask();
    if (!background_.isNull()) {
        const QBitmap mask = background_.mask();
        if (!mask.isNull()) {
            setMask(mask);
        }
    }
}

// 计算歌词文本绘制区域。
QRect LyricWindow::lyricArea() const {
    if (elemLyric_.position.isEmpty()) {
        return QRect(8, 28, width() - 16, height() - 36);
    }

    const int rightMargin = baseSize_.width() - (elemLyric_.position.x() + elemLyric_.position.width());
    const int bottomMargin = baseSize_.height() - (elemLyric_.position.y() + elemLyric_.position.height());
    return QRect(elemLyric_.position.x(), elemLyric_.position.y(),
                 qMax(1, width() - elemLyric_.position.x() - rightMargin),
                 qMax(1, height() - elemLyric_.position.y() - bottomMargin));
}

// 计算标题显示区域的位置。
QRect LyricWindow::titleDrawRect() const {
    const QSize titleSize = titlePixmap_.isNull() ? titleRect_.size() : titlePixmap_.size();
    return alignedRect(titleRect_, baseSize_, size(), titleAlign_, titleSize);
}

// 根据鼠标位置判断当前是否处于可调整大小的边缘区域。
Qt::Edges LyricWindow::resizeEdgesForPosition(const QPoint& pos) const {
    if (resizeRect_.isEmpty()) {
        return {};
    }

    Qt::Edges edges;
    if (pos.x() >= width() - 8) {
        edges |= Qt::RightEdge;
    }
    if (pos.y() >= height() - 8) {
        edges |= Qt::BottomEdge;
    }
    return edges;
}

// 重新解析当前歌词原始数据，并应用时间偏移。
void LyricWindow::reparseCurrentLyric() {
    if (currentLrcRawData_.isEmpty()) {
        lrcData_ = LrcData{};
        update();
        return;
    }

    LrcParser parser;
    lrcData_ = parser.parse(currentLrcRawData_, currentEncoding_);
    if (currentOffsetMs_ != 0) {
        for (auto& line : lrcData_.lines) {
            line.timeMs += currentOffsetMs_;
        }
        lrcData_.offset += currentOffsetMs_;
    }
    update();
}

// 从指定路径加载 LRC 文件并解析歌词数据。
bool LyricWindow::loadLrc(const QString& path, LrcParser::Encoding encoding) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    currentLrcPath_ = path;
    currentLrcRawData_ = f.readAll();
    currentEncoding_ = encoding;
    currentOffsetMs_ = 0;
    reparseCurrentLyric();
    return !lrcData_.lines.isEmpty();
}

// 清空当前歌词数据并刷新显示。
void LyricWindow::clearLrc() {
    currentLrcPath_.clear();
    currentLrcRawData_.clear();
    currentOffsetMs_ = 0;
    lrcData_ = LrcData{};
    update();
}

// 更新无歌词时显示的曲目信息。
void LyricWindow::setTrackInfo(const QString& title, const QString& artist) {
    trackTitle_  = title;
    trackArtist_ = artist;
    update();
}

// 定时刷新歌词显示。
void LyricWindow::updateLyric() {
    if (isVisible()) update();
}

// 绘制歌词窗口的背景与歌词文本。
void LyricWindow::paintEvent(QPaintEvent*) {
    QPainter p(this);

    if (!background_.isNull())
        p.drawPixmap(0, 0, background_);
    else
        p.fillRect(rect(), bkgndColor_);

    const QRect titleDraw = titleDrawRect();
    if (!titlePixmap_.isNull()) {
        p.drawPixmap(titleDraw.topLeft(), titlePixmap_);
    }

    const QRect contentRect = lyricArea();

    p.setClipRect(contentRect);
    p.setFont(lyricFont_);
    QFontMetrics fm(lyricFont_);
    int lineH = fm.height() + 4;

    if (lrcData_.lines.isEmpty()) {
        // 没有歌词时显示曲目信息或占位文本
        p.setPen(textColor_);
        QString info;
        if (!trackTitle_.isEmpty()) {
            info = trackArtist_.isEmpty() ? trackTitle_ : trackArtist_ + " - " + trackTitle_;
        } else {
            info = QStringLiteral("暂无歌词");
        }
        p.drawText(contentRect, Qt::AlignCenter, info);
        return;
    }

    int64_t pos = engine_->positionMs();
    int currentLine = -1;
    for (int i = 0; i < lrcData_.lines.size(); ++i) {
        if (lrcData_.lines[i].timeMs <= pos)
            currentLine = i;
    }

    int visibleLines = qMax(1, contentRect.height() / lineH);
    int startLine = currentLine - visibleLines / 2;
    int endLine   = startLine + visibleLines;

    for (int i = startLine; i <= endLine && i < lrcData_.lines.size(); ++i) {
        if (i < 0) continue;
        int y = contentRect.top() + (i - startLine) * lineH;
        bool isCurrent = (i == currentLine);
        p.setPen(isCurrent ? hilightColor_ : textColor_);
        p.drawText(contentRect.left(), y, contentRect.width(), lineH,
                   Qt::AlignHCenter | Qt::AlignVCenter, lrcData_.lines[i].text);
    }
}

void LyricWindow::resizeEvent(QResizeEvent* e) {
    QWidget::resizeEvent(e);
    rebuildBackground();
    updateChromeGeometry();
}

void LyricWindow::moveEvent(QMoveEvent* e) {
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

void LyricWindow::showEvent(QShowEvent* e) {
    QWidget::showEvent(e);
    emit visibilityChanged(true);
}

void LyricWindow::hideEvent(QHideEvent* e) {
    QWidget::hideEvent(e);
    emit visibilityChanged(false);
}

void LyricWindow::mousePressEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        resizeEdges_ = resizeEdgesForPosition(e->position().toPoint());
        if (resizeEdges_ != Qt::Edges()) {
            resizeStartGlobalPos_ = e->globalPosition().toPoint();
            resizeStartSize_ = size();
            e->accept();
            return;
        }
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

void LyricWindow::mouseMoveEvent(QMouseEvent* e) {
    if (resizeEdges_ != Qt::Edges()) {
        const QPoint delta = e->globalPosition().toPoint() - resizeStartGlobalPos_;
        int newWidth = resizeStartSize_.width();
        int newHeight = resizeStartSize_.height();
        if (resizeEdges_.testFlag(Qt::RightEdge)) {
            newWidth += delta.x();
        }
        if (resizeEdges_.testFlag(Qt::BottomEdge)) {
            newHeight += delta.y();
        }
        resize(qMax(minimumWidth(), newWidth), qMax(minimumHeight(), newHeight));
        emit resizeInProgress(resizeEdges_);
    } else if (dragging_) {
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
    } else {
        const Qt::Edges edges = resizeEdgesForPosition(e->position().toPoint());
        if (edges == (Qt::RightEdge | Qt::BottomEdge)) {
            setCursor(Qt::SizeFDiagCursor);
        } else if (edges == Qt::RightEdge) {
            setCursor(Qt::SizeHorCursor);
        } else if (edges == Qt::BottomEdge) {
            setCursor(Qt::SizeVerCursor);
        } else {
            unsetCursor();
        }
    }
}

void LyricWindow::mouseReleaseEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        const Qt::Edges resizeEdges = resizeEdges_;
        resizeEdges_ = {};
        dragging_ = false;
        if (resizeEdges != Qt::Edges()) {
            emit resizeFinished(resizeEdges);
        }
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

void LyricWindow::contextMenuEvent(QContextMenuEvent* e) {
    QMenu menu(this);

    // 编码切换子菜单
    QMenu* encodingMenu = menu.addMenu(QStringLiteral("歌词编码(&E)"));
    for (const auto& [enc, name] : LrcParser::availableEncodings()) {
        QAction* act = encodingMenu->addAction(name);
        act->setCheckable(true);
        act->setChecked(enc == currentEncoding_);
        connect(act, &QAction::triggered, this, [this, enc]() {
            if (!currentLrcRawData_.isEmpty()) {
                currentEncoding_ = enc;
                reparseCurrentLyric();
            }
        });
    }

    menu.addSeparator();

    QMenu* offsetMenu = menu.addMenu(QStringLiteral("歌词时间偏移(&O)"));
    QAction* offsetInfo = offsetMenu->addAction(QStringLiteral("当前偏移: %1 ms").arg(currentOffsetMs_));
    offsetInfo->setEnabled(false);
    offsetMenu->addSeparator();

    auto addOffsetAction = [this, offsetMenu](const QString& text, int deltaMs) {
        QAction* action = offsetMenu->addAction(text);
        action->setEnabled(!currentLrcRawData_.isEmpty());
        connect(action, &QAction::triggered, this, [this, deltaMs]() {
            currentOffsetMs_ += deltaMs;
            reparseCurrentLyric();
        });
    };

    addOffsetAction(QStringLiteral("提前 0.5s"), -500);
    addOffsetAction(QStringLiteral("延后 0.5s"), 500);

    QAction* resetOffset = offsetMenu->addAction(QStringLiteral("重置偏移"));
    resetOffset->setEnabled(!currentLrcRawData_.isEmpty() && currentOffsetMs_ != 0);
    connect(resetOffset, &QAction::triggered, this, [this]() {
        currentOffsetMs_ = 0;
        reparseCurrentLyric();
    });

    menu.addSeparator();
    menu.addAction(QStringLiteral("关闭"), this, [this]() {
        emit closeRequested();
    });

    menu.exec(e->globalPos());
    e->accept();
}
