unit uSDLView;

{ SDL3 window with a vsync'ed render loop, driven from the LCL idle loop so the
  SDL window and the LCL info window share one main thread.

  Each pass of the loop:
    1. poll SDL events (keys, close, resize)
    2. wait for the bands the workers rendered during the previous pass
    3. re-cut the static parts when the window size changed
    4. upload the finished bands into one streaming texture
       (SDL_UpdateTexture per band, SDL_PIXELFORMAT_ARGB8888 = TBGRAPixel bytes)
    5. advance the animation and start the next frame on all physical cores
    6. draw the texture and SDL_RenderPresent; with vsync on this blocks until
       the display refresh while the workers are already rendering.
  So the CPU rendering hides behind the vsync wait and the main thread never
  draws pixels itself. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, Forms, Controls, SDL3, BGRABitmap, BGRABitmapTypes,
  uRenderPool, uVolcanoScene, uFrameRenderer;

const
  HistLen = 300;  // frames kept in the timing history

type

  { TSDLView }

  TSDLView = class
  private
    FWin: PSDL_Window;
    FRen: PSDL_Renderer;
    FTex: PSDL_Texture;
    FTexW, FTexH: Integer;
    FFlipV: Boolean;
    FScene: TVolcanoScene;
    FRenderer: TFrameRenderer;
    FRunning, FHaveFrame, FFresh: Boolean;
    FPaused, FFullScreen, FDirty, FSaveRequested, FVSync: Boolean;
    FLastUpdate, FLastSwap: Double;
    FInfoOpened: Boolean;  // the info window opens by itself once, at startup
    FRefocus: Integer;     // passes left before the SDL window takes the keyboard back
    FBenchSecs, FBenchT0: Double;  // --bench=SECONDS: frame pacing report, then quit
    FBench: array of Single;
    procedure AppIdle(Sender: TObject; var Done: Boolean);
    procedure PollEvents;
    procedure HandleKey(AKey: TSDL_Keycode);
    procedure ApplyVSync;
    procedure UpdateRefreshRate;
    procedure UploadFrame;
    procedure Present;
    procedure DoSave;
    procedure SetPaused(AValue: Boolean);
    procedure BenchFrame(ANow, AInterval: Double);
    procedure WriteBenchReport;
  public
    { timing history, ring buffers indexed by HistPos (next slot to write) }
    IntervalHist: array[0..HistLen - 1] of Single;  // ms between two presents
    RenderHist: array[0..HistLen - 1] of Single;    // workers: kick -> last band
    CpuHist: array[0..HistLen - 1] of Single;       // workers: summed busy time
    WaitHist: array[0..HistLen - 1] of Single;      // main thread waiting for workers
    UploadHist: array[0..HistLen - 1] of Single;    // texture upload
    SwapHist: array[0..HistLen - 1] of Single;      // draw + present (vsync wait)
    HistPos: Integer;
    FrameCount, MissedFrames: Int64;
    Fps, RefreshHz: Double;
    LastWaitMs, LastUploadMs, LastSwapMs, LastUpdateMs, LastInterval: Double;
    GLVendor, GLRenderer, GLVersion: string;  // SDL version, render backend, method
    GLExtCount: Integer;                      // render drivers available
    VSyncSupported: Boolean;
    SwapIntervalNow: Integer;
    LastSaved: string;
    Exporting: Boolean;  // an export runs: the live loop stops, all cores go to it
    constructor Create;
    destructor Destroy; override;
    procedure ToggleFullScreen;
    procedure ToggleCaption;
    procedure ShowInfo;
    procedure PlaceInfoBeside;
    procedure RequestSave;
    procedure Redraw;  // re-render even when paused (layer switches etc.)
    procedure SetVSync(AValue: Boolean);
    procedure SetThreads(N: Integer);
    procedure SetBandsPerThread(N: Integer);
    procedure SetAdaptive(AValue: Boolean);
    procedure ResetStats;
    function Left: Integer;
    function Top: Integer;
    function Width: Integer;
    function Height: Integer;
    property Scene: TVolcanoScene read FScene;
    property Renderer: TFrameRenderer read FRenderer;
    property Paused: Boolean read FPaused write SetPaused;
    property VSync: Boolean read FVSync write SetVSync;
    property FullScreen: Boolean read FFullScreen;
    property TexW: Integer read FTexW;
    property TexH: Integer read FTexH;
  end;

var
  View: TSDLView;

implementation

uses
  uInfoForm;

function SDLErr: string;
begin
  Result := StrPas(SDL_GetError);
end;

constructor TSDLView.Create;
var
  R: TSDL_Rect;
  Ver, I: Integer;
begin
  inherited Create;
  if not SDL_Init(SDL_INIT_VIDEO) then
    raise Exception.Create('SDL_Init failed: ' + SDLErr);
  FWin := SDL_CreateWindow('Volcano Papercut - SDL3 + BGRABitmap all cores',
    450, 800, SDL_WINDOW_RESIZABLE or SDL_WINDOW_HIGH_PIXEL_DENSITY);
  if FWin = nil then raise Exception.Create('SDL_CreateWindow failed: ' + SDLErr);
  if SDL_GetDisplayUsableBounds(SDL_GetPrimaryDisplay, @R) then
    SDL_SetWindowPosition(FWin, R.x + 40, R.y + 40);
  FRen := SDL_CreateRenderer(FWin, nil);
  if FRen = nil then raise Exception.Create('SDL_CreateRenderer failed: ' + SDLErr);

  Ver := SDL_GetVersion;
  GLVendor := Format('SDL %d.%d.%d', [Ver div 1000000, (Ver div 1000) mod 1000, Ver mod 1000]);
  GLRenderer := StrPas(SDL_GetRendererName(FRen));
  GLVersion := 'SDL_Renderer, streaming texture, SDL_RenderPresent';
  GLExtCount := SDL_GetNumRenderDrivers;
  for I := 0 to GLExtCount - 1 do
    GLVersion := GLVersion + IfThen(I = 0, '  (drivers: ', ', ') + StrPas(SDL_GetRenderDriver(I));
  if GLExtCount > 0 then GLVersion := GLVersion + ')';
  VSyncSupported := True;
  FVSync := True;
  RefreshHz := 60;
  ApplyVSync;
  UpdateRefreshRate;

  FScene := TVolcanoScene.Create;
  FRenderer := TFrameRenderer.Create(FScene, PhysicalCores, 1);
  FRunning := True;
  FLastUpdate := HiResMs;
  FLastSwap := FLastUpdate;
  for I := 1 to ParamCount do
  begin
    if Pos('--bench=', ParamStr(I)) = 1 then
      FBenchSecs := StrToFloatDef(Copy(ParamStr(I), 9, 20), 10);
    if ParamStr(I) = '--novsync' then
      SetVSync(False);  // measure the top speed
  end;
  Application.AddOnIdleHandler(@AppIdle);
end;

destructor TSDLView.Destroy;
begin
  Application.RemoveOnIdleHandler(@AppIdle);
  FreeAndNil(FRenderer);  // waits for the workers
  FreeAndNil(FScene);
  if FTex <> nil then SDL_DestroyTexture(FTex);
  if FRen <> nil then SDL_DestroyRenderer(FRen);
  if FWin <> nil then SDL_DestroyWindow(FWin);
  SDL_Quit;
  inherited Destroy;
end;

{ ---------- SDL ---------- }

procedure TSDLView.ApplyVSync;
var
  V: LongInt;
begin
  SDL_SetRenderVSync(FRen, Ord(FVSync));
  V := 0;
  SDL_GetRenderVSync(FRen, @V);
  SwapIntervalNow := V;
end;

procedure TSDLView.UpdateRefreshRate;
var
  Mode: PSDL_DisplayMode;
begin
  Mode := SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(FWin));
  if (Mode <> nil) and (Mode^.refresh_rate > 1) then
    RefreshHz := Mode^.refresh_rate;
end;

procedure TSDLView.HandleKey(AKey: TSDL_Keycode);
begin
  case AKey of
    SDLK_SPACE: Paused := not Paused;
    SDLK_V: VSync := not VSync;
    SDLK_F11: ToggleFullScreen;
    SDLK_S: RequestSave;
    SDLK_H: ToggleCaption;
    SDLK_I, SDLK_F1: ShowInfo;
    SDLK_E:
      begin
        ShowInfo;
        InfoForm.ShowExportTab;
      end;
    SDLK_ESCAPE:
      if FFullScreen then ToggleFullScreen;
  end;
end;

procedure TSDLView.PollEvents;
var
  E: TSDL_Event;
begin
  while SDL_PollEvent(@E) do
    case E._type of
      SDL_EVENT_QUIT, SDL_EVENT_WINDOW_CLOSE_REQUESTED:
        if not Exporting then
        begin
          FRunning := False;
          Application.Terminate;
        end;
      SDL_EVENT_KEY_DOWN:
        if not E.key._repeat then HandleKey(E.key.key);
      SDL_EVENT_WINDOW_DISPLAY_CHANGED:
        UpdateRefreshRate;
    end;
end;

{ Every band goes straight from its bitmap into the texture. BGRABitmap rows are
  bottom-up on Windows: the bands are uploaded as they are into a texture that
  is drawn vertically flipped. }
procedure TSDLView.UploadFrame;
var
  I, W, H: Integer;
  B: TBGRABitmap;
  Rc: TSDL_Rect;
  Fmt: TSDL_PixelFormat;
begin
  W := FRenderer.Width;
  H := FRenderer.Height;
  if (FTex = nil) or (FTexW <> W) or (FTexH <> H) then
  begin
    if FTex <> nil then SDL_DestroyTexture(FTex);
    if TBGRAPixel_RGBAOrder then Fmt := SDL_PIXELFORMAT_ABGR8888 else Fmt := SDL_PIXELFORMAT_ARGB8888;
    FTex := SDL_CreateTexture(FRen, Fmt, SDL_TEXTUREACCESS_STREAMING, W, H);
    if FTex = nil then Exit;
    SDL_SetTextureScaleMode(FTex, SDL_SCALEMODE_NEAREST);
    SDL_SetTextureBlendMode(FTex, SDL_BLENDMODE_NONE);
    FTexW := W;
    FTexH := H;
  end;
  for I := 0 to FRenderer.BandCount - 1 do
  begin
    B := FRenderer.Bands[I];
    FFlipV := B.LineOrder = riloBottomToTop;
    Rc.x := 0;
    Rc.w := W;
    Rc.h := B.Height;
    if FFlipV then
      Rc.y := H - FRenderer.BandTops[I] - B.Height
    else
      Rc.y := FRenderer.BandTops[I];
    SDL_UpdateTexture(FTex, @Rc, B.Data, W * SizeOf(TBGRAPixel));
  end;
end;

procedure TSDLView.Present;
var
  W, H: LongInt;
  Dst: TSDL_FRect;
begin
  if FTex = nil then
  begin
    SDL_SetRenderDrawColor(FRen, 244, 244, 242, 255);
    SDL_RenderClear(FRen);
  end
  else
  begin
    W := 0;
    H := 0;
    SDL_GetCurrentRenderOutputSize(FRen, @W, @H);
    Dst.x := 0;
    Dst.y := 0;
    Dst.w := W;
    Dst.h := H;
    if FFlipV then
      SDL_RenderTextureRotated(FRen, FTex, nil, @Dst, 0, nil, SDL_FLIP_VERTICAL)
    else
      SDL_RenderTexture(FRen, FTex, nil, @Dst);
  end;
  SDL_RenderPresent(FRen);
end;

{ ---------- render loop ---------- }

procedure TSDLView.AppIdle(Sender: TObject; var Done: Boolean);
var
  T0, Now, DT, Interval: Double;
  W, H: LongInt;
begin
  Done := False;
  if not FRunning or Exporting then
  begin
    Done := True;
    Exit;
  end;
  PollEvents;
  if not FRunning then Exit;
  if (SDL_GetWindowFlags(FWin) and SDL_WINDOW_MINIMIZED) <> 0 then
  begin
    Sleep(15);
    Exit;
  end;

  if FRefocus > 0 then
  begin
    // a few passes after the info window opened: give the keyboard back to SDL
    Dec(FRefocus);
    if FRefocus = 0 then SDL_RaiseWindow(FWin);
  end;
  if not FInfoOpened and (InfoForm <> nil) then
  begin
    // open the developer info window right away, beside the scene
    FInfoOpened := True;
    ShowInfo;
    FRefocus := 5;
  end;

  // 1. collect the frame the workers rendered during the last vsync wait
  if FRenderer.Rendering then
  begin
    T0 := HiResMs;
    FRenderer.Wait;
    LastWaitMs := HiResMs - T0;
    FHaveFrame := True;
    FFresh := True;
  end
  else
    LastWaitMs := 0;

  // 2. size change: re-cut the static parts and sprites (sprites on all cores)
  W := 0;
  H := 0;
  SDL_GetWindowSizeInPixels(FWin, @W, @H);
  if (W >= 16) and (H >= 16) and ((W <> FRenderer.Width) or (H <> FRenderer.Height)) then
  begin
    FRenderer.SetSize(W, H);
    FHaveFrame := False;
  end;
  if not FHaveFrame then
  begin
    FScene.Prepare;
    FRenderer.Render;
    FHaveFrame := True;
    FFresh := True;
  end;
  if FSaveRequested then DoSave;

  // 3. hand the finished frame to the GPU
  T0 := HiResMs;
  if FFresh then UploadFrame;
  FFresh := False;
  LastUploadMs := HiResMs - T0;

  // 4. advance the animation and start the next frame on all cores
  Now := HiResMs;
  DT := (Now - FLastUpdate) / 1000;
  FLastUpdate := Now;
  if DT > 0.1 then DT := 0.1;
  if (not FPaused) or FDirty then
  begin
    T0 := HiResMs;
    if not FPaused then FScene.Update(DT);
    FScene.Prepare;
    LastUpdateMs := HiResMs - T0;
    FRenderer.Start;
    FDirty := False;
  end;

  // 5. present; with vsync on this waits here for the display
  T0 := HiResMs;
  Present;
  LastSwapMs := HiResMs - T0;

  Now := HiResMs;
  Interval := Now - FLastSwap;
  FLastSwap := Now;
  LastInterval := Interval;
  if FrameCount > 0 then
  begin
    IntervalHist[HistPos] := Interval;
    RenderHist[HistPos] := FRenderer.RenderWallMs;
    CpuHist[HistPos] := FRenderer.RenderCpuMs;
    WaitHist[HistPos] := LastWaitMs;
    UploadHist[HistPos] := LastUploadMs;
    SwapHist[HistPos] := LastSwapMs;
    HistPos := (HistPos + 1) mod HistLen;
    if Interval > 0 then
      Fps := Fps * 0.95 + (1000 / Interval) * 0.05;
    if FVSync and not FPaused and (Interval > 1.5 * 1000 / RefreshHz) then
      Inc(MissedFrames);
    if FBenchSecs > 0 then BenchFrame(Now, Interval);
  end;
  Inc(FrameCount);
  // nothing moves while paused: sleep until the next message
  if FPaused and not FDirty then
  begin
    Sleep(10);
    Done := True;
  end;
end;

{ ---------- --bench=SECONDS ---------- }

procedure TSDLView.BenchFrame(ANow, AInterval: Double);
begin
  if FBenchT0 = 0 then FBenchT0 := ANow + 2000;  // 2 s warm-up
  if ANow < FBenchT0 then Exit;
  SetLength(FBench, Length(FBench) + 1);
  FBench[High(FBench)] := AInterval;
  if ANow - FBenchT0 >= FBenchSecs * 1000 then
  begin
    WriteBenchReport;
    FRunning := False;
    Application.Terminate;
  end;
end;

procedure TSDLView.WriteBenchReport;
var
  SL: TStringList;
  Sorted: array of Single;
  I, J, N, Missed: Integer;
  Sum, Budget: Double;
  T: Single;
begin
  N := Length(FBench);
  if N = 0 then Exit;
  Sorted := Copy(FBench);
  for I := 1 to N - 1 do
  begin
    T := Sorted[I];
    J := I - 1;
    while (J >= 0) and (Sorted[J] > T) do
    begin
      Sorted[J + 1] := Sorted[J];
      Dec(J);
    end;
    Sorted[J + 1] := T;
  end;
  Sum := 0;
  for I := 0 to N - 1 do Sum := Sum + FBench[I];
  Budget := 1000 / Max(1, RefreshHz);
  Missed := 0;
  for I := 0 to N - 1 do
    if FBench[I] > Budget * 1.5 then Inc(Missed);
  SL := TStringList.Create;
  try
    SL.Add('Volcano Papercut SDL3 frame pacing  ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', SysUtils.Now));
    SL.Add(Format('%s, backend %s, vsync %s, display %s Hz', [GLVendor, GLRenderer,
      IfThen(FVSync, 'on', 'off'), FormatFloat('0', RefreshHz)]));
    SL.Add(Format('frame %d x %d, %d threads (%d physical / %d logical cores), %d bands',
      [FRenderer.Width, FRenderer.Height, FRenderer.Threads, PhysicalCores,
      TThread.ProcessorCount, FRenderer.BandCount]));
    SL.Add(Format('presents %d in %.1f s  ->  %.2f fps', [N, Sum / 1000, N * 1000 / Sum]));
    SL.Add(Format('interval ms: mean %.2f  median %.2f  p99 %.2f  max %.2f', [Sum / N,
      Sorted[N div 2], Sorted[Min(N - 1, Round(N * 0.99))], Sorted[N - 1]]));
    if FVSync then
      SL.Add(Format('missed vblank (interval > 1.5 x %.2f ms): %d (%.2f %%)',
        [Budget, Missed, Missed * 100 / N]))
    else
      SL.Add('vsync off: frames are presented as fast as the pipeline allows');
    SL.Add(Format('render wall %.2f ms, cpu %.2f ms (smoothed); upload %.2f ms, present %.2f ms',
      [FRenderer.WallSmooth, FRenderer.CpuSmooth, LastUploadMs, LastSwapMs]));
    SL.Add(Format('info window visible: %s', [IfThen((InfoForm <> nil) and InfoForm.Visible, 'yes', 'no')]));
    SL.SaveToFile(ChangeFileExt(ParamStr(0), '-bench.txt'));
  finally
    SL.Free;
  end;
end;

{ ---------- controls ---------- }

procedure TSDLView.SetPaused(AValue: Boolean);
begin
  FPaused := AValue;
  FLastUpdate := HiResMs;
  FDirty := True;
end;

procedure TSDLView.Redraw;
begin
  FDirty := True;
end;

procedure TSDLView.SetVSync(AValue: Boolean);
begin
  FVSync := AValue;
  ApplyVSync;
end;

procedure TSDLView.SetThreads(N: Integer);
begin
  FRenderer.SetThreads(N);
  FHaveFrame := False;
  ResetStats;
end;

procedure TSDLView.SetBandsPerThread(N: Integer);
begin
  FRenderer.SetBandsPerThread(N);
  FHaveFrame := False;
  ResetStats;
end;

procedure TSDLView.SetAdaptive(AValue: Boolean);
begin
  FRenderer.Adaptive := AValue;
  if not AValue then
  begin
    FRenderer.ResetBands;
    FHaveFrame := False;
  end;
  ResetStats;
end;

procedure TSDLView.ResetStats;
begin
  FillChar(IntervalHist, SizeOf(IntervalHist), 0);
  FillChar(RenderHist, SizeOf(RenderHist), 0);
  FillChar(CpuHist, SizeOf(CpuHist), 0);
  FillChar(WaitHist, SizeOf(WaitHist), 0);
  FillChar(UploadHist, SizeOf(UploadHist), 0);
  FillChar(SwapHist, SizeOf(SwapHist), 0);
  MissedFrames := 0;
end;

procedure TSDLView.ToggleCaption;
begin
  FScene.ShowCaption := not FScene.ShowCaption;
  Redraw;
end;

procedure TSDLView.ToggleFullScreen;
begin
  FFullScreen := not FFullScreen;
  SDL_SetWindowFullscreen(FWin, FFullScreen);  // borderless desktop full screen
  if InfoForm <> nil then
    if FFullScreen then InfoForm.FormStyle := fsStayOnTop else InfoForm.FormStyle := fsNormal;
end;

procedure TSDLView.RequestSave;
begin
  FSaveRequested := True;
end;

procedure TSDLView.DoSave;
var
  B: TBGRABitmap;
  FileName: string;
begin
  FSaveRequested := False;
  B := TBGRABitmap.Create(1, 1);
  try
    FRenderer.Assemble(B);
    FileName := ExtractFilePath(ParamStr(0)) + 'volcano_' +
      FormatDateTime('yyyymmdd_hhnnss', SysUtils.Now) + '.png';
    B.SaveToFile(FileName);
    LastSaved := FileName;
  finally
    B.Free;
  end;
end;

{ Puts the info window next to the SDL window without covering it: to the right
  when there is room, else to the left, else both windows are moved so they sit
  side by side in the middle of the work area. }
procedure TSDLView.PlaceInfoBeside;
const
  Gap = 16;
var
  WA: TRect;
  Total, X, L, T, W: Integer;
begin
  if FFullScreen or (InfoForm = nil) then Exit;
  WA := Screen.WorkAreaRect;
  L := Left;
  T := Top;
  W := Width;
  if L + W + Gap + InfoForm.Width <= WA.Right then
    InfoForm.SetBounds(L + W + Gap, T - 30, InfoForm.Width, InfoForm.Height)
  else if L - Gap - InfoForm.Width >= WA.Left then
    InfoForm.SetBounds(L - Gap - InfoForm.Width, T - 30, InfoForm.Width, InfoForm.Height)
  else
  begin
    Total := W + Gap + InfoForm.Width;
    X := Max(WA.Left, WA.Left + (WA.Right - WA.Left - Total) div 2);
    SDL_SetWindowPosition(FWin, X, T);
    InfoForm.SetBounds(X + W + Gap, T - 30, InfoForm.Width, Min(InfoForm.Height, WA.Bottom - T));
  end;
end;

procedure TSDLView.ShowInfo;
begin
  if InfoForm = nil then Exit;
  if not InfoForm.Visible then
  begin
    PlaceInfoBeside;
    InfoForm.Show;
  end;
  InfoForm.BringToFront;
end;

function TSDLView.Left: Integer;
var
  X, Y: LongInt;
begin
  SDL_GetWindowPosition(FWin, @X, @Y);
  Result := X;
end;

function TSDLView.Top: Integer;
var
  X, Y: LongInt;
begin
  SDL_GetWindowPosition(FWin, @X, @Y);
  Result := Y;
end;

function TSDLView.Width: Integer;
var
  W, H: LongInt;
begin
  SDL_GetWindowSize(FWin, @W, @H);
  Result := W;
end;

function TSDLView.Height: Integer;
var
  W, H: LongInt;
begin
  SDL_GetWindowSize(FWin, @W, @H);
  Result := H;
end;

end.
