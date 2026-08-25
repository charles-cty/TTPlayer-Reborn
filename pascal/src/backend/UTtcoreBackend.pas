unit UTtcoreBackend;

{$mode objfpc}{$H+}

// IPlayerBackend over the ttcore C ABI. Audio-thread cdecl callbacks are
// marshalled onto the main thread with TThread.Queue.

interface

uses
  Classes, SysUtils, SyncObjs, UPlayerBackend, UTtcoreAbi;

type
  TTtcoreBackend = class(TInterfacedObject, IPlayerBackend)
  private
    FPlayer: TTtcorePlayer;
    FLock: TCriticalSection;
    FOpened: Boolean;
    FOnStateChanged: TStateChangedEvent;
    FOnPositionChanged: TPositionChangedEvent;
    FOnDurationChanged: TDurationChangedEvent;
    FOnTrackFinished: TTrackFinishedEvent;
    FOnError: TErrorEvent;
    FQueuedProgress: Boolean;
    FQueuedFinished: Boolean;
    FQueuedError: Boolean;
    FTornDown: Boolean;
    FPendingPos: Int64;
    FPendingError: string;
    procedure DeliverProgress;
    procedure DeliverFinished;
    procedure DeliverError;
    procedure HandleNativeProgress(PositionMs: Int64);
    procedure HandleNativeFinished;
    procedure HandleNativeError(const Message: string);
    procedure EmitState;
    function MapState: TPlayerState;
    function LockedUtf8(Fn: Tttcore_get_title): string;
  public
    constructor Create;
    destructor Destroy; override;

    procedure OpenFile(const FilePath: string);
    procedure Play;
    procedure Pause;
    procedure Stop;
    procedure Seek(PositionMs: Int64);
    function GetState: TPlayerState;
    function GetPositionMs: Int64;
    function GetDurationMs: Int64;
    function GetVolume: Integer;
    function GetIsMuted: Boolean;
    procedure SetVolume(Vol: Integer);
    procedure SetMuted(Muted: Boolean);
    procedure SetEqGain(Band: Integer; GainDb: Double);
    procedure SetPreamp(GainDb: Double);
    procedure SetEqEnabled(Enabled: Boolean);
    function GetEqEnabled: Boolean;
    procedure SetBalance(Value: Integer);
    function GetBalance: Integer;
    function GetTitle: string;
    function GetArtist: string;
    function GetAlbum: string;
    function GetCoverArt: TBytes;
    function GetSpectrum(OutBands: PDouble; BandCount: Integer): Integer;
    procedure SetOnStateChanged(Handler: TStateChangedEvent);
    procedure SetOnPositionChanged(Handler: TPositionChangedEvent);
    procedure SetOnDurationChanged(Handler: TDurationChangedEvent);
    procedure SetOnTrackFinished(Handler: TTrackFinishedEvent);
    procedure SetOnError(Handler: TErrorEvent);
  end;

implementation

procedure ProgressThunk(UserData: Pointer; PositionMs: Int64); cdecl;
begin
  if UserData <> nil then
    TTtcoreBackend(UserData).HandleNativeProgress(PositionMs);
end;

procedure FinishedThunk(UserData: Pointer); cdecl;
begin
  if UserData <> nil then
    TTtcoreBackend(UserData).HandleNativeFinished;
end;

procedure ErrorThunk(UserData: Pointer; Message: PAnsiChar); cdecl;
begin
  if UserData <> nil then
    TTtcoreBackend(UserData).HandleNativeError(Utf8FromPChar(Message));
end;

constructor TTtcoreBackend.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  if not LoadTtcore then
    raise Exception.Create('Failed to load ttcore: ' + TtcoreLoadError);
  FPlayer := ttcore_create();
  if FPlayer = nil then
    raise Exception.Create('ttcore_create returned nil');
  ttcore_set_progress_callback(FPlayer, @ProgressThunk, Pointer(Self));
  ttcore_set_finished_callback(FPlayer, @FinishedThunk, Pointer(Self));
  ttcore_set_error_callback(FPlayer, @ErrorThunk, Pointer(Self));
end;

destructor TTtcoreBackend.Destroy;
var
  p: TTtcorePlayer;
begin
  // Mark torn-down first so in-flight cdecl callbacks skip TThread.Queue.
  // Then unhook + join the SDL audio thread. FLock may be the only field
  // that exists if Create raised before ttcore_create.
  p := nil;
  if FLock <> nil then
  begin
    FLock.Enter;
    try
      FTornDown := True;
      p := FPlayer;
      FPlayer := nil;
      FOnStateChanged := nil;
      FOnPositionChanged := nil;
      FOnDurationChanged := nil;
      FOnTrackFinished := nil;
      FOnError := nil;
    finally
      FLock.Leave;
    end;
  end
  else
  begin
    p := FPlayer;
    FPlayer := nil;
  end;
  if p <> nil then
  begin
    ttcore_set_progress_callback(p, nil, nil);
    ttcore_set_finished_callback(p, nil, nil);
    ttcore_set_error_callback(p, nil, nil);
    ttcore_destroy(p);
  end;
  TThread.RemoveQueuedEvents(@DeliverProgress);
  TThread.RemoveQueuedEvents(@DeliverFinished);
  TThread.RemoveQueuedEvents(@DeliverError);
  CheckSynchronize(0);
  FreeAndNil(FLock);
  inherited Destroy;
end;

function TTtcoreBackend.LockedUtf8(Fn: Tttcore_get_title): string;
begin
  Result := '';
  if (FLock = nil) or not Assigned(Fn) then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    Result := Utf8FromPChar(Fn(FPlayer));
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.HandleNativeProgress(PositionMs: Int64);
var
  needQueue: Boolean;
begin
  needQueue := False;
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    FPendingPos := PositionMs;
    needQueue := not FQueuedProgress;
    FQueuedProgress := True;
  finally
    FLock.Leave;
  end;
  if needQueue then
    TThread.Queue(nil, @DeliverProgress);
end;

procedure TTtcoreBackend.HandleNativeFinished;
var
  needQueue: Boolean;
begin
  needQueue := False;
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    needQueue := not FQueuedFinished;
    FQueuedFinished := True;
  finally
    FLock.Leave;
  end;
  if needQueue then
    TThread.Queue(nil, @DeliverFinished);
end;

procedure TTtcoreBackend.HandleNativeError(const Message: string);
var
  needQueue: Boolean;
begin
  needQueue := False;
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    FPendingError := Message;
    needQueue := not FQueuedError;
    FQueuedError := True;
  finally
    FLock.Leave;
  end;
  if GetCurrentThreadId = MainThreadID then
    DeliverError
  else if needQueue then
    TThread.Queue(nil, @DeliverError);
end;

procedure TTtcoreBackend.DeliverProgress;
var
  pos: Int64;
  handler: TPositionChangedEvent;
begin
  handler := nil;
  FLock.Enter;
  try
    FQueuedProgress := False;
    if FTornDown then
      Exit;
    pos := FPendingPos;
    handler := FOnPositionChanged;
  finally
    FLock.Leave;
  end;
  if Assigned(handler) then
    handler(Self, pos);
end;

procedure TTtcoreBackend.DeliverFinished;
var
  handler: TTrackFinishedEvent;
begin
  handler := nil;
  FLock.Enter;
  try
    FQueuedFinished := False;
    if FTornDown then
      Exit;
    handler := FOnTrackFinished;
  finally
    FLock.Leave;
  end;
  EmitState;
  if Assigned(handler) then
    handler(Self);
end;

procedure TTtcoreBackend.DeliverError;
var
  msg: string;
  handler: TErrorEvent;
begin
  handler := nil;
  FLock.Enter;
  try
    FQueuedError := False;
    if FTornDown then
      Exit;
    msg := FPendingError;
    handler := FOnError;
  finally
    FLock.Leave;
  end;
  if Assigned(handler) then
    handler(Self, msg);
end;

procedure TTtcoreBackend.EmitState;
var
  handler: TStateChangedEvent;
begin
  handler := nil;
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    handler := FOnStateChanged;
  finally
    FLock.Leave;
  end;
  if Assigned(handler) then
    handler(Self, MapState);
end;

function TTtcoreBackend.MapState: TPlayerState;
var
  st: Integer;
  opened: Boolean;
begin
  if FLock = nil then
    Exit(psIdle);
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit(psIdle);
    st := ttcore_get_state(FPlayer);
    opened := FOpened;
  finally
    FLock.Leave;
  end;
  case st of
    Ord(ttcorePlaying): Result := psPlaying;
    Ord(ttcorePaused):  Result := psPaused;
  else
    if opened then
      Result := psStopped
    else
      Result := psIdle;
  end;
end;

procedure TTtcoreBackend.OpenFile(const FilePath: string);
var
  path: UTF8String;
  ok: Integer;
  p: TTtcorePlayer;
  durCb: TDurationChangedEvent;
  posCb: TPositionChangedEvent;
begin
  path := UTF8String(FilePath);
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    p := FPlayer;
  finally
    FLock.Leave;
  end;
  if p = nil then
    Exit;
  ok := ttcore_open(p, PAnsiChar(path));
  FLock.Enter;
  try
    if FTornDown or (FPlayer <> p) then
      Exit;
    FOpened := ok <> 0;
    durCb := FOnDurationChanged;
    posCb := FOnPositionChanged;
  finally
    FLock.Leave;
  end;
  if ok = 0 then
    Exit;
  if Assigned(durCb) then
    durCb(Self, ttcore_get_duration_ms(p));
  if Assigned(posCb) then
    posCb(Self, ttcore_get_position_ms(p));
  Play;
end;

procedure TTtcoreBackend.Play;
var
  p: TTtcorePlayer;
begin
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    p := FPlayer;
  finally
    FLock.Leave;
  end;
  if p <> nil then
    ttcore_play(p);
  EmitState;
end;

procedure TTtcoreBackend.Pause;
var
  p: TTtcorePlayer;
begin
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    p := FPlayer;
  finally
    FLock.Leave;
  end;
  if p <> nil then
    ttcore_pause(p);
  EmitState;
end;

procedure TTtcoreBackend.Stop;
var
  p: TTtcorePlayer;
  posCb: TPositionChangedEvent;
begin
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    p := FPlayer;
    posCb := FOnPositionChanged;
  finally
    FLock.Leave;
  end;
  if p <> nil then
    ttcore_stop(p);
  EmitState;
  if Assigned(posCb) then
    posCb(Self, 0);
end;

procedure TTtcoreBackend.Seek(PositionMs: Int64);
var
  p: TTtcorePlayer;
  posCb: TPositionChangedEvent;
  pos: Int64;
begin
  FLock.Enter;
  try
    if FTornDown then
      Exit;
    p := FPlayer;
    posCb := FOnPositionChanged;
  finally
    FLock.Leave;
  end;
  if p = nil then
    Exit;
  ttcore_seek(p, PositionMs);
  pos := ttcore_get_position_ms(p);
  if Assigned(posCb) then
    posCb(Self, pos);
end;

function TTtcoreBackend.GetState: TPlayerState;
begin
  Result := MapState;
end;

function TTtcoreBackend.GetPositionMs: Int64;
begin
  Result := 0;
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    Result := ttcore_get_position_ms(FPlayer);
  finally
    FLock.Leave;
  end;
end;

function TTtcoreBackend.GetDurationMs: Int64;
begin
  Result := 0;
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    Result := ttcore_get_duration_ms(FPlayer);
  finally
    FLock.Leave;
  end;
end;

function TTtcoreBackend.GetVolume: Integer;
begin
  Result := 0;
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    Result := ttcore_get_volume(FPlayer);
  finally
    FLock.Leave;
  end;
end;

function TTtcoreBackend.GetIsMuted: Boolean;
begin
  Result := False;
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    Result := ttcore_is_muted(FPlayer) <> 0;
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetVolume(Vol: Integer);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    ttcore_set_volume(FPlayer, Vol);
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetMuted(Muted: Boolean);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    if Muted then
      ttcore_set_muted(FPlayer, 1)
    else
      ttcore_set_muted(FPlayer, 0);
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetEqGain(Band: Integer; GainDb: Double);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    ttcore_set_eq_gain(FPlayer, Band, GainDb);
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetPreamp(GainDb: Double);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    ttcore_set_preamp(FPlayer, GainDb);
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetEqEnabled(Enabled: Boolean);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    if Enabled then
      ttcore_set_eq_enabled(FPlayer, 1)
    else
      ttcore_set_eq_enabled(FPlayer, 0);
  finally
    FLock.Leave;
  end;
end;

function TTtcoreBackend.GetEqEnabled: Boolean;
begin
  Result := False;
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    Result := ttcore_get_eq_enabled(FPlayer) <> 0;
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetBalance(Value: Integer);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    ttcore_set_balance(FPlayer, Value);
  finally
    FLock.Leave;
  end;
end;

function TTtcoreBackend.GetBalance: Integer;
begin
  Result := 0;
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    Result := ttcore_get_balance(FPlayer);
  finally
    FLock.Leave;
  end;
end;

function TTtcoreBackend.GetTitle: string;
begin
  Result := LockedUtf8(ttcore_get_title);
end;

function TTtcoreBackend.GetArtist: string;
begin
  Result := LockedUtf8(ttcore_get_artist);
end;

function TTtcoreBackend.GetAlbum: string;
begin
  Result := LockedUtf8(ttcore_get_album);
end;

function TTtcoreBackend.GetCoverArt: TBytes;
var
  n: Integer;
begin
  Result := nil;
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit;
    n := ttcore_get_cover(FPlayer, nil, 0);
    if n <= 0 then
      Exit;
    SetLength(Result, n);
    n := ttcore_get_cover(FPlayer, @Result[0], Length(Result));
    if n < 0 then
      n := 0;
    if n < Length(Result) then
      SetLength(Result, n);
  finally
    FLock.Leave;
  end;
end;

function TTtcoreBackend.GetSpectrum(OutBands: PDouble; BandCount: Integer): Integer;
var
  raw: array of Single;
  n, i, startIdx, endIdx, j: Integer;
  peak: Double;
  sample: Single;
begin
  if (OutBands = nil) or (BandCount <= 0) or (FLock = nil) then
    Exit(0);
  n := 0;
  FLock.Enter;
  try
    if FTornDown or (FPlayer = nil) then
      Exit(0);
    SetLength(raw, 1024);
    n := ttcore_get_spectrum(FPlayer, @raw[0], Length(raw));
  finally
    FLock.Leave;
  end;
  if n < 0 then
    n := 0;
  for i := 0 to BandCount - 1 do
  begin
    if n <= 0 then
    begin
      OutBands[i] := 0;
      Continue;
    end;
    startIdx := (i * n) div BandCount;
    endIdx := ((i + 1) * n) div BandCount;
    if endIdx <= startIdx then
      endIdx := startIdx + 1;
    if endIdx > n then
      endIdx := n;
    peak := 0;
    for j := startIdx to endIdx - 1 do
    begin
      sample := raw[j];
      if sample < 0 then
        sample := -sample;
      if sample > peak then
        peak := sample;
    end;
    if peak > 1 then
      peak := 1;
    OutBands[i] := peak;
  end;
  Result := BandCount;
end;

procedure TTtcoreBackend.SetOnStateChanged(Handler: TStateChangedEvent);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    FOnStateChanged := Handler;
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetOnPositionChanged(Handler: TPositionChangedEvent);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    FOnPositionChanged := Handler;
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetOnDurationChanged(Handler: TDurationChangedEvent);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    FOnDurationChanged := Handler;
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetOnTrackFinished(Handler: TTrackFinishedEvent);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    FOnTrackFinished := Handler;
  finally
    FLock.Leave;
  end;
end;

procedure TTtcoreBackend.SetOnError(Handler: TErrorEvent);
begin
  if FLock = nil then
    Exit;
  FLock.Enter;
  try
    FOnError := Handler;
  finally
    FLock.Leave;
  end;
end;

end.
