program skinpreview;

{$mode objfpc}{$H+}

// 皮肤预览工具：加载 Skin/ 目录下的皮肤，用 TPlayerForm / TEqualizerForm /
// TLyricForm / TPlaylistForm 实时显示四个子窗口（Layer 5 冒烟按标题识别）。

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  UHeapTraceConfig,
  UGdkX11Backend,
  UWinDpiAware,
  Interfaces,
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, Types,
  LazFileUtils, LazUTF8, LCLIntf,
  USkinTypes, USkinLoader, UPlayerForm, UEqualizerForm, ULyricForm,
  UVisualWidget, UPlaylistForm, UPlayerBackend,
  UWindowSnapManager, UFormSnap, UWindowSnapMath, UPlatformWindow, USkinView,
  UPlayerMenuSpec;

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
    FSkinDir: string;
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
    procedure HandlePlayFile(Sender: TObject; const FilePath: string);
    procedure HandlePrev(Sender: TObject);
    procedure HandleNext(Sender: TObject);
    procedure HandleOpen(Sender: TObject);
    procedure HandlePlay(Sender: TObject);
    procedure HandleTrackFinished(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure RunProbe(const OutPath: string);
  end;

constructor TPreviewMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);   // CreateNew：无 .lfm 资源，纯代码构建

  FBackend := TStubBackend.Create;
  FEngine  := TSkinEngine.Create;
  FSnap    := TWindowSnapManager.Create;

  FSkinDir := IncludeTrailingPathDelimiter(FindSkinDirectory);

  BuildUI;
  PopulateSkins;

  OnClose := @HandleClose;
end;

destructor TPreviewMainForm.Destroy;
begin
  if FBackend <> nil then
    FBackend.SetOnTrackFinished(nil);
  // 先从吸附图拿掉 ISnapWindow，避免子 Form BeforeDestruction.Hide
  // 重建图时读到已释放的 TForm。
  if FSnap <> nil then
    FSnap.ClearWindows;
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
  names: TStringList;
begin
  skinDir := FSkinDir;
  FCombo.OnChange := nil;
  FCombo.Items.Clear;

  names := TStringList.Create;
  try
    names.Sorted := True;
    names.Duplicates := dupIgnore;
    if FindFirst(skinDir + '*.skn', faAnyFile, sr) = 0 then
    begin
      try
        repeat
          names.Add(ChangeFileExt(sr.Name, ''));
        until FindNext(sr) <> 0;
      finally
        FindClose(sr);
      end;
    end;
    FCombo.Items.Assign(names);
  finally
    names.Free;
  end;

  FCombo.OnChange := @OnSkinSelected;
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
  sknPath := FSkinDir + FCombo.Items[FCombo.ItemIndex] + '.skn';
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
  // 先 ApplySkin 再 Show，避免首帧空白 / 默认尺寸被 Region 锁住。
  if FPlayerForm = nil then
  begin
    FPlayerForm := TPlayerForm.Create(Self, FBackend);
    FPlayerForm.OnAuxToggle := @HandleAuxToggle;
    FPlayerForm.OnPrev := @HandlePrev;
    FPlayerForm.OnNext := @HandleNext;
    FPlayerForm.OnOpen := @HandleOpen;
    FPlayerForm.OnPlay := @HandlePlay;
    FBackend.SetOnTrackFinished(@HandleTrackFinished);
    FPlayerForm.Left := 20;
    FPlayerForm.Top  := 160;
  end;

  if FEqForm = nil then
  begin
    FEqForm := TEqualizerForm.Create(Self, FBackend);
    FEqForm.Left := 310;
    FEqForm.Top  := 160;
  end;

  if FLyricForm = nil then
  begin
    FLyricForm := TLyricForm.Create(Self, FBackend);
    FLyricForm.Left := 20;
    FLyricForm.Top  := 360;
  end;

  if FPlaylistForm = nil then
  begin
    FPlaylistForm := TPlaylistForm.Create(Self, FBackend);
    FPlaylistForm.OnPlayFile := @HandlePlayFile;
    FPlaylistForm.Left := 310;
    FPlaylistForm.Top  := 350;
    SeedDemoPlaylist;
  end;

  FPlayerForm.ApplySkin(FEngine.SkinPtr);
  FEqForm.ApplySkin(FEngine.SkinPtr);
  FLyricForm.ApplySkin(FEngine.SkinPtr);
  FPlaylistForm.ApplySkin(FEngine.SkinPtr);
  FPlayerForm.SetAuxToggle('lyric', True);
  FPlayerForm.SetAuxToggle('equalizer', True);
  FPlayerForm.SetAuxToggle('playlist', True);
  PrepareAuxOwnedWindow(FEqForm, FPlayerForm);
  PrepareAuxOwnedWindow(FLyricForm, FPlayerForm);
  PrepareAuxOwnedWindow(FPlaylistForm, FPlayerForm);
  EnsureSnapHooked;
  Caption := 'Skin Preview — ' + FEngine.SkinData.Name;

  if not FPlayerForm.Visible then FPlayerForm.Show;
  if not FEqForm.Visible then FEqForm.Show;
  if not FLyricForm.Visible then FLyricForm.Show;
  if not FPlaylistForm.Visible then FPlaylistForm.Show;
  Application.ProcessMessages;
end;

procedure TPreviewMainForm.EnsureSnapHooked;
begin
  if FPlayerWin <> nil then
  begin
    FSnap.RebuildSnapGraph;
    Exit;
  end;
  if (FPlayerForm = nil) or (FSnap = nil) then
    Exit;
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

procedure TPreviewMainForm.HandlePlayFile(Sender: TObject; const FilePath: string);
var
  lrc: string;
begin
  if Sender = nil then ;
  if FLyricForm = nil then Exit;
  lrc := ChangeFileExt(FilePath, '.lrc');
  if FileExists(lrc) then
    FLyricForm.LoadLrc(lrc)
  else
    FLyricForm.ClearLrc;
  if FBackend <> nil then
    FLyricForm.SetTrackInfo(FBackend.GetTitle, FBackend.GetArtist);
end;

procedure TPreviewMainForm.HandlePrev(Sender: TObject);
begin
  if Sender = nil then ;
  if FPlaylistForm <> nil then
    FPlaylistForm.PlayPrev;
end;

procedure TPreviewMainForm.HandleNext(Sender: TObject);
begin
  if Sender = nil then ;
  if FPlaylistForm <> nil then
    FPlaylistForm.PlayNext;
end;

procedure TPreviewMainForm.HandleOpen(Sender: TObject);
begin
  if Sender = nil then ;
  if FPlaylistForm <> nil then
    FPlaylistForm.OpenFilesAndPlay;
end;

procedure TPreviewMainForm.HandlePlay(Sender: TObject);
begin
  if Sender = nil then ;
  if FBackend = nil then Exit;
  case FBackend.GetState of
    psPaused, psStopped:
      FBackend.Play;
  else
    if FPlaylistForm <> nil then
    begin
      FPlaylistForm.PlayCurrent;
      if FBackend.GetState = psIdle then
        FPlaylistForm.OpenFilesAndPlay;
    end
    else
      FBackend.Play;
  end;
end;

procedure TPreviewMainForm.HandleTrackFinished(Sender: TObject);
begin
  if Sender = nil then ;
  if FPlaylistForm <> nil then
    FPlaylistForm.PlayNext;
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

function JsonEscape(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
end;

function JsonBool(B: Boolean): string;
begin
  if B then Result := 'true' else Result := 'false';
end;

function JsonNumber(D: Double): string;
var
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  Result := FormatFloat('0.###', D, fs);
end;

function WidgetSetName: string;
begin
  Result := 'unknown';
  {$IFDEF LCLGTK3} Result := 'gtk3'; {$ENDIF}
  {$IFDEF LCLGTK2} Result := 'gtk2'; {$ENDIF}
  {$IFDEF LCLQT5} Result := 'qt5'; {$ENDIF}
  {$IFDEF LCLQT6} Result := 'qt6'; {$ENDIF}
  {$IFDEF LCLWIN32} Result := 'win32'; {$ENDIF}
end;

function FormBoundsJson(AForm: TForm): string;
var
  wr: TRect;
  nl, nt, nw, nh, gdkScale, xw, xh: Integer;
  decorated, hasTitle, above: Boolean;
  scale, viewScale: Double;
begin
  if AForm = nil then
    Exit('{"present":false}');
  nl := 0;
  nt := 0;
  nw := 0;
  nh := 0;
  xw := 0;
  xh := 0;
  decorated := False;
  hasTitle := False;
  above := False;
  scale := 1.0;
  viewScale := FormViewScale(AForm);
  gdkScale := 1;
  if AForm.HandleAllocated then
  begin
    wr := Types.Rect(0, 0, 0, 0);
    if PlatformGetWindowRect(AForm.Handle, wr) then
    begin
      nl := wr.Left;
      nt := wr.Top;
      nw := wr.Right - wr.Left;
      nh := wr.Bottom - wr.Top;
    end;
    if not PlatformXWindowSize(AForm.Handle, xw, xh) then
    begin
      xw := nw;
      xh := nh;
    end;
    decorated := PlatformWindowIsDecorated(AForm.Handle);
    hasTitle := PlatformWindowHasTitlebar(AForm.Handle);
    above := PlatformWindowIsAbove(AForm.Handle);
    scale := PlatformWindowScale(AForm.Handle, AForm.Width, AForm.Height);
    gdkScale := PlatformGdkScaleFactor(AForm.Handle);
  end;
  Result := Format(
    '{"present":true,"visible":%s,"caption":"%s",' +
    '"lcl_left":%d,"lcl_top":%d,"lcl_width":%d,"lcl_height":%d,' +
    '"native_left":%d,"native_top":%d,"native_width":%d,"native_height":%d,' +
    '"x11_width":%d,"x11_height":%d,' +
    '"scale":%s,"view_scale":%s,"gdk_scale_factor":%d,' +
    '"decorated":%s,"has_titlebar":%s,"ewmh_above":%s}',
    [JsonBool(AForm.Visible), JsonEscape(AForm.Caption),
     AForm.Left, AForm.Top, AForm.Width, AForm.Height,
     nl, nt, nw, nh, xw, xh,
     JsonNumber(scale), JsonNumber(viewScale), gdkScale,
     JsonBool(decorated), JsonBool(hasTitle), JsonBool(above)]);
end;

function HasSwitch(const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 1 to ParamCount do
    if SameText(ParamStr(i), S) then
      Exit(True);
end;

function SwitchValue(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to ParamCount - 1 do
    if SameText(ParamStr(i), S) then
      Exit(ParamStr(i + 1));
end;

procedure TPreviewMainForm.RunProbe(const OutPath: string);
var
  pr, er: TSnapRect;
  gapBefore, gapAfter, i, gdkScale, ppi: Integer;
  sl: TStringList;
  skinName, json: string;
  snapped: Boolean;
  uiScale, viewScale: Double;
begin
  for i := 1 to 30 do
  begin
    Application.ProcessMessages;
    Sleep(20);
  end;
  EnsureSnapHooked;
  if FPlayerForm <> nil then
  begin
    SetWindowAlwaysOnTop(FPlayerForm, True);
    Application.ProcessMessages;
    Sleep(50);
  end;

  skinName := '';
  if FCombo.ItemIndex >= 0 then
    skinName := FCombo.Items[FCombo.ItemIndex];

  gapBefore := 0;
  gapAfter := 0;
  snapped := False;
  if (FPlayerWin <> nil) and (FEqWin <> nil) then
  begin
    pr := FPlayerWin.GetBounds;
    FSnap.OnDragStarted(FEqWin);
    FEqWin.MoveTo(pr.X + pr.W + 5, pr.Y);
    Application.ProcessMessages;
    er := FEqWin.GetBounds;
    gapBefore := er.X - (pr.X + pr.W);
    FSnap.OnDragFinished(FEqWin);
    Application.ProcessMessages;
    pr := FPlayerWin.GetBounds;
    er := FEqWin.GetBounds;
    gapAfter := er.X - (pr.X + pr.W);
    snapped := FSnap.IsSnapped(FEqWin);
  end;

  uiScale := 1.0;
  viewScale := 1.0;
  gdkScale := 1;
  ppi := Screen.PixelsPerInch;
  if ppi <= 0 then
    ppi := PlatformPixelsPerInch;
  if FPlayerForm <> nil then
  begin
    if FPlayerForm.HandleAllocated then
    begin
      uiScale := PlatformWindowScale(FPlayerForm.Handle,
        FPlayerForm.Width, FPlayerForm.Height);
      gdkScale := PlatformGdkScaleFactor(FPlayerForm.Handle);
    end;
    viewScale := FormViewScale(FPlayerForm);
    ppi := FormDpi(FPlayerForm);
  end;

  sl := TStringList.Create;
  try
    sl.Add('{');
    sl.Add('  "ok": true,');
    sl.Add('  "widgetset": "' + JsonEscape(WidgetSetName) + '",');
    sl.Add('  "backend": "' + JsonEscape(PlatformBackendName) + '",');
    sl.Add('  "gdk_display": "' + JsonEscape(PlatformGdkDisplayName) + '",');
    sl.Add('  "wayland_display": "' +
      JsonEscape(GetEnvironmentVariable('WAYLAND_DISPLAY')) + '",');
    sl.Add('  "x11_display": "' +
      JsonEscape(GetEnvironmentVariable('DISPLAY')) + '",');
    sl.Add('  "shape_supported": ' + JsonBool(PlatformShapeSupported) + ',');
    sl.Add('  "always_on_top_native": ' +
      JsonBool(PlatformAlwaysOnTopNative) + ',');
    sl.Add('  "dpi": {');
    sl.Add('    "scale": ' + JsonNumber(uiScale) + ',');
    sl.Add('    "view_scale": ' + JsonNumber(viewScale) + ',');
    sl.Add('    "gdk_scale_factor": ' + IntToStr(gdkScale) + ',');
    sl.Add('    "pixels_per_inch": ' + IntToStr(ppi));
    sl.Add('  },');
    sl.Add('  "skin": "' + JsonEscape(skinName) + '",');
    sl.Add('  "windows": {');
    sl.Add('    "player": ' + FormBoundsJson(FPlayerForm) + ',');
    sl.Add('    "equalizer": ' + FormBoundsJson(FEqForm) + ',');
    sl.Add('    "lyric": ' + FormBoundsJson(FLyricForm) + ',');
    sl.Add('    "playlist": ' + FormBoundsJson(FPlaylistForm));
    sl.Add('  },');
    sl.Add('  "snap": {');
    sl.Add('    "threshold": ' + IntToStr(FSnap.SnapThreshold) + ',');
    sl.Add('    "gap_before": ' + IntToStr(gapBefore) + ',');
    sl.Add('    "gap_after": ' + IntToStr(gapAfter) + ',');
    sl.Add('    "snapped": ' + JsonBool(snapped));
    sl.Add('  },');
    sl.Add('  "policy": "xwayland-only",');
    sl.Add('  "notes": [');
    sl.Add('    "Linux target is X11/XWayland only (GDK_BACKEND=x11, GTK_CSD=0)",');
    sl.Add('    "native Wayland is out of scope",');
    sl.Add('    "GTK3 caption drag is LCL capture + OnDragStarted/Finished",');
    sl.Add('    "snap here is programmatic OnDragFinished (same manager as mouse drag)",');
    sl.Add('    "DPI: snap in logical pixels; Shape scaled when native size is a uniform UI scale",');
    sl.Add('    "view_scale sizes LCL to skin*dpi/96 on Windows; GTK GDK_SCALE>=2 keeps LCL at 1x"');
    sl.Add('  ]');
    sl.Add('}');
    json := sl.Text;
    if OutPath <> '' then
      sl.SaveToFile(OutPath);
  finally
    sl.Free;
  end;
  // -WG GUI 子系统下 Output 未打开，WriteLn 会 EInOutError「File not open」。
  if TextRec(Output).Mode <> fmClosed then
  begin
    WriteLn(json);
    Flush(Output);
  end;
end;

var
  MainForm: TPreviewMainForm;
  ProbeOut: string;
begin
  RequireDerivedFormResource := False;  // 纯代码窗口，无 .lfm 资源
  Application.Scaled := False;
  Application.Initialize;
  Application.CreateForm(TPreviewMainForm, MainForm);
  if HasSwitch('--probe') then
  begin
    ProbeOut := SwitchValue('--probe-out');
    MainForm.RunProbe(ProbeOut);
    Exit;
  end;
  Application.Run;
end.
