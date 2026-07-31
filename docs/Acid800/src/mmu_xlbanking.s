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
				_SAP_HEADER "MMU: XL banking"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
					;skip if we only have 16K of memory
			lda		ramtop
			cmp		#$41
			bcs		memok
				_SKIP	c"Test skipped: <64K of memory."
		memok:
			jsr		_screenOff
			jsr		_interruptsOff
					;reset PIA port B
		mva		#$3c pbctl
		mva		#$01 portb
		mva		#$38 pbctl
		mva		#$ff portb
					;bank out all ROMs and make sure we've got RAM
		mva		#$3c pbctl
		mva		#$c2 portb
			jsr		testROMs
				_ASSERT1 d0, $0f, c"Unable to bank out ROMs: mask=$%x."
					;bank in only the kernel ROM and recheck
		mva		#$f3 portb
			jsr		testROMs
				_ASSERT1 d0, $03, c"Unable to bank in kernel ROM."
					;bank in only the BASIC ROM and recheck
		mva		#$f0 portb
			jsr		testROMs
				_ASSERT1 d0, $0d, c"Unable to bank in BASIC ROM."
					;try to bank in only the self test ROM and recheck
		mva		#$72 portb
			jsr		testROMs
				_ASSERT1 d0, $0f, c"Self-test ROM bit failed: mask=$%x."
					;bank in both the kernel and self-test ROMs
		mva		#$73 portb
			jsr		testROMs
				_ASSERT1 d0, $02, c"Unable to bank in self-test ROM: mask=$%x."
					;attempt to complement bytes through ROM; this should fail
		mva		#$fe portb
		mva		$c000 d0
		mva		$f000 d1
		mva		$a000 d2
		mva		$5000 d3
		mva		#$71 portb
			lda		d0
			eor		#$ff
			sta		$c000
			lda		d1
			eor		#$ff
			sta		$f000
			lda		d2
			eor		#$ff
			sta		$a000
			lda		d3
			eor		#$ff
			sta		$5000
		mva		#$fe portb
			lda		$c000
			eor		d0
			ldx		d0
			stx		$c000
			sta		d0
			lda		$f000
			eor		d1
			ldx		d1
			stx		$f000
			sta		d1
			lda		$a000
			eor		d2
			ldx		d2
			stx		$a000
			sta		d2
			lda		$5000
			eor		d3
			ldx		d3
			stx		$5000
			sta		d3
				_ASSERT1 d0, $00, c"Write through lower kernel ROM was not blocked."
				_ASSERT1 d1, $00, c"Write through upper kernel ROM was not blocked."
				_ASSERT1 d2, $00, c"Write through BASIC ROM was not blocked."
				_ASSERT1 d3, $00, c"Write through self-test ROM was not blocked."
					;Turn on extended banking and check if bit 7 is a significant banking
					;bit. If so, skip the extbank/selftest check.
		mva		#$cf portb		;enable $00 extbank
			lda		$7fff			;load $00:3FFF
			eor		#$ff
		mvy		#$4f portb		;enable $80 extbank
			ldy		$7fff			;save $80:3FFF
			sta		$7fff			;write complement of $00:3FFF to $80:3FFF
		mvx		#$cf portb		;enable $00 extbank
			cmp		$7fff			;check if $00:3FFF changed when $80:3FFF was written
				php						;save comparison result
		mva		#$4f portb		;enable $80 extbank
			sty		$7fff			;restore $80:3FFF
		mva		#$ff portb		;disable extended banking
				plp						;restore comparison result
			bne		skip_extselftest
					;Turn on extended banking and the self-test ROM and verify that the self-test
					;ROM wins. (This may fail with memory expansions above 128K).
		mva		#$43 portb
			jsr		testROMs
				_ASSERT1 d0, $02, c"Unable to bank in self-test ROM with extended RAM enabled: mask=$%x."
			jmp		_testPassed
		skip_extselftest:
			jsr		_testSkipped
	dta		c"Bit 7 banking detected.",0
		.proc testROMs
					;test $c000
			ldy		#$c0
			lda		#$00
			jsr		testAddress
			ldx		#0
			cmp		#$aa
			sne:inx
			stx		d0
					;test $f000
			ldy		#$f0
			lda		#$00
			jsr		testAddress
			asl		d0
			cmp		#$aa
			sne:inc	d0
					;test $a000
			ldy		#$a0
			lda		#$00
			jsr		testAddress
			asl		d0
			cmp		#$aa
			sne:inc	d0
					;test $5000
			ldy		#$50
			lda		#$00
			jsr		testAddress
			asl		d0
			cmp		#$aa
			sne:inc	d0
				rts
			.endp
		.proc testAddress
			sty		a0+1
			sta		a0
			ldy		#0
			lda		(a0),y
				tax
			eor		#$aa
			sta		(a0),y
				txa
			eor		(a0),y
				pha
				txa
			sta		(a0),y
				pla
				rts
			.endp
		testname:
	dta		c"MMU: XL banking",0
			run		$2000
					end
