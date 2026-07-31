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
				_SAP_HEADER "GTIA: Phantom PMG DMA"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
		mva	#0 nmien
				sei
			lda		#124
		cmp:rne	vcount
	mwa		#dlist dlistl
		mva		#$21 dmactl
		mva		#$81 prior
		mva		#$02 gractl		;player DMA only
		mva		#$81 hposp0
		mva		#$00 hposp1
		mva		#$00 hposp2
		mva		#$00 hposp3
		mva		#$89 hposm0
		mva		#$8b hposm1
		mva		#$8d hposm2
		mva		#$8f hposm3
		mva		#$01 sizep0
		mva		#$00 sizem
		mva		#$ff grafm
		mva		#$18 colpm0
		mva		#$38 colpm1
		mva		#$58 colpm2
		mva		#$78 colpm3
		mva		#$ff grafp0
			ldx		#15
		cpx:rne	vcount
		cpx:req	vcount
			inc		wsync			;end 32
			sta		hitclr			;105, 106, 107, 108
				nop						;109, 110
				nop						;111, 112
			lda		$00				;113, 0, 1
			lda		$0100			;2*, 3, 4, 5, 6
			inc		wsync			;end 33
			lda		p0pf			;105, 106, 107, 108
			ldx		m0pl			;109, 110, 111, 112
			ldy		m1pl			;113, 0, 1*, 2, 3
			sta		d0				;4, 5, 6
			stx		d1				;7, 8, 9
			lda		m2pl			;10, 11, 12, 13
			ldx		m3pl			;14, 15, 16, 17
			sty		d2
			sta		d3
			stx		d4
			lda		d0
			lsr		d1
				rol
			lsr		d2
				rol
			lsr		d3
				rol
			lsr		d4
				rol
			sta		d0
				_ASSERT1 d0, $ad, c"Phantom DMA byte #1 was not $AD (was $%x).",0
			jmp		_testPassed
		testname:
	dta		c"GTIA: Phantom PMG DMA",0
				org		$2400
		dlist:
			dta		$70
				dta		$70
				dta		$70
			dta		$4F,a(framebuf)
				dta		$0F
				dta		$70
				dta		$70
				dta		$70
				dta		$70
				dta		$70
				dta		$70
				dta		$70
				dta		$70
			dta		$41,a(dlist)
		framebuf:
	:32 dta $88
	:16 dta $88
			dta		$76,$54
	:14 dta $88
			run		$2000
					end
