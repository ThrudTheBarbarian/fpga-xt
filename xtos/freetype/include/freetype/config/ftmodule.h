/*
 * ftmodule.h — TRIMMED module list for the fpga-xt A9 build.
 *
 * Only the modules needed to load + render scalable TrueType / OpenType-CFF
 * fonts with variable-font (MM) + kerning + sfnt-name support (what gem/font.c
 * uses).  Dropped: type1, cid, pfr, type42, winfonts, pcf, bdf, sdf, svg.
 * Must match the wrapper TUs compiled under xtos/freetype/tu/.
 */

FT_USE_MODULE( FT_Module_Class,    autofit_module_class )
FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class,    psaux_module_class )
FT_USE_MODULE( FT_Module_Class,    psnames_module_class )
FT_USE_MODULE( FT_Module_Class,    pshinter_module_class )
FT_USE_MODULE( FT_Module_Class,    sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class,  ft_smooth_renderer_class )
FT_USE_MODULE( FT_Renderer_Class,  ft_raster1_renderer_class )

/* EOF */
