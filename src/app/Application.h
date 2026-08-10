#pragma once
#include "Config.h"
#include "audio/AudioEngine.h"
#include "skin/SkinEngine.h"
#include "ui/PlayerWindow.h"
#include "ui/LyricWindow.h"
#include "ui/EqualizerWindow.h"
#include "ui/PlaylistWindow.h"
#include "ui/WindowSnapManager.h"
#include <QApplication>
#include <QSystemTrayIcon>
#include <QMenu>
#include <QActionGroup>
#include <QVector>
#include <memory>

#ifdef QT_DBUS_LIB
class MprisAdaptor;
class MprisPlayerAdaptor;
#endif
#ifdef Q_OS_WIN
class WinMediaSession;  // 实现在 Application.cpp 中
#endif

// 应用程序顶层管理类，负责启动、配置、皮肤加载、托盘菜单、窗口布局和播放控制。
class Application : public QObject {
    Q_OBJECT
public:
    // 构造函数，初始化 Qt 应用、音频引擎、各窗口和窗口吸附管理器。
    explicit Application(int& argc, char** argv);
    ~Application();

    // 启动应用程序主循环，执行窗口显示、皮肤加载和事件处理。
    int run();

#ifdef QT_DBUS_LIB
    friend class MprisAdaptor;
    friend class MprisPlayerAdaptor;
#endif
#ifdef Q_OS_WIN
    friend class WinMediaSession;
#endif

private slots:
    // 处理“打开文件”请求，弹出文件选择对话框。
    void onOpenFile();
    // 处理当前曲目播放结束事件，自动切换到下一首。
    void onTrackFinished();
    // 播放下一首。
    void onNext();
    // 播放上一首。
    void onPrev();
    // 切换歌词窗口可见性。
    void onLyricToggled(bool visible);
    // 切换均衡器窗口可见性。
    void onEqualizerToggled(bool visible);
    // 切换播放列表窗口可见性。
    void onPlaylistToggled(bool visible);
    // 处理播放列表中选中文件后的播放请求。
    void onFileSelected(const QString& filePath);
    // 处理最小化请求，将窗口最小化到托盘。
    void onMiniModeRequested();
    void onMinimizeRequested();
    // 恢复并显示主窗口及辅助窗口。
    void onShowMainWindow();
    // 切换播放/暂停状态。
    void onTogglePlayPause();
    // 处理系统托盘图标激活事件。
    void onTrayActivated(QSystemTrayIcon::ActivationReason reason);
    // 处理播放器右键菜单请求，显示上下文菜单。
    void onPlayerContextMenuRequested(const QPoint& globalPos);
    // 导入调试音乐目录中的所有音频文件。
    void onImportDebugMusicFolder();
    // 切换所有窗口的置顶状态。
    void onAlwaysOnTopToggled(bool enabled);

private:
    struct SkinChoice {
        enum class Kind {
            FollowOriginal,
            BuiltinDefault,
            File
        };

        QString selectionId;
        QString displayName;
        QString sourcePath;
        Kind kind = Kind::File;
    };

    // 应用窗口置顶标志到主窗口和所有辅助窗口。
    void applyAlwaysOnTop(bool enabled);
    // 将辅助窗口绑定到主窗口，确保它们属于同一个窗口组。
    void bindAuxWindowsToMain();
    // 根据当前辅助窗口的可见性同步主窗口按钮状态。
    void syncAuxWindowToggleStates();
    // 初始化平台特定的任务栏/媒体控制集成。
    void initPlatformMediaControls();
    void updatePlatformMediaControls();
#ifdef QT_DBUS_LIB
    void updateMprisMetadata();
    void updateMprisPlaybackStatus();
    void updateMprisVolume();
#endif
    // 初始化应用前台可用的窗口内快捷键。
    void initializeGlobalShortcuts();
    // 切换到下一个可用皮肤。
    void applyNextSkinTest();
    // 切换到上一个可用皮肤。
    void applyPreviousSkinTest();
    // 发现可用的皮肤选择，包括原版皮肤、本地 Skin 目录和内置默认。
    QVector<SkinChoice> discoverAvailableSkins() const;
    // 规范化皮肤选择标识，返回可用于加载的标准 ID 或路径。
    QString normalizedSkinSelection(const QString& selection) const;
    // 根据选择 ID 加载对应皮肤资源。
    bool loadSkinSelection(const QString& selectionId);
    // 将新的皮肤选择应用到界面，并可选保存配置。
    bool applySkinSelection(const QString& selectionId, bool persistSelection);
    // 获取皮肤选择对应的实际文件路径，用于保存侧车布局。
    QString resolveSkinSelectionFilePath(const QString& selectionId) const;
    // 保存当前窗口布局到皮肤侧车 XML 文件中。
    void saveSkinLayoutSidecarForSelection(const QString& selectionId) const;
    // 加载当前配置中指定的皮肤，失败时回退到默认。
    void loadSkin();
    // 将加载后的皮肤数据应用到各个窗口。
    void applySkin();
    // 根据当前皮肤布局配置安排辅助窗口位置。
    void layoutFromSkin();
    // 恢复上次保存的主窗口位置和辅助窗口布局状态。
    void restoreState();
    // 保存当前配置、窗口位置、可见性和播放状态到配置文件。
    void saveState();
    // 加载并播放指定文件，同时更新歌词和播放信息。
    void playFile(const QString& filePath, qint64 userSwitchStartMs = -1);
    // 创建系统托盘图标及其关联菜单。
    void createTrayMenu();
    // 重新构建系统托盘菜单中的皮肤切换项。
    void rebuildSkinMenu();
    // 记录一次待执行的皮肤切换，等待菜单完全关闭后再应用。
    void queueSkinSelection(const QString& selectionId, bool persistSelection);
    // 在菜单关闭后的事件循环中执行待处理的皮肤切换。
    void applyPendingSkinSelection();

    QApplication app_;
    Config config_;
    AudioEngine engine_;
    SkinEngine skinEngine_;
    bool configLoaded_ = false;

    std::unique_ptr<PlayerWindow> playerWindow_;
    std::unique_ptr<LyricWindow> lyricWindow_;
    std::unique_ptr<EqualizerWindow> eqWindow_;
    std::unique_ptr<PlaylistWindow> playlistWindow_;
    std::unique_ptr<QSystemTrayIcon> trayIcon_;
    std::unique_ptr<QMenu> trayMenu_;
    std::unique_ptr<WindowSnapManager> snapManager_;
    QMenu* skinMenu_ = nullptr;
    QActionGroup* skinActionGroup_ = nullptr;
    QAction* trayLyricAction_ = nullptr;
    QAction* trayEqAction_ = nullptr;
    QAction* trayPlaylistAction_ = nullptr;
    QVector<SkinChoice> availableSkins_;
    QString currentSkinSelection_;
    QString pendingSkinSelection_;
    bool pendingSkinPersistSelection_ = false;
    bool suppressAuxVisibilitySync_ = false;
    // 用户意图的辅助窗口可见性，不受最小化/皮肤切换等临时 hide 影响。
    bool auxLyricVisible_ = true;
    bool auxEqVisible_ = true;
    bool auxPlaylistVisible_ = true;
    qint64 lastNextSkinTriggerMs_ = 0;

#ifdef Q_OS_WIN
    WinMediaSession* winMediaSession_ = nullptr;  // ITaskbarList3 + SMTC 集成
#endif

#ifdef QT_DBUS_LIB
    MprisAdaptor* mprisCoreAdaptor_ = nullptr;
    MprisPlayerAdaptor* mprisPlayerAdaptor_ = nullptr;
#endif
};
