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
				_SAP_HEADER "POKEY: Two-tone mode"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;clock all serial ports with channel 4, turn on two-tone mode, init
		mva		#$28 skctl
					;15KHz clocks all around
		mva		#$01 audctl
					;set timer 1 to 1 hblank, timer 2 to 2 hblanks, timer 4 to 16 hblanks
		mva		#0 audf1
		mva		#1 audf2
		mva		#15 audf4
		mva		#0 audc1
		mva		#0 audc2
		mva		#0 audc4
					;wait for scan 0
			lda		#0
			jsr		_waitVCount
					;reset serial port
			lda		#$2b
			sta		skctl
			sta		skres
					;write %11111100 to serial port
			lda		#$FC
			sta		stimer
			sta		serout
					;check for three spaces -- should be 6 cycles on timer 4, 32 cycles on timer 2
		mva		#0 irqen
		mva		#$02 irqen
			ldx		#0
		spaceloop:
			lda		irqst
			and		#$02
			bne		notimer2
		mva		#0 irqen
		mva		#2 irqen
				inx
		notimer2:
			lda		vcount
			cmp		#48
			bne		spaceloop
					;check for three marks
			ldy		#0
		markloop:
			lda		irqst
			and		#$02
			bne		notimer2a
		mva		#0 irqen
		mva		#2 irqen
				iny
		notimer2a:
			lda		vcount
			cmp		#96
			bne		markloop
					;shut down serial port
			lda		#0
			sta		skctl
			lda		#3
			sta		skctl
					;check values
					;the exact mechanism here is not clear yet, so tolerances are very loose
			cpx		#28
			bcs		pass1
			stx		d1
				_FAIL	c"Too few timer 2 interrupts on space: %d (should be 32)."
		pass1:
			cpx		#50
			bcc		pass2
			stx		d1
				_FAIL	c"Too many timer 2 interrupts on space: %d (should be 32)."
		pass2:
			cpy		#19
			bcc		pass4
			sty		d1
				_FAIL	c"Too many timer 2 interrupts on mark: %d (should be 16)."
		pass4:
			jmp		_testPassed
		testname:
	dta		c"POKEY: Two-tone mode",0
			run		$2000
					end
