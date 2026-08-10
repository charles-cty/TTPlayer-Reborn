#include "SkinParser.h"
#include <QDebug>
#include <QHash>
#include <QImage>
#include <QPainter>
#include <QSet>

namespace {
bool parseBoolAttr(QStringView value) {
    const QString lowered = value.toString().trimmed().toLower();
    return lowered == "1" || lowered == "true" || lowered == "yes";
}

int fixedButtonStateCount(const QString& type) {
    static const QHash<QString, int> kStateCounts = {
        {QStringLiteral("play"), 4},
        {QStringLiteral("pause"), 4},
        {QStringLiteral("stop"), 4},
        {QStringLiteral("prev"), 4},
        {QStringLiteral("next"), 4},
        {QStringLiteral("mute"), 4},
        {QStringLiteral("open"), 4},
        {QStringLiteral("close"), 4},
        {QStringLiteral("exit"), 4},
        {QStringLiteral("lyric"), 4},
        {QStringLiteral("equalizer"), 4},
        {QStringLiteral("playlist"), 4},
        {QStringLiteral("minimize"), 4},
        {QStringLiteral("minimode"), 4},
        {QStringLiteral("enabled"), 4},
        {QStringLiteral("profile"), 4},
        {QStringLiteral("reset"), 4},
        {QStringLiteral("ontop"), 4},
        {QStringLiteral("browser"), 4},
        {QStringLiteral("backward"), 4},
        {QStringLiteral("forward"), 4},
        {QStringLiteral("refresh"), 4},
        {QStringLiteral("startup"), 4},
    };

    return kStateCounts.value(type.toLower(), 0);
}

int fixedSliderThumbStateCount(const QString& type) {
    static const QHash<QString, int> kStateCounts = {
        {QStringLiteral("progress"), 4},
        {QStringLiteral("volume"), 4},
        {QStringLiteral("balance"), 4},
        {QStringLiteral("surround"), 4},
        {QStringLiteral("preamp"), 4},
        {QStringLiteral("eqfactor"), 4},
        {QStringLiteral("scrollbar"), 3},
    };

    return kStateCounts.value(type.toLower(), 0);
}

QString truncateXmlAfterRoot(const QString& xmlContent) {
    QString text = xmlContent.trimmed();
    QXmlStreamReader probe(text);
    while (!probe.atEnd() && !probe.isStartElement()) {
        probe.readNext();
    }
    if (probe.atEnd() || !probe.isStartElement()) {
        return text;
    }

    const QString rootName = probe.name().toString();
    if (rootName.isEmpty()) {
        return text;
    }

    const QString closeTag = QStringLiteral("</%1>").arg(rootName);
    const int lastClose = text.lastIndexOf(closeTag, Qt::CaseInsensitive);
    if (lastClose < 0) {
        return text;
    }

    const QString truncated = text.left(lastClose + closeTag.size()).trimmed();
    if (truncated.size() < text.size()) {
        qWarning() << "SkinParser::truncateXmlAfterRoot: trimmed trailing content after" << rootName;
    }
    return truncated;
}

// 具有多状态按钮精灵表的元素类型。
// 其他元素使用单张图片，不进行拆分。
bool isButtonType(const QString& type) {
    return fixedButtonStateCount(type) > 0;
}

QVector<QRect> opaqueColumnRuns(const QPixmap& sheet) {
    QVector<QRect> runs;
    if (sheet.isNull()) {
        return runs;
    }

    const QImage image = sheet.toImage().convertToFormat(QImage::Format_ARGB32);
    int runStart = -1;
    for (int x = 0; x < image.width(); ++x) {
        bool hasOpaquePixel = false;
        for (int y = 0; y < image.height(); ++y) {
            if (qAlpha(image.pixel(x, y)) > 0) {
                hasOpaquePixel = true;
                break;
            }
        }

        if (hasOpaquePixel) {
            if (runStart < 0) {
                runStart = x;
            }
            continue;
        }

        if (runStart >= 0) {
            runs.append(QRect(runStart, 0, x - runStart, image.height()));
            runStart = -1;
        }
    }

    if (runStart >= 0) {
        runs.append(QRect(runStart, 0, image.width() - runStart, image.height()));
    }

    return runs;
}

bool splitByOpaqueColumnRuns(const QPixmap& sheet, int expectedStates,
                             QPixmap out[4], int& stateCount) {
    if (sheet.isNull() || expectedStates < 2 || expectedStates > 4) {
        return false;
    }

    const QVector<QRect> runs = opaqueColumnRuns(sheet);
    if (runs.size() != expectedStates) {
        return false;
    }

    for (const QRect& run : runs) {
        if (run.width() <= 0) {
            return false;
        }
    }

    stateCount = expectedStates;
    for (int i = 0; i < expectedStates; ++i) {
        out[i] = sheet.copy(runs[i]);
    }
    for (int i = expectedStates; i < 4; ++i) {
        out[i] = out[0];
    }
    return true;
}

bool rectLooksLikeSpriteSheetBounds(const QRect& rect, const QSize& sheetSize) {
    if (rect.isEmpty() || !sheetSize.isValid()) {
        return false;
    }

    // 兼容一类老皮肤：position 记录的是整张状态图的包围盒，
    // 而不是单帧按钮大小；常见误差通常只在 0-2px。
    return qAbs(rect.width() - sheetSize.width()) <= 2 &&
           qAbs(rect.height() - sheetSize.height()) <= 2;
}

bool shouldUseFrameSizeForBounds(const QRect& rect, const QPixmap& sheet, const QPixmap& frame) {
    return !frame.isNull() && rectLooksLikeSpriteSheetBounds(rect, sheet.size());
}

void assignSingleState(const QPixmap& sheet, QPixmap out[4], int& stateCount) {
    for (int i = 0; i < 4; ++i) {
        out[i] = {};
    }

    if (sheet.isNull()) {
        stateCount = 0;
        return;
    }

    stateCount = 1;
    out[0] = sheet;
    for (int i = 1; i < 4; ++i) {
        out[i] = sheet;
    }
}

enum class FixedStateSplitResult {
    Failed,
    OpaqueRuns,
    EqualPartitions,
    ForcedPartitions,
};

FixedStateSplitResult splitByFixedStateCount(const QPixmap& sheet, int expectedStates,
                                             QPixmap out[4], int& stateCount) {
    if (sheet.isNull() || expectedStates < 2 || expectedStates > 4) {
        return FixedStateSplitResult::Failed;
    }

    if (splitByOpaqueColumnRuns(sheet, expectedStates, out, stateCount)) {
        return FixedStateSplitResult::OpaqueRuns;
    }

    if (sheet.width() < expectedStates) {
        return FixedStateSplitResult::Failed;
    }

    stateCount = expectedStates;
    int startX = 0;
    for (int i = 0; i < expectedStates; ++i) {
        const int endX = ((i + 1) * sheet.width()) / expectedStates;
        const int partWidth = endX - startX;
        if (partWidth <= 0) {
            return FixedStateSplitResult::Failed;
        }
        out[i] = sheet.copy(startX, 0, partWidth, sheet.height());
        startX = endX;
    }
    for (int i = expectedStates; i < 4; ++i) {
        out[i] = out[0];
    }

    if ((sheet.width() % expectedStates) == 0) {
        return FixedStateSplitResult::EqualPartitions;
    }
    return FixedStateSplitResult::ForcedPartitions;
}
}

// 解析 Skin.xml 内容，并将图片与元素配置转换成 SkinData。
bool SkinParser::parse(const QString& xmlContent,
                       const QMap<QString, QImage>& images,
                       QColor transparentColor,
                       SkinData& out) {
    out = SkinData{};
    QXmlStreamReader xml(xmlContent);

    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement() && xml.name() == u"skin") {
            auto attrs = xml.attributes();
            out.version = attrs.value("version").toInt();
            out.name = attrs.value("name").toString();
            out.author = attrs.value("author").toString();
            out.url = attrs.value("url").toString();
            out.email = attrs.value("email").toString();
            if (attrs.hasAttribute("transparent_color"))
                out.transparentColor = parseColor(attrs.value("transparent_color").toString());
            else
                out.transparentColor = transparentColor;
        }
        else if (xml.isStartElement() && xml.name() == u"player_window") {
            out.playerWindow.type = "player_window";
            auto attrs = xml.attributes();
            out.playerWindow.backgroundImageName = attrs.value("image").toString();
            out.playerWindow.backgroundPixmap = loadAndProcess(images, out.playerWindow.backgroundImageName, out.transparentColor);
            parseWindow(xml, out.playerWindow, images, out.transparentColor);
        }
        else if (xml.isStartElement() && xml.name() == u"mini_window") {
            out.miniWindow.type = "mini_window";
            auto attrs = xml.attributes();
            out.miniWindow.backgroundImageName = attrs.value("image").toString();
            out.miniWindow.backgroundPixmap = loadAndProcess(images, out.miniWindow.backgroundImageName, out.transparentColor);
            parseWindow(xml, out.miniWindow, images, out.transparentColor);
        }
        else if (xml.isStartElement() && xml.name() == u"lyric_window") {
            out.lyricWindow.type = "lyric_window";
            auto attrs = xml.attributes();
            out.lyricWindow.backgroundImageName = attrs.value("image").toString();
            out.lyricWindow.backgroundPixmap = loadAndProcess(images, out.lyricWindow.backgroundImageName, out.transparentColor);
            if (attrs.hasAttribute("position"))
                out.lyricWindow.defaultPosition = parsePosition(attrs.value("position").toString());
            if (attrs.hasAttribute("resize_rect"))
                out.lyricWindow.resizeRect = parsePosition(attrs.value("resize_rect").toString());
            if (attrs.hasAttribute("resize_tile"))
                out.lyricWindow.resizeTile = attrs.value("resize_tile").toInt() != 0;
            parseWindow(xml, out.lyricWindow, images, out.transparentColor);
        }
        else if (xml.isStartElement() && xml.name() == u"equalizer_window") {
            out.equalizerWindow.type = "equalizer_window";
            auto attrs = xml.attributes();
            out.equalizerWindow.backgroundImageName = attrs.value("image").toString();
            out.equalizerWindow.backgroundPixmap = loadAndProcess(images, out.equalizerWindow.backgroundImageName, out.transparentColor);
            if (attrs.hasAttribute("position"))
                out.equalizerWindow.defaultPosition = parsePosition(attrs.value("position").toString());
            if (attrs.hasAttribute("eq_interval"))
                out.equalizerWindow.eqInterval = attrs.value("eq_interval").toInt();
            parseWindow(xml, out.equalizerWindow, images, out.transparentColor);
        }
        else if (xml.isStartElement() && xml.name() == u"playlist_window") {
            out.playlistWindow.type = "playlist_window";
            auto attrs = xml.attributes();
            out.playlistWindow.backgroundImageName = attrs.value("image").toString();
            out.playlistWindow.backgroundPixmap = loadAndProcess(images, out.playlistWindow.backgroundImageName, out.transparentColor);
            if (attrs.hasAttribute("position"))
                out.playlistWindow.defaultPosition = parsePosition(attrs.value("position").toString());
            if (attrs.hasAttribute("resize_rect"))
                out.playlistWindow.resizeRect = parsePosition(attrs.value("resize_rect").toString());
            if (attrs.hasAttribute("resize_tile"))
                out.playlistWindow.resizeTile = attrs.value("resize_tile").toInt() != 0;
            // 先保留 playlist_window 的 hilight 属性，后续如果需要兼容原版 splitter 扩展字段可再利用。
            if (attrs.hasAttribute("hilight"))
                out.playlistWindow.hilightColor = parseColor(attrs.value("hilight").toString());
            parseWindow(xml, out.playlistWindow, images, out.transparentColor);
        }
    }

    if (xml.hasError()) {
        const QString errorText = xml.errorString();
        if (errorText.contains("extra content", Qt::CaseInsensitive) ||
            errorText.contains(QStringLiteral("文档末尾有额外内容"), Qt::CaseInsensitive)) {
            const QString truncated = truncateXmlAfterRoot(xmlContent);
            if (truncated != xmlContent) {
                qWarning() << "SkinParser::parse: retrying after truncating trailing XML content";
                return parse(truncated, images, transparentColor, out);
            }
        }
        qWarning() << "SkinParser::parse: XML parse error at line" << xml.lineNumber()
                   << "column" << xml.columnNumber() << ":" << errorText;
        return false;
    }
    return true;
}

// 解析一个窗口节点及其子元素。
void SkinParser::parseWindow(QXmlStreamReader& xml, SkinWindow& window,
                              const QMap<QString, QImage>& images, QColor transColor) {
    QString endTag = xml.name().toString();
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isEndElement() && xml.name().toString() == endTag)
            break;
        if (xml.isStartElement()) {
            SkinElement elem = parseElement(xml, images, transColor);
            window.elements.append(elem);
        }
    }
}

// 解析单个皮肤元素，支持按钮、图标、滑块等类型。
SkinElement SkinParser::parseElement(QXmlStreamReader& xml,
                                      const QMap<QString, QImage>& images,
                                      QColor transColor) {
    SkinElement elem;
    elem.type = xml.name().toString();
    auto attrs = xml.attributes();

    // 位置解析
    if (attrs.hasAttribute("position"))
        elem.position = parsePosition(attrs.value("position").toString());

    // 主图像（按钮精灵表或单图元素）
    if (attrs.hasAttribute("image")) {
        elem.imageName = attrs.value("image").toString();
        if (!elem.imageName.isEmpty()) {
            QPixmap full = loadAndProcess(images, elem.imageName, transColor);
            if (!full.isNull() && !elem.position.isEmpty() && isButtonType(elem.type)) {
                // 按钮元素：将水平精灵表拆分为多个状态
                splitStates(elem.type, full, elem.statePixmaps, elem.stateCount);
                if (shouldUseFrameSizeForBounds(elem.position, full, elem.statePixmaps[0])) {
                    elem.useFrameSizeForBounds = true;
                    qWarning() << "SkinParser::parseElement: detected sprite-sheet-sized button anchor rect for"
                               << elem.type << elem.imageName
                               << "sheet=" << full.size() << "frame=" << elem.statePixmaps[0].size();
                }
            } else {
                // 非按钮元素（led、title、toolbar 等）：保留完整图像
                elem.statePixmaps[0] = full;
                elem.stateCount = 1;
            }
        }
    }
    if (attrs.hasAttribute("hot_image")) {
        elem.hotImageName = attrs.value("hot_image").toString();
        elem.hotPixmap = loadAndProcess(images, elem.hotImageName, transColor);
    }
    if (attrs.hasAttribute("selected_image")) {
        elem.selectedImageName = attrs.value("selected_image").toString();
        elem.selectedPixmap = loadAndProcess(images, elem.selectedImageName, transColor);
    }
    if (attrs.hasAttribute("buttons_image")) {
        elem.buttonsImageName = attrs.value("buttons_image").toString();
        elem.buttonsPixmap = loadAndProcess(images, elem.buttonsImageName, transColor);
    }
    if (attrs.hasAttribute("icon")) {
        elem.iconName = attrs.value("icon").toString();
        const QPixmap iconPixmap = loadAndProcess(images, elem.iconName, transColor);
        if (!iconPixmap.isNull()) {
            elem.statePixmaps[0] = iconPixmap;
            for (int i = 1; i < 4; ++i) {
                elem.statePixmaps[i] = iconPixmap;
            }
            elem.stateCount = 1;
        }
    }

    // 滑块图像解析
    if (attrs.hasAttribute("thumb_image")) {
        elem.thumbImageName = attrs.value("thumb_image").toString();
        QPixmap thumbFull = loadAndProcess(images, elem.thumbImageName, transColor);
        if (!thumbFull.isNull()) {
            const int fixedStates = fixedSliderThumbStateCount(elem.type);
            int thumbStateCount = 0;
            assignSingleState(thumbFull, elem.thumbPixmaps, thumbStateCount);
            if (fixedStates >= 2) {
                const FixedStateSplitResult splitResult =
                    splitByFixedStateCount(thumbFull, fixedStates, elem.thumbPixmaps, thumbStateCount);
                if (splitResult == FixedStateSplitResult::Failed) {
                    qWarning() << "SkinParser::parseElement: failed to split thumb sheet for"
                               << elem.type << elem.thumbImageName
                               << "sheet=" << thumbFull.size() << "states=" << fixedStates;
                } else if (splitResult == FixedStateSplitResult::ForcedPartitions) {
                    qWarning() << "SkinParser::parseElement: forced count-based thumb split for"
                               << elem.type << elem.thumbImageName
                               << "sheet=" << thumbFull.size() << "states=" << fixedStates;
                }
            }
        }
    }
    if (attrs.hasAttribute("bar_image")) {
        elem.barImageName = attrs.value("bar_image").toString();
        elem.barPixmap = loadAndProcess(images, elem.barImageName, transColor);
    }
    if (attrs.hasAttribute("fill_image")) {
        elem.fillImageName = attrs.value("fill_image").toString();
        elem.fillPixmap = loadAndProcess(images, elem.fillImageName, transColor);
    }
    if (attrs.hasAttribute("vertical"))
        elem.vertical = parseBoolAttr(attrs.value("vertical"));
    if (attrs.hasAttribute("thumb_resize_center"))
        elem.thumbResizeCenter = attrs.value("thumb_resize_center").toInt();
    if (attrs.hasAttribute("thumb_resize_tile"))
        elem.thumbResizeTile = parseBoolAttr(attrs.value("thumb_resize_tile"));

    // 文本样式解析
    if (attrs.hasAttribute("color"))
        elem.color = parseColor(attrs.value("color").toString());
    if (attrs.hasAttribute("bkgnd"))
        elem.bkgndColor = parseColor(attrs.value("bkgnd").toString());
    if (attrs.hasAttribute("font"))
        elem.fontFamily = attrs.value("font").toString();
    if (attrs.hasAttribute("font_size"))
        elem.fontSize = attrs.value("font_size").toInt();
    if (attrs.hasAttribute("align"))
        elem.align = attrs.value("align").toString();
    if (attrs.hasAttribute("left_top_color"))
        elem.leftTopColor = parseColor(attrs.value("left_top_color").toString());
    if (attrs.hasAttribute("right_bottom_color"))
        elem.rightBottomColor = parseColor(attrs.value("right_bottom_color").toString());

    // 跳过到当前元素结束
    xml.skipCurrentElement();
    return elem;
}

// 解析皮肤中使用的坐标字符串，返回 QRect。
QRect SkinParser::parsePosition(const QString& pos) {
    // 格式："x1, y1, x2, y2"
    QStringList parts = pos.split(',');
    if (parts.size() >= 4) {
        int x1 = parts[0].trimmed().toInt();
        int y1 = parts[1].trimmed().toInt();
        int x2 = parts[2].trimmed().toInt();
        int y2 = parts[3].trimmed().toInt();
        return QRect(x1, y1, x2 - x1, y2 - y1);
    }
    return {};
}

// 解析十六进制颜色字符串为 QColor。
QColor SkinParser::parseColor(const QString& colorStr) {
    // 格式："#rrggbb"
    return QColor(colorStr);
}

// 从图片字典加载指定图像，并将透明色替换为 alpha 通道。
QPixmap SkinParser::loadAndProcess(const QMap<QString, QImage>& images,
                                    const QString& name, QColor transColor) {
    if (name.isEmpty()) return {};
    auto it = images.find(name.toLower());
    if (it == images.end()) return {};

    QImage img = it.value().convertToFormat(QImage::Format_ARGB32);

    // 将透明色替换为 alpha 通道
    QRgb transRgb = transColor.rgb() & 0x00FFFFFF;
    for (int y = 0; y < img.height(); ++y) {
        QRgb* line = reinterpret_cast<QRgb*>(img.scanLine(y));
        for (int x = 0; x < img.width(); ++x) {
            if ((line[x] & 0x00FFFFFF) == transRgb) {
                line[x] = 0x00000000; // 完全透明
            }
        }
    }

    return QPixmap::fromImage(img);
}

// 将按钮精灵表拆分为多个状态图像（最多 4 个）。
void SkinParser::splitStates(const QString& elementType,
                              const QPixmap& sheet,
                              QPixmap out[4], int& stateCount) {
    assignSingleState(sheet, out, stateCount);

    if (sheet.isNull()) {
        return;
    }

    const int fixedStates = fixedButtonStateCount(elementType);
    if (fixedStates < 2) {
        return;
    }

    const FixedStateSplitResult splitResult =
        splitByFixedStateCount(sheet, fixedStates, out, stateCount);
    if (splitResult == FixedStateSplitResult::Failed) {
        qWarning() << "SkinParser::splitStates: failed to split fixed-state button sheet for"
                   << elementType << "sheet=" << sheet.size() << "states=" << fixedStates;
    } else if (splitResult == FixedStateSplitResult::ForcedPartitions) {
        qWarning() << "SkinParser::splitStates: forced count-based button split for"
                   << elementType << "sheet=" << sheet.size() << "states=" << fixedStates;
    }
}

// 解析 Windows LOGFONT 逗号分隔字符串为 QFont
// 格式："lfHeight,lfWidth,...,lfFaceName"（共 14 个字段）
QFont SkinParser::parseLogFont(const QString& logFontStr) {
    QStringList parts = logFontStr.split(',');
    QFont font;
    if (parts.size() >= 14) {
        int lfHeight = parts[0].trimmed().toInt();
        // 负数 lfHeight 表示字符高度（像素），正数表示单元格高度
        int px = qAbs(lfHeight);
        if (px > 0) font.setPixelSize(px);
        int lfWeight = (parts.size() > 4) ? parts[4].trimmed().toInt() : 400;
        font.setBold(lfWeight >= 700);
        QString faceName = parts[13].trimmed();
        if (!faceName.isEmpty()) font.setFamily(faceName);
    }
    return font;
}

void SkinParser::parseLyricXml(const QString& xmlContent, SkinData& out) {
    QXmlStreamReader xml(xmlContent);
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement() && xml.name() == u"Lyric") {
            auto attrs = xml.attributes();
            if (attrs.hasAttribute("Font"))
                out.lyricConfig.font = parseLogFont(attrs.value("Font").toString());
            if (attrs.hasAttribute("TextColor"))
                out.lyricConfig.textColor = parseColor(attrs.value("TextColor").toString());
            if (attrs.hasAttribute("HilightColor"))
                out.lyricConfig.hilightColor = parseColor(attrs.value("HilightColor").toString());
            if (attrs.hasAttribute("BkgndColor"))
                out.lyricConfig.bkgndColor = parseColor(attrs.value("BkgndColor").toString());
        }
    }
}

void SkinParser::parsePlaylistXml(const QString& xmlContent, SkinData& out) {
    QXmlStreamReader xml(xmlContent);
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement() && xml.name() == u"PlayList") {
            auto attrs = xml.attributes();
            if (attrs.hasAttribute("Font")) {
                out.playlistConfig.font = parseLogFont(attrs.value("Font").toString());
                out.playlistConfig.hasFont = true;
            }
            if (attrs.hasAttribute("Color_Text")) {
                out.playlistConfig.colorText = parseColor(attrs.value("Color_Text").toString());
                out.playlistConfig.hasColorText = true;
            }
            if (attrs.hasAttribute("Color_Hilight")) {
                out.playlistConfig.colorHilight = parseColor(attrs.value("Color_Hilight").toString());
                out.playlistConfig.hasColorHilight = true;
            }
            if (attrs.hasAttribute("Color_Bkgnd")) {
                out.playlistConfig.colorBkgnd = parseColor(attrs.value("Color_Bkgnd").toString());
                out.playlistConfig.hasColorBkgnd = true;
            }
            if (attrs.hasAttribute("Color_Number")) {
                out.playlistConfig.colorNumber = parseColor(attrs.value("Color_Number").toString());
                out.playlistConfig.hasColorNumber = true;
            }
            if (attrs.hasAttribute("Color_Duration")) {
                out.playlistConfig.colorDuration = parseColor(attrs.value("Color_Duration").toString());
                out.playlistConfig.hasColorDuration = true;
            }
            if (attrs.hasAttribute("Color_Select")) {
                out.playlistConfig.colorSelect = parseColor(attrs.value("Color_Select").toString());
                out.playlistConfig.hasColorSelect = true;
            }
            if (attrs.hasAttribute("Color_Bkgnd2")) {
                out.playlistConfig.colorBkgnd2 = parseColor(attrs.value("Color_Bkgnd2").toString());
                out.playlistConfig.hasColorBkgnd2 = true;
            }
        }
    }
}

void SkinParser::parseVisualXml(const QString& xmlContent, SkinData& out) {
    QXmlStreamReader xml(xmlContent);
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement() && xml.name() == u"Visual") {
            const auto attrs = xml.attributes();
            if (attrs.hasAttribute("SpectrumTopColor"))
                out.visualConfig.spectrumTopColor = parseColor(attrs.value("SpectrumTopColor").toString());
            if (attrs.hasAttribute("SpectrumBtmColor"))
                out.visualConfig.spectrumBtmColor = parseColor(attrs.value("SpectrumBtmColor").toString());
            if (attrs.hasAttribute("SpectrumMidColor"))
                out.visualConfig.spectrumMidColor = parseColor(attrs.value("SpectrumMidColor").toString());
            if (attrs.hasAttribute("SpectrumPeakColor"))
                out.visualConfig.spectrumPeakColor = parseColor(attrs.value("SpectrumPeakColor").toString());
            if (attrs.hasAttribute("BlurScopeColor"))
                out.visualConfig.blurScopeColor = parseColor(attrs.value("BlurScopeColor").toString());
            if (attrs.hasAttribute("TextColor"))
                out.visualConfig.textColor = parseColor(attrs.value("TextColor").toString());
            if (attrs.hasAttribute("Font"))
                out.visualConfig.font = parseLogFont(attrs.value("Font").toString());
            if (attrs.hasAttribute("SpectrumWide"))
                out.visualConfig.spectrumWide = attrs.value("SpectrumWide").toInt();
            if (attrs.hasAttribute("BlurSpeed"))
                out.visualConfig.blurSpeed = attrs.value("BlurSpeed").toInt();
            if (attrs.hasAttribute("Blur"))
                out.visualConfig.blur = parseBoolAttr(attrs.value("Blur"));
            if (attrs.hasAttribute("Type"))
                out.visualConfig.type = attrs.value("Type").toInt();
            if (attrs.hasAttribute("FramesPerSec"))
                out.visualConfig.framesPerSec = attrs.value("FramesPerSec").toInt();
        }
    }
}

void SkinParser::parseSkinConfigXml(const QString& xmlContent, SkinData& out) {
    QXmlStreamReader xml(xmlContent);
    while (!xml.atEnd()) {
        xml.readNext();
        if (!(xml.isStartElement() && xml.name() == u"Player")) {
            continue;
        }

        const auto attrs = xml.attributes();
        auto parseLayout = [this, &attrs](const char* attrName, SkinWindowLayout& layout) {
            if (!attrs.hasAttribute(attrName)) {
                return;
            }
            layout.geometry = parsePosition(attrs.value(attrName).toString());
            layout.hasGeometry = layout.geometry.width() > 0 && layout.geometry.height() > 0;
        };

        parseLayout("PlayerWnd", out.layoutConfig.playerWindow);
        parseLayout("PlayerWnd2", out.layoutConfig.miniWindow);
        parseLayout("LyricWnd", out.layoutConfig.lyricWindow);
        parseLayout("EqualizerWnd", out.layoutConfig.equalizerWindow);
        parseLayout("PlayListWnd", out.layoutConfig.playlistWindow);

        if (attrs.hasAttribute("LyricVisible")) {
            out.layoutConfig.lyricWindow.visible = parseBoolAttr(attrs.value("LyricVisible"));
            out.layoutConfig.lyricWindow.hasVisible = true;
        }
        if (attrs.hasAttribute("EqualizerVisible")) {
            out.layoutConfig.equalizerWindow.visible = parseBoolAttr(attrs.value("EqualizerVisible"));
            out.layoutConfig.equalizerWindow.hasVisible = true;
        }
        if (attrs.hasAttribute("PlayListVisible")) {
            out.layoutConfig.playlistWindow.visible = parseBoolAttr(attrs.value("PlayListVisible"));
            out.layoutConfig.playlistWindow.hasVisible = true;
        }
    }
}
