unit uVolcanoScene;

{ Volcano island 02 - a bigger, more detailed and more realistic island.

  The picture is laid out in a 736 x 1308 "design space" (portrait) and scaled
  to fit the window. The island is far wider than the design space: the cone
  flanks, the jungle, the beach and the sea run past both window edges, at any
  window shape.

  Back to front: sky, far clouds (drifting right to left), smoke, volcano cone,
  lava, near clouds (left to right), jungle with swaying palms, beach, sea with
  waves rolling onto the shore, crabs, boat, jumping fish, then the crater
  glow, ash, embers, birds and the caption.

  TVolcanoScene holds the state and every read-only resource cut once per window
  size (sky, cone, jungle, beach, sea body, cloud sprites, round sprites), so
  worker threads only read it. TPainter renders one horizontal band of the
  frame; one painter per worker thread. }

{$mode objfpc}{$H+}
{$INLINE ON}

interface

uses
  Classes, SysUtils, StrUtils, Math, Graphics, BGRABitmap, BGRABitmapTypes,
  BGRAGradientScanner, uRenderPool, uSvgRecorder;

const
  DesignW = 736;
  DesignH = 1308;
  CraterX = 368;
  CraterY = 512;     // smoke and sparks start here
  RimY = 528;        // top of the cone
  ConeBaseY = 1010;  // the cone meets the jungle
  JungleTopY = 905;  // average top of the jungle canopy
  BeachTopY = 1040;  // jungle ends, sand starts
  ShoreBaseY = 1100; // average water line
  SeaBottomY = 1320;
  SpriteKinds = 6;   // 0..2 smoke depth, 3 orange lava, 4 red-orange lava, 5 yellow lava
  MaxDepth = 0.9;    // deepest paper shadow of a layer that uses the shadow pass

type
  TParticle = record
    X, Y, VX, VY, Life, MaxLife, Size, Phase: Single;
  end;

  TBird = record
    X, Y, VX, VY, Size, Phase: Single;
  end;

  TCloud = record
    Puffs: array of Single;  // x, y, r triples (design units)
    MinX, MaxX, MinY, MaxY: Single;
    OX, OY, Speed, Phase: Single;
    Sprite: TBGRABitmap;     // cut once per window size
    Svg: string;             // the same cloud as SVG (vector export), local coordinates
  end;

  TPalm = record
    X, BaseY, H, Lean, Sc, Phase: Single;
    LeafAng, LeafLen: array[0..9] of Single;
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

  TCrab = record
    X, Y, VX, Timer, LegPhase, Size: Single;
    Walking: Boolean;
  end;

  TFish = record
    X0, Y0, Dir, Dist, Height, T, Dur, Wait, Size: Single;  // T < 0 = waiting
  end;

  TBoat = record
    X, Y, Speed, Size, Phase: Single;
  end;

  { Everything the frame is made of, back to front. }
  TLayerId = (lySky, lyFarClouds, lySmoke, lyVolcano, lyLava, lyFire, lyNearClouds, lyJungle,
    lyBeach, lySea, lyCrabs, lyBoat, lyFish, lyGlow, lyAsh, lyEmbers, lyBirds, lyCaption);

const
  LayerNames: array[TLayerId] of string = ('Sky', 'Far clouds', 'Smoke', 'Volcano',
    'Lava', 'Fire burst', 'Near clouds', 'Jungle + palms', 'Beach', 'Sea + waves', 'Crabs',
    'Boat', 'Fish', 'Crater glow', 'Ash', 'Embers', 'Birds', 'Caption');
  LayerKinds: array[TLayerId] of string = ('static rows', 'sprites', 'sprites',
    'static', 'vector', 'sprites', 'sprites', 'static+vector', 'static', 'static+vector',
    'vector', 'vector', 'vector', 'overlay', 'overlay', 'overlay', 'overlay', 'static');
  { paper shadow depth: offset (3, 6) * depth, blur 7 * depth (design px);
    0 = drawn straight onto the band, no shadow pass }
  LayerDepth: array[TLayerId] of Single = (0, 0, 0, 0, 0, 0, 0, 0.9, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0);
  LayerNotes: array[TLayerId] of string = (
    'Sky gradient (blue -> warm haze), sun glow and grain; bands copy their rows',
    '6 shaded, blurred cumulus drifting RIGHT TO LEFT, slower (far away)',
    '260 shaded puffs on 3 depth sheets rising out of the crater and off the top',
    'Lit / shaded cone (half width 46 + 640 u^0.72), 46 gullies, speckles, old lava',
    '7 lava rivers with glow and travelling wavy edges down the flanks',
    'Fire over the crater: a boiling lava mass and 90 blobs bursting up, own layer',
    '4 big shaded clouds drifting LEFT TO RIGHT, faster (near)',
    'Canopy of 1000+ bushes (static) + 16 palms swaying, with a soft shadow',
    'Sand gradient, wet sand, rocks and shells (static)',
    'Sea gradient + 4 waves rolling in and breaking, swash foam on the sand',
    '6 crabs walking sideways on the sand, legs moving, stop and turn',
    'Sailboat drifting left to right, bobbing, with wake and reflection',
    '3 fish jumping out of the sea with splash rings',
    'Radial glow over the crater, pulsing radius and alpha',
    '70 flakes thrown out of the crater, rotate and fall with gravity',
    '50 sparks rising with sideways wobble, flicker',
    '12 birds flying away from the eruption',
    'Title card with hotkeys, cut once per window size');

  PaletteNames: array[0..27] of string = ('Sky top', 'Sky haze', 'Cloud lit',
    'Cloud shade', 'Smoke light', 'Smoke dark', 'Cone lit', 'Cone shade', 'Gully',
    'Old lava', 'Lava edge', 'Lava mid', 'Lava core', 'Jungle dark', 'Jungle mid',
    'Jungle light', 'Palm leaf', 'Palm trunk', 'Sand dry', 'Sand wet', 'Rock',
    'Sea shallow', 'Sea deep', 'Foam', 'Crab', 'Boat hull', 'Sail', 'Fish back');
  PaletteHex: array[0..27] of string = ('#6FA3D2', '#EBDCC6', '#FFFFFF', '#AEB9C8',
    '#6C6C70', '#232326', '#7A6857', '#2A2320', '#1E1917', '#3B1F17', '#E0441A',
    '#F7861E', '#FFC23A', '#1E3A1C', '#2F5A28', '#5E9238', '#4F8A2E', '#6B4F35',
    '#EAD6A6', '#B99A6E', '#7D7A74', '#5DC2BE', '#134F78', '#FFFFFF', '#D9532B',
    '#6B3A22', '#F4F2EA', '#4F6F8F');

type
  TVolcanoScene = class;

  { TPainter: renders frame rows into a band bitmap. One per worker thread. }

  TPainter = class
  private
    FScene: TVolcanoScene;
    FLayer: TBGRABitmap;      // work layer, frame rows [FLayerTop, FLayerTop + height)
    FLayerTop: Integer;
    FOrgX, FOrgY: Single;     // P() origin in pixels of the current target
    FTargetH: Integer;        // height of the current target (row culling)
    FShadow, FBlurTmp, FRow: array of Single;
    FXIdx: array of Integer;
    FXFrac: array of Single;
    FPts, FMid, FTrunk, FWave, FScaled: array of TPointF;
    FSvg: TSvgRecorder;       // vector mode: shapes are recorded here
    FRaster: Boolean;         // draw pixels (False in pure vector mode)
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
    procedure TargetBand(ATop, AHeight: Integer);
    procedure CompositeLayer(Dest: TBGRABitmap; DestTop: Integer; Depth: Single);
    procedure Circle(Bmp: TBGRABitmap; X, Y, R: Single; C: TBGRAPixel);
    procedure Poly(Bmp: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel);
    procedure Leaf(Bmp: TBGRABitmap; Base, Ctrl, Tip: TPointF; W: Single; C, Rib: TBGRAPixel);
    procedure Sprite(Bmp: TBGRABitmap; Kind: Integer; X, Y: Single; RPx: Integer);
    procedure DrawPalm(Bmp: TBGRABitmap; const Pm: TPalm; Dark: Boolean);
    procedure DrawClouds(Dest: TBGRABitmap; const List: array of TCloud);
    procedure DrawSmoke(Dest: TBGRABitmap);
    procedure DrawFlow(Dest: TBGRABitmap; const F: TFlow);
    procedure DrawLava(Dest: TBGRABitmap);
    procedure DrawFire(Dest: TBGRABitmap);
    procedure DrawSea(Dest: TBGRABitmap);
    procedure DrawCrabs(Dest: TBGRABitmap);
    procedure DrawBoat(Dest: TBGRABitmap);
    procedure DrawFish(Dest: TBGRABitmap);
    procedure DrawGlow(Dest: TBGRABitmap);
    procedure DrawEmbers(Dest: TBGRABitmap);
    procedure DrawAsh(Dest: TBGRABitmap);
    procedure DrawBirds(Dest: TBGRABitmap);
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
    FBack: TBGRABitmap;              // sky, window sized
    FVolcano, FJungle, FBeach, FSeaBody, FCaption: TBGRABitmap;  // cropped static sprites
    FVolcanoPos, FJunglePos, FBeachPos, FSeaPos: TPoint;
    FSprites: array[0..SpriteKinds - 1] of array of TBGRABitmap; // [kind][radius px]
    FSpriteJobs: array of TPoint;    // (kind, radius) of each sprite to cut
    FCutter: TPainter;               // full-frame painter used for the static cut
    FTime: Single;
    FFarClouds, FNearClouds: array of TCloud;
    FPalms: array of TPalm;
    FPuffs: array of TPuff;
    FPuffDraw: array of TPuffDraw;
    FBlobs: array of TBlob;
    FFlows: array of TFlow;
    FEmbers: array of TParticle;
    FAsh: array of TParticle;
    FBirds: array of TBird;
    FCrabs: array of TCrab;
    FFish: array of TFish;
    FBoat: TBoat;
    FShowCaption: Boolean;
    FRecordSvg: Boolean;             // record the static parts as SVG too (vector export)
    FStaticSvg: TSvgRecorder;        // defs of the static parts
    FSvgBack, FSvgVolcano, FSvgJungle, FSvgBeach, FSvgSea, FSvgCaption: string;
    function P(X, Y: Single): TPointF;
    function S(V: Single): Single;
    procedure AddCloud(var List: array of TCloud; Index: Integer; CX, CY, W, H, Speed: Single);
    procedure SetupPalm(var Pm: TPalm; X, BaseY, H, Lean, Sc: Single);
    procedure SpawnPuff(var Pf: TPuff; Initial: Boolean);
    procedure SpawnBlob(var B: TBlob; Initial: Boolean);
    procedure SpawnEmber(var E: TParticle; Initial: Boolean);
    procedure SpawnAsh(var A: TParticle; Initial: Boolean);
    procedure SpawnBird(var B: TBird; Initial: Boolean);
    procedure SpawnFish(var F: TFish; Initial: Boolean);
    procedure FreeResources;
    function CropLayer(Y0, Y1: Single; out Pos: TPoint): TBGRABitmap;
    procedure CutCloud(var C: TCloud; Far: Boolean);
    procedure CutSky;
    procedure CutVolcano;
    procedure CutJungle;
    procedure CutBeach;
    procedure CutSea;
    procedure CutCaption;
    procedure RenderStatic;
  public
    LayerOn: array[TLayerId] of Boolean;   // switch single layers off for debugging
    TransparentBack: Boolean;              // sky off -> transparent (layer export)
    StaticMs: Double;                      // last static cut (resize), main thread part
    StaticCount: Integer;
    constructor Create;
    destructor Destroy; override;
    { window size changed: cuts sky, cone, jungle, beach, sea, clouds, caption.
      Main thread only (fonts). Then run SpriteJob for 0..SpriteJobCount-1 on any
      number of threads. }
    procedure Resize(AWidth, AHeight: Integer);
    function SpriteJobCount: Integer;
    procedure SpriteJob(AIndex, AWorker: Integer);
    procedure Update(DT: Single);
    { per frame, after Update and before the painters run: builds draw lists }
    procedure Prepare;
    { copies the animation state of another scene (export) }
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

{ the island geometry, in design units }
function ConeHalfWidth(Y: Single): Single;
function ShoreY(X: Single): Single;
function JungleTop(X: Single): Single;
function BeachTop(X: Single): Single;

implementation

{ colours used while rendering (read-only after initialization, shared by threads) }
var
  clInk, clWhite, clLavaEdge, clLavaMid, clLavaCore, clLavaGlow, clWave, clFoam,
  clCrab, clCrabDark, clCrabLeg, clHull, clSail, clSailShade, clFishBack, clFishBelly,
  clPalmTrunk, clPalmLeaf, clPalmLeafLight, clPalmDark, clBird: TBGRAPixel;
  SpriteFill: array[0..SpriteKinds - 1] of TBGRAPixel;   // centre / highlight
  SpriteEdge: array[0..SpriteKinds - 1] of TBGRAPixel;   // rim

function Hex(const S: string): TBGRAPixel;
begin
  Result := StrToBGRA(S);
end;

function WithAlpha(C: TBGRAPixel; A: Integer): TBGRAPixel; inline;
begin
  Result := C;
  Result.alpha := EnsureRange(A, 0, 255);
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

{ Half width of the cone at height Y; the power < 1 gives broad rounded shoulders
  and flanks that run out far past the window edges. }
function ConeHalfWidth(Y: Single): Single;
begin
  Result := 46 + 640 * Power(EnsureRange((Y - RimY) / (ConeBaseY - RimY), 0, 1), 0.72);
end;

function ShoreY(X: Single): Single;
begin
  Result := ShoreBaseY + 9 * Sin(X * 0.011) + 5 * Sin(X * 0.029 + 1.3);
end;

function JungleTop(X: Single): Single;
begin
  Result := JungleTopY + 22 * Sin(X * 0.013 + 0.4) + 10 * Sin(X * 0.041);
end;

function BeachTop(X: Single): Single;
begin
  Result := BeachTopY + 7 * Sin(X * 0.021 + 2) + 3 * Sin(X * 0.07);
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
  SetLength(FWave, 256);
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

{ True when design rows Y0..Y1 reach the current target; everything outside the
  band is skipped before any geometry is built. }
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
      90 / 255) + ')">' + LineEnding + Content + '</g>')
  else
    FSvg.Raw('<g>' + LineEnding + Content + '</g>');
end;



procedure TPainter.TargetBand(ATop, AHeight: Integer);
begin
  FOrgX := FScene.FOffX;
  FOrgY := FScene.FOffY - ATop;
  FTargetH := AHeight;
end;

{ Lays the work layer on the band with a soft shadow, in one pass.
  Shadow = layer alpha sampled every 4th pixel (grid aligned to frame rows), box
  blurred twice, then bilinearly stretched back while blending. Only the bounding
  box of what the layer holds is touched. Works on opaque and transparent bands. }
procedure TPainter.CompositeLayer(Dest: TBGRABitmap; DestTop: Integer; Depth: Single);
const
  F = 4;
  Strength = 90 / 255;
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
    Dst := RowPtr(Dest, Y);
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
  if Length(FScene.FSprites[Kind]) < 2 then Exit;
  RPx := EnsureRange(RPx, 1, High(FScene.FSprites[Kind]));
  Q := P(X, Y);
  if FSvg <> nil then
  begin
    // the same shaded ball as the sprite: one radial gradient per kind, lit upper left
    FSvg.EllipseFill(Q.X, Q.Y, RPx, RPx, FSvg.BoxRadial('sprite' + IntToStr(Kind),
      SpriteFill[Kind], SpriteEdge[Kind], 0.325, 0.3, 0.725));
    if Kind = 5 then
      FSvg.EllipseLine(Q.X, Q.Y, RPx * 0.5, RPx * 0.5, BGRA(240, 154, 30, 160), Max(0.6, S(1)));
  end;
  if not FRaster then Exit;
  Spr := FScene.FSprites[Kind][RPx];
  if Spr = nil then Exit;
  BlendBitmap(Bmp, Round(Q.X) - Spr.Width div 2, Round(Q.Y) - Spr.Height div 2, Spr);
end;

{ A palm frond: a tapered strip along a quadratic curve with a saw-tooth edge. }
procedure TPainter.Leaf(Bmp: TBGRABitmap; Base, Ctrl, Tip: TPointF; W: Single; C, Rib: TBGRAPixel);
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
  DPoly(Bmp, FPts, C);
  if Rib.alpha > 0 then
    DPolyLine(Bmp, FMid, Rib, Max(0.7, S(1.1)));
end;

{ A coconut palm: ringed trunk bending with the wind, two-tone fronds that wave
  on their own beat, coconuts under the crown. Dark = a silhouette further back. }
procedure TPainter.DrawPalm(Bmp: TBGRABitmap; const Pm: TPalm; Dark: Boolean);
const
  N = 14;
var
  Base, Top, Ctrl, B, D, Tip, LC: TPointF;
  I: Integer;
  T, W, L, A, Len, Sway, Tm: Single;
  Trunk, Ring, LeafC, LeafL, Rib: TBGRAPixel;
begin
  if not RowsHit(Pm.BaseY - Pm.H - 75 * Pm.Sc, Max(Pm.BaseY, Pm.BaseY - Pm.H + 75 * Pm.Sc) + 4) then
    Exit;
  if Dark then
  begin
    Trunk := clPalmDark; Ring := clPalmDark; LeafC := clPalmDark; LeafL := clPalmDark;
    Rib := BGRAPixelTransparent;
  end
  else
  begin
    Trunk := clPalmTrunk; Ring := BGRA(80, 58, 38, 160); LeafC := clPalmLeaf;
    LeafL := clPalmLeafLight; Rib := BGRAPixelTransparent;  // two-tone fronds, no rib lines
  end;
  Tm := FScene.FTime;
  Sway := Sin(Tm * 1.1 + Pm.Phase) + 0.35 * Sin(Tm * 2.3 + Pm.Phase * 1.7);
  Base := PointF(Pm.X, Pm.BaseY);
  Top := PointF(Pm.X + Pm.Lean * Pm.H + Sway * Pm.H * 0.02, Pm.BaseY - Pm.H);
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
  DPoly(Bmp, FTrunk, Trunk);
  if not Dark then
    for I := 1 to N - 1 do  // trunk rings
      if Odd(I) then
        DLine(Bmp, FTrunk[I].X, FTrunk[I].Y, FTrunk[2 * (N + 1) - 1 - I].X,
          FTrunk[2 * (N + 1) - 1 - I].Y, Ring, Max(0.6, S(0.9)));
  for I := 0 to 9 do
  begin
    A := DegToRad(Pm.LeafAng[I] + Sway * 3 + Sin(Tm * 1.9 + Pm.Phase + I * 0.7) * 4);
    Len := Pm.LeafLen[I] * Pm.Sc * (1 + 0.03 * Sin(Tm * 2.4 + I));
    Tip := PointF(Top.X + Cos(A) * Len, Top.Y + Sin(A) * Len * 0.55 + Len * 0.42);
    LC := PointF(Top.X + Cos(A) * Len * 0.55, Top.Y + Sin(A) * Len * 0.6 - Len * 0.22);
    if Odd(I) then
      Leaf(Bmp, Top, LC, Tip, 9 * Pm.Sc, LeafC, Rib)
    else
      Leaf(Bmp, Top, LC, Tip, 8 * Pm.Sc, LeafL, Rib);
  end;
  if not Dark then
  begin
    Circle(Bmp, Top.X - 3 * Pm.Sc, Top.Y + 5 * Pm.Sc, 3.2 * Pm.Sc, BGRA(92, 66, 34));
    Circle(Bmp, Top.X + 3 * Pm.Sc, Top.Y + 6 * Pm.Sc, 3.2 * Pm.Sc, BGRA(110, 80, 40));
  end;
  Circle(Bmp, Top.X, Top.Y + 1.5 * Pm.Sc, 4 * Pm.Sc, Trunk);
end;

procedure TPainter.DrawClouds(Dest: TBGRABitmap; const List: array of TCloud);
var
  I: Integer;
  Q: TPointF;
begin
  for I := 0 to High(List) do
    with List[I] do
    begin
      if (Sprite = nil) or not RowsHit(MinY + OY - 8, MaxY + OY + 8) then Continue;
      Q := P(MinX - 8 + OX, MinY - 8 + OY);
      if FSvg <> nil then
        FSvg.Raw(Format('<g transform="translate(%s,%s)">', [FSvg.N(Round(Q.X)), FSvg.N(Round(Q.Y))]) +
          LineEnding + Svg + '</g>');
      if FRaster then BlendBitmap(Dest, Round(Q.X), Round(Q.Y), Sprite);
    end;
end;

{ Smoke puffs come pre-sorted from TVolcanoScene.Prepare; the band only blits the
  shaded sprites that reach it. }
procedure TPainter.DrawSmoke(Dest: TBGRABitmap);
var
  I, Half: Integer;
  Q: TPointF;
begin
  for I := 0 to High(FScene.FPuffDraw) do
    with FScene.FPuffDraw[I] do
    begin
      Q := P(X, Y);
      Half := RPx + 3;
      if (Q.Y + Half < 0) or (Q.Y - Half > FTargetH) then Continue;
      Sprite(Dest, Kind, X, Y, RPx);
    end;
end;

{ A lava river on the flank with a soft glow. The edges are wavy and the ripples
  travel downhill (sin(s*k - time*w)), so the lava looks like it is flowing. }
procedure TPainter.DrawFlow(Dest: TBGRABitmap; const F: TFlow);
const
  N = 44;
  Scales: array[0..3] of Single = (2.4, 1, 0.6, 0.28);
  Reach: array[0..3] of Single = (1.05, 1, 0.86, 0.62);
var
  Ctr: array[0..N] of TPointF;
  Pass, I, A, B: Integer;
  Sv, Y, Wt, WL, WR, L, Spd, Tm: Single;
  D, Nrm: TPointF;
  Color: TBGRAPixel;
begin
  if not RowsHit(RimY - 8, F.EndY + F.W * 2.5 + 4) then Exit;
  Tm := FScene.FTime;
  for I := 0 to N do
  begin
    Sv := I / N;
    Y := RimY + 4 + (F.EndY - RimY - 4) * Sv;
    Ctr[I] := PointF(CraterX + F.K * ConeHalfWidth(Y) * 0.9 +
      Sin(Sv * 6 + F.Seed + Tm * 0.3) * 9 * Sv, Y);
  end;
  if Length(FPts) <> 2 * (N + 1) then SetLength(FPts, 2 * (N + 1));
  for Pass := 0 to 3 do
  begin
    Spd := 2 + Pass * 1.2;
    for I := 0 to N do
    begin
      Sv := I / N;
      A := Min(I + 1, N);
      B := Max(I - 1, 0);
      D := PointF(Ctr[A].X - Ctr[B].X, Ctr[A].Y - Ctr[B].Y);
      L := Sqrt(D.X * D.X + D.Y * D.Y);
      if L < 1e-4 then L := 1;
      Nrm := PointF(-D.Y / L, D.X / L);
      Wt := F.W * Scales[Pass] * Max(0, 1 - Power(Sv / Reach[Pass], 1.5)) * (0.55 + 0.45 * (1 - Sv * 0.5));
      if Pass <= 1 then Wt := Wt + 1;
      WL := Wt * (1 + 0.26 * Sin(Sv * 31 - Tm * Spd + F.Seed)
        + 0.12 * Sin(Sv * 63 - Tm * Spd * 1.7 + F.Seed * 1.9));
      WR := Wt * (1 + 0.26 * Sin(Sv * 29 - Tm * Spd * 1.1 + F.Seed + 1.3)
        + 0.12 * Sin(Sv * 57 - Tm * Spd * 1.6 + F.Seed * 2.3));
      FPts[I] := P(Ctr[I].X + Nrm.X * WL, Ctr[I].Y + Nrm.Y * WL);
      FPts[2 * (N + 1) - 1 - I] := P(Ctr[I].X - Nrm.X * WR, Ctr[I].Y - Nrm.Y * WR);
    end;
    case Pass of
      0: Color := WithAlpha(clLavaGlow, Round(55 + 15 * Sin(Tm * 2 + F.Seed)));
      1: Color := clLavaEdge;
      2: Color := clLavaMid;
    else
      Color := clLavaCore;
    end;
    DPoly(Dest, FPts, Color);
  end;
end;

{ Lava: the rivers running down the flanks. }
procedure TPainter.DrawLava(Dest: TBGRABitmap);
var
  I: Integer;
begin
  if not RowsHit(RimY - 10, 1000) then Exit;
  for I := 0 to High(FScene.FFlows) do
    DrawFlow(Dest, FScene.FFlows[I]);
end;

{ Fire: the boiling burst over the crater, on its own layer above the lava. }
procedure TPainter.DrawFire(Dest: TBGRABitmap);
var
  I: Integer;
  X, Y, R, Tm: Single;
begin
  if not RowsHit(RimY - 190, RimY + 30) then Exit;
  Tm := FScene.FTime;
  // a fixed lava mass fills the crater so the burst never looks empty
  for I := 0 to 8 do
    Sprite(Dest, 3, CraterX - 36 + I * 9, RimY - 4 + Sin(Tm * 3 + I) * 2,
      Round(S(15 + Sin(Tm * 2.6 + I * 1.3) * 2)));
  for I := 0 to High(FScene.FBlobs) do
    with FScene.FBlobs[I] do
    begin
      if Yellow then
      begin
        X := CraterX + Lat * (14 + Sin(U * Pi) * 32);
        Y := RimY - 4 - U * 120;
        R := RBase * (0.5 + 0.6 * Sin(Pi * Min(1, U * 1.15)));
        Sprite(Dest, 5, X, Y, Round(S(R)));
      end
      else
      begin
        X := CraterX + Lat * (22 + Sin(U * Pi) * 42);
        Y := RimY + 2 - U * 160;
        R := RBase * (0.55 + 0.6 * Sin(Pi * Min(1, U * 1.1)));
        if U > 0.75 then
          Sprite(Dest, 4, X, Y, Round(S(R)))
        else
          Sprite(Dest, 3, X, Y, Round(S(R)));
      end;
    end;
end;

{ Waves: three crests roll from the front of the picture up to the beach, get
  thinner and whiter as they near it and break; each arrival pushes a sheet of
  foamy water up the sand (swash), which then slides back. }
procedure TPainter.DrawSea(Dest: TBGRABitmap);
const
  Period = 10.0; // seconds a crest needs from the bottom to the beach
  Waves = 4;
  StepX = 7;
var
  I, N, K: Integer;
  X, X0, X1, Y, Y0, Y1, Pp, Tm, Th, Q, Sw, A: Single;
  Top: array of TPointF;
  Run: Integer;
begin
  if not RowsHit(ShoreBaseY - 40, SeaBottomY) then Exit;
  Tm := FScene.FTime;
  X0 := FScene.FVisL - 20;
  X1 := FScene.FVisR + 20;
  N := Ceil((X1 - X0) / StepX) + 1;
  SetLength(Top, N);
  if Length(FWave) < 2 * N + 2 then SetLength(FWave, 2 * N + 2);
  if Length(FScaled) < N + 2 then SetLength(FScaled, N + 2);

  { rolling crests }
  for K := 0 to Waves - 1 do
  begin
    Pp := Frac(Tm / Period + K / Waves);           // 0 = front, 1 = at the beach
    Th := 4 + 20 * (1 - Pp);                        // nearer = thicker band
    for I := 0 to N - 1 do
    begin
      X := X0 + I * StepX;
      Y := SeaBottomY + 30 + (ShoreY(X) + 3 - SeaBottomY - 30) * Power(Pp, 0.85) +
        (3 + 5 * (1 - Pp)) * Sin(X * 0.045 + K * 2.1 + Tm * 1.3) +
        2 * Sin(X * 0.11 - Tm * 2 + K);
      Top[I] := PointF(X, Y);
      FWave[I] := P(X, Y);
      FWave[2 * N - 1 - I] := P(X, Y + Th);
    end;
    // this crest only touches a narrow strip of rows: skip bands it misses
    Y0 := 1e9; Y1 := -1e9;
    for I := 0 to N - 1 do
    begin
      Y0 := Min(Y0, Top[I].Y);
      Y1 := Max(Y1, Top[I].Y);
    end;
    if not RowsHit(Y0 - 4, Y1 + Th + 4) then Continue;
    A := 55 + 95 * Pp;
    if Pp > 0.9 then A := A * (1 - Pp) / 0.1;  // breaks into the swash
    DPoly(Dest, Copy(FWave, 0, 2 * N), WithAlpha(clWave, Round(A)));
    // broken white foam line on the crest, drawn as a few long runs
    I := 0;
    while I < N - 1 do
    begin
      if Sin(Top[I].X * 0.05 + K * 3 + Tm * 0.6) > -0.35 + 0.6 * (1 - Pp) then
      begin
        Run := 0;
        while (I < N) and (Sin(Top[I].X * 0.05 + K * 3 + Tm * 0.6) > -0.35 + 0.6 * (1 - Pp)) do
        begin
          FScaled[Run] := P(Top[I].X, Top[I].Y);
          Inc(Run);
          Inc(I);
        end;
        if Run > 1 then
          DPolyLine(Dest, Copy(FScaled, 0, Run), WithAlpha(clFoam, Round(A * 2.2)),
            Max(1, S(1.2 + 2.8 * Pp)));
      end
      else
        Inc(I);
    end;
  end;

  { swash: water and foam running up the sand after each arrival }
  if not RowsHit(ShoreBaseY - 40, ShoreBaseY + 30) then Exit;
  Q := Frac(Tm / (Period / Waves));
  if Q < 0.22 then Sw := Q / 0.22 else Sw := 1 - (Q - 0.22) / 0.78;
  Sw := Sw * Sw * (3 - 2 * Sw);                    // smooth
  for I := 0 to N - 1 do
  begin
    X := X0 + I * StepX;
    Y := ShoreY(X) - (4 + 15 * Sw) * (0.75 + 0.25 * Sin(X * 0.023 + Tm * 0.7));
    Top[I] := PointF(X, Y);
    FWave[I] := P(X, Y);
    FWave[2 * N - 1 - I] := P(X, ShoreY(X) + 10);
  end;
  DPoly(Dest, Copy(FWave, 0, 2 * N), BGRA(120, 200, 205, 120));
  for I := 0 to N - 1 do
    FWave[I] := P(Top[I].X, Top[I].Y + 2 * Sin(Top[I].X * 0.2 + Tm * 3));
  DPolyLine(Dest, Copy(FWave, 0, N), WithAlpha(clFoam, 230), Max(1, S(2.4)));
  for I := 0 to N - 1 do
    FWave[I] := P(Top[I].X, Top[I].Y + 5 + 1.5 * Sin(Top[I].X * 0.13 - Tm * 2));
  DPolyLine(Dest, Copy(FWave, 0, N), WithAlpha(clFoam, 120), Max(0.8, S(1.2)));
end;

{ Crabs: red body, two claws, eye stalks and three legs a side that step in turn. }
procedure TPainter.DrawCrabs(Dest: TBGRABitmap);
var
  I, K, Side: Integer;
  Sz, LegA, Kx, Ky: Single;
  C, Q: TPointF;
begin
  if not RowsHit(BeachTopY - 10, ShoreBaseY + 20) then Exit;
  for I := 0 to High(FScene.FCrabs) do
    with FScene.FCrabs[I] do
    begin
      if (X < FScene.FVisL - 20) or (X > FScene.FVisR + 20) then Continue;
      Sz := Size;
      C := P(X, Y);
      // shadow on the sand
      DEllipse(Dest, C.X + S(1), C.Y + S(4 * Sz), S(9 * Sz), S(3 * Sz), BGRA(60, 40, 20, 70));
      // legs
      for Side := -1 to 1 do
      begin
        if Side = 0 then Continue;
        for K := 0 to 2 do
        begin
          LegA := Sin(LegPhase + K * 2.1 + Ord(Side > 0) * Pi) * 0.5;
          Kx := X + Side * (6 + K * 1.5) * Sz;
          Ky := Y + (-1 + K * 1.6) * Sz;
          Q := P(Kx + Side * 3 * Sz, Ky + (2.5 + LegA * 2) * Sz);
          DLine(Dest, P(X + Side * 4 * Sz, Ky).X, P(X, Ky).Y, P(Kx, Ky - 1.5 * Sz).X,
            P(Kx, Ky - 1.5 * Sz).Y, clCrabLeg, Max(0.7, S(1.1 * Sz)));
          DLine(Dest, P(Kx, Ky - 1.5 * Sz).X, P(Kx, Ky - 1.5 * Sz).Y, Q.X, Q.Y,
            clCrabLeg, Max(0.6, S(0.9 * Sz)));
        end;
      end;
      // body
      DEllipse(Dest, C.X, C.Y, S(7.5 * Sz), S(4.8 * Sz), clCrab);
      DEllipse(Dest, C.X, C.Y - S(1.2 * Sz), S(6 * Sz), S(2.6 * Sz), clCrabDark);
      // claws, raised a little while walking
      for Side := -1 to 1 do
      begin
        if Side = 0 then Continue;
        Q := P(X + Side * 9 * Sz, Y - (3.5 + Ord(Walking) * Sin(LegPhase * 0.5) * 1.2) * Sz);
        DLine(Dest, P(X + Side * 5 * Sz, Y - 1 * Sz).X, P(X, Y - 1 * Sz).Y, Q.X, Q.Y,
          clCrabLeg, Max(0.7, S(1.3 * Sz)));
        DEllipse(Dest, Q.X, Q.Y, S(2.8 * Sz), S(2.1 * Sz), clCrab);
      end;
      // eyes
      for Side := -1 to 1 do
      begin
        if Side = 0 then Continue;
        Q := P(X + Side * 2 * Sz, Y - 6 * Sz);
        DLine(Dest, Q.X, Q.Y, Q.X, C.Y - S(3.5 * Sz), clCrabLeg, Max(0.5, S(0.8 * Sz)));
        DEllipse(Dest, Q.X, Q.Y, S(1.1 * Sz), S(1.1 * Sz), BGRA(20, 20, 20));
      end;
    end;
end;

{ A small sailboat: hull, mast, main sail and jib, flag; it bobs and rolls on the
  swell, leaves a wake and has a soft reflection. }
procedure TPainter.DrawBoat(Dest: TBGRABitmap);
var
  Bx, By, Sz, Roll, Ca, Sa: Single;
  Pts: array[0..5] of TPointF;

  function R(DX, DY: Single): TPointF;
  begin
    Result := P(Bx + (DX * Ca - DY * Sa) * Sz, By + (DX * Sa + DY * Ca) * Sz);
  end;

begin
  with FScene.FBoat do
  begin
    Sz := Size;
    Bx := X;
    By := Y + 2.5 * Sin(FScene.FTime * 1.6 + Phase);
    Roll := DegToRad(3.5 * Sin(FScene.FTime * 1.25 + Phase));
  end;
  if not RowsHit(By - 70 * Sz, By + 30 * Sz) then Exit;
  if (Bx < FScene.FVisL - 80) or (Bx > FScene.FVisR + 80) then Exit;
  Ca := Cos(Roll);
  Sa := Sin(Roll);
  // wake and reflection
  DLine(Dest, R(-30, 6).X, R(-30, 6).Y, R(-70, 10).X, R(-70, 10).Y,
    WithAlpha(clFoam, 150), Max(0.7, S(1.4)));
  DLine(Dest, R(-30, 8).X, R(-30, 8).Y, R(-62, 16).X, R(-62, 16).Y,
    WithAlpha(clFoam, 110), Max(0.6, S(1.1)));
  DEllipse(Dest, R(0, 12).X, R(0, 12).Y, S(32 * Sz), S(5 * Sz), BGRA(20, 40, 60, 60));
  // hull
  Pts[0] := R(-32, 0); Pts[1] := R(34, 0); Pts[2] := R(26, 9); Pts[3] := R(-24, 9);
  DPoly(Dest, Slice(Pts, 4), clHull);
  Pts[0] := R(-31, 1.5); Pts[1] := R(33, 1.5); Pts[2] := R(32, 3); Pts[3] := R(-30, 3);
  DPoly(Dest, Slice(Pts, 4), BGRA(235, 230, 215));
  // mast
  DLine(Dest, R(0, 0).X, R(0, 0).Y, R(0, -62).X, R(0, -62).Y, BGRA(60, 45, 30),
    Max(0.8, S(1.6 * Sz)));
  // main sail and jib
  Pts[0] := R(-2, -60); Pts[1] := R(-2, -4); Pts[2] := R(-30, -4);
  DPoly(Dest, Slice(Pts, 3), clSail);
  Pts[0] := R(-2, -60); Pts[1] := R(-2, -4); Pts[2] := R(-12, -4);
  DPoly(Dest, Slice(Pts, 3), clSailShade);
  Pts[0] := R(2, -56); Pts[1] := R(2, -4); Pts[2] := R(26, -4);
  DPoly(Dest, Slice(Pts, 3), clSail);
  // flag
  Pts[0] := R(0, -62); Pts[1] := R(9, -59 + Sin(FScene.FTime * 6)); Pts[2] := R(0, -56);
  DPoly(Dest, Slice(Pts, 3), BGRA(214, 50, 40));
end;

{ Jumping fish: a silver body along a parabola, nose first, with splash rings
  where it leaves and re-enters the water. }
procedure TPainter.DrawFish(Dest: TBGRABitmap);
var
  I, K: Integer;
  S0, Fx, Fy, Ang, Ca, Sa, Sz, Ring, Rx: Single;
  Pts: array[0..6] of TPointF;
  Q: TPointF;

  function R(DX, DY: Single): TPointF;
  begin
    Result := P(Fx + (DX * Ca - DY * Sa) * Sz, Fy + (DX * Sa + DY * Ca) * Sz);
  end;

  procedure Splash(X, Y, Age: Single);
  begin
    if (Age < 0) or (Age > 1) then Exit;
    Q := P(X, Y);
    DEllipseLine(Dest, Q.X, Q.Y, S(4 + 18 * Age), S(1.5 + 5 * Age),
      WithAlpha(clFoam, Round(200 * (1 - Age))), Max(0.6, S(1.2)));
    DEllipseLine(Dest, Q.X, Q.Y, S(2 + 9 * Age), S(1 + 2.5 * Age),
      WithAlpha(clFoam, Round(160 * (1 - Age))), Max(0.5, S(0.9)));
  end;

begin
  if not RowsHit(ShoreBaseY + 20, SeaBottomY) then Exit;
  for I := 0 to High(FScene.FFish) do
    with FScene.FFish[I] do
    begin
      if T < 0 then Continue;
      Sz := Size;
      S0 := T / Dur;
      Splash(X0, Y0, S0 * 1.6);                         // take-off rings
      Splash(X0 + Dir * Dist, Y0, (S0 - 0.85) * 1.6);   // landing rings
      if S0 > 1 then Continue;
      Fx := X0 + Dir * Dist * S0;
      Fy := Y0 - 4 * Height * S0 * (1 - S0);
      Ang := ArcTan2(-4 * Height * (1 - 2 * S0), Dir * Dist);
      if Dir < 0 then Ang := Ang + Pi;
      Ca := Cos(Ang);
      Sa := Sin(Ang);
      if Dir < 0 then
      begin
        Ca := -Ca;
        Sa := -Sa;
      end;
      Rx := Dir;
      // body (nose towards the direction of travel)
      for K := 0 to 6 do
        Pts[K] := R(Rx * 9 * Cos(K * Pi / 3), 3.2 * Sin(K * Pi / 3));
      DPoly(Dest, Slice(Pts, 6), clFishBelly);
      Pts[0] := R(Rx * 9, 0); Pts[1] := R(Rx * 4, -3.2); Pts[2] := R(-Rx * 5, -3);
      Pts[3] := R(-Rx * 8, -0.5);
      DPoly(Dest, Slice(Pts, 4), clFishBack);
      // tail
      Ring := Sin(FScene.FTime * 25 + I) * 1.5;
      Pts[0] := R(-Rx * 8, 0); Pts[1] := R(-Rx * 14, -4 + Ring); Pts[2] := R(-Rx * 13, 4 + Ring);
      DPoly(Dest, Slice(Pts, 3), clFishBack);
      // eye
      Q := R(Rx * 6, -0.8);
      DEllipse(Dest, Q.X, Q.Y, S(0.9 * Sz), S(0.9 * Sz), BGRA(20, 20, 20));
      // droplets
      if S0 < 0.3 then
        for K := 0 to 3 do
        begin
          Q := P(X0 + Dir * (K - 1.5) * 4, Y0 - 12 * S0 * (K + 1));
          DEllipse(Dest, Q.X, Q.Y, S(1), S(1), WithAlpha(clFoam, 200));
        end;
    end;
end;

procedure TPainter.DrawGlow(Dest: TBGRABitmap);
var
  C: TPointF;
  R, Tm: Single;
  A: Byte;
begin
  Tm := FScene.FTime;
  C := P(CraterX, CraterY - 10);
  R := S(170 * (1 + 0.07 * Sin(Tm * 2.3)));
  if (C.Y + R < 0) or (C.Y - R > FTargetH) then Exit;
  A := Round(80 + 30 * Sin(Tm * 3.1));
  DRadialRect(Dest, Round(C.X - R), Round(C.Y - R), Round(C.X + R), Round(C.Y + R),
    BGRA(255, 150, 50, A), BGRA(255, 110, 20, 0), C, PointF(C.X + R, C.Y));
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
      DPoly(Dest, Pts, BGRA(35, 32, 30, Round(220 * Fade)));
    end;
end;

procedure TPainter.DrawBirds(Dest: TBGRABitmap);
var
  I: Integer;
  Pts: array[0..7] of TPointF;
  Tip, Sz, Dir: Single;
  Q: TPointF;
begin
  for I := 0 to High(FScene.FBirds) do
    with FScene.FBirds[I] do
    begin
      Sz := Size;
      Q := P(X, Y);
      if (Q.Y + S(Sz + 6) < 0) or (Q.Y - S(Sz) > FTargetH) then Continue;
      Tip := -Sz * 0.75 * Sin(Phase);
      Dir := Sign(VX);
      Pts[0] := P(X - Sz, Y + Tip);
      Pts[1] := P(X - Sz * 0.4, Y - Sz * 0.2 + Tip * 0.4);
      Pts[2] := P(X + Dir * Sz * 0.12, Y - Sz * 0.05);
      Pts[3] := P(X + Sz * 0.4, Y - Sz * 0.2 + Tip * 0.4);
      Pts[4] := P(X + Sz, Y + Tip);
      Pts[5] := P(X + Sz * 0.4, Y + Sz * 0.05 + Tip * 0.4);
      Pts[6] := P(X, Y + Sz * 0.28);
      Pts[7] := P(X - Sz * 0.4, Y + Sz * 0.05 + Tip * 0.4);
      DPoly(Dest, Pts, clBird);
    end;
end;

procedure TPainter.RenderBand(Dest: TBGRABitmap; ATop: Integer);
var
  Sc: TVolcanoScene;
  I, Y, W, H, R, MT, MB, LTop, LH: Integer;
  T0: Double;
  A: TPointF;

  procedure Mark(Id: TLayerId);
  var
    T: Double;
  begin
    T := HiResMs;
    LayerMs[Id] := LayerMs[Id] + (T - T0);
    T0 := T;
  end;

  procedure Blit(Spr: TBGRABitmap; const Pos: TPoint; const Svg: string);
  begin
    DBlit(Dest, Pos.X, Pos.Y - ATop, Spr, Svg);
  end;

begin
  Sc := FScene;
  W := Sc.FWidth;
  if Dest <> nil then H := Dest.Height else H := Sc.FHeight;
  T0 := HiResMs;

  if FSvg <> nil then
  begin
    if Sc.LayerOn[lySky] then
      FSvg.Raw(Sc.FSvgBack)
    else if not Sc.TransparentBack then
      FSvg.Rect(0, 0, W, H, '#B4C8DC');
  end;
  if FRaster then
    if Sc.LayerOn[lySky] then
    begin
      for Y := 0 to H - 1 do
        if ATop + Y < Sc.FHeight then
          Move(RowPtr(Sc.FBack, ATop + Y)^, RowPtr(Dest, Y)^, W * SizeOf(TBGRAPixel));
    end
    else if Sc.TransparentBack then
      Dest.FillTransparent
    else
      Dest.Fill(BGRA(180, 200, 220));
  Mark(lySky);

  // most layers draw straight onto the band
  TargetBand(ATop, H);
  if Sc.LayerOn[lyFarClouds] then DrawClouds(Dest, Sc.FFarClouds);
  Mark(lyFarClouds);
  if Sc.LayerOn[lySmoke] then DrawSmoke(Dest);
  Mark(lySmoke);
  if Sc.LayerOn[lyVolcano] then Blit(Sc.FVolcano, Sc.FVolcanoPos, Sc.FSvgVolcano);
  Mark(lyVolcano);
  if Sc.LayerOn[lyLava] then DrawLava(Dest);
  Mark(lyLava);
  if Sc.LayerOn[lyFire] then DrawFire(Dest);
  Mark(lyFire);
  if Sc.LayerOn[lyNearClouds] then DrawClouds(Dest, Sc.FNearClouds);
  Mark(lyNearClouds);

  { jungle: static canopy, then the palms on a work layer with a soft shadow.
    The work layer covers the band plus the rows whose shadows reach into it;
    its top is a multiple of 4 so every band samples the same grid. }
  if Sc.LayerOn[lyJungle] then
  begin
    Blit(Sc.FJungle, Sc.FJunglePos, Sc.FSvgJungle);
    if RowsHit(JungleTopY - 330, BeachTopY + 40) then
    begin
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
      BeginLayer;
      for I := 0 to High(Sc.FPalms) do
        DrawPalm(FLayer, Sc.FPalms[I], False);
      CompositeLayer(Dest, ATop, LayerDepth[lyJungle]);
      TargetBand(ATop, H);
    end;
  end;
  Mark(lyJungle);

  if Sc.LayerOn[lyBeach] then Blit(Sc.FBeach, Sc.FBeachPos, Sc.FSvgBeach);
  Mark(lyBeach);
  if Sc.LayerOn[lySea] then
  begin
    Blit(Sc.FSeaBody, Sc.FSeaPos, Sc.FSvgSea);
    DrawSea(Dest);
  end;
  Mark(lySea);
  if Sc.LayerOn[lyCrabs] then DrawCrabs(Dest);
  Mark(lyCrabs);
  if Sc.LayerOn[lyBoat] then DrawBoat(Dest);
  Mark(lyBoat);
  if Sc.LayerOn[lyFish] then DrawFish(Dest);
  Mark(lyFish);
  if Sc.LayerOn[lyGlow] then DrawGlow(Dest);
  Mark(lyGlow);
  if Sc.LayerOn[lyAsh] then DrawAsh(Dest);
  Mark(lyAsh);
  if Sc.LayerOn[lyEmbers] then DrawEmbers(Dest);
  Mark(lyEmbers);
  if Sc.LayerOn[lyBirds] then DrawBirds(Dest);
  Mark(lyBirds);
  if Sc.FShowCaption and Sc.LayerOn[lyCaption] and (Sc.FCaption <> nil) then
  begin
    A := P(176, 17);
    if FSvg <> nil then
      FSvg.Raw(Format('<g transform="translate(%s,%s)">', [FSvg.N(Round(A.X)), FSvg.N(Round(A.Y))]) +
        LineEnding + Sc.FSvgCaption + '</g>');
    if FRaster then BlendBitmap(Dest, Round(A.X), Round(A.Y), Sc.FCaption);
  end;
  Mark(lyCaption);
  if Dest <> nil then Dest.InvalidateBitmap;
end;

{ ====================================================================== }
{ TVolcanoScene                                                          }
{ ====================================================================== }

constructor TVolcanoScene.Create;
const
  PalmX: array[0..15] of Single = (-420, -300, -190, -80, 20, 105, 190, 270, 360, 450,
    540, 625, 720, 830, 950, 1080);
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
  RandSeed := 20261015;  // same island every run

  SetLength(FFarClouds, 6);
  for I := 0 to High(FFarClouds) do
    AddCloud(FFarClouds, I, RandRange(-80, DesignW + 80), RandRange(60, 300),
      RandRange(150, 240), RandRange(34, 52), -RandRange(6, 11));
  SetLength(FNearClouds, 4);
  for I := 0 to High(FNearClouds) do
    AddCloud(FNearClouds, I, -60 + I * 260 + RandRange(-40, 40), RandRange(170, 430),
      RandRange(320, 440), RandRange(95, 125), RandRange(12, 19));

  SetLength(FPalms, Length(PalmX));
  for I := 0 to High(PalmX) do
    SetupPalm(FPalms[I], PalmX[I] + RandRange(-20, 20), BeachTop(PalmX[I]) + RandRange(-4, 6),
      RandRange(120, 230), RandRange(-0.16, 0.16), RandRange(0.85, 1.2));

  SetLength(FFlows, 7);
  for I := 0 to High(FFlows) do
    FFlows[I].Seed := RandRange(0, 2 * Pi);
  FFlows[0].K := -0.78; FFlows[0].EndY := 905; FFlows[0].W := 12;
  FFlows[1].K := -0.50; FFlows[1].EndY := 820; FFlows[1].W := 9;
  FFlows[2].K := -0.22; FFlows[2].EndY := 940; FFlows[2].W := 11;
  FFlows[3].K := 0.06;  FFlows[3].EndY := 880; FFlows[3].W := 10;
  FFlows[4].K := 0.32;  FFlows[4].EndY := 960; FFlows[4].W := 12;
  FFlows[5].K := 0.58;  FFlows[5].EndY := 840; FFlows[5].W := 9;
  FFlows[6].K := 0.84;  FFlows[6].EndY := 930; FFlows[6].W := 11;

  FBoat.X := 520;
  FBoat.Y := 1215;
  FBoat.Speed := 9;
  FBoat.Size := 1.7;
  FBoat.Phase := 0.7;

  Randomize;
  SetLength(FPuffs, 260);
  for I := 0 to High(FPuffs) do
  begin
    if I < 105 then FPuffs[I].Depth := 0
    else if I < 190 then FPuffs[I].Depth := 1
    else FPuffs[I].Depth := 2;
    SpawnPuff(FPuffs[I], True);
  end;
  SetLength(FBlobs, 90);
  for I := 0 to High(FBlobs) do
  begin
    FBlobs[I].Yellow := I >= 52;
    SpawnBlob(FBlobs[I], True);
  end;
  SetLength(FEmbers, 50);
  for I := 0 to High(FEmbers) do
    SpawnEmber(FEmbers[I], True);
  SetLength(FAsh, 70);
  for I := 0 to High(FAsh) do
    SpawnAsh(FAsh[I], True);
  SetLength(FBirds, 12);
  for I := 0 to High(FBirds) do
    SpawnBird(FBirds[I], True);
  SetLength(FCrabs, 6);
  for I := 0 to High(FCrabs) do
    with FCrabs[I] do
    begin
      X := RandRange(20, DesignW - 20);
      Y := RandRange(BeachTopY + 18, ShoreBaseY - 16);
      Size := RandRange(0.85, 1.25);
      Walking := Random < 0.6;
      VX := IfThen(Random < 0.5, -1, 1) * RandRange(18, 40);
      Timer := RandRange(0.5, 3);
      LegPhase := RandRange(0, 6);
    end;
  SetLength(FFish, 3);
  for I := 0 to High(FFish) do
    SpawnFish(FFish[I], True);
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
  for I := 0 to High(FNearClouds) do
    FreeAndNil(FNearClouds[I].Sprite);
  FreeAndNil(FBack);
  FreeAndNil(FVolcano);
  FreeAndNil(FJungle);
  FreeAndNil(FBeach);
  FreeAndNil(FSeaBody);
  FreeAndNil(FCaption);
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

  // every round sprite this size can need: smoke up to r = 120, lava up to 30
  N := 0;
  SetLength(FSpriteJobs, 0);
  for K := 0 to SpriteKinds - 1 do
  begin
    if K <= 2 then MaxR := Ceil(S(120)) else MaxR := Ceil(S(30));
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

{ Cuts one round sprite; safe on any thread (each job owns its slot).
  Smoke: a radial gradient lit from the upper left with a darker rim, so the
  stacked puffs read as billows. Lava: hot centre, darker edge. }
procedure TVolcanoScene.SpriteJob(AIndex, AWorker: Integer);
var
  K, R, Size: Integer;
  C: Single;
  B: TBGRABitmap;
  G: TBGRAGradientScanner;
begin
  K := FSpriteJobs[AIndex].X;
  R := FSpriteJobs[AIndex].Y;
  Size := 2 * R + 4;
  C := Size / 2 - 0.5;
  B := TBGRABitmap.Create(Size, Size);
  G := TBGRAGradientScanner.Create(SpriteFill[K], SpriteEdge[K], gtRadial,
    PointF(C - R * 0.35, C - R * 0.4), PointF(C - R * 0.35 + R * 1.45, C - R * 0.4), True);
  try
    B.FillEllipseAntialias(C, C, R, R, G);
  finally
    G.Free;
  end;
  if K = 5 then
    B.EllipseAntialias(C, C, R * 0.5, R * 0.5, BGRA(240, 154, 30, 160), Max(0.6, S(1)));
  FSprites[K][R] := B;
end;

{ Copies design rows Y0..Y1 of the cutter layer (full window width). }
function TVolcanoScene.CropLayer(Y0, Y1: Single; out Pos: TPoint): TBGRABitmap;
var
  A, B: Integer;
begin
  A := EnsureRange(Floor(P(0, Y0).Y), 0, FHeight - 1);
  B := EnsureRange(Ceil(P(0, Y1).Y), A + 1, FHeight);
  Pos := Point(0, A);
  Result := TBGRABitmap(FCutter.FLayer.GetPart(Rect(0, A, FWidth, B)));
end;

{ ---------- static cut ---------- }

procedure TVolcanoScene.CutSky;
var
  Px: PBGRAPixel;
  I: Integer;
  Noise: Single;
  Sun: TPointF;
  R: Single;
begin
  FBack := TBGRABitmap.Create(FWidth, FHeight);
  FBack.GradientFill(0, 0, FWidth, FHeight, Hex('#6FA3D2'), Hex('#EBDCC6'),
    gtLinear, PointF(0, P(0, 40).Y), PointF(0, P(0, 960).Y), dmSet);
  // warm haze low on the horizon and a soft sun glow on the left
  Sun := P(110, 260);
  R := S(420);
  FBack.GradientFill(Round(Sun.X - R), Round(Sun.Y - R), Round(Sun.X + R), Round(Sun.Y + R),
    BGRA(255, 246, 220, 120), BGRA(255, 246, 220, 0), gtRadial, Sun, PointF(Sun.X + R, Sun.Y),
    dmDrawWithTransparency);
  Px := FBack.Data;
  for I := 0 to FBack.NbPixels - 1 do
  begin
    Noise := RandRange(-3, 3);
    Px^.red := EnsureRange(Round(Px^.red + Noise), 0, 255);
    Px^.green := EnsureRange(Round(Px^.green + Noise), 0, 255);
    Px^.blue := EnsureRange(Round(Px^.blue + Noise), 0, 255);
    Inc(Px);
  end;
  FBack.InvalidateBitmap;
  if FStaticSvg <> nil then
  begin
    I := FStaticSvg.Mark;
    FStaticSvg.Rect(0, 0, FWidth, FHeight, FStaticSvg.Gradient(MakeGrad(Hex('#6FA3D2'),
      Hex('#EBDCC6'), False, PointF(0, P(0, 40).Y), PointF(0, P(0, 960).Y))));
    FStaticSvg.Rect(Sun.X - R, Sun.Y - R, 2 * R, 2 * R, FStaticSvg.Gradient(MakeGrad(
      BGRA(255, 246, 220, 120), BGRA(255, 246, 220, 0), True, Sun, PointF(Sun.X + R, Sun.Y))));
    FSvgBack := FStaticSvg.Take(I);
  end;
end;

{ The cone: a lit-to-shaded gradient across, darker ash near the top, gullies
  running down the flanks with a light edge on the sunny side, speckled rock,
  old dark lava, a glowing crater lip and green creeping up the foot. }
procedure TVolcanoScene.CutVolcano;
const
  N = 80;
var
  Cut: TPainter;
  Pts, Line: array of TPointF;
  I, J, K, G: Integer;
  X, Y, Hw, Kk, Y0, Y1, Wig: Single;
  Q: TPointF;
  Grad: TBGRAGradientScanner;
  Shape: array of TPointF;
begin
  Cut := FCutter;
  Cut.BeginLayer;
  // distant green hills left and right of the cone (seen on wide windows)
  for G := 0 to 3 do
  begin
    case G of
      0: begin X := -520; Hw := 420; Y0 := 760; end;
      1: begin X := 1260; Hw := 460; Y0 := 740; end;
      2: begin X := -1250; Hw := 520; Y0 := 800; end;
    else
      begin X := 1980; Hw := 520; Y0 := 790; end;
    end;
    SetLength(Pts, 42);
    for I := 0 to 40 do
    begin
      Kk := -1 + I / 20;
      Pts[I] := PointF(X + Kk * Hw, Y0 + (ConeBaseY + 40 - Y0) * Power(Abs(Kk), 1.6) +
        8 * Sin(I * 1.3 + G));
    end;
    Pts[41] := PointF(X, ConeBaseY + 60);
    SetLength(Shape, 42);
    for I := 0 to 41 do
      Shape[I] := P(Pts[I].X, Pts[I].Y);
    Cut.DPolyG(Cut.FLayer, Shape, MakeGrad(BGRA(96, 128, 92), BGRA(52, 82, 46), False, P(0, Y0), P(0, ConeBaseY)));
  end;
  // silhouette, with a ragged ridge
  SetLength(Pts, 2 * (N + 1) + 7);
  K := 0;
  for I := 0 to N do
  begin
    Y := ConeBaseY + 60 - I * (ConeBaseY + 60 - RimY) / N;
    Pts[K] := PointF(CraterX - ConeHalfWidth(Y) - 5 * Sin(Y * 0.05) - 3 * Sin(Y * 0.17), Y);
    Inc(K);
  end;
  Pts[K] := PointF(CraterX - 30, RimY - 9); Inc(K);
  Pts[K] := PointF(CraterX - 16, RimY - 3); Inc(K);
  Pts[K] := PointF(CraterX - 4, RimY - 12); Inc(K);
  Pts[K] := PointF(CraterX + 9, RimY - 5); Inc(K);
  Pts[K] := PointF(CraterX + 22, RimY - 11); Inc(K);
  Pts[K] := PointF(CraterX + 34, RimY - 4); Inc(K);
  Pts[K] := PointF(CraterX + 44, RimY - 1); Inc(K);
  for I := 0 to N do
  begin
    Y := RimY + I * (ConeBaseY + 60 - RimY) / N;
    Pts[K] := PointF(CraterX + ConeHalfWidth(Y) + 4 * Sin(Y * 0.06 + 1) + 3 * Sin(Y * 0.19), Y);
    Inc(K);
  end;
  SetLength(Shape, Length(Pts));
  for I := 0 to High(Pts) do
    Shape[I] := P(Pts[I].X, Pts[I].Y);
  // lit side on the left (sun), shaded side on the right
  Cut.DPolyG(Cut.FLayer, Shape, MakeGrad(Hex('#8A7663'), Hex('#26201D'), False, P(CraterX - 330, 0), P(CraterX + 300, 0)));
  // ash-darkened summit
  Cut.DPolyG(Cut.FLayer, Shape, MakeGrad(BGRA(28, 24, 22, 190), BGRA(28, 24, 22, 0), False, P(0, RimY), P(0, RimY + 300)));

  // gullies: dark grooves with a lit lip on the sunny side
  SetLength(Line, 30);
  for G := 1 to 54 do
  begin
    Kk := RandRange(-0.97, 0.97);
    Y0 := RimY + RandRange(8, 140);
    Y1 := Min(ConeBaseY + 20, Y0 + RandRange(140, 470));
    Wig := RandRange(0, 6);
    for J := 0 to 29 do
    begin
      Y := Y0 + (Y1 - Y0) * J / 29;
      Hw := ConeHalfWidth(Y);
      X := CraterX + Kk * Hw * 0.98 + Sin(J * 0.5 + Wig) * 4;
      Line[J] := P(X, Y);
    end;
    Cut.DPolyLine(Cut.FLayer, Line, BGRA(22, 18, 16, 150), Max(0.8, S(RandRange(1.6, 3.2))));
    for J := 0 to 29 do
      Line[J].X := Line[J].X - S(2.2);
    Cut.DPolyLine(Cut.FLayer, Line, BGRA(160, 140, 118, 60), Max(0.6, S(1)));
  end;
  // rock speckles
  for I := 1 to 1100 do
  begin
    Y := RandRange(RimY + 10, ConeBaseY + 40);
    Hw := ConeHalfWidth(Y);
    X := CraterX + RandRange(-0.97, 0.97) * Hw;
    Q := P(X, Y);
    if Random < 0.5 then
      Cut.DEllipse(Cut.FLayer, Q.X, Q.Y, S(RandRange(0.6, 1.8)), S(RandRange(0.5, 1.2)),
        BGRA(20, 17, 15, Random(90) + 40))
    else
      Cut.DEllipse(Cut.FLayer, Q.X, Q.Y, S(RandRange(0.5, 1.4)), S(RandRange(0.4, 1)),
        BGRA(170, 150, 130, Random(60) + 25));
  end;
  // old, cooled lava tongues
  for G := 0 to 5 do
  begin
    Kk := -0.9 + G * 0.36 + RandRange(-0.08, 0.08);
    Y1 := RandRange(780, 980);
    for J := 0 to 29 do
    begin
      Y := RimY + 6 + (Y1 - RimY - 6) * J / 29;
      X := CraterX + Kk * ConeHalfWidth(Y) * 0.95 + Sin(J * 0.4 + G) * 6;
      Line[J] := P(X, Y);
    end;
    Cut.DPolyLine(Cut.FLayer, Line, BGRA(59, 31, 23, 200), Max(1, S(RandRange(6, 11))));
    Cut.DPolyLine(Cut.FLayer, Line, BGRA(90, 46, 30, 120), Max(0.6, S(2)));
  end;
  // crater: dark mouth and a glowing lip
  Q := P(CraterX, RimY - 2);
  Cut.DEllipse(Cut.FLayer, Q.X, Q.Y, S(42), S(7), BGRA(30, 14, 10));
  Cut.DEllipseLine(Cut.FLayer, Q.X, Q.Y, S(42), S(7), BGRA(255, 140, 50, 200), Max(0.8, S(2.4)));
  // green creeping up the foot of the cone
  K := 0;
  SetLength(Pts, 2 * N + 4);
  for I := 0 to N do
  begin
    X := CraterX - 760 + I * 1520 / N;
    Pts[K] := PointF(X, 862 + 14 * Sin(X * 0.05) + 9 * Sin(X * 0.13));
    Inc(K);
  end;
  Pts[K] := PointF(CraterX + 760, ConeBaseY + 70); Inc(K);
  Pts[K] := PointF(CraterX - 760, ConeBaseY + 70); Inc(K);
  SetLength(Pts, K);
  SetLength(Shape, K);
  for I := 0 to K - 1 do
    Shape[I] := P(Pts[I].X, Pts[I].Y);
  Cut.DPolyG(Cut.FLayer, Shape, MakeGrad(BGRA(70, 105, 48, 0), BGRA(47, 82, 38, 235), False, P(0, 850), P(0, 940)));
  if FStaticSvg <> nil then FSvgVolcano := FStaticSvg.Take(Cut.FSvgMark);
  FVolcano := CropLayer(Min(RimY - 20, 700), ConeBaseY + 72, FVolcanoPos);
end;

{ The jungle canopy: thousands of overlapping bush blobs, darker at the back and
  lighter at the front, with a ragged top, plus a few distant palm silhouettes. }
procedure TVolcanoScene.CutJungle;
var
  Cut: TPainter;
  X, Y, T0, B0, R, F: Single;
  I: Integer;
  Pm: TPalm;
  Q: TPointF;
begin
  Cut := FCutter;
  Cut.BeginLayer;
  // distant palms above the canopy line
  X := FVisL - 60;
  while X < FVisR + 60 do
  begin
    SetupPalm(Pm, X + RandRange(-20, 20), JungleTop(X) + 20, RandRange(70, 120),
      RandRange(-0.15, 0.15), RandRange(0.55, 0.75));
    Cut.DrawPalm(Cut.FLayer, Pm, True);
    X := X + RandRange(55, 110);
  end;
  X := FVisL - 40;
  while X < FVisR + 40 do
  begin
    T0 := JungleTop(X);
    B0 := BeachTop(X) + 6;
    for I := 0 to 6 do
    begin
      F := I / 6;                          // 0 back (top) .. 1 front (bottom)
      Y := T0 + 12 + (B0 - T0 - 16) * F + RandRange(-6, 6);
      R := RandRange(9, 17) * (1 - 0.25 * F);
      Q := P(X + RandRange(-5, 5), Y);
      Cut.DEllipse(Cut.FLayer, Q.X, Q.Y, S(R), S(R * 0.85),
        BGRA(Round(30 + 25 * F), Round(58 + 50 * F), Round(28 + 18 * F)));
      // sun-lit upper left of each bush
      Cut.DEllipse(Cut.FLayer, Q.X - S(R * 0.3), Q.Y - S(R * 0.35), S(R * 0.55), S(R * 0.45),
        BGRA(Round(70 + 40 * F), Round(110 + 45 * F), Round(48 + 15 * F), 150));
    end;
    X := X + RandRange(8, 13);
  end;
  if FStaticSvg <> nil then FSvgJungle := FStaticSvg.Take(Cut.FSvgMark);
  FJungle := CropLayer(JungleTopY - 160, BeachTopY + 20, FJunglePos);
end;

{ The beach: dry sand fading into wet, darker sand at the water, rocks with a lit
  top and a shadow, and little shells. }
procedure TVolcanoScene.CutBeach;
const
  StepX = 6;
var
  Cut: TPainter;
  Shape: array of TPointF;
  I, N, K: Integer;
  X, Y, R: Single;
  Grad: TBGRAGradientScanner;
  Q: TPointF;
begin
  Cut := FCutter;
  Cut.BeginLayer;
  N := Ceil((FVisR - FVisL + 120) / StepX) + 1;
  SetLength(Shape, 2 * N);
  for I := 0 to N - 1 do
  begin
    X := FVisL - 60 + I * StepX;
    Shape[I] := P(X, BeachTop(X));
    Shape[2 * N - 1 - I] := P(X, ShoreY(X) + 14);
  end;
  Cut.DPolyG(Cut.FLayer, Shape, MakeGrad(Hex('#EAD6A6'), Hex('#C9AD7C'), False, P(0, BeachTopY), P(0, ShoreBaseY + 10)));
  // wet sand band that the swash keeps wet
  for I := 0 to N - 1 do
  begin
    X := FVisL - 60 + I * StepX;
    Shape[I] := P(X, ShoreY(X) - 22);
    Shape[2 * N - 1 - I] := P(X, ShoreY(X) + 14);
  end;
  Cut.DPolyG(Cut.FLayer, Shape, MakeGrad(BGRA(150, 120, 80, 0), BGRA(150, 120, 80, 150), False, P(0, ShoreBaseY - 24), P(0, ShoreBaseY)));
  // sand grain
  for K := 1 to Round((FVisR - FVisL) * 1.6) do
  begin
    X := RandRange(FVisL, FVisR);
    Y := RandRange(BeachTop(X) + 2, ShoreY(X) - 4);
    Q := P(X, Y);
    Cut.DEllipse(Cut.FLayer, Q.X, Q.Y, S(0.7), S(0.7), BGRA(120, 95, 60, Random(70) + 20));
  end;
  // rocks
  for K := 1 to Round((FVisR - FVisL) / 26) do
  begin
    X := RandRange(FVisL, FVisR);
    Y := RandRange(BeachTop(X) + 4, ShoreY(X) - 2);
    R := RandRange(3, 9);
    Q := P(X, Y);
    Cut.DEllipse(Cut.FLayer, Q.X + S(1.5), Q.Y + S(R * 0.4), S(R * 1.1), S(R * 0.45),
      BGRA(70, 55, 35, 90));
    Cut.DEllipse(Cut.FLayer, Q.X, Q.Y, S(R), S(R * 0.7), Hex('#6F6B64'));
    Cut.DEllipse(Cut.FLayer, Q.X - S(R * 0.3), Q.Y - S(R * 0.25), S(R * 0.5), S(R * 0.3),
      BGRA(175, 170, 160, 170));
  end;
  // shells
  for K := 1 to Round((FVisR - FVisL) / 12) do
  begin
    X := RandRange(FVisL, FVisR);
    Y := RandRange(BeachTop(X) + 6, ShoreY(X) - 6);
    Q := P(X, Y);
    Cut.DEllipse(Cut.FLayer, Q.X, Q.Y, S(1.4), S(1), BGRA(250, 240, 230, 220));
  end;
  if FStaticSvg <> nil then FSvgBeach := FStaticSvg.Take(Cut.FSvgMark);
  FBeach := CropLayer(BeachTopY - 12, ShoreBaseY + 30, FBeachPos);
end;

{ The sea body: turquoise over the sand, deepening to dark blue at the front,
  with faint ripple streaks. The waves are drawn every frame on top. }
procedure TVolcanoScene.CutSea;
const
  StepX = 6;
var
  Cut: TPainter;
  Shape, Line: array of TPointF;
  I, N, K: Integer;
  X, Y: Single;
  Grad: TBGRAGradientScanner;
begin
  Cut := FCutter;
  Cut.BeginLayer;
  N := Ceil((FVisR - FVisL + 120) / StepX) + 1;
  SetLength(Shape, 2 * N);
  for I := 0 to N - 1 do
  begin
    X := FVisL - 60 + I * StepX;
    Shape[I] := P(X, ShoreY(X));
    Shape[2 * N - 1 - I] := P(X, SeaBottomY + 40);
  end;
  Cut.DPolyG(Cut.FLayer, Shape, MakeGrad(Hex('#5DC2BE'), Hex('#134F78'), False, P(0, ShoreBaseY), P(0, SeaBottomY)));
  SetLength(Line, 2);
  for K := 1 to Round((FVisR - FVisL) / 5) do
  begin
    X := RandRange(FVisL, FVisR);
    Y := RandRange(ShoreY(X) + 14, SeaBottomY);
    Line[0] := P(X, Y);
    Line[1] := P(X + RandRange(10, 40), Y);
    Cut.DLine(Cut.FLayer, Line[0].X, Line[0].Y, Line[1].X, Line[1].Y,
      BGRA(220, 245, 250, Random(40) + 15), Max(0.6, S(0.9)));
  end;
  if FStaticSvg <> nil then FSvgSea := FStaticSvg.Take(Cut.FSvgMark);
  FSeaBody := CropLayer(ShoreBaseY - 20, SeaBottomY + 12, FSeaPos);
end;

{ A realistic cloud sprite: every puff is shaded top to bottom (sunlit white to
  blue-grey), towers behind, base row in front; then a soft highlight on the
  sunny side, a blur for soft edges and a flat, fading base. Far clouds are
  paler, softer and partly transparent. }
procedure TVolcanoScene.CutCloud(var C: TCloud; Far: Boolean);
var
  I, X, Y, W, H, Base, Fade: Integer;
  R, K: Single;
  Q: TPointF;
  Cut: TPainter;
  Spr: TBGRABitmap;
  Shade, Lit: TBGRAPixel;
  Px: PBGRAPixel;
  SvgMark: Integer;
begin
  Cut := FCutter;
  W := Min(FWidth, Ceil(S(C.MaxX - C.MinX + 16)));
  H := Min(FHeight, Ceil(S(C.MaxY - C.MinY + 16)));
  if (W < 4) or (H < 4) then Exit;
  Spr := TBGRABitmap.Create(W, H);
  Cut.FOrgX := S(-C.MinX + 8);
  Cut.FOrgY := S(-C.MinY + 8);
  SvgMark := 0;
  if FStaticSvg <> nil then SvgMark := FStaticSvg.Mark;
  if Far then
  begin
    Shade := BGRA(184, 196, 212);
    Lit := BGRA(250, 251, 253);
  end
  else
  begin
    Shade := BGRA(150, 164, 184);
    Lit := BGRA(255, 255, 255);
  end;
  I := 0;
  while I + 2 <= High(C.Puffs) do
  begin
    R := C.Puffs[I + 2];
    Q := Cut.P(C.Puffs[I], C.Puffs[I + 1]);
    Cut.DEllipseG(Spr, Q.X, Q.Y, S(R), S(R * 0.9), MakeGrad(Lit, Shade, False,
      PointF(Q.X, Q.Y - S(R)), PointF(Q.X, Q.Y + S(R * 0.75))));
    Inc(I, 3);
  end;
  // sunlit rims on the upper left of the bigger puffs
  I := 0;
  while I + 2 <= High(C.Puffs) do
  begin
    R := C.Puffs[I + 2];
    if R > 14 then
    begin
      Q := Cut.P(C.Puffs[I] - R * 0.3, C.Puffs[I + 1] - R * 0.42);
      Cut.DEllipse(Spr, Q.X, Q.Y, S(R * 0.5), S(R * 0.32), BGRA(255, 255, 255, 120));
    end;
    Inc(I, 3);
  end;
  BGRAReplace(Spr, Spr.FilterBlurRadial(Max(1, S(IfThen(Far, 3.5, 2.4))), rbNormal));
  // flat base: fade the alpha out under the base line
  Base := Round(H - S(16) + S(4));
  Fade := Max(2, Round(S(10)));
  if FStaticSvg <> nil then
    C.Svg := Format('<g mask="url(#%s)"%s><g filter="url(#%s)">',
      [FStaticSvg.FadeMask(-4, -4, W + 8, H + 8, Base - Fade, Base),
      IfThen(Far, ' opacity="0.78"', ''), FStaticSvg.Blur(Max(1, S(IfThen(Far, 3.5, 2.4))) * 0.5)]) +
      LineEnding + FStaticSvg.Take(SvgMark) + '</g></g>';
  for Y := Max(0, Base - Fade) to H - 1 do
  begin
    K := EnsureRange(1 - (Y - (Base - Fade)) / Fade, 0, 1);
    Px := Spr.ScanLine[Y];
    for X := 0 to W - 1 do
    begin
      Px^.alpha := Round(Px^.alpha * K);
      Inc(Px);
    end;
  end;
  Spr.InvalidateBitmap;
  if Far then Spr.ApplyGlobalOpacity(200);
  Spr.LoadFromBitmapIfNeeded;
  C.Sprite := Spr;
  Cut.FOrgX := FOffX;
  Cut.FOrgY := FOffY;
end;

procedure TVolcanoScene.CutCaption;
var
  I: Integer;
begin
  FCaption := TBGRABitmap.Create(Max(1, Round(S(392))), Max(1, Round(S(90))));
  FCaption.FillRoundRectAntialias(S(3), S(6), S(383), S(80), S(14), S(14), BGRA(0, 0, 0, 40));
  FCaption.FillRoundRectAntialias(S(1), S(1), S(381), S(75), S(14), S(14), BGRA(255, 255, 255, 220));
  FCaption.RoundRectAntialias(S(1), S(1), S(381), S(75), S(14), S(14), BGRA(40, 60, 80), Max(1, S(1.5)));
  FCaption.FontName := 'Segoe UI';
  FCaption.FontQuality := fqFineAntialiasing;
  FCaption.FontStyle := [fsBold];
  FCaption.FontHeight := Max(8, Round(S(30)));
  FCaption.TextOut(S(191), S(9), 'VOLCANO ISLAND 02', BGRA(30, 45, 60), taCenter);
  FCaption.FontStyle := [];
  FCaption.FontHeight := Max(7, Round(S(15)));
  FCaption.TextOut(S(191), S(47), 'Space pause  V vsync  F11 full  S save  I info',
    clLavaEdge, taCenter);
  FCaption.LoadFromBitmapIfNeeded;
  FCaption.InvalidateBitmap;
  if FStaticSvg <> nil then
  begin
    I := FStaticSvg.Mark;
    FStaticSvg.RoundRect(S(3), S(6), S(383), S(80), S(14), S(14), BGRA(0, 0, 0, 40));
    FStaticSvg.RoundRect(S(1), S(1), S(381), S(75), S(14), S(14), BGRA(255, 255, 255, 220));
    FStaticSvg.RoundRect(S(1), S(1), S(381), S(75), S(14), S(14), BGRA(40, 60, 80), Max(1, S(1.5)));
    FStaticSvg.Text(S(191), S(9), 'VOLCANO ISLAND 02', 'Segoe UI', Max(8, Round(S(30))), True,
      BGRA(30, 45, 60), True);
    FStaticSvg.Text(S(191), S(47), 'Space pause  V vsync  F11 full  S save  I info', 'Segoe UI',
      Max(7, Round(S(15))), False, clLavaEdge, True);
    FSvgCaption := FStaticSvg.Take(I);
  end;
end;

procedure TVolcanoScene.RenderStatic;
var
  I: Integer;
begin
  RandSeed := 20261015;
  CutSky;
  CutVolcano;
  CutJungle;
  CutBeach;
  CutSea;
  for I := 0 to High(FFarClouds) do
    CutCloud(FFarClouds[I], True);
  for I := 0 to High(FNearClouds) do
    CutCloud(FNearClouds[I], False);
  CutCaption;
  // settle the LCL/BGRA sync flags now, so threads only ever read these bitmaps
  FBack.LoadFromBitmapIfNeeded;
end;

{ ---------- setup ---------- }

{ A cumulus cloud: a long row of base puffs that taper to the ends, a mound of
  towering puffs over the middle and a flat base (cut in CutCloud). Puffs are
  stored back to front: towers first, base row last. }
procedure TVolcanoScene.AddCloud(var List: array of TCloud; Index: Integer;
  CX, CY, W, H, Speed: Single);
var
  C: TCloud;
  I, NB, NT, K: Integer;
  X, Y, R, U: Single;
begin
  NB := 11 + Random(7);
  NT := 5 + Random(5);
  SetLength(C.Puffs, 3 * (NB + NT));
  K := 0;
  for I := 0 to NT - 1 do
  begin
    U := (Random + Random + Random) / 3 - 0.5;   // bunched to the middle
    C.Puffs[K] := CX + U * W * 0.75;
    C.Puffs[K + 1] := CY - H * RandRange(0.2, 0.55) * (1 - Abs(U) * 1.2);
    C.Puffs[K + 2] := H * RandRange(0.28, 0.5) * (1 - Abs(U));
    Inc(K, 3);
  end;
  for I := 0 to NB - 1 do
  begin
    U := (I + 0.5) / NB - 0.5;
    C.Puffs[K] := CX + U * W + RandRange(-0.03, 0.03) * W;
    C.Puffs[K + 1] := CY + RandRange(-0.08, 0.04) * H;
    C.Puffs[K + 2] := H * RandRange(0.2, 0.36) * (1 - 0.9 * Abs(U));
    Inc(K, 3);
  end;
  C.MinX := 1e9; C.MaxX := -1e9; C.MinY := 1e9; C.MaxY := -1e9;
  I := 0;
  while I + 2 <= High(C.Puffs) do
  begin
    X := C.Puffs[I]; Y := C.Puffs[I + 1]; R := C.Puffs[I + 2];
    C.MinX := Min(C.MinX, X - R); C.MaxX := Max(C.MaxX, X + R);
    C.MinY := Min(C.MinY, Y - R); C.MaxY := Max(C.MaxY, Y + R);
    Inc(I, 3);
  end;
  C.MaxY := Min(C.MaxY, CY + H * 0.2);   // flat base
  C.OX := 0;
  C.OY := 0;
  C.Speed := Speed;
  C.Phase := RandRange(0, 2 * Pi);
  C.Sprite := nil;
  List[Index] := C;
end;

procedure TVolcanoScene.SetupPalm(var Pm: TPalm; X, BaseY, H, Lean, Sc: Single);
const
  Angles: array[0..9] of Single = (-178, -155, -130, -105, -80, -55, -30, -5, 160, 20);
var
  I: Integer;
begin
  Pm.X := X;
  Pm.BaseY := BaseY;
  Pm.H := H;
  Pm.Lean := Lean;
  Pm.Sc := Sc;
  Pm.Phase := RandRange(0, 2 * Pi);
  for I := 0 to 9 do
  begin
    Pm.LeafAng[I] := Angles[I] + RandRange(-8, 8);
    Pm.LeafLen[I] := 60 * RandRange(0.8, 1.15);
  end;
end;

procedure TVolcanoScene.SpawnPuff(var Pf: TPuff; Initial: Boolean);
begin
  if Initial then Pf.U := Random else Pf.U := 0;
  Pf.Speed := 1 / RandRange(20, 30);
  Pf.Lat := Random + Random - 1;  // bunched toward the middle of the column
  Pf.RMul := RandRange(0.6, 1.2);
  Pf.Wob := RandRange(0, 2 * Pi);
end;

procedure TVolcanoScene.SpawnBlob(var B: TBlob; Initial: Boolean);
begin
  if Initial then B.U := Random else B.U := 0;
  B.Speed := 1 / RandRange(1.1, 2.0);
  B.Lat := RandRange(-1, 1);
  if B.Yellow then B.RBase := RandRange(7, 14) else B.RBase := RandRange(13, 23);
end;

procedure TVolcanoScene.SpawnEmber(var E: TParticle; Initial: Boolean);
begin
  E.X := CraterX + RandRange(-30, 30);
  E.Y := CraterY - RandRange(0, 40);
  E.VX := RandRange(-14, 24);
  E.VY := -RandRange(40, 95);
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
  A.X := CraterX + RandRange(-24, 24);
  A.Y := CraterY - RandRange(10, 90);
  A.VX := Dir * RandRange(30, 130);
  A.VY := -RandRange(50, 160);
  A.MaxLife := RandRange(3, 6);
  A.Life := A.MaxLife;
  A.Size := RandRange(1.5, 4.5);
  A.Phase := RandRange(0, 2 * Pi);
  if Initial then A.Life := RandRange(0, A.MaxLife);
end;

procedure TVolcanoScene.SpawnBird(var B: TBird; Initial: Boolean);
var
  Dir: Single;
begin
  Dir := IfThen(Random < 0.7, 1, -1);
  B.Size := RandRange(8, 15);
  B.VX := Dir * RandRange(35, 70);
  B.VY := -RandRange(2, 12);
  B.Phase := RandRange(0, 2 * Pi);
  if Initial then
    B.X := RandRange(40, DesignW - 40)
  else if Dir > 0 then
    B.X := FVisL - RandRange(20, 80)
  else
    B.X := FVisR + RandRange(20, 80);
  B.Y := RandRange(120, 640);
end;

procedure TVolcanoScene.SpawnFish(var F: TFish; Initial: Boolean);
begin
  F.T := -1;
  F.Wait := RandRange(0.5, 4) + IfThen(Initial, RandRange(0, 2), 0);
  F.Dir := IfThen(Random < 0.5, -1, 1);
  F.Dist := RandRange(40, 75);
  F.Height := RandRange(22, 45);
  F.Dur := RandRange(0.9, 1.4);
  F.Size := RandRange(0.9, 1.3);
  F.X0 := RandRange(FVisL + 60, FVisR - 60);
  F.Y0 := RandRange(ShoreBaseY + 60, SeaBottomY - 40);
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
      if U >= 1 then SpawnPuff(FPuffs[I], False);
    end;
  for I := 0 to High(FBlobs) do
    with FBlobs[I] do
    begin
      U := U + DT * Speed;
      if U >= 1 then SpawnBlob(FBlobs[I], False);
    end;
  // far clouds drift right to left, near clouds left to right
  for I := 0 to High(FFarClouds) do
    with FFarClouds[I] do
    begin
      OX := OX + Speed * DT;
      OY := Sin(FTime * 0.4 + Phase) * 2;
      if MaxX + OX < FVisL - 20 then
        OX := FVisR + 20 - MinX;
    end;
  for I := 0 to High(FNearClouds) do
    with FNearClouds[I] do
    begin
      OX := OX + Speed * DT;
      OY := Sin(FTime * 0.35 + Phase) * 4;
      if MinX + OX > FVisR + 20 then
        OX := FVisL - 20 - MaxX;
    end;
  for I := 0 to High(FEmbers) do
    with FEmbers[I] do
    begin
      Life := Life - DT;
      X := X + (VX + Sin(FTime * 1.5 + Phase) * 10) * DT;
      Y := Y + VY * DT;
      if (Life <= 0) or (Y < 30) then SpawnEmber(FEmbers[I], False);
    end;
  for I := 0 to High(FAsh) do
    with FAsh[I] do
    begin
      Life := Life - DT;
      VY := VY + 45 * DT;  // gravity
      X := X + VX * DT;
      Y := Y + VY * DT;
      Phase := Phase + DT * 4;
      if Life <= 0 then SpawnAsh(FAsh[I], False);
    end;
  for I := 0 to High(FBirds) do
    with FBirds[I] do
    begin
      X := X + VX * DT;
      Y := Y + VY * DT;
      Phase := Phase + DT * (9 + Size * 0.2);
      if (X > FVisR + 100) or (X < FVisL - 100) or (Y < 20) then SpawnBird(FBirds[I], False);
    end;
  // crabs: walk sideways, stop, turn; stay on the sand
  for I := 0 to High(FCrabs) do
    with FCrabs[I] do
    begin
      Timer := Timer - DT;
      if Timer <= 0 then
      begin
        Timer := RandRange(0.8, 3.5);
        if Random < 0.35 then Walking := False
        else
        begin
          Walking := True;
          if Random < 0.5 then VX := -VX;
        end;
      end;
      if Walking then
      begin
        X := X + VX * DT;
        LegPhase := LegPhase + DT * Abs(VX) * 0.6;
        if X < FVisL + 10 then VX := Abs(VX);
        if X > FVisR - 10 then VX := -Abs(VX);
        Y := EnsureRange(Y + Sin(FTime * 0.7 + I) * 2 * DT, BeachTop(X) + 14, ShoreY(X) - 14);
      end;
    end;
  // fish: wait, then jump along a parabola
  for I := 0 to High(FFish) do
    with FFish[I] do
    begin
      if T < 0 then
      begin
        Wait := Wait - DT;
        if Wait <= 0 then T := 0;
      end
      else
      begin
        T := T + DT;
        if T > Dur * 1.6 then SpawnFish(FFish[I], False);
      end;
    end;
  // boat: drifts right and comes back from the left edge
  with FBoat do
  begin
    X := X + Speed * DT;
    if X > FVisR + 90 then X := FVisL - 90;
  end;
end;

{ Rising puffs: each travels from the crater up and out through the top edge,
  growing as it goes. Positions are worked out and sorted once here. }
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
      T := 1 - Power(1 - U, 1.4);
      Cx := CraterX + T * T * 90 - Sin(T * 5) * 18 * T + Sin(FTime * 0.45 + Wob) * 10 * T;
      Hw := 30 + T * 250 + IfThen(T > 0.5, (T - 0.5) * 400, 0);
      R := (17 + T * 70) * RMul * RDepth[Depth];
      if U < 0.05 then R := R * (0.3 + 0.7 * U / 0.05);
      FPuffDraw[I].X := Cx + Lat * Hw * Spread[Depth] + Sin(FTime * 0.8 + Wob * 2) * 4;
      FPuffDraw[I].Y := BaseY - T * (BaseY + 160);
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
  FCrabs := Copy(Src.FCrabs);
  FFish := Copy(Src.FFish);
  FBoat := Src.FBoat;
  for I := 0 to Min(High(FFarClouds), High(Src.FFarClouds)) do
  begin
    FFarClouds[I].OX := Src.FFarClouds[I].OX;
    FFarClouds[I].OY := Src.FFarClouds[I].OY;
  end;
  for I := 0 to Min(High(FNearClouds), High(Src.FNearClouds)) do
  begin
    FNearClouds[I].OX := Src.FNearClouds[I].OX;
    FNearClouds[I].OY := Src.FNearClouds[I].OY;
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

  procedure Add(B: TBGRABitmap);
  begin
    if B <> nil then Inc(Result, Int64(B.NbPixels) * 4);
  end;

begin
  Result := 0;
  for K := 0 to SpriteKinds - 1 do
    for I := 0 to High(FSprites[K]) do
      Add(FSprites[K][I]);
  for I := 0 to High(FFarClouds) do Add(FFarClouds[I].Sprite);
  for I := 0 to High(FNearClouds) do Add(FNearClouds[I].Sprite);
  Add(FCaption);
end;

function TVolcanoScene.StaticBytes: Int64;

  procedure Add(B: TBGRABitmap);
  begin
    if B <> nil then Inc(Result, Int64(B.NbPixels) * 4);
  end;

begin
  Result := 0;
  Add(FBack);
  Add(FVolcano);
  Add(FJungle);
  Add(FBeach);
  Add(FSeaBody);
  Add(FCutter.FLayer);
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

begin
  SL := TStringList.Create;
  try
    SL.Add('DESIGN SPACE');
    SL.Add(Format('  %d x %d design px, crater (%d, %d), rim y %d, cone base y %d',
      [DesignW, DesignH, CraterX, CraterY, RimY, ConeBaseY]));
    SL.Add(Format('  jungle top ~%d, beach top ~%d, shore ~%d, sea to %d', [JungleTopY,
      BeachTopY, ShoreBaseY, SeaBottomY]));
    SL.Add(Format('  window %d x %d, scale %s, offset (%s, %s), visible x %s .. %s',
      [FWidth, FHeight, FormatFloat('0.0000', FScale), F(FOffX), F(FOffY), F(FVisL), F(FVisR)]));
    SL.Add('  the island is wider than any window: cone, jungle, beach and sea are cut');
    SL.Add('  for the whole visible range, so they always run past both edges');
    SL.Add('');
    SL.Add('LAYERS (back to front)');
    SL.Add('  Layer            Kind            Shadow  Notes');
    for Id := Low(TLayerId) to High(TLayerId) do
      SL.Add(Format('  %-16s %-15s %-7s %s', [LayerNames[Id], LayerKinds[Id],
        IfThen(LayerDepth[Id] = 0, '-', F(LayerDepth[Id])), LayerNotes[Id]]));
    SL.Add('');
    SL.Add('GEOMETRY');
    SL.Add('  cone half width(y) = 46 + 640 * u^0.72, u = (y - 528) / (1010 - 528)');
    SL.Add('  shore(x) = 1100 + 9 sin(0.011 x) + 5 sin(0.029 x + 1.3)');
    SL.Add('  jungle top(x) = 905 + 22 sin(0.013 x + 0.4) + 10 sin(0.041 x)');
    SL.Add('');
    SL.Add('SEA');
    SL.Add('  4 crests, 10 s from the front to the beach, band 24 -> 4 px, foam grows');
    SL.Add('  near the shore; each arrival (every 2.5 s) runs a swash 4 -> 19 px up the sand');
    SL.Add('');
    SL.Add('LAVA RIVERS  (x = crater + K * 0.9 * hw(y) + sin(s*6 + seed + t*0.3) * 9 * s)');
    SL.Add('  #   K       EndY   Width');
    for I := 0 to High(FFlows) do
      with FFlows[I] do
        SL.Add(Format('  %d   %-7s %-6s %s', [I, F(K), F(EndY), F(W)]));
    SL.Add('  4 passes: glow x2.4 (alpha 55-70), edge #E0441A, mid #F7861E, core #FFC23A');
    SL.Add('');
    SL.Add('CLOUDS');
    SL.Add(Format('  far %d (right to left, 6-11 px/s, opacity 75%%), near %d (left to right,',
      [Length(FFarClouds), Length(FNearClouds)]));
    SL.Add('  12-19 px/s); 3 tones per puff (shade, mid, sunlit) then blurred');
    SL.Add('');
    SL.Add('LIFE');
    SL.Add(Format('  palms %d, crabs %d, fish %d, birds %d, boat 1', [Length(FPalms),
      Length(FCrabs), Length(FFish), Length(FBirds)]));
    SL.Add(Format('  smoke puffs %d, lava blobs %d, embers %d, ash %d', [Length(FPuffs),
      Length(FBlobs), Length(FEmbers), Length(FAsh)]));
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
  clLavaGlow := Hex('#FF7A1A');
  clWave := Hex('#D8F4F6');
  clFoam := Hex('#FFFFFF');
  clCrab := Hex('#D9532B');
  clCrabDark := Hex('#B23E1E');
  clCrabLeg := Hex('#9E3418');
  clHull := Hex('#6B3A22');
  clSail := Hex('#F4F2EA');
  clSailShade := Hex('#D9D6CA');
  clFishBack := Hex('#4F6F8F');
  clFishBelly := Hex('#CFDAE3');
  clPalmTrunk := Hex('#6B4F35');
  clPalmLeaf := Hex('#3F7A2A');
  clPalmLeafLight := Hex('#5E9A38');
  clPalmDark := BGRA(36, 62, 34, 200);
  clBird := Hex('#1C1C1C');
  // round sprites: centre (lit) and rim colours
  SpriteFill[0] := Hex('#5A5A5E'); SpriteEdge[0] := Hex('#1C1C1F');
  SpriteFill[1] := Hex('#6C6C70'); SpriteEdge[1] := Hex('#232326');
  SpriteFill[2] := Hex('#818186'); SpriteEdge[2] := Hex('#2C2C30');
  SpriteFill[3] := Hex('#FFB040'); SpriteEdge[3] := Hex('#E8601C');
  SpriteFill[4] := Hex('#FF8A3A'); SpriteEdge[4] := Hex('#C83A18');
  SpriteFill[5] := Hex('#FFF0A0'); SpriteEdge[5] := Hex('#FFB52E');
end.
