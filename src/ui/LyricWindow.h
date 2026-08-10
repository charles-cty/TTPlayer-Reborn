#pragma once
#include "skin/SkinData.h"
#include "skin/SkinButton.h"
#include "audio/AudioEngine.h"
#include "lyric/LrcParser.h"
#include "WindowMovePerfLogger.h"
#include <QWidget>
#include <QTimer>
#include <QPixmap>

// 歌词窗口，显示 LRC 歌词并支持窗口拖动、置顶和上下文菜单。
class LyricWindow : public QWidget {
    Q_OBJECT
public:
    explicit LyricWindow(AudioEngine* engine, QWidget* parent = nullptr);
    // 将皮肤应用到歌词窗口。
    void applySkin(const SkinData& skin);
    // 设置窗口置顶状态。
    void setAlwaysOnTopState(bool enabled);
    // 加载 LRC 歌词文件。
    bool loadLrc(const QString& path, LrcParser::Encoding encoding = LrcParser::AutoDetect);
    // 清空当前歌词数据。
    void clearLrc();
    // 设置当前曲目标题和艺术家显示信息。
    void setTrackInfo(const QString& title, const QString& artist);

signals:
    void windowMoved(QPoint delta);
    void dragStarted();
    void dragFinished();
    void resizeInProgress(Qt::Edges edges);
    void resizeFinished(Qt::Edges edges);
    void alwaysOnTopToggled(bool enabled);
    void closeRequested();
    void visibilityChanged(bool visible);

protected:
    void paintEvent(QPaintEvent*) override;
    void mousePressEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void resizeEvent(QResizeEvent*) override;
    void moveEvent(QMoveEvent*) override;
    void showEvent(QShowEvent*) override;
    void hideEvent(QHideEvent*) override;
    void contextMenuEvent(QContextMenuEvent*) override;

private slots:
    void updateLyric();

private:
    void reparseCurrentLyric();
    void rebuildBackground();
    void updateChromeGeometry();
    QRect lyricArea() const;
    QRect titleDrawRect() const;
    Qt::Edges resizeEdgesForPosition(const QPoint& pos) const;

    AudioEngine* engine_;

    // 皮肤资源
    QPixmap baseBackground_;
    QPixmap background_;
    QPixmap titlePixmap_;
    QRect titleRect_;
    QString titleAlign_;
    QRect resizeRect_;
    SkinElement closeElement_;
    SkinElement ontopElement_;
    SkinButton* closeButton_ = nullptr;
    SkinButton* ontopButton_ = nullptr;
    bool resizeTile_ = false;
    QSize baseSize_{200, 100};
    bool alwaysOnTop_ = false;

    SkinElement elemLyric_;
    LrcData lrcData_;

    // 歌词编码
    QString currentLrcPath_;
    QByteArray currentLrcRawData_;
    LrcParser::Encoding currentEncoding_ = LrcParser::AutoDetect;
    int currentOffsetMs_ = 0;

    // 来自 Lyric.xml 的颜色和字体
    QColor textColor_{0x00, 0x80, 0xC0};
    QColor hilightColor_{0x00, 0xFF, 0x00};
    QColor bkgndColor_{0x00, 0x00, 0x00};
    QFont lyricFont_{"SimSun", 12};

    // 无歌词时显示的曲目信息
    QString trackTitle_;
    QString trackArtist_;

    QTimer* timer_;

    // 调整大小句柄
    Qt::Edges resizeEdges_ = {};
    QPoint resizeStartGlobalPos_;
    QSize resizeStartSize_;

    // 拖拽状态
    bool dragging_ = false;
    QPoint dragStart_;
    bool dragSessionActive_ = false;
    bool dragUsingSystemMove_ = false;
    bool lastMoveEventObserved_ = false;
    qint64 lastWindowMovedEmitMs_ = 0;
    WindowMovePerfLogger movePerf_{"LyricWindow"};
};
