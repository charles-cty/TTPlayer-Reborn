#pragma once
#include <QString>
#include <QPixmap>
#include <QImage>
#include <QRect>
#include <QColor>
#include <QFont>
#include <QMap>
#include <QVector>
#include <memory>

// 单个皮肤元素定义，对应 Skin.xml 中的一个控件或文本区域。
struct SkinElement {
    QString type;          // "play", "pause", "stop", "progress" 等类型
    QRect position;        // 来自皮肤 XML 的 x1,y1,x2,y2 坐标
    QString imageName;     // BMP 文件名
    QString hotImageName;
    QString selectedImageName;
    QString buttonsImageName;
    QString iconName;
    QPixmap statePixmaps[4]; // 正常、悬停、按下、禁用 状态图
    QPixmap hotPixmap;
    QPixmap selectedPixmap;
    QPixmap buttonsPixmap;
    int stateCount = 1;
    bool useFrameSizeForBounds = false;

    // 滑块相关属性
    QString barImageName;
    QString thumbImageName;
    QString fillImageName;
    QPixmap barPixmap;
    QPixmap thumbPixmaps[4];
    QPixmap fillPixmap;
    bool vertical = false;
    int thumbResizeCenter = 0;
    bool thumbResizeTile = false;

    // 文本元素属性
    QColor color;
    QColor bkgndColor;
    QString fontFamily;
    int fontSize = 12;
    QString align;

    // 可调整大小窗口属性
    QRect resizeRect;
    bool resizeTile = false;

    // 额外颜色，用于特殊元素如 mini_border
    QColor leftTopColor;
    QColor rightBottomColor;
};

// 皮肤中的一个窗口定义，例如播放器、歌词、均衡器或播放列表窗口。
struct SkinWindow {
    QString type;                    // "player_window", "lyric_window" 等窗口类型
    QPixmap backgroundPixmap;        // 该窗口的背景图像
    QString backgroundImageName;
    QRect defaultPosition;           // 相对于播放器主窗口的默认偏移
    QRect resizeRect;                // 可缩放区域
    bool resizeTile = false;
    int eqInterval = 2;             // 均衡器窗口滑块间隔
    QColor hilightColor;             // Skin.xml 中 playlist_window 的 hilight 属性（保留供扩展兼容）
    QVector<SkinElement> elements;

    SkinElement* findElement(const QString& type) {
        for (auto& e : elements) {
            if (e.type == type) return &e;
        }
        return nullptr;
    }
};

// 从 Lyric.xml 解析出来的歌词窗口配置。
struct LyricConfig {
    QFont font{"SimSun", 12};
    QColor textColor{0x00, 0x80, 0xC0};
    QColor hilightColor{0x00, 0xFF, 0x00};
    QColor bkgndColor{0x00, 0x00, 0x00};
};

// 从 PlayList.xml 解析出来的播放列表窗口配置。
struct PlaylistConfig {
    QFont font{"SimSun", 12};
    QColor colorText{0x00, 0x80, 0xFF};
    QColor colorHilight{0x00, 0xFF, 0x00};
    QColor colorBkgnd{0x00, 0x00, 0x00};
    QColor colorNumber{0x00, 0x80, 0x00};
    QColor colorDuration{0xC0, 0x80, 0x20};
    QColor colorSelect{0x32, 0x69, 0xC8};
    QColor colorBkgnd2{0x20, 0x20, 0x20};
    bool hasFont = false;
    bool hasColorText = false;
    bool hasColorHilight = false;
    bool hasColorBkgnd = false;
    bool hasColorNumber = false;
    bool hasColorDuration = false;
    bool hasColorSelect = false;
    bool hasColorBkgnd2 = false;
};

// 从 Visual.xml 或皮肤配置中解析出的可视化效果配置。
struct VisualConfig {
    QColor spectrumTopColor{0xFF, 0xFF, 0xFF};
    QColor spectrumBtmColor{0x00, 0x80, 0xFF};
    QColor spectrumMidColor{0xFF, 0xFF, 0x00};
    QColor spectrumPeakColor{0xFF, 0xFF, 0xFF};
    QColor blurScopeColor{0x00, 0xFF, 0xFF};
    QColor textColor{0xFF, 0xFF, 0xFF};
    QFont font{"Tahoma", 11};
    int spectrumWide = 0;
    int blurSpeed = 3;
    bool blur = true;
    int type = 0;
    int framesPerSec = 30;
};

struct SkinWindowLayout {
    QRect geometry;
    bool hasGeometry = false;
    bool visible = false;
    bool hasVisible = false;
};

struct SkinLayoutConfig {
    SkinWindowLayout playerWindow;
    SkinWindowLayout miniWindow;
    SkinWindowLayout lyricWindow;
    SkinWindowLayout equalizerWindow;
    SkinWindowLayout playlistWindow;
};

// 完整解析后的皮肤数据，包含窗口布局、元素和各种配置。
struct SkinData {
    QString name;
    QString author;
    QString url;
    QString email;
    QColor transparentColor{255, 0, 255}; // 默认透明色 #FF00FF
    int version = 2;

    SkinWindow playerWindow;
    SkinWindow miniWindow;
    SkinWindow lyricWindow;
    SkinWindow equalizerWindow;
    SkinWindow playlistWindow;

    SkinLayoutConfig layoutConfig;
    LyricConfig lyricConfig;
    PlaylistConfig playlistConfig;
    VisualConfig visualConfig;

    SkinWindow* windowByType(const QString& type) {
        if (type == "player_window") return &playerWindow;
        if (type == "mini_window") return &miniWindow;
        if (type == "lyric_window") return &lyricWindow;
        if (type == "equalizer_window") return &equalizerWindow;
        if (type == "playlist_window") return &playlistWindow;
        return nullptr;
    }
};
