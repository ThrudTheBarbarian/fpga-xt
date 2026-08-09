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
				_SAP_HEADER "ANTIC: DLI timing"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vertical blank and swap in new display list
			jsr		_waitVBL
	mwa		#dli vdslst
	mwa		#dlist dlistl
		mva		#$80 nmien
		mva		#$20 dmactl
					;test #1 (scanline 17)
			lda		#8
		cmp:req	vcount
		cmp:rne	vcount
			inc		wsync
		origin_test1:
				nop						;104, 105
				nop						;106, 107
				nop						;108, 109
				nop						;110, 111
				nop						;112, 113
				nop						;0, 1
				nop						;2, 3
				nop						;4, 5
				nop						;6, 7
				nop						;8, 9
				nop						;10, 11 <--
				nop						;12, 13
			lda		d0
			sub		#<origin_test1
			sta		d1
					;test #2 (scanline 19)
			inc		wsync
			inc		wsync
			sta		$ff				;104, 105, 106
		origin_test2:
				nop						;107, 108
				nop						;109, 110
				nop						;111, 112
				nop						;113, 0
				nop						;1, 2
				nop						;3, 4
				nop						;5, 6
				nop						;7, 8
				nop						;9, 10	<--
				nop						;11, 12
				nop						;13, 14
			lda		d0
			sub		#(<origin_test2)-1
			sta		d2
					;test #3 (scanline 21)
			inc		wsync
			inc		wsync
		origin_test3:
			lda		$ff				;104, 105, 106
			lda		$ff				;107, 108, 109
			lda		$ff				;110, 111, 112
			lda		$ff				;113, 0, 1
			lda		$ff				;2, 3, 4
			lda		$ff				;5, 6, 7
			lda		$ff				;8, 9, 10
			lda		$ff				;11, 12, 13		<--
			lda		d0
			sub		#<origin_test3
			sta		d3
					;test #4
			inc		wsync
			inc		wsync
		origin_test4:
			lda		$0100			;104-107
			lda		$ff				;108
			lda		$ff				;111
			lda		$ff				;0
			lda		$ff				;3
			lda		$ff				;6
			lda		$ff				;9	<--
			lda		$ff				;12
			lda		d0
			sub		#<origin_test4
			sta		d4
					;test #5
			inc		wsync
			inc		wsync
		origin_test5:
			inc		d0				;104-108
			lda		$ff				;109
			lda		$ff				;112
			lda		$ff				;1
			lda		$ff				;4
			lda		$ff				;7
			lda		$ff				;10	<--
			lda		$ff				;13
			lda		$ff				;16
			lda		d0
			sub		#<origin_test5
			sta		d5
					;disable NMIs
		mva		#0 nmien
					;check values
				_ASSERT1 d1, $0a, c"Even count incorrect: $%x != $0a"
				_ASSERT1 d2, $09, c"Odd count incorrect: $%x != $09"
				_ASSERT1 d3, $0e, c"Phase 1/3 count incorrect: $%x != $0e"
				_ASSERT1 d4, $0d, c"Phase 2/3 count incorrect: $%x != $0d"
				_ASSERT1 d5, $0c, c"Phase 3/3 count incorrect: $%x != $09"
					;========= DELAY TESTS
					;test #1 (scanline 17)
			lda		#8
		cmp:req	vcount
		cmp:rne	vcount
			inc		wsync
		origin_test6:
			lda		#$00			;104, 105
			sta		nmien			;106-109
			lda		$80				;110-112
				nop						;113, 0
			lda		#$80			;1, 2
			sta		nmien			;3, 4, 5, 6
				nop						;7, 8
				nop						;9, 10
				nop						;11, 12 <--
			lda		d0
			sub		#<origin_test6
			sta		d1
			inc		wsync			;-> (17:105)
			inc		wsync			;-> (18:105)
		origin_test7:
			lda		#$00			;104, 105
			sta		nmien			;106-109
			lda		$80				;110-112
				nop						;113, 0
			lda		#$80			;1, 2
			sta		nmien			;3, 4, 5, 6
			lda		$80				;7, 8, 9
				nop						;10, 11 <--
				nop						;11, 12
			lda		d0
			sub		#<origin_test7
			sta		d2
					;disable NMIs
		mva		#0 nmien
					;check values
				_ASSERT1 d1, $0F, c"Delayed odd count incorrect: $%x != $0F"
				_ASSERT1 d2, $0F, c"Delayed even count incorrect: $%x != $0F"
					;========= DLI after WSYNC test
			inc		wsync			;-> (20:105)
			inc		wsync			;-> (21:105)
			inc		wsync			;-> (22:105)
		mva		#$80 nmien
			sta		wsync			;-> (23:105)
		origin_test8:
				nop						;this should execute before DLI because its first cycle has already executed
				nop						;this should execute after DLI
				nop
			lda		d0
			sub		#<origin_test8
			sta		d1
		mva		#0 nmien
				_ASSERT1 d1, $01, c"Incorrect insn count after WSYNC delayed DLI: %d != 1"
			jmp		_testPassed
			;=========================================================================
		.proc dli
				pha
				txa
				pha
				tsx
			lda		$0104,x
			sta		d0
				pla
				tax
				pla
				rti
			.endp
			;=========================================================================
		testname:
	dta		c"ANTIC: DLI timing",0
				org		$2800
		dlist:
			dta		$70			;8
				dta		$90			;16 (DLI on 17)
				dta		$90			;18 (DLI on 19)
				dta		$90			;20 (DLI on 21)
				dta		$90			;22 (DLI on 23)
				dta		$90			;24 (DLI on 25)
			dta		$41,a(dlist)
			run		$2000
					end
