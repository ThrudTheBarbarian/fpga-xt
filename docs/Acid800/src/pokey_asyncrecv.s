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
				_SAP_HEADER "POKEY: Asynchronous receive mode"
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
					;disable asynchronous receive mode on POKEY and check that we can
					;see timer 4 interrupts
		mva		#$03 skctl
		mva		#0 audc4
		mva		#$02 audf4
		mva		#$00 audctl
		mva		#$00 irqen
			sta		stimer
		mva		#$04 irqen
			jsr		checkirq
				_ASSERTA $01, c"Timer #4 IRQ did not fire."
					;clear the interrupt
		mva		#$00 irqen
					;enable asynchronous receive mode on POKEY
		mva		#$13 skctl
					;re-enable the interrupt and see if we can see it; we shouldn't,
					;since POKEY is waiting for a start bit
			sta		stimer
		mva		#$04 irqen
			jsr		checkirq
				_ASSERTA $00, c"Timer #4 IRQ fired with async recv mode active."
					;turn async receive back off and see if timer 4 unlocks
		mva		#$03 skctl
		mva		#0 irqen
			lda		#4
			sta		stimer
			sta		irqen
			jsr		checkirq
				_ASSERTA $01, c"Timer #4 IRQ did not fire after turning async recv back off."
					;link timers 3+4 and set to 456 cycles (four scan lines); we use this slow of
					;a timer for emulators that are scanline granularity
		mva		#$28 audctl
		mva		#<(114*4-7) audf3
		mva		#>(114*4-7) audf4
					;see if we can get timer 4 to skip some cycles
			ldx		#0
			lda		#4
			sta		wsync
			sta		wsync
			sta		stimer
				nop
			stx		irqen
			sta		irqen
			sta		wsync				;stimer + 1 line
			sta		wsync				;stimer + 2 lines
			bit		irqst				;check IRQ
			beq		skiptest_fail1		;IRQ shouldn't be on yet - fail if not
			sta		wsync				;stimer + 3 lines
			sta		wsync				;stimer + 4 lines - IRQ fires ~here
			sta		wsync				;stimer + 5 lines
			bit		irqst				;check IRQ
			bne		skiptest_fail2		;IRQ should be on now - fail if not
			stx		irqen				;clear IRQ
			sta		irqen				;re-enable IRQ
			sta		wsync				;stimer + 6 lines
		mvy		#$13 skctl			;turn asynchronous receive mode on
			sta		wsync				;stimer + 7 lines
			sta		wsync				;stimer + 8 lines
		mvy		#$03 skctl			;turn asynchronous receive mode back off
			sta		wsync				;stimer + 9 lines
			sta		wsync				;stimer + 10 lines
			sta		wsync				;stimer + 11 lines
			bit		irqst				;check IRQ
			beq		skiptest_fail3		;IRQ shouldn't have fired
			sta		wsync				;stimer + 12 lines - IRQ fires ~here
			sta		wsync				;stimer + 13 lines
			bit		irqst				;check IRQ
			bne		skiptest_fail4		;IRQ should have fired
			jmp		_testPassed
		skiptest_fail1:
			ldx		#1
			bne		skiptest_fail
		skiptest_fail2:
			ldx		#2
			bne		skiptest_fail
		skiptest_fail3:
			ldx		#3
			bne		skiptest_fail
		skiptest_fail4:
			ldx		#4
		skiptest_fail:
			stx		d1
				_FAIL	c"Async receive timer 3+4 reset test failed (%d)."
		.proc checkirq
			ldy		#$20
			ldx		#0
		checkloop:
			bit		irqst
			beq		detected
				dex
			bne		checkloop
				dey
			bne		checkloop
				txa
				rts
		detected:
			lda		#1
				rts
			.endp
		testname:
	dta		c"POKEY: Asynchronous receive mode",0
			run		$2000
					end
