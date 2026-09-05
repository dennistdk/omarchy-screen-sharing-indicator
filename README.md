# Screen Sharing Indicator

A presenter-only red ring around the window or monitor you are currently sharing
through the desktop portal - Teams PWA, `teams-for-linux`, Meet, Discord, Zoom, OBS,
anything that goes through xdg-desktop-portal.

macOS draws this ring in WindowServer. On Wayland a client cannot paint on another
window, and Hyprland has no built-in indicator, so you get no cue about *which*
surface you actually picked in the share dialog. This plugin adds one.

| | |
| --- | --- |
| Plugin id | `screen-sharing-indicator` |
| Install path | `~/.config/omarchy/plugins/screen-sharing-indicator/` |
| Target | Omarchy 4.0.2 · Hyprland 0.56.2 · Quickshell 0.3.1 |

## What each side sees

The ring is four thin layer-shell strips, not a full-screen overlay. That matters:
Hyprland's `no_screen_share` fills a layer's whole **bounding box** with black in
monitor captures, so a full-screen overlay would black out your entire stream. Four
thin strips make the bounding box *be* the ring.

| You are sharing | You see | Your audience sees |
| --- | --- | --- |
| A window | Red ring around it | Nothing - window captures never include layer-shell surfaces |
| A monitor | Red ring around the output | Thin black strips along the edges. Never red, never a blackout |
| A region | Red ring around the whole monitor | The same thin black strips |

Those black strips are the accepted price of the red never leaking. Budget about
**twice `widthPx` in physical pixels** for them, not `widthPx` itself: Hyprland
expands the fill box a little beyond the surface, and a scaled display multiplies
everything by the scale factor again. Measured on a 3840x2160 output at scale 1.25,
the default `widthPx: 3` blacks out 6 physical rows. See
[`tests/captures.md`](tests/captures.md) for the measurements.

## Install

```bash
omarchy plugin add https://github.com/dennistdk/omarchy-screen-sharing-indicator.git --enable --yes
```

Or by hand:

```bash
git clone https://github.com/dennistdk/omarchy-screen-sharing-indicator.git \
  ~/.config/omarchy/plugins/screen-sharing-indicator
omarchy-shell shell rescanPlugins
omarchy plugin enable screen-sharing-indicator
```

Either way, enabling drops an eye icon into your bar's right section - see
"Bar widget" below for what it does. Drag it elsewhere, or move it with
`omarchy bar move`.

### Then do this - it is not optional

Add this to the personal section of `~/.config/hypr/hyprland.lua`, or to
`~/.config/hypr/autostart.lua`:

```lua
do
  local path = (os.getenv("HOME") or "") .. "/.config/omarchy/plugins/screen-sharing-indicator/hypr.lua"
  local f = io.open(path, "r")
  if f then
    f:close()
    local ok, err = pcall(dofile, path)
    if not ok then
      io.stderr:write("screen-sharing-indicator hypr.lua: " .. tostring(err) .. "\n")
    end
  end
end
```

Then `hyprctl reload`.

**Without this snippet your audience sees the red ring burned into every monitor
share.** The layer rule it loads is what keeps the ring out of captures, and layer
rules are compositor config - a plugin installer cannot write them for you.

Keep the `io.open` guard and the `pcall`. A bare `dofile` breaks your *entire*
Hyprland config the moment the file goes missing, which is exactly what happens when
you uninstall the plugin.

## Uninstall

Order matters:

```bash
omarchy plugin disable screen-sharing-indicator   # or: omarchy plugin remove
# delete the snippet from your hypr config
hyprctl reload
```

Disabling alone unmaps every strip. A guarded snippet pointing at a deleted file is a
harmless no-op, so leaving it behind breaks nothing - but tidy it up anyway.

## Bar widget

Enabling the plugin puts an eye in the bar. It is always visible, even when
there is nothing to show: a privacy indicator that vanishes when idle cannot
be told apart from one that has died.

It answers one question - **is something being captured right now?** - from
the session table, not from whether a ring happens to be drawn. Those come
apart: switch **Window rings** off during a window share and the ring goes
away while the capture does not. The eye stays red.

| State | Glyph | Meaning |
| --- | --- | --- |
| Dim eye | open | Enabled, nothing is being captured. |
| Bright red eye | open | Something is being captured right now. A ring is up too, unless you have switched that ring type off. |
| Dim, slashed eye | slashed | `active: false` - the plugin is switched off, and nothing is being captured. |
| Bright red, slashed eye | slashed | `active: false` **and** something is being captured. No ring is being drawn - you asked for it not to be. |

A **Preview ring** does not turn the eye red: a preview is not a capture.

Click the eye for the dropdown. It carries:

- **What's being shared** - one line per session (identity, type, output), or
  "Nothing is being shared". A session that is not ringing yet is listed with
  a state word - `window · starting`, or `window · stopping` for one that
  ended before its ring came up - rather than hidden: a share the ring has
  not caught up with is still a share. The count beside the title is of
  sessions actually ringing, so a share picker sitting open with nine live
  preview sessions reads "0 active" over nine `starting` rows.
- **Settings** - four toggles: **Enabled** (the `active` key), **Window
  rings**, **Monitor rings**, **Notifications**. The first three change only
  what is *drawn*. None of them stops a capture, so none of them changes the
  eye, and flipping one mid-share never produces a notification - a toast
  fires when a share really starts or really stops, and at no other time. The
  same holds for a ring that comes and goes on its own: switch desktops during
  a window share and the ring is withdrawn until you switch back, silently.
- **Appearance** - six colour swatches plus an **Auto** mode, a ring-width
  stepper, and a **Preview ring** button that draws the ring for three
  seconds on your focused output with no capture involved, so you can judge a
  colour or width change without joining a call. A preview draws real strips,
  so you see exactly what your audience would see the black residual of, but
  it is never treated as a share and never fires a notification - not even if
  a real share starts and ends while it is running.
- **Health warnings**, shown only when something needs attention: whether the
  layer rule that keeps the ring out of monitor captures actually loaded (see
  "Then do this" under Install), and whether your pointer reaches the audience
  during a share (see "Cursor" below), with a one-click fix. The layer-rule
  warning sits at the top of the dropdown, because its consequence is
  happening to your audience right now. The cursor fix sits at the foot of
  Appearance, with a one-line "Cursor issue - see Appearance below" pointer at
  the top so it is never something you have to scroll to discover.

**Removing the widget from your bar stops the ring entirely.** The plugin
ships as both a `service` (which watches for shares and draws the ring) and a
`bar-widget` (the chip), but there is exactly one `shell.json` entry between
them - the widget's own bar entry, holding all of your settings. Delete the
chip and that entry goes with it, leaving nothing to tell the shell to run
the service: no ring, whatever else is configured, until you add the widget
back. That is how third-party plugins in this shell are enabled at all, which
is why M19 in [`tests/matrix.md`](tests/matrix.md) pins it down as expected
behaviour rather than something a future change may quietly regress.

## Settings

Most of these are also editable through the bar widget's dropdown (above):
`active`, the four toggles, `colorMode`, `color` and `widthPx` all have a
control there. `debounceMs` and `stopGraceMs` do not, and still need a hand
edit. Either way, every key lives inline on the widget's own entry in
`~/.config/omarchy/shell.json` (under `bar.layout.<section>` once the widget
is on your bar):

```json
{
  "id": "screen-sharing-indicator",
  "active": true,
  "colorMode": "fixed",
  "color": "#E81123",
  "widthPx": 3,
  "debounceMs": 700,
  "stopGraceMs": 1500,
  "showWindowRings": true,
  "showMonitorRings": true,
  "notify": false
}
```

| Key | Default | Notes |
| --- | --- | --- |
| `active` | `true` | Soft off switch. Unmaps every strip and stops drawing, but tracking continues so the chip stays honest about shares. Removing the widget from your bar does this too, and more - see "Bar widget" above. |
| `colorMode` | `"fixed"` | `"fixed"` always paints `color`. `"auto"` keeps `color` unless it is too close to your theme accent to tell apart, in which case it is pushed to the far end of a red/orange "alarm" hue band. It guards against confusability rather than following your theme, so a red ring never turns green; if computing it throws, the ring falls back to `color` rather than disappearing. |
| `color` | `#E81123` | Teams-ish red. Deliberately not your theme accent - a sharing cue should read as "you are being captured", not as decoration. Ignored while `colorMode` is `"auto"` and adjustment triggers. |
| `widthPx` | `3` | Ring thickness in logical pixels, clamped 1-16. Also drives how much black your audience sees on a monitor share - roughly double this, in physical pixels. |
| `debounceMs` | `700` | How long a capture must last before the ring appears, clamped 0-5000. Keeps PrintScreen and `grim` from flashing it. Values at or below 500 can still flash, because Hyprland's own idle-stop timer is 500 ms. |
| `stopGraceMs` | `1500` | How long a stop is held before the ring comes down, clamped 0-5000. Hyprland ends a capture 500 ms after the last copied frame and emits the same event a real "stop sharing" does, so without this a still screen flickers and the ring often never appears at all. The cost is that the ring lingers this long after you genuinely stop. `0` unmaps on the stop event. |
| `showWindowRings` | `true` | |
| `showMonitorRings` | `true` | Also covers region shares. |
| `notify` | `false` | Desktop notification when a share starts and stops. Off by default - the ring is already the cue, and an update shouldn't start adding pop-ups to your desktop unasked. A preview never triggers one, even if it overlaps a real share. |

Changes apply live; no shell restart needed.

## Cursor

Whether your mouse pointer reaches your audience during a screen share is
governed entirely by `cursor_mode` in `~/.config/hypr/xdph.conf`, and Teams
in particular does not ask for it - so without it set, your pointer is simply
invisible in the capture, with nothing in this plugin or in Teams telling you
so.

**It applies when the portal starts, not when you edit the file.** Change
`cursor_mode` while the portal is running and the file on disk updates while
the live share does not, and nothing distinguishes "set and live" from "set
but stale" until you go looking. So the dropdown carries a standing check
rather than a one-time reminder: it compares the file's modification time
against the portal's start time, and can tell "you fixed it and the portal
has since restarted" apart from "you fixed it, but the portal hasn't picked
it up yet."

When the check finds a problem, the dropdown shows a **Fix** button that
edits `xdph.conf` (backing it up first) to set `cursor_mode = 2` inside the
`screencopy { }` block, then restarts `xdg-desktop-portal-hyprland`. Two
things worth knowing:

- **It refuses while you are sharing** rather than restarting the portal
  underneath a live capture. Press it mid-share and nothing is touched -
  including when the press lands inside the check's own read-then-write gap.
- **It changes only the default.** An app that explicitly asks the portal to
  hide the cursor still hides it. This fixes the common case, where nothing
  asked and the cursor vanished anyway.

## Checking on it

```bash
omarchy-shell screen-sharing-indicator status
```

Dumps the session table, the matched window addresses, and the strip count as JSON.

## Known limitations

- **Restarting the shell mid-share loses the ring** until the next share starts.
  Hyprland has no "what is currently being captured?" query, and it will not re-emit a
  start event for a session that is already running.
- **Region shares ring the whole monitor, not the region.** The `screencastv2`
  payload is `active,type,name` and nothing else, and for a region `name` is just
  the monitor. Hyprland *does* know the rectangle - `CScreenshareSession` holds it
  as `m_captureBox` and renders from it - it simply never puts it on the wire, so
  this is one upstream field away rather than impossible. Ringing the whole
  monitor overstates what is shared, the safe direction for a privacy cue, and
  `status` reports `"type": "region"` so you can tell the two apart.
- **Sharing a browser tab rings the whole browser window.** Hyprland cannot see tabs.
- **Two windows with the same title both get ringed.** The share event identifies the
  target by title, so this is the honest answer rather than a guess.
- **No rounded corners.** The strips are axis-aligned rectangles; rounding them would
  mean a larger bounding box, which means more black in your audience's capture.

## Development

```bash
./tests/run                      # pure-model unit tests, no compositor needed
omarchy-plugin-validate .        # manifest check
```

Anything that needs a live compositor - and most of it needs a real portal
client too - is written up as a runnable checklist in
[`tests/matrix.md`](tests/matrix.md), with the audience-side measurements in
[`tests/captures.md`](tests/captures.md). See [`CONTRIBUTING.md`](CONTRIBUTING.md)
before sending a change.

`ShareModel.js` holds all parsing, refcounting and geometry as pure functions with no
timers and no QML types, so it runs under plain node. `Service.qml` owns the Hyprland
event subscription, the debounce timers and the strip surfaces.

**Hot-reload does not work here.** Run `omarchy-restart-shell` after editing
anything, and verify against the journal:

```bash
journalctl --user -f | grep screen-sharing-indicator
```

It fails silently, in two different ways; [`CONTRIBUTING.md`](CONTRIBUTING.md)
has both, along with a `socat` one-liner for watching the raw compositor events.

## License

MIT - see [`LICENSE`](LICENSE).
