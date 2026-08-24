unit UPlaylistForm;

{$mode objfpc}{$H+}

// 播放列表窗口，对应 Qt 版 src/ui/PlaylistWindow。
// 无边框九宫格、虚拟列表、7 组工具栏、皮肤滚动条、外部拖放、双击 OpenFile。
// TTBL 读写、列表内拖放重排、搜索对话框、多播放列表标签页。
// 元数据加载器仍等 ttcore / TagLib。

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, StdCtrls,
  LCLIntf, LCLType, LMessages, LazUTF8, Math, Types,
  BGRABitmap, BGRABitmapTypes,
  USkinTypes, USkinRender, UPlayerBackend, UPlaylistModel, UPlaylistBook,
  UPlatformWindow, USkinView;

type
  TPlayFileEvent = procedure(Sender: TObject; const FilePath: string) of object;

  TPlaylistForm = class(TForm, ISkinViewForm)
  public
    constructor Create(AOwner: TComponent; ABackend: IPlayerBackend); reintroduce;
    destructor Destroy; override;

    procedure ApplySkin(ASkin: PSkinData);
    procedure RefreshViewScale;

    procedure AddEntry(const FilePath, Title, Artist: string; DurationMs: Int64);
    procedure Clear;
    procedure SetCurrentIndex(Index: Integer);
    function CurrentFile: string;
    procedure SetBounds(ALeft, ATop, AWidth, AHeight: Integer); override;
    procedure LoadFromTtblDir(const Dir: string; Count, ActiveList: Integer);
    function SaveToTtblDir(const Dir: string): Integer;

  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure DblClick; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure CreateWnd; override;
    procedure DoShow; override;

    procedure WMNCHitTest(var Msg: TLMessage); message LM_NCHITTEST;

  private
    FSkin: PSkinData;
    FBackend: IPlayerBackend;
    FFrame: TBGRABitmap;
    FBook: TPlaylistBook;
    FModel: TPlaylistModel;

    FLogicW, FLogicH: Integer;
    FRowHeight: Integer;

    FHoveredType: string;
    FPressedType: string;
    FHoveredToolbar: Integer;
    FPressedToolbar: Integer;

    FResizing: Boolean;
    FResizeEdgeRight: Boolean;
    FResizeEdgeBottom: Boolean;
    FResizeStartX, FResizeStartY, FResizeStartW, FResizeStartH: Integer;

    FDividerPos, FDividerSavedPos: Integer;
    FDividerDragging, FDividerHandlePressed: Boolean;
    FDividerDragStartX: Integer;

    FSelected: array of Boolean;
    FSelAnchor: Integer;
    FScroll: Integer;
    FFilter: string;
    FVisible: array of Integer;

    FSbButtons: array[0..1, 0..2] of TBGRABitmap;
    FSbDragging: Boolean;
    FSbDragOffset: Integer;
    FSbHoverPart: Integer;    // 0=top 1=bottom 2=thumb -1=none
    FSbPressedPart: Integer;

    FOnPlayFile: TPlayFileEvent;
    FSearchForm: TForm;
    FSearchEdit: TEdit;
    FDragRows: Boolean;
    FDragStart: TPoint;
    FDragSources: array of Integer;
    FDropVisIndex: Integer;
    FHoveredTab: Integer;

    FOnResizeInProgress: TNotifyEvent;
    FOnResizeFinished: TNotifyEvent;

    FMenu: TPopupMenu;

    procedure BuildRegion;
    procedure RenderFrame;
    procedure InvalidateFrame;
    procedure MapHit(var X, Y: Integer);
    procedure ApplyListFont;
    procedure RebuildVisible;
    procedure SyncSelectionLength;
    procedure ClampScroll;
    procedure EnsureSourceVisible(SourceIndex: Integer);

    function HitButton(PX, PY: Integer): string;
    function HitResizeEdge(PX, PY: Integer;
      out EdgeRight, EdgeBottom: Boolean): Boolean;
    function AlignedButtonX(const Elem: TSkinElement): Integer;

    function BgSize: TPoint;
    function ContentRect: TSkinRect;
    function ToolbarAreaRect: TSkinRect;
    function ToolbarGroupRect(Group: Integer): TSkinRect;
    function ToolbarGroupIndexAt(PX, PY: Integer): Integer;
    function ToolbarMenuAnchor(Group: Integer): TPoint;
    function DividerVisualRect: TSkinRect;
    function DividerHotZoneRect: TSkinRect;
    function DividerHandleRect: TSkinRect;
    function IsDividerCollapsed: Boolean;
    function ListRect: TSkinRect;
    function ScrollBarRect: TSkinRect;
    function ScrollBarWidth: Integer;
    function PtInSkinRect(PX, PY: Integer; const R: TSkinRect): Boolean;
    procedure ToggleDividerCollapsed;
    procedure ClampDividerPos;

    function VisibleCount: Integer;
    function VisibleRowsFit: Integer;
    function SourceOfVisible(VisIndex: Integer): Integer;
    function VisibleOfSource(SourceIndex: Integer): Integer;
    function RowAt(PX, PY: Integer): Integer;
    function ScrollMax: Integer;
    function NeedScrollBar: Boolean;

    function SbTopRect: TSkinRect;
    function SbBottomRect: TSkinRect;
    function SbTrackRect: TSkinRect;
    function SbThumbRect: TSkinRect;
    function SbHitPart(PX, PY: Integer): Integer;
    procedure SplitScrollButtons;
    procedure FreeScrollButtons;
    procedure SetScrollValue(Value: Integer);

    procedure DrawSplitterBar(const R: TSkinRect; Front, Back: TBGRAPixel);
    procedure DrawSplitterArrow(const R: TSkinRect; ArrowColor: TBGRAPixel;
      Collapsed: Boolean);
    procedure DrawToolbarGroups;
    procedure DrawListRows;
    procedure DrawTabs;
    function TabListRect: TSkinRect;
    function TabAt(PX, PY: Integer): Integer;
    procedure SyncActiveModel;
    procedure EnsureSearchDialog;
    procedure OnSearchEditChange(Sender: TObject);
    procedure OnSearchClose(Sender: TObject);
    procedure OnSearchFormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure OnNewTab(Sender: TObject);
    procedure OnRenameTab(Sender: TObject);
    procedure OnDeleteTab(Sender: TObject);
    procedure CollectDragSources;
    function InsertionVisIndex(PY: Integer): Integer;
    function GetTabCount: Integer;
    function GetActiveTabIndex: Integer;
    procedure DrawScrollBar;
    procedure DrawVTiled(Src: TBGRABitmap; const R: TSkinRect);
    procedure DrawVThreeSlice(Src: TBGRABitmap; const R: TSkinRect;
      ResizeCenter: Integer; TileCenter: Boolean);
    function ElideRight(const S: string; MaxW: Integer): string;

    procedure FireButtonClick(const AName: string);
    procedure FireToolbarClick(Group: Integer);
    procedure PlaySource(SourceIndex: Integer);
    procedure SelectRow(VisIndex: Integer; Shift: TShiftState);
    procedure ImportPathList(Files: TStrings);
    procedure CollectAudioFiles(const Path: string; Dest: TStrings);
    function IsAudioFile(const Path: string): Boolean;
    procedure HandleDropFiles(Sender: TObject; const FileNames: array of string);

    function AddMenuItem(const Cap: string; Handler: TNotifyEvent;
      ATag: Integer = 0): TMenuItem;
    procedure ShowAddMenu;
    procedure ShowDeleteMenu;
    procedure ShowListMenu;
    procedure ShowSortMenu;
    procedure ShowFindMenu;
    procedure ShowEditMenu;
    procedure ShowModeMenu;

    procedure OnAddFiles(Sender: TObject);
    procedure OnAddFolder(Sender: TObject);
    procedure OnRemoveSelected(Sender: TObject);
    procedure OnClearAll(Sender: TObject);
    procedure OnRemoveDupes(Sender: TObject);
    procedure OnRemoveInvalid(Sender: TObject);
    procedure OnLocateCurrent(Sender: TObject);
    procedure OnSortByName(Sender: TObject);
    procedure OnSortByTitle(Sender: TObject);
    procedure OnSortByPath(Sender: TObject);
    procedure OnSortRandom(Sender: TObject);
    procedure OnSortReverse(Sender: TObject);
    procedure OnPlaySelected(Sender: TObject);
    procedure OnFileProps(Sender: TObject);
    procedure OnSelectAll(Sender: TObject);
    procedure OnInvertSel(Sender: TObject);
    procedure OnClearSel(Sender: TObject);
    procedure OnMoveUp(Sender: TObject);
    procedure OnMoveDown(Sender: TObject);
    procedure OnModeClick(Sender: TObject);
  public
    property OnResizeInProgress: TNotifyEvent
      read FOnResizeInProgress write FOnResizeInProgress;
    property OnResizeFinished: TNotifyEvent
      read FOnResizeFinished write FOnResizeFinished;
    property ResizeEdgeRight: Boolean read FResizeEdgeRight;
    property ResizeEdgeBottom: Boolean read FResizeEdgeBottom;
    property OnPlayFile: TPlayFileEvent read FOnPlayFile write FOnPlayFile;
    property TabCount: Integer read GetTabCount;
    property ActiveTabIndex: Integer read GetActiveTabIndex;
  end;

implementation

uses
  UFormSnap, UDpiScale;

const
  kResizeSense              = 8;
  kPlaylistMinW             = 200;
  kPlaylistMinH             = 80;
  kToolbarGroupCount        = 7;
  kDividerWidth             = 5;
  kDividerHandleHalfH       = 7;
  kDividerMinExpandedPos    = 20;
  kDividerCollapseThreshold = 6;
  kDefaultDividerPos        = 55;
  kDividerHotPad            = 6;
  kAudioExts: array[0..7] of string = (
    '.mp3', '.flac', '.ogg', '.wav', '.aac', '.m4a', '.wma', '.ape');

{ TPlaylistForm }

constructor TPlaylistForm.Create(AOwner: TComponent; ABackend: IPlayerBackend);
begin
  inherited CreateNew(AOwner);

  FSkin    := nil;
  FBackend := ABackend;
  FFrame   := nil;
  FBook    := TPlaylistBook.Create;
  FModel   := FBook.ActiveModel;

  FLogicW := 268;
  FLogicH := 165;
  FRowHeight := 16;

  FHoveredType     := '';
  FPressedType     := '';
  FHoveredToolbar  := -1;
  FPressedToolbar  := -1;
  FResizing        := False;

  FDividerPos           := kDefaultDividerPos;
  FDividerSavedPos      := kDefaultDividerPos;
  FDividerDragging      := False;
  FDividerHandlePressed := False;

  FSelAnchor := -1;
  FScroll := 0;
  FFilter := '';
  FSbHoverPart := -1;
  FSbPressedPart := -1;
  FSbDragging := False;
  FDragRows := False;
  FDropVisIndex := -1;
  FHoveredTab := -1;
  FSearchForm := nil;
  FSearchEdit := nil;

  FMenu := TPopupMenu.Create(Self);

  BorderStyle := bsNone;
  FormStyle   := fsNormal;
  Color       := clBlack;
  Caption     := 'Playlist';
  AllowDropFiles := True;
  OnDropFiles := @HandleDropFiles;

  MouseLeave;
end;

destructor TPlaylistForm.Destroy;
begin
  FreeScrollButtons;
  FreeAndNil(FFrame);
  FModel := nil;
  FreeAndNil(FBook);
  inherited Destroy;
end;

procedure TPlaylistForm.ApplySkin(ASkin: PSkinData);
var
  bg: TBGRABitmap;
  dp: TSkinRect;
begin
  if ASkin = nil then Exit;
  FSkin := ASkin;
  ConfigurePlatformWindow(Self);

  if HandleAllocated then
    ClearWindowShape(Handle);

  bg := ASkin^.PlaylistWindow.BackgroundPixmap;
  dp := ASkin^.PlaylistWindow.DefaultPosition;
  if bg <> nil then
  begin
    if (dp.W > 0) and (dp.H > 0) then
    begin
      FLogicW := dp.W;
      FLogicH := dp.H;
    end
    else
    begin
      FLogicW := bg.Width;
      FLogicH := bg.Height;
    end;
    ApplySkinFormSize(Self, FLogicW, FLogicH);
  end;

  SplitScrollButtons;
  ClampDividerPos;
  RebuildVisible;
  InvalidateFrame;
  if HandleAllocated then
    BuildRegion;
  if HandleAllocated then
    Update;
end;

procedure TPlaylistForm.SetBounds(ALeft, ATop, AWidth, AHeight: Integer);
var
  sizeChanged: Boolean;
  s: Double;
begin
  sizeChanged := (AWidth <> Width) or (AHeight <> Height);
  inherited SetBounds(ALeft, ATop, AWidth, AHeight);
  if sizeChanged and (FSkin <> nil) then
  begin
    s := FormViewScale(Self);
    if s < 0.01 then s := 1.0;
    FLogicW := Max(1, Round(Width / s));
    FLogicH := Max(1, Round(Height / s));
    ClampDividerPos;
    ClampScroll;
    FreeAndNil(FFrame);
    if HandleAllocated then
      BuildRegion;
    Invalidate;
  end;
end;

procedure TPlaylistForm.MapHit(var X, Y: Integer);
begin
  ClientToSkinXY(Self, FLogicW, FLogicH, X, Y);
end;

procedure TPlaylistForm.RefreshViewScale;
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

procedure TPlaylistForm.BuildRegion;
var
  src, bmp: TBGRABitmap;
  own: Boolean;
begin
  if (FSkin = nil) or (not HandleAllocated) then Exit;
  src := FSkin^.PlaylistWindow.BackgroundPixmap;
  if src = nil then Exit;

  own := False;
  if (src.Width = FLogicW) and (src.Height = FLogicH) then
    bmp := src
  else
  begin
    bmp := TBGRABitmap.Create(FLogicW, FLogicH, BGRAPixelTransparent);
    own := True;
    DrawNinePatch(bmp, src, FSkin^.PlaylistWindow.ResizeRect,
      FSkin^.PlaylistWindow.ResizeTile, FLogicW, FLogicH, True);
  end;
  try
    ApplyAlphaShape(Handle, bmp);
  finally
    if own then bmp.Free;
  end;
end;

procedure TPlaylistForm.CreateWnd;
begin
  inherited CreateWnd;
  ConfigurePlatformWindow(Self);
  RefreshViewScale;
end;

procedure TPlaylistForm.DoShow;
begin
  inherited DoShow;
  ConfigurePlatformWindow(Self);
  RefreshViewScale;
  BuildRegion;
end;

procedure TPlaylistForm.InvalidateFrame;
begin
  FreeAndNil(FFrame);
  RenderFrame;
  Invalidate;
end;

function TPlaylistForm.BgSize: TPoint;
begin
  Result := Point(FLogicW, FLogicH);
  if (FSkin <> nil) and (FSkin^.PlaylistWindow.BackgroundPixmap <> nil) then
  begin
    Result.X := FSkin^.PlaylistWindow.BackgroundPixmap.Width;
    Result.Y := FSkin^.PlaylistWindow.BackgroundPixmap.Height;
  end;
end;

function TPlaylistForm.AlignedButtonX(const Elem: TSkinElement): Integer;
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
  baseW := BgSize.X;
  rightMargin := baseW - (Elem.Position.X + Elem.Position.W);
  btnW := ButtonBounds(Elem).W;
  Result := FLogicW - rightMargin - btnW;
end;

function TPlaylistForm.ContentRect: TSkinRect;
begin
  if FSkin = nil then
  begin
    Result.X := 4; Result.Y := 50;
    Result.W := Max(1, FLogicW - 8);
    Result.H := Max(1, FLogicH - 74);
  end
  else
    Result := PlaylistContentRect(FSkin^, FLogicW, FLogicH);
end;

function TPlaylistForm.ToolbarAreaRect: TSkinRect;
var
  elem: PSkinElement;
  sz: TPoint;
begin
  Result := TSkinRect.Zero;
  if FSkin = nil then Exit;
  elem := FSkin^.PlaylistWindow.FindElement('toolbar');
  if elem = nil then Exit;
  sz := BgSize;
  Result := AlignedRect(elem^.Position, sz.X, sz.Y, FLogicW, FLogicH,
    elem^.Align, elem^.Position.W, elem^.Position.H);
end;

function TPlaylistForm.ToolbarGroupRect(Group: Integer): TSkinRect;
var
  tb: TSkinRect;
  gLeft, gRight: Integer;
begin
  Result := TSkinRect.Zero;
  if (Group < 0) or (Group >= kToolbarGroupCount) then Exit;
  tb := ToolbarAreaRect;
  if tb.IsEmpty then Exit;
  gLeft  := tb.X + (tb.W * Group)       div kToolbarGroupCount;
  gRight := tb.X + (tb.W * (Group + 1)) div kToolbarGroupCount;
  Result.X := gLeft;
  Result.Y := tb.Y;
  Result.W := Max(1, gRight - gLeft);
  Result.H := tb.H;
end;

function TPlaylistForm.ToolbarGroupIndexAt(PX, PY: Integer): Integer;
var
  tb: TSkinRect;
  relX: Integer;
begin
  Result := -1;
  tb := ToolbarAreaRect;
  if tb.IsEmpty or not PtInSkinRect(PX, PY, tb) then Exit;
  relX := PX - tb.X;
  Result := (relX * kToolbarGroupCount) div Max(1, tb.W);
  if (Result < 0) or (Result >= kToolbarGroupCount) then
    Result := -1;
end;

function TPlaylistForm.ToolbarMenuAnchor(Group: Integer): TPoint;
var
  r: TSkinRect;
  x, y: Integer;
begin
  r := ToolbarGroupRect(Group);
  if r.IsEmpty then
    Result := Mouse.CursorPos
  else
  begin
    x := r.X;
    y := r.Y + r.H;
    SkinToClientXY(Self, FLogicW, FLogicH, x, y);
    Result := ClientToScreen(Point(x, y));
  end;
end;

function TPlaylistForm.PtInSkinRect(PX, PY: Integer; const R: TSkinRect): Boolean;
begin
  Result := (not R.IsEmpty) and
            (PX >= R.X) and (PX < R.X + R.W) and
            (PY >= R.Y) and (PY < R.Y + R.H);
end;

function TPlaylistForm.IsDividerCollapsed: Boolean;
begin
  Result := FDividerPos <= 0;
end;

function TPlaylistForm.DividerVisualRect: TSkinRect;
var
  pl: TSkinRect;
begin
  Result := TSkinRect.Zero;
  pl := ContentRect;
  if pl.IsEmpty then Exit;
  Result.X := pl.X;
  if not IsDividerCollapsed then
    Inc(Result.X, FDividerPos);
  Result.Y := pl.Y;
  Result.W := kDividerWidth;
  Result.H := pl.H;
end;

function TPlaylistForm.DividerHotZoneRect: TSkinRect;
begin
  Result := DividerVisualRect;
  if Result.IsEmpty then Exit;
  Result.X := Result.X - kDividerHotPad;
  Result.W := Result.W + 2 * kDividerHotPad;
end;

function TPlaylistForm.DividerHandleRect: TSkinRect;
var
  vis: TSkinRect;
  cy: Integer;
begin
  Result := TSkinRect.Zero;
  vis := DividerVisualRect;
  if vis.IsEmpty then Exit;
  cy := vis.Y + vis.H div 2;
  Result.X := vis.X;
  Result.Y := cy - kDividerHandleHalfH;
  Result.W := vis.W;
  Result.H := 2 * kDividerHandleHalfH + 1;
end;

procedure TPlaylistForm.ClampDividerPos;
var
  pl: TSkinRect;
  maxPos: Integer;
begin
  pl := ContentRect;
  maxPos := Max(0, pl.W - kDividerWidth - 24);
  if FDividerPos > 0 then
    FDividerPos := Min(Max(FDividerPos, kDividerMinExpandedPos), maxPos);
  if FDividerSavedPos > 0 then
    FDividerSavedPos := Min(Max(FDividerSavedPos, kDividerMinExpandedPos),
      Max(kDividerMinExpandedPos, maxPos));
end;

procedure TPlaylistForm.ToggleDividerCollapsed;
begin
  if IsDividerCollapsed then
    FDividerPos := Max(kDividerMinExpandedPos, FDividerSavedPos)
  else
  begin
    FDividerSavedPos := FDividerPos;
    FDividerPos := 0;
  end;
  ClampDividerPos;
  InvalidateFrame;
end;

function TPlaylistForm.ScrollBarWidth: Integer;
var
  elem: PSkinElement;
  w: Integer;
begin
  Result := 0;
  if FSkin = nil then Exit;
  elem := FSkin^.PlaylistWindow.FindElement('scrollbar');
  if (elem = nil) or (elem^.ButtonsPixmap = nil) then Exit;
  Result := 8;
  if FSbButtons[0, 0] <> nil then
    Result := Max(Result, FSbButtons[0, 0].Width);
  if FSbButtons[1, 0] <> nil then
    Result := Max(Result, FSbButtons[1, 0].Width);
  if elem^.BarPixmap <> nil then
    Result := Max(Result, elem^.BarPixmap.Width);
  if elem^.ThumbPixmaps[0] <> nil then
    Result := Max(Result, elem^.ThumbPixmaps[0].Width);
  w := Result;
  Result := w;
end;

function TPlaylistForm.NeedScrollBar: Boolean;
begin
  Result := (ScrollBarWidth > 0) and (VisibleCount > VisibleRowsFit);
end;

function TPlaylistForm.ListRect: TSkinRect;
var
  pl, vis: TSkinRect;
  sbW: Integer;
begin
  Result := TSkinRect.Zero;
  pl := ContentRect;
  vis := DividerVisualRect;
  if pl.IsEmpty then Exit;
  Result.X := vis.X + vis.W;
  Result.Y := pl.Y;
  sbW := 0;
  if NeedScrollBar then sbW := ScrollBarWidth;
  Result.W := Max(0, pl.X + pl.W - Result.X - sbW);
  Result.H := pl.H;
end;

function TPlaylistForm.ScrollBarRect: TSkinRect;
var
  pl: TSkinRect;
  sbW: Integer;
begin
  Result := TSkinRect.Zero;
  if not NeedScrollBar then Exit;
  pl := ContentRect;
  sbW := ScrollBarWidth;
  Result.X := pl.X + pl.W - sbW;
  Result.Y := pl.Y;
  Result.W := sbW;
  Result.H := pl.H;
end;

function TPlaylistForm.VisibleCount: Integer;
begin
  Result := Length(FVisible);
end;

function TPlaylistForm.VisibleRowsFit: Integer;
var
  pl: TSkinRect;
begin
  // 用内容区高度，避免 ListRect ↔ NeedScrollBar 循环依赖。
  pl := ContentRect;
  if FRowHeight <= 0 then FRowHeight := 16;
  Result := Max(1, pl.H div FRowHeight);
end;

function TPlaylistForm.SourceOfVisible(VisIndex: Integer): Integer;
begin
  if (VisIndex < 0) or (VisIndex >= Length(FVisible)) then Exit(-1);
  Result := FVisible[VisIndex];
end;

function TPlaylistForm.VisibleOfSource(SourceIndex: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FVisible) do
    if FVisible[i] = SourceIndex then Exit(i);
  Result := -1;
end;

function TPlaylistForm.RowAt(PX, PY: Integer): Integer;
var
  lr: TSkinRect;
begin
  Result := -1;
  lr := ListRect;
  if not PtInSkinRect(PX, PY, lr) then Exit;
  if FRowHeight <= 0 then Exit;
  Result := FScroll + (PY - lr.Y) div FRowHeight;
  if (Result < 0) or (Result >= VisibleCount) then Result := -1;
end;

function TPlaylistForm.ScrollMax: Integer;
begin
  Result := Max(0, VisibleCount - VisibleRowsFit);
end;

procedure TPlaylistForm.ClampScroll;
begin
  if FScroll < 0 then FScroll := 0;
  if FScroll > ScrollMax then FScroll := ScrollMax;
end;

procedure TPlaylistForm.SetScrollValue(Value: Integer);
begin
  if Value < 0 then Value := 0;
  if Value > ScrollMax then Value := ScrollMax;
  if Value <> FScroll then
  begin
    FScroll := Value;
    InvalidateFrame;
  end;
end;

procedure TPlaylistForm.EnsureSourceVisible(SourceIndex: Integer);
var
  vis: Integer;
begin
  vis := VisibleOfSource(SourceIndex);
  if vis < 0 then Exit;
  if vis < FScroll then
    FScroll := vis
  else if vis >= FScroll + VisibleRowsFit then
    FScroll := vis - VisibleRowsFit + 1;
  ClampScroll;
end;

procedure TPlaylistForm.SyncSelectionLength;
var
  oldLen, i: Integer;
begin
  oldLen := Length(FSelected);
  SetLength(FSelected, FModel.Count);
  for i := oldLen to High(FSelected) do
    FSelected[i] := False;
end;

procedure TPlaylistForm.RebuildVisible;
var
  i: Integer;
  e: TPlaylistEntry;
  needle, hay: string;
begin
  SetLength(FVisible, 0);
  if FModel = nil then Exit;
  needle := UTF8LowerCase(Trim(FFilter));
  for i := 0 to FModel.Count - 1 do
  begin
    if needle <> '' then
    begin
      e := FModel.Entries[i];
      hay := UTF8LowerCase(DisplayTitleForEntry(e) + ' ' + e.FilePath);
      if Pos(needle, hay) = 0 then Continue;
    end;
    SetLength(FVisible, Length(FVisible) + 1);
    FVisible[High(FVisible)] := i;
  end;
  ClampScroll;
end;

procedure TPlaylistForm.ApplyListFont;
var
  f: TSkinFont;
  st: TFontStyles;
begin
  if (FFrame = nil) or (FSkin = nil) then Exit;
  f := FSkin^.PlaylistConfig.Font;
  if f.Family <> '' then
    FFrame.FontName := f.Family
  else
    FFrame.FontName := 'SimSun';
  if f.PixelSize > 0 then
    FFrame.FontHeight := f.PixelSize
  else
    FFrame.FontHeight := 12;
  st := [];
  if f.Bold then Include(st, fsBold);
  if f.Italic then Include(st, fsItalic);
  FFrame.FontStyle := st;
  FFrame.FontAntialias := True;
  FRowHeight := FFrame.TextSize('Ag').cy + 4;
  if FRowHeight < 14 then FRowHeight := 14;
end;

procedure TPlaylistForm.FreeScrollButtons;
var
  r, c: Integer;
begin
  for r := 0 to 1 do
    for c := 0 to 2 do
      FreeAndNil(FSbButtons[r, c]);
end;

procedure TPlaylistForm.SplitScrollButtons;
var
  elem: PSkinElement;
  sheet: TBGRABitmap;
  cw, ch, row, col: Integer;
begin
  FreeScrollButtons;
  if FSkin = nil then Exit;
  elem := FSkin^.PlaylistWindow.FindElement('scrollbar');
  if (elem = nil) or (elem^.ButtonsPixmap = nil) then Exit;
  sheet := elem^.ButtonsPixmap;
  if (sheet.Width < 3) or (sheet.Height < 2) then Exit;
  cw := sheet.Width div 3;
  ch := sheet.Height div 2;
  if (cw <= 0) or (ch <= 0) then Exit;
  for row := 0 to 1 do
    for col := 0 to 2 do
      FSbButtons[row, col] := sheet.GetPart(
        Classes.Rect(col * cw, row * ch, (col + 1) * cw, (row + 1) * ch));
end;

function TPlaylistForm.SbTopRect: TSkinRect;
var
  bar: TSkinRect;
  w, h: Integer;
begin
  Result := TSkinRect.Zero;
  bar := ScrollBarRect;
  if bar.IsEmpty then Exit;
  w := bar.W; h := 0;
  if FSbButtons[0, 0] <> nil then
  begin
    w := FSbButtons[0, 0].Width;
    h := FSbButtons[0, 0].Height;
  end;
  Result.X := bar.X + (bar.W - w) div 2;
  Result.Y := bar.Y;
  Result.W := w;
  Result.H := h;
end;

function TPlaylistForm.SbBottomRect: TSkinRect;
var
  bar: TSkinRect;
  w, h: Integer;
begin
  Result := TSkinRect.Zero;
  bar := ScrollBarRect;
  if bar.IsEmpty then Exit;
  w := bar.W; h := 0;
  if FSbButtons[1, 0] <> nil then
  begin
    w := FSbButtons[1, 0].Width;
    h := FSbButtons[1, 0].Height;
  end;
  Result.X := bar.X + (bar.W - w) div 2;
  Result.Y := bar.Y + bar.H - h;
  Result.W := w;
  Result.H := h;
end;

function TPlaylistForm.SbTrackRect: TSkinRect;
var
  bar, topR, botR: TSkinRect;
begin
  Result := TSkinRect.Zero;
  bar := ScrollBarRect;
  if bar.IsEmpty then Exit;
  topR := SbTopRect;
  botR := SbBottomRect;
  Result.X := bar.X;
  Result.Y := bar.Y + topR.H;
  Result.W := bar.W;
  Result.H := Max(0, bar.H - topR.H - botR.H);
end;

function TPlaylistForm.SbThumbRect: TSkinRect;
var
  track: TSkinRect;
  elem: PSkinElement;
  thumb: TBGRABitmap;
  baseH, propH, avail, y, tw: Integer;
  ratio: Double;
begin
  Result := TSkinRect.Zero;
  track := SbTrackRect;
  if track.IsEmpty then Exit;
  elem := nil;
  thumb := nil;
  tw := track.W;
  baseH := 12;
  if FSkin <> nil then
  begin
    elem := FSkin^.PlaylistWindow.FindElement('scrollbar');
    if elem <> nil then
    begin
      thumb := elem^.ThumbPixmaps[0];
      if thumb = nil then thumb := elem^.ThumbPixmaps[1];
      if thumb <> nil then
      begin
        baseH := thumb.Height;
        tw := thumb.Width;
      end;
    end;
  end;
  if ScrollMax <= 0 then
    propH := Min(track.H, baseH)
  else
    propH := Min(track.H, Max(baseH, track.H * VisibleRowsFit div
      Max(1, VisibleCount)));
  avail := Max(0, track.H - propH);
  y := track.Y;
  if (ScrollMax > 0) and (avail > 0) then
  begin
    ratio := FScroll / ScrollMax;
    y := y + Trunc(ratio * avail);
  end;
  Result.X := track.X + (track.W - tw) div 2;
  Result.Y := y;
  Result.W := tw;
  Result.H := propH;
end;

function TPlaylistForm.SbHitPart(PX, PY: Integer): Integer;
begin
  Result := -1;
  if not NeedScrollBar then Exit;
  if PtInSkinRect(PX, PY, SbTopRect) then Exit(0);
  if PtInSkinRect(PX, PY, SbBottomRect) then Exit(1);
  if PtInSkinRect(PX, PY, SbThumbRect) then Exit(2);
  if PtInSkinRect(PX, PY, SbTrackRect) then
  begin
    if PY < SbThumbRect.Y then Exit(3);  // page up
    Exit(4);                              // page down
  end;
end;

procedure TPlaylistForm.DrawVTiled(Src: TBGRABitmap; const R: TSkinRect);
var
  y, dh: Integer;
  part: TBGRABitmap;
begin
  if (Src = nil) or (R.W <= 0) or (R.H <= 0) then Exit;
  y := R.Y;
  while y < R.Y + R.H do
  begin
    dh := Min(Src.Height, R.Y + R.H - y);
    if dh < Src.Height then
      part := Src.GetPart(Classes.Rect(0, 0, Src.Width, dh))
    else
      part := Src;
    try
      FFrame.PutImage(R.X + (R.W - Src.Width) div 2, y, part, dmDrawWithTransparency);
    finally
      if part <> Src then part.Free;
    end;
    Inc(y, Src.Height);
  end;
end;

procedure TPlaylistForm.DrawVThreeSlice(Src: TBGRABitmap; const R: TSkinRect;
  ResizeCenter: Integer; TileCenter: Boolean);
var
  fixedTop, fixedBottom: Integer;
  topBmp, midBmp, botBmp: TBGRABitmap;
  midR: TSkinRect;
begin
  if (Src = nil) or (R.W <= 0) or (R.H <= 0) then Exit;
  if (ResizeCenter <= 0) or (Src.Height <= ResizeCenter) or (R.H <= Src.Height) then
  begin
    FFrame.StretchPutImage(Classes.Rect(R.X, R.Y, R.X + R.W, R.Y + R.H),
      Src, dmDrawWithTransparency);
    Exit;
  end;
  fixedTop := (Src.Height - ResizeCenter) div 2;
  fixedBottom := Src.Height - fixedTop - ResizeCenter;
  topBmp := Src.GetPart(Classes.Rect(0, 0, Src.Width, fixedTop));
  midBmp := Src.GetPart(Classes.Rect(0, fixedTop, Src.Width, fixedTop + ResizeCenter));
  botBmp := Src.GetPart(Classes.Rect(0, Src.Height - fixedBottom, Src.Width, Src.Height));
  try
    if (topBmp <> nil) and (fixedTop > 0) then
      FFrame.PutImage(R.X, R.Y, topBmp, dmDrawWithTransparency);
    if (botBmp <> nil) and (fixedBottom > 0) then
      FFrame.PutImage(R.X, R.Y + R.H - fixedBottom, botBmp, dmDrawWithTransparency);
    midR.X := R.X;
    midR.Y := R.Y + fixedTop;
    midR.W := R.W;
    midR.H := Max(0, R.H - fixedTop - fixedBottom);
    if (midBmp <> nil) and (midR.H > 0) then
    begin
      if TileCenter then
        DrawVTiled(midBmp, midR)
      else
        FFrame.StretchPutImage(Classes.Rect(midR.X, midR.Y, midR.X + midR.W, midR.Y + midR.H),
          midBmp, dmDrawWithTransparency);
    end;
  finally
    topBmp.Free;
    midBmp.Free;
    botBmp.Free;
  end;
end;

procedure TPlaylistForm.DrawScrollBar;
var
  elem: PSkinElement;
  topR, botR, track, thumb: TSkinRect;
  btn: TBGRABitmap;
  state: Integer;
  barRect: TSkinRect;
begin
  if not NeedScrollBar then Exit;
  elem := FSkin^.PlaylistWindow.FindElement('scrollbar');
  if elem = nil then Exit;

  topR := SbTopRect;
  botR := SbBottomRect;
  track := SbTrackRect;
  thumb := SbThumbRect;

  if (elem^.BarPixmap <> nil) and (not track.IsEmpty) then
  begin
    barRect := track;
    barRect.W := elem^.BarPixmap.Width;
    barRect.X := track.X + (track.W - barRect.W) div 2;
    DrawVTiled(elem^.BarPixmap, barRect);
  end;

  if FSbPressedPart = 0 then state := 2
  else if FSbHoverPart = 0 then state := 1
  else state := 0;
  btn := FSbButtons[0, state];
  if btn = nil then btn := FSbButtons[0, 0];
  if (btn <> nil) and (not topR.IsEmpty) then
    FFrame.PutImage(topR.X, topR.Y, btn, dmDrawWithTransparency);

  if FSbPressedPart = 1 then state := 2
  else if FSbHoverPart = 1 then state := 1
  else state := 0;
  btn := FSbButtons[1, state];
  if btn = nil then btn := FSbButtons[1, 0];
  if (btn <> nil) and (not botR.IsEmpty) then
    FFrame.PutImage(botR.X, botR.Y, btn, dmDrawWithTransparency);

  if not thumb.IsEmpty then
  begin
    if FSbDragging then state := 2
    else if FSbHoverPart = 2 then state := 1
    else state := 0;
    btn := elem^.ThumbPixmaps[state];
    if btn = nil then btn := elem^.ThumbPixmaps[0];
    if btn <> nil then
      DrawVThreeSlice(btn, thumb, elem^.ThumbResizeCenter, elem^.ThumbResizeTile);
  end;
end;

function TPlaylistForm.ElideRight(const S: string; MaxW: Integer): string;
begin
  Result := S;
  if (FFrame = nil) or (MaxW <= 0) then Exit;
  if FFrame.TextSize(Result).cx <= MaxW then Exit;
  while (UTF8Length(Result) > 0) and
        (FFrame.TextSize(Result + '...').cx > MaxW) do
    UTF8Delete(Result, UTF8Length(Result), 1);
  Result := Result + '...';
end;

procedure TPlaylistForm.DrawListRows;
var
  lr: TSkinRect;
  vis, src, y, hPad, numW, durW, gap, playW, crL, crR: Integer;
  e: TPlaylistEntry;
  selected, playing: Boolean;
  bg, bg2, selC, textC, hiC, numC, durC, rowBg, useC: TBGRAPixel;
  number, title, duration: string;
  plElem: PSkinElement;
  markerH: Integer;
begin
  lr := ListRect;
  if (lr.W <= 0) or (lr.H <= 0) or (FSkin = nil) then Exit;

  ApplyListFont;
  FFrame.ClipRect := Classes.Rect(lr.X, lr.Y, lr.X + lr.W, lr.Y + lr.H);

  bg   := FSkin^.PlaylistConfig.ColorBkgnd.ToBGRA;
  bg2  := FSkin^.PlaylistConfig.ColorBkgnd2.ToBGRA;
  selC := FSkin^.PlaylistConfig.ColorSelect.ToBGRA;
  textC:= FSkin^.PlaylistConfig.ColorText.ToBGRA;
  hiC  := FSkin^.PlaylistConfig.ColorHilight.ToBGRA;
  numC := FSkin^.PlaylistConfig.ColorNumber.ToBGRA;
  durC := FSkin^.PlaylistConfig.ColorDuration.ToBGRA;
  if not FSkin^.PlaylistConfig.ColorBkgnd.Valid then bg := BGRA(0, 0, 0);
  if not FSkin^.PlaylistConfig.ColorBkgnd2.Valid then bg2 := BGRA($20, $20, $20);
  if not FSkin^.PlaylistConfig.ColorSelect.Valid then selC := BGRA($32, $69, $C8);
  if not FSkin^.PlaylistConfig.ColorText.Valid then textC := BGRA($00, $80, $FF);
  if not FSkin^.PlaylistConfig.ColorHilight.Valid then hiC := BGRA($00, $FF, $00);
  if not FSkin^.PlaylistConfig.ColorNumber.Valid then numC := BGRA($00, $80, $00);
  if not FSkin^.PlaylistConfig.ColorDuration.Valid then durC := BGRA($C0, $80, $20);

  plElem := FSkin^.PlaylistWindow.FindElement('playlist');
  hPad := 4;

  for vis := FScroll to Min(VisibleCount, FScroll + VisibleRowsFit + 1) - 1 do
  begin
    src := SourceOfVisible(vis);
    if src < 0 then Continue;
    y := lr.Y + (vis - FScroll) * FRowHeight;
    if y >= lr.Y + lr.H then Break;

    selected := (src < Length(FSelected)) and FSelected[src];
    playing  := src = FModel.CurrentIndex;
    if vis mod 2 = 0 then rowBg := bg else rowBg := bg2;

    if selected then
    begin
      if (plElem <> nil) and (plElem^.SelectedPixmap <> nil) then
        FFrame.StretchPutImage(Classes.Rect(lr.X, y, lr.X + lr.W, y + FRowHeight),
          plElem^.SelectedPixmap, dmSet)
      else
        FFrame.GradientFill(lr.X, y, lr.X + lr.W, y + FRowHeight,
          rowBg, selC, gtLinear, PointF(lr.X, y), PointF(lr.X, y + FRowHeight),
          dmSet, False);
    end
    else
      FFrame.FillRect(lr.X, y, lr.X + lr.W, y + FRowHeight, rowBg, dmSet);

    e := FModel.Entries[src];
    number := IntToStr(src + 1);
    title := DisplayTitleForEntry(e);
    duration := DisplayDurationForEntry(e);

    crL := lr.X + hPad;
    crR := lr.X + lr.W - hPad;

    if playing then
    begin
      markerH := Min(6, FRowHeight - 4);
      FFrame.FillPolyAntialias(
        [PointF(crL + 2, y + (FRowHeight - markerH) / 2),
         PointF(crL + 2, y + (FRowHeight + markerH) / 2),
         PointF(crL + 2 + markerH, y + FRowHeight / 2)],
        hiC);
      Inc(crL, markerH + 6);
    end;

    if selected or playing then useC := hiC else useC := durC;
    durW := 0;
    if duration <> '' then
    begin
      durW := FFrame.TextSize(duration).cx;
      FFrame.TextOut(crR - durW, y + (FRowHeight - FFrame.TextSize(duration).cy) div 2,
        duration, useC);
    end;

    if selected or playing then useC := hiC else useC := numC;
    number := number + ' ';
    numW := FFrame.TextSize(number).cx;
    FFrame.TextOut(crL, y + (FRowHeight - FFrame.TextSize(number).cy) div 2,
      number, useC);

    if selected or playing then useC := hiC else useC := textC;
    gap := 0;
    if durW > 0 then gap := FFrame.TextSize('  ').cx;
    playW := Max(1, (crR - durW - gap) - (crL + numW));
    title := ElideRight(title, playW);
    FFrame.TextOut(crL + numW, y + (FRowHeight - FFrame.TextSize(title).cy) div 2,
      title, useC);
  end;

  FFrame.NoClip;

  if FDragRows and (FDropVisIndex >= 0) then
  begin
    y := lr.Y + (FDropVisIndex - FScroll) * FRowHeight;
    if (y >= lr.Y) and (y <= lr.Y + lr.H) then
      FFrame.FillRect(lr.X, y, lr.X + lr.W, y + 2, hiC, dmSet);
  end;
end;

function TPlaylistForm.TabListRect: TSkinRect;
var
  pl, vis: TSkinRect;
begin
  Result := TSkinRect.Zero;
  pl := ContentRect;
  vis := DividerVisualRect;
  if pl.IsEmpty or IsDividerCollapsed then Exit;
  Result.X := pl.X;
  Result.Y := pl.Y;
  Result.W := Max(0, vis.X - pl.X);
  Result.H := pl.H;
end;

function TPlaylistForm.TabAt(PX, PY: Integer): Integer;
var
  r: TSkinRect;
begin
  Result := -1;
  r := TabListRect;
  if not PtInSkinRect(PX, PY, r) then Exit;
  if FRowHeight <= 0 then Exit;
  Result := (PY - r.Y) div FRowHeight;
  if (Result < 0) or (Result >= FBook.TabCount) then
    Result := -1;
end;

procedure TPlaylistForm.DrawTabs;
var
  r: TSkinRect;
  i, y, tw: Integer;
  tabName: string;
  textC, hiC, selC: TBGRAPixel;
begin
  r := TabListRect;
  if (r.W <= 0) or (r.H <= 0) or (FFrame = nil) or (FBook = nil) then Exit;
  ApplyListFont;
  FFrame.ClipRect := Classes.Rect(r.X, r.Y, r.X + r.W, r.Y + r.H);
  if (FSkin <> nil) and FSkin^.PlaylistConfig.ColorText.Valid then
    textC := FSkin^.PlaylistConfig.ColorText.ToBGRA
  else
    textC := BGRA($00, $80, $FF);
  if (FSkin <> nil) and FSkin^.PlaylistConfig.ColorHilight.Valid then
    hiC := FSkin^.PlaylistConfig.ColorHilight.ToBGRA
  else
    hiC := BGRA($00, $FF, $00);
  if (FSkin <> nil) and FSkin^.PlaylistConfig.ColorSelect.Valid then
    selC := FSkin^.PlaylistConfig.ColorSelect.ToBGRA
  else
    selC := BGRA($32, $69, $C8);
  for i := 0 to FBook.TabCount - 1 do
  begin
    y := r.Y + i * FRowHeight;
    if y >= r.Y + r.H then Break;
    if i = FBook.ActiveIndex then
      FFrame.FillRect(r.X, y, r.X + r.W, y + FRowHeight, selC, dmSet)
    else if i = FHoveredTab then
      FFrame.FillRect(r.X, y, r.X + r.W, y + FRowHeight,
        BGRA(selC.red, selC.green, selC.blue, 80), dmDrawWithTransparency);
    tabName := FBook.Tabs[i].Name;
    tabName := ElideRight(tabName, Max(1, r.W - 8));
    tw := FFrame.TextSize(tabName).cx;
    if i = FBook.ActiveIndex then
      FFrame.TextOut(r.X + 4, y + (FRowHeight - FFrame.TextSize(tabName).cy) div 2,
        tabName, hiC)
    else
      FFrame.TextOut(r.X + 4, y + (FRowHeight - FFrame.TextSize(tabName).cy) div 2,
        tabName, textC);
    if tw = 0 then ;
  end;
  FFrame.NoClip;
end;

procedure TPlaylistForm.SyncActiveModel;
begin
  FModel := FBook.ActiveModel;
  SyncSelectionLength;
  RebuildVisible;
  FScroll := 0;
  ClampScroll;
  InvalidateFrame;
end;

function TPlaylistForm.GetTabCount: Integer;
begin
  if FBook = nil then Result := 0 else Result := FBook.TabCount;
end;

function TPlaylistForm.GetActiveTabIndex: Integer;
begin
  if FBook = nil then Result := 0 else Result := FBook.ActiveIndex;
end;

procedure TPlaylistForm.DrawSplitterBar(const R: TSkinRect; Front, Back: TBGRAPixel);
var
  x, totalW, frontW, backW: Integer;
  mix: TBGRAPixel;
begin
  if (R.W <= 0) or (R.H <= 0) or (FFrame = nil) then Exit;
  FFrame.FillRect(R.X, R.Y, R.X + R.W, R.Y + 1, Front, dmSet);
  if R.H > 1 then
    FFrame.FillRect(R.X, R.Y + R.H - 1, R.X + R.W, R.Y + R.H, Front, dmSet);
  if R.H <= 2 then Exit;
  FFrame.FillRect(R.X, R.Y + 1, R.X + 1, R.Y + R.H - 1, Front, dmSet);
  if R.W > 1 then
    FFrame.FillRect(R.X + R.W - 1, R.Y + 1, R.X + R.W, R.Y + R.H - 1, Front, dmSet);
  totalW := R.W;
  for x := 1 to R.W - 2 do
  begin
    frontW := totalW - x;
    backW  := totalW - frontW;
    mix.red   := Byte((Integer(Front.red)   * frontW + Integer(Back.red)   * backW) div totalW);
    mix.green := Byte((Integer(Front.green) * frontW + Integer(Back.green) * backW) div totalW);
    mix.blue  := Byte((Integer(Front.blue)  * frontW + Integer(Back.blue)  * backW) div totalW);
    mix.alpha := 255;
    FFrame.FillRect(R.X + x, R.Y + 1, R.X + x + 1, R.Y + R.H - 1, mix, dmSet);
  end;
end;

procedure TPlaylistForm.DrawSplitterArrow(const R: TSkinRect; ArrowColor: TBGRAPixel;
  Collapsed: Boolean);
const
  kExpanded: array[0..13] of TPoint = (
    (X:3; Y:-2), (X:4; Y:-2),
    (X:2; Y:-1), (X:3; Y:-1), (X:4; Y:-1),
    (X:1; Y: 0), (X:2; Y: 0), (X:3; Y: 0), (X:4; Y: 0),
    (X:2; Y: 1), (X:3; Y: 1), (X:4; Y: 1),
    (X:3; Y: 2), (X:4; Y: 2)
  );
  kCollapsedPts: array[0..13] of TPoint = (
    (X:0; Y:-2), (X:1; Y:-2),
    (X:0; Y:-1), (X:1; Y:-1), (X:2; Y:-1),
    (X:0; Y: 0), (X:1; Y: 0), (X:2; Y: 0), (X:3; Y: 0),
    (X:0; Y: 1), (X:1; Y: 1), (X:2; Y: 1),
    (X:0; Y: 2), (X:1; Y: 2)
  );
var
  cy, baseX, i: Integer;
begin
  if (R.W < 5) or (R.H < 5) or (FFrame = nil) then Exit;
  cy := R.Y + R.H div 2;
  baseX := R.X;
  if Collapsed then
    for i := 0 to High(kCollapsedPts) do
      FFrame.SetPixel(baseX + kCollapsedPts[i].X, cy + kCollapsedPts[i].Y, ArrowColor)
  else
    for i := 0 to High(kExpanded) do
      FFrame.SetPixel(baseX + kExpanded[i].X, cy + kExpanded[i].Y, ArrowColor);
end;

procedure TPlaylistForm.DrawToolbarGroups;
var
  elem: PSkinElement;
  tb: TSkinRect;
  group, gLeft, gRight, gW: Integer;
  srcLeft, srcRight, srcW, srcH, drawX, drawY: Integer;
  sheet, clip_: TBGRABitmap;
  srcRect: TRect;
  hovered, pressed, hasHot: Boolean;
begin
  if FSkin = nil then Exit;
  elem := FSkin^.PlaylistWindow.FindElement('toolbar');
  if (elem = nil) or (elem^.StatePixmaps[0] = nil) then Exit;
  tb := ToolbarAreaRect;
  if tb.IsEmpty then Exit;
  hasHot := elem^.HotPixmap <> nil;

  for group := 0 to kToolbarGroupCount - 1 do
  begin
    gLeft  := tb.X + (tb.W * group)       div kToolbarGroupCount;
    gRight := tb.X + (tb.W * (group + 1)) div kToolbarGroupCount;
    gW := gRight - gLeft;
    if gW <= 0 then Continue;

    hovered := FHoveredToolbar = group;
    pressed := FPressedToolbar = group;
    if hasHot and (hovered or pressed) then
      sheet := elem^.HotPixmap
    else
      sheet := elem^.StatePixmaps[0];
    if sheet = nil then Continue;

    srcLeft  := (sheet.Width * group)       div kToolbarGroupCount;
    srcRight := (sheet.Width * (group + 1)) div kToolbarGroupCount;
    srcW := srcRight - srcLeft;
    if srcW <= 0 then srcW := 1;
    srcH := sheet.Height;
    drawX := gLeft + (gW - srcW) div 2;
    drawY := tb.Y  + (tb.H - srcH) div 2;
    if hasHot then
    begin
      if pressed then begin Inc(drawX); Inc(drawY); end;
    end
    else if hovered and not pressed then
    begin
      Dec(drawX); Dec(drawY);
    end
    else if pressed then
    begin
      Inc(drawX); Inc(drawY);
    end;

    srcRect := Classes.Rect(srcLeft, 0, srcLeft + srcW, srcH);
    clip_ := sheet.GetPart(srcRect);
    try
      FFrame.ClipRect := Classes.Rect(gLeft, tb.Y, gRight, tb.Y + tb.H);
      FFrame.PutImage(drawX, drawY, clip_, dmDrawWithTransparency);
      FFrame.NoClip;
    finally
      clip_.Free;
    end;
  end;
end;

procedure TPlaylistForm.RenderFrame;
var
  wnd: TSkinWindow;
  elem: PSkinElement;
  bounds, pl, vis, leftPane, titleRect: TSkinRect;
  btnX, titleW, titleH: Integer;
  overType: string;
  overState: TButtonVisualState;
  fillBkgnd, fillBkgnd2, front, back: TBGRAPixel;
  sz: TPoint;
begin
  if FSkin = nil then Exit;

  wnd := FSkin^.PlaylistWindow;
  sz := BgSize;
  FreeAndNil(FFrame);
  FFrame := TBGRABitmap.Create(FLogicW, FLogicH, BGRAPixelTransparent);

  if wnd.BackgroundPixmap <> nil then
    DrawNinePatch(FFrame, wnd.BackgroundPixmap, wnd.ResizeRect, wnd.ResizeTile,
      FLogicW, FLogicH, True);

  ApplyListFont;

  pl := ContentRect;
  fillBkgnd  := FSkin^.PlaylistConfig.ColorBkgnd.ToBGRA;
  fillBkgnd2 := FSkin^.PlaylistConfig.ColorBkgnd2.ToBGRA;
  if not FSkin^.PlaylistConfig.ColorBkgnd.Valid then
    fillBkgnd := BGRA(0, 0, 0, 255);
  if not FSkin^.PlaylistConfig.ColorBkgnd2.Valid then
    fillBkgnd2 := BGRA($20, $20, $20, 255);

  vis := DividerVisualRect;
  if (pl.W > 0) and (pl.H > 0) then
  begin
    if (not IsDividerCollapsed) and (FDividerPos > 0) then
    begin
      leftPane.X := pl.X;
      leftPane.Y := pl.Y;
      leftPane.W := Max(0, vis.X - pl.X);
      leftPane.H := pl.H;
      if leftPane.W > 0 then
        FFrame.FillRect(leftPane.X, leftPane.Y,
          leftPane.X + leftPane.W, leftPane.Y + leftPane.H, fillBkgnd2, dmSet);
    end;
  end;

  DrawTabs;
  DrawListRows;
  DrawScrollBar;
  DrawToolbarGroups;

  elem := wnd.FindElement('title');
  if (elem <> nil) and (elem^.StatePixmaps[0] <> nil) then
  begin
    titleW := elem^.StatePixmaps[0].Width;
    titleH := elem^.StatePixmaps[0].Height;
    titleRect := AlignedRect(elem^.Position, sz.X, sz.Y, FLogicW, FLogicH,
      elem^.Align, titleW, titleH);
    bounds := ButtonBounds(elem^);
    bounds.X := titleRect.X;
    bounds.Y := titleRect.Y;
    DrawButton(FFrame, elem^, bounds, bvsNormal);
  end;

  overType  := '';
  overState := bvsNormal;
  if FPressedType <> '' then begin overType := FPressedType; overState := bvsPressed; end
  else if FHoveredType <> '' then begin overType := FHoveredType; overState := bvsHover; end;

  elem := wnd.FindElement('close');
  if elem <> nil then
  begin
    bounds := ButtonBounds(elem^);
    btnX   := AlignedButtonX(elem^);
    bounds.X := btnX;
    if SameText(overType, 'close') then
      DrawButton(FFrame, elem^, bounds, overState)
    else
      DrawButton(FFrame, elem^, bounds, bvsNormal);
  end;

  if FSkin^.PlaylistConfig.ColorText.Valid then
    front := FSkin^.PlaylistConfig.ColorText.ToBGRA
  else
    front := BGRA($00, $80, $FF, 255);
  back := fillBkgnd;
  if (FDividerSavedPos > 0) or (not IsDividerCollapsed) then
  begin
    DrawSplitterBar(vis, front, back);
    DrawSplitterArrow(vis, front, IsDividerCollapsed);
  end;
end;

procedure TPlaylistForm.Paint;
begin
  if FFrame = nil then
    RenderFrame;
  if FFrame = nil then Exit;
  DrawSkinFrame(Canvas, FFrame, ClientWidth, ClientHeight);
end;

function TPlaylistForm.HitButton(PX, PY: Integer): string;
var
  elem: PSkinElement;
  bounds: TSkinRect;
  btnX: Integer;
begin
  Result := '';
  if FSkin = nil then Exit;
  elem := FSkin^.PlaylistWindow.FindElement('close');
  if elem = nil then Exit;
  bounds := ButtonBounds(elem^);
  btnX   := AlignedButtonX(elem^);
  if (PX >= btnX) and (PX < btnX + bounds.W) and
     (PY >= elem^.Position.Y) and (PY < elem^.Position.Y + bounds.H) then
    Result := 'close';
end;

function TPlaylistForm.HitResizeEdge(PX, PY: Integer;
  out EdgeRight, EdgeBottom: Boolean): Boolean;
begin
  EdgeRight  := (PX >= FLogicW - kResizeSense) and (PX < FLogicW);
  EdgeBottom := (PY >= FLogicH - kResizeSense) and (PY < FLogicH);
  Result := EdgeRight or EdgeBottom;
end;

procedure TPlaylistForm.FireButtonClick(const AName: string);
begin
  if SameText(AName, 'close') then
    Hide;
  InvalidateFrame;
end;

procedure TPlaylistForm.FireToolbarClick(Group: Integer);
begin
  case Group of
    0: ShowAddMenu;
    1: ShowDeleteMenu;
    2: ShowListMenu;
    3: ShowSortMenu;
    4: ShowFindMenu;
    5: ShowEditMenu;
    6: ShowModeMenu;
  end;
end;

procedure TPlaylistForm.PlaySource(SourceIndex: Integer);
var
  path: string;
begin
  if (SourceIndex < 0) or (SourceIndex >= FModel.Count) then Exit;
  FModel.SetCurrentIndex(SourceIndex);
  path := FModel.CurrentFile;
  if (path <> '') and (FBackend <> nil) then
    FBackend.OpenFile(path);
  if (path <> '') and Assigned(FOnPlayFile) then
    FOnPlayFile(Self, path);
  EnsureSourceVisible(SourceIndex);
  InvalidateFrame;
end;

procedure TPlaylistForm.SelectRow(VisIndex: Integer; Shift: TShiftState);
var
  src, i, a, b, vis: Integer;
begin
  src := SourceOfVisible(VisIndex);
  if src < 0 then Exit;
  SyncSelectionLength;
  if ssCtrl in Shift then
  begin
    FSelected[src] := not FSelected[src];
    FSelAnchor := src;
  end
  else if ssShift in Shift then
  begin
    if FSelAnchor < 0 then FSelAnchor := src;
    a := Min(FSelAnchor, src);
    b := Max(FSelAnchor, src);
    for i := 0 to High(FSelected) do
      FSelected[i] := False;
    for vis := 0 to High(FVisible) do
      if (FVisible[vis] >= a) and (FVisible[vis] <= b) then
        FSelected[FVisible[vis]] := True;
  end
  else
  begin
    for i := 0 to High(FSelected) do
      FSelected[i] := False;
    FSelected[src] := True;
    FSelAnchor := src;
  end;
  InvalidateFrame;
end;

function TPlaylistForm.IsAudioFile(const Path: string): Boolean;
var
  ext: string;
  i: Integer;
begin
  ext := LowerCase(ExtractFileExt(Path));
  for i := 0 to High(kAudioExts) do
    if ext = kAudioExts[i] then Exit(True);
  Result := False;
end;

procedure TPlaylistForm.CollectAudioFiles(const Path: string; Dest: TStrings);
var
  sr: TSearchRec;
  full, dir: string;
begin
  if DirectoryExists(Path) then
  begin
    dir := IncludeTrailingPathDelimiter(Path);
    if FindFirst(dir + '*', faAnyFile, sr) = 0 then
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        full := dir + sr.Name;
        if (sr.Attr and faDirectory) <> 0 then
          CollectAudioFiles(full, Dest)
        else if IsAudioFile(full) then
          Dest.Add(full);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end
  else if FileExists(Path) and IsAudioFile(Path) then
    Dest.Add(Path);
end;

procedure TPlaylistForm.ImportPathList(Files: TStrings);
var
  arr: array of string;
  i: Integer;
begin
  if (Files = nil) or (Files.Count = 0) then Exit;
  SetLength(arr, Files.Count);
  for i := 0 to Files.Count - 1 do
    arr[i] := Files[i];
  FModel.AddFiles(arr);
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.HandleDropFiles(Sender: TObject; const FileNames: array of string);
var
  i: Integer;
  collected: TStringList;
begin
  if Sender = nil then ;
  collected := TStringList.Create;
  try
    collected.Sorted := True;
    collected.Duplicates := dupIgnore;
    for i := 0 to High(FileNames) do
      CollectAudioFiles(FileNames[i], collected);
    ImportPathList(collected);
  finally
    collected.Free;
  end;
end;

function TPlaylistForm.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  steps: Integer;
begin
  inherited DoMouseWheel(Shift, WheelDelta, MousePos);
  Result := True;
  steps := WheelDelta div 120;
  if steps = 0 then
    if WheelDelta > 0 then steps := 1 else steps := -1;
  SetScrollValue(FScroll - steps);
end;

procedure TPlaylistForm.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  er, eb: Boolean;
  hitName: string;
  group, row, part: Integer;
  thumb: TSkinRect;
  cx, cy: Integer;
begin
  cx := X;
  cy := Y;
  MapHit(X, Y);
  if Button = mbLeft then
  begin
    if ssDouble in Shift then
    begin
      if (FDividerSavedPos > 0) and PtInSkinRect(X, Y, DividerHotZoneRect) then
      begin
        FDividerDragging := False;
        FDividerHandlePressed := False;
        ToggleDividerCollapsed;
        Cursor := crDefault;
        Exit;
      end;
      row := RowAt(X, Y);
      if row >= 0 then
      begin
        PlaySource(SourceOfVisible(row));
        Exit;
      end;
    end;

    hitName := HitButton(X, Y);
    if hitName <> '' then
    begin
      FPressedType := hitName;
      InvalidateFrame;
    end
    else
    begin
      group := ToolbarGroupIndexAt(X, Y);
      if group >= 0 then
      begin
        FPressedToolbar := group;
        InvalidateFrame;
      end
      else
      begin
        part := SbHitPart(X, Y);
        if part >= 0 then
        begin
          case part of
            0: begin FSbPressedPart := 0; SetScrollValue(FScroll - 1); end;
            1: begin FSbPressedPart := 1; SetScrollValue(FScroll + 1); end;
            2: begin
                 FSbDragging := True;
                 FSbHoverPart := 2;
                 thumb := SbThumbRect;
                 FSbDragOffset := Y - thumb.Y;
                 SetCapture(Handle);
               end;
            3: SetScrollValue(FScroll - VisibleRowsFit);
            4: SetScrollValue(FScroll + VisibleRowsFit);
          end;
          InvalidateFrame;
        end
        else if (FDividerSavedPos > 0) and PtInSkinRect(X, Y, DividerHotZoneRect) then
        begin
          FDividerDragging := True;
          FDividerHandlePressed := PtInSkinRect(X, Y, DividerHandleRect);
          FDividerDragStartX := X;
          SetCapture(Handle);
        end
        else if HitResizeEdge(X, Y, er, eb) then
        begin
          FResizing         := True;
          FResizeEdgeRight  := er;
          FResizeEdgeBottom := eb;
          FResizeStartX     := Mouse.CursorPos.X;
          FResizeStartY     := Mouse.CursorPos.Y;
          FResizeStartW     := FLogicW;
          FResizeStartH     := FLogicH;
          SetCapture(Handle);
        end
        else
        begin
          row := TabAt(X, Y);
          if row >= 0 then
          begin
            FBook.SwitchTo(row);
            SyncActiveModel;
          end
          else
          begin
            row := RowAt(X, Y);
            if row >= 0 then
            begin
              SelectRow(row, Shift);
              FDragRows := False;
              FDragStart := Point(X, Y);
              CollectDragSources;
              FDropVisIndex := -1;
            end;
          end;
        end;
      end;
    end;
  end
  else if Button = mbRight then
  begin
    row := RowAt(X, Y);
    if row >= 0 then
    begin
      if (SourceOfVisible(row) >= 0) and
         ((SourceOfVisible(row) >= Length(FSelected)) or
          not FSelected[SourceOfVisible(row)]) then
        SelectRow(row, []);
      ShowEditMenu;
    end;
  end;
  inherited MouseDown(Button, Shift, cx, cy);
  if Button = mbLeft then
    TryBeginCaptionDrag(Self, cx, cy);
end;

procedure TPlaylistForm.DblClick;
begin
  inherited DblClick;
end;

procedure TPlaylistForm.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  newName: string;
  er, eb: Boolean;
  newW, newH, dx, dy, newPos, newGroup, part: Integer;
  pl, track, thumb: TSkinRect;
  needRedraw: Boolean;
  avail: Integer;
  ratio: Double;
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
    if FResizeEdgeRight  then
      newW := Max(kPlaylistMinW, FResizeStartW + Round(dx / s));
    if FResizeEdgeBottom then
      newH := Max(kPlaylistMinH, FResizeStartH + Round(dy / s));
    if (newW <> FLogicW) or (newH <> FLogicH) then
    begin
      SetBounds(Left, Top, ScalePx(newW, s), ScalePx(newH, s));
      RenderFrame;
      if Assigned(FOnResizeInProgress) then
        FOnResizeInProgress(Self);
    end;
  end
  else
  begin
  MapHit(X, Y);
  if FSbDragging then
  begin
    track := SbTrackRect;
    thumb := SbThumbRect;
    avail := Max(1, track.H - thumb.H);
    newPos := Y - FSbDragOffset;
    if newPos < track.Y then newPos := track.Y;
    if newPos > track.Y + avail then newPos := track.Y + avail;
    ratio := (newPos - track.Y) / avail;
    SetScrollValue(Round(ratio * ScrollMax));
  end
  else if (Length(FDragSources) > 0) and (ssLeft in Shift) and
          ((Abs(X - FDragStart.X) > 4) or (Abs(Y - FDragStart.Y) > 4) or FDragRows) then
  begin
    FDragRows := True;
    FDropVisIndex := InsertionVisIndex(Y);
    Cursor := crDrag;
    InvalidateFrame;
  end
  else if FDividerDragging then
  begin
    pl := ContentRect;
    newPos := X - pl.X;
    newPos := Max(0, Min(newPos, pl.W - 40));
    if newPos <> FDividerPos then
    begin
      FDividerPos := newPos;
      InvalidateFrame;
    end;
  end
  else
  begin
    needRedraw := False;
    newName := HitButton(X, Y);
    if newName <> FHoveredType then
    begin
      FHoveredType := newName;
      needRedraw := True;
    end;
    newGroup := ToolbarGroupIndexAt(X, Y);
    if newGroup <> FHoveredToolbar then
    begin
      FHoveredToolbar := newGroup;
      needRedraw := True;
    end;
    newPos := TabAt(X, Y);
    if newPos <> FHoveredTab then
    begin
      FHoveredTab := newPos;
      needRedraw := True;
    end;
    part := SbHitPart(X, Y);
    if part <> FSbHoverPart then
    begin
      if part <= 2 then FSbHoverPart := part else FSbHoverPart := -1;
      needRedraw := True;
    end;
    if needRedraw then InvalidateFrame;

    if HitResizeEdge(X, Y, er, eb) then
    begin
      if er and eb then Cursor := crSizeNWSE
      else if er    then Cursor := crSizeWE
      else               Cursor := crSizeNS;
    end
    else if (FDividerSavedPos > 0) and PtInSkinRect(X, Y, DividerHandleRect) then
      Cursor := crHandPoint
    else if (FDividerSavedPos > 0) and PtInSkinRect(X, Y, DividerHotZoneRect) then
      Cursor := crHSplit
    else if newGroup >= 0 then
      Cursor := crHandPoint
    else
      Cursor := crDefault;
  end;
  end;
  inherited MouseMove(Shift, X, Y);
end;

procedure TPlaylistForm.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  clickedType, hitName: string;
  group, released, insertSrc, vis: Integer;
  wasDrag: Boolean;
begin
  MapHit(X, Y);
  if Button = mbLeft then
  begin
    if FDragRows then
    begin
      vis := InsertionVisIndex(Y);
      insertSrc := 0;
      if vis < 0 then
        insertSrc := FModel.Count
      else if vis >= VisibleCount then
        insertSrc := FModel.Count
      else
        insertSrc := SourceOfVisible(vis);
      if insertSrc < 0 then insertSrc := FModel.Count;
      FModel.MoveRows(FDragSources, insertSrc);
      FDragRows := False;
      SetLength(FDragSources, 0);
      FDropVisIndex := -1;
      Cursor := crDefault;
      SyncSelectionLength;
      RebuildVisible;
      InvalidateFrame;
    end
    else if FSbDragging then
    begin
      ReleaseCapture;
      FSbDragging := False;
      FSbPressedPart := -1;
      InvalidateFrame;
    end
    else if FDividerDragging then
    begin
      ReleaseCapture;
      wasDrag := Abs(X - FDividerDragStartX) > 3;
      FDividerDragging := False;
      if wasDrag then
      begin
        if FDividerPos <= kDividerCollapseThreshold then
          FDividerPos := 0
        else
          FDividerSavedPos := FDividerPos;
        ClampDividerPos;
        InvalidateFrame;
      end
      else if FDividerHandlePressed and PtInSkinRect(X, Y, DividerHandleRect) then
        ToggleDividerCollapsed;
      FDividerHandlePressed := False;
      Cursor := crDefault;
    end
    else if FResizing then
    begin
      ReleaseCapture;
      FResizing := False;
      if Assigned(FOnResizeFinished) then
        FOnResizeFinished(Self);
    end
    else if FPressedToolbar >= 0 then
    begin
      group := FPressedToolbar;
      FPressedToolbar := -1;
      released := ToolbarGroupIndexAt(X, Y);
      InvalidateFrame;
      if (released >= 0) and (released = group) then
        FireToolbarClick(group);
    end
    else
    begin
      if FSbPressedPart >= 0 then
      begin
        FSbPressedPart := -1;
        InvalidateFrame;
      end;
      clickedType := FPressedType;
      FPressedType := '';
      if clickedType <> '' then
      begin
        hitName := HitButton(X, Y);
        if SameText(hitName, clickedType) then
          FireButtonClick(clickedType)
        else
          InvalidateFrame;
      end;
      SetLength(FDragSources, 0);
      FDragRows := False;
    end;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TPlaylistForm.MouseLeave;
begin
  if (FHoveredType <> '') or (FPressedType <> '') or
     (FHoveredToolbar >= 0) or (FPressedToolbar >= 0) or
     (FSbHoverPart >= 0) or (FHoveredTab >= 0) then
  begin
    FHoveredType := '';
    FPressedType := '';
    FHoveredToolbar := -1;
    FPressedToolbar := -1;
    FSbHoverPart := -1;
    FHoveredTab := -1;
    InvalidateFrame;
  end;
  Cursor := crDefault;
  inherited MouseLeave;
end;

procedure TPlaylistForm.WMNCHitTest(var Msg: TLMessage);
var
  pt: TPoint;
  er, eb: Boolean;
  pl: TSkinRect;
begin
  pt := NcHitToSkin(Self, Msg, FLogicW, FLogicH);

  if HitButton(pt.X, pt.Y) <> '' then
    Msg.Result := HTCLIENT
  else if ToolbarGroupIndexAt(pt.X, pt.Y) >= 0 then
    Msg.Result := HTCLIENT
  else if HitResizeEdge(pt.X, pt.Y, er, eb) then
    Msg.Result := HTCLIENT
  else if (FDividerSavedPos > 0) and PtInSkinRect(pt.X, pt.Y, DividerHotZoneRect) then
    Msg.Result := HTCLIENT
  else
  begin
    pl := ContentRect;
    if PtInSkinRect(pt.X, pt.Y, pl) then
      Msg.Result := HTCLIENT
    else
      Msg.Result := HTCAPTION;
  end;
end;

function TPlaylistForm.AddMenuItem(const Cap: string; Handler: TNotifyEvent;
  ATag: Integer): TMenuItem;
begin
  Result := TMenuItem.Create(FMenu);
  Result.Caption := Cap;
  Result.OnClick := Handler;
  Result.Tag := ATag;
  FMenu.Items.Add(Result);
end;

procedure TPlaylistForm.ShowAddMenu;
var
  pt: TPoint;
begin
  FMenu.Items.Clear;
  AddMenuItem('文件(&F)...', @OnAddFiles);
  AddMenuItem('文件夹(&D)...', @OnAddFolder);
  pt := ToolbarMenuAnchor(0);
  FMenu.PopUp(pt.X, pt.Y);
end;

procedure TPlaylistForm.ShowDeleteMenu;
var
  pt: TPoint;
begin
  FMenu.Items.Clear;
  AddMenuItem('从列表删除(&D)', @OnRemoveSelected);
  AddMenuItem('清空列表(&L)', @OnClearAll);
  AddMenuItem('-', nil);
  AddMenuItem('删除重复项(&R)', @OnRemoveDupes);
  AddMenuItem('删除无效文件(&I)', @OnRemoveInvalid);
  pt := ToolbarMenuAnchor(1);
  FMenu.PopUp(pt.X, pt.Y);
end;

procedure TPlaylistForm.ShowListMenu;
var
  pt: TPoint;
begin
  FMenu.Items.Clear;
  AddMenuItem('定位正在播放(&L)', @OnLocateCurrent);
  AddMenuItem('-', nil);
  AddMenuItem('新建播放列表(&N)', @OnNewTab);
  AddMenuItem('重命名(&R)', @OnRenameTab);
  AddMenuItem('删除播放列表(&D)', @OnDeleteTab);
  pt := ToolbarMenuAnchor(2);
  FMenu.PopUp(pt.X, pt.Y);
end;

procedure TPlaylistForm.ShowSortMenu;
var
  pt: TPoint;
begin
  FMenu.Items.Clear;
  AddMenuItem('按文件名排序', @OnSortByName);
  AddMenuItem('按标题排序', @OnSortByTitle);
  AddMenuItem('按路径排序', @OnSortByPath);
  AddMenuItem('-', nil);
  AddMenuItem('随机排序', @OnSortRandom);
  AddMenuItem('反转排序', @OnSortReverse);
  pt := ToolbarMenuAnchor(3);
  FMenu.PopUp(pt.X, pt.Y);
end;

procedure TPlaylistForm.ShowFindMenu;
begin
  EnsureSearchDialog;
  FSearchEdit.Text := FFilter;
  FSearchForm.Left := Left + (Width - FSearchForm.Width) div 2;
  FSearchForm.Top := Top + 40;
  FSearchForm.Show;
  FSearchForm.BringToFront;
  FSearchEdit.SetFocus;
  FSearchEdit.SelectAll;
end;

procedure TPlaylistForm.ShowEditMenu;
var
  pt: TPoint;
begin
  FMenu.Items.Clear;
  AddMenuItem('播放选中(&P)', @OnPlaySelected);
  AddMenuItem('文件属性(&I)', @OnFileProps);
  AddMenuItem('-', nil);
  AddMenuItem('全选(&A)', @OnSelectAll);
  AddMenuItem('反选(&I)', @OnInvertSel);
  AddMenuItem('取消选择(&N)', @OnClearSel);
  AddMenuItem('-', nil);
  AddMenuItem('上移(&U)', @OnMoveUp);
  AddMenuItem('下移(&D)', @OnMoveDown);
  pt := ToolbarMenuAnchor(5);
  FMenu.PopUp(pt.X, pt.Y);
end;

procedure TPlaylistForm.ShowModeMenu;
var
  pt: TPoint;
  item: TMenuItem;
  i: Integer;
  modes: array[0..3] of record
    Cap: string;
    RepeatMode: Integer;
    Shuffle: Boolean;
  end;
begin
  modes[0].Cap := '顺序播放'; modes[0].RepeatMode := 0; modes[0].Shuffle := False;
  modes[1].Cap := '单曲循环'; modes[1].RepeatMode := 1; modes[1].Shuffle := False;
  modes[2].Cap := '列表循环'; modes[2].RepeatMode := 2; modes[2].Shuffle := False;
  modes[3].Cap := '随机播放'; modes[3].RepeatMode := 2; modes[3].Shuffle := True;

  FMenu.Items.Clear;
  for i := 0 to 3 do
  begin
    item := AddMenuItem(modes[i].Cap, @OnModeClick, i);
    item.RadioItem := True;
    item.Checked := (FModel.RepeatMode = modes[i].RepeatMode) and
                    (FModel.Shuffle = modes[i].Shuffle);
  end;
  pt := ToolbarMenuAnchor(6);
  FMenu.PopUp(pt.X, pt.Y);
end;

procedure TPlaylistForm.OnAddFiles(Sender: TObject);
var
  dlg: TOpenDialog;
  i: Integer;
  files: TStringList;
begin
  dlg := TOpenDialog.Create(Self);
  files := TStringList.Create;
  try
    dlg.Title := '添加文件';
    dlg.Options := dlg.Options + [ofAllowMultiSelect, ofFileMustExist, ofEnableSizing];
    dlg.Filter := '音频文件|*.mp3;*.flac;*.ogg;*.wav;*.aac;*.m4a;*.wma;*.ape|' +
                  '所有文件|*.*';
    if not dlg.Execute then Exit;
    for i := 0 to dlg.Files.Count - 1 do
      files.Add(dlg.Files[i]);
    ImportPathList(files);
  finally
    files.Free;
    dlg.Free;
  end;
end;

procedure TPlaylistForm.OnAddFolder(Sender: TObject);
var
  dir: string;
  files: TStringList;
begin
  dir := '';
  if not SelectDirectory('添加文件夹', '', dir) then Exit;
  files := TStringList.Create;
  try
    files.Sorted := True;
    CollectAudioFiles(dir, files);
    ImportPathList(files);
  finally
    files.Free;
  end;
end;

procedure TPlaylistForm.OnRemoveSelected(Sender: TObject);
var
  i: Integer;
begin
  SyncSelectionLength;
  for i := FModel.Count - 1 downto 0 do
    if (i < Length(FSelected)) and FSelected[i] then
      FModel.RemoveIndex(i);
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnClearAll(Sender: TObject);
begin
  Clear;
end;

procedure TPlaylistForm.OnRemoveDupes(Sender: TObject);
var
  seen: TStringList;
  i: Integer;
  key: string;
begin
  seen := TStringList.Create;
  try
    seen.Sorted := True;
    seen.Duplicates := dupIgnore;
    for i := FModel.Count - 1 downto 0 do
    begin
      key := UTF8LowerCase(FModel.FileAt(i));
      if seen.IndexOf(key) >= 0 then
        FModel.RemoveIndex(i)
      else
        seen.Add(key);
    end;
  finally
    seen.Free;
  end;
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnRemoveInvalid(Sender: TObject);
var
  i: Integer;
begin
  for i := FModel.Count - 1 downto 0 do
    if not FileExists(FModel.FileAt(i)) then
      FModel.RemoveIndex(i);
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnLocateCurrent(Sender: TObject);
begin
  if FModel.CurrentIndex < 0 then Exit;
  EnsureSourceVisible(FModel.CurrentIndex);
  InvalidateFrame;
end;

procedure TPlaylistForm.OnSortByName(Sender: TObject);
var
  i: Integer;
  names, paths: TStringList;
  tmpN, tmpP: string;
  j: Integer;
begin
  names := TStringList.Create;
  paths := TStringList.Create;
  try
    for i := 0 to FModel.Count - 1 do
    begin
      paths.Add(FModel.FileAt(i));
      names.Add(ExtractFileName(FModel.FileAt(i)));
    end;
    for i := 0 to names.Count - 2 do
      for j := i + 1 to names.Count - 1 do
        if AnsiCompareText(names[i], names[j]) > 0 then
        begin
          tmpN := names[i]; names[i] := names[j]; names[j] := tmpN;
          tmpP := paths[i]; paths[i] := paths[j]; paths[j] := tmpP;
        end;
    FModel.Clear;
    for i := 0 to paths.Count - 1 do
      FModel.AddFile(paths[i]);
  finally
    names.Free;
    paths.Free;
  end;
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnSortByTitle(Sender: TObject);
var
  i, j: Integer;
  paths, titles: TStringList;
  tmpP, tmpT: string;
begin
  paths := TStringList.Create;
  titles := TStringList.Create;
  try
    for i := 0 to FModel.Count - 1 do
    begin
      paths.Add(FModel.FileAt(i));
      titles.Add(DisplayTitleForEntry(FModel.Entries[i]));
    end;
    for i := 0 to titles.Count - 2 do
      for j := i + 1 to titles.Count - 1 do
        if AnsiCompareText(titles[i], titles[j]) > 0 then
        begin
          tmpT := titles[i]; titles[i] := titles[j]; titles[j] := tmpT;
          tmpP := paths[i];  paths[i]  := paths[j];  paths[j]  := tmpP;
        end;
    FModel.Clear;
    for i := 0 to paths.Count - 1 do
      FModel.AddFile(paths[i]);
  finally
    titles.Free;
    paths.Free;
  end;
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnSortByPath(Sender: TObject);
var
  i, j: Integer;
  paths: TStringList;
  tmpP: string;
begin
  paths := TStringList.Create;
  try
    for i := 0 to FModel.Count - 1 do
      paths.Add(FModel.FileAt(i));
    for i := 0 to paths.Count - 2 do
      for j := i + 1 to paths.Count - 1 do
        if AnsiCompareText(paths[i], paths[j]) > 0 then
        begin
          tmpP := paths[i]; paths[i] := paths[j]; paths[j] := tmpP;
        end;
    FModel.Clear;
    for i := 0 to paths.Count - 1 do
      FModel.AddFile(paths[i]);
  finally
    paths.Free;
  end;
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnSortRandom(Sender: TObject);
var
  i, j: Integer;
  paths: TStringList;
  tmp: string;
begin
  paths := TStringList.Create;
  try
    for i := 0 to FModel.Count - 1 do
      paths.Add(FModel.FileAt(i));
    for i := paths.Count - 1 downto 1 do
    begin
      j := Random(i + 1);
      tmp := paths[i];
      paths[i] := paths[j];
      paths[j] := tmp;
    end;
    FModel.Clear;
    for i := 0 to paths.Count - 1 do
      FModel.AddFile(paths[i]);
  finally
    paths.Free;
  end;
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnSortReverse(Sender: TObject);
var
  i: Integer;
  paths: TStringList;
begin
  paths := TStringList.Create;
  try
    for i := FModel.Count - 1 downto 0 do
      paths.Add(FModel.FileAt(i));
    FModel.Clear;
    for i := 0 to paths.Count - 1 do
      FModel.AddFile(paths[i]);
  finally
    paths.Free;
  end;
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnPlaySelected(Sender: TObject);
var
  i: Integer;
begin
  SyncSelectionLength;
  for i := 0 to High(FSelected) do
    if FSelected[i] then
    begin
      PlaySource(i);
      Exit;
    end;
  if FModel.CurrentIndex >= 0 then
    PlaySource(FModel.CurrentIndex);
end;

procedure TPlaylistForm.OnFileProps(Sender: TObject);
var
  i: Integer;
  e: TPlaylistEntry;
  dur: string;
begin
  SyncSelectionLength;
  i := -1;
  if (FSelAnchor >= 0) and (FSelAnchor < FModel.Count) then
    i := FSelAnchor;
  if i < 0 then
    for i := 0 to High(FSelected) do
      if FSelected[i] then Break;
  if (i < 0) or (i >= FModel.Count) then Exit;
  e := FModel.Entries[i];
  dur := DisplayDurationForEntry(e);
  if dur = '' then dur := '（未知）';
  MessageDlg('文件属性',
    '文件：' + e.FilePath + LineEnding +
    '标题：' + DisplayTitleForEntry(e) + LineEnding +
    '时长：' + dur,
    mtInformation, [mbOK], 0);
end;

procedure TPlaylistForm.OnSelectAll(Sender: TObject);
var
  i: Integer;
begin
  SyncSelectionLength;
  for i := 0 to High(FSelected) do
    FSelected[i] := True;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnInvertSel(Sender: TObject);
var
  i: Integer;
begin
  SyncSelectionLength;
  for i := 0 to High(FSelected) do
    FSelected[i] := not FSelected[i];
  InvalidateFrame;
end;

procedure TPlaylistForm.OnClearSel(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to High(FSelected) do
    FSelected[i] := False;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnMoveUp(Sender: TObject);
var
  i: Integer;
begin
  SyncSelectionLength;
  for i := 1 to FModel.Count - 1 do
    if (i < Length(FSelected)) and FSelected[i] then
    begin
      FModel.MoveUp(i);
      FSelected[i] := False;
      FSelected[i - 1] := True;
    end;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnMoveDown(Sender: TObject);
var
  i: Integer;
begin
  SyncSelectionLength;
  for i := FModel.Count - 2 downto 0 do
    if (i < Length(FSelected)) and FSelected[i] then
    begin
      FModel.MoveDown(i);
      FSelected[i] := False;
      FSelected[i + 1] := True;
    end;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnModeClick(Sender: TObject);
begin
  case TMenuItem(Sender).Tag of
    0: begin FModel.RepeatMode := 0; FModel.Shuffle := False; end;
    1: begin FModel.RepeatMode := 1; FModel.Shuffle := False; end;
    2: begin FModel.RepeatMode := 2; FModel.Shuffle := False; end;
    3: begin FModel.RepeatMode := 2; FModel.Shuffle := True; end;
  end;
end;

procedure TPlaylistForm.AddEntry(const FilePath, Title, Artist: string;
  DurationMs: Int64);
var
  idx: Integer;
begin
  FModel.AddFile(FilePath);
  idx := FModel.Count - 1;
  if (Title <> '') or (Artist <> '') or (DurationMs > 0) then
    FModel.SetMetadata(idx, Title, Artist, '', DurationMs);
  SyncSelectionLength;
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.Clear;
begin
  FModel.Clear;
  SetLength(FSelected, 0);
  SetLength(FVisible, 0);
  FScroll := 0;
  FSelAnchor := -1;
  InvalidateFrame;
end;

procedure TPlaylistForm.SetCurrentIndex(Index: Integer);
begin
  FModel.SetCurrentIndex(Index);
  EnsureSourceVisible(FModel.CurrentIndex);
  InvalidateFrame;
end;

function TPlaylistForm.CurrentFile: string;
begin
  Result := FModel.CurrentFile;
end;

procedure TPlaylistForm.CollectDragSources;
var
  i, n: Integer;
begin
  SetLength(FDragSources, 0);
  n := 0;
  SyncSelectionLength;
  for i := 0 to High(FSelected) do
    if FSelected[i] then
    begin
      SetLength(FDragSources, n + 1);
      FDragSources[n] := i;
      Inc(n);
    end;
end;

function TPlaylistForm.InsertionVisIndex(PY: Integer): Integer;
var
  lr: TSkinRect;
begin
  lr := ListRect;
  if FRowHeight <= 0 then Exit(VisibleCount);
  if PY <= lr.Y then Exit(FScroll);
  Result := FScroll + (PY - lr.Y + FRowHeight div 2) div FRowHeight;
  if Result < 0 then Result := 0;
  if Result > VisibleCount then Result := VisibleCount;
end;

procedure TPlaylistForm.EnsureSearchDialog;
var
  lbl: TLabel;
  btn: TButton;
begin
  if FSearchForm <> nil then Exit;
  FSearchForm := TForm.CreateNew(Self);
  FSearchForm.Caption := '搜索播放列表';
  FSearchForm.BorderStyle := bsToolWindow;
  FSearchForm.Width := 320;
  FSearchForm.Height := 90;
  FSearchForm.Position := poDesigned;
  FSearchForm.FormStyle := fsStayOnTop;
  FSearchForm.OnClose := @OnSearchFormClose;
  lbl := TLabel.Create(FSearchForm);
  lbl.Parent := FSearchForm;
  lbl.Left := 10;
  lbl.Top := 14;
  lbl.Caption := '关键字:';
  FSearchEdit := TEdit.Create(FSearchForm);
  FSearchEdit.Parent := FSearchForm;
  FSearchEdit.Left := 70;
  FSearchEdit.Top := 10;
  FSearchEdit.Width := 230;
  FSearchEdit.OnChange := @OnSearchEditChange;
  btn := TButton.Create(FSearchForm);
  btn.Parent := FSearchForm;
  btn.Caption := '关闭';
  btn.Left := 220;
  btn.Top := 48;
  btn.Width := 80;
  btn.OnClick := @OnSearchClose;
end;

procedure TPlaylistForm.OnSearchEditChange(Sender: TObject);
begin
  if Sender = nil then ;
  if FSearchEdit = nil then Exit;
  FFilter := Trim(FSearchEdit.Text);
  RebuildVisible;
  InvalidateFrame;
end;

procedure TPlaylistForm.OnSearchClose(Sender: TObject);
begin
  if Sender = nil then ;
  if FSearchForm <> nil then
    FSearchForm.Hide;
end;

procedure TPlaylistForm.OnSearchFormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if Sender = nil then ;
  CloseAction := caHide;
end;

procedure TPlaylistForm.OnNewTab(Sender: TObject);
begin
  if Sender = nil then ;
  FBook.AddTab(Format('[%d]', [FBook.TabCount]));
  FBook.SwitchTo(FBook.TabCount - 1);
  SyncActiveModel;
end;

procedure TPlaylistForm.OnRenameTab(Sender: TObject);
var
  s: string;
begin
  s := FBook.ActiveName;
  if InputQuery('重命名', '播放列表名称：', s) then
  begin
    FBook.RenameTab(FBook.ActiveIndex, s);
    InvalidateFrame;
  end;
end;

procedure TPlaylistForm.OnDeleteTab(Sender: TObject);
begin
  if FBook.TabCount <= 1 then Exit;
  FBook.RemoveTab(FBook.ActiveIndex);
  SyncActiveModel;
end;

procedure TPlaylistForm.LoadFromTtblDir(const Dir: string; Count, ActiveList: Integer);
begin
  FBook.LoadFromTtblDir(Dir, Count, ActiveList);
  SyncActiveModel;
end;

function TPlaylistForm.SaveToTtblDir(const Dir: string): Integer;
begin
  Result := FBook.SaveToTtblDir(Dir);
end;

end.
