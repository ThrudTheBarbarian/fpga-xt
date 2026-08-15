; xl_reset_stub.s - force COLDSTART *and* wipe RAM on every 6502 reset.
;
; The A9's cold-boot-per-launch (CTRL SALLYRST) resets the CPU but RAM keeps
; its contents.  Two problems follow:
;   1. The XL OS would take the WARMSTART path (valid PUPBT) and never re-boot
;      the disk.
;   2. A previous session's / crashed game's RAM survives.  The A9 ROM-window
;      upload scrubs $1000-$BFFF, but it physically CANNOT reach $0000-$0FFF,
;      and a game's own reset (JMP ($FFFC)) after a crash does no A9 scrub at
;      all - so stale bytes leak into the next run and the first boot differs
;      from a post-crash reboot.
;
; So the kernel points the RESET vector ($FFFC) here and we, running on the
; 6502 itself (which CAN write all of $0000-$BFFF), zero the whole RAM before
; entering the OS coldstart.  This makes every reset a genuine, repeatable
; power-on: clean RAM + a real coldstart + the D1 boot.  Clearing PUPBT
; ($033D-$033F) falls out of the sweep, which is what forces the coldstart.
;
; Assemble. xa -o xl_reset_stub.bin tools/xl_reset_stub.s (position-independent;
; the trailing JMP operand [len-2] is fixed up to the original RESET target).

* = $0000

    ; Disable NMIs + ANTIC DMA first, so the wipe can't be derailed by a stale
    ; DLI/VBI NMI.  SALLYRST clears these in HW, but a game's own reset->$FFFC
    ; path does not, so do it here unconditionally.
    lda #$00
    sta $D40E           ; NMIEN  = 0
    sta $D400           ; DMACTL = 0

    ; Wipe $0100-$BFFF via an indirect pointer in zero page ($F0/$F1).
    sta $F0             ; ptr lo = $00
    lda #$01
    sta $F1             ; ptr hi = $01  (start at $0100)
    ldy #$00
nextpage:
    lda #$00            ; MUST be reloaded per page: the loop below leaves the
                        ; PAGE NUMBER in A (lda $F1), so branching straight back
                        ; to wipehi filled every page with its own page number
                        ; instead of zero ($A000->$A0, $BFFC->$BF ...).
wipehi:
    sta ($F0),y
    iny
    bne wipehi
    inc $F1
    lda $F1
    cmp #$A0            ; stop before $A000: ROM and RAM share one array in
                        ; sally_mem, so wiping the BASIC window destroys the
                        ; freshly uploaded BASIC image whenever a game left
                        ; BASIC banked out (rom_override does not block it).
                        ; upload_image rewrites $A000-$BFFF every boot anyway.
    bne nextpage

    ; Wipe zero page $0000-$00FF last (this also clears the $F0/$F1 pointer and
    ; PUPBT1-3 at $033D-$033F was already cleared in the sweep above).
    ldx #$00
    lda #$00
wipezp:
    sta $00,x
    inx
    bne wipezp

    jmp $FFFF           ; original RESET target (kernel fixes up len-2)
