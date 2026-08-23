unit UPlayerForm;

{$mode objfpc}{$H+}

// 主播放器窗口，对应 Qt 版 src/ui/PlayerWindow。
// 无边框自绘，通过色键生成 Windows Region 实现异形窗口。
// 绘制由 USkinRender 离屏合成，直接贴到 LCL Canvas（BGRABitmap.Draw）。
// 拖动通过 WMNCHitTest 返回 HTCAPTION 实现，由系统处理。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, LCLIntf, LCLType, LMessages,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UPlayerBackend, UVisualWidget;

type
  TPlayerForm = class(TForm)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;

    // 应用皮肤数据；换肤时调用，重建 Region 并刷新。
    procedure ApplySkin(const ASkin: TSkinData);

    // 切换辅助窗口按钮的切换状态（lyric/equalizer/playlist）。
    procedure SetAuxToggle(const AType: string; AToggled: Boolean);

  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseLeave; override;

    // 拖动：背景区域返回 HTCAPTION，让系统处理窗口移动。
    procedure WMNCHitTest(var Msg: TLMessage); message LM_NCHITTEST;

  private
    FSkin: ^TSkinData;         // 指向外部持有的皮肤数据
    FBackend: IPlayerBackend;
    FFrame: TBGRABitmap;       // 离屏合成缓冲
    FVisual: TVisualWidget;    // 频谱/示波图子控件

    // 当前交互状态
    FHoveredType: string;      // 悬停的元素类型（''=无）
    FPressedType: string;      // 按下的元素类型（''=无）
    FToggled: array of record  // 切换按钮状态（lyric/equalizer/playlist/mute/ontop）
      ElemType: string;
      Value: Boolean;
    end;

    procedure BuildRegion;
    procedure RenderFrame;
    function  HitElement(X, Y: Integer): PSkinElement;
    function  IsButtonType(const AType: string): Boolean;
    function  IsToggleButton(const AType: string): Boolean;
    function  GetToggled(const AType: string): Boolean;
    procedure SetToggled(const AType: string; AValue: Boolean);
    procedure FireButtonClick(const AType: string);
  end;

implementation

uses
  LCLProc, Math;

{ TPlayerForm }

constructor TPlayerForm.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  inherited CreateNew(AOwner);

  FSkin    := nil;
  FBackend := ABackend;
  FFrame   := nil;

  // 无边框、无标题栏、可置顶
  BorderStyle := bsNone;
  FormStyle   := fsNormal;
  Color       := clBlack;
  Caption     := 'Player';

  // 频谱子控件（在 visual 元素区域内动画）
  FVisual := TVisualWidget.Create(Self, ABackend);
  FVisual.Parent := Self;
  FVisual.Visible := False;  // ApplySkin 后按 visual 元素存在与否决定

  MouseLeave;
end;

destructor TPlayerForm.Destroy;
begin
  FFrame.Free;
  inherited Destroy;
end;

procedure TPlayerForm.ApplySkin(const ASkin: TSkinData);
var
  visualElem: PSkinElement;
begin
  FSkin := @ASkin;

  if (ASkin.PlayerWindow.BackgroundPixmap <> nil) then
  begin
    SetBounds(Left, Top,
      ASkin.PlayerWindow.BackgroundPixmap.Width,
      ASkin.PlayerWindow.BackgroundPixmap.Height);
  end;

  // 重建异形 Region
  if HandleAllocated then
    BuildRegion;

  // 重建离屏缓冲
  FreeAndNil(FFrame);
  RenderFrame;

  // 定位频谱子控件到 visual 元素区域
  visualElem := ASkin.PlayerWindow.FindElement('visual');
  if (visualElem <> nil) and (not visualElem^.Position.IsEmpty) then
  begin
    FVisual.SetVisualRect(visualElem^.Position);
    FVisual.ApplyConfig(ASkin.VisualConfig);
    FVisual.Visible := True;
    FVisual.Mode    := vmSpectrum;
  end
  else
    FVisual.Visible := False;

  Invalidate;
end;

// 从背景位图的透明色（已被 LoadAndProcess 替换为 alpha=0）生成 HRGN。
// 用 run-length 行区段合并成矩形列表，再用 CombineRgn(RGN_OR) 合并。
procedure TPlayerForm.BuildRegion;
var
  bmp: TBGRABitmap;
  totalRgn, rowRgn, segRgn: HRGN;
  x, y, startX, w, h: Integer;
  p: PBGRAPixel;
begin
  if FSkin = nil then Exit;
  bmp := FSkin^.PlayerWindow.BackgroundPixmap;
  if bmp = nil then Exit;

  w := bmp.Width;
  h := bmp.Height;

  totalRgn := CreateRectRgn(0, 0, 0, 0);  // 空 region 作初始累加器

  for y := 0 to h - 1 do
  begin
    p := bmp.ScanLine[y];
    startX := -1;
    for x := 0 to w - 1 do
    begin
      if p^.alpha > 0 then
      begin
        if startX < 0 then startX := x;
      end
      else
      begin
        if startX >= 0 then
        begin
          segRgn := CreateRectRgn(startX, y, x, y + 1);
          rowRgn := CreateRectRgn(0, 0, 0, 0);
          CombineRgn(rowRgn, totalRgn, segRgn, RGN_OR);
          DeleteObject(totalRgn);
          DeleteObject(segRgn);
          totalRgn := rowRgn;
          startX := -1;
        end;
      end;
      Inc(p);
    end;
    // 行末未关闭的区段
    if startX >= 0 then
    begin
      segRgn := CreateRectRgn(startX, y, w, y + 1);
      rowRgn := CreateRectRgn(0, 0, 0, 0);
      CombineRgn(rowRgn, totalRgn, segRgn, RGN_OR);
      DeleteObject(totalRgn);
      DeleteObject(segRgn);
      totalRgn := rowRgn;
    end;
  end;

  // SetWindowRgn 之后 hRgn 的所有权归系统，无需自行释放
  SetWindowRgn(Handle, totalRgn, True);
end;

// 离屏合成当前帧到 FFrame。
procedure TPlayerForm.RenderFrame;
var
  overrideType: string;
  overrideState: TButtonVisualState;
  toggledMute: Boolean;
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

  toggledMute := GetToggled('mute');

  FFrame := RenderPlayerWindow(FSkin^,
    0, 100,              // 进度/音量默认值（后续接入 Backend）
    overrideType, overrideState, toggledMute);
end;

procedure TPlayerForm.Paint;
begin
  if FFrame = nil then Exit;
  FFrame.Draw(Canvas, 0, 0, True);
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
      if (Position.X <= X) and (X < Position.X + Position.W) and
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
  Result := SameText(AType, 'mute') or SameText(AType, 'lyric') or
            SameText(AType, 'equalizer') or SameText(AType, 'playlist') or
            SameText(AType, 'ontop');
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

procedure TPlayerForm.FireButtonClick(const AType: string);
begin
  // 切换按钮：翻转状态
  if IsToggleButton(AType) then
    SetToggled(AType, not GetToggled(AType));

  // 特殊操作（后续接入 Backend）
  if SameText(AType, 'play') or SameText(AType, 'pause') then
  begin
    if FBackend <> nil then
    begin
      if FBackend.GetState = psPlaying then
        FBackend.Pause
      else
        FBackend.Play;
    end;
  end
  else if SameText(AType, 'stop') then
  begin
    if FBackend <> nil then FBackend.Stop;
  end
  else if SameText(AType, 'minimize') then
    WindowState := wsMinimized
  else if SameText(AType, 'exit') then
    Close;
end;

procedure TPlayerForm.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  elem: PSkinElement;
  newHover: string;
begin
  elem := HitElement(X, Y);
  if (elem <> nil) and IsButtonType(elem^.ElementType) then
    newHover := elem^.ElementType
  else
    newHover := '';

  if newHover <> FHoveredType then
  begin
    FHoveredType := newHover;
    RenderFrame;
    Invalidate;
  end;
  inherited MouseMove(Shift, X, Y);
end;

procedure TPlayerForm.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  elem: PSkinElement;
begin
  if Button = mbLeft then
  begin
    elem := HitElement(X, Y);
    if (elem <> nil) and IsButtonType(elem^.ElementType) then
    begin
      FPressedType := elem^.ElementType;
      RenderFrame;
      Invalidate;
    end;
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TPlayerForm.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  elem: PSkinElement;
  clickedType: string;
begin
  if Button = mbLeft then
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

    RenderFrame;
    Invalidate;
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

// 拖动实现：背景区域（无命中按钮）返回 HTCAPTION，
// 系统将后续鼠标事件解释为标题栏拖动（无需 ReleaseCapture）。
// 按钮区域返回 HTCLIENT，LCL 继续分发 MouseDown/Up 事件。
procedure TPlayerForm.WMNCHitTest(var Msg: TLMessage);
var
  pt: TPoint;
  elem: PSkinElement;
begin
  pt := ScreenToClient(Point(
    SmallInt(Msg.LParam and $FFFF),
    SmallInt((Msg.LParam shr 16) and $FFFF)));

  elem := HitElement(pt.X, pt.Y);
  if (elem <> nil) and IsButtonType(elem^.ElementType) then
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

end.
