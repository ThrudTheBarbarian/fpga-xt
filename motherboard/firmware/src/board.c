/* board.c — put every pin into a defined state before anything uses it.
 *
 * Nothing here is subtle; the point is that no pin is left floating between
 * reset and whichever driver eventually claims it.  Drivers that need a pin in
 * a different mode (SPI, USART, timers) reconfigure it in their own init.
 */
#include "board.h"
#include "clock.h"

/* The hub's reset input is active low on every 4-port controller we might have
 * fitted, but confirm against the hub page of the schematic before trusting a
 * failed enumeration.  Flip this if the part turns out to be active high. */
#define HUB_RST_ACTIVE_LOW  1

void board_init(void)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOA | RCC_AHB1ENR_GPIOB | RCC_AHB1ENR_GPIOC |
                    RCC_AHB1ENR_GPIOD | RCC_AHB1ENR_GPIOE | RCC_AHB1ENR_GPIOH;
    RCC->APB2ENR |= RCC_APB2ENR_SYSCFG;

    /* --- FPGA doorbell (PA4): STM raises it when it has something to say ---
     * The FPGA is the SPI master and cannot be interrupted by a slave, so this
     * line is the only way the STM can start a conversation.  Idle low. */
    gpio_clear(GPIO_SPI, PIN_STM_SIRQ);
    gpio_mode(GPIO_SPI, PIN_STM_SIRQ, GPIO_MODE_OUT);
    gpio_speed(GPIO_SPI, PIN_STM_SIRQ, GPIO_SPEED_HIGH);

    /* --- USB hub reset (PA9) --- held in reset until usb_init() releases it */
    board_hub_reset(1);
    gpio_mode(GPIO_HUB, PIN_HUB_RST, GPIO_MODE_OUT);
    gpio_speed(GPIO_HUB, PIN_HUB_RST, GPIO_SPEED_LOW);

    /* --- PIA control lines toward the FPGA ---
     * INTERRUPT (CB1) and PROCEED (CA1) follow the SIO convention: active low,
     * so idle is high.  COMMAND (CB2) comes the other way; pull it up so it is
     * defined while the FPGA is still configuring and its pins float. */
    gpio_set(GPIO_FPGA_CTL, PIN_FPGA_INTERRUPT);
    gpio_set(GPIO_FPGA_CTL, PIN_FPGA_PROCEED);
    gpio_mode(GPIO_FPGA_CTL, PIN_FPGA_INTERRUPT, GPIO_MODE_OUT);
    gpio_mode(GPIO_FPGA_CTL, PIN_FPGA_PROCEED, GPIO_MODE_OUT);
    gpio_mode(GPIO_FPGA_CTL, PIN_FPGA_COMMAND, GPIO_MODE_IN);
    gpio_pull(GPIO_FPGA_CTL, PIN_FPGA_COMMAND, GPIO_PULL_UP);

    /* --- SIO control lines toward the DIN connector ---
     * MOTOR and COMMAND idle high (inactive); the clock pair is wired but idle
     * because SIO is asynchronous in practice.  IRQ and PROCEED are
     * open-collector inputs from the peripheral, hence the pull-ups. */
    gpio_set(GPIO_SIO_CTL, PIN_SIO_MOTOR);
    gpio_set(GPIO_SIO_CTL, PIN_SIO_CMD);
    gpio_set(GPIO_SIO_CTL, PIN_SIO_CLKOUT);
    gpio_mode(GPIO_SIO_CTL, PIN_SIO_MOTOR, GPIO_MODE_OUT);
    gpio_mode(GPIO_SIO_CTL, PIN_SIO_CMD, GPIO_MODE_OUT);
    gpio_mode(GPIO_SIO_CTL, PIN_SIO_CLKOUT, GPIO_MODE_OUT);

    gpio_mode(GPIO_SIO_CTL, PIN_SIO_CLKIN, GPIO_MODE_IN);
    gpio_mode(GPIO_SIO_CTL, PIN_SIO_IRQ, GPIO_MODE_IN);
    gpio_mode(GPIO_SIO_CTL, PIN_SIO_PROCEED, GPIO_MODE_IN);
    gpio_pull(GPIO_SIO_CTL, PIN_SIO_IRQ, GPIO_PULL_UP);
    gpio_pull(GPIO_SIO_CTL, PIN_SIO_PROCEED, GPIO_PULL_UP);
}

void board_hub_reset(int asserted)
{
#if HUB_RST_ACTIVE_LOW
    gpio_write(GPIO_HUB, PIN_HUB_RST, !asserted);
#else
    gpio_write(GPIO_HUB, PIN_HUB_RST, asserted);
#endif
}

void board_hub_cycle(void)
{
    board_hub_reset(1);
    clock_delay_ms(10);
    board_hub_reset(0);
    clock_delay_ms(50);                     /* hubs need a moment to come back */
}

void board_doorbell(void)
{
    /* Load MISO first, then ring — the FPGA reads on the edge, so raising the
     * line before the data is staged would hand it stale bytes. */
    gpio_set(GPIO_SPI, PIN_STM_SIRQ);
    clock_delay_us(2);
    gpio_clear(GPIO_SPI, PIN_STM_SIRQ);
}
