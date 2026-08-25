unit UWinDpiAware;

{$mode objfpc}{$H+}

// 必须排在 program uses 里 Interfaces 之前。
// 打开 Per-Monitor V2：Windows 125/150/200% 下窗口按物理像素排版，
// 由皮肤视图缩放拉伸绘制，避免 DWM 把 96dpi 窗拉糊。

interface

procedure EnablePerMonitorDpiAwareness;

implementation

{$IFDEF WINDOWS}
uses
  Windows, ActiveX;

const
  DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = HANDLE(-4);
  PROCESS_PER_MONITOR_DPI_AWARE = 2;

type
  TSetProcessDpiAwarenessContext = function(Value: HANDLE): BOOL; stdcall;
  TSetProcessDpiAwareness = function(Value: LongInt): HRESULT; stdcall;
  TSetProcessDPIAware = function: BOOL; stdcall;
{$ENDIF}

procedure EnablePerMonitorDpiAwareness;
{$IFDEF WINDOWS}
var
  hUser, hShcore: HMODULE;
  fnCtx: TSetProcessDpiAwarenessContext;
  fnAwareness: TSetProcessDpiAwareness;
  fnOld: TSetProcessDPIAware;
{$ENDIF}
begin
{$IFDEF WINDOWS}
  hUser := GetModuleHandle('user32.dll');
  if hUser <> 0 then
  begin
    fnCtx := TSetProcessDpiAwarenessContext(
      GetProcAddress(hUser, 'SetProcessDpiAwarenessContext'));
    if Assigned(fnCtx) then
      if fnCtx(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) then
        Exit;
  end;
  hShcore := LoadLibrary('shcore.dll');
  if hShcore <> 0 then
  begin
    fnAwareness := TSetProcessDpiAwareness(
      GetProcAddress(hShcore, 'SetProcessDpiAwareness'));
    if Assigned(fnAwareness) then
    begin
      fnAwareness(PROCESS_PER_MONITOR_DPI_AWARE);
      Exit;
    end;
  end;
  if hUser <> 0 then
  begin
    fnOld := TSetProcessDPIAware(GetProcAddress(hUser, 'SetProcessDPIAware'));
    if Assigned(fnOld) then
      fnOld();
  end;
{$ENDIF}
end;

initialization
  EnablePerMonitorDpiAwareness;
{$IFDEF WINDOWS}
  // Qt's QApplication does this; WASAPI/SDL enumerate COM MMDevices on the
  // thread that opens the audio device. LCL may OleInitialize later — extra
  // init returns S_FALSE.
  OleInitialize(nil);
{$ENDIF}

end.
