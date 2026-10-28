unit uExportJob;

{ Export of the main picture and of every single layer as
    PNG       first frame (still), optionally every frame as a PNG sequence
    GIF       animated, endless loop (TBGRAAnimatedGif, colour quantised)
    MP4       H.264 through Windows Media Foundation (umfvideo.pas)

  The export renders with its own scene and its own frame renderer (all
  physical cores), so the size and frame rate are free and the window's scene is
  never touched. The export scene first copies the window's animation state,
  then every target (main or one layer) replays the same frames: each pass
  starts from that copy with the same random seed, so all files line up frame
  for frame.

  Layers are rendered alone on a transparent background with their paper
  shadow, so PNG and GIF keep the transparency and can be stacked again in an
  editor. MP4 has no alpha channel, so layer videos are flattened on white. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, BGRABitmap, BGRABitmapTypes, BGRAAnimatedGif,
  BGRAPalette, BGRAColorQuantization, uRenderPool, uVolcanoScene, uFrameRenderer, uMFVideo;

const
  TargetMain = -1;  // the full picture; 0..13 = Ord(TLayerId)

type
  TExportOptions = record
    Folder: string;
    Width, Height: Integer;
    Frames, Fps: Integer;
    Png, PngSequence, Gif, Mp4: Boolean;
    Mp4Kbps: Integer;
    Mp4Hardware: Boolean;
    Targets: array of Integer;  // TargetMain and/or Ord(TLayerId)
  end;

  { ADone of ATotal frames rendered; set ACancel to stop after this frame }
  TExportProgress = procedure(const AMessage: string; ADone, ATotal: Integer;
    var ACancel: Boolean) of object;

  TExportResult = record
    Files: TStringList;     // written files (caller frees)
    Errors: TStringList;    // problems, export goes on with the next file
    Ms: Double;
    FramesRendered: Integer;
    Cancelled: Boolean;
  end;

function DefaultExportOptions(AWidth, AHeight: Integer): TExportOptions;
function TargetName(ATarget: Integer): string;
function TargetFileStem(ATarget: Integer): string;
function RunExport(ALive: TVolcanoScene; const AOpt: TExportOptions;
  AProgress: TExportProgress): TExportResult;

implementation

function DefaultExportOptions(AWidth, AHeight: Integer): TExportOptions;
begin
  Result := Default(TExportOptions);
  Result.Folder := ExtractFilePath(ParamStr(0)) + 'export';
  Result.Width := AWidth;
  Result.Height := AHeight;
  Result.Frames := 120;
  Result.Fps := 30;
  Result.Png := True;
  Result.Gif := True;
  Result.Mp4 := True;
  Result.Mp4Kbps := 12000;
  Result.Mp4Hardware := True;
  Result.Targets := [TargetMain];
end;

function TargetName(ATarget: Integer): string;
begin
  if ATarget = TargetMain then
    Result := 'Main (all layers)'
  else
    Result := 'Layer: ' + LayerNames[TLayerId(ATarget)];
end;

function TargetFileStem(ATarget: Integer): string;
var
  S: string;
  I: Integer;
begin
  if ATarget = TargetMain then Exit('volcano_main');
  S := LowerCase(LayerNames[TLayerId(ATarget)]);
  for I := 1 to Length(S) do
    if not (S[I] in ['a'..'z', '0'..'9']) then S[I] := '_';
  while Pos('__', S) > 0 do
    S := StringReplace(S, '__', '_', [rfReplaceAll]);
  Result := Format('volcano_layer_%.2d_%s', [ATarget, S]);
end;

function RunExport(ALive: TVolcanoScene; const AOpt: TExportOptions;
  AProgress: TExportProgress): TExportResult;
var
  Scene: TVolcanoScene;
  R: TFrameRenderer;
  Frame, Flat: TBGRABitmap;
  Gif: TBGRAAnimatedGif;
  Mp4: TMp4Writer;
  T, F, Done, Total, W, H, MW, MH, Delay: Integer;
  Target: Integer;
  Id: TLayerId;
  Stem, SeqDir, Name: string;
  Cancel: Boolean;
  T0: Double;

  procedure Report(const S: string);
  begin
    if Assigned(AProgress) then AProgress(S, Done, Total, Cancel);
  end;

  procedure Fail(const S: string);
  begin
    Result.Errors.Add(S);
    Report('ERROR ' + S);
  end;

begin
  Result.Files := TStringList.Create;
  Result.Errors := TStringList.Create;
  Result.Cancelled := False;
  Result.FramesRendered := 0;
  T0 := HiResMs;
  W := Max(16, AOpt.Width);
  H := Max(16, AOpt.Height);
  MW := W and not 1;  // H.264 4:2:0 needs even sizes
  MH := H and not 1;
  Delay := Max(10, Round(1000 / Max(1, AOpt.Fps)));
  Total := Length(AOpt.Targets) * Max(1, AOpt.Frames);
  Done := 0;
  Cancel := False;
  ForceDirectories(AOpt.Folder);

  Scene := TVolcanoScene.Create;
  R := TFrameRenderer.Create(Scene, PhysicalCores, 1);
  Frame := TBGRABitmap.Create(W, H);
  Flat := TBGRABitmap.Create(MW, MH);
  try
    R.SetSize(W, H);
    for T := 0 to High(AOpt.Targets) do
    begin
      if Cancel then Break;
      Target := AOpt.Targets[T];
      Stem := TargetFileStem(Target);

      { same starting point and the same random numbers for every target }
      Scene.CopyStateFrom(ALive);
      RandSeed := 20261015;
      if Target = TargetMain then
      begin
        Scene.LayerOn := ALive.LayerOn;
        Scene.ShowCaption := ALive.ShowCaption;
        Scene.TransparentBack := False;
      end
      else
      begin
        for Id := Low(TLayerId) to High(TLayerId) do
          Scene.LayerOn[Id] := Ord(Id) = Target;
        Scene.ShowCaption := TLayerId(Target) = lyCaption;
        Scene.TransparentBack := True;
      end;

      Gif := nil;
      Mp4 := nil;
      SeqDir := '';
      try
        if AOpt.Gif then
        begin
          Gif := TBGRAAnimatedGif.Create;
          Gif.SetSize(W, H);
          Gif.LoopCount := 0;  // loop forever
        end;
        if AOpt.Mp4 then
        try
          Mp4 := TMp4Writer.Create(IncludeTrailingPathDelimiter(AOpt.Folder) + Stem + '.mp4',
            MW, MH, AOpt.Fps, AOpt.Mp4Kbps, AOpt.Mp4Hardware);
        except
          on E: Exception do
          begin
            Fail(Stem + '.mp4: ' + E.Message);
            Mp4 := nil;
          end;
        end;
        if AOpt.PngSequence then
        begin
          SeqDir := IncludeTrailingPathDelimiter(AOpt.Folder) + Stem;
          ForceDirectories(SeqDir);
        end;

        Report('rendering ' + TargetName(Target));
        for F := 0 to Max(1, AOpt.Frames) - 1 do
        begin
          if F > 0 then Scene.Update(1 / Max(1, AOpt.Fps));
          Scene.Prepare;
          R.Render;
          R.Assemble(Frame);
          Inc(Result.FramesRendered);

          if AOpt.Png and (F = 0) then
          begin
            Name := IncludeTrailingPathDelimiter(AOpt.Folder) + Stem + '.png';
            Frame.SaveToFile(Name);
            Result.Files.Add(Name);
          end;
          if SeqDir <> '' then
            Frame.SaveToFile(IncludeTrailingPathDelimiter(SeqDir) + Format('%s_%.4d.png', [Stem, F]));
          if Gif <> nil then
            Gif.AddFullFrame(Frame, Delay, True);
          if Mp4 <> nil then
          try
            // MP4 has no alpha: flatten layers on white, crop to even size
            Flat.Fill(BGRAWhite);
            Flat.PutImage(0, 0, Frame, dmDrawWithTransparency);
            Mp4.AddFrame(Flat);
          except
            on E: Exception do
            begin
              Fail(Stem + '.mp4 frame ' + IntToStr(F) + ': ' + E.Message);
              FreeAndNil(Mp4);
            end;
          end;
          Inc(Done);
          Report(Format('%s  frame %d / %d', [TargetName(Target), F + 1, AOpt.Frames]));
          if Cancel then Break;
        end;

        if SeqDir <> '' then
          Result.Files.Add(SeqDir + PathDelim + Format('(%d PNG files)', [AOpt.Frames]));
        if Gif <> nil then
        begin
          Report('writing ' + Stem + '.gif (colour quantisation)');
          Name := IncludeTrailingPathDelimiter(AOpt.Folder) + Stem + '.gif';
          try
            Gif.SaveToFile(Name);
            Result.Files.Add(Name);
          except
            on E: Exception do Fail(Stem + '.gif: ' + E.Message);
          end;
        end;
        if Mp4 <> nil then
        begin
          Name := IncludeTrailingPathDelimiter(AOpt.Folder) + Stem + '.mp4';
          try
            Mp4.Finish;
            Result.Files.Add(Name + IfThen(Mp4.Hardware, '  (GPU encoder)', '  (software encoder)'));
          except
            on E: Exception do Fail(Stem + '.mp4: ' + E.Message);
          end;
        end;
      finally
        Gif.Free;
        Mp4.Free;
      end;
    end;
  finally
    Flat.Free;
    Frame.Free;
    R.Free;
    Scene.Free;
  end;
  Result.Cancelled := Cancel;
  Result.Ms := HiResMs - T0;
end;

initialization
  if BGRAColorQuantizerFactory = nil then
    BGRAColorQuantizerFactory := TBGRAColorQuantizer;
end.
