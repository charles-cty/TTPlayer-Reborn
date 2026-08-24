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

interface

uses
  Classes, SysUtils, Types, Forms, Controls, LCLType,
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
procedure ConfigurePlatformWindow(AForm: TCustomForm);
function PlatformGetWindowRect(AHandle: HWND; out R: TRect): Boolean;
procedure PlatformMoveWindow(AHandle: HWND; AX, AY: Integer);
function PlatformWindowIsDecorated(AHandle: HWND): Boolean;
function PlatformWindowHasTitlebar(AHandle: HWND): Boolean;
function PlatformWindowIsAbove(AHandle: HWND): Boolean;

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

procedure ConfigurePlatformWindow(AForm: TCustomForm);
begin
  if AForm = nil then Exit;
end;

function PlatformGetWindowRect(AHandle: HWND; out R: TRect): Boolean;
begin
  R := Rect(0, 0, 0, 0);
  Result := (AHandle <> 0) and (LCLIntf.GetWindowRect(AHandle, R) <> 0);
end;

procedure PlatformMoveWindow(AHandle: HWND; AX, AY: Integer);
begin
  if AHandle = 0 then Exit;
  Windows.SetWindowPos(AHandle, 0, AX, AY, 0, 0,
    SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
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
  TGtkWindowGetDecorated = function(Window: Pointer): LongInt; cdecl;
  TGtkWindowGetTitlebar = function(Window: Pointer): Pointer; cdecl;
  TGtkWindowMove = procedure(Window: Pointer; X, Y: LongInt); cdecl;
  TGtkWindowResize = procedure(Window: Pointer; Width, Height: LongInt); cdecl;
  TGtkWindowSetKeepAbove = procedure(Window: Pointer; Setting: LongInt); cdecl;
  TGdkWindowSetDecorations = procedure(Window: TGdkWindow; Decorations: LongWord); cdecl;
  TGdkWindowGetOrigin = function(Window: TGdkWindow; out X, Y: LongInt): Integer; cdecl;
  TGdkWindowGetWidth = function(Window: TGdkWindow): Integer; cdecl;
  TGdkWindowGetHeight = function(Window: TGdkWindow): Integer; cdecl;
  TGdkWindowGetState = function(Window: TGdkWindow): LongWord; cdecl;
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
  TXChangeProperty = function(Display: PDisplay; W: TXID;
    Prop, AType: Cardinal; Format, Mode: Integer; Data: Pointer;
    NElements: Integer): Integer; cdecl;
  TXGetWindowProperty = function(Display: PDisplay; W: TXID; Prop: PtrUInt;
    LongOffset, LongLength: PtrInt; Delete: Integer; ReqType: PtrUInt;
    ActualType: PPtrUInt; ActualFormat: PInteger;
    NItems, BytesAfter: PPtrUInt; PropReturn: PPointer): Integer; cdecl;
  TXFree = function(Data: Pointer): Integer; cdecl;
  TXShapeCombineRectangles = procedure(Display: PDisplay; Dest: TXID;
    DestKind, XOff, YOff: Integer; Rects: PXRectangle; NRects, Op, Ordering: Integer); cdecl;

var
  GtkLib, GdkLib, GObjLib, X11Lib, XextLib: TLibHandle;
  GtkWidgetGetWindow: TGtkWidgetGetWindow;
  GtkWidgetRealize: TGtkWidgetRealize;
  GtkWindowSetDecorated: TGtkWindowSetDecorated;
  GtkWindowGetDecorated: TGtkWindowGetDecorated;
  GtkWindowGetTitlebar: TGtkWindowGetTitlebar;
  GtkWindowMove: TGtkWindowMove;
  GtkWindowResize: TGtkWindowResize;
  GtkWindowSetKeepAbove: TGtkWindowSetKeepAbove;
  GdkWindowSetDecorations: TGdkWindowSetDecorations;
  GdkWindowGetOrigin: TGdkWindowGetOrigin;
  GdkWindowGetWidth: TGdkWindowGetWidth;
  GdkWindowGetHeight: TGdkWindowGetHeight;
  GdkWindowGetState: TGdkWindowGetState;
  GdkX11WindowGetXid: TGdkX11WindowGetXid;
  GdkWindowGetDisplay: TGdkWindowGetDisplay;
  GdkX11DisplayGetXdisplay: TGdkX11DisplayGetXdisplay;
  GdkDisplayGetDefaultFn: TGdkDisplayGetDefault;
  GdkDisplayGetNameFn: TGdkDisplayGetName;
  GTypeNameFn: TGTypeName;
  XInternAtomFn: TXInternAtom;
  XFlushFn: TXFlush;
  XMoveWindowFn: TXMoveWindow;
  XChangePropertyFn: TXChangeProperty;
  XGetWindowPropertyFn: TXGetWindowProperty;
  XFreeFn: TXFree;
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
  Pointer(GtkWindowSetDecorated) := GetProcedureAddress(GtkLib, 'gtk_window_set_decorated');
  Pointer(GtkWindowGetDecorated) := GetProcedureAddress(GtkLib, 'gtk_window_get_decorated');
  Pointer(GtkWindowGetTitlebar) := GetProcedureAddress(GtkLib, 'gtk_window_get_titlebar');
  Pointer(GtkWindowMove) := GetProcedureAddress(GtkLib, 'gtk_window_move');
  Pointer(GtkWindowResize) := GetProcedureAddress(GtkLib, 'gtk_window_resize');
  Pointer(GtkWindowSetKeepAbove) := GetProcedureAddress(GtkLib, 'gtk_window_set_keep_above');
  Pointer(GdkWindowSetDecorations) := GetProcedureAddress(GdkLib, 'gdk_window_set_decorations');
  Pointer(GdkWindowGetOrigin) := GetProcedureAddress(GdkLib, 'gdk_window_get_origin');
  Pointer(GdkWindowGetWidth) := GetProcedureAddress(GdkLib, 'gdk_window_get_width');
  Pointer(GdkWindowGetHeight) := GetProcedureAddress(GdkLib, 'gdk_window_get_height');
  Pointer(GdkWindowGetState) := GetProcedureAddress(GdkLib, 'gdk_window_get_state');
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
  Pointer(XChangePropertyFn) := GetProcedureAddress(X11Lib, 'XChangeProperty');
  Pointer(XGetWindowPropertyFn) := GetProcedureAddress(X11Lib, 'XGetWindowProperty');
  Pointer(XFreeFn) := GetProcedureAddress(X11Lib, 'XFree');
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
    Exit;
  end;
  if QueryPlatformWindowBackend <> pwbX11 then Exit;
  win := XidFromHandle(AHandle, dpy);
  if (win = 0) or (dpy = nil) or not Assigned(XMoveWindowFn) then Exit;
  XMoveWindowFn(dpy, win, AX, AY);
  if Assigned(XFlushFn) then
    XFlushFn(dpy);
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
