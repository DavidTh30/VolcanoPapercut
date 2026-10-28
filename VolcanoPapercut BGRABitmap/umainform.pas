unit uMainForm;

{ Window hosting the volcano scene. The form is built in code (no .lfm):
  a timer advances the animation and the whole frame is painted from one
  TBGRABitmap. Frame statistics are kept here for the info window (I / F1). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, ExtCtrls, LCLType,
  BGRABitmap, BGRABitmapTypes, uVolcanoScene;

const
  HistLen = 240;  // frames kept in the timing history

type

  { TMainForm }

  TMainForm = class(TForm)
  private
    FScene: TVolcanoScene;
    FFrame: TBGRABitmap;
    FTimer: TTimer;
    FLastTick: QWord;
    FLastPaint: Double;
    FPaused: Boolean;
    FFullScreen: Boolean;
    FSavedBounds: TRect;
    FInfoOpened: Boolean;  // the info window opens by itself once, at startup
    procedure TimerTick(Sender: TObject);
    procedure PaintHandler(Sender: TObject);
    procedure KeyDownHandler(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure SetPaused(AValue: Boolean);
  protected
    procedure EraseBackground(DC: HDC); override;
  public
    { timing history, ring buffers indexed by HistPos (next slot to write) }
    IntervalHist: array[0..HistLen - 1] of Single;  // ms between two paints
    PaintHist: array[0..HistLen - 1] of Single;     // ms spent in one paint
    HistPos: Integer;
    FrameCount: Int64;
    Fps: Double;
    LastSaved: string;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ToggleFullScreen;
    procedure ToggleCaption;
    procedure SaveFrame;
    procedure ShowInfo;
    procedure PlaceInfoBeside;
    property Scene: TVolcanoScene read FScene;
    property Frame: TBGRABitmap read FFrame;
    property Paused: Boolean read FPaused write SetPaused;
    property FullScreen: Boolean read FFullScreen;
  end;

var
  MainForm: TMainForm;

implementation

uses
  uInfoForm;

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Volcano Papercut - BGRABitmap';
  Position := poScreenCenter;
  ClientWidth := Scale96ToForm(450);
  ClientHeight := Scale96ToForm(800);
  Color := clWhite;
  DoubleBuffered := True;
  KeyPreview := True;
  OnPaint := @PaintHandler;
  OnKeyDown := @KeyDownHandler;

  FScene := TVolcanoScene.Create;
  FFrame := TBGRABitmap.Create(1, 1);

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 16;
  FTimer.OnTimer := @TimerTick;
  FLastTick := GetTickCount64;
end;

destructor TMainForm.Destroy;
begin
  FTimer.Enabled := False;
  FreeAndNil(InfoForm);
  FFrame.Free;
  FScene.Free;
  inherited Destroy;
end;

procedure TMainForm.EraseBackground(DC: HDC);
begin
  // the frame covers the whole client area; skipping the erase avoids flicker
end;

procedure TMainForm.TimerTick(Sender: TObject);
var
  Now64: QWord;
  DT: Single;
begin
  if not FInfoOpened and Showing then
  begin
    // open the developer info window right away, beside the scene, and give
    // the keyboard back to the scene so the hotkeys work at once
    FInfoOpened := True;
    ShowInfo;
    Self.SetFocus;
  end;
  Now64 := GetTickCount64;
  DT := (Now64 - FLastTick) / 1000;
  FLastTick := Now64;
  if DT > 0.1 then DT := 0.1;
  if not FPaused then
  begin
    FScene.Update(DT);
    Invalidate;
  end;
end;

procedure TMainForm.PaintHandler(Sender: TObject);
var
  T0, Interval: Double;
begin
  if (ClientWidth < 1) or (ClientHeight < 1) then Exit;
  T0 := HiResMs;
  if (FFrame.Width <> ClientWidth) or (FFrame.Height <> ClientHeight) then
    FFrame.SetSize(ClientWidth, ClientHeight);
  FScene.Render(FFrame);
  FFrame.Draw(Canvas, 0, 0, True);

  if FLastPaint > 0 then
    Interval := T0 - FLastPaint
  else
    Interval := 0;
  FLastPaint := T0;
  IntervalHist[HistPos] := Interval;
  PaintHist[HistPos] := HiResMs - T0;
  HistPos := (HistPos + 1) mod HistLen;
  Inc(FrameCount);
  if Interval > 0 then
    Fps := Fps * 0.9 + (1000 / Interval) * 0.1;
end;

procedure TMainForm.KeyDownHandler(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_SPACE: Paused := not Paused;
    VK_F11: ToggleFullScreen;
    VK_S: SaveFrame;
    VK_H: ToggleCaption;
    VK_I, VK_F1: ShowInfo;
    VK_ESCAPE:
      if FFullScreen then ToggleFullScreen else Close;
  end;
end;

procedure TMainForm.SetPaused(AValue: Boolean);
begin
  FPaused := AValue;
  Invalidate;
end;

procedure TMainForm.ToggleCaption;
begin
  FScene.ShowCaption := not FScene.ShowCaption;
  Invalidate;
end;

procedure TMainForm.ToggleFullScreen;
begin
  FFullScreen := not FFullScreen;
  if FFullScreen then
  begin
    FSavedBounds := BoundsRect;
    BorderStyle := bsNone;
    WindowState := wsFullScreen;
  end
  else
  begin
    WindowState := wsNormal;
    BorderStyle := bsSizeable;
    BoundsRect := FSavedBounds;
  end;
end;

procedure TMainForm.SaveFrame;
var
  FileName: string;
begin
  FileName := ExtractFilePath(ParamStr(0)) + 'volcano_' +
    FormatDateTime('yyyymmdd_hhnnss', Now) + '.png';
  FFrame.SaveToFile(FileName);
  LastSaved := FileName;
  Caption := 'Volcano Papercut - saved ' + ExtractFileName(FileName);
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
