#!/bin/sh
-- A shell script: Lua for logic, bare words to run programs.
-- Foreground commands run to completion before the script continues;
-- append '&' to launch one in the background.
print("[sh] hello — " .. _VERSION .. ", 2+2=" .. (2 + 2))
hello
print("[sh] the command finished; back in the script")
