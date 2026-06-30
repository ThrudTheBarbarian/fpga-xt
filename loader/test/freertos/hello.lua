#!/bin/sh
-- hello.lua — smoke test for init + the Lua shell (/System/bin/sh). Lua skips the
-- shebang line. Exercises base/string/math + spawn() (PL0 -> SYS_spawn -> a program).
print("[lua] hello from " .. _VERSION .. ", 2+2=" .. (2 + 2) .. ", sqrt(2)=" .. string.format("%.4f", math.sqrt(2)))
print("[lua] sh works; spawning hello...")
spawn("hello")
