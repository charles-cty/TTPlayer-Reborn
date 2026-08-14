"""
tools/smoke_skinpreview.py
皮肤预览工具的 GUI 冒烟测试（PlayerForm + EqualizerForm）。

变更历史：
- v1: 初始版本（PlayerForm 单窗口）
- v2: 增加 EqualizerForm 检查；改用 Win32 CB_SETCURSEL + WM_COMMAND
      触发皮肤切换（UIA .select() / click_input() 在无桌面会话中不可靠）；
      改用 PrintWindow 截图（ImageGrab.grab 需真实桌面会话）。
"""
import sys
import time
import os
import io
import ctypes
import struct
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
os.makedirs(ARTIFACT_DIR, exist_ok=True)

user32 = ctypes.windll.user32
gdi32  = ctypes.windll.gdi32

# ── Win32 helpers ───────────────────────────────────────────────────────────

def physical_size(hwnd) -> tuple:
    """Return (width, height) in physical pixels via GetWindowRect."""
    rc = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rc))
    return rc.right - rc.left, rc.bottom - rc.top

def grab_window(hwnd) -> Image.Image | None:
    """
    Capture a window's client area via PrintWindow (PW_CLIENTONLY=2).
    Works without a real desktop session; falls back to None on error.
    """
    rc = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rc))
    w = rc.right - rc.left
    h = rc.bottom - rc.top
    if w <= 0 or h <= 0:
        return None
    try:
        hdc_screen = user32.GetDC(0)
        hdc_mem    = gdi32.CreateCompatibleDC(hdc_screen)
        hbm        = gdi32.CreateCompatibleBitmap(hdc_screen, w, h)
        gdi32.SelectObject(hdc_mem, hbm)
        user32.PrintWindow(hwnd, hdc_mem, 2)  # PW_CLIENTONLY

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
        bih.biSize       = ctypes.sizeof(BITMAPINFOHEADER)
        bih.biWidth      = w
        bih.biHeight     = -h  # top-down
        bih.biPlanes     = 1
        bih.biBitCount   = 32
        bih.biCompression = 0  # BI_RGB

        buf = (ctypes.c_char * (w * h * 4))()
        gdi32.GetDIBits(hdc_mem, hbm, 0, h, buf, ctypes.byref(bih), 0)

        pixels = [struct.unpack_from('BBB', buf, i*4)[::-1]  # BGR → RGB
                  for i in range(w * h)]
        img = Image.new('RGB', (w, h))
        img.putdata([(r, g, b) for b, g, r in pixels])
        return img
    finally:
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

# ── Main ────────────────────────────────────────────────────────────────────

def main() -> int:
    app = None
    try:
        # ── 启动 ─────────────────────────────────────────────────────────
        print('[smoke] 启动 skinpreview.exe ...')
        app = Application(backend='uia').start(EXE, timeout=10)

        ctrl_win = app.window(title_re=r'.*Skin Preview.*')
        ctrl_win.wait('visible ready', timeout=15)
        print('[smoke] 1/7  控制面板窗口已就绪')

        # ── 1. 标题检查 ──────────────────────────────────────────────────
        title = ctrl_win.window_text()
        assert 'Skin Preview' in title, f'意外标题: {title!r}'
        print(f'[smoke] 2/7  标题正确: {title!r}')

        # ── 2. 下拉框有皮肤选项 ──────────────────────────────────────────
        combo_hwnd = get_combo_hwnd(ctrl_win.handle)
        assert combo_hwnd, '未找到 ComboBox 控件'

        combos = ctrl_win.descendants(control_type='ComboBox')
        assert combos, '未找到 ComboBox（UIA）'
        combos[0].expand()
        time.sleep(0.3)
        skin_lists = Desktop(backend='uia').windows(control_type='List')
        assert skin_lists, '展开下拉框后未找到皮肤列表'
        items = skin_lists[0].descendants(control_type='ListItem')
        skin_count = len(items)
        from pywinauto.keyboard import send_keys
        send_keys('{ESC}')
        time.sleep(0.1)
        assert skin_count > 0, '皮肤下拉框为空'
        assert skin_count <= 20, f'皮肤数量异常（{skin_count}），可能目录路径错误'
        print(f'[smoke] 3/7  下拉框有 {skin_count} 个皮肤')

        # ── 3. PlayerForm + EqualizerForm + LyricForm 三个子窗口 ──────────
        def proc_subwins():
            return [w for w in Desktop(backend='uia').windows(visible_only=True)
                    if w.process_id() == ctrl_win.process_id()
                       and w.handle != ctrl_win.handle]

        try:
            wait_until(timeout=8, retry_interval=0.2,
                func=lambda: len(proc_subwins()) >= 3)
        except PWATimeout:
            pass

        sub = proc_subwins()
        assert len(sub) >= 3, \
            f'期望 ≥3 个子窗口（Player+EQ+Lyric），实际 {len(sub)}'

        # 按面积升序：LyricForm 通常最小，Player 和 EQ 次之
        sub_sizes = [(physical_size(w.handle), i) for i, w in enumerate(sub)]
        sub_sizes.sort(key=lambda t: t[0][0] * t[0][1])
        lyric_win  = sub[sub_sizes[0][1]]
        player_win = sub[sub_sizes[1][1]]
        eq_win     = sub[sub_sizes[-1][1]]

        lw, lh = physical_size(lyric_win.handle)
        pw, ph = physical_size(player_win.handle)
        ew, eh = physical_size(eq_win.handle)
        assert pw >= 100 and ph >= 50, f'PlayerForm 尺寸异常: {pw}×{ph}'
        assert ew >= 100 and eh >= 50, f'EqualizerForm 尺寸异常: {ew}×{eh}'
        assert lw >= 100 and lh >= 30, f'LyricForm 尺寸异常: {lw}×{lh}'
        print(f'[smoke] 4/7  Player {pw}×{ph}  EQ {ew}×{eh}  Lyric {lw}×{lh}')

        # ── 4. 全部窗口背景已渲染（PrintWindow 截图）───────────────────
        img_p = grab_window(player_win.handle)
        img_e = grab_window(eq_win.handle)
        img_l = grab_window(lyric_win.handle)
        assert img_p is not None, 'PlayerForm 截图失败'
        assert img_e is not None, 'EqualizerForm 截图失败'
        assert img_l is not None, 'LyricForm 截图失败'
        save(img_p, 'player_default')
        save(img_e, 'equalizer_default')
        save(img_l, 'lyric_default')

        sp = nonblank_spread(img_p)
        se = nonblank_spread(img_e)
        sl = nonblank_spread(img_l)
        assert sp > 10, f'PlayerForm 近乎空白（spread={sp}），皮肤可能未渲染'
        assert se > 10, f'EqualizerForm 近乎空白（spread={se}），皮肤可能未渲染'
        assert sl > 10, f'LyricForm 近乎空白（spread={sl}），皮肤可能未渲染'
        print(f'[smoke] 5/7  背景渲染 OK  player={sp}  eq={se}  lyric={sl}')

        # ── 5. 切换到第二个皮肤，三个窗口应同步更新 ────────────────────
        if skin_count > 1:
            select_combo_item(ctrl_win.handle, combo_hwnd, 1)
            time.sleep(0.8)

            sub2 = proc_subwins()
            if len(sub2) >= 3:
                sub2_sizes = [(physical_size(w.handle), i)
                              for i, w in enumerate(sub2)]
                sub2_sizes.sort(key=lambda t: t[0][0] * t[0][1])
                l2 = sub2[sub2_sizes[0][1]]
                p2 = sub2[sub2_sizes[1][1]]
                e2 = sub2[sub2_sizes[-1][1]]

                lw2, lh2 = physical_size(l2.handle)
                pw2, ph2 = physical_size(p2.handle)
                ew2, eh2 = physical_size(e2.handle)
                img_p2 = grab_window(p2.handle)
                img_e2 = grab_window(e2.handle)
                img_l2 = grab_window(l2.handle)
                if img_p2: save(img_p2, 'player_skin2')
                if img_e2: save(img_e2, 'equalizer_skin2')
                if img_l2: save(img_l2, 'lyric_skin2')

                p_changed = (pw2, ph2) != (pw, ph)
                e_changed = (ew2, eh2) != (ew, eh)
                l_changed = (lw2, lh2) != (lw, lh)
                print(f'[smoke] 6/7  切换皮肤  Player {"变化" if p_changed else "同前"}  '
                      f'EQ {"变化" if e_changed else "同前"}  '
                      f'Lyric {"变化" if l_changed else "同前"}')

                if img_e2:
                    se2 = nonblank_spread(img_e2)
                    assert se2 > 10, \
                        f'切换皮肤后 EqualizerForm 近乎空白（spread={se2}）'
                if img_l2:
                    sl2 = nonblank_spread(img_l2)
                    assert sl2 > 10, \
                        f'切换皮肤后 LyricForm 近乎空白（spread={sl2}）'

        # ── 6. 皮肤名出现在标题中 ────────────────────────────────────────
        new_title = ctrl_win.window_text()
        assert 'Skin Preview' in new_title, f'切换后标题异常: {new_title!r}'
        print(f'[smoke] 7/7  切换后标题: {new_title!r}')

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
