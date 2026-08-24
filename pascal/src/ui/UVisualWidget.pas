unit UVisualWidget;

{$mode objfpc}{$H+}

// 频谱/示波图控件，对应 Qt 版 src/ui/VisualWidget。
// 三种模式：Spectrum（柱状频谱 + 峰值线）、BlurScope（模糊示波图）、None。
// 数据来自 IPlayerBackend.GetSpectrum（TStubBackend 提供归一化假数据）。
// 绘制直接用 BGRABitmap，通过 TBGRABitmap.Draw 贴到 LCL Canvas。
// 作为 TPlayerForm 内嵌子控件，挂在 visual 元素的 position 区域。

interface

uses
  Classes, SysUtils, Controls, Graphics, ExtCtrls, Forms,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, UPlayerBackend;

type
  TVisualMode = (vmSpectrum, vmBlurScope, vmNone);

  TVisualWidget = class(TCustomControl)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;

    // 应用皮肤可视化配置（颜色、帧率、模式）。
    procedure ApplyConfig(const AConfig: TVisualConfig);

    // 设置可视化区域矩形（在父窗口 canvas 上的位置/尺寸）。
    procedure SetVisualRect(const R: TSkinRect);

  protected
    procedure Paint; override;

  private
    FBackend: IPlayerBackend;
    FConfig:  TVisualConfig;
    FMode:    TVisualMode;
    FTimer:   TTimer;
    FFrame:   TBGRABitmap;       // 离屏缓冲

    // 频谱数据（归一化 0..1，长度 = BandCount）
    FSpecData:  array of Single;
    FPeakData:  array of Single;

    // 模糊示波：历史波形（最多 4 帧）
    FScopeHistory: array of array of Single;

    procedure TimerTick(Sender: TObject);
    procedure SetMode(AMode: TVisualMode);
    procedure UpdateTimer;
    function  BandCount: Integer;
    procedure RenderSpectrum;
    procedure RenderBlurScope;

    // 颜色辅助
    function ConfigColor(const C: TSkinColor): TBGRAPixel;

  public
    // 当前模式
    property Mode: TVisualMode read FMode write SetMode;
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

constructor TVisualWidget.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  inherited Create(AOwner);

  FBackend := ABackend;
  FMode    := vmSpectrum;
  FFrame   := nil;

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
  FFrame.Free;
  inherited Destroy;
end;

procedure TVisualWidget.ApplyConfig(const AConfig: TVisualConfig);
begin
  FConfig := AConfig;
  UpdateTimer;
  Invalidate;
end;

procedure TVisualWidget.SetVisualRect(const R: TSkinRect);
var
  s: Double;
  f: TCustomForm;
begin
  f := GetParentForm(Self);
  s := FormViewScale(f);
  SetBounds(ScalePx(R.X, s), ScalePx(R.Y, s), ScalePx(R.W, s), ScalePx(R.H, s));
  UpdateTimer;
end;

procedure TVisualWidget.SetMode(AMode: TVisualMode);
begin
  if FMode = AMode then Exit;
  FMode := AMode;
  if FMode <> vmBlurScope then
    SetLength(FScopeHistory, 0);
  UpdateTimer;
  Invalidate;
end;

procedure TVisualWidget.UpdateTimer;
var
  fps: Integer;
begin
  fps := FConfig.FramesPerSec;
  if fps < 10 then fps := 10;
  if fps > 120 then fps := 120;
  FTimer.Interval := 1000 div fps;
  FTimer.Enabled  := (FMode <> vmNone) and Visible;
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

// ── 定时器：拉取频谱数据并刷新 ─────────────────────────────────────
procedure TVisualWidget.TimerTick(Sender: TObject);
var
  bands, i: Integer;
  newVal: Single;
  wave: array of Double;
  waveF: array of Single;
  n: Integer;
begin
  if FMode = vmNone then Exit;

  bands := BandCount;
  if Length(FSpecData) <> bands then
  begin
    SetLength(FSpecData, bands);
    SetLength(FPeakData, bands);
    FillChar(FSpecData[0], bands * SizeOf(Single), 0);
    FillChar(FPeakData[0], bands * SizeOf(Single), 0);
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
    // 频谱模式：从 Backend 拉取 bands 个归一化值
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
    // 示波图模式：拉取一个时间域样本帧（用频谱 slot 作缓冲）
    SetLength(wave, kScopeLen);
    n := FBackend.GetSpectrum(@wave[0], kScopeLen);
    SetLength(waveF, kScopeLen);
    for i := 0 to kScopeLen - 1 do
      waveF[i] := wave[i] * 2.0 - 1.0;  // 归一化 0-1 → -1..1

    // 追加到历史
    SetLength(FScopeHistory, Length(FScopeHistory) + 1);
    FScopeHistory[High(FScopeHistory)] := waveF;
    if Length(FScopeHistory) > kScopeHistMax then
    begin
      Move(FScopeHistory[1], FScopeHistory[0],
        (Length(FScopeHistory) - 1) * SizeOf(FScopeHistory[0]));
      SetLength(FScopeHistory, kScopeHistMax);
    end;
  end;

  // 重绘
  FreeAndNil(FFrame);
  if FMode = vmSpectrum then RenderSpectrum
  else if FMode = vmBlurScope then RenderBlurScope;
  Invalidate;
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

  FreeAndNil(FFrame);
  FFrame := TBGRABitmap.Create(w, h, BGRAPixelTransparent);

  bands := Max(1, Length(FSpecData));
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
        // btm → mid: weight = ratio*2 → 0=btm, 1=mid
        barColor := MergeBGRA(btmC, 255 - Round(ratio * 2 * 255), midC, Round(ratio * 2 * 255))
      else
        // mid → top: weight = (ratio-0.5)*2 → 0=mid, 1=top
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

  FreeAndNil(FFrame);
  FFrame := TBGRABitmap.Create(w, h, BGRAPixelTransparent);
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
  if FFrame <> nil then
    FFrame.Draw(Canvas, 0, 0, True);
end;

end.
