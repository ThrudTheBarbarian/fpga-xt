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
				_SAP_HEADER "CPU: Timing"
					opt		h+o+
					icl		'library.s'
					opt		o-
				icl		'options.s'
					opt		o+
		insn_cnt = $80
		cycles = $81
		test_ptr = $82
				org		$2000
		main:
				_INITTEST	c"CPU: Illegal insn timing"
			lda		opt_noillinsn
			beq		illok
				_SKIP	c"Illegal instructions option disabled."
		illok:
					;skip if we're running on a CMOS CPU
			lda		_cpuMode
			beq		is6502
				_SKIP	c"65C02/65C816 detected."
		is6502:
			jsr		_screenOff
			jsr		_interruptsOff
	mwa		#test_start test_ptr
					;setup temp registers
	mwa		#d5 a1
	mwa		#d4 a2
	mwa		#d5-$ff a3
		test_loop:
					;fetch opcode
			ldy		#0
			lda		(test_ptr),y
			bne		opcode_valid
					;$00 = we're done
			jmp		_testPassed
		opcode_valid:
					;copy instruction to test loop
			sta		insn+0
				iny
			lda		(test_ptr),y
			sta		insn+1
				iny
			lda		(test_ptr),y
			sta		insn+2
					;load X
				iny
			lda		(test_ptr),y
				tax
					;save off value for Y
				iny
			lda		(test_ptr),y
				pha
					;load M (d5)
				iny
			lda		(test_ptr),y
			sta		d5
					;load Y
				pla
				tay
					;set loop counter (228 cycles - 18 refresh cycles)
			lda		#210
			sta		insn_cnt
					;sync and delay to mid-scanline for some safety margin
			inc		wsync
			jsr		delay48
					;load A and wait for vcount=0
		lda:rne	vcount
					;execute insn 210 times
		insn_loop:
		insn:
				nop
				nop
				nop
			dec		insn_cnt
			bne		insn
					;capture vcount and compute cycle count
			lda		vcount
				sec
			sbc		#8
			ldy		#7
			sbc		(test_ptr),y
			sta		cycles
					;check if cycle count is correct
				dey
			cmp		(test_ptr),y
			bne		cycles_incorrect
					;looks good, advance to next
			lda		#8-1
			adc		test_ptr			;!! - c=1
			sta		test_ptr
			scc:inc	test_ptr+1
			jmp		test_loop
		cycles_incorrect:
		mva		insn d1
		mva		insn+1 d2
		mva		insn+2 d3
			jsr		_imprintf
		dta		'FAIL.',$9b
	dta		'Insn: %x %x %x',$9b,0
			ldy		#3
		mva		(test_ptr),y+ d1
		mva		(test_ptr),y+ d2
		mva		(test_ptr),y+ d3
			jsr		_imprintf
	dta		'Regs: X=%x Y=%x M=%x',$9b,0
			mva		cycles d2
			ldy		#6
			mva		(test_ptr),y d1
			jsr		_testFailed2
	dta		'Cycles: expected=%d, actual=%d',$9b,0
		delay48:
			jsr		delay24
		delay24:
			jsr		delay12
		delay12:
				rts
			;Test memory vars:
			;
			;	d5 = M
			;	a1 = &d5
			;	a2 = &d4
			;	a3 = &d5-$ff
	w5 = d5-$ff			;wraps around 64K, but that's fine, this test can't run on a 65816
		test_start:
					;       insn				 X   Y   M  cy xc
	dta		$03,<a0,$ea,		$02,$00,$81, 8,2	;SLO (zp,X) (ASL + ORA)
	dta		$04,<d5,$ea,		$00,$00,$00, 3,2	;NOP zp
	dta		$07,<d5,$ea,		$00,$00,$81, 5,2	;SLO zp (ASL + ORA)
	dta		$0b,$00,$ea,		$00,$00,$00, 2,2	;AAC #imm (modified AND)
	dta		$0c,<d5,>d5,		$00,$00,$00, 4,0	;NOP abs
	dta		$0f,<d5,>d5,		$00,$00,$81, 6,0	;SLO abs (ASL + ORA)
	dta		$13,<a2,$ea,		$00,$01,$81, 8,2	;SLO (zp),Y (ASL + ORA)
	dta		$13,<a2,$ea,		$00,$FF,$81, 8,2	;SLO (zp),Y (ASL + ORA)
	dta		$14,<d5,$ea,		$00,$00,$00, 4,2	;NOP zp,X
	dta		$17,<d4,$ea,		$01,$00,$81, 6,2	;SLO zp,X (ASL + ORA)
	dta		$1A,$ea,$ea,		$00,$00,$00, 2,4	;NOP
	dta		$1B,<d2,>d2,		$00,$03,$81, 7,0	;SLO abs,Y (ASL + ORA)
	dta		$1B,<w5,>w5,		$00,$FF,$81, 7,0	;SLO abs,Y (ASL + ORA)
	dta		$1C,<d5,>d5,		$00,$00,$00, 4,0	;NOP abs,X
	dta		$1C,<w5,>w5,		$FF,$00,$00, 5,0	;NOP abs,X
	dta		$1F,<d3,>d3,		$02,$03,$81, 7,0	;SLO abs,X (ASL + ORA)
	dta		$1F,<w5,>w5,		$FF,$03,$81, 7,0	;SLO abs,X (ASL + ORA)
	dta		$23,<a0,$ea,		$02,$00,$81, 8,2	;RLA (zp,X) (ROL + AND)
	dta		$27,<d5,$ea,		$00,$00,$81, 5,2	;RLA zp (ROL + AND)
	dta		$2F,<d5,>d5,		$00,$00,$81, 6,0	;RLA abs (ROL + AND)
	dta		$33,<a2,$ea,		$00,$01,$81, 8,2	;RLA (zp),Y (ROL + AND)
	dta		$33,<a3,$ea,		$00,$FF,$81, 8,2	;RLA (zp),Y (ROL + AND)
	dta		$34,<d5,$ea,		$00,$00,$00, 4,2	;NOP zp,X
	dta		$37,<d4,$ea,		$01,$00,$81, 6,2	;RLA zp,X (ROL + AND)
	dta		$3A,$ea,$ea,		$00,$00,$00, 2,4	;NOP
	dta		$3B,<d4,>d4,		$00,$01,$81, 7,0	;RLA abs,Y (ROL + AND)
	dta		$3B,<w5,>w5,		$00,$FF,$81, 7,0	;RLA abs,Y (ROL + AND)
	dta		$3C,<d5,>d5,		$00,$00,$00, 4,0	;NOP abs,X
	dta		$3C,<w5,>w5,		$FF,$00,$00, 5,0	;NOP abs,X
	dta		$3F,<d4,>d4,		$01,$00,$81, 7,0	;RLA abs,X (ROL + AND)
	dta		$3F,<w5,>w5,		$FF,$00,$81, 7,0	;RLA abs,X (ROL + AND)
	dta		$43,<a0,$ea,		$02,$00,$55, 8,2	;SRE (zp,X) (LSR + EOR)
	dta		$44,<d5,$ea,		$00,$00,$00, 3,2	;NOP zp
	dta		$47,<d5,$ea,		$00,$00,$55, 5,2	;SRE zp (LSR + EOR)
	dta		$4B,$55,$ea,		$00,$00,$55, 2,2	;ASR #imm (AND + LSR)
	dta		$4F,<d5,>d5,		$00,$00,$55, 6,0	;SRE abs (LSR + EOR)
	dta		$53,<a2,$ea,		$00,$01,$55, 8,2	;SRE (zp),Y (LSR + EOR)
	dta		$53,<a3,$ea,		$00,$FF,$55, 8,2	;SRE (zp),Y (LSR + EOR)
	dta		$54,<d5,$ea,		$00,$00,$00, 4,2	;NOP zp,X
	dta		$57,<d2,$ea,		$03,$00,$55, 6,2	;SRE zp,X (LSR + EOR)
	dta		$5A,$ea,$ea,		$00,$00,$00, 2,4	;NOP
	dta		$5B,<d1,>d1,		$00,$04,$55, 7,0	;SRE abs,Y (LSR + EOR)
	dta		$5B,<w5,>w5,		$00,$FF,$55, 7,0	;SRE abs,Y (LSR + EOR)
	dta		$5C,<d5,>d5,		$00,$00,$00, 4,0	;NOP abs,X
	dta		$5C,<w5,>w5,		$FF,$00,$00, 5,0	;NOP abs,X
	dta		$5F,<d1,>d1,		$04,$00,$55, 7,0	;SRE abs,X (LSR + EOR)
	dta		$5F,<w5,>w5,		$FF,$00,$55, 7,0	;SRE abs,X (LSR + EOR)
	dta		$63,<a0,$ea,		$02,$00,$01, 8,2	;RRA (zp,X) (ROR + ADC)
	dta		$64,<d5,$ea,		$00,$00,$00, 3,2	;NOP zp
	dta		$67,<d5,$ea,		$00,$00,$01, 5,2	;RRA zp (ROR + ADC)
	dta		$6B,$2a,$ea,		$00,$00,$01, 2,2	;ARR #imm (AND + ROR + N/V fiddling)
	dta		$6F,<d5,>d5,		$00,$00,$01, 6,0	;RRA abs (ROR + ADC)
	dta		$73,<a2,$ea,		$00,$01,$01, 8,2	;RRA (zp),Y (ROR + ADC)
	dta		$73,<a3,$ea,		$00,$FF,$01, 8,2	;RRA (zp),Y (ROR + ADC)
	dta		$74,<d5,$ea,		$00,$00,$00, 4,2	;NOP zp,X
	dta		$77,<d4,$ea,		$01,$00,$01, 6,2	;RRA zp,X (ROR + ADC)
	dta		$7A,$ea,$ea,		$00,$00,$00, 2,4	;NOP
	dta		$7B,<d4,>d4,		$00,$01,$01, 7,0	;RRA abs,Y (ROR + ADC)
	dta		$7B,<w5,>w5,		$00,$FF,$01, 7,0	;RRA abs,Y (ROR + ADC)
	dta		$7C,<d5,>d5,		$00,$00,$00, 4,0	;NOP abs,X
	dta		$7C,<w5,>w5,		$FF,$00,$00, 5,0	;NOP abs,X
	dta		$7F,<d4,>d4,		$01,$00,$01, 7,0	;RRA abs,X (ROR + ADC)
	dta		$7F,<w5,>w5,		$FF,$00,$01, 7,0	;RRA abs,X (ROR + ADC)
	dta		$80,$00,$ea,		$00,$00,$00, 2,2	;NOP #imm
	dta		$82,$00,$ea,		$00,$00,$00, 2,2	;NOP #imm
	dta		$83,<(a1-$ff),$ea,	$ff,$00,$00, 6,2	;SAX (zp,X) (store A&X)
	dta		$87,<d5,$ea,		$ff,$00,$00, 3,2	;SAX zp (store A&X)
	dta		$8F,<d5,>d5,		$ff,$00,$00, 4,0	;SAX abs (store A&X)
	dta		$89,$00,$ea,		$00,$00,$00, 2,2	;NOP #imm
	dta		$97,<d4,$ea,		$ff,$01,$00, 4,2	;SAX zp,Y (store A&X)
	dta		$9C,<d3,>d3,		$02,$00,$aa, 5,0	;SHY abs,X
	dta		$9C,<w5,>w5,		$FF,$00,$aa, 5,0	;SHY abs,X
	dta		$9E,<d3,>d3,		$00,$02,$aa, 5,0	;SHX abs,Y
	dta		$9E,<w5,>w5,		$00,$FF,$aa, 5,0	;SHX abs,Y
	dta		$A3,<a0,$ea,		$02,$00,$00, 6,2	;LAX (zp,X) (load A&X)
	dta		$A7,<d5,$ea,		$55,$00,$00, 3,2	;LAX zp (load A&X)
	dta		$AF,<d5,>d5,		$55,$00,$00, 4,0	;LAX abs (load A&X)
	dta		$B3,<a2,$ea,		$55,$01,$00, 5,2	;LAX (zp),Y (load A&X)
	dta		$B3,<a3,$ea,		$55,$FF,$00, 6,2	;LAX (zp),Y (load A&X)
	dta		$B7,<d3,$ea,		$55,$02,$00, 4,2	;LAX zp,Y (load A&X)
	dta		$BF,<d4,>d4,		$55,$01,$00, 4,0	;LAX abs,Y (load A&X)
	dta		$BF,<w5,>w5,		$55,$FF,$00, 5,0	;LAX abs,Y (load A&X)
	dta		$C2,$00,$ea,		$00,$00,$00, 2,2	;NOP #imm
	dta		$C3,<a0,$ea,		$02,$00,$01, 8,2	;DCP (zp,X) (DEC + CMP)
	dta		$C7,<d5,$ea,		$55,$00,$01, 5,2	;DCP zp (DEC + CMP)
	dta		$CB,$00,$ea,		$ff,$00,$01, 2,2	;SBX #imm (A&X -> X, X-imm -> X)
	dta		$CF,<d5,>d5,		$55,$00,$01, 6,0	;DCP abs (DEC + CMP)
	dta		$D3,<a2,$ea,		$55,$01,$01, 8,2	;DCP (zp),Y (DEC + CMP)
	dta		$D3,<a3,$ea,		$55,$FF,$01, 8,2	;DCP (zp),Y (DEC + CMP)
	dta		$D4,<d5,$ea,		$00,$00,$00, 4,2	;NOP zp,X
	dta		$D7,<d3,$ea,		$02,$00,$01, 6,2	;DCP zp,X (DEC + CMP)
	dta		$DA,$ea,$ea,		$00,$00,$00, 2,4	;NOP
	dta		$DB,<d4,>d4,		$55,$01,$01, 7,0	;DCP abs,Y (DEC + CMP)
	dta		$DB,<w5,>w5,		$55,$FF,$01, 7,0	;DCP abs,Y (DEC + CMP)
	dta		$DC,<d5,>d5,		$00,$00,$00, 4,0	;NOP abs,X
	dta		$DC,<w5,>w5,		$FF,$00,$00, 5,0	;NOP abs,X
	dta		$DF,<d4,>d4,		$01,$55,$01, 7,0	;DCP abs,X (DEC + CMP)
	dta		$DF,<w5,>w5,		$FF,$55,$01, 7,0	;DCP abs,X (DEC + CMP)
	dta		$E2,$00,$ea,		$00,$00,$00, 2,2	;NOP #imm
	dta		$E3,<a0,$ea,		$02,$00,$00, 8,2	;ISB (zp,X) (INC + SBC)
	dta		$E7,<d5,$ea,		$00,$00,$00, 5,2	;ISB zp (INC + SBC)
	dta		$EB,$00,$ea,		$00,$00,$00, 2,2	;SBC #imm
	dta		$EF,<d5,>d5,		$00,$00,$00, 6,0	;ISB abs (INC + SBC)
	dta		$F3,<a2,$ea,		$02,$01,$00, 8,2	;ISB (zp),Y (INC + SBC)
	dta		$F3,<a3,$ea,		$02,$FF,$00, 8,2	;ISB (zp),Y (INC + SBC)
	dta		$F4,<d5,$ea,		$00,$00,$00, 4,2	;NOP zp,X
	dta		$F7,<d3,$ea,		$02,$00,$00, 6,2	;ISB zp,X (INC + SBC)
	dta		$FA,$ea,$ea,		$00,$00,$00, 2,4	;NOP
	dta		$FB,<d3,>d3,		$00,$02,$00, 7,0	;ISB abs,Y (INC + SBC)
	dta		$FB,<w5,>w5,		$00,$FF,$00, 7,0	;ISB abs,Y (INC + SBC)
	dta		$FC,<d5,>d5,		$00,$00,$00, 4,0	;NOP abs,X
	dta		$FC,<w5,>w5,		$FF,$00,$00, 5,0	;NOP abs,X
	dta		$FF,<d3,>d3,		$02,$00,$00, 7,0	;ISB abs,X (INC + SBC)
	dta		$FF,<w5,>w5,		$FF,$00,$00, 7,0	;ISB abs,X (INC + SBC)
				dta		$00
		test_end:
			run		$2000
					end
