program VolcanoSDL3;

{ Volcano Papercut - SDL3 window + BGRABitmap on all CPU cores, vsync 60 Hz.
  uvolcanoscene.pas   scene state, static resources, band painter
  urenderpool.pas     worker thread pool (all threads created once)
  uframerenderer.pas  splits a frame into adaptive bands, renders them on the pool
  usdlview.pas        SDL3 window, streaming texture, vsync'ed render loop
  uinfoform.pas       developer information window (opens at startup)
  uexportjob.pas      PNG / GIF / MP4 export of the main picture and every layer
  umfvideo.pas        H.264 MP4 writer (Windows Media Foundation)

  The SDL window and the LCL info window share the main thread: the SDL frame is
  rendered from the LCL idle loop. Close the SDL window to quit. Needs SDL3.dll
  next to the program.

  Command line
    --bench=SECONDS                 frame pacing in the real window, writes
                                    VolcanoSDL3-bench.txt and quits
    --novsync                       start with vsync off (top speed; V toggles)
    --cpubench out.png [w h]        no window: render speed for 1..all threads
    --export folder [w h frames fps]  no window: main + every layer as PNG SVG GIF MP4 }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Classes, Forms, SysUtils, Math, BGRABitmap, uRenderPool, uVolcanoScene, uFrameRenderer,
  uMFVideo, uSvgRecorder, uExportJob, uSDLView, uInfoForm;

{$R *.res}

procedure Bench;
const
  Frames = 60;
var
  Scene: TVolcanoScene;
  R: TFrameRenderer;
  Out: TBGRABitmap;
  Log: TStringList;
  Counts: array of Integer;
  I, J, N: Integer;
  T0, Wall, Cpu, Base: Double;
  Layers: string;
  Id: TLayerId;
begin
  Scene := TVolcanoScene.Create;
  R := TFrameRenderer.Create(Scene, TThread.ProcessorCount, 1);
  Out := TBGRABitmap.Create(1, 1);
  Log := TStringList.Create;
  try
    T0 := HiResMs;
    R.SetSize(StrToIntDef(ParamStr(3), 450), StrToIntDef(ParamStr(4), 800));
    Log.Add(Format('size %d x %d, %d logical cores, %d physical cores', [R.Width, R.Height,
      TThread.ProcessorCount, PhysicalCores]));
    Log.Add(Format('static cut %.1f ms (main thread) + sprites %.1f ms (%d sprites, all cores)',
      [Scene.StaticMs, R.SpriteMs, Scene.SpriteCount]));
    for I := 1 to 300 do
      Scene.Update(1 / 60);
    Log.Add('');
    Log.Add('threads  bands  wall ms/frame  cpu ms/frame  speed-up  fps limit');
    Counts := [1, 2, 4, PhysicalCores, 8, TThread.ProcessorCount];
    Base := 0;
    for J := 0 to High(Counts) do
    begin
      N := Counts[J];
      if (J > 0) and (N <= Counts[J - 1]) then Continue;
      R.SetThreads(N);
      Scene.Prepare;
      for I := 1 to 100 do  // warm-up: layer buffers, adaptive band borders
      begin
        Scene.Update(1 / 60);
        Scene.Prepare;
        R.Render;
      end;
      Wall := 0;
      Cpu := 0;
      T0 := HiResMs;
      for I := 1 to Frames do
      begin
        Scene.Update(1 / 60);
        Scene.Prepare;
        R.Render;
        Cpu := Cpu + R.RenderCpuMs;
      end;
      Wall := (HiResMs - T0) / Frames;
      Cpu := Cpu / Frames;
      if Base = 0 then Base := Wall;
      Log.Add(Format('%7d  %5d  %13.2f  %12.2f  %8.2f  %9.0f',
        [N, R.BandCount, Wall, Cpu, Base / Wall, 1000 / Wall]));
      Layers := '        cpu per layer:';
      for Id := Low(TLayerId) to High(TLayerId) do
        Layers := Layers + Format(' %s %.1f', [Copy(LayerNames[Id], 1, 6), R.LayerCpuMs[Id]]);
      Log.Add(Layers);
      Log.SaveToFile(ChangeFileExt(ParamStr(2), '.txt'));
    end;
    // bands per thread at full thread count
    Log.Add('');
    Log.Add('bands/thread  bands  wall ms/frame  cpu ms/frame');
    R.SetThreads(PhysicalCores);
    for J := 1 to 4 do
    begin
      R.SetBandsPerThread(J);
      for I := 1 to 100 do
      begin
        Scene.Update(1 / 60);
        Scene.Prepare;
        R.Render;
      end;
      Cpu := 0;
      T0 := HiResMs;
      for I := 1 to Frames do
      begin
        Scene.Update(1 / 60);
        Scene.Prepare;
        R.Render;
        Cpu := Cpu + R.RenderCpuMs;
      end;
      Log.Add(Format('%12d  %5d  %13.2f  %12.2f', [J, R.BandCount, (HiResMs - T0) / Frames,
        Cpu / Frames]));
    end;
    R.SetBandsPerThread(1);
    Log.Add('');
    Log.Add('adaptive  wall ms/frame  cpu ms/frame');
    for J := 0 to 1 do
    begin
      R.Adaptive := J = 1;
      R.SetBandsPerThread(2);
      R.SetBandsPerThread(1);  // fresh equal bands
      for I := 1 to 100 do
      begin
        Scene.Update(1 / 60);
        Scene.Prepare;
        R.Render;
      end;
      Cpu := 0;
      T0 := HiResMs;
      for I := 1 to Frames do
      begin
        Scene.Update(1 / 60);
        Scene.Prepare;
        R.Render;
        Cpu := Cpu + R.RenderCpuMs;
      end;
      Log.Add(Format('%8s  %13.2f  %12.2f', [BoolToStr(R.Adaptive, 'on', 'off'),
        (HiResMs - T0) / Frames, Cpu / Frames]));
    end;
    Scene.Prepare;
    R.Render;  // the band rebuild above left empty bands
    Log.Add('');
    Log.Add(Format('job exceptions: %d', [R.Pool.ErrorCount]));
    Log.Add(R.Pool.ErrorReport);
    R.Assemble(Out);
    Out.SaveToFile(ParamStr(2));
    Log.SaveToFile(ChangeFileExt(ParamStr(2), '.txt'));
  finally
    Log.Free;
    Out.Free;
    R.Free;
    Scene.Free;
  end;
end;

procedure ExportAll;
var
  Live: TVolcanoScene;
  Opt: TExportOptions;
  Res: TExportResult;
  Log: TStringList;
  I: Integer;
  Id: TLayerId;
begin
  Live := TVolcanoScene.Create;
  Log := TStringList.Create;
  try
    for I := 1 to 300 do
      Live.Update(1 / 60);  // a few seconds into the eruption
    Opt := DefaultExportOptions(StrToIntDef(ParamStr(3), 450), StrToIntDef(ParamStr(4), 800));
    Opt.Folder := ExpandFileName(ParamStr(2));
    Opt.Frames := StrToIntDef(ParamStr(5), 60);
    Opt.Fps := StrToIntDef(ParamStr(6), 30);
    Opt.Targets := [TargetMain];
    for Id := Low(TLayerId) to High(TLayerId) do
      Opt.Targets := Concat(Opt.Targets, [Ord(Id)]);
    Res := RunExport(Live, Opt, nil);
    Log.Add(Format('%d x %d, %d frames at %d fps, %d targets, %d frames rendered in %.1f s',
      [Opt.Width, Opt.Height, Opt.Frames, Opt.Fps, Length(Opt.Targets), Res.FramesRendered,
      Res.Ms / 1000]));
    Log.Add('');
    Log.AddStrings(Res.Files);
    Log.Add('');
    Log.Add(Format('errors: %d', [Res.Errors.Count]));
    Log.AddStrings(Res.Errors);
    Log.SaveToFile(IncludeTrailingPathDelimiter(Opt.Folder) + 'export.txt');
    Res.Files.Free;
    Res.Errors.Free;
  finally
    Log.Free;
    Live.Free;
  end;
end;

begin
  if (ParamCount >= 2) and (ParamStr(1) = '--export') then
  begin
    ExportAll;
    Exit;
  end;
  if (ParamCount >= 2) and (ParamStr(1) = '--cpubench') then
  begin
    Bench;
    Exit;
  end;
  RequireDerivedFormResource := False;  // forms are built in code
  Application.Scaled := True;
  Application.Title := 'Volcano Papercut SDL3';
  Application.Initialize;
  try
    View := TSDLView.Create;
  except
    on E: Exception do
    begin
      Application.MessageBox(PChar(E.Message), 'Volcano Papercut SDL3', 0);
      Exit;
    end;
  end;
  // the info window is shown by the render loop, placed beside the SDL window
  Application.ShowMainForm := False;
  Application.CreateForm(TInfoForm, InfoForm);
  Application.Run;
  FreeAndNil(View);
end.
