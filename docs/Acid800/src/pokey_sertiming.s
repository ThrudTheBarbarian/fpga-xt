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
				_SAP_HEADER "POKEY: Serial port timing"
					opt		h+o+
					icl		'library.s'
				org		$2000
			.macro _DELAY_CYCLES_X
				;validate parameters
				.if :0 != 1
				.error "Cycle count required." c' '
				.endif
				.if :1 < 2
				.error "Cycle count must be at least 2." c' '
				.endif
				.if :1 > 1000
				.error "Cycle count is too large." c' '
				.endif
				.def ?cycles = :1
				;check for page break
				.if ?cycles > 14 && ((*+5)&$ff)<3
					jmp *+3
					.def ?cycles = ?cycles - 3
				.endif
				.if ?cycles > 14
					;5N+1 cycles
					.def ?loops = (?cycles - 1) / 5
					.if ?loops*5+2 == ?cycles
						.def ?loops = ?loops - 1
					.endif
					ldx		#<?loops
					.pages 1
					dex:rne
					.endpg
					.def ?cycles = ?cycles - (5 * ?loops + 1)
				.endif
				.if ?cycles > 8
					pha
					pla
					.def ?cycles = ?cycles - 7
				.endif
				.if ?cycles == 8
					bit		$0100
					bit		$0100
				.elseif ?cycles == 7
					pha
					pla
				.elseif ?cycles == 6
					bit		$0100
					nop
				.elseif ?cycles == 5
					bit		$00
					nop
				.elseif ?cycles == 4
					bit		$0100
				.elseif ?cycles == 3
					bit		$00
				.elseif ?cycles == 2
					nop
				.elseif ?cycles != 0
					.error "Internal error" c' '
				.endif
			.endm
			;==========================================================================
		.proc main
				_INITTEST c"POKEY: Serial port timing",0
					;turn interrupts off
			jsr		_interruptsOff
					;make sure the command line is deasserted so we don't activate devices
		mva		#$3c pbctl
					;set timer 1+2 to 10 cycles, 1.79MHz
		mva		#$78 audctl
		mva		#<(10-7) audf1
		mva		#>(10-7) audf2
					;reset serial port and set timer 2 as transmit clock
		mva		#$00 skctl
		mva		#$63 skctl
					;make sure that serial shift register is cleared
			lda		#$08
		bit:rne	irqst
					;set timer 1+2 to 228 cycles
		mva		#$78 audctl
		mva		#<(228-7) audf1
		mva		#>(228-7) audf2
					;wait for vertical blank
			jsr		_waitFrame
					;sync timing and reset timers
			sta		wsync
			sta		wsync
			sta		stimer
					;reset noise generators / clocks / serial
		mva		#$00 skctl
		mva		#$63 skctl
					;write a byte
			sta		serout
				_DELAY_CYCLES_X 195
			lda		irqst
			and		#$08
				_ASSERTA $00, c"Serial output register was loaded too early."
					;wait for vertical blank
			jsr		_waitFrame
					;sync timing and reset timers
			sta		wsync
			sta		wsync
			sta		stimer
					;reset noise generators / clocks / serial
		mva		#$00 skctl
		mva		#$63 skctl
					;write a byte
			sta		serout
				_DELAY_CYCLES_X 196
			lda		irqst
			and		#$08
				_ASSERTA $08, c"Serial output register was loaded too late."
			jmp		_testPassed
			.endp
			;==========================================================================
			run		main
					end
