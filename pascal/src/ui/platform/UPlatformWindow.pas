unit UPlatformWindow;

{$mode objfpc}{$H+}

// 平台窗口原语，隔离 Windows / X11 / Wayland 差异（docs/lazarus-rewrite.md GTK3 绕行）。
//   ApplyAlphaShape     — 由位图 alpha 生成异形窗口
//   SetWindowAlwaysOnTop — 置顶（Win: HWND_TOPMOST；X11: EWMH _NET_WM_STATE_ABOVE）
//   QueryPlatformWindowBackend — win32 / x11 / wayland / other
//
// Windows：SetWindowRgn + SetWindowPos。
// UNIX：只支持 X11（XWayland / Xorg）。UGdkX11Backend 在 Interfaces 之前
// 强制 GDK_BACKEND=x11、GTK_CSD=0。不支持 Wayland 客户端。
// dynload libX11/libXext/libgdk-3；XShape / EWMH 仅在 GdkX11Display 上调用。
//
// LCL GTK3 的 HWND 是 TGtk3Widget 对象，不是 GtkWidget*（GTK2 才是）。
// 对 Handle 直接 gtk_widget_get_window 会 GTK_IS_WIDGET 失败，严重时 Access violation。
// DPI：UDpiScale 把均匀 UI 缩放与 CSD 撑大区分开；ApplyAlphaShape 按 native/逻辑尺寸比缩放 Region。

interface

uses
  Classes, SysUtils, Types, Forms, Controls, LCLType,
  BGRABitmap, BGRABitmapTypes, UAlphaShape, UDpiScale, UTracy;

type
  TPlatformWindowBackend = (pwbUnknown, pwbWin32, pwbX11, pwbWayland, pwbOther);

function QueryPlatformWindowBackend: TPlatformWindowBackend;
function PlatformBackendName: string;
function PlatformGdkDisplayName: string;
function PlatformShapeSupported: Boolean;
function PlatformAlwaysOnTopNative: Boolean;

procedure ApplyAlphaShape(AHandle: HWND; Bitmap: TBGRABitmap);
procedure ApplyShapeRects(AHandle: HWND; const Rects: TShapeRectArray;
  LogicalW, LogicalH: Integer; Redraw: Boolean = True);
procedure ApplyRectShape(AHandle: HWND; AWidth, AHeight: Integer);
procedure ClearWindowShape(AHandle: HWND);
procedure SetWindowAlwaysOnTop(AForm: TCustomForm; Enable: Boolean);
procedure ConfigurePlatformWindow(AForm: TCustomForm);
// 辅助窗口挂到主窗口：Win 为 HWND owner，GTK/X11 为 transient parent。
// 任务栏激活/最小化时操作系统会把 owned 窗口当一组处理。
procedure PrepareAuxOwnedWindow(AForm, AOwner: TCustomForm);
procedure BindWindowToOwner(AForm, AOwner: TCustomForm);
procedure RaiseWindowKeepFocus(AForm: TCustomForm);
procedure RaiseOwnedGroup(AOwner, AKeepFocus: TCustomForm);
function PlatformGetWindowRect(AHandle: HWND; out R: TRect): Boolean;
procedure PlatformMoveWindow(AHandle: HWND; AX, AY: Integer);
procedure PlatformBeginLiveSize(AHandle: HWND);
procedure PlatformEndLiveSize(AHandle: HWND);
// GTK3：X 指针抓取（异形窗外仍能收到运动/松开）。Win32 无需，HTCAPTION 已抓鼠标。
function PlatformGrabPointer(AHandle: HWND): Boolean;
procedure PlatformUngrabPointer;
function PlatformGetPointerRoot(out X, Y: Integer): Boolean;
function PlatformWindowIsDecorated(AHandle: HWND): Boolean;
function PlatformWindowHasTitlebar(AHandle: HWND): Boolean;
function PlatformWindowIsAbove(AHandle: HWND): Boolean;
function PlatformGdkScaleFactor(AHandle: HWND): Integer;
function PlatformWindowScale(AHandle: HWND; LogicalW, LogicalH: Integer): Double;
function PlatformPixelsPerInch: Integer;
function PlatformXWindowSize(AHandle: HWND; out W, H: Integer): Boolean;

implementation

uses
  LCLIntf
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  {$IFDEF UNIX}, dynlibs{$ENDIF}
  {$IFDEF LCLGTK3}, Gtk3Widgets{$ENDIF};

var
  RaisingOwnedGroup: Boolean = False;

function BackendToName(B: TPlatformWindowBackend): string;
begin
  case B of
    pwbWin32:   Result := 'win32';
    pwbX11:     Result := 'x11';
    pwbWayland: Result := 'wayland';
    pwbOther:   Result := 'other';
  else
    Result := 'unknown';
  end;
end;

{$IFDEF WINDOWS}

function QueryPlatformWindowBackend: TPlatformWindowBackend;
begin
  Result := pwbWin32;
end;

function PlatformBackendName: string;
begin
  Result := 'win32';
end;

function PlatformGdkDisplayName: string;
begin
  Result := '';
end;

function PlatformShapeSupported: Boolean;
begin
  Result := True;
end;

function PlatformAlwaysOnTopNative: Boolean;
begin
  Result := True;
end;

procedure ApplyShapeRects(AHandle: HWND; const Rects: TShapeRectArray;
  LogicalW, LogicalH: Integer; Redraw: Boolean = True);
const
  RDH_RECTANGLES = 1;
var
  scaled: TShapeRectArray;
  scale: Double;
  n, i, bytes: Integer;
  data: PRGNDATA;
  pr: PRect;
  rgn, totalRgn, segRgn, rowRgn: HRGN;
  minX, minY, maxX, maxY: Integer;
  zone: TTracyZone;
begin
  if AHandle = 0 then Exit;
  scaled := Rects;
  if (LogicalW > 0) and (LogicalH > 0) then
  begin
    zone := TracyZoneBegin('Window.ScaleShapeRects');
    try
    scale := PlatformWindowScale(AHandle, LogicalW, LogicalH);
    if scale > 1.0001 then
      scaled := ScaleShapeRects(Rects, scale, scale);
    finally
      TracyZoneEnd(zone);
    end;
  end;
  n := Length(scaled);
  if n <= 0 then
  begin
    SetWindowRgn(AHandle, CreateRectRgn(0, 0, 0, 0), True);
    Exit;
  end;
  bytes := SizeOf(RGNDATAHEADER) + n * SizeOf(TRect);
  GetMem(data, bytes);
  try
    FillChar(data^, bytes, 0);
    data^.rdh.dwSize := SizeOf(RGNDATAHEADER);
    data^.rdh.iType := RDH_RECTANGLES;
    data^.rdh.nCount := DWORD(n);
    data^.rdh.nRgnSize := DWORD(n * SizeOf(TRect));
    minX := scaled[0].X;
    minY := scaled[0].Y;
    maxX := scaled[0].X + scaled[0].W;
    maxY := scaled[0].Y + scaled[0].H;
    pr := PRect(@data^.Buffer);
    for i := 0 to n - 1 do
    begin
      pr^.Left := scaled[i].X;
      pr^.Top := scaled[i].Y;
      pr^.Right := scaled[i].X + scaled[i].W;
      pr^.Bottom := scaled[i].Y + scaled[i].H;
      if scaled[i].X < minX then minX := scaled[i].X;
      if scaled[i].Y < minY then minY := scaled[i].Y;
      if scaled[i].X + scaled[i].W > maxX then maxX := scaled[i].X + scaled[i].W;
      if scaled[i].Y + scaled[i].H > maxY then maxY := scaled[i].Y + scaled[i].H;
      Inc(pr);
    end;
    data^.rdh.rcBound.Left := minX;
    data^.rdh.rcBound.Top := minY;
    data^.rdh.rcBound.Right := maxX;
    data^.rdh.rcBound.Bottom := maxY;
    zone := TracyZoneBegin('Window.ExtCreateRegion');
    try
      rgn := ExtCreateRegion(nil, bytes, data^);
    finally
      TracyZoneEnd(zone);
    end;
  finally
    FreeMem(data);
  end;
  if rgn = 0 then
  begin
    zone := TracyZoneBegin('Window.RegionFallback');
    try
    totalRgn := CreateRectRgn(0, 0, 0, 0);
    for i := 0 to n - 1 do
    begin
      segRgn := CreateRectRgn(scaled[i].X, scaled[i].Y,
        scaled[i].X + scaled[i].W, scaled[i].Y + scaled[i].H);
      rowRgn := CreateRectRgn(0, 0, 0, 0);
      CombineRgn(rowRgn, totalRgn, segRgn, RGN_OR);
      DeleteObject(totalRgn);
      DeleteObject(segRgn);
      totalRgn := rowRgn;
    end;
    rgn := totalRgn;
    finally
      TracyZoneEnd(zone);
    end;
  end;
  zone := TracyZoneBegin('Window.SetWindowRgn');
  try
    SetWindowRgn(AHandle, rgn, Redraw);
  finally
    TracyZoneEnd(zone);
  end;
end;

procedure ApplyAlphaShape(AHandle: HWND; Bitmap: TBGRABitmap);
var
  zone: TTracyZone;
  rects: TShapeRectArray;
begin
  if (AHandle = 0) or (Bitmap = nil) then Exit;
  zone := TracyZoneBegin('Window.AlphaRunRects');
  try
    rects := AlphaRunRects(Bitmap);
  finally
    TracyZoneEnd(zone);
  end;
  ApplyShapeRects(AHandle, rects, Bitmap.Width, Bitmap.Height);
end;

procedure ApplyRectShape(AHandle: HWND; AWidth, AHeight: Integer);
var
  scale: Double;
  rw, rh: Integer;
begin
  if (AHandle = 0) or (AWidth < 1) or (AHeight < 1) then Exit;
  scale := PlatformWindowScale(AHandle, AWidth, AHeight);
  rw := AWidth;
  rh := AHeight;
  if scale > 1.0001 then
  begin
    rw := Round(AWidth * scale);
    rh := Round(AHeight * scale);
    if rw < 1 then rw := 1;
    if rh < 1 then rh := 1;
  end;
  SetWindowRgn(AHandle, CreateRectRgn(0, 0, rw, rh), True);
end;

procedure ClearWindowShape(AHandle: HWND);
begin
  if AHandle <> 0 then
    SetWindowRgn(AHandle, 0, True);
end;

procedure BindWindowToOwner(AForm, AOwner: TCustomForm);
const
  HWNDPARENT_INDEX = -8;
var
  styleEx: LONG_PTR;
begin
  if (AForm = nil) or (AOwner = nil) or (AForm = AOwner) then Exit;
  if not AForm.HandleAllocated or not AOwner.HandleAllocated then Exit;
  if GetWindowLongPtr(AForm.Handle, HWNDPARENT_INDEX) <> LONG_PTR(AOwner.Handle) then
    SetWindowLongPtr(AForm.Handle, HWNDPARENT_INDEX, LONG_PTR(AOwner.Handle));
  styleEx := GetWindowLongPtr(AForm.Handle, GWL_EXSTYLE);
  styleEx := (styleEx or WS_EX_TOOLWINDOW) and not WS_EX_APPWINDOW;
  SetWindowLongPtr(AForm.Handle, GWL_EXSTYLE, styleEx);
  SetWindowPos(AForm.Handle, 0, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED);
end;

procedure PrepareAuxOwnedWindow(AForm, AOwner: TCustomForm);
begin
  if (AForm = nil) or (AOwner = nil) or (AForm = AOwner) then Exit;
  AForm.ShowInTaskBar := stNever;
  AForm.PopupMode := pmExplicit;
  AForm.PopupParent := AOwner;
  if AForm.HandleAllocated then
    BindWindowToOwner(AForm, AOwner);
end;

procedure RaiseWindowKeepFocus(AForm: TCustomForm);
begin
  if (AForm = nil) or not AForm.Visible then Exit;
  if not AForm.HandleAllocated then Exit;
  if AForm.WindowState = wsMinimized then
    ShowWindow(AForm.Handle, SW_RESTORE);
  SetWindowPos(AForm.Handle, HWND_TOP, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
end;

procedure RaiseOwnedGroup(AOwner, AKeepFocus: TCustomForm);
var
  i: Integer;
  f: TCustomForm;
begin
  if (AOwner = nil) or RaisingOwnedGroup then Exit;
  RaisingOwnedGroup := True;
  try
    RaiseWindowKeepFocus(AOwner);
    for i := 0 to Screen.CustomFormCount - 1 do
    begin
      f := Screen.CustomForms[i];
      if (f = nil) or (f = AOwner) then Continue;
      if f.PopupParent = AOwner then
        RaiseWindowKeepFocus(f);
    end;
    if (AKeepFocus <> nil) and (AKeepFocus <> AOwner) then
      RaiseWindowKeepFocus(AKeepFocus);
  finally
    RaisingOwnedGroup := False;
  end;
end;

procedure ConfigurePlatformWindow(AForm: TCustomForm);
begin
  if AForm = nil then Exit;
  if AForm.PopupParent <> nil then
    BindWindowToOwner(AForm, AForm.PopupParent);
end;

function PlatformGetWindowRect(AHandle: HWND; out R: TRect): Boolean;
begin
  R := Types.Rect(0, 0, 0, 0);
  Result := (AHandle <> 0) and (LCLIntf.GetWindowRect(AHandle, R) <> 0);
end;

procedure PlatformMoveWindow(AHandle: HWND; AX, AY: Integer);
var
  zone: TTracyZone;
begin
  if AHandle = 0 then Exit;
  zone := TracyZoneBegin('Window.SetWindowPos');
  try
    Windows.SetWindowPos(AHandle, 0, AX, AY, 0, 0,
      SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
  finally
    TracyZoneEnd(zone);
  end;
end;

procedure PlatformBeginLiveSize(AHandle: HWND);
begin
  if AHandle = 0 then Exit;
  SendMessage(AHandle, WM_SETREDRAW, 0, 0);
end;

procedure PlatformEndLiveSize(AHandle: HWND);
begin
  if AHandle = 0 then Exit;
  SendMessage(AHandle, WM_SETREDRAW, 1, 0);
end;

function PlatformGrabPointer(AHandle: HWND): Boolean;
begin
  Result := False;
  if AHandle = 0 then ;
end;

procedure PlatformUngrabPointer;
begin
end;

function PlatformGetPointerRoot(out X, Y: Integer): Boolean;
begin
  Result := False;
  X := 0;
  Y := 0;
end;

procedure SetWindowAlwaysOnTop(AForm: TCustomForm; Enable: Boolean);
begin
  if AForm = nil then Exit;
  if Enable then
    AForm.FormStyle := fsStayOnTop
  else
    AForm.FormStyle := fsNormal;
  if AForm.HandleAllocated then
  begin
    if Enable then
      SetWindowPos(AForm.Handle, HWND_TOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE)
    else
      SetWindowPos(AForm.Handle, HWND_NOTOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  end;
end;

function PlatformWindowIsDecorated(AHandle: HWND): Boolean;
begin
  Result := (AHandle <> 0) and
    ((GetWindowLong(AHandle, GWL_STYLE) and WS_CAPTION) <> 0);
end;

function PlatformWindowHasTitlebar(AHandle: HWND): Boolean;
begin
  Result := PlatformWindowIsDecorated(AHandle);
end;

function PlatformWindowIsAbove(AHandle: HWND): Boolean;
begin
  Result := (AHandle <> 0) and
    ((GetWindowLong(AHandle, GWL_EXSTYLE) and WS_EX_TOPMOST) <> 0);
end;

function PlatformGdkScaleFactor(AHandle: HWND): Integer;
begin
  Result := 1;
  if AHandle = 0 then ;
end;

function PlatformWindowScale(AHandle: HWND; LogicalW, LogicalH: Integer): Double;
var
  wr: TRect;
begin
  Result := 1.0;
  wr := Types.Rect(0, 0, 0, 0);
  if not PlatformGetWindowRect(AHandle, wr) then Exit;
  Result := WindowScaleFromSizes(LogicalW, LogicalH,
    wr.Right - wr.Left, wr.Bottom - wr.Top);
end;

function PlatformPixelsPerInch: Integer;
var
  dc: HDC;
begin
  Result := 96;
  dc := GetDC(0);
  if dc <> 0 then
  begin
    Result := GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(0, dc);
    if Result <= 0 then
      Result := 96;
  end;
end;

function PlatformXWindowSize(AHandle: HWND; out W, H: Integer): Boolean;
var
  wr: TRect;
begin
  W := 0;
  H := 0;
  Result := PlatformGetWindowRect(AHandle, wr);
  if Result then
  begin
    W := wr.Right - wr.Left;
    H := wr.Bottom - wr.Top;
    Result := (W > 0) and (H > 0);
  end;
end;

{$ELSE}

type
  TXRectangle = record
    x, y: SmallInt;
    width, height: Word;
  end;
  PXRectangle = ^TXRectangle;

  TGdkWindow = Pointer;
  TGdkDisplay = Pointer;
  PDisplay = Pointer;
  TXID = PtrUInt;

  TGtkWidgetGetWindow = function(Widget: Pointer): TGdkWindow; cdecl;
  TGtkWidgetRealize = procedure(Widget: Pointer); cdecl;
  TGtkWindowSetDecorated = procedure(Window: Pointer; Decorated: LongInt); cdecl;
  TGtkWindowSetTransientFor = procedure(Window, Parent: Pointer); cdecl;
  TGtkWindowSetSkipTaskbarHint = procedure(Window: Pointer; Setting: LongInt); cdecl;
  TGtkWindowGetDecorated = function(Window: Pointer): LongInt; cdecl;
  TGtkWindowGetTitlebar = function(Window: Pointer): Pointer; cdecl;
  TGtkWindowMove = procedure(Window: Pointer; X, Y: LongInt); cdecl;
  TGtkWindowResize = procedure(Window: Pointer; Width, Height: LongInt); cdecl;
  TGtkWindowSetKeepAbove = procedure(Window: Pointer; Setting: LongInt); cdecl;
  TGtkGetCurrentEvent = function: Pointer; cdecl;
  TGtkGetCurrentEventTime = function: LongWord; cdecl;
  TGdkEventFree = procedure(Event: Pointer); cdecl;
  TGdkEventGetRootCoords = function(Event: Pointer; var X, Y: Double): LongInt; cdecl;
  TGdkDisplayGetDefaultSeat = function(Display: TGdkDisplay): Pointer; cdecl;
  TGdkSeatGrab = function(Seat: Pointer; Window: TGdkWindow; Capabilities: Integer;
    OwnerEvents: LongInt; Cursor: Pointer; Event: Pointer; Prepare: Pointer;
    PrepareData: Pointer): Integer; cdecl;
  TGdkSeatUngrab = procedure(Seat: Pointer); cdecl;
  TGdkPointerGrab = function(Window: TGdkWindow; OwnerEvents: LongInt;
    EventMask: LongInt; ConfineTo: TGdkWindow; Cursor: Pointer;
    Time: LongWord): Integer; cdecl;
  TGdkPointerUngrab = procedure(Time: LongWord); cdecl;
  TGdkWindowSetDecorations = procedure(Window: TGdkWindow; Decorations: LongWord); cdecl;
  TGdkWindowRaise = procedure(Window: TGdkWindow); cdecl;
  TGdkWindowGetOrigin = function(Window: TGdkWindow; out X, Y: LongInt): Integer; cdecl;
  TGdkWindowGetWidth = function(Window: TGdkWindow): Integer; cdecl;
  TGdkWindowGetHeight = function(Window: TGdkWindow): Integer; cdecl;
  TGdkWindowGetState = function(Window: TGdkWindow): LongWord; cdecl;
  TGdkWindowGetScaleFactor = function(Window: TGdkWindow): Integer; cdecl;
  TGtkWidgetGetScaleFactor = function(Widget: Pointer): Integer; cdecl;
  TGdkScreenGetDefault = function: Pointer; cdecl;
  TGdkScreenGetResolution = function(Screen: Pointer): Double; cdecl;
  TGdkX11WindowGetXid = function(Window: TGdkWindow): TXID; cdecl;
  TGdkWindowGetDisplay = function(Window: TGdkWindow): TGdkDisplay; cdecl;
  TGdkX11DisplayGetXdisplay = function(Display: TGdkDisplay): PDisplay; cdecl;
  TGdkDisplayGetDefault = function: TGdkDisplay; cdecl;
  TGdkDisplayGetName = function(Display: TGdkDisplay): PAnsiChar; cdecl;
  TGTypeName = function(AType: PtrUInt): PAnsiChar; cdecl;
  TXInternAtom = function(Display: PDisplay; Name: PAnsiChar;
    OnlyIfExists: Integer): Cardinal; cdecl;
  TXFlush = procedure(Display: PDisplay); cdecl;
  TXMoveWindow = procedure(Display: PDisplay; W: TXID; X, Y: Integer); cdecl;
  TXSetTransientForHint = function(Display: PDisplay; W, PropWindow: TXID): Integer; cdecl;
  TXChangeProperty = function(Display: PDisplay; W: TXID;
    Prop, AType: Cardinal; Format, Mode: Integer; Data: Pointer;
    NElements: Integer): Integer; cdecl;
  TXGetWindowProperty = function(Display: PDisplay; W: TXID; Prop: PtrUInt;
    LongOffset, LongLength: PtrInt; Delete: Integer; ReqType: PtrUInt;
    ActualType: PPtrUInt; ActualFormat: PInteger;
    NItems, BytesAfter: PPtrUInt; PropReturn: PPointer): Integer; cdecl;
  TXFree = function(Data: Pointer): Integer; cdecl;
  TXGetGeometry = function(Display: PDisplay; D: TXID; out Root: TXID;
    out X, Y: Integer; out Width, Height, BorderWidth, Depth: Cardinal): Integer; cdecl;
  TXShapeCombineRectangles = procedure(Display: PDisplay; Dest: TXID;
    DestKind, XOff, YOff: Integer; Rects: PXRectangle; NRects, Op, Ordering: Integer); cdecl;

var
  GtkLib, GdkLib, GObjLib, X11Lib, XextLib: TLibHandle;
  GtkWidgetGetWindow: TGtkWidgetGetWindow;
  GtkWidgetRealize: TGtkWidgetRealize;
  GtkWindowSetDecorated: TGtkWindowSetDecorated;
  GtkWindowSetTransientFor: TGtkWindowSetTransientFor;
  GtkWindowSetSkipTaskbarHint: TGtkWindowSetSkipTaskbarHint;
  GtkWindowGetDecorated: TGtkWindowGetDecorated;
  GtkWindowGetTitlebar: TGtkWindowGetTitlebar;
  GtkWindowMove: TGtkWindowMove;
  GtkWindowResize: TGtkWindowResize;
  GtkWindowSetKeepAbove: TGtkWindowSetKeepAbove;
  GtkGetCurrentEventFn: TGtkGetCurrentEvent;
  GtkGetCurrentEventTimeFn: TGtkGetCurrentEventTime;
  GdkEventFreeFn: TGdkEventFree;
  GdkEventGetRootCoordsFn: TGdkEventGetRootCoords;
  GdkDisplayGetDefaultSeatFn: TGdkDisplayGetDefaultSeat;
  GdkSeatGrabFn: TGdkSeatGrab;
  GdkSeatUngrabFn: TGdkSeatUngrab;
  GdkPointerGrabFn: TGdkPointerGrab;
  GdkPointerUngrabFn: TGdkPointerUngrab;
  GdkWindowSetDecorations: TGdkWindowSetDecorations;
  GdkWindowRaiseFn: TGdkWindowRaise;
  GdkWindowGetOrigin: TGdkWindowGetOrigin;
  GdkWindowGetWidth: TGdkWindowGetWidth;
  GdkWindowGetHeight: TGdkWindowGetHeight;
  GdkWindowGetState: TGdkWindowGetState;
  GdkWindowGetScaleFactorFn: TGdkWindowGetScaleFactor;
  GtkWidgetGetScaleFactorFn: TGtkWidgetGetScaleFactor;
  GdkScreenGetDefaultFn: TGdkScreenGetDefault;
  GdkScreenGetResolutionFn: TGdkScreenGetResolution;
  GdkX11WindowGetXid: TGdkX11WindowGetXid;
  GdkWindowGetDisplay: TGdkWindowGetDisplay;
  GdkX11DisplayGetXdisplay: TGdkX11DisplayGetXdisplay;
  GdkDisplayGetDefaultFn: TGdkDisplayGetDefault;
  GdkDisplayGetNameFn: TGdkDisplayGetName;
  GTypeNameFn: TGTypeName;
  XInternAtomFn: TXInternAtom;
  XFlushFn: TXFlush;
  XMoveWindowFn: TXMoveWindow;
  XSetTransientForHintFn: TXSetTransientForHint;
  XChangePropertyFn: TXChangeProperty;
  XGetWindowPropertyFn: TXGetWindowProperty;
  XFreeFn: TXFree;
  XGetGeometryFn: TXGetGeometry;
  XShapeCombineRectanglesFn: TXShapeCombineRectangles;
  GdkTried: Boolean = False;
  GdkReady: Boolean = False;
  X11Tried: Boolean = False;
  X11Ready: Boolean = False;
  BackendQueried: Boolean = False;
  CachedBackend: TPlatformWindowBackend = pwbUnknown;
  CachedGdkName: string = '';
  PointerGrabbed: Boolean = False;
  GrabbedSeat: Pointer = nil;

function EnsureGdk: Boolean;
begin
  if GdkTried then Exit(GdkReady);
  GdkTried := True;
  GtkLib := LoadLibrary('libgtk-3.so.0');
  GdkLib := LoadLibrary('libgdk-3.so.0');
  GObjLib := LoadLibrary('libgobject-2.0.so.0');
  if (GtkLib = 0) or (GdkLib = 0) then
    Exit(False);
  Pointer(GtkWidgetGetWindow) := GetProcedureAddress(GtkLib, 'gtk_widget_get_window');
  Pointer(GtkWidgetRealize) := GetProcedureAddress(GtkLib, 'gtk_widget_realize');
  Pointer(GtkWindowSetDecorated) := GetProcedureAddress(GtkLib, 'gtk_window_set_decorated');
  Pointer(GtkWindowSetTransientFor) := GetProcedureAddress(GtkLib, 'gtk_window_set_transient_for');
  Pointer(GtkWindowSetSkipTaskbarHint) := GetProcedureAddress(GtkLib, 'gtk_window_set_skip_taskbar_hint');
  Pointer(GtkWindowGetDecorated) := GetProcedureAddress(GtkLib, 'gtk_window_get_decorated');
  Pointer(GtkWindowGetTitlebar) := GetProcedureAddress(GtkLib, 'gtk_window_get_titlebar');
  Pointer(GtkWindowMove) := GetProcedureAddress(GtkLib, 'gtk_window_move');
  Pointer(GtkWindowResize) := GetProcedureAddress(GtkLib, 'gtk_window_resize');
  Pointer(GtkWindowSetKeepAbove) := GetProcedureAddress(GtkLib, 'gtk_window_set_keep_above');
  Pointer(GtkGetCurrentEventFn) := GetProcedureAddress(GtkLib, 'gtk_get_current_event');
  Pointer(GtkGetCurrentEventTimeFn) := GetProcedureAddress(GtkLib, 'gtk_get_current_event_time');
  Pointer(GdkEventFreeFn) := GetProcedureAddress(GdkLib, 'gdk_event_free');
  Pointer(GdkEventGetRootCoordsFn) := GetProcedureAddress(GdkLib, 'gdk_event_get_root_coords');
  Pointer(GdkDisplayGetDefaultSeatFn) := GetProcedureAddress(GdkLib, 'gdk_display_get_default_seat');
  Pointer(GdkSeatGrabFn) := GetProcedureAddress(GdkLib, 'gdk_seat_grab');
  Pointer(GdkSeatUngrabFn) := GetProcedureAddress(GdkLib, 'gdk_seat_ungrab');
  Pointer(GdkPointerGrabFn) := GetProcedureAddress(GdkLib, 'gdk_pointer_grab');
  Pointer(GdkPointerUngrabFn) := GetProcedureAddress(GdkLib, 'gdk_pointer_ungrab');
  Pointer(GdkWindowSetDecorations) := GetProcedureAddress(GdkLib, 'gdk_window_set_decorations');
  Pointer(GdkWindowRaiseFn) := GetProcedureAddress(GdkLib, 'gdk_window_raise');
  Pointer(GdkWindowGetOrigin) := GetProcedureAddress(GdkLib, 'gdk_window_get_origin');
  Pointer(GdkWindowGetWidth) := GetProcedureAddress(GdkLib, 'gdk_window_get_width');
  Pointer(GdkWindowGetHeight) := GetProcedureAddress(GdkLib, 'gdk_window_get_height');
  Pointer(GdkWindowGetState) := GetProcedureAddress(GdkLib, 'gdk_window_get_state');
  Pointer(GdkWindowGetScaleFactorFn) := GetProcedureAddress(GdkLib, 'gdk_window_get_scale_factor');
  Pointer(GtkWidgetGetScaleFactorFn) := GetProcedureAddress(GtkLib, 'gtk_widget_get_scale_factor');
  Pointer(GdkScreenGetDefaultFn) := GetProcedureAddress(GdkLib, 'gdk_screen_get_default');
  Pointer(GdkScreenGetResolutionFn) := GetProcedureAddress(GdkLib, 'gdk_screen_get_resolution');
  Pointer(GdkWindowGetDisplay) := GetProcedureAddress(GdkLib, 'gdk_window_get_display');
  Pointer(GdkDisplayGetDefaultFn) := GetProcedureAddress(GdkLib, 'gdk_display_get_default');
  Pointer(GdkDisplayGetNameFn) := GetProcedureAddress(GdkLib, 'gdk_display_get_name');
  if GObjLib <> 0 then
    Pointer(GTypeNameFn) := GetProcedureAddress(GObjLib, 'g_type_name');
  GdkReady := Assigned(GtkWidgetGetWindow) and Assigned(GdkWindowGetDisplay) and
              Assigned(GdkDisplayGetDefaultFn);
  Result := GdkReady;
end;

function EnsureX11: Boolean;
begin
  if X11Tried then Exit(X11Ready);
  X11Tried := True;
  if not EnsureGdk then Exit(False);
  X11Lib := LoadLibrary('libX11.so.6');
  XextLib := LoadLibrary('libXext.so.6');
  if X11Lib = 0 then Exit(False);
  Pointer(GdkX11WindowGetXid) := GetProcedureAddress(GdkLib, 'gdk_x11_window_get_xid');
  Pointer(GdkX11DisplayGetXdisplay) :=
    GetProcedureAddress(GdkLib, 'gdk_x11_display_get_xdisplay');
  Pointer(XInternAtomFn) := GetProcedureAddress(X11Lib, 'XInternAtom');
  Pointer(XFlushFn) := GetProcedureAddress(X11Lib, 'XFlush');
  Pointer(XMoveWindowFn) := GetProcedureAddress(X11Lib, 'XMoveWindow');
  Pointer(XSetTransientForHintFn) := GetProcedureAddress(X11Lib, 'XSetTransientForHint');
  Pointer(XChangePropertyFn) := GetProcedureAddress(X11Lib, 'XChangeProperty');
  Pointer(XGetWindowPropertyFn) := GetProcedureAddress(X11Lib, 'XGetWindowProperty');
  Pointer(XFreeFn) := GetProcedureAddress(X11Lib, 'XFree');
  Pointer(XGetGeometryFn) := GetProcedureAddress(X11Lib, 'XGetGeometry');
  if XextLib <> 0 then
    Pointer(XShapeCombineRectanglesFn) :=
      GetProcedureAddress(XextLib, 'XShapeCombineRectangles');
  X11Ready := Assigned(GdkX11WindowGetXid) and Assigned(GdkX11DisplayGetXdisplay) and
              Assigned(XInternAtomFn);
  Result := X11Ready;
end;

function TypeNameOfGObject(Obj: Pointer): string;
var
  klass: Pointer;
  gt: PtrUInt;
  n: PAnsiChar;
begin
  Result := '';
  if (Obj = nil) or not Assigned(GTypeNameFn) then Exit;
  klass := PPointer(Obj)^;
  if klass = nil then Exit;
  gt := PPtrUInt(klass)^;
  n := GTypeNameFn(gt);
  if n <> nil then
    Result := string(n);
end;

function GdkNameOf(gd: TGdkDisplay): string;
var
  n: PAnsiChar;
begin
  Result := '';
  if (gd = nil) or not Assigned(GdkDisplayGetNameFn) then Exit;
  n := GdkDisplayGetNameFn(gd);
  if n <> nil then
    Result := string(n);
end;

function DisplayIsX11(gd: TGdkDisplay): Boolean;
var
  tn, dn: string;
begin
  Result := False;
  if gd = nil then Exit;
  tn := TypeNameOfGObject(gd);
  if tn <> '' then
    Exit(Pos('X11', tn) > 0);
  dn := GdkNameOf(gd);
  if dn = '' then Exit;
  Result := Pos('wayland', LowerCase(dn)) = 0;
end;

function InferBackendFromEnv: TPlatformWindowBackend;
begin
  if GetEnvironmentVariable('WAYLAND_DISPLAY') <> '' then
    Result := pwbWayland
  else if GetEnvironmentVariable('DISPLAY') <> '' then
    Result := pwbX11
  else
    Result := pwbUnknown;
end;

function QueryPlatformWindowBackend: TPlatformWindowBackend;
var
  gd: TGdkDisplay;
  tn, dn: string;
begin
  if BackendQueried then
    Exit(CachedBackend);
  BackendQueried := True;
  Result := pwbUnknown;
  CachedGdkName := '';
  if not EnsureGdk then
  begin
    Result := InferBackendFromEnv;
    CachedBackend := Result;
    Exit;
  end;
  gd := GdkDisplayGetDefaultFn();
  if gd = nil then
  begin
    Result := InferBackendFromEnv;
    CachedBackend := Result;
    Exit;
  end;
  CachedGdkName := GdkNameOf(gd);
  tn := TypeNameOfGObject(gd);
  if Pos('Wayland', tn) > 0 then
    Result := pwbWayland
  else if Pos('X11', tn) > 0 then
    Result := pwbX11
  else
  begin
    dn := CachedGdkName;
    if Pos('wayland', LowerCase(dn)) > 0 then
      Result := pwbWayland
    else if dn <> '' then
      Result := pwbX11
    else
      Result := pwbOther;
  end;
  CachedBackend := Result;
end;

function PlatformBackendName: string;
begin
  Result := BackendToName(QueryPlatformWindowBackend);
end;

function PlatformGdkDisplayName: string;
begin
  QueryPlatformWindowBackend;
  Result := CachedGdkName;
end;

function PlatformShapeSupported: Boolean;
begin
  Result := (QueryPlatformWindowBackend = pwbX11) and EnsureX11 and
            Assigned(XShapeCombineRectanglesFn);
end;

function PlatformAlwaysOnTopNative: Boolean;
begin
  Result := QueryPlatformWindowBackend = pwbX11;
end;

function GtkWidgetFromLCLHandle(AHandle: HWND): Pointer;
begin
  Result := nil;
  if AHandle = 0 then Exit;
{$IFDEF LCLGTK3}
  if not TGtk3Widget(AHandle).IsValidHandle then Exit;
  Result := Pointer(TGtk3Widget(AHandle).Widget);
{$ELSE}
  Result := Pointer(AHandle);
{$ENDIF}
end;

function GdkWindowFromLCLHandle(AHandle: HWND): TGdkWindow;
{$IFDEF LCLGTK3}
var
  W: TGtk3Widget;
  Widget: Pointer;
{$ENDIF}
begin
  Result := nil;
  if AHandle = 0 then Exit;
  if not EnsureGdk then Exit;
{$IFDEF LCLGTK3}
  // LCL GTK3：Handle = TGtk3Widget，.Widget 才是 GtkWidget*。
  W := TGtk3Widget(AHandle);
  if not W.IsValidHandle then Exit;
  Widget := Pointer(W.Widget);
  Result := TGdkWindow(Pointer(W.GetWindow));
  if (Result = nil) and Assigned(GtkWidgetRealize) and (Widget <> nil) then
  begin
    GtkWidgetRealize(Widget);
    Result := TGdkWindow(Pointer(W.GetWindow));
  end;
  if (Result = nil) and Assigned(GtkWidgetGetWindow) and (Widget <> nil) then
    Result := GtkWidgetGetWindow(Widget);
{$ELSE}
  // LCL GTK2：Handle 本身就是 GtkWidget*。
  if Assigned(GtkWidgetGetWindow) then
    Result := GtkWidgetGetWindow(Pointer(AHandle));
{$ENDIF}
end;

function XidFromHandle(AHandle: HWND; out Dpy: PDisplay): TXID;
var
  gw: TGdkWindow;
  gd: TGdkDisplay;
begin
  Result := 0;
  Dpy := nil;
  if AHandle = 0 then Exit;
  if QueryPlatformWindowBackend <> pwbX11 then Exit;
  if not EnsureX11 then Exit;
  gw := GdkWindowFromLCLHandle(AHandle);
  if gw = nil then Exit;
  gd := GdkWindowGetDisplay(gw);
  if not DisplayIsX11(gd) then Exit;
  Result := GdkX11WindowGetXid(gw);
  if gd <> nil then
    Dpy := GdkX11DisplayGetXdisplay(gd);
end;

procedure ApplyMotifNoDecorations(AHandle: HWND);
const
  PropModeReplace = 0;
  MwmHintsDecorations = 2;
var
  dpy: PDisplay;
  win: TXID;
  atom: Cardinal;
  hints: array[0..4] of PtrUInt;
begin
  if QueryPlatformWindowBackend <> pwbX11 then Exit;
  if not EnsureX11 then Exit;
  if not Assigned(XChangePropertyFn) then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) then Exit;
  FillChar(hints, SizeOf(hints), 0);
  hints[0] := MwmHintsDecorations;
  hints[2] := 0;
  atom := XInternAtomFn(dpy, '_MOTIF_WM_HINTS', 0);
  if atom = 0 then Exit;
  XChangePropertyFn(dpy, win, atom, atom, 32, PropModeReplace, @hints[0], 5);
  if Assigned(XFlushFn) then
    XFlushFn(dpy);
end;

procedure ConfigurePlatformWindow(AForm: TCustomForm);
var
  Widget: Pointer;
  gw: TGdkWindow;
begin
  if AForm = nil then Exit;
  if AForm.BorderStyle <> bsNone then Exit;
  if not AForm.HandleAllocated then Exit;
  if not EnsureGdk then Exit;
  Widget := GtkWidgetFromLCLHandle(AForm.Handle);
  if Widget = nil then Exit;
  // 不要 gtk_window_set_titlebar(nil)：GTK3 会恢复默认 CSD 标题栏。
  if Assigned(GtkWindowSetDecorated) then
    GtkWindowSetDecorated(Widget, 0);
  gw := GdkWindowFromLCLHandle(AForm.Handle);
  if (gw <> nil) and Assigned(GdkWindowSetDecorations) then
    GdkWindowSetDecorations(gw, 0);
  ApplyMotifNoDecorations(AForm.Handle);
  if Assigned(GtkWindowResize) and (AForm.Width > 0) and (AForm.Height > 0) then
    GtkWindowResize(Widget, AForm.Width, AForm.Height);
  if AForm.PopupParent <> nil then
    BindWindowToOwner(AForm, AForm.PopupParent);
end;

procedure BindWindowToOwner(AForm, AOwner: TCustomForm);
var
  childW, ownerW: Pointer;
  dpy: PDisplay;
  childX, ownerX: TXID;
begin
  if (AForm = nil) or (AOwner = nil) or (AForm = AOwner) then Exit;
  if not AForm.HandleAllocated or not AOwner.HandleAllocated then Exit;
  if not EnsureGdk then Exit;
  childW := GtkWidgetFromLCLHandle(AForm.Handle);
  ownerW := GtkWidgetFromLCLHandle(AOwner.Handle);
  if (childW <> nil) and (ownerW <> nil) then
  begin
    if Assigned(GtkWindowSetTransientFor) then
      GtkWindowSetTransientFor(childW, ownerW);
    if Assigned(GtkWindowSetSkipTaskbarHint) then
      GtkWindowSetSkipTaskbarHint(childW, 1);
  end;
  if QueryPlatformWindowBackend = pwbX11 then
  begin
    childX := XidFromHandle(AForm.Handle, dpy);
    ownerX := XidFromHandle(AOwner.Handle, dpy);
    if (childX <> 0) and (ownerX <> 0) and Assigned(XSetTransientForHintFn) then
    begin
      XSetTransientForHintFn(dpy, childX, ownerX);
      if Assigned(XFlushFn) then
        XFlushFn(dpy);
    end;
  end;
end;

procedure PrepareAuxOwnedWindow(AForm, AOwner: TCustomForm);
begin
  if (AForm = nil) or (AOwner = nil) or (AForm = AOwner) then Exit;
  AForm.ShowInTaskBar := stNever;
  AForm.PopupMode := pmExplicit;
  AForm.PopupParent := AOwner;
  if AForm.HandleAllocated then
    BindWindowToOwner(AForm, AOwner);
end;

procedure RaiseWindowKeepFocus(AForm: TCustomForm);
var
  gw: TGdkWindow;
begin
  if (AForm = nil) or not AForm.Visible then Exit;
  if not AForm.HandleAllocated then Exit;
  if AForm.WindowState = wsMinimized then
    AForm.WindowState := wsNormal;
  if not EnsureGdk then Exit;
  gw := GdkWindowFromLCLHandle(AForm.Handle);
  if (gw <> nil) and Assigned(GdkWindowRaiseFn) then
    GdkWindowRaiseFn(gw);
end;

procedure RaiseOwnedGroup(AOwner, AKeepFocus: TCustomForm);
var
  i: Integer;
  f: TCustomForm;
begin
  if (AOwner = nil) or RaisingOwnedGroup then Exit;
  RaisingOwnedGroup := True;
  try
    RaiseWindowKeepFocus(AOwner);
    for i := 0 to Screen.CustomFormCount - 1 do
    begin
      f := Screen.CustomForms[i];
      if (f = nil) or (f = AOwner) then Continue;
      if f.PopupParent = AOwner then
        RaiseWindowKeepFocus(f);
    end;
    if (AKeepFocus <> nil) and (AKeepFocus <> AOwner) then
      RaiseWindowKeepFocus(AKeepFocus);
  finally
    RaisingOwnedGroup := False;
  end;
end;

function PlatformWindowIsDecorated(AHandle: HWND): Boolean;
var
  Widget: Pointer;
begin
  Result := False;
  if AHandle = 0 then Exit;
  if not EnsureGdk then Exit;
  Widget := GtkWidgetFromLCLHandle(AHandle);
  if (Widget = nil) or not Assigned(GtkWindowGetDecorated) then Exit;
  Result := GtkWindowGetDecorated(Widget) <> 0;
end;

function PlatformWindowHasTitlebar(AHandle: HWND): Boolean;
var
  Widget: Pointer;
begin
  Result := False;
  if AHandle = 0 then Exit;
  if not EnsureGdk then Exit;
  Widget := GtkWidgetFromLCLHandle(AHandle);
  if (Widget = nil) or not Assigned(GtkWindowGetTitlebar) then Exit;
  Result := GtkWindowGetTitlebar(Widget) <> nil;
end;

function EwmhHasAbove(AHandle: HWND): Boolean;
var
  dpy: PDisplay;
  win: TXID;
  stateAtom, aboveAtom, actualType: PtrUInt;
  actualFormat: Integer;
  nitems, bytesAfter: PtrUInt;
  prop: Pointer;
  atoms: PPtrUInt;
  i: Integer;
begin
  Result := False;
  if QueryPlatformWindowBackend <> pwbX11 then Exit;
  if not EnsureX11 then Exit;
  if not Assigned(XGetWindowPropertyFn) then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) then Exit;
  stateAtom := XInternAtomFn(dpy, '_NET_WM_STATE', 0);
  aboveAtom := XInternAtomFn(dpy, '_NET_WM_STATE_ABOVE', 0);
  if (stateAtom = 0) or (aboveAtom = 0) then Exit;
  actualType := 0;
  actualFormat := 0;
  nitems := 0;
  bytesAfter := 0;
  prop := nil;
  if XGetWindowPropertyFn(dpy, win, stateAtom, 0, 64, 0, 0,
    @actualType, @actualFormat, @nitems, @bytesAfter, @prop) <> 0 then
    Exit;
  if (prop <> nil) and (nitems > 0) then
  begin
    atoms := PPtrUInt(prop);
    for i := 0 to Integer(nitems) - 1 do
      if atoms[i] = aboveAtom then
      begin
        Result := True;
        Break;
      end;
  end;
  if (prop <> nil) and Assigned(XFreeFn) then
    XFreeFn(prop);
end;

function PlatformWindowIsAbove(AHandle: HWND): Boolean;
const
  GDK_WINDOW_STATE_ABOVE = 64; // 1 shl 6
var
  gw: TGdkWindow;
begin
  Result := False;
  if AHandle = 0 then Exit;
  if not EnsureGdk then Exit;
  gw := GdkWindowFromLCLHandle(AHandle);
  if (gw <> nil) and Assigned(GdkWindowGetState) then
  begin
    if (GdkWindowGetState(gw) and GDK_WINDOW_STATE_ABOVE) <> 0 then
      Exit(True);
  end;
  Result := EwmhHasAbove(AHandle);
end;

function PlatformGetWindowRect(AHandle: HWND; out R: TRect): Boolean;
var
  gw: TGdkWindow;
  ox, oy: LongInt;
  ww, hh: Integer;
begin
  Result := False;
  R := Rect(0, 0, 0, 0);
  if AHandle = 0 then Exit;
  if not EnsureGdk then Exit;
  gw := GdkWindowFromLCLHandle(AHandle);
  if gw = nil then Exit;
  ox := 0;
  oy := 0;
  if Assigned(GdkWindowGetOrigin) then
    GdkWindowGetOrigin(gw, ox, oy);
  ww := 0;
  hh := 0;
  if Assigned(GdkWindowGetWidth) then
    ww := GdkWindowGetWidth(gw);
  if Assigned(GdkWindowGetHeight) then
    hh := GdkWindowGetHeight(gw);
  if (ww <= 0) or (hh <= 0) then Exit;
  R := Bounds(ox, oy, ww, hh);
  Result := True;
end;

procedure PlatformMoveWindow(AHandle: HWND; AX, AY: Integer);
var
  Widget: Pointer;
  dpy: PDisplay;
  win: TXID;
begin
  if AHandle = 0 then Exit;
  // 只走 gtk_window_move。再 XMoveWindow 会和 GTK/WM 抢位置，
  // 配合 CSD 尺寸比会把坐标指数放大到 SmallInt 溢出。
  Widget := GtkWidgetFromLCLHandle(AHandle);
  if (Widget <> nil) and Assigned(GtkWindowMove) then
  begin
    GtkWindowMove(Widget, AX, AY);
    // WSLg XWayland 上不 flush 的 move 会积在 GDK 队列里，拖动看起来“粘”。
    if EnsureX11 and Assigned(XFlushFn) then
    begin
      win := XidFromHandle(AHandle, dpy);
      if (dpy <> nil) then
        XFlushFn(dpy);
    end;
    Exit;
  end;
  if QueryPlatformWindowBackend <> pwbX11 then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) or not Assigned(XMoveWindowFn) then Exit;
  XMoveWindowFn(dpy, win, AX, AY);
  if Assigned(XFlushFn) then
    XFlushFn(dpy);
end;

procedure PlatformBeginLiveSize(AHandle: HWND);
begin
  if AHandle = 0 then ;
end;

procedure PlatformEndLiveSize(AHandle: HWND);
begin
  if AHandle = 0 then ;
end;

function CurrentEventTime: LongWord;
begin
  Result := 0;
  if Assigned(GtkGetCurrentEventTimeFn) then
    Result := GtkGetCurrentEventTimeFn();
end;

procedure PlatformUngrabPointer;
begin
  if not PointerGrabbed then Exit;
  if (GrabbedSeat <> nil) and Assigned(GdkSeatUngrabFn) then
    GdkSeatUngrabFn(GrabbedSeat)
  else if Assigned(GdkPointerUngrabFn) then
    GdkPointerUngrabFn(CurrentEventTime);
  GrabbedSeat := nil;
  PointerGrabbed := False;
end;

function PlatformGrabPointer(AHandle: HWND): Boolean;
const
  GDK_SEAT_CAPABILITY_ALL_POINTING = 7;
  GDK_GRAB_SUCCESS = 0;
  GDK_POINTER_MOTION_MASK = 1 shl 2;
  GDK_BUTTON_MOTION_MASK = 1 shl 4;
  GDK_BUTTON1_MOTION_MASK = 1 shl 5;
  GDK_BUTTON_PRESS_MASK = 1 shl 8;
  GDK_BUTTON_RELEASE_MASK = 1 shl 9;
  PointerEventMask = GDK_POINTER_MOTION_MASK or GDK_BUTTON_MOTION_MASK or
    GDK_BUTTON1_MOTION_MASK or GDK_BUTTON_PRESS_MASK or GDK_BUTTON_RELEASE_MASK;
var
  gw: TGdkWindow;
  gd: TGdkDisplay;
  seat, ev: Pointer;
  st: Integer;
begin
  Result := False;
  PlatformUngrabPointer;
  if AHandle = 0 then Exit;
  if not EnsureGdk then Exit;
  gw := GdkWindowFromLCLHandle(AHandle);
  if gw = nil then Exit;
  ev := nil;
  if Assigned(GtkGetCurrentEventFn) then
    ev := GtkGetCurrentEventFn();
  try
    seat := nil;
    gd := nil;
    if Assigned(GdkDisplayGetDefaultFn) then
      gd := GdkDisplayGetDefaultFn();
    if Assigned(GdkDisplayGetDefaultSeatFn) and (gd <> nil) then
      seat := GdkDisplayGetDefaultSeatFn(gd);
    if (seat <> nil) and Assigned(GdkSeatGrabFn) then
    begin
      st := GdkSeatGrabFn(seat, gw, GDK_SEAT_CAPABILITY_ALL_POINTING,
        0, nil, ev, nil, nil);
      if st = GDK_GRAB_SUCCESS then
      begin
        GrabbedSeat := seat;
        PointerGrabbed := True;
        Exit(True);
      end;
    end;
    if Assigned(GdkPointerGrabFn) then
    begin
      st := GdkPointerGrabFn(gw, 0, PointerEventMask, nil, nil, CurrentEventTime);
      if st = GDK_GRAB_SUCCESS then
      begin
        GrabbedSeat := nil;
        PointerGrabbed := True;
        Exit(True);
      end;
    end;
  finally
    if (ev <> nil) and Assigned(GdkEventFreeFn) then
      GdkEventFreeFn(ev);
  end;
end;

function PlatformGetPointerRoot(out X, Y: Integer): Boolean;
var
  ev: Pointer;
  rx, ry: Double;
begin
  Result := False;
  X := 0;
  Y := 0;
  if not EnsureGdk then Exit;
  if not Assigned(GtkGetCurrentEventFn) or not Assigned(GdkEventGetRootCoordsFn) then
    Exit;
  ev := GtkGetCurrentEventFn();
  if ev = nil then Exit;
  try
    rx := 0;
    ry := 0;
    if GdkEventGetRootCoordsFn(ev, rx, ry) <> 0 then
    begin
      X := Round(rx);
      Y := Round(ry);
      Result := True;
    end;
  finally
    if Assigned(GdkEventFreeFn) then
      GdkEventFreeFn(ev);
  end;
end;

function PlatformGdkScaleFactor(AHandle: HWND): Integer;
var
  gw: TGdkWindow;
  Widget: Pointer;
  envS: string;
  envN, code: Integer;
begin
  Result := 1;
  if not EnsureGdk then Exit;
  gw := GdkWindowFromLCLHandle(AHandle);
  if (gw <> nil) and Assigned(GdkWindowGetScaleFactorFn) then
  begin
    Result := GdkWindowGetScaleFactorFn(gw);
    if Result < 1 then Result := 1;
    Exit;
  end;
  Widget := GtkWidgetFromLCLHandle(AHandle);
  if (Widget <> nil) and Assigned(GtkWidgetGetScaleFactorFn) then
  begin
    Result := GtkWidgetGetScaleFactorFn(Widget);
    if Result < 1 then Result := 1;
    Exit;
  end;
  envS := GetEnvironmentVariable('GDK_SCALE');
  if envS <> '' then
  begin
    Val(envS, envN, code);
    if (code = 0) and (envN >= 1) then
      Result := envN;
  end;
end;

function PlatformXWindowSize(AHandle: HWND; out W, H: Integer): Boolean;
var
  dpy: PDisplay;
  win, root: TXID;
  x, y: Integer;
  width, height, bw, depth: Cardinal;
begin
  Result := False;
  W := 0;
  H := 0;
  if not EnsureX11 or not Assigned(XGetGeometryFn) then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) then Exit;
  root := 0;
  x := 0;
  y := 0;
  width := 0;
  height := 0;
  bw := 0;
  depth := 0;
  if XGetGeometryFn(dpy, win, root, x, y, width, height, bw, depth) = 0 then
    Exit;
  W := Integer(width);
  H := Integer(height);
  Result := (W > 0) and (H > 0);
end;

function PlatformWindowScale(AHandle: HWND; LogicalW, LogicalH: Integer): Double;
var
  wr: TRect;
  sizeScale: Double;
  gdk: Integer;
  nw, nh, xw, xh: Integer;
begin
  Result := 1.0;
  nw := 0;
  nh := 0;
  // X 窗口像素才是 Shape 坐标系；GDK get_width 在 GDK_SCALE>1 时可能仍是逻辑尺寸。
  if PlatformXWindowSize(AHandle, xw, xh) then
  begin
    sizeScale := WindowScaleFromSizes(LogicalW, LogicalH, xw, xh);
    if sizeScale > 1.0001 then
      Exit(sizeScale);
    nw := xw;
    nh := xh;
  end;
  wr := Rect(0, 0, 0, 0);
  if PlatformGetWindowRect(AHandle, wr) then
  begin
    nw := wr.Right - wr.Left;
    nh := wr.Bottom - wr.Top;
    sizeScale := WindowScaleFromSizes(LogicalW, LogicalH, nw, nh);
    if sizeScale > 1.0001 then
      Exit(sizeScale);
  end;
  gdk := PlatformGdkScaleFactor(AHandle);
  if gdk <= 1 then Exit;
  if (nw > 0) and (nh > 0) then
    Exit(1.0);
  Result := gdk;
end;

function PlatformPixelsPerInch: Integer;
var
  scr: Pointer;
  res: Double;
begin
  Result := 96;
  if not EnsureGdk then Exit;
  if not Assigned(GdkScreenGetDefaultFn) or not Assigned(GdkScreenGetResolutionFn) then
    Exit;
  scr := GdkScreenGetDefaultFn();
  if scr = nil then Exit;
  res := GdkScreenGetResolutionFn(scr);
  if res >= 48 then
    Result := Round(res);
end;

procedure ApplyShapeRects(AHandle: HWND; const Rects: TShapeRectArray;
  LogicalW, LogicalH: Integer; Redraw: Boolean = True);
const
  ShapeBounding = 0;
  ShapeSet = 0;
  Unsorted = 0;
var
  scaled: TShapeRectArray;
  xrects: array of TXRectangle;
  i, n: Integer;
  dpy: PDisplay;
  win: TXID;
  scale: Double;
begin
  if not PlatformShapeSupported then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) then Exit;
  scaled := Rects;
  if (LogicalW > 0) and (LogicalH > 0) then
  begin
    scale := PlatformWindowScale(AHandle, LogicalW, LogicalH);
    if scale > 1.0001 then
      scaled := ScaleShapeRects(Rects, scale, scale);
  end;
  n := Length(scaled);
  SetLength(xrects, n);
  for i := 0 to n - 1 do
  begin
    xrects[i].x := SmallInt(scaled[i].X);
    xrects[i].y := SmallInt(scaled[i].Y);
    xrects[i].width := Word(scaled[i].W);
    xrects[i].height := Word(scaled[i].H);
  end;
  if n = 0 then
    XShapeCombineRectanglesFn(dpy, win, ShapeBounding, 0, 0, nil, 0, ShapeSet, Unsorted)
  else
    XShapeCombineRectanglesFn(dpy, win, ShapeBounding, 0, 0, @xrects[0], n,
      ShapeSet, Unsorted);
  if Assigned(XFlushFn) then
    XFlushFn(dpy);
  if Redraw then ;
end;

procedure ApplyAlphaShape(AHandle: HWND; Bitmap: TBGRABitmap);
begin
  if (AHandle = 0) or (Bitmap = nil) then Exit;
  ApplyShapeRects(AHandle, AlphaRunRects(Bitmap), Bitmap.Width, Bitmap.Height);
end;

procedure ApplyRectShape(AHandle: HWND; AWidth, AHeight: Integer);
const
  ShapeBounding = 0;
  ShapeSet = 0;
  Unsorted = 0;
var
  dpy: PDisplay;
  win: TXID;
  r: TXRectangle;
  scale: Double;
  rw, rh: Integer;
begin
  if not PlatformShapeSupported then Exit;
  if (AWidth < 1) or (AHeight < 1) then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) then Exit;
  scale := PlatformWindowScale(AHandle, AWidth, AHeight);
  rw := AWidth;
  rh := AHeight;
  if scale > 1.0001 then
  begin
    rw := Round(AWidth * scale);
    rh := Round(AHeight * scale);
    if rw < 1 then rw := 1;
    if rh < 1 then rh := 1;
  end;
  r.x := 0;
  r.y := 0;
  r.width := Word(rw);
  r.height := Word(rh);
  XShapeCombineRectanglesFn(dpy, win, ShapeBounding, 0, 0, @r, 1, ShapeSet, Unsorted);
  if Assigned(XFlushFn) then
    XFlushFn(dpy);
end;

procedure ClearWindowShape(AHandle: HWND);
const
  ShapeBounding = 0;
  ShapeSet = 0;
  Unsorted = 0;
var
  dpy: PDisplay;
  win: TXID;
  r: TXRectangle;
begin
  if not PlatformShapeSupported then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) then Exit;
  r.x := 0;
  r.y := 0;
  r.width := 32767;
  r.height := 32767;
  XShapeCombineRectanglesFn(dpy, win, ShapeBounding, 0, 0, @r, 1, ShapeSet, Unsorted);
  if Assigned(XFlushFn) then
    XFlushFn(dpy);
end;

procedure SetWindowAlwaysOnTop(AForm: TCustomForm; Enable: Boolean);
var
  Widget: Pointer;
begin
  if AForm = nil then Exit;
  if Enable then
    AForm.FormStyle := fsStayOnTop
  else
    AForm.FormStyle := fsNormal;
  if not AForm.HandleAllocated then Exit;
  // 用 GTK 发 EWMH，不要手写 XClientMessageEvent：64 位布局不对会
  // XSendEvent BadValue，GDK 直接把进程杀掉。
  if not EnsureGdk then Exit;
  if Assigned(GtkWindowSetKeepAbove) then
  begin
    Widget := GtkWidgetFromLCLHandle(AForm.Handle);
    if Widget <> nil then
      GtkWindowSetKeepAbove(Widget, Ord(Enable));
  end;
end;

{$ENDIF}

end.
