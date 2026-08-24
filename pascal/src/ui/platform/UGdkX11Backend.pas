unit UGdkX11Backend;

{$mode objfpc}{$H+}

// 必须排在 program uses 里 Interfaces 之前：GTK 在 widgetset 初始化时读环境。
// Linux 只走 X11（桌面 XWayland 或原生 Xorg），不支持 Wayland 客户端。
// GDK_BACKEND=x11；GTK_CSD=0 关掉客户区装饰（WSLg 上 GetWindowRect 仍可能含阴影）。

interface

procedure ForceGdkX11Backend;

implementation

uses
  SysUtils;

{$IFDEF UNIX}
function CSetEnv(Name, Value: PAnsiChar; Overwrite: LongInt): LongInt; cdecl;
  external 'c' name 'setenv';
{$ENDIF}

procedure ForceGdkX11Backend;
begin
{$IFDEF UNIX}
  CSetEnv('GDK_BACKEND', 'x11', 1);
  CSetEnv('GTK_CSD', '0', 1);
{$ENDIF}
end;

initialization
  ForceGdkX11Backend;

end.
