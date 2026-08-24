unit USkinTypes;

{$mode objfpc}{$H+}{$modeswitch advancedrecords}

// 皮肤数据结构定义，对应 Qt 版 src/skin/SkinData.h。
// 字段与 Qt 版一一对应；QPixmap 换为 TBGRABitmap（由 USkinLoader 负责生命周期）。

interface

uses
  Classes, SysUtils, BGRABitmap, BGRABitmapTypes;

type
  // 与 QRect 对应的整数矩形（x/y/w/h 表示，parsePosition 由 x1,y1,x2,y2 换算而来）。
  TSkinRect = record
    X, Y, W, H: Integer;
    class function Zero: TSkinRect; static;
    function IsEmpty: Boolean;
  end;

  // 与 QColor 对应：Valid=False 表示 Qt 侧的"invalid color"（JSON 输出 null）。
  TSkinColor = record
    R, G, B: Byte;
    Valid: Boolean;
    class function Invalid: TSkinColor; static;
    class function Make(AR, AG, AB: Byte): TSkinColor; static;
    function ToBGRA: TBGRAPixel;
  end;

  // 与 QFont 的可比子集对应（SkinParser::parseLogFont 用 setPixelSize，
  // 未经 LOGFONT 解析的默认字体 PixelSize 保持 -1，与 QFont 行为一致）。
  TSkinFont = record
    Family: string;
    PixelSize: Integer;   // -1 表示未设置（Qt 默认按 pointSize 走）
    Bold: Boolean;
    Italic: Boolean;
    class function Make(const AFamily: string): TSkinFont; static;
  end;

  // 单个皮肤元素，对应 SkinElement。
  TSkinElement = record
    ElementType: string;       // "play", "pause", "progress" 等
    Position: TSkinRect;
    ImageName: string;
    HotImageName: string;
    SelectedImageName: string;
    ButtonsImageName: string;
    IconName: string;
    StatePixmaps: array[0..3] of TBGRABitmap;  // 正常、悬停、按下、禁用
    HotPixmap: TBGRABitmap;
    SelectedPixmap: TBGRABitmap;
    ButtonsPixmap: TBGRABitmap;
    StateCount: Integer;
    UseFrameSizeForBounds: Boolean;

    // 滑块相关
    BarImageName: string;
    ThumbImageName: string;
    FillImageName: string;
    BarPixmap: TBGRABitmap;
    ThumbPixmaps: array[0..3] of TBGRABitmap;
    FillPixmap: TBGRABitmap;
    Vertical: Boolean;
    ThumbResizeCenter: Integer;
    ThumbResizeTile: Boolean;

    // 文本属性
    Color: TSkinColor;
    BkgndColor: TSkinColor;
    FontFamily: string;
    FontSize: Integer;
    Align: string;

    // 可缩放窗口属性
    ResizeRect: TSkinRect;
    ResizeTile: Boolean;

    LeftTopColor: TSkinColor;
    RightBottomColor: TSkinColor;
  end;
  PSkinElement = ^TSkinElement;

  // 皮肤窗口，对应 SkinWindow。
  TSkinWindow = record
    WindowType: string;
    BackgroundPixmap: TBGRABitmap;
    BackgroundImageName: string;
    DefaultPosition: TSkinRect;
    ResizeRect: TSkinRect;
    ResizeTile: Boolean;
    EqInterval: Integer;
    HilightColor: TSkinColor;
    Elements: array of TSkinElement;
    function FindElement(const AType: string): PSkinElement;
  end;

  TLyricConfig = record
    Font: TSkinFont;
    TextColor: TSkinColor;
    HilightColor: TSkinColor;
    BkgndColor: TSkinColor;
  end;

  TPlaylistConfig = record
    Font: TSkinFont;
    ColorText: TSkinColor;
    ColorHilight: TSkinColor;
    ColorBkgnd: TSkinColor;
    ColorNumber: TSkinColor;
    ColorDuration: TSkinColor;
    ColorSelect: TSkinColor;
    ColorBkgnd2: TSkinColor;
    HasFont: Boolean;
    HasColorText: Boolean;
    HasColorHilight: Boolean;
    HasColorBkgnd: Boolean;
    HasColorNumber: Boolean;
    HasColorDuration: Boolean;
    HasColorSelect: Boolean;
    HasColorBkgnd2: Boolean;
  end;

  TVisualConfig = record
    SpectrumTopColor: TSkinColor;
    SpectrumBtmColor: TSkinColor;
    SpectrumMidColor: TSkinColor;
    SpectrumPeakColor: TSkinColor;
    BlurScopeColor: TSkinColor;
    TextColor: TSkinColor;
    Font: TSkinFont;
    SpectrumWide: Integer;
    BlurSpeed: Integer;
    Blur: Boolean;
    VisualType: Integer;
    FramesPerSec: Integer;
  end;

  TSkinWindowLayout = record
    Geometry: TSkinRect;
    HasGeometry: Boolean;
    Visible: Boolean;
    HasVisible: Boolean;
  end;

  TSkinLayoutConfig = record
    PlayerWindow: TSkinWindowLayout;
    MiniWindow: TSkinWindowLayout;
    LyricWindow: TSkinWindowLayout;
    EqualizerWindow: TSkinWindowLayout;
    PlaylistWindow: TSkinWindowLayout;
  end;

  // 完整皮肤数据，对应 SkinData。持有其中所有 TBGRABitmap 的所有权。
  TSkinData = record
    Name: string;
    Author: string;
    Url: string;
    Email: string;
    TransparentColor: TSkinColor;
    Version: Integer;

    PlayerWindow: TSkinWindow;
    MiniWindow: TSkinWindow;
    LyricWindow: TSkinWindow;
    EqualizerWindow: TSkinWindow;
    PlaylistWindow: TSkinWindow;

    LayoutConfig: TSkinLayoutConfig;
    LyricConfig: TLyricConfig;
    PlaylistConfig: TPlaylistConfig;
    VisualConfig: TVisualConfig;
  end;
  PSkinData = ^TSkinData;

// 按 Qt 版各结构默认值初始化（SkinData.h 中的成员初始化器）。
procedure InitSkinData(out Skin: TSkinData);
procedure InitSkinElement(out Elem: TSkinElement);
// 释放皮肤持有的全部位图。同一位图可能被多个状态槽共享，需去重后释放。
procedure FreeSkinData(var Skin: TSkinData);

implementation

class function TSkinRect.Zero: TSkinRect;
begin
  Result.X := 0; Result.Y := 0; Result.W := 0; Result.H := 0;
end;

function TSkinRect.IsEmpty: Boolean;
begin
  // 与 QRect::isEmpty 一致：宽或高 <= 0 即视为空。
  Result := (W <= 0) or (H <= 0);
end;

class function TSkinColor.Invalid: TSkinColor;
begin
  Result.R := 0; Result.G := 0; Result.B := 0; Result.Valid := False;
end;

class function TSkinColor.Make(AR, AG, AB: Byte): TSkinColor;
begin
  Result.R := AR; Result.G := AG; Result.B := AB; Result.Valid := True;
end;

function TSkinColor.ToBGRA: TBGRAPixel;
begin
  Result := BGRA(R, G, B, 255);
end;

class function TSkinFont.Make(const AFamily: string): TSkinFont;
begin
  Result.Family := AFamily;
  Result.PixelSize := -1;
  Result.Bold := False;
  Result.Italic := False;
end;

function TSkinWindow.FindElement(const AType: string): PSkinElement;
var
  i: Integer;
begin
  for i := 0 to High(Elements) do
    if SameText(Elements[i].ElementType, AType) then
      Exit(@Elements[i]);
  Result := nil;
end;

procedure InitSkinElement(out Elem: TSkinElement);
begin
  Elem := Default(TSkinElement);
  Elem.StateCount := 1;
  Elem.FontSize := 12;
  Elem.Color := TSkinColor.Invalid;
  Elem.BkgndColor := TSkinColor.Invalid;
  Elem.LeftTopColor := TSkinColor.Invalid;
  Elem.RightBottomColor := TSkinColor.Invalid;
end;

procedure InitWindow(out Wnd: TSkinWindow);
begin
  Wnd := Default(TSkinWindow);
  Wnd.EqInterval := 2;
  Wnd.HilightColor := TSkinColor.Invalid;
end;

procedure InitSkinData(out Skin: TSkinData);
begin
  Skin := Default(TSkinData);
  Skin.TransparentColor := TSkinColor.Make(255, 0, 255);  // 默认透明色 #FF00FF
  Skin.Version := 2;
  InitWindow(Skin.PlayerWindow);
  InitWindow(Skin.MiniWindow);
  InitWindow(Skin.LyricWindow);
  InitWindow(Skin.EqualizerWindow);
  InitWindow(Skin.PlaylistWindow);

  Skin.LyricConfig.Font := TSkinFont.Make('SimSun');
  Skin.LyricConfig.TextColor := TSkinColor.Make($00, $80, $C0);
  Skin.LyricConfig.HilightColor := TSkinColor.Make($00, $FF, $00);
  Skin.LyricConfig.BkgndColor := TSkinColor.Make($00, $00, $00);

  Skin.PlaylistConfig.Font := TSkinFont.Make('SimSun');
  Skin.PlaylistConfig.ColorText := TSkinColor.Make($00, $80, $FF);
  Skin.PlaylistConfig.ColorHilight := TSkinColor.Make($00, $FF, $00);
  Skin.PlaylistConfig.ColorBkgnd := TSkinColor.Make($00, $00, $00);
  Skin.PlaylistConfig.ColorNumber := TSkinColor.Make($00, $80, $00);
  Skin.PlaylistConfig.ColorDuration := TSkinColor.Make($C0, $80, $20);
  Skin.PlaylistConfig.ColorSelect := TSkinColor.Make($32, $69, $C8);
  Skin.PlaylistConfig.ColorBkgnd2 := TSkinColor.Make($20, $20, $20);

  Skin.VisualConfig.SpectrumTopColor := TSkinColor.Make($FF, $FF, $FF);
  Skin.VisualConfig.SpectrumBtmColor := TSkinColor.Make($00, $80, $FF);
  Skin.VisualConfig.SpectrumMidColor := TSkinColor.Make($FF, $FF, $00);
  Skin.VisualConfig.SpectrumPeakColor := TSkinColor.Make($FF, $FF, $FF);
  Skin.VisualConfig.BlurScopeColor := TSkinColor.Make($00, $FF, $FF);
  Skin.VisualConfig.TextColor := TSkinColor.Make($FF, $FF, $FF);
  Skin.VisualConfig.Font := TSkinFont.Make('Tahoma');
  Skin.VisualConfig.SpectrumWide := 0;
  Skin.VisualConfig.BlurSpeed := 3;
  Skin.VisualConfig.Blur := True;
  Skin.VisualConfig.VisualType := 0;
  Skin.VisualConfig.FramesPerSec := 30;
end;

procedure CollectBitmaps(var Wnd: TSkinWindow; List: TFPList);

  procedure Add(Bmp: TBGRABitmap);
  begin
    if (Bmp <> nil) and (List.IndexOf(Bmp) < 0) then
      List.Add(Bmp);
  end;

var
  i, s: Integer;
begin
  Add(Wnd.BackgroundPixmap);
  for i := 0 to High(Wnd.Elements) do
  begin
    for s := 0 to 3 do
    begin
      Add(Wnd.Elements[i].StatePixmaps[s]);
      Add(Wnd.Elements[i].ThumbPixmaps[s]);
    end;
    Add(Wnd.Elements[i].HotPixmap);
    Add(Wnd.Elements[i].SelectedPixmap);
    Add(Wnd.Elements[i].ButtonsPixmap);
    Add(Wnd.Elements[i].BarPixmap);
    Add(Wnd.Elements[i].FillPixmap);
  end;
end;

procedure FreeSkinData(var Skin: TSkinData);
var
  List: TFPList;
  i: Integer;
begin
  List := TFPList.Create;
  try
    CollectBitmaps(Skin.PlayerWindow, List);
    CollectBitmaps(Skin.MiniWindow, List);
    CollectBitmaps(Skin.LyricWindow, List);
    CollectBitmaps(Skin.EqualizerWindow, List);
    CollectBitmaps(Skin.PlaylistWindow, List);
    for i := 0 to List.Count - 1 do
      TBGRABitmap(List[i]).Free;
  finally
    List.Free;
  end;
  InitSkinData(Skin);
end;

end.
