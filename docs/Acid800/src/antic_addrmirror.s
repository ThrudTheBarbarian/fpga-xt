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
				_SAP_HEADER "ANTIC: Address mirroring"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
			lda		vcount
			lda		#$10
		cmp:rne	vcount
			lda		vcount+$20
			cmp		#$10
			beq		pass1
		fail1:
			sta		d0
				_FAIL	c"VCOUNT mirror mismatch: $%x != $10"
		pass1:
			lda		#$11
		cmp:rne	vcount
			lda		vcount+$20
			cmp		#$11
			bne		fail1
			lda		#125
		cmp:rne	vcount
			bit		nmist
			bvs		pass2
				_FAIL	c"NMIST bit 6 was not set on VBLANK."
		pass2:
			bit		nmist+$20
			bvs		pass3
				_FAIL	c"NMIST mirror bit 6 was not set on VBLANK."
		pass3:
			sta		nmires
			bit		nmist
			bvc		pass4
				_FAIL	c"NMIST bit 6 was not cleared by NMIRES."
		pass4:
			bit		nmist+$20
			bvc		pass5
				_FAIL	c"NMIST mirror bit 6 was not cleared by NMIRES."
		pass5:
			jmp		_testPassed
		testname:
	dta		c"ANTIC: Address mirroring",0
			run		$2000
					end
