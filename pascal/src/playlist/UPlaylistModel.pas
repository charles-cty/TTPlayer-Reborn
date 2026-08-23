unit UPlaylistModel;

{$mode objfpc}{$H+}

// 播放列表数据模型，对应 Qt 版 src/playlist/PlaylistManager。
// 只负责条目集合与当前索引的维护，不涉及任何渲染或 UI 状态。
// 元数据（title/artist/album/duration）由调用方填充——Pascal 侧暂无 TagLib
// 绑定，Step 7 接入 ttcore 后由后端回填（对应 Qt 的 PlaylistMetadataLoader）。

interface

uses
  Classes, SysUtils, Math;

type
  // 对应 PlaylistEntry。MetadataLoaded=False 表示仅有路径占位。
  TPlaylistEntry = record
    FilePath: string;
    Title: string;
    Artist: string;
    Album: string;
    DurationMs: Int64;
    Valid: Boolean;
    MetadataLoaded: Boolean;
  end;

  TPlaylistEntryArray = array of TPlaylistEntry;

  // 对应 PlaylistManager。索引语义与 Qt 版逐行一致（含 currentIndex 的
  // 插入/删除/交换修正规则），保证 Layer 3 逻辑测试可直接对拍。
  TPlaylistModel = class
  private
    FEntries: TPlaylistEntryArray;
    FCount: Integer;
    FCurrentIndex: Integer;
    FShuffle: Boolean;
    FRepeatMode: Integer;   // 0=不重复 1=单曲循环 2=列表循环
    FRandSeed: Cardinal;    // 自带 LCG，避免依赖全局 Randomize（测试可复现）
    function NextRandom(Bound: Integer): Integer;
    function GetEntry(Index: Integer): TPlaylistEntry;
    procedure SetEntry(Index: Integer; const AEntry: TPlaylistEntry);
  public
    constructor Create;

    procedure AddFile(const APath: string);
    procedure InsertFile(Index: Integer; const APath: string);
    procedure AddFiles(const APaths: array of string);
    procedure InsertFiles(Index: Integer; const APaths: array of string);
    procedure RemoveIndex(Index: Integer);
    procedure Clear;

    procedure MoveUp(Index: Integer);
    procedure MoveDown(Index: Integer);
    // 将 SourceIndices（升序）整体移动到 InsertIndex 之前（对应 Qt
    // moveRowsWithinActivePlaylist）。InsertIndex 为移动前的下标空间。
    procedure MoveRows(const SourceIndices: array of Integer; InsertIndex: Integer);

    function FileAt(Index: Integer): string;
    function IndexOfFile(const APath: string): Integer;
    function CurrentFile: string;
    function NextFile: string;
    function PrevFile: string;
    function TotalDurationMs: Int64;

    procedure SetCurrentIndex(Idx: Integer);
    // 填充元数据（后台加载完成时调用）；索引越界时静默忽略。
    procedure SetMetadata(Index: Integer;
      const ATitle, AArtist, AAlbum: string; ADurationMs: Int64);

    property Count: Integer read FCount;
    property Entries[Index: Integer]: TPlaylistEntry read GetEntry write SetEntry; default;
    property CurrentIndex: Integer read FCurrentIndex;
    property Shuffle: Boolean read FShuffle write FShuffle;
    property RepeatMode: Integer read FRepeatMode write FRepeatMode;
    property RandSeed: Cardinal read FRandSeed write FRandSeed;
  end;

// 显示用标题：title 为空时取文件名（不含扩展名）；artist 非空时前置 "artist - "。
// 对应 Qt displayTitleForEntry。
function DisplayTitleForEntry(const AEntry: TPlaylistEntry): string;
// 显示用时长：durationMs<=0 时返回空串。对应 Qt displayDurationForEntry。
function DisplayDurationForEntry(const AEntry: TPlaylistEntry): string;
// "M:SS" / "H:MM:SS"（分秒补零，小时不补零）。对应 Qt formatDurationText。
function FormatDurationText(DurationMs: Int64): string;

implementation

uses
  StrUtils;

function FormatDurationText(DurationMs: Int64): string;
var
  totalSeconds, hours, minutes, seconds: Integer;
begin
  totalSeconds := Integer(Max(Int64(0), DurationMs) div 1000);
  hours   := totalSeconds div 3600;
  minutes := (totalSeconds div 60) mod 60;
  seconds := totalSeconds mod 60;
  if hours > 0 then
    Result := Format('%d:%.2d:%.2d', [hours, minutes, seconds])
  else
    Result := Format('%.2d:%.2d', [minutes, seconds]);
end;

function DisplayTitleForEntry(const AEntry: TPlaylistEntry): string;
begin
  if AEntry.Title <> '' then
    Result := AEntry.Title
  else
    // QFileInfo::completeBaseName —— 去掉最后一个扩展名
    Result := ChangeFileExt(ExtractFileName(AEntry.FilePath), '');
  if AEntry.Artist <> '' then
    Result := AEntry.Artist + ' - ' + Result;
end;

function DisplayDurationForEntry(const AEntry: TPlaylistEntry): string;
begin
  if AEntry.DurationMs > 0 then
    Result := FormatDurationText(AEntry.DurationMs)
  else
    Result := '';
end;

// 构造仅含路径的占位条目（对应 Qt buildEntryForPath 的无 TagLib 分支）。
function BuildEntryForPath(const APath: string): TPlaylistEntry;
begin
  Result.FilePath       := APath;
  Result.Title          := '';
  Result.Artist         := '';
  Result.Album          := '';
  Result.DurationMs     := 0;
  Result.Valid          := True;
  Result.MetadataLoaded := False;
end;

{ TPlaylistModel }

constructor TPlaylistModel.Create;
begin
  inherited Create;
  FCount        := 0;
  FCurrentIndex := -1;
  FShuffle      := False;
  FRepeatMode   := 0;
  FRandSeed     := 22695477;
  SetLength(FEntries, 0);
end;

// 线性同余（Numerical Recipes 参数）——固定种子即可复现，便于测试。
function TPlaylistModel.NextRandom(Bound: Integer): Integer;
begin
  if Bound <= 0 then Exit(0);
  FRandSeed := Cardinal(FRandSeed * 1664525 + 1013904223);
  Result := Integer((FRandSeed shr 16) mod Cardinal(Bound));
end;

function TPlaylistModel.GetEntry(Index: Integer): TPlaylistEntry;
begin
  if (Index < 0) or (Index >= FCount) then
  begin
    Result := BuildEntryForPath('');
    Result.Valid := False;
    Exit;
  end;
  Result := FEntries[Index];
end;

procedure TPlaylistModel.SetEntry(Index: Integer; const AEntry: TPlaylistEntry);
begin
  if (Index < 0) or (Index >= FCount) then Exit;
  FEntries[Index] := AEntry;
end;

procedure TPlaylistModel.AddFile(const APath: string);
begin
  InsertFile(FCount, APath);
end;

procedure TPlaylistModel.InsertFile(Index: Integer; const APath: string);
var
  insertAt, i: Integer;
begin
  insertAt := Min(Max(Index, 0), FCount);
  if FCount >= Length(FEntries) then
    SetLength(FEntries, Max(8, Length(FEntries) * 2));
  for i := FCount downto insertAt + 1 do
    FEntries[i] := FEntries[i - 1];
  FEntries[insertAt] := BuildEntryForPath(APath);
  Inc(FCount);

  // 与 Qt insertFile 一致：插入点在当前项之前（或相同）时当前索引后移。
  if FCurrentIndex >= insertAt then Inc(FCurrentIndex);
  if FCurrentIndex < 0 then FCurrentIndex := 0;
end;

procedure TPlaylistModel.AddFiles(const APaths: array of string);
begin
  InsertFiles(FCount, APaths);
end;

procedure TPlaylistModel.InsertFiles(Index: Integer; const APaths: array of string);
var
  insertStart, processed, i, j: Integer;
begin
  if Length(APaths) = 0 then Exit;
  insertStart := Min(Max(Index, 0), FCount);
  processed   := Length(APaths);

  if FCount + processed > Length(FEntries) then
    SetLength(FEntries, FCount + processed + 8);
  // 整体后移一次，避免逐条 O(n²)
  for i := FCount - 1 downto insertStart do
    FEntries[i + processed] := FEntries[i];
  for j := 0 to processed - 1 do
    FEntries[insertStart + j] := BuildEntryForPath(APaths[j]);
  Inc(FCount, processed);

  if FCurrentIndex >= insertStart then Inc(FCurrentIndex, processed);
  if (FCurrentIndex < 0) and (FCount > 0) then FCurrentIndex := 0;
end;

procedure TPlaylistModel.RemoveIndex(Index: Integer);
var
  i: Integer;
begin
  if (Index < 0) or (Index >= FCount) then Exit;
  for i := Index to FCount - 2 do
    FEntries[i] := FEntries[i + 1];
  Dec(FCount);

  if FCurrentIndex > Index then Dec(FCurrentIndex);
  if FCurrentIndex >= FCount then FCurrentIndex := FCount - 1;
  if FCount = 0 then FCurrentIndex := -1;
end;

procedure TPlaylistModel.Clear;
begin
  FCount := 0;
  SetLength(FEntries, 0);
  FCurrentIndex := -1;
end;

procedure TPlaylistModel.MoveUp(Index: Integer);
var
  tmp: TPlaylistEntry;
begin
  if (Index <= 0) or (Index >= FCount) then Exit;
  tmp := FEntries[Index];
  FEntries[Index] := FEntries[Index - 1];
  FEntries[Index - 1] := tmp;
  if FCurrentIndex = Index then Dec(FCurrentIndex)
  else if FCurrentIndex = Index - 1 then Inc(FCurrentIndex);
end;

procedure TPlaylistModel.MoveDown(Index: Integer);
var
  tmp: TPlaylistEntry;
begin
  if (Index < 0) or (Index >= FCount - 1) then Exit;
  tmp := FEntries[Index];
  FEntries[Index] := FEntries[Index + 1];
  FEntries[Index + 1] := tmp;
  if FCurrentIndex = Index then Inc(FCurrentIndex)
  else if FCurrentIndex = Index + 1 then Dec(FCurrentIndex);
end;

procedure TPlaylistModel.MoveRows(const SourceIndices: array of Integer;
  InsertIndex: Integer);
var
  moved: TPlaylistEntryArray;
  keep: TPlaylistEntryArray;
  isMoved: array of Boolean;
  i, k, n, target, curFileIdx: Integer;
  curPath: string;
begin
  n := Length(SourceIndices);
  if (n = 0) or (FCount = 0) then Exit;

  curPath := CurrentFile;

  SetLength(isMoved, FCount);
  for i := 0 to FCount - 1 do isMoved[i] := False;
  for i := 0 to n - 1 do
    if (SourceIndices[i] >= 0) and (SourceIndices[i] < FCount) then
      isMoved[SourceIndices[i]] := True;

  // 目标位置换算到"剔除被移动项之后"的下标空间
  target := 0;
  for i := 0 to Min(InsertIndex, FCount) - 1 do
    if not isMoved[i] then Inc(target);

  SetLength(moved, 0);
  SetLength(keep, 0);
  for i := 0 to FCount - 1 do
    if isMoved[i] then
    begin
      SetLength(moved, Length(moved) + 1);
      moved[High(moved)] := FEntries[i];
    end
    else
    begin
      SetLength(keep, Length(keep) + 1);
      keep[High(keep)] := FEntries[i];
    end;

  k := 0;
  for i := 0 to target - 1 do begin FEntries[k] := keep[i]; Inc(k); end;
  for i := 0 to High(moved) do begin FEntries[k] := moved[i]; Inc(k); end;
  for i := target to High(keep) do begin FEntries[k] := keep[i]; Inc(k); end;

  // 当前项按文件路径跟随移动（Qt 侧同样以 sourceIndex 重建选择）
  if curPath <> '' then
  begin
    curFileIdx := IndexOfFile(curPath);
    if curFileIdx >= 0 then FCurrentIndex := curFileIdx;
  end;
end;

function TPlaylistModel.FileAt(Index: Integer): string;
begin
  if (Index < 0) or (Index >= FCount) then Exit('');
  Result := FEntries[Index].FilePath;
end;

function TPlaylistModel.IndexOfFile(const APath: string): Integer;
var
  i: Integer;
begin
  for i := 0 to FCount - 1 do
    if FEntries[i].FilePath = APath then Exit(i);
  Result := -1;
end;

function TPlaylistModel.CurrentFile: string;
begin
  if (FCurrentIndex < 0) or (FCurrentIndex >= FCount) then Exit('');
  Result := FEntries[FCurrentIndex].FilePath;
end;

procedure TPlaylistModel.SetCurrentIndex(Idx: Integer);
begin
  if FCount = 0 then
  begin
    FCurrentIndex := -1;
    Exit;
  end;
  if Idx < 0 then Exit;   // 与 Qt 一致：负值不改变当前索引
  FCurrentIndex := Min(Max(Idx, 0), FCount - 1);
end;

function TPlaylistModel.NextFile: string;
var
  idx: Integer;
begin
  if FCount = 0 then Exit('');
  if FRepeatMode = 1 then Exit(CurrentFile);

  if FShuffle then
  begin
    idx := NextRandom(FCount);
    FCurrentIndex := idx;
    Exit(FEntries[idx].FilePath);
  end;

  Inc(FCurrentIndex);
  if FCurrentIndex >= FCount then
  begin
    if FRepeatMode = 2 then
      FCurrentIndex := 0
    else
    begin
      FCurrentIndex := FCount - 1;
      Exit('');
    end;
  end;
  Result := FEntries[FCurrentIndex].FilePath;
end;

function TPlaylistModel.PrevFile: string;
var
  idx: Integer;
begin
  if FCount = 0 then Exit('');
  if FRepeatMode = 1 then Exit(CurrentFile);

  if FShuffle then
  begin
    idx := NextRandom(FCount);
    FCurrentIndex := idx;
    Exit(FEntries[idx].FilePath);
  end;

  Dec(FCurrentIndex);
  if FCurrentIndex < 0 then
  begin
    if FRepeatMode = 2 then
      FCurrentIndex := FCount - 1
    else
    begin
      FCurrentIndex := 0;
      Exit('');
    end;
  end;
  Result := FEntries[FCurrentIndex].FilePath;
end;

function TPlaylistModel.TotalDurationMs: Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FCount - 1 do
    Inc(Result, FEntries[i].DurationMs);
end;

procedure TPlaylistModel.SetMetadata(Index: Integer;
  const ATitle, AArtist, AAlbum: string; ADurationMs: Int64);
begin
  if (Index < 0) or (Index >= FCount) then Exit;
  FEntries[Index].Title          := ATitle;
  FEntries[Index].Artist         := AArtist;
  FEntries[Index].Album          := AAlbum;
  FEntries[Index].DurationMs     := ADurationMs;
  FEntries[Index].MetadataLoaded := True;
end;

end.
