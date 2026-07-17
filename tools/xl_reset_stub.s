; xl_reset_stub.s - force COLDSTART on every A9-triggered 6502 reset.
;
; The A9's cold-boot-per-launch (CTRL SALLYRST) resets the CPU but RAM keeps
; its contents, so the XL OS would take the WARMSTART path (valid PUPBT) and
; never re-boot the disk.  The kernel points the RESET vector ($FFFC) here;
; this invalidates the power-up-validation bytes and jumps to the original
; reset target - the OS then runs a genuine coldstart, including the D1. boot.
;
; Assemble. xa -o xl_reset_stub.bin tools/xl_reset_stub.s (position-independent;
; the trailing JMP operand [len-2] is fixed up to the original RESET target).

* = $0000

    lda #$00
    sta $033D           ; PUPBT1
    sta $033E           ; PUPBT2
    sta $033F           ; PUPBT3
    jmp $FFFF           ; to original RESET target (kernel fixes up len-2)
