			; Altirra Acid800 test suite
			; Copyright (C) 2010 Avery Lee, All Rights Reserved.
			;
			; Permission is hereby granted, free of charge, to any person obtaining a copy
			; of this software and associated documentation files (the "Software"), to deal
			; in the Software without restriction, including without limitation the rights
			; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
			; copies of the Software, and to permit persons to whom the Software is
			; furnished to do so, subject to the following conditions:
			;
			; The above copyright notice and this permission notice shall be included in
			; all copies or substantial portions of the Software.
			;
			; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
			; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
			; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
			; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
			; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
			; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
			; SOFTWARE.
				_SAP_HEADER "POKEY: Init timing"
					opt		h+o+
					icl		'library.s'
			.macro _DELAY_CYCLES_X
				;validate parameters
				.if :0 != 1
				.error "Cycle count required." c' '
				.endif
				.if :1 < 2
				.error "Cycle count must be at least 2." c' '
				.endif
				.if :1 > 1000
				.error "Cycle count is too large." c' '
				.endif
				.def ?cycles = :1
				.if ?cycles == 660 || ?cycles >= 662
					.def ?cycles = ?cycles - 660
					jsr		delay660
				.endif
				.if ?cycles == 408 || ?cycles >= 410
					.def ?cycles = ?cycles - 408
					jsr		delay408
				.endif
				.if ?cycles == 252 || ?cycles >= 254
					.def ?cycles = ?cycles - 252
					jsr		delay252
				.endif
				.if ?cycles == 156 || ?cycles >= 158
					.def ?cycles = ?cycles - 156
					jsr		delay156
				.endif
				.if ?cycles == 96 || ?cycles >= 98
					.def ?cycles = ?cycles - 96
					jsr		delay96
				.endif
				.if ?cycles == 60 || ?cycles >= 62
					.def ?cycles = ?cycles - 60
					jsr		delay60
				.endif
				.if ?cycles == 36 || ?cycles >= 38
					.def ?cycles = ?cycles - 36
					jsr		delay36
				.endif
				.if ?cycles == 24 || ?cycles >= 26
					.def ?cycles = ?cycles - 24
					jsr		delay24
				.endif
				;14-23 cycles we can hit exactly
				.if ?cycles >= 23
					.def ?cycles = ?cycles - 23
					jsr		delay23
				.endif
				.if ?cycles >= 22
					.def ?cycles = ?cycles - 22
					jsr		delay22
				.endif
				.if ?cycles >= 21
					.def ?cycles = ?cycles - 21
					jsr		delay21
				.endif
				.if ?cycles >= 20
					.def ?cycles = ?cycles - 20
					jsr		delay20
				.endif
				.if ?cycles >= 19
					.def ?cycles = ?cycles - 19
					jsr		delay19
				.endif
				.if ?cycles >= 18
					.def ?cycles = ?cycles - 18
					jsr		delay18
				.endif
				.if ?cycles >= 17
					.def ?cycles = ?cycles - 17
					jsr		delay17
				.endif
				.if ?cycles >= 16
					.def ?cycles = ?cycles - 16
					jsr		delay16
				.endif
				.if ?cycles >= 15
					.def ?cycles = ?cycles - 15
					jsr		delay15
				.endif
				.if ?cycles >= 14
					.def ?cycles = ?cycles - 14
					jsr		delay14
				.endif
				;12 cycles we can hit exactly
				.if ?cycles == 12
					.def ?cycles = ?cycles - 12
					jsr		delay12
				.endif
				;At this point we have 2-11 or 13 cycles, which we handle through combinations of
				;nop + jmp to avoid changing any state. This can take up to 4 JMPs and two NOPs.
				.if ?cycles > 4 || ?cycles == 3
					.def ?cycles = ?cycles - 3
					jmp		*+3
				.endif
				.if ?cycles > 4 || ?cycles == 3
					.def ?cycles = ?cycles - 3
					jmp		*+3
				.endif
				.if ?cycles > 4 || ?cycles == 3
					.def ?cycles = ?cycles - 3
					jmp		*+3
				.endif
				.if ?cycles > 4 || ?cycles == 3
					.def ?cycles = ?cycles - 3
					jmp		*+3
				.endif
				.if ?cycles == 4
					nop
					nop
				.elseif ?cycles == 2
					nop
				.elseif ?cycles != 0
					.error "Internal error" c' '
				.endif
			.endm
			;==========================================================================
			; POKEY timer timing tests
			;
			; Many timings are given below in the form XX/YY where XX and YY are cycles
			; after a write to STIMER. They indicate a tight cycle count bound for when
			; an event occurs. For instance, 15c/16c for IRQST bit 0 means that IRQST
			; bit 0 is deasserted (1) when read 15 cycles after the cycle on which
			; STIMER is written, and asserted (0) when read 16 cycles after. Thus, the
			; second number indicates the first cycle on which the change is visible.
			; These are also the two cycle offsets at which the test checks to
			; precisely check the cycle delay.
			;
			; *extrapolated means timing values that are not directly measured due to
			; difficulty, i.e. 6502 not fast enough, but are inferred from the measured
			; cases.
			;
				org		$2000
		.nowarn .proc main
				_INITTEST c"POKEY: Timer timing"
					;turn interrupts off
			jsr		_screenOff
			jsr		_interruptsOff
					;set timer 1 for 1.79MHz
		mva		#$40 audctl
		mva		#$10 audf1
		mva		#$00 audf2
					;====== 8-bit timer IRQST tests ===================================
					; Checks the cycle at which the IRQ bit is asserted in IRQST.
					; A/B values are cycles after STIMER write before/after bit 0 is
					; cleared for timer 1.
					;
					;			IRQST1		IRQST2
					; AUDF1=0	 7c/ 8c		11c/12c		*extrapolated
					; AUDF1=16	23c/24c		43c/44c
					;
					;------------------------------------------------------------------
					;check for early 1.79MHz 8-bit timer
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
		mva		#$01 irqen
				_DELAY_CYCLES_X 19-12
			lda		irqst
			and		#$01
				_ASSERTA $01, c"1.79MHz 8-bit timer triggered too early (loop #1)."
					;------------------------------------------------------------------
					;check for late 1.79MHz 8-bit timer
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
		mva		#$01 irqen
				_DELAY_CYCLES_X 20-12
			lda		irqst
			and		#$01
				_ASSERTA $00, c"1.79MHz 8-bit timer triggered too late (loop #1)."
					;------------------------------------------------------------------
					;check for early 1.79MHz 8-bit timer (loop 2)
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
				_DELAY_CYCLES_X 12
		mva		#$01 irqen
				_DELAY_CYCLES_X 39-24
			lda		irqst
			and		#$01
				_ASSERTA $01, c"1.79MHz 8-bit timer triggered too early (loop #2)."
					;------------------------------------------------------------------
					;check for late 1.79MHz 8-bit timer (loop 2)
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
				_DELAY_CYCLES_X 12
		mva		#$01 irqen
				_DELAY_CYCLES_X 40-24
			lda		irqst
			and		#$01
				_ASSERTA $00, c"1.79MHz 8-bit timer triggered too late (loop #2)."
					;====== 16-bit timer tests ========================================
					; Checks the cycle at which the IRQ bit is asserted in IRQST.
					; A/B values are cycles after STIMER write before/after bit 0/1 is
					; cleared for timer 1/2. In general, the timer 1 values are similar
					; to the 8-bit case except for the additional 3 cycles on the
					; period, and the timer 2 values lag the timer 1 values by 3 cycles.
					;
					;					IRQST1		IRQST2
					; AUDF=$0000 T1		 7c/ 8c		14c/15c		*extrapolated
					; AUDF=$0000 T2		10c/11c		17c/18c		*extrapolated
					; AUDF=$0010 T1		23c/24c		43c/44c
					; AUDF=$0010 T2		26c/27c		46c/47c
					;
					;switch to linked timers
		mva		#$50 audctl
					;------------------------------------------------------------------
					;check for early 1.79MHz 16-bit lo timer
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
		mva		#$01 irqen
				_DELAY_CYCLES_X 19-12
			lda		irqst
			and		#$01
				_ASSERTA $01, c"1.79MHz 16-bit lo timer triggered too early (loop #1)."
					;------------------------------------------------------------------
					;check for late 1.79MHz 16-bit lo timer
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
		mva		#$01 irqen
				_DELAY_CYCLES_X 20-12
			lda		irqst
			and		#$01
				_ASSERTA $00, c"1.79MHz 16-bit lo timer triggered too late (loop #1)."
					;------------------------------------------------------------------
					;check for early 1.79MHz 16-bit lo timer (loop 2)
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
				_DELAY_CYCLES_X 15
		mva		#$01 irqen
				_DELAY_CYCLES_X 42-27
			lda		irqst
			and		#$01
				_ASSERTA $01, c"1.79MHz 16-bit lo timer triggered too early (loop #2)."
					;------------------------------------------------------------------
					;check for late 1.79MHz 16-bit lo timer (loop 2)
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
				_DELAY_CYCLES_X 15
		mva		#$01 irqen
				_DELAY_CYCLES_X 43-27
			lda		irqst
			and		#$01
				_ASSERTA $00, c"1.79MHz 16-bit lo timer triggered too late (loop #2)."
					;------------------------------------------------------------------
					;check for early 1.79MHz 16-bit hi timer
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
		mva		#$02 irqen
				_DELAY_CYCLES_X 22-12
			lda		irqst
			and		#$02
				_ASSERTA $02, c"1.79MHz 16-bit hi timer triggered too early (loop #1)."
					;------------------------------------------------------------------
					;check for late 1.79MHz 16-bit hi timer
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
		mva		#$02 irqen
				_DELAY_CYCLES_X 23-12
			lda		irqst
			and		#$02
				_ASSERTA $00, c"1.79MHz 16-bit hi timer triggered too late (loop #1)."
					;------------------------------------------------------------------
					;check for early 1.79MHz 16-bit hi timer (loop 2)
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
				_DELAY_CYCLES_X 21
		mva		#$02 irqen
				_DELAY_CYCLES_X 45-33
			lda		irqst
			and		#$02
				_ASSERTA $02, c"1.79MHz 16-bit hi timer triggered too early (loop #2)."
					;------------------------------------------------------------------
					;check for late 1.79MHz 16-bit hi timer (loop 2)
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen
				_DELAY_CYCLES_X 21
		mva		#$02 irqen
				_DELAY_CYCLES_X 46-33
			lda		irqst
			and		#$02
				_ASSERTA $00, c"1.79MHz 16-bit hi timer triggered too late (loop #2)."
					;====== 8-bit timer reprogramming tests ===========================
					; AUDF1 setting is $10, for a period of $14 (20) cycles. We are
					; testing for the last cycle where AUDF1 can be changed to $12
					; without raising the period of the next cycle to 22 cycles.
					;
					; The timing verified by the below is as follows:
					;
					; - Writes to AUDF1 up to 18 cycles after write to STIMER do affect
					;   the second loop and cause IRQST bit 1 to assert 2 cycles
					;   later starting at 46 cycles past STIMER (4 + 20 + 22).
					;
					; - Writes to AUDF1 at 19 cycles after write to STIMER do not affect
					;   the second loop and cause IRQST bit 1 to assert starting at
					;   44 cycles past STIMER (4 + 20 + 20).
					;
					; Timing:
					;
					;	          1         2         3         4         5        6
					;	012345678901234567890123456789012345678901234567890123456789
					;	S F                   F I                   1 2
					;
					;	S = write to STIMER with AUDF1=$10
					;	F = last cycle AUDF1 can be written to affect next period
					;	I = 1st cycle IRQST[0]=0 for first period (22c)
					;	1 = 1st cycle IRQST[0]=0 for second period when AUDF1=$12 written <=22c
					;	2 = 1st cycle IRQST[0]=0 for second period when AUDF1=$12 not changed <=22c
					;
					; AUDF1=0		 6c/ 7c		*extrapolated
					; AUDF1=16		22c/23c
					;
					;set timer 1 for 1.79MHz
		mva		#$40 audctl
			ldy		#$12
					;------------------------------------------------------------------
					;check for early 1.79MHz 8-bit timer
		mva		#$10 audf1
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60			;104-49
			sta		stimer				; 50-53
		mva		#0 irqen			; 54-59   + 6c past STIMER write
		mvx		#$01 irqen			; 60-65   +12c
				_DELAY_CYCLES_X 6			; 66-71   +18c
			sty		audf1				; 72-75   +22c (written in time to affect second period)
			sta		irqen				; 76-79   +26c
			stx		irqen				; 80-83   +30c
				_DELAY_CYCLES_X 11			; 84-94   +41c
			lda		irqst				; 95-98   +45c (should be last cycle not fired)
			and		#$01
				_ASSERTA $01, c"1.79MHz 8-bit timer fired too early after 22c change (<46c)."
					;------------------------------------------------------------------
					;check for late 1.79MHz 8-bit timer
		mva		#$10 audf1
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write
		mvx		#$01 irqen			;+12c
				_DELAY_CYCLES_X 6			;+18c
			sty		audf1				;+22c (written in time to affect second period)
			sta		irqen				;+26c
			stx		irqen				;+30c
				_DELAY_CYCLES_X 12			;+42c
			lda		irqst				;+46c (should be first cycle fired)
			and		#$01
				_ASSERTA $00, c"1.79MHz 8-bit timer fired too late after 22c change (>46c)."
					;------------------------------------------------------------------
					; Check for early 1.79MHz 8-bit timer.
					;
					; If this test fails, either the IRQ is asserting too early, or
					; the change to AUDF1 is taking effect too late.
					;
		mva		#$10 audf1
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write
		mvx		#$01 irqen			;+12c
				_DELAY_CYCLES_X 7			;+19c
			sty		audf1				;+23c (written too late to affect second period)
			sta		irqen				;+27c
			stx		irqen				;+31c
				_DELAY_CYCLES_X 8			;+39c
			lda		irqst				;+43c (should be last cycle not fired)
			and		#$01
				_ASSERTA $01, c"1.79MHz 8-bit timer fired too early after 23c change (<44c)."
					;------------------------------------------------------------------
					; Check for late 1.79MHz 8-bit timer after late change.
					;
					; If this test fails, either the IRQ is asserting too late, or
					; the change to AUDF1 is taking effect too soon.
					;
		mva		#$10 audf1
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write
		mvx		#$01 irqen			;+12c
				_DELAY_CYCLES_X 7			;+19c
			sty		audf1				;+23c (written too late to affect second period)
			sta		irqen				;+27c
			stx		irqen				;+31c
				_DELAY_CYCLES_X 9			;+40c
			lda		irqst				;+44c (should be first cycle fired)
			and		#$01
				_ASSERTA $00, c"1.79MHz 8-bit timer fired too late after 23c change (>44c)."
					;====== 16-bit lo timer reprogramming tests========================
					; AUDF1/2 setting is $000D, for a period of 13 + 7 = 20 cycles. We
					; are testing for the last cycle where AUDF1 can be changed to $0F
					; without raising the period of the next cycle to 22 cycles.
					;
					; The timing verified by the below is as follows:
					;
					; - Writes to AUDF1 up to 18 cycles after write to STIMER do affect
					;   the second loop and cause IRQST bit 1 to assert 2 cycles
					;   later starting at 43 cycles past STIMER (1 + 20 + 22).
					;
					; - Writes to AUDF1 at 19 cycles after write to STIMER do not
					;   affect the first two loops and cause IRQST bit 1 to assert
					;   starting at 41 cycles past STIMER (1 + 20 + 20). This is 3
					;   cycles before IRQST bit 2.
					;
					; The IRQST bit 1 timing is the same from the start of each loop
					; as for an unlinked 8-bit timer given equivalent AUDF1 values,
					; but 3 cycles earlier here because AUDF1 is set 3 lower here to
					; account for the extra linked timer delay. The deadline timing
					; for writes to AUDF1 is the same as unlinked from the END of the
					; loop, presumably due to the late reset from channel 2.
					;
					; AUDF1=0	 9c/10c		*extrapolated
					; AUDF1=13	22c/23c
					;
		mva		#$50 audctl
			ldy		#$0f
					;------------------------------------------------------------------
					;lower bound 1.79MHz 16-bit lo IRQST timing, latest AUDF1 write to take effect
		mva		#$0d audf1
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write
		mvx		#$01 irqen			;+12c
				_DELAY_CYCLES_X 6			;+18c
			sty		audf1				;+22c
			sta		irqen				;+26c
			stx		irqen				;+30c
				_DELAY_CYCLES_X 8			;+38c
			lda		irqst				;+42c (should be last cycle not fired)
			and		#$01
				_ASSERTA $01, c"1.79MHz 16-bit lo timer fired too early after 22c change (<43c)."
					;------------------------------------------------------------------
					;upper bound 1.79MHz 16-bit lo IRQST timing, latest AUDF1 write to take effect
		mva		#$0d audf1
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write
		mvx		#$01 irqen			;+12c
				_DELAY_CYCLES_X 6			;+18c
			sty		audf1				;+22c
			sta		irqen				;+26c
			stx		irqen				;+30c
				_DELAY_CYCLES_X 9			;+39c
			lda		irqst				;+43c (should be first cycle fired)
			and		#$01
				_ASSERTA $00, c"1.79MHz 16-bit lo timer fired too late after 22c change (>43c)."
					;------------------------------------------------------------------
					;lower bound 1.79MHz 16-bit lo IRQST timing, earliest AUDF1 write to be too late
		mva		#$0d audf1
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write
		mvx		#$01 irqen			;+12c
				_DELAY_CYCLES_X 7			;+19c
			sty		audf1				;+23c
			sta		irqen				;+27c
			stx		irqen				;+31c
				_DELAY_CYCLES_X 5			;+36c
			lda		irqst				;+40c (should be last cycle not fired)
			and		#$01
				_ASSERTA $01, c"1.79MHz 16-bit lo timer fired too early after 23c change (<41c)."
					;------------------------------------------------------------------
					;upper bound 1.79MHz 16-bit lo IRQST timing, earliest AUDF1 write to be too late
		mva		#$0d audf1
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write
		mvx		#$01 irqen			;+12c
				_DELAY_CYCLES_X 7			;+19c
			sty		audf1				;+23c
			sta		irqen				;+27c
			stx		irqen				;+31c
				_DELAY_CYCLES_X 6			;+37c
			lda		irqst				;+41c (should be first cycle fired)
			and		#$01
				_ASSERTA $00, c"1.79MHz 16-bit lo timer fired too late after 23c change (>41c)."
					;====== 16-bit hi timer reprogramming tests========================
					; AUDF1/2 setting is $000D, for a period of 13 + 7 = 20 cycles. We
					; are testing for the last cycle where AUDF2 can be changed to $01
					; without raising the period of the next cycle to 276 cycles.
					;
					; The timing verified by the below is as follows:
					;
					; - Writes to AUDF2 up to 18 cycles after write to STIMER do affect
					;   the second loop and cause IRQST bit 2 to assert 256 cycles
					;   later starting at 300 cycles past STIMER (4 + 20 + 276).
					;
					; - Writes to AUDF2 at 19 cycles after write to STIMER do not
					;   affect the first two loops and cause IRQST bit 2 to assert
					;   starting at 44 cycles past STIMER (4 + 20 + 20). This is 3 cycles
					;   after IRQST bit 1.
					;
					; AUDF1=0	 9c/10c		*extrapolated
					; AUDF1=13	22c/23c
		mva		#$50 audctl
		mva		#$0d audf1
			ldy		#$01
					;------------------------------------------------------------------
					;lower bound 1.79MHz 16-bit hi IRQST timing, latest AUDF2 write to take effect
		mva		#$00 audf2
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write
		mvx		#$02 irqen			;+12c
				_DELAY_CYCLES_X 6			;+18c
			sty		audf2				;+22c
			sta		irqen				;+26c
			stx		irqen				;+30c
				_DELAY_CYCLES_X 247			;+295c (+18c from refresh cycles)
			lda		irqst				;+299c (should be last cycle not fired)
			and		#$02
				_ASSERTA $02, c"1.79MHz 16-bit hi timer fired too early after 24c change (<300c)."
					;------------------------------------------------------------------
					;upper bound 1.79MHz 16-bit hi IRQST timing, latest AUDF2 write to take effect
		mva		#$00 audf2
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60			;cycle 104-58 (skip 9 refresh cycles)
			sta		stimer				;cycles 59-63
		mva		#0 irqen			;+ 6c past STIMER write for last cycle
		mvx		#$02 irqen			;+12c
				_DELAY_CYCLES_X 6			;+18c
			sty		audf2				;+22c
			sta		irqen				;+26c
			stx		irqen				;+30c
				_DELAY_CYCLES_X 248			;+296c (+18c from refresh cycles)
			lda		irqst				;+300c (should be first cycle fired)
			and		#$02
				_ASSERTA $00, c"1.79MHz 16-bit hi timer fired too late after 22c change (>300c)."
					;------------------------------------------------------------------
					;lower bound 1.79MHz 16-bit hi IRQST timing, earliest AUDF2 write to be too late
		mva		#$00 audf2
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write for last cycle
		mvx		#$02 irqen			;+12c
				_DELAY_CYCLES_X 7			;+19c
			sty		audf2				;+23c
			sta		irqen				;+27c
			stx		irqen				;+31c
				_DELAY_CYCLES_X 8			;+39c
			lda		irqst				;+43c (should be last cycle not fired)
			and		#$02
				_ASSERTA $02, c"1.79MHz 16-bit hi timer fired too early after 22c change (<44c)."
					;------------------------------------------------------------------
					;upper bound 1.79MHz 16-bit hi IRQST timing, earliest AUDF2 write to be too late
		mva		#$00 audf2
			sta		wsync
			sta		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
		mva		#0 irqen			;+ 6c past STIMER write for last cycle
		mvx		#$02 irqen			;+12c
				_DELAY_CYCLES_X 7			;+19c
			sty		audf2				;+23c
			sta		irqen				;+27c
			stx		irqen				;+31c
				_DELAY_CYCLES_X 9			;+40c
			lda		irqst				;+44c (should be first cycle fired)
			and		#$02
				_ASSERTA $00, c"1.79MHz 16-bit hi timer fired too late after 25c change (>44c)."
					;====== 8-bit STIMER preemption tests =============================
					;Checks for the last cycle that STIMER can be strobed to prevent
					;the timer from firing.
					;
					;			STIMER1		STIMER2
					; AUDF1=0	 4c/ 5c		 8c/ 9c		*extrapolated
					; AUDF1=8	12c/13c		24c/25c
					;
		mva		#$40 audctl
		mva		#8 audf1
			lda		#0
			ldx		#1
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 4		;+7c
			sta		stimer			;+12c
				_DELAY_CYCLES_X 4
			lda		irqst
			and		#1
				_ASSERTA $01, c"STIMER did not preempt AUDF1=8 at +12c.",0
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 5		;+8c
			sta		stimer			;+13c
				_DELAY_CYCLES_X 4
			lda		irqst
			and		#1
				_ASSERTA $00, c"STIMER should not have preempted AUDF1=8 at +13c.",0
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 12		;+12c
			stx		irqen			;+16c
				_DELAY_CYCLES_X 4		;+20c
			sta		stimer			;+24c
				_DELAY_CYCLES_X 4
			lda		irqst
			and		#1
				_ASSERTA $01, c"STIMER did not preempt AUDF1=8 at +24c.",0
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 12		;+12c
			stx		irqen			;+16c
				_DELAY_CYCLES_X 5		;+21c
			sta		stimer			;+25c
				_DELAY_CYCLES_X 4
			lda		irqst
			and		#1
				_ASSERTA $00, c"STIMER should not have preempted AUDF1=8 at +25c.",0
					;====== two-tone test prep ========================================
					;
					; We need to use timer 1 for 8-bit two tone tests to have access
					; to the 1.79MHz clock, but there is no direct way to reset the
					; serial output state, which is not affected by init mode or
					; serial reset (they can halt the shifter, but not clear it).
					; Therefore, we need to push a byte through to ensure that the
					; shifter has completed the stop bit, and therefore output a 1.
					; After that, we can use force break to get a 0 as needed.
			ldy		#0
			sty		skctl			;reset serial port as much as we can
			sty		audf3
			sty		audf4
			sty		irqen
		mva		#$23 skctl		;ch4 transmit synchronous
		mva		#$28 audctl		;ch3+4 linked 1.79MHz
		mva		#$18 irqen		;serial output ready + complete
			sty		serout			;write dummy byte (~140-153 cycles)
			sta		wsync
			sta		wsync
			sta		wsync
			lda		irqst
			and		#$18
				_ASSERTA $00, c"Unable to reset serial output for 2tn tests.",0
					;====== 8-bit two-tone timer 1 IRQST tests ========================
					;
					; IRQST is set at the same time for the first period after STIMER.
					; Second and subsequent periods are two cycles longer.
					;
					; AUDF1=0	 7c/ 8c		13c/14c		*extrapolated
					; AUDF1=8	15c/16c		29c/30c
					;
		mva		#0 skctl
		mva		#$40 audctl
		mva		#$0b skctl
		mva		#8 audf1
		mva		#$ff audf2
			sta		stimer
			lda		#0
			ldx		#$ff
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 7		;+11c
			ldy		irqst			;+15c
			sta		irqen			;+19c
			stx		irqen			;+23c
				nop						;+25c
			lda		irqst			;+29c
				lsr
				tya
			and		#1
			bne		ttn_ok1
				_FAIL	c"AUDF1=8 timer 1 2tn should not have been set at +15c.",0
		ttn_ok1:
			bcs		ttn_ok2
				_FAIL	c"AUDF1=8 timer 1 2tn should not have been set at +29c.",0
		ttn_ok2:
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 8		;+12c
			ldy		irqst			;+16c
			sta		irqen			;+20c
			stx		irqen			;+24c
				nop						;+26c
			lda		irqst			;+30c
				lsr
				tya
			and		#1
			beq		ttn_ok3
				_FAIL	c"AUDF1=8 timer 1 2tn should have been set at +16c.",0
		ttn_ok3:
			bcc		ttn_ok4
				_FAIL	c"AUDF1=8 timer 1 2tn should have been set at +30c.",0
		ttn_ok4:
					;====== 8-bit two-tone timer 1 reprogramming tests ================
					;Changes AUDF1 on the fly in 8-bit two-tone mode and measure
					;the last cycle on which we can affect the timing of the next IRQ.
					;
					;				AUDF1*1		AUDF1*2
					; AUDF1=0		 8c/ 9c		14c/15c		*extrapolated
					; AUDF1=8		16c/17c		30c/31c
					; AUDF1=10		18c/19c		34c/35c
					;
		mva		#$40 audctl
		mva		#$0b skctl
		mvx		#$ff audf2
			ldy		#0
		mva		#8 audf1
			sty		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 12		;+12c
			stx		audf1			;+16c
				_DELAY_CYCLES_X 6		;+22c
			stx		irqen			;+26c
			lda		irqst			;+30c
				lsr
			bcs		ttnrp_ok1
				_FAIL	c"AUDF1=8 timer 1 2tn refreq should have succeeded at +16c.",0
		ttnrp_ok1:
		mva		#8 audf1
			sty		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 13		;+13c
			stx		audf1			;+17c
				_DELAY_CYCLES_X 5		;+22c
			stx		irqen			;+26c
			lda		irqst			;+30c
				lsr
			bcc		ttnrp_ok2
				_FAIL	c"AUDF1=8 timer 1 2tn refreq should not have succeeded at +17c.",0
		ttnrp_ok2:
		mva		#8 audf1
			sty		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 26		;+26c
			stx		audf1			;+30c
				_DELAY_CYCLES_X 8		;+38c
			stx		irqen			;+42c
			lda		irqst			;+46c
				lsr
			bcs		ttnrp_ok3
				_FAIL	c"AUDF1=8 timer 1 2tn refreq should have succeeded at +30c.",0
		ttnrp_ok3:
		mva		#8 audf1
			sty		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 27		;+27c
			stx		audf1			;+31c
				_DELAY_CYCLES_X 7		;+38c
			stx		irqen			;+42c
			lda		irqst			;+46c
				lsr
			bcc		ttnrp_ok4
				_FAIL	c"AUDF1=8 timer 1 2tn refreq should not have succeeded at +31c.",0
		ttnrp_ok4:
		mva		#10 audf1
			sty		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 14		;+14c
			stx		audf1			;+18c
				_DELAY_CYCLES_X 8		;+26c
			stx		irqen			;+30c
			lda		irqst			;+34c
				lsr
			bcs		ttnrp_ok5
				_FAIL	c"AUDF1=10 timer 1 2tn refreq should have succeeded at +18c.",0
		ttnrp_ok5:
		mva		#10 audf1
			sty		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 15		;+15c
			stx		audf1			;+19c
				_DELAY_CYCLES_X 7		;+26c
			stx		irqen			;+30c
			lda		irqst			;+34c
				lsr
			bcc		ttnrp_ok6
				_FAIL	c"AUDF1=10 timer 1 2tn refreq should not have succeeded at +19c.",0
		ttnrp_ok6:
		mva		#10 audf1
			sty		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 30		;+30c
			stx		audf1			;+34c
				_DELAY_CYCLES_X 10		;+44c
			stx		irqen			;+48c
			lda		irqst			;+52c
				lsr
			bcs		ttnrp_ok7
				_FAIL	c"AUDF1=10 timer 1 2tn refreq should have succeeded at +34c.",0
		ttnrp_ok7:
		mva		#10 audf1
			sty		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 31		;+31c
			stx		audf1			;+35c
				_DELAY_CYCLES_X 9		;+44c
			stx		irqen			;+48c
			lda		irqst			;+52c
				lsr
			bcc		ttnrp_ok8
				_FAIL	c"AUDF1=10 timer 1 2tn refreq should not have succeeded at +35c.",0
		ttnrp_ok8:
					;====== 8-bit two-tone timer 1 STIMER preemption tests ==============
					;Measures the last cycle on which STIMER can be strobed to affect
					;the timing of the next IRQ.
					;
					;			AUDF1*2		AUDF1*3
					; AUDF1=0	10c/11c		16c/17c		*extrapolated
					; AUDF1=8	26c/27c		40c/41c
					; AUDF1=10	30c/31c		46c/47c
		mva		#$40 audctl
		mva		#$0b skctl
		mva		#$ff audf2
			lda		#0
			ldx		#$ff
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			stx		audf1			;set long period to establish IRQ safe window
			sta		stimer			;reset timer 1
			stx		irqen			;enable timer 1 IRQ
			sta		audf1			;change period to 0
			sta		stimer			;reset timers
			sta		stimer			;+4c
			lda		irqst			;+8c
				lsr
			bcs		ttnst_ok0a
				_FAIL	c"AUDF1=0 timer 1 2tn STIMER should not have worked at +4c.",0
		ttnst_ok0a:
		mva		#8 audf1
			lda		#0
			ldx		#$ff
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 10		;+14c
			sta		irqen			;+18c	IRQ asserts at +16c, recleared here
			stx		irqen			;+22c
			sta		stimer			;+26c
			jmp		*+3				;+29c
			lda		irqst			;+33c	IRQ at +30c suppressed by STIMER
				lsr
			bcs		ttnst_ok1
				_FAIL	c"AUDF1=8 timer 1 2tn STIMER should have worked at +26c.",0
		ttnst_ok1:
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 11		;+15c
			sta		irqen			;+19c	IRQ asserts at +16c, recleared here
			stx		irqen			;+23c
			sta		stimer			;+27c
				nop						;+29c
			lda		irqst			;+33c	IRQ at +30c asserted
				lsr
			bcc		ttnst_ok3
				_FAIL	c"AUDF1=8 timer 1 2tn STIMER should not have worked at +27c.",0
		ttnst_ok3:
			lda		#0
			ldx		#$ff
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 32		;+32c	IRQ at +30c suppressed by IRQST=0
			stx		irqen			;+36c
			sta		stimer			;+40c
			jmp		*+3				;+43c
			lda		irqst			;+47c	IRQ at +44c suppressed by STIMER
				lsr
			bcs		ttnst_ok2
				_FAIL	c"AUDF1=8 timer 1 2tn STIMER should have worked at +40c.",0
		ttnst_ok2:
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 33		;+33c
			stx		irqen			;+37c
			sta		stimer			;+41c
				nop						;+43c
			lda		irqst			;+47c	IRQ at +44c asserted
				lsr
			bcc		ttnst_ok4
				_FAIL	c"AUDF1=8 timer 1 2tn STIMER should not have worked at +41c.",0
		ttnst_ok4:
		mva		#10 audf1
			lda		#0
			ldx		#$ff
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 22		;+22c
			stx		irqen			;+26c
			sta		stimer			;+30c
			jmp		*+3				;+33c
			lda		irqst			;+37c
				lsr
			bcs		ttnst_ok5
				_FAIL	c"AUDF1=10 timer 1 2tn STIMER should have worked at +30c.",0
		ttnst_ok5:
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 23		;+23c
			stx		irqen			;+27c
			sta		stimer			;+31c
				nop						;+33c
			lda		irqst			;+37c
				lsr
			bcc		ttnst_ok6
				_FAIL	c"AUDF1=10 timer 1 2tn STIMER should not have worked at +31c.",0
		ttnst_ok6:
			lda		#0
			ldx		#$ff
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 38		;+38c
			stx		irqen			;+42c
			sta		stimer			;+46c
			jmp		*+3				;+49c
			lda		irqst			;+53c
				lsr
			bcs		ttnst_ok7
				_FAIL	c"AUDF1=10 timer 1 2tn STIMER should have worked at +46c.",0
		ttnst_ok7:
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
				_DELAY_CYCLES_X 39		;+39c
			stx		irqen			;+43c
			sta		stimer			;+47c
				nop						;+49c
			lda		irqst			;+53c
				lsr
			bcc		ttnst_ok8
				_FAIL	c"AUDF1=10 timer 1 2tn STIMER should not have worked at +47c.",0
		ttnst_ok8:
					;====== 16-bit two-tone timer 2 0-bit IRQST tests ==================
					;Measure IRQST timing for two-tone, 16-bit linked 1.79MHz with force
					;break activated (resync 1+2 triggered only by timer 2).
					;
					; AUDF1=0	Timer1	 7c/ 8c		16c/17c		*extrapolated
					; AUDF1=0	Timer2	10c/11c		19c/20c		*extrapolated
					; AUDF1=8	Timer1	15c/16c		32c/33c
					; AUDF1=8	Timer2	18c/19c		35c/36c
		mva		#$50 audctl
		mva		#$8b skctl
		mva		#8 audf1
		mva		#0 audf2
			lda		#0
			ldx		#$ff
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 10		;+14c
			ldy		irqst			;+18c
			sta		irqen			;+22c
			stx		irqen			;+26c
				nop						;+28c
			jmp		*+3				;+31c
			lda		irqst			;+35c
				lsr
				lsr
				tya
			and		#2
			bne		ttn16t2b0_ok1
				_FAIL	c"AUDF1+2=8 timer 2 2tn 0b should not have been set at +18c.",0
		ttn16t2b0_ok1:
			bcs		ttn16t2b0_ok2
				_FAIL	c"AUDF1+2=8 timer 2 2tn 0b should not have been set at +35c.",0
		ttn16t2b0_ok2:
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 11		;+15c
			ldy		irqst			;+19c
			sta		irqen			;+23c
			stx		irqen			;+27c
				nop						;+29c
			jmp		*+3				;+32c
			lda		irqst			;+36c
				lsr
				lsr
				tya
			and		#2
			beq		ttn16t2b0_ok3
				_FAIL	c"AUDF1+2=8 timer 2 2tn 0b should have been set at +19c.",0
		ttn16t2b0_ok3:
			bcc		ttn16t2b0_ok4
				_FAIL	c"AUDF1+2=8 timer 2 2tn 0b should have been set at +36c.",0
		ttn16t2b0_ok4:
			lda		#0
			ldx		#$ff
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 7		;+11c
			ldy		irqst			;+15c
			sta		irqen			;+19c
			stx		irqen			;+23c
				nop						;+25c
			jmp		*+3				;+28c
			lda		irqst			;+32c
				lsr
				tya
			and		#1
			bne		ttn16t1b0_ok1
				_FAIL	c"AUDF1+2=8 timer 1 2tn 0b should not have been set at +15c.",0
		ttn16t1b0_ok1:
			bcs		ttn16t1b0_ok2
				_FAIL	c"AUDF1+2=8 timer 1 2tn 0b should not have been set at +32c.",0
		ttn16t1b0_ok2:
			lda		#0
			sta		irqen
			inc		wsync
				_DELAY_CYCLES_X 60
			sta		stimer
			stx		irqen			;+4c
				_DELAY_CYCLES_X 8		;+12c
			ldy		irqst			;+16c
			sta		irqen			;+20c
			stx		irqen			;+24c
				nop						;+26c
			jmp		*+3				;+29c
			lda		irqst			;+33c
				lsr
				tya
			and		#1
			beq		ttn16t1b0_ok3
				_FAIL	c"AUDF1+2=8 timer 1 2tn 0b should have been set at +16c.",0
		ttn16t1b0_ok3:
			bcc		ttn16t1b0_ok4
				_FAIL	c"AUDF1+2=8 timer 1 2tn 0b should have been set at +33c.",0
		ttn16t1b0_ok4:
					;====== 8-bit two-tone cancellation tests =========================
					;
					;
					;set timer 1 1.79MHz, timer 2 64KHz
		mva		#$40 audctl
					;schedule timer 1 to expire one cycle after timer 2
		mva		#3 audf2		;24+28*3 = 108c after SKCTL write
		mva		#98 audf1		;105c after STIMER write / 109c after SKCTL write
		mva		#0 skctl
			lda		#$8b
			sta		wsync
			sta		wsync
			sta		skctl
			sta		stimer
		mva		#0 irqen
		mva		#3 irqen
			sta		wsync
					;timer 1+2 should fire
			and		irqen
				_ASSERTA 0,	c"Two-tone timer 1 did not fire at +1c from timer 2 w/resync: %x",0
					;schedule timer 1 two cycles after timer 2
		mva		#3 audf2		;24+28*3 = 108c after SKCTL write
		mva		#99 audf1		;106c after STIMER write / 110c after SKCTL write
		mva		#0 skctl
			lda		#$8b
			sta		wsync
			sta		wsync
			sta		skctl
			sta		stimer
		mva		#0 irqen
		mva		#3 irqen
			sta		wsync
					;only timer 2 should fire
			and		irqen
				_ASSERTA 1, c"Two-tone timer 1 should not have fired at +2c from timer 2 w/resync: %x",0
					;schedule timer 1 three cycles after timer 2
		mva		#3 audf2		;24+28*3 = 108c after SKCTL write
		mva		#100 audf1		;107c after STIMER write / 111c after SKCTL write
		mva		#0 skctl
			lda		#$8b
			sta		wsync
			sta		wsync
			sta		skctl
			sta		stimer
		mva		#0 irqen
		mva		#1 irqen
			sta		wsync
					;only timer 2 should fire
			and		irqen
				_ASSERTA 1, c"Two-tone timer 1 did not fire at +3c from timer 2 w/resync: %x",0
					;====== all done ==================================================
			jmp		_testPassed
			.endp
		delay660:
			jsr		delay252
		delay408:
			jsr		delay156
		delay252:
			jsr		delay96
		delay156:
			jsr		delay60
		delay96:
			jsr		delay36
		delay60:
			jsr		delay24
		delay36:
			jsr		delay12
		delay24:
			jsr		delay12
		delay12:
				rts
		delay22:
				nop
		delay20:
				nop
		delay18:
				nop
		delay16:
				nop
		delay14:
				nop
				rts
		delay23:
				nop
		delay21:
				nop
		delay19:
				nop
		delay17:
				nop
		delay15:
			jmp		*+3
				rts
			run		$2000
					end
