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
				_SAP_HEADER "ANTIC: WSYNC timing"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
		mva		#$80 audctl
		mva		#0 skctl
			sta		wsync
			lda		#3
			sta		wsync
			sta		skctl
			sta		wsync
			ldy		random			;*, 105, 106, 107
			sty		d0				;108, 109, 110
				nop						;111, 112
			sta		wsync			;113, 0, 1, 2
			lda		random			;*, 105, 106, 107
			sta		d1				;108, 109, 110
			inc		wsync			;111, 112, 113, 0, 1, 2
			lda		random			;105, 106, 107, 108
			sta		d2
			sta		wsync			;*, 105-107
			ldx		#19				;*, 105
			dex:rne					;106-113, 0-94
			bit		$00				;95-97
				nop						;98-99
			sta		wsync			;100-103
			lda		random
			sta		d3
			sta		wsync			;*, 105-107
			ldx		#19				;*, 105
			dex:rne					;106-113, 0-94
			bit		$0100			;95-98
				nop						;99-100
			sta		wsync			;101-104
			lda		random
			sta		d4
			sta		wsync			;*, 105-107
			ldx		#19				;*, 105
			dex:rne					;106-113, 0-94
			bit		$0100			;95-98
			inc		wsync			;99-104
			lda		random
			sta		d5
					;check values
				_ASSERT1 d0, $95, c"Initial RANDOM incorrect: $%x != $95.",0
				_ASSERT1 d1, $4B, c"STA WSYNC failed: $%x != $4B.",0
					;skip checking the INC test on a CMOS CPU since they do not stop for RDY on write
					;cycles
			lda		_cpuMode
			bne		skip_inc_check
				_ASSERT1 d2, $0D, c"INC WSYNC failed: $%x != $0D.",0
		skip_inc_check:
				_ASSERT1 d3, $44, c"Early WSYNC failed: $%x != $44."
				_ASSERT1 d4, $E2, c"Late WSYNC failed: $%x != $E2."
				_ASSERT1 d5, $34, c"Late INC WSYNC failed: $%x != $34."
			jmp		_testPassed
					;set noise generator to long mode and read a byte
		testname:
	dta		c"ANTIC: WSYNC timing",0
			run		$2000
					end
