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
				_SAP_HEADER "ANTIC: VCOUNT timing"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_interruptsOff
			lda		#1
		cmp:req	vcount
		cmp:rne	vcount
			sta		wsync			;end scan line 2
			sta		wsync			;end scan line 3
			bit		$00				;*, 105, 106
			lda		vcount			;107, 108, 109, 110
			sta		d0
			sta		wsync			;end scan line 4
			bit		$00				;*, 105, 106
			lda		vcount			;107, 108, 109, 110
			sta		d1
			sta		wsync			;end scan line 5
			bit		$0100			;*, 105, 106, 107
			lda		vcount			;108, 109, 110, 111
			sta		d2
			sta		wsync			;end scan line 6
			bit		$0100
			lda		vcount
			sta		d3
				_ASSERT1 d0, $01, c"VCOUNT #1 wrong: $%x != $01"
				_ASSERT1 d1, $02, c"VCOUNT #2 wrong: $%x != $02"
				_ASSERT1 d2, $03, c"VCOUNT #3 wrong: $%x != $03"
				_ASSERT1 d3, $03, c"VCOUNT #4 wrong: $%x != $03"
					;now for the nasty one -- single cycle rollover
			ldx		#130
			lda		pal
			cmp		#$0f
			beq		is_ntsc
			ldx		#155
		is_ntsc:
		cpx:rne	vcount
			sta		wsync			;end scan line 260/310
			sta		wsync			;end scan line 261/311
			bit		$0100			;*, 105, 106, 107
			lda		vcount			;108, 109, 110, 111
			sta		d0
			inc		wsync
		cpx:rne	vcount
			sta		wsync
			sta		wsync			;end scan line 261/311
			bit		$00				;*, 105, 106
				nop						;107, 108
			lda		vcount			;109, 110, 111, 112
			sta		d1
					;check values
			lda		pal
			cmp		#$0f
			beq		is_ntsc2
				_ASSERT1 d0, 156, c"VCOUNT rollover #1 (PAL) wrong: $%x"
				_ASSERT1 d1, 0, c"VCOUNT rollover #2 (PAL) wrong: $%x"
			jmp		_testPassed
		is_ntsc2:
				_ASSERT1 d0, 131, c"VCOUNT rollover #1 (NTSC) wrong: $%x"
				_ASSERT1 d1, 0, c"VCOUNT rollover #2 (NTSC) wrong: $%x"
			jmp		_testPassed
		testname:
	dta		c"ANTIC: VCOUNT timing",0
			run		$2000
					end
