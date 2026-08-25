unit UPlayerConfig;

{$mode objfpc}{$H+}

// Qt 属性式 TTPlayer.xml 编解码（对应 src/app/Config.cpp）。
// 不经过 QSettings / TIniFile。控制台 FPCUnit 可对临时文件往返。

interface

uses
  Classes, SysUtils;

type
  TPlayerConfig = class
  public
    Volume: Integer;
    Muted: Boolean;
    Balance: Integer;

    EqEnabled: Boolean;
    EqPreamp: Double;
    EqBands: array[0..9] of Double;

    PlayerX, PlayerY, PlayerW, PlayerH: Integer;
    LyricX, LyricY, LyricW, LyricH: Integer;
    EqX, EqY, EqW, EqH: Integer;
    PlaylistX, PlaylistY, PlaylistW, PlaylistH: Integer;
    PlaylistSplitPos: Integer;

    LyricVisible: Boolean;
    EqVisible: Boolean;
    PlaylistVisible: Boolean;
    AlwaysOnTop: Boolean;

    SkinPath: string;
    RepeatMode: Integer;
    Shuffle: Boolean;
    LastFile: string;
    PlaylistDir: string;
    PlaylistCount: Integer;
    ActiveList: Integer;

    constructor Create;
    procedure ResetDefaults;
    function LoadFromFile(const FilePath: string): Boolean;
    function SaveToFile(const FilePath: string): Boolean;
  end;

function DefaultConfigPath(const ExeDir: string = ''): string;
function LegacyConfigPath: string;
function LoadPlayerConfig(Cfg: TPlayerConfig; const ExeDir: string): Boolean;
function SkinPackageNameFromSelection(const Selection: string): string;

implementation

uses
  StrUtils, LazFileUtils, laz2_DOM, laz2_XMLRead, laz2_XMLWrite;

function DotSettings: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function ParseIntAttr(const Value: string; Fallback: Integer): Integer;
begin
  Result := StrToIntDef(Trim(Value), Fallback);
end;

function ParseFloatAttr(const Value: string; Fallback: Double): Double;
begin
  if not TryStrToFloat(Trim(Value), Result, DotSettings) then
    Result := Fallback;
end;

function ParseBoolText(const Value: string; Fallback: Boolean): Boolean;
var
  t: string;
begin
  t := LowerCase(Trim(Value));
  if t = '' then Exit(Fallback);
  if (t = '1') or (t = 'true') or (t = 'yes') then Exit(True);
  if (t = '0') or (t = 'false') or (t = 'no') then Exit(False);
  Result := Fallback;
end;

function Fmt1(V: Double): string;
begin
  Result := FormatFloat('0.0', V, DotSettings);
end;

function RectToAttr(X, Y, W, H: Integer): string;
begin
  if W < 0 then W := 0;
  if H < 0 then H := 0;
  Result := Format('%d,%d,%d,%d', [X, Y, X + W, Y + H]);
end;

function ParseRectAttr(const Value: string; var X, Y, W, H: Integer;
  ApplyPos, ApplySize: Boolean): Boolean;
var
  parts: TStringList;
  x1, y1, x2, y2, nw, nh: Integer;
begin
  Result := False;
  parts := TStringList.Create;
  try
    parts.Delimiter := ',';
    parts.StrictDelimiter := True;
    parts.DelimitedText := Value;
    if parts.Count < 4 then Exit;
    x1 := ParseIntAttr(parts[0], 0);
    y1 := ParseIntAttr(parts[1], 0);
    x2 := ParseIntAttr(parts[2], x1);
    y2 := ParseIntAttr(parts[3], y1);
    nw := x2 - x1;
    nh := y2 - y1;
    if nw < 0 then nw := 0;
    if nh < 0 then nh := 0;
    if ApplyPos then
    begin
      X := x1;
      Y := y1;
    end;
    if ApplySize and (nw > 0) and (nh > 0) then
    begin
      W := nw;
      H := nh;
    end;
    Result := True;
  finally
    parts.Free;
  end;
end;

procedure DecodeEqualizerProfile(const Encoded: string; var Preamp: Double;
  var Bands: array of Double);
var
  colon, i: Integer;
  rest: string;
  parts: TStringList;
begin
  if Encoded = '' then Exit;
  colon := Pos(':', Encoded);
  if colon <= 0 then Exit;
  Preamp := ParseFloatAttr(Copy(Encoded, 1, colon - 1), Preamp);
  rest := Copy(Encoded, colon + 1, MaxInt);
  parts := TStringList.Create;
  try
    parts.Delimiter := ',';
    parts.StrictDelimiter := True;
    parts.DelimitedText := rest;
    for i := 0 to 9 do
      if i < parts.Count then
        Bands[i] := ParseFloatAttr(parts[i], Bands[i]);
  finally
    parts.Free;
  end;
end;

function EncodeEqualizerProfile(Preamp: Double; const Bands: array of Double): string;
var
  i: Integer;
begin
  Result := Fmt1(Preamp) + ':';
  for i := 0 to 9 do
  begin
    if i > 0 then
      Result := Result + ',';
    Result := Result + Fmt1(Bands[i]);
  end;
end;

function SkinPackageNameFromSelection(const Selection: string): string;
begin
  if (Selection = '') or
     (Selection = '__skin__:follow-original') or
     (Selection = '__skin__:builtin-default') then
    Exit('<Default_Skin>');
  if FileExists(Selection) or AnsiEndsText('.skn', Selection) then
    Result := ExtractFileName(Selection)
  else
    Result := Selection;
end;

function DefaultConfigPath(const ExeDir: string): string;
var
  dir: string;
begin
  dir := ExeDir;
  if dir = '' then
    dir := ExtractFilePath(ParamStr(0));
  Result := IncludeTrailingPathDelimiter(dir) + 'TTPlayer.xml';
end;

function LegacyConfigPath: string;
var
  base: string;
begin
  base := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if base = '' then
  begin
    {$IFDEF WINDOWS}
    base := GetEnvironmentVariable('LOCALAPPDATA');
    if base = '' then
      base := GetUserDir + 'AppData' + PathDelim + 'Local';
    {$ELSE}
    base := ExcludeTrailingPathDelimiter(GetUserDir) + PathDelim + '.config';
    {$ENDIF}
  end;
  Result := IncludeTrailingPathDelimiter(base) +
    'TTPlayerReborn' + PathDelim + 'TTPlayer Reborn' + PathDelim + 'TTPlayer.xml';
end;

function LoadPlayerConfig(Cfg: TPlayerConfig; const ExeDir: string): Boolean;
var
  primary, legacy: string;
begin
  Result := False;
  if Cfg = nil then Exit;
  primary := DefaultConfigPath(ExeDir);
  if FileExists(primary) then
    Result := Cfg.LoadFromFile(primary);
  if Result then Exit;
  legacy := LegacyConfigPath;
  if (legacy <> '') and (CompareFilenames(legacy, primary) <> 0) and FileExists(legacy) then
    Result := Cfg.LoadFromFile(legacy);
end;

constructor TPlayerConfig.Create;
begin
  inherited Create;
  ResetDefaults;
end;

procedure TPlayerConfig.ResetDefaults;
var
  i: Integer;
begin
  Volume := 80;
  Muted := False;
  Balance := 0;
  EqEnabled := False;
  EqPreamp := 0;
  for i := 0 to 9 do
    EqBands[i] := 0;
  PlayerX := 100; PlayerY := 100; PlayerW := 318; PlayerH := 188;
  LyricX := 100; LyricY := 400; LyricW := 290; LyricH := 116;
  EqX := 400; EqY := 100; EqW := 290; EqH := 148;
  PlaylistX := 400; PlaylistY := 400; PlaylistW := 290; PlaylistH := 116;
  PlaylistSplitPos := 55;
  LyricVisible := True;
  EqVisible := True;
  PlaylistVisible := True;
  AlwaysOnTop := False;
  SkinPath := '';
  RepeatMode := 2;
  Shuffle := False;
  LastFile := '';
  PlaylistDir := '';
  PlaylistCount := 1;
  ActiveList := 0;
end;

procedure LoadPlayerAttrs(Cfg: TPlayerConfig; El: TDOMElement);
begin
  if El.hasAttribute('PlayerWnd') then
    ParseRectAttr(El.GetAttribute('PlayerWnd'),
      Cfg.PlayerX, Cfg.PlayerY, Cfg.PlayerW, Cfg.PlayerH, True, True);
  if El.hasAttribute('LyricWnd') then
    ParseRectAttr(El.GetAttribute('LyricWnd'),
      Cfg.LyricX, Cfg.LyricY, Cfg.LyricW, Cfg.LyricH, True, True);
  if El.hasAttribute('EqualizerWnd') then
    ParseRectAttr(El.GetAttribute('EqualizerWnd'),
      Cfg.EqX, Cfg.EqY, Cfg.EqW, Cfg.EqH, True, True);
  if El.hasAttribute('PlayListWnd') then
    ParseRectAttr(El.GetAttribute('PlayListWnd'),
      Cfg.PlaylistX, Cfg.PlaylistY, Cfg.PlaylistW, Cfg.PlaylistH, True, True);

  if El.hasAttribute('LyricVisible') then
    Cfg.LyricVisible := ParseBoolText(El.GetAttribute('LyricVisible'), Cfg.LyricVisible);
  if El.hasAttribute('EqualizerVisible') then
    Cfg.EqVisible := ParseBoolText(El.GetAttribute('EqualizerVisible'), Cfg.EqVisible);
  if El.hasAttribute('PlayListVisible') then
    Cfg.PlaylistVisible := ParseBoolText(El.GetAttribute('PlayListVisible'), Cfg.PlaylistVisible);
  if El.hasAttribute('TopMost') then
    Cfg.AlwaysOnTop := ParseBoolText(El.GetAttribute('TopMost'), Cfg.AlwaysOnTop)
  else if El.hasAttribute('AlwaysOnTop') then
    Cfg.AlwaysOnTop := ParseBoolText(El.GetAttribute('AlwaysOnTop'), Cfg.AlwaysOnTop);

  if El.hasAttribute('PlayMode') then
    Cfg.RepeatMode := ParseIntAttr(El.GetAttribute('PlayMode'), Cfg.RepeatMode);
  if El.hasAttribute('Shuffle') then
    Cfg.Shuffle := ParseBoolText(El.GetAttribute('Shuffle'), Cfg.Shuffle);
  if El.hasAttribute('Volume') then
    Cfg.Volume := ParseIntAttr(El.GetAttribute('Volume'), Cfg.Volume);
  if El.hasAttribute('Mute') then
    Cfg.Muted := ParseBoolText(El.GetAttribute('Mute'), Cfg.Muted);
  if El.hasAttribute('Balance') then
    Cfg.Balance := ParseIntAttr(El.GetAttribute('Balance'), Cfg.Balance);
  if El.hasAttribute('PlayingFileName') then
  begin
    if Trim(El.GetAttribute('PlayingFileName')) <> '' then
      Cfg.LastFile := El.GetAttribute('PlayingFileName');
  end;
  if El.hasAttribute('SplitOnLists') then
    Cfg.PlaylistSplitPos := ParseIntAttr(El.GetAttribute('SplitOnLists'), Cfg.PlaylistSplitPos);
  if El.hasAttribute('PlayLists') then
  begin
    Cfg.PlaylistCount := ParseIntAttr(El.GetAttribute('PlayLists'), Cfg.PlaylistCount);
    if Cfg.PlaylistCount < 1 then Cfg.PlaylistCount := 1;
  end;
  if El.hasAttribute('ActiveList') then
  begin
    Cfg.ActiveList := ParseIntAttr(El.GetAttribute('ActiveList'), Cfg.ActiveList);
    if Cfg.ActiveList < 0 then Cfg.ActiveList := 0;
  end;
end;

procedure LoadChildValue(Cfg: TPlayerConfig; const Section: string; El: TDOMElement);
var
  tag, text: string;
  idx: Integer;
begin
  tag := El.TagName;
  text := Trim(El.TextContent);
  if SameText(Section, 'Player') then
  begin
    if tag = 'Volume' then Cfg.Volume := ParseIntAttr(text, Cfg.Volume)
    else if tag = 'Mute' then Cfg.Muted := ParseBoolText(text, Cfg.Muted)
    else if tag = 'Balance' then Cfg.Balance := ParseIntAttr(text, Cfg.Balance)
    else if tag = 'PlayerX' then Cfg.PlayerX := ParseIntAttr(text, Cfg.PlayerX)
    else if tag = 'PlayerY' then Cfg.PlayerY := ParseIntAttr(text, Cfg.PlayerY)
    else if tag = 'LyricX' then Cfg.LyricX := ParseIntAttr(text, Cfg.LyricX)
    else if tag = 'LyricY' then Cfg.LyricY := ParseIntAttr(text, Cfg.LyricY)
    else if tag = 'EqX' then Cfg.EqX := ParseIntAttr(text, Cfg.EqX)
    else if tag = 'EqY' then Cfg.EqY := ParseIntAttr(text, Cfg.EqY)
    else if tag = 'PlayListX' then Cfg.PlaylistX := ParseIntAttr(text, Cfg.PlaylistX)
    else if tag = 'PlayListY' then Cfg.PlaylistY := ParseIntAttr(text, Cfg.PlaylistY)
    else if tag = 'SplitOnLists' then Cfg.PlaylistSplitPos := ParseIntAttr(text, Cfg.PlaylistSplitPos)
    else if tag = 'LyricVisible' then Cfg.LyricVisible := ParseBoolText(text, Cfg.LyricVisible)
    else if tag = 'EqVisible' then Cfg.EqVisible := ParseBoolText(text, Cfg.EqVisible)
    else if tag = 'PlayListVisible' then Cfg.PlaylistVisible := ParseBoolText(text, Cfg.PlaylistVisible)
    else if tag = 'AlwaysOnTop' then Cfg.AlwaysOnTop := ParseBoolText(text, Cfg.AlwaysOnTop)
    else if tag = 'LastFile' then Cfg.LastFile := text;
  end
  else if SameText(Section, 'Playback') then
  begin
    if tag = 'RepeatMode' then Cfg.RepeatMode := ParseIntAttr(text, Cfg.RepeatMode)
    else if tag = 'Shuffle' then Cfg.Shuffle := ParseBoolText(text, Cfg.Shuffle);
  end
  else if SameText(Section, 'Equalizer') then
  begin
    if tag = 'Enabled' then Cfg.EqEnabled := ParseBoolText(text, Cfg.EqEnabled)
    else if tag = 'Preamp' then Cfg.EqPreamp := ParseFloatAttr(text, Cfg.EqPreamp)
    else if (Length(tag) >= 5) and (Copy(tag, 1, 4) = 'Band') then
    begin
      idx := StrToIntDef(Copy(tag, 5, 8), -1);
      if (idx >= 0) and (idx <= 9) then
        Cfg.EqBands[idx] := ParseFloatAttr(text, Cfg.EqBands[idx]);
    end;
  end
  else if SameText(Section, 'Skin') then
  begin
    if (tag = 'Path') or (tag = 'PackageName') then
      if text <> '' then Cfg.SkinPath := text;
  end;
end;

procedure LoadSection(Cfg: TPlayerConfig; El: TDOMElement);
var
  tag: string;
  child: TDOMNode;
  i: Integer;
begin
  tag := El.TagName;
  if SameText(tag, 'Player') and (El.Attributes.Length > 0) then
    LoadPlayerAttrs(Cfg, El)
  else if SameText(tag, 'Playback') and (El.Attributes.Length > 0) then
  begin
    if El.hasAttribute('RepeatMode') then
      Cfg.RepeatMode := ParseIntAttr(El.GetAttribute('RepeatMode'), Cfg.RepeatMode);
    if El.hasAttribute('Shuffle') then
      Cfg.Shuffle := ParseBoolText(El.GetAttribute('Shuffle'), Cfg.Shuffle);
  end
  else if SameText(tag, 'Equalizer') and (El.Attributes.Length > 0) then
  begin
    if El.hasAttribute('Current') then
      DecodeEqualizerProfile(El.GetAttribute('Current'), Cfg.EqPreamp, Cfg.EqBands)
    else if El.hasAttribute('Custom') then
      DecodeEqualizerProfile(El.GetAttribute('Custom'), Cfg.EqPreamp, Cfg.EqBands);
    if El.hasAttribute('Enabled') then
      Cfg.EqEnabled := ParseBoolText(El.GetAttribute('Enabled'), Cfg.EqEnabled);
    if El.hasAttribute('Preamp') then
      Cfg.EqPreamp := ParseFloatAttr(El.GetAttribute('Preamp'), Cfg.EqPreamp);
    for i := 0 to 9 do
      if El.hasAttribute('Band' + IntToStr(i)) then
        Cfg.EqBands[i] := ParseFloatAttr(El.GetAttribute('Band' + IntToStr(i)), Cfg.EqBands[i]);
  end
  else if SameText(tag, 'Histroy') and (El.Attributes.Length > 0) then
  begin
    if El.hasAttribute('SplitOnLists') then
      Cfg.PlaylistSplitPos := ParseIntAttr(El.GetAttribute('SplitOnLists'), Cfg.PlaylistSplitPos);
    if El.hasAttribute('PlayListPath') then
      Cfg.PlaylistDir := El.GetAttribute('PlayListPath');
  end
  else if SameText(tag, 'Skin') and (El.Attributes.Length > 0) then
  begin
    if Trim(El.GetAttribute('Path')) <> '' then
      Cfg.SkinPath := El.GetAttribute('Path')
    else if El.GetAttribute('PackageName') = '<Default_Skin>' then
      Cfg.SkinPath := '__skin__:builtin-default'
    else if Trim(El.GetAttribute('PackageName')) <> '' then
      Cfg.SkinPath := El.GetAttribute('PackageName');
  end;

  child := El.FirstChild;
  while child <> nil do
  begin
    if child is TDOMElement then
      LoadChildValue(Cfg, tag, TDOMElement(child));
    child := child.NextSibling;
  end;
end;

function TPlayerConfig.LoadFromFile(const FilePath: string): Boolean;
var
  doc: TXMLDocument;
  child: TDOMNode;
begin
  Result := False;
  if not FileExists(FilePath) then Exit;
  doc := nil;
  try
    ReadXMLFile(doc, FilePath);
    if (doc = nil) or (doc.DocumentElement = nil) then Exit;
    child := doc.DocumentElement.FirstChild;
    while child <> nil do
    begin
      if child is TDOMElement then
        LoadSection(Self, TDOMElement(child));
      child := child.NextSibling;
    end;
    Result := True;
  except
    Result := False;
  end;
  doc.Free;
end;

procedure SetAttr(El: TDOMElement; const Name, Value: string);
begin
  El.SetAttribute(Name, Value);
end;

function Bool01(V: Boolean): string;
begin
  if V then Result := '1' else Result := '0';
end;

function TPlayerConfig.SaveToFile(const FilePath: string): Boolean;
var
  doc: TXMLDocument;
  root, el: TDOMElement;
  dir, profile: string;
  i: Integer;
begin
  Result := False;
  dir := ExtractFilePath(FilePath);
  if (dir <> '') and (not DirectoryExists(dir)) then
    if not ForceDirectories(dir) then Exit;

  profile := EncodeEqualizerProfile(EqPreamp, EqBands);
  doc := TXMLDocument.Create;
  try
    root := doc.CreateElement('ttplayer');
    SetAttr(root, 'version', '5.7.9');
    doc.AppendChild(root);

    el := doc.CreateElement('Player');
    SetAttr(el, 'PlayerWnd', RectToAttr(PlayerX, PlayerY, PlayerW, PlayerH));
    SetAttr(el, 'PlayerWnd2', '0,0,0,0');
    SetAttr(el, 'LyricWnd', RectToAttr(LyricX, LyricY, LyricW, LyricH));
    SetAttr(el, 'LyricWnd2', '0,0,0,0');
    SetAttr(el, 'EqualizerWnd', RectToAttr(EqX, EqY, EqW, EqH));
    SetAttr(el, 'PlayListWnd', RectToAttr(PlaylistX, PlaylistY, PlaylistW, PlaylistH));
    SetAttr(el, 'LyricVisible', Bool01(LyricVisible));
    SetAttr(el, 'EqualizerVisible', Bool01(EqVisible));
    SetAttr(el, 'PlayListVisible', Bool01(PlaylistVisible));
    SetAttr(el, 'MiniMode', '0');
    SetAttr(el, 'DesklrcWnd', '0,0,0,0');
    SetAttr(el, 'TopMost', Bool01(AlwaysOnTop));
    SetAttr(el, 'PlayMode', IntToStr(RepeatMode));
    SetAttr(el, 'Shuffle', Bool01(Shuffle));
    SetAttr(el, 'PlayLists', IntToStr(PlaylistCount));
    SetAttr(el, 'ActiveList', IntToStr(ActiveList));
    SetAttr(el, 'PlayingFileName', LastFile);
    SetAttr(el, 'Mute', Bool01(Muted));
    SetAttr(el, 'Volume', IntToStr(Volume));
    SetAttr(el, 'Balance', IntToStr(Balance));
    SetAttr(el, 'SplitOnLists', IntToStr(PlaylistSplitPos));
    root.AppendChild(el);

    el := doc.CreateElement('Playback');
    SetAttr(el, 'RepeatMode', IntToStr(RepeatMode));
    SetAttr(el, 'Shuffle', Bool01(Shuffle));
    root.AppendChild(el);

    el := doc.CreateElement('Equalizer');
    SetAttr(el, 'Profile', '-2');
    SetAttr(el, 'Custom', profile);
    SetAttr(el, 'Current', profile);
    SetAttr(el, 'Enabled', Bool01(EqEnabled));
    SetAttr(el, 'Preamp', Fmt1(EqPreamp));
    for i := 0 to 9 do
      SetAttr(el, 'Band' + IntToStr(i), Fmt1(EqBands[i]));
    root.AppendChild(el);

    el := doc.CreateElement('Skin');
    SetAttr(el, 'PackageName', SkinPackageNameFromSelection(SkinPath));
    SetAttr(el, 'Path', SkinPath);
    root.AppendChild(el);

    el := doc.CreateElement('Histroy');
    SetAttr(el, 'SplitOnLists', IntToStr(PlaylistSplitPos));
    SetAttr(el, 'PlayListPath', PlaylistDir);
    root.AppendChild(el);

    WriteXMLFile(doc, FilePath);
    Result := FileExists(FilePath);
  except
    Result := False;
  end;
  doc.Free;
end;

end.
