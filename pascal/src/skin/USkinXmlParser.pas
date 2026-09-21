unit USkinXmlParser;

{$mode objfpc}{$H+}

// 皮肤 XML 解析器，对应 Qt 版 src/skin/SkinParser.cpp。
// 将 Skin.xml / Lyric.xml / PlayList.xml / Visual.xml / 侧车布局 XML
// 解析为 USkinTypes 中的数据结构。
//
// 为保证与 Qt 版 differential testing 逐字节一致，所有解析细节
// （默认值、容错、状态图拆分规则）都必须与 Qt 版严格对齐。

interface

uses
  Classes, SysUtils, StrUtils, laz2_DOM, laz2_XMLRead, BGRABitmap, BGRABitmapTypes,
  USkinTypes;

type
  // 图片资源表：小写文件名 → TBGRABitmap（表持有源图所有权）。
  TSkinImageMap = class
  private
    FNames: TStringList;
    FQuantizedNames: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AName: string; ABitmap: TBGRABitmap;
      AQuantizedColorFormat: Boolean = False);
    function Find(const AName: string): TBGRABitmap;
    function IsQuantizedColorFormat(const AName: string): Boolean;
    function Count: Integer;
  end;

// 解析 Skin.xml（已 sanitize 的文本），结合图片资源生成 SkinData。
function ParseSkinXml(const XmlContent: string; Images: TSkinImageMap;
  const DefaultTransColor: TSkinColor; var Skin: TSkinData): Boolean;

// 解析 Lyric.xml / PlayList.xml / Visual.xml / 侧车布局 XML。
procedure ParseLyricXml(const XmlContent: string; var Skin: TSkinData);
procedure ParsePlaylistXml(const XmlContent: string; var Skin: TSkinData);
procedure ParseVisualXml(const XmlContent: string; var Skin: TSkinData);
procedure ParseSkinConfigXml(const XmlContent: string; var Skin: TSkinData);

// 解析 Windows LOGFONT 逗号分隔字符串（对应 SkinParser::parseLogFont）。
function ParseLogFont(const LogFontStr: string): TSkinFont;

// 工具函数（Layer 3 单测直接覆盖）。
function ParsePositionStr(const Pos: string): TSkinRect;
function ParseColorStr(const ColorStr: string): TSkinColor;
function ParseBoolAttr(const Value: string): Boolean;

// 推导播放列表配色（对应 SkinEngine.cpp 的 resolvePlaylistTheme）。
procedure ResolvePlaylistTheme(var Skin: TSkinData);

implementation

{ TSkinImageMap }

constructor TSkinImageMap.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
  FNames.Sorted := True;
  FNames.OwnsObjects := True;
  FNames.Duplicates := dupIgnore;
  FQuantizedNames := TStringList.Create;
  FQuantizedNames.Sorted := True;
  FQuantizedNames.Duplicates := dupIgnore;
end;

destructor TSkinImageMap.Destroy;
begin
  FNames.Free;
  FQuantizedNames.Free;
  inherited Destroy;
end;

procedure TSkinImageMap.Add(const AName: string; ABitmap: TBGRABitmap;
  AQuantizedColorFormat: Boolean);
begin
  FNames.AddObject(LowerCase(AName), ABitmap);
  if AQuantizedColorFormat then
    FQuantizedNames.Add(LowerCase(AName));
end;

function TSkinImageMap.Find(const AName: string): TBGRABitmap;
var
  idx: Integer;
begin
  if FNames.Find(LowerCase(AName), idx) then
    Result := TBGRABitmap(FNames.Objects[idx])
  else
    Result := nil;
end;

function TSkinImageMap.IsQuantizedColorFormat(const AName: string): Boolean;
var
  idx: Integer;
begin
  Result := FQuantizedNames.Find(LowerCase(AName), idx);
end;

function TSkinImageMap.Count: Integer;
begin
  Result := FNames.Count;
end;

{ 基础解析工具 }

function ParseBoolAttr(const Value: string): Boolean;
var
  lowered: string;
begin
  lowered := LowerCase(Trim(Value));
  Result := (lowered = '1') or (lowered = 'true') or (lowered = 'yes');
end;

// 与 QString::toInt 一致：解析失败返回 0，允许前后空白。
function ToIntQt(const S: string): Integer;
begin
  Result := StrToIntDef(Trim(S), 0);
end;

function ParsePositionStr(const Pos: string): TSkinRect;
var
  parts: TStringArray;
  x1, y1, x2, y2: Integer;
begin
  Result := TSkinRect.Zero;
  parts := Pos.Split([',']);
  if Length(parts) >= 4 then
  begin
    x1 := ToIntQt(parts[0]);
    y1 := ToIntQt(parts[1]);
    x2 := ToIntQt(parts[2]);
    y2 := ToIntQt(parts[3]);
    Result.X := x1;
    Result.Y := y1;
    Result.W := x2 - x1;
    Result.H := y2 - y1;
  end;
end;

function HexDigit(C: Char; out V: Integer): Boolean;
begin
  Result := True;
  case C of
    '0'..'9': V := Ord(C) - Ord('0');
    'a'..'f': V := Ord(C) - Ord('a') + 10;
    'A'..'F': V := Ord(C) - Ord('A') + 10;
  else
    V := 0;
    Result := False;
  end;
end;

// 对应 QColor(QString)：支持 "#rgb" 与 "#rrggbb"，其余视为无效。
// （皮肤实际只使用 #rrggbb；QColor 的命名颜色等能力这里不需要。）
function ParseColorStr(const ColorStr: string): TSkinColor;
var
  s: string;
  v: array[0..5] of Integer;
  i: Integer;
begin
  Result := TSkinColor.Invalid;
  s := Trim(ColorStr);
  if (s = '') or (s[1] <> '#') then Exit;
  Delete(s, 1, 1);

  if Length(s) = 6 then
  begin
    for i := 1 to 6 do
      if not HexDigit(s[i], v[i - 1]) then Exit;
    Result := TSkinColor.Make(v[0] * 16 + v[1], v[2] * 16 + v[3], v[4] * 16 + v[5]);
  end
  else if Length(s) = 3 then
  begin
    for i := 1 to 3 do
      if not HexDigit(s[i], v[i - 1]) then Exit;
    // #rgb 展开为 #rrggbb
    Result := TSkinColor.Make(v[0] * 17, v[1] * 17, v[2] * 17);
  end;
end;

function ParseLogFont(const LogFontStr: string): TSkinFont;
var
  parts: TStringArray;
  lfHeight, px, lfWeight: Integer;
  faceName: string;
begin
  Result := TSkinFont.Make('');
  parts := LogFontStr.Split([',']);
  if Length(parts) >= 14 then
  begin
    lfHeight := ToIntQt(parts[0]);
    // 负数 lfHeight 表示字符高度（像素），正数表示单元格高度；两者都取绝对值。
    px := Abs(lfHeight);
    if px > 0 then Result.PixelSize := px;
    lfWeight := ToIntQt(parts[4]);
    Result.Bold := lfWeight >= 700;
    faceName := Trim(parts[13]);
    if faceName <> '' then Result.Family := faceName;
  end;
end;

{ 状态图拆分（对应 SkinParser.cpp 匿名命名空间的拆分逻辑） }

// 固定状态数的按钮类型表（对应 fixedButtonStateCount）。
function FixedButtonStateCount(const ElemType: string): Integer;
const
  kTypes: array[0..22] of string = (
    'play', 'pause', 'stop', 'prev', 'next', 'mute', 'open', 'close', 'exit',
    'lyric', 'equalizer', 'playlist', 'minimize', 'minimode', 'enabled',
    'profile', 'reset', 'ontop', 'browser', 'backward', 'forward', 'refresh',
    'startup');
var
  lowered: string;
  i: Integer;
begin
  lowered := LowerCase(ElemType);
  for i := 0 to High(kTypes) do
    if lowered = kTypes[i] then Exit(4);
  Result := 0;
end;

// 滑块 thumb 的固定状态数表（对应 fixedSliderThumbStateCount）。
function FixedSliderThumbStateCount(const ElemType: string): Integer;
var
  lowered: string;
begin
  lowered := LowerCase(ElemType);
  if (lowered = 'progress') or (lowered = 'volume') or (lowered = 'balance') or
     (lowered = 'surround') or (lowered = 'preamp') or (lowered = 'eqfactor') then
    Exit(4);
  if lowered = 'scrollbar' then Exit(3);
  Result := 0;
end;

type
  TRunArray = array of TSkinRect;

// 找出精灵表中按列扫描的不透明区段（对应 opaqueColumnRuns）。
function OpaqueColumnRuns(Sheet: TBGRABitmap): TRunArray;
var
  runs: TRunArray;
  runStart, x, y: Integer;
  hasOpaque: Boolean;
  p: PBGRAPixel;

  procedure AppendRun(AStart, AWidth: Integer);
  var
    n: Integer;
  begin
    n := Length(runs);
    SetLength(runs, n + 1);
    runs[n].X := AStart;
    runs[n].Y := 0;
    runs[n].W := AWidth;
    runs[n].H := Sheet.Height;
  end;

begin
  runs := nil;
  if Sheet = nil then Exit(runs);

  runStart := -1;
  for x := 0 to Sheet.Width - 1 do
  begin
    hasOpaque := False;
    for y := 0 to Sheet.Height - 1 do
    begin
      p := Sheet.ScanLine[y];
      Inc(p, x);
      if p^.alpha > 0 then
      begin
        hasOpaque := True;
        Break;
      end;
    end;

    if hasOpaque then
    begin
      if runStart < 0 then runStart := x;
      Continue;
    end;

    if runStart >= 0 then
    begin
      AppendRun(runStart, x - runStart);
      runStart := -1;
    end;
  end;

  if runStart >= 0 then
    AppendRun(runStart, Sheet.Width - runStart);
  Result := runs;
end;

function CopyRect(Sheet: TBGRABitmap; const R: TSkinRect): TBGRABitmap;
begin
  Result := Sheet.GetPart(Classes.Rect(R.X, R.Y, R.X + R.W, R.Y + R.H));
end;

// 按不透明区段拆分（对应 splitByOpaqueColumnRuns）。
function SplitByOpaqueColumnRuns(Sheet: TBGRABitmap; ExpectedStates: Integer;
  var Outs: array of TBGRABitmap; var StateCount: Integer): Boolean;
var
  runs: TRunArray;
  i: Integer;
begin
  Result := False;
  if (Sheet = nil) or (ExpectedStates < 2) or (ExpectedStates > 4) then Exit;

  runs := OpaqueColumnRuns(Sheet);
  if Length(runs) <> ExpectedStates then Exit;
  for i := 0 to High(runs) do
    if runs[i].W <= 0 then Exit;

  StateCount := ExpectedStates;
  for i := 0 to ExpectedStates - 1 do
    Outs[i] := CopyRect(Sheet, runs[i]);
  for i := ExpectedStates to 3 do
    Outs[i] := Outs[0];
  Result := True;
end;

// 单一状态赋值（对应 assignSingleState）。传入的 Sheet 所有权归 Outs[0]。
procedure AssignSingleState(Sheet: TBGRABitmap;
  var Outs: array of TBGRABitmap; var StateCount: Integer);
var
  i: Integer;
begin
  for i := 0 to 3 do Outs[i] := nil;
  if Sheet = nil then
  begin
    StateCount := 0;
    Exit;
  end;
  StateCount := 1;
  for i := 0 to 3 do Outs[i] := Sheet;
end;

type
  TFixedStateSplitResult = (fssFailed, fssOpaqueRuns, fssEqualPartitions, fssForcedPartitions);

// 按固定状态数拆分（对应 splitByFixedStateCount）。
// 成功拆分时会生成新位图，原 Outs 中的整图引用不再使用（由调用方管理释放）。
function SplitByFixedStateCount(Sheet: TBGRABitmap; ExpectedStates: Integer;
  var Outs: array of TBGRABitmap; var StateCount: Integer): TFixedStateSplitResult;
var
  i, startX, endX, partWidth: Integer;
  r: TSkinRect;
begin
  if (Sheet = nil) or (ExpectedStates < 2) or (ExpectedStates > 4) then
    Exit(fssFailed);

  if SplitByOpaqueColumnRuns(Sheet, ExpectedStates, Outs, StateCount) then
    Exit(fssOpaqueRuns);

  if Sheet.Width < ExpectedStates then Exit(fssFailed);

  StateCount := ExpectedStates;
  startX := 0;
  for i := 0 to ExpectedStates - 1 do
  begin
    endX := ((i + 1) * Sheet.Width) div ExpectedStates;
    partWidth := endX - startX;
    if partWidth <= 0 then Exit(fssFailed);
    r.X := startX; r.Y := 0; r.W := partWidth; r.H := Sheet.Height;
    Outs[i] := CopyRect(Sheet, r);
    startX := endX;
  end;
  for i := ExpectedStates to 3 do
    Outs[i] := Outs[0];

  if (Sheet.Width mod ExpectedStates) = 0 then
    Result := fssEqualPartitions
  else
    Result := fssForcedPartitions;
end;

// 判断 position 是否记录的是整张精灵表的包围盒（对应 rectLooksLikeSpriteSheetBounds）。
function RectLooksLikeSpriteSheetBounds(const R: TSkinRect; Sheet: TBGRABitmap): Boolean;
begin
  if R.IsEmpty or (Sheet = nil) then Exit(False);
  Result := (Abs(R.W - Sheet.Width) <= 2) and (Abs(R.H - Sheet.Height) <= 2);
end;

{ 图片加载与色键处理 }

// 从资源表复制图像并把透明色转为 alpha（对应 SkinParser::loadAndProcess）。
// 返回新副本，调用方持有所有权；找不到时返回 nil。
function LoadAndProcess(Images: TSkinImageMap; const AName: string;
  const TransColor: TSkinColor): TBGRABitmap;
var
  src: TBGRABitmap;
  x, y: Integer;
  p: PBGRAPixel;

  function IsEndpointKeyMatch(const Pixel: TBGRAPixel): Boolean;
  const
    // BGRABitmap keeps 5/6-bit BMP endpoint channels at 248/252, while the
    // XML color key is expressed as 8-bit #rrggbb (usually #ff00ff).
    EndpointTolerance = 8;
  begin
    Result := (Abs(Integer(Pixel.red) - TransColor.R) <= EndpointTolerance) and
      (Abs(Integer(Pixel.green) - TransColor.G) <= EndpointTolerance) and
      (Abs(Integer(Pixel.blue) - TransColor.B) <= EndpointTolerance);
  end;
begin
  Result := nil;
  if AName = '' then Exit;
  src := Images.Find(AName);
  if src = nil then Exit;

  Result := src.Duplicate;
  for y := 0 to Result.Height - 1 do
  begin
    p := Result.ScanLine[y];
    for x := 0 to Result.Width - 1 do
    begin
      if (p^.red = TransColor.R) and (p^.green = TransColor.G) and
         (p^.blue = TransColor.B) then
        p^ := BGRAPixelTransparent;  // 完全透明（0,0,0,0）
      // Match Qt's RGB16 -> ARGB32 color-key semantics.  BGRABitmap exposes
      // a 5/6-bit endpoint as 248/252, while Qt expands it back to 255.
      if Images.IsQuantizedColorFormat(AName) and
         (TransColor.R in [0, 255]) and (TransColor.G in [0, 255]) and
         (TransColor.B in [0, 255]) and IsEndpointKeyMatch(p^) then
        p^ := BGRAPixelTransparent;
      Inc(p);
    end;
  end;
  Result.InvalidateBitmap;
end;

{ 元素解析 }

function GetAttr(Node: TDOMElement; const AName: string): string;
begin
  Result := string(Node.GetAttribute(DOMString(AName)));
end;

function HasAttr(Node: TDOMElement; const AName: string): Boolean;
begin
  Result := Node.HasAttribute(DOMString(AName));
end;

// 拆分按钮精灵表（对应 SkinParser::splitStates）。
// 不负责释放 Sheet；拆分成功时 Outs 为新位图，失败时 Outs 全部指向 Sheet。
procedure SplitStates(const ElementType: string; Sheet: TBGRABitmap;
  var Outs: array of TBGRABitmap; var StateCount: Integer);
var
  fixedStates, i: Integer;
begin
  AssignSingleState(Sheet, Outs, StateCount);
  if Sheet = nil then Exit;

  fixedStates := FixedButtonStateCount(ElementType);
  if fixedStates < 2 then Exit;

  if SplitByFixedStateCount(Sheet, fixedStates, Outs, StateCount) = fssFailed then
  begin
    // 拆分失败：保持整图单状态
    for i := 0 to 3 do Outs[i] := Sheet;
    StateCount := 1;
  end;
end;

// 解析单个皮肤元素（对应 SkinParser::parseElement）。
function ParseElement(Node: TDOMElement; Images: TSkinImageMap;
  const TransColor: TSkinColor): TSkinElement;
var
  elem: TSkinElement;
  full, thumbFull, whole, iconPixmap: TBGRABitmap;
  fixedStates, thumbStateCount, i: Integer;
  splitResult: TFixedStateSplitResult;
begin
  InitSkinElement(elem);
  elem.ElementType := string(Node.TagName);

  if HasAttr(Node, 'position') then
    elem.Position := ParsePositionStr(GetAttr(Node, 'position'));

  // 主图像（按钮精灵表或单图元素）
  if HasAttr(Node, 'image') then
  begin
    elem.ImageName := GetAttr(Node, 'image');
    if elem.ImageName <> '' then
    begin
      full := LoadAndProcess(Images, elem.ImageName, TransColor);
      if (full <> nil) and (not elem.Position.IsEmpty) and
         (FixedButtonStateCount(elem.ElementType) > 0) then
      begin
        // 按钮元素：将水平精灵表拆分为多个状态
        SplitStates(elem.ElementType, full, elem.StatePixmaps, elem.StateCount);
        if (elem.StatePixmaps[0] <> full) and
           RectLooksLikeSpriteSheetBounds(elem.Position, full) then
          elem.UseFrameSizeForBounds := True;
        // 拆分成功时状态图为新位图，原整图不再被引用，释放之；
        // 失败时整图就是 StatePixmaps[0]，所有权转移。
        if elem.StatePixmaps[0] <> full then
          full.Free;
      end
      else if full <> nil then
      begin
        // 非按钮元素（led、title、toolbar 等）：保留完整图像
        elem.StatePixmaps[0] := full;
        elem.StateCount := 1;
      end;
    end;
  end;

  if HasAttr(Node, 'hot_image') then
  begin
    elem.HotImageName := GetAttr(Node, 'hot_image');
    elem.HotPixmap := LoadAndProcess(Images, elem.HotImageName, TransColor);
  end;
  if HasAttr(Node, 'selected_image') then
  begin
    elem.SelectedImageName := GetAttr(Node, 'selected_image');
    elem.SelectedPixmap := LoadAndProcess(Images, elem.SelectedImageName, TransColor);
  end;
  if HasAttr(Node, 'buttons_image') then
  begin
    elem.ButtonsImageName := GetAttr(Node, 'buttons_image');
    elem.ButtonsPixmap := LoadAndProcess(Images, elem.ButtonsImageName, TransColor);
  end;
  if HasAttr(Node, 'icon') then
  begin
    elem.IconName := GetAttr(Node, 'icon');
    iconPixmap := LoadAndProcess(Images, elem.IconName, TransColor);
    if iconPixmap <> nil then
    begin
      for i := 0 to 3 do
        elem.StatePixmaps[i] := iconPixmap;
      elem.StateCount := 1;
    end;
  end;

  // 滑块图像解析
  if HasAttr(Node, 'thumb_image') then
  begin
    elem.ThumbImageName := GetAttr(Node, 'thumb_image');
    thumbFull := LoadAndProcess(Images, elem.ThumbImageName, TransColor);
    if thumbFull <> nil then
    begin
      fixedStates := FixedSliderThumbStateCount(elem.ElementType);
      thumbStateCount := 0;
      AssignSingleState(thumbFull, elem.ThumbPixmaps, thumbStateCount);
      if fixedStates >= 2 then
      begin
        whole := elem.ThumbPixmaps[0];
        splitResult := SplitByFixedStateCount(thumbFull, fixedStates,
          elem.ThumbPixmaps, thumbStateCount);
        if splitResult = fssFailed then
        begin
          for i := 0 to 3 do elem.ThumbPixmaps[i] := whole;
          thumbStateCount := 1;
        end
        else if whole <> elem.ThumbPixmaps[0] then
          whole.Free;
      end;
    end;
  end;
  if HasAttr(Node, 'bar_image') then
  begin
    elem.BarImageName := GetAttr(Node, 'bar_image');
    elem.BarPixmap := LoadAndProcess(Images, elem.BarImageName, TransColor);
  end;
  if HasAttr(Node, 'fill_image') then
  begin
    elem.FillImageName := GetAttr(Node, 'fill_image');
    elem.FillPixmap := LoadAndProcess(Images, elem.FillImageName, TransColor);
  end;
  if HasAttr(Node, 'vertical') then
    elem.Vertical := ParseBoolAttr(GetAttr(Node, 'vertical'));
  if HasAttr(Node, 'thumb_resize_center') then
    elem.ThumbResizeCenter := ToIntQt(GetAttr(Node, 'thumb_resize_center'));
  if HasAttr(Node, 'thumb_resize_tile') then
    elem.ThumbResizeTile := ParseBoolAttr(GetAttr(Node, 'thumb_resize_tile'));

  // 文本样式解析
  if HasAttr(Node, 'color') then
    elem.Color := ParseColorStr(GetAttr(Node, 'color'));
  if HasAttr(Node, 'bkgnd') then
    elem.BkgndColor := ParseColorStr(GetAttr(Node, 'bkgnd'));
  if HasAttr(Node, 'font') then
    elem.FontFamily := GetAttr(Node, 'font');
  if HasAttr(Node, 'font_size') then
    elem.FontSize := ToIntQt(GetAttr(Node, 'font_size'));
  if HasAttr(Node, 'align') then
    elem.Align := GetAttr(Node, 'align');
  if HasAttr(Node, 'left_top_color') then
    elem.LeftTopColor := ParseColorStr(GetAttr(Node, 'left_top_color'));
  if HasAttr(Node, 'right_bottom_color') then
    elem.RightBottomColor := ParseColorStr(GetAttr(Node, 'right_bottom_color'));

  Result := elem;
end;

// 解析窗口节点的所有子元素（对应 SkinParser::parseWindow）。
procedure ParseWindowChildren(Node: TDOMElement; var Window: TSkinWindow;
  Images: TSkinImageMap; const TransColor: TSkinColor);
var
  child: TDOMNode;
  n: Integer;
begin
  child := Node.FirstChild;
  while child <> nil do
  begin
    if child.NodeType = ELEMENT_NODE then
    begin
      n := Length(Window.Elements);
      SetLength(Window.Elements, n + 1);
      Window.Elements[n] := ParseElement(TDOMElement(child), Images, TransColor);
    end;
    child := child.NextSibling;
  end;
end;

// 遍历文档中所有元素节点（对应 QXmlStreamReader 顺序遍历任意深度的行为）。
type
  TElementProc = procedure(Node: TDOMElement; Data: TObject);

procedure ForEachElement(Root: TDOMNode; Callback: TObject; Proc: TElementProc);
var
  node: TDOMNode;
begin
  node := Root;
  while node <> nil do
  begin
    if node.NodeType = ELEMENT_NODE then
      Proc(TDOMElement(node), Callback);
    if node.FirstChild <> nil then
      node := node.FirstChild
    else
    begin
      while (node <> nil) and (node <> Root) and (node.NextSibling = nil) do
        node := node.ParentNode;
      if (node = nil) or (node = Root) then Break;
      node := node.NextSibling;
    end;
  end;
end;

function TryReadXml(const XmlContent: string; out Doc: TXMLDocument): Boolean;
var
  stream: TStringStream;
begin
  Doc := nil;
  Result := False;
  if Trim(XmlContent) = '' then Exit;
  stream := TStringStream.Create(XmlContent, TEncoding.UTF8, False);
  try
    try
      ReadXMLFile(Doc, stream);
      Result := Doc <> nil;
    except
      FreeAndNil(Doc);
      Result := False;
    end;
  finally
    stream.Free;
  end;
end;

// 截掉根元素闭合之后的多余内容（对应 truncateXmlAfterRoot），
// 兼容一类结尾带垃圾数据的老皮肤 XML。
function TruncateXmlAfterRoot(const XmlContent: string): string;
var
  text, rootName, closeTag: string;
  p, tagStart, tagEnd, lastClose: Integer;
begin
  text := Trim(XmlContent);
  Result := text;

  // 找到第一个非声明/注释的开始标签，取其名字
  p := 1;
  rootName := '';
  while p <= Length(text) do
  begin
    tagStart := PosEx('<', text, p);
    if tagStart <= 0 then Exit;
    if (Copy(text, tagStart, 2) = '<?') or (Copy(text, tagStart, 4) = '<!--') or
       (Copy(text, tagStart, 2) = '<!') then
    begin
      tagEnd := PosEx('>', text, tagStart + 1);
      if tagEnd <= 0 then Exit;
      p := tagEnd + 1;
      Continue;
    end;
    tagEnd := tagStart + 1;
    while (tagEnd <= Length(text)) and not (text[tagEnd] in [' ', #9, #10, #13, '>', '/']) do
      Inc(tagEnd);
    rootName := Copy(text, tagStart + 1, tagEnd - tagStart - 1);
    Break;
  end;
  if rootName = '' then Exit;

  closeTag := '</' + rootName + '>';
  // 大小写不敏感地找最后一个闭合标签
  lastClose := LowerCase(text).LastIndexOf(LowerCase(closeTag)) + 1;
  if lastClose <= 0 then Exit;

  Result := Trim(Copy(text, 1, lastClose + Length(closeTag) - 1));
end;

type
  TSkinParseContext = class
    Skin: ^TSkinData;
    Images: TSkinImageMap;
  end;

procedure HandleSkinNode(Node: TDOMElement; Data: TObject);
var
  ctx: TSkinParseContext;
  name: string;
  wnd: ^TSkinWindow;
begin
  ctx := TSkinParseContext(Data);
  name := string(Node.TagName);

  if name = 'skin' then
  begin
    ctx.Skin^.Version := ToIntQt(GetAttr(Node, 'version'));
    ctx.Skin^.Name := GetAttr(Node, 'name');
    ctx.Skin^.Author := GetAttr(Node, 'author');
    ctx.Skin^.Url := GetAttr(Node, 'url');
    ctx.Skin^.Email := GetAttr(Node, 'email');
    if HasAttr(Node, 'transparent_color') then
      ctx.Skin^.TransparentColor := ParseColorStr(GetAttr(Node, 'transparent_color'));
    // 注意：Qt 版在无 transparent_color 属性时保留传入的默认值，此处已在 InitSkinData 设置
    Exit;
  end;

  wnd := nil;
  if name = 'player_window' then wnd := @ctx.Skin^.PlayerWindow
  else if name = 'mini_window' then wnd := @ctx.Skin^.MiniWindow
  else if name = 'lyric_window' then wnd := @ctx.Skin^.LyricWindow
  else if name = 'equalizer_window' then wnd := @ctx.Skin^.EqualizerWindow
  else if name = 'playlist_window' then wnd := @ctx.Skin^.PlaylistWindow;
  if wnd = nil then Exit;

  wnd^.WindowType := name;
  wnd^.BackgroundImageName := GetAttr(Node, 'image');
  wnd^.BackgroundPixmap := LoadAndProcess(ctx.Images, wnd^.BackgroundImageName,
    ctx.Skin^.TransparentColor);

  // lyric/equalizer/playlist 窗口的附加属性（player/mini 只有 image）
  if (name = 'lyric_window') or (name = 'equalizer_window') or
     (name = 'playlist_window') then
  begin
    if HasAttr(Node, 'position') then
      wnd^.DefaultPosition := ParsePositionStr(GetAttr(Node, 'position'));
  end;
  if (name = 'lyric_window') or (name = 'playlist_window') then
  begin
    if HasAttr(Node, 'resize_rect') then
      wnd^.ResizeRect := ParsePositionStr(GetAttr(Node, 'resize_rect'));
    if HasAttr(Node, 'resize_tile') then
      wnd^.ResizeTile := ToIntQt(GetAttr(Node, 'resize_tile')) <> 0;
  end;
  if name = 'equalizer_window' then
  begin
    if HasAttr(Node, 'eq_interval') then
      wnd^.EqInterval := ToIntQt(GetAttr(Node, 'eq_interval'));
  end;
  if name = 'playlist_window' then
  begin
    if HasAttr(Node, 'hilight') then
      wnd^.HilightColor := ParseColorStr(GetAttr(Node, 'hilight'));
  end;

  ParseWindowChildren(Node, wnd^, ctx.Images, ctx.Skin^.TransparentColor);
end;

function ParseSkinXml(const XmlContent: string; Images: TSkinImageMap;
  const DefaultTransColor: TSkinColor; var Skin: TSkinData): Boolean;
var
  doc: TXMLDocument;
  ctx: TSkinParseContext;
  content: string;
begin
  Result := False;
  FreeSkinData(Skin);
  InitSkinData(Skin);
  Skin.TransparentColor := DefaultTransColor;

  content := XmlContent;
  if not TryReadXml(content, doc) then
  begin
    // 对应 Qt 版"文档末尾有额外内容"时的截断重试
    content := TruncateXmlAfterRoot(content);
    if (content = XmlContent) or not TryReadXml(content, doc) then Exit;
  end;

  ctx := TSkinParseContext.Create;
  try
    ctx.Skin := @Skin;
    ctx.Images := Images;
    ForEachElement(doc.DocumentElement, ctx, @HandleSkinNode);
    Result := True;
  finally
    ctx.Free;
    doc.Free;
  end;
end;

{ 配置 XML 解析 }

procedure HandleLyricNode(Node: TDOMElement; Data: TObject);
var
  skin: ^TSkinData;
begin
  if string(Node.TagName) <> 'Lyric' then Exit;
  skin := Pointer(TSkinParseContext(Data).Skin);
  if HasAttr(Node, 'Font') then
    skin^.LyricConfig.Font := ParseLogFont(GetAttr(Node, 'Font'));
  if HasAttr(Node, 'TextColor') then
    skin^.LyricConfig.TextColor := ParseColorStr(GetAttr(Node, 'TextColor'));
  if HasAttr(Node, 'HilightColor') then
    skin^.LyricConfig.HilightColor := ParseColorStr(GetAttr(Node, 'HilightColor'));
  if HasAttr(Node, 'BkgndColor') then
    skin^.LyricConfig.BkgndColor := ParseColorStr(GetAttr(Node, 'BkgndColor'));
end;

procedure HandlePlaylistNode(Node: TDOMElement; Data: TObject);
var
  skin: ^TSkinData;
begin
  if string(Node.TagName) <> 'PlayList' then Exit;
  skin := Pointer(TSkinParseContext(Data).Skin);
  with skin^.PlaylistConfig do
  begin
    if HasAttr(Node, 'Font') then
    begin
      Font := ParseLogFont(GetAttr(Node, 'Font'));
      HasFont := True;
    end;
    if HasAttr(Node, 'Color_Text') then
    begin
      ColorText := ParseColorStr(GetAttr(Node, 'Color_Text'));
      HasColorText := True;
    end;
    if HasAttr(Node, 'Color_Hilight') then
    begin
      ColorHilight := ParseColorStr(GetAttr(Node, 'Color_Hilight'));
      HasColorHilight := True;
    end;
    if HasAttr(Node, 'Color_Bkgnd') then
    begin
      ColorBkgnd := ParseColorStr(GetAttr(Node, 'Color_Bkgnd'));
      HasColorBkgnd := True;
    end;
    if HasAttr(Node, 'Color_Number') then
    begin
      ColorNumber := ParseColorStr(GetAttr(Node, 'Color_Number'));
      HasColorNumber := True;
    end;
    if HasAttr(Node, 'Color_Duration') then
    begin
      ColorDuration := ParseColorStr(GetAttr(Node, 'Color_Duration'));
      HasColorDuration := True;
    end;
    if HasAttr(Node, 'Color_Select') then
    begin
      ColorSelect := ParseColorStr(GetAttr(Node, 'Color_Select'));
      HasColorSelect := True;
    end;
    if HasAttr(Node, 'Color_Bkgnd2') then
    begin
      ColorBkgnd2 := ParseColorStr(GetAttr(Node, 'Color_Bkgnd2'));
      HasColorBkgnd2 := True;
    end;
  end;
end;

procedure HandleVisualNode(Node: TDOMElement; Data: TObject);
var
  skin: ^TSkinData;
begin
  if string(Node.TagName) <> 'Visual' then Exit;
  skin := Pointer(TSkinParseContext(Data).Skin);
  with skin^.VisualConfig do
  begin
    if HasAttr(Node, 'SpectrumTopColor') then
      SpectrumTopColor := ParseColorStr(GetAttr(Node, 'SpectrumTopColor'));
    if HasAttr(Node, 'SpectrumBtmColor') then
      SpectrumBtmColor := ParseColorStr(GetAttr(Node, 'SpectrumBtmColor'));
    if HasAttr(Node, 'SpectrumMidColor') then
      SpectrumMidColor := ParseColorStr(GetAttr(Node, 'SpectrumMidColor'));
    if HasAttr(Node, 'SpectrumPeakColor') then
      SpectrumPeakColor := ParseColorStr(GetAttr(Node, 'SpectrumPeakColor'));
    if HasAttr(Node, 'BlurScopeColor') then
      BlurScopeColor := ParseColorStr(GetAttr(Node, 'BlurScopeColor'));
    if HasAttr(Node, 'TextColor') then
      TextColor := ParseColorStr(GetAttr(Node, 'TextColor'));
    if HasAttr(Node, 'Font') then
      Font := ParseLogFont(GetAttr(Node, 'Font'));
    if HasAttr(Node, 'SpectrumWide') then
      SpectrumWide := ToIntQt(GetAttr(Node, 'SpectrumWide'));
    if HasAttr(Node, 'BlurSpeed') then
      BlurSpeed := ToIntQt(GetAttr(Node, 'BlurSpeed'));
    if HasAttr(Node, 'Blur') then
      Blur := ParseBoolAttr(GetAttr(Node, 'Blur'));
    if HasAttr(Node, 'Type') then
      VisualType := ToIntQt(GetAttr(Node, 'Type'));
    if HasAttr(Node, 'FramesPerSec') then
      FramesPerSec := ToIntQt(GetAttr(Node, 'FramesPerSec'));
  end;
end;

procedure HandlePlayerLayoutNode(Node: TDOMElement; Data: TObject);
var
  skin: ^TSkinData;

  procedure ParseLayout(const AttrName: string; var Layout: TSkinWindowLayout);
  begin
    if not HasAttr(Node, AttrName) then Exit;
    Layout.Geometry := ParsePositionStr(GetAttr(Node, AttrName));
    Layout.HasGeometry := (Layout.Geometry.W > 0) and (Layout.Geometry.H > 0);
  end;

begin
  if string(Node.TagName) <> 'Player' then Exit;
  skin := Pointer(TSkinParseContext(Data).Skin);

  ParseLayout('PlayerWnd', skin^.LayoutConfig.PlayerWindow);
  ParseLayout('PlayerWnd2', skin^.LayoutConfig.MiniWindow);
  ParseLayout('LyricWnd', skin^.LayoutConfig.LyricWindow);
  ParseLayout('EqualizerWnd', skin^.LayoutConfig.EqualizerWindow);
  ParseLayout('PlayListWnd', skin^.LayoutConfig.PlaylistWindow);

  if HasAttr(Node, 'LyricVisible') then
  begin
    skin^.LayoutConfig.LyricWindow.Visible := ParseBoolAttr(GetAttr(Node, 'LyricVisible'));
    skin^.LayoutConfig.LyricWindow.HasVisible := True;
  end;
  if HasAttr(Node, 'EqualizerVisible') then
  begin
    skin^.LayoutConfig.EqualizerWindow.Visible := ParseBoolAttr(GetAttr(Node, 'EqualizerVisible'));
    skin^.LayoutConfig.EqualizerWindow.HasVisible := True;
  end;
  if HasAttr(Node, 'PlayListVisible') then
  begin
    skin^.LayoutConfig.PlaylistWindow.Visible := ParseBoolAttr(GetAttr(Node, 'PlayListVisible'));
    skin^.LayoutConfig.PlaylistWindow.HasVisible := True;
  end;
end;

procedure RunConfigParse(const XmlContent: string; var Skin: TSkinData;
  Proc: TElementProc);
var
  doc: TXMLDocument;
  ctx: TSkinParseContext;
begin
  if not TryReadXml(XmlContent, doc) then Exit;
  ctx := TSkinParseContext.Create;
  try
    ctx.Skin := @Skin;
    ctx.Images := nil;
    ForEachElement(doc.DocumentElement, ctx, Proc);
  finally
    ctx.Free;
    doc.Free;
  end;
end;

procedure ParseLyricXml(const XmlContent: string; var Skin: TSkinData);
begin
  RunConfigParse(XmlContent, Skin, @HandleLyricNode);
end;

procedure ParsePlaylistXml(const XmlContent: string; var Skin: TSkinData);
begin
  RunConfigParse(XmlContent, Skin, @HandlePlaylistNode);
end;

procedure ParseVisualXml(const XmlContent: string; var Skin: TSkinData);
begin
  RunConfigParse(XmlContent, Skin, @HandleVisualNode);
end;

procedure ParseSkinConfigXml(const XmlContent: string; var Skin: TSkinData);
begin
  RunConfigParse(XmlContent, Skin, @HandlePlayerLayoutNode);
end;

{ 播放列表配色推导（对应 SkinEngine.cpp 匿名命名空间 + resolvePlaylistTheme） }

function BlendColors(const A, B: TSkinColor; RatioToB: Double): TSkinColor;
var
  clamped, inv: Double;
begin
  clamped := RatioToB;
  if clamped < 0 then clamped := 0;
  if clamped > 1 then clamped := 1;
  inv := 1.0 - clamped;
  Result := TSkinColor.Make(
    Round(A.R * inv + B.R * clamped),
    Round(A.G * inv + B.G * clamped),
    Round(A.B * inv + B.B * clamped));
end;

function AdjustBrightness(const C: TSkinColor; Factor: Double): TSkinColor;

  function Scale(Channel: Integer): Integer;
  begin
    Result := Round(Channel * Factor);
    if Result < 0 then Result := 0;
    if Result > 255 then Result := 255;
  end;

begin
  Result := TSkinColor.Make(Scale(C.R), Scale(C.G), Scale(C.B));
end;

function ColorLuma(const C: TSkinColor): Integer;
begin
  Result := Round(C.R * 0.299 + C.G * 0.587 + C.B * 0.114);
end;

function ContrastingTextColor(const Background: TSkinColor): TSkinColor;
begin
  if ColorLuma(Background) >= 140 then
    Result := TSkinColor.Make($20, $20, $20)
  else
    Result := TSkinColor.Make($F2, $F2, $F2);
end;

// 计算位图区域内不透明像素的平均色（对应 averageOpaqueColor）。
function AverageOpaqueColor(Bitmap: TBGRABitmap; SampleRect: TSkinRect): TSkinColor;
var
  l, t, r, b, x, y: Integer;
  red, green, blue, count: Int64;
  p: PBGRAPixel;
begin
  Result := TSkinColor.Invalid;
  if Bitmap = nil then Exit;

  // QRect::isValid 语义：宽高 > 0 才有效；无效则取整图。
  if (SampleRect.W > 0) and (SampleRect.H > 0) then
  begin
    l := SampleRect.X; t := SampleRect.Y;
    r := SampleRect.X + SampleRect.W - 1; b := SampleRect.Y + SampleRect.H - 1;
    // intersected(image.rect())
    if l < 0 then l := 0;
    if t < 0 then t := 0;
    if r > Bitmap.Width - 1 then r := Bitmap.Width - 1;
    if b > Bitmap.Height - 1 then b := Bitmap.Height - 1;
  end
  else
  begin
    l := 0; t := 0; r := Bitmap.Width - 1; b := Bitmap.Height - 1;
  end;

  // sampleRect.width()>4 && height()>4 时向内缩 2px
  if ((r - l + 1) > 4) and ((b - t + 1) > 4) then
  begin
    Inc(l, 2); Inc(t, 2); Dec(r, 2); Dec(b, 2);
  end;
  // 缩完无效则回退整图
  if (l > r) or (t > b) then
  begin
    l := 0; t := 0; r := Bitmap.Width - 1; b := Bitmap.Height - 1;
  end;

  red := 0; green := 0; blue := 0; count := 0;
  for y := t to b do
  begin
    p := Bitmap.ScanLine[y];
    Inc(p, l);
    for x := l to r do
    begin
      if p^.alpha <> 0 then
      begin
        Inc(red, p^.red);
        Inc(green, p^.green);
        Inc(blue, p^.blue);
        Inc(count);
      end;
      Inc(p);
    end;
  end;

  if count = 0 then Exit;
  Result := TSkinColor.Make(red div count, green div count, blue div count);
end;

function InferPlaylistBackground(var Skin: TSkinData): TSkinColor;
var
  sampleRect: TSkinRect;
  playlistElem: PSkinElement;
begin
  Result := TSkinColor.Invalid;
  if Skin.PlaylistWindow.BackgroundPixmap = nil then Exit;

  sampleRect := TSkinRect.Zero;
  playlistElem := Skin.PlaylistWindow.FindElement('playlist');
  if playlistElem <> nil then
    sampleRect := playlistElem^.Position;
  Result := AverageOpaqueColor(Skin.PlaylistWindow.BackgroundPixmap, sampleRect);
end;

function InferPlaylistAccent(var Skin: TSkinData;
  const FallbackBackground: TSkinColor): TSkinColor;
var
  titleElem: PSkinElement;
  sampled, text: TSkinColor;
begin
  if Skin.PlaylistWindow.HilightColor.Valid then
    Exit(Skin.PlaylistWindow.HilightColor);

  titleElem := Skin.PlaylistWindow.FindElement('title');
  if titleElem <> nil then
  begin
    if titleElem^.Color.Valid then
      Exit(titleElem^.Color);
    sampled := AverageOpaqueColor(titleElem^.StatePixmaps[0], TSkinRect.Zero);
    if sampled.Valid then
      Exit(sampled);
  end;

  if FallbackBackground.Valid then
  begin
    text := ContrastingTextColor(FallbackBackground);
    Exit(BlendColors(text, FallbackBackground, 0.2));
  end;
  Result := TSkinColor.Invalid;
end;

procedure ResolvePlaylistTheme(var Skin: TSkinData);
var
  inferredBackground, background, accent, text, background2, select, number,
  duration: TSkinColor;
  factor: Double;
begin
  inferredBackground := InferPlaylistBackground(Skin);
  if Skin.PlaylistConfig.HasColorBkgnd then
    background := Skin.PlaylistConfig.ColorBkgnd
  else
    background := inferredBackground;
  if not background.Valid then
    background := Skin.PlaylistConfig.ColorBkgnd;

  if Skin.PlaylistConfig.HasColorHilight then
    accent := Skin.PlaylistConfig.ColorHilight
  else
    accent := InferPlaylistAccent(Skin, background);
  if not accent.Valid then
    accent := ContrastingTextColor(background);

  if Skin.PlaylistConfig.HasColorText then
    text := Skin.PlaylistConfig.ColorText
  else
    text := ContrastingTextColor(background);

  if Skin.PlaylistConfig.HasColorBkgnd2 then
    background2 := Skin.PlaylistConfig.ColorBkgnd2
  else
  begin
    if ColorLuma(background) >= 128 then
      factor := 0.92
    else
      factor := 1.08;
    background2 := AdjustBrightness(background, factor);
  end;

  if Skin.PlaylistConfig.HasColorSelect then
    select := Skin.PlaylistConfig.ColorSelect
  else
    select := BlendColors(background, accent, 0.42);

  if Skin.PlaylistConfig.HasColorNumber then
    number := Skin.PlaylistConfig.ColorNumber
  else
    number := BlendColors(text, accent, 0.30);

  if Skin.PlaylistConfig.HasColorDuration then
    duration := Skin.PlaylistConfig.ColorDuration
  else
    duration := BlendColors(text, accent, 0.55);

  Skin.PlaylistConfig.ColorBkgnd := background;
  Skin.PlaylistConfig.ColorBkgnd2 := background2;
  Skin.PlaylistConfig.ColorHilight := accent;
  Skin.PlaylistConfig.ColorText := text;
  Skin.PlaylistConfig.ColorSelect := select;
  Skin.PlaylistConfig.ColorNumber := number;
  Skin.PlaylistConfig.ColorDuration := duration;
end;

end.
