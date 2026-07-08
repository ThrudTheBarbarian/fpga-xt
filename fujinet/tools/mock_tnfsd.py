#!/usr/bin/env python3
"""Minimal TNFS server for testing libfujinet — serves one local directory.

Usage: mock_tnfsd.py <root-dir> [port] [--drop N]   (--drop: drop every Nth
datagram to exercise the client's retry path)

Implements: MOUNT UMOUNT OPENDIR READDIR CLOSEDIR MKDIR RMDIR OPEN READ
WRITE CLOSE STAT LSEEK UNLINK RENAME SIZE FREE. Single session, UDP only.
"""
import os
import socket
import stat as statmod
import struct
import sys

OK, ENOENT, EBADF, EINVAL, EOF_, EHANDLE = 0x00, 0x02, 0x06, 0x0E, 0x21, 0xFF

root = os.path.realpath(sys.argv[1])
port = int(sys.argv[2]) if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else 16384
drop_every = 0
if "--drop" in sys.argv:
    drop_every = int(sys.argv[sys.argv.index("--drop") + 1])

session = 0xBEEF
dirs = {}    # handle -> list of remaining names
files = {}   # handle -> file object
next_dh, next_fh = 1, 1
rx_count = 0


def localpath(p):
    joined = os.path.realpath(os.path.join(root, p.lstrip("/")))
    if not joined.startswith(root):
        raise FileNotFoundError(p)
    return joined


def cstr(data, off):
    end = data.index(0, off)
    return data[off:end].decode("utf-8", "replace"), end + 1


def handle(cmd, body):
    """Returns reply payload starting with the status byte."""
    global next_dh, next_fh
    try:
        if cmd == 0x00:  # MOUNT
            return bytes([OK]) + struct.pack("<HH", 0x0102, 100)
        if cmd == 0x01:  # UMOUNT
            return bytes([OK])
        if cmd == 0x10:  # OPENDIR
            path, _ = cstr(body, 0)
            names = sorted(os.listdir(localpath(path)))
            dh = next_dh
            next_dh += 1
            dirs[dh] = names
            return bytes([OK, dh])
        if cmd == 0x11:  # READDIR
            dh = body[0]
            if dh not in dirs:
                return bytes([EHANDLE])
            if not dirs[dh]:
                return bytes([EOF_])
            return bytes([OK]) + dirs[dh].pop(0).encode() + b"\0"
        if cmd == 0x12:  # CLOSEDIR
            dirs.pop(body[0], None)
            return bytes([OK])
        if cmd == 0x13:  # MKDIR
            path, _ = cstr(body, 0)
            os.mkdir(localpath(path))
            return bytes([OK])
        if cmd == 0x14:  # RMDIR
            path, _ = cstr(body, 0)
            os.rmdir(localpath(path))
            return bytes([OK])
        if cmd == 0x29:  # OPEN
            flags, mode = struct.unpack("<HH", body[0:4])
            path, _ = cstr(body, 4)
            m = {1: "rb", 2: "wb", 3: "r+b"}[flags & 3]
            if flags & 0x0100 and not os.path.exists(localpath(path)):
                open(localpath(path), "ab").close()
            if flags & 0x0200:
                m = "wb" if (flags & 3) == 2 else "w+b"
            fh = next_fh
            next_fh += 1
            files[fh] = open(localpath(path), m)
            return bytes([OK, fh])
        if cmd == 0x21:  # READ
            fh, want = body[0], struct.unpack("<H", body[1:3])[0]
            if fh not in files:
                return bytes([EBADF])
            data = files[fh].read(want)
            if not data:
                return bytes([EOF_])
            return bytes([OK]) + struct.pack("<H", len(data)) + data
        if cmd == 0x22:  # WRITE
            fh, n = body[0], struct.unpack("<H", body[1:3])[0]
            if fh not in files:
                return bytes([EBADF])
            files[fh].write(body[3:3 + n])
            return bytes([OK]) + struct.pack("<H", n)
        if cmd == 0x23:  # CLOSE
            f = files.pop(body[0], None)
            if f:
                f.close()
            return bytes([OK])
        if cmd == 0x24:  # STAT
            path, _ = cstr(body, 0)
            st = os.stat(localpath(path))
            # fixed 22 bytes; like tnfsd, no trailing uid/gid strings
            return bytes([OK]) + struct.pack(
                "<HHHIIII", st.st_mode & 0xFFFF, 0, 0,
                st.st_size & 0xFFFFFFFF, int(st.st_atime) & 0xFFFFFFFF,
                int(st.st_mtime) & 0xFFFFFFFF, int(st.st_ctime) & 0xFFFFFFFF,
            )
        if cmd == 0x25:  # LSEEK
            fh, whence = body[0], body[1]
            off = struct.unpack("<i", body[2:6])[0]
            if fh not in files:
                return bytes([EBADF])
            files[fh].seek(off, whence)
            return bytes([OK]) + struct.pack("<I", files[fh].tell())
        if cmd == 0x26:  # UNLINK
            path, _ = cstr(body, 0)
            os.unlink(localpath(path))
            return bytes([OK])
        if cmd == 0x28:  # RENAME
            src, off = cstr(body, 0)
            dst, _ = cstr(body, off)
            os.rename(localpath(src), localpath(dst))
            return bytes([OK])
        if cmd == 0x30:  # SIZE
            return bytes([OK]) + struct.pack("<I", 1024 * 1024)
        if cmd == 0x31:  # FREE
            return bytes([OK]) + struct.pack("<I", 512 * 1024)
        return bytes([EINVAL])
    except (FileNotFoundError, NotADirectoryError):
        return bytes([ENOENT])
    except KeyError:
        return bytes([EINVAL])


def process(pkt):
    global rx_count
    rx_count += 1
    if drop_every and rx_count % drop_every == 0:
        return None
    if len(pkt) < 4:
        return None
    seq, cmd = pkt[2], pkt[3]
    return struct.pack("<HBB", session, seq, cmd) + handle(cmd, pkt[4:])


import selectors

sel = selectors.DefaultSelector()
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(("127.0.0.1", port))
tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
tcp.bind(("127.0.0.1", port))
tcp.listen(4)
sel.register(udp, selectors.EVENT_READ, "udp")
sel.register(tcp, selectors.EVENT_READ, "listen")
print(f"mock tnfsd: serving {root} on udp+tcp/{port}"
      + (f", dropping every {drop_every}th packet" if drop_every else ""),
      flush=True)

while True:
    for key, _ in sel.select():
        if key.data == "udp":
            pkt, addr = udp.recvfrom(2048)
            reply = process(pkt)
            if reply is not None:
                udp.sendto(reply, addr)
        elif key.data == "listen":
            conn, _ = tcp.accept()
            sel.register(conn, selectors.EVENT_READ, "conn")
        else:
            pkt = key.fileobj.recv(2048)
            if not pkt:
                sel.unregister(key.fileobj)
                key.fileobj.close()
                continue
            reply = process(pkt)
            if reply is not None:
                key.fileobj.sendall(reply)
