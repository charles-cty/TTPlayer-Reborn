unit ULog;

{$mode objfpc}{$H+}

// Pascal 工程日志。不依赖 LCL，ttplayer / tests / skinpreview / ttdump 都能用。
//
// Windows GUI（-WG）没有控制台，WriteLn(stdout) 会 EInOutError。默认写到
// exe 旁 <program>.log。级别和去向也可在运行前用环境变量改，或测试里配置。
//
//   TTPLAYER_LOG         文件路径 | off | stdout | stderr
//                        未设则用 ChangeFileExt(ParamStr(0), '.log')
//   TTPLAYER_LOG_LEVEL   off | error | warn | info | debug | trace
//                        未设则 info
//   TTPLAYER_LOG_TOPICS  逗号分隔的 topic；空或未设 = 全部
//
// 行格式: hh:nn:ss.zzz LEVEL [topic] message
// 消息：首字母大写，动词开头（Drag start、Refit end、Move），词之间一个空格。
// 写失败不抛。每次写出后 Flush。

interface

type
  TLogLevel = (llOff, llError, llWarn, llInfo, llDebug, llTrace);

function ParseLogLevel(const S: string; out Level: TLogLevel): Boolean;
function LogLevelName(ALevel: TLogLevel): string;
function DefaultLogFilePath: string;

function GetLogLevel: TLogLevel;
function GetLogFilePath: string;
function LogEnabled(ALevel: TLogLevel): Boolean;
function LogEnabled(ALevel: TLogLevel; const Topic: string): Boolean;

procedure SetLogLevel(ALevel: TLogLevel);
procedure SetLogDestination(const Spec: string);
procedure SetLogTopics(const Spec: string);
procedure ApplyLogEnv;
procedure FlushLog;
procedure CloseLog;

procedure Log(ALevel: TLogLevel; const Topic, Msg: string);
procedure LogFmt(ALevel: TLogLevel; const Topic, Fmt: string;
  const Args: array of const);

procedure LogError(const Topic, Msg: string);
procedure LogWarn(const Topic, Msg: string);
procedure LogInfo(const Topic, Msg: string);
procedure LogDebug(const Topic, Msg: string);
procedure LogTrace(const Topic, Msg: string);

procedure LogErrorFmt(const Topic, Fmt: string; const Args: array of const);
procedure LogWarnFmt(const Topic, Fmt: string; const Args: array of const);
procedure LogInfoFmt(const Topic, Fmt: string; const Args: array of const);
procedure LogDebugFmt(const Topic, Fmt: string; const Args: array of const);
procedure LogTraceFmt(const Topic, Fmt: string; const Args: array of const);

implementation

uses
  SysUtils;

type
  TLogDest = (ldNone, ldFile, ldStdout, ldStderr);

var
  GLock: TRTLCriticalSection;
  GLevel: TLogLevel = llInfo;
  GDest: TLogDest = ldFile;
  GPath: string;
  GTopics: string; // ',skin,snap,' lowercase; empty = all
  GFile: TextFile;
  GFileOpen: Boolean = False;
  GWroteHeader: Boolean = False;

function SwallowIO: Boolean;
begin
  Result := IOResult = 0;
end;

function ConsoleOpen(var T: Text): Boolean;
begin
  Result := TextRec(T).Mode <> fmClosed;
end;

function LogLevelName(ALevel: TLogLevel): string;
const
  Names: array[TLogLevel] of string = (
    'OFF', 'ERROR', 'WARN', 'INFO', 'DEBUG', 'TRACE');
begin
  Result := Names[ALevel];
end;

function ParseLogLevel(const S: string; out Level: TLogLevel): Boolean;
var
  t: string;
begin
  t := LowerCase(Trim(S));
  Result := True;
  if (t = 'off') or (t = '0') or (t = 'none') then
    Level := llOff
  else if (t = 'error') or (t = 'err') then
    Level := llError
  else if (t = 'warn') or (t = 'warning') then
    Level := llWarn
  else if (t = 'info') then
    Level := llInfo
  else if (t = 'debug') or (t = 'dbg') then
    Level := llDebug
  else if (t = 'trace') then
    Level := llTrace
  else
  begin
    Level := llInfo;
    Result := False;
  end;
end;

function DefaultLogFilePath: string;
var
  exe: string;
begin
  exe := ParamStr(0);
  if exe = '' then
    Result := 'ttplayer.log'
  else
    Result := ChangeFileExt(exe, '.log');
end;

function NormalizeTopics(const Spec: string): string;
var
  raw, item: string;
  i, start: Integer;
begin
  raw := Trim(Spec);
  if raw = '' then
    Exit('');
  Result := ',';
  start := 1;
  for i := 1 to Length(raw) + 1 do
    if (i > Length(raw)) or (raw[i] = ',') then
    begin
      item := LowerCase(Trim(Copy(raw, start, i - start)));
      if item <> '' then
        Result := Result + item + ',';
      start := i + 1;
    end;
  if Result = ',' then
    Result := '';
end;

function TopicAllowed(const Topic: string): Boolean;
begin
  if GTopics = '' then
    Exit(True);
  Result := Pos(',' + LowerCase(Topic) + ',', GTopics) > 0;
end;

function GetLogLevel: TLogLevel;
begin
  Result := GLevel;
end;

function GetLogFilePath: string;
begin
  if GDest = ldFile then
    Result := GPath
  else
    Result := '';
end;

function LogEnabled(ALevel: TLogLevel): Boolean;
begin
  Result := (ALevel <> llOff) and (GLevel <> llOff) and (ALevel <= GLevel)
    and (GDest <> ldNone);
end;

function LogEnabled(ALevel: TLogLevel; const Topic: string): Boolean;
begin
  Result := LogEnabled(ALevel) and TopicAllowed(Topic);
end;

procedure CloseLogUnlocked;
begin
  if GFileOpen then
  begin
    {$I-}
    CloseFile(GFile);
    SwallowIO;
    {$I+}
    GFileOpen := False;
  end;
  GWroteHeader := False;
end;

procedure CloseLog;
begin
  EnterCriticalSection(GLock);
  try
    CloseLogUnlocked;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure FlushLog;
begin
  EnterCriticalSection(GLock);
  try
    if GFileOpen then
    begin
      {$I-}
      Flush(GFile);
      SwallowIO;
      {$I+}
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure SetLogLevel(ALevel: TLogLevel);
begin
  EnterCriticalSection(GLock);
  try
    GLevel := ALevel;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure SetLogTopics(const Spec: string);
begin
  EnterCriticalSection(GLock);
  try
    GTopics := NormalizeTopics(Spec);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure SetLogDestination(const Spec: string);
var
  t: string;
begin
  t := Trim(Spec);
  EnterCriticalSection(GLock);
  try
    CloseLogUnlocked;
    if (t = '') or SameText(t, 'off') or (t = '0') or SameText(t, 'none')
      or SameText(t, 'false') then
    begin
      GDest := ldNone;
      GPath := '';
    end
    else if SameText(t, 'stdout') or (t = '-') or SameText(t, 'con') then
    begin
      GDest := ldStdout;
      GPath := '';
    end
    else if SameText(t, 'stderr') or SameText(t, 'err') then
    begin
      GDest := ldStderr;
      GPath := '';
    end
    else
    begin
      GDest := ldFile;
      GPath := t;
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure ApplyLogEnv;
var
  s: string;
  lv: TLogLevel;
begin
  s := GetEnvironmentVariable('TTPLAYER_LOG_LEVEL');
  if (s = '') or not ParseLogLevel(s, lv) then
    lv := llInfo;
  SetLogLevel(lv);
  SetLogTopics(GetEnvironmentVariable('TTPLAYER_LOG_TOPICS'));
  s := GetEnvironmentVariable('TTPLAYER_LOG');
  if s = '' then
    s := DefaultLogFilePath;
  SetLogDestination(s);
end;

procedure EnsureFileOpenUnlocked;
var
  ok: Boolean;
begin
  if GFileOpen or (GDest <> ldFile) or (GPath = '') then
    Exit;
  AssignFile(GFile, GPath);
  {$I-}
  if FileExists(GPath) then
  begin
    Append(GFile);
    ok := SwallowIO;
    if not ok then
    begin
      Rewrite(GFile);
      ok := SwallowIO;
    end;
  end
  else
  begin
    Rewrite(GFile);
    ok := SwallowIO;
  end;
  {$I+}
  if not ok then
    Exit;
  GFileOpen := True;
  if not GWroteHeader then
  begin
    {$I-}
    WriteLn(GFile, '---------- ',
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
      ' pid=', IntToStr(GetProcessID), ' ',
      ExtractFileName(ParamStr(0)), ' ----------');
    Flush(GFile);
    SwallowIO;
    {$I+}
    GWroteHeader := True;
  end;
end;

procedure EmitLine(const Line: string);
begin
  EnterCriticalSection(GLock);
  try
    case GDest of
      ldNone:
        ;
      ldFile:
        begin
          EnsureFileOpenUnlocked;
          if GFileOpen then
          begin
            {$I-}
            WriteLn(GFile, Line);
            Flush(GFile);
            SwallowIO;
            {$I+}
          end;
        end;
      ldStdout:
        if ConsoleOpen(Output) then
        begin
          {$I-}
          WriteLn(Output, Line);
          Flush(Output);
          SwallowIO;
          {$I+}
        end;
      ldStderr:
        if ConsoleOpen(ErrOutput) then
        begin
          {$I-}
          WriteLn(ErrOutput, Line);
          Flush(ErrOutput);
          SwallowIO;
          {$I+}
        end;
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure Log(ALevel: TLogLevel; const Topic, Msg: string);
begin
  if not LogEnabled(ALevel, Topic) then
    Exit;
  EmitLine(FormatDateTime('hh:nn:ss.zzz', Now) + ' ' +
    Format('%-5s', [LogLevelName(ALevel)]) + ' [' + Topic + '] ' + Msg);
end;

procedure LogFmt(ALevel: TLogLevel; const Topic, Fmt: string;
  const Args: array of const);
begin
  if not LogEnabled(ALevel, Topic) then
    Exit;
  Log(ALevel, Topic, Format(Fmt, Args));
end;

procedure LogError(const Topic, Msg: string);
begin
  Log(llError, Topic, Msg);
end;

procedure LogWarn(const Topic, Msg: string);
begin
  Log(llWarn, Topic, Msg);
end;

procedure LogInfo(const Topic, Msg: string);
begin
  Log(llInfo, Topic, Msg);
end;

procedure LogDebug(const Topic, Msg: string);
begin
  Log(llDebug, Topic, Msg);
end;

procedure LogTrace(const Topic, Msg: string);
begin
  Log(llTrace, Topic, Msg);
end;

procedure LogErrorFmt(const Topic, Fmt: string; const Args: array of const);
begin
  LogFmt(llError, Topic, Fmt, Args);
end;

procedure LogWarnFmt(const Topic, Fmt: string; const Args: array of const);
begin
  LogFmt(llWarn, Topic, Fmt, Args);
end;

procedure LogInfoFmt(const Topic, Fmt: string; const Args: array of const);
begin
  LogFmt(llInfo, Topic, Fmt, Args);
end;

procedure LogDebugFmt(const Topic, Fmt: string; const Args: array of const);
begin
  LogFmt(llDebug, Topic, Fmt, Args);
end;

procedure LogTraceFmt(const Topic, Fmt: string; const Args: array of const);
begin
  LogFmt(llTrace, Topic, Fmt, Args);
end;

initialization
  InitCriticalSection(GLock);
  GPath := DefaultLogFilePath;
  ApplyLogEnv;

finalization
  CloseLog;
  DoneCriticalSection(GLock);

end.
