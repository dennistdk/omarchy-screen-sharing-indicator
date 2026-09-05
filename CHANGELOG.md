# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-05

Initial release.

### Added

- Presenter-visible red border around the window, monitor or region currently
  being captured through the desktop portal. Drawn as four thin layer-shell
  strips so that Hyprland's `no_screen_share` bounding-box fill costs a monitor
  share's audience a thin black edge rather than the whole frame.
- `hypr.lua`, the layer rule that keeps the border out of monitor captures,
  loaded from the user's Hyprland config through a guarded `dofile`.
- Window matching by exact title, with the matched addresses frozen on the
  start event so a mid-share retitle cannot break the border. Duplicate titles
  border every window that answers to them.
- A start debounce (`debounceMs`, default 700) so screenshots do not flash the
  border, and a stop grace (`stopGraceMs`, default 1500) so Hyprland's 500 ms
  idle-stop does not make a still screen flicker.
- Bar widget: an always-visible eye that reports whether something is being
  captured, read from the session table rather than from the strip count.
- Widget dropdown: live session list, four toggles, six colour swatches plus an
  `auto` contrast mode, a border-width stepper, and a three-second preview border.
- Health checks in the dropdown for the layer rule and for `cursor_mode` in
  `xdph.conf`, the latter with a one-click fix that refuses while a share is
  running.
- Optional desktop notifications when a share starts and stops (`notify`, off
  by default). Settings changes and preview borders never fire one.
- `omarchy-shell screen-sharing-indicator status` for the session table, the
  matched window addresses and the strip count, as JSON.
- Unit tests over the pure model (`tests/run`), plus a manual matrix
  (`tests/matrix.md`) and capture-side measurements (`tests/captures.md`) for
  everything that needs a live compositor.

### Known limitations

- Restarting the shell mid-share loses the border until the next share starts.
  Hyprland has no query for what is currently being captured.
- Region shares border the whole monitor. The wire protocol carries no rectangle.
- Sharing a browser tab draws a border around the whole browser window.
- A monitor share's audience sees a thin black edge, roughly twice `widthPx` in
  physical pixels, and 8 physical pixels of border colour at the bottom corners
  on a fractionally scaled output. Both are measured in `tests/captures.md`.

[1.0.0]: https://github.com/dennistdk/omarchy-screen-sharing-indicator/releases/tag/v1.0.0
