# What a capture actually contains

The dangerous failure in this plugin is not "no ring". It is a ring that reaches
the audience - either as red leaking into their stream, or as a blackout of it.
This file records what has actually been measured on real captures, and it is
why the ring is four thin strips rather than one full-output overlay.

The presenter-facing rows of the manual matrix live in
[`matrix.md`](matrix.md); this file is the audience's side, in numbers.

## How these are measured

`grim` goes through the same `ScreenshareManager` path Teams or OBS does - it
emits `screencast` / `screencastv2` on socket2 like any other client - so a
`grim` capture taken while the ring is mapped *is* the audience's view. That
makes the audience side measurable without a portal client.

**One trap makes naive runs misleading.** A `grim` session lives about 500 ms,
and a `PanelWindow` created and destroyed inside that window never completes a
render pass: the layer surface maps at the right geometry but never attaches a
buffer. `hyprctl layers` still lists it, and `no_screen_share` still fills its
bounding box, so a monitor capture shows **black strips for a surface that
painted nothing**. That looks exactly like a pass while the presenter sees
nothing at all.

Every number below was therefore taken against a long-lived surface, pinned
through a temporary IPC call rather than a real capture session. Measure the
audience side the same way.

Environment for these figures: Omarchy 4.0.2, Hyprland 0.56.2, Quickshell 0.3.1,
`DP-1` 3840x2160 at scale 1.25 (logical 3072x1728).

## What the layer rule does

| Setup | Result |
| --- | --- |
| One full-output surface in this namespace, rule applied | **8,294,400 px black** - the entire 3840x2160 frame. The fill covers the bounding box, not the ink. This is what a full-output overlay would cost the audience, and the reason the ring is four strips. |
| One strip surface, rule applied | **75,000 px black** over the strip region only; screen centre `srgb(35,43,46)`, a normal desktop. No blackout. |
| The same strip, rule removed | **75,000 px of `srgb(232,17,35)`** - exactly `#E81123`. The rule is the only thing preventing this. |
| A window share, seen from a **window** capture | No ring and no black frame. Window captures never include layer-shell surfaces. Field-confirmed across a 13m45s Teams window share with no artifact reported by any participant - and a red leak or a blackout would have been unmissable. |
| A window share, seen from a concurrent **monitor** capture | The one case that needs two portal clients at once, so it is a manual row rather than a measurement here: see M11 in [`matrix.md`](matrix.md). |

`hyprctl reload` with the plugin's `hypr.lua` deleted returns `ok`, so the
guarded `dofile` in the user's config survives an uninstall rather than breaking
the whole Hyprland config.

## The ring is not quite invisible: 8 px at the bottom corners

A single pinned strip shows no ring colour at all. A whole four-strip monitor
ring does leak, by exactly 8 physical pixels:

```
4x1+0+2155      bottom-left
4x1+3836+2155   bottom-right
```

Both are the *bottom end of a side strip*, and neither top corner leaks. The
side strips run to logical y=1725, which at scale 1.25 is physical 2156.25 - a
fractional row. `no_screen_share` rounds the fill one row short of what the
surface renders, so a 4x1 sliver of `#E81123` escapes at each end. The top ends
sit at logical y=3 (physical 3.75), where the rounding goes the generous way, so
they are covered.

Invisible in practice, and it leaks no content - but it does make "no red
reaches the audience" literally 8 px wrong, so it is recorded rather than
quietly rounded off. It is not fixed because the obvious fix is a scale-specific
fudge.

**The clean fix, if it is ever wanted:** let the side strips span the full height
instead of insetting by `widthPx`. The union of the four bounding boxes is
unchanged - the top and bottom strips already cover the corners across the full
width - so the audience's black costs nothing more, while the side strips would
then end on integer physical rows (0 and 2160) and the slivers disappear. It
means deliberately double-drawing the corners, and re-running everything on this
page.

`tests/audience` therefore allows 500 px of ring colour rather than requiring
zero. The discrimination is not delicate: a single unruled strip measures
75,000 px.

## The black residual is wider than `widthPx`

A `widthPx: 3` strip on a 1.25-scaled output does not cost the audience 3
physical pixels, or even the 3.75 the scale implies. Measured vertical profile
across a 3-logical-pixel strip at logical `y=300`:

```
buffer y=374  srgb(28,26,23)   desktop
buffer y=375  srgb(0,0,0)      black
...
buffer y=380  srgb(0,0,0)      black
buffer y=381  srgb(28,26,23)   desktop
```

Six physical rows for a three-logical-pixel strip. Hyprland expands the fill box
beyond the surface bounds, so budget roughly **2x `widthPx` in physical pixels**.
Still thin - 6 rows out of 2160 - but the documentation should not promise 3.

## Geometry, measured

A monitor ring on `DP-1`, from `hyprctl layers`:

```
x=0    y=0     w=3072 h=3
x=0    y=1725  w=3072 h=3
x=0    y=3     w=3    h=1722
x=3069 y=3     w=3    h=1722
```

3072, not 3840: `Quickshell.screens` reports logical pixels and
`HyprlandMonitor.width` reports buffer pixels, and only the former shares a
coordinate space with `PanelWindow` margins. Mixing them overflows every monitor
strip.

Sharing the second output puts the strips at global `x=3072..6141`, so the
output-local conversion holds off-origin rather than pinning every ring to the
first monitor's corner.

## Timing, measured

`grim` start to stop, twice: `06.108 -> 06.608` and `11.130 -> 11.630`. Exactly
500 ms, and torn down by Hyprland's idle-stop timer rather than by the client
disconnecting. That is the case the 700 ms default debounce exists for; anything
at or below 500 ms flashes a ring on every screenshot.

With the default in place, a `grim` capture arms a timer, cancels it, and maps
zero strips.
