unit ULyricForm;

{$mode objfpc}{$H+}

// 歌词窗口，对应 Qt 版 src/ui/LyricWindow。
// 无边框自绘，九宫格背景，右/下边缘可调整大小。
// close/ontop 按钮以原始 position 坐标绘制，align 修正通过 AlignedButtonX 计算。
// WMNCHitTest 返回 HTCAPTION 实现拖动；边缘拖动在 MouseDown/Move/Up 中处理。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, ExtCtrls, Menus,
  LCLIntf, LCLType, LMessages,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UPlayerBackend, ULrcParser, UPlatformWindow,
  USkinView, UPlayerMenuSpec, ULiveResizeSession, USkinErase,
  UAlphaShape;

type
  TLyricForm = class(TForm, ISkinViewForm)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;

    // 应用皮肤；换肤时调用。
    procedure ApplySkin(ASkin: PSkinData);
    procedure RefreshViewScale;
    procedure RebuildWindowShape;
    procedure SetBounds(ALeft, ATop, AWidth, AHeight: Integer); override;
    procedure LoadLrc(const APath: string);
    procedure ClearLrc;
    procedure SetTrackInfo(const ATitle, AArtist: string);
    procedure ReparseCurrentLyric;
    procedure SetLyricEncoding(Enc: TLrcEncoding);
    procedure AdjustLyricOffset(DeltaMs: Integer);
    procedure ResetLyricOffset;
    function LyricOffsetMs: Integer;
    function LyricEncoding: TLrcEncoding;

  protected
    procedure Paint; override;
    procedure WMEraseBkgnd(var Message: TLMEraseBkgnd); message LM_ERASEBKGND;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure CreateWnd; override;
    procedure DoShow; override;
    procedure DoContextPopup(MousePos: TPoint; var Handled: Boolean); override;

    procedure WMNCHitTest(var Msg: TLMessage); message LM_NCHITTEST;

  private
    FSkin: PSkinData;
    FBackend: IPlayerBackend;
    FFrame: TBGRABitmap;
    FNineScratch: TBGRABitmap;

    // 当前窗口逻辑尺寸（用于九宫格和命中测试）
    FLogicW, FLogicH: Integer;

    // 交互状态
    FHoveredType: string;
    FPressedType: string;
    FAlwaysOnTop: Boolean;

    // 边缘拖动调整大小
    FResizing: Boolean;
    FResizeEdgeRight: Boolean;   // 拖动右边缘
    FResizeEdgeBottom: Boolean;  // 拖动下边缘
    FResizeStartX: Integer;      // 拖动起始屏幕 X
    FResizeStartY: Integer;
    FResizeStartW: Integer;
    FResizeStartH: Integer;
    FResizeSession: TLiveResizeSession;
    FResizeTraceActive: Boolean;
    FResizeCoalesce: TTimer;
    FDeferLiveChrome: Boolean;
    FLivePaintLocked: Boolean;
    FLastPaintChromeUs: Int64;
    FShapeRects: TShapeRectArray;
    FShapeW, FShapeH: Integer;
    FLastRgnW, FLastRgnH: Integer;

    FOnResizeInProgress: TNotifyEvent;
    FOnResizeFinished: TNotifyEvent;

    FLrc: TLrcData;
    FTrackTitle: string;
    FTrackArtist: string;
    FTimer: TTimer;
    FRaw: TBytes;
    FLrcPath: string;
    FEncoding: TLrcEncoding;
    FOffsetMs: Integer;
    FLyricMenu: TPopupMenu;
    FOnCloseRequested: TNotifyEvent;
    FSkipContextPopup: Boolean;

    procedure BuildRegion;
    procedure RenderFrame;
    procedure MapHit(var X, Y: Integer);
    procedure ApplyResizeDecision(const D: TLiveResizeDecision);
    procedure ExecuteResizeDecision(const D: TLiveResizeDecision);
    procedure HandleResizeCoalesce(Sender: TObject);

    procedure OnLyricTick(Sender: TObject);
    function LyricArea: TSkinRect;
    procedure DrawLyrics;

    // 命中测试：返回按钮名或 ''
    function HitButton(PX, PY: Integer): string;
    // 是否命中右/下可调整边缘（8 px 感应带）
    function HitResizeEdge(PX, PY: Integer;
      out EdgeRight, EdgeBottom: Boolean): Boolean;
    // 计算 align='right' 按钮的实际 X（与 Qt alignedRect 等价，使用 baseSize）
    function AlignedButtonX(const Elem: TSkinElement): Integer;

    procedure FireButtonClick(const AName: string);
    procedure BuildLyricMenu;
    procedure HandleLyricMenuPopup(Sender: TObject);
    procedure HandleEncodingClick(Sender: TObject);
    procedure HandleOffsetAhead(Sender: TObject);
    procedure HandleOffsetBehind(Sender: TObject);
    procedure HandleOffsetReset(Sender: TObject);
    procedure HandleLyricClose(Sender: TObject);
  public
    property OnResizeInProgress: TNotifyEvent
      read FOnResizeInProgress write FOnResizeInProgress;
    property OnResizeFinished: TNotifyEvent
      read FOnResizeFinished write FOnResizeFinished;
    property OnCloseRequested: TNotifyEvent
      read FOnCloseRequested write FOnCloseRequested;
    property ResizeEdgeRight: Boolean read FResizeEdgeRight;
    property ResizeEdgeBottom: Boolean read FResizeEdgeBottom;
  end;

implementation

uses
  LCLProc, Math, UFormSnap, UDpiScale, UTracy;

const
  kResizeSense = 8;  // 调整大小感应带宽度（像素）

{ TLyricForm }

constructor TLyricForm.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  inherited CreateNew(AOwner);

  FSkin    := nil;
  FBackend := ABackend;
  FFrame   := nil;

  FLogicW  := 268;
  FLogicH  := 60;
  FAlwaysOnTop := False;
  FTrackTitle := '';
  FTrackArtist := '';

  FHoveredType := '';
  FPressedType := '';
  FResizing := False;
  FDeferLiveChrome := False;
  FResizeSession := TLiveResizeSession.Create;
  FResizeCoalesce := TTimer.Create(Self);
  FResizeCoalesce.Enabled := False;
  FResizeCoalesce.Interval := kLiveResizeCoalesceMs;
  FResizeCoalesce.OnTimer := @HandleResizeCoalesce;
  FEncoding := leAutoDetect;
  FOffsetMs := 0;
  FLrcPath := '';

  FLyricMenu := TPopupMenu.Create(Self);
  FLyricMenu.OnPopup := @HandleLyricMenuPopup;

  BorderStyle := bsNone;
  FormStyle   := fsNormal;
  Color       := clBlack;
  Caption     := 'Lyric';
  ShowInTaskBar := stNever;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 100;
  FTimer.OnTimer := @OnLyricTick;
  FTimer.Enabled := True;

  MouseLeave;
end;

destructor TLyricForm.Destroy;
begin
  FTimer.Enabled := False;
  if FResizeCoalesce <> nil then
    FResizeCoalesce.Enabled := False;
  FreeAndNil(FResizeSession);
  FreeAndNil(FNineScratch);
  FreeAndNil(FFrame);
  inherited Destroy;
end;

procedure TLyricForm.OnLyricTick(Sender: TObject);
begin
  if Sender = nil then ;
  if not Visible then Exit;
  if Length(FLrc.Lines) = 0 then Exit;
  RenderFrame;
  Invalidate;
end;

procedure TLyricForm.LoadLrc(const APath: string);
var
  fs: TFileStream;
begin
  FLrcPath := APath;
  FOffsetMs := 0;
  FEncoding := leAutoDetect;
  SetLength(FRaw, 0);
  if FileExists(APath) then
  begin
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(FRaw, fs.Size);
      if fs.Size > 0 then
        fs.ReadBuffer(FRaw[0], fs.Size);
    finally
      fs.Free;
    end;
  end;
  ReparseCurrentLyric;
end;

procedure TLyricForm.ClearLrc;
begin
  FLrcPath := '';
  SetLength(FRaw, 0);
  FOffsetMs := 0;
  FEncoding := leAutoDetect;
  FLrc.Title := '';
  FLrc.Artist := '';
  FLrc.Album := '';
  FLrc.Offset := 0;
  SetLength(FLrc.Lines, 0);
  RenderFrame;
  Invalidate;
end;

procedure TLyricForm.ReparseCurrentLyric;
begin
  if Length(FRaw) = 0 then
  begin
    FLrc.Title := '';
    FLrc.Artist := '';
    FLrc.Album := '';
    FLrc.Offset := 0;
    SetLength(FLrc.Lines, 0);
  end
  else
    FLrc := ReparseLyric(FRaw, FEncoding, FOffsetMs);
  RenderFrame;
  Invalidate;
end;

procedure TLyricForm.SetLyricEncoding(Enc: TLrcEncoding);
begin
  FEncoding := Enc;
  if Length(FRaw) > 0 then
    ReparseCurrentLyric;
end;

procedure TLyricForm.AdjustLyricOffset(DeltaMs: Integer);
begin
  Inc(FOffsetMs, DeltaMs);
  ReparseCurrentLyric;
end;

procedure TLyricForm.ResetLyricOffset;
begin
  FOffsetMs := 0;
  ReparseCurrentLyric;
end;

function TLyricForm.LyricOffsetMs: Integer;
begin
  Result := FOffsetMs;
end;

function TLyricForm.LyricEncoding: TLrcEncoding;
begin
  Result := FEncoding;
end;

procedure TLyricForm.SetTrackInfo(const ATitle, AArtist: string);
begin
  FTrackTitle := ATitle;
  FTrackArtist := AArtist;
  if Length(FLrc.Lines) = 0 then
  begin
    RenderFrame;
    Invalidate;
  end;
end;

function TLyricForm.LyricArea: TSkinRect;
var
  elem: PSkinElement;
  bgW, bgH, rightM, bottomM: Integer;
begin
  Result.X := 8;
  Result.Y := 24;
  Result.W := Max(1, FLogicW - 16);
  Result.H := Max(1, FLogicH - 32);
  if FSkin = nil then Exit;
  elem := FSkin^.LyricWindow.FindElement('lyric');
  if (elem = nil) or elem^.Position.IsEmpty then Exit;
  if FSkin^.LyricWindow.BackgroundPixmap <> nil then
  begin
    bgW := FSkin^.LyricWindow.BackgroundPixmap.Width;
    bgH := FSkin^.LyricWindow.BackgroundPixmap.Height;
  end
  else
  begin
    bgW := FLogicW;
    bgH := FLogicH;
  end;
  rightM := bgW - (elem^.Position.X + elem^.Position.W);
  bottomM := bgH - (elem^.Position.Y + elem^.Position.H);
  Result.X := elem^.Position.X;
  Result.Y := elem^.Position.Y;
  Result.W := Max(1, FLogicW - elem^.Position.X - rightM);
  Result.H := Max(1, FLogicH - elem^.Position.Y - bottomM);
end;

procedure TLyricForm.ApplySkin(ASkin: PSkinData);
var
  bg: TBGRABitmap;
begin
  if ASkin = nil then Exit;
  FSkin := ASkin;
  ConfigurePlatformWindow(Self);

  if HandleAllocated then
    ClearWindowShape(Handle);

  bg := ASkin^.LyricWindow.BackgroundPixmap;
  if bg <> nil then
  begin
    FLogicW := bg.Width;
    FLogicH := bg.Height;
    ApplySkinFormSize(Self, FLogicW, FLogicH);
  end;

  FreeAndNil(FFrame);
  RenderFrame;
  if HandleAllocated then
    BuildRegion;
  Invalidate;
  if HandleAllocated then
    Update;
end;

procedure TLyricForm.SetBounds(ALeft, ATop, AWidth, AHeight: Integer);
var
  sizeChanged, frameReady: Boolean;
  s: Double;
begin
  sizeChanged := (AWidth <> Width) or (AHeight <> Height);
  if FDeferLiveChrome and HandleAllocated then
  begin
    // FFrame 已按新尺寸画好时不要锁 Paint / SETREDRAW，否则新边会露出底色。
    frameReady := (FFrame <> nil) and (FFrame.Width >= AWidth) and
      (FFrame.Height >= AHeight);
    if not frameReady then
    begin
      FLivePaintLocked := True;
      PlatformBeginLiveSize(Handle);
    end;
    try
      inherited SetBounds(ALeft, ATop, AWidth, AHeight);
    finally
      if not frameReady then
      begin
        PlatformEndLiveSize(Handle);
        FLivePaintLocked := False;
      end;
    end;
    Invalidate;
    Exit;
  end;
  inherited SetBounds(ALeft, ATop, AWidth, AHeight);
  if sizeChanged and (FSkin <> nil) then
  begin
    s := FormViewScale(Self);
    if s < 0.01 then s := 1.0;
    FLogicW := Max(1, Round(Width / s));
    FLogicH := Max(1, Round(Height / s));
    FreeAndNil(FFrame);
    if HandleAllocated then
      BuildRegion;
    Invalidate;
  end;
end;

procedure TLyricForm.ApplyResizeDecision(const D: TLiveResizeDecision);
const
  UpdateFrameName: PAnsiChar = 'Resize.Lyric.Update';
var
  UpdateZone: TTracyZone;
begin
  if D.Kind = lrkIdle then Exit;
  if (not D.ApplyWindowSize) and (not D.RebuildNinePatch) then Exit;
  if FResizeTraceActive then
  begin
    ExecuteResizeDecision(D);
    Exit;
  end;
  FResizeTraceActive := True;
  TracyFrameStart(UpdateFrameName);
  UpdateZone := TracyZoneBegin(UpdateFrameName);
  try
    ExecuteResizeDecision(D);
  finally
    TracyZoneEnd(UpdateZone);
    TracyFrameEnd(UpdateFrameName);
    FResizeTraceActive := False;
  end;
end;

procedure TLyricForm.ExecuteResizeDecision(const D: TLiveResizeDecision);
var
  s: Double;
  fw, fh: Integer;
  growing, moved: Boolean;
  PhaseZone: TTracyZone;
begin
  if D.Kind = lrkIdle then Exit;
  // 合帧：逻辑尺寸在 session 里，HWND 未到点则不动，避免把新布局画进旧客户区。
  if (not D.ApplyWindowSize) and (not D.RebuildNinePatch) then Exit;
  s := FormViewScale(Self);
  if s < 0.01 then s := 1.0;
  fw := ScalePx(D.LogicW, s);
  fh := ScalePx(D.LogicH, s);
  if fw < 1 then fw := 1;
  if fh < 1 then fh := 1;
  growing := (fw > Width) or (fh > Height);
  moved := (Width <> fw) or (Height <> fh);

  FLogicW := Max(1, D.LogicW);
  FLogicH := Max(1, D.LogicH);

  // 圆角来自九宫格，不能把旧 HRGN 均匀拉伸（半径会跟着变）。
  // 放大：先画 FFrame、按新帧 BuildRegion，再撑 HWND。
  // 缩小：先裁 HWND，再画再 BuildRegion。
  if growing then
  begin
    PhaseZone := TracyZoneBegin('Resize.Lyric.Render');
    try
      RenderFrame;
    finally
      TracyZoneEnd(PhaseZone);
    end;
    FLastPaintChromeUs := LiveNowUs;
    if D.ApplyWindowSize and HandleAllocated then
    begin
      PhaseZone := TracyZoneBegin('Resize.Lyric.Region');
      try
        BuildRegion;
      finally
        TracyZoneEnd(PhaseZone);
      end;
    end;
    if D.ApplyWindowSize then
    begin
      FDeferLiveChrome := True;
      try
        if moved then
        begin
          PhaseZone := TracyZoneBegin('Resize.Lyric.Bounds');
          try
            SetBounds(Left, Top, fw, fh);
          finally
            TracyZoneEnd(PhaseZone);
          end;
        end;
      finally
        FDeferLiveChrome := False;
      end;
    end;
  end
  else
  begin
    if D.ApplyWindowSize then
    begin
      FDeferLiveChrome := True;
      try
        if moved then
        begin
          PhaseZone := TracyZoneBegin('Resize.Lyric.Bounds');
          try
            SetBounds(Left, Top, fw, fh);
          finally
            TracyZoneEnd(PhaseZone);
          end;
        end;
      finally
        FDeferLiveChrome := False;
      end;
    end;
    PhaseZone := TracyZoneBegin('Resize.Lyric.Render');
    try
      RenderFrame;
    finally
      TracyZoneEnd(PhaseZone);
    end;
    FLastPaintChromeUs := LiveNowUs;
    if HandleAllocated and (D.RebuildNinePatch or (D.Kind = lrkCommit)) then
    begin
      PhaseZone := TracyZoneBegin('Resize.Lyric.Region');
      try
        BuildRegion;
      finally
        TracyZoneEnd(PhaseZone);
      end;
    end;
  end;

  PhaseZone := TracyZoneBegin('Resize.Lyric.Paint');
  try
    Invalidate;
    if HandleAllocated then
      Update;
  finally
    TracyZoneEnd(PhaseZone);
  end;
end;

procedure TLyricForm.HandleResizeCoalesce(Sender: TObject);
begin
  if Sender = nil then ;
  if (FResizeSession = nil) or (not FResizeSession.Active) then
  begin
    if FResizeCoalesce <> nil then
      FResizeCoalesce.Enabled := False;
    Exit;
  end;
  ApplyResizeDecision(FResizeSession.Tick(LiveNowUs));
end;

procedure TLyricForm.MapHit(var X, Y: Integer);
begin
  ClientToSkinXY(Self, FLogicW, FLogicH, X, Y);
end;

procedure TLyricForm.RefreshViewScale;
var
  s: Double;
begin
  if FSkin = nil then Exit;
  s := FormViewScale(Self);
  SetBounds(Left, Top, ScalePx(FLogicW, s), ScalePx(FLogicH, s));
  if HandleAllocated then
    BuildRegion;
  Invalidate;
end;

procedure TLyricForm.RebuildWindowShape;
begin
  if HandleAllocated then
    BuildRegion;
end;

procedure TLyricForm.BuildRegion;
var
  src, bmp: TBGRABitmap;
  own: Boolean;
begin
  if (FSkin = nil) or (not HandleAllocated) then Exit;
  if (FFrame <> nil) and (FFrame.Width > 0) and (FFrame.Height > 0) then
  begin
    FShapeRects := MergeShapeRects(AlphaRunRects(FFrame));
    FShapeW := FFrame.Width;
    FShapeH := FFrame.Height;
    ApplyShapeRects(Handle, FShapeRects, FFrame.Width, FFrame.Height);
    FLastRgnW := FFrame.Width;
    FLastRgnH := FFrame.Height;
    Exit;
  end;
  src := FSkin^.LyricWindow.BackgroundPixmap;
  if src = nil then Exit;
  own := False;
  if (src.Width = FLogicW) and (src.Height = FLogicH) then
    bmp := src
  else
  begin
    bmp := TBGRABitmap.Create(FLogicW, FLogicH, BGRAPixelTransparent);
    own := True;
    DrawNinePatch(bmp, src, FSkin^.LyricWindow.ResizeRect,
      FSkin^.LyricWindow.ResizeTile, FLogicW, FLogicH, True);
  end;
  try
    FShapeRects := MergeShapeRects(AlphaRunRects(bmp));
    FShapeW := FLogicW;
    FShapeH := FLogicH;
    ApplyShapeRects(Handle, FShapeRects, bmp.Width, bmp.Height);
    FLastRgnW := bmp.Width;
    FLastRgnH := bmp.Height;
  finally
    if own then bmp.Free;
  end;
end;

procedure TLyricForm.CreateWnd;
begin
  inherited CreateWnd;
  ConfigurePlatformWindow(Self);
  RefreshViewScale;
end;

procedure TLyricForm.DoShow;
begin
  inherited DoShow;
  ConfigurePlatformWindow(Self);
  RefreshViewScale;
  BuildRegion;
end;

procedure TLyricForm.RenderFrame;
var
  overType: string;
  overState: TButtonVisualState;
  wnd: TSkinWindow;
  elem: PSkinElement;
  bounds: TSkinRect;
  btnX: Integer;
  s: Double;
  fw, fh: Integer;
begin
  if FSkin = nil then Exit;

  s := FormViewScale(Self);
  if s < 0.01 then s := 1.0;
  fw := ScalePx(FLogicW, s);
  fh := ScalePx(FLogicH, s);
  if fw < 1 then fw := 1;
  if fh < 1 then fh := 1;

  wnd := FSkin^.LyricWindow;

  EnsureSkinFrame(FFrame, fw, fh);
  if wnd.BackgroundPixmap <> nil then
  begin
    if (fw = FLogicW) and (fh = FLogicH) then
      DrawNinePatch(FFrame, wnd.BackgroundPixmap, wnd.ResizeRect, wnd.ResizeTile,
        FLogicW, FLogicH, True)
    else
    begin
      EnsureSkinFrame(FNineScratch, FLogicW, FLogicH);
      DrawNinePatch(FNineScratch, wnd.BackgroundPixmap, wnd.ResizeRect,
        wnd.ResizeTile, FLogicW, FLogicH, True);
      BlitNearest(FFrame, FNineScratch);
    end;
  end;

  overType  := '';
  overState := bvsNormal;
  if FPressedType <> '' then begin overType := FPressedType; overState := bvsPressed; end
  else if FHoveredType <> '' then begin overType := FHoveredType; overState := bvsHover; end;

  // close 按钮
  elem := wnd.FindElement('close');
  if elem <> nil then
  begin
    bounds := ButtonBounds(elem^);
    btnX := AlignedButtonX(elem^);
    bounds.X := btnX;
    if SameText(overType, 'close') then
      DrawButton(FFrame, elem^, bounds, overState, s)
    else
      DrawButton(FFrame, elem^, bounds, bvsNormal, s);
  end;

  // ontop 按钮（usePressedStateForToggle：开启时用 bvsPressed 渲染）
  elem := wnd.FindElement('ontop');
  if elem <> nil then
  begin
    bounds := ButtonBounds(elem^);
    btnX := AlignedButtonX(elem^);
    bounds.X := btnX;
    if SameText(overType, 'ontop') then
      DrawButton(FFrame, elem^, bounds, overState, s)
    else if FAlwaysOnTop then
      DrawButton(FFrame, elem^, bounds, bvsPressed, s)
    else
      DrawButton(FFrame, elem^, bounds, bvsNormal, s);
  end;

  DrawLyrics;
end;

procedure TLyricForm.DrawLyrics;
var
  area: TSkinRect;
  f: TSkinFont;
  textC, hiC: TBGRAPixel;
  info: string;
  lineH, visibleLines, startLine, endLine, i, y, tw: Integer;
  posMs: Int64;
  cur: Integer;
  s: Double;
  ax, ay, aw, ah, minLine: Integer;
begin
  if FFrame = nil then Exit;
  area := LyricArea;
  if (area.W <= 0) or (area.H <= 0) then Exit;
  s := FormViewScale(Self);
  if s < 0.01 then s := 1.0;
  ax := ScalePx(area.X, s);
  ay := ScalePx(area.Y, s);
  aw := ScalePx(area.X + area.W, s) - ax;
  ah := ScalePx(area.Y + area.H, s) - ay;

  if FSkin <> nil then
  begin
    f := FSkin^.LyricConfig.Font;
    ApplyViewFont(FFrame, f.Family, f.PixelSize, f.Bold, f.Italic, s);
    if FSkin^.LyricConfig.TextColor.Valid then
      textC := FSkin^.LyricConfig.TextColor.ToBGRA
    else
      textC := BGRA($00, $80, $C0);
    if FSkin^.LyricConfig.HilightColor.Valid then
      hiC := FSkin^.LyricConfig.HilightColor.ToBGRA
    else
      hiC := BGRA($00, $FF, $00);
  end
  else
  begin
    ApplyViewFont(FFrame, 'SimSun', 12, False, False, s);
    textC := BGRA($00, $80, $C0);
    hiC := BGRA($00, $FF, $00);
  end;
  FFrame.ClipRect := Classes.Rect(ax, ay, ax + aw, ay + ah);

  if Length(FLrc.Lines) = 0 then
  begin
    if FTrackTitle <> '' then
    begin
      if FTrackArtist <> '' then
        info := FTrackArtist + ' - ' + FTrackTitle
      else
        info := FTrackTitle;
    end
    else
      info := '暂无歌词';
    tw := FFrame.TextSize(info).cx;
    FFrame.TextOut(ax + (aw - tw) div 2,
      ay + (ah - FFrame.TextSize(info).cy) div 2, info, textC);
    FFrame.NoClip;
    Exit;
  end;

  minLine := ScalePx(14, s);
  lineH := FFrame.TextSize('Ag').cy + ScalePx(4, s);
  if lineH < minLine then lineH := minLine;
  posMs := 0;
  if FBackend <> nil then
    posMs := FBackend.GetPositionMs;
  cur := CurrentLyricIndex(FLrc, posMs);
  visibleLines := Max(1, ah div lineH);
  startLine := cur - visibleLines div 2;
  endLine := startLine + visibleLines;
  for i := startLine to endLine do
  begin
    if (i < 0) or (i > High(FLrc.Lines)) then Continue;
    y := ay + (i - startLine) * lineH;
    tw := FFrame.TextSize(FLrc.Lines[i].Text).cx;
    if i = cur then
      FFrame.TextOut(ax + (aw - tw) div 2, y, FLrc.Lines[i].Text, hiC)
    else
      FFrame.TextOut(ax + (aw - tw) div 2, y, FLrc.Lines[i].Text, textC);
  end;
  FFrame.NoClip;
end;

procedure TLyricForm.Paint;
begin
  if FLivePaintLocked then
  begin
    if FFrame <> nil then
      DrawSkinFrame(Canvas, FFrame, ClientWidth, ClientHeight);
    Exit;
  end;
  if SkinFrameNeedsRebuild(FFrame, ClientWidth, ClientHeight) then
  begin
    RenderFrame;
    FLastPaintChromeUs := LiveNowUs;
  end;
  if FFrame = nil then Exit;
  DrawSkinFrame(Canvas, FFrame, ClientWidth, ClientHeight);
end;

procedure TLyricForm.WMEraseBkgnd(var Message: TLMEraseBkgnd);
begin
  SwallowSkinEraseBkgnd(Message.Result);
end;

// Qt alignedRect('right') 的等价计算：
//   rightMargin = baseSize.w - (pos.x + pos.w)
//   x = currentW - rightMargin - btnW
function TLyricForm.AlignedButtonX(const Elem: TSkinElement): Integer;
var
  baseW, rightMargin, btnW: Integer;
  lAlign: string;
begin
  lAlign := LowerCase(Elem.Align);
  if Pos('right', lAlign) = 0 then
  begin
    Result := Elem.Position.X;
    Exit;
  end;
  if FSkin = nil then begin Result := Elem.Position.X; Exit; end;
  baseW := FSkin^.LyricWindow.BackgroundPixmap.Width;
  rightMargin := baseW - (Elem.Position.X + Elem.Position.W);
  btnW := ButtonBounds(Elem).W;
  Result := FLogicW - rightMargin - btnW;
end;

// 命中测试：close / ontop 按钮（使用运行时 AlignedButtonX）
function TLyricForm.HitButton(PX, PY: Integer): string;
var
  wnd: TSkinWindow;
  elem: PSkinElement;
  bounds: TSkinRect;
  btnX: Integer;
  i: Integer;
const
  kBtnNames: array[0..1] of string = ('close', 'ontop');
begin
  Result := '';
  if FSkin = nil then Exit;
  wnd := FSkin^.LyricWindow;

  for i := 0 to High(kBtnNames) do
  begin
    elem := wnd.FindElement(kBtnNames[i]);
    if elem = nil then Continue;
    bounds := ButtonBounds(elem^);
    btnX := AlignedButtonX(elem^);
    if (PX >= btnX) and (PX < btnX + bounds.W) and
       (PY >= elem^.Position.Y) and (PY < elem^.Position.Y + bounds.H) then
    begin
      Result := kBtnNames[i];
      Exit;
    end;
  end;
end;

// 8 px 边缘感应带：右边缘和/或下边缘
function TLyricForm.HitResizeEdge(PX, PY: Integer;
  out EdgeRight, EdgeBottom: Boolean): Boolean;
begin
  EdgeRight  := (PX >= FLogicW - kResizeSense) and (PX < FLogicW);
  EdgeBottom := (PY >= FLogicH - kResizeSense) and (PY < FLogicH);
  Result := EdgeRight or EdgeBottom;
end;

procedure TLyricForm.BuildLyricMenu;
var
  encMenu, offMenu: TMenuItem;
  item: TMenuItem;
  i: Integer;
  enc: TLrcEncoding;
begin
  FLyricMenu.Items.Clear;
  encMenu := TMenuItem.Create(FLyricMenu);
  encMenu.Caption := LyricEncodingMenuCaption;
  FLyricMenu.Items.Add(encMenu);
  for i := Low(AvailableLrcEncodings) to High(AvailableLrcEncodings) do
  begin
    enc := AvailableLrcEncodings[i];
    item := TMenuItem.Create(encMenu);
    item.Caption := LrcEncodingName(enc);
    item.Tag := Ord(enc);
    item.RadioItem := True;
    item.Checked := enc = FEncoding;
    item.OnClick := @HandleEncodingClick;
    encMenu.Add(item);
  end;

  item := TMenuItem.Create(FLyricMenu);
  item.Caption := '-';
  FLyricMenu.Items.Add(item);

  offMenu := TMenuItem.Create(FLyricMenu);
  offMenu.Caption := LyricOffsetMenuCaption;
  FLyricMenu.Items.Add(offMenu);

  item := TMenuItem.Create(offMenu);
  item.Caption := CurrentOffsetCaption(FOffsetMs);
  item.Enabled := False;
  offMenu.Add(item);
  item := TMenuItem.Create(offMenu);
  item.Caption := '-';
  offMenu.Add(item);
  item := TMenuItem.Create(offMenu);
  item.Caption := LyricOffsetAheadCaption;
  item.Enabled := Length(FRaw) > 0;
  item.OnClick := @HandleOffsetAhead;
  offMenu.Add(item);
  item := TMenuItem.Create(offMenu);
  item.Caption := LyricOffsetBehindCaption;
  item.Enabled := Length(FRaw) > 0;
  item.OnClick := @HandleOffsetBehind;
  offMenu.Add(item);
  item := TMenuItem.Create(offMenu);
  item.Caption := LyricOffsetResetCaption;
  item.Enabled := (Length(FRaw) > 0) and (FOffsetMs <> 0);
  item.OnClick := @HandleOffsetReset;
  offMenu.Add(item);

  item := TMenuItem.Create(FLyricMenu);
  item.Caption := '-';
  FLyricMenu.Items.Add(item);
  item := TMenuItem.Create(FLyricMenu);
  item.Caption := LyricCloseCaption;
  item.OnClick := @HandleLyricClose;
  FLyricMenu.Items.Add(item);
end;

procedure TLyricForm.HandleLyricMenuPopup(Sender: TObject);
begin
  if Sender = nil then ;
  BuildLyricMenu;
end;

procedure TLyricForm.HandleEncodingClick(Sender: TObject);
begin
  SetLyricEncoding(TLrcEncoding(TMenuItem(Sender).Tag));
end;

procedure TLyricForm.HandleOffsetAhead(Sender: TObject);
begin
  if Sender = nil then ;
  AdjustLyricOffset(-500);
end;

procedure TLyricForm.HandleOffsetBehind(Sender: TObject);
begin
  if Sender = nil then ;
  AdjustLyricOffset(500);
end;

procedure TLyricForm.HandleOffsetReset(Sender: TObject);
begin
  if Sender = nil then ;
  ResetLyricOffset;
end;

procedure TLyricForm.HandleLyricClose(Sender: TObject);
begin
  if Sender = nil then ;
  Hide;
  if Assigned(FOnCloseRequested) then
    FOnCloseRequested(Self);
end;

procedure TLyricForm.DoContextPopup(MousePos: TPoint; var Handled: Boolean);
begin
  if FSkipContextPopup then
  begin
    FSkipContextPopup := False;
    Handled := True;
    Exit;
  end;
  if MousePos.X = 0 then ;
  BuildLyricMenu;
  FLyricMenu.PopUp;
  Handled := True;
end;

procedure TLyricForm.FireButtonClick(const AName: string);
begin
  if SameText(AName, 'close') then
  begin
    Hide;
    if Assigned(FOnCloseRequested) then
      FOnCloseRequested(Self);
  end
  else if SameText(AName, 'ontop') then
  begin
    FAlwaysOnTop := not FAlwaysOnTop;
    SetWindowAlwaysOnTop(Self, FAlwaysOnTop);
  end;

  RenderFrame;
  Invalidate;
end;

procedure TLyricForm.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  er, eb: Boolean;
  hitName: string;
  sx, sy: Integer;
begin
  sx := X;
  sy := Y;
  MapHit(sx, sy);
  if Button = mbLeft then
  begin
    hitName := HitButton(sx, sy);
    if hitName <> '' then
    begin
      FPressedType := hitName;
      RenderFrame; Invalidate;
    end
    else if HitResizeEdge(sx, sy, er, eb) then
    begin
      FResizing := True;
      FResizeEdgeRight  := er;
      FResizeEdgeBottom := eb;
      FResizeStartX := Mouse.CursorPos.X;
      FResizeStartY := Mouse.CursorPos.Y;
      FResizeStartW := FLogicW;
      FResizeStartH := FLogicH;
      FResizeSession.BeginGesture(FLogicW, FLogicH);
      FResizeCoalesce.Enabled := True;
      SetCapture(Handle);
    end;
  end;
  inherited MouseDown(Button, Shift, X, Y);
  if Button = mbLeft then
    TryBeginCaptionDrag(Self, X, Y)
  else if Button = mbRight then
  begin
    BuildLyricMenu;
    FLyricMenu.PopUp;
    FSkipContextPopup := True;
  end;
end;

procedure TLyricForm.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  newName: string;
  er, eb: Boolean;
  newW, newH, dx, dy: Integer;
  s: Double;
begin
  if FResizing then
  begin
    s := FormViewScale(Self);
    if s < 0.01 then s := 1.0;
    dx := Mouse.CursorPos.X - FResizeStartX;
    dy := Mouse.CursorPos.Y - FResizeStartY;
    newW := FResizeStartW;
    newH := FResizeStartH;
    if FResizeEdgeRight  then newW := Max(200, FResizeStartW + Round(dx / s));
    if FResizeEdgeBottom then newH := Max(50,  FResizeStartH + Round(dy / s));
    if (newW <> FLogicW) or (newH <> FLogicH) then
      ApplyResizeDecision(FResizeSession.Sample(newW, newH, LiveNowUs));
  end
  else
  begin
    MapHit(X, Y);
    // hover 高亮（按钮）
    newName := HitButton(X, Y);
    if newName <> FHoveredType then
    begin
      FHoveredType := newName;
      RenderFrame; Invalidate;
    end;
    // 调整大小光标
    if HitResizeEdge(X, Y, er, eb) then
    begin
      if er and eb then Cursor := crSizeNWSE
      else if er    then Cursor := crSizeWE
      else               Cursor := crSizeNS;
    end
    else
      Cursor := crDefault;
  end;
  inherited MouseMove(Shift, X, Y);
end;

procedure TLyricForm.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  clickedType, hitName: string;
begin
  MapHit(X, Y);
  if Button = mbLeft then
  begin
    if FResizing then
    begin
      ReleaseCapture;
      FResizing := False;
      FResizeCoalesce.Enabled := False;
      ApplyResizeDecision(FResizeSession.Commit(LiveNowUs));
      FResizeSession.EndGesture;
      if Assigned(FOnResizeFinished) then
        FOnResizeFinished(Self);
    end
    else
    begin
      clickedType := FPressedType;
      FPressedType := '';
      if clickedType <> '' then
      begin
        hitName := HitButton(X, Y);
        if SameText(hitName, clickedType) then
          FireButtonClick(clickedType)
        else begin RenderFrame; Invalidate; end;
      end;
    end;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TLyricForm.MouseLeave;
begin
  if (FHoveredType <> '') or (FPressedType <> '') then
  begin
    FHoveredType := '';
    FPressedType := '';
    RenderFrame; Invalidate;
  end;
  Cursor := crDefault;
  inherited MouseLeave;
end;

// 背景区域 → HTCAPTION（拖动）；按钮/边缘 → HTCLIENT
procedure TLyricForm.WMNCHitTest(var Msg: TLMessage);
var
  pt: TPoint;
  er, eb: Boolean;
begin
  pt := NcHitToSkin(Self, Msg, FLogicW, FLogicH);

  if NcRightButtonDown then
  begin
    Msg.Result := HTCLIENT;
    Exit;
  end;

  if HitButton(pt.X, pt.Y) <> '' then
    Msg.Result := HTCLIENT
  else if HitResizeEdge(pt.X, pt.Y, er, eb) then
    Msg.Result := HTCLIENT   // 让 MouseDown/Move/Up 处理调整大小
  else
    Msg.Result := HTCAPTION;
end;

end.
