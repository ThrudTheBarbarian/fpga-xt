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
				_SAP_HEADER "GTIA: Vertical Delay"
					opt	o-
					org	$80
			result0	dta	0
			result1	dta	0
					opt		h+o+
					icl		'library.s'
				org		$2000
			;==============================================================
		.proc main
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
					;initialize sprite memory
			lda		#0
				tax
		fill:
			sta		sprmem,x
			sta		sprmem+$0100,x
			sta		sprmem+$0200,x
			sta		sprmem+$0300,x
			eor		#$ff
				inx
			bne		fill
					;screen, ints off
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vblank
			jsr		_waitVBL
					;initialize test display
	mwa		#dlist dlistl
					;set up sprites and turn on display
		mva		#$29 dmactl
		mva		#>sprmem pmbase
		mva		#$07 gractl
		mva		#$01 prior
			ldx		#21
	mva:rpl	sprdata,x $d000,x-
		mva		#$00 vcount
					;run kernel
			lda		#$10
		cmp:rne	vcount
			sta		wsync		;end 32
			sta		wsync		;end 33
					;test no vdelay -- should be on, on, off, off
			sta		hitclr
			sta		wsync		;end 34
			lda		p0pf
			and		p2pf
			and		m0pf
			and		m2pf
			sta		hitclr
				_ASSERTA $01, 'No delay 1/4 failed: %x != $01'
			sta		wsync		;end 35
			lda		p1pf
			and		p3pf
			and		m1pf
			and		m3pf
			sta		hitclr
				_ASSERTA $01, 'No delay 2/4 failed: %x != $01'
			sta		wsync		;end 36
			lda		p0pf
			ora		p2pf
			ora		m0pf
			ora		m2pf
			sta		hitclr
				_ASSERTA $00, 'No delay 3/4 failed: %x != $00'
			sta		wsync		;end 37
			lda		p1pf
			ora		p3pf
			ora		m1pf
			ora		m3pf
			sta		hitclr
				_ASSERTA $00, 'No delay 4/4 failed: %x != $00'
					;test vdelay -- should be off, on, on, off
			sta		wsync		;end 38
		mva		#$ff vdelay
			sta		wsync		;end 39 - 1
			sta		wsync		;end 40 - 0 no load
			sta		wsync		;end 41 - 0 load
			sta		hitclr
			sta		wsync		;end 42 - 1 no load
			lda		p0pf
			and		p2pf
			and		m0pf
			and		m2pf
			sta		hitclr
				_ASSERTA $00, 'Delay 1/4 failed: %x != $00'
			sta		wsync		;end 43 - 1 load
			lda		p1pf
			and		p3pf
			and		m1pf
			and		m3pf
			sta		hitclr
				_ASSERTA $01, 'Delay 2/4 failed: %x != $01'
			sta		wsync		;end 44 - 0 no load
			lda		p0pf
			and		p2pf
			and		m0pf
			and		m2pf
			sta		hitclr
				_ASSERTA $01, 'Delay 3/4 failed: %x != $01'
			sta		wsync		;end 45
			lda		p1pf
			ora		p3pf
			ora		m1pf
			ora		m3pf
			sta		hitclr
				_ASSERTA $00, 'Delay 4/4 failed: %x != $00'
			jmp		_testPassed
		sprdata:
			dta		$80, $88, $90, $98		;HPOSPx
			dta		$a0, $a8, $b0, $b8		;HPOSMx
			dta		$00, $00, $00, $00		;SIZEPx
				dta		$00						;SIZEMx
			dta		$00, $00, $00, $00		;GRAFPx
				dta		$00						;GRAFM
			dta		$18, $38, $58, $78		;COLPMx
		testname:
	dta		c"GTIA: Vertical delay",0
			.endp
			;==============================================================
				org		$2800
		dlist:
			dta		$70
				dta		$70
				dta		$70
	:16 dta	$4c, a(testpat)
			dta		$41, a(dlist)
		testpat:
	:20 dta $ff
				org		$2c00
		sprmem:
			run		main
					end
