unit UPlayerBackend;

{$mode objfpc}{$H+}

// 播放后端接口 + 桩实现。
//
// IPlayerBackend 定义了 PlayerForm / EqualizerForm 等 UI 单元所需的播放控制。
// TStubBackend 用定时器假进度，供 skinpreview / GUI 测试使用（不加载真实音频）。
// ttplayer 使用 UTtcoreBackend（ttcore C ABI FFI）。

interface

uses
  Classes, SysUtils;

type
  TPlayerState = (psIdle, psPlaying, psPaused, psStopped);

  // 后端状态回调类型（从主线程调用，不存在线程安全问题）。
  TStateChangedEvent = procedure(Sender: TObject; NewState: TPlayerState) of object;
  TPositionChangedEvent = procedure(Sender: TObject; PositionMs: Int64) of object;
  TDurationChangedEvent = procedure(Sender: TObject; DurationMs: Int64) of object;
  TTrackFinishedEvent = procedure(Sender: TObject) of object;
  TErrorEvent = procedure(Sender: TObject; const Message: string) of object;

  IPlayerBackend = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    // 播放控制
    procedure OpenFile(const FilePath: string);
    procedure Play;
    procedure Pause;
    procedure Stop;
    procedure Seek(PositionMs: Int64);

    // 状态查询
    function GetState: TPlayerState;
    function GetPositionMs: Int64;
    function GetDurationMs: Int64;
    function GetVolume: Integer;      // 0-100
    function GetIsMuted: Boolean;

    // 设置
    procedure SetVolume(Vol: Integer);
    procedure SetMuted(Muted: Boolean);
    procedure SetEqGain(Band: Integer; GainDb: Double);  // Band 0-9
    procedure SetPreamp(GainDb: Double);
    procedure SetEqEnabled(Enabled: Boolean);
    function GetEqEnabled: Boolean;
    procedure SetBalance(Value: Integer);  // -100..+100
    function GetBalance: Integer;

    // 元数据（当前曲目）
    function GetTitle: string;
    function GetArtist: string;
    function GetAlbum: string;
    function GetCoverArt: TBytes;

    // 频谱数据（主线程拉取，由 VisualWidget 使用）
    // BandCount 为请求的频段数，写入 OutBands 数组，返回实际写入的数量。
    function GetSpectrum(OutBands: PDouble; BandCount: Integer): Integer;

    // 事件注册（各 UI 组件注册自己的回调）
    procedure SetOnStateChanged(Handler: TStateChangedEvent);
    procedure SetOnPositionChanged(Handler: TPositionChangedEvent);
    procedure SetOnDurationChanged(Handler: TDurationChangedEvent);
    procedure SetOnTrackFinished(Handler: TTrackFinishedEvent);
    procedure SetOnError(Handler: TErrorEvent);
  end;

  // 桩实现：定时器假进度、固定频谱数据。
  // Volume 默认 100，初始状态 psIdle。
  TStubBackend = class(TInterfacedObject, IPlayerBackend)
  private
    FState: TPlayerState;
    FPositionMs: Int64;
    FDurationMs: Int64;
    FVolume: Integer;
    FMuted: Boolean;
    FEqGains: array[0..9] of Double;
    FPreamp: Double;
    FBalance: Integer;
    FEqEnabled: Boolean;
    FTicker: TThread;
    FTickEnabled: Boolean;
    FOnStateChanged: TStateChangedEvent;
    FOnPositionChanged: TPositionChangedEvent;
    FOnDurationChanged: TDurationChangedEvent;
    FOnTrackFinished: TTrackFinishedEvent;
    FOnError: TErrorEvent;
    FSpectrumPhase: Double;  // 用于生成逼真的假频谱动画

    procedure TimerTick;
    procedure SetTickEnabled(Enabled: Boolean);
    procedure EmitState;
    procedure EmitPosition;
    procedure EmitDuration;
  public
    constructor Create;
    destructor Destroy; override;

    // IPlayerBackend
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

uses
  Math;

type
  TStubTicker = class(TThread)
  private
    FOwner: TStubBackend;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TStubBackend);
  end;

constructor TStubTicker.Create(AOwner: TStubBackend);
begin
  inherited Create(True);
  FOwner := AOwner;
  FreeOnTerminate := False;
end;

procedure TStubTicker.Execute;
begin
  while not Terminated do
  begin
    Sleep(100);
    if Terminated then
      Break;
    if FOwner.FTickEnabled then
      TThread.Queue(nil, @FOwner.TimerTick);
  end;
end;

constructor TStubBackend.Create;
begin
  inherited Create;
  FState := psIdle;
  FPositionMs := 0;
  FDurationMs := 3 * 60 * 1000;  // 默认假曲目时长 3 分钟
  FVolume := 100;
  FMuted := False;
  FEqEnabled := False;
  FBalance := 0;
  FSpectrumPhase := 0;
  FTickEnabled := False;
  FTicker := TStubTicker.Create(Self);
  FTicker.Start;
end;

destructor TStubBackend.Destroy;
begin
  FTickEnabled := False;
  if FTicker <> nil then
  begin
    FTicker.Terminate;
    FTicker.WaitFor;
    FreeAndNil(FTicker);
  end;
  TThread.RemoveQueuedEvents(@TimerTick);
  inherited Destroy;
end;

procedure TStubBackend.SetTickEnabled(Enabled: Boolean);
begin
  FTickEnabled := Enabled;
end;

procedure TStubBackend.TimerTick;
begin
  if FState <> psPlaying then Exit;

  Inc(FPositionMs, 100);
  FSpectrumPhase := FSpectrumPhase + 0.15;

  if FPositionMs >= FDurationMs then
  begin
    FPositionMs := FDurationMs;
    FState := psStopped;
    EmitState;
    SetTickEnabled(False);
    if Assigned(FOnTrackFinished) then
      FOnTrackFinished(Self);
    Exit;
  end;

  EmitPosition;
end;

procedure TStubBackend.EmitState;
begin
  if Assigned(FOnStateChanged) then
    FOnStateChanged(Self, FState);
end;

procedure TStubBackend.EmitPosition;
begin
  if Assigned(FOnPositionChanged) then
    FOnPositionChanged(Self, FPositionMs);
end;

procedure TStubBackend.EmitDuration;
begin
  if Assigned(FOnDurationChanged) then
    FOnDurationChanged(Self, FDurationMs);
end;

procedure TStubBackend.OpenFile(const FilePath: string);
begin
  FPositionMs := 0;
  FDurationMs := 3 * 60 * 1000;
  FState := psIdle;
  EmitDuration;
  EmitPosition;
  // 桩：立即开始"播放"
  Play;
end;

procedure TStubBackend.Play;
begin
  if FState <> psPlaying then
  begin
    FState := psPlaying;
    SetTickEnabled(True);
    EmitState;
  end;
end;

procedure TStubBackend.Pause;
begin
  if FState = psPlaying then
  begin
    FState := psPaused;
    SetTickEnabled(False);
    EmitState;
  end;
end;

procedure TStubBackend.Stop;
begin
  FState := psStopped;
  SetTickEnabled(False);
  FPositionMs := 0;
  EmitState;
  EmitPosition;
end;

procedure TStubBackend.Seek(PositionMs: Int64);
begin
  FPositionMs := PositionMs;
  if FPositionMs < 0 then FPositionMs := 0;
  if FPositionMs > FDurationMs then FPositionMs := FDurationMs;
  EmitPosition;
end;

function TStubBackend.GetState: TPlayerState;
begin
  Result := FState;
end;

function TStubBackend.GetPositionMs: Int64;
begin
  Result := FPositionMs;
end;

function TStubBackend.GetDurationMs: Int64;
begin
  Result := FDurationMs;
end;

function TStubBackend.GetVolume: Integer;
begin
  Result := FVolume;
end;

function TStubBackend.GetIsMuted: Boolean;
begin
  Result := FMuted;
end;

procedure TStubBackend.SetVolume(Vol: Integer);
begin
  if Vol < 0 then Vol := 0;
  if Vol > 100 then Vol := 100;
  FVolume := Vol;
end;

procedure TStubBackend.SetMuted(Muted: Boolean);
begin
  FMuted := Muted;
end;

procedure TStubBackend.SetEqGain(Band: Integer; GainDb: Double);
begin
  if (Band >= 0) and (Band <= 9) then
    FEqGains[Band] := GainDb;
end;

procedure TStubBackend.SetPreamp(GainDb: Double);
begin
  FPreamp := GainDb;
end;

procedure TStubBackend.SetEqEnabled(Enabled: Boolean);
begin
  FEqEnabled := Enabled;
end;

function TStubBackend.GetEqEnabled: Boolean;
begin
  Result := FEqEnabled;
end;

procedure TStubBackend.SetBalance(Value: Integer);
begin
  if Value < -100 then Value := -100;
  if Value > 100 then Value := 100;
  FBalance := Value;
end;

function TStubBackend.GetBalance: Integer;
begin
  Result := FBalance;
end;

function TStubBackend.GetTitle: string;
begin
  Result := 'TTPlayer Reborn';
end;

function TStubBackend.GetArtist: string;
begin
  Result := '';
end;

function TStubBackend.GetAlbum: string;
begin
  Result := '';
end;

function TStubBackend.GetCoverArt: TBytes;
begin
  Result := nil;
end;

// 生成逼真的假频谱：低频大、高频衰减，叠加缓慢动画相位。
function TStubBackend.GetSpectrum(OutBands: PDouble; BandCount: Integer): Integer;
var
  i: Integer;
  base, anim: Double;
begin
  if (OutBands = nil) or (BandCount <= 0) then Exit(0);
  for i := 0 to BandCount - 1 do
  begin
    // 低频到高频的基础形状（1.0 在最低频，0.1 在最高频）
    base := 1.0 - (i / (BandCount - 1)) * 0.9;
    // 慢速正弦动画，各频段错落
    anim := Sin(FSpectrumPhase + i * 0.5) * 0.3 + 0.7;
    OutBands[i] := base * anim;
    if OutBands[i] < 0 then OutBands[i] := 0;
    if OutBands[i] > 1 then OutBands[i] := 1;
  end;
  Result := BandCount;
end;

procedure TStubBackend.SetOnStateChanged(Handler: TStateChangedEvent);
begin
  FOnStateChanged := Handler;
end;

procedure TStubBackend.SetOnPositionChanged(Handler: TPositionChangedEvent);
begin
  FOnPositionChanged := Handler;
end;

procedure TStubBackend.SetOnDurationChanged(Handler: TDurationChangedEvent);
begin
  FOnDurationChanged := Handler;
end;

procedure TStubBackend.SetOnTrackFinished(Handler: TTrackFinishedEvent);
begin
  FOnTrackFinished := Handler;
end;

procedure TStubBackend.SetOnError(Handler: TErrorEvent);
begin
  FOnError := Handler;
end;

end.
