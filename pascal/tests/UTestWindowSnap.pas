unit UTestWindowSnap;

{$mode objfpc}{$H+}

// Layer 4 扩展：WindowSnapManager 几何与图结构测试。
//
// MR-4：A 向 B 吸附的相对几何 ≡ B 向 A 吸附（角色互换）。
// 其余用例覆盖阈值边界、主窗口联动、子窗口独立拖动、
// 松手吸附、隐藏窗口、就地重建不移动、缩放吸附。

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  UWindowSnapMath, UWindowSnapManager;

type
  TWindowSnapTest = class(TTestCase)
  published
    procedure TestSnapXAxisAdjacent;
    procedure TestSnapXAxisThreshold;
    procedure TestSnapXAxisAlignLeft;
    procedure TestSnapYAxisAdjacent;
    procedure TestSnapScreenEdges;
    procedure TestSnapResizeRight;
    procedure TestMR4SymmetryHorizontal;
    procedure TestMR4SymmetryVertical;
    procedure TestMR4SymmetryIndependentAxes;
    procedure TestSubSnapsToMain;
    procedure TestMainDragMovesConnected;
    procedure TestMainDragSkipsUnconnected;
    procedure TestSubDragDoesNotMoveOthers;
    procedure TestSubDragAwayDetaches;
    procedure TestSubDragNearSnapsOnFinish;
    procedure TestHiddenWindowIgnored;
    procedure TestInPlaceRebuildDoesNotMove;
    procedure TestGroupFollowThenDetach;
    procedure TestResizeSnapToMain;
  end;

implementation

function MakeWin(const AName: string; X, Y, W, H: Integer): ISnapWindow;
begin
  Result := TMemorySnapWindow.Create(AName, X, Y, W, H);
end;

procedure ApplyAxisSnap(var Moving: TSnapRect; const Anchor: TSnapRect);
var
  nx, ny, dx, dy: Integer;
  hx, hy: Boolean;
begin
  hx := TrySnapXAxis(Moving, Anchor, kDefaultSnapThreshold, nx, dx);
  hy := TrySnapYAxis(Moving, Anchor, kDefaultSnapThreshold, ny, dy);
  if hx then Moving.X := nx;
  if hy then Moving.Y := ny;
end;

{ 几何 }

procedure TWindowSnapTest.TestSnapXAxisAdjacent;
var
  moving, anchor: TSnapRect;
  newX, dist: Integer;
begin
  // A 100×50 @ (0,0)，B 100×50 @ (108,0)，间隙 8 ≤ 10
  moving := SnapRectXYWH(0, 0, 100, 50);
  anchor := SnapRectXYWH(108, 0, 100, 50);
  AssertTrue('应吸附到锚点左侧',
    TrySnapXAxis(moving, anchor, 10, newX, dist));
  AssertEquals('相邻：moving.RightExcl = anchor.X', 8, newX);
  AssertEquals('距离为间隙', 8, dist);
end;

procedure TWindowSnapTest.TestSnapXAxisThreshold;
var
  moving, anchor: TSnapRect;
  newX, dist: Integer;
begin
  moving := SnapRectXYWH(0, 0, 100, 50);
  anchor := SnapRectXYWH(111, 0, 100, 50); // 间隙 11
  AssertFalse('超过阈值不应吸附',
    TrySnapXAxis(moving, anchor, 10, newX, dist));

  anchor := SnapRectXYWH(110, 0, 100, 50); // 间隙 10
  AssertTrue('等于阈值应吸附',
    TrySnapXAxis(moving, anchor, 10, newX, dist));
  AssertEquals(10, newX);
end;

procedure TWindowSnapTest.TestSnapXAxisAlignLeft;
var
  moving, anchor: TSnapRect;
  newX, dist: Integer;
begin
  // 重叠区域内同侧对齐：A 与 B 共享左边缘（差 4px）且 Y 重叠
  moving := SnapRectXYWH(4, 10, 100, 80);
  anchor := SnapRectXYWH(0, 0, 100, 50);
  AssertTrue('重叠同侧应吸附',
    TrySnapXAxis(moving, anchor, 10, newX, dist));
  AssertEquals('左边缘对齐到锚点', 0, newX);
end;

procedure TWindowSnapTest.TestSnapYAxisAdjacent;
var
  moving, anchor: TSnapRect;
  newY, dist: Integer;
begin
  moving := SnapRectXYWH(0, 0, 100, 50);
  anchor := SnapRectXYWH(0, 56, 100, 40); // 间隙 6
  AssertTrue(TrySnapYAxis(moving, anchor, 10, newY, dist));
  AssertEquals(6, newY);
end;

procedure TWindowSnapTest.TestSnapScreenEdges;
var
  moving, screen: TSnapRect;
  newX, newY, dist: Integer;
begin
  screen := SnapRectXYWH(0, 0, 1920, 1080);
  moving := SnapRectXYWH(6, 100, 200, 80);
  AssertTrue(TrySnapXAxisToScreen(moving, screen, 10, newX, dist));
  AssertEquals(0, newX);

  moving := SnapRectXYWH(100, 1072, 200, 80); // bottom 1151 vs 1079, dist of bottom edges
  // moving.BottomIncl = 1072+80-1 = 1151, screen.BottomIncl = 1079 → 太远
  moving := SnapRectXYWH(100, 1005, 200, 80); // BottomIncl = 1084, screen 1079, dist 5
  AssertTrue(TrySnapYAxisToScreen(moving, screen, 10, newY, dist));
  AssertEquals('底边对齐', 1080 - 80, newY);
end;

procedure TWindowSnapTest.TestSnapResizeRight;
var
  moving, anchor, snapped: TSnapRect;
  dist: Integer;
begin
  moving := SnapRectXYWH(0, 0, 108, 80);
  anchor := SnapRectXYWH(0, 10, 100, 40); // 右边缘差 8，Y 重叠
  AssertTrue('右边缘应对齐',
    TrySnapResizeToAnchor(moving, [seRight], anchor, 10, snapped, dist));
  AssertEquals('宽度对齐到锚点右边缘', 100, snapped.W);
  AssertEquals(80, snapped.H);
end;

{ MR-4 }

procedure TWindowSnapTest.TestMR4SymmetryHorizontal;
var
  a, b, a0, b0: TSnapRect;
  relAX, relBX: Integer;
begin
  a0 := SnapRectXYWH(0, 0, 100, 50);
  b0 := SnapRectXYWH(108, 0, 100, 50);

  a := a0; b := b0;
  ApplyAxisSnap(a, b);
  relAX := b.X - a.X;

  a := a0; b := b0;
  ApplyAxisSnap(b, a);
  relBX := b.X - a.X;

  AssertEquals('MR-4 水平相对偏移相同', relAX, relBX);
  AssertEquals('吸附后无间隙', a0.W, relAX);
end;

procedure TWindowSnapTest.TestMR4SymmetryVertical;
var
  a, b, a0, b0: TSnapRect;
  relAY, relBY: Integer;
begin
  a0 := SnapRectXYWH(0, 0, 100, 50);
  b0 := SnapRectXYWH(0, 56, 100, 40);

  a := a0; b := b0;
  ApplyAxisSnap(a, b);
  relAY := b.Y - a.Y;

  a := a0; b := b0;
  ApplyAxisSnap(b, a);
  relBY := b.Y - a.Y;

  AssertEquals('MR-4 垂直相对偏移相同', relAY, relBY);
  AssertEquals('吸附后无间隙', a0.H, relAY);
end;

procedure TWindowSnapTest.TestMR4SymmetryIndependentAxes;
var
  a, b, a0, b0: TSnapRect;
  relAX, relAY, relBX, relBY: Integer;
begin
  // 同时接近右邻与顶对齐
  a0 := SnapRectXYWH(0, 0, 100, 50);
  b0 := SnapRectXYWH(108, 7, 100, 50);

  a := a0; b := b0;
  ApplyAxisSnap(a, b);
  relAX := b.X - a.X;
  relAY := b.Y - a.Y;

  a := a0; b := b0;
  ApplyAxisSnap(b, a);
  relBX := b.X - a.X;
  relBY := b.Y - a.Y;

  AssertEquals('MR-4 双轴 X', relAX, relBX);
  AssertEquals('MR-4 双轴 Y', relAY, relBY);
end;

{ 管理器 }

procedure TWindowSnapTest.TestSubSnapsToMain;
var
  mgr: TWindowSnapManager;
  main, eq: ISnapWindow;
begin
  mgr := TWindowSnapManager.Create;
  try
    main := MakeWin('player', 100, 100, 275, 116);
    eq   := MakeWin('eq',     100, 220, 275, 80); // 间隙 4
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(eq);
    mgr.RebuildSnapGraph;
    AssertEquals('eq 应贴在 player 下方', 216, eq.GetBounds.Y);
    AssertTrue('eq 已连接到主窗口', mgr.ConnectedToMain(eq));
    AssertEquals(SNAP_MAIN_ANCHOR, mgr.AnchorOf(eq));
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestMainDragMovesConnected;
var
  mgr: TWindowSnapManager;
  main, eq: ISnapWindow;
begin
  mgr := TWindowSnapManager.Create;
  try
    main := MakeWin('player', 100, 100, 275, 116);
    eq   := MakeWin('eq',     100, 216, 275, 80);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(eq);
    mgr.RebuildSnapGraph;
    AssertTrue(mgr.ConnectedToMain(eq));

    mgr.OnDragStarted(main);
    main.MoveTo(150, 130);
    mgr.OnMainMoved(50, 30);
    AssertEquals('联动 X', 150, eq.GetBounds.X);
    AssertEquals('联动 Y', 246, eq.GetBounds.Y);
    mgr.OnDragFinished(main);
    AssertTrue('松手后仍连接', mgr.ConnectedToMain(eq));
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestMainDragSkipsUnconnected;
var
  mgr: TWindowSnapManager;
  main, lyric: ISnapWindow;
  orig: TSnapRect;
begin
  mgr := TWindowSnapManager.Create;
  try
    main  := MakeWin('player', 100, 100, 275, 116);
    lyric := MakeWin('lyric',  500, 400, 268, 60);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(lyric);
    mgr.RebuildSnapGraph;
    AssertFalse(mgr.ConnectedToMain(lyric));
    orig := lyric.GetBounds;

    mgr.OnDragStarted(main);
    main.MoveTo(140, 120);
    mgr.OnMainMoved(40, 20);
    mgr.OnDragFinished(main);

    AssertEquals(orig.X, lyric.GetBounds.X);
    AssertEquals(orig.Y, lyric.GetBounds.Y);
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestSubDragDoesNotMoveOthers;
var
  mgr: TWindowSnapManager;
  main, eq: ISnapWindow;
  mainOrig: TSnapRect;
begin
  mgr := TWindowSnapManager.Create;
  try
    main := MakeWin('player', 100, 100, 275, 116);
    eq   := MakeWin('eq',     100, 216, 275, 80);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(eq);
    mgr.RebuildSnapGraph;
    mainOrig := main.GetBounds;

    mgr.OnDragStarted(eq);
    eq.MoveTo(300, 400);
    mgr.OnSubMoved(eq, 200, 184);
    mgr.OnDragFinished(eq);

    AssertEquals('子窗口拖动不带动主窗口 X', mainOrig.X, main.GetBounds.X);
    AssertEquals('子窗口拖动不带动主窗口 Y', mainOrig.Y, main.GetBounds.Y);
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestSubDragAwayDetaches;
var
  mgr: TWindowSnapManager;
  main, eq: ISnapWindow;
begin
  mgr := TWindowSnapManager.Create;
  try
    main := MakeWin('player', 100, 100, 275, 116);
    eq   := MakeWin('eq',     100, 216, 275, 80);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(eq);
    mgr.RebuildSnapGraph;
    AssertTrue(mgr.ConnectedToMain(eq));

    mgr.OnDragStarted(eq);
    eq.MoveTo(600, 500);
    mgr.OnDragFinished(eq);
    AssertFalse('拖远后应断开', mgr.ConnectedToMain(eq));
    AssertEquals(600, eq.GetBounds.X);
    AssertEquals(500, eq.GetBounds.Y);
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestSubDragNearSnapsOnFinish;
var
  mgr: TWindowSnapManager;
  main, eq: ISnapWindow;
begin
  mgr := TWindowSnapManager.Create;
  try
    main := MakeWin('player', 100, 100, 275, 116);
    eq   := MakeWin('eq',     400, 400, 275, 80);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(eq);
    mgr.RebuildSnapGraph;
    AssertFalse(mgr.ConnectedToMain(eq));

    mgr.OnDragStarted(eq);
    eq.MoveTo(100, 220); // 间隙 4
    mgr.OnDragFinished(eq);
    AssertEquals('松手吸附 Y', 216, eq.GetBounds.Y);
    AssertTrue(mgr.ConnectedToMain(eq));
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestHiddenWindowIgnored;
var
  mgr: TWindowSnapManager;
  main, eq: ISnapWindow;
begin
  mgr := TWindowSnapManager.Create;
  try
    main := MakeWin('player', 100, 100, 275, 116);
    eq   := MakeWin('eq',     100, 216, 275, 80);
    eq.SetVisible(False);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(eq);
    mgr.RebuildSnapGraph;
    AssertFalse(mgr.ConnectedToMain(eq));
    AssertEquals('隐藏窗口不被拉过去', 216, eq.GetBounds.Y);
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestInPlaceRebuildDoesNotMove;
var
  mgr: TWindowSnapManager;
  main, eq: ISnapWindow;
begin
  mgr := TWindowSnapManager.Create;
  try
    main := MakeWin('player', 100, 100, 275, 116);
    eq   := MakeWin('eq',     104, 400, 275, 80); // 水平近、垂直远
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(eq);
    // RebuildSnapGraph 会移动；这里模拟松手后的 in-place：
    // 先放到远处再 OnDragFinished 走 RebuildSnapGraphInPlace
    mgr.OnDragStarted(eq);
    mgr.OnDragFinished(eq);
    AssertEquals('就地重建不移动 X', 104, eq.GetBounds.X);
    AssertEquals('就地重建不移动 Y', 400, eq.GetBounds.Y);
    AssertFalse(mgr.ConnectedToMain(eq));
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestGroupFollowThenDetach;
var
  mgr: TWindowSnapManager;
  main, eq, lyric: ISnapWindow;
begin
  mgr := TWindowSnapManager.Create;
  try
    main  := MakeWin('player', 100, 100, 275, 116);
    eq    := MakeWin('eq',     100, 216, 275, 80);
    lyric := MakeWin('lyric',  500, 100, 268, 60);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(eq);
    mgr.AddSubWindow(lyric);
    mgr.RebuildSnapGraph;
    AssertTrue(mgr.ConnectedToMain(eq));
    AssertFalse(mgr.ConnectedToMain(lyric));

    mgr.OnDragStarted(main);
    main.MoveTo(120, 100);
    mgr.OnMainMoved(20, 0);
    AssertEquals(120, eq.GetBounds.X);
    AssertEquals(500, lyric.GetBounds.X);
    mgr.OnDragFinished(main);
  finally
    mgr.Free;
  end;
end;

procedure TWindowSnapTest.TestResizeSnapToMain;
var
  mgr: TWindowSnapManager;
  main, lyric: ISnapWindow;
begin
  mgr := TWindowSnapManager.Create;
  try
    main  := MakeWin('player', 100, 100, 275, 116);
    lyric := MakeWin('lyric',  100, 216, 268, 60);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(lyric);
    mgr.RebuildSnapGraph;

    lyric.ResizeTo(280, 60); // 右边缘超出主窗口 5px
    mgr.OnSubResized(lyric, [seRight]);
    AssertEquals('右边缘对齐主窗口', 275, lyric.GetBounds.W);
  finally
    mgr.Free;
  end;
end;

initialization
  RegisterTest(TWindowSnapTest);

end.
