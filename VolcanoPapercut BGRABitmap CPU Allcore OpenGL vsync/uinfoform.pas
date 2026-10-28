unit uInfoForm;

{ Developer information window (opens at startup; I or F1 brings it back; 1..7 switch tabs).
  Tabs:
    Overview     project, architecture, pipeline, hotkeys and a parameter dump
    Performance  live fps / vsync, frame history graph, pipeline timings
    Threads      thread and band controls, per-worker and per-band cost
    Layers       switch single layers on/off, CPU cost of each layer
    Objects      live counts, sizes, memory, OpenGL and build information
    Palette      every colour used, with its hex code
  Built in code, no .lfm. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls,
  ComCtrls, Spin, Clipbrd, LCLType, BGRABitmap, BGRABitmapTypes,
  CheckLst, EditBtn, LCLIntf, uRenderPool, uVolcanoScene, uFrameRenderer, uExportJob, uMFVideo;

type

  { TInfoForm }

  TInfoForm = class(TForm)
  private
    FPages: TPageControl;
    FOverview: TMemo;
    FPerfBox, FThreadBox, FPaletteBox: TPaintBox;
    { export tab }
    FExpFolder: TDirectoryEdit;
    FExpW, FExpH, FExpFrames, FExpFps, FExpKbps: TSpinEdit;
    FExpPng, FExpSeq, FExpGif, FExpMp4, FExpHw: TCheckBox;
    FExpTargets: TCheckListBox;
    FExpInfo: TLabel;
    FExpProgress: TProgressBar;
    FExpLog: TMemo;
    FExpRun, FExpCancel: TButton;
    FExpCancelled, FExpBusy: Boolean;
    FLayerList, FObjList: TListView;
    FThreadSpin, FBandSpin: TSpinEdit;
    FVSyncCheck: TCheckBox;
    FBtnPause, FBtnCaption: TButton;
    FStatus: TLabel;
    FTimer: TTimer;
    FUpdating: Boolean;
    FBuf: TBitmap;        // GDI back buffer of the live panels
    FPaintMs: Double;     // last live panel paint (main thread time)
    FAdaptiveCheck: TCheckBox;
    FOrder: Integer;  // increasing Left so left-aligned controls keep creation order
    function AddTab(const ACaption: string): TTabSheet;
    function AddBar(AParent: TWinControl): TPanel;
    function AddButton(AParent: TWinControl; const ACaption: string;
      AHandler: TNotifyEvent): TButton;
    function AddLabel(AParent: TWinControl; const ACaption: string): TLabel;
    function AddList(AParent: TWinControl): TListView;
    procedure AddCol(LV: TListView; const ACaption: string; AWidth: Integer);
    procedure BuildUI;
    procedure FillLayers;
    procedure RefreshLayers;
    procedure RefreshObjects;
    procedure RefreshOverview;
    procedure RefreshControls;
    function OverviewText: string;
    function ReportText: string;
    procedure TimerTick(Sender: TObject);
    procedure PageChange(Sender: TObject);
    function Buffer(ABox: TPaintBox): TCanvas;
    procedure AdaptiveClick(Sender: TObject);
    procedure PerfPaint(Sender: TObject);
    procedure ThreadPaint(Sender: TObject);
    procedure PalettePaint(Sender: TObject);
    procedure LayerChecked(Sender: TObject; Item: TListItem);
    procedure AllOnClick(Sender: TObject);
    procedure AllOffClick(Sender: TObject);
    procedure SoloClick(Sender: TObject);
    procedure ThreadsChange(Sender: TObject);
    procedure BandsChange(Sender: TObject);
    procedure VSyncClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure CaptionClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure BuildExportTab(Tab: TTabSheet);
    function AddSpin(AParent: TWinControl; AMin, AMax, AValue: Integer): TSpinEdit;
    function AddCheck(AParent: TWinControl; const ACaption: string; AChecked: Boolean): TCheckBox;
    procedure ExpEstimate(Sender: TObject);
    procedure ExpWindowSize(Sender: TObject);
    procedure ExpHalfSize(Sender: TObject);
    procedure ExpAllTargets(Sender: TObject);
    procedure ExpNoTargets(Sender: TObject);
    procedure ExpMainOnly(Sender: TObject);
    procedure ExpOpenFolder(Sender: TObject);
    procedure ExpRunClick(Sender: TObject);
    procedure ExpCancelClick(Sender: TObject);
    procedure ExpProgressCb(const AMessage: string; ADone, ATotal: Integer; var ACancel: Boolean);
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ShowExportTab;
  end;

var
  InfoForm: TInfoForm;

implementation

uses
  uMainForm;

const
  TabCount = 7;

function Ms(V: Double): string;
begin
  Result := FormatFloat('0.00', V) + ' ms';
end;

function KB(V: Int64): string;
begin
  if V >= 1024 * 1024 then
    Result := FormatFloat('0.0', V / (1024 * 1024)) + ' MB'
  else
    Result := FormatFloat('0.0', V / 1024) + ' KB';
end;

{ worker colours for the thread charts }
function WorkerColor(I: Integer): TColor;
begin
  Result := BGRAToColor(HSLAToBGRA(HSLA((I * 9973) mod 65536, 40000, 30000)));
end;

{ TInfoForm }

constructor TInfoForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Volcano Papercut GL - Developer info';
  Width := Scale96ToForm(780);
  Height := Scale96ToForm(820);
  Position := poDesigned;
  KeyPreview := True;
  OnKeyDown := @FormKey;
  BuildUI;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 250;
  FTimer.OnTimer := @TimerTick;
  RefreshOverview;
  RefreshControls;
end;

destructor TInfoForm.Destroy;
begin
  FBuf.Free;
  inherited Destroy;
end;

function TInfoForm.AddTab(const ACaption: string): TTabSheet;
begin
  Result := FPages.AddTabSheet;
  Result.Caption := ACaption;
end;

function TInfoForm.AddBar(AParent: TWinControl): TPanel;
begin
  Result := TPanel.Create(Self);
  Result.Parent := AParent;
  Result.Align := alTop;
  Result.Height := Scale96ToForm(34);
  Result.BevelOuter := bvNone;
  Inc(FOrder);
  Result.Top := FOrder * 1000;  // top-aligned rows keep creation order
end;

function TInfoForm.AddButton(AParent: TWinControl; const ACaption: string;
  AHandler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.AutoSize := True;
  Result.Align := alLeft;
  Result.BorderSpacing.Around := 3;
  Inc(FOrder);
  Result.Left := FOrder * 1000;
  Result.OnClick := AHandler;
end;

function TInfoForm.AddLabel(AParent: TWinControl; const ACaption: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Align := alLeft;
  Result.Layout := tlCenter;
  Result.BorderSpacing.Left := 8;
  Result.BorderSpacing.Right := 4;
  Inc(FOrder);
  Result.Left := FOrder * 1000;
end;

function TInfoForm.AddList(AParent: TWinControl): TListView;
begin
  Result := TListView.Create(Self);
  Result.Parent := AParent;
  Result.Align := alClient;
  Result.ViewStyle := vsReport;
  Result.ReadOnly := True;
  Result.RowSelect := True;
  Result.GridLines := True;
end;

procedure TInfoForm.AddCol(LV: TListView; const ACaption: string; AWidth: Integer);
var
  Col: TListColumn;
begin
  Col := LV.Columns.Add;
  Col.Caption := ACaption;
  Col.Width := Scale96ToForm(AWidth);
end;

procedure TInfoForm.BuildUI;
var
  Bar, TopBar: TPanel;
  Tab: TTabSheet;
begin
  { bottom bar with the main window controls }
  Bar := TPanel.Create(Self);
  Bar.Parent := Self;
  Bar.Align := alBottom;
  Bar.Height := Scale96ToForm(36);
  Bar.BevelOuter := bvNone;
  Bar.BorderSpacing.Around := 2;
  FBtnPause := AddButton(Bar, 'Pause', @PauseClick);
  FBtnCaption := AddButton(Bar, 'Hide caption', @CaptionClick);
  AddButton(Bar, 'Save PNG', @SaveClick);
  AddButton(Bar, 'Copy report', @CopyClick);
  AddButton(Bar, 'Close', @CloseClick);
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Bar;
  FStatus.Align := alClient;
  FStatus.Alignment := taRightJustify;
  FStatus.Layout := tlCenter;
  FStatus.BorderSpacing.Right := 8;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  FPages.OnChange := @PageChange;

  { 1 Overview }
  Tab := AddTab('Overview');
  TopBar := AddBar(Tab);
  AddButton(TopBar, 'Refresh', @RefreshClick);
  AddButton(TopBar, 'Copy all', @CopyClick);
  FOverview := TMemo.Create(Self);
  FOverview.Parent := Tab;
  FOverview.Align := alClient;
  FOverview.ReadOnly := True;
  FOverview.ScrollBars := ssBoth;
  FOverview.WordWrap := False;
  FOverview.Font.Name := 'Consolas';
  FOverview.Font.Size := 9;

  { 2 Performance }
  Tab := AddTab('Performance');
  TopBar := AddBar(Tab);
  AddButton(TopBar, 'Reset statistics', @ResetClick);
  FVSyncCheck := TCheckBox.Create(Self);
  FVSyncCheck.Parent := TopBar;
  FVSyncCheck.Caption := 'VSync (V)';
  FVSyncCheck.Align := alLeft;
  FVSyncCheck.BorderSpacing.Left := 12;
  Inc(FOrder);
  FVSyncCheck.Left := FOrder * 1000;
  FVSyncCheck.OnClick := @VSyncClick;
  FPerfBox := TPaintBox.Create(Self);
  FPerfBox.Parent := Tab;
  FPerfBox.Align := alClient;
  FPerfBox.OnPaint := @PerfPaint;

  { 3 Threads }
  Tab := AddTab('Threads');
  TopBar := AddBar(Tab);
  AddLabel(TopBar, 'Worker threads');
  FThreadSpin := TSpinEdit.Create(Self);
  FThreadSpin.Parent := TopBar;
  FThreadSpin.Align := alLeft;
  FThreadSpin.BorderSpacing.Around := 4;
  FThreadSpin.MinValue := 1;
  FThreadSpin.MaxValue := MaxThreads;
  Inc(FOrder);
  FThreadSpin.Left := FOrder * 1000;
  FThreadSpin.OnChange := @ThreadsChange;
  AddLabel(TopBar, 'Bands per thread');
  FBandSpin := TSpinEdit.Create(Self);
  FBandSpin.Parent := TopBar;
  FBandSpin.Align := alLeft;
  FBandSpin.BorderSpacing.Around := 4;
  FBandSpin.MinValue := 1;
  FBandSpin.MaxValue := 16;
  Inc(FOrder);
  FBandSpin.Left := FOrder * 1000;
  FBandSpin.OnChange := @BandsChange;
  FAdaptiveCheck := TCheckBox.Create(Self);
  FAdaptiveCheck.Parent := TopBar;
  FAdaptiveCheck.Caption := 'Adaptive bands';
  FAdaptiveCheck.Align := alLeft;
  FAdaptiveCheck.BorderSpacing.Left := 12;
  Inc(FOrder);
  FAdaptiveCheck.Left := FOrder * 1000;
  FAdaptiveCheck.OnClick := @AdaptiveClick;
  FThreadBox := TPaintBox.Create(Self);
  FThreadBox.Parent := Tab;
  FThreadBox.Align := alClient;
  FThreadBox.OnPaint := @ThreadPaint;

  { 4 Layers }
  Tab := AddTab('Layers');
  TopBar := AddBar(Tab);
  AddButton(TopBar, 'All on', @AllOnClick);
  AddButton(TopBar, 'All off', @AllOffClick);
  AddButton(TopBar, 'Solo selected', @SoloClick);
  FLayerList := AddList(Tab);
  FLayerList.Checkboxes := True;
  AddCol(FLayerList, 'Layer', 120);
  AddCol(FLayerList, 'Kind', 100);
  AddCol(FLayerList, 'Shadow', 56);
  AddCol(FLayerList, 'CPU ms', 70);
  AddCol(FLayerList, 'Share', 56);
  AddCol(FLayerList, 'What it draws', 520);
  FillLayers;
  FLayerList.OnItemChecked := @LayerChecked;

  { 5 Objects }
  Tab := AddTab('Objects');
  FObjList := AddList(Tab);
  AddCol(FObjList, 'Item', 170);
  AddCol(FObjList, 'Value', 190);
  AddCol(FObjList, 'Detail', 380);

  { 6 Palette }
  Tab := AddTab('Palette');
  FPaletteBox := TPaintBox.Create(Self);
  FPaletteBox.Parent := Tab;
  FPaletteBox.Align := alClient;
  FPaletteBox.OnPaint := @PalettePaint;

  { 7 Export }
  BuildExportTab(AddTab('Export'));
end;

{ ---------- layers ---------- }

procedure TInfoForm.FillLayers;
var
  Id: TLayerId;
  It: TListItem;
begin
  FUpdating := True;
  try
    FLayerList.Items.BeginUpdate;
    FLayerList.Items.Clear;
    for Id := Low(TLayerId) to High(TLayerId) do
    begin
      It := FLayerList.Items.Add;
      It.Caption := LayerNames[Id];
      It.SubItems.Add(LayerKinds[Id]);
      if LayerDepth[Id] = 0 then
        It.SubItems.Add('-')
      else
        It.SubItems.Add(FormatFloat('0.##', LayerDepth[Id]));
      It.SubItems.Add('');
      It.SubItems.Add('');
      It.SubItems.Add(LayerNotes[Id]);
      It.Checked := MainForm.Scene.LayerOn[Id];
    end;
    FLayerList.Items.EndUpdate;
  finally
    FUpdating := False;
  end;
end;

procedure TInfoForm.RefreshLayers;
var
  Id: TLayerId;
  It: TListItem;
  Total: Double;
begin
  Total := 0;
  for Id := Low(TLayerId) to High(TLayerId) do
    Total := Total + MainForm.Renderer.LayerCpuMs[Id];
  Total := Max(0.001, Total);
  FUpdating := True;
  try
    for Id := Low(TLayerId) to High(TLayerId) do
    begin
      It := FLayerList.Items[Ord(Id)];
      It.SubItems[2] := FormatFloat('0.00', MainForm.Renderer.LayerCpuMs[Id]);
      It.SubItems[3] := FormatFloat('0', MainForm.Renderer.LayerCpuMs[Id] / Total * 100) + ' %';
      if It.Checked <> MainForm.Scene.LayerOn[Id] then
        It.Checked := MainForm.Scene.LayerOn[Id];
    end;
  finally
    FUpdating := False;
  end;
end;

procedure TInfoForm.LayerChecked(Sender: TObject; Item: TListItem);
begin
  if FUpdating or (Item = nil) then Exit;
  MainForm.Scene.LayerOn[TLayerId(Item.Index)] := Item.Checked;
  MainForm.Redraw;
end;

procedure TInfoForm.AllOnClick(Sender: TObject);
var
  Id: TLayerId;
begin
  for Id := Low(TLayerId) to High(TLayerId) do
    MainForm.Scene.LayerOn[Id] := True;
  RefreshLayers;
  MainForm.Redraw;
end;

procedure TInfoForm.AllOffClick(Sender: TObject);
var
  Id: TLayerId;
begin
  for Id := Low(TLayerId) to High(TLayerId) do
    MainForm.Scene.LayerOn[Id] := False;
  RefreshLayers;
  MainForm.Redraw;
end;

{ Only the selected layer (plus the paper background) stays on. }
procedure TInfoForm.SoloClick(Sender: TObject);
var
  Id: TLayerId;
begin
  if FLayerList.Selected = nil then Exit;
  for Id := Low(TLayerId) to High(TLayerId) do
    MainForm.Scene.LayerOn[Id] := (Ord(Id) = FLayerList.Selected.Index) or (Id = lyBackground);
  RefreshLayers;
  MainForm.Redraw;
end;

{ ---------- objects ---------- }

procedure TInfoForm.RefreshObjects;
var
  Sc: TVolcanoScene;
  R: TFrameRenderer;
  M: TMainForm;

  K: Integer;

  { rows are created once and then only changed text is written }
  procedure Row(const AName, AValue, ADetail: string);
  var
    It: TListItem;
  begin
    if K < FObjList.Items.Count then
      It := FObjList.Items[K]
    else
    begin
      It := FObjList.Items.Add;
      It.SubItems.Add('');
      It.SubItems.Add('');
    end;
    if It.Caption <> AName then It.Caption := AName;
    if It.SubItems[0] <> AValue then It.SubItems[0] := AValue;
    if It.SubItems[1] <> ADetail then It.SubItems[1] := ADetail;
    Inc(K);
  end;

begin
  M := MainForm;
  Sc := M.Scene;
  R := M.Renderer;
  K := 0;
  begin
    Row('Frame (GL client)', Format('%d x %d', [R.Width, R.Height]),
      IfThen(M.FullScreen, 'full screen', 'windowed'));
    Row('Design space', Format('%d x %d', [DesignW, DesignH]), 'size of the reference image');
    Row('Scale', FormatFloat('0.0000', Sc.Scale), 'fit by min(width/736, height/1308)');
    Row('Offset', Format('%s, %s px', [FormatFloat('0', Sc.OffX), FormatFloat('0', Sc.OffY)]),
      'picture is centred in the window');
    Row('Visible x range', Format('%s .. %s', [FormatFloat('0', Sc.VisL), FormatFloat('0', Sc.VisR)]),
      'design px, clouds and birds wrap here');
    Row('Scene time', FormatFloat('0.0', Sc.Time) + ' s', IfThen(M.Paused, 'paused', 'running'));
    Row('Frames presented', IntToStr(M.FrameCount), Format('%d rendered by the pool', [R.Frames]));
    Row('Missed vsync', IntToStr(M.MissedFrames), 'present interval > 1.5 refresh periods');
    Row('Worker threads', IntToStr(R.Threads), Format('%d logical cores in this machine',
      [TThread.ProcessorCount]));
    Row('Bands', Format('%d, about %d px', [R.BandCount, R.BandHeight]),
      Format('%d per thread, taken dynamically', [R.BandsPerThread]));
    Row('Static cut', Ms(Sc.StaticMs), Format('main thread, %d times so far', [Sc.StaticCount]));
    Row('Sprite cut', Ms(R.SpriteMs), Format('%d round sprites on all cores', [Sc.SpriteCount]));
    Row('Sprite memory', KB(Sc.SpriteBytes), 'round + cloud + sea + caption sprites');
    Row('Static bitmaps', KB(Sc.StaticBytes), 'background + cone + cutter layer');
    Row('Band bitmaps', KB(Int64(R.Width) * R.Height * 4), 'one frame, split in bands');
    Row('Smoke puffs', '230', 'depth 0/1/2 = 95/75/60, sorted once per frame');
    Row('Lava blobs', '90', '52 orange + 38 yellow');
    Row('Lava flows', '7', '3 passes each, 41 points per edge');
    Row('Embers / ash / birds', '40 / 60 / 14', '');
    Row('Clouds', '5 far + 3 low', 'far drift and wrap, low bob in place');
    Row('Palms', '6 back + 5 front', '9 fronds each, 12 segments per frond');
    Row('OpenGL vendor', M.GLVendor, '');
    Row('OpenGL renderer', M.GLRenderer, '');
    Row('OpenGL version', M.GLVersion, Format('%d extensions', [M.GLExtCount]));
    Row('Texture', Format('%d x %d BGRA', [M.TexW, M.TexH]),
      'GL_RGBA8, nearest, filled by glTexSubImage2D per band');
    Row('VSync', IfThen(M.VSync, 'on', 'off'), Format('wglSwapIntervalEXT %s, interval now %d',
      [IfThen(M.VSyncSupported, 'found', 'missing'), M.SwapIntervalNow]));
    Row('Display refresh', FormatFloat('0', M.RefreshHz) + ' Hz', 'GetDeviceCaps(VREFRESH)');
    Row('Last pool error', IfThen(R.Pool.LastError = '', '-', R.Pool.LastError), '');
    Row('Last saved PNG', IfThen(M.LastSaved = '', '-', ExtractFileName(M.LastSaved)),
      ExtractFilePath(M.LastSaved));
    Row('Compiler', 'FPC ' + {$I %FPCVERSION%}, {$I %FPCTARGETOS%} + ' / ' + {$I %FPCTARGETCPU%});
    Row('Built', {$I %DATE%} + ' ' + {$I %TIME%}, '');
  end;
end;

{ ---------- overview ---------- }

function TInfoForm.OverviewText: string;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('VOLCANO PAPERCUT - BGRABitmap CPU all cores + OpenGL vsync');
    SL.Add('===========================================================');
    SL.Add('Animated paper-cut volcano island. Every pixel is drawn by BGRABitmap on');
    SL.Add('the CPU, on all cores at once; OpenGL only shows the result, in step with');
    SL.Add('the display (vsync, 60 Hz).');
    SL.Add('');
    SL.Add('FILES');
    SL.Add('  VolcanoGL.lpi        project (BGRABitmapPack, LazOpenGLContext, LCL; -O3)');
    SL.Add('  VolcanoGL.lpr        program; also the --bench command line mode');
    SL.Add('  uvolcanoscene.pas    scene state + static resources (TVolcanoScene),');
    SL.Add('                       band renderer (TPainter, one per worker thread)');
    SL.Add('  urenderpool.pas      worker thread pool with per-job timing');
    SL.Add('  uframerenderer.pas   cuts the frame in bands and renders them on the pool');
    SL.Add('  umainform.pas        OpenGL window and the vsync''ed render loop');
    SL.Add('  uinfoform.pas        this window');
    SL.Add('');
    SL.Add('BUILD AND RUN');
    SL.Add('  IDE:  open VolcanoGL.lpi, press F9');
    SL.Add('  CLI:  C:\lazarus\lazbuild.exe VolcanoGL.lpi');
    SL.Add('  VolcanoGL.exe --bench out.png [width height]');
    SL.Add('        no window: times 60 frames with 1, 2, 4, 6, 8 and all threads,');
    SL.Add('        writes out.txt and saves the last frame');
    SL.Add('');
    SL.Add('EXPORT (tab 7, or E in the main window; --export on the command line)');
    SL.Add('  targets: the main picture and every single layer');
    SL.Add('  PNG first frame (+ optional PNG sequence), animated GIF, H.264 MP4');
    SL.Add('  - own scene + own frame renderer on all physical cores, at any size');
    SL.Add('  - the export scene copies the window''s animation state; every target');
    SL.Add('    replays the same frames with the same random seed, so the files line');
    SL.Add('    up frame for frame and the layers can be stacked again in an editor');
    SL.Add('  - layers: transparent background + their paper shadow (PNG / GIF alpha);');
    SL.Add('    MP4 has no alpha, so layer videos are flattened on white');
    SL.Add('  - MP4 through Windows Media Foundation (GPU encoder, software fallback),');
    SL.Add('    width and height rounded down to even numbers');
    SL.Add('  - the live window pauses while exporting');
    SL.Add('');
    SL.Add('HOTKEYS');
    SL.Add('  Space  pause / resume        V    vsync on / off');
    SL.Add('  F11    full screen           S    save frame as PNG');
    SL.Add('  H      hide / show caption   I, F1  this window (opens by itself at startup)');
    SL.Add('  E      export tab');
    SL.Add('  Esc    leave full screen / quit');
    SL.Add('  in this window: 1..7 switch tabs, Esc closes it');
    SL.Add('');
    SL.Add('RENDER LOOP (Application.OnIdle, main thread)');
    SL.Add('  1. Wait     collect the bands the workers rendered during the last vsync');
    SL.Add('  2. Resize   window size changed -> re-cut static parts, sprites on all cores');
    SL.Add('  3. Upload   glTexSubImage2D, one call per band, straight from the bitmaps');
    SL.Add('              (BGRABitmap rows are bottom-up on Windows = OpenGL order)');
    SL.Add('  4. Update   advance the animation, sort the smoke, start the next frame');
    SL.Add('              on all cores (returns at once)');
    SL.Add('  5. Present  one textured quad + SwapBuffers; with vsync this blocks until');
    SL.Add('              the display refresh while the workers keep rendering');
    SL.Add('  The picture on screen is one frame behind the simulation; in exchange the');
    SL.Add('  whole render time hides behind the vsync wait.');
    SL.Add('');
    SL.Add('MULTI-CORE BANDS');
    SL.Add('  - the frame is cut in (threads x bands per thread) horizontal bands with a');
    SL.Add('    height that is a multiple of 4; workers take the next free band');
    SL.Add('    (interlocked counter), so busy bands (smoke, lava) do not hold others up');
    SL.Add('  - one worker per PHYSICAL core by default (GetLogicalProcessorInformation):');
    SL.Add('    a second hyper-thread on the same core made frames slower, not faster');
    SL.Add('  - adaptive bands: every 20 frames the band borders move half way towards');
    SL.Add('    an equal share of the measured cost (lava and palm rows cost far more');
    SL.Add('    than sky rows), so the frame time follows the average band');
    SL.Add('  - each worker owns a TPainter: its own work layer and shadow buffers');
    SL.Add('  - the work layer covers the band plus a margin above (shadow offset + blur)');
    SL.Add('    and below (blur), aligned to multiples of 4 so every band samples the');
    SL.Add('    same shadow grid: no seams between bands');
    SL.Add('  - shared bitmaps are drawn with BlendBitmap (own code, read-only):');
    SL.Add('    TBGRABitmap.PutImage keeps scan state inside the SOURCE bitmap, so two');
    SL.Add('    threads drawing the same sprite corrupted each other (access violations');
    SL.Add('    that silently killed a worker and froze the pool)');
    SL.Add('  - everything the workers read is cut beforehand (background, cone,');
    SL.Add('    cloud / sea / caption sprites, one round sprite per pixel radius), so');
    SL.Add('    threads never create or change shared objects; text is drawn only on');
    SL.Add('    the main thread (caption, at resize)');
    SL.Add('');
    SL.Add('MEASURED (--bench, 6 physical / 12 logical cores, adaptive bands)');
    SL.Add('  450 x 800     1 thread 24.9 ms   6 threads 7.0 ms  (about 143 fps)');
    SL.Add('  1920 x 1080   1 thread 51.2 ms   6 threads 11.7 ms (about 85 fps)');
    SL.Add('  12 threads (hyper-threading) were slower than 6 at both sizes');
    SL.Add('');
    SL.Add('ONE LAYER IN ONE BAND');
    SL.Add('  BeginLayer -> draw the layer clipped to the work layer -> CompositeLayer:');
    SL.Add('    alpha sampled every 4th px (x 110/255), box blur twice (r = 7*depth/4),');
    SL.Add('    bilinear stretch, offset (3, 6) * depth, darken, blend the layer on top;');
    SL.Add('    only the bounding box of what the layer holds is touched');
    SL.Add('');
    SL.Add('ADDING A LAYER');
    SL.Add('  1. add an id to TLayerId and its LayerNames / LayerKinds / LayerDepth /');
    SL.Add('     LayerNotes entries');
    SL.Add('  2. write TPainter.DrawXxx in design coordinates (P(), S(), Circle, Sprite)');
    SL.Add('     reading only scene data that the main thread prepared');
    SL.Add('  3. in TPainter.RenderBand: BeginLayer; DrawXxx;');
    SL.Add('     CompositeLayer(Dest, ATop, LayerDepth[id]); Mark(id)');
    SL.Add('  4. if it casts a deeper shadow than MaxDepth, raise MaxDepth');
    SL.Add('');
    SL.Add('CURRENT PARAMETERS');
    SL.Add('==================');
    SL.Add(MainForm.Scene.DescribeParams);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TInfoForm.RefreshOverview;
var
  P: TPoint;
begin
  P := FOverview.CaretPos;
  FOverview.Lines.Text := OverviewText;
  FOverview.CaretPos := P;
end;

function TInfoForm.ReportText: string;
var
  Id: TLayerId;
  SL: TStringList;
  I: Integer;
  R: TFrameRenderer;
begin
  R := MainForm.Renderer;
  SL := TStringList.Create;
  try
    SL.Text := OverviewText;
    SL.Add('LIVE PERFORMANCE');
    SL.Add(Format('  fps %s, refresh %s Hz, vsync %s, missed %d',
      [FormatFloat('0.0', MainForm.Fps), FormatFloat('0', MainForm.RefreshHz),
      IfThen(MainForm.VSync, 'on', 'off'), MainForm.MissedFrames]));
    SL.Add(Format('  render wall %s, cpu %s (%d threads, %d bands)', [Ms(R.WallSmooth),
      Ms(R.CpuSmooth), R.Threads, R.BandCount]));
    SL.Add(Format('  upload %s, swap %s, wait %s', [Ms(MainForm.LastUploadMs),
      Ms(MainForm.LastSwapMs), Ms(MainForm.LastWaitMs)]));
    for Id := Low(TLayerId) to High(TLayerId) do
      SL.Add(Format('  %-14s %9s cpu  %s', [LayerNames[Id], Ms(R.LayerCpuMs[Id]),
        IfThen(MainForm.Scene.LayerOn[Id], 'on', 'OFF')]));
    SL.Add('');
    SL.Add('WORKERS (last frame)');
    for I := 0 to R.Threads - 1 do
      SL.Add(Format('  worker %2d  %9s  %d bands', [I, Ms(R.WorkerMs[I]), R.WorkerJobs[I]]));
    SL.Add('');
    SL.Add('OBJECTS');
    RefreshObjects;
    for I := 0 to FObjList.Items.Count - 1 do
      with FObjList.Items[I] do
        SL.Add(Format('  %-20s %-26s %s', [Caption, SubItems[0], SubItems[1]]));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ ---------- performance ---------- }

{ The live panels are drawn with plain GDI on a back buffer: the info window
  runs on the same thread as the render loop, so its paint must stay well
  under a millisecond or it would cost vsync frames. }

function TInfoForm.Buffer(ABox: TPaintBox): TCanvas;
begin
  if FBuf = nil then FBuf := TBitmap.Create;
  if (FBuf.Width <> ABox.Width) or (FBuf.Height <> ABox.Height) then
    FBuf.SetSize(Max(1, ABox.Width), Max(1, ABox.Height));
  Result := FBuf.Canvas;
  Result.Brush.Color := RGBToColor(250, 250, 248);
  Result.FillRect(0, 0, FBuf.Width, FBuf.Height);
  Result.Font.Name := 'Segoe UI';
  Result.Font.Height := -Scale96ToForm(14);
  Result.Font.Color := RGBToColor(40, 40, 40);
  Result.Brush.Style := bsClear;
end;

procedure TInfoForm.PerfPaint(Sender: TObject);
const
  Pad = 12;
var
  C: TCanvas;
  M: TMainForm;
  R: TFrameRenderer;
  W, H, Y, I, K, GX, GY, GW, GH, LH, N, X: Integer;
  MaxV, V, Period, SumI, MaxI, SumR, MaxR: Double;
  Pts: array[0..HistLen - 1] of TPoint;

  procedure Line(const S: string; Bold: Boolean = False);
  begin
    if Bold then C.Font.Style := [fsBold] else C.Font.Style := [];
    C.TextOut(Pad, Y, S);
    Inc(Y, LH);
  end;

  procedure Plot(const A: array of Single; Color: TColor);
  var
    J, Idx: Integer;
  begin
    for J := 0 to HistLen - 1 do
    begin
      Idx := (M.HistPos + J) mod HistLen;  // oldest first
      Pts[J] := Point(GX + Round(J / (HistLen - 1) * GW),
        GY + GH - Round(Min(A[Idx], MaxV) / MaxV * GH));
    end;
    C.Pen.Color := Color;
    C.Pen.Width := 2;
    C.Polyline(Pts);
  end;

  procedure Legend(const S: string; Color: TColor);
  begin
    C.Brush.Style := bsSolid;
    C.Brush.Color := Color;
    C.FillRect(X, Y + 5, X + 14, Y + LH - 6);
    C.Brush.Style := bsClear;
    C.TextOut(X + 18, Y, S);
    X := X + 26 + C.TextWidth(S);
  end;

begin
  M := MainForm;
  R := M.Renderer;
  W := FPerfBox.Width;
  H := FPerfBox.Height;
  if (W < 10) or (H < 10) then Exit;
  C := Buffer(FPerfBox);
  LH := Scale96ToForm(19);
  Period := 1000 / Max(1, M.RefreshHz);

  SumI := 0; MaxI := 0; SumR := 0; MaxR := 0; N := 0;
  for I := 0 to HistLen - 1 do
    if M.IntervalHist[I] > 0 then
    begin
      SumI := SumI + M.IntervalHist[I];
      MaxI := Max(MaxI, M.IntervalHist[I]);
      SumR := SumR + M.RenderHist[I];
      MaxR := Max(MaxR, M.RenderHist[I]);
      Inc(N);
    end;
  Y := Pad;
  Line('LIVE PERFORMANCE', True);
  Line(Format('FPS %s   display %s Hz (%s per frame)   vsync %s   missed frames %d',
    [FormatFloat('0.0', M.Fps), FormatFloat('0', M.RefreshHz), Ms(Period),
    IfThen(M.VSync, 'ON', 'off'), M.MissedFrames]));
  if N > 0 then
    Line(Format('Present interval avg %s  max %s     Render (all cores) avg %s  max %s',
      [Ms(SumI / N), Ms(MaxI), Ms(SumR / N), Ms(MaxR)]));
  Line(Format('Render wall %s   CPU %s   speed-up %sx on %d threads   headroom %s',
    [Ms(R.WallSmooth), Ms(R.CpuSmooth), FormatFloat('0.0', R.CpuSmooth / Max(0.01, R.WallSmooth)),
    R.Threads, Ms(Period - R.WallSmooth)]));
  Line(Format('Main thread: wait %s   upload %s   update+sort %s   draw+swap %s   info paint %s',
    [Ms(M.LastWaitMs), Ms(M.LastUploadMs), Ms(M.LastUpdateMs), Ms(M.LastSwapMs), Ms(FPaintMs)]));
  Line(Format('Frame %d x %d in %d bands (%s)   theoretical max %s fps',
    [R.Width, R.Height, R.BandCount, IfThen(R.Adaptive, 'adaptive', 'equal'),
    FormatFloat('0', 1000 / Max(0.01, R.WallSmooth))]));
  Inc(Y, LH div 2);

  Line('Frame history (last ' + IntToStr(HistLen) + ' presents, ms)', True);
  X := Pad;
  C.Font.Style := [];
  Legend('present interval', RGBToColor(40, 110, 210));
  Legend('render wall', RGBToColor(240, 120, 30));
  Legend('main waits for workers', RGBToColor(210, 40, 40));
  Legend('upload', RGBToColor(40, 160, 80));
  Inc(Y, LH);
  GX := Pad + Scale96ToForm(36);
  GY := Y;
  GW := W - GX - Pad;
  GH := Max(80, H - Y - Pad);
  C.Brush.Style := bsSolid;
  C.Brush.Color := clWhite;
  C.Pen.Color := RGBToColor(200, 200, 200);
  C.Pen.Width := 1;
  C.Rectangle(GX, GY, GX + GW, GY + GH);
  C.Brush.Style := bsClear;
  MaxV := Max(Period * 2.2, 10);
  for I := 0 to HistLen - 1 do
    MaxV := Max(MaxV, Min(M.IntervalHist[I], 200) * 1.1);
  C.Font.Height := -Scale96ToForm(11);
  C.Font.Color := RGBToColor(110, 110, 110);
  for K := 0 to 3 do
  begin
    case K of
      0: V := 0;
      1: V := Period;
      2: V := Period * 2;
    else
      V := MaxV;
    end;
    if (K = 3) or (V < MaxV) then
    begin
      I := GY + GH - Round(V / MaxV * GH);
      C.Pen.Color := RGBToColor(200, 200, 200);
      C.Line(GX, I, GX + GW, I);
      C.TextOut(Pad, I - Scale96ToForm(7), FormatFloat('0.0', V));
    end;
  end;
  Plot(M.UploadHist, RGBToColor(40, 160, 80));
  Plot(M.WaitHist, RGBToColor(210, 40, 40));
  Plot(M.RenderHist, RGBToColor(240, 120, 30));
  Plot(M.IntervalHist, RGBToColor(40, 110, 210));
  FPerfBox.Canvas.Draw(0, 0, FBuf);
end;

{ ---------- threads ---------- }

procedure TInfoForm.ThreadPaint(Sender: TObject);
const
  Pad = 12;
var
  C: TCanvas;
  R: TFrameRenderer;
  W, H, Y, I, LH, BarX, BarW, BH: Integer;
  MaxV, Util: Double;

  procedure Line(const S: string; Bold: Boolean = False);
  begin
    if Bold then C.Font.Style := [fsBold] else C.Font.Style := [];
    C.TextOut(Pad, Y, S);
    Inc(Y, LH);
  end;

  procedure Bar(V: Double; Color: TColor);
  begin
    C.Brush.Style := bsSolid;
    C.Brush.Color := Color;
    C.FillRect(BarX, Y + 2, BarX + Max(1, Round(V / MaxV * BarW)), Y + BH - 2);
    C.Brush.Style := bsClear;
  end;

begin
  R := MainForm.Renderer;
  W := FThreadBox.Width;
  H := FThreadBox.Height;
  if (W < 10) or (H < 10) then Exit;
  C := Buffer(FThreadBox);
  LH := Scale96ToForm(19);
  Util := R.CpuSmooth / Max(0.01, R.WallSmooth * R.Threads) * 100;
  Y := Pad;
  Line('WORK SPLIT (last frame)', True);
  Line(Format('%d workers (%d physical / %d logical cores), %d bands, wall %s, CPU %s, utilisation %s %%',
    [R.Threads, PhysicalCores, TThread.ProcessorCount, R.BandCount, Ms(R.RenderWallMs),
    Ms(R.RenderCpuMs), FormatFloat('0', Util)]));
  Line(Format('Adaptive bands %s: every %d frames the borders move so every band costs about', [
    IfThen(R.Adaptive, 'ON', 'off'), BalanceEvery]));
  Line(Format('the same (%d rebalances so far). Colour = worker.', [R.Rebalances]));
  Inc(Y, LH div 2);

  Line('Workers', True);
  BarX := Pad + Scale96ToForm(80);
  BarW := W - BarX - Pad - Scale96ToForm(140);
  MaxV := 0.1;
  for I := 0 to R.Threads - 1 do
    MaxV := Max(MaxV, R.WorkerMs[I]);
  BH := Max(8, Min(LH, (H div 2 - Y) div Max(1, R.Threads)));
  for I := 0 to R.Threads - 1 do
  begin
    C.Font.Style := [];
    C.TextOut(Pad, Y, 'worker ' + IntToStr(I));
    Bar(R.WorkerMs[I], WorkerColor(I));
    C.TextOut(BarX + Round(R.WorkerMs[I] / MaxV * BarW) + 6, Y,
      Format('%s  (%d bands)', [Ms(R.WorkerMs[I]), R.WorkerJobs[I]]));
    Inc(Y, BH);
  end;
  Inc(Y, LH div 2);

  Line('Bands (top of the frame first): rows, cost, worker', True);
  MaxV := 0.1;
  for I := 0 to R.BandCount - 1 do
    MaxV := Max(MaxV, R.BandMs[I]);
  BH := Max(4, Min(LH, (H - Y - Pad) div Max(1, R.BandCount)));
  for I := 0 to R.BandCount - 1 do
  begin
    if Y + BH > H then Break;
    C.Font.Style := [];
    if BH >= 12 then
      C.TextOut(Pad, Y, Format('%d+%d', [R.BandTops[I], R.Bands[I].Height]));
    Bar(R.BandMs[I], WorkerColor(R.BandWorker[I]));
    if BH >= 12 then
      C.TextOut(BarX + Round(R.BandMs[I] / MaxV * BarW) + 6, Y,
        Format('%s  w%d', [Ms(R.BandMs[I]), R.BandWorker[I]]));
    Inc(Y, BH);
  end;
  FThreadBox.Canvas.Draw(0, 0, FBuf);
end;

procedure TInfoForm.AdaptiveClick(Sender: TObject);
begin
  if FUpdating then Exit;
  MainForm.SetAdaptive(FAdaptiveCheck.Checked);
end;

procedure TInfoForm.ThreadsChange(Sender: TObject);
begin
  if FUpdating then Exit;
  MainForm.SetThreads(FThreadSpin.Value);
end;

procedure TInfoForm.BandsChange(Sender: TObject);
begin
  if FUpdating then Exit;
  MainForm.SetBandsPerThread(FBandSpin.Value);
end;

procedure TInfoForm.VSyncClick(Sender: TObject);
begin
  if FUpdating then Exit;
  MainForm.VSync := FVSyncCheck.Checked;
  MainForm.ResetStats;
end;

procedure TInfoForm.ResetClick(Sender: TObject);
begin
  MainForm.ResetStats;
end;

{ ---------- palette ---------- }

procedure TInfoForm.PalettePaint(Sender: TObject);
var
  B: TBGRABitmap;
  I, Cols, CW, RH, X, Y, Sw: Integer;
  C: TBGRAPixel;
begin
  if (FPaletteBox.Width < 10) or (FPaletteBox.Height < 10) then Exit;
  B := TBGRABitmap.Create(FPaletteBox.Width, FPaletteBox.Height, BGRA(250, 250, 248));
  try
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;
    B.FontHeight := Scale96ToForm(14);
    Cols := Max(1, FPaletteBox.Width div Scale96ToForm(240));
    CW := FPaletteBox.Width div Cols;
    RH := Scale96ToForm(44);
    Sw := Scale96ToForm(34);
    for I := 0 to High(PaletteNames) do
    begin
      X := (I mod Cols) * CW + Scale96ToForm(12);
      Y := (I div Cols) * RH + Scale96ToForm(12);
      C := StrToBGRA(PaletteHex[I]);
      B.FillRoundRectAntialias(X + 2, Y + 4, X + Sw + 2, Y + Sw + 4, 5, 5, BGRA(0, 0, 0, 40));
      B.FillRoundRectAntialias(X, Y, X + Sw, Y + Sw, 5, 5, C);
      B.RoundRectAntialias(X, Y, X + Sw, Y + Sw, 5, 5, BGRA(30, 30, 30), 1);
      B.FontStyle := [fsBold];
      B.TextOut(X + Sw + 10, Y, PaletteNames[I], BGRA(40, 40, 40));
      B.FontStyle := [];
      B.TextOut(X + Sw + 10, Y + Scale96ToForm(17),
        Format('%s   rgb %d, %d, %d', [PaletteHex[I], C.red, C.green, C.blue]), BGRA(100, 100, 100));
    end;
    B.Draw(FPaletteBox.Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

{ ---------- live refresh ---------- }

procedure TInfoForm.RefreshControls;
begin
  FUpdating := True;
  try
    if MainForm.Paused then FBtnPause.Caption := 'Resume' else FBtnPause.Caption := 'Pause';
    if MainForm.Scene.ShowCaption then FBtnCaption.Caption := 'Hide caption'
    else FBtnCaption.Caption := 'Show caption';
    if FVSyncCheck.Checked <> MainForm.VSync then FVSyncCheck.Checked := MainForm.VSync;
    if not FThreadSpin.Focused then FThreadSpin.Value := MainForm.Renderer.Threads;
    if not FBandSpin.Focused then FBandSpin.Value := MainForm.Renderer.BandsPerThread;
    if FAdaptiveCheck.Checked <> MainForm.Renderer.Adaptive then
      FAdaptiveCheck.Checked := MainForm.Renderer.Adaptive;
    FStatus.Caption := Format('%s fps   vsync %s   render %s on %d threads',
      [FormatFloat('0.0', MainForm.Fps), IfThen(MainForm.VSync, 'on', 'off'),
      Ms(MainForm.Renderer.WallSmooth), MainForm.Renderer.Threads]);
  finally
    FUpdating := False;
  end;
end;

procedure TInfoForm.TimerTick(Sender: TObject);
var
  T0: Double;
begin
  if not Visible then Exit;
  RefreshControls;
  T0 := HiResMs;
  case FPages.ActivePageIndex of
    1: FPerfBox.Repaint;
    2: FThreadBox.Repaint;
    3: RefreshLayers;
    4: RefreshObjects;
  end;
  FPaintMs := HiResMs - T0;
end;

procedure TInfoForm.PageChange(Sender: TObject);
begin
  case FPages.ActivePageIndex of
    0: RefreshOverview;
    3: RefreshLayers;
    4: RefreshObjects;
  end;
end;

{ ---------- buttons ---------- }

procedure TInfoForm.PauseClick(Sender: TObject);
begin
  MainForm.Paused := not MainForm.Paused;
  RefreshControls;
end;

procedure TInfoForm.CaptionClick(Sender: TObject);
begin
  MainForm.ToggleCaption;
  RefreshControls;
end;

procedure TInfoForm.SaveClick(Sender: TObject);
begin
  MainForm.RequestSave;
  FStatus.Caption := 'saving on the next frame...';
end;

procedure TInfoForm.CopyClick(Sender: TObject);
begin
  Clipboard.AsText := ReportText;
  FStatus.Caption := 'report copied to the clipboard';
end;

procedure TInfoForm.RefreshClick(Sender: TObject);
begin
  RefreshOverview;
end;

{ ---------- export ---------- }

function TInfoForm.AddSpin(AParent: TWinControl; AMin, AMax, AValue: Integer): TSpinEdit;
begin
  Result := TSpinEdit.Create(Self);
  Result.Parent := AParent;
  Result.Align := alLeft;
  Result.BorderSpacing.Around := 4;
  Result.MinValue := AMin;
  Result.MaxValue := AMax;
  Result.Value := AValue;
  Result.Width := Scale96ToForm(70);
  Inc(FOrder);
  Result.Left := FOrder * 1000;
  Result.OnChange := @ExpEstimate;
end;

function TInfoForm.AddCheck(AParent: TWinControl; const ACaption: string;
  AChecked: Boolean): TCheckBox;
begin
  Result := TCheckBox.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Checked := AChecked;
  Result.Align := alLeft;
  Result.BorderSpacing.Left := 8;
  Result.BorderSpacing.Right := 4;
  Inc(FOrder);
  Result.Left := FOrder * 1000;
  Result.OnClick := @ExpEstimate;
end;

procedure TInfoForm.BuildExportTab(Tab: TTabSheet);
var
  Bar: TPanel;
  Id: TLayerId;
  Why: string;
begin
  { folder }
  Bar := AddBar(Tab);
  AddLabel(Bar, 'Folder');
  FExpFolder := TDirectoryEdit.Create(Self);
  FExpFolder.Parent := Bar;
  FExpFolder.Align := alClient;
  FExpFolder.BorderSpacing.Around := 4;
  FExpFolder.Text := ExtractFilePath(ParamStr(0)) + 'export';
  AddButton(Bar, 'Open', @ExpOpenFolder).Align := alRight;

  { size }
  Bar := AddBar(Tab);
  AddLabel(Bar, 'Size');
  FExpW := AddSpin(Bar, 16, 7680, 450);
  AddLabel(Bar, 'x');
  FExpH := AddSpin(Bar, 16, 4320, 800);
  AddButton(Bar, 'Window size', @ExpWindowSize);
  AddButton(Bar, 'Half', @ExpHalfSize);

  { time }
  Bar := AddBar(Tab);
  AddLabel(Bar, 'Frames');
  FExpFrames := AddSpin(Bar, 1, 100000, 120);
  AddLabel(Bar, 'FPS');
  FExpFps := AddSpin(Bar, 1, 120, 30);
  AddLabel(Bar, 'MP4 kbps');
  FExpKbps := AddSpin(Bar, 500, 200000, 12000);
  FExpKbps.Width := Scale96ToForm(80);

  { formats }
  Bar := AddBar(Tab);
  AddLabel(Bar, 'Formats');
  FExpPng := AddCheck(Bar, 'PNG (first frame)', True);
  FExpSeq := AddCheck(Bar, 'PNG sequence', False);
  FExpGif := AddCheck(Bar, 'GIF', True);
  FExpMp4 := AddCheck(Bar, 'MP4', True);
  FExpHw := AddCheck(Bar, 'GPU encoder', True);
  if not MP4Available(Why) then
  begin
    FExpMp4.Checked := False;
    FExpMp4.Enabled := False;
    FExpMp4.Hint := Why;
    FExpMp4.ShowHint := True;
  end;

  { targets }
  Bar := AddBar(Tab);
  AddLabel(Bar, 'Targets');
  AddButton(Bar, 'Main only', @ExpMainOnly);
  AddButton(Bar, 'Main + all layers', @ExpAllTargets);
  AddButton(Bar, 'None', @ExpNoTargets);
  FExpTargets := TCheckListBox.Create(Self);
  FExpTargets.Parent := Tab;
  FExpTargets.Align := alTop;
  FExpTargets.Height := Scale96ToForm(170);
  Inc(FOrder);
  FExpTargets.Top := FOrder * 1000;
  FExpTargets.Columns := 2;
  FExpTargets.Items.Add(TargetName(TargetMain));
  for Id := Low(TLayerId) to High(TLayerId) do
    FExpTargets.Items.Add(TargetName(Ord(Id)));
  FExpTargets.Checked[0] := True;
  FExpTargets.OnClickCheck := @ExpEstimate;

  { run }
  Bar := AddBar(Tab);
  FExpRun := AddButton(Bar, 'Export', @ExpRunClick);
  FExpCancel := AddButton(Bar, 'Cancel', @ExpCancelClick);
  FExpCancel.Enabled := False;
  FExpInfo := AddLabel(Bar, '');
  FExpInfo.Align := alClient;
  FExpProgress := TProgressBar.Create(Self);
  FExpProgress.Parent := Tab;
  FExpProgress.Align := alTop;
  FExpProgress.Height := Scale96ToForm(18);
  FExpProgress.BorderSpacing.Around := 4;
  Inc(FOrder);
  FExpProgress.Top := FOrder * 1000;

  FExpLog := TMemo.Create(Self);
  FExpLog.Parent := Tab;
  FExpLog.Align := alClient;
  FExpLog.ReadOnly := True;
  FExpLog.ScrollBars := ssBoth;
  FExpLog.WordWrap := False;
  FExpLog.Font.Name := 'Consolas';
  FExpLog.Font.Size := 9;
  FExpLog.Lines.Add('Layers are exported alone on a transparent background with their paper');
  FExpLog.Lines.Add('shadow (PNG / GIF keep the alpha; MP4 is flattened on white).');
  FExpLog.Lines.Add('All targets replay the same frames, so they stack frame for frame.');
  FExpLog.Lines.Add('The live window pauses while exporting.');
end;

{ files and a rough time estimate from the measured render speed }
procedure TInfoForm.ExpEstimate(Sender: TObject);
var
  I, N, Files: Integer;
  PerFrame: Double;
begin
  if FExpInfo = nil then Exit;
  N := 0;
  for I := 0 to FExpTargets.Count - 1 do
    if FExpTargets.Checked[I] then Inc(N);
  Files := N * (Ord(FExpPng.Checked) + Ord(FExpGif.Checked) + Ord(FExpMp4.Checked and FExpMp4.Enabled))
    + Ord(FExpSeq.Checked) * N * FExpFrames.Value;
  // render time scales with the pixel count of the live frame
  PerFrame := MainForm.Renderer.WallSmooth * (FExpW.Value * FExpH.Value) /
    Max(1, MainForm.Renderer.Width * MainForm.Renderer.Height) + 1;
  FExpInfo.Caption := Format('%d targets, %d files, %s s of animation, about %s s to render',
    [N, Files, FormatFloat('0.0', FExpFrames.Value / Max(1, FExpFps.Value)),
    FormatFloat('0', N * FExpFrames.Value * PerFrame / 1000)]);
end;

procedure TInfoForm.ExpWindowSize(Sender: TObject);
begin
  FExpW.Value := MainForm.Renderer.Width;
  FExpH.Value := MainForm.Renderer.Height;
end;

procedure TInfoForm.ExpHalfSize(Sender: TObject);
begin
  FExpW.Value := Max(16, FExpW.Value div 2);
  FExpH.Value := Max(16, FExpH.Value div 2);
end;

procedure TInfoForm.ExpAllTargets(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to FExpTargets.Count - 1 do
    FExpTargets.Checked[I] := True;
  ExpEstimate(nil);
end;

procedure TInfoForm.ExpNoTargets(Sender: TObject);
var
  I: Integer;
begin
  for I := 0 to FExpTargets.Count - 1 do
    FExpTargets.Checked[I] := False;
  ExpEstimate(nil);
end;

procedure TInfoForm.ExpMainOnly(Sender: TObject);
begin
  ExpNoTargets(nil);
  FExpTargets.Checked[0] := True;
  ExpEstimate(nil);
end;

procedure TInfoForm.ExpOpenFolder(Sender: TObject);
begin
  ForceDirectories(FExpFolder.Text);
  OpenDocument(FExpFolder.Text);
end;

procedure TInfoForm.ExpCancelClick(Sender: TObject);
begin
  FExpCancelled := True;
end;

procedure TInfoForm.ExpProgressCb(const AMessage: string; ADone, ATotal: Integer;
  var ACancel: Boolean);
begin
  FExpProgress.Max := Max(1, ATotal);
  FExpProgress.Position := ADone;
  FExpInfo.Caption := AMessage;
  if (Pos('rendering', AMessage) = 1) or (Pos('writing', AMessage) = 1) or
    (Pos('ERROR', AMessage) = 1) then
    FExpLog.Lines.Add(AMessage);
  Application.ProcessMessages;  // keeps the window alive; the live loop is paused
  ACancel := FExpCancelled;
end;

procedure TInfoForm.ExpRunClick(Sender: TObject);
var
  Opt: TExportOptions;
  Res: TExportResult;
  I: Integer;
begin
  if FExpBusy then Exit;
  Opt := DefaultExportOptions(FExpW.Value, FExpH.Value);
  Opt.Folder := FExpFolder.Text;
  Opt.Frames := FExpFrames.Value;
  Opt.Fps := FExpFps.Value;
  Opt.Png := FExpPng.Checked;
  Opt.PngSequence := FExpSeq.Checked;
  Opt.Gif := FExpGif.Checked;
  Opt.Mp4 := FExpMp4.Checked and FExpMp4.Enabled;
  Opt.Mp4Kbps := FExpKbps.Value;
  Opt.Mp4Hardware := FExpHw.Checked;
  Opt.Targets := [];
  for I := 0 to FExpTargets.Count - 1 do
    if FExpTargets.Checked[I] then
      Opt.Targets := Concat(Opt.Targets, [I - 1]);  // item 0 = main = -1
  if Length(Opt.Targets) = 0 then
  begin
    FExpLog.Lines.Add('Nothing to export: tick at least one target.');
    Exit;
  end;
  if not (Opt.Png or Opt.PngSequence or Opt.Gif or Opt.Mp4) then
  begin
    FExpLog.Lines.Add('Nothing to export: tick at least one format.');
    Exit;
  end;

  FExpBusy := True;
  FExpCancelled := False;
  FExpRun.Enabled := False;
  FExpCancel.Enabled := True;
  MainForm.Exporting := True;
  MainForm.Renderer.Wait;
  FExpLog.Lines.Add('');
  FExpLog.Lines.Add(Format('== export %d x %d, %d frames at %d fps, %d targets -> %s',
    [Opt.Width, Opt.Height, Opt.Frames, Opt.Fps, Length(Opt.Targets), Opt.Folder]));
  try
    Res := RunExport(MainForm.Scene, Opt, @ExpProgressCb);
    try
      FExpLog.Lines.AddStrings(Res.Files);
      FExpLog.Lines.Add(Format('== %s: %d frames rendered in %s s, %d errors',
        [IfThen(Res.Cancelled, 'cancelled', 'done'), Res.FramesRendered,
        FormatFloat('0.0', Res.Ms / 1000), Res.Errors.Count]));
      FExpLog.Lines.AddStrings(Res.Errors);
    finally
      Res.Files.Free;
      Res.Errors.Free;
    end;
  except
    on E: Exception do
      FExpLog.Lines.Add('== export failed: ' + E.Message);
  end;
  MainForm.Exporting := False;
  MainForm.Redraw;
  FExpBusy := False;
  FExpRun.Enabled := True;
  FExpCancel.Enabled := False;
  FExpInfo.Caption := '';
end;

procedure TInfoForm.ShowExportTab;
begin
  FPages.ActivePageIndex := TabCount - 1;
  if FExpW.Value = 450 then ExpWindowSize(nil);
  ExpEstimate(nil);
end;

procedure TInfoForm.CloseClick(Sender: TObject);
begin
  Hide;
end;

procedure TInfoForm.FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Hide;
    Key := 0;
  end
  else if (Key >= VK_1) and (Key < VK_1 + TabCount) and (Shift = []) and
    not (ActiveControl is TSpinEdit) then
  begin
    FPages.ActivePageIndex := Key - VK_1;
    PageChange(FPages);
    Key := 0;
  end;
end;

end.
