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
					opt		h+o+l+
					icl		'library.s'
				org		$e0
	row		dta		0
		col		dta		0
	rowptr	dta		a($9000)
	rowptr2	dta		a(0)
		blnkcnt	dta		0
		cha		dta		0
			;========================== NON-RESIDENT SECTION ==========================
				org		$2800
		.proc main
					;turn off display
			sei
		mva		#0 sdmctl
				cli
			jsr		_waitVBL
					;relocate resident section
		copyloop:
		mva		$2a00,x $0a00,x
				inx
			bne		copyloop
					;clear screen memory
			jsr		clearScreen
					;swap in new display list and turn DMA back on
				sei
	mwa		#dlist sdlstl
		mva		#$22 sdmctl
				cli
					;wait for vertical blank
			jsr		_waitVBL
					;init params
			mva		#0 row
			mva		#2 col
			jsr		recompRowAddr
					;replace putchar vector
	mwa		#putchar40 _vputchar
				rts
			.endp
			;============================ RESIDENT SECTION ============================
				org		$0a00,$2a00
		.proc	putchar40
			sta		cha
				tya
				pha
			jsr		toggleCursor40
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
					;convert to internal encoding
				tay
				rol
				rol
				rol
				rol
			and		#3
				tax
				tya
			eor		convtab,x
			ldy		col
			sta		(rowptr),y
					;update position and exit
				iny
			sty		col
			cpy		#40
			bcs		newline
		alldone:
			jsr		toggleCursor40
				pla
				tay
				rts
		isclearscrn:
			jsr		clearScreen
		recomp_and_exit:
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
			jsr		scroll40
		noscroll:
			jmp		recomp_and_exit
		convtab:
				dta		$40
				dta		$20
				dta		$60
				dta		$00
			.endp
			;==========================================================================
		.proc	clearLine
			lda		#0
			ldy		#39
		sta:rpl	(rowptr),y-
			mva		#2 col
				rts
			.endp
			;==========================================================================
		.proc	scroll40
					;clear row 24
			lda		#0
			ldx		#40
		sta:rne	scnbase+40*24-1,x-
					;shift screen memory up by 40 bytes
			lda		#$0c
			sta		pageloop+2
			sta		pageloop+5
			ldy		#4
		pageloop:
			lda		scnbase+40,x
			sta		scnbase,x
				inx
			bne		pageloop
			inc		pageloop+2
			inc		pageloop+5
				dey
			bne		pageloop
					;warp cursor and recompute row address
			lda		#23
			sta		row
			jmp		recompRowAddr
			.endp
			;==========================================================================
		.proc	recompRowAddr
			lda		row
				asl					;x2 (0-46)
				asl					;x4 (0-92)
				clc
			adc		row			;x5 (0-115)
				asl					;x10 (0-230)
				asl					;x20 (0-460)
				rol					;x40 (0-920)
				tax
			and		#$f8
			sta		rowptr
				txa
				rol
			and		#$03
				clc
			adc		#>scnbase
			sta		rowptr+1
				rts
			.endp
			;==========================================================================
		.proc	toggleCursor40
			ldy		col
			lda		#$80
			eor		(rowptr),y
			sta		(rowptr),y
				rts
			.endp
			;=========================================================================
		.proc	clearScreen
			lda		#0
				tax
		clear_loop:
			sta		scnbase,x
			sta		scnbase+$0100,x
			sta		scnbase+$0200,x
			sta		scnbase+$0300,x
				inx
			bne		clear_loop
			stx		row
			mva		#2 col
			jsr		recompRowAddr
			jmp		toggleCursor40
			.endp
			;=========================================================================
					.if *>$0ae0
					.error "Module too long: ",*
					.endif
				org		$0ae0,$2ae0
		dlist:
		:3 dta $70
			dta		$42,a(scnbase)
	:23 dta $02
			dta		$41,a(dlist)
				org		$0c00
		scnbase:
			run		main
					end
