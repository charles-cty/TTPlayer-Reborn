unit UTtcoreAbi;

{$mode objfpc}{$H+}

// Dynamic loader for the ttcore C ABI (libttcore.so / ttcore.dll).

interface

uses
  Classes, SysUtils, dynlibs;

const
  TTCORE_META_STRLEN = 512;

type
  TTtcorePlayer = Pointer;

  TTtcoreState = (
    ttcoreStopped = 0,
    ttcorePlaying = 1,
    ttcorePaused  = 2
  );

  TTtcoreProgressCb = procedure(UserData: Pointer; PositionMs: Int64); cdecl;
  TTtcoreFinishedCb = procedure(UserData: Pointer); cdecl;
  TTtcoreErrorCb = procedure(UserData: Pointer; Message: PAnsiChar); cdecl;

  TTtcoreMetadata = record
    Title: array[0..TTCORE_META_STRLEN - 1] of AnsiChar;
    Artist: array[0..TTCORE_META_STRLEN - 1] of AnsiChar;
    Album: array[0..TTCORE_META_STRLEN - 1] of AnsiChar;
    DurationMs: Int64;
  end;

  Tttcore_create = function: TTtcorePlayer; cdecl;
  Tttcore_destroy = procedure(Player: TTtcorePlayer); cdecl;
  Tttcore_open = function(Player: TTtcorePlayer; PathUtf8: PAnsiChar): Integer; cdecl;
  Tttcore_play = procedure(Player: TTtcorePlayer); cdecl;
  Tttcore_pause = procedure(Player: TTtcorePlayer); cdecl;
  Tttcore_stop = procedure(Player: TTtcorePlayer); cdecl;
  Tttcore_seek = procedure(Player: TTtcorePlayer; PositionMs: Int64); cdecl;
  Tttcore_get_state = function(Player: TTtcorePlayer): Integer; cdecl;
  Tttcore_get_position_ms = function(Player: TTtcorePlayer): Int64; cdecl;
  Tttcore_get_duration_ms = function(Player: TTtcorePlayer): Int64; cdecl;
  Tttcore_last_error = function(Player: TTtcorePlayer): PAnsiChar; cdecl;
  Tttcore_set_volume = procedure(Player: TTtcorePlayer; Volume: Integer); cdecl;
  Tttcore_get_volume = function(Player: TTtcorePlayer): Integer; cdecl;
  Tttcore_set_muted = procedure(Player: TTtcorePlayer; Muted: Integer); cdecl;
  Tttcore_is_muted = function(Player: TTtcorePlayer): Integer; cdecl;
  Tttcore_set_eq_enabled = procedure(Player: TTtcorePlayer; Enabled: Integer); cdecl;
  Tttcore_get_eq_enabled = function(Player: TTtcorePlayer): Integer; cdecl;
  Tttcore_set_eq_gain = procedure(Player: TTtcorePlayer; Band: Integer; GainDb: Double); cdecl;
  Tttcore_get_eq_gain = function(Player: TTtcorePlayer; Band: Integer): Double; cdecl;
  Tttcore_set_preamp = procedure(Player: TTtcorePlayer; GainDb: Double); cdecl;
  Tttcore_get_preamp = function(Player: TTtcorePlayer): Double; cdecl;
  Tttcore_set_balance = procedure(Player: TTtcorePlayer; Balance: Integer); cdecl;
  Tttcore_get_balance = function(Player: TTtcorePlayer): Integer; cdecl;
  Tttcore_get_title = function(Player: TTtcorePlayer): PAnsiChar; cdecl;
  Tttcore_get_artist = function(Player: TTtcorePlayer): PAnsiChar; cdecl;
  Tttcore_get_album = function(Player: TTtcorePlayer): PAnsiChar; cdecl;
  Tttcore_get_cover = function(Player: TTtcorePlayer; OutBuf: PByte; Cap: Integer): Integer; cdecl;
  Tttcore_get_spectrum = function(Player: TTtcorePlayer; OutBuf: PSingle; Count: Integer): Integer; cdecl;
  Tttcore_set_progress_callback = procedure(Player: TTtcorePlayer; Cb: TTtcoreProgressCb; UserData: Pointer); cdecl;
  Tttcore_set_finished_callback = procedure(Player: TTtcorePlayer; Cb: TTtcoreFinishedCb; UserData: Pointer); cdecl;
  Tttcore_set_error_callback = procedure(Player: TTtcorePlayer; Cb: TTtcoreErrorCb; UserData: Pointer); cdecl;
  Tttcore_read_metadata = function(PathUtf8: PAnsiChar; out Meta: TTtcoreMetadata): Integer; cdecl;
  Tttcore_write_metadata = function(PathUtf8, TitleUtf8, ArtistUtf8, AlbumUtf8: PAnsiChar): Integer; cdecl;

var
  ttcore_create: Tttcore_create;
  ttcore_destroy: Tttcore_destroy;
  ttcore_open: Tttcore_open;
  ttcore_play: Tttcore_play;
  ttcore_pause: Tttcore_pause;
  ttcore_stop: Tttcore_stop;
  ttcore_seek: Tttcore_seek;
  ttcore_get_state: Tttcore_get_state;
  ttcore_get_position_ms: Tttcore_get_position_ms;
  ttcore_get_duration_ms: Tttcore_get_duration_ms;
  ttcore_last_error: Tttcore_last_error;
  ttcore_set_volume: Tttcore_set_volume;
  ttcore_get_volume: Tttcore_get_volume;
  ttcore_set_muted: Tttcore_set_muted;
  ttcore_is_muted: Tttcore_is_muted;
  ttcore_set_eq_enabled: Tttcore_set_eq_enabled;
  ttcore_get_eq_enabled: Tttcore_get_eq_enabled;
  ttcore_set_eq_gain: Tttcore_set_eq_gain;
  ttcore_get_eq_gain: Tttcore_get_eq_gain;
  ttcore_set_preamp: Tttcore_set_preamp;
  ttcore_get_preamp: Tttcore_get_preamp;
  ttcore_set_balance: Tttcore_set_balance;
  ttcore_get_balance: Tttcore_get_balance;
  ttcore_get_title: Tttcore_get_title;
  ttcore_get_artist: Tttcore_get_artist;
  ttcore_get_album: Tttcore_get_album;
  ttcore_get_cover: Tttcore_get_cover;
  ttcore_get_spectrum: Tttcore_get_spectrum;
  ttcore_set_progress_callback: Tttcore_set_progress_callback;
  ttcore_set_finished_callback: Tttcore_set_finished_callback;
  ttcore_set_error_callback: Tttcore_set_error_callback;
  ttcore_read_metadata: Tttcore_read_metadata;
  ttcore_write_metadata: Tttcore_write_metadata;

function TtcoreLibName: string;
function TtcoreAvailable: Boolean;
function LoadTtcore: Boolean;
function TtcoreLoadError: string;
function Utf8FromPChar(P: PAnsiChar): string;

implementation

var
  GLib: TLibHandle = NilHandle;
  GTried: Boolean = False;
  GError: string = '';

function TtcoreLibName: string;
begin
  {$IFDEF WINDOWS}
  Result := 'ttcore.dll';
  {$ELSE}
  Result := 'libttcore.so';
  {$ENDIF}
end;

function TtcoreLoadError: string;
begin
  Result := GError;
end;

function Utf8FromPChar(P: PAnsiChar): string;
var
  n: Integer;
begin
  if (P = nil) or (P^ = #0) then
    Exit('');
  n := 0;
  while P[n] <> #0 do
    Inc(n);
  SetLength(Result, n);
  if n > 0 then
    Move(P^, Result[1], n);
end;

function Bind(const Name: string; out Proc): Boolean;
var
  p: Pointer;
begin
  Pointer(Proc) := nil;
  p := GetProcedureAddress(GLib, Name);
  Result := p <> nil;
  if Result then
    Pointer(Proc) := p
  else if GError = '' then
    GError := 'missing symbol: ' + Name;
end;

function TryLoadFrom(const Path: string): Boolean;
begin
  Result := False;
  if Path = '' then Exit;
  if (ExtractFilePath(Path) <> '') and (not FileExists(Path)) then Exit;
  GLib := LoadLibrary(Path);
  Result := GLib <> NilHandle;
  if not Result then
    GError := 'LoadLibrary failed: ' + Path;
end;

function LoadTtcore: Boolean;
var
  exeDir, repo, libName: string;
  paths: array of string;
  i: Integer;
begin
  if GLib <> NilHandle then
    Exit(True);
  if GTried then
    Exit(False);
  GTried := True;
  GError := '';
  libName := TtcoreLibName;
  exeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  repo := ExpandFileName(exeDir + '..' + PathDelim + '..' + PathDelim);
  repo := IncludeTrailingPathDelimiter(repo);

  SetLength(paths, 8);
  paths[0] := GetEnvironmentVariable('TTCORE_LIB');
  paths[1] := exeDir + libName;
  paths[2] := repo + 'pascal' + PathDelim + 'bin' + PathDelim + libName;
  paths[3] := repo + 'build-ttcore' + PathDelim + libName;
  paths[4] := repo + 'build' + PathDelim + libName;
  paths[5] := repo + 'build-linux' + PathDelim + libName;
  paths[6] := repo + libName;
  paths[7] := libName;

  Result := False;
  for i := 0 to High(paths) do
    if TryLoadFrom(paths[i]) then
    begin
      Result := True;
      Break;
    end;
  if not Result then
  begin
    if GError = '' then
      GError := 'could not find ' + libName;
    Exit(False);
  end;

  Result :=
    Bind('ttcore_create', ttcore_create) and
    Bind('ttcore_destroy', ttcore_destroy) and
    Bind('ttcore_open', ttcore_open) and
    Bind('ttcore_play', ttcore_play) and
    Bind('ttcore_pause', ttcore_pause) and
    Bind('ttcore_stop', ttcore_stop) and
    Bind('ttcore_seek', ttcore_seek) and
    Bind('ttcore_get_state', ttcore_get_state) and
    Bind('ttcore_get_position_ms', ttcore_get_position_ms) and
    Bind('ttcore_get_duration_ms', ttcore_get_duration_ms) and
    Bind('ttcore_last_error', ttcore_last_error) and
    Bind('ttcore_set_volume', ttcore_set_volume) and
    Bind('ttcore_get_volume', ttcore_get_volume) and
    Bind('ttcore_set_muted', ttcore_set_muted) and
    Bind('ttcore_is_muted', ttcore_is_muted) and
    Bind('ttcore_set_eq_enabled', ttcore_set_eq_enabled) and
    Bind('ttcore_get_eq_enabled', ttcore_get_eq_enabled) and
    Bind('ttcore_set_eq_gain', ttcore_set_eq_gain) and
    Bind('ttcore_get_eq_gain', ttcore_get_eq_gain) and
    Bind('ttcore_set_preamp', ttcore_set_preamp) and
    Bind('ttcore_get_preamp', ttcore_get_preamp) and
    Bind('ttcore_set_balance', ttcore_set_balance) and
    Bind('ttcore_get_balance', ttcore_get_balance) and
    Bind('ttcore_get_title', ttcore_get_title) and
    Bind('ttcore_get_artist', ttcore_get_artist) and
    Bind('ttcore_get_album', ttcore_get_album) and
    Bind('ttcore_get_cover', ttcore_get_cover) and
    Bind('ttcore_get_spectrum', ttcore_get_spectrum) and
    Bind('ttcore_set_progress_callback', ttcore_set_progress_callback) and
    Bind('ttcore_set_finished_callback', ttcore_set_finished_callback) and
    Bind('ttcore_set_error_callback', ttcore_set_error_callback) and
    Bind('ttcore_read_metadata', ttcore_read_metadata) and
    Bind('ttcore_write_metadata', ttcore_write_metadata);
  if not Result then
  begin
    UnloadLibrary(GLib);
    GLib := NilHandle;
  end;
end;

function TtcoreAvailable: Boolean;
begin
  Result := LoadTtcore;
end;

end.
