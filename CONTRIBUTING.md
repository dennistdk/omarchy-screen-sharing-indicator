# Contributing

Bug reports and patches are welcome. This file covers the two things that are
easy to get wrong here: how the code is split, and how to actually test a
change against a running shell.

## Layout

| File | Owns |
| --- | --- |
| `ShareModel.js` | Every pure decision: parsing, session bookkeeping, refcounting, geometry, settings merges, health verdicts |
| `Service.qml` | The Hyprland event subscription, the timers, the strip surfaces, IPC |
| `Strip.qml` | One edge of the border |
| `BarWidget.qml` | The bar chip |
| `Panel.qml` | The dropdown |
| `hypr.lua` | The layer rule, loaded from the user's Hyprland config |

**`ShareModel.js` has no timers, no QML types and no I/O.** That is what lets
`tests/run` execute it under plain node, and it is the boundary worth
defending: if a change needs a clock, the clock belongs in `Service.qml` and
the decision it feeds belongs in the model, as a function taking `nowMs`.

## Tests

```bash
./tests/run                      # pure-model unit tests, no compositor needed
omarchy-plugin-validate .        # manifest check
```

Anything that needs a live compositor is in [`tests/matrix.md`](tests/matrix.md) -
21 rows grouped into six sittings, most of them needing a real portal client.
The audience-side numbers those rows compare against are in
[`tests/captures.md`](tests/captures.md).

New model behaviour should arrive with a unit test. New *drawing* or *event*
behaviour usually cannot have one; add or amend a matrix row instead, and say
in the pull request which rows you ran.

## Testing against a running shell

**Restart the shell after editing anything.** Hot-reload is not reliable here,
and the way it fails is silent:

- The shell watches `~/.config/omarchy/plugins/` and logs `Local plugin changed,
  reloading`, but that does not dependably swap an already-compiled
  `Service.qml`. You can end up with the old code handling events while the new
  file sits on disk.
- Editing `ShareModel.js` is worse: hot-reload does not re-parse an imported
  `.js` resource **at all**. The JS engine caches the module by URL, so the
  running shell keeps executing whatever version was loaded at the last full
  start, however often the file or `Service.qml` changes in the meantime.

So:

```bash
omarchy-restart-shell
journalctl --user -f | grep screen-sharing-indicator
```

If a live test produces a result that makes no sense - a function throwing
`TypeError` for a symbol that plainly exists on disk - suspect a stale model
before the logic. `diff` against the installed copy shows nothing, because the
file is not what is out of date; the process is.

To watch the raw compositor events the plugin reacts to:

```bash
socat -U - UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock \
  | grep --line-buffered screencast
```

## Reporting a bug

Include the journal - `journalctl --user | grep screen-sharing-indicator` is
enough to diagnose most of what goes wrong here. Say which portal client you
were sharing through, whether it was a window, monitor or region share, and, if
the border misbehaved rather than the chip, `hyprctl layers | grep -c
screen-sharing-indicator` at the time.

For a transient that is gone before you can type, `tests/record` samples the
model and the compositor together twice a second and writes both to a file.

## Scope

The border is a privacy cue, not decoration. Two consequences worth knowing
before proposing a change:

- **When in doubt, overstate what is being shared.** A region share draws a border around the
  whole monitor because the compositor does not put the rectangle on the wire.
  A border around less than is captured is the dangerous direction to err in.
- **Nothing may leak red into a capture.** Any change touching strip geometry
  or the layer rule needs the capture-side matrix rows re-run, and the
  measurements in `tests/captures.md` updated if they move.
