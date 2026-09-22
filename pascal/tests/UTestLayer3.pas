unit UTestLayer3;

{$mode objfpc}{$H+}

// Layer 3：解析逻辑的表驱动单元测试（LOGFONT、position、color、bool 等）。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, BGRABitmap, BGRABitmapTypes,
  FileUtil,
  USkinTypes, USkinXmlParser, USkinLoader, USkinRender;

type
  TParserLogicTest = class(TTestCase)
  published
    procedure TestParsePosition;
    procedure TestParseColor;
    procedure TestParseLogFont;
    procedure TestParseBool;
    procedure TestQuantizedEndpointColorKey;
    procedure TestEmptyLogFontFaceIsSansSerif;
    procedure TestNestedMiniWindowKeepsBackground;
    procedure TestRgb555SpriteSplit;
    procedure TestPngNamedAsBmpFill;
    procedure TestPlaylistBlendUsesQtRound;
    procedure TestEqualizerDefaultSizeWithoutBackground;
    procedure TestPackedChromeShiftsToOrigin;
  end;

implementation

procedure TParserLogicTest.TestParsePosition;
var
  r: TSkinRect;
begin
  r := ParsePositionStr('10, 20, 110, 70');
  AssertEquals('x', 10, r.X);
  AssertEquals('y', 20, r.Y);
  AssertEquals('w', 100, r.W);
  AssertEquals('h', 50, r.H);

  // 空白容错
  r := ParsePositionStr(' 1,2,3,4 ');
  AssertEquals(1, r.X);
  AssertEquals(2, r.W);  // 3-1

  // 字段不足 → 零矩形
  r := ParsePositionStr('1,2,3');
  AssertTrue(r.IsEmpty);

  // 非数字 → QString::toInt 语义返回 0
  r := ParsePositionStr('a,b,c,d');
  AssertEquals(0, r.X);
  AssertEquals(0, r.W);
end;

procedure TParserLogicTest.TestParseColor;
var
  c: TSkinColor;
begin
  c := ParseColorStr('#ff8000');
  AssertTrue(c.Valid);
  AssertEquals($FF, c.R);
  AssertEquals($80, c.G);
  AssertEquals($00, c.B);

  // 大写
  c := ParseColorStr('#FFFFFF');
  AssertTrue(c.Valid);
  AssertEquals($FF, c.R);

  // #rgb 缩写
  c := ParseColorStr('#f80');
  AssertTrue(c.Valid);
  AssertEquals($FF, c.R);
  AssertEquals($88, c.G);

  // 无效输入
  AssertFalse(ParseColorStr('').Valid);
  AssertFalse(ParseColorStr('ff8000').Valid);
  AssertFalse(ParseColorStr('#zzzzzz').Valid);
end;

procedure TParserLogicTest.TestParseLogFont;
var
  f: TSkinFont;
begin
  // 皮肤中的典型 LOGFONT 串（Default.xml Visual 属性）
  f := ParseLogFont('-11,0,0,0,400,0,1,0,1,0,0,4,0,Tahoma');
  AssertEquals('Tahoma', f.Family);
  AssertEquals(11, f.PixelSize);
  AssertFalse(f.Bold);

  // 粗体（weight >= 700）
  f := ParseLogFont('-12,0,0,0,700,0,0,0,0,0,0,0,34,SimSun');
  AssertTrue(f.Bold);
  AssertEquals('SimSun', f.Family);

  // 正高度同样取绝对值
  f := ParseLogFont('16,0,0,0,400,0,0,0,0,0,0,0,0,Arial');
  AssertEquals(16, f.PixelSize);

  // 字段不足 → QFont 默认族名，pixelSize 未设
  f := ParseLogFont('-11,0,0');
  AssertEquals(-1, f.PixelSize);
  AssertEquals('Sans Serif', f.Family);
end;

procedure TParserLogicTest.TestParseBool;
begin
  AssertTrue(ParseBoolAttr('1'));
  AssertTrue(ParseBoolAttr('true'));
  AssertTrue(ParseBoolAttr('YES'));
  AssertTrue(ParseBoolAttr(' True '));
  AssertFalse(ParseBoolAttr('0'));
  AssertFalse(ParseBoolAttr('no'));
  AssertFalse(ParseBoolAttr(''));
end;

procedure TParserLogicTest.TestQuantizedEndpointColorKey;
const
  Xml = '<skin version="2" name="16-bit" transparent_color="#ff00ff">' +
    '<player_window image="bg.bmp"/></skin>';
var
  images: TSkinImageMap;
  skin: TSkinData;
  source, background: TBGRABitmap;
begin
  images := TSkinImageMap.Create;
  InitSkinData(skin);
  try
    // Darkstar's 16-bit BMP #ff00ff pixels are decoded by BGRABitmap as
    // #f800f8.  Qt treats that RGB16 endpoint as the declared #ff00ff key,
    // even when the image contains only a few key pixels.
    source := TBGRABitmap.Create(2, 2, BGRA(248, 0, 248, 255));
    source.SetPixel(1, 1, BGRA(24, 32, 40, 255));
    images.Add('bg.bmp', source, True);
    AssertTrue(ParseSkinXml(Xml, images, TSkinColor.Make(255, 0, 255), skin));
    background := skin.PlayerWindow.BackgroundPixmap;
    AssertTrue(background <> nil);
    AssertEquals('quantized magenta key', 0,
      Integer(background.GetPixel(0, 0).alpha));
    AssertEquals('non-key artwork remains opaque', 255,
      Integer(background.GetPixel(1, 1).alpha));
  finally
    FreeSkinData(skin);
    images.Free;
  end;
end;

procedure TParserLogicTest.TestEmptyLogFontFaceIsSansSerif;
var
  f: TSkinFont;
begin
  // Amethystine Visual.xml: Font="-12,...,2," 空 lfFaceName。
  f := ParseLogFont('-12,0,0,0,400,0,1,0,134,3,2,4,2,');
  AssertEquals('Sans Serif', f.Family);
  AssertEquals(12, f.PixelSize);
  AssertFalse(f.Bold);
end;

procedure TParserLogicTest.TestNestedMiniWindowKeepsBackground;
const
  Xml = '<skin version="2" name="et">' +
    '<mini_window image="mini-player.bmp">' +
    '<play position="0,0,9,9" image="play.bmp"/>' +
    '<mini_window position=""/>' +
    '</mini_window></skin>';
var
  images: TSkinImageMap;
  skin: TSkinData;
  bg, play: TBGRABitmap;
begin
  images := TSkinImageMap.Create;
  InitSkinData(skin);
  try
    bg := TBGRABitmap.Create(4, 2, BGRA(10, 20, 30, 255));
    play := TBGRABitmap.Create(9, 9, BGRA(1, 2, 3, 255));
    images.Add('mini-player.bmp', bg);
    images.Add('play.bmp', play);
    AssertTrue(ParseSkinXml(Xml, images, TSkinColor.Make(255, 0, 255), skin));
    AssertEquals('mini-player.bmp', skin.MiniWindow.BackgroundImageName);
    AssertTrue(skin.MiniWindow.BackgroundPixmap <> nil);
    AssertEquals(4, skin.MiniWindow.BackgroundPixmap.Width);
    AssertEquals(2, skin.MiniWindow.BackgroundPixmap.Height);
  finally
    FreeSkinData(skin);
    images.Free;
  end;
end;

procedure WriteBytes(const Path: string; const Data: array of Byte);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmCreate);
  try
    if Length(Data) > 0 then
      fs.WriteBuffer(Data[0], Length(Data));
  finally
    fs.Free;
  end;
end;

procedure WriteUtf8File(const Path, Text: string);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmCreate);
  try
    if Text <> '' then
      fs.WriteBuffer(Text[1], Length(Text));
  finally
    fs.Free;
  end;
end;

function MakeTempSkinDir: string;
begin
  Result := IncludeTrailingPathDelimiter(
    IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'l3tmp-' + IntToStr(Random(100000000)));
  if not ForceDirectories(Result) then
    raise Exception.Create('cannot create temp skin dir ' + Result);
end;

procedure TParserLogicTest.TestRgb555SpriteSplit;
const
  Xml = '<skin version="2" name="rgb555" transparent_color="#ff00ff">' +
    '<player_window image="close.bmp">' +
    '<close position="0,0,8,1" image="close.bmp"/>' +
    '</player_window></skin>';
  Rgb555Sheet: array[0..117] of Byte = (
    $42, $4D, $76, $00, $00, $00, $00, $00, $00, $00, $36, $00, $00, $00, $28, $00,
    $00, $00, $20, $00, $00, $00, $01, $00, $00, $00, $01, $00, $10, $00, $00, $00,
    $00, $00, $40, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00, $00,
    $00, $00, $00, $00, $00, $00, $FF, $7F, $FF, $7F, $FF, $7F, $FF, $7F, $FF, $7F,
    $FF, $7F, $1F, $7C, $1F, $7C, $FF, $7F, $FF, $7F, $FF, $7F, $FF, $7F, $FF, $7F,
    $FF, $7F, $1F, $7C, $1F, $7C, $FF, $7F, $FF, $7F, $FF, $7F, $FF, $7F, $FF, $7F,
    $FF, $7F, $1F, $7C, $1F, $7C, $FF, $7F, $FF, $7F, $FF, $7F, $FF, $7F, $FF, $7F,
    $FF, $7F, $1F, $7C, $1F, $7C);
var
  dir: string;
  engine: TSkinEngine;
  closeElem: PSkinElement;
begin
  dir := MakeTempSkinDir;
  engine := TSkinEngine.Create;
  try
    WriteBytes(dir + 'close.bmp', Rgb555Sheet);
    WriteUtf8File(dir + 'Skin.xml', Xml);
    if not engine.LoadFromDirectory(dir) then
      Fail('load 16-bit sheet dir=' + dir +
        ' bmpExists=' + BoolToStr(FileExists(dir + 'close.bmp'), True) +
        ' xmlExists=' + BoolToStr(FileExists(dir + 'Skin.xml'), True));
    closeElem := engine.SkinData.PlayerWindow.FindElement('close');
    AssertTrue(closeElem <> nil);
    AssertEquals('opaque-run width', 6, closeElem^.StatePixmaps[0].Width);
    AssertEquals(4, closeElem^.StateCount);
    AssertEquals(255, Integer(closeElem^.StatePixmaps[0].GetPixel(0, 0).red));
  finally
    engine.Free;
    DeleteDirectory(dir, False);
  end;
end;

procedure TParserLogicTest.TestPngNamedAsBmpFill;
const
  Xml = '<skin version="2" name="pngbmp" transparent_color="#ff00ff">' +
    '<player_window image="volume_fill.bmp">' +
    '<volume position="0,0,26,7" fill_image="volume_fill.bmp"/>' +
    '</player_window></skin>';
var
  dir: string;
  src: TBGRABitmap;
  engine: TSkinEngine;
  vol: PSkinElement;
  pngPath: string;
  pngBytes: TBytes;
  fs: TFileStream;
begin
  dir := MakeTempSkinDir;
  engine := TSkinEngine.Create;
  src := TBGRABitmap.Create(26, 7, BGRA(10, 20, 30, 255));
  try
    pngPath := dir + 'volume_fill.png';
    src.SaveToFile(pngPath);
    fs := TFileStream.Create(pngPath, fmOpenRead or fmShareDenyNone);
    try
      SetLength(pngBytes, fs.Size);
      if fs.Size > 0 then
        fs.ReadBuffer(pngBytes[0], fs.Size);
    finally
      fs.Free;
    end;
    WriteBytes(dir + 'volume_fill.bmp', pngBytes);
    WriteUtf8File(dir + 'Skin.xml', Xml);
    if not engine.LoadFromDirectory(dir) then
      Fail('load png-as-bmp dir=' + dir +
        ' bmpExists=' + BoolToStr(FileExists(dir + 'volume_fill.bmp'), True) +
        ' xmlExists=' + BoolToStr(FileExists(dir + 'Skin.xml'), True) +
        ' pngExists=' + BoolToStr(FileExists(pngPath), True));
    vol := engine.SkinData.PlayerWindow.FindElement('volume');
    AssertTrue(vol <> nil);
    AssertTrue('fill loaded', vol^.FillPixmap <> nil);
    AssertEquals(26, vol^.FillPixmap.Width);
    AssertEquals(7, vol^.FillPixmap.Height);
  finally
    src.Free;
    engine.Free;
    DeleteDirectory(dir, False);
  end;
end;

procedure TParserLogicTest.TestPlaylistBlendUsesQtRound;
var
  skin: TSkinData;
begin
  InitSkinData(skin);
  try
    skin.PlaylistConfig.HasColorText := True;
    skin.PlaylistConfig.ColorText := TSkinColor.Make(10, 10, 10);
    skin.PlaylistConfig.HasColorHilight := True;
    skin.PlaylistConfig.ColorHilight := TSkinColor.Make(0, 0, 0);
    skin.PlaylistConfig.HasColorBkgnd := True;
    skin.PlaylistConfig.ColorBkgnd := TSkinColor.Make(20, 20, 20);
    ResolvePlaylistTheme(skin);
    // qRound(10*0.45 + 0*0.55) = qRound(4.5) = 5；Pascal Round(4.5)=4。
    AssertEquals(5, Integer(skin.PlaylistConfig.ColorDuration.R));
    AssertEquals(5, Integer(skin.PlaylistConfig.ColorDuration.G));
    AssertEquals(5, Integer(skin.PlaylistConfig.ColorDuration.B));
  finally
    FreeSkinData(skin);
  end;
end;

procedure TParserLogicTest.TestEqualizerDefaultSizeWithoutBackground;
var
  skin: TSkinData;
  frame: TBGRABitmap;
  gains: array[0..9] of Double;
  i: Integer;
begin
  InitSkinData(skin);
  for i := 0 to 9 do
    gains[i] := 0;
  frame := RenderEqualizerWindow(skin, gains, 0, 0, 0, False, '', bvsNormal);
  try
    AssertEquals(640, frame.Width);
    AssertEquals(480, frame.Height);
  finally
    frame.Free;
    FreeSkinData(skin);
  end;
end;

procedure TParserLogicTest.TestPackedChromeShiftsToOrigin;
var
  skin: TSkinData;
  frame: TBGRABitmap;
  px: TBGRAPixel;
begin
  InitSkinData(skin);
  try
    skin.LyricWindow.BackgroundPixmap :=
      TBGRABitmap.Create(40, 30, BGRAPixelTransparent);
    skin.LyricWindow.BackgroundPixmap.FillRect(20, 15, 30, 23,
      BGRA(10, 20, 30, 255), dmSet);
    frame := RenderLyricWindow(skin, 40, 30);
    try
      px := frame.GetPixel(0, 0);
      AssertEquals('lyric packed alpha', 255, Integer(px.alpha));
      AssertEquals('lyric packed red', 10, Integer(px.red));
      AssertEquals('lyric packed green', 20, Integer(px.green));
      AssertEquals('lyric packed blue', 30, Integer(px.blue));
      AssertEquals('lyric packed last chrome', 255,
        Integer(frame.GetPixel(9, 7).alpha));
      AssertEquals('lyric old origin cleared', 0,
        Integer(frame.GetPixel(20, 15).alpha));
      AssertEquals('lyric outside chrome', 0,
        Integer(frame.GetPixel(10, 7).alpha));
    finally
      frame.Free;
    end;

    skin.PlaylistWindow.BackgroundPixmap :=
      TBGRABitmap.Create(24, 18, BGRAPixelTransparent);
    skin.PlaylistWindow.BackgroundPixmap.FillRect(8, 6, 16, 12,
      BGRA(40, 50, 60, 255), dmSet);
    frame := RenderPlaylistWindow(skin, 24, 18);
    try
      px := frame.GetPixel(0, 0);
      AssertEquals('playlist packed alpha', 255, Integer(px.alpha));
      AssertEquals('playlist packed red', 40, Integer(px.red));
      AssertEquals('playlist old origin cleared', 0,
        Integer(frame.GetPixel(8, 6).alpha));
    finally
      frame.Free;
    end;
  finally
    FreeSkinData(skin);
  end;
end;

initialization
  RegisterTest(TParserLogicTest);

end.
