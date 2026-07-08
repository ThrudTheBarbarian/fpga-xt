# cdc_video_sleep.xdc — the clk_pix BUFGCE enable (pix_clk_ce) is driven by the
# clk_sys register gp0_ctrl[5] (the video-sleep bit).  It changes only when the
# A9 toggles display sleep — an async, rarely-changing control into the pixel
# clock's gate.  BUFGCE switches glitch-free on it, so don't time the crossing.
set_false_path -to [get_pins -hier -filter {NAME =~ *u_bufg_pix/CE}]
