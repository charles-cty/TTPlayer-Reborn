# Drive real playlist/lyric live resize on Windows via SendInput.
# Aux windows are WS_EX_TOOLWINDOW, so UIA often misses them; enumerate HWND.
#
# Default is a multi-phase gesture: corner grow/shrink/grow, edge sawtooth,
# rapid wiggle, then lyric. Writes PHASE timestamps for ETW correlation.

from __future__ import annotations

import argparse
import ctypes
import os
import shutil
import sys
import time
from ctypes import wintypes

from pywinauto.mouse import move, press, release

user32 = ctypes.windll.user32
WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)


def log(msg: str) -> None:
    print(msg, flush=True)


def enum_process_windows(pid: int) -> list[dict]:
    buf = ctypes.create_unicode_buffer(512)
    found: list[dict] = []

    def cb(hwnd, _lparam):
        p = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(p))
        if p.value != pid:
            return True
        user32.GetWindowTextW(hwnd, buf, 512)
        vis = bool(user32.IsWindowVisible(hwnd))
        rc = wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rc))
        found.append(
            {
                'hwnd': int(hwnd),
                'title': buf.value,
                'vis': vis,
                'l': rc.left,
                't': rc.top,
                'r': rc.right,
                'b': rc.bottom,
            }
        )
        return True

    user32.EnumWindows(WNDENUMPROC(cb), 0)
    return found


def wait_titled(pid: int, title: str, timeout: float = 20.0) -> dict:
    deadline = time.time() + timeout
    last = []
    while time.time() < deadline:
        last = enum_process_windows(pid)
        for w in last:
            if w['vis'] and w['title'] == title and (w['r'] - w['l']) > 20:
                return w
        time.sleep(0.2)
    log('WINDOWS_AT_TIMEOUT')
    for w in last:
        log(
            f"WINDOW\t{w['hwnd']}\tvis={w['vis']}\t{w['title']!r}\t"
            f"{w['l']},{w['t']}-{w['r']},{w['b']}"
        )
    raise TimeoutError(f'visible window {title!r} not found')


def rect_of(hwnd: int) -> dict:
    rc = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rc))
    return {'l': rc.left, 't': rc.top, 'r': rc.right, 'b': rc.bottom}


def width(r: dict) -> int:
    return r['r'] - r['l']


def height(r: dict) -> int:
    return r['b'] - r['t']


def snapshot_phases(out_dir: str | None, tag: str) -> None:
    src = os.environ.get('TTPLAYER_ZOOM_PHASES_LOG', '')
    if not out_dir or not src or not os.path.isfile(src):
        return
    dst = os.path.join(out_dir, f'zoom-phases-{tag}.log')
    shutil.copyfile(src, dst)
    log(f'PHASES_SAVED\t{dst}')


def interp_path(points: list[tuple[int, int]], steps: int) -> list[tuple[int, int]]:
    if steps < 1:
        steps = 1
    if len(points) < 2:
        return points[:]
    segs = len(points) - 1
    out: list[tuple[int, int]] = []
    for s in range(steps):
        t = s / float(steps)
        f = t * segs
        i = min(int(f), segs - 1)
        u = f - i
        x0, y0 = points[i]
        x1, y1 = points[i + 1]
        out.append((int(x0 + (x1 - x0) * u), int(y0 + (y1 - y0) * u)))
    out.append(points[-1])
    return out


def drag_path(
    hwnd: int,
    start: tuple[int, int],
    points: list[tuple[int, int]],
    steps: int,
    step_s: float,
    name: str,
) -> tuple[dict, dict]:
    r0 = rect_of(hwnd)
    sx, sy = start
    log(
        f"DRAG_START\t{name}\t{sx},{sy}\tfrom\t"
        f"{r0['l']},{r0['t']}-{r0['r']},{r0['b']}"
    )
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.08)
    move(coords=(sx, sy))
    time.sleep(0.03)
    press(button='left', coords=(sx, sy))
    time.sleep(0.03)
    t0 = time.perf_counter()
    path = interp_path([(sx, sy)] + points, steps)
    for x, y in path[1:]:
        move(coords=(x, y))
        time.sleep(step_s)
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    ex, ey = path[-1]
    release(button='left', coords=(ex, ey))
    time.sleep(0.25)
    r1 = rect_of(hwnd)
    log(
        f"DRAG_END\t{name}\t{ex},{ey}\tto\t"
        f"{r1['l']},{r1['t']}-{r1['r']},{r1['b']}\t"
        f"dw={width(r1) - width(r0)}\tdh={height(r1) - height(r0)}\t"
        f"move_ms={elapsed_ms:.1f}\tsteps={len(path) - 1}"
    )
    return r0, r1


def right_edge(r: dict) -> tuple[int, int]:
    # 2px inside the 8px sense band, away from the SE corner.
    return r['r'] - 2, r['t'] + max(16, (r['b'] - r['t']) // 2)


def bottom_edge(r: dict) -> tuple[int, int]:
    return r['l'] + max(24, (r['r'] - r['l']) // 2), r['b'] - 2


def corner_se(r: dict) -> tuple[int, int]:
    return r['r'] - 2, r['b'] - 2


def add(p: tuple[int, int], dx: int, dy: int) -> tuple[int, int]:
    return p[0] + dx, p[1] + dy


def run_complex(pid: int, out_dir: str | None) -> None:
    log('HANDS_OFF\tkeep mouse and keyboard still for ~20s')
    for i in range(3, 0, -1):
        log(f'COUNTDOWN\t{i}')
        time.sleep(1.0)

    playlist = wait_titled(pid, 'Playlist')
    lyric = wait_titled(pid, 'Lyric')
    log(
        f"PLAYLIST\t{playlist['l']},{playlist['t']}-"
        f"{playlist['r']},{playlist['b']}"
    )
    log(f"LYRIC\t{lyric['l']},{lyric['t']}-{lyric['r']},{lyric['b']}")

    ph = playlist['hwnd']
    lh = lyric['hwnd']

    # 1) Playlist right: grow, shrink, grow in one live session.
    r = rect_of(ph)
    s = right_edge(r)
    log('PHASE\tplaylist_right_sawtooth')
    b, a = drag_path(
        ph,
        s,
        [add(s, 80, 0), add(s, 20, 0), add(s, 100, 0)],
        steps=48,
        step_s=0.008,
        name='playlist_right_sawtooth',
    )
    if width(a) == width(b):
        raise AssertionError('playlist right-edge resize did not take (hands off the mouse?)')
    snapshot_phases(out_dir, 'playlist_right')

    # 2) Playlist bottom sawtooth.
    r = rect_of(ph)
    s = bottom_edge(r)
    log('PHASE\tplaylist_bottom_sawtooth')
    b, a = drag_path(
        ph,
        s,
        [add(s, 0, 50), add(s, 0, 10), add(s, 0, 60)],
        steps=36,
        step_s=0.008,
        name='playlist_bottom_sawtooth',
    )
    if height(a) == height(b):
        raise AssertionError('playlist bottom-edge resize did not take')
    snapshot_phases(out_dir, 'playlist_bottom')

    # 3) Playlist SE corner (both axes) then a short right-edge wiggle.
    r = rect_of(ph)
    s = corner_se(r)
    log('PHASE\tplaylist_corner')
    drag_path(
        ph,
        s,
        [add(s, 40, 30), add(s, 10, 8), add(s, 55, 40)],
        steps=36,
        step_s=0.008,
        name='playlist_corner',
    )
    snapshot_phases(out_dir, 'playlist_corner')

    r = rect_of(ph)
    s = right_edge(r)
    wiggle = []
    x, y = s
    for i in range(10):
        x += 8 if i % 2 == 0 else -5
        wiggle.append((x, y))
    log('PHASE\tplaylist_right_wiggle')
    drag_path(ph, s, wiggle, steps=30, step_s=0.006, name='playlist_right_wiggle')
    snapshot_phases(out_dir, 'playlist_wiggle')

    # 4) Lyric right + bottom (not caption).
    r = rect_of(lh)
    s = right_edge(r)
    log('PHASE\tlyric_right_sawtooth')
    b, a = drag_path(
        lh,
        s,
        [add(s, 70, 0), add(s, 20, 0), add(s, 80, 0)],
        steps=36,
        step_s=0.008,
        name='lyric_right_sawtooth',
    )
    if width(a) == width(b) and (a['l'] != b['l'] or a['t'] != b['t']):
        raise AssertionError('lyric was moved instead of resized; edge hit missed')
    if width(a) == width(b):
        raise AssertionError('lyric right-edge resize did not take')
    snapshot_phases(out_dir, 'lyric_right')

    r = rect_of(lh)
    s = bottom_edge(r)
    log('PHASE\tlyric_bottom')
    drag_path(
        lh,
        s,
        [add(s, 0, 35), add(s, 0, 10)],
        steps=24,
        step_s=0.008,
        name='lyric_bottom',
    )
    snapshot_phases(out_dir, 'lyric_bottom')

    pr = rect_of(ph)
    lr = rect_of(lh)
    log(f"PLAYLIST_FINAL\t{width(pr)}x{height(pr)}")
    log(f"LYRIC_FINAL\t{width(lr)}x{height(lr)}")


def run_simple(pid: int, out_dir: str | None) -> None:
    playlist = wait_titled(pid, 'Playlist')
    lyric = wait_titled(pid, 'Lyric')
    ph = playlist['hwnd']
    r = rect_of(ph)
    s = right_edge(r)
    drag_path(ph, s, [add(s, 80, 0)], 40, 0.012, 'playlist_grow')
    snapshot_phases(out_dir, 'playlist_grow')
    r = rect_of(ph)
    s = right_edge(r)
    drag_path(ph, s, [add(s, -40, 0)], 20, 0.012, 'playlist_shrink')
    snapshot_phases(out_dir, 'playlist_shrink')
    r = rect_of(lyric['hwnd'])
    s = right_edge(r)
    drag_path(lyric['hwnd'], s, [add(s, 50, 0)], 25, 0.012, 'lyric_grow')
    snapshot_phases(out_dir, 'lyric_grow')


def main() -> int:
    from pywinauto import Application

    parser = argparse.ArgumentParser()
    parser.add_argument('--exe', required=True)
    parser.add_argument('--workdir', required=True)
    parser.add_argument('--out', default='')
    parser.add_argument('--simple', action='store_true')
    args = parser.parse_args()

    out_dir = args.out or None
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    app = Application(backend='win32').start(
        args.exe,
        work_dir=args.workdir,
        timeout=20,
    )
    pid = app.process
    log(f'PID\t{pid}')
    try:
        time.sleep(1.4)
        if args.simple:
            run_simple(pid, out_dir)
        else:
            run_complex(pid, out_dir)
        log('PROFILE_GESTURE_OK')
        return 0
    except Exception as exc:  # noqa: BLE001
        log(f'PROFILE_GESTURE_FAIL\t{exc}')
        try:
            for w in enum_process_windows(pid):
                log(f"WINDOW\t{w['hwnd']}\tvis={w['vis']}\t{w['title']!r}")
        except Exception:
            pass
        return 1
    finally:
        try:
            app.kill()
        except Exception:
            pass


if __name__ == '__main__':
    sys.exit(main())
