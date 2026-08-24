unit UFormSnap;

{$mode objfpc}{$H+}

// LCL 窗口与 TWindowSnapManager 的桥：
//   TFormSnapWindow  — ISnapWindow 适配 TForm；DPI≠100% 时用 GetWindowRect
//                      换算到 LCL 单位，MoveTo 再用 SetWindowPos 写回物理像素
//   TSnapFormAdapter — 截获拖动：Windows 上子类化原生 WndProc 收取
//                      WM_ENTERSIZEMOVE / WM_EXITSIZEMOVE（LCL WindowProc
//                      收不到跨进程 SendMessage 的这两条）；LM_MOVE 仍走 LCL
//
// GTK3 上这些 Windows 消息不会到达，平台层（src/ui/platform）后续再补。

interface

uses
  Classes, SysUtils, Forms, Controls, LCLType, LCLIntf, LMessages, Types,
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
    FNativeHooked: Boolean;
    FHookedWnd: HWND;
    FOrigWndProc: PtrUInt;
    procedure WndProc(var Msg: TLMessage);
    procedure HandleShow(Sender: TObject);
    procedure HandleHide(Sender: TObject);
    procedure UpdateScreenRect;
    procedure HandleEnterSizeMove;
    procedure HandleExitSizeMove;
    procedure InstallNativeHook;
    procedure RemoveNativeHook;
  public
    constructor Create(AForm: TForm; AManager: TWindowSnapManager;
      AWin: ISnapWindow; AIsMain: Boolean); reintroduce;
    destructor Destroy; override;
  end;

function HookSnapWindow(AForm: TForm; AManager: TWindowSnapManager;
  AIsMain: Boolean): ISnapWindow;

function ResizeEdgesOf(RightEdge, BottomEdge: Boolean): TSnapEdges;

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

const
  WM_ENTERSIZEMOVE = $0231;
  WM_EXITSIZEMOVE  = $0232;
  SNAP_PROP_NAME   = 'TTPSnapAdpt';

{$IFDEF WINDOWS}
function SnapNativeWndProc(Wnd: HWND; uMsg: UINT; wParam: WPARAM;
  lParam: LPARAM): LRESULT; stdcall; forward;
{$ENDIF}

{ TFormSnapWindow }

constructor TFormSnapWindow.Create(AForm: TForm);
begin
  inherited Create;
  FForm := AForm;
end;

function TFormSnapWindow.GetBounds: TSnapRect;
var
  wr: TRect;
  pw, ph: Integer;
begin
  Result := SnapRectXYWH(FForm.Left, FForm.Top, FForm.Width, FForm.Height);
  if (FForm = nil) or (not FForm.HandleAllocated) then Exit;
  wr := Types.Rect(0, 0, 0, 0);
  if LCLIntf.GetWindowRect(FForm.Handle, wr) = 0 then Exit;
  pw := wr.Right - wr.Left;
  ph := wr.Bottom - wr.Top;
  if (pw <= 0) or (ph <= 0) or (FForm.Width <= 0) or (FForm.Height <= 0) then
    Exit;
  // DPI≠100% 时 Win32 矩形是物理像素，LCL Left/Width 是 96dpi。
  // 用实际窗口位置换算到 LCL 单位，这样外部 SetWindowPos 也能参与吸附。
  Result.X := Round(wr.Left * FForm.Width / pw);
  Result.Y := Round(wr.Top * FForm.Height / ph);
  Result.W := FForm.Width;
  Result.H := FForm.Height;
end;

procedure TFormSnapWindow.MoveTo(AX, AY: Integer);
var
  wr: TRect;
  pw, ph, physX, physY: Integer;
begin
  if FForm = nil then Exit;
  if (FForm.Left <> AX) or (FForm.Top <> AY) then
    FForm.SetBounds(AX, AY, FForm.Width, FForm.Height);
  {$IFDEF WINDOWS}
  if not FForm.HandleAllocated then Exit;
  wr := Types.Rect(0, 0, 0, 0);
  if LCLIntf.GetWindowRect(FForm.Handle, wr) = 0 then Exit;
  pw := wr.Right - wr.Left;
  ph := wr.Bottom - wr.Top;
  if (pw <= 0) or (ph <= 0) or (FForm.Width <= 0) or (FForm.Height <= 0) then
    Exit;
  physX := Round(AX * pw / FForm.Width);
  physY := Round(AY * ph / FForm.Height);
  if (wr.Left <> physX) or (wr.Top <> physY) then
    Windows.SetWindowPos(FForm.Handle, 0, physX, physY, 0, 0,
      SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
  {$ENDIF}
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
  InstallNativeHook;
end;

destructor TSnapFormAdapter.Destroy;
begin
  RemoveNativeHook;
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

procedure TSnapFormAdapter.HandleEnterSizeMove;
var
  b: TSnapRect;
begin
  if FManager = nil then Exit;
  b := FWin.GetBounds;
  FLastX := b.X;
  FLastY := b.Y;
  UpdateScreenRect;
  FManager.OnDragStarted(FWin);
end;

procedure TSnapFormAdapter.HandleExitSizeMove;
var
  b: TSnapRect;
begin
  if FManager = nil then Exit;
  FManager.OnDragFinished(FWin);
  b := FWin.GetBounds;
  FLastX := b.X;
  FLastY := b.Y;
end;

procedure TSnapFormAdapter.InstallNativeHook;
{$IFDEF WINDOWS}
var
  wnd: HWND;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  if FForm = nil then Exit;
  if not FForm.HandleAllocated then Exit;
  wnd := FForm.Handle;
  if FNativeHooked and (FHookedWnd = wnd) then Exit;
  if FNativeHooked then
    RemoveNativeHook;
  Windows.SetProp(wnd, SNAP_PROP_NAME, THandle(PtrUInt(Self)));
  FOrigWndProc := PtrUInt(SetWindowLongPtr(wnd, GWL_WNDPROC,
    LONG_PTR(@SnapNativeWndProc)));
  FNativeHooked := FOrigWndProc <> 0;
  if FNativeHooked then
    FHookedWnd := wnd
  else
    Windows.RemoveProp(wnd, SNAP_PROP_NAME);
  {$ENDIF}
end;

procedure TSnapFormAdapter.RemoveNativeHook;
{$IFDEF WINDOWS}
var
  wnd: HWND;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  if not FNativeHooked then Exit;
  wnd := FHookedWnd;
  if (wnd <> 0) and Windows.IsWindow(wnd) then
  begin
    SetWindowLongPtr(wnd, GWL_WNDPROC, LONG_PTR(FOrigWndProc));
    Windows.RemoveProp(wnd, SNAP_PROP_NAME);
  end;
  FNativeHooked := False;
  FHookedWnd := 0;
  FOrigWndProc := 0;
  {$ENDIF}
end;

{$IFDEF WINDOWS}
function SnapNativeWndProc(Wnd: HWND; uMsg: UINT; wParam: WPARAM;
  lParam: LPARAM): LRESULT; stdcall;
var
  A: TSnapFormAdapter;
  orig: PtrUInt;
begin
  A := TSnapFormAdapter(PtrUInt(Windows.GetProp(Wnd, SNAP_PROP_NAME)));
  if (A = nil) or (not A.FNativeHooked) then
    Exit(DefWindowProc(Wnd, uMsg, wParam, lParam));
  orig := A.FOrigWndProc;
  if uMsg = WM_ENTERSIZEMOVE then
    A.HandleEnterSizeMove;
  Result := CallWindowProc(WNDPROC(orig), Wnd, uMsg, wParam, lParam);
  if uMsg = WM_EXITSIZEMOVE then
    A.HandleExitSizeMove;
end;
{$ENDIF}

procedure TSnapFormAdapter.HandleShow(Sender: TObject);
begin
  if Assigned(FPrevShow) then
    FPrevShow(Sender);
  InstallNativeHook;
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
  b: TSnapRect;
begin
  if Msg.Msg = WM_ENTERSIZEMOVE then
    HandleEnterSizeMove;

  FOldProc(Msg);

  if Msg.Msg = LM_MOVE then
  begin
    b := FWin.GetBounds;
    dx := b.X - FLastX;
    dy := b.Y - FLastY;
    if (dx <> 0) or (dy <> 0) then
    begin
      FLastX := b.X;
      FLastY := b.Y;
      if FIsMain then
        FManager.OnMainMoved(dx, dy)
      else
        FManager.OnSubMoved(FWin, dx, dy);
    end;
  end
  else if Msg.Msg = WM_EXITSIZEMOVE then
    HandleExitSizeMove;
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
