unit uSvgRecorder;

{ Records drawing commands as SVG, for the vector export.

  The scene painters call the same shape commands they use for pixels (polygon,
  ellipse, polyline, gradient fill, text); in vector mode those go here and come
  out as SVG elements in frame pixel coordinates. Gradients, drop shadows, blurs
  and fade masks become <defs> entries. Every recorder has its own id prefix, so
  the defs of the static parts (recorded once per size) can be merged into each
  exported frame without clashes. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Math, BGRABitmap, BGRABitmapTypes;

type
  { a two-stop gradient: linear from P1 to P2, or radial centred on P1 with
    radius |P2 - P1| (the TBGRAGradientScanner convention) }
  TGrad = record
    C1, C2: TBGRAPixel;
    Radial: Boolean;
    P1, P2: TPointF;
  end;

  { TSvgRecorder }

  TSvgRecorder = class
  private
    FPrefix: string;
    FDefs, FBody: TStringList;
    FNextId: Integer;
    FFS: TFormatSettings;
    FCache: TStringList;  // name=id of shared defs (sprite gradients, filters)
    function NewId: string;
    function Pts(const P: array of TPointF): string;
  public
    Elements: Int64;
    constructor Create(const APrefix: string);
    destructor Destroy; override;
    function N(V: Single): string;
    function Paint(C: TBGRAPixel): string;          // fill="..." [fill-opacity]
    function StrokeAttr(C: TBGRAPixel; W: Single): string;
    function Gradient(const G: TGrad): string;       // returns url(#id)
    { a gradient shared by many shapes, in each shape's own bounding box }
    function BoxRadial(const AName: string; C1, C2: TBGRAPixel; CX, CY, R: Single): string;
    function DropShadow(DX, DY, Std, Opacity: Single): string;  // filter id
    function Blur(Std: Single): string;                          // filter id
    function FadeMask(X, Y, W, H, Y0, Y1: Single): string;        // mask id
    procedure Poly(const P: array of TPointF; C: TBGRAPixel);
    procedure PolyFill(const P: array of TPointF; const Fill: string);
    procedure Ellipse(CX, CY, RX, RY: Single; C: TBGRAPixel);
    procedure EllipseFill(CX, CY, RX, RY: Single; const Fill: string);
    procedure EllipseLine(CX, CY, RX, RY: Single; C: TBGRAPixel; W: Single);
    procedure PolyLine(const P: array of TPointF; C: TBGRAPixel; W: Single);
    procedure Line(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single);
    procedure Rect(X, Y, W, H: Single; const Fill: string);
    procedure RoundRect(X1, Y1, X2, Y2, RX, RY: Single; C: TBGRAPixel; StrokeW: Single = 0);
    procedure Text(X, Y: Single; const S, Font: string; Height: Single; Bold: Boolean;
      C: TBGRAPixel; Centered: Boolean);
    procedure Raw(const S: string);
    procedure BeginGroup(const Attr: string);
    procedure EndGroup;
    { body capture: Take returns everything recorded since Mark and removes it }
    function Mark: Integer;
    function Take(AMark: Integer): string;
    { merge the defs of another recorder (static parts) }
    procedure AddDefsFrom(Other: TSvgRecorder);
    function Document(W, H: Integer; const Title: string): string;
    procedure SaveToFile(const FileName: string; W, H: Integer; const Title: string);
  end;

function MakeGrad(C1, C2: TBGRAPixel; Radial: Boolean; P1, P2: TPointF): TGrad;

implementation

function MakeGrad(C1, C2: TBGRAPixel; Radial: Boolean; P1, P2: TPointF): TGrad;
begin
  Result.C1 := C1;
  Result.C2 := C2;
  Result.Radial := Radial;
  Result.P1 := P1;
  Result.P2 := P2;
end;

function HexOf(C: TBGRAPixel): string;
begin
  Result := '#' + IntToHex(C.red, 2) + IntToHex(C.green, 2) + IntToHex(C.blue, 2);
end;

function Esc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

{ TSvgRecorder }

constructor TSvgRecorder.Create(const APrefix: string);
begin
  inherited Create;
  FPrefix := APrefix;
  FDefs := TStringList.Create;
  FBody := TStringList.Create;
  FCache := TStringList.Create;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  FFS.ThousandSeparator := #0;
end;

destructor TSvgRecorder.Destroy;
begin
  FCache.Free;
  FBody.Free;
  FDefs.Free;
  inherited Destroy;
end;

function TSvgRecorder.NewId: string;
begin
  Inc(FNextId);
  Result := FPrefix + IntToStr(FNextId);
end;

function TSvgRecorder.N(V: Single): string;
begin
  if IsNan(V) or IsInfinite(V) then V := 0;
  Result := FormatFloat('0.##', V, FFS);
end;

function TSvgRecorder.Pts(const P: array of TPointF): string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to High(P) do
    begin
      if I > 0 then SB.Append(' ');
      SB.Append(N(P[I].X)).Append(',').Append(N(P[I].Y));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TSvgRecorder.Paint(C: TBGRAPixel): string;
begin
  Result := 'fill="' + HexOf(C) + '"';
  if C.alpha < 255 then
    Result := Result + ' fill-opacity="' + N(C.alpha / 255) + '"';
end;

function TSvgRecorder.StrokeAttr(C: TBGRAPixel; W: Single): string;
begin
  Result := 'fill="none" stroke="' + HexOf(C) + '" stroke-width="' + N(W) +
    '" stroke-linecap="round" stroke-linejoin="round"';
  if C.alpha < 255 then
    Result := Result + ' stroke-opacity="' + N(C.alpha / 255) + '"';
end;

function TSvgRecorder.Gradient(const G: TGrad): string;
var
  Id, Stops: string;
begin
  Id := NewId;
  Stops := Format('<stop offset="0" stop-color="%s" stop-opacity="%s"/>' +
    '<stop offset="1" stop-color="%s" stop-opacity="%s"/>',
    [HexOf(G.C1), N(G.C1.alpha / 255), HexOf(G.C2), N(G.C2.alpha / 255)]);
  if G.Radial then
    FDefs.Add(Format('<radialGradient id="%s" gradientUnits="userSpaceOnUse" cx="%s" cy="%s" r="%s">%s</radialGradient>',
      [Id, N(G.P1.X), N(G.P1.Y), N(Max(0.01, Hypot(G.P2.X - G.P1.X, G.P2.Y - G.P1.Y))), Stops]))
  else
    FDefs.Add(Format('<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="%s" y1="%s" x2="%s" y2="%s">%s</linearGradient>',
      [Id, N(G.P1.X), N(G.P1.Y), N(G.P2.X), N(G.P2.Y), Stops]));
  Result := 'url(#' + Id + ')';
end;

function TSvgRecorder.BoxRadial(const AName: string; C1, C2: TBGRAPixel; CX, CY, R: Single): string;
var
  I: Integer;
  Id: string;
begin
  I := FCache.IndexOfName(AName);
  if I >= 0 then Exit('url(#' + FCache.ValueFromIndex[I] + ')');
  Id := NewId;
  FDefs.Add(Format('<radialGradient id="%s" cx="%s" cy="%s" r="%s">' +
    '<stop offset="0" stop-color="%s" stop-opacity="%s"/><stop offset="1" stop-color="%s" stop-opacity="%s"/></radialGradient>',
    [Id, N(CX), N(CY), N(R), HexOf(C1), N(C1.alpha / 255), HexOf(C2), N(C2.alpha / 255)]));
  FCache.Values[AName] := Id;
  Result := 'url(#' + Id + ')';
end;

function TSvgRecorder.DropShadow(DX, DY, Std, Opacity: Single): string;
var
  Key: string;
  I: Integer;
begin
  Key := Format('shadow %s %s %s %s', [N(DX), N(DY), N(Std), N(Opacity)]);
  I := FCache.IndexOfName(Key);
  if I >= 0 then Exit(FCache.ValueFromIndex[I]);
  Result := NewId;
  FDefs.Add(Format('<filter id="%s" x="-20%%" y="-20%%" width="140%%" height="140%%">' +
    '<feDropShadow dx="%s" dy="%s" stdDeviation="%s" flood-color="#000" flood-opacity="%s"/></filter>',
    [Result, N(DX), N(DY), N(Std), N(Opacity)]));
  FCache.Values[Key] := Result;
end;

function TSvgRecorder.Blur(Std: Single): string;
var
  Key: string;
  I: Integer;
begin
  Key := 'blur ' + N(Std);
  I := FCache.IndexOfName(Key);
  if I >= 0 then Exit(FCache.ValueFromIndex[I]);
  Result := NewId;
  FDefs.Add(Format('<filter id="%s" x="-10%%" y="-10%%" width="120%%" height="120%%">' +
    '<feGaussianBlur stdDeviation="%s"/></filter>', [Result, N(Std)]));
  FCache.Values[Key] := Result;
end;

function TSvgRecorder.FadeMask(X, Y, W, H, Y0, Y1: Single): string;
var
  G: string;
begin
  G := NewId;
  Result := NewId;
  FDefs.Add(Format('<linearGradient id="%s" gradientUnits="userSpaceOnUse" x1="0" y1="%s" x2="0" y2="%s">' +
    '<stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>',
    [G, N(Y0), N(Y1)]));
  FDefs.Add(Format('<mask id="%s" maskUnits="userSpaceOnUse" x="%s" y="%s" width="%s" height="%s">' +
    '<rect x="%s" y="%s" width="%s" height="%s" fill="url(#%s)"/></mask>',
    [Result, N(X), N(Y), N(W), N(H), N(X), N(Y), N(W), N(H), G]));
end;

procedure TSvgRecorder.Poly(const P: array of TPointF; C: TBGRAPixel);
begin
  if (Length(P) < 3) or (C.alpha = 0) then Exit;
  FBody.Add('<polygon points="' + Pts(P) + '" ' + Paint(C) + '/>');
  Inc(Elements);
end;

procedure TSvgRecorder.PolyFill(const P: array of TPointF; const Fill: string);
begin
  if Length(P) < 3 then Exit;
  FBody.Add('<polygon points="' + Pts(P) + '" fill="' + Fill + '"/>');
  Inc(Elements);
end;

procedure TSvgRecorder.Ellipse(CX, CY, RX, RY: Single; C: TBGRAPixel);
begin
  if (C.alpha = 0) or (RX <= 0) or (RY <= 0) then Exit;
  FBody.Add(Format('<ellipse cx="%s" cy="%s" rx="%s" ry="%s" %s/>',
    [N(CX), N(CY), N(RX), N(RY), Paint(C)]));
  Inc(Elements);
end;

procedure TSvgRecorder.EllipseFill(CX, CY, RX, RY: Single; const Fill: string);
begin
  if (RX <= 0) or (RY <= 0) then Exit;
  FBody.Add(Format('<ellipse cx="%s" cy="%s" rx="%s" ry="%s" fill="%s"/>',
    [N(CX), N(CY), N(RX), N(RY), Fill]));
  Inc(Elements);
end;

procedure TSvgRecorder.EllipseLine(CX, CY, RX, RY: Single; C: TBGRAPixel; W: Single);
begin
  if (C.alpha = 0) or (RX <= 0) or (RY <= 0) then Exit;
  FBody.Add(Format('<ellipse cx="%s" cy="%s" rx="%s" ry="%s" %s/>',
    [N(CX), N(CY), N(RX), N(RY), StrokeAttr(C, W)]));
  Inc(Elements);
end;

procedure TSvgRecorder.PolyLine(const P: array of TPointF; C: TBGRAPixel; W: Single);
begin
  if (Length(P) < 2) or (C.alpha = 0) then Exit;
  FBody.Add('<polyline points="' + Pts(P) + '" ' + StrokeAttr(C, W) + '/>');
  Inc(Elements);
end;

procedure TSvgRecorder.Line(X1, Y1, X2, Y2: Single; C: TBGRAPixel; W: Single);
begin
  if C.alpha = 0 then Exit;
  FBody.Add(Format('<line x1="%s" y1="%s" x2="%s" y2="%s" %s/>',
    [N(X1), N(Y1), N(X2), N(Y2), StrokeAttr(C, W)]));
  Inc(Elements);
end;

procedure TSvgRecorder.Rect(X, Y, W, H: Single; const Fill: string);
begin
  FBody.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>',
    [N(X), N(Y), N(W), N(H), Fill]));
  Inc(Elements);
end;

procedure TSvgRecorder.RoundRect(X1, Y1, X2, Y2, RX, RY: Single; C: TBGRAPixel; StrokeW: Single);
begin
  if StrokeW > 0 then
    FBody.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" ry="%s" %s/>',
      [N(X1), N(Y1), N(X2 - X1), N(Y2 - Y1), N(RX), N(RY), StrokeAttr(C, StrokeW)]))
  else
    FBody.Add(Format('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" ry="%s" %s/>',
      [N(X1), N(Y1), N(X2 - X1), N(Y2 - Y1), N(RX), N(RY), Paint(C)]));
  Inc(Elements);
end;

procedure TSvgRecorder.Text(X, Y: Single; const S, Font: string; Height: Single;
  Bold: Boolean; C: TBGRAPixel; Centered: Boolean);
begin
  FBody.Add(Format('<text x="%s" y="%s" font-family="%s" font-size="%s"%s%s dominant-baseline="hanging" %s>%s</text>',
    [N(X), N(Y), Esc(Font), N(Height * 0.86), IfThen(Bold, ' font-weight="bold"', ''),
    IfThen(Centered, ' text-anchor="middle"', ''), Paint(C), Esc(S)]));
  Inc(Elements);
end;

procedure TSvgRecorder.Raw(const S: string);
begin
  if S <> '' then FBody.Add(S);
end;

procedure TSvgRecorder.BeginGroup(const Attr: string);
begin
  FBody.Add('<g ' + Attr + '>');
end;

procedure TSvgRecorder.EndGroup;
begin
  FBody.Add('</g>');
end;

function TSvgRecorder.Mark: Integer;
begin
  Result := FBody.Count;
end;

function TSvgRecorder.Take(AMark: Integer): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    for I := AMark to FBody.Count - 1 do
      SB.Append(FBody[I]).Append(LineEnding);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
  while FBody.Count > AMark do
    FBody.Delete(FBody.Count - 1);
end;

procedure TSvgRecorder.AddDefsFrom(Other: TSvgRecorder);
begin
  if Other <> nil then FDefs.AddStrings(Other.FDefs);
end;

function TSvgRecorder.Document(W, H: Integer; const Title: string): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('<?xml version="1.0" encoding="UTF-8"?>').Append(LineEnding);
    SB.Append(Format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">',
      [W, H, W, H])).Append(LineEnding);
    SB.Append('<title>').Append(Esc(Title)).Append('</title>').Append(LineEnding);
    SB.Append('<defs>').Append(LineEnding);
    for I := 0 to FDefs.Count - 1 do
      SB.Append(FDefs[I]).Append(LineEnding);
    SB.Append('</defs>').Append(LineEnding);
    for I := 0 to FBody.Count - 1 do
      SB.Append(FBody[I]).Append(LineEnding);
    SB.Append('</svg>').Append(LineEnding);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TSvgRecorder.SaveToFile(const FileName: string; W, H: Integer; const Title: string);
var
  F: TFileStream;
  S: string;
begin
  S := Document(W, H, Title);
  F := TFileStream.Create(FileName, fmCreate);
  try
    if S <> '' then F.WriteBuffer(S[1], Length(S));
  finally
    F.Free;
  end;
end;

end.
