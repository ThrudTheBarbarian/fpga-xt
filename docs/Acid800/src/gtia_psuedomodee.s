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
				_SAP_HEADER "GTIA: Pseudo mode E"
					opt	o-
					org	$80
			result0	dta	0
			result1	dta	0
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vblank
			jsr		_waitVBL
					;initialize test display
	mwa		#dlist dlistl
	mwa		#dli vdslst
		mva		#$01 vscrol
					;set up sprites
		mva		#$00 gractl
		mva		#$80 hposp0
		mva		#$00 grafp0
		mva		#$03 sizep0
					;turn on display
		mva		#$22 dmactl
		mva		#$80 nmien
					;wait for another vblank so DLI can fire
			jsr		_waitFrame
					;shut off DLI
		mva		#0 nmien
					;check results
				_ASSERT1 result0, $04, c"Cycle 14 test failed: %x"
				_ASSERT1 result1, $0f, c"Cycle 15 test failed: %x"
			jmp		_testPassed
			;==============================================================
		.proc	dli
				pha
				tya
				pha
				txa
				pha
			ldx	#$80
			ldy	#0
			lda	#$ff
			inc		wsync
			inc		wsync
			stx		prior		;104, 105, 106, (107)
			pha:pla				;108, 109, 110, 111, 112, 113, 0
				nop					;1, 2
			sta		hitclr		;3, 4, 5, 6
			sta		grafp0		;7, 8, 9, 10
			sty		prior		;11, 12, 13, (14)
			inc		wsync
		mva		p0pf result0
			lda		#$ff
			inc		wsync
			inc		wsync
			inc		wsync
			stx		prior		;104, 105, 106, (107)
			pha:pla				;108, 109, 110, 111, 112, 113, 0
				nop					;1, 2
			sta		hitclr		;3, 4, 5, 6
			sta		grafp0,y	;7, 8, 9, 10, 11
			sty		prior		;12, 13, 14, (15)
			inc		wsync
		mva		p0pf result1
			sty		grafp0
				pla
				tax
				pla
				tay
				pla
				rti
			.endp
		testname:
	dta		c"GTIA: Psuedo mode E",0
				org		$2800
		dlist:
			dta		$70
				dta		$70
				dta		$f0
			dta		$6f, a(testpat)
			dta		$41, a(dlist)
		testpat:
	:40 dta $e4
			run		$2000
					end
