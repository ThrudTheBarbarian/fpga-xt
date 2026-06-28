/*
 * bsp_shim.c — no-op stand-ins for the Xilinx GIC-driver calls the vendored
 * FreeRTOS port makes on its legacy path. The real GIC + tick setup is in
 * zynq.c (gic_init / vConfigureTickInterrupt), so these just satisfy the port's
 * link references and let its init succeed.
 */
#include "xscugic.h"

/* the GIC instance the port references (we don't use it; zynq.c owns the GIC) */
XScuGic xInterruptController;

static XScuGic_Config g_cfg = {
    .DeviceId = 0,
    .CpuBaseAddress = 0xF8F00100UL,
    .DistBaseAddress = 0xF8F01000UL,
};

XScuGic_Config *XScuGic_LookupConfig(u16 DeviceId)
{
    (void)DeviceId;
    return &g_cfg;
}

s32 XScuGic_CfgInitialize(XScuGic *InstancePtr, XScuGic_Config *ConfigPtr, u32 EffectiveAddr)
{
    (void)EffectiveAddr;
    if (InstancePtr) { InstancePtr->Config = ConfigPtr; InstancePtr->IsReady = 1; }
    return XST_SUCCESS;
}

s32 XScuGic_Connect(XScuGic *InstancePtr, u32 Int_Id, Xil_InterruptHandler Handler, void *CallBackRef)
{
    (void)InstancePtr; (void)Int_Id; (void)Handler; (void)CallBackRef;
    return XST_SUCCESS;   /* tick IRQ is routed in zynq.c's vApplicationIRQHandler */
}

void XScuGic_Enable(XScuGic *InstancePtr, u32 Int_Id)  { (void)InstancePtr; (void)Int_Id; }
void XScuGic_Disable(XScuGic *InstancePtr, u32 Int_Id) { (void)InstancePtr; (void)Int_Id; }

/* the port's prvTaskExitError logs via xil_printf; we don't need it. */
int xil_printf(const char *fmt, ...) { (void)fmt; return 0; }
