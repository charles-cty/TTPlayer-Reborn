unit UWindowSnapMath;

{$mode objfpc}{$H+}{$modeswitch advancedrecords}

// 窗口吸附几何原语，对应 Qt 版 WindowSnapManager 中与 QWidget 无关的轴对齐算法。
// 矩形用 {X,Y,W,H}；Qt QRect::right()/bottom() 是闭合坐标（X+W-1 / Y+H-1），
// 本单元所有比较都按这一约定翻译，避免 Types.TRect（Right 开区间）的差一错误。
// 不依赖 LCL，可供 FPCUnit（NoLCL）直接测试。

interface

uses
  Classes, SysUtils;

const
  kDefaultSnapThreshold = 10;

type
  TSnapEdge = (seRight, seBottom);
  TSnapEdges = set of TSnapEdge;

  TSnapRect = record
    X, Y, W, H: Integer;
    function RightIncl: Integer;   // Qt QRect::right()  = X+W-1
    function BottomIncl: Integer;  // Qt QRect::bottom() = Y+H-1
    function RightExcl: Integer;   // X+W
    function BottomExcl: Integer;  // Y+H
    function IsValid: Boolean;     // W>0 and H>0
    function Intersects(const Other: TSnapRect): Boolean;
    function ContainsRect(const Other: TSnapRect): Boolean;
    function Equal(const Other: TSnapRect): Boolean;
    function United(const Other: TSnapRect): TSnapRect;
  end;

  TSnapPoint = record
    X, Y: Integer;
  end;

function SnapRectXYWH(AX, AY, AW, AH: Integer): TSnapRect;
function SnapPointXY(AX, AY: Integer): TSnapPoint;
function Manhattan(X1, Y1, X2, Y2: Integer): Integer;
function SnapPointIsZero(const P: TSnapPoint): Boolean;

// 独立轴吸附：从 Moving 对齐到 Anchor，成功时写出新坐标与距离。
function TrySnapXAxis(const Moving, Anchor: TSnapRect; Threshold: Integer;
  out OutNewX, OutXDist: Integer): Boolean;
function TrySnapYAxis(const Moving, Anchor: TSnapRect; Threshold: Integer;
  out OutNewY, OutYDist: Integer): Boolean;

function TrySnapXAxisToScreen(const Moving, ScreenRect: TSnapRect;
  Threshold: Integer; out OutNewX, OutXDist: Integer): Boolean;
function TrySnapYAxisToScreen(const Moving, ScreenRect: TSnapRect;
  Threshold: Integer; out OutNewY, OutYDist: Integer): Boolean;

function TrySnapResizeToAnchor(const Moving: TSnapRect; Edges: TSnapEdges;
  const Anchor: TSnapRect; Threshold: Integer;
  out OutSnapRect: TSnapRect; out OutDistance: Integer): Boolean;
function TrySnapResizeToScreen(const Moving: TSnapRect; Edges: TSnapEdges;
  const ScreenRect: TSnapRect; Threshold: Integer;
  out OutSnapRect: TSnapRect; out OutDistance: Integer): Boolean;

// 合并独立轴结果：有吸附的轴取新坐标，没有的轴保持原值。
function CombineAxisSnap(const Moving: TSnapRect;
  HasX: Boolean; NewX: Integer;
  HasY: Boolean; NewY: Integer): TSnapPoint;

implementation

uses
  Math;

function SnapRectXYWH(AX, AY, AW, AH: Integer): TSnapRect;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function SnapPointXY(AX, AY: Integer): TSnapPoint;
begin
  Result.X := AX;
  Result.Y := AY;
end;

function Manhattan(X1, Y1, X2, Y2: Integer): Integer;
begin
  Result := Abs(X1 - X2) + Abs(Y1 - Y2);
end;

function SnapPointIsZero(const P: TSnapPoint): Boolean;
begin
  Result := (P.X = 0) and (P.Y = 0);
end;

function TSnapRect.RightIncl: Integer;
begin
  Result := X + W - 1;
end;

function TSnapRect.BottomIncl: Integer;
begin
  Result := Y + H - 1;
end;

function TSnapRect.RightExcl: Integer;
begin
  Result := X + W;
end;

function TSnapRect.BottomExcl: Integer;
begin
  Result := Y + H;
end;

function TSnapRect.IsValid: Boolean;
begin
  Result := (W > 0) and (H > 0);
end;

function TSnapRect.Intersects(const Other: TSnapRect): Boolean;
begin
  Result := (W > 0) and (H > 0) and (Other.W > 0) and (Other.H > 0) and
            (X < Other.RightExcl) and (Other.X < RightExcl) and
            (Y < Other.BottomExcl) and (Other.Y < BottomExcl);
end;

function TSnapRect.ContainsRect(const Other: TSnapRect): Boolean;
begin
  Result := (Other.X >= X) and (Other.Y >= Y) and
            (Other.RightExcl <= RightExcl) and
            (Other.BottomExcl <= BottomExcl);
end;

function TSnapRect.Equal(const Other: TSnapRect): Boolean;
begin
  Result := (X = Other.X) and (Y = Other.Y) and (W = Other.W) and (H = Other.H);
end;

function TSnapRect.United(const Other: TSnapRect): TSnapRect;
var
  x2, y2: Integer;
begin
  if not IsValid then
    Exit(Other);
  if not Other.IsValid then
    Exit(Self);
  Result.X := Min(X, Other.X);
  Result.Y := Min(Y, Other.Y);
  x2 := Max(RightExcl, Other.RightExcl);
  y2 := Max(BottomExcl, Other.BottomExcl);
  Result.W := x2 - Result.X;
  Result.H := y2 - Result.Y;
end;

function CombineAxisSnap(const Moving: TSnapRect;
  HasX: Boolean; NewX: Integer;
  HasY: Boolean; NewY: Integer): TSnapPoint;
begin
  if HasX then Result.X := NewX else Result.X := Moving.X;
  if HasY then Result.Y := NewY else Result.Y := Moving.Y;
end;

function TrySnapXAxis(const Moving, Anchor: TSnapRect; Threshold: Integer;
  out OutNewX, OutXDist: Integer): Boolean;
var
  overlapsVertically, overlapsArea: Boolean;
  dist: Integer;

  procedure Consider(CandidateX, ADist: Integer);
  begin
    if (not Result) or (ADist < OutXDist) then
    begin
      OutXDist := ADist;
      OutNewX := CandidateX;
      Result := True;
    end;
  end;

begin
  Result := False;
  OutNewX := Moving.X;
  OutXDist := High(Integer);

  overlapsVertically :=
    (Moving.BottomIncl >= Anchor.Y - Threshold) and
    (Moving.Y <= Anchor.BottomIncl + Threshold);
  overlapsArea := Moving.Intersects(Anchor) or
                  Moving.ContainsRect(Anchor) or
                  Anchor.ContainsRect(Moving);

  // 左边缘 → 锚点右边缘 + 1（左右相邻）
  if overlapsVertically then
  begin
    dist := Abs(Moving.X - Anchor.RightExcl);
    if dist <= Threshold then
      Consider(Anchor.RightExcl, dist);
  end;

  // 右边缘 + 1 → 锚点左边缘（右左相邻）
  if overlapsVertically then
  begin
    dist := Abs(Moving.RightExcl - Anchor.X);
    if dist <= Threshold then
      Consider(Anchor.X - Moving.W, dist);
  end;

  // 重叠区域（或垂直投影重叠）内的同侧对齐
  if overlapsArea or overlapsVertically then
  begin
    dist := Abs(Moving.X - Anchor.X);
    if dist <= Threshold then
      Consider(Anchor.X, dist);
    dist := Abs(Moving.RightIncl - Anchor.RightIncl);
    if dist <= Threshold then
      Consider(Anchor.RightIncl - Moving.W + 1, dist);
  end;
end;

function TrySnapYAxis(const Moving, Anchor: TSnapRect; Threshold: Integer;
  out OutNewY, OutYDist: Integer): Boolean;
var
  overlapsHorizontally, overlapsArea: Boolean;
  dist: Integer;

  procedure Consider(CandidateY, ADist: Integer);
  begin
    if (not Result) or (ADist < OutYDist) then
    begin
      OutYDist := ADist;
      OutNewY := CandidateY;
      Result := True;
    end;
  end;

begin
  Result := False;
  OutNewY := Moving.Y;
  OutYDist := High(Integer);

  overlapsHorizontally :=
    (Moving.RightIncl >= Anchor.X - Threshold) and
    (Moving.X <= Anchor.RightIncl + Threshold);
  overlapsArea := Moving.Intersects(Anchor) or
                  Moving.ContainsRect(Anchor) or
                  Anchor.ContainsRect(Moving);

  // 上边缘 → 锚点下边缘 + 1（上下相邻）
  if overlapsHorizontally then
  begin
    dist := Abs(Moving.Y - Anchor.BottomExcl);
    if dist <= Threshold then
      Consider(Anchor.BottomExcl, dist);
  end;

  // 下边缘 + 1 → 锚点上边缘（下上相邻）
  if overlapsHorizontally then
  begin
    dist := Abs(Moving.BottomExcl - Anchor.Y);
    if dist <= Threshold then
      Consider(Anchor.Y - Moving.H, dist);
  end;

  if overlapsArea or overlapsHorizontally then
  begin
    dist := Abs(Moving.Y - Anchor.Y);
    if dist <= Threshold then
      Consider(Anchor.Y, dist);
    dist := Abs(Moving.BottomIncl - Anchor.BottomIncl);
    if dist <= Threshold then
      Consider(Anchor.BottomIncl - Moving.H + 1, dist);
  end;
end;

function TrySnapXAxisToScreen(const Moving, ScreenRect: TSnapRect;
  Threshold: Integer; out OutNewX, OutXDist: Integer): Boolean;
var
  dist: Integer;

  procedure Consider(CandidateX, ADist: Integer);
  begin
    if (not Result) or (ADist < OutXDist) then
    begin
      OutXDist := ADist;
      OutNewX := CandidateX;
      Result := True;
    end;
  end;

begin
  Result := False;
  OutNewX := Moving.X;
  OutXDist := High(Integer);
  if not ScreenRect.IsValid then Exit;

  dist := Abs(Moving.X - ScreenRect.X);
  if dist <= Threshold then
    Consider(ScreenRect.X, dist);

  dist := Abs(Moving.RightIncl - ScreenRect.RightIncl);
  if dist <= Threshold then
    Consider(ScreenRect.RightIncl - Moving.W + 1, dist);
end;

function TrySnapYAxisToScreen(const Moving, ScreenRect: TSnapRect;
  Threshold: Integer; out OutNewY, OutYDist: Integer): Boolean;
var
  dist: Integer;

  procedure Consider(CandidateY, ADist: Integer);
  begin
    if (not Result) or (ADist < OutYDist) then
    begin
      OutYDist := ADist;
      OutNewY := CandidateY;
      Result := True;
    end;
  end;

begin
  Result := False;
  OutNewY := Moving.Y;
  OutYDist := High(Integer);
  if not ScreenRect.IsValid then Exit;

  dist := Abs(Moving.Y - ScreenRect.Y);
  if dist <= Threshold then
    Consider(ScreenRect.Y, dist);

  dist := Abs(Moving.BottomIncl - ScreenRect.BottomIncl);
  if dist <= Threshold then
    Consider(ScreenRect.BottomIncl - Moving.H + 1, dist);
end;

function TrySnapResizeToAnchor(const Moving: TSnapRect; Edges: TSnapEdges;
  const Anchor: TSnapRect; Threshold: Integer;
  out OutSnapRect: TSnapRect; out OutDistance: Integer): Boolean;
var
  overlapsHorizontally, overlapsVertically: Boolean;
  candidate: TSnapRect;
  dist: Integer;

  procedure Consider(const CandidateRect: TSnapRect);
  begin
    if (CandidateRect.W <= 0) or (CandidateRect.H <= 0) then Exit;
    dist := 0;
    if seRight in Edges then
      dist := dist + Abs(CandidateRect.RightIncl - Moving.RightIncl);
    if seBottom in Edges then
      dist := dist + Abs(CandidateRect.BottomIncl - Moving.BottomIncl);
    if (not Result) or (dist < OutDistance) then
    begin
      OutDistance := dist;
      OutSnapRect := CandidateRect;
      Result := True;
    end;
  end;

begin
  Result := False;
  OutSnapRect := Moving;
  OutDistance := High(Integer);

  overlapsHorizontally :=
    (Moving.RightIncl >= Anchor.X - Threshold) and
    (Moving.X <= Anchor.RightIncl + Threshold);
  overlapsVertically :=
    (Moving.BottomIncl >= Anchor.Y - Threshold) and
    (Moving.Y <= Anchor.BottomIncl + Threshold);

  if (seRight in Edges) and overlapsVertically then
  begin
    if Abs(Moving.RightIncl - Anchor.RightIncl) <= Threshold then
    begin
      candidate := Moving;
      candidate.W := Anchor.RightExcl - Moving.X;
      Consider(candidate);
    end;
    if Abs(Moving.RightExcl - Anchor.X) <= Threshold then
    begin
      candidate := Moving;
      candidate.W := Anchor.X - Moving.X;
      Consider(candidate);
    end;
  end;

  if (seBottom in Edges) and overlapsHorizontally then
  begin
    if Abs(Moving.BottomIncl - Anchor.BottomIncl) <= Threshold then
    begin
      candidate := Moving;
      candidate.H := Anchor.BottomExcl - Moving.Y;
      Consider(candidate);
    end;
    if Abs(Moving.BottomExcl - Anchor.Y) <= Threshold then
    begin
      candidate := Moving;
      candidate.H := Anchor.Y - Moving.Y;
      Consider(candidate);
    end;
  end;
end;

function TrySnapResizeToScreen(const Moving: TSnapRect; Edges: TSnapEdges;
  const ScreenRect: TSnapRect; Threshold: Integer;
  out OutSnapRect: TSnapRect; out OutDistance: Integer): Boolean;
var
  candidate: TSnapRect;
  dist: Integer;

  procedure Consider(const CandidateRect: TSnapRect);
  begin
    if (CandidateRect.W <= 0) or (CandidateRect.H <= 0) then Exit;
    dist := 0;
    if seRight in Edges then
      dist := dist + Abs(CandidateRect.RightIncl - Moving.RightIncl);
    if seBottom in Edges then
      dist := dist + Abs(CandidateRect.BottomIncl - Moving.BottomIncl);
    if (not Result) or (dist < OutDistance) then
    begin
      OutDistance := dist;
      OutSnapRect := CandidateRect;
      Result := True;
    end;
  end;

begin
  Result := False;
  OutSnapRect := Moving;
  OutDistance := High(Integer);
  if not ScreenRect.IsValid then Exit;

  if (seRight in Edges) and
     (Abs(Moving.RightIncl - ScreenRect.RightIncl) <= Threshold) then
  begin
    candidate := Moving;
    candidate.W := ScreenRect.RightExcl - Moving.X;
    Consider(candidate);
  end;

  if (seBottom in Edges) and
     (Abs(Moving.BottomIncl - ScreenRect.BottomIncl) <= Threshold) then
  begin
    candidate := Moving;
    candidate.H := ScreenRect.BottomExcl - Moving.Y;
    Consider(candidate);
  end;
end;

end.
