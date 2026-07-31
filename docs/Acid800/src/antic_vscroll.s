			; Altirra Acid800 test suite
			; Copyright (C) 2010-2012 Avery Lee, All Rights Reserved.
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
				_SAP_HEADER "ANTIC: Vertical scrolling"
					opt		h+o+
					icl		'library.s'
		lines	equ		$80
				org		$2000
		main:
				_INITTEST	c"ANTIC: Vertical scrolling"
			jsr		_screenOff
			jsr		_interruptsOff
					;swap in new display list and VBI/DLI handlers
			jsr		_waitVBL
	mwa		#dli vdslst
	mwa		#dlist dlistl
		mva		#$22 dmactl
		mva		#3 vscrol
			mva		#$ff lines
		mva		#$80 nmien
			jsr		_waitFrame
	mwa		#dlist3 dlistl
		mva		#$0c vscrol
			jsr		_waitFrame
			jsr		_waitFrame
			ldx		#0
		chkloop:
			lda		lines,x
			cmp		chkdata,x
			bne		chkfail
				inx
			cpx		#5
			bne		chkloop
		mva		#0 nmien
			jmp		_testPassed
		chkfail:
			sta		d3
		mva		chkdata,x d2
				inx
			stx		d1
				_FAIL	c"Failed test #%d: expected %d, got %d"
		chkdata:
		dta		12, 16, 39, 49, 15
			;=========================================================================
		.proc	dli
				pha
			sta		wsync
			lda		vcount
				clc
			sta		wsync
			adc		vcount
			sta		lines
		lineidx = *-1
			inc		lineidx
			lda		lineidx
			cmp		#$82
			bne		notphase2
		mva		#9 vscrol
		notphase2:
				pla
				rti
			.endp
			;=========================================================================
				org		$2c00
		dlist:
			dta		$a2		;8	+5
				dta		$82		;13	+4
				dta		$70		;17 +8
				dta		$a2		;25	+15
				dta		$82		;40	+10
									;50
		dlist2:
			dta		$41,a(dlist2)
		dlist3:
	:29 dta	$70
				dta		$22
					;-- eof
				dta		$a2
				dta		$00
		dlist4:
			dta		$41,a(dlist4)
			run		main
					end
