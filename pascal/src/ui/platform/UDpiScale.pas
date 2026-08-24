unit UDpiScale;

{$mode objfpc}{$H+}

// UI 缩放换算（无 LCL）。皮肤与吸附在逻辑像素里算；Shape / Win32
// GetWindowRect 在物理像素里。不能把 CSD 撑大的 native/LCL 比当成 DPI
// （GTK3 上会把坐标指数放大到 SmallInt 溢出）。
// 皮肤视图：ScalePx / ViewScaleFromDpi / MapClientToSkin；LCL 侧见 USkinView。
//
// 判别：宽高缩放须一致，且贴近 125/150/200% 等常见档；否则视为 1×。

interface

uses
  Classes, SysUtils, UAlphaShape;

function QuantizeUiScale(Raw: Double): Double;
function WindowScaleFromSizes(LogicalW, LogicalH, NativeW, NativeH: Integer): Double;
function LogicalFromNative(Native, LogicalExtent, NativeExtent: Integer): Integer;
function NativeFromLogical(Logical, LogicalExtent, NativeExtent: Integer): Integer;
function MapNativePosToLogical(NativePos, LclPos, LogicalExtent, NativeExtent: Integer): Integer;
function ScaleShapeRects(const Rects: TShapeRectArray; ScaleX, ScaleY: Double): TShapeRectArray;

// 皮肤视图缩放（LCL 客户区相对 1× 皮肤像素）。GTK 在 GDK_SCALE≥2 时
// 由 cairo 做设备缩放，LCL 仍用 1×，不要把皮肤再乘一遍。
function ScalePx(V: Integer; Scale: Double): Integer;
function ViewScaleFromDpi(Dpi: Integer): Double;
function MapClientToSkin(Client, ClientExtent, SkinExtent: Integer): Integer;
function MapSkinToClient(Skin, SkinExtent, ClientExtent: Integer): Integer;

implementation

uses
  Math;

const
  kUiScales: array[0..9] of Double = (
    1.0, 1.25, 4.0 / 3.0, 1.5, 1.75, 2.0, 2.25, 2.5, 3.0, 4.0);
  kQuantTol = 0.08;
  kAxisSkewTol = 0.12;
  kOriginMismatch = 64;

function ScaleInt(V: Integer; Scale: Double): Integer;
begin
  if Scale = 1.0 then
    Exit(V);
  // 正数远离零的 0.5 入（避免 bankers Round(412.5)=412）
  if V >= 0 then
    Result := Trunc(V * Scale + 0.5)
  else
    Result := Trunc(V * Scale - 0.5);
end;

function ScalePx(V: Integer; Scale: Double): Integer;
begin
  Result := ScaleInt(V, Scale);
end;

function ViewScaleFromDpi(Dpi: Integer): Double;
begin
  Result := 1.0;
  if Dpi <= 0 then
    Exit;
  Result := QuantizeUiScale(Dpi / 96.0);
  if Result < 1.0 then
    Result := 1.0;
end;

function MapClientToSkin(Client, ClientExtent, SkinExtent: Integer): Integer;
begin
  Result := LogicalFromNative(Client, SkinExtent, ClientExtent);
end;

function MapSkinToClient(Skin, SkinExtent, ClientExtent: Integer): Integer;
begin
  Result := NativeFromLogical(Skin, SkinExtent, ClientExtent);
end;

function SizeMatchesScale(Logical, Native: Integer; Scale: Double): Boolean;
var
  tol: Integer;
begin
  if Logical <= 0 then
    Exit(False);
  tol := Max(2, Logical div 50);
  Result := Abs(Native - ScaleInt(Logical, Scale)) <= tol;
end;

function QuantizeUiScale(Raw: Double): Double;
var
  i: Integer;
  best, d, bd: Double;
begin
  Result := 1.0;
  if (Raw < 0.92) or (Raw > 4.2) then
    Exit;
  best := 1.0;
  bd := Abs(Raw - 1.0);
  for i := 0 to High(kUiScales) do
  begin
    d := Abs(Raw - kUiScales[i]);
    if d < bd then
    begin
      bd := d;
      best := kUiScales[i];
    end;
  end;
  if bd <= kQuantTol then
    Result := best;
end;

function WindowScaleFromSizes(LogicalW, LogicalH, NativeW, NativeH: Integer): Double;
var
  rawX, rawY, raw, q: Double;
begin
  Result := 1.0;
  if (LogicalW <= 0) or (LogicalH <= 0) or (NativeW <= 0) or (NativeH <= 0) then
    Exit;
  if (Abs(NativeW - LogicalW) <= 2) and (Abs(NativeH - LogicalH) <= 2) then
    Exit;
  rawX := NativeW / LogicalW;
  rawY := NativeH / LogicalH;
  if Abs(rawX - rawY) > kAxisSkewTol then
    Exit;
  raw := (rawX + rawY) / 2.0;
  q := QuantizeUiScale(raw);
  if q <= 1.0001 then
    Exit;
  if not SizeMatchesScale(LogicalW, NativeW, q) then
    Exit;
  if not SizeMatchesScale(LogicalH, NativeH, q) then
    Exit;
  Result := q;
end;

function LogicalFromNative(Native, LogicalExtent, NativeExtent: Integer): Integer;
begin
  if (NativeExtent <= 0) or (LogicalExtent <= 0) then
    Exit(Native);
  Result := Round(Native * LogicalExtent / NativeExtent);
end;

function NativeFromLogical(Logical, LogicalExtent, NativeExtent: Integer): Integer;
begin
  if (NativeExtent <= 0) or (LogicalExtent <= 0) then
    Exit(Logical);
  Result := Round(Logical * NativeExtent / LogicalExtent);
end;

function MapNativePosToLogical(NativePos, LclPos, LogicalExtent, NativeExtent: Integer): Integer;
var
  converted: Integer;
begin
  Result := LclPos;
  if WindowScaleFromSizes(LogicalExtent, LogicalExtent, NativeExtent, NativeExtent) <= 1.0001 then
    Exit;
  converted := LogicalFromNative(NativePos, LogicalExtent, NativeExtent);
  if Abs(converted - LclPos) > kOriginMismatch then
    Exit;
  Result := converted;
end;

function ScaleShapeRects(const Rects: TShapeRectArray; ScaleX, ScaleY: Double): TShapeRectArray;
var
  i, n: Integer;
  x2, y2, r, b: Integer;
begin
  Result := nil;
  n := Length(Rects);
  if n = 0 then
    Exit;
  if (Abs(ScaleX - 1.0) < 1e-6) and (Abs(ScaleY - 1.0) < 1e-6) then
  begin
    Result := Copy(Rects);
    Exit;
  end;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    Result[i].X := ScaleInt(Rects[i].X, ScaleX);
    Result[i].Y := ScaleInt(Rects[i].Y, ScaleY);
    r := ScaleInt(Rects[i].X + Rects[i].W, ScaleX);
    b := ScaleInt(Rects[i].Y + Rects[i].H, ScaleY);
    x2 := Result[i].X;
    y2 := Result[i].Y;
    Result[i].W := Max(1, r - x2);
    Result[i].H := Max(1, b - y2);
  end;
end;

end.
