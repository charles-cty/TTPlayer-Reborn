#pragma once
#include <QString>
#include <QVector>
#include <QByteArray>

struct LrcLine {
    int64_t timeMs;
    QString text;
};

struct LrcData {
    QString title;
    QString artist;
    QString album;
    int offset = 0;
    QVector<LrcLine> lines;
};

class LrcParser {
public:
    // 编码选项
    enum Encoding {
        AutoDetect = 0,   // 自动检测（UTF-8 → 本地编码）
        UTF8,
        GBK,
        BIG5,
        ShiftJIS,
        EUC_KR,
        Latin1
    };

    LrcData parse(const QByteArray& data, Encoding encoding = AutoDetect);
    LrcData parseFile(const QString& filePath, Encoding encoding = AutoDetect);

    static QString encodingName(Encoding enc);
    static QVector<QPair<Encoding, QString>> availableEncodings();

private:
    int64_t parseTime(const QString& timeStr);
    QString decodeText(const QByteArray& data, Encoding encoding);
};
