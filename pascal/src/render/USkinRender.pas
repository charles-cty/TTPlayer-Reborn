unit USkinRender;

{$mode objfpc}{$H+}

// 皮肤渲染原语，对应 Qt 版 SkinButton/SkinSlider 的 paintEvent 与
// PlayerWindow 的窗口合成逻辑。所有绘制离屏进行（TBGRABitmap 上合成），
// 与 Layer 2 快照测试共用同一条渲染路径。

interface

uses
  Classes, SysUtils, Types, BGRABitmap, BGRABitmapTypes, USkinTypes, UDpiScale;

type
  // 按钮视觉状态（与 Qt 版 currentState 的取值一致）。
  TButtonVisualState = (bvsNormal, bvsHover, bvsPressed, bvsDisabled);

// 计算按钮控件的实际尺寸（对应 SkinButton::setSkinElement 的尺寸推导）。
function ButtonBounds(const Elem: TSkinElement): TSkinRect;

// 在 Dest 上绘制按钮（对应 SkinButton::paintEvent；X/Y 为控件左上角）。
// Scale>1 时按视图缩放拉伸状态图（运行时 DPI）；Layer 2 保持 Scale=1。
procedure DrawButton(Dest: TBGRABitmap; const Elem: TSkinElement;
  const Bounds: TSkinRect; State: TButtonVisualState; Scale: Double = 1.0);

// 在 Dest 上绘制滑块（对应 SkinSlider::paintEvent）。
// Value 为当前值，范围 [MinV, MaxV]；ThumbState 同按钮四态。
procedure DrawSlider(Dest: TBGRABitmap; const Elem: TSkinElement;
  Value, MinV, MaxV: Double; ThumbState: TButtonVisualState);

// 滑块值↔像素位置换算（对应 SkinSlider::valueToPosition / positionToValue）。
// 公开供 Layer 4 metamorphic 测试直接驱动。
// ThumbWidth：thumb 图的宽度（水平）或高度（垂直），参与范围计算。
// TrackLen：控件在移动方向上的总像素数（width 或 height）。
function SliderValueToPos(Value, MinV, MaxV: Double;
  TrackLen, ThumbSize: Integer; Vertical: Boolean): Integer;
function SliderPosToValue(Pos: Integer; MinV, MaxV: Double;
  TrackLen: Integer; Vertical: Boolean): Double;

// 在 Dest 上绘制 LED 位图字体时间（对应 PlayerWindow::drawLedTime）。
// number.bmp 为 "0123456789:-" 12 字符精灵表；Elapsed=False 且 TimeMs>0 时
// 显示剩余时间格式 "-MM:SS"。
procedure DrawLedTime(Dest: TBGRABitmap; const Elem: TSkinElement;
  TimeMs: Int64; Elapsed: Boolean);

// 合成整个 player_window（对应 PlayerWindow 默认帧的渲染结果）。
// ProgressValue 0-1，VolumeValue 0-100；OverrideType/OverrideState 用于
// 强制单个按钮的视觉状态（对应测试钩子），OverrideType='' 表示不启用。
// ToggledMute=True 时静音按钮按切换态（按下图）渲染。
// Playing=False（默认）跳过 pause、绘制 play，与 Layer 2 默认帧一致；
// Playing=True 跳过 play、绘制 pause。LedTimeMs 默认 0 → LED 00:00。
// InfoText 默认空：不画 info 元素，Layer 2 默认帧不变。
// ShowCover=False（默认）不画 visual 封面，保持金样。
function RenderPlayerWindow(const Skin: TSkinData;
  ProgressValue, VolumeValue: Double;
  const OverrideType: string; OverrideState: TButtonVisualState;
  ToggledMute: Boolean;
  Playing: Boolean = False;
  LedTimeMs: Int64 = 0;
  const InfoText: string = '';
  CoverArt: TBGRABitmap = nil;
  ShowCover: Boolean = False): TBGRABitmap;

// 计算第 Band 个 eqfactor 滑块的实际 Position（X 按 eqInterval 偏移）。
// 公开供 UEqualizerForm 命中测试使用，与 RenderEqualizerWindow 保持一致。
function EqFactorRect(const Elem: TSkinElement; Band, EqInterval: Integer): TSkinRect;

// 九宫格背景绘制（公开供 ULyricForm 等使用）。
// Tile=True: 各边/中心平铺；Tile=False: 双线性缩放。
// 绘制范围为 DestW × DestH（已在 Dest 上直接合成）。
// ExclusiveMids=True：边/中心不伸进四角（与 Qt PlaylistWindow / LyricWindow
// rebuildBackground 的 width()-left-right 矩形一致）。False：topMid/bottomMid
// 先铺到 DestW，再由角片覆盖，透明角会透出中段瓦片。
procedure DrawNinePatch(Dest: TBGRABitmap;
  Base: TBGRABitmap; const RR: TSkinRect; Tile: Boolean;
  DestW, DestH: Integer; ExclusiveMids: Boolean = False);

// 最近邻放大/缩小。不要用 BGRA `Resample(..., rmSimpleStretch)`：
// 它对 1px 高/宽图和一般上采样会读越界 ScanLine，Windows DPI≠100% 即 AV。
function NearestResample(Src: TBGRABitmap; DestW, DestH: Integer): TBGRABitmap;

// 窗口客户区尺寸变了就要按新尺寸九宫格重绘，不能把旧帧当放大镜拉伸。
function SkinFrameNeedsRebuild(Frame: TBGRABitmap; DestW, DestH: Integer): Boolean;

// 仅位图拉伸（测试/备用）。播放列表/歌词 live 缩放不要走这条路径。
procedure LiveFillFrame(var Frame: TBGRABitmap; DestW, DestH: Integer);

// Qt alignedRect：按 align 把内容矩形放到当前窗口中。
// ContentW/H<=0 时退回 BaseRect 的宽高。
function AlignedRect(const BaseRect: TSkinRect;
  BaseW, BaseH, CurW, CurH: Integer; const Align: string;
  ContentW: Integer = 0; ContentH: Integer = 0): TSkinRect;

// Qt PlaylistWindow::playlistRect()：随窗口拉伸的列表区。
function PlaylistContentRect(const Skin: TSkinData;
  DestW, DestH: Integer): TSkinRect;

// 合成整个 equalizer_window（对应 EqualizerWindow 的渲染结果）。
// EqGains: 10 波段增益 dB [-12..+12]；PreampGain 前置增益 dB；
// BalanceValue [-100..+100]；SurroundValue [0..100]；
// EqEnabled: 均衡器开关（对应 btnEnabled_ 的 toggled 状态）。
// OverrideType/OverrideState: 强制单个按钮视觉状态（测试用），'' 表示不启用。
// enabled 已打开且精灵上刻有字母时，悬停不覆盖按下态（否则看起来像被关掉）。
function RenderEqualizerWindow(const Skin: TSkinData;
  const EqGains: array of Double; PreampGain: Double;
  BalanceValue, SurroundValue: Double;
  EqEnabled: Boolean;
  const OverrideType: string; OverrideState: TButtonVisualState): TBGRABitmap;

// 状态图是否在亮色面板上刻有字母（如 Winamp Modern 的 EQ）。
// 空心图标的孔相对笔画过大，不会当成字母。
function PixmapHasInscribedText(Bmp: TBGRABitmap): Boolean;
function ButtonHasInscribedText(const Elem: TSkinElement): Boolean;

// 合成整个 lyric_window（对应 LyricWindow 的渲染结果）。
// DestW/DestH 为目标窗口像素尺寸。Layer 2 使用皮肤背景图尺寸（FrameDumper
// 以 baseSize 捕帧）；运行时 ULyricForm 用当前窗口逻辑尺寸。
// 九宫格背景：resizeRect 定义可拉伸中心区；ResizeTile=True 时平铺，否则缩放。
// 渲染内容：background、title、close、ontop 按钮。
// 歌词文本区（lyric 元素）在 masks.json 中被排除，不渲染。
function RenderLyricWindow(const Skin: TSkinData;
  DestW, DestH: Integer): TBGRABitmap;

// 合成整个 playlist_window（对应 PlaylistWindow 的渲染结果）。
// DestW/DestH 为目标窗口像素尺寸。Layer 2 使用皮肤背景图尺寸（FrameDumper
// 以 baseSize 捕帧）；运行时 UPlaylistForm 用当前窗口逻辑尺寸。
// 渲染内容：
//   · 九宫格背景（ExclusiveMids，对齐 Qt rebuildBackground）
//   · title（alignedRect，与 paintEvent 一致）
//   · 工具栏 7 组，普通态精灵图居中裁剪到各组矩形（无悬停/按下状态）
//   · close 按钮（align='right' 时由 rightMargin 计算 X）
// 列表区（playlistRect 内的 tabs/divider/list/scrollbar）由 Layer 2 掩码排除，
// 不在此填充 ColorBkgnd，以免盖住九宫格底边倒角。
function RenderPlaylistWindow(const Skin: TSkinData;
  DestW, DestH: Integer): TBGRABitmap;

implementation

// 皮肤按钮元素类型清单（与 PlayerWindow::createButtons 的 makeBtn 调用一致）。
const
  kPlayerButtonTypes: array[0..12] of string = (
    'play', 'pause', 'stop', 'prev', 'next', 'mute', 'open', 'lyric',
    'equalizer', 'playlist', 'minimode', 'minimize', 'exit');

{ Qt 精确合成：FrameDumper 的渲染目标是非预乘 ARGB32 QImage，QPainter 对
  每次绘制做 预乘 → source-over（div255 舍入）→ 反预乘。逐像素一致必须
  复刻同一套整数舍入，BGRABitmap 自带的混合模式与之存在 ±1 差异。 }

// Qt 的 div255 近似：(x + (x >> 8) + 0x80) >> 8
function QtDiv255(V: Cardinal): Cardinal; inline;
begin
  Result := (V + (V shr 8) + $80) shr 8;
end;

function QtPremul(C, A: Cardinal): Cardinal; inline;
begin
  Result := QtDiv255(C * A);
end;

// qUnpremultiply 精确复刻（qrgb.h）：invAlpha = 0x00ff00ff div a，
// c_out = (c * invAlpha) shr 16 —— 对所有 c、a 等价于 (c*255)/a。
function QtUnpremul(C, A: Cardinal): Cardinal; inline;
begin
  if A = 0 then
    Result := 0
  else if A = 255 then
    Result := C
  else
    Result := (C * ($00FF00FF div A)) shr 16;
end;

// 把 Src 以 Qt source-over 语义绘制到 Dest（两者均为非预乘 alpha）。
// 剪裁到 Dest.ClipRect（默认整图）。
procedure QtPutImage(Dest: TBGRABitmap; X, Y: Integer; Src: TBGRABitmap);
var
  clip: TRect;
  sx, sy, dx, dy, x0, x1, y0, y1: Integer;
  ps, pd: PBGRAPixel;
  sr, sg, sb, sa, dr, dg, db, da, ia, or_, og, ob, oa: Cardinal;
begin
  if Src = nil then Exit;
  clip := Dest.ClipRect;

  y0 := Y; if y0 < clip.Top then y0 := clip.Top;
  y1 := Y + Src.Height; if y1 > clip.Bottom then y1 := clip.Bottom;
  x0 := X; if x0 < clip.Left then x0 := clip.Left;
  x1 := X + Src.Width; if x1 > clip.Right then x1 := clip.Right;
  if (x0 >= x1) or (y0 >= y1) then Exit;

  for dy := y0 to y1 - 1 do
  begin
    sy := dy - Y;
    ps := Src.ScanLine[sy];
    Inc(ps, x0 - X);
    pd := Dest.ScanLine[dy];
    Inc(pd, x0);
    for dx := x0 to x1 - 1 do
    begin
      sa := ps^.alpha;
      if sa = 255 then
        pd^ := ps^
      else if sa > 0 then
      begin
        // 预乘源与目标
        sr := QtPremul(ps^.red, sa);
        sg := QtPremul(ps^.green, sa);
        sb := QtPremul(ps^.blue, sa);
        da := pd^.alpha;
        dr := QtPremul(pd^.red, da);
        dg := QtPremul(pd^.green, da);
        db := QtPremul(pd^.blue, da);
        // source-over
        ia := 255 - sa;
        or_ := sr + QtDiv255(dr * ia);
        og := sg + QtDiv255(dg * ia);
        ob := sb + QtDiv255(db * ia);
        oa := sa + QtDiv255(da * ia);
        // 反预乘写回
        pd^.red := QtUnpremul(or_, oa);
        pd^.green := QtUnpremul(og, oa);
        pd^.blue := QtUnpremul(ob, oa);
        pd^.alpha := oa;
      end;
      Inc(ps);
      Inc(pd);
    end;
  end;
  Dest.InvalidateBitmap;
end;

function NearestResample(Src: TBGRABitmap; DestW, DestH: Integer): TBGRABitmap;
var
  x, y, sx, sy: Integer;
  p, sp: PBGRAPixel;
begin
  if DestW < 1 then DestW := 1;
  if DestH < 1 then DestH := 1;
  Result := TBGRABitmap.Create(DestW, DestH);
  if (Src = nil) or (Src.Width < 1) or (Src.Height < 1) then
    Exit;
  if (Src.Width = DestW) and (Src.Height = DestH) then
  begin
    Result.PutImage(0, 0, Src, dmSet);
    Exit;
  end;
  for y := 0 to DestH - 1 do
  begin
    // Qt fast transform：src = floor((d+0.5)*sw/dw - 0.5)，再夹到扫描行。
    sy := ((Int64(2) * y + 1) * Src.Height - DestH) div (Int64(2) * DestH);
    if sy < 0 then sy := 0;
    if sy > Src.Height - 1 then sy := Src.Height - 1;
    sp := Src.ScanLine[sy];
    p := Result.ScanLine[y];
    for x := 0 to DestW - 1 do
    begin
      sx := ((Int64(2) * x + 1) * Src.Width - DestW) div (Int64(2) * DestW);
      if sx < 0 then sx := 0;
      if sx > Src.Width - 1 then sx := Src.Width - 1;
      p^ := (sp + sx)^;
      Inc(p);
    end;
  end;
  Result.InvalidateBitmap;
end;

function SkinFrameNeedsRebuild(Frame: TBGRABitmap; DestW, DestH: Integer): Boolean;
begin
  Result := (Frame = nil) or (DestW < 1) or (DestH < 1) or
    (Frame.Width <> DestW) or (Frame.Height <> DestH);
end;

procedure LiveFillFrame(var Frame: TBGRABitmap; DestW, DestH: Integer);
var
  next, scaled: TBGRABitmap;
begin
  if DestW < 1 then DestW := 1;
  if DestH < 1 then DestH := 1;
  if Frame = nil then
  begin
    Frame := TBGRABitmap.Create(DestW, DestH, BGRAPixelTransparent);
    Exit;
  end;
  if (Frame.Width = DestW) and (Frame.Height = DestH) then
    Exit;
  next := TBGRABitmap.Create(DestW, DestH, BGRAPixelTransparent);
  try
    scaled := NearestResample(Frame, DestW, DestH);
    try
      next.PutImage(0, 0, scaled, dmSet);
    finally
      scaled.Free;
    end;
    Frame.Free;
    Frame := next;
    next := nil;
  finally
    next.Free;
  end;
end;

// 等价于 QPainter::drawPixmap(destRect, pixmap)（无平滑变换）：
// 最近邻缩放。Qt fast transform 以目标像素中心反算源坐标：
// src = floor((d + 0.5) * sw / dw)。
procedure QtStretchPutImage(Dest: TBGRABitmap; const DestRect: TRect;
  Src: TBGRABitmap);
var
  tmp: TBGRABitmap;
  dw, dh: Integer;
begin
  if (Src = nil) or (Dest = nil) then Exit;
  if (Src.Width < 1) or (Src.Height < 1) then Exit;
  dw := DestRect.Right - DestRect.Left;
  dh := DestRect.Bottom - DestRect.Top;
  if (dw <= 0) or (dh <= 0) then Exit;

  if (dw = Src.Width) and (dh = Src.Height) then
  begin
    QtPutImage(Dest, DestRect.Left, DestRect.Top, Src);
    Exit;
  end;

  tmp := NearestResample(Src, dw, dh);
  try
    QtPutImage(Dest, DestRect.Left, DestRect.Top, tmp);
  finally
    tmp.Free;
  end;
end;

function ButtonBounds(const Elem: TSkinElement): TSkinRect;
var
  w, h, i: Integer;
  lowerAlign: string;
  useAlignedAnchor: Boolean;
begin
  // 对应 SkinButton::setSkinElement：取各状态图的最大尺寸；
  // 无图时退回 position 尺寸；默认锚点时与 position 尺寸取并。
  w := 0; h := 0;
  for i := 0 to Elem.StateCount - 1 do
    if Elem.StatePixmaps[i] <> nil then
    begin
      if Elem.StatePixmaps[i].Width > w then w := Elem.StatePixmaps[i].Width;
      if Elem.StatePixmaps[i].Height > h then h := Elem.StatePixmaps[i].Height;
    end;

  lowerAlign := LowerCase(Elem.Align);
  useAlignedAnchor := (Pos('right', lowerAlign) > 0) or
    (Pos('center', lowerAlign) > 0) or (Pos('bottom', lowerAlign) > 0);

  Result := Elem.Position;
  if (w = 0) or (h = 0) then
  begin
    Result.W := Elem.Position.W;
    Result.H := Elem.Position.H;
  end
  else if (not useAlignedAnchor) and (not Elem.UseFrameSizeForBounds) then
  begin
    // QSize::expandedTo：各维取最大值
    if Elem.Position.W > w then Result.W := Elem.Position.W else Result.W := w;
    if Elem.Position.H > h then Result.H := Elem.Position.H else Result.H := h;
  end
  else
  begin
    Result.W := w;
    Result.H := h;
  end;
end;

procedure DrawButton(Dest: TBGRABitmap; const Elem: TSkinElement;
  const Bounds: TSkinRect; State: TButtonVisualState; Scale: Double);
var
  stateIdx, drawX, drawY, bx, by, bw, bh, pw, ph: Integer;
  pixmap: TBGRABitmap;
  lowerAlign: string;
begin
  stateIdx := Ord(State);
  if stateIdx >= Elem.StateCount then stateIdx := 0;
  pixmap := Elem.StatePixmaps[stateIdx];
  if pixmap = nil then Exit;

  if Scale <= 1.0001 then
  begin
    drawX := 0;
    drawY := 0;
    lowerAlign := LowerCase(Elem.Align);
    if Pos('center', lowerAlign) > 0 then
      drawX := (Bounds.W - pixmap.Width) div 2
    else if Pos('right', lowerAlign) > 0 then
      drawX := Bounds.W - pixmap.Width;
    if Pos('bottom', lowerAlign) > 0 then
      drawY := Bounds.H - pixmap.Height;
    QtPutImage(Dest, Bounds.X + drawX, Bounds.Y + drawY, pixmap);
    Exit;
  end;

  bx := ScalePx(Bounds.X, Scale);
  by := ScalePx(Bounds.Y, Scale);
  bw := ScalePx(Bounds.X + Bounds.W, Scale) - bx;
  bh := ScalePx(Bounds.Y + Bounds.H, Scale) - by;
  pw := ScalePx(pixmap.Width, Scale);
  ph := ScalePx(pixmap.Height, Scale);
  if pw < 1 then pw := 1;
  if ph < 1 then ph := 1;
  drawX := 0;
  drawY := 0;
  lowerAlign := LowerCase(Elem.Align);
  if Pos('center', lowerAlign) > 0 then
    drawX := (bw - pw) div 2
  else if Pos('right', lowerAlign) > 0 then
    drawX := bw - pw;
  if Pos('bottom', lowerAlign) > 0 then
    drawY := bh - ph;
  QtStretchPutImage(Dest, Classes.Rect(bx + drawX, by + drawY,
    bx + drawX + pw, by + drawY + ph), pixmap);
end;

procedure DrawSlider(Dest: TBGRABitmap; const Elem: TSkinElement;
  Value, MinV, MaxV: Double; ThumbState: TButtonVisualState);
var
  ratio: Double;
  x, y, xOff, yOff, fillW, fillH, stateIdx, thumbW, thumbH, posV: Integer;
  thumb: TBGRABitmap;
  part: TBGRABitmap;
begin
  // QWidget 子控件的绘制被裁剪到控件矩形内，这里等价地设置剪裁区。
  Dest.ClipRect := Classes.Rect(Elem.Position.X, Elem.Position.Y,
    Elem.Position.X + Elem.Position.W, Elem.Position.Y + Elem.Position.H);
  try
  // 值域夹取（对应 SkinSlider::setValue 的 qBound）
  if Value < MinV then Value := MinV;
  if Value > MaxV then Value := MaxV;

  // 背景条：以原始大小居中，比控件短则平铺
  if Elem.BarPixmap <> nil then
  begin
    if Elem.Vertical then
    begin
      xOff := (Elem.Position.W - Elem.BarPixmap.Width) div 2;
      y := 0;
      while y < Elem.Position.H do
      begin
        QtPutImage(Dest, Elem.Position.X + xOff, Elem.Position.Y + y,
          Elem.BarPixmap);
        Inc(y, Elem.BarPixmap.Height);
      end;
    end
    else
    begin
      yOff := (Elem.Position.H - Elem.BarPixmap.Height) div 2;
      x := 0;
      while x < Elem.Position.W do
      begin
        QtPutImage(Dest, Elem.Position.X + x, Elem.Position.Y + yOff,
          Elem.BarPixmap);
        Inc(x, Elem.BarPixmap.Width);
      end;
    end;
  end;

  if MaxV > MinV then
    ratio := (Value - MinV) / (MaxV - MinV)
  else
    ratio := 0;

  // 填充图
  if Elem.FillPixmap <> nil then
  begin
    if Elem.Vertical then
    begin
      fillH := Trunc(Elem.Position.H * ratio);
      // 夹取到 fill 图实际高度（防止 GetPart 收到负数 Y 导致行偏移）
      if fillH > Elem.FillPixmap.Height then fillH := Elem.FillPixmap.Height;
      xOff := (Elem.Position.W - Elem.FillPixmap.Width) div 2;
      if fillH > 0 then
      begin
        // 从底部绘制，裁剪 fill 图的底部 fillH 高度
        part := Elem.FillPixmap.GetPart(Classes.Rect(0,
          Elem.FillPixmap.Height - fillH, Elem.FillPixmap.Width,
          Elem.FillPixmap.Height));
        try
          QtPutImage(Dest, Elem.Position.X + xOff,
            Elem.Position.Y + Elem.Position.H - fillH, part);
        finally
          part.Free;
        end;
      end;
    end
    else
    begin
      fillW := Trunc(Elem.Position.W * ratio);
      yOff := (Elem.Position.H - Elem.FillPixmap.Height) div 2;
      if fillW > 0 then
      begin
        // 绘制左侧部分，保持原始高度（源图不足 fillW 时按源图宽绘制，
        // 与 QPainter::drawPixmap 对超界源矩形的裁剪行为一致）
        if fillW > Elem.FillPixmap.Width then fillW := Elem.FillPixmap.Width;
        part := Elem.FillPixmap.GetPart(Classes.Rect(0, 0, fillW,
          Elem.FillPixmap.Height));
        try
          QtPutImage(Dest, Elem.Position.X, Elem.Position.Y + yOff, part);
        finally
          part.Free;
        end;
      end;
    end;
  end;

  // 滑块拇指
  stateIdx := Ord(ThumbState);
  if (stateIdx > 0) and (Elem.ThumbPixmaps[stateIdx] = nil) then
    stateIdx := 0;
  thumb := Elem.ThumbPixmaps[stateIdx];
  if thumb <> nil then
  begin
    thumbW := thumb.Width;
    thumbH := thumb.Height;
    if Elem.Vertical then
    begin
      posV := Elem.Position.H - Trunc(ratio * Elem.Position.H) - thumbH div 2;
      if posV < 0 then posV := 0;
      if posV > Elem.Position.H - thumbH then posV := Elem.Position.H - thumbH;
      QtPutImage(Dest, Elem.Position.X + (Elem.Position.W - thumbW) div 2,
        Elem.Position.Y + posV, thumb);
    end
    else
    begin
      posV := Trunc(ratio * (Elem.Position.W - thumbW));
      if posV < 0 then posV := 0;
      if posV > Elem.Position.W - thumbW then posV := Elem.Position.W - thumbW;
      QtPutImage(Dest, Elem.Position.X + posV,
        Elem.Position.Y + (Elem.Position.H - thumbH) div 2, thumb);
    end;
  end;
  finally
    Dest.NoClip;
  end;
end;

procedure DrawLedTime(Dest: TBGRABitmap; const Elem: TSkinElement;
  TimeMs: Int64; Elapsed: Boolean);
var
  digits: TBGRABitmap;
  digitW, digitH, totalSecs, mins, secs, renderedWidth, x, y, i, idx: Integer;
  timeStr, lowerAlign: string;
  part: TBGRABitmap;
begin
  digits := Elem.StatePixmaps[0];
  if digits = nil then Exit;

  digitW := digits.Width div 12;
  digitH := digits.Height;
  if digitW <= 0 then Exit;

  totalSecs := Abs(TimeMs) div 1000;
  mins := totalSecs div 60;
  secs := totalSecs mod 60;

  if (not Elapsed) and (TimeMs > 0) then
    timeStr := Format('-%.2d:%.2d', [mins, secs])
  else
    timeStr := Format('%.2d:%.2d', [mins, secs]);

  renderedWidth := Length(timeStr) * digitW;

  x := Elem.Position.X;
  lowerAlign := LowerCase(Elem.Align);
  if Pos('right', lowerAlign) > 0 then
  begin
    if Elem.Position.W - renderedWidth > 0 then
      Inc(x, Elem.Position.W - renderedWidth);
  end
  else if Pos('center', lowerAlign) > 0 then
  begin
    if Elem.Position.W - renderedWidth > 0 then
      Inc(x, (Elem.Position.W - renderedWidth) div 2);
  end;

  y := Elem.Position.Y;
  if Elem.Position.H >= digitH then
    Inc(y, (Elem.Position.H - digitH) div 2);

  for i := 1 to Length(timeStr) do
  begin
    case timeStr[i] of
      '0'..'9': idx := Ord(timeStr[i]) - Ord('0');
      ':': idx := 10;
      '-': idx := 11;
    else
      Continue;
    end;
    part := digits.GetPart(Classes.Rect(idx * digitW, 0, (idx + 1) * digitW, digitH));
    try
      QtPutImage(Dest, x, y, part);
    finally
      part.Free;
    end;
    Inc(x, digitW);
  end;
end;

procedure DrawInfoText(Dest: TBGRABitmap; const Elem: TSkinElement;
  const Text: string);
var
  oldClip: TRect;
  px, x, y: Integer;
  sz: TSize;
  col, bg: TBGRAPixel;
  lowerAlign: string;
begin
  if (Dest = nil) or (Text = '') or Elem.Position.IsEmpty then
    Exit;

  oldClip := Dest.ClipRect;
  Dest.ClipRect := Classes.Rect(Elem.Position.X, Elem.Position.Y,
    Elem.Position.X + Elem.Position.W, Elem.Position.Y + Elem.Position.H);
  try
    if Elem.BkgndColor.Valid then
    begin
      bg := BGRA(Elem.BkgndColor.R, Elem.BkgndColor.G, Elem.BkgndColor.B, 255);
      Dest.FillRect(Elem.Position.X, Elem.Position.Y,
        Elem.Position.X + Elem.Position.W, Elem.Position.Y + Elem.Position.H,
        bg, dmSet);
    end;

    if Elem.Color.Valid then
      col := BGRA(Elem.Color.R, Elem.Color.G, Elem.Color.B, 255)
    else
      col := BGRA(255, 255, 6, 255);

    try
      if Elem.FontFamily <> '' then
        Dest.FontName := Elem.FontFamily
      else
        Dest.FontName := 'SimSun';
      px := Elem.FontSize;
      if px <= 0 then
        px := 12;
      Dest.FontHeight := px;
      Dest.FontAntialias := True;
      sz := Dest.TextSize(Text);
      x := Elem.Position.X;
      lowerAlign := LowerCase(Elem.Align);
      if Pos('right', lowerAlign) > 0 then
      begin
        if Elem.Position.W - sz.cx > 0 then
          Inc(x, Elem.Position.W - sz.cx);
      end
      else if Pos('center', lowerAlign) > 0 then
      begin
        if Elem.Position.W - sz.cx > 0 then
          Inc(x, (Elem.Position.W - sz.cx) div 2);
      end;
      y := Elem.Position.Y;
      if Elem.Position.H > sz.cy then
        Inc(y, (Elem.Position.H - sz.cy) div 2);
      Dest.TextOut(x, y, Text, col);
    except
      // tests.lpi is NoLCL (no LazFreeType). Stamp the info rect so
      // non-empty InfoText still differs in pixels from the default frame.
      Dest.FillRect(Elem.Position.X, Elem.Position.Y,
        Elem.Position.X + Elem.Position.W, Elem.Position.Y + Elem.Position.H,
        col, dmSet);
    end;
  finally
    Dest.ClipRect := oldClip;
  end;
end;

procedure DrawCoverArt(Dest: TBGRABitmap; const Elem: TSkinElement;
  Cover: TBGRABitmap);
var
  oldClip: TRect;
  dw, dh, x, y: Integer;
  sz: TSize;
  destR: TRect;
begin
  if (Dest = nil) or Elem.Position.IsEmpty then
    Exit;

  oldClip := Dest.ClipRect;
  Dest.ClipRect := Classes.Rect(Elem.Position.X, Elem.Position.Y,
    Elem.Position.X + Elem.Position.W, Elem.Position.Y + Elem.Position.H);
  try
    Dest.FillRect(Elem.Position.X, Elem.Position.Y,
      Elem.Position.X + Elem.Position.W, Elem.Position.Y + Elem.Position.H,
      BGRA(12, 12, 12, 255), dmSet);
    if (Cover <> nil) and (Cover.Width > 0) and (Cover.Height > 0) then
    begin
      if Cover.Width * Elem.Position.H <= Cover.Height * Elem.Position.W then
      begin
        dh := Elem.Position.H;
        dw := Cover.Width * dh div Cover.Height;
      end
      else
      begin
        dw := Elem.Position.W;
        dh := Cover.Height * dw div Cover.Width;
      end;
      if dw < 1 then dw := 1;
      if dh < 1 then dh := 1;
      x := Elem.Position.X + (Elem.Position.W - dw) div 2;
      y := Elem.Position.Y + (Elem.Position.H - dh) div 2;
      destR := Classes.Rect(x, y, x + dw, y + dh);
      QtStretchPutImage(Dest, destR, Cover);
    end
    else
    begin
      try
        Dest.FontName := 'SimSun';
        Dest.FontHeight := 12;
        Dest.FontAntialias := True;
        sz := Dest.TextSize('No Cover');
        Dest.TextOut(Elem.Position.X + (Elem.Position.W - sz.cx) div 2,
          Elem.Position.Y + (Elem.Position.H - sz.cy) div 2,
          'No Cover', BGRA(160, 200, 160, 255));
      except
        Dest.Rectangle(Elem.Position.X, Elem.Position.Y,
          Elem.Position.X + Elem.Position.W - 1,
          Elem.Position.Y + Elem.Position.H - 1,
          BGRA(160, 200, 160, 255), dmSet);
      end;
    end;
  finally
    Dest.ClipRect := oldClip;
  end;
end;

function RenderPlayerWindow(const Skin: TSkinData;
  ProgressValue, VolumeValue: Double;
  const OverrideType: string; OverrideState: TButtonVisualState;
  ToggledMute: Boolean;
  Playing: Boolean;
  LedTimeMs: Int64;
  const InfoText: string;
  CoverArt: TBGRABitmap;
  ShowCover: Boolean): TBGRABitmap;
var
  wnd: TSkinWindow;
  i, t: Integer;
  elem: PSkinElement;
  bounds: TSkinRect;
  state: TButtonVisualState;
  btnType: string;
begin
  wnd := Skin.PlayerWindow;
  if wnd.BackgroundPixmap = nil then
    Exit(TBGRABitmap.Create(1, 1, BGRAPixelTransparent));

  Result := TBGRABitmap.Create(wnd.BackgroundPixmap.Width,
    wnd.BackgroundPixmap.Height, BGRAPixelTransparent);
  // 背景（对应 PlayerWindow::paintEvent 的背景绘制，含预乘往返损失）
  QtPutImage(Result, 0, 0, wnd.BackgroundPixmap);

  // 按钮：按 createButtons 的类型清单绘制。
  // play / pause 互斥（对应 btnPause_->hide() 初始态与 onStateChanged）。
  for t := 0 to High(kPlayerButtonTypes) do
  begin
    btnType := kPlayerButtonTypes[t];
    if (btnType = 'pause') and (not Playing) then Continue;
    if (btnType = 'play') and Playing then Continue;
    elem := nil;
    for i := 0 to High(wnd.Elements) do
      if wnd.Elements[i].ElementType = btnType then
      begin
        elem := @wnd.Elements[i];
        Break;
      end;
    if elem = nil then Continue;

    state := bvsNormal;
    if SameText(OverrideType, btnType) then
      state := OverrideState
    else if (btnType = 'mute') and ToggledMute then
      state := bvsPressed;  // usePressedStateForToggle

    bounds := ButtonBounds(elem^);
    DrawButton(Result, elem^, bounds, state);
  end;

  // 滑块：progress（0-1）与 volume（0-100）
  for i := 0 to High(wnd.Elements) do
  begin
    if wnd.Elements[i].ElementType = 'progress' then
      DrawSlider(Result, wnd.Elements[i], ProgressValue, 0, 1.0, bvsNormal)
    else if wnd.Elements[i].ElementType = 'volume' then
      DrawSlider(Result, wnd.Elements[i], VolumeValue, 0, 100, bvsNormal);
  end;

  // 封面：仅 ShowCover 时画在 visual 矩形（默认关闭，Layer 2 金样不变）
  if ShowCover then
  begin
    elem := nil;
    for i := 0 to High(wnd.Elements) do
      if wnd.Elements[i].ElementType = 'visual' then
      begin
        elem := @wnd.Elements[i];
        Break;
      end;
    if (elem <> nil) and (not elem^.Position.IsEmpty) then
      DrawCoverArt(Result, elem^, CoverArt);
  end;

  // icon 元素：按 position 矩形缩放绘制（对应 paintEvent 的 drawPixmap(rect,...)）
  elem := nil;
  for i := 0 to High(wnd.Elements) do
    if wnd.Elements[i].ElementType = 'icon' then
    begin
      elem := @wnd.Elements[i];
      Break;
    end;
  if (elem <> nil) and (not elem^.Position.IsEmpty) and
     (elem^.StatePixmaps[0] <> nil) then
    QtStretchPutImage(Result, Classes.Rect(elem^.Position.X, elem^.Position.Y,
      elem^.Position.X + elem^.Position.W, elem^.Position.Y + elem^.Position.H),
      elem^.StatePixmaps[0]);

  // 曲目信息文本（InfoText 默认空 → 不绘制）
  if InfoText <> '' then
  begin
    elem := nil;
    for i := 0 to High(wnd.Elements) do
      if wnd.Elements[i].ElementType = 'info' then
      begin
        elem := @wnd.Elements[i];
        Break;
      end;
    if (elem <> nil) and (not elem^.Position.IsEmpty) then
      DrawInfoText(Result, elem^, InfoText);
  end;

  // LED 时间（对应 PlayerWindow::drawLedTime；默认 0 → 00:00）
  elem := nil;
  for i := 0 to High(wnd.Elements) do
    if wnd.Elements[i].ElementType = 'led' then
    begin
      elem := @wnd.Elements[i];
      Break;
    end;
  if (elem <> nil) and (not elem^.Position.IsEmpty) then
    DrawLedTime(Result, elem^, LedTimeMs, True);
end;

// 公开：滑块值→像素位置（对应 SkinSlider::valueToPosition + DrawSlider 的 thumb 定位）。
// Vertical=False：水平滑块，pos = Trunc(ratio * (TrackLen - ThumbSize))，夹取 [0, TrackLen-ThumbSize]。
// Vertical=True：垂直滑块，pos = TrackLen - Trunc(ratio * TrackLen) - ThumbSize div 2，夹取 [0, TrackLen-ThumbSize]。
// 与 DrawSlider 的内部实现保持一一对应，是 metamorphic 测试的被测函数。
function SliderValueToPos(Value, MinV, MaxV: Double;
  TrackLen, ThumbSize: Integer; Vertical: Boolean): Integer;
var
  ratio: Double;
begin
  if MaxV > MinV then
    ratio := (Value - MinV) / (MaxV - MinV)
  else
    ratio := 0;
  if ratio < 0 then ratio := 0;
  if ratio > 1 then ratio := 1;

  if Vertical then
  begin
    Result := TrackLen - Trunc(ratio * TrackLen) - ThumbSize div 2;
    if Result < 0 then Result := 0;
    if Result > TrackLen - ThumbSize then Result := TrackLen - ThumbSize;
  end
  else
  begin
    Result := Trunc(ratio * (TrackLen - ThumbSize));
    if Result < 0 then Result := 0;
    if Result > TrackLen - ThumbSize then Result := TrackLen - ThumbSize;
  end;
end;

// 公开：像素位置→滑块值（对应 SkinSlider::positionToValue）。
// Vertical=False：ratio = pos / TrackLen；Vertical=True：ratio = 1 - pos / TrackLen。
// 返回 [MinV, MaxV] 内夹取后的值。
function SliderPosToValue(Pos: Integer; MinV, MaxV: Double;
  TrackLen: Integer; Vertical: Boolean): Double;
var
  ratio: Double;
begin
  if TrackLen > 0 then
  begin
    if Vertical then
      ratio := 1.0 - Pos / TrackLen
    else
      ratio := Pos / TrackLen;
  end
  else
    ratio := 0;
  if ratio < 0 then ratio := 0;
  if ratio > 1 then ratio := 1;
  Result := MinV + ratio * (MaxV - MinV);
end;

// 均衡器按钮类型清单（对应 EqualizerWindow::applySkin 中处理的按钮元素）。
const
  kEqButtonTypes: array[0..3] of string = ('close', 'enabled', 'profile', 'reset');

function PixelLum(const P: TBGRAPixel): Integer; inline;
begin
  Result := (Integer(P.red) * 299 + Integer(P.green) * 587 +
    Integer(P.blue) * 114) div 1000;
end;

function PixelUsable(const P: TBGRAPixel): Boolean; inline;
begin
  // 色键后品红已是 alpha=0；这里仍排除残品红与全透明。
  Result := (P.alpha >= 16) and
    not ((P.red = 255) and (P.green = 0) and (P.blue = 255));
end;

function PixmapHasInscribedText(Bmp: TBGRABitmap): Boolean;
var
  w, h, x, y, i, idx, mode, paper, target, acc, lo, hi: Integer;
  n, lab, bestN, bestLab, plateN: Integer;
  px0, py0, px1, py1, cx0, cy0, cx1, cy1, bw, bh, hole, sp, nx, ny, nidx: Integer;
  p: PBGRAPixel;
  lumv: Integer;
  bin8: array[0..7] of Integer;
  lumHist: array[0..255] of Integer;
  plateMask, inkMask, visited: array of Boolean;
  labels, stack: array of Integer;
  area: Int64;

  procedure PushIdx(AIdx: Integer);
  begin
    stack[sp] := AIdx;
    Inc(sp);
  end;

  function PopIdx: Integer;
  begin
    Dec(sp);
    Result := stack[sp];
  end;
begin
  Result := False;
  if Bmp = nil then Exit;
  w := Bmp.Width;
  h := Bmp.Height;
  if (w < 5) or (h < 5) then Exit;

  FillChar(bin8, SizeOf(bin8), 0);
  FillChar(lumHist, SizeOf(lumHist), 0);
  for y := 2 to h - 3 do
  begin
    p := Bmp.ScanLine[y];
    Inc(p, 2);
    for x := 2 to w - 3 do
    begin
      if PixelUsable(p^) then
      begin
        lumv := PixelLum(p^);
        Inc(lumHist[lumv]);
        Inc(bin8[lumv shr 5]);
      end;
      Inc(p);
    end;
  end;

  mode := 0;
  for i := 1 to 7 do
    if bin8[i] > bin8[mode] then
      mode := i;
  if bin8[mode] = 0 then Exit;

  // 众数 32-亮度箱内的中位亮度 = 面板「纸色」。
  target := bin8[mode] div 2;
  lo := mode * 32;
  hi := lo + 31;
  if hi > 255 then hi := 255;
  acc := 0;
  paper := lo;
  for i := lo to hi do
  begin
    Inc(acc, lumHist[i]);
    if acc > target then
    begin
      paper := i;
      Break;
    end;
  end;

  SetLength(plateMask, w * h);
  FillChar(plateMask[0], Length(plateMask), 0);
  plateN := 0;
  for y := 2 to h - 3 do
  begin
    p := Bmp.ScanLine[y];
    Inc(p, 2);
    for x := 2 to w - 3 do
    begin
      if PixelUsable(p^) then
      begin
        lumv := PixelLum(p^);
        if Abs(lumv - paper) <= 28 then
        begin
          plateMask[y * w + x] := True;
          Inc(plateN);
        end;
      end;
      Inc(p);
    end;
  end;
  if plateN = 0 then Exit;

  SetLength(labels, w * h);
  SetLength(stack, w * h);
  FillChar(labels[0], Length(labels) * SizeOf(Integer), 0);
  lab := 0;
  bestN := 0;
  bestLab := 0;
  for y := 2 to h - 3 do
    for x := 2 to w - 3 do
    begin
      idx := y * w + x;
      if (not plateMask[idx]) or (labels[idx] <> 0) then Continue;
      Inc(lab);
      sp := 0;
      PushIdx(idx);
      labels[idx] := lab;
      n := 0;
      while sp > 0 do
      begin
        idx := PopIdx;
        Inc(n);
        nx := idx mod w;
        ny := idx div w;
        if (nx + 1 < w) then
        begin
          nidx := idx + 1;
          if plateMask[nidx] and (labels[nidx] = 0) then
          begin
            labels[nidx] := lab;
            PushIdx(nidx);
          end;
        end;
        if (nx > 0) then
        begin
          nidx := idx - 1;
          if plateMask[nidx] and (labels[nidx] = 0) then
          begin
            labels[nidx] := lab;
            PushIdx(nidx);
          end;
        end;
        if (ny + 1 < h) then
        begin
          nidx := idx + w;
          if plateMask[nidx] and (labels[nidx] = 0) then
          begin
            labels[nidx] := lab;
            PushIdx(nidx);
          end;
        end;
        if (ny > 0) then
        begin
          nidx := idx - w;
          if plateMask[nidx] and (labels[nidx] = 0) then
          begin
            labels[nidx] := lab;
            PushIdx(nidx);
          end;
        end;
      end;
      if n > bestN then
      begin
        bestN := n;
        bestLab := lab;
      end;
    end;
  if bestLab = 0 then Exit;

  px0 := w; py0 := h; px1 := -1; py1 := -1;
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do
      if labels[y * w + x] = bestLab then
      begin
        if x < px0 then px0 := x;
        if y < py0 then py0 := y;
        if x > px1 then px1 := x;
        if y > py1 then py1 := y;
      end;

  SetLength(inkMask, w * h);
  FillChar(inkMask[0], Length(inkMask), 0);
  n := 0;
  for y := py0 to py1 do
  begin
    p := Bmp.ScanLine[y];
    Inc(p, px0);
    for x := px0 to px1 do
    begin
      if PixelUsable(p^) then
      begin
        lumv := PixelLum(p^);
        if Abs(lumv - paper) >= 50 then
        begin
          inkMask[y * w + x] := True;
          Inc(n);
        end;
      end;
      Inc(p);
    end;
  end;
  if n < 10 then Exit;

  FillChar(labels[0], Length(labels) * SizeOf(Integer), 0);
  SetLength(visited, w * h);
  lab := 0;
  for y := py0 to py1 do
    for x := px0 to px1 do
    begin
      idx := y * w + x;
      if (not inkMask[idx]) or (labels[idx] <> 0) then Continue;
      Inc(lab);
      sp := 0;
      PushIdx(idx);
      labels[idx] := lab;
      n := 0;
      while sp > 0 do
      begin
        idx := PopIdx;
        Inc(n);
        nx := idx mod w;
        ny := idx div w;
        if (nx + 1 < w) then
        begin
          nidx := idx + 1;
          if inkMask[nidx] and (labels[nidx] = 0) then
          begin
            labels[nidx] := lab;
            PushIdx(nidx);
          end;
        end;
        if (nx > 0) then
        begin
          nidx := idx - 1;
          if inkMask[nidx] and (labels[nidx] = 0) then
          begin
            labels[nidx] := lab;
            PushIdx(nidx);
          end;
        end;
        if (ny + 1 < h) then
        begin
          nidx := idx + w;
          if inkMask[nidx] and (labels[nidx] = 0) then
          begin
            labels[nidx] := lab;
            PushIdx(nidx);
          end;
        end;
        if (ny > 0) then
        begin
          nidx := idx - w;
          if inkMask[nidx] and (labels[nidx] = 0) then
          begin
            labels[nidx] := lab;
            PushIdx(nidx);
          end;
        end;
      end;
      if n < 10 then Continue;

      cx0 := w; cy0 := h; cx1 := -1; cy1 := -1;
      for ny := py0 to py1 do
        for nx := px0 to px1 do
          if labels[ny * w + nx] = lab then
          begin
            if nx < cx0 then cx0 := nx;
            if ny < cy0 then cy0 := ny;
            if nx > cx1 then cx1 := nx;
            if ny > cy1 then cy1 := ny;
          end;
      bw := cx1 - cx0 + 1;
      bh := cy1 - cy0 + 1;
      if (bw < 4) or (bh < 5) then Continue;
      area := Int64(bw) * bh;
      if (Int64(n) * 4 < area) or (Int64(n) * 4 > 3 * area) then Continue;

      // 从包围盒边沿淹没非墨水；剩下的非墨水即封闭孔（字母 counter）。
      FillChar(visited[0], Length(visited), 0);
      sp := 0;
      for nx := cx0 to cx1 do
      begin
        nidx := cy0 * w + nx;
        if ((not inkMask[nidx]) or (labels[nidx] <> lab)) and not visited[nidx] then
        begin
          visited[nidx] := True;
          PushIdx(nidx);
        end;
        nidx := cy1 * w + nx;
        if ((not inkMask[nidx]) or (labels[nidx] <> lab)) and not visited[nidx] then
        begin
          visited[nidx] := True;
          PushIdx(nidx);
        end;
      end;
      for ny := cy0 to cy1 do
      begin
        nidx := ny * w + cx0;
        if ((not inkMask[nidx]) or (labels[nidx] <> lab)) and not visited[nidx] then
        begin
          visited[nidx] := True;
          PushIdx(nidx);
        end;
        nidx := ny * w + cx1;
        if ((not inkMask[nidx]) or (labels[nidx] <> lab)) and not visited[nidx] then
        begin
          visited[nidx] := True;
          PushIdx(nidx);
        end;
      end;
      while sp > 0 do
      begin
        idx := PopIdx;
        nx := idx mod w;
        ny := idx div w;
        if nx + 1 <= cx1 then
        begin
          nidx := idx + 1;
          if not visited[nidx] and
             ((not inkMask[nidx]) or (labels[nidx] <> lab)) then
          begin
            visited[nidx] := True;
            PushIdx(nidx);
          end;
        end;
        if nx - 1 >= cx0 then
        begin
          nidx := idx - 1;
          if not visited[nidx] and
             ((not inkMask[nidx]) or (labels[nidx] <> lab)) then
          begin
            visited[nidx] := True;
            PushIdx(nidx);
          end;
        end;
        if ny + 1 <= cy1 then
        begin
          nidx := idx + w;
          if not visited[nidx] and
             ((not inkMask[nidx]) or (labels[nidx] <> lab)) then
          begin
            visited[nidx] := True;
            PushIdx(nidx);
          end;
        end;
        if ny - 1 >= cy0 then
        begin
          nidx := idx - w;
          if not visited[nidx] and
             ((not inkMask[nidx]) or (labels[nidx] <> lab)) then
          begin
            visited[nidx] := True;
            PushIdx(nidx);
          end;
        end;
      end;

      hole := 0;
      for ny := cy0 to cy1 do
        for nx := cx0 to cx1 do
        begin
          nidx := ny * w + nx;
          if visited[nidx] then Continue;
          if inkMask[nidx] and (labels[nidx] = lab) then Continue;
          Inc(hole);
        end;

      if (hole >= 1) and (Int64(hole) * 5 <= Int64(n) * 2) then
        Exit(True);
    end;
end;

function ButtonHasInscribedText(const Elem: TSkinElement): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to 2 do
    if (i < Elem.StateCount) and (Elem.StatePixmaps[i] <> nil) and
       PixmapHasInscribedText(Elem.StatePixmaps[i]) then
      Exit(True);
end;

function EqFactorRect(const Elem: TSkinElement; Band, EqInterval: Integer): TSkinRect;
begin
  Result := Elem.Position;
  Result.X := Elem.Position.X + Band * (Elem.Position.W + EqInterval);
end;

function RenderEqualizerWindow(const Skin: TSkinData;
  const EqGains: array of Double; PreampGain: Double;
  BalanceValue, SurroundValue: Double;
  EqEnabled: Boolean;
  const OverrideType: string; OverrideState: TButtonVisualState): TBGRABitmap;
var
  wnd: TSkinWindow;
  i, band: Integer;
  elem: PSkinElement;
  bounds: TSkinRect;
  state: TButtonVisualState;
  sliderElem: TSkinElement;
  bandRect: TSkinRect;
  gain: Double;
begin
  wnd := Skin.EqualizerWindow;
  if wnd.BackgroundPixmap = nil then
    Exit(TBGRABitmap.Create(1, 1, BGRAPixelTransparent));

  Result := TBGRABitmap.Create(wnd.BackgroundPixmap.Width,
    wnd.BackgroundPixmap.Height, BGRAPixelTransparent);

  // 背景
  QtPutImage(Result, 0, 0, wnd.BackgroundPixmap);

  // title：直接按 position 绘制，不做 hover/press 状态变换
  elem := wnd.FindElement('title');
  if (elem <> nil) and (elem^.StatePixmaps[0] <> nil) then
    QtPutImage(Result, elem^.Position.X, elem^.Position.Y, elem^.StatePixmaps[0]);

  // 按钮：close / enabled / profile / reset
  for i := 0 to High(kEqButtonTypes) do
  begin
    elem := wnd.FindElement(kEqButtonTypes[i]);
    if elem = nil then Continue;

    state := bvsNormal;
    if SameText(OverrideType, kEqButtonTypes[i]) then
    begin
      // 刻字开关的悬停帧是凸起「关」，盖住按下态会看起来像被关掉。
      // 无文字的图标/LED 悬停仍是正常反馈。
      if SameText(kEqButtonTypes[i], 'enabled') and EqEnabled and
         (OverrideState = bvsHover) and ButtonHasInscribedText(elem^) then
        state := bvsPressed
      else
        state := OverrideState;
    end
    else if SameText(kEqButtonTypes[i], 'enabled') and EqEnabled then
      state := bvsPressed;  // usePressedStateForToggle

    bounds := ButtonBounds(elem^);
    DrawButton(Result, elem^, bounds, state);
  end;

  // preamp 滑块（Qt applySkin 显式调用 setVertical(true)，不依赖 XML 的 vertical 字段）。
  // EqEnabled=False 时 Qt 调用 setEnabled(false) → 滑块用 bvsDisabled(state 3) 绘制 thumb。
  elem := wnd.FindElement('preamp');
  if elem <> nil then
  begin
    sliderElem := elem^;
    sliderElem.Vertical := True;
    if EqEnabled then
      DrawSlider(Result, sliderElem, PreampGain, -12, 12, bvsNormal)
    else
      DrawSlider(Result, sliderElem, PreampGain, -12, 12, bvsDisabled);
  end;

  // balance 滑块（水平，-100..+100；禁用态不受 EqEnabled 影响）
  elem := wnd.FindElement('balance');
  if elem <> nil then
    DrawSlider(Result, elem^, BalanceValue, -100, 100, bvsNormal);

  // surround 滑块（水平，0..100）
  elem := wnd.FindElement('surround');
  if elem <> nil then
    DrawSlider(Result, elem^, SurroundValue, 0, 100, bvsNormal);

  // eqfactor：单个元素模板 → 10 个垂直滑块；EqEnabled=False 时 thumb 用 bvsDisabled。
  elem := wnd.FindElement('eqfactor');
  if elem <> nil then
  begin
    sliderElem := elem^;
    for band := 0 to 9 do
    begin
      bandRect := EqFactorRect(elem^, band, wnd.EqInterval);
      sliderElem.Position := bandRect;
      sliderElem.Vertical := True;

      if band < Length(EqGains) then
        gain := EqGains[band]
      else
        gain := 0;

      if EqEnabled then
        DrawSlider(Result, sliderElem, gain, -12, 12, bvsNormal)
      else
        DrawSlider(Result, sliderElem, gain, -12, 12, bvsDisabled);
    end;
  end;
end;

{ ── 九宫格辅助：把 Src 的指定矩形平铺或缩放到 Dest 的 DestRect ─────── }

// 平铺一个切片到 DestRect（对应 drawHTiled / drawVTiled / drawTiled）。
procedure TileSlice(Dest: TBGRABitmap; const DestRect: TRect;
  Src: TBGRABitmap);
var
  x, y, dx, dy, tw, th: Integer;
  part: TBGRABitmap;
begin
  if Src = nil then Exit;
  tw := Src.Width;
  th := Src.Height;
  if (tw = 0) or (th = 0) then Exit;
  if (DestRect.Right <= DestRect.Left) or
     (DestRect.Bottom <= DestRect.Top) then Exit;

  y := DestRect.Top;
  while y < DestRect.Bottom do
  begin
    dy := DestRect.Bottom - y;
    if dy > th then dy := th;
    x := DestRect.Left;
    while x < DestRect.Right do
    begin
      dx := DestRect.Right - x;
      if dx > tw then dx := tw;
      // 裁剪右/底边不足一格的部分
      if (dx < tw) or (dy < th) then
      begin
        part := Src.GetPart(Classes.Rect(0, 0, dx, dy));
        try
          QtPutImage(Dest, x, y, part);
        finally
          part.Free;
        end;
      end
      else
        QtPutImage(Dest, x, y, Src);
      Inc(x, tw);
    end;
    Inc(y, th);
  end;
end;

function AlignedRect(const BaseRect: TSkinRect;
  BaseW, BaseH, CurW, CurH: Integer; const Align: string;
  ContentW: Integer; ContentH: Integer): TSkinRect;
var
  lowerAlign: string;
  rightMargin, bottomMargin: Integer;
begin
  Result := BaseRect;
  if ContentW > 0 then Result.W := ContentW;
  if ContentH > 0 then Result.H := ContentH;
  lowerAlign := LowerCase(Align);
  if Pos('center', lowerAlign) > 0 then
    Result.X := (CurW - Result.W) div 2
  else if Pos('right', lowerAlign) > 0 then
  begin
    rightMargin := BaseW - (BaseRect.X + BaseRect.W);
    Result.X := CurW - rightMargin - Result.W;
  end;
  if Pos('bottom', lowerAlign) > 0 then
  begin
    bottomMargin := BaseH - (BaseRect.Y + BaseRect.H);
    Result.Y := CurH - bottomMargin - Result.H;
  end;
end;

function PlaylistContentRect(const Skin: TSkinData;
  DestW, DestH: Integer): TSkinRect;
var
  wnd: TSkinWindow;
  pl: PSkinElement;
  bgW, bgH, rightMargin, bottomMargin: Integer;
begin
  wnd := Skin.PlaylistWindow;
  pl := wnd.FindElement('playlist');
  if wnd.BackgroundPixmap <> nil then
  begin
    bgW := wnd.BackgroundPixmap.Width;
    bgH := wnd.BackgroundPixmap.Height;
  end
  else
  begin
    bgW := DestW;
    bgH := DestH;
  end;
  if (pl = nil) or pl^.Position.IsEmpty then
  begin
    Result.X := 4;
    Result.Y := 50;
    Result.W := DestW - 8;
    Result.H := DestH - 74;
  end
  else
  begin
    rightMargin  := bgW - (pl^.Position.X + pl^.Position.W);
    bottomMargin := bgH - (pl^.Position.Y + pl^.Position.H);
    Result.X := pl^.Position.X;
    Result.Y := pl^.Position.Y;
    Result.W := DestW - Result.X - rightMargin;
    Result.H := DestH - Result.Y - bottomMargin;
  end;
  if Result.W < 1 then Result.W := 1;
  if Result.H < 1 then Result.H := 1;
end;

// 绘制九宫格背景到 Result（大小已创建为 DestW × DestH）。
// Tile=True: 各边/中心平铺；Tile=False: 双线性缩放（对应 Qt SmoothTransformation）。
procedure DrawNinePatch(Dest: TBGRABitmap;
  Base: TBGRABitmap; const RR: TSkinRect; Tile: Boolean;
  DestW, DestH: Integer; ExclusiveMids: Boolean);
var
  bgW, bgH: Integer;
  left, top, right, bottom, cw, ch: Integer;
  cx, cy, cdw, cdh: Integer;
  slice, resampled: TBGRABitmap;
  dstRect: TRect;

  procedure PutScaled(DestX, DestY: Integer; Src: TBGRABitmap; OutW, OutH: Integer);
  begin
    if (OutW = Src.Width) and (OutH = Src.Height) then
      QtPutImage(Dest, DestX, DestY, Src)
    else
    begin
      resampled := Src.Resample(OutW, OutH, rmFineResample) as TBGRABitmap;
      try QtPutImage(Dest, DestX, DestY, resampled); finally resampled.Free; end;
    end;
  end;

begin
  if Base = nil then Exit;
  bgW := Base.Width;
  bgH := Base.Height;

  if RR.IsEmpty then
  begin
    // resizeRect 空：直接把背景按 DestW×DestH 缩放
    if (DestW = bgW) and (DestH = bgH) then
      QtPutImage(Dest, 0, 0, Base)
    else
      QtStretchPutImage(Dest, Classes.Rect(0, 0, DestW, DestH), Base);
    Exit;
  end;

  left   := RR.X;
  top    := RR.Y;
  cw     := RR.W;
  ch     := RR.H;
  right  := bgW - (left + cw);
  bottom := bgH - (top + ch);
  cx     := left;
  cy     := top;
  cdw    := DestW - left - right;
  cdh    := DestH - top - bottom;

  // ── 四角（原样贴，不拉伸）────────────────────────────────────────
  // topLeft
  slice := Base.GetPart(Classes.Rect(0, 0, left, top));
  try QtPutImage(Dest, 0, 0, slice); finally slice.Free; end;
  // topRight
  slice := Base.GetPart(Classes.Rect(bgW - right, 0, bgW, top));
  try QtPutImage(Dest, DestW - right, 0, slice); finally slice.Free; end;
  // bottomLeft
  slice := Base.GetPart(Classes.Rect(0, bgH - bottom, left, bgH));
  try QtPutImage(Dest, 0, DestH - bottom, slice); finally slice.Free; end;
  // bottomRight
  slice := Base.GetPart(Classes.Rect(bgW - right, bgH - bottom, bgW, bgH));
  try QtPutImage(Dest, DestW - right, DestH - bottom, slice); finally slice.Free; end;

  // ── 四边 + 中心 ───────────────────────────────────────────────────
  // ExclusiveMids=True：与 Qt PlaylistWindow::rebuildBackground 一致，
  // topMid/bottomMid 宽 = DestW-left-right，不伸进四角。
  // ExclusiveMids=False：topMid/bottomMid 铺到 DestW，之后角片覆盖，
  // 透明角由中段瓦片透出（Lyric 路径）。
  if top > 0 then
  begin
    slice := Base.GetPart(Classes.Rect(cx, 0, cx + cw, top));
    try
      if ExclusiveMids then
        dstRect := Classes.Rect(cx, 0, DestW - right, top)
      else
        dstRect := Classes.Rect(cx, 0, DestW, top);
      if Tile then TileSlice(Dest, dstRect, slice)
      else PutScaled(cx, 0, slice, dstRect.Right - dstRect.Left, top);
    finally slice.Free; end;
  end;
  if bottom > 0 then
  begin
    slice := Base.GetPart(Classes.Rect(cx, bgH - bottom, cx + cw, bgH));
    try
      if ExclusiveMids then
        dstRect := Classes.Rect(cx, DestH - bottom, DestW - right, DestH)
      else
        dstRect := Classes.Rect(cx, DestH - bottom, DestW, DestH);
      if Tile then TileSlice(Dest, dstRect, slice)
      else PutScaled(cx, DestH - bottom, slice, dstRect.Right - dstRect.Left, bottom);
    finally slice.Free; end;
  end;

  // midLeft / midRight / center: top 到 DestH-bottom
  if left > 0 then
  begin
    slice := Base.GetPart(Classes.Rect(0, cy, left, cy + ch));
    try
      dstRect := Classes.Rect(0, cy, left, DestH - bottom);
      if Tile then TileSlice(Dest, dstRect, slice)
      else PutScaled(0, cy, slice, left, cdh);
    finally slice.Free; end;
  end;
  if right > 0 then
  begin
    slice := Base.GetPart(Classes.Rect(bgW - right, cy, bgW, cy + ch));
    try
      dstRect := Classes.Rect(DestW - right, cy, DestW, DestH - bottom);
      if Tile then TileSlice(Dest, dstRect, slice)
      else PutScaled(DestW - right, cy, slice, right, cdh);
    finally slice.Free; end;
  end;

  // center: left..DestW-right, top..DestH-bottom
  if (cdw > 0) and (cdh > 0) then
  begin
    slice := Base.GetPart(Classes.Rect(cx, cy, cx + cw, cy + ch));
    try
      if Tile then
      begin
        dstRect := Classes.Rect(cx, cy, DestW - right, DestH - bottom);
        TileSlice(Dest, dstRect, slice);
      end
      else
        PutScaled(cx, cy, slice, cdw, cdh);
    finally slice.Free; end;
  end;

  // ── 角片最后覆盖（透明角由边缘切片透出）──
  // ExclusiveMids 路径角片已在最前绘制且中段不侵入，无需再盖一次。
  if not ExclusiveMids then
  begin
    if left > 0 then
    begin
      if top > 0 then
      begin
        slice := Base.GetPart(Classes.Rect(0, 0, left, top));
        try QtPutImage(Dest, 0, 0, slice); finally slice.Free; end;
      end;
      if bottom > 0 then
      begin
        slice := Base.GetPart(Classes.Rect(0, bgH - bottom, left, bgH));
        try QtPutImage(Dest, 0, DestH - bottom, slice); finally slice.Free; end;
      end;
    end;
    if right > 0 then
    begin
      if top > 0 then
      begin
        slice := Base.GetPart(Classes.Rect(bgW - right, 0, bgW, top));
        try QtPutImage(Dest, DestW - right, 0, slice); finally slice.Free; end;
      end;
      if bottom > 0 then
      begin
        slice := Base.GetPart(Classes.Rect(bgW - right, bgH - bottom, bgW, bgH));
        try QtPutImage(Dest, DestW - right, DestH - bottom, slice); finally slice.Free; end;
      end;
    end;
  end;
end;

function RenderLyricWindow(const Skin: TSkinData;
  DestW, DestH: Integer): TBGRABitmap;
var
  wnd: TSkinWindow;
  bgW, bgH: Integer;
  elem: PSkinElement;
  bounds, drawRect: TSkinRect;
  titleW, titleH: Integer;
begin
  wnd := Skin.LyricWindow;
  Result := TBGRABitmap.Create(DestW, DestH, BGRAPixelTransparent);

  if wnd.BackgroundPixmap = nil then Exit;

  bgW := wnd.BackgroundPixmap.Width;
  bgH := wnd.BackgroundPixmap.Height;

  // 九宫格铺满 DestW×DestH（与 LyricWindow::rebuildBackground 一致）。
  // Layer 2 传入 baseSize，无拉伸；运行时 ULyricForm 传入当前逻辑尺寸。
  // ExclusiveMids=True：与 LyricWindow::rebuildBackground 的
  // QRect(left, 0, width()-left-right, top) 一致。
  DrawNinePatch(Result, wnd.BackgroundPixmap, wnd.ResizeRect, wnd.ResizeTile,
    DestW, DestH, True);

  // title：paintEvent 按 titleDrawRect（alignedRect + pixmap 尺寸）贴图。
  elem := wnd.FindElement('title');
  if (elem <> nil) and (elem^.StatePixmaps[0] <> nil) then
  begin
    titleW := elem^.StatePixmaps[0].Width;
    titleH := elem^.StatePixmaps[0].Height;
    drawRect := AlignedRect(elem^.Position, bgW, bgH, DestW, DestH,
      elem^.Align, titleW, titleH);
    QtPutImage(Result, drawRect.X, drawRect.Y, elem^.StatePixmaps[0]);
  end;

  // close / ontop：子控件 SkinButton，位置 = alignedRect(..., button.size())。
  elem := wnd.FindElement('close');
  if elem <> nil then
  begin
    bounds := ButtonBounds(elem^);
    drawRect := AlignedRect(elem^.Position, bgW, bgH, DestW, DestH,
      elem^.Align, bounds.W, bounds.H);
    DrawButton(Result, elem^, drawRect, bvsNormal);
  end;

  elem := wnd.FindElement('ontop');
  if elem <> nil then
  begin
    bounds := ButtonBounds(elem^);
    drawRect := AlignedRect(elem^.Position, bgW, bgH, DestW, DestH,
      elem^.Align, bounds.W, bounds.H);
    DrawButton(Result, elem^, drawRect, bvsNormal);
  end;
end;

// kToolbarGroupCount 与 Qt PlaylistWindow::kToolbarGroupCount 一致。
const
  kPlaylistToolbarGroupCount = 7;

function RenderPlaylistWindow(const Skin: TSkinData;
  DestW, DestH: Integer): TBGRABitmap;
var
  wnd: TSkinWindow;
  bgW, bgH: Integer;
  // title
  titleElem: PSkinElement;
  titleRect: TSkinRect;
  titleW, titleH: Integer;
  // 工具栏
  tbElem: PSkinElement;
  tbRect: TSkinRect;
  tbX, tbY, tbW, tbH: Integer;
  group, gLeft, gRight, gW, gH: Integer;
  srcLeft, srcRight, srcW, srcH: Integer;
  drawX, drawY: Integer;
  sheet, clip_: TBGRABitmap;
  srcRect: TRect;
  // close 按钮
  closeElem: PSkinElement;
  closeX, closeBtnW: Integer;
  rightMargin: Integer;
  closeBounds: TSkinRect;
begin
  wnd := Skin.PlaylistWindow;
  Result := TBGRABitmap.Create(DestW, DestH, BGRAPixelTransparent);

  if wnd.BackgroundPixmap = nil then Exit;

  bgW := wnd.BackgroundPixmap.Width;
  bgH := wnd.BackgroundPixmap.Height;

  // ── 九宫格背景（DestW × DestH，与 Qt FrameDumper 的 640×480 窗口一致）─
  DrawNinePatch(Result, wnd.BackgroundPixmap, wnd.ResizeRect, wnd.ResizeTile,
    DestW, DestH, True);

  // ── title（Qt paintEvent：drawPixmap(titleDrawRect().topLeft(), pixmap)）─
  titleElem := wnd.FindElement('title');
  if (titleElem <> nil) and (titleElem^.StatePixmaps[0] <> nil) then
  begin
    titleW := titleElem^.StatePixmaps[0].Width;
    titleH := titleElem^.StatePixmaps[0].Height;
    titleRect := AlignedRect(titleElem^.Position, bgW, bgH, DestW, DestH,
      titleElem^.Align, titleW, titleH);
    QtPutImage(Result, titleRect.X, titleRect.Y, titleElem^.StatePixmaps[0]);
  end;

  // ── 工具栏（7 组，普通态精灵图，不绘制悬停/按下状态）──────────────────
  // toolbarAreaRect() = alignedRect(toolbar.position, ..., position.size())
  // 每组矩形：左 = tbX + tbW*g/7, 右 = tbX + tbW*(g+1)/7
  // 精灵图各组：srcLeft = sheet.w*g/7, srcRight = sheet.w*(g+1)/7
  // 绘制方式：裁剪到 groupRect，图像在 groupRect 中居中
  tbElem := wnd.FindElement('toolbar');
  if (tbElem <> nil) and (tbElem^.StatePixmaps[0] <> nil) then
  begin
    sheet := tbElem^.StatePixmaps[0];
    tbRect := AlignedRect(tbElem^.Position, bgW, bgH, DestW, DestH,
      tbElem^.Align, tbElem^.Position.W, tbElem^.Position.H);
    tbX := tbRect.X;
    tbY := tbRect.Y;
    tbW := tbRect.W;
    tbH := tbRect.H;

    for group := 0 to kPlaylistToolbarGroupCount - 1 do
    begin
      // groupRect：整数除法，与 Qt (left + w * g) / 7 保持一致
      gLeft  := tbX + (tbW * group)       div kPlaylistToolbarGroupCount;
      gRight := tbX + (tbW * (group + 1)) div kPlaylistToolbarGroupCount;
      gW := gRight - gLeft;
      gH := tbH;
      if gW <= 0 then Continue;

      // 源精灵图切片
      srcLeft  := (sheet.Width * group)       div kPlaylistToolbarGroupCount;
      srcRight := (sheet.Width * (group + 1)) div kPlaylistToolbarGroupCount;
      srcW := srcRight - srcLeft;
      if srcW <= 0 then srcW := 1;
      srcH := sheet.Height;

      // 在 groupRect 内居中（Qt toolbarGroupDrawRect 的居中逻辑）
      drawX := gLeft + (gW - srcW) div 2;
      drawY := tbY  + (gH - srcH) div 2;

      // 剪裁到 groupRect，再绘制精灵子图
      srcRect := Classes.Rect(srcLeft, 0, srcLeft + srcW, srcH);
      clip_ := sheet.GetPart(srcRect);
      try
        Result.ClipRect := Classes.Rect(gLeft, tbY, gRight, tbY + tbH);
        QtPutImage(Result, drawX, drawY, clip_);
        Result.NoClip;
      finally
        clip_.Free;
      end;
    end;
  end;

  // ── close 按钮（普通态；align='right' → rightMargin 修正 X）────────────
  // 与 Qt PlaylistWindow::updateChromeGeometry 中 closeButton_->move() 等价：
  //   rightMargin = bgW - (close.x + close.w)
  //   closeX      = DestW - rightMargin - btnW
  closeElem := wnd.FindElement('close');
  if closeElem <> nil then
  begin
    closeBounds := ButtonBounds(closeElem^);
    closeBtnW   := closeBounds.W;
    if Pos('right', LowerCase(closeElem^.Align)) > 0 then
    begin
      rightMargin := bgW - (closeElem^.Position.X + closeElem^.Position.W);
      closeX      := DestW - rightMargin - closeBtnW;
    end
    else
      closeX := closeElem^.Position.X;
    closeBounds.X := closeX;
    DrawButton(Result, closeElem^, closeBounds, bvsNormal);
  end;
end;

end.
