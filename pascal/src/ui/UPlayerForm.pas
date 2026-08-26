unit UPlayerForm;

{$mode objfpc}{$H+}

// 主播放器窗口，对应 Qt 版 src/ui/PlayerWindow。
// 无边框自绘，通过色键生成 Windows Region 实现异形窗口。
// 绘制由 USkinRender 离屏合成，直接贴到 LCL Canvas（BGRABitmap.Draw）。
// 拖动：Windows 上 WMNCHitTest=HTCAPTION 由系统处理；GTK3 走 TryBeginCaptionDrag。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, ExtCtrls,
  LCLIntf, LCLType, LMessages,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UPlayerBackend, UVisualWidget, UPlatformWindow,
  USkinView;

type
  TAuxToggleEvent = procedure(Sender: TObject; const AType: string;
    AToggled: Boolean) of object;

  TPlayerForm = class(TForm, ISkinViewForm)
  public
    constructor Create(AOwner: TComponent); override; overload;
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); overload;
    destructor Destroy; override;
    procedure AttachBackend(ABackend: IPlayerBackend);

    // 应用皮肤数据；换肤时调用，重建 Region 并刷新。
    // ASkin 必须指向引擎持有的 TSkinData（TSkinEngine.SkinPtr），不能是副本。
    procedure ApplySkin(ASkin: PSkinData);
    procedure RefreshViewScale;

    // 切换辅助窗口按钮的切换状态（lyric/equalizer/playlist）。
    procedure SetAuxToggle(const AType: string; AToggled: Boolean);
    procedure SetAlwaysOnTopState(AEnabled: Boolean);
    function AlwaysOnTopState: Boolean;

  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure CreateWnd; override;
    procedure DoShow; override;
    procedure DoContextPopup(MousePos: TPoint; var Handled: Boolean); override;

    // 拖动：背景区域返回 HTCAPTION（Win 系统拖动 / GTK3 TryBeginCaptionDrag）。
    procedure WMNCHitTest(var Msg: TLMessage); message LM_NCHITTEST;

  private
    FSkin: PSkinData;          // 指向引擎持有的皮肤数据
    FBackend: IPlayerBackend;
    FFrame: TBGRABitmap;       // 离屏合成缓冲
    FVisual: TVisualWidget;    // 频谱/示波图子控件
    FVisualMode: TVisualMode;
    FCoverBmp: TBGRABitmap;
    FCoverBytes: TBytes;

    // 当前交互状态
    FHoveredType: string;      // 悬停的元素类型（''=无）
    FPressedType: string;      // 按下的元素类型（''=无）
    FToggled: array of record  // 切换按钮状态（lyric/equalizer/playlist/mute/ontop）
      ElemType: string;
      Value: Boolean;
    end;
    FOnAuxToggle: TAuxToggleEvent;
    FOnPrev: TNotifyEvent;
    FOnNext: TNotifyEvent;
    FOnOpen: TNotifyEvent;
    FOnPlay: TNotifyEvent;
    FOnContextMenu: TNotifyEvent;
    FSkipContextPopup: Boolean;

    FUiTimer: TTimer;
    FDragKind: string;       // 'progress' / 'volume' / ''
    FDragValue: Double;
    FMouseCaptured: Boolean;

    procedure BuildRegion;
    procedure RenderFrame;
    procedure SkinSize(out W, H: Integer);
    procedure MapHit(var X, Y: Integer);
    function  HitElement(X, Y: Integer): PSkinElement;
    function  IsButtonType(const AType: string): Boolean;
    function  IsToggleButton(const AType: string): Boolean;
    function  GetToggled(const AType: string): Boolean;
    procedure SetToggled(const AType: string; AValue: Boolean);
    procedure FireButtonClick(const AType: string);
    function  IsPlaying: Boolean;
    function  IsSliderType(const AType: string): Boolean;
    function  ElementInteractive(const AType: string): Boolean;
    procedure ApplySlider(const Kind: string; X, Y: Integer);
    procedure HandleStateChanged(Sender: TObject; NewState: TPlayerState);
    procedure HandlePositionChanged(Sender: TObject; PositionMs: Int64);
    procedure HandleVisualClicked(Sender: TObject);
    procedure OnUiTick(Sender: TObject);
    procedure UnhookBackend;
    procedure InitPlayerForm;
    procedure HandleFormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure RefreshFrame;
    procedure CycleVisualMode;
    procedure ApplyVisualMode;
    procedure SyncCover;
    function CurrentInfoText: string;
  public
    // lyric / equalizer / playlist 点击后通知宿主显示或隐藏对应窗口。
    property OnAuxToggle: TAuxToggleEvent read FOnAuxToggle write FOnAuxToggle;
    property OnPrev: TNotifyEvent read FOnPrev write FOnPrev;
    property OnNext: TNotifyEvent read FOnNext write FOnNext;
    property OnOpen: TNotifyEvent read FOnOpen write FOnOpen;
    // 非 Playing 时点 play：宿主决定恢复 / 播列表当前项 / 打开文件。
    property OnPlay: TNotifyEvent read FOnPlay write FOnPlay;
    property OnContextMenu: TNotifyEvent read FOnContextMenu write FOnContextMenu;
  end;

implementation

uses
  LCLProc, UFormSnap;

{ TPlayerForm }

constructor TPlayerForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  InitPlayerForm;
end;

constructor TPlayerForm.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  Create(AOwner);
  AttachBackend(ABackend);
end;

procedure TPlayerForm.InitPlayerForm;
begin
  FSkin    := nil;
  FBackend := nil;
  FFrame   := nil;
  FDragKind := '';
  FMouseCaptured := False;
  FVisualMode := vmSpectrum;
  FCoverBmp := nil;

  // 无边框、无标题栏。必须出现在任务栏：LCL 默认 MainFormOnTaskBar=False，
  // 且 Create() 不会把窗体注册成 MainForm，结果是 WS_POPUP owned 窗口，没有按钮。
  BorderStyle := bsNone;
  FormStyle   := fsNormal;
  Color       := clBlack;
  Caption     := 'TTPlayer';
  ShowInTaskBar := stAlways;
  OnClose := @HandleFormClose;

  FVisual := TVisualWidget.Create(Self, nil);
  FVisual.Parent := Self;
  FVisual.Visible := False;
  FVisual.OnClicked := @HandleVisualClicked;

  FUiTimer := TTimer.Create(Self);
  FUiTimer.Enabled := False;
  FUiTimer.Interval := 100;
  FUiTimer.OnTimer := @OnUiTick;

  MouseLeave;
end;

procedure TPlayerForm.AttachBackend(ABackend: IPlayerBackend);
begin
  UnhookBackend;
  FBackend := ABackend;
  if FVisual <> nil then
    FVisual.AttachBackend(ABackend);
  if FBackend <> nil then
  begin
    FBackend.SetOnStateChanged(@HandleStateChanged);
    FBackend.SetOnPositionChanged(@HandlePositionChanged);
  end;
end;

procedure TPlayerForm.HandleFormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if Sender = nil then ;
  // 关主播放器 = 退出进程。caHide 让宿主 Destroy 里还能读几何并写 TTPlayer.xml。
  CloseAction := caHide;
  if (Application.MainForm = Self) or (Application.MainForm = nil) then
    Application.Terminate;
end;

destructor TPlayerForm.Destroy;
begin
  UnhookBackend;
  if FVisual <> nil then
    FVisual.SetSkinBackground(nil);
  FreeAndNil(FCoverBmp);
  FFrame.Free;
  inherited Destroy;
end;

procedure TPlayerForm.ApplySkin(ASkin: PSkinData);
var
  visualElem: PSkinElement;
begin
  if ASkin = nil then Exit;
  FSkin := ASkin;
  ConfigurePlatformWindow(Self);

  // 先清 Region，否则 SetWindowRgn 会卡住后续 SetBounds。
  if HandleAllocated then
    ClearWindowShape(Handle);

  if (ASkin^.PlayerWindow.BackgroundPixmap <> nil) then
    ApplySkinFormSize(Self,
      ASkin^.PlayerWindow.BackgroundPixmap.Width,
      ASkin^.PlayerWindow.BackgroundPixmap.Height);

  // 重建异形 Region
  if HandleAllocated then
    BuildRegion;

  // 重建离屏缓冲
  FreeAndNil(FFrame);
  RenderFrame;

  // 定位频谱子控件到 visual 元素区域
  visualElem := ASkin^.PlayerWindow.FindElement('visual');
  if (visualElem <> nil) and (not visualElem^.Position.IsEmpty) then
  begin
    FVisual.SetVisualRect(visualElem^.Position);
    FVisual.ApplyConfig(ASkin^.VisualConfig);
  end;
  ApplyVisualMode;
  if FVisual <> nil then
    FVisual.SetSkinBackground(FFrame);

  Invalidate;
  if HandleAllocated then
    Update;
end;

procedure TPlayerForm.BuildRegion;
var
  bmp: TBGRABitmap;
begin
  if (FSkin = nil) or (not HandleAllocated) then Exit;
  bmp := FSkin^.PlayerWindow.BackgroundPixmap;
  if bmp = nil then Exit;
  ApplyAlphaShape(Handle, bmp);
end;

procedure TPlayerForm.SkinSize(out W, H: Integer);
var
  bmp: TBGRABitmap;
begin
  W := Width;
  H := Height;
  if FSkin = nil then Exit;
  bmp := FSkin^.PlayerWindow.BackgroundPixmap;
  if bmp = nil then Exit;
  W := bmp.Width;
  H := bmp.Height;
end;

procedure TPlayerForm.MapHit(var X, Y: Integer);
var
  sw, sh: Integer;
begin
  SkinSize(sw, sh);
  ClientToSkinXY(Self, sw, sh, X, Y);
end;

procedure TPlayerForm.RefreshViewScale;
var
  visualElem: PSkinElement;
  sw, sh: Integer;
begin
  if FSkin = nil then Exit;
  SkinSize(sw, sh);
  ApplySkinFormSize(Self, sw, sh);
  if HandleAllocated then
    BuildRegion;
  visualElem := FSkin^.PlayerWindow.FindElement('visual');
  if (visualElem <> nil) and (not visualElem^.Position.IsEmpty) and
     (FVisual <> nil) then
  begin
    FVisual.SetVisualRect(visualElem^.Position);
    FVisual.SetSkinBackground(FFrame);
  end;
  ApplyVisualMode;
  Invalidate;
end;

procedure TPlayerForm.CreateWnd;
begin
  inherited CreateWnd;
  ConfigurePlatformWindow(Self);
  RefreshViewScale;
end;

procedure TPlayerForm.DoShow;
begin
  inherited DoShow;
  ConfigurePlatformWindow(Self);
  RefreshViewScale;
  BuildRegion;
end;

procedure TPlayerForm.RefreshFrame;
begin
  RenderFrame;
  Invalidate;
end;

procedure TPlayerForm.UnhookBackend;
begin
  if FBackend = nil then Exit;
  FBackend.SetOnStateChanged(nil);
  FBackend.SetOnPositionChanged(nil);
end;

procedure TPlayerForm.HandleStateChanged(Sender: TObject; NewState: TPlayerState);
begin
  if Sender = nil then ;
  if FUiTimer <> nil then
    FUiTimer.Enabled := NewState = psPlaying;
  RefreshFrame;
end;

procedure TPlayerForm.HandlePositionChanged(Sender: TObject; PositionMs: Int64);
begin
  if Sender = nil then ;
  if PositionMs < 0 then ;
  if FDragKind = 'progress' then Exit;
  RefreshFrame;
end;

procedure TPlayerForm.OnUiTick(Sender: TObject);
begin
  if Sender = nil then ;
  if FDragKind = 'progress' then Exit;
  RefreshFrame;
end;

function TPlayerForm.IsPlaying: Boolean;
begin
  Result := (FBackend <> nil) and (FBackend.GetState = psPlaying);
end;

procedure TPlayerForm.ApplyVisualMode;
var
  visualElem: PSkinElement;
  hasVisual: Boolean;
begin
  if FVisual = nil then Exit;
  hasVisual := False;
  if FSkin <> nil then
  begin
    visualElem := FSkin^.PlayerWindow.FindElement('visual');
    hasVisual := (visualElem <> nil) and (not visualElem^.Position.IsEmpty);
  end;
  if not hasVisual then
  begin
    FVisual.SetVisualVisible(False);
    Exit;
  end;
  case FVisualMode of
    vmSpectrum:
      begin
        FVisual.Mode := vmSpectrum;
        FVisual.SetVisualVisible(True);
      end;
    vmBlurScope:
      begin
        FVisual.Mode := vmBlurScope;
        FVisual.SetVisualVisible(True);
      end;
  else
    FVisual.SetVisualVisible(False);
  end;
end;

procedure TPlayerForm.CycleVisualMode;
begin
  FVisualMode := TVisualMode((Ord(FVisualMode) + 1) mod 4);
  ApplyVisualMode;
  if FVisualMode = vmCover then
    SyncCover;
  RefreshFrame;
end;

procedure TPlayerForm.HandleVisualClicked(Sender: TObject);
begin
  if Sender = nil then ;
  CycleVisualMode;
end;

procedure TPlayerForm.SyncCover;
var
  bytes: TBytes;
  ms: TMemoryStream;
begin
  if FBackend = nil then
  begin
    FreeAndNil(FCoverBmp);
    SetLength(FCoverBytes, 0);
    Exit;
  end;
  bytes := FBackend.GetCoverArt;
  if (Length(bytes) = Length(FCoverBytes)) and
     ((Length(bytes) = 0) or CompareMem(@bytes[0], @FCoverBytes[0], Length(bytes))) then
    Exit;
  FCoverBytes := bytes;
  FreeAndNil(FCoverBmp);
  if Length(bytes) = 0 then
    Exit;
  ms := TMemoryStream.Create;
  try
    ms.WriteBuffer(bytes[0], Length(bytes));
    ms.Position := 0;
    FCoverBmp := TBGRABitmap.Create;
    try
      FCoverBmp.LoadFromStream(ms);
    except
      FreeAndNil(FCoverBmp);
    end;
  finally
    ms.Free;
  end;
end;

function TPlayerForm.CurrentInfoText: string;
var
  title, artist: string;
begin
  Result := '';
  if FBackend = nil then
    Exit;
  title := FBackend.GetTitle;
  artist := FBackend.GetArtist;
  if (title = '') and (artist = '') then
  begin
    if FBackend.GetState = psIdle then
      Exit('');
    Result := 'TTPlayer Reborn';
  end
  else if artist = '' then
    Result := title
  else if title = '' then
    Result := artist
  else
    Result := artist + ' - ' + title;
end;

function TPlayerForm.IsSliderType(const AType: string): Boolean;
begin
  Result := SameText(AType, 'progress') or SameText(AType, 'volume');
end;

function TPlayerForm.ElementInteractive(const AType: string): Boolean;
begin
  if SameText(AType, 'play') then
    Exit(not IsPlaying);
  if SameText(AType, 'pause') then
    Exit(IsPlaying);
  Result := True;
end;

// 离屏合成当前帧到 FFrame。
procedure TPlayerForm.RenderFrame;
var
  overrideType: string;
  overrideState: TButtonVisualState;
  toggledMute: Boolean;
  progress, volume: Double;
  dur, ledMs: Int64;
  info: string;
  showCover: Boolean;
begin
  if FSkin = nil then Exit;

  FreeAndNil(FFrame);

  // 确定 override 状态（悬停/按下最多作用于一个按钮）
  overrideType := '';
  overrideState := bvsNormal;
  if FPressedType <> '' then
  begin
    overrideType  := FPressedType;
    overrideState := bvsPressed;
  end
  else if FHoveredType <> '' then
  begin
    overrideType  := FHoveredType;
    overrideState := bvsHover;
  end;

  progress := 0;
  volume := 100;
  ledMs := 0;
  if (FDragKind = 'progress') then
  begin
    progress := FDragValue;
    if FBackend <> nil then
    begin
      dur := FBackend.GetDurationMs;
      if dur > 0 then
        ledMs := Round(FDragValue * dur);
    end;
  end
  else if FBackend <> nil then
  begin
    dur := FBackend.GetDurationMs;
    ledMs := FBackend.GetPositionMs;
    if dur > 0 then
      progress := ledMs / dur;
  end;

  if FDragKind = 'volume' then
    volume := FDragValue
  else if FBackend <> nil then
    volume := FBackend.GetVolume;

  if FBackend <> nil then
    toggledMute := FBackend.GetIsMuted
  else
    toggledMute := GetToggled('mute');

  info := CurrentInfoText;
  showCover := FVisualMode = vmCover;
  if showCover then
    SyncCover;

  FFrame := RenderPlayerWindow(FSkin^,
    progress, volume,
    overrideType, overrideState, toggledMute,
    IsPlaying, ledMs, info, FCoverBmp, showCover);
  if FVisual <> nil then
    FVisual.SetSkinBackground(FFrame);
end;

procedure TPlayerForm.Paint;
begin
  if FFrame = nil then Exit;
  DrawSkinFrame(Canvas, FFrame, ClientWidth, ClientHeight);
end;

// 元素命中测试：按 position 查找包含 (X,Y) 的元素。
function TPlayerForm.HitElement(X, Y: Integer): PSkinElement;
var
  i: Integer;
begin
  Result := nil;
  if FSkin = nil then Exit;
  for i := 0 to High(FSkin^.PlayerWindow.Elements) do
  begin
    with FSkin^.PlayerWindow.Elements[i] do
      if ElementInteractive(ElementType) and
         (Position.X <= X) and (X < Position.X + Position.W) and
         (Position.Y <= Y) and (Y < Position.Y + Position.H) then
      begin
        Result := @FSkin^.PlayerWindow.Elements[i];
        Exit;
      end;
  end;
end;

function TPlayerForm.IsButtonType(const AType: string): Boolean;
const
  kButtonTypes: array[0..22] of string = (
    'play','pause','stop','prev','next','mute','open','close','exit',
    'lyric','equalizer','playlist','minimize','minimode','enabled',
    'profile','reset','ontop','browser','backward','forward','refresh','startup');
var
  i: Integer;
begin
  for i := 0 to High(kButtonTypes) do
    if SameText(AType, kButtonTypes[i]) then Exit(True);
  Result := False;
end;

function TPlayerForm.IsToggleButton(const AType: string): Boolean;
begin
  Result := SameText(AType, 'lyric') or SameText(AType, 'equalizer') or
            SameText(AType, 'playlist') or SameText(AType, 'ontop');
end;

function TPlayerForm.GetToggled(const AType: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FToggled) do
    if SameText(FToggled[i].ElemType, AType) then
      Exit(FToggled[i].Value);
  Result := False;
end;

procedure TPlayerForm.SetToggled(const AType: string; AValue: Boolean);
var
  i: Integer;
begin
  for i := 0 to High(FToggled) do
    if SameText(FToggled[i].ElemType, AType) then
    begin
      FToggled[i].Value := AValue;
      Exit;
    end;
  SetLength(FToggled, Length(FToggled) + 1);
  FToggled[High(FToggled)].ElemType := AType;
  FToggled[High(FToggled)].Value := AValue;
end;

procedure TPlayerForm.ApplySlider(const Kind: string; X, Y: Integer);
var
  elem: PSkinElement;
  px: Integer;
  v: Double;
  dur: Int64;
  minV, maxV: Double;
begin
  if FSkin = nil then Exit;
  elem := FSkin^.PlayerWindow.FindElement(Kind);
  if elem = nil then Exit;

  if SameText(Kind, 'progress') then
  begin
    minV := 0;
    maxV := 1;
  end
  else
  begin
    minV := 0;
    maxV := 100;
  end;

  if elem^.Vertical then
    px := Y - elem^.Position.Y
  else
    px := X - elem^.Position.X;

  if elem^.Vertical then
    v := SliderPosToValue(px, minV, maxV, elem^.Position.H, True)
  else
    v := SliderPosToValue(px, minV, maxV, elem^.Position.W, False);
  if v < minV then v := minV;
  if v > maxV then v := maxV;
  FDragValue := v;

  if FBackend = nil then Exit;
  if SameText(Kind, 'progress') then
  begin
    dur := FBackend.GetDurationMs;
    if dur > 0 then
      FBackend.Seek(Round(v * dur));
  end
  else if SameText(Kind, 'volume') then
    FBackend.SetVolume(Round(v));
end;

procedure TPlayerForm.FireButtonClick(const AType: string);
var
  posMs: Int64;
begin
  // 切换按钮：翻转状态
  if IsToggleButton(AType) then
  begin
    SetToggled(AType, not GetToggled(AType));
    if Assigned(FOnAuxToggle) and
       (SameText(AType, 'lyric') or SameText(AType, 'equalizer') or
        SameText(AType, 'playlist')) then
      FOnAuxToggle(Self, AType, GetToggled(AType));
    if SameText(AType, 'ontop') then
    begin
      if Assigned(FOnAuxToggle) then
        FOnAuxToggle(Self, AType, GetToggled(AType))
      else
        SetWindowAlwaysOnTop(Self, GetToggled(AType));
    end;
  end;

  if SameText(AType, 'mute') then
  begin
    if FBackend <> nil then
    begin
      FBackend.SetMuted(not FBackend.GetIsMuted);
      SetToggled('mute', FBackend.GetIsMuted);
    end
    else
      SetToggled('mute', not GetToggled('mute'));
  end;

  if SameText(AType, 'play') or SameText(AType, 'pause') then
  begin
    if FBackend <> nil then
    begin
      if FBackend.GetState = psPlaying then
        FBackend.Pause
      else if Assigned(FOnPlay) then
        FOnPlay(Self)
      else
        FBackend.Play;
    end
    else if Assigned(FOnPlay) then
      FOnPlay(Self);
  end
  else if SameText(AType, 'stop') then
  begin
    if FBackend <> nil then FBackend.Stop;
  end
  else if SameText(AType, 'prev') then
  begin
    if Assigned(FOnPrev) then FOnPrev(Self);
  end
  else if SameText(AType, 'next') then
  begin
    if Assigned(FOnNext) then FOnNext(Self);
  end
  else if SameText(AType, 'open') then
  begin
    if Assigned(FOnOpen) then FOnOpen(Self);
  end
  else if SameText(AType, 'backward') then
  begin
    if FBackend <> nil then
    begin
      posMs := FBackend.GetPositionMs - 5000;
      if posMs < 0 then posMs := 0;
      FBackend.Seek(posMs);
    end;
  end
  else if SameText(AType, 'forward') then
  begin
    if FBackend <> nil then
      FBackend.Seek(FBackend.GetPositionMs + 5000);
  end
  else if SameText(AType, 'minimize') then
    WindowState := wsMinimized
  else if SameText(AType, 'close') or SameText(AType, 'exit') then
  begin
    if (Application.MainForm = Self) or (Application.MainForm = nil) then
      Application.Terminate
    else
      Close;
  end;
end;

procedure TPlayerForm.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  elem: PSkinElement;
  newHover: string;
begin
  MapHit(X, Y);
  if FDragKind <> '' then
  begin
    ApplySlider(FDragKind, X, Y);
    RefreshFrame;
  end
  else
  begin
    elem := HitElement(X, Y);
    if (elem <> nil) and IsButtonType(elem^.ElementType) then
      newHover := elem^.ElementType
    else
      newHover := '';

    if newHover <> FHoveredType then
    begin
      FHoveredType := newHover;
      RefreshFrame;
    end;
  end;
  inherited MouseMove(Shift, X, Y);
end;

procedure TPlayerForm.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  elem: PSkinElement;
  sx, sy: Integer;
begin
  sx := X;
  sy := Y;
  MapHit(sx, sy);
  if Button = mbLeft then
  begin
    elem := HitElement(sx, sy);
    if (elem <> nil) and SameText(elem^.ElementType, 'visual') then
    begin
      CycleVisualMode;
      inherited MouseDown(Button, Shift, X, Y);
      Exit;
    end;
    if (elem <> nil) and IsSliderType(elem^.ElementType) then
    begin
      FDragKind := elem^.ElementType;
      ApplySlider(FDragKind, sx, sy);
      SetCapture(Handle);
      FMouseCaptured := True;
      RefreshFrame;
    end
    else if (elem <> nil) and IsButtonType(elem^.ElementType) then
    begin
      FPressedType := elem^.ElementType;
      RefreshFrame;
    end;
  end;
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
    TryBeginCaptionDrag(Self, X, Y)
  else if (Button = mbRight) and Assigned(FOnContextMenu) then
  begin
    FOnContextMenu(Self);
    FSkipContextPopup := True;
  end;
end;

procedure TPlayerForm.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  elem: PSkinElement;
  clickedType: string;
begin
  MapHit(X, Y);
  if Button = mbLeft then
  begin
    if FMouseCaptured then
    begin
      ReleaseCapture;
      FMouseCaptured := False;
    end;

    if FDragKind <> '' then
    begin
      ApplySlider(FDragKind, X, Y);
      FDragKind := '';
    end
    else
    begin
      clickedType := FPressedType;
      FPressedType := '';

      if clickedType <> '' then
      begin
        // 鼠标释放在同一按钮上才算点击
        elem := HitElement(X, Y);
        if (elem <> nil) and SameText(elem^.ElementType, clickedType) then
          FireButtonClick(clickedType);
      end;
    end;

    RefreshFrame;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TPlayerForm.MouseLeave;
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

// 拖动：背景返回 HTCAPTION。Windows 由系统拖动；GTK3 在 MouseDown
// 里 TryBeginCaptionDrag 捕获鼠标并走 OnDragStarted/Finished。
// 按钮区域返回 HTCLIENT，LCL 继续分发 MouseDown/Up。
procedure TPlayerForm.WMNCHitTest(var Msg: TLMessage);
var
  pt: TPoint;
  elem: PSkinElement;
  sw, sh: Integer;
begin
  SkinSize(sw, sh);
  pt := NcHitToSkin(Self, Msg, sw, sh);

  if NcRightButtonDown then
  begin
    Msg.Result := HTCLIENT;
    Exit;
  end;

  elem := HitElement(pt.X, pt.Y);
  if (elem <> nil) and
     (IsButtonType(elem^.ElementType) or IsSliderType(elem^.ElementType) or
      SameText(elem^.ElementType, 'visual')) then
    Msg.Result := HTCLIENT
  else
    Msg.Result := HTCAPTION;
end;

procedure TPlayerForm.SetAuxToggle(const AType: string; AToggled: Boolean);
begin
  SetToggled(AType, AToggled);
  RenderFrame;
  Invalidate;
end;

procedure TPlayerForm.SetAlwaysOnTopState(AEnabled: Boolean);
begin
  SetToggled('ontop', AEnabled);
  SetWindowAlwaysOnTop(Self, AEnabled);
  RenderFrame;
  Invalidate;
end;

function TPlayerForm.AlwaysOnTopState: Boolean;
begin
  Result := GetToggled('ontop');
end;

procedure TPlayerForm.DoContextPopup(MousePos: TPoint; var Handled: Boolean);
begin
  if FSkipContextPopup then
  begin
    FSkipContextPopup := False;
    Handled := True;
    Exit;
  end;
  if Assigned(FOnContextMenu) then
  begin
    if MousePos.X = 0 then ;
    FOnContextMenu(Self);
    Handled := True;
  end
  else
    inherited DoContextPopup(MousePos, Handled);
end;

end.
