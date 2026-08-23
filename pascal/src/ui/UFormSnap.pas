unit UFormSnap;

{$mode objfpc}{$H+}

// LCL 窗口与 TWindowSnapManager 的桥：
//   TFormSnapWindow  — ISnapWindow 适配 TForm.Left/Top/Width/Height
//   TSnapFormAdapter — 截获 WM_ENTERSIZEMOVE / WM_MOVE / WM_EXITSIZEMOVE
//                      （HTCAPTION 系统拖动），转发给吸附管理器
//
// GTK3 上这些 Windows 消息不会到达，平台层（src/ui/platform）后续再补。

interface

uses
  Classes, SysUtils, Forms, Controls, LCLType, LMessages,
  UWindowSnapMath, UWindowSnapManager;

type
  TFormSnapWindow = class(TInterfacedObject, ISnapWindow)
  private
    FForm: TForm;
  public
    constructor Create(AForm: TForm);
    function GetBounds: TSnapRect;
    procedure MoveTo(AX, AY: Integer);
    procedure ResizeTo(AW, AH: Integer);
    function GetVisible: Boolean;
    procedure SetVisible(AValue: Boolean);
    function GetName: string;
  end;

  TSnapFormAdapter = class(TComponent)
  private
    FForm: TForm;
    FManager: TWindowSnapManager;
    FWin: ISnapWindow;
    FIsMain: Boolean;
    FOldProc: TWndMethod;
    FPrevShow: TNotifyEvent;
    FPrevHide: TNotifyEvent;
    FLastX, FLastY: Integer;
    procedure WndProc(var Msg: TLMessage);
    procedure HandleShow(Sender: TObject);
    procedure HandleHide(Sender: TObject);
    procedure UpdateScreenRect;
  public
    constructor Create(AForm: TForm; AManager: TWindowSnapManager;
      AWin: ISnapWindow; AIsMain: Boolean); reintroduce;
    destructor Destroy; override;
  end;

function HookSnapWindow(AForm: TForm; AManager: TWindowSnapManager;
  AIsMain: Boolean): ISnapWindow;

function ResizeEdgesOf(RightEdge, BottomEdge: Boolean): TSnapEdges;

implementation

const
  WM_ENTERSIZEMOVE = $0231;
  WM_EXITSIZEMOVE  = $0232;

{ TFormSnapWindow }

constructor TFormSnapWindow.Create(AForm: TForm);
begin
  inherited Create;
  FForm := AForm;
end;

function TFormSnapWindow.GetBounds: TSnapRect;
begin
  Result := SnapRectXYWH(FForm.Left, FForm.Top, FForm.Width, FForm.Height);
end;

procedure TFormSnapWindow.MoveTo(AX, AY: Integer);
begin
  if (FForm.Left <> AX) or (FForm.Top <> AY) then
    FForm.SetBounds(AX, AY, FForm.Width, FForm.Height);
end;

procedure TFormSnapWindow.ResizeTo(AW, AH: Integer);
begin
  if (FForm.Width <> AW) or (FForm.Height <> AH) then
    FForm.SetBounds(FForm.Left, FForm.Top, AW, AH);
end;

function TFormSnapWindow.GetVisible: Boolean;
begin
  Result := FForm.Visible;
end;

procedure TFormSnapWindow.SetVisible(AValue: Boolean);
begin
  FForm.Visible := AValue;
end;

function TFormSnapWindow.GetName: string;
begin
  Result := FForm.Caption;
  if Result = '' then
    Result := FForm.ClassName;
end;

{ TSnapFormAdapter }

constructor TSnapFormAdapter.Create(AForm: TForm; AManager: TWindowSnapManager;
  AWin: ISnapWindow; AIsMain: Boolean);
begin
  inherited Create(AForm);
  FForm := AForm;
  FManager := AManager;
  FWin := AWin;
  FIsMain := AIsMain;
  FLastX := AForm.Left;
  FLastY := AForm.Top;
  FOldProc := AForm.WindowProc;
  AForm.WindowProc := @WndProc;
  FPrevShow := AForm.OnShow;
  FPrevHide := AForm.OnHide;
  AForm.OnShow := @HandleShow;
  AForm.OnHide := @HandleHide;
  UpdateScreenRect;
end;

destructor TSnapFormAdapter.Destroy;
begin
  if Assigned(FForm) then
  begin
    if Assigned(FOldProc) then
      FForm.WindowProc := FOldProc;
    FForm.OnShow := FPrevShow;
    FForm.OnHide := FPrevHide;
  end;
  FWin := nil;
  inherited Destroy;
end;

procedure TSnapFormAdapter.UpdateScreenRect;
var
  r: TRect;
  m: TMonitor;
begin
  if (FForm = nil) or (FManager = nil) then Exit;
  m := FForm.Monitor;
  if m <> nil then
    r := m.WorkareaRect
  else
    r := Screen.WorkAreaRect;
  FManager.ScreenRect := SnapRectXYWH(r.Left, r.Top,
    r.Right - r.Left, r.Bottom - r.Top);
end;

procedure TSnapFormAdapter.HandleShow(Sender: TObject);
begin
  if Assigned(FPrevShow) then
    FPrevShow(Sender);
  UpdateScreenRect;
  if FManager <> nil then
    FManager.RebuildSnapGraph;
end;

procedure TSnapFormAdapter.HandleHide(Sender: TObject);
begin
  if Assigned(FPrevHide) then
    FPrevHide(Sender);
  if FManager <> nil then
    FManager.RebuildSnapGraph;
end;

procedure TSnapFormAdapter.WndProc(var Msg: TLMessage);
var
  dx, dy: Integer;
  isMove, isEnter, isExit: Boolean;
begin
  isEnter := Msg.Msg = WM_ENTERSIZEMOVE;
  isExit  := Msg.Msg = WM_EXITSIZEMOVE;
  isMove  := Msg.Msg = LM_MOVE;

  if isEnter then
  begin
    FLastX := FForm.Left;
    FLastY := FForm.Top;
    UpdateScreenRect;
    FManager.OnDragStarted(FWin);
  end;

  FOldProc(Msg);

  if isMove then
  begin
    dx := FForm.Left - FLastX;
    dy := FForm.Top - FLastY;
    if (dx <> 0) or (dy <> 0) then
    begin
      FLastX := FForm.Left;
      FLastY := FForm.Top;
      if FIsMain then
        FManager.OnMainMoved(dx, dy)
      else
        FManager.OnSubMoved(FWin, dx, dy);
    end;
  end
  else if isExit then
  begin
    FManager.OnDragFinished(FWin);
    FLastX := FForm.Left;
    FLastY := FForm.Top;
  end;
end;

function HookSnapWindow(AForm: TForm; AManager: TWindowSnapManager;
  AIsMain: Boolean): ISnapWindow;
begin
  Result := TFormSnapWindow.Create(AForm);
  if AIsMain then
    AManager.SetMainWindow(Result)
  else
    AManager.AddSubWindow(Result);
  TSnapFormAdapter.Create(AForm, AManager, Result, AIsMain);
end;

function ResizeEdgesOf(RightEdge, BottomEdge: Boolean): TSnapEdges;
begin
  Result := [];
  if RightEdge then Include(Result, seRight);
  if BottomEdge then Include(Result, seBottom);
end;

end.
