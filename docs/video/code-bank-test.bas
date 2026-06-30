10 REM ===== XT CODE-BANK DDR TEST (Atari BASIC) =====
20 REM $6000-$9FFF is the code window (RAM).  $D5C0 selects the
30 REM bank: 0 = flat BRAM, >=1 = a 16K DDR page via the LINE
40 REM reader on S_AXI_ACP.  The reader is WRITE-THROUGH, so a
50 REM POKE to a non-zero bank lands in DDR and a PEEK re-fetches
60 REM it -- proving real DDR banking (not just the BRAM shadow).
70 REM We read into a variable while the bank is live, then flip
80 REM back to bank 0 BEFORE printing (the screen lives in this
90 REM window, so PRINT must run on bank 0 to be visible).
100 POKE 53727,255 : REM $D1DF: unlock all XT groups (bank = bit 3)
110 REM ---- bank 1: write 123, read back ----
120 POKE 54720,1 : POKE 24576,123 : A=PEEK(24576) : POKE 54720,0
130 PRINT "BANK 1: wrote 123 read ";A
140 REM ---- bank 2: write 77 to the SAME address ----
150 POKE 54720,2 : POKE 24576,77 : B=PEEK(24576) : POKE 54720,0
160 PRINT "BANK 2: wrote  77 read ";B
170 REM ---- back to bank 1: must STILL be 123 (DDR persisted,
180 REM bank 2's write to $6000 did not clobber it) ----
190 POKE 54720,1 : C=PEEK(24576) : POKE 54720,0
200 PRINT "BANK 1 AGAIN: read ";C
210 IF A=123 AND B=77 AND C=123 THEN PRINT "*** BANKING OK ***" : END
220 PRINT "*** FAIL  A=";A;" B=";B;" C=";C
