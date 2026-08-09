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
				_SAP_HEADER "GTIA: Player overlap"
					opt		h+o+
					icl		'library.s'
		passidx	equ		$80
		scanpos	equ		$81
				org		$2000
		main:
				_INITTEST	c"GTIA: Player overlap"
			jsr		_screenOff
			jsr		_interruptsOff
		mva		#$00 gractl
		mva		#$aa grafm
		mva		#$80 hposp0
		mva		#$00 sizem
		mva		#$08 colpm0
		mva		#$28 colpm1
		mva		#$18 prior
			mva		#0 passidx
		pass_loop:
			ldx		passidx
		mva		pass_data_hposm0_start,x scanpos
		mva		pass_data_sizep0,x sizep0
		mva		pass_data_lo,x scan_addr
		mva		pass_data_hi,x scan_addr+1
					;wait for start of visible region
		render_loop:
			lda		#16
		render_ypos = *-1
		cmp:req	vcount
		cmp:rne	vcount
			add		#32
			cmp		#16+32*3
			sne:lda	#16
			sta		render_ypos
		mva		#$81 grafp0
		mva		#$60 hposp0
			ldx		scanpos
			stx		hposm0
				inx
			stx		hposm1
				inx
			stx		hposm2
				inx
			stx		hposm3
			ldx		#<shift4
			ldy		#$f0
			lda		#4
			bit		scanpos
			beq		even
			ldx		#<noshift
			ldy		#$0f
		even:
			stx		shift_table_addr
			sty		compare_mask
			jsr		do_scan
			sta		wsync
		mva		#0 grafp0
			lda		scanpos
			eor		#4
			sta		scanpos
			and		#4
		seq:jmp	render_loop
			ldx		passidx
				inx
			stx		passidx
			cpx		#12
		seq:jmp	pass_loop
			jmp		_testPassed
			;==========================================================================
				org		$2200
		do_scan:
					;We currently skip the first four test lines (start at $64 instead
					;of $60) to avoid tripping on a one-cycle delta in HPOSPx deadline
					;on different machines.
			ldy		#$64
			sta		wsync
			sta		wsync
					;equalize entry with loop exit-entry path
			pha:pla					;7
			bit		$0100			;4
		scan_loop:
			lda		#$60
			sta		hposp0
			sta		hitclr
			bit		$00
				nop
				nop
				tya
			eor		#$60
				tax
			lda		$0100,x			;4
		scan_addr = *-2
				tax						;2
			and		#0
		compare_mask = *-1
			sta		compare_val		;2
				nop
			sty		hposp0
			jsr		delay12			;12
			bit		$0100			;4
				nop
				nop
			lda		m0pl			;4
				asl						;2
			ora		m1pl			;4
				asl						;2
			ora		m2pl			;4
				asl						;2
			ora		m3pl			;4
				tax						;2
			lda		noshift,x		;4
		shift_table_addr = *-2
			sta		wsync
			cmp		#0				;2
		compare_val = *-1
			bne		fail			;2
				iny						;2
			cpy		#$80			;2
			bne		scan_loop		;3
				rts
		fail:
			sta		d5
		mva		compare_val d4
			sty		d3
			lda		scanpos
			and		#4
				lsr
				lsr
			sta		d2
			mva		passidx d1
				_FAIL	c"Pass %d.%d: Pos=%x, Expected %x, Got %x"
		delay48:
			jsr		delay24
		delay24:
			jsr		delay12
		delay12:
				rts
			;==========================================================================
				org		$3000
				.pages 1
		wide_data_1:
			dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11111110
				dta		%11111111
				dta		%11110111
				dta		%11110011
				dta		%11110001
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
				dta		%11110000
		wide_data_2:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%10000000
				dta		%11000000
				dta		%11100000
				dta		%11110000
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%00000111
				dta		%00000011
				dta		%00000001
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
		wide_data_3:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%10000000
				dta		%11000000
				dta		%11100000
				dta		%11110000
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%00000111
				dta		%00000011
				dta		%00000001
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
		wide_data_4:
				dta		%00001111
				dta		%00001111
				dta		%00001111
				dta		%00011111
				dta		%00001111
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%11111000
				dta		%11111100
				dta		%11111110
				dta		%11111111
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%00001111
				dta		%00001111
				dta		%00001111
		wide_data_5:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%11100000
				dta		%11110000
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%00000111
				dta		%00000011
				dta		%00000001
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%10000000
				dta		%11000000
				dta		%11100000
		wide_data_6:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%10000000
				dta		%11000000
				dta		%11100000
				dta		%11110000
				dta		%01111000
				dta		%00111100
				dta		%00011110
				dta		%00001111
				dta		%00000111
				dta		%00000011
				dta		%00000001
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
		double_data_1:
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11011000
				dta		%11001100
				dta		%11000110
				dta		%11000011
				dta		%11000001
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
				dta		%11000000
		double_data_2:
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000110
				dta		%00000011
				dta		%00000110
				dta		%00000011
				dta		%10000110
				dta		%11000011
				dta		%01100110
				dta		%00110011
				dta		%00011110
				dta		%00001111
				dta		%00000110
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				dta		%00000011
				.endpg
				.pages 1
		double_data_3:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%01100000
				dta		%00110000
				dta		%00011000
				dta		%00001100
				dta		%00000110
				dta		%00000011
				dta		%00000001
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%10000000
				dta		%11000000
				dta		%01100000
				dta		%00110000
				dta		%00011000
				dta		%00001100
				dta		%00000110
				dta		%00000011
				dta		%00000001
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
		double_data_4:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%10000000
				dta		%11000000
				dta		%01100000
				dta		%00110000
				dta		%00011000
				dta		%00001100
				dta		%00000110
				dta		%00000011
				dta		%00000001
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%10000000
				dta		%11000000
				dta		%01100000
				dta		%00110000
				dta		%00011000
				dta		%00001100
				dta		%00000110
				dta		%00000011
				dta		%00000001
		normal_data_1:
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10010001
				dta		%10001001
				dta		%10000101
				dta		%10000011
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
				dta		%10000001
		normal_data_2:
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00100000
				dta		%00010000
				dta		%00001000
				dta		%00000100
				dta		%00000010
				dta		%10000001
				dta		%01000000
				dta		%00100000
				dta		%00010000
				dta		%00001000
				dta		%00000100
				dta		%00000010
				dta		%00000001
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				dta		%00000000
				.endpg
			;==========================================================================
				org		$3200
				.pages 2
		noshift:
	:16 dta #
		shift4:
	:16 dta #*16
				.endpg
			;==========================================================================
		pass_data_lo:
				dta		<wide_data_1
				dta		<wide_data_2
				dta		<wide_data_3
				dta		<wide_data_4
				dta		<wide_data_5
				dta		<wide_data_6
				dta		<double_data_1
				dta		<double_data_2
				dta		<double_data_3
				dta		<double_data_4
				dta		<normal_data_1
				dta		<normal_data_2
		pass_data_hi:
				dta		>wide_data_1
				dta		>wide_data_2
				dta		>wide_data_3
				dta		>wide_data_4
				dta		>wide_data_5
				dta		>wide_data_6
				dta		>double_data_1
				dta		>double_data_2
				dta		>double_data_3
				dta		>double_data_4
				dta		>normal_data_1
				dta		>normal_data_2
		pass_data_hposm0_start:
		dta		$60,$68,$70,$78,$80,$88
			dta		$60,$68,$70,$78
			dta		$60,$68
		pass_data_sizep0:
		dta		$03,$03,$03,$03,$03,$03
			dta		$01,$01,$01,$01
			dta		$00,$00
			;==========================================================================
			run		$2000
					end
