# gtia_addrmirror — GTIA: Address mirroring

**Pins down:** that GTIA's registers mirror across its address space, verified
through live collision state rather than a static readback.

Source: [`src/gtia_addrmirror.s`](src/gtia_addrmirror.s). Four assertions.

## Method

All four players are stacked at the same position with full patterns:

```
lda #$ff -> grafp0..grafp3, sizep0..sizep2, sizem
lda #$80 -> hposp0..hposp3
```

so collisions are guaranteed, then the test reads the collision registers
through their mirrored addresses and requires agreement, and finally turns the
sprites off and checks the mirrors again.

Using collisions rather than a written-then-read register is the point: a
collision register's value is produced by hardware, so a mirror that is really a
separate storage location cannot fake it.

## To pass this test you must have

GTIA decoded on its low address bits with the rest of `$D0xx` aliasing onto it,
for the collision registers as well as the write registers — and the mirror
reading the *same live state*, not a copy.
