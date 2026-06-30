/******************************************************************************
* Copyright (c) 2023 - 2025 Advanced Micro Devices, Inc. All Rights Reserved.
* SPDX-License-Identifier: MIT
******************************************************************************/
#ifndef _FREERTOSUARTCONFIG_H
#define _FREERTOSUARTCONFIG_H



/* #undef XPM_SUPPORT */
/* #undef XPAR_STDIN_IS_UARTLITE */
/* #undef XPAR_STDIN_IS_UARTNS550 */
#define XPAR_STDIN_IS_UARTPS  
/* #undef XPAR_STDIN_IS_UARTPSV */
/* #undef XPAR_STDIN_IS_CORESIGHTPS_DCC */
/* #undef XPAR_STDIN_IS_IOMODULE */
#define STDIN_BASEADDRESS 0xe0001000
#define STDOUT_BASEADDRESS 0xe0001000

#if defined (__aarch64__) || defined (ARMA53_32)
#define EL3  0
#define EL1_NONSECURE  0
#define HYP_GUEST  0
#endif

#endif /* _FREERTOSUARTCONFIG_H */
