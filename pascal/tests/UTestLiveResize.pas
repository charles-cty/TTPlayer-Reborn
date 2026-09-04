unit UTestLiveResize;

{$mode objfpc}{$H+}

// live 缩放会话：中间尺寸不每拍重建九宫格/Region；松手 commit 才
// 完整 chrome + TrySnapResizeToAnchor。驱动的是 ULiveResizeSession、
// DrawNinePatch、AlphaRunRects、LiveFillFrame 这些已交付路径。

interface

uses
  Classes, SysUtils, LazUTF8, fpcunit, testregistry,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UAlphaShape, UDpiScale,
  UWindowSnapMath, UWindowSnapManager,
  ULiveResizeSession, USkinErase;

type
  TLiveResizeTest = class(TTestCase)
  published
    procedure TestCoalesceNotPerSample;
    procedure TestCommitNinePatchAndShape;
    procedure TestResizeSnapAtCommitNotLive;
    procedure TestLiveFillKeepsFilledSurface;
    procedure TestLivePathCheaperThanFullRebuild;
    procedure TestLiveZoomDoesNotEraseToBlack;
    procedure TestLiveZoomKeepsRoundedCorners;
    procedure TestMapLiveShapeCoversGrownEdge;
    procedure TestGrowSkipsChromeCoalesce;
    procedure TestShrinkCoalescesChrome;
    procedure TestSkinFrameNeedsRebuildOnSizeChange;
    procedure TestEnsureSkinFrameReusesInstance;
    procedure TestNinePatchResizeIsNotMagnify;
    procedure TestLivePaintShouldRebuildChrome;
    procedure TestSampleDoesNotRebuildNinePatch;
    procedure TestMergeAfterMapLiveShape;
    procedure TestNinePatchUsesLogicSizeNotDestScale;
    procedure TestLiveResizeKeepsProductPaths;
    procedure TestElideUtf8RightFitsAndCuts;
    procedure TestElideUtf8RightIsLogMeasures;
  end;

implementation

function MakePatchBase(W, H: Integer): TBGRABitmap;
var
  y: Integer;
  p: PBGRAPixel;
  x: Integer;
begin
  Result := TBGRABitmap.Create(W, H, BGRAPixelTransparent);
  for y := 0 to H - 1 do
  begin
    p := Result.ScanLine[y];
    for x := 0 to W - 1 do
    begin
      p^ := BGRA(Byte(40 + x mod 80), Byte(80 + y mod 80), 160, 255);
      Inc(p);
    end;
  end;
  Result.InvalidateBitmap;
end;

function PatchRect(AX, AY, AW, AH: Integer): TSkinRect;
begin
  Result.X := AX;
  Result.Y := AY;
  Result.W := AW;
  Result.H := AH;
end;

function OpaqueCount(Bmp: TBGRABitmap): Integer;
var
  y, x: Integer;
  p: PBGRAPixel;
begin
  Result := 0;
  if Bmp = nil then Exit;
  for y := 0 to Bmp.Height - 1 do
  begin
    p := Bmp.ScanLine[y];
    for x := 0 to Bmp.Width - 1 do
    begin
      if p^.alpha > 0 then
        Inc(Result);
      Inc(p);
    end;
  end;
end;

function MakeWin(const AName: string; X, Y, W, H: Integer): ISnapWindow;
begin
  Result := TMemorySnapWindow.Create(AName, X, Y, W, H);
end;

procedure TLiveResizeTest.TestCoalesceNotPerSample;
var
  session: TLiveResizeSession;
  i: Integer;
  nowUs: Int64;
  d: TLiveResizeDecision;
begin
  session := TLiveResizeSession.Create;
  try
    session.CoalesceIntervalUs := 16000;
    session.BeginGesture(268, 200);
    for i := 1 to 30 do
    begin
      nowUs := Int64(i) * 2000;
      d := session.Sample(268 + i * 4, 200 + i * 2, nowUs);
      AssertTrue('每拍都更新逻辑尺寸', d.LogicW = 268 + i * 4);
      AssertFalse('不用矩形 Region（会露出黑角）', d.ApplyRectRegion);
      AssertFalse('live 不跑缩放吸附', d.ApplyResizeSnap);
      AssertEquals('放大全程 live fill', Ord(lrkLiveFill), Ord(d.Kind));
      AssertTrue(d.ApplyScaledShape);
      AssertFalse(d.ApplyAlphaShape);
    end;
    d := session.Commit(nowUs + 1000);
    AssertEquals(Ord(lrkCommit), Ord(d.Kind));
    AssertTrue(d.RebuildNinePatch);
    AssertTrue(d.ApplyAlphaShape);
    AssertTrue(d.ApplyResizeSnap);
    AssertEquals('指针采样次数', 30, session.SampleCount);
    AssertEquals('放大只在松手重建 chrome', 1, session.ChromeRebuildCount);
    AssertTrue('有 live fill', session.LiveFillCount > 0);
    AssertEquals(1, session.CommitCount);
  finally
    session.Free;
  end;
end;

procedure TLiveResizeTest.TestCommitNinePatchAndShape;
var
  session: TLiveResizeSession;
  base, dest: TBGRABitmap;
  rr: TSkinRect;
  i: Integer;
  d: TLiveResizeDecision;
  shapes: TShapeRectArray;
begin
  session := TLiveResizeSession.Create;
  base := MakePatchBase(80, 60);
  dest := nil;
  try
    rr := PatchRect(10, 10, 60, 40);
    session.CoalesceIntervalUs := 16000;
    session.BeginGesture(80, 60);
    for i := 1 to 12 do
    begin
      d := session.Sample(80 + i * 8, 60 + i * 4, Int64(i) * 2000);
      if d.RebuildNinePatch then
      begin
        FreeAndNil(dest);
        dest := TBGRABitmap.Create(d.LogicW, d.LogicH, BGRAPixelTransparent);
        DrawNinePatch(dest, base, rr, True, d.LogicW, d.LogicH, True);
      end
      else if d.Kind = lrkLiveFill then
        LiveFillFrame(dest, d.LogicW, d.LogicH);
    end;
    d := session.Commit(30000);
    FreeAndNil(dest);
    dest := TBGRABitmap.Create(d.LogicW, d.LogicH, BGRAPixelTransparent);
    DrawNinePatch(dest, base, rr, True, d.LogicW, d.LogicH, True);
    AssertEquals('commit 宽', d.LogicW, dest.Width);
    AssertEquals('commit 高', d.LogicH, dest.Height);
    AssertTrue('九宫格铺满', OpaqueCount(dest) > 0);
    shapes := AlphaRunRects(dest);
    AssertTrue('commit 可生成窗口形状', Length(shapes) > 0);
  finally
    dest.Free;
    base.Free;
    session.Free;
  end;
end;

procedure TLiveResizeTest.TestResizeSnapAtCommitNotLive;
var
  session: TLiveResizeSession;
  mgr: TWindowSnapManager;
  main, lyric: ISnapWindow;
  i, w: Integer;
  d: TLiveResizeDecision;
  moving, snapped: TSnapRect;
  dist: Integer;
begin
  session := TLiveResizeSession.Create;
  mgr := TWindowSnapManager.Create;
  try
    main := MakeWin('player', 100, 100, 275, 116);
    lyric := MakeWin('lyric', 100, 216, 268, 60);
    mgr.SetMainWindow(main);
    mgr.AddSubWindow(lyric);
    mgr.RebuildSnapGraph;

    session.CoalesceIntervalUs := 16000;
    session.BeginGesture(268, 60);
    for i := 1 to 12 do
    begin
      w := 268 + i;
      d := session.Sample(w, 60, Int64(i) * 2000);
      lyric.ResizeTo(d.LogicW, d.LogicH);
      AssertEquals('live 跟手，不吸附', w, lyric.GetBounds.W);
    end;
    AssertEquals(280, lyric.GetBounds.W);

    d := session.Commit(30000);
    AssertTrue(d.ApplyResizeSnap);
    lyric.ResizeTo(d.LogicW, d.LogicH);
    moving := lyric.GetBounds;
    AssertTrue('松手几何与 TrySnapResizeToAnchor 一致',
      TrySnapResizeToAnchor(moving, [seRight], main.GetBounds, 10, snapped, dist));
    mgr.OnSubResizeFinished(lyric, [seRight]);
    AssertEquals('commit 吸附到主窗口右缘', snapped.W, lyric.GetBounds.W);
    AssertEquals(275, lyric.GetBounds.W);
  finally
    mgr.Free;
    session.Free;
  end;
end;

procedure TLiveResizeTest.TestLiveFillKeepsFilledSurface;
var
  src, frame: TBGRABitmap;
  before, after: Integer;
begin
  src := MakePatchBase(100, 80);
  frame := nil;
  try
    frame := TBGRABitmap.Create(100, 80);
    frame.PutImage(0, 0, src, dmSet);
    before := OpaqueCount(frame);
    AssertEquals(100 * 80, before);
    LiveFillFrame(frame, 140, 90);
    AssertEquals(140, frame.Width);
    AssertEquals(90, frame.Height);
    after := OpaqueCount(frame);
    AssertEquals('拉伸后仍铺满', 140 * 90, after);
  finally
    frame.Free;
    src.Free;
  end;
end;

procedure TLiveResizeTest.TestLivePathCheaperThanFullRebuild;
var
  session: TLiveResizeSession;
  base, dest, naiveDest: TBGRABitmap;
  rr: TSkinRect;
  i, naiveCount, chromeCount: Integer;
  nowUs: Int64;
  d: TLiveResizeDecision;
  shapes: TShapeRectArray;
begin
  session := TLiveResizeSession.Create;
  base := MakePatchBase(240, 180);
  dest := nil;
  naiveDest := nil;
  naiveCount := 0;
  chromeCount := 0;
  try
    rr := PatchRect(24, 24, 192, 132);
    session.CoalesceIntervalUs := 16000;
    session.BeginGesture(480, 360);

    for i := 1 to 24 do
    begin
      nowUs := Int64(i) * 2000;
      naiveDest := TBGRABitmap.Create(480 + i * 16, 360 + i * 10, BGRAPixelTransparent);
      DrawNinePatch(naiveDest, base, rr, True, naiveDest.Width, naiveDest.Height, True);
      shapes := AlphaRunRects(naiveDest);
      Inc(naiveCount);
      AssertTrue('naive 九宫格应能生成形状', Length(shapes) > 0);
      FreeAndNil(naiveDest);

      d := session.Sample(480 + i * 16, 360 + i * 10, nowUs);
      if d.RebuildNinePatch then
      begin
        FreeAndNil(dest);
        dest := TBGRABitmap.Create(d.LogicW, d.LogicH, BGRAPixelTransparent);
        DrawNinePatch(dest, base, rr, True, d.LogicW, d.LogicH, True);
        shapes := AlphaRunRects(dest);
        Inc(chromeCount);
      end
      else
        LiveFillFrame(dest, d.LogicW, d.LogicH);
    end;

    d := session.Commit(50000);
    FreeAndNil(dest);
    dest := TBGRABitmap.Create(d.LogicW, d.LogicH, BGRAPixelTransparent);
    DrawNinePatch(dest, base, rr, True, d.LogicW, d.LogicH, True);
    shapes := AlphaRunRects(dest);
    Inc(chromeCount);
    AssertTrue(Length(shapes) > 0);
    AssertTrue('live chrome 次数 < 每拍 naive', chromeCount < naiveCount);
    AssertTrue(session.ChromeRebuildCount < session.SampleCount);
  finally
    dest.Free;
    naiveDest.Free;
    base.Free;
    session.Free;
  end;
end;

procedure TLiveResizeTest.TestLiveZoomDoesNotEraseToBlack;
var
  msgResult: PtrInt;
  root, path: string;
  sl: TStringList;
  playlistSrc, lyricSrc: string;
begin
  msgResult := 0;
  SwallowSkinEraseBkgnd(msgResult);
  AssertEquals('WM_ERASEBKGND Result=1，不交给 DefWindowProc 铺 clBlack',
    SkinEraseBkgndHandled, msgResult);
  AssertEquals(1, SkinEraseBkgndHandled);

  root := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim +
    '..' + PathDelim);
  sl := TStringList.Create;
  try
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'UPlaylistForm.pas';
    AssertTrue('播放列表源存在', FileExists(path));
    sl.LoadFromFile(path);
    playlistSrc := sl.Text;
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'ULyricForm.pas';
    AssertTrue('歌词窗源存在', FileExists(path));
    sl.LoadFromFile(path);
    lyricSrc := sl.Text;
  finally
    sl.Free;
  end;

  AssertTrue('播放列表注册 LM_ERASEBKGND',
    Pos('message LM_ERASEBKGND', playlistSrc) > 0);
  AssertTrue('播放列表走 SwallowSkinEraseBkgnd',
    Pos('SwallowSkinEraseBkgnd(Message.Result)', playlistSrc) > 0);

  AssertTrue('歌词窗注册 LM_ERASEBKGND',
    Pos('message LM_ERASEBKGND', lyricSrc) > 0);
  AssertTrue('歌词窗走 SwallowSkinEraseBkgnd',
    Pos('SwallowSkinEraseBkgnd(Message.Result)', lyricSrc) > 0);
end;

function ShapeCoversPixel(const Rects: TShapeRectArray; X, Y: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(Rects) do
    if (X >= Rects[i].X) and (X < Rects[i].X + Rects[i].W) and
       (Y >= Rects[i].Y) and (Y < Rects[i].Y + Rects[i].H) then
      Exit(True);
end;

procedure TLiveResizeTest.TestLiveZoomKeepsRoundedCorners;
var
  session: TLiveResizeSession;
  base, dest: TBGRABitmap;
  rr: TSkinRect;
  d: TLiveResizeDecision;
  shapes, scaled: TShapeRectArray;
  x, y: Integer;
begin
  session := TLiveResizeSession.Create;
  base := TBGRABitmap.Create(40, 30, BGRAPixelTransparent);
  dest := nil;
  try
    for y := 6 to 23 do
      for x := 6 to 33 do
        base.DrawPixel(x, y, BGRA(20, 80, 160, 255));
    rr := PatchRect(6, 6, 28, 18);
    dest := TBGRABitmap.Create(80, 60, BGRAPixelTransparent);
    DrawNinePatch(dest, base, rr, True, 80, 60, True);
    shapes := AlphaRunRects(dest);
    AssertFalse('九宫格角是透明的', ShapeCoversPixel(shapes, 0, 0));
    AssertFalse(ShapeCoversPixel(shapes, 79, 0));
    AssertFalse(ShapeCoversPixel(shapes, 0, 59));
    AssertFalse(ShapeCoversPixel(shapes, 79, 59));
    AssertTrue('中间不透明', ShapeCoversPixel(shapes, 40, 30));

    scaled := ScaleShapeRects(shapes, 2.0, 2.0);
    AssertFalse('缩放 Region 仍挖掉圆角', ShapeCoversPixel(scaled, 0, 0));
    AssertFalse(ShapeCoversPixel(scaled, 159, 0));
    AssertTrue(ShapeCoversPixel(scaled, 80, 60));

    session.CoalesceIntervalUs := 16000;
    session.BeginGesture(80, 60);
    d := session.Sample(96, 72, 2000);
    AssertEquals(Ord(lrkLiveFill), Ord(d.Kind));
    AssertTrue(d.ApplyScaledShape);
    AssertFalse(d.ApplyRectRegion);
    AssertFalse(d.ApplyAlphaShape);
    d := session.Sample(112, 84, 4000);
    AssertEquals(Ord(lrkLiveFill), Ord(d.Kind));
    AssertTrue(d.ApplyScaledShape);
    AssertFalse(d.ApplyRectRegion);
    AssertFalse(d.ApplyAlphaShape);
    d := session.Commit(20000);
    AssertTrue(d.ApplyAlphaShape);
    AssertFalse(d.ApplyRectRegion);
  finally
    dest.Free;
    base.Free;
    session.Free;
  end;
end;

procedure TLiveResizeTest.TestMapLiveShapeCoversGrownEdge;
var
  src, mapped: TShapeRectArray;
begin
  SetLength(src, 2);
  src[0].X := 0;
  src[0].Y := 10;
  src[0].W := 100;
  src[0].H := 1;
  src[1].X := 8;
  src[1].Y := 0;
  src[1].W := 84;
  src[1].H := 1;
  mapped := MapLiveShapeRects(src, 100, 50, 160, 50);
  AssertTrue('贴右边的 run 覆盖新右缘', ShapeCoversPixel(mapped, 159, 10));
  AssertEquals(160, mapped[0].W);
  AssertFalse('圆角行不铺满，避免黑角', ShapeCoversPixel(mapped, 0, 0));
  AssertFalse(ShapeCoversPixel(mapped, 159, 0));
end;

procedure TLiveResizeTest.TestGrowSkipsChromeCoalesce;
var
  session: TLiveResizeSession;
  d: TLiveResizeDecision;
  i: Integer;
begin
  session := TLiveResizeSession.Create;
  try
    session.CoalesceIntervalUs := 16000;
    session.BeginGesture(200, 100);
    for i := 1 to 20 do
    begin
      d := session.Sample(200 + i * 8, 100 + i * 4, Int64(i) * 2000);
      AssertEquals(Ord(lrkLiveFill), Ord(d.Kind));
      AssertFalse(d.RebuildNinePatch);
    end;
    AssertEquals(0, session.ChromeRebuildCount);
    d := session.Commit(50000);
    AssertTrue(d.RebuildNinePatch);
    AssertEquals(1, session.ChromeRebuildCount);
  finally
    session.Free;
  end;
end;

procedure TLiveResizeTest.TestShrinkCoalescesChrome;
var
  session: TLiveResizeSession;
  d: TLiveResizeDecision;
  i: Integer;
begin
  session := TLiveResizeSession.Create;
  try
    session.CoalesceIntervalUs := 16000;
    session.BeginGesture(400, 300);
    for i := 1 to 20 do
    begin
      d := session.Sample(400 - i * 8, 300 - i * 4, Int64(i) * 2000);
      AssertEquals(Ord(lrkLiveFill), Ord(d.Kind));
      AssertFalse(d.RebuildNinePatch);
    end;
    d := session.Tick(40000);
    AssertEquals(Ord(lrkChromeCoalesce), Ord(d.Kind));
    AssertTrue(d.RebuildNinePatch);
  finally
    session.Free;
  end;
end;

procedure TLiveResizeTest.TestSkinFrameNeedsRebuildOnSizeChange;
var
  frame: TBGRABitmap;
  playlistSrc, lyricSrc: string;
  root, path: string;
  sl: TStringList;
begin
  AssertTrue(SkinFrameNeedsRebuild(nil, 100, 80));
  frame := TBGRABitmap.Create(100, 80, BGRAPixelTransparent);
  try
    AssertFalse(SkinFrameNeedsRebuild(frame, 100, 80));
    AssertTrue('客户区变了必须九宫格重绘，不能拉伸旧帧',
      SkinFrameNeedsRebuild(frame, 140, 90));
    AssertTrue(SkinFrameNeedsRebuild(frame, 80, 80));
  finally
    frame.Free;
  end;

  root := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim +
    '..' + PathDelim);
  sl := TStringList.Create;
  try
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'UPlaylistForm.pas';
    AssertTrue(FileExists(path));
    sl.LoadFromFile(path);
    playlistSrc := sl.Text;
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'ULyricForm.pas';
    sl.LoadFromFile(path);
    lyricSrc := sl.Text;
  finally
    sl.Free;
  end;
  AssertTrue('播放列表 Paint 按客户区重绘',
    Pos('SkinFrameNeedsRebuild(FFrame, ClientWidth, ClientHeight)', playlistSrc) > 0);
  AssertTrue('歌词 Paint 按客户区重绘',
    Pos('SkinFrameNeedsRebuild(FFrame, ClientWidth, ClientHeight)', lyricSrc) > 0);
end;

procedure TLiveResizeTest.TestEnsureSkinFrameReusesInstance;
var
  frame: TBGRABitmap;
  inst: Pointer;
begin
  frame := nil;
  EnsureSkinFrame(frame, 40, 30);
  try
    AssertEquals(40, frame.Width);
    AssertEquals(30, frame.Height);
    inst := Pointer(frame);
    EnsureSkinFrame(frame, 80, 50);
    AssertTrue('改尺寸仍是同一对象', inst = Pointer(frame));
    AssertEquals(80, frame.Width);
    AssertEquals(50, frame.Height);
    EnsureSkinFrame(frame, 80, 50);
    AssertTrue(inst = Pointer(frame));
    frame.DrawPixel(0, 0, BGRA(255, 0, 0, 255));
    EnsureSkinFrame(frame, 80, 50);
    AssertEquals('复用前清空', 0, frame.GetPixel(0, 0).alpha);
  finally
    frame.Free;
  end;
end;

procedure TLiveResizeTest.TestNinePatchResizeIsNotMagnify;
var
  base, small, large, zoomed: TBGRABitmap;
  rr: TSkinRect;
  x, y: Integer;
begin
  base := TBGRABitmap.Create(40, 30, BGRA(80, 80, 80, 255));
  small := nil;
  large := nil;
  zoomed := nil;
  try
    for y := 0 to 5 do
      for x := 0 to 5 do
        base.DrawPixel(x, y, BGRA(255, 0, 0, 255));
    rr := PatchRect(6, 6, 28, 18);
    small := TBGRABitmap.Create(40, 30, BGRAPixelTransparent);
    large := TBGRABitmap.Create(80, 60, BGRAPixelTransparent);
    DrawNinePatch(small, base, rr, True, 40, 30, True);
    DrawNinePatch(large, base, rr, True, 80, 60, True);
    zoomed := NearestResample(small, 80, 60);
    AssertEquals('九宫格角不拉伸', 255, large.GetPixel(3, 3).red);
    AssertEquals(0, large.GetPixel(3, 3).green);
    AssertTrue('放大镜会把 6px 角拉成 12px', zoomed.GetPixel(10, 3).red > 200);
    AssertTrue('真 resize 的顶边中段不是角的红色',
      large.GetPixel(10, 3).red < 200);
  finally
    zoomed.Free;
    large.Free;
    small.Free;
    base.Free;
  end;
end;

procedure TLiveResizeTest.TestLivePaintShouldRebuildChrome;
begin
  AssertFalse(LivePaintShouldRebuildChrome(True, True, 0, 1000, 16000));
  AssertTrue('首帧必须九宫格',
    LivePaintShouldRebuildChrome(True, False, 0, 1000, 16000));
  AssertFalse('未到合并间隔不重绘，避免堵住鼠标',
    LivePaintShouldRebuildChrome(True, False, 1000, 5000, 16000));
  AssertTrue(LivePaintShouldRebuildChrome(True, False, 1000, 18000, 16000));
  AssertTrue('非缩放尺寸变化立刻重绘',
    LivePaintShouldRebuildChrome(False, False, 1000, 1001, 16000));
end;

procedure TLiveResizeTest.TestSampleDoesNotRebuildNinePatch;
var
  session: TLiveResizeSession;
  d: TLiveResizeDecision;
begin
  session := TLiveResizeSession.Create;
  try
    session.BeginGesture(200, 100);
    d := session.Sample(260, 140, 2000);
    AssertFalse(d.RebuildNinePatch);
    d := session.Sample(180, 90, 4000);
    AssertFalse(d.RebuildNinePatch);
  finally
    session.Free;
  end;
end;

procedure TLiveResizeTest.TestMergeAfterMapLiveShape;
var
  src, mapped, merged: TShapeRectArray;
begin
  SetLength(src, 3);
  src[0].X := 2; src[0].Y := 0; src[0].W := 6; src[0].H := 1;
  src[1].X := 2; src[1].Y := 1; src[1].W := 6; src[1].H := 1;
  src[2].X := 2; src[2].Y := 2; src[2].W := 6; src[2].H := 1;
  mapped := MapLiveShapeRects(src, 10, 3, 20, 6);
  merged := MergeShapeRects(mapped);
  AssertTrue('映射后仍可竖向合并', Length(merged) < Length(mapped));
  AssertEquals(1, Length(merged));
  AssertEquals(4, merged[0].X);
  AssertEquals(0, merged[0].Y);
  AssertEquals(12, merged[0].W);
  AssertEquals(6, merged[0].H);
end;

procedure TLiveResizeTest.TestNinePatchUsesLogicSizeNotDestScale;
var
  base, dest: TBGRABitmap;
  rr: TSkinRect;
  x, y: Integer;
  root, path, playlistSrc, lyricSrc: string;
  sl: TStringList;
begin
  base := TBGRABitmap.Create(40, 30, BGRA(80, 80, 80, 255));
  dest := nil;
  try
    for y := 0 to 5 do
      for x := 0 to 5 do
        base.DrawPixel(x, y, BGRA(255, 0, 0, 255));
    rr := PatchRect(6, 6, 28, 18);
    dest := TBGRABitmap.Create(80, 60, BGRAPixelTransparent);
    DrawNinePatch(dest, base, rr, True, 80, 60, True);
    AssertEquals('四角原样贴，不随 Dest 放大', 255, dest.GetPixel(3, 3).red);
    AssertTrue('角外中段不是角红', dest.GetPixel(10, 3).red < 200);
  finally
    dest.Free;
    base.Free;
  end;

  root := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim +
    '..' + PathDelim);
  sl := TStringList.Create;
  try
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'UPlaylistForm.pas';
    AssertTrue(FileExists(path));
    sl.LoadFromFile(path);
    playlistSrc := sl.Text;
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'ULyricForm.pas';
    sl.LoadFromFile(path);
    lyricSrc := sl.Text;
  finally
    sl.Free;
  end;
  AssertTrue('播放列表九宫格用逻辑尺寸',
    Pos('FLogicW, FLogicH, True)', playlistSrc) > 0);
  AssertTrue('歌词九宫格用逻辑尺寸',
    Pos('FLogicW, FLogicH, True)', lyricSrc) > 0);
  AssertTrue('播放列表 HiDPI 用 BlitNearest',
    Pos('BlitNearest(FFrame, FNineScratch)', playlistSrc) > 0);
  AssertTrue('歌词 HiDPI 用 BlitNearest',
    Pos('BlitNearest(FFrame, FNineScratch)', lyricSrc) > 0);
  AssertTrue('播放列表仍画列表内容',
    Pos('DrawListRows;', playlistSrc) > 0);
  AssertTrue('歌词仍画歌词',
    Pos('DrawLyrics;', lyricSrc) > 0);
end;

procedure TLiveResizeTest.TestLiveResizeKeepsProductPaths;
var
  root, path, playlistSrc, lyricSrc, viewSrc: string;
  sl: TStringList;
begin
  root := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim +
    '..' + PathDelim);
  sl := TStringList.Create;
  try
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'UPlaylistForm.pas';
    AssertTrue(FileExists(path));
    sl.LoadFromFile(path);
    playlistSrc := sl.Text;
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'ULyricForm.pas';
    sl.LoadFromFile(path);
    lyricSrc := sl.Text;
    path := root + 'pascal' + PathDelim + 'src' + PathDelim + 'ui' +
      PathDelim + 'platform' + PathDelim + 'USkinView.pas';
    sl.LoadFromFile(path);
    viewSrc := sl.Text;
  finally
    sl.Free;
  end;
  AssertTrue('列表省略走二分 ElideUtf8Right',
    Pos('ElideUtf8Right', playlistSrc) > 0);
  AssertTrue('列表行用量宽缓存',
    Pos('TextWidthOf(duration)', playlistSrc) > 0);
  AssertTrue('Windows TrueType 统一 GDI ClearType',
    Pos('fqSystemClearType', viewSrc) > 0);
  AssertTrue('不再用精细 ClearType',
    Pos('fqFineClearTypeRGB', viewSrc) = 0);
  AssertTrue('播放列表复用 FFrame',
    Pos('EnsureSkinFrame(FFrame, fw, fh)', playlistSrc) > 0);
  AssertTrue('歌词复用 FFrame',
    Pos('EnsureSkinFrame(FFrame, fw, fh)', lyricSrc) > 0);
end;

type
  TElideMeasureState = record
    Count: Integer;
    UnitW: Integer;
  end;
  PElideMeasureState = ^TElideMeasureState;

function ElideUnitMeasure(const S: string; Data: Pointer): Integer;
begin
  Inc(PElideMeasureState(Data)^.Count);
  Result := UTF8Length(S) * PElideMeasureState(Data)^.UnitW;
end;

procedure TLiveResizeTest.TestElideUtf8RightFitsAndCuts;
var
  st: TElideMeasureState;
  s, outS: string;
  w: Integer;
begin
  st.Count := 0;
  st.UnitW := 10;
  s := 'ABCDEFGHIJ';
  outS := ElideUtf8Right(s, 100, @ElideUnitMeasure, @st);
  AssertEquals('装得下不省略', s, outS);
  outS := ElideUtf8Right(s, 50, @ElideUnitMeasure, @st);
  AssertEquals('MaxW=50 → 2字+省略', 'AB...', outS);
  outS := ElideUtf8Right(s, 30, @ElideUnitMeasure, @st);
  AssertEquals('刚好三个点', '...', outS);
  outS := ElideUtf8Right(s, 0, @ElideUnitMeasure, @st);
  AssertEquals('MaxW<=0 保持原文', s, outS);
  outS := ElideUtf8Right('周杰伦晴天下', 50, @ElideUnitMeasure, @st);
  AssertEquals('UTF-8 按字符切', '周杰...', outS);
  for w := 30 to 120 do
  begin
    outS := ElideUtf8Right(s, w, @ElideUnitMeasure, @st);
    if Pos('...', outS) > 0 then
      AssertTrue('省略号在末尾', Copy(outS, Length(outS) - 2, 3) = '...')
    else
      AssertEquals(s, outS);
  end;
end;

procedure TLiveResizeTest.TestElideUtf8RightIsLogMeasures;
var
  st: TElideMeasureState;
  s: string;
  i: Integer;
begin
  st.Count := 0;
  st.UnitW := 10;
  s := '';
  for i := 1 to 80 do
    s := s + 'A';
  ElideUtf8Right(s, 80, @ElideUnitMeasure, @st);
  AssertTrue(Format('80 字省略应是 log 次量宽，实际 %d', [st.Count]),
    st.Count < 24);
end;

initialization
  RegisterTest(TLiveResizeTest);

end.
