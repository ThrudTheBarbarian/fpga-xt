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
				_SAP_HEADER "ANTIC: Virtual DMA"
					opt		h+o+
		results	equ		$80
					icl		'library.s'
				org		$2000
		main:
				_INITTEST	c"ANTIC: Virtual DMA"
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vertical blank
			jsr		_waitVBL
					;initialize wide display, horizontally +2 scrolled mode 7 screen
	mwa		#dlist dlistl
		mva		#$23 dmactl
		mva		#$02 hscrol
					;set up collision detect sprites along right border
			lda		#$00
			sta		gractl
		mva		#$aa grafm
		mva		#$da hposm3
		mva		#$db hposm2
		mva		#$dc hposm1
		mva		#$dd hposm0
					;Check virtual DMA.
					;
					;The DMA pattern for the scan lines we care about looks like this:
					;
					;           1         2         3         4         5         6         7         8         9         0         1
					; 012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123
					;..............C...C...C..RC..RC..RC..RC..RC..RC..RC..RC..RC...C...C...C...C...C...C...C...C...C...C...C...V.......
					;
					;Therefore, at the end, our execution looks as follows:
					;
					;	(prev)	LDA abs (1/4)
					;	104		LDA abs (2/4)   (RDY released)
					;	105		LDA abs (3/4)	(sampled by playfield DMA)
					;	106		LDA abs (4/4)
					;	107		LDA m0pf (1/4)
					;	108		LDA m0pf (2/4)
					;	109		LDA m0pf (3/4)
					;	110		LDA m0pf (4/4)
					;	111		STA zp (1/3)
					;	112		STA zp (2/3)
					;	113		STA zp (3/3)
					;	0		LDA m1pf (1/4)
					;	1		LDA m1pf (2/4)
					;	2		LDA m1pf (3/4)
					;	3		LDA m1pf (4/4)
					;	4		STA zp (1/3)
					;	5		STA zp (2/3)
					;	6		STA zp (3/3)
					;	7		LDA m1pf (1/4)
					;	8		LDA m1pf (2/4)
					;	9		LDA m1pf (3/4)
					;	10		LDA m1pf (4/4)
					;	11		STA zp (1/3)
					;	12		STA zp (2/3)
					;	13
					;	14		STA zp (3/3)
					;	15		LDA m1pf (1/4)
					;	16		LDA m1pf (2/4)
					;	17
					;	18		LDA m1pf (3/4)
					;	19		LDA m1pf (4/4)
					;	20		STA zp (1/3)
					;	21
					;	22		STA zp (2/3)
					;	23		STA zp (3/3)
					;	24
					;	25
					;	26		STA hitclr (1/4)
					;	27		STA hitclr (2/4)
					;	28
					;	29
					;	30		STA hitclr (3/4)
					;	31		STA hitclr (4/4)
					;	32
					;	33
					;	34		STA wsync,X (1/5)
					;	35		STA wsync,X (2/5)
					;	36
					;	37
					;	38		STA wsync,X (3/5)
					;	39		STA wsync,X (4/5)
					;	40
					;	41
					;	42		STA wsync,X (5/5)
					;	43		LDA abs (1/4)
					;
					;We need to use STA wsync,X in order to push the WSYNC write out one cycle so that the next
					;cycle is not a DMA cycle.
			ldx		#0
			lda		#32/2
		cmp:rne	vcount
			sta		wsync				;end scanline 32
				nop
				nop
			sta		hitclr
			sta		wsync				;end scanline 33
			lda		$0100
		mva		m0pf results+0
		mva		m1pf results+1
		mva		m2pf results+2
		mva		m3pf results+3
			sta		hitclr
			sta		wsync,X				;end scanline 34
			lda		$5000
		mva		m0pf results+4
		mva		m1pf results+5
		mva		m2pf results+6
		mva		m3pf results+7
			sta		hitclr
			sta		wsync,X				;end scanline 35
			lda		$c000
		mva		m0pf results+8
		mva		m1pf results+9
		mva		m2pf results+10
		mva		m3pf results+11
			sta		hitclr
			sta		wsync,X				;end scanline 36
			lda		$f000
		mva		m0pf results+12
		mva		m1pf results+13
		mva		m2pf results+14
		mva		m3pf results+15
			sta		hitclr
			sta		wsync,X				;end scanline 37
			ldx		#0
			jsr		GetPattern
				_ASSERTA $00, c"Pattern #1 was not correct: %x != $00"
			ldx		#4
			jsr		GetPattern
				_ASSERTA $05, c"Pattern #2 was not correct: %x != $05"
			ldx		#8
			jsr		GetPattern
				_ASSERTA $0c, c"Pattern #3 was not correct: %x != $0c"
			ldx		#12
			jsr		GetPattern
				_ASSERTA $0f, c"Pattern #4 was not correct: %x != $0f"
			jmp		_testPassed
			;==========================================================================
		.proc GetPattern
			lda		results+3,x
				asl
			ora		results+2,x
				asl
			ora		results+1,x
				asl
			ora		results+0,x
				rts
			.endp
			;==========================================================================
				org		$2400
		dlist:
			dta		$70
				dta		$70
				dta		$70
			dta		$57,a(framebuf)
			dta		$41,a(dlist)
		framebuf:
	:48	dta $00
			run		$2000
					end
