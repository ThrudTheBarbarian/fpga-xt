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
				_SAP_HEADER "POKEY: Direct serial input"
					opt		h+o+
					icl		'library.s'
				org		$2000
			;==========================================================================
		.proc main
				_INITTEST c"POKEY: Direct serial input",0
					;issue a status request to D1: and make sure we've actually got
					;a drive present
		mva		#$01 dunit
		mva		#$53 dcomnd
		mva		#$40 dstats
			jsr		dskinv
			bpl		disk_ok
				_SKIP	c"D1: status command failed."
		disk_ok:
					;issue an invalid read sector 0 command and see if D1: sends back
					;a NAK
		mva		#$01 dunit
		mva		#$52 dcomnd
		mva		#$40 dstats
			lda		#$00
			sta		daux1
			sta		daux2
	mwa		#dummysec dbuflo
			jsr		dskinv
			cpy		#$8b
			beq		disk_ok2
					;read sector 0 command didn't work... delay for two frames to let
					;any possible running command clear, then try command $00
			jsr		_waitVBL
			jsr		_waitVBL
		mva		#<sercmd2+3 IRQRoutine.seraddr
		mva		#$01 dunit
			lda		#0
			sta		dcomnd
			sta		dstats
			sta		daux1
			sta		daux2
	mwa		#dummysec dbuflo
			jsr		dskinv
			cpy		#$8b
			beq		disk_ok2
				_SKIP	c"Unable to find NAKed command on D1:."
		disk_ok2:
					;set up ANTIC display list for a one second timeout
			ldy		#0
	mwa		#timeout_dlist a0
		make_timeoutdl_loop:
		mva		#$41 (a0),y+
				tya
			add		#2
			sta		(a0),y+
		mva		#>timeout_dlist (a0),y+
			cpy		#180
			bne		make_timeoutdl_loop
					;turn interrupts off
			jsr		_screenOff
			jsr		_interruptsOff
					;start ANTIC timeout
			jsr		_waitVBL
	mwa		#timeout vdslst
	mwa		#timeout_dlist dlistl
		mva		#$80 nmien
		mva		#$20 dmactl
					;deassert SIO command line and wait for things to settle
		mva		#$3c pbctl
			jsr		_waitFrame
					;set up for 19200 baud synchronous transfer
			lda		#$28
			sta		audctl
			sta		audf3
			lda		#$00
			sta		audf4
			sta		skctl
	mwa		#IRQRoutine vimirq
		mva		#$23 skctl
					;assert command line
		mva		#$34 pbctl
					;wait 750-1600us before transferring first byte (~1400-2800 cycles)
			ldx		#19
			jsr		goofyWait
					;enable interrupts and transfer first byte
		mva		#$00 irqen
		mva		#$10 irqen
				cli
		mva		#$31 serout
					;wait for transfer to complete
			lda		#8
		bit:req	IRQRoutine.seraddr
		bit:rne	irqst
				sei
					;wait 650-950us before deasserting command line (~1200-1700 cycles)
			ldx		#13
			jsr		goofyWait
					;--- prepare to bit-bang in NAK byte
					;reset POKEY clocks and clear IRQs
			lda		#0
			sta		skctl
			sta		irqen
		mva		#$03 skctl
					;setup for a bit less than half bit delay
		mva		#33-4 audf1
		mva		#$40 audctl
					;deassert command line and wait for start bit (space)
			ldy		#$3c
			lda		#$10
			ldx		#0
			sty		pbctl
		bit:rne	skstat
					;delay by 47 cycles, then switch to 94 cycles
			sta		stimer
			lda		#1
			sta		irqen
		mvy		#94-4 audf1
		bit:rne	irqst
			stx		irqen
			sta		irqen
					;read in 8 data bits + stop bit
		bitloop:
		bit:rne	irqst
			ldy		skstat		;4
			stx		irqen
			sta		irqen
			sty		serdata+8	;4
			dec		*-2			;6
			bpl		bitloop		;3
					;check for framing error
			lda		serdata
			and		#$10
			bne		frame_ok
				_FAIL	c"Framing error detected."
		frame_ok:
					;extract received byte
			ldx		#8
		extloop:
			lda		serdata,x
			and		#$10
			adc		#$fe
			ror		d1
				dex
			bne		extloop
					;check received byte
			lda		d1
				_ASSERTA $4E, c"Received byte was not a NAK: %x"
			jmp		_testPassed
			.endp
			;==========================================================================
		goofyWait .proc
			sta		wsync
				dex
			bne		goofyWait
				rts
			.endp
			;==========================================================================
		timeout .proc
		mva		#0 nmien
				_FAIL	c"Timeout while waiting for NAK."
			.endp
			;==========================================================================
				org		$3000
		IRQRoutine .proc
			pha
			lda		sercmd1+3
		seraddr = *-2
			sta		serout
		mva		#0 irqen
			lda		seraddr
			dec		seraddr
			and		#$0f
			beq		done
		mva		#$10 irqen
		done:
				pla
				rti
			.endp
			;==========================================================================
				org		$3400
		serdata:
sercmd1	dta		$83,$00,$00,$52		;read disk sector 0 (invalid command)
				org		$3410
sercmd2	dta		$31,$00,$00,$00		;cmd $00 (invalid command)
				org		$3420
					;NAK byte is $4E
dta		$00, $08, $00, $00, $08, $08, $08, $00
		timeout_dlist	equ	$3800
				org		$38B4
			dta		$80
			dta		$41,a($38B5)
		dummysec	equ	$3c00
			;==========================================================================
			run		main
					end
