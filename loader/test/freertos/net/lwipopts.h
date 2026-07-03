/* lwipopts.h — lwIP configuration for the XTOS loader.
 *
 * OS mode (NO_SYS=0) over the FreeRTOS sys_arch port; raw + callback APIs
 * only (no sockets/netconn yet — that's the phase-2 PL0 ABI); static pools,
 * no libc malloc. TCP is compiled in ready for the console-over-TCP phase;
 * phase 1 uses UDP (DHCP + the TFTP file drop). */
#ifndef XT_LWIPOPTS_H
#define XT_LWIPOPTS_H

#define NO_SYS                     0
#define SYS_LIGHTWEIGHT_PROT       1
#define LWIP_TCPIP_CORE_LOCKING    1

#define LWIP_SOCKET                0
#define LWIP_NETCONN               0
#define LWIP_NETIF_API             0

#define LWIP_IPV4                  1
#define LWIP_IPV6                  0
#define LWIP_ARP                   1
#define LWIP_ICMP                  1
#define LWIP_UDP                   1
#define LWIP_TCP                   1
#define LWIP_DHCP                  1
#define LWIP_DHCP_DOES_ACD_CHECK   0     /* bind on ACK (no multi-second ARP probe dance) */
#define LWIP_AUTOIP                0
#define LWIP_DNS                   0
#define LWIP_IGMP                  0
#define LWIP_RAW                   0

#define LWIP_NETIF_HOSTNAME        1
#define LWIP_NETIF_STATUS_CALLBACK 1
#define LWIP_NETIF_LINK_CALLBACK   1

/* static pools only: no libc malloc in the kernel */
#define MEM_LIBC_MALLOC            0
#define MEMP_MEM_MALLOC            0
#define MEM_ALIGNMENT              4
#define MEM_SIZE                   (64 * 1024)
#define MEMP_NUM_PBUF              32
#define MEMP_NUM_UDP_PCB           8
#define MEMP_NUM_TCP_PCB           8
#define MEMP_NUM_TCP_PCB_LISTEN    4
#define MEMP_NUM_TCP_SEG           32
#define MEMP_NUM_SYS_TIMEOUT       12
#define PBUF_POOL_SIZE             32
#define PBUF_POOL_BUFSIZE          1600

#define TCP_MSS                    1460
#define TCP_WND                    (8 * TCP_MSS)
#define TCP_SND_BUF                (8 * TCP_MSS)

#define LWIP_CHECKSUM_CTRL_PER_NETIF 0   /* software checksums everywhere (no offload) */

#define TCPIP_THREAD_NAME          "lwip"
#define TCPIP_THREAD_STACKSIZE     2048      /* words */
#define TCPIP_THREAD_PRIO          3
#define TCPIP_MBOX_SIZE            16
#define DEFAULT_UDP_RECVMBOX_SIZE  8
#define DEFAULT_TCP_RECVMBOX_SIZE  8
#define DEFAULT_ACCEPTMBOX_SIZE    4
#define DEFAULT_THREAD_STACKSIZE   1024

#define LWIP_STATS                 0
#define LWIP_DEBUG                 0

/* the TFTP file drop (apps/tftp/tftp.c) */
#define TFTP_MAX_FILENAME_LEN      128

#endif
