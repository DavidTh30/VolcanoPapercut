unit uVolcanoScene;

{ Paper-cut volcano island scene.

  The picture is designed in a fixed 736 x 1308 "design space" (the size of the
  reference image) and scaled to fit the window.

  Every frame is built as a stack of paper layers. Each layer is drawn on its own
  transparent bitmap (design-rect sized), then a soft drop shadow is laid down
  (blackened half-resolution copy, blurred, offset down-right) and the layer is
  placed on top. Only the paper background and the volcano cone never move, so
  they are cut once per window size; clouds, smoke, palms, lava, fire and the sea
  are re-cut every frame so they can move. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, Graphics, BGRABitmap, BGRABitmapTypes;

const
  DesignW = 736;
  DesignH = 1308;
  CraterX = 375;
  CraterY = 690;
  RimY = 705;       // top of the cone
  ConeBaseY = 1128; // bottom of the cone

type
  TParticle = record
    X, Y, VX, VY, Life, MaxLife, Size, Phase: Single;
  end;

  TBird = record
    X, Y, VX, VY, Size, Phase: Single;
  end;

  TCloud = record
    Puffs: array of Single; // x, y, r triples
    MinX, MaxX, MinY, MaxY: Single;
    OX, OY, Speed, Phase: Single;
    Sprite: TBGRABitmap;     // cut once per window size
    Drift: Boolean;          // True = sails across the sky, False = bobs in place
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

  TBlob = record
    U, Speed, Lat, RBase: Single;
    Yellow: Boolean;
  end;

  TFlow = record
    K, EndY, W, Seed: Single; // K = side of the cone (-1 left .. 1 right)
  end;

  { Everything the frame is made of, back to front. }
  TLayerId = (lyBackground, lyFarClouds, lySmoke, lyBackPalms, lyVolcano, lyFire,
    lyFrontPalms, lySea, lyLowClouds, lyGlow, lyAsh, lyEmbers, lyBirds, lyCaption);

const
  LayerNames: array[TLayerId] of string = ('Background', 'Far clouds', 'Smoke',
    'Back palms', 'Volcano cone', 'Lava + fire', 'Front palms', 'Sea', 'Low clouds',
    'Crater glow', 'Ash', 'Embers', 'Birds', 'Caption');
  LayerKinds: array[TLayerId] of string = ('static', 'sprites', 'sprites',
    'vector', 'static', 'vector+sprites', 'vector', 'sprite+vector', 'sprites',
    'overlay', 'overlay', 'overlay', 'overlay', 'static');
  { shadow depth multiplier: offset (3, 6) * depth, blur 7 * depth (design px);
    0 = no paper shadow }
  LayerDepth: array[TLayerId] of Single = (0, 0.8, 1.3, 1.0, 1.2, 0.55, 0.7, 0.9, 1.1,
    0, 0, 0, 0, 0);
  LayerNotes: array[TLayerId] of string = (
    'Gradient #F4F4F2 -> #D6D6D4 + random grain +-5, cut once per window size',
    '5 clouds, cut once as sprites; drift right 5..13 px/s and wrap at the window edges',
    '230 puffs on 3 depth sheets; rise from the crater and leave through the top edge',
    '6 silhouette palms; trunk bends and fronds wave',
    'Plump cone (half width 26 + 332 * u^0.6), front lobe, 240 rock strokes, grass strip',
    '7 lava tongues with travelling wavy edges, 90 boiling blobs, shore pool',
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

{ High resolution clock in milliseconds. }
function HiResMs: Double;

type
  { TVolcanoScene }

  TVolcanoScene = class
  private
    FWidth, FHeight: Integer;
    FLW, FLH: Integer;               // layer size in pixels (= window)
    FVisL, FVisR: Single;            // visible x range in design units
    FScale, FOffX, FOffY: Single;
    FOrgX, FOrgY: Single;            // origin used by P(): 0 in layers, offset on Dest
    FBack: TBGRABitmap;              // paper background, window sized
    FVolcano: TBGRABitmap;           // cone + grass with its shadow, design-rect sized
    FLayer: TBGRABitmap;             // the paper layer currently being cut
    FTime: Single;
    FFarClouds, FLowClouds: array of TCloud;
    FBackPalms, FFrontPalms: array of TPalm;
    FPuffs: array of TPuff;
    FBlobs: array of TBlob;
    FFlows: array of TFlow;
    FEmbers: array of TParticle;
    FAsh: array of TParticle;
    FBirds: array of TBird;
    FShowCaption: Boolean;
    FShadow, FBlurTmp, FRow: array of Single;  // CompositeLayer work buffers
    FXIdx: array of Integer;
    FXFrac: array of Single;
    FSprites: array[0..5] of array of TBGRABitmap; // [kind][radius px], see RoundSprite
    FCaption: TBGRABitmap;           // caption card with its shadow
    FSeaBody: TBGRABitmap;           // base plate + sea, waves are drawn per frame
    FSeaPos, FVolcanoPos: TPoint;    // where the cropped sprites sit in the layer
    function RoundSprite(Kind, RPx: Integer): TBGRABitmap;
    procedure FreeSprites;
    function CropLayer(const R: TRect; out Pos: TPoint): TBGRABitmap;
    function P(X, Y: Single): TPointF;
    function S(V: Single): Single;
    function ConeHalfWidth(Y: Single): Single;
    procedure BeginLayer;
    procedure BakeLayer(Dest: TBGRABitmap; Depth: Single);
    procedure CompositeLayer(Dest: TBGRABitmap; OX, OY: Integer; Depth: Single);
    { setup }
    procedure AddCloud(var List: array of TCloud; Index: Integer; const Puffs: array of Single;
      Drift: Boolean);
    procedure SetupPalm(var Pm: TPalm; X, BaseY, H, Lean, Sc: Single;
      TrunkC, LeafC, RibC: TBGRAPixel);
    procedure SpawnPuff(var Pf: TPuff; Initial: Boolean);
    procedure SpawnBlob(var B: TBlob; Initial: Boolean);
    procedure SpawnEmber(var E: TParticle; Initial: Boolean);
    procedure SpawnAsh(var A: TParticle; Initial: Boolean);
    procedure SpawnBird(var B: TBird; Initial: Boolean);
    { shape helpers, all in design coordinates }
    procedure Circle(Bmp: TBGRABitmap; X, Y, R: Single; C: TBGRAPixel);
    procedure Poly(Bmp: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel);
    procedure Leaf(Base, Ctrl, Tip: TPointF; W: Single; C, Rib: TBGRAPixel);
    { layers }
    procedure RenderStatic;
    procedure CutCloud(var C: TCloud);
    procedure DrawCloud(const C: TCloud);
    procedure DrawPalm(const Pm: TPalm);
    procedure DrawSmoke;
    procedure DrawFlow(const F: TFlow);
    procedure Blob(Kind: Integer; X, Y, R: Single);
    procedure DrawFire;
    procedure DrawSea;
    { overlays, drawn straight on Dest }
    procedure DrawGlow(Dest: TBGRABitmap);
    procedure DrawEmbers(Dest: TBGRABitmap);
    procedure DrawAsh(Dest: TBGRABitmap);
    procedure DrawBirds(Dest: TBGRABitmap);
    procedure DrawCaption(Dest: TBGRABitmap);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Resize(AWidth, AHeight: Integer);
    procedure Update(DT: Single);
    procedure Render(Dest: TBGRABitmap);
    property ShowCaption: Boolean read FShowCaption write FShowCaption;
  public
    { developer information }
    LayerOn: array[TLayerId] of Boolean;   // switch single layers off for debugging
    LayerMs: array[TLayerId] of Double;    // smoothed cost of each layer per frame
    RenderMs: Double;                      // smoothed cost of Render
    StaticMs: Double;                      // last RenderStatic (resize) cost
    StaticCount: Integer;                  // how many times the static layers were cut
    function SpriteCount: Integer;
    function SpriteBytes: Int64;
    function BitmapBytes: Int64;
    function DescribeParams: string;
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

{$IFDEF WINDOWS}
function QueryPerformanceCounter(var C: Int64): LongBool; stdcall; external 'kernel32.dll';
function QueryPerformanceFrequency(var F: Int64): LongBool; stdcall; external 'kernel32.dll';
{$ENDIF}

function HiResMs: Double;
{$IFDEF WINDOWS}
var
  C, F: Int64;
begin
  QueryPerformanceCounter(C);
  QueryPerformanceFrequency(F);
  Result := Double(C) / Double(F) * 1000;  // Double: FPC types 1000.0 as Single
end;
{$ELSE}
begin
  Result := GetTickCount64;
end;
{$ENDIF}

function Hex(const S: string): TBGRAPixel;
begin
  Result := StrToBGRA(S);
end;

function WithAlpha(C: TBGRAPixel; A: Byte): TBGRAPixel;
begin
  Result := C;
  Result.alpha := A;
end;

function RandRange(A, B: Single): Single;
begin
  Result := A + Random * (B - A);
end;

function Bezier(const P0, C, P1: TPointF; T: Single): TPointF;
var
  U: Single;
begin
  U := 1 - T;
  Result.X := U * U * P0.X + 2 * U * T * C.X + T * T * P1.X;
  Result.Y := U * U * P0.Y + 2 * U * T * C.Y + T * T * P1.Y;
end;

function BezierTangent(const P0, C, P1: TPointF; T: Single): TPointF;
begin
  Result.X := 2 * (1 - T) * (C.X - P0.X) + 2 * T * (P1.X - C.X);
  Result.Y := 2 * (1 - T) * (C.Y - P0.Y) + 2 * T * (P1.Y - C.Y);
end;

{ TVolcanoScene }

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
  FreeSprites;
  FBack.Free;
  FVolcano.Free;
  FLayer.Free;
  inherited Destroy;
end;

function TVolcanoScene.P(X, Y: Single): TPointF;
begin
  Result := PointF(FOrgX + X * FScale, FOrgY + Y * FScale);
end;

function TVolcanoScene.S(V: Single): Single;
begin
  Result := V * FScale;
end;

{ Half width of the cone at height Y. The power < 1 bulges the sides outward,
  which gives the plump, rounded shoulders. }
function TVolcanoScene.ConeHalfWidth(Y: Single): Single;
begin
  Result := 26 + 332 * Power(EnsureRange((Y - RimY) / (ConeBaseY - RimY), 0, 1), 0.6);
end;

procedure TVolcanoScene.Resize(AWidth, AHeight: Integer);
var
  T0: Double;
begin
  FWidth := Max(1, AWidth);
  FHeight := Max(1, AHeight);
  FScale := Min(FWidth / DesignW, FHeight / DesignH);
  // layers cover the whole window so clouds and birds can go past the picture
  FLW := FWidth;
  FLH := FHeight;
  FOffX := Round((FWidth - DesignW * FScale) / 2);
  FOffY := Round((FHeight - DesignH * FScale) / 2);
  FVisL := -FOffX / FScale;
  FVisR := (FWidth - FOffX) / FScale;
  FreeAndNil(FBack);
  FreeAndNil(FVolcano);
  FreeAndNil(FLayer);
  FreeSprites;
  FBack := TBGRABitmap.Create(FWidth, FHeight);
  FVolcano := TBGRABitmap.Create(FLW, FLH);
  FLayer := TBGRABitmap.Create(FLW, FLH);
  FLayer.LinearAntialiasing := True;
  T0 := HiResMs;
  RenderStatic;
  StaticMs := HiResMs - T0;
  Inc(StaticCount);
end;

procedure TVolcanoScene.BeginLayer;
begin
  FLayer.FillTransparent;
  FOrgX := FOffX;
  FOrgY := FOffY;
end;

{ Bakes the layer and its soft shadow into a transparent bitmap (used once per
  resize for the static cone, so it can go through the regular BGRABitmap filters). }
procedure TVolcanoScene.BakeLayer(Dest: TBGRABitmap; Depth: Single);
var
  Shadow: TBGRABitmap;
  Px: PBGRAPixel;
  I: Integer;
begin
  Shadow := TBGRABitmap.Create(FLW, FLH);
  try
    Shadow.PutImage(0, 0, FLayer, dmSet);
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
  Dest.PutImage(0, 0, FLayer, dmDrawWithTransparency);
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

{ Lays the current layer on an opaque Dest with a soft paper shadow, in one pass.
  The shadow is the layer alpha sampled every 4th pixel, box-blurred twice, then
  bilinearly stretched back while blending; this keeps a layer at a few ms. }
procedure TVolcanoScene.CompositeLayer(Dest: TBGRABitmap; OX, OY: Integer; Depth: Single);
const
  F = 4;
  Strength = 110 / 255;
var
  SW, SH, X, Y, R, DX, DY, LX, LY, SY0, X0, X1, Y0, Y1, SA, LA, Inv, Pad: Integer;
  BX0, BX1, BY0, BY1: Integer;
  FY, V: Single;
  Src, Dst, L: PBGRAPixel;
begin
  BX0 := MaxInt; BX1 := -1; BY0 := MaxInt; BY1 := -1;
  SW := FLW div F + 2;
  SH := FLH div F + 2;
  if Length(FShadow) <> SW * SH then
  begin
    SetLength(FShadow, SW * SH);
    SetLength(FBlurTmp, SW * SH);
  end;
  for Y := 0 to SH - 1 do
  begin
    LY := Y * F;
    if LY >= FLH then
    begin
      for X := 0 to SW - 1 do FShadow[Y * SW + X] := 0;
      Continue;
    end;
    Src := FLayer.ScanLine[LY];
    for X := 0 to SW - 1 do
    begin
      LX := X * F;
      if (LX < FLW) and ((Src + LX)^.alpha > 0) then
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

  // only touch the pixels around what the layer actually holds
  DX := Round(S(3) * Depth);
  DY := Round(S(6) * Depth);
  Pad := (2 * R + 2) * F;
  X0 := Max(0, OX + BX0 * F - Pad);
  X1 := Min(Dest.Width, OX + BX1 * F + DX + Pad);
  Y0 := Max(0, OY + BY0 * F - Pad);
  Y1 := Min(Dest.Height, OY + BY1 * F + DY + Pad);
  // horizontal sample positions are the same for every row
  if Length(FXIdx) <> Dest.Width then
  begin
    SetLength(FXIdx, Dest.Width);
    SetLength(FXFrac, Dest.Width);
  end;
  for X := X0 to X1 - 1 do
  begin
    V := (X - OX - DX) / F;
    FXIdx[X] := Floor(V);
    FXFrac[X] := V - FXIdx[X];
  end;
  SetLength(FRow, SW);
  L := nil;
  for Y := Y0 to Y1 - 1 do
  begin
    FY := (Y - OY - DY) / F;
    SY0 := Floor(FY);
    FY := FY - SY0;
    for X := 0 to SW - 1 do
    begin
      V := 0;
      if (SY0 >= 0) and (SY0 < SH) then V := FShadow[SY0 * SW + X] * (1 - FY);
      if (SY0 + 1 >= 0) and (SY0 + 1 < SH) then V := V + FShadow[(SY0 + 1) * SW + X] * FY;
      FRow[X] := V;
    end;
    LY := Y - OY;
    if (LY >= 0) and (LY < FLH) then Src := FLayer.ScanLine[LY] else Src := nil;
    Dst := Dest.ScanLine[Y];
    for X := X0 to X1 - 1 do
    begin
      LX := FXIdx[X];
      V := 0;
      if (LX >= 0) and (LX < SW) then V := FRow[LX] * (1 - FXFrac[X]);
      if (LX + 1 >= 0) and (LX + 1 < SW) then V := V + FRow[LX + 1] * FXFrac[X];
      SA := Round(V);
      LA := 0;
      LX := X - OX;
      if (Src <> nil) and (LX >= 0) and (LX < FLW) then
      begin
        L := Src + LX;
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
          Continue;
        end;
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
      end;
    end;
  end;
  Dest.InvalidateBitmap;
end;

{ Round paper pieces, cached per pixel radius. Kinds 0..2 are smoke puffs (back to
  front), 3 = orange lava, 4 = red-orange lava tip, 5 = yellow lava with a curl. }
function TVolcanoScene.RoundSprite(Kind, RPx: Integer): TBGRABitmap;
const
  Fills: array[0..5] of string = ('#232323', '#2E2E2E', '#3A3A3A', '#F7861E', '#E8501E', '#FFC23A');
  Lines: array[0..2] of string = ('#161616', '#202020', '#2A2A2A');
var
  I, Old, Size: Integer;
  C: Single;
begin
  if RPx >= Length(FSprites[Kind]) then
  begin
    Old := Length(FSprites[Kind]);
    SetLength(FSprites[Kind], RPx + 16);
    for I := Old to High(FSprites[Kind]) do
      FSprites[Kind][I] := nil;
  end;
  Result := FSprites[Kind][RPx];
  if Result = nil then
  begin
    Size := 2 * RPx + 4;
    C := Size / 2 - 0.5;
    Result := TBGRABitmap.Create(Size, Size);
    Result.FillEllipseAntialias(C, C, RPx, RPx, Hex(Fills[Kind]));
    if Kind <= 2 then
      Result.EllipseAntialias(C, C, RPx, RPx, Hex(Lines[Kind]), Max(0.8, S(1.6)))
    else if Kind = 5 then
      Result.EllipseAntialias(C, C, RPx * 0.5, RPx * 0.5, Hex('#F09A1E'), Max(0.6, S(1.1)));
    FSprites[Kind][RPx] := Result;
  end;
end;

procedure TVolcanoScene.FreeSprites;
var
  D, I: Integer;
begin
  for D := 0 to High(FSprites) do
  begin
    for I := 0 to High(FSprites[D]) do
      FSprites[D][I].Free;
    SetLength(FSprites[D], 0);
  end;
  for D := 0 to High(FFarClouds) do
    FreeAndNil(FFarClouds[D].Sprite);
  for D := 0 to High(FLowClouds) do
    FreeAndNil(FLowClouds[D].Sprite);
  FreeAndNil(FCaption);
  FreeAndNil(FSeaBody);
end;

{ Copies the part of FLayer inside the design rect R into its own bitmap. }
function TVolcanoScene.CropLayer(const R: TRect; out Pos: TPoint): TBGRABitmap;
var
  A, B: TPointF;
  PR: TRect;
begin
  A := P(R.Left, R.Top);
  B := P(R.Right, R.Bottom);
  PR := Rect(Max(0, Floor(A.X)), Max(0, Floor(A.Y)), Min(FLW, Ceil(B.X)), Min(FLH, Ceil(B.Y)));
  if PR.Right <= PR.Left then PR.Right := PR.Left + 1;
  if PR.Bottom <= PR.Top then PR.Bottom := PR.Top + 1;
  Pos := PR.TopLeft;
  Result := TBGRABitmap(FLayer.GetPart(PR));
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

{ ---------- shape helpers ---------- }

procedure TVolcanoScene.Circle(Bmp: TBGRABitmap; X, Y, R: Single; C: TBGRAPixel);
var
  Q: TPointF;
begin
  Q := P(X, Y);
  Bmp.FillEllipseAntialias(Q.X, Q.Y, S(R), S(R), C);
end;

procedure TVolcanoScene.Poly(Bmp: TBGRABitmap; const Pts: array of TPointF; C: TBGRAPixel);
var
  Scaled: array of TPointF;
  I: Integer;
begin
  SetLength(Scaled, Length(Pts));
  for I := 0 to High(Pts) do
    Scaled[I] := P(Pts[I].X, Pts[I].Y);
  Bmp.FillPolyAntialias(Scaled, C);
end;

{ A palm frond: a tapered strip along a quadratic curve with a saw-tooth edge. }
procedure TVolcanoScene.Leaf(Base, Ctrl, Tip: TPointF; W: Single; C, Rib: TBGRAPixel);
const
  N = 12;
var
  Pts: array of TPointF;
  Mid: array of TPointF;
  I: Integer;
  T, Wt, L: Single;
  B, D, Nrm: TPointF;
begin
  SetLength(Pts, 2 * (N + 1));
  SetLength(Mid, N + 1);
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
    Pts[I] := PointF(B.X + Nrm.X * Wt, B.Y + Nrm.Y * Wt);
    Pts[2 * (N + 1) - 1 - I] := PointF(B.X - Nrm.X * Wt * 0.8, B.Y - Nrm.Y * Wt * 0.8);
    Mid[I] := P(B.X, B.Y);
  end;
  Poly(FLayer, Pts, C);
  if Rib.alpha > 0 then
    FLayer.DrawPolyLineAntialias(Mid, Rib, Max(0.8, S(1.2)));
end;

{ ---------- static layers ---------- }

procedure TVolcanoScene.RenderStatic;
const
  N = 48;
var
  I, K: Integer;
  Px: PBGRAPixel;
  Noise, X, Y, Hw: Single;
  Pts: array of TPointF;
  Q: TPointF;
begin
  RandSeed := 20261015;

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

  { plump volcano cone: left flank up, crater rim, right flank down }
  BeginLayer;
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
  Poly(FLayer, Pts, Hex('#2F2F2F'));

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
  Poly(FLayer, Pts, Hex('#353535'));

  { rock texture strokes follow the slope }
  for I := 1 to 240 do
  begin
    Y := RandRange(RimY + 15, ConeBaseY - 12);
    Hw := ConeHalfWidth(Y);
    X := CraterX + RandRange(-0.9, 0.9) * Hw;
    Q := P(X, Y);
    FLayer.DrawLineAntialias(Q.X, Q.Y, Q.X + S((X - CraterX) / Hw * 4),
      Q.Y + S(RandRange(5, 14)), Hex('#474747'), Max(0.6, S(1.2)));
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
  Poly(FLayer, Pts, Hex('#6DB33F'));
  Poly(FLayer, [PointF(14, 1130), PointF(722, 1130), PointF(722, 1140), PointF(14, 1140)],
    Hex('#4E9A2E'));

  Q := P(0, RimY - 20);
  FVolcano.FillTransparent;
  BakeLayer(FVolcano, 1.2);
  // keep only the band of rows the cone covers
  FVolcanoPos := Point(0, Max(0, Round(Q.Y)));
  BGRAReplace(FVolcano, FVolcano.GetPart(Rect(0, FVolcanoPos.Y, FLW,
    Min(FLH, Round(P(0, 1160).Y)))));

  for I := 0 to High(FFarClouds) do
    CutCloud(FFarClouds[I]);
  for I := 0 to High(FLowClouds) do
    CutCloud(FLowClouds[I]);

  { base plate + sea body }
  BeginLayer;
  Poly(FLayer, [PointF(10, 1137), PointF(726, 1137), PointF(726, 1150), PointF(10, 1150)],
    Hex('#1A1A1A'));
  Poly(FLayer, [PointF(12, 1139), PointF(724, 1139), PointF(724, 1148), PointF(12, 1148)],
    Hex('#FFFFFF'));
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
  Poly(FLayer, Pts, Hex('#3E5566'));
  FreeAndNil(FSeaBody);
  FSeaBody := CropLayer(Rect(0, 1130, DesignW, 1270), FSeaPos);

  { caption card }
  FreeAndNil(FCaption);
  FCaption := TBGRABitmap.Create(Round(S(392)), Round(S(90)));
  FCaption.FillRoundRectAntialias(S(3), S(6), S(383), S(80), S(14), S(14), BGRA(0, 0, 0, 45));
  FCaption.FillRoundRectAntialias(S(1), S(1), S(381), S(75), S(14), S(14), BGRA(255, 255, 255, 235));
  FCaption.RoundRectAntialias(S(1), S(1), S(381), S(75), S(14), S(14), Hex('#1A1A1A'), Max(1, S(2)));
  FCaption.FontName := 'Segoe UI';
  FCaption.FontQuality := fqFineAntialiasing;
  FCaption.FontStyle := [fsBold];
  FCaption.FontHeight := Max(8, Round(S(30)));
  FCaption.TextOut(S(191), S(9), 'VOLCANO ISLAND', Hex('#2B2B2B'), taCenter);
  FCaption.FontStyle := [];
  FCaption.FontHeight := Max(7, Round(S(15)));
  FCaption.TextOut(S(191), S(47), 'Space pause   F11 full   S save   H hide   I info',
    Hex('#E0441A'), taCenter);
end;

{ ---------- moving layers ---------- }

{ Cuts a cloud sprite. A black pass slightly larger than the white pass gives the
  thin ink outline. The sprite is cut in a 4 px margin so the outline fits. }
procedure TVolcanoScene.CutCloud(var C: TCloud);
var
  I: Integer;
  Ink: Single;
  Pos: TPoint;
begin
  BeginLayer;
  FOrgX := S(-C.MinX + 6);
  FOrgY := S(-C.MinY + 6);
  Ink := Max(1.2 / FScale, 2.2);
  I := 0;
  while I + 2 <= High(C.Puffs) do
  begin
    Circle(FLayer, C.Puffs[I], C.Puffs[I + 1], C.Puffs[I + 2] + Ink, Hex('#1A1A1A'));
    Inc(I, 3);
  end;
  I := 0;
  while I + 2 <= High(C.Puffs) do
  begin
    Circle(FLayer, C.Puffs[I], C.Puffs[I + 1], C.Puffs[I + 2], Hex('#FFFFFF'));
    Inc(I, 3);
  end;
  FOrgX := 0;
  FOrgY := 0;
  FreeAndNil(C.Sprite);
  C.Sprite := CropLayer(Rect(0, 0, Ceil(C.MaxX - C.MinX + 12), Ceil(C.MaxY - C.MinY + 12)), Pos);
end;

procedure TVolcanoScene.DrawCloud(const C: TCloud);
var
  Q: TPointF;
begin
  Q := P(C.MinX - 6 + C.OX, C.MinY - 6 + C.OY);
  FLayer.PutImage(Round(Q.X), Round(Q.Y), C.Sprite, dmDrawWithTransparency);
end;

{ The trunk bends with the wind; every frond waves on its own beat. }
procedure TVolcanoScene.DrawPalm(const Pm: TPalm);
const
  N = 14;
var
  Base, Top, Ctrl, B, D, Tip, LC: TPointF;
  Trunk: array of TPointF;
  I: Integer;
  T, W, L, A, Len, Sway: Single;
begin
  Sway := Sin(FTime * 1.1 + Pm.Phase) + 0.35 * Sin(FTime * 2.3 + Pm.Phase * 1.7);
  Base := PointF(Pm.X, Pm.BaseY);
  Top := PointF(Pm.X + Pm.Lean * Pm.H + Sway * Pm.H * 0.022, Pm.BaseY - Pm.H);
  Ctrl := PointF(Pm.X + Pm.Lean * Pm.H * 0.15, Pm.BaseY - Pm.H * 0.55);
  SetLength(Trunk, 2 * (N + 1));
  for I := 0 to N do
  begin
    T := I / N;
    B := Bezier(Base, Ctrl, Top, T);
    D := BezierTangent(Base, Ctrl, Top, T);
    L := Sqrt(D.X * D.X + D.Y * D.Y);
    W := (6.5 - 3 * T) * Pm.Sc;
    Trunk[I] := PointF(B.X - D.Y / L * W, B.Y + D.X / L * W);
    Trunk[2 * (N + 1) - 1 - I] := PointF(B.X + D.Y / L * W, B.Y - D.X / L * W);
  end;
  Poly(FLayer, Trunk, Pm.TrunkC);
  for I := 0 to 8 do
  begin
    A := DegToRad(Pm.LeafAng[I] + Sway * 3 + Sin(FTime * 1.9 + Pm.Phase + I * 0.7) * 4);
    Len := Pm.LeafLen[I] * Pm.Sc * (1 + 0.03 * Sin(FTime * 2.4 + I));
    Tip := PointF(Top.X + Cos(A) * Len, Top.Y + Sin(A) * Len * 0.55 + Len * 0.42);
    LC := PointF(Top.X + Cos(A) * Len * 0.55, Top.Y + Sin(A) * Len * 0.6 - Len * 0.22);
    Leaf(Top, LC, Tip, 9 * Pm.Sc, Pm.LeafC, Pm.RibC);
  end;
  Circle(FLayer, Top.X, Top.Y + 2 * Pm.Sc, 4 * Pm.Sc, Pm.TrunkC);
end;

{ Rising puffs. Each puff travels from the crater up and out through the top edge,
  growing as it goes, while new ones are born at the crater. Puffs are blitted from
  cached sprites (one per depth and pixel radius). }
procedure TVolcanoScene.DrawSmoke;
const
  Spread: array[0..2] of Single = (1.0, 0.8, 0.55);
  RDepth: array[0..2] of Single = (1.1, 1.0, 0.85);
  BaseY = 655;
var
  N, I, J, Tmp: Integer;
  Order: array of Integer;
  PX, PY, PR, Key: array of Single;
  T, Cx, Hw: Single;
  RPx: Integer;
  Sprite: TBGRABitmap;
  Q: TPointF;
begin
  N := Length(FPuffs);
  SetLength(Order, N);
  SetLength(PX, N);
  SetLength(PY, N);
  SetLength(PR, N);
  SetLength(Key, N);
  for I := 0 to N - 1 do
    with FPuffs[I] do
    begin
      T := 1 - Power(1 - U, 1.4);  // quick out of the crater, slow at the top
      Cx := CraterX + T * T * 80 - Sin(T * 5) * 18 * T + Sin(FTime * 0.45 + Wob) * 9 * T;
      Hw := 26 + T * 230 + IfThen(T > 0.55, (T - 0.55) * 380, 0);
      PR[I] := (15 + T * 62) * RMul * RDepth[Depth];
      if U < 0.05 then PR[I] := PR[I] * (0.3 + 0.7 * U / 0.05);
      PX[I] := EnsureRange(Cx + Lat * Hw * Spread[Depth] + Sin(FTime * 0.8 + Wob * 2) * 4,
        30, DesignW - 30);
      PY[I] := BaseY - T * (BaseY + 110);  // leaves through the top edge
      Key[I] := Depth * 10000 + PY[I];  // back sheet first, higher puffs first
      Order[I] := I;
    end;
  for I := 1 to N - 1 do
  begin
    Tmp := Order[I];
    J := I - 1;
    while (J >= 0) and (Key[Order[J]] > Key[Tmp]) do
    begin
      Order[J + 1] := Order[J];
      Dec(J);
    end;
    Order[J + 1] := Tmp;
  end;
  for J := 0 to N - 1 do
  begin
    I := Order[J];
    RPx := Max(1, Round(S(PR[I])));
    Sprite := RoundSprite(FPuffs[I].Depth, RPx);
    Q := P(PX[I], PY[I]);
    FLayer.PutImage(Round(Q.X - Sprite.Width / 2), Round(Q.Y - Sprite.Height / 2), Sprite,
      dmDrawWithTransparency);
  end;
end;

{ A lava tongue hugging the plump flank. The edges are wavy, and the ripples
  travel downhill (sin(s*k - time*w)), so the lava looks like it is flowing. }
procedure TVolcanoScene.DrawFlow(const F: TFlow);
const
  N = 40;
  Scales: array[0..2] of Single = (1, 0.62, 0.3);
  Reach: array[0..2] of Single = (1, 0.88, 0.66);
var
  Ctr: array[0..N] of TPointF;
  Pts: array of TPointF;
  Pass, I, A, B: Integer;
  Sv, Y, Wt, WL, WR, L, Spd: Single;
  D, Nrm: TPointF;
  Colors: array[0..2] of TBGRAPixel;
begin
  Colors[0] := Hex('#E0441A');
  Colors[1] := Hex('#F7861E');
  Colors[2] := Hex('#FFC23A');
  for I := 0 to N do
  begin
    Sv := I / N;
    Y := RimY + 4 + (F.EndY - RimY - 4) * Sv;
    Ctr[I] := PointF(CraterX + F.K * ConeHalfWidth(Y) * 0.92 +
      Sin(Sv * 7 + F.Seed + FTime * 0.35) * 7 * Sv, Y);
  end;
  SetLength(Pts, 2 * (N + 1));
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
      WL := Wt * (1 + 0.28 * Sin(Sv * 29 - FTime * Spd + F.Seed)
        + 0.14 * Sin(Sv * 61 - FTime * Spd * 1.7 + F.Seed * 1.9));
      WR := Wt * (1 + 0.28 * Sin(Sv * 31 - FTime * Spd * 1.1 + F.Seed + 1.3)
        + 0.14 * Sin(Sv * 57 - FTime * Spd * 1.6 + F.Seed * 2.3));
      Pts[I] := PointF(Ctr[I].X + Nrm.X * WL, Ctr[I].Y + Nrm.Y * WL);
      Pts[2 * (N + 1) - 1 - I] := PointF(Ctr[I].X - Nrm.X * WR, Ctr[I].Y - Nrm.Y * WR);
    end;
    Poly(FLayer, Pts, Colors[Pass]);
  end;
end;

procedure TVolcanoScene.Blob(Kind: Integer; X, Y, R: Single);
var
  Sprite: TBGRABitmap;
  Q: TPointF;
begin
  Sprite := RoundSprite(Kind, Max(1, Round(S(R))));
  Q := P(X, Y);
  FLayer.PutImage(Round(Q.X - Sprite.Width / 2), Round(Q.Y - Sprite.Height / 2), Sprite,
    dmDrawWithTransparency);
end;

{ Lava flows, the shore pool and the boiling burst over the crater. }
procedure TVolcanoScene.DrawFire;
var
  I: Integer;
  X, Y, R, Pulse: Single;
  Q: TPointF;
begin
  for I := 0 to High(FFlows) do
    DrawFlow(FFlows[I]);

  Pulse := Sin(FTime * 2.2);
  Circle(FLayer, 560, 1128, 9 + Pulse, Hex('#F26A1B'));
  Circle(FLayer, 574, 1126, 7 - Pulse * 0.7, Hex('#FFA41B'));
  Circle(FLayer, 548, 1131, 5 + Pulse * 0.5, Hex('#FFC23A'));

  // a fixed lava mass sits in the crater so the burst never looks empty
  for I := 0 to 6 do
    Blob(3, CraterX - 27 + I * 9, RimY - 6 + Sin(FTime * 3 + I) * 2,
      13 + Sin(FTime * 2.6 + I * 1.3) * 2);

  for I := 0 to High(FBlobs) do
    with FBlobs[I] do
    begin
      if Yellow then
      begin
        X := CraterX + Lat * (12 + Sin(U * Pi) * 26);
        Y := RimY - 2 - U * 95;
        R := RBase * (0.5 + 0.6 * Sin(Pi * Min(1, U * 1.15)));
        Blob(5, X, Y, R);
      end
      else
      begin
        X := CraterX + Lat * (18 + Sin(U * Pi) * 34);
        Y := RimY + 4 - U * 125;
        R := RBase * (0.55 + 0.6 * Sin(Pi * Min(1, U * 1.1)));
        if U > 0.78 then
          Blob(4, X, Y, R)
        else
          Blob(3, X, Y, R);
      end;
    end;
end;

{ Sea body sprite plus wave lines that roll left and right. }
procedure TVolcanoScene.DrawSea;
var
  Wave: array of TPointF;
  N, Row: Integer;
  X, Y, Bottom, Dir: Single;
begin
  FLayer.PutImage(FSeaPos.X, FSeaPos.Y, FSeaBody, dmSet);
  SetLength(Wave, 200);
  Row := 0;
  Y := 1160;
  while Y < 1255 do
  begin
    if Odd(Row) then Dir := -1 else Dir := 1;
    N := 0;
    X := 26;
    while X < 710 do
    begin
      Bottom := 1180 + 80 * Sqrt(Max(0, 1 - Sqr((X - 368) / 352)));
      if Y + 6 < Bottom then
      begin
        Wave[N] := P(X, Y + Sin(X * 0.08 + Row * 1.7 - Dir * FTime * (1.4 + Row * 0.15)) * 2.8
          + Sin(FTime * 0.9 + Row) * 1.2);
        Inc(N);
      end;
      X := X + 5;
    end;
    if N > 1 then
      FLayer.DrawPolyLineAntialias(Copy(Wave, 0, N), Hex('#22313B'), Max(0.8, S(1.5)));
    Y := Y + 11;
    Inc(Row);
  end;
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

procedure TVolcanoScene.DrawGlow(Dest: TBGRABitmap);
var
  C: TPointF;
  R: Single;
  A: Byte;
begin
  C := P(CraterX, CraterY - 20);
  R := S(140 * (1 + 0.07 * Sin(FTime * 2.3)));
  A := Round(70 + 30 * Sin(FTime * 3.1));
  Dest.GradientFill(Round(C.X - R), Round(C.Y - R), Round(C.X + R), Round(C.Y + R),
    BGRA(255, 150, 40, A), BGRA(255, 120, 20, 0), gtRadial,
    C, PointF(C.X + R, C.Y), dmDrawWithTransparency);
end;

procedure TVolcanoScene.DrawEmbers(Dest: TBGRABitmap);
var
  I: Integer;
  Q: TPointF;
  Fade, Flick: Single;
begin
  for I := 0 to High(FEmbers) do
    with FEmbers[I] do
    begin
      Fade := EnsureRange(Life / MaxLife * 1.6, 0, 1);
      Flick := 0.6 + 0.4 * Sin(FTime * 11 + Phase);
      Q := P(X, Y);
      Dest.FillEllipseAntialias(Q.X, Q.Y, S(Size * 2.4), S(Size * 2.4),
        BGRA(255, 120, 30, Round(50 * Fade * Flick)));
      Dest.FillEllipseAntialias(Q.X, Q.Y, S(Size), S(Size),
        BGRA(255, Round(150 + 80 * Flick), 60, Round(255 * Fade)));
    end;
end;

procedure TVolcanoScene.DrawAsh(Dest: TBGRABitmap);
var
  I, K: Integer;
  Pts: array[0..3] of TPointF;
  Fade, A: Single;
begin
  for I := 0 to High(FAsh) do
    with FAsh[I] do
    begin
      Fade := EnsureRange(Life / MaxLife * 2, 0, 1);
      for K := 0 to 3 do
      begin
        A := Phase + K * Pi / 2;
        Pts[K] := P(X + Cos(A) * Size * (1 - 0.4 * Ord(Odd(K))),
          Y + Sin(A) * Size * (1 - 0.4 * Ord(Odd(K))));
      end;
      Dest.FillPolyAntialias(Pts, BGRA(25, 25, 25, Round(230 * Fade)));
    end;
end;

procedure TVolcanoScene.DrawBirds(Dest: TBGRABitmap);
var
  I, Pass: Integer;
  Pts: array[0..7] of TPointF;
  Tip, Sz, Dx, Dy, Dir: Single;
  C: TBGRAPixel;
begin
  for Pass := 0 to 1 do  // 0 = paper shadow, 1 = bird
    for I := 0 to High(FBirds) do
      with FBirds[I] do
      begin
        Sz := Size;
        Tip := -Sz * 0.75 * Sin(Phase);
        Dir := Sign(VX);
        if Pass = 0 then
        begin
          Dx := 2.5; Dy := 5; C := BGRA(0, 0, 0, 45);
        end
        else
        begin
          Dx := 0; Dy := 0; C := Hex('#161616');
        end;
        Pts[0] := P(X + Dx - Sz, Y + Dy + Tip);
        Pts[1] := P(X + Dx - Sz * 0.4, Y + Dy - Sz * 0.2 + Tip * 0.4);
        Pts[2] := P(X + Dx + Dir * Sz * 0.12, Y + Dy - Sz * 0.05);
        Pts[3] := P(X + Dx + Sz * 0.4, Y + Dy - Sz * 0.2 + Tip * 0.4);
        Pts[4] := P(X + Dx + Sz, Y + Dy + Tip);
        Pts[5] := P(X + Dx + Sz * 0.4, Y + Dy + Sz * 0.05 + Tip * 0.4);
        Pts[6] := P(X + Dx, Y + Dy + Sz * 0.28);
        Pts[7] := P(X + Dx - Sz * 0.4, Y + Dy + Sz * 0.05 + Tip * 0.4);
        Dest.FillPolyAntialias(Pts, C);
      end;
end;

procedure TVolcanoScene.DrawCaption(Dest: TBGRABitmap);
var
  A: TPointF;
begin
  A := P(176, 17);
  Dest.PutImage(Round(A.X), Round(A.Y), FCaption, dmDrawWithTransparency);
end;

procedure TVolcanoScene.Render(Dest: TBGRABitmap);
var
  I: Integer;
  T0, TStart: Double;

  procedure Mark(Id: TLayerId);
  var
    T: Double;
  begin
    T := HiResMs;
    LayerMs[Id] := LayerMs[Id] * 0.9 + (T - T0) * 0.1;
    T0 := T;
  end;

begin
  if (FBack = nil) or (FBack.Width <> Dest.Width) or (FBack.Height <> Dest.Height) then
    Resize(Dest.Width, Dest.Height);
  TStart := HiResMs;
  T0 := TStart;
  // layers are window sized and their origin is already offset, so they go to (0, 0)
  if LayerOn[lyBackground] then
    Dest.PutImage(0, 0, FBack, dmSet)
  else
    Dest.Fill(BGRA(244, 244, 242));
  Mark(lyBackground);

  if LayerOn[lyFarClouds] then
  begin
    BeginLayer;
    for I := 0 to High(FFarClouds) do
      DrawCloud(FFarClouds[I]);
    CompositeLayer(Dest, 0, 0, LayerDepth[lyFarClouds]);
  end;
  Mark(lyFarClouds);

  if LayerOn[lySmoke] then
  begin
    BeginLayer;
    DrawSmoke;
    CompositeLayer(Dest, 0, 0, LayerDepth[lySmoke]);
  end;
  Mark(lySmoke);

  if LayerOn[lyBackPalms] then
  begin
    BeginLayer;
    for I := 0 to High(FBackPalms) do
      DrawPalm(FBackPalms[I]);
    CompositeLayer(Dest, 0, 0, LayerDepth[lyBackPalms]);
  end;
  Mark(lyBackPalms);

  if LayerOn[lyVolcano] then
    Dest.PutImage(FVolcanoPos.X, FVolcanoPos.Y, FVolcano, dmDrawWithTransparency);
  Mark(lyVolcano);

  if LayerOn[lyFire] then
  begin
    BeginLayer;
    DrawFire;
    CompositeLayer(Dest, 0, 0, LayerDepth[lyFire]);
  end;
  Mark(lyFire);

  if LayerOn[lyFrontPalms] then
  begin
    BeginLayer;
    for I := 0 to High(FFrontPalms) do
      DrawPalm(FFrontPalms[I]);
    CompositeLayer(Dest, 0, 0, LayerDepth[lyFrontPalms]);
  end;
  Mark(lyFrontPalms);

  if LayerOn[lySea] then
  begin
    BeginLayer;
    DrawSea;
    CompositeLayer(Dest, 0, 0, LayerDepth[lySea]);
  end;
  Mark(lySea);

  if LayerOn[lyLowClouds] then
  begin
    BeginLayer;
    for I := 0 to High(FLowClouds) do
      DrawCloud(FLowClouds[I]);
    CompositeLayer(Dest, 0, 0, LayerDepth[lyLowClouds]);
  end;
  Mark(lyLowClouds);

  // overlays go straight on Dest
  FOrgX := FOffX;
  FOrgY := FOffY;
  if LayerOn[lyGlow] then DrawGlow(Dest);
  Mark(lyGlow);
  if LayerOn[lyAsh] then DrawAsh(Dest);
  Mark(lyAsh);
  if LayerOn[lyEmbers] then DrawEmbers(Dest);
  Mark(lyEmbers);
  if LayerOn[lyBirds] then DrawBirds(Dest);
  Mark(lyBirds);
  if FShowCaption and LayerOn[lyCaption] then
    DrawCaption(Dest);
  Mark(lyCaption);
  RenderMs := RenderMs * 0.9 + (HiResMs - TStart) * 0.1;
end;

{ ---------- developer information ---------- }

function TVolcanoScene.SpriteCount: Integer;
var
  K, I: Integer;
begin
  Result := 0;
  for K := 0 to High(FSprites) do
    for I := 0 to High(FSprites[K]) do
      if FSprites[K][I] <> nil then Inc(Result);
end;

function TVolcanoScene.SpriteBytes: Int64;
var
  K, I: Integer;
begin
  Result := 0;
  for K := 0 to High(FSprites) do
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

function TVolcanoScene.BitmapBytes: Int64;
begin
  Result := 0;
  if FBack <> nil then Inc(Result, Int64(FBack.NbPixels) * 4);
  if FLayer <> nil then Inc(Result, Int64(FLayer.NbPixels) * 4);
  if FVolcano <> nil then Inc(Result, Int64(FVolcano.NbPixels) * 4);
  Inc(Result, Int64(Length(FShadow) + Length(FBlurTmp)) * SizeOf(Single));
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
    SL.Add('  t = 1 - (1 - u)^1.4;  y = 655 - t * 765;  r = (15 + 62 t) * rmul * (1.1/1.0/0.85)');
    SL.Add('  centre x = 375 + 80 t^2 - 18 t sin(5t) + 9 t sin(0.45 time + wob)');
    SL.Add('  half width = 26 + 230 t (+ 380 (t - 0.55) above t = 0.55), spread 1.0/0.8/0.55');
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
    for I := 0 to High(FSprites) do
      SL.Add(Format('  kind %d: %d slots', [I, Length(FSprites[I])]));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

end.
