unit UUiPerf;

{$mode objfpc}{$H+}

// 单调时钟，给 live 缩放合帧用。

interface

uses
  SysUtils;

function UiNowUs: Int64;

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

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

end.
