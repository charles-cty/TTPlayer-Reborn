unit USkinJsonDump;

{$mode objfpc}{$H+}

// 皮肤数据 JSON 导出，对应 Qt 版 src/tools/SkinDumper.cpp。
// 输出结构与 Qt 版逐字段一致（键排序、颜色 #rrggbb、矩形 x/y/w/h、
// 字体 family/pixel_size/bold/italic、位图只记尺寸）。
// 缩进与字符转义的细微差异由 Layer 1 比对脚本做结构化比较时消化。

interface

uses
  Classes, SysUtils, fpjson, USkinTypes;

// 把 SkinData 序列化为规范化 JSON 文本。
function DumpSkinToJson(const Skin: TSkinData): string;

implementation

uses
  BGRABitmap;

function DumpColor(const C: TSkinColor): TJSONData;
begin
  if not C.Valid then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(LowerCase(Format('#%.2x%.2x%.2x', [C.R, C.G, C.B])));
end;

function DumpRect(const R: TSkinRect): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('x', R.X);
  Result.Add('y', R.Y);
  Result.Add('w', R.W);
  Result.Add('h', R.H);
end;

function DumpFont(const F: TSkinFont): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('family', F.Family);
  Result.Add('pixel_size', F.PixelSize);
  Result.Add('bold', F.Bold);
  Result.Add('italic', F.Italic);
end;

function DumpPixmapSize(Bmp: TBGRABitmap): TJSONData;
var
  obj: TJSONObject;
begin
  if Bmp = nil then
    Exit(TJSONNull.Create);
  obj := TJSONObject.Create;
  obj.Add('w', Bmp.Width);
  obj.Add('h', Bmp.Height);
  Result := obj;
end;

function DumpElement(const Elem: TSkinElement): TJSONObject;
var
  stateSizes, thumbSizes: TJSONArray;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('type', Elem.ElementType);
  Result.Add('position', DumpRect(Elem.Position));

  Result.Add('image_name', Elem.ImageName);
  Result.Add('hot_image_name', Elem.HotImageName);
  Result.Add('selected_image_name', Elem.SelectedImageName);
  Result.Add('buttons_image_name', Elem.ButtonsImageName);
  Result.Add('icon_name', Elem.IconName);
  Result.Add('bar_image_name', Elem.BarImageName);
  Result.Add('thumb_image_name', Elem.ThumbImageName);
  Result.Add('fill_image_name', Elem.FillImageName);

  Result.Add('state_count', Elem.StateCount);
  stateSizes := TJSONArray.Create;
  for i := 0 to 3 do
    stateSizes.Add(DumpPixmapSize(Elem.StatePixmaps[i]));
  Result.Add('state_sizes', stateSizes);
  Result.Add('use_frame_size_for_bounds', Elem.UseFrameSizeForBounds);

  Result.Add('hot_size', DumpPixmapSize(Elem.HotPixmap));
  Result.Add('selected_size', DumpPixmapSize(Elem.SelectedPixmap));
  Result.Add('buttons_size', DumpPixmapSize(Elem.ButtonsPixmap));
  Result.Add('bar_size', DumpPixmapSize(Elem.BarPixmap));
  Result.Add('fill_size', DumpPixmapSize(Elem.FillPixmap));

  thumbSizes := TJSONArray.Create;
  for i := 0 to 3 do
    thumbSizes.Add(DumpPixmapSize(Elem.ThumbPixmaps[i]));
  Result.Add('thumb_sizes', thumbSizes);

  Result.Add('vertical', Elem.Vertical);
  Result.Add('thumb_resize_center', Elem.ThumbResizeCenter);
  Result.Add('thumb_resize_tile', Elem.ThumbResizeTile);

  Result.Add('color', DumpColor(Elem.Color));
  Result.Add('bkgnd_color', DumpColor(Elem.BkgndColor));
  Result.Add('font_family', Elem.FontFamily);
  Result.Add('font_size', Elem.FontSize);
  Result.Add('align', Elem.Align);

  Result.Add('resize_rect', DumpRect(Elem.ResizeRect));
  Result.Add('resize_tile', Elem.ResizeTile);

  Result.Add('left_top_color', DumpColor(Elem.LeftTopColor));
  Result.Add('right_bottom_color', DumpColor(Elem.RightBottomColor));
end;

function DumpWindow(const Wnd: TSkinWindow): TJSONObject;
var
  elements: TJSONArray;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('type', Wnd.WindowType);
  Result.Add('background_image_name', Wnd.BackgroundImageName);
  Result.Add('background_size', DumpPixmapSize(Wnd.BackgroundPixmap));
  Result.Add('default_position', DumpRect(Wnd.DefaultPosition));
  Result.Add('resize_rect', DumpRect(Wnd.ResizeRect));
  Result.Add('resize_tile', Wnd.ResizeTile);
  Result.Add('eq_interval', Wnd.EqInterval);
  Result.Add('hilight_color', DumpColor(Wnd.HilightColor));

  elements := TJSONArray.Create;
  for i := 0 to High(Wnd.Elements) do
    elements.Add(DumpElement(Wnd.Elements[i]));
  Result.Add('elements', elements);
end;

function DumpWindowLayout(const Layout: TSkinWindowLayout): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('geometry', DumpRect(Layout.Geometry));
  Result.Add('has_geometry', Layout.HasGeometry);
  Result.Add('visible', Layout.Visible);
  Result.Add('has_visible', Layout.HasVisible);
end;

function DumpLyricConfig(const Cfg: TLyricConfig): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('font', DumpFont(Cfg.Font));
  Result.Add('text_color', DumpColor(Cfg.TextColor));
  Result.Add('hilight_color', DumpColor(Cfg.HilightColor));
  Result.Add('bkgnd_color', DumpColor(Cfg.BkgndColor));
end;

function DumpPlaylistConfig(const Cfg: TPlaylistConfig): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('font', DumpFont(Cfg.Font));
  Result.Add('color_text', DumpColor(Cfg.ColorText));
  Result.Add('color_hilight', DumpColor(Cfg.ColorHilight));
  Result.Add('color_bkgnd', DumpColor(Cfg.ColorBkgnd));
  Result.Add('color_number', DumpColor(Cfg.ColorNumber));
  Result.Add('color_duration', DumpColor(Cfg.ColorDuration));
  Result.Add('color_select', DumpColor(Cfg.ColorSelect));
  Result.Add('color_bkgnd2', DumpColor(Cfg.ColorBkgnd2));
  Result.Add('has_font', Cfg.HasFont);
  Result.Add('has_color_text', Cfg.HasColorText);
  Result.Add('has_color_hilight', Cfg.HasColorHilight);
  Result.Add('has_color_bkgnd', Cfg.HasColorBkgnd);
  Result.Add('has_color_number', Cfg.HasColorNumber);
  Result.Add('has_color_duration', Cfg.HasColorDuration);
  Result.Add('has_color_select', Cfg.HasColorSelect);
  Result.Add('has_color_bkgnd2', Cfg.HasColorBkgnd2);
end;

function DumpVisualConfig(const Cfg: TVisualConfig): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('spectrum_top_color', DumpColor(Cfg.SpectrumTopColor));
  Result.Add('spectrum_btm_color', DumpColor(Cfg.SpectrumBtmColor));
  Result.Add('spectrum_mid_color', DumpColor(Cfg.SpectrumMidColor));
  Result.Add('spectrum_peak_color', DumpColor(Cfg.SpectrumPeakColor));
  Result.Add('blur_scope_color', DumpColor(Cfg.BlurScopeColor));
  Result.Add('text_color', DumpColor(Cfg.TextColor));
  Result.Add('font', DumpFont(Cfg.Font));
  Result.Add('spectrum_wide', Cfg.SpectrumWide);
  Result.Add('blur_speed', Cfg.BlurSpeed);
  Result.Add('blur', Cfg.Blur);
  Result.Add('type', Cfg.VisualType);
  Result.Add('frames_per_sec', Cfg.FramesPerSec);
end;

function DumpSkinToJson(const Skin: TSkinData): string;
var
  root, layout: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('name', Skin.Name);
    root.Add('author', Skin.Author);
    root.Add('url', Skin.Url);
    root.Add('email', Skin.Email);
    root.Add('version', Skin.Version);
    root.Add('transparent_color', DumpColor(Skin.TransparentColor));

    root.Add('player_window', DumpWindow(Skin.PlayerWindow));
    root.Add('mini_window', DumpWindow(Skin.MiniWindow));
    root.Add('lyric_window', DumpWindow(Skin.LyricWindow));
    root.Add('equalizer_window', DumpWindow(Skin.EqualizerWindow));
    root.Add('playlist_window', DumpWindow(Skin.PlaylistWindow));

    layout := TJSONObject.Create;
    layout.Add('player_window', DumpWindowLayout(Skin.LayoutConfig.PlayerWindow));
    layout.Add('mini_window', DumpWindowLayout(Skin.LayoutConfig.MiniWindow));
    layout.Add('lyric_window', DumpWindowLayout(Skin.LayoutConfig.LyricWindow));
    layout.Add('equalizer_window', DumpWindowLayout(Skin.LayoutConfig.EqualizerWindow));
    layout.Add('playlist_window', DumpWindowLayout(Skin.LayoutConfig.PlaylistWindow));
    root.Add('layout_config', layout);

    root.Add('lyric_config', DumpLyricConfig(Skin.LyricConfig));
    root.Add('playlist_config', DumpPlaylistConfig(Skin.PlaylistConfig));
    root.Add('visual_config', DumpVisualConfig(Skin.VisualConfig));

    Result := root.FormatJSON([], 4);
  finally
    root.Free;
  end;
end;

end.
