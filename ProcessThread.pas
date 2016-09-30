unit ProcessThread;

interface
uses Windows, Classes, Math, SyncObjs, Graphics, Chart, Series,
StdCtrls, SysUtils, ltr24api, ltr34api, ltrapi, DACThread, WriterThread, Config;

type TProcessThread = class(TThread)
  public
    //�������� ���������� ��� ����������� ����������� ���������
    visChAvg : array [0..LTR24_CHANNEL_NUM-1] of TChart;
    DACthread : TDACThread; //������ ������ ��� ���������� ����� ������
    WriterThread : TWriter;
    debugFile:TextFile;
    MilisecsToWork:  Int64;
    MilisecsProcessed:  Int64;
    phltr34: pTLTR34;
    phltr24: pTLTR24; //��������� �� ��������� ������
    bnStart:  TButton;
    skipAmount: integer;

    path:string;
    frequency:string;

    doUseCalibration:boolean;
    err : Integer; //��� ������ ��� ���������� ������ �����
    stop : Boolean; //������ �� ������� (��������������� �� ��������� ������)

    constructor Create(SuspendCreate : Boolean);
    destructor Free();

  private
    { Private declarations }
    // �������, ��� ���� ����������� ������ �� ������� � ChAvg
    ChValidData : array [0..LTR24_CHANNEL_NUM-1] of Boolean;
    AccelerationSign: array [0..LTR24_CHANNEL_NUM-1] of Integer;
    OptimalDACSignal , LastCalibrateSignal, OptimalPoint: array [0..LTR24_CHANNEL_NUM-1] of DOUBLE;
    data     : array of Double;    //������������ ������
    calibration_signal_step: double;
    DevicesAmount   : Integer;  //���������� ����������� �������
    ChannelPackageSize : Integer;
    History: THistory;
    HistoryIndex, HistoryPage : Integer;

    procedure NextTick();
    procedure ParseChannelsData;
    procedure sendDAC(channel: Integer; signal: Double);
    procedure CalibrateData(deviceNumber: Integer);
    procedure doWorkPointShift(deviceNumber: Integer);
    function GetLowFreq(deviceNumber: Integer) : Double;
    procedure RecalculateOptimumPoint(deviceNumber: Integer);
    procedure doBigSignal(deviceNumber: Integer);
   protected
    procedure Execute; override;
  end;
implementation

  constructor TProcessThread.Create(SuspendCreate : Boolean);
  begin
     Inherited Create(SuspendCreate);
     stop:=False;
     err:=LTR_OK;
  end;

  destructor TProcessThread.Free();
  begin
      if DACthread <> nil then
        DACthread.stop := true;
        FreeAndNil(DACthread);
      Inherited Free();
  end;

  procedure TProcessThread.sendDAC(channel: Integer; signal: Double);
  begin
    EnterCriticalSection(DACSection);
    DACthread.DAC_level[channel]:=  signal;
    //DACthread.send(channel, signal);
    LastCalibrateSignal[channel]:= signal;
    LeaveCriticalSection(DACSection);
  end;


  procedure TProcessThread.Execute;
  var
    stoperr,i,historyPagesAmount : Integer;
    rcv_buf  : array of LongWord;  //����� �������� ����� �� ������

    ch       : Integer;

    recv_wrd_cnt : Integer;  //���������� ����������� ����� ���� �� ���
    recv_data_cnt : Integer; //���������� ������������ ����, ������� ������ ������� �� ���
    // ������ ����������� �������
    ch_nums  : array [0..LTR24_CHANNEL_NUM-1] of Byte;
    // ��������� ���������� ��� ����������. � ����� ����������� ��� ����
    // ������ - ChAvg � ChDataValid
    ch_avg   : array [0..LTR24_CHANNEL_NUM-1] of Double;
    ch_valid : array [0..LTR24_CHANNEL_NUM-1] of Boolean;
  begin
    //�������� ����������
    for ch:=0 to LTR24_CHANNEL_NUM-1 do
      ChValidData[ch]:=False;

    System.Assign(debugFile, 'D:\debug.txt');
    ReWrite(debugFile);

    //���������, ������� � ����� ������ ���������
    DevicesAmount := 0;
    for ch:=0 to LTR24_CHANNEL_NUM-1 do
    begin
      if phltr24^.ChannelMode[ch].Enable then
      begin
        ch_nums[DevicesAmount] := ch;
        DevicesAmount := DevicesAmount+1;
      end;
    end;

    { ����������, ������ �������������� ����� ���������� �� �������� �����
      => ����� ��������� ������ ������� ������ ������� }
    recv_data_cnt:=  Round(phltr24^.ADCFreq*ADC_reading_time/1000) * DevicesAmount;
    { � 24-������ ������� ������� ������� ������������� ��� ����� �� ������,
                   � � 20-������ - ���� }
    if phltr24^.DataFmt = LTR24_FORMAT_24 then
      recv_wrd_cnt :=  2*recv_data_cnt
    else
      recv_wrd_cnt :=  recv_data_cnt;

    { �������� ������� ��� ������ ������ }
    SetLength(rcv_buf, recv_wrd_cnt);
    SetLength(data, recv_data_cnt);

    historyPagesAmount :=   Trunc((recv_data_cnt*InnerBufferPagesAmount)/DevicesAmount);
    calibration_signal_step := DAC_max_signal/(CalibrateMiliSecondsCut/ADC_reading_time);
    for i := 0 to ChannelsAmount - 1 do begin
       SetLength(History[i], historyPagesAmount);
    end;

    err:= LTR24_Start(phltr24^);

    WriterThread := TWriter.Create(path, frequency, skipAmount, True);
    WriterThread.Priority := tpHighest;
    WriterThread.History := @History;

    if doUseCalibration then begin
      DACthread := TDACThread.Create(phltr34, True);
      DACthread.Priority := tpHighest;
      DACthread.Resume;
    end;

    if err = LTR_OK then
    begin
      while not stop and (err = LTR_OK) do
      begin
        { ��������� ������ (����� ������������ ������� ��� �����������, �� ����
          � ������������� ������� � ����) }
        ChannelPackageSize := LTR24_Recv(phltr24^, rcv_buf, recv_wrd_cnt, ADC_possible_delay + ADC_reading_time);
        MilisecsProcessed := MilisecsProcessed +  ADC_reading_time;

        if MilisecsProcessed > MilisecsToWork then
          stop := true;

        //�������� ������ ���� ������������� ���� ������
        if ChannelPackageSize < 0 then
          err:=ChannelPackageSize
        else  if ChannelPackageSize < recv_wrd_cnt then
          err:=LTR_ERROR_RECV_INSUFFICIENT_DATA
        else
        begin
          err:=LTR24_ProcessData(phltr24^, rcv_buf, data, ChannelPackageSize,
                                  LTR24_PROC_FLAG_CALIBR or
                                  LTR24_PROC_FLAG_VOLT or
                                  LTR24_PROC_FLAG_AFC_COR);
          if err=LTR_OK then
          begin
            for ch:=0 to LTR24_CHANNEL_NUM-1 do
            begin
              ch_avg[ch] :=  0;
              ch_valid[ch] := False;
            end;

            // �������� ���-�� �������� �� �����
            ChannelPackageSize := Trunc(ChannelPackageSize/DevicesAmount) ;
            for ch:=0 to DevicesAmount-1 do
            begin
              ChValidData[ch] := True;
            end;

            NextTick();
          end;
        end;

      end; //while not stop and (err = LTR_OK) do

      NextTick();

      visChAvg[0].Series[0].Clear();
      visChAvg[1].Series[0].Clear();

      WriterThread.Terminate();

      { �� ������ �� ����� ������������� ���� ������.
        ����� �� �������� ��� ������ (���� ����� �� ������)
        ��������� �������� ��������� � ��������� ���������� }

      stoperr:= LTR24_Stop(phltr24^);
      if err = LTR_OK then
        err:= stoperr;

    end;
    if doUseCalibration then begin
       DACthread.stopThread();
       DACthread.stop := true;
    end;
    bnStart.Caption := '�����';
  end;


  function TProcessThread.GetLowFreq(deviceNumber: Integer) : Double;
  var i, index : Integer;
  sum: Extended;
  sinArgStep, collectedStep, weight: Double;
  begin
    sum:= 0;
    sinArgStep:=1.57/ChannelPackageSize;  //pi/(2*ChannelPackageSize)
    collectedStep:=1;

    for i := 1 to  ChannelPackageSize do begin
      index:= HistoryIndex-i;
      if index<0 then
        index:= Length(History[deviceNumber])+index;

      weight:= sin(collectedStep);
      collectedStep:=collectedStep-sinArgStep;
      sum:=sum+(History[deviceNumber, index]*weight);
    end;

    GetLowFreq:= sum/ ChannelPackageSize;
  end;

  procedure TProcessThread.doWorkPointShift(deviceNumber: Integer);
  var
    Shift, newCalibrateSignal: Double;
  begin
    Shift := OptimalPoint[deviceNumber] - GetLowFreq(deviceNumber);
    Shift := Shift * AccelerationSign[deviceNumber];
    newCalibrateSignal := LastCalibrateSignal[deviceNumber] + Shift;

    if newCalibrateSignal > DAC_max_signal then
      newCalibrateSignal := newCalibrateSignal - (0.02 * DevicePeriod[deviceNumber]);
    if newCalibrateSignal < 0 then
      newCalibrateSignal := newCalibrateSignal + (0.02 * DevicePeriod[deviceNumber]);

    SendDAC(deviceNumber, newCalibrateSignal);
  end;

  Procedure TProcessThread.RecalculateOptimumPoint(deviceNumber: Integer);
  var i: integer;
    indexMin,indexMax:longint;
    OpHistoryPage, OpHistoryIndex: longint ;
    BefPageSignal, SignalStepByIndex, PageSignalChange: single;
    valueMax,valueMin: Double;
  begin
    valueMin := 14000; valueMax := -14000;
    indexMin := 0; indexMax := 0;

    for i := 0 to Length(History[deviceNumber])-1 do begin
    if (History[deviceNumber,i] = 0) then break; 

      if valueMin >= History[deviceNumber,i] then begin
        valueMin := History[deviceNumber,i];
        indexMin := i;
      end;
      if valueMax <= History[deviceNumber,i] then begin
        valueMax := History[deviceNumber,i];
        indexMax := i;
      end;
    end;
    OptimalPoint[deviceNumber] := (valueMax+valueMin)/2;     //����� ��������� ��� �����

    if indexMax > indexMin then
      AccelerationSign[deviceNumber]:= 1
    else
      AccelerationSign[deviceNumber]:= -1;

    //DAC signal calculating
    OpHistoryIndex := Round((indexMax+indexMin)/2);
    OpHistoryPage := Trunc(OpHistoryIndex/ChannelPackageSize);
    SignalStepByIndex := (calibration_signal_step/ChannelPackageSize);
    BefPageSignal := OpHistoryPage*calibration_signal_step;
    PageSignalChange :=  (OpHistoryIndex mod ChannelPackageSize)*SignalStepByIndex;
    OptimalDACSignal[deviceNumber] :=  BefPageSignal +  PageSignalChange;

    {OpHistoryIndex := Round((indexMax+indexMin)/2);
    OpHistoryPage := Trunc(OpHistoryIndex/ChannelPackageSize);
    OptimalDACSignal[deviceNumber] :=  OpHistoryPage*calibration_signal_step;}

    SendDAC(deviceNumber, OptimalDACSignal[deviceNumber]);

  end;

  procedure TProcessThread.doBigSignal(deviceNumber: Integer);
  begin
      EnterCriticalSection(DACSection);
     
      DACthread.DAC_level[deviceNumber]:= DACthread.DAC_level[deviceNumber]+calibration_signal_step;
      LeaveCriticalSection(DACSection);
  end;

  procedure TProcessThread.CalibrateData(deviceNumber: Integer);
  begin
    if MilisecsProcessed < CalibrateMiliSecondsCut then begin
      doBigSignal(deviceNumber);
    end else
    if MilisecsProcessed = CalibrateMiliSecondsCut then begin
      // RecalculateOptimumPoint(deviceNumber);
    end else
    if MilisecsProcessed > CalibrateMiliSecondsCut+3 then
      //doWorkPointShift(deviceNumber);

    writeln(debugFile, Format('%.5g', [DACthread.DAC_level[deviceNumber] ]));

  end;

  procedure TProcessThread.ParseChannelsData;
  var
    ch: Integer;
    i: Integer;
    IndexShift: Integer;
  begin
  EnterCriticalSection(HistorySection);
    for ch:=0 to LTR24_CHANNEL_NUM-1 do begin
      if ChValidData[ch] then begin
        for i := 0 to ChannelPackageSize-1 do begin
          IndexShift := DevicesAmount*i + ch;
          History[ch, HistoryIndex+i] := data[IndexShift];
        end;
      end;
    end;
  LeaveCriticalSection(HistorySection);
  end;

  procedure TProcessThread.NextTick();
  var i:Integer;
  begin
    ParseChannelsData;
    if HistoryPage >= InnerBufferPagesAmount then begin
      WriterThread.Save();
      HistoryPage := 0;
    end;
    HistoryIndex:= HistoryPage*ChannelPackageSize;

    if doUseCalibration then  begin
      for i := 0  to DevicesAmount - 1 do
        CalibrateData(i);
    end;

    HistoryPage:= HistoryPage+1;
  end;

end.
