#include "SkinButton.h"
#include <QPainter>

// ============ SkinButton ============

// 构造皮肤按钮，设置透明背景和手型光标。
SkinButton::SkinButton(QWidget* parent) : QWidget(parent) {
    setMouseTracking(true);
    setAttribute(Qt::WA_TranslucentBackground);
    setCursor(Qt::PointingHandCursor);
}

// 设置按钮的皮肤元素并根据状态图设置固定大小。
void SkinButton::setSkinElement(const SkinElement& element) {
    hovered_ = false;
    pressed_ = false;
    toggled_ = false;
    align_ = element.align;
    for (int i = 0; i < 4; ++i)
        states_[i] = element.statePixmaps[i];
    stateCount_ = element.stateCount;

    QSize buttonSize;
    const QString lowerAlign = align_.toLower();
    const bool useAlignedAnchor = lowerAlign.contains("right") ||
                                  lowerAlign.contains("center") ||
                                  lowerAlign.contains("bottom");
    for (int i = 0; i < stateCount_; ++i) {
        if (!states_[i].isNull()) {
            buttonSize = buttonSize.expandedTo(states_[i].size());
        }
    }
    if (!buttonSize.isValid()) {
        buttonSize = element.position.size();
    } else if (!useAlignedAnchor && !element.useFrameSizeForBounds) {
        buttonSize = element.position.size().expandedTo(buttonSize);
    }

    setFixedSize(buttonSize);
    update();
}

int SkinButton::currentState() const {
    if (!isEnabled()) return 3;  // 已禁用
    if (toggleable_ && toggled_ && usePressedStateForToggle_ && lockVisualWhenToggled_) {
        return 2; // 锁定到切换视觉（按下状态）
    }
    if (pressed_) return 2;  // 按下
    if (hovered_) return 1;  // 悬停
    if (toggleable_ && toggled_ && usePressedStateForToggle_) return 2;
    return 0; // 正常
}

void SkinButton::paintEvent(QPaintEvent*) {
    QPainter p(this);
    int state = currentState();
    if (state >= stateCount_) state = 0;
    if (!states_[state].isNull()) {
        const QPixmap& pixmap = states_[state];
        int drawX = 0;
        int drawY = 0;
        const QString lowerAlign = align_.toLower();
        if (lowerAlign.contains("center")) {
            drawX = (width() - pixmap.width()) / 2;
        } else if (lowerAlign.contains("right")) {
            drawX = width() - pixmap.width();
        }
        if (lowerAlign.contains("bottom")) {
            drawY = height() - pixmap.height();
        }
        // 默认以 XML 左上角为锚点；仅在显式 align 时才进行偏移。
        p.drawPixmap(drawX, drawY, pixmap);
    }
}

void SkinButton::enterEvent(QEnterEvent*) {
    hovered_ = true;
    update();
}

void SkinButton::leaveEvent(QEvent*) {
    hovered_ = false;
    update();
}

void SkinButton::mousePressEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        pressed_ = true;
        update();
    }
}

void SkinButton::mouseReleaseEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton && pressed_) {
        pressed_ = false;
        if (rect().contains(e->pos())) {
            if (toggleable_) {
                toggled_ = !toggled_;
                emit toggled(toggled_);
            }
            emit clicked();
        }
        update();
    }
}

// ============ SkinSlider ============

SkinSlider::SkinSlider(QWidget* parent) : QWidget(parent) {
    setMouseTracking(true);
    setAttribute(Qt::WA_TranslucentBackground);
}

void SkinSlider::setSkinElement(const SkinElement& element) {
    dragging_ = false;
    hovered_ = false;
    barPixmap_ = element.barPixmap;
    for (int i = 0; i < 4; ++i)
        thumbPixmaps_[i] = element.thumbPixmaps[i];
    fillPixmap_ = element.fillPixmap;
    vertical_ = element.vertical;
    setFixedSize(element.position.size());
    update();
}

void SkinSlider::setRange(double min, double max) {
    min_ = min;
    max_ = max;
}

void SkinSlider::setValue(double value) {
    value_ = qBound(min_, value, max_);
    update();
}

void SkinSlider::paintEvent(QPaintEvent*) {
    QPainter p(this);

    // 以原始大小居中绘制滑块背景
    if (!barPixmap_.isNull()) {
        if (vertical_) {
            int xOff = (width() - barPixmap_.width()) / 2;
            // 如果背景条比控件短则垂直平铺
            for (int y = 0; y < height(); y += barPixmap_.height())
                p.drawPixmap(xOff, y, barPixmap_);
        } else {
            int yOff = (height() - barPixmap_.height()) / 2;
            // 如果背景条比控件短则水平平铺
            for (int x = 0; x < width(); x += barPixmap_.width())
                p.drawPixmap(x, yOff, barPixmap_);
        }
    }

    // 绘制填充效果
    double ratio = (max_ > min_) ? (value_ - min_) / (max_ - min_) : 0;
    if (!fillPixmap_.isNull()) {
        if (vertical_) {
            int fillH = static_cast<int>(height() * ratio);
            int yOff = (width() - fillPixmap_.width()) / 2;
            // 从底部绘制，使用原始宽度，并裁剪到 fillH
            p.drawPixmap(yOff, height() - fillH, fillPixmap_.width(), fillH,
                         fillPixmap_, 0, fillPixmap_.height() - fillH,
                         fillPixmap_.width(), fillH);
        } else {
            int fillW = static_cast<int>(width() * ratio);
            int yOff = (height() - fillPixmap_.height()) / 2;
            // 绘制左侧部分，保持原始高度
            p.drawPixmap(0, yOff, fillW, fillPixmap_.height(),
                         fillPixmap_, 0, 0, fillW, fillPixmap_.height());
        }
    }

    // 以原始大小绘制滑块拇指
    int state = 0;
    if (!isEnabled()) {
        state = 3;
    } else if (dragging_) {
        state = 2;
    } else if (hovered_) {
        state = 1;
    }
    if (state > 0 && thumbPixmaps_[state].isNull()) {
        state = 0;
    }
    QPixmap thumb = thumbPixmaps_[state];
    if (!thumb.isNull()) {
        int thumbW = thumb.width();
        int thumbH = thumb.height();
        if (vertical_) {
            int pos = height() - static_cast<int>(ratio * height()) - thumbH / 2;
            pos = qBound(0, pos, height() - thumbH);
            p.drawPixmap((width() - thumbW) / 2, pos, thumb);
        } else {
            int pos = static_cast<int>(ratio * (width() - thumbW));
            pos = qBound(0, pos, width() - thumbW);
            p.drawPixmap(pos, (height() - thumbH) / 2, thumb);
        }
    }
}

void SkinSlider::enterEvent(QEnterEvent*) {
    hovered_ = true;
    update();
}

void SkinSlider::leaveEvent(QEvent*) {
    hovered_ = false;
    update();
}

void SkinSlider::mousePressEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        dragging_ = true;
        value_ = positionToValue(vertical_ ? e->pos().y() : e->pos().x());
        emit sliderPressed();
        emit valueChanged(value_);
        update();
    }
}

void SkinSlider::mouseMoveEvent(QMouseEvent* e) {
    if (dragging_) {
        value_ = positionToValue(vertical_ ? e->pos().y() : e->pos().x());
        emit valueChanged(value_);
        update();
    }
}

void SkinSlider::mouseReleaseEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton && dragging_) {
        dragging_ = false;
        emit sliderReleased();
        update();
    }
}

double SkinSlider::positionToValue(int pos) const {
    double ratio;
    if (vertical_) {
        ratio = 1.0 - static_cast<double>(pos) / height();
    } else {
        ratio = static_cast<double>(pos) / width();
    }
    ratio = qBound(0.0, ratio, 1.0);
    return min_ + ratio * (max_ - min_);
}

int SkinSlider::valueToPosition(double val) const {
    double ratio = (max_ > min_) ? (val - min_) / (max_ - min_) : 0;
    if (vertical_)
        return static_cast<int>((1.0 - ratio) * height());
    return static_cast<int>(ratio * width());
}
