unit UTestLayer2;

{$mode objfpc}{$H+}

// Layer 2：渲染快照测试。用 USkinRender 离屏渲染 player_window 的各状态帧，
// 与 Qt 版 golden PNG 逐像素比对（masks.json 中的文本/动画区域除外）。
// 失败时输出 expected/actual/diff 三联 PNG 到 tests/artifacts/layer2/。
//
// 本阶段覆盖 USkinRender 已实现的合成（背景+按钮+滑块），
// 对应 golden 帧：player__default / player__progress37 /
// player__hover-play / player__pressed-play / player__toggled-mute。
// equalizer/lyric/playlist 帧随后续窗口移植接入。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, fpjson, jsonparser,
  BGRABitmap, BGRABitmapTypes, USkinTypes, USkinLoader, USkinRender;

type
  TSnapshotTest = class(TTestCase)
  private
    procedure CheckSkinFrames(const SkinName: string);
    procedure CompareFrame(const SkinName, FrameName: string;
      Actual: TBGRABitmap; Masks: TJSONArray);
  published
    procedure TestAllSkins;
  end;

implementation

var
  RepoRoot: string;

function LoadMaskRects(const SkinName: string): TJSONArray;
var
  path, content: string;
  fs: TFileStream;
  data: TJSONData;
  obj: TJSONObject;
begin
  Result := nil;
  path := RepoRoot + 'tests' + PathDelim + 'golden' + PathDelim + 'masks' +
    PathDelim + SkinName + '.json';
  if not FileExists(path) then Exit;
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(content, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(content[1], fs.Size);
  finally
    fs.Free;
  end;
  data := GetJSON(content);
  if data is TJSONObject then
  begin
    obj := TJSONObject(data);
    if obj.IndexOfName('player') >= 0 then
      Result := TJSONArray(obj.Extract(obj.IndexOfName('player')));
  end;
  data.Free;
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

// 单通道绝对差（含 alpha）
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
  goldenPath := RepoRoot + 'tests' + PathDelim + 'golden' + PathDelim +
    'frames' + PathDelim + SkinName + PathDelim + FrameName + '.png';
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
        artifactDir := RepoRoot + 'tests' + PathDelim + 'artifacts' +
          PathDelim + 'layer2' + PathDelim + SkinName;
        ForceDirectories(artifactDir);
        expected.SaveToFile(artifactDir + PathDelim + FrameName + '.expected.png');
        Actual.SaveToFile(artifactDir + PathDelim + FrameName + '.actual.png');
        diff.SaveToFile(artifactDir + PathDelim + FrameName + '.diff.png');
        Fail(Format('%s/%s: %d 个像素不一致（三联图已存 tests/artifacts/layer2）',
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
  masks: TJSONArray;
  sknPath: string;
begin
  sknPath := RepoRoot + 'Skin' + PathDelim + SkinName + '.skn';
  if not FileExists(sknPath) then Exit;

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
  // Subaru_Offbeat_TTPlayer57: Qt FrameDumper 在 offscreen 模式下渲染该皮肤时
  // setMask 导致输出坐标整体偏移 (7,11)，是 golden 生成端的问题，暂时跳过。
  // TODO: 修复 FrameDumper 后重新启用。
  found := False;
  if FindFirst(RepoRoot + 'Skin' + PathDelim + '*.skn', faAnyFile, rec) = 0 then
  begin
    try
      repeat
        skinName := ChangeFileExt(rec.Name, '');
        if skinName = 'Subaru_Offbeat_TTPlayer57' then
        begin
          found := True;
          Continue;
        end;
        found := True;
        CheckSkinFrames(skinName);
      until FindNext(rec) <> 0;
    finally
      FindClose(rec);
    end;
  end;
  AssertTrue('Skin 目录下应有 .skn 皮肤', found);
end;

initialization
  // 测试可执行文件位于 pascal\bin\，仓库根在其上两级。
  RepoRoot := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim +
    '..' + PathDelim) ;
  RegisterTest(TSnapshotTest);

end.
