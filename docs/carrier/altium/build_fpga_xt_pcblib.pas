{ ============================================================================
  build_fpga_xt_pcblib.pas  -  connector footprints for the fpga-xt carrier

  WHY THIS SCRIPT EXISTS
    The Altium MCP bridge's lib_add_footprint_pad reports success but does NOT
    register pads into the footprint component (only lib_add_footprint_text was
    given the dual-add + PCBM_BoardRegisteration workaround). Result: every
    footprint built over MCP came out with 0 pads / 0 primitives. This script
    uses the proven DelphiScript pattern (FP.AddPCBObject + PCBM_BoardRegisteration
    + RegisterComponent) - the same path that builds the symbols reliably.

  BUILDS (datasheet-verified geometry):
    - M55-7008042R     Harwin 2x40 1.27mm vertical SMT header (CN1/CN2 = Z-Turn
                       stack). Harwin DRG-02768 Iss.9 sheet 10 round-hole PCB
                       layout + Table 4 (80-way). Pads 0.80x1.10mm @1.27, rows
                       5.50mm, 4 SMT hold-downs, 2x NPTH O1.65 location holes.
    - ATARI_PBI_EDGE_50  Atari 800XL PBI 50-pin card-edge GOLD FINGERS - our
                       board IS the Atari motherboard, so it presents the male
                       fingers a PBI device's socket plugs onto (we are NOT a
                       peripheral plugging into anything). 25 positions x 0.1",
                       ODD 1-49 top copper / EVEN 2-50 bottom, aligned. Numbering
                       per Wikipedia PBI + AtariMania (odd top / even bottom);
                       matches ATARI_PBI_50 symbol pins 1-50.

  HOW TO RUN
    1. If StartMCPServer (the MCP bridge) is running, STOP it - Altium runs only
       one script at a time.
    2. Open the existing fpga-xt.PcbLib  (File > Open), make it the active doc.
    3. In the PCB Library panel, DELETE any existing EMPTY footprints of the same
       names (M55-7008042R, ATARI_PBI_EDGE_50) so this script doesn't duplicate
       them. (The old MCP-built ones are empty - safe to remove.)
    4. DXP/Tools > Run Script... > this file > run procedure  GenAll.
    5. Save the .PcbLib.

  NOTE: top/bottom fingers (PBI) and the SMT pads share the same X,Y per
  position - in the 2D top view top+bottom pads sit on top of each other, so a
  card edge LOOKS like one row; toggle layers to see both. That is correct.

  GOLD FINGERS (PBI) are FAB settings, not footprint geometry: hard gold, NO
  soldermask over fingers, 20-30deg edge bevel, pull the board outline to the
  Mechanical1 line (y = 0 = finger tips). FINGER_L (7.5mm insertion depth) is
  the one value to confirm against a physical PBI socket.
  ============================================================================ }

Const
    { ---- M55-7008042R (mm) ---- }
    M_PITCH = 1.27;    M_PADW = 0.80;   M_PADL = 1.10;   M_ROWY = 2.75;
    M_SPAN  = 49.53;   { first..last contact centre = 39 * 1.27 }
    M_HDX   = 26.975;  M_HDY  = 3.00;   M_HDW  = 0.90;   M_HDL  = 1.60;
    M_HOLEX = 27.26;   M_HOLED = 1.65;
    M_BOXX  = 28.45;   M_BOXY = 3.95;
    { ---- ATARI_PBI_EDGE_50 (mm) ---- }
    P_PITCH = 2.54;    P_FINW = 2.00;   P_FINL = 7.50;   P_NPOS = 25;

Var
    CurLib : IPCB_Library;
    FP     : IPCB_LibComponent;

{ Remove any existing footprint of this name so re-runs don't duplicate. }
Procedure DropFP(Nm : String);
Var i : Integer; C : IPCB_LibComponent;
Begin
    For i := CurLib.ComponentCount - 1 DownTo 0 Do
    Begin
        C := CurLib.GetComponent(i);
        If C.Name = Nm Then CurLib.RemoveComponent(C);
    End;
End;

Procedure NewFP(Nm : String);
Begin
    DropFP(Nm);
    FP := PCBServer.CreatePCBLibComp;
    FP.Name := Nm;
End;

{ Generic pad: SMD when hole=0; through/NPTH when hole>0. w,l,hole in mm. }
Procedure Pad(x_mm, y_mm, w_mm, l_mm, hole_mm : Double; Lyr : TLayer;
              Shp : TShape; IsPlated : Boolean; Desig : String);
Var P : IPCB_Pad;
Begin
    P := PCBServer.PCBObjectFactory(ePadObject, eNoDimension, eCreate_Default);
    P.X        := MMsToCoord(x_mm);
    P.Y        := MMsToCoord(y_mm);
    P.TopXSize := MMsToCoord(w_mm);   P.TopYSize := MMsToCoord(l_mm);
    P.MidXSize := MMsToCoord(w_mm);   P.MidYSize := MMsToCoord(l_mm);
    P.BotXSize := MMsToCoord(w_mm);   P.BotYSize := MMsToCoord(l_mm);
    P.TopShape := Shp;   P.MidShape := Shp;   P.BotShape := Shp;
    P.HoleSize := MMsToCoord(hole_mm);
    P.Plated   := IsPlated;
    P.Layer    := Lyr;
    P.Name     := Desig;
    FP.AddPCBObject(P);
    PCBServer.SendMessageToRobots(CurLib.Board.I_ObjectAddress, c_Broadcast,
        PCBM_BoardRegisteration, P.I_ObjectAddress);
End;

Procedure Line(x1, y1, x2, y2, w_mm : Double; Lyr : TLayer);
Var T : IPCB_Track;
Begin
    T := PCBServer.PCBObjectFactory(eTrackObject, eNoDimension, eCreate_Default);
    T.X1 := MMsToCoord(x1);  T.Y1 := MMsToCoord(y1);
    T.X2 := MMsToCoord(x2);  T.Y2 := MMsToCoord(y2);
    T.Width := MMsToCoord(w_mm);
    T.Layer := Lyr;
    FP.AddPCBObject(T);
    PCBServer.SendMessageToRobots(CurLib.Board.I_ObjectAddress, c_Broadcast,
        PCBM_BoardRegisteration, T.I_ObjectAddress);
End;

Procedure Dot(xc, yc, r, w_mm : Double; Lyr : TLayer);
Var A : IPCB_Arc;
Begin
    A := PCBServer.PCBObjectFactory(eArcObject, eNoDimension, eCreate_Default);
    A.XCenter   := MMsToCoord(xc);
    A.YCenter   := MMsToCoord(yc);
    A.Radius    := MMsToCoord(r);
    A.StartAngle := 0;   A.EndAngle := 360;
    A.LineWidth := MMsToCoord(w_mm);
    A.Layer     := Lyr;
    FP.AddPCBObject(A);
    PCBServer.SendMessageToRobots(CurLib.Board.I_ObjectAddress, c_Broadcast,
        PCBM_BoardRegisteration, A.I_ObjectAddress);
End;

Procedure RegFP;
Begin
    CurLib.RegisterComponent(FP);
    CurLib.CurrentComponent := FP;
End;

{ ---- M55-7008042R : 80 SMT contacts + 4 hold-downs + 2 NPTH holes -------- }
Procedure GenM55;
Var i : Integer; x, x0 : Double;
Begin
    NewFP('M55-7008042R');
    x0 := 0 - (M_SPAN / 2);                 { -24.765 = first contact x }
    For i := 1 To 40 Do Begin
        x := x0 + (i - 1) * M_PITCH;
        Pad(x,  M_ROWY, M_PADW, M_PADL, 0, eTopLayer, eRectangular, True, IntToStr(i));      { top  1..40 }
        Pad(x, 0 - M_ROWY, M_PADW, M_PADL, 0, eTopLayer, eRectangular, True, IntToStr(i+40));{ bot 41..80 }
    End;
    { SMT hold-down tabs }
    Pad(0 - M_HDX,  M_HDY, M_HDW, M_HDL, 0, eTopLayer, eRectangular, True, 'MP1');
    Pad(M_HDX,      M_HDY, M_HDW, M_HDL, 0, eTopLayer, eRectangular, True, 'MP2');
    Pad(0 - M_HDX, 0 - M_HDY, M_HDW, M_HDL, 0, eTopLayer, eRectangular, True, 'MP3');
    Pad(M_HDX,     0 - M_HDY, M_HDW, M_HDL, 0, eTopLayer, eRectangular, True, 'MP4');
    { NPTH location/peg holes (no copper, not plated) }
    Pad(0 - M_HOLEX, 0, M_HOLED, M_HOLED, M_HOLED, eMultiLayer, eRounded, False, 'MH1');
    Pad(M_HOLEX,     0, M_HOLED, M_HOLED, M_HOLED, eMultiLayer, eRounded, False, 'MH2');
    { silk body box + pin-1 dot }
    Line(0 - M_BOXX,  M_BOXY, M_BOXX,  M_BOXY, 0.20, eTopOverlay);
    Line(0 - M_BOXX, 0 - M_BOXY, M_BOXX, 0 - M_BOXY, 0.20, eTopOverlay);
    Line(0 - M_BOXX, 0 - M_BOXY, 0 - M_BOXX, M_BOXY, 0.20, eTopOverlay);
    Line(M_BOXX,     0 - M_BOXY, M_BOXX,     M_BOXY, 0.20, eTopOverlay);
    Dot(0 - (M_BOXX + 0.95), M_ROWY, 0.30, 0.25, eTopOverlay);   { pin-1 marker }
    RegFP;
End;

{ ---- ATARI_PBI_EDGE_50 : 25 pos, odd top / even bottom, card edge -------- }
Procedure GenPBI;
Var i : Integer; x, yc, xL, xR : Double;
Begin
    NewFP('ATARI_PBI_EDGE_50');
    yc := P_FINL / 2;                       { pad centre; board edge / finger tip at y = 0 }
    For i := 0 To P_NPOS - 1 Do Begin
        x := i * P_PITCH;
        Pad(x, yc, P_FINW, P_FINL, 0, eTopLayer,    eRectangular, True, IntToStr(2*i + 1));  { odd  -> top    }
        Pad(x, yc, P_FINW, P_FINL, 0, eBottomLayer, eRectangular, True, IntToStr(2*i + 2));  { even -> bottom }
    End;
    xL := 0 - P_PITCH;   xR := P_NPOS * P_PITCH;
    Line(xL, 0, xR, 0, 0.20, eMechanical1);                 { board edge - pull outline here }
    Line(xL, P_FINL, xR, P_FINL, 0.15, eTopOverlay);        { inboard finger extent }
    Line(0 - P_FINW, P_FINL + 0.6, P_FINW, P_FINL + 0.6, 0.25, eTopOverlay);  { pin-1 tick }
    RegFP;
End;

{ ---- DSUB9_RA_F : DE-9 right-angle female, standard .318" footprint -------
  Pads/pins 1-9 match the ATARI_JOY_DE9 symbol. Pitch .109"(2.77) in-row, rows
  offset .112"(2.84); 2 boardlock holes at .984"(25.0) centres. Universal
  D-sub layout (NorComp 182 / Amphenol 82009 .318" R/A female).
  NOTE: pin-1 corner is drawn top-left; verify against the chosen DE-9 part. }
Procedure GenDE9;
Begin
    NewFP('DSUB9_RA_F');
    { top row pins 1..5 (y=0); pin 1 = rectangular marker }
    Pad(-5.537, 0, 1.70, 1.70, 0.99, eMultiLayer, eRectangular, True, '1');
    Pad(-2.769, 0, 1.70, 1.70, 0.99, eMultiLayer, eRounded, True, '2');
    Pad( 0.000, 0, 1.70, 1.70, 0.99, eMultiLayer, eRounded, True, '3');
    Pad( 2.769, 0, 1.70, 1.70, 0.99, eMultiLayer, eRounded, True, '4');
    Pad( 5.537, 0, 1.70, 1.70, 0.99, eMultiLayer, eRounded, True, '5');
    { bottom row pins 6..9 (y=-2.845), offset half a pitch }
    Pad(-4.140, -2.845, 1.70, 1.70, 0.99, eMultiLayer, eRounded, True, '6');
    Pad(-1.397, -2.845, 1.70, 1.70, 0.99, eMultiLayer, eRounded, True, '7');
    Pad( 1.397, -2.845, 1.70, 1.70, 0.99, eMultiLayer, eRounded, True, '8');
    Pad( 4.140, -2.845, 1.70, 1.70, 0.99, eMultiLayer, eRounded, True, '9');
    { boardlock / mounting holes (25.0mm centres) }
    Pad(-12.497, -1.422, 3.68, 3.68, 3.20, eMultiLayer, eRounded, True, 'MP1');
    Pad( 12.497, -1.422, 3.68, 3.68, 3.20, eMultiLayer, eRounded, True, 'MP2');
    { silk outline + pin-1 dot }
    Line(-15.75,  3.81, 15.75,  3.81, 0.20, eTopOverlay);
    Line(-15.75, -6.60, 15.75, -6.60, 0.20, eTopOverlay);
    Line(-15.75, -6.60,-15.75,  3.81, 0.20, eTopOverlay);
    Line( 15.75, -6.60, 15.75,  3.81, 0.20, eTopOverlay);
    Dot(-7.10, 1.50, 0.30, 0.25, eTopOverlay);
    RegFP;
End;

{ ---- CART_EDGE_30 : Atari cartridge slot = TE 5530843-2 card-edge socket ---
  30-contact (2x15) .100 centerline edge connector. Recommended PCB hole layout
  per TE customer drawing 5530843 sheet 6 + table (dash -2 = 15 dual positions):
  O0.040" holes, .100" pitch in-row (15/row), rows .191" apart. Top row = 1..15,
  bottom row = A..S, aligned columns (matches ATARI_CART_30 symbol). A real Atari
  cartridge inserts into this socket (we ARE the Atari). }
Procedure GenCart;
Const CX = 2.54; CRY = 2.4257; CH = 1.016; CPAD = 1.70; X0 = -17.78;
Var i : Integer; x : Double;
Begin
    DropFP('CART_2x15_P100');                 { remove the stale empty MCP footprint }
    NewFP('CART_EDGE_30_TE5530843');
    { top row contacts 1..15 (y = +CRY); pin 1 rectangular }
    For i := 1 To 15 Do Begin
        x := X0 + (i - 1) * CX;
        If i = 1 Then Pad(x, CRY, CPAD, CPAD, CH, eMultiLayer, eRectangular, True, '1')
        Else Pad(x, CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, IntToStr(i));
    End;
    { bottom row contacts A..S (y = -CRY), aligned under 1..15 }
    Pad(X0 +  0*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'A');
    Pad(X0 +  1*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'B');
    Pad(X0 +  2*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'C');
    Pad(X0 +  3*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'D');
    Pad(X0 +  4*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'E');
    Pad(X0 +  5*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'F');
    Pad(X0 +  6*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'H');
    Pad(X0 +  7*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'J');
    Pad(X0 +  8*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'K');
    Pad(X0 +  9*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'L');
    Pad(X0 + 10*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'M');
    Pad(X0 + 11*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'N');
    Pad(X0 + 12*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'P');
    Pad(X0 + 13*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'R');
    Pad(X0 + 14*CX, 0 - CRY, CPAD, CPAD, CH, eMultiLayer, eRounded, True, 'S');
    { silk body outline (~TE housing A=1.760") + pin-1 dot }
    Line(-20.0,  4.6, 20.0,  4.6, 0.20, eTopOverlay);
    Line(-20.0, -4.6, 20.0, -4.6, 0.20, eTopOverlay);
    Line(-20.0, -4.6,-20.0,  4.6, 0.20, eTopOverlay);
    Line( 20.0, -4.6, 20.0,  4.6, 0.20, eTopOverlay);
    Dot(-19.3, 2.43, 0.30, 0.25, eTopOverlay);
    RegFP;
End;

{ ---- SIO_RECEPTACLE_13 : Atari SIO 13-pin receptacle (computer side) --------
  Geometry taken from the FujiNet atari-sio-breakout v2.2 RECEPTACLE footprint
  (Gerbers/Through.drl, T03 contacts O2.1mm + T04 O6.0mm mounting). Pin numbering
  per the Atari SIO standard (Wikipedia/AtariMania): ZIGZAG - bottom row = ODD
  1,3,5,7,9,11,13; top row = EVEN 2,4,6,8,10,12. Pin 1 = rightmost lower contact
  (cross-checked vs the breakout header CKIN..INT labels). Matches ATARI_SIO_13
  symbol pins 1..13. Origin = contact-field centre. Contacts at x-stagger 1.78,
  in-row 3.56, rows 3.05 apart. The 2x O6.0 holes are the breakout's mounting -
  VERIFY they suit our mechanical (delete if board-specific). }
Procedure GenSIO;
Const SH = 2.1; SPAD = 3.0; MH = 6.0; YL = -1.525; YU = 1.525;
Begin
    NewFP('SIO_RECEPTACLE_13');
    { lower row (odd pins), pin 1 = rectangular marker }
    Pad( 10.68, YL, SPAD, SPAD, SH, eMultiLayer, eRectangular, True, '1');
    Pad(  7.12, YL, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '3');
    Pad(  3.56, YL, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '5');
    Pad(  0.00, YL, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '7');
    Pad( -3.56, YL, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '9');
    Pad( -7.12, YL, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '11');
    Pad(-10.68, YL, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '13');
    { upper row (even pins) }
    Pad(  8.90, YU, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '2');
    Pad(  5.34, YU, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '4');
    Pad(  1.78, YU, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '6');
    Pad( -1.78, YU, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '8');
    Pad( -5.34, YU, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '10');
    Pad( -8.90, YU, SPAD, SPAD, SH, eMultiLayer, eRounded, True, '12');
    { mounting holes (O6.0 NPTH), flanking the contacts }
    Pad(-19.95, -2.455, MH, MH, MH, eMultiLayer, eRounded, False, 'MH1');
    Pad( 20.05, -2.455, MH, MH, MH, eMultiLayer, eRounded, False, 'MH2');
    { silk around contact field + pin-1 dot }
    Line(-13.0,  3.6, 13.0,  3.6, 0.20, eTopOverlay);
    Line(-13.0, -3.6, 13.0, -3.6, 0.20, eTopOverlay);
    Line(-13.0, -3.6,-13.0,  3.6, 0.20, eTopOverlay);
    Line( 13.0, -3.6, 13.0,  3.6, 0.20, eTopOverlay);
    Dot(12.3, -3.1, 0.30, 0.25, eTopOverlay);
    RegFP;
End;

Procedure GenAll;
Begin
    If PCBServer = Nil Then Exit;
    CurLib := PCBServer.GetCurrentPCBLibrary;
    If CurLib = Nil Then Begin
        ShowMessage('Open a PCB Library (fpga-xt.PcbLib) and make it active first.');
        Exit;
    End;
    PCBServer.PreProcess;
    GenM55;
    GenPBI;
    GenDE9;
    GenCart;
    GenSIO;
    PCBServer.PostProcess;
    CurLib.Board.ViewManager_FullUpdate;
    { no ShowMessage: a modal here would hang an MCP-driven run }
End;
