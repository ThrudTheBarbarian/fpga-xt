; xl_sio_stub.s - the XTOS paravirtual SIO stub (Tier 1, docs/OS/app-launch.md).
;
; Patched into free XL OS ROM space by the kernel (xl_boot.c), SIOV's JMP target
; repointed here. Talks to the A9 through the math-cop mailbox. dcb to slots + a
; MAGIC byte, doorbell $D5C7, poll done. COMPACT (must fit the largest free
; padding run in the OS ROM, ~164 B). magic instead of an op program, no
; pre-clears (the A9 writes status+flags), and v1 is READ-ONLY-boot; the write
; path is a follow-up (ATRs boot without writing).
;
; Contract with the A9 (mathcop.h MC_OFF_SIO_*).
;   $4005        magic $5A = "this chunk is an SIO request" (A9 checks, clears)
;   $4040-$404B  dcb copy ($0300-$030B)
;   $40C0-$41BF  sector payload (A9 to stub, for a page-copied read)
;   $4003        SIO status byte (A9 to stub; 1 = ok, $8x/$9x = error)
;   $4004        flags (A9 to stub). bit7 = NOT MINE (fall through to real SIO),
;                bit0 = data already DELIVERED to BRAM (DBUF >= $1000; no copy)
;
; Clobbers A/X/Y and BUFRLO/BUFRHI ($32/$33). Assemble. xa -o out.bin this.
; PIC; the trailing JMP operand [len-2] is fixed up to the original SIOV target.

* = $0000

    lda $D5C6
    pha
    lda $D5C8
    pha
    lda #$FF
    sta $D5C8
    lda #$01
    sta $D5C6

    ldx #$0B
dcb:
    lda $0300,x
    sta $4040,x
    dex
    bpl dcb

    lda #$5A
    sta $4005

    sta $D5C7
wait:
    lda $D5C7
    and #$01
    beq wait

    lda $4004
    bmi notmine
    and #$01
    bne done
    lda $0303
    and #$40
    beq done
    lda $0304
    sta $32
    lda $0305
    sta $33
    ldy #$00
rcopy:
    lda $40C0,y
    sta ($32),y
    iny
    cpy $0308
    bne rcopy

done:
    lda $4003
    sta $0303
    tax
    pla
    sta $D5C8
    pla
    sta $D5C6
    txa
    tay
    rts

notmine:
    pla
    sta $D5C8
    pla
    sta $D5C6
    jmp $FFFF
