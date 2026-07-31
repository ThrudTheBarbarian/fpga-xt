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
				_SAP_HEADER "GTIA: Address mirroring"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
					;place all players on top of each other
			lda		#$ff
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			sta		sizep0
			sta		sizep1
			sta		sizep2
			sta		sizem
			lda		#$80
			sta		hposp0
			sta		hposp1
			sta		hposp2
			sta		hposp3
					;wait until high in display region
			lda		#$10
		cmp:rne	vcount
					;wait a couple of scanlines to ensure collisions
			inc		wsync
			inc		wsync
					;turn off all sprites
			lda		#$00
			sta		grafp0
			sta		grafp1
			sta		grafp2
			sta		grafp3
			sta		grafm
			inc		wsync
					;check that p0 shows collisions
			lda		p0pl
			and		#$0f
				_ASSERTA $0e, c"Player 0 collisions wrong: $%x"
					;check collisions on mirror address
			lda		p0pl+$40
			and		#$0f
				_ASSERTA $0e, c"Mirror player 0 collisions wrong: $%x"
					;clear collisions through mirror
			sta		hitclr
			inc		wsync
			lda		p0pl+$40
			and		#$0f
				_ASSERTA $00, c"Mirror player 0 collisions not cleared: $%x"
			lda		p0pl
			and		#$0f
				_ASSERTA $00, c"Player 0 collisions not cleared: $%x"
			jmp		_testPassed
		testname:
	dta		c"GTIA: Address mirroring",0
			run		$2000
					end
