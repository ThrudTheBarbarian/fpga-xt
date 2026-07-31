			; Altirra Acid800 test suite
			; Copyright (C) 2010-2011 Avery Lee, All Rights Reserved.
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
				_SAP_HEADER "POKEY: Serial clocking modes"
					opt		h+o+
					icl		'library.s'
				org		$2000
			;==========================================================================
		.proc main
				_INITTEST c"POKEY: Serial clocking modes",0
					;turn interrupts off
			jsr		_screenOff
			jsr		_interruptsOff
					;make sure the command line is deasserted so we don't activate devices
		mva		#$3c pbctl
					;set timer 1+2 to 228 cycles, timer 3+4 to 456 cycles, 1.79MHz clock
		mva		#$78 audctl
		mva		#<(228-7) audf1
		mva		#>(228-7) audf2
		mva		#<(456-7) audf3
		mva		#>(456-7) audf4
					;Test with timer 4 as serial output clock. Note that we are not a
					;timing test, so we allow some slop here; precise checks are done
					;in another test.
			lda		#$23
			jsr		MeasureSerOutRate
			sta		d1
			cmp		#40-1
			bcc		timer4fast_fail
			cmp		#40+2
			bcc		timer4fast_ok
		timer4fast_fail:
				_FAIL	c"Timer 3+4 1.79MHz output failed: %d!=40"
		timer4fast_ok:
					;switch to timer 2 as serial output clock and retest
			lda		#$63
			jsr		MeasureSerOutRate
			sta		d1
			cmp		#20-1
			bcc		timer2fast_fail
			cmp		#20+2
			bcc		timer2fast_ok
		timer2fast_fail:
				_FAIL	c"Timer 1+2 1.79MHz output failed: %d!=20"
		timer2fast_ok:
					;switch timers to 15KHz
		mva		#1 audctl
		mva		#2-1 audf2
		mva		#4-1 audf4
					;test with timer 4 as serial output clock
			lda		#$23
			jsr		MeasureSerOutRate
			cmp		#40-1
			bcc		timer4slow_fail
			cmp		#40+2
			bcc		timer4slow_ok
		timer4slow_fail:
				_FAIL	c"Timer 4 15KHz output failed: %d!=40"
		timer4slow_ok:
					;switch to timer 2 as serial output clock and retest
			lda		#$63
			jsr		MeasureSerOutRate
			cmp		#20-1
			bcc		timer2slow_fail
			cmp		#20+2
			bcc		timer2slow_ok
		timer2slow_fail:
				_FAIL	c"Timer 2 15KHz output failed: %d!=20"
		timer2slow_ok:
					;switch to external clock and verify that the clock is
					;stopped; the shift register should never load in this mode
			lda		#$00
			sta		skctl
			sta		irqen
				nop
		mva		#$03 skctl
		mva		#$10 irqen
			sta		serout
			jsr		_waitFrame
			jsr		_waitFrame
				_ASSERT1 irqst, $f7, c"Output register loaded with stopped serial clock."
			jmp		_testPassed
			.endp
			;==========================================================================
		.proc MeasureSerOutRate
					;push a byte through to reset serial port to known state
		mvx		#$03 skctl
			sta		serout
				pha
			jsr		_waitFrame
			jsr		_waitFrame
				pla
					;clear any existing serial output ready interrupt
		mvy		#0 irqen
					;reset pokey with known 15KHz offset
			sty		skctl
			pha:pla
			sta		wsync
			sta		skctl
					;wait until end of scanline 9
			ldx		#3
		cpx:rne	vcount
				inx
		cpx:rne	vcount
			lda		#$10
			sta		wsync
					;whack timers, push a byte out the serial port, and enable the serial
					;output transmit IRQ (note that interrupts are still masked)
			sta		stimer
			sta		serout
			sta		irqen
					;wait for first byte to be accepted; this shouldn't take long (cycles)
			jsr		waitready
					;stash VCOUNT
			stx		d1
					;ack the interrupt
			sty		irqen
			sta		irqen
					;stuff a second byte
			sta		serout
					;wait for timer to expire; this should happen 19 clock periods from now
			jsr		waitready
					;subtract original VCOUNT value and return delta
				txa
			sub		d1
				rts
		waitready:
			ldx		vcount
			bmi		ready
			bit		irqst
			bne		waitready
		ready:
				rts
			.endp
			;==========================================================================
			run		main
					end
