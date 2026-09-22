unit UTestLayer2;

{$mode objfpc}{$H+}

// Layer 2：渲染快照测试。用 USkinRender 离屏渲染 player_window / equalizer_window
// 的各状态帧，与 Qt 版 golden PNG 逐像素比对（masks.json 中的文本/动画区域除外）。
// 失败时输出 expected/actual/diff 三联 PNG 到 build/<platform>/tests/artifacts/layer2/。
//
// 覆盖帧：
//   player__default / player__progress37 / player__hover-play /
//   player__pressed-play / player__toggled-mute
//   equalizer__default / equalizer__sliders
//   lyric__default（皮肤 baseSize；lyric 文本区走 mask）
//
// playlist__default: 皮肤 baseSize 捕帧（与 lyric 相同），resize_tile=False
// 也可比；masks 覆盖 playlist 文本区与 title/close 1px 容差。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser,
  BGRABitmap, BGRABitmapTypes, USkinTypes, USkinLoader, USkinRender;

type
  TSnapshotTest = class(TTestCase)
  private
    FSnapshotFailures: Integer;
    procedure CheckSkinFrames(const SkinName: string);
    procedure CompareFrame(const SkinName, FrameName: string;
      Actual: TBGRABitmap; Masks: TJSONArray);
  published
    procedure TestAllSkins;
    procedure TestInfoTextDiffersFromEmpty;
    procedure TestCoverRenderDiffersFromDefault;
  end;

implementation

var
  RepoRoot, SkinRoot, GoldenRoot: string;

function FindRepoRoot: string;
var
  currentDir, parentDir: string;
begin
  currentDir := ExcludeTrailingPathDelimiter(
    ExpandFileName(ExtractFilePath(ParamStr(0))));
  while currentDir <> '' do
  begin
    if DirectoryExists(currentDir + PathDelim + 'Skin') and
       DirectoryExists(currentDir + PathDelim + 'pascal') then
      Exit(IncludeTrailingPathDelimiter(currentDir));
    parentDir := ExcludeTrailingPathDelimiter(
      ExpandFileName(currentDir + PathDelim + '..'));
    if parentDir = currentDir then Break;
    currentDir := parentDir;
  end;
  raise Exception.Create('Could not locate repository root from ' + ParamStr(0));
end;

function FindGoldenRoot: string;
begin
  Result := GetEnvironmentVariable('TTPLAYER_GOLDEN_DIR');
  if Result <> '' then
    Exit(IncludeTrailingPathDelimiter(ExpandFileName(Result)));
{$IFDEF WINDOWS}
  Result := RepoRoot + 'build' + PathDelim + 'windows' + PathDelim +
    'tests' + PathDelim + 'golden' + PathDelim;
{$ELSE}
  Result := RepoRoot + 'build' + PathDelim + 'linux' + PathDelim +
    'tests' + PathDelim + 'golden' + PathDelim;
{$ENDIF}
end;

function FindSkinRoot: string;
var
  configured: string;
begin
  configured := GetEnvironmentVariable('TTPLAYER_SKIN_DIR');
  if (configured <> '') and DirectoryExists(configured) then
    Exit(IncludeTrailingPathDelimiter(ExpandFileName(configured)));
  Result := RepoRoot + 'Skin' + PathDelim;
end;

function GoldenIdForSkin(const SkinFile: string): string;
var path, content: string; fs: TFileStream; data: TJSONData; i: Integer; item: TJSONObject;
begin
  Result := ChangeFileExt(SkinFile, '');
  path := GoldenRoot + 'skin-index.json';
  if not FileExists(path) then Exit;
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try SetLength(content, fs.Size); if fs.Size > 0 then fs.ReadBuffer(content[1], fs.Size); finally fs.Free; end;
  data := GetJSON(content);
  try
    if data is TJSONArray then
      for i := 0 to TJSONArray(data).Count - 1 do
      begin
        item := TJSONObject(TJSONArray(data).Items[i]);
        if item.Get('file', '') = SkinFile then begin Result := item.Get('id', Result); Exit; end;
      end;
  finally data.Free; end;
end;

// 加载 masks.json 中指定 section（'player'/'equalizer'）的矩形列表。
function LoadMaskSection(const SkinName, Section: string): TJSONArray;
var
  path, content: string;
  fs: TFileStream;
  data: TJSONData;
  obj: TJSONObject;
begin
  Result := nil;
  path := GoldenRoot + 'masks' + PathDelim +
    GoldenIdForSkin(SkinName + '.skn') + '.json';
  if not FileExists(path) then Exit;
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(content, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(content[1], fs.Size);
  finally
    fs.Free;
  end;
  data := GetJSON(content);
  try
    if data is TJSONObject then
    begin
      obj := TJSONObject(data);
      if obj.IndexOfName(Section) >= 0 then
        Result := TJSONArray(obj.Extract(obj.IndexOfName(Section)));
    end;
  finally
    data.Free;
  end;
end;

// LoadMaskRects: 旧接口，加载 'player' section（兼容现有调用）
function LoadMaskRects(const SkinName: string): TJSONArray;
begin
  Result := LoadMaskSection(SkinName, 'player');
end;

procedure AddMaskRect(Masks: TJSONArray; const AType: string;
  X, Y, W, H: Integer);
var
  obj: TJSONObject;
begin
  if (Masks = nil) or (W <= 0) or (H <= 0) then Exit;
  obj := TJSONObject.Create;
  obj.Add('type', AType);
  obj.Add('x', X);
  obj.Add('y', Y);
  obj.Add('w', W);
  obj.Add('h', H);
  Masks.Add(obj);
end;

// FrameDumper 以皮肤 baseSize 捕帧。扩进比较掩码：
//   · playlistRect（Qt 子控件 tabs/list/divider/scrollbar 文本）
//   · aligned titleDrawRect / close（子控件合成 1px 级差异）
// dest≠base 时仍盖住九宫格右/底边（拉伸路径的抗锯齿差异）。
procedure ExpandPlaylistCompareMasks(Masks: TJSONArray; const Skin: TSkinData;
  DestW, DestH: Integer);
var
  wnd: TSkinWindow;
  bgW, bgH, right, bottom: Integer;
  plRect, titleRect, closeRect, closeBounds, tbRect: TSkinRect;
  titleElem, closeElem, tbElem: PSkinElement;
  titleW, titleH: Integer;
begin
  if Masks = nil then Exit;
  wnd := Skin.PlaylistWindow;
  if wnd.BackgroundPixmap <> nil then
  begin
    bgW := wnd.BackgroundPixmap.Width;
    bgH := wnd.BackgroundPixmap.Height;
  end
  else
  begin
    bgW := DestW;
    bgH := DestH;
  end;

  plRect := PlaylistContentRect(Skin, DestW, DestH);
  AddMaskRect(Masks, 'playlist', plRect.X, plRect.Y, plRect.W, plRect.H);

  // 无工具栏精灵图的皮肤走 Qt 矢量文字回退（「添加/删除/…」），Layer 2 排除。
  tbElem := wnd.FindElement('toolbar');
  if tbElem <> nil then
  begin
    tbRect := AlignedRect(tbElem^.Position, bgW, bgH, DestW, DestH,
      tbElem^.Align, tbElem^.Position.W, tbElem^.Position.H);
    AddMaskRect(Masks, 'toolbar', tbRect.X - 1, tbRect.Y - 1,
      tbRect.W + 2, tbRect.H + 2);
  end;

  titleElem := wnd.FindElement('title');
  if titleElem <> nil then
  begin
    if titleElem^.StatePixmaps[0] <> nil then
    begin
      titleW := titleElem^.StatePixmaps[0].Width;
      titleH := titleElem^.StatePixmaps[0].Height;
    end
    else
    begin
      titleW := titleElem^.Position.W;
      titleH := titleElem^.Position.H;
    end;
    titleRect := AlignedRect(titleElem^.Position, bgW, bgH, DestW, DestH,
      titleElem^.Align, titleW, titleH);
    // 标题图可能比 XML 宽 1px，或居中舍入与 Qt 差 1px。
    AddMaskRect(Masks, 'title', titleRect.X - 1, titleRect.Y, titleRect.W + 2,
      titleRect.H);
  end;

  closeElem := wnd.FindElement('close');
  if closeElem <> nil then
  begin
    closeBounds := ButtonBounds(closeElem^);
    closeRect := AlignedRect(closeElem^.Position, bgW, bgH, DestW, DestH,
      closeElem^.Align, closeBounds.W, closeBounds.H);
    AddMaskRect(Masks, 'close', closeRect.X - 1, closeRect.Y - 1,
      closeRect.W + 2, closeRect.H + 2);
  end;

  if ((DestW <> bgW) or (DestH <> bgH)) and (not wnd.ResizeRect.IsEmpty) then
  begin
    right  := bgW - (wnd.ResizeRect.X + wnd.ResizeRect.W);
    bottom := bgH - (wnd.ResizeRect.Y + wnd.ResizeRect.H);
    if right < 0 then right := 0;
    if bottom < 0 then bottom := 0;
    if right > 0 then
      AddMaskRect(Masks, 'nineslice-right', DestW - right - 1, 0, right + 1, DestH);
    if bottom > 0 then
      AddMaskRect(Masks, 'nineslice-bottom', 0, DestH - bottom - 8, DestW,
        bottom + 8);
  end;
end;

function InMask(X, Y: Integer; Masks: TJSONArray): Boolean;
var
  i: Integer;
  r: TJSONObject;
begin
  Result := False;
  if Masks = nil then Exit;
  for i := 0 to Masks.Count - 1 do
  begin
    r := TJSONObject(Masks[i]);
    if (X >= r.Integers['x']) and (X < r.Integers['x'] + r.Integers['w']) and
       (Y >= r.Integers['y']) and (Y < r.Integers['y'] + r.Integers['h']) then
      Exit(True);
  end;
end;
function ChanDiff(A, B: Byte): Integer; inline;
begin
  Result := Abs(Integer(A) - Integer(B));
end;

// 四通道最大差值
function MaxChannelDiff(const A, B: TBGRAPixel): Integer; inline;
var
  d: Integer;
begin
  Result := ChanDiff(A.red, B.red);
  d := ChanDiff(A.green, B.green); if d > Result then Result := d;
  d := ChanDiff(A.blue, B.blue);  if d > Result then Result := d;
  d := ChanDiff(A.alpha, B.alpha); if d > Result then Result := d;
end;

// 全透明像素只比 alpha，否则比所有通道。
// 容差 kTolerance=1 以容纳 8-bit 预乘往返的 ±1 舍入误差（业界惯例）。
// 超过容差的像素计入 diffCount，并在 diff 图中用红色标注。
const
  kTolerance = 1;

procedure TSnapshotTest.CompareFrame(const SkinName, FrameName: string;
  Actual: TBGRABitmap; Masks: TJSONArray);
var
  goldenPath, artifactDir: string;
  expected, diff: TBGRABitmap;
  x, y, diffCount, d: Integer;
  pe, pa: PBGRAPixel;
begin
  goldenPath := GoldenRoot + 'frames' + PathDelim +
    GoldenIdForSkin(SkinName + '.skn') + PathDelim +
    FrameName + '.png';
  if not FileExists(goldenPath) then
  begin
    Fail(Format('%s/%s: 缺少 golden 帧', [SkinName, FrameName]));
    Exit;
  end;

  expected := TBGRABitmap.Create(goldenPath);
  try
    if (expected.Width <> Actual.Width) or (expected.Height <> Actual.Height) then
    begin
      Fail(Format('%s/%s: 尺寸不一致 期望 %dx%d 实际 %dx%d',
        [SkinName, FrameName, expected.Width, expected.Height,
         Actual.Width, Actual.Height]));
      Exit;
    end;

    diff := TBGRABitmap.Create(expected.Width, expected.Height, BGRABlack);
    try
      diffCount := 0;
      for y := 0 to expected.Height - 1 do
      begin
        pe := expected.ScanLine[y];
        pa := Actual.ScanLine[y];
        for x := 0 to expected.Width - 1 do
        begin
          if not InMask(x, y, Masks) then
          begin
            if pe^.alpha = 0 then
              d := ChanDiff(pe^.alpha, pa^.alpha)
            else
              d := MaxChannelDiff(pe^, pa^);
            if d > kTolerance then
            begin
              Inc(diffCount);
              diff.SetPixel(x, y, BGRA(255, 0, 0, 255));
            end;
          end;
          Inc(pe);
          Inc(pa);
        end;
      end;

      if diffCount > 0 then
      begin
{$IFDEF WINDOWS}
        artifactDir := RepoRoot + 'build' + PathDelim + 'windows' + PathDelim;
{$ELSE}
        artifactDir := RepoRoot + 'build' + PathDelim + 'linux' + PathDelim;
{$ENDIF}
        artifactDir := artifactDir + 'tests' + PathDelim + 'artifacts' +
          PathDelim + 'layer2' + PathDelim + SkinName;
        ForceDirectories(artifactDir);
        expected.SaveToFile(artifactDir + PathDelim + FrameName + '.expected.png');
        Actual.SaveToFile(artifactDir + PathDelim + FrameName + '.actual.png');
        diff.SaveToFile(artifactDir + PathDelim + FrameName + '.diff.png');
        Fail(Format('%s/%s: %d 个像素不一致（三联图已存 build/<platform>/tests/artifacts/layer2）',
          [SkinName, FrameName, diffCount]));
      end;
    finally
      diff.Free;
    end;
  finally
    expected.Free;
  end;
end;

procedure TSnapshotTest.CheckSkinFrames(const SkinName: string);
var
  engine: TSkinEngine;
  frame: TBGRABitmap;
  masks, eqMasks, lyricMasks, plMasks: TJSONArray;
  sknPath: string;
  eqGains: array[0..9] of Double;
begin
  sknPath := SkinRoot + SkinName + '.skn';
  if not FileExists(sknPath) then Exit;
  // Qt could not produce a golden for some legacy skins; those are reported
  // by gen-golden/errors and are not render-comparable here.
  if not DirectoryExists(GoldenRoot + 'frames' + PathDelim +
    GoldenIdForSkin(SkinName + '.skn')) then Exit;

  engine := TSkinEngine.Create;
  masks := LoadMaskRects(SkinName);
  try
    if not engine.LoadFromFile(sknPath) then
    begin
      Fail(SkinName + ': 皮肤加载失败');
      Exit;
    end;

    // 默认帧：进度 0、音量 100（AudioEngine 默认音量为 1.0 → 100）
    frame := RenderPlayerWindow(engine.SkinData, 0, 100, '', bvsNormal, False);
    try
      CompareFrame(SkinName, 'player__default', frame, masks);
    finally
      frame.Free;
    end;

    frame := RenderPlayerWindow(engine.SkinData, 0.37, 60, '', bvsNormal, False);
    try
      CompareFrame(SkinName, 'player__progress37', frame, masks);
    finally
      frame.Free;
    end;

    frame := RenderPlayerWindow(engine.SkinData, 0, 100, 'play', bvsHover, False);
    try
      CompareFrame(SkinName, 'player__hover-play', frame, masks);
    finally
      frame.Free;
    end;

    frame := RenderPlayerWindow(engine.SkinData, 0, 100, 'play', bvsPressed, False);
    try
      CompareFrame(SkinName, 'player__pressed-play', frame, masks);
    finally
      frame.Free;
    end;

    frame := RenderPlayerWindow(engine.SkinData, 0, 100, '', bvsNormal, True);
    try
      CompareFrame(SkinName, 'player__toggled-mute', frame, masks);
    finally
      frame.Free;
    end;

    // ── 均衡器帧 ──────────────────────────────────────────────────────
    // equalizer__default: 初始状态（gains=0, preamp=0, balance=0, surround=0）。
    // equalizer__sliders: 各频段错落图案（对应 FrameDumper 的确定性 pattern[]）。
    //   pattern = {-12,-6,0,6,12,6,0,-6,-12,0,6,3}，按 XML slider 顺序应用：
    //   balance(-12), surround(clamp→0), preamp(0), eqfactor[0..9]
    eqMasks := LoadMaskSection(SkinName, 'equalizer');
    try
      // equalizer__default: EQ 初始状态 — Qt 默认均衡器关闭（EqEnabled=False）
      FillChar(eqGains, SizeOf(eqGains), 0);
      frame := RenderEqualizerWindow(engine.SkinData,
        eqGains, 0.0, 0.0, 0.0, False, '', bvsNormal);
      try
        CompareFrame(SkinName, 'equalizer__default', frame, eqMasks);
      finally
        frame.Free;
      end;

      // equalizer__sliders: EQ 仍关闭（FrameDumper 仅移动滑块，不改变开关状态）
      eqGains[0] :=  6.0;  eqGains[1] := 12.0;  eqGains[2] :=  6.0;
      eqGains[3] :=  0.0;  eqGains[4] := -6.0;  eqGains[5] := -12.0;
      eqGains[6] :=  0.0;  eqGains[7] :=  6.0;  eqGains[8] :=  3.0;
      eqGains[9] := -12.0;
      frame := RenderEqualizerWindow(engine.SkinData,
        eqGains, 0.0, -12.0, 0.0, False, '', bvsNormal);
      try
        CompareFrame(SkinName, 'equalizer__sliders', frame, eqMasks);
      finally
        frame.Free;
      end;
    finally
      eqMasks.Free;
    end;

    // ── 歌词窗口帧 ─────────────────────────────────────────────────────
    // FrameDumper 以皮肤 baseSize 捕帧，与 RenderLyricWindow(bgW, bgH) 对拍。
    // dest==base 时九宫格无拉伸，resize_tile=False 皮肤也可比。
    // lyric 文本（「暂无歌词」）由 masks.json 排除；title/close/ontop 逐像素比。
    lyricMasks := LoadMaskSection(SkinName, 'lyric');
    try
      if engine.SkinData.LyricWindow.BackgroundPixmap <> nil then
      begin
        frame := RenderLyricWindow(engine.SkinData,
          engine.SkinData.LyricWindow.BackgroundPixmap.Width,
          engine.SkinData.LyricWindow.BackgroundPixmap.Height);
        try
          CompareFrame(SkinName, 'lyric__default', frame, lyricMasks);
        finally
          frame.Free;
        end;
      end;
    finally
      lyricMasks.Free;
    end;

    // ── 播放列表窗口帧 ──────────────────────────────────────────────────
    // FrameDumper 以皮肤 baseSize 捕帧，与 RenderPlaylistWindow(bgW, bgH) 对拍。
    // dest==base 时九宫格无拉伸，resize_tile=False 皮肤也可比。
    if engine.SkinData.PlaylistWindow.BackgroundPixmap <> nil then
    begin
      plMasks := LoadMaskSection(SkinName, 'playlist');
      if plMasks = nil then
        plMasks := TJSONArray.Create;
      try
        ExpandPlaylistCompareMasks(plMasks, engine.SkinData,
          engine.SkinData.PlaylistWindow.BackgroundPixmap.Width,
          engine.SkinData.PlaylistWindow.BackgroundPixmap.Height);
        frame := RenderPlaylistWindow(engine.SkinData,
          engine.SkinData.PlaylistWindow.BackgroundPixmap.Width,
          engine.SkinData.PlaylistWindow.BackgroundPixmap.Height);
        try
          CompareFrame(SkinName, 'playlist__default', frame, plMasks);
        finally
          frame.Free;
        end;
      finally
        plMasks.Free;
      end;
    end;
  finally
    masks.Free;
    engine.Free;
  end;
end;

procedure TSnapshotTest.TestAllSkins;
var
  rec: TSearchRec;
  found: Boolean;
  skinName: string;
begin
  found := False;
  if FindFirst(SkinRoot + '*.skn', faAnyFile, rec) = 0 then
  begin
    try
      repeat
        skinName := ChangeFileExt(rec.Name, '');
        found := True;
        try
          CheckSkinFrames(skinName);
        except
          on E: Exception do
          begin
            Inc(FSnapshotFailures);
            WriteLn('[layer2] FAIL ', skinName, ': ', E.Message);
          end;
        end;
      until FindNext(rec) <> 0;
    finally
      FindClose(rec);
    end;
  end;
  AssertTrue('Skin 目录下应有 .skn 皮肤', found);
  if FSnapshotFailures > 0 then
    Fail(Format('%d 个皮肤存在渲染差异（详见 layer2 日志和 artifacts）', [FSnapshotFailures]));
end;

function CountPixelDiffs(A, B: TBGRABitmap): Integer;
var
  x, y: Integer;
  pa, pb: PBGRAPixel;
begin
  Result := 0;
  if (A = nil) or (B = nil) then
    Exit;
  if (A.Width <> B.Width) or (A.Height <> B.Height) then
  begin
    Result := A.Width * A.Height;
    Exit;
  end;
  for y := 0 to A.Height - 1 do
  begin
    pa := A.ScanLine[y];
    pb := B.ScanLine[y];
    for x := 0 to A.Width - 1 do
    begin
      if (pa^.red <> pb^.red) or (pa^.green <> pb^.green) or
         (pa^.blue <> pb^.blue) or (pa^.alpha <> pb^.alpha) then
        Inc(Result);
      Inc(pa);
      Inc(pb);
    end;
  end;
end;

function LoadFirstSkinWith(const ElemType: string; out Engine: TSkinEngine): Boolean;
var
  rec: TSearchRec;
  sknPath: string;
  elem: PSkinElement;
begin
  Result := False;
  Engine := nil;
  if FindFirst(SkinRoot + '*.skn', faAnyFile, rec) <> 0 then
    Exit;
  try
    repeat
      sknPath := SkinRoot + rec.Name;
      Engine := TSkinEngine.Create;
      if Engine.LoadFromFile(sknPath) then
      begin
        elem := Engine.SkinData.PlayerWindow.FindElement(ElemType);
        if (elem <> nil) and (not elem^.Position.IsEmpty) then
        begin
          Result := True;
          Exit;
        end;
      end;
      FreeAndNil(Engine);
    until FindNext(rec) <> 0;
  finally
    FindClose(rec);
  end;
end;

procedure TSnapshotTest.TestInfoTextDiffersFromEmpty;
var
  engine: TSkinEngine;
  empty, filled: TBGRABitmap;
  diffs: Integer;
begin
  AssertTrue('need skin with info', LoadFirstSkinWith('info', engine));
  try
    empty := RenderPlayerWindow(engine.SkinData, 0, 100, '', bvsNormal, False);
    filled := RenderPlayerWindow(engine.SkinData, 0, 100, '', bvsNormal, False,
      False, 0, 'ZZZ_INFO_PIXEL_PROBE');
    try
      diffs := CountPixelDiffs(empty, filled);
      AssertTrue(Format('info text must change pixels, diffs=%d', [diffs]),
        diffs > 0);
    finally
      empty.Free;
      filled.Free;
    end;
  finally
    engine.Free;
  end;
end;

procedure TSnapshotTest.TestCoverRenderDiffersFromDefault;
var
  engine: TSkinEngine;
  empty, covered: TBGRABitmap;
  cover: TBGRABitmap;
  diffs: Integer;
begin
  AssertTrue('need skin with visual', LoadFirstSkinWith('visual', engine));
  cover := TBGRABitmap.Create(16, 16, BGRA(255, 0, 0, 255));
  try
    empty := RenderPlayerWindow(engine.SkinData, 0, 100, '', bvsNormal, False);
    covered := RenderPlayerWindow(engine.SkinData, 0, 100, '', bvsNormal, False,
      False, 0, '', cover, True);
    try
      diffs := CountPixelDiffs(empty, covered);
      AssertTrue(Format('cover must change pixels, diffs=%d', [diffs]),
        diffs > 0);
    finally
      empty.Free;
      covered.Free;
    end;
  finally
    cover.Free;
    engine.Free;
  end;
end;

initialization
  RepoRoot := FindRepoRoot;
  SkinRoot := FindSkinRoot;
  GoldenRoot := FindGoldenRoot;
  RegisterTest(TSnapshotTest);

end.
