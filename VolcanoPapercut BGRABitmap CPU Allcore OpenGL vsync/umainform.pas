unit uMainForm;

{ OpenGL window with a vsync'ed render loop (Application.OnIdle).

  Each pass of the loop:
    1. wait for the bands the workers rendered during the previous pass
    2. re-cut the static parts when the window size changed
    3. upload the finished bands into one texture (glTexSubImage2D per band)
    4. advance the animation and start the next frame on all cores
    5. draw the texture on a quad and SwapBuffers; with vsync on this blocks
       until the display refresh, while the workers are already rendering.
  So CPU rendering overlaps the vsync wait, and the main thread never draws. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, ExtCtrls, LCLType, LCLIntf,
  OpenGLContext, GL, BGRABitmap, BGRABitmapTypes, uRenderPool, uVolcanoScene, uFrameRenderer;

const
  HistLen = 300;  // frames kept in the timing history

type

  { TMainForm }

  TMainForm = class(TForm)
  private
    FGL: TOpenGLControl;
    FScene: TVolcanoScene;
    FRenderer: TFrameRenderer;
    FTex: GLuint;
    FTexW, FTexH: Integer;
    FGLReady, FHaveFrame, FFresh, FFlipV: Boolean;
    FPaused, FFullScreen, FDirty, FSaveRequested, FVSync: Boolean;
    FLastUpdate, FLastSwap: Double;
    FInfoOpened: Boolean;  // the info window opens by itself once, at startup
    FRefocus: Integer;     // idle passes left before the scene takes the focus back
    procedure AppIdle(Sender: TObject; var Done: Boolean);
    procedure GLPaint(Sender: TObject);
    procedure InitGL;
    procedure ApplyVSync;
    procedure UploadFrame;
    procedure DrawFrame;
    procedure KeyDownHandler(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure DoSave;
    procedure CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
    procedure SetPaused(AValue: Boolean);
  public
    { timing history, ring buffers indexed by HistPos (next slot to write) }
    IntervalHist: array[0..HistLen - 1] of Single;  // ms between two presents
    RenderHist: array[0..HistLen - 1] of Single;    // workers: kick -> last band
    CpuHist: array[0..HistLen - 1] of Single;       // workers: summed busy time
    WaitHist: array[0..HistLen - 1] of Single;      // main thread waiting for workers
    UploadHist: array[0..HistLen - 1] of Single;    // texture upload
    SwapHist: array[0..HistLen - 1] of Single;      // draw + SwapBuffers (vsync wait)
    HistPos: Integer;
    FrameCount, MissedFrames: Int64;
    Fps, RefreshHz: Double;
    LastWaitMs, LastUploadMs, LastSwapMs, LastUpdateMs, LastInterval: Double;
    GLVendor, GLRenderer, GLVersion: string;
    GLExtCount: Integer;
    VSyncSupported: Boolean;
    SwapIntervalNow: Integer;
    LastSaved: string;
    Exporting: Boolean;  // an export runs: the live loop stops, all cores go to it
    constructor Create(AOwner: TComponent); override;
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
    property Scene: TVolcanoScene read FScene;
    property Renderer: TFrameRenderer read FRenderer;
    property Paused: Boolean read FPaused write SetPaused;
    property VSync: Boolean read FVSync write SetVSync;
    property FullScreen: Boolean read FFullScreen;
    property TexW: Integer read FTexW;
    property TexH: Integer read FTexH;
  end;

var
  MainForm: TMainForm;

implementation

uses
  uInfoForm;

const
  GL_BGRA = $80E1;
  GL_CLAMP_TO_EDGE = $812F;
  VREFRESH = 116;

{$IFDEF WINDOWS}
type
  TwglSwapIntervalEXT = function(Interval: LongInt): LongBool; stdcall;
  TwglGetSwapIntervalEXT = function: LongInt; stdcall;

function wglGetProcAddress(Name: PChar): Pointer; stdcall; external 'opengl32.dll';
{$ENDIF}

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Volcano Papercut - BGRABitmap CPU all cores + OpenGL vsync';
  Position := poScreenCenter;
  ClientWidth := Scale96ToForm(450);
  ClientHeight := Scale96ToForm(800);
  KeyPreview := True;
  OnKeyDown := @KeyDownHandler;
  OnCloseQuery := @CloseQueryHandler;
  FVSync := True;
  RefreshHz := 60;

  FScene := TVolcanoScene.Create;
  FRenderer := TFrameRenderer.Create(FScene, PhysicalCores, 1);

  FGL := TOpenGLControl.Create(Self);
  FGL.Parent := Self;
  FGL.Align := alClient;
  FGL.AutoResizeViewport := False;
  FGL.DoubleBuffered := True;
  FGL.OnPaint := @GLPaint;

  FLastUpdate := HiResMs;
  FLastSwap := FLastUpdate;
  Application.OnIdle := @AppIdle;
end;

destructor TMainForm.Destroy;
begin
  Application.OnIdle := nil;
  FreeAndNil(InfoForm);
  FRenderer.Free;  // waits for the workers
  FScene.Free;
  inherited Destroy;
end;

{ ---------- OpenGL ---------- }

procedure TMainForm.InitGL;
var
  DC: HDC;
  P: PChar;
  S: string;
  I: Integer;
begin
  P := PChar(glGetString(GL_VENDOR));
  GLVendor := StrPas(P);
  GLRenderer := StrPas(PChar(glGetString(GL_RENDERER)));
  GLVersion := StrPas(PChar(glGetString(GL_VERSION)));
  S := StrPas(PChar(glGetString(GL_EXTENSIONS)));
  GLExtCount := 0;
  for I := 1 to Length(S) do
    if S[I] = ' ' then Inc(GLExtCount);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_BLEND);
  glDisable(GL_LIGHTING);
  if FTex <> 0 then glDeleteTextures(1, @FTex);
  glGenTextures(1, @FTex);
  glBindTexture(GL_TEXTURE_2D, FTex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  FTexW := 0;
  FTexH := 0;
  ApplyVSync;
  DC := GetDC(0);
  RefreshHz := GetDeviceCaps(DC, VREFRESH);
  ReleaseDC(0, DC);
  if RefreshHz <= 1 then RefreshHz := 60;
  FGLReady := True;
  FFresh := FHaveFrame;
end;

procedure TMainForm.ApplyVSync;
{$IFDEF WINDOWS}
var
  SetProc: TwglSwapIntervalEXT;
  GetProc: TwglGetSwapIntervalEXT;
begin
  SetProc := TwglSwapIntervalEXT(wglGetProcAddress('wglSwapIntervalEXT'));
  GetProc := TwglGetSwapIntervalEXT(wglGetProcAddress('wglGetSwapIntervalEXT'));
  VSyncSupported := Assigned(SetProc);
  if VSyncSupported then
    SetProc(Ord(FVSync));
  if Assigned(GetProc) then
    SwapIntervalNow := GetProc()
  else
    SwapIntervalNow := -1;
end;
{$ELSE}
begin
  VSyncSupported := False;
  SwapIntervalNow := -1;
end;
{$ENDIF}

{ Every band goes straight from its bitmap into the texture. BGRABitmap rows are
  bottom-up on Windows, which is exactly OpenGL's texture order. }
procedure TMainForm.UploadFrame;
var
  I, Y, W, H: Integer;
  B: TBGRABitmap;
begin
  W := FRenderer.Width;
  H := FRenderer.Height;
  glBindTexture(GL_TEXTURE_2D, FTex);
  if (FTexW <> W) or (FTexH <> H) then
  begin
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_BGRA, GL_UNSIGNED_BYTE, nil);
    FTexW := W;
    FTexH := H;
  end;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  for I := 0 to FRenderer.BandCount - 1 do
  begin
    B := FRenderer.Bands[I];
    if B.LineOrder = riloBottomToTop then
    begin
      Y := H - FRenderer.BandTops[I] - B.Height;
      FFlipV := False;
    end
    else
    begin
      Y := FRenderer.BandTops[I];
      FFlipV := True;
    end;
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, Y, B.Width, B.Height, GL_BGRA, GL_UNSIGNED_BYTE, B.Data);
  end;
end;

procedure TMainForm.DrawFrame;
var
  V0, V1: GLfloat;
begin
  glViewport(0, 0, FGL.ClientWidth, FGL.ClientHeight);
  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  glOrtho(0, 1, 0, 1, -1, 1);
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;
  if FTexW = 0 then
  begin
    glClearColor(0.95, 0.95, 0.94, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    Exit;
  end;
  if FFlipV then
  begin
    V0 := 1; V1 := 0;
  end
  else
  begin
    V0 := 0; V1 := 1;
  end;
  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, FTex);
  glBegin(GL_QUADS);
  glTexCoord2f(0, V0); glVertex2f(0, 0);
  glTexCoord2f(1, V0); glVertex2f(1, 0);
  glTexCoord2f(1, V1); glVertex2f(1, 1);
  glTexCoord2f(0, V1); glVertex2f(0, 1);
  glEnd;
end;

procedure TMainForm.GLPaint(Sender: TObject);
begin
  // window exposed: show the last frame; the idle loop does the real work
  if not FGLReady then Exit;
  DrawFrame;
  FGL.SwapBuffers;
end;

{ ---------- render loop ---------- }

procedure TMainForm.AppIdle(Sender: TObject; var Done: Boolean);
var
  T0, Now, DT, Interval: Double;
  W, H: Integer;
begin
  Done := False;
  if Exporting then
  begin
    Done := True;
    Exit;
  end;
  if Application.Terminated or not Visible or (WindowState = wsMinimized) or
    not FGL.HandleAllocated then
  begin
    Done := True;
    Exit;
  end;
  if not FGL.MakeCurrent then
  begin
    Done := True;
    Exit;
  end;
  if not FGLReady then InitGL;
  if FRefocus > 0 then
  begin
    // a few passes after the info window opened: give the keyboard back to the
    // scene so the hotkeys work at once
    Dec(FRefocus);
    if FRefocus = 0 then
    begin
      BringToFront;
      SetFocus;
    end;
  end;
  if not FInfoOpened then
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
  W := FGL.ClientWidth;
  H := FGL.ClientHeight;
  if (W > 0) and (H > 0) and ((W <> FRenderer.Width) or (H <> FRenderer.Height)) then
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

  // 5. present; with vsync on SwapBuffers waits here for the display
  T0 := HiResMs;
  DrawFrame;
  FGL.SwapBuffers;
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
  end;
  Inc(FrameCount);
  // nothing moves while paused: sleep until the next message
  if FPaused and not FDirty then Done := True;
end;

{ ---------- controls ---------- }

procedure TMainForm.KeyDownHandler(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_SPACE: Paused := not Paused;
    VK_V: VSync := not VSync;
    VK_F11: ToggleFullScreen;
    VK_S: RequestSave;
    VK_H: ToggleCaption;
    VK_I, VK_F1: ShowInfo;
    VK_E:
      begin
        ShowInfo;
        InfoForm.ShowExportTab;
      end;
    VK_ESCAPE:
      if FFullScreen then ToggleFullScreen else Close;
  end;
end;

procedure TMainForm.CloseQueryHandler(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := not Exporting;  // cancel the export first (Export tab)
end;

procedure TMainForm.SetPaused(AValue: Boolean);
begin
  FPaused := AValue;
  FLastUpdate := HiResMs;
  FDirty := True;
end;

procedure TMainForm.Redraw;
begin
  FDirty := True;
end;

procedure TMainForm.SetVSync(AValue: Boolean);
begin
  FVSync := AValue;
  if FGLReady and FGL.MakeCurrent then
    ApplyVSync;
end;

procedure TMainForm.SetThreads(N: Integer);
begin
  FRenderer.SetThreads(N);
  FHaveFrame := False;
  ResetStats;
end;

procedure TMainForm.SetBandsPerThread(N: Integer);
begin
  FRenderer.SetBandsPerThread(N);
  FHaveFrame := False;
  ResetStats;
end;

procedure TMainForm.SetAdaptive(AValue: Boolean);
begin
  FRenderer.Adaptive := AValue;
  if not AValue then
  begin
    FRenderer.ResetBands;
    FHaveFrame := False;
  end;
  ResetStats;
end;

procedure TMainForm.ResetStats;
begin
  FillChar(IntervalHist, SizeOf(IntervalHist), 0);
  FillChar(RenderHist, SizeOf(RenderHist), 0);
  FillChar(CpuHist, SizeOf(CpuHist), 0);
  FillChar(WaitHist, SizeOf(WaitHist), 0);
  FillChar(UploadHist, SizeOf(UploadHist), 0);
  FillChar(SwapHist, SizeOf(SwapHist), 0);
  MissedFrames := 0;
end;

procedure TMainForm.ToggleCaption;
begin
  FScene.ShowCaption := not FScene.ShowCaption;
  Redraw;
end;

procedure TMainForm.ToggleFullScreen;
begin
  FFullScreen := not FFullScreen;
  if FFullScreen then
    WindowState := wsFullScreen
  else
    WindowState := wsNormal;
end;

procedure TMainForm.RequestSave;
begin
  FSaveRequested := True;
end;

procedure TMainForm.DoSave;
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

{ Puts the info window next to the scene without covering it: to the right
  when there is room, else to the left, else both windows are moved so they
  sit side by side in the middle of the work area. }
procedure TMainForm.PlaceInfoBeside;
const
  Gap = 8;
var
  WA: TRect;
  Total, X: Integer;
begin
  if FFullScreen then Exit;
  WA := Screen.WorkAreaRect;
  if Left + Width + Gap + InfoForm.Width <= WA.Right then
    InfoForm.SetBounds(Left + Width + Gap, Top, InfoForm.Width, InfoForm.Height)
  else if Left - Gap - InfoForm.Width >= WA.Left then
    InfoForm.SetBounds(Left - Gap - InfoForm.Width, Top, InfoForm.Width, InfoForm.Height)
  else
  begin
    Total := Width + Gap + InfoForm.Width;
    X := Max(WA.Left, WA.Left + (WA.Right - WA.Left - Total) div 2);
    Left := X;
    InfoForm.SetBounds(X + Width + Gap, Top, InfoForm.Width,
      Min(InfoForm.Height, WA.Bottom - Top));
  end;
end;

procedure TMainForm.ShowInfo;
begin
  if InfoForm = nil then
    InfoForm := TInfoForm.Create(Application);
  if InfoForm.Visible then
    InfoForm.BringToFront
  else
  begin
    PlaceInfoBeside;
    InfoForm.Show;
  end;
end;

end.
