10 REM ===== XT SCREEN-BANK FLIP TEST (Atari BASIC) =====
20 REM Banks 1 and 2 each hold a full GR.0 screen in the
30 REM $4000-$5FFF aperture.  ANTIC flips between them with
40 REM NO CPU redraw -> proves the screen_bank engine.
50 REM
60 POKE 53727,255 : REM $D1DF: unlock all XT groups (bank = bit 3)
70 GRAPHICS 0
80 DL=PEEK(560)+256*PEEK(561) : REM OS display-list address
90 POKE DL+4,0 : POKE DL+5,64 : REM point GR.0 LMS at $4000 (lo=0, hi=$40)
100 REM ---- build bank 1 = a field of "1" ----
110 POKE 54723,1 : GOSUB 500 : REM $D5C3 = CPU bank 1, wait ready
120 FOR I=0 TO 959 : POKE 16384+I,17 : NEXT I : REM screen code 17 = "1"
130 REM ---- build bank 2 = a field of "2" ----
140 POKE 54723,2 : GOSUB 500 : REM flush bank 1 -> DDR, load bank 2
150 FOR I=0 TO 959 : POKE 16384+I,18 : NEXT I : REM screen code 18 = "2"
160 POKE 54723,1 : GOSUB 500 : REM flush bank 2 -> DDR (both banks now stored)
170 REM ===== flip loop -- press BREAK to stop =====
180 POKE 54724,1 : GOSUB 600 : REM $D5C4 = ANTIC bank 1 -> shows "1"s
190 POKE 54724,2 : GOSUB 600 : REM $D5C4 = ANTIC bank 2 -> shows "2"s
200 GOTO 180
500 REM -- wait screen-bank ready ($D5C5 bit0) --
510 IF (PEEK(54725) AND 1)=0 THEN 510
520 RETURN
600 REM -- ~0.4 s delay so the flip is visible --
610 FOR D=1 TO 250 : NEXT D : RETURN
