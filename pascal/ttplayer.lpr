program ttplayer;

{$mode objfpc}{$H+}

// 主播放器入口（阶段占位）。
// 本阶段不接入真实音频：用 TStubBackend 驱动三个窗口，
// 自动加载 Skin/ 目录中第一个 .skn 皮肤并展示 PlayerForm/
// EqualizerForm/LyricForm。Step 7 接入 ttcore FFI 时再替换桩。

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Interfaces,
  Classes, SysUtils, Forms,
  LazFileUtils,
  USkinTypes, USkinLoader,
  UPlayerForm, UEqualizerForm, ULyricForm, UPlayerBackend;

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
  // 应用对象：持有皮肤引擎、后端桩和三个子窗口的生命周期。
  TTPlayerApp = class
  private
    FEngine:  TSkinEngine;
    FBackend: TStubBackend;
    FPlayer:  TPlayerForm;
    FEq:      TEqualizerForm;
    FLyric:   TLyricForm;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Run;
  end;

constructor TTPlayerApp.Create;
begin
  FBackend := TStubBackend.Create;
  FEngine  := TSkinEngine.Create;
  FPlayer  := TPlayerForm.Create(Application, FBackend);
  FEq      := TEqualizerForm.Create(Application, FBackend);
  FLyric   := TLyricForm.Create(Application, FBackend);
end;

destructor TTPlayerApp.Destroy;
begin
  FPlayer.Free;
  FEq.Free;
  FLyric.Free;
  FEngine.Free;
  FBackend.Free;
  inherited Destroy;
end;

procedure TTPlayerApp.Run;
var
  sknPath: string;
begin
  sknPath := FindFirstSkin;
  if (sknPath <> '') and FEngine.LoadFromFile(sknPath) then
  begin
    FPlayer.ApplySkin(FEngine.SkinData);
    FEq.ApplySkin(FEngine.SkinData);
    FLyric.ApplySkin(FEngine.SkinData);
  end;

  FPlayer.Show;
  FEq.Show;
  FLyric.Show;

  Application.Run;
end;

var
  TheApp: TTPlayerApp;
begin
  RequireDerivedFormResource := False;  // 纯代码窗口，无 .lfm 资源
  Application.Initialize;
  TheApp := TTPlayerApp.Create;
  try
    TheApp.Run;
  finally
    TheApp.Free;
  end;
end.
