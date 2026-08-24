unit UPlatformWindow;

{$mode objfpc}{$H+}

// 平台窗口原语，隔离 Windows / X11 差异（docs/lazarus-rewrite.md GTK3 绕行）。
//   ApplyAlphaShape     — 由位图 alpha 生成异形窗口
//   SetWindowAlwaysOnTop — 置顶（Win: HWND_TOPMOST；X11: EWMH _NET_WM_STATE_ABOVE）
//
// Windows：SetWindowRgn + SetWindowPos。
// UNIX：dynload libX11/libXext/libgdk-3，XShapeCombineRectangles + ClientMessage。
// GTK3 LCL 的 Handle 是 GtkWidget*，经 gdk_x11_window_get_xid 取 XID。

interface

uses
  Classes, SysUtils, Forms, Controls, LCLType,
  BGRABitmap, BGRABitmapTypes;

type
  TShapeRect = record
    X, Y, W, H: Integer;
  end;
  TShapeRectArray = array of TShapeRect;

function AlphaRunRects(Bitmap: TBGRABitmap): TShapeRectArray;
procedure ApplyAlphaShape(AHandle: HWND; Bitmap: TBGRABitmap);
procedure ClearWindowShape(AHandle: HWND);
procedure SetWindowAlwaysOnTop(AForm: TCustomForm; Enable: Boolean);

implementation

uses
  LCLIntf
  {$IFDEF WINDOWS}, Windows{$ENDIF}
  {$IFDEF UNIX}, dynlibs{$ENDIF};

function AlphaRunRects(Bitmap: TBGRABitmap): TShapeRectArray;
var
  x, y, startX, w, h, n: Integer;
  p: PBGRAPixel;
begin
  SetLength(Result, 0);
  if Bitmap = nil then Exit;
  w := Bitmap.Width;
  h := Bitmap.Height;
  n := 0;
  for y := 0 to h - 1 do
  begin
    p := Bitmap.ScanLine[y];
    startX := -1;
    for x := 0 to w - 1 do
    begin
      if p^.alpha > 0 then
      begin
        if startX < 0 then startX := x;
      end
      else if startX >= 0 then
      begin
        SetLength(Result, n + 1);
        Result[n].X := startX;
        Result[n].Y := y;
        Result[n].W := x - startX;
        Result[n].H := 1;
        Inc(n);
        startX := -1;
      end;
      Inc(p);
    end;
    if startX >= 0 then
    begin
      SetLength(Result, n + 1);
      Result[n].X := startX;
      Result[n].Y := y;
      Result[n].W := w - startX;
      Result[n].H := 1;
      Inc(n);
    end;
  end;
end;

{$IFDEF WINDOWS}

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
  TGdkX11WindowGetXid = function(Window: TGdkWindow): TXID; cdecl;
  TGdkWindowGetDisplay = function(Window: TGdkWindow): TGdkDisplay; cdecl;
  TGdkX11DisplayGetXdisplay = function(Display: TGdkDisplay): PDisplay; cdecl;
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
  GtkLib, GdkLib, X11Lib, XextLib: TLibHandle;
  GtkWidgetGetWindow: TGtkWidgetGetWindow;
  GdkX11WindowGetXid: TGdkX11WindowGetXid;
  GdkWindowGetDisplay: TGdkWindowGetDisplay;
  GdkX11DisplayGetXdisplay: TGdkX11DisplayGetXdisplay;
  XInternAtomFn: TXInternAtom;
  XDefaultRootWindowFn: TXDefaultRootWindow;
  XFlushFn: TXFlush;
  XSendEventFn: TXSendEvent;
  XShapeCombineRectanglesFn: TXShapeCombineRectangles;
  X11Ready: Boolean = False;
  X11Tried: Boolean = False;

function EnsureX11: Boolean;
begin
  if X11Tried then Exit(X11Ready);
  X11Tried := True;
  GtkLib := LoadLibrary('libgtk-3.so.0');
  GdkLib := LoadLibrary('libgdk-3.so.0');
  X11Lib := LoadLibrary('libX11.so.6');
  XextLib := LoadLibrary('libXext.so.6');
  if (GtkLib = 0) or (GdkLib = 0) or (X11Lib = 0) then
    Exit(False);
  Pointer(GtkWidgetGetWindow) := GetProcedureAddress(GtkLib, 'gtk_widget_get_window');
  Pointer(GdkX11WindowGetXid) := GetProcedureAddress(GdkLib, 'gdk_x11_window_get_xid');
  Pointer(GdkWindowGetDisplay) := GetProcedureAddress(GdkLib, 'gdk_window_get_display');
  Pointer(GdkX11DisplayGetXdisplay) :=
    GetProcedureAddress(GdkLib, 'gdk_x11_display_get_xdisplay');
  Pointer(XInternAtomFn) := GetProcedureAddress(X11Lib, 'XInternAtom');
  Pointer(XDefaultRootWindowFn) := GetProcedureAddress(X11Lib, 'XDefaultRootWindow');
  Pointer(XFlushFn) := GetProcedureAddress(X11Lib, 'XFlush');
  Pointer(XSendEventFn) := GetProcedureAddress(X11Lib, 'XSendEvent');
  if XextLib <> 0 then
    Pointer(XShapeCombineRectanglesFn) :=
      GetProcedureAddress(XextLib, 'XShapeCombineRectangles');
  X11Ready := Assigned(GtkWidgetGetWindow) and Assigned(GdkX11WindowGetXid) and
              Assigned(GdkX11DisplayGetXdisplay) and Assigned(XInternAtomFn);
  Result := X11Ready;
end;

function XidFromHandle(AHandle: HWND; out Dpy: PDisplay): TXID;
var
  gw: TGdkWindow;
  gd: TGdkDisplay;
begin
  Result := 0;
  Dpy := nil;
  if (AHandle = 0) or not EnsureX11 then Exit;
  gw := GtkWidgetGetWindow(Pointer(AHandle));
  if gw = nil then Exit;
  Result := GdkX11WindowGetXid(gw);
  gd := GdkWindowGetDisplay(gw);
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
  if not EnsureX11 then Exit;
  if not Assigned(XShapeCombineRectanglesFn) then Exit;
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
  if not EnsureX11 then Exit;
  if not Assigned(XShapeCombineRectanglesFn) then Exit;
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
