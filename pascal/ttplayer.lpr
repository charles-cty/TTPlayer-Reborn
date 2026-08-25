program ttplayer;

{$mode objfpc}{$H+}

// 主播放器入口（阶段占位）。
// 本阶段不接入真实音频：用 TStubBackend 驱动四个窗口，
// 自动加载 Skin/ 目录中第一个 .skn 皮肤并展示 PlayerForm/
// EqualizerForm/LyricForm/PlaylistForm。Step 7 接入 ttcore FFI 时再替换桩。

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  UHeapTraceConfig,
  UGdkX11Backend,
  UWinDpiAware,
  Interfaces,
  Classes, SysUtils, Forms,
  LazFileUtils,
  USkinTypes, USkinLoader,
  UPlayerForm, UEqualizerForm, ULyricForm, UPlaylistForm, UPlayerBackend,
  UWindowSnapManager, UFormSnap;

// 返回仓库根目录（bin/ -> pascal/ -> repo root）。
function RepoRoot: string;
begin
  Result := AppendPathDelim(ExpandFileName(
    ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..'));
end;

// 查找 Skin/ 下第一个 .skn 文件；失败返回空字符串。
function FindFirstSkin: string;
var
  sr: TSearchRec;
  dir: string;
begin
  Result := '';
  dir := RepoRoot + 'Skin' + PathDelim;
  if FindFirst(dir + '*.skn', faAnyFile, sr) = 0 then
  begin
    try
      Result := dir + sr.Name;
    finally
      FindClose(sr);
    end;
  end;
end;

type
  // 应用对象：持有皮肤引擎、后端桩和四个子窗口的生命周期。
  TTPlayerApp = class
  private
    FEngine:    TSkinEngine;
    FBackend:   TStubBackend;
    FPlayer:    TPlayerForm;
    FEq:        TEqualizerForm;
    FLyric:     TLyricForm;
    FPlaylist:  TPlaylistForm;
    FSnap:      TWindowSnapManager;
    FPlayerWin, FEqWin, FLyricWin, FPlaylistWin: ISnapWindow;
    procedure HandleAuxToggle(Sender: TObject; const AType: string;
      AToggled: Boolean);
    procedure HandleLyricResize(Sender: TObject);
    procedure HandleLyricResizeFinished(Sender: TObject);
    procedure HandlePlaylistResize(Sender: TObject);
    procedure HandlePlaylistResizeFinished(Sender: TObject);
    procedure HandlePlayFile(Sender: TObject; const FilePath: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TTPlayerApp.Create;
begin
  FBackend := TStubBackend.Create;
  FEngine  := TSkinEngine.Create;
  FSnap    := TWindowSnapManager.Create;
  FPlayer  := TPlayerForm.Create(Application, FBackend);
  FEq      := TEqualizerForm.Create(Application, FBackend);
  FLyric   := TLyricForm.Create(Application, FBackend);
  FPlaylist := TPlaylistForm.Create(Application, FBackend);
  FPlaylist.OnPlayFile := @HandlePlayFile;
  FPlayer.OnAuxToggle := @HandleAuxToggle;
  FLyric.OnResizeInProgress := @HandleLyricResize;
  FLyric.OnResizeFinished := @HandleLyricResizeFinished;
  FPlaylist.OnResizeInProgress := @HandlePlaylistResize;
  FPlaylist.OnResizeFinished := @HandlePlaylistResizeFinished;
end;

destructor TTPlayerApp.Destroy;
begin
  if FSnap <> nil then
    FSnap.ClearWindows;
  FPlayerWin := nil;
  FEqWin := nil;
  FLyricWin := nil;
  FPlaylistWin := nil;
  FPlayer.Free;
  FEq.Free;
  FLyric.Free;
  FPlaylist.Free;
  FSnap.Free;
  FEngine.Free;
  FBackend := nil;  // TInterfacedObject，随最后的接口引用释放
  inherited Destroy;
end;

procedure TTPlayerApp.HandleAuxToggle(Sender: TObject; const AType: string;
  AToggled: Boolean);
begin
  if SameText(AType, 'lyric') then
  begin
    if AToggled then FLyric.Show else FLyric.Hide;
  end
  else if SameText(AType, 'equalizer') then
  begin
    if AToggled then FEq.Show else FEq.Hide;
  end
  else if SameText(AType, 'playlist') then
  begin
    if AToggled then FPlaylist.Show else FPlaylist.Hide;
  end;
end;

procedure TTPlayerApp.HandleLyricResize(Sender: TObject);
begin
  if FLyricWin = nil then Exit;
  FSnap.OnSubResized(FLyricWin,
    ResizeEdgesOf(FLyric.ResizeEdgeRight, FLyric.ResizeEdgeBottom));
end;

procedure TTPlayerApp.HandleLyricResizeFinished(Sender: TObject);
begin
  if FLyricWin = nil then Exit;
  FSnap.OnSubResizeFinished(FLyricWin,
    ResizeEdgesOf(FLyric.ResizeEdgeRight, FLyric.ResizeEdgeBottom));
end;

procedure TTPlayerApp.HandlePlaylistResize(Sender: TObject);
begin
  if FPlaylistWin = nil then Exit;
  FSnap.OnSubResized(FPlaylistWin,
    ResizeEdgesOf(FPlaylist.ResizeEdgeRight, FPlaylist.ResizeEdgeBottom));
end;

procedure TTPlayerApp.HandlePlaylistResizeFinished(Sender: TObject);
begin
  if FPlaylistWin = nil then Exit;
  FSnap.OnSubResizeFinished(FPlaylistWin,
    ResizeEdgesOf(FPlaylist.ResizeEdgeRight, FPlaylist.ResizeEdgeBottom));
end;

procedure TTPlayerApp.HandlePlayFile(Sender: TObject; const FilePath: string);
var
  lrc: string;
begin
  if Sender = nil then ;
  lrc := ChangeFileExt(FilePath, '.lrc');
  if FileExists(lrc) then
    FLyric.LoadLrc(lrc)
  else
    FLyric.ClearLrc;
  FLyric.SetTrackInfo(FBackend.GetTitle, FBackend.GetArtist);
end;

procedure TTPlayerApp.Run;
var
  sknPath: string;
begin
  sknPath := FindFirstSkin;
  if (sknPath <> '') and FEngine.LoadFromFile(sknPath) then
  begin
    FPlayer.ApplySkin(FEngine.SkinPtr);
    FEq.ApplySkin(FEngine.SkinPtr);
    FLyric.ApplySkin(FEngine.SkinPtr);
    FPlaylist.ApplySkin(FEngine.SkinPtr);
  end;

  FPlayer.SetAuxToggle('lyric', True);
  FPlayer.SetAuxToggle('equalizer', True);
  FPlayer.SetAuxToggle('playlist', True);

  if DirectoryExists(RepoRoot + 'PlayList') then
    FPlaylist.LoadFromTtblDir(RepoRoot + 'PlayList', 4, 0)
  else if DirectoryExists(RepoRoot + 'build-mingw64' + PathDelim + 'PlayList') then
    FPlaylist.LoadFromTtblDir(RepoRoot + 'build-mingw64' + PathDelim + 'PlayList', 4, 0);

  FPlayer.Left := 40;
  FPlayer.Top  := 40;
  FEq.Left := 40;
  FEq.Top  := 200;
  FLyric.Left := 40;
  FLyric.Top  := 360;
  FPlaylist.Left := 360;
  FPlaylist.Top  := 40;

  FPlayerWin := HookSnapWindow(FPlayer, FSnap, True);
  FEqWin := HookSnapWindow(FEq, FSnap, False);
  FLyricWin := HookSnapWindow(FLyric, FSnap, False);
  FPlaylistWin := HookSnapWindow(FPlaylist, FSnap, False);

  FPlayer.Show;
  FEq.Show;
  FLyric.Show;
  FPlaylist.Show;
  FSnap.RebuildSnapGraph;

  Application.Run;
end;

var
  TheApp: TTPlayerApp;
begin
  RequireDerivedFormResource := False;  // 纯代码窗口，无 .lfm 资源
  Application.Scaled := False;
  Application.Initialize;
  TheApp := TTPlayerApp.Create;
  try
    TheApp.Run;
  finally
    TheApp.Free;
  end;
end.
