unit UUiPerf;

{$mode objfpc}{$H+}

// 缩放/拖曳/吸附阶段计时。名字与 WPR 区间、zoom-phases.log 列一致。
// Windows 用 QueryPerformanceCounter；其它平台用 gettimeofday。

interface

uses
  Classes, SysUtils;

const
  kUiPhaseNinePatch  = 'nine_patch';
  kUiPhaseAlphaShape = 'alpha_shape';
  kUiPhaseLiveFill   = 'live_fill';
  kUiPhaseRectRegion = 'rect_region';
  kUiPhaseSnapGraph  = 'snap_graph';
  kUiPhaseSetBounds  = 'set_bounds';

type
  TUiPhaseStats = record
    Name: string;
    Count: Integer;
    TotalUs: Int64;
    MaxUs: Int64;
  end;

  TUiPhaseLog = class
  private
    FNames: array of string;
    FCount: array of Integer;
    FTotal: array of Int64;
    FMax: array of Int64;
    FOpenName: string;
    FOpenUs: Int64;
    function IndexOfName(const AName: string): Integer;
    function EnsureName(const AName: string): Integer;
  public
    procedure Clear;
    procedure BeginPhase(const AName: string);
    procedure EndPhase;
    procedure Add(const AName: string; ElapsedUs: Int64);
    function PhaseCount: Integer;
    function Stats(Index: Integer): TUiPhaseStats;
    function CountOf(const AName: string): Integer;
    function TotalUsOf(const AName: string): Int64;
    function DumpText: string;
    procedure DumpToFile(const Path: string);
  end;

function UiNowUs: Int64;
function SharedUiPhaseLog: TUiPhaseLog;
procedure UiPhaseBegin(const AName: string);
procedure UiPhaseEnd;

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

var
  GLog: TUiPhaseLog = nil;

function UiNowUs: Int64;
{$IFDEF WINDOWS}
var
  counter, freq: Int64;
begin
  if (not QueryPerformanceFrequency(freq)) or (freq <= 0) then
    Exit(Int64(GetTickCount64) * 1000);
  QueryPerformanceCounter(counter);
  Result := (counter * 1000000) div freq;
end;
{$ELSE}
begin
  Result := Int64(GetTickCount64) * 1000;
end;
{$ENDIF}

function SharedUiPhaseLog: TUiPhaseLog;
begin
  if GLog = nil then
    GLog := TUiPhaseLog.Create;
  Result := GLog;
end;

procedure UiPhaseBegin(const AName: string);
begin
  SharedUiPhaseLog.BeginPhase(AName);
end;

procedure UiPhaseEnd;
begin
  SharedUiPhaseLog.EndPhase;
end;

function TUiPhaseLog.IndexOfName(const AName: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FNames) do
    if FNames[i] = AName then
      Exit(i);
  Result := -1;
end;

function TUiPhaseLog.EnsureName(const AName: string): Integer;
begin
  Result := IndexOfName(AName);
  if Result >= 0 then Exit;
  Result := Length(FNames);
  SetLength(FNames, Result + 1);
  SetLength(FCount, Result + 1);
  SetLength(FTotal, Result + 1);
  SetLength(FMax, Result + 1);
  FNames[Result] := AName;
  FCount[Result] := 0;
  FTotal[Result] := 0;
  FMax[Result] := 0;
end;

procedure TUiPhaseLog.Clear;
begin
  SetLength(FNames, 0);
  SetLength(FCount, 0);
  SetLength(FTotal, 0);
  SetLength(FMax, 0);
  FOpenName := '';
  FOpenUs := 0;
end;

procedure TUiPhaseLog.BeginPhase(const AName: string);
begin
  if FOpenName <> '' then
    EndPhase;
  FOpenName := AName;
  FOpenUs := UiNowUs;
end;

procedure TUiPhaseLog.EndPhase;
var
  elapsed: Int64;
  name: string;
begin
  if FOpenName = '' then Exit;
  elapsed := UiNowUs - FOpenUs;
  if elapsed < 0 then elapsed := 0;
  name := FOpenName;
  FOpenName := '';
  Add(name, elapsed);
end;

procedure TUiPhaseLog.Add(const AName: string; ElapsedUs: Int64);
var
  i: Integer;
begin
  i := EnsureName(AName);
  Inc(FCount[i]);
  Inc(FTotal[i], ElapsedUs);
  if ElapsedUs > FMax[i] then
    FMax[i] := ElapsedUs;
end;

function TUiPhaseLog.PhaseCount: Integer;
begin
  Result := Length(FNames);
end;

function TUiPhaseLog.Stats(Index: Integer): TUiPhaseStats;
begin
  Result.Name := '';
  Result.Count := 0;
  Result.TotalUs := 0;
  Result.MaxUs := 0;
  if (Index < 0) or (Index > High(FNames)) then Exit;
  Result.Name := FNames[Index];
  Result.Count := FCount[Index];
  Result.TotalUs := FTotal[Index];
  Result.MaxUs := FMax[Index];
end;

function TUiPhaseLog.CountOf(const AName: string): Integer;
var
  i: Integer;
begin
  i := IndexOfName(AName);
  if i < 0 then Exit(0);
  Result := FCount[i];
end;

function TUiPhaseLog.TotalUsOf(const AName: string): Int64;
var
  i: Integer;
begin
  i := IndexOfName(AName);
  if i < 0 then Exit(0);
  Result := FTotal[i];
end;

function TUiPhaseLog.DumpText: string;
var
  i: Integer;
  sl: TStringList;
  st: TUiPhaseStats;
begin
  sl := TStringList.Create;
  try
    sl.Add('# zoom-phases');
    sl.Add('phase' + #9 + 'count' + #9 + 'total_us' + #9 + 'max_us');
    for i := 0 to PhaseCount - 1 do
    begin
      st := Stats(i);
      sl.Add(Format('%s' + #9 + '%d' + #9 + '%d' + #9 + '%d',
        [st.Name, st.Count, st.TotalUs, st.MaxUs]));
    end;
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

procedure TUiPhaseLog.DumpToFile(const Path: string);
var
  sl: TStringList;
begin
  if Path = '' then Exit;
  sl := TStringList.Create;
  try
    sl.Text := DumpText;
    sl.SaveToFile(Path);
  finally
    sl.Free;
  end;
end;

initialization

finalization
  FreeAndNil(GLog);

end.
