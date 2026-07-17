; xl_sio_stub.s - the XTOS paravirtual SIO stub (Tier 1, docs/OS/app-launch.md).
;
; Patched into free XL OS ROM space by the kernel (xl_boot.c), with the SIOV
; vector's JMP target repointed here.  Talks to the A9 through the math-cop
; mailbox. DCB to slots, one MC_OP_SIO op word, doorbell $D5C7, poll done.
;
; Contract with the A9 (mathcop.h MC_OFF_SIO_*).
;   $4040-$404B  DCB copy ($0300-$030B)
;   $40C0-$41BF  sector payload (<= 256 bytes)
;   $4003        SIO status byte (1 = complete, $8x/$9x = error)
;   $4004        flags. bit7 = NOT MINE (fall through to the real SIO),
;                       bit0 = data DELIVERED (A9 wrote BRAM via the ROM
;                       window because DBUF >= $1000 - the stub must NOT copy;
;                       this is also what makes DBUF inside $4000-$5FFF safe,
;                       since the stub's view of that range is the mapped page)
;
; Clobbers A/X/Y and BUFRLO/BUFRHI ($32/$33) - SIO's own zero-page cells.
; The write path copies (DBUF) with the page MAPPED. safe for any DBUF outside
; $4000-$5FFF; a write FROM the overlay range is refused by the A9 (v1 gap).
;
; Assemble.  xa -o xl_sio_stub.bin tools/xl_sio_stub.s   (position-independent.
; relative branches only; the trailing JMP's operand [len-2] is fixed up by the
; kernel to the ORIGINAL SIOV target).  Bytes embedded in xl_boot.c.

* = $0000

start:
    lda $D5C6           ; save math-page map state
    pha
    lda $D5C8           ; save chunk select
    pha
    lda #$FF
    sta $D5C8           ; SIO's dedicated chunk (MC_SIO_CHUNK)
    lda #$01
    sta $D5C6           ; map the math page over $4000-$5FFF

    ldx #$0B            ; DCB $0300-$030B to slots at $4040
dcbloop:
    lda $0300,x
    sta $4040,x
    dex
    bpl dcbloop

    lda #$01
    sta $4000           ; op_count = 1
    lda #$00
    sta $4001
    sta $4003           ; status = 0
    sta $4004           ; flags = 0
    lda #$02
    sta $4002           ; MC_ABI_VERSION
    lda #$25            ; MC_OP_SIO
    sta $4840
    lda #$00
    sta $4841
    sta $4842
    sta $4843

    lda $0304           ; DBUF to BUFRLO/HI
    sta $32
    lda $0305
    sta $33

    lda $0303           ; DSTATS bit7 = write (6502 to device)
    bpl doexec
    ldy #$00            ; write. stage (DBUF) to $40C0 before the doorbell
    ldx $0309           ; DBYTHI != 0 to full 256 bytes
    bne w256
wshort:
    cpy $0308
    beq doexec
    lda ($32),y
    sta $40C0,y
    iny
    bne wshort
    beq doexec          ; Y wrapped. 256 copied
w256:
    lda ($32),y
    sta $40C0,y
    iny
    bne w256

doexec:
    sta $D5C7           ; EXEC doorbell (value irrelevant)
wait:
    lda $D5C7
    and #$01            ; done bit
    beq wait

    lda $4004           ; A9 flags
    bmi notmine         ; bit7. not a virtual device
    and #$01
    bne setstat         ; bit0. A9 already delivered to BRAM - no copy
    lda $0303
    and #$40            ; a read op with data for us?
    beq setstat
    ldy #$00            ; copy $40C0.. to (DBUF) (DBUF < $1000 here by contract)
    ldx $0309
    bne r256
rshort:
    cpy $0308
    beq setstat
    lda $40C0,y
    sta ($32),y
    iny
    bne rshort
    beq setstat
r256:
    lda $40C0,y
    sta ($32),y
    iny
    bne r256

setstat:
    lda $4003           ; the SIO status byte
    sta $0303           ; to DSTATS
    tax                 ; keep it through the restores
    pla
    sta $D5C8           ; restore chunk select
    pla
    sta $D5C6           ; restore map state
    txa
    tay                 ; SIO returns status in Y, flags from it
    rts

notmine:
    pla
    sta $D5C8
    pla
    sta $D5C6
    jmp $FFFF           ; to the ORIGINAL SIOV target (kernel fixes up len-2)
