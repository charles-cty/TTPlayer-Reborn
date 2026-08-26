unit UTestTtcoreBackend;

{$mode objfpc}{$H+}

// FPCUnit tests that drive the shipped ttcore-backed IPlayerBackend and the
// FFmpeg-via-ttcore metadata loader. WAV fixtures are generated at runtime;
// MP3 remux uses pascal/tests/fixtures/sine.mp3.

interface

uses
  Classes, SysUtils, Math, fpcunit, testregistry,
  UPlayerBackend, UTtcoreBackend, UTtcoreAbi,
  UPlaylistModel, UPlaylistMetadataLoader;

type
  TTtcoreBackendTest = class(TTestCase)
  private
    FGotError: Boolean;
    FLastError: string;
    FLastDuration: Int64;
    FWorkDir: string;
    FWavPath: string;
    FTaggedPath: string;
    FCoverWavPath: string;
    FCoverImgPath: string;
    FMp3Path: string;
    FExpectedDurationMs: Integer;
    procedure OnErr(Sender: TObject; const Message: string);
    procedure OnDur(Sender: TObject; DurationMs: Int64);
    procedure RequireTtcore;
    function WriteFixture(const Path: string; DurationMs: Integer): Boolean;
    procedure WriteTinyPng(const Path: string);
    function ReadAllBytes(const Path: string): TBytes;
    function Mp3FixturePath: string;
    function CopyFileTo(const Src, Dst: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestOpenDurationPlayPauseStopSeekVolumeEqSpectrum;
    procedure TestMissingPathError;
    procedure TestTaggedMetadataApi;
    procedure TestTaggedMp3RemuxMetadata;
    procedure TestMetadataLoaderFillsPlaylist;
    procedure TestDestroyWhilePlaying;
    procedure TestBalanceRoundTrip;
    procedure TestCoverSidecarVsAbsent;
    procedure TestGettersDuringOpenStop;
    procedure TestUnicodePathOpen;
  end;

implementation

type
  TGetterHammer = class(TThread)
  private
    FBackend: IPlayerBackend;
  protected
    procedure Execute; override;
  public
    Iters: Integer;
    constructor Create(ABackend: IPlayerBackend);
  end;

constructor TGetterHammer.Create(ABackend: IPlayerBackend);
begin
  inherited Create(True);
  FBackend := ABackend;
  FreeOnTerminate := False;
  Iters := 0;
end;

procedure TGetterHammer.Execute;
var
  cover: TBytes;
begin
  while not Terminated do
  begin
    FBackend.GetTitle;
    FBackend.GetArtist;
    FBackend.GetAlbum;
    FBackend.GetPositionMs;
    FBackend.GetDurationMs;
    FBackend.GetBalance;
    cover := FBackend.GetCoverArt;
    if Length(cover) < 0 then
      Break;
    Inc(Iters);
  end;
end;

{$IFDEF UNIX}
function CSetEnv(Name, Value: PAnsiChar; Overwrite: LongInt): LongInt; cdecl;
  external 'c' name 'setenv';
{$ENDIF}
{$IFDEF WINDOWS}
function SetEnvironmentVariableA(Name, Value: PAnsiChar): LongBool; stdcall;
  external 'kernel32' name 'SetEnvironmentVariableA';
{$ENDIF}

procedure PumpMs(Ms: Integer);
var
  t: QWord;
begin
  t := GetTickCount64;
  while GetTickCount64 - t < QWord(Ms) do
  begin
    CheckSynchronize(10);
    Sleep(5);
  end;
  CheckSynchronize(0);
end;

procedure WriteU16(S: TStream; V: Word);
begin
  S.WriteBuffer(V, SizeOf(V));
end;

procedure WriteU32(S: TStream; V: Cardinal);
begin
  S.WriteBuffer(V, SizeOf(V));
end;

procedure WriteFour(S: TStream; const Id: string);
var
  b: array[0..3] of AnsiChar;
begin
  b[0] := Id[1];
  b[1] := Id[2];
  b[2] := Id[3];
  b[3] := Id[4];
  S.WriteBuffer(b[0], 4);
end;

function TTtcoreBackendTest.WriteFixture(const Path: string; DurationMs: Integer): Boolean;
const
  SampleRate = 44100;
var
  fs: TFileStream;
  numSamples, dataBytes, i: Integer;
  sample: SmallInt;
  phase, step: Double;
begin
  Result := False;
  numSamples := (SampleRate * DurationMs) div 1000;
  if numSamples < 1 then
    numSamples := 1;
  dataBytes := numSamples * 2; // 16-bit mono
  fs := TFileStream.Create(Path, fmCreate);
  try
    WriteFour(fs, 'RIFF');
    WriteU32(fs, Cardinal(36 + dataBytes));
    WriteFour(fs, 'WAVE');
    WriteFour(fs, 'fmt ');
    WriteU32(fs, 16);
    WriteU16(fs, 1);              // PCM
    WriteU16(fs, 1);              // mono
    WriteU32(fs, SampleRate);
    WriteU32(fs, SampleRate * 2); // byte rate
    WriteU16(fs, 2);              // block align
    WriteU16(fs, 16);             // bits
    WriteFour(fs, 'data');
    WriteU32(fs, Cardinal(dataBytes));
    phase := 0;
    step := 2.0 * Pi * 440.0 / SampleRate;
    for i := 0 to numSamples - 1 do
    begin
      sample := SmallInt(Round(Sin(phase) * 16000));
      fs.WriteBuffer(sample, SizeOf(sample));
      phase := phase + step;
    end;
  finally
    fs.Free;
  end;
  Result := FileExists(Path);
end;

procedure TTtcoreBackendTest.OnErr(Sender: TObject; const Message: string);
begin
  if Sender = nil then ;
  FGotError := True;
  FLastError := Message;
end;

procedure TTtcoreBackendTest.OnDur(Sender: TObject; DurationMs: Int64);
begin
  if Sender = nil then ;
  FLastDuration := DurationMs;
end;

procedure TTtcoreBackendTest.RequireTtcore;
begin
  if not LoadTtcore then
    Fail('ttcore library not loaded: ' + TtcoreLoadError);
end;

procedure WriteTinyPngFile(const Path: string);
const
  Png: array[0..68] of Byte = (
    $89, $50, $4E, $47, $0D, $0A, $1A, $0A,
    $00, $00, $00, $0D, $49, $48, $44, $52,
    $00, $00, $00, $01, $00, $00, $00, $01,
    $08, $02, $00, $00, $00, $90, $77, $53, $DE,
    $00, $00, $00, $0C, $49, $44, $41, $54,
    $08, $D7, $63, $F8, $CF, $C0, $00, $00, $00, $03, $00, $01,
    $8E, $1E, $B0, $0D,
    $00, $00, $00, $00, $49, $45, $4E, $44, $AE, $42, $60, $82
  );
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmCreate);
  try
    fs.WriteBuffer(Png[0], Length(Png));
  finally
    fs.Free;
  end;
end;

procedure TTtcoreBackendTest.WriteTinyPng(const Path: string);
begin
  WriteTinyPngFile(Path);
end;

function TTtcoreBackendTest.ReadAllBytes(const Path: string): TBytes;
var
  fs: TFileStream;
begin
  Result := nil;
  if not FileExists(Path) then
    Exit;
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

function TTtcoreBackendTest.Mp3FixturePath: string;
var
  exeDir, repo: string;
begin
  exeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  Result := ExpandFileName(exeDir + '..' + PathDelim + 'tests' + PathDelim +
    'fixtures' + PathDelim + 'sine.mp3');
  if FileExists(Result) then
    Exit;
  repo := ExpandFileName(exeDir + '..' + PathDelim + '..' + PathDelim);
  Result := IncludeTrailingPathDelimiter(repo) + 'pascal' + PathDelim +
    'tests' + PathDelim + 'fixtures' + PathDelim + 'sine.mp3';
end;

function TTtcoreBackendTest.CopyFileTo(const Src, Dst: string): Boolean;
var
  froms, tos: TFileStream;
begin
  Result := False;
  if not FileExists(Src) then
    Exit;
  froms := TFileStream.Create(Src, fmOpenRead or fmShareDenyWrite);
  try
    tos := TFileStream.Create(Dst, fmCreate);
    try
      tos.CopyFrom(froms, 0);
    finally
      tos.Free;
    end;
  finally
    froms.Free;
  end;
  Result := FileExists(Dst);
end;

procedure TTtcoreBackendTest.SetUp;
begin
  Randomize;
  FGotError := False;
  FLastError := '';
  FLastDuration := -1;
  FExpectedDurationMs := 800;
  FWorkDir := IncludeTrailingPathDelimiter(GetTempDir) +
    'ttcore-fx-' + IntToStr(GetTickCount64) + '-' + IntToStr(Random(MaxInt)) +
    PathDelim;
  ForceDirectories(FWorkDir);
  FWavPath := FWorkDir + 'plain.wav';
  FTaggedPath := FWorkDir + 'tagged.wav';
  FCoverWavPath := FWorkDir + 'withcover.wav';
  FCoverImgPath := FWorkDir + 'withcover.png';
  FMp3Path := FWorkDir + 'tagged.mp3';
  AssertTrue('write wav fixture', WriteFixture(FWavPath, FExpectedDurationMs));
end;

procedure TTtcoreBackendTest.TearDown;
begin
  CheckSynchronize(0);
  if (FWavPath <> '') and FileExists(FWavPath) then
    DeleteFile(FWavPath);
  if (FTaggedPath <> '') and FileExists(FTaggedPath) then
    DeleteFile(FTaggedPath);
  if (FCoverWavPath <> '') and FileExists(FCoverWavPath) then
    DeleteFile(FCoverWavPath);
  if (FCoverImgPath <> '') and FileExists(FCoverImgPath) then
    DeleteFile(FCoverImgPath);
  if (FMp3Path <> '') and FileExists(FMp3Path) then
    DeleteFile(FMp3Path);
  if (FWorkDir <> '') and DirectoryExists(FWorkDir) then
    RemoveDir(FWorkDir);
end;

procedure TTtcoreBackendTest.TestOpenDurationPlayPauseStopSeekVolumeEqSpectrum;
var
  backend: IPlayerBackend;
  dur, pos: Int64;
  bands: array[0..7] of Double;
  wave: array[0..255] of Single;
  i, n: Integer;
begin
  RequireTtcore;
  backend := TTtcoreBackend.Create;
  try
    backend.SetOnError(@OnErr);
    backend.SetOnDurationChanged(@OnDur);
    backend.OpenFile(FWavPath);
    PumpMs(50);
    AssertFalse('open should succeed: ' + FLastError, FGotError);
    dur := backend.GetDurationMs;
    AssertTrue(Format('duration got %d expected ~%d', [dur, FExpectedDurationMs]),
      Abs(dur - FExpectedDurationMs) <= 80);
    if FLastDuration >= 0 then
      AssertTrue('duration callback', Abs(FLastDuration - FExpectedDurationMs) <= 80);

    backend.Play;
    PumpMs(80);
    AssertEquals('playing', Ord(psPlaying), Ord(backend.GetState));

    backend.SetVolume(42);
    AssertEquals('volume', 42, backend.GetVolume);
    backend.SetEqEnabled(True);
    AssertTrue('eq enabled', backend.GetEqEnabled);
    backend.SetEqGain(3, 6.0);
    backend.SetPreamp(-3.0);
    AssertTrue('eq still enabled after gain', backend.GetEqEnabled);

    for i := 0 to High(bands) do
      bands[i] := -999;
    PumpMs(250);
    n := backend.GetSpectrum(@bands[0], Length(bands));
    AssertEquals('spectrum count', Length(bands), n);
    for i := 0 to High(bands) do
    begin
      AssertTrue('spectrum written', bands[i] >= 0);
      AssertTrue('spectrum clamped', bands[i] <= 1.0001);
    end;

    n := backend.GetWaveform(@wave[0], Length(wave));
    AssertTrue('waveform count', n >= 0);
    AssertTrue('waveform not longer than asked', n <= Length(wave));
    for i := 0 to High(wave) do
      AssertTrue('waveform in range', (wave[i] >= -1.5) and (wave[i] <= 1.5));

    backend.Seek(200);
    PumpMs(30);
    pos := backend.GetPositionMs;
    AssertTrue(Format('seek position %d ~ 200', [pos]), Abs(pos - 200) <= 120);

    backend.Pause;
    PumpMs(20);
    AssertEquals('paused', Ord(psPaused), Ord(backend.GetState));

    backend.Stop;
    PumpMs(20);
    AssertEquals('stopped', Ord(psStopped), Ord(backend.GetState));
  finally
    backend := nil;
    CheckSynchronize(0);
  end;
end;

procedure TTtcoreBackendTest.TestMissingPathError;
var
  backend: IPlayerBackend;
begin
  RequireTtcore;
  backend := TTtcoreBackend.Create;
  try
    backend.SetOnError(@OnErr);
    backend.OpenFile('/no/such/ttcore-missing-9f3a2c.wav');
    PumpMs(30);
    AssertTrue('missing path must surface error callback', FGotError);
    AssertTrue('error message not empty', FLastError <> '');
  finally
    backend := nil;
    CheckSynchronize(0);
  end;
end;

procedure TTtcoreBackendTest.TestTaggedMetadataApi;
var
  path: UTF8String;
  title, artist, album: UTF8String;
  meta: TTtcoreMetadata;
  ok: Integer;
begin
  RequireTtcore;
  AssertTrue('write tagged wav', WriteFixture(FTaggedPath, FExpectedDurationMs));
  path := UTF8String(FTaggedPath);
  title := UTF8String('Fixture Title');
  artist := UTF8String('Fixture Artist');
  album := UTF8String('Fixture Album');
  ok := ttcore_write_metadata(PAnsiChar(path), PAnsiChar(title),
    PAnsiChar(artist), PAnsiChar(album));
  AssertEquals('ttcore_write_metadata', 1, ok);
  FillChar(meta, SizeOf(meta), 0);
  ok := ttcore_read_metadata(PAnsiChar(path), meta);
  AssertEquals('ttcore_read_metadata', 1, ok);
  AssertEquals('title', 'Fixture Title', Utf8FromPChar(@meta.Title[0]));
  AssertEquals('artist', 'Fixture Artist', Utf8FromPChar(@meta.Artist[0]));
  AssertEquals('album', 'Fixture Album', Utf8FromPChar(@meta.Album[0]));
  AssertTrue(Format('tagged duration %d', [meta.DurationMs]),
    Abs(meta.DurationMs - FExpectedDurationMs) <= 80);
end;

procedure TTtcoreBackendTest.TestTaggedMp3RemuxMetadata;
var
  src, path, title, artist, album: UTF8String;
  metaBefore, metaAfter: TTtcoreMetadata;
  ok: Integer;
begin
  RequireTtcore;
  src := UTF8String(Mp3FixturePath);
  AssertTrue('mp3 fixture exists: ' + string(src), FileExists(string(src)));
  AssertTrue('copy mp3 fixture', CopyFileTo(string(src), FMp3Path));
  path := UTF8String(FMp3Path);
  FillChar(metaBefore, SizeOf(metaBefore), 0);
  AssertEquals('read mp3 before write', 1,
    ttcore_read_metadata(PAnsiChar(path), metaBefore));
  AssertTrue(Format('mp3 duration before %d', [metaBefore.DurationMs]),
    metaBefore.DurationMs > 200);

  title := UTF8String('Mp3 Title');
  artist := UTF8String('Mp3 Artist');
  album := UTF8String('Mp3 Album');
  ok := ttcore_write_metadata(PAnsiChar(path), PAnsiChar(title),
    PAnsiChar(artist), PAnsiChar(album));
  AssertEquals('ttcore_write_metadata mp3 remux', 1, ok);

  FillChar(metaAfter, SizeOf(metaAfter), 0);
  ok := ttcore_read_metadata(PAnsiChar(path), metaAfter);
  AssertEquals('ttcore_read_metadata mp3', 1, ok);
  AssertEquals('mp3 title', 'Mp3 Title', Utf8FromPChar(@metaAfter.Title[0]));
  AssertEquals('mp3 artist', 'Mp3 Artist', Utf8FromPChar(@metaAfter.Artist[0]));
  AssertEquals('mp3 album', 'Mp3 Album', Utf8FromPChar(@metaAfter.Album[0]));
  AssertTrue(Format('mp3 duration after %d (was %d)',
    [metaAfter.DurationMs, metaBefore.DurationMs]),
    Abs(metaAfter.DurationMs - metaBefore.DurationMs) <= 120);
end;

procedure TTtcoreBackendTest.TestMetadataLoaderFillsPlaylist;
var
  path: UTF8String;
  title, artist, album: UTF8String;
  model: TPlaylistModel;
  loader: TPlaylistMetadataLoader;
  t: QWord;
  e: TPlaylistEntry;
begin
  RequireTtcore;
  AssertTrue('write tagged wav', WriteFixture(FTaggedPath, FExpectedDurationMs));
  path := UTF8String(FTaggedPath);
  title := UTF8String('Loader Title');
  artist := UTF8String('Loader Artist');
  album := UTF8String('Loader Album');
  AssertEquals(1, ttcore_write_metadata(PAnsiChar(path), PAnsiChar(title),
    PAnsiChar(artist), PAnsiChar(album)));

  model := TPlaylistModel.Create;
  loader := TPlaylistMetadataLoader.Create;
  try
    model.AddFile(FTaggedPath);
    AssertFalse(model.Entries[0].MetadataLoaded);
    loader.StartLoading(model);
    t := GetTickCount64;
    while (not loader.IsFinished) and (GetTickCount64 - t < 5000) do
      PumpMs(20);
    PumpMs(50);
    AssertTrue('loader finished', loader.IsFinished);
    e := model.Entries[0];
    AssertTrue('MetadataLoaded', e.MetadataLoaded);
    AssertEquals('loader title', 'Loader Title', e.Title);
    AssertEquals('loader artist', 'Loader Artist', e.Artist);
    AssertEquals('loader album', 'Loader Album', e.Album);
    AssertTrue(Format('loader duration %d', [e.DurationMs]),
      Abs(e.DurationMs - FExpectedDurationMs) <= 80);
  finally
    loader.Free;
    model.Free;
  end;
end;

procedure TTtcoreBackendTest.TestDestroyWhilePlaying;
var
  backend: IPlayerBackend;
  i: Integer;
begin
  RequireTtcore;
  // ttplayer.Destroy nils the backend without Stop; closing during playback
  // must join the SDL thread before cancelling queued Deliver* methods.
  for i := 1 to 8 do
  begin
    backend := TTtcoreBackend.Create;
    backend.SetOnError(@OnErr);
    backend.SetOnDurationChanged(@OnDur);
    backend.OpenFile(FWavPath);
    PumpMs(60);
    AssertEquals(Format('playing before destroy #%d', [i]),
      Ord(psPlaying), Ord(backend.GetState));
    backend := nil;
    PumpMs(40);
  end;
  AssertFalse('destroy while playing: ' + FLastError, FGotError);
end;

procedure TTtcoreBackendTest.TestBalanceRoundTrip;
var
  backend: IPlayerBackend;
begin
  RequireTtcore;
  backend := TTtcoreBackend.Create;
  try
    backend.SetOnError(@OnErr);
    AssertEquals('default balance', 0, backend.GetBalance);
    backend.SetBalance(-100);
    AssertEquals('balance -100', -100, backend.GetBalance);
    backend.SetBalance(100);
    AssertEquals('balance 100', 100, backend.GetBalance);
    backend.OpenFile(FWavPath);
    PumpMs(50);
    AssertFalse('open should succeed: ' + FLastError, FGotError);
    backend.SetBalance(-100);
    AssertEquals('open -100', -100, backend.GetBalance);
    backend.SetBalance(37);
    AssertEquals('open 37', 37, backend.GetBalance);
    backend.SetBalance(0);
    AssertEquals('open 0', 0, backend.GetBalance);
    backend.SetBalance(250);
    AssertEquals('clamped high', 100, backend.GetBalance);
    backend.SetBalance(-250);
    AssertEquals('clamped low', -100, backend.GetBalance);
  finally
    backend := nil;
    CheckSynchronize(0);
  end;
end;

procedure TTtcoreBackendTest.TestCoverSidecarVsAbsent;
var
  backend: IPlayerBackend;
  cover, expected: TBytes;
begin
  RequireTtcore;
  backend := TTtcoreBackend.Create;
  try
    backend.SetOnError(@OnErr);
    backend.OpenFile(FWavPath);
    PumpMs(50);
    AssertFalse('plain open: ' + FLastError, FGotError);
    cover := backend.GetCoverArt;
    AssertEquals('cover-less wav has no cover', 0, Length(cover));

    AssertTrue('write cover wav', WriteFixture(FCoverWavPath, FExpectedDurationMs));
    WriteTinyPng(FCoverImgPath);
    AssertTrue('sidecar png exists', FileExists(FCoverImgPath));
    expected := ReadAllBytes(FCoverImgPath);
    AssertTrue('sidecar png not empty', Length(expected) > 0);

    backend.OpenFile(FCoverWavPath);
    PumpMs(50);
    AssertFalse('cover open: ' + FLastError, FGotError);
    cover := backend.GetCoverArt;
    AssertEquals('sidecar cover size', Length(expected), Length(cover));
    AssertTrue('sidecar cover bytes',
      (Length(cover) > 0) and CompareMem(@cover[0], @expected[0], Length(cover)));

    backend.Stop;
    PumpMs(20);
    cover := backend.GetCoverArt;
    AssertEquals('stop clears cover', 0, Length(cover));
  finally
    backend := nil;
    CheckSynchronize(0);
  end;
end;

procedure TTtcoreBackendTest.TestGettersDuringOpenStop;
var
  backend: IPlayerBackend;
  hammer: TGetterHammer;
  i: Integer;
  title: string;
begin
  RequireTtcore;
  backend := TTtcoreBackend.Create;
  hammer := TGetterHammer.Create(backend);
  try
    backend.SetOnError(@OnErr);
    hammer.Start;
    for i := 1 to 12 do
    begin
      backend.OpenFile(FWavPath);
      PumpMs(40);
      title := backend.GetTitle;
      AssertTrue('title readable during play', title <> '');
      backend.Stop;
      PumpMs(20);
      backend.GetTitle;
      backend.GetCoverArt;
    end;
    hammer.Terminate;
    hammer.WaitFor;
    AssertTrue('hammer iterated', hammer.Iters > 0);
    AssertFalse('open/stop vs getters: ' + FLastError, FGotError);
  finally
    hammer.Terminate;
    hammer.WaitFor;
    hammer.Free;
    backend := nil;
    CheckSynchronize(0);
  end;
end;

procedure TTtcoreBackendTest.TestUnicodePathOpen;
var
  backend: IPlayerBackend;
  dir, dst: string;
begin
  RequireTtcore;
  // U+6B4C U+66F2 = 歌曲, U+6D4B U+8BD5 = 测试 — built from codepoints so the
  // .pas source encoding cannot mangle the path on CP_ACP compilers.
  dir := FWorkDir + PathDelim + UTF8Encode(WideString(WideChar($6B4C)) + WideString(WideChar($66F2)));
  ForceDirectories(dir);
  dst := dir + PathDelim + UTF8Encode(WideString(WideChar($6D4B)) + WideString(WideChar($8BD5))) + '.wav';
  AssertTrue('copy onto unicode path', CopyFileTo(FWavPath, dst));
  backend := TTtcoreBackend.Create;
  try
    backend.SetOnError(@OnErr);
    backend.OpenFile(dst);
    PumpMs(50);
    AssertFalse('unicode open should succeed: ' + FLastError, FGotError);
    AssertTrue('unicode duration', backend.GetDurationMs > 0);
  finally
    backend := nil;
    CheckSynchronize(0);
  end;
end;

initialization
  {$IFDEF UNIX}
  CSetEnv(PAnsiChar('SDL_AUDIODRIVER'), PAnsiChar('dummy'), 1);
  {$ENDIF}
  {$IFDEF WINDOWS}
  SetEnvironmentVariableA(PAnsiChar('SDL_AUDIODRIVER'), PAnsiChar('dummy'));
  {$ENDIF}
  RegisterTest(TTtcoreBackendTest);

end.
