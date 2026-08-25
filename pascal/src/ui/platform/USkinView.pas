unit USkinView;

{$mode objfpc}{$H+}

// 皮肤窗的 LCL 视图缩放：Windows 按监视器 DPI 放大客户区并拉伸绘制；
// GTK3 在 GDK_SCALE≥2 时 LCL 保持 1× 皮肤尺寸（cairo 已做设备缩放，
// 再 SetBounds(skin*2) 会变成 4×）。命中测试把客户区坐标映回皮肤像素。
// 皮肤位图最近邻拉伸；播放列表/歌词 TrueType 在 dest 像素栅格化（Windows
// ClearType），避免 1× 合成后再 HALFTONE 发糊。

interface

uses
  Classes, SysUtils, Types, Forms, Controls, Graphics, LCLType, LMessages,
  BGRABitmap, BGRABitmapTypes, UDpiScale, UPlatformWindow;

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
procedure BlitNearest(Dest, Src: TBGRABitmap);
procedure PutSkinNearest(Dest: TBGRABitmap; const DestR: Types.TRect;
  Src: TBGRABitmap; Mode: TDrawMode = dmDrawWithTransparency);
function ViewRect(AX, AY, AW, AH: Integer; Scale: Double): Types.TRect;
procedure ApplyViewFont(Bmp: TBGRABitmap; const Family: string;
  PixelSize: Integer; Bold, Italic: Boolean; Scale: Double);
procedure ClientToSkinXY(AForm: TCustomForm; SkinW, SkinH: Integer;
  var X, Y: Integer);
procedure SkinToClientXY(AForm: TCustomForm; SkinW, SkinH: Integer;
  var X, Y: Integer);
function NcHitToSkin(AForm: TCustomForm; const Msg: TLMessage;
  SkinW, SkinH: Integer): TPoint;
// Windows：背景 HTCAPTION 会把右键吞进非客户区，菜单出不来。右键按下时改走 HTCLIENT。
function NcRightButtonDown: Boolean;
procedure NotifySkinViewScale(AForm: TForm);

implementation

uses
  USkinRender
{$IFDEF WINDOWS}
  , Windows
{$ENDIF}
  ;

function EnvGdkScale: Integer;
var
  s: string;
begin
  Result := 1;
  s := SysUtils.GetEnvironmentVariable('GDK_SCALE');
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

function ViewRect(AX, AY, AW, AH: Integer; Scale: Double): Types.TRect;
begin
  Result.Left := ScalePx(AX, Scale);
  Result.Top := ScalePx(AY, Scale);
  Result.Right := ScalePx(AX + AW, Scale);
  Result.Bottom := ScalePx(AY + AH, Scale);
end;

procedure ApplyViewFont(Bmp: TBGRABitmap; const Family: string;
  PixelSize: Integer; Bold, Italic: Boolean; Scale: Double);
var
  st: TFontStyles;
  px: Integer;
begin
  if Bmp = nil then Exit;
  if Family <> '' then
    Bmp.FontName := Family
  else
    Bmp.FontName := 'SimSun';
  px := PixelSize;
  if px <= 0 then
    px := 12;
  Bmp.FontHeight := ScalePx(px, Scale);
  st := [];
  if Bold then
    Include(st, fsBold);
  if Italic then
    Include(st, fsItalic);
  Bmp.FontStyle := st;
{$IFDEF WINDOWS}
  Bmp.FontQuality := fqFineClearTypeRGB;
{$ELSE}
  Bmp.FontAntialias := True;
{$ENDIF}
end;

procedure BlitNearest(Dest, Src: TBGRABitmap);
var
  scaled: TBGRABitmap;
begin
  if (Dest = nil) or (Src = nil) then Exit;
  if (Src.Width = Dest.Width) and (Src.Height = Dest.Height) then
  begin
    Dest.PutImage(0, 0, Src, dmSet);
    Exit;
  end;
  if (Dest.Width < 1) or (Dest.Height < 1) then Exit;
  scaled := NearestResample(Src, Dest.Width, Dest.Height);
  try
    Dest.PutImage(0, 0, scaled, dmSet);
  finally
    scaled.Free;
  end;
end;

procedure PutSkinNearest(Dest: TBGRABitmap; const DestR: Types.TRect;
  Src: TBGRABitmap; Mode: TDrawMode);
var
  scaled: TBGRABitmap;
  dw, dh: Integer;
begin
  if (Dest = nil) or (Src = nil) then Exit;
  dw := DestR.Right - DestR.Left;
  dh := DestR.Bottom - DestR.Top;
  if (dw <= 0) or (dh <= 0) then Exit;
  if (dw = Src.Width) and (dh = Src.Height) then
  begin
    Dest.PutImage(DestR.Left, DestR.Top, Src, Mode);
    Exit;
  end;
  scaled := NearestResample(Src, dw, dh);
  try
    Dest.PutImage(DestR.Left, DestR.Top, scaled, Mode);
  finally
    scaled.Free;
  end;
end;

procedure DrawSkinFrame(ACanvas: TCanvas; Frame: TBGRABitmap;
  DestW, DestH: Integer);
var
  scaled: TBGRABitmap;
begin
  if (ACanvas = nil) or (Frame = nil) or (DestW <= 0) or (DestH <= 0) then
    Exit;
  if (Frame.Width = DestW) and (Frame.Height = DestH) then
  begin
    Frame.Draw(ACanvas, 0, 0, True);
    Exit;
  end;
  // 最近邻：皮肤是像素图。不用 BGRA rmSimpleStretch（上采样会 AV）。
  scaled := NearestResample(Frame, DestW, DestH);
  try
    scaled.Draw(ACanvas, 0, 0, True);
  finally
    scaled.Free;
  end;
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
  Result := Types.Point(
    SmallInt(Msg.LParam and $FFFF),
    SmallInt((Msg.LParam shr 16) and $FFFF));
  if AForm <> nil then
    Result := AForm.ScreenToClient(Result);
  ClientToSkinXY(AForm, SkinW, SkinH, Result.X, Result.Y);
end;

function NcRightButtonDown: Boolean;
begin
  {$IFDEF WINDOWS}
  Result := (Windows.GetAsyncKeyState(VK_RBUTTON) and $8000) <> 0;
  {$ELSE}
  Result := False;
  {$ENDIF}
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
