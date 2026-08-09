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
	xebase	dta		a(0)
	rowptr	dta		a(0)
		row		dta		0
		col		dta		4
		cha		dta		0
			;============ NON-RESIDENT SECTION ============
				org		$2000
				VBXE_VIDEO_CONTROL	= $40
				VBXE_CORE_VERSION	= $40
				VBXE_MINOR_REVISION	= $41
				VBXE_XDL_ADR0		= $41
				VBXE_XDL_ADR2		= $42
				VBXE_XDL_ADR3		= $43
				VBXE_CSEL			= $44
				VBXE_PSEL			= $45
				VBXE_CR				= $46
				VBXE_CG				= $47
				VBXE_CB				= $48
				VBXE_BL_ADR0		= $50
				VBXE_BL_ADR1		= $51
				VBXE_BL_ADR2		= $52
				VBXE_BLITTER_START	= $53
				VBXE_BLITTER_BUSY	= $53
				VBXE_IRQ_CONTROL	= $54
				VBXE_P0				= $55
				VBXE_P1				= $56
				VBXE_P2				= $57
				VBXE_P3				= $58
				VBXE_MEMAC_CONTROL	= $5E
				VBXE_MEMAC_BANK_SEL	= $5F
				VBXE_UPLOAD_BASE	= $1800
		upload_dest		equ $b800
			.macro XEBLIT
					ldx		#>(:1 - upload_start + VBXE_UPLOAD_BASE)
					lda		#<(:1 - upload_start + VBXE_UPLOAD_BASE)
					jsr		xeBlitStart
					jsr		xeBlitWait
			.endm
			.macro XEBLIT_RTS
					ldx		#>(:1 - upload_start + VBXE_UPLOAD_BASE)
					lda		#<(:1 - upload_start + VBXE_UPLOAD_BASE)
					jsr		xeBlitStart
					jmp		xeBlitWait
			.endm
			;==========================================================================
		.proc main
					;try $D600
	mwa		#$d600 xebase
			jsr		xeDetect
			bpl		detected
	mwa		#$d700 xebase
			jsr		xeDetect
			bpl		detected
			jsr		_imprint
	dta		c"Error: Video Board XE 1.20+ not found.",$9b,$9b,0
			jmp		_waitKeyPrompt
		detected:
					;stop blitter and disable blitter interrupt
			lda		#0
			ldy		#VBXE_BLITTER_START
			sta		(xebase),y
			ldy		#VBXE_IRQ_CONTROL
			sta		(xebase),y
					;disable ANTIC display
				sei
	mwa		#dlist sdlstl
				cli
			jsr		_waitVBL
					;upload font at $02000
			ldy		#VBXE_MEMAC_BANK_SEL
			lda		#$82
			sta		(xebase),y
			ldx		#0
		fontloop:
					;copy character from internal encoded position in base font to
					;to normal and inverted states in ATASCII positions
					;
					; ATASCII  Internal
					;  00-1F -> 40-5F
					;  20-3F -> 00-1F
					;  40-5F -> 20-3F
					;  60-7F -> 60-7F
			lda		$e200,x
			sta		$a000,x
			eor		#$ff
			sta		$a400,x
			lda		$e000,x
			sta		$a100,x
			eor		#$ff
			sta		$a500,x
			lda		$e100,x
			sta		$a200,x
			eor		#$ff
			sta		$a600,x
			lda		$e300,x
			sta		$a300,x
			eor		#$ff
			sta		$a700,x
				inx
			bne		fontloop
					;upload palette 1
			ldy		#VBXE_PSEL
			lda		#1
			sta		(xebase),y
					;set color $00 to #4aa4ff
			ldy		#VBXE_CSEL
			lda		#0
			sta		(xebase),y
			ldy		#VBXE_CR
			mva		#$4a (xebase),y
				iny
			mva		#$a4 (xebase),y
				iny
			mva		#$ff (xebase),y
					;set color $80 to #003a9e
			ldy		#VBXE_CSEL
			lda		#$80
			sta		(xebase),y
			ldy		#VBXE_CR
			mva		#$00 (xebase),y
				iny
			mva		#$3a (xebase),y
				iny
			mva		#$9e (xebase),y
					;reset MEMAC A window to $00000
			lda		#$80
			ldy		#VBXE_MEMAC_BANK_SEL
			sta		(xebase),y
					;upload XDL and blit lists
	mwa		#$b800 a1
	mwa		#upload_start a0
			ldx		#(upload_end - upload_start + 255)/256
			ldy		#0
		uploadloop:
			lda		(a0),y
			sta		(a1),y
				iny
			bne		uploadloop
			inc		a0+1
			inc		a1+1
				dex
			bne		uploadloop
					;set XDL address to $01800
			ldy		#VBXE_XDL_ADR0
			lda		#0
			sta		(xebase),y
				iny
			lda		#$18
			sta		(xebase),y
				iny
			lda		#0
			sta		(xebase),y
					;init display
			ldy		#VBXE_VIDEO_CONTROL
			lda		#$01
			sta		(xebase),y
					;clear the screen
			jsr		xeClearScreen
					;change display vector
	mwa		#xePutChar _vputchar
	mwa		#xeUnhook _vputunhook
					;all done!
				rts
			.endp
		.proc xeDetect
					;check core version
			ldy		#VBXE_CORE_VERSION
			lda		(xebase),y
			cmp		#$ff
			beq		fail
			cmp		#$10
			bcs		major_version_ok
		fail:
			lda		#$80
				rts
		major_version_ok:
					;check core revision
			ldy		#VBXE_MINOR_REVISION
			lda		(xebase),y
			cmp		#$ff
			beq		fail
			and		#$7f
			cmp		#$20
			bcc		fail
					;issue reset (this may also whack HPOSP0 on GTIA)
			lda		#$80
			sta		$D080
					;wait a little bit in case VBXE needs time to recover
			jsr		_waitVBL
			jsr		_waitVBL
					;see if we can twiddle MEMAC_CONTROL - disable MEMAC A first
			ldy		#VBXE_MEMAC_CONTROL
			lda		#$00
			sta		(xebase),y
			cmp		(xebase),y
			bne		fail
					;map $00000 to $A000-BFFF via MEMAC A
			lda		#$AD
			sta		(xebase),y
			cmp		(xebase),y
			bne		fail
			ldy		#VBXE_MEMAC_BANK_SEL
			lda		#$80
			sta		(xebase),y
					;quickly test memory
			lda		#0
			sta		$A000
			cmp		$A000
			bne		fail
			lda		#$ff
			sta		$A000
			cmp		$A000
			bne		fail
					;looks good....
			lda		#0
				rts
			.endp
			;============ UPLOAD SECTION ============
		upload_start:
		upload_xdl:
					;24 blank lines
			dta		$24,$00
				dta		$17
					;192 text lines
			dta		$f1,$89				;text mode, end
				dta		$bf					;repeat 191x
		dta		a($0000),$00,a($0100)	;address = $00000, pitch = $100
			dta		$00,$00				;scroll 0,0
				dta		$04					;character base = $02000
			dta		$11,$00				;overlay attributes: normal, palette 1, overlay on bottom
		upload_blit_clear_data:
			dta		$20, $80
		upload_blit_clear:
		dta		a(upload_blit_clear_data - upload_start + VBXE_UPLOAD_BASE),$00,a($0000),$01	;source
		dta		a($0000),$00,a($0100),$01	;dest
			dta		a($009f),$17				;width, height
			dta		$ff,$00,$00					;and, xor, collision
			dta		$00,$81,$00					;zoom, pattern, mode
		upload_blit_clear_line:
		dta		a(upload_blit_clear_data - upload_start + VBXE_UPLOAD_BASE),$00,a($0000),$01	;source
		dta		a($0000),$00,a($0000),$01	;dest
			dta		a($009f),$00				;width, height
			dta		$ff,$00,$00					;and, xor, collision
			dta		$00,$81,$00					;zoom, pattern, mode
		upload_blit_scroll:
					;move 23 lines up
		dta		a($0100),$00,a($0100),$01	;source
		dta		a($0000),$00,a($0100),$01	;dest
			dta		a($009f),$16				;width, height
			dta		$ff,$00,$00					;and, xor, collision
			dta		$00,$00,$08					;zoom, pattern, mode
					;clear last line
		dta		a(upload_blit_clear_data - upload_start + VBXE_UPLOAD_BASE),$00,a($0000),$01	;source
		dta		a($1700),$00,a($0000),$01	;dest
			dta		a($009f),$00				;width, height
			dta		$ff,$00,$00					;and, xor, collision
			dta		$00,$81,$00					;zoom, pattern, mode
		upload_end:
			;============ RESIDENT SECTION ============
				org		$9000
		dlist:
		dta		$41,a(dlist)
			;==========================================================================
		.proc xeUnhook
					;wait for any outstanding blits to finish
			jsr		xeBlitWait
					;issue VBXE reset
			lda		#$80
			sta		$d080
					;done
				rts
			.endp
			;==========================================================================
		.proc xePutChar
			sta		cha
				tya
				pha
					;toggle cursor
			jsr		xeToggleCursor
					;recover character
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
			ldy		col
			sta		(rowptr),y
					;update position and exit
			inc		col
			inc		col
			lda		col
			cmp		#156
			bcs		newline
		alldone:
			jsr		xeToggleCursor
				pla
				tay
				rts
		isclearscrn:
			jsr		xeClearScreen
			jmp		alldone
		isclearline:
			jsr		xeClearLine
			jmp		alldone
		newline:
					;reset X position
			mva		#4 col
					;increment Y position
			inc		row
			inc		rowptr+1
					;check if we've gone over
			lda		row
			cmp		#24
			bcc		noscroll
					;whoops... looks like we'll have to scroll
			dec		row
			dec		rowptr+1
			jsr		xeScroll
		noscroll:
			jmp		alldone
			.endp
			;==========================================================================
		.proc xeToggleCursor
			ldy		col
			lda		#$80
			eor		(rowptr),y
			sta		(rowptr),y
				rts
			.endp
			;==========================================================================
		.proc xeRecompRowAddr
			lda		row
			ora		#$a0
			sta		rowptr+1
				rts
			.endp
			;==========================================================================
		.proc xeScroll
					;issue scroll blit
				XEBLIT_RTS upload_blit_scroll
			.endp
			;==========================================================================
		.proc xeClearLine
					;set destination address for line clear
			lda		row
			sta		upload_dest + (upload_blit_clear_line + 7 - upload_start)
					;issue clear blit
				XEBLIT	upload_blit_clear_line
					;reset column
			mva		#4 col
					;all done
				rts
			.endp
			;==========================================================================
		.proc xeClearScreen
					;issue clear blit
				XEBLIT	upload_blit_clear
					;reset row/column
			mva		#4 col
			mva		#0 row
			jsr		xeRecompRowAddr
					;all done
				rts
			.endp
			;==========================================================================
		.proc xeBlitStart
					;wait for any existing blit to finish
			jsr		xeBlitWait
					;set blit list address
			ldy		#VBXE_BL_ADR0
			sta		(xebase),y
				txa
				iny
			sta		(xebase),y
			lda		#0
				iny
			sta		(xebase),y
					;start blitter
			ldy		#VBXE_BLITTER_START
			lda		#1
			sta		(xebase),y
				rts
			.endp
			;==========================================================================
		.proc xeBlitWait
					;poll until blitter busy bits go clear
			ldy		#VBXE_BLITTER_BUSY
				pha
			lda:rne	(xebase),y
				pla
				rts
			.endp
			;==========================================================================
			run		main
					end
