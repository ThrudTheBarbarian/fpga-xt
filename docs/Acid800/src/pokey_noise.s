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
				_SAP_HEADER "POKEY: Noise generators"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;kick POKEY into init mode
		mva		#0 skctl
			sta		wsync
			sta		wsync
					;check RANDOM in init mode
			lda		random
				_ASSERTA $ff, 'RANDOM was not $ff in init mode: $%x'
					;set noise generator to short mode and read a byte
		mva		#$80 audctl
			lda		#$03
			inc		wsync
			sta		skctl			;105, 106, 107
			inc		wsync
			lda		random			;105, 106, 107, 108
				_ASSERTA $95, 'Incorrect 9-bit PRNG value: $%x != $95'
		mva		#0 skctl
			sta		wsync
			sta		wsync
		mva		#$00 audctl
			lda		#$03
			inc		wsync
			sta		skctl			;105, 106, 107
			inc		wsync
			lda		random			;108, 109, 110, 111
				_ASSERTA $08, 'Incorrect 17-bit PRNG value: $%x != $08'
					;check for correct values while entering init mode
		mva		#0 skctl
		mva		#$80 audctl
			sta		wsync
			sta		wsync
			lda		#3
			sta		skctl
			sta		wsync
			lda		#0
			sta		skctl
			lda		random
				_ASSERTA $E9, 'Incorrect 9-bit hot-stop value: $%x != $E9'
		mva		#0 skctl
			sta		audctl
			sta		wsync
			sta		wsync
			lda		#3
			sta		skctl
			sta		wsync
			lda		#0
			sta		skctl
			lda		random
				_ASSERTA $F0, 'Incorrect 17-bit hot-stop value: $%x != $F0'
			jmp		_testPassed
					;set noise generator to long mode and read a byte
		testname:
	dta		c"POKEY: Noise generators",0
			run		$2000
					end
