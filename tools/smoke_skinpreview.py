"""
tools/smoke_skinpreview.py
皮肤预览工具的 GUI 冒烟测试。
"""
import sys
import time
import os
import io

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

EXE = r'C:\My\Repos\TTPlayer-Reborn\pascal\bin\skinpreview.exe'
ARTIFACT_DIR = r'C:\My\Repos\TTPlayer-Reborn\tests\artifacts\smoke'
os.makedirs(ARTIFACT_DIR, exist_ok=True)

def save_screenshot(img: Image.Image, name: str):
    path = os.path.join(ARTIFACT_DIR, f'{name}.png')
    img.save(path)
    print(f'  screenshot: {path}')

def nonblank_pixel_spread(img: Image.Image, x, y, w, h) -> int:
    """Return the max per-channel range in a region (0 = blank/solid)."""
    region = img.crop((x, y, x + w, y + h)).convert('RGB')
    extrema = region.getextrema()
    return max(hi - lo for lo, hi in extrema[:3])

def main() -> int:
    app = None
    try:
        # ── 启动 ─────────────────────────────────────────────────────────
        print('[smoke] 启动 skinpreview.exe ...')
        app = Application(backend='uia').start(EXE, timeout=10)

        # 控制面板窗口：标题 "Skin Preview"
        ctrl_win = app.window(title_re=r'.*Skin Preview.*')
        ctrl_win.wait('visible ready', timeout=15)
        print('[smoke] 1/5  控制面板窗口已就绪')

        # ── 1. 标题检查 ─────────────────────────────────────────────────
        title = ctrl_win.window_text()
        assert 'Skin Preview' in title, f'意外标题: {title!r}'
        print(f'[smoke] 2/5  标题正确: {title!r}')

        # ── 2. 下拉框有皮肤选项 ─────────────────────────────────────────
        combos = ctrl_win.descendants(control_type='ComboBox')
        assert combos, '未找到 ComboBox 控件'
        combo = combos[0]
        # 展开后皮肤列表出现在桌面顶层 List 窗口中，而非 combo 子节点
        combo.expand()
        time.sleep(0.3)
        skin_lists = Desktop(backend='uia').windows(control_type='List')
        assert skin_lists, '展开下拉框后未找到皮肤列表'
        items = skin_lists[0].descendants(control_type='ListItem')
        skin_count = len(items)
        # 收起：先 Escape 再点击其他区域
        from pywinauto.keyboard import send_keys
        send_keys('{ESC}')
        time.sleep(0.1)
        assert skin_count > 0, '皮肤下拉框为空'
        assert skin_count <= 20, f'皮肤数量异常（{skin_count}），可能目录路径错误'
        print(f'[smoke] 3/5  下拉框有 {skin_count} 个皮肤')

        # ── 3. PlayerForm 窗口出现 ───────────────────────────────────────
        # TPlayerForm 是独立的无边框窗口，标题为空或皮肤名
        try:
            wait_until(
                timeout=5, retry_interval=0.2,
                func=lambda: len(Desktop(backend='uia').windows(
                    class_name_re=r'.*', visible_only=True)) > 1
            )
        except PWATimeout:
            pass  # 继续检测，下面会 assert

        all_wins = Desktop(backend='uia').windows(visible_only=True)
        # skinpreview 进程打开的窗口
        proc_wins = [w for w in all_wins
                     if w.process_id() == ctrl_win.process_id()]
        player_wins = [w for w in proc_wins
                       if w.handle != ctrl_win.handle]
        assert player_wins, 'PlayerForm 窗口未出现'
        player_win = player_wins[0]
        r = player_win.rectangle()
        w_px = r.width()
        h_px = r.height()
        assert w_px >= 100 and h_px >= 50, \
            f'PlayerForm 尺寸异常: {w_px}×{h_px}'
        print(f'[smoke] 4/5  PlayerForm 出现，尺寸 {w_px}×{h_px}')

        # ── 4. PlayerForm 区域不全透明（背景已渲染）────────────────────
        img = player_win.capture_as_image()
        save_screenshot(img, 'player_default')
        spread = nonblank_pixel_spread(img, 0, 0, min(50, img.width),
                                             min(50, img.height))
        assert spread > 10, \
            f'PlayerForm 角落区域近乎空白（spread={spread}），皮肤可能未渲染'
        print(f'[smoke] 5/5  背景已渲染（色彩变化 spread={spread}）')

        # ── 5. 切换皮肤，PlayerForm 尺寸可能变化 ────────────────────────
        if len(items) > 1:
            # 选第二个皮肤——通过键盘下箭头，避免 COM 展开的脆弱性
            combo.click_input()  # 聚焦 combo
            time.sleep(0.1)
            from pywinauto.keyboard import send_keys as sk
            sk('{DOWN}')
            time.sleep(0.5)

            new_wins = [w for w in Desktop(backend='uia').windows(visible_only=True)
                        if w.process_id() == ctrl_win.process_id()
                           and w.handle != ctrl_win.handle]
            if new_wins:
                r2 = new_wins[0].rectangle()
                img2 = new_wins[0].capture_as_image()
                save_screenshot(img2, 'player_skin2')
                print(f'[smoke] 6/6  切换皮肤后尺寸 {r2.width()}×{r2.height()}（'
                      f'{"已变化" if (r2.width(),r2.height())!=(w_px,h_px) else "相同"}）')

        print('[smoke] PASS 全部检查通过')
        return 0

    except AssertionError as e:
        print(f'[smoke] FAIL: {e}', file=sys.stderr)
        # 尝试截图
        try:
            if app:
                for w in Desktop(backend='uia').windows(visible_only=True):
                    if w.process_id() == app.process().__enter__():
                        w.capture_as_image().save(
                            os.path.join(ARTIFACT_DIR, 'fail.png'))
        except Exception:
            pass
        return 1
    except Exception as e:
        print(f'[smoke] ERROR: {e}', file=sys.stderr)
        import traceback; traceback.print_exc()
        return 1
    finally:
        if app:
            try:
                app.kill()
            except Exception:
                pass
        # 清理残留
        os.system('taskkill.exe /IM skinpreview.exe /F > nul 2>&1')


if __name__ == '__main__':
    sys.exit(main())
