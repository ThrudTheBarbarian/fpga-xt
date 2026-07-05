/*
 * localoptions.h - XTOS Dropbear feature config (server, pubkey auth).
 *
 * Overrides src/default_options.h (Dropbear includes this first when built with
 * -DLOCALOPTIONS_H_EXISTS). Kept OUTSIDE the submodule tree and found via
 * -I dropbear-config, so the submodule stays a pristine upstream checkout.
 *
 * Server build only (we compile the svr and common file set). Deliberately
 * minimal: public-key auth only (no crypt on XTOS), and no forwarding, agent or
 * X11, to shrink the port and avoid facilities we do not have yet.
 */
#ifndef XTOS_LOCALOPTIONS_H
#define XTOS_LOCALOPTIONS_H

/* auth: public-key only (crypt() is absent, so no password hashing) */
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH   1

/* no forwarding / agent / X11 (smaller, and no plumbing yet) */
#define DROPBEAR_SVR_AGENTFWD      0
#define DROPBEAR_SVR_LOCALTCPFWD   0
#define DROPBEAR_SVR_REMOTETCPFWD  0
#define DROPBEAR_X11FWD            0

/* the shell search path on XTOS */
#define DEFAULT_PATH "/System/bin:/OS/bin:/bin"

/* accepted login shells (dropbear's getusershell falls back to this list when /etc/shells
 * is absent). XTOS's shell is /System/bin/sh — without this, login is "invalid shell". */
#define COMPAT_USER_SHELLS "/System/bin/sh", "/OS/bin/sh", "/bin/sh"

#endif
