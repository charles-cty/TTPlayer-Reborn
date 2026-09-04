unit ULiveResizeSession;

{$mode objfpc}{$H+}

// 播放列表/歌词窗口的 live 缩放会话：指针每拍都改逻辑尺寸（真·resize）。
// 画面由 Paint 按当前尺寸九宫格重绘，禁止把旧帧整图拉伸（那是放大镜）。
// live 只映射上一帧的 alpha run 以保持圆角；不用矩形 Region。
// 吸附只在松手。不依赖 LCL，FPCUnit 可直接驱动。

interface

uses
  Classes, SysUtils;

const
  kLiveResizeCoalesceUs = 16000; // ~60 Hz

type
  TLiveResizeKind = (
    lrkIdle,
    lrkLiveFill,
    lrkChromeCoalesce,
    lrkCommit
  );

  TLiveResizeDecision = record
    Kind: TLiveResizeKind;
    LogicW, LogicH: Integer;
    SizeChanged: Boolean;
    RebuildNinePatch: Boolean;
    ApplyAlphaShape: Boolean;
    ApplyScaledShape: Boolean;
    ApplyRectRegion: Boolean;
    ApplyResizeSnap: Boolean;
  end;

  TLiveResizeSession = class
  private
    FActive: Boolean;
    FLogicW, FLogicH: Integer;
    FStartW, FStartH: Integer;
    FSampleCount: Integer;
    FChromeRebuildCount: Integer;
    FLiveFillCount: Integer;
    FCommitCount: Integer;
    FLastChromeUs: Int64;
    FLastChromeW, FLastChromeH: Integer;
    FDirty: Boolean;
    FCoalesceUs: Int64;
    FPendingSizeChanged: Boolean;
    function Decide(NowUs: Int64; SizeChanged: Boolean): TLiveResizeDecision;
  public
    constructor Create;
    procedure BeginGesture(StartW, StartH: Integer);
    function Sample(NewW, NewH: Integer; NowUs: Int64): TLiveResizeDecision;
    function Tick(NowUs: Int64): TLiveResizeDecision;
    function Commit(NowUs: Int64): TLiveResizeDecision;
    procedure EndGesture;
    property Active: Boolean read FActive;
    property LogicW: Integer read FLogicW;
    property LogicH: Integer read FLogicH;
    property StartW: Integer read FStartW;
    property StartH: Integer read FStartH;
    property SampleCount: Integer read FSampleCount;
    property ChromeRebuildCount: Integer read FChromeRebuildCount;
    property LiveFillCount: Integer read FLiveFillCount;
    property CommitCount: Integer read FCommitCount;
    property CoalesceIntervalUs: Int64 read FCoalesceUs write FCoalesceUs;
  end;

function EmptyLiveResizeDecision: TLiveResizeDecision;
function LivePaintShouldRebuildChrome(Resizing, FrameMatchesDest: Boolean;
  LastChromeUs, NowUs, IntervalUs: Int64): Boolean;

implementation

function LivePaintShouldRebuildChrome(Resizing, FrameMatchesDest: Boolean;
  LastChromeUs, NowUs, IntervalUs: Int64): Boolean;
begin
  if FrameMatchesDest then
    Exit(False);
  if not Resizing then
    Exit(True);
  if LastChromeUs <= 0 then
    Exit(True);
  if IntervalUs <= 0 then
    Exit(True);
  Result := (NowUs - LastChromeUs) >= IntervalUs;
end;

function EmptyLiveResizeDecision: TLiveResizeDecision;
begin
  Result.Kind := lrkIdle;
  Result.LogicW := 0;
  Result.LogicH := 0;
  Result.SizeChanged := False;
  Result.RebuildNinePatch := False;
  Result.ApplyAlphaShape := False;
  Result.ApplyScaledShape := False;
  Result.ApplyRectRegion := False;
  Result.ApplyResizeSnap := False;
end;

constructor TLiveResizeSession.Create;
begin
  inherited Create;
  FCoalesceUs := kLiveResizeCoalesceUs;
  EndGesture;
end;

procedure TLiveResizeSession.BeginGesture(StartW, StartH: Integer);
begin
  FActive := True;
  FStartW := StartW;
  FStartH := StartH;
  FLogicW := StartW;
  FLogicH := StartH;
  FSampleCount := 0;
  FChromeRebuildCount := 0;
  FLiveFillCount := 0;
  FCommitCount := 0;
  FLastChromeUs := 0;
  FLastChromeW := StartW;
  FLastChromeH := StartH;
  FDirty := True;
  FPendingSizeChanged := True;
end;

function TLiveResizeSession.Decide(NowUs: Int64;
  SizeChanged: Boolean): TLiveResizeDecision;
var
  due, grew: Boolean;
begin
  Result := EmptyLiveResizeDecision;
  Result.LogicW := FLogicW;
  Result.LogicH := FLogicH;
  Result.SizeChanged := SizeChanged;
  if not FActive then Exit;
  if not FDirty then Exit;

  grew := (FLogicW > FLastChromeW) or (FLogicH > FLastChromeH);
  due := (FLastChromeUs = 0) or (NowUs - FLastChromeUs >= FCoalesceUs);
  // Sample 只跟手改 HWND/Region。九宫格在 Paint 里按 coalesce 节流，
  // 避免 SetBounds 同步重绘把鼠标消息堵住。
  if due and (not SizeChanged) and (not grew) then
  begin
    Result.Kind := lrkChromeCoalesce;
    Result.RebuildNinePatch := True;
    Result.ApplyRectRegion := False;
    Result.ApplyScaledShape := False;
    Result.ApplyAlphaShape := True;
    Result.ApplyResizeSnap := False;
    Inc(FChromeRebuildCount);
    FLastChromeUs := NowUs;
    FLastChromeW := FLogicW;
    FLastChromeH := FLogicH;
    FDirty := False;
    FPendingSizeChanged := False;
  end
  else
  begin
    Result.Kind := lrkLiveFill;
    Result.RebuildNinePatch := False;
    Result.ApplyRectRegion := False;
    Result.ApplyScaledShape := SizeChanged or FPendingSizeChanged or grew;
    Result.ApplyAlphaShape := False;
    Result.ApplyResizeSnap := False;
    Inc(FLiveFillCount);
    FPendingSizeChanged := False;
    FDirty := grew or SizeChanged;
  end;
end;

function TLiveResizeSession.Sample(NewW, NewH: Integer;
  NowUs: Int64): TLiveResizeDecision;
var
  sizeChanged: Boolean;
begin
  Result := EmptyLiveResizeDecision;
  if not FActive then Exit;
  sizeChanged := (NewW <> FLogicW) or (NewH <> FLogicH);
  FLogicW := NewW;
  FLogicH := NewH;
  Inc(FSampleCount);
  if sizeChanged then
  begin
    FDirty := True;
    FPendingSizeChanged := True;
  end;
  Result := Decide(NowUs, sizeChanged);
end;

function TLiveResizeSession.Tick(NowUs: Int64): TLiveResizeDecision;
begin
  Result := Decide(NowUs, False);
end;

function TLiveResizeSession.Commit(NowUs: Int64): TLiveResizeDecision;
begin
  Result := EmptyLiveResizeDecision;
  Result.LogicW := FLogicW;
  Result.LogicH := FLogicH;
  if not FActive then Exit;
  Result.Kind := lrkCommit;
  Result.SizeChanged := True;
  Result.RebuildNinePatch := True;
  Result.ApplyAlphaShape := True;
  Result.ApplyScaledShape := False;
  Result.ApplyRectRegion := False;
  Result.ApplyResizeSnap := True;
  Inc(FChromeRebuildCount);
  Inc(FCommitCount);
  FLastChromeUs := NowUs;
  FLastChromeW := FLogicW;
  FLastChromeH := FLogicH;
  FDirty := False;
  FPendingSizeChanged := False;
end;

procedure TLiveResizeSession.EndGesture;
begin
  FActive := False;
  FDirty := False;
  FPendingSizeChanged := False;
end;

end.
