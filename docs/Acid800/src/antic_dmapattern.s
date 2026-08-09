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
				_SAP_HEADER "ANTIC: DMA pattern"
					opt		h+o+
					icl		'library.s'
				org		$0080
		quickrs:
	:16 dta $00
		rand1	dta		0			;first random value
		rand2	dta		0			;second random value, 114 cycles past first
	randpos	dta		a(0)		;random position index (1-511)
	testptr	dta		a(0)		;pointer to current test data
		delyidx	dta		0			;profiling cycle delay (doubled; must be even)
		profrdy	dta		0			;set when DLI handler should execute test
		dispslc	dta		0			;display slice (0-3)
		xsave	dta		0			;DLI X register save
		ysave	dta		0			;DLI Y register save
				org		$2000
			;==========================================================================
			; ANTIC DMA pattern test
			;
			; This test involves quite a bit more trickery than usual, so it deserves
			; some explanation.
			;
			; What we're trying to do is determine which cycles are blocked by ANTIC
			; DMA during a scan line. However, the CPU can't monitor this directly
			; since it's halted, and there isn't a convenient and reliable cycle
			; timer on the A8. High-speed POTs *almost* work for this but have a glitch
			; in HBLANK. Therefore, we use trusty RANDOM instead. In 9-bit mode, we
			; can *almost* read the entire LFSR, but unfortunately we're short one bit.
			; To determine the true position, we take two samples exactly one scanline
			; apart. We can then look up through a series of carefully constructed
			; tables:
			;
			;	lfsrtab		RANDOM values in cycle order (Pad byte + 511 entries).
			;	lfsrlo/hi0	One-based index given RANDOM value, assuming high bit = 0.
			;	lfsrlo/hi1	One-based index given RANDOM value, assuming high bit = 1.
			;
			; Given the first value, we can look up its two possible indices, and
			; check the second value 114 cycles later in the sequence table to select
			; the right once. We then walk down the expected bitmask and LFSR sequence
			; in parallel, counting off the *unhalted* cycles, and checking the LFSR
			; values against the recorded RANDOM values in the scanline. We can't
			; just search the sequence, because all values except 00 occur twice, and
			; the duplicates are sometimes very close (FF FF occurs in it).
			;
			; That leaves sampling RANDOM during the scanline. We can't possibly do it
			; every cycle; the best that the 6502 can do is once every 7 cycles.
			; To work around this we need seven sampling passes all skewed by one
			; cycle apart.
			;
			; Optimizing the sampling passes
			; ------------------------------
			; We have 50 tests to do and 7 passes to do on each test. Older versions
			; of this test used to do one pass a frame, which was annoyingly long
			; at six seconds. The display list has been tightened up and four passes
			; are now done a frame, speeding the test up to a second and a half.
			; The main obstacle to further speedups is the LFSR scanning routine, which
			; takes a few dozen scanlines to analyze the results of a pass.
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
					;generate 9-bit LFSR tables
			jsr		genlfsr9
					;kill screen
			jsr		_screenOff
			jsr		_interruptsOff
					;wait for vertical blank and swap in new display list
			jsr		_waitVBL
	mwa		#dli vdslst
	mwa		#dlist dlistl
		mva		#$22 dmactl
		mva		#$80 nmien
					;switch to 9-bit lfsr
		mva		#$80 audctl
					;begin test loop
	mwa		#testdata testptr
					;============================ MODE LOOP =============================
					;This is where we loop through each ANTIC mode in turn.
		testloop:
			ldx		#0
					;=========================== OFFSET LOOP ============================
					;This is where we loop through unblocked cycle offsets 0-6 for the
					;mode line.
		offsetloop:
			stx		delyidx
					;wait for scanline 16 every four display slices, as that's what fits
			lda		dispslc
			inc		dispslc
			and		#3
			bne		nowaitvbl
			lda		#8
		cmp:rne	vcount
		nowaitvbl:
					;turn off playfield and display list DMA
		mva		#0 dmactl
					;wait for end of scanline
			sta		wsync
					;reset display list -- it's a little too tight to do this before the
					;the display list read, so we safely wait past it and blow a scanline;
					;this requires a minimum of 18 cycles of delay
			pha:pla
			pha:pla
			pla:pla
	mwa		#dlist dlistl
					;wait for wsync again and turn display DMA back on
			lda		#$22
			sta		wsync
			sta		dmactl
					;signal DLI handler to run
			mva		#$ff profrdy
					;wait for DLI to occur
			lda:rne	profrdy
					;set up LFSR index to point to the right location -- we need to be four
					;scanlines + 7 cycles past (106 -> 113) = 463 cycles ahead, but we need
					;one cycle less since we increment at the start below
			lda		a0
				clc
			adc		#<[462-114]
			sta		a0
			lda		a0+1
			and		#$01
			adc		#>[462-114]
		lfsrptrnorm:
			cmp		#2
			bcc		lfsrptrok
			and		#1
			inc		a0
			bne		lfsrptrok
				clc
			adc		#1
			bcc		lfsrptrnorm
		lfsrptrok:
			ora		#>lfsrtab
			sta		a0+1
					;compute the initial index in unblocked cycles; we need to skip this many
					;in the data.
			lda		delyidx
				lsr
				tax
				inx
					;============================ SCAN LOOP =============================
					;Here we walk through the test data every 7 unblocked cycles, checking
					;that LFSR values are as expected.
					;
					;	X		Number of unblocked cycles left to advance
					;	Y		Index into test data
					;	A0		Current LFSR data pointer
					;	D0		Current test data; shifted left
					;	D1		Bit counter ($01, $02, $04....)
					;	D2		Temporary
					;	D3		result index
					;reset result index
			mva		#0 d3
					;load first test byte and bit indicator
			ldy		#1
			sty		d1
	adw		testptr #2 testpt2
			mva		(testptr),y d0
			ldy		a0
			mva		#0 a0
			jmp		sevenloop
				.align	256
		lfsrinc2:
			pha
			inc		a0+1
			lda		a0+1
			cmp		#$32
				pla
			bcc		lfsrinc1
				iny
				pha
			mva		#>lfsrtab a0+1
				pla
			bcs		lfsrinc1
		load_new_byte:
					;load next test byte
			lda.w	$0
		testpt2 = *-2
	inw		testpt2
					;check if we're done
			cmp		#$a5
			beq		bitscancomplete
					;reset byte flag
			inc		d1
			bne		samebyte
		sevenloop:
			lda		d0
		bitloop:
		isblocked:
					;advance to next LFSR index
				iny
			beq		lfsrinc2
		lfsrinc1:
					;advance to next bit in test stream
				rol
			rol		d2
			asl		d1
			bcs		load_new_byte
		samebyte:
					;keep going if this is a blocked cycle
			ror		d2
			bcs		isblocked
					;keep going if we still need to skip unblocked cycles
				dex
			bne		bitloop
			sta		d0
					;check if the LFSR value matches
			ldx		d3
			inc		d3
			lda		quickrs,x
			cmp		(a0),y
			bne		randfail
					;go back to check another value 7 unblocked cycles later
			ldx		#7
			jmp		sevenloop
		randfail:
					;uh oh....
			ldy		#0
			lda		(testptr),y
				lsr
				lsr
			sta		d1
			lda		(testptr),y
			and		#3
				clc
			adc		#'a'
			sta		d2
				_FAIL	c"Incorrect timing for mode %x-%c"
		bitscancomplete:
					;========================== END SCAN LOOP ===========================
					;continue until we've done all 7 offsets
			ldx		delyidx
				inx
				inx
			cpx		#14
		seq:jmp	offsetloop
					;========================= END OFFSET LOOP ==========================
					;bump up test pointer by test size (16 bytes)
			lda		testptr
				clc
			adc		#16
			sta		testptr
			scc:inc	testptr+1
					;continue if we still have tests
			ldy		#0
			lda		(testptr),y
			beq		done
			jmp		testloop
		done:
					;all done!
			jmp		_testPassed
			;=========================================================================
		.proc	dli
				pha
					;check if we've should run
			lda		profrdy
			beq		xit
					;immediately block to prevent recursion
			inc		profrdy
					;save X/Y
			sty		ysave
			stx		xsave
					;modify display list mode byte
			ldy		#0
			lda		(testptr),y
				lsr
				php
				lsr
			ora		#$40
			sta		dlmode
			lda		#$21
			adc		#0
			sta		dmactl
				plp
					;check if we need to skip an extra line
			bcc		noxline
			sta		wsync			;end scanline 16
		noxline:
			sta		wsync			;end scanline 16/17
					;dispatch to routine
			jsr		doProfile
					;decode the starting offset
			jsr		unrand
			ldx		xsave
			ldy		ysave
		xit:
				pla
				rti
		doProfile:
			ldx		delyidx
			lda		routines+1,x
				pha
			lda		routines,x
				pha
				rts
		routines:
			dta		a(profileDelay0-1)
			dta		a(profileDelay1-1)
			dta		a(profileDelay2-1)
			dta		a(profileDelay3-1)
			dta		a(profileDelay4-1)
			dta		a(profileDelay5-1)
			dta		a(profileDelay6-1)
			.endp
			;=========================================================================
		.proc genlfsr9
			mva		#0 d2
			ldy		#1
	mwa		#lfsrtab a0
			lda		#$ff
			sta		d0
				clc
				php
		loop2:
				plp
		loop:
			mva		d0	(a0),y
				tax
				tya
			bcc		low
			sta		lfsrlo1,x
		mva		d2 lfsrhi1,x
			bcs		hi
		low:
			sta		lfsrlo0,x
		mva		d2 lfsrhi0,x
		hi:
			ror		d0
			ror		d1
				txa
				rol
				rol
			eor		d1
				rol
				iny
			bne		loop
				php
			inc		a0+1
			inc		d2
			lda		d2
			cmp		#2
			bne		loop2
				plp
					;add 114 to all values (needed by unrand)
			ldx		#0
		addloop:
		mva		lfsrlo0,x randpos
		mva		lfsrhi0,x randpos+1
			jsr		add114
		mva		a0 lfsrlo0,x
		mva		a0+1 lfsrhi0,x
		mva		lfsrlo1,x randpos
		mva		lfsrhi1,x randpos+1
			jsr		add114
		mva		a0 lfsrlo1,x
		mva		a0+1 lfsrhi1,x
				inx
			bne		addloop
				rts
			.endp
			;=========================================================================
			; unrand
			;
			; Converts rand1/rand2 pair into randpos index.
			;
		.proc	unrand
					;try first with high bit = 0
			ldx		rand1
		mva		lfsrlo0,x a0
		mva		lfsrhi0,x a0+1
			ldy		#0
			lda		rand2
			cmp		(a0),y
			beq		foundit
					;nope... try with high bit = 1
			ldx		rand1
		mva		lfsrlo1,x a0
		mva		lfsrhi1,x a0+1
			lda		rand2
			cmp		(a0),y
			beq		foundit
					;whoops... we can't decode this pair!
			mva		rand1 d1
			mva		rand2 d2
				_FAIL	c"Cannot decode random pair: %x %x"
		foundit:
				rts
			.endp
		.proc add114
			lda		randpos
				clc
			adc		#114
			sta		a0
			lda		randpos+1
			adc		#0
			cmp		#2
			bcc		add114_nocarry
					;whoops, we've wrapped... subtract 511.
			lda		#0
			inc		a0
			sne:lda	#1
		add114_nocarry:
			ora		#>lfsrtab
			sta		a0+1
				rts
			.endp
			;=========================================================================
		.proc profile
			lda		$ffff				;106, 107, 108, 109
		mva		random quickrs+0	;110, 111, 112, [113]...
		mva		random quickrs+1
		mva		random quickrs+2
		mva		random quickrs+3
		mva		random quickrs+4
		mva		random quickrs+5
		mva		random quickrs+6
		mva		random quickrs+7
		mva		random quickrs+8
		mva		random quickrs+9
		mva		random quickrs+10
		mva		random quickrs+11
		mva		random quickrs+12
		mva		random quickrs+13
		mva		random quickrs+14
		mva		random quickrs+15
			stx		rand1
			sty		rand2
				rts
			.endp
			;=========================================================================
		.proc profileDelay0
			sta		wsync		;end of scanline 19/20
			ldx		random
			sta		wsync		;end of scanline 20/21
			ldy		random
			sta		wsync		;end of scanline 21/22
			sta		wsync		;end of scanline 22/23
			sta		wsync		;end of scanline 23/24
			jmp		profile		;*, 104, 105
			.endp
			;=========================================================================
		.proc profileDelay1
			sta		wsync
			ldx		random
			sta		wsync
			ldy		random
			sta		wsync
			sta		wsync
			inc		wsync
			jmp		profile
			.endp
			;=========================================================================
		.proc profileDelay2
			sta		wsync
			ldx		random
			sta		wsync
			ldy		random
			sta		wsync
			sta		wsync
			sta		wsync
				nop
			jmp		profile
			.endp
			;=========================================================================
		.proc profileDelay3
			sta		wsync
			ldx		random
			sta		wsync
			ldy		random
			sta		wsync
			sta		wsync
			sta		wsync
			lda		$ff
			jmp		profile
			.endp
			;=========================================================================
		.proc profileDelay4
			sta		wsync
			ldx		random
			sta		wsync
			ldy		random
			sta		wsync
			sta		wsync
			sta		wsync
			lda		$ffff
			jmp		profile
			.endp
			;=========================================================================
		.proc profileDelay5
			sta		wsync
			ldx		random
			sta		wsync
			ldy		random
			sta		wsync
			sta		wsync
			sta		wsync
			lda		$ff
				nop
			jmp		profile
			.endp
			;=========================================================================
		.proc profileDelay6
			sta		wsync
			ldx		random
			sta		wsync
			ldy		random
			sta		wsync
			sta		wsync
			sta		wsync
			lda		$ffff
				nop
			jmp		profile
			.endp
			;=========================================================================
		testname:
	dta		c"ANTIC: DMA pattern",0
				org		$2800
		dlist:
			dta		$80
				dta		$40
		dlmode:
			dta		$21,a(testname)	;dummy data
		dljam:
					;we purposely use a jump here instead of JVB, as you can't break
					;out of a JVB manually
			dta		$01,a(dljam)
		lfsrtab	equ		$3000		;512 bytes (first byte is not used)
		lfsrlo0	equ		$3400
		lfsrhi0	equ		$3500
		lfsrlo1	equ		$3600
		lfsrhi1	equ		$3700
				org		$3800
			; Test data
			;
			; The first byte is mode*2 + second_line; the subsequent bytes are the
			; DMA cycle pattern.
		testdata:
			;narrow playfield
			;				                                                                                                                                  1           1
			;				                  1           2           3             4           5           6           7             8           9           0           1
			;				      0123456  78901234  56789012  34567890  12345678  90123456  78901234  56789012  34567890  12345678  90123456  78901234  56789012  34567890
dta		$08,%01000011,%00000000,%00000000,%01101111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11110000,%00000000,%00000000,$A5
dta		$09,%00000000,%00000000,%00000000,%01000111,%01110111,%01110111,%01110111,%01110101,%01010101,%01010101,%01010101,%01010000,%00000000,%00000000,$A5
dta		$0c,%01000011,%00000000,%00000000,%01101111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11110000,%00000000,%00000000,$A5
dta		$0d,%00000000,%00000000,%00000000,%01000111,%01110111,%01110111,%01110111,%01110101,%01010101,%01010101,%01010101,%01010000,%00000000,%00000000,$A5
dta		$10,%01000011,%00000000,%00000000,%01101111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11110000,%00000000,%00000000,$A5
dta		$11,%00000000,%00000000,%00000000,%01000111,%01110111,%01110111,%01110111,%01110101,%01010101,%01010101,%01010101,%01010000,%00000000,%00000000,$A5
dta		$10,%01000011,%00000000,%00000000,%01101111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11110000,%00000000,%00000000,$A5
dta		$11,%00000000,%00000000,%00000000,%01000111,%01110111,%01110111,%01110111,%01110101,%01010101,%01010101,%01010101,%01010000,%00000000,%00000000,$A5
dta		$18,%01000011,%00000000,%00000000,%01100111,%01110111,%01110111,%01110111,%01110110,%01100110,%01100110,%01100110,%01000000,%00000000,%00000000,$A5
dta		$19,%00000000,%00000000,%00000000,%01000110,%01100110,%01100110,%01100110,%01100100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,$A5
dta		$1c,%01000011,%00000000,%00000000,%01100111,%01110111,%01110111,%01110111,%01110110,%01100110,%01100110,%01100110,%01000000,%00000000,%00000000,$A5
dta		$1d,%00000000,%00000000,%00000000,%01000110,%01100110,%01100110,%01100110,%01100100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,$A5
dta		$20,%01000011,%00000000,%00000000,%01001100,%01001100,%01001100,%01001100,%01001000,%00001000,%00001000,%00001000,%00000000,%00000000,%00000000,$A5
dta		$21,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$24,%01000011,%00000000,%00000000,%01001100,%01001100,%01001100,%01001100,%01001000,%00001000,%00001000,%00001000,%00000000,%00000000,%00000000,$A5
dta		$25,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$28,%01000011,%00000000,%00000000,%01001100,%11001100,%11001100,%11001100,%11001000,%10001000,%10001000,%10001000,%10000000,%00000000,%00000000,$A5
dta		$29,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$2c,%01000011,%00000000,%00000000,%01001100,%11001100,%11001100,%11001100,%11001000,%10001000,%10001000,%10001000,%10000000,%00000000,%00000000,$A5
dta		$2d,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$30,%01000011,%00000000,%00000000,%01001100,%11001100,%11001100,%11001100,%11001000,%10001000,%10001000,%10001000,%10000000,%00000000,%00000000,$A5
dta		$34,%01000011,%00000000,%00000000,%01001110,%11101110,%11101110,%11101110,%11101010,%10101010,%10101010,%10101010,%10100000,%00000000,%00000000,$A5
dta		$35,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$38,%01000011,%00000000,%00000000,%01001110,%11101110,%11101110,%11101110,%11101010,%10101010,%10101010,%10101010,%10100000,%00000000,%00000000,$A5
dta		$3c,%01000011,%00000000,%00000000,%01001110,%11101110,%11101110,%11101110,%11101010,%10101010,%10101010,%10101010,%10100000,%00000000,%00000000,$A5
			;normal playfield
			;				                                                                                                                                  1           1
			;				                  1           2           3             4           5           6           7             8           9           0           1
			;				      0123456  78901234  56789012  34567890  12345678  90123456  78901234  56789012  34567890  12345678  90123456  78901234  56789012  34567890
dta		$0a,%01000011,%00000000,%00101111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11110000,%00000000,$A5
dta		$0b,%00000000,%00000000,%00000101,%01110111,%01110111,%01110111,%01110111,%01110101,%01010101,%01010101,%01010101,%01010101,%01010000,%00000000,$A5
dta		$0e,%01000011,%00000000,%00101111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11110000,%00000000,$A5
dta		$0f,%00000000,%00000000,%00000101,%01110111,%01110111,%01110111,%01110111,%01110101,%01010101,%01010101,%01010101,%01010101,%01010000,%00000000,$A5
dta		$12,%01000011,%00000000,%00101111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11110000,%00000000,$A5
dta		$13,%00000000,%00000000,%00000101,%01110111,%01110111,%01110111,%01110111,%01110101,%01010101,%01010101,%01010101,%01010101,%01010000,%00000000,$A5
dta		$16,%01000011,%00000000,%00101111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11111111,%11110000,%00000000,$A5
dta		$17,%00000000,%00000000,%00000101,%01110111,%01110111,%01110111,%01110111,%01110101,%01010101,%01010101,%01010101,%01010101,%01010000,%00000000,$A5
dta		$1a,%01000011,%00000000,%00100110,%01110111,%01110111,%01110111,%01110111,%01110110,%01100110,%01100110,%01100110,%01100110,%01000000,%00000000,$A5
dta		$1b,%00000000,%00000000,%00000100,%01100110,%01100110,%01100110,%01100110,%01100100,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,$A5
dta		$1e,%01000011,%00000000,%00100110,%01110111,%01110111,%01110111,%01110111,%01110110,%01100110,%01100110,%01100110,%01100110,%01000000,%00000000,$A5
dta		$1f,%00000000,%00000000,%00000100,%01100110,%01100110,%01100110,%01100110,%01100100,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,$A5
dta		$22,%01000011,%00000000,%00001000,%01001100,%01001100,%01001100,%01001100,%01001000,%00001000,%00001000,%00001000,%00001000,%00000000,%00000000,$A5
dta		$23,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$26,%01000011,%00000000,%00001000,%01001100,%01001100,%01001100,%01001100,%01001000,%00001000,%00001000,%00001000,%00001000,%00000000,%00000000,$A5
dta		$27,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$2a,%01000011,%00000000,%00001000,%11001100,%11001100,%11001100,%11001100,%11001000,%10001000,%10001000,%10001000,%10001000,%10000000,%00000000,$A5
dta		$2b,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$2e,%01000011,%00000000,%00001000,%11001100,%11001100,%11001100,%11001100,%11001000,%10001000,%10001000,%10001000,%10001000,%10000000,%00000000,$A5
dta		$2f,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$32,%01000011,%00000000,%00001000,%11001100,%11001100,%11001100,%11001100,%11001000,%10001000,%10001000,%10001000,%10001000,%10000000,%00000000,$A5
dta		$36,%01000011,%00000000,%00001010,%11101110,%11101110,%11101110,%11101110,%11101010,%10101010,%10101010,%10101010,%10101010,%10100000,%00000000,$A5
dta		$37,%00000000,%00000000,%00000000,%01000100,%01000100,%01000100,%01000100,%01000000,%00000000,%00000000,%00000000,%00000000,%00000000,%00000000,$A5
dta		$3a,%01000011,%00000000,%00001010,%11101110,%11101110,%11101110,%11101110,%11101010,%10101010,%10101010,%10101010,%10101010,%10100000,%00000000,$A5
dta		$3e,%01000011,%00000000,%00001010,%11101110,%11101110,%11101110,%11101110,%11101010,%10101010,%10101010,%10101010,%10101010,%10100000,%00000000,$A5
				dta		$00
			run		$2000
					end
