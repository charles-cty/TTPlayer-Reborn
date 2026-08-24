unit UTestPlaylistModel;

{$mode objfpc}{$H+}

// Layer 3：TPlaylistModel 索引语义与显示辅助函数。

interface

uses
  Classes, SysUtils, fpcunit, testregistry, UPlaylistModel;

type
  TPlaylistModelTest = class(TTestCase)
  published
    procedure TestAddAndCurrentIndex;
    procedure TestRemoveAdjustsCurrent;
    procedure TestMoveUpDown;
    procedure TestMoveRows;
    procedure TestNextPrevRepeat;
    procedure TestDisplayHelpers;
  end;

implementation

procedure TPlaylistModelTest.TestAddAndCurrentIndex;
var
  m: TPlaylistModel;
begin
  m := TPlaylistModel.Create;
  try
    AssertEquals(-1, m.CurrentIndex);
    m.AddFile('a.mp3');
    AssertEquals(1, m.Count);
    AssertEquals(0, m.CurrentIndex);
    m.AddFile('b.mp3');
    AssertEquals(2, m.Count);
    AssertEquals(0, m.CurrentIndex);
    m.InsertFile(0, 'z.mp3');
    AssertEquals(3, m.Count);
    AssertEquals(1, m.CurrentIndex);
    AssertEquals('z.mp3', m.FileAt(0));
    AssertEquals('a.mp3', m.FileAt(1));
  finally
    m.Free;
  end;
end;

procedure TPlaylistModelTest.TestRemoveAdjustsCurrent;
var
  m: TPlaylistModel;
begin
  m := TPlaylistModel.Create;
  try
    m.AddFiles(['a.mp3', 'b.mp3', 'c.mp3']);
    m.SetCurrentIndex(1);
    m.RemoveIndex(0);
    AssertEquals(2, m.Count);
    AssertEquals(0, m.CurrentIndex);
    AssertEquals('b.mp3', m.CurrentFile);
    m.RemoveIndex(0);
    AssertEquals('c.mp3', m.CurrentFile);
    m.RemoveIndex(0);
    AssertEquals(0, m.Count);
    AssertEquals(-1, m.CurrentIndex);
  finally
    m.Free;
  end;
end;

procedure TPlaylistModelTest.TestMoveUpDown;
var
  m: TPlaylistModel;
begin
  m := TPlaylistModel.Create;
  try
    m.AddFiles(['a.mp3', 'b.mp3', 'c.mp3']);
    m.SetCurrentIndex(1);
    m.MoveUp(1);
    AssertEquals('b.mp3', m.FileAt(0));
    AssertEquals(0, m.CurrentIndex);
    m.MoveDown(0);
    AssertEquals('b.mp3', m.FileAt(1));
    AssertEquals(1, m.CurrentIndex);
  finally
    m.Free;
  end;
end;

procedure TPlaylistModelTest.TestMoveRows;
var
  m: TPlaylistModel;
begin
  m := TPlaylistModel.Create;
  try
    m.AddFiles(['a.mp3', 'b.mp3', 'c.mp3', 'd.mp3']);
    m.SetCurrentIndex(1);
    m.MoveRows([1, 2], 0);
    AssertEquals('b.mp3', m.FileAt(0));
    AssertEquals('c.mp3', m.FileAt(1));
    AssertEquals('a.mp3', m.FileAt(2));
    AssertEquals('d.mp3', m.FileAt(3));
    AssertEquals(0, m.CurrentIndex);
  finally
    m.Free;
  end;
end;

procedure TPlaylistModelTest.TestNextPrevRepeat;
var
  m: TPlaylistModel;
begin
  m := TPlaylistModel.Create;
  try
    m.AddFiles(['a.mp3', 'b.mp3']);
    m.SetCurrentIndex(0);
    m.RepeatMode := 0;
    AssertEquals('b.mp3', m.NextFile);
    AssertEquals('', m.NextFile);
    AssertEquals(1, m.CurrentIndex);
    m.RepeatMode := 2;
    AssertEquals('a.mp3', m.NextFile);
    AssertEquals(0, m.CurrentIndex);
    AssertEquals('b.mp3', m.PrevFile);
    m.RepeatMode := 1;
    AssertEquals('b.mp3', m.NextFile);
    AssertEquals(1, m.CurrentIndex);
  finally
    m.Free;
  end;
end;

procedure TPlaylistModelTest.TestDisplayHelpers;
var
  e: TPlaylistEntry;
begin
  AssertEquals('00:00', FormatDurationText(0));
  AssertEquals('03:05', FormatDurationText(185000));
  AssertEquals('1:01:01', FormatDurationText(Int64(3661) * 1000));

  e := Default(TPlaylistEntry);
  AssertEquals('', DisplayDurationForEntry(e));
  e.FilePath := '/tmp/hello.mp3';
  AssertEquals('hello', DisplayTitleForEntry(e));
  e.Title := '晴天';
  e.Artist := '周杰伦';
  AssertEquals('周杰伦 - 晴天', DisplayTitleForEntry(e));
  e.DurationMs := 185000;
  AssertEquals('03:05', DisplayDurationForEntry(e));
end;

initialization
  RegisterTest(TPlaylistModelTest);

end.
