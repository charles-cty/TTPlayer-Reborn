program ttplayer;

{$mode objfpc}{$H+}

// 主播放器入口。宿主 TTtplayerHost 负责 TTPlayer.xml、托盘与四个窗口。

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  UHeapTraceConfig,
  UGdkX11Backend,
  UWinDpiAware,
  Interfaces,
  Forms,
  UTtplayerHost;

var
  TheApp: TTtplayerHost;
begin
  RequireDerivedFormResource := False;  // 纯代码窗口，无 .lfm 资源
  Application.Scaled := False;
  Application.Initialize;
  Application.Title := 'TTPlayer';
  {$IFDEF WINDOWS}
  Application.MainFormOnTaskBar := True;
  {$ENDIF}
  TheApp := TTtplayerHost.Create;
  try
    TheApp.Run;
  finally
    TheApp.Free;
  end;
end.
