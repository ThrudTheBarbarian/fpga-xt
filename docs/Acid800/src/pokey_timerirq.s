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
				_SAP_HEADER "POKEY: Timer IRQs"
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
					;check timer #1 and #2 interrupts; we don't check timer #4 as that is done during
					;the asynchronous receive mode test
		mva		#0 audc1
		mva		#$02 audf1
		mva		#0 audc2
		mva		#$02 audf2
		mva		#$00 audctl
		mva		#$00 irqen
			sta		stimer
		mva		#$01 irqen
			jsr		checkirq
				_ASSERTA $01, c"Timer #1 IRQ did not fire."
					;clear the interrupt
		mva		#$00 irqen
			sta		stimer
		mva		#$02 irqen
			jsr		checkirq
				_ASSERTA $01, c"Timer #2 IRQ did not fire."
					;clear the interrupt
		mva		#$00 irqen
					;set both interrupts on a long delay and make sure we don't get any IRQs within
					;four scan lines
		mva		#$ff audf1
		mva		#$ff audf2
			sta		stimer
		mva		#$03 irqen
			inc		wsync
			inc		wsync
			inc		wsync
			inc		wsync
			lda		irqen
			and		#$03
				_ASSERTA $03, c"Stray timer #1 or #2 IRQs detected."
			jmp		_testPassed
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
	dta		c"POKEY: Timer IRQs",0
			run		$2000
					end
