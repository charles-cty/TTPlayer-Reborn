unit UTestLayer3;

{$mode objfpc}{$H+}

// Layer 3：解析逻辑的表驱动单元测试（LOGFONT、position、color、bool 等）。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinXmlParser;

type
  TParserLogicTest = class(TTestCase)
  published
    procedure TestParsePosition;
    procedure TestParseColor;
    procedure TestParseLogFont;
    procedure TestParseBool;
    procedure TestQuantizedEndpointColorKey;
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

  // 字段不足 → 保持默认
  f := ParseLogFont('-11,0,0');
  AssertEquals(-1, f.PixelSize);
  AssertEquals('', f.Family);
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
    // #f800f8.  A repeated endpoint color is still the declared color key.
    source := TBGRABitmap.Create(5, 5, BGRA(248, 0, 248, 255));
    source.SetPixel(2, 2, BGRA(24, 32, 40, 255));
    images.Add('bg.bmp', source);
    AssertTrue(ParseSkinXml(Xml, images, TSkinColor.Make(255, 0, 255), skin));
    background := skin.PlayerWindow.BackgroundPixmap;
    AssertTrue(background <> nil);
    AssertEquals('quantized magenta key', 0,
      Integer(background.GetPixel(0, 0).alpha));
    AssertEquals('non-key artwork remains opaque', 255,
      Integer(background.GetPixel(2, 2).alpha));
  finally
    FreeSkinData(skin);
    images.Free;
  end;
end;

initialization
  RegisterTest(TParserLogicTest);

end.
