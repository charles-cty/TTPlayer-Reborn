unit UEqualizerForm;

{$mode objfpc}{$H+}

// 均衡器窗口，对应 Qt 版 src/ui/EqualizerWindow。
// 无边框自绘，异形 Region 色键；10 波段垂直 EQ 滑块 + preamp/balance/surround 滑块。
// 拖动通过 WMNCHitTest 返回 HTCAPTION 实现（同 UPlayerForm）。
// 滑块拖动：MouseDown 捕获鼠标，MouseMove 从绝对坐标计算值，MouseUp 释放。
// EQ 关闭时（原版行为）：preamp 与十波段不可调，点击落在 HTCAPTION；
// balance / surround 以及预设/复位按钮仍可用。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, LCLIntf, LCLType, LMessages,
  Menus, BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UPlayerBackend, UPlatformWindow, USkinView,
  USkinErase;

type
  // 正在拖动的滑块的完整状态（'' = 无拖动）。
  TSliderDragState = record
    SliderName: string;       // 'preamp' / 'balance' / 'surround' / 'eq0'..'eq9'
    SliderElem: TSkinElement; // 元素拷贝（eqfactor 已将 Position.X 修正到该波段）
    MinV, MaxV: Double;
    IsVert: Boolean;          // True = 垂直滑块
  end;

  TEqualizerForm = class(TForm, ISkinViewForm)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;

    // 应用皮肤；换肤时调用，重建 Region 并刷新。
    procedure ApplySkin(ASkin: PSkinData);
    procedure RefreshViewScale;
    procedure RebuildWindowShape;
    procedure ApplyEqConfig(AEnabled: Boolean; Preamp: Double;
      const Bands: array of Double; Balance: Integer);
    function GetPreamp: Double;
    function GetEqEnabled: Boolean;
    function GetEqBand(Index: Integer): Double;
    function GetBalanceValue: Integer;

  protected
    procedure Paint; override;
    procedure WMEraseBkgnd(var Message: TLMEraseBkgnd); message LM_ERASEBKGND;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure CreateWnd; override;
    procedure DoShow; override;

    // 背景→HTCAPTION（系统拖动），按钮/滑块→HTCLIENT。
    procedure WMNCHitTest(var Msg: TLMessage); message LM_NCHITTEST;

  private
    FSkin: PSkinData;
    FBackend: IPlayerBackend;
    FFrame: TBGRABitmap;

    // EQ 状态
    FEqGains:  array[0..9] of Double;  // -12..+12 dB
    FPreamp:   Double;                  // -12..+12 dB
    FBalance:  Double;                  // -100..+100
    FSurround: Double;                  // 0..100
    FEqEnabled: Boolean;

    // 交互状态
    FHoveredType: string;
    FPressedType: string;
    FDrag: TSliderDragState;
    FMouseCaptured: Boolean;

    FProfileMenu: TPopupMenu;

    procedure BuildRegion;
    procedure UpdateCaption;
    procedure RenderFrame;
    procedure SkinSize(out W, H: Integer);
    procedure MapHit(var X, Y: Integer);
    procedure BuildProfileMenu;
    procedure OnPresetClick(Sender: TObject);

    // 综合命中测试。参数 PX/PY 为窗口客户区坐标。
    // 返回 True 表示命中；hitName 为元素名；hitElem 已拷贝并调整 Position；
    // hitIsSlider=True 时 hitMinV/MaxV/IsVert 有效。
    function HitTest(PX, PY: Integer;
      out hitName: string; out hitElem: TSkinElement;
      out hitIsSlider: Boolean;
      out hitMinV, hitMaxV: Double; out hitIsVert: Boolean): Boolean;

    function IsEqButton(const AName: string): Boolean;
    // 原版/Qt：EQ 关闭时前置增益与十波段不可调；balance/surround 仍可。
    function IsGatedEqSlider(const AName: string): Boolean;
    procedure FireButtonClick(const AName: string; MouseX, MouseY: Integer);
  end;

implementation

uses
  LCLProc, Math, UFormSnap;

{ ── EQ 预设（与 Qt EqualizerWindow::initPresets 一致）─────────────── }

type
  TEqPreset = record
    Caption: string;
    Bands:   array[0..9] of Double;
    Preamp:  Double;
  end;

const
  kPresets: array[0..10] of TEqPreset = (
    (Caption:'平坦';     Bands:( 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); Preamp:0),
    (Caption:'摇滚';     Bands:( 4, 3,-2,-4,-2, 2, 4, 7, 7, 6); Preamp:0),
    (Caption:'流行';     Bands:(-1, 3, 5, 5, 3,-1,-2,-2,-1,-1); Preamp:0),
    (Caption:'古典';     Bands:( 4, 4, 3, 3, 0, 0, 0,-3,-3,-4); Preamp:0),
    (Caption:'爵士';     Bands:( 0, 0, 0, 3, 3, 3, 0,-2,-2,-2); Preamp:0),
    (Caption:'舞曲';     Bands:( 4, 7, 5, 0, 2, 4, 6, 6, 5, 0); Preamp:0),
    (Caption:'重金属';   Bands:( 4, 3, 1, 4, 3, 0,-2, 0, 4, 4); Preamp:0),
    (Caption:'人声';     Bands:(-2,-2, 0, 2, 5, 5, 3, 1, 0,-1); Preamp:0),
    (Caption:'轻音乐';   Bands:( 3, 1, 0,-1,-1, 0, 1, 3, 3, 4); Preamp:0),
    (Caption:'低音加强'; Bands:( 6, 5, 3, 1, 0, 0, 0, 0, 0, 0); Preamp:0),
    (Caption:'高音加强'; Bands:( 0, 0, 0, 0, 0, 1, 3, 5, 5, 6); Preamp:0)
  );

  // 按钮元素名称清单（与 kEqButtonTypes in USkinRender 一致）
  kEqButtonNames: array[0..3] of string = ('close', 'enabled', 'profile', 'reset');

{ TEqualizerForm }

constructor TEqualizerForm.Create(AOwner: TComponent; ABackend: IPlayerBackend);
var
  i: Integer;
begin
  inherited CreateNew(AOwner);

  FSkin    := nil;
  FBackend := ABackend;
  FFrame   := nil;

  for i := 0 to 9 do FEqGains[i] := 0;
  FPreamp    := 0;
  FBalance   := 0;
  FSurround  := 0;
  FEqEnabled := False;  // 与 Qt Equalizer::enabled_ / Config.eqEnabled_ 默认一致
  if FBackend <> nil then
    FBalance := FBackend.GetBalance;

  FDrag.SliderName := '';
  FMouseCaptured   := False;

  BorderStyle := bsNone;
  FormStyle   := fsNormal;
  Color       := clBlack;
  Caption     := 'Equalizer';
  ShowInTaskBar := stNever;
  UpdateCaption;

  FProfileMenu := TPopupMenu.Create(Self);
  BuildProfileMenu;

  MouseLeave;
end;

destructor TEqualizerForm.Destroy;
begin
  FFrame.Free;
  inherited Destroy;
end;

procedure TEqualizerForm.ApplyEqConfig(AEnabled: Boolean; Preamp: Double;
  const Bands: array of Double; Balance: Integer);
var
  i: Integer;
begin
  FEqEnabled := AEnabled;
  FPreamp := Preamp;
  FBalance := Balance;
  for i := 0 to 9 do
    if i <= High(Bands) then
      FEqGains[i] := Bands[i];
  if FBackend <> nil then
  begin
    FBackend.SetEqEnabled(FEqEnabled);
    FBackend.SetPreamp(FPreamp);
    FBackend.SetBalance(Round(FBalance));
    for i := 0 to 9 do
      FBackend.SetEqGain(i, FEqGains[i]);
  end;
  UpdateCaption;
  RenderFrame;
  Invalidate;
end;

function TEqualizerForm.GetPreamp: Double;
begin
  Result := FPreamp;
end;

function TEqualizerForm.GetEqEnabled: Boolean;
begin
  Result := FEqEnabled;
end;

function TEqualizerForm.GetEqBand(Index: Integer): Double;
begin
  if (Index >= 0) and (Index <= 9) then
    Result := FEqGains[Index]
  else
    Result := 0;
end;

function TEqualizerForm.GetBalanceValue: Integer;
begin
  Result := Round(FBalance);
end;

procedure TEqualizerForm.ApplySkin(ASkin: PSkinData);
begin
  if ASkin = nil then Exit;
  FSkin := ASkin;
  ConfigurePlatformWindow(Self);

  if HandleAllocated then
    ClearWindowShape(Handle);

  if ASkin^.EqualizerWindow.BackgroundPixmap <> nil then
    ApplySkinFormSize(Self,
      ASkin^.EqualizerWindow.BackgroundPixmap.Width,
      ASkin^.EqualizerWindow.BackgroundPixmap.Height);

  if HandleAllocated then
    BuildRegion;

  FreeAndNil(FFrame);
  RenderFrame;
  Invalidate;
  if HandleAllocated then
    Update;
end;

procedure TEqualizerForm.UpdateCaption;
begin
  if FEqEnabled then
    Caption := 'Equalizer ON'
  else
    Caption := 'Equalizer';
end;

procedure TEqualizerForm.BuildRegion;
var
  bmp: TBGRABitmap;
begin
  if (FSkin = nil) or (not HandleAllocated) then Exit;
  bmp := FSkin^.EqualizerWindow.BackgroundPixmap;
  if bmp = nil then Exit;
  ApplyAlphaShape(Handle, bmp);
end;

procedure TEqualizerForm.SkinSize(out W, H: Integer);
var
  bmp: TBGRABitmap;
begin
  W := Width;
  H := Height;
  if FSkin = nil then Exit;
  bmp := FSkin^.EqualizerWindow.BackgroundPixmap;
  if bmp = nil then Exit;
  W := bmp.Width;
  H := bmp.Height;
end;

procedure TEqualizerForm.MapHit(var X, Y: Integer);
var
  sw, sh: Integer;
begin
  SkinSize(sw, sh);
  ClientToSkinXY(Self, sw, sh, X, Y);
end;

procedure TEqualizerForm.RefreshViewScale;
var
  sw, sh: Integer;
begin
  if FSkin = nil then Exit;
  SkinSize(sw, sh);
  ApplySkinFormSize(Self, sw, sh);
  if HandleAllocated then
    BuildRegion;
  Invalidate;
end;

procedure TEqualizerForm.RebuildWindowShape;
begin
  if HandleAllocated then
    BuildRegion;
end;

procedure TEqualizerForm.CreateWnd;
begin
  inherited CreateWnd;
  ConfigurePlatformWindow(Self);
  RefreshViewScale;
end;

procedure TEqualizerForm.DoShow;
begin
  inherited DoShow;
  ConfigurePlatformWindow(Self);
  RefreshViewScale;
  BuildRegion;
end;

procedure TEqualizerForm.RenderFrame;
var
  gains: array[0..9] of Double;
  overType: string;
  overState: TButtonVisualState;
  i: Integer;
begin
  if FSkin = nil then Exit;

  FreeAndNil(FFrame);

  for i := 0 to 9 do gains[i] := FEqGains[i];

  overType  := '';
  overState := bvsNormal;
  if FPressedType <> '' then
  begin
    overType  := FPressedType;
    overState := bvsPressed;
  end
  else if FHoveredType <> '' then
  begin
    overType  := FHoveredType;
    overState := bvsHover;
  end;

  FFrame := RenderEqualizerWindow(FSkin^,
    gains, FPreamp, FBalance, FSurround, FEqEnabled,
    overType, overState);
end;

procedure TEqualizerForm.Paint;
begin
  if FFrame = nil then Exit;
  DrawSkinFrame(Canvas, FFrame, ClientWidth, ClientHeight);
end;

procedure TEqualizerForm.WMEraseBkgnd(var Message: TLMEraseBkgnd);
begin
  SwallowSkinEraseBkgnd(Message.Result);
end;

procedure TEqualizerForm.BuildProfileMenu;
var
  i: Integer;
  item: TMenuItem;
begin
  FProfileMenu.Items.Clear;
  for i := 0 to High(kPresets) do
  begin
    item := TMenuItem.Create(FProfileMenu);
    item.Caption := kPresets[i].Caption;
    item.Tag := i;
    item.OnClick := @OnPresetClick;
    FProfileMenu.Items.Add(item);
  end;
end;

procedure TEqualizerForm.OnPresetClick(Sender: TObject);
var
  idx, band: Integer;
begin
  idx := TMenuItem(Sender).Tag;
  if (idx < 0) or (idx > High(kPresets)) then Exit;

  for band := 0 to 9 do
    FEqGains[band] := kPresets[idx].Bands[band];
  FPreamp := kPresets[idx].Preamp;

  if FBackend <> nil then
  begin
    for band := 0 to 9 do
      FBackend.SetEqGain(band, FEqGains[band]);
    FBackend.SetPreamp(FPreamp);
  end;

  RenderFrame;
  Invalidate;
end;

function TEqualizerForm.IsEqButton(const AName: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(kEqButtonNames) do
    if SameText(AName, kEqButtonNames[i]) then Exit(True);
  Result := False;
end;

function TEqualizerForm.IsGatedEqSlider(const AName: string): Boolean;
begin
  Result := SameText(AName, 'preamp') or
            ((Length(AName) >= 3) and (LowerCase(Copy(AName, 1, 2)) = 'eq'));
end;

// 综合命中测试：按钮优先，其次各类滑块。
// 用 PX/PY 而非 X/Y 避免与 TSkinRect 的字段名冲突。
function TEqualizerForm.HitTest(PX, PY: Integer;
  out hitName: string; out hitElem: TSkinElement;
  out hitIsSlider: Boolean;
  out hitMinV, hitMaxV: Double; out hitIsVert: Boolean): Boolean;
var
  wnd: TSkinWindow;
  i, band: Integer;
  ep: PSkinElement;
  pos: TSkinRect;
  bandRect: TSkinRect;
begin
  Result      := False;
  hitIsSlider := False;
  hitMinV     := 0;
  hitMaxV     := 0;
  hitIsVert   := False;
  if FSkin = nil then Exit;

  wnd := FSkin^.EqualizerWindow;

  // ── 1. 按钮 ──────────────────────────────────────────────────────────
  for i := 0 to High(kEqButtonNames) do
  begin
    ep := wnd.FindElement(kEqButtonNames[i]);
    if ep = nil then Continue;
    pos := ep^.Position;
    if (PX >= pos.X) and (PX < pos.X + pos.W) and
       (PY >= pos.Y) and (PY < pos.Y + pos.H) then
    begin
      hitName     := kEqButtonNames[i];
      hitElem     := ep^;
      hitIsSlider := False;
      Exit(True);
    end;
  end;

  // ── 2. Preamp 滑块（垂直，-12..+12；EQ 关闭时不命中，交给 HTCAPTION）
  ep := wnd.FindElement('preamp');
  if (ep <> nil) and FEqEnabled then
  begin
    pos := ep^.Position;
    if (PX >= pos.X) and (PX < pos.X + pos.W) and
       (PY >= pos.Y) and (PY < pos.Y + pos.H) then
    begin
      hitName     := 'preamp';
      hitElem     := ep^;
      hitElem.Vertical := True;
      hitIsSlider := True;
      hitMinV     := -12;  hitMaxV := 12;
      hitIsVert   := True;
      Exit(True);
    end;
  end;

  // ── 3. Balance 滑块（水平，-100..+100）──────────────────────────────
  ep := wnd.FindElement('balance');
  if ep <> nil then
  begin
    pos := ep^.Position;
    if (PX >= pos.X) and (PX < pos.X + pos.W) and
       (PY >= pos.Y) and (PY < pos.Y + pos.H) then
    begin
      hitName     := 'balance';
      hitElem     := ep^;
      hitElem.Vertical := False;
      hitIsSlider := True;
      hitMinV     := -100;  hitMaxV := 100;
      hitIsVert   := False;
      Exit(True);
    end;
  end;

  // ── 4. Surround 滑块（水平，0..100）─────────────────────────────────
  ep := wnd.FindElement('surround');
  if ep <> nil then
  begin
    pos := ep^.Position;
    if (PX >= pos.X) and (PX < pos.X + pos.W) and
       (PY >= pos.Y) and (PY < pos.Y + pos.H) then
    begin
      hitName     := 'surround';
      hitElem     := ep^;
      hitElem.Vertical := False;
      hitIsSlider := True;
      hitMinV     := 0;  hitMaxV := 100;
      hitIsVert   := False;
      Exit(True);
    end;
  end;

  // ── 5. EQ factor 滑块（垂直 × 10，-12..+12；EQ 关闭时不命中）────────
  ep := wnd.FindElement('eqfactor');
  if (ep <> nil) and FEqEnabled then
    for band := 0 to 9 do
    begin
      bandRect := EqFactorRect(ep^, band, wnd.EqInterval);
      if (PX >= bandRect.X) and (PX < bandRect.X + bandRect.W) and
         (PY >= bandRect.Y) and (PY < bandRect.Y + bandRect.H) then
      begin
        hitName     := 'eq' + IntToStr(band);
        hitElem     := ep^;
        hitElem.Position := bandRect;
        hitElem.Vertical := True;
        hitIsSlider := True;
        hitMinV     := -12;  hitMaxV := 12;
        hitIsVert   := True;
        Exit(True);
      end;
    end;
end;

procedure TEqualizerForm.FireButtonClick(const AName: string;
  MouseX, MouseY: Integer);
var
  menuPt: TPoint;
  band: Integer;
begin
  if SameText(AName, 'enabled') then
  begin
    FEqEnabled := not FEqEnabled;
    if FBackend <> nil then
      FBackend.SetEqEnabled(FEqEnabled);
    UpdateCaption;
  end
  else if SameText(AName, 'close') then
    Hide
  else if SameText(AName, 'profile') then
  begin
    menuPt := ClientToScreen(Point(MouseX, MouseY));
    FProfileMenu.PopUp(menuPt.X, menuPt.Y);
  end
  else if SameText(AName, 'reset') then
  begin
    FPreamp := 0;
    FillChar(FEqGains, SizeOf(FEqGains), 0);
    if FBackend <> nil then
    begin
      FBackend.SetPreamp(0);
      for band := 0 to 9 do
        FBackend.SetEqGain(band, 0);
    end;
  end;

  RenderFrame;
  Invalidate;
end;

procedure TEqualizerForm.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  hitName: string;
  hitElem: TSkinElement;
  hitIsSlider: Boolean;
  hitMinV, hitMaxV: Double;
  hitIsVert: Boolean;
  sx, sy: Integer;
begin
  sx := X;
  sy := Y;
  MapHit(sx, sy);
  if Button = mbLeft then
  begin
    if HitTest(sx, sy, hitName, hitElem, hitIsSlider,
               hitMinV, hitMaxV, hitIsVert) then
    begin
      if hitIsSlider then
      begin
        if FEqEnabled or (not IsGatedEqSlider(hitName)) then
        begin
          FDrag.SliderName := hitName;
          FDrag.SliderElem := hitElem;
          FDrag.MinV       := hitMinV;
          FDrag.MaxV       := hitMaxV;
          FDrag.IsVert     := hitIsVert;
          SetCapture(Handle);
          FMouseCaptured := True;
        end;
      end
      else
      begin
        FPressedType := hitName;
        RenderFrame;
        Invalidate;
      end;
    end;
  end;
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
    TryBeginCaptionDrag(Self, X, Y);
end;

procedure TEqualizerForm.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  hitName: string;
  hitElem: TSkinElement;
  hitIsSlider: Boolean;
  hitMinV, hitMaxV: Double;
  hitIsVert: Boolean;
  newPx: Integer;
  newVal: Double;
  band: Integer;
  needRedraw: Boolean;
  newHover: string;
begin
  MapHit(X, Y);
  if FDrag.SliderName <> '' then
  begin
    // ── 拖动滑块 ─────────────────────────────────────────────────────
    if FDrag.IsVert then
      newPx := Y - FDrag.SliderElem.Position.Y
    else
      newPx := X - FDrag.SliderElem.Position.X;

    if FDrag.IsVert then
      newVal := SliderPosToValue(newPx, FDrag.MinV, FDrag.MaxV,
        FDrag.SliderElem.Position.H, True)
    else
      newVal := SliderPosToValue(newPx, FDrag.MinV, FDrag.MaxV,
        FDrag.SliderElem.Position.W, False);

    if newVal < FDrag.MinV then newVal := FDrag.MinV;
    if newVal > FDrag.MaxV then newVal := FDrag.MaxV;

    needRedraw := False;

    if SameText(FDrag.SliderName, 'preamp') then
    begin
      if FPreamp <> newVal then
      begin
        FPreamp := newVal;
        if FBackend <> nil then FBackend.SetPreamp(FPreamp);
        needRedraw := True;
      end;
    end
    else if SameText(FDrag.SliderName, 'balance') then
    begin
      if FBalance <> newVal then
      begin
        FBalance := newVal;
        if FBackend <> nil then
          FBackend.SetBalance(Round(FBalance));
        needRedraw := True;
      end;
    end
    else if SameText(FDrag.SliderName, 'surround') then
    begin
      if FSurround <> newVal then
      begin
        FSurround := newVal;
        needRedraw := True;
      end;
    end
    else if (Length(FDrag.SliderName) > 2) and
            (Copy(FDrag.SliderName, 1, 2) = 'eq') then
    begin
      band := StrToIntDef(Copy(FDrag.SliderName, 3, 10), -1);
      if (band >= 0) and (band <= 9) and (FEqGains[band] <> newVal) then
      begin
        FEqGains[band] := newVal;
        if FBackend <> nil then FBackend.SetEqGain(band, newVal);
        needRedraw := True;
      end;
    end;

    if needRedraw then
    begin
      RenderFrame;
      Invalidate;
    end;
  end
  else
  begin
    // ── Hover 高亮（仅对按钮，不对滑块）──────────────────────────────
    if HitTest(X, Y, hitName, hitElem, hitIsSlider,
               hitMinV, hitMaxV, hitIsVert) and
       (not hitIsSlider) then
      newHover := hitName
    else
      newHover := '';

    if newHover <> FHoveredType then
    begin
      FHoveredType := newHover;
      RenderFrame;
      Invalidate;
    end;
  end;
  inherited MouseMove(Shift, X, Y);
end;

procedure TEqualizerForm.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  clickedType: string;
  hitName: string;
  hitElem: TSkinElement;
  hitIsSlider: Boolean;
  hitMinV, hitMaxV: Double;
  hitIsVert: Boolean;
  sx, sy: Integer;
begin
  sx := X;
  sy := Y;
  MapHit(sx, sy);
  if Button = mbLeft then
  begin
    if FMouseCaptured then
    begin
      ReleaseCapture;
      FMouseCaptured := False;
    end;

    if FDrag.SliderName <> '' then
      FDrag.SliderName := ''
    else
    begin
      clickedType  := FPressedType;
      FPressedType := '';
      if clickedType <> '' then
      begin
        // 鼠标在同一按钮上抬起才算点击
        if HitTest(sx, sy, hitName, hitElem, hitIsSlider,
                   hitMinV, hitMaxV, hitIsVert) and
           SameText(hitName, clickedType) then
          FireButtonClick(clickedType, X, Y)
        else
        begin
          RenderFrame;
          Invalidate;
        end;
      end;
    end;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TEqualizerForm.MouseLeave;
begin
  if (FHoveredType <> '') or (FPressedType <> '') then
  begin
    FHoveredType := '';
    FPressedType := '';
    RenderFrame;
    Invalidate;
  end;
  inherited MouseLeave;
end;

procedure TEqualizerForm.WMNCHitTest(var Msg: TLMessage);
var
  pt: TPoint;
  hitName: string;
  hitElem: TSkinElement;
  hitIsSlider: Boolean;
  hitMinV, hitMaxV: Double;
  hitIsVert: Boolean;
  sw, sh: Integer;
begin
  SkinSize(sw, sh);
  pt := NcHitToSkin(Self, Msg, sw, sh);

  if HitTest(pt.X, pt.Y, hitName, hitElem, hitIsSlider,
             hitMinV, hitMaxV, hitIsVert) then
  begin
    if hitIsSlider and (not FEqEnabled) and IsGatedEqSlider(hitName) then
      Msg.Result := HTCAPTION
    else
      Msg.Result := HTCLIENT;
  end
  else
    Msg.Result := HTCAPTION;
end;

end.
