unit UTestTracy;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, UTracy;

type
  TTracyTest = class(TTestCase)
  published
    procedure TestBuildModeGate;
    procedure TestNestedZones;
  end;

implementation

{$ifdef MSWINDOWS}
uses Windows;
{$endif}

procedure TTracyTest.TestBuildModeGate;
var
  Zone: TTracyZone;
begin
  Zone := TracyZoneBegin('Test.Tracy.BuildMode');
  try
    {$if defined(MSWINDOWS) and defined(ENABLE_TRACY)}
    if FileExists(ExtractFilePath(ExpandFileName(ParamStr(0))) + 'tttracy.dll') then
    begin
      AssertTrue('Profile must load the available shim', GetModuleHandle('tttracy.dll') <> 0);
      AssertTrue('Profile must use the current zone ABI', Zone <> 0);
    end
    else
      AssertTrue('Missing optional DLL must produce an empty zone', Zone = 0);
    {$else}
    AssertTrue('Disabled instrumentation must produce an empty zone', Zone = 0);
    {$ifdef MSWINDOWS}
    AssertTrue('Disabled instrumentation must not load a leftover DLL',
      GetModuleHandle('tttracy.dll') = 0);
    {$endif}
    {$endif}
  finally
    TracyZoneEnd(Zone);
  end;
end;

procedure TTracyTest.TestNestedZones;
const
  FrameName: PAnsiChar = 'Test.Tracy.Update';
var
  OuterZone, InnerZone: TTracyZone;
  Iteration: Integer;
begin
  for Iteration := 1 to 1000 do
  begin
    TracyFrameStart(FrameName);
    OuterZone := TracyZoneBegin(FrameName);
    try
      InnerZone := TracyZoneBegin('Test.Tracy.Render');
      try
        if OuterZone <> 0 then
          AssertTrue('Nested zones must retain independent contexts',
            (InnerZone <> 0) and (InnerZone <> OuterZone));
      finally
        TracyZoneEnd(InnerZone);
      end;
    finally
      TracyZoneEnd(OuterZone);
      TracyFrameEnd(FrameName);
    end;
  end;
  TracyZoneEnd(0);
end;

initialization
  RegisterTest(TTracyTest);
end.
