#include "FrameDumper.h"
#include "skin/SkinEngine.h"
#include "skin/SkinButton.h"
#include "audio/AudioEngine.h"
#include "ui/PlayerWindow.h"
#include "ui/EqualizerWindow.h"
#include "ui/LyricWindow.h"
#include "ui/PlaylistWindow.h"

#include <QDir>
#include <QFileInfo>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QFile>
#include <QTextStream>
#include <QWidget>
#include <QRegion>

// 状态矩阵（与 docs/testing.md 保持同步）：
//   player__default            初始状态
//   player__progress37         进度 37% + 音量 60%
//   player__hover-play         播放按钮悬停态（测试钩子）
//   player__pressed-play       播放按钮按下态（测试钩子）
//   player__toggled-mute       静音按钮切换态
//   equalizer__default         初始状态
//   equalizer__sliders         各频段滑块错落图案
//   lyric__default             初始状态
//   playlist__default          初始状态
//   mini 窗口暂不覆盖（Qt 版尚未实现独立 mini 窗口渲染路径）
//
// 文本类区域（info 滚动文字、歌词、播放列表条目、频谱动画区）写入 masks.json，
// Layer 2 像素对比时排除；LED 位图字体数字不排除。

namespace {

// 收集窗口内文本/动画类元素矩形，供像素对比排除。
void appendMaskRects(const SkinWindow& wnd, const QString& windowKey,
                     QJsonObject& masks) {
    // 需要掩码的元素类型：矢量文本、时变动画、或缩放后采样有平台差异的图标
    static const QStringList kMaskTypes = {
        QStringLiteral("info"), QStringLiteral("lyric"), QStringLiteral("playlist"),
        QStringLiteral("visual"), QStringLiteral("title"), QStringLiteral("column"),
        QStringLiteral("stereo"), QStringLiteral("status"), QStringLiteral("icon"),
    };

    QJsonArray rects;
    for (const auto& elem : wnd.elements) {
        if (!kMaskTypes.contains(elem.type.toLower())) {
            continue;
        }
        if (elem.position.isEmpty()) {
            continue;
        }
        QJsonObject r;
        r["type"] = elem.type;
        r["x"] = elem.position.x();
        r["y"] = elem.position.y();
        r["w"] = elem.position.width();
        r["h"] = elem.position.height();
        rects.append(r);
    }
    masks[windowKey] = rects;
}

bool saveFrame(QWidget* widget, const QString& outDir, const QString& name) {
    // Offscreen QWidget::render + setMask 会把遮罩原点当成屏幕坐标，
    // Subaru 等皮肤因此整体偏移 (+7,+11)。捕帧前清掉 mask，画完再还原。
    const QRegion oldMask = widget->mask();
    const bool hadMask = !oldMask.isEmpty();
    if (hadMask)
        widget->clearMask();
    QImage image(widget->size(), QImage::Format_ARGB32);
    image.fill(Qt::transparent);
    widget->render(&image);
    if (hadMask)
        widget->setMask(oldMask);
    const QString path = outDir + QLatin1Char('/') + name + QStringLiteral(".png");
    return image.save(path, "PNG");
}

}  // 匿名命名空间结束

namespace FrameDumper {

int run(const QString& skinPath, const QString& outDir) {
    QTextStream err(stderr);

    SkinEngine engine;
    const QFileInfo info(skinPath);
    const bool ok = info.isDir() ? engine.loadFromDirectory(skinPath)
                                 : engine.loadFromFile(skinPath);
    if (!ok) {
        err << "FrameDumper: failed to load skin: " << skinPath << "\n";
        return 3;
    }
    if (!QDir().mkpath(outDir)) {
        err << "FrameDumper: failed to create output dir: " << outDir << "\n";
        return 4;
    }

    const SkinData& skin = engine.skinData();
    // AudioEngine 正常构造（不播放任何内容），保证确定性输出。
    AudioEngine audio;

    int failures = 0;
    auto dump = [&](QWidget* w, const QString& name) {
        if (!saveFrame(w, outDir, name)) {
            err << "FrameDumper: failed to save frame: " << name << "\n";
            ++failures;
        }
    };

    // ---- player_window ----
    {
        PlayerWindow player(&audio);
        player.applySkin(skin);
        const int engineVolumeDefault = audio.volume();
        dump(&player, QStringLiteral("player__default"));

        // 进度/音量：直接驱动子控件（值域与 createSliders 一致：进度 0-1，音量 0-100）
        auto* progress = player.findChild<SkinSlider*>(QStringLiteral("progress"));
        auto* volume = player.findChild<SkinSlider*>(QStringLiteral("volume"));
        if (progress) progress->setValue(0.37);
        if (volume) volume->setValue(60);
        dump(&player, QStringLiteral("player__progress37"));
        // 复位，保证后续帧状态独立
        if (progress) progress->setValue(0);
        if (volume) volume->setValue(engineVolumeDefault);

        if (auto* play = player.findChild<SkinButton*>(QStringLiteral("play"))) {
            play->setVisualStateOverride(1);
            dump(&player, QStringLiteral("player__hover-play"));
            play->setVisualStateOverride(2);
            dump(&player, QStringLiteral("player__pressed-play"));
            play->setVisualStateOverride(-1);
        }

        // toggled-mute：若无 mute 按钮则输出与 default 相同的帧（golden 一致性）
        if (auto* mute = player.findChild<SkinButton*>(QStringLiteral("mute"))) {
            mute->setToggled(true);
        }
        dump(&player, QStringLiteral("player__toggled-mute"));
        if (auto* mute = player.findChild<SkinButton*>(QStringLiteral("mute"))) {
            mute->setToggled(false);
        }
    }

    // ---- equalizer_window ----
    {
        EqualizerWindow eq(&audio);
        eq.applySkin(skin);
        dump(&eq, QStringLiteral("equalizer__default"));

        // 各频段滑块错落图案：确定性的固定序列（直接驱动子控件视觉，不触发音频）
        const QList<SkinSlider*> sliders = eq.findChildren<SkinSlider*>();
        const double pattern[] = {-12.0, -6.0, 0.0, 6.0, 12.0, 6.0, 0.0, -6.0, -12.0, 0.0, 6.0, 3.0};
        for (int i = 0; i < sliders.size(); ++i) {
            sliders[i]->setValue(pattern[i % 12]);
        }
        dump(&eq, QStringLiteral("equalizer__sliders"));
    }

    // ---- lyric_window ----
    // applySkin 不 resize（避开 X11 WM 异步改尺寸）。offscreen 默认是
    // 640×480，chrome 的 alignedRect 会偏离 XML/masks。按皮肤 baseSize
    // 捕帧后，Layer 2 可与 Pascal RenderLyricWindow(bgW, bgH) 对拍。
    {
        LyricWindow lyric(&audio);
        lyric.applySkin(skin);
        const QSize lyricSize = skin.lyricWindow.backgroundPixmap.isNull()
            ? lyric.minimumSize()
            : skin.lyricWindow.backgroundPixmap.size();
        if (lyricSize.isValid() && !lyricSize.isEmpty()) {
            lyric.resize(lyricSize);
        }
        dump(&lyric, QStringLiteral("lyric__default"));
    }

    // ---- playlist_window ----
    // 与 lyric 相同：offscreen 默认 640×480 会把 chrome 的 alignedRect 拉偏
    // XML/masks。按皮肤 baseSize 捕帧后，Layer 2 可与
    // RenderPlaylistWindow(bgW, bgH) 对拍，resize_tile=False 也不再双线性拉伸。
    {
        PlaylistWindow playlist(&audio);
        playlist.applySkin(skin);
        const QSize playlistSize = skin.playlistWindow.backgroundPixmap.isNull()
            ? playlist.minimumSize()
            : skin.playlistWindow.backgroundPixmap.size();
        if (playlistSize.isValid() && !playlistSize.isEmpty()) {
            playlist.resize(playlistSize);
        }
        dump(&playlist, QStringLiteral("playlist__default"));
    }

    // ---- masks.json ----
    QJsonObject masks;
    appendMaskRects(skin.playerWindow, QStringLiteral("player"), masks);
    appendMaskRects(skin.equalizerWindow, QStringLiteral("equalizer"), masks);
    appendMaskRects(skin.lyricWindow, QStringLiteral("lyric"), masks);
    appendMaskRects(skin.playlistWindow, QStringLiteral("playlist"), masks);

    QFile maskFile(outDir + QStringLiteral("/masks.json"));
    if (maskFile.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        maskFile.write(QJsonDocument(masks).toJson(QJsonDocument::Indented));
    } else {
        err << "FrameDumper: failed to write masks.json\n";
        ++failures;
    }

    return failures == 0 ? 0 : 5;
}

}  // namespace FrameDumper
