unit UTestTtbl;

{$mode objfpc}{$H+}

// Layer 3：TTBL v3 往返、v5 头部跳过、CUE marker=7、多标签页 book。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, UPlaylistModel, UTtbl, UPlaylistBook;

type
  TTtblTest = class(TTestCase)
  published
    procedure TestRoundTripV3;
    procedure TestParseCueTrack;
    procedure TestParseV5SkipsExtraFields;
    procedure TestBookTabsAndSwitch;
    procedure TestBookTtblDir;
  end;

implementation

procedure TTtblTest.TestRoundTripV3;
var
  src: TPlaylistEntryArray;
  raw: TBytes;
  hdr: TTtblHeader;
  parsed: TTtblEntryArray;
begin
  SetLength(src, 2);
  src[0].FilePath := 'C:\music\晴天.mp3';
  src[0].Title := '晴天';
  src[0].Artist := '周杰伦';
  src[0].DurationMs := 269000;
  src[1].FilePath := '/tmp/foo.flac';
  src[1].Title := 'foo';
  src[1].Artist := '';
  src[1].DurationMs := 120000;

  raw := SerializeTtbl(src, 2, '我的列表', 1);
  parsed := ParseTtbl(raw, hdr);
  AssertEquals(3, hdr.Version);
  AssertEquals(1, hdr.CurrentIndex);
  AssertEquals(2, Integer(hdr.RecordCount));
  AssertEquals('我的列表', hdr.ListName);
  AssertEquals(2, Length(parsed));
  AssertEquals('C:\music\晴天.mp3', parsed[0].FilePath);
  AssertEquals('周杰伦 - 晴天', parsed[0].Title);
  AssertEquals(269000, parsed[0].DurationMs);
  AssertEquals(False, parsed[0].IsCueTrack);
  AssertEquals('/tmp/foo.flac', parsed[1].FilePath);
  AssertEquals('foo', parsed[1].Title);
end;

procedure TTtblTest.TestParseCueTrack;
var
  buf: TBytes;
  len: Integer;
  hdr: TTtblHeader;
  parsed: TTtblEntryArray;
  ws: UnicodeString;
  procedure PutU16(V: Word);
  begin
    buf[len] := Byte(V); buf[len+1] := Byte(V shr 8); Inc(len, 2);
  end;
  procedure PutU32(V: Cardinal);
  begin
    buf[len] := Byte(V); buf[len+1] := Byte(V shr 8);
    buf[len+2] := Byte(V shr 16); buf[len+3] := Byte(V shr 24); Inc(len, 4);
  end;
  procedure PutUtf16(const S: string);
  var
    n: Integer;
  begin
    ws := UTF8Decode(S);
    n := Length(ws) * 2;
    PutU32(Cardinal(n));
    if n > 0 then
    begin
      Move(ws[1], buf[len], n);
      Inc(len, n);
    end;
  end;
begin
  SetLength(buf, 256);
  len := 0;
  buf[0] := Ord('T'); buf[1] := Ord('T'); buf[2] := Ord('B'); buf[3] := Ord('L');
  len := 4;
  PutU32(3);
  PutU32(Cardinal(Integer(-1)));
  PutU32(1);
  PutUtf16('cue');
  PutUtf16('D:\album.wav');
  PutU16($0007);
  PutU16(3);
  PutUtf16('Track 03');
  PutU32(180000);
  SetLength(buf, len);

  parsed := ParseTtbl(buf, hdr);
  AssertEquals(1, Length(parsed));
  AssertTrue(parsed[0].IsCueTrack);
  AssertEquals(3, parsed[0].TrackNumber);
  AssertEquals('Track 03', parsed[0].Title);
  AssertEquals(180000, parsed[0].DurationMs);
end;

procedure TTtblTest.TestParseV5SkipsExtraFields;
var
  buf: TBytes;
  len: Integer;
  hdr: TTtblHeader;
  parsed: TTtblEntryArray;
  ws: UnicodeString;
  procedure PutU32(V: Cardinal);
  begin
    buf[len] := Byte(V); buf[len+1] := Byte(V shr 8);
    buf[len+2] := Byte(V shr 16); buf[len+3] := Byte(V shr 24); Inc(len, 4);
  end;
  procedure PutU16(V: Word);
  begin
    buf[len] := Byte(V); buf[len+1] := Byte(V shr 8); Inc(len, 2);
  end;
  procedure PutUtf16(const S: string);
  var
    n: Integer;
  begin
    ws := UTF8Decode(S);
    n := Length(ws) * 2;
    PutU32(Cardinal(n));
    if n > 0 then begin Move(ws[1], buf[len], n); Inc(len, n); end;
  end;
begin
  SetLength(buf, 256);
  len := 4;
  buf[0] := Ord('T'); buf[1] := Ord('T'); buf[2] := Ord('B'); buf[3] := Ord('L');
  PutU32(5);
  PutU32(0);
  PutU32(1);
  PutUtf16('v5list');
  PutUtf16('%title%');
  PutUtf16('%filename%');
  PutUtf16('a.mp3');
  PutU16($0006);
  PutUtf16('A');
  PutU32(1000);
  SetLength(buf, len);

  parsed := ParseTtbl(buf, hdr);
  AssertEquals(5, hdr.Version);
  AssertEquals('v5list', hdr.ListName);
  AssertEquals(1, Length(parsed));
  AssertEquals('a.mp3', parsed[0].FilePath);
  AssertEquals('A', parsed[0].Title);
end;

procedure TTtblTest.TestBookTabsAndSwitch;
var
  b: TPlaylistBook;
begin
  b := TPlaylistBook.Create;
  try
    AssertEquals(1, b.TabCount);
    AssertEquals('[默认]', b.ActiveName);
    b.ActiveModel.AddFile('a.mp3');
    b.AddTab('收藏');
    AssertEquals(2, b.TabCount);
    b.SwitchTo(1);
    AssertEquals('收藏', b.ActiveName);
    AssertEquals(0, b.ActiveModel.Count);
    b.ActiveModel.AddFile('b.mp3');
    b.SwitchTo(0);
    AssertEquals(1, b.ActiveModel.Count);
    AssertEquals('a.mp3', b.ActiveModel.FileAt(0));
    b.RemoveTab(1);
    AssertEquals(1, b.TabCount);
    AssertEquals(0, b.ActiveIndex);
  finally
    b.Free;
  end;
end;

procedure TTtblTest.TestBookTtblDir;
var
  b, b2: TPlaylistBook;
  dir: string;
begin
  dir := GetTempDir(False) + 'ttbl-test-' + IntToStr(Random(100000));
  ForceDirectories(dir);
  b := TPlaylistBook.Create;
  try
    b.ActiveModel.AddFile('one.mp3');
    b.ActiveModel.SetMetadata(0, 'One', '', '', 1000);
    b.AddTab('第二');
    b.SwitchTo(1);
    b.ActiveModel.AddFile('two.mp3');
    AssertEquals(1, b.SaveToTtblDir(dir));
  finally
    b.Free;
  end;

  b2 := TPlaylistBook.Create;
  try
    b2.LoadFromTtblDir(dir, 2, 1);
    AssertEquals(2, b2.TabCount);
    AssertEquals(1, b2.ActiveIndex);
    AssertEquals('第二', b2.ActiveName);
    AssertEquals('two.mp3', b2.ActiveModel.FileAt(0));
    b2.SwitchTo(0);
    AssertEquals('[默认]', b2.ActiveName);
    AssertEquals('one.mp3', b2.ActiveModel.FileAt(0));
    AssertEquals('One', b2.ActiveModel.Entries[0].Title);
  finally
    b2.Free;
    DeleteFile(IncludeTrailingPathDelimiter(dir) + '0000.ttbl');
    DeleteFile(IncludeTrailingPathDelimiter(dir) + '0001.ttbl');
    RemoveDir(dir);
  end;
end;

initialization
  RegisterTest(TTtblTest);

end.
