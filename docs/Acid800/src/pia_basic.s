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
				_SAP_HEADER "PIA: Basic test"
					opt		h+o+
					icl		'library.s'
				org		$2000
		main:
			ldy		#>testname
			lda		#<testname
			jsr		_testInit
			jsr		_screenOff
			jsr		_interruptsOff
					;check port A direction register
		mva		#$38 pactl
		mva		#$ff porta
		mva		porta d0
		mva		#$00 porta
		mva		porta d1
		mva		#$3c pactl
				_ASSERT1	d0, $ff, c"Port A direction register failed: %x != ff"
				_ASSERT1	d1, $00, c"Port A direction register failed: %x != 00"
					;check if port A o/d registers are distinct
		mva		#$38 pactl
		mva		#$cc porta
		mva		#$3c pactl
		mva		#$55 porta
		mva		#$38 pactl
		mva		porta d0
				_ASSERT1	d0, $cc, c"Port A crosstalk test failed: direction %x != cc"
					;check if port B o/d registers are distinct
		mva		#$38 pbctl
		mva		#$00 portb		;DDRB = $00 (all inputs)
		mva		#$3c pbctl
		mva		#$55 portb		;ORB = $55 (can't read this while input mode)
		mva		#$38 pbctl
		mva		portb d0
				_ASSERT1	d0, $00, c"Port B crosstalk test #1 failed: DDRB %x != 00"
					;switch DDRB to $FF... ORB should then read $55
		mva		#$ff portb		;DDRB = $ff (all outputs)
		mva		#$3c pbctl
		mva		portb d0
				_ASSERT1	d0, $55, c"Port B crosstalk test #2 failed: IORB %x != 55"
					;check if we can pull down all input lines with the outputs
		mva		#$38 pactl
		mva		#$ff porta
		mva		#$3c pactl
		mva		#$00 porta
		mva		porta d0
				_ASSERT1	d0, $00, c"Port A output test failed: %x != 00"
		mva		#$38 pactl
		mva		#0 porta
		mva		#$3c pactl
		mva		#0 porta
			jmp		_testPassed
		testname:
	dta		c"PIA: Basic test",0
			run		$2000
					end
