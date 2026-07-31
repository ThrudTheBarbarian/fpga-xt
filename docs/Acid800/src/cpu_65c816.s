			; Altirra Acid800 test suite
			; Copyright (C) 2010-2013 Avery Lee, All Rights Reserved.
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
					opt		h+o+
					icl		'library.s'
					opt		o-
				icl		'options.s'
			.macro _FAIL816
					jsr		FailTest816
					dta		:1,0
			.endm
			.macro _ASSERT816
					:1		ok
					jsr		FailTest816
					dta		:2,0
			ok:
			.endm
					opt		o+
				org		$0080
	emusp			dta		0
		save_crb		dta		0
		save_ddrb		dta		0
		save_orb		dta		0
		switched_pia	dta		0
		switched_os		dta		0
		switched_zp		dta		0
		romos_ok		dta		0
		int_p			dta		0
		int_type		dta		0
				org		$2000
					opt		o-
		oszpsave:
				.ds		128
		stksave:
				.ds		128
		romsave:
				.ds		32
		vercopy_start = $1000
					opt		o+
				org		$2200
		.proc main
			lda		#<[test_name+1]
			ldy		#>[test_name+1]
		quick_abort_msg:
			jsr		_testInit
			lda		_cpuMode
			ora		_veronica
			bmi		have_816
				_SKIP	'No 65C816 present.'
		test_name:
	dta		$9b,'CPU: 65C816 tests',0
		precheck:
					;check if 65C816 or Veronica is present - if so, print the banner and
					;bail out now, without loading the full test (so it can extend beyond
					;16K)
			lda		_cpuMode
			ora		_veronica
			spl:rts
			lda		#<test_name
			ldy		#>test_name
			jmp		quick_abort_msg
			ini		precheck
		have_816:
					opt		c+
					;save off current stack pointer
			tsx
			stx		emusp
					;check if we are using Veronica
			bit		_veronica
			bpl		no_veronica
					;launch on Veronica
			lda		#>veronica_start
			sta		d0
			ldx		#<veronica_start
			lda		#>vercopy_start
			ldy		#>[vercopy_end-1]+1->[vercopy_start]
			jsr		_veronicaLaunch
		smi:jmp	_testPassed
				pha
				txa
				pha
			jmp		_testFailed
		veronica_start:
		mva		#$4c _testFailed
	mwa		#FailTest816 _testFailed+1
		no_veronica:
					;first, let's do some basic tests in emulation mode with interrupts on
			lda		#$a5
				xba
			lda		#$f0
				xba
				_ASSERTA $a5, 'XBA instruction failed.'
			ldx		#$42
				phx
				pla
				_ASSERTA $42, 'PHX instruction failed.'
			ldy		#$8c
				phy
				pla
				_ASSERTA $8c, 'PHY instruction failed.'
			lda		#$22
				pha
				plx
				_ASSERTX $22, 'PLX instruction failed.'
			lda		#$fe
				pha
				ply
				_ASSERTY $fe, 'PLY instruction failed.'
				tdc
				_ASSERTA $00, 'TDC instruction failed.'
			ldx		#$01
			ldy		#$02
				txy
				_ASSERTY $01, 'TXY instruction failed.'
			ldx		#$01
			ldy		#$02
				tyx
				_ASSERTX $02, 'TYX instruction failed.'
					;check that WDM is a two-byte opcode
				wdm
				inx
				_ASSERTX $02, 'WDM was not a two-byte opcode.'
					;check that we cannot clear M/X in emulation mode
				php
				pla
			and		#$cf
				pha
				plp
				php
				pla
			and		#$30
				_ASSERTA $30, 'PLP was able to clear M or X in emu mode.'
					;test REP/SEP
				clc
			sep		#$01
				_ASSERT816 bcs, 'SEP did not set carry flag.'
			rep		#$01
				_ASSERT816 bcc, 'REP did not clear carry flag.'
			rep		#$30
				php
				pla
			and		#$30
			cmp		#$30
				_ASSERTA $30, 'REP was able to clear M or X in emu mode.'
					;interrupts off
			bit		_veronica
			bmi		skip_intsoff
			jsr		_screenOff
			jsr		_interruptsOff
		skip_intsoff:
					;save off OS zero page and low stack
			ldx.b	#$7f
		zpsave_loop:
		mva		0,x oszpsave,x
		mva		$100,x stksave,x
				dex
			bpl		zpsave_loop
			stx		switched_zp
					;check that dp,X addressing wraps in zero page
			lda.b	#$f2
			sta		d1
			ldx.b	#$ff
			cmp		d1+1,x
				_ASSERT816 beq, 'dp,X did not wrap in zero page with D=0.'
					;check that (dp),Y and (dp,X) addressing wraps in zero page
			ldx		d0+$100			;save d0+$100
				phx
			ldx		$100
				phx
			mva		#$aa d0
		mva		#$cc d0+$100
			mva		#d0 $ff
			mva		#0	$0
		mva		#1	$100
			ldy.b	#0
				tyx
			lda		($ff)
			sta		dpwrap_result
			lda		($ff),y
				xba
			lda		($ff,x)
				plx
			sta		$100
				plx
			stx		d0+$100
			cmp		#$aa
				_ASSERT816 beq, '(dp,X) address read did not wrap in page zero.'
				xba
			cmp		#$aa
				_ASSERT816 beq, '(dp),Y address read did not wrap in page zero.'
			lda		#0
		dpwrap_result = *-1
			cmp		#$aa
				_ASSERT816 beq, '(dp) address read did not wrap in page zero.'
					;check that [dp] and [dp],Y do not wrap in page zero, even in emulation mode and
					;with DL=0
			mva		#$aa $08
			mva		#$ab $09
		mva		#$cc $108
		mva		#$cd $109
			mva		#$08 $ff
		mva		#$09 $1ff
			mva		#0	$0
		mva		#1	$100
		mva		#0	$101
			ldy.b	#0
			lda		[$ff],y
				xba
			lda		[$ff]
			cmp.b	#$cc
				_ASSERT816 beq, '[dp] address read wrapped in page zero.'
				xba
			cmp.b	#$cc
				_ASSERT816 beq, '[dp],Y address read wrapped in page zero.'
					;check that PEI (dp) does not wrap
			pei		($ff)
				pla
			cmp.b	#8
		pei_fail:
				_ASSERT816 beq, 'PEI (dp) did not cross pages with DL=0.'
				pla
			cmp.b	#1
			bne		pei_fail
					;check that we can change the direct page to page 1 with wrapping
			lda.b	#1
				xba
			lda.b	#0
				tcd
			lda.b	#$3c
				pha
				tsx
				inx
				inx
			cmp.b	$ff,x
				_ASSERT816 beq, 'dp,X did not wrap in page one with D=$100.'
				pla
					;check that we can change the direct page base to $0001 and that it
					;can cross into page one
			lda.b	#0
				xba
			lda.b	#1
				tcd
			ldx.b	#$ff
			lda.b	#$5c
			sta.b	$20,x
			cmp		$120
				_ASSERT816 beq, 'dp,X did not cross page boundaries with DL!=0.'
					;check that (dp,X=0) still wraps high byte
			ldx.b	#0
			lda		($fe,x)
			cmp.b	#$aa
				_ASSERT816 beq, '($fe,X=0) crossed page boundaries with DL=1.'
					;check that (dp,X=$ff) crosses pages
				dex
			lda		($ff,x)		;($1ff) = $109
			cmp.b	#$cd
				_ASSERT816 beq, '($fe,X=$ff) unexpected read with DL=1.'
					;check that (dp),Y now wraps
			ldy.b	#0
			lda		($fe),y
			cmp.b	#$cc
				_ASSERT816 beq, '(dp),Y did not cross page boundaries with DL!=0.'
					;check that (dp) now wraps
			lda		($fe)
			cmp.b	#$cc
				_ASSERT816 beq, '(dp) did not cross page boundaries with DL!=0.'
					;restore normal direct page
			lda.b	#0
				xba
			lda.b	#0
				tcd
					;check if we can index out of page one using d,S indexing
			ldx.b	#$ff
				txs
			ldy		$0120			;save $0120
			lda		$0220
			eor		#$ff
			sta		$0120
			lda.b	$21,s
			sty		$0120			;restore $0120
			ldx		emusp			;get original stack pointer
				txs						;restore stack pointer
			cmp		$0220
				_ASSERT816 beq, 'd,S addressing did not cross into page 2.'
					;check if we can index out of page one using (d,S),Y indexing
					;CAREFUL: Veronica has hardware registers at $0200-$020F.
			lda		$0220
				pha
			lda		$0221
				pha
			lda		$0120
				pha
			lda		$0121
				pha
			ldx.b	#$ff
				txs
	mwa		#d0-4 $0120
	mwa		#d1-4 $0220
			mva		#$a9 d0
			mva		#$2c d1
			ldy.b	#4
			lda		($21,s),y
			ldx		emusp
				txs
				plx
			stx		$0121
				plx
			stx		$0120
				plx
			stx		$0221
				plx
			stx		$0220
			cmp.b	#$2c
				_ASSERT816 beq, '(d,S),Y addressing did not cross into page 2.'
					;set stack pointer to $00 and see if we can push a 16-bit
					;value into page zero
			mva		$ff d0				;save potential problem locations
		mva		$100 d1
		mva		$1ff d2
			ldx		#0					;reset stack to push 16-bit across page boundary
				txs
			lda		#$ff
			sta		$ff					;($ff) = $ff
				phd							;write $100, $ff
			lda		$ff					;see if ($ff) changed
		mvx		d2 $1ff				;restore locations
		mvx		d1 $100
			mvx		d0 $ff
			ldx		emusp				;restore stack pointer
				txs
			cmp		#0					;check result
				_ASSERT816 beq, 'PHD was not able to write to $00FF in emu mode.'
					;set stack pointer to $FF and see if we can read from page two
			ldy		$0100
			lda		$0200
			eor		#$ff
			sta		$0100
			ldx		#$fe
				txs
				pld							;read $1ff, $200
			ldx.w	emusp				;!! D is weird... must avoid dp addressing!
				txs
			sty		$0100
				tdc
			ldx		#0
				phx
				phx
				pld							;back to normal zero page
				xba
			cmp		$0200
				_ASSERT816 beq, 'PLD was not able to read from $0200 in emu mode.'
					;----------------------------------------------
					; Stack page crossing tests
					;----------------------------------------------
			ldx		#$a5
			sta		$ff
			ldx		#0
				txs
					;PEA should index out of page one
			pea		#$abcd
			lda		$ff
			cmp		#$cd
				_ASSERT816 beq, 'PEA did not write to $FF in emu mode.'
				pla
				pla
					;PER should index out of page one
			lda		#<per0_next^$80
			sta		$ff
			per		per0_next
		per0_next:
			lda		$ff
			cmp		#<per0_next
				_ASSERT816 beq, 'PER did not write to $FF in emu mode.'
				pla
				pla
					;PEI should index out of page one
			ldx		#$5c
			stx		a0
				inx
			sta		a0+1
			pei		(a0)
			lda		$ff
			cmp		#$5c
				_ASSERT816 beq, 'PEI did not write to $FF in emu mode.'
				pla
				pla
					;JSL should index out of page one
			lda		#$ff
			sta		$ff
			sta		$fe
			jsl		jsl0_next
		jsl0_next:
			lda		$ff
			cmp		#>[jsl0_next-1]
				_ASSERT816 beq, 'JSL did not write to $FF in emu mode.'
			lda		$fe
			cmp		#<[jsl0_next-1]
				_ASSERT816 beq, 'JSL did not write to $FE in emu mode.'
				pla
				pla
				pla
					;PLB should index across to page two
			ldx		#$e4
			stx		$100
				inx
			stx		$200
			ldx		#$ff
				txs
				plb
				inx
				inx
				txs
				phb
				pla
			ldx		#0
				phx
				plb
			cmp		#$e5
				_ASSERT816 beq, 'PLB did not read from $0200 in emu mode.'
					;PLX, PLY should not index across to page two
			ldx		#$ff
				txs
				ply
				txs
				plx
			cpx		#$e4
				_ASSERT816 beq, 'PLX should not read from $0200 in emu mode.'
			cpy		#$e4
				_ASSERT816 beq, 'PLY should not read from $0200 in emu mode.'
					;
			ldx		emusp
				txs
					;jump to native mode (and test XCE)
				clc
				xce
				_ASSERT816 bcs, 'XCE did not set the carry flag.'
					;----------------------------------------------
					;       ** WE ARE NOW IN NATIVE MODE **
					;----------------------------------------------
					;save off the ROM vector area
			ldx		#31
	mva:rpl	$ffe0,x romsave,x-
					;check if we are running on a RAM OS
			inc		$ffff
			lda		$ffff
			dec		$ffff
			cmp		$ffff
			bne		ram_os
					;save off the current port B state
			ldx		#$38
			ldy		#$3c
		mva		portb save_crb
			stx		pbctl
		mva		portb save_ddrb
			sty		pbctl
		mva		portb save_orb
					;try to bank out the kernel ROM
			lda		#$ff
			sta		switched_pia
			sta		portb
			stx		pbctl
			sta		portb
			sty		pbctl
		mva		#$fe portb
			inc		$ffff
			lda		$ffff
			dec		$ffff
			cmp		$ffff
			beq		softos_fail
			mva		#$ff switched_os
		ram_os:
			mva		#$ff romos_ok
		softos_fail:
					;check that we can do 16-bit accumulator and that NZC are sane.
			rep		#$20
			lda.w	#$a500
				_ASSERT816 bmi, 'LDA.w #$a500 did not set N.'
				_ASSERT816 bne, 'LDA.w #$a500 did not clear Z.'
				clc
			adc.w	#$5b00
				_ASSERT816 bpl, 'ADC.w #$5b00 did not clear N.'
				_ASSERT816 beq, 'ADC.w #$5b00 did not set Z.'
				_ASSERT816 bcs, 'ADC.w #$5b00 did not set C.'
					;check that we can do 16-bit memory
			lda.w	#$00ff
			sta		a0
			inc		a0
			lda		a0
			cmp.w	#$0100
				_ASSERT816 beq, 'INC did not increment a 16-bit location.'
					;check that we can do 16-bit index
			rep		#$10	;MADS bug -- doesn't recognize #$91
			rep		#$81
			ldx.w	#$a500
				_ASSERT816 bmi, 'LDX.w #$a500 did not set N.'
				_ASSERT816 bne, 'LDX.w #$a500 did not clear Z.'
			cpx.w	#$a4ff
				_ASSERT816 bpl, 'CPX.w #$a4ff did not clear N.'
				_ASSERT816 bne, 'CPX.w #$a4ff did not clear Z.'
				_ASSERT816 bcs, 'CPX.w #$a4ff did not set C.'
				clc
			ldy.w	#$a500
				_ASSERT816 bmi, 'LDY.w #$a500 did not set N.'
				_ASSERT816 bne, 'LDY.w #$a500 did not clear Z.'
			cpy.w	#$a4ff
				_ASSERT816 bpl, 'CPY.w #$a4ff did not clear N.'
				_ASSERT816 bne, 'CPY.w #$a4ff did not clear Z.'
				_ASSERT816 bcs, 'CPY.w #$a4ff did not set C.'
			ldx.w	#$a4ff
				inx
				_ASSERT816 bmi, '16-bit INX did not set N properly.'
				_ASSERT816 bne, '16-bit INX did not set Z properly.'
			cpx.w	#$a500
				_ASSERT816 beq, '16-bit INX failed.'
			ldy.w	#$a4ff
				iny
				_ASSERT816 bmi, '16-bit INY did not set N properly.'
				_ASSERT816 bne, '16-bit INY did not set Z properly.'
			cpy.w	#$a500
				_ASSERT816 beq, '16-bit INY failed.'
				inx
				dex
				_ASSERT816 bmi, '16-bit DEX did not set N properly.'
				_ASSERT816 bne, '16-bit DEX did not set Z properly.'
			cpx.w	#$a500
				_ASSERT816 beq, '16-bit DEX failed.'
				iny
				dey
				_ASSERT816 bmi, '16-bit DEY did not set N properly.'
				_ASSERT816 bne, '16-bit DEY did not set Z properly.'
			cpy.w	#$a500
				_ASSERT816 beq, '16-bit DEY failed.'
					;go to 8-bit index and back and make sure XH/YH are cleared.
				inx
				iny
			sep		#$10
			rep		#$10
			cpx.w	#$0001
				_ASSERT816 beq, 'X did not revert to $01 after switch to idx8.'
			cpy.w	#$0001
				_ASSERT816 beq, 'X did not revert to $01 after switch to idx8.'
					;check that switching the acc to 8-bit does NOT clear B
			rep		#$20
			lda.w	#$1234
			sep		#$20
			cmp.b	#$34
				_ASSERT816 beq, 'A did not survive switch to 8-bit acc.'
				xba
			cmp.b	#$12
				_ASSERT816 beq, 'B did not survive switch to 8-bit acc.'
					;check that TXA cannot set B in 8-bit acc mode
			ldx.w	#$5678
			lda.b	#$12
				xba
			lda.b	#$34
				txa
				tax
			cpx.w	#$1278
				_ASSERT816 beq, 'TXA failed in M8X16 mode.'
					;check that TXA can set B in 16-bit acc mode, 8-bit X mode
			rep		#$20
			lda.w	#$1234
			sep		#$10
			ldx.b	#$fe
				txa
			cmp.w	#$00fe
				_ASSERT816 beq, 'TXA failed in M16X8 mode.'
					;-----------------------------------------
					;native direct page tests (DP=0)
					;-----------------------------------------
			sep		#$30
					;check that (dp), (dp,X) and (dp),Y can now wrap even with DL=0
			lda.b	#$55
			sta.b	$20
			lda.b	#$33
			sta.w	$120
			lda.b	#$20
			sta.b	$ff
			lda.b	#$00
			sta.b	$00
				tax
				tay
			lda.b	#$01
			sta.w	$100
			lda		($ff)
			cmp.b	#$33
				_ASSERT816 beq, '(dp) incorrectly wrapped in native mode.'
			lda		($ff,x)
			cmp.b	#$33
				_ASSERT816 beq, '(dp,X) incorrectly wrapped in native mode.'
			lda		($ff),y
			cmp.b	#$33
				_ASSERT816 beq, '(dp),Y incorrectly wrapped in native mode.'
					;set D=$0100
			lda.b	#$01
				xba
			lda.b	#$00
					;check that we can index out of zero page
			ldx.b	#$80
			lda		$140
				inc
			inc		$c0,x
			cmp.b	$c0,x
				_ASSERT816 beq, 'dp,X did not access page one in native mode.'
				txy
			ldx.b	$c0,y
			cpx.b	#$01
				_ASSERT816 beq, 'dp,Y did not access page one in native mode.'
					;check that we can do 16-bit indexing
			rep		#$10
			ldx.w	#no_24bit
			lda.b	0,x
			cmp.w	0,x
				_ASSERT816 beq, 'dp,X did not work with 16-bit indexing.'
					;-----------------------------------------
					;native direct page tests (DP=1)
					;-----------------------------------------
					;switch to misaligned direct page (DP=1)
			pea		#1
				pld
					;verify that (dp,X) is fully wrap free in native mode
					;
					; ($00) = 0
					; ($01) = $fa
					; ($20) = $55
					; ($ff) = $20
					; ($100) = 1
					; ($101) = 1
			lda.b	#1
			sta		$0101
			lda.b	#$fa
			sta		$01
			sep		#$30
			ldx.b	#0
			lda		($fe,x)		;should read $ff, $100 -> $120 -> $33
			cmp.b	#$33
				_ASSERT816 beq, '(dp,X=0) did not cross banks in native mode.'
			ldx.b	#$fe
			lda		(1,x)		;should read $100, $101 -> $101 -> $01
			cmp.b	#1
				_ASSERT816 beq, '(dp,X=$fe) did not cross banks in native mode.'
					;restore DP=0
			pea		#0
				pld
					;-----------------------------------------
					;stack tests
					;-----------------------------------------
					;check TSC against TSX in 8-bit memory mode
			rep		#$10
				tsc
				tsx
			sta		a0
				xba
			sta		a0+1
			cpx		a0
				_ASSERT816 beq, 'TSC and TSX were inconsistent in M8 mode.'
			cmp		#1
				_ASSERT816 beq, 'TSC result was not within page 1.'
					;check TSC in 16-bit memory mode
			rep		#$20
			lda.w	#0
				tsc
			cpx		a0
				_ASSERT816 beq, 'TSC failed in M16 mode.'
					;relocate stack and set $21ff and $2200
			sep		#$20
			ldx.w	#$2200
				txs
			lda.b	#$12
				pha
			cmp.b	0,x
				_ASSERT816 beq, 'Unable to relocate stack to $2200.'
			lda.b	#$34
				pha
				dex
			cmp.b	0,x
				_ASSERT816 beq, 'Unable to cross page with stack.'
					;check PLX, PLY, PHX, PHY (8-bit)
			sep		#$10
				plx
			cpx.b	#$34
				_ASSERT816 beq, 'PLX (8-bit) failed in extended stack.'
				ply
			cpy.b	#$12
				_ASSERT816 beq, 'PLY (8-bit) failed in extended stack.'
			ldx.b	#$56
				phx
				pla
			cmp.b	#$56
				_ASSERT816 beq, 'PHX (8-bit) failed in extended stack.'
			ldy.b	#$78
				phy
				pla
			cmp.b	#$78
				_ASSERT816 beq, 'PHY (8-bit) failed in extended stack.'
					;check PLX, PLY, PHX, PHY (16-bit)
			rep		#$10
			pea		#$a101
				plx
			cpx.w	#$a101
				_ASSERT816 beq, 'PLX (16-bit) failed in extended stack.'
			rep		#$10
			pea		#$a202
				ply
			cpy.w	#$a202
				_ASSERT816 beq, 'PLY (16-bit) failed in extended stack.'
			rep		#$10
			ldx.w	#$a303
				phx
				ply
			cpy.w	#$a303
				_ASSERT816 beq, 'PHX (16-bit) failed in extended stack.'
			rep		#$10
			ldy.w	#$a404
				phy
				plx
			cpx.w	#$a404
				_ASSERT816 beq, 'PHY (16-bit) failed in extended stack.'
					;PEA has already been checked above
					;check that PEI (dp) works in xstack with page crossing
			ldx.w	#$a5a7
			stx		a0
			pei		(a0)
				plx
			cpx		a0
				_ASSERT816 beq, 'PEI (dp) failed in extended stack.'
					;check that PER works in xstack
			per		per_next
		per_next:
				plx
			cpx.w	#per_next
				_ASSERT816 beq, 'PER failed in extended stack.'
					;restore stack pointer
			lda.b	#1
				xba
			lda.b	emusp
				tcs
					;-----------------------------------------
					;interrupt tests
					;-----------------------------------------
					;check if we can modify the vector area
			lda		romos_ok
		sne:brl	skip_interrupt_tests
					;change vectors
			ldy.w	#$1b
		veccopy_loop:
			lda		NativeVectors,y
			sta		$ffe4,y
				dey
			bpl		veccopy_loop
					;check that BRK calls the native vector and that it sets
					;I=1, D=0.
			lda.b	#0
			sta		int_type
			sta		int_p
				sed
				brk
				nop
				cld
			lda		int_type
			cmp.b	#2
				_ASSERT816 beq, 'BRK native vector was not called.'
			lda		int_p
			and.b	#$0c
			cmp.b	#$04
				_ASSERT816 beq, 'BRK did not change I and D flags correctly.'
					;check the same for COP
			lda.b	#0
			sta		int_type
			sta		int_p
				sed
			cop		#$80
				cld
			lda		int_type
			cmp.b	#1
				_ASSERT816 beq, 'COP native vector was not called.'
			lda		int_p
			and.b	#$0c
			cmp.b	#$04
				_ASSERT816 beq, 'COP did not change I and D flags correctly.'
		skip_interrupt_tests:
					;-----------------------------------------
					;high memory tests (A=8-bit, X/Y = 16-bit)
					;-----------------------------------------
			rep		#$10
			sep		#$20
					;check if we have 24-bit addressing and skip if we don't
			lda		_cpuMode
				dec
			smi
		no_24bit_1:
			jmp		no_24bit
					;check if we have high memory available
			lda		$10000+d0
				inc
			sta		$10000+d0
			cmp		$10000+d0
			bne		no_24bit_1
					;switch data bank to bank $01
			lda.b	#$01
				pha
				plb
				dec
				phb
				pla
			cmp.b	#$01
				_ASSERT816 beq, 'Could not set DBK=$01.'
					;check that dp addressing is still in bank $00
			lda.b	#$a5
			sta.l	d0
				dec
			sta.l	$10000+d0
				inc
			cmp		d0
				_ASSERT816 beq, 'DP addressing did not stay in bank $00.'
					;check that abs addressing is now in bank $01
				dec
			cmp.w	d0
				_ASSERT816 beq, 'Abs addressing did not go to bank $01.'
					;check that stack addressing is still in bank $00
					;pea	$1234		;MADS 1.9.6 misassembles this as PER!
			dta		$f4,a($1234)
				tsx
			ldy		1,x			;Note: This is dp,X, not abs,X.
				plx
			cpy.w	#$1234
				_ASSERT816 beq, 'Stack addressing did not stay in bank $00.'
					;check that d,S still reads from bank 0
				phy
			lda		1,s
				ply
			cmp.b	#$34
				_ASSERT816 beq, 'd,S did not read from bank 0.'
					;check that (d,S),Y can read from bank $01
			ldy.w	#0
				phy
			ldy.w	#d0
			lda		(1,s),y
				ply
			cmp.b	#$a4
				_ASSERT816 beq, '(d,S),Y did not read from bank $01.'
					;reset DBK to $00
			lda.b	#0
			sta		a1
				pha
				plb
					;check that we can index across the 64K boundary with abs,X
			ldx.w	#d0+1
			lda		$ffff,x
			cmp.b	#$a4
				_ASSERT816 beq, 'Abs addressing did not cross banks.'
					;check that we can index across the 64K boundary with (dp),Y
			ldy.w	#$ffff
				phy
			sty		a0
				txy
			lda		(a0),y
			cmp.b	#$a4
				_ASSERT816 beq, '(dp),Y addressing did not cross banks.'
					;check that we can index into bank $01 with (d,S),Y
			cmp.b	(1,s),y
				_ASSERT816 beq, '(d,S),Y addressing did not cross banks.'
					;check that we can index into bank $01 with [dp],Y.
			cmp.b	[a0],y
				_ASSERT816 beq, '[dp],Y addressing did not cross banks.'
					;check that [dp] and [dp],Y can read from bank $01 directly
			ldx.w	#d0
			stx		a0
			lda.b	#1
			sta		a1
			lda		#$a4
			cmp		[a0]
				_ASSERT816 beq, '[dp] addressing did not read bank $01.'
			ldy.w	#0
			cmp		[a0],y
				_ASSERT816 beq, '[dp],Y addressing did not read bank $01.'
					;---------------------------------------------------
					; 16-bit bank crossing tests
					;---------------------------------------------------
					;set DBK=0
			lda.b	#0
				pha
				plb
					;set $10000 to $7c
			lda.b	#$7c
			sta.l	$10000
			lda.b	#$00
			sta.l	$10001
					;switch to 16-bit accumulator, 16-bit indexing
			rep		#$30
					;test direct page read (should NOT cross banks)
			lda.w	#$5555
			sta		0
			ldx.w	#$ffff
			lda.b	0,x
			and.w	#$ff00
			cmp.w	#$5500
				_ASSERT816 beq, 'dp,X 16-bit read should not have crossed banks.'
			ldy.w	#$ffff
			ldx.b	0,y
				txa
			and.w	#$ff00
			cmp.w	#$5500
				_ASSERT816 beq, 'dp,Y 16-bit read should not have crossed banks.'
					;test (dp), (dp,X) and (dp,Y)
			sep		#$20
			lda.b	#$1c
			sta.b	$20
			lda.b	#$35
			sta.w	$120
			lda.b	#$20
			sta.w	$ffff
			ldx.w	#$ffff
			lda.b	(0,x)
				_ASSERT816 beq, '(dp,X) address read should not have crossed banks.'
			ldy.w	#$ffff
				phy
				pld
			ldy.w	#0
			lda.b	(0),y
				_ASSERT816 beq, '(dp),Y address read should not have crossed banks.'
			lda.b	(0)
				_ASSERT816 beq, '(dp) address read should not have crossed banks.'
				phy
				pld
					;test absolute read (should cross banks)
			rep		#$20
			lda.w	$ffff
			and.w	#$ff00
			cmp.w	#$7c00
				_ASSERT816 beq, 'abs 16-bit read did not cross banks.'
					;test absolute long read (should cross banks)
			lda.l	$00ffff
			and.w	#$ff00
			cmp.w	#$7c00
				_ASSERT816 beq, 'long 16-bit read did not cross banks.'
					;---------------------------------------------------
					; high bank code tests
					;---------------------------------------------------
					;switch to 16-bit accumulator and index registers
			rep		#$30
					;copy code up to bank $01 (this also sets DBK=$01)
			lda.w	#[bank01_end-bank01_start-1]
			ldx.w	#bank01_start
				txy
			mvn		0,1
					;check that C is now $FFFF
				tax
			cpx.w	#$ffff
				_ASSERT816 beq, 'C was not $FFFF after MVP.'
					;switch to 8-bit accumulator
			sep		#$20
					;check that DBK is now $01
				phb
				pla
			cmp.b	#1
				_ASSERT816 beq, 'DBK was not $01 after MVP.'
					;check that our code actually made it to Mars safely
			lda		bank01_end-1
			cmp.l	bank01_end-1
				_ASSERT816 beq, 'MVP to bank $01 failed.'
					;set DBK back to 0
			lda.b	#0
				pha
				plb
					;write an sec:rtl pair in bank $01 and try calling it
			lda.b	#$38
			sta.l	SetCarryTest+$010000
			lda.b	#$6b
			sta.l	SetCarryTest+$010001
			jsl		SetCarryTest+$010000
				_ASSERT816 bcs, 'Could not call code in bank $01.'
					;check that PBK is reflected correctly
			jsl		ReadPBK+$10000
			cmp.b	#1
				_ASSERT816 beq, 'PBK!=1 in bank $01.'
					;set DBK to bank $01
			lda.b	#1
				pha
				plb
					;test JMP (abs) in bank $01 (reads from bank $00)
		mva		#4 JmpTest.addval+$10000
	mwa		#JmpTest.pt2 JmpTest.addr+$10000
			jsl		JmpTest+$10000
			cmp.b	#2
				_ASSERT816 beq, 'JMP (abs) failed in bank $01.'
					;set DBK to bank 0
			lda.b	#0
				pha
				plb
					;test JMP (abs,X) in bank $01 (reads from PBR)
		mva		#4 JmpXTest.addval+$10000
	mwa		#JmpXTest.pt2 JmpXTest.addr+$10000
			jsl		JmpXTest+$10000
			cmp.b	#3
				_ASSERT816 beq, 'JMP (abs,X) failed in bank $01.'
					;test JSR (abs,X) in bank $01 (reads from PBR)
		mva		#4 JsrXTest.addval+$10000
	mwa		#JsrXTest.pt2 JsrXTest.addr+$10000
			jsl		JsrXTest+$10000
			cmp.b	#3
				_ASSERT816 beq, 'JSR (abs,X) failed in bank $01.'
					;set DBK to bank 1
			lda.b	#1
				pha
				plb
					;test JMP [abs] with DBK=1 -- should read from bank $00, not PBK or DBK
			lda.b	#$01
				pha
				plb
		mva		#$00 JmpAbsLongTest+$10002
				clc
			jsl		JmpAbsLongTest.dispatch
				_ASSERT816 bcs, 'JMP [abs] failed.'
		no_24bit:
					;all good... go back to emu mode and exit
			sep		#$30
			lda.b	#0
				xba
			lda.b	#0
				tcd
				pha
				plb
				sec
				xce
			bit		_veronica
			bpl		maincpu_ret
			ldy		#0
			jmp		$ffe0
		maincpu_ret:
			jsr		RestoreOS
			jmp		_testPassed
			.endp
		bank01_start:
		.proc SetCarryTest
				clc
				rtl
			.endp
		.proc ReadPBK
				phk
				pla
				rtl
			.endp
			;==========================================================================
			; Exit:
			;	A = $fe		WTF -- didn't hit any of the code.
			;	A = $00		Address read from bank $00, jumped to code in bank $00
			;	A = $01		Address read from bank $01, jumped to code in bank $00
			;	A = $02		Address read from bank $00, jumped to code in bank $01
			;	A = $03		Address read from bank $01, jumped to code in bank $01
			;
			; Remarks:
			;	JMP (abs) reads the jump address from bank 0 and jumps to that address
			;	in the current program bank. Therefore, calling this in bank $01 should
			;	give A=$02.
			;
		.proc JmpTest
			lda.b	#$fe
			jmp		(addr)
		pt2:
				inc
		pt1:
				clc
			adc.b	#2				;patched to 4 in bank $01
		addval = *-1
				rtl
		addr:
			dta		a(pt1)			;patched to pt2 in bank $01
			.endp
			;==========================================================================
			; Exit:
			;	A = $fe		WTF -- didn't hit any of the code.
			;	A = $ff		WTF -- indexing didn't occur.
			;	A = $00		Address read from bank $00, jumped to code in bank $00
			;	A = $01		Address read from bank $01, jumped to code in bank $00
			;	A = $02		Address read from bank $00, jumped to code in bank $01
			;	A = $03		Address read from bank $01, jumped to code in bank $01
			;
			; Remarks:
			;	JMP (abs,X) reads the jump address from the current program bank and
			;	jumps to that address in the current program bank. Therefore, calling
			;	this in bank $01 should give A=$03.
			;
		.proc JmpXTest
			lda.b	#$fe
			ldx.w	#$fffe
			jmp		(addr+2,X)
		pt2:
				inc
		pt1:
				clc
			adc.b	#2				;patched to 4 in bank $01
		addval = *-1
				rtl
		pt3:
			lda.b	#$ff
				rtl
		addr:
			dta		a(pt1)			;patched to pt2 in bank $01
			dta		a(pt3)
			.endp
			;==========================================================================
			; Exit:
			;	A = $fe		WTF -- didn't hit any of the code.
			;	A = $ff		WTF -- indexing didn't occur.
			;	A = $00		Address read from bank $00, jumped to code in bank $00
			;	A = $01		Address read from bank $01, jumped to code in bank $00
			;	A = $02		Address read from bank $00, jumped to code in bank $01
			;	A = $03		Address read from bank $01, jumped to code in bank $01
			;
			; Remarks:
			;	JSR (abs,X) reads the jump address from the current program bank and
			;	jumps to that address in the current program bank. Therefore, calling
			;	this in bank $01 should give A=$03.
			;
		.proc JsrXTest
			lda.b	#$fe
			ldx.w	#$fffe
			jsr		(addr+2,X)
				rtl
		pt2:
				inc
		pt1:
				clc
			adc.b	#2				;patched to 4 in bank $01
		addval = *-1
				rts
		pt3:
			lda.b	#$ff
				rts
		addr:
			dta		a(pt1)			;patched to pt2 in bank $01
			dta		a(pt3)
			.endp
			;==========================================================================
		.proc JmpAbsLongTest
			dta		a(SetCarryTest),$01		;patched to bank $00 in bank $01
		dispatch:
			jmp		[JmpAbsLongTest]		;should read from bank $00
			.endp
		bank01_end:
			;==========================================================================
		.proc NativeCOP
			sep		#$20
				pha
				php
				pla
			sta.l	int_p
			lda		#1
			sta.l	int_type
				pla
				rti
			.endp
		.proc NativeBRK
			sep		#$20
				pha
				php
				pla
			sta.l	int_p
			lda.b	#2
			sta.l	int_type
				pla
				rti
			.endp
		NativeABORT = NativeInterrupt
		NativeNMI = NativeInterrupt
		NativeIRQ = NativeInterrupt
		.proc NativeInterrupt
			sep		#$20
				pha
			lda.b	#$80
			sta.l	int_type
				pla
				rtl
			.endp
		EmuNMI = EmuInterrupt
		EmuRESET = EmuInterrupt
		EmuIRQ = EmuInterrupt
		.proc EmuInterrupt
				pha
			lda.b	#$80
			sta.l	int_type
				pla
				rti
			.endp
			;==========================================================================
		.proc NativeVectors
			dta		a(NativeCOP)
			dta		a(NativeBRK)
			dta		a(NativeABORT)
			dta		a(NativeNMI)
			dta		a(0)
			dta		a(NativeIRQ)
			dta		a(0)
			dta		a(0)
			dta		a(0)
			dta		a(0)
			dta		a(0)
			dta		a(EmuNMI)
			dta		a(EmuRESET)
			dta		a(EmuIRQ)
			.endp
			;==========================================================================
		.proc RestoreOS
					;restore vector area
			lda		switched_os
			beq		postos
			ldx		#31
	mva:rpl	romsave,x $ffe0,x-
		postos:
					;restore PIA state
			lda		switched_pia
			beq		postpia
			ldx		#$38
			ldy		#$3c
			stx		pbctl
		mva		#$ff portb
			sty		pbctl
		mva		save_orb portb
			stx		pbctl
		mva		save_ddrb portb
		mva		save_crb portb
		postpia:
					;restore OS zero page and low satck
			lda		switched_zp
			beq		postzp
			ldx		#$7f
		restorezp_loop:
		mva		oszpsave,x 0,x
		mva		stksave $100,x
				dex
			bpl		restorezp_loop
		postzp:
				rts
			.endp
			;==========================================================================
		.proc FailTest816
					;okay, let's get this thing back to home base -- first, go to 8-bit
					;registers.
			sep		#$30
					;restore direct page
			lda.b	#0
				xba
			lda.b	#0
				tcd
					;pull the return address (for the message)
				plx
				ply
					;restore the stack
			lda.b		#1
				xba
			lda.l	emusp
				tcs
					;put the return address back
				phy
				phx
					;restore data bank
			lda.b	#0
				pha
				plb
					;jump to emulation mode
				sec
				xce
					;check if we're on Veronica
			bit		_veronica
			bpl		maincpu_ret
					;load message address - 1 to A:X
				plx
				pla
			ldy		#$80
			jmp		$ffe0
		maincpu_ret:
					;restore the RAM OS, if there is one
			jsr		RestoreOS
					;fail
			jmp		_testFailed
			.endp
		vercopy_end:
			run		main
					end
