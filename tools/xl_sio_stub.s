; xl_sio_stub.s - the XTOS paravirtual SIO stub (Tier 1, docs/OS/app-launch.md).
;
; Patched into free XL OS ROM space by the kernel (xl_boot.c), SIOV's JMP target
; repointed here. Talks to the A9 through the SIO mailbox - dcb + a MAGIC byte
; into the mailbox, doorbell $D5C7, poll done, read the answer back out.
; COMPACT (must fit the largest free padding run in the OS ROM, ~164 B).
;
; A PORT, NOT A WINDOW. Earlier revisions reached the mailbox by setting
; $D5C6.0, which overlaid it on the CPU's view of $4000-$5FFF -- the GUEST'S
; RAM -- and held that map across the doorbell AND the whole A9 round-trip.
; Any interrupt taken in those milliseconds ran with $4000-$5FFF replaced.
; ElektraGlide streams its image through $0400-$B9FF, derailed into the mapped
; region and died executing the DCB's $52 (DCOMND) as a KIL. There is no window
; now - $D5CD selects a byte, $D5CE is that byte, and every access
; post-increments the index -- so one index write per phase walks a whole
; payload, carrying across $FF->$100 in the mailbox's 9-bit counter.
;
; Contract with the A9 (mathcop.h MC_OFF_SIO_*) -- offsets UNCHANGED, they are
; just reached through the port instead of the aperture, so xl_sio_service()
; did not move.
;   $05        magic $5A = "this chunk is an SIO request" (A9 checks, clears)
;   $40-$4B    dcb copy ($0300-$030B)
;   $C0-$1BF   sector payload (A9 to stub, for a page-copied read)
;   $03        SIO status byte (A9 to stub; 1 = ok, $8x/$9x = error)
;   $04        flags (A9 to stub). bit7 = NOT MINE (fall through to real SIO),
;              bit0 = data already DELIVERED to BRAM (DBUF >= $1000; no copy)
;
; Clobbers A/X/Y and BUFRLO/BUFRHI ($32/$33). Assemble - xa -o out.bin this.
; PIC; the trailing JMP operand [len-2] is fixed up to the original SIOV target.

* = $0000

    ; ---- request - dcb -> mailbox $40, then the magic byte at $05 ----------
    lda #$40
    sta $D5CD                   ; index = MC_OFF_SIO_DCB
    ldx #$00
dcb:
    lda $0300,x
    sta $D5CE                   ; store + index++
    inx
    cpx #$0C
    bne dcb

    lda #$05
    sta $D5CD                   ; index = MC_OFF_SIO_MAGIC
    lda #$5A
    sta $D5CE

    sta $D5C7                   ; doorbell (value ignored)
wait:
    lda $D5C7
    and #$01
    beq wait

    ; ---- reply - flags, then the payload if the A9 did not deliver it ------
    lda #$04
    sta $D5CD                   ; index = MC_OFF_SIO_FLAGS
    lda $D5CE
    bmi notmine
    and #$01
    bne done                    ; MC_SIO_DELIVERED - already in BRAM
    lda $0303
    and #$40
    beq done                    ; not a read - no payload
    lda $0304
    sta $32
    lda $0305
    sta $33
    lda #$C0
    sta $D5CD                   ; index = MC_OFF_SIO_DATA
    ldy #$00
rcopy:
    lda $D5CE                   ; byte + index++ (carries past $FF)
    sta ($32),y
    iny
    cpy $0308
    bne rcopy

done:
    lda #$03
    sta $D5CD                   ; index = MC_OFF_SIO_STATUS
    lda $D5CE
    sta $0303
    tay                         ; SIO returns status in Y as well as A
    rts

notmine:
    jmp $FFFF
