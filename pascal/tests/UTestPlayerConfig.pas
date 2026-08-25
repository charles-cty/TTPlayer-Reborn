unit UTestPlayerConfig;

{$mode objfpc}{$H+}

// 驱动已交付的 TPlayerConfig.LoadFromFile / SaveToFile：
// Qt 属性式夹具往返 + 改键后再存再读。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, UPlayerConfig;

type
  TPlayerConfigTest = class(TTestCase)
  published
    procedure TestLoadQtAttributeFixture;
    procedure TestSaveReloadMutatedLiveKeys;
  end;

implementation

const
  kQtFixture =
    '<?xml version="1.0" encoding="UTF-8"?>' + LineEnding +
    '<ttplayer version="5.7.9">' + LineEnding +
    '  <Player PlayerWnd="10,20,328,208" LyricWnd="30,40,320,156"' +
    ' EqualizerWnd="50,60,340,208" PlayListWnd="70,80,360,196"' +
    ' LyricVisible="0" EqualizerVisible="1" PlayListVisible="0"' +
    ' TopMost="1" PlayMode="1" Shuffle="1" Mute="1" Volume="42" Balance="-15"' +
    ' PlayingFileName="/tmp/song.mp3" SplitOnLists="77" PlayLists="3"' +
    ' ActiveList="2"/>' + LineEnding +
    '  <Playback RepeatMode="1" Shuffle="1"/>' + LineEnding +
    '  <Equalizer Enabled="1" Preamp="3.5"' +
    ' Current="3.5:1.0,2.0,3.0,4.0,5.0,-1.0,-2.0,-3.0,-4.0,-5.0"' +
    ' Band0="1.0" Band1="2.0" Band2="3.0" Band3="4.0" Band4="5.0"' +
    ' Band5="-1.0" Band6="-2.0" Band7="-3.0" Band8="-4.0" Band9="-5.0"/>' + LineEnding +
    '  <Skin PackageName="Classic.skn" Path="/skins/Classic.skn"/>' + LineEnding +
    '  <Histroy SplitOnLists="77" PlayListPath="/lists"/>' + LineEnding +
    '</ttplayer>' + LineEnding;

function ScratchXml(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir) + 'ttplayer-cfg-' + Name;
end;

procedure WriteTextFile(const Path, Contents: string);
var
  sl: TStringList;
begin
  sl := TStringList.Create;
  try
    sl.Text := Contents;
    sl.SaveToFile(Path);
  finally
    sl.Free;
  end;
end;

procedure AssertLiveKeys(T: TTestCase; C: TPlayerConfig);
begin
  T.AssertEquals('volume', 42, C.Volume);
  T.AssertTrue('muted', C.Muted);
  T.AssertEquals('balance', -15, C.Balance);
  T.AssertTrue('eq enabled', C.EqEnabled);
  T.AssertEquals('eq preamp', 3.5, C.EqPreamp);
  T.AssertEquals('band0', 1.0, C.EqBands[0]);
  T.AssertEquals('band4', 5.0, C.EqBands[4]);
  T.AssertEquals('band9', -5.0, C.EqBands[9]);
  T.AssertEquals('player x', 10, C.PlayerX);
  T.AssertEquals('player y', 20, C.PlayerY);
  T.AssertEquals('player w', 318, C.PlayerW);
  T.AssertEquals('player h', 188, C.PlayerH);
  T.AssertEquals('lyric x', 30, C.LyricX);
  T.AssertEquals('lyric w', 290, C.LyricW);
  T.AssertEquals('eq x', 50, C.EqX);
  T.AssertEquals('eq h', 148, C.EqH);
  T.AssertEquals('playlist x', 70, C.PlaylistX);
  T.AssertEquals('playlist h', 116, C.PlaylistH);
  T.AssertEquals('split', 77, C.PlaylistSplitPos);
  T.AssertFalse('lyric vis', C.LyricVisible);
  T.AssertTrue('eq vis', C.EqVisible);
  T.AssertFalse('pl vis', C.PlaylistVisible);
  T.AssertTrue('ontop', C.AlwaysOnTop);
  T.AssertEquals('skin', '/skins/Classic.skn', C.SkinPath);
  T.AssertEquals('repeat', 1, C.RepeatMode);
  T.AssertTrue('shuffle', C.Shuffle);
  T.AssertEquals('last file', '/tmp/song.mp3', C.LastFile);
  T.AssertEquals('pl dir', '/lists', C.PlaylistDir);
  T.AssertEquals('pl count', 3, C.PlaylistCount);
  T.AssertEquals('active', 2, C.ActiveList);
end;

procedure TPlayerConfigTest.TestLoadQtAttributeFixture;
var
  path: string;
  cfg: TPlayerConfig;
begin
  path := ScratchXml('fixture.xml');
  WriteTextFile(path, kQtFixture);
  cfg := TPlayerConfig.Create;
  try
    AssertTrue('load fixture', cfg.LoadFromFile(path));
    AssertLiveKeys(Self, cfg);
  finally
    cfg.Free;
    DeleteFile(path);
  end;
end;

procedure TPlayerConfigTest.TestSaveReloadMutatedLiveKeys;
var
  src, dst: string;
  cfg, again: TPlayerConfig;
  i: Integer;
begin
  src := ScratchXml('src.xml');
  dst := ScratchXml('dst.xml');
  WriteTextFile(src, kQtFixture);
  cfg := TPlayerConfig.Create;
  again := TPlayerConfig.Create;
  try
    AssertTrue(cfg.LoadFromFile(src));
    cfg.Volume := 17;
    cfg.Muted := False;
    cfg.Balance := 25;
    cfg.EqEnabled := False;
    cfg.EqPreamp := -2.5;
    for i := 0 to 9 do
      cfg.EqBands[i] := i - 4.0;
    cfg.PlayerX := 8; cfg.PlayerY := 9; cfg.PlayerW := 300; cfg.PlayerH := 180;
    cfg.LyricX := 11; cfg.LyricY := 12; cfg.LyricW := 200; cfg.LyricH := 80;
    cfg.EqX := 13; cfg.EqY := 14; cfg.EqW := 210; cfg.EqH := 90;
    cfg.PlaylistX := 15; cfg.PlaylistY := 16; cfg.PlaylistW := 220; cfg.PlaylistH := 100;
    cfg.PlaylistSplitPos := 40;
    cfg.LyricVisible := True;
    cfg.EqVisible := False;
    cfg.PlaylistVisible := True;
    cfg.AlwaysOnTop := False;
    cfg.SkinPath := '/skins/HiFi.skn';
    cfg.RepeatMode := 2;
    cfg.Shuffle := False;
    cfg.LastFile := '/music/b.flac';
    cfg.PlaylistDir := '/pl';
    cfg.PlaylistCount := 4;
    cfg.ActiveList := 1;
    AssertTrue('save', cfg.SaveToFile(dst));
    AssertTrue('reload', again.LoadFromFile(dst));
    AssertEquals(17, again.Volume);
    AssertFalse(again.Muted);
    AssertEquals(25, again.Balance);
    AssertFalse(again.EqEnabled);
    AssertEquals(-2.5, again.EqPreamp);
    AssertEquals(5.0, again.EqBands[9]);
    AssertEquals(-4.0, again.EqBands[0]);
    AssertEquals(8, again.PlayerX);
    AssertEquals(300, again.PlayerW);
    AssertEquals(11, again.LyricX);
    AssertEquals(80, again.LyricH);
    AssertEquals(13, again.EqX);
    AssertEquals(90, again.EqH);
    AssertEquals(15, again.PlaylistX);
    AssertEquals(100, again.PlaylistH);
    AssertEquals(40, again.PlaylistSplitPos);
    AssertTrue(again.LyricVisible);
    AssertFalse(again.EqVisible);
    AssertTrue(again.PlaylistVisible);
    AssertFalse(again.AlwaysOnTop);
    AssertEquals('/skins/HiFi.skn', again.SkinPath);
    AssertEquals(2, again.RepeatMode);
    AssertFalse(again.Shuffle);
    AssertEquals('/music/b.flac', again.LastFile);
    AssertEquals('/pl', again.PlaylistDir);
    AssertEquals(4, again.PlaylistCount);
    AssertEquals(1, again.ActiveList);
    AssertEquals('Classic.skn', SkinPackageNameFromSelection('/skins/Classic.skn'));
  finally
    cfg.Free;
    again.Free;
    DeleteFile(src);
    DeleteFile(dst);
  end;
end;

initialization
  RegisterTest(TPlayerConfigTest);
end.
