unit UPlatformWindow;

{$mode objfpc}{$H+}

// 平台窗口原语，隔离 Windows / X11 / Wayland 差异（docs/lazarus-rewrite.md GTK3 绕行）。
//   ApplyAlphaShape     — 由位图 alpha 生成异形窗口
//   SetWindowAlwaysOnTop — 置顶（Win: HWND_TOPMOST；X11: EWMH _NET_WM_STATE_ABOVE）
//   QueryPlatformWindowBackend — win32 / x11 / wayland / other
//
// Windows：SetWindowRgn + SetWindowPos。
// UNIX：dynload libX11/libXext/libgdk-3。XShape / EWMH 仅在 GdkX11Display 上调用；
// Wayland GdkWindow 上调用 gdk_x11_window_get_xid 会触发 GLib-CRITICAL。
//
// LCL GTK3 的 HWND 是 TGtk3Widget 对象，不是 GtkWidget*（GTK2 才是）。
// 对 Handle 直接 gtk_widget_get_window 会 GTK_IS_WIDGET 失败，严重时 Access violation。

interface

uses
  Classes, SysUtils, Forms, Controls, LCLType,
  BGRABitmap, BGRABitmapTypes, UAlphaShape;

type
  TPlatformWindowBackend = (pwbUnknown, pwbWin32, pwbX11, pwbWayland, pwbOther);

function QueryPlatformWindowBackend: TPlatformWindowBackend;
function PlatformBackendName: string;
function PlatformGdkDisplayName: string;
function PlatformShapeSupported: Boolean;
function PlatformAlwaysOnTopNative: Boolean;

procedure ApplyAlphaShape(AHandle: HWND; Bitmap: TBGRABitmap);
procedure ClearWindowShape(AHandle: HWND);
procedure SetWindowAlwaysOnTop(AForm: TCustomForm; Enable: Boolean);

implementation

uses
  LCLIntf
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  {$IFDEF UNIX}, dynlibs{$ENDIF}
  {$IFDEF LCLGTK3}, Gtk3Widgets{$ENDIF};

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

procedure ApplyAlphaShape(AHandle: HWND; Bitmap: TBGRABitmap);
var
  rects: TShapeRectArray;
  totalRgn, rowRgn, segRgn: HRGN;
  i: Integer;
begin
  if (AHandle = 0) or (Bitmap = nil) then Exit;
  rects := AlphaRunRects(Bitmap);
  totalRgn := CreateRectRgn(0, 0, 0, 0);
  for i := 0 to High(rects) do
  begin
    segRgn := CreateRectRgn(rects[i].X, rects[i].Y,
      rects[i].X + rects[i].W, rects[i].Y + rects[i].H);
    rowRgn := CreateRectRgn(0, 0, 0, 0);
    CombineRgn(rowRgn, totalRgn, segRgn, RGN_OR);
    DeleteObject(totalRgn);
    DeleteObject(segRgn);
    totalRgn := rowRgn;
  end;
  SetWindowRgn(AHandle, totalRgn, True);
end;

procedure ClearWindowShape(AHandle: HWND);
begin
  if AHandle <> 0 then
    SetWindowRgn(AHandle, 0, True);
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
  TGdkX11WindowGetXid = function(Window: TGdkWindow): TXID; cdecl;
  TGdkWindowGetDisplay = function(Window: TGdkWindow): TGdkDisplay; cdecl;
  TGdkX11DisplayGetXdisplay = function(Display: TGdkDisplay): PDisplay; cdecl;
  TGdkDisplayGetDefault = function: TGdkDisplay; cdecl;
  TGdkDisplayGetName = function(Display: TGdkDisplay): PAnsiChar; cdecl;
  TGTypeName = function(AType: PtrUInt): PAnsiChar; cdecl;
  TXInternAtom = function(Display: PDisplay; Name: PAnsiChar;
    OnlyIfExists: Integer): Cardinal; cdecl;
  TXDefaultRootWindow = function(Display: PDisplay): TXID; cdecl;
  TXFlush = procedure(Display: PDisplay); cdecl;
  TXSendEvent = function(Display: PDisplay; W: TXID; Propagate: Integer;
    EventMask: LongInt; EventSend: Pointer): Integer; cdecl;
  TXShapeCombineRectangles = procedure(Display: PDisplay; Dest: TXID;
    DestKind, XOff, YOff: Integer; Rects: PXRectangle; NRects, Op, Ordering: Integer); cdecl;

  TXClientMessageEvent = record
    _type: Integer;
    serial: PtrUInt;
    send_event: Integer;
    display: PDisplay;
    window: TXID;
    message_type: Cardinal;
    format: Integer;
    data: array[0..4] of LongInt;
  end;

var
  GtkLib, GdkLib, GObjLib, X11Lib, XextLib: TLibHandle;
  GtkWidgetGetWindow: TGtkWidgetGetWindow;
  GtkWidgetRealize: TGtkWidgetRealize;
  GdkX11WindowGetXid: TGdkX11WindowGetXid;
  GdkWindowGetDisplay: TGdkWindowGetDisplay;
  GdkX11DisplayGetXdisplay: TGdkX11DisplayGetXdisplay;
  GdkDisplayGetDefaultFn: TGdkDisplayGetDefault;
  GdkDisplayGetNameFn: TGdkDisplayGetName;
  GTypeNameFn: TGTypeName;
  XInternAtomFn: TXInternAtom;
  XDefaultRootWindowFn: TXDefaultRootWindow;
  XFlushFn: TXFlush;
  XSendEventFn: TXSendEvent;
  XShapeCombineRectanglesFn: TXShapeCombineRectangles;
  GdkTried: Boolean = False;
  GdkReady: Boolean = False;
  X11Tried: Boolean = False;
  X11Ready: Boolean = False;
  BackendQueried: Boolean = False;
  CachedBackend: TPlatformWindowBackend = pwbUnknown;
  CachedGdkName: string = '';

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
  Pointer(XDefaultRootWindowFn) := GetProcedureAddress(X11Lib, 'XDefaultRootWindow');
  Pointer(XFlushFn) := GetProcedureAddress(X11Lib, 'XFlush');
  Pointer(XSendEventFn) := GetProcedureAddress(X11Lib, 'XSendEvent');
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

procedure ApplyAlphaShape(AHandle: HWND; Bitmap: TBGRABitmap);
const
  ShapeBounding = 0;
  ShapeSet = 0;
  Unsorted = 0;
var
  rects: TShapeRectArray;
  xrects: array of TXRectangle;
  i, n: Integer;
  dpy: PDisplay;
  win: TXID;
begin
  if not PlatformShapeSupported then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) or (Bitmap = nil) then Exit;
  rects := AlphaRunRects(Bitmap);
  n := Length(rects);
  SetLength(xrects, n);
  for i := 0 to n - 1 do
  begin
    xrects[i].x := SmallInt(rects[i].X);
    xrects[i].y := SmallInt(rects[i].Y);
    xrects[i].width := Word(rects[i].W);
    xrects[i].height := Word(rects[i].H);
  end;
  if n = 0 then
    XShapeCombineRectanglesFn(dpy, win, ShapeBounding, 0, 0, nil, 0, ShapeSet, Unsorted)
  else
    XShapeCombineRectanglesFn(dpy, win, ShapeBounding, 0, 0, @xrects[0], n,
      ShapeSet, Unsorted);
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
const
  ClientMessage = 33;
  SubstructureNotify = 1 shl 19;
  SubstructureRedirect = 1 shl 20;
  _NET_WM_STATE_REMOVE = 0;
  _NET_WM_STATE_ADD = 1;
var
  dpy: PDisplay;
  win, root: TXID;
  ev: TXClientMessageEvent;
  action: LongInt;
begin
  if AForm = nil then Exit;
  if Enable then
    AForm.FormStyle := fsStayOnTop
  else
    AForm.FormStyle := fsNormal;
  if not AForm.HandleAllocated then Exit;
  if QueryPlatformWindowBackend <> pwbX11 then Exit;
  win := XidFromHandle(AForm.Handle, dpy);
  if (win = 0) or (dpy = nil) then Exit;
  FillChar(ev, SizeOf(ev), 0);
  ev._type := ClientMessage;
  ev.display := dpy;
  ev.window := win;
  ev.message_type := XInternAtomFn(dpy, '_NET_WM_STATE', 0);
  ev.format := 32;
  if Enable then action := _NET_WM_STATE_ADD else action := _NET_WM_STATE_REMOVE;
  ev.data[0] := action;
  ev.data[1] := XInternAtomFn(dpy, '_NET_WM_STATE_ABOVE', 0);
  ev.data[2] := 0;
  ev.data[3] := 1;
  ev.data[4] := 0;
  root := XDefaultRootWindowFn(dpy);
  XSendEventFn(dpy, root, 0, SubstructureNotify or SubstructureRedirect, @ev);
  if Assigned(XFlushFn) then
    XFlushFn(dpy);
end;

{$ENDIF}

end.
