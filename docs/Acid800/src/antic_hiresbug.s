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
				_SAP_HEADER "ANTIC: Hires bug"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
		mva		#0 gractl
		mva		#$ff grafp0
		mva		#$ff grafp1
		mva		#$80 hposp0
		mva		#$80 hposp1
	mwa		#dli vdslst
					;test collision without bug
			jsr		_waitVBL
	mwa		#dlist1 dlistl
		mva		#$80 nmien
		mva		#$22 dmactl
			mva		#0 d1
			sta		wsync
			sta		wsync
			jsr		_waitVBL
			mva		d1 d0
					;test collision with bug
			jsr		_waitVBL
	mwa		#dlist2 dlistl
		mva		#$80 nmien
		mva		#$22 dmactl
			mva		#0 d1
			sta		wsync
			sta		wsync
			jsr		_waitVBL
		mva		#0 dmactl
		mva		#0 nmien
				_ASSERT1 d0, $00, c"Collision was found without bug: $%x"
				_ASSERT1 d1, $02, c"Collision not found with bug: $%x"
			jmp		_testPassed
		dli:
				pha
			sta		wsync
			sta		hitclr
			sta		wsync
			sta		wsync
			lda		p0pl
			and		#$02
			sta		d1
		mva		#0 nmien
				pla
				rti
		testname:
	dta		c"ANTIC: Hires bug",0
				org		$2400
		dlist1:
	:29 dta $70
				dta		$60
				dta		$80
			dta		$41, a(dlist1)
		dlist2:
	:29 dta $70
				dta		$60
			dta		$CF, a($2000)
			dta		$41, a(dlist2)
			run		$2000
					end
