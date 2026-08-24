unit UTestLrcParser;

{$mode objfpc}{$H+}

// Layer 3：LRC 解析（时间戳、元数据、offset、多时间戳、当前行索引）。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, ULrcParser;

type
  TLrcParserTest = class(TTestCase)
  published
    procedure TestBasicTimesAndTags;
    procedure TestCentisecondsAndMillis;
    procedure TestMultiTimestampLine;
    procedure TestOffsetAppliesToFollowingLines;
    procedure TestCurrentIndex;
    procedure TestEmptyAndJunk;
    procedure TestGbkFallback;
  end;

implementation

procedure TLrcParserTest.TestBasicTimesAndTags;
var
  d: TLrcData;
begin
  d := ParseLrcText(
    '[ti:晴天]' + LineEnding +
    '[ar:周杰伦]' + LineEnding +
    '[al:叶惠美]' + LineEnding +
    '[00:12.00]故事的小黄花' + LineEnding +
    '[00:16.50]从出生那年就飘着');
  AssertEquals('晴天', d.Title);
  AssertEquals('周杰伦', d.Artist);
  AssertEquals('叶惠美', d.Album);
  AssertEquals(2, Length(d.Lines));
  AssertEquals(12000, d.Lines[0].TimeMs);
  AssertEquals('故事的小黄花', d.Lines[0].Text);
  AssertEquals(16500, d.Lines[1].TimeMs);
end;

procedure TLrcParserTest.TestCentisecondsAndMillis;
var
  d: TLrcData;
begin
  d := ParseLrcText('[01:02.03]a' + LineEnding + '[01:02.345]b');
  AssertEquals(2, Length(d.Lines));
  AssertEquals(Int64(1) * 60000 + 2000 + 30, d.Lines[0].TimeMs);
  AssertEquals(Int64(1) * 60000 + 2000 + 345, d.Lines[1].TimeMs);
end;

procedure TLrcParserTest.TestMultiTimestampLine;
var
  d: TLrcData;
begin
  d := ParseLrcText('[00:10.00][00:20.00]chorus');
  AssertEquals(2, Length(d.Lines));
  AssertEquals(10000, d.Lines[0].TimeMs);
  AssertEquals(20000, d.Lines[1].TimeMs);
  AssertEquals('chorus', d.Lines[0].Text);
  AssertEquals('chorus', d.Lines[1].Text);
end;

procedure TLrcParserTest.TestOffsetAppliesToFollowingLines;
var
  d: TLrcData;
begin
  d := ParseLrcText(
    '[00:01.00]before' + LineEnding +
    '[offset:500]' + LineEnding +
    '[00:02.00]after');
  AssertEquals(500, d.Offset);
  AssertEquals(1000, d.Lines[0].TimeMs);
  AssertEquals(2500, d.Lines[1].TimeMs);
end;

procedure TLrcParserTest.TestCurrentIndex;
var
  d: TLrcData;
begin
  d := ParseLrcText('[00:00.00]a' + LineEnding + '[00:10.00]b' + LineEnding +
    '[00:20.00]c');
  AssertEquals(-1, CurrentLyricIndex(d, -1));
  AssertEquals(0, CurrentLyricIndex(d, 0));
  AssertEquals(0, CurrentLyricIndex(d, 9999));
  AssertEquals(1, CurrentLyricIndex(d, 10000));
  AssertEquals(2, CurrentLyricIndex(d, 20000));
  AssertEquals(2, CurrentLyricIndex(d, 999999));
end;

procedure TLrcParserTest.TestEmptyAndJunk;
var
  d: TLrcData;
begin
  d := ParseLrcText('');
  AssertEquals(0, Length(d.Lines));
  d := ParseLrcText('not a lyric' + LineEnding + '[bad' + LineEnding);
  AssertEquals(0, Length(d.Lines));
end;

procedure TLrcParserTest.TestGbkFallback;
var
  raw: TBytes;
  d: TLrcData;
  prefix: RawByteString;
  i: Integer;
begin
  // "[00:01.00]你好" 的 GBK 编码（ASCII 前缀 + C4 E3 BA C3）
  prefix := '[00:01.00]';
  SetLength(raw, Length(prefix) + 4);
  for i := 1 to Length(prefix) do
    raw[i - 1] := Byte(prefix[i]);
  raw[Length(prefix)]     := $C4;
  raw[Length(prefix) + 1] := $E3;
  raw[Length(prefix) + 2] := $BA;
  raw[Length(prefix) + 3] := $C3;
  d := ParseLrc(raw, leAutoDetect);
  AssertEquals(1, Length(d.Lines));
  AssertEquals(1000, d.Lines[0].TimeMs);
  AssertEquals('你好', d.Lines[0].Text);
  d := ParseLrc(raw, leGBK);
  AssertEquals('你好', d.Lines[0].Text);
end;

initialization
  RegisterTest(TLrcParserTest);

end.
