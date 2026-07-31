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
				_SAP_HEADER "POKEY: Init timing"
					opt		h+o+
					icl		'library.s'
			;==========================================================================
		retoff	equ		$80
		result1	equ		$81
		result2	equ		$82
			;==========================================================================
				org		$2000
		.nowarn .proc main
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
					;initialize runway
			ldx		#0
			lda		#$ea
		runway_init:
			sta		runway,x
				inx
			bne		runway_init
			lda		#$24			;bit zp
			sta		runway
			lda		#$60			;rts
			sta		runway+$ff
					;turn interrupts off and revector irq
			jsr		_screenOff
			jsr		_interruptsOff
		mva		#0 irqen
	mwa		#irqhandler vimirq
					;reset serial port to force output complete
		mva		#0 skctl
			pha:pla
					;revector IRQ and enable interrupts
				cli
					;set timer 1 for 15KHz operation (IRQ ack starting 86-87 cycles after SKCTL write)
		mva		#$01 audctl
		mva		#$00 audf1
		mva		#0 audc1
			jsr		runtests
					;check values
					;
					;Note that Ataris vary slightly in their POKEY IRQ latency, so we have to
					;accept two sets of timing values here. The values reported are from two NOP
					;sleds, offset by a cycle. The first byte of the sled at offset 0 is a BIT zp
					;instruction (odd test start), and starting at offset 1 are the NOP
					;instructions (even test start). The byte is actually the low byte of the
					;return address on the stack.
					;
					;For the 15KHz clock, we expect an even value of either $1F or $20, which means
					;30-31 NOP instructions. With the STA + STA + CLI + JSR leading
					;into it and 9 refresh cycles, that's a delay of 85 or 87 cycles.
					;
					;The odd value is $1F, which means one BIT zp instruction and 29 NOP
					;insns - 86 cycles. Take the min and we have 86-87 cycles of instructions
					;bin between the STA SKCTL and the IRQ ack sequence. The one cycle variance
					;is due to IRQ timing differences between systems.
					;
				_ASSERT1_DUAL result1, $1F, $20, c"Incorrect 15KHz cycle count (even): $%x",0
				_ASSERT1 result2, $1F, c"Incorrect 15KHz cycle count (odd): $%x",0
					;set timer 1 for 64KHz operation (IRQ ack starting 83-84 cycles after SKCTL write)
					;
					; 84 - 28*2 = 28
					;
					;For the 64KHz timer, we expect an even value of $1E (83 cycles) and an odd
					;value of $1D-1E (82 or 84 cycles), giving 82-83 cycles. We set the timer to
					;run two extra cycles to clear memory refresh, so this is actually 26-27 cycles.
					;
		mva		#$00 audctl
		mva		#$02 audf1
		mva		#0 audc1
			jsr		runtests
					;check values
				_ASSERT1 result1, $1E, c"Incorrect 64KHz cycle count (even): $%x",0
				_ASSERT1_DUAL result2, $1E, $1D, c"Incorrect 64KHz cycle count (odd): $%x",0
					;===================== IRQST tests =====================
					;----- 15KHz
		mva		#$01 audctl
			lda		#0
			sta		audf1
			sta		irqen
			sta		skctl
			sta		stimer
			ldy		#3
			sta		wsync
			ldx		#1
			sta		wsync
			sty		skctl
			stx		irqen
			jsr		delay36			;delay 66 cycles
			jsr		delay24
				nop
				nop
				nop
			lda		irqst
			and		#$01
				_ASSERTA $01, '15KHz IRQ fired too early after exiting init mode.'
			lda		#0
			sta		irqen
			sta		skctl
			ldy		#3
			sta		wsync
			ldx		#1
			sta		wsync
			sty		skctl
			stx		irqen
			jsr		delay36			;delay 67 cycles
			jsr		delay24
				nop
				nop
			bit		$00
			lda		irqst
			and		#$01
				_ASSERTA $00, '15KHz IRQ fired too late after exiting init mode.'
					;----- 64KHz
			lda		#2
			sta		audf1
		mva		#$00 audctl
			sta		irqen
			sta		skctl
			sta		stimer
			ldy		#3
			sta		wsync
			ldx		#1
			sta		wsync
			sty		skctl
			sta		stimer
			stx		irqen
			jsr		delay36			;delay 59 cycles (+4 from sta stimer)
			jsr		delay12
			pha:pla
				nop
				nop
			lda		irqst
			and		#$01
				_ASSERTA $01, '64KHz IRQ fired too early after exiting init mode.'
			sta		irqen
			sta		skctl
			ldy		#3
			sta		wsync
			ldx		#1
			sta		wsync
			sty		skctl
			sta		stimer
			stx		irqen
			jsr		delay36			;delay 60 cycles (+4 from sta stimer)
			jsr		delay24
			lda		irqst
			and		#$01
				_ASSERTA $00, '64KHz IRQ fired too late after exiting init mode.'
			jmp		_testPassed
			.endp
			;==========================================================================
		delay72:
			jsr		delay36
		delay36:
			jsr		delay12
		delay24:
			jsr		delay12
		delay12:
				rts
			;==========================================================================
		.proc	runtests
					;run even test
			lda		#0
			sta		skctl
			sta		retoff
			lda		#$01
			ldy		#3
			sta		wsync
			sta		wsync
			sty		skctl
			sta		stimer
			sta		irqen
				cli
			jsr		runway+1
				sei
			mva		retoff result1
		mva		#0 irqen
					;run odd test
			lda		#$01
			ldx		#0
			stx		skctl
			ldy		#3
			sta		wsync
			sta		wsync
			sty		skctl
			sta		stimer
			sta		irqen
				cli
			jsr		runway
				sei
			mva		retoff result2
		mva		#0 irqen
				rts
			.endp
			;==========================================================================
		.proc	irqhandler
				pha
				txa
				pha
				tsx
			lda		$0104,x
			sta		retoff
		mva		#0 irqen
				pla
				tax
				pla
				rti
			.endp
		testname:
	dta		c"POKEY: Init timing",0
		runway	equ		$2400
			run		$2000
					end
