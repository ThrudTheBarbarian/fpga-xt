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
				_SAP_HEADER "PIA: Interrupt control test"
					opt		h+o+
					icl		'library.s'
		irqflag	equ		$80
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;reset port A and port B control
		mva		#$3c pactl
		mva		#$3c pbctl
					;clear and disable all POKEY interrupts
		mva		#$00 irqen
					;wait for IRQ lines to clear
			pha:pla
					;check that interrupts are off
			jsr		checkIRQ
			sta		d0
					;set IRQ bits with all interrupts masked
			lda		#$c0
			sta		pactl
			sta		pbctl
			jsr		checkIRQ
			sta		d1
					;check value
			lda		#$ff
			sta		pactl
			sta		pbctl
			lda		pactl
			sta		d2
			lda		pbctl
			sta		d3
					;reset PIA
			lda		#$3c
			sta		pactl
			sta		pbctl
					;do asserts
				_ASSERT1	d0, 0, c"Stray IRQ detected with all interrupts disabled."
				_ASSERT1	d1, 0, c"PIA IRQ detected with int bits on and interrupts masked."
				_ASSERT1	d2, $3f, c"Wrote $FF to PACTL, got $%x, expected $3F"
				_ASSERT1	d3, $3f, c"Wrote $FF to PBCTL, got $%x, expected $3F"
					;check that we can turn on IRQA2 flag
		mva		#$34 pactl
		mva		#$3c pactl
		mva		#$14 pactl
			lda		pactl
				_ASSERTA	$54, c"Unable to turn on port A control bit 6 (%x)."
					;check that reading the DDR does NOT clear IRQA2
		mva		#$00 pactl
			lda		pactl
				_ASSERTA	$40, c"Read from DDRA should not have cleared port A control bit 6."
					;check that reading the port A does clear IRQA2
		mva		#$04 pactl
			lda		porta
			lda		pactl
				_ASSERTA	$04, c"Read from port A should have cleared port A control bit 6."
					;reset port A
		mva		#$3c pactl
					;===== run port B test suite
					;clear IRQB2 in case a device happened to set it
			lda		portb
	mwa		#irq vimirq
	mwa		#testvec_b a0
		runloop_b:
			ldy		#0
			sty		irqflag
			lda		(a0),y
		sne:jmp	done_b
			sta		pbctl
				iny
			lda		(a0),y+
			sta		pbctl
			lda		(a0),y+
			sta		pbctl
			lda		(a0),y+
			sta		pbctl
			lda		pbctl
			cmp		(a0),y
			beq		valok_b
			sta		d3
			mva		(a0),y d4
	sbw		a0 #testvec_b d1
				_FAIL	c"Test %X failed: PBCTL %x!=%x"
		valok_b:
				iny
				cli
				nop
				nop
				sei
			lda		irqflag
			cmp		(a0),y
			beq		irqok_b
			sta		d3
			mva		(a0),y d4
	sbw		a0 #testvec_b d1
				_FAIL	c"Test %X failed: IRQB2 %x!=%x"
		irqok_b:
				sec
				tya
			adc		a0
			sta		a0
			scc:inc	a0+1
			jmp		runloop_b
		done_b:
	mwa		#testvec_a a0
		runloop_a:
			ldy		#0
			sty		irqflag
			lda		(a0),y
		sne:jmp	done_a
			sta		pactl
				iny
			lda		(a0),y+
			sta		pactl
			lda		(a0),y+
			sta		pactl
			lda		(a0),y+
			sta		pactl
			lda		pactl
			cmp		(a0),y
			beq		valok_a
			sta		d3
			mva		(a0),y d4
	sbw		a0 #testvec_a d1
				_FAIL	c"Test %X failed: PACTL %x!=%x"
		valok_a:
				iny
				cli
				nop
				nop
				sei
			lda		irqflag
			cmp		(a0),y
			beq		irqok_a
			sta		d3
			mva		(a0),y d4
	sbw		a0 #testvec_a d1
				_FAIL	c"Test %X failed: IRQA2 %x!=%x"
		irqok_a:
				sec
				tya
			adc		a0
			sta		a0
			scc:inc	a0+1
			jmp		runloop_a
		done_a:
					;reset PIA
			lda		#$3c
			sta		pactl
			sta		pbctl
			jmp		_testPassed
		testname:
	dta		c"PIA: Interrupt control test",0
			;==========================================================================
		.proc irq
				pha
			mva		#1 irqflag
		mva		#$3c pactl
		mva		#$3c pbctl
				pla
				rti
			.endp
			;==========================================================================
			;Port B test vectors
			;
		testvec_b:
					;$34 -> $3C transition sets pending flag which is turned into
					;IRQB2 flag on input mode. The actual choice of input mode
					;doesn't matter.
		dta		$34,$3c,$3c,$04, $44,$00
		dta		$34,$3c,$3c,$0c, $4c,$01
		dta		$34,$3c,$04,$04, $44,$00
					;Any output mode clears IRQB2.
		dta		$34,$3c,$04,$24, $24,$00
					;Handshake mode (100) can be between the 34:3C sequence. Pulse
					;output mode (101) cannot be, nor can an input mode.
		dta		$34,$24,$3c,$04, $44,$00
		dta		$34,$28,$3c,$04, $04,$00
		dta		$34,$04,$3c,$04, $04,$00
					;High-low-high sequence does not work.
		dta		$34,$3c,$34,$04, $04,$00
		dta		$3c,$34,$3c,$04, $44,$00
				dta		$00
			;==========================================================================
			;Port A test vectors
			;
		testvec_a:
					;IRQA2 is set if the line is forced low (34) and the next input
					;mode is for a negative-to-positive transition (14/1C). The line
					;can temporarily be raised (3C) in any pattern as long as it is
					;lowered at some point.
		dta		$3c,$3c,$3c,$14, $14,$00
		dta		$3c,$3c,$34,$14, $54,$00
		dta		$3c,$34,$3c,$14, $54,$00
		dta		$3c,$34,$3c,$1c, $5c,$01
		dta		$34,$34,$34,$04, $04,$00
					;Pulse output mode (2c) clears the pending transition, but
					;handshake mode does not.
		dta		$34,$34,$2c,$14, $14,$00
		dta		$34,$34,$24,$14, $54,$00
					;Any output mode clears IRQA2/IRQB2.
		dta		$34,$34,$14,$34, $34,$00
				dta		$00
			;==========================================================================
		.proc checkIRQ
	mwa		#irqHandler vimirq
			lda		#0
				cli
	:8 nop
				sei
				rts
		irqHandler:
				pla
				pla
				pla
			lda		#1
				rts
			.endp
			;==========================================================================
			run		$2000
					end
