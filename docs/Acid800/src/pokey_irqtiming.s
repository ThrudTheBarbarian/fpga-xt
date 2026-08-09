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
				_SAP_HEADER "POKEY: IRQ timing"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
					;turn interrupts off
			jsr		_screenOff
			jsr		_interruptsOff
		mva		#$00 irqen
					;reset serial port to force output complete
		mva		#0 skctl
		mva		#3 skctl
					;revector IRQ and enable interrupts
	mwa		#irq1 vimirq
				cli
			lda		#124
		cmp:rne	vcount
					;====== IRQEN-based IRQ tests =====================================
					;enable seroc and see how long it takes to fire
			lda		#$08
			ldx		#0
			inc		wsync
			pha:pla				;105-111
			pha:pla				;112-4 (113-5)
			pha:pla				;5-10
			pha:pla				;11-17
			pha:pla				;18-24
			pha:pla				;25-34
			pha:pla				;35-43
			pha:pla				;44-52
			pha:pla				;53-61
			sta		irqen
				inx
				inx		;interrupt here
				inx		;...or here
				inx
				inx
				inx
				inx
				inx
				sei
		resume1:
			stx		d0
					;try again, with a one cycle offset
		mva		#0 irqen
	mwa		#irq2 vimirq
				cli
					;enable seroc and see how long it takes to fire
			mva		#1 d1
			lda		#$08
			ldx		#0
			inc		wsync
			pha:pla				;105-111
			pha:pla				;112-4 (113-5)
			pha:pla				;5-10
			pha:pla				;11-17
			pha:pla				;18-24
			pha:pla				;25-34
			pha:pla				;35-43
			pha:pla				;44-52
			pha:pla				;53-61
			sta		irqen
			ldx		d1
				inx		;interrupt here
				inx
				inx
				inx
				inx
				inx
				inx
				sei
		resume2:
			stx		d1
					;check values
					;
					;Note that Ataris vary slightly in their POKEY IRQ latency; my 130XE shows 2
					;cycles whereas my 800XL shows 3. This shows up as a one-level difference in
					;the even value.
			lda		d0
			cmp		#$02
			beq		evenok1
				_ASSERTA $01, c"Incorrect IRQEN delay count (even): $%x",0
		evenok1:
				_ASSERT1 d1, $01, c"Incorrect IRQEN delay count (odd): $%x",0
					;====== timer-based IRQ tests =====================================
					; Here we configure the timer 1 IRQ to 1.79MHz with a period of
					; 12 cycles (AUDF1=8), hit STIMER, and run down an INX sled until
					; the IRQ trips. This is done twice with even and odd cycle offsets
					; to determine the precise timing.
					;
					; Because of hardware variation -- some XEs 1 cycle quicker than
					; some XLs -- one cycle of leeway is given here, allowing the
					; 7-cycle IRQ acknowledge sequence to start 18-19 cycles after the
					; write to STIMER (17-18 cycles in between). This is believed to be
					; related to timing variations in the 6502 chip.
					;
					; Note that IRQST timing, which is tested in the pokey_timertiming
					; test, does NOT show this variation, which consistently shows
					; the same timing for IRQST bit 1 on systems that vary in IRQ
					; timing. The equivalent timing for this test has IRQST bit 1 first
					; asserted at 16 cycles after the STIMER write cycle. Thus, the
					; latency from IRQST to IRQ start is 2-3 cycles. This is also the
					; same as when IRQST bit 3 is manually tripped for SEROC, as tested
					; above.
					;
		mva		#8 audf1
		mva		#$40 audctl
				clv
	mwa		#irq3 vimirq
		mva		#0 irqen
			ldx		#1
			inc		wsync
			jsr		delay60
			stx		stimer
			stx		irqen			;+4c from STIMER write to last cycle
				cli						;+6c
				.pages 1
			bvs		*+2				;+8c
				inx						;+10c
				.endpg
				inx						;+12c
				inx						;+14c
				inx						;+16c
				inx						;+18c
					;----------------------- NTSC 800XL/130XE position
					;						 First cycle of IRQ ack at 19 cycles from STIMER write
				inx
				inx
				inx
				sei
		resume3:
			stx		d0
	mwa		#irq4 vimirq
		mva		#0 irqen
			ldx		#1
			inc		wsync
			jsr		delay60
			stx		stimer
			stx		irqen			;+4c from STIMER write to last cycle
				cli						;+6c
				.pages 1
			bvc		*+2				;+9c
				inx						;+11c
				.endpg
				inx						;+13c
				inx						;+15c
				inx						;+17c
					;----------------------- NTSC 130XE position
					;						 First cycle of IRQ ack at 18 cycles from STIMER write
				inx						;+19c
					;----------------------- NTSC 800XL position
					;						 First cycle of IRQ ack at 20 cycles from STIMER write
				inx
				inx
				inx
				sei
		resume4:
			stx		d1
			lda		d0
				_ASSERTA $06, c"Incorrect timer IRQ delay count (even): $%x",0
					;NTSC 130XE reports $05 here (18 cycles), 800XL reports $06 (19 cycles)
			lda		d1
			cmp		#$06
			beq		oddok2
				_ASSERT1 d1, $05, c"Incorrect timer IRQ delay count (odd): $%x",0
		oddok2:
			jmp		_testPassed
		delay60:
			jsr		delay12
		delay48:
			jsr		delay24
		delay24:
			jsr		delay12
		delay12:
				rts
		irq1:
				pla
				pla
				pla
			jmp		resume1
		irq2:
				pla
				pla
				pla
			jmp		resume2
		irq3:
			:3 pla
			jmp		resume3
		irq4:
			:3 pla
			jmp		resume4
		testname:
	dta		c"POKEY: IRQ timing",0
			run		$2000
					end
