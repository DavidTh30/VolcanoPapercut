program VolcanoPapercut;

{ Volcano Papercut - animated paper-cut UI background drawn with BGRABitmap.
  The scene (static paper layers + animated birds/embers/ash) is in uvolcanoscene.pas,
  the window is in umainform.pas. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, SysUtils, BGRABitmap, uVolcanoScene, uMainForm, uInfoForm;

{$R *.res}

{ VolcanoPapercut --snapshot out.png [width height]
  renders one frame off-screen and exits (no window). }
procedure Snapshot;
var
  Scene: TVolcanoScene;
  Frame: TBGRABitmap;
  I: Integer;
  T0: QWord;
  Log: TextFile;
begin
  Scene := TVolcanoScene.Create;
  Frame := TBGRABitmap.Create(StrToIntDef(ParamStr(3), DesignW),
    StrToIntDef(ParamStr(4), DesignH));
  try
    for I := 1 to StrToIntDef(ParamStr(5), 90) do
      Scene.Update(1 / 30);
    Scene.Render(Frame);
    Frame.SaveToFile(ParamStr(2));
    // frame time, written next to the image
    T0 := GetTickCount64;
    for I := 1 to 30 do
    begin
      Scene.Update(1 / 30);
      Scene.Render(Frame);
    end;
    AssignFile(Log, ChangeFileExt(ParamStr(2), '.txt'));
    Rewrite(Log);
    WriteLn(Log, Format('%dx%d  %.1f ms/frame', [Frame.Width, Frame.Height,
      (GetTickCount64 - T0) / 30]));
    CloseFile(Log);
  finally
    Frame.Free;
    Scene.Free;
  end;
end;

begin
  if (ParamCount >= 2) and (ParamStr(1) = '--snapshot') then
  begin
    Snapshot;
    Exit;
  end;

  RequireDerivedFormResource := False;
  Application.Scaled := True;
  Application.Title := 'Volcano Papercut';
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
