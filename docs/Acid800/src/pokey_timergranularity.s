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
				_SAP_HEADER "POKEY: 1.79MHz timer granularity"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;switch timer 1 to high resolution
		mva		#$40 audctl
					;set timer 1 to fire every 50 cycles
		mva		#50-4 audf1
		mva		#0 audc1
					;set irq vector
	mwa		#irq1 vimirq
					;enable timer 1 interrupt
		mva		#$01 irqen
					;clear counter
			mvx		#0	d0
			ldy		#10
					;wait for the beginning of scan 0
		cpx:req	vcount
		cpx:rne	vcount
					;let 'er rip
			sta		wsync
			sta		stimer
				cli
		cpy:rne	vcount
					;clear timer
		mva		#0 irqen
					;the above loop runs for about 2280 cycles, so we expect to see
					;about 44 iterations... pass between 39 and 49
			cpx		#39
			bcc		fail
			cpx		#49
			bcs		fail
			jmp		_testPassed
		fail:
			stx		d1
			jsr		_testFailed
	dta		c"Iteration count was %d (should be 39-49)",0
			;===========================================================
			; Worst case timing for this handler:
			;
			;	3 cycles	Finish current instruction
			;	7 cycles	6502 interrupt acknowledge
			;	2 cycles	CLD
			;	5 cycles	JSR (VIMIRQ)
			;	2 cycles	LDA imm
			;	4 cycles	STA abs
			;	2 cycles	LDA imm
			;	4 cycles	STA abs
			;	2 cycles	INX
			;	6 cycles	RTI
			; Total 37 cycles
			;
		irq1:
		mva		#0 irqen
		mva		#1 irqen
				inx
				rti
		testname:
	dta		c"POKEY: 1.79MHz timer granularity",0
			run		$2000
					end
