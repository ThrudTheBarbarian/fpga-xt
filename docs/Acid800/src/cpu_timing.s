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
				_SAP_HEADER "CPU: Timing"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;test empty timing loop
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop1:
				dex
			bne		tloop1
			ldx		vcount
				_ASSERTX $05, c"Incorrect DEX/BNE cycle count: %d"
					;test NOP
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop2:
				nop
				dex
			bne		tloop2
			ldx		vcount
				_ASSERTX $07, c"Incorrect NOP cycle count: %d-5"
					;test LDA abs
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop3:
			lda		$0100
				dex
			bne		tloop3
			ldx		vcount
				_ASSERTX $09, c"Incorrect LDA abs cycle count: %d-5"
					;test LDA abs,X, no page crossing
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop4:
			lda		$0100,x
				dex
			bne		tloop4
			ldx		vcount
				_ASSERTX $09, c"Incorrect LDA abs,X (1) cycle count: %d-5"
					;test LDA abs,X, page crossing
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop5:
			lda		$01FF,x
				dex
			bne		tloop5
			ldx		vcount
				_ASSERTX $0A, c"Incorrect LDA abs,X (2) cycle count: %d-5"
					;test STA abs,X, no page crossing
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop6:
			sta		$2800,x
				dex
			bne		tloop6
			ldx		vcount
				_ASSERTX $0A, c"Incorrect STA abs,X (1) cycle count: %d-5"
					;test STA abs,X, page crossing
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop7:
			sta		$28FF,x
				dex
			bne		tloop7
			ldx		vcount
				_ASSERTX $0A, c"Incorrect STA abs,X (2) cycle count: %d-5"
					;test LDA zp
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop8:
			lda		$00
				dex
			bne		tloop8
			ldx		vcount
				_ASSERTX $08, c"Incorrect LDA zp cycle count: %d-5"
					;test LDA zp,X
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop9:
			lda		$00,x
				dex
			bne		tloop9
			ldx		vcount
				_ASSERTX $09, c"Incorrect LDA zp,X cycle count: %d-5"
					;test INC zp
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop10:
			inc		d0
				dex
			bne		tloop10
			ldx		vcount
				_ASSERTX $0A, c"Incorrect INC zp cycle count: %d-5"
					;test INC zp,X
			ldx		#0
				txa
			jsr		_waitVCount
			inc		wsync
			ldy		#210
		tloop11:
			inc		d0,x
				dey
			bne		tloop11
			ldx		vcount
				_ASSERTX $0B, c"Incorrect INC zp,X cycle count: %d-5"
					;test INC abs
			ldx		#0
				txa
			jsr		_waitVCount
			inc		wsync
			ldy		#210
		tloop12:
			inc		$2800
				dey
			bne		tloop12
			ldx		vcount
				_ASSERTX $0B, c"Incorrect INC abs cycle count: %d-5"
					;test INC abs,X
			ldx		#0
				txa
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop13:
			inc		$2800,x
				dex
			bne		tloop13
			ldx		vcount
				_ASSERTX $0C, c"Incorrect INC abs,X cycle count: %d-5"
					;test LDA (zp),y, no page crossing
	mwa		#$2800 a0
			ldy		#0
				tya
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop14:
			lda		(a0),y
				dex
			bne		tloop14
			ldx		vcount
				_ASSERTX $0A, c"Incorrect LDA (zp),Y (1) cycle count: %d-5"
					;test LDA (zp),y, page crossing
	mwa		#$28FF a0
			ldy		#1
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldx		#210
		tloop15:
			lda		(a0),y
				dex
			bne		tloop15
			ldx		vcount
				_ASSERTX $0B, c"Incorrect LDA (zp),Y (2) cycle count: %d-5"
					;test LDA (zp),X
	mwa		#$28FF a0
			ldx		#0
			lda		#0
			jsr		_waitVCount
			inc		wsync
			ldy		#210
		tloop16:
			lda		(a0,x)
				dey
			bne		tloop16
			ldx		vcount
				_ASSERTX $0B, c"Incorrect LDA (zp,X) cycle count: %d-5"
			jmp		_testPassed
		testname:
	dta		c"CPU: Timing",0
		testbuf	equ		$2800		;$2800-2FFF reserved
			run		$2000
					end
