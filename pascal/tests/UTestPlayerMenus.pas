unit UTestPlayerMenus;

{$mode objfpc}{$H+}

// 皮肤目录枚举、托盘/歌词/播放列表菜单标题、歌词偏移再解析。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, UPlayerMenuSpec, ULrcParser;

type
  TPlayerMenusTest = class(TTestCase)
  published
    procedure TestDiscoverSkinsFromTempDir;
    procedure TestTrayAndPlayModeCaptions;
    procedure TestLyricOffsetReparse;
    procedure TestLyricEncodingCaptions;
    procedure TestPlaylistContextCaptions;
  end;

implementation

procedure TPlayerMenusTest.TestDiscoverSkinsFromTempDir;
var
  dir, a, b: string;
  skins: TSkinChoiceArray;
  sl: TStringList;
  i: Integer;
  sawA, sawB: Boolean;
  picked: string;
begin
  dir := IncludeTrailingPathDelimiter(GetTempDir) + 'ttplayer-skins-' + IntToStr(Random(MaxInt));
  ForceDirectories(dir);
  a := IncludeTrailingPathDelimiter(dir) + 'Alpha.skn';
  b := IncludeTrailingPathDelimiter(dir) + 'Beta.skn';
  sl := TStringList.Create;
  try
    sl.Text := 'placeholder';
    sl.SaveToFile(a);
    sl.SaveToFile(b);
    skins := DiscoverSkins(dir);
    AssertEquals('two skins', 2, Length(skins));
    sawA := False;
    sawB := False;
    for i := 0 to High(skins) do
    begin
      if skins[i].DisplayName = 'Alpha' then
      begin
        sawA := True;
        AssertEquals(a, skins[i].Path);
      end;
      if skins[i].DisplayName = 'Beta' then
      begin
        sawB := True;
        AssertEquals(b, skins[i].Path);
      end;
    end;
    AssertTrue('Alpha present', sawA);
    AssertTrue('Beta present', sawB);
    picked := skins[0].Path;
    AssertTrue('select yields path', (picked = a) or (picked = b));
    AssertEquals(picked, ResolveSkinPath(ExtractFileName(picked), dir));
  finally
    sl.Free;
    DeleteFile(a);
    DeleteFile(b);
    RemoveDir(dir);
  end;
end;

procedure TPlayerMenusTest.TestTrayAndPlayModeCaptions;
begin
  AssertTrue(HasCaption('显示主窗口', PlayerTrayCaptions));
  AssertTrue(HasCaption('打开文件...', PlayerTrayCaptions));
  AssertTrue(HasCaption('切换皮肤', PlayerTrayCaptions));
  AssertTrue(HasCaption('播放/暂停', PlayerTrayCaptions));
  AssertTrue(HasCaption('停止', PlayerTrayCaptions));
  AssertTrue(HasCaption('上一首', PlayerTrayCaptions));
  AssertTrue(HasCaption('下一首', PlayerTrayCaptions));
  AssertTrue(HasCaption('播放模式', PlayerTrayCaptions));
  AssertTrue(HasCaption('静音切换', PlayerTrayCaptions));
  AssertTrue(HasCaption('音量 +5', PlayerTrayCaptions));
  AssertTrue(HasCaption('音量 -5', PlayerTrayCaptions));
  AssertTrue(HasCaption('歌词窗口', PlayerTrayCaptions));
  AssertTrue(HasCaption('均衡器', PlayerTrayCaptions));
  AssertTrue(HasCaption('播放列表', PlayerTrayCaptions));
  AssertTrue(HasCaption('窗口置顶', PlayerTrayCaptions));
  AssertTrue(HasCaption('退出', PlayerTrayCaptions));
  AssertTrue(HasCaption('顺序播放', PlayModeCaptions));
  AssertTrue(HasCaption('单曲循环', PlayModeCaptions));
  AssertTrue(HasCaption('列表循环', PlayModeCaptions));
  AssertTrue(HasCaption('随机播放', PlayModeCaptions));
end;

procedure TPlayerMenusTest.TestLyricOffsetReparse;
var
  raw: TBytes;
  text: RawByteString;
  base, ahead, behind, reseted: TLrcData;
begin
  text := '[00:01.00]one' + LineEnding + '[00:02.00]two';
  SetLength(raw, Length(text));
  if Length(text) > 0 then
    Move(text[1], raw[0], Length(text));
  base := ReparseLyric(raw, leUTF8, 0);
  AssertEquals(2, Length(base.Lines));
  AssertEquals(1000, base.Lines[0].TimeMs);
  AssertEquals(2000, base.Lines[1].TimeMs);
  ahead := ReparseLyric(raw, leUTF8, -500);
  AssertEquals(500, ahead.Lines[0].TimeMs);
  AssertEquals(1500, ahead.Lines[1].TimeMs);
  AssertEquals(-500, ahead.Offset);
  behind := ReparseLyric(raw, leUTF8, 500);
  AssertEquals(1500, behind.Lines[0].TimeMs);
  AssertEquals(2500, behind.Lines[1].TimeMs);
  reseted := ReparseLyric(raw, leUTF8, 0);
  AssertEquals(1000, reseted.Lines[0].TimeMs);
  AssertEquals(2000, reseted.Lines[1].TimeMs);
  AssertEquals('当前偏移: -500 ms', CurrentOffsetCaption(-500));
end;

procedure TPlayerMenusTest.TestLyricEncodingCaptions;
var
  i: Integer;
  names: string;
begin
  names := '';
  for i := Low(AvailableLrcEncodings) to High(AvailableLrcEncodings) do
    names := names + LrcEncodingName(AvailableLrcEncodings[i]) + '|';
  AssertTrue(Pos('自动检测', names) > 0);
  AssertTrue(Pos('UTF-8', names) > 0);
  AssertTrue(Pos('GBK (简体中文)', names) > 0);
  AssertTrue(Pos('Latin-1 (西欧)', names) > 0);
  AssertEquals(LyricEncodingMenuCaption, '歌词编码(&E)');
  AssertEquals(LyricOffsetMenuCaption, '歌词时间偏移(&O)');
  AssertEquals(LyricCloseCaption, '关闭');
  AssertEquals(LyricOffsetAheadCaption, '提前 0.5s');
  AssertEquals(LyricOffsetBehindCaption, '延后 0.5s');
  AssertEquals(LyricOffsetResetCaption, '重置偏移');
end;

procedure TPlayerMenusTest.TestPlaylistContextCaptions;
begin
  AssertTrue(HasCaption('播放(&P)', PlaylistListCaptions));
  AssertTrue(HasCaption('添加(&A)', PlaylistListCaptions));
  AssertTrue(HasCaption('从列表删除(&D)', PlaylistListCaptions));
  AssertTrue(HasCaption('清空列表(&L)', PlaylistListCaptions));
  AssertTrue(HasCaption('排序(&S)', PlaylistListCaptions));
  AssertTrue(HasCaption('播放模式(&M)', PlaylistListCaptions));
  AssertTrue(HasCaption('文件属性(&I)', PlaylistListCaptions));
  AssertTrue(HasCaption('文件(&F)...', PlaylistAddSubCaptions));
  AssertTrue(HasCaption('文件夹(&D)...', PlaylistAddSubCaptions));
  AssertTrue(HasCaption('按文件名排序', PlaylistSortSubCaptions));
  AssertTrue(HasCaption('按标题排序', PlaylistSortSubCaptions));
  AssertTrue(HasCaption('随机排序', PlaylistSortSubCaptions));
  AssertTrue(HasCaption('反转排序', PlaylistSortSubCaptions));
  AssertTrue(HasCaption('添加文件(&A)...', PlaylistChromeCaptions));
  AssertTrue(HasCaption('添加文件夹(&F)...', PlaylistChromeCaptions));
  AssertTrue(HasCaption('清空列表(&L)', PlaylistChromeCaptions));
end;

initialization
  RegisterTest(TPlayerMenusTest);
end.
