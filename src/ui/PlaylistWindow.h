#pragma once
#include "skin/SkinData.h"
#include "skin/SkinButton.h"
#include "audio/AudioEngine.h"
#include "WindowMovePerfLogger.h"
#include "playlist/PlaylistManager.h"
#include "playlist/PlaylistMetadataLoader.h"
#include <QWidget>
#include <QListWidget>
#include <QLineEdit>
#include <QDialog>
#include <QLabel>
#include <QMenu>
#include <QPoint>
#include <QSplitter>
#include <QHash>
#include <QString>

// 播放列表窗口，支持文件添加、搜索、分组、上下文菜单和拖放操作。
class PlaylistWindow : public QWidget {
    Q_OBJECT
public:
    explicit PlaylistWindow(AudioEngine* engine, QWidget* parent = nullptr);
    // 应用皮肤到播放列表窗口。
    void applySkin(const SkinData& skin);
    void setDividerPosition(int pos);
    int dividerPosition() const;

    // 添加单个文件到播放列表。
    void addFile(const QString& filePath);
    // 批量添加文件到播放列表。
    void addFiles(const QStringList& files);
    // 批量导入文件到播放列表（带进度窗口）。
    void importFilesWithProgress(const QStringList& files, const QString& progressTitle = {});
    // 获取当前播放文件路径。
    QString currentFile() const;

    // --- TTBL 加载 / 保存 ---
    // 从目录中加载 count 个播放列表（文件名：0000.ttbl, 0001.ttbl, ...）。
    // 快速加载路径并立即更新 UI，然后在后台线程中加载元数据。
    // activeList 为要激活的标签页索引（0-based）。
    void loadFromTtblDir(const QString& dir, int count, int activeList);
    // 将所有标签页保存到目录（文件名：0000.ttbl, 0001.ttbl, ...）。
    // 返回当前活动标签页索引，供调用方写回 Config。
    int saveToTtblDir(const QString& dir) const;
    // 请求立即获取指定索引的元数据（当该曲目即将播放时调用）。
    void requestPriorityMetadata(int tabIndex, int entryIndex);
    // 获取下一首文件路径。
    QString nextFile() const;
    // 获取上一首文件路径。
    QString prevFile() const;
    // 设置播放模式（循环/随机）。
    void setPlaybackMode(int repeatMode, bool shuffle);

    int currentIndex() const { return playlist_.currentIndex(); }
    int repeatMode() const { return playlist_.repeatMode(); }
    bool shuffle() const { return playlist_.isShuffle(); }
    int tabCount() const { return tabData_.size(); }
    int activeTabIndex() const { return activeTab_; }
    qint64 takeLastUserSwitchRequestMs(const QString& filePath, bool* fromDoubleClick = nullptr);

signals:
    // 选择播放文件后发出。
    void fileSelected(const QString& filePath);
    void windowMoved(QPoint delta);
    void dragStarted();
    void dragFinished();
    void resizeInProgress(Qt::Edges edges);
    void resizeFinished(Qt::Edges edges);
    void closeRequested();
    void visibilityChanged(bool visible);

public slots:
    void onCurrentChanged(int index);
    void setCurrentFile(const QString& filePath);

protected:
    void paintEvent(QPaintEvent*) override;
    bool eventFilter(QObject* watched, QEvent* event) override;
    void mousePressEvent(QMouseEvent*) override;
    void mouseDoubleClickEvent(QMouseEvent*) override;
    void mouseMoveEvent(QMouseEvent*) override;
    void mouseReleaseEvent(QMouseEvent*) override;
    void leaveEvent(QEvent*) override;
    void resizeEvent(QResizeEvent*) override;
    void moveEvent(QMoveEvent*) override;
    void showEvent(QShowEvent*) override;
    void hideEvent(QHideEvent*) override;
    void contextMenuEvent(QContextMenuEvent*) override;
    void dragEnterEvent(QDragEnterEvent*) override;
    void dragMoveEvent(QDragMoveEvent*) override;
    void dropEvent(QDropEvent*) override;

private slots:
    // UI 事件处理槽
    void onAddFiles();
    void onAddFolder();
    void onRemoveSelected();
    void onClearAll();
    void onPlaySelected();
    void onShowFileProps();
    void showListContextMenu(const QPoint& pos);
    void showAddMenu();
    void showDeleteMenu();
    void showPlaylistMenu();
    void showSortMenu();
    void showEditMenu();
    void showModeMenu();

private:
    // 内部布局与样式管理
    void applyStyle();
    void updateListGeometry();
    void rebuildBackground();
    void updateChromeGeometry();
    QRect playlistRect() const;
    QRect titleDrawRect() const;
    QRect toolbarAreaRect() const;
    QRect toolbarGroupRect(int group) const;
    QRect toolbarGroupDrawRect(int group, const QPixmap& sheet) const;
    QPoint toolbarMenuAnchor(int group) const;
    Qt::Edges resizeEdgesForPosition(const QPoint& pos) const;
    int toolbarGroupIndexAt(const QPoint& pos) const;
    int sourceIndexForItem(const QListWidgetItem* item) const;
    QListWidgetItem* findVisibleItemBySource(int sourceIndex);
    bool matchesFilter(const PlaylistEntry& entry) const;
    QList<int> selectedSourceIndices() const;
    void restoreSelectionBySourceIndices(const QList<int>& sourceIndices, int currentSource = -1);
    void updateSearchPlaceholder(int visibleCount);
    void refreshPlaylistView(const QString& reason = {});
    void addFilesWithProgress(const QStringList& files, const QString& progressTitle);
    void insertFilesWithProgress(const QStringList& files, int insertIndex, const QString& progressTitle);
    QStringList collectImportableAudioFiles(const QStringList& inputPaths) const;
    void ensureSearchDialog();
    void showSearchDialog();
    void populatePlaybackModeMenu(QMenu* menu);
    void saveActiveTab();
    void switchToTab(int index);
    QRect dividerVisualRect() const;
    QRect dividerHotZoneRect() const;
    QRect dividerHandleRect() const;
    bool isDividerCollapsed() const;
    void toggleDividerCollapsed();
    int insertionIndexForListPosition(const QPoint& pos) const;
    int dropIndicatorYForListPosition(const QPoint& pos) const;
    int targetTabIndexForPosition(const QPoint& pos) const;
    int dropIndicatorYForTabPosition(const QPoint& pos) const;
    void startPlaylistDrag(Qt::DropActions supportedActions);
    void startStandardPlaylistDrag(const QList<int>& sourceIndices,
                                   const QPixmap& previewPixmap,
                                   const QPoint& hotSpot);
    // xcb/XWayland 自定义拖拽（绕过 XDnD 光标更新缺陷）
    void startPlaylistDragCustom(const QList<int>& sourceIndices,
                                 const QPixmap& previewPixmap,
                                 const QPoint& hotSpot);
    void promoteCustomDragToStandard(const QPoint& globalPos);
    void updateCustomDragIndicators(const QPoint& globalPos);
    void finishCustomDrag(const QPoint& globalPos);
    void cancelCustomDrag();
    void handleListDragEnter(QDragEnterEvent* event);
    void handleListDragMove(QDragMoveEvent* event);
    void handleListDrop(QDropEvent* event);
    void handleTabDragEnter(QDragEnterEvent* event);
    void handleTabDragMove(QDragMoveEvent* event);
    void handleTabDrop(QDropEvent* event);
    void moveRowsWithinActivePlaylist(const QList<int>& sourceIndices, int insertIndex);
    void moveRowsToTab(int sourceTab, const QList<int>& sourceIndices, int targetTab);
    void markScrollDebugContext(bool tabs, const QString& source);
    QString currentScrollDebugContext(bool tabs) const;
    void logScrollBarValueChange(const char* channel, bool tabs, QScrollBar* scrollBar, int newValue);
    void logScrollBarRangeChange(const char* channel, bool tabs, QScrollBar* scrollBar, int minimum, int maximum);
    void logDragDecision(const char* target,
                         const char* phase,
                         const QPoint& localPos,
                         const QPoint& globalPos,
                         const QDropEvent* event);
    void resetDragDebugState(const char* target = nullptr);

    // 后台元数据加载（每个标签页独立一个加载器）。
    // tabIndex 对应 tabData_/metadataLoaders_ 中的同一个位置。
    void onMetadataReady(int tabIndex, int entryIndex,
                         const QString& filePath,
                         const QString& title, const QString& artist,
                         const QString& album, qint64 durationMs);
    void startMetadataLoaderForTab(int tabIndex);

    AudioEngine* engine_;

    // 皮肤资源
    QPixmap baseBackground_;
    QPixmap background_;
    QRect resizeRect_;
    SkinElement toolbarElement_;
    SkinElement scrollbarElement_;
    SkinElement titleElement_;
    SkinElement closeElement_;
    SkinElement playlistElement_;
    SkinButton* closeButton_ = nullptr;
    bool resizeTile_ = false;
    QSize baseSize_{268, 165};

    QListWidget* listWidget_;
    QListWidget* playlistTabsWidget_;
    QWidget* skinScrollBar_ = nullptr;
    QWidget* tabsSkinScrollBar_ = nullptr;
    PlaylistManager playlist_;

    // 多播放列表支持
    struct PlaylistTabData {
        QString name;
        QVector<PlaylistEntry> entries;
        int currentIndex = -1;
    };
    QVector<PlaylistTabData> tabData_;
    int activeTab_ = 0;

    // 工具栏按钮状态（统一为 7 组）
    int pressedToolbarGroup_ = -1;
    int hoveredToolbarGroup_ = -1;

    // 分割条
    int dividerPos_ = 55;
    int dividerSavedPos_ = 55;   // 用于点击折叠时恢复分隔条位置
    bool dividerDragging_ = false;
    int dividerDragStartX_ = 0;  // 用于区分点击和拖动
    bool dividerHandlePressed_ = false;

    // 来自 PlayList.xml 的颜色配置
    QColor colorText_{0x00, 0x80, 0xFF};
    QColor colorHilight_{0x00, 0xFF, 0x00};
    QColor colorBkgnd_{0x00, 0x00, 0x00};
    QColor colorSelect_{0x32, 0x69, 0xC8};
    QColor colorBkgnd2_{0x20, 0x20, 0x20};
    QColor colorNumber_{0x00, 0x80, 0x00};
    QColor colorDuration_{0xC0, 0x80, 0x20};
    QColor splitterFrontColor_{0x00, 0x80, 0xFF};
    QColor splitterBackColor_{0x00, 0x00, 0x00};

    QAbstractItemDelegate* playlistDelegate_ = nullptr;
    QDialog* searchDialog_ = nullptr;
    QLineEdit* searchEdit_ = nullptr;

    // 每个标签页对应一个元数据加载器（nullptr 表示未为这个标签页启动加载器）。
    QVector<PlaylistMetadataLoader*> metadataLoaders_;

    // 调整大小句柄
    Qt::Edges resizeEdges_ = {};
    QPoint resizeStartGlobalPos_;
    QSize resizeStartSize_;

    // 可见列表项索引缓存：sourceIndex -> row。
    QHash<int, int> visibleRowBySource_;
    int displayedPlayingSource_ = -1;

    // 拖拽相关
    bool dragging_ = false;
    QPoint dragStart_;
    bool dragSessionActive_ = false;
    bool dragUsingSystemMove_ = false;
    bool lastMoveEventObserved_ = false;
    qint64 lastWindowMovedEmitMs_ = 0;
    WindowMovePerfLogger movePerf_{"PlaylistWindow"};
    QString filterText_;
    qint64 lastUserSwitchRequestMs_ = -1;
    QString lastUserSwitchPath_;
    bool lastUserSwitchFromDoubleClick_ = false;

    struct ScrollDebugState {
        QString source;
        qint64 timestampMs = -1;
        int lastValue = 0;
    };
    ScrollDebugState playlistScrollDebug_;
    ScrollDebugState tabsScrollDebug_;

    struct DragDebugState {
        QString lastSignature;
    };
    DragDebugState listDragDebug_;
    DragDebugState tabsDragDebug_;
    DragDebugState rootDragDebug_;

    // 自定义拖拽（xcb/XWayland 平台专用，绕过 XDnD 光标更新问题）
    bool customDragActive_ = false;
    QList<int> customDragSourceIndices_;
    int customDragSourceTab_ = -1;
    QLabel* customDragPreviewLabel_ = nullptr;
    QPixmap customDragPreviewPixmap_;
    QPoint customDragHotSpot_;
    bool customDragPromotingToStandard_ = false;
    qint64 customDragStartedMs_ = -1;
    QList<int> pendingStandardDragSourceIndices_;
    QPixmap pendingStandardDragPreviewPixmap_;
    QPoint pendingStandardDragHotSpot_;
    qint64 pendingStandardDragQueuedMs_ = -1;
};
