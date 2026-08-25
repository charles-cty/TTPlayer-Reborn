unit UTtplayerHost;

{$mode objfpc}{$H+}

// ttplayer 宿主：TTPlayer.xml、系统托盘、与播放器右键共用的命令集。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, ExtCtrls, Menus, LCLType,
  USkinTypes, USkinLoader, UPlayerForm, UEqualizerForm, ULyricForm,
  UPlaylistForm, UPlayerBackend, UTtcoreBackend, UWindowSnapManager, UFormSnap,
  UPlayerConfig, UPlayerMenuSpec, UPlatformWindow;

type
  TTtplayerHost = class
  private
    FEngine: TSkinEngine;
    FBackend: IPlayerBackend;
    FConfig: TPlayerConfig;
    FPlayer: TPlayerForm;
    FEq: TEqualizerForm;
    FLyric: TLyricForm;
    FPlaylist: TPlaylistForm;
    FSnap: TWindowSnapManager;
    FPlayerWin, FEqWin, FLyricWin, FPlaylistWin: ISnapWindow;
    FTray: TTrayIcon;
    FTrayMenu: TPopupMenu;
    FPlayerMenu: TPopupMenu;
    FActiveMenu: TPopupMenu;
    FSkinMenu: TMenuItem;
    FItemLyric: TMenuItem;
    FItemEq: TMenuItem;
    FItemPlaylist: TMenuItem;
    FItemOnTop: TMenuItem;
    FAuxLyric, FAuxEq, FAuxPlaylist: Boolean;
    FLastFile: string;
    FSuppressAux: Boolean;
    procedure HandleAuxToggle(Sender: TObject; const AType: string;
      AToggled: Boolean);
    procedure HandleLyricResize(Sender: TObject);
    procedure HandleLyricResizeFinished(Sender: TObject);
    procedure HandlePlaylistResize(Sender: TObject);
    procedure HandlePlaylistResizeFinished(Sender: TObject);
    procedure HandlePlayFile(Sender: TObject; const FilePath: string);
    procedure HandlePrev(Sender: TObject);
    procedure HandleNext(Sender: TObject);
    procedure HandleOpen(Sender: TObject);
    procedure HandlePlay(Sender: TObject);
    procedure HandleTrackFinished(Sender: TObject);
    procedure HandlePlayerContextMenu(Sender: TObject);
    procedure HandleLyricClosed(Sender: TObject);
    procedure HandleAuxHide(Sender: TObject);
    procedure HandleTrayClick(Sender: TObject);
    procedure HandleTrayMenuPopup(Sender: TObject);
    procedure HandleTrayCommand(Sender: TObject);
    procedure HandleSkinClick(Sender: TObject);
    procedure HandlePlayModeClick(Sender: TObject);
    procedure BuildCommandMenu(AMenu: TPopupMenu);
    procedure BindMenuItems(AMenu: TPopupMenu);
    procedure RebuildSkinMenu;
    procedure SyncTrayChecks;
    procedure PopupPlayerMenu;
    procedure ShowMainWindow;
    procedure ApplyAlwaysOnTop(Enabled: Boolean);
    procedure ApplySkinFile(const SknPath: string);
    procedure ApplyLoadedConfig;
    procedure RestoreGeometry;
    procedure LoadPlaylists;
    procedure SaveState;
    procedure SetAuxVisible(const AType: string; AToggled: Boolean);
    function RepoRoot: string;
    function ExeDir: string;
    function SkinDir: string;
    function ConfigFilePath: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

implementation

uses
  LazFileUtils, Math
  {$IFDEF WINDOWS}, Windows{$ENDIF};

function TTtplayerHost.RepoRoot: string;
begin
  Result := AppendPathDelim(ExpandFileName(
    ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..'));
end;

function TTtplayerHost.ExeDir: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

function TTtplayerHost.SkinDir: string;
begin
  Result := RepoRoot + 'Skin';
end;

function TTtplayerHost.ConfigFilePath: string;
begin
  Result := DefaultConfigPath(ExeDir);
end;

constructor TTtplayerHost.Create;
begin
  FConfig := TPlayerConfig.Create;
  LoadPlayerConfig(FConfig, ExeDir);

  FBackend := TTtcoreBackend.Create;
  FEngine := TSkinEngine.Create;
  FSnap := TWindowSnapManager.Create;
  FSuppressAux := False;
  FAuxLyric := FConfig.LyricVisible;
  FAuxEq := FConfig.EqVisible;
  FAuxPlaylist := FConfig.PlaylistVisible;
  FLastFile := FConfig.LastFile;

  Application.CreateForm(TPlayerForm, FPlayer);
  FPlayer.AttachBackend(FBackend);
  FEq := TEqualizerForm.Create(Application, FBackend);
  FLyric := TLyricForm.Create(Application, FBackend);
  FPlaylist := TPlaylistForm.Create(Application, FBackend);
  FPlaylist.OnPlayFile := @HandlePlayFile;
  FPlayer.OnAuxToggle := @HandleAuxToggle;
  FPlayer.OnPrev := @HandlePrev;
  FPlayer.OnNext := @HandleNext;
  FPlayer.OnOpen := @HandleOpen;
  FPlayer.OnPlay := @HandlePlay;
  FPlayer.OnContextMenu := @HandlePlayerContextMenu;
  FBackend.SetOnTrackFinished(@HandleTrackFinished);
  FLyric.OnResizeInProgress := @HandleLyricResize;
  FLyric.OnResizeFinished := @HandleLyricResizeFinished;
  FLyric.OnCloseRequested := @HandleLyricClosed;
  FLyric.OnHide := @HandleAuxHide;
  FEq.OnHide := @HandleAuxHide;
  FPlaylist.OnResizeInProgress := @HandlePlaylistResize;
  FPlaylist.OnResizeFinished := @HandlePlaylistResizeFinished;
  FPlaylist.OnHide := @HandleAuxHide;

  // 托盘与窗口右键必须用两份菜单：GTK3 AppIndicator 会独占 PopUpMenu 的 GtkMenu，
  // 再对同一份调用 gtk_menu_popup 会没有任何反应。
  FPlayerMenu := TPopupMenu.Create(FPlayer);
  FPlayerMenu.OnPopup := @HandleTrayMenuPopup;
  BuildCommandMenu(FPlayerMenu);
  FPlayer.PopupMenu := FPlayerMenu;

  FTrayMenu := TPopupMenu.Create(FPlayer);
  FTrayMenu.OnPopup := @HandleTrayMenuPopup;
  BuildCommandMenu(FTrayMenu);

  FTray := TTrayIcon.Create(FPlayer);
  FTray.PopUpMenu := FTrayMenu;
  FTray.Hint := 'TTPlayer';
  FTray.OnClick := @HandleTrayClick;
  FTray.OnDblClick := @HandleTrayClick;
  if not Application.Icon.Empty then
    FTray.Icon.Assign(Application.Icon)
  {$IFDEF WINDOWS}
  else
    FTray.Icon.Handle := Windows.LoadIcon(0, IDI_APPLICATION)
  {$ENDIF};
end;

destructor TTtplayerHost.Destroy;
begin
  SaveState;
  if FBackend <> nil then
    FBackend.SetOnTrackFinished(nil);
  if FSnap <> nil then
    FSnap.ClearWindows;
  FPlayerWin := nil;
  FEqWin := nil;
  FLyricWin := nil;
  FPlaylistWin := nil;
  if FTray <> nil then
    FTray.Visible := False;
  FTray := nil;
  FreeAndNil(FPlayer);
  FreeAndNil(FEq);
  FreeAndNil(FLyric);
  FreeAndNil(FPlaylist);
  FreeAndNil(FSnap);
  FreeAndNil(FEngine);
  FreeAndNil(FConfig);
  FBackend := nil;
  inherited Destroy;
end;

procedure TTtplayerHost.BuildCommandMenu(AMenu: TPopupMenu);
var
  i, j: Integer;
  cap: string;
  item, modeItem: TMenuItem;
begin
  AMenu.Items.Clear;
  for i := Low(PlayerTrayCaptions) to High(PlayerTrayCaptions) do
  begin
    cap := PlayerTrayCaptions[i];
    if CaptionIsSeparator(cap) then
    begin
      item := TMenuItem.Create(AMenu);
      item.Caption := '-';
      AMenu.Items.Add(item);
      Continue;
    end;
    if cap = '切换皮肤' then
    begin
      item := TMenuItem.Create(AMenu);
      item.Caption := cap;
      AMenu.Items.Add(item);
      Continue;
    end;
    if cap = '播放模式' then
    begin
      item := TMenuItem.Create(AMenu);
      item.Caption := cap;
      AMenu.Items.Add(item);
      for j := Low(PlayModeCaptions) to High(PlayModeCaptions) do
      begin
        modeItem := TMenuItem.Create(item);
        modeItem.Caption := PlayModeCaptions[j];
        modeItem.RadioItem := True;
        modeItem.GroupIndex := 1;
        modeItem.Tag := j;
        modeItem.OnClick := @HandlePlayModeClick;
        item.Add(modeItem);
      end;
      Continue;
    end;
    item := TMenuItem.Create(AMenu);
    item.Caption := cap;
    item.OnClick := @HandleTrayCommand;
    if (cap = '歌词窗口') or (cap = '均衡器') or (cap = '播放列表') or
       (cap = '窗口置顶') then
      item.AutoCheck := True;
    AMenu.Items.Add(item);
  end;
end;

procedure TTtplayerHost.BindMenuItems(AMenu: TPopupMenu);
var
  i: Integer;
  cap: string;
begin
  FActiveMenu := AMenu;
  FSkinMenu := nil;
  FItemLyric := nil;
  FItemEq := nil;
  FItemPlaylist := nil;
  FItemOnTop := nil;
  if AMenu = nil then Exit;
  for i := 0 to AMenu.Items.Count - 1 do
  begin
    cap := StringReplace(AMenu.Items[i].Caption, '&', '', [rfReplaceAll]);
    if cap = '切换皮肤' then FSkinMenu := AMenu.Items[i]
    else if cap = '歌词窗口' then FItemLyric := AMenu.Items[i]
    else if cap = '均衡器' then FItemEq := AMenu.Items[i]
    else if cap = '播放列表' then FItemPlaylist := AMenu.Items[i]
    else if cap = '窗口置顶' then FItemOnTop := AMenu.Items[i];
  end;
end;

procedure TTtplayerHost.RebuildSkinMenu;
var
  skins: TSkinChoiceArray;
  i: Integer;
  item: TMenuItem;
  active: string;
begin
  if FSkinMenu = nil then Exit;
  FSkinMenu.Clear;
  skins := DiscoverSkins(SkinDir);
  active := FConfig.SkinPath;
  for i := 0 to High(skins) do
  begin
    item := TMenuItem.Create(FSkinMenu);
    item.Caption := skins[i].DisplayName;
    item.Hint := skins[i].Path;
    item.RadioItem := True;
    item.Checked := SameFileName(skins[i].Path, active) or
      SameText(ExtractFileName(skins[i].Path), ExtractFileName(active));
    item.OnClick := @HandleSkinClick;
    FSkinMenu.Add(item);
  end;
end;

procedure TTtplayerHost.SyncTrayChecks;
var
  i: Integer;
  parent: TMenuItem;
  wantRepeat: Integer;
  wantShuffle: Boolean;
begin
  FSuppressAux := True;
  try
    if FItemLyric <> nil then FItemLyric.Checked := FAuxLyric;
    if FItemEq <> nil then FItemEq.Checked := FAuxEq;
    if FItemPlaylist <> nil then FItemPlaylist.Checked := FAuxPlaylist;
    if FItemOnTop <> nil then FItemOnTop.Checked := FConfig.AlwaysOnTop;
    if (FPlaylist = nil) or (FActiveMenu = nil) then Exit;
    wantRepeat := FPlaylist.RepeatMode;
    wantShuffle := FPlaylist.Shuffle;
    for i := 0 to FActiveMenu.Items.Count - 1 do
    begin
      parent := FActiveMenu.Items[i];
      if parent.Caption <> '播放模式' then Continue;
      if parent.Count >= 4 then
      begin
        parent.Items[0].Checked := (wantRepeat = 0) and (not wantShuffle);
        parent.Items[1].Checked := (wantRepeat = 1) and (not wantShuffle);
        parent.Items[2].Checked := (wantRepeat = 2) and (not wantShuffle);
        parent.Items[3].Checked := (wantRepeat = 2) and wantShuffle;
      end;
    end;
  finally
    FSuppressAux := False;
  end;
end;

procedure TTtplayerHost.HandleTrayMenuPopup(Sender: TObject);
begin
  if Sender is TPopupMenu then
    BindMenuItems(TPopupMenu(Sender));
  RebuildSkinMenu;
  SyncTrayChecks;
end;

procedure TTtplayerHost.HandleSkinClick(Sender: TObject);
var
  path: string;
begin
  path := TMenuItem(Sender).Hint;
  if path = '' then Exit;
  ApplySkinFile(path);
  FConfig.SkinPath := path;
end;

procedure TTtplayerHost.HandlePlayModeClick(Sender: TObject);
begin
  if FSuppressAux then Exit;
  case TMenuItem(Sender).Tag of
    0: FPlaylist.SetPlaybackMode(0, False);
    1: FPlaylist.SetPlaybackMode(1, False);
    2: FPlaylist.SetPlaybackMode(2, False);
    3: FPlaylist.SetPlaybackMode(2, True);
  end;
  FConfig.RepeatMode := FPlaylist.RepeatMode;
  FConfig.Shuffle := FPlaylist.Shuffle;
end;

procedure TTtplayerHost.HandleTrayCommand(Sender: TObject);
var
  cap: string;
  vol: Integer;
begin
  if FSuppressAux then Exit;
  cap := TMenuItem(Sender).Caption;
  cap := StringReplace(cap, '&', '', [rfReplaceAll]);
  if cap = '显示主窗口' then
    ShowMainWindow
  else if cap = '打开文件...' then
    HandleOpen(Sender)
  else if cap = '播放/暂停' then
  begin
    if (FBackend <> nil) and (FBackend.GetState = psPlaying) then
      FBackend.Pause
    else
      HandlePlay(Sender);
  end
  else if cap = '停止' then
  begin
    if FBackend <> nil then FBackend.Stop;
  end
  else if cap = '上一首' then
    HandlePrev(Sender)
  else if cap = '下一首' then
    HandleNext(Sender)
  else if cap = '静音切换' then
  begin
    if FBackend <> nil then
      FBackend.SetMuted(not FBackend.GetIsMuted);
  end
  else if cap = '音量 +5' then
  begin
    if FBackend <> nil then
    begin
      vol := FBackend.GetVolume + 5;
      if vol > 100 then vol := 100;
      FBackend.SetVolume(vol);
    end;
  end
  else if cap = '音量 -5' then
  begin
    if FBackend <> nil then
    begin
      vol := FBackend.GetVolume - 5;
      if vol < 0 then vol := 0;
      FBackend.SetVolume(vol);
    end;
  end
  else if cap = '歌词窗口' then
    SetAuxVisible('lyric', TMenuItem(Sender).Checked)
  else if cap = '均衡器' then
    SetAuxVisible('equalizer', TMenuItem(Sender).Checked)
  else if cap = '播放列表' then
    SetAuxVisible('playlist', TMenuItem(Sender).Checked)
  else if cap = '窗口置顶' then
  begin
    FConfig.AlwaysOnTop := TMenuItem(Sender).Checked;
    ApplyAlwaysOnTop(FConfig.AlwaysOnTop);
  end
  else if cap = '退出' then
    Application.Terminate;
end;

procedure TTtplayerHost.HandleTrayClick(Sender: TObject);
begin
  if Sender = nil then ;
  ShowMainWindow;
end;

procedure TTtplayerHost.PopupPlayerMenu;
var
  pt: TPoint;
begin
  if FPlayerMenu = nil then Exit;
  BindMenuItems(FPlayerMenu);
  RebuildSkinMenu;
  SyncTrayChecks;
  pt := Mouse.CursorPos;
  FPlayerMenu.PopUp(pt.X, pt.Y);
end;

procedure TTtplayerHost.HandlePlayerContextMenu(Sender: TObject);
begin
  if Sender = nil then ;
  PopupPlayerMenu;
end;

procedure TTtplayerHost.ShowMainWindow;
begin
  if FPlayer.WindowState = wsMinimized then
    FPlayer.WindowState := wsNormal;
  FPlayer.Show;
  FPlayer.BringToFront;
  if FAuxPlaylist then FPlaylist.Show;
  if FAuxLyric then FLyric.Show;
  if FAuxEq then FEq.Show;
end;

procedure TTtplayerHost.ApplyAlwaysOnTop(Enabled: Boolean);
begin
  FConfig.AlwaysOnTop := Enabled;
  FPlayer.SetAlwaysOnTopState(Enabled);
  SetWindowAlwaysOnTop(FEq, Enabled);
  SetWindowAlwaysOnTop(FLyric, Enabled);
  SetWindowAlwaysOnTop(FPlaylist, Enabled);
end;

procedure TTtplayerHost.SetAuxVisible(const AType: string; AToggled: Boolean);
begin
  FSuppressAux := True;
  try
    if SameText(AType, 'lyric') then
    begin
      FAuxLyric := AToggled;
      if AToggled then FLyric.Show else FLyric.Hide;
    end
    else if SameText(AType, 'equalizer') then
    begin
      FAuxEq := AToggled;
      if AToggled then FEq.Show else FEq.Hide;
    end
    else if SameText(AType, 'playlist') then
    begin
      FAuxPlaylist := AToggled;
      if AToggled then FPlaylist.Show else FPlaylist.Hide;
    end;
    FPlayer.SetAuxToggle(AType, AToggled);
  finally
    FSuppressAux := False;
  end;
  SyncTrayChecks;
end;

procedure TTtplayerHost.HandleAuxToggle(Sender: TObject; const AType: string;
  AToggled: Boolean);
begin
  if Sender = nil then ;
  if FSuppressAux then Exit;
  if SameText(AType, 'ontop') then
    ApplyAlwaysOnTop(AToggled)
  else
    SetAuxVisible(AType, AToggled);
end;

procedure TTtplayerHost.HandleLyricClosed(Sender: TObject);
begin
  if Sender = nil then ;
  FAuxLyric := False;
  FPlayer.SetAuxToggle('lyric', False);
  SyncTrayChecks;
end;

procedure TTtplayerHost.HandleAuxHide(Sender: TObject);
begin
  if FSuppressAux then Exit;
  if Sender = FLyric then
  begin
    FAuxLyric := False;
    FPlayer.SetAuxToggle('lyric', False);
  end
  else if Sender = FEq then
  begin
    FAuxEq := False;
    FPlayer.SetAuxToggle('equalizer', False);
  end
  else if Sender = FPlaylist then
  begin
    FAuxPlaylist := False;
    FPlayer.SetAuxToggle('playlist', False);
  end;
  SyncTrayChecks;
end;

procedure TTtplayerHost.HandleLyricResize(Sender: TObject);
begin
  if FLyricWin = nil then Exit;
  FSnap.OnSubResized(FLyricWin,
    ResizeEdgesOf(FLyric.ResizeEdgeRight, FLyric.ResizeEdgeBottom));
end;

procedure TTtplayerHost.HandleLyricResizeFinished(Sender: TObject);
begin
  if FLyricWin = nil then Exit;
  FSnap.OnSubResizeFinished(FLyricWin,
    ResizeEdgesOf(FLyric.ResizeEdgeRight, FLyric.ResizeEdgeBottom));
end;

procedure TTtplayerHost.HandlePlaylistResize(Sender: TObject);
begin
  if FPlaylistWin = nil then Exit;
  FSnap.OnSubResized(FPlaylistWin,
    ResizeEdgesOf(FPlaylist.ResizeEdgeRight, FPlaylist.ResizeEdgeBottom));
end;

procedure TTtplayerHost.HandlePlaylistResizeFinished(Sender: TObject);
begin
  if FPlaylistWin = nil then Exit;
  FSnap.OnSubResizeFinished(FPlaylistWin,
    ResizeEdgesOf(FPlaylist.ResizeEdgeRight, FPlaylist.ResizeEdgeBottom));
end;

procedure TTtplayerHost.HandlePlayFile(Sender: TObject; const FilePath: string);
var
  lrc: string;
begin
  if Sender = nil then ;
  FLastFile := FilePath;
  lrc := ChangeFileExt(FilePath, '.lrc');
  if FileExists(lrc) then
    FLyric.LoadLrc(lrc)
  else
    FLyric.ClearLrc;
  FLyric.SetTrackInfo(FBackend.GetTitle, FBackend.GetArtist);
end;

procedure TTtplayerHost.HandlePrev(Sender: TObject);
begin
  if Sender = nil then ;
  if FPlaylist <> nil then
    FPlaylist.PlayPrev;
end;

procedure TTtplayerHost.HandleNext(Sender: TObject);
begin
  if Sender = nil then ;
  if FPlaylist <> nil then
    FPlaylist.PlayNext;
end;

procedure TTtplayerHost.HandleOpen(Sender: TObject);
begin
  if Sender = nil then ;
  if FPlaylist <> nil then
    FPlaylist.OpenFilesAndPlay;
end;

procedure TTtplayerHost.HandlePlay(Sender: TObject);
begin
  if Sender = nil then ;
  if FBackend = nil then Exit;
  case FBackend.GetState of
    psPaused, psStopped:
      FBackend.Play;
  else
    if FPlaylist <> nil then
    begin
      FPlaylist.PlayCurrent;
      if FBackend.GetState = psIdle then
        FPlaylist.OpenFilesAndPlay;
    end
    else
      FBackend.Play;
  end;
end;

procedure TTtplayerHost.HandleTrackFinished(Sender: TObject);
begin
  if Sender = nil then ;
  if FPlaylist <> nil then
    FPlaylist.PlayNext;
end;

procedure TTtplayerHost.ApplySkinFile(const SknPath: string);
begin
  if (SknPath = '') or (not FileExists(SknPath)) then Exit;
  if not FEngine.LoadFromFile(SknPath) then Exit;
  FPlayer.ApplySkin(FEngine.SkinPtr);
  FEq.ApplySkin(FEngine.SkinPtr);
  FLyric.ApplySkin(FEngine.SkinPtr);
  FPlaylist.ApplySkin(FEngine.SkinPtr);
  if FConfig.AlwaysOnTop then
    ApplyAlwaysOnTop(True);
end;

procedure TTtplayerHost.ApplyLoadedConfig;
var
  bands: array[0..9] of Double;
  i: Integer;
begin
  if FBackend <> nil then
  begin
    FBackend.SetVolume(FConfig.Volume);
    FBackend.SetMuted(FConfig.Muted);
    FBackend.SetBalance(FConfig.Balance);
  end;
  for i := 0 to 9 do
    bands[i] := FConfig.EqBands[i];
  FEq.ApplyEqConfig(FConfig.EqEnabled, FConfig.EqPreamp, bands, FConfig.Balance);
  FPlaylist.SetPlaybackMode(FConfig.RepeatMode, FConfig.Shuffle);
end;

procedure TTtplayerHost.RestoreGeometry;
begin
  if FConfig.PlayerW > 0 then
    FPlayer.SetBounds(FConfig.PlayerX, FConfig.PlayerY,
      FConfig.PlayerW, FConfig.PlayerH)
  else
  begin
    FPlayer.Left := FConfig.PlayerX;
    FPlayer.Top := FConfig.PlayerY;
  end;
  if FConfig.LyricW > 0 then
    FLyric.SetBounds(FConfig.LyricX, FConfig.LyricY,
      FConfig.LyricW, FConfig.LyricH)
  else
  begin
    FLyric.Left := FConfig.LyricX;
    FLyric.Top := FConfig.LyricY;
  end;
  if FConfig.EqW > 0 then
    FEq.SetBounds(FConfig.EqX, FConfig.EqY, FConfig.EqW, FConfig.EqH)
  else
  begin
    FEq.Left := FConfig.EqX;
    FEq.Top := FConfig.EqY;
  end;
  if FConfig.PlaylistW > 0 then
    FPlaylist.SetBounds(FConfig.PlaylistX, FConfig.PlaylistY,
      FConfig.PlaylistW, FConfig.PlaylistH)
  else
  begin
    FPlaylist.Left := FConfig.PlaylistX;
    FPlaylist.Top := FConfig.PlaylistY;
  end;
  FPlaylist.SetDividerPosition(FConfig.PlaylistSplitPos);
end;

procedure TTtplayerHost.LoadPlaylists;
var
  dir: string;
  count, active: Integer;
begin
  dir := FConfig.PlaylistDir;
  if (dir = '') or (not DirectoryExists(dir)) then
  begin
    if DirectoryExists(RepoRoot + 'PlayList') then
      dir := RepoRoot + 'PlayList'
    else if DirectoryExists(RepoRoot + 'build-mingw64' + PathDelim + 'PlayList') then
      dir := RepoRoot + 'build-mingw64' + PathDelim + 'PlayList'
    else
      dir := IncludeTrailingPathDelimiter(ExeDir) + 'PlayList';
  end;
  FConfig.PlaylistDir := ExpandFileName(dir);
  count := FConfig.PlaylistCount;
  if count < 1 then count := 1;
  active := FConfig.ActiveList;
  if active < 0 then active := 0;
  if DirectoryExists(dir) then
    FPlaylist.LoadFromTtblDir(dir, count, active);
end;

procedure TTtplayerHost.SaveState;
var
  i: Integer;
  dir: string;
begin
  if FConfig = nil then Exit;
  if FBackend <> nil then
  begin
    FConfig.Volume := FBackend.GetVolume;
    FConfig.Muted := FBackend.GetIsMuted;
    FConfig.Balance := FBackend.GetBalance;
    FConfig.EqEnabled := FBackend.GetEqEnabled;
  end;
  if FEq <> nil then
  begin
    FConfig.EqEnabled := FEq.GetEqEnabled;
    FConfig.EqPreamp := FEq.GetPreamp;
    for i := 0 to 9 do
      FConfig.EqBands[i] := FEq.GetEqBand(i);
    FConfig.Balance := FEq.GetBalanceValue;
  end;
  if FPlayer <> nil then
  begin
    FConfig.PlayerX := FPlayer.Left;
    FConfig.PlayerY := FPlayer.Top;
    FConfig.PlayerW := FPlayer.Width;
    FConfig.PlayerH := FPlayer.Height;
    FConfig.AlwaysOnTop := FPlayer.AlwaysOnTopState;
  end;
  if FLyric <> nil then
  begin
    FConfig.LyricX := FLyric.Left;
    FConfig.LyricY := FLyric.Top;
    FConfig.LyricW := FLyric.Width;
    FConfig.LyricH := FLyric.Height;
  end;
  if FEq <> nil then
  begin
    FConfig.EqX := FEq.Left;
    FConfig.EqY := FEq.Top;
    FConfig.EqW := FEq.Width;
    FConfig.EqH := FEq.Height;
  end;
  if FPlaylist <> nil then
  begin
    FConfig.PlaylistX := FPlaylist.Left;
    FConfig.PlaylistY := FPlaylist.Top;
    FConfig.PlaylistW := FPlaylist.Width;
    FConfig.PlaylistH := FPlaylist.Height;
    FConfig.PlaylistSplitPos := FPlaylist.DividerPosition;
    FConfig.RepeatMode := FPlaylist.RepeatMode;
    FConfig.Shuffle := FPlaylist.Shuffle;
  end;
  FConfig.LyricVisible := FAuxLyric;
  FConfig.EqVisible := FAuxEq;
  FConfig.PlaylistVisible := FAuxPlaylist;
  FConfig.LastFile := FLastFile;

  dir := FConfig.PlaylistDir;
  if dir = '' then
    dir := RepoRoot + 'PlayList';
  if not DirectoryExists(dir) then
    ForceDirectories(dir);
  if (FPlaylist <> nil) and DirectoryExists(dir) then
  begin
    FConfig.ActiveList := FPlaylist.SaveToTtblDir(dir);
    FConfig.PlaylistCount := FPlaylist.TabCount;
    FConfig.PlaylistDir := ExpandFileName(dir);
  end;
  FConfig.SaveToFile(ConfigFilePath);
end;

procedure TTtplayerHost.Run;
var
  sknPath: string;
begin
  ApplyLoadedConfig;

  sknPath := ResolveSkinPath(FConfig.SkinPath, SkinDir);
  if sknPath <> '' then
  begin
    ApplySkinFile(sknPath);
    FConfig.SkinPath := sknPath;
  end;

  RestoreGeometry;
  ApplyAlwaysOnTop(FConfig.AlwaysOnTop);
  LoadPlaylists;

  FPlayer.SetAuxToggle('lyric', FAuxLyric);
  FPlayer.SetAuxToggle('equalizer', FAuxEq);
  FPlayer.SetAuxToggle('playlist', FAuxPlaylist);

  FPlayerWin := HookSnapWindow(FPlayer, FSnap, True);
  FEqWin := HookSnapWindow(FEq, FSnap, False);
  FLyricWin := HookSnapWindow(FLyric, FSnap, False);
  FPlaylistWin := HookSnapWindow(FPlaylist, FSnap, False);

  FPlayer.Show;
  FSuppressAux := True;
  try
    if FAuxEq then FEq.Show else FEq.Hide;
    if FAuxLyric then FLyric.Show else FLyric.Hide;
    if FAuxPlaylist then FPlaylist.Show else FPlaylist.Hide;
  finally
    FSuppressAux := False;
  end;
  FSnap.RebuildSnapGraph;

  try
    FTray.Visible := True;
  except
  end;
  BindMenuItems(FPlayerMenu);
  RebuildSkinMenu;
  SyncTrayChecks;

  Application.Run;
end;

end.
