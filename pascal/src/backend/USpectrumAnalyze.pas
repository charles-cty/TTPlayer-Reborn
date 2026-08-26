unit USpectrumAnalyze;

{$mode objfpc}{$H+}

// Log-spaced Goertzel bands from left-channel PCM. Matches Qt
// VisualComputeWorker in src/ui/VisualWidget.cpp.

interface

procedure ComputeSpectrumBands(Raw: PSingle; RawCount: Integer;
  OutBands: PDouble; BandCount: Integer);

implementation

uses
  Math;

function GoertzelMagnitude(Raw: PSingle; SampleCount, StartBin, EndBin: Integer): Single;
var
  bin, i, used: Integer;
  omega, coeff, q0, q1, q2, re, im, total, cs, sn: Single;
begin
  Result := 0;
  if (Raw = nil) or (SampleCount <= 0) or (StartBin > EndBin) then
    Exit;
  total := 0;
  used := 0;
  for bin := StartBin to EndBin do
  begin
    if (bin <= 0) or (bin >= SampleCount div 2) then
      Continue;
    omega := 2.0 * Pi * bin / SampleCount;
    coeff := 2.0 * Cos(omega);
    cs := Cos(omega);
    sn := Sin(omega);
    q0 := 0;
    q1 := 0;
    q2 := 0;
    for i := 0 to SampleCount - 1 do
    begin
      q0 := coeff * q1 - q2 + Raw[i];
      q2 := q1;
      q1 := q0;
    end;
    re := q1 - q2 * cs;
    im := q2 * sn;
    total := total + Sqrt(re * re + im * im) / SampleCount;
    Inc(used);
  end;
  if used > 0 then
    Result := total / used;
end;

procedure ComputeSpectrumBands(Raw: PSingle; RawCount: Integer;
  OutBands: PDouble; BandCount: Integer);
var
  i, maxBin, startBin, endBin: Integer;
  startRatio, endRatio, energy: Double;
begin
  if (OutBands = nil) or (BandCount <= 0) then
    Exit;
  for i := 0 to BandCount - 1 do
    OutBands[i] := 0;
  if (Raw = nil) or (RawCount <= 0) then
    Exit;
  maxBin := RawCount div 2 - 1;
  if maxBin <= 0 then
    Exit;
  for i := 0 to BandCount - 1 do
  begin
    startRatio := i / BandCount;
    endRatio := (i + 1) / BandCount;
    startBin := Max(1, Trunc(Power(maxBin, startRatio)));
    endBin := Max(startBin, Trunc(Power(maxBin, endRatio)));
    energy := GoertzelMagnitude(Raw, RawCount, startBin, endBin);
    energy := Sqrt(energy) * 6.0;
    if energy < 0 then
      energy := 0;
    if energy > 1 then
      energy := 1;
    OutBands[i] := energy;
  end;
end;

end.
