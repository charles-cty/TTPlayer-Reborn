unit UTestSpectrumAnalyze;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, fpcunit, testregistry, USpectrumAnalyze;

type
  TSpectrumAnalyzeTest = class(TTestCase)
  published
    procedure TestSilenceIsZero;
    procedure TestLowFreqPeaksBeforeHighFreq;
    procedure TestNilAndEmptyInputs;
  end;

implementation

procedure FillSine(var Buf: array of Single; Freq, Rate: Double);
var
  i: Integer;
begin
  for i := 0 to High(Buf) do
    Buf[i] := Sin(2.0 * Pi * Freq * i / Rate);
end;

function PeakIndex(const Bands: array of Double): Integer;
var
  i: Integer;
  m: Double;
begin
  Result := 0;
  m := Bands[0];
  for i := 1 to High(Bands) do
    if Bands[i] > m then
    begin
      m := Bands[i];
      Result := i;
    end;
end;

function MaxBand(const Bands: array of Double): Double;
var
  i: Integer;
begin
  Result := Bands[0];
  for i := 1 to High(Bands) do
    if Bands[i] > Result then
      Result := Bands[i];
end;

procedure TSpectrumAnalyzeTest.TestSilenceIsZero;
var
  raw: array[0..1023] of Single;
  bands: array[0..15] of Double;
  i: Integer;
begin
  FillChar(raw, SizeOf(raw), 0);
  ComputeSpectrumBands(@raw[0], Length(raw), @bands[0], Length(bands));
  for i := 0 to High(bands) do
    AssertTrue(Format('silence band %d = %f', [i, bands[i]]), Abs(bands[i]) < 1e-6);
end;

procedure TSpectrumAnalyzeTest.TestLowFreqPeaksBeforeHighFreq;
var
  raw: array[0..1023] of Single;
  lowBands, highBands: array[0..23] of Double;
  lowPeak, highPeak: Integer;
begin
  FillSine(raw, 440, 44100);
  ComputeSpectrumBands(@raw[0], Length(raw), @lowBands[0], Length(lowBands));
  FillSine(raw, 8000, 44100);
  ComputeSpectrumBands(@raw[0], Length(raw), @highBands[0], Length(highBands));

  AssertTrue('440Hz energy', MaxBand(lowBands) > 0.05);
  AssertTrue('8000Hz energy', MaxBand(highBands) > 0.05);
  lowPeak := PeakIndex(lowBands);
  highPeak := PeakIndex(highBands);
  AssertTrue(Format('440Hz peak %d before 8000Hz peak %d', [lowPeak, highPeak]),
    lowPeak < highPeak);
end;

procedure TSpectrumAnalyzeTest.TestNilAndEmptyInputs;
var
  bands: array[0..7] of Double;
  i: Integer;
begin
  for i := 0 to High(bands) do
    bands[i] := 99;
  ComputeSpectrumBands(nil, 1024, @bands[0], Length(bands));
  for i := 0 to High(bands) do
    AssertTrue(Format('nil raw zeros band %d', [i]), Abs(bands[i]) < 1e-12);

  for i := 0 to High(bands) do
    bands[i] := 99;
  ComputeSpectrumBands(nil, 0, @bands[0], Length(bands));
  for i := 0 to High(bands) do
    AssertTrue(Format('empty count zeros band %d', [i]), Abs(bands[i]) < 1e-12);

  ComputeSpectrumBands(nil, 0, nil, 8);
end;

initialization
  RegisterTest(TSpectrumAnalyzeTest);

end.
