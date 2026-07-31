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
				_SAP_HEADER "GTIA: Collision test"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
			lda		#0
			jsr		_waitVCount
					;move all sprites into horizontal blank and check for phantom collisions
		mva		#$22 dmactl
		mva		#$00 gractl
		mva		#$00 hposp0
		mva		#$08 hposp1
		mva		#$10 hposp2
		mva		#$18 hposp3
		mva		#$20 hposm0
		mva		#$22 hposm1
		mva		#$24 hposm2
		mva		#$26 hposm3
			lda		#0
			sta		sizep0
			sta		sizep1
			sta		sizep2
			sta		sizep3
			sta		sizem
			sta		gractl
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			sta		grafm
			sta		hitclr
			lda		#124
			jsr		_waitVCount
			lda		m0pl
			ora		m1pl
			ora		m2pl
			ora		m3pl
			ora		p0pl
			ora		p1pl
			ora		p2pl
			ora		p3pl
			ora		p0pf
			ora		p1pf
			ora		p2pf
			ora		p3pf
				_ASSERTA $00, c"Phantom collisions detected."
					;overlap all sprites and check for cross collections
			lda		#0
			jsr		_waitVCount
			lda		#$80
			sta		hposp0
			sta		hposp1
			sta		hposp2
			sta		hposp3
			sta		hposm0
			sta		hposm1
			sta		hposm2
			sta		hposm3
			lda		#$ff
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			sta		grafm
			sta		hitclr
			lda		#124
			jsr		_waitVCount
			lda		m0pl
			and		m1pl
			and		m2pl
			and		m3pl
			and		#$0f
				_ASSERTA $0f, c"M/P collisions were not correct in total case."
			lda		p0pl
			cmp		#$0e
			bne		failallpl
			lda		p1pl
			cmp		#$0d
			bne		failallpl
			lda		p2pl
			cmp		#$0b
			bne		failallpl
			lda		p3pl
			cmp		#$07
			beq		passallpl
		failallpl:
				_FAIL	c"P/P collisions were not correct in total case."
		passallpl:
					;check if collisions can happen in HBLANK on left side
			lda		#0
			jsr		_waitVCount
			lda		#$21
			sta		hposp0
			sta		hposp1
			sta		hposp2
			sta		hposp3
			sta		hposm0
			sta		hposm1
			sta		hposm2
			sta		hposm3
			lda		#$80
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			lda		#$aa
			sta		grafm
			sta		hitclr
			lda		#124
			jsr		_waitVCount
			lda		m0pl
			ora		m1pl
			ora		m2pl
			ora		m3pl
			ora		#$0f
				_ASSERTA $0f, c"M/P collisions were detected in HBLANK on left."
			lda		p0pl
			ora		p1pl
			ora		p2pl
			ora		p3pl
				_ASSERTA $00, c"P/P collisions were detected in HBLANK on left."
					;check if collisions can happen in HBLANK on right side
			lda		#0
			jsr		_waitVCount
			lda		#$de
			sta		hposp0
			sta		hposp1
			sta		hposp2
			sta		hposp3
			sta		hposm0
			sta		hposm1
			sta		hposm2
			sta		hposm3
			lda		#$ff
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			sta		grafm
			sta		hitclr
			lda		#124
			jsr		_waitVCount
			lda		m0pl
			ora		m1pl
			ora		m2pl
			ora		m3pl
			ora		#$0f
				_ASSERTA $0f, c"M/P collisions were detected in HBLANK on right."
			lda		p0pl
			ora		p1pl
			ora		p2pl
			ora		p3pl
				_ASSERTA $00, c"P/P collisions were detected in HBLANK on right."
					;check if collisions can happen in visible region on left
			lda		#0
			jsr		_waitVCount
			lda		#$22
			sta		hposp0
			sta		hposp1
			sta		hposp2
			sta		hposp3
			sta		hposm0
			sta		hposm1
			sta		hposm2
			sta		hposm3
			lda		#$80
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			lda		#$aa
			sta		grafm
			sta		hitclr
			lda		#124
			jsr		_waitVCount
			lda		m0pl
			and		m1pl
			and		m2pl
			and		m3pl
				_ASSERTA $0f, c"Missing M/P collisions on left at $22."
			lda		p0pl
			cmp		#$0e
			bne		failplvisleft
			lda		p1pl
			cmp		#$0d
			bne		failplvisleft
			lda		p2pl
			cmp		#$0b
			bne		failplvisleft
			lda		p3pl
			cmp		#$07
			beq		passplvisleft
		failplvisleft:
				_FAIL	c"Missing P/P collisions on left at $22."
		passplvisleft:
					;check if collisions can happen in visible region on right side
			lda		#0
			jsr		_waitVCount
			lda		#$dd
			sta		hposp0
			sta		hposp1
			sta		hposp2
			sta		hposp3
			sta		hposm0
			sta		hposm1
			sta		hposm2
			sta		hposm3
			lda		#$80
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			lda		#$aa
			sta		grafm
			sta		hitclr
			lda		#124
			jsr		_waitVCount
			lda		m0pl
			and		m1pl
			and		m2pl
			and		m3pl
			and		#$0f
				_ASSERTA $0f, c"Missing P/M collisions on right at $DD."
			lda		p0pl
			cmp		#$0e
			bne		failplvisright
			lda		p1pl
			cmp		#$0d
			bne		failplvisright
			lda		p2pl
			cmp		#$0b
			bne		failplvisright
			lda		p3pl
			cmp		#$07
			beq		passplvisright
		failplvisright:
				_FAIL	c"Missing P/P collisions on right at $DD."
		passplvisright:
					;check if sprites partially horizontal blank on left can still trigger collisions
			lda		#0
			jsr		_waitVCount
			lda		#$21
			sta		hposp0
			sta		hposp1
			sta		hposp2
			sta		hposp3
			sta		hposm0
			sta		hposm1
			sta		hposm2
			sta		hposm3
			lda		#$c0
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			lda		#$ff
			sta		grafm
			sta		hitclr
			lda		#124
			jsr		_waitVCount
			lda		m0pl
			and		m1pl
			and		m2pl
			and		m3pl
				_ASSERTA $0f, c"Missing M/P collisions on left at $21-$22."
			lda		p0pl
			cmp		#$0e
			bne		failplvispartial
			lda		p1pl
			cmp		#$0d
			bne		failplvispartial
			lda		p2pl
			cmp		#$0b
			bne		failplvispartial
			lda		p3pl
			cmp		#$07
			beq		passplvispartial
		failplvispartial:
				_FAIL	c"Missing P/P collisions on left at $21-$22."
		passplvispartial:
					;move sprites back to center and check for VBLANK collisions
			lda		#124
			jsr		_waitVCount
			lda		#$80
			sta		hposp0
			sta		hposp1
			sta		hposp2
			sta		hposp3
			sta		hposm0
			sta		hposm1
			sta		hposm2
			sta		hposm3
			lda		#$ff
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			sta		grafm
			sta		hitclr
			lda		#0
			jsr		_waitVCount
			lda		m0pl
			ora		m1pl
			ora		m2pl
			ora		m3pl
				_ASSERTA $00, c"P/M collisions were detected in VBLANK."
			lda		p0pl
			ora		p1pl
			ora		p2pl
			ora		p3pl
				_ASSERTA $00, c"P/P collisions were detected in VBLANK."
			lda		m0pf
			ora		m1pf
			ora		m2pf
			ora		m3pf
				_ASSERTA $00, c"M/PF collisions were detected in VBLANK."
			lda		p0pf
			ora		p1pf
			ora		p2pf
			ora		p3pf
				_ASSERTA $00, c"P/PF collisions were detected in VBLANK."
			jmp		_testPassed
		testname:
	dta		c"GTIA: Collision test",0
			run		$2000
					end
