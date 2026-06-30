-- hello.lua — smoke test for the embedded Lua runner (/System/bin/boot).
-- Exercises base + string + table + math; spawn() is recorded by the kernel.
print("[lua] hello from " .. _VERSION .. ", 2+2=" .. (2 + 2))
local sq = {}
for i = 1, 4 do sq[i] = i * i end
print("[lua] squares: " .. table.concat(sq, " ") .. ", sqrt(2)=" .. string.format("%.4f", math.sqrt(2)))
print("[lua] (a fresh lua_State per /OS/Boot file; spawn(\"name\") launches /System/bin/name)")
