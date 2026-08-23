---
title: Bound methods & callbacks
description: The ^ type — a receiver and a code address travelling together, so a callback needs no context pointer and no cast.
---

> Since 0.4 the language also has [blocks](/compiler/language/blocks/) —
> function values that capture arbitrary locals, not just one receiver.
> A bound method remains the right tool for "call this method on that
> object"; a block is the right tool when the callback needs context.


`&obj.method` yields a **bound method**: a two-word value carrying the receiver
*and* the code address together. Store it, pass it, call it later — the receiver
travels with it.

```c
Counter* c = new Counter();
Handler^ h = &c.accumulate;      // receiver + code, in one value
h((i32)10);                      // calls c.accumulate(10)
```

This is the whole of the callback story in xcc. There is no `void*` context
argument to thread through, no cast back from `void*` on entry, and no protocol
to declare for a one-method interface.

## Declaring a `^` type

A `^` type is built from a function typedef. The typedef names the **signature**;
`Handler^` means "anything callable with that signature".

```c
typedef void Handler(i32 value);
typedef i32  Reducer(i32 a, i32 b);

Handler^ h;                       // a field, local or parameter
i32 reduce(i32* xs, u32 n, i32 seed, Reducer^ f) { … }
```

## A plain function widens into the same type

A free function has no receiver, and widens into a `^` with a null receiver
word. That is what lets one field accept either:

```c
void logIt(i32 v) { … }

Handler^ h = &c.accumulate;      // a method on an object
h = &logIt;                      // a free function — same type
```

This is target/action: a control declares one `action` field, and the client
supplies a method on their controller *or* a bare function, without the control
caring which.

## Guarding a `^`

A `^` that was never assigned is null, and calling it would crash. Both spellings
of the guard work, and both test **the whole pair**:

```c
if (action == 0) { return; }
if (action) { action(arg); }
```

## The receiver is part of the value

Two bindings of the same method to different objects are different callbacks, and
compare unequal:

```c
Handler^ hc = &c.accumulate;
Handler^ hd = &d.accumulate;
hc((i32)1);                     // updates c
hd((i32)100);                   // updates d
hc == hd                        // false
```

## Optional protocol methods

A protocol method marked `optional` that a class does not implement leaves a
**null vtable slot**. Taking `&delegate.method` therefore yields a null `^` — so
the same null test doubles as `respondsTo:`:

```c
Resize^ r = &delegate.windowDidResize;
if (r) { r(newSize); }              // only if the delegate implements it
```

That is what makes the delegate pattern work without a separate reflection API.
See [Inheritance & protocols](/compiler/language/inheritance/).

## ARC and stored `^`

A stored `^` holds its receiver like any other reference, so a view holding an
action that points back at its controller is a retain cycle. Declare the field
`weak:` and the receiver word auto-zeroes when the referent dies — the guard you
already wrote then does the right thing:

```c
class Button : Object
{
    weak: Handler^ action;      // does not keep the target alive
}
```

A `^` holding a *widened free function* has no receiver to retain, so it costs
nothing either way.

## Worked example

```c
// bound-methods.xc — `^`, the callback type.
#import "Stdio.xc"
#import "Foundation.xc"

typedef void Handler(i32 value);
typedef i32  Reducer(i32 a, i32 b);

void logIt(i32 v) { Stdio.printf("  free function saw %ld\n", v); }

i32 sumOf(i32 a, i32 b)     { return a + b; }
i32 productOf(i32 a, i32 b) { return a * b; }

class Counter : Object
{
    i32 total;
    void init(void) { total = (i32)0; }
    void accumulate(i32 v) { total = total + v; }
    void announce(i32 v) { Stdio.printf("  %s got %ld\n", "counter", v); }
}

class Button : Object
{
    Handler^ action;
    String*  title;
    void init(void) { action = 0; title = 0; }

    static Button* named(string t)
    {
        Button* b = new Button();
        b.title = String.withCString(t);
        return b;
    }

    void click(i32 arg)
    {
        if (action == 0) { Stdio.printf("  %s has no action\n", title.cString()); return; }
        action(arg);
    }
}

i32 reduce(i32* xs, u32 n, i32 seed, Reducer^ f)
{
    i32 acc = seed;
    for (u32 i = (u32)0; i < n; i = i + (u32)1) { acc = f(acc, xs[i]); }
    return acc;
}

i32 main(void)
{
    Stdio.print("bound to an object:\n");
    Counter* c = new Counter();
    Handler^ h = &c.accumulate;
    h((i32)10);
    h((i32)32);
    Stdio.printf("  total %ld\n", c.total);

    Stdio.print("a free function widens into the same type:\n");
    h = &logIt;
    h((i32)7);

    Stdio.print("stored as a field, fired later:\n");
    Button* ok   = Button.named("ok");
    Button* mute = Button.named("mute");
    ok.action = &c.announce;
    ok.click((i32)99);
    mute.click((i32)99);            // never assigned — guarded, not a crash

    Stdio.print("passed as a parameter:\n");
    i32 xs[4];
    xs[0] = (i32)1; xs[1] = (i32)2; xs[2] = (i32)3; xs[3] = (i32)4;
    Stdio.printf("  sum %ld, product %ld\n",
                 reduce(&xs[0], (u32)4, (i32)0, &sumOf),
                 reduce(&xs[0], (u32)4, (i32)1, &productOf));

    Counter* d = new Counter();
    Handler^ hc = &c.accumulate;
    Handler^ hd = &d.accumulate;
    hc((i32)1); hd((i32)100);
    Stdio.printf("  c=%ld d=%ld same? %d\n",
                 c.total, d.total, (i16)(hc == hd ? 1 : 0));
    return 0;
}
```

```
bound to an object:
  total 42
a free function widens into the same type:
  free function saw 7
stored as a field, fired later:
  counter got 99
  mute has no action
passed as a parameter:
  sum 10, product 24
  c=43 d=100 same? 0
```

## Across a shared-library boundary

A `^` crosses a `.so` boundary intact — it is a pair of words, not a symbol
reference. What does *not* cross is symbol interposition: the loader has none, so
a `^` built in one module and called in another calls the code that module
actually holds. See [Modules & shared libraries](/compiler/language/modules/).

## Threading

`Thread.spawn(&obj.method)` takes a `^`, which is why a thread body needs no
context argument: the thread's state is simply the object the method belongs to.
See [Threading](/compiler/language/threading/).
