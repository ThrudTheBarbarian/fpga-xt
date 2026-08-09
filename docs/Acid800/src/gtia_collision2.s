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
				_SAP_HEADER "GTIA: Special modes collision test"
					opt		h+o+
					icl		'library.s'
			;GENLIBRARY = 0
			;STANDALONE = 0
		USEPLAYERS = 0
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
			jsr		_waitVBL
					;test standard gr.8 collisions
	mwa		#dlist dlistl
		mva		#$21 dmactl
		mva		#$00 gractl
		mva		#$00 prior
			.if USEPLAYERS
					mva		#$00 sizep0
					mva		#$00 sizep1
					mva		#$00 sizep2
					mva		#$00 sizep3
					mva		#$c0 grafp0
					mva		#$c0 grafp1
					mva		#$c0 grafp2
					mva		#$c0 grafp3
					mva		#$70 hposp0
					mva		#$7A hposp1
					mva		#$84 hposp2
					mva		#$8E hposp3
			.else
		mva		#$00 sizem
		mva		#$ff grafm
		mva		#$70 hposm0
		mva		#$7A hposm1
		mva		#$84 hposm2
		mva		#$8E hposm3
			.endif
			sta		hitclr
			inc		wsync
			inc		wsync
			jsr		_waitVBL
					;do a second waitvbl to make sure we're not in bugged mode
			inc		wsync
			inc		wsync
			jsr		_waitVBL
			.if USEPLAYERS
					_ASSERT1 p0pf, $00, c"Gr.8 %%00 collision incorrect: $%x"
					_ASSERT1 p1pf, $04, c"Gr.8 %%01 collision incorrect: $%x"
					_ASSERT1 p2pf, $04, c"Gr.8 %%10 collision incorrect: $%x"
					_ASSERT1 p3pf, $04, c"Gr.8 %%11 collision incorrect: $%x"
			.else
				_ASSERT1 m0pf, $00, c"Gr.8 %%00 collision incorrect: $%x"
				_ASSERT1 m1pf, $04, c"Gr.8 %%01 collision incorrect: $%x"
				_ASSERT1 m2pf, $04, c"Gr.8 %%10 collision incorrect: $%x"
				_ASSERT1 m3pf, $04, c"Gr.8 %%11 collision incorrect: $%x"
			.endif
					;test gr.9 collisions
		mva		#$40 prior
			jsr		checkcoll911
				_ASSERTA $00, c"Playfield collisions detected in Gr.9."
					;test gr.10 collisions
		mva		#$80 prior
			jsr		_waitVBL
			.if USEPLAYERS
					mva		#$71 hposp0
					mva		#$73 hposp1
					mva		#$75 hposp2
					mva		#$77 hposp3
			.else
		mva		#$71 hposm0
		mva		#$73 hposm1
		mva		#$75 hposm2
		mva		#$77 hposm3
			.endif
			sta		hitclr
			lda		#7
		cmp:rne	vcount
			.if USEPLAYERS
					_ASSERT1 p0pf, $00, c"Gr.10 P0 bogus early collision: $%x"
					_ASSERT1 p1pf, $00, c"Gr.10 P1 bogus early collision: $%x"
					_ASSERT1 p2pf, $00, c"Gr.10 P2 bogus early collision: $%x"
					_ASSERT1 p3pf, $00, c"Gr.10 P3 bogus early collision: $%x"
			.else
				_ASSERT1 m0pf, $00, c"Gr.10 M0 bogus early collision: $%x"
				_ASSERT1 m1pf, $00, c"Gr.10 M1 bogus early collision: $%x"
				_ASSERT1 m2pf, $00, c"Gr.10 M2 bogus early collision: $%x"
				_ASSERT1 m3pf, $00, c"Gr.10 M3 bogus early collision: $%x"
			.endif
			lda		#17
		cmp:rne	vcount
			;		lda		#$00
			;		mva		m0pf d1
			;		mva		m1pf d2
			;		mva		m2pf d3
			;		mva		m3pf d4
			;		jsr		_imprintf
			;		dta		$9B,c"MxPF: %x %x %x %x",$9B,0
			;		jsr		_testRestore
			;		jsr		_jam
			.if USEPLAYERS
					_ASSERT1 p0pf, $00, c"Gr.10 $0 collision incorrect: $%x"
					_ASSERT1 p1pf, $00, c"Gr.10 $1 collision incorrect: $%x"
					_ASSERT1 p2pf, $00, c"Gr.10 $2 collision incorrect: $%x"
					_ASSERT1 p3pf, $00, c"Gr.10 $3 collision incorrect: $%x"
			.else
				_ASSERT1 m0pf, $00, c"Gr.10 $0 collision incorrect: $%x"
				_ASSERT1 m1pf, $00, c"Gr.10 $1 collision incorrect: $%x"
				_ASSERT1 m2pf, $00, c"Gr.10 $2 collision incorrect: $%x"
				_ASSERT1 m3pf, $00, c"Gr.10 $3 collision incorrect: $%x"
			.endif
			jsr		_waitVBL
			.if USEPLAYERS
					_ASSERT1 p0pf, $00, c"Gr.10 M0 bogus late collision: $%x"
					_ASSERT1 p1pf, $00, c"Gr.10 M1 bogus late collision: $%x"
					_ASSERT1 p2pf, $00, c"Gr.10 M2 bogus late collision: $%x"
					_ASSERT1 p3pf, $00, c"Gr.10 M3 bogus late collision: $%x"
					mva		#$79 hposp0
					mva		#$7b hposp1
					mva		#$7d hposp2
					mva		#$7f hposp3
			.else
				_ASSERT1 m0pf, $00, c"Gr.10 M0 bogus late collision: $%x"
				_ASSERT1 m1pf, $00, c"Gr.10 M1 bogus late collision: $%x"
				_ASSERT1 m2pf, $00, c"Gr.10 M2 bogus late collision: $%x"
				_ASSERT1 m3pf, $00, c"Gr.10 M3 bogus late collision: $%x"
		mva		#$79 hposm0
		mva		#$7b hposm1
		mva		#$7d hposm2
		mva		#$7f hposm3
			.endif
			sta		hitclr
			inc		wsync
			inc		wsync
			jsr		_waitVBL
			.if USEPLAYERS
					_ASSERT1 p0pf, $01, c"Gr.10 $4 collision incorrect: $%x"
					_ASSERT1 p1pf, $02, c"Gr.10 $5 collision incorrect: $%x"
					_ASSERT1 p2pf, $04, c"Gr.10 $6 collision incorrect: $%x"
					_ASSERT1 p3pf, $08, c"Gr.10 $7 collision incorrect: $%x"
					mva		#$81 hposp0
					mva		#$83 hposp1
					mva		#$85 hposp2
					mva		#$87 hposp3
			.else
				_ASSERT1 m0pf, $01, c"Gr.10 $4 collision incorrect: $%x"
				_ASSERT1 m1pf, $02, c"Gr.10 $5 collision incorrect: $%x"
				_ASSERT1 m2pf, $04, c"Gr.10 $6 collision incorrect: $%x"
				_ASSERT1 m3pf, $08, c"Gr.10 $7 collision incorrect: $%x"
		mva		#$81 hposm0
		mva		#$83 hposm1
		mva		#$85 hposm2
		mva		#$87 hposm3
			.endif
			sta		hitclr
			inc		wsync
			inc		wsync
			jsr		_waitVBL
			.if USEPLAYERS
					_ASSERT1 p0pf, $00, c"Gr.10 $8 collision incorrect: $%x"
					_ASSERT1 p1pf, $00, c"Gr.10 $9 collision incorrect: $%x"
					_ASSERT1 p2pf, $00, c"Gr.10 $A collision incorrect: $%x"
					_ASSERT1 p3pf, $00, c"Gr.10 $B collision incorrect: $%x"
					mva		#$89 hposp0
					mva		#$8b hposp1
					mva		#$8d hposp2
					mva		#$8f hposp3
			.else
				_ASSERT1 m0pf, $00, c"Gr.10 $8 collision incorrect: $%x"
				_ASSERT1 m1pf, $00, c"Gr.10 $9 collision incorrect: $%x"
				_ASSERT1 m2pf, $00, c"Gr.10 $A collision incorrect: $%x"
				_ASSERT1 m3pf, $00, c"Gr.10 $B collision incorrect: $%x"
		mva		#$89 hposm0
		mva		#$8b hposm1
		mva		#$8d hposm2
		mva		#$8f hposm3
			.endif
			sta		hitclr
			inc		wsync
			inc		wsync
			jsr		_waitVBL
			.if USEPLAYERS
					_ASSERT1 p0pf, $01, c"Gr.10 $C collision incorrect: $%x"
					_ASSERT1 p1pf, $02, c"Gr.10 $D collision incorrect: $%x"
					_ASSERT1 p2pf, $04, c"Gr.10 $E collision incorrect: $%x"
					_ASSERT1 p3pf, $08, c"Gr.10 $F collision incorrect: $%x"
			.else
				_ASSERT1 m0pf, $01, c"Gr.10 $C collision incorrect: $%x"
				_ASSERT1 m1pf, $02, c"Gr.10 $D collision incorrect: $%x"
				_ASSERT1 m2pf, $04, c"Gr.10 $E collision incorrect: $%x"
				_ASSERT1 m3pf, $08, c"Gr.10 $F collision incorrect: $%x"
			.endif
					;test gr.11 collisions
		mva		#$c0 prior
			jsr		checkcoll911
				_ASSERTA $00, c"Playfield collisions detected in Gr.11."
			jmp		_testPassed
		checkcoll911:
			jsr		_waitVBL
			.if USEPLAYERS
					mva		#$70 hposp0
					mva		#$72 hposp1
					mva		#$74 hposp2
					mva		#$76 hposp3
			.else
		mva		#$70 hposm0
		mva		#$72 hposm1
		mva		#$74 hposm2
		mva		#$76 hposm3
			.endif
			sta		hitclr
			inc		wsync
			inc		wsync
			jsr		_waitVBL
			.if USEPLAYERS
					lda		p0pf
					ora		p1pf
					ora		p2pf
					ora		p3pf
			.else
			lda		m0pf
			ora		m1pf
			ora		m2pf
			ora		m3pf
			.endif
			sta		d0
			.if USEPLAYERS
					mva		#$78 hposp0
					mva		#$7a hposp1
					mva		#$7c hposp2
					mva		#$7e hposp3
			.else
		mva		#$78 hposm0
		mva		#$7a hposm1
		mva		#$7c hposm2
		mva		#$7e hposm3
			.endif
			sta		hitclr
			inc		wsync
			inc		wsync
			jsr		_waitVBL
			lda		d0
			.if USEPLAYERS
					ora		p0pf
					ora		p1pf
					ora		p2pf
					ora		p3pf
			.else
			ora		m0pf
			ora		m1pf
			ora		m2pf
			ora		m3pf
			.endif
			sta		d0
			.if USEPLAYERS
					mva		#$80 hposp0
					mva		#$82 hposp1
					mva		#$84 hposp2
					mva		#$86 hposp3
			.else
		mva		#$80 hposm0
		mva		#$82 hposm1
		mva		#$84 hposm2
		mva		#$86 hposm3
			.endif
			sta		hitclr
			inc		wsync
			inc		wsync
			jsr		_waitVBL
			lda		d0
			.if USEPLAYERS
					ora		p0pf
					ora		p1pf
					ora		p2pf
					ora		p3pf
			.else
			ora		m0pf
			ora		m1pf
			ora		m2pf
			ora		m3pf
			.endif
			sta		d0
			.if USEPLAYERS
					mva		#$88 hposp0
					mva		#$8a hposp1
					mva		#$8c hposp2
					mva		#$8e hposp3
			.else
		mva		#$88 hposm0
		mva		#$8a hposm1
		mva		#$8c hposm2
		mva		#$8e hposm3
			.endif
			sta		hitclr
			inc		wsync
			inc		wsync
			jsr		_waitVBL
			lda		d0
			.if USEPLAYERS
					ora		p0pf
					ora		p1pf
					ora		p2pf
					ora		p3pf
			.else
			ora		m0pf
			ora		m1pf
			ora		m2pf
			ora		m3pf
			.endif
				rts
		testname:
	dta		c"GTIA: Special modes collision test",0
				org		$2800
		dlist:
			dta		$70
				dta		$70
				dta		$70
			dta		$4F,a(framebuf)
			dta		$41,a(dlist)
		framebuf:
	:12 dta $00
	dta		$01,$23,$45,$67,$89,$AB,$CD,$EF
	:12 dta $00
			run		$2000
					end
