unit uMFVideo;

{ Minimal Windows Media Foundation binding for writing H.264 MP4 files.
  Uses the IMFSinkWriter (mfreadwrite.dll) that ships with Windows, so no
  external encoder is needed. The DLLs are loaded at runtime: on systems
  without Media Foundation (e.g. Windows "N" editions) MP4 export reports an
  error instead of preventing the program from starting.

  Input frames are 32-bit BGRA TBGRABitmaps (= MFVideoFormat_RGB32), written
  top-down; the encoder converts to YUV 4:2:0 internally. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF WINDOWS}Windows, ActiveX,{$ENDIF}
  Classes, SysUtils, BGRABitmap, BGRABitmapTypes;

type
  EMFVideo = class(Exception);

  TMp4Writer = class
  private
    FWriter: IUnknown;  // IMFSinkWriter
    FStream: DWORD;
    FWidth, FHeight, FFps: Integer;
    FFrames: Int64;
    FHardware: Boolean;
    FStarted: Boolean;
    procedure Open(const AFileName: string; ABitrate: Integer; AHardware: Boolean);
  public
    { AW and AH must be even (H.264 4:2:0). ABitrateKbps e.g. 16000. }
    constructor Create(const AFileName: string; AW, AH, AFps, ABitrateKbps: Integer;
      AHardware: Boolean);
    destructor Destroy; override;
    procedure AddFrame(AFrame: TBGRABitmap);
    procedure Finish;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    property Frames: Int64 read FFrames;
    property Hardware: Boolean read FHardware;
  end;

function MP4Available(out AReason: string): Boolean;

implementation

{$IFDEF WINDOWS}
type
  IMFAttributes = interface(IUnknown)
    ['{2cd2d921-c447-44a7-a13c-4adabfc247e3}']
    function GetItem: HRESULT; stdcall;
    function GetItemType: HRESULT; stdcall;
    function CompareItem: HRESULT; stdcall;
    function Compare: HRESULT; stdcall;
    function GetUINT32: HRESULT; stdcall;
    function GetUINT64: HRESULT; stdcall;
    function GetDouble: HRESULT; stdcall;
    function GetGUID: HRESULT; stdcall;
    function GetStringLength: HRESULT; stdcall;
    function GetString: HRESULT; stdcall;
    function GetAllocatedString: HRESULT; stdcall;
    function GetBlobSize: HRESULT; stdcall;
    function GetBlob: HRESULT; stdcall;
    function GetAllocatedBlob: HRESULT; stdcall;
    function GetUnknown: HRESULT; stdcall;
    function SetItem: HRESULT; stdcall;
    function DeleteItem: HRESULT; stdcall;
    function DeleteAllItems: HRESULT; stdcall;
    function SetUINT32(constref guidKey: TGUID; unValue: UINT32): HRESULT; stdcall;
    function SetUINT64(constref guidKey: TGUID; unValue: UInt64): HRESULT; stdcall;
    function SetDouble: HRESULT; stdcall;
    function SetGUID(constref guidKey: TGUID; constref guidValue: TGUID): HRESULT; stdcall;
    function SetString: HRESULT; stdcall;
    function SetBlob: HRESULT; stdcall;
    function SetUnknown: HRESULT; stdcall;
    function LockStore: HRESULT; stdcall;
    function UnlockStore: HRESULT; stdcall;
    function GetCount: HRESULT; stdcall;
    function GetItemByIndex: HRESULT; stdcall;
    function CopyAllItems: HRESULT; stdcall;
  end;

  IMFMediaType = interface(IMFAttributes)
    ['{44ae0fa8-ea31-4109-8d2e-4cae4997c555}']
    function GetMajorType: HRESULT; stdcall;
    function IsCompressedFormat: HRESULT; stdcall;
    function IsEqual: HRESULT; stdcall;
    function GetRepresentation: HRESULT; stdcall;
    function FreeRepresentation: HRESULT; stdcall;
  end;

  IMFMediaBuffer = interface(IUnknown)
    ['{045FA593-8799-42b8-BC8D-8968C6453507}']
    function Lock(out ppbBuffer: PByte; pcbMaxLength, pcbCurrentLength: PDWORD): HRESULT; stdcall;
    function Unlock: HRESULT; stdcall;
    function GetCurrentLength: HRESULT; stdcall;
    function SetCurrentLength(cbCurrentLength: DWORD): HRESULT; stdcall;
    function GetMaxLength: HRESULT; stdcall;
  end;

  IMFSample = interface(IMFAttributes)
    ['{c40a00f2-b93a-4d80-ae8c-5a1c634f58e4}']
    function GetSampleFlags: HRESULT; stdcall;
    function SetSampleFlags: HRESULT; stdcall;
    function GetSampleTime: HRESULT; stdcall;
    function SetSampleTime(hnsSampleTime: Int64): HRESULT; stdcall;
    function GetSampleDuration: HRESULT; stdcall;
    function SetSampleDuration(hnsSampleDuration: Int64): HRESULT; stdcall;
    function GetBufferCount: HRESULT; stdcall;
    function GetBufferByIndex: HRESULT; stdcall;
    function ConvertToContiguousBuffer: HRESULT; stdcall;
    function AddBuffer(pBuffer: IMFMediaBuffer): HRESULT; stdcall;
    function RemoveBufferByIndex: HRESULT; stdcall;
    function RemoveAllBuffers: HRESULT; stdcall;
    function GetTotalLength: HRESULT; stdcall;
    function CopyToBuffer: HRESULT; stdcall;
  end;

  IMFSinkWriter = interface(IUnknown)
    ['{3137f1cd-fe5e-4805-a5d8-fb477448cb3d}']
    function AddStream(pTargetMediaType: IMFMediaType; out pdwStreamIndex: DWORD): HRESULT; stdcall;
    function SetInputMediaType(dwStreamIndex: DWORD; pInputMediaType: IMFMediaType;
      pEncodingParameters: IMFAttributes): HRESULT; stdcall;
    function BeginWriting: HRESULT; stdcall;
    function WriteSample(dwStreamIndex: DWORD; pSample: IMFSample): HRESULT; stdcall;
    function SendStreamTick: HRESULT; stdcall;
    function PlaceMarker: HRESULT; stdcall;
    function NotifyEndOfSegment: HRESULT; stdcall;
    function Flush: HRESULT; stdcall;
    function Finalize: HRESULT; stdcall;
    function GetServiceForStream: HRESULT; stdcall;
    function GetStatistics: HRESULT; stdcall;
  end;

const
  MF_VERSION = $00020070;
  MFVideoInterlace_Progressive = 2;

  MF_MT_MAJOR_TYPE: TGUID = '{48eba18e-f8c9-4687-bf11-0a74c9f96a8f}';
  MF_MT_SUBTYPE: TGUID = '{f7e34c9a-42e8-4714-b74b-cb29d72c35e5}';
  MF_MT_AVG_BITRATE: TGUID = '{20332624-fb0d-4d9e-bd0d-cbf6786c102e}';
  MF_MT_INTERLACE_MODE: TGUID = '{e2724bb8-e676-4806-b4b2-a8d6efb44ccd}';
  MF_MT_FRAME_SIZE: TGUID = '{1652c33d-d6b2-4012-b834-72030849a37d}';
  MF_MT_FRAME_RATE: TGUID = '{c459a2e8-3d2c-4e44-b132-fee5156c7bb0}';
  MF_MT_PIXEL_ASPECT_RATIO: TGUID = '{c6376a1e-8d0a-4027-be45-6d9a0ad39bb6}';
  MF_MT_DEFAULT_STRIDE: TGUID = '{644b4e48-1e02-4516-b0eb-c01ca9d49ac6}';
  MFMediaType_Video: TGUID = '{73646976-0000-0010-8000-00AA00389B71}';
  MFVideoFormat_H264: TGUID = '{34363248-0000-0010-8000-00AA00389B71}';
  MFVideoFormat_RGB32: TGUID = '{00000016-0000-0010-8000-00AA00389B71}';
  MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS: TGUID = '{a634a91c-822b-41b9-a494-4de4643612b0}';
  MF_SINK_WRITER_DISABLE_THROTTLING: TGUID = '{08b845d8-2b74-4afe-9d53-be16d2d5ae4f}';

type
  TMFStartup = function(Version: ULONG; dwFlags: DWORD): HRESULT; stdcall;
  TMFShutdown = function: HRESULT; stdcall;
  TMFCreateMediaType = function(out ppMFType: IMFMediaType): HRESULT; stdcall;
  TMFCreateSample = function(out ppIMFSample: IMFSample): HRESULT; stdcall;
  TMFCreateMemoryBuffer = function(cbMaxLength: DWORD; out ppBuffer: IMFMediaBuffer): HRESULT; stdcall;
  TMFCreateAttributes = function(out ppMFAttributes: IMFAttributes; cInitialSize: UINT32): HRESULT; stdcall;
  TMFCreateSinkWriterFromURL = function(pwszOutputURL: PWideChar; pByteStream: Pointer;
    pAttributes: IMFAttributes; out ppSinkWriter: IMFSinkWriter): HRESULT; stdcall;

var
  LibPlat, LibRW: HMODULE;
  LoadError: string;
  MFStartup: TMFStartup;
  MFShutdown: TMFShutdown;
  MFCreateMediaType: TMFCreateMediaType;
  MFCreateSample: TMFCreateSample;
  MFCreateMemoryBuffer: TMFCreateMemoryBuffer;
  MFCreateAttributes: TMFCreateAttributes;
  MFCreateSinkWriterFromURL: TMFCreateSinkWriterFromURL;

function LoadMF: Boolean;
begin
  if Assigned(MFCreateSinkWriterFromURL) then Exit(True);
  if LoadError <> '' then Exit(False);
  LibPlat := LoadLibrary('mfplat.dll');
  LibRW := LoadLibrary('mfreadwrite.dll');
  if (LibPlat = 0) or (LibRW = 0) then
  begin
    LoadError := 'Windows Media Foundation (mfplat.dll / mfreadwrite.dll) is not installed. ' +
      'On Windows "N" editions install the Media Feature Pack.';
    Exit(False);
  end;
  Pointer(MFStartup) := GetProcAddress(LibPlat, 'MFStartup');
  Pointer(MFShutdown) := GetProcAddress(LibPlat, 'MFShutdown');
  Pointer(MFCreateMediaType) := GetProcAddress(LibPlat, 'MFCreateMediaType');
  Pointer(MFCreateSample) := GetProcAddress(LibPlat, 'MFCreateSample');
  Pointer(MFCreateMemoryBuffer) := GetProcAddress(LibPlat, 'MFCreateMemoryBuffer');
  Pointer(MFCreateAttributes) := GetProcAddress(LibPlat, 'MFCreateAttributes');
  Pointer(MFCreateSinkWriterFromURL) := GetProcAddress(LibRW, 'MFCreateSinkWriterFromURL');
  if not (Assigned(MFStartup) and Assigned(MFShutdown) and Assigned(MFCreateMediaType) and
    Assigned(MFCreateSample) and Assigned(MFCreateMemoryBuffer) and Assigned(MFCreateAttributes) and
    Assigned(MFCreateSinkWriterFromURL)) then
  begin
    LoadError := 'Media Foundation entry points not found.';
    MFCreateSinkWriterFromURL := nil;
    Exit(False);
  end;
  Result := True;
end;

procedure Check(AHr: HRESULT; const AStep: string);
begin
  if Failed(AHr) then
    raise EMFVideo.CreateFmt('Media Foundation: %s failed (HRESULT $%.8x)', [AStep, DWORD(AHr)]);
end;

function Pack64(AHi, ALo: DWORD): UInt64; inline;
begin
  Result := (UInt64(AHi) shl 32) or ALo;
end;
{$ENDIF}

function MP4Available(out AReason: string): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := LoadMF;
  AReason := LoadError;
  {$ELSE}
  Result := False;
  AReason := 'MP4 export uses Windows Media Foundation and is only available on Windows.';
  {$ENDIF}
end;

{ TMp4Writer }

constructor TMp4Writer.Create(const AFileName: string; AW, AH, AFps, ABitrateKbps: Integer;
  AHardware: Boolean);
var
  why: string;
begin
  inherited Create;
  if not MP4Available(why) then raise EMFVideo.Create(why);
  if Odd(AW) or Odd(AH) or (AW < 16) or (AH < 16) then
    raise EMFVideo.CreateFmt('MP4 frame size must be even and at least 16 px (got %d x %d)', [AW, AH]);
  FWidth := AW;
  FHeight := AH;
  FFps := AFps;
  {$IFDEF WINDOWS}
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  Check(MFStartup(MF_VERSION, 0), 'MFStartup');
  FStarted := True;
  try
    Open(AFileName, ABitrateKbps, AHardware);
  except
    { some GPU encoders reject a configuration: retry with the software encoder }
    if not AHardware then raise;
    FWriter := nil;
    DeleteFile(AFileName);
    Open(AFileName, ABitrateKbps, False);
  end;
  {$ENDIF}
end;

procedure TMp4Writer.Open(const AFileName: string; ABitrate: Integer; AHardware: Boolean);
{$IFDEF WINDOWS}
var
  attr: IMFAttributes;
  tOut, tIn: IMFMediaType;
  w: IMFSinkWriter;
  url: UnicodeString;
begin
  Check(MFCreateAttributes(attr, 2), 'MFCreateAttributes');
  attr.SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, Ord(AHardware));
  attr.SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, 1);
  url := UnicodeString(AFileName);
  Check(MFCreateSinkWriterFromURL(PWideChar(url), nil, attr, w), 'MFCreateSinkWriterFromURL');

  Check(MFCreateMediaType(tOut), 'MFCreateMediaType');
  tOut.SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  tOut.SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  tOut.SetUINT32(MF_MT_AVG_BITRATE, ABitrate * 1000);
  tOut.SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  tOut.SetUINT64(MF_MT_FRAME_SIZE, Pack64(FWidth, FHeight));
  tOut.SetUINT64(MF_MT_FRAME_RATE, Pack64(FFps, 1));
  tOut.SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, Pack64(1, 1));
  Check(w.AddStream(tOut, FStream), 'AddStream (H.264 output)');

  Check(MFCreateMediaType(tIn), 'MFCreateMediaType');
  tIn.SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  tIn.SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  tIn.SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  tIn.SetUINT64(MF_MT_FRAME_SIZE, Pack64(FWidth, FHeight));
  tIn.SetUINT64(MF_MT_FRAME_RATE, Pack64(FFps, 1));
  tIn.SetUINT64(MF_MT_PIXEL_ASPECT_RATIO, Pack64(1, 1));
  tIn.SetUINT32(MF_MT_DEFAULT_STRIDE, UINT32(FWidth * 4));  // positive = top-down rows
  Check(w.SetInputMediaType(FStream, tIn, nil), 'SetInputMediaType (RGB32 input)');
  Check(w.BeginWriting, 'BeginWriting');
  FWriter := w;
  FHardware := AHardware;
end;
{$ELSE}
begin
end;
{$ENDIF}

destructor TMp4Writer.Destroy;
begin
  try
    Finish;
  except
    { already reported by the caller }
  end;
  {$IFDEF WINDOWS}
  if FStarted then MFShutdown;
  {$ENDIF}
  inherited Destroy;
end;

procedure TMp4Writer.AddFrame(AFrame: TBGRABitmap);
{$IFDEF WINDOWS}
var
  buf: IMFMediaBuffer;
  sample: IMFSample;
  p: PByte;
  y, rowBytes: Integer;
  src: TBGRABitmap;
begin
  if FWriter = nil then raise EMFVideo.Create('MP4 writer is closed');
  src := AFrame;
  if (AFrame.Width <> FWidth) or (AFrame.Height <> FHeight) then
    src := AFrame.Resample(FWidth, FHeight, rmFineResample) as TBGRABitmap;
  try
    rowBytes := FWidth * 4;
    Check(MFCreateMemoryBuffer(rowBytes * FHeight, buf), 'MFCreateMemoryBuffer');
    Check(buf.Lock(p, nil, nil), 'IMFMediaBuffer.Lock');
    try
      for y := 0 to FHeight - 1 do
        Move(src.ScanLine[y]^, p[y * rowBytes], rowBytes);
    finally
      buf.Unlock;
    end;
    buf.SetCurrentLength(rowBytes * FHeight);
  finally
    if src <> AFrame then src.Free;
  end;
  Check(MFCreateSample(sample), 'MFCreateSample');
  sample.AddBuffer(buf);
  sample.SetSampleTime(FFrames * 10000000 div FFps);
  sample.SetSampleDuration((FFrames + 1) * 10000000 div FFps - FFrames * 10000000 div FFps);
  Check(IMFSinkWriter(FWriter).WriteSample(FStream, sample), 'WriteSample');
  Inc(FFrames);
end;
{$ELSE}
begin
end;
{$ENDIF}

procedure TMp4Writer.Finish;
begin
  {$IFDEF WINDOWS}
  if FWriter = nil then Exit;
  try
    Check(IMFSinkWriter(FWriter).Finalize, 'Finalize');
  finally
    FWriter := nil;
  end;
  {$ENDIF}
end;

end.
