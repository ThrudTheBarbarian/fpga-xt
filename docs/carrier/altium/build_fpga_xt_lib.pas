{ ============================================================================
  build_fpga_xt_lib.pas  -  fpga-xt motherboard schematic-symbol generator

  Builds schematic symbols for the parts that are NOT in stock Altium libs:
  the Z-Turn CON80 (CN1/CN2), the Atari cartridge / PBI / SIO / joystick
  connectors, and the CB3T bus switches, plus functional symbols for the
  RP2354B, PCM1808 and USB hub.

  HOW TO RUN
    1. Altium: File > New > Library > Schematic Library  (a blank .SchLib).
    2. Keep that SchLib document as the active window.
    3. DXP/Tools > Run Script... > choose this file > run procedure GenLib.
    4. Save the .SchLib.

  PIN-NUMBER ACCURACY
    - CONNECTORS (CON80, CART30, PBI50, SIO13, JOY_DE9): pin NUMBERS are the
      real connector positions and pin NAMES carry the 800XL-strict signals
      from docs/carrier/03-schematic-sheets.md. These are ready to use.
    - ICs (CB3T16210, CB3T3245, RP2354B, PCM1808, USB_HUB): pins carry
      FUNCTIONAL names; the placeholder pin NUMBERS (1..N in listed order)
      MUST be reconciled against the device datasheet/package before you
      build footprints. Each such symbol prints a reminder in its description.

  Footprints (PcbLib) - especially the card-edge fingers - are a separate
  step; see README.md in this folder.
  ============================================================================ }

Var
    SchLib  : ISch_Lib;
    LY, RY  : Integer;     // running pin Y (mils), per side, per component
    LN, RN  : Integer;     // pin counts per side
    BodyW   : Integer;     // body width (mils)

Const
    PIN_PITCH = 100;
    PIN_LEN   = 300;
    TOP_Y     = 0;

{ ---- low-level helpers --------------------------------------------------- }

Function MkComp(LibRef, Desig, Descr : String; AWidth : Integer) : ISch_Component;
Var R : ISch_Rectangle;
Begin
    Result := SchServer.SchObjectFactory(eSchComponent, eCreate_GlobalCopy);
    Result.Designator.Text      := Desig;
    Result.LibReference         := LibRef;
    Result.ComponentDescription := Descr;
    Result.Location             := Point(MilsToCoord(100), MilsToCoord(100));
    LY := TOP_Y; RY := TOP_Y; LN := 0; RN := 0; BodyW := AWidth;
End;

{ side: 0 = left, 1 = right.  et : TPinElectrical }
Procedure AddPin(Comp : ISch_Component; Side : Integer;
                 Num, Nm : String; Et : TIeeeSymbol);
Var Pin : ISch_Pin; Y : Integer;
Begin
    Pin := SchServer.SchObjectFactory(ePin, eCreate_GlobalCopy);
    Pin.Designator   := Num;
    Pin.Name         := Nm;
    Pin.Electrical   := Et;
    Pin.PinLength    := MilsToCoord(PIN_LEN);
    Pin.ShowName     := True;
    Pin.ShowDesignator := True;
    If Side = 0 Then Begin
        Pin.Orientation := eRotate0;                       // hot end at left
        Y := LY; LY := LY - PIN_PITCH; LN := LN + 1;
        Pin.Location := Point(MilsToCoord(0), MilsToCoord(Y));
    End Else Begin
        Pin.Orientation := eRotate180;                     // hot end at right
        Y := RY; RY := RY - PIN_PITCH; RN := RN + 1;
        Pin.Location := Point(MilsToCoord(BodyW), MilsToCoord(Y));
    End;
    Comp.AddSchObject(Pin);
End;

Procedure Finish(Comp : ISch_Component);
Var R : ISch_Rectangle; H, Bot : Integer;
Begin
    If LN > RN Then H := LN Else H := RN;
    Bot := TOP_Y - (H * PIN_PITCH);
    R := SchServer.SchObjectFactory(eRectangle, eCreate_GlobalCopy);
    R.Location := Point(MilsToCoord(PIN_LEN), MilsToCoord(Bot + PIN_PITCH Div 2));
    R.Corner   := Point(MilsToCoord(BodyW - PIN_LEN), MilsToCoord(TOP_Y + PIN_PITCH Div 2));
    R.LineWidth := eSmall; R.IsSolid := True; R.AreaColor := $00B0FFFF;
    Comp.AddSchObject(R);
    SchLib.AddSchComponent(Comp);
    SchServer.RobotManager.SendMessage(SchLib.I_ObjectAddress, c_BroadCast,
        SCHM_PrimitiveRegistration, Comp.I_ObjectAddress);
End;

{ shorthand electrical types }
Function eIn  : TIeeeSymbol; Begin Result := eElectricInput;   End;
Function eOut : TIeeeSymbol; Begin Result := eElectricOutput;  End;
Function eIO  : TIeeeSymbol; Begin Result := eElectricIO;      End;
Function ePwr : TIeeeSymbol; Begin Result := eElectricPower;   End;
Function ePas : TIeeeSymbol; Begin Result := eElectricPassive; End;

{ ---- CON80  (CN1 / CN2, generic 2x40) ----------------------------------- }
Procedure Gen_CON80;
Var C : ISch_Component; i : Integer;
Begin
    C := MkComp('CON80_ZTURN', 'CN?', 'Z-Turn 2x40 board-to-board (CON80) - mate per Z-Turn sheet 15', 700);
    For i := 1 To 40 Do AddPin(C, 0, IntToStr(i),      'P' + IntToStr(i),      ePas);
    For i := 41 To 80 Do AddPin(C, 1, IntToStr(i),     'P' + IntToStr(i),      ePas);
    Finish(C);
End;

{ ---- Atari cartridge connector  (30-pin: 1..15 + A..S) ------------------ }
Procedure Gen_CART30;
Var C : ISch_Component;
Begin
    C := MkComp('ATARI_CART_30', 'J?', 'Atari 800XL cartridge slot, 30-pin card edge', 800);
    { numbered row -> left }
    AddPin(C,0,'1','/S4',ePas);   AddPin(C,0,'2','A3',ePas);   AddPin(C,0,'3','A2',ePas);
    AddPin(C,0,'4','A1',ePas);    AddPin(C,0,'5','A0',ePas);   AddPin(C,0,'6','D4',ePas);
    AddPin(C,0,'7','D5',ePas);    AddPin(C,0,'8','D2',ePas);   AddPin(C,0,'9','D1',ePas);
    AddPin(C,0,'10','D0',ePas);   AddPin(C,0,'11','D6',ePas);  AddPin(C,0,'12','/S5',ePas);
    AddPin(C,0,'13','+5V',ePwr);  AddPin(C,0,'14','/RD5',ePas);AddPin(C,0,'15','/CCTL',ePas);
    { lettered row -> right (G,I,O,Q skipped) }
    AddPin(C,1,'A','/RD4',ePas);  AddPin(C,1,'B','GND',ePwr);  AddPin(C,1,'C','A4',ePas);
    AddPin(C,1,'D','A5',ePas);    AddPin(C,1,'E','A6',ePas);   AddPin(C,1,'F','A7',ePas);
    AddPin(C,1,'H','A8',ePas);    AddPin(C,1,'J','A9',ePas);   AddPin(C,1,'K','A12',ePas);
    AddPin(C,1,'L','D3',ePas);    AddPin(C,1,'M','D7',ePas);   AddPin(C,1,'N','A11',ePas);
    AddPin(C,1,'P','A10',ePas);   AddPin(C,1,'R','R/W',ePas);  AddPin(C,1,'S','PHI2',ePas);
    Finish(C);
End;

{ ---- PBI connector  (50-pin) -------------------------------------------- }
Procedure Gen_PBI50;
Var C : ISch_Component;
Begin
    C := MkComp('ATARI_PBI_50', 'J?', 'Atari 800XL Parallel Bus Interface, 50-pin card edge', 800);
    AddPin(C,0,'1','GND',ePwr);   AddPin(C,0,'2','/EXTSEL',ePas);AddPin(C,0,'3','A0',ePas);
    AddPin(C,0,'4','A1',ePas);    AddPin(C,0,'5','A2',ePas);    AddPin(C,0,'6','A3',ePas);
    AddPin(C,0,'7','A4',ePas);    AddPin(C,0,'8','A5',ePas);    AddPin(C,0,'9','A6',ePas);
    AddPin(C,0,'10','GND',ePwr);  AddPin(C,0,'11','A7',ePas);   AddPin(C,0,'12','A8',ePas);
    AddPin(C,0,'13','A9',ePas);   AddPin(C,0,'14','A10',ePas);  AddPin(C,0,'15','A11',ePas);
    AddPin(C,0,'16','A12',ePas);  AddPin(C,0,'17','A13',ePas);  AddPin(C,0,'18','A14',ePas);
    AddPin(C,0,'19','GND',ePwr);  AddPin(C,0,'20','A15',ePas);  AddPin(C,0,'21','D0',ePas);
    AddPin(C,0,'22','D1',ePas);   AddPin(C,0,'23','D2',ePas);   AddPin(C,0,'24','D3',ePas);
    AddPin(C,0,'25','D4',ePas);
    AddPin(C,1,'26','D5',ePas);   AddPin(C,1,'27','D6',ePas);   AddPin(C,1,'28','D7',ePas);
    AddPin(C,1,'29','GND',ePwr);  AddPin(C,1,'30','GND',ePwr);  AddPin(C,1,'31','PHI2',ePas);
    AddPin(C,1,'32','GND',ePwr);  AddPin(C,1,'33','NC',ePas);   AddPin(C,1,'34','/RST',ePas);
    AddPin(C,1,'35','/IRQ',ePas); AddPin(C,1,'36','/RDY',ePas); AddPin(C,1,'37','NC',ePas);
    AddPin(C,1,'38','/EXTENB',ePas);AddPin(C,1,'39','NC',ePas); AddPin(C,1,'40','/REF',ePas);
    AddPin(C,1,'41','/CAS',ePas); AddPin(C,1,'42','GND',ePwr);  AddPin(C,1,'43','/MPD',ePas);
    AddPin(C,1,'44','/RAS',ePas); AddPin(C,1,'45','GND',ePwr);  AddPin(C,1,'46','LR/W',ePas);
    AddPin(C,1,'47','NC',ePas);   AddPin(C,1,'48','NC',ePas);   AddPin(C,1,'49','AUDIO',ePas);
    AddPin(C,1,'50','GND',ePwr);
    Finish(C);
End;

{ ---- SIO connector  (13-pin) -------------------------------------------- }
Procedure Gen_SIO13;
Var C : ISch_Component;
Begin
    C := MkComp('ATARI_SIO_13', 'J?', 'Atari SIO 13-pin (XL: pin12 +12V = NC)', 700);
    AddPin(C,0,'1','CLK_IN',ePas);  AddPin(C,0,'2','CLK_OUT',ePas); AddPin(C,0,'3','DATA_IN',ePas);
    AddPin(C,0,'4','GND',ePwr);     AddPin(C,0,'5','DATA_OUT',ePas);AddPin(C,0,'6','GND',ePwr);
    AddPin(C,0,'7','/COMMAND',ePas);
    AddPin(C,1,'8','MOTOR',ePas);   AddPin(C,1,'9','/PROCEED',ePas);AddPin(C,1,'10','+5V/RDY',ePwr);
    AddPin(C,1,'11','AUDIO_IN',ePas);AddPin(C,1,'12','NC(+12V)',ePas);AddPin(C,1,'13','/INTERRUPT',ePas);
    Finish(C);
End;

{ ---- Joystick port  (DE-9) ---------------------------------------------- }
Procedure Gen_JOY9;
Var C : ISch_Component;
Begin
    C := MkComp('ATARI_JOY_DE9', 'J?', 'Atari joystick/paddle DE-9 (pin7 = 3.3V on this board)', 700);
    AddPin(C,0,'1','UP',ePas);    AddPin(C,0,'2','DOWN',ePas);  AddPin(C,0,'3','LEFT',ePas);
    AddPin(C,0,'4','RIGHT',ePas); AddPin(C,0,'5','POT_B',ePas);
    AddPin(C,1,'6','TRIGGER',ePas);AddPin(C,1,'7','+3V3',ePwr); AddPin(C,1,'8','GND',ePwr);
    AddPin(C,1,'9','POT_A',ePas);
    Finish(C);
End;

{ ---- CB3T16210  (20-bit FET bus switch) - VERIFY PIN NUMBERS ------------- }
Procedure Gen_CB3T16210;
Var C : ISch_Component; i : Integer; n : Integer;
Begin
    C := MkComp('SN74CB3T16210', 'U?', 'VERIFY DGG/DGV pin numbers vs datasheet. 20-bit 3.3<->5V FET switch', 900);
    n := 1;
    AddPin(C,0,IntToStr(n),'1OE',eIn); n:=n+1;
    For i := 1 To 10 Do Begin AddPin(C,0,IntToStr(n),'1A'+IntToStr(i),eIO); n:=n+1; End;
    AddPin(C,0,IntToStr(n),'2OE',eIn); n:=n+1;
    For i := 1 To 10 Do Begin AddPin(C,0,IntToStr(n),'2A'+IntToStr(i),eIO); n:=n+1; End;
    For i := 1 To 10 Do Begin AddPin(C,1,IntToStr(n),'1B'+IntToStr(i),eIO); n:=n+1; End;
    For i := 1 To 10 Do Begin AddPin(C,1,IntToStr(n),'2B'+IntToStr(i),eIO); n:=n+1; End;
    AddPin(C,1,IntToStr(n),'VCC',ePwr); n:=n+1;
    AddPin(C,1,IntToStr(n),'GND',ePwr);
    Finish(C);
End;

{ ---- CB3T3245  (8-bit FET bus switch, SIO) - VERIFY PIN NUMBERS ---------- }
Procedure Gen_CB3T3245;
Var C : ISch_Component; i : Integer; n : Integer;
Begin
    C := MkComp('SN74CB3T3245', 'U?', 'VERIFY pin numbers vs datasheet. 8-bit 3.3<->5V FET switch', 800);
    n := 1;
    AddPin(C,0,IntToStr(n),'/OE',eIn); n:=n+1;
    For i := 1 To 8 Do Begin AddPin(C,0,IntToStr(n),'A'+IntToStr(i),eIO); n:=n+1; End;
    For i := 1 To 8 Do Begin AddPin(C,1,IntToStr(n),'B'+IntToStr(i),eIO); n:=n+1; End;
    AddPin(C,1,IntToStr(n),'VCC',ePwr); n:=n+1;
    AddPin(C,1,IntToStr(n),'GND',ePwr);
    Finish(C);
End;

{ ---- RP2354B  (functional) - VERIFY PIN NUMBERS ------------------------- }
Procedure Gen_RP2354B;
Var C : ISch_Component; i : Integer; n : Integer;
Begin
    C := MkComp('RP2354B', 'U?', 'FUNCTIONAL symbol - assign QFN-80 pin numbers from datasheet', 1100);
    n := 1;
    { joysticks GPIO0..15 }
    For i := 0 To 15 Do Begin AddPin(C,0,IntToStr(n),'GPIO'+IntToStr(i),eIO); n:=n+1; End;
    { triggers 16..19, SIO 20..27, SPI/IRQ/LED/USBhost 28..35 }
    For i := 16 To 35 Do Begin AddPin(C,0,IntToStr(n),'GPIO'+IntToStr(i),eIO); n:=n+1; End;
    { ADC paddles 40..47 }
    For i := 40 To 47 Do Begin AddPin(C,1,IntToStr(n),'GPIO'+IntToStr(i)+'/ADC',eIO); n:=n+1; End;
    AddPin(C,1,IntToStr(n),'USB_DP',eIO); n:=n+1;
    AddPin(C,1,IntToStr(n),'USB_DM',eIO); n:=n+1;
    AddPin(C,1,IntToStr(n),'RUN',eIn); n:=n+1;
    AddPin(C,1,IntToStr(n),'SWCLK',eIn); n:=n+1;
    AddPin(C,1,IntToStr(n),'SWDIO',eIO); n:=n+1;
    AddPin(C,1,IntToStr(n),'XIN',eIn); n:=n+1;
    AddPin(C,1,IntToStr(n),'XOUT',eOut); n:=n+1;
    AddPin(C,1,IntToStr(n),'IOVDD',ePwr); n:=n+1;
    AddPin(C,1,IntToStr(n),'USB_VDD',ePwr); n:=n+1;
    AddPin(C,1,IntToStr(n),'ADC_AVDD',ePwr); n:=n+1;
    AddPin(C,1,IntToStr(n),'VREG_VIN',ePwr); n:=n+1;
    AddPin(C,1,IntToStr(n),'VREG_VOUT',ePwr); n:=n+1;
    AddPin(C,1,IntToStr(n),'GND',ePwr);
    Finish(C);
End;

{ ---- PCM1808  (functional) - VERIFY PIN NUMBERS ------------------------- }
Procedure Gen_PCM1808;
Var C : ISch_Component; n : Integer;
Begin
    C := MkComp('PCM1808', 'U?', 'FUNCTIONAL symbol - assign TSSOP-14 pin numbers from datasheet', 800);
    n := 1;
    AddPin(C,0,IntToStr(n),'VINL',eIn); n:=n+1;
    AddPin(C,0,IntToStr(n),'VINR',eIn); n:=n+1;
    AddPin(C,0,IntToStr(n),'VREF1',ePas); n:=n+1;
    AddPin(C,0,IntToStr(n),'VREF2',ePas); n:=n+1;
    AddPin(C,0,IntToStr(n),'FMT',eIn); n:=n+1;
    AddPin(C,0,IntToStr(n),'MD0',eIn); n:=n+1;
    AddPin(C,0,IntToStr(n),'MD1',eIn);
    AddPin(C,1,IntToStr(n+1),'SCKI',eIn);
    AddPin(C,1,IntToStr(n+2),'BCK',eIn);
    AddPin(C,1,IntToStr(n+3),'LRCK',eIn);
    AddPin(C,1,IntToStr(n+4),'DOUT',eOut);
    AddPin(C,1,IntToStr(n+5),'VDD',ePwr);
    AddPin(C,1,IntToStr(n+6),'AGND',ePwr);
    AddPin(C,1,IntToStr(n+7),'DGND',ePwr);
    Finish(C);
End;

{ ---- USB 1:4 hub  (functional) ----------------------------------------- }
Procedure Gen_USBHUB;
Var C : ISch_Component; i : Integer; n : Integer;
Begin
    C := MkComp('USB_HUB_1x4', 'U?', 'FUNCTIONAL 1:4 USB hub - map to chosen PN (FE1.1s/CH334F/USB2514B)', 900);
    n := 1;
    AddPin(C,0,IntToStr(n),'UP_DP',eIO); n:=n+1;
    AddPin(C,0,IntToStr(n),'UP_DM',eIO); n:=n+1;
    AddPin(C,0,IntToStr(n),'XIN',eIn); n:=n+1;
    AddPin(C,0,IntToStr(n),'XOUT',eOut); n:=n+1;
    For i := 1 To 4 Do Begin
        AddPin(C,1,IntToStr(n),'DP'+IntToStr(i),eIO); n:=n+1;
        AddPin(C,1,IntToStr(n),'DM'+IntToStr(i),eIO); n:=n+1;
    End;
    AddPin(C,1,IntToStr(n),'VDD',ePwr); n:=n+1;
    AddPin(C,1,IntToStr(n),'GND',ePwr);
    Finish(C);
End;

{ ---- entry point -------------------------------------------------------- }
Procedure GenLib;
Begin
    If SchServer = Nil Then Exit;
    SchLib := SchServer.GetCurrentSchDocument;
    If SchLib = Nil Then Begin ShowMessage('Open a blank Schematic Library first.'); Exit; End;
    If SchLib.ObjectID <> eSchLib Then Begin ShowMessage('Active document is not a SchLib.'); Exit; End;

    Gen_CON80;
    Gen_CART30;
    Gen_PBI50;
    Gen_SIO13;
    Gen_JOY9;
    Gen_CB3T16210;
    Gen_CB3T3245;
    Gen_RP2354B;
    Gen_PCM1808;
    Gen_USBHUB;

    SchLib.GraphicallyInvalidate;
    ShowMessage('fpga-xt symbols generated. Connectors are datasheet-exact; '
              + 'IC pin NUMBERS are placeholders - reconcile with datasheets.');
End;
