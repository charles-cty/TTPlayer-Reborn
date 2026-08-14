unit USkinRender;

{$mode objfpc}{$H+}

// 皮肤渲染原语，对应 Qt 版 SkinButton/SkinSlider 的 paintEvent 与
// PlayerWindow 的窗口合成逻辑。所有绘制离屏进行（TBGRABitmap 上合成），
// 与 Layer 2 快照测试共用同一条渲染路径。

interface

uses
  Classes, SysUtils, BGRABitmap, BGRABitmapTypes, USkinTypes;

type
  // 按钮视觉状态（与 Qt 版 currentState 的取值一致）。
  TButtonVisualState = (bvsNormal, bvsHover, bvsPressed, bvsDisabled);

// 计算按钮控件的实际尺寸（对应 SkinButton::setSkinElement 的尺寸推导）。
function ButtonBounds(const Elem: TSkinElement): TSkinRect;

// 在 Dest 上绘制按钮（对应 SkinButton::paintEvent；X/Y 为控件左上角）。
procedure DrawButton(Dest: TBGRABitmap; const Elem: TSkinElement;
  const Bounds: TSkinRect; State: TButtonVisualState);

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
function RenderPlayerWindow(const Skin: TSkinData;
  ProgressValue, VolumeValue: Double;
  const OverrideType: string; OverrideState: TButtonVisualState;
  ToggledMute: Boolean): TBGRABitmap;

// 计算第 Band 个 eqfactor 滑块的实际 Position（X 按 eqInterval 偏移）。
// 公开供 UEqualizerForm 命中测试使用，与 RenderEqualizerWindow 保持一致。
function EqFactorRect(const Elem: TSkinElement; Band, EqInterval: Integer): TSkinRect;

// 合成整个 equalizer_window（对应 EqualizerWindow 的渲染结果）。
// EqGains: 10 波段增益 dB [-12..+12]；PreampGain 前置增益 dB；
// BalanceValue [-100..+100]；SurroundValue [0..100]；
// EqEnabled: 均衡器开关（对应 btnEnabled_ 的 toggled 状态）。
// OverrideType/OverrideState: 强制单个按钮视觉状态（测试用），'' 表示不启用。
function RenderEqualizerWindow(const Skin: TSkinData;
  const EqGains: array of Double; PreampGain: Double;
  BalanceValue, SurroundValue: Double;
  EqEnabled: Boolean;
  const OverrideType: string; OverrideState: TButtonVisualState): TBGRABitmap;

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

// 等价于 QPainter::drawPixmap(destRect, pixmap)（无平滑变换）：
// 最近邻缩放。Qt fast transform 以目标像素中心反算源坐标：
// src = floor((d + 0.5) * sw / dw)。
procedure QtStretchPutImage(Dest: TBGRABitmap; const DestRect: TRect;
  Src: TBGRABitmap);
var
  tmp: TBGRABitmap;
  dw, dh, x, y, sx, sy: Integer;
  p: PBGRAPixel;
begin
  if Src = nil then Exit;
  dw := DestRect.Right - DestRect.Left;
  dh := DestRect.Bottom - DestRect.Top;
  if (dw <= 0) or (dh <= 0) then Exit;

  if (dw = Src.Width) and (dh = Src.Height) then
  begin
    QtPutImage(Dest, DestRect.Left, DestRect.Top, Src);
    Exit;
  end;

  tmp := TBGRABitmap.Create(dw, dh);
  try
    for y := 0 to dh - 1 do
    begin
      // Qt fast transform 定点映射：src = floor((d+0.5)*sw/dw - 0.5)
      sy := ((2 * y + 1) * Src.Height - dh) div (2 * dh);
      if sy < 0 then sy := 0;
      if sy > Src.Height - 1 then sy := Src.Height - 1;
      p := tmp.ScanLine[y];
      for x := 0 to dw - 1 do
      begin
        sx := ((2 * x + 1) * Src.Width - dw) div (2 * dw);
        if sx < 0 then sx := 0;
        if sx > Src.Width - 1 then sx := Src.Width - 1;
        p^ := Src.GetPixel(sx, sy);
        Inc(p);
      end;
    end;
    tmp.InvalidateBitmap;
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
  const Bounds: TSkinRect; State: TButtonVisualState);
var
  stateIdx, drawX, drawY: Integer;
  pixmap: TBGRABitmap;
  lowerAlign: string;
begin
  stateIdx := Ord(State);
  if stateIdx >= Elem.StateCount then stateIdx := 0;
  pixmap := Elem.StatePixmaps[stateIdx];
  if pixmap = nil then Exit;

  drawX := 0;
  drawY := 0;
  lowerAlign := LowerCase(Elem.Align);
  if Pos('center', lowerAlign) > 0 then
    drawX := (Bounds.W - pixmap.Width) div 2
  else if Pos('right', lowerAlign) > 0 then
    drawX := Bounds.W - pixmap.Width;
  if Pos('bottom', lowerAlign) > 0 then
    drawY := Bounds.H - pixmap.Height;

  // 默认以 XML 左上角为锚点；仅在显式 align 时才偏移。
  QtPutImage(Dest, Bounds.X + drawX, Bounds.Y + drawY, pixmap);
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

function RenderPlayerWindow(const Skin: TSkinData;
  ProgressValue, VolumeValue: Double;
  const OverrideType: string; OverrideState: TButtonVisualState;
  ToggledMute: Boolean): TBGRABitmap;
var
  wnd: TSkinWindow;
  i, t: Integer;
  elem: PSkinElement;
  bounds: TSkinRect;
  state: TButtonVisualState;
begin
  wnd := Skin.PlayerWindow;
  if wnd.BackgroundPixmap = nil then
    Exit(TBGRABitmap.Create(1, 1, BGRAPixelTransparent));

  Result := TBGRABitmap.Create(wnd.BackgroundPixmap.Width,
    wnd.BackgroundPixmap.Height, BGRAPixelTransparent);
  // 背景（对应 PlayerWindow::paintEvent 的背景绘制，含预乘往返损失）
  QtPutImage(Result, 0, 0, wnd.BackgroundPixmap);

  // 按钮：按 createButtons 的类型清单绘制（pause 初始隐藏，跳过）
  for t := 0 to High(kPlayerButtonTypes) do
  begin
    if kPlayerButtonTypes[t] = 'pause' then Continue;
    elem := nil;
    for i := 0 to High(wnd.Elements) do
      if wnd.Elements[i].ElementType = kPlayerButtonTypes[t] then
      begin
        elem := @wnd.Elements[i];
        Break;
      end;
    if elem = nil then Continue;

    state := bvsNormal;
    if SameText(OverrideType, kPlayerButtonTypes[t]) then
      state := OverrideState
    else if (kPlayerButtonTypes[t] = 'mute') and ToggledMute then
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

  // LED 时间：初始为 00:00 已过时间（对应 currentPosMs_=0, showElapsed_=true）
  elem := nil;
  for i := 0 to High(wnd.Elements) do
    if wnd.Elements[i].ElementType = 'led' then
    begin
      elem := @wnd.Elements[i];
      Break;
    end;
  if (elem <> nil) and (not elem^.Position.IsEmpty) then
    DrawLedTime(Result, elem^, 0, True);
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
      state := OverrideState
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

end.
