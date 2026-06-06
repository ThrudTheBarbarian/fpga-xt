# xtos/Makefile — XTOS host build (the OS layer that boots into the GEM desktop).
# Starts with the vendored Lua library + a smoke test.  The A9/FreeRTOS build
# will reuse lua/ with a freestanding luaconf.

BUILD   := build
CC      := cc
CFLAGS  := -std=c99 -O2 -g -Ilua

# Lua library = every src file except the two standalone mains (lua.c / luac.c).
LUA_SRC := $(filter-out lua/lua.c lua/luac.c,$(wildcard lua/*.c))
LUA_OBJ := $(addprefix $(BUILD)/,$(LUA_SRC:.c=.o))

.PHONY: all lua test clean
all: $(BUILD)/liblua.a

$(BUILD)/liblua.a: $(LUA_OBJ)
	ar rcs $@ $^

$(BUILD)/%.o: %.c | $(BUILD)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

# Smoke test: embed Lua, run a script.
$(BUILD)/lua_test: lua_test.c $(BUILD)/liblua.a
	$(CC) $(CFLAGS) $< $(BUILD)/liblua.a -lm -o $@
test: $(BUILD)/lua_test
	./$(BUILD)/lua_test

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)
