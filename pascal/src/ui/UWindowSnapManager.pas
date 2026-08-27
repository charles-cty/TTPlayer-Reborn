unit UWindowSnapManager;

{$mode objfpc}{$H+}

// 窗口吸附管理器，对应 Qt 版 src/ui/WindowSnapManager。
//
// 工作原理（与原版一致）：
//   - 子窗口可吸附到主窗口，或吸附到已连接主窗口的子窗口。
//   - 主窗口移动时，仅移动“直接或间接连接到主窗口”的吸附窗口。
//   - 子窗口手动拖动只影响自身位置与后续吸附关系，不带动其他窗口。
//   - 任务栏激活/Z 序成组不在本单元：宿主把辅助窗口绑成主窗口的
//     owned/transient 子窗口（见 PrepareAuxOwnedWindow），与是否吸附无关。
//
// 本单元不依赖 LCL：窗口通过 ISnapWindow 抽象，测试用 TMemorySnapWindow，
// 真实 Form 由 UFormSnap.TFormSnapWindow 包装。
// 未移植 Qt 侧的 MovePerf 日志与 SnapDebugOverlay。

interface

uses
  Classes, SysUtils, UWindowSnapMath;

const
  SNAP_MAIN_ANCHOR = -1;
  SNAP_NO_ANCHOR   = -2;

type
  ISnapWindow = interface
    ['{B8E4C2A1-7F3D-4A90-9C15-8D6E4F2A1B03}']
    function GetBounds: TSnapRect;
    procedure MoveTo(AX, AY: Integer);
    procedure ResizeTo(AW, AH: Integer);
    function GetVisible: Boolean;
    procedure SetVisible(AValue: Boolean);
    function GetName: string;
    // 宿主窗口正在销毁时断开引用。之后 GetVisible=False，GetBounds 为空。
    procedure Detach;
  end;

  TMemorySnapWindow = class(TInterfacedObject, ISnapWindow)
  private
    FX, FY, FW, FH: Integer;
    FVisible: Boolean;
    FName: string;
  public
    constructor Create(const AName: string; AX, AY, AW, AH: Integer);
    function GetBounds: TSnapRect;
    procedure MoveTo(AX, AY: Integer);
    procedure ResizeTo(AW, AH: Integer);
    function GetVisible: Boolean;
    procedure SetVisible(AValue: Boolean);
    function GetName: string;
    procedure Detach;
  end;

  TWindowSnapManager = class
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetMainWindow(AWin: ISnapWindow);
    procedure AddSubWindow(AWin: ISnapWindow);
    procedure RemoveSubWindow(AWin: ISnapWindow);
    procedure ClearWindows;

    function  GetSnapThreshold: Integer;
    procedure SetSnapThreshold(Px: Integer);
    property  SnapThreshold: Integer read GetSnapThreshold write SetSnapThreshold;

    function  GetScreenRect: TSnapRect;
    procedure SetScreenRect(const R: TSnapRect);
    property  ScreenRect: TSnapRect read GetScreenRect write SetScreenRect;

    function  GetLiveAttachOnMainDragEnabled: Boolean;
    procedure SetLiveAttachOnMainDragEnabled(AValue: Boolean);
    property  LiveAttachOnMainDragEnabled: Boolean
      read GetLiveAttachOnMainDragEnabled write SetLiveAttachOnMainDragEnabled;

    procedure OnMainMoved(DX, DY: Integer);
    procedure OnSubMoved(ASub: ISnapWindow; DX, DY: Integer);
    procedure OnSubResized(ASub: ISnapWindow; Edges: TSnapEdges);
    procedure OnSubResizeFinished(ASub: ISnapWindow; Edges: TSnapEdges);
    procedure OnDragStarted(ALeader: ISnapWindow);
    procedure OnDragFinished(ALeader: ISnapWindow);
    procedure RebuildSnapGraph;

    // 测试/诊断
    function SubCount: Integer;
    function FindSubIndex(AWin: ISnapWindow): Integer;
    function IsSnapped(AWin: ISnapWindow): Boolean;
    function ConnectedToMain(AWin: ISnapWindow): Boolean;
    function AnchorOf(AWin: ISnapWindow): Integer;
  private
    type
      TSubEntry = record
        Win: ISnapWindow;
        Anchor: Integer;
        SnapOffset: TSnapPoint;
      end;

    var
      FMain: ISnapWindow;
      FSubs: array of TSubEntry;
      FSnapThreshold: Integer;
      FScreenRect: TSnapRect;
      FLiveAttachOnMainDragEnabled: Boolean;
      FSyncing: Boolean;

      FDragLeader: ISnapWindow;
      FDragLeaderIndex: Integer;
      FDragLeaderStart: TSnapPoint;
      FMoveGroup: array of Integer;
      FMoveGroupStart: array of TSnapPoint;

    function  DragActive: Boolean;
    procedure ClearDrag;
    function  IsSnappedIndex(SubIndex: Integer): Boolean;
    function  IsConnectedToMain(SubIndex: Integer): Boolean;
    function  WouldCreateCycle(MovingIndex, AnchorIndex: Integer): Boolean;
    function  AnchorWin(SubIndex: Integer): ISnapWindow;
    function  ConnectedGroupRectExcluding(ExcludeIndex: Integer): TSnapRect;
    function  TrySnap(MovingIndex: Integer; MoveToSnap: Boolean): Boolean;
    procedure ClearAllAnchors;
    procedure RefreshOffsets;
    procedure BeginDragSession(ALeader: ISnapWindow);
    procedure FinishDragSession(ALeader: ISnapWindow);
    function  MoveDragGroup(const TotalDelta: TSnapPoint): Integer;
    function  MoveConnectedSubWindows(const Delta: TSnapPoint): Integer;
    function  FinalSnapGroupToStaticWindows: TSnapPoint;
    function  FinalSnapDraggedSub: TSnapPoint;
    procedure RebuildSnapGraphInPlace;
  end;

implementation

{ TMemorySnapWindow }

constructor TMemorySnapWindow.Create(const AName: string; AX, AY, AW, AH: Integer);
begin
  inherited Create;
  FName := AName;
  FX := AX; FY := AY; FW := AW; FH := AH;
  FVisible := True;
end;

function TMemorySnapWindow.GetBounds: TSnapRect;
begin
  Result := SnapRectXYWH(FX, FY, FW, FH);
end;

procedure TMemorySnapWindow.MoveTo(AX, AY: Integer);
begin
  FX := AX;
  FY := AY;
end;

procedure TMemorySnapWindow.ResizeTo(AW, AH: Integer);
begin
  FW := AW;
  FH := AH;
end;

function TMemorySnapWindow.GetVisible: Boolean;
begin
  Result := FVisible;
end;

procedure TMemorySnapWindow.SetVisible(AValue: Boolean);
begin
  FVisible := AValue;
end;

function TMemorySnapWindow.GetName: string;
begin
  Result := FName;
end;

procedure TMemorySnapWindow.Detach;
begin
  FVisible := False;
end;

{ TWindowSnapManager }

constructor TWindowSnapManager.Create;
begin
  inherited Create;
  FSnapThreshold := kDefaultSnapThreshold;
  FScreenRect := SnapRectXYWH(0, 0, 0, 0);
  FLiveAttachOnMainDragEnabled := True;
  FSyncing := False;
  ClearDrag;
end;

destructor TWindowSnapManager.Destroy;
begin
  ClearDrag;
  SetLength(FSubs, 0);
  FMain := nil;
  inherited Destroy;
end;

procedure TWindowSnapManager.SetMainWindow(AWin: ISnapWindow);
begin
  FMain := AWin;
  RebuildSnapGraph;
end;

procedure TWindowSnapManager.AddSubWindow(AWin: ISnapWindow);
var
  n: Integer;
begin
  if AWin = nil then Exit;
  if FindSubIndex(AWin) <> SNAP_NO_ANCHOR then Exit;
  n := Length(FSubs);
  SetLength(FSubs, n + 1);
  FSubs[n].Win := AWin;
  FSubs[n].Anchor := SNAP_NO_ANCHOR;
  FSubs[n].SnapOffset := SnapPointXY(0, 0);
end;

procedure TWindowSnapManager.RemoveSubWindow(AWin: ISnapWindow);
var
  idx, i, last: Integer;
begin
  if AWin = nil then Exit;
  if FMain = AWin then
    FMain := nil;
  idx := FindSubIndex(AWin);
  if idx = SNAP_NO_ANCHOR then Exit;
  last := High(FSubs);
  for i := 0 to last do
  begin
    if FSubs[i].Anchor = idx then
      FSubs[i].Anchor := SNAP_NO_ANCHOR
    else if (idx <> last) and (FSubs[i].Anchor = last) then
      FSubs[i].Anchor := idx;
  end;
  if idx <> last then
    FSubs[idx] := FSubs[last];
  FSubs[last].Win := nil;
  SetLength(FSubs, Length(FSubs) - 1);
end;

procedure TWindowSnapManager.ClearWindows;
var
  i: Integer;
begin
  ClearDrag;
  FMain := nil;
  for i := 0 to High(FSubs) do
    FSubs[i].Win := nil;
  SetLength(FSubs, 0);
end;

function TWindowSnapManager.GetSnapThreshold: Integer;
begin
  Result := FSnapThreshold;
end;

procedure TWindowSnapManager.SetSnapThreshold(Px: Integer);
begin
  FSnapThreshold := Px;
end;

function TWindowSnapManager.GetScreenRect: TSnapRect;
begin
  Result := FScreenRect;
end;

procedure TWindowSnapManager.SetScreenRect(const R: TSnapRect);
begin
  FScreenRect := R;
end;

function TWindowSnapManager.GetLiveAttachOnMainDragEnabled: Boolean;
begin
  Result := FLiveAttachOnMainDragEnabled;
end;

procedure TWindowSnapManager.SetLiveAttachOnMainDragEnabled(AValue: Boolean);
begin
  FLiveAttachOnMainDragEnabled := AValue;
end;

function TWindowSnapManager.SubCount: Integer;
begin
  Result := Length(FSubs);
end;

function TWindowSnapManager.FindSubIndex(AWin: ISnapWindow): Integer;
var
  i: Integer;
begin
  Result := SNAP_NO_ANCHOR;
  if AWin = nil then Exit;
  for i := 0 to High(FSubs) do
    if FSubs[i].Win = AWin then
      Exit(i);
end;

function TWindowSnapManager.IsSnapped(AWin: ISnapWindow): Boolean;
begin
  Result := IsSnappedIndex(FindSubIndex(AWin));
end;

function TWindowSnapManager.ConnectedToMain(AWin: ISnapWindow): Boolean;
begin
  Result := IsConnectedToMain(FindSubIndex(AWin));
end;

function TWindowSnapManager.AnchorOf(AWin: ISnapWindow): Integer;
var
  idx: Integer;
begin
  idx := FindSubIndex(AWin);
  if idx = SNAP_NO_ANCHOR then
    Result := SNAP_NO_ANCHOR
  else
    Result := FSubs[idx].Anchor;
end;

function TWindowSnapManager.DragActive: Boolean;
begin
  Result := FDragLeader <> nil;
end;

procedure TWindowSnapManager.ClearDrag;
begin
  FDragLeader := nil;
  FDragLeaderIndex := SNAP_NO_ANCHOR;
  FDragLeaderStart := SnapPointXY(0, 0);
  SetLength(FMoveGroup, 0);
  SetLength(FMoveGroupStart, 0);
end;

function TWindowSnapManager.IsSnappedIndex(SubIndex: Integer): Boolean;
begin
  Result := (SubIndex >= 0) and (SubIndex <= High(FSubs)) and
            (FSubs[SubIndex].Anchor <> SNAP_NO_ANCHOR);
end;

function TWindowSnapManager.IsConnectedToMain(SubIndex: Integer): Boolean;
var
  visited: array of Boolean;
  cursor, anchor: Integer;
begin
  Result := False;
  if (FMain = nil) or not IsSnappedIndex(SubIndex) then Exit;
  SetLength(visited, Length(FSubs));
  cursor := SubIndex;
  while (cursor >= 0) and (cursor <= High(FSubs)) do
  begin
    if visited[cursor] then Exit;
    visited[cursor] := True;
    anchor := FSubs[cursor].Anchor;
    if anchor = SNAP_MAIN_ANCHOR then
      Exit(True);
    if (anchor < 0) or (anchor > High(FSubs)) then
      Exit(False);
    cursor := anchor;
  end;
end;

function TWindowSnapManager.WouldCreateCycle(MovingIndex, AnchorIndex: Integer): Boolean;
var
  visited: array of Boolean;
  cursor, nextAnchor: Integer;
begin
  if (MovingIndex < 0) or (MovingIndex > High(FSubs)) then
    Exit(True);
  if AnchorIndex = SNAP_MAIN_ANCHOR then
    Exit(False);
  if (AnchorIndex < 0) or (AnchorIndex > High(FSubs)) then
    Exit(True);

  SetLength(visited, Length(FSubs));
  cursor := AnchorIndex;
  while (cursor >= 0) and (cursor <= High(FSubs)) do
  begin
    if (cursor = MovingIndex) or visited[cursor] then
      Exit(True);
    visited[cursor] := True;
    nextAnchor := FSubs[cursor].Anchor;
    if (nextAnchor = SNAP_MAIN_ANCHOR) or (nextAnchor = SNAP_NO_ANCHOR) then
      Exit(False);
    cursor := nextAnchor;
  end;
  Result := False;
end;

function TWindowSnapManager.AnchorWin(SubIndex: Integer): ISnapWindow;
var
  anchor: Integer;
begin
  Result := nil;
  if (FMain = nil) or (SubIndex < 0) or (SubIndex > High(FSubs)) then Exit;
  anchor := FSubs[SubIndex].Anchor;
  if anchor = SNAP_MAIN_ANCHOR then
    Result := FMain
  else if (anchor >= 0) and (anchor <= High(FSubs)) then
    Result := FSubs[anchor].Win;
end;

function TWindowSnapManager.ConnectedGroupRectExcluding(ExcludeIndex: Integer): TSnapRect;
var
  i: Integer;
  b: TSnapRect;
begin
  Result := SnapRectXYWH(0, 0, 0, 0);
  if (FMain = nil) or not FMain.GetVisible then Exit;
  Result := FMain.GetBounds;
  for i := 0 to High(FSubs) do
  begin
    if (i = ExcludeIndex) or (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then
      Continue;
    if not IsConnectedToMain(i) then Continue;
    b := FSubs[i].Win.GetBounds;
    Result := Result.United(b);
  end;
end;

procedure TWindowSnapManager.ClearAllAnchors;
var
  i: Integer;
begin
  for i := 0 to High(FSubs) do
  begin
    FSubs[i].Anchor := SNAP_NO_ANCHOR;
    FSubs[i].SnapOffset := SnapPointXY(0, 0);
  end;
end;

procedure TWindowSnapManager.RefreshOffsets;
var
  i: Integer;
  anchor: ISnapWindow;
  wb, ab: TSnapRect;
begin
  for i := 0 to High(FSubs) do
  begin
    if not IsSnappedIndex(i) or (FSubs[i].Win = nil) then Continue;
    anchor := AnchorWin(i);
    if anchor = nil then
    begin
      FSubs[i].Anchor := SNAP_NO_ANCHOR;
      FSubs[i].SnapOffset := SnapPointXY(0, 0);
      Continue;
    end;
    wb := FSubs[i].Win.GetBounds;
    ab := anchor.GetBounds;
    FSubs[i].SnapOffset := SnapPointXY(wb.X - ab.X, wb.Y - ab.Y);
  end;
end;

procedure TWindowSnapManager.RebuildSnapGraph;
var
  changed: Boolean;
  i: Integer;
begin
  if FMain = nil then Exit;
  ClearAllAnchors;
  changed := True;
  while changed do
  begin
    changed := False;
    for i := 0 to High(FSubs) do
    begin
      if (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible or IsSnappedIndex(i) then
        Continue;
      if TrySnap(i, True) then
        changed := True;
    end;
  end;
  RefreshOffsets;
end;

procedure TWindowSnapManager.RebuildSnapGraphInPlace;
var
  changed: Boolean;
  i: Integer;
begin
  if FMain = nil then Exit;
  ClearAllAnchors;
  changed := True;
  while changed do
  begin
    changed := False;
    for i := 0 to High(FSubs) do
    begin
      if (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible or IsSnappedIndex(i) then
        Continue;
      if TrySnap(i, False) then
        changed := True;
    end;
  end;
  RefreshOffsets;
end;

function TWindowSnapManager.TrySnap(MovingIndex: Integer; MoveToSnap: Boolean): Boolean;
var
  entryWin: ISnapWindow;
  movingRect, anchorRect, groupRect, mainRect: TSnapRect;
  bestXDist, bestYDist, bestNewX, bestNewY, xAnchor, yAnchor: Integer;
  hasXSnap, hasYSnap: Boolean;
  newX, xDist, newY, yDist, i, bestAnchor: Integer;
  bestPos, curPos: TSnapPoint;

  procedure ConsiderAnchorAxes(AnchorIndex: Integer; const ARect: TSnapRect);
  begin
    if TrySnapXAxis(movingRect, ARect, FSnapThreshold, newX, xDist) and
       (xDist < bestXDist) then
    begin
      bestXDist := xDist;
      bestNewX := newX;
      xAnchor := AnchorIndex;
      hasXSnap := True;
    end;
    if TrySnapYAxis(movingRect, ARect, FSnapThreshold, newY, yDist) and
       (yDist < bestYDist) then
    begin
      bestYDist := yDist;
      bestNewY := newY;
      yAnchor := AnchorIndex;
      hasYSnap := True;
    end;
  end;

begin
  Result := False;
  if (FMain = nil) or (MovingIndex < 0) or (MovingIndex > High(FSubs)) then Exit;
  entryWin := FSubs[MovingIndex].Win;
  if entryWin = nil then Exit;

  movingRect := entryWin.GetBounds;
  bestXDist := High(Integer);
  bestYDist := High(Integer);
  bestNewX := movingRect.X;
  bestNewY := movingRect.Y;
  xAnchor := SNAP_NO_ANCHOR;
  yAnchor := SNAP_NO_ANCHOR;
  hasXSnap := False;
  hasYSnap := False;

  if FMain.GetVisible then
    ConsiderAnchorAxes(SNAP_MAIN_ANCHOR, FMain.GetBounds);

  groupRect := ConnectedGroupRectExcluding(MovingIndex);
  mainRect := FMain.GetBounds;
  if groupRect.IsValid and not groupRect.Equal(mainRect) then
    ConsiderAnchorAxes(SNAP_MAIN_ANCHOR, groupRect);

  for i := 0 to High(FSubs) do
  begin
    if (i = MovingIndex) or not IsConnectedToMain(i) or
       WouldCreateCycle(MovingIndex, i) then
      Continue;
    if (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then Continue;
    ConsiderAnchorAxes(i, FSubs[i].Win.GetBounds);
  end;

  if (not hasXSnap) and (not hasYSnap) then Exit;

  bestPos := CombineAxisSnap(movingRect, hasXSnap, bestNewX, hasYSnap, bestNewY);

  if hasXSnap and hasYSnap then
  begin
    if bestXDist <= bestYDist then
      bestAnchor := xAnchor
    else
      bestAnchor := yAnchor;
  end
  else if hasXSnap then
    bestAnchor := xAnchor
  else
    bestAnchor := yAnchor;

  if MoveToSnap then
  begin
    FSyncing := True;
    try
      entryWin.MoveTo(bestPos.X, bestPos.Y);
    finally
      FSyncing := False;
    end;
  end
  else
  begin
    curPos := SnapPointXY(entryWin.GetBounds.X, entryWin.GetBounds.Y);
    if Manhattan(bestPos.X, bestPos.Y, curPos.X, curPos.Y) > 2 then
      Exit(False);
  end;

  FSubs[MovingIndex].Anchor := bestAnchor;
  if bestAnchor = SNAP_MAIN_ANCHOR then
  begin
    movingRect := entryWin.GetBounds;
    mainRect := FMain.GetBounds;
    FSubs[MovingIndex].SnapOffset :=
      SnapPointXY(movingRect.X - mainRect.X, movingRect.Y - mainRect.Y);
  end
  else
  begin
    movingRect := entryWin.GetBounds;
    anchorRect := FSubs[bestAnchor].Win.GetBounds;
    FSubs[MovingIndex].SnapOffset :=
      SnapPointXY(movingRect.X - anchorRect.X, movingRect.Y - anchorRect.Y);
  end;
  Result := True;
end;

procedure TWindowSnapManager.OnMainMoved(DX, DY: Integer);
var
  totalDelta: TSnapPoint;
  mb: TSnapRect;
begin
  if FSyncing or (FMain = nil) then Exit;
  if (DX = 0) and (DY = 0) then Exit;

  if DragActive and (FDragLeader = FMain) then
  begin
    mb := FMain.GetBounds;
    totalDelta := SnapPointXY(mb.X - FDragLeaderStart.X, mb.Y - FDragLeaderStart.Y);
    MoveDragGroup(totalDelta);
    // 拖动过程中不把主窗口磁吸到静止窗口：HTCAPTION / 系统拖动会覆盖
    // 主窗口位置（Qt 版同样被下一帧 mouseMove 覆盖）。松手时再吸附。
    Exit;
  end;

  MoveConnectedSubWindows(SnapPointXY(DX, DY));
end;

procedure TWindowSnapManager.OnSubMoved(ASub: ISnapWindow; DX, DY: Integer);
begin
  if FSyncing or (FMain = nil) or (ASub = nil) then Exit;
  if (DX = 0) and (DY = 0) then Exit;
  // 子窗口拖动中不实时磁吸（与主窗口同一原因）；松手时 finalSnapDraggedSub。
  if DragActive and (FDragLeader = ASub) then
    Exit;
end;

procedure TWindowSnapManager.OnDragStarted(ALeader: ISnapWindow);
begin
  BeginDragSession(ALeader);
end;

procedure TWindowSnapManager.OnDragFinished(ALeader: ISnapWindow);
begin
  FinishDragSession(ALeader);
end;

procedure TWindowSnapManager.BeginDragSession(ALeader: ISnapWindow);
var
  i, n: Integer;
  b: TSnapRect;
begin
  if (FMain = nil) or FSyncing or (ALeader = nil) then Exit;
  ClearDrag;
  FDragLeader := ALeader;

  if ALeader = FMain then
  begin
    FDragLeaderIndex := SNAP_MAIN_ANCHOR;
    b := FMain.GetBounds;
    FDragLeaderStart := SnapPointXY(b.X, b.Y);
    n := 0;
    SetLength(FMoveGroup, Length(FSubs));
    SetLength(FMoveGroupStart, Length(FSubs));
    for i := 0 to High(FSubs) do
    begin
      if (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then Continue;
      if not IsConnectedToMain(i) then Continue;
      FMoveGroup[n] := i;
      b := FSubs[i].Win.GetBounds;
      FMoveGroupStart[n] := SnapPointXY(b.X, b.Y);
      Inc(n);
    end;
    SetLength(FMoveGroup, n);
    SetLength(FMoveGroupStart, n);
    Exit;
  end;

  FDragLeaderIndex := FindSubIndex(ALeader);
  if FDragLeaderIndex = SNAP_NO_ANCHOR then
  begin
    ClearDrag;
    Exit;
  end;
  b := ALeader.GetBounds;
  FDragLeaderStart := SnapPointXY(b.X, b.Y);
end;

procedure TWindowSnapManager.FinishDragSession(ALeader: ISnapWindow);
begin
  if (not DragActive) or (FDragLeader <> ALeader) then Exit;
  if FDragLeader = FMain then
    FinalSnapGroupToStaticWindows
  else
    FinalSnapDraggedSub;
  ClearDrag;
  RebuildSnapGraphInPlace;
end;

function TWindowSnapManager.MoveDragGroup(const TotalDelta: TSnapPoint): Integer;
var
  i, idx: Integer;
  target: TSnapPoint;
  b: TSnapRect;
begin
  Result := 0;
  if not DragActive then Exit;
  if (TotalDelta.X = 0) and (TotalDelta.Y = 0) then Exit;
  FSyncing := True;
  try
    for i := 0 to High(FMoveGroup) do
    begin
      idx := FMoveGroup[i];
      if (idx < 0) or (idx > High(FSubs)) then Continue;
      if (FSubs[idx].Win = nil) or not FSubs[idx].Win.GetVisible then Continue;
      target.X := FMoveGroupStart[i].X + TotalDelta.X;
      target.Y := FMoveGroupStart[i].Y + TotalDelta.Y;
      b := FSubs[idx].Win.GetBounds;
      if (b.X = target.X) and (b.Y = target.Y) then Continue;
      FSubs[idx].Win.MoveTo(target.X, target.Y);
      Inc(Result);
    end;
  finally
    FSyncing := False;
  end;
end;

function TWindowSnapManager.MoveConnectedSubWindows(const Delta: TSnapPoint): Integer;
var
  i: Integer;
  b: TSnapRect;
begin
  Result := 0;
  if ((Delta.X = 0) and (Delta.Y = 0)) or (FMain = nil) then Exit;
  FSyncing := True;
  try
    for i := 0 to High(FSubs) do
    begin
      if (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then Continue;
      if not IsConnectedToMain(i) then Continue;
      b := FSubs[i].Win.GetBounds;
      FSubs[i].Win.MoveTo(b.X + Delta.X, b.Y + Delta.Y);
      Inc(Result);
    end;
  finally
    FSyncing := False;
  end;
end;

function TWindowSnapManager.FinalSnapGroupToStaticWindows: TSnapPoint;
var
  bestXShiftDist, bestYShiftDist, bestXShift, bestYShift: Integer;
  hasXShift, hasYShift: Boolean;
  i, g: Integer;
  staticRect: TSnapRect;
  newX, xDist, newY, yDist: Integer;
  bestGroupShift: TSnapPoint;
  b: TSnapRect;

  procedure AccumulateAxes(const AMoving, AAnchor: TSnapRect);
  begin
    if TrySnapXAxis(AMoving, AAnchor, FSnapThreshold, newX, xDist) and
       (xDist < bestXShiftDist) then
    begin
      bestXShiftDist := xDist;
      bestXShift := newX - AMoving.X;
      hasXShift := True;
    end;
    if TrySnapYAxis(AMoving, AAnchor, FSnapThreshold, newY, yDist) and
       (yDist < bestYShiftDist) then
    begin
      bestYShiftDist := yDist;
      bestYShift := newY - AMoving.Y;
      hasYShift := True;
    end;
  end;

  procedure AccumulateScreenAxes(const AMoving: TSnapRect);
  begin
    if TrySnapXAxisToScreen(AMoving, FScreenRect, FSnapThreshold, newX, xDist) and
       (xDist < bestXShiftDist) then
    begin
      bestXShiftDist := xDist;
      bestXShift := newX - AMoving.X;
      hasXShift := True;
    end;
    if TrySnapYAxisToScreen(AMoving, FScreenRect, FSnapThreshold, newY, yDist) and
       (yDist < bestYShiftDist) then
    begin
      bestYShiftDist := yDist;
      bestYShift := newY - AMoving.Y;
      hasYShift := True;
    end;
  end;

begin
  Result := SnapPointXY(0, 0);
  if (FMain = nil) or (not DragActive) or (FDragLeader <> FMain) then Exit;

  bestXShiftDist := High(Integer);
  bestYShiftDist := High(Integer);
  bestXShift := 0;
  bestYShift := 0;
  hasXShift := False;
  hasYShift := False;

  for i := 0 to High(FSubs) do
  begin
    if IsSnappedIndex(i) or (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then
      Continue;
    staticRect := FSubs[i].Win.GetBounds;
    AccumulateAxes(FMain.GetBounds, staticRect);
    for g := 0 to High(FMoveGroup) do
    begin
      if (FMoveGroup[g] < 0) or (FMoveGroup[g] > High(FSubs)) then Continue;
      if (FSubs[FMoveGroup[g]].Win = nil) or not FSubs[FMoveGroup[g]].Win.GetVisible then
        Continue;
      AccumulateAxes(FSubs[FMoveGroup[g]].Win.GetBounds, staticRect);
    end;
  end;

  AccumulateScreenAxes(FMain.GetBounds);
  for g := 0 to High(FMoveGroup) do
  begin
    if (FMoveGroup[g] < 0) or (FMoveGroup[g] > High(FSubs)) then Continue;
    if (FSubs[FMoveGroup[g]].Win = nil) or not FSubs[FMoveGroup[g]].Win.GetVisible then
      Continue;
    AccumulateScreenAxes(FSubs[FMoveGroup[g]].Win.GetBounds);
  end;

  if hasXShift then bestGroupShift.X := bestXShift else bestGroupShift.X := 0;
  if hasYShift then bestGroupShift.Y := bestYShift else bestGroupShift.Y := 0;
  if SnapPointIsZero(bestGroupShift) then Exit;

  FSyncing := True;
  try
    b := FMain.GetBounds;
    FMain.MoveTo(b.X + bestGroupShift.X, b.Y + bestGroupShift.Y);
    for g := 0 to High(FMoveGroup) do
    begin
      if (FMoveGroup[g] < 0) or (FMoveGroup[g] > High(FSubs)) then Continue;
      if (FSubs[FMoveGroup[g]].Win = nil) or not FSubs[FMoveGroup[g]].Win.GetVisible then
        Continue;
      b := FSubs[FMoveGroup[g]].Win.GetBounds;
      FSubs[FMoveGroup[g]].Win.MoveTo(b.X + bestGroupShift.X, b.Y + bestGroupShift.Y);
    end;
  finally
    FSyncing := False;
  end;
  Result := bestGroupShift;
end;

function TWindowSnapManager.FinalSnapDraggedSub: TSnapPoint;
var
  entryWin: ISnapWindow;
  movingRect, groupRect, mainRect: TSnapRect;
  bestXDist, bestYDist, bestNewX, bestNewY: Integer;
  hasXSnap, hasYSnap: Boolean;
  newX, xDist, newY, yDist, i: Integer;
  oldPos, bestPos: TSnapPoint;

  procedure ConsiderAxes(const ARect: TSnapRect);
  begin
    if TrySnapXAxis(movingRect, ARect, FSnapThreshold, newX, xDist) and
       (xDist < bestXDist) then
    begin
      bestXDist := xDist;
      bestNewX := newX;
      hasXSnap := True;
    end;
    if TrySnapYAxis(movingRect, ARect, FSnapThreshold, newY, yDist) and
       (yDist < bestYDist) then
    begin
      bestYDist := yDist;
      bestNewY := newY;
      hasYSnap := True;
    end;
  end;

begin
  Result := SnapPointXY(0, 0);
  if (FMain = nil) or (not DragActive) or (FDragLeader = FMain) then Exit;
  if (FDragLeaderIndex < 0) or (FDragLeaderIndex > High(FSubs)) then Exit;
  entryWin := FSubs[FDragLeaderIndex].Win;
  if entryWin = nil then Exit;

  movingRect := entryWin.GetBounds;
  bestXDist := High(Integer);
  bestYDist := High(Integer);
  bestNewX := movingRect.X;
  bestNewY := movingRect.Y;
  hasXSnap := False;
  hasYSnap := False;

  if FMain.GetVisible then
    ConsiderAxes(FMain.GetBounds);

  groupRect := ConnectedGroupRectExcluding(FDragLeaderIndex);
  mainRect := FMain.GetBounds;
  if groupRect.IsValid and not groupRect.Equal(mainRect) then
    ConsiderAxes(groupRect);

  for i := 0 to High(FSubs) do
  begin
    if (i = FDragLeaderIndex) or (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then
      Continue;
    ConsiderAxes(FSubs[i].Win.GetBounds);
  end;

  if TrySnapXAxisToScreen(movingRect, FScreenRect, FSnapThreshold, newX, xDist) and
     (xDist < bestXDist) then
  begin
    bestXDist := xDist;
    bestNewX := newX;
    hasXSnap := True;
  end;
  if TrySnapYAxisToScreen(movingRect, FScreenRect, FSnapThreshold, newY, yDist) and
     (yDist < bestYDist) then
  begin
    bestYDist := yDist;
    bestNewY := newY;
    hasYSnap := True;
  end;

  if (not hasXSnap) and (not hasYSnap) then Exit;

  oldPos := SnapPointXY(entryWin.GetBounds.X, entryWin.GetBounds.Y);
  bestPos := CombineAxisSnap(movingRect, hasXSnap, bestNewX, hasYSnap, bestNewY);

  FSyncing := True;
  try
    entryWin.MoveTo(bestPos.X, bestPos.Y);
  finally
    FSyncing := False;
  end;
  Result := SnapPointXY(bestPos.X - oldPos.X, bestPos.Y - oldPos.Y);
end;

procedure TWindowSnapManager.OnSubResized(ASub: ISnapWindow; Edges: TSnapEdges);
var
  movingIndex, i, bestDistance, distance: Integer;
  movingRect, bestRect, snappedRect, groupRect: TSnapRect;

  procedure ConsiderRect(const AnchorRect: TSnapRect);
  begin
    if not AnchorRect.IsValid then Exit;
    if not TrySnapResizeToAnchor(movingRect, Edges, AnchorRect, FSnapThreshold,
         snappedRect, distance) then
      Exit;
    if distance < bestDistance then
    begin
      bestDistance := distance;
      bestRect := snappedRect;
    end;
  end;

begin
  if FSyncing or (FMain = nil) or (ASub = nil) or (Edges = []) then Exit;
  movingIndex := FindSubIndex(ASub);
  if movingIndex = SNAP_NO_ANCHOR then Exit;

  movingRect := ASub.GetBounds;
  bestRect := movingRect;
  bestDistance := High(Integer);

  ConsiderRect(FMain.GetBounds);
  groupRect := ConnectedGroupRectExcluding(movingIndex);
  if groupRect.IsValid then
    ConsiderRect(groupRect);
  for i := 0 to High(FSubs) do
  begin
    if (i = movingIndex) or (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then
      Continue;
    ConsiderRect(FSubs[i].Win.GetBounds);
  end;

  if TrySnapResizeToScreen(movingRect, Edges, FScreenRect, FSnapThreshold,
       snappedRect, distance) and (distance < bestDistance) then
  begin
    bestDistance := distance;
    bestRect := snappedRect;
  end;

  if (bestRect.W = ASub.GetBounds.W) and (bestRect.H = ASub.GetBounds.H) then
    Exit;

  FSyncing := True;
  try
    ASub.ResizeTo(bestRect.W, bestRect.H);
  finally
    FSyncing := False;
  end;
end;

procedure TWindowSnapManager.OnSubResizeFinished(ASub: ISnapWindow; Edges: TSnapEdges);
begin
  OnSubResized(ASub, Edges);
  RebuildSnapGraphInPlace;
end;

end.
