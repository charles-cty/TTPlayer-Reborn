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

implementation

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

end.
