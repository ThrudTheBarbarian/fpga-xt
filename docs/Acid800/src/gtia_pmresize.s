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
				_SAP_HEADER "GTIA: Player resizing"
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
					;We use collisions to detect whether the resized image is correct. Player 0
					;is always the player we are resizing; players 1-3, missiles 0-3, and PF0-PF3
					;are used to scan the resulting bit pattern:
					;
					;	P1 P2 P3 M0 M1 M2 M3
		mva		#$80 grafp1
		mva		#$80 grafp2
		mva		#$80 grafp3
		mva		#$aa grafm
		mva		#$61 hposp1
		mva		#$62 hposp2
		mva		#$63 hposp3
		mva		#$64 hposm0
		mva		#$65 hposm1
		mva		#$66 hposm2
		mva		#$67 hposm3
		mva		#$00 sizep1
		mva		#$00 sizep2
		mva		#$00 sizep3
		mva		#$00 sizem
		mva		#$0f colpm0
		mva		#$12 colpm1
		mva		#$32 colpm2
		mva		#$52 colpm3
		mva		#$18 prior
					;wait for start of visible region
			lda		#8
		cmp:rne	vcount
					;------------------------------------------------------------------
					; 4x to 1x
					;
			mva		#$48 d4
			mva		#$f0 d5
		test1:
			lda		#3
			ldy		#0
			ldx		d4
			jsr		runtest
			ldx		d5
			cmp		testpat1-$f0,x
			beq		pass1
			sta		d3
				txa
				clc
			adc		#$10
			sta		d1
		mva		testpat1-$f0,x d2
				_FAIL	c"4x-to-1x failed at index %d: expected $%x, got $%x"
		pass1:
			inc		d4
			inc		d5
			bne		test1
					;------------------------------------------------------------------
					; 4x to 2x
					;
			mva		#$48 d4
			mva		#$f0 d5
		test2:
			lda		#3
			ldy		#1
			ldx		d4
			jsr		runtest
			ldx		d5
			cmp		testpat2-$f0,x
			beq		pass2
			sta		d3
				txa
				clc
			adc		#$10
			sta		d1
		mva		testpat2-$f0,x d2
				_FAIL	c"4x-to-2x failed at index %d: expected $%x, got $%x"
		pass2:
			inc		d4
			inc		d5
			bne		test2
					;------------------------------------------------------------------
					; 2x to 4x
					;
			mva		#$54 d4
			mva		#$f0 d5
		test3:
			lda		#1
			ldy		#3
			ldx		d4
			jsr		runtest
			ldx		d5
			cmp		testpat3-$f0,x
			beq		pass3
			sta		d3
				txa
				clc
			adc		#$10
			sta		d1
		mva		testpat3-$f0,x d2
				_FAIL	c"2x-to-4x failed at index %d: expected $%x, got $%x"
		pass3:
			inc		d4
			inc		d5
			bne		test3
					;------------------------------------------------------------------
					; 1x to 2x
					;
					;wait for start of visible region
			lda		#8
		cmp:rne	vcount
			mva		#$54 d4
			mva		#$f0 d5
		test4:
			lda		#0
			ldy		#1
			ldx		d4
			jsr		runtest
			ldx		d5
			cmp		testpat4-$f0,x
			beq		pass4
			;		jmp		pass4
			sta		d3
				txa
				clc
			adc		#$10
			sta		d1
		mva		testpat4-$f0,x d2
				_FAIL	c"1x-to-2x failed at index %d: expected $%x, got $%x"
		pass4:
			inc		d4
			inc		d5
			bne		test4
					;------------------------------------------------------------------
					; 1x to 4x
					;
			mva		#$54 d4
			mva		#$f0 d5
		test5:
			lda		#0
			ldy		#3
			ldx		d4
			jsr		runtest
			ldx		d5
			cmp		testpat5-$f0,x
			beq		pass5
			;		jmp		pass5
			sta		d3
				txa
				clc
			adc		#$10
			sta		d1
		mva		testpat5-$f0,x d2
				_FAIL	c"1x-to-4x failed at index %d: expected $%x, got $%x"
		pass5:
			inc		d4
			inc		d5
			bne		test5
					;------------------------------------------------------------------
					; 2x to 1xalt
					;
			mva		#$54 d4
			mva		#$f0 d5
		test6:
			lda		#1
			ldy		#2
			ldx		d4
			jsr		runtest
			ldx		d5
			cmp		testpat6-$f0,x
			beq		pass6
			;		jmp		pass6
			sta		d3
				txa
				clc
			adc		#$10
			sta		d1
		mva		testpat6-$f0,x d2
				_FAIL	c"2x-to-1xalt failed at index %d: expected $%x, got $%x"
		pass6:
			inc		d4
			inc		d5
			bne		test6
					;------------------------------------------------------------------
					; 4x to 1xalt
					;
					;wait for start of visible region
			lda		#8
		cmp:rne	vcount
			mva		#$54 d4
			mva		#$f0 d5
		test7:
			lda		#3
			ldy		#2
			ldx		d4
			jsr		runtest
			ldx		d5
			cmp		testpat7-$f0,x
			beq		pass7
			;		jmp		pass7
			sta		d3
				txa
				clc
			adc		#$10
			sta		d1
		mva		testpat7-$f0,x d2
				_FAIL	c"4x-to-1xalt failed at index %d: expected $%x, got $%x"
		pass7:
			inc		d4
			inc		d5
			bne		test7
			jmp		_testPassed
		.proc runtest
			inc		wsync
			sta		hitclr		;104, 105, 106, 107
			stx		hposp0		;108, 109, 110, 111
			sta		sizep0		;112, 113, 0, 1
			lda		#$aa		;2, 3
			sta		grafp0		;4, 5, 6, 7
			lda		$0100		;8-11
			lda		$0100		;12-15
			pha:pla				;16-22
			pha:pla				;23, 24*, 25, 26, 27, 28*, 29, 30, 31
			pha:pla				;32*, 33, 34, 35, 36*, 37, 38, 39, 40*, 41
			sty		sizep0		;42, 43, 44*, 45, 46++
			inc		wsync
					;shut off player 0 graphic and reset position so we don't get new hits
					;(the latter is required if we are testing 1xalt lockup)
		mva		#0 grafp0
			sta		sizep0
			sta		hposp0
					;read bits 0-6
			lda		p1pl
				ror
			rol		d0
			lda		p2pl
				ror
			rol		d0
			lda		p3pl
				ror
			rol		d0
			lda		m0pl
				ror
			rol		d0
			lda		m1pl
				ror
			rol		d0
			lda		m2pl
				ror
			rol		d0
			lda		m3pl
				ror
			rol		d0
			lda		d0
				asl
				rts
			.endp
			;----------------------------------------------------------------
			; 4x to 1x
		testpat1:
				dta		%10000000
				dta		%10000000
				dta		%01000000
				dta		%01000000
				dta		%01000000
				dta		%01000000
				dta		%10100000
				dta		%10100000
				dta		%10100000
				dta		%10100000
				dta		%01010000
				dta		%01010000
				dta		%01010000
				dta		%01010000
				dta		%10101000
				dta		%10101000
			;----------------------------------------------------------------
			; 4x to 2x
		testpat2:
				dta		%10000000
				dta		%11000000
				dta		%01100000
				dta		%00110000
				dta		%01100000
				dta		%00110000
				dta		%10011000
				dta		%11001100
				dta		%10011000
				dta		%11001100
				dta		%01100110
				dta		%00110010
				dta		%01100110
				dta		%00110010
				dta		%10011000
				dta		%11001100
			;----------------------------------------------------------------
			; 2x to 4x
		testpat3:
				dta		%11100000
				dta		%11110000
				dta		%00011110
				dta		%00001110
				dta		%11100000
				dta		%11110000
				dta		%00011110
				dta		%00001110
				dta		%11100000
				dta		%11110000
				dta		%00011110
				dta		%00001110
				dta		%11100000
				dta		%11110000
				dta		%01111000
				dta		%00111100
			;----------------------------------------------------------------
			; 1x to 2x
		testpat4:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%11000000
				dta		%00110000
				dta		%11001100
				dta		%00110010
				dta		%11001100
				dta		%00110010
				dta		%11001100
				dta		%01100110
				dta		%00110010
			;----------------------------------------------------------------
			; 1x to 4x
		testpat5:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%11110000
				dta		%00001110
				dta		%11110000
				dta		%00001110
				dta		%11110000
				dta		%00001110
				dta		%11110000
				dta		%01111000
				dta		%00111100
			;----------------------------------------------------------------
			; 2x to 1xalt
		testpat6:
				dta		%11111110
				dta		%10000000
				dta		%00000000
				dta		%01000000
				dta		%11111110
				dta		%10100000
				dta		%00000000
				dta		%01010000
				dta		%11111110
				dta		%10101000
				dta		%00000000
				dta		%01010100
				dta		%11111110
				dta		%10101010
				dta		%01010100
				dta		%00101010
			;----------------------------------------------------------------
			; 4x to 1xalt
		testpat7:
				dta		%00000000
				dta		%01010000
				dta		%10101000
				dta		%11111110
				dta		%11111110
				dta		%10101000
				dta		%01010100
				dta		%00000000
				dta		%00000000
				dta		%01010100
				dta		%10101010
				dta		%11111110
				dta		%11111110
				dta		%10101010
				dta		%01010100
				dta		%00101010
		testname:
	dta		c"GTIA: Player resizing",0
			run		$2000
					end
