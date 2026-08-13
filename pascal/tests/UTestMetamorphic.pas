unit UTestMetamorphic;

{$mode objfpc}{$H+}

// Layer 4：Metamorphic Testing（变形测试）。
//
// 变形关系（Metamorphic Relation，MR）：当输入发生已知变换时，
// 输出必须满足的关系约束。适用于"难以直接给出期望值，但能描述
// 两次调用结果之间关系"的场景，是对 expect/snapshot 测试的补充。
//
// 本文件覆盖三组 MR：
//
//   MR-1  滑块位置计算的数学性质（单调性、边界、对称性、往返一致）
//         被测函数：SliderValueToPos / SliderPosToValue
//         变形关系：
//           a) 单调性：v1 < v2 → pos(v1) <= pos(v2)（水平）
//           b) 边界：pos(min)=0，pos(max)=track-thumb
//           c) 关于中点对称：pos(min+max-v) = track-thumb - pos(v)
//           d) 往返一致：posToValue(valueToPos(v)) ≈ v（浮点精度内）
//
//   MR-2  色键变形（皮肤解析对透明色替换的鲁棒性）
//         对同一张图，把 transparent_color 换成另一个不在图中的颜色，
//         解析出的元素数量和位置坐标不变（颜色替换不影响布局）。
//
//   MR-3  皮肤解析的缩放无关性（元素 position 以像素绝对坐标存储）
//         对同一 Skin.xml，用两套不同分辨率的假背景图（尺寸不同）
//         解析出的 position 值应相同（position 来自 XML，不依赖图像尺寸）。

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  USkinTypes, USkinXmlParser, USkinLoader, USkinRender;

type
  TMetamorphicTest = class(TTestCase)
  published
    // MR-1：滑块位置计算的数学性质
    procedure TestSliderMonotonicity;
    procedure TestSliderBoundary;
    procedure TestSliderSymmetry;
    procedure TestSliderRoundTrip;
    // MR-2：色键变形（透明色替换不影响布局）
    procedure TestTransparentColorSwap;
    // MR-3：解析位置坐标与背景图尺寸无关
    procedure TestPositionIndependentOfImageSize;
  end;

implementation

uses
  BGRABitmap, BGRABitmapTypes, Math;

const
  Eps = 1e-9;  // 浮点比较容差

{ MR-1a：单调性 }
procedure TMetamorphicTest.TestSliderMonotonicity;
const
  TrackLen = 257;
  ThumbSize = 20;
  Min = 0.0;
  Max = 100.0;
var
  v, prevPos, pos: Integer;
begin
  prevPos := -1;
  // 以整数步长从 Min 到 Max 采样，每步 pos 不得小于上一步
  for v := 0 to 100 do
  begin
    pos := SliderValueToPos(v, Min, Max, TrackLen, ThumbSize, False);
    if prevPos >= 0 then
      AssertTrue(
        Format('单调性违反：v=%d pos=%d < prev=%d', [v, pos, prevPos]),
        pos >= prevPos);
    prevPos := pos;
  end;
end;

{ MR-1b：边界 }
procedure TMetamorphicTest.TestSliderBoundary;
const
  TrackLen = 200;
  ThumbSize = 16;
  Min = -12.0;
  Max = 12.0;
begin
  // 水平滑块
  AssertEquals('水平 pos(min)=0',
    0, SliderValueToPos(Min, Min, Max, TrackLen, ThumbSize, False));
  AssertEquals('水平 pos(max)=track-thumb',
    TrackLen - ThumbSize,
    SliderValueToPos(Max, Min, Max, TrackLen, ThumbSize, False));

  // 垂直滑块（min 对应底部，max 对应顶部；这里 pos 是从顶部量的像素距离）
  // pos(max) 最小（接近 0 顶部），pos(min) 最大（接近底部）
  AssertEquals('垂直 pos(max) 在顶部区域',
    0, SliderValueToPos(Max, Min, Max, TrackLen, ThumbSize, True));
  AssertEquals('垂直 pos(min) 在底部区域',
    TrackLen - ThumbSize,
    SliderValueToPos(Min, Min, Max, TrackLen, ThumbSize, True));

  // 超出范围应夹取
  AssertEquals('pos(min-1) 夹取到 0',
    0, SliderValueToPos(Min - 5, Min, Max, TrackLen, ThumbSize, False));
  AssertEquals('pos(max+1) 夹取到 track-thumb',
    TrackLen - ThumbSize,
    SliderValueToPos(Max + 5, Min, Max, TrackLen, ThumbSize, False));
end;

{ MR-1c：关于中点对称
  变形关系：对水平滑块，v 与 (min+max-v) 关于中点对称，
  因此 pos(v) + pos(min+max-v) = track - thumb（轴对称）。
  允许 ±1 的截断误差。 }
procedure TMetamorphicTest.TestSliderSymmetry;
const
  TrackLen = 312;
  ThumbSize = 12;
  Min = 0.0;
  Max = 100.0;
var
  v: Integer;
  pos1, pos2, total: Integer;
begin
  for v := 0 to 100 do
  begin
    pos1 := SliderValueToPos(v,         Min, Max, TrackLen, ThumbSize, False);
    pos2 := SliderValueToPos(Min + Max - v, Min, Max, TrackLen, ThumbSize, False);
    total := TrackLen - ThumbSize;
    AssertTrue(
      Format('对称性：v=%d pos1=%d pos2=%d sum=%d expected=%d ±1',
             [v, pos1, pos2, pos1+pos2, total]),
      Abs((pos1 + pos2) - total) <= 1);
  end;
end;

{ MR-1d：往返一致（posToValue(valueToPos(v)) ≈ v）
  容差：由于 Trunc 截断，往返误差最多为 (max-min)/track_len + eps。 }
procedure TMetamorphicTest.TestSliderRoundTrip;
const
  TrackLen = 312;
  ThumbSize = 0;   // 无 thumb 时往返误差理论上为 0
  Min = -12.0;
  Max = 12.0;
var
  v100: Integer;
  vf, vBack, tolerance: Double;
begin
  tolerance := (Max - Min) / TrackLen + Eps;
  for v100 := 0 to 100 do
  begin
    vf := Min + v100 / 100.0 * (Max - Min);
    vBack := SliderPosToValue(
      SliderValueToPos(vf, Min, Max, TrackLen, ThumbSize, False),
      Min, Max, TrackLen, False);
    AssertTrue(
      Format('往返误差过大：v=%.4f vBack=%.4f diff=%.6f tol=%.6f',
             [vf, vBack, Abs(vf - vBack), tolerance]),
      Abs(vf - vBack) <= tolerance);
  end;
end;

{ MR-2：色键变形——透明色替换不影响解析结果的元素数量和位置
  构造一段最小 Skin.xml（只含 player_window + 一个 play 按钮），
  用颜色 A 和颜色 B（都不出现在任何图像中）作为 transparent_color 分别解析，
  断言两次解析的元素数量、各元素的 type 和 position 完全一致。 }
procedure TMetamorphicTest.TestTransparentColorSwap;
const
  MinimalSkinXml =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<skin version="2" name="MR2Test" transparent_color="#%s">' +
    '<player_window image="">' +
    '<play position="10,20,50,60" image=""/>' +
    '<progress position="5,70,260,82" bar_image="" thumb_image=""/>' +
    '</player_window>' +
    '</skin>';
var
  xmlA, xmlB: string;
  skinA, skinB: TSkinData;
  images: TSkinImageMap;
  i: Integer;
begin
  // 两种不出现在图像中的颜色（无图像可言，所以色键不会命中任何像素）
  xmlA := Format(MinimalSkinXml, ['ff00ff']);  // 默认透明色
  xmlB := Format(MinimalSkinXml, ['00ff00']);  // 换一种不同的透明色

  InitSkinData(skinA);
  InitSkinData(skinB);
  images := TSkinImageMap.Create;
  try
    AssertTrue('MR-2 解析 A', ParseSkinXml(xmlA, images,
      TSkinColor.Make(255, 0, 255), skinA));
    AssertTrue('MR-2 解析 B', ParseSkinXml(xmlB, images,
      TSkinColor.Make(0, 255, 0), skinB));

    // 元素数量相同
    AssertEquals('MR-2 元素数量',
      Length(skinA.PlayerWindow.Elements),
      Length(skinB.PlayerWindow.Elements));

    // 各元素 type 和 position 完全一致（色键替换不影响布局解析）
    for i := 0 to High(skinA.PlayerWindow.Elements) do
    begin
      AssertEquals(Format('MR-2 元素[%d] type', [i]),
        skinA.PlayerWindow.Elements[i].ElementType,
        skinB.PlayerWindow.Elements[i].ElementType);
      AssertEquals(Format('MR-2 元素[%d] x', [i]),
        skinA.PlayerWindow.Elements[i].Position.X,
        skinB.PlayerWindow.Elements[i].Position.X);
      AssertEquals(Format('MR-2 元素[%d] y', [i]),
        skinA.PlayerWindow.Elements[i].Position.Y,
        skinB.PlayerWindow.Elements[i].Position.Y);
      AssertEquals(Format('MR-2 元素[%d] w', [i]),
        skinA.PlayerWindow.Elements[i].Position.W,
        skinB.PlayerWindow.Elements[i].Position.W);
      AssertEquals(Format('MR-2 元素[%d] h', [i]),
        skinA.PlayerWindow.Elements[i].Position.H,
        skinB.PlayerWindow.Elements[i].Position.H);
    end;
  finally
    images.Free;
    FreeSkinData(skinA);
    FreeSkinData(skinB);
  end;
end;

{ MR-3：position 坐标与背景图尺寸无关
  同一 Skin.xml 用两张尺寸不同的假背景图（均为纯色 BMP）解析，
  断言 player_window 各元素的 position 完全一致。
  这验证解析器不会把图像尺寸混入坐标计算。 }
procedure TMetamorphicTest.TestPositionIndependentOfImageSize;
const
  SkinXml =
    '<?xml version="1.0" encoding="UTF-8"?>' +
    '<skin version="2" name="MR3Test" transparent_color="#ff00ff">' +
    '<player_window image="bg.bmp">' +
    '<play position="88,90,132,134" image="btn.bmp"/>' +
    '<volume position="10,50,80,62" bar_image="bar.bmp" thumb_image="thumb.bmp"/>' +
    '</player_window>' +
    '</skin>';
var
  skinSmall, skinLarge: TSkinData;
  imagesSmall, imagesLarge: TSkinImageMap;
  bgSmall, bgLarge, btn, bar, thumb: TBGRABitmap;
  i: Integer;
begin
  InitSkinData(skinSmall);
  InitSkinData(skinLarge);

  // 小背景：275×116（Classic 尺寸）
  bgSmall := TBGRABitmap.Create(275, 116, BGRA(50, 50, 50, 255));
  // 大背景：540×286（Subaru 尺寸）
  bgLarge := TBGRABitmap.Create(540, 286, BGRA(50, 50, 50, 255));
  btn    := TBGRABitmap.Create(44, 11, BGRA(200, 100, 0, 255));
  bar    := TBGRABitmap.Create(62, 5, BGRA(80, 80, 80, 255));
  thumb  := TBGRABitmap.Create(10, 10, BGRA(200, 200, 200, 255));

  imagesSmall := TSkinImageMap.Create;
  imagesLarge := TSkinImageMap.Create;
  try
    // 图像所有权由 TSkinImageMap 管理；两份各自持有独立副本
    imagesSmall.Add('bg.bmp', bgSmall.Duplicate);
    imagesSmall.Add('btn.bmp', btn.Duplicate);
    imagesSmall.Add('bar.bmp', bar.Duplicate);
    imagesSmall.Add('thumb.bmp', thumb.Duplicate);

    imagesLarge.Add('bg.bmp', bgLarge.Duplicate);
    imagesLarge.Add('btn.bmp', btn.Duplicate);
    imagesLarge.Add('bar.bmp', bar.Duplicate);
    imagesLarge.Add('thumb.bmp', thumb.Duplicate);

    AssertTrue('MR-3 小图解析', ParseSkinXml(SkinXml, imagesSmall,
      TSkinColor.Make(255, 0, 255), skinSmall));
    AssertTrue('MR-3 大图解析', ParseSkinXml(SkinXml, imagesLarge,
      TSkinColor.Make(255, 0, 255), skinLarge));

    AssertEquals('MR-3 元素数量相同',
      Length(skinSmall.PlayerWindow.Elements),
      Length(skinLarge.PlayerWindow.Elements));

    for i := 0 to High(skinSmall.PlayerWindow.Elements) do
    begin
      AssertEquals(Format('MR-3 元素[%d] x', [i]),
        skinSmall.PlayerWindow.Elements[i].Position.X,
        skinLarge.PlayerWindow.Elements[i].Position.X);
      AssertEquals(Format('MR-3 元素[%d] y', [i]),
        skinSmall.PlayerWindow.Elements[i].Position.Y,
        skinLarge.PlayerWindow.Elements[i].Position.Y);
      AssertEquals(Format('MR-3 元素[%d] w', [i]),
        skinSmall.PlayerWindow.Elements[i].Position.W,
        skinLarge.PlayerWindow.Elements[i].Position.W);
    end;
  finally
    imagesSmall.Free;
    imagesLarge.Free;
    bgSmall.Free;
    bgLarge.Free;
    btn.Free;
    bar.Free;
    thumb.Free;
    FreeSkinData(skinSmall);
    FreeSkinData(skinLarge);
  end;
end;

initialization
  RegisterTest(TMetamorphicTest);

end.
