unit UHeapTraceConfig;

{$mode objfpc}{$H+}

// HeapTrc runtime settings for -gh / ENABLE_HEAPTRC builds.
//
// Compile with UseHeaptrc (-gh) and -dENABLE_HEAPTRC so heaptrc is the first
// unit (inserted by the compiler) and HaltOnError / output file are applied.
// Default dump path is <exe>.heaptrc next to the binary; override with
// HEAPTRACEFILE. Set HEAPTRC_KEEP_RELEASED=1 to never reuse freed Pascal
// blocks (UAF becomes a deterministic invalid-pointer halt).

interface

procedure ApplyHeapTraceSettings;

implementation

uses
{$IFDEF ENABLE_HEAPTRC}
  heaptrc,
{$ENDIF}
  SysUtils;

procedure ApplyHeapTraceSettings;
{$IFDEF ENABLE_HEAPTRC}
var
  path, keep: string;
{$ENDIF}
begin
{$IFDEF ENABLE_HEAPTRC}
  HaltOnError := True;
  keep := GetEnvironmentVariable('HEAPTRC_KEEP_RELEASED');
  KeepReleased := (keep = '1') or SameText(keep, 'true') or SameText(keep, 'yes');
  path := GetEnvironmentVariable('HEAPTRACEFILE');
  if path = '' then
    path := ChangeFileExt(ParamStr(0), '.heaptrc');
  if path <> '' then
    SetHeapTraceOutput(path);
{$ENDIF}
end;

initialization
  // First unit in ttplayer/tests: force UTF-8 so Chinese paths stay UTF-8
  // when passed to ttcore (FFmpeg CreateFileW / avformat). Without this,
  // FPC treats string as CP_ACP on Windows and UTF8String() mangles them.
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  ApplyHeapTraceSettings;

end.
