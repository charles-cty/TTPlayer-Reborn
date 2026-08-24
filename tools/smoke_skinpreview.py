"""
tools/smoke_skinpreview.py
皮肤预览工具的 GUI 冒烟测试（Player / Equalizer / Lyric / Playlist 四个子窗口）。

变更历史：
- v1: 初始版本（PlayerForm 单窗口）
- v2: 增加 EqualizerForm 检查；改用 Win32 CB_SETCURSEL + WM_COMMAND
      触发皮肤切换（UIA .select() / click_input() 在无桌面会话中不可靠）；
      改用 PrintWindow 截图（ImageGrab.grab 需真实桌面会话）。
- v3: 四个子窗口（Player/EQ/Lyric/Playlist），优先按窗口标题识别。
- v4: 换肤选 Subaru/HiFi 等大尺寸差皮肤；PrintWindow 前 RedrawWindow；
      修 BGR 双交换；启动前 taskkill 残留进程。
- v5: 吸附用 EnumWindows 的 Player/EQ HWND + ENTER/SetWindowPos/EXIT
      模拟拖动；先把 Player 拉开再停 EQ，避免 EQ 仍在主窗口联动组里。
"""
import sys
import time
import os
import io
import json
import ctypes
from ctypes import wintypes

# Windows cmd/PowerShell 控制台可能使用 GBK，强制 UTF-8 输出
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

try:
    from pywinauto import Application, Desktop
    from pywinauto.timings import wait_until, TimeoutError as PWATimeout
    from PIL import Image
except ImportError as e:
    print(f'SMOKE FAIL: missing dependency — {e}', file=sys.stderr)
    sys.exit(1)

EXE          = r'C:\My\Repos\TTPlayer-Reborn\pascal\bin\skinpreview.exe'
ARTIFACT_DIR = r'C:\My\Repos\TTPlayer-Reborn\tests\artifacts\smoke'
SKINJSON_DIR = r'C:\My\Repos\TTPlayer-Reborn\tests\golden\skinjson'
WM_ENTERSIZEMOVE = 0x0231
WM_EXITSIZEMOVE  = 0x0232
WM_LBUTTONDOWN   = 0x0201
WM_LBUTTONUP     = 0x0202
MK_LBUTTON       = 0x0001
SWP_NOSIZE       = 0x0001
SWP_NOMOVE       = 0x0002
SWP_NOZORDER     = 0x0004
SWP_NOACTIVATE   = 0x0010
HWND_TOP         = 0
os.makedirs(ARTIFACT_DIR, exist_ok=True)

user32 = ctypes.windll.user32
gdi32  = ctypes.windll.gdi32

# ── Win32 helpers ───────────────────────────────────────────────────────────

def physical_size(hwnd) -> tuple:
    """Return (width, height) in physical pixels via GetWindowRect."""
    rc = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rc))
    return rc.right - rc.left, rc.bottom - rc.top

RDW_INVALIDATE   = 0x0001
RDW_ERASE        = 0x0004
RDW_ALLCHILDREN  = 0x0080
RDW_UPDATENOW    = 0x0100
PW_CLIENTONLY    = 0x0001
PW_RENDERFULLCONTENT = 0x0002


def grab_window(hwnd) -> Image.Image | None:
    """
    Capture a window's client area via PrintWindow.
    Forces a synchronous repaint first so DWM/PrintWindow does not return a
    stale frame after ApplySkin. GetDIBits BI_RGB is BGRA; decode as BGRX.
    """
    rc = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rc))
    w = rc.right - rc.left
    h = rc.bottom - rc.top
    if w <= 0 or h <= 0:
        return None
    user32.RedrawWindow(
        hwnd, None, None,
        RDW_INVALIDATE | RDW_ERASE | RDW_UPDATENOW | RDW_ALLCHILDREN)
    hdc_screen = user32.GetDC(0)
    hdc_mem = gdi32.CreateCompatibleDC(hdc_screen)
    hbm = gdi32.CreateCompatibleBitmap(hdc_screen, w, h)
    old = gdi32.SelectObject(hdc_mem, hbm)
    try:
        user32.PrintWindow(hwnd, hdc_mem, PW_CLIENTONLY | PW_RENDERFULLCONTENT)

        class BITMAPINFOHEADER(ctypes.Structure):
            _fields_ = [
                ('biSize',          ctypes.c_uint32),
                ('biWidth',         ctypes.c_int32),
                ('biHeight',        ctypes.c_int32),
                ('biPlanes',        ctypes.c_uint16),
                ('biBitCount',      ctypes.c_uint16),
                ('biCompression',   ctypes.c_uint32),
                ('biSizeImage',     ctypes.c_uint32),
                ('biXPelsPerMeter', ctypes.c_int32),
                ('biYPelsPerMeter', ctypes.c_int32),
                ('biClrUsed',       ctypes.c_uint32),
                ('biClrImportant',  ctypes.c_uint32),
            ]

        bih = BITMAPINFOHEADER()
        bih.biSize        = ctypes.sizeof(BITMAPINFOHEADER)
        bih.biWidth       = w
        bih.biHeight      = -h  # top-down
        bih.biPlanes      = 1
        bih.biBitCount    = 32
        bih.biCompression = 0  # BI_RGB

        buf = (ctypes.c_char * (w * h * 4))()
        gdi32.GetDIBits(hdc_mem, hbm, 0, h, buf, ctypes.byref(bih), 0)
        return Image.frombuffer('RGB', (w, h), bytes(buf), 'raw', 'BGRX', 0, 1).copy()
    finally:
        gdi32.SelectObject(hdc_mem, old)
        gdi32.DeleteObject(hbm)
        gdi32.DeleteDC(hdc_mem)
        user32.ReleaseDC(0, hdc_screen)

def get_combo_hwnd(parent_hwnd) -> int | None:
    """Return HWND of the first ComboBox child of parent_hwnd."""
    found = []
    WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    def cb(hwnd, _):
        cls = ctypes.create_unicode_buffer(64)
        user32.GetClassNameW(hwnd, cls, 64)
        if 'ComboBox' in cls.value:
            found.append(hwnd)
        return True
    user32.EnumChildWindows(parent_hwnd, WNDENUMPROC(cb), 0)
    return found[0] if found else None

def select_combo_item(parent_hwnd, combo_hwnd, index: int):
    """
    Programmatically select a ComboBox item and notify the parent window
    via WM_COMMAND / CBN_SELCHANGE so that LCL's OnChange fires.
    """
    CB_SETCURSEL  = 0x014E
    WM_COMMAND    = 0x0111
    CBN_SELCHANGE = 1
    user32.SendMessageW(combo_hwnd, CB_SETCURSEL, index, 0)
    ctrl_id = user32.GetDlgCtrlID(combo_hwnd)
    wparam  = (CBN_SELCHANGE << 16) | (ctrl_id & 0xFFFF)
    user32.SendMessageW(parent_hwnd, WM_COMMAND, wparam, combo_hwnd)


def combo_item_text(combo_hwnd, idx: int) -> str:
    CB_GETLBTEXT    = 0x0148
    CB_GETLBTEXTLEN = 0x0149
    n = user32.SendMessageW(combo_hwnd, CB_GETLBTEXTLEN, idx, 0)
    if n <= 0:
        return ''
    buf = ctypes.create_unicode_buffer(n + 1)
    user32.SendMessageW(combo_hwnd, CB_GETLBTEXT, idx, buf)
    return buf.value


def combo_selected_text(combo_hwnd) -> str:
    """Return the current ComboBox item text (skin filename without .skn)."""
    CB_GETCURSEL = 0x0147
    idx = user32.SendMessageW(combo_hwnd, CB_GETCURSEL, 0, 0)
    if idx < 0:
        return ''
    return combo_item_text(combo_hwnd, idx)


def pick_second_skin_index(combo_hwnd, count: int) -> int:
    """Pick a second skin whose geometry is obviously different from item 0."""
    names = [combo_item_text(combo_hwnd, i) for i in range(count)]
    first = names[0] if names else ''
    for preferred in (
        'Subaru_Offbeat_TTPlayer57',
        'HiFi',
        'WMP10',
        'Winamp Modern',
        'Serein Flat',
        'orange',
    ):
        if preferred in names and preferred != first:
            return names.index(preferred)
    return 1 if count > 1 else 0

def nonblank_spread(img: Image.Image, x=0, y=0, w=50, h=50) -> int:
    """Max per-channel (R/G/B) range in the given region."""
    w = min(w, img.width)
    h = min(h, img.height)
    region = img.crop((x, y, x + w, y + h)).convert('RGB')
    extrema = region.getextrema()
    return max(hi - lo for lo, hi in extrema[:3])

def save(img: Image.Image, name: str):
    path = os.path.join(ARTIFACT_DIR, f'{name}.png')
    img.save(path)
    print(f'  screenshot: {path}')

def click_client(hwnd, x: int, y: int):
    """Send WM_MOUSEMOVE + WM_LBUTTONDOWN/UP in client coordinates."""
    lparam = (int(y) << 16) | (int(x) & 0xFFFF)
    user32.SendMessageW(hwnd, 0x0200, MK_LBUTTON, lparam)  # WM_MOUSEMOVE
    user32.SendMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, lparam)
    user32.SendMessageW(hwnd, WM_LBUTTONUP, 0, lparam)
    user32.PostMessageW(hwnd, 0x0200, MK_LBUTTON, lparam)
    user32.PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, lparam)
    user32.PostMessageW(hwnd, WM_LBUTTONUP, 0, lparam)


def click_client_screen(hwnd, x: int, y: int):
    """Real cursor click in client coords (bypasses some SendMessage quirks)."""
    pt = wintypes.POINT(int(x), int(y))
    user32.ClientToScreen(hwnd, ctypes.byref(pt))
    user32.SetForegroundWindow(hwnd)
    user32.SetCursorPos(pt.x, pt.y)
    time.sleep(0.05)
    user32.mouse_event(0x0002, 0, 0, 0, 0)  # LEFTDOWN
    user32.mouse_event(0x0004, 0, 0, 0, 0)  # LEFTUP


def find_hwnd_by_title(pid: int, part: str) -> int | None:
    found = []
    WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    part_l = part.lower()

    def cb(hwnd, _):
        proc = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(proc))
        if int(proc.value) != int(pid):
            return True
        if not user32.IsWindowVisible(hwnd):
            return True
        title = get_window_text(hwnd)
        if part_l in title.lower():
            found.append(int(hwnd))
        return True

    user32.EnumWindows(WNDENUMPROC(cb), 0)
    return found[0] if found else None


def get_window_text(hwnd) -> str:
    n = int(user32.GetWindowTextLengthW(hwnd)) + 1
    buf = ctypes.create_unicode_buffer(n)
    user32.GetWindowTextW(hwnd, buf, n)
    return buf.value


def client_size(hwnd) -> tuple[int, int]:
    rc = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rc))
    return rc.right - rc.left, rc.bottom - rc.top


def eq_enabled_logical_size(skin_name: str) -> tuple[int, int] | None:
    path = os.path.join(SKINJSON_DIR, f'{skin_name}.json')
    if not os.path.isfile(path):
        return None
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
    bg = (data.get('equalizer_window') or {}).get('background_size') or {}
    w, h = int(bg.get('w') or 0), int(bg.get('h') or 0)
    if w <= 0 or h <= 0:
        return None
    return w, h


def window_rect(hwnd):
    rc = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rc))
    return rc.left, rc.top, rc.right, rc.bottom


def raise_window(hwnd):
    hwnd = int(hwnd)
    user32.SetWindowPos(
        hwnd, HWND_TOP, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE)
    user32.SetForegroundWindow(hwnd)


def drag_move(hwnd, x, y):
    """Simulate HTCAPTION drag: ENTERSIZEMOVE + SetWindowPos + EXITSIZEMOVE.

    LCL WindowProc does not see cross-process SendMessage of those two;
    skinpreview subclasses the native WndProc so this reaches TWindowSnapManager.
    """
    hwnd = int(hwnd)
    user32.SendMessageW(hwnd, WM_ENTERSIZEMOVE, 0, 0)
    user32.SetWindowPos(
        hwnd, 0, int(x), int(y), 0, 0,
        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)
    user32.SendMessageW(hwnd, WM_EXITSIZEMOVE, 0, 0)


def eq_enabled_click_point(skin_name: str) -> tuple[int, int] | None:
    path = os.path.join(SKINJSON_DIR, f'{skin_name}.json')
    if not os.path.isfile(path):
        return None
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
    elems = (data.get('equalizer_window') or {}).get('elements') or []
    for el in elems:
        if str(el.get('type', '')).lower() == 'enabled':
            pos = el.get('position') or {}
            x = int(pos.get('x', 0)) + max(1, int(pos.get('w', 10))) // 2
            y = int(pos.get('y', 0)) + max(1, int(pos.get('h', 10))) // 2
            return x, y
    return None


def identify_subwindows(sub):
    """按标题识别四个子窗口；标题缺失时按面积回退。"""
    named = {}
    for w in sub:
        title = (w.window_text() or '').lower()
        if 'playlist' in title:
            named['playlist'] = w
        elif 'lyric' in title:
            named['lyric'] = w
        elif 'equalizer' in title:
            named['eq'] = w
        elif 'player' in title:
            named['player'] = w
    if all(k in named for k in ('player', 'eq', 'lyric', 'playlist')):
        return named

    # 回退：面积升序 → Lyric 最小、Playlist 最大，中间两个为 Player/EQ
    sized = [(physical_size(w.handle), w) for w in sub]
    sized.sort(key=lambda t: t[0][0] * t[0][1])
    named.setdefault('lyric', sized[0][1])
    named.setdefault('playlist', sized[-1][1])
    mid = [w for _, w in sized[1:-1]]
    if len(mid) >= 2:
        named.setdefault('player', mid[0])
        named.setdefault('eq', mid[-1])
    elif len(mid) == 1:
        named.setdefault('player', mid[0])
        named.setdefault('eq', mid[0])
    return named

# ── Main ────────────────────────────────────────────────────────────────────

def main() -> int:
    app = None
    try:
        # ── 启动 ─────────────────────────────────────────────────────────
        os.system('taskkill.exe /IM skinpreview.exe /F > nul 2>&1')
        time.sleep(0.4)
        print('[smoke] 启动 skinpreview.exe ...')
        app = Application(backend='uia').start(EXE, timeout=10)

        ctrl_win = app.window(title_re=r'.*Skin Preview.*')
        ctrl_win.wait('visible ready', timeout=15)
        print('[smoke] 1/10  控制面板窗口已就绪')

        # ── 1. 标题检查 ──────────────────────────────────────────────────
        title = ctrl_win.window_text()
        assert 'Skin Preview' in title, f'意外标题: {title!r}'
        print(f'[smoke] 2/10  标题正确: {title!r}')

        # ── 2. 下拉框有皮肤选项 ──────────────────────────────────────────
        combo_hwnd = get_combo_hwnd(ctrl_win.handle)
        assert combo_hwnd, '未找到 ComboBox 控件'

        CB_GETCOUNT = 0x0146
        skin_count = int(user32.SendMessageW(combo_hwnd, CB_GETCOUNT, 0, 0))
        assert skin_count > 0, '皮肤下拉框为空'
        assert skin_count <= 20, f'皮肤数量异常（{skin_count}），可能目录路径错误'
        print(f'[smoke] 3/10  下拉框有 {skin_count} 个皮肤')

        # ── 3. 四个子窗口：Player / Equalizer / Lyric / Playlist ────────
        def proc_subwins():
            return [w for w in Desktop(backend='uia').windows(visible_only=True)
                    if w.process_id() == ctrl_win.process_id()
                       and w.handle != ctrl_win.handle]

        try:
            wait_until(timeout=8, retry_interval=0.2,
                func=lambda: len(proc_subwins()) >= 4)
        except PWATimeout:
            pass

        sub = proc_subwins()
        assert len(sub) >= 4, \
            f'期望 ≥4 个子窗口（Player+EQ+Lyric+Playlist），实际 {len(sub)}'

        wins = identify_subwindows(sub)
        assert 'player' in wins, '未识别到 Player 窗口'
        assert 'eq' in wins, '未识别到 Equalizer 窗口'
        assert 'lyric' in wins, '未识别到 Lyric 窗口'
        assert 'playlist' in wins, '未识别到 Playlist 窗口'
        player_win, eq_win = wins['player'], wins['eq']
        lyric_win, playlist_win = wins['lyric'], wins['playlist']

        lw, lh = physical_size(lyric_win.handle)
        pw, ph = physical_size(player_win.handle)
        ew, eh = physical_size(eq_win.handle)
        plw, plh = physical_size(playlist_win.handle)
        assert pw >= 100 and ph >= 50, f'PlayerForm 尺寸异常: {pw}×{ph}'
        assert ew >= 100 and eh >= 50, f'EqualizerForm 尺寸异常: {ew}×{eh}'
        assert lw >= 100 and lh >= 30, f'LyricForm 尺寸异常: {lw}×{lh}'
        assert plw >= 100 and plh >= 50, f'PlaylistForm 尺寸异常: {plw}×{plh}'
        print(f'[smoke] 4/10  Player {pw}×{ph}  EQ {ew}×{eh}  '
              f'Lyric {lw}×{lh}  Playlist {plw}×{plh}')

        # ── 4. 全部窗口背景已渲染（PrintWindow 截图）───────────────────
        img_p = grab_window(player_win.handle)
        img_e = grab_window(eq_win.handle)
        img_l = grab_window(lyric_win.handle)
        img_pl = grab_window(playlist_win.handle)
        assert img_p is not None, 'PlayerForm 截图失败'
        assert img_e is not None, 'EqualizerForm 截图失败'
        assert img_l is not None, 'LyricForm 截图失败'
        assert img_pl is not None, 'PlaylistForm 截图失败'
        save(img_p, 'player_default')
        save(img_e, 'equalizer_default')
        save(img_l, 'lyric_default')
        save(img_pl, 'playlist_default')

        sp = nonblank_spread(img_p)
        se = nonblank_spread(img_e)
        sl = nonblank_spread(img_l)
        spl = nonblank_spread(img_pl)
        assert sp > 10, f'PlayerForm 近乎空白（spread={sp}），皮肤可能未渲染'
        assert se > 10, f'EqualizerForm 近乎空白（spread={se}），皮肤可能未渲染'
        assert sl > 10, f'LyricForm 近乎空白（spread={sl}），皮肤可能未渲染'
        assert spl > 10, f'PlaylistForm 近乎空白（spread={spl}），皮肤可能未渲染'
        print(f'[smoke] 5/10  背景渲染 OK  player={sp}  eq={se}  '
              f'lyric={sl}  playlist={spl}')

        # ── 5. 切换到几何差异明显的第二套皮肤 ────────────────────────
        img_p2 = img_e2 = img_l2 = img_pl2 = None
        pw2, ph2, ew2, eh2, lw2, lh2, plw2, plh2 = pw, ph, ew, eh, lw, lh, plw, plh
        if skin_count > 1:
            second_idx = pick_second_skin_index(combo_hwnd, skin_count)
            second_name = combo_item_text(combo_hwnd, second_idx)
            print(f'[smoke]     切换 {combo_selected_text(combo_hwnd)!r} → {second_name!r}')
            select_combo_item(ctrl_win.handle, combo_hwnd, second_idx)

            deadline = time.time() + 3.0
            while time.time() < deadline:
                sub2 = proc_subwins()
                if len(sub2) >= 4:
                    wins2 = identify_subwindows(sub2)
                    p2 = wins2.get('player') or player_win
                    pw2, ph2 = physical_size(p2.handle)
                    if (pw2, ph2) != (pw, ph):
                        player_win = p2
                        eq_win = wins2.get('eq') or eq_win
                        lyric_win = wins2.get('lyric') or lyric_win
                        playlist_win = wins2.get('playlist') or playlist_win
                        break
                time.sleep(0.15)
            else:
                sub2 = proc_subwins()
                if len(sub2) >= 4:
                    wins2 = identify_subwindows(sub2)
                    player_win = wins2.get('player') or player_win
                    eq_win = wins2.get('eq') or eq_win
                    lyric_win = wins2.get('lyric') or lyric_win
                    playlist_win = wins2.get('playlist') or playlist_win

            pw2, ph2 = physical_size(player_win.handle)
            ew2, eh2 = physical_size(eq_win.handle)
            lw2, lh2 = physical_size(lyric_win.handle)
            plw2, plh2 = physical_size(playlist_win.handle)
            img_p2 = grab_window(player_win.handle)
            img_e2 = grab_window(eq_win.handle)
            img_l2 = grab_window(lyric_win.handle)
            img_pl2 = grab_window(playlist_win.handle)
            if img_p2: save(img_p2, 'player_skin2')
            if img_e2: save(img_e2, 'equalizer_skin2')
            if img_l2: save(img_l2, 'lyric_skin2')
            if img_pl2: save(img_pl2, 'playlist_skin2')

            p_changed = (pw2, ph2) != (pw, ph)
            e_changed = (ew2, eh2) != (ew, eh)
            l_changed = (lw2, lh2) != (lw, lh)
            pl_changed = (plw2, plh2) != (plw, plh)
            print(f'[smoke] 6/10  切换皮肤  Player {pw}×{ph}→{pw2}×{ph2} '
                  f'{"变化" if p_changed else "同前"}  '
                  f'EQ {"变化" if e_changed else "同前"}  '
                  f'Lyric {"变化" if l_changed else "同前"}  '
                  f'Playlist {"变化" if pl_changed else "同前"}')

            if img_e2:
                se2 = nonblank_spread(img_e2)
                assert se2 > 10, \
                    f'切换皮肤后 EqualizerForm 近乎空白（spread={se2}）'
            if img_l2:
                sl2 = nonblank_spread(img_l2)
                assert sl2 > 10, \
                    f'切换皮肤后 LyricForm 近乎空白（spread={sl2}）'
            if img_pl2:
                spl2 = nonblank_spread(img_pl2)
                assert spl2 > 10, \
                    f'切换皮肤后 PlaylistForm 近乎空白（spread={spl2}）'

        # ── 6. 皮肤名出现在标题中 ────────────────────────────────────────
        new_title = ctrl_win.window_text()
        assert 'Skin Preview' in new_title, f'切换后标题异常: {new_title!r}'
        print(f'[smoke] 7/10  切换后标题: {new_title!r}')

        # 换肤：窗口尺寸变化，或至少有一个窗口的截图与默认皮肤不同
        size_changed = (
            (pw2, ph2) != (pw, ph) or (ew2, eh2) != (ew, eh) or
            (lw2, lh2) != (lw, lh) or (plw2, plh2) != (plw, plh))
        skin_pixels_changed = False
        if img_p is not None and img_p2 is not None:
            skin_pixels_changed = img_p.tobytes() != img_p2.tobytes()
        if img_e is not None and img_e2 is not None:
            skin_pixels_changed = skin_pixels_changed or (
                img_e.tobytes() != img_e2.tobytes())
        if img_pl is not None and img_pl2 is not None:
            skin_pixels_changed = skin_pixels_changed or (
                img_pl.tobytes() != img_pl2.tobytes())
        if skin_count > 1:
            assert size_changed or skin_pixels_changed, \
                '切换皮肤后窗口尺寸与截图像素均未变化'
            print('[smoke] 8/10  换肤已生效'
                  f'（尺寸{"变" if size_changed else "同"} '
                  f'像素{"变" if skin_pixels_changed else "同"}）')
        else:
            print('[smoke] 8/10  仅一套皮肤，跳过像素差')

        # ── 8. 换回较小皮肤，再点 EQ enabled（Subaru 下 Player 会盖住按钮）
        # 150% DPI 下 GetWindowRect 是物理像素，吸附用 LCL Form.Width。
        if skin_count > 1:
            select_combo_item(ctrl_win.handle, combo_hwnd, 0)
            deadline = time.time() + 3.0
            while time.time() < deadline:
                if physical_size(player_win.handle) == (pw, ph):
                    break
                time.sleep(0.15)
            sub3 = proc_subwins()
            if len(sub3) >= 4:
                wins3 = identify_subwindows(sub3)
                player_win = wins3.get('player') or player_win
                eq_win = wins3.get('eq') or eq_win

        time.sleep(0.3)
        pid = ctrl_win.process_id()
        eq_hwnd = find_hwnd_by_title(pid, 'Equalizer') or int(eq_win.handle)
        snap_skin = combo_selected_text(combo_hwnd) or 'ArcticAMP'
        pt = eq_enabled_click_point(snap_skin)
        before_eq = get_window_text(eq_hwnd) or eq_win.window_text()
        raise_window(eq_hwnd)
        if pt:
            candidates = [(pt[0], pt[1])]
            logical = eq_enabled_logical_size(snap_skin)
            cw, ch = client_size(eq_hwnd)
            if logical and logical[0] > 0 and abs(cw - logical[0]) > 2:
                candidates.append((
                    int(pt[0] * cw / logical[0] + 0.5),
                    int(pt[1] * ch / logical[1] + 0.5)))
            after_eq = before_eq
            tried = []
            for attempt in range(3):
                raise_window(eq_hwnd)
                for cx, cy in candidates:
                    tried.append((cx, cy, attempt))
                    click_client(eq_hwnd, cx, cy)
                    time.sleep(0.25)
                    after_eq = get_window_text(eq_hwnd)
                    if 'ON' in after_eq:
                        break
                    click_client_screen(eq_hwnd, cx, cy)
                    time.sleep(0.25)
                    after_eq = get_window_text(eq_hwnd)
                    if 'ON' in after_eq:
                        break
                if 'ON' in after_eq:
                    break
            img_eq_on = grab_window(eq_hwnd)
            if img_eq_on:
                save(img_eq_on, 'equalizer_on')
            assert 'ON' in after_eq, \
                f'EQ 开关后标题应为 Equalizer ON，实际 {after_eq!r}' \
                f'（点击 {tried}，之前 {before_eq!r}，client={cw}×{ch} hwnd={eq_hwnd}）'
            print(f'[smoke] 9/10  EQ 开关 OK  {before_eq!r} → {after_eq!r}')
        else:
            print(f'[smoke] 9/10  未找到 {snap_skin} 的 enabled 坐标，跳过 EQ 开关')

        # ── 9. 吸附：按皮肤逻辑宽度留 5px 缝 ───────────────────────────
        pid = ctrl_win.process_id()
        player_hwnd = find_hwnd_by_title(pid, 'Player') or int(player_win.handle)
        eq_hwnd = find_hwnd_by_title(pid, 'Equalizer') or int(eq_win.handle)
        eq_log = eq_enabled_logical_size(snap_skin)
        eq_phys_w, _ = physical_size(eq_hwnd)
        eq_log_w = eq_log[0] if eq_log else eq_phys_w
        dpi = eq_phys_w / float(eq_log_w) if eq_log_w else 1.0

        # 先把 Player 拉开，再停 EQ：否则 EQ 若仍连着主窗口，主窗口拖动会带着它走，
        # FinalSnapGroupToStaticWindows 也会跳过已吸附的 EQ。
        drag_move(player_hwnd, 720, 80)
        time.sleep(0.1)
        drag_move(eq_hwnd, 80, 200)
        time.sleep(0.1)
        el, et, er, eb = window_rect(eq_hwnd)
        # 5 个 LCL 像素的缝：吸附阈值是 10 逻辑像素，物理像素 = LCL × DPI
        target_x = int(round((el / dpi + eq_log_w + 5) * dpi))
        target_y = et
        drag_move(player_hwnd, target_x, target_y)
        time.sleep(0.3)
        pl2, pt2, pr2, pb2 = window_rect(player_hwnd)
        el2, et2, er2, eb2 = window_rect(eq_hwnd)
        gap_lcl = (pl2 / dpi) - (el2 / dpi + eq_log_w)
        assert abs(gap_lcl) <= 2.5, \
            f'吸附后 Player 左缘应对齐 EQ 逻辑右缘，LCL 间隙 {gap_lcl:.1f}px ' \
            f'(player={pl2},{pt2}-{pr2},{pb2} eq={el2},{et2}-{er2},{eb2} ' \
            f'eq_log_w={eq_log_w} dpi={dpi:.3f} placed={target_x} ' \
            f'hwnds=player:{player_hwnd} eq:{eq_hwnd})'
        print(f'[smoke] 10/10  吸附 OK  gap_lcl={gap_lcl:.1f}px dpi={dpi:.2f}')

        print('[smoke] PASS 全部检查通过')
        return 0

    except AssertionError as e:
        print(f'[smoke] FAIL: {e}', file=sys.stderr)
        return 1
    except Exception as e:
        print(f'[smoke] ERROR: {e}', file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return 1
    finally:
        if app:
            try:
                app.kill()
            except Exception:
                pass
        os.system('taskkill.exe /IM skinpreview.exe /F > nul 2>&1')


if __name__ == '__main__':
    sys.exit(main())
