---
title: Errors — throws, try & catch
description: "Checked error propagation: the throws effect, throw, typed and untyped catch arms, the Error protocol, and how errors interact with defer and ARC."
---

xtc's error model is **checked propagation**, not stack unwinding. A function that can fail says so on its signature; `throw` runs the scope teardown and returns; a call to such a function tests an error channel and either branches to a `catch` or propagates. The cost is a test-and-branch per throwing call — paid only where something can actually fail.

That choice is what makes the feature portable. Table-driven unwinding would need per-backend CFI tables, personality routines and an unwinder — machinery a banked 6502 with a 4 KB hardware stack cannot realistically carry. Checked propagation needs nothing the IR didn't already have (calls, compares, branches, returns), so every backend gets it at once, xt6502 included.

## The shape of it

```c
#import <Error.xt>

class ParseError <Error>
{
    String@ msg;
    void init(String@ m)  { msg = m; }
    String@ message(void) { return msg; }
}

i32 parseDigit(u8 ch) throws
{
    if (ch < '0' || ch > '9')
        throw new ParseError(String.withCString("not a digit"));
    return (i32)(ch - '0');
}

void main(void)
{
    try {
        i32 n = parseDigit('7');
        Stdio.printf("n=%d\n", n);
    }
    catch (ParseError e) { Stdio.printf("parse: %s\n", e.message().cString()); }
    catch (e)            { Stdio.printf("other error\n"); }
}
```

## The `Error` protocol

An error is an ordinary heap object — not a new kind of value. It conforms to `Error`, which has exactly one requirement:

```c
protocol Error
{
    String@ message(void);
}
```

One requirement means a handler can always say something useful about what it caught without knowing the concrete type. Everything else comes free from machinery the language already has: errors are classes, so they use protocols, ARC and the RTTI downcast rather than a mechanism sitting beside them.

`Error.xt` lives in `support/generic/lib/`. It is **not** part of the `Foundation.xt` umbrella — import it explicitly.

Errors follow ARC like anything else. A caught error is a strong local, released at the end of its `catch` scope.

## `throws` — the effect on the signature

`throws` goes between the parameter list and the body, after any function annotations:

```c
i32 parse(String@ s) throws { … }
void reload(void) :main throws { … }
```

Under the hood a `throws` function gains one hidden trailing out-parameter. `throw` stores the error through it and returns; the caller tests it after the call. The return value on the throwing path is indeterminate — the generated check guarantees you never read it.

### Calling a `throws` function is checked

A call to a `throws` function must be **either** inside a `try` **or** inside a function that is itself `throws`. Anything else is a sema error naming the callee and both fixes:

```
'readCount' is declared 'throws' — wrap the call in try { } catch (e) { },
or declare the caller 'throws' to propagate
```

That is the whole point of the checked model: the test-and-branch stays off every non-throwing call, and the compiler tells you where failure can reach.

Propagation needs no syntax. A `throws` function that calls another `throws` function without a `try` simply forwards the error to *its* caller:

```c
i32 middle(u32 n) throws { i32 v = inner(n); return v + (i32)1; }
```

:::caution[`throws` is for free functions today]
The keyword parses on a class method, but the effect flag is not carried onto the method declaration, so a `throw` inside a method body is rejected with *"'throw' in a function not declared 'throws'"*. Put throwing work in free functions for now.
:::

## `throw`

```c
throw new IOError(String.withCString("cannot open"));
```

`throw` evaluates its operand, stores it into the error channel, then runs every enclosing scope's [`defer`](/compiler/language/statements/#defer) bodies and ARC teardown on the way out — the same walk an early `return` performs. A propagating throw *is* an exit path, so nothing about scope cleanup is special-cased.

The operand should conform to `Error`. That is not yet enforced — **any class pointer is accepted today** — so a handler calling `message()` on something that has no such method is a bug you meet at the handler, not at the `throw`. Conform to `Error` anyway; it is the contract every untyped `catch` is written against.

## `try` / `catch`

```c
try   { … }
catch (IOError e) { … }        // typed arm
catch (ParseError e) { … }     // another typed arm
catch (e) { … }                // untyped catch-all
```

A `try` block must be followed by at least one `catch`. Arms are tested **in source order**:

- A **typed** arm runs only when the in-flight error really is an instance of that class. The test is the same RTTI conformance check that [`(T@ ?)obj`](/compiler/language/inheritance/#downcasts--runtime-checked) uses, so it works across a `.so` boundary for free. Inside the arm, the binder is already narrowed to that class — `e.message()` resolves directly against it.
- An **untyped** arm catches everything. Its binder is `Object@`, the most general reference, so reaching a specific class's members needs a cast.
- If **no** arm matches, the error keeps propagating — out to an enclosing `try`, or out of the function if it is `throws`.

Note the class name in a typed arm carries **no** `@`: it is `catch (IOError e)`, not `catch (IOError@ e)`.

### Unreachable arms are a warning

An arm shadowed by an earlier, broader one can never run, and the compiler says so:

```
this 'catch' can never run — an earlier arm already catches everything
```

It is a warning, not an error — silence it with `-Wno-unreachable-catch` if you have a reason to keep the dead arm (a signature you intend to fill in, say).

## A worked example

Using the `ParseError` class from the top of the page:

```c
i32 inner(u32 n) throws
{
    defer { Stdio.printf("  inner-defer\n"); }
    if (n == (u32)1) throw new ParseError(String.withCString("deep"));
    return (i32)7;
}

// No try here: the error propagates out to our caller.
i32 middle(u32 n) throws { i32 v = inner(n); return v + (i32)1; }

void main(void)
{
    try { i32 a = middle((u32)0); Stdio.printf("ok a=%d\n", a); }
    catch (e) { Stdio.printf("UNEXPECTED\n"); }

    try { i32 b = middle((u32)1); Stdio.printf("UNEXPECTED b=%d\n", b); }
    catch (e) { Stdio.printf("caught: %s\n", ((ParseError@)e).message().cString()); }
}
```

```
  inner-defer
ok a=8
  inner-defer
caught: deep
```

The defer fires on both paths — once on the ordinary return, once on the throw — and `middle` forwards the error without a line of handling code.

## What there is no such thing as

- **No `finally`.** [`defer`](/compiler/language/statements/#defer) subsumes it and is more useful: it attaches cleanup to the thing being cleaned up rather than to a block at the bottom of the function.
- **No throwing from a `defer` body.** A defer running during propagation would have nowhere to send a second error, so this is forbidden rather than defined.
- **No unchecked errors.** There is no way to call a `throws` function and ignore the possibility. That is the trade: annotation churn up the call chain, in exchange for the compiler knowing exactly where failure flows.

## What's next

- [Statements & control flow → `defer`](/compiler/language/statements/#defer) — the cleanup half of this design.
- [Inheritance & protocols](/compiler/language/inheritance/) — protocols and the failable downcast the typed arms are built on.
- [Heap, ARC & weak refs](/compiler/language/memory/) — how a caught error's lifetime is managed.
