unit ULrcParser;

{$mode objfpc}{$H+}

// LRC 歌词解析，对应 Qt 版 src/lyric/LrcParser。
// 支持 [mm:ss] / [mm:ss.xx] / [mm:ss.xxx]、一行多时间戳、ti/ar/al/offset 标签。
// 编码：UTF-8 优先，失败回退 CP936（GBK）；与 Qt AutoDetect 一致。

interface

uses
  Classes, SysUtils;

type
  TLrcEncoding = (
    leAutoDetect,
    leUTF8,
    leGBK,
    leLatin1
  );

  TLrcLine = record
    TimeMs: Int64;
    Text: string;
  end;

  TLrcLineArray = array of TLrcLine;

  TLrcData = record
    Title: string;
    Artist: string;
    Album: string;
    Offset: Integer;
    Lines: TLrcLineArray;
  end;

function ParseLrc(const Data: TBytes; Encoding: TLrcEncoding = leAutoDetect): TLrcData;
function ParseLrcText(const Text: string): TLrcData;
function ParseLrcFile(const FilePath: string;
  Encoding: TLrcEncoding = leAutoDetect): TLrcData;
function CurrentLyricIndex(const Data: TLrcData; PositionMs: Int64): Integer;

function LrcEncodingName(Enc: TLrcEncoding): string;
function ApplyLyricTimeOffset(const Data: TLrcData; ExtraOffsetMs: Integer): TLrcData;
function ReparseLyric(const Data: TBytes; Encoding: TLrcEncoding;
  ExtraOffsetMs: Integer): TLrcData;

const
  AvailableLrcEncodings: array[0..3] of TLrcEncoding = (
    leAutoDetect, leUTF8, leGBK, leLatin1
  );

implementation

uses
  LConvEncoding;

function BytesAreUtf8(const S: RawByteString): Boolean;
var
  i, n, need: Integer;
  c: Byte;
begin
  Result := True;
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    c := Byte(S[i]);
    if c < $80 then
      need := 0
    else if (c and $E0) = $C0 then
    begin
      if c < $C2 then Exit(False);
      need := 1;
    end
    else if (c and $F0) = $E0 then
      need := 2
    else if (c and $F8) = $F0 then
      need := 3
    else
      Exit(False);
    Inc(i);
    while need > 0 do
    begin
      if i > n then Exit(False);
      if (Byte(S[i]) and $C0) <> $80 then Exit(False);
      Inc(i);
      Dec(need);
    end;
  end;
end;

function DecodeBytes(const Data: TBytes; Encoding: TLrcEncoding): string;
var
  raw: RawByteString;
  start: Integer;
begin
  Result := '';
  if Length(Data) = 0 then Exit;
  start := 0;
  if (Length(Data) >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and
     (Data[2] = $BF) then
    start := 3;
  SetLength(raw, Length(Data) - start);
  if Length(raw) > 0 then
    Move(Data[start], raw[1], Length(raw));

  case Encoding of
    leUTF8:
      Result := raw;
    leGBK:
      Result := CP936ToUTF8(raw);
    leLatin1:
      Result := ISO_8859_1ToUTF8(raw);
  else
    if (raw = '') or BytesAreUtf8(raw) then
      Result := raw
    else
      Result := CP936ToUTF8(raw);
  end;
end;

function ParseIntDigits(const S: string; StartPos, Count: Integer): Integer;
var
  i: Integer;
  c: Char;
begin
  Result := 0;
  for i := 0 to Count - 1 do
  begin
    if StartPos + i > Length(S) then Exit(0);
    c := S[StartPos + i];
    if (c < '0') or (c > '9') then Exit(0);
    Result := Result * 10 + Ord(c) - Ord('0');
  end;
end;

function ParseTimeToken(const S: string; PosBracket: Integer;
  out TimeMs: Int64; out TokenEnd: Integer): Boolean;
var
  mins, secs, frac, fracDigits, p, n: Integer;
begin
  Result := False;
  TimeMs := 0;
  TokenEnd := PosBracket;
  if (PosBracket < 1) or (PosBracket > Length(S)) or (S[PosBracket] <> '[') then
    Exit;
  p := PosBracket + 1;
  if (p + 4 > Length(S)) then Exit;
  if (S[p + 2] <> ':') then Exit;
  mins := ParseIntDigits(S, p, 2);
  secs := ParseIntDigits(S, p + 3, 2);
  p := p + 5;
  frac := 0;
  fracDigits := 0;
  if (p <= Length(S)) and ((S[p] = '.') or (S[p] = ':')) then
  begin
    Inc(p);
    n := p;
    while (n <= Length(S)) and (S[n] >= '0') and (S[n] <= '9') do
      Inc(n);
    fracDigits := n - p;
    if fracDigits = 2 then
      frac := ParseIntDigits(S, p, 2) * 10
    else if fracDigits = 3 then
      frac := ParseIntDigits(S, p, 3)
    else if fracDigits = 1 then
      frac := ParseIntDigits(S, p, 1) * 100
    else
      frac := 0;
    p := n;
  end;
  if (p > Length(S)) or (S[p] <> ']') then Exit;
  TimeMs := Int64(mins) * 60000 + Int64(secs) * 1000 + frac;
  TokenEnd := p;
  Result := True;
end;

function IsMetadataKey(const Key: string): Boolean;
begin
  Result := (Key = 'ti') or (Key = 'ar') or (Key = 'al') or (Key = 'offset') or
            (Key = 'by') or (Key = 're') or (Key = 've') or (Key = 'length');
end;

procedure SortLines(var Lines: TLrcLineArray);
var
  i, j: Integer;
  tmp: TLrcLine;
begin
  for i := 1 to High(Lines) do
  begin
    tmp := Lines[i];
    j := i;
    while (j > 0) and (Lines[j - 1].TimeMs > tmp.TimeMs) do
    begin
      Lines[j] := Lines[j - 1];
      Dec(j);
    end;
    Lines[j] := tmp;
  end;
end;

function ParseLrcText(const Text: string): TLrcData;
var
  sl: TStringList;
  i, p, tokenEnd, lastEnd, k: Integer;
  line, key, val, lyricText: string;
  times: array of Int64;
  t: Int64;
  hasTime: Boolean;
begin
  Result.Title := '';
  Result.Artist := '';
  Result.Album := '';
  Result.Offset := 0;
  SetLength(Result.Lines, 0);

  sl := TStringList.Create;
  try
    sl.Text := Text;

    for i := 0 to sl.Count - 1 do
    begin
      line := Trim(sl[i]);
      if line = '' then Continue;

      hasTime := False;
      p := 1;
      SetLength(times, 0);
      lastEnd := 0;
      while p <= Length(line) do
      begin
        if line[p] = '[' then
        begin
          if ParseTimeToken(line, p, t, tokenEnd) then
          begin
            hasTime := True;
            SetLength(times, Length(times) + 1);
            times[High(times)] := t;
            lastEnd := tokenEnd;
            p := tokenEnd + 1;
            Continue;
          end;
        end;
        Break;
      end;

      if hasTime then
      begin
        lyricText := Trim(Copy(line, lastEnd + 1, MaxInt));
        for k := 0 to High(times) do
        begin
          SetLength(Result.Lines, Length(Result.Lines) + 1);
          Result.Lines[High(Result.Lines)].TimeMs := times[k] + Result.Offset;
          Result.Lines[High(Result.Lines)].Text := lyricText;
        end;
        Continue;
      end;

      // 元数据 [ti:...] 等（不含时间戳的方括号标签）
      if (Length(line) >= 4) and (line[1] = '[') then
      begin
        p := Pos(':', line);
        tokenEnd := Length(line);
        if (line[tokenEnd] = ']') and (p > 2) then
        begin
          key := LowerCase(Copy(line, 2, p - 2));
          val := Trim(Copy(line, p + 1, tokenEnd - p - 1));
          if IsMetadataKey(key) then
          begin
            if key = 'ti' then Result.Title := val
            else if key = 'ar' then Result.Artist := val
            else if key = 'al' then Result.Album := val
            else if key = 'offset' then Result.Offset := StrToIntDef(val, 0);
          end;
        end;
      end;
    end;
  finally
    sl.Free;
  end;

  SortLines(Result.Lines);
end;

function ParseLrc(const Data: TBytes; Encoding: TLrcEncoding): TLrcData;
begin
  Result := ParseLrcText(DecodeBytes(Data, Encoding));
end;

function ParseLrcFile(const FilePath: string; Encoding: TLrcEncoding): TLrcData;
var
  fs: TFileStream;
  data: TBytes;
begin
  Result.Title := '';
  Result.Artist := '';
  Result.Album := '';
  Result.Offset := 0;
  SetLength(Result.Lines, 0);
  if not FileExists(FilePath) then Exit;
  fs := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(data[0], fs.Size);
  finally
    fs.Free;
  end;
  Result := ParseLrc(data, Encoding);
end;

function CurrentLyricIndex(const Data: TLrcData; PositionMs: Int64): Integer;
var
  i: Integer;
begin
  Result := -1;
  for i := 0 to High(Data.Lines) do
    if Data.Lines[i].TimeMs <= PositionMs then
      Result := i
    else
      Break;
end;

function LrcEncodingName(Enc: TLrcEncoding): string;
begin
  case Enc of
    leAutoDetect: Result := '自动检测';
    leUTF8: Result := 'UTF-8';
    leGBK: Result := 'GBK (简体中文)';
    leLatin1: Result := 'Latin-1 (西欧)';
  else
    Result := '未知';
  end;
end;

function ApplyLyricTimeOffset(const Data: TLrcData; ExtraOffsetMs: Integer): TLrcData;
var
  i: Integer;
begin
  Result := Data;
  Result.Offset := Data.Offset + ExtraOffsetMs;
  SetLength(Result.Lines, Length(Data.Lines));
  for i := 0 to High(Data.Lines) do
  begin
    Result.Lines[i] := Data.Lines[i];
    Result.Lines[i].TimeMs := Data.Lines[i].TimeMs + ExtraOffsetMs;
  end;
end;

function ReparseLyric(const Data: TBytes; Encoding: TLrcEncoding;
  ExtraOffsetMs: Integer): TLrcData;
begin
  Result := ParseLrc(Data, Encoding);
  if ExtraOffsetMs <> 0 then
    Result := ApplyLyricTimeOffset(Result, ExtraOffsetMs);
end;

end.
