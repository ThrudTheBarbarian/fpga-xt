---
title: Statements & control flow
description: Variable declarations, if, switch, for, for-in (array and range), while, break, continue, :unroll.
---

## Variable declarations

```c
u8  myVal;
u8  myVal = 5;
u8  a, b = 1, 2;            // a = 1, b = 2

u8  bytes[32];              // array
u8  rgb[]   = {255, 0, 0};  // size inferred from initialiser
RGB white   = {255, 255, 255};
RGB white   = [255, 255, 255]; // [..] is interchangeable with {..}
```

You may also initialise the **raw bytes** of any value, regardless of its type, using the brace / bracket form. Trailing missing bytes are zero-filled.

### Storage modifiers

| Modifier | Storage | Persistence | Visibility | ZP cost |
|----------|---------|-------------|-------------|---------|
| *(default)* | ZP | local scope | current block | yes |
| `register` | ZP (priority) | local scope | current block | yes (forced) |
| `volatile` | ZP | local scope | current block | yes |
| `static` | data section | permanent | current file or block | no |
| `global static` | data section | permanent | every file | no |

Examples:

```c
volatile u16@ dosvec = @10;       // both stores happen, even at -O2+
register u16@ hot = $1234;        // priority on ZP allocation
static  u16  hits = 0;            // persists across calls; file-scoped
global static u16 totalHits = 0;  // persists, visible everywhere
```

`register` is a hint to the zero-page allocator: the compiler scans for these before ordinary allocation, so they get first pick of the ZP slots. `volatile` disables the optimiser's store-elimination — every read and write becomes an actual memory access.

`typedef <type> alias;` introduces a type alias; see [Types → Type aliases](/compiler/language/types/#type-aliases-typedef).

## If / else

```c
if (x > 10) {
    Stdio.print("big\n");
} else if (x > 5) {
    Stdio.print("medium\n");
} else {
    Stdio.print("small\n");
}
```

The condition is in round brackets; the body is a block (`{ }` or `(( ))`). `else` is optional.

## Switch

```c
switch (c) {
    case ..12:
        // any value <= 12
        break;

    case 13..18:
        // 13, 14, 15, 16, 17, 18
        break;

    case 22:        // fall through
    case 23:
        myFunction(c);
        break;

    case 40..:
        // any value >= 40
        break;

    default:
        Stdio.printf("nope\n");
        break;
}
```

`switch` extends C's form with **range cases** — `..N`, `M..N`, and `N..` cover "less than or equal", inclusive ranges, and "greater than or equal". Range cases are only available on `u8` arguments; non-range cases (single values, fall-through) work on any integer.

At `-O2` and above the compiler may emit a jump-table for dense switches.

## C-style `for`

```c
for (u8 i = 0; i < 40; i++) {
    Stdio.printInt(i);
}
```

The setup may declare a new loop variable; if so, that variable goes out of scope when the loop terminates. All three clauses (setup / condition / step) are optional.

## For-in (iterate over array)

```c
u8 chars[] = {'h', 'e', 'l', 'l', 'o'};
for (u8 ch in chars) {
    Stdio.printByte(ch);
}
```

The collection may be either:

- A fixed-size array (length is known at compile time), or
- A heap-allocated pointer from `new T[N]` (length is read from the allocator's block header at loop entry, so deep recursion or re-allocation inside the body doesn't perturb the iteration count).

The loop variable's type is normally given explicitly (`u8 ch in ...`); `auto` works too if you'd rather have the compiler infer it.

## For-in (range)

The for-in collection slot also accepts an integer range. Two forms cover the natural readings:

```c
for (u8 i in 0..10)  { ... }   // exclusive: 0, 1, …, 9   (10 iters)
for (u8 i in 0...10) { ... }   // inclusive: 0, 1, …, 10  (11 iters)
```

`..` (two dots) is **exclusive** — the end value is *not* visited. `...` (three dots) is **inclusive** — the end value *is* visited. Same convention as Rust.

### Stride and direction: `step`

An optional `step <signed-int-literal>` clause sets the increment:

```c
for (u8 i in 0..10 step 2)    { ... }   // 0, 2, 4, 6, 8
for (u8 i in 0...10 step 2)   { ... }   // 0, 2, 4, 6, 8, 10
for (u8 i in 10..0 step -1)   { ... }   // 10, 9, …, 1
for (u16 i in 100..0 step -5) { ... }   // 100, 95, …, 5
```

The step must be a compile-time integer literal (a bare integer or its negation; expressions are not folded here). A negative step makes the loop descend.

When both bounds are integer literals **and** `start > end` and no explicit step is given, the loop auto-flips to descending with `step -1`:

```c
for (u8 i in 10..0)   { ... }   // 10, 9, …, 1   (auto-flip, step -1)
for (u8 i in 10...0)  { ... }   // 10, 9, …, 0   (auto-flip, step -1, inclusive)
```

For non-literal bounds, the loop is ascending unless you write `step -N` explicitly:

```c
u8 from = 8;
u8 to   = 3;
for (u8 i in from..to step -1) { ... }   // runtime descending
```

Inconsistent combinations (e.g. `0..10 step -1`, where the body would never run) are rejected at parse time.

### Type inference

When no loop type is given, the compiler defaults to `u8` if both bounds and the step magnitude are `u8`-fitting integer literals:

```c
for (i in 1..4) { ... }           // i: u8 (auto)
for (i in 0..1000) { ... }        // ERROR: needs explicit type — bound > 255
```

Anything else — non-literal bound, literal beyond 255, large step — requires an explicit type. The parser doesn't run sema's full constant-folding, so this stays a surface-level check rather than full type inference.

### Caveat: unsigned descending and underflow

Descending unsigned loops with a step that doesn't divide evenly into the start can wrap past 0 and run longer than expected. For example, `for (u8 i in 20..0 step -3)` walks 20, 17, 14, 11, 8, 5, 2 — then `2 - 3` wraps to 255 and the loop continues from there.

Avoid by either aligning the bounds with the step (`21..0 step -3`) or widening the loop variable to `u16` / `i16`.

### Lowering

The range form is rewritten to an equivalent C-style `for` at parse time, so all existing optimisation paths (`:unroll`, the loop unroller, pointer induction) apply:

| Source                                     | Equivalent C-style                            |
|--------------------------------------------|-----------------------------------------------|
| `for (T i in 0..N)`                        | `for (T i = 0; i < N; i += 1)`                |
| `for (T i in 0...N)`                       | `for (T i = 0; i <= N; i += 1)`               |
| `for (T i in 0..N step 2)`                 | `for (T i = 0; i < N; i += 2)`                |
| `for (T i in N..0)`     *(literal bounds)* | `for (T i = N; i > 0; i -= 1)`                |
| `for (T i in N..0 step -3)`                | `for (T i = N; i > 0; i -= 3)`                |

## For-in (array slice)

The for-in array form also accepts a range expression *inside* the subscript, producing a slice — a sub-range view that the loop walks element-by-element:

```c
u8 arr[10] = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };

for (u8 v in arr[2..5])  { ... }   // 30, 40, 50         (m..n exclusive)
for (u8 v in arr[2...4]) { ... }   // 30, 40, 50         (m...n inclusive)
for (u8 v in arr[..3])   { ... }   // 10, 20, 30         (open start = 0)
for (u8 v in arr[7..])   { ... }   // 80, 90, 100        (open end = arr.length)
```

The base may be either a fixed-size array or a heap-allocated pointer from `new T[N]`; for heap pointers the open-end form (`buf[m..]`) reads `.length` from the heap-block header at loop entry, same as the plain `for (u8 v in buf)` form.

Bounds can be any integer expression — they don't have to constant-fold:

```c
u8 from = 2;
u8 to   = 7;
for (u8 v in arr[from..to]) { ... }  // 30, 40, 50, 60, 70
```

The codegen lowers the slice to a counted iteration with the counter starting at `m` (or 0) and exiting when it would reach `n` (or the base's `.length`). Inclusive form biases the cap by +1 at loop setup so the inner compare stays a plain `idx < cap` — no per-iteration branch difference between `..` and `...`.

Slice expressions are only valid as the iterable of a `for-in` loop today. Passing a slice to a function or storing it in a variable would need a first-class slice value type (a fat pointer with length); that's a separate, deferred feature.

## While

```c
while (running) {
    tick();
}
```

Standard — the body runs while the condition evaluates to non-zero.

## Loop control: break and continue

`break` exits the enclosing loop. `continue` skips the rest of the current iteration and jumps to the loop's increment / re-test.

```c
for (u8 i = 0; i < n; i++) {
    if (skip[i]) continue;
    if (i == limit) break;
    process(i);
}
```

## `defer`

`defer { ... }` registers a block to run when the **enclosing scope** exits — by any path: fall-through, `return`, `break`, `continue`, or a propagating [`throw`](/compiler/language/errors/). It is the cleanup statement: you write the release next to the acquisition instead of at the bottom of the function, and every exit path gets it for free.

```c
void render(Scene@ s) {
    s.lock();
    defer { s.unlock(); }             // released however we leave

    if (!s.visible) return;           // …here
    if (s.clipped)  return;           // …or here
    s.drawEverything();               // …or by falling off the end
}
```

The body must be a block. It runs at several exit points, so the braces keep what is deferred unambiguous.

### LIFO, and per-scope

Multiple defers in one scope run **last-registered-first**, and each defer belongs to the block that registered it — an inner `{ }` runs its own defers at its closing brace, not at function exit.

```c
{
    defer { Stdio.printf("A\n"); }
    defer { Stdio.printf("B\n"); }
    Stdio.printf("body\n");
}
// body
// B
// A
```

Inside a loop body, the defer runs at the end of **each iteration** — including the iteration that `break`s or `continue`s out.

```c
for (u32 i = (u32)0; i < (u32)3; i = i + (u32)1) {
    defer { Stdio.printf("d%d\n", i); }
    if (i == (u32)1) break;
}
// d0
// d1
```

### It runs before the scope's ARC releases

The ordering that makes `defer` useful: a scope exits by running **its defers first**, then its [ARC teardown](/compiler/language/memory/#automatic-reference-counting-arc), then moving outward to the next scope. So the body can still use the very local it was written to clean up.

```c
{
    Res@ r = new Res((u32)7);
    defer { Stdio.printf("defer sees id=%d\n", r.id); }
}
// defer sees id=7
// dealloc 7
```

### No closures involved

`defer` is a **statement, not a value**. Its body is lowered inline at each exit point of the scope that registered it — nothing is captured, nothing is allocated, there is no object to keep alive. It reads the enclosing scope's locals directly because it is emitted *in* that scope. That is how a language with no closures gets `defer` at zero cost, on every backend including the 6502.

Two consequences fall out of that, and both are enforced:

- **`return` inside a defer body is rejected.** The body runs at every exit of its scope, so there is no single return for it to perform.
- **A `break` or `continue` that would *leave* the body is rejected.** A `break` inside a loop or `switch` written *within* the body is fine — it targets that construct.

```c
defer { return; }                       // error
defer { break; }                        // error (inside a loop's scope)
defer { for (…) { … break; } }          // fine — the break is the inner loop's
```

## Manual unrolling: `:unroll`

The auto-unroller runs at `-O2+` for counted `for` loops with a small trip count (default ≤5; tunable with `-Flu`). To force an unroll regardless of trip count or optimisation level, annotate the loop with `:unroll`:

```c
for (u8 i = 0; i < 40; i++) :unroll {
    poke(scrn + i, ' ');
}
```

The annotation goes after the closing `)` of the `for` clause and before the body. Apply it sparingly — every unroll trades binary size for cycle count.

## Program entry: `main`

Execution begins at `main`. Two signatures are accepted:

```c
void main(void) {
    // …
}

i16 main(u8 numArgs, string args[]) {
    // …
}
```

When `main` returns, the program issues an `RTS` to the caller — unless you pass `-Q loop` on the command line, in which case the runtime spins in an infinite loop instead.
