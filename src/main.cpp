#include "app/Application.h"
#include <QByteArray>

namespace {
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
    // 在 Wayland 环境下强制 Qt 使用 xcb 后端，避免某些平台出现异常。
    if (shouldForceXcbOnWayland()) {
        qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("xcb"));
    }

    Application app(argc, argv);
    return app.run();
}
