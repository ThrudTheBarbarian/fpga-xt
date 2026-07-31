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
				_SAP_HEADER "ANTIC: Blocked NMIs"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
					;skip if we are running a CMOS variant
			lda		_cpuMode
			beq		is6502
				_SKIP	c"65C02/65C816 detected."
		is6502:
			jsr		_screenOff
			jsr		_interruptsOff
					;Test for BRK bug.
					;
					;We need an NMI to do this -- we'll use the VBI, since it's easy to set
					;up.
	mwa		#irq vimirq
	mwa		#nmi vvblki
			lda		#246/2
		cmp:req	vcount
		cmp:rne	vcount			;end scan 245
			sta		wsync			;end scan 246
			sta		wsync			;end scan 247
		brktest:
		mva		#$40 nmien		;*, 104, 105, 106, 107, 108
			lda		$0100			;109, 110, 111, 112
				nop						;113, 0
				nop						;1, 2
				brk						;3, 4, 5, 6, 7, 8, 9
		after:
				_FAIL	c"Execution went past BRK insn #1."
			;============================================================================
		.proc nmi
					;shut VBI back off
		mva		#0 nmien
				_FAIL	c"VBI handler should not have executed."
			.endp
			;============================================================================
		.proc irq
	mwa		#irq2 vimirq
	mwa		#nmi2 vvblki
		mva		#0 nmien
			lda		#246/2
		cmp:req	vcount
		cmp:rne	vcount			;end scan 245
			sta		wsync			;end scan 246
			sta		wsync			;end scan 247
		mva		#$40 nmien		;*, 104, 105, 106, 107, 108
			lda		$0100			;109, 110, 111, 112
				nop						;113, 0
			lda		$ff				;1, 2, 3
				brk						;4, 5, 6, 7, 8, 9, 10
		after:
				_FAIL	c"Execution went past BRK insn #2."
			.endp
			;============================================================================
		.proc nmi2
					;shut VBI back off
		mva		#0 nmien
					;check return address
				tsx
					.ifdef SYS5200
					lda		$0102,x
					.else
			lda		$0105,x
					.endif
			cmp		#<(irq.after+1)
			bne		irq2
					.ifdef SYS5200
					lda		$0103,x
					.else
			lda		$0106,x
					.endif
			cmp		#>(irq.after+1)
			bne		irq2
			jsr		_testPassed
			.endp
			;============================================================================
		.proc irq2
				_FAIL	c"BRK handler should not have executed."
			.endp
			;============================================================================
		testname:
	dta		c"ANTIC: Blocked NMIs",0
			;============================================================================
			run		$2000
					end
