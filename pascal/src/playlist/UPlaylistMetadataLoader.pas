unit UPlaylistMetadataLoader;

{$mode objfpc}{$H+}

// Background FFmpeg metadata fill via ttcore (same shape as Qt PlaylistMetadataLoader).
// Worker thread calls ttcore_read_metadata; results are marshalled with TThread.Queue
// before TPlaylistModel.SetMetadata.

interface

uses
  Classes, SysUtils, SyncObjs, UPlaylistModel, UTtcoreAbi;

type
  TMetadataReadyEvent = procedure(Sender: TObject; Index: Integer;
    const FilePath, Title, Artist, Album: string; DurationMs: Int64) of object;

  TPlaylistMetadataLoader = class
  private
    type
      TReadyItem = record
        Index: Integer;
        FilePath: string;
        Title: string;
        Artist: string;
        Album: string;
        DurationMs: Int64;
      end;
  private
    FLock: TCriticalSection;
    FModel: TPlaylistModel;
    FPaths: array of string;
    FSkip: array of Boolean;
    FReady: array of TReadyItem;
    FReadyCount: Integer;
    FStop: Boolean;
    FFinished: Boolean;
    FQueuedDrain: Boolean;
    FThread: TThread;
    FOnMetadataReady: TMetadataReadyEvent;
    procedure DrainReady;
    procedure MarkFinished;
    procedure PushReady(Index: Integer; const FilePath, Title, Artist, Album: string;
      DurationMs: Int64);
  public
    constructor Create;
    destructor Destroy; override;
    procedure StartLoading(AModel: TPlaylistModel);
    procedure Cancel;
    function IsFinished: Boolean;
    property OnMetadataReady: TMetadataReadyEvent read FOnMetadataReady write FOnMetadataReady;
  end;

implementation

type
  TMetaWorker = class(TThread)
  private
    FOwner: TPlaylistMetadataLoader;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TPlaylistMetadataLoader);
  end;

constructor TMetaWorker.Create(AOwner: TPlaylistMetadataLoader);
begin
  inherited Create(True);
  FOwner := AOwner;
  FreeOnTerminate := False;
end;

procedure TMetaWorker.Execute;
var
  i, n: Integer;
  path: UTF8String;
  meta: TTtcoreMetadata;
  title, artist, album: string;
  duration: Int64;
  skip, stopNow: Boolean;
begin
  if not LoadTtcore then
  begin
    FOwner.MarkFinished;
    Exit;
  end;

  FOwner.FLock.Enter;
  try
    n := Length(FOwner.FPaths);
  finally
    FOwner.FLock.Leave;
  end;

  for i := 0 to n - 1 do
  begin
    if Terminated then
      Break;
    skip := False;
    stopNow := False;
    FOwner.FLock.Enter;
    try
      stopNow := FOwner.FStop;
      if not stopNow then
      begin
        path := UTF8String(FOwner.FPaths[i]);
        skip := (i < Length(FOwner.FSkip)) and FOwner.FSkip[i];
      end;
    finally
      FOwner.FLock.Leave;
    end;
    if stopNow then
      Break;
    if skip then
      Continue;

    FillChar(meta, SizeOf(meta), 0);
    duration := 0;
    title := '';
    artist := '';
    album := '';
    if ttcore_read_metadata(PAnsiChar(path), meta) <> 0 then
    begin
      title := Utf8FromPChar(@meta.Title[0]);
      artist := Utf8FromPChar(@meta.Artist[0]);
      album := Utf8FromPChar(@meta.Album[0]);
      duration := meta.DurationMs;
    end;
    FOwner.PushReady(i, string(path), title, artist, album, duration);
  end;
  FOwner.MarkFinished;
end;

constructor TPlaylistMetadataLoader.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FFinished := True;
end;

destructor TPlaylistMetadataLoader.Destroy;
begin
  Cancel;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  CheckSynchronize(0);
  TThread.RemoveQueuedEvents(@DrainReady);
  FModel := nil;
  FLock.Free;
  inherited Destroy;
end;

procedure TPlaylistMetadataLoader.Cancel;
begin
  FLock.Enter;
  try
    FStop := True;
  finally
    FLock.Leave;
  end;
  if FThread <> nil then
    FThread.Terminate;
end;

function TPlaylistMetadataLoader.IsFinished: Boolean;
begin
  FLock.Enter;
  try
    Result := FFinished;
  finally
    FLock.Leave;
  end;
end;

procedure TPlaylistMetadataLoader.MarkFinished;
begin
  FLock.Enter;
  try
    FFinished := True;
  finally
    FLock.Leave;
  end;
end;

procedure TPlaylistMetadataLoader.PushReady(Index: Integer;
  const FilePath, Title, Artist, Album: string; DurationMs: Int64);
var
  needQueue: Boolean;
begin
  FLock.Enter;
  try
    if FReadyCount >= Length(FReady) then
      SetLength(FReady, FReadyCount + 8);
    FReady[FReadyCount].Index := Index;
    FReady[FReadyCount].FilePath := FilePath;
    FReady[FReadyCount].Title := Title;
    FReady[FReadyCount].Artist := Artist;
    FReady[FReadyCount].Album := Album;
    FReady[FReadyCount].DurationMs := DurationMs;
    Inc(FReadyCount);
    needQueue := not FQueuedDrain;
    FQueuedDrain := True;
  finally
    FLock.Leave;
  end;
  if needQueue then
    TThread.Queue(nil, @DrainReady);
end;

procedure TPlaylistMetadataLoader.DrainReady;
var
  copyItems: array of TReadyItem;
  n, i, idx: Integer;
  item: TReadyItem;
begin
  FLock.Enter;
  try
    n := FReadyCount;
    SetLength(copyItems, n);
    for i := 0 to n - 1 do
      copyItems[i] := FReady[i];
    FReadyCount := 0;
    FQueuedDrain := False;
  finally
    FLock.Leave;
  end;
  if FModel = nil then
    Exit;
  for i := 0 to n - 1 do
  begin
    item := copyItems[i];
    idx := item.Index;
    if (idx < 0) or (idx >= FModel.Count) or (FModel.FileAt(idx) <> item.FilePath) then
      idx := FModel.IndexOfFile(item.FilePath);
    if idx < 0 then
      Continue;
    FModel.SetMetadata(idx, item.Title, item.Artist, item.Album, item.DurationMs);
    if Assigned(FOnMetadataReady) then
      FOnMetadataReady(Self, idx, item.FilePath, item.Title, item.Artist,
        item.Album, item.DurationMs);
  end;
end;

procedure TPlaylistMetadataLoader.StartLoading(AModel: TPlaylistModel);
var
  i: Integer;
  e: TPlaylistEntry;
begin
  Cancel;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
  CheckSynchronize(0);

  FModel := AModel;
  FLock.Enter;
  try
    FStop := False;
    FFinished := False;
    FReadyCount := 0;
    FQueuedDrain := False;
    if AModel = nil then
    begin
      SetLength(FPaths, 0);
      SetLength(FSkip, 0);
      FFinished := True;
    end
    else
    begin
      SetLength(FPaths, AModel.Count);
      SetLength(FSkip, AModel.Count);
      for i := 0 to AModel.Count - 1 do
      begin
        e := AModel.Entries[i];
        FPaths[i] := e.FilePath;
        FSkip[i] := e.MetadataLoaded;
      end;
    end;
  finally
    FLock.Leave;
  end;

  if FFinished then
    Exit;
  FThread := TMetaWorker.Create(Self);
  FThread.Start;
end;

end.
