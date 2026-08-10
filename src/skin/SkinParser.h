#pragma once
#include "SkinData.h"
#include <QString>
#include <QXmlStreamReader>
#include <QMap>
#include <QImage>

// 皮肤 XML 解析器，将 Skin.xml / Lyric.xml / PlayList.xml / Visual.xml 转换为可用的 SkinData 数据结构。
class SkinParser {
public:
    // 解析 Skin.xml 内容并结合图片资源生成 SkinData。
    bool parse(const QString& xmlContent,
               const QMap<QString, QImage>& images,
               QColor transparentColor,
               SkinData& out);

    // 解析 Lyric.xml 并填充 SkinData 中的 lyricConfig。
    void parseLyricXml(const QString& xmlContent, SkinData& out);

    // 解析 PlayList.xml 并填充 SkinData 中的 playlistConfig。
    void parsePlaylistXml(const QString& xmlContent, SkinData& out);

    // 解析 Visual.xml 并填充 SkinData 中的 visualConfig。
    void parseVisualXml(const QString& xmlContent, SkinData& out);

    // 解析侧车/默认 TTPlayer XML，并填充 SkinData 中的 layoutConfig。
    void parseSkinConfigXml(const QString& xmlContent, SkinData& out);

    // 解析 Windows LOGFONT 字符串（例如 "-12,0,...,宋体"）为 QFont。
    static QFont parseLogFont(const QString& logFontStr);

private:
    void parseWindow(QXmlStreamReader& xml, SkinWindow& window,
                     const QMap<QString, QImage>& images, QColor transColor);
    SkinElement parseElement(QXmlStreamReader& xml,
                             const QMap<QString, QImage>& images,
                             QColor transColor);

    QRect parsePosition(const QString& pos);
    QColor parseColor(const QString& colorStr);
    QPixmap loadAndProcess(const QMap<QString, QImage>& images,
                           const QString& name, QColor transColor);

    // 将多状态精灵表拆分为单独状态的 QPixmap。
    void splitStates(const QString& elementType,
                     const QPixmap& sheet,
                     QPixmap out[4], int& stateCount);
};
