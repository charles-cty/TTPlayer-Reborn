unit UPlaylistForm;

{$mode objfpc}{$H+}

// 播放列表窗口，对应 Qt 版 src/ui/PlaylistWindow。
// 无边框自绘，九宫格背景（ExclusiveMids），右/下边缘可调整大小。
// 工具栏 7 组按钮（HTCLIENT 命中，悬停/按下偏移）；close（align=right）；
// 垂直分割条（Qt drawSplitterBar/Arrow + 拖动/点击折叠）。
// WMNCHitTest：chrome → HTCAPTION，按钮/工具栏/分割条/列表区/边缘 → HTCLIENT。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, LCLIntf, LCLType, LMessages,
  Math, Types,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UPlayerBackend;

type
  TPlaylistForm = class(TForm)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;

    procedure ApplySkin(const ASkin: TSkinData);

    // 列表条目接口（Phase 3 接入 TPlaylistModel）。
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
    procedure DblClick; override;

    procedure WMNCHitTest(var Msg: TLMessage); message LM_NCHITTEST;

  private
    FSkin: ^TSkinData;
    FBackend: IPlayerBackend;
    FFrame: TBGRABitmap;

    FLogicW, FLogicH: Integer;

    FHoveredType: string;       // 'close' 或 ''
    FPressedType: string;
    FHoveredToolbar: Integer;   // -1 = 无
    FPressedToolbar: Integer;

    FResizing: Boolean;
    FResizeEdgeRight: Boolean;
    FResizeEdgeBottom: Boolean;
    FResizeStartX: Integer;
    FResizeStartY: Integer;
    FResizeStartW: Integer;
    FResizeStartH: Integer;

    FDividerPos: Integer;
    FDividerSavedPos: Integer;
    FDividerDragging: Boolean;
    FDividerHandlePressed: Boolean;
    FDividerDragStartX: Integer;

    procedure BuildRegion;
    procedure RenderFrame;
    procedure InvalidateFrame;

    function HitButton(PX, PY: Integer): string;
    function HitResizeEdge(PX, PY: Integer;
      out EdgeRight, EdgeBottom: Boolean): Boolean;
    function AlignedButtonX(const Elem: TSkinElement): Integer;

    function BgSize: TPoint;
    function ContentRect: TSkinRect;
    function ToolbarAreaRect: TSkinRect;
    function ToolbarGroupRect(Group: Integer): TSkinRect;
    function ToolbarGroupIndexAt(PX, PY: Integer): Integer;
    function DividerVisualRect: TSkinRect;
    function DividerHotZoneRect: TSkinRect;
    function DividerHandleRect: TSkinRect;
    function IsDividerCollapsed: Boolean;
    function PtInSkinRect(PX, PY: Integer; const R: TSkinRect): Boolean;
    procedure ToggleDividerCollapsed;
    procedure ClampDividerPos;

    procedure DrawSplitterBar(const R: TSkinRect; Front, Back: TBGRAPixel);
    procedure DrawSplitterArrow(const R: TSkinRect; ArrowColor: TBGRAPixel;
      Collapsed: Boolean);
    procedure DrawToolbarGroups;

    procedure FireButtonClick(const AName: string);
    procedure FireToolbarClick(Group: Integer);
  end;

implementation

const
  kResizeSense              = 8;
  kPlaylistMinW             = 200;
  kPlaylistMinH             = 80;
  kToolbarGroupCount        = 7;
  kDividerWidth             = 5;
  kDividerHandleHalfH       = 7;
  kDividerMinExpandedPos    = 20;
  kDividerCollapseThreshold = 6;
  kDefaultDividerPos        = 55;
  kDividerHotPad            = 6;

{ TPlaylistForm }

constructor TPlaylistForm.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  inherited CreateNew(AOwner);

  FSkin    := nil;
  FBackend := ABackend;
  FFrame   := nil;

  FLogicW := 268;
  FLogicH := 165;

  FHoveredType     := '';
  FPressedType     := '';
  FHoveredToolbar  := -1;
  FPressedToolbar  := -1;
  FResizing        := False;

  FDividerPos           := kDefaultDividerPos;
  FDividerSavedPos      := kDefaultDividerPos;
  FDividerDragging      := False;
  FDividerHandlePressed := False;

  BorderStyle := bsNone;
  FormStyle   := fsNormal;
  Color       := clBlack;
  Caption     := 'Playlist';

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

  ClampDividerPos;

  // 播放列表窗口背景图角落透明像素极少，逐像素 HRGN 会在关闭时挂起。
  // 直接使用矩形窗口，视觉效果与原版 Qt 几乎完全一致。
  InvalidateFrame;
end;

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

procedure TPlaylistForm.InvalidateFrame;
begin
  FreeAndNil(FFrame);
  RenderFrame;
  Invalidate;
end;

function TPlaylistForm.BgSize: TPoint;
begin
  Result := Point(FLogicW, FLogicH);
  if (FSkin <> nil) and (FSkin^.PlaylistWindow.BackgroundPixmap <> nil) then
  begin
    Result.X := FSkin^.PlaylistWindow.BackgroundPixmap.Width;
    Result.Y := FSkin^.PlaylistWindow.BackgroundPixmap.Height;
  end;
end;

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
  baseW := BgSize.X;
  rightMargin := baseW - (Elem.Position.X + Elem.Position.W);
  btnW := ButtonBounds(Elem).W;
  Result := FLogicW - rightMargin - btnW;
end;

function TPlaylistForm.ContentRect: TSkinRect;
begin
  if FSkin = nil then
  begin
    Result.X := 4; Result.Y := 50;
    Result.W := Max(1, FLogicW - 8);
    Result.H := Max(1, FLogicH - 74);
  end
  else
    Result := PlaylistContentRect(FSkin^, FLogicW, FLogicH);
end;

function TPlaylistForm.ToolbarAreaRect: TSkinRect;
var
  elem: PSkinElement;
  sz: TPoint;
begin
  Result := TSkinRect.Zero;
  if FSkin = nil then Exit;
  elem := FSkin^.PlaylistWindow.FindElement('toolbar');
  if elem = nil then Exit;
  sz := BgSize;
  Result := AlignedRect(elem^.Position, sz.X, sz.Y, FLogicW, FLogicH,
    elem^.Align, elem^.Position.W, elem^.Position.H);
end;

function TPlaylistForm.ToolbarGroupRect(Group: Integer): TSkinRect;
var
  tb: TSkinRect;
  gLeft, gRight: Integer;
begin
  Result := TSkinRect.Zero;
  if (Group < 0) or (Group >= kToolbarGroupCount) then Exit;
  tb := ToolbarAreaRect;
  if tb.IsEmpty then Exit;
  gLeft  := tb.X + (tb.W * Group)       div kToolbarGroupCount;
  gRight := tb.X + (tb.W * (Group + 1)) div kToolbarGroupCount;
  Result.X := gLeft;
  Result.Y := tb.Y;
  Result.W := Max(1, gRight - gLeft);
  Result.H := tb.H;
end;

function TPlaylistForm.ToolbarGroupIndexAt(PX, PY: Integer): Integer;
var
  tb: TSkinRect;
  relX: Integer;
begin
  Result := -1;
  tb := ToolbarAreaRect;
  if tb.IsEmpty or not PtInSkinRect(PX, PY, tb) then Exit;
  relX := PX - tb.X;
  Result := (relX * kToolbarGroupCount) div Max(1, tb.W);
  if (Result < 0) or (Result >= kToolbarGroupCount) then
    Result := -1;
end;

function TPlaylistForm.PtInSkinRect(PX, PY: Integer; const R: TSkinRect): Boolean;
begin
  Result := (not R.IsEmpty) and
            (PX >= R.X) and (PX < R.X + R.W) and
            (PY >= R.Y) and (PY < R.Y + R.H);
end;

function TPlaylistForm.IsDividerCollapsed: Boolean;
begin
  Result := FDividerPos <= 0;
end;

function TPlaylistForm.DividerVisualRect: TSkinRect;
var
  pl: TSkinRect;
begin
  Result := TSkinRect.Zero;
  pl := ContentRect;
  if pl.IsEmpty then Exit;
  Result.X := pl.X;
  if not IsDividerCollapsed then
    Inc(Result.X, FDividerPos);
  Result.Y := pl.Y;
  Result.W := kDividerWidth;
  Result.H := pl.H;
end;

function TPlaylistForm.DividerHotZoneRect: TSkinRect;
begin
  Result := DividerVisualRect;
  if Result.IsEmpty then Exit;
  Result.X := Result.X - kDividerHotPad;
  Result.W := Result.W + 2 * kDividerHotPad;
end;

function TPlaylistForm.DividerHandleRect: TSkinRect;
var
  vis: TSkinRect;
  cy: Integer;
begin
  Result := TSkinRect.Zero;
  vis := DividerVisualRect;
  if vis.IsEmpty then Exit;
  cy := vis.Y + vis.H div 2;
  Result.X := vis.X;
  Result.Y := cy - kDividerHandleHalfH;
  Result.W := vis.W;
  Result.H := 2 * kDividerHandleHalfH + 1;
end;

procedure TPlaylistForm.ClampDividerPos;
var
  pl: TSkinRect;
  maxPos: Integer;
begin
  pl := ContentRect;
  maxPos := Max(0, pl.W - kDividerWidth - 24);
  if FDividerPos > 0 then
    FDividerPos := Min(Max(FDividerPos, kDividerMinExpandedPos), maxPos);
  if FDividerSavedPos > 0 then
    FDividerSavedPos := Min(Max(FDividerSavedPos, kDividerMinExpandedPos),
      Max(kDividerMinExpandedPos, maxPos));
end;

procedure TPlaylistForm.ToggleDividerCollapsed;
begin
  if IsDividerCollapsed then
    FDividerPos := Max(kDividerMinExpandedPos, FDividerSavedPos)
  else
  begin
    FDividerSavedPos := FDividerPos;
    FDividerPos := 0;
  end;
  ClampDividerPos;
  InvalidateFrame;
end;

procedure TPlaylistForm.DrawSplitterBar(const R: TSkinRect; Front, Back: TBGRAPixel);
var
  x, totalW: Integer;
  mix: TBGRAPixel;
  frontW, backW: Integer;
begin
  if (R.W <= 0) or (R.H <= 0) or (FFrame = nil) then Exit;

  FFrame.FillRect(R.X, R.Y, R.X + R.W, R.Y + 1, Front, dmSet);
  if R.H > 1 then
    FFrame.FillRect(R.X, R.Y + R.H - 1, R.X + R.W, R.Y + R.H, Front, dmSet);
  if R.H <= 2 then Exit;

  FFrame.FillRect(R.X, R.Y + 1, R.X + 1, R.Y + R.H - 1, Front, dmSet);
  if R.W > 1 then
    FFrame.FillRect(R.X + R.W - 1, R.Y + 1, R.X + R.W, R.Y + R.H - 1, Front, dmSet);

  totalW := R.W;
  for x := 1 to R.W - 2 do
  begin
    frontW := totalW - x;
    backW  := totalW - frontW;
    if totalW <= 0 then Continue;
    mix.red   := Byte((Integer(Front.red)   * frontW + Integer(Back.red)   * backW) div totalW);
    mix.green := Byte((Integer(Front.green) * frontW + Integer(Back.green) * backW) div totalW);
    mix.blue  := Byte((Integer(Front.blue)  * frontW + Integer(Back.blue)  * backW) div totalW);
    mix.alpha := 255;
    FFrame.FillRect(R.X + x, R.Y + 1, R.X + x + 1, R.Y + R.H - 1, mix, dmSet);
  end;
end;

procedure TPlaylistForm.DrawSplitterArrow(const R: TSkinRect; ArrowColor: TBGRAPixel;
  Collapsed: Boolean);
const
  kExpanded: array[0..13] of TPoint = (
    (X:3; Y:-2), (X:4; Y:-2),
    (X:2; Y:-1), (X:3; Y:-1), (X:4; Y:-1),
    (X:1; Y: 0), (X:2; Y: 0), (X:3; Y: 0), (X:4; Y: 0),
    (X:2; Y: 1), (X:3; Y: 1), (X:4; Y: 1),
    (X:3; Y: 2), (X:4; Y: 2)
  );
  kCollapsedPts: array[0..13] of TPoint = (
    (X:0; Y:-2), (X:1; Y:-2),
    (X:0; Y:-1), (X:1; Y:-1), (X:2; Y:-1),
    (X:0; Y: 0), (X:1; Y: 0), (X:2; Y: 0), (X:3; Y: 0),
    (X:0; Y: 1), (X:1; Y: 1), (X:2; Y: 1),
    (X:0; Y: 2), (X:1; Y: 2)
  );
var
  cy, baseX, i: Integer;
begin
  if (R.W < 5) or (R.H < 5) or (FFrame = nil) then Exit;
  cy := R.Y + R.H div 2;
  baseX := R.X;
  if Collapsed then
    for i := 0 to High(kCollapsedPts) do
      FFrame.SetPixel(baseX + kCollapsedPts[i].X, cy + kCollapsedPts[i].Y, ArrowColor)
  else
    for i := 0 to High(kExpanded) do
      FFrame.SetPixel(baseX + kExpanded[i].X, cy + kExpanded[i].Y, ArrowColor);
end;

procedure TPlaylistForm.DrawToolbarGroups;
var
  elem: PSkinElement;
  tb: TSkinRect;
  group, gLeft, gRight, gW, gH: Integer;
  srcLeft, srcRight, srcW, srcH: Integer;
  drawX, drawY: Integer;
  sheet, clip_: TBGRABitmap;
  srcRect: TRect;
  hovered, pressed, hasHot: Boolean;
begin
  if FSkin = nil then Exit;
  elem := FSkin^.PlaylistWindow.FindElement('toolbar');
  if (elem = nil) or (elem^.StatePixmaps[0] = nil) then Exit;

  tb := ToolbarAreaRect;
  if tb.IsEmpty then Exit;
  hasHot := elem^.HotPixmap <> nil;

  for group := 0 to kToolbarGroupCount - 1 do
  begin
    gLeft  := tb.X + (tb.W * group)       div kToolbarGroupCount;
    gRight := tb.X + (tb.W * (group + 1)) div kToolbarGroupCount;
    gW := gRight - gLeft;
    gH := tb.H;
    if gW <= 0 then Continue;

    hovered := FHoveredToolbar = group;
    pressed := FPressedToolbar = group;
    if hasHot and (hovered or pressed) then
      sheet := elem^.HotPixmap
    else
      sheet := elem^.StatePixmaps[0];
    if sheet = nil then Continue;

    srcLeft  := (sheet.Width * group)       div kToolbarGroupCount;
    srcRight := (sheet.Width * (group + 1)) div kToolbarGroupCount;
    srcW := srcRight - srcLeft;
    if srcW <= 0 then srcW := 1;
    srcH := sheet.Height;

    drawX := gLeft + (gW - srcW) div 2;
    drawY := tb.Y  + (gH - srcH) div 2;
    if hasHot then
    begin
      if pressed then begin Inc(drawX); Inc(drawY); end;
    end
    else if hovered and not pressed then
    begin
      Dec(drawX); Dec(drawY);
    end
    else if pressed then
    begin
      Inc(drawX); Inc(drawY);
    end;

    srcRect := Classes.Rect(srcLeft, 0, srcLeft + srcW, srcH);
    clip_ := sheet.GetPart(srcRect);
    try
      FFrame.ClipRect := Classes.Rect(gLeft, tb.Y, gRight, tb.Y + gH);
      FFrame.PutImage(drawX, drawY, clip_, dmDrawWithTransparency);
      FFrame.NoClip;
    finally
      clip_.Free;
    end;
  end;
end;

procedure TPlaylistForm.RenderFrame;
var
  wnd: TSkinWindow;
  elem: PSkinElement;
  bounds: TSkinRect;
  btnX: Integer;
  overType: string;
  overState: TButtonVisualState;
  pl, vis, leftPane, listPane: TSkinRect;
  fillBkgnd, fillBkgnd2, front, back: TBGRAPixel;
  sz: TPoint;
  titleW, titleH: Integer;
  titleRect: TSkinRect;
begin
  if FSkin = nil then Exit;

  wnd := FSkin^.PlaylistWindow;
  sz := BgSize;

  FreeAndNil(FFrame);
  FFrame := TBGRABitmap.Create(FLogicW, FLogicH, BGRAPixelTransparent);

  if wnd.BackgroundPixmap <> nil then
    DrawNinePatch(FFrame, wnd.BackgroundPixmap, wnd.ResizeRect, wnd.ResizeTile,
      FLogicW, FLogicH, True);

  pl := ContentRect;
  fillBkgnd  := FSkin^.PlaylistConfig.ColorBkgnd.ToBGRA;
  fillBkgnd2 := FSkin^.PlaylistConfig.ColorBkgnd2.ToBGRA;
  if not FSkin^.PlaylistConfig.ColorBkgnd.Valid then
    fillBkgnd := BGRA(0, 0, 0, 255);
  if not FSkin^.PlaylistConfig.ColorBkgnd2.Valid then
    fillBkgnd2 := BGRA($20, $20, $20, 255);

  vis := DividerVisualRect;
  if (pl.W > 0) and (pl.H > 0) then
  begin
    if (not IsDividerCollapsed) and (FDividerPos > 0) then
    begin
      leftPane.X := pl.X;
      leftPane.Y := pl.Y;
      leftPane.W := Max(0, vis.X - pl.X);
      leftPane.H := pl.H;
      if leftPane.W > 0 then
        FFrame.FillRect(leftPane.X, leftPane.Y,
          leftPane.X + leftPane.W, leftPane.Y + leftPane.H, fillBkgnd2, dmSet);
    end;
    listPane.X := vis.X + vis.W;
    listPane.Y := pl.Y;
    listPane.W := Max(0, pl.X + pl.W - listPane.X);
    listPane.H := pl.H;
    if listPane.W > 0 then
      FFrame.FillRect(listPane.X, listPane.Y,
        listPane.X + listPane.W, listPane.Y + listPane.H, fillBkgnd, dmSet);
  end;

  DrawToolbarGroups;

  elem := wnd.FindElement('title');
  if (elem <> nil) and (elem^.StatePixmaps[0] <> nil) then
  begin
    titleW := elem^.StatePixmaps[0].Width;
    titleH := elem^.StatePixmaps[0].Height;
    titleRect := AlignedRect(elem^.Position, sz.X, sz.Y, FLogicW, FLogicH,
      elem^.Align, titleW, titleH);
    bounds := ButtonBounds(elem^);
    bounds.X := titleRect.X;
    bounds.Y := titleRect.Y;
    DrawButton(FFrame, elem^, bounds, bvsNormal);
  end;

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

  if FSkin^.PlaylistConfig.ColorText.Valid then
    front := FSkin^.PlaylistConfig.ColorText.ToBGRA
  else
    front := BGRA($00, $80, $FF, 255);
  back := fillBkgnd;

  if (FDividerSavedPos > 0) or (not IsDividerCollapsed) then
  begin
    DrawSplitterBar(vis, front, back);
    DrawSplitterArrow(vis, front, IsDividerCollapsed);
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
  InvalidateFrame;
end;

procedure TPlaylistForm.FireToolbarClick(Group: Integer);
begin
  // Phase 3：弹出对应工具栏菜单。Phase 2 仅消费点击以免落入窗口拖动。
  case Group of
    0..6: ;
  end;
end;

procedure TPlaylistForm.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  er, eb: Boolean;
  hitName: string;
  group: Integer;
begin
  if Button = mbLeft then
  begin
    if ssDouble in Shift then
    begin
      if (FDividerSavedPos > 0) and PtInSkinRect(X, Y, DividerHotZoneRect) then
      begin
        FDividerDragging := False;
        FDividerHandlePressed := False;
        ToggleDividerCollapsed;
        Cursor := crDefault;
        Exit;
      end;
    end;

    hitName := HitButton(X, Y);
    if hitName <> '' then
    begin
      FPressedType := hitName;
      InvalidateFrame;
    end
    else
    begin
      group := ToolbarGroupIndexAt(X, Y);
      if group >= 0 then
      begin
        FPressedToolbar := group;
        InvalidateFrame;
      end
      else if (FDividerSavedPos > 0) and PtInSkinRect(X, Y, DividerHotZoneRect) then
      begin
        FDividerDragging := True;
        FDividerHandlePressed := PtInSkinRect(X, Y, DividerHandleRect);
        FDividerDragStartX := X;
        SetCapture(Handle);
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
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TPlaylistForm.DblClick;
begin
  inherited DblClick;
end;

procedure TPlaylistForm.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  newName: string;
  er, eb: Boolean;
  newW, newH, dx, dy, newPos: Integer;
  newGroup: Integer;
  pl: TSkinRect;
  needRedraw: Boolean;
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
      ClampDividerPos;
      FreeAndNil(FFrame);
      RenderFrame;
      if HandleAllocated then BuildRegion;
      Invalidate;
    end;
  end
  else if FDividerDragging then
  begin
    pl := ContentRect;
    newPos := X - pl.X;
    newPos := Max(0, Min(newPos, pl.W - 40));
    if newPos <> FDividerPos then
    begin
      FDividerPos := newPos;
      InvalidateFrame;
    end;
  end
  else
  begin
    needRedraw := False;
    newName := HitButton(X, Y);
    if newName <> FHoveredType then
    begin
      FHoveredType := newName;
      needRedraw := True;
    end;
    newGroup := ToolbarGroupIndexAt(X, Y);
    if newGroup <> FHoveredToolbar then
    begin
      FHoveredToolbar := newGroup;
      needRedraw := True;
    end;
    if needRedraw then InvalidateFrame;

    if HitResizeEdge(X, Y, er, eb) then
    begin
      if er and eb then Cursor := crSizeNWSE
      else if er    then Cursor := crSizeWE
      else               Cursor := crSizeNS;
    end
    else if (FDividerSavedPos > 0) and PtInSkinRect(X, Y, DividerHandleRect) then
      Cursor := crHandPoint
    else if (FDividerSavedPos > 0) and PtInSkinRect(X, Y, DividerHotZoneRect) then
      Cursor := crHSplit
    else if newGroup >= 0 then
      Cursor := crHandPoint
    else
      Cursor := crDefault;
  end;
  inherited MouseMove(Shift, X, Y);
end;

procedure TPlaylistForm.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  clickedType, hitName: string;
  group, released: Integer;
  wasDrag: Boolean;
begin
  if Button = mbLeft then
  begin
    if FDividerDragging then
    begin
      ReleaseCapture;
      wasDrag := Abs(X - FDividerDragStartX) > 3;
      FDividerDragging := False;
      if wasDrag then
      begin
        if FDividerPos <= kDividerCollapseThreshold then
          FDividerPos := 0
        else
          FDividerSavedPos := FDividerPos;
        ClampDividerPos;
        InvalidateFrame;
      end
      else if FDividerHandlePressed and PtInSkinRect(X, Y, DividerHandleRect) then
        ToggleDividerCollapsed;
      FDividerHandlePressed := False;
      Cursor := crDefault;
    end
    else if FResizing then
    begin
      ReleaseCapture;
      FResizing := False;
    end
    else if FPressedToolbar >= 0 then
    begin
      group := FPressedToolbar;
      FPressedToolbar := -1;
      released := ToolbarGroupIndexAt(X, Y);
      InvalidateFrame;
      if (released >= 0) and (released = group) then
        FireToolbarClick(group);
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
        else
          InvalidateFrame;
      end;
    end;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TPlaylistForm.MouseLeave;
begin
  if (FHoveredType <> '') or (FPressedType <> '') or
     (FHoveredToolbar >= 0) or (FPressedToolbar >= 0) then
  begin
    FHoveredType := '';
    FPressedType := '';
    FHoveredToolbar := -1;
    FPressedToolbar := -1;
    InvalidateFrame;
  end;
  Cursor := crDefault;
  inherited MouseLeave;
end;

procedure TPlaylistForm.WMNCHitTest(var Msg: TLMessage);
var
  pt: TPoint;
  er, eb: Boolean;
  pl: TSkinRect;
begin
  pt := ScreenToClient(Point(
    SmallInt(Msg.LParam and $FFFF),
    SmallInt((Msg.LParam shr 16) and $FFFF)));

  if HitButton(pt.X, pt.Y) <> '' then
    Msg.Result := HTCLIENT
  else if ToolbarGroupIndexAt(pt.X, pt.Y) >= 0 then
    Msg.Result := HTCLIENT
  else if HitResizeEdge(pt.X, pt.Y, er, eb) then
    Msg.Result := HTCLIENT
  else if (FDividerSavedPos > 0) and PtInSkinRect(pt.X, pt.Y, DividerHotZoneRect) then
    Msg.Result := HTCLIENT
  else
  begin
    pl := ContentRect;
    if PtInSkinRect(pt.X, pt.Y, pl) then
      Msg.Result := HTCLIENT
    else
      Msg.Result := HTCAPTION;
  end;
end;

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
