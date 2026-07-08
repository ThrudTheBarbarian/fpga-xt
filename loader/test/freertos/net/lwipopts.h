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
#define LWIP_NETCONN               1     /* the PL0 socket ABI bridges to netconn */
#define LWIP_SO_RCVTIMEO           1     /* blocking recv ticks for kill/^C/^Z */
#define LWIP_SO_RCVBUF             1     /* recv_avail -> FIONREAD/poll */
#define SO_REUSE                   1     /* honour SOF_REUSEADDR: a restarted
                                          * server rebinds over TIME_WAIT pcbs
                                          * (sockets.c sets it on every bind) */
#define LWIP_NETIF_LOOPBACK        1     /* 127.0.0.1 (the slirp-free test rig) */
#define LWIP_HAVE_LOOPIF           1
#define MEMP_NUM_NETCONN           48
#define MEMP_NUM_NETBUF            32
#define MEMP_NUM_TCPIP_MSG_API     32
#define LWIP_NETIF_API             0

#define LWIP_IPV4                  1
#define LWIP_IPV6                  0
#define LWIP_ARP                   1
#define ARP_QUEUEING               1     /* queue the pkt while ARP resolves (else the
                                          * first packet to an unresolved MAC is DROPPED,
                                          * so the board can't initiate its own resolution) */
#define ARP_QUEUE_LEN              10
#define LWIP_ICMP                  1
#define LWIP_UDP                   1
#define LWIP_TCP                   1
#define LWIP_DHCP                  1
#define LWIP_DHCP_DOES_ACD_CHECK   0     /* bind on ACK (no multi-second ARP probe dance) */
#define LWIP_AUTOIP                0
#define LWIP_DNS                   1     /* sntp resolves pool.ntp.org */
#define LWIP_DHCP_PROVIDE_DNS_SERVERS 1  /* DHCP option 6 -> dns_setserver */
#define LWIP_IGMP                  1     /* mDNS joins 224.0.0.251 */
#define LWIP_RAW                   1    /* raw ICMP sockets — ping */

#define LWIP_NETIF_HOSTNAME        1
#define LWIP_MDNS_RESPONDER        1     /* xtos.local */
#define LWIP_NUM_NETIF_CLIENT_DATA 1
#define MDNS_MAX_SERVICES          1
#define LWIP_NETIF_EXT_STATUS_CALLBACK 1 /* mdns re-announces on address change */
#define LWIP_NETIF_STATUS_CALLBACK 1
#define LWIP_NETIF_LINK_CALLBACK   1

/* static pools only: no libc malloc in the kernel */
#define MEM_LIBC_MALLOC            0
#define MEMP_MEM_MALLOC            0
#define MEM_ALIGNMENT              4
#define MEM_SIZE                   (64 * 1024)
#define MEMP_NUM_PBUF              48
#define MEMP_NUM_UDP_PCB           12
#define MEMP_NUM_TCP_PCB           48   /* active + TIME_WAIT: rapid short connections
                                          * leave PCBs in TIME_WAIT (2*MSL); a small pool
                                          * exhausts under churn -> connect/accept fail */
#define MEMP_NUM_TCP_PCB_LISTEN    16   /* a multi-port server wants many listeners */
#define MEMP_NUM_TCP_SEG           48
#define MEMP_NUM_SYS_TIMEOUT       24    /* dhcp+arp+tcp+dns+mdns+sntp+tftp cyclic + one-
                                          * shots; an EXHAUSTED pool spins the tcpip thread
                                          * at prio 3 = a whole-system wedge */
#define PBUF_POOL_SIZE             48
#define PBUF_POOL_BUFSIZE          1600

#define TCP_MSS                    1460
#define TCP_WND                    (8 * TCP_MSS)
#define TCP_SND_BUF                (8 * TCP_MSS)

#define LWIP_CHECKSUM_CTRL_PER_NETIF 0   /* software checksums everywhere (no offload) */

#define TCPIP_THREAD_NAME          "lwip"
#define LWIP_FREERTOS_THREAD_STACKSIZE_IS_STACKWORDS 1   /* sizes below are WORDS */
#define TCPIP_THREAD_STACKSIZE     2048      /* words = 8 KB (dns/sntp/mdns run here) */
#define TCPIP_THREAD_PRIO          4         /* above PL0 processes (3): packet processing
                                              * (ip4_input/raw_input) must not be starved by a
                                              * busy app; pairs with net_task at 4 */
#define TCPIP_MBOX_SIZE            16
#define DEFAULT_UDP_RECVMBOX_SIZE  8
#define DEFAULT_TCP_RECVMBOX_SIZE  8
#define DEFAULT_RAW_RECVMBOX_SIZE  8    /* ping's ICMP raw netconn */
#define DEFAULT_ACCEPTMBOX_SIZE    4
#define DEFAULT_THREAD_STACKSIZE   1024

#define LWIP_STATS                 1   /* per-proto counters -> /OS/proc/net/stats */
#define LWIP_STATS_DISPLAY         0   /* no stats_display() (we format in procnet) */
#define LWIP_DEBUG                 0

/* SNTP: resolves pool.ntp.org, hands the unix epoch to the kernel wall clock */
#define SNTP_SERVER_DNS            1
#define SNTP_SET_SYSTEM_TIME(sec)  do { extern void xt_wallclock_set(unsigned); xt_wallclock_set((unsigned)(sec)); } while (0)
#define SNTP_UPDATE_DELAY          3600000   /* re-sync hourly */

/* the TFTP file drop (apps/tftp/tftp.c) */
#define TFTP_MAX_FILENAME_LEN      128
#define LWIP_TFTP_MODE_SERVER_ONLY 1

#endif
