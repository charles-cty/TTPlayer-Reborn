unit UVisualWidget;

{$mode objfpc}{$H+}

// 频谱/示波图控件，对应 Qt 版 src/ui/VisualWidget。
// 四种模式：Spectrum、BlurScope、Cover、None。Cover/None 时由 PlayerForm
// 在 visual 矩形上自绘（控件隐藏）。点击 visual 区域循环模式。
// TGraphicControl：不占 HWND。主窗是 WS_CLIPCHILDREN 异形窗，子 HWND
// 会在父窗客户区挖洞，InvalidateRect(erase) 先把洞铺成 Color（clBlack）。

interface

uses
  Classes, SysUtils, Controls, Graphics, ExtCtrls, Forms,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, UPlayerBackend;

type
  TVisualMode = (vmSpectrum, vmBlurScope, vmCover, vmNone);

  TVisualWidget = class(TGraphicControl)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;
    procedure AttachBackend(ABackend: IPlayerBackend);

    // 应用皮肤可视化配置（颜色、帧率、模式）。
    procedure ApplyConfig(const AConfig: TVisualConfig);

    // 设置可视化区域矩形（在父窗口 canvas 上的位置/尺寸）。
    procedure SetVisualRect(const R: TSkinRect);

    // 拷贝主窗皮肤在 visual 矩形上的像素，频谱画在皮肤凹槽上。
    procedure SetSkinBackground(ABg: TBGRABitmap);

    procedure SetVisualVisible(AValue: Boolean);
    // GTK3：子控件 Canvas 上 BGRA.Draw 会 LPtoDP 把 Left/Top 加两遍，
    // visual 凹槽左上露出白底。由 PlayerForm.Paint 画到窗体 Canvas。
    procedure DrawOnto(ACanvas: TCanvas; AX, AY: Integer);
    function OverlayOnParent: Boolean;

  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;

  private
    FBackend: IPlayerBackend;
    FConfig:  TVisualConfig;
    FMode:    TVisualMode;
    FTimer:   TTimer;
    FFrame:   TBGRABitmap;       // 离屏缓冲
    FBg:      TBGRABitmap;       // 皮肤 visual 矩形拷贝
    FSkinRect: TSkinRect;
    FOnClicked: TNotifyEvent;
    FActive: Boolean;

    // 频谱数据（归一化 0..1，长度 = BandCount）
    FSpecData:  array of Single;
    FPeakData:  array of Single;

    // 模糊示波：历史波形（最多 4 帧）
    FScopeHistory: array of array of Single;

    procedure TimerTick(Sender: TObject);
    procedure SetMode(AMode: TVisualMode);
    procedure UpdateTimer;
    procedure RequestPaint;
    function  BandCount: Integer;
    procedure EnsureFrame;
    procedure RenderSpectrum;
    procedure RenderBlurScope;

    // 颜色辅助
    function ConfigColor(const C: TSkinColor): TBGRAPixel;

  public
    // 当前模式
    property Mode: TVisualMode read FMode write SetMode;
    property OnClicked: TNotifyEvent read FOnClicked write FOnClicked;
  end;

implementation

uses
  Math, LCLType, USkinView, UDpiScale;

const
  kScopeLen     = 256;
  kScopeHistMax = 4;
  kDecayFactor  = 0.85;   // 播放停止时频谱衰减
  kPeakDecay    = 0.01;   // 峰值每帧下落量

{ TVisualWidget }

procedure TVisualWidget.AttachBackend(ABackend: IPlayerBackend);
begin
  FBackend := ABackend;
end;

constructor TVisualWidget.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  inherited Create(AOwner);

  FBackend := ABackend;
  FMode    := vmSpectrum;
  FFrame   := nil;
  FBg      := nil;
  FSkinRect := TSkinRect.Zero;
  ControlStyle := ControlStyle + [csOpaque];
  Color := clBlack;
  FActive := False;

  FTimer          := TTimer.Create(Self);
  FTimer.Interval := 33;   // ~30 fps
  FTimer.Enabled  := False;
  FTimer.OnTimer  := @TimerTick;

  // 默认配置（对应 InitSkinData 的默认值）
  FConfig.SpectrumTopColor  := TSkinColor.Make($FF, $00, $80);
  FConfig.SpectrumMidColor  := TSkinColor.Make($FF, $FF, $00);
  FConfig.SpectrumBtmColor  := TSkinColor.Make($00, $80, $FF);
  FConfig.SpectrumPeakColor := TSkinColor.Make($FF, $FF, $FF);
  FConfig.BlurScopeColor    := TSkinColor.Make($00, $FF, $FF);
  FConfig.SpectrumWide      := 0;
  FConfig.FramesPerSec      := 30;
  FConfig.Blur              := True;
end;

destructor TVisualWidget.Destroy;
begin
  FTimer.Enabled := False;
  FreeAndNil(FFrame);
  FreeAndNil(FBg);
  inherited Destroy;
end;

procedure TVisualWidget.ApplyConfig(const AConfig: TVisualConfig);
begin
  FConfig := AConfig;
  UpdateTimer;
  RequestPaint;
end;

procedure TVisualWidget.SetVisualRect(const R: TSkinRect);
var
  s: Double;
  f: TCustomForm;
begin
  FSkinRect := R;
  f := GetParentForm(Self);
  s := FormViewScale(f);
  SetBounds(ScalePx(R.X, s), ScalePx(R.Y, s), ScalePx(R.W, s), ScalePx(R.H, s));
  UpdateTimer;
end;

procedure TVisualWidget.SetSkinBackground(ABg: TBGRABitmap);
var
  r: TRect;
begin
  FreeAndNil(FBg);
  if (ABg = nil) or FSkinRect.IsEmpty then
    Exit;
  r := Classes.Rect(FSkinRect.X, FSkinRect.Y,
    FSkinRect.X + FSkinRect.W, FSkinRect.Y + FSkinRect.H);
  if r.Left < 0 then
    r.Left := 0;
  if r.Top < 0 then
    r.Top := 0;
  if r.Right > ABg.Width then
    r.Right := ABg.Width;
  if r.Bottom > ABg.Height then
    r.Bottom := ABg.Height;
  if (r.Right <= r.Left) or (r.Bottom <= r.Top) then
    Exit;
  FBg := ABg.GetPart(r);
  if FMode = vmSpectrum then
    RenderSpectrum
  else if FMode = vmBlurScope then
    RenderBlurScope;
  RequestPaint;
end;

procedure TVisualWidget.SetVisualVisible(AValue: Boolean);
begin
  FActive := AValue;
{$IFDEF WINDOWS}
  Visible := AValue;
{$ELSE}
  // 不把 TGraphicControl 盖在凹槽上，避免 GTK3 白块。
  Visible := False;
{$ENDIF}
  UpdateTimer;
  RequestPaint;
end;

function TVisualWidget.OverlayOnParent: Boolean;
begin
{$IFDEF WINDOWS}
  Result := False;
{$ELSE}
  Result := FActive;
{$ENDIF}
end;

procedure TVisualWidget.DrawOnto(ACanvas: TCanvas; AX, AY: Integer);
begin
  if ACanvas = nil then Exit;
  if FFrame <> nil then
    FFrame.Draw(ACanvas, AX, AY, True)
  else if FBg <> nil then
    FBg.Draw(ACanvas, AX, AY, True);
end;

procedure TVisualWidget.RequestPaint;
begin
  if OverlayOnParent and (Parent <> nil) then
    Parent.Invalidate
  else
    Invalidate;
end;

procedure TVisualWidget.SetMode(AMode: TVisualMode);
begin
  if FMode = AMode then Exit;
  FMode := AMode;
  if FMode <> vmBlurScope then
    SetLength(FScopeHistory, 0);
  UpdateTimer;
  RequestPaint;
end;

procedure TVisualWidget.UpdateTimer;
var
  fps: Integer;
begin
  fps := FConfig.FramesPerSec;
  if fps < 10 then fps := 10;
  if fps > 120 then fps := 120;
  FTimer.Interval := 1000 div fps;
  FTimer.Enabled  := FActive and
    ((FMode = vmSpectrum) or (FMode = vmBlurScope));
end;

function TVisualWidget.BandCount: Integer;
var
  gap, barW: Integer;
begin
  gap  := IfThen(FConfig.SpectrumWide > 0, 2, 1);
  barW := IfThen(FConfig.SpectrumWide > 0, 4, 3);
  Result := Max(8, Min(48, (Width + gap) div (barW + gap)));
end;

function TVisualWidget.ConfigColor(const C: TSkinColor): TBGRAPixel;
begin
  if C.Valid then
    Result := BGRA(C.R, C.G, C.B, 255)
  else
    Result := BGRA(128, 128, 128, 255);
end;

procedure TVisualWidget.EnsureFrame;
var
  w, h: Integer;
begin
  w := Width;
  h := Height;
  if (w <= 0) or (h <= 0) then
  begin
    FreeAndNil(FFrame);
    Exit;
  end;
  if (FFrame = nil) or (FFrame.Width <> w) or (FFrame.Height <> h) then
  begin
    FreeAndNil(FFrame);
    FFrame := TBGRABitmap.Create(w, h, BGRA(0, 0, 0, 255));
  end
  else
    FFrame.Fill(BGRA(0, 0, 0, 255));
  if FBg = nil then
    Exit;
  if (FBg.Width = w) and (FBg.Height = h) then
    FFrame.PutImage(0, 0, FBg, dmDrawWithTransparency)
  else
    FFrame.StretchPutImage(Classes.Rect(0, 0, w, h), FBg, dmDrawWithTransparency);
end;

// ── 定时器：拉取频谱数据并刷新 ─────────────────────────────────────
procedure TVisualWidget.TimerTick(Sender: TObject);
var
  bands, i, n, nHist: Integer;
  newVal: Single;
  wave: array of Double;
  waveF: array of Single;
begin
  if FMode = vmNone then Exit;

  bands := BandCount;
  if Length(FSpecData) <> bands then
  begin
    SetLength(FSpecData, bands);
    SetLength(FPeakData, bands);
    if bands > 0 then
    begin
      FillChar(FSpecData[0], bands * SizeOf(Single), 0);
      FillChar(FPeakData[0], bands * SizeOf(Single), 0);
    end;
  end;

  if (FBackend = nil) or (FBackend.GetState <> psPlaying) then
  begin
    // 停止播放时频谱衰减
    for i := 0 to bands - 1 do
    begin
      FSpecData[i] := FSpecData[i] * kDecayFactor;
      FPeakData[i] := FPeakData[i] * 0.92;
    end;
  end
  else if FMode = vmSpectrum then
  begin
    SetLength(wave, bands);
    n := FBackend.GetSpectrum(@wave[0], bands);
    for i := 0 to n - 1 do
    begin
      newVal := wave[i];
      if newVal > FSpecData[i] then
        FSpecData[i] := newVal
      else
        FSpecData[i] := FSpecData[i] * kDecayFactor + newVal * (1.0 - kDecayFactor);
      if FSpecData[i] > FPeakData[i] then
        FPeakData[i] := FSpecData[i]
      else
        FPeakData[i] := Max(0.0, FPeakData[i] - kPeakDecay);
    end;
  end
  else if FMode = vmBlurScope then
  begin
    SetLength(waveF, kScopeLen);
    n := FBackend.GetWaveform(@waveF[0], kScopeLen);
    if n < 0 then
      n := 0;

    nHist := Length(FScopeHistory);
    SetLength(FScopeHistory, nHist + 1);
    FScopeHistory[nHist] := Copy(waveF);
    if Length(FScopeHistory) > kScopeHistMax then
    begin
      for i := 0 to kScopeHistMax - 1 do
        FScopeHistory[i] := FScopeHistory[i + 1];
      SetLength(FScopeHistory, kScopeHistMax);
    end;
  end;

  if FMode = vmSpectrum then RenderSpectrum
  else if FMode = vmBlurScope then RenderBlurScope;
  RequestPaint;
end;

// ── 频谱渲染 ─────────────────────────────────────────────────────────
procedure TVisualWidget.RenderSpectrum;
var
  w, h, bands, barW, gap, i, x, barH, peakY, py: Integer;
  topC, midC, btmC, peakC: TBGRAPixel;
  barColor: TBGRAPixel;
  ratio: Single;
begin
  w := Width;
  h := Height;
  if (w <= 0) or (h <= 0) then Exit;

  EnsureFrame;
  if FFrame = nil then Exit;

  // Empty until the first timer tick. Max(1, Length) used to index nil [0].
  bands := Length(FSpecData);
  if (bands <= 0) or (Length(FPeakData) < bands) then
  begin
    FFrame.InvalidateBitmap;
    Exit;
  end;
  gap   := IfThen(FConfig.SpectrumWide > 0, 2, 1);
  barW  := Max(2, (w - (bands - 1) * gap) div bands);

  topC  := ConfigColor(FConfig.SpectrumTopColor);
  midC  := ConfigColor(FConfig.SpectrumMidColor);
  btmC  := ConfigColor(FConfig.SpectrumBtmColor);
  peakC := ConfigColor(FConfig.SpectrumPeakColor);

  for i := 0 to bands - 1 do
  begin
    x    := i * (barW + gap);
    barH := Round(FSpecData[i] * h);
    if barH > h then barH := h;
    if barH <= 0 then Continue;

    // 线性渐变：每像素插值 btm→mid→top
    for py := h - barH to h - 1 do
    begin
      ratio := 1.0 - (py / h);  // 0 = bottom, 1 = top
      if ratio < 0.5 then
        barColor := MergeBGRA(btmC, 255 - Round(ratio * 2 * 255), midC, Round(ratio * 2 * 255))
      else
        barColor := MergeBGRA(midC, 255 - Round((ratio - 0.5) * 2 * 255), topC, Round((ratio - 0.5) * 2 * 255));
      FFrame.DrawHorizLine(x, py, x + barW - 1, barColor);
    end;

    // 峰值线
    peakY := h - Round(FPeakData[i] * h);
    peakY := Max(0, peakY);
    if peakY < h then
      FFrame.DrawHorizLine(x, peakY, x + barW - 1, peakC);
  end;

  FFrame.InvalidateBitmap;
end;

// ── 示波图渲染 ───────────────────────────────────────────────────────
procedure TVisualWidget.RenderBlurScope;
var
  w, h, midY, t, i: Integer;
  alpha: Integer;
  scopeC: TBGRAPixel;
  wave: array of Single;
  y0, y1: Integer;
begin
  w := Width;
  h := Height;
  if (w <= 0) or (h <= 0) then Exit;

  EnsureFrame;
  if FFrame = nil then Exit;
  midY := h div 2;

  for t := 0 to High(FScopeHistory) do
  begin
    alpha := Round((t + 1) / Length(FScopeHistory) *
               IfThen(FConfig.Blur, 200, 255));
    scopeC := ConfigColor(FConfig.BlurScopeColor);
    scopeC.alpha := alpha;

    wave := FScopeHistory[t];
    for i := 1 to Min(High(wave), w - 1) do
    begin
      y0 := midY - Round(wave[i - 1] * midY);
      y1 := midY - Round(wave[i] * midY);
      FFrame.DrawLineAntialias(i - 1, y0, i, y1, scopeC, 1.5);
    end;
  end;

  FFrame.InvalidateBitmap;
end;

procedure TVisualWidget.Paint;
begin
  if OverlayOnParent then
    Exit;
  if FFrame <> nil then
    FFrame.Draw(Canvas, 0, 0, True)
  else if FBg <> nil then
    FBg.Draw(Canvas, 0, 0, True)
  else
  begin
    Canvas.Brush.Color := clBlack;
    Canvas.FillRect(0, 0, Width, Height);
  end;
end;

procedure TVisualWidget.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  if Button = mbLeft then
  begin
    if Assigned(FOnClicked) then
      FOnClicked(Self);
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

end.
