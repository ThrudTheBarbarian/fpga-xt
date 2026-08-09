			; Altirra Acid800 test suite
			; Copyright (C) 2010-2011 Avery Lee, All Rights Reserved.
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
		ANALYSIS = 0
				_SAP_HEADER "ANTIC: HSCROL bug"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
				_INITTEST c"ANTIC: HSCROL bug"
					;init framebuffer
			lda		#0
				tax
		sta:rne	framebuf,x+
			lda		#$aa
			ldx		#31
		fillloop:
			eor		#$ff
			sta		framebuf+44,x-
			eor		#$ff
			sta		framebuf+44,x-
			bpl		fillloop
			lda		#$ff
			sta		framebuf+44
			sta		framebuf+44+31
					;kill screen
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vertical blank and swap in new display list
			jsr		_waitVBL
	mwa		#dlist dlistl
		mva		#$21 dmactl
					;set up collision detection sprites
		mva		#0 gractl
			lda		#$80
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			sta		sizep0
			sta		sizep1
			sta		sizep2
			sta		sizep3
		mva		#$40 hposp0			;left border - narrow playfield
		mva		#$bf hposp1			;right border - narrow playfield
			lda		#$04
			sta		colpm0
			sta		colpm1
			sta		colpm2
			sta		colpm3
					;Wait for second scan line of mode E line and skew it.
					;
					;At HSCROL=0, hscrolled narrow mode E fetches bytes every two clocks
					;at clocks 19-97. What we do here is temporary glitch HSCROL to move
					;the PF stop cycle, which causes ANTIC to fail to stop the playfield
					;counter. This causes it to continue fetching through horizontal blank.
					;Since the original fetch offset was odd, the extra fetches miss the
					;display list instruction fetch at cycle 0.
					;
					;We restore HSCROL immediately after so that the fetch pattern for
					;the new scanline lines up; otherwise, ANTIC would fetch at double rate
					;and the scanline would instead display the OR of adjacent bytes. This
					;way, the second scanline displays as usual, except that it is shifted
					;left by 17 bytes (the number of extra fetches in HBLANK).
					;
					;This is the pattern of DMA cycles on the two scanlines:
					;                                                                                                     1         1
					;           1         2         3         4         5         6         7         8         9         0         1
					; 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123
					; .D..................F.F.FRF.FRF.FRF.FRF.FRF.FRF.FRF.FRF.FRF.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.#.#.#.#.
					; #DF.F.F.F.F.F.F.F.F.F.F.FRF.FRF.FRF.FRF.FRF.FRF.FRF.FRF.FRF.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F.F...............
					; ^ ^ ^ ^ ^ ^ ^ ^ ^ ^                                     |                                           ^ ^ ^ ^ ^ ^ ^
					;         |                                           test byte
					;     offset zero
					;
					; Legend:
					;   ^  Extra cycle location
					;   F  Playfield fetch w/DMA cycle
					;   #  Playfield fetch, but DMA cycle suppressed
					;   R  Memory refresh cycle
					;
					;Analysis mode also replays the line buffer on an additional mode $0D
					;line, revealing the first 32 bytes of the internal contents to be:
					;
					;55 AA 55 AA 55 AA 55 AA 55 AA 55 AA 55 AA 55 AA
					;55 AA 55 AA 55 AA 55 AA FF 00 00 00 00 00 00 00
					;
					;The test requires the $FF byte at buffer position $18 to be displayed
					;at horizontal positions $78-$7B, or the normal position for byte $12
					;in a normal mode E line. This means that the line buffer address was
					;advanced by six additional locations due to the abnormal DMA condition.
		frameloop:
					;position missiles
		mva		#$78 hposp2			;left border of last byte, shifted
		mva		#$7b hposp3			;right border of last byte, shifted
					;wait for scanline to start at
			ldx		#14
		cpx:rne	vcount		;end 27 or 28
				inx
		cpx:rne	vcount		;end 29
			ldy		#0
			sty		hscrol
			sta		wsync		;end 30
			sta		wsync		;end 31
			lda		#2			;*, 104
			ldx		#8			;105, 106
			dex:rne
			sta		hscrol		;71, 73, 75, 77
			pha:pla				;79, 81, 83, 85, 87, 89, 91
			sta		$0100		;93, 95, 97, 99
			sty		hscrol		;101, 103, 105, 107
					;clear collisions and wait for the scanline to pass
			sta		hitclr
			sta		wsync		;end 33
					;check collisions
			lda		p0pf
			ldx		p1pf
			ldy		p2pf
			sta		d0
			lda		p3pf
			stx		d1
			sty		d2
			sta		d3
			.if ANALYSIS
					;replay the line buffer on a normal scanline (the blank line will have
					;cleared out any abnormalities)
					sta		wsync		;end 34
					mva		#$20 dmactl
					ldx		#10
					dex:rne
					mva		#$21 dmactl
					sta		wsync		;end 35
			.else
			sta		wsync
				_ASSERT1 d2, $04, c"Unstopped PF DMA test failed: cl=%x"
				_ASSERT1 d3, $04, c"Unstopped PF DMA test failed: cr=%x"
				_ASSERT1 d0, $01, c"Unstopped PF DMA test failed: l=%x"
				_ASSERT1 d1, $00, c"Unstopped PF DMA test failed: r=%x"
			sta		wsync
			.endif
					;Repeat the test with odd cycles instead of even cycles. This is more
					;troublesome as the abnormal DMA pattern overlaps the display list
					;fetch, so instead we turn off display list DMA so that the $5E byte
					;is reused. The LMS part will be safely ignored.
		mva		#$7a hposp2			;left border of last byte, shifted
		mva		#$7d hposp3			;right border of last byte, shifted
			ldy		#2
			sty		hscrol
			sta		wsync		;end 36
			lda		#4			;*, 104
			ldx		#8			;105, 106
			dex:rne
			sta		hscrol		;71, 73, 75, 77
			pha:pla				;79, 81, 83, 85, 87, 89, 91
			lda		#$01		;93, 95
			sta		dmactl		;97, 99, 101, 103
			sty		hscrol		;101, 103, 105, 107
					;clear collisions and wait for the scanline to pass
			sta		hitclr
			pha:pla
			lda		#$21
			sta		dmactl
			sta		wsync		;end 37
					;check collisions
			lda		p0pf
			ldx		p1pf
			ldy		p2pf
			sta		d0
			lda		p3pf
			stx		d1
			sty		d2
			sta		d3
			.if ANALYSIS
					;replay the line buffer on a normal scanline (the blank line will have
					;cleared out any abnormalities)
					sta		wsync		;end 37
					mva		#$20 dmactl
					ldx		#10
					dex:rne
					mva		#$21 dmactl
					sta		wsync		;end 38
					jsr		_waitVBL
					jmp		frameloop
			.else
				_ASSERT1 d2, $04, c"Unstopped PF DMA test #2 failed: cl=%x"
				_ASSERT1 d3, $04, c"Unstopped PF DMA test #2 failed: cr=%x"
				_ASSERT1 d0, $02, c"Unstopped PF DMA test #2 failed: l=%x"
				_ASSERT1 d1, $00, c"Unstopped PF DMA test #2 failed: r=%x"
			jmp		_testPassed
			.endif
			;=========================================================================
				org		$2c00
		dlist:
			dta		$70					;8
				dta		$70					;16
				dta		$70					;24
			dta		$5E,a(framebuf)		;32
				dta		$1E					;33
			.if ANALYSIS
					dta		$00,$0D				;34
			.else
				dta		$20					;34
			.endif
			dta		$5E,a(framebuf)		;37
												;38 (done with disabled DL DMA)
			.if ANALYSIS
					dta		$00,$0D				;39
			.endif
			dta		$41,a(dlist)
				org		$2d00
		framebuf:
			run		$2000
					end
