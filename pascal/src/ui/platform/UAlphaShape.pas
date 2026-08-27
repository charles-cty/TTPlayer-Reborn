unit UAlphaShape;

{$mode objfpc}{$H+}

// 由位图 alpha 生成 Shape 矩形（每行不透明 run）。不依赖 LCL，
// 供 UPlatformWindow 与 NoLCL FPCUnit 共用。

interface

uses
  Classes, SysUtils, BGRABitmap, BGRABitmapTypes;

type
  TShapeRect = record
    X, Y, W, H: Integer;
  end;
  TShapeRectArray = array of TShapeRect;

function AlphaRunRects(Bitmap: TBGRABitmap): TShapeRectArray;

// live 缩放：把上一帧的不透明 run 映到新尺寸。贴着源右/下边的 run
// 对齐到 Dest 右/下边，放大时 Region 跟手，缩小则由 HWND 裁切。
function MapLiveShapeRects(const Src: TShapeRectArray;
  SrcW, SrcH, DstW, DstH: Integer): TShapeRectArray;

implementation

function MapCoord(V, SrcExtent, DstExtent: Integer): Integer;
begin
  if SrcExtent <= 0 then
    Exit(0);
  if V <= 0 then
    Exit(0);
  Result := Integer((Int64(V) * DstExtent + SrcExtent div 2) div SrcExtent);
end;

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

function MapLiveShapeRects(const Src: TShapeRectArray;
  SrcW, SrcH, DstW, DstH: Integer): TShapeRectArray;
var
  i, n, x1, y1, x2, y2: Integer;
begin
  Result := nil;
  n := Length(Src);
  if (n = 0) or (SrcW < 1) or (SrcH < 1) then
    Exit;
  if DstW < 1 then DstW := 1;
  if DstH < 1 then DstH := 1;
  if (SrcW = DstW) and (SrcH = DstH) then
  begin
    Result := Copy(Src);
    Exit;
  end;
  SetLength(Result, n);
  for i := 0 to n - 1 do
  begin
    x1 := MapCoord(Src[i].X, SrcW, DstW);
    y1 := MapCoord(Src[i].Y, SrcH, DstH);
    x2 := MapCoord(Src[i].X + Src[i].W, SrcW, DstW);
    y2 := MapCoord(Src[i].Y + Src[i].H, SrcH, DstH);
    if Src[i].X <= 0 then
      x1 := 0;
    if Src[i].Y <= 0 then
      y1 := 0;
    if Src[i].X + Src[i].W >= SrcW then
      x2 := DstW;
    if Src[i].Y + Src[i].H >= SrcH then
      y2 := DstH;
    Result[i].X := x1;
    Result[i].Y := y1;
    Result[i].W := x2 - x1;
    Result[i].H := y2 - y1;
    if Result[i].W < 1 then Result[i].W := 1;
    if Result[i].H < 1 then Result[i].H := 1;
  end;
end;

end.
