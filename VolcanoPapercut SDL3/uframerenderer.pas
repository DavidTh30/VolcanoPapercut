unit uFrameRenderer;

{ Renders the scene on all CPU cores.

  Adaptive bands: the picture is not equally busy everywhere (lava and palms
  cost far more per row than the sky), so every BalanceEvery frames the band
  borders are moved to give every band about the same measured cost. The
  frame time then follows the average band instead of the slowest one.

  The frame is cut into horizontal bands (BandsPerThread x threads). The pool's
  workers take bands one after another; each worker has its own TPainter. Bands
  stay as separate bitmaps: the OpenGL window uploads them straight into the
  texture, and Assemble glues them only when a whole picture is needed (PNG).

  Start / Wait split the frame so the caller can do other work (upload the
  previous frame, wait for vsync) while the workers render. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, BGRABitmap, BGRABitmapTypes, uRenderPool, uVolcanoScene;

const
  MaxThreads = 32;  // threads created up front; Threads picks how many work
  BalanceEvery = 20; // frames between two band rebalances

type

  { TFrameRenderer }

  TFrameRenderer = class
  private
    FScene: TVolcanoScene;
    FPool: TRenderPool;
    FPainters: array of TPainter;
    FBands: array of TBGRABitmap;
    FBandTop: array of Integer;
    FWidth, FHeight, FBandsPerThread, FBandH: Integer;
    FRendering: Boolean;
    FKick: Double;
    FSinceBalance: Integer;
    procedure Rebalance;
    procedure BandJob(AIndex, AWorker: Integer);
    procedure BuildPool(AThreads: Integer);
    procedure BuildBands;
    procedure FreeBands;
    function GetBand(I: Integer): TBGRABitmap;
    function GetBandTop(I: Integer): Integer;
    function GetBandCount: Integer;
    function GetThreads: Integer;
  public
    { statistics of the last finished frame }
    LayerCpuMs: array[TLayerId] of Double; // summed over threads, smoothed
    RenderWallMs: Double;                  // kick -> last band done
    RenderCpuMs: Double;                   // sum of worker busy time
    WallSmooth, CpuSmooth: Double;         // smoothed versions
    SpriteMs: Double;                      // parallel sprite cut on the last resize
    BandMs: array of Double;               // per band, last frame
    BandWorker: array of Integer;
    WorkerMs: array of Double;             // per worker, last frame
    WorkerJobs: array of Integer;
    Frames: Int64;
    Adaptive: Boolean;                     // move band borders to balance the cost
    Rebalances: Integer;
    constructor Create(AScene: TVolcanoScene; AThreads, ABandsPerThread: Integer);
    destructor Destroy; override;
    { waits for a running frame, then re-cuts the scene for the new size }
    procedure SetSize(AWidth, AHeight: Integer);
    procedure SetThreads(AThreads: Integer);
    procedure SetBandsPerThread(AValue: Integer);
    procedure ResetBands;  // back to equal band heights
    procedure Start;   // Scene.Prepare must have run
    procedure Wait;
    procedure Render;  // Start + Wait
    procedure Assemble(Dest: TBGRABitmap);
    property Scene: TVolcanoScene read FScene;
    property Pool: TRenderPool read FPool;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Threads: Integer read GetThreads;
    property BandsPerThread: Integer read FBandsPerThread;
    property BandHeight: Integer read FBandH;
    property BandCount: Integer read GetBandCount;
    property Bands[I: Integer]: TBGRABitmap read GetBand;
    property BandTops[I: Integer]: Integer read GetBandTop;
    property Rendering: Boolean read FRendering;
  end;

implementation

constructor TFrameRenderer.Create(AScene: TVolcanoScene; AThreads, ABandsPerThread: Integer);
begin
  inherited Create;
  FScene := AScene;
  FBandsPerThread := Max(1, ABandsPerThread);
  Adaptive := True;
  // every thread the info window can ask for is created now, once
  BuildPool(MaxThreads);
  FPool.ActiveThreads := AThreads;
end;

destructor TFrameRenderer.Destroy;
var
  I: Integer;
begin
  Wait;
  FPool.Free;
  for I := 0 to High(FPainters) do
    FPainters[I].Free;
  FreeBands;
  inherited Destroy;
end;

procedure TFrameRenderer.BuildPool(AThreads: Integer);
var
  I: Integer;
begin
  AThreads := Max(1, AThreads);
  FreeAndNil(FPool);
  for I := 0 to High(FPainters) do
    FPainters[I].Free;
  FPool := TRenderPool.Create(AThreads);
  SetLength(FPainters, AThreads);
  for I := 0 to AThreads - 1 do
    FPainters[I] := TPainter.Create(FScene);
  SetLength(WorkerMs, AThreads);
  SetLength(WorkerJobs, AThreads);
end;

procedure TFrameRenderer.FreeBands;
var
  I: Integer;
begin
  for I := 0 to High(FBands) do
    FBands[I].Free;
  SetLength(FBands, 0);
  SetLength(FBandTop, 0);
end;

{ Equal bands, height a multiple of 4; the last one takes what is left. }
procedure TFrameRenderer.BuildBands;
var
  Count, I, Top: Integer;
begin
  FreeBands;
  if (FWidth < 1) or (FHeight < 1) then Exit;
  Count := Max(1, FPool.ActiveThreads * FBandsPerThread);
  FBandH := ((FHeight + Count - 1) div Count + 3) div 4 * 4;
  FBandH := Max(4, FBandH);
  Count := (FHeight + FBandH - 1) div FBandH;
  SetLength(FBands, Count);
  SetLength(FBandTop, Count);
  Top := 0;
  for I := 0 to Count - 1 do
  begin
    FBandTop[I] := Top;
    FBands[I] := TBGRABitmap.Create(FWidth, Min(FBandH, FHeight - Top));
    Inc(Top, FBandH);
  end;
  SetLength(BandMs, Count);
  SetLength(BandWorker, Count);
  FSinceBalance := 0;
end;

{ Moves the band borders so that each band gets an equal share of the cost
  measured in the last frame (cost per row = band ms / band height). Borders
  move half way each time and stay on multiples of 4. Runs between frames. }
procedure TFrameRenderer.Rebalance;
const
  MinH = 8;
var
  N, I, Y, Band, NewTop, OldTop, H: Integer;
  RowCost: array of Double;
  Total, Target, Acc: Double;
  Tops: array of Integer;
begin
  N := Length(FBands);
  if (N < 2) or (FHeight < N * MinH) then Exit;
  SetLength(RowCost, FHeight);
  Total := 0;
  for Band := 0 to N - 1 do
  begin
    H := FBands[Band].Height;
    for Y := FBandTop[Band] to FBandTop[Band] + H - 1 do
      RowCost[Y] := Max(BandMs[Band], 0.001) / H;
    Total := Total + Max(BandMs[Band], 0.001);
  end;
  SetLength(Tops, N + 1);
  Tops[0] := 0;
  Tops[N] := FHeight;
  Acc := 0;
  Y := 0;
  for I := 1 to N - 1 do
  begin
    Target := Total * I / N;
    while (Y < FHeight) and (Acc + RowCost[Y] < Target) do
    begin
      Acc := Acc + RowCost[Y];
      Inc(Y);
    end;
    OldTop := FBandTop[I];
    NewTop := (OldTop + Y) div 2 div 4 * 4;          // half way, multiple of 4
    NewTop := Max(NewTop, Tops[I - 1] + MinH);
    NewTop := Min(NewTop, FHeight - (N - I) * MinH);
    Tops[I] := NewTop;
  end;
  for I := 0 to N - 1 do
  begin
    H := Tops[I + 1] - Tops[I];
    FBandTop[I] := Tops[I];
    if FBands[I].Height <> H then
      FBands[I].SetSize(FWidth, H);
  end;
  Inc(Rebalances);
end;

procedure TFrameRenderer.SetSize(AWidth, AHeight: Integer);
var
  T0: Double;
begin
  Wait;
  AWidth := Max(1, AWidth);
  AHeight := Max(1, AHeight);
  if (AWidth = FWidth) and (AHeight = FHeight) then Exit;
  FWidth := AWidth;
  FHeight := AHeight;
  FScene.Resize(FWidth, FHeight);
  T0 := HiResMs;
  FPool.Run(FScene.SpriteJobCount, @FScene.SpriteJob);
  SpriteMs := HiResMs - T0;
  BuildBands;
end;

procedure TFrameRenderer.SetThreads(AThreads: Integer);
begin
  Wait;
  AThreads := EnsureRange(AThreads, 1, MaxThreads);
  if AThreads = Threads then Exit;
  FPool.ActiveThreads := AThreads;
  BuildBands;
end;

procedure TFrameRenderer.SetBandsPerThread(AValue: Integer);
begin
  Wait;
  AValue := EnsureRange(AValue, 1, 64);
  if AValue = FBandsPerThread then Exit;
  FBandsPerThread := AValue;
  BuildBands;
end;

procedure TFrameRenderer.ResetBands;
begin
  Wait;
  BuildBands;
end;

procedure TFrameRenderer.BandJob(AIndex, AWorker: Integer);
begin
  FPainters[AWorker].RenderBand(FBands[AIndex], FBandTop[AIndex]);
end;

procedure TFrameRenderer.Start;
var
  I: Integer;
begin
  Wait;
  for I := 0 to High(FPainters) do
    FPainters[I].ResetStats;
  // between frames: the previous frame has been uploaded / assembled already
  Inc(FSinceBalance);
  if Adaptive and (FSinceBalance >= BalanceEvery) and (Frames > 0) then
  begin
    Rebalance;
    FSinceBalance := 0;
  end;
  FKick := HiResMs;
  FRendering := True;
  FPool.Start(Length(FBands), @BandJob);
end;

procedure TFrameRenderer.Wait;
var
  I: Integer;
  Id: TLayerId;
  Sum: Double;
begin
  if not FRendering then Exit;
  FPool.Wait;
  FRendering := False;
  Inc(Frames);
  RenderWallMs := FPool.FinishTime - FKick;
  RenderCpuMs := 0;
  for I := 0 to FPool.ActiveThreads - 1 do
  begin
    WorkerMs[I] := FPool.WorkerMs[I];
    WorkerJobs[I] := FPool.WorkerJobs[I];
    RenderCpuMs := RenderCpuMs + WorkerMs[I];
  end;
  for I := 0 to High(BandMs) do
  begin
    BandMs[I] := FPool.JobMs[I];
    BandWorker[I] := FPool.JobWorker[I];
  end;
  for Id := Low(TLayerId) to High(TLayerId) do
  begin
    Sum := 0;
    for I := 0 to High(FPainters) do
      Sum := Sum + FPainters[I].LayerMs[Id];
    LayerCpuMs[Id] := LayerCpuMs[Id] * 0.9 + Sum * 0.1;
  end;
  WallSmooth := WallSmooth * 0.9 + RenderWallMs * 0.1;
  CpuSmooth := CpuSmooth * 0.9 + RenderCpuMs * 0.1;
end;

procedure TFrameRenderer.Render;
begin
  Start;
  Wait;
end;

procedure TFrameRenderer.Assemble(Dest: TBGRABitmap);
var
  I: Integer;
begin
  Wait;
  Dest.SetSize(FWidth, FHeight);
  for I := 0 to High(FBands) do
    Dest.PutImage(0, FBandTop[I], FBands[I], dmSet);
end;

function TFrameRenderer.GetBand(I: Integer): TBGRABitmap;
begin
  Result := FBands[I];
end;

function TFrameRenderer.GetBandTop(I: Integer): Integer;
begin
  Result := FBandTop[I];
end;

function TFrameRenderer.GetBandCount: Integer;
begin
  Result := Length(FBands);
end;

function TFrameRenderer.GetThreads: Integer;
begin
  Result := FPool.ActiveThreads;
end;

end.
