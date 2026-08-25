program ttdump;

{$mode objfpc}{$H+}

// 皮肤解析结果导出工具（Pascal 侧，Layer 1 差分测试的被测端）。
// 用法：ttdump <skn文件|皮肤目录> <输出.json>
// 输出格式与 Qt 版 TTPlayerReborn.exe --dump-skin 完全对应。

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  UHeapTraceConfig,
  Classes, SysUtils, USkinTypes, USkinLoader, USkinJsonDump;

var
  skinPath, outPath, json: string;
  engine: TSkinEngine;
  ok: Boolean;
  fs: TFileStream;
begin
  if ParamCount < 2 then
  begin
    WriteLn(ErrOutput, 'usage: ttdump <skn|dir> <out.json>');
    ExitCode := 1;
    Exit;
  end;

  skinPath := ParamStr(1);
  outPath := ParamStr(2);

  if not (FileExists(skinPath) or DirectoryExists(skinPath)) then
  begin
    WriteLn(ErrOutput, 'ttdump: skin path does not exist: ', skinPath);
    ExitCode := 2;
    Exit;
  end;

  engine := TSkinEngine.Create;
  try
    if DirectoryExists(skinPath) then
      ok := engine.LoadFromDirectory(skinPath)
    else
      ok := engine.LoadFromFile(skinPath);
    if not ok then
    begin
      WriteLn(ErrOutput, 'ttdump: failed to load skin: ', skinPath);
      ExitCode := 3;
      Exit;
    end;

    json := DumpSkinToJson(engine.SkinData);
    fs := TFileStream.Create(outPath, fmCreate);
    try
      if json <> '' then
        fs.WriteBuffer(json[1], Length(json));
    finally
      fs.Free;
    end;
  finally
    engine.Free;
  end;
end.
