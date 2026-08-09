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
				_SAP_HEADER "GTIA: CONSOL test"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
		mva		#$0c consol
			jsr		delay
			lda		consol
			and		#7
			sta		d0
		mva		#$0a consol
			jsr		delay
			lda		consol
			and		#7
			sta		d1
		mva		#$09 consol
			jsr		delay
			lda		consol
			and		#7
			sta		d2
				_ASSERT1 d0, $03, c"CONSOL value #1 bad: $%x != $04"
				_ASSERT1 d1, $05, c"CONSOL value #2 bad: $%x != $02"
				_ASSERT1 d2, $06, c"CONSOL value #3 bad: $%x != $01"
			jmp		_testPassed
		.proc delay
			ldx		#100
		loop:
			inc		wsync
				dex
			bne		loop
				rts
			.endp
		testname:
	dta		c"GTIA: CONSOL test",0
			run		$2000
					end
