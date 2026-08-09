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
				_SAP_HEADER "GTIA: P/M retriggering"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
		mva		#$00 gractl
		mva		#$ff grafp0
		mva		#$ff grafp1
		mva		#$ff grafp2
		mva		#$40 hposp0
		mva		#$40 hposp1
		mva		#$b8 hposp2
		mva		#$00 sizep0
		mva		#$00 sizep1
		mva		#$00 sizep2
					;try basic retriggering
			lda		#8
			jsr		_waitVCount
			sta		wsync
		mva		#$40 hposp0
			lda		#$b8
			sta		wsync
			sta		hitclr			;*, 104, 105, 106
			sta		d0				;107, 108, 109
			pha:pla					;110-113, 0-2
			pha:pla					;3-9
			pha:pla					;10-16
			pha:pla					;17-23
			pha:pla					;24, 25*, 26, 27, 28, 29*, 30, 31, 32
			pha:pla					;33*, 34, 35, 36, 37*, 38, 39, 40, 41*
			pha:pla					;42, 43, 44, 45*, 46, 47, 48, 48*, 50
			pha:pla					;51, 52, 53*, 54, 55, 56, 57*, 58, 59
			sta		hposp0			;60, 61, 62, 63
			inc		wsync
			lda		p0pl
			and		#$06
				_ASSERTA $06, c"Player did not retrigger properly."
					;try retriggering one cycle too early
			lda		#8
			jsr		_waitVCount
			sta		wsync
		mva		#$40 hposp0
			lda		#$b8
			sta		wsync
			sta		hitclr			;*, 104, 105, 106
			sta		d0				;107, 108, 109
			pha:pla					;110-113, 0-3
			pha:pla					;3-9
			pha:pla					;10-16
			sta		d0				;17-19
			sta		d0				;20-22
			sta		hposp0			;23, 24*, 25, 26, **27**
			inc		wsync
			lda		p0pl
			and		#$06
				_ASSERTA $04, c"Player retrigger timing test #1 failed: $%x."
					;try retriggering as early as possible
			lda		#8
			jsr		_waitVCount
			sta		wsync
		mva		#$40 hposp0
			lda		#$b8
			sta		wsync
			sta		hitclr			;*, 104, 105, 106
			sta		d0				;107, 108, 109
			pha:pla					;110-113, 0-3
			pha:pla					;3-9
			pha:pla					;10-16
			pha:pla					;17-23
			sta		hposp0			;24*, 25, 26, 27, 28*, **29**
			inc		wsync
			lda		p0pl
			and		#$06
				_ASSERTA $06, c"Player retrigger timing test #2 failed: $%x."
					;try retriggering as late as possible (even)
			lda		#8
			jsr		_waitVCount
			sta		wsync
		mva		#$40 hposp0
			lda		#$b8
			sta		wsync
			sta		hitclr			;*, 105, 106, 107
				sec
			jsr		delay80
			sta		hposp0			;86, 87, 88, **89**
			inc		wsync
			lda		p0pl
			and		#$06
				_ASSERTA $06, c"Player retrigger timing test #3 failed: $%x."
					;try retriggering one cycle too late (even)
			lda		#8
			jsr		_waitVCount
			sta		wsync
		mva		#$40 hposp0
			lda		#$b8
			sta		wsync
			sta		hitclr			;*, 105, 106, 107
				clc
			jsr		delay82
			sta		hposp0			;87, 88, 89, **90**
			inc		wsync
			lda		p0pl
			and		#$06
				_ASSERTA $02, c"Player retrigger timing test #4 failed: $%x."
					;=== Retrigger late test
					;
					; This test is annoying because we have to deal with a timing issue
					; between pre-XE and XE GTIAs. Pre-XE GTIAs or cold XE GTIAs retrigger
					; up to cycle 89, whereas warm XE GTIAs trigger up to cycle 90.
					; Therefore, we test at cycle 89 and 91 and allow for one cycle of
					; leeway here.
					;try retriggering as late as possible (odd)
			lda		#8
			jsr		_waitVCount
			sta		wsync
		mva		#$40 hposp0
			lda		#$b9
			sta		wsync
			sta		hitclr			;*, 105, 106, 107
				sec
			jsr		delay80
					;130XE warm check
					; clc
					; jsr		delay82
			sta		hposp0			;86, 87, 88, **89**
			inc		wsync
			lda		p0pl
			and		#$06
				_ASSERTA $06, c"Player retrigger timing test #5 failed: $%x."
					;try retriggering one cycle too late (odd)
			lda		#8
			jsr		_waitVCount
			sta		wsync
		mva		#$40 hposp0
			lda		#$b9
			sta		wsync
			sta		hitclr			;*, 105, 106, 107
					;800XL / 130XE cold
					; clc
					; jsr		delay82
					;130XE warm
				sec
			jsr		delay82
			sta		hposp0			;87, 88, 89, **90**
			inc		wsync
			lda		p0pl
			and		#$06
				_ASSERTA $02, c"Player retrigger timing test #6 failed: $%x."
			jmp		_testPassed
		delay86:
				nop
		delay84:
				nop
		delay82:
				nop
		delay80:
				nop
		delay78:
				nop
		delay76:
				nop
		delay74:
			bcs		delay72
		delay72:
			jsr		delay24
		delay48:
			jsr		delay24
		delay24:
			jsr		delay12
		delay12:
				rts
		testname:
	dta		c"GTIA: P/M retriggering",0
			run		$2000
					end
