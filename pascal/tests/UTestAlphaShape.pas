unit UTestAlphaShape;

{$mode objfpc}{$H+}

// Layer 3：Alpha run-length → Shape 矩形。不依赖窗口系统。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, BGRABitmap, BGRABitmapTypes, UAlphaShape;

type
  TAlphaShapeTest = class(TTestCase)
  published
    procedure TestNilBitmap;
    procedure TestFullyTransparent;
    procedure TestFullyOpaque;
    procedure TestSinglePixel;
    procedure TestRowSplit;
    procedure TestMergeVerticalRuns;
    procedure TestMergeEmpty;
  end;

implementation

procedure TAlphaShapeTest.TestNilBitmap;
begin
  AssertEquals(0, Length(AlphaRunRects(nil)));
end;

procedure TAlphaShapeTest.TestFullyTransparent;
var
  bmp: TBGRABitmap;
begin
  bmp := TBGRABitmap.Create(3, 2, BGRA(255, 0, 0, 0));
  try
    AssertEquals(0, Length(AlphaRunRects(bmp)));
  finally
    bmp.Free;
  end;
end;

procedure TAlphaShapeTest.TestFullyOpaque;
var
  bmp: TBGRABitmap;
  r: TShapeRectArray;
begin
  bmp := TBGRABitmap.Create(4, 2, BGRA(255, 0, 0, 255));
  try
    r := AlphaRunRects(bmp);
    AssertEquals('每行一条 run', 2, Length(r));
    AssertEquals(0, r[0].X);
    AssertEquals(0, r[0].Y);
    AssertEquals(4, r[0].W);
    AssertEquals(1, r[0].H);
    AssertEquals(0, r[1].X);
    AssertEquals(1, r[1].Y);
    AssertEquals(4, r[1].W);
  finally
    bmp.Free;
  end;
end;

procedure TAlphaShapeTest.TestSinglePixel;
var
  bmp: TBGRABitmap;
  r: TShapeRectArray;
begin
  bmp := TBGRABitmap.Create(3, 3, BGRA(0, 0, 0, 0));
  try
    bmp.ScanLine[2][1] := BGRA(10, 20, 30, 1);
    r := AlphaRunRects(bmp);
    AssertEquals(1, Length(r));
    AssertEquals(1, r[0].X);
    AssertEquals(2, r[0].Y);
    AssertEquals(1, r[0].W);
    AssertEquals(1, r[0].H);
  finally
    bmp.Free;
  end;
end;

procedure TAlphaShapeTest.TestRowSplit;
var
  bmp: TBGRABitmap;
  r: TShapeRectArray;
begin
  bmp := TBGRABitmap.Create(5, 1, BGRA(0, 0, 0, 0));
  try
    bmp.ScanLine[0][0] := BGRA(255, 255, 255, 255);
    bmp.ScanLine[0][1] := BGRA(255, 255, 255, 255);
    bmp.ScanLine[0][3] := BGRA(255, 255, 255, 128);
    r := AlphaRunRects(bmp);
    AssertEquals(2, Length(r));
    AssertEquals(0, r[0].X);
    AssertEquals(2, r[0].W);
    AssertEquals(3, r[1].X);
    AssertEquals(1, r[1].W);
  finally
    bmp.Free;
  end;
end;

procedure TAlphaShapeTest.TestMergeVerticalRuns;
var
  src, merged: TShapeRectArray;
begin
  SetLength(src, 4);
  src[0].X := 0; src[0].Y := 0; src[0].W := 10; src[0].H := 1;
  src[1].X := 0; src[1].Y := 1; src[1].W := 10; src[1].H := 1;
  src[2].X := 0; src[2].Y := 2; src[2].W := 10; src[2].H := 1;
  src[3].X := 2; src[3].Y := 3; src[3].W := 5;  src[3].H := 1;
  merged := MergeShapeRects(src);
  AssertEquals('竖向同宽 run 合成一条', 2, Length(merged));
  AssertEquals(0, merged[0].X);
  AssertEquals(0, merged[0].Y);
  AssertEquals(10, merged[0].W);
  AssertEquals(3, merged[0].H);
  AssertEquals(2, merged[1].X);
  AssertEquals(3, merged[1].Y);
  AssertEquals(5, merged[1].W);
  AssertEquals(1, merged[1].H);
end;

procedure TAlphaShapeTest.TestMergeEmpty;
begin
  AssertEquals(0, Length(MergeShapeRects(nil)));
end;

initialization
  RegisterTest(TAlphaShapeTest);
end.
