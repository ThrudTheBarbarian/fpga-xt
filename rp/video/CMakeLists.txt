cmake_minimum_required(VERSION 3.13)

# rp_antic_video — paired RP2354 firmware that serves as intelligent
# video memory for fpga-antic. Implements the FPGA<->RP FETCH/SET/DRAW
# bus, holds the framebuffer, and (M17+) accelerates drawing primitives.
#
# Dev rig: Adafruit Feather RP2350 (RP2350A). Production target: custom
# RP2354 board (board file added later — uses the chip's full 48-pin
# package + PSRAM/SRAM external memory).
#
# Build:
#   mkdir -p build && cd build
#   PICO_SDK_PATH=/opt/pico-sdk cmake ..
#   make -j

set(PICO_PLATFORM rp2350-arm-s)
set(PICO_BOARD adafruit_feather_rp2350 CACHE STRING "Board type")

include(${CMAKE_CURRENT_LIST_DIR}/pico_sdk_import.cmake)

project(rp_antic_video C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

pico_sdk_init()

# sys_clk target. Default 360 MHz — needed for the bus PIO to comfortably
# absorb the FPGA's FETCH/SET stream at the line-buffer prefetch budget
# (~16 MHz beat rate worst case at 800x600 fullres). 252 MHz is also
# valid for ANTIC-compat which only needs ~5 MHz beat rate.
#
#   ≤ 252 MHz  → no vreg change, no QMI retune
#   ≤ 360 MHz  → vreg 1.35 V + QMI retune  (DEFAULT — validated baseline)
#   ≤ 432 MHz  → vreg 1.40 V + QMI retune
#   ≤ 480 MHz  → vreg 1.50 V + QMI retune
#   ≤ 528 MHz  → vreg 1.60 V + QMI retune
set(RP_VIDEO_SYS_MHZ "360" CACHE STRING "sys_clk in MHz (252, 360, 432, 480, 528)")

add_executable(rp_antic_video
    src/main.c
    src/clock.c
    src/bus_server.c
)

# bus.pio is the FPGA<->RP bus state machine. Generated header lives in the
# build dir; main.c includes it via the standard pico_generate_pio_header
# convention.
pico_generate_pio_header(rp_antic_video ${CMAKE_CURRENT_LIST_DIR}/src/bus.pio)

target_include_directories(rp_antic_video PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src)
target_compile_options(rp_antic_video PRIVATE -O3 -Wall -Wextra -Wno-unused-parameter)
target_compile_definitions(rp_antic_video PRIVATE RP_VIDEO_SYS_MHZ=${RP_VIDEO_SYS_MHZ})

if(RP_VIDEO_SYS_MHZ LESS_EQUAL 252)
    message(STATUS "rp-antic-video: sys_clk = ${RP_VIDEO_SYS_MHZ} MHz (default vreg)")
elseif(RP_VIDEO_SYS_MHZ LESS_EQUAL 360)
    message(STATUS "rp-antic-video: sys_clk = ${RP_VIDEO_SYS_MHZ} MHz (vreg 1.35 V + QMI retune)")
elseif(RP_VIDEO_SYS_MHZ LESS_EQUAL 432)
    message(STATUS "rp-antic-video: sys_clk = ${RP_VIDEO_SYS_MHZ} MHz (vreg 1.40 V + QMI retune)")
elseif(RP_VIDEO_SYS_MHZ LESS_EQUAL 480)
    message(STATUS "rp-antic-video: sys_clk = ${RP_VIDEO_SYS_MHZ} MHz (vreg 1.50 V + QMI retune)")
elseif(RP_VIDEO_SYS_MHZ LESS_EQUAL 528)
    message(STATUS "rp-antic-video: sys_clk = ${RP_VIDEO_SYS_MHZ} MHz (vreg 1.60 V + QMI retune, near-max)")
else()
    message(FATAL_ERROR "rp-antic-video: RP_VIDEO_SYS_MHZ=${RP_VIDEO_SYS_MHZ} exceeds 528")
endif()

target_link_libraries(rp_antic_video
    pico_stdlib
    pico_multicore
    hardware_clocks
    hardware_dma
    hardware_gpio
    hardware_irq
    hardware_pio
    hardware_resets
    hardware_sync
    hardware_vreg
)

pico_add_extra_outputs(rp_antic_video)
pico_enable_stdio_usb(rp_antic_video 1)
pico_enable_stdio_uart(rp_antic_video 0)
