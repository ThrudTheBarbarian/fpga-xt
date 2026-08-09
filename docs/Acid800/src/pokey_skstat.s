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
				_SAP_HEADER "POKEY: Serial status"
					opt		h+o+
					icl		'library.s'
					opt		o-
				org		$80
		timeoutFlag		dta		0
					opt		o+
				org		$2000
			;==========================================================================
		.proc main
				_INITTEST c"POKEY: Serial status",0
					;issue a status request to D1: and make sure we've actually got
					;a drive present
		mva		#$01 dunit
		mva		#$53 dcomnd
		mva		#$40 dstats
			jsr		dskinv
			bpl		disk_ok
				_SKIP	c"D1: status command failed."
		disk_ok:
					;mask IRQs (but leave NMIs)
				sei
					;make sure the command line is deasserted so we don't activate devices
		mva		#$3c pbctl
		mva		#$28 audctl
			sta		audf3
		mva		#$00 audf4
			sta		skctl
			sta		wsync
			sta		wsync
		mva		#$23 skctl
					;check that the serial input bit is idle
			lda		skstat
			and		#$02
			bne		serin_idle
				_FAIL	'Serial input active bit was asserted when idle.',0
		serin_idle:
					;---issue a status command read to D1:
					;reset timeout
			lda		#30
			sta		cdtmv1
	mwa		#TimeoutHandler cdtma1
			lda		#0
			sta		cdtmv1+1
			sta		timeoutFlag
					;assert command line
		mva		#$34 pbctl
					;wait at least 750us (12 scanlines)
			ldx		#6
			jsr		WaitScanlinePairs
					;send status command
		mva		#$00 irqen
		mva		#$10 irqen
			lda		#$31
			jsr		SendByte
			lda		#'S'
			jsr		SendByte
			lda		#$00
			jsr		SendByte
			lda		#$00
			jsr		SendByte
			lda		#$84
			jsr		SendByte
					;wait for complete
		mva		#$08 irqen
		bit:rne	irqst
					;wait 650us (11 scanlines)
			ldx		#6
			jsr		WaitScanlinePairs
					;switch to receive mode
		mva		#$13 skctl
		mva		#$20 irqen
					;deassert command line
		mva		#$3c pbctl
					;wait for ACK
			jsr		ReceiveByte
			cmp		#'A'
			beq		ack_ok
			sta		d1
				_FAIL	'Result byte was not ACK: %x'
		ack_ok:
					;wait for complete
			jsr		ReceiveByte
			cmp		#'C'
			beq		complete_ok
			sta		d1
				_FAIL	'Complete byte not received: %x'
		complete_ok:
					;receive first status byte and check that the serial input busy bit activates
			jsr		ReceiveByte
				txa
			and		#$02
			beq		serin_active_ok
				_FAIL	'Serial input active bit was not asserted during reception.'
		serin_active_ok:
					;burn bytes #2 and #3
			jsr		ReceiveByte
			jsr		ReceiveByte
					;wait for byte #4 to come in
		wait_loop_1:
			lda		timeoutFlag
		seq:jmp	ReceiveByte.timeout
			lda		#$20
			bit		irqst
			bne		wait_loop_1
					;wait for byte #5 to come in, leaving the serin IRQ active; we must
					;use the serin busy bit for this
		wait_loop_2:
			ldy		timeoutFlag
		seq:jmp	ReceiveByte.timeout
			lda		#$02
			bit		skstat
			bne		wait_loop_2
		wait_loop_3:
			ldy		timeoutFlag
		seq:jmp	ReceiveByte.timeout
			lda		#$02
			bit		skstat
			beq		wait_loop_3
					;verify that the overrun bit is set
			lda		skstat
			and		#$20
			beq		overrun_ok
				_FAIL	'Serial input overrun bit was not asserted.'
		overrun_ok:
			jmp		_testPassed
			.endp
			;==========================================================================
		.proc ReceiveByte
			ldx		#$a2
		not_ready:
			ldy		timeoutFlag
			bne		timeout
				txa
			and		skstat
				tax
			cmp		#$a0
			bcc		recv_err
			lda		#$20
			bit		irqst
			bne		not_ready
			ldy		#$00
			sty		irqen
			ldy		#$20
			sty		irqen
			lda		serin
				rts
		recv_err:
				asl
			bcc		framing_err
				_FAIL	'Serial input overrun error occurred.',0
		framing_err:
				_FAIL	'Framing error occurred.',0
		timeout:
				_FAIL	'Timeout occurred while sending status command.',0
			.endp
			;==========================================================================
		.proc WaitScanlinePairs
		wait_loop:
			lda		vcount
		cmp:rne	vcount
				dex
			bne		wait_loop
				rts
			.endp
			;==========================================================================
		.proc SendByte
			sta		serout
			lda		#$10
		bit:rne	irqst
		mva		#$00 irqen
		mva		#$10 irqen
				rts
			.endp
			;==========================================================================
		.proc TimeoutHandler
			lda		#$ff
			sta		timeoutFlag
				rts
			.endp
			;==========================================================================
			run		main
					end
