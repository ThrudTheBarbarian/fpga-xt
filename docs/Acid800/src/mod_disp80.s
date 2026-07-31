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
					opt		h+o+
					icl		'library.s'
				org		$e0
	row		dta		0
		col		dta		0
	rowptr1	dta		a(0)
	rowptr2	dta		a(0)
	chaddr	dta		a(0)
		cha		dta		0
		chb		dta		0
		rowcntr	dta		0
		mask	dta		0
			;========================== NON-RESIDENT SECTION ==========================
				org		$2000
		.proc main
					;check if we have a cartridge
		lda		$a000
				tax
			eor		#$ff
			sta		$a000
			cmp		$a000
			stx		$a000
			beq		mem_ok
					;check if we have an XL or newer
			lda		$fcd8
			cmp		#$a2
		sne:jmp	damn_cart
					;check if BASIC is enabled
			lda		basicf
		seq:jmp	damn_cart
					;see if we can disable basic
			lda		pbctl
				tax
			and		#$fb			;switch to DDR
			sta		pbctl
			lda		portb			;read DDR
			and		#$02			;test BASIC bit
			beq		damn_cart_pbres	;set to input, so can't be BASIC
				txa
			ora		#$04			;switch to IOR
			sta		pbctl
			lda		portb			;read IOR
			and		#$02			;test BASIC bit
			bne		damn_cart_pbres	;set to high, so can't be BASIC
			lda		portb			;read IOR
			ora		#$02			;clear BASIC bit (enable BASIC)
			sta		portb
				txa
			and		#$fb			;switch to DDR
			sta		pbctl
			lda		portb			;read DDR
			ora		#$02			;enable BASIC bit for output
			sta		portb
			stx		pbctl			;restore control mode
		mva		#$ff basicf		;mark basic as not enabled in OS
			jmp		main			;restart
		mem_ok:
					;create new display list and clear screen memory
			jsr		rewriteDisplayList
			jsr		clearScreen
					;swap in new display list
				sei
	mwa		#dlist1 sdlstl
	mwa		#vbiHandler vvblkd
				cli
					;wait for vertical blank
			jsr		_waitVBL
					;init params
			mva		#0 row
			mva		#2 col
			jsr		recompRowAddr
					;replace putchar vector
	mwa		#putchar80 _vputchar
	mwa		#unhook80 _vputunhook
				rts
		damn_cart_pbres:
			stx		pbctl
		damn_cart:
			jsr		_imprint
	dta		c"Cannot enter 80 column mode because a cartridge is present or there is no memory at $A000-BFFF.",$9B,0
			jmp		_waitKeyPrompt
			.endp
			;============================ RESIDENT SECTION ============================
				org		$9000
		.proc	unhook80
			sei
	mwa		#xitvbv vvblkd
				cli
				rts
			.endp
		.proc	putchar80
			sta		cha
				tya
				pha
			jsr		toggleCursor80
			lda		cha
					;check for newline
			cmp		#$9b
			beq		newline
					;check for clear line
			cmp		#$9c
			beq		isclearline
					;check for clear screen
			cmp		#$7d
			beq		isclearscrn
					;draw raw character
			jsr		putraw80
					;update position and exit
			inc		col
			lda		col
			cmp		#78
			bcs		newline
		alldone:
			jsr		toggleCursor80
				pla
				tay
				rts
		isclearscrn:
			jsr		clearScreen
			mva		#0 row
			mva		#2 col
			jsr		recompRowAddr
			jmp		alldone
		isclearline:
			jsr		clearLine
			jmp		alldone
		newline:
					;reset X position
			mva		#2 col
					;increment Y position
			inc		row
					;check if we've gone over
			lda		row
			cmp		#24
			bcc		noscroll
					;whoops... looks like we'll have to scroll
			mva		#23 row
			jsr		scroll80
		noscroll:
			jsr		recompRowAddr
			jmp		alldone
			.endp
			;==========================================================================
		.proc	clearLine
			lda		#0
			ldx		#8
		xloop:
			ldy		#40
		yloop:
			sta		(rowptr1),y
			sta		(rowptr2),y
				dey
			bne		yloop
			inc		rowptr1+1
			inc		rowptr2+1
				dex
			bne		xloop
			mva		#2 col
			jmp		recompRowAddr
			.endp
			;==========================================================================
		.proc	scroll80
					;rotate row lines
			lda		rowaddrlo
				pha
			lda		rowaddrhi
				pha
			ldx		#$e9
		shiftloop:
			lda		rowaddrlo-$e8,x
			sta		rowaddrlo-$e9,x
			lda		rowaddrhi-$e8,x
			sta		rowaddrhi-$e9,x
				inx
			bne		shiftloop
				pla
			sta		rowaddrhi+23
				pla
			sta		rowaddrlo+23
					;remake display list
			jsr		rewriteDisplayList
					;clear row 23
			lda		rowaddrhi+23
			ora		#$60
			sta		rowptr1+1
			eor		#$c0
			sta		rowptr2+1
			lda		rowaddrlo+23
			sta		rowptr1
			sta		rowptr2
			lda		#0
			ldx		#8
		yloop:
			ldy		#39
		xloop:
			sta		(rowptr1),y
			sta		(rowptr2),y
				dey
			bpl		xloop
			inc		rowptr1+1
			inc		rowptr2+1
				dex
			bne		yloop
			lda		#23
			sta		row
			jmp		recompRowAddr
			.endp
			;==========================================================================
		.proc	recompRowAddr
			ldx		row
			lda		rowaddrlo,x
			sta		rowptr1
			sta		rowptr2
			lda		rowaddrhi,x
			ora		#$60
			sta		rowptr1+1
			eor		#$c0
			sta		rowptr2+1
				rts
			.endp
			;==========================================================================
		.proc	putraw80
					;convert to internal encoding
				pha
				lsr
				lsr
				lsr
				lsr
				lsr
			and		#3
				tax
				pla
			eor		convtab,x
					;compute character address
				rol
				rol
				rol
				tax
			and		#$f8
			sta		chaddr
				txa
				rol
			and		#$03
			ora		#$e0
			sta		chaddr+1
					;start row loop
			lda		#0
			sta		rowcntr
		rowloop:
					;convert a row
			ldy		rowcntr
			lda		(chaddr),y
				asl
			ldx		#4
		bitloop:
				ror
			ror		cha
				ror
			ror		chb
				dex
			bne		bitloop
					;shift down if needed
			lda		col
			ldx		#$f0
				lsr
				tay
			bcc		leftside
			ldx		#4
		shiftloop:
			lsr		cha
			lsr		chb
				dex
			bne		shiftloop
			ldx		#$0f
		leftside:
					;merge in character
			stx		mask
			lda		(rowptr1),y
			eor		cha
			and		mask
			eor		(rowptr1),y
			sta		(rowptr1),y
			inc		rowptr1+1
			lda		(rowptr2),y
			eor		chb
			and		mask
			eor		(rowptr2),y
			sta		(rowptr2),y
			inc		rowptr2+1
					;do more rows
			inc		rowcntr
			lda		rowcntr
			cmp		#8
			bne		rowloop
					;restore row pointers
				sec
			lda		rowptr1+1
			sbc		#$08
			sta		rowptr1+1
			lda		rowptr2+1
			sbc		#$08
			sta		rowptr2+1
					;all done
				rts
		convtab:
				dta		$40
				dta		$20
				dta		$60
				dta		$00
			.endp
			;==========================================================================
		.proc	toggleCursor80
			ldx		#8
			lda		col
				lsr
				tay
			lda		#$f0
			scc:lda	#$0f
			sta		chb
		loop:
			lda		(rowptr1),y
			eor		chb
			sta		(rowptr1),y
			lda		(rowptr2),y
			eor		chb
			sta		(rowptr2),y
			inc		rowptr1+1
			inc		rowptr2+1
				dex
			bne		loop
			lda		rowptr1+1
				sec
			sbc		#$08
			sta		rowptr1+1
			eor		#$c0
			sta		rowptr2+1
				rts
			.endp
			;=========================================================================
		.proc	rewriteDisplayList
			lda		#0
			sta		rowptr1
			sta		rowptr2
			mva		#>dlist1 rowptr1+1
			mva		#>dlist2 rowptr2+1
			ldy		#0
			ldx		#0
					;24 blank lines
			lda		#$70
			jsr		putbyte
			jsr		putbyte
			jsr		putbyte
					;192 LMS lines
		lineloop:
			mva		#0 cha
		rowloop:
			lda		#$4F
			jsr		putbyte
			lda		rowaddrlo,x
			jsr		putbyte
			lda		rowaddrhi,x
				clc
			adc		cha
			ora		#$60
			sta		(rowptr1),y
			eor		#$c0
			sta		(rowptr2),y
			jsr		putbyte1
			inc		cha
			lda		cha
			cmp		#8
			bne		rowloop
				inx
			cpx		#24
			bne		lineloop
					;add wait for VBL insn
			lda		#$41
			jsr		putbyte
			lda		#<dlist1
			jsr		putbyte
			lda		#>dlist2
			sta		(rowptr1),y
			lda		#>dlist1
			sta		(rowptr2),y
				rts
		putbyte:
			sta		(rowptr1),y
			sta		(rowptr2),y
		putbyte1:
				iny
			bne		putbyte2
			inc		rowptr1+1
			inc		rowptr2+1
		putbyte2:
				rts
			.endp
			;=========================================================================
		.proc	clearScreen
			lda		#$60
			sta		rowptr1+1
			lda		#$a0
			sta		rowptr2+1
			lda		#0
			sta		rowptr1
			sta		rowptr2
			ldx		#$20
		xloop:
			ldy		#0
		yloop:
			sta		(rowptr1),y
			sta		(rowptr2),y
				iny
			bne		yloop
			inc		rowptr1+1
			inc		rowptr2+1
				dex
			bne		xloop
				rts
			.endp
			;=========================================================================
		.proc	vbiHandler
			lda		sdlsth
			eor		#$04
			sta		sdlsth
			jmp		xitvbv
			.endp
			;=========================================================================
			; We use a bit of a screwed up memory layout here, reminiscent of the
			; Apple II. Six lines are packed at a time into a page, and four pages
			; make up one row across all 24 lines. The row pages are arranged such
			; stepping down a character row simply involves incrementing the high
			; byte.
			;
		rowaddrlo:
	:4 dta $00, $28, $50, $78, $a0, $c8
		rowaddrhi:
		:6 dta $00
		:6 dta $08
		:6 dta $10
		:6 dta $18
			;=========================================================================
		dlist1	equ		$9800
		dlist2	equ		$9c00
			run		main
					end
