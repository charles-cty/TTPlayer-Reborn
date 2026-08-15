unit UPlaylistForm;

{$mode objfpc}{$H+}

// 播放列表窗口，对应 Qt 版 src/ui/PlaylistWindow。
// 无边框自绘，九宫格背景，右/下边缘可调整大小。
// 工具栏 7 组按钮；close 按钮（align='right' 计算 X）；列表区背景色填充；
// 垂直分割条视觉渲染（Phase 2 不实现拖动功能）。
// WMNCHitTest 返回 HTCAPTION 实现拖动；边缘拖动在 MouseDown/Move/Up 中处理。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, LCLIntf, LCLType, LMessages,
  Math,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UPlayerBackend;

type
  TPlaylistForm = class(TForm)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;

    // 应用皮肤；换肤时调用。
    procedure ApplySkin(const ASkin: TSkinData);

    // 列表条目接口（Phase 3 实现，目前仅占位）。
    procedure AddEntry(const FilePath, Title, Artist: string; DurationMs: Int64);
    procedure Clear;
    procedure SetCurrentIndex(Index: Integer);

  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseLeave; override;

    procedure WMNCHitTest(var Msg: TLMessage); message LM_NCHITTEST;

  private
    FSkin: ^TSkinData;
    FBackend: IPlayerBackend;
    FFrame: TBGRABitmap;

    // 当前窗口逻辑尺寸
    FLogicW, FLogicH: Integer;

    // 交互状态
    FHoveredType: string;  // 'close' 或 ''
    FPressedType: string;

    // 边缘拖动调整大小
    FResizing: Boolean;
    FResizeEdgeRight: Boolean;
    FResizeEdgeBottom: Boolean;
    FResizeStartX: Integer;
    FResizeStartY: Integer;
    FResizeStartW: Integer;
    FResizeStartH: Integer;

    procedure BuildRegion;
    procedure RenderFrame;

    // 命中测试：返回 'close' 或 ''
    function HitButton(PX, PY: Integer): string;
    // 8 px 边缘感应
    function HitResizeEdge(PX, PY: Integer;
      out EdgeRight, EdgeBottom: Boolean): Boolean;
    // align='right' 按钮的实际 X（与 Qt alignedRect 等价）
    function AlignedButtonX(const Elem: TSkinElement): Integer;

    procedure FireButtonClick(const AName: string);
  end;

implementation

const
  kResizeSense         = 8;
  kPlaylistMinW        = 200;
  kPlaylistMinH        = 80;
  kToolbarGroupCount   = 7;
  kDividerWidth        = 5;
  kDividerHandleHalfH  = 7;
  // 默认分割条位置（对应 Qt 默认 dividerPos_=55）
  kDefaultDividerPos   = 55;

{ TPlaylistForm }

constructor TPlaylistForm.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  inherited CreateNew(AOwner);

  FSkin    := nil;
  FBackend := ABackend;
  FFrame   := nil;

  FLogicW := 268;
  FLogicH := 165;

  FHoveredType := '';
  FPressedType := '';
  FResizing    := False;

  BorderStyle := bsNone;
  FormStyle   := fsNormal;
  Color       := clBlack;

  MouseLeave;
end;

destructor TPlaylistForm.Destroy;
begin
  FreeAndNil(FFrame);
  inherited Destroy;
end;

procedure TPlaylistForm.ApplySkin(const ASkin: TSkinData);
var
  bg: TBGRABitmap;
  dp: TSkinRect;
begin
  FSkin := @ASkin;

  bg := ASkin.PlaylistWindow.BackgroundPixmap;
  dp := ASkin.PlaylistWindow.DefaultPosition;
  if bg <> nil then
  begin
    // 初始尺寸优先用 DefaultPosition（与 Qt 版 applySkin 后的窗口大小一致）。
    // DefaultPosition 只有宽高有意义（左上角坐标由窗口管理器决定）。
    // 若 DefaultPosition 无效（w/h=0）则退回背景图尺寸作为最小基准。
    if (dp.W > 0) and (dp.H > 0) then
    begin
      FLogicW := dp.W;
      FLogicH := dp.H;
    end
    else
    begin
      FLogicW := bg.Width;
      FLogicH := bg.Height;
    end;
    SetBounds(Left, Top, FLogicW, FLogicH);
  end;

  // 播放列表窗口背景图角落透明像素极少（Classic 仅左上角 23px，占 0.1%），
  // 不值得用逐像素 HRGN 扫描裁剪——会在关闭时产生大量 GDI 对象销毁导致挂起。
  // 直接使用矩形窗口，视觉效果与原版 Qt 几乎完全一致。
  FreeAndNil(FFrame);
  RenderFrame;
  Invalidate;
end;

// 从已渲染的 FFrame 生成异形 HRGN（对应 PlaylistWindow::updateChromeGeometry → setMask）。
// 扫描 FFrame 而非原始背景图，确保 HRGN 覆盖九宫格拉伸后的完整窗口区域。
// （若扫描背景图，bg.h < FLogicH 时窗口下半部分会被系统裁掉）
procedure TPlaylistForm.BuildRegion;
var
  bmp: TBGRABitmap;
  totalRgn, rowRgn, segRgn: HRGN;
  bx, by, startX, bw, bh: Integer;
  p: PBGRAPixel;
begin
  if FFrame = nil then Exit;
  bmp := FFrame;

  bw := bmp.Width;
  bh := bmp.Height;
  totalRgn := CreateRectRgn(0, 0, 0, 0);

  for by := 0 to bh - 1 do
  begin
    p := bmp.ScanLine[by];
    startX := -1;
    for bx := 0 to bw - 1 do
    begin
      if p^.alpha > 0 then
      begin
        if startX < 0 then startX := bx;
      end
      else if startX >= 0 then
      begin
        segRgn := CreateRectRgn(startX, by, bx, by + 1);
        rowRgn := CreateRectRgn(0, 0, 0, 0);
        CombineRgn(rowRgn, totalRgn, segRgn, RGN_OR);
        DeleteObject(totalRgn); DeleteObject(segRgn);
        totalRgn := rowRgn;
        startX := -1;
      end;
      Inc(p);
    end;
    if startX >= 0 then
    begin
      segRgn := CreateRectRgn(startX, by, bw, by + 1);
      rowRgn := CreateRectRgn(0, 0, 0, 0);
      CombineRgn(rowRgn, totalRgn, segRgn, RGN_OR);
      DeleteObject(totalRgn); DeleteObject(segRgn);
      totalRgn := rowRgn;
    end;
  end;

  SetWindowRgn(Handle, totalRgn, True);
end;

// align='right' ボタンの实际 X（baseSize 为背景图宽）
function TPlaylistForm.AlignedButtonX(const Elem: TSkinElement): Integer;
var
  baseW, rightMargin, btnW: Integer;
  lAlign: string;
begin
  lAlign := LowerCase(Elem.Align);
  if Pos('right', lAlign) = 0 then
  begin
    Result := Elem.Position.X;
    Exit;
  end;
  if FSkin = nil then begin Result := Elem.Position.X; Exit; end;
  baseW      := FSkin^.PlaylistWindow.BackgroundPixmap.Width;
  rightMargin := baseW - (Elem.Position.X + Elem.Position.W);
  btnW       := ButtonBounds(Elem).W;
  Result     := FLogicW - rightMargin - btnW;
end;

procedure TPlaylistForm.RenderFrame;
var
  wnd: TSkinWindow;
  bgW, bgH: Integer;
  elem: PSkinElement;
  bounds: TSkinRect;
  btnX: Integer;
  // toolbar
  tbX, tbY, tbW, tbH: Integer;
  group, gLeft, gRight, gW, gH: Integer;
  srcLeft, srcRight, srcW, srcH: Integer;
  drawX, drawY: Integer;
  sheet, clip_: TBGRABitmap;
  srcRect: TRect;
  // divider
  divX, divY, divH: Integer;
  overType: string;
  overState: TButtonVisualState;
  // playlist fill
  rightMargin, bottomMargin, plX, plY, plW, plH: Integer;
  fillColor: TBGRAPixel;
begin
  if FSkin = nil then Exit;

  wnd := FSkin^.PlaylistWindow;
  bgW := wnd.BackgroundPixmap.Width;
  bgH := wnd.BackgroundPixmap.Height;

  FFrame := TBGRABitmap.Create(FLogicW, FLogicH, BGRAPixelTransparent);

  // ── 九宫格背景 ───────────────────────────────────────────────────────
  if wnd.BackgroundPixmap <> nil then
    DrawNinePatch(FFrame, wnd.BackgroundPixmap, wnd.ResizeRect, wnd.ResizeTile,
      FLogicW, FLogicH);

  // ── 列表区背景色填充 ─────────────────────────────────────────────────
  elem := wnd.FindElement('playlist');
  if elem <> nil then
  begin
    rightMargin  := bgW - (elem^.Position.X + elem^.Position.W);
    bottomMargin := bgH - (elem^.Position.Y + elem^.Position.H);
    plX := elem^.Position.X;
    plY := elem^.Position.Y;
    plW := FLogicW - plX - rightMargin;
    plH := FLogicH - plY - bottomMargin;
    if (plW > 0) and (plH > 0) and FSkin^.PlaylistConfig.ColorBkgnd.Valid then
    begin
      fillColor := FSkin^.PlaylistConfig.ColorBkgnd.ToBGRA;
      FFrame.FillRect(plX, plY, plX + plW, plY + plH, fillColor, dmSet);
    end;
  end;

  // ── 工具栏（7 组，普通态，无悬停）──────────────────────────────────
  // 复用 RenderPlaylistWindow 中的相同逻辑，通过 TBGRABitmap.PutImage 绘制。
  // 每组：裁剪矩形内，精灵子图居中（Qt toolbarGroupDrawRect 居中逻辑）。
  elem := wnd.FindElement('toolbar');
  if (elem <> nil) and (elem^.StatePixmaps[0] <> nil) then
  begin
    sheet := elem^.StatePixmaps[0];
    tbX := elem^.Position.X;
    tbY := elem^.Position.Y;
    tbW := elem^.Position.W;
    tbH := elem^.Position.H;
    for group := 0 to kToolbarGroupCount - 1 do
    begin
      gLeft  := tbX + (tbW * group)       div kToolbarGroupCount;
      gRight := tbX + (tbW * (group + 1)) div kToolbarGroupCount;
      gW := gRight - gLeft;
      gH := tbH;
      if gW <= 0 then Continue;

      srcLeft  := (sheet.Width * group)       div kToolbarGroupCount;
      srcRight := (sheet.Width * (group + 1)) div kToolbarGroupCount;
      srcW := srcRight - srcLeft;
      if srcW <= 0 then srcW := 1;
      srcH := sheet.Height;

      drawX := gLeft + (gW - srcW) div 2;
      drawY := tbY  + (gH - srcH) div 2;

      srcRect := Classes.Rect(srcLeft, 0, srcLeft + srcW, srcH);
      clip_ := sheet.GetPart(srcRect);
      try
        FFrame.ClipRect := Classes.Rect(gLeft, tbY, gRight, tbY + tbH);
        // PutImage: BGRABitmap 内置 source-over（非 Qt 精确合成，toolbar 为不透明位图，效果等同）
        FFrame.PutImage(drawX, drawY, clip_, dmDrawWithTransparency);
        FFrame.NoClip;
      finally
        clip_.Free;
      end;
    end;
  end;

  // ── title 图像（align='center' → 水平居中于窗口）────────────────────
  // 对应 Qt PlaylistWindow::paintEvent 的 titleDrawRect() 绘制。
  // align='center' 时 X = (FLogicW - img.w) / 2；Y 取 position.y。
  elem := wnd.FindElement('title');
  if (elem <> nil) and (elem^.StatePixmaps[0] <> nil) then
  begin
    bounds := ButtonBounds(elem^);
    if Pos('center', LowerCase(elem^.Align)) > 0 then
      btnX := (FLogicW - bounds.W) div 2
    else if Pos('right', LowerCase(elem^.Align)) > 0 then
      btnX := AlignedButtonX(elem^)
    else
      btnX := elem^.Position.X;
    bounds.X := btnX;
    DrawButton(FFrame, elem^, bounds, bvsNormal);
  end;

  // ── close 按钮 ──────────────────────────────────────────────────────
  overType  := '';
  overState := bvsNormal;
  if FPressedType <> '' then begin overType := FPressedType; overState := bvsPressed; end
  else if FHoveredType <> '' then begin overType := FHoveredType; overState := bvsHover; end;

  elem := wnd.FindElement('close');
  if elem <> nil then
  begin
    bounds := ButtonBounds(elem^);
    btnX   := AlignedButtonX(elem^);
    bounds.X := btnX;
    if SameText(overType, 'close') then
      DrawButton(FFrame, elem^, bounds, overState)
    else
      DrawButton(FFrame, elem^, bounds, bvsNormal);
  end;

  // ── 分割条视觉渲染（Phase 2：仅绘制竖线，不绘制箭头；拖动 Phase 3 实现）─
  // 分割条在 playlistRect 内，位于 playlistRect.x + kDefaultDividerPos 处。
  // 若列表区有效才绘制（playlistRect 宽度 > kDefaultDividerPos + kDividerWidth）。
  if elem <> nil then  // 复用 close elem 仅为语法顺序；用专用 elem
    ;  // no-op
  begin
    // 重新查找 playlist 元素以计算 playlistRect
    elem := wnd.FindElement('playlist');
    if elem <> nil then
    begin
      rightMargin  := bgW - (elem^.Position.X + elem^.Position.W);
      bottomMargin := bgH - (elem^.Position.Y + elem^.Position.H);
      plX := elem^.Position.X;
      plY := elem^.Position.Y;
      plW := FLogicW - plX - rightMargin;
      plH := FLogicH - plY - bottomMargin;
      divX := plX + kDefaultDividerPos;
      divY := plY;
      divH := plH;
      if (plW > kDefaultDividerPos + kDividerWidth) and (divH > 0) then
      begin
        // 分割条：用 FillRect 绘制竖条（Qt drawSplitterBar 的近似）
        // 暗色底色条
        FFrame.FillRect(divX, divY, divX + kDividerWidth, divY + divH,
          BGRA(80, 80, 80, 255), dmSet);
        // 中间高亮竖线
        FFrame.FillRect(divX + 2, divY, divX + 3, divY + divH,
          BGRA(200, 200, 200, 180), dmDrawWithTransparency);
      end;
    end;
  end;
end;

procedure TPlaylistForm.Paint;
begin
  if FFrame = nil then Exit;
  FFrame.Draw(Canvas, 0, 0, True);
end;

function TPlaylistForm.HitButton(PX, PY: Integer): string;
var
  wnd: TSkinWindow;
  elem: PSkinElement;
  bounds: TSkinRect;
  btnX: Integer;
begin
  Result := '';
  if FSkin = nil then Exit;
  wnd := FSkin^.PlaylistWindow;

  elem := wnd.FindElement('close');
  if elem = nil then Exit;
  bounds := ButtonBounds(elem^);
  btnX   := AlignedButtonX(elem^);
  if (PX >= btnX) and (PX < btnX + bounds.W) and
     (PY >= elem^.Position.Y) and (PY < elem^.Position.Y + bounds.H) then
    Result := 'close';
end;

function TPlaylistForm.HitResizeEdge(PX, PY: Integer;
  out EdgeRight, EdgeBottom: Boolean): Boolean;
begin
  EdgeRight  := (PX >= FLogicW - kResizeSense) and (PX < FLogicW);
  EdgeBottom := (PY >= FLogicH - kResizeSense) and (PY < FLogicH);
  Result := EdgeRight or EdgeBottom;
end;

procedure TPlaylistForm.FireButtonClick(const AName: string);
begin
  if SameText(AName, 'close') then
    Hide;
  RenderFrame;
  Invalidate;
end;

procedure TPlaylistForm.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  er, eb: Boolean;
  hitName: string;
begin
  if Button = mbLeft then
  begin
    hitName := HitButton(X, Y);
    if hitName <> '' then
    begin
      FPressedType := hitName;
      RenderFrame; Invalidate;
    end
    else if HitResizeEdge(X, Y, er, eb) then
    begin
      FResizing         := True;
      FResizeEdgeRight  := er;
      FResizeEdgeBottom := eb;
      FResizeStartX     := Mouse.CursorPos.X;
      FResizeStartY     := Mouse.CursorPos.Y;
      FResizeStartW     := FLogicW;
      FResizeStartH     := FLogicH;
      SetCapture(Handle);
    end;
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TPlaylistForm.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  newName: string;
  er, eb: Boolean;
  newW, newH, dx, dy: Integer;
begin
  if FResizing then
  begin
    dx := Mouse.CursorPos.X - FResizeStartX;
    dy := Mouse.CursorPos.Y - FResizeStartY;
    newW := FResizeStartW;
    newH := FResizeStartH;
    if FResizeEdgeRight  then newW := Max(kPlaylistMinW, FResizeStartW + dx);
    if FResizeEdgeBottom then newH := Max(kPlaylistMinH, FResizeStartH + dy);
    if (newW <> FLogicW) or (newH <> FLogicH) then
    begin
      FLogicW := newW;
      FLogicH := newH;
      SetBounds(Left, Top, newW, newH);
      FreeAndNil(FFrame);
      RenderFrame;
      if HandleAllocated then BuildRegion;
      Invalidate;
    end;
  end
  else
  begin
    newName := HitButton(X, Y);
    if newName <> FHoveredType then
    begin
      FHoveredType := newName;
      RenderFrame; Invalidate;
    end;
    if HitResizeEdge(X, Y, er, eb) then
    begin
      if er and eb then Cursor := crSizeNWSE
      else if er    then Cursor := crSizeWE
      else               Cursor := crSizeNS;
    end
    else
      Cursor := crDefault;
  end;
  inherited MouseMove(Shift, X, Y);
end;

procedure TPlaylistForm.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  clickedType, hitName: string;
begin
  if Button = mbLeft then
  begin
    if FResizing then
    begin
      ReleaseCapture;
      FResizing := False;
    end
    else
    begin
      clickedType := FPressedType;
      FPressedType := '';
      if clickedType <> '' then
      begin
        hitName := HitButton(X, Y);
        if SameText(hitName, clickedType) then
          FireButtonClick(clickedType)
        else begin RenderFrame; Invalidate; end;
      end;
    end;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TPlaylistForm.MouseLeave;
begin
  if (FHoveredType <> '') or (FPressedType <> '') then
  begin
    FHoveredType := '';
    FPressedType := '';
    RenderFrame; Invalidate;
  end;
  Cursor := crDefault;
  inherited MouseLeave;
end;

// 背景 → HTCAPTION（系统拖动）；按钮/边缘 → HTCLIENT
procedure TPlaylistForm.WMNCHitTest(var Msg: TLMessage);
var
  pt: TPoint;
  er, eb: Boolean;
begin
  pt := ScreenToClient(Point(
    SmallInt(Msg.LParam and $FFFF),
    SmallInt((Msg.LParam shr 16) and $FFFF)));

  if HitButton(pt.X, pt.Y) <> '' then
    Msg.Result := HTCLIENT
  else if HitResizeEdge(pt.X, pt.Y, er, eb) then
    Msg.Result := HTCLIENT
  else
    Msg.Result := HTCAPTION;
end;

// ── Phase 3 列表接口（占位）──────────────────────────────────────────────

procedure TPlaylistForm.AddEntry(const FilePath, Title, Artist: string;
  DurationMs: Int64);
begin
  // Phase 3: 添加条目到 TPlaylistModel，重绘列表区
end;

procedure TPlaylistForm.Clear;
begin
  // Phase 3: 清空 TPlaylistModel，重绘列表区
end;

procedure TPlaylistForm.SetCurrentIndex(Index: Integer);
begin
  // Phase 3: 设置当前播放索引，高亮对应行
end;

end.
