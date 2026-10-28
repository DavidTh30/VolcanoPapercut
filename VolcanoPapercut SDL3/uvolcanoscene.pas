unit uVolcanoScene;

{ Paper-cut volcano island scene, multi-core edition.

  The picture is designed in a fixed 736 x 1308 "design space" (the size of the
  reference image) and scaled to fit the window.

  TVolcanoScene holds the state (animation, layout) and the read-only resources
  cut once per window size: paper background, the volcano cone with its baked
  shadow, cloud / sea / caption sprites and every round sprite (smoke puffs,
  lava blobs) for every pixel radius. Nothing is created while frames render, so
  any number of threads can read the scene at the same time.

  TPainter renders one horizontal band of the frame. Each worker thread owns one
  painter (its own work layer and shadow buffers). A painter draws every moving
  layer clipped to its band plus a margin above/below, so the soft shadows that
  cross band borders are computed from the same pixels in every band (the shadow
  sampling grid is aligned to frame rows, so there is no seam). }

{$mode objfpc}{$H+}
{$INLINE ON}

interface

uses
  Classes, SysUtils, StrUtils, Math, Graphics, BGRABitmap, BGRABitmapTypes,
  BGRAGradientScanner, uRenderPool, uSvgRecorder;

const
  DesignW = 736;
  DesignH = 1308;
  CraterX = 375;
  CraterY = 690;
  RimY = 705;       // top of the cone
  ConeBaseY = 1128; // bottom of the cone
  SpriteKinds = 6;  // 0..2 smoke depth, 3 orange lava, 4 red-orange lava, 5 yellow lava
  MaxDepth = 1.3;   // largest paper shadow depth of any layer

type
  TParticle = record
    X, Y, VX, VY, Life, MaxLife, Size, Phase: Single;
  end;

  TBird = record
    X, Y, VX, VY, Size, Phase: Single;
  end;

  TCloud = record
    Puffs: array of Single;  // x, y, r triples
    MinX, MaxX, MinY, MaxY: Single;
    OX, OY, Speed, Phase: Single;
    Drift: Boolean;          // True = sails across the sky, False = bobs in place
    Sprite: TBGRABitmap;     // cut once per window size
    Svg: string;             // the same cloud as SVG (vector export), local coordinates
  end;

  TPalm = record
    X, BaseY, H, Lean, Sc, Phase: Single;
    TrunkC, LeafC, RibC: TBGRAPixel;
    LeafAng, LeafLen: array[0..8] of Single;
  end;

  TPuff = record
    U, Speed, Lat, RMul, Wob: Single; // U = progress from crater (0) to sky (1)
    Depth: Integer;                  // 0 back .. 2 front
  end;

  TPuffDraw = record                  // smoke draw list, built once per frame
    X, Y: Single;
    Kind, RPx: Integer;
  end;

  TBlob = record
    U, Speed, Lat, RBase: Single;
    Yellow: Boolean;
  end;

  TFlow = record
    K, EndY, W, Seed: Single; // K = side of the cone (-1 left .. 1 right)
  end;

  { Everything the frame is made of, back to front. }
  TLayerId = (lyBackground, lyFarClouds, lySmoke, lyBackPalms, lyVolcano, lyLava, lyFire,
    lyFrontPalms, lySea, lyLowClouds, lyGlow, lyAsh, lyEmbers, lyBirds, lyCaption);

const
  LayerNames: array[TLayerId] of string = ('Background', 'Far clouds', 'Smoke',
    'Back palms', 'Volcano cone', 'Lava', 'Fire burst', 'Front palms', 'Sea', 'Low clouds',
    'Crater glow', 'Ash', 'Embers', 'Birds', 'Caption');
  LayerKinds: array[TLayerId] of string = ('static rows', 'sprites', 'sprites',
    'vector', 'static', 'vector', 'sprites', 'vector', 'sprite+vector', 'sprites',
    'overlay', 'overlay', 'overlay', 'overlay', 'static');
  { shadow depth multiplier: offset (3, 6) * depth, blur 7 * depth (design px);
    0 = no paper shadow }
  LayerDepth: array[TLayerId] of Single = (0, 0.8, 1.3, 1.0, 1.2, 0.45, 0.55, 0.7, 0.9, 1.1,
    0, 0, 0, 0, 0);
  LayerNotes: array[TLayerId] of string = (
    'Gradient #F4F4F2 -> #D6D6D4 + grain, cut once; bands copy their rows',
    '5 clouds, cut once as sprites; drift right 5..13 px/s and wrap at the window edges',
    '230 puffs on 3 depth sheets; rise from the crater and leave through the top edge',
    '6 silhouette palms; trunk bends and fronds wave',
    'Plump cone (half width 26 + 332 * u^0.6), front lobe, 240 rock strokes, grass strip',
    '7 lava tongues with travelling wavy edges down the flanks, shore pool',
    'Fire over the crater: a boiling lava mass and 90 blobs bursting up, own layer',
    '5 green palms with leaf ribs; trunk bends and fronds wave',
    'Base plate + sea body sprite; 9 wave lines rolling in alternate directions',
    '3 clouds under the island, bob in place',
    'Radial gradient over the crater, pulsing radius and alpha',
    '60 flakes thrown out of the crater, rotate and fall with gravity',
    '40 sparks rising with sideways wobble, flicker',
    '14 birds flapping away from the eruption (75% to the right)',
    'Title card with hotkeys, cut once per window size');

  PaletteNames: array[0..23] of string = ('Paper light', 'Paper dark', 'Ink outline',
    'Cloud', 'Smoke back', 'Smoke mid', 'Smoke front', 'Cone', 'Cone lobe', 'Rock stroke',
    'Lava edge', 'Lava mid', 'Lava core', 'Lava tip', 'Lava pool', 'Grass', 'Grass shade',
    'Palm leaf', 'Palm leaf light', 'Palm rib', 'Palm trunk', 'Back palm', 'Sea',
    'Wave line');
  PaletteHex: array[0..23] of string = ('#F4F4F2', '#D6D6D4', '#1A1A1A', '#FFFFFF',
    '#232323', '#2E2E2E', '#3A3A3A', '#2F2F2F', '#353535', '#474747', '#E0441A',
    '#F7861E', '#FFC23A', '#E8501E', '#F26A1B', '#6DB33F', '#4E9A2E', '#7CC242',
    '#86CC4C', '#4E9A2E', '#3E4B36', '#3C3C3C', '#3E5566', '#22313B');

type
  TVolcanoScene = class;

  { TPainter: renders frame rows into a band bitmap. One per worker thread. }

  TPainter = class
  private
    FScene: TVolcanoScene;
    FLayer: TBGRABitmap;      // work layer, frame rows [FLayerTop, FLayerTop + height)
    FLayerTop: Integer;
    FOrgX, FOrgY: Single;     // P() origin in pixels of the current target
    FShadow, FBlurTmp, FRow: array of Single;
    FXIdx: array of Integer;
    FXFrac: array of Single;
    FPts, FMid, FTrunk, FWave, FScaled: array of TPointF;
    FSvg: TSvgRecorder;       // vector mode: shapes are recorded here
    FRaster: Boolean;         // draw pixels (False in pure vector mode)
    FTargetH: Integer;        // height of the current target (row culling)
    FSvgMark: Integer;        // start of the current layer in FSvg
    procedure DPoly(B: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel);
    procedure DPolyG(B: TBGRABitmap; const Pts: array of TPointF; const G: TGrad);
    procedure DEllipse(B: TBGRABitmap; X, Y, RX, RY: Single; C: TBGRAPixel);
    procedure DEllipseG(B: TBGRABitmap; X, Y, RX, RY: Single; const G: TGrad);
    procedure DEllipseLine(B: TBGRABitmap; X, Y, RX, RY: Single; C: TBGRAPixel; W: Single);
    procedure DPolyLine(B: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel; W: Single);
    procedure DLine(B: TBGRABitmap; X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single);
    procedure DRadialRect(B: TBGRABitmap; X1, Y1, X2, Y2: Integer; C1, C2: TBGRAPixel;
      Ctr, Edge: TPointF);
    procedure DBlit(B: TBGRABitmap; X, Y: Integer; Spr: TBGRABitmap; const Svg: string;
      ACopy: Boolean = False);
    procedure SvgLayerEnd(Depth: Single);
    function P(X, Y: Single): TPointF; inline;
    function S(V: Single): Single; inline;
    function RowsHit(Y0, Y1: Single): Boolean; inline;
    procedure BeginLayer;
    procedure CompositeLayer(Dest: TBGRABitmap; DestTop: Integer; Depth: Single);
    procedure Circle(Bmp: TBGRABitmap; X, Y, R: Single; C: TBGRAPixel);
    procedure Poly(Bmp: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel);
    procedure Leaf(Base, Ctrl, Tip: TPointF; W: Single; C, Rib: TBGRAPixel);
    procedure Sprite(Bmp: TBGRABitmap; Kind: Integer; X, Y: Single; RPx: Integer);
    procedure DrawCloud(const C: TCloud);
    procedure DrawPalm(const Pm: TPalm);
    procedure DrawSmoke;
    procedure DrawFlow(const F: TFlow);
    procedure DrawLava;
    procedure DrawFire;
    procedure DrawSea;
    procedure DrawGlow(Dest: TBGRABitmap);
    procedure DrawEmbers(Dest: TBGRABitmap);
    procedure DrawAsh(Dest: TBGRABitmap);
    procedure DrawBirds(Dest: TBGRABitmap);
    procedure DrawCaption(Dest: TBGRABitmap);
  public
    LayerMs: array[TLayerId] of Double;  // accumulated since ResetStats
    constructor Create(AScene: TVolcanoScene);
    destructor Destroy; override;
    procedure ResetStats;
    { renders frame rows [ATop, ATop + Dest.Height) into Dest (full frame width) }
    procedure RenderBand(Dest: TBGRABitmap; ATop: Integer);
  end;

  { TVolcanoScene }

  TVolcanoScene = class
  private
    FWidth, FHeight: Integer;
    FVisL, FVisR: Single;            // visible x range in design units
    FScale, FOffX, FOffY: Single;
    FBack: TBGRABitmap;              // paper background, window sized
    FVolcano: TBGRABitmap;           // cone + grass with its shadow, cropped to its rows
    FVolcanoPos: TPoint;
    FCaption: TBGRABitmap;           // caption card with its shadow
    FSeaBody: TBGRABitmap;           // base plate + sea, waves are drawn per frame
    FSeaPos: TPoint;
    FSprites: array[0..SpriteKinds - 1] of array of TBGRABitmap; // [kind][radius px]
    FSpriteJobs: array of TPoint;    // (kind, radius) of each sprite to cut
    FCutter: TPainter;               // full-frame painter used for the static cut
    FTime: Single;
    FFarClouds, FLowClouds: array of TCloud;
    FBackPalms, FFrontPalms: array of TPalm;
    FPuffs: array of TPuff;
    FPuffDraw: array of TPuffDraw;
    FBlobs: array of TBlob;
    FFlows: array of TFlow;
    FEmbers: array of TParticle;
    FAsh: array of TParticle;
    FBirds: array of TBird;
    FShowCaption: Boolean;
    FRecordSvg: Boolean;             // record the static parts as SVG too (vector export)
    FStaticSvg: TSvgRecorder;        // defs of the static parts
    FSvgBack, FSvgVolcano, FSvgSea, FSvgCaption: string;
    function P(X, Y: Single): TPointF;
    function S(V: Single): Single;
    procedure AddCloud(var List: array of TCloud; Index: Integer; const Puffs: array of Single;
      Drift: Boolean);
    procedure SetupPalm(var Pm: TPalm; X, BaseY, H, Lean, Sc: Single;
      TrunkC, LeafC, RibC: TBGRAPixel);
    procedure SpawnPuff(var Pf: TPuff; Initial: Boolean);
    procedure SpawnBlob(var B: TBlob; Initial: Boolean);
    procedure SpawnEmber(var E: TParticle; Initial: Boolean);
    procedure SpawnAsh(var A: TParticle; Initial: Boolean);
    procedure SpawnBird(var B: TBird; Initial: Boolean);
    procedure FreeResources;
    procedure BakeLayer(Dest: TBGRABitmap; Depth: Single);
    function CropLayer(const R: TRect; out Pos: TPoint): TBGRABitmap;
    procedure CutCloud(var C: TCloud);
    procedure RenderStatic;
  public
    LayerOn: array[TLayerId] of Boolean;   // switch single layers off for debugging
    TransparentBack: Boolean;              // background off -> transparent (layer export)
    StaticMs: Double;                      // last static cut (resize), main thread part
    StaticCount: Integer;
    constructor Create;
    destructor Destroy; override;
    { window size changed: cuts background, cone, cloud/sea/caption sprites.
      Main thread only (uses fonts). Then run SpriteJob for 0..SpriteJobCount-1,
      on any number of threads. }
    procedure Resize(AWidth, AHeight: Integer);
    function SpriteJobCount: Integer;
    procedure SpriteJob(AIndex, AWorker: Integer);
    procedure Update(DT: Single);
    { per frame, after Update and before the painters run: builds draw lists }
    procedure Prepare;
    { copies the animation state (time, particles, clouds) of another scene, so an
      export scene can continue exactly from what the window shows }
    procedure CopyStateFrom(Src: TVolcanoScene);
    { vector export: the current frame (Prepare must have run) as SVG shapes in
      frame pixel coordinates; needs VectorStatic set before the last Resize }
    procedure RenderSvg(Svg: TSvgRecorder);
    property VectorStatic: Boolean read FRecordSvg write FRecordSvg;
    function SpriteCount: Integer;
    function SpriteBytes: Int64;
    function StaticBytes: Int64;
    function DescribeParams: string;
    property ShowCaption: Boolean read FShowCaption write FShowCaption;
    property Time: Single read FTime;
    property Scale: Single read FScale;
    property OffX: Single read FOffX;
    property OffY: Single read FOffY;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property VisL: Single read FVisL;
    property VisR: Single read FVisR;
  end;

implementation

{ colours used while rendering (read-only after initialization, shared by threads) }
var
  clInk, clWhite, clLavaEdge, clLavaMid, clLavaCore, clPool1, clPool2, clWave,
  clBird, clCone, clLobe, clRock, clGrass, clGrassShade, clSea: TBGRAPixel;
  SpriteFill: array[0..SpriteKinds - 1] of TBGRAPixel;
  SpriteLine: array[0..SpriteKinds - 1] of TBGRAPixel;

function Hex(const S: string): TBGRAPixel;
begin
  Result := StrToBGRA(S);
end;

function RandRange(A, B: Single): Single;
begin
  Result := A + Random * (B - A);
end;

function Bezier(const P0, C, P1: TPointF; T: Single): TPointF; inline;
var
  U: Single;
begin
  U := 1 - T;
  Result.X := U * U * P0.X + 2 * U * T * C.X + T * T * P1.X;
  Result.Y := U * U * P0.Y + 2 * U * T * C.Y + T * T * P1.Y;
end;

function BezierTangent(const P0, C, P1: TPointF; T: Single): TPointF; inline;
begin
  Result.X := 2 * (1 - T) * (C.X - P0.X) + 2 * T * (P1.X - C.X);
  Result.Y := 2 * (1 - T) * (C.Y - P0.Y) + 2 * T * (P1.Y - C.Y);
end;

{ Half width of the cone at height Y. The power < 1 bulges the sides outward,
  which gives the plump, rounded shoulders. }
function ConeHalfWidth(Y: Single): Single;
begin
  Result := 26 + 332 * Power(EnsureRange((Y - RimY) / (ConeBaseY - RimY), 0, 1), 0.6);
end;

{ One box-blur pass over a W x H single-channel buffer (horizontal then vertical). }
procedure BoxBlur(var A, Tmp: array of Single; W, H, R: Integer);
var
  X, Y, I: Integer;
  Sum, Inv: Single;
begin
  Inv := 1 / (2 * R + 1);
  for Y := 0 to H - 1 do
  begin
    Sum := 0;
    for I := 0 to Min(R, W - 1) do
      Sum := Sum + A[Y * W + I];
    for X := 0 to W - 1 do
    begin
      Tmp[Y * W + X] := Sum * Inv;
      if X + R + 1 < W then Sum := Sum + A[Y * W + X + R + 1];
      if X - R >= 0 then Sum := Sum - A[Y * W + X - R];
    end;
  end;
  for X := 0 to W - 1 do
  begin
    Sum := 0;
    for I := 0 to Min(R, H - 1) do
      Sum := Sum + Tmp[I * W + X];
    for Y := 0 to H - 1 do
    begin
      A[Y * W + X] := Sum * Inv;
      if Y + R + 1 < H then Sum := Sum + Tmp[(Y + R + 1) * W + X];
      if Y - R >= 0 then Sum := Sum - Tmp[(Y - R) * W + X];
    end;
  end;
end;

{ Row Y of a bitmap without going through BGRABitmap's getters, so threads only
  ever read shared bitmaps (TBGRABitmap.PutImage keeps scan state inside the
  source bitmap and must not be used on a source that other threads use). }
function RowPtr(B: TBGRABitmap; Y: Integer): PBGRAPixel; inline;
begin
  if B.LineOrder = riloTopToBottom then
    Result := B.Data + Y * B.Width
  else
    Result := B.Data + (B.Height - 1 - Y) * B.Width;
end;

{ Draws Src at (X, Y) on Dest: alpha "over" (Dest may be transparent), or a plain
  copy. Src is only read, so any number of threads can draw the same sprite. }
procedure BlendBitmap(Dest: TBGRABitmap; X, Y: Integer; Src: TBGRABitmap; ACopy: Boolean = False);
var
  SX0, SY0, SX1, SY1, YY, XX, SA, DA, W1, W2, WS: Integer;
  S, D: PBGRAPixel;
begin
  if Src = nil then Exit;
  SX0 := Max(0, -X);
  SY0 := Max(0, -Y);
  SX1 := Min(Src.Width, Dest.Width - X);
  SY1 := Min(Src.Height, Dest.Height - Y);
  if (SX1 <= SX0) or (SY1 <= SY0) then Exit;
  for YY := SY0 to SY1 - 1 do
  begin
    S := RowPtr(Src, YY) + SX0;
    D := RowPtr(Dest, Y + YY) + X + SX0;
    if ACopy then
    begin
      Move(S^, D^, (SX1 - SX0) * SizeOf(TBGRAPixel));
      Continue;
    end;
    for XX := SX0 to SX1 - 1 do
    begin
      SA := S^.alpha;
      if SA = 255 then
        D^ := S^
      else if SA > 0 then
      begin
        DA := D^.alpha;
        if DA = 255 then
        begin
          W2 := 255 - SA;
          D^.red := (S^.red * SA + D^.red * W2) div 255;
          D^.green := (S^.green * SA + D^.green * W2) div 255;
          D^.blue := (S^.blue * SA + D^.blue * W2) div 255;
        end
        else
        begin
          W1 := SA * 255;
          W2 := DA * (255 - SA);
          WS := W1 + W2;
          D^.red := (S^.red * W1 + D^.red * W2) div WS;
          D^.green := (S^.green * W1 + D^.green * W2) div WS;
          D^.blue := (S^.blue * W1 + D^.blue * W2) div WS;
          D^.alpha := WS div 255;
        end;
      end;
      Inc(S);
      Inc(D);
    end;
  end;
end;

{ ====================================================================== }
{ TPainter                                                               }
{ ====================================================================== }

constructor TPainter.Create(AScene: TVolcanoScene);
begin
  inherited Create;
  FScene := AScene;
  FLayer := TBGRABitmap.Create(1, 1);
  FLayer.LinearAntialiasing := True;
  SetLength(FPts, 128);
  SetLength(FMid, 32);
  SetLength(FTrunk, 32);
  SetLength(FWave, 200);
  SetLength(FScaled, 128);
  FRaster := True;
end;

destructor TPainter.Destroy;
begin
  FLayer.Free;
  inherited Destroy;
end;

procedure TPainter.ResetStats;
begin
  FillChar(LayerMs, SizeOf(LayerMs), 0);
end;

function TPainter.P(X, Y: Single): TPointF;
begin
  Result.X := FOrgX + X * FScene.FScale;
  Result.Y := FOrgY + Y * FScene.FScale;
end;

function TPainter.S(V: Single): Single;
begin
  Result := V * FScene.FScale;
end;

{ True when design rows Y0..Y1 reach the work layer; everything outside the band
  is skipped before any geometry is built. }
function TPainter.RowsHit(Y0, Y1: Single): Boolean;
begin
  Result := (FOrgY + Y1 * FScene.FScale >= -2) and (FOrgY + Y0 * FScene.FScale <= FTargetH + 2);
end;

procedure TPainter.BeginLayer;
begin
  FOrgX := FScene.FOffX;
  FOrgY := FScene.FOffY - FLayerTop;
  if FRaster then
  begin
    FLayer.FillTransparent;
    FTargetH := FLayer.Height;
  end
  else
    FTargetH := FScene.FHeight;
  if FSvg <> nil then FSvgMark := FSvg.Mark;
end;

{ ---------- drawing primitives: pixels, SVG, or both ---------- }

procedure TPainter.DPoly(B: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel);
begin
  if FSvg <> nil then FSvg.Poly(Pts, C);
  if FRaster then B.FillPolyAntialias(Pts, C);
end;

procedure TPainter.DPolyG(B: TBGRABitmap; const Pts: array of TPointF; const G: TGrad);
var
  Sc: TBGRAGradientScanner;
begin
  if FSvg <> nil then FSvg.PolyFill(Pts, FSvg.Gradient(G));
  if FRaster then
  begin
    if G.Radial then
      Sc := TBGRAGradientScanner.Create(G.C1, G.C2, gtRadial, G.P1, G.P2, True)
    else
      Sc := TBGRAGradientScanner.Create(G.C1, G.C2, gtLinear, G.P1, G.P2, True);
    try
      B.FillPolyAntialias(Pts, Sc);
    finally
      Sc.Free;
    end;
  end;
end;

procedure TPainter.DEllipse(B: TBGRABitmap; X, Y, RX, RY: Single; C: TBGRAPixel);
begin
  if FSvg <> nil then FSvg.Ellipse(X, Y, RX, RY, C);
  if FRaster then B.FillEllipseAntialias(X, Y, RX, RY, C);
end;

procedure TPainter.DEllipseG(B: TBGRABitmap; X, Y, RX, RY: Single; const G: TGrad);
var
  Sc: TBGRAGradientScanner;
begin
  if FSvg <> nil then FSvg.EllipseFill(X, Y, RX, RY, FSvg.Gradient(G));
  if FRaster then
  begin
    if G.Radial then
      Sc := TBGRAGradientScanner.Create(G.C1, G.C2, gtRadial, G.P1, G.P2, True)
    else
      Sc := TBGRAGradientScanner.Create(G.C1, G.C2, gtLinear, G.P1, G.P2, True);
    try
      B.FillEllipseAntialias(X, Y, RX, RY, Sc);
    finally
      Sc.Free;
    end;
  end;
end;

procedure TPainter.DEllipseLine(B: TBGRABitmap; X, Y, RX, RY: Single; C: TBGRAPixel; W: Single);
begin
  if FSvg <> nil then FSvg.EllipseLine(X, Y, RX, RY, C, W);
  if FRaster then B.EllipseAntialias(X, Y, RX, RY, C, W);
end;

procedure TPainter.DPolyLine(B: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel; W: Single);
begin
  if FSvg <> nil then FSvg.PolyLine(Pts, C, W);
  if FRaster then B.DrawPolyLineAntialias(Pts, C, W);
end;

procedure TPainter.DLine(B: TBGRABitmap; X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single);
begin
  if FSvg <> nil then FSvg.Line(X1, Y1, X2, Y2, C, W);
  if FRaster then B.DrawLineAntialias(X1, Y1, X2, Y2, C, W);
end;

{ a radial glow over a square (GradientFill with transparency) }
procedure TPainter.DRadialRect(B: TBGRABitmap; X1, Y1, X2, Y2: Integer; C1, C2: TBGRAPixel;
  Ctr, Edge: TPointF);
begin
  if FSvg <> nil then
    FSvg.Rect(X1, Y1, X2 - X1, Y2 - Y1, FSvg.Gradient(MakeGrad(C1, C2, True, Ctr, Edge)));
  if FRaster then
    B.GradientFill(X1, Y1, X2, Y2, C1, C2, gtRadial, Ctr, Edge, dmDrawWithTransparency);
end;

{ a static resource: blended pixels, or its recorded SVG }
procedure TPainter.DBlit(B: TBGRABitmap; X, Y: Integer; Spr: TBGRABitmap; const Svg: string;
  ACopy: Boolean = False);
begin
  if FSvg <> nil then FSvg.Raw(Svg);
  if FRaster then BlendBitmap(B, X, Y, Spr, ACopy);
end;

{ vector mode: everything since BeginLayer becomes one group with the paper shadow }
procedure TPainter.SvgLayerEnd(Depth: Single);
var
  Content: string;
begin
  Content := FSvg.Take(FSvgMark);
  if Content = '' then Exit;
  if Depth > 0 then
    FSvg.Raw('<g filter="url(#' + FSvg.DropShadow(S(3) * Depth, S(6) * Depth, S(7) * Depth * 0.5,
      110 / 255) + ')">' + LineEnding + Content + '</g>')
  else
    FSvg.Raw('<g>' + LineEnding + Content + '</g>');
end;



{ Lays the work layer on the opaque band with a soft paper shadow, in one pass.
  Shadow = layer alpha sampled every 4th pixel (grid aligned to frame rows), box
  blurred twice, then bilinearly stretched back while blending. Only the bounding
  box of what the layer holds is touched. }
procedure TPainter.CompositeLayer(Dest: TBGRABitmap; DestTop: Integer; Depth: Single);
const
  F = 4;
  Strength = 110 / 255;
var
  LW, LH, DH, SW, SH, X, Y, R, DX, DY, LX, LY, SY0, X0, X1, Y0, Y1, SA, LA, Inv,
  Pad, BX0, BX1, BY0, BY1, W1, W2, WS: Integer;
  FY, V: Single;
  Src, Dst, L: PBGRAPixel;
begin
  if not FRaster then
  begin
    SvgLayerEnd(Depth);
    Exit;
  end;
  LW := FLayer.Width;
  LH := FLayer.Height;
  DH := Dest.Height;
  BX0 := MaxInt; BX1 := -1; BY0 := MaxInt; BY1 := -1;
  SW := LW div F + 2;
  SH := LH div F + 2;
  if Length(FShadow) < SW * SH then
  begin
    SetLength(FShadow, SW * SH);
    SetLength(FBlurTmp, SW * SH);
  end;
  for Y := 0 to SH - 1 do
  begin
    LY := Y * F;
    if LY >= LH then
    begin
      for X := 0 to SW - 1 do FShadow[Y * SW + X] := 0;
      Continue;
    end;
    Src := FLayer.ScanLine[LY];
    for X := 0 to SW - 1 do
    begin
      LX := X * F;
      if (LX < LW) and ((Src + LX)^.alpha > 0) then
      begin
        FShadow[Y * SW + X] := (Src + LX)^.alpha * Strength;
        if X < BX0 then BX0 := X;
        if X > BX1 then BX1 := X;
        if Y < BY0 then BY0 := Y;
        if Y > BY1 then BY1 := Y;
      end
      else
        FShadow[Y * SW + X] := 0;
    end;
  end;
  if BX1 < 0 then Exit;  // empty layer
  R := Max(1, Round(S(7) * Depth / F));
  BoxBlur(FShadow, FBlurTmp, SW, SH, R);
  BoxBlur(FShadow, FBlurTmp, SW, SH, R);

  DX := Round(S(3) * Depth);
  DY := Round(S(6) * Depth);
  Pad := (2 * R + 2) * F;
  X0 := Max(0, BX0 * F - Pad);
  X1 := Min(LW, BX1 * F + DX + Pad);
  // layer rows -> frame rows -> band rows
  Y0 := Max(0, FLayerTop + BY0 * F - Pad - DestTop);
  Y1 := Min(DH, FLayerTop + BY1 * F + DY + Pad - DestTop);
  if (X1 <= X0) or (Y1 <= Y0) then Exit;
  if Length(FXIdx) < LW then
  begin
    SetLength(FXIdx, LW);
    SetLength(FXFrac, LW);
  end;
  for X := X0 to X1 - 1 do
  begin
    V := (X - DX) / F;
    FXIdx[X] := Floor(V);
    FXFrac[X] := V - FXIdx[X];
  end;
  if Length(FRow) < SW then SetLength(FRow, SW);
  L := nil;
  for Y := Y0 to Y1 - 1 do
  begin
    FY := (DestTop + Y - DY - FLayerTop) / F;
    SY0 := Floor(FY);
    FY := FY - SY0;
    for X := 0 to SW - 1 do
    begin
      V := 0;
      if (SY0 >= 0) and (SY0 < SH) then V := FShadow[SY0 * SW + X] * (1 - FY);
      if (SY0 + 1 >= 0) and (SY0 + 1 < SH) then V := V + FShadow[(SY0 + 1) * SW + X] * FY;
      FRow[X] := V;
    end;
    LY := DestTop + Y - FLayerTop;
    if (LY >= 0) and (LY < LH) then Src := FLayer.ScanLine[LY] else Src := nil;
    Dst := Dest.ScanLine[Y];
    for X := X0 to X1 - 1 do
    begin
      LX := FXIdx[X];
      V := 0;
      if (LX >= 0) and (LX < SW) then V := FRow[LX] * (1 - FXFrac[X]);
      if (LX + 1 >= 0) and (LX + 1 < SW) then V := V + FRow[LX + 1] * FXFrac[X];
      SA := Round(V);
      LA := 0;
      if Src <> nil then
      begin
        L := Src + X;
        LA := L^.alpha;
      end;
      if (SA = 0) and (LA = 0) then Continue;
      with (Dst + X)^ do
      begin
        if LA = 255 then
        begin
          red := L^.red;
          green := L^.green;
          blue := L^.blue;
          alpha := 255;
          Continue;
        end;
        if alpha = 255 then
        begin
          // opaque band (the live frame): plain darken + blend
          if SA > 0 then
          begin
            Inv := 255 - SA;
            red := red * Inv div 255;
            green := green * Inv div 255;
            blue := blue * Inv div 255;
          end;
          if LA > 0 then
          begin
            Inv := 255 - LA;
            red := (L^.red * LA + red * Inv) div 255;
            green := (L^.green * LA + green * Inv) div 255;
            blue := (L^.blue * LA + blue * Inv) div 255;
          end;
        end
        else
        begin
          // transparent band (layer export): black shadow "over", then layer "over"
          if SA > 0 then
          begin
            W2 := alpha * (255 - SA);
            WS := SA * 255 + W2;
            red := red * W2 div WS;
            green := green * W2 div WS;
            blue := blue * W2 div WS;
            alpha := WS div 255;
          end;
          if LA > 0 then
          begin
            W1 := LA * 255;
            W2 := alpha * (255 - LA);
            WS := W1 + W2;
            red := (L^.red * W1 + red * W2) div WS;
            green := (L^.green * W1 + green * W2) div WS;
            blue := (L^.blue * W1 + blue * W2) div WS;
            alpha := WS div 255;
          end;
        end;
      end;
    end;
  end;
end;

procedure TPainter.Circle(Bmp: TBGRABitmap; X, Y, R: Single; C: TBGRAPixel);
var
  Q: TPointF;
begin
  Q := P(X, Y);
  DEllipse(Bmp, Q.X, Q.Y, S(R), S(R), C);
end;

procedure TPainter.Poly(Bmp: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel);
var
  I: Integer;
begin
  if Length(FScaled) <> Length(Pts) then SetLength(FScaled, Length(Pts));
  for I := 0 to High(Pts) do
    FScaled[I] := P(Pts[I].X, Pts[I].Y);
  DPoly(Bmp, FScaled, C);
end;

procedure TPainter.Sprite(Bmp: TBGRABitmap; Kind: Integer; X, Y: Single; RPx: Integer);
var
  Spr: TBGRABitmap;
  Q: TPointF;
begin
  RPx := EnsureRange(RPx, 1, High(FScene.FSprites[Kind]));
  Q := P(X, Y);
  if FSvg <> nil then
  begin
    // the same round paper piece as the sprite: fill, outline / curl
    FSvg.Ellipse(Q.X, Q.Y, RPx, RPx, SpriteFill[Kind]);
    if Kind <= 2 then
      FSvg.EllipseLine(Q.X, Q.Y, RPx, RPx, SpriteLine[Kind], Max(0.8, S(1.6)))
    else if Kind = 5 then
      FSvg.EllipseLine(Q.X, Q.Y, RPx * 0.5, RPx * 0.5, SpriteLine[Kind], Max(0.6, S(1.1)));
  end;
  if not FRaster then Exit;
  Spr := FScene.FSprites[Kind][RPx];
  if Spr = nil then Exit;
  BlendBitmap(Bmp, Round(Q.X) - Spr.Width div 2, Round(Q.Y) - Spr.Height div 2, Spr);
end;

{ A palm frond: a tapered strip along a quadratic curve with a saw-tooth edge. }
procedure TPainter.Leaf(Base, Ctrl, Tip: TPointF; W: Single; C, Rib: TBGRAPixel);
const
  N = 12;
var
  I: Integer;
  T, Wt, L: Single;
  B, D, Nrm: TPointF;
begin
  if not RowsHit(Min(Base.Y, Min(Ctrl.Y, Tip.Y)) - W, Max(Base.Y, Max(Ctrl.Y, Tip.Y)) + W) then
    Exit;
  if Length(FPts) <> 2 * (N + 1) then SetLength(FPts, 2 * (N + 1));
  if Length(FMid) <> N + 1 then SetLength(FMid, N + 1);
  for I := 0 to N do
  begin
    T := I / N;
    B := Bezier(Base, Ctrl, Tip, T);
    D := BezierTangent(Base, Ctrl, Tip, T);
    L := Sqrt(D.X * D.X + D.Y * D.Y);
    if L < 1e-4 then L := 1;
    Nrm := PointF(-D.Y / L, D.X / L);
    Wt := W * Sin(Pi * Power(T, 0.7));
    if Odd(I) then Wt := Wt * 0.45;  // jagged frond edge
    FPts[I] := P(B.X + Nrm.X * Wt, B.Y + Nrm.Y * Wt);
    FPts[2 * (N + 1) - 1 - I] := P(B.X - Nrm.X * Wt * 0.8, B.Y - Nrm.Y * Wt * 0.8);
    FMid[I] := P(B.X, B.Y);
  end;
  DPoly(FLayer, FPts, C);
  if Rib.alpha > 0 then
    DPolyLine(FLayer, FMid, Rib, Max(0.8, S(1.2)));
end;

procedure TPainter.DrawCloud(const C: TCloud);
var
  Q: TPointF;
begin
  if C.Sprite = nil then Exit;
  Q := P(C.MinX - 6 + C.OX, C.MinY - 6 + C.OY);
  if FSvg <> nil then
    FSvg.Raw(Format('<g transform="translate(%s,%s)">', [FSvg.N(Round(Q.X)), FSvg.N(Round(Q.Y))]) +
      LineEnding + C.Svg + '</g>');
  if FRaster then BlendBitmap(FLayer, Round(Q.X), Round(Q.Y), C.Sprite);
end;

{ The trunk bends with the wind; every frond waves on its own beat. }
procedure TPainter.DrawPalm(const Pm: TPalm);
const
  N = 14;
var
  Base, Top, Ctrl, B, D, Tip, LC: TPointF;
  I: Integer;
  T, W, L, A, Len, Sway, Tm: Single;
begin
  // fronds reach about 70 * scale above the crown and droop below it
  if not RowsHit(Pm.BaseY - Pm.H - 70 * Pm.Sc, Max(Pm.BaseY, Pm.BaseY - Pm.H + 70 * Pm.Sc) + 4) then
    Exit;
  Tm := FScene.FTime;
  Sway := Sin(Tm * 1.1 + Pm.Phase) + 0.35 * Sin(Tm * 2.3 + Pm.Phase * 1.7);
  Base := PointF(Pm.X, Pm.BaseY);
  Top := PointF(Pm.X + Pm.Lean * Pm.H + Sway * Pm.H * 0.022, Pm.BaseY - Pm.H);
  Ctrl := PointF(Pm.X + Pm.Lean * Pm.H * 0.15, Pm.BaseY - Pm.H * 0.55);
  if Length(FTrunk) <> 2 * (N + 1) then SetLength(FTrunk, 2 * (N + 1));
  for I := 0 to N do
  begin
    T := I / N;
    B := Bezier(Base, Ctrl, Top, T);
    D := BezierTangent(Base, Ctrl, Top, T);
    L := Sqrt(D.X * D.X + D.Y * D.Y);
    W := (6.5 - 3 * T) * Pm.Sc;
    FTrunk[I] := P(B.X - D.Y / L * W, B.Y + D.X / L * W);
    FTrunk[2 * (N + 1) - 1 - I] := P(B.X + D.Y / L * W, B.Y - D.X / L * W);
  end;
  DPoly(FLayer, FTrunk, Pm.TrunkC);
  for I := 0 to 8 do
  begin
    A := DegToRad(Pm.LeafAng[I] + Sway * 3 + Sin(Tm * 1.9 + Pm.Phase + I * 0.7) * 4);
    Len := Pm.LeafLen[I] * Pm.Sc * (1 + 0.03 * Sin(Tm * 2.4 + I));
    Tip := PointF(Top.X + Cos(A) * Len, Top.Y + Sin(A) * Len * 0.55 + Len * 0.42);
    LC := PointF(Top.X + Cos(A) * Len * 0.55, Top.Y + Sin(A) * Len * 0.6 - Len * 0.22);
    Leaf(Top, LC, Tip, 9 * Pm.Sc, Pm.LeafC, Pm.RibC);
  end;
  Circle(FLayer, Top.X, Top.Y + 2 * Pm.Sc, 4 * Pm.Sc, Pm.TrunkC);
end;

{ Smoke puffs come pre-sorted from TVolcanoScene.Prepare; the band only blits
  the sprites that reach it. }
procedure TPainter.DrawSmoke;
var
  I, Half: Integer;
  Q: TPointF;
begin
  for I := 0 to High(FScene.FPuffDraw) do
    with FScene.FPuffDraw[I] do
    begin
      Q := P(X, Y);
      Half := RPx + 2;
      if (Q.Y + Half < 0) or (Q.Y - Half > FTargetH) then Continue;
      Sprite(FLayer, Kind, X, Y, RPx);
    end;
end;

{ A lava tongue hugging the plump flank. The edges are wavy, and the ripples
  travel downhill (sin(s*k - time*w)), so the lava looks like it is flowing. }
procedure TPainter.DrawFlow(const F: TFlow);
const
  N = 40;
  Scales: array[0..2] of Single = (1, 0.62, 0.3);
  Reach: array[0..2] of Single = (1, 0.88, 0.66);
var
  Ctr: array[0..N] of TPointF;
  Pass, I, A, B: Integer;
  Sv, Y, Wt, WL, WR, L, Spd, Tm: Single;
  D, Nrm: TPointF;
  Color: TBGRAPixel;
begin
  if not RowsHit(RimY - 4, F.EndY + F.W + 4) then Exit;
  Tm := FScene.FTime;
  for I := 0 to N do
  begin
    Sv := I / N;
    Y := RimY + 4 + (F.EndY - RimY - 4) * Sv;
    Ctr[I] := PointF(CraterX + F.K * ConeHalfWidth(Y) * 0.92 +
      Sin(Sv * 7 + F.Seed + Tm * 0.35) * 7 * Sv, Y);
  end;
  if Length(FPts) <> 2 * (N + 1) then SetLength(FPts, 2 * (N + 1));
  for Pass := 0 to 2 do
  begin
    Spd := 2 + Pass * 1.3;
    for I := 0 to N do
    begin
      Sv := I / N;
      A := Min(I + 1, N);
      B := Max(I - 1, 0);
      D := PointF(Ctr[A].X - Ctr[B].X, Ctr[A].Y - Ctr[B].Y);
      L := Sqrt(D.X * D.X + D.Y * D.Y);
      if L < 1e-4 then L := 1;
      Nrm := PointF(-D.Y / L, D.X / L);
      Wt := F.W * Scales[Pass] * Max(0, 1 - Power(Sv / Reach[Pass], 1.5));
      if Pass = 0 then Wt := Wt + 1.2;
      WL := Wt * (1 + 0.28 * Sin(Sv * 29 - Tm * Spd + F.Seed)
        + 0.14 * Sin(Sv * 61 - Tm * Spd * 1.7 + F.Seed * 1.9));
      WR := Wt * (1 + 0.28 * Sin(Sv * 31 - Tm * Spd * 1.1 + F.Seed + 1.3)
        + 0.14 * Sin(Sv * 57 - Tm * Spd * 1.6 + F.Seed * 2.3));
      FPts[I] := P(Ctr[I].X + Nrm.X * WL, Ctr[I].Y + Nrm.Y * WL);
      FPts[2 * (N + 1) - 1 - I] := P(Ctr[I].X - Nrm.X * WR, Ctr[I].Y - Nrm.Y * WR);
    end;
    case Pass of
      0: Color := clLavaEdge;
      1: Color := clLavaMid;
    else
      Color := clLavaCore;
    end;
    DPoly(FLayer, FPts, Color);
  end;
end;

{ Lava: the flows down the flanks and the pool on the shore. }
procedure TPainter.DrawLava;
var
  I: Integer;
  Pulse: Single;
begin
  // the lava lives between design rows ~700 and ~1145
  if (P(0, 1145).Y < 0) or (P(0, 690).Y > FTargetH) then Exit;
  for I := 0 to High(FScene.FFlows) do
    DrawFlow(FScene.FFlows[I]);
  Pulse := Sin(FScene.FTime * 2.2);
  Circle(FLayer, 560, 1128, 9 + Pulse, clPool1);
  Circle(FLayer, 574, 1126, 7 - Pulse * 0.7, clPool2);
  Circle(FLayer, 548, 1131, 5 + Pulse * 0.5, clLavaCore);
end;

{ Fire: the boiling burst over the crater, on its own layer above the lava. }
procedure TPainter.DrawFire;
var
  I: Integer;
  X, Y, R, Tm: Single;
begin
  Tm := FScene.FTime;
  // the burst lives between design rows ~560 and ~730
  if (P(0, 735).Y < 0) or (P(0, 555).Y > FTargetH) then Exit;

  // a fixed lava mass sits in the crater so the burst never looks empty
  for I := 0 to 6 do
    Sprite(FLayer, 3, CraterX - 27 + I * 9, RimY - 6 + Sin(Tm * 3 + I) * 2,
      Round(S(13 + Sin(Tm * 2.6 + I * 1.3) * 2)));

  for I := 0 to High(FScene.FBlobs) do
    with FScene.FBlobs[I] do
    begin
      if Yellow then
      begin
        X := CraterX + Lat * (12 + Sin(U * Pi) * 26);
        Y := RimY - 2 - U * 95;
        R := RBase * (0.5 + 0.6 * Sin(Pi * Min(1, U * 1.15)));
        Sprite(FLayer, 5, X, Y, Round(S(R)));
      end
      else
      begin
        X := CraterX + Lat * (18 + Sin(U * Pi) * 34);
        Y := RimY + 4 - U * 125;
        R := RBase * (0.55 + 0.6 * Sin(Pi * Min(1, U * 1.1)));
        if U > 0.78 then
          Sprite(FLayer, 4, X, Y, Round(S(R)))
        else
          Sprite(FLayer, 3, X, Y, Round(S(R)));
      end;
    end;
end;

{ Sea body sprite plus wave lines that roll left and right. }
procedure TPainter.DrawSea;
var
  N, Row: Integer;
  X, Y, Bottom, Dir, Tm: Single;
begin
  if (P(0, 1275).Y < 0) or (P(0, 1130).Y > FTargetH) then Exit;
  Tm := FScene.FTime;
  DBlit(FLayer, FScene.FSeaPos.X, FScene.FSeaPos.Y - FLayerTop, FScene.FSeaBody, FScene.FSvgSea, True);
  if Length(FWave) < 200 then SetLength(FWave, 200);
  Row := 0;
  Y := 1160;
  while Y < 1255 do
  begin
    if Odd(Row) then Dir := -1 else Dir := 1;
    N := 0;
    X := 26;
    if not RowsHit(Y - 6, Y + 6) then X := 710;  // row outside this band
    while X < 710 do
    begin
      Bottom := 1180 + 80 * Sqrt(Max(0, 1 - Sqr((X - 368) / 352)));
      if Y + 6 < Bottom then
      begin
        FWave[N] := P(X, Y + Sin(X * 0.08 + Row * 1.7 - Dir * Tm * (1.4 + Row * 0.15)) * 2.8
          + Sin(Tm * 0.9 + Row) * 1.2);
        Inc(N);
      end;
      X := X + 5;
    end;
    if N > 1 then
      DPolyLine(FLayer, Copy(FWave, 0, N), clWave, Max(0.8, S(1.5)));
    Y := Y + 11;
    Inc(Row);
  end;
end;

procedure TPainter.DrawGlow(Dest: TBGRABitmap);
var
  C: TPointF;
  R, Tm: Single;
  A: Byte;
begin
  Tm := FScene.FTime;
  C := P(CraterX, CraterY - 20);
  R := S(140 * (1 + 0.07 * Sin(Tm * 2.3)));
  if (C.Y + R < 0) or (C.Y - R > FTargetH) then Exit;
  A := Round(70 + 30 * Sin(Tm * 3.1));
  DRadialRect(Dest, Round(C.X - R), Round(C.Y - R), Round(C.X + R), Round(C.Y + R),
    BGRA(255, 150, 40, A), BGRA(255, 120, 20, 0), C, PointF(C.X + R, C.Y));
end;

procedure TPainter.DrawEmbers(Dest: TBGRABitmap);
var
  I: Integer;
  Q: TPointF;
  Fade, Flick, R: Single;
begin
  for I := 0 to High(FScene.FEmbers) do
    with FScene.FEmbers[I] do
    begin
      Q := P(X, Y);
      R := S(Size * 2.4);
      if (Q.Y + R < 0) or (Q.Y - R > FTargetH) then Continue;
      Fade := EnsureRange(Life / MaxLife * 1.6, 0, 1);
      Flick := 0.6 + 0.4 * Sin(FScene.FTime * 11 + Phase);
      DEllipse(Dest, Q.X, Q.Y, R, R, BGRA(255, 120, 30, Round(50 * Fade * Flick)));
      DEllipse(Dest, Q.X, Q.Y, S(Size), S(Size),
        BGRA(255, Round(150 + 80 * Flick), 60, Round(255 * Fade)));
    end;
end;

procedure TPainter.DrawAsh(Dest: TBGRABitmap);
var
  I, K: Integer;
  Pts: array[0..3] of TPointF;
  Fade, A: Single;
  Q: TPointF;
begin
  for I := 0 to High(FScene.FAsh) do
    with FScene.FAsh[I] do
    begin
      Q := P(X, Y);
      if (Q.Y + S(Size) < 0) or (Q.Y - S(Size) > FTargetH) then Continue;
      Fade := EnsureRange(Life / MaxLife * 2, 0, 1);
      for K := 0 to 3 do
      begin
        A := Phase + K * Pi / 2;
        Pts[K] := P(X + Cos(A) * Size * (1 - 0.4 * Ord(Odd(K))),
          Y + Sin(A) * Size * (1 - 0.4 * Ord(Odd(K))));
      end;
      DPoly(Dest, Pts, BGRA(25, 25, 25, Round(230 * Fade)));
    end;
end;

procedure TPainter.DrawBirds(Dest: TBGRABitmap);
var
  I, Pass: Integer;
  Pts: array[0..7] of TPointF;
  Tip, Sz, Dx, Dy, Dir: Single;
  C: TBGRAPixel;
  Q: TPointF;
begin
  for Pass := 0 to 1 do  // 0 = paper shadow, 1 = bird
    for I := 0 to High(FScene.FBirds) do
      with FScene.FBirds[I] do
      begin
        Sz := Size;
        Q := P(X, Y);
        if (Q.Y + S(Sz + 6) < 0) or (Q.Y - S(Sz) > FTargetH) then Continue;
        Tip := -Sz * 0.75 * Sin(Phase);
        Dir := Sign(VX);
        if Pass = 0 then
        begin
          Dx := 2.5; Dy := 5; C := BGRA(0, 0, 0, 45);
        end
        else
        begin
          Dx := 0; Dy := 0; C := clBird;
        end;
        Pts[0] := P(X + Dx - Sz, Y + Dy + Tip);
        Pts[1] := P(X + Dx - Sz * 0.4, Y + Dy - Sz * 0.2 + Tip * 0.4);
        Pts[2] := P(X + Dx + Dir * Sz * 0.12, Y + Dy - Sz * 0.05);
        Pts[3] := P(X + Dx + Sz * 0.4, Y + Dy - Sz * 0.2 + Tip * 0.4);
        Pts[4] := P(X + Dx + Sz, Y + Dy + Tip);
        Pts[5] := P(X + Dx + Sz * 0.4, Y + Dy + Sz * 0.05 + Tip * 0.4);
        Pts[6] := P(X + Dx, Y + Dy + Sz * 0.28);
        Pts[7] := P(X + Dx - Sz * 0.4, Y + Dy + Sz * 0.05 + Tip * 0.4);
        DPoly(Dest, Pts, C);
      end;
end;

procedure TPainter.DrawCaption(Dest: TBGRABitmap);
var
  A: TPointF;
begin
  if FScene.FCaption = nil then Exit;
  A := P(176, 17);
  if FSvg <> nil then
    FSvg.Raw(Format('<g transform="translate(%s,%s)">', [FSvg.N(Round(A.X)), FSvg.N(Round(A.Y))]) +
      LineEnding + FScene.FSvgCaption + '</g>');
  if FRaster then BlendBitmap(Dest, Round(A.X), Round(A.Y), FScene.FCaption);
end;

procedure TPainter.RenderBand(Dest: TBGRABitmap; ATop: Integer);
var
  Sc: TVolcanoScene;
  I, Y, W, H, R, MT, MB, LTop, LH: Integer;
  T0: Double;

  procedure Mark(Id: TLayerId);
  var
    T: Double;
  begin
    T := HiResMs;
    LayerMs[Id] := LayerMs[Id] + (T - T0);
    T0 := T;
  end;

begin
  Sc := FScene;
  W := Sc.FWidth;
  if Dest <> nil then H := Dest.Height else H := Sc.FHeight;
  T0 := HiResMs;

  if FSvg <> nil then
  begin
    if Sc.LayerOn[lyBackground] then
      FSvg.Raw(Sc.FSvgBack)
    else if not Sc.TransparentBack then
      FSvg.Rect(0, 0, W, H, '#F4F4F2');
  end;
  // background: copy this band's rows of the paper
  if FRaster then
    if Sc.LayerOn[lyBackground] then
    begin
      for Y := 0 to H - 1 do
        if ATop + Y < Sc.FHeight then
          Move(RowPtr(Sc.FBack, ATop + Y)^, RowPtr(Dest, Y)^, W * SizeOf(TBGRAPixel));
    end
    else if Sc.TransparentBack then
      Dest.FillTransparent
    else
      Dest.Fill(BGRA(244, 244, 242));
  Mark(lyBackground);

  { The work layer covers the band plus the rows whose shadows reach into it:
    shadows fall down by up to S(6 * MaxDepth) and blur over (2R + 2) cells of
    4 px. Its top is a multiple of 4 so every band samples the same grid. }
  R := Max(1, Round(S(7) * MaxDepth / 4));
  MB := (2 * R + 3) * 4;
  MT := Round(S(6) * MaxDepth) + MB;
  LTop := Floor((ATop - MT) / 4) * 4;
  LH := ATop + H + MB - LTop;
  if FRaster then
  begin
    if (FLayer.Width <> W) or (FLayer.Height <> LH) then
      FLayer.SetSize(W, LH);
    FLayerTop := LTop;
  end
  else
    FLayerTop := 0;

  if Sc.LayerOn[lyFarClouds] then
  begin
    BeginLayer;
    for I := 0 to High(Sc.FFarClouds) do
      DrawCloud(Sc.FFarClouds[I]);
    CompositeLayer(Dest, ATop, LayerDepth[lyFarClouds]);
  end;
  Mark(lyFarClouds);

  if Sc.LayerOn[lySmoke] then
  begin
    BeginLayer;
    DrawSmoke;
    CompositeLayer(Dest, ATop, LayerDepth[lySmoke]);
  end;
  Mark(lySmoke);

  if Sc.LayerOn[lyBackPalms] then
  begin
    BeginLayer;
    for I := 0 to High(Sc.FBackPalms) do
      DrawPalm(Sc.FBackPalms[I]);
    CompositeLayer(Dest, ATop, LayerDepth[lyBackPalms]);
  end;
  Mark(lyBackPalms);

  if Sc.LayerOn[lyVolcano] and (Sc.FVolcano <> nil) then
    DBlit(Dest, Sc.FVolcanoPos.X, Sc.FVolcanoPos.Y - ATop, Sc.FVolcano, Sc.FSvgVolcano);
  Mark(lyVolcano);

  if Sc.LayerOn[lyLava] then
  begin
    BeginLayer;
    DrawLava;
    CompositeLayer(Dest, ATop, LayerDepth[lyLava]);
  end;
  Mark(lyLava);

  if Sc.LayerOn[lyFire] then
  begin
    BeginLayer;
    DrawFire;
    CompositeLayer(Dest, ATop, LayerDepth[lyFire]);
  end;
  Mark(lyFire);

  if Sc.LayerOn[lyFrontPalms] then
  begin
    BeginLayer;
    for I := 0 to High(Sc.FFrontPalms) do
      DrawPalm(Sc.FFrontPalms[I]);
    CompositeLayer(Dest, ATop, LayerDepth[lyFrontPalms]);
  end;
  Mark(lyFrontPalms);

  if Sc.LayerOn[lySea] then
  begin
    BeginLayer;
    DrawSea;
    CompositeLayer(Dest, ATop, LayerDepth[lySea]);
  end;
  Mark(lySea);

  if Sc.LayerOn[lyLowClouds] then
  begin
    BeginLayer;
    for I := 0 to High(Sc.FLowClouds) do
      DrawCloud(Sc.FLowClouds[I]);
    CompositeLayer(Dest, ATop, LayerDepth[lyLowClouds]);
  end;
  Mark(lyLowClouds);

  // overlays go straight on the band
  FOrgX := Sc.FOffX;
  FOrgY := Sc.FOffY - ATop;
  FTargetH := H;
  if Sc.LayerOn[lyGlow] then DrawGlow(Dest);
  Mark(lyGlow);
  if Sc.LayerOn[lyAsh] then DrawAsh(Dest);
  Mark(lyAsh);
  if Sc.LayerOn[lyEmbers] then DrawEmbers(Dest);
  Mark(lyEmbers);
  if Sc.LayerOn[lyBirds] then DrawBirds(Dest);
  Mark(lyBirds);
  if Sc.FShowCaption and Sc.LayerOn[lyCaption] then DrawCaption(Dest);
  Mark(lyCaption);
  if Dest <> nil then Dest.InvalidateBitmap;
end;

{ ====================================================================== }
{ TVolcanoScene                                                          }
{ ====================================================================== }

constructor TVolcanoScene.Create;
const
  BackTrunk: array[0..2] of string = ('#3C3C3C', '#4A4A4A', '#555555');
var
  I: Integer;
begin
  inherited Create;
  FShowCaption := True;
  FillChar(LayerOn, SizeOf(LayerOn), 1);
  FVisL := 0;
  FVisR := DesignW;
  FScale := 1;
  FCutter := TPainter.Create(Self);
  RandSeed := 20261015;  // same paper cut every run

  SetLength(FFarClouds, 5);
  AddCloud(FFarClouds, 0, [60, 52, 18, 85, 40, 24, 115, 48, 20, 140, 56, 14, 40, 60, 12], True);
  AddCloud(FFarClouds, 1, [610, 120, 22, 640, 100, 30, 675, 112, 24, 700, 125, 16, 585, 130, 14], True);
  AddCloud(FFarClouds, 2, [95, 545, 26, 135, 520, 34, 180, 530, 30, 220, 548, 22, 70, 560, 16,
    250, 560, 14], True);
  AddCloud(FFarClouds, 3, [40, 700, 26, 85, 680, 36, 135, 690, 32, 180, 708, 24, 20, 720, 16], True);
  AddCloud(FFarClouds, 4, [500, 770, 30, 548, 745, 40, 600, 755, 34, 645, 770, 26, 470, 790, 18,
    680, 790, 16], True);

  SetLength(FLowClouds, 3);
  AddCloud(FLowClouds, 0, [95, 1225, 36, 140, 1218, 30, 55, 1250, 34, 120, 1258, 40, 175, 1252, 34,
    30, 1290, 34, 90, 1295, 38, 155, 1292, 34, 205, 1285, 26], False);
  AddCloud(FLowClouds, 1, [300, 1250, 34, 345, 1236, 32, 390, 1250, 38, 270, 1278, 32, 330, 1282, 40,
    400, 1290, 36, 440, 1276, 28, 250, 1300, 26], False);
  AddCloud(FLowClouds, 2, [540, 1232, 32, 590, 1220, 38, 640, 1236, 36, 690, 1258, 32, 505, 1262, 30,
    560, 1268, 40, 625, 1278, 38, 690, 1295, 34, 480, 1295, 28, 715, 1238, 22], False);

  SetLength(FBackPalms, 6);
  SetupPalm(FBackPalms[0], 120, 1060, 330, -0.08, 1.15, Hex(BackTrunk[0]), Hex(BackTrunk[0]), BGRAPixelTransparent);
  SetupPalm(FBackPalms[1], 45, 1075, 250, 0.12, 0.95, Hex(BackTrunk[1]), Hex(BackTrunk[1]), BGRAPixelTransparent);
  SetupPalm(FBackPalms[2], 175, 1060, 265, 0.12, 0.8, Hex(BackTrunk[2]), Hex(BackTrunk[2]), BGRAPixelTransparent);
  SetupPalm(FBackPalms[3], 675, 1050, 250, -0.1, 1.05, Hex(BackTrunk[0]), Hex(BackTrunk[0]), BGRAPixelTransparent);
  SetupPalm(FBackPalms[4], 600, 1050, 225, 0.05, 0.8, Hex(BackTrunk[1]), Hex(BackTrunk[1]), BGRAPixelTransparent);
  SetupPalm(FBackPalms[5], 712, 1075, 175, -0.12, 0.75, Hex(BackTrunk[2]), Hex(BackTrunk[2]), BGRAPixelTransparent);

  SetLength(FFrontPalms, 5);
  SetupPalm(FFrontPalms[0], 205, 1120, 95, -0.12, 0.62, Hex('#3E4B36'), Hex('#7CC242'), Hex('#4E9A2E'));
  SetupPalm(FFrontPalms[1], 268, 1122, 62, 0.1, 0.48, Hex('#3E4B36'), Hex('#86CC4C'), Hex('#4E9A2E'));
  SetupPalm(FFrontPalms[2], 432, 1122, 105, -0.05, 0.66, Hex('#3E4B36'), Hex('#7CC242'), Hex('#4E9A2E'));
  SetupPalm(FFrontPalms[3], 512, 1124, 88, 0.08, 0.58, Hex('#3E4B36'), Hex('#86CC4C'), Hex('#4E9A2E'));
  SetupPalm(FFrontPalms[4], 700, 1124, 100, -0.06, 0.64, Hex('#3E4B36'), Hex('#7CC242'), Hex('#4E9A2E'));

  SetLength(FFlows, 7);
  for I := 0 to High(FFlows) do
    FFlows[I].Seed := RandRange(0, 2 * Pi);
  FFlows[0].K := -0.80; FFlows[0].EndY := 1060; FFlows[0].W := 13;
  FFlows[1].K := -0.52; FFlows[1].EndY := 985;  FFlows[1].W := 9;
  FFlows[2].K := -0.22; FFlows[2].EndY := 1050; FFlows[2].W := 11;
  FFlows[3].K := 0.05;  FFlows[3].EndY := 1080; FFlows[3].W := 10;
  FFlows[4].K := 0.30;  FFlows[4].EndY := 1010; FFlows[4].W := 9;
  FFlows[5].K := 0.56;  FFlows[5].EndY := 990;  FFlows[5].W := 12;
  FFlows[6].K := 0.82;  FFlows[6].EndY := 1065; FFlows[6].W := 11;

  Randomize;
  SetLength(FPuffs, 230);
  for I := 0 to High(FPuffs) do
  begin
    if I < 95 then FPuffs[I].Depth := 0
    else if I < 170 then FPuffs[I].Depth := 1
    else FPuffs[I].Depth := 2;
    SpawnPuff(FPuffs[I], True);
  end;
  SetLength(FBlobs, 90);
  for I := 0 to High(FBlobs) do
  begin
    FBlobs[I].Yellow := I >= 52;
    SpawnBlob(FBlobs[I], True);
  end;
  SetLength(FEmbers, 40);
  for I := 0 to High(FEmbers) do
    SpawnEmber(FEmbers[I], True);
  SetLength(FAsh, 60);
  for I := 0 to High(FAsh) do
    SpawnAsh(FAsh[I], True);
  SetLength(FBirds, 14);
  for I := 0 to High(FBirds) do
    SpawnBird(FBirds[I], True);
end;

destructor TVolcanoScene.Destroy;
begin
  FreeResources;
  FCutter.Free;
  FStaticSvg.Free;
  inherited Destroy;
end;

function TVolcanoScene.P(X, Y: Single): TPointF;
begin
  Result := FCutter.P(X, Y);
end;

function TVolcanoScene.S(V: Single): Single;
begin
  Result := V * FScale;
end;

procedure TVolcanoScene.FreeResources;
var
  K, I: Integer;
begin
  for K := 0 to SpriteKinds - 1 do
  begin
    for I := 0 to High(FSprites[K]) do
      FSprites[K][I].Free;
    SetLength(FSprites[K], 0);
  end;
  for I := 0 to High(FFarClouds) do
    FreeAndNil(FFarClouds[I].Sprite);
  for I := 0 to High(FLowClouds) do
    FreeAndNil(FLowClouds[I].Sprite);
  FreeAndNil(FBack);
  FreeAndNil(FVolcano);
  FreeAndNil(FCaption);
  FreeAndNil(FSeaBody);
end;

procedure TVolcanoScene.Resize(AWidth, AHeight: Integer);
var
  T0: Double;
  K, R, N, MaxR: Integer;
begin
  T0 := HiResMs;
  FWidth := Max(1, AWidth);
  FHeight := Max(1, AHeight);
  FScale := Min(FWidth / DesignW, FHeight / DesignH);
  FOffX := Round((FWidth - DesignW * FScale) / 2);
  FOffY := Round((FHeight - DesignH * FScale) / 2);
  FVisL := -FOffX / FScale;
  FVisR := (FWidth - FOffX) / FScale;
  FreeResources;
  FBack := TBGRABitmap.Create(FWidth, FHeight);
  FCutter.FLayer.SetSize(FWidth, FHeight);
  FCutter.FLayerTop := 0;
  // vector export: the cutter records the static parts as SVG while it cuts them
  FreeAndNil(FStaticSvg);
  if FRecordSvg then FStaticSvg := TSvgRecorder.Create('s');
  FCutter.FSvg := FStaticSvg;
  try
    RenderStatic;
  finally
    FCutter.FSvg := nil;
  end;

  // every round sprite this size can need: smoke up to r = 105, lava up to 28
  N := 0;
  SetLength(FSpriteJobs, 0);
  for K := 0 to SpriteKinds - 1 do
  begin
    if K <= 2 then MaxR := Ceil(S(105)) else MaxR := Ceil(S(28));
    MaxR := Max(MaxR, 2);
    SetLength(FSprites[K], MaxR + 1);
    for R := 0 to MaxR do
      FSprites[K][R] := nil;
    SetLength(FSpriteJobs, N + MaxR);
    for R := 1 to MaxR do
    begin
      FSpriteJobs[N] := Point(K, R);
      Inc(N);
    end;
  end;
  StaticMs := HiResMs - T0;
  Inc(StaticCount);
end;

function TVolcanoScene.SpriteJobCount: Integer;
begin
  Result := Length(FSpriteJobs);
end;

{ Cuts one round sprite; safe on any thread (each job owns its slot). }
procedure TVolcanoScene.SpriteJob(AIndex, AWorker: Integer);
var
  K, R, Size: Integer;
  C: Single;
  B: TBGRABitmap;
begin
  K := FSpriteJobs[AIndex].X;
  R := FSpriteJobs[AIndex].Y;
  Size := 2 * R + 4;
  C := Size / 2 - 0.5;
  B := TBGRABitmap.Create(Size, Size);
  B.FillEllipseAntialias(C, C, R, R, SpriteFill[K]);
  if K <= 2 then
    B.EllipseAntialias(C, C, R, R, SpriteLine[K], Max(0.8, S(1.6)))
  else if K = 5 then
    B.EllipseAntialias(C, C, R * 0.5, R * 0.5, SpriteLine[K], Max(0.6, S(1.1)));
  FSprites[K][R] := B;
end;

{ Bakes the cutter layer and its soft shadow into a transparent bitmap. }
procedure TVolcanoScene.BakeLayer(Dest: TBGRABitmap; Depth: Single);
var
  Shadow: TBGRABitmap;
  Px: PBGRAPixel;
  I: Integer;
begin
  Shadow := TBGRABitmap.Create(FWidth, FHeight);
  try
    Shadow.PutImage(0, 0, FCutter.FLayer, dmSet);
    Px := Shadow.Data;
    for I := 0 to Shadow.NbPixels - 1 do
    begin
      Px^.red := 0;
      Px^.green := 0;
      Px^.blue := 0;
      Inc(Px);
    end;
    Shadow.InvalidateBitmap;
    BGRAReplace(Shadow, Shadow.FilterBlurRadial(Max(1, S(7) * Depth), rbFast));
    Dest.PutImage(Round(S(3) * Depth), Round(S(6) * Depth), Shadow, dmDrawWithTransparency, 110);
  finally
    Shadow.Free;
  end;
  Dest.PutImage(0, 0, FCutter.FLayer, dmDrawWithTransparency);
end;

{ Copies the part of the cutter layer inside the design rect R. }
function TVolcanoScene.CropLayer(const R: TRect; out Pos: TPoint): TBGRABitmap;
var
  A, B: TPointF;
  PR: TRect;
begin
  A := P(R.Left, R.Top);
  B := P(R.Right, R.Bottom);
  PR := Rect(Max(0, Floor(A.X)), Max(0, Floor(A.Y)), Min(FWidth, Ceil(B.X)), Min(FHeight, Ceil(B.Y)));
  if PR.Right <= PR.Left then PR.Right := PR.Left + 1;
  if PR.Bottom <= PR.Top then PR.Bottom := PR.Top + 1;
  Pos := PR.TopLeft;
  Result := TBGRABitmap(FCutter.FLayer.GetPart(PR));
end;

{ Cuts a cloud sprite. A black pass slightly larger than the white pass gives the
  thin ink outline. }
procedure TVolcanoScene.CutCloud(var C: TCloud);
var
  I: Integer;
  Ink: Single;
  Pos: TPoint;
begin
  FCutter.BeginLayer;
  FCutter.FOrgX := S(-C.MinX + 6);
  FCutter.FOrgY := S(-C.MinY + 6);
  C.Svg := '';
  Ink := Max(1.2 / FScale, 2.2);
  I := 0;
  while I + 2 <= High(C.Puffs) do
  begin
    FCutter.Circle(FCutter.FLayer, C.Puffs[I], C.Puffs[I + 1], C.Puffs[I + 2] + Ink, clInk);
    Inc(I, 3);
  end;
  I := 0;
  while I + 2 <= High(C.Puffs) do
  begin
    FCutter.Circle(FCutter.FLayer, C.Puffs[I], C.Puffs[I + 1], C.Puffs[I + 2], clWhite);
    Inc(I, 3);
  end;
  if FStaticSvg <> nil then C.Svg := FStaticSvg.Take(FCutter.FSvgMark);
  FCutter.FOrgX := 0;
  FCutter.FOrgY := 0;
  FreeAndNil(C.Sprite);
  C.Sprite := CropLayer(Rect(0, 0, Ceil(C.MaxX - C.MinX + 12), Ceil(C.MaxY - C.MinY + 12)), Pos);
end;

procedure TVolcanoScene.RenderStatic;
const
  N = 48;
var
  I, K: Integer;
  Px: PBGRAPixel;
  Noise, X, Y, Hw: Single;
  Pts: array of TPointF;
  Q: TPointF;
  Cut: TPainter;
begin
  RandSeed := 20261015;
  Cut := FCutter;

  { paper background with a little grain }
  FBack.GradientFill(0, 0, FWidth, FHeight, Hex('#F4F4F2'), Hex('#D6D6D4'),
    gtLinear, PointF(0, 0), PointF(0, FHeight), dmSet);
  Px := FBack.Data;
  for I := 0 to FBack.NbPixels - 1 do
  begin
    Noise := RandRange(-5, 5);
    Px^.red := EnsureRange(Round(Px^.red + Noise), 0, 255);
    Px^.green := EnsureRange(Round(Px^.green + Noise), 0, 255);
    Px^.blue := EnsureRange(Round(Px^.blue + Noise), 0, 255);
    Inc(Px);
  end;
  FBack.InvalidateBitmap;
  if FStaticSvg <> nil then
  begin
    I := FStaticSvg.Mark;
    FStaticSvg.Rect(0, 0, FWidth, FHeight, FStaticSvg.Gradient(MakeGrad(Hex('#F4F4F2'),
      Hex('#D6D6D4'), False, PointF(0, 0), PointF(0, FHeight))));
    FSvgBack := FStaticSvg.Take(I);
  end;

  { plump volcano cone: left flank up, crater rim, right flank down }
  Cut.BeginLayer;
  SetLength(Pts, 2 * (N + 1) + 5);
  K := 0;
  for I := 0 to N do
  begin
    Y := ConeBaseY - I * (ConeBaseY - RimY) / N;
    Pts[K] := PointF(CraterX - ConeHalfWidth(Y) + RandRange(-1.5, 1.5), Y);
    Inc(K);
  end;
  Pts[K] := PointF(CraterX - 14, RimY - 7); Inc(K);
  Pts[K] := PointF(CraterX - 4, RimY - 3); Inc(K);
  Pts[K] := PointF(CraterX + 6, RimY - 8); Inc(K);
  Pts[K] := PointF(CraterX + 16, RimY - 4); Inc(K);
  Pts[K] := PointF(CraterX + 22, RimY - 2); Inc(K);
  for I := 0 to N do
  begin
    Y := RimY + I * (ConeBaseY - RimY) / N;
    Pts[K] := PointF(CraterX + ConeHalfWidth(Y) + RandRange(-1.5, 1.5), Y);
    Inc(K);
  end;
  Cut.Poly(Cut.FLayer, Pts, clCone);

  { lighter front lobe gives the cone some roundness }
  K := 0;
  SetLength(Pts, 2 * (N + 1));
  for I := 0 to N do
  begin
    Y := ConeBaseY - I * (ConeBaseY - RimY - 40) / N;
    Pts[K] := PointF(CraterX - ConeHalfWidth(Y) * 0.62, Y);
    Inc(K);
  end;
  for I := 0 to N do
  begin
    Y := RimY + 40 + I * (ConeBaseY - RimY - 40) / N;
    Pts[K] := PointF(CraterX + ConeHalfWidth(Y) * 0.18, Y);
    Inc(K);
  end;
  Cut.Poly(Cut.FLayer, Pts, clLobe);

  { rock texture strokes follow the slope }
  for I := 1 to 240 do
  begin
    Y := RandRange(RimY + 15, ConeBaseY - 12);
    Hw := ConeHalfWidth(Y);
    X := CraterX + RandRange(-0.9, 0.9) * Hw;
    Q := P(X, Y);
    Cut.DLine(Cut.FLayer, Q.X, Q.Y, Q.X + S((X - CraterX) / Hw * 4),
      Q.Y + S(RandRange(5, 14)), clRock, Max(0.6, S(1.2)));
  end;

  { grass strip of the island }
  K := 0;
  SetLength(Pts, 60);
  for I := 0 to 55 do
  begin
    X := 14 + I * (708 / 55);
    Pts[K] := PointF(X, 1112 + Sin(I * 0.9) * 4 + RandRange(-3, 3));
    Inc(K);
  end;
  Pts[K] := PointF(722, 1140); Inc(K);
  Pts[K] := PointF(14, 1140); Inc(K);
  SetLength(Pts, K);
  Cut.Poly(Cut.FLayer, Pts, clGrass);
  Cut.Poly(Cut.FLayer, [PointF(14, 1130), PointF(722, 1130), PointF(722, 1140), PointF(14, 1140)],
    clGrassShade);

  Q := P(0, RimY - 20);
  if FStaticSvg <> nil then
    FSvgVolcano := '<g filter="url(#' + FStaticSvg.DropShadow(S(3) * LayerDepth[lyVolcano],
      S(6) * LayerDepth[lyVolcano], S(7) * LayerDepth[lyVolcano] * 0.5, 110 / 255) + ')">' +
      LineEnding + FStaticSvg.Take(Cut.FSvgMark) + '</g>';
  FVolcano := TBGRABitmap.Create(FWidth, FHeight);
  BakeLayer(FVolcano, LayerDepth[lyVolcano]);
  // keep only the rows the cone covers
  FVolcanoPos := Point(0, Max(0, Round(Q.Y)));
  BGRAReplace(FVolcano, FVolcano.GetPart(Rect(0, FVolcanoPos.Y, FWidth,
    Max(FVolcanoPos.Y + 1, Min(FHeight, Round(P(0, 1160).Y))))));

  for I := 0 to High(FFarClouds) do
    CutCloud(FFarClouds[I]);
  for I := 0 to High(FLowClouds) do
    CutCloud(FLowClouds[I]);

  { base plate + sea body }
  Cut.BeginLayer;
  Cut.Poly(Cut.FLayer, [PointF(10, 1137), PointF(726, 1137), PointF(726, 1150), PointF(10, 1150)],
    clInk);
  Cut.Poly(Cut.FLayer, [PointF(12, 1139), PointF(724, 1139), PointF(724, 1148), PointF(12, 1148)],
    clWhite);
  SetLength(Pts, N + 3);
  K := 0;
  Pts[K] := PointF(22, 1150); Inc(K);
  Pts[K] := PointF(714, 1150); Inc(K);
  for I := 0 to N do
  begin
    X := 714 - I * (692 / N);
    Pts[K] := PointF(X, 1180 + 80 * Sqrt(Max(0, 1 - Sqr((X - 368) / 352))));
    Inc(K);
  end;
  SetLength(Pts, K);
  Cut.Poly(Cut.FLayer, Pts, clSea);
  if FStaticSvg <> nil then FSvgSea := FStaticSvg.Take(Cut.FSvgMark);
  FSeaBody := CropLayer(Rect(0, 1130, DesignW, 1270), FSeaPos);

  { caption card (fonts: main thread only) }
  FCaption := TBGRABitmap.Create(Max(1, Round(S(392))), Max(1, Round(S(90))));
  FCaption.FillRoundRectAntialias(S(3), S(6), S(383), S(80), S(14), S(14), BGRA(0, 0, 0, 45));
  FCaption.FillRoundRectAntialias(S(1), S(1), S(381), S(75), S(14), S(14), BGRA(255, 255, 255, 235));
  FCaption.RoundRectAntialias(S(1), S(1), S(381), S(75), S(14), S(14), clInk, Max(1, S(2)));
  FCaption.FontName := 'Segoe UI';
  FCaption.FontQuality := fqFineAntialiasing;
  FCaption.FontStyle := [fsBold];
  FCaption.FontHeight := Max(8, Round(S(30)));
  FCaption.TextOut(S(191), S(9), 'VOLCANO ISLAND', Hex('#2B2B2B'), taCenter);
  FCaption.FontStyle := [];
  FCaption.FontHeight := Max(7, Round(S(15)));
  FCaption.TextOut(S(191), S(47), 'Space pause  V vsync  F11 full  S save  I info',
    clLavaEdge, taCenter);
  if FStaticSvg <> nil then
  begin
    I := FStaticSvg.Mark;
    FStaticSvg.RoundRect(S(3), S(6), S(383), S(80), S(14), S(14), BGRA(0, 0, 0, 45));
    FStaticSvg.RoundRect(S(1), S(1), S(381), S(75), S(14), S(14), BGRA(255, 255, 255, 235));
    FStaticSvg.RoundRect(S(1), S(1), S(381), S(75), S(14), S(14), clInk, Max(1, S(2)));
    FStaticSvg.Text(S(191), S(9), 'VOLCANO ISLAND', 'Segoe UI', Max(8, Round(S(30))), True,
      Hex('#2B2B2B'), True);
    FStaticSvg.Text(S(191), S(47), 'Space pause  V vsync  F11 full  S save  I info', 'Segoe UI',
      Max(7, Round(S(15))), False, clLavaEdge, True);
    FSvgCaption := FStaticSvg.Take(I);
  end;
  // settle the LCL/BGRA sync flags now, so threads only ever read these bitmaps
  FBack.LoadFromBitmapIfNeeded;
  FCaption.LoadFromBitmapIfNeeded;
  FCaption.InvalidateBitmap;
end;

{ ---------- setup ---------- }

procedure TVolcanoScene.AddCloud(var List: array of TCloud; Index: Integer;
  const Puffs: array of Single; Drift: Boolean);
var
  I: Integer;
  C: TCloud;
begin
  SetLength(C.Puffs, Length(Puffs));
  C.MinX := 1e9;
  C.MaxX := -1e9;
  C.MinY := 1e9;
  C.MaxY := -1e9;
  C.Sprite := nil;
  for I := 0 to High(Puffs) do
  begin
    C.Puffs[I] := Puffs[I];
    if I mod 3 = 0 then
    begin
      C.MinX := Min(C.MinX, Puffs[I] - Puffs[I + 2]);
      C.MaxX := Max(C.MaxX, Puffs[I] + Puffs[I + 2]);
      C.MinY := Min(C.MinY, Puffs[I + 1] - Puffs[I + 2]);
      C.MaxY := Max(C.MaxY, Puffs[I + 1] + Puffs[I + 2]);
    end;
  end;
  C.OX := 0;
  C.OY := 0;
  C.Drift := Drift;
  C.Speed := RandRange(5, 13);
  C.Phase := RandRange(0, 2 * Pi);
  List[Index] := C;
end;

procedure TVolcanoScene.SetupPalm(var Pm: TPalm; X, BaseY, H, Lean, Sc: Single;
  TrunkC, LeafC, RibC: TBGRAPixel);
const
  Angles: array[0..8] of Single = (-175, -150, -122, -95, -62, -35, -8, 160, 20);
var
  I: Integer;
begin
  Pm.X := X;
  Pm.BaseY := BaseY;
  Pm.H := H;
  Pm.Lean := Lean;
  Pm.Sc := Sc;
  Pm.TrunkC := TrunkC;
  Pm.LeafC := LeafC;
  Pm.RibC := RibC;
  Pm.Phase := RandRange(0, 2 * Pi);
  for I := 0 to 8 do
  begin
    Pm.LeafAng[I] := Angles[I] + RandRange(-8, 8);
    Pm.LeafLen[I] := 58 * RandRange(0.8, 1.15);
  end;
end;

procedure TVolcanoScene.SpawnPuff(var Pf: TPuff; Initial: Boolean);
begin
  if Initial then
    Pf.U := Random
  else
    Pf.U := 0;
  Pf.Speed := 1 / RandRange(20, 30);
  Pf.Lat := Random + Random - 1;  // bunched toward the middle of the column
  Pf.RMul := RandRange(0.6, 1.2);
  Pf.Wob := RandRange(0, 2 * Pi);
end;

procedure TVolcanoScene.SpawnBlob(var B: TBlob; Initial: Boolean);
begin
  if Initial then
    B.U := Random
  else
    B.U := 0;
  B.Speed := 1 / RandRange(1.1, 2.0);
  B.Lat := RandRange(-1, 1);
  if B.Yellow then
    B.RBase := RandRange(6, 12)
  else
    B.RBase := RandRange(11, 19);
end;

procedure TVolcanoScene.SpawnEmber(var E: TParticle; Initial: Boolean);
begin
  E.X := CraterX + RandRange(-25, 25);
  E.Y := CraterY - RandRange(0, 40);
  E.VX := RandRange(-12, 22);
  E.VY := -RandRange(35, 85);
  E.MaxLife := RandRange(4, 9);
  E.Life := E.MaxLife;
  E.Size := RandRange(1.6, 3.8);
  E.Phase := RandRange(0, 2 * Pi);
  if Initial then
  begin
    E.Life := RandRange(0, E.MaxLife);
    E.X := E.X + E.VX * (E.MaxLife - E.Life);
    E.Y := E.Y + E.VY * (E.MaxLife - E.Life);
  end;
end;

procedure TVolcanoScene.SpawnAsh(var A: TParticle; Initial: Boolean);
var
  Dir: Single;
begin
  Dir := IfThen(Random < 0.5, -1, 1);
  A.X := CraterX + RandRange(-20, 20);
  A.Y := CraterY - RandRange(10, 80);
  A.VX := Dir * RandRange(25, 110);
  A.VY := -RandRange(40, 140);
  A.MaxLife := RandRange(3, 6);
  A.Life := A.MaxLife;
  A.Size := RandRange(1.5, 4.5);
  A.Phase := RandRange(0, 2 * Pi);
  if Initial then
    A.Life := RandRange(0, A.MaxLife);
end;

procedure TVolcanoScene.SpawnBird(var B: TBird; Initial: Boolean);
var
  Dir: Single;
begin
  Dir := IfThen(Random < 0.75, 1, -1);  // most birds flee to the right
  B.Size := RandRange(10, 20);
  B.VX := Dir * RandRange(35, 70);
  B.VY := -RandRange(2, 14);
  B.Phase := RandRange(0, 2 * Pi);
  if Initial then
    B.X := RandRange(40, DesignW - 40)
  else if Dir > 0 then
    B.X := FVisL - RandRange(20, 80)
  else
    B.X := FVisR + RandRange(20, 80);
  B.Y := RandRange(130, 720);
end;

{ ---------- animation ---------- }

procedure TVolcanoScene.Update(DT: Single);
var
  I: Integer;
begin
  FTime := FTime + DT;
  for I := 0 to High(FPuffs) do
    with FPuffs[I] do
    begin
      U := U + DT * Speed;
      if U >= 1 then
        SpawnPuff(FPuffs[I], False);
    end;
  for I := 0 to High(FBlobs) do
    with FBlobs[I] do
    begin
      U := U + DT * Speed;
      if U >= 1 then
        SpawnBlob(FBlobs[I], False);
    end;
  for I := 0 to High(FFarClouds) do
    with FFarClouds[I] do
    begin
      OX := OX + Speed * DT;
      OY := Sin(FTime * 0.5 + Phase) * 3;
      if MinX + OX > FVisR + 10 then
        OX := FVisL - 10 - MaxX;  // re-enter from the left edge of the window
    end;
  for I := 0 to High(FLowClouds) do
    with FLowClouds[I] do
    begin
      OX := Sin(FTime * 0.22 + Phase) * 14;
      OY := Sin(FTime * 0.4 + Phase) * 3;
    end;
  for I := 0 to High(FEmbers) do
    with FEmbers[I] do
    begin
      Life := Life - DT;
      X := X + (VX + Sin(FTime * 1.5 + Phase) * 10) * DT;
      Y := Y + VY * DT;
      if (Life <= 0) or (Y < 40) then
        SpawnEmber(FEmbers[I], False);
    end;
  for I := 0 to High(FAsh) do
    with FAsh[I] do
    begin
      Life := Life - DT;
      VY := VY + 45 * DT;  // gravity
      X := X + VX * DT;
      Y := Y + VY * DT;
      Phase := Phase + DT * 4;
      if Life <= 0 then
        SpawnAsh(FAsh[I], False);
    end;
  for I := 0 to High(FBirds) do
    with FBirds[I] do
    begin
      X := X + VX * DT;
      Y := Y + VY * DT;
      Phase := Phase + DT * (9 + Size * 0.2);
      if (X > FVisR + 100) or (X < FVisL - 100) or (Y < 20) then
        SpawnBird(FBirds[I], False);
    end;
end;

{ Rising puffs. Each puff travels from the crater up and out through the top edge,
  growing as it goes. Positions are worked out and sorted once here, so the bands
  only blit. }
procedure TVolcanoScene.Prepare;
const
  Spread: array[0..2] of Single = (1.0, 0.8, 0.55);
  RDepth: array[0..2] of Single = (1.1, 1.0, 0.85);
  BaseY = RimY - 3;  // smoke leaves the crater right at its lip
var
  N, I, J: Integer;
  T, Cx, Hw, R: Single;
  Tmp: TPuffDraw;
  Key: array of Single;
  TmpKey: Single;
begin
  N := Length(FPuffs);
  if Length(FPuffDraw) <> N then SetLength(FPuffDraw, N);
  SetLength(Key, N);
  for I := 0 to N - 1 do
    with FPuffs[I] do
    begin
      T := 1 - Power(1 - U, 1.4);  // quick out of the crater, slow at the top
      Cx := CraterX + T * T * 80 - Sin(T * 5) * 18 * T + Sin(FTime * 0.45 + Wob) * 9 * T;
      Hw := 26 + T * 230 + IfThen(T > 0.55, (T - 0.55) * 380, 0);
      R := (15 + T * 62) * RMul * RDepth[Depth];
      if U < 0.05 then R := R * (0.3 + 0.7 * U / 0.05);
      FPuffDraw[I].X := EnsureRange(Cx + Lat * Hw * Spread[Depth] + Sin(FTime * 0.8 + Wob * 2) * 4,
        30, DesignW - 30);
      FPuffDraw[I].Y := BaseY - T * (BaseY + 110);  // leaves through the top edge
      FPuffDraw[I].Kind := Depth;
      FPuffDraw[I].RPx := Max(1, Round(S(R)));
      Key[I] := Depth * 10000 + FPuffDraw[I].Y;  // back sheet first, higher puffs first
    end;
  for I := 1 to N - 1 do
  begin
    Tmp := FPuffDraw[I];
    TmpKey := Key[I];
    J := I - 1;
    while (J >= 0) and (Key[J] > TmpKey) do
    begin
      FPuffDraw[J + 1] := FPuffDraw[J];
      Key[J + 1] := Key[J];
      Dec(J);
    end;
    FPuffDraw[J + 1] := Tmp;
    Key[J + 1] := TmpKey;
  end;
end;

procedure TVolcanoScene.CopyStateFrom(Src: TVolcanoScene);
var
  I: Integer;
begin
  FTime := Src.FTime;
  FPuffs := Copy(Src.FPuffs);
  FBlobs := Copy(Src.FBlobs);
  FEmbers := Copy(Src.FEmbers);
  FAsh := Copy(Src.FAsh);
  FBirds := Copy(Src.FBirds);
  for I := 0 to Min(High(FFarClouds), High(Src.FFarClouds)) do
  begin
    FFarClouds[I].OX := Src.FFarClouds[I].OX;
    FFarClouds[I].OY := Src.FFarClouds[I].OY;
  end;
  for I := 0 to Min(High(FLowClouds), High(Src.FLowClouds)) do
  begin
    FLowClouds[I].OX := Src.FLowClouds[I].OX;
    FLowClouds[I].OY := Src.FLowClouds[I].OY;
  end;
end;

procedure TVolcanoScene.RenderSvg(Svg: TSvgRecorder);
var
  Pt: TPainter;
begin
  Svg.AddDefsFrom(FStaticSvg);
  Pt := TPainter.Create(Self);
  try
    Pt.FSvg := Svg;
    Pt.FRaster := False;
    Pt.RenderBand(nil, 0);
  finally
    Pt.Free;
  end;
end;

{ ---------- developer information ---------- }

function TVolcanoScene.SpriteCount: Integer;
var
  K, I: Integer;
begin
  Result := 0;
  for K := 0 to SpriteKinds - 1 do
    for I := 0 to High(FSprites[K]) do
      if FSprites[K][I] <> nil then Inc(Result);
end;

function TVolcanoScene.SpriteBytes: Int64;
var
  K, I: Integer;
begin
  Result := 0;
  for K := 0 to SpriteKinds - 1 do
    for I := 0 to High(FSprites[K]) do
      if FSprites[K][I] <> nil then
        Inc(Result, Int64(FSprites[K][I].NbPixels) * 4);
  for I := 0 to High(FFarClouds) do
    if FFarClouds[I].Sprite <> nil then Inc(Result, Int64(FFarClouds[I].Sprite.NbPixels) * 4);
  for I := 0 to High(FLowClouds) do
    if FLowClouds[I].Sprite <> nil then Inc(Result, Int64(FLowClouds[I].Sprite.NbPixels) * 4);
  if FCaption <> nil then Inc(Result, Int64(FCaption.NbPixels) * 4);
  if FSeaBody <> nil then Inc(Result, Int64(FSeaBody.NbPixels) * 4);
end;

function TVolcanoScene.StaticBytes: Int64;
begin
  Result := 0;
  if FBack <> nil then Inc(Result, Int64(FBack.NbPixels) * 4);
  if FVolcano <> nil then Inc(Result, Int64(FVolcano.NbPixels) * 4);
  Inc(Result, Int64(FCutter.FLayer.NbPixels) * 4);
end;

function TVolcanoScene.DescribeParams: string;
var
  SL: TStringList;
  I: Integer;
  Id: TLayerId;

  function F(V: Single): string;
  begin
    Result := FormatFloat('0.##', V);
  end;

  procedure Palms(const Title: string; const A: array of TPalm);
  var
    J: Integer;
  begin
    SL.Add(Title);
    SL.Add('  #   X      BaseY  H      Lean   Scale  Trunk    Leaf     Rib');
    for J := 0 to High(A) do
      with A[J] do
        SL.Add(Format('  %d   %-6s %-6s %-6s %-6s %-6s %-8s %-8s %s', [J, F(X), F(BaseY), F(H),
          F(Lean), F(Sc), BGRAToStr(TrunkC), BGRAToStr(LeafC),
          IfThen(RibC.alpha = 0, '-', BGRAToStr(RibC))]));
  end;

  procedure Clouds(const Title: string; const A: array of TCloud);
  var
    J: Integer;
  begin
    SL.Add(Title);
    SL.Add('  #   Puffs  Box (design px)              Speed  Mode   Offset');
    for J := 0 to High(A) do
      with A[J] do
        SL.Add(Format('  %d   %-6d %-28s %-6s %-6s %s, %s', [J, Length(Puffs) div 3,
          Format('%s,%s - %s,%s', [F(MinX), F(MinY), F(MaxX), F(MaxY)]),
          F(Speed), IfThen(Drift, 'drift', 'bob'), F(OX), F(OY)]));
  end;

begin
  SL := TStringList.Create;
  try
    SL.Add('DESIGN SPACE');
    SL.Add(Format('  %d x %d design px, crater (%d, %d), rim y %d, cone base y %d',
      [DesignW, DesignH, CraterX, CraterY, RimY, ConeBaseY]));
    SL.Add(Format('  window %d x %d, scale %s, offset (%s, %s), visible x %s .. %s',
      [FWidth, FHeight, FormatFloat('0.0000', FScale), F(FOffX), F(FOffY), F(FVisL), F(FVisR)]));
    SL.Add('');
    SL.Add('LAYERS (back to front)');
    SL.Add('  Layer          Kind            Shadow  Notes');
    for Id := Low(TLayerId) to High(TLayerId) do
      SL.Add(Format('  %-14s %-15s %-7s %s', [LayerNames[Id], LayerKinds[Id],
        IfThen(LayerDepth[Id] = 0, '-', F(LayerDepth[Id])), LayerNotes[Id]]));
    SL.Add('');
    SL.Add('VOLCANO CONE');
    SL.Add('  half width(y) = 26 + 332 * u^0.6,  u = (y - 705) / (1128 - 705) clamped 0..1');
    SL.Add('  front lobe: x from -0.62 * hw to +0.18 * hw, colour #353535');
    SL.Add('');
    SL.Add('LAVA FLOWS  (x = crater + K * 0.92 * hw(y) + sin(s*7 + seed + t*0.35) * 7 * s)');
    SL.Add('  #   K       EndY   Width  Seed');
    for I := 0 to High(FFlows) do
      with FFlows[I] do
        SL.Add(Format('  %d   %-7s %-6s %-6s %s', [I, F(K), F(EndY), F(W), F(Seed)]));
    SL.Add('  3 passes: #E0441A x1.00 (full), #F7861E x0.62 (88%), #FFC23A x0.30 (66%)');
    SL.Add('  edge = w * (1 + 0.28 sin(s*29 - t*v) + 0.14 sin(s*61 - t*1.7v)), v = 2 + pass*1.3');
    SL.Add('');
    SL.Add('SMOKE');
    SL.Add(Format('  %d puffs (depth 0/1/2 = 95/75/60), life 20..30 s each', [Length(FPuffs)]));
    SL.Add('  t = 1 - (1 - u)^1.4;  y = 702 - t * 812 (starts at the crater lip);  r = (15 + 62 t) * rmul * (1.1/1.0/0.85)');
    SL.Add('  centre x = 375 + 80 t^2 - 18 t sin(5t) + 9 t sin(0.45 time + wob)');
    SL.Add('  half width = 26 + 230 t (+ 380 (t - 0.55) above t = 0.55), spread 1.0/0.8/0.55');
    SL.Add('  positions are computed and depth-sorted once per frame (Prepare), bands only blit');
    SL.Add('');
    SL.Add('FIRE');
    SL.Add(Format('  %d blobs (52 orange, rest yellow), each rises over 1.1..2.0 s', [Length(FBlobs)]));
    SL.Add('  orange: y = 709 - 125 u, red-orange above u = 0.78;  yellow: y = 703 - 95 u');
    SL.Add('');
    SL.Add('PARTICLES');
    SL.Add(Format('  embers %d, ash %d, birds %d', [Length(FEmbers), Length(FAsh), Length(FBirds)]));
    SL.Add('');
    Clouds('FAR CLOUDS', FFarClouds);
    SL.Add('');
    Clouds('LOW CLOUDS', FLowClouds);
    SL.Add('');
    Palms('BACK PALMS', FBackPalms);
    SL.Add('');
    Palms('FRONT PALMS', FFrontPalms);
    SL.Add('');
    SL.Add('SPRITE CACHE  (kind: 0..2 smoke depth, 3 orange, 4 red-orange, 5 yellow)');
    for I := 0 to SpriteKinds - 1 do
      SL.Add(Format('  kind %d: radius 1..%d px', [I, High(FSprites[I])]));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

initialization
  clInk := Hex('#1A1A1A');
  clWhite := Hex('#FFFFFF');
  clLavaEdge := Hex('#E0441A');
  clLavaMid := Hex('#F7861E');
  clLavaCore := Hex('#FFC23A');
  clPool1 := Hex('#F26A1B');
  clPool2 := Hex('#FFA41B');
  clWave := Hex('#22313B');
  clBird := Hex('#161616');
  clCone := Hex('#2F2F2F');
  clLobe := Hex('#353535');
  clRock := Hex('#474747');
  clGrass := Hex('#6DB33F');
  clGrassShade := Hex('#4E9A2E');
  clSea := Hex('#3E5566');
  SpriteFill[0] := Hex('#232323');
  SpriteFill[1] := Hex('#2E2E2E');
  SpriteFill[2] := Hex('#3A3A3A');
  SpriteFill[3] := Hex('#F7861E');
  SpriteFill[4] := Hex('#E8501E');
  SpriteFill[5] := Hex('#FFC23A');
  SpriteLine[0] := Hex('#161616');
  SpriteLine[1] := Hex('#202020');
  SpriteLine[2] := Hex('#2A2A2A');
  SpriteLine[3] := Hex('#F7861E');
  SpriteLine[4] := Hex('#E8501E');
  SpriteLine[5] := Hex('#F09A1E');
end.
