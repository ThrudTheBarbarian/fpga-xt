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
				_SAP_HEADER "ANTIC: Display list wrapping"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;=== test #1: check that a display list >240 lines is continued next frame
			jsr		_waitVBL
	mwa		#dlist1 dlistl
		mva		#$21 dmactl
		mva		#$00 prior
		mva		#$80 nmien
	mwa		#dli vdslst
			mva		#0 d0
					;wait a frame for new display list to take effect
			jsr		_waitFrame
					;wait another frame
			jsr		_waitFrame
					;check that we saw a DLI
				_ASSERT1 d0, $01, c"Display list did not wrap around."
					;=== test #2: check that DLIs are carried over vblank with display list DMA enabled
			jsr		_waitVBL
	mwa		#dlist2 dlistl
		mva		#$21 dmactl
		mva		#$00 nmien
			mva		#0 d0
					;wait until scan line 14/15, then nuke display list DMA
			lda		#7
			jsr		_waitVCount
		mva		#$00 dmactl
					;wait for vblank
			jsr		_waitFrame
					;wait for scan line 32 on next frame, then turn on DLIs
			lda		#16
			jsr		_waitVCount
		mva		#$80 nmien
					;wait for vblank
			jsr		_waitFrame
					;check that we saw the DLI
				_ASSERT1 d0, $01, c"DLI was not carried over around VBLANK."
					;=== test #3: check that NMIRES does not clear a pending DLI
			jsr		_waitVBL
	mwa		#dlist2 dlistl
		mva		#$21 dmactl
		mva		#$00 nmien
			mva		#0 d0
					;wait until scan line 14/15, then nuke display list DMA
			lda		#7
			jsr		_waitVCount
		mva		#$00 dmactl
					;wait for vblank
			jsr		_waitFrame
					;wait for scan line 32 on next frame, then strobe NMIRES and turn on DLIs
			lda		#16
			jsr		_waitVCount
			inc		wsync
			pha:pla					;105-111
			pha:pla					;112-113, 0-4
			pha:pla					;5-11
			pha:pla					;12-18
		mva		#$80 nmien
			sta		nmires
					;wait for vblank
			jsr		_waitFrame
					;check that we saw the DLI
				_ASSERT1 d0, $01, c"NMIRES improperly cleared pending DLI."
					;all good
		mva		#0 nmien
			jmp		_testPassed
		dli:
				pha
			mva		#1 d0
		mva		#0 nmien
				pla
				rti
		testname:
	dta		c"ANTIC: Display list wrapping",0
				org		$2400
		dlist1:
	:30 dta $70
				dta		$70
				dta		$f0
			dta		$41,a(dlist1)
		dlist2:
				dta		$f0
	:40 dta $70
			dta		$41,a(dlist2)
			run		$2000
					end
