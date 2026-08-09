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
	scnbase	dta		a($9000)
	rowptr	dta		a($9000)
	rowptr2	dta		a(0)
		blnkcnt	dta		0
		cha		dta		0
			;========================== NON-RESIDENT SECTION ==========================
				org		$2000
		.proc main
					;turn off display
			sei
		mva		#0 sdmctl
				cli
			jsr		_waitVBL
					;relocate resident section
		copyloop:
		mva		$9000,x $9c00,x
		mva		$9100,x $9d00,x
		mva		$9200,x $9e00,x
		mva		$9300,x $9f00,x
				inx
			bne		copyloop
					;clear screen memory
			ldx		#0
			ldy		#12
			lda		#0
		clearloop:
			sta		$9000,x
				inx
			bne		clearloop
			inc		clearloop+2
				dey
			bne		clearloop
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
					;wrap keyboard vector
				sei
	mwa		vkeybd keyvec40.oldvec
	mwa		#keyvec40 vkeybd
				cli
					;replace putchar vector
	mwa		#putchar40 _vputchar
	mwa		#unhook40 _vputunhook
				rts
			.endp
			;============================ RESIDENT SECTION ============================
				org		$9c00,$9000
		.proc	keyvec40
		lda		kbcode
			cmp		#$af		;Q
			beq		is_ctrl_q
			cmp		#$bf		;A
			beq		is_ctrl_a
			jmp		$0000
		oldvec = *-2
		is_ctrl_q:
					;scroll up by $3c0
				cld
				txa
				pha
			lda		dlist+4
			sub		#$c0
				tax
			lda		dlist+5
			sbc		#$03
			cmp		#$90
			bcs		scroll_ok
			ldx		#$00
			lda		#$90
		scroll_ok:
			stx		dlist+4
			sta		dlist+5
				pla
				tax
				pla
				rti
		is_ctrl_a:
					;scroll down by $3c0
				cld
				txa
				pha
			lda		dlist+4
			add		#$c0
				tax
			lda		dlist+5
			adc		#$03
			cmp		scnbase+1
			bne		scroll_down_check_2
			cpx		scnbase
		scroll_down_check_2:
			bcc		scroll_ok
			ldx		scnbase
			lda		scnbase+1
			bne		scroll_ok
			.endp
		.proc	unhook40
				sei
	mwa		keyvec40.oldvec vkeybd
				cli
				rts
			.endp
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
					;draw raw character
			jsr		putraw40
					;update position and exit
			inc		col
			lda		col
			cmp		#40
			bcs		newline
		alldone:
			jsr		toggleCursor40
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
			jsr		scroll40
		noscroll:
			jsr		recompRowAddr
			jmp		alldone
			.endp
			;==========================================================================
		.proc	clearLine
			lda		#0
			ldx		#8
			ldy		#40
		yloop:
			sta		(rowptr),y
				dey
			bne		yloop
			mva		#2 col
				rts
			.endp
			;==========================================================================
		.proc	scroll40
					;bump address down by 40 bytes
			lda		#40
				clc
			adc		scnbase
				sei
			sta		scnbase
			scc:inc	scnbase+1
				cli
					;check if we've exceeded $9848
			cmp		#$48
			bne		fast_ok
			lda		scnbase+1
			cmp		#$98
			bne		fast_ok
			jsr		shiftScreen
		fast_ok:
					;warp cursor and recompute row address
			lda		#23
			sta		row
			jsr		recompRowAddr
					;clear row 23
			lda		#0
			ldy		#39
		xloop:
			sta		(rowptr),y
				dey
			bpl		xloop
					;update hardware address
				sei
		mva		scnbase dlist+4
		mva		scnbase+1 dlist+5
				cli
					;all done
				rts
			.endp
			;==========================================================================
		.proc	shiftScreen
					;shift screen memory up by $500 bytes
		mva		#$95 pageloop+2
		mva		#$90 pageloop+5
			ldy		#7
		pageloop:
			lda		$9500,x
			sta		$9000,x
				inx
			bne		pageloop
			inc		pageloop+2
			inc		pageloop+5
				dey
			bne		pageloop
					;move screen base
				sei
			lda		scnbase+1
				sec
			sbc		#5
			sta		scnbase+1
				cli
					;all done
				rts
			.endp
			;==========================================================================
		.proc	recompRowAddr
					;40 = 2*2*2*5
			mva		#0 rowptr+1
			lda		row
			ldx		#2
			jsr		shl
				clc
			adc		row
			scc:inc	rowptr+1
			ldx		#3
			jsr		shl
				clc
			adc		scnbase
			sta		rowptr
			lda		rowptr+1
			adc		scnbase+1
			sta		rowptr+1
				rts
		shl:
				asl
			rol		rowptr+1
				dex
			bne		shl
				rts
			.endp
			;==========================================================================
		.proc	putraw40
					;convert to internal encoding
				pha
				rol
				rol
				rol
				rol
			and		#3
				tax
				pla
			eor		convtab,x
			ldy		col
			sta		(rowptr),y
				rts
		convtab:
				dta		$40
				dta		$20
				dta		$60
				dta		$00
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
	mwa		scnbase rowptr2
			ldx		#24
			stx		blnkcnt
		lineloop:
			ldy		#39
		charloop:
			lda		(rowptr2),y
			bne		notblank
				dey
			bpl		charloop
			dec		blnkcnt
			jmp		nextline
		notblank:
			mva		#24 blnkcnt
		nextline:
			lda		#40
				clc
			adc		rowptr2
			sta		rowptr2
			scc:inc	rowptr2+1
				dex
			bne		lineloop
					;scroll until we have 24 blank lines
			lda		blnkcnt
			beq		done
		blankloop:
			jsr		scroll40
			dec		blnkcnt
			bne		blankloop
		done:
			mva		#0 row
			mva		#2 col
			jsr		recompRowAddr
			jsr		toggleCursor40
				rts
			.endp
			;=========================================================================
					.if *>$9fc0
					.error "Module too long: ",*
					.endif
				org		$9fc0,$93c0
		dlist:
		:3 dta $70
			dta		$42,a($9000)
	:23 dta $02
			dta		$41,a(dlist)
			run		main
					end
