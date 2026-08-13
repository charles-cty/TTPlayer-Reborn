program skinpreview;

{$mode objfpc}{$H+}

// 皮肤预览工具：加载 Skin/ 目录下的皮肤，用 TPlayerForm 实时显示。
// 作为 PlayerForm 的开发脚手架，兼作目视验收工具。

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,  // 拉入平台 widgetset（Win32/GTK 等），必须放在 Forms 之前
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs,
  LazFileUtils, LazUTF8,
  USkinTypes, USkinLoader, UPlayerForm, UPlayerBackend;

type
  TPreviewMainForm = class(TForm)
  private
    FCombo: TComboBox;
    FLabel: TLabel;
    FPlayerForm: TPlayerForm;
    FEngine: TSkinEngine;
    FBackend: TStubBackend;
    FRepoRoot: string;

    procedure BuildUI;
    procedure PopulateSkins;
    procedure OnSkinSelected(Sender: TObject);
    procedure LoadSkin(const SknPath: string);
    procedure HandleClose(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

constructor TPreviewMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);   // CreateNew：无 .lfm 资源，纯代码构建

  FBackend := TStubBackend.Create;
  FEngine  := TSkinEngine.Create;

  // 仓库根目录 = 本工具所在目录的上两级（pascal/bin/ -> pascal/ -> repo root）
  FRepoRoot := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..');
  FRepoRoot := AppendPathDelim(FRepoRoot);

  BuildUI;
  PopulateSkins;

  OnClose := @HandleClose;
end;

destructor TPreviewMainForm.Destroy;
begin
  FPlayerForm.Free;
  FEngine.Free;
  FBackend.Free;
  inherited Destroy;
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

  // 首次加载时创建 PlayerForm，此后复用
  if FPlayerForm = nil then
  begin
    FPlayerForm := TPlayerForm.Create(Self, FBackend);
    FPlayerForm.Show;
  end;

  FPlayerForm.ApplySkin(FEngine.SkinData);
  Caption := 'Skin Preview — ' + FEngine.SkinData.Name;
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
