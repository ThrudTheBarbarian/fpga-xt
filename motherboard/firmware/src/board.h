/* board.h — Atari-XT motherboard pin map (IC3, STM32F411VET6, LQFP100).
 *
 * Transcribed from the carrier schematic.  Every entry carries the schematic
 * net name so this file and the Altium sheet can be diffed by eye.
 *
 * Port summary
 *   A   USART2 (FPGA control / ROM bootloader), SPI1 slave, doorbell,
 *       hub reset, USB OTG-FS, SWD, USART1 TX (SIO)
 *   B   8 paddle pots, USART1 RX (SIO), 3 FPGA control lines
 *   C   USART6 (MIDI), fan PWM + tach
 *   D   16 joystick direction lines — all four ports, contiguous
 *   E   SIO control lines, 4 joystick fire buttons
 */
#ifndef BOARD_H
#define BOARD_H

#include "stm32f411.h"

/* --------------------------------------------------------------- clocking --
 * Y1 is an 8 MHz crystal on PH0/PH1 (OSC_IN/OSC_OUT) with 8.2 pF loading.
 * PLL: /M=4 -> 2 MHz ref, xN=192 -> 384 MHz VCO, /P=4 -> 96 MHz SYSCLK,
 * /Q=8 -> 48 MHz exactly for USB OTG-FS.  96 rather than the 100 MHz maximum
 * because 100 cannot also yield a legal 48 MHz USB clock.
 */
#define HSE_HZ              8000000UL
#define SYSCLK_HZ           96000000UL
#define AHB_HZ              SYSCLK_HZ            /* AHB  prescaler /1  */
#define APB1_HZ             (SYSCLK_HZ / 2)      /* APB1 prescaler /2  = 48 MHz */
#define APB2_HZ             SYSCLK_HZ            /* APB2 prescaler /1  = 96 MHz */
#define APB1_TIMER_HZ       (APB1_HZ * 2)        /* /2 prescaler doubles timer clk */
#define APB2_TIMER_HZ       APB2_HZ

/* --------------------------------------------------------------- port A ----*/

#define PIN_UART2_TX        2       /* PA2  net UART2_FROM_STM -> Zynq MIO15 RX  */
#define PIN_UART2_RX        3       /* PA3  net UART2_TO_STM   <- Zynq MIO14 TX  */
#define PIN_STM_SIRQ        4       /* PA4  doorbell out, STM -> FPGA (ATN_S2F)  */
#define PIN_STM_SCLK        5       /* PA5  SPI1_SCK  in  (FPGA is master)       */
#define PIN_STM_MISO        6       /* PA6  SPI1_MISO out                        */
#define PIN_STM_MOSI        7       /* PA7  SPI1_MOSI in                         */
#define PIN_HUB_RST         9       /* PA9  USB hub reset out (NOT VBUS sense)   */
#define PIN_USB_DM          11      /* PA11 net STM_USB_N                        */
#define PIN_USB_DP          12      /* PA12 net STM_USB_P                        */
#define PIN_SWDIO           13      /* PA13                                      */
#define PIN_SWCLK           14      /* PA14                                      */
#define PIN_SIO_TX          15      /* PA15 USART1_TX -> SIO DATA_OUT            */

#define GPIO_UART2          GPIOA
#define GPIO_SPI            GPIOA
#define GPIO_HUB            GPIOA

/* PA9 carries HUB_RST, so OTG-FS has NO VBUS sense pin.  The USB core must be
 * configured with VBUS sensing disabled (GCCFG NOVBUSSENS) — the 4-way hub is
 * self-powered from the board rail and owns VBUS/overcurrent itself.
 */
#define BOARD_USB_HAS_VBUS_SENSE   0

/* --------------------------------------------------------------- port B ----
 * Eight paddle pots.  Naming follows the schematic: the four controller ports
 * are ILL (far left), IL (left), IR (right), IRR (far right); A/B are the two
 * pots in each port.
 *
 * NOTE these are read as RC charge-time on plain GPIO (see pots.c), NOT via
 * TIM3/TIM4 input capture — TIM3_CH3/CH4 are the fan PWM/tach pins PC8/PC9 and
 * a compare unit cannot serve two pins at once.
 */
#define PIN_IRR_POTA        0       /* PB0                                       */
#define PIN_IRR_POTB        1       /* PB1                                       */
/*      PB2  BOOT1 — unconnected on the schematic; see README "hardware notes"  */
#define PIN_SIO_RX          3       /* PB3  USART1_RX <- SIO DATA_IN             */
#define PIN_ILL_POTA        4       /* PB4                                       */
#define PIN_ILL_POTB        5       /* PB5                                       */
#define PIN_IL_POTA         6       /* PB6                                       */
#define PIN_IL_POTB         7       /* PB7                                       */
#define PIN_IR_POTA         8       /* PB8                                       */
#define PIN_IR_POTB         9       /* PB9                                       */
#define PIN_FPGA_INTERRUPT  13      /* PB13 out -> FPGA, PIA CB1                 */
#define PIN_FPGA_PROCEED    14      /* PB14 out -> FPGA, PIA CA1                 */
#define PIN_FPGA_COMMAND    15      /* PB15 in  <- FPGA, PIA CB2, EXTI15         */

#define GPIO_POTS           GPIOB
#define GPIO_FPGA_CTL       GPIOB

/* mask of the eight pot bits within GPIOB — all in one port so discharge and
 * release are a single atomic BSRR / MODER write for all eight simultaneously */
#define POT_MASK            ((1U << PIN_IRR_POTA) | (1U << PIN_IRR_POTB) | \
                             (1U << PIN_ILL_POTA) | (1U << PIN_ILL_POTB) | \
                             (1U << PIN_IL_POTA)  | (1U << PIN_IL_POTB)  | \
                             (1U << PIN_IR_POTA)  | (1U << PIN_IR_POTB))

/* --------------------------------------------------------------- port C ----*/

#define PIN_MIDI_TX         6       /* PC6  USART6_TX                            */
#define PIN_MIDI_RX         7       /* PC7  USART6_RX                            */
#define PIN_FAN_PWM         8       /* PC8  TIM3_CH3, via R67 220R to J3 pin 4   */
#define PIN_FAN_TACH        9       /* PC9  open-collector tach, needs pull-up   */

#define GPIO_MIDI           GPIOC
#define GPIO_FAN            GPIOC

/* --------------------------------------------------------------- port D ----
 * All sixteen joystick direction lines, contiguous and in port order, so one
 * read of GPIOD->IDR samples all four controllers at the same instant.
 * Switches are to ground, so internal pull-ups are enabled and a pressed
 * direction reads 0.
 */
#define PIN_IL_RT           0
#define PIN_IL_LT           1
#define PIN_IL_DN           2
#define PIN_IL_UP           3
#define PIN_ILL_RT          4
#define PIN_ILL_LT          5
#define PIN_ILL_DN          6
#define PIN_ILL_UP          7
#define PIN_IR_RT           8
#define PIN_IR_LT           9
#define PIN_IR_DN           10
#define PIN_IR_UP           11
#define PIN_IRR_RT          12
#define PIN_IRR_LT          13
#define PIN_IRR_DN          14
#define PIN_IRR_UP          15

#define GPIO_JOY_DIR        GPIOD
#define JOY_DIR_MASK        0xFFFFU

/* --------------------------------------------------------------- port E ----*/

#define PIN_SIO_IRQ         0       /* PE0  in,  EXTI0,  SIO pin 13 INTERRUPT    */
#define PIN_SIO_PROCEED     1       /* PE1  in,  EXTI1,  SIO pin 9  PROCEED      */
#define PIN_SIO_MOTOR       2       /* PE2  out, SIO MOTOR_CONTROL               */
#define PIN_SIO_CMD         3       /* PE3  out, SIO COMMAND                     */
#define PIN_SIO_CLKOUT      4       /* PE4  out, vestigial (SIO is async)        */
#define PIN_SIO_CLKIN       5       /* PE5  in,  vestigial                       */
#define PIN_ILL_BTN         12      /* PE12 fire button, active low              */
#define PIN_IL_BTN          13      /* PE13                                      */
#define PIN_IR_BTN          14      /* PE14                                      */
#define PIN_IRR_BTN         15      /* PE15                                      */

#define GPIO_SIO_CTL        GPIOE
#define GPIO_JOY_BTN        GPIOE
#define JOY_BTN_MASK        0xF000U

/* ------------------------------------------------------- alternate funcs ---*/

#define AF_TIM1_TIM2        1
#define AF_TIM3_TIM5        2
#define AF_SPI1             5
#define AF_USART1_2         7       /* USART1/2 on their remapped pins           */
#define AF_USART6           8
#define AF_OTG_FS           10

/* ------------------------------------------------------------- gpio helpers */

static inline void gpio_mode(gpio_t *p, unsigned pin, unsigned mode)
{
    p->MODER = (p->MODER & ~(3UL << (pin * 2))) | ((uint32_t)mode << (pin * 2));
}

static inline void gpio_pull(gpio_t *p, unsigned pin, unsigned pull)
{
    p->PUPDR = (p->PUPDR & ~(3UL << (pin * 2))) | ((uint32_t)pull << (pin * 2));
}

static inline void gpio_speed(gpio_t *p, unsigned pin, unsigned speed)
{
    p->OSPEEDR = (p->OSPEEDR & ~(3UL << (pin * 2))) | ((uint32_t)speed << (pin * 2));
}

static inline void gpio_af(gpio_t *p, unsigned pin, unsigned af)
{
    unsigned i = pin >> 3, s = (pin & 7) * 4;
    p->AFR[i] = (p->AFR[i] & ~(0xFUL << s)) | ((uint32_t)af << s);
    gpio_mode(p, pin, GPIO_MODE_AF);
}

static inline void gpio_set(gpio_t *p, unsigned pin)   { p->BSRR = 1UL << pin; }
static inline void gpio_clear(gpio_t *p, unsigned pin) { p->BSRR = 1UL << (pin + 16); }

static inline void gpio_write(gpio_t *p, unsigned pin, int v)
{
    p->BSRR = v ? (1UL << pin) : (1UL << (pin + 16));
}

static inline int gpio_read(gpio_t *p, unsigned pin)
{
    return (p->IDR >> pin) & 1U;
}

void board_init(void);
void board_hub_reset(int asserted);             /* 1 = held in reset */
void board_hub_cycle(void);                     /* assert, settle, release */
void board_doorbell(void);                      /* pulse PA4 toward the FPGA */

#endif /* BOARD_H */
