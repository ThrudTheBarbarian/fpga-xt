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
				_SAP_HEADER "POKEY: Serial output complete IRQ"
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
					;enable the SEROC interrupt (note that we have IRQs masked)
		mva		#$08 irqen
					;SEROC bit should be set, since SIO has long completed
			lda		irqst
			and		#$08
				_ASSERTA $00, c"SEROC IRQ was not set when enabled."
					;SEROC is special and should be set even when disabled
		mva		#0 irqen
			lda		irqst
			and		#$08
				_ASSERTA $00, c"SEROC IRQ was not set when disabled."
					;Re-enable SEROC and check that we can force an immediate IRQ.
	mwa		#irq vimirq
			mva		#0 d0
				cli
		mva		#$08 irqen
			ldx		#0
			dex:rne
				sei
				_ASSERT1 d0, $ff, c"SEROC IRQ did not fire."
			jmp		_testPassed
		.proc irq
				pha
			mva		#$ff d0
		mva		#0 irqen
				pla
				rti
			.endp
		testname:
	dta		c"POKEY: Serial output complete IRQ",0
			run		$2000
					end
