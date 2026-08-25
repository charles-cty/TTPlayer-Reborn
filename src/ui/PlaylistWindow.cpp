#include "PlaylistWindow.h"
#include "playlist/TtblParser.h"
#include "playlist/TtblWriter.h"
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QImage>
#include <QPainter>
#include <QLinearGradient>
#include <QMouseEvent>
#include <QMetaType>
#include <QProgressDialog>
#include <QTimer>
#include <QContextMenuEvent>
#include <QDragEnterEvent>
#include <QDragMoveEvent>
#include <QDropEvent>
#include <QDrag>
#include <QFileDialog>
#include <QMimeData>
#include <QUrl>
#include <QWindow>
#include <QPolygon>
#include <QMenu>
#include <QAction>
#include <QActionGroup>
#include <QApplication>
#include <QMessageBox>
#include <QDirIterator>
#include <QRandomGenerator>
#include <QCursor>
#include <QDialog>
#include <QDialogButtonBox>
#include <QDateTime>
#include <QElapsedTimer>
#include <QFormLayout>
#include <QRegularExpression>
#include <QFileInfo>
#include <QFontMetrics>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QLabel>
#include <QPushButton>
#include <QScrollBar>
#include <QSet>
#include <QDataStream>
#include <QStyledItemDelegate>
#include <QVBoxLayout>
#include <QWheelEvent>
#include <algorithm>
#include <functional>

namespace {
bool shouldPreferManualMove() {
    return QGuiApplication::platformName() == "xcb";
}

QString playbackStateText(const AudioEngine* engine) {
    if (!engine) {
        return QStringLiteral("no_engine");
    }

    switch (engine->state()) {
    case AudioEngine::Stopped:
        return QStringLiteral("stopped");
    case AudioEngine::Playing:
        return QStringLiteral("playing");
    case AudioEngine::Paused:
        return QStringLiteral("paused");
    }

    return QStringLiteral("unknown");
}

QString wheelDeltaText(const QWheelEvent* event) {
    if (!event) {
        return QStringLiteral("0,0");
    }
    const QPoint angleDelta = event->angleDelta();
    return QStringLiteral("%1,%2").arg(angleDelta.x()).arg(angleDelta.y());
}

QString keyDebugText(const QKeyEvent* event) {
    if (!event) {
        return QStringLiteral("unknown");
    }
    return QStringLiteral("key=%1").arg(event->key());
}

QString sliderActionText(int action) {
    switch (static_cast<QAbstractSlider::SliderAction>(action)) {
    case QAbstractSlider::SliderNoAction:
        return QStringLiteral("SliderNoAction");
    case QAbstractSlider::SliderSingleStepAdd:
        return QStringLiteral("SliderSingleStepAdd");
    case QAbstractSlider::SliderSingleStepSub:
        return QStringLiteral("SliderSingleStepSub");
    case QAbstractSlider::SliderPageStepAdd:
        return QStringLiteral("SliderPageStepAdd");
    case QAbstractSlider::SliderPageStepSub:
        return QStringLiteral("SliderPageStepSub");
    case QAbstractSlider::SliderToMinimum:
        return QStringLiteral("SliderToMinimum");
    case QAbstractSlider::SliderToMaximum:
        return QStringLiteral("SliderToMaximum");
    case QAbstractSlider::SliderMove:
        return QStringLiteral("SliderMove");
    default:
        return QStringLiteral("UnknownAction");
    }
}

QString dropActionText(Qt::DropAction action) {
    switch (action) {
    case Qt::CopyAction:
        return QStringLiteral("CopyAction");
    case Qt::MoveAction:
        return QStringLiteral("MoveAction");
    case Qt::LinkAction:
        return QStringLiteral("LinkAction");
    case Qt::IgnoreAction:
        return QStringLiteral("IgnoreAction");
    case Qt::TargetMoveAction:
        return QStringLiteral("TargetMoveAction");
    default:
        return QStringLiteral("UnknownAction(%1)").arg(static_cast<int>(action));
    }
}

QString dropActionsText(Qt::DropActions actions) {
    if (actions == Qt::IgnoreAction) {
        return QStringLiteral("IgnoreAction");
    }

    QStringList parts;
    if (actions.testFlag(Qt::CopyAction)) {
        parts << QStringLiteral("CopyAction");
    }
    if (actions.testFlag(Qt::MoveAction)) {
        parts << QStringLiteral("MoveAction");
    }
    if (actions.testFlag(Qt::LinkAction)) {
        parts << QStringLiteral("LinkAction");
    }
    if (actions.testFlag(Qt::TargetMoveAction)) {
        parts << QStringLiteral("TargetMoveAction");
    }
    return parts.isEmpty()
        ? QStringLiteral("None(%1)").arg(static_cast<int>(actions))
        : parts.join(QLatin1Char('|'));
}

QString cursorShapeText(Qt::CursorShape shape) {
    switch (shape) {
    case Qt::ArrowCursor:
        return QStringLiteral("ArrowCursor");
    case Qt::DragMoveCursor:
        return QStringLiteral("DragMoveCursor");
    case Qt::DragCopyCursor:
        return QStringLiteral("DragCopyCursor");
    case Qt::DragLinkCursor:
        return QStringLiteral("DragLinkCursor");
    case Qt::ForbiddenCursor:
        return QStringLiteral("ForbiddenCursor");
    default:
        return QStringLiteral("Cursor(%1)").arg(static_cast<int>(shape));
    }
}

QPixmap makeDragCursorPixmap(Qt::DropAction action) {
    constexpr int kSize = 28;
    QPixmap pixmap(kSize, kSize);
    pixmap.fill(Qt::transparent);

    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing, true);

    const QPolygon arrow({
        QPoint(1, 1),
        QPoint(1, 18),
        QPoint(5, 14),
        QPoint(7, 24),
        QPoint(11, 22),
        QPoint(9, 13),
        QPoint(16, 13)
    });
    painter.setPen(QPen(Qt::black, 1));
    painter.setBrush(Qt::white);
    painter.drawPolygon(arrow);

    const QRect badgeRect(11, 11, 14, 14);
    QColor badgeColor(0, 170, 0);
    if (action == Qt::CopyAction) {
        badgeColor = QColor(0, 120, 215);
    } else if (action == Qt::IgnoreAction) {
        badgeColor = QColor(200, 50, 50);
    }

    painter.setPen(QPen(Qt::black, 1));
    painter.setBrush(badgeColor);
    painter.drawEllipse(badgeRect);

    painter.setPen(QPen(Qt::white, 2, Qt::SolidLine, Qt::RoundCap));
    const QPoint center = badgeRect.center();
    if (action == Qt::CopyAction) {
        painter.drawLine(center.x() - 3, center.y(), center.x() + 3, center.y());
        painter.drawLine(center.x(), center.y() - 3, center.x(), center.y() + 3);
    } else if (action == Qt::IgnoreAction) {
        painter.drawLine(center.x() - 3, center.y() - 3, center.x() + 3, center.y() + 3);
        painter.drawLine(center.x() - 3, center.y() + 3, center.x() + 3, center.y() - 3);
    } else {
        painter.drawLine(center.x() - 4, center.y(), center.x() + 2, center.y());
        painter.drawLine(center.x() + 2, center.y(), center.x(), center.y() - 2);
        painter.drawLine(center.x() + 2, center.y(), center.x(), center.y() + 2);
    }

    return pixmap;
}

// 剪去原版 TTBL 存储的展示标题中的序号前缀和时长后缀。
// 例如 "1. 艺术家 - 曲目 [03:45]" → "艺术家 - 曲目"
static QString cleanTtblTitle(const QString& raw) {
    static const QRegularExpression reNum(QStringLiteral(R"(^\d+\.\s*)"));
    static const QRegularExpression reDur(QStringLiteral(R"(\s*\[\d+:\d+(?::\d+)?\]\s*$)"));
    QString s = raw;
    s.remove(reNum);
    s.remove(reDur);
    return s;
}

bool useFastFileDialogMode() {
    return qEnvironmentVariableIntValue("TTPLAYER_FAST_FILE_DIALOG") == 1;
}

QStringList importAudioNameFilters() {
    return {
        QStringLiteral("*.mp3"),
        QStringLiteral("*.flac"),
        QStringLiteral("*.ogg"),
        QStringLiteral("*.wav"),
        QStringLiteral("*.aac"),
        QStringLiteral("*.m4a"),
        QStringLiteral("*.wma"),
        QStringLiteral("*.ape")
    };
}

bool isImportableAudioFile(const QString& path) {
    const QString suffix = QFileInfo(path).suffix().toLower();
    return suffix == QStringLiteral("mp3")
        || suffix == QStringLiteral("flac")
        || suffix == QStringLiteral("ogg")
        || suffix == QStringLiteral("wav")
        || suffix == QStringLiteral("aac")
        || suffix == QStringLiteral("m4a")
        || suffix == QStringLiteral("wma")
        || suffix == QStringLiteral("ape");
}

constexpr char kPlaylistItemMimeType[] = "application/x-ttplayer-playlist-items";
constexpr char kTextUriListMimeType[] = "text/uri-list";
constexpr bool kEnableCustomPlaylistDragOnXcb = true;

Qt::ItemFlags playlistEntryItemFlags(Qt::ItemFlags flags) {
    return flags | Qt::ItemIsDragEnabled | Qt::ItemIsDropEnabled;
}

Qt::ItemFlags playlistTabItemFlags(Qt::ItemFlags flags) {
    return flags | Qt::ItemIsDropEnabled;
}

QList<int> normalizedSourceIndices(QList<int> sourceIndices) {
    std::sort(sourceIndices.begin(), sourceIndices.end());
    sourceIndices.erase(std::unique(sourceIndices.begin(), sourceIndices.end()), sourceIndices.end());
    return sourceIndices;
}

QByteArray encodePlaylistItemMimeData(int sourceTab, const QList<int>& sourceIndices) {
    QByteArray data;
    QDataStream stream(&data, QIODevice::WriteOnly);
    stream << qint32(sourceTab) << qint32(sourceIndices.size());
    for (int index : sourceIndices) {
        stream << qint32(index);
    }
    return data;
}

class PlaylistDragMimeData : public QMimeData {
public:
    PlaylistDragMimeData(int sourceTab, QList<int> sourceIndices, QStringList filePaths)
        : sourceTab_(sourceTab)
        , sourceIndices_(normalizedSourceIndices(std::move(sourceIndices)))
        , filePaths_(std::move(filePaths))
    {
    }

    int sourceTab() const { return sourceTab_; }
    const QList<int>& sourceIndices() const { return sourceIndices_; }

    QStringList formats() const override {
        return {QLatin1String(kPlaylistItemMimeType), QLatin1String(kTextUriListMimeType)};
    }

    bool hasFormat(const QString& mimeType) const override {
        return mimeType == QLatin1String(kPlaylistItemMimeType) ||
               mimeType == QLatin1String(kTextUriListMimeType) ||
               QMimeData::hasFormat(mimeType);
    }

protected:
    QVariant retrieveData(const QString& mimeType, QMetaType type) const override {
        if (mimeType == QLatin1String(kPlaylistItemMimeType)) {
            if (encodedPlaylistData_.isEmpty()) {
                encodedPlaylistData_ = encodePlaylistItemMimeData(sourceTab_, sourceIndices_);
            }
            return encodedPlaylistData_;
        }

        if (mimeType == QLatin1String(kTextUriListMimeType)) {
            if (type == QMetaType::fromType<QByteArray>()) {
                if (!encodedUrlsReady_) {
                    const QList<QUrl>& urls = cachedUrls();
                    for (const QUrl& url : urls) {
                        encodedUrls_ += url.toEncoded();
                        encodedUrls_ += "\r\n";
                    }
                    encodedUrlsReady_ = true;
                }
                return encodedUrls_;
            }
            return QVariant::fromValue(cachedUrls());
        }

        return QMimeData::retrieveData(mimeType, type);
    }

private:
    const QList<QUrl>& cachedUrls() const {
        if (!urlsReady_) {
            urls_.reserve(filePaths_.size());
            for (const QString& filePath : filePaths_) {
                if (!filePath.isEmpty()) {
                    urls_.append(QUrl::fromLocalFile(filePath));
                }
            }
            urlsReady_ = true;
        }
        return urls_;
    }

    int sourceTab_ = -1;
    QList<int> sourceIndices_;
    QStringList filePaths_;
    mutable QByteArray encodedPlaylistData_;
    mutable QList<QUrl> urls_;
    mutable QByteArray encodedUrls_;
    mutable bool urlsReady_ = false;
    mutable bool encodedUrlsReady_ = false;
};

bool decodePlaylistItemMimeData(const QMimeData* mimeData, int* sourceTab, QList<int>* sourceIndices) {
    if (!mimeData || !mimeData->hasFormat(QLatin1String(kPlaylistItemMimeType))) {
        return false;
    }

    if (const auto* playlistMimeData = dynamic_cast<const PlaylistDragMimeData*>(mimeData)) {
        if (sourceTab) {
            *sourceTab = playlistMimeData->sourceTab();
        }
        if (sourceIndices) {
            *sourceIndices = playlistMimeData->sourceIndices();
        }
        return true;
    }

    const QByteArray rawData = mimeData->data(QLatin1String(kPlaylistItemMimeType));
    QDataStream stream(rawData);
    qint32 decodedTab = -1;
    qint32 count = 0;
    stream >> decodedTab >> count;
    if (stream.status() != QDataStream::Ok || count < 0) {
        return false;
    }

    QList<int> decodedRows;
    decodedRows.reserve(count);
    for (qint32 i = 0; i < count; ++i) {
        qint32 row = -1;
        stream >> row;
        if (stream.status() != QDataStream::Ok || row < 0) {
            return false;
        }
        decodedRows.append(row);
    }

    if (sourceTab) {
        *sourceTab = decodedTab;
    }
    if (sourceIndices) {
        *sourceIndices = normalizedSourceIndices(decodedRows);
    }
    return true;
}

QRect alignedRect(const QRect& baseRect, const QSize& baseSize, const QSize& currentSize,
                  const QString& align, const QSize& contentSize = {}) {
    const QSize finalSize = contentSize.isValid() ? contentSize : baseRect.size();
    QRect rect(baseRect.topLeft(), finalSize);
    const QString lowerAlign = align.toLower();

    if (lowerAlign.contains("center")) {
        rect.moveLeft((currentSize.width() - rect.width()) / 2);
    } else if (lowerAlign.contains("right")) {
        const int rightMargin = baseSize.width() - (baseRect.x() + baseRect.width());
        rect.moveLeft(currentSize.width() - rightMargin - rect.width());
    }

    if (lowerAlign.contains("bottom")) {
        const int bottomMargin = baseSize.height() - (baseRect.y() + baseRect.height());
        rect.moveTop(currentSize.height() - bottomMargin - rect.height());
    }

    return rect;
}

QString formatDurationText(int64_t durationMs) {
    const int totalSeconds = static_cast<int>(qMax<int64_t>(0, durationMs) / 1000);
    const int hours = totalSeconds / 3600;
    const int minutes = (totalSeconds / 60) % 60;
    const int seconds = totalSeconds % 60;

    if (hours > 0) {
        return QStringLiteral("%1:%2:%3")
            .arg(hours)
            .arg(minutes, 2, 10, QChar('0'))
            .arg(seconds, 2, 10, QChar('0'));
    }

    return QStringLiteral("%1:%2")
        .arg(minutes, 2, 10, QChar('0'))
        .arg(seconds, 2, 10, QChar('0'));
}

QString displayTitleForEntry(const PlaylistEntry& entry) {
    QString title = entry.title.isEmpty()
        ? QFileInfo(entry.filePath).completeBaseName()
        : entry.title;
    if (!entry.artist.isEmpty()) {
        title = entry.artist + QStringLiteral(" - ") + title;
    }
    return title;
}

QString displayDurationForEntry(const PlaylistEntry& entry) {
    return entry.durationMs > 0 ? formatDurationText(entry.durationMs) : QString{};
}

QColor blendColor(const QColor& front, const QColor& back, int frontWeight, int totalWeight) {
    const int backWeight = qMax(0, totalWeight - frontWeight);
    return QColor(
        (front.red() * frontWeight + back.red() * backWeight) / totalWeight,
        (front.green() * frontWeight + back.green() * backWeight) / totalWeight,
        (front.blue() * frontWeight + back.blue() * backWeight) / totalWeight
    );
}

void drawSplitterBar(QPainter& painter, const QRect& rect,
                     const QColor& front, const QColor& back) {
    if (rect.width() <= 0 || rect.height() <= 0) {
        return;
    }

    painter.fillRect(rect.left(), rect.top(), rect.width(), 1, front);
    if (rect.height() > 1) {
        painter.fillRect(rect.left(), rect.bottom(), rect.width(), 1, front);
    }

    if (rect.height() <= 2) {
        return;
    }

    painter.fillRect(rect.left(), rect.top() + 1, 1, rect.height() - 2, front);
    if (rect.width() > 1) {
        painter.fillRect(rect.right(), rect.top() + 1, 1, rect.height() - 2, front);
    }

    for (int x = 1; x < rect.width() - 1; ++x) {
        const QColor mix = blendColor(front, back, rect.width() - x, rect.width());
        painter.fillRect(rect.left() + x, rect.top() + 1, 1, rect.height() - 2, mix);
    }
}

void drawSplitterArrow(QPainter& painter, const QRect& rect,
                       const QColor& color, bool collapsed) {
    if (rect.width() < 5 || rect.height() < 5) {
        return;
    }

    const int cy = rect.center().y();
    const int baseX = rect.left();
    painter.setPen(color);

    static const QPoint kExpandedArrow[] = {
        QPoint(3, -2), QPoint(4, -2),
        QPoint(2, -1), QPoint(3, -1), QPoint(4, -1),
        QPoint(1,  0), QPoint(2,  0), QPoint(3,  0), QPoint(4,  0),
        QPoint(2,  1), QPoint(3,  1), QPoint(4,  1),
        QPoint(3,  2), QPoint(4,  2),
    };
    static const QPoint kCollapsedArrow[] = {
        QPoint(0, -2), QPoint(1, -2),
        QPoint(0, -1), QPoint(1, -1), QPoint(2, -1),
        QPoint(0,  0), QPoint(1,  0), QPoint(2,  0), QPoint(3,  0),
        QPoint(0,  1), QPoint(1,  1), QPoint(2,  1),
        QPoint(0,  2), QPoint(1,  2),
    };
    constexpr int kExpandedArrowCount = sizeof(kExpandedArrow) / sizeof(kExpandedArrow[0]);
    constexpr int kCollapsedArrowCount = sizeof(kCollapsedArrow) / sizeof(kCollapsedArrow[0]);

    const auto& pixels = collapsed ? kCollapsedArrow : kExpandedArrow;
    const int pixelCount = collapsed ? kCollapsedArrowCount : kExpandedArrowCount;
    for (int i = 0; i < pixelCount; ++i) {
        const QPoint pt = pixels[i];
        painter.drawPoint(baseX + pt.x(), cy + pt.y());
    }
}

QVector<QRect> opaqueRuns(const QPixmap& pixmap, Qt::Orientation orientation) {
    QVector<QRect> runs;
    if (pixmap.isNull()) {
        return runs;
    }

    const QImage image = pixmap.toImage().convertToFormat(QImage::Format_ARGB32);
    const int primaryLength = orientation == Qt::Horizontal ? image.width() : image.height();
    const int secondaryLength = orientation == Qt::Horizontal ? image.height() : image.width();
    int runStart = -1;

    for (int primary = 0; primary < primaryLength; ++primary) {
        bool hasOpaquePixel = false;
        for (int secondary = 0; secondary < secondaryLength; ++secondary) {
            const int x = orientation == Qt::Horizontal ? primary : secondary;
            const int y = orientation == Qt::Horizontal ? secondary : primary;
            if (qAlpha(image.pixel(x, y)) > 0) {
                hasOpaquePixel = true;
                break;
            }
        }

        if (hasOpaquePixel) {
            if (runStart < 0) {
                runStart = primary;
            }
            continue;
        }

        if (runStart >= 0) {
            if (orientation == Qt::Horizontal) {
                runs.append(QRect(runStart, 0, primary - runStart, image.height()));
            } else {
                runs.append(QRect(0, runStart, image.width(), primary - runStart));
            }
            runStart = -1;
        }
    }

    if (runStart >= 0) {
        if (orientation == Qt::Horizontal) {
            runs.append(QRect(runStart, 0, primaryLength - runStart, image.height()));
        } else {
            runs.append(QRect(0, runStart, image.width(), primaryLength - runStart));
        }
    }

    return runs;
}

bool splitByOpaqueRuns(const QPixmap& pixmap, Qt::Orientation orientation,
                       int expectedParts, QPixmap* out) {
    if (pixmap.isNull() || expectedParts <= 0) {
        return false;
    }

    const QVector<QRect> runs = opaqueRuns(pixmap, orientation);
    if (runs.size() != expectedParts) {
        return false;
    }

    for (int i = 0; i < expectedParts; ++i) {
        if (runs[i].width() <= 0 || runs[i].height() <= 0) {
            return false;
        }
        out[i] = pixmap.copy(runs[i]);
    }
    return true;
}

bool splitByFixedPartCount(const QPixmap& pixmap, Qt::Orientation orientation,
                           int expectedParts, QPixmap* out, bool* forcedPartition = nullptr) {
    if (forcedPartition) {
        *forcedPartition = false;
    }
    if (pixmap.isNull() || expectedParts <= 0) {
        return false;
    }

    if (splitByOpaqueRuns(pixmap, orientation, expectedParts, out)) {
        return true;
    }

    const int totalLength = orientation == Qt::Horizontal ? pixmap.width() : pixmap.height();
    if (totalLength < expectedParts) {
        return false;
    }

    int start = 0;
    for (int i = 0; i < expectedParts; ++i) {
        const int end = ((i + 1) * totalLength) / expectedParts;
        const int partLength = end - start;
        if (partLength <= 0) {
            return false;
        }

        const QRect partRect = orientation == Qt::Horizontal
            ? QRect(start, 0, partLength, pixmap.height())
            : QRect(0, start, pixmap.width(), partLength);
        out[i] = pixmap.copy(partRect);
        start = end;
    }

    if (forcedPartition) {
        *forcedPartition = (totalLength % expectedParts) != 0;
    }
    return true;
}

bool splitScrollBarButtonSheet(const QPixmap& pixmap, QPixmap out[2][3]) {
    for (int row = 0; row < 2; ++row) {
        for (int state = 0; state < 3; ++state) {
            out[row][state] = {};
        }
    }

    if (pixmap.isNull()) {
        return false;
    }

    QPixmap rowSheets[2];
    bool forcedRowSplit = false;
    if (!splitByFixedPartCount(pixmap, Qt::Vertical, 2, rowSheets, &forcedRowSplit)) {
        return false;
    }

    bool forcedPartition = forcedRowSplit;
    for (int row = 0; row < 2; ++row) {
        bool forcedColumnSplit = false;
        if (!splitByFixedPartCount(rowSheets[row], Qt::Horizontal, 3,
                                   out[row], &forcedColumnSplit)) {
            return false;
        }
        forcedPartition = forcedPartition || forcedColumnSplit;
    }

    if (forcedPartition) {
        qWarning() << "SkinScrollBarWidget: forced count-based split for buttons_image"
                   << "sheet=" << pixmap.size();
    }
    return true;
}

void drawHTiled(QPainter& painter, const QPixmap& tile, const QRect& rect) {
    if (tile.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    for (int x = rect.left(); x <= rect.right(); x += tile.width()) {
        const int drawW = qMin(tile.width(), rect.right() - x + 1);
        painter.drawPixmap(QRect(x, rect.top(), drawW, rect.height()), tile,
                           QRect(0, 0, drawW, tile.height()));
    }
}

void drawVTiled(QPainter& painter, const QPixmap& tile, const QRect& rect) {
    if (tile.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    for (int y = rect.top(); y <= rect.bottom(); y += tile.height()) {
        const int drawH = qMin(tile.height(), rect.bottom() - y + 1);
        painter.drawPixmap(QRect(rect.left(), y, rect.width(), drawH), tile,
                           QRect(0, 0, tile.width(), drawH));
    }
}

void drawTiled(QPainter& painter, const QPixmap& tile, const QRect& rect) {
    if (tile.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    for (int y = rect.top(); y <= rect.bottom(); y += tile.height()) {
        const int drawH = qMin(tile.height(), rect.bottom() - y + 1);
        for (int x = rect.left(); x <= rect.right(); x += tile.width()) {
            const int drawW = qMin(tile.width(), rect.right() - x + 1);
            painter.drawPixmap(QRect(x, y, drawW, drawH), tile,
                               QRect(0, 0, drawW, drawH));
        }
    }
}

void drawHorizontalSlice(QPainter& painter, const QPixmap& slice, const QRect& rect, bool tiled) {
    if (slice.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    if (tiled) {
        drawHTiled(painter, slice, rect);
    } else {
        painter.drawPixmap(rect, slice);
    }
}

void drawVerticalSlice(QPainter& painter, const QPixmap& slice, const QRect& rect, bool tiled) {
    if (slice.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    if (tiled) {
        drawVTiled(painter, slice, rect);
    } else {
        painter.drawPixmap(rect, slice);
    }
}

void drawCenterSlice(QPainter& painter, const QPixmap& slice, const QRect& rect, bool tiled) {
    if (slice.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }
    if (tiled) {
        drawTiled(painter, slice, rect);
    } else {
        painter.drawPixmap(rect, slice);
    }
}

void drawVerticalThreeSlice(QPainter& painter, const QPixmap& pixmap, const QRect& rect,
                            int resizeCenter, bool tileCenter) {
    if (pixmap.isNull() || rect.width() <= 0 || rect.height() <= 0) {
        return;
    }

    if (resizeCenter <= 0 || pixmap.height() <= resizeCenter || rect.height() <= pixmap.height()) {
        painter.drawPixmap(rect, pixmap);
        return;
    }

    const int fixedTop = (pixmap.height() - resizeCenter) / 2;
    const int fixedBottom = pixmap.height() - fixedTop - resizeCenter;
    const QPixmap top = pixmap.copy(0, 0, pixmap.width(), fixedTop);
    const QPixmap center = pixmap.copy(0, fixedTop, pixmap.width(), resizeCenter);
    const QPixmap bottom = pixmap.copy(0, pixmap.height() - fixedBottom, pixmap.width(), fixedBottom);

    const QRect topRect(rect.left(), rect.top(), rect.width(), fixedTop);
    const QRect centerRect(rect.left(), rect.top() + fixedTop, rect.width(),
                           qMax(0, rect.height() - fixedTop - fixedBottom));
    const QRect bottomRect(rect.left(), rect.bottom() - fixedBottom + 1, rect.width(), fixedBottom);

    if (!top.isNull() && topRect.height() > 0) {
        painter.drawPixmap(topRect, top);
    }
    if (!bottom.isNull() && bottomRect.height() > 0) {
        painter.drawPixmap(bottomRect, bottom);
    }
    if (!center.isNull() && centerRect.height() > 0) {
        if (tileCenter) {
            drawVTiled(painter, center, centerRect);
        } else {
            painter.drawPixmap(centerRect, center);
        }
    }
}

class SkinScrollBarWidget : public QWidget {
public:
    explicit SkinScrollBarWidget(QWidget* parent = nullptr)
        : QWidget(parent) {
        setMouseTracking(true);
    }

    void setSkinElement(const SkinElement& element) {
        element_ = element;
        hoveredTop_ = false;
        hoveredBottom_ = false;
        hoveredThumb_ = false;
        dragging_ = false;
        pressedButton_ = -1;
        for (auto& row : buttonPixmaps_) {
            for (auto& state : row) {
                state = {};
            }
        }

        if (!element.buttonsPixmap.isNull() &&
            !splitScrollBarButtonSheet(element.buttonsPixmap, buttonPixmaps_)) {
            qWarning() << "SkinScrollBarWidget: failed to split buttons_image"
                       << "sheet=" << element.buttonsPixmap.size();
        }
        update();
    }

    void setValueCallback(std::function<void(int)> callback) {
        valueChanged_ = std::move(callback);
    }

    void setRange(int minimum, int maximum) {
        minimum_ = minimum;
        maximum_ = qMax(minimum, maximum);
        value_ = qBound(minimum_, value_, maximum_);
        update();
    }

    void setPageStep(int step) {
        pageStep_ = qMax(1, step);
        update();
    }

    void setValue(int value) {
        const int bounded = qBound(minimum_, value, maximum_);
        if (bounded == value_) {
            return;
        }
        value_ = bounded;
        update();
    }

    int widthHint() const {
        return std::max({buttonWidth(0), buttonWidth(1), element_.barPixmap.width(),
                         thumbBasePixmap().width(), 8});
    }

protected:
    void paintEvent(QPaintEvent*) override {
        QPainter painter(this);
        const QRect topRect = topButtonRect();
        const QRect bottomRect = bottomButtonRect();
        const QRect track = trackRect();

        const QPixmap topButton = buttonPixmap(0, hoveredTop_, pressedButton_ == 0);
        if (!topButton.isNull()) {
            painter.drawPixmap(topRect, topButton);
        }
        const QPixmap bottomButton = buttonPixmap(1, hoveredBottom_, pressedButton_ == 1);
        if (!bottomButton.isNull()) {
            painter.drawPixmap(bottomRect, bottomButton);
        }
        if (!element_.barPixmap.isNull() && !track.isEmpty()) {
            const QRect barRect((width() - element_.barPixmap.width()) / 2, track.top(),
                                element_.barPixmap.width(), track.height());
            drawVTiled(painter, element_.barPixmap, barRect);
        }

        const QRect thumb = thumbRect();
        const QPixmap thumbPixmap = dragging_ ? thumbPixmapForState(2)
                                              : thumbPixmapForState(hoveredThumb_ ? 1 : 0);
        if (!thumbPixmap.isNull() && !thumb.isEmpty()) {
            drawVerticalThreeSlice(painter, thumbPixmap, thumb,
                                   element_.thumbResizeCenter, element_.thumbResizeTile);
        }
    }

    void mousePressEvent(QMouseEvent* event) override {
        if (event->button() != Qt::LeftButton) {
            return;
        }

        const QPoint pos = event->position().toPoint();
        const QRect topRect = topButtonRect();
        const QRect bottomRect = bottomButtonRect();
        const QRect thumb = thumbRect();
        if (topRect.contains(pos)) {
            pressedButton_ = 0;
            stepBy(-1);
            update();
            return;
        }
        if (bottomRect.contains(pos)) {
            pressedButton_ = 1;
            stepBy(1);
            update();
            return;
        }
        if (thumb.contains(pos)) {
            dragging_ = true;
            hoveredThumb_ = true;
            dragOffset_ = pos.y() - thumb.top();
            update();
            return;
        }

        const int pageDelta = pos.y() < thumb.top() ? -pageStep_ : pageStep_;
        stepBy(pageDelta);
    }

    void mouseMoveEvent(QMouseEvent* event) override {
        const QPoint pos = event->position().toPoint();
        const bool newHoverTop = topButtonRect().contains(pos);
        const bool newHoverBottom = bottomButtonRect().contains(pos);
        const bool newHoverThumb = thumbRect().contains(pos);
        if (newHoverTop != hoveredTop_ || newHoverBottom != hoveredBottom_ || newHoverThumb != hoveredThumb_) {
            hoveredTop_ = newHoverTop;
            hoveredBottom_ = newHoverBottom;
            hoveredThumb_ = newHoverThumb;
            update();
        }

        if (!dragging_) {
            return;
        }
        const QRect track = trackRect();
        const QRect thumb = thumbRect();
        const int available = qMax(1, track.height() - thumb.height());
        const int y = qBound(track.top(), event->position().toPoint().y() - dragOffset_,
                             track.bottom() - thumb.height() + 1);
        const double ratio = static_cast<double>(y - track.top()) / available;
        const int mapped = minimum_ + static_cast<int>(ratio * (maximum_ - minimum_));
        setAndEmitValue(mapped);
    }

    void mouseReleaseEvent(QMouseEvent* event) override {
        if (event->button() == Qt::LeftButton) {
            dragging_ = false;
            pressedButton_ = -1;
            hoveredTop_ = topButtonRect().contains(event->position().toPoint());
            hoveredBottom_ = bottomButtonRect().contains(event->position().toPoint());
            hoveredThumb_ = thumbRect().contains(event->position().toPoint());
            update();
        }
    }

    void leaveEvent(QEvent*) override {
        if (hoveredTop_ || hoveredBottom_ || hoveredThumb_) {
            hoveredTop_ = false;
            hoveredBottom_ = false;
            hoveredThumb_ = false;
            update();
        }
    }

private:
    QRect topButtonRect() const {
        const int w = buttonWidth(0);
        const int h = buttonHeight(0);
        return QRect((width() - w) / 2, 0, w, h);
    }

    QRect bottomButtonRect() const {
        const int w = buttonWidth(1);
        const int h = buttonHeight(1);
        return QRect((width() - w) / 2, height() - h, w, h);
    }

    QRect trackRect() const {
        const int top = buttonHeight(0);
        const int bottom = buttonHeight(1);
        return QRect(0, top, width(), qMax(0, height() - top - bottom));
    }

    int thumbHeight() const {
        const QRect track = trackRect();
        const QPixmap thumbPixmap = thumbBasePixmap();
        const int baseHeight = thumbPixmap.isNull() ? 12 : thumbPixmap.height();
        if (maximum_ <= minimum_) {
            return qMin(track.height(), baseHeight);
        }
        const int proportional = qMax(baseHeight, track.height() * pageStep_ / (maximum_ + pageStep_ + 1));
        return qMin(track.height(), proportional);
    }

    QRect thumbRect() const {
        const QRect track = trackRect();
        if (track.isEmpty()) {
            return {};
        }
        const int height = thumbHeight();
        const int available = qMax(0, track.height() - height);
        int y = track.top();
        if (maximum_ > minimum_ && available > 0) {
            const double ratio = static_cast<double>(value_ - minimum_) / (maximum_ - minimum_);
            y += static_cast<int>(ratio * available);
        }
        const QPixmap thumbPixmap = thumbBasePixmap();
        const int thumbWidth = thumbPixmap.isNull() ? width() : thumbPixmap.width();
        return QRect((width() - thumbWidth) / 2, y, thumbWidth, height);
    }

    void stepBy(int delta) {
        setAndEmitValue(value_ + delta);
    }

    void setAndEmitValue(int value) {
        const int bounded = qBound(minimum_, value, maximum_);
        if (bounded == value_) {
            return;
        }
        value_ = bounded;
        update();
        if (valueChanged_) {
            valueChanged_(value_);
        }
    }

    int buttonWidth(int row) const {
        return buttonPixmaps_[row][0].isNull() ? 0 : buttonPixmaps_[row][0].width();
    }

    int buttonHeight(int row) const {
        return buttonPixmaps_[row][0].isNull() ? 0 : buttonPixmaps_[row][0].height();
    }

    QPixmap buttonPixmap(int row, bool hovered, bool pressed) const {
        const int state = pressed ? 2 : (hovered ? 1 : 0);
        return buttonPixmaps_[row][state];
    }

    QPixmap thumbBasePixmap() const {
        return thumbPixmapForState(0);
    }

    QPixmap thumbPixmapForState(int state) const {
        if (!element_.thumbPixmaps[state].isNull()) {
            return element_.thumbPixmaps[state];
        }
        for (const auto& pixmap : element_.thumbPixmaps) {
            if (!pixmap.isNull()) {
                return pixmap;
            }
        }
        return {};
    }

    SkinElement element_;
    QPixmap buttonPixmaps_[2][3];
    int minimum_ = 0;
    int maximum_ = 0;
    int pageStep_ = 1;
    int value_ = 0;
    bool dragging_ = false;
    int dragOffset_ = 0;
    bool hoveredTop_ = false;
    bool hoveredBottom_ = false;
    bool hoveredThumb_ = false;
    int pressedButton_ = -1;
    std::function<void(int)> valueChanged_;
};

// --- 抑制 QListWidget 自动滚动（仅在显式启用时允许 scrollTo）---
class StableScrollListWidget : public QListWidget {
public:
    using QListWidget::QListWidget;
    void scrollTo(const QModelIndex& index, ScrollHint hint = EnsureVisible) override {
        if (suppressAutoScroll_) return;
        QListWidget::scrollTo(index, hint);
    }
    void setAutoScrollEnabled(bool on) { suppressAutoScroll_ = !on; }
private:
    bool suppressAutoScroll_ = true;
};

class PlaylistDragListWidget : public StableScrollListWidget {
public:
    using StableScrollListWidget::StableScrollListWidget;

    void setStartDragHandler(std::function<void(Qt::DropActions)> handler) {
        startDragHandler_ = std::move(handler);
    }

    void setDragEnterHandler(std::function<void(QDragEnterEvent*)> handler) {
        dragEnterHandler_ = std::move(handler);
    }

    void setDragMoveHandler(std::function<void(QDragMoveEvent*)> handler) {
        dragMoveHandler_ = std::move(handler);
    }

    void setDropHandler(std::function<void(QDropEvent*)> handler) {
        dropHandler_ = std::move(handler);
    }

    void setActiveTabProvider(std::function<int()> provider) {
        activeTabProvider_ = std::move(provider);
    }

    void setInsertionIndicatorY(int y) {
        const int bounded = qMax(-1, y);
        if (dropIndicatorY_ == bounded) {
            return;
        }
        dropIndicatorY_ = bounded;
        viewport()->update();
    }

protected:
    QStringList mimeTypes() const override;
    QMimeData* mimeData(const QList<QListWidgetItem*>& items) const override;
    Qt::DropActions supportedDropActions() const override;

    void paintEvent(QPaintEvent* event) override {
        StableScrollListWidget::paintEvent(event);
        if (dropIndicatorY_ < 0) {
            return;
        }

        QPainter painter(viewport());
        painter.setRenderHint(QPainter::Antialiasing, false);
        const QColor lineColor(255, 255, 255);
        painter.setPen(QPen(lineColor, 2));
        const int y = qBound(0, dropIndicatorY_, viewport()->height() - 1);
        painter.drawLine(4, y, qMax(4, viewport()->width() - 5), y);
    }

    void startDrag(Qt::DropActions supportedActions) override {
        if (startDragHandler_) {
            startDragHandler_(supportedActions);
            return;
        }
        StableScrollListWidget::startDrag(supportedActions);
    }

    void dragEnterEvent(QDragEnterEvent* event) override {
        if (dragEnterHandler_) {
            dragEnterHandler_(event);
            if (event->isAccepted()) {
                return;
            }
        }
        StableScrollListWidget::dragEnterEvent(event);
    }

    void dragMoveEvent(QDragMoveEvent* event) override {
        if (dragMoveHandler_) {
            dragMoveHandler_(event);
            if (event->isAccepted()) {
                return;
            }
        }
        StableScrollListWidget::dragMoveEvent(event);
    }

    void dropEvent(QDropEvent* event) override {
        if (dropHandler_) {
            dropHandler_(event);
            if (event->isAccepted()) {
                setInsertionIndicatorY(-1);
                return;
            }
        }
        StableScrollListWidget::dropEvent(event);
    }

    void dragLeaveEvent(QDragLeaveEvent* event) override {
        setInsertionIndicatorY(-1);
        StableScrollListWidget::dragLeaveEvent(event);
    }

private:
    std::function<int()> activeTabProvider_;
    std::function<void(Qt::DropActions)> startDragHandler_;
    std::function<void(QDragEnterEvent*)> dragEnterHandler_;
    std::function<void(QDragMoveEvent*)> dragMoveHandler_;
    std::function<void(QDropEvent*)> dropHandler_;
    int dropIndicatorY_ = -1;
};

class PlaylistTabDropListWidget : public QListWidget {
public:
    using QListWidget::QListWidget;

    void setDragEnterHandler(std::function<void(QDragEnterEvent*)> handler) {
        dragEnterHandler_ = std::move(handler);
    }

    void setDragMoveHandler(std::function<void(QDragMoveEvent*)> handler) {
        dragMoveHandler_ = std::move(handler);
    }

    void setDropHandler(std::function<void(QDropEvent*)> handler) {
        dropHandler_ = std::move(handler);
    }

    void setInsertionIndicatorY(int y) {
        const int bounded = qMax(-1, y);
        if (dropIndicatorY_ == bounded) {
            return;
        }
        dropIndicatorY_ = bounded;
        viewport()->update();
    }

protected:
    QStringList mimeTypes() const override;
    Qt::DropActions supportedDropActions() const override;

    void paintEvent(QPaintEvent* event) override {
        QListWidget::paintEvent(event);
        if (dropIndicatorY_ < 0) {
            return;
        }

        QPainter painter(viewport());
        painter.setRenderHint(QPainter::Antialiasing, false);
        painter.setPen(QPen(QColor(255, 255, 255), 2));
        const int y = qBound(0, dropIndicatorY_, viewport()->height() - 1);
        painter.drawLine(3, y, qMax(3, viewport()->width() - 4), y);
    }

    void dragEnterEvent(QDragEnterEvent* event) override {
        if (dragEnterHandler_) {
            dragEnterHandler_(event);
            if (event->isAccepted()) {
                return;
            }
        }
        QListWidget::dragEnterEvent(event);
    }

    void dragMoveEvent(QDragMoveEvent* event) override {
        if (dragMoveHandler_) {
            dragMoveHandler_(event);
            if (event->isAccepted()) {
                return;
            }
        }
        QListWidget::dragMoveEvent(event);
    }

    void dropEvent(QDropEvent* event) override {
        if (dropHandler_) {
            dropHandler_(event);
            if (event->isAccepted()) {
                setInsertionIndicatorY(-1);
                return;
            }
        }
        QListWidget::dropEvent(event);
    }

    void dragLeaveEvent(QDragLeaveEvent* event) override {
        setInsertionIndicatorY(-1);
        QListWidget::dragLeaveEvent(event);
    }

private:
    std::function<void(QDragEnterEvent*)> dragEnterHandler_;
    std::function<void(QDragMoveEvent*)> dragMoveHandler_;
    std::function<void(QDropEvent*)> dropHandler_;
    int dropIndicatorY_ = -1;
};

enum PlaylistDataRole {
    SourceIndexRole = Qt::UserRole,
    NumberRole      = Qt::UserRole + 1,
    TitleRole       = Qt::UserRole + 2,
    DurationRole    = Qt::UserRole + 3,
    IsPlayingRole   = Qt::UserRole + 4,
    FilePathRole    = Qt::UserRole + 5,
};

QStringList PlaylistDragListWidget::mimeTypes() const {
    return {QLatin1String(kPlaylistItemMimeType), QLatin1String(kTextUriListMimeType)};
}

QMimeData* PlaylistDragListWidget::mimeData(const QList<QListWidgetItem*>& items) const {
    QList<int> sourceIndices;
    QStringList filePaths;
    sourceIndices.reserve(items.size());
    filePaths.reserve(items.size());

    for (QListWidgetItem* item : items) {
        if (!item) {
            continue;
        }
        const int sourceIndex = item->data(SourceIndexRole).toInt();
        if (sourceIndex < 0) {
            continue;
        }
        sourceIndices.append(sourceIndex);
        filePaths.append(item->data(FilePathRole).toString());
    }

    return new PlaylistDragMimeData(activeTabProvider_ ? activeTabProvider_() : -1,
                                    sourceIndices,
                                    filePaths);
}

Qt::DropActions PlaylistDragListWidget::supportedDropActions() const {
    return Qt::CopyAction | Qt::MoveAction;
}

QStringList PlaylistTabDropListWidget::mimeTypes() const {
    return {QLatin1String(kPlaylistItemMimeType)};
}

Qt::DropActions PlaylistTabDropListWidget::supportedDropActions() const {
    return Qt::MoveAction;
}

class PlaylistItemDelegate : public QStyledItemDelegate {
public:
    using QStyledItemDelegate::QStyledItemDelegate;

    void setColors(const QColor& text, const QColor& hilight, const QColor& bkgnd,
                   const QColor& bkgnd2, const QColor& select, const QColor& number,
                   const QColor& duration) {
        colorText_ = text;
        colorHilight_ = hilight;
        colorBkgnd_ = bkgnd;
        colorBkgnd2_ = bkgnd2;
        colorSelect_ = select;
        colorNumber_ = number;
        colorDuration_ = duration;
    }

    void setSelectedPixmap(const QPixmap& pixmap) {
        selectedPixmap_ = pixmap;
    }

    void paint(QPainter* painter, const QStyleOptionViewItem& option,
               const QModelIndex& index) const override {
        painter->save();
        painter->setFont(option.font);

        const bool selected = option.state & QStyle::State_Selected;
        const bool playing  = index.data(IsPlayingRole).toBool();

        // 背景
        QColor bg = (index.row() % 2 == 0) ? colorBkgnd_ : colorBkgnd2_;
        if (selected) {
            if (!selectedPixmap_.isNull()) {
                // 使用皮肤提供的 selected_image 位图
                painter->drawPixmap(option.rect, selectedPixmap_);
            } else {
                // 纵向渐变：从行背景到选中颜色
                QLinearGradient grad(option.rect.left(), option.rect.top(),
                                     option.rect.left(), option.rect.bottom());
                grad.setColorAt(0.0, bg);
                grad.setColorAt(1.0, colorSelect_);
                painter->fillRect(option.rect, grad);
            }
        } else {
            painter->fillRect(option.rect, bg);
        }

        const QString number   = index.data(NumberRole).toString();
        const QString title    = index.data(TitleRole).toString();
        const QString duration = index.data(DurationRole).toString();

        const QFontMetrics fm(option.font);
        const int hPad = 4;
        QRect cr = option.rect.adjusted(hPad, 1, -hPad, -1);
        int playMarkerWidth = 0;
        if (playing) {
            playMarkerWidth = qMin(6, cr.height() - 4);
            const int markerLeft = cr.left() + 2;
            const int markerTop = cr.top() + (cr.height() - playMarkerWidth) / 2;
            const QPolygon triangle = QPolygon({
                QPoint(markerLeft, markerTop),
                QPoint(markerLeft, markerTop + playMarkerWidth),
                QPoint(markerLeft + playMarkerWidth, markerTop + playMarkerWidth / 2)
            });
            painter->save();
            painter->setPen(Qt::NoPen);
            painter->setBrush((selected || playing) ? colorHilight_ : colorNumber_);
            painter->drawPolygon(triangle);
            painter->restore();
            cr.adjust(playMarkerWidth + 4, 0, 0, 0);
        }

        // 时长（右对齐）
        int durW = 0;
        if (!duration.isEmpty()) {
            durW = fm.horizontalAdvance(duration);
            QRect dr(cr.right() - durW, cr.top(), durW, cr.height());
            painter->setPen((selected || playing) ? colorHilight_ : colorDuration_);
            painter->drawText(dr, Qt::AlignRight | Qt::AlignVCenter, duration);
        }

        // 序号（左对齐）
        int numW = 0;
        if (!number.isEmpty()) {
            const QString numText = number + QChar(' ');
            numW = fm.horizontalAdvance(numText);
            QRect nr(cr.left(), cr.top(), numW, cr.height());
            painter->setPen((selected || playing) ? colorHilight_ : colorNumber_);
            painter->drawText(nr, Qt::AlignLeft | Qt::AlignVCenter, numText);
        }

        // 标题（占据中间区域）
        if (!title.isEmpty()) {
            int gap = durW > 0 ? fm.horizontalAdvance(QChar(' ')) * 2 : 0;
            QRect tr(cr.left() + numW, cr.top(),
                     qMax(1, cr.width() - numW - durW - gap), cr.height());
            painter->setPen((selected || playing) ? colorHilight_ : colorText_);
            painter->drawText(tr, Qt::AlignLeft | Qt::AlignVCenter,
                              fm.elidedText(title, Qt::ElideRight, tr.width()));
        }

        painter->restore();
    }

    QSize sizeHint(const QStyleOptionViewItem& option, const QModelIndex& index) const override {
        Q_UNUSED(index);
        return QSize(0, QFontMetrics(option.font).height() + 4);
    }

private:
    QColor colorText_{0x00, 0x80, 0xFF};
    QColor colorHilight_{0x00, 0xFF, 0x00};
    QColor colorBkgnd_{0x00, 0x00, 0x00};
    QColor colorBkgnd2_{0x20, 0x20, 0x20};
    QColor colorSelect_{0x32, 0x69, 0xC8};
    QColor colorNumber_{0x00, 0x80, 0x00};
    QColor colorDuration_{0xC0, 0x80, 0x20};
    QPixmap selectedPixmap_;
};

static constexpr int kToolbarGroupCount = 7;
static constexpr int kDividerWidth = 5;
static constexpr int kDividerMinExpandedPos = 20;
static constexpr int kDividerCollapseThreshold = 6;
static constexpr int kDividerHandleHalfHeight = 7;

} // 匿名命名空间

PlaylistWindow::PlaylistWindow(AudioEngine* engine, QWidget* parent)
    : QWidget(parent, Qt::Tool | Qt::FramelessWindowHint)
    , engine_(engine)
{
    setAcceptDrops(true);
    setAttribute(Qt::WA_TranslucentBackground);
    setMouseTracking(true);

    auto* dragListWidget = new PlaylistDragListWidget(this);
    listWidget_ = dragListWidget;
    listWidget_->setMouseTracking(true);
    listWidget_->setCursor(Qt::ArrowCursor);
    listWidget_->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    listWidget_->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    listWidget_->setUniformItemSizes(true);
    listWidget_->setSelectionMode(QAbstractItemView::ExtendedSelection);
    listWidget_->setSelectionRectVisible(true);
    listWidget_->setDragEnabled(true);
    listWidget_->setAcceptDrops(true);
    listWidget_->viewport()->setAcceptDrops(true);
    listWidget_->setDropIndicatorShown(true);
    listWidget_->setDragDropOverwriteMode(false);
    listWidget_->setDefaultDropAction(Qt::MoveAction);
    listWidget_->setDragDropMode(QAbstractItemView::InternalMove);
    listWidget_->setAutoScroll(false);
    listWidget_->setContextMenuPolicy(Qt::CustomContextMenu);
    connect(listWidget_, &QListWidget::customContextMenuRequested,
            this, &PlaylistWindow::showListContextMenu);
    dragListWidget->setStartDragHandler([this](Qt::DropActions supportedActions) {
        startPlaylistDrag(supportedActions);
    });
    dragListWidget->setActiveTabProvider([this]() {
        return activeTab_;
    });
    dragListWidget->setDragEnterHandler([this](QDragEnterEvent* event) {
        handleListDragEnter(event);
    });
    dragListWidget->setDragMoveHandler([this](QDragMoveEvent* event) {
        handleListDragMove(event);
    });
    dragListWidget->setDropHandler([this](QDropEvent* event) {
        handleListDrop(event);
    });

    playlistDelegate_ = new PlaylistItemDelegate(listWidget_);
    listWidget_->setItemDelegate(playlistDelegate_);

    connect(listWidget_, &QListWidget::itemDoubleClicked, this, [this](QListWidgetItem* item) {
        const int row = sourceIndexForItem(item);
        if (row >= 0 && row < playlist_.count()) {
            playlist_.setCurrentIndex(row);
            const QString selectedPath = playlist_.currentFile();
            lastUserSwitchRequestMs_ = QDateTime::currentMSecsSinceEpoch();
            lastUserSwitchPath_ = selectedPath;
            lastUserSwitchFromDoubleClick_ = true;
            qDebug().noquote()
                << QStringLiteral("[SwitchPerf][PlaylistWindow] itemDoubleClicked path=\"%1\" ts=%2 row=%3")
                       .arg(selectedPath)
                       .arg(lastUserSwitchRequestMs_)
                       .arg(row);
            emit fileSelected(selectedPath);
        }
    });

    // 左侧播放列表标签面板（多列表支持）
    auto* tabDropWidget = new PlaylistTabDropListWidget(this);
    playlistTabsWidget_ = tabDropWidget;
    playlistTabsWidget_->setMouseTracking(true);
    playlistTabsWidget_->setCursor(Qt::ArrowCursor);
    playlistTabsWidget_->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    playlistTabsWidget_->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    playlistTabsWidget_->setSelectionMode(QAbstractItemView::SingleSelection);
    playlistTabsWidget_->setDragEnabled(false);
    playlistTabsWidget_->setAcceptDrops(true);
    playlistTabsWidget_->viewport()->setAcceptDrops(true);
    playlistTabsWidget_->setDropIndicatorShown(true);
    playlistTabsWidget_->setDragDropMode(QAbstractItemView::DropOnly);
    playlistTabsWidget_->setAutoScroll(false);
    playlistTabsWidget_->setContextMenuPolicy(Qt::CustomContextMenu);
    tabDropWidget->setDragEnterHandler([this](QDragEnterEvent* event) {
        handleTabDragEnter(event);
    });
    tabDropWidget->setDragMoveHandler([this](QDragMoveEvent* event) {
        handleTabDragMove(event);
    });
    tabDropWidget->setDropHandler([this](QDropEvent* event) {
        handleTabDrop(event);
    });
    playlistTabsWidget_->addItem(QStringLiteral("[默认]"));
    if (auto* item = playlistTabsWidget_->item(playlistTabsWidget_->count() - 1)) {
        item->setFlags(playlistTabItemFlags(item->flags()));
    }
    playlistTabsWidget_->setCurrentRow(0);

    // 初始化多播放列表，默认创建一个标签页
    tabData_.append({QStringLiteral("[默认]"), {}, -1});
    activeTab_ = 0;

    connect(playlistTabsWidget_, &QListWidget::currentRowChanged,
            this, &PlaylistWindow::switchToTab);

    // 同步重命名后的标签文本到 tabData_
    connect(playlistTabsWidget_->model(), &QAbstractItemModel::dataChanged,
            this, [this](const QModelIndex& topLeft) {
        const int row = topLeft.row();
        if (row >= 0 && row < tabData_.size()) {
            tabData_[row].name = topLeft.data().toString();
        }
    });

    connect(playlistTabsWidget_, &QListWidget::customContextMenuRequested,
            this, [this](const QPoint& pos) {
        QMenu menu(this);
        menu.addAction(QStringLiteral("新建列表(&N)"), this, [this]() {
            const int n = playlistTabsWidget_->count();
            const QString name = QStringLiteral("新列表 %1").arg(n);
            tabData_.append({name, {}, -1});
            playlistTabsWidget_->addItem(name);
            if (auto* item = playlistTabsWidget_->item(playlistTabsWidget_->count() - 1)) {
                item->setFlags(playlistTabItemFlags(item->flags()));
            }
            playlistTabsWidget_->setCurrentRow(n);
        });
        menu.addAction(QStringLiteral("重命名(&R)"), this, [this]() {
            auto* item = playlistTabsWidget_->currentItem();
            if (item) {
                item->setFlags(item->flags() | Qt::ItemIsEditable);
                playlistTabsWidget_->editItem(item);
            }
        });
        menu.addSeparator();
        menu.addAction(QStringLiteral("删除列表(&D)"), this, [this]() {
            if (playlistTabsWidget_->count() <= 1) return;
            const int row = playlistTabsWidget_->currentRow();
            if (row < 0) return;
            // 如果删除当前激活标签页，先切换到邻近标签页
            if (row == activeTab_) {
                const int newTab = (row > 0) ? row - 1 : row + 1;
                playlistTabsWidget_->setCurrentRow(newTab);
            }
            if (row < tabData_.size()) tabData_.removeAt(row);
            delete playlistTabsWidget_->takeItem(row);
            // 删除后修正 activeTab_ 索引
            activeTab_ = playlistTabsWidget_->currentRow();
        });
        menu.exec(playlistTabsWidget_->mapToGlobal(pos));
    });

    skinScrollBar_ = new SkinScrollBarWidget(this);
    skinScrollBar_->setCursor(Qt::ArrowCursor);
    skinScrollBar_->hide();
    auto* nativeScrollBar = listWidget_->verticalScrollBar();
    listWidget_->viewport()->installEventFilter(this);
    nativeScrollBar->installEventFilter(this);
    skinScrollBar_->installEventFilter(this);
    static_cast<SkinScrollBarWidget*>(skinScrollBar_)->setValueCallback(
        [this, nativeScrollBar](int value) {
            markScrollDebugContext(false, QStringLiteral("skin_scrollbar_setValue"));
            nativeScrollBar->setValue(value);
        });
    connect(nativeScrollBar, &QScrollBar::rangeChanged, this, [this, nativeScrollBar](int min, int max) {
        auto* bar = static_cast<SkinScrollBarWidget*>(skinScrollBar_);
        bar->setRange(min, max);
        bar->setPageStep(nativeScrollBar->pageStep());
        bar->setValue(nativeScrollBar->value());
        skinScrollBar_->setVisible(max > min && !scrollbarElement_.buttonsPixmap.isNull());
        logScrollBarRangeChange("playlist", false, nativeScrollBar, min, max);
    });
    connect(nativeScrollBar, &QScrollBar::valueChanged, this, [this, nativeScrollBar](int value) {
        static_cast<SkinScrollBarWidget*>(skinScrollBar_)->setValue(value);
        logScrollBarValueChange("playlist", false, nativeScrollBar, value);
    });
    connect(nativeScrollBar, &QScrollBar::actionTriggered, this, [this](int action) {
        const QString previous = currentScrollDebugContext(false);
        markScrollDebugContext(false,
                               QStringLiteral("native_action=%1(%2) prev=%3")
                                   .arg(action)
                                   .arg(sliderActionText(action))
                                   .arg(previous));
    });
    connect(nativeScrollBar, &QScrollBar::sliderPressed, this, [this]() {
        markScrollDebugContext(false, QStringLiteral("native_sliderPressed"));
    });
    connect(nativeScrollBar, &QScrollBar::sliderReleased, this, [this]() {
        markScrollDebugContext(false, QStringLiteral("native_sliderReleased"));
    });

    tabsSkinScrollBar_ = new SkinScrollBarWidget(this);
    tabsSkinScrollBar_->setCursor(Qt::ArrowCursor);
    tabsSkinScrollBar_->hide();
    auto* tabsNativeScrollBar = playlistTabsWidget_->verticalScrollBar();
    playlistTabsWidget_->viewport()->installEventFilter(this);
    tabsNativeScrollBar->installEventFilter(this);
    tabsSkinScrollBar_->installEventFilter(this);
    static_cast<SkinScrollBarWidget*>(tabsSkinScrollBar_)->setValueCallback(
        [this, tabsNativeScrollBar](int value) {
            markScrollDebugContext(true, QStringLiteral("skin_scrollbar_setValue"));
            tabsNativeScrollBar->setValue(value);
        });
    connect(tabsNativeScrollBar, &QScrollBar::rangeChanged, this,
            [this, tabsNativeScrollBar](int min, int max) {
        auto* bar = static_cast<SkinScrollBarWidget*>(tabsSkinScrollBar_);
        const bool shouldShow = max > min && !scrollbarElement_.buttonsPixmap.isNull();
        const bool visibilityChanged = tabsSkinScrollBar_->isVisible() != shouldShow;
        bar->setRange(min, max);
        bar->setPageStep(tabsNativeScrollBar->pageStep());
        bar->setValue(tabsNativeScrollBar->value());
        tabsSkinScrollBar_->setVisible(shouldShow);
        if (visibilityChanged) {
            updateListGeometry();
        }
        logScrollBarRangeChange("tabs", true, tabsNativeScrollBar, min, max);
    });
    connect(tabsNativeScrollBar, &QScrollBar::valueChanged, this, [this, tabsNativeScrollBar](int value) {
        static_cast<SkinScrollBarWidget*>(tabsSkinScrollBar_)->setValue(value);
        logScrollBarValueChange("tabs", true, tabsNativeScrollBar, value);
    });
    connect(tabsNativeScrollBar, &QScrollBar::actionTriggered, this, [this](int action) {
        const QString previous = currentScrollDebugContext(true);
        markScrollDebugContext(true,
                               QStringLiteral("native_action=%1(%2) prev=%3")
                                   .arg(action)
                                   .arg(sliderActionText(action))
                                   .arg(previous));
    });
    connect(tabsNativeScrollBar, &QScrollBar::sliderPressed, this, [this]() {
        markScrollDebugContext(true, QStringLiteral("native_sliderPressed"));
    });
    connect(tabsNativeScrollBar, &QScrollBar::sliderReleased, this, [this]() {
        markScrollDebugContext(true, QStringLiteral("native_sliderReleased"));
    });

    playlistScrollDebug_.lastValue = nativeScrollBar->value();
    tabsScrollDebug_.lastValue = tabsNativeScrollBar->value();

    applyStyle();
}

bool PlaylistWindow::eventFilter(QObject* watched, QEvent* event) {
    const bool isPlaylistViewport = watched == listWidget_->viewport();
    const bool isPlaylistNativeBar = watched == listWidget_->verticalScrollBar();
    const bool isPlaylistSkinBar = watched == skinScrollBar_;
    const bool isTabsViewport = watched == playlistTabsWidget_->viewport();
    const bool isTabsNativeBar = watched == playlistTabsWidget_->verticalScrollBar();
    const bool isTabsSkinBar = watched == tabsSkinScrollBar_;

    const bool playlistTarget = isPlaylistViewport || isPlaylistNativeBar || isPlaylistSkinBar;
    const bool tabsTarget = isTabsViewport || isTabsNativeBar || isTabsSkinBar;
    if (playlistTarget || tabsTarget) {
        const bool tabs = tabsTarget;
        switch (event->type()) {
        case QEvent::Wheel:
            markScrollDebugContext(tabs,
                                   QStringLiteral("%1_wheel delta=%2")
                                       .arg(isPlaylistViewport || isTabsViewport ? QStringLiteral("viewport")
                                                                                : QStringLiteral("scrollbar"))
                                       .arg(wheelDeltaText(static_cast<QWheelEvent*>(event))));
            break;
        case QEvent::MouseButtonPress:
            markScrollDebugContext(tabs,
                                   isPlaylistSkinBar || isTabsSkinBar
                                       ? QStringLiteral("skin_scrollbar_mousePress")
                                       : (isPlaylistNativeBar || isTabsNativeBar
                                              ? QStringLiteral("native_scrollbar_mousePress")
                                              : QStringLiteral("viewport_mousePress")));
            break;
        case QEvent::MouseMove:
            if ((isPlaylistSkinBar || isTabsSkinBar) &&
                (static_cast<QMouseEvent*>(event)->buttons() & Qt::LeftButton)) {
                markScrollDebugContext(tabs, QStringLiteral("skin_scrollbar_drag"));
            } else if ((isPlaylistNativeBar || isTabsNativeBar) &&
                       (static_cast<QMouseEvent*>(event)->buttons() & Qt::LeftButton)) {
                markScrollDebugContext(tabs, QStringLiteral("native_scrollbar_drag"));
            }
            break;
        case QEvent::MouseButtonRelease:
            if (isPlaylistSkinBar || isTabsSkinBar) {
                markScrollDebugContext(tabs, QStringLiteral("skin_scrollbar_mouseRelease"));
            } else if (isPlaylistNativeBar || isTabsNativeBar) {
                markScrollDebugContext(tabs, QStringLiteral("native_scrollbar_mouseRelease"));
            }
            break;
        case QEvent::KeyPress:
            markScrollDebugContext(tabs,
                                   QStringLiteral("%1_%2")
                                       .arg(isPlaylistViewport || isTabsViewport ? QStringLiteral("viewport")
                                                                                : QStringLiteral("scrollbar"))
                                       .arg(keyDebugText(static_cast<QKeyEvent*>(event))));
            break;
        default:
            break;
        }
    }

    // 自定义拖拽事件处理（xcb/XWayland 平台绕过 XDnD 光标缺陷）
    // viewport 持有 grabMouse，所有鼠标事件都会到达这里。
    if (customDragActive_ && isPlaylistViewport) {
        switch (event->type()) {
        case QEvent::MouseMove: {
            const auto* me = static_cast<QMouseEvent*>(event);
            updateCustomDragIndicators(me->globalPosition().toPoint());
            return true;
        }
        case QEvent::MouseButtonRelease: {
            const auto* me = static_cast<QMouseEvent*>(event);
            if (me->button() == Qt::LeftButton) {
                finishCustomDrag(me->globalPosition().toPoint());
                return true;
            }
            break;
        }
        case QEvent::KeyPress: {
            const auto* ke = static_cast<QKeyEvent*>(event);
            if (ke->key() == Qt::Key_Escape) {
                cancelCustomDrag();
                return true;
            }
            break;
        }
        default:
            break;
        }
    }

    return QWidget::eventFilter(watched, event);
}

void PlaylistWindow::markScrollDebugContext(bool tabs, const QString& source) {
    ScrollDebugState& state = tabs ? tabsScrollDebug_ : playlistScrollDebug_;
    state.source = source;
    state.timestampMs = QDateTime::currentMSecsSinceEpoch();
}

QString PlaylistWindow::currentScrollDebugContext(bool tabs) const {
    const ScrollDebugState& state = tabs ? tabsScrollDebug_ : playlistScrollDebug_;
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (state.timestampMs > 0 && now - state.timestampMs <= 600) {
        return state.source;
    }
    return QStringLiteral("unknown_or_programmatic");
}

void PlaylistWindow::logScrollBarValueChange(const char* channel, bool tabs, QScrollBar* scrollBar, int newValue) {
    if (!scrollBar) {
        return;
    }

    ScrollDebugState& state = tabs ? tabsScrollDebug_ : playlistScrollDebug_;
    qDebug().noquote()
        << QStringLiteral("[ScrollDebug][%1] valueChanged value=%2 old=%3 min=%4 max=%5 page=%6 source=%7")
               .arg(QString::fromLatin1(channel))
               .arg(newValue)
               .arg(state.lastValue)
               .arg(scrollBar->minimum())
               .arg(scrollBar->maximum())
               .arg(scrollBar->pageStep())
               .arg(currentScrollDebugContext(tabs));
    state.lastValue = newValue;
}

void PlaylistWindow::logScrollBarRangeChange(const char* channel, bool tabs, QScrollBar* scrollBar, int minimum, int maximum) {
    if (!scrollBar) {
        return;
    }

    qDebug().noquote()
        << QStringLiteral("[ScrollDebug][%1] rangeChanged min=%2 max=%3 page=%4 value=%5 source=%6")
               .arg(QString::fromLatin1(channel))
               .arg(minimum)
               .arg(maximum)
               .arg(scrollBar->pageStep())
               .arg(scrollBar->value())
               .arg(currentScrollDebugContext(tabs));
}

void PlaylistWindow::logDragDecision(const char* target,
                                     const char* phase,
                                     const QPoint& localPos,
                                     const QPoint& globalPos,
                                     const QDropEvent* event) {
    if (!event) {
        return;
    }

    DragDebugState* state = &rootDragDebug_;
    if (qstrcmp(target, "list") == 0) {
        state = &listDragDebug_;
    } else if (qstrcmp(target, "tabs") == 0) {
        state = &tabsDragDebug_;
    }

    const QMimeData* mimeData = event->mimeData();
    const bool hasPlaylistMime =
        mimeData && mimeData->hasFormat(QLatin1String(kPlaylistItemMimeType));
    const bool hasUrls = mimeData && mimeData->hasUrls();
    const QString signature = QStringLiteral("%1|%2|%3|%4|%5|%6|%7")
                                  .arg(QString::fromLatin1(phase))
                                  .arg(event->isAccepted() ? 1 : 0)
                                  .arg(static_cast<int>(event->possibleActions()))
                                  .arg(static_cast<int>(event->proposedAction()))
                                  .arg(static_cast<int>(event->dropAction()))
                                  .arg(hasPlaylistMime ? 1 : 0)
                                  .arg(hasUrls ? 1 : 0);
    if (state->lastSignature == signature) {
        return;
    }
    state->lastSignature = signature;

    qDebug().noquote()
        << QStringLiteral("[DragDebug][%1] %2 local=(%3,%4) global=(%5,%6) accepted=%7 possible=%8 proposed=%9 drop=%10 has_playlist=%11 has_urls=%12 cursor=%13")
               .arg(QString::fromLatin1(target))
               .arg(QString::fromLatin1(phase))
               .arg(localPos.x())
               .arg(localPos.y())
               .arg(globalPos.x())
               .arg(globalPos.y())
               .arg(event->isAccepted() ? 1 : 0)
               .arg(dropActionsText(event->possibleActions()))
               .arg(dropActionText(event->proposedAction()))
               .arg(dropActionText(event->dropAction()))
               .arg(hasPlaylistMime ? 1 : 0)
               .arg(hasUrls ? 1 : 0)
               .arg(cursorShapeText(cursor().shape()));
}

void PlaylistWindow::resetDragDebugState(const char* target) {
    if (!target || qstrcmp(target, "list") == 0) {
        listDragDebug_.lastSignature.clear();
    }
    if (!target || qstrcmp(target, "tabs") == 0) {
        tabsDragDebug_.lastSignature.clear();
    }
    if (!target || qstrcmp(target, "root") == 0) {
        rootDragDebug_.lastSignature.clear();
    }
}

void PlaylistWindow::setDividerPosition(int pos) {
    const int effectivePos = qMax(0, pos);
    dividerPos_ = effectivePos;
    if (effectivePos > 0) {
        dividerSavedPos_ = effectivePos;
    }
    updateListGeometry();
    update();
}

int PlaylistWindow::dividerPosition() const {
    return dividerPos_ > 0 ? dividerPos_ : dividerSavedPos_;
}

QRect PlaylistWindow::dividerVisualRect() const {
    const QRect plRect = playlistRect();
    if (plRect.isEmpty()) {
        return {};
    }
    const int dividerX = plRect.x() + (isDividerCollapsed() ? 0 : dividerPos_);
    return QRect(dividerX, plRect.y(), kDividerWidth, plRect.height());
}

QRect PlaylistWindow::dividerHotZoneRect() const {
    const QRect visualRect = dividerVisualRect();
    if (visualRect.isEmpty()) {
        return {};
    }
    return visualRect.adjusted(-6, 0, 6, 0);
}

QRect PlaylistWindow::dividerHandleRect() const {
    const QRect visualRect = dividerVisualRect();
    if (visualRect.isEmpty()) {
        return {};
    }
    const int cy = visualRect.center().y();
    return QRect(visualRect.x(), cy - kDividerHandleHalfHeight,
                 visualRect.width(), 2 * kDividerHandleHalfHeight + 1);
}

bool PlaylistWindow::isDividerCollapsed() const {
    return dividerPos_ <= 0;
}

void PlaylistWindow::toggleDividerCollapsed() {
    if (isDividerCollapsed()) {
        dividerPos_ = qMax(kDividerMinExpandedPos, dividerSavedPos_);
    } else {
        dividerSavedPos_ = dividerPos_;
        dividerPos_ = 0;
    }
    updateListGeometry();
    update();
}

void PlaylistWindow::applyStyle() {
    auto bg     = colorBkgnd_.name();
    auto sel    = colorSelect_.name();

    // 代理负责项目颜色，样式表仅设置列表级属性
    if (playlistDelegate_) {
        static_cast<PlaylistItemDelegate*>(playlistDelegate_)->setColors(
            colorText_, colorHilight_, colorBkgnd_, colorBkgnd2_,
            colorSelect_, colorNumber_, colorDuration_);
    }

    listWidget_->setStyleSheet(QString(
        "QListWidget {"
        "  background-color: %1;"
        "  border: none;"
        "  outline: none;"
        "}"
        "QScrollBar:vertical { width: 8px; background: %1; }"
        "QScrollBar::handle:vertical { background: %2; min-height: 20px; }"
        "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }"
    ).arg(bg, sel));

    listWidget_->setAlternatingRowColors(false);

    if (searchEdit_) {
        searchEdit_->setStyleSheet(QString(
            "QLineEdit {"
            "  background-color: %1;"
            "  color: %2;"
            "  border: 1px solid %3;"
            "  padding: 2px 6px;"
            "  selection-background-color: %3;"
            "  selection-color: %4;"
            "}"
        ).arg(colorBkgnd2_.name(), colorText_.name(), sel, colorHilight_.name()));
    }

    if (playlistTabsWidget_) {
        playlistTabsWidget_->setStyleSheet(QString(
            "QListWidget {"
            "  background-color: %1;"
            "  color: %2;"
            "  border: none;"
            "  font-size: 11px;"
            "  outline: none;"
            "}"
            "QListWidget::item { padding: 2px 4px; }"
            "QListWidget::item:selected {"
            "  background: qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 %1, stop:1 %3);"
            "  color: %4;"
            "}"
            "QScrollBar:vertical { width: 8px; background: %1; }"
            "QScrollBar::handle:vertical { background: %3; min-height: 20px; }"
            "QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }"
        ).arg(bg, colorText_.name(), sel, colorHilight_.name()));
    }
}

// 将皮肤数据应用到播放列表窗口，并重置相关可视元素。
void PlaylistWindow::applySkin(const SkinData& skin) {
    const SkinWindow& w = skin.playlistWindow;

    qDeleteAll(findChildren<SkinButton*>(QString(), Qt::FindDirectChildrenOnly));
    closeButton_ = nullptr;
    hoveredToolbarGroup_ = -1;
    pressedToolbarGroup_ = -1;

    // 应用 PlayList.xml 中的颜色配置
    colorText_    = skin.playlistConfig.colorText;
    colorHilight_ = skin.playlistConfig.colorHilight;
    colorBkgnd_   = skin.playlistConfig.colorBkgnd;
    colorNumber_  = skin.playlistConfig.colorNumber;
    colorDuration_= skin.playlistConfig.colorDuration;
    colorBkgnd2_  = skin.playlistConfig.colorBkgnd2;
    colorSelect_  = skin.playlistConfig.colorSelect;
    // 原版列表分隔条默认从播放列表前景/背景色回退，而不是走 Color_Select 或 Skin.xml hilight。
    splitterFrontColor_ = colorText_;
    splitterBackColor_ = colorBkgnd_;
    listWidget_->setFont(skin.playlistConfig.font);

    applyStyle();

    baseBackground_ = w.backgroundPixmap;
    baseSize_ = baseBackground_.isNull() ? QSize(268, 165) : baseBackground_.size();
    resizeRect_  = w.resizeRect;
    resizeTile_  = w.resizeTile;
    toolbarElement_ = {};
    scrollbarElement_ = {};
    titleElement_ = {};
    playlistElement_ = {};
    closeElement_ = {};

    for (const auto& elem : w.elements) {
        if (elem.type == "playlist") {
            playlistElement_ = elem;
        } else if (elem.type == "toolbar") {
            toolbarElement_ = elem;
        } else if (elem.type == "scrollbar") {
            scrollbarElement_ = elem;
        } else if (elem.type == "title") {
            titleElement_ = elem;
        } else if (elem.type == "close") {
            closeElement_ = elem;
        }
    }

    // 将 selected_image 传递给代理，用于渐变/图像选择效果
    if (playlistDelegate_) {
        static_cast<PlaylistItemDelegate*>(playlistDelegate_)->setSelectedPixmap(
            playlistElement_.selectedPixmap);
    }

    if (!closeElement_.position.isEmpty()) {
        closeButton_ = new SkinButton(this);
        connect(closeButton_, &SkinButton::clicked, this, [this]() {
            emit closeRequested();
        });
        closeButton_->setSkinElement(closeElement_);
        closeButton_->show();
    }

    auto* skinBar = static_cast<SkinScrollBarWidget*>(skinScrollBar_);
    skinBar->setSkinElement(scrollbarElement_);
    skinBar->setPageStep(listWidget_->verticalScrollBar()->pageStep());
    skinBar->setRange(listWidget_->verticalScrollBar()->minimum(), listWidget_->verticalScrollBar()->maximum());
    skinBar->setValue(listWidget_->verticalScrollBar()->value());
    auto* tabsSkinBar = static_cast<SkinScrollBarWidget*>(tabsSkinScrollBar_);
    tabsSkinBar->setSkinElement(scrollbarElement_);
    tabsSkinBar->setPageStep(playlistTabsWidget_->verticalScrollBar()->pageStep());
    tabsSkinBar->setRange(playlistTabsWidget_->verticalScrollBar()->minimum(),
                          playlistTabsWidget_->verticalScrollBar()->maximum());
    tabsSkinBar->setValue(playlistTabsWidget_->verticalScrollBar()->value());

    setMinimumSize(baseSize_);
    setMaximumSize(QWIDGETSIZE_MAX, QWIDGETSIZE_MAX);
    // 不要在这里调整尺寸，layoutFromSkin() 会设置正确大小。

    rebuildBackground();
    updateChromeGeometry();
    updateListGeometry();
    update();
}

// 基于当前窗口大小和可拉伸区域重建背景图像。
void PlaylistWindow::rebuildBackground() {
    if (baseBackground_.isNull()) {
        background_ = QPixmap(size());
        background_.fill(Qt::transparent);
        return;
    }

    if (resizeRect_.isEmpty()) {
        background_ = baseBackground_;
        return;
    }

    const int left = resizeRect_.left();
    const int top = resizeRect_.top();
    const int centerW = resizeRect_.width();
    const int centerH = resizeRect_.height();
    const int right = baseBackground_.width() - (resizeRect_.x() + resizeRect_.width());
    const int bottom = baseBackground_.height() - (resizeRect_.y() + resizeRect_.height());

    background_ = QPixmap(width(), height());
    background_.fill(Qt::transparent);
    QPainter p(&background_);

    const QPixmap topLeft = baseBackground_.copy(0, 0, left, top);
    const QPixmap topMid = baseBackground_.copy(left, 0, centerW, top);
    const QPixmap topRight = baseBackground_.copy(baseBackground_.width() - right, 0, right, top);
    const QPixmap midLeft = baseBackground_.copy(0, top, left, centerH);
    const QPixmap mid = baseBackground_.copy(left, top, centerW, centerH);
    const QPixmap midRight = baseBackground_.copy(baseBackground_.width() - right, top, right, centerH);
    const QPixmap bottomLeft = baseBackground_.copy(0, baseBackground_.height() - bottom, left, bottom);
    const QPixmap bottomMid = baseBackground_.copy(left, baseBackground_.height() - bottom, centerW, bottom);
    const QPixmap bottomRight = baseBackground_.copy(baseBackground_.width() - right, baseBackground_.height() - bottom, right, bottom);

    p.drawPixmap(0, 0, topLeft);
    p.drawPixmap(width() - right, 0, topRight);
    p.drawPixmap(0, height() - bottom, bottomLeft);
    p.drawPixmap(width() - right, height() - bottom, bottomRight);

    drawHorizontalSlice(p, topMid, QRect(left, 0, width() - left - right, top), resizeTile_);
    drawHorizontalSlice(p, bottomMid, QRect(left, height() - bottom, width() - left - right, bottom), resizeTile_);
    drawVerticalSlice(p, midLeft, QRect(0, top, left, height() - top - bottom), resizeTile_);
    drawVerticalSlice(p, midRight, QRect(width() - right, top, right, height() - top - bottom), resizeTile_);
    drawCenterSlice(p, mid, QRect(left, top, width() - left - right, height() - top - bottom), resizeTile_);
}

// 更新列表、标签页和自定义滚动条的位置与大小。
void PlaylistWindow::updateListGeometry() {
    const QRect plRect = playlistRect();
    int rightScrollBarWidth = 0;
    if (skinScrollBar_ && !scrollbarElement_.buttonsPixmap.isNull()) {
        rightScrollBarWidth = static_cast<SkinScrollBarWidget*>(skinScrollBar_)->widthHint();
    }
    const QRect contentRect = plRect.adjusted(0, 0, rightScrollBarWidth > 0 ? -rightScrollBarWidth : 0, 0);
    const int maxDivider = qMax(0, contentRect.width() - kDividerWidth - 24);
    dividerPos_ = qBound(0, dividerPos_, maxDivider);
    if (!isDividerCollapsed()) {
        int leftScrollBarWidth = 0;
        if (tabsSkinScrollBar_ && !scrollbarElement_.buttonsPixmap.isNull()) {
            auto* nativeBar = playlistTabsWidget_->verticalScrollBar();
            if (nativeBar->maximum() > nativeBar->minimum()) {
                leftScrollBarWidth = static_cast<SkinScrollBarWidget*>(tabsSkinScrollBar_)->widthHint();
            }
        }
        const int tabsWidth = qMin(dividerPos_, qMax(0, contentRect.width() - kDividerWidth - 1));
        const int tabsContentWidth = qMax(1, tabsWidth - leftScrollBarWidth);
        playlistTabsWidget_->setGeometry(
            contentRect.x(), contentRect.y(),
            tabsContentWidth, contentRect.height());
        playlistTabsWidget_->setVisible(true);
        if (tabsSkinScrollBar_ && leftScrollBarWidth > 0) {
            tabsSkinScrollBar_->setGeometry(contentRect.x() + tabsContentWidth, contentRect.y(),
                                            leftScrollBarWidth, contentRect.height());
            auto* nativeBar = playlistTabsWidget_->verticalScrollBar();
            auto* skinBar = static_cast<SkinScrollBarWidget*>(tabsSkinScrollBar_);
            skinBar->setPageStep(nativeBar->pageStep());
            skinBar->setRange(nativeBar->minimum(), nativeBar->maximum());
            skinBar->setValue(nativeBar->value());
            tabsSkinScrollBar_->setVisible(nativeBar->maximum() > nativeBar->minimum());
        } else if (tabsSkinScrollBar_) {
            tabsSkinScrollBar_->hide();
        }
        listWidget_->setGeometry(
            contentRect.x() + dividerPos_ + kDividerWidth, contentRect.y(),
            qMax(1, contentRect.width() - dividerPos_ - kDividerWidth), contentRect.height());
    } else {
        playlistTabsWidget_->setVisible(false);
        if (tabsSkinScrollBar_) {
            tabsSkinScrollBar_->hide();
        }
        listWidget_->setGeometry(contentRect.adjusted(kDividerWidth, 0, 0, 0));
    }

    if (skinScrollBar_) {
        if (rightScrollBarWidth > 0) {
            skinScrollBar_->setGeometry(plRect.right() - rightScrollBarWidth + 1, plRect.top(),
                                        rightScrollBarWidth, plRect.height());
            auto* nativeBar = listWidget_->verticalScrollBar();
            auto* skinBar = static_cast<SkinScrollBarWidget*>(skinScrollBar_);
            skinBar->setPageStep(nativeBar->pageStep());
            skinBar->setRange(nativeBar->minimum(), nativeBar->maximum());
            skinBar->setValue(nativeBar->value());
            skinScrollBar_->setVisible(nativeBar->maximum() > nativeBar->minimum());
        } else {
            skinScrollBar_->hide();
        }
    }
}

// 更新窗口边框、关闭按钮和遮罩区域，以保持基于皮肤的外观。
void PlaylistWindow::updateChromeGeometry() {
    if (closeButton_ && !closeElement_.position.isEmpty()) {
        closeButton_->move(alignedRect(closeElement_.position, baseSize_, size(),
                                       closeElement_.align, closeButton_->size()).topLeft());
    }

    clearMask();
    if (!background_.isNull()) {
        const QBitmap mask = background_.mask();
        if (!mask.isNull()) {
            setMask(mask);
        }
    }
}

QRect PlaylistWindow::playlistRect() const {
    if (playlistElement_.position.isEmpty()) {
        return QRect(4, 50, width() - 8, height() - 74);
    }

    const int rightMargin = baseSize_.width() - (playlistElement_.position.x() + playlistElement_.position.width());
    const int bottomMargin = baseSize_.height() - (playlistElement_.position.y() + playlistElement_.position.height());
    return QRect(playlistElement_.position.x(), playlistElement_.position.y(),
                 qMax(1, width() - playlistElement_.position.x() - rightMargin),
                 qMax(1, height() - playlistElement_.position.y() - bottomMargin));
}

QRect PlaylistWindow::titleDrawRect() const {
    const QSize titleSize = titleElement_.statePixmaps[0].isNull()
        ? titleElement_.position.size()
        : titleElement_.statePixmaps[0].size();
    return alignedRect(titleElement_.position, baseSize_, size(), titleElement_.align, titleSize);
}

QRect PlaylistWindow::toolbarAreaRect() const {
    if (toolbarElement_.position.isEmpty()) {
        return {};
    }
    return alignedRect(toolbarElement_.position, baseSize_, size(), toolbarElement_.align,
                       toolbarElement_.position.size());
}

QRect PlaylistWindow::toolbarGroupRect(int group) const {
    if (group < 0 || group >= kToolbarGroupCount) {
        return {};
    }

    const QRect toolbarRect = toolbarAreaRect();
    if (toolbarRect.isEmpty()) {
        return {};
    }

    const int left = toolbarRect.left() + (toolbarRect.width() * group) / kToolbarGroupCount;
    const int right = toolbarRect.left() + (toolbarRect.width() * (group + 1)) / kToolbarGroupCount;
    return QRect(left, toolbarRect.top(), qMax(1, right - left), toolbarRect.height());
}

QRect PlaylistWindow::toolbarGroupDrawRect(int group, const QPixmap& sheet) const {
    const QRect groupRect = toolbarGroupRect(group);
    if (groupRect.isEmpty() || sheet.isNull()) {
        return groupRect;
    }

    const int srcLeft = (sheet.width() * group) / kToolbarGroupCount;
    const int srcRight = (sheet.width() * (group + 1)) / kToolbarGroupCount;
    const QSize srcSize(qMax(1, srcRight - srcLeft), sheet.height());
    QRect drawRect(groupRect.topLeft(), srcSize);
    drawRect.moveLeft(groupRect.left() + (groupRect.width() - drawRect.width()) / 2);
    drawRect.moveTop(groupRect.top() + (groupRect.height() - drawRect.height()) / 2);
    return drawRect;
}

QPoint PlaylistWindow::toolbarMenuAnchor(int group) const {
    const QRect groupRect = toolbarGroupRect(group);
    if (groupRect.isNull()) {
        return QCursor::pos();
    }
    return mapToGlobal(QPoint(groupRect.left(), groupRect.bottom()));
}

Qt::Edges PlaylistWindow::resizeEdgesForPosition(const QPoint& pos) const {
    if (resizeRect_.isEmpty()) {
        return {};
    }

    Qt::Edges edges;
    if (pos.x() >= width() - 8) {
        edges |= Qt::RightEdge;
    }
    if (pos.y() >= height() - 8) {
        edges |= Qt::BottomEdge;
    }
    return edges;
}

int PlaylistWindow::toolbarGroupIndexAt(const QPoint& pos) const {
    const QRect toolbarRect = toolbarAreaRect();
    if (toolbarRect.isEmpty() || !toolbarRect.contains(pos)) {
        return -1;
    }

    const int relativeX = pos.x() - toolbarRect.left();
    const int group = (relativeX * kToolbarGroupCount) / qMax(1, toolbarRect.width());
    if (group < 0 || group >= kToolbarGroupCount) {
        return -1;
    }
    return group;
}

void PlaylistWindow::addFile(const QString& filePath) {
    QElapsedTimer totalTimer;
    totalTimer.start();

    QElapsedTimer addTimer;
    addTimer.start();
    playlist_.addFile(filePath);
    const qint64 addMs = addTimer.elapsed();

    QElapsedTimer refreshTimer;
    refreshTimer.start();
    refreshPlaylistView();
    const qint64 refreshMs = refreshTimer.elapsed();

    qDebug().noquote()
        << QStringLiteral("[ImportPerf][PlaylistWindow] addFile total=%1ms add_metadata=%2ms refresh=%3ms path=\"%4\"")
               .arg(totalTimer.elapsed())
               .arg(addMs)
               .arg(refreshMs)
               .arg(filePath);
}

void PlaylistWindow::addFiles(const QStringList& files) {
    QElapsedTimer totalTimer;
    totalTimer.start();

    QElapsedTimer addTimer;
    addTimer.start();
    playlist_.addFiles(files);
    const qint64 addMs = addTimer.elapsed();

    QElapsedTimer refreshTimer;
    refreshTimer.start();
    refreshPlaylistView();
    const qint64 refreshMs = refreshTimer.elapsed();

    qDebug().noquote()
        << QStringLiteral("[ImportPerf][PlaylistWindow] addFiles total=%1ms add_metadata=%2ms refresh=%3ms count=%4")
               .arg(totalTimer.elapsed())
               .arg(addMs)
               .arg(refreshMs)
               .arg(files.size());
}

void PlaylistWindow::importFilesWithProgress(const QStringList& files, const QString& progressTitle) {
    const QString title = progressTitle.isEmpty() ? QStringLiteral("正在导入文件") : progressTitle;
    addFilesWithProgress(files, title);
}

QStringList PlaylistWindow::collectImportableAudioFiles(const QStringList& inputPaths) const {
    QStringList files;
    for (const QString& rawPath : inputPaths) {
        QFileInfo info(rawPath);
        if (!info.exists()) {
            continue;
        }

        if (info.isDir()) {
            QDirIterator it(info.absoluteFilePath(),
                            importAudioNameFilters(),
                            QDir::Files,
                            QDirIterator::Subdirectories);
            while (it.hasNext()) {
                files << it.next();
            }
            continue;
        }

        if (info.isFile() && isImportableAudioFile(info.absoluteFilePath())) {
            files << info.absoluteFilePath();
        }
    }
    return files;
}

void PlaylistWindow::addFilesWithProgress(const QStringList& files, const QString& progressTitle) {
    if (files.isEmpty()) {
        return;
    }

    const int beforeCount = playlist_.count();

    QProgressDialog progress(this);
    progress.setWindowTitle(progressTitle);
    progress.setLabelText(QStringLiteral("准备导入..."));
    progress.setCancelButtonText(QStringLiteral("停止"));
    progress.setRange(0, files.size());
    progress.setMinimumDuration(0);
    progress.setAutoReset(false);
    progress.setAutoClose(false);
    progress.setWindowModality(Qt::WindowModal);
    progress.setMinimumWidth(460);
    progress.show();

    auto updateProgressLabel = [&progress](const QString& currentPath, bool finished) {
        QString pathLine;
        if (!currentPath.isEmpty()) {
            if (auto* label = progress.findChild<QLabel*>()) {
                const int labelWidth = qMax(80, label->width() - 8);
                pathLine = QFontMetrics(label->font()).elidedText(currentPath, Qt::ElideMiddle, labelWidth);
            } else {
                pathLine = QFontMetrics(progress.font()).elidedText(currentPath, Qt::ElideMiddle, 320);
            }
        }

        const QString statusLine = finished
            ? QStringLiteral("导入完成，正在刷新列表...")
            : QStringLiteral("正在读取文件信息...");
        progress.setLabelText(pathLine.isEmpty() ? statusLine : statusLine + QLatin1Char('\n') + pathLine);
    };

    QElapsedTimer totalTimer;
    totalTimer.start();

    QElapsedTimer addTimer;
    addTimer.start();
    playlist_.addFiles(files, [&progress, &updateProgressLabel](int processed, int total, const QString& currentPath) {
        progress.setMaximum(total);
        progress.setValue(processed);
        const bool finished = (processed >= total);
        QString path = currentPath;
        if (path.isEmpty() && !finished && processed > 0 && processed <= total) {
            path = QStringLiteral("第 %1 / %2 首").arg(processed).arg(total);
        }
        updateProgressLabel(path, finished);
        QApplication::processEvents();
        return !progress.wasCanceled();
    });
    const qint64 addMs = addTimer.elapsed();

    QElapsedTimer refreshTimer;
    refreshTimer.start();
    refreshPlaylistView();
    const qint64 refreshMs = refreshTimer.elapsed();

    progress.setValue(progress.maximum());
    progress.close();

    qDebug().noquote()
        << QStringLiteral("[ImportPerf][PlaylistWindow] addFiles total=%1ms add_metadata=%2ms refresh=%3ms count=%4")
               .arg(totalTimer.elapsed())
               .arg(addMs)
               .arg(refreshMs)
               .arg(playlist_.count() - beforeCount);
}

void PlaylistWindow::insertFilesWithProgress(const QStringList& files, int insertIndex, const QString& progressTitle) {
    if (files.isEmpty()) {
        return;
    }

    const QString title = progressTitle.isEmpty() ? QStringLiteral("正在导入文件") : progressTitle;
    const int boundedInsertIndex = qBound(0, insertIndex, playlist_.count());
    const int beforeCount = playlist_.count();
    auto* scrollBar = listWidget_->verticalScrollBar();
    const int preservedScrollValue = scrollBar ? scrollBar->value() : 0;

    QProgressDialog progress(this);
    progress.setWindowTitle(title);
    progress.setLabelText(QStringLiteral("准备导入..."));
    progress.setCancelButtonText(QStringLiteral("停止"));
    progress.setRange(0, files.size());
    progress.setMinimumDuration(0);
    progress.setAutoReset(false);
    progress.setAutoClose(false);
    progress.setWindowModality(Qt::WindowModal);
    progress.setMinimumWidth(460);
    progress.show();

    auto updateProgressLabel = [&progress](const QString& currentPath, bool finished) {
        QString pathLine;
        if (!currentPath.isEmpty()) {
            if (auto* label = progress.findChild<QLabel*>()) {
                const int labelWidth = qMax(80, label->width() - 8);
                pathLine = QFontMetrics(label->font()).elidedText(currentPath, Qt::ElideMiddle, labelWidth);
            } else {
                pathLine = QFontMetrics(progress.font()).elidedText(currentPath, Qt::ElideMiddle, 320);
            }
        }

        const QString statusLine = finished
            ? QStringLiteral("导入完成，正在刷新列表...")
            : QStringLiteral("正在读取文件信息...");
        progress.setLabelText(pathLine.isEmpty() ? statusLine : statusLine + QLatin1Char('\n') + pathLine);
    };

    QElapsedTimer totalTimer;
    totalTimer.start();

    QElapsedTimer addTimer;
    addTimer.start();
    playlist_.insertFiles(boundedInsertIndex, files, [&progress, &updateProgressLabel](int processed, int total, const QString& currentPath) {
        progress.setMaximum(total);
        progress.setValue(processed);
        const bool finished = (processed >= total);
        QString path = currentPath;
        if (path.isEmpty() && !finished && processed > 0 && processed <= total) {
            path = QStringLiteral("第 %1 / %2 首").arg(processed).arg(total);
        }
        updateProgressLabel(path, finished);
        QApplication::processEvents();
        return !progress.wasCanceled();
    });
    const qint64 addMs = addTimer.elapsed();

    const int insertedCount = playlist_.count() - beforeCount;
    QList<int> insertedRows;
    insertedRows.reserve(insertedCount);
    for (int i = 0; i < insertedCount; ++i) {
        insertedRows.append(boundedInsertIndex + i);
    }

    QElapsedTimer refreshTimer;
    refreshTimer.start();
    refreshPlaylistView(QStringLiteral("insertFilesWithProgress insert_at=%1 count=%2")
                            .arg(boundedInsertIndex)
                            .arg(insertedCount));
    restoreSelectionBySourceIndices(insertedRows,
                                    insertedRows.isEmpty() ? playlist_.currentIndex() : insertedRows.first());
    if (scrollBar) {
        markScrollDebugContext(false, QStringLiteral("insertFiles_restoreScroll"));
        scrollBar->setValue(qBound(scrollBar->minimum(), preservedScrollValue, scrollBar->maximum()));
        qDebug().noquote()
            << QStringLiteral("[ScrollDebug][playlist] insertFiles restoreScroll preserved=%1 actual=%2 max=%3 insert_at=%4 count=%5")
                   .arg(preservedScrollValue)
                   .arg(scrollBar->value())
                   .arg(scrollBar->maximum())
                   .arg(boundedInsertIndex)
                   .arg(insertedCount);
    }
    const qint64 refreshMs = refreshTimer.elapsed();

    progress.setValue(progress.maximum());
    progress.close();

    qDebug().noquote()
        << QStringLiteral("[ImportPerf][PlaylistWindow] insertFiles total=%1ms add_metadata=%2ms refresh=%3ms insert_at=%4 count=%5")
               .arg(totalTimer.elapsed())
               .arg(addMs)
               .arg(refreshMs)
               .arg(boundedInsertIndex)
               .arg(insertedCount);
}

QString PlaylistWindow::currentFile() const {
    return playlist_.currentFile();
}

QString PlaylistWindow::nextFile() const {
    return const_cast<PlaylistManager&>(playlist_).nextFile();
}

QString PlaylistWindow::prevFile() const {
    return const_cast<PlaylistManager&>(playlist_).prevFile();
}

void PlaylistWindow::setPlaybackMode(int repeatMode, bool shuffle) {
    playlist_.setRepeatMode(repeatMode);
    playlist_.setShuffle(shuffle);
}

int PlaylistWindow::sourceIndexForItem(const QListWidgetItem* item) const {
    if (!item) {
        return -1;
    }
    return item->data(Qt::UserRole).toInt();
}

QListWidgetItem* PlaylistWindow::findVisibleItemBySource(int sourceIndex) {
    if (sourceIndex < 0) {
        return nullptr;
    }

    const auto it = visibleRowBySource_.constFind(sourceIndex);
    if (it != visibleRowBySource_.cend()) {
        const int row = it.value();
        if (row >= 0 && row < listWidget_->count()) {
            QListWidgetItem* cached = listWidget_->item(row);
            if (cached && cached->data(SourceIndexRole).toInt() == sourceIndex) {
                return cached;
            }
        }
    }

    for (int row = 0; row < listWidget_->count(); ++row) {
        QListWidgetItem* item = listWidget_->item(row);
        if (item && item->data(SourceIndexRole).toInt() == sourceIndex) {
            visibleRowBySource_.insert(sourceIndex, row);
            return item;
        }
    }
    return nullptr;
}

bool PlaylistWindow::matchesFilter(const PlaylistEntry& entry) const {
    if (filterText_.isEmpty()) {
        return true;
    }

    const QString needle = filterText_;
    return entry.title.contains(needle, Qt::CaseInsensitive)
        || entry.artist.contains(needle, Qt::CaseInsensitive)
        || entry.album.contains(needle, Qt::CaseInsensitive)
        || QFileInfo(entry.filePath).fileName().contains(needle, Qt::CaseInsensitive)
        || entry.filePath.contains(needle, Qt::CaseInsensitive);
}

QList<int> PlaylistWindow::selectedSourceIndices() const {
    QList<int> rows;
    rows.reserve(listWidget_->selectedItems().size());
    for (QListWidgetItem* item : listWidget_->selectedItems()) {
        const int sourceIndex = sourceIndexForItem(item);
        if (sourceIndex >= 0) {
            rows.append(sourceIndex);
        }
    }
    return normalizedSourceIndices(rows);
}

void PlaylistWindow::restoreSelectionBySourceIndices(const QList<int>& sourceIndices, int currentSource) {
    QSet<int> selectedSet;
    for (int sourceIndex : sourceIndices) {
        selectedSet.insert(sourceIndex);
    }
    listWidget_->clearSelection();

    QListWidgetItem* currentItem = nullptr;
    QModelIndex currentIndex;
    for (int row = 0; row < listWidget_->count(); ++row) {
        QListWidgetItem* item = listWidget_->item(row);
        if (!item) {
            continue;
        }
        const int sourceIndex = sourceIndexForItem(item);
        if (selectedSet.contains(sourceIndex)) {
            item->setSelected(true);
            if (!currentItem) {
                currentItem = item;
            }
        }
        if (sourceIndex == currentSource) {
            currentItem = item;
            currentIndex = listWidget_->model()->index(row, 0);
        }
    }

    if (currentItem) {
        listWidget_->selectionModel()->setCurrentIndex(currentIndex, QItemSelectionModel::NoUpdate);
    }
}

void PlaylistWindow::updateSearchPlaceholder(int visibleCount) {
    if (!searchEdit_) {
        return;
    }

    const int totalCount = playlist_.count();
    QString text = QStringLiteral("搜索播放列表  |  %1/%2 首")
        .arg(visibleCount)
        .arg(totalCount);

    const int64_t totalDuration = playlist_.totalDurationMs();
    if (totalDuration > 0) {
        text += QStringLiteral("  |  %1").arg(formatDurationText(totalDuration));
    }

    searchEdit_->setPlaceholderText(text);
    searchEdit_->setToolTip(text);
}

void PlaylistWindow::onCurrentChanged(int index) {
    const int currentSource = playlist_.currentIndex();
    auto updatePlayingState = [this](int sourceIndex, bool isPlaying) {
        if (sourceIndex < 0 || sourceIndex >= playlist_.count()) {
            return;
        }
        if (QListWidgetItem* item = findVisibleItemBySource(sourceIndex)) {
            item->setData(IsPlayingRole, isPlaying);
            item->setData(TitleRole, displayTitleForEntry(playlist_.at(sourceIndex)));
        }
    };

    if (displayedPlayingSource_ != currentSource) {
        updatePlayingState(displayedPlayingSource_, false);
        updatePlayingState(currentSource, true);
        displayedPlayingSource_ = currentSource;
    }
    Q_UNUSED(index);
}

void PlaylistWindow::saveActiveTab() {
    if (activeTab_ >= 0 && activeTab_ < tabData_.size()) {
        tabData_[activeTab_].entries = playlist_.entries();
        tabData_[activeTab_].currentIndex = playlist_.currentIndex();
    }
}

void PlaylistWindow::switchToTab(int index) {
    if (index < 0 || index >= tabData_.size() || index == activeTab_)
        return;

    // 保存当前标签页状态
    saveActiveTab();

    // 加载新标签页
    activeTab_ = index;
    playlist_.clear();
    playlist_.setEntries(tabData_[index].entries);
    playlist_.setCurrentIndex(tabData_[index].currentIndex);

    refreshPlaylistView(QStringLiteral("switchToTab index=%1").arg(index));
}

void PlaylistWindow::refreshPlaylistView(const QString& reason) {
    // 重新构建列表项视图，同时保留当前选择、焦点和滚动位置。
    auto* scrollBar = listWidget_->verticalScrollBar();
    const int scrollValue = scrollBar ? scrollBar->value() : 0;
    QList<int> selectedSources;
    for (auto* item : listWidget_->selectedItems()) {
        const int sourceIndex = sourceIndexForItem(item);
        if (sourceIndex >= 0) {
            selectedSources.append(sourceIndex);
        }
    }
    const int focusedSource = sourceIndexForItem(listWidget_->currentItem());
    const QString debugReason = reason.isEmpty() ? QStringLiteral("unspecified") : reason;

    qDebug().noquote()
        << QStringLiteral("[ScrollDebug][playlist] refreshPlaylistView begin reason=\"%1\" value=%2 count=%3 selected=%4 current=%5 filter=\"%6\"")
               .arg(debugReason)
               .arg(scrollValue)
               .arg(playlist_.count())
               .arg(selectedSources.size())
               .arg(focusedSource)
               .arg(filterText_);

    // 在重建列表期间阻塞滚动条信号，防止 rangeChanged/valueChanged
    // 通过 skinScrollBar 同步时重置滚动位置。
    if (scrollBar) scrollBar->blockSignals(true);
    listWidget_->setUpdatesEnabled(false);
    listWidget_->clear();
    visibleRowBySource_.clear();

    const int currentSource = playlist_.currentIndex();
    displayedPlayingSource_ = currentSource;
    int visibleCount = 0;
    for (int i = 0; i < playlist_.count(); ++i) {
        const PlaylistEntry& entry = playlist_.at(i);
        if (!matchesFilter(entry)) {
            continue;
        }

        const bool isPlaying = (i == currentSource);

        // 序号段
        const QString number = QString::number(i + 1) + QChar('.');
        const QString title = displayTitleForEntry(entry);
        const QString duration = displayDurationForEntry(entry);

        auto* item = new QListWidgetItem(listWidget_);
        item->setFlags(playlistEntryItemFlags(item->flags()));
        item->setData(SourceIndexRole, i);
        item->setData(NumberRole, number);
        item->setData(TitleRole, title);
        item->setData(DurationRole, duration);
        item->setData(IsPlayingRole, isPlaying);
        item->setData(FilePathRole, entry.filePath);
        if (selectedSources.contains(i)) {
            item->setSelected(true);
        }
        if (i == focusedSource) {
            listWidget_->setCurrentItem(item);
        }
        visibleRowBySource_.insert(i, listWidget_->count() - 1);
        ++visibleCount;
    }

    if (visibleCount == 0 && !playlist_.isEmpty() && !filterText_.isEmpty()) {
        auto* item = new QListWidgetItem(QStringLiteral("没有匹配结果"), listWidget_);
        item->setFlags(Qt::NoItemFlags);
        item->setForeground(colorNumber_);
    }

    updateSearchPlaceholder(visibleCount);

    // 先重新启用更新，让 Qt 正确布局，
    // 然后恢复滚动并解除信号屏蔽。
    listWidget_->setUpdatesEnabled(true);
    if (scrollBar) {
        markScrollDebugContext(false, QStringLiteral("refreshPlaylistView_restore"));
        scrollBar->setValue(scrollValue);
        scrollBar->blockSignals(false);
        // 将 skinScrollBar 同步到恢复后的值
        emit scrollBar->valueChanged(scrollBar->value());
        emit scrollBar->rangeChanged(scrollBar->minimum(), scrollBar->maximum());

        qDebug().noquote()
            << QStringLiteral("[ScrollDebug][playlist] refreshPlaylistView end reason=\"%1\" saved=%2 restored=%3 max=%4 visible=%5")
                   .arg(debugReason)
                   .arg(scrollValue)
                   .arg(scrollBar->value())
                   .arg(scrollBar->maximum())
                   .arg(listWidget_->count());
    }
}

void PlaylistWindow::ensureSearchDialog() {
    if (searchDialog_) {
        return;
    }
    // 创建搜索对话框并绑定关键字输入事件

    searchDialog_ = new QDialog(this, Qt::Tool);
    searchDialog_->setWindowTitle(QStringLiteral("搜索播放列表"));
    searchDialog_->setModal(false);

    auto* rootLayout = new QVBoxLayout(searchDialog_);
    rootLayout->setContentsMargins(10, 10, 10, 10);
    rootLayout->setSpacing(8);

    auto* inputRow = new QHBoxLayout();
    inputRow->setSpacing(6);
    auto* label = new QLabel(QStringLiteral("关键字:"), searchDialog_);
    searchEdit_ = new QLineEdit(searchDialog_);
    searchEdit_->setCursor(Qt::ArrowCursor);
    searchEdit_->setClearButtonEnabled(true);
    inputRow->addWidget(label);
    inputRow->addWidget(searchEdit_, 1);
    rootLayout->addLayout(inputRow);

    auto* buttonRow = new QHBoxLayout();
    buttonRow->addStretch();
    auto* closeButton = new QPushButton(QStringLiteral("关闭"), searchDialog_);
    buttonRow->addWidget(closeButton);
    rootLayout->addLayout(buttonRow);

    connect(searchEdit_, &QLineEdit::textChanged, this, [this](const QString& text) {
        filterText_ = text.trimmed();
        refreshPlaylistView();
    });
    connect(closeButton, &QPushButton::clicked, searchDialog_, &QDialog::hide);

    applyStyle();
    updateSearchPlaceholder(listWidget_->count());
    searchDialog_->resize(320, searchDialog_->sizeHint().height());
}

void PlaylistWindow::showSearchDialog() {
    ensureSearchDialog();
    updateSearchPlaceholder(listWidget_->count());

    const int dialogX = (width() - searchDialog_->width()) / 2;
    const QRect toolbarRect = toolbarAreaRect();
    const int dialogY = qMax(titleDrawRect().bottom() + 10, toolbarRect.bottom() + 10);
    searchDialog_->move(mapToGlobal(QPoint(dialogX, dialogY)));
    searchDialog_->show();
    searchDialog_->raise();
    searchDialog_->activateWindow();
    searchEdit_->setFocus();
    searchEdit_->selectAll();
}

void PlaylistWindow::setCurrentFile(const QString& filePath) {
    const int current = playlist_.currentIndex();
    if (current >= 0 && current < playlist_.count() && playlist_.fileAt(current) == filePath) {
        onCurrentChanged(current);
        return;
    }

    const int index = playlist_.indexOfFile(filePath);
    if (index >= 0) {
        playlist_.setCurrentIndex(index);
        onCurrentChanged(index);
    }
}

qint64 PlaylistWindow::takeLastUserSwitchRequestMs(const QString& filePath, bool* fromDoubleClick) {
    if (fromDoubleClick) {
        *fromDoubleClick = false;
    }
    if (lastUserSwitchRequestMs_ <= 0 || filePath != lastUserSwitchPath_) {
        return -1;
    }

    const qint64 ts = lastUserSwitchRequestMs_;
    if (fromDoubleClick) {
        *fromDoubleClick = lastUserSwitchFromDoubleClick_;
    }
    lastUserSwitchRequestMs_ = -1;
    lastUserSwitchPath_.clear();
    lastUserSwitchFromDoubleClick_ = false;
    return ts;
}

int PlaylistWindow::insertionIndexForListPosition(const QPoint& pos) const {
    if (playlist_.isEmpty()) {
        return 0;
    }

    QListWidgetItem* item = listWidget_->itemAt(pos);
    if (!item) {
        QListWidgetItem* lastItem = listWidget_->count() > 0 ? listWidget_->item(listWidget_->count() - 1) : nullptr;
        if (!lastItem) {
            return playlist_.count();
        }
        const QRect lastRect = listWidget_->visualItemRect(lastItem);
        if (pos.y() < lastRect.top()) {
            return sourceIndexForItem(listWidget_->item(0));
        }
        return playlist_.count();
    }

    const int sourceIndex = sourceIndexForItem(item);
    const QRect itemRect = listWidget_->visualItemRect(item);
    if (pos.y() > itemRect.center().y()) {
        return sourceIndex + 1;
    }
    return sourceIndex;
}

int PlaylistWindow::dropIndicatorYForListPosition(const QPoint& pos) const {
    if (listWidget_->count() <= 0) {
        return 1;
    }

    QListWidgetItem* item = listWidget_->itemAt(pos);
    if (!item) {
        QListWidgetItem* lastItem = listWidget_->item(listWidget_->count() - 1);
        if (!lastItem) {
            return 1;
        }
        const QRect lastRect = listWidget_->visualItemRect(lastItem);
        if (pos.y() < lastRect.top()) {
            QListWidgetItem* firstItem = listWidget_->item(0);
            return firstItem ? listWidget_->visualItemRect(firstItem).top() : 1;
        }
        return lastRect.bottom() + 1;
    }

    const QRect itemRect = listWidget_->visualItemRect(item);
    return pos.y() > itemRect.center().y()
        ? itemRect.bottom() + 1
        : itemRect.top();
}

int PlaylistWindow::targetTabIndexForPosition(const QPoint& pos) const {
    const int directIndex = playlistTabsWidget_->indexAt(pos).row();
    if (directIndex >= 0) {
        return directIndex;
    }
    if (playlistTabsWidget_->count() <= 0) {
        return -1;
    }

    if (QListWidgetItem* currentItem = playlistTabsWidget_->currentItem()) {
        const QRect currentRect = playlistTabsWidget_->visualItemRect(currentItem);
        if (!currentRect.isEmpty() && currentRect.adjusted(-4, -4, 4, 4).contains(pos)) {
            return playlistTabsWidget_->currentRow();
        }
    }

    if (pos.y() < 0) {
        return 0;
    }
    return playlistTabsWidget_->count() - 1;
}

int PlaylistWindow::dropIndicatorYForTabPosition(const QPoint& pos) const {
    if (playlistTabsWidget_->count() <= 0) {
        return 1;
    }

    QListWidgetItem* item = playlistTabsWidget_->itemAt(pos);
    if (!item) {
        QListWidgetItem* lastItem = playlistTabsWidget_->item(playlistTabsWidget_->count() - 1);
        if (!lastItem) {
            return 1;
        }
        const QRect lastRect = playlistTabsWidget_->visualItemRect(lastItem);
        if (pos.y() < lastRect.top()) {
            QListWidgetItem* firstItem = playlistTabsWidget_->item(0);
            return firstItem ? playlistTabsWidget_->visualItemRect(firstItem).top() : 1;
        }
        return lastRect.bottom() + 1;
    }

    const QRect itemRect = playlistTabsWidget_->visualItemRect(item);
    return pos.y() > itemRect.center().y()
        ? itemRect.bottom() + 1
        : itemRect.top();
}

void PlaylistWindow::startPlaylistDrag(Qt::DropActions supportedActions) {
    Q_UNUSED(supportedActions);
    const QList<int> sourceIndices = selectedSourceIndices();
    if (sourceIndices.isEmpty()) {
        return;
    }
    resetDragDebugState();
    const Qt::DropActions dragActions = Qt::CopyAction | Qt::MoveAction;
    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] begin selected=%1 actions=%2 active_tab=%3 cursor=%4")
               .arg(sourceIndices.size())
               .arg(dropActionsText(dragActions))
               .arg(activeTab_)
               .arg(cursorShapeText(cursor().shape()));

    // 构建拖拽预览气泡（共用于 xcb 自定义拖拽和标准 XDnD 路径）
    const int count = sourceIndices.size();
    const QString firstTitle = displayTitleForEntry(playlist_.at(sourceIndices.first()));
    const QString dragText = count > 1
        ? QStringLiteral("%1 首歌曲").arg(count)
        : firstTitle;
    QFont font = listWidget_->font();
    font.setBold(true);
    const QFontMetrics fm(font);
    const int textWidth = qMin(320, fm.horizontalAdvance(dragText));
    const QSize pixmapSize(textWidth + 28, fm.height() + 18);
    QPixmap dragPixmap(pixmapSize);
    dragPixmap.fill(Qt::transparent);
    {
        QPainter painter(&dragPixmap);
        painter.setRenderHint(QPainter::Antialiasing, true);
        const QRect bubbleRect = dragPixmap.rect().adjusted(1, 1, -2, -2);
        painter.setBrush(QColor(35, 35, 35, 210));
        painter.setPen(QPen(QColor(255, 255, 255, 220), 1, Qt::DashLine));
        painter.drawRoundedRect(bubbleRect, 6, 6);
        painter.setFont(font);
        painter.setPen(QColor(255, 255, 255));
        painter.drawText(bubbleRect.adjusted(10, 0, -10, 0),
                         Qt::AlignLeft | Qt::AlignVCenter,
                         fm.elidedText(dragText, Qt::ElideRight, bubbleRect.width() - 20));
    }
    const QPoint hotSpot(14, dragPixmap.height() / 2);

    // xcb/XWayland: 窗口内走自定义拖拽，保住正常箭头；
    // 拖出窗口时再切回标准 XDnD，保留外部拖拽能力。
    if (kEnableCustomPlaylistDragOnXcb &&
        QGuiApplication::platformName() == QLatin1String("xcb")) {
        startPlaylistDragCustom(sourceIndices, dragPixmap, hotSpot);
        return;
    }

    startStandardPlaylistDrag(sourceIndices, dragPixmap, hotSpot);
}

void PlaylistWindow::startStandardPlaylistDrag(const QList<int>& sourceIndices,
                                               const QPixmap& previewPixmap,
                                               const QPoint& hotSpot) {
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const qint64 queuedDelayMs =
        pendingStandardDragQueuedMs_ > 0 ? (nowMs - pendingStandardDragQueuedMs_) : -1;
    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] standard_begin selected=%1 preview=%2x%3 hot=(%4,%5) queued_delay=%6ms cursor=%7")
               .arg(sourceIndices.size())
               .arg(previewPixmap.width())
               .arg(previewPixmap.height())
               .arg(hotSpot.x())
               .arg(hotSpot.y())
               .arg(queuedDelayMs)
               .arg(cursorShapeText(cursor().shape()));

    // --- 标准 XDnD 路径 ---
    QElapsedTimer setupTimer;
    setupTimer.start();
    auto* drag = new QDrag(listWidget_);
    QStringList filePaths;
    filePaths.reserve(sourceIndices.size());
    for (int sourceIndex : sourceIndices) {
        const QString filePath = playlist_.fileAt(sourceIndex);
        if (!filePath.isEmpty()) {
            filePaths.append(filePath);
        }
    }
    auto* mimeData = new PlaylistDragMimeData(activeTab_, sourceIndices, filePaths);
    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] standard_payload files=%1 active_tab=%2 has_urls=%3")
               .arg(filePaths.size())
               .arg(activeTab_)
               .arg(filePaths.isEmpty() ? 0 : 1);

    drag->setMimeData(mimeData);
    drag->setPixmap(previewPixmap);
    drag->setHotSpot(hotSpot);
    const QPixmap moveCursorPixmap = makeDragCursorPixmap(Qt::MoveAction);
    const QPixmap copyCursorPixmap = makeDragCursorPixmap(Qt::CopyAction);
    // 结合 DragDebug 日志可见，列表内部拖拽在目标侧已被接受，
    // 但 xcb/XWayland 标准 XDnD 光标仍会偶发卡在 IgnoreAction。
    // 这里先将 IgnoreAction 的显示降级为 MoveAction，避免错误的禁止图标长期停留。
    const QPixmap ignoreCursorPixmap =
        (QGuiApplication::platformName() == QLatin1String("xcb"))
            ? moveCursorPixmap
            : makeDragCursorPixmap(Qt::IgnoreAction);
    drag->setDragCursor(moveCursorPixmap, Qt::MoveAction);
    drag->setDragCursor(copyCursorPixmap, Qt::CopyAction);
    drag->setDragCursor(ignoreCursorPixmap, Qt::IgnoreAction);
    const qint64 setupElapsedMs = setupTimer.elapsed();

    const Qt::DropActions dragActions = Qt::CopyAction | Qt::MoveAction;
    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] pre_exec setup=%1ms buttons=%2 globalPos=(%3,%4)")
               .arg(setupElapsedMs)
               .arg(int(QGuiApplication::mouseButtons()))
               .arg(QCursor::pos().x())
               .arg(QCursor::pos().y());
    QElapsedTimer execTimer;
    execTimer.start();
    const Qt::DropAction resultAction = drag->exec(dragActions, Qt::MoveAction);
    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] end result=%1 exec=%2ms cursor=%3")
               .arg(dropActionText(resultAction))
               .arg(execTimer.elapsed())
               .arg(cursorShapeText(cursor().shape()));
    pendingStandardDragQueuedMs_ = -1;
}

void PlaylistWindow::startPlaylistDragCustom(const QList<int>& sourceIndices,
                                              const QPixmap& previewPixmap,
                                              const QPoint& hotSpot)
{
    customDragActive_        = true;
    customDragSourceIndices_ = sourceIndices;
    customDragSourceTab_     = activeTab_;
    customDragPreviewPixmap_ = previewPixmap;
    customDragHotSpot_       = hotSpot;
    customDragPromotingToStandard_ = false;
    customDragStartedMs_ = QDateTime::currentMSecsSinceEpoch();

    // 创建/复用浮动预览 label（透明工具提示窗口，跟随光标移动）
    if (!customDragPreviewLabel_) {
        customDragPreviewLabel_ = new QLabel(nullptr,
            Qt::ToolTip | Qt::FramelessWindowHint | Qt::WindowDoesNotAcceptFocus);
        
        // 关键改动：使预览窗口对鼠标事件完全穿透，避免被 XDnD 协议识别为拖放目标。
        // 如果没有这个属性，QDrag::exec() 启动后向它发送 XDnD 事件但由于它未实现响应/被隐藏
        // 会导致 XDnD 等待超时，即 ~1000 毫秒卡顿的根本原因。
        customDragPreviewLabel_->setAttribute(Qt::WA_TransparentForMouseEvents, true);
#if QT_VERSION >= QT_VERSION_CHECK(5, 1, 0)
        customDragPreviewLabel_->setWindowFlag(Qt::WindowTransparentForInput, true);
#endif

        customDragPreviewLabel_->setAttribute(Qt::WA_TranslucentBackground);
        customDragPreviewLabel_->setAlignment(Qt::AlignLeft | Qt::AlignTop);
    }
    customDragPreviewLabel_->setPixmap(previewPixmap);
    customDragPreviewLabel_->resize(previewPixmap.size());
    const QPoint cursorPos = QCursor::pos();
    customDragPreviewLabel_->move(cursorPos - hotSpot);
    customDragPreviewLabel_->show();

    // grabMouse(cursor) 调用 XGrabPointer 并携带正确的光标参数，
    // XWayland 可以正确处理，从一开始就显示移动光标。
    listWidget_->viewport()->grabMouse(QCursor(Qt::DragMoveCursor));
    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] custom_begin selected=%1 preview=%2x%3 hot=(%4,%5) cursor=%6")
               .arg(sourceIndices.size())
               .arg(previewPixmap.width())
               .arg(previewPixmap.height())
               .arg(hotSpot.x())
               .arg(hotSpot.y())
               .arg(cursorShapeText(cursor().shape()));
}

void PlaylistWindow::promoteCustomDragToStandard(const QPoint& globalPos)
{
    if (!customDragActive_ || customDragPromotingToStandard_) {
        return;
    }
    customDragPromotingToStandard_ = true;

    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] promote_custom_to_standard global=(%1,%2) selected=%3 custom_elapsed=%4ms")
               .arg(globalPos.x())
               .arg(globalPos.y())
               .arg(customDragSourceIndices_.size())
               .arg(customDragStartedMs_ > 0 ? QDateTime::currentMSecsSinceEpoch() - customDragStartedMs_ : -1);

    // 保存拖拽数据（清理自定义状态之前）
    const QList<int> sourceIndices = customDragSourceIndices_;
    const QPixmap previewPixmap = customDragPreviewPixmap_;
    const QPoint hotSpot = customDragHotSpot_;

    QElapsedTimer promoteTimer;
    promoteTimer.start();

    // 清理插入指示器
    static_cast<PlaylistDragListWidget*>(listWidget_)->setInsertionIndicatorY(-1);
    static_cast<PlaylistTabDropListWidget*>(playlistTabsWidget_)->setInsertionIndicatorY(-1);

    // 修复 1000 毫秒卡顿问题：
    // 之前保留 customDragPreviewLabel 作为 QDrag 的过渡，或者直接 hide() 都会导致 X server 缓存了它的坐标。
    // QDrag::exec 初始化后扫描光标下方的窗体时，XDnD 发现这是一个属于我方的窗口，于是发送 XdndEnter 消息，
    // 但是它被隐藏（或者我们并不理会），于是 QDrag 一直等候 XdndStatus（直到 1000ms 左右内部超时！）。
    // 现在直接 releaseMouse 并销毁这个残留窗口并用 processEvents 强刷 X server 的窗口树状。
    listWidget_->viewport()->releaseMouse();
    if (customDragPreviewLabel_) {
        customDragPreviewLabel_->hide();
        customDragPreviewLabel_->deleteLater();
        customDragPreviewLabel_ = nullptr;
    }

    // 强行驱使处理所有的 X11 UnmapNotify，清除悬浮预览从 X server / Wayland 的记录。
    QCoreApplication::processEvents(QEventLoop::ExcludeUserInputEvents);

    const qint64 setupMs = promoteTimer.elapsed();
    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] promote_timing setup=%1ms buttons=%2")
               .arg(setupMs)
               .arg(int(QGuiApplication::mouseButtons()));

    customDragActive_ = false;
    customDragSourceIndices_.clear();
    customDragSourceTab_ = -1;
    customDragPreviewPixmap_ = {};
    customDragHotSpot_ = {};
    customDragStartedMs_ = -1;

    pendingStandardDragQueuedMs_ = QDateTime::currentMSecsSinceEpoch();

    qDebug().noquote()
        << QStringLiteral("[DragDebug][source] standard_dispatch pending=%1 queued_for=0ms(sync)")
               .arg(sourceIndices.size());

    startStandardPlaylistDrag(sourceIndices, previewPixmap, hotSpot);

    customDragPromotingToStandard_ = false;
}

void PlaylistWindow::updateCustomDragIndicators(const QPoint& globalPos)
{
    const QRect windowGlobalRect(mapToGlobal(QPoint(0, 0)), size());
    if (!windowGlobalRect.contains(globalPos)) {
        qDebug().noquote()
            << QStringLiteral("[DragDebug][source] custom_leave_window global=(%1,%2) window=(%3,%4 %5x%6)")
                   .arg(globalPos.x())
                   .arg(globalPos.y())
                   .arg(windowGlobalRect.x())
                   .arg(windowGlobalRect.y())
                   .arg(windowGlobalRect.width())
                   .arg(windowGlobalRect.height());
        promoteCustomDragToStandard(globalPos);
        return;
    }

    // 更新预览位置（偏移 14px 让气泡出现在光标右侧，与 hotSpot 对齐）
    if (customDragPreviewLabel_) {
        customDragPreviewLabel_->move(
            globalPos + QPoint(14, -customDragPreviewLabel_->height() / 2));
    }

    // 判断光标是否在标签面板视口上方
    const QPoint tabsGlobalOrigin =
        playlistTabsWidget_->viewport()->mapToGlobal(QPoint(0, 0));
    const QRect tabsGlobalRect(tabsGlobalOrigin,
                               playlistTabsWidget_->viewport()->size());
    const bool overTabs = tabsGlobalRect.contains(globalPos);

    auto* listDragWidget = static_cast<PlaylistDragListWidget*>(listWidget_);
    auto* tabDropWidget  = static_cast<PlaylistTabDropListWidget*>(playlistTabsWidget_);

    if (overTabs) {
        listDragWidget->setInsertionIndicatorY(-1);
        const QPoint tabsLocalPos =
            playlistTabsWidget_->viewport()->mapFromGlobal(globalPos);
        tabDropWidget->setInsertionIndicatorY(
            dropIndicatorYForTabPosition(tabsLocalPos));
    } else {
        tabDropWidget->setInsertionIndicatorY(-1);
        const QPoint listGlobalOrigin =
            listWidget_->viewport()->mapToGlobal(QPoint(0, 0));
        const QRect listGlobalRect(listGlobalOrigin, listWidget_->viewport()->size());
        const QPoint listLocalPos =
            listWidget_->viewport()->mapFromGlobal(globalPos);
        if (listGlobalRect.contains(globalPos)) {
            // 边缘自动滚动（与 handleListDragMove 保持一致）
            auto* scrollBar = listWidget_->verticalScrollBar();
            if (scrollBar && scrollBar->maximum() > scrollBar->minimum()) {
                constexpr int kEdge = 18;
                int step = 0;
                if (listLocalPos.y() <= kEdge) {
                    step = -2;
                } else if (listLocalPos.y() >= listWidget_->viewport()->height() - kEdge) {
                    step = 2;
                }
                if (step != 0) {
                    scrollBar->setValue(qBound(scrollBar->minimum(),
                                               scrollBar->value() + step,
                                               scrollBar->maximum()));
                }
            }
            listDragWidget->setInsertionIndicatorY(
                dropIndicatorYForListPosition(listLocalPos));
        } else {
            listDragWidget->setInsertionIndicatorY(-1);
        }
    }
}

void PlaylistWindow::finishCustomDrag(const QPoint& globalPos)
{
    auto* listDragWidget = static_cast<PlaylistDragListWidget*>(listWidget_);
    auto* tabDropWidget  = static_cast<PlaylistTabDropListWidget*>(playlistTabsWidget_);
    listDragWidget->setInsertionIndicatorY(-1);
    tabDropWidget->setInsertionIndicatorY(-1);

    listWidget_->viewport()->releaseMouse();
    customDragActive_ = false;

    if (customDragPreviewLabel_) {
        customDragPreviewLabel_->hide();
    }

    // 判断落点位置并执行相应操作
    const QPoint tabsGlobalOrigin =
        playlistTabsWidget_->viewport()->mapToGlobal(QPoint(0, 0));
    const QRect tabsGlobalRect(tabsGlobalOrigin,
                               playlistTabsWidget_->viewport()->size());
    const bool overTabs = tabsGlobalRect.contains(globalPos);

    if (overTabs) {
        const QPoint tabsLocalPos =
            playlistTabsWidget_->viewport()->mapFromGlobal(globalPos);
        const int targetTab = targetTabIndexForPosition(tabsLocalPos);
        if (targetTab >= 0 && targetTab != customDragSourceTab_) {
            moveRowsToTab(customDragSourceTab_, customDragSourceIndices_, targetTab);
        }
    } else {
        const QPoint listGlobalOrigin =
            listWidget_->viewport()->mapToGlobal(QPoint(0, 0));
        const QRect listGlobalRect(listGlobalOrigin, listWidget_->viewport()->size());
        const QPoint listLocalPos =
            listWidget_->viewport()->mapFromGlobal(globalPos);
        if (listGlobalRect.contains(globalPos)) {
            const int insertIndex = insertionIndexForListPosition(listLocalPos);
            moveRowsWithinActivePlaylist(customDragSourceIndices_, insertIndex);
        }
    }

    customDragSourceIndices_.clear();
    customDragSourceTab_ = -1;
    customDragPreviewPixmap_ = {};
    customDragHotSpot_ = {};
    customDragPromotingToStandard_ = false;
    customDragStartedMs_ = -1;
    pendingStandardDragSourceIndices_.clear();
    pendingStandardDragPreviewPixmap_ = {};
    pendingStandardDragHotSpot_ = {};
    pendingStandardDragQueuedMs_ = -1;
}

void PlaylistWindow::cancelCustomDrag()
{
    if (!customDragActive_) {
        return;
    }
    customDragActive_ = false;
    listWidget_->viewport()->releaseMouse();
    static_cast<PlaylistDragListWidget*>(listWidget_)->setInsertionIndicatorY(-1);
    static_cast<PlaylistTabDropListWidget*>(playlistTabsWidget_)->setInsertionIndicatorY(-1);
    if (customDragPreviewLabel_) {
        customDragPreviewLabel_->hide();
    }
    customDragSourceIndices_.clear();
    customDragSourceTab_ = -1;
    customDragPreviewPixmap_ = {};
    customDragHotSpot_ = {};
    customDragPromotingToStandard_ = false;
    customDragStartedMs_ = -1;
    pendingStandardDragSourceIndices_.clear();
    pendingStandardDragPreviewPixmap_ = {};
    pendingStandardDragHotSpot_ = {};
    pendingStandardDragQueuedMs_ = -1;
}

void PlaylistWindow::handleListDragEnter(QDragEnterEvent* event) {
    const QPoint localPos = event->position().toPoint();
    const QPoint globalPos = listWidget_->viewport()->mapToGlobal(localPos);
    if (!event->mimeData()) {
        logDragDecision("list", "enter_no_mime", localPos, globalPos, event);
        return;
    }
    if (event->mimeData()->hasFormat(QLatin1String(kPlaylistItemMimeType))) {
        static_cast<PlaylistDragListWidget*>(listWidget_)
            ->setInsertionIndicatorY(dropIndicatorYForListPosition(localPos));
        // 使用 acceptProposedAction 而非 setDropAction+accept：
        // setDropAction 内部检查 action 是否在 possibleActions 中，
        // XWayland 下 possibleActions 可能未正确传递，导致静默降级为 IgnoreAction。
        // acceptProposedAction 直接接受源端提议的动作，规避此问题。
        event->acceptProposedAction();
        logDragDecision("list", "enter_playlist", localPos, globalPos, event);
        return;
    }
    if (event->mimeData()->hasUrls()) {
        event->setDropAction(Qt::CopyAction);
        event->accept();
        logDragDecision("list", "enter_urls", localPos, globalPos, event);
        return;
    }
    logDragDecision("list", "enter_reject", localPos, globalPos, event);
}

void PlaylistWindow::handleListDragMove(QDragMoveEvent* event) {
    const QPoint pos = event->position().toPoint();
    const QPoint globalPos = listWidget_->viewport()->mapToGlobal(pos);
    if (!event->mimeData()) {
        logDragDecision("list", "move_no_mime", pos, globalPos, event);
        return;
    }
    if (event->mimeData()->hasFormat(QLatin1String(kPlaylistItemMimeType))) {
        auto* scrollBar = listWidget_->verticalScrollBar();
        if (scrollBar && scrollBar->maximum() > scrollBar->minimum()) {
            const int edgeThreshold = 18;
            int step = 0;
            if (pos.y() <= edgeThreshold) {
                step = -2;
            } else if (pos.y() >= listWidget_->viewport()->height() - edgeThreshold) {
                step = 2;
            }
            if (step != 0) {
                const int oldValue = scrollBar->value();
                const int newValue = qBound(scrollBar->minimum(), oldValue + step, scrollBar->maximum());
                if (newValue != oldValue) {
                    scrollBar->setValue(newValue);
                }
            }
        }
        static_cast<PlaylistDragListWidget*>(listWidget_)
            ->setInsertionIndicatorY(dropIndicatorYForListPosition(pos));
        event->acceptProposedAction();
        logDragDecision("list", "move_playlist", pos, globalPos, event);
        return;
    }
    if (event->mimeData()->hasUrls()) {
        static_cast<PlaylistDragListWidget*>(listWidget_)
            ->setInsertionIndicatorY(dropIndicatorYForListPosition(pos));
        event->setDropAction(Qt::CopyAction);
        event->accept();
        logDragDecision("list", "move_urls", pos, globalPos, event);
        return;
    }
    logDragDecision("list", "move_reject", pos, globalPos, event);
}

void PlaylistWindow::handleListDrop(QDropEvent* event) {
    static_cast<PlaylistDragListWidget*>(listWidget_)->setInsertionIndicatorY(-1);
    const QPoint localPos = event->position().toPoint();
    const QPoint globalPos = listWidget_->viewport()->mapToGlobal(localPos);

    if (!event->mimeData()) {
        logDragDecision("list", "drop_no_mime", localPos, globalPos, event);
        return;
    }

    int sourceTab = -1;
    QList<int> sourceIndices;
    if (decodePlaylistItemMimeData(event->mimeData(), &sourceTab, &sourceIndices) && sourceTab == activeTab_) {
        const int insertIndex = insertionIndexForListPosition(localPos);
        moveRowsWithinActivePlaylist(sourceIndices, insertIndex);
        event->setDropAction(Qt::MoveAction);
        event->accept();
        logDragDecision("list", "drop_playlist", localPos, globalPos, event);
        return;
    }
    if (event->mimeData()->hasUrls()) {
        QStringList droppedPaths;
        for (const QUrl& url : event->mimeData()->urls()) {
            if (url.isLocalFile()) {
                droppedPaths << url.toLocalFile();
            }
        }

        if (!droppedPaths.isEmpty()) {
            const QStringList files = collectImportableAudioFiles(droppedPaths);
            insertFilesWithProgress(files,
                                    insertionIndexForListPosition(localPos),
                                    QStringLiteral("正在导入拖拽内容"));
        }
        event->setDropAction(Qt::CopyAction);
        event->accept();
        logDragDecision("list", "drop_urls", localPos, globalPos, event);
        return;
    }
    logDragDecision("list", "drop_reject", localPos, globalPos, event);
}

void PlaylistWindow::handleTabDragEnter(QDragEnterEvent* event) {
    const QPoint localPos = event->position().toPoint();
    const QPoint globalPos = playlistTabsWidget_->viewport()->mapToGlobal(localPos);
    int sourceTab = -1;
    QList<int> sourceIndices;
    if (decodePlaylistItemMimeData(event->mimeData(), &sourceTab, &sourceIndices) && !sourceIndices.isEmpty()) {
        static_cast<PlaylistTabDropListWidget*>(playlistTabsWidget_)
            ->setInsertionIndicatorY(dropIndicatorYForTabPosition(localPos));
        event->setDropAction(Qt::MoveAction);
        event->accept();
        logDragDecision("tabs", "enter_playlist", localPos, globalPos, event);
        return;
    }
    logDragDecision("tabs", "enter_reject", localPos, globalPos, event);
}

void PlaylistWindow::handleTabDragMove(QDragMoveEvent* event) {
    const QPoint localPos = event->position().toPoint();
    const QPoint globalPos = playlistTabsWidget_->viewport()->mapToGlobal(localPos);
    int sourceTab = -1;
    QList<int> sourceIndices;
    if (decodePlaylistItemMimeData(event->mimeData(), &sourceTab, &sourceIndices) && !sourceIndices.isEmpty()) {
        static_cast<PlaylistTabDropListWidget*>(playlistTabsWidget_)
            ->setInsertionIndicatorY(dropIndicatorYForTabPosition(localPos));
        event->setDropAction(Qt::MoveAction);
        event->accept();
        logDragDecision("tabs", "move_playlist", localPos, globalPos, event);
        return;
    }
    logDragDecision("tabs", "move_reject", localPos, globalPos, event);
}

void PlaylistWindow::handleTabDrop(QDropEvent* event) {
    static_cast<PlaylistTabDropListWidget*>(playlistTabsWidget_)->setInsertionIndicatorY(-1);
    const QPoint localPos = event->position().toPoint();
    const QPoint globalPos = playlistTabsWidget_->viewport()->mapToGlobal(localPos);

    int sourceTab = -1;
    QList<int> sourceIndices;
    if (!decodePlaylistItemMimeData(event->mimeData(), &sourceTab, &sourceIndices) || sourceIndices.isEmpty()) {
        logDragDecision("tabs", "drop_reject", localPos, globalPos, event);
        return;
    }

    const int targetTab = targetTabIndexForPosition(localPos);
    if (targetTab < 0) {
        logDragDecision("tabs", "drop_invalid_tab", localPos, globalPos, event);
        return;
    }

    if (targetTab != sourceTab) {
        moveRowsToTab(sourceTab, sourceIndices, targetTab);
    }
    event->setDropAction(Qt::MoveAction);
    event->accept();
    logDragDecision("tabs", "drop_playlist", localPos, globalPos, event);
}

void PlaylistWindow::moveRowsWithinActivePlaylist(const QList<int>& sourceIndices, int insertIndex) {
    const QList<int> rows = normalizedSourceIndices(sourceIndices);
    if (rows.isEmpty()) {
        return;
    }
    auto* scrollBar = listWidget_->verticalScrollBar();
    const int preservedScrollValue = scrollBar ? scrollBar->value() : 0;

    QVector<PlaylistEntry> entries = playlist_.entries();
    const int originalCount = entries.size();
    const int boundedInsertIndex = qBound(0, insertIndex, originalCount);
    const int originalInsertIndex = boundedInsertIndex;
    int adjustedInsertIndex = originalInsertIndex;
    for (int row : rows) {
        if (row < originalInsertIndex) {
            --adjustedInsertIndex;
        }
    }

    if (adjustedInsertIndex == rows.first() && adjustedInsertIndex + rows.size() - 1 == rows.last()) {
        return;
    }

    QVector<PlaylistEntry> movedEntries;
    movedEntries.reserve(rows.size());
    for (int row : rows) {
        if (row >= 0 && row < entries.size()) {
            movedEntries.append(entries[row]);
        }
    }
    if (movedEntries.isEmpty()) {
        return;
    }

    const int oldCurrentIndex = playlist_.currentIndex();
    int newCurrentIndex = oldCurrentIndex;
    const int movedCurrentOffset = rows.indexOf(oldCurrentIndex);

    for (int i = rows.size() - 1; i >= 0; --i) {
        entries.removeAt(rows[i]);
        if (movedCurrentOffset < 0 && oldCurrentIndex > rows[i]) {
            --newCurrentIndex;
        }
    }

    for (int i = 0; i < movedEntries.size(); ++i) {
        entries.insert(adjustedInsertIndex + i, movedEntries[i]);
    }

    if (movedCurrentOffset >= 0) {
        newCurrentIndex = adjustedInsertIndex + movedCurrentOffset;
    } else if (newCurrentIndex >= adjustedInsertIndex) {
        newCurrentIndex += movedEntries.size();
    }

    playlist_.setEntries(std::move(entries));
    playlist_.setCurrentIndex(newCurrentIndex);
    refreshPlaylistView(QStringLiteral("moveRowsWithinActivePlaylist rows=%1 insert=%2 newCurrent=%3")
                            .arg(QStringList([&rows]() {
                                QStringList values;
                                values.reserve(rows.size());
                                for (int row : rows) {
                                    values.append(QString::number(row));
                                }
                                return values;
                            }()).join(QLatin1Char(',')))
                            .arg(insertIndex)
                            .arg(newCurrentIndex));

    QList<int> movedRows;
    movedRows.reserve(movedEntries.size());
    for (int i = 0; i < movedEntries.size(); ++i) {
        movedRows.append(adjustedInsertIndex + i);
    }
    const int preferredFocusSource = !movedRows.isEmpty() ? movedRows.first() : -1;
    restoreSelectionBySourceIndices(movedRows, preferredFocusSource);
    if (scrollBar) {
        markScrollDebugContext(false, QStringLiteral("moveRows_restoreScroll"));
        scrollBar->setValue(qBound(scrollBar->minimum(), preservedScrollValue, scrollBar->maximum()));
    }
    saveActiveTab();
}

void PlaylistWindow::moveRowsToTab(int sourceTab, const QList<int>& sourceIndices, int targetTab) {
    if (sourceTab < 0 || sourceTab >= tabData_.size() ||
        targetTab < 0 || targetTab >= tabData_.size() ||
        sourceTab == targetTab) {
        return;
    }

    saveActiveTab();

    QList<int> rows = normalizedSourceIndices(sourceIndices);
    QVector<PlaylistEntry> movedEntries;
    movedEntries.reserve(rows.size());

    auto& source = tabData_[sourceTab];
    auto& target = tabData_[targetTab];
    for (int row : rows) {
        if (row >= 0 && row < source.entries.size()) {
            movedEntries.append(source.entries[row]);
        }
    }
    if (movedEntries.isEmpty()) {
        return;
    }

    const int oldCurrentIndex = source.currentIndex;
    int newCurrentIndex = oldCurrentIndex;
    const bool movedCurrent = rows.contains(oldCurrentIndex);

    for (int i = rows.size() - 1; i >= 0; --i) {
        const int row = rows[i];
        if (row < 0 || row >= source.entries.size()) {
            continue;
        }
        source.entries.removeAt(row);
        if (!movedCurrent && oldCurrentIndex > row) {
            --newCurrentIndex;
        }
    }

    source.currentIndex = movedCurrent ? -1 : newCurrentIndex;
    const int targetInsertIndex = target.entries.size();
    for (const PlaylistEntry& entry : movedEntries) {
        target.entries.append(entry);
    }

    if (sourceTab == activeTab_) {
        playlist_.clear();
        playlist_.setEntries(source.entries);
        playlist_.setCurrentIndex(source.currentIndex);
        refreshPlaylistView();
        restoreSelectionBySourceIndices({}, source.currentIndex);
    }

}

// 显示添加文件/文件夹的工具栏菜单。
void PlaylistWindow::showAddMenu() {
    QMenu menu(this);
    menu.addAction(QStringLiteral("文件(&F)..."), this, &PlaylistWindow::onAddFiles);
    menu.addAction(QStringLiteral("文件夹(&D)..."), this, &PlaylistWindow::onAddFolder);
    menu.addSeparator();
    menu.addAction(QStringLiteral("添加 URL..."), this, [this]() {
        // TODO：支持通过 URL 添加播放列表项
    });

    // 在第一个工具栏按钮下方弹出
    menu.exec(toolbarMenuAnchor(0));
}

// 显示删除、清空、去重和移除无效文件的工具栏菜单。
void PlaylistWindow::showDeleteMenu() {
    QMenu menu(this);
    menu.addAction(QStringLiteral("从列表删除(&D)"), this, &PlaylistWindow::onRemoveSelected);
    menu.addAction(QStringLiteral("清空列表(&L)"), this, &PlaylistWindow::onClearAll);
    menu.addSeparator();
    menu.addAction(QStringLiteral("删除重复项(&R)"), this, [this]() {
        QSet<QString> seen;
        QList<int> dupes;
        for (int i = 0; i < playlist_.count(); ++i) {
            const QString f = playlist_.fileAt(i).toLower();
            if (seen.contains(f)) dupes.prepend(i);
            else seen.insert(f);
        }
        for (int idx : dupes) playlist_.removeAt(idx);
        refreshPlaylistView();
    });
    menu.addAction(QStringLiteral("删除无效文件(&I)"), this, [this]() {
        QList<int> dead;
        for (int i = 0; i < playlist_.count(); ++i) {
            if (!QFileInfo::exists(playlist_.fileAt(i))) dead.prepend(i);
        }
        for (int idx : dead) playlist_.removeAt(idx);
        refreshPlaylistView();
    });

    menu.exec(toolbarMenuAnchor(1));
}

void PlaylistWindow::showPlaylistMenu() {
    QMenu menu(this);
    menu.addAction(QStringLiteral("定位正在播放(&L)"), this, [this]() {
        const int cur = playlist_.currentIndex();
        if (cur < 0) return;
        for (int i = 0; i < listWidget_->count(); ++i) {
            if (sourceIndexForItem(listWidget_->item(i)) == cur) {
                listWidget_->setCurrentItem(listWidget_->item(i));
                static_cast<StableScrollListWidget*>(listWidget_)->setAutoScrollEnabled(true);
                markScrollDebugContext(false, QStringLiteral("scrollToCurrentTrack"));
                listWidget_->scrollToItem(listWidget_->item(i), QAbstractItemView::PositionAtCenter);
                static_cast<StableScrollListWidget*>(listWidget_)->setAutoScrollEnabled(false);
                break;
            }
        }
    });
    menu.addSeparator();
    menu.addAction(QStringLiteral("新建列表(&N)"), this, [this]() {
        const int n = playlistTabsWidget_->count();
        const QString name = QStringLiteral("新列表 %1").arg(n);
        tabData_.append({name, {}, -1});
        playlistTabsWidget_->addItem(name);
        if (auto* item = playlistTabsWidget_->item(playlistTabsWidget_->count() - 1)) {
            item->setFlags(playlistTabItemFlags(item->flags()));
        }
        playlistTabsWidget_->setCurrentRow(n);
    });
    menu.addAction(QStringLiteral("重命名列表(&R)"), this, [this]() {
        auto* item = playlistTabsWidget_->currentItem();
        if (!item) return;
        item->setFlags(item->flags() | Qt::ItemIsEditable);
        playlistTabsWidget_->editItem(item);
    });
    menu.addAction(QStringLiteral("删除列表(&D)"), this, [this]() {
        if (playlistTabsWidget_->count() <= 1) return;
        const int row = playlistTabsWidget_->currentRow();
        if (row < 0) return;
        if (row == activeTab_) {
            const int newTab = (row > 0) ? row - 1 : row + 1;
            playlistTabsWidget_->setCurrentRow(newTab);
        }
        if (row < tabData_.size()) tabData_.removeAt(row);
        delete playlistTabsWidget_->takeItem(row);
        activeTab_ = playlistTabsWidget_->currentRow();
    });
    menu.exec(toolbarMenuAnchor(2));
}

// 显示排序菜单，支持文件名、标题、路径、随机和反转排序。
void PlaylistWindow::showSortMenu() {
    QMenu menu(this);
    menu.addAction(QStringLiteral("按文件名排序"), this, [this]() {
        QStringList all;
        for (int i = 0; i < playlist_.count(); ++i)
            all << playlist_.fileAt(i);
        all.sort();
        playlist_.clear();
        listWidget_->clear();
        addFiles(all);
    });
    menu.addAction(QStringLiteral("按标题排序"), this, [this]() {
        QVector<QPair<QString,QString>> items;
        for (int i = 0; i < playlist_.count(); ++i)
            items.append({playlist_.displayText(i), playlist_.fileAt(i)});
        std::sort(items.begin(), items.end(),
                  [](const auto& a, const auto& b) { return a.first < b.first; });
        playlist_.clear();
        listWidget_->clear();
        for (const auto& item : items)
            addFile(item.second);
    });
    menu.addAction(QStringLiteral("按路径排序"), this, [this]() {
        QStringList all;
        for (int i = 0; i < playlist_.count(); ++i)
            all << playlist_.fileAt(i);
        all.sort();
        playlist_.clear();
        listWidget_->clear();
        addFiles(all);
    });
    menu.addSeparator();
    menu.addAction(QStringLiteral("随机排序"), this, [this]() {
        QStringList all;
        for (int i = 0; i < playlist_.count(); ++i)
            all << playlist_.fileAt(i);
        for (int i = all.size()-1; i > 0; --i) {
            int j = QRandomGenerator::global()->bounded(i+1);
            all.swapItemsAt(i, j);
        }
        playlist_.clear();
        listWidget_->clear();
        addFiles(all);
    });
    menu.addAction(QStringLiteral("反转排序"), this, [this]() {
        QStringList all;
        for (int i = 0; i < playlist_.count(); ++i)
            all << playlist_.fileAt(i);
        std::reverse(all.begin(), all.end());
        playlist_.clear();
        listWidget_->clear();
        addFiles(all);
    });

    menu.exec(toolbarMenuAnchor(3));
}

// 显示编辑菜单，包括播放、选择反选、上移下移等操作。
void PlaylistWindow::showEditMenu() {
    QMenu menu(this);
    menu.addAction(QStringLiteral("播放选中(&P)"), this, &PlaylistWindow::onPlaySelected);
    menu.addAction(QStringLiteral("文件属性(&I)"), this, &PlaylistWindow::onShowFileProps);
    menu.addSeparator();
    menu.addAction(QStringLiteral("全选(&A)"), this, [this]() {
        listWidget_->selectAll();
    });
    menu.addAction(QStringLiteral("反选(&I)"), this, [this]() {
        for (int i = 0; i < listWidget_->count(); ++i) {
            auto* item = listWidget_->item(i);
            item->setSelected(!item->isSelected());
        }
    });
    menu.addAction(QStringLiteral("取消选择(&N)"), this, [this]() {
        listWidget_->clearSelection();
    });
    menu.addSeparator();
    menu.addAction(QStringLiteral("上移(&U)"), this, [this]() {
        for (auto* item : listWidget_->selectedItems()) {
            int idx = sourceIndexForItem(item);
            if (idx > 0) playlist_.moveUp(idx);
        }
        refreshPlaylistView();
    });
    menu.addAction(QStringLiteral("下移(&D)"), this, [this]() {
        auto sel = listWidget_->selectedItems();
        for (int i = sel.size() - 1; i >= 0; --i) {
            int idx = sourceIndexForItem(sel[i]);
            if (idx >= 0 && idx < playlist_.count() - 1) playlist_.moveDown(idx);
        }
        refreshPlaylistView();
    });
    menu.exec(toolbarMenuAnchor(5));
}

// 显示播放模式菜单，用于切换顺序、单曲循环、列表循环和随机播放。
void PlaylistWindow::showModeMenu() {
    QMenu menu(this);
    populatePlaybackModeMenu(&menu);
    menu.exec(toolbarMenuAnchor(6));
}

void PlaylistWindow::populatePlaybackModeMenu(QMenu* menu) {
    if (!menu) {
        return;
    }
    auto* modeGroup = new QActionGroup(menu);
    modeGroup->setExclusive(true);
    auto addModeAction = [this, menu, modeGroup](const QString& text, int repeatMode, bool shuffle) {
        QAction* action = menu->addAction(text);
        action->setCheckable(true);
        action->setActionGroup(modeGroup);
        action->setChecked(playlist_.repeatMode() == repeatMode && playlist_.isShuffle() == shuffle);
        connect(action, &QAction::triggered, this, [this, repeatMode, shuffle]() {
            setPlaybackMode(repeatMode, shuffle);
        });
    };

    addModeAction(QStringLiteral("顺序播放"), 0, false);
    addModeAction(QStringLiteral("单曲循环"), 1, false);
    addModeAction(QStringLiteral("列表循环"), 2, false);
    addModeAction(QStringLiteral("随机播放"), 2, true);
}

// ---- Toolbar actions ----

// 打开文件选择对话框并添加选中的音频文件。
void PlaylistWindow::onAddFiles() {
    QStringList files;
    if (useFastFileDialogMode()) {
        const QFileDialog::Options dialogOptions =
            QFileDialog::DontUseNativeDialog | QFileDialog::DontUseCustomDirectoryIcons;
        files = QFileDialog::getOpenFileNames(
            this, QStringLiteral("添加文件"), QString(),
            QStringLiteral("音频文件 (*.mp3 *.flac *.ogg *.wav *.aac *.m4a *.wma *.ape *.cue);;所有文件 (*)"),
            nullptr,
            dialogOptions);
    } else {
        files = QFileDialog::getOpenFileNames(
            this, QStringLiteral("添加文件"), QString(),
            QStringLiteral("音频文件 (*.mp3 *.flac *.ogg *.wav *.aac *.m4a *.wma *.ape *.cue);;所有文件 (*)"));
    }

    if (files.isEmpty()) {
        qDebug().noquote() << QStringLiteral("[ImportPerf][PlaylistWindow] onAddFiles cancelled");
        return;
    }

    QElapsedTimer internalTimer;
    internalTimer.start();

    QElapsedTimer importTimer;
    importTimer.start();
    importFilesWithProgress(files, QStringLiteral("正在导入文件"));
    const qint64 importMs = importTimer.elapsed();
    const qint64 internalMs = internalTimer.elapsed();

    qDebug().noquote()
        << QStringLiteral("[ImportPerf][PlaylistWindow] onAddFiles completed count=%1 internal_after_confirm=%2ms import=%3ms")
               .arg(files.size())
               .arg(internalMs)
               .arg(importMs);
}

// 从目录递归扫描音频文件并批量添加到播放列表。
void PlaylistWindow::onAddFolder() {
    QString dir;
    if (useFastFileDialogMode()) {
        const QFileDialog::Options dialogOptions =
            QFileDialog::ShowDirsOnly | QFileDialog::DontUseNativeDialog
            | QFileDialog::DontUseCustomDirectoryIcons;
        dir = QFileDialog::getExistingDirectory(
            this, QStringLiteral("添加文件夹"), QString(), dialogOptions);
    } else {
        dir = QFileDialog::getExistingDirectory(
            this, QStringLiteral("添加文件夹"), QString(), QFileDialog::ShowDirsOnly);
    }
    if (dir.isEmpty()) {
        qDebug().noquote() << QStringLiteral("[ImportPerf][PlaylistWindow] onAddFolder cancelled");
        return;
    }

    QElapsedTimer internalTimer;
    internalTimer.start();

    QElapsedTimer scanTimer;
    scanTimer.start();
    const QStringList files = collectImportableAudioFiles({dir});
    const qint64 scanMs = scanTimer.elapsed();

    QElapsedTimer sortTimer;
    sortTimer.start();
    QStringList sortedFiles = files;
    sortedFiles.sort();
    const qint64 sortMs = sortTimer.elapsed();

    QElapsedTimer importTimer;
    importTimer.start();
    importFilesWithProgress(sortedFiles, QStringLiteral("正在导入文件夹"));
    const qint64 importMs = importTimer.elapsed();
    const qint64 internalMs = internalTimer.elapsed();

    qDebug().noquote()
        << QStringLiteral("[ImportPerf][PlaylistWindow] onAddFolder completed dir=\"%1\" count=%2 internal_after_confirm=%3ms scan=%4ms sort=%5ms import=%6ms")
               .arg(dir)
               .arg(sortedFiles.size())
               .arg(internalMs)
               .arg(scanMs)
               .arg(sortMs)
               .arg(importMs);
}

// 删除当前选中的列表项。
void PlaylistWindow::onRemoveSelected() {
    QList<int> rows;
    for (auto* item : listWidget_->selectedItems()) {
        const int sourceIndex = sourceIndexForItem(item);
        if (sourceIndex >= 0) {
            rows.prepend(sourceIndex);
        }
    }
    std::sort(rows.rbegin(), rows.rend());
    for (int row : rows) {
        playlist_.removeAt(row);
    }
    refreshPlaylistView();
}

void PlaylistWindow::onClearAll() {
    playlist_.clear();
    refreshPlaylistView();
}

void PlaylistWindow::onPlaySelected() {
    int row = sourceIndexForItem(listWidget_->currentItem());
    if (row >= 0 && row < playlist_.count()) {
        playlist_.setCurrentIndex(row);
        const QString selectedPath = playlist_.currentFile();
        lastUserSwitchRequestMs_ = QDateTime::currentMSecsSinceEpoch();
        lastUserSwitchPath_ = selectedPath;
        lastUserSwitchFromDoubleClick_ = false;
        emit fileSelected(selectedPath);
    }
}

void PlaylistWindow::onShowFileProps() {
    int row = sourceIndexForItem(listWidget_->currentItem());
    if (row < 0 || row >= playlist_.count()) return;

    const PlaylistEntry& entry = playlist_.at(row);
    const QFileInfo fi(entry.filePath);

    // 格式化时长
    const int totalSec = static_cast<int>(qMax<int64_t>(0, entry.durationMs) / 1000);
    const int h = totalSec / 3600, mm = (totalSec / 60) % 60, ss = totalSec % 60;
    const QString durStr = (totalSec > 0)
        ? (h > 0 ? QStringLiteral("%1:%2:%3").arg(h).arg(mm, 2, 10, QChar('0')).arg(ss, 2, 10, QChar('0'))
                 : QStringLiteral("%1:%2").arg(mm, 2, 10, QChar('0')).arg(ss, 2, 10, QChar('0')))
        : QStringLiteral("（未知）");

    // 格式化文件大小
    const qint64 bytes = fi.size();
    const QString sizeStr = fi.exists()
        ? (bytes >= 1024 * 1024
            ? QStringLiteral("%1 MB（%2 字节）").arg(bytes / (1024.0 * 1024.0), 0, 'f', 2).arg(bytes)
            : QStringLiteral("%1 KB（%2 字节）").arg(bytes / 1024.0, 0, 'f', 1).arg(bytes))
        : QStringLiteral("（文件不存在）");

    QDialog dlg(this);
    dlg.setWindowTitle(QStringLiteral("文件属性"));
    dlg.setMinimumWidth(520);
    auto* layout = new QVBoxLayout(&dlg);
    auto* form = new QFormLayout;
    form->setLabelAlignment(Qt::AlignRight);

    auto addRow = [&](const QString& label, const QString& value) {
        auto* edit = new QLineEdit(value);
        edit->setReadOnly(true);
        form->addRow(label, edit);
    };

    addRow(QStringLiteral("标题："),
           entry.title.isEmpty() ? QStringLiteral("（未知）") : entry.title);
    addRow(QStringLiteral("艺术家："),
           entry.artist.isEmpty() ? QStringLiteral("（未知）") : entry.artist);
    addRow(QStringLiteral("专辑："),
           entry.album.isEmpty() ? QStringLiteral("（未知）") : entry.album);
    addRow(QStringLiteral("时长："), durStr);
    form->addRow(new QLabel);
    addRow(QStringLiteral("文件名："), fi.fileName());
    addRow(QStringLiteral("路径："), fi.absoluteFilePath());
    addRow(QStringLiteral("大小："), sizeStr);
    addRow(QStringLiteral("格式："), fi.suffix().toUpper());
    addRow(QStringLiteral("修改时间："),
           fi.exists() ? fi.lastModified().toString(QStringLiteral("yyyy-MM-dd hh:mm:ss")) : QString());
    form->addRow(new QLabel);
    auto* statusLabel = new QLabel(
        entry.metadataLoaded ? QStringLiteral("<i>元数据已完整加载</i>")
                             : QStringLiteral("<i>元数据加载中……</i>"));
    form->addRow(statusLabel);

    layout->addLayout(form);
    auto* btnBox = new QDialogButtonBox(QDialogButtonBox::Ok);
    connect(btnBox, &QDialogButtonBox::accepted, &dlg, &QDialog::accept);
    layout->addWidget(btnBox);
    dlg.exec();
}

void PlaylistWindow::showListContextMenu(const QPoint& pos) {
    QMenu menu(this);
    menu.addAction(QStringLiteral("播放(&P)"),    this, &PlaylistWindow::onPlaySelected);
    menu.addSeparator();

    // 添加子菜单（模拟原版）
    QMenu* addMenu = menu.addMenu(QStringLiteral("添加(&A)"));
    addMenu->addAction(QStringLiteral("文件(&F)..."),    this, &PlaylistWindow::onAddFiles);
    addMenu->addAction(QStringLiteral("文件夹(&D)..."),  this, &PlaylistWindow::onAddFolder);

    menu.addSeparator();
    menu.addAction(QStringLiteral("从列表删除(&D)"),   this, &PlaylistWindow::onRemoveSelected);
    menu.addSeparator();
    menu.addAction(QStringLiteral("清空列表(&L)"),   this, &PlaylistWindow::onClearAll);
    if (!filterText_.isEmpty()) {
        menu.addAction(QStringLiteral("清除搜索(&F)"), this, [this]() {
            searchEdit_->clear();
        });
    }
    menu.addSeparator();

    QMenu* sortMenu = menu.addMenu(QStringLiteral("排序(&S)"));
    sortMenu->addAction(QStringLiteral("按文件名排序"), this, [this]() {
        QStringList all;
        for (int i = 0; i < playlist_.count(); ++i)
            all << playlist_.fileAt(i);
        all.sort();
        playlist_.clear();
        listWidget_->clear();
        addFiles(all);
    });
    sortMenu->addAction(QStringLiteral("按标题排序"), this, [this]() {
        QVector<QPair<QString,QString>> items;
        for (int i = 0; i < playlist_.count(); ++i)
            items.append({playlist_.displayText(i), playlist_.fileAt(i)});
        std::sort(items.begin(), items.end(),
                  [](const auto& a, const auto& b) { return a.first < b.first; });
        playlist_.clear();
        listWidget_->clear();
        for (const auto& item : items)
            addFile(item.second);
    });
    sortMenu->addAction(QStringLiteral("随机排序"), this, [this]() {
        QStringList all;
        for (int i = 0; i < playlist_.count(); ++i)
            all << playlist_.fileAt(i);
        // Fisher-Yates 洗牌算法
        for (int i = all.size()-1; i > 0; --i) {
            int j = QRandomGenerator::global()->bounded(i+1);
            all.swapItemsAt(i, j);
        }
        playlist_.clear();
        listWidget_->clear();
        addFiles(all);
    });
    sortMenu->addAction(QStringLiteral("反转排序"), this, [this]() {
        QStringList all;
        for (int i = 0; i < playlist_.count(); ++i)
            all << playlist_.fileAt(i);
        std::reverse(all.begin(), all.end());
        playlist_.clear();
        listWidget_->clear();
        addFiles(all);
    });

    menu.addSeparator();

    // 播放模式子菜单
    QMenu* modeMenu = menu.addMenu(QStringLiteral("播放模式(&M)"));
    populatePlaybackModeMenu(modeMenu);

    menu.addSeparator();
    menu.addAction(QStringLiteral("文件属性(&I)"), this, &PlaylistWindow::onShowFileProps);

    menu.exec(listWidget_->mapToGlobal(pos));
}

// ---- Paint & Mouse ----

// 绘制窗口背景、工具栏按钮、分割条以及列表区域的视觉元素。
void PlaylistWindow::paintEvent(QPaintEvent*) {
    QPainter p(this);
    if (!background_.isNull()) {
        p.drawPixmap(0, 0, background_);
    } else {
        p.fillRect(rect(), colorBkgnd_);
        p.setPen(colorText_);
        p.drawText(QRect(8, 2, width()-16, 18), Qt::AlignLeft|Qt::AlignVCenter,
                   QStringLiteral("播放列表"));
    }

    if (!titleElement_.statePixmaps[0].isNull()) {
        p.drawPixmap(titleDrawRect().topLeft(), titleElement_.statePixmaps[0]);
    }

    const QRect toolbarRect = toolbarAreaRect();
    if (!toolbarElement_.statePixmaps[0].isNull() && !toolbarRect.isEmpty()) {
        const QPixmap& normalSheet = toolbarElement_.statePixmaps[0];
        for (int group = 0; group < kToolbarGroupCount; ++group) {
            const QRect groupRect = toolbarGroupRect(group);
            if (groupRect.isEmpty()) {
                continue;
            }

            const int srcLeft = (normalSheet.width() * group) / kToolbarGroupCount;
            const int srcRight = (normalSheet.width() * (group + 1)) / kToolbarGroupCount;
            const QRect normalSrc(srcLeft, 0, qMax(1, srcRight - srcLeft), normalSheet.height());
            const bool hovered = hoveredToolbarGroup_ == group;
            const bool pressed = pressedToolbarGroup_ == group;
            QRect drawRect = toolbarGroupDrawRect(group, normalSheet);

            p.save();
            p.setClipRect(groupRect);
            if (!toolbarElement_.hotPixmap.isNull()) {
                const QPixmap& activeSheet = (hovered || pressed) ? toolbarElement_.hotPixmap : normalSheet;
                drawRect = toolbarGroupDrawRect(group, activeSheet);
                if (pressed) {
                    drawRect.translate(1, 1);
                }
                const int activeLeft = (activeSheet.width() * group) / kToolbarGroupCount;
                const int activeRight = (activeSheet.width() * (group + 1)) / kToolbarGroupCount;
                const QRect activeSrc(activeLeft, 0, qMax(1, activeRight - activeLeft), activeSheet.height());
                p.drawPixmap(drawRect, activeSheet, activeSrc);
            } else {
                if (hovered && !pressed) {
                    drawRect.translate(-1, -1);
                } else if (pressed) {
                    drawRect.translate(1, 1);
                }
                p.drawPixmap(drawRect, normalSheet, normalSrc);
            }
            p.restore();
        }
    } else if (!toolbarRect.isEmpty()) {
        static const QStringList kFallbackLabels = {
            QStringLiteral("添加"),
            QStringLiteral("删除"),
            QStringLiteral("列表"),
            QStringLiteral("排序"),
            QStringLiteral("查找"),
            QStringLiteral("编辑"),
            QStringLiteral("模式"),
        };
        QFont font = listWidget_->font();
        font.setBold(true);
        font.setPixelSize(qMax(11, toolbarRect.height() - 6));
        p.setFont(font);
        for (int group = 0; group < kToolbarGroupCount; ++group) {
            const QRect dst = toolbarGroupRect(group);
            if (dst.isEmpty()) {
                continue;
            }
            const bool hovered = hoveredToolbarGroup_ == group;
            const bool pressed = pressedToolbarGroup_ == group;
            QRect textRect = dst;
            if (hovered && !pressed) {
                textRect.translate(-1, -1);
            }
            p.setPen(Qt::black);
            p.drawText(textRect, Qt::AlignCenter, kFallbackLabels.value(group));
        }
    }

    // 绘制可拖拽分割条
    if (!isDividerCollapsed()) {
        const QRect dividerRect = dividerVisualRect();
        drawSplitterBar(p, dividerRect, splitterFrontColor_, splitterBackColor_);
        drawSplitterArrow(p, dividerRect, splitterFrontColor_, false);
    } else if (dividerSavedPos_ > 0) {
        // 收起时在左侧绘制小展开指示条
        const QRect dividerRect = dividerVisualRect();
        drawSplitterBar(p, dividerRect, splitterFrontColor_, splitterBackColor_);
        drawSplitterArrow(p, dividerRect, splitterFrontColor_, true);
    }
}

void PlaylistWindow::contextMenuEvent(QContextMenuEvent* e) {
    if (e->pos().y() < playlistRect().top()) {
        QMenu menu(this);
        menu.addAction(QStringLiteral("添加文件(&A)..."),  this, &PlaylistWindow::onAddFiles);
        menu.addAction(QStringLiteral("添加文件夹(&F)..."),this, &PlaylistWindow::onAddFolder);
        if (!filterText_.isEmpty()) {
            menu.addAction(QStringLiteral("清除搜索(&S)"), this, [this]() {
                searchEdit_->clear();
            });
        }
        menu.addSeparator();
        menu.addAction(QStringLiteral("清空列表(&L)"), this, &PlaylistWindow::onClearAll);
        menu.exec(e->globalPos());
    }
}

// 处理鼠标按下事件，包括工具栏按钮点击、列表分隔条拖动、窗口拖拽和调整大小。
void PlaylistWindow::mousePressEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton) {
        const int toolbarGroup = toolbarGroupIndexAt(e->position().toPoint());
        if (toolbarGroup >= 0) {
            pressedToolbarGroup_ = toolbarGroup;
            update();
            e->accept();
            return;
        }

        // 分割条拖拽 / 展开
        if (dividerSavedPos_ > 0 && dividerHotZoneRect().contains(e->position().toPoint())) {
            dividerDragging_ = true;
            dividerHandlePressed_ = dividerHandleRect().contains(e->position().toPoint());
            dividerDragStartX_ = e->position().x();
            e->accept();
            return;
        }

        resizeEdges_ = resizeEdgesForPosition(e->position().toPoint());
        if (resizeEdges_ != Qt::Edges()) {
            resizeStartGlobalPos_ = e->globalPosition().toPoint();
            resizeStartSize_ = size();
            e->accept();
            return;
        }

        if (e->position().y() < playlistRect().top()) {
            dragSessionActive_ = true;
            emit dragStarted();
            dragUsingSystemMove_ = false;
            lastMoveEventObserved_ = false;
            lastWindowMovedEmitMs_ = 0;
            const bool useSystemMove =
                !shouldPreferManualMove() && windowHandle() && windowHandle()->startSystemMove();
            dragUsingSystemMove_ = useSystemMove;
            movePerf_.beginSession(useSystemMove ? QStringLiteral("system") : QStringLiteral("manual"),
                                   pos(),
                                   playbackStateText(engine_));
            if (useSystemMove) {
                e->accept();
                return;
            }
            dragging_ = true;
            dragStart_ = e->globalPosition().toPoint() - pos();
            e->accept();
            return;
        }
    }
    QWidget::mousePressEvent(e);
}

void PlaylistWindow::mouseDoubleClickEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton &&
        dividerSavedPos_ > 0 &&
        dividerHotZoneRect().contains(e->position().toPoint())) {
        dividerDragging_ = false;
        dividerHandlePressed_ = false;
        toggleDividerCollapsed();
        unsetCursor();
        e->accept();
        return;
    }
    QWidget::mouseDoubleClickEvent(e);
}

void PlaylistWindow::mouseMoveEvent(QMouseEvent* e) {
    const int hoverGroup = toolbarGroupIndexAt(e->position().toPoint());
    if (hoverGroup != hoveredToolbarGroup_) {
        hoveredToolbarGroup_ = hoverGroup;
        update();
    }
    if (dividerDragging_) {
        const QRect plRect = playlistRect();
        int newPos = e->position().x() - plRect.x();
        newPos = qBound(0, newPos, plRect.width() - 40);
        if (newPos != dividerPos_) {
            dividerPos_ = newPos;
            updateListGeometry();
            update();
        }
        e->accept();
        return;
    }
    if (resizeEdges_ != Qt::Edges()) {
        const QPoint delta = e->globalPosition().toPoint() - resizeStartGlobalPos_;
        int newWidth = resizeStartSize_.width();
        int newHeight = resizeStartSize_.height();
        if (resizeEdges_.testFlag(Qt::RightEdge)) {
            newWidth += delta.x();
        }
        if (resizeEdges_.testFlag(Qt::BottomEdge)) {
            newHeight += delta.y();
        }
        resize(qMax(minimumWidth(), newWidth), qMax(minimumHeight(), newHeight));
        emit resizeInProgress(resizeEdges_);
    } else if (dragging_) {
        const QPoint fromPos = pos();
        const QPoint targetPos = e->globalPosition().toPoint() - dragStart_;
        if (targetPos != fromPos) {
            lastMoveEventObserved_ = false;
            lastWindowMovedEmitMs_ = 0;

            QElapsedTimer timer;
            timer.start();
            move(targetPos);
            movePerf_.noteMoveRequest(fromPos,
                                      pos(),
                                      timer.elapsed(),
                                      lastMoveEventObserved_ ? lastWindowMovedEmitMs_ : 0);
        }
    } else {
        const Qt::Edges edges = resizeEdgesForPosition(e->position().toPoint());
        if (edges == (Qt::RightEdge | Qt::BottomEdge)) {
            setCursor(Qt::SizeFDiagCursor);
        } else if (edges == Qt::RightEdge) {
            setCursor(Qt::SizeHorCursor);
        } else if (edges == Qt::BottomEdge) {
            setCursor(Qt::SizeVerCursor);
        } else {
            // 分割条悬停光标
            const QPoint pos = e->position().toPoint();
            if (dividerSavedPos_ > 0 && dividerHandleRect().contains(pos)) {
                setCursor(Qt::PointingHandCursor);
            } else if (dividerSavedPos_ > 0 && dividerHotZoneRect().contains(pos)) {
                setCursor(Qt::SplitHCursor);
            } else if (hoverGroup >= 0) {
                setCursor(Qt::PointingHandCursor);
            } else {
                unsetCursor();
            }
        }
    }
    QWidget::mouseMoveEvent(e);
}

void PlaylistWindow::mouseReleaseEvent(QMouseEvent* e) {
    if (e->button() == Qt::LeftButton && dividerDragging_) {
        const bool wasDrag = qAbs(e->position().x() - dividerDragStartX_) > 3;
        dividerDragging_ = false;
        if (wasDrag) {
            if (dividerPos_ <= kDividerCollapseThreshold) {
                dividerPos_ = 0;
            } else {
                dividerSavedPos_ = dividerPos_;
            }
            updateListGeometry();
            update();
        } else if (dividerHandlePressed_ && dividerHandleRect().contains(e->position().toPoint())) {
            toggleDividerCollapsed();
        }
        dividerHandlePressed_ = false;
        unsetCursor();
        e->accept();
        return;
    }
    if (e->button() == Qt::LeftButton && pressedToolbarGroup_ >= 0) {
        const int releasedGroup = toolbarGroupIndexAt(e->position().toPoint());
        const int group = pressedToolbarGroup_;
        pressedToolbarGroup_ = -1;
        update();

        if (releasedGroup >= 0 && releasedGroup == group) {
            switch (group) {
            case 0:
                showAddMenu();
                break;
            case 1:
                showDeleteMenu();
                break;
            case 2:
                showPlaylistMenu();
                break;
            case 3:
                showSortMenu();
                break;
            case 4:
                showSearchDialog();
                break;
            case 5:
                showEditMenu();
                break;
            case 6:
                showModeMenu();
                break;
            default: break;
            }
        }
        e->accept();
        return;
    }
    const Qt::Edges resizeEdges = resizeEdges_;
    resizeEdges_ = {};
    dragging_ = false;
    if (e->button() == Qt::LeftButton && resizeEdges != Qt::Edges()) {
        emit resizeFinished(resizeEdges);
    }
    if (e->button() == Qt::LeftButton && dragSessionActive_) {
        dragSessionActive_ = false;
        emit dragFinished();
        movePerf_.endSession(pos(), QStringLiteral("mouse_release"));
    }
    if (e->button() == Qt::LeftButton) {
        dragUsingSystemMove_ = false;
        lastMoveEventObserved_ = false;
        lastWindowMovedEmitMs_ = 0;
    }
    QWidget::mouseReleaseEvent(e);
}

void PlaylistWindow::leaveEvent(QEvent* e) {
    if (!dividerDragging_ && !dragging_ && resizeEdges_ == Qt::Edges()) {
        unsetCursor();
    }
    QWidget::leaveEvent(e);
}

void PlaylistWindow::moveEvent(QMoveEvent* e) {
    QWidget::moveEvent(e);
    const QPoint delta = e->pos() - e->oldPos();
    if (!delta.isNull()) {
        QElapsedTimer timer;
        timer.start();
        emit windowMoved(delta);
        lastMoveEventObserved_ = true;
        lastWindowMovedEmitMs_ = timer.elapsed();
        if (movePerf_.active()) {
            movePerf_.noteMoveEvent(e->oldPos(),
                                    e->pos(),
                                    delta,
                                    lastWindowMovedEmitMs_,
                                    dragUsingSystemMove_);
        }
    }
}

void PlaylistWindow::showEvent(QShowEvent* e) {
    QWidget::showEvent(e);
    emit visibilityChanged(true);
}

void PlaylistWindow::hideEvent(QHideEvent* e) {
    QWidget::hideEvent(e);
    emit visibilityChanged(false);
}

void PlaylistWindow::resizeEvent(QResizeEvent* e) {
    QWidget::resizeEvent(e);
    rebuildBackground();
    updateChromeGeometry();
    updateListGeometry();
}

void PlaylistWindow::dragEnterEvent(QDragEnterEvent* e) {
    const QPoint localPos = e->position().toPoint();
    const QPoint globalPos = mapToGlobal(localPos);
    if (e->mimeData()->hasFormat(QLatin1String(kPlaylistItemMimeType))) {
        e->acceptProposedAction();
        logDragDecision("root", "enter_playlist", localPos, globalPos, e);
        return;
    }
    if (e->mimeData()->hasUrls()) {
        e->setDropAction(Qt::CopyAction);
        e->accept();
        logDragDecision("root", "enter_urls", localPos, globalPos, e);
        return;
    }
    logDragDecision("root", "enter_reject", localPos, globalPos, e);
}

void PlaylistWindow::dragMoveEvent(QDragMoveEvent* e) {
    const QPoint localPos = e->position().toPoint();
    const QPoint globalPos = mapToGlobal(localPos);
    if (e->mimeData()->hasFormat(QLatin1String(kPlaylistItemMimeType))) {
        e->acceptProposedAction();
        logDragDecision("root", "move_playlist", localPos, globalPos, e);
        return;
    }
    if (e->mimeData()->hasUrls()) {
        e->setDropAction(Qt::CopyAction);
        e->accept();
        logDragDecision("root", "move_urls", localPos, globalPos, e);
        return;
    }
    logDragDecision("root", "move_reject", localPos, globalPos, e);
}

void PlaylistWindow::dropEvent(QDropEvent* e) {
    const QPoint localPos = e->position().toPoint();
    const QPoint globalPos = mapToGlobal(localPos);
    QStringList droppedPaths;
    for (const QUrl& url : e->mimeData()->urls()) {
        if (url.isLocalFile()) {
            droppedPaths << url.toLocalFile();
        }
    }

    if (!droppedPaths.isEmpty()) {
        QElapsedTimer internalTimer;
        internalTimer.start();

        QElapsedTimer scanTimer;
        scanTimer.start();
        QStringList files = collectImportableAudioFiles(droppedPaths);
        const qint64 scanMs = scanTimer.elapsed();

        QElapsedTimer sortTimer;
        sortTimer.start();
        files.sort();
        const qint64 sortMs = sortTimer.elapsed();

        QElapsedTimer importTimer;
        importTimer.start();
        importFilesWithProgress(files, QStringLiteral("正在导入拖拽内容"));
        const qint64 importMs = importTimer.elapsed();
        const qint64 internalMs = internalTimer.elapsed();

        qDebug().noquote()
            << QStringLiteral("[ImportPerf][PlaylistWindow] onDropImport completed source_count=%1 count=%2 internal_after_confirm=%3ms scan=%4ms sort=%5ms import=%6ms")
                   .arg(droppedPaths.size())
                   .arg(files.size())
                   .arg(internalMs)
                   .arg(scanMs)
                   .arg(sortMs)
                   .arg(importMs);
    }

    e->acceptProposedAction();
    logDragDecision("root", "drop", localPos, globalPos, e);
}

// ============================================================
//  TTBL 加载 / 保存 / 后台元数据加载器
// ============================================================

// 快速从 TTBL 加载路径和 TTBL 内嵌标题，然后启动后台元数据加载器。
void PlaylistWindow::loadFromTtblDir(const QString& dir, int count, int activeList) {
    // 停止所有现有加载器
    for (auto* loader : metadataLoaders_) {
        if (loader) {
            loader->cancel();
            loader->deleteLater();
        }
    }
    metadataLoaders_.clear();

    // 清空现有标签页，从文件重建
    playlist_.clear();
    tabData_.clear();
    while (playlistTabsWidget_->count() > 0)
        delete playlistTabsWidget_->takeItem(0);

    TtblParser parser;
    const int actualCount = qMax(1, count);

    for (int t = 0; t < actualCount; ++t) {
        const QString filePath = QDir(dir).absoluteFilePath(
            QStringLiteral("%1.ttbl").arg(t, 4, 10, QChar('0')));

        TtblHeader header;
        QVector<TtblEntry> parsed = QFileInfo::exists(filePath)
            ? parser.parse(filePath, &header)
            : QVector<TtblEntry>{};

        // 将解析结果转换为 PlaylistEntry（只有路径和 TTBL 内嵌标题）
        QVector<PlaylistEntry> entries;
        entries.reserve(parsed.size());
        for (const TtblEntry& te : parsed) {
            PlaylistEntry pe;
            pe.filePath = te.filePath;
            pe.title    = te.title.isEmpty()
                            ? QFileInfo(te.filePath).completeBaseName()
                            : cleanTtblTitle(te.title);
            pe.durationMs      = te.durationMs;
            pe.metadataLoaded  = false;  // 后台加载后会更新
            entries.append(pe);
        }

        const QString tabName = header.listName.isEmpty()
            ? (t == 0 ? QStringLiteral("[默认]") : QStringLiteral("[%1]").arg(t))
            : header.listName;

        tabData_.append({tabName, entries, header.currentIndex});
        playlistTabsWidget_->addItem(tabName);
        if (auto* item = playlistTabsWidget_->item(playlistTabsWidget_->count() - 1)) {
            item->setFlags(playlistTabItemFlags(item->flags()));
        }

        qDebug().noquote()
            << QStringLiteral("[TtblLoad] tab=%1 name=%2 entries=%3 file=%4")
                   .arg(t).arg(tabName).arg(entries.size()).arg(filePath);
    }

    // 若无任何标签页，添加默认空列表
    if (tabData_.isEmpty()) {
        tabData_.append({QStringLiteral("[默认]"), {}, -1});
        playlistTabsWidget_->addItem(QStringLiteral("[默认]"));
        if (auto* item = playlistTabsWidget_->item(playlistTabsWidget_->count() - 1)) {
            item->setFlags(playlistTabItemFlags(item->flags()));
        }
    }

    // 激活指定标签页
    activeTab_ = qBound(0, activeList, tabData_.size() - 1);
    playlistTabsWidget_->setCurrentRow(activeTab_);
    playlist_.clear();
    playlist_.setEntries(tabData_[activeTab_].entries);
    playlist_.setCurrentIndex(tabData_[activeTab_].currentIndex);
    refreshPlaylistView();

    // 为每个标签页启动后台元数据加载器
    metadataLoaders_.resize(tabData_.size(), nullptr);
    for (int t = 0; t < tabData_.size(); ++t) {
        if (!tabData_[t].entries.isEmpty()) {
            startMetadataLoaderForTab(t);
        }
    }
}

// 启动指定标签页的后台元数据加载器。
void PlaylistWindow::startMetadataLoaderForTab(int tabIndex) {
    if (tabIndex < 0 || tabIndex >= tabData_.size()) return;

    // 如果已有加载器，先取消旧的
    if (tabIndex < metadataLoaders_.size() && metadataLoaders_[tabIndex]) {
        metadataLoaders_[tabIndex]->cancel();
        metadataLoaders_[tabIndex]->deleteLater();
        metadataLoaders_[tabIndex] = nullptr;
    }

    // 确保容器足够大
    while (metadataLoaders_.size() <= tabIndex)
        metadataLoaders_.append(nullptr);

    QVector<QString> paths;
    paths.reserve(tabData_[tabIndex].entries.size());
    for (const PlaylistEntry& e : tabData_[tabIndex].entries)
        paths.append(e.filePath);

    auto* loader = new PlaylistMetadataLoader(this);
    metadataLoaders_[tabIndex] = loader;

    const int capturedTabIndex = tabIndex;

    // 连接元数据就绪信号（跨线程：Qt 自动使用队列连接）
    connect(loader, &PlaylistMetadataLoader::metadataReady,
            this, [this, capturedTabIndex](int idx, const QString& filePath,
                                           const QString& title,
                                           const QString& artist, const QString& album,
                                           qint64 durationMs) {
        onMetadataReady(capturedTabIndex, idx, filePath, title, artist, album, durationMs);
    }, Qt::QueuedConnection);

    connect(loader, &PlaylistMetadataLoader::allMetadataLoaded,
            this, [this, capturedTabIndex](int loadedCount, qint64 elapsedMs) {
        qDebug().noquote()
            << QStringLiteral("[TtblLoad] tab=%1 metadata all loaded: %2/%2 elapsed=%3ms")
                   .arg(capturedTabIndex).arg(loadedCount).arg(elapsedMs);
    }, Qt::QueuedConnection);

    loader->startLoading(paths);
    qDebug().noquote()
        << QStringLiteral("[TtblLoad] started metadata loader for tab=%1 paths=%2")
               .arg(tabIndex).arg(paths.size());
}

// 当某首曲目的元数据加载完成时，更新 tabData_ 和当前展示的列表。
// 此槽在主线程中运行（via 队列连接）。
void PlaylistWindow::onMetadataReady(int tabIndex, int entryIndex,
                                      const QString& filePath,
                                      const QString& title, const QString& artist,
                                      const QString& album, qint64 durationMs) {
    if (tabIndex < 0 || tabIndex >= tabData_.size()) return;
    const auto resolveEntryIndex = [](const QVector<PlaylistEntry>& entries,
                                      int preferredIndex,
                                      const QString& preferredPath) {
        if (preferredIndex >= 0 && preferredIndex < entries.size() &&
            entries[preferredIndex].filePath == preferredPath) {
            return preferredIndex;
        }
        for (int index = 0; index < entries.size(); ++index) {
            if (entries[index].filePath == preferredPath) {
                return index;
            }
        }
        return -1;
    };

    const int resolvedEntryIndex = resolveEntryIndex(tabData_[tabIndex].entries, entryIndex, filePath);
    if (resolvedEntryIndex < 0) {
        qDebug().noquote()
            << QStringLiteral("[TtblLoad] ignore stale metadata tab=%1 index=%2 path=\"%3\"")
                   .arg(tabIndex)
                   .arg(entryIndex)
                   .arg(filePath);
        return;
    }

    if (resolvedEntryIndex != entryIndex) {
        qDebug().noquote()
            << QStringLiteral("[TtblLoad] remap metadata tab=%1 old_index=%2 new_index=%3 path=\"%4\"")
                   .arg(tabIndex)
                   .arg(entryIndex)
                   .arg(resolvedEntryIndex)
                   .arg(filePath);
    }

    PlaylistEntry& entry = tabData_[tabIndex].entries[resolvedEntryIndex];
    // 若元数据标题为空，保留 TTBL 内嵌标题（回退策略）
    if (!title.isEmpty())  entry.title  = title;
    if (!artist.isEmpty()) entry.artist = artist;
    if (!album.isEmpty())  entry.album  = album;
    if (durationMs > 0)    entry.durationMs = durationMs;
    entry.metadataLoaded = true;

    // 若当前标签页正是这个标签，同步更新 playlist_ 并刷新视图
    if (tabIndex == activeTab_) {
        const int activeEntryIndex = resolveEntryIndex(playlist_.entries(), resolvedEntryIndex, filePath);
        if (activeEntryIndex >= 0) {
            PlaylistEntry& active = playlist_.at(activeEntryIndex);
            if (!title.isEmpty())  active.title  = title;
            if (!artist.isEmpty()) active.artist = artist;
            if (!album.isEmpty())  active.album  = album;
            if (durationMs > 0)    active.durationMs = durationMs;
            active.metadataLoaded = true;
        }
        if (activeEntryIndex >= 0) {
            if (QListWidgetItem* item = findVisibleItemBySource(activeEntryIndex)) {
                const PlaylistEntry& e = playlist_.at(activeEntryIndex);
                item->setData(TitleRole, displayTitleForEntry(e));
                item->setData(DurationRole, displayDurationForEntry(e));
            }
        }
    }
}

// 请求立即加载指定标签页和索引的元数据（即将播放时调用）。
void PlaylistWindow::requestPriorityMetadata(int tabIndex, int entryIndex) {
    if (tabIndex < 0 || tabIndex >= metadataLoaders_.size()) return;
    auto* loader = metadataLoaders_[tabIndex];
    if (!loader) return;
    if (tabIndex >= tabData_.size() ||
        entryIndex < 0 ||
        entryIndex >= tabData_[tabIndex].entries.size()) {
        return;
    }

    const QString filePath = tabData_[tabIndex].entries[entryIndex].filePath;
    if (filePath.isEmpty()) {
        return;
    }
    loader->requestPriorityForPath(filePath);
}

// 将所有标签页的播放列表保存到指定目录，文件名为 0000.ttbl, 0001.ttbl ...
// 返回当前活动标签页的索引。
int PlaylistWindow::saveToTtblDir(const QString& dir) const {
    // 先更新当前标签的快照（const 方法中使用 const_cast 是安全的，因为不影响外部可见状态）
    auto* self = const_cast<PlaylistWindow*>(this);
    self->saveActiveTab();

    TtblWriter writer;
    for (int t = 0; t < tabData_.size(); ++t) {
        const QString filePath = QDir(dir).absoluteFilePath(
            QStringLiteral("%1.ttbl").arg(t, 4, 10, QChar('0')));
        const int curIdx = (t == activeTab_) ? playlist_.currentIndex()
                                             : tabData_[t].currentIndex;
        const bool ok = writer.write(filePath, tabData_[t].entries,
                                     tabData_[t].name, curIdx);
        if (!ok) {
            qWarning() << "[TtblSave] failed to write" << filePath;
        }
    }

    qDebug().noquote()
        << QStringLiteral("[TtblSave] saved %1 playlist(s) to %2").arg(tabData_.size()).arg(dir);
    return activeTab_;
}
