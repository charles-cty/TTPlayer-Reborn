unit UPlayerMenuSpec;

{$mode objfpc}{$H+}

// Qt createTrayMenu / 歌词 / 播放列表右键菜单的标题数据 + 皮肤目录枚举。
// 无 LCL，供 FPCUnit 与 ttplayer 宿主共用。

interface

uses
  Classes, SysUtils;

type
  TSkinChoice = record
    DisplayName: string;
    Path: string;
  end;
  TSkinChoiceArray = array of TSkinChoice;

const
  PlayerTrayCaptions: array[0..18] of string = (
    '显示主窗口',
    '-',
    '打开文件...',
    '切换皮肤',
    '播放/暂停',
    '停止',
    '上一首',
    '下一首',
    '播放模式',
    '静音切换',
    '音量 +5',
    '音量 -5',
    '-',
    '歌词窗口',
    '均衡器',
    '播放列表',
    '窗口置顶',
    '-',
    '退出'
  );

  PlayModeCaptions: array[0..3] of string = (
    '顺序播放',
    '单曲循环',
    '列表循环',
    '随机播放'
  );

  LyricEncodingMenuCaption = '歌词编码(&E)';
  LyricOffsetMenuCaption = '歌词时间偏移(&O)';
  LyricCloseCaption = '关闭';
  LyricOffsetAheadCaption = '提前 0.5s';
  LyricOffsetBehindCaption = '延后 0.5s';
  LyricOffsetResetCaption = '重置偏移';

  PlaylistListCaptions: array[0..6] of string = (
    '播放(&P)',
    '添加(&A)',
    '从列表删除(&D)',
    '清空列表(&L)',
    '排序(&S)',
    '播放模式(&M)',
    '文件属性(&I)'
  );

  PlaylistAddSubCaptions: array[0..1] of string = (
    '文件(&F)...',
    '文件夹(&D)...'
  );

  PlaylistSortSubCaptions: array[0..3] of string = (
    '按文件名排序',
    '按标题排序',
    '随机排序',
    '反转排序'
  );

  PlaylistChromeCaptions: array[0..2] of string = (
    '添加文件(&A)...',
    '添加文件夹(&F)...',
    '清空列表(&L)'
  );

function CaptionIsSeparator(const Cap: string): Boolean;
function HasCaption(const Cap: string; const List: array of string): Boolean;
function CurrentOffsetCaption(OffsetMs: Integer): string;

function DiscoverSkins(const SkinDir: string): TSkinChoiceArray;
function ResolveSkinPath(const Configured, SkinDir: string): string;

implementation

uses
  LazFileUtils;

function CaptionIsSeparator(const Cap: string): Boolean;
begin
  Result := Cap = '-';
end;

function HasCaption(const Cap: string; const List: array of string): Boolean;
var
  i: Integer;
begin
  for i := Low(List) to High(List) do
    if List[i] = Cap then
      Exit(True);
  Result := False;
end;

function CurrentOffsetCaption(OffsetMs: Integer): string;
begin
  Result := Format('当前偏移: %d ms', [OffsetMs]);
end;

function DiscoverSkins(const SkinDir: string): TSkinChoiceArray;
var
  sr: TSearchRec;
  names: TStringList;
  i: Integer;
  dir, path: string;
begin
  Result := nil;
  dir := IncludeTrailingPathDelimiter(SkinDir);
  names := TStringList.Create;
  try
    names.Sorted := True;
    names.Duplicates := dupIgnore;
    if FindFirst(dir + '*.skn', faAnyFile, sr) = 0 then
    try
      repeat
        if (sr.Attr and faDirectory) = 0 then
          names.Add(dir + sr.Name);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    SetLength(Result, names.Count);
    for i := 0 to names.Count - 1 do
    begin
      path := names[i];
      Result[i].Path := path;
      Result[i].DisplayName := ChangeFileExt(ExtractFileName(path), '');
    end;
  finally
    names.Free;
  end;
end;

function ResolveSkinPath(const Configured, SkinDir: string): string;
var
  dir, candidate: string;
  skins: TSkinChoiceArray;
begin
  Result := '';
  if (Configured <> '') and FileExists(Configured) then
    Exit(Configured);
  dir := IncludeTrailingPathDelimiter(SkinDir);
  if Configured <> '' then
  begin
    candidate := dir + Configured;
    if FileExists(candidate) then Exit(candidate);
    candidate := dir + ExtractFileName(Configured);
    if FileExists(candidate) then Exit(candidate);
  end;
  skins := DiscoverSkins(SkinDir);
  if Length(skins) > 0 then
    Result := skins[0].Path;
end;

end.
