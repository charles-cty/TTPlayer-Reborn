unit USkinErase;

{$mode objfpc}{$H+}

// 皮肤窗 Color=clBlack。Win32 InvalidateRect(..., True) 会先发
// WM_ERASEBKGND，DefWindowProc 用 Color 铺客户区，Paint 之前就是黑闪。
// 处理函数必须 Result=1 并吞掉该消息（只覆盖 EraseBackground 不够）。
// 不依赖 LCL，供窗体 handler 与 FPCUnit 共用。

interface

function SkinEraseBkgndHandled: PtrInt;
procedure SwallowSkinEraseBkgnd(var MsgResult: PtrInt);

implementation

function SkinEraseBkgndHandled: PtrInt;
begin
  Result := 1;
end;

procedure SwallowSkinEraseBkgnd(var MsgResult: PtrInt);
begin
  MsgResult := SkinEraseBkgndHandled;
end;

end.
