# Implementing GEM

The next piece I'd like to tackle is some foundational work on the GEM desktop. There's lots yet to do on the 'X' of XT but it'll be easier to get working if the environment is easy to work with on the device.

So, we need to

* Create a linked GEM library which handles all the VDI calls and at least some AES calls too
* Integrate Lua into XTOS
* Boot up and configure any runtime settings then launch Desktop.app as the last stage of that boot
* Allow user interaction. First gate would be to enclose the XL in a window that can be dragged around/resized etc.


## Approach (decided 2026-06-05)

Foundation-first, host-iterated. The mouse (RP2354) gates nothing — we build and test the whole desktop, window manager and interaction on the host first.

**Portable C core + thin backend.** The GEM service (VDI, AES, window manager, theming, layout) is platform-neutral C. The only platform-specific part is a small backend of low-level surface primitives — `fill_rect`, `blit`, `line`, `text` onto an RGBA-8888 surface:

* **SDL backend (host):** software primitives, surface shown in an SDL window. Sub-second iterate, no FPGA build — for algorithms, the artwork/theme do-test-redo loop, layout, and (because SDL gives us a mouse) the full event/window-manager interaction.
* **A9 backend (target):** the same C, primitives routed to the hardware blitter; surface is a DDR3 plane the compositor scans out.

So the RP2354 is never a blocker — it becomes a late input-backend swap (SDL mouse → RP2354), and HDMI a surface-backend swap.

**Compositing — one live surface, DDR3 backing-store windows.** Hard rule (from the XL-flicker DMA-contention work): never make a window a live compositor plane. Exactly one live desktop surface (HP0) + the XL plane (HP3) + a small pointer plane. Each window owns an off-screen DDR3 buffer; on expose the WM blits it into the desktop surface (blitter, HP1, on-demand only — no steady-state read traffic, so no new flicker). `WM_REDRAW` is still delivered (real GEM apps expect it; can be made optional). Standard backing-pixmap technique — faithful to the ABI, less app work not more.

**ST ABI = the trap is the doorbell.** We own TRAP on the emulated m68k, so the TRAP-#2 handler grabs the app's native `contrl/intin/...` param-block pointer and marshals it to the service — no drawing in the trap path. It's a hook in the m68k JIT dispatch, so it lands with the m68k window and does not constrain the core now. 6502 and XTOS-native clients use our binding into the same service.

**Code layout.** Portable core + backends under `gem/`; the SDL testbed builds on the host (`gem/Makefile`).

**Milestone 1:** static XL framed in a (later-draggable) window on a desktop background, drawn entirely through the VDI doorbell — the whole spine (service ABI → minimal VDI → compositor windowing of the XL plane) with no fonts/themes/events/mouse.

**Sequence:** portable C GEM core + SDL testbed → minimal VDI → desktop + window-manager + theming (mouse and all, on SDL) → A9/RP2354 backend swaps.


## GEM

This is a reasonably large task, needs to be cognisant of the two calling conventions (m68k, 6502) but those are relatively simple (TRAP # on 68k, poke-addresses on 6502), so should be easy to unify.

The easiest option is probably a port of the VDI part of EmuTOS but that comes entangled with a GPL restriction I'm not sure we want to buy into. Thus far I think we're restriction-free in terms of licensing.

So a clean implementation then. The API is well documented, the goal is simply to be compatible. Things to note:

* We use a 32-bit ARGB format, GEM is mainly focused on 8-bit LUT-based colours. Atari did release a 16-bit computer (the Falcon) that supported a direct-mapped framebuffer, so we should be able to generalise that.
* we need to implement the 'pen' approach anyway, so we should use one of the standard (eg NVDI/FVDI) palettes that are currently in use for those 256 pens rather than invent our own
* GEM is mainly planar-based graphics, whereas we're bitmap-based, there are methods to convert between the portable planar-based and host-based formats, and we should make sure those are efficient
* NVDI, fVDI etc have expanded the GEM interface calls, we should support those. Not really interested in supporting the VT52 opcodes at this level though, those seem Atari-ST/TT specific, and can be handled inside the m68k emulation window
* Use the blitter as much as possible

### Fonts

We need a font story. I think the best way forward is to incorporate (simpler, less capable) [libttf](https://github.com/tayoky/libttf) or 
[libfreetype](https://freetype.org/freetype2/docs/index.html) and then, on handling a font-based api call, render the font to a bitmap cache at a particular size, and use it thereafter. Fonts can be stored in OS/Fonts.

We specify a system font as part of the GEM configuration, possibly a boot-time parameter (in 70.GEM) or possibly via a settings panel. If no systme font is specified, we use the first font we find in OS/Fonts.

If a font is requested with (say) italic presentation, the plan would be to look for the italic version of the font-file, and if found use it. If not found, we apply the italic slanting effect to the normal font. If the normal font is not found, we use the system font.

### Themes

I'd like to make the GEM environment theme-able, so it can be customised more easily later. This comes down to a class that looks for the default theme (specified alongside the default font) and then looks for OS/Themes/<theme-dir>/{artwork.png,locations.txt} to find which bitmap rectangles correspond to which known type of artwork (window title-bar, scrollbar-top/thumb/background/bottom etc.) Then it's just a matter of blitting the right bitmaps.

If a default theme isn't set, then we use the first directory we come across in OS/Themes/

We can use the [Aristo2](https://github.com/cappuccino/cappuccino/tree/main/AppKit/Themes/Aristo2) resources (I checked with the developer) to make the look-and-feel nice and pretty, better than original GEM anyway. 



## Integrate Lua

Lua is designed to be an embedded language. We should integrate it as our scripting language, and bind OS services to a Lua object("os"), that way we can write scripts that interact with the OS by calling methods on the 'os' object.

We could also bind the GEM layer as another Lua object ("gem") which would open up creation of system-level dialogues and options from a scripting language, making them far more flexible.


## Boot up

I think we borrow from the unix world for this, with a few tweaks. Eventually I'll want things like networking setup to be done here, but for the time being the only thing we'll be launching is the Desktop.app task.

Still, we should be flexible because boot-up is something that comes back to bite you if it's not sufficiently so.

Proposal: 

* Have a directory on the SD card (implies FAT32) called OS
* Inside there, have a directory called Boot
* Inside there, have Lua scripts of the form xx.<reason> eg: 50.network
* Scan, sort, and run the scripts in numeric xx order
* Last script is 99.Desktop

99.desktop can be as simple as 
```
if not os.isrunning("desktop") os.launch("desktop")
```


## User Interaction

So this is where we start to rely on mouse movement (which needs the RP2354-based USB interface) as well as have the AES window support, and controls built into the window for resize/scale (for emulator windows)/iconise etc.

This is the final gate for the baseline GEM integration

