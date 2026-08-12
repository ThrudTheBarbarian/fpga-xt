/* uart.c — USART2 on PA2/PA3.
 *
 * This is the link to the Zynq (its UART0 on MIO14/15) and, at reset with
 * BOOT0 high, the very same pins the on-chip ROM bootloader listens on.  So
 * the FPGA gets one wire pair that is both the firmware-update channel and the
 * runtime control channel — they are never needed at the same instant.
 *
 * RX is interrupt-driven into a ring so a REPL command can arrive while the
 * main loop is busy servicing USB.
 */
#include "uart.h"
#include "board.h"

#define RX_SIZE     256                     /* power of two */

static volatile char     s_rx[RX_SIZE];
static volatile unsigned s_rx_wr, s_rx_rd;

void uart2_init(uint32_t baud)
{
    RCC->AHB1ENR |= RCC_AHB1ENR_GPIOA;
    RCC->APB1ENR |= RCC_APB1ENR_USART2;

    gpio_af(GPIO_UART2, PIN_UART2_TX, AF_USART1_2);
    gpio_af(GPIO_UART2, PIN_UART2_RX, AF_USART1_2);
    gpio_speed(GPIO_UART2, PIN_UART2_TX, GPIO_SPEED_HIGH);
    gpio_pull(GPIO_UART2, PIN_UART2_RX, GPIO_PULL_UP);   /* idle high if unplugged */

    /* USART2 is on APB1.  Oversampling by 16, so BRR is simply the divider in
     * 12.4 fixed point, which is exactly what (clk + baud/2) / baud yields. */
    USART2->BRR = (APB1_HZ + baud / 2U) / baud;
    USART2->CR1 = USART_CR1_UE | USART_CR1_TE | USART_CR1_RE | USART_CR1_RXNEIE;
    USART2->CR2 = 0;
    USART2->CR3 = 0;

    s_rx_wr = s_rx_rd = 0;

    nvic_priority(IRQ_USART2, 8);
    nvic_enable(IRQ_USART2);
}

void usart2_handler(void)
{
    uint32_t sr = USART2->SR;

    if (sr & (USART_SR_ORE | USART_SR_FE | USART_SR_NE | USART_SR_PE)) {
        (void)USART2->DR;                   /* SR-then-DR read clears them */
        return;
    }
    if (sr & USART_SR_RXNE) {
        char     c    = (char)(USART2->DR & 0xFF);
        unsigned next = (s_rx_wr + 1U) & (RX_SIZE - 1U);
        if (next != s_rx_rd) {              /* silently drop when full */
            s_rx[s_rx_wr] = c;
            s_rx_wr       = next;
        }
    }
}

int uart2_write(const char *data, int len)
{
    for (int i = 0; i < len; i++) {
        while (!(USART2->SR & USART_SR_TXE))
            ;
        USART2->DR = (uint8_t)data[i];
    }
    return len;
}

int uart2_read(char *data, int len)
{
    int n = 0;

    while (n < len && s_rx_rd != s_rx_wr) {
        data[n++] = s_rx[s_rx_rd];
        s_rx_rd   = (s_rx_rd + 1U) & (RX_SIZE - 1U);
    }
    return n;
}

int uart2_readable(void)
{
    return (int)((s_rx_wr - s_rx_rd) & (RX_SIZE - 1U));
}
