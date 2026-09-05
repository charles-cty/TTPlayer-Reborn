unit UWindowSnapManager;

{$mode objfpc}{$H+}

// 窗口吸附管理器，对应 Qt 版 src/ui/WindowSnapManager。
//
// 工作原理（对齐原版 TTPlayer：拖动过程中磁吸，而不是松手才吸）：
//   - 子窗口可吸附到主窗口，或吸附到已连接主窗口的子窗口。
//   - 主窗口移动时，仅移动“直接或间接连接到主窗口”的吸附窗口。
//   - 子窗口手动拖动只影响自身位置与后续吸附关系，不带动其他窗口。
//   - 拖动中磁吸按「光标推出的逻辑位置」判定，而不是已经吸住的窗口
//     矩形。否则 Win32 HTCAPTION 会把拖动原点重定到窗口上，永远拉不开。
//   - X/Y 独立吸住：沿贴边滑动不会把另一轴一起松开。某轴要垂直拉开
//     SnapReleaseThreshold（1× 吸入）才脱离。LiveAttachOnMainDragEnabled=False
//     时只联动、松手再吸。
//   - 任务栏激活/Z 序成组不在本单元：宿主把辅助窗口绑成主窗口的
//     owned/transient 子窗口（见 PrepareAuxOwnedWindow），与是否吸附无关。
//   - 换肤只改尺寸、左上角不动。CaptureSnapFits 记下贴合边，
//     RefitSnappedWindows 按新尺寸重新贴紧，吸附图本身不拆。
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
    // 换肤重贴用 LCL 客户区，避免 Win32 把 native/DPI 坐标和 SetBounds 混用。
    function GetLayoutBounds: TSnapRect;
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
    function GetLayoutBounds: TSnapRect;
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

    function  GetSnapReleaseThreshold: Integer;
    property  SnapReleaseThreshold: Integer read GetSnapReleaseThreshold;

    procedure OnMainMoved(DX, DY: Integer);
    procedure OnSubMoved(ASub: ISnapWindow; DX, DY: Integer);
    procedure OnDragLogicalMove(AX, AY: Integer);
    procedure OnSubResized(ASub: ISnapWindow; Edges: TSnapEdges);
    procedure OnSubResizeFinished(ASub: ISnapWindow; Edges: TSnapEdges);
    procedure OnDragStarted(ALeader: ISnapWindow);
    procedure OnDragFinished(ALeader: ISnapWindow);
    procedure RebuildSnapGraph;
    // 换肤期间禁止 Show/Hide 重建吸附图（会清掉贴合边、用 10px 阈值重吸）。
    procedure BeginLayoutChange;
    procedure EndLayoutChange;
    // 按当前几何记下每条吸附边（对边相贴 / 同侧对齐）。
    procedure CaptureSnapFits;
    // 换肤改尺寸后：按贴合边把窗口重新贴紧，不拆吸附图。
    procedure RefitSnappedWindows;
    function  LayoutRefitXY(AWin: ISnapWindow; out X, Y: Integer): Boolean;

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
        FitTarget: Integer; // 重贴时对齐的窗口；可能与 Anchor 不同
        FitX: TSnapFitX;
        FitY: TSnapFitY;
        CaptureX, CaptureY: Integer;
      end;

    var
      FMain: ISnapWindow;
      FSubs: array of TSubEntry;
      FSnapThreshold: Integer;
      FScreenRect: TSnapRect;
      FLiveAttachOnMainDragEnabled: Boolean;
      FSyncing: Boolean;
      FLayoutChangeLock: Integer;

      FDragLeader: ISnapWindow;
      FDragLeaderIndex: Integer;
      FDragLeaderStart: TSnapPoint;
      FMoveGroup: array of Integer;
      FMoveGroupStart: array of TSnapPoint;
      FHeldX, FHeldY: Boolean;
      FHeldLeaderPos: TSnapPoint;

    function  DragActive: Boolean;
    procedure ClearDrag;
    procedure ApplyDragLogical(AX, AY: Integer);
    procedure MoveLeaderTo(AX, AY: Integer);
    function  IsSnappedIndex(SubIndex: Integer): Boolean;
    function  IsConnectedToMain(SubIndex: Integer): Boolean;
    function  WouldCreateCycle(MovingIndex, AnchorIndex: Integer): Boolean;
    function  AnchorWin(SubIndex: Integer): ISnapWindow;
    function  ConnectedGroupRectExcluding(ExcludeIndex: Integer): TSnapRect;
    function  TrySnap(MovingIndex: Integer; MoveToSnap: Boolean): Boolean;
    procedure ClearAllAnchors;
    procedure RefreshOffsets;
    procedure RecordFits(SubIndex: Integer);
    function  FitTargetWin(SubIndex: Integer): ISnapWindow;
    procedure BeginDragSession(ALeader: ISnapWindow);
    procedure FinishDragSession(ALeader: ISnapWindow);
    function  MoveDragGroup(const TotalDelta: TSnapPoint): Integer;
    function  MoveConnectedSubWindows(const Delta: TSnapPoint): Integer;
    function  FinalSnapGroupToStaticWindows: TSnapPoint;
    function  FinalSnapDraggedSub: TSnapPoint;
    procedure RebuildSnapGraphInPlace;
    function  DescribeGraph: string;
  end;

implementation

uses
  ULog;

function SnapWinName(AWin: ISnapWindow): string;
begin
  if AWin = nil then
    Exit('-');
  Result := AWin.GetName;
  if Result = '' then
    Result := '-';
end;

function SnapRectLabel(const R: TSnapRect): string;
begin
  Result := Format('%d,%d %dx%d', [R.X, R.Y, R.W, R.H]);
end;

function SnapEdgesLabel(Edges: TSnapEdges): string;
begin
  Result := '';
  if seRight in Edges then
    Result := Result + 'R';
  if seBottom in Edges then
    Result := Result + 'B';
  if Result = '' then
    Result := '-';
end;

function HeldAxesLabel(HeldX, HeldY: Boolean): string;
begin
  if HeldX and HeldY then
    Result := 'XY'
  else if HeldX then
    Result := 'X'
  else if HeldY then
    Result := 'Y'
  else
    Result := '-';
end;

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

function TMemorySnapWindow.GetLayoutBounds: TSnapRect;
begin
  Result := GetBounds;
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
  FLayoutChangeLock := 0;
  ClearDrag;
end;

destructor TWindowSnapManager.Destroy;
begin
  ClearDrag;
  SetLength(FSubs, 0);
  FMain := nil;
  inherited Destroy;
end;

function TWindowSnapManager.DescribeGraph: string;
var
  i: Integer;
  b: TSnapRect;
  an, item: string;
begin
  Result := '';
  if FMain <> nil then
  begin
    b := FMain.GetBounds;
    Result := 'main=' + SnapWinName(FMain) + '[' + SnapRectLabel(b) + ']';
  end;
  for i := 0 to High(FSubs) do
  begin
    if FSubs[i].Win = nil then Continue;
    b := FSubs[i].Win.GetBounds;
    if FSubs[i].Anchor = SNAP_MAIN_ANCHOR then
      an := 'main'
    else if FSubs[i].Anchor = SNAP_NO_ANCHOR then
      an := '-'
    else if (FSubs[i].Anchor >= 0) and (FSubs[i].Anchor <= High(FSubs)) then
      an := SnapWinName(FSubs[FSubs[i].Anchor].Win)
    else
      an := '?';
    item := SnapWinName(FSubs[i].Win) + '>' + an + '[' + SnapRectLabel(b) + ']';
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + item;
  end;
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
  FSubs[n].FitTarget := SNAP_NO_ANCHOR;
  FSubs[n].FitX := sfxNone;
  FSubs[n].FitY := sfyNone;
  FSubs[n].CaptureX := 0;
  FSubs[n].CaptureY := 0;
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
    if FSubs[i].FitTarget = idx then
      FSubs[i].FitTarget := SNAP_NO_ANCHOR
    else if (idx <> last) and (FSubs[i].FitTarget = last) then
      FSubs[i].FitTarget := idx;
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
  FHeldX := False;
  FHeldY := False;
  FHeldLeaderPos := SnapPointXY(0, 0);
end;

function TWindowSnapManager.GetSnapReleaseThreshold: Integer;
begin
  Result := FSnapThreshold; // 1× 吸入阈值
end;

procedure TWindowSnapManager.MoveLeaderTo(AX, AY: Integer);
begin
  if FDragLeader = nil then Exit;
  FSyncing := True;
  try
    FDragLeader.MoveTo(AX, AY);
  finally
    FSyncing := False;
  end;
end;

procedure TWindowSnapManager.ApplyDragLogical(AX, AY: Integer);
var
  outX, outY, rel: Integer;
  wasX, wasY: Boolean;
begin
  if (not DragActive) or (FDragLeader = nil) then Exit;
  rel := GetSnapReleaseThreshold;
  wasX := FHeldX;
  wasY := FHeldY;

  outX := AX;
  outY := AY;
  if FHeldX then
  begin
    if Abs(AX - FHeldLeaderPos.X) > rel then
      FHeldX := False
    else
      outX := FHeldLeaderPos.X;
  end;
  if FHeldY then
  begin
    if Abs(AY - FHeldLeaderPos.Y) > rel then
      FHeldY := False
    else
      outY := FHeldLeaderPos.Y;
  end;

  if wasX and not FHeldX then
    LogInfoFmt('snap', 'Release X %s pointer=%d held=%d',
      [SnapWinName(FDragLeader), AX, FHeldLeaderPos.X]);
  if wasY and not FHeldY then
    LogInfoFmt('snap', 'Release Y %s pointer=%d held=%d',
      [SnapWinName(FDragLeader), AY, FHeldLeaderPos.Y]);

  MoveLeaderTo(outX, outY);
  if FDragLeader = FMain then
    MoveDragGroup(SnapPointXY(outX - FDragLeaderStart.X, outY - FDragLeaderStart.Y));

  if not FLiveAttachOnMainDragEnabled then Exit;
  if FHeldX and FHeldY then Exit;

  if FDragLeader = FMain then
    FinalSnapGroupToStaticWindows
  else
    FinalSnapDraggedSub;
end;

procedure TWindowSnapManager.OnDragLogicalMove(AX, AY: Integer);
begin
  if FSyncing or (FMain = nil) then Exit;
  ApplyDragLogical(AX, AY);
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
    FSubs[i].FitTarget := SNAP_NO_ANCHOR;
    FSubs[i].FitX := sfxNone;
    FSubs[i].FitY := sfyNone;
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
      FSubs[i].FitTarget := SNAP_NO_ANCHOR;
      FSubs[i].FitX := sfxNone;
      FSubs[i].FitY := sfyNone;
      Continue;
    end;
    wb := FSubs[i].Win.GetBounds;
    ab := anchor.GetBounds;
    FSubs[i].SnapOffset := SnapPointXY(wb.X - ab.X, wb.Y - ab.Y);
  end;
end;

function TWindowSnapManager.FitTargetWin(SubIndex: Integer): ISnapWindow;
var
  t: Integer;
begin
  Result := nil;
  if (SubIndex < 0) or (SubIndex > High(FSubs)) then Exit;
  t := FSubs[SubIndex].FitTarget;
  if t = SNAP_MAIN_ANCHOR then
    Result := FMain
  else if (t >= 0) and (t <= High(FSubs)) then
    Result := FSubs[t].Win
  else
    Result := AnchorWin(SubIndex);
end;

procedure TWindowSnapManager.RecordFits(SubIndex: Integer);
var
  child: TSnapRect;
  fx: TSnapFitX;
  fy: TSnapFitY;
  i, score, bestScore: Integer;
  prefer: Integer;

  procedure Consider(Target: Integer; const R: TSnapRect);
  begin
    if not R.IsValid then Exit;
    fx := ClassifySnapFitX(child, R, kSnapFitAlignTolerance);
    fy := ClassifySnapFitY(child, R, kSnapFitAlignTolerance);
    if (fx = sfxNone) and (fy = sfyNone) then Exit;
    score := SnapFitXDistance(child, R, fx) + SnapFitYDistance(child, R, fy);
    if score < bestScore then
    begin
      bestScore := score;
      FSubs[SubIndex].FitTarget := Target;
      FSubs[SubIndex].FitX := fx;
      FSubs[SubIndex].FitY := fy;
    end
    else if (score = bestScore) and (Target = prefer) then
    begin
      FSubs[SubIndex].FitTarget := Target;
      FSubs[SubIndex].FitX := fx;
      FSubs[SubIndex].FitY := fy;
    end;
  end;

begin
  if (SubIndex < 0) or (SubIndex > High(FSubs)) then Exit;
  FSubs[SubIndex].FitTarget := SNAP_NO_ANCHOR;
  FSubs[SubIndex].FitX := sfxNone;
  FSubs[SubIndex].FitY := sfyNone;
  if not IsSnappedIndex(SubIndex) or (FSubs[SubIndex].Win = nil) then Exit;
  child := FSubs[SubIndex].Win.GetLayoutBounds;
  prefer := FSubs[SubIndex].Anchor;
  bestScore := High(Integer);
  if (FMain <> nil) and FMain.GetVisible then
    Consider(SNAP_MAIN_ANCHOR, FMain.GetLayoutBounds);
  for i := 0 to High(FSubs) do
  begin
    if i = SubIndex then Continue;
    if (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then Continue;
    if not IsConnectedToMain(i) then Continue;
    Consider(i, FSubs[i].Win.GetLayoutBounds);
  end;
  if FSubs[SubIndex].FitTarget = SNAP_NO_ANCHOR then
    FSubs[SubIndex].FitTarget := prefer;
  if (FSubs[SubIndex].FitX = sfxNone) and (FSubs[SubIndex].FitY = sfyNone) then
  begin
    if prefer = SNAP_MAIN_ANCHOR then
    begin
      if FMain <> nil then
        ForceDockFit(child, FMain.GetLayoutBounds, fx, fy);
    end
    else if (prefer >= 0) and (prefer <= High(FSubs)) and (FSubs[prefer].Win <> nil) then
      ForceDockFit(child, FSubs[prefer].Win.GetLayoutBounds, fx, fy);
    FSubs[SubIndex].FitX := fx;
    FSubs[SubIndex].FitY := fy;
  end;
end;

procedure TWindowSnapManager.BeginLayoutChange;
begin
  Inc(FLayoutChangeLock);
end;

procedure TWindowSnapManager.EndLayoutChange;
begin
  if FLayoutChangeLock <= 0 then Exit;
  Dec(FLayoutChangeLock);
  // 不要在这里 RebuildSnapGraphInPlace：尺寸差常大于 2px，就地重建会拆掉吸附。
  // 贴合边已由 RefitSnappedWindows 按新尺寸对齐，RefreshOffsets 保持连通。
end;

procedure TWindowSnapManager.CaptureSnapFits;
var
  assigned: array of Boolean;
  i, j, n: Integer;
  child, ab: TSnapRect;
  fx: TSnapFitX;
  fy: TSnapFitY;
  changed: Boolean;
begin
  n := Length(FSubs);
  SetLength(assigned, n);
  for i := 0 to n - 1 do
  begin
    assigned[i] := False;
    FSubs[i].FitTarget := SNAP_NO_ANCHOR;
    FSubs[i].FitX := sfxNone;
    FSubs[i].FitY := sfyNone;
    if FSubs[i].Win <> nil then
    begin
      child := FSubs[i].Win.GetLayoutBounds;
      FSubs[i].CaptureX := child.X;
      FSubs[i].CaptureY := child.Y;
    end;
  end;

  // 从主窗向外：只把真正挨着的窗口链起来，避免 EQ/歌词/列表都贴到主窗底边。
  changed := True;
  while changed do
  begin
    changed := False;
    for i := 0 to n - 1 do
    begin
      if assigned[i] then Continue;
      if not IsSnappedIndex(i) then Continue;
      if (FSubs[i].Win = nil) or not FSubs[i].Win.GetVisible then Continue;
      child := FSubs[i].Win.GetLayoutBounds;
      if (FMain <> nil) and FMain.GetVisible then
      begin
        ab := FMain.GetLayoutBounds;
        if TouchingDock(child, ab, fx, fy) then
        begin
          FSubs[i].FitTarget := SNAP_MAIN_ANCHOR;
          FSubs[i].FitX := fx;
          FSubs[i].FitY := fy;
          assigned[i] := True;
          changed := True;
          LogInfoFmt('snap',
            'Capture %s target=main fitX=%d fitY=%d @%d,%d %dx%d',
            [FSubs[i].Win.GetName, Ord(fx), Ord(fy),
             child.X, child.Y, child.W, child.H]);
          Continue;
        end;
      end;
      for j := 0 to n - 1 do
      begin
        if not assigned[j] then Continue;
        if (FSubs[j].Win = nil) or not FSubs[j].Win.GetVisible then Continue;
        ab := FSubs[j].Win.GetLayoutBounds;
        if TouchingDock(child, ab, fx, fy) then
        begin
          FSubs[i].FitTarget := j;
          FSubs[i].FitX := fx;
          FSubs[i].FitY := fy;
          assigned[i] := True;
          changed := True;
          LogInfoFmt('snap',
            'Capture %s target=%s#%d fitX=%d fitY=%d @%d,%d %dx%d',
            [FSubs[i].Win.GetName, FSubs[j].Win.GetName, j, Ord(fx), Ord(fy),
             child.X, child.Y, child.W, child.H]);
          Break;
        end;
      end;
    end;
  end;

  for i := 0 to n - 1 do
  begin
    if assigned[i] then Continue;
    if not IsSnappedIndex(i) then Continue;
    if (FSubs[i].Win = nil) or (FMain = nil) then Continue;
    child := FSubs[i].Win.GetLayoutBounds;
    ForceDockFit(child, FMain.GetLayoutBounds, fx, fy);
    FSubs[i].FitTarget := SNAP_MAIN_ANCHOR;
    FSubs[i].FitX := fx;
    FSubs[i].FitY := fy;
    LogInfoFmt('snap',
      'Capture %s force-dock main fitX=%d fitY=%d @%d,%d %dx%d',
      [FSubs[i].Win.GetName, Ord(fx), Ord(fy),
       child.X, child.Y, child.W, child.H]);
  end;
end;

function TWindowSnapManager.LayoutRefitXY(AWin: ISnapWindow; out X, Y: Integer): Boolean;
var
  idx: Integer;
  child, dock: TSnapRect;
  target: ISnapWindow;
begin
  Result := False;
  X := 0;
  Y := 0;
  idx := FindSubIndex(AWin);
  if not IsSnappedIndex(idx) or (AWin = nil) then Exit;
  if (FSubs[idx].FitX = sfxNone) and (FSubs[idx].FitY = sfyNone) then
    RecordFits(idx);
  target := FitTargetWin(idx);
  if target = nil then Exit;
  child := AWin.GetLayoutBounds;
  dock := target.GetLayoutBounds;
  if not dock.IsValid then Exit;
  if FSubs[idx].FitX = sfxNone then
    X := child.X
  else
    X := ApplySnapFitX(child, dock, FSubs[idx].FitX, 0);
  if FSubs[idx].FitY = sfyNone then
    Y := child.Y
  else
    Y := ApplySnapFitY(child, dock, FSubs[idx].FitY, 0);
  Result := True;
end;

procedure TWindowSnapManager.RefitSnappedWindows;
var
  placed: array of Boolean;
  i, j, n, a, b, tmp, newX, newY, cursor, guard: Integer;
  order: array of Integer;
  cnt: Integer;
  child, dock: TSnapRect;
  progress: Boolean;

  procedure PlaceGroup(FitTarget: Integer; ATarget: ISnapWindow);
  var
    sideY: TSnapFitY;
    sideX: TSnapFitX;
    p, q: Integer;
  begin
    if ATarget = nil then Exit;
    dock := ATarget.GetLayoutBounds;
    if not dock.IsValid then Exit;

    for sideY := sfyAdjBelow to sfyAdjAbove do
    begin
      cnt := 0;
      SetLength(order, n);
      for p := 0 to n - 1 do
      begin
        if placed[p] then Continue;
        if not IsSnappedIndex(p) then Continue;
        if (FSubs[p].Win = nil) or not FSubs[p].Win.GetVisible then Continue;
        if FSubs[p].FitTarget <> FitTarget then Continue;
        if FSubs[p].FitY <> sideY then Continue;
        order[cnt] := p;
        Inc(cnt);
      end;
      for p := 0 to cnt - 2 do
        for q := p + 1 to cnt - 1 do
        begin
          a := order[p];
          b := order[q];
          if ((sideY = sfyAdjBelow) and (FSubs[a].CaptureY > FSubs[b].CaptureY)) or
             ((sideY = sfyAdjAbove) and (FSubs[a].CaptureY < FSubs[b].CaptureY)) then
          begin
            tmp := order[p];
            order[p] := order[q];
            order[q] := tmp;
          end;
        end;
      if sideY = sfyAdjBelow then
        cursor := dock.BottomExcl
      else
        cursor := dock.Y;
      for p := 0 to cnt - 1 do
      begin
        i := order[p];
        child := FSubs[i].Win.GetLayoutBounds;
        if sideY = sfyAdjBelow then
          newY := cursor
        else
          newY := cursor - child.H;
        if FSubs[i].FitX = sfxNone then
          newX := child.X
        else
          newX := ApplySnapFitX(child, dock, FSubs[i].FitX, 0);
        FSyncing := True;
        try
          FSubs[i].Win.MoveTo(newX, newY);
        finally
          FSyncing := False;
        end;
        placed[i] := True;
        progress := True;
        LogInfoFmt('snap', 'Place %s Y -> %d,%d',
          [FSubs[i].Win.GetName, newX, newY]);
        child := FSubs[i].Win.GetLayoutBounds;
        if sideY = sfyAdjBelow then
          cursor := child.Y + child.H
        else
          cursor := child.Y;
      end;
    end;

    for sideX := sfxAdjRight to sfxAdjLeft do
    begin
      cnt := 0;
      SetLength(order, n);
      for p := 0 to n - 1 do
      begin
        if placed[p] then Continue;
        if not IsSnappedIndex(p) then Continue;
        if (FSubs[p].Win = nil) or not FSubs[p].Win.GetVisible then Continue;
        if FSubs[p].FitTarget <> FitTarget then Continue;
        if FSubs[p].FitX <> sideX then Continue;
        if FSubs[p].FitY in [sfyAdjBelow, sfyAdjAbove] then Continue;
        order[cnt] := p;
        Inc(cnt);
      end;
      for p := 0 to cnt - 2 do
        for q := p + 1 to cnt - 1 do
        begin
          a := order[p];
          b := order[q];
          if ((sideX = sfxAdjRight) and (FSubs[a].CaptureX > FSubs[b].CaptureX)) or
             ((sideX = sfxAdjLeft) and (FSubs[a].CaptureX < FSubs[b].CaptureX)) then
          begin
            tmp := order[p];
            order[p] := order[q];
            order[q] := tmp;
          end;
        end;
      if sideX = sfxAdjRight then
        cursor := dock.RightExcl
      else
        cursor := dock.X;
      for p := 0 to cnt - 1 do
      begin
        i := order[p];
        child := FSubs[i].Win.GetLayoutBounds;
        if sideX = sfxAdjRight then
          newX := cursor
        else
          newX := cursor - child.W;
        if FSubs[i].FitY = sfyNone then
          newY := child.Y
        else
          newY := ApplySnapFitY(child, dock, FSubs[i].FitY, 0);
        FSyncing := True;
        try
          FSubs[i].Win.MoveTo(newX, newY);
        finally
          FSyncing := False;
        end;
        placed[i] := True;
        progress := True;
        LogInfoFmt('snap', 'Place %s X -> %d,%d',
          [FSubs[i].Win.GetName, newX, newY]);
        child := FSubs[i].Win.GetLayoutBounds;
        if sideX = sfxAdjRight then
          cursor := child.X + child.W
        else
          cursor := child.X;
      end;
    end;
  end;

begin
  if FMain = nil then Exit;
  if DragActive then Exit;
  n := Length(FSubs);
  SetLength(placed, n);
  for i := 0 to n - 1 do
    placed[i] := False;
  guard := 0;
  progress := True;
  while progress and (guard <= n + 1) do
  begin
    Inc(guard);
    progress := False;
    PlaceGroup(SNAP_MAIN_ANCHOR, FMain);
    for j := 0 to n - 1 do
      if placed[j] then
        PlaceGroup(j, FSubs[j].Win);
  end;
  RefreshOffsets;
end;

procedure TWindowSnapManager.RebuildSnapGraph;
var
  changed: Boolean;
  i: Integer;
begin
  if FMain = nil then Exit;
  if FLayoutChangeLock > 0 then Exit;
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
  LogInfoFmt('snap', 'Rebuild move %s', [DescribeGraph]);
end;

procedure TWindowSnapManager.RebuildSnapGraphInPlace;
var
  changed: Boolean;
  i: Integer;
begin
  if FMain = nil then Exit;
  if FLayoutChangeLock > 0 then Exit;
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
  LogInfoFmt('snap', 'Rebuild inplace %s', [DescribeGraph]);
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
    // 就地重建：已经贴上的那一轴即可建边。不要因为另一轴没对齐
    // （沿边滑开）就把连通关系拆掉。
    if not (((hasXSnap and (Abs(bestNewX - curPos.X) <= 2)) or
             (hasYSnap and (Abs(bestNewY - curPos.Y) <= 2)))) then
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
  RecordFits(MovingIndex);
  Result := True;
end;

procedure TWindowSnapManager.OnMainMoved(DX, DY: Integer);
var
  mb: TSnapRect;
begin
  if FSyncing or (FMain = nil) then Exit;
  if (DX = 0) and (DY = 0) then Exit;

  if DragActive and (FDragLeader = FMain) then
  begin
    mb := FMain.GetBounds;
    ApplyDragLogical(mb.X, mb.Y);
    Exit;
  end;

  MoveConnectedSubWindows(SnapPointXY(DX, DY));
end;

procedure TWindowSnapManager.OnSubMoved(ASub: ISnapWindow; DX, DY: Integer);
begin
  if FSyncing or (FMain = nil) or (ASub = nil) then Exit;
  if (DX = 0) and (DY = 0) then Exit;
  if DragActive and (FDragLeader = ASub) then
  begin
    ApplyDragLogical(ASub.GetBounds.X, ASub.GetBounds.Y);
    Exit;
  end;
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
    LogInfoFmt('snap', 'Drag start %s @%s group=%d held=%s',
      [SnapWinName(FMain), SnapRectLabel(FMain.GetBounds), n,
       HeldAxesLabel(FHeldX, FHeldY)]);
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
  if IsConnectedToMain(FDragLeaderIndex) then
  begin
    FHeldX := True;
    FHeldY := True;
    FHeldLeaderPos := FDragLeaderStart;
  end;
  LogInfoFmt('snap', 'Drag start %s @%s connected=%s held=%s',
    [SnapWinName(ALeader), SnapRectLabel(b),
     BoolToStr(IsConnectedToMain(FDragLeaderIndex), True),
     HeldAxesLabel(FHeldX, FHeldY)]);
end;

procedure TWindowSnapManager.FinishDragSession(ALeader: ISnapWindow);
var
  leader: string;
  b: TSnapRect;
begin
  if (not DragActive) or (FDragLeader <> ALeader) then Exit;
  leader := SnapWinName(FDragLeader);
  if FDragLeader = FMain then
    FinalSnapGroupToStaticWindows
  else
    FinalSnapDraggedSub;
  b := FDragLeader.GetBounds;
  ClearDrag;
  RebuildSnapGraphInPlace;
  LogInfoFmt('snap', 'Drag end %s @%s', [leader, SnapRectLabel(b)]);
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

  if FHeldX then hasXShift := False;
  if FHeldY then hasYShift := False;
  if hasXShift then bestGroupShift.X := bestXShift else bestGroupShift.X := 0;
  if hasYShift then bestGroupShift.Y := bestYShift else bestGroupShift.Y := 0;
  if (not hasXShift) and (not hasYShift) then Exit;
  if hasXShift then FHeldX := True;
  if hasYShift then FHeldY := True;

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
  b := FMain.GetBounds;
  if FHeldX then FHeldLeaderPos.X := b.X;
  if FHeldY then FHeldLeaderPos.Y := b.Y;
  LogInfoFmt('snap', 'Attach group d=%d,%d held=%s main@%s',
    [bestGroupShift.X, bestGroupShift.Y, HeldAxesLabel(FHeldX, FHeldY),
     SnapRectLabel(b)]);
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

  if FHeldX then hasXSnap := False;
  if FHeldY then hasYSnap := False;
  if (not hasXSnap) and (not hasYSnap) then Exit;

  oldPos := SnapPointXY(entryWin.GetBounds.X, entryWin.GetBounds.Y);
  bestPos := CombineAxisSnap(movingRect, hasXSnap, bestNewX, hasYSnap, bestNewY);
  if FHeldX then bestPos.X := FHeldLeaderPos.X;
  if FHeldY then bestPos.Y := FHeldLeaderPos.Y;

  FSyncing := True;
  try
    entryWin.MoveTo(bestPos.X, bestPos.Y);
  finally
    FSyncing := False;
  end;
  Result := SnapPointXY(bestPos.X - oldPos.X, bestPos.Y - oldPos.Y);
  if hasXSnap then
  begin
    FHeldX := True;
    FHeldLeaderPos.X := bestPos.X;
  end;
  if hasYSnap then
  begin
    FHeldY := True;
    FHeldLeaderPos.Y := bestPos.Y;
  end;
  LogInfoFmt('snap', 'Attach %s -> %d,%d d=%d,%d held=%s',
    [SnapWinName(entryWin), bestPos.X, bestPos.Y, Result.X, Result.Y,
     HeldAxesLabel(FHeldX, FHeldY)]);
end;

procedure TWindowSnapManager.OnSubResized(ASub: ISnapWindow; Edges: TSnapEdges);
// 会改窗口尺寸。live 缩放不要每拍调用，否则边缘吸附会把尺寸拽离指针；
// 松手走 OnSubResizeFinished。
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
var
  oldR, newR: TSnapRect;
begin
  if ASub = nil then
    oldR := SnapRectXYWH(0, 0, 0, 0)
  else
    oldR := ASub.GetBounds;
  OnSubResized(ASub, Edges);
  if ASub = nil then
    newR := oldR
  else
    newR := ASub.GetBounds;
  LogInfoFmt('snap', 'Resize end %s edges=%s %s -> %s',
    [SnapWinName(ASub), SnapEdgesLabel(Edges), SnapRectLabel(oldR),
     SnapRectLabel(newR)]);
  RebuildSnapGraphInPlace;
end;

end.
