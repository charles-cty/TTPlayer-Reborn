unit UPlaylistBook;

{$mode objfpc}{$H+}

// 多播放列表标签页，对应 Qt PlaylistWindow::tabData_ / switchToTab /
// loadFromTtblDir / saveToTtblDir。每个标签页持有独立的 TPlaylistModel。

interface

uses
  Classes, SysUtils, UPlaylistModel, UTtbl;

type
  TPlaylistTab = class
  public
    Name: string;
    Model: TPlaylistModel;
    constructor Create(const AName: string);
    destructor Destroy; override;
  end;

  TPlaylistBook = class
  private
    FTabs: TFPList;
    FActive: Integer;
    function GetTab(Index: Integer): TPlaylistTab;
    function GetTabCount: Integer;
    function GetActiveModel: TPlaylistModel;
    function GetActiveName: string;
    function GetActiveIndex: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    procedure AddTab(const AName: string);
    procedure RenameTab(Index: Integer; const AName: string);
    procedure RemoveTab(Index: Integer);
    procedure SwitchTo(Index: Integer);

    procedure LoadFromTtblDir(const Dir: string; Count, ActiveList: Integer);
    function SaveToTtblDir(const Dir: string): Integer;

    property TabCount: Integer read GetTabCount;
    property Tabs[Index: Integer]: TPlaylistTab read GetTab;
    property ActiveIndex: Integer read GetActiveIndex;
    property ActiveModel: TPlaylistModel read GetActiveModel;
    property ActiveName: string read GetActiveName;
  end;

implementation

constructor TPlaylistTab.Create(const AName: string);
begin
  inherited Create;
  Name := AName;
  Model := TPlaylistModel.Create;
end;

destructor TPlaylistTab.Destroy;
begin
  Model.Free;
  inherited Destroy;
end;

{ TPlaylistBook }

constructor TPlaylistBook.Create;
begin
  inherited Create;
  FTabs := TFPList.Create;
  FActive := 0;
  AddTab('[默认]');
end;

destructor TPlaylistBook.Destroy;
begin
  Clear;
  FTabs.Free;
  inherited Destroy;
end;

procedure TPlaylistBook.Clear;
var
  i: Integer;
begin
  for i := 0 to FTabs.Count - 1 do
    TPlaylistTab(FTabs[i]).Free;
  FTabs.Clear;
  FActive := 0;
end;

function TPlaylistBook.GetTabCount: Integer;
begin
  Result := FTabs.Count;
end;

function TPlaylistBook.GetTab(Index: Integer): TPlaylistTab;
begin
  if (Index < 0) or (Index >= FTabs.Count) then
    Result := nil
  else
    Result := TPlaylistTab(FTabs[Index]);
end;

function TPlaylistBook.GetActiveIndex: Integer;
begin
  Result := FActive;
end;

function TPlaylistBook.GetActiveModel: TPlaylistModel;
var
  t: TPlaylistTab;
begin
  t := GetTab(FActive);
  if t <> nil then
    Result := t.Model
  else
    Result := nil;
end;

function TPlaylistBook.GetActiveName: string;
var
  t: TPlaylistTab;
begin
  t := GetTab(FActive);
  if t <> nil then
    Result := t.Name
  else
    Result := '';
end;

procedure TPlaylistBook.AddTab(const AName: string);
var
  t: TPlaylistTab;
  n: string;
begin
  n := AName;
  if n = '' then
    n := Format('[%d]', [FTabs.Count]);
  t := TPlaylistTab.Create(n);
  FTabs.Add(t);
  if FTabs.Count = 1 then
    FActive := 0;
end;

procedure TPlaylistBook.RenameTab(Index: Integer; const AName: string);
var
  t: TPlaylistTab;
begin
  t := GetTab(Index);
  if t = nil then Exit;
  if AName <> '' then
    t.Name := AName;
end;

procedure TPlaylistBook.RemoveTab(Index: Integer);
begin
  if (Index < 0) or (Index >= FTabs.Count) then Exit;
  if FTabs.Count <= 1 then Exit;
  TPlaylistTab(FTabs[Index]).Free;
  FTabs.Delete(Index);
  if FActive >= FTabs.Count then
    FActive := FTabs.Count - 1
  else if FActive > Index then
    Dec(FActive);
end;

procedure TPlaylistBook.SwitchTo(Index: Integer);
begin
  if (Index < 0) or (Index >= FTabs.Count) then Exit;
  FActive := Index;
end;

procedure TPlaylistBook.LoadFromTtblDir(const Dir: string; Count, ActiveList: Integer);
var
  i, actual, k: Integer;
  path, tabName: string;
  hdr: TTtblHeader;
  parsed: TTtblEntryArray;
  tab: TPlaylistTab;
begin
  Clear;
  actual := Count;
  if actual < 1 then actual := 1;
  for i := 0 to actual - 1 do
  begin
    path := IncludeTrailingPathDelimiter(Dir) + Format('%.4d.ttbl', [i]);
    parsed := ParseTtblFile(path, hdr);
    if hdr.ListName <> '' then
      tabName := hdr.ListName
    else if i = 0 then
      tabName := '[默认]'
    else
      tabName := Format('[%d]', [i]);
    AddTab(tabName);
    tab := GetTab(FTabs.Count - 1);
    for k := 0 to High(parsed) do
    begin
      tab.Model.AddFile(parsed[k].FilePath);
      if (parsed[k].Title <> '') or (parsed[k].DurationMs > 0) then
        tab.Model.SetMetadata(tab.Model.Count - 1, parsed[k].Title,
          parsed[k].Artist, '', parsed[k].DurationMs);
    end;
    if hdr.CurrentIndex >= 0 then
      tab.Model.SetCurrentIndex(hdr.CurrentIndex);
  end;
  if FTabs.Count = 0 then
    AddTab('[默认]');
  if ActiveList < 0 then ActiveList := 0;
  if ActiveList >= FTabs.Count then ActiveList := FTabs.Count - 1;
  FActive := ActiveList;
end;

function TPlaylistBook.SaveToTtblDir(const Dir: string): Integer;
var
  i, n: Integer;
  path: string;
  tab: TPlaylistTab;
  entries: TPlaylistEntryArray;
begin
  if not DirectoryExists(Dir) then
    ForceDirectories(Dir);
  for i := 0 to FTabs.Count - 1 do
  begin
    tab := GetTab(i);
    path := IncludeTrailingPathDelimiter(Dir) + Format('%.4d.ttbl', [i]);
    n := tab.Model.Count;
    SetLength(entries, n);
    while n > 0 do
    begin
      Dec(n);
      entries[n] := tab.Model.Entries[n];
    end;
    n := tab.Model.Count;
    WriteTtblFile(path, entries, n, tab.Name, tab.Model.CurrentIndex);
  end;
  Result := FActive;
end;

end.
