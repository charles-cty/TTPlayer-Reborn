unit UTtbl;

{$mode objfpc}{$H+}

// 原版 TTPlayer .ttbl 二进制播放列表，对应 Qt TtblParser / TtblWriter。
// 小尾序；字符串为 UTF-16LE（无 BOM、无终止符）。支持 version 3 与 5。
// 写出始终为 version=3（与 Qt TtblWriter 一致）。

interface

uses
  Classes, SysUtils, UPlaylistModel;

type
  TTtblEntry = record
    FilePath: string;
    Title: string;
    Artist: string;
    DurationMs: Int64;
    TrackNumber: Integer;
    IsCueTrack: Boolean;
  end;

  TTtblEntryArray = array of TTtblEntry;

  TTtblHeader = record
    Version: Integer;
    CurrentIndex: Integer;
    RecordCount: Cardinal;
    ListName: string;
  end;

function ParseTtbl(const Data: TBytes; out Header: TTtblHeader): TTtblEntryArray;
function ParseTtblFile(const FilePath: string; out Header: TTtblHeader): TTtblEntryArray;
function SerializeTtbl(const Entries: TPlaylistEntryArray; Count: Integer;
  const ListName: string; CurrentIndex: Integer): TBytes;
function WriteTtblFile(const FilePath: string; const Entries: TPlaylistEntryArray;
  Count: Integer; const ListName: string; CurrentIndex: Integer): Boolean;

implementation

function ReadU16(const D: TBytes; Off: Integer): Word;
begin
  Result := Word(D[Off]) or (Word(D[Off + 1]) shl 8);
end;

function ReadU32(const D: TBytes; Off: Integer): Cardinal;
begin
  Result := Cardinal(D[Off])
         or (Cardinal(D[Off + 1]) shl 8)
         or (Cardinal(D[Off + 2]) shl 16)
         or (Cardinal(D[Off + 3]) shl 24);
end;

function ReadI32(const D: TBytes; Off: Integer): Integer;
begin
  Result := Integer(ReadU32(D, Off));
end;

function InBounds(Offset, Size, DataSize: Integer): Boolean;
begin
  Result := (Offset >= 0) and (Size >= 0) and (Offset <= DataSize - Size);
end;

function ReadUtf16Le(const D: TBytes; Off, ByteCount: Integer): string;
var
  ws: UnicodeString;
  n: Integer;
begin
  Result := '';
  if ByteCount <= 0 then Exit;
  n := ByteCount div 2;
  SetLength(ws, n);
  if n > 0 then
    Move(D[Off], ws[1], n * 2);
  Result := UTF8Encode(ws);
end;

procedure WriteU16(var Buf: TBytes; var Len: Integer; V: Word);
begin
  if Len + 2 > Length(Buf) then
    SetLength(Buf, Length(Buf) * 2 + 16);
  Buf[Len] := Byte(V);
  Buf[Len + 1] := Byte(V shr 8);
  Inc(Len, 2);
end;

procedure WriteU32(var Buf: TBytes; var Len: Integer; V: Cardinal);
begin
  if Len + 4 > Length(Buf) then
    SetLength(Buf, Length(Buf) * 2 + 16);
  Buf[Len]     := Byte(V);
  Buf[Len + 1] := Byte(V shr 8);
  Buf[Len + 2] := Byte(V shr 16);
  Buf[Len + 3] := Byte(V shr 24);
  Inc(Len, 4);
end;

procedure WriteI32(var Buf: TBytes; var Len: Integer; V: Integer);
begin
  WriteU32(Buf, Len, Cardinal(V));
end;

procedure WriteBytes(var Buf: TBytes; var Len: Integer; const Src: TBytes);
var
  n: Integer;
begin
  n := Length(Src);
  if n = 0 then Exit;
  if Len + n > Length(Buf) then
    SetLength(Buf, Len + n + 64);
  Move(Src[0], Buf[Len], n);
  Inc(Len, n);
end;

function ToUtf16Le(const S: string): TBytes;
var
  ws: UnicodeString;
  n: Integer;
begin
  ws := UTF8Decode(S);
  n := Length(ws);
  SetLength(Result, n * 2);
  if n > 0 then
    Move(ws[1], Result[0], n * 2);
end;

procedure WriteUtf16Field(var Buf: TBytes; var Len: Integer; const S: string);
var
  enc: TBytes;
begin
  enc := ToUtf16Le(S);
  WriteU32(Buf, Len, Cardinal(Length(enc)));
  WriteBytes(Buf, Len, enc);
end;

function ParseTtbl(const Data: TBytes; out Header: TTtblHeader): TTtblEntryArray;
var
  dataSize, off: Integer;
  nameLen, titleFmtLen, defaultFmtLen, pathLen, titleLen: Cardinal;
  marker: Word;
  entry: TTtblEntry;
begin
  SetLength(Result, 0);
  Header.Version := 3;
  Header.CurrentIndex := -1;
  Header.RecordCount := 0;
  Header.ListName := '';

  dataSize := Length(Data);
  if (dataSize < 20) or (Data[0] <> Ord('T')) or (Data[1] <> Ord('T')) or
     (Data[2] <> Ord('B')) or (Data[3] <> Ord('L')) then
    Exit;

  Header.Version := ReadI32(Data, 4);
  Header.CurrentIndex := ReadI32(Data, 8);
  Header.RecordCount := ReadU32(Data, 12);
  nameLen := ReadU32(Data, 16);
  off := 20;
  if not InBounds(off, Integer(nameLen), dataSize) then Exit;
  Header.ListName := ReadUtf16Le(Data, off, Integer(nameLen));
  Inc(off, Integer(nameLen));

  if Header.Version >= 5 then
  begin
    if off + 4 > dataSize then Exit;
    titleFmtLen := ReadU32(Data, off); Inc(off, 4);
    if not InBounds(off, Integer(titleFmtLen), dataSize) then Exit;
    Inc(off, Integer(titleFmtLen));
    if off + 4 > dataSize then Exit;
    defaultFmtLen := ReadU32(Data, off); Inc(off, 4);
    if not InBounds(off, Integer(defaultFmtLen), dataSize) then Exit;
    Inc(off, Integer(defaultFmtLen));
  end;

  while off + 6 <= dataSize do
  begin
    if off + 4 > dataSize then Break;
    pathLen := ReadU32(Data, off);
    if (pathLen = 0) or (pathLen > 8192) then Break;
    if not InBounds(off + 4, Integer(pathLen), dataSize) then Break;
    entry.FilePath := ReadUtf16Le(Data, off + 4, Integer(pathLen));
    Inc(off, 4 + Integer(pathLen));

    if off + 2 > dataSize then Break;
    marker := ReadU16(Data, off);
    Inc(off, 2);

    entry.Title := '';
    entry.Artist := '';
    entry.DurationMs := 0;
    entry.TrackNumber := 0;
    entry.IsCueTrack := False;

    if marker = $0006 then
    begin
      if off + 4 > dataSize then Break;
      titleLen := ReadU32(Data, off); Inc(off, 4);
      if not InBounds(off, Integer(titleLen), dataSize) then Break;
      entry.Title := ReadUtf16Le(Data, off, Integer(titleLen));
      Inc(off, Integer(titleLen));
      if off + 4 > dataSize then Break;
      entry.DurationMs := ReadU32(Data, off);
      Inc(off, 4);
    end
    else if marker = $0007 then
    begin
      if off + 2 > dataSize then Break;
      entry.TrackNumber := Integer(ReadU16(Data, off));
      Inc(off, 2);
      if off + 4 > dataSize then Break;
      titleLen := ReadU32(Data, off); Inc(off, 4);
      if not InBounds(off, Integer(titleLen), dataSize) then Break;
      entry.Title := ReadUtf16Le(Data, off, Integer(titleLen));
      Inc(off, Integer(titleLen));
      if off + 4 > dataSize then Break;
      entry.DurationMs := ReadU32(Data, off);
      Inc(off, 4);
      entry.IsCueTrack := True;
    end
    else
      Break;

    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := entry;
  end;
end;

function ParseTtblFile(const FilePath: string; out Header: TTtblHeader): TTtblEntryArray;
var
  fs: TFileStream;
  data: TBytes;
begin
  SetLength(Result, 0);
  Header.Version := 3;
  Header.CurrentIndex := -1;
  Header.RecordCount := 0;
  Header.ListName := '';
  if not FileExists(FilePath) then Exit;
  fs := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(data, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(data[0], fs.Size);
  finally
    fs.Free;
  end;
  Result := ParseTtbl(data, Header);
end;

function SerializeTtbl(const Entries: TPlaylistEntryArray; Count: Integer;
  const ListName: string; CurrentIndex: Integer): TBytes;
var
  len, i, n: Integer;
  titleStr: string;
  magic: TBytes;
begin
  n := Count;
  if n < 0 then n := 0;
  if n > Length(Entries) then n := Length(Entries);
  SetLength(Result, 128 + n * 256);
  len := 0;
  SetLength(magic, 4);
  magic[0] := Ord('T'); magic[1] := Ord('T');
  magic[2] := Ord('B'); magic[3] := Ord('L');
  WriteBytes(Result, len, magic);
  WriteI32(Result, len, 3);
  WriteI32(Result, len, CurrentIndex);
  WriteU32(Result, len, Cardinal(n));
  WriteUtf16Field(Result, len, ListName);

  for i := 0 to n - 1 do
  begin
    WriteUtf16Field(Result, len, Entries[i].FilePath);
    WriteU16(Result, len, $0006);
    titleStr := Entries[i].Title;
    if (Entries[i].Artist <> '') and (titleStr <> '') then
      titleStr := Entries[i].Artist + ' - ' + titleStr;
    WriteUtf16Field(Result, len, titleStr);
    if Entries[i].DurationMs > 0 then
      WriteU32(Result, len, Cardinal(Entries[i].DurationMs))
    else
      WriteU32(Result, len, 0);
  end;
  SetLength(Result, len);
end;

function WriteTtblFile(const FilePath: string; const Entries: TPlaylistEntryArray;
  Count: Integer; const ListName: string; CurrentIndex: Integer): Boolean;
var
  data: TBytes;
  fs: TFileStream;
  dir: string;
begin
  Result := False;
  dir := ExtractFilePath(FilePath);
  if (dir <> '') and (not DirectoryExists(dir)) then
    if not ForceDirectories(dir) then Exit;
  data := SerializeTtbl(Entries, Count, ListName, CurrentIndex);
  fs := TFileStream.Create(FilePath, fmCreate);
  try
    if Length(data) > 0 then
      fs.WriteBuffer(data[0], Length(data));
    Result := True;
  finally
    fs.Free;
  end;
end;

end.
