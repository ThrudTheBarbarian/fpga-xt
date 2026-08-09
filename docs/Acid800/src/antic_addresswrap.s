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
				_SAP_HEADER "ANTIC: Address wrapping"
					opt		h+o+
					icl		'library.s'
				org		$2000
	:16 dta $00
				org		$2200
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
			jsr		_waitVBL
	mwa		#dlist dlistl
		mva		#$21 dmactl
		mva		#$00 prior
		mva		#$00 gractl
		mva		#$ff grafp0
		mva		#$ff grafp1
		mva		#$03 sizep0
		mva		#$03 sizep1
		mva		#$50 hposp0
		mva		#$90 hposp1
	mwa		#dli vdslst
					;wait a frame for new display list to take effect
			jsr		_waitFrame
					;flip on display list interrupts and clear collision flags
		mva		#$80 nmien
			sta		hitclr
					;wait another frame; if display list fails to wrap, ANTIC will fire a DLI
			jsr		_waitFrame
					;check if player 0 collided; this would mean that the LMS address was not
					;read properly.
				_ASSERT1 p0pf, $00, c"Display list LMS address did not wrap at 1K boundary."
					;check if player 1 collided; this would mean that playfield DMA did not
					;wrap properly.
				_ASSERT1 p1pf, $00, c"Playfield DMA did not wrap at 4K boundary."
					;all good
		mva		#0 nmien
			jmp		_testPassed
		dli:
		mva		#0 nmien
				_FAIL	c"Display list failed to wrap at 1K boundary."
		testname:
	dta		c"ANTIC: Address wrapping",0
			;==========================================================================
			; Test display list.
			;
			; The display list itself wraps around from $27fb to $2403, with the break
			; in the middle of an LMS address. The playfield is located at $2ff0 so
			; that it contains a 4K wrap back to $2000.
			;
				org		$2400
			dta		$2f				;high byte of $2ff0 LMS
			dta		$41,a(dlist)
				org		$27fb
		dlist:
			dta		$70
				dta		$70
				dta		$70
			dta		$4f,$f0,$3f		;1K address boundary in middle of address!
				dta		$80				;fire DLI to indicate failed display list wrap
			dta		$41,a(dlist)
				org		$2ff0
	:16	dta $00
	:16 dta $ff
				org		$3ff0
	:16 dta $ff
			run		main
					end
