#include "LrcParser.h"
#include <QFile>
#include <QTextStream>
#include <QRegularExpression>
#include <QStringConverter>
#include <algorithm>

QString LrcParser::decodeText(const QByteArray& data, Encoding encoding) {
    switch (encoding) {
    case UTF8:
        return QString::fromUtf8(data);
    case GBK: {
        auto decoder = QStringDecoder(QStringDecoder::Encoding::System);
        // 尝试通过编码器名称加载 GBK 编码
        auto gbkDecoder = QStringDecoder("GBK");
        if (gbkDecoder.isValid())
            return gbkDecoder(data);
        return QString::fromLocal8Bit(data);
    }
    case BIG5: {
        auto decoder = QStringDecoder("Big5");
        if (decoder.isValid())
            return decoder(data);
        return QString::fromLocal8Bit(data);
    }
    case ShiftJIS: {
        auto decoder = QStringDecoder("Shift-JIS");
        if (decoder.isValid())
            return decoder(data);
        return QString::fromLocal8Bit(data);
    }
    case EUC_KR: {
        auto decoder = QStringDecoder("EUC-KR");
        if (decoder.isValid())
            return decoder(data);
        return QString::fromLocal8Bit(data);
    }
    case Latin1:
        return QString::fromLatin1(data);
    case AutoDetect:
    default: {
        // 尝试 UTF-8
        QString text = QString::fromUtf8(data);
        if (!text.isEmpty() && !text.contains(QChar::ReplacementCharacter))
            return text;
        // 回退到 GBK
        auto gbkDecoder = QStringDecoder("GBK");
        if (gbkDecoder.isValid()) {
            QString gbkText = gbkDecoder(data);
            if (!gbkText.isEmpty())
                return gbkText;
        }
        // 最终回退
        return QString::fromLocal8Bit(data);
    }
    }
}

QString LrcParser::encodingName(Encoding enc) {
    switch (enc) {
    case AutoDetect: return QStringLiteral("自动检测");
    case UTF8:       return QStringLiteral("UTF-8");
    case GBK:        return QStringLiteral("GBK (简体中文)");
    case BIG5:       return QStringLiteral("Big5 (繁体中文)");
    case ShiftJIS:   return QStringLiteral("Shift-JIS (日文)");
    case EUC_KR:     return QStringLiteral("EUC-KR (韩文)");
    case Latin1:     return QStringLiteral("Latin-1 (西欧)");
    }
    return QStringLiteral("未知");
}

QVector<QPair<LrcParser::Encoding, QString>> LrcParser::availableEncodings() {
    return {
        {AutoDetect, encodingName(AutoDetect)},
        {UTF8,       encodingName(UTF8)},
        {GBK,        encodingName(GBK)},
        {BIG5,       encodingName(BIG5)},
        {ShiftJIS,   encodingName(ShiftJIS)},
        {EUC_KR,     encodingName(EUC_KR)},
        {Latin1,     encodingName(Latin1)},
    };
}

LrcData LrcParser::parse(const QByteArray& data, Encoding encoding) {
    LrcData result;
    QString text = decodeText(data, encoding);

    QStringList lineList = text.split('\n');
    static QRegularExpression timeRe(R"(\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\])");
    static QRegularExpression tagRe(R"(\[(\w+):([^\]]*)\])");

    for (const QString& line : lineList) {
        QString trimmed = line.trimmed();
        if (trimmed.isEmpty()) continue;

        // 检查元数据标签
        auto tagMatch = tagRe.match(trimmed);
        if (tagMatch.hasMatch() && !trimmed.contains(timeRe)) {
            QString key = tagMatch.captured(1).toLower();
            QString val = tagMatch.captured(2).trimmed();
            if (key == "ti") result.title = val;
            else if (key == "ar") result.artist = val;
            else if (key == "al") result.album = val;
            else if (key == "offset") result.offset = val.toInt();
            continue;
        }

        // 解析时间标记行——一行可以包含多个时间戳
        auto it = timeRe.globalMatch(trimmed);
        QVector<int64_t> times;
        int lastEnd = 0;
        while (it.hasNext()) {
            auto match = it.next();
            times.append(parseTime(match.captured(0)));
            lastEnd = match.capturedEnd(0);
        }

        if (!times.isEmpty()) {
            QString lyricText = trimmed.mid(lastEnd).trimmed();
            for (int64_t t : times) {
                result.lines.append({t + result.offset, lyricText});
            }
        }
    }

    // 按时间排序
    std::sort(result.lines.begin(), result.lines.end(),
              [](const LrcLine& a, const LrcLine& b) { return a.timeMs < b.timeMs; });

    return result;
}

LrcData LrcParser::parseFile(const QString& filePath, Encoding encoding) {
    QFile f(filePath);
    if (!f.open(QIODevice::ReadOnly)) return {};
    return parse(f.readAll(), encoding);
}

int64_t LrcParser::parseTime(const QString& timeStr) {
    static QRegularExpression re(R"(\[(\d{2}):(\d{2})(?:\.(\d{2,3}))?\])");
    auto match = re.match(timeStr);
    if (!match.hasMatch()) return 0;

    int64_t mins = match.captured(1).toLongLong();
    int64_t secs = match.captured(2).toLongLong();
    int64_t ms = 0;
    if (!match.captured(3).isEmpty()) {
        QString msStr = match.captured(3);
        ms = msStr.toLongLong();
        if (msStr.length() == 2) ms *= 10; // [mm:ss.xx] → centiseconds
    }

    return mins * 60000 + secs * 1000 + ms;
}
