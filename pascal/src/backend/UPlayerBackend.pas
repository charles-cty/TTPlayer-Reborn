unit UPlayerBackend;

{$mode objfpc}{$H+}

// 播放后端接口 + 桩实现，供 GUI 开发阶段使用（不依赖真实音频核心）。
//
// IPlayerBackend 定义了 PlayerWindow / EqualizerWindow 等 UI 单元
// 所需的全部播放控制接口。TStubBackend 用定时器模拟进度，
// 用固定频谱数据驱动 VisualWidget，使界面开发与音频实现完全解耦。
// 最终用 ttcore FFI 实现替换时，UI 层无需改动。

interface

uses
  Classes, SysUtils, ExtCtrls;

type
  TPlayerState = (psIdle, psPlaying, psPaused, psStopped);

  // 后端状态回调类型（从主线程调用，不存在线程安全问题）。
  TStateChangedEvent = procedure(Sender: TObject; NewState: TPlayerState) of object;
  TPositionChangedEvent = procedure(Sender: TObject; PositionMs: Int64) of object;
  TDurationChangedEvent = procedure(Sender: TObject; DurationMs: Int64) of object;
  TTrackFinishedEvent = procedure(Sender: TObject) of object;

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

    // 元数据（当前曲目）
    function GetTitle: string;
    function GetArtist: string;
    function GetAlbum: string;

    // 频谱数据（主线程拉取，由 VisualWidget 使用）
    // BandCount 为请求的频段数，写入 OutBands 数组，返回实际写入的数量。
    function GetSpectrum(OutBands: PDouble; BandCount: Integer): Integer;

    // 事件注册（各 UI 组件注册自己的回调）
    procedure SetOnStateChanged(Handler: TStateChangedEvent);
    procedure SetOnPositionChanged(Handler: TPositionChangedEvent);
    procedure SetOnDurationChanged(Handler: TDurationChangedEvent);
    procedure SetOnTrackFinished(Handler: TTrackFinishedEvent);
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
    FTimer: TTimer;
    FOnStateChanged: TStateChangedEvent;
    FOnPositionChanged: TPositionChangedEvent;
    FOnDurationChanged: TDurationChangedEvent;
    FOnTrackFinished: TTrackFinishedEvent;
    FSpectrumPhase: Double;  // 用于生成逼真的假频谱动画

    procedure TimerTick(Sender: TObject);
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
    function GetTitle: string;
    function GetArtist: string;
    function GetAlbum: string;
    function GetSpectrum(OutBands: PDouble; BandCount: Integer): Integer;
    procedure SetOnStateChanged(Handler: TStateChangedEvent);
    procedure SetOnPositionChanged(Handler: TPositionChangedEvent);
    procedure SetOnDurationChanged(Handler: TDurationChangedEvent);
    procedure SetOnTrackFinished(Handler: TTrackFinishedEvent);
  end;

implementation

uses
  Math;

constructor TStubBackend.Create;
begin
  inherited Create;
  FState := psIdle;
  FPositionMs := 0;
  FDurationMs := 3 * 60 * 1000;  // 默认假曲目时长 3 分钟
  FVolume := 100;
  FMuted := False;
  FSpectrumPhase := 0;

  FTimer := TTimer.Create(nil);
  FTimer.Interval := 100;  // 100ms 更新，约 10fps 进度更新
  FTimer.Enabled := False;
  FTimer.OnTimer := @TimerTick;
end;

destructor TStubBackend.Destroy;
begin
  FTimer.Free;
  inherited Destroy;
end;

procedure TStubBackend.TimerTick(Sender: TObject);
begin
  if FState <> psPlaying then Exit;

  Inc(FPositionMs, 100);
  FSpectrumPhase := FSpectrumPhase + 0.15;

  if FPositionMs >= FDurationMs then
  begin
    FPositionMs := FDurationMs;
    FState := psStopped;
    EmitState;
    FTimer.Enabled := False;
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
    FTimer.Enabled := True;
    EmitState;
  end;
end;

procedure TStubBackend.Pause;
begin
  if FState = psPlaying then
  begin
    FState := psPaused;
    FTimer.Enabled := False;
    EmitState;
  end;
end;

procedure TStubBackend.Stop;
begin
  FState := psStopped;
  FTimer.Enabled := False;
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

end.
