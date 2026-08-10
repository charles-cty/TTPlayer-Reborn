#include "SkinEngine.h"
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QTemporaryDir>
#include <QTextCodec>
#include <QVector>
#include <QImage>
#include <quazip/quazip.h>
#include <quazip/quazipfile.h>

namespace {
// 不区分大小写查找目录中的文件，返回匹配的绝对路径。
QString findSkinFileCaseInsensitive(const QString& dirPath, const QString& fileName) {
    const QDir dir(dirPath);
    const QFileInfo exact(dir.absoluteFilePath(fileName));
    if (exact.exists() && exact.isFile()) {
        return exact.absoluteFilePath();
    }

    const auto entries = dir.entryInfoList(QDir::Files | QDir::NoDotAndDotDot);
    for (const auto& entry : entries) {
        if (entry.fileName().compare(fileName, Qt::CaseInsensitive) == 0) {
            return entry.absoluteFilePath();
        }
    }
    return {};
}

// 构建可能存在的侧车 XML 配置文件候选路径列表。
QStringList sidecarConfigCandidates(const QString& sknPath) {
    const QFileInfo sknInfo(sknPath);
    const QString sidecarName = sknInfo.fileName() + ".xml";
    QStringList candidates;
    QSet<QString> seen;

    auto addCandidate = [&candidates, &seen](const QString& path) {
        if (path.isEmpty()) {
            return;
        }
        const QString normalized = QFileInfo(path).absoluteFilePath();
        if (!seen.contains(normalized)) {
            seen.insert(normalized);
            candidates.append(normalized);
        }
    };

    auto addFromDir = [&addCandidate, &sidecarName](const QString& dirPath) {
        const QString resolved = findSkinFileCaseInsensitive(dirPath, sidecarName);
        if (!resolved.isEmpty()) {
            addCandidate(resolved);
        }
    };

    const QString absSkinPath = sknInfo.absoluteFilePath();
    const auto addMappedRoot = [&addFromDir, &absSkinPath](const QString& marker, const QString& mapped) {
        const int idx = absSkinPath.indexOf(marker, Qt::CaseInsensitive);
        if (idx < 0) {
            return;
        }
        const QString root = absSkinPath.left(idx);
        addFromDir(root + mapped);
    };

    // 先合并“另一套皮肤根目录”中的同名侧车，再让当前目录和同名旁路侧车覆盖。
    addMappedRoot("/TTPlayerv5.7.9/Skin/", "/build/Skin");
    addMappedRoot("/build/Skin/", "/TTPlayerv5.7.9/Skin");

    const QStringList fallbackDirs = {
        QDir::currentPath() + "/Skin",
        QDir::currentPath() + "/../Skin",
        QDir::currentPath() + "/../build/Skin",
        QDir::currentPath() + "/../../build/Skin",
        QDir::currentPath() + "/../TTPlayerv5.7.9/Skin",
        QDir::currentPath() + "/../../TTPlayerv5.7.9/Skin"
    };
    for (const auto& dir : fallbackDirs) {
        addFromDir(dir);
    }

    addFromDir(sknInfo.dir().absolutePath());

    const QString directSidecar = sknPath + ".xml";
    if (QFileInfo::exists(directSidecar)) {
        addCandidate(directSidecar);
    }

    return candidates;
}

QString escapeBareAmpersands(const QString& xml) {
    QString result = xml;
    static const QRegularExpression attrValue(R"((['"])([^'"<>]*&[^'"<>]*)\1)");
    static const QRegularExpression bareAmp(R"(&(?!(?:amp|lt|gt|quot|apos|#[0-9]+|#x[0-9A-Fa-f]+);))");
    int offset = 0;

    while (offset < result.size()) {
        const QRegularExpressionMatch match = attrValue.match(result, offset);
        if (!match.hasMatch()) {
            break;
        }
        QString value = match.captured(2);
        const QString escaped = value;
        value.replace(bareAmp, "&amp;");
        if (value != escaped) {
            result.replace(match.capturedStart(2), match.capturedLength(2), value);
            offset = match.capturedStart(2) + value.size();
        } else {
            offset = match.capturedEnd(2);
        }
    }
    return result;
}

bool isXmlNameStart(QChar ch) {
    return ch == QLatin1Char('_') || ch == QLatin1Char(':') || ch.isLetter();
}

bool isXmlNameChar(QChar ch) {
    return isXmlNameStart(ch) || ch.isDigit() || ch == QLatin1Char('-') ||
           ch == QLatin1Char('.') || ch == QLatin1Char('_');
}

bool isValidXml10Char(QChar ch) {
    const ushort code = ch.unicode();
    return code == 0x0009 || code == 0x000A || code == 0x000D ||
           (code >= 0x0020 && code <= 0xD7FF) ||
           (code >= 0xE000 && code <= 0xFFFD);
}

QString stripInvalidXml10Chars(const QString& xml) {
    QString cleaned;
    cleaned.reserve(xml.size());
    for (QChar ch : xml) {
        if (isValidXml10Char(ch)) {
            cleaned += ch;
        }
    }
    return cleaned;
}

struct XmlTagInfo {
    bool parsed = false;
    bool isStart = false;
    bool isEnd = false;
    bool selfClosing = false;
    QString name;
};

XmlTagInfo parseXmlTagInfo(const QString& rawTag) {
    XmlTagInfo info;
    if (!rawTag.startsWith(QLatin1Char('<')) || !rawTag.endsWith(QLatin1Char('>'))) {
        return info;
    }

    QString inner = rawTag.mid(1, rawTag.size() - 2).trimmed();
    if (inner.isEmpty() || inner.startsWith(QLatin1Char('?')) || inner.startsWith(QLatin1Char('!'))) {
        return info;
    }

    if (inner.startsWith(QLatin1Char('/'))) {
        info.isEnd = true;
        inner.remove(0, 1);
        inner = inner.trimmed();
    } else {
        info.isStart = true;
        if (inner.endsWith(QLatin1Char('/'))) {
            info.selfClosing = true;
            inner.chop(1);
            inner = inner.trimmed();
        }
    }

    if (inner.isEmpty() || !isXmlNameStart(inner.front())) {
        return XmlTagInfo{};
    }

    int cursor = 1;
    while (cursor < inner.size() && isXmlNameChar(inner[cursor])) {
        ++cursor;
    }
    info.name = inner.left(cursor);
    info.parsed = !info.name.isEmpty();
    if (!info.parsed) {
        return XmlTagInfo{};
    }
    return info;
}

QString trimAttributeQuotes(QString value) {
    value = value.trimmed();
    while (!value.isEmpty() &&
           (value.front() == QLatin1Char('"') || value.front() == QLatin1Char('\''))) {
        value.remove(0, 1);
    }
    while (!value.isEmpty() &&
           (value.back() == QLatin1Char('"') || value.back() == QLatin1Char('\''))) {
        value.chop(1);
    }
    return value.trimmed();
}

QString escapeXmlAttributeValue(QString value) {
    value.replace(QLatin1Char('&'), QStringLiteral("&amp;"));
    value.replace(QLatin1Char('"'), QStringLiteral("&quot;"));
    value.replace(QLatin1Char('\''), QStringLiteral("&apos;"));
    value.replace(QLatin1Char('<'), QStringLiteral("&lt;"));
    value.replace(QLatin1Char('>'), QStringLiteral("&gt;"));
    return value;
}

QString normalizeLegacyStartTag(const QString& rawTag, bool* changed = nullptr) {
    if (changed) {
        *changed = false;
    }
    if (!rawTag.startsWith(QLatin1Char('<')) || !rawTag.endsWith(QLatin1Char('>'))) {
        return rawTag;
    }

    const QString inner = rawTag.mid(1, rawTag.size() - 2);
    const QString trimmed = inner.trimmed();
    if (trimmed.isEmpty() || trimmed.startsWith(QLatin1Char('/')) ||
        trimmed.startsWith(QLatin1Char('?')) || trimmed.startsWith(QLatin1Char('!'))) {
        return rawTag;
    }

    QString content = trimmed;
    bool selfClosing = false;
    if (content.endsWith(QLatin1Char('/'))) {
        selfClosing = true;
        content.chop(1);
        content = content.trimmed();
    }

    int cursor = 0;
    while (cursor < content.size() && content[cursor].isSpace()) {
        ++cursor;
    }
    const int tagStart = cursor;
    if (tagStart >= content.size() || !isXmlNameStart(content[tagStart])) {
        return rawTag;
    }
    ++cursor;
    while (cursor < content.size() && isXmlNameChar(content[cursor])) {
        ++cursor;
    }
    const QString tagName = content.mid(tagStart, cursor - tagStart);
    if (tagName.isEmpty()) {
        return rawTag;
    }

    struct ParsedAttr {
        QString name;
        QString value;
    };

    QVector<ParsedAttr> attrs;
    QHash<QString, int> attrIndexByName;

    while (cursor < content.size()) {
        while (cursor < content.size() && content[cursor].isSpace()) {
            ++cursor;
        }
        if (cursor >= content.size()) {
            break;
        }
        if (!isXmlNameStart(content[cursor])) {
            ++cursor;
            continue;
        }

        const int attrStart = cursor;
        ++cursor;
        while (cursor < content.size() && isXmlNameChar(content[cursor])) {
            ++cursor;
        }
        const QString attrName = content.mid(attrStart, cursor - attrStart);
        while (cursor < content.size() && content[cursor].isSpace()) {
            ++cursor;
        }

        QString attrValue;
        if (cursor < content.size() && content[cursor] == QLatin1Char('=')) {
            ++cursor;
            while (cursor < content.size() && content[cursor].isSpace()) {
                ++cursor;
            }

            if (cursor < content.size() &&
                (content[cursor] == QLatin1Char('"') || content[cursor] == QLatin1Char('\''))) {
                const QChar quote = content[cursor];
                ++cursor;
                const int valueStart = cursor;
                while (cursor < content.size() && content[cursor] != quote) {
                    ++cursor;
                }
                attrValue = content.mid(valueStart, cursor - valueStart);
                if (cursor < content.size() && content[cursor] == quote) {
                    ++cursor;
                }
            } else {
                const int valueStart = cursor;
                while (cursor < content.size() && !content[cursor].isSpace() &&
                       content[cursor] != QLatin1Char('>') &&
                       content[cursor] != QLatin1Char('/')) {
                    ++cursor;
                }
                attrValue = content.mid(valueStart, cursor - valueStart);
            }
        }

        attrValue = trimAttributeQuotes(attrValue);
        const QString attrKey = attrName.toLower();
        const auto existing = attrIndexByName.constFind(attrKey);
        if (existing == attrIndexByName.constEnd()) {
            attrIndexByName.insert(attrKey, attrs.size());
            attrs.append({attrName, attrValue});
        } else if (attrs[*existing].value.isEmpty() && !attrValue.isEmpty()) {
            attrs[*existing].value = attrValue;
        }
    }

    QString normalized = QStringLiteral("<") + tagName;
    for (const auto& attr : attrs) {
        normalized += QStringLiteral(" %1=\"%2\"")
            .arg(attr.name, escapeXmlAttributeValue(attr.value));
    }
    if (selfClosing) {
        normalized += QStringLiteral(" /");
    }
    normalized += QLatin1Char('>');

    if (changed) {
        *changed = (normalized != rawTag);
    }
    return normalized;
}

QString normalizeLegacyXmlTags(const QString& xml) {
    QString normalized;
    normalized.reserve(xml.size() + 64);
    QVector<QString> openTagStack;

    int cursor = 0;
    while (cursor < xml.size()) {
        const int tagStart = xml.indexOf(QLatin1Char('<'), cursor);
        if (tagStart < 0) {
            normalized += xml.mid(cursor);
            break;
        }

        normalized += xml.mid(cursor, tagStart - cursor);
        if (xml.mid(tagStart, 4) == QStringLiteral("<!--")) {
            const int end = xml.indexOf(QStringLiteral("-->"), tagStart + 4);
            if (end < 0) {
                normalized += xml.mid(tagStart);
                break;
            }
            normalized += xml.mid(tagStart, end - tagStart + 3);
            cursor = end + 3;
            continue;
        }
        if (xml.mid(tagStart, 9) == QStringLiteral("<![CDATA[")) {
            const int end = xml.indexOf(QStringLiteral("]]>"), tagStart + 9);
            if (end < 0) {
                normalized += xml.mid(tagStart);
                break;
            }
            normalized += xml.mid(tagStart, end - tagStart + 3);
            cursor = end + 3;
            continue;
        }
        if (xml.mid(tagStart, 2) == QStringLiteral("<?")) {
            const int end = xml.indexOf(QStringLiteral("?>"), tagStart + 2);
            if (end < 0) {
                normalized += xml.mid(tagStart);
                break;
            }
            normalized += xml.mid(tagStart, end - tagStart + 2);
            cursor = end + 2;
            continue;
        }

        const int tagEnd = xml.indexOf(QLatin1Char('>'), tagStart + 1);
        if (tagEnd < 0) {
            normalized += xml.mid(tagStart);
            break;
        }

        const QString rawTag = xml.mid(tagStart, tagEnd - tagStart + 1);
        const XmlTagInfo rawInfo = parseXmlTagInfo(rawTag);
        if (rawInfo.parsed && rawInfo.isEnd) {
            if (!openTagStack.isEmpty()) {
                const QString expected = openTagStack.last();
                if (rawInfo.name.compare(expected, Qt::CaseInsensitive) == 0) {
                    openTagStack.removeLast();
                    if (rawInfo.name.compare(expected, Qt::CaseSensitive) == 0) {
                        normalized += rawTag;
                    } else {
                        normalized += QStringLiteral("</%1>").arg(expected);
                    }
                } else {
                    normalized += rawTag;
                }
            } else {
                normalized += rawTag;
            }
            cursor = tagEnd + 1;
            continue;
        }

        const QString normalizedTag = normalizeLegacyStartTag(rawTag);
        normalized += normalizedTag;

        const XmlTagInfo normalizedInfo = parseXmlTagInfo(normalizedTag);
        if (normalizedInfo.parsed && normalizedInfo.isStart && !normalizedInfo.selfClosing) {
            openTagStack.append(normalizedInfo.name);
        }
        cursor = tagEnd + 1;
    }

    return normalized;
}

QString sanitizeLegacyXml(const QString& xml) {
    QString sanitized = stripInvalidXml10Chars(xml);
    sanitized = normalizeLegacyXmlTags(sanitized);
    sanitized = escapeBareAmpersands(sanitized);
    return sanitized;
}

const SkinElement* findWindowElement(const SkinWindow& window, const QString& type) {
    for (const auto& element : window.elements) {
        if (element.type.compare(type, Qt::CaseInsensitive) == 0) {
            return &element;
        }
    }
    return nullptr;
}

QColor blendColors(const QColor& a, const QColor& b, qreal ratioToB) {
    const qreal clamped = qBound<qreal>(0.0, ratioToB, 1.0);
    const qreal inv = 1.0 - clamped;
    return QColor(
        qRound(a.red() * inv + b.red() * clamped),
        qRound(a.green() * inv + b.green() * clamped),
        qRound(a.blue() * inv + b.blue() * clamped));
}

QColor adjustBrightness(const QColor& color, qreal factor) {
    const auto scale = [factor](int channel) {
        return qBound(0, qRound(channel * factor), 255);
    };
    return QColor(scale(color.red()), scale(color.green()), scale(color.blue()));
}

int colorLuma(const QColor& color) {
    return qRound(color.red() * 0.299 + color.green() * 0.587 + color.blue() * 0.114);
}

QColor contrastingTextColor(const QColor& background) {
    return colorLuma(background) >= 140 ? QColor(0x20, 0x20, 0x20) : QColor(0xF2, 0xF2, 0xF2);
}

QColor averageOpaqueColor(const QPixmap& pixmap, QRect sampleRect = {}) {
    if (pixmap.isNull()) {
        return {};
    }

    const QImage image = pixmap.toImage().convertToFormat(QImage::Format_ARGB32);
    if (image.isNull()) {
        return {};
    }

    sampleRect = sampleRect.isValid()
        ? sampleRect.intersected(image.rect())
        : image.rect();
    if (sampleRect.width() > 4 && sampleRect.height() > 4) {
        sampleRect.adjust(2, 2, -2, -2);
    }
    if (!sampleRect.isValid() || sampleRect.isEmpty()) {
        sampleRect = image.rect();
    }

    qint64 red = 0;
    qint64 green = 0;
    qint64 blue = 0;
    qint64 count = 0;
    for (int y = sampleRect.top(); y <= sampleRect.bottom(); ++y) {
        for (int x = sampleRect.left(); x <= sampleRect.right(); ++x) {
            const QRgb pixel = image.pixel(x, y);
            if (qAlpha(pixel) == 0) {
                continue;
            }
            red += qRed(pixel);
            green += qGreen(pixel);
            blue += qBlue(pixel);
            ++count;
        }
    }

    if (count == 0) {
        return {};
    }
    return QColor(int(red / count), int(green / count), int(blue / count));
}

QColor inferPlaylistBackground(const SkinData& skin) {
    const SkinWindow& window = skin.playlistWindow;
    if (!window.backgroundPixmap.isNull()) {
        QRect sampleRect;
        if (const SkinElement* playlistElement = findWindowElement(window, QStringLiteral("playlist"))) {
            sampleRect = playlistElement->position;
        }
        const QColor sampled = averageOpaqueColor(window.backgroundPixmap, sampleRect);
        if (sampled.isValid()) {
            return sampled;
        }
    }
    return {};
}

QColor inferPlaylistAccent(const SkinData& skin, const QColor& fallbackBackground) {
    const SkinWindow& window = skin.playlistWindow;
    if (window.hilightColor.isValid()) {
        return window.hilightColor;
    }
    if (const SkinElement* titleElement = findWindowElement(window, QStringLiteral("title"))) {
        if (titleElement->color.isValid()) {
            return titleElement->color;
        }
        const QColor sampled = averageOpaqueColor(titleElement->statePixmaps[0]);
        if (sampled.isValid()) {
            return sampled;
        }
    }
    if (fallbackBackground.isValid()) {
        const QColor text = contrastingTextColor(fallbackBackground);
        return blendColors(text, fallbackBackground, 0.2);
    }
    return {};
}

void resolvePlaylistTheme(SkinData& skin) {
    PlaylistConfig& cfg = skin.playlistConfig;

    const QColor inferredBackground = inferPlaylistBackground(skin);
    QColor background = cfg.hasColorBkgnd ? cfg.colorBkgnd : inferredBackground;
    if (!background.isValid()) {
        background = cfg.colorBkgnd;
    }

    QColor accent = cfg.hasColorHilight ? cfg.colorHilight : inferPlaylistAccent(skin, background);
    if (!accent.isValid()) {
        accent = contrastingTextColor(background);
    }

    QColor text = cfg.hasColorText ? cfg.colorText : contrastingTextColor(background);
    QColor background2 = cfg.hasColorBkgnd2
        ? cfg.colorBkgnd2
        : adjustBrightness(background, colorLuma(background) >= 128 ? 0.92 : 1.08);
    QColor select = cfg.hasColorSelect
        ? cfg.colorSelect
        : blendColors(background, accent, 0.42);
    QColor number = cfg.hasColorNumber
        ? cfg.colorNumber
        : blendColors(text, accent, 0.30);
    QColor duration = cfg.hasColorDuration
        ? cfg.colorDuration
        : blendColors(text, accent, 0.55);

    cfg.colorBkgnd = background;
    cfg.colorBkgnd2 = background2;
    cfg.colorHilight = accent;
    cfg.colorText = text;
    cfg.colorSelect = select;
    cfg.colorNumber = number;
    cfg.colorDuration = duration;
}

bool hasRarSignature(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return false;
    }
    const QByteArray header = file.read(8);
    return header.startsWith("Rar!\x1A\x07");
}

bool extractArchiveWithUnar(const QString& archivePath, const QString& outputDir) {
    QProcess process;
    process.start(QStringLiteral("unar"),
                  {QStringLiteral("-quiet"),
                   QStringLiteral("-output-directory"), outputDir,
                   archivePath});
    if (!process.waitForFinished(30000)) {
        process.kill();
        process.waitForFinished();
        return false;
    }
    return process.exitStatus() == QProcess::NormalExit && process.exitCode() == 0;
}

bool extractZipArchive(const QString& archivePath, const QString& outputDir) {
    QuaZip zip(archivePath);
    if (!zip.open(QuaZip::mdUnzip)) {
        return false;
    }

    for (bool more = zip.goToFirstFile(); more; more = zip.goToNextFile()) {
        const QString name = zip.getCurrentFileName();
        QuaZipFile zf(&zip);
        if (!zf.open(QIODevice::ReadOnly)) {
            continue;
        }

        const QString outPath = outputDir + QLatin1Char('/') + name;
        QDir().mkpath(QFileInfo(outPath).path());
        QFile outFile(outPath);
        if (outFile.open(QIODevice::WriteOnly)) {
            outFile.write(zf.readAll());
            outFile.close();
        }
        zf.close();
    }
    zip.close();
    return true;
}

bool extractSkinArchive(const QString& sknPath, const QString& outputDir, QString* actualArchivePath = nullptr) {
    if (extractZipArchive(sknPath, outputDir)) {
        if (actualArchivePath) {
            *actualArchivePath = sknPath;
        }
        return true;
    }

    if (!hasRarSignature(sknPath)) {
        return false;
    }

    QTemporaryDir rarTempDir;
    if (!rarTempDir.isValid()) {
        return false;
    }
    rarTempDir.setAutoRemove(false);
    if (!extractArchiveWithUnar(sknPath, rarTempDir.path())) {
        return false;
    }

    const auto entries = QDir(rarTempDir.path()).entryInfoList(
        QDir::Files | QDir::NoDotAndDotDot, QDir::Name | QDir::IgnoreCase);
    for (const auto& entry : entries) {
        const QString suffix = entry.suffix().toLower();
        if ((suffix == QStringLiteral("skn") || suffix == QStringLiteral("zip")) &&
            extractZipArchive(entry.absoluteFilePath(), outputDir)) {
            if (actualArchivePath) {
                *actualArchivePath = entry.absoluteFilePath();
            }
            return true;
        }
    }

    return false;
}
}

SkinEngine::SkinEngine() = default;

namespace {
QString loadXmlText(const QString& path) {
    QFile xmlFile(path);
    if (!xmlFile.open(QIODevice::ReadOnly)) {
        qWarning() << "SkinEngine::loadXmlText: failed to open file:" << path;
        return {};
    }
    const QByteArray data = xmlFile.readAll();
    xmlFile.close();

    if (data.isEmpty()) {
        qWarning() << "SkinEngine::loadXmlText: file empty:" << path;
        return {};
    }
    qWarning() << "SkinEngine::loadXmlText: reading" << path << "size=" << data.size();

    if (data.startsWith("\xEF\xBB\xBF")) {
        qWarning() << "SkinEngine::loadXmlText: detected UTF-8 BOM";
        return sanitizeLegacyXml(QString::fromUtf8(data.mid(3)));
    }

    QString text = QString::fromUtf8(data);
    if (!text.contains(QChar::ReplacementCharacter)) {
        qWarning() << "SkinEngine::loadXmlText: decoded as UTF-8";
        return sanitizeLegacyXml(text);
    }
    qWarning() << "SkinEngine::loadXmlText: UTF-8 decode contains replacement chars";

    text = QString::fromLocal8Bit(data);
    if (!text.contains(QChar::ReplacementCharacter)) {
        qWarning() << "SkinEngine::loadXmlText: decoded as local 8-bit";
        return sanitizeLegacyXml(text);
    }
    qWarning() << "SkinEngine::loadXmlText: local8bit decode contains replacement chars";

    if (auto codec = QTextCodec::codecForName("GB18030")) {
        text = codec->toUnicode(data);
        if (!text.contains(QChar::ReplacementCharacter)) {
            qWarning() << "SkinEngine::loadXmlText: decoded as GB18030";
            return sanitizeLegacyXml(text);
        }
        qWarning() << "SkinEngine::loadXmlText: GB18030 decode contains replacement chars";
    } else {
        qWarning() << "SkinEngine::loadXmlText: GB18030 codec unavailable";
    }

    qWarning() << "SkinEngine::loadXmlText: falling back to UTF-8 with replacement";
    return sanitizeLegacyXml(QString::fromUtf8(data));
}

} // 匿名命名空间结束

// 加载皮肤配置 XML 文件，解析播放器、歌词、列表和可视化设置。
bool SkinEngine::loadSkinConfigXml(const QString& xmlPath, SkinData& skin) {
    if (xmlPath.isEmpty()) {
        return false;
    }

    const QString xmlContent = loadXmlText(xmlPath);
    if (xmlContent.isEmpty()) {
        return false;
    }

    parser_.parseSkinConfigXml(xmlContent, skin);
    parser_.parseLyricXml(xmlContent, skin);
    parser_.parsePlaylistXml(xmlContent, skin);
    parser_.parseVisualXml(xmlContent, skin);
    return true;
}

// 从 .skn 文件加载皮肤：解压 ZIP 包，然后读取其中的图片和 XML 配置。
bool SkinEngine::loadFromFile(const QString& sknPath) {
    QTemporaryDir tempDir;
    if (!tempDir.isValid()) {
        qWarning() << "SkinEngine::loadFromFile: Failed to create temporary extraction directory for:" << sknPath;
        return false;
    }
    tempDir.setAutoRemove(false); // 我们手动管理临时目录的清理

    const QString extractDir = tempDir.path();
    QString actualArchivePath;
    if (!extractSkinArchive(sknPath, extractDir, &actualArchivePath)) {
        if (hasRarSignature(sknPath)) {
            qWarning() << "SkinEngine::loadFromFile: RAR-wrapped skin is unsupported in selection list, extracted load failed:" << sknPath;
        } else {
            qWarning() << "SkinEngine::loadFromFile: Failed to open .skn archive:" << sknPath;
        }
        return false;
    }

    if (!loadFromDirectory(extractDir)) {
        qWarning() << "SkinEngine::loadFromFile: Failed to load extracted skin directory:" << extractDir;
        return false;
    }

    const QStringList configCandidates = sidecarConfigCandidates(sknPath);
    bool anyConfigLoaded = false;
    for (const auto& candidate : configCandidates) {
        if (loadSkinConfigXml(candidate, skin_)) {
            anyConfigLoaded = true;
        }
    }
    if (!anyConfigLoaded && !configCandidates.isEmpty()) {
        qWarning() << "SkinEngine::loadFromFile: found sidecar config files but failed to load any for" << sknPath
                   << "candidates:" << configCandidates;
    }
    resolvePlaylistTheme(skin_);
    return true;
}

// 从已解压皮肤目录加载资源并解析 Skin.xml/侧车配置。
bool SkinEngine::loadFromDirectory(const QString& dirPath) {
    loaded_ = false;

    // 加载目录中的图片资源，支持 BMP/PNG/JPG/ICO。
    QMap<QString, QImage> images;
    if (!loadImages(dirPath, images)) {
        qWarning() << "SkinEngine::loadFromDirectory: No image resources found in" << dirPath;
        return false;
    }

    // 读取 Skin.xml 配置文件
    const QString skinXmlPath = findSkinFileCaseInsensitive(dirPath, "Skin.xml");
    if (skinXmlPath.isEmpty()) {
        qWarning() << "SkinEngine::loadFromDirectory: Skin.xml not found in" << dirPath;
        return false;
    }
    QFile skinXml(skinXmlPath);
    if (!skinXml.open(QIODevice::ReadOnly | QIODevice::Text)) {
        qWarning() << "SkinEngine::loadFromDirectory: Failed to open Skin.xml:" << skinXmlPath;
        return false;
    }

    QString xmlContent = loadXmlText(skinXml.fileName());
    skinXml.close();

    if (xmlContent.isEmpty()) {
        qWarning() << "SkinEngine::loadFromDirectory: Skin.xml content empty or invalid encoding:" << skinXmlPath;
        return false;
    }

    SkinData parsedSkin;
    QColor defaultTransColor(255, 0, 255);
    if (!parser_.parse(xmlContent, images, defaultTransColor, parsedSkin)) {
        qWarning() << "SkinEngine::loadFromDirectory: SkinParser failed to parse Skin.xml:" << skinXmlPath;
        return false;
    }

    // 如果存在，则加载 Lyric.xml
    const QString lyricPath = findSkinFileCaseInsensitive(dirPath, "Lyric.xml");
    if (!lyricPath.isEmpty()) {
        const QString lyricXmlContent = loadXmlText(lyricPath);
        if (!lyricXmlContent.isEmpty()) {
            parser_.parseLyricXml(lyricXmlContent, parsedSkin);
        }
    }

    // 如果存在，则加载 PlayList.xml
    const QString playlistPath = findSkinFileCaseInsensitive(dirPath, "PlayList.xml");
    if (!playlistPath.isEmpty()) {
        const QString playlistXmlContent = loadXmlText(playlistPath);
        if (!playlistXmlContent.isEmpty()) {
            parser_.parsePlaylistXml(playlistXmlContent, parsedSkin);
        }
    }

    // Visual.xml 可选，用于控制频谱和模糊示波图颜色。
    const QString visualPath = findSkinFileCaseInsensitive(dirPath, "Visual.xml");
    if (!visualPath.isEmpty()) {
        const QString visualXmlContent = loadXmlText(visualPath);
        if (!visualXmlContent.isEmpty()) {
            parser_.parseVisualXml(visualXmlContent, parsedSkin);
        }
    }

    resolvePlaylistTheme(parsedSkin);
    skin_ = std::move(parsedSkin);
    loaded_ = true;
    return true;
}

// 尝试从已知路径加载 Classic 默认皮肤作为回退。
// 尝试从已知路径加载 Classic 默认皮肤作为回退。
bool SkinEngine::loadDefault() {
    QStringList searchPaths;
    searchPaths << "/home/john/Downloads/TTPlayer-main/TTPlayerv5.7.9/Skin/Classic.skn";
    searchPaths << "/home/john/Downloads/TTPlayer-main/build/Skin/Classic.skn";
    searchPaths << QDir::currentPath() + "/Skin/Classic.skn";
    searchPaths << QDir::currentPath() + QStringLiteral("/../build/Skin/Classic.skn");
    searchPaths << QDir::currentPath() + "/../../build/Skin/Classic.skn";
    searchPaths << QDir::currentPath() + QStringLiteral("/../TTPlayerv5.7.9/Skin/Classic.skn");
    searchPaths << QDir::currentPath() + "/../../TTPlayerv5.7.9/Skin/Classic.skn";
    searchPaths << "/home/john/.wine/drive_c/Program Files (x86)/TTPlayer/Skin/Classic.skn";
    searchPaths << QDir::currentPath() + "/skins/Classic.skn";

    for (int i = 0; i < searchPaths.size(); ++i) {
        const QString& path = searchPaths.at(i);
        if (QFile::exists(path) && loadFromFile(path)) {
            loadSkinConfigXml(QFileInfo(path).dir().absoluteFilePath("Default.xml"), skin_);
            return true;
        }
    }

    return false;
}

// 读取皮肤目录中的图片资源，并按文件名小写存储。
bool SkinEngine::loadImages(const QString& dirPath, QMap<QString, QImage>& images) {
    QDir dir(dirPath);
    QStringList filters = {"*.bmp", "*.png", "*.jpg", "*.ico"};
    auto files = dir.entryInfoList(filters, QDir::Files);

    for (const auto& fi : files) {
        QImage img(fi.absoluteFilePath());
        if (!img.isNull()) {
            images[fi.fileName().toLower()] = img;
        }
    }

    return !images.isEmpty();
}
