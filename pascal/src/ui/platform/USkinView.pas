unit USkinView;

{$mode objfpc}{$H+}

// 皮肤窗的 LCL 视图缩放：Windows 按监视器 DPI 放大客户区并拉伸绘制；
// GTK3 在 GDK_SCALE≥2 时 LCL 保持 1× 皮肤尺寸（cairo 已做设备缩放，
// 再 SetBounds(skin*2) 会变成 4×）。命中测试把客户区坐标映回皮肤像素。

interface

uses
  Classes, SysUtils, Types, Forms, Controls, Graphics, LCLType, LMessages,
  BGRABitmap, UDpiScale, UPlatformWindow;

type
  ISkinViewForm = interface
    ['{A7C3E1D0-8B4F-4E2A-9C11-6F0D2B8A4E31}']
    procedure RefreshViewScale;
  end;

function FormDpi(AForm: TCustomForm): Integer;
function FormViewScale(AForm: TCustomForm): Double;
procedure ApplySkinFormSize(AForm: TCustomForm; SkinW, SkinH: Integer);
procedure DrawSkinFrame(ACanvas: TCanvas; Frame: TBGRABitmap;
  DestW, DestH: Integer);
procedure ClientToSkinXY(AForm: TCustomForm; SkinW, SkinH: Integer;
  var X, Y: Integer);
procedure SkinToClientXY(AForm: TCustomForm; SkinW, SkinH: Integer;
  var X, Y: Integer);
function NcHitToSkin(AForm: TCustomForm; const Msg: TLMessage;
  SkinW, SkinH: Integer): TPoint;
procedure NotifySkinViewScale(AForm: TForm);

implementation

{$IFDEF WINDOWS}
uses
  Windows;
{$ENDIF}

function EnvGdkScale: Integer;
var
  s: string;
begin
  Result := 1;
  s := GetEnvironmentVariable('GDK_SCALE');
  if s <> '' then
    Result := StrToIntDef(s, 1);
  if Result < 1 then
    Result := 1;
end;

function DeviceScaleHint(AForm: TCustomForm): Integer;
begin
  Result := 1;
{$IFNDEF WINDOWS}
  if (AForm <> nil) and AForm.HandleAllocated then
    Result := PlatformGdkScaleFactor(AForm.Handle);
  if Result < 1 then
    Result := 1;
  if Result <= 1 then
    Result := EnvGdkScale;
{$ENDIF}
end;

function FormDpi(AForm: TCustomForm): Integer;
{$IFDEF WINDOWS}
type
  TGetDpiForWindow = function(Wnd: HWND): UINT; stdcall;
var
  fn: TGetDpiForWindow;
  dpi: UINT;
{$ENDIF}
begin
  Result := 96;
  if (AForm <> nil) and AForm.HandleAllocated then
  begin
{$IFDEF WINDOWS}
    fn := TGetDpiForWindow(GetProcAddress(GetModuleHandle('user32.dll'),
      'GetDpiForWindow'));
    if Assigned(fn) then
    begin
      dpi := fn(AForm.Handle);
      if dpi >= 48 then
        Exit(Integer(dpi));
    end;
{$ENDIF}
  end;
  if (AForm <> nil) and (AForm.Monitor <> nil) and
     (AForm.Monitor.PixelsPerInch >= 48) then
    Exit(AForm.Monitor.PixelsPerInch);
  if (Screen <> nil) and (Screen.PixelsPerInch >= 48) then
    Result := Screen.PixelsPerInch
  else
  begin
    Result := PlatformPixelsPerInch;
    if Result < 48 then
      Result := 96;
  end;
end;

function FormViewScale(AForm: TCustomForm): Double;
begin
  Result := ViewScaleFromDpi(FormDpi(AForm));
  // GTK cairo/GDK_SCALE 已把 LCL 逻辑像素画到 2× X 窗口。
  if DeviceScaleHint(AForm) >= 2 then
    Result := 1.0;
end;

procedure ApplySkinFormSize(AForm: TCustomForm; SkinW, SkinH: Integer);
var
  s: Double;
begin
  if AForm = nil then Exit;
  if SkinW < 1 then SkinW := 1;
  if SkinH < 1 then SkinH := 1;
  s := FormViewScale(AForm);
  AForm.SetBounds(AForm.Left, AForm.Top, ScalePx(SkinW, s), ScalePx(SkinH, s));
end;

procedure DrawSkinFrame(ACanvas: TCanvas; Frame: TBGRABitmap;
  DestW, DestH: Integer);
{$IFDEF WINDOWS}
const
  COLORONCOLOR = 1;
  HALFTONE = 4;
var
  prev: Integer;
  integerScale: Boolean;
{$ENDIF}
begin
  if (ACanvas = nil) or (Frame = nil) or (DestW <= 0) or (DestH <= 0) then
    Exit;
  if (Frame.Width = DestW) and (Frame.Height = DestH) then
  begin
    Frame.Draw(ACanvas, 0, 0, True);
    Exit;
  end;
{$IFDEF WINDOWS}
  integerScale :=
    ((Frame.Width > 0) and (DestW mod Frame.Width = 0) and
     (Frame.Height > 0) and (DestH mod Frame.Height = 0)) or
    ((DestW > 0) and (Frame.Width mod DestW = 0) and
     (DestH > 0) and (Frame.Height mod DestH = 0));
  if integerScale then
    prev := SetStretchBltMode(ACanvas.Handle, COLORONCOLOR)
  else
    prev := SetStretchBltMode(ACanvas.Handle, HALFTONE);
  SetBrushOrgEx(ACanvas.Handle, 0, 0, nil);
{$ENDIF}
  Frame.Draw(ACanvas, Classes.Rect(0, 0, DestW, DestH), True);
{$IFDEF WINDOWS}
  SetStretchBltMode(ACanvas.Handle, prev);
{$ENDIF}
end;

procedure ClientToSkinXY(AForm: TCustomForm; SkinW, SkinH: Integer;
  var X, Y: Integer);
begin
  if (AForm = nil) or (SkinW <= 0) or (SkinH <= 0) then Exit;
  if (AForm.ClientWidth <= 0) or (AForm.ClientHeight <= 0) then Exit;
  X := MapClientToSkin(X, AForm.ClientWidth, SkinW);
  Y := MapClientToSkin(Y, AForm.ClientHeight, SkinH);
end;

procedure SkinToClientXY(AForm: TCustomForm; SkinW, SkinH: Integer;
  var X, Y: Integer);
begin
  if (AForm = nil) or (SkinW <= 0) or (SkinH <= 0) then Exit;
  if (AForm.ClientWidth <= 0) or (AForm.ClientHeight <= 0) then Exit;
  X := MapSkinToClient(X, SkinW, AForm.ClientWidth);
  Y := MapSkinToClient(Y, SkinH, AForm.ClientHeight);
end;

function NcHitToSkin(AForm: TCustomForm; const Msg: TLMessage;
  SkinW, SkinH: Integer): TPoint;
begin
  Result := Point(
    SmallInt(Msg.LParam and $FFFF),
    SmallInt((Msg.LParam shr 16) and $FFFF));
  if AForm <> nil then
    Result := AForm.ScreenToClient(Result);
  ClientToSkinXY(AForm, SkinW, SkinH, Result.X, Result.Y);
end;

procedure NotifySkinViewScale(AForm: TForm);
var
  view: ISkinViewForm;
begin
  if AForm = nil then Exit;
  if Supports(AForm, ISkinViewForm, view) then
    view.RefreshViewScale;
end;

end.
