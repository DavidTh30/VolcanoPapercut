unit uInfoForm;

{ Developer information window (I or F1 in the main window).
  Tabs: Overview (project, pipeline and a full parameter dump), Performance
  (live frame times, history graph, cost per layer), Layers (switch single layers
  on/off with their live cost), Objects (live counts, sizes and memory) and
  Palette (every colour used, with its hex code). Built in code, no .lfm. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, StrUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, ComCtrls,
  Clipbrd, LCLType, BGRABitmap, BGRABitmapTypes, uVolcanoScene;

type

  { TInfoForm }

  TInfoForm = class(TForm)
  private
    FPages: TPageControl;
    FOverview: TMemo;
    FPerfBox: TPaintBox;
    FLayerList: TListView;
    FObjList: TListView;
    FPaletteBox: TPaintBox;
    FBtnPause, FBtnCaption: TButton;
    FStatus: TLabel;
    FTimer: TTimer;
    FUpdating: Boolean;
    FOrder: Integer;  // increasing Left so left-aligned buttons keep creation order
    function AddTab(const ACaption: string): TTabSheet;
    function AddButton(AParent: TWinControl; const ACaption: string;
      AHandler: TNotifyEvent): TButton;
    procedure BuildUI;
    procedure FillLayers;
    procedure RefreshLayers;
    procedure RefreshObjects;
    procedure RefreshOverview;
    procedure RefreshButtons;
    function OverviewText: string;
    function ReportText: string;
    procedure TimerTick(Sender: TObject);
    procedure PageChange(Sender: TObject);
    procedure PerfPaint(Sender: TObject);
    procedure PalettePaint(Sender: TObject);
    procedure LayerChecked(Sender: TObject; Item: TListItem);
    procedure AllOnClick(Sender: TObject);
    procedure AllOffClick(Sender: TObject);
    procedure SoloClick(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure CaptionClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  InfoForm: TInfoForm;

implementation

uses
  uMainForm;

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

{ TInfoForm }

constructor TInfoForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Volcano Papercut - Developer info';
  Width := Scale96ToForm(760);
  Height := Scale96ToForm(800);
  Position := poDesigned;
  KeyPreview := True;
  OnKeyDown := @FormKey;
  BuildUI;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 250;
  FTimer.OnTimer := @TimerTick;
  RefreshOverview;
end;

function TInfoForm.AddTab(const ACaption: string): TTabSheet;
begin
  Result := FPages.AddTabSheet;
  Result.Caption := ACaption;
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
  Result.Left := FOrder * 1000;  // keep creation order when aligned left
  Result.OnClick := AHandler;
end;

procedure TInfoForm.BuildUI;
var
  Bar, TopBar: TPanel;
  Tab: TTabSheet;
  Col: TListColumn;

  procedure AddCol(LV: TListView; const ACaption: string; AWidth: Integer);
  begin
    Col := LV.Columns.Add;
    Col.Caption := ACaption;
    Col.Width := Scale96ToForm(AWidth);
  end;

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

  { Overview }
  Tab := AddTab('Overview');
  TopBar := TPanel.Create(Self);
  TopBar.Parent := Tab;
  TopBar.Align := alTop;
  TopBar.Height := Scale96ToForm(34);
  TopBar.BevelOuter := bvNone;
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

  { Performance }
  Tab := AddTab('Performance');
  FPerfBox := TPaintBox.Create(Self);
  FPerfBox.Parent := Tab;
  FPerfBox.Align := alClient;
  FPerfBox.OnPaint := @PerfPaint;

  { Layers }
  Tab := AddTab('Layers');
  TopBar := TPanel.Create(Self);
  TopBar.Parent := Tab;
  TopBar.Align := alTop;
  TopBar.Height := Scale96ToForm(34);
  TopBar.BevelOuter := bvNone;
  AddButton(TopBar, 'All on', @AllOnClick);
  AddButton(TopBar, 'All off', @AllOffClick);
  AddButton(TopBar, 'Solo selected', @SoloClick);
  FLayerList := TListView.Create(Self);
  FLayerList.Parent := Tab;
  FLayerList.Align := alClient;
  FLayerList.ViewStyle := vsReport;
  FLayerList.Checkboxes := True;
  FLayerList.ReadOnly := True;
  FLayerList.RowSelect := True;
  FLayerList.GridLines := True;
  AddCol(FLayerList, 'Layer', 120);
  AddCol(FLayerList, 'Kind', 100);
  AddCol(FLayerList, 'Shadow', 56);
  AddCol(FLayerList, 'ms / frame', 76);
  AddCol(FLayerList, 'Share', 56);
  AddCol(FLayerList, 'What it draws', 520);
  FillLayers;
  FLayerList.OnItemChecked := @LayerChecked;

  { Objects }
  Tab := AddTab('Objects');
  FObjList := TListView.Create(Self);
  FObjList.Parent := Tab;
  FObjList.Align := alClient;
  FObjList.ViewStyle := vsReport;
  FObjList.ReadOnly := True;
  FObjList.RowSelect := True;
  FObjList.GridLines := True;
  AddCol(FObjList, 'Item', 170);
  AddCol(FObjList, 'Value', 150);
  AddCol(FObjList, 'Detail', 400);

  { Palette }
  Tab := AddTab('Palette');
  FPaletteBox := TPaintBox.Create(Self);
  FPaletteBox.Parent := Tab;
  FPaletteBox.Align := alClient;
  FPaletteBox.OnPaint := @PalettePaint;
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
  Total := Max(0.001, MainForm.Scene.RenderMs);
  FUpdating := True;
  try
    for Id := Low(TLayerId) to High(TLayerId) do
    begin
      It := FLayerList.Items[Ord(Id)];
      It.SubItems[2] := FormatFloat('0.00', MainForm.Scene.LayerMs[Id]);
      It.SubItems[3] := FormatFloat('0', MainForm.Scene.LayerMs[Id] / Total * 100) + ' %';
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
  MainForm.Invalidate;
end;

procedure TInfoForm.AllOnClick(Sender: TObject);
var
  Id: TLayerId;
begin
  for Id := Low(TLayerId) to High(TLayerId) do
    MainForm.Scene.LayerOn[Id] := True;
  RefreshLayers;
  MainForm.Invalidate;
end;

procedure TInfoForm.AllOffClick(Sender: TObject);
var
  Id: TLayerId;
begin
  for Id := Low(TLayerId) to High(TLayerId) do
    MainForm.Scene.LayerOn[Id] := False;
  RefreshLayers;
  MainForm.Invalidate;
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
  MainForm.Invalidate;
end;

{ ---------- objects ---------- }

procedure TInfoForm.RefreshObjects;
var
  Sc: TVolcanoScene;

  procedure Row(const AName, AValue, ADetail: string);
  var
    It: TListItem;
  begin
    It := FObjList.Items.Add;
    It.Caption := AName;
    It.SubItems.Add(AValue);
    It.SubItems.Add(ADetail);
  end;

var
  TopIdx: Integer;
begin
  Sc := MainForm.Scene;
  if FObjList.TopItem <> nil then TopIdx := FObjList.TopItem.Index else TopIdx := 0;
  FObjList.Items.BeginUpdate;
  try
    FObjList.Items.Clear;
    Row('Window (client)', Format('%d x %d', [MainForm.ClientWidth, MainForm.ClientHeight]),
      IfThen(MainForm.FullScreen, 'full screen', 'windowed'));
    Row('Design space', Format('%d x %d', [DesignW, DesignH]), 'size of the reference image');
    Row('Scale', FormatFloat('0.0000', Sc.Scale), 'fit by min(width/736, height/1308)');
    Row('Offset', Format('%s, %s px', [FormatFloat('0', Sc.OffX), FormatFloat('0', Sc.OffY)]),
      'picture is centred in the window');
    Row('Visible x range', Format('%s .. %s', [FormatFloat('0', Sc.VisL), FormatFloat('0', Sc.VisR)]),
      'design px, clouds and birds wrap here');
    Row('Scene time', FormatFloat('0.0', Sc.Time) + ' s', IfThen(MainForm.Paused, 'paused', 'running'));
    Row('Frames painted', IntToStr(MainForm.FrameCount), '');
    Row('Static cuts', IntToStr(Sc.StaticCount), 'last one took ' + Ms(Sc.StaticMs) +
      ' (resize re-cuts background, cone, clouds, sea, caption)');
    Row('Smoke puffs', '230', 'depth 0/1/2 = 95/75/60, sprites per pixel radius');
    Row('Lava blobs', '90', '52 orange + 38 yellow');
    Row('Lava flows', '7', '3 passes each, 41 points per edge');
    Row('Embers', '40', 'rising sparks');
    Row('Ash flakes', '60', 'ballistic with gravity 45 px/s^2');
    Row('Birds', '14', '10..20 px, 35..70 px/s');
    Row('Clouds', '5 far + 3 low', 'far drift and wrap, low bob in place');
    Row('Palms', '6 back + 5 front', '9 fronds each, 12 segments per frond');
    Row('Sprite cache', IntToStr(Sc.SpriteCount) + ' round sprites',
      KB(Sc.SpriteBytes) + ' incl. cloud, sea and caption sprites');
    Row('Frame bitmaps', KB(Sc.BitmapBytes), 'background + work layer + cone + shadow buffers');
    Row('Output frame', Format('%d x %d', [MainForm.Frame.Width, MainForm.Frame.Height]),
      KB(Int64(MainForm.Frame.NbPixels) * 4));
    Row('Last saved PNG', IfThen(MainForm.LastSaved = '', '-', ExtractFileName(MainForm.LastSaved)),
      ExtractFilePath(MainForm.LastSaved));
    Row('Compiler', 'FPC ' + {$I %FPCVERSION%}, {$I %FPCTARGETOS%} + ' / ' + {$I %FPCTARGETCPU%});
    Row('Built', {$I %DATE%} + ' ' + {$I %TIME%}, '');
  finally
    FObjList.Items.EndUpdate;
  end;
  if (TopIdx > 0) and (TopIdx < FObjList.Items.Count) then
    FObjList.Items[TopIdx].MakeVisible(False);
end;

{ ---------- overview ---------- }

function TInfoForm.OverviewText: string;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('VOLCANO PAPERCUT - BGRABitmap');
    SL.Add('==============================');
    SL.Add('Animated paper-cut volcano island used as a UI background.');
    SL.Add('Lazarus + Free Pascal, drawing with BGRABitmap (package BGRABitmapPack).');
    SL.Add('');
    SL.Add('FILES');
    SL.Add('  VolcanoPapercut.lpi   project (packages: BGRABitmapPack, LCL; Release, -O3)');
    SL.Add('  VolcanoPapercut.lpr   program; also the --snapshot command line mode');
    SL.Add('  uvolcanoscene.pas     TVolcanoScene: layout, animation, rendering, timing');
    SL.Add('  umainform.pas         main window: timer, paint, hotkeys, frame history');
    SL.Add('  uinfoform.pas         this window');
    SL.Add('');
    SL.Add('BUILD AND RUN');
    SL.Add('  IDE:  open VolcanoPapercut.lpi, press F9');
    SL.Add('  CLI:  C:\lazarus\lazbuild.exe VolcanoPapercut.lpi');
    SL.Add('  VolcanoPapercut.exe --snapshot out.png [width height frames]');
    SL.Add('        renders one frame off-screen after <frames> updates of 1/30 s,');
    SL.Add('        saves it and writes out.txt with the average ms per frame');
    SL.Add('');
    SL.Add('HOTKEYS (main window)');
    SL.Add('  Space  pause / resume        F11  full screen');
    SL.Add('  S      save frame as PNG      H    hide / show caption');
    SL.Add('  I, F1  this window (it also opens by itself at startup)');
    SL.Add('  Esc    leave full screen / quit');
    SL.Add('  in this window: 1..5 switch tabs, Esc closes it');
    SL.Add('');
    SL.Add('USING IT AS A BACKGROUND IN ANOTHER FORM');
    SL.Add('  Scene := TVolcanoScene.Create;');
    SL.Add('  Scene.ShowCaption := False;');
    SL.Add('  on a timer:  Scene.Update(dt); Invalidate;');
    SL.Add('  in OnPaint:  Frame.SetSize(ClientWidth, ClientHeight);');
    SL.Add('               Scene.Render(Frame); Frame.Draw(Canvas, 0, 0, True);');
    SL.Add('');
    SL.Add('HOW A FRAME IS MADE');
    SL.Add('  1. The picture is laid out in a 736 x 1308 design space and scaled to fit');
    SL.Add('     (scale = min(w/736, h/1308)), centred. P(x, y) maps design -> pixels.');
    SL.Add('  2. Static parts are cut once per window size (Resize -> RenderStatic):');
    SL.Add('     paper background with grain, the cone (with its blurred shadow baked in),');
    SL.Add('     cloud sprites, sea body sprite and the caption card.');
    SL.Add('  3. Every frame, each moving layer is drawn on a transparent work bitmap');
    SL.Add('     (BeginLayer), then CompositeLayer lays it on the frame with a soft');
    SL.Add('     paper shadow in one pass:');
    SL.Add('       - layer alpha sampled every 4th pixel, x 110/255');
    SL.Add('       - box blur twice, radius 7 * depth / 4 px');
    SL.Add('       - bilinear stretch, offset (3, 6) * depth, darken, then blend the layer');
    SL.Add('       - only the bounding box of what the layer holds is touched');
    SL.Add('  4. Overlays (glow, ash, embers, birds, caption) go straight on the frame.');
    SL.Add('  5. Round pieces (smoke puffs, lava blobs) are blitted from sprites cached');
    SL.Add('     per pixel radius, so a frame does not re-rasterise hundreds of circles.');
    SL.Add('');
    SL.Add('ADDING A LAYER');
    SL.Add('  1. add an id to TLayerId and its entries in LayerNames, LayerKinds,');
    SL.Add('     LayerDepth and LayerNotes');
    SL.Add('  2. write a DrawXxx procedure that draws on FLayer in design coordinates');
    SL.Add('     (use P() and S(), or the Circle / Poly / Blob helpers)');
    SL.Add('  3. in Render: if LayerOn[id] then BeginLayer; DrawXxx;');
    SL.Add('     CompositeLayer(Dest, 0, 0, LayerDepth[id]); then Mark(id)');
    SL.Add('  4. anything that never moves belongs in RenderStatic instead');
    SL.Add('');
    SL.Add('PERFORMANCE (measured with --snapshot, 30 frames)');
    SL.Add('  450 x 800    about 31 ms/frame');
    SL.Add('  736 x 1308   about 56 ms/frame');
    SL.Add('  1920 x 1080  about 65 ms/frame');
    SL.Add('  Live numbers are on the Performance and Layers tabs.');
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
begin
  SL := TStringList.Create;
  try
    SL.Text := OverviewText;
    SL.Add('LIVE PERFORMANCE');
    SL.Add(Format('  fps %s, scene render %s, static cut %s', [FormatFloat('0.0', MainForm.Fps),
      Ms(MainForm.Scene.RenderMs), Ms(MainForm.Scene.StaticMs)]));
    for Id := Low(TLayerId) to High(TLayerId) do
      SL.Add(Format('  %-14s %8s  %s', [LayerNames[Id], Ms(MainForm.Scene.LayerMs[Id]),
        IfThen(MainForm.Scene.LayerOn[Id], 'on', 'OFF')]));
    SL.Add('');
    SL.Add('OBJECTS');
    for I := 0 to FObjList.Items.Count - 1 do
      with FObjList.Items[I] do
        SL.Add(Format('  %-18s %-22s %s', [Caption, SubItems[0], SubItems[1]]));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ ---------- performance ---------- }

procedure TInfoForm.PerfPaint(Sender: TObject);
const
  Pad = 12;
var
  B: TBGRABitmap;
  W, H, Y, I, K, GX, GY, GW, GH, LH: Integer;
  MaxV, SumI, SumP, MaxP, V, X, Total, BarW: Double;
  N: Integer;
  PtsI, PtsP: array of TPointF;
  Id: TLayerId;
  Txt: TBGRAPixel;

  procedure Line(const S: string; C: TBGRAPixel; Bold: Boolean = False);
  begin
    if Bold then B.FontStyle := [fsBold] else B.FontStyle := [];
    B.TextOut(Pad, Y, S, C);
    Inc(Y, LH);
  end;

begin
  W := FPerfBox.Width;
  H := FPerfBox.Height;
  if (W < 10) or (H < 10) then Exit;
  B := TBGRABitmap.Create(W, H, BGRA(250, 250, 248));
  try
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;
    B.FontHeight := Scale96ToForm(14);
    LH := Scale96ToForm(19);
    Txt := BGRA(40, 40, 40);

    // history statistics
    SumI := 0; SumP := 0; MaxP := 0; N := 0;
    for I := 0 to HistLen - 1 do
      if MainForm.IntervalHist[I] > 0 then
      begin
        SumI := SumI + MainForm.IntervalHist[I];
        SumP := SumP + MainForm.PaintHist[I];
        MaxP := Max(MaxP, MainForm.PaintHist[I]);
        Inc(N);
      end;
    Y := Pad;
    Line('LIVE PERFORMANCE', Txt, True);
    Line(Format('FPS %s   (timer 16 ms, state: %s)', [FormatFloat('0.0', MainForm.Fps),
      IfThen(MainForm.Paused, 'paused', 'running')]), Txt);
    if N > 0 then
    begin
      Line(Format('Frame interval avg %s     Paint avg %s     Paint max %s   (last %d frames)',
        [Ms(SumI / N), Ms(SumP / N), Ms(MaxP), N]), Txt);
    end;
    Line(Format('Scene.Render %s     Static cut %s (x%d)     Window %d x %d     Scale %s',
      [Ms(MainForm.Scene.RenderMs), Ms(MainForm.Scene.StaticMs), MainForm.Scene.StaticCount,
      MainForm.ClientWidth, MainForm.ClientHeight, FormatFloat('0.000', MainForm.Scene.Scale)]), Txt);
    Inc(Y, LH div 2);

    // frame history graph
    Line('Frame history:  blue = interval between paints,  orange = time inside paint', Txt, True);
    GX := Pad + Scale96ToForm(36);
    GY := Y;
    GW := W - GX - Pad;
    GH := Max(80, Round(H * 0.32));
    B.FillRect(GX, GY, GX + GW, GY + GH, BGRAWhite, dmSet);
    B.Rectangle(GX, GY, GX + GW, GY + GH, BGRA(200, 200, 200), dmSet);
    MaxV := 50;
    for I := 0 to HistLen - 1 do
      MaxV := Max(MaxV, MainForm.IntervalHist[I] * 1.1);
    B.FontHeight := Scale96ToForm(11);
    for K := 0 to 3 do
    begin
      case K of
        0: V := 0;
        1: V := 16.7;
        2: V := 33.3;
      else
        V := MaxV;
      end;
      if (K = 3) or (V < MaxV) then
      begin
        X := GY + GH - V / MaxV * GH;
        B.DrawLineAntialias(GX, X, GX + GW, X, BGRA(190, 190, 190), 1);
        B.TextOut(Pad, X - Scale96ToForm(7), FormatFloat('0', V), BGRA(110, 110, 110));
      end;
    end;
    B.FontHeight := Scale96ToForm(14);
    SetLength(PtsI, HistLen);
    SetLength(PtsP, HistLen);
    for I := 0 to HistLen - 1 do
    begin
      K := (MainForm.HistPos + I) mod HistLen;  // oldest first
      X := GX + I / (HistLen - 1) * GW;
      PtsI[I] := PointF(X, GY + GH - Min(MainForm.IntervalHist[K], MaxV) / MaxV * GH);
      PtsP[I] := PointF(X, GY + GH - Min(MainForm.PaintHist[K], MaxV) / MaxV * GH);
    end;
    B.DrawPolyLineAntialias(PtsI, BGRA(40, 110, 210), 1.5);
    B.DrawPolyLineAntialias(PtsP, BGRA(240, 120, 30), 1.5);
    Y := GY + GH + LH;

    // cost per layer
    Line('Cost per layer (smoothed, ms per frame)', Txt, True);
    Total := 0;
    for Id := Low(TLayerId) to High(TLayerId) do
      Total := Max(Total, MainForm.Scene.LayerMs[Id]);
    Total := Max(Total, 0.5);
    BarW := W - Pad * 2 - Scale96ToForm(200);
    for Id := Low(TLayerId) to High(TLayerId) do
    begin
      if Y + LH > H then Break;
      if MainForm.Scene.LayerOn[Id] then
        B.TextOut(Pad, Y, LayerNames[Id], Txt)
      else
        B.TextOut(Pad, Y, LayerNames[Id] + ' (off)', BGRA(160, 160, 160));
      V := MainForm.Scene.LayerMs[Id] / Total * BarW;
      B.FillRectAntialias(Pad + Scale96ToForm(120), Y + 3, Pad + Scale96ToForm(120) + V,
        Y + LH - 4, BGRA(240, 120, 30));
      B.TextOut(Pad + Scale96ToForm(126) + V, Y, Ms(MainForm.Scene.LayerMs[Id]), Txt);
      Inc(Y, LH);
    end;
    B.Draw(FPerfBox.Canvas, 0, 0, True);
  finally
    B.Free;
  end;
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

procedure TInfoForm.RefreshButtons;
begin
  if MainForm.Paused then FBtnPause.Caption := 'Resume' else FBtnPause.Caption := 'Pause';
  if MainForm.Scene.ShowCaption then FBtnCaption.Caption := 'Hide caption'
  else FBtnCaption.Caption := 'Show caption';
  FStatus.Caption := Format('%s fps   %s / frame', [FormatFloat('0.0', MainForm.Fps),
    Ms(MainForm.Scene.RenderMs)]);
end;

procedure TInfoForm.TimerTick(Sender: TObject);
begin
  if not Visible then Exit;
  RefreshButtons;
  case FPages.ActivePageIndex of
    1: FPerfBox.Invalidate;
    2: RefreshLayers;
    3: RefreshObjects;
  end;
end;

procedure TInfoForm.PageChange(Sender: TObject);
begin
  case FPages.ActivePageIndex of
    0: RefreshOverview;
    2: RefreshLayers;
    3: RefreshObjects;
  end;
end;

{ ---------- buttons ---------- }

procedure TInfoForm.PauseClick(Sender: TObject);
begin
  MainForm.Paused := not MainForm.Paused;
  RefreshButtons;
end;

procedure TInfoForm.CaptionClick(Sender: TObject);
begin
  MainForm.ToggleCaption;
  RefreshButtons;
end;

procedure TInfoForm.SaveClick(Sender: TObject);
begin
  MainForm.SaveFrame;
  FStatus.Caption := 'saved ' + ExtractFileName(MainForm.LastSaved);
end;

procedure TInfoForm.CopyClick(Sender: TObject);
begin
  RefreshObjects;
  Clipboard.AsText := ReportText;
  FStatus.Caption := 'report copied to the clipboard';
end;

procedure TInfoForm.RefreshClick(Sender: TObject);
begin
  RefreshOverview;
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
  else if (Key >= VK_1) and (Key <= VK_5) and (Shift = []) then
  begin
    // 1..5 jump to a tab
    FPages.ActivePageIndex := Key - VK_1;
    PageChange(FPages);
    Key := 0;
  end;
end;

end.
