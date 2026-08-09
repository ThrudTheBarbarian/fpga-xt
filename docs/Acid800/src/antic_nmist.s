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
				_SAP_HEADER "ANTIC: NMIST/NMIRES test"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;swap in new display list and VBI/DLI handlers
			jsr		_waitVBL
			inc		wsync			;make sure we're not before VBI start
			inc		wsync
	mwa		#dlist dlistl
	mwa		#dli1 vdslst
	mwa		#vbi vvblki
		mva		#$c0 nmien
		mva		#$20 dmactl
			mva		#0 d0
			mva		#0 d1
					;wait a few VBLANKs; if the VBI handler doesn't fire, fail
			jsr		_waitVBL
			jsr		_waitVBL
			jsr		_waitVBL
				_FAIL	c"VBI handler did not fire.",0
		resume_test:
					;shut NMIs back off
		mva		#0 nmien
					;===== DLI timing tests
					;wait for scanline 38, and check that the DLI bit flips on
			lda		#19
		cmp:rne	vcount
			sta		nmires
			sta		wsync		;end 38
			sta		wsync		;end 39 (DLI fired)
			sta		wsync
			lda		nmist
			and		#$80
				_ASSERTA $80, c"DLI bit was not set in NMIST with DLIs disabled."
					;check that the DLI bit is auto-cleared at scan line 248
			lda		#247/2
		cmp:rne	vcount
			sta		wsync		;end 246
			lda		nmist
			and		#$80
				_ASSERTA $80, c"DLI bit was not set at scan line 246."
			sta		wsync		;end 247
			sta		wsync
			lda		nmist
				pha
			and		#$80
				_ASSERTA $00, c"DLI bit was not cleared at scan line 248."
				pla
			and		#$40
				_ASSERTA $40, c"VBI bit was not set at scan line 248."
					;check that the VBI bit turns off when the DLI bit turns on
			lda		#19
		cmp:rne	vcount
			sta		wsync		;end 38
			lda		nmist
			and		#$40
				_ASSERTA $40, c"VBI bit was cleared before scan line 39."
			sta		wsync		;end 39
			pha:pla				;*, 104-109
			pha:pla				;110-113, 0-3
			pha:pla				;4-9
			lda		nmist
			and		#$40
				_ASSERTA $00, c"VBI bit was not cleared at scan line 39."
					;look for cycle-exact timing on the DLI bit
			lda		#19
		cmp:req	vcount
		cmp:rne	vcount
			sta		nmires
			sta		wsync		;end 38
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
				nop					;0, 1
			lda		nmist		;2, 3, 4, 5
			and		#$80
				_ASSERTA $00, c"DLI bit set too early (<cycle 6)."
					;look for cycle-exact timing
			lda		#19
		cmp:req	vcount
		cmp:rne	vcount
			sta		nmires
			sta		wsync		;end 38
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			pha:pla				;110, 111, 112, 113, 0, 1, 2
			lda		nmist		;3, 4, 5, 6
			and		#$80
				_ASSERTA $80, c"DLI bit set too late (>cycle 6)."
					;===== VBI timing tests
					;wait for scanline 38, and check that the DLI bit flips on
			lda		#246/2
		cmp:rne	vcount
			sta		nmires
			sta		wsync		;end 246
			sta		wsync		;end 247
			sta		wsync		;end 248 (VBI fired)
			sta		wsync		;end 249
			lda		nmist
			and		#$40
				_ASSERTA $40, c"VBI bit was not set in NMIST with VBIs disabled."
					;repeat the test, but this time, look for cycle-exact timing
			lda		#246/2
		cmp:req	vcount
		cmp:rne	vcount
			sta		nmires
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
				nop					;0, 1
			lda		nmist		;2, 3, 4, 5
			and		#$40
				_ASSERTA $00, c"VBI bit set too early (<cycle 6)."
					;repeat the test, but this time, look for cycle-exact timing
			lda		#246/2
		cmp:req	vcount
		cmp:rne	vcount
			sta		nmires
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			pha:pla				;110, 111, 112, 113, 0, 1, 2
			lda		nmist		;3, 4, 5, 6
			and		#$40
				_ASSERTA $40, c"VBI bit set too late (>cycle 6)."
					;===== NMIRES timing tests
					;wait for scanline 246
			lda		#246/2
		cmp:rne	vcount
					;hit NMIRES on cycle 6 and check VBI bit
					;
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
			lda		$00			;0, 1, 2
			sta		nmires		;3, 4, 5, 6
			lda		nmist
			and		#$40
				_ASSERTA $40, c"VBI bit was reset too early."
					;hit NMIRES on cycle 7 and check VBI bit
					;
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
			lda		$0100		;0, 1, 2, 3
			sta		nmires		;4, 5, 6, 7
			lda		nmist
			and		#$40
				_ASSERTA $00, c"VBI bit was reset too late."
			pha:pla
			pha:pla
					;wait for scanline 246
			lda		#246/2
		cmp:rne	vcount
					.ifndef SYS5200
					;enable VBI
		mva		#$40 nmien
	mwa		#vbi2 vvblki
					;hit NMIRES on cycle 7 and see if VBI still fires
					;
					;NOTE: We cannot run this test on the 5200 because the OS does not
					;dispatch NMIs when NMIST is clear.
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
			lda		$0100		;0, 1, 2, 3
			sta		nmires		;4, 5, 6, 7
			pha:pla
			pha:pla
		mva		#0 nmien
				_FAIL	c"VBI was blocked by NMIRES."
					.endif
		resume_test2:
					;===== NMIEN timing tests
					;wait for scanline 38 and enable DLI on cycle 6
			lda		#36/2
		cmp:req	vcount
		cmp:rne	vcount
			lda		#0
			sta		nmien
			sta		d1
			sta		nmires
	mwa		#dli3 vdslst
			sta		wsync		;end 36
			sta		wsync		;end 37
			sta		wsync		;end 38
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			inc		d2			;110, 111, 112, 113, 0
		mva		#$80 nmien	;1, 2, 3, 4, 5, 6
				nop
				nop
				nop
				nop
		mva		#0 nmien
				_ASSERT1 d1, $ff, c"DLI was not activated by write to NMIEN on cycle 6."
					;wait for scanline 38 and enable DLI on cycle 7
			lda		#36/2
		cmp:req	vcount
		cmp:rne	vcount
			lda		#0
			sta		nmien
			sta		d1
			sta		nmires
	mwa		#dli3 vdslst
			sta		wsync		;end 36
			sta		wsync		;end 37
			sta		wsync		;end 38
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
				nop					;0, 1
		mva		#$80 nmien	;2, 3, 4, 5, 6, 7
				nop
				nop
				nop
				nop
		mva		#0 nmien
				_ASSERT1 d1, $00, c"DLI was activated by write to NMIEN on cycle 7."
					;turn off display list DMA
		mva		#0 dmactl
					;wait for scanline 248 and enable VBI on cycle 6
			lda		#246/2
		cmp:req	vcount
		cmp:rne	vcount
			lda		#0
			sta		nmien
			sta		d1
			sta		nmires
	mwa		#vbi3 vvblki
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			inc		d2			;110, 111, 112, 113, 0
		mva		#$40 nmien	;1, 2, 3, 4, 5, 6
				nop
				nop
				nop
				nop
		mva		#0 nmien
				_ASSERT1 d1, $ff, c"VBI was not activated by write to NMIEN on cycle 6."
					;wait for scanline 248 and enable VBI on cycle 7
			lda		#246/2
		cmp:req	vcount
		cmp:rne	vcount
			lda		#0
			sta		nmien
			sta		d1
			sta		nmires
	mwa		#vbi3 vvblki
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
				nop					;0, 1
		mva		#$40 nmien	;2, 3, 4, 5, 6, 7
				nop
				nop
				nop
				nop
		mva		#0 nmien
				_ASSERT1 d1, $00, c"VBI was activated by write to NMIEN on cycle 7."
					;wait for scanline 248 and disable VBI on cycle 3
			lda		#246/2
		cmp:req	vcount
		cmp:rne	vcount
			lda		#$40
			sta		nmien
			sta		d1
			sta		nmires
	mwa		#vbi3 vvblki
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			lda		$0100		;110, 111, 112, 113
		mva		#0 nmien	;0, 1, 2, 3, 4, 5
				nop
				nop
				nop
				nop
		mva		#0 nmien
				_ASSERT1 d1, $40, c"VBI was not deactivated by write to NMIEN on cycle 5."
					;wait for scanline 248 and disable VBI on cycle 4
			lda		#246/2
		cmp:req	vcount
		cmp:rne	vcount
			lda		#$40
			sta		nmien
			sta		d1
			sta		nmires
	mwa		#vbi3 vvblki	;reuse DLI routine
			sta		wsync		;end 246
			sta		wsync		;end 247
			pha:pla				;*, 104, 105, 106, 107, 108, 109
			inc		d2			;110, 111, 112, 113, 0
		mva		#0 nmien	;1, 2, 3, 4, 5, 6
				nop
				nop
				nop
				nop
		mva		#0 nmien
				_ASSERT1 d1, $ff, c"VBI was deactivated by write to NMIEN on cycle 6."
			jmp		_testPassed
		testname:
	dta		c"ANTIC: NMIST/NMIRES test",0
			;=========================================================================
		.proc vbi
					.ifdef SYS5200
					cld
					pha
					txa
					pha
					tya
					pha
					.endif
					;The fact that we got here means that everything is mostly OK.
					;Since we're relying on the OS NMI dispatch, we know that the
					;DLI bit was cleared and the VBI bit was set. We can, however,
					;check that our DLI handlers were called and that strobing NMIRES
					;clears the VBI bit.
				_ASSERT1 d0, $ff, c"The DLI1 handler was not called."
				_ASSERT1 d1, $ff, c"The DLI1 handler was not called."
			sta		nmires
			lda		nmist
			and		#$c0
				_ASSERTA $00, c"NMIRES did not clear the VBI bit: $%x"
			jmp		resume_test
			.endp
			;=========================================================================
		.proc vbi2
					.ifdef SYS5200
					cld
					pha
					txa
					pha
					tya
					pha
					.endif
		mva		#0 nmien
			lda		nmist
			and		#$40
				_ASSERTA $00, c"NMIST bit 6 was set within VBI handler after NMIRES."
			jmp		resume_test2
			.endp
			;=========================================================================
		.proc dli1
				pha
					;check that we were only called once
			lda		d0
			beq		first_time
				_FAIL	c"The DLI1 handler was invoked more than once.",0
		first_time:
			mva		#$ff d0
					;strobe NMIRES and check that the DLI bit is cleared
			sta		nmires
			lda		nmist
			and		#$c0
				_ASSERTA $00, c"NMIRES did not clear the DLI bit: $%x"
					;setup for next DLI handler
	mwa		#dli2 vdslst
				pla
				rti
			.endp
		.proc dli2
				pha
					;We should only get here once. If we got here more than once, it
					;means that an NMI was dispatched more than once, which is bad.
					;It means that either the same DLI was dispatched more than once
					;or that the DLI bit wasn't cleared at scanline 248.
			lda		d1
			beq		first_time
				_FAIL	c"The DLI2 handler was invoked more than once.",0
		first_time:
			mva		#$ff d1
					;Exit without strobing NMIRES. This should not cause a problem.
				pla
				rti
			.endp
		.proc dli3
				pha
			mva		#$ff d1
				pla
				rti
			.endp
		.proc vbi3
					.ifdef SYS5200
					cld
					pha
					txa
					pha
					tya
					pha
					.endif
			mva		#$ff d1
				pla
				tay
				pla
				tax
				pla
				rti
			.endp
			;=========================================================================
				org		$2c00
		dlist:
			dta		$70
				dta		$70
				dta		$70
				dta		$f0
				dta		$f0
			dta		$41,a(dlist)
			run		$2000
					end
