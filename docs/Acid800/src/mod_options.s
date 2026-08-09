			; Altirra Acid800 test suite
			; Copyright (C) 2010-2020 Avery Lee, All Rights Reserved.
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
				MOD_COL80 = 2
				MOD_VBXE80 = 3
				MOD_SCROLL40 = 4
				MOD_VERONICA = 5
					opt		o-
				icl		'options.s'
					opt		o+
				org		$3800
		.proc main
		loop:
		jsr		showMenu
			jsr		_imprint
					.ifdef SYS5200
					dta		c"Acid5200> ",0
					.else
	dta		c"Acid800> ",0
					.endif
		waitkey:
					.ifdef SYS5200
					mva		#$ff ch
					lda:rmi	ch
					.else
			lda		#0
			sta		ch
			sta		ch1
		lda:req	ch
					.endif
					.ifdef SYS5200
					cmp		#$01		;1
					beq		overridecpu
					cmp		#$02		;2
					beq		togglewaitfail
					cmp		#$03		;3
					beq		toggleillegal
					cmp		#$04		;4
					beq		togglewait
					cmp		#$00		;5
					bne		waitkey
					.else
			cmp		#$12		;C
			beq		overridecpu
			cmp		#$38		;F
			beq		togglewaitfail
			cmp		#$0d		;I
			beq		toggleillegal
			cmp		#$2e		;W
			beq		togglewait
			cmp		#$3f		;A
			beq		load80
			cmp		#$15		;B
			beq		loadv80
			cmp		#$3e		;S
		sne:jmp	loads40
			cmp		#$10		;V
		sne:jmp	toggleveronica
			cmp		#$16		;X
			bne		waitkey
					.endif
				rts
		toggleillegal:
			lda		opt_noillinsn
			eor		#$ff
			sta		opt_noillinsn
			jmp		loop
		togglewaitfail:
			lda		opt_waitfail
			eor		#$ff
			sta		opt_waitfail
			jmp		loop
		togglewait:
			lda		opt_wait
			eor		#$ff
			sta		opt_wait
			jmp		loop
		overridecpu:
			lda		_cpuMode
			ora		#$7e
				clc
			adc		#1
			and		#$81
			sta		_cpuMode
			jmp		loop
					.ifdef SYS800
		load80:
			jsr		resetDisplay
			jsr		_imprint
	dta		$9c,c"Loading 80-column handler...",$9b,0
			ldx		#MOD_COL80
			jsr		_loadSeg
			jsr		_runSeg
			jmp		loop
		loadv80:
			jsr		resetDisplay
			jsr		_imprint
	dta		$9c,c"Loading VBXE 80-column handler...",$9b,0
			ldx		#MOD_VBXE80
			jsr		_loadSeg
			jsr		_runSeg
			jmp		loop
		loads40:
			jsr		resetDisplay
			jsr		_imprint
	dta		$9c,c"Loading scrolling 40-column handler...",$9b,0
			ldx		#MOD_SCROLL40
			jsr		_loadSeg
			jsr		_runSeg
			jmp		loop
		toggleveronica:
			lda		_veronica
			beq		load_veronica
			inc		_veronica
			jmp		loop
		load_veronica:
			jsr		_imprint
	dta		$9c,'Loading Veronica module...',$9b,0
			ldx		#MOD_VERONICA
			jsr		_loadSeg
			jsr		_runSeg
			jmp		loop
					.endif
			.endp
			;=========================================================================
			.ifdef SYS800
		.proc resetDisplay
					;check if display is hooked
			lda		_vputunhook+1
			sne:rts
					;reset ANTIC and GTIA
			lda		#0
			sta		sdmctl
			sta		dmactl
			sta		nmien
				tax
		clear_loop:
			sta		$d000,x
				inx
			bne		clear_loop
					;call unhook
			jsr		unhook
			lda		#0
			sta		_vputunhook+1
					;reinit gr.0 screen
		mva		#$0c iccmd
			ldx		#0
			jsr		ciov
		mva		#$03 iccmd
	mwa		#ename icbal
		mva		#$0c icax1
			ldx		#0
			jsr		ciov
	mwa		icptl _vputchar
	inw		_vputchar
				rts
		ename:
			dta		c"E:",$9B
		unhook:
			jmp		(_vputunhook)
			.endp
			.endif
			;=========================================================================
		.proc showMenu
			jsr		_imprint
				dta		$7d
					.ifdef SYS5200
					dta		c"Altirra Acid5200 test options",$9b
					dta		$9b
					.else
	dta		c"Altirra Acid800 test options",$9b
				dta		$9b
	dta		c"A - Load standard 80-column handler",$9b
	dta		c"B - Load VBXE 80-column handler",$9b
	dta		c"S - Load scrolling 40-column handler",$9b
					.endif
				dta		0
			ldx		_cpuMode
			bpl		not65c816
	mwa		#str65C816_16 d1
				dex
			bpl		postcpu
	mwa		#str65C816_24 d1
			jmp		postcpu
		not65c816:
			beq		not65C02
	mwa		#str65C02 d1
			jmp		postcpu
		not65C02:
	mwa		#str6502 d1
		postcpu:
			jsr		_imprintf
					.ifdef SYS5200
					dta		c"1 - Change detected CPU: %s",$9b,0
					.else
	dta		c"C - Change detected CPU: %s",$9b,0
					.endif
					.ifdef SYS800
			lda		_veronica
			jsr		setonoff
			jsr		_imprintf
	dta		c"V - Use Veronica for 816: %s",$9b,0
					.endif
			lda		opt_waitfail
			jsr		setonoff
			jsr		_imprintf
					.ifdef SYS5200
					dta		c"2 - Wait after test failure: %s",$9b,0
					.else
	dta		c"F - Wait after test failure: %s",$9b,0
					.endif
			lda		opt_noillinsn
			eor		#$ff
			jsr		setonoff
			jsr		_imprintf
					.ifdef SYS5200
					dta		c"3 - Allow illegal instructions: %s",$9b,0
					.else
	dta		c"I - Allow illegal instructions: %s",$9b,0
					.endif
			lda		opt_wait
			jsr		setonoff
			jsr		_imprintf
					.ifdef SYS5200
					dta		c"4 - Wait after each test: %s",$9b,0
					.else
	dta		c"W - Wait after each test: %s",$9b,0
					.endif
			jsr		_imprint
					.ifdef SYS5200
					dta		c"0 - Exit and run tests",$9b
					.else
	dta		c"X - Exit and run tests",$9b
					.endif
				dta		$9b
				dta		0
				rts
		setonoff:
			bpl		isoff
	mwa		#on d1
				rts
		isoff:
	mwa		#off d1
				rts
	on		dta		c"ON",0
	off		dta		c"OFF",0
		str6502:
		dta		c"6502",0
		str65C02:
		dta		c"65C02",0
		str65C816_16:
	dta		c"65C816[16]",0
		str65C816_24:
	dta		c"65C816[24]",0
			.endp
			;=========================================================================
					.if * > $4000
					.error "Segment too large"
					.endif
			run		main
					end
