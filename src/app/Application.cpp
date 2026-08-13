#include "Application.h"
#include <QFileDialog>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QDebug>
#include <QAction>
#include <QStyle>
#include <QActionGroup>
#include <QSet>
#include <QTimer>
#include <QSocketNotifier>
#include <QDateTime>
#include <QXmlStreamReader>
#include <QXmlStreamWriter>
#include <QDirIterator>
#include <QVariant>
#include <QKeySequence>
#include <QShortcut>
#include <QGuiApplication>
#include <QWindow>
#include <QElapsedTimer>
#include <functional>
#ifdef QT_DBUS_LIB
#include <QDBusConnection>
#include <QDBusAbstractAdaptor>
#include <QDBusObjectPath>
#include <QDBusMessage>
#include <QUrl>
#endif
#ifdef Q_OS_WIN
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  ifndef UNICODE
#    define UNICODE
#  endif
#  include <windows.h>
#  include <shobjidl.h>    // ITaskbarList3, THUMBBUTTON
#  include <commctrl.h>    // HIMAGELIST helpers
#  include <QAbstractNativeEventFilter>
// SMTC (Windows.Media) \u9700\u8981 Windows SDK 10.0.15063+ \u4e14 MSVC/WRL \u5934\u6587\u4ef6\u53ef\u7528
#  if defined(_WIN32_WINNT_WIN10) && _WIN32_WINNT >= _WIN32_WINNT_WIN10 \
      && __has_include(<systemmediatransportcontrolsinterop.h>) \
      && __has_include(<wrl/client.h>) \
      && __has_include(<wrl/event.h>)
#    define HAS_WIN_SMTC 1
#    include <systemmediatransportcontrolsinterop.h>
#    include <Windows.Media.h>
#    include <wrl/client.h>
#    include <wrl/event.h>
#    include <roapi.h>
#  endif
#endif
namespace {
// 是否在主窗口拖动时进行实时吸附联动。
constexpr bool kEnableLiveAttachOnMainDrag = true;
constexpr int kDefaultSnapGapPx = 1;
const char kSkinSelectionFollowOriginal[] = "__skin__:follow-original";
const char kSkinSelectionBuiltinDefault[] = "__skin__:builtin-default";

void forceImmediateRefresh(QWidget* window) {
    if (!window) {
        return;
    }
    window->update();
    if (window->isVisible()) {
        window->repaint();
    }
}

// 检测原版 TTPlayer 的根目录，用于查找原版皮肤资源。
QString detectOriginalRoot() {
    QStringList candidates = {
        QDir::currentPath() + "/../TTPlayerv5.7.9",
        QDir::currentPath() + "/../../TTPlayerv5.7.9",
        "/home/john/Downloads/TTPlayer-main/TTPlayerv5.7.9"
    };

    for (const auto& c : candidates) {
        if (QFileInfo::exists(c + "/TTPlayer.xml")) {
            return QDir(c).absolutePath();
        }
    }
    return {};
}

QString readOriginalSkinPackage(const QString& ttplayerXmlPath) {
    QFile f(ttplayerXmlPath);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return {};
    }

    QXmlStreamReader xml(&f);
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement() && xml.name() == "Skin") {
            return xml.attributes().value("PackageName").toString();
        }
    }
    return {};
}

QString normalizeSkinFileName(QString packageName) {
    if (packageName.isEmpty() || packageName == "<Default_Skin>") {
        return "Classic.skn";
    }
    if (!packageName.endsWith(".skn", Qt::CaseInsensitive)) {
        packageName += ".skn";
    }
    return packageName;
}

QString displayNameForSkinPath(const QString& filePath) {
    return QFileInfo(filePath).completeBaseName();
}

bool isRarWrappedSkin(const QString& filePath) {
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) {
        return false;
    }
    const QByteArray header = file.read(8);
    return header.startsWith("Rar!\x1A\x07");
}

QStringList candidateSkinDirectories(const QString& originalRoot) {
    QStringList dirs;
    if (!originalRoot.isEmpty()) {
        dirs << originalRoot + "/Skin";
        dirs << QFileInfo(originalRoot).absolutePath() + "/build/Skin";
    }

    dirs << QDir::currentPath() + "/Skin";
    dirs << QDir::currentPath() + "/../Skin";
    dirs << QDir::currentPath() + "/../build/Skin";
    dirs << QDir::currentPath() + "/../../build/Skin";

    QStringList existing;
    QSet<QString> seen;
    for (const auto& dir : dirs) {
        const QString cleaned = QDir(dir).absolutePath();
        if (QDir(cleaned).exists() && !seen.contains(cleaned)) {
            seen.insert(cleaned);
            existing << cleaned;
        }
    }
    return existing;
}

} // 匿名辅助命名空间

#ifdef QT_DBUS_LIB
// org.mpris.MediaPlayer2 根接口 —— 应用基本信息
class MprisAdaptor : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
    Q_PROPERTY(bool CanQuit READ canQuit CONSTANT)
    Q_PROPERTY(bool CanRaise READ canRaise CONSTANT)
    Q_PROPERTY(bool HasTrackList READ hasTrackList CONSTANT)
    Q_PROPERTY(QString Identity READ identity CONSTANT)
    Q_PROPERTY(QString DesktopEntry READ desktopEntry CONSTANT)
    Q_PROPERTY(QStringList SupportedUriSchemes READ supportedUriSchemes CONSTANT)
    Q_PROPERTY(QStringList SupportedMimeTypes READ supportedMimeTypes CONSTANT)
public:
    explicit MprisAdaptor(Application* parent)
        : QDBusAbstractAdaptor(parent), app_(parent) {}
    bool canQuit() const { return true; }
    bool canRaise() const { return true; }
    bool hasTrackList() const { return false; }
    QString identity() const { return QStringLiteral("TTPlayer Reborn"); }
    QString desktopEntry() const { return QStringLiteral("ttplayerreborn"); }
    QStringList supportedUriSchemes() const { return {QStringLiteral("file")}; }
    QStringList supportedMimeTypes() const {
        return {QStringLiteral("audio/mpeg"), QStringLiteral("audio/flac"),
                QStringLiteral("audio/wav"),  QStringLiteral("audio/ogg"),
                QStringLiteral("audio/x-ape"), QStringLiteral("audio/aac"),
                QStringLiteral("audio/mp4"),  QStringLiteral("audio/x-ms-wma")};
    }
public slots:
    Q_SCRIPTABLE void Raise() { app_->onShowMainWindow(); }
    Q_SCRIPTABLE void Quit() { qApp->quit(); }
private:
    Application* app_;
};

// org.mpris.MediaPlayer2.Player 接口 —— 播放控制与元数据
class MprisPlayerAdaptor : public QDBusAbstractAdaptor {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
    // MPRIS2 规范要求的所有属性
    Q_PROPERTY(QString PlaybackStatus READ playbackStatus)
    Q_PROPERTY(double Rate READ rate WRITE setRate)
    Q_PROPERTY(QVariantMap Metadata READ metadata)
    Q_PROPERTY(double Volume READ volume WRITE setVolume)
    Q_PROPERTY(qlonglong Position READ position)
    Q_PROPERTY(double MinimumRate READ minimumRate CONSTANT)
    Q_PROPERTY(double MaximumRate READ maximumRate CONSTANT)
    Q_PROPERTY(bool CanGoNext READ canGoNext CONSTANT)
    Q_PROPERTY(bool CanGoPrevious READ canGoPrevious CONSTANT)
    Q_PROPERTY(bool CanPlay READ canPlay CONSTANT)
    Q_PROPERTY(bool CanPause READ canPause CONSTANT)
    Q_PROPERTY(bool CanSeek READ canSeek CONSTANT)
    Q_PROPERTY(bool CanControl READ canControl CONSTANT)
public:
    explicit MprisPlayerAdaptor(Application* parent)
        : QDBusAbstractAdaptor(parent), app_(parent) {}

    QString playbackStatus() const {
        switch (app_->engine_.state()) {
        case AudioEngine::Playing: return QStringLiteral("Playing");
        case AudioEngine::Paused:  return QStringLiteral("Paused");
        default:                   return QStringLiteral("Stopped");
        }
    }
    double rate() const { return 1.0; }
    void setRate(double) {}
    double minimumRate() const { return 1.0; }
    double maximumRate() const { return 1.0; }
    qlonglong position() const {
        return static_cast<qlonglong>(app_->engine_.positionMs()) * 1000LL;
    }
    double volume() const { return app_->engine_.volume() / 100.0; }
    void setVolume(double v) {
        app_->engine_.setVolume(static_cast<int>(qBound(0.0, v, 1.0) * 100.0));
    }
    bool canGoNext() const { return true; }
    bool canGoPrevious() const { return true; }
    bool canPlay() const { return true; }
    bool canPause() const { return true; }
    bool canSeek() const { return true; }
    bool canControl() const { return true; }  // 关键：缺少此属性 KDE 不显示任何控件

    QVariantMap metadata() const {
        QVariantMap meta;
        const QString filePath = app_->engine_.currentFilePath();
        const QString trackId = filePath.isEmpty()
            ? QStringLiteral("/org/mpris/MediaPlayer2/TrackList/NoTrack")
            : QStringLiteral("/org/mpris/MediaPlayer2/Track/") +
              QString::number(qHash(filePath));
        meta[QStringLiteral("mpris:trackid")] =
            QVariant::fromValue(QDBusObjectPath(trackId));
        if (!filePath.isEmpty()) {
            const QString title = app_->engine_.currentTitle().isEmpty()
                ? QFileInfo(filePath).completeBaseName()
                : app_->engine_.currentTitle();
            meta[QStringLiteral("xesam:title")] = title;
            meta[QStringLiteral("xesam:url")] = QUrl::fromLocalFile(filePath).toString();
            const qlonglong dur = static_cast<qlonglong>(app_->engine_.durationMs()) * 1000LL;
            if (dur > 0) meta[QStringLiteral("mpris:length")] = dur;
            const QString artist = app_->engine_.currentArtist();
            if (!artist.isEmpty())
                meta[QStringLiteral("xesam:artist")] = QStringList{artist};
            const QString album = app_->engine_.currentAlbum();
            if (!album.isEmpty())
                meta[QStringLiteral("xesam:album")] = album;
            if (!coverArtPath_.isEmpty())
                meta[QStringLiteral("mpris:artUrl")] =
                    QUrl::fromLocalFile(coverArtPath_).toString();
        }
        return meta;
    }

public slots:
    Q_SCRIPTABLE void Play() {
        if (app_->engine_.state() != AudioEngine::Playing) app_->onTogglePlayPause();
    }
    Q_SCRIPTABLE void Pause() {
        if (app_->engine_.state() == AudioEngine::Playing) app_->onTogglePlayPause();
    }
    Q_SCRIPTABLE void PlayPause() { app_->onTogglePlayPause(); }
    Q_SCRIPTABLE void Next() { app_->onNext(); }
    Q_SCRIPTABLE void Previous() { app_->onPrev(); }
    Q_SCRIPTABLE void Stop() { app_->engine_.stop(); }
    Q_SCRIPTABLE void Seek(qlonglong offsetUs) {
        app_->engine_.seek(app_->engine_.positionMs() + offsetUs / 1000LL);
    }
    Q_SCRIPTABLE void SetPosition(const QDBusObjectPath& /*trackId*/, qlonglong posUs) {
        app_->engine_.seek(posUs / 1000LL);
    }
    Q_SCRIPTABLE void OpenUri(const QString& uri) {
        const QString path = QUrl(uri).toLocalFile();
        if (!path.isEmpty()) { app_->engine_.loadFile(path); app_->engine_.play(); }
    }

    // 发送标准 PropertiesChanged 信号（KDE/GNOME 监听此信号更新 UI）
    void notifyPlaybackStatusChanged() {
        sendPropertiesChanged({{QStringLiteral("PlaybackStatus"), playbackStatus()}});
    }
    void notifyVolumeChanged() {
        sendPropertiesChanged({{QStringLiteral("Volume"), volume()}});
    }
    void notifyMetadataChanged() {
        updateCoverArtFile();
        sendPropertiesChanged({
            {QStringLiteral("Metadata"),       metadata()},
            {QStringLiteral("PlaybackStatus"), playbackStatus()}
        });
    }

signals:
    // Seeked 是 MPRIS2 规范中唯一需要主动发出的信号
    Q_SCRIPTABLE void Seeked(qlonglong position);

private:
    Application* app_;
    QString coverArtPath_;

    // 将封面写入临时文件，MPRIS 需要 file:// URI 才能加载图片
    void updateCoverArtFile() {
        const QString filePath = app_->engine_.currentFilePath();
        if (filePath.isEmpty()) {
            coverArtPath_.clear();
            return;
        }
        // 每首曲使用不同的临时文件路径，防止 KDE/GNOME 缓存旧封面图
        const QString newPath = QDir::tempPath()
            + QStringLiteral("/ttplayerreborn_art_%1.jpg")
              .arg(qHash(filePath), 8, 16, QChar('0'));
        if (newPath == coverArtPath_) return;  // 当前曲目已写入，跳过
        coverArtPath_.clear();
        const QByteArray cover = app_->engine_.currentCoverArt();
        if (!cover.isEmpty()) {
            QFile f(newPath);
            if (f.open(QIODevice::WriteOnly) && f.write(cover) > 0) {
                coverArtPath_ = newPath;
            }
        }
    }

    // 发送 org.freedesktop.DBus.Properties.PropertiesChanged 信号
    void sendPropertiesChanged(const QVariantMap& changed) {
        QDBusMessage msg = QDBusMessage::createSignal(
            QStringLiteral("/org/mpris/MediaPlayer2"),
            QStringLiteral("org.freedesktop.DBus.Properties"),
            QStringLiteral("PropertiesChanged"));
        msg << QStringLiteral("org.mpris.MediaPlayer2.Player") << changed << QStringList{};
        QDBusConnection::sessionBus().send(msg);
    }
};
#endif // QT_DBUS_LIB

// ============================================================
//  WinMediaSession —— Windows 媒体控件集成
//  · ITaskbarList3  任务栏缩略图工具栏（前/播放暂停/后）
//  · SMTC (Windows.Media)  系统媒体传输控件（Win10+ 媒体浮窗）
// ============================================================
#ifdef Q_OS_WIN

// 按钮 ID，避免与 Qt 内部 WM_COMMAND id 冲突（取大值 7001-7003）
static constexpr UINT kThumbBtnPrev = 7001;
static constexpr UINT kThumbBtnPlay = 7002;
static constexpr UINT kThumbBtnNext = 7003;
// THBN_CLICKED 是缩略图工具栏按钮的 WM_COMMAND 通知码
#ifndef THBN_CLICKED
#  define THBN_CLICKED 0x1800
#endif

// 将 QImage 转换为带透明通道的 HBITMAP（32bpp ARGB DIB）
static HBITMAP qImageToHBitmap(const QImage& src) {
    const QImage img = src.convertToFormat(QImage::Format_ARGB32_Premultiplied);
    if (img.isNull()) return nullptr;
    BITMAPV4HEADER hdr{};
    hdr.bV4Size          = sizeof(BITMAPV4HEADER);
    hdr.bV4Width         = img.width();
    hdr.bV4Height        = -img.height();  // top-down DIB
    hdr.bV4Planes        = 1;
    hdr.bV4BitCount      = 32;
    hdr.bV4V4Compression = BI_BITFIELDS;
    hdr.bV4RedMask       = 0x00FF0000;
    hdr.bV4GreenMask     = 0x0000FF00;
    hdr.bV4BlueMask      = 0x000000FF;
    hdr.bV4AlphaMask     = 0xFF000000;
    void* bits = nullptr;
    HBITMAP hbm = CreateDIBSection(nullptr, reinterpret_cast<BITMAPINFO*>(&hdr),
                                   DIB_RGB_COLORS, &bits, nullptr, 0);
    if (hbm && bits)
        memcpy(bits, img.constBits(), static_cast<size_t>(img.sizeInBytes()));
    return hbm;
}

// 将 QPixmap 缩放到指定尺寸并转换为 HICON
static HICON qPixmapToHIcon(const QPixmap& pm, int size) {
    if (pm.isNull()) return nullptr;
    const QImage img = pm.scaled(size, size, Qt::KeepAspectRatio, Qt::SmoothTransformation)
                         .toImage().convertToFormat(QImage::Format_ARGB32_Premultiplied);
    HBITMAP hbmColor = qImageToHBitmap(img);
    if (!hbmColor) return nullptr;
    HBITMAP hbmMask = CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO ii{};
    ii.fIcon    = TRUE;
    ii.hbmColor = hbmColor;
    ii.hbmMask  = hbmMask;
    HICON hIcon = CreateIconIndirect(&ii);
    DeleteObject(hbmColor);
    DeleteObject(hbmMask);
    return hIcon;
}

class WinMediaSession : public QAbstractNativeEventFilter {
public:
    explicit WinMediaSession(Application* app)
        : app_(app)
        , taskbarCreatedMsg_(RegisterWindowMessage(L"TaskbarCreated"))
    {}

    ~WinMediaSession() { cleanup(); }

    void init() {
        hwnd_ = reinterpret_cast<HWND>(app_->playerWindow_->winId());
        if (!hwnd_) return;
        // COM 初始化（允许重入，Qt 已在主线程初始化过）
        CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        initTaskbarThumbnail();
#ifdef HAS_WIN_SMTC
        initSmtc();
#endif
        // 注册原生消息过滤器，捕获 TaskbarCreated + WM_COMMAND
        QCoreApplication::instance()->installNativeEventFilter(this);
    }

    // 播放状态改变时调用（更新工具栏播放/暂停图标 + SMTC 状态）
    void updatePlayState() {
        const bool isPlaying = app_->engine_.state() == AudioEngine::Playing;
        updateThumbbarPlayBtn(isPlaying);
#ifdef HAS_WIN_SMTC
        updateSmtcStatus();
#endif
    }

    // 曲目或元数据改变时调用
    void updateMetadata() {
#ifdef HAS_WIN_SMTC
        updateSmtcMetadata();
#endif
    }

    bool nativeEventFilter(const QByteArray& eventType, void* message, qintptr*) override {
        if (eventType != "windows_generic_MSG") return false;
        const MSG* msg = static_cast<const MSG*>(message);

        // Explorer 重启后重新初始化工具栏
        if (msg->message == taskbarCreatedMsg_) {
            initTaskbarThumbnail();
            return false;
        }

        // 缩略图工具栏按钮点击：
        // LOWORD(wParam) = 按钮ID，HIWORD(wParam) = THBN_CLICKED
        if (msg->message == WM_COMMAND && msg->hwnd == hwnd_) {
            const UINT notif = HIWORD(msg->wParam);
            const UINT id    = LOWORD(msg->wParam);
            if (notif == THBN_CLICKED || notif == 0) {
                if (id == kThumbBtnPrev) {
                    QMetaObject::invokeMethod(app_, "onPrev", Qt::QueuedConnection);
                    return true;
                }
                if (id == kThumbBtnPlay) {
                    QMetaObject::invokeMethod(app_, "onTogglePlayPause", Qt::QueuedConnection);
                    return true;
                }
                if (id == kThumbBtnNext) {
                    QMetaObject::invokeMethod(app_, "onNext", Qt::QueuedConnection);
                    return true;
                }
            }
        }
        return false;
    }

private:
    // -------- ITaskbarList3 缩略图工具栏 --------

    void initTaskbarThumbnail() {
        if (pTaskbar_) { pTaskbar_->Release(); pTaskbar_ = nullptr; }
        const HRESULT hr = CoCreateInstance(CLSID_TaskbarList, nullptr,
                                            CLSCTX_INPROC_SERVER, IID_ITaskbarList3,
                                            reinterpret_cast<void**>(&pTaskbar_));
        if (FAILED(hr) || FAILED(pTaskbar_->HrInit())) {
            if (pTaskbar_) { pTaskbar_->Release(); pTaskbar_ = nullptr; }
            return;
        }

        safeDestroyIcon(iconPlay_);
        safeDestroyIcon(iconPause_);
        iconPlay_  = qPixmapToHIcon(QApplication::style()->standardPixmap(QStyle::SP_MediaPlay), 20);
        iconPause_ = qPixmapToHIcon(QApplication::style()->standardPixmap(QStyle::SP_MediaPause), 20);
        HICON icoPrev = qPixmapToHIcon(QApplication::style()->standardPixmap(QStyle::SP_MediaSkipBackward), 20);
        HICON icoNext = qPixmapToHIcon(QApplication::style()->standardPixmap(QStyle::SP_MediaSkipForward), 20);

        THUMBBUTTON btns[3]{};
        btns[0].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
        btns[0].iId    = kThumbBtnPrev;  btns[0].hIcon = icoPrev;
        wcscpy_s(btns[0].szTip, L"上一首");  btns[0].dwFlags = THBF_ENABLED;

        btns[1].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
        btns[1].iId    = kThumbBtnPlay;  btns[1].hIcon = iconPlay_;
        wcscpy_s(btns[1].szTip, L"播放/暂停");  btns[1].dwFlags = THBF_ENABLED;

        btns[2].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
        btns[2].iId    = kThumbBtnNext;  btns[2].hIcon = icoNext;
        wcscpy_s(btns[2].szTip, L"下一首");  btns[2].dwFlags = THBF_ENABLED;

        pTaskbar_->ThumbBarAddButtons(hwnd_, 3, btns);
        safeDestroyIcon(icoPrev);
        safeDestroyIcon(icoNext);
    }

    void updateThumbbarPlayBtn(bool isPlaying) {
        if (!pTaskbar_ || !hwnd_) return;
        HICON ico = isPlaying ? iconPause_ : iconPlay_;
        if (!ico) return;
        THUMBBUTTON btn{};
        btn.dwMask  = THB_ICON | THB_FLAGS;
        btn.iId     = kThumbBtnPlay;
        btn.hIcon   = ico;
        btn.dwFlags = THBF_ENABLED;
        pTaskbar_->ThumbBarUpdateButtons(hwnd_, 1, &btn);
    }

    // -------- SMTC (Windows.Media - Win10+) --------
#ifdef HAS_WIN_SMTC
    void initSmtc() {
        using namespace Microsoft::WRL;
        using namespace Microsoft::WRL::Wrappers;
        using namespace ABI::Windows::Media;

        // 初始化 WinRT（允许多线程公寓，与 Qt COM 共存）
        const HRESULT hrInit = RoInitialize(RO_INIT_MULTITHREADED);
        if (FAILED(hrInit) && hrInit != RPC_E_CHANGED_MODE) return;

        ComPtr<ISystemMediaTransportControlsInterop> interop;
        if (FAILED(RoGetActivationFactory(
                HStringReference(RuntimeClass_Windows_Media_SystemMediaTransportControls).Get(),
                IID_PPV_ARGS(&interop)))) return;

        if (FAILED(interop->GetForWindow(hwnd_, IID_PPV_ARGS(&smtc_)))) return;

        smtc_->put_IsEnabled(true);
        smtc_->put_IsPlayEnabled(true);
        smtc_->put_IsPauseEnabled(true);
        smtc_->put_IsNextEnabled(true);
        smtc_->put_IsPreviousEnabled(true);
        smtc_->put_IsStopEnabled(true);

        // 注册按钮点击回调（在 COM 线程上回调，需队列发送到 Qt 主线程）
        Application* const app = app_;
        smtc_->add_ButtonPressed(
            Callback<ABI::Windows::Foundation::ITypedEventHandler<
                ISystemMediaTransportControls*,
                SystemMediaTransportControlsButtonPressedEventArgs*>>(
                [app](ISystemMediaTransportControls*,
                       ISystemMediaTransportControlsButtonPressedEventArgs* args) -> HRESULT {
                    SystemMediaTransportControlsButton btn{};
                    args->get_Button(&btn);
                    switch (btn) {
                    case SystemMediaTransportControlsButton_Play:
                    case SystemMediaTransportControlsButton_Pause:
                        QMetaObject::invokeMethod(app, "onTogglePlayPause",
                                                  Qt::QueuedConnection);
                        break;
                    case SystemMediaTransportControlsButton_Next:
                        QMetaObject::invokeMethod(app, "onNext", Qt::QueuedConnection);
                        break;
                    case SystemMediaTransportControlsButton_Previous:
                        QMetaObject::invokeMethod(app, "onPrev", Qt::QueuedConnection);
                        break;
                    case SystemMediaTransportControlsButton_Stop:
                        QMetaObject::invokeMethod(app->engine(),
                                                  "stop", Qt::QueuedConnection);
                        break;
                    default: break;
                    }
                    return S_OK;
                }).Get(),
            &buttonPressedToken_);
    }

    void updateSmtcStatus() {
        if (!smtc_) return;
        using namespace ABI::Windows::Media;
        switch (app_->engine_.state()) {
        case AudioEngine::Playing:
            smtc_->put_PlaybackStatus(MediaPlaybackStatus_Playing);  break;
        case AudioEngine::Paused:
            smtc_->put_PlaybackStatus(MediaPlaybackStatus_Paused);   break;
        default:
            smtc_->put_PlaybackStatus(MediaPlaybackStatus_Stopped);  break;
        }
    }

    void updateSmtcMetadata() {
        if (!smtc_) return;
        using namespace Microsoft::WRL;
        using namespace ABI::Windows::Media;

        ComPtr<ISystemMediaTransportControlsDisplayUpdater> updater;
        if (FAILED(smtc_->get_DisplayUpdater(&updater))) return;
        updater->put_Type(MediaPlaybackType_Music);

        ComPtr<IMusicDisplayProperties> musicProps;
        if (FAILED(updater->get_MusicProperties(&musicProps))) return;

        auto setStr = [](HSTRING& h, const QString& s) {
            const std::wstring ws = s.toStdWString();
            WindowsCreateString(ws.c_str(), static_cast<UINT32>(ws.size()), &h);
        };
        const QString title = app_->engine_.currentTitle().isEmpty()
            ? QFileInfo(app_->engine_.currentFilePath()).completeBaseName()
            : app_->engine_.currentTitle();

        HSTRING hTitle{}; setStr(hTitle, title);          musicProps->put_Title(hTitle);         WindowsDeleteString(hTitle);
        HSTRING hArtist{}; setStr(hArtist, app_->engine_.currentArtist()); musicProps->put_AlbumArtist(hArtist); WindowsDeleteString(hArtist);
        HSTRING hAlbum{};  setStr(hAlbum,  app_->engine_.currentAlbum());  musicProps->put_AlbumTitle(hAlbum);   WindowsDeleteString(hAlbum);

        // 封面图：将 QByteArray 写入临时文件，通过 RandomAccessStreamReference 加载
        const QByteArray cover = app_->engine_.currentCoverArt();
        if (!cover.isEmpty()) {
            const QString artPath = QDir::tempPath()
                + QStringLiteral("/ttplayerreborn_winart.jpg");
            QFile f(artPath);
            if (f.open(QIODevice::WriteOnly) && f.write(cover) > 0) {
                f.close();
                ComPtr<ABI::Windows::Storage::IStorageFileStatics> sfStatics;
                HSTRING hFileCls{};
                WindowsCreateString(L"Windows.Storage.StorageFile",
                                    static_cast<UINT32>(wcslen(L"Windows.Storage.StorageFile")),
                                    &hFileCls);
                // 尝试通过 URI 设置封面（忽略失败，不影响其他字段）
                ComPtr<ABI::Windows::Foundation::IUriRuntimeClassFactory> uriFactory;
                if (SUCCEEDED(RoGetActivationFactory(
                        Microsoft::WRL::Wrappers::HStringReference(
                            RuntimeClass_Windows_Foundation_Uri).Get(),
                        IID_PPV_ARGS(&uriFactory)))) {
                    const std::wstring uriStr = (QStringLiteral("file:///")
                        + artPath.replace('\\', '/')).toStdWString();
                    HSTRING hUri{};
                    WindowsCreateString(uriStr.c_str(),
                                        static_cast<UINT32>(uriStr.size()), &hUri);
                    ComPtr<ABI::Windows::Foundation::IUriRuntimeClass> uri;
                    if (SUCCEEDED(uriFactory->CreateUri(hUri, &uri))) {
                        ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStreamReferenceStatics> refStatics;
                        if (SUCCEEDED(RoGetActivationFactory(
                                Microsoft::WRL::Wrappers::HStringReference(
                                    RuntimeClass_Windows_Storage_Streams_RandomAccessStreamReference).Get(),
                                IID_PPV_ARGS(&refStatics)))) {
                            ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStreamReference> ref;
                            refStatics->CreateFromUri(uri.Get(), &ref);
                            updater->put_Thumbnail(ref.Get());
                        }
                    }
                    WindowsDeleteString(hUri);
                }
                WindowsDeleteString(hFileCls);
            }
        }
        updater->Update();
    }
#endif // HAS_WIN_SMTC

    void cleanup() {
        QCoreApplication::instance()->removeNativeEventFilter(this);
#ifdef HAS_WIN_SMTC
        if (smtc_) { smtc_->remove_ButtonPressed(buttonPressedToken_); smtc_.Reset(); }
#endif
        safeDestroyIcon(iconPlay_);
        safeDestroyIcon(iconPause_);
        if (pTaskbar_) { pTaskbar_->Release(); pTaskbar_ = nullptr; }
    }

    static void safeDestroyIcon(HICON& ico) {
        if (ico) { DestroyIcon(ico); ico = nullptr; }
    }

    Application*   app_;
    HWND           hwnd_              = nullptr;
    ITaskbarList3* pTaskbar_          = nullptr;
    HICON          iconPlay_          = nullptr;
    HICON          iconPause_         = nullptr;
    UINT           taskbarCreatedMsg_;
#ifdef HAS_WIN_SMTC
    Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControls> smtc_;
    EventRegistrationToken buttonPressedToken_{};
#endif
};
#endif // Q_OS_WIN

namespace {

// 将 QRect 编码为逗号分隔的字符串，方便保存到侧车配置中。
QString encodeSkinRect(const QRect& rect) {
    return QStringLiteral("%1,%2,%3,%4")
        .arg(rect.x())
        .arg(rect.y())
        .arg(rect.x() + rect.width())
        .arg(rect.y() + rect.height());
}
} // 命名空间结束

Application::Application(int& argc, char** argv)
    : QObject(nullptr)
    , app_(argc, argv)
{
    qInfo() << "Qt platform:" << QGuiApplication::platformName();

    app_.setApplicationName("TTPlayer Reborn");
    app_.setApplicationVersion("0.1.0");
    app_.setOrganizationName("TTPlayerReborn");

    // 创建主窗口和辅助窗口
    playerWindow_ = std::make_unique<PlayerWindow>(&engine_);
    lyricWindow_ = std::make_unique<LyricWindow>(&engine_, playerWindow_.get());
    eqWindow_ = std::make_unique<EqualizerWindow>(&engine_, playerWindow_.get());
    playlistWindow_ = std::make_unique<PlaylistWindow>(&engine_, playerWindow_.get());

    // 设置窗口吸附管理器，处理主窗口与辅助窗口之间的联动吸附与移动。
    snapManager_ = std::make_unique<WindowSnapManager>(this);
    snapManager_->setMainWindow(playerWindow_.get());
    snapManager_->addSubWindow(lyricWindow_.get());
    snapManager_->addSubWindow(eqWindow_.get());
    snapManager_->addSubWindow(playlistWindow_.get());
    // 关闭此开关可回到“仅拖动联动，不做实时吸附捕获”的低负载模式。
    snapManager_->setLiveAttachOnMainDragEnabled(kEnableLiveAttachOnMainDrag);

    // 当主窗口移动时，让所有已吸附的子窗口同步移动。
    connect(playerWindow_.get(), &PlayerWindow::windowMoved,
            snapManager_.get(), &WindowSnapManager::onMainMoved);
    connect(playerWindow_.get(), &PlayerWindow::dragStarted, this, [this]() {
        snapManager_->onDragStarted(playerWindow_.get());
    });
    connect(playerWindow_.get(), &PlayerWindow::dragFinished, this, [this]() {
        snapManager_->onDragFinished(playerWindow_.get());
    });
    // 当子窗口移动时，重新检查是否应吸附到主窗口或其他子窗口。
    connect(lyricWindow_.get(), &LyricWindow::windowMoved, this, [this](QPoint delta) {
        snapManager_->onSubMoved(lyricWindow_.get(), delta);
    });
    connect(lyricWindow_.get(), &LyricWindow::dragStarted, this, [this]() {
        snapManager_->onDragStarted(lyricWindow_.get());
    });
    connect(lyricWindow_.get(), &LyricWindow::dragFinished, this, [this]() {
        snapManager_->onDragFinished(lyricWindow_.get());
    });
    connect(lyricWindow_.get(), &LyricWindow::resizeInProgress, this, [this](Qt::Edges edges) {
        snapManager_->onSubResized(lyricWindow_.get(), edges);
    });
    connect(lyricWindow_.get(), &LyricWindow::resizeFinished, this, [this](Qt::Edges edges) {
        snapManager_->onSubResizeFinished(lyricWindow_.get(), edges);
    });
    connect(lyricWindow_.get(), &LyricWindow::alwaysOnTopToggled,
            this, &Application::onAlwaysOnTopToggled);
    connect(lyricWindow_.get(), &LyricWindow::closeRequested, this, [this]() {
        onLyricToggled(false);
    });
    connect(lyricWindow_.get(), &LyricWindow::visibilityChanged, this, [this](bool) {
        if (suppressAuxVisibilitySync_) {
            return;
        }
        syncAuxWindowToggleStates();
        snapManager_->rebuildSnapGraph();
    });
    connect(eqWindow_.get(), &EqualizerWindow::windowMoved, this, [this](QPoint delta) {
        snapManager_->onSubMoved(eqWindow_.get(), delta);
    });
    connect(eqWindow_.get(), &EqualizerWindow::dragStarted, this, [this]() {
        snapManager_->onDragStarted(eqWindow_.get());
    });
    connect(eqWindow_.get(), &EqualizerWindow::dragFinished, this, [this]() {
        snapManager_->onDragFinished(eqWindow_.get());
    });
    connect(eqWindow_.get(), &EqualizerWindow::closeRequested, this, [this]() {
        onEqualizerToggled(false);
    });
    connect(eqWindow_.get(), &EqualizerWindow::visibilityChanged, this, [this](bool) {
        if (suppressAuxVisibilitySync_) {
            return;
        }
        syncAuxWindowToggleStates();
        snapManager_->rebuildSnapGraph();
    });
    connect(playlistWindow_.get(), &PlaylistWindow::windowMoved, this, [this](QPoint delta) {
        snapManager_->onSubMoved(playlistWindow_.get(), delta);
    });
    connect(playlistWindow_.get(), &PlaylistWindow::dragStarted, this, [this]() {
        snapManager_->onDragStarted(playlistWindow_.get());
    });
    connect(playlistWindow_.get(), &PlaylistWindow::dragFinished, this, [this]() {
        snapManager_->onDragFinished(playlistWindow_.get());
    });
    connect(playlistWindow_.get(), &PlaylistWindow::resizeInProgress, this, [this](Qt::Edges edges) {
        snapManager_->onSubResized(playlistWindow_.get(), edges);
    });
    connect(playlistWindow_.get(), &PlaylistWindow::resizeFinished, this, [this](Qt::Edges edges) {
        snapManager_->onSubResizeFinished(playlistWindow_.get(), edges);
    });
    connect(playlistWindow_.get(), &PlaylistWindow::closeRequested, this, [this]() {
        onPlaylistToggled(false);
    });
    connect(playlistWindow_.get(), &PlaylistWindow::visibilityChanged, this, [this](bool) {
        if (suppressAuxVisibilitySync_) {
            return;
        }
        syncAuxWindowToggleStates();
        snapManager_->rebuildSnapGraph();
    });

    // 连接主播放器窗口的信号到应用程序事件处理函数。
    connect(playerWindow_.get(), &PlayerWindow::openFileRequested, this, &Application::onOpenFile);
    connect(playerWindow_.get(), &PlayerWindow::lyricToggled, this, &Application::onLyricToggled);
    connect(playerWindow_.get(), &PlayerWindow::equalizerToggled, this, &Application::onEqualizerToggled);
    connect(playerWindow_.get(), &PlayerWindow::playlistToggled, this, &Application::onPlaylistToggled);
        connect(playerWindow_.get(), &PlayerWindow::prevRequested, this, &Application::onPrev);
        connect(playerWindow_.get(), &PlayerWindow::nextRequested, this, &Application::onNext);
        connect(playerWindow_.get(), &PlayerWindow::contextMenuRequested,
            this, &Application::onPlayerContextMenuRequested);
    connect(playerWindow_.get(), &PlayerWindow::exitRequested, &app_, &QApplication::quit);
        connect(playerWindow_.get(), &PlayerWindow::miniModeRequested, this, &Application::onMiniModeRequested);
        connect(playerWindow_.get(), &PlayerWindow::minimizeRequested, this, &Application::onMinimizeRequested);

    // 连接音频引擎播放结束信号，用于自动切换下一首。
    connect(&engine_, &AudioEngine::trackFinished, this, &Application::onTrackFinished);

    // 连接播放列表文件选择信号，用于开始播放所选文件。
    connect(playlistWindow_.get(), &PlaylistWindow::fileSelected, this, &Application::onFileSelected);

    // 保存退出时的窗口位置、可见性、播放状态及配置到文件。
    connect(&app_, &QApplication::aboutToQuit, this, &Application::saveState);

}

Application::~Application() = default;

// 启动应用程序主流程：读取配置、加载皮肤、恢复窗口状态并进入事件循环。
int Application::run() {
    // 读取配置文件并恢复当前状态
    const QString configPath = Config::defaultPath();
    configLoaded_ = config_.load(configPath);
    if (!configLoaded_) {
        const QString legacyConfigPath = Config::legacyPath();
        if (!legacyConfigPath.isEmpty() &&
            legacyConfigPath != configPath &&
            QFileInfo::exists(legacyConfigPath)) {
            configLoaded_ = config_.load(legacyConfigPath);
        }
    }

    playlistWindow_->setPlaybackMode(config_.repeatMode(), config_.shuffle());

    // 在皮肤创建之前先恢复音量/静音/平衡状态，以便界面控件与当前状态一致。
    engine_.setVolume(config_.volume());
    engine_.setMuted(config_.muted());
    engine_.setBalance(config_.balance());

    if (config_.eqEnabled()) {
        auto& dsp = engine_.dspChain();
        dsp.equalizer.setEnabled(true);
        dsp.equalizer.setPreamp(config_.eqPreamp());
        for (int i = 0; i < 10; i++) {
            dsp.equalizer.setBandGain(i, config_.eqBand(i));
        }
    }

    // 初始化用户意图可见性变量，以配置文件为基础。
    // 启动时只读 TTPlayer.xml，不读皮肤 sidecar；sidecar 仅在切换皮肤时读写。
    auxLyricVisible_ = config_.lyricVisible();
    auxEqVisible_ = config_.eqVisible();
    auxPlaylistVisible_ = config_.playlistVisible();

    createTrayMenu();

    // 加载皮肤并应用到窗口
    loadSkin();
    rebuildSkinMenu();
    applySkin();

    // 恢复窗口位置和可见状态（从 TTPlayer.xml 读取，sidecar 仅作无配置时的回退）。
    restoreState();
    applyAlwaysOnTop(config_.alwaysOnTop());

    // 加载播放列表文件（与 Config 同步时机，均在启动时读取）。
    // 快速加载路径后立即更新 UI，元数据由后台线程填充。
    {
        QString playlistDir = config_.playlistDir();
        if (playlistDir.isEmpty()) {
            playlistDir = QDir(QCoreApplication::applicationDirPath())
                              .absoluteFilePath(QStringLiteral("PlayList"));
        }
        config_.setPlaylistDir(playlistDir);  // 确保 Config 保存的是绝对路径

        const int plCount   = qMax(1, config_.playlistCount());
        const int activeList = qBound(0, config_.activeList(), plCount - 1);

        qDebug().noquote()
            << QStringLiteral("[Application] loading playlists from %1 (count=%2 active=%3)")
                   .arg(playlistDir).arg(plCount).arg(activeList);
        playlistWindow_->loadFromTtblDir(playlistDir, plCount, activeList);
    }

    // 显示主窗口和辅助窗口，并在皮肤布局加载完成后同步状态。
    playerWindow_->show();
    playerWindow_->activateWindow();
    suppressAuxVisibilitySync_ = true;
    if (auxPlaylistVisible_) playlistWindow_->show();
    if (auxLyricVisible_) lyricWindow_->show();
    if (auxEqVisible_) eqWindow_->show();
    suppressAuxVisibilitySync_ = false;
    // 不在此处再次调用 layoutFromSkin()：restoreState() 已完成位置恢复，
    // 重复调用会用 sidecar geometry 覆盖刚从 TTPlayer.xml 恢复的 config 位置。
    bindAuxWindowsToMain();
    syncAuxWindowToggleStates();

    snapManager_->rebuildSnapGraph();

    if (trayIcon_) {
        trayIcon_->show();
        trayIcon_->setToolTip(QStringLiteral("TTPlayer Reborn"));
    }

    initPlatformMediaControls();
    updatePlatformMediaControls();

    return app_.exec();
}

void Application::initPlatformMediaControls() {
#ifdef QT_DBUS_LIB
    if (QDBusConnection::sessionBus().isConnected()) {
        const QString serviceName = QStringLiteral("org.mpris.MediaPlayer2.ttplayerreborn");
        if (QDBusConnection::sessionBus().registerService(serviceName)) {
            mprisCoreAdaptor_ = new MprisAdaptor(this);
            mprisPlayerAdaptor_ = new MprisPlayerAdaptor(this);
            QDBusConnection::sessionBus().registerObject(
                QStringLiteral("/org/mpris/MediaPlayer2"), this,
                QDBusConnection::ExportAdaptors);
            connect(&engine_, &AudioEngine::stateChanged,
                    this, &Application::updateMprisPlaybackStatus);
            connect(&engine_, &AudioEngine::stateChanged,
                    this, &Application::updateMprisMetadata);   // 状态变化时也需刷新元数据
            connect(&engine_, &AudioEngine::volumeChanged,
                    this, &Application::updateMprisVolume);
            connect(&engine_, &AudioEngine::mutedChanged,
                    this, &Application::updateMprisVolume);
            // durationChanged 在每个新文件加载同时发出，是封面和元数据刷新的正确时机
            connect(&engine_, &AudioEngine::durationChanged,
                    this, &Application::updateMprisMetadata);
        }
    }
#endif
#ifdef Q_OS_WIN
    // 初始化 Windows 媒体控制（ITaskbarList3 + SMTC）
    winMediaSession_ = new WinMediaSession(this);
    winMediaSession_->init();
    // 连接引擎信号更新任判1工具栏和 SMTC
    connect(&engine_, &AudioEngine::stateChanged,
            this, &Application::updatePlatformMediaControls);
    connect(&engine_, &AudioEngine::durationChanged,
            this, &Application::updatePlatformMediaControls);
#endif
}

void Application::updatePlatformMediaControls() {
#ifdef QT_DBUS_LIB
    updateMprisMetadata();
    updateMprisPlaybackStatus();
    updateMprisVolume();
#endif
#ifdef Q_OS_WIN
    if (winMediaSession_) {
        winMediaSession_->updatePlayState();
        winMediaSession_->updateMetadata();
    }
#endif
}

#ifdef QT_DBUS_LIB
void Application::updateMprisMetadata() {
    if (mprisPlayerAdaptor_) {
        mprisPlayerAdaptor_->notifyMetadataChanged();
    }
}

void Application::updateMprisPlaybackStatus() {
    if (mprisPlayerAdaptor_) {
        mprisPlayerAdaptor_->notifyPlaybackStatusChanged();
    }
}

void Application::updateMprisVolume() {
    if (mprisPlayerAdaptor_) {
        mprisPlayerAdaptor_->notifyVolumeChanged();
    }
}
#endif

// 扫描可用的皮肤资源，包括原版当前皮肤、内置默认和本地 Skin 目录中的 .skn 文件。
// 扫描可用皮肤资源：跟随原版、内置默认和本地 Skin 目录中的 .skn 文件。
QVector<Application::SkinChoice> Application::discoverAvailableSkins() const {
    QVector<SkinChoice> choices;
    const QString originalRoot = detectOriginalRoot();
    const QString currentOriginalPackage = originalRoot.isEmpty()
        ? QString()
        : readOriginalSkinPackage(originalRoot + "/TTPlayer.xml");

    SkinChoice followOriginal;
    followOriginal.selectionId = QString::fromLatin1(kSkinSelectionFollowOriginal);
    followOriginal.kind = SkinChoice::Kind::FollowOriginal;
    if (originalRoot.isEmpty()) {
        followOriginal.displayName = QStringLiteral("跟随原版当前皮肤（未找到原版配置）");
    } else if (currentOriginalPackage == "<Default_Skin>") {
        followOriginal.displayName = QStringLiteral("跟随原版当前皮肤（原版默认）");
    } else if (!currentOriginalPackage.isEmpty()) {
        followOriginal.displayName = QStringLiteral("跟随原版当前皮肤（%1）")
            .arg(QFileInfo(currentOriginalPackage).completeBaseName());
    } else {
        followOriginal.displayName = QStringLiteral("跟随原版当前皮肤");
    }
    choices.append(followOriginal);

    SkinChoice builtinDefault;
    builtinDefault.selectionId = QString::fromLatin1(kSkinSelectionBuiltinDefault);
    builtinDefault.displayName = QStringLiteral("原版默认（内建回退）");
    builtinDefault.kind = SkinChoice::Kind::BuiltinDefault;
    choices.append(builtinDefault);

    QSet<QString> seenDisplayNames;
    for (const auto& dir : candidateSkinDirectories(originalRoot)) {
        const auto entries = QDir(dir).entryInfoList({"*.skn"}, QDir::Files, QDir::Name | QDir::IgnoreCase);
        for (const auto& entry : entries) {
            if (isRarWrappedSkin(entry.absoluteFilePath())) {
                continue;
            }
            const QString display = displayNameForSkinPath(entry.fileName());
            const QString displayKey = display.toLower();
            if (seenDisplayNames.contains(displayKey)) {
                continue;
            }
            seenDisplayNames.insert(displayKey);

            SkinChoice fileChoice;
            fileChoice.selectionId = entry.canonicalFilePath().isEmpty()
                ? entry.absoluteFilePath()
                : entry.canonicalFilePath();
            fileChoice.sourcePath = fileChoice.selectionId;
            fileChoice.displayName = display;
            fileChoice.kind = SkinChoice::Kind::File;
            choices.append(fileChoice);
        }
    }

    return choices;
}

// 规范化皮肤选择 ID，返回标准化文件路径或预定义选项标识符。
// 规范化皮肤选择字符串，返回标准预定义选项或本地皮肤文件路径。
QString Application::normalizedSkinSelection(const QString& selection) const {
    if (selection.isEmpty()) {
        return QString::fromLatin1(kSkinSelectionFollowOriginal);
    }

    if (selection == QString::fromLatin1(kSkinSelectionFollowOriginal) ||
        selection == QString::fromLatin1(kSkinSelectionBuiltinDefault)) {
        return selection;
    }

    const QFileInfo info(selection);
    if (!info.exists()) {
        return selection;
    }

    const QString canonical = info.canonicalFilePath();
    return canonical.isEmpty() ? info.absoluteFilePath() : canonical;
}

// 根据当前选择加载对应皮肤，支持跟随原版、内置默认和本地路径。
// 根据皮肤选择 ID 加载对应皮肤，支持原版、内置默认和本地路径。
bool Application::loadSkinSelection(const QString& selectionId) {
    const QString normalized = normalizedSkinSelection(selectionId);
    const QString originalRoot = detectOriginalRoot();

    if (normalized == QString::fromLatin1(kSkinSelectionFollowOriginal)) {
        if (!originalRoot.isEmpty()) {
            const QString xmlPath = originalRoot + "/TTPlayer.xml";
            const QString packageName = readOriginalSkinPackage(xmlPath);
            if (packageName == "<Default_Skin>") {
                return skinEngine_.loadDefault();
            }

            const QString skinFile = normalizeSkinFileName(packageName);
            const QStringList candidates = {
                originalRoot + "/Skin/" + skinFile,
                QFileInfo(originalRoot).absolutePath() + "/build/Skin/" + skinFile
            };

            for (const auto& candidate : candidates) {
                if (QFileInfo::exists(candidate) && skinEngine_.loadFromFile(candidate)) {
                    return true;
                }
            }
        }

        return skinEngine_.loadDefault();
    }

    if (normalized == QString::fromLatin1(kSkinSelectionBuiltinDefault)) {
        return skinEngine_.loadDefault();
    }

    const QFileInfo info(normalized);
    if (info.exists()) {
        if (info.isDir()) {
            return skinEngine_.loadFromDirectory(info.absoluteFilePath());
        }
        return skinEngine_.loadFromFile(info.absoluteFilePath());
    }

    return false;
}

// 应用皮肤选择并可选保存到配置文件，同时维护窗口可见性和位置。
// 应用选定皮肤，并可选保存当前选择和布局状态。
bool Application::applySkinSelection(const QString& selectionId, bool persistSelection) {
    const QString normalized = normalizedSkinSelection(selectionId);
    if (persistSelection && !currentSkinSelection_.isEmpty() && normalized != currentSkinSelection_) {
        saveSkinLayoutSidecarForSelection(currentSkinSelection_);
    }

    QWidget* windows[] = {
        playerWindow_.get(),
        lyricWindow_.get(),
        eqWindow_.get(),
        playlistWindow_.get()
    };

    const QPoint playerPos = playerWindow_->pos();
    const bool playerVisible = playerWindow_->isVisible();
    const bool lyricVisible = auxLyricVisible_;
    const bool eqVisible = auxEqVisible_;
    const bool playlistVisible = auxPlaylistVisible_;

    suppressAuxVisibilitySync_ = true;
    for (QWidget* window : windows) {
        if (window) {
            window->setUpdatesEnabled(false);
            window->hide();
        }
    }

    if (!loadSkinSelection(normalized)) {
        qWarning() << "Application::applySkinSelection: Failed to load selected skin:" << normalized;
        qWarning() << "  raw selection:" << selectionId;
        if (QFileInfo(normalized).exists()) {
            qWarning() << "  normalized exists:" << normalized;
        } else {
            qWarning() << "  normalized does not exist:" << normalized;
        }
        for (QWidget* window : windows) {
            if (window) {
                window->setUpdatesEnabled(true);
            }
        }
        playerVisible ? playerWindow_->show() : playerWindow_->hide();
        lyricVisible ? lyricWindow_->show() : lyricWindow_->hide();
        eqVisible ? eqWindow_->show() : eqWindow_->hide();
        playlistVisible ? playlistWindow_->show() : playlistWindow_->hide();
        for (QWidget* window : windows) {
            forceImmediateRefresh(window);
        }
        app_.processEvents(QEventLoop::ExcludeUserInputEvents);
        suppressAuxVisibilitySync_ = false;
        if (trayIcon_) {
            trayIcon_->showMessage(
                QStringLiteral("TTPlayer Reborn"),
                QStringLiteral("切换皮肤失败: %1").arg(normalized),
                QSystemTrayIcon::Warning,
                2000);
        }
        return false;
    }

    currentSkinSelection_ = normalized;
    applySkin();

    const auto& layout = skinEngine_.skinData().layoutConfig;
    // 若新皮肤的 sidecar 中记录了可见性，则以 sidecar 为准；否则延续当前用户意图。
    const bool nextLyricVisible = layout.lyricWindow.hasVisible
        ? layout.lyricWindow.visible : lyricVisible;
    const bool nextEqVisible = layout.equalizerWindow.hasVisible
        ? layout.equalizerWindow.visible : eqVisible;
    const bool nextPlaylistVisible = layout.playlistWindow.hasVisible
        ? layout.playlistWindow.visible : playlistVisible;

    // 切换皮肤时保留当前主窗口位置。
    // 侧车窗口的绝对坐标来自其他会话，不能直接复用。
    playerWindow_->move(playerPos);
    playerVisible ? playerWindow_->show() : playerWindow_->hide();
    nextLyricVisible ? lyricWindow_->show() : lyricWindow_->hide();
    nextEqVisible ? eqWindow_->show() : eqWindow_->hide();
    nextPlaylistVisible ? playlistWindow_->show() : playlistWindow_->hide();
    layoutFromSkin();

    auxLyricVisible_ = nextLyricVisible;
    auxEqVisible_ = nextEqVisible;
    auxPlaylistVisible_ = nextPlaylistVisible;

    bindAuxWindowsToMain();
    syncAuxWindowToggleStates();
    snapManager_->rebuildSnapGraph();

    for (QWidget* window : windows) {
        if (window) {
            window->setUpdatesEnabled(true);
            forceImmediateRefresh(window);
        }
    }
    app_.processEvents(QEventLoop::ExcludeUserInputEvents);
    suppressAuxVisibilitySync_ = false;

    if (persistSelection) {
        config_.setSkinPath(normalized);
    }

    return true;
}

// 根据选择 ID 解析实际皮肤文件的绝对路径，供侧车布局保存使用。
// 解析皮肤选择 ID 到实际皮肤文件路径，用于保存或恢复皮肤侧车布局。
QString Application::resolveSkinSelectionFilePath(const QString& selectionId) const {
    const QString normalized = normalizedSkinSelection(selectionId);
    const QString originalRoot = detectOriginalRoot();

    if (normalized == QString::fromLatin1(kSkinSelectionFollowOriginal)) {
        if (originalRoot.isEmpty()) {
            return {};
        }

        const QString packageName = readOriginalSkinPackage(originalRoot + "/TTPlayer.xml");
        const QString skinFile = normalizeSkinFileName(packageName);
        const QStringList candidates = {
            originalRoot + "/Skin/" + skinFile,
            QFileInfo(originalRoot).absolutePath() + "/build/Skin/" + skinFile
        };

        for (const auto& candidate : candidates) {
            const QFileInfo fi(candidate);
            if (fi.exists() && fi.isFile()) {
                return fi.canonicalFilePath().isEmpty() ? fi.absoluteFilePath() : fi.canonicalFilePath();
            }
        }
        return {};
    }

    if (normalized == QString::fromLatin1(kSkinSelectionBuiltinDefault)) {
        const QStringList searchPaths = {
            "/home/john/Downloads/TTPlayer-main/TTPlayerv5.7.9/Skin/Classic.skn",
            "/home/john/Downloads/TTPlayer-main/build/Skin/Classic.skn",
            QDir::currentPath() + "/Skin/Classic.skn",
            QDir::currentPath() + "/../build/Skin/Classic.skn",
            QDir::currentPath() + "/../../build/Skin/Classic.skn",
            QDir::currentPath() + "/../TTPlayerv5.7.9/Skin/Classic.skn",
            QDir::currentPath() + "/../../TTPlayerv5.7.9/Skin/Classic.skn",
            "/home/john/.wine/drive_c/Program Files (x86)/TTPlayer/Skin/Classic.skn",
            QDir::currentPath() + "/skins/Classic.skn",
        };
        for (const auto& path : searchPaths) {
            const QFileInfo fi(path);
            if (fi.exists() && fi.isFile()) {
                return fi.canonicalFilePath().isEmpty() ? fi.absoluteFilePath() : fi.canonicalFilePath();
            }
        }
        return {};
    }

    const QFileInfo fi(normalized);
    if (!fi.exists() || !fi.isFile()) {
        return {};
    }
    return fi.canonicalFilePath().isEmpty() ? fi.absoluteFilePath() : fi.canonicalFilePath();
}

// 将当前窗口布局保存为皮肤侧车 XML，以便下次加载相同皮肤时恢复布局。
// 将当前窗口布局保存为皮肤侧车 XML，以便下次加载同一皮肤时恢复布局。
void Application::saveSkinLayoutSidecarForSelection(const QString& selectionId) const {
    const QString skinFilePath = resolveSkinSelectionFilePath(selectionId);
    if (skinFilePath.isEmpty()) {
        return;
    }

    const QString xmlPath = skinFilePath + ".xml";
    QFile file(xmlPath);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        qWarning() << "Failed to write skin sidecar xml:" << xmlPath;
        return;
    }

    const QRect playerRect(playerWindow_->pos(), playerWindow_->size());
    const QRect lyricRect(lyricWindow_->pos(), lyricWindow_->size());
    const QRect eqRect(eqWindow_->pos(), eqWindow_->size());
    const QRect playlistRect(playlistWindow_->pos(), playlistWindow_->size());

    QXmlStreamWriter xml(&file);
    xml.setAutoFormatting(true);
    xml.writeStartDocument();
    xml.writeStartElement("ttplayer");
    xml.writeAttribute("version", "5.7.9");
    xml.writeStartElement("Player");
    xml.writeAttribute("PlayerWnd", encodeSkinRect(playerRect));
    xml.writeAttribute("PlayerWnd2", "0,0,0,0");
    xml.writeAttribute("LyricWnd", encodeSkinRect(lyricRect));
    xml.writeAttribute("LyricWnd2", "0,0,0,0");
    xml.writeAttribute("EqualizerWnd", encodeSkinRect(eqRect));
    xml.writeAttribute("PlayListWnd", encodeSkinRect(playlistRect));
    xml.writeAttribute("LyricVisible", auxLyricVisible_ ? "1" : "0");
    xml.writeAttribute("EqualizerVisible", auxEqVisible_ ? "1" : "0");
    xml.writeAttribute("PlayListVisible", auxPlaylistVisible_ ? "1" : "0");
    xml.writeEndElement(); // Player 元素结束
    xml.writeEndElement(); // ttplayer 根元素结束
    xml.writeEndDocument();
}

// 依据配置文件中记录的皮肤路径，加载首选皮肤并在失败时回退。
// 按配置加载当前皮肤，失败时依次回退到原版跟随和内置默认。
void Application::loadSkin() {
    const QString configuredSelection = normalizedSkinSelection(config_.skinPath());
    if (loadSkinSelection(configuredSelection)) {
        currentSkinSelection_ = configuredSelection;
        qDebug() << "Loaded skin selection:" << configuredSelection << skinEngine_.skinName();
        return;
    }

    const QString followOriginal = QString::fromLatin1(kSkinSelectionFollowOriginal);
    if (configuredSelection != followOriginal && loadSkinSelection(followOriginal)) {
        currentSkinSelection_ = followOriginal;
        qDebug() << "Fell back to original-selected skin";
        return;
    }

    const QString builtinDefault = QString::fromLatin1(kSkinSelectionBuiltinDefault);
    if (configuredSelection != builtinDefault && loadSkinSelection(builtinDefault)) {
        currentSkinSelection_ = builtinDefault;
        qDebug() << "Fell back to built-in default skin";
        return;
    }

    qWarning() << "No usable skin source found";
}

// 将已加载的皮肤数据应用到各窗口，实现视觉和布局一致性。
// 将已加载的皮肤数据分发到主窗口和所有辅助窗口。
void Application::applySkin() {
    const auto& skin = skinEngine_.skinData();
    playerWindow_->applySkin(skin);
    lyricWindow_->applySkin(skin);
    lyricWindow_->setAlwaysOnTopState(config_.alwaysOnTop());
    eqWindow_->applySkin(skin);
    playlistWindow_->applySkin(skin);
}

// 根据当前皮肤的布局配置计算并安排子窗口位置。
// 根据当前皮肤的布局配置计算所有辅助窗口的大小和位置。
void Application::layoutFromSkin() {
    const auto& skin = skinEngine_.skinData();
    const auto& layout = skin.layoutConfig;

    // 这里不调整主窗口位置，调用者负责主窗口的最终位置。
    // restoreState 使用配置中的位置，applySkinSelection 保持当前主窗口位置。

    const QPoint mainPos = playerWindow_->pos();

    // 如果侧车配置包含玩家窗口位置，则计算子窗口相对于侧车主窗口的偏移量。
    // 这样即便当前玩家位置不同，也能保留侧车原有的布局（并排或垂直堆叠）。
    const QPoint sidecarPlayerOrigin = layout.playerWindow.hasGeometry
        ? layout.playerWindow.geometry.topLeft()
        : mainPos;

    auto placeWindow = [&](QWidget* window,
                           const SkinWindow& skinWindow,
                           const SkinWindowLayout& windowLayout,
                           const QPoint& fallback) {
        if (!window) {
            return;
        }

        if (windowLayout.hasGeometry) {
            // 将侧车中的绝对位置转换为相对于侧车主窗口的偏移量，
            // 再应用到当前主窗口位置。
            const QPoint relOffset = windowLayout.geometry.topLeft() - sidecarPlayerOrigin;
            window->resize(windowLayout.geometry.size().expandedTo(window->minimumSize()));
            window->move(mainPos + relOffset);
        } else if (!skinWindow.defaultPosition.isEmpty()) {
            window->resize(skinWindow.defaultPosition.size().expandedTo(window->minimumSize()));
            window->move(mainPos + skinWindow.defaultPosition.topLeft());
        } else {
            window->resize(window->minimumSize());
            window->move(mainPos + fallback);
        }
    };

    placeWindow(eqWindow_.get(), skin.equalizerWindow, layout.equalizerWindow,
                QPoint(0, playerWindow_->height() + kDefaultSnapGapPx));
    placeWindow(playlistWindow_.get(), skin.playlistWindow, layout.playlistWindow,
                QPoint(0, playerWindow_->height() + eqWindow_->height() + 2 * kDefaultSnapGapPx));
    placeWindow(lyricWindow_.get(), skin.lyricWindow, layout.lyricWindow,
                QPoint(0, playerWindow_->height() + eqWindow_->height() + playlistWindow_->height()
                       + 3 * kDefaultSnapGapPx));
}

// 恢复上次保存的主窗口位置，并根据当前皮肤重新布局辅助窗口。
void Application::restoreState() {
    if (configLoaded_) {
        const QSize playerSize = config_.playerSize();
        if (playerSize.width() > 0 && playerSize.height() > 0) {
            playerWindow_->resize(playerSize.expandedTo(playerWindow_->minimumSize()));
        }
        playerWindow_->move(config_.playerPos());
    }

    layoutFromSkin();

    if (configLoaded_) {
        auto restoreAuxWindow = [](QWidget* window, const QPoint& pos, const QSize& size) {
            if (!window) {
                return;
            }
            if (size.width() > 0 && size.height() > 0) {
                window->resize(size.expandedTo(window->minimumSize()));
            }
            window->move(pos);
        };
        restoreAuxWindow(lyricWindow_.get(), config_.lyricPos(), config_.lyricSize());
        restoreAuxWindow(eqWindow_.get(), config_.eqPos(), config_.eqSize());
        restoreAuxWindow(playlistWindow_.get(), config_.playlistPos(), config_.playlistSize());
    }

    playlistWindow_->setDividerPosition(config_.playlistSplitPos());
}

// 退出或切换皮肤时保存当前状态到配置文件。
// 保存当前音量、窗口位置、可见性、播放列表状态和均衡器设置到配置文件。
void Application::saveState() {
    config_.setVolume(engine_.volume());
    config_.setMuted(engine_.isMuted());
    config_.setPlayerPos(playerWindow_->pos());
    config_.setPlayerSize(playerWindow_->size());
    config_.setLyricPos(lyricWindow_->pos());
    config_.setLyricSize(lyricWindow_->size());
    config_.setEqPos(eqWindow_->pos());
    config_.setEqSize(eqWindow_->size());
    config_.setPlaylistPos(playlistWindow_->pos());
    config_.setPlaylistSize(playlistWindow_->size());
    config_.setPlaylistSplitPos(playlistWindow_->dividerPosition());
    config_.setLastFile(engine_.currentFilePath());
    config_.setRepeatMode(playlistWindow_->repeatMode());
    config_.setShuffle(playlistWindow_->shuffle());
    config_.setAlwaysOnTop(playerWindow_->windowFlags().testFlag(Qt::WindowStaysOnTopHint));

    // DEBUG: 输出保存时的可见性状态
    qDebug() << "=== saveState visibility ===";
    qDebug() << "  lyric  isVisible:" << lyricWindow_->isVisible()
             << "config:" << config_.lyricVisible()
             << "auxVisible:" << auxLyricVisible_;
    qDebug() << "  eq     isVisible:" << eqWindow_->isVisible()
             << "config:" << config_.eqVisible()
             << "auxVisible:" << auxEqVisible_;
    qDebug() << "  playlist isVisible:" << playlistWindow_->isVisible()
             << "config:" << config_.playlistVisible()
             << "auxVisible:" << auxPlaylistVisible_;

    // 使用专门维护的"用户意图可见性"变量，不受最小化到托盘影响。
    config_.setLyricVisible(auxLyricVisible_);
    config_.setEqVisible(auxEqVisible_);
    config_.setPlaylistVisible(auxPlaylistVisible_);

    // 保存均衡器状态与频段设置。
    config_.setEqEnabled(engine_.dspChain().equalizer.isEnabled());
    config_.setEqPreamp(engine_.dspChain().equalizer.preamp());
    for (int i = 0; i < 10; i++)
        config_.setEqBand(i, engine_.dspChain().equalizer.bandGain(i));

    const QString configPath = Config::defaultPath();
    if (!config_.save(configPath)) {
        qWarning() << "Application::saveState: failed to save config:" << configPath;
    }

    // 保存播放列表到 TTBL（与 Config 同步时机，均在关闭时保存）。
    {
        QString playlistDir = config_.playlistDir();
        if (playlistDir.isEmpty()) {
            playlistDir = QDir(QCoreApplication::applicationDirPath())
                              .absoluteFilePath(QStringLiteral("PlayList"));
            config_.setPlaylistDir(playlistDir);
        }
        const int activeList = playlistWindow_->saveToTtblDir(playlistDir);
        config_.setPlaylistCount(playlistWindow_->tabCount());
        config_.setActiveList(activeList);
        // 写回更新后的 PlayLists / ActiveList 到 XML（再次保存）
        config_.save(configPath);
    }
}

// 打开文件对话框以选择一个或多个音频文件，并将它们添加到播放列表。
// 处理“打开文件”请求，弹出文件选择对话框并将选中的文件加载到播放列表。
void Application::onOpenFile() {
    const QString musicRoot = QStringLiteral("/media/john/新加卷/music");
    const QString startDir = QFileInfo::exists(musicRoot) ? musicRoot : QDir::homePath();

    QStringList files = QFileDialog::getOpenFileNames(
        playerWindow_.get(),
        QStringLiteral("打开音频文件"),
        startDir,
        QStringLiteral("音频文件 (*.mp3 *.flac *.wav *.ogg *.ape *.aac *.m4a *.wma *.mpc *.tak *.tta *.ac3 *.dts *.opus *.cue);;所有文件 (*)")
    );

    if (files.isEmpty()) return;

    playlistWindow_->importFilesWithProgress(files, QStringLiteral("正在导入文件"));
    playFile(files.first());
}

// 处理当前曲目播放结束事件，自动切换到下一首。
// 处理曲目播放结束事件，自动调度下一首播放。
void Application::onTrackFinished() {
    QString next = playlistWindow_->nextFile();
    if (!next.isEmpty()) {
        playFile(next);
    }
}

// 处理“下一首”操作。
// 响应“下一首”命令，切换到播放列表中的下一首。
void Application::onNext() {
    QString next = playlistWindow_->nextFile();
    if (!next.isEmpty()) playFile(next);
}

// 处理“上一首”操作。
// 响应“上一首”命令，切换到播放列表中的上一首。
void Application::onPrev() {
    QString prev = playlistWindow_->prevFile();
    if (!prev.isEmpty()) playFile(prev);
}

// 切换歌词窗口可见性，并同步保存配置。
// 显示或隐藏歌词窗口，并同步状态到配置和窗口吸附管理。
void Application::onLyricToggled(bool visible) {
    auxLyricVisible_ = visible;
    if (visible) {
        lyricWindow_->show();
        bindAuxWindowsToMain();
    } else {
        lyricWindow_->hide();
    }
    syncAuxWindowToggleStates();
    snapManager_->rebuildSnapGraph();
}

// 切换均衡器窗口可见性，并同步配置状态。
// 显示或隐藏均衡器窗口，并同步状态到配置和窗口吸附管理。
void Application::onEqualizerToggled(bool visible) {
    auxEqVisible_ = visible;
    if (visible) {
        eqWindow_->show();
        bindAuxWindowsToMain();
    } else {
        eqWindow_->hide();
    }
    syncAuxWindowToggleStates();
    snapManager_->rebuildSnapGraph();
}

// 切换播放列表窗口可见性，并同步配置状态。
// 显示或隐藏播放列表窗口，并同步状态到配置和窗口吸附管理。
void Application::onPlaylistToggled(bool visible) {
    auxPlaylistVisible_ = visible;
    if (visible) {
        playlistWindow_->show();
        bindAuxWindowsToMain();
    } else {
        playlistWindow_->hide();
    }
    syncAuxWindowToggleStates();
    snapManager_->rebuildSnapGraph();
}

// 播放列表中选择文件后开始播放该文件。
// 处理播放列表中选中文件，直接播放该文件。
void Application::onFileSelected(const QString& filePath) {
    const QString selectedPath = filePath;
    bool fromDoubleClick = false;
    const qint64 userSwitchStartMs =
        playlistWindow_->takeLastUserSwitchRequestMs(selectedPath, &fromDoubleClick);
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const qint64 dispatchDelayMs = (userSwitchStartMs > 0) ? (nowMs - userSwitchStartMs) : -1;
    qDebug().noquote()
        << QStringLiteral("[SwitchPerf][Application] onFileSelected path=\"%1\" tab=%2 index=%3 from_double_click=%4 dispatch_delay=%5ms")
               .arg(selectedPath)
               .arg(playlistWindow_->activeTabIndex())
               .arg(playlistWindow_->currentIndex())
               .arg(fromDoubleClick ? 1 : 0)
               .arg(dispatchDelayMs);
    // 若元数据尚未加载完毕，请求立即优先加载（用于 MPRIS 元数据和排序显示）。
    const int activeTab = playlistWindow_->activeTabIndex();
    const int idx = playlistWindow_->currentIndex();
    if (idx >= 0)
        playlistWindow_->requestPriorityMetadata(activeTab, idx);
    playFile(selectedPath, userSwitchStartMs);
}

// 小窗模式请求处理，暂时只提供接口。
// TODO: 实现小窗模式时，这里应切换到迷你窗口布局。
void Application::onMiniModeRequested() {
    qDebug() << "Application::onMiniModeRequested: mini mode requested";
}

// 窗口最小化请求处理，将主窗口和所有辅助窗口隐藏到系统托盘。
void Application::onMinimizeRequested() {
    suppressAuxVisibilitySync_ = true;
    playerWindow_->hide();
    lyricWindow_->hide();
    eqWindow_->hide();
    playlistWindow_->hide();
    suppressAuxVisibilitySync_ = false;
    if (trayIcon_) {
        trayIcon_->showMessage(
            QStringLiteral("TTPlayer Reborn"),
            QStringLiteral("已最小化到系统托盘，双击托盘图标可恢复。"),
            QSystemTrayIcon::Information,
            1500);
    }
}

// 将主窗口及当前可见的辅助窗口恢复到前台。
// 恢复主窗口及可见辅助窗口，并重新绑定窗口组。
void Application::onShowMainWindow() {
    playerWindow_->show();
    playerWindow_->raise();
    playerWindow_->activateWindow();

    if (auxPlaylistVisible_) playlistWindow_->show();
    if (auxLyricVisible_) lyricWindow_->show();
    if (auxEqVisible_) eqWindow_->show();
    bindAuxWindowsToMain();
    syncAuxWindowToggleStates();
}

// 将辅助窗口的当前可见性同步到主窗口上的切换按钮状态。
// 同步主窗口中辅助窗口切换项的选中状态。
void Application::syncAuxWindowToggleStates() {
    const bool lyricVis = auxLyricVisible_;
    const bool eqVis = auxEqVisible_;
    const bool playlistVis = auxPlaylistVisible_;

    if (playerWindow_) {
        playerWindow_->setAuxWindowToggleStates(lyricVis, eqVis, playlistVis);
    }

    // 同步托盘菜单 checked 状态，屏蔽信号避免触发 toggled 回调。
    if (trayLyricAction_) {
        QSignalBlocker b(trayLyricAction_);
        trayLyricAction_->setChecked(lyricVis);
    }
    if (trayEqAction_) {
        QSignalBlocker b(trayEqAction_);
        trayEqAction_->setChecked(eqVis);
    }
    if (trayPlaylistAction_) {
        QSignalBlocker b(trayPlaylistAction_);
        trayPlaylistAction_->setChecked(playlistVis);
    }
}

// 绑定辅助窗口到主窗口，使它们成为同一窗口组的一部分。
// 将辅助窗口设置为主窗口的瞬态子窗口，保证窗口分组和置顶行为一致。
void Application::bindAuxWindowsToMain() {
    if (!playerWindow_) {
        return;
    }

    QWindow* mainHandle = playerWindow_->windowHandle();
    if (!mainHandle) {
        return;
    }

    auto bindOne = [mainHandle](QWidget* window) {
        if (!window) {
            return;
        }
        QWindow* childHandle = window->windowHandle();
        if (!childHandle) {
            return;
        }
        childHandle->setTransientParent(mainHandle);
    };

    bindOne(lyricWindow_.get());
    bindOne(eqWindow_.get());
    bindOne(playlistWindow_.get());
}

// 切换播放/暂停状态。
// 切换当前播放状态：播放和暂停之间切换。
void Application::onTogglePlayPause() {
    if (engine_.state() == AudioEngine::Playing) {
        engine_.pause();
    } else {
        engine_.play();
    }
}

// 处理系统托盘图标点击事件，左键或双击恢复主窗口。
// 处理系统托盘图标激活事件，单击或双击恢复主窗口。
void Application::onTrayActivated(QSystemTrayIcon::ActivationReason reason) {
    if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) {
        onShowMainWindow();
    }
}

// 右键菜单请求处理，显示托盘菜单作为上下文菜单。
// 在主窗口请求上下文菜单时显示托盘菜单。
void Application::onPlayerContextMenuRequested(const QPoint& globalPos) {
    if (trayMenu_) {
        rebuildSkinMenu();
        trayMenu_->exec(globalPos);
    }
}

void Application::initializeGlobalShortcuts() {
    if (!playerWindow_) {
        return;
    }

    const auto installShortcut = [this](const QString& sequence,
                                        const std::function<void()>& handler) {
        auto* shortcut = new QShortcut(QKeySequence(sequence), playerWindow_.get());
        shortcut->setContext(Qt::ApplicationShortcut);
        QObject::connect(shortcut, &QShortcut::activated, this, handler);
    };

    installShortcut(QStringLiteral("Ctrl+Alt+N"), [this]() { applyNextSkinTest(); });
    installShortcut(QStringLiteral("Ctrl+Alt+M"), [this]() { applyPreviousSkinTest(); });
}

// 导入调试音乐目录下所有支持音频格式文件到播放列表。
// 导入调试目录中的所有音频文件到播放列表中。
void Application::onImportDebugMusicFolder() {
    const QString root = QStringLiteral("/media/john/新加卷/music");
    if (!QFileInfo::exists(root)) {
        if (trayIcon_) {
            trayIcon_->showMessage(
                QStringLiteral("TTPlayer Reborn"),
                QStringLiteral("未找到调试目录: /media/john/新加卷/music"),
                QSystemTrayIcon::Warning,
                2000);
        }
        return;
    }

    QStringList patterns = {"*.mp3", "*.flac", "*.wav", "*.ogg", "*.ape", "*.aac", "*.m4a",
                            "*.wma", "*.mpc", "*.tak", "*.tta", "*.ac3", "*.dts", "*.opus"};

    QStringList files;
    QDirIterator it(root, patterns, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        files << it.next();
    }

    if (files.isEmpty()) {
        if (trayIcon_) {
            trayIcon_->showMessage(
                QStringLiteral("TTPlayer Reborn"),
                QStringLiteral("调试目录中没有找到可播放音频文件。"),
                QSystemTrayIcon::Information,
                2000);
        }
        return;
    }

    playlistWindow_->importFilesWithProgress(files, QStringLiteral("正在导入文件夹"));
    // 仅加载文件，不自动开始播放。
}

// 置顶状态切换回调，保存配置并应用到所有窗口。
// 处理置顶切换事件，将状态保存到配置并应用到所有窗口。
void Application::onAlwaysOnTopToggled(bool enabled) {
    config_.setAlwaysOnTop(enabled);
    applyAlwaysOnTop(enabled);
}

// 将“窗口置顶”标志同时应用到所有窗口，并保持可见状态不变。
// 将窗口置顶标志应用到主窗口及所有辅助窗口。
void Application::applyAlwaysOnTop(bool enabled) {
    QWidget* windows[] = {
        playerWindow_.get(),
        lyricWindow_.get(),
        eqWindow_.get(),
        playlistWindow_.get()
    };

    for (QWidget* window : windows) {
        if (!window) {
            continue;
        }

        const bool wasVisible = window->isVisible();
        const QPoint oldPos = window->pos();
        window->setWindowFlag(Qt::WindowStaysOnTopHint, enabled);
        window->move(oldPos);
        if (wasVisible) {
            window->show();
        }
    }

    if (lyricWindow_) {
        lyricWindow_->setAlwaysOnTopState(enabled);
    }
}

// 创建系统托盘菜单，包括播放控制、皮肤切换和窗口显示选项。
// 创建并初始化系统托盘菜单及其命令项。
void Application::createTrayMenu() {
    initializeGlobalShortcuts();

    if (!QSystemTrayIcon::isSystemTrayAvailable()) {
        qWarning() << "System tray is not available on this desktop environment";
        return;
    }

    trayMenu_ = std::make_unique<QMenu>();
    trayIcon_ = std::make_unique<QSystemTrayIcon>(
        app_.style()->standardIcon(QStyle::SP_MediaPlay), this);

    auto* showMainAction = trayMenu_->addAction(QStringLiteral("显示主窗口"));
    connect(showMainAction, &QAction::triggered, this, &Application::onShowMainWindow);

    trayMenu_->addSeparator();

    auto* openAction = trayMenu_->addAction(QStringLiteral("打开文件..."));
    connect(openAction, &QAction::triggered, this, &Application::onOpenFile);

    auto* importDebugAction = trayMenu_->addAction(QStringLiteral("导入调试目录音乐"));
    connect(importDebugAction, &QAction::triggered, this, &Application::onImportDebugMusicFolder);

    skinMenu_ = trayMenu_->addMenu(QStringLiteral("切换皮肤"));
    connect(trayMenu_.get(), &QMenu::aboutToShow, this, &Application::rebuildSkinMenu);
    connect(trayMenu_.get(), &QMenu::aboutToHide, this, [this]() {
        if (pendingSkinSelection_.isEmpty()) {
            return;
        }
        QTimer::singleShot(0, this, &Application::applyPendingSkinSelection);
    });

    auto* playPauseAction = trayMenu_->addAction(QStringLiteral("播放/暂停"));
    connect(playPauseAction, &QAction::triggered, this, &Application::onTogglePlayPause);

    auto* stopAction = trayMenu_->addAction(QStringLiteral("停止"));
    connect(stopAction, &QAction::triggered, this, [this]() { engine_.stop(); });

    auto* prevAction = trayMenu_->addAction(QStringLiteral("上一首"));
    connect(prevAction, &QAction::triggered, this, &Application::onPrev);

    auto* nextAction = trayMenu_->addAction(QStringLiteral("下一首"));
    connect(nextAction, &QAction::triggered, this, &Application::onNext);

    auto* playModeMenu = trayMenu_->addMenu(QStringLiteral("播放模式"));
    auto* playModeGroup = new QActionGroup(playModeMenu);
    playModeGroup->setExclusive(true);
    auto addModeAction = [this, playModeMenu, playModeGroup](const QString& text, int repeatMode, bool shuffle) {
        QAction* action = playModeMenu->addAction(text);
        action->setCheckable(true);
        action->setActionGroup(playModeGroup);
        action->setChecked(playlistWindow_->repeatMode() == repeatMode && playlistWindow_->shuffle() == shuffle);
        connect(action, &QAction::triggered, this, [this, repeatMode, shuffle]() {
            playlistWindow_->setPlaybackMode(repeatMode, shuffle);
        });
        return action;
    };

    addModeAction(QStringLiteral("顺序播放"), 0, false);
    addModeAction(QStringLiteral("单曲循环"), 1, false);
    addModeAction(QStringLiteral("列表循环"), 2, false);
    addModeAction(QStringLiteral("随机播放"), 2, true);

    auto* muteAction = trayMenu_->addAction(QStringLiteral("静音切换"));
    connect(muteAction, &QAction::triggered, this, [this]() {
        engine_.setMuted(!engine_.isMuted());
    });

    auto* volUpAction = trayMenu_->addAction(QStringLiteral("音量 +5"));
    connect(volUpAction, &QAction::triggered, this, [this]() {
        engine_.setVolume(std::min(100, engine_.volume() + 5));
    });

    auto* volDownAction = trayMenu_->addAction(QStringLiteral("音量 -5"));
    connect(volDownAction, &QAction::triggered, this, [this]() {
        engine_.setVolume(std::max(0, engine_.volume() - 5));
    });

    trayMenu_->addSeparator();

    trayLyricAction_ = trayMenu_->addAction(QStringLiteral("歌词窗口"));
    trayLyricAction_->setCheckable(true);
    trayLyricAction_->setChecked(auxLyricVisible_);
    connect(trayLyricAction_, &QAction::toggled, this, &Application::onLyricToggled);

    trayEqAction_ = trayMenu_->addAction(QStringLiteral("均衡器"));
    trayEqAction_->setCheckable(true);
    trayEqAction_->setChecked(auxEqVisible_);
    connect(trayEqAction_, &QAction::toggled, this, &Application::onEqualizerToggled);

    trayPlaylistAction_ = trayMenu_->addAction(QStringLiteral("播放列表"));
    trayPlaylistAction_->setCheckable(true);
    trayPlaylistAction_->setChecked(auxPlaylistVisible_);
    connect(trayPlaylistAction_, &QAction::toggled, this, &Application::onPlaylistToggled);

    auto* alwaysOnTopAction = trayMenu_->addAction(QStringLiteral("窗口置顶"));
    alwaysOnTopAction->setCheckable(true);
    alwaysOnTopAction->setChecked(config_.alwaysOnTop());
    connect(alwaysOnTopAction, &QAction::toggled, this, &Application::onAlwaysOnTopToggled);

    trayMenu_->addSeparator();

    auto* quitAction = trayMenu_->addAction(QStringLiteral("退出"));
    connect(quitAction, &QAction::triggered, &app_, &QApplication::quit);

    trayIcon_->setContextMenu(trayMenu_.get());
    connect(trayIcon_.get(), &QSystemTrayIcon::activated, this, &Application::onTrayActivated);
}

// 重新构建托盘菜单中的皮肤选择列表。
// 重新构建托盘菜单中皮肤切换的选项列表。
void Application::rebuildSkinMenu() {
    if (!skinMenu_) {
        return;
    }

    skinMenu_->clear();
    if (skinActionGroup_) {
        delete skinActionGroup_;
    }
    skinActionGroup_ = new QActionGroup(skinMenu_);
    skinActionGroup_->setExclusive(true);
    availableSkins_ = discoverAvailableSkins();

    const QString activeSelection = currentSkinSelection_.isEmpty()
        ? normalizedSkinSelection(config_.skinPath())
        : currentSkinSelection_;

    for (const auto& choice : availableSkins_) {
        QAction* action = skinMenu_->addAction(choice.displayName);
        action->setCheckable(true);
        action->setChecked(choice.selectionId == activeSelection);
        action->setActionGroup(skinActionGroup_);
        connect(action, &QAction::triggered, this, [this, selectionId = choice.selectionId]() {
            queueSkinSelection(selectionId, true);
        });
    }
}

void Application::queueSkinSelection(const QString& selectionId, bool persistSelection) {
    pendingSkinSelection_ = selectionId;
    pendingSkinPersistSelection_ = persistSelection;

    if (!trayMenu_ || !trayMenu_->isVisible()) {
        QTimer::singleShot(0, this, &Application::applyPendingSkinSelection);
    }
}

void Application::applyPendingSkinSelection() {
    if (pendingSkinSelection_.isEmpty()) {
        return;
    }
    if (trayMenu_ && trayMenu_->isVisible()) {
        return;
    }

    const QString selectionId = pendingSkinSelection_;
    const bool persistSelection = pendingSkinPersistSelection_;
    pendingSkinSelection_.clear();
    pendingSkinPersistSelection_ = false;

    applySkinSelection(selectionId, persistSelection);
}

void Application::applyNextSkinTest() {
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (lastNextSkinTriggerMs_ != 0 && now - lastNextSkinTriggerMs_ < 150) {
        return;
    }
    lastNextSkinTriggerMs_ = now;

    const auto skins = discoverAvailableSkins();
    if (skins.isEmpty()) {
        return;
    }

    const QString activeSelection = currentSkinSelection_.isEmpty()
        ? normalizedSkinSelection(config_.skinPath())
        : currentSkinSelection_;

    int activeIndex = 0;
    for (int i = 0; i < skins.size(); ++i) {
        if (skins[i].selectionId == activeSelection) {
            activeIndex = i;
            break;
        }
    }

    const QString nextSelection = skins[(activeIndex + 1) % skins.size()].selectionId;
    QTimer::singleShot(0, this, [this, nextSelection]() {
        applySkinSelection(nextSelection, true);
    });
}

void Application::applyPreviousSkinTest() {
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    if (lastNextSkinTriggerMs_ != 0 && now - lastNextSkinTriggerMs_ < 150) {
        return;
    }
    lastNextSkinTriggerMs_ = now;

    const auto skins = discoverAvailableSkins();
    if (skins.isEmpty()) {
        return;
    }

    const QString activeSelection = currentSkinSelection_.isEmpty()
        ? normalizedSkinSelection(config_.skinPath())
        : currentSkinSelection_;

    int activeIndex = 0;
    for (int i = 0; i < skins.size(); ++i) {
        if (skins[i].selectionId == activeSelection) {
            activeIndex = i;
            break;
        }
    }

    const int previousIndex = (activeIndex - 1 + skins.size()) % skins.size();
    const QString previousSelection = skins[previousIndex].selectionId;
    QTimer::singleShot(0, this, [this, previousSelection]() {
        applySkinSelection(previousSelection, true);
    });
}

// 加载并播放指定文件，同时更新歌词窗口的曲目信息和播放列表当前项。
void Application::playFile(const QString& filePath, qint64 userSwitchStartMs) {
    QElapsedTimer totalTimer;
    totalTimer.start();
    QElapsedTimer phaseTimer;

    phaseTimer.start();
    if (engine_.loadFile(filePath)) {
        const qint64 loadMs = phaseTimer.elapsed();

        phaseTimer.restart();
        engine_.play();
        const qint64 playMs = phaseTimer.elapsed();

        phaseTimer.restart();
        playlistWindow_->setCurrentFile(filePath);
        const qint64 playlistSyncMs = phaseTimer.elapsed();

        // 更新歌词窗口的当前曲目信息。
        phaseTimer.restart();
        QFileInfo fi(filePath);
        QString title = engine_.currentTitle();
        if (title.isEmpty()) {
            title = fi.completeBaseName();
        }
        const QString artist = engine_.currentArtist();

        // 尝试加载与当前音频文件同名的 LRC 歌词文件。
        QString lrcPath = fi.absolutePath() + "/" + fi.completeBaseName() + ".lrc";
        if (QFileInfo::exists(lrcPath)) {
            lyricWindow_->loadLrc(lrcPath);
        } else {
            lyricWindow_->clearLrc();
        }
        lyricWindow_->setTrackInfo(title, artist);

        const qint64 lyricUpdateMs = phaseTimer.elapsed();
        const qint64 totalMs = totalTimer.elapsed();
        const qint64 endToEndMs = (userSwitchStartMs > 0)
            ? (QDateTime::currentMSecsSinceEpoch() - userSwitchStartMs)
            : -1;
        qDebug().noquote()
            << QStringLiteral("[SwitchPerf][Application] playFile ok path=\"%1\" total=%2ms load=%3ms play=%4ms playlist_sync=%5ms lyric_update=%6ms e2e_from_user=%7ms")
                   .arg(filePath)
                   .arg(totalMs)
                   .arg(loadMs)
                   .arg(playMs)
                   .arg(playlistSyncMs)
                   .arg(lyricUpdateMs)
                   .arg(endToEndMs);
    } else {
        qDebug().noquote()
            << QStringLiteral("[SwitchPerf][Application] playFile failed path=\"%1\" total=%2ms e2e_from_user=%3ms")
                   .arg(filePath)
                   .arg(totalTimer.elapsed())
                   .arg((userSwitchStartMs > 0) ? (QDateTime::currentMSecsSinceEpoch() - userSwitchStartMs) : -1);
    }
}

#ifdef QT_DBUS_LIB
#include "Application.moc"
#endif
