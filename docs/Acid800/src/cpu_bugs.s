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
				_SAP_HEADER "CPU: Bugs"
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
					;test very famous bug
			jmp		(jmpbugvec)
				org		$2200
		jmpbugok:
					.ifdef SYSSAP
					jmp		_testPassed
					.else
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
			lda		$01				;113, 0, 1
				nop						;2, 3
					;This needs to start executing at cycle 4-8. If it executes at cycle
					;3 then it blocks the NMI!
				brk						;4, 5, 6, 7, 8, 9, 10
		after:
				_FAIL	c"Execution went past a BRK insn."
			;============================================================================
		.proc irq
				_FAIL	c"BRK handler should not have executed."
			.endp
			;============================================================================
				org		$2300
		.proc nmi
					;shut off all ANTIC interrupts, to be safe
	mva		#0 nmien
					;check return location, and see if it is in our test code; ignore
					;if it is in the OS or in the IRQ handler as then we need to let
					;the test fail
				tsx
					.ifdef SYS5200
					lda		$0103,x
					.else
			lda		$0106,x
					.endif
			cmp		#>brktest
			beq		retok
					;oops... return and let the IRQ routine fail
					.ifndef SYS5200
				pla
				tay
				pla
				tax
				pla
					.endif
				rti
		retok:
					;check low return byte
				tsx
					.ifdef SYS5200
					lda		$0102,x
					.else
			lda		$0105,x
					.endif
			sub		#<(after+1)
				_ASSERTA $00, c"NMI handler executed too early or late: %x"
					;check the B flag; it should be set
					.ifdef SYS5200
					lda		$0101,x
					.else
			lda		$0104,x
					.endif
			and		#$20
				_ASSERTA $20, c"B flag was not set on entry to NMI handler."
			jmp		_testPassed
			.endp
					.endif
			;============================================================================
		testname:
	dta		c"CPU: Bugs",0
			;============================================================================
				org		$2400
			dta		$24
				org		$2480
		jmp		jmpbugok
				org		$24ff
		jmpbugvec:
			dta		$80
				dta		$25
				org		$2580
				_FAIL	c"JMP indirect bug not found.",0
			;============================================================================
			run		$2000
					end
