unit UTracy;

{$mode objfpc}{$H+}

interface

type
  TTracyZone = QWord;

function TracyZoneBegin(const Name: PAnsiChar): TTracyZone; inline;
procedure TracyZoneEnd(Zone: TTracyZone); inline;
procedure TracyFrameStart(const Name: PAnsiChar); inline;
procedure TracyFrameEnd(const Name: PAnsiChar); inline;

implementation

{$if defined(MSWINDOWS) and defined(ENABLE_TRACY)}
uses Windows, SysUtils;

type
  TZoneBegin = function(Name: PAnsiChar): TTracyZone; cdecl;
  TZoneEnd = procedure(Zone: TTracyZone); cdecl;
  TFrame = procedure(Name: PAnsiChar); cdecl;

var
  TracyModule: HMODULE = 0;
  LoadAttempted: Boolean = False;
  ZoneBeginProc: TZoneBegin = nil;
  ZoneEndProc: TZoneEnd = nil;
  FrameStartProc: TFrame = nil;
  FrameEndProc: TFrame = nil;

procedure EnsureTracy;
begin
  if LoadAttempted then Exit;
  LoadAttempted := True;
  TracyModule := LoadLibrary(PChar(ExtractFilePath(ExpandFileName(ParamStr(0))) +
    'tttracy.dll'));
  if TracyModule = 0 then Exit;
  Pointer(ZoneBeginProc) := GetProcAddress(TracyModule, 'tt_tracy_zone_begin_v2');
  Pointer(ZoneEndProc) := GetProcAddress(TracyModule, 'tt_tracy_zone_end_v2');
  Pointer(FrameStartProc) := GetProcAddress(TracyModule, 'tt_tracy_frame_start');
  Pointer(FrameEndProc) := GetProcAddress(TracyModule, 'tt_tracy_frame_end');
  if not (Assigned(ZoneBeginProc) and Assigned(ZoneEndProc) and
    Assigned(FrameStartProc) and Assigned(FrameEndProc)) then
  begin
    ZoneBeginProc := nil;
    ZoneEndProc := nil;
    FrameStartProc := nil;
    FrameEndProc := nil;
    OutputDebugString('TTPlayer: incompatible tttracy.dll; rebuild the Tracy shim.');
    Exit;
  end;
end;
{$endif}

function TracyZoneBegin(const Name: PAnsiChar): TTracyZone;
begin
  Result := 0;
  {$if defined(MSWINDOWS) and defined(ENABLE_TRACY)}
  EnsureTracy;
  if Assigned(ZoneBeginProc) then Result := ZoneBeginProc(Name);
  {$endif}
end;

procedure TracyZoneEnd(Zone: TTracyZone);
begin
  {$if defined(MSWINDOWS) and defined(ENABLE_TRACY)}
  if Assigned(ZoneEndProc) then ZoneEndProc(Zone);
  {$endif}
end;

procedure TracyFrameStart(const Name: PAnsiChar);
begin
  {$if defined(MSWINDOWS) and defined(ENABLE_TRACY)}
  EnsureTracy;
  if Assigned(FrameStartProc) then FrameStartProc(Name);
  {$endif}
end;

procedure TracyFrameEnd(const Name: PAnsiChar);
begin
  {$if defined(MSWINDOWS) and defined(ENABLE_TRACY)}
  EnsureTracy;
  if Assigned(FrameEndProc) then FrameEndProc(Name);
  {$endif}
end;

end.
