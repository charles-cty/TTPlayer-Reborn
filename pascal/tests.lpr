program tests;

{$mode objfpc}{$H+}

// FPCUnit 控制台测试入口：
//   Layer 2 — 渲染快照测试（USkinRender vs Qt golden PNG）
//   Layer 3 — 解析逻辑 expect 测试（LOGFONT/position/color/bool）
//   Layer 4 — Metamorphic 测试（滑块数学性质、色键变形、位置解析独立性）
//   Playlist — TPlaylistModel 索引语义与显示辅助函数
//   WindowSnap — 窗口吸附几何 + MR-4 对称性
//   LRC / TTBL — 歌词解析与播放列表文件往返

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, consoletestrunner, UTestLayer2, UTestLayer3, UTestMetamorphic,
  UTestPlaylistModel, UTestWindowSnap, UTestLrcParser, UTestTtbl,
  UTestAlphaShape, UTestDpiScale, UTestTtcoreBackend;

var
  App: TTestRunner;
begin
  App := TTestRunner.Create(nil);
  App.Initialize;
  App.Title := 'TTPlayer Pascal tests';
  App.Run;
  App.Free;
end.
