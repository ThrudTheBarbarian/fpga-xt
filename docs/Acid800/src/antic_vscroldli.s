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
				_SAP_HEADER "ANTIC: VSCROL+NMI timing"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
				_INITTEST	c"ANTIC: VSCROL+NMI timing"
			jsr		_screenOff
			jsr		_interruptsOff
					;swap in new display list and VBI/DLI handlers
			jsr		_waitVBL
			inc		wsync			;make sure we're not before VBI start
			inc		wsync
	mwa		#dlist dlistl
		mva		#$20 dmactl
			sta		nmires
		mva		#0 vscrol
			ldx		#1
			ldy		#0
					;set VSCROL just barely in time, make sure it takes effect
			lda		#19
		cmp:req	vcount
		cmp:rne	vcount
			sta		nmires
			sta		wsync		;end 38
			sta		wsync		;end 39
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
			stx		vscrol		;0, 1, 2, 3
			pha:pla
			lda		nmist
			sty		vscrol
			and		#$80
				_ASSERTA $00, c"VSCROL took effect too late."
					;look for cycle-exact timing
			lda		#27
		cmp:req	vcount
		cmp:rne	vcount
			sta		nmires
			sta		wsync		;end 54
			sta		wsync		;end 55
			sta		wsync		;end 56
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			inc		d0			;110, 111, 112, 113, 0
			stx		vscrol		;1, 2, 3, 4
			pha:pla
			lda		nmist
			sty		vscrol
			and		#$80
				_ASSERTA $80, c"VSCROL took effect too early."
			jmp		_testPassed
			;=========================================================================
				org		$2c00
		dlist:
			dta		$70		;8
				dta		$70		;16
				dta		$70		;24
				dta		$28		;32
				dta		$f0		;40
				dta		$70		;41
				dta		$28		;49
				dta		$f0		;57
			dta		$41,a(dlist)
			run		$2000
					end
