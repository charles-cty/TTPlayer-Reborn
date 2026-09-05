unit UTestLog;

{$mode objfpc}{$H+}

// ULog：级别、topic 过滤、文件写出。每个用例写到独立临时文件。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, ULog;

type
  TLogTest = class(TTestCase)
  private
    FPath: string;
    function ReadLog: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestWritesInfoLine;
    procedure TestLevelFiltersDebug;
    procedure TestTopicFilter;
    procedure TestDisabled;
    procedure TestParseLogLevel;
    procedure TestLogEnabled;
    procedure TestFmt;
  end;

implementation

function TLogTest.ReadLog: string;
var
  sl: TStringList;
begin
  FlushLog;
  if not FileExists(FPath) then
    Exit('');
  sl := TStringList.Create;
  try
    sl.LoadFromFile(FPath);
    Result := sl.Text;
  finally
    sl.Free;
  end;
end;

procedure TLogTest.SetUp;
begin
  FPath := IncludeTrailingPathDelimiter(GetTempDir) +
    'ttplayer-ulog-' + IntToStr(GetProcessID) + '-' +
    IntToStr(Random(MaxInt)) + '.log';
  CloseLog;
  if FileExists(FPath) then
    DeleteFile(FPath);
  SetLogTopics('');
  SetLogLevel(llDebug);
  SetLogDestination(FPath);
end;

procedure TLogTest.TearDown;
begin
  CloseLog;
  if (FPath <> '') and FileExists(FPath) then
    DeleteFile(FPath);
  ApplyLogEnv;
end;

procedure TLogTest.TestWritesInfoLine;
var
  body: string;
begin
  LogInfo('skin', 'hello-refit');
  body := ReadLog;
  AssertTrue('session header', Pos('pid=', body) > 0);
  AssertTrue('info line', Pos('INFO  [skin] hello-refit', body) > 0);
end;

procedure TLogTest.TestLevelFiltersDebug;
var
  body: string;
begin
  SetLogLevel(llWarn);
  LogDebug('skin', 'hidden');
  LogWarn('skin', 'visible');
  body := ReadLog;
  AssertTrue('warn kept', Pos('WARN  [skin] visible', body) > 0);
  AssertTrue('debug dropped', Pos('hidden', body) = 0);
end;

procedure TLogTest.TestTopicFilter;
var
  body: string;
begin
  SetLogTopics('skin, host');
  LogInfo('skin', 'keep-skin');
  LogInfo('snap', 'drop-snap');
  LogInfo('host', 'keep-host');
  body := ReadLog;
  AssertTrue('skin kept', Pos('keep-skin', body) > 0);
  AssertTrue('host kept', Pos('keep-host', body) > 0);
  AssertTrue('snap dropped', Pos('drop-snap', body) = 0);
end;

procedure TLogTest.TestDisabled;
begin
  SetLogDestination('off');
  LogInfo('skin', 'should-not-write');
  AssertFalse('no file when off', FileExists(FPath));
  AssertFalse('enabled', LogEnabled(llInfo, 'skin'));
end;

procedure TLogTest.TestParseLogLevel;
var
  lv: TLogLevel;
begin
  AssertTrue(ParseLogLevel('info', lv));
  AssertTrue(lv = llInfo);
  AssertTrue(ParseLogLevel('WARN', lv));
  AssertTrue(lv = llWarn);
  AssertTrue(ParseLogLevel('trace', lv));
  AssertTrue(lv = llTrace);
  AssertTrue(ParseLogLevel('off', lv));
  AssertTrue(lv = llOff);
  AssertFalse(ParseLogLevel('nope', lv));
  AssertTrue(lv = llInfo);
end;

procedure TLogTest.TestLogEnabled;
begin
  SetLogLevel(llInfo);
  AssertTrue(LogEnabled(llError, 'skin'));
  AssertTrue(LogEnabled(llInfo, 'skin'));
  AssertFalse(LogEnabled(llDebug, 'skin'));
  SetLogTopics('snap');
  AssertFalse(LogEnabled(llInfo, 'skin'));
  AssertTrue(LogEnabled(llInfo, 'snap'));
end;

procedure TLogTest.TestFmt;
var
  body: string;
begin
  LogInfoFmt('skin', 'Move %s -> %d,%d', ['TEq', 10, 20]);
  body := ReadLog;
  AssertTrue('fmt', Pos('INFO  [skin] Move TEq -> 10,20', body) > 0);
end;

initialization
  Randomize;
  RegisterTest(TLogTest);
end.
