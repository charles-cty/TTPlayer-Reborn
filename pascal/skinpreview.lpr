program skinpreview;

{$mode objfpc}{$H+}

// 皮肤预览工具：加载 Skin/ 目录下的皮肤，用 TPlayerForm / TEqualizerForm /
// TLyricForm / TPlaylistForm 实时显示四个子窗口（Layer 5 冒烟按标题识别）。

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs,
  LazFileUtils, LazUTF8,
  USkinTypes, USkinLoader, UPlayerForm, UEqualizerForm, ULyricForm,
  UVisualWidget, UPlaylistForm, UPlayerBackend,
  UWindowSnapManager, UFormSnap;

type
  TPreviewMainForm = class(TForm)
  private
    FCombo: TComboBox;
    FLabel: TLabel;
    FPlayerForm: TPlayerForm;
    FEqForm: TEqualizerForm;
    FLyricForm: TLyricForm;
    FPlaylistForm: TPlaylistForm;
    FEngine: TSkinEngine;
    FBackend: TStubBackend;
    FRepoRoot: string;
    FSnap: TWindowSnapManager;
    FPlayerWin, FEqWin, FLyricWin, FPlaylistWin: ISnapWindow;

    procedure BuildUI;
    procedure PopulateSkins;
    procedure OnSkinSelected(Sender: TObject);
    procedure LoadSkin(const SknPath: string);
    procedure HandleClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure HandleAuxToggle(Sender: TObject; const AType: string;
      AToggled: Boolean);
    procedure HandleLyricResize(Sender: TObject);
    procedure HandleLyricResizeFinished(Sender: TObject);
    procedure HandlePlaylistResize(Sender: TObject);
    procedure HandlePlaylistResizeFinished(Sender: TObject);
    procedure SeedDemoPlaylist;
    procedure EnsureSnapHooked;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

constructor TPreviewMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);   // CreateNew：无 .lfm 资源，纯代码构建

  FBackend := TStubBackend.Create;
  FEngine  := TSkinEngine.Create;
  FSnap    := TWindowSnapManager.Create;

  // 仓库根目录 = 本工具所在目录的上两级（pascal/bin/ -> pascal/ -> repo root）
  FRepoRoot := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..');
  FRepoRoot := AppendPathDelim(FRepoRoot);

  BuildUI;
  PopulateSkins;

  OnClose := @HandleClose;
end;

destructor TPreviewMainForm.Destroy;
begin
  // 子 Form 均以 Self 为 Owner 创建，LCL 在本对象销毁时自动释放，无需手动 Free。
  FPlayerWin := nil;
  FEqWin := nil;
  FLyricWin := nil;
  FPlaylistWin := nil;
  FEngine.Free;
  FBackend := nil;  // TInterfacedObject，引用计数归零自动释放，不能手动 Free
  inherited Destroy;  // 子 Form / Adapter 先拆掉，Hide 时 FSnap 仍有效
  FSnap.Free;
end;

procedure TPreviewMainForm.BuildUI;
begin
  Caption := 'Skin Preview';
  Width   := 340;
  Height  := 120;
  Position := poScreenCenter;
  BorderStyle := bsSingle;

  FLabel := TLabel.Create(Self);
  FLabel.Parent := Self;
  FLabel.Left   := 12;
  FLabel.Top    := 14;
  FLabel.Caption := '皮肤：';

  FCombo := TComboBox.Create(Self);
  FCombo.Parent := Self;
  FCombo.Left   := 60;
  FCombo.Top    := 10;
  FCombo.Width  := 250;
  FCombo.Style  := csDropDownList;
  FCombo.OnChange := @OnSkinSelected;
end;

procedure TPreviewMainForm.PopulateSkins;
var
  skinDir: string;
  sr: TSearchRec;
begin
  skinDir := FRepoRoot + 'Skin' + PathDelim;
  FCombo.Items.Clear;

  if FindFirst(skinDir + '*.skn', faAnyFile, sr) = 0 then
  begin
    try
      repeat
    FCombo.Items.Add(ChangeFileExt(sr.Name, ''));
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;

  if FCombo.Items.Count > 0 then
  begin
    FCombo.ItemIndex := 0;
    OnSkinSelected(FCombo);
  end;
end;

procedure TPreviewMainForm.OnSkinSelected(Sender: TObject);
var
  sknPath: string;
begin
  if FCombo.ItemIndex < 0 then Exit;
  sknPath := FRepoRoot + 'Skin' + PathDelim +
             FCombo.Items[FCombo.ItemIndex] + '.skn';
  LoadSkin(sknPath);
end;

procedure TPreviewMainForm.LoadSkin(const SknPath: string);
begin
  if not FileExists(SknPath) then
  begin
    ShowMessage('找不到皮肤文件：' + SknPath);
    Exit;
  end;

  if not FEngine.LoadFromFile(SknPath) then
  begin
    ShowMessage('皮肤加载失败：' + SknPath);
    Exit;
  end;

  // 首次加载时创建各子窗口，错开初始位置避免堆叠。
  // 预览工具显示全部四个窗口，便于 Layer 5 冒烟核对。
  if FPlayerForm = nil then
  begin
    FPlayerForm := TPlayerForm.Create(Self, FBackend);
    FPlayerForm.OnAuxToggle := @HandleAuxToggle;
    FPlayerForm.Left := 20;
    FPlayerForm.Top  := 160;
    FPlayerForm.Show;
  end;

  if FEqForm = nil then
  begin
    FEqForm := TEqualizerForm.Create(Self, FBackend);
    FEqForm.Left := 310;
    FEqForm.Top  := 160;
    FEqForm.Show;
  end;

  if FLyricForm = nil then
  begin
    FLyricForm := TLyricForm.Create(Self, FBackend);
    FLyricForm.Left := 20;
    FLyricForm.Top  := 360;
    FLyricForm.Show;
  end;

  if FPlaylistForm = nil then
  begin
    FPlaylistForm := TPlaylistForm.Create(Self, FBackend);
    FPlaylistForm.Left := 310;
    FPlaylistForm.Top  := 350;
    SeedDemoPlaylist;
    FPlaylistForm.Show;
  end;

  FPlayerForm.ApplySkin(FEngine.SkinData);
  FEqForm.ApplySkin(FEngine.SkinData);
  FLyricForm.ApplySkin(FEngine.SkinData);
  FPlaylistForm.ApplySkin(FEngine.SkinData);
  FPlayerForm.SetAuxToggle('lyric', True);
  FPlayerForm.SetAuxToggle('equalizer', True);
  FPlayerForm.SetAuxToggle('playlist', True);
  EnsureSnapHooked;
  Caption := 'Skin Preview — ' + FEngine.SkinData.Name;
end;

procedure TPreviewMainForm.EnsureSnapHooked;
begin
  if FPlayerWin <> nil then
  begin
    FSnap.RebuildSnapGraph;
    Exit;
  end;
  FPlayerWin := HookSnapWindow(FPlayerForm, FSnap, True);
  FEqWin := HookSnapWindow(FEqForm, FSnap, False);
  FLyricWin := HookSnapWindow(FLyricForm, FSnap, False);
  FPlaylistWin := HookSnapWindow(FPlaylistForm, FSnap, False);
  FLyricForm.OnResizeInProgress := @HandleLyricResize;
  FLyricForm.OnResizeFinished := @HandleLyricResizeFinished;
  FPlaylistForm.OnResizeInProgress := @HandlePlaylistResize;
  FPlaylistForm.OnResizeFinished := @HandlePlaylistResizeFinished;
  FSnap.RebuildSnapGraph;
end;

procedure TPreviewMainForm.HandleLyricResize(Sender: TObject);
begin
  if FLyricWin = nil then Exit;
  FSnap.OnSubResized(FLyricWin,
    ResizeEdgesOf(FLyricForm.ResizeEdgeRight, FLyricForm.ResizeEdgeBottom));
end;

procedure TPreviewMainForm.HandleLyricResizeFinished(Sender: TObject);
begin
  if FLyricWin = nil then Exit;
  FSnap.OnSubResizeFinished(FLyricWin,
    ResizeEdgesOf(FLyricForm.ResizeEdgeRight, FLyricForm.ResizeEdgeBottom));
end;

procedure TPreviewMainForm.HandlePlaylistResize(Sender: TObject);
begin
  if FPlaylistWin = nil then Exit;
  FSnap.OnSubResized(FPlaylistWin,
    ResizeEdgesOf(FPlaylistForm.ResizeEdgeRight, FPlaylistForm.ResizeEdgeBottom));
end;

procedure TPreviewMainForm.HandlePlaylistResizeFinished(Sender: TObject);
begin
  if FPlaylistWin = nil then Exit;
  FSnap.OnSubResizeFinished(FPlaylistWin,
    ResizeEdgesOf(FPlaylistForm.ResizeEdgeRight, FPlaylistForm.ResizeEdgeBottom));
end;

procedure TPreviewMainForm.HandleAuxToggle(Sender: TObject; const AType: string;
  AToggled: Boolean);
begin
  if SameText(AType, 'lyric') and (FLyricForm <> nil) then
  begin
    if AToggled then FLyricForm.Show else FLyricForm.Hide;
  end
  else if SameText(AType, 'equalizer') and (FEqForm <> nil) then
  begin
    if AToggled then FEqForm.Show else FEqForm.Hide;
  end
  else if SameText(AType, 'playlist') and (FPlaylistForm <> nil) then
  begin
    if AToggled then FPlaylistForm.Show else FPlaylistForm.Hide;
  end;
end;

procedure TPreviewMainForm.SeedDemoPlaylist;
begin
  if FPlaylistForm = nil then Exit;
  FPlaylistForm.Clear;
  FPlaylistForm.AddEntry('demo/晴天.mp3', '晴天', '周杰伦', 269000);
  FPlaylistForm.AddEntry('demo/七里香.mp3', '七里香', '周杰伦', 299000);
  FPlaylistForm.AddEntry('demo/夜曲.mp3', '夜曲', '周杰伦', 226000);
  FPlaylistForm.AddEntry('demo/稻香.mp3', '稻香', '周杰伦', 223000);
  FPlaylistForm.AddEntry('demo/告白气球.mp3', '告白气球', '周杰伦', 215000);
  FPlaylistForm.AddEntry('demo/简单爱.mp3', '简单爱', '周杰伦', 270000);
  FPlaylistForm.AddEntry('demo/东风破.mp3', '东风破', '周杰伦', 315000);
  FPlaylistForm.AddEntry('demo/青花瓷.mp3', '青花瓷', '周杰伦', 239000);
  FPlaylistForm.AddEntry('demo/听妈妈的话.mp3', '听妈妈的话', '周杰伦', 263000);
  FPlaylistForm.AddEntry('demo/搁浅.mp3', '搁浅', '周杰伦', 240000);
  FPlaylistForm.AddEntry('demo/轨迹.mp3', '轨迹', '周杰伦', 332000);
  FPlaylistForm.AddEntry('demo/发如雪.mp3', '发如雪', '周杰伦', 299000);
  FPlaylistForm.AddEntry('demo/彩虹.mp3', '彩虹', '周杰伦', 263000);
  FPlaylistForm.AddEntry('demo/菊花台.mp3', '菊花台', '周杰伦', 293000);
  FPlaylistForm.AddEntry('demo/不能说的秘密.mp3', '不能说的秘密', '周杰伦', 296000);
  FPlaylistForm.AddEntry('demo/开不了口.mp3', '开不了口', '周杰伦', 284000);
  FPlaylistForm.AddEntry('demo/龙卷风.mp3', '龙卷风', '周杰伦', 249000);
  FPlaylistForm.AddEntry('demo/安静.mp3', '安静', '周杰伦', 331000);
  FPlaylistForm.AddEntry('demo/一路向北.mp3', '一路向北', '周杰伦', 290000);
  FPlaylistForm.AddEntry('demo/夜的第七章.mp3', '夜的第七章', '周杰伦', 228000);
  FPlaylistForm.SetCurrentIndex(0);
end;

procedure TPreviewMainForm.HandleClose(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  Application.Terminate;
end;

var
  MainForm: TPreviewMainForm;
begin
  RequireDerivedFormResource := False;  // 纯代码窗口，无 .lfm 资源
  Application.Initialize;
  Application.CreateForm(TPreviewMainForm, MainForm);
  Application.Run;
end.
