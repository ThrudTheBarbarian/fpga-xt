/* xemacps_g.c — GEM0 config table + LookupConfig for the vendored xemacps
 * driver (SDT flavour; the BSP normally generates this). One device: the
 * Z-Turn's PS GEM0 at 0xE000B000, RGMII to the on-SOM KSZ9031 PHY (address
 * discovered by MDIO scan at init, so PhyAddr here is a hint only). The
 * S* dividers are the SLCR GEM0_CLK_CTRL divisors for each line rate off the
 * 1000 MHz IO PLL (125 / 25 / 2.5 MHz). */
#include "xemacps.h"

XEmacPs_Config XEmacPs_ConfigTable[] = {
    {
        .Name                   = "gem0",
        .BaseAddress            = 0xE000B000u,
        .IsCacheCoherent        = 0,
        .IntrId                 = 54,
        .IntrParent             = 0,
        .RefClk                 = 0,
        .PhyType                = "rgmii-id",
        .PhyAddr                = 0,
        .MdioProducerBaseAddr   = 0xE000B000u,
        .GmiitoRgmiiConvPhyAddr = 0,
        .S1GDiv0   = 8,  .S1GDiv1   = 1,
        .S100MDiv0 = 8,  .S100MDiv1 = 5,
        .S10MDiv0  = 8,  .S10MDiv1  = 50,
    },
};

XEmacPs_Config *XEmacPs_LookupConfig(UINTPTR BaseAddress)
{
    if (!BaseAddress || BaseAddress == XEmacPs_ConfigTable[0].BaseAddress)
        return &XEmacPs_ConfigTable[0];
    return (XEmacPs_Config *)0;
}
