unit ULyricForm;

{$mode objfpc}{$H+}

// 歌词窗口，对应 Qt 版 src/ui/LyricWindow。
// 无边框自绘，九宫格背景，右/下边缘可调整大小。
// close/ontop 按钮以原始 position 坐标绘制，align 修正通过 AlignedButtonX 计算。
// WMNCHitTest 返回 HTCAPTION 实现拖动；边缘拖动在 MouseDown/Move/Up 中处理。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, LCLIntf, LCLType, LMessages,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UPlayerBackend;

type
  TLyricForm = class(TForm)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;

    // 应用皮肤；换肤时调用。
    procedure ApplySkin(const ASkin: TSkinData);

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

    // 当前窗口逻辑尺寸（用于九宫格和命中测试）
    FLogicW, FLogicH: Integer;

    // 交互状态
    FHoveredType: string;
    FPressedType: string;
    FAlwaysOnTop: Boolean;

    // 边缘拖动调整大小
    FResizing: Boolean;
    FResizeEdgeRight: Boolean;   // 拖动右边缘
    FResizeEdgeBottom: Boolean;  // 拖动下边缘
    FResizeStartX: Integer;      // 拖动起始屏幕 X
    FResizeStartY: Integer;
    FResizeStartW: Integer;
    FResizeStartH: Integer;

    procedure BuildRegion;
    procedure RenderFrame;

    // 命中测试：返回按钮名或 ''
    function HitButton(PX, PY: Integer): string;
    // 是否命中右/下可调整边缘（8 px 感应带）
    function HitResizeEdge(PX, PY: Integer;
      out EdgeRight, EdgeBottom: Boolean): Boolean;
    // 计算 align='right' 按钮的实际 X（与 Qt alignedRect 等价，使用 baseSize）
    function AlignedButtonX(const Elem: TSkinElement): Integer;

    procedure FireButtonClick(const AName: string);
  end;

implementation

uses
  LCLProc, Math;

const
  kResizeSense = 8;  // 调整大小感应带宽度（像素）

{ TLyricForm }

constructor TLyricForm.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  inherited CreateNew(AOwner);

  FSkin    := nil;
  FBackend := ABackend;
  FFrame   := nil;

  FLogicW  := 268;
  FLogicH  := 60;
  FAlwaysOnTop := False;

  FHoveredType := '';
  FPressedType := '';
  FResizing := False;

  BorderStyle := bsNone;
  FormStyle   := fsNormal;
  Color       := clBlack;

  MouseLeave;
end;

destructor TLyricForm.Destroy;
begin
  FFrame.Free;
  inherited Destroy;
end;

procedure TLyricForm.ApplySkin(const ASkin: TSkinData);
var
  bg: TBGRABitmap;
begin
  FSkin := @ASkin;

  bg := ASkin.LyricWindow.BackgroundPixmap;
  if bg <> nil then
  begin
    FLogicW := bg.Width;
    FLogicH := bg.Height;
    SetBounds(Left, Top, bg.Width, bg.Height);
  end;

  if HandleAllocated then
    BuildRegion;

  FreeAndNil(FFrame);
  RenderFrame;
  Invalidate;
end;

// 从背景位图生成异形 HRGN（对应 LyricWindow::updateChromeGeometry → setMask）。
procedure TLyricForm.BuildRegion;
var
  bmp: TBGRABitmap;
  totalRgn, rowRgn, segRgn: HRGN;
  bx, by, startX, bw, bh: Integer;
  p: PBGRAPixel;
begin
  if FSkin = nil then Exit;
  bmp := FSkin^.LyricWindow.BackgroundPixmap;
  if bmp = nil then Exit;

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

procedure TLyricForm.RenderFrame;
var
  overType: string;
  overState: TButtonVisualState;
  wnd: TSkinWindow;
  elem: PSkinElement;
  bounds: TSkinRect;
  btnX: Integer;
begin
  if FSkin = nil then Exit;
  FreeAndNil(FFrame);

  wnd := FSkin^.LyricWindow;

  // 九宫格背景（当前窗口尺寸）
  if wnd.BackgroundPixmap <> nil then
  begin
    FFrame := TBGRABitmap.Create(FLogicW, FLogicH, BGRAPixelTransparent);
    DrawNinePatch(FFrame, wnd.BackgroundPixmap, wnd.ResizeRect, wnd.ResizeTile,
      FLogicW, FLogicH);
  end
  else
    FFrame := TBGRABitmap.Create(FLogicW, FLogicH, BGRAPixelTransparent);

  overType  := '';
  overState := bvsNormal;
  if FPressedType <> '' then begin overType := FPressedType; overState := bvsPressed; end
  else if FHoveredType <> '' then begin overType := FHoveredType; overState := bvsHover; end;

  // close 按钮
  elem := wnd.FindElement('close');
  if elem <> nil then
  begin
    bounds := ButtonBounds(elem^);
    btnX := AlignedButtonX(elem^);
    bounds.X := btnX;
    if SameText(overType, 'close') then
      DrawButton(FFrame, elem^, bounds, overState)
    else
      DrawButton(FFrame, elem^, bounds, bvsNormal);
  end;

  // ontop 按钮（usePressedStateForToggle：开启时用 bvsPressed 渲染）
  elem := wnd.FindElement('ontop');
  if elem <> nil then
  begin
    bounds := ButtonBounds(elem^);
    btnX := AlignedButtonX(elem^);
    bounds.X := btnX;
    if SameText(overType, 'ontop') then
      DrawButton(FFrame, elem^, bounds, overState)
    else if FAlwaysOnTop then
      DrawButton(FFrame, elem^, bounds, bvsPressed)
    else
      DrawButton(FFrame, elem^, bounds, bvsNormal);
  end;
end;

procedure TLyricForm.Paint;
begin
  if FFrame = nil then Exit;
  FFrame.Draw(Canvas, 0, 0, True);
end;

// Qt alignedRect('right') 的等价计算：
//   rightMargin = baseSize.w - (pos.x + pos.w)
//   x = currentW - rightMargin - btnW
function TLyricForm.AlignedButtonX(const Elem: TSkinElement): Integer;
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
  baseW := FSkin^.LyricWindow.BackgroundPixmap.Width;
  rightMargin := baseW - (Elem.Position.X + Elem.Position.W);
  btnW := ButtonBounds(Elem).W;
  Result := FLogicW - rightMargin - btnW;
end;

// 命中测试：close / ontop 按钮（使用运行时 AlignedButtonX）
function TLyricForm.HitButton(PX, PY: Integer): string;
var
  wnd: TSkinWindow;
  elem: PSkinElement;
  bounds: TSkinRect;
  btnX: Integer;
  i: Integer;
const
  kBtnNames: array[0..1] of string = ('close', 'ontop');
begin
  Result := '';
  if FSkin = nil then Exit;
  wnd := FSkin^.LyricWindow;

  for i := 0 to High(kBtnNames) do
  begin
    elem := wnd.FindElement(kBtnNames[i]);
    if elem = nil then Continue;
    bounds := ButtonBounds(elem^);
    btnX := AlignedButtonX(elem^);
    if (PX >= btnX) and (PX < btnX + bounds.W) and
       (PY >= elem^.Position.Y) and (PY < elem^.Position.Y + bounds.H) then
    begin
      Result := kBtnNames[i];
      Exit;
    end;
  end;
end;

// 8 px 边缘感应带：右边缘和/或下边缘
function TLyricForm.HitResizeEdge(PX, PY: Integer;
  out EdgeRight, EdgeBottom: Boolean): Boolean;
begin
  EdgeRight  := (PX >= FLogicW - kResizeSense) and (PX < FLogicW);
  EdgeBottom := (PY >= FLogicH - kResizeSense) and (PY < FLogicH);
  Result := EdgeRight or EdgeBottom;
end;

procedure TLyricForm.FireButtonClick(const AName: string);
begin
  if SameText(AName, 'close') then
    Hide
  else if SameText(AName, 'ontop') then
  begin
    FAlwaysOnTop := not FAlwaysOnTop;
    // 实际置顶由 ULyricForm 外部处理（与 TPlayerForm.SetAuxToggle 模式一致）
  end;

  RenderFrame;
  Invalidate;
end;

procedure TLyricForm.MouseDown(Button: TMouseButton; Shift: TShiftState;
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
      FResizing := True;
      FResizeEdgeRight  := er;
      FResizeEdgeBottom := eb;
      FResizeStartX := Mouse.CursorPos.X;
      FResizeStartY := Mouse.CursorPos.Y;
      FResizeStartW := FLogicW;
      FResizeStartH := FLogicH;
      SetCapture(Handle);
    end;
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TLyricForm.MouseMove(Shift: TShiftState; X, Y: Integer);
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
    if FResizeEdgeRight  then newW := Max(200, FResizeStartW + dx);
    if FResizeEdgeBottom then newH := Max(50,  FResizeStartH + dy);
    if (newW <> FLogicW) or (newH <> FLogicH) then
    begin
      FLogicW := newW;
      FLogicH := newH;
      SetBounds(Left, Top, newW, newH);
      if HandleAllocated then BuildRegion;
      FreeAndNil(FFrame);
      RenderFrame;
      Invalidate;
    end;
  end
  else
  begin
    // hover 高亮（按钮）
    newName := HitButton(X, Y);
    if newName <> FHoveredType then
    begin
      FHoveredType := newName;
      RenderFrame; Invalidate;
    end;
    // 调整大小光标
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

procedure TLyricForm.MouseUp(Button: TMouseButton; Shift: TShiftState;
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

procedure TLyricForm.MouseLeave;
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

// 背景区域 → HTCAPTION（拖动）；按钮/边缘 → HTCLIENT
procedure TLyricForm.WMNCHitTest(var Msg: TLMessage);
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
    Msg.Result := HTCLIENT   // 让 MouseDown/Move/Up 处理调整大小
  else
    Msg.Result := HTCAPTION;
end;

end.
