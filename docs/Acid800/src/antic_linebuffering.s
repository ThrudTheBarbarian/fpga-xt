			; Altirra Acid800 test suite
			; Copyright (C) 2010-2012 Avery Lee, All Rights Reserved.
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
				_SAP_HEADER "ANTIC: Line buffering"
					opt		h+o+
					icl		'library.s'
		ANALYSIS = 0
				org		$2000
		main:
				_INITTEST c"ANTIC: Line buffering"
					;kill screen
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vertical blank and swap in new display list
		render_loop:
			jsr		_waitVBL
	mwa		#dlist dlistl
		mva		#$22 dmactl
		mva		#$00 gractl
		mva		#$aa grafm
		mva		#0 sizem
		mva		#$00 nmien
		mva		#1 vscrol
			ldx		#$44
			jsr		setMissilePos
			lda		#16
		cmp:rne	vcount
			sta		hitclr
			sta		wsync			;end scan 32
			sta		wsync			;end scan 33
			jsr		checkMissiles
			beq		check1_ok
					.if !ANALYSIS
				_FAIL	c"Readout incorrect for initial mode E: %x%x%x%x"
					.endif
		check1_ok:
		mva		#$20 dmactl
			sta		wsync			;end scan 34
			ldx		#$80
			jsr		setMissilePosX4
			lda		#$22
			sta		wsync			;end scan 35
			sta		dmactl
			sta		hitclr
			sta		wsync			;end scan 36
			jsr		checkMissiles
			beq		check2_ok
					.if !ANALYSIS
				_FAIL	c"Readout incorrect for aliased mode 8: %x%x%x%x"
					.endif
		check2_ok:
			lda		#$20
			sta		wsync			;end scan 37
			sta		dmactl
			sta		wsync			;end scan 38
			sta		wsync			;end scan 39
			sta		wsync			;end scan 40
			sta		wsync			;end scan 41
			sta		wsync			;end scan 42
			ldx		#$90
			jsr		setMissilePosX4
			lda		#$21
			sta		wsync			;end scan 43
			sta		hitclr
			pha:pla
			sta		dmactl
			sta		wsync			;end scan 44
			jsr		checkMissiles
			beq		check3_ok
					.if !ANALYSIS
				_FAIL	c"Readout incorrect for aliased narrow mode 8: %x%x%x%x"
					.endif
		check3_ok:
		mva		#$20 dmactl
			sta		wsync			;end scan 45
			sta		wsync			;end scan 46
			sta		wsync			;end scan 47
			sta		wsync			;end scan 48
			sta		wsync			;end scan 49
			ldx		#$54
			jsr		setMissilePos
			sta		wsync			;end scan 50
			lda		#$21
			sta		wsync			;end scan 51
			sta		dmactl
			sta		hitclr
			sta		wsync			;end scan 52
			jsr		loadMissiles
			lda		d1
			cmp		#4
			bne		check4_fail
			lda		d2
			cmp		#4
			bne		check4_fail
			lda		d3
			cmp		#4
			bne		check4_fail
			lda		d4
			beq		check4_ok
		check4_fail:
					.if !ANALYSIS
				_FAIL	c"Readout incorrect for aliased mode F: %x%x%x%x"
					.endif
		check4_ok:
					;-----------------------------------------------------------------
					;Test 5
					;
					;Disable DMACTL across the center and check that that the
					;surrounding bytes are correct. (The bytes that are loaded in the
					;meantime are from the bus, but we don't test that yet.)
			sta		wsync			;end 53
			ldx		#$80
			jsr		setMissilePosX4
			ldy		#$22
			sty		dmactl
			ldx		#14
		ws_loop:
			sta		wsync
				dex
			bne		ws_loop
			lda		#$20
			sta		wsync			;end 68
			sta		hitclr			;*, 105, 106, 107
			ldx		#7
			dex:rne
			sta		dmactl
			pha:pla
			pha:pla
			sty		dmactl
			sta		wsync			;end 69
			sta		hitclr
			sta		wsync			;end 70 (row 2/8)
			jsr		loadMissiles
					;We should have reused the $E4 byte
			jsr		checkMissiles
			;		beq		check5_ok
			jmp		check5_ok		;requires knowing bus values; don't test yet
					.if !ANALYSIS
				_FAIL	c"Readout incorrect for mid-interrupted mode 8/center: %x%x%x%x"
					.endif
		check5_ok:
			ldx		#$30			;left side
			jsr		setMissilePosX4
			sta		wsync			;end 72 (row 4/8)
			sta		hitclr
			sta		wsync			;end 73 (row 5/8)
			jsr		loadMissiles
					;left byte should be #$ff
			lda		d1
			cmp		#4
			bne		check5a_fail
			lda		d2
			cmp		#4
			bne		check5a_fail
			lda		d3
			cmp		#4
			bne		check5a_fail
			lda		d4
			cmp		#4
			beq		check5a_ok
		check5a_fail:
					.if !ANALYSIS
				_FAIL	c"Readout incorrect for mid-interrupted mode 8/left: %x%x%x%x"
					.endif
		check5a_ok:
			ldx		#$c0			;right side
			jsr		setMissilePosX4
			sta		wsync			;end 75 (row 7/8)
			sta		hitclr
			sta		wsync			;end 76 (row 8/8)
			jsr		loadMissiles
					;right byte should be #$f6 or %11110110
			lda		d1
			cmp		#4
			bne		check5b_fail
			lda		d2
			cmp		#4
			bne		check5b_fail
			lda		d3
			cmp		#1
			bne		check5b_fail
			lda		d4
			cmp		#2
			beq		check5b_ok
		check5b_fail:
					.if !ANALYSIS
				_FAIL	c"Readout incorrect for mid-interrupted mode 8/right: %x%x%x%x"
					.endif
		check5b_ok:
					;-----------------------------------------------------------------
					;Test 6
					;
					;Disable DMACTL in the middle of a scanline while we are still
					;replaying the buffer, and check that the replay addressing is also
					;not affected by the temporary disable.
			lda		#$20
			ldy		#$22
			sta		wsync			;end 77 (row 1/8)
			sta		hitclr
					;##ASSERT vpos=77
			ldx		#8
			dex:rne
				nop
			sta		dmactl
			pha:pla
				nop
				nop
			sty		dmactl
			ldx		#$c0			;right side
			jsr		setMissilePosX4
			sta		wsync			;end 78 (row 2/8)
			sta		hitclr
			sta		wsync			;end 79 (row 3/8)
			jsr		loadMissiles
					;right byte should be #$89 or %10001001
			lda		d1
			cmp		#2
			bne		check5c_fail
			lda		d2
			cmp		#0
			bne		check5c_fail
			lda		d3
			cmp		#2
			bne		check5c_fail
			lda		d4
			cmp		#1
			beq		check5c_ok
		check5c_fail:
					.if !ANALYSIS
				_FAIL	c"Readout incorrect for mid-interrupted replayed mode 8/right: %x%x%x%x"
					.endif
		check5c_ok:
					.if ANALYSIS
					jmp		render_loop
					.endif
			jmp		_testPassed
			;=========================================================================
		.proc setMissilePos
			stx		hposm0
				inx
			stx		hposm1
				inx
			stx		hposm2
				inx
			stx		hposm3
				rts
			.endp
			;=========================================================================
		.proc setMissilePosX4
				txa
			sta		hposm0
			add		#4
			sta		hposm1
			adc		#4
			sta		hposm2
			adc		#4
			sta		hposm3
				rts
			.endp
			;=========================================================================
		.proc loadMissiles
		mva		m0pf d1
			lda		m1pf
			ldx		m2pf
			ldy		m3pf
			sta		d2
			stx		d3
			sty		d4
				rts
			.endp
			;=========================================================================
		.proc checkMissiles
			jsr		loadMissiles
			lda		d1
			cmp		#4
			bne		fail
			lda		d2
			cmp		#2
			bne		fail
			lda		d3
			cmp		#1
			bne		fail
			lda		d4
			cmp		#0
		fail:
				rts
			.endp
			;=========================================================================
				org		$2c00
		dlist:
			dta		$70					;8
				dta		$70					;16
				dta		$70					;24
			dta		$4e,a(framedata)	;32
				dta		$10					;33
				dta		$08					;35
				dta		$08					;43
				dta		$2f					;51 (VSCROL=1)
				dta		$10					;67
			dta		$48,a(framedata2)	;69
				dta		$08					;77
				dta		$00
		dlist2:
			dta		$41,a(dlist2)
				org		$2d00
		framedata:
					;line 32
	:5 dta $00
				dta		$e4
	:34 dta $0
		framedata2:
					;line 69
	:10 dta $ff-#
					;line 77
	:10 dta $80+#
			run		$2000
					end
