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
				_SAP_HEADER "ANTIC: Character control"
					opt		h+o+
					icl		'library.s'
				org		$2000
		.proc main
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
					;clear P/M graphics
			ldx		#0
				txa
		clearloop:
			sta		datam0,x
			sta		datap0,x
			sta		datap1,x
			sta		datap2,x
			sta		datap3,x
				dex
			bne		clearloop
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vertical blank
			jsr		_waitVBL
					;set up for player/missile collisions
		mva		#$40 hposp0
		mva		#$41 hposp1
		mva		#$42 hposp2
		mva		#$43 hposp3
		mva		#$44 hposm0
		mva		#$45 hposm1
		mva		#$46 hposm2
		mva		#$47 hposm3
		mva		#$00 sizep0
		mva		#$00 sizep1
		mva		#$00 sizep2
		mva		#$00 sizep3
		mva		#$00 sizem
		mva		#$03 gractl
		mva		#$30 pmbase
					;set up display
		mva		#$2c chbase
	mwa		#dlist dlistl
		mva		#$3d dmactl
					;--- test 1: chactl all off
			ldx		#$00
			ldy		#>checktab0
			lda		#<checktab0
			jsr		doTests
					;--- test 1: chactl, invert on
			ldx		#$02
			ldy		#>checktab1
			lda		#<checktab1
			jsr		doTests
					;--- test 1: chactl, blink on
			ldx		#$01
			ldy		#>checktab2
			lda		#<checktab2
			jsr		doTests
					;--- test 3: chactl, reflect on
			ldx		#$04
			ldy		#>checktab3
			lda		#<checktab3
			jsr		doTests
			jmp		_testPassed
		checktab0:
					;mode 2
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 2 inverted
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 3
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
				dta		%00000000
				dta		%00000000
					;mode 3 inverted
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
				dta		%00000000
				dta		%00000000
					;mode 3 inverted descender
				dta		%00000000
				dta		%00000000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
				dta		%00010000
				dta		%00100000
					;mode 4
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 5
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 6
				dta		%00000011
				dta		%00001100
				dta		%00110000
				dta		%11000000
				dta		%00000011
				dta		%00001111
				dta		%00111111
				dta		%11111111
					;mode 7
				dta		%00000011
				dta		%00001100
				dta		%00110000
				dta		%11000000
				dta		%00000011
				dta		%00001111
				dta		%00111111
				dta		%11111111
		checktab1:
					;mode 2
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 2 inverted
				dta		%11100000
				dta		%11010000
				dta		%10110000
				dta		%01110000
				dta		%11100000
				dta		%11000000
				dta		%10000000
				dta		%00000000
					;mode 3
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
				dta		%00000000
				dta		%00000000
					;mode 3 inverted
				dta		%11100000
				dta		%11010000
				dta		%10110000
				dta		%01110000
				dta		%11100000
				dta		%11000000
				dta		%10000000
				dta		%00000000
				dta		%11110000
				dta		%11110000
					;mode 3 inverted descender
				dta		%11110000
				dta		%11110000
				dta		%10110000
				dta		%01110000
				dta		%11100000
				dta		%11000000
				dta		%10000000
				dta		%00000000
				dta		%11100000
				dta		%11010000
					;mode 4
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 5
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 6
				dta		%00000011
				dta		%00001100
				dta		%00110000
				dta		%11000000
				dta		%00000011
				dta		%00001111
				dta		%00111111
				dta		%11111111
					;mode 7
				dta		%00000011
				dta		%00001100
				dta		%00110000
				dta		%11000000
				dta		%00000011
				dta		%00001111
				dta		%00111111
				dta		%11111111
		checktab2:
					;mode 2
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 2 inverted
	:8 dta $00
					;mode 3
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
				dta		%00000000
				dta		%00000000
					;mode 3 inverted
	:10 dta $00
					;mode 3 inverted descender
	:10 dta $00
					;mode 4
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 5
				dta		%00010000
				dta		%00100000
				dta		%01000000
				dta		%10000000
				dta		%00010000
				dta		%00110000
				dta		%01110000
				dta		%11110000
					;mode 6
				dta		%00000011
				dta		%00001100
				dta		%00110000
				dta		%11000000
				dta		%00000011
				dta		%00001111
				dta		%00111111
				dta		%11111111
					;mode 7
				dta		%00000011
				dta		%00001100
				dta		%00110000
				dta		%11000000
				dta		%00000011
				dta		%00001111
				dta		%00111111
				dta		%11111111
		checktab3:
					;mode 2
				dta		%11110000
				dta		%01110000
				dta		%00110000
				dta		%00010000
				dta		%10000000
				dta		%01000000
				dta		%00100000
				dta		%00010000
					;mode 2 inverted
				dta		%11110000
				dta		%01110000
				dta		%00110000
				dta		%00010000
				dta		%10000000
				dta		%01000000
				dta		%00100000
				dta		%00010000
					;mode 3
				dta		%11110000
				dta		%01110000
				dta		%00110000
				dta		%00010000
				dta		%10000000
				dta		%01000000
				dta		%00100000
				dta		%00010000
				dta		%00000000
				dta		%00000000
					;mode 3 inverted
				dta		%11110000
				dta		%01110000
				dta		%00110000
				dta		%00010000
				dta		%10000000
				dta		%01000000
				dta		%00100000
				dta		%00010000
				dta		%00000000
				dta		%00000000
					;mode 3 inverted descender
				dta		%00000000
				dta		%00000000
				dta		%00110000
				dta		%00010000
				dta		%10000000
				dta		%01000000
				dta		%00100000
				dta		%00010000
				dta		%11110000
				dta		%01110000
					;mode 4
				dta		%11110000
				dta		%01110000
				dta		%00110000
				dta		%00010000
				dta		%10000000
				dta		%01000000
				dta		%00100000
				dta		%00010000
					;mode 5
				dta		%11110000
				dta		%01110000
				dta		%00110000
				dta		%00010000
				dta		%10000000
				dta		%01000000
				dta		%00100000
				dta		%00010000
					;mode 6
				dta		%11111111
				dta		%00111111
				dta		%00001111
				dta		%00000011
				dta		%11000000
				dta		%00110000
				dta		%00001100
				dta		%00000011
					;mode 7
				dta		%11111111
				dta		%00111111
				dta		%00001111
				dta		%00000011
				dta		%11000000
				dta		%00110000
				dta		%00001100
				dta		%00000011
			.endp
			;=========================================================================
			; Entry:
			;	X		CHACTL mode
			;	Y:A		Check data
			;
		.proc	doTests
			stx		chactl
			stx		d1
			sta		a2
			sty		a2+1
					;mode 2
			ldx		#$42
		mva		#$01 playfield
			jsr		doTest
			ldy		#>modename0
			lda		#<modename0
			ldx		#8
			jsr		checkTest
					;mode 2 inverted
			ldx		#$42
		mva		#$81 playfield
			jsr		doTest
			ldy		#>modename1
			lda		#<modename1
			ldx		#8
			jsr		checkTest
					;mode 3
			ldx		#$43
		mva		#$01 playfield
			jsr		doTest
			ldy		#>modename2
			lda		#<modename2
			ldx		#10
			jsr		checkTest
					;mode 3 inverted
			ldx		#$43
		mva		#$81 playfield
			jsr		doTest
			ldy		#>modename3
			lda		#<modename3
			ldx		#10
			jsr		checkTest
					;mode 3 inverted descender
			ldx		#$43
		mva		#$e0 playfield
			jsr		doTest
			ldy		#>modename4
			lda		#<modename4
			ldx		#10
			jsr		checkTest
					;mode 4
			ldx		#$44
		mva		#$01 playfield
			jsr		doTest
			ldy		#>modename5
			lda		#<modename5
			ldx		#8
			jsr		checkTest
					;mode 5
			ldx		#$45
			jsr		doTest
			ldy		#>modename6
			lda		#<modename6
			ldx		#8
			jsr		checkTest
					;mode 6
			ldx		#$46
		mva		#$81 playfield
			jsr		doTest
			ldy		#>modename7
			lda		#<modename7
			ldx		#8
			jsr		checkTest
					;mode 7
			ldx		#$47
			jsr		doTest
			ldy		#>modename8
			lda		#<modename8
			ldx		#8
			jsr		checkTest
				rts
	modename0	dta	c"2",0
modename1	dta	c"2 inv",0
	modename2	dta	c"3",0
modename3	dta	c"3 inv",0
dta	c"3 inv desc",0
	modename5	dta	c"4",0
	modename6	dta	c"5",0
	modename7	dta	c"6",0
	modename8	dta	c"7",0
			.endp
			;=========================================================================
			; Entry:
			;	X		Row count
			;	D1		CHACTL value
			;	Y:A		Mode name
			;
		.proc	checkTest
			sta		d2
			sty		d3
			stx		d0
			ldy		#0
			ldx		#0
		loop:
			lda		(a2),y
			cmp		testres,x
			beq		ok
			stx		d4
			sta		d5
		mva		testres,x d6
				_FAIL	c"Failed chactl=$%x on mode %s at row %d: expected $%x, got $%x"
		ok:
		inw		a2
				inx
			cpx		d0
			bne		loop
				rts
			.endp
			;=========================================================================
		.proc	doTest
					;modify display list
			stx		dlist
			stx		dlist+4
			stx		dlist+8
			stx		dlist+12
			stx		dlist+16
			stx		dlist+20
			stx		dlist+24
			stx		dlist+28
			stx		dlist+32
			stx		dlist+36
					;init row counter
			mva		#0 d6
					;clear player
			ldy		#0
		clearloop:
			sta		datam0,y
			sta		datap0,y
			sta		datap1,y
			sta		datap2,y
			sta		datap3,y
				iny
			bne		clearloop
					;test mode and init player
			cpx		#$43
			bne		notmode3
					;init for mode 3
			ldx		#9
		mode3loop:
			lda		ppostab3,x
				tay
			lda		#$80
			sta		datap0,y
			sta		datap1,y
			sta		datap2,y
			sta		datap3,y
			lda		#$aa
			sta		datam0,y
				dex
			bpl		mode3loop
					;begin mode 3 test
			jsr		_waitVBL
			sta		hitclr
					.rept 10
						lda		#(20 + 14*#)/2
						jsr		readval
					.endr
					.endr
				rts
		notmode3:
			cpx		#$45
			beq		mode57
			cpx		#$47
			bne		mode246
		mode57:
					;init for modes 5, 7
			ldx		#7
		mode57loop:
			lda		ppostab57,x
				tay
			lda		#$80
			sta		datap0,y
			sta		datap1,y
			sta		datap2,y
			sta		datap3,y
			lda		#$aa
			sta		datam0,y
				dex
			bpl		mode57loop
					;begin mode 5, 7 test
			jsr		_waitVBL
			sta		hitclr
					.rept 8
						lda		#(26 + 20*#)/2
						jsr		readval
					.endr
					.endr
				rts
		mode246:
					;init for modes 2, 4, 6
			ldx		#7
		mode246loop:
			lda		ppostab246,x
				tay
			lda		#$80
			sta		datap0,y
			sta		datap1,y
			sta		datap2,y
			sta		datap3,y
			lda		#$aa
			sta		datam0,y
				dex
			bpl		mode246loop
					;begin mode 2, 4, 6 test
			jsr		_waitVBL
			sta		hitclr
					.rept 8
						lda		#(18 + 12*#)/2
						jsr		readval
					.endr
					.endr
				rts
		readval:
					;wait until given scanline
		cmp:rne	vcount
					;read value from collision registers
			lda		p0pf
			and		#$04
			cmp		#$02
			rol		a0
			lda		p1pf
			and		#$04
			cmp		#$02
			rol		a0
			lda		p2pf
			and		#$04
			cmp		#$02
			rol		a0
			lda		p3pf
			and		#$04
			cmp		#$02
			rol		a0
			lda		m0pf
			and		#$04
			cmp		#$02
			rol		a0
			lda		m1pf
			and		#$04
			cmp		#$02
			rol		a0
			lda		m2pf
			and		#$04
			cmp		#$02
			rol		a0
			lda		m3pf
			and		#$04
			cmp		#$02
			rol		a0
			lda		a0
					;store value
			ldy		d6
			inc		d6
			sta		testres,y
					;reset collisions
			sta		hitclr
				rts
		ppostab246:
	:8 dta	8+13*#
		ppostab3:
	:10 dta	8+15*#
		ppostab57:
	:8 dta	8+22*#
			.endp
		testname:
	dta		c"ANTIC: Character control",0
		testres	equ		$2780
				org		$2800
		dlist:
		dta		$42,a(playfield)		;8
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$42,a(playfield)
				dta		$30
			dta		$41,a(dlist)
		playfield:
	:32		dta $00
				org		$2c00
		charset:
	dta		$00,$00,$00,$00,$00,$00,$00,$00
	dta		$03,$0c,$30,$c0,$03,$0f,$3f,$ff
				org		$2f00
	dta		$03,$0c,$30,$c0,$03,$0f,$3f,$ff
		datam0	equ		$3300
		datap0	equ		$3400
		datap1	equ		$3500
		datap2	equ		$3600
		datap3	equ		$3700
			run		main
					end
