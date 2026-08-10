#pragma once
#include "SkinData.h"
#include <QWidget>
#include <QPainter>
#include <QMouseEvent>

// 皮肤按钮控件，从状态图集渲染普通、悬停、按下和禁用状态。
class SkinButton : public QWidget {
    Q_OBJECT
public:
    explicit SkinButton(QWidget* parent = nullptr);

    // 设置按钮的皮肤元素，包括不同状态的图像。
    void setSkinElement(const SkinElement& element);
    // 设置控件是否支持切换状态。
    void setToggleable(bool t) { toggleable_ = t; }
    // 设置切换状态并刷新显示。
    void setToggled(bool t) { toggled_ = t; update(); }
    // 切换时是否使用按下状态作为可视化效果。
    void setUsePressedStateForToggle(bool on) { usePressedStateForToggle_ = on; update(); }
    // 切换时是否锁定视觉状态为按下。
    void setLockVisualWhenToggled(bool on) { lockVisualWhenToggled_ = on; update(); }
    bool isToggled() const { return toggled_; }

signals:
    void clicked();
    void toggled(bool checked);

protected:
    void paintEvent(QPaintEvent* event) override;
    void enterEvent(QEnterEvent* event) override;
    void leaveEvent(QEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;

private:
    int currentState() const;

    QPixmap states_[4];  // 正常、悬停、按下、禁用 状态图
    QString align_;
    int stateCount_ = 1;
    bool hovered_ = false;
    bool pressed_ = false;
    bool toggleable_ = false;
    bool toggled_ = false;
    bool usePressedStateForToggle_ = false;
    bool lockVisualWhenToggled_ = false;
};

// 皮肤滑块控件，用于进度条、音量和均衡器滑块。
class SkinSlider : public QWidget {
    Q_OBJECT
public:
    explicit SkinSlider(QWidget* parent = nullptr);

    void setSkinElement(const SkinElement& element);
    void setRange(double min, double max);
    void setValue(double value);
    double value() const { return value_; }
    void setVertical(bool v) { vertical_ = v; update(); }

signals:
    void valueChanged(double value);
    void sliderPressed();
    void sliderReleased();

protected:
    void paintEvent(QPaintEvent* event) override;
    void enterEvent(QEnterEvent* event) override;
    void leaveEvent(QEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;

private:
    double positionToValue(int pos) const;
    int valueToPosition(double val) const;

    QPixmap barPixmap_;
    QPixmap thumbPixmaps_[4];
    QPixmap fillPixmap_;
    bool vertical_ = false;
    double min_ = 0, max_ = 1.0, value_ = 0;
    bool dragging_ = false;
    bool hovered_ = false;
};
