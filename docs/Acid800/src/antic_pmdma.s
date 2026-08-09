			; Altirra Acid800 test suite
			; Copyright (C) 2010-2013 Avery Lee, All Rights Reserved.
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
				_SAP_HEADER "ANTIC: P/M graphics DMA"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;initialize player 0 data
			ldx		#0
		initloop:
				txa
			and		#$0f
			sta		$3300,x
			sta		$3400,x
			sta		$3500,x
			sta		$3600,x
			sta		$3700,x
				inx
			bne		initloop
			ldx		#0
			ldy		#0
		initloop2:
				txa
			and		#$0f
			sta		$3200,y
			eor		#$0f
			sta		$3600,y
				inx
				txa
			and		#$0f
			sta		$3a00,y
				inx
				iny
			bne		initloop2
					;wait for vertical blank
			jsr		_waitVBL
					;bring up mode 10 collision test screen with P/M DMA
	mwa		#dlist dlistl
		mva		#$3d dmactl
		mva		#$80 prior
		mva		#$37 pmbase
					;set up GTIA to receive player data
		mva		#$02 gractl
		mva		#$00 vdelay
					;position player 0 along left side for playfield collision
		mva		#$41-8 hposp0
		mva		#$01 sizep0
					;wait for scan line 6
			lda		#3
		cmp:rne	vcount
					;*** begin kernel***
			ldx		#8
			sta		wsync
		testloop1:
			sta		wsync			;end scan 7+
			sta		hitclr			;clear collisions
			jsr		delay29
			pha:pla
			lda		p0pf
			cmp		$3400,x
			bne		fail1
				inx
			cpx		#24
			bne		testloop1
			jmp		pass1
		fail1:
			sta		d2
			stx		d1
			lda		$3400,x
			sta		d3
				_FAIL	c"One-line P0 data bad at line %d: $%x != $%x"
		pass1:
					;wait for vertical blank
			jsr		_waitVBL
					;set up GTIA to receive missile data
		mva		#$01 gractl
					;position players for collision detection
		mva		#$36 hposp0
		mva		#$34 hposp1
		mva		#$32 hposp2
		mva		#$30 hposp3
		mva		#$01 sizep0
		mva		#$01 sizep1
		mva		#$01 sizep2
		mva		#$01 sizep3
		mva		#$80 grafp0
		mva		#$80 grafp1
		mva		#$80 grafp2
		mva		#$80 grafp3
					;position missiles 0 and 1 for checking
		mva		#$30 hposm1
		mva		#$34 hposm0
		mva		#$55 sizem
					;wait for scan line 6 again
			lda		#3
		cmp:rne	vcount
					;*** begin kernel***
			ldx		#8
			sta		wsync
		testloop2:
			sta		wsync			;end scan 7+
			sta		hitclr			;clear collisions
			jsr		delay29
			lda		m0pl
			ora		m1pl
			cmp		$3300,x
			bne		fail2
				inx
			cpx		#24
			bne		testloop2
			jmp		pass2
		fail2:
			sta		d2
			stx		d1
				_FAIL	c"One-line M0/M1 data bad at line %d: $%x"
		pass2:
					;enable only player DMA on ANTIC, and check that missiles
					;still DMA
					;wait for vertical blank
			jsr		_waitVBL
		mva		#$39 dmactl
					;wait for scan line 6
			lda		#3
		cmp:rne	vcount
					;*** begin kernel***
			ldx		#8
			sta		wsync
		testloop3:
			sta		wsync			;end scan 7+
			sta		hitclr			;clear collisions
			jsr		delay29
			lda		m0pl
			ora		m1pl
			cmp		$3300,x
			bne		fail3
				inx
			cpx		#24
			bne		testloop3
			jmp		pass3
		fail3:
			sta		d2
			stx		d1
				_FAIL	c"Player DMA was not implicitly enabled at line %d: $%x"
		pass3:
					;switch to two-line DMA and make sure that ANTIC is actually DMAing
					;every scan line
					;wait for vertical blank
			jsr		_waitVBL
		mva		#$29 dmactl
		mva		#$02 gractl
					;position player 0 along left side for playfield collision
		mva		#$41-8 hposp0
		mva		#$01 sizep0
					;wait for scan line 6
			lda		#3
		cmp:rne	vcount
					;*** begin kernel***
			ldx		#4
			sta		wsync
		testloop4:
		mva		#$33 pmbase
			sta		wsync
			sta		hitclr			;clear collisions
			jsr		delay29
			lda		p0pf
			cmp		$3200,x
			bne		fail4
		mva		#$3b pmbase
			sta		wsync
			sta		hitclr			;clear collisions
			jsr		delay29
			lda		p0pf
			cmp		$3a00,x
			bne		fail4
				inx
			cpx		#16
			bne		testloop4
			jmp		pass4
		fail4:
			sta		d2
			stx		d1
				_FAIL	c"Two-line DMA bad at line %d: $%x"
		pass4:
					;switch to one-line with bit 2 set
			sta		wsync
		mva		#$39 dmactl
		mva		#$34 pmbase
			sta		wsync
			sta		wsync
					;switch to two-line without changing PMBASE and verify bit 2 is active
		mva		#$29 dmactl
			sta		wsync
					;wait for scan line 6
			lda		#3
		cmp:rne	vcount
					;*** begin kernel***
			ldx		#4
			sta		wsync
		testloop5:
		mva		#$33 pmbase
			sta		wsync
			sta		hitclr			;clear collisions
			jsr		delay29
			lda		p0pf
			eor		#$0f
			cmp		$3600,x
			bne		fail5
			sta		wsync
				inx
			cpx		#16
			bne		testloop5
			jmp		pass5
		fail5:
			sta		d2
			stx		d1
				_FAIL	c"PMBASE dormant bit 2 test failed at line %d: $%x"
		pass5:
			jmp		_testPassed
		delay29:
			bit		$00
				nop
		delay24:
			jsr		delay12
		delay12:
				rts
		testname:
	dta		c"ANTIC: P/M graphics DMA",0
				org		$2400
		dlist:
	:191 dta $4F,a(testline)
			dta		$41,a(dlist)
		testline:
			dta		$76,$54
	:30 dta	$88
			run		$2000
					end
