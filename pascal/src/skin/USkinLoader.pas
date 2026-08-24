unit USkinLoader;

{$mode objfpc}{$H+}

// 皮肤加载器，对应 Qt 版 src/skin/SkinEngine.cpp。
// 负责：.skn（zip）解包、图片资源加载、XML 文本编码探测与老皮肤容错清洗、
// 各配置 XML 的加载顺序编排。

interface

uses
  Classes, SysUtils, USkinTypes, USkinXmlParser;

type
  TSkinEngine = class
  private
    FSkin: TSkinData;
    FLoaded: Boolean;
    function LoadImages(const DirPath: string; Images: TSkinImageMap): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    // 从 .skn 文件（zip 包）加载皮肤。
    function LoadFromFile(const SknPath: string): Boolean;
    // 从已解压皮肤目录加载。
    function LoadFromDirectory(const DirPath: string): Boolean;
    // 加载侧车布局 XML（Default.xml / <皮肤>.skn.xml）。
    function LoadSkinConfigXml(const XmlPath: string): Boolean;
    // 指向内部 TSkinData：窗体须持有此指针，不能对 SkinData 属性取址
    //（属性返回副本，ApplySkin(const TSkinData) 的 @ASkin 会悬空）。
    function SkinPtr: PSkinData;

    property SkinData: TSkinData read FSkin;
    property Loaded: Boolean read FLoaded;
  end;

// 读取 XML 文本：编码探测（UTF-8 BOM → UTF-8 → 系统 ANSI → GB18030 兜底）
// + 老皮肤 XML 清洗。对应 SkinEngine.cpp 的 loadXmlText + sanitizeLegacyXml。
function LoadXmlText(const Path: string): string;

// 老皮肤 XML 清洗（公开供单测）。
function SanitizeLegacyXml(const Xml: string): string;

implementation

uses
  StrUtils, Character, LazUTF8, LConvEncoding, Zipper, FileUtil, LazFileUtils,
  BGRABitmap, FPImage, BGRAReadBMP, BGRAReadPng, BGRAReadJpeg;

{ XML 清洗：对应 SkinEngine.cpp 匿名命名空间的 sanitize 系列函数 }

function IsXmlNameStart(C: WideChar): Boolean;
begin
  Result := (C = '_') or (C = ':') or TCharacter.IsLetter(C);
end;

function IsXmlNameChar(C: WideChar): Boolean;
begin
  Result := IsXmlNameStart(C) or TCharacter.IsDigit(C) or (C = '-') or
    (C = '.') or (C = '_');
end;

// 去除 XML 1.0 规范不允许的控制字符。
function StripInvalidXml10Chars(const Xml: UnicodeString): UnicodeString;
var
  sb: UnicodeString;
  i, n: Integer;
  code: Word;
begin
  SetLength(sb, Length(Xml));
  n := 0;
  for i := 1 to Length(Xml) do
  begin
    code := Ord(Xml[i]);
    if (code = $0009) or (code = $000A) or (code = $000D) or
       ((code >= $0020) and (code <= $D7FF)) or
       ((code >= $E000) and (code <= $FFFD)) then
    begin
      Inc(n);
      sb[n] := Xml[i];
    end;
  end;
  Result := Copy(sb, 1, n);
end;

// 把属性值内的裸 & 转义为 &amp;（对应 escapeBareAmpersands 的意图，
// 在标签规范化后统一执行，作用于整个文本的属性值区间之外也安全，
// 因为规范化输出的属性值已完全转义，此处只处理残余文本节点）。
function EscapeBareAmpersands(const Xml: UnicodeString): UnicodeString;
var
  i, n, j: Integer;
  entity: UnicodeString;
  isEntity: Boolean;
begin
  Result := '';
  n := Length(Xml);
  i := 1;
  while i <= n do
  begin
    if Xml[i] = '&' then
    begin
      // 检查是否已是合法实体引用
      j := i + 1;
      entity := '';
      while (j <= n) and (j - i <= 10) and (Xml[j] <> ';') do
      begin
        entity := entity + Xml[j];
        Inc(j);
      end;
      isEntity := (j <= n) and (Xml[j] = ';') and
        ((entity = 'amp') or (entity = 'lt') or (entity = 'gt') or
         (entity = 'quot') or (entity = 'apos') or
         ((Length(entity) > 1) and (entity[1] = '#')));
      if isEntity then
        Result := Result + '&'
      else
        Result := Result + '&amp;';
    end
    else
      Result := Result + Xml[i];
    Inc(i);
  end;
end;

function EscapeXmlAttributeValue(const Value: UnicodeString): UnicodeString;
begin
  Result := Value;
  Result := UnicodeStringReplace(Result, '&', '&amp;', [rfReplaceAll]);
  Result := UnicodeStringReplace(Result, '"', '&quot;', [rfReplaceAll]);
  Result := UnicodeStringReplace(Result, '''', '&apos;', [rfReplaceAll]);
  Result := UnicodeStringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := UnicodeStringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

type
  TXmlTagInfo = record
    Parsed: Boolean;
    IsStart: Boolean;
    IsEnd: Boolean;
    SelfClosing: Boolean;
    Name: UnicodeString;
  end;

function ParseXmlTagInfo(const RawTag: UnicodeString): TXmlTagInfo;
var
  inner: UnicodeString;
  cursor: Integer;
begin
  Result := Default(TXmlTagInfo);
  if (Length(RawTag) < 2) or (RawTag[1] <> '<') or
     (RawTag[Length(RawTag)] <> '>') then Exit;

  inner := Trim(Copy(RawTag, 2, Length(RawTag) - 2));
  if (inner = '') or (inner[1] = '?') or (inner[1] = '!') then Exit;

  if inner[1] = '/' then
  begin
    Result.IsEnd := True;
    inner := Trim(Copy(inner, 2, MaxInt));
  end
  else
  begin
    Result.IsStart := True;
    if (inner <> '') and (inner[Length(inner)] = '/') then
    begin
      Result.SelfClosing := True;
      inner := Trim(Copy(inner, 1, Length(inner) - 1));
    end;
  end;

  if (inner = '') or not IsXmlNameStart(inner[1]) then
  begin
    Result := Default(TXmlTagInfo);
    Exit;
  end;

  cursor := 2;
  while (cursor <= Length(inner)) and IsXmlNameChar(inner[cursor]) do
    Inc(cursor);
  Result.Name := Copy(inner, 1, cursor - 1);
  Result.Parsed := Result.Name <> '';
end;

// 规范化老式开始标签：属性值统一双引号并转义、去重属性（对应 normalizeLegacyStartTag）。
function NormalizeLegacyStartTag(const RawTag: UnicodeString): UnicodeString;
type
  TParsedAttr = record
    Name: UnicodeString;
    Value: UnicodeString;
  end;
var
  inner, content, tagName, attrName, attrValue: UnicodeString;
  selfClosing: Boolean;
  cursor, tagStart, attrStart, valueStart, i, existing: Integer;
  quote: WideChar;
  attrs: array of TParsedAttr;
  lowerName: UnicodeString;
begin
  Result := RawTag;
  if (Length(RawTag) < 2) or (RawTag[1] <> '<') or
     (RawTag[Length(RawTag)] <> '>') then Exit;

  inner := Copy(RawTag, 2, Length(RawTag) - 2);
  content := Trim(inner);
  if (content = '') or (content[1] = '/') or (content[1] = '?') or
     (content[1] = '!') then Exit;

  selfClosing := False;
  if content[Length(content)] = '/' then
  begin
    selfClosing := True;
    content := Trim(Copy(content, 1, Length(content) - 1));
  end;

  cursor := 1;
  while (cursor <= Length(content)) and (content[cursor] = ' ') do Inc(cursor);
  tagStart := cursor;
  if (tagStart > Length(content)) or not IsXmlNameStart(content[tagStart]) then Exit;
  Inc(cursor);
  while (cursor <= Length(content)) and IsXmlNameChar(content[cursor]) do Inc(cursor);
  tagName := Copy(content, tagStart, cursor - tagStart);
  if tagName = '' then Exit;

  attrs := nil;
  while cursor <= Length(content) do
  begin
    while (cursor <= Length(content)) and
          (content[cursor] in [WideChar(' '), WideChar(#9), WideChar(#10), WideChar(#13)]) do
      Inc(cursor);
    if cursor > Length(content) then Break;
    if not IsXmlNameStart(content[cursor]) then
    begin
      Inc(cursor);
      Continue;
    end;

    attrStart := cursor;
    Inc(cursor);
    while (cursor <= Length(content)) and IsXmlNameChar(content[cursor]) do Inc(cursor);
    attrName := Copy(content, attrStart, cursor - attrStart);
    while (cursor <= Length(content)) and
          (content[cursor] in [WideChar(' '), WideChar(#9), WideChar(#10), WideChar(#13)]) do
      Inc(cursor);

    attrValue := '';
    if (cursor <= Length(content)) and (content[cursor] = '=') then
    begin
      Inc(cursor);
      while (cursor <= Length(content)) and
            (content[cursor] in [WideChar(' '), WideChar(#9), WideChar(#10), WideChar(#13)]) do
        Inc(cursor);

      if (cursor <= Length(content)) and
         ((content[cursor] = '"') or (content[cursor] = '''')) then
      begin
        quote := content[cursor];
        Inc(cursor);
        valueStart := cursor;
        while (cursor <= Length(content)) and (content[cursor] <> quote) do
          Inc(cursor);
        attrValue := Copy(content, valueStart, cursor - valueStart);
        if (cursor <= Length(content)) and (content[cursor] = quote) then
          Inc(cursor);
      end
      else
      begin
        valueStart := cursor;
        while (cursor <= Length(content)) and
              not (content[cursor] in [WideChar(' '), WideChar(#9), WideChar(#10),
                   WideChar(#13), WideChar('>'), WideChar('/')]) do
          Inc(cursor);
        attrValue := Copy(content, valueStart, cursor - valueStart);
      end;
    end;

    // trimAttributeQuotes：去除首尾残余引号
    attrValue := Trim(attrValue);
    while (attrValue <> '') and ((attrValue[1] = '"') or (attrValue[1] = '''')) do
      Delete(attrValue, 1, 1);
    while (attrValue <> '') and
          ((attrValue[Length(attrValue)] = '"') or (attrValue[Length(attrValue)] = '''')) do
      Delete(attrValue, Length(attrValue), 1);
    attrValue := Trim(attrValue);

    // 属性去重（大小写不敏感）；空值可被后续非空值覆盖
    lowerName := LowerCase(attrName);
    existing := -1;
    for i := 0 to High(attrs) do
      if LowerCase(attrs[i].Name) = lowerName then
      begin
        existing := i;
        Break;
      end;
    if existing < 0 then
    begin
      SetLength(attrs, Length(attrs) + 1);
      attrs[High(attrs)].Name := attrName;
      attrs[High(attrs)].Value := attrValue;
    end
    else if (attrs[existing].Value = '') and (attrValue <> '') then
      attrs[existing].Value := attrValue;
  end;

  Result := '<' + tagName;
  for i := 0 to High(attrs) do
    Result := Result + ' ' + attrs[i].Name + '="' +
      EscapeXmlAttributeValue(attrs[i].Value) + '"';
  if selfClosing then
    Result := Result + ' /';
  Result := Result + '>';
end;

// 规范化整个文档的标签（对应 normalizeLegacyXmlTags）：
// 逐标签重写开始标签，并修正大小写不匹配的闭合标签。
function NormalizeLegacyXmlTags(const Xml: UnicodeString): UnicodeString;
var
  normalized, rawTag, normalizedTag, expected: UnicodeString;
  openTagStack: array of UnicodeString;
  cursor, tagStart, tagEnd: Integer;
  rawInfo, normalizedInfo: TXmlTagInfo;

  procedure PushTag(const AName: UnicodeString);
  begin
    SetLength(openTagStack, Length(openTagStack) + 1);
    openTagStack[High(openTagStack)] := AName;
  end;

  procedure PopTag;
  begin
    SetLength(openTagStack, Length(openTagStack) - 1);
  end;

begin
  normalized := '';
  openTagStack := nil;
  cursor := 1;
  while cursor <= Length(Xml) do
  begin
    tagStart := PosEx('<', Xml, cursor);
    if tagStart <= 0 then
    begin
      normalized := normalized + Copy(Xml, cursor, MaxInt);
      Break;
    end;

    normalized := normalized + Copy(Xml, cursor, tagStart - cursor);
    if Copy(Xml, tagStart, 4) = '<!--' then
    begin
      tagEnd := PosEx('-->', Xml, tagStart + 4);
      if tagEnd <= 0 then
      begin
        normalized := normalized + Copy(Xml, tagStart, MaxInt);
        Break;
      end;
      normalized := normalized + Copy(Xml, tagStart, tagEnd - tagStart + 3);
      cursor := tagEnd + 3;
      Continue;
    end;
    if Copy(Xml, tagStart, 9) = '<![CDATA[' then
    begin
      tagEnd := PosEx(']]>', Xml, tagStart + 9);
      if tagEnd <= 0 then
      begin
        normalized := normalized + Copy(Xml, tagStart, MaxInt);
        Break;
      end;
      normalized := normalized + Copy(Xml, tagStart, tagEnd - tagStart + 3);
      cursor := tagEnd + 3;
      Continue;
    end;
    if Copy(Xml, tagStart, 2) = '<?' then
    begin
      tagEnd := PosEx('?>', Xml, tagStart + 2);
      if tagEnd <= 0 then
      begin
        normalized := normalized + Copy(Xml, tagStart, MaxInt);
        Break;
      end;
      normalized := normalized + Copy(Xml, tagStart, tagEnd - tagStart + 2);
      cursor := tagEnd + 2;
      Continue;
    end;

    tagEnd := PosEx('>', Xml, tagStart + 1);
    if tagEnd <= 0 then
    begin
      normalized := normalized + Copy(Xml, tagStart, MaxInt);
      Break;
    end;

    rawTag := Copy(Xml, tagStart, tagEnd - tagStart + 1);
    rawInfo := ParseXmlTagInfo(rawTag);
    if rawInfo.Parsed and rawInfo.IsEnd then
    begin
      if Length(openTagStack) > 0 then
      begin
        expected := openTagStack[High(openTagStack)];
        if LowerCase(rawInfo.Name) = LowerCase(expected) then
        begin
          PopTag;
          if rawInfo.Name = expected then
            normalized := normalized + rawTag
          else
            normalized := normalized + '</' + expected + '>';
        end
        else
          normalized := normalized + rawTag;
      end
      else
        normalized := normalized + rawTag;
      cursor := tagEnd + 1;
      Continue;
    end;

    normalizedTag := NormalizeLegacyStartTag(rawTag);
    normalized := normalized + normalizedTag;

    normalizedInfo := ParseXmlTagInfo(normalizedTag);
    if normalizedInfo.Parsed and normalizedInfo.IsStart and
       not normalizedInfo.SelfClosing then
      PushTag(normalizedInfo.Name);
    cursor := tagEnd + 1;
  end;

  Result := normalized;
end;

function SanitizeLegacyXml(const Xml: string): string;
var
  u: UnicodeString;
begin
  u := UTF8Decode(Xml);
  u := StripInvalidXml10Chars(u);
  u := NormalizeLegacyXmlTags(u);
  u := EscapeBareAmpersands(u);
  Result := UTF8Encode(u);
end;

{ 编码探测：对应 loadXmlText 的 UTF-8 BOM → UTF-8 → local8bit → GB18030 顺序 }

// UTF-8 有效性检查（对应 QString::fromUtf8 后无 ReplacementCharacter）。
function IsValidUtf8(const Data: RawByteString): Boolean;
var
  i, len, remaining: Integer;
  b: Byte;
begin
  i := 1;
  len := Length(Data);
  while i <= len do
  begin
    b := Ord(Data[i]);
    if b < $80 then
      remaining := 0
    else if (b and $E0) = $C0 then
      remaining := 1
    else if (b and $F0) = $E0 then
      remaining := 2
    else if (b and $F8) = $F0 then
      remaining := 3
    else
      Exit(False);
    Inc(i);
    while remaining > 0 do
    begin
      if (i > len) or ((Ord(Data[i]) and $C0) <> $80) then Exit(False);
      Inc(i);
      Dec(remaining);
    end;
  end;
  Result := True;
end;

function LoadXmlText(const Path: string): string;
var
  fs: TFileStream;
  data: RawByteString;
  converted: string;
  encoded: Boolean;
begin
  Result := '';
  if not FileExists(Path) then Exit;

  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(data[1], fs.Size);
  finally
    fs.Free;
  end;
  if data = '' then Exit;

  // UTF-8 BOM
  if (Length(data) >= 3) and (Copy(data, 1, 3) = #$EF#$BB#$BF) then
    Exit(SanitizeLegacyXml(Copy(data, 4, MaxInt)));

  // UTF-8 无损解码
  if IsValidUtf8(data) then
    Exit(SanitizeLegacyXml(data));

  // GB18030/GBK（中文皮肤最常见的 ANSI 编码；对应 local8bit + GB18030 兜底）
  converted := ConvertEncodingToUTF8(data, 'cp936', encoded);
  if encoded then
    Exit(SanitizeLegacyXml(converted));

  // 兜底：按 UTF-8 处理
  Result := SanitizeLegacyXml(data);
end;

{ TSkinEngine }

constructor TSkinEngine.Create;
begin
  inherited Create;
  InitSkinData(FSkin);
  FLoaded := False;
end;

destructor TSkinEngine.Destroy;
begin
  FreeSkinData(FSkin);
  inherited Destroy;
end;

function TSkinEngine.SkinPtr: PSkinData;
begin
  Result := @FSkin;
end;

// 不区分大小写查找目录中的文件（对应 findSkinFileCaseInsensitive）。
function FindSkinFileCaseInsensitive(const DirPath, FileName: string): string;
var
  rec: TSearchRec;
begin
  Result := '';
  if FileExists(DirPath + PathDelim + FileName) then
    Exit(DirPath + PathDelim + FileName);

  if FindFirst(DirPath + PathDelim + '*', faAnyFile, rec) = 0 then
  begin
    try
      repeat
        if (rec.Attr and faDirectory) = 0 then
          if SameText(rec.Name, FileName) then
            Exit(DirPath + PathDelim + rec.Name);
      until FindNext(rec) <> 0;
    finally
      FindClose(rec);
    end;
  end;
end;

function TSkinEngine.LoadImages(const DirPath: string; Images: TSkinImageMap): Boolean;
var
  rec: TSearchRec;
  ext: string;
  bmp: TBGRABitmap;
  reader: TFPCustomImageReader;
begin
  if FindFirst(DirPath + PathDelim + '*', faAnyFile, rec) = 0 then
  begin
    try
      repeat
        if (rec.Attr and faDirectory) <> 0 then Continue;
        ext := LowerCase(ExtractFileExt(rec.Name));
        if (ext = '.bmp') or (ext = '.png') or (ext = '.jpg') or (ext = '.ico') then
        begin
          try
            if ext = '.bmp' then
            begin
              // Qt 读 BMP 一律视为不透明（即使 32 位文件带全零 alpha 通道）。
              // BGRABitmap 默认 toTransparent 会把这类文件读成全透明，须显式 toOpaque。
              reader := TBGRAReaderBMP.Create;
              try
                TBGRAReaderBMP(reader).TransparencyOption := toOpaque;
                bmp := TBGRABitmap.Create;
                bmp.LoadFromFile(DirPath + PathDelim + rec.Name, reader);
              finally
                reader.Free;
              end;
            end
            else
              bmp := TBGRABitmap.Create(DirPath + PathDelim + rec.Name);
            Images.Add(rec.Name, bmp);
          except
            // 与 Qt 版一致：加载失败的图片静默跳过
          end;
        end;
      until FindNext(rec) <> 0;
    finally
      FindClose(rec);
    end;
  end;
  Result := Images.Count > 0;
end;

function TSkinEngine.LoadFromDirectory(const DirPath: string): Boolean;
var
  images: TSkinImageMap;
  skinXmlPath, xmlContent, auxPath, auxContent: string;
begin
  Result := False;
  FLoaded := False;

  images := TSkinImageMap.Create;
  try
    if not LoadImages(DirPath, images) then Exit;

    skinXmlPath := FindSkinFileCaseInsensitive(DirPath, 'Skin.xml');
    if skinXmlPath = '' then Exit;

    xmlContent := LoadXmlText(skinXmlPath);
    if xmlContent = '' then Exit;

    if not ParseSkinXml(xmlContent, images, TSkinColor.Make(255, 0, 255), FSkin) then
      Exit;

    // Lyric.xml / PlayList.xml / Visual.xml 可选
    auxPath := FindSkinFileCaseInsensitive(DirPath, 'Lyric.xml');
    if auxPath <> '' then
    begin
      auxContent := LoadXmlText(auxPath);
      if auxContent <> '' then ParseLyricXml(auxContent, FSkin);
    end;
    auxPath := FindSkinFileCaseInsensitive(DirPath, 'PlayList.xml');
    if auxPath <> '' then
    begin
      auxContent := LoadXmlText(auxPath);
      if auxContent <> '' then ParsePlaylistXml(auxContent, FSkin);
    end;
    auxPath := FindSkinFileCaseInsensitive(DirPath, 'Visual.xml');
    if auxPath <> '' then
    begin
      auxContent := LoadXmlText(auxPath);
      if auxContent <> '' then ParseVisualXml(auxContent, FSkin);
    end;

    ResolvePlaylistTheme(FSkin);
    FLoaded := True;
    Result := True;
  finally
    images.Free;
  end;
end;

function TSkinEngine.LoadFromFile(const SknPath: string): Boolean;
var
  tempDir, sidecarPath: string;
  unzip: TUnZipper;
begin
  Result := False;

  tempDir := GetTempDir(False) + 'ttskin_' + IntToStr(GetProcessID) + '_' +
    IntToStr(GetTickCount64);
  if not ForceDirectories(tempDir) then Exit;

  try
    unzip := TUnZipper.Create;
    try
      unzip.FileName := SknPath;
      unzip.OutputPath := tempDir;
      try
        unzip.UnZipAllFiles;
      except
        Exit;  // 非 zip 或损坏的皮肤包
      end;
    finally
      unzip.Free;
    end;

    if not LoadFromDirectory(tempDir) then Exit;

    // 侧车布局：<皮肤文件名>.xml（如 Classic.skn.xml）。
    // （Qt 版的 sidecarConfigCandidates 有一批历史遗留路径，经去重后
    // 对仓库内皮肤实际生效的只有这一种。）
    sidecarPath := SknPath + '.xml';
    if FileExists(sidecarPath) then
      LoadSkinConfigXml(sidecarPath);

    ResolvePlaylistTheme(FSkin);
    Result := True;
  finally
    DeleteDirectory(tempDir, False);
  end;
end;

function TSkinEngine.LoadSkinConfigXml(const XmlPath: string): Boolean;
var
  content: string;
begin
  Result := False;
  if XmlPath = '' then Exit;
  content := LoadXmlText(XmlPath);
  if content = '' then Exit;

  ParseSkinConfigXml(content, FSkin);
  ParseLyricXml(content, FSkin);
  ParsePlaylistXml(content, FSkin);
  ParseVisualXml(content, FSkin);
  Result := True;
end;

end.
