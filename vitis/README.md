# vitis/ — PS-side build (Vitis Unified 2025.x)

PS-side counterpart to `vivado/`.  Generates the Vitis platform, the
Zynq FSBL, and the bare-metal `app_blink` hello-world from the XSA
that Vivado writes alongside the bitstream.

## Layout

```
vitis/
├── README.md           this file
├── .gitignore          excludes generated workspace
├── run.sh              rsync sources to remote box, run vitis -s, sync back
├── scripts/
│   └── create_platform.py    Vitis Unified Python script
├── app_blink/
│   └── src/main.c      bare-metal app source (committed)
└── workspace/          (gitignored) Vitis-generated workspace
    ├── fpga_xt_platform/    standalone platform + BSP
    ├── fsbl/                Zynq FSBL component
    └── app_blink/           our app, builds against the platform
```

## Workflow

Same remote-build pattern as `vivado/run.sh`: sources rsync to the
build box, the Xilinx toolchain runs there, artefacts come back.

### One-time platform setup

```sh
cd vivado && ./run.sh bit fpga_xt_top xc7z020-2clg400   # writes XSA
cd ../vitis && ./run.sh                                  # creates platform + FSBL + app
```

After this, `vitis/workspace/app_blink/build/app_blink.elf` exists
and is ready for JTAG load.

### Editing the app

`vitis/app_blink/src/main.c` is the source of truth.  The Vitis
component imports from there, so:

```sh
# edit vitis/app_blink/src/main.c
cd vitis && ./run.sh   # rebuilds platform + app (idempotent)
```

Eventually a `build_app.py` will skip the platform-rebuild step for
the common edit-build-flash loop.  Not done yet — the full
`create_platform.py` re-run is idempotent and only takes ~30 s once
the platform is cached.

### JTAG load

Once the bitstream and `app_blink.elf` are in hand:

```sh
xsct -eval "
    connect
    fpga -file ../vivado/build/fpga_xt_top.bit
    targets -set -filter {name =~ \"ARM*#0\"}
    dow workspace/app_blink/build/app_blink.elf
    con
"
```

A canned version of the above lives at
`vivado/scripts/jtag_load.tcl` (bring-up prereq, separate commit).

## Env vars

| Var | Default | Notes |
|-----|---------|-------|
| `VITIS_PATH` | `/opt/xilinx/2025.2.1/Vitis` | path to Vitis settings64.sh |
| `REMOTE`     | `ubuntu`                     | SSH alias of build box |
| `REMOTE_DIR` | `fpga-xt-build`              | path on remote |

## Things this does NOT do yet

- **FreeRTOS BSP** — committed scope is standalone (bare-metal).
  FreeRTOS comes once the boot path is proven.
- **boot.bin builder** — `bootgen` wrapping FSBL + bitstream + app
  into an SD-bootable image.  Phase 3+ prereq from
  `docs/bring-up.md`; defer until JTAG bring-up is solid.
- **GPIO blink** — currently the heartbeat is UART-only.  Need to
  confirm the Z-Turn PS-side LED MIO assignments before driving real
  LEDs from `app_blink`.
