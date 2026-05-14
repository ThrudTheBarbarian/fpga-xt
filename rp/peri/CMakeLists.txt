cmake_minimum_required(VERSION 3.13)

# rp_antic_peri — peripheral RP2354B firmware. Owns the joystick /
# fire-button / POT / SIO / SD-card pins and bridges them to the FPGA
# over a 3-pin SPI + 1-pin IRQ link. See ../../docs/hardware-notes.md
# § "Peripheral RP" and ../../docs/roadmap.md § M25.
#
# Dev rig: Adafruit Feather RP2350 (RP2350A) — same dev board as
# rp_antic_video, with a different firmware image. Production target:
# custom RP2354B QFN-80 (48 GPIOs).
#
# Build:
#   mkdir -p build && cd build
#   PICO_SDK_PATH=/opt/pico-sdk cmake ..
#   make -j

set(PICO_PLATFORM rp2350-arm-s)
set(PICO_BOARD adafruit_feather_rp2350 CACHE STRING "Board type")

include(${CMAKE_CURRENT_LIST_DIR}/pico_sdk_import.cmake)

project(rp_antic_peri C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

pico_sdk_init()

# sys_clk target. The peri-RP doesn't need 360 MHz — its SPI slave PIO
# runs comfortably at any sys_clk ≥ ~120 MHz given the FPGA's 5 MHz SPI
# rate, and the C polling loop's <200 ns response budget needs ~70
# cycles at 360 MHz / ~50 cycles at 252 MHz. Default 252 MHz keeps the
# default vreg + flash timing untouched (the QMI retune dance only
# fires above 252 MHz).
#
#   ≤ 252 MHz  → no vreg change, no QMI retune (DEFAULT)
#   ≤ 360 MHz  → vreg 1.35 V + QMI retune
#   ≤ 432 MHz  → vreg 1.40 V + QMI retune
#   ≤ 480 MHz  → vreg 1.50 V + QMI retune
#   ≤ 528 MHz  → vreg 1.60 V + QMI retune
set(RP_PERI_SYS_MHZ "252" CACHE STRING "sys_clk in MHz (252, 360, 432, 480, 528)")

add_executable(rp_antic_peri
    src/main.c
    src/clock.c
    src/peri_spi_slave.c
    src/peri_regs.c
    src/peri_pot.c
    src/peri_sio.c
    src/peri_sd.c
    src/peri_irq.c
)

pico_generate_pio_header(rp_antic_peri ${CMAKE_CURRENT_LIST_DIR}/src/peri_pot.pio)
pico_generate_pio_header(rp_antic_peri ${CMAKE_CURRENT_LIST_DIR}/src/peri_sio.pio)

target_include_directories(rp_antic_peri PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src)
target_compile_options(rp_antic_peri PRIVATE -O3 -Wall -Wextra -Wno-unused-parameter)
target_compile_definitions(rp_antic_peri PRIVATE RP_PERI_SYS_MHZ=${RP_PERI_SYS_MHZ})

if(RP_PERI_SYS_MHZ LESS_EQUAL 252)
    message(STATUS "rp-antic-peri: sys_clk = ${RP_PERI_SYS_MHZ} MHz (default vreg)")
elseif(RP_PERI_SYS_MHZ LESS_EQUAL 360)
    message(STATUS "rp-antic-peri: sys_clk = ${RP_PERI_SYS_MHZ} MHz (vreg 1.35 V + QMI retune)")
elseif(RP_PERI_SYS_MHZ LESS_EQUAL 432)
    message(STATUS "rp-antic-peri: sys_clk = ${RP_PERI_SYS_MHZ} MHz (vreg 1.40 V + QMI retune)")
elseif(RP_PERI_SYS_MHZ LESS_EQUAL 480)
    message(STATUS "rp-antic-peri: sys_clk = ${RP_PERI_SYS_MHZ} MHz (vreg 1.50 V + QMI retune)")
elseif(RP_PERI_SYS_MHZ LESS_EQUAL 528)
    message(STATUS "rp-antic-peri: sys_clk = ${RP_PERI_SYS_MHZ} MHz (vreg 1.60 V + QMI retune, near-max)")
else()
    message(FATAL_ERROR "rp-antic-peri: RP_PERI_SYS_MHZ=${RP_PERI_SYS_MHZ} exceeds 528")
endif()

target_link_libraries(rp_antic_peri
    pico_stdlib
    pico_multicore
    hardware_clocks
    hardware_gpio
    hardware_irq
    hardware_pio
    hardware_spi
    hardware_sync
    hardware_vreg
)

pico_add_extra_outputs(rp_antic_peri)
pico_enable_stdio_usb(rp_antic_peri 1)
pico_enable_stdio_uart(rp_antic_peri 0)
