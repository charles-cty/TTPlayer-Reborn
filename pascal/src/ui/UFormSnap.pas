unit UFormSnap;

{$mode objfpc}{$H+}

// LCL 窗口与 TWindowSnapManager 的桥：
//   TFormSnapWindow  — ISnapWindow 适配 TForm。吸附在逻辑像素里算。
//                      Windows DPI≠100% 时用 UDpiScale 把 native 坐标换回逻辑。
//                      GTK3/WSLg：始终用 LCL Left/Top（GDK origin 与 LCL 不是
//                      同一原点；不要把 CSD 尺寸比当成 DPI）。
//   TSnapFormAdapter — Windows：子类化原生 WndProc 收 WM_ENTER/EXITSIZEMOVE
//                      GTK3/X11：TryBeginCaptionDrag 模拟 HTCAPTION 拖动
//                      （gdk_seat_grab 指针抓取 + gtk_window_move），
//                      松手走 OnDragFinished（与 Windows 吸附同一套）
// Linux 只支持 X11（见 UGdkX11Backend）。探测：tools/test-gtk3-wayland.sh。

interface

uses
  Classes, SysUtils, Forms, Controls, LCLType, LCLIntf, LMessages, Types,
  UWindowSnapMath, UWindowSnapManager, UPlatformWindow, USkinView
{$IFDEF WINDOWS}
  , UDpiScale
{$ENDIF}
  ;

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
    procedure Detach;
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
    FCaptionDragging: Boolean;
    FGrabOffX, FGrabOffY: Integer;
    FDragOriginX, FDragOriginY: Integer;
    FLastViewScale: Double;
    FSyncingView: Boolean;
    procedure WndProc(var Msg: TLMessage);
    procedure SyncViewScale(Force: Boolean);
    procedure HandleShow(Sender: TObject);
    procedure HandleHide(Sender: TObject);
    procedure UpdateScreenRect;
    procedure HandleEnterSizeMove;
    procedure HandleExitSizeMove;
    procedure InstallNativeHook;
    procedure RemoveNativeHook;
    procedure ReadPointerRoot(out X, Y: Integer);
  public
    constructor Create(AForm: TForm; AManager: TWindowSnapManager;
      AWin: ISnapWindow; AIsMain: Boolean); reintroduce;
    destructor Destroy; override;
    procedure BeginCaptionDrag;
    procedure EndCaptionDrag;
  end;

function HookSnapWindow(AForm: TForm; AManager: TWindowSnapManager;
  AIsMain: Boolean): ISnapWindow;

function ResizeEdgesOf(RightEdge, BottomEdge: Boolean): TSnapEdges;

// GTK3：无 HTCAPTION 系统拖动。皮肤窗 MouseDown 调本函数；TForm 已
// csCaptureMouse。X 指针抓取后按「起点 Left + 根坐标位移」MoveTo
// （WSLg 上不要混用 GDK origin 与 LCL Left，也不要只靠 gtk_grab_add）。
procedure TryBeginCaptionDrag(AForm: TForm; ClientX, ClientY: Integer);

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

const
  WM_ENTERSIZEMOVE = $0231;
  WM_EXITSIZEMOVE  = $0232;
  WM_DPICHANGED    = $02E0;
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
{$IFDEF WINDOWS}
var
  wr: TRect;
  pw, ph, lx, ly: Integer;
{$ENDIF}
begin
  Result := SnapRectXYWH(0, 0, 0, 0);
  if FForm = nil then Exit;
  Result := SnapRectXYWH(FForm.Left, FForm.Top, FForm.Width, FForm.Height);
{$IFDEF WINDOWS}
  if not FForm.HandleAllocated then Exit;
  wr := Types.Rect(0, 0, 0, 0);
  if not PlatformGetWindowRect(FForm.Handle, wr) then Exit;
  pw := wr.Right - wr.Left;
  ph := wr.Bottom - wr.Top;
  if (pw <= 0) or (ph <= 0) or (FForm.Width <= 0) or (FForm.Height <= 0) then
    Exit;
  // 仅在宽高均匀缩放到常见 DPI 档时换算。
  if WindowScaleFromSizes(FForm.Width, FForm.Height, pw, ph) <= 1.0001 then
    Exit;
  lx := LogicalFromNative(wr.Left, FForm.Width, pw);
  ly := LogicalFromNative(wr.Top, FForm.Height, ph);
  Result.X := lx;
  Result.Y := ly;
  Result.W := FForm.Width;
  Result.H := FForm.Height;
{$ENDIF}
end;

procedure TFormSnapWindow.MoveTo(AX, AY: Integer);
{$IFDEF WINDOWS}
var
  wr: TRect;
  pw, ph, physX, physY: Integer;
{$ENDIF}
begin
  if FForm = nil then Exit;
  // LCL SendMoveSizeMessages 把 Left/Top 塞进 SmallInt。
  if (AX < Low(SmallInt)) or (AX > High(SmallInt)) or
     (AY < Low(SmallInt)) or (AY > High(SmallInt)) then
    Exit;
  if (FForm.Left <> AX) or (FForm.Top <> AY) then
    FForm.SetBounds(AX, AY, FForm.Width, FForm.Height);
{$IFNDEF WINDOWS}
  // GTK3 TGtk3Window.SetBounds 会 size_allocate+resize+move；再 gtk_window_move
  // 一次，避免只改 LCL Left 而 X 窗口停在原地（WSLg 上很常见）。
  if FForm.HandleAllocated then
    PlatformMoveWindow(FForm.Handle, AX, AY);
{$ENDIF}
{$IFDEF WINDOWS}
  // Win32 SetWindowPos 是物理像素。GTK3 gtk_window_move 是逻辑像素。
  if not FForm.HandleAllocated then Exit;
  wr := Types.Rect(0, 0, 0, 0);
  if not PlatformGetWindowRect(FForm.Handle, wr) then Exit;
  pw := wr.Right - wr.Left;
  ph := wr.Bottom - wr.Top;
  if (pw <= 0) or (ph <= 0) or (FForm.Width <= 0) or (FForm.Height <= 0) then
    Exit;
  physX := NativeFromLogical(AX, FForm.Width, pw);
  physY := NativeFromLogical(AY, FForm.Height, ph);
  if (wr.Left <> physX) or (wr.Top <> physY) then
    PlatformMoveWindow(FForm.Handle, physX, physY);
{$ENDIF}
end;

procedure TFormSnapWindow.ResizeTo(AW, AH: Integer);
begin
  if FForm = nil then Exit;
  if (FForm.Width <> AW) or (FForm.Height <> AH) then
    FForm.SetBounds(FForm.Left, FForm.Top, AW, AH);
end;

function TFormSnapWindow.GetVisible: Boolean;
begin
  // FForm 为空或已进入销毁：不能读 TForm.Visible（nil 时指令就在
  // `mov al,[rax+0x3fc]`，Linux 上即 EAccessViolation @ GetVisible）。
  Result := Assigned(FForm) and FForm.Visible and
    not (csDestroying in FForm.ComponentState);
end;

procedure TFormSnapWindow.SetVisible(AValue: Boolean);
begin
  if FForm = nil then Exit;
  if csDestroying in FForm.ComponentState then Exit;
  FForm.Visible := AValue;
end;

function TFormSnapWindow.GetName: string;
begin
  if FForm = nil then
  begin
    Result := '';
    Exit;
  end;
  Result := FForm.Caption;
  if Result = '' then
    Result := FForm.ClassName;
end;

procedure TFormSnapWindow.Detach;
begin
  FForm := nil;
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
  FCaptionDragging := False;
  FGrabOffX := 0;
  FGrabOffY := 0;
  FDragOriginX := 0;
  FDragOriginY := 0;
  FLastViewScale := FormViewScale(AForm);
  FSyncingView := False;
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
  if FCaptionDragging then
  begin
    FCaptionDragging := False;
    PlatformUngrabPointer;
    if Assigned(FForm) and FForm.HandleAllocated and
       (GetCapture = FForm.Handle) then
      ReleaseCapture;
  end;
  RemoveNativeHook;
  if Assigned(FForm) then
  begin
    if Assigned(FOldProc) then
      FForm.WindowProc := FOldProc;
    FForm.OnShow := FPrevShow;
    FForm.OnHide := FPrevHide;
  end;
  if Assigned(FWin) then
    FWin.Detach;
  if FManager <> nil then
  begin
    if FIsMain then
      FManager.SetMainWindow(nil)
    else
      FManager.RemoveSubWindow(FWin);
  end;
  FWin := nil;
  FForm := nil;
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

procedure TSnapFormAdapter.SyncViewScale(Force: Boolean);
var
  s: Double;
begin
  if FSyncingView or (FForm = nil) then Exit;
  s := FormViewScale(FForm);
  if (not Force) and (Abs(s - FLastViewScale) < 0.01) then Exit;
  FSyncingView := True;
  try
    FLastViewScale := s;
    NotifySkinViewScale(FForm);
  finally
    FSyncingView := False;
  end;
end;

procedure TSnapFormAdapter.HandleEnterSizeMove;
var
  b: TSnapRect;
begin
  if (FManager = nil) or (FWin = nil) then Exit;
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
  if (FManager = nil) or (FWin = nil) then Exit;
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
  if uMsg = WM_DPICHANGED then
  begin
    if lParam <> 0 then
      A.FForm.SetBounds(PRect(lParam)^.Left, PRect(lParam)^.Top,
        A.FForm.Width, A.FForm.Height);
    A.SyncViewScale(True);
    Result := 0;
    Exit;
  end;
  if uMsg = WM_ENTERSIZEMOVE then
    A.HandleEnterSizeMove;
  Result := CallWindowProc(WNDPROC(orig), Wnd, uMsg, wParam, lParam);
  if uMsg = WM_EXITSIZEMOVE then
    A.HandleExitSizeMove;
  // 任务栏把主窗口拉到前台时，owned 子窗口有时不会一起抬升（无边框+Region）。
  if (uMsg = Windows.WM_ACTIVATE) and A.FIsMain and ((wParam and $FFFF) <> 0) then
    RaiseOwnedGroup(A.FForm, A.FForm);
end;
{$ENDIF}

procedure TSnapFormAdapter.ReadPointerRoot(out X, Y: Integer);
var
  cur: TPoint;
begin
  if PlatformGetPointerRoot(X, Y) then Exit;
  cur := Mouse.CursorPos;
  X := cur.X;
  Y := cur.Y;
end;

procedure TSnapFormAdapter.BeginCaptionDrag;
begin
  {$IFDEF WINDOWS}
  Exit;
  {$ENDIF}
  if FCaptionDragging or (FForm = nil) or (FWin = nil) then Exit;
  // 起点用 LCL Left + 指针根坐标的累计位移。不要 CursorPos-Left：
  // WSLg 上 GDK origin 与 LCL Left 不是同一原点，相减会瞬移。
  ReadPointerRoot(FGrabOffX, FGrabOffY);
  FDragOriginX := FForm.Left;
  FDragOriginY := FForm.Top;
  FCaptionDragging := True;
  if FForm.HandleAllocated then
    PlatformGrabPointer(FForm.Handle);
  if FForm.HandleAllocated and (GetCapture <> FForm.Handle) then
    SetCapture(FForm.Handle);
  HandleEnterSizeMove;
end;

procedure TSnapFormAdapter.EndCaptionDrag;
begin
  if not FCaptionDragging then Exit;
  FCaptionDragging := False;
  PlatformUngrabPointer;
  HandleExitSizeMove;
end;

procedure TSnapFormAdapter.HandleShow(Sender: TObject);
begin
  if Assigned(FPrevShow) then
    FPrevShow(Sender);
  if (FForm = nil) or (csDestroying in FForm.ComponentState) then Exit;
  InstallNativeHook;
  ConfigurePlatformWindow(FForm);
  UpdateScreenRect;
  if FManager <> nil then
    FManager.RebuildSnapGraph;
end;

procedure TSnapFormAdapter.HandleHide(Sender: TObject);
begin
  if Assigned(FPrevHide) then
    FPrevHide(Sender);
  // BeforeDestruction 里 Hide 时 csDestroying 已置位；此时重建图会
  // 读到别的已拆掉的 TFormSnapWindow.FForm。
  if (FForm = nil) or (csDestroying in FForm.ComponentState) then Exit;
  if FManager <> nil then
    FManager.RebuildSnapGraph;
end;

procedure TSnapFormAdapter.WndProc(var Msg: TLMessage);
var
  dx, dy: Integer;
  b: TSnapRect;
  cur: TPoint;
begin
  if Assigned(FForm) and (csDestroying in FForm.ComponentState) then
  begin
    if Assigned(FOldProc) then
      FOldProc(Msg);
    Exit;
  end;

  if Msg.Msg = WM_ENTERSIZEMOVE then
    HandleEnterSizeMove;

  // 松手先结束拖动，再让 LCL 因 csCaptureMouse 释放捕获。
  if FCaptionDragging and (Msg.Msg = LM_LBUTTONUP) then
    EndCaptionDrag;

  FOldProc(Msg);

  if (FForm = nil) or (FWin = nil) or (FManager = nil) then Exit;

  if FCaptionDragging then
  begin
    if Msg.Msg = LM_MOUSEMOVE then
    begin
      ReadPointerRoot(cur.X, cur.Y);
      dx := cur.X - FGrabOffX;
      dy := cur.Y - FGrabOffY;
      if (dx <> 0) or (dy <> 0) then
        FWin.MoveTo(FDragOriginX + dx, FDragOriginY + dy);
    end
    else if (Msg.Msg = LM_CAPTURECHANGED) and (GetCapture <> FForm.Handle) and
            ((GetKeyState(VK_LBUTTON) and $8000) = 0) then
      // GTK3 GetCapture 常指向 container 而非 TForm.Handle；左键仍按下时
      // 不要结束。真正的 X 抓取由 PlatformUngrabPointer 在 MouseUp 释放。
      EndCaptionDrag;
  end;

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
    SyncViewScale(False);
  end
  else if Msg.Msg = WM_DPICHANGED then
    SyncViewScale(True)
  else if Msg.Msg = WM_EXITSIZEMOVE then
    HandleExitSizeMove;
end;

function FindSnapAdapter(AForm: TForm): TSnapFormAdapter;
var
  i: Integer;
begin
  Result := nil;
  if AForm = nil then Exit;
  for i := 0 to AForm.ComponentCount - 1 do
    if AForm.Components[i] is TSnapFormAdapter then
      Exit(TSnapFormAdapter(AForm.Components[i]));
end;

procedure TryBeginCaptionDrag(AForm: TForm; ClientX, ClientY: Integer);
{$IFNDEF WINDOWS}
var
  A: TSnapFormAdapter;
  pt: TPoint;
  lp: LPARAM;
{$ENDIF}
begin
{$IFDEF WINDOWS}
  Exit;
{$ELSE}
  if AForm = nil then Exit;
  // TForm 带 csCaptureMouse，WMLButtonDown 已经 SetCapture。不能见捕获就退出。
  if (GetCapture <> 0) and (GetCapture <> AForm.Handle) then Exit;
  pt := AForm.ClientToScreen(Point(ClientX, ClientY));
  lp := LPARAM(Word(SmallInt(pt.X))) or (LPARAM(Word(SmallInt(pt.Y))) shl 16);
  if AForm.Perform(LM_NCHITTEST, 0, lp) <> HTCAPTION then Exit;
  A := FindSnapAdapter(AForm);
  if A <> nil then
    A.BeginCaptionDrag;
{$ENDIF}
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
