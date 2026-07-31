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
				_SAP_HEADER "ANTIC: Playfield start timing"
					opt		h+o+
					icl		'library.s'
				org		$2000
			;DISPLAY_MODE = 1
			;EARLY_TIMING = 1
		main:
			.ifdef EARLY_TIMING
					_INITTEST c"ANTIC: Playfield start timing (early)"
			.else
				_INITTEST c"ANTIC: Playfield start timing"
			.endif
					;kill screen
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vertical blank and swap in new display list
			jsr		_waitVBL
	mwa		#dli1 vdslst
	mwa		#dlist dlistl
		mva		#$22 dmactl
		mva		#$80 hposp0
		mva		#$84 hposp1
		mva		#$f0 grafp0
		mva		#$f0 grafp1
		mva		#$00 sizep0
		mva		#$00 sizep1
		mva		#$00 gractl
		mva		#$80 nmien
		mva		#$07 vscrol
					.ifdef DISPLAY_MODE
					jmp		*
					.else
			jsr		_waitFrame
				_FAIL	c"DLIs did not fire."
					.endif
			;=========================================================================
		.proc dli1
		phr
			sta		wsync			;-> end line 31
		mva		#$07 vscrol
			lda		#$21
			ldx		#$22
				nop
			sta		wsync			;-> end line 32
			pha:pla					;*, 105, 106, 107, 108, 109, 110
			pha:pla					;111, 112, 113, 0, 1*, 2, 3, 4
			.ifdef EARLY_TIMING
					inc		a0
			.else
			nop:nop:nop				;5, 6*, 7*, 8, 9, 10, 11, 12
			.endif
			sta		dmactl			;13, 14, 15, 16
			sta		wsync
			stx		dmactl
			sta		hitclr
			sta		wsync
			lda		p0pf
				asl
				asl
			ora		p1pf
			add		#12
					.ifndef DISPLAY_MODE
				_ASSERTA 16, c"Character mode DMACTL early test failed: stride=%d"
					.endif
	mwa		#dli2 vdslst
		plr
				rti
			.endp
			;=========================================================================
		.proc dli2
		phr
			sta		wsync
		mva		#$07 vscrol
			lda		#$21
			ldx		#$22
				nop
			sta		wsync
			pha:pla					;*, 105, 106, 107, 108, 109, 110
			pha:pla					;111, 112, 113, 0, 1*, 2, 3, 4
			.ifdef EARLY_TIMING
					nop:nop:nop
			.else
			pha:pla					;5, 6*, 7*, 8, 9, 10, 11, 12, 13
			.endif
			sta		dmactl			;14, 15, 16, 17
			sta		wsync
			stx		dmactl
			sta		hitclr
			sta		wsync
			lda		p0pf
				asl
				asl
			ora		p1pf
			add		#12
					.ifndef DISPLAY_MODE
				_ASSERTA 18, c"Character mode DMACTL late test failed: stride=%d"
					.endif
	mwa		#dli3 vdslst
		plr
				rti
			.endp
			;=========================================================================
		.proc dli3
		phr
			sta		wsync
		mva		#$03 vscrol
			lda		#$21
			ldx		#$22
				nop
			sta		wsync
			pha:pla					;*, 105, 106, 107, 108, 109, 110
			pha:pla					;111, 112, 113, 0, 1*, 2, 3, 4
			.ifdef EARLY_TIMING
					inc		a0
			.else
			nop:nop:nop				;5, 6*, 7*, 8, 9, 10, 11, 12
			.endif
			sta		dmactl			;13, 14, 15, 16
			sta		wsync
			stx		dmactl
			sta		hitclr
			sta		wsync
			lda		p0pf
				asl
				asl
			ora		p1pf
			add		#12
					.ifndef DISPLAY_MODE
				_ASSERTA 16, c"Bitmap mode DMACTL early test failed: stride=%d"
					.endif
	mwa		#dli4 vdslst
		plr
				rti
			.endp
			;=========================================================================
		.proc dli4
		phr
			sta		wsync
		mva		#$03 vscrol
			lda		#$21
			ldx		#$22
				nop
			sta		wsync
			pha:pla					;*, 105, 106, 107, 108, 109, 110
			pha:pla					;111, 112, 113, 0, 1*, 2, 3, 4
			.ifdef EARLY_TIMING
					nop:nop:nop
			.else
			pha:pla					;5, 6*, 7*, 8, 9, 10, 11, 12, 13
			.endif
			sta		dmactl			;14, 15, 16, 17
			sta		wsync
			stx		dmactl
			sta		hitclr
			sta		wsync
			lda		p0pf
				asl
				asl
			ora		p1pf
			add		#12
					.ifndef DISPLAY_MODE
				_ASSERTA 18, c"Bitmap mode DMACTL late test failed: stride=%d"
					.endif
	mwa		#dli5 vdslst
		plr
				rti
			.endp
			;=========================================================================
		.proc dli5
		phr
			sta		wsync
		mva		#$07 vscrol
		mva		#$21 dmactl
			ldx		#$00
			stx		hscrol
			lda		#$08
				nop
			sta		wsync
			pha:pla					;*, 105, 106, 107, 108, 109, 110
			pha:pla					;111, 112, 113, 0, 1*, 2, 3, 4
			nop:nop:nop				;5, 6*, 7*, 8, 9, 10, 11, 12
			sta		hscrol			;13, 14, 15, 16
			sta		wsync
			stx		hscrol
			sta		hitclr
			sta		wsync
			lda		p0pf
				asl
				asl
			ora		p1pf
			add		#10
					.ifndef DISPLAY_MODE
				_ASSERTA 16, c"Character mode HSCROL early test failed: stride=%d"
					.endif
	mwa		#dli6 vdslst
		plr
				rti
			.endp
			;=========================================================================
		.proc dli6
		phr
			sta		wsync
		mva		#$07 vscrol
		mva		#$21 dmactl
			ldx		#$00
			stx		hscrol
			lda		#$08
				nop
			sta		wsync
			pha:pla					;*, 105, 106, 107, 108, 109, 110
			pha:pla					;111, 112, 113, 0, 1*, 2, 3, 4
			pha:pla					;5, 6*, 7*, 8, 9, 10, 11, 12, 13
			sta		hscrol			;14, 15, 16, 17
			sta		wsync
			stx		hscrol
			sta		hitclr
			sta		wsync
			lda		p0pf
				asl
				asl
			ora		p1pf
			add		#10
					.ifndef DISPLAY_MODE
				_ASSERTA 17, c"Character mode HSCROL late test failed: stride=%d"
					.endif
	mwa		#dli7 vdslst
		plr
				rti
			.endp
			;=========================================================================
		.proc dli7
		phr
			sta		wsync
		mva		#$03 vscrol
		mva		#$21 dmactl
			ldx		#$00
			stx		hscrol
			lda		#$08
				nop
			sta		wsync
			pha:pla					;*, 105, 106, 107, 108, 109, 110
			pha:pla					;111, 112, 113, 0, 1*, 2, 3, 4
			nop:nop:nop				;5, 6*, 7*, 8, 9, 10, 11, 12
			sta		hscrol			;13, 14, 15, 16
			sta		wsync
			stx		hscrol
			sta		hitclr
			sta		wsync
			lda		p0pf
				asl
				asl
			ora		p1pf
			add		#10
					.ifndef DISPLAY_MODE
				_ASSERTA 16, c"Bitmap mode HSCROL early test failed: stride=%d"
					.endif
	mwa		#dli8 vdslst
		plr
				rti
			.endp
			;=========================================================================
		.proc dli8
		phr
			sta		wsync
		mva		#$03 vscrol
		mva		#$21 dmactl
			ldx		#$00
			stx		hscrol
			lda		#$08
				nop
			sta		wsync
			pha:pla					;*, 105, 106, 107, 108, 109, 110
			pha:pla					;111, 112, 113, 0, 1*, 2, 3, 4
			pha:pla					;5, 6*, 7*, 8, 9, 10, 11, 12, 13
			sta		hscrol			;14, 15, 16, 17
			sta		wsync
			stx		hscrol
			sta		hitclr
			sta		wsync
			lda		p0pf
				asl
				asl
			ora		p1pf
			add		#10
					.ifndef DISPLAY_MODE
				_ASSERTA 17, c"Bitmap mode HSCROL late test failed: stride=%d"
		mva		#$00 nmien
			jmp		_testPassed
					.else
					mva		#$22 dmactl
					mwa		#dli1 vdslst
					plr
					rti
					.endif
			.endp
			;=========================================================================
				org		$2c00
		dlist:
			dta		$70					;8-15
				dta		$70					;16-23
					;DMACTL test - character mode
				dta		$f0					;24-31
				dta		$00					;32
			dta		$66,a(framedata)	;33
				dta		$0a					;34-41
				dta		$f0					;42-49
				dta		$00
			dta		$66,a(framedata)
				dta		$0a
					;DMACTL test - bitmap mode
				dta		$f0
				dta		$00
			dta		$6a,a(framedata)
				dta		$0a
				dta		$f0
				dta		$00
			dta		$6a,a(framedata)
				dta		$0a
					;HSCROL test - character mode
				dta		$f0
				dta		$00
			dta		$76,a(framedata)
				dta		$0a
				dta		$f0
				dta		$00
			dta		$76,a(framedata)
				dta		$0a
					;HSCROL test - bitmap mode
				dta		$f0
				dta		$00
			dta		$7a,a(framedata)
				dta		$0a
				dta		$f0
				dta		$00
			dta		$7a,a(framedata)
				dta		$0a
		dlist2:
					.ifndef DISPLAY_MODE
			dta		$41,a(dlist2)
					.else
					dta		$41,a(dlist)
					.endif
				org		$2d00
		framedata:
	:22 dta $00
			dta		$00,$01,$08,$09
			dta		$10,$11,$18,$19
			dta		$80,$81,$88,$89
			dta		$90,$91,$98,$99
			run		$2000
					end
