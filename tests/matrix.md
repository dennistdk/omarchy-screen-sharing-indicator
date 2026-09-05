# Manual test matrix

`tests/run` covers everything that can be decided from pure functions - parsing,
refcounting, session bookkeeping, geometry, settings merges. It cannot see a
compositor, so it cannot tell you whether a surface actually mapped, what a
capture of that surface looks like, or what happens when a real portal client
starts and stops a share.

This file is the remainder: the checks that need a live Hyprland session, and
most of them a real portal client driving a real share. Every row is
self-contained - do this, expect that, confirm it with these commands.

Rows are grouped by the setup they need, so this is six sittings rather than
twenty-one separate errands.

## Instruments

```bash
tests/watch          # one snapshot of sessions, strips and settings
tests/watch -f       # the same, twice a second, while you drive a share
tests/audience DP-1  # the audience's view of an output, with a verdict
tests/record 180     # log both views to a file, for catching transients
journalctl --user -f | grep --line-buffered screen-sharing-indicator
hyprctl layers | grep -c screen-sharing-indicator   # surfaces actually mapped
```

**Two numbers, two questions.** Several rows below turn on the difference:

- **`strips=N`** from `tests/watch` is how many rows the model wants. It stays
  at 4 even when the border is deliberately withdrawn.
- **`hyprctl layers | grep -c`** is how many surfaces are really mapped. This is
  the one that goes to 0 when the border comes down.

A row that expects them to diverge says so explicitly. Anywhere else, they
should agree.

**Watch for an orphan.** `tests/watch` flags a window session that has lost its
window with `ORPHAN no-window-for=Ns`. One should never survive past about 5 s -
the reaper collects it. A `stop-orphan` line in the journal means a stop arrived
that no session owned. Either is worth capturing the journal for: this is the
failure that leaves a border on a window nobody is sharing.

**Take a baseline before you start**, with nothing shared:

```bash
tests/audience DP-1     # expect: border 0 px, and a black count to compare against
```

`tests/audience` allows up to 500 px of border colour rather than requiring zero.
A full monitor border genuinely leaks 8 px - two 4x1 slivers at the bottom
corners, where the side strips end on a fractional physical row. Measured and
understood; see [`captures.md`](captures.md). A real layer-rule failure is in the tens
of thousands, so the two are never hard to tell apart.

---

## Sitting 1 - one live window share

Share a single window from any portal client - Teams PWA, `teams-for-linux`,
Meet, Discord, Zoom. Pick a window you are willing to fullscreen, move, resize
and close. **Leave the share running**: the last two rows are the ones that end
it.

Run `tests/watch -f` in one terminal and the journal in another.

### M1 - the border appears, and sticks through retitles

- **Do:** start the share. Then make the window change its own title - switch
  tabs in a browser, or let a Teams chat update the title bar. Do it both during
  the first second and again once the border is up.
- **Expect:** window-local strips about 700 ms after the share starts, and they
  stay put across every retitle.
- **Why it can fail:** the share event carries the title as of session init, not
  a live one. Addresses are frozen on the start event precisely so that a
  retitle during the debounce cannot break the match. If the border never appears
  when the title changed early, that freeze has regressed.
- **Check:** the journal shows `match-ok: 1 window(s)`, then `debounce-fire`
  roughly 700 ms after the start. `tests/watch` shows the session `VISIBLE` with
  `addrs=1`; `hyprctl layers | grep -c` is 4.

### M2 - the border tracks the window

- **Do:** move the shared window to another monitor. Resize it. Toggle it
  between tiled and floating.
- **Expect:** the strips follow, on a 33 ms poll, and the old output is left
  clean. The border hugs the client area - Hyprland's own border sits outside it,
  not under it.
- **Check:** `hyprctl layers | grep -c` stays 4 throughout; no strip is left
  behind on the output the window came from.

### M3 - the shared window fullscreen

- **Do:** fullscreen the shared window.
- **Expect:** the border stays visible and snaps out to the screen edges. A
  fullscreen window's `at`/`size` become the whole output, so a window border
  becomes an output-edge border. The overlay layer sits above fullscreen clients,
  so nothing covers it.
- **Check:** `tests/watch` still shows `VISIBLE` with `addrs=1`;
  `hyprctl layers | grep -c` stays 4.

### M4 - the shared window on another workspace

- **Do:** switch to a workspace where the shared window is not visible.
- **Expect:** the border disappears from the screen; tracking continues.
- **Check:** this is the row where the two numbers diverge. `tests/watch` still
  reports `strips=4` and `VISIBLE`, while `hyprctl layers | grep -c` drops to
  **0** - `isWindowDrawable` withdraws the surfaces, not the session. The
  journal logs `no-strips: … not drawable on <output>: … windowWs=3
  monitorActiveWs=2`. Switch back and it logs `strips-up`; the count returns to
  4. The session is never dropped across either transition.
- **Also expect:** no notification at either edge. A border that comes and goes on
  its own is not a share starting or stopping.

### M5 - two windows with the same title

- **Do:** open two windows with an identical title - two terminals in the same
  directory is easiest - and share one of them.
- **Expect:** **both** get a border. This is intentional. The share event
  identifies its target by title, not by address, so an exact title match draws a border on
  every window that answers to it. Choosing one arbitrary window would be a guess
  presented as fact.
- **Check:** `tests/watch` → `addrs=2`; `hyprctl layers | grep -c` → 8; the
  journal logs `match-multi: 2 window(s)`.

### M6 - close the shared window

- **Do:** close the window being shared.
- **Expect:** the border goes. The app may hold its session open a moment longer;
  the strips must go regardless, because the tracked address stops resolving.
- **Check:** `hyprctl layers | grep -c` → 0. The journal may log `match-miss`.

### M7 - stop the share from the app

- **Do:** press *Stop sharing* in the app.
- **Expect:** the border goes within `stopGraceMs` - about 1.5 s - and **not**
  instantly. The grace is deliberate: Hyprland ends a capture session 500 ms
  after the last copied frame and emits the identical event a real stop emits,
  so an immediate unmap makes a still screen flicker.
- **Check:** with `tests/watch -f` the session sits as `stopping` with `count=0`
  while still `VISIBLE`, then vanishes. The journal shows
  `stop-grace … holding 1500ms` and a `session-drop` roughly 1500 ms later.
  Setting `stopGraceMs: 0` unmaps immediately, if you want to see the flicker
  the grace exists to prevent.

---

## Sitting 2 - monitor, region and tab shares

Same single portal client, different pick in its share dialog. `tests/audience`
carries the audience half of these rows, so run it against the shared output
each time.

### M8 - share a whole monitor

- **Do:** share an entire output.
- **Expect, presenter:** four inset strips on that output only. No strips
  anywhere else.
- **Expect, audience:** thin black bars along the edges - **never** red, and
  **never** a blacked-out frame. Budget roughly twice `widthPx` in physical
  pixels for the black, not `widthPx` itself.
- **Check:** `tests/audience <output>` passes. Red in the thousands means the
  layer rule is not applied - see M17. Over 90% black means a full-output
  surface is being filled, which is the failure the four-strip design exists to
  prevent.

### M9 - share a region

- **Do:** pick *share a region* and select part of an output.
- **Expect:** the same four strips as M8, around the **whole monitor**, not the
  region. Hyprland knows the rectangle but does not put it on the wire, so
  drawing a border around the whole output is the only honest option - and overstating what is
  shared is the safe direction for a privacy cue.
- **Check:** the journal logs `debounce-fire: region <output>`;
  `omarchy-shell screen-sharing-indicator status` reports `"type": "region"`, so
  a region share is distinguishable from a monitor one even though they look
  identical.

### M10 - share a browser tab

- **Do:** pick a single tab in a browser's share dialog.
- **Expect:** the whole browser **window** is bordered, not a tab-shaped box.
  Hyprland cannot see tabs.
- **Check:** the border matches the browser window's geometry exactly.

---

## Sitting 3 - two clients at once

The one setup that needs two portal clients running together, and the only way
to see a window border from a monitor capture's point of view.

### M11 - window share plus a concurrent monitor capture

- **Do:** share window *W* from Teams. In OBS add two sources: a **Window
  Capture** of *W*, and a **Screen Capture** of the output *W* sits on. Look at
  both previews.
- **Expect, presenter:** a border on *W* **and** a border around the whole output.
  Both are correct - with OBS capturing the monitor, that monitor genuinely is
  being captured, so it earns its own border. `tests/watch` lists several
  sessions; that is the point of the row.
- **Expect, OBS window capture of *W*:** no border at all, and no black frame.
  Window captures never include layer-shell surfaces.
- **Expect, OBS screen capture:** thin black around *W*'s box and around the
  output edge - **not** red, and **not** a blacked-out frame.
- **Check:** `tests/audience <output>` for the numeric version of the monitor
  half.

---

## Sitting 4 - screenshots

No portal client needed. `grim` goes through the same capture path a real share
does, so these rows exercise the debounce with nothing else running.

### M12 - screenshots never flash the border

- **Do:** take a full-output screenshot (PrintScreen, or `grim -o <output>`).
  Then a region screenshot (`grim -g "$(slurp)"`). Then, with the default
  `debounceMs`, start a `grim` capture and immediately start a real window share.
- **Expect:** no border for either screenshot. A `grim` session lives about 500 ms
  and is torn down by Hyprland's own idle-stop timer, which the 700 ms default
  debounce is sized to swallow. After the third case settles, only the real
  share's strips remain.
- **Check:** the journal shows `debounce-arm` then `debounce-cancel` with no
  `debounce-fire`; `tests/watch` shows `strips=0` throughout. Note that
  `debounceMs` at or below 500 can still flash - that is the setting's
  documented floor, not a defect.

---

## Sitting 5 - config and lifecycle

These change the environment underneath a live share. Run each with a real share
running unless the row says otherwise.

### M13 - `hyprctl reload` mid-share

- **Do:** `hyprctl reload` while a monitor share is running.
- **Expect:** the border survives, and the layer rule is still applied.
- **Check:** `tests/audience <output>` must still pass. If the border colour count
  jumps into the thousands, the reload dropped `hypr.lua` and the audience is
  now seeing red. This is the whole reason the row exists.

### M14 - lock and unlock

- **Do:** lock the session. Wait more than `stopGraceMs` - 2 s is plenty - then
  unlock.
- **Expect while locked:** no border over the lock screen. `above_lock` is
  deliberately unset, so the renderer skips the layer entirely; no code in this
  plugin is involved.
- **Expect on unlock:** the border comes back. Two paths are both a pass, and the
  journal says which:
  - the session survived the lock and revived - `revived`, and no `session-drop`;
  - or it expired while locked and the capture restarted - `session-drop`, then
    a fresh `debounce-arm` and `debounce-fire`.

### M15 - switching the plugin off mid-share

- **Do:** set `"active": false` on the plugin's entry in
  `~/.config/omarchy/shell.json`, or use the **Enabled** toggle in the dropdown.
  Settings apply live; no restart.
- **Expect:** every strip unmapped, nothing left behind - and **no
  notification**, because nothing about the capture changed. The eye stays red.
- **Check:** `tests/watch` → `strips=0 active=false`, and
  `hyprctl layers | grep -c` → **0**. A mapped strip contributes its black
  bounding box to a capture even with a transparent colour, so anything above 0
  here is a real defect rather than a cosmetic one.
- **Then:** set it back to `true`. The border returns, because the session was
  never torn down. Still no notification.

### M16 - restarting the shell mid-share

- **Do:** `omarchy-restart-shell` while a share is running.
- **Expect:** the border stays gone until the next share starts. This is a known
  limitation, not a regression: Hyprland has no "what is currently being
  captured?" query, and it will not re-emit a start event for a session that is
  already running.
- **Check:** `tests/watch` shows no sessions. Starting a fresh share brings the
  border back normally.

### M17 - the layer rule removed (negative control)

Do this one deliberately, and put it back afterwards.

- **Do:** comment the guarded snippet out of your Hyprland config, `hyprctl
  reload`, then start a **monitor** share.
- **Expect:** the presenter still sees red - and so does the audience. This is
  the failure the snippet prevents, and the reason the README calls it not
  optional.
- **Check:** `tests/audience <output>` **fails**, reporting border colour in the
  tens of thousands. The dropdown's health section should also flip to the
  layer-rule warning at the next reload.
- **Then:** restore the snippet, `hyprctl reload`, and confirm `tests/audience`
  passes again.

---

## Sitting 6 - the bar widget

Needs the widget actually on the bar - or, for M19, briefly off it. A different
kind of setup from the sittings above, which all assume it is already there and
otherwise ignore it.

### M18 - chip states

- **Do:** watch the chip through a full cycle: idle, start a real share, stop
  it, and wait past `stopGraceMs`. Then, mid-share, switch the matching border
  type off and on again.
- **Expect:** dim eye while idle; the eye lights (full opacity, `Color.urgent`)
  the moment a border goes up; dim again - but only once `stopGraceMs` has
  actually elapsed after the real stop, not immediately. Switching a border type
  off mid-share must **not** dim it: the chip answers "is something being
  captured", which is not the same question as "is a border drawn".
- **Check:** compare the chip's transitions against the journal - lit within a
  frame of `debounce-fire`, dim within a frame of `session-drop`, never earlier
  than either. The chip reads `svc.sharingNow`, derived from the session table
  rather than the strip count, so it should track the grace exactly.
- **Also:** press **Preview border** while idle. The border draws for three seconds;
  the eye stays dim. A preview is not a capture.

### M19 - removing the widget stops the border

This row pins an accepted consequence, so that a regression cannot be mistaken
for correct behaviour or the reverse. The plugin's `kinds` include `bar-widget`,
and its single `shell.json` entry - living under `bar.layout` - is simultaneously
its settings and its enabled flag. There is no separate "service running, widget
just hidden" state.

- **Do:** with nothing currently shared, remove the widget from the bar (drag it
  off, or `omarchy plugin disable io.github.dennistdk.screen-sharing-indicator`). Confirm with
  `omarchy-shell screen-sharing-indicator status` → `Target not found`. Then
  start a real share.
- **Expect:** no border. There is no service running to see the `screencastv2`
  event in the first place.
- **Check:** `hyprctl layers | grep -c screen-sharing-indicator` → **0** for the
  whole duration of the share.
- **Then:** re-add the widget. The eye reappears in its idle state - the plugin
  has no memory of the share that ran while it was gone, which is consistent
  with M16: there is no live-session query to recover one from.

### M20 - a settings write preserves unrelated keys

- **Do:** hand-set a value the panel has no control for - `debounceMs` or
  `stopGraceMs` - directly on the entry in `~/.config/omarchy/shell.json`. Then
  open the panel and change anything: a toggle, a colour swatch, the width
  stepper.
- **Expect:** the hand-set value is still there afterwards, untouched.
- **Check:** re-read the entry and confirm the hand-set key matches what you set,
  alongside the control's own new value. Every panel write folds a single change
  onto the whole current entry through one `mergedSettings()` call, so a partial
  write should be structurally impossible - this row is what catches it if that
  ever stops being true.

### M21 - the cursor fix refuses mid-share

- **Do:** start a real share. While the border is up, open the panel and press the
  **Fix** button in the cursor section. (That section only renders when
  `cursorState !== "ok"`, so if your `xdph.conf` is already correct,
  break it first.)
- **Expect:** a refusal, not a fix. The button is disabled outright while
  `svc.borderCount > 0`, and the action refuses even if reached another way. It
  will not restart the portal underneath a live capture.
- **Check:** `xdph.conf`'s mtime and `systemctl --user show -p
  ActiveEnterTimestamp xdg-desktop-portal-hyprland` are both unchanged after the
  attempt, and the share is undisturbed - `tests/watch` still shows the session
  `VISIBLE` throughout.

---

## When something fails

Capture the journal. Every bug found in this plugin so far was diagnosed from

```bash
journalctl --user | grep screen-sharing-indicator
```

and nothing else. For a transient that is gone before you can type, `tests/record`
samples the model and the compositor together twice a second and writes both to a
file.

### M22 - the layer rule fix button

The one action that writes to the user's compositor config, so it is the one
that most needs a live row. Verification is not a separate step: `hypr.lua`
rewrites its marker on every reload, and the service re-reads that marker, so
a warning that clears itself *is* the proof the rule loaded.

- **Do:** with the loader absent from `~/.config/hypr/hyprland.lua`, open the
  dropdown. Press **Hide the border from your audience**.
- **Expect:** the warning disappears within a second or two. `hyprland.lua`
  gains the guarded `do ... end` block with the plugin's real install path, and
  a sibling `hyprland.lua.bak.<epoch>` appears next to it. The journal logs
  `layer-rule-fix: wrote hyprland.lua and reloaded Hyprland`.
- **Check:** `hyprctl layers | grep -c io.github` is unchanged (the rule governs
  capture, not mapping); start a monitor share and confirm a `grim` capture shows
  black strips rather than red. That is the audience-side proof - see
  [`captures.md`](captures.md).

- **Do:** press it a second time (temporarily force the warning by commenting the
  block out, then reload).
- **Expect:** no duplicate block. `applyLayerRuleSnippet` returns null for a
  config that already loads it, so the service reloads without writing, and the
  journal says `loader already present; reloaded`. A *commented-out* block reads
  as absent, so this path appends one - matching how `cursor_mode` is judged.

- **Do:** make `hyprland.lua` read-only (`chmod 444`) and press the button.
- **Expect:** nothing is written and Hyprland is not reloaded. The journal says
  `backed up but failed to write hyprland.lua; not reloaded`, and the warning
  stays up rather than flipping to a green readout it has not earned.

- **Do:** arrow-key down from the top of the dropdown while the warning shows.
- **Expect:** the fix button is the **first** row, ahead of `Enabled`, and every
  row below it still activates its own control. With the warning hidden, the
  first row is `Enabled` again. The row model is identity-based precisely so
  this conditional top row cannot shift the meaning of the ones under it.
