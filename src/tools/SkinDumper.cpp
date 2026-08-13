#include "SkinDumper.h"
#include "skin/SkinEngine.h"

#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTextStream>

namespace {

// 颜色规范化：有效颜色输出小写 "#rrggbb"，无效颜色输出 null。
QJsonValue dumpColor(const QColor& color) {
    if (!color.isValid()) {
        return QJsonValue(QJsonValue::Null);
    }
    return QString::asprintf("#%02x%02x%02x", color.red(), color.green(), color.blue());
}

// 矩形规范化为 {x, y, w, h}。
QJsonObject dumpRect(const QRect& rect) {
    QJsonObject obj;
    obj["x"] = rect.x();
    obj["y"] = rect.y();
    obj["w"] = rect.width();
    obj["h"] = rect.height();
    return obj;
}

// 字体规范化：只保留跨实现可比的属性。
// 注意 SkinParser::parseLogFont 使用 setPixelSize，故这里读 pixelSize。
QJsonObject dumpFont(const QFont& font) {
    QJsonObject obj;
    obj["family"] = font.family();
    obj["pixel_size"] = font.pixelSize();
    obj["bold"] = font.bold();
    obj["italic"] = font.italic();
    return obj;
}

// 位图只记录是否存在及其尺寸，不含像素数据（像素一致性由 Layer 2 快照测试负责）。
QJsonValue dumpPixmapSize(const QPixmap& pixmap) {
    if (pixmap.isNull()) {
        return QJsonValue(QJsonValue::Null);
    }
    QJsonObject obj;
    obj["w"] = pixmap.width();
    obj["h"] = pixmap.height();
    return obj;
}

QJsonObject dumpElement(const SkinElement& elem) {
    QJsonObject obj;
    obj["type"] = elem.type;
    obj["position"] = dumpRect(elem.position);

    // 图像资源名（保持皮肤 XML 中的原始大小写）
    obj["image_name"] = elem.imageName;
    obj["hot_image_name"] = elem.hotImageName;
    obj["selected_image_name"] = elem.selectedImageName;
    obj["buttons_image_name"] = elem.buttonsImageName;
    obj["icon_name"] = elem.iconName;
    obj["bar_image_name"] = elem.barImageName;
    obj["thumb_image_name"] = elem.thumbImageName;
    obj["fill_image_name"] = elem.fillImageName;

    // 状态图拆分结果：状态数与各状态尺寸是拆分算法一致性的关键指标
    obj["state_count"] = elem.stateCount;
    QJsonArray stateSizes;
    for (int i = 0; i < 4; ++i) {
        stateSizes.append(dumpPixmapSize(elem.statePixmaps[i]));
    }
    obj["state_sizes"] = stateSizes;
    obj["use_frame_size_for_bounds"] = elem.useFrameSizeForBounds;

    obj["hot_size"] = dumpPixmapSize(elem.hotPixmap);
    obj["selected_size"] = dumpPixmapSize(elem.selectedPixmap);
    obj["buttons_size"] = dumpPixmapSize(elem.buttonsPixmap);
    obj["bar_size"] = dumpPixmapSize(elem.barPixmap);
    obj["fill_size"] = dumpPixmapSize(elem.fillPixmap);

    QJsonArray thumbSizes;
    for (int i = 0; i < 4; ++i) {
        thumbSizes.append(dumpPixmapSize(elem.thumbPixmaps[i]));
    }
    obj["thumb_sizes"] = thumbSizes;

    // 滑块属性
    obj["vertical"] = elem.vertical;
    obj["thumb_resize_center"] = elem.thumbResizeCenter;
    obj["thumb_resize_tile"] = elem.thumbResizeTile;

    // 文本属性
    obj["color"] = dumpColor(elem.color);
    obj["bkgnd_color"] = dumpColor(elem.bkgndColor);
    obj["font_family"] = elem.fontFamily;
    obj["font_size"] = elem.fontSize;
    obj["align"] = elem.align;

    // 可缩放窗口属性
    obj["resize_rect"] = dumpRect(elem.resizeRect);
    obj["resize_tile"] = elem.resizeTile;

    obj["left_top_color"] = dumpColor(elem.leftTopColor);
    obj["right_bottom_color"] = dumpColor(elem.rightBottomColor);
    return obj;
}

QJsonObject dumpWindow(const SkinWindow& window) {
    QJsonObject obj;
    obj["type"] = window.type;
    obj["background_image_name"] = window.backgroundImageName;
    obj["background_size"] = dumpPixmapSize(window.backgroundPixmap);
    obj["default_position"] = dumpRect(window.defaultPosition);
    obj["resize_rect"] = dumpRect(window.resizeRect);
    obj["resize_tile"] = window.resizeTile;
    obj["eq_interval"] = window.eqInterval;
    obj["hilight_color"] = dumpColor(window.hilightColor);

    // 元素保持 XML 中的出现顺序（顺序本身也是解析行为的一部分）
    QJsonArray elements;
    for (const auto& elem : window.elements) {
        elements.append(dumpElement(elem));
    }
    obj["elements"] = elements;
    return obj;
}

QJsonObject dumpWindowLayout(const SkinWindowLayout& layout) {
    QJsonObject obj;
    obj["geometry"] = dumpRect(layout.geometry);
    obj["has_geometry"] = layout.hasGeometry;
    obj["visible"] = layout.visible;
    obj["has_visible"] = layout.hasVisible;
    return obj;
}

QJsonObject dumpLyricConfig(const LyricConfig& cfg) {
    QJsonObject obj;
    obj["font"] = dumpFont(cfg.font);
    obj["text_color"] = dumpColor(cfg.textColor);
    obj["hilight_color"] = dumpColor(cfg.hilightColor);
    obj["bkgnd_color"] = dumpColor(cfg.bkgndColor);
    return obj;
}

// 注意：这里导出的是 SkinEngine::resolvePlaylistTheme 推导之后的最终配色。
// 皮肤未显式给出的颜色由背景采样与混合算出，Pascal 侧必须复刻同一套推导逻辑。
QJsonObject dumpPlaylistConfig(const PlaylistConfig& cfg) {
    QJsonObject obj;
    obj["font"] = dumpFont(cfg.font);
    obj["color_text"] = dumpColor(cfg.colorText);
    obj["color_hilight"] = dumpColor(cfg.colorHilight);
    obj["color_bkgnd"] = dumpColor(cfg.colorBkgnd);
    obj["color_number"] = dumpColor(cfg.colorNumber);
    obj["color_duration"] = dumpColor(cfg.colorDuration);
    obj["color_select"] = dumpColor(cfg.colorSelect);
    obj["color_bkgnd2"] = dumpColor(cfg.colorBkgnd2);

    // has_* 标记哪些颜色来自皮肤显式声明，哪些是推导值
    obj["has_font"] = cfg.hasFont;
    obj["has_color_text"] = cfg.hasColorText;
    obj["has_color_hilight"] = cfg.hasColorHilight;
    obj["has_color_bkgnd"] = cfg.hasColorBkgnd;
    obj["has_color_number"] = cfg.hasColorNumber;
    obj["has_color_duration"] = cfg.hasColorDuration;
    obj["has_color_select"] = cfg.hasColorSelect;
    obj["has_color_bkgnd2"] = cfg.hasColorBkgnd2;
    return obj;
}

QJsonObject dumpVisualConfig(const VisualConfig& cfg) {
    QJsonObject obj;
    obj["spectrum_top_color"] = dumpColor(cfg.spectrumTopColor);
    obj["spectrum_btm_color"] = dumpColor(cfg.spectrumBtmColor);
    obj["spectrum_mid_color"] = dumpColor(cfg.spectrumMidColor);
    obj["spectrum_peak_color"] = dumpColor(cfg.spectrumPeakColor);
    obj["blur_scope_color"] = dumpColor(cfg.blurScopeColor);
    obj["text_color"] = dumpColor(cfg.textColor);
    obj["font"] = dumpFont(cfg.font);
    obj["spectrum_wide"] = cfg.spectrumWide;
    obj["blur_speed"] = cfg.blurSpeed;
    obj["blur"] = cfg.blur;
    obj["type"] = cfg.type;
    obj["frames_per_sec"] = cfg.framesPerSec;
    return obj;
}

QJsonObject dumpSkin(const SkinData& skin) {
    QJsonObject root;
    root["name"] = skin.name;
    root["author"] = skin.author;
    root["url"] = skin.url;
    root["email"] = skin.email;
    root["version"] = skin.version;
    root["transparent_color"] = dumpColor(skin.transparentColor);

    root["player_window"] = dumpWindow(skin.playerWindow);
    root["mini_window"] = dumpWindow(skin.miniWindow);
    root["lyric_window"] = dumpWindow(skin.lyricWindow);
    root["equalizer_window"] = dumpWindow(skin.equalizerWindow);
    root["playlist_window"] = dumpWindow(skin.playlistWindow);

    QJsonObject layout;
    layout["player_window"] = dumpWindowLayout(skin.layoutConfig.playerWindow);
    layout["mini_window"] = dumpWindowLayout(skin.layoutConfig.miniWindow);
    layout["lyric_window"] = dumpWindowLayout(skin.layoutConfig.lyricWindow);
    layout["equalizer_window"] = dumpWindowLayout(skin.layoutConfig.equalizerWindow);
    layout["playlist_window"] = dumpWindowLayout(skin.layoutConfig.playlistWindow);
    root["layout_config"] = layout;

    root["lyric_config"] = dumpLyricConfig(skin.lyricConfig);
    root["playlist_config"] = dumpPlaylistConfig(skin.playlistConfig);
    root["visual_config"] = dumpVisualConfig(skin.visualConfig);
    return root;
}

}  // 匿名命名空间结束

namespace SkinDumper {

int run(const QString& skinPath, const QString& outPath) {
    QTextStream err(stderr);

    const QFileInfo info(skinPath);
    if (!info.exists()) {
        err << "SkinDumper: skin path does not exist: " << skinPath << "\n";
        return 2;
    }

    SkinEngine engine;
    const bool ok = info.isDir() ? engine.loadFromDirectory(skinPath)
                                 : engine.loadFromFile(skinPath);
    if (!ok) {
        err << "SkinDumper: failed to load skin: " << skinPath << "\n";
        return 3;
    }

    // QJsonObject 内部按键排序存储，序列化输出天然是规范化的。
    const QJsonDocument doc(dumpSkin(engine.skinData()));
    QByteArray json = doc.toJson(QJsonDocument::Indented);

    QFile outFile(outPath);
    if (!outFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        err << "SkinDumper: failed to open output file: " << outPath << "\n";
        return 4;
    }
    outFile.write(json);
    outFile.close();
    return 0;
}

}  // namespace SkinDumper
