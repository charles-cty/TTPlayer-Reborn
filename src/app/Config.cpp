#include "Config.h"
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMap>
#include <QRect>
#include <QStandardPaths>
#include <QStringList>
#include <QXmlStreamReader>
#include <QXmlStreamWriter>

namespace {
int parseInt(QStringView value, int fallback) {
    bool ok = false;
    const int result = value.toString().trimmed().toInt(&ok);
    return ok ? result : fallback;
}

float parseFloat(QStringView value, float fallback) {
    bool ok = false;
    const float result = value.toString().trimmed().toFloat(&ok);
    return ok ? result : fallback;
}

bool parseBool(QStringView value, bool fallback) {
    const QString text = value.toString().trimmed().toLower();
    if (text.isEmpty()) {
        return fallback;
    }
    if (text == QStringLiteral("1") || text == QStringLiteral("true") || text == QStringLiteral("yes")) {
        return true;
    }
    if (text == QStringLiteral("0") || text == QStringLiteral("false") || text == QStringLiteral("no")) {
        return false;
    }
    return fallback;
}

QRect parseRectAttr(const QString& value) {
    const QStringList parts = value.split(',', Qt::SkipEmptyParts);
    if (parts.size() < 4) {
        return {};
    }
    const int x1 = parseInt(parts[0], 0);
    const int y1 = parseInt(parts[1], 0);
    const int x2 = parseInt(parts[2], x1);
    const int y2 = parseInt(parts[3], y1);
    return QRect(x1, y1, qMax(0, x2 - x1), qMax(0, y2 - y1));
}

QString rectToAttr(const QPoint& topLeft, int width, int height) {
    const int x1 = topLeft.x();
    const int y1 = topLeft.y();
    const int x2 = x1 + qMax(0, width);
    const int y2 = y1 + qMax(0, height);
    return QStringLiteral("%1,%2,%3,%4").arg(x1).arg(y1).arg(x2).arg(y2);
}

QPoint parseWindowTopLeft(const QXmlStreamAttributes& attrs, const char* key, const QPoint& fallback) {
    if (!attrs.hasAttribute(key)) {
        return fallback;
    }
    const QRect rect = parseRectAttr(attrs.value(key).toString());
    if (rect.isNull() && rect.topLeft().isNull()) {
        return fallback;
    }
    return rect.topLeft();
}

QSize parseWindowSize(const QXmlStreamAttributes& attrs, const char* key, const QSize& fallback) {
    if (!attrs.hasAttribute(key)) {
        return fallback;
    }
    const QRect rect = parseRectAttr(attrs.value(key).toString());
    if (rect.width() <= 0 || rect.height() <= 0) {
        return fallback;
    }
    return rect.size();
}

QString encodeEqualizerProfile(float preamp, const float bands[10]) {
    QStringList values;
    values.reserve(10);
    for (int i = 0; i < 10; ++i) {
        values.append(QString::number(bands[i], 'f', 1));
    }
    return QStringLiteral("%1:%2")
        .arg(QString::number(preamp, 'f', 1), values.join(QLatin1Char(',')));
}

void decodeEqualizerProfile(const QString& encoded, float& preamp, float bands[10]) {
    if (encoded.isEmpty()) {
        return;
    }
    const int colon = encoded.indexOf(QLatin1Char(':'));
    if (colon < 0) {
        return;
    }

    preamp = parseFloat(QStringView{encoded}.left(colon), preamp);
    const QStringList values = encoded.mid(colon + 1).split(',', Qt::KeepEmptyParts);
    for (int i = 0; i < 10 && i < values.size(); ++i) {
        bands[i] = parseFloat(values[i], bands[i]);
    }
}

QString skinPackageNameFromSelection(const QString& selection) {
    if (selection.isEmpty() || selection == QStringLiteral("__skin__:follow-original")) {
        return QStringLiteral("<Default_Skin>");
    }
    if (selection == QStringLiteral("__skin__:builtin-default")) {
        return QStringLiteral("<Default_Skin>");
    }

    const QFileInfo info(selection);
    if (info.exists() && info.isFile()) {
        return info.fileName();
    }

    if (selection.endsWith(QStringLiteral(".skn"), Qt::CaseInsensitive)) {
        return QFileInfo(selection).fileName();
    }

    return selection;
}

void writeEmptySection(QXmlStreamWriter& xml, const QString& section,
                       const QMap<QString, QString>& attrs) {
    xml.writeEmptyElement(section);
    for (auto it = attrs.cbegin(); it != attrs.cend(); ++it) {
        xml.writeAttribute(it.key(), it.value());
    }
}
} // namespace

// 构造函数，初始化均衡器频段默认值。
Config::Config() {
    for (int i = 0; i < 10; i++) eqBands_[i] = 0.0f;
}

// 获取指定 EQ 频段的增益值。
float Config::eqBand(int index) const {
    if (index < 0 || index >= 10) return 0.0f;
    return eqBands_[index];
}

// 设置指定 EQ 频段的增益值。
void Config::setEqBand(int index, float gain) {
    if (index >= 0 && index < 10) eqBands_[index] = gain;
}

QString Config::defaultPath() {
    const QString appDir = QCoreApplication::applicationDirPath();
    if (!appDir.isEmpty()) {
        return QDir(appDir).absoluteFilePath(QStringLiteral("TTPlayer.xml"));
    }
    return legacyPath();
}

QString Config::legacyPath() {
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    if (dir.isEmpty()) {
        return QStringLiteral("TTPlayer.xml");
    }
    QDir().mkpath(dir);
    return QDir(dir).absoluteFilePath(QStringLiteral("TTPlayer.xml"));
}

bool Config::load(const QString& filePath) {
    QFile f(filePath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return false;

    QXmlStreamReader xml(&f);
    QString section;

    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            const QString tag = xml.name().toString();
            const auto attrs = xml.attributes();

            // 原版 TTPlayer.xml（属性式）读取
            if (tag.compare(QStringLiteral("Player"), Qt::CaseInsensitive) == 0 && !attrs.isEmpty()) {
                playerPos_ = parseWindowTopLeft(attrs, "PlayerWnd", playerPos_);
                playerSize_ = parseWindowSize(attrs, "PlayerWnd", playerSize_);
                lyricPos_ = parseWindowTopLeft(attrs, "LyricWnd", lyricPos_);
                lyricSize_ = parseWindowSize(attrs, "LyricWnd", lyricSize_);
                eqPos_ = parseWindowTopLeft(attrs, "EqualizerWnd", eqPos_);
                eqSize_ = parseWindowSize(attrs, "EqualizerWnd", eqSize_);
                playlistPos_ = parseWindowTopLeft(attrs, "PlayListWnd", playlistPos_);
                playlistSize_ = parseWindowSize(attrs, "PlayListWnd", playlistSize_);

                lyricVisible_ = parseBool(attrs.value("LyricVisible"), lyricVisible_);
                eqVisible_ = parseBool(attrs.value("EqualizerVisible"), eqVisible_);
                playlistVisible_ = parseBool(attrs.value("PlayListVisible"), playlistVisible_);
                alwaysOnTop_ = attrs.hasAttribute("TopMost")
                    ? parseBool(attrs.value("TopMost"), alwaysOnTop_)
                    : parseBool(attrs.value("AlwaysOnTop"), alwaysOnTop_);

                repeatMode_ = parseInt(attrs.value("PlayMode"), repeatMode_);
                if (attrs.hasAttribute("Shuffle")) {
                    shuffle_ = parseBool(attrs.value("Shuffle"), shuffle_);
                }

                volume_ = parseInt(attrs.value("Volume"), volume_);
                muted_ = parseBool(attrs.value("Mute"), muted_);
                balance_ = parseInt(attrs.value("Balance"), balance_);

                if (attrs.hasAttribute("PlayingFileName")) {
                    const QString playing = attrs.value("PlayingFileName").toString();
                    if (!playing.isEmpty()) {
                        lastFile_ = playing;
                    }
                }

                if (attrs.hasAttribute("SplitOnLists")) {
                    playlistSplitPos_ = parseInt(attrs.value("SplitOnLists"), playlistSplitPos_);
                }

                if (attrs.hasAttribute("PlayLists")) {
                    playlistCount_ = qMax(1, parseInt(attrs.value("PlayLists"), playlistCount_));
                }
                if (attrs.hasAttribute("ActiveList")) {
                    activeList_ = qMax(0, parseInt(attrs.value("ActiveList"), activeList_));
                }
            } else if (tag.compare(QStringLiteral("Playback"), Qt::CaseInsensitive) == 0 &&
                       !attrs.isEmpty()) {
                if (attrs.hasAttribute("RepeatMode")) {
                    repeatMode_ = parseInt(attrs.value("RepeatMode"), repeatMode_);
                }
                if (attrs.hasAttribute("Shuffle")) {
                    shuffle_ = parseBool(attrs.value("Shuffle"), shuffle_);
                }
            } else if (tag.compare(QStringLiteral("Equalizer"), Qt::CaseInsensitive) == 0 &&
                       !attrs.isEmpty()) {
                if (attrs.hasAttribute("Current")) {
                    decodeEqualizerProfile(attrs.value("Current").toString(), eqPreamp_, eqBands_);
                } else if (attrs.hasAttribute("Custom")) {
                    decodeEqualizerProfile(attrs.value("Custom").toString(), eqPreamp_, eqBands_);
                }

                if (attrs.hasAttribute("Enabled")) {
                    eqEnabled_ = parseBool(attrs.value("Enabled"), eqEnabled_);
                }
                if (attrs.hasAttribute("Preamp")) {
                    eqPreamp_ = parseFloat(attrs.value("Preamp"), eqPreamp_);
                }
                for (int i = 0; i < 10; ++i) {
                    const QString key = QStringLiteral("Band%1").arg(i);
                    if (attrs.hasAttribute(key)) {
                        eqBands_[i] = parseFloat(attrs.value(key), eqBands_[i]);
                    }
                }
            } else if (tag.compare(QStringLiteral("Histroy"), Qt::CaseInsensitive) == 0 &&
                       !attrs.isEmpty()) {
                if (attrs.hasAttribute("SplitOnLists")) {
                    playlistSplitPos_ = parseInt(attrs.value("SplitOnLists"), playlistSplitPos_);
                }
                if (attrs.hasAttribute("PlayListPath")) {
                    playlistDir_ = attrs.value("PlayListPath").toString();
                }
            } else if (tag.compare(QStringLiteral("Skin"), Qt::CaseInsensitive) == 0 &&
                       !attrs.isEmpty()) {
                const QString path = attrs.value("Path").toString();
                if (!path.isEmpty()) {
                    skinPath_ = path;
                } else {
                    const QString packageName = attrs.value("PackageName").toString();
                    if (packageName == QStringLiteral("<Default_Skin>")) {
                        skinPath_ = QStringLiteral("__skin__:builtin-default");
                    } else if (!packageName.isEmpty()) {
                        skinPath_ = packageName;
                    }
                }
            }

            if (tag == "Player" || tag == "Playback" || tag == "Equalizer" ||
                tag == "Skin" || tag == "PlayList") {
                section = tag;
            }

            if (section == "Player") {
                if (tag == "Volume") volume_ = xml.readElementText().toInt();
                else if (tag == "Mute") muted_ = xml.readElementText().toInt();
                else if (tag == "Balance") balance_ = xml.readElementText().toInt();
                else if (tag == "PlayerX") playerPos_.setX(xml.readElementText().toInt());
                else if (tag == "PlayerY") playerPos_.setY(xml.readElementText().toInt());
                else if (tag == "LyricX") lyricPos_.setX(xml.readElementText().toInt());
                else if (tag == "LyricY") lyricPos_.setY(xml.readElementText().toInt());
                else if (tag == "EqX") eqPos_.setX(xml.readElementText().toInt());
                else if (tag == "EqY") eqPos_.setY(xml.readElementText().toInt());
                else if (tag == "PlayListX") playlistPos_.setX(xml.readElementText().toInt());
                else if (tag == "PlayListY") playlistPos_.setY(xml.readElementText().toInt());
                else if (tag == "SplitOnLists") playlistSplitPos_ = xml.readElementText().toInt();
                else if (tag == "LyricVisible") lyricVisible_ = xml.readElementText().toInt();
                else if (tag == "EqVisible") eqVisible_ = xml.readElementText().toInt();
                else if (tag == "PlayListVisible") playlistVisible_ = xml.readElementText().toInt();
                else if (tag == "AlwaysOnTop") alwaysOnTop_ = xml.readElementText().toInt();
                else if (tag == "LastFile") lastFile_ = xml.readElementText();
            }
            else if (section == "Playback") {
                if (tag == "RepeatMode") repeatMode_ = xml.readElementText().toInt();
                else if (tag == "Shuffle") shuffle_ = xml.readElementText().toInt();
            }
            else if (section == "Equalizer") {
                if (tag == "Enabled") eqEnabled_ = xml.readElementText().toInt();
                else if (tag == "Preamp") eqPreamp_ = xml.readElementText().toFloat();
                else if (tag.startsWith("Band")) {
                    int idx = tag.mid(4).toInt();
                    if (idx >= 0 && idx < 10) eqBands_[idx] = xml.readElementText().toFloat();
                }
            }
            else if (section == "Skin") {
                if (tag == "Path") skinPath_ = xml.readElementText();
                else if (tag == "PackageName") skinPath_ = xml.readElementText();
            }
        }
        else if (xml.isEndElement()) {
            QString tag = xml.name().toString();
            if (tag == section) section.clear();
        }
    }

    return !xml.hasError();
}

bool Config::save(const QString& filePath) const {
    const QString dirPath = QFileInfo(filePath).absolutePath();
    if (!dirPath.isEmpty()) {
        QDir().mkpath(dirPath);
    }

    QFile f(filePath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;

    QXmlStreamWriter xml(&f);
    xml.setAutoFormatting(true);
    xml.writeStartDocument();
    xml.writeStartElement(QStringLiteral("ttplayer"));
    xml.writeAttribute(QStringLiteral("version"), QStringLiteral("5.7.9"));

    QMap<QString, QString> playerAttrs;
    playerAttrs.insert(QStringLiteral("PlayerWnd"),
                       rectToAttr(playerPos_, playerSize_.width(), playerSize_.height()));
    playerAttrs.insert(QStringLiteral("PlayerWnd2"), QStringLiteral("0,0,0,0"));
    playerAttrs.insert(QStringLiteral("LyricWnd"),
                       rectToAttr(lyricPos_, lyricSize_.width(), lyricSize_.height()));
    playerAttrs.insert(QStringLiteral("LyricWnd2"), QStringLiteral("0,0,0,0"));
    playerAttrs.insert(QStringLiteral("EqualizerWnd"),
                       rectToAttr(eqPos_, eqSize_.width(), eqSize_.height()));
    playerAttrs.insert(QStringLiteral("PlayListWnd"),
                       rectToAttr(playlistPos_, playlistSize_.width(), playlistSize_.height()));
    playerAttrs.insert(QStringLiteral("LyricVisible"), lyricVisible_ ? QStringLiteral("1") : QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("EqualizerVisible"), eqVisible_ ? QStringLiteral("1") : QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("PlayListVisible"), playlistVisible_ ? QStringLiteral("1") : QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("MiniMode"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("DesklrcWnd"), QStringLiteral("0,0,0,0"));
    playerAttrs.insert(QStringLiteral("TopMost"), alwaysOnTop_ ? QStringLiteral("1") : QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("LyricTopMost"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("TopMost2"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("LyricTopMost2"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("LyricVisible2"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("OpaqueWhenActive"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("AlphaPercent"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("WindowShadow"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("PlayMode"), QString::number(repeatMode_));
    playerAttrs.insert(QStringLiteral("Shuffle"), shuffle_ ? QStringLiteral("1") : QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("AutoSwitchList"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("PlayFollowCursor"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("PlayLists"), QString::number(playlistCount_));
    playerAttrs.insert(QStringLiteral("ActiveList"), QString::number(activeList_));
    playerAttrs.insert(QStringLiteral("PlayingTime"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("PlayingFileName"), lastFile_);
    playerAttrs.insert(QStringLiteral("PlayingFileSubTrack"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("Mute"), muted_ ? QStringLiteral("1") : QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("Volume"), QString::number(volume_));
    playerAttrs.insert(QStringLiteral("Balance"), QString::number(balance_));
    playerAttrs.insert(QStringLiteral("ShowElapsedTime"), QStringLiteral("1"));
    playerAttrs.insert(QStringLiteral("CheckAssociation"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("AutoAssociate"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("FirstRun_552"), QStringLiteral("0"));
    playerAttrs.insert(QStringLiteral("UserWord"), QString());
    playerAttrs.insert(QStringLiteral("UserWordMD5"), QString());
    writeEmptySection(xml, QStringLiteral("Player"), playerAttrs);

    writeEmptySection(xml, QStringLiteral("General"), {
        {QStringLiteral("StartupMinimize"), QStringLiteral("0")},
        {QStringLiteral("TrayIcon"), QStringLiteral("1")},
        {QStringLiteral("Fade_Windows"), QStringLiteral("0")},
        {QStringLiteral("ShowHotKeyInTips"), QStringLiteral("1")},
        {QStringLiteral("TipsOnOpen"), QStringLiteral("0")},
        {QStringLiteral("MenuTips"), QStringLiteral("1")},
        {QStringLiteral("MenuBarPlayList"), QStringLiteral("0")},
        {QStringLiteral("ScrollTitle"), QStringLiteral("1")},
        {QStringLiteral("SendTitleToMSN"), QStringLiteral("0")},
        {QStringLiteral("Snap_Windows"), QStringLiteral("65546")}
    });

    writeEmptySection(xml, QStringLiteral("Playback"), {
        {QStringLiteral("AutoPlay"), QStringLiteral("0")},
        {QStringLiteral("ContinuePlay"), QStringLiteral("0")},
        {QStringLiteral("StopWhenFail"), QStringLiteral("0")},
        {QStringLiteral("TracksInterval"), QStringLiteral("0")},
        {QStringLiteral("ThreadPriority"), QStringLiteral("15")},
        {QStringLiteral("FileBuffer"), QStringLiteral("16384")},
        {QStringLiteral("AutoGain"), QStringLiteral("1")},
        {QStringLiteral("RepeatMode"), QString::number(repeatMode_)},
        {QStringLiteral("Shuffle"), shuffle_ ? QStringLiteral("1") : QStringLiteral("0")}
    });

    writeEmptySection(xml, QStringLiteral("Device"), {
        {QStringLiteral("DeviceType"), QStringLiteral("{DEF00000-9C6D-47ED-AAF1-4DDA8F2B5C03}")},
        {QStringLiteral("OutputBits"), QStringLiteral("16")},
        {QStringLiteral("BufferDuration"), QStringLiteral("1000")},
        {QStringLiteral("HardwareBuffer"), QStringLiteral("1")},
        {QStringLiteral("ResampleRate"), QStringLiteral("0")}
    });

    writeEmptySection(xml, QStringLiteral("HotKey"), {
        {QStringLiteral("Global"), QStringLiteral("0")},
        {QStringLiteral("KeyMap_Count"), QStringLiteral("0")}
    });

    writeEmptySection(xml, QStringLiteral("Visual"), {
        {QStringLiteral("SpectrumTopColor"), QStringLiteral("#00ffff")},
        {QStringLiteral("SpectrumBtmColor"), QStringLiteral("#2e89a0")},
        {QStringLiteral("SpectrumMidColor"), QStringLiteral("#01d2f8")},
        {QStringLiteral("SpectrumPeakColor"), QStringLiteral("#ffffff")},
        {QStringLiteral("SpectrumWide"), QStringLiteral("1")},
        {QStringLiteral("BlurSpeed"), QStringLiteral("3")},
        {QStringLiteral("Blur"), QStringLiteral("1")},
        {QStringLiteral("TextColor"), QStringLiteral("#00ffff")},
        {QStringLiteral("Font"), QStringLiteral("-12,0,0,0,400,0,0,0,1,0,0,4,0,宋体")},
        {QStringLiteral("BlurScopeColor"), QStringLiteral("#00ffff")},
        {QStringLiteral("Type"), QStringLiteral("1")},
        {QStringLiteral("FramesPerSec"), QStringLiteral("25")}
    });

    writeEmptySection(xml, QStringLiteral("FullScreen"), {
        {QStringLiteral("VisualType"), QStringLiteral("1")},
        {QStringLiteral("PosRelationAll"), QStringLiteral("0")},
        {QStringLiteral("LrcSizeAll"), QStringLiteral("2")}
    });

    writeEmptySection(xml, QStringLiteral("DeskLrc"), {
        {QStringLiteral("Profile"), QStringLiteral("0")},
        {QStringLiteral("Lines"), QStringLiteral("2")},
        {QStringLiteral("Align"), QStringLiteral("3")},
        {QStringLiteral("Topmost"), QStringLiteral("1")},
        {QStringLiteral("KaraokeMode"), QStringLiteral("1")}
    });

    writeEmptySection(xml, QStringLiteral("Lyric"), {
        {QStringLiteral("Font"), QStringLiteral("-12,0,0,0,400,0,0,0,1,0,0,4,0,宋体")},
        {QStringLiteral("TextColor"), QStringLiteral("#009bbe")},
        {QStringLiteral("HilightColor"), QStringLiteral("#00ffff")},
        {QStringLiteral("BkgndColor"), QStringLiteral("#012d3c")},
        {QStringLiteral("AutoLoadLyric"), QStringLiteral("1")},
        {QStringLiteral("AutoSaveLyricTag"), QStringLiteral("1")}
    });

    writeEmptySection(xml, QStringLiteral("PlayList"), {
        {QStringLiteral("Font"), QStringLiteral("-11,0,0,0,400,0,0,0,1,0,0,4,0,Tahoma")},
        {QStringLiteral("Color_Text"), QStringLiteral("#009bbe")},
        {QStringLiteral("Color_Hilight"), QStringLiteral("#00ffff")},
        {QStringLiteral("Color_Bkgnd"), QStringLiteral("#003c50")},
        {QStringLiteral("Color_Number"), QStringLiteral("#00ffff")},
        {QStringLiteral("Color_Duration"), QStringLiteral("#00ffff")},
        {QStringLiteral("Color_Select"), QStringLiteral("#00ffff")},
        {QStringLiteral("Color_Bkgnd2"), QStringLiteral("#002d3c")}
    });

    writeEmptySection(xml, QStringLiteral("Library"), {
        {QStringLiteral("Enabled"), QStringLiteral("0")},
        {QStringLiteral("Valid"), QStringLiteral("0")}
    });

    writeEmptySection(xml, QStringLiteral("Network"), {
        {QStringLiteral("Proxy_Type"), QStringLiteral("0")},
        {QStringLiteral("Proxy_Server"), QString()},
        {QStringLiteral("Proxy_Port"), QStringLiteral("0")},
        {QStringLiteral("DoCache"), QStringLiteral("1")},
        {QStringLiteral("CacheSpaceSize"), QStringLiteral("600")}
    });

    writeEmptySection(xml, QStringLiteral("Convert"), {
        {QStringLiteral("WriterIndex"), QStringLiteral("0")},
        {QStringLiteral("OutputBits"), QStringLiteral("0")},
        {QStringLiteral("ResampleRate"), QStringLiteral("0")},
        {QStringLiteral("ReplayGain"), QStringLiteral("0")}
    });

    QMap<QString, QString> equalizerAttrs;
    const QString eqProfile = encodeEqualizerProfile(eqPreamp_, eqBands_);
    equalizerAttrs.insert(QStringLiteral("Profile"), QStringLiteral("-2"));
    equalizerAttrs.insert(QStringLiteral("ProfileLast"), QStringLiteral("-1"));
    equalizerAttrs.insert(QStringLiteral("Surround"), QStringLiteral("0"));
    equalizerAttrs.insert(QStringLiteral("Custom"), eqProfile);
    equalizerAttrs.insert(QStringLiteral("Current"), eqProfile);
    equalizerAttrs.insert(QStringLiteral("Enabled"), eqEnabled_ ? QStringLiteral("1") : QStringLiteral("0"));
    equalizerAttrs.insert(QStringLiteral("Preamp"), QString::number(eqPreamp_, 'f', 1));
    for (int i = 0; i < 10; ++i) {
        equalizerAttrs.insert(QStringLiteral("Band%1").arg(i), QString::number(eqBands_[i], 'f', 1));
    }
    writeEmptySection(xml, QStringLiteral("Equalizer"), equalizerAttrs);

    writeEmptySection(xml, QStringLiteral("Skin"), {
        {QStringLiteral("PackageName"), skinPackageNameFromSelection(skinPath_)},
        {QStringLiteral("Path"), skinPath_}
    });

    writeEmptySection(xml, QStringLiteral("Plugin"), {
        {QStringLiteral("Folder"), QDir(QCoreApplication::applicationDirPath()).absoluteFilePath(QStringLiteral("Plugins/"))},
        {QStringLiteral("Modules_Count"), QStringLiteral("0")}
    });

    writeEmptySection(xml, QStringLiteral("Histroy"), {
        {QStringLiteral("LastActivePage"), QStringLiteral("0")},
        {QStringLiteral("SplitOnLists"), QString::number(playlistSplitPos_)},
        {QStringLiteral("SoundPath"), QString()},
        {QStringLiteral("PlayListPath"), playlistDir_},
        {QStringLiteral("Folder"), QString()},
        {QStringLiteral("TagPattern"), QString()},
        {QStringLiteral("CheckSubFolder"), QStringLiteral("1")},
        {QStringLiteral("AdvanceFileInfo"), QStringLiteral("0")}
    });

    xml.writeEndElement(); // ttplayer 根元素结束
    xml.writeEndDocument();

    return true;
}
