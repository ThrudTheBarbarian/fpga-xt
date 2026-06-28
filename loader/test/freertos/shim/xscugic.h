/* Minimal stand-in for the Xilinx GIC driver header. The vendored FreeRTOS
 * port (legacy, non-SDT path) references these; the real GIC work is done in
 * zynq.c, so the implementations (bsp_shim.c) are no-ops. */
#ifndef XSCUGIC_H
#define XSCUGIC_H
#include "xil_types.h"

typedef struct {
    u32     DeviceId;
    UINTPTR CpuBaseAddress;
    UINTPTR DistBaseAddress;
} XScuGic_Config;

typedef struct {
    XScuGic_Config *Config;
    u32 IsReady;
} XScuGic;

typedef void (*Xil_InterruptHandler)(void *);

#define XPAR_SCUGIC_SINGLE_DEVICE_ID 0U

XScuGic_Config *XScuGic_LookupConfig(u16 DeviceId);
s32  XScuGic_CfgInitialize(XScuGic *InstancePtr, XScuGic_Config *ConfigPtr, u32 EffectiveAddr);
s32  XScuGic_Connect(XScuGic *InstancePtr, u32 Int_Id, Xil_InterruptHandler Handler, void *CallBackRef);
void XScuGic_Enable(XScuGic *InstancePtr, u32 Int_Id);
void XScuGic_Disable(XScuGic *InstancePtr, u32 Int_Id);

#endif /* XSCUGIC_H */
