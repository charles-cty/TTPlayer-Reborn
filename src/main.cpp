#include "app/Application.h"
#include "tools/SkinDumper.h"
#include "tools/FrameDumper.h"
#include <QApplication>
#include <QByteArray>
#include <QStringList>
#include <QTextStream>
#ifdef Q_OS_WIN
#  include <windows.h>
#  include <shellapi.h>
#endif

namespace {

// 从参数列表中取出 --key 后跟的值，取到后从列表中移除该键值对。
QString takeOption(QStringList& args, const QString& key) {
    const int idx = args.indexOf(key);
    if (idx < 0 || idx + 1 >= args.size()) {
        return {};
    }
    const QString value = args.at(idx + 1);
    args.removeAt(idx + 1);
    args.removeAt(idx);
    return value;
}

// Windows CRT argv is the ANSI code page; PowerShell passes UTF-16 via
// CreateProcessW.  Decode the real command line so --dump-skin/--dump-frames
// can open non-ASCII skin paths.
QStringList toolArguments(int argc, char** argv) {
    QStringList args;
#ifdef Q_OS_WIN
    int wargc = 0;
    wchar_t** wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
    if (wargv) {
        for (int i = 1; i < wargc; ++i) {
            args.append(QString::fromWCharArray(wargv[i]));
        }
        LocalFree(wargv);
        return args;
    }
#endif
    for (int i = 1; i < argc; ++i) {
        args.append(QString::fromLocal8Bit(argv[i]));
    }
    return args;
}

// 测试辅助模式分发：--dump-skin 导出皮肤解析结果供 differential testing 使用。
// 返回 -1 表示不是辅助模式，应继续正常启动播放器。
int runToolMode(int argc, char** argv) {
    QStringList args = toolArguments(argc, argv);
    if (!args.contains(QStringLiteral("--dump-skin")) &&
        !args.contains(QStringLiteral("--dump-frames"))) {
        return -1;
    }

    QTextStream err(stderr);

    if (args.contains(QStringLiteral("--dump-frames"))) {
        const QString skinPath = takeOption(args, QStringLiteral("--dump-frames"));
        const QString outDir = takeOption(args, QStringLiteral("--outdir"));
        if (skinPath.isEmpty() || outDir.isEmpty()) {
            err << "usage: --dump-frames <skn|dir> --outdir <dir>\n";
            return 1;
        }
        // 帧渲染同样离屏执行；固定 1x 缩放保证跨机器输出一致。
        if (qgetenv("QT_QPA_PLATFORM").isEmpty()) {
            qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("offscreen"));
        }
        qputenv("QT_SCALE_FACTOR", QByteArrayLiteral("1"));
        qputenv("QT_ENABLE_HIGHDPI_SCALING", QByteArrayLiteral("0"));
        QApplication app(argc, argv);
        return FrameDumper::run(skinPath, outDir);
    }

    const QString skinPath = takeOption(args, QStringLiteral("--dump-skin"));
    const QString outPath = takeOption(args, QStringLiteral("--out"));
    if (skinPath.isEmpty() || outPath.isEmpty()) {
        err << "usage: --dump-skin <skn|dir> --out <file.json>\n";
        return 1;
    }

    // QPixmap 需要 GUI 应用实例；离屏平台让该模式在无显示环境下也能运行。
    if (qgetenv("QT_QPA_PLATFORM").isEmpty()) {
        qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("offscreen"));
    }
    QApplication app(argc, argv);
    return SkinDumper::run(skinPath, outPath);
}
// 将常见环境变量值归一化为布尔值。
// 例如 '1', 'true', 'yes', 'on' 都被视为真。
bool isTruthy(const QByteArray& value) {
    const QByteArray v = value.trimmed().toLower();
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

// 在 Wayland 会话下强制使用 XCB 平台，以避免 Qt Wayland 兼容性问题。
// 这在某些 Linux 桌面环境下可以提供更稳定的窗口行为。
bool shouldForceXcbOnWayland() {
    // 允许通过环境变量显式禁用该策略，用于调试原生 Wayland 行为。
    if (isTruthy(qgetenv("TTPLAYER_FORCE_WAYLAND"))) {
        return false;
    }

    const QByteArray qpa = qgetenv("QT_QPA_PLATFORM").trimmed().toLower();
    if (qpa == "xcb") {
        return false;
    }
    if (!qpa.isEmpty() && qpa != "wayland") {
        return false;
    }

    const QByteArray sessionType = qgetenv("XDG_SESSION_TYPE").trimmed().toLower();
    if (sessionType == "wayland") {
        return true;
    }
    return !qgetenv("WAYLAND_DISPLAY").isEmpty() || !qgetenv("WAYLAND_SOCKET").isEmpty();
}
} // 命名空间结束

int main(int argc, char* argv[]) {
    // 优先处理测试辅助模式（--dump-skin 等），它们不启动播放器界面。
    const int toolResult = runToolMode(argc, argv);
    if (toolResult >= 0) {
        return toolResult;
    }

    // 在 Wayland 环境下强制 Qt 使用 xcb 后端，避免某些平台出现异常。
    if (shouldForceXcbOnWayland()) {
        qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("xcb"));
    }

    Application app(argc, argv);
    return app.run();
}
