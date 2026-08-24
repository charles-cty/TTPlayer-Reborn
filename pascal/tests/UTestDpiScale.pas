unit UTestDpiScale;

{$mode objfpc}{$H+}

// Layer 3：DPI / GDK_SCALE 换算。CSD 尺寸比不得当成缩放。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, UDpiScale, UAlphaShape;

type
  TDpiScaleTest = class(TTestCase)
  published
    procedure TestQuantizeCommon;
    procedure TestQuantizeRejectsCsdRatio;
    procedure TestScaleIdentity;
    procedure TestScale150;
    procedure TestScale200;
    procedure TestCsdNotScale;
    procedure TestLogicalNativeRoundTrip;
    procedure TestMapPosScale1KeepsLcl;
    procedure TestMapPosScale2;
    procedure TestMapPosOriginMismatch;
    procedure TestScaleShapeRects2x;
    procedure TestScaleShapeRects15;
  end;

implementation

procedure TDpiScaleTest.TestQuantizeCommon;
begin
  AssertEquals(1.0, QuantizeUiScale(1.0), 1e-9);
  AssertEquals(1.25, QuantizeUiScale(1.25), 1e-9);
  AssertEquals(1.5, QuantizeUiScale(1.48), 1e-9);
  AssertEquals(2.0, QuantizeUiScale(2.0), 1e-9);
end;

procedure TDpiScaleTest.TestQuantizeRejectsCsdRatio;
begin
  // 351/275≈1.276 离 1.25 很近，单靠量化会落到 1.25；CSD 靠宽高比剔除。
  AssertEquals(1.25, QuantizeUiScale(351 / 275), 1e-9);
  AssertEquals(1.0, WindowScaleFromSizes(275, 116, 351, 213), 1e-9);
end;

procedure TDpiScaleTest.TestScaleIdentity;
begin
  AssertEquals(1.0, WindowScaleFromSizes(275, 116, 275, 116), 1e-9);
  AssertEquals(1.0, WindowScaleFromSizes(275, 116, 276, 117), 1e-9);
end;

procedure TDpiScaleTest.TestScale150;
begin
  AssertEquals(1.5, WindowScaleFromSizes(275, 116, 413, 174), 1e-9);
end;

procedure TDpiScaleTest.TestScale200;
begin
  AssertEquals(2.0, WindowScaleFromSizes(275, 116, 550, 232), 1e-9);
end;

procedure TDpiScaleTest.TestCsdNotScale;
begin
  AssertEquals('CSD 宽高比不一致，不得当 DPI',
    1.0, WindowScaleFromSizes(275, 116, 351, 213), 1e-9);
end;

procedure TDpiScaleTest.TestLogicalNativeRoundTrip;
var
  n, l: Integer;
begin
  n := NativeFromLogical(20, 275, 550);
  AssertEquals(40, n);
  l := LogicalFromNative(n, 275, 550);
  AssertEquals(20, l);
end;

procedure TDpiScaleTest.TestMapPosScale1KeepsLcl;
begin
  // WSLg：LCL 20，GDK origin 286，尺寸 1× → 保留 LCL
  AssertEquals(20, MapNativePosToLogical(286, 20, 275, 275));
end;

procedure TDpiScaleTest.TestMapPosScale2;
begin
  AssertEquals(20, MapNativePosToLogical(40, 20, 275, 550));
end;

procedure TDpiScaleTest.TestMapPosOriginMismatch;
begin
  // 2× 但原点对不上（WSLg + GDK_SCALE）→ 仍用 LCL，避免吸附飞掉
  AssertEquals(20, MapNativePosToLogical(572, 20, 275, 550));
end;

procedure TDpiScaleTest.TestScaleShapeRects2x;
var
  src, dst: TShapeRectArray;
begin
  src := nil;
  SetLength(src, 1);
  src[0].X := 10;
  src[0].Y := 2;
  src[0].W := 4;
  src[0].H := 1;
  dst := ScaleShapeRects(src, 2.0, 2.0);
  AssertEquals(1, Length(dst));
  AssertEquals(20, dst[0].X);
  AssertEquals(4, dst[0].Y);
  AssertEquals(8, dst[0].W);
  AssertEquals(2, dst[0].H);
end;

procedure TDpiScaleTest.TestScaleShapeRects15;
var
  src, dst: TShapeRectArray;
begin
  src := nil;
  SetLength(src, 1);
  src[0].X := 0;
  src[0].Y := 0;
  src[0].W := 275;
  src[0].H := 116;
  dst := ScaleShapeRects(src, 1.5, 1.5);
  AssertEquals(0, dst[0].X);
  AssertEquals(0, dst[0].Y);
  AssertEquals(413, dst[0].W);
  AssertEquals(174, dst[0].H);
end;

initialization
  RegisterTest(TDpiScaleTest);
end.
