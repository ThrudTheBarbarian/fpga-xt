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
				_SAP_HEADER "POKEY: Address mirroring"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_interruptsOff
					;fire timer 1 IRQ
		mva		#$03 skctl
		mva		#0 audctl
		mva		#0 audc1
		mva		#1 audf1
		mva		#1 irqen
			sta		stimer
	:4 inc wsync
			lda		irqst
			and		#1
				_ASSERTA $00, c"Timer IRQ #1 did not fire."
			lda		irqst+$20
			and		#1
				_ASSERTA $00, c"Mirror IRQST does not show timer 1 IRQ."
					;turn off the IRQ through the mirror and check
		mva		#0 irqen+$20
			inc		wsync
			inc		wsync
			lda		irqst+$20
			and		#1
				_ASSERTA $01, c"Timer 1 IRQ not cleared in mirror IRQST."
					;check normal address
			lda		irqst
			and		#1
				_ASSERTA $01, c"Timer 1 IRQ not cleared in IRQST."
			jmp		_testPassed
		testname:
	dta		c"POKEY: Address mirroring",0
			run		$2000
					end
