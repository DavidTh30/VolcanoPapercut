unit uRenderPool;

{ A fixed pool of worker threads that run a batch of numbered jobs.
  All threads are created once; ActiveThreads chooses how many take part in a
  batch, so changing the thread count never creates or destroys threads.
  Start hands the batch to every worker; each worker keeps taking the next job
  index (interlocked counter) until none is left, so fast workers take more
  jobs and the load stays balanced. Wait blocks until the batch is done.
  The pool also measures every job and every worker for the info window. }

{$mode objfpc}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils;

type
  TJobProc = procedure(AIndex, AWorker: Integer) of object;

  TRenderPool = class;

  { TPoolWorker }

  TPoolWorker = class(TThread)
  private
    FPool: TRenderPool;
    FIndex: Integer;
    FStart: PRTLEvent;
    FLastError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TRenderPool; AIndex: Integer);
    destructor Destroy; override;
  end;

  { TRenderPool }

  TRenderPool = class
  private
    FWorkers: array of TPoolWorker;
    FDone: PRTLEvent;
    FProc: TJobProc;
    FCount: Integer;
    FNext: LongInt;    // next job index, taken with InterLockedIncrement
    FActive: LongInt;  // workers still busy with the batch
    FBusy: Boolean;
    FActiveThreads: Integer;
    FErrors: LongInt;
    function GetThreadCount: Integer;
    procedure SetActiveThreads(AValue: Integer);
  public
    { statistics of the last batch }
    JobMs: array of Double;       // wall time of each job
    JobWorker: array of Integer;  // which worker ran it
    WorkerMs: array of Double;    // time each worker spent in jobs
    WorkerJobs: array of Integer; // jobs each worker ran
    StartTime, FinishTime: Double;
    LastError: string;
    constructor Create(AThreads: Integer);
    destructor Destroy; override;
    procedure Start(ACount: Integer; AProc: TJobProc);
    procedure Wait;
    procedure Run(ACount: Integer; AProc: TJobProc);
    { exceptions caught in jobs since the start (main thread, pool idle) }
    function ErrorCount: Integer;
    function ErrorReport: string;
    property ThreadCount: Integer read GetThreadCount;  // threads created
    property ActiveThreads: Integer read FActiveThreads write SetActiveThreads;
    property Busy: Boolean read FBusy;
  end;

{ High resolution clock in milliseconds. }
function HiResMs: Double;

{ Physical CPU cores (logical processors without hyper-threading siblings).
  Rendering scales with real cores; two threads on one core mostly fight for
  the same execution units and memory bandwidth. }
function PhysicalCores: Integer;

implementation

{$IFDEF WINDOWS}
function QueryPerformanceCounter(var C: Int64): LongBool; stdcall; external 'kernel32.dll';
function QueryPerformanceFrequency(var F: Int64): LongBool; stdcall; external 'kernel32.dll';

var
  QpcFreq: Int64 = 0;

function HiResMs: Double;
var
  C: Int64;
begin
  if QpcFreq = 0 then
    QueryPerformanceFrequency(QpcFreq);
  QueryPerformanceCounter(C);
  Result := Double(C) / Double(QpcFreq) * 1000;  // Double: FPC types 1000.0 as Single
end;
{$ELSE}
function HiResMs: Double;
begin
  Result := Double(GetTickCount64);
end;
{$ENDIF}

{$IFDEF WINDOWS}
type
  TProcInfo = record
    ProcessorMask: PtrUInt;
    Relationship: LongInt;  // 0 = RelationProcessorCore
    Pad: LongInt;
    Data: array[0..1] of QWord;
  end;

function GetLogicalProcessorInformation(Buffer: Pointer; var ReturnLength: LongWord): LongBool;
  stdcall; external 'kernel32.dll';

function PhysicalCores: Integer;
var
  Len: LongWord;
  Buf: array of TProcInfo;
  I: Integer;
begin
  Result := 0;
  Len := 0;
  GetLogicalProcessorInformation(nil, Len);
  if Len > 0 then
  begin
    SetLength(Buf, Len div SizeOf(TProcInfo) + 1);
    if GetLogicalProcessorInformation(@Buf[0], Len) then
      for I := 0 to Integer(Len div SizeOf(TProcInfo)) - 1 do
        if Buf[I].Relationship = 0 then Inc(Result);
  end;
  if Result < 1 then Result := TThread.ProcessorCount;
end;
{$ELSE}
function PhysicalCores: Integer;
begin
  Result := TThread.ProcessorCount;
end;
{$ENDIF}

{ TPoolWorker }

constructor TPoolWorker.Create(APool: TRenderPool; AIndex: Integer);
begin
  FPool := APool;
  FIndex := AIndex;
  FStart := RTLEventCreate;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TPoolWorker.Destroy;
begin
  RTLEventDestroy(FStart);
  inherited Destroy;
end;

procedure TPoolWorker.Execute;
var
  I, Jobs: Integer;
  T0, Busy: Double;
begin
  while not Terminated do
  begin
    RTLEventWaitFor(FStart);
    if Terminated then Break;
    Busy := 0;
    Jobs := 0;
    repeat
      I := InterLockedIncrement(FPool.FNext) - 1;
      if I >= FPool.FCount then Break;
      T0 := HiResMs;
      try
        FPool.FProc(I, FIndex);
      except
        on E: Exception do
        begin
          // each worker keeps its own message: no string is shared between threads
          FLastError := Format('job %d: %s: %s', [I, E.ClassName, E.Message]);
          InterLockedIncrement(FPool.FErrors);
        end;
      end;
      T0 := HiResMs - T0;
      FPool.JobMs[I] := T0;
      FPool.JobWorker[I] := FIndex;
      Busy := Busy + T0;
      Inc(Jobs);
    until False;
    FPool.WorkerMs[FIndex] := Busy;
    FPool.WorkerJobs[FIndex] := Jobs;
    if InterLockedDecrement(FPool.FActive) = 0 then
    begin
      FPool.FinishTime := HiResMs;
      RTLEventSetEvent(FPool.FDone);
    end;
  end;
end;

{ TRenderPool }

constructor TRenderPool.Create(AThreads: Integer);
var
  I: Integer;
begin
  inherited Create;
  if AThreads < 1 then AThreads := 1;
  FDone := RTLEventCreate;
  SetLength(WorkerMs, AThreads);
  SetLength(WorkerJobs, AThreads);
  SetLength(FWorkers, AThreads);
  for I := 0 to AThreads - 1 do
    FWorkers[I] := TPoolWorker.Create(Self, I);
  FActiveThreads := AThreads;
end;

procedure TRenderPool.SetActiveThreads(AValue: Integer);
begin
  Wait;
  if AValue < 1 then AValue := 1;
  if AValue > Length(FWorkers) then AValue := Length(FWorkers);
  FActiveThreads := AValue;
end;

destructor TRenderPool.Destroy;
var
  I: Integer;
begin
  Wait;
  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].Terminate;
    RTLEventSetEvent(FWorkers[I].FStart);
  end;
  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FWorkers[I].Free;
  end;
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

function TRenderPool.GetThreadCount: Integer;
begin
  Result := Length(FWorkers);
end;

procedure TRenderPool.Start(ACount: Integer; AProc: TJobProc);
var
  I: Integer;
begin
  Wait;
  if Length(JobMs) < ACount then
  begin
    SetLength(JobMs, ACount);
    SetLength(JobWorker, ACount);
  end;
  FProc := AProc;
  FCount := ACount;
  FNext := 0;
  FActive := FActiveThreads;
  FBusy := True;
  StartTime := HiResMs;
  for I := 0 to FActiveThreads - 1 do
    RTLEventSetEvent(FWorkers[I].FStart);
end;

procedure TRenderPool.Wait;
begin
  if not FBusy then Exit;
  RTLEventWaitFor(FDone);
  FBusy := False;
end;

function TRenderPool.ErrorCount: Integer;
begin
  Result := FErrors;
end;

function TRenderPool.ErrorReport: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(FWorkers) do
    if FWorkers[I].FLastError <> '' then
      Result := Result + Format('worker %d: %s', [I, FWorkers[I].FLastError]) + LineEnding;
end;

procedure TRenderPool.Run(ACount: Integer; AProc: TJobProc);
begin
  Start(ACount, AProc);
  Wait;
end;

end.
