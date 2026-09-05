import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "ShareModel.js" as ShareModel

// Watches Hyprland's screencast events and tracks what is currently being
// captured. Drawing lives here too: persistent per-output surfaces in this
// shell are owned by services, not by summoned overlays.
Item {
  id: root

  // Injected by omarchy-shell's service loader (shell.qml ensureService).
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  property var pluginRegistry: null

  readonly property string pluginId: "screen-sharing-indicator"
  readonly property string defaultColor: "#E81123"

  // Services are not injected `settings` the way bar widgets are, so read the
  // plugin's own entry out of shell.json. Going through shell.shellConfig keeps
  // the binding live, so edits apply without restarting the shell. The entry
  // sits in bar.layout or in plugins[] depending on whether the widget is on
  // the bar; the registry's resolver decides, and ShareModel mirrors it for
  // the unit tests and for shells without that function.
  readonly property var shellConfig: shell && shell.shellConfig ? shell.shellConfig : null
  readonly property var settingsEntry: resolveEntry(shellConfig)

  function resolveEntry(config) {
    if (!config) return ({})
    if (pluginRegistry && typeof pluginRegistry.findEntryLocation === "function") {
      var loc = pluginRegistry.findEntryLocation(config, pluginId)
      if (loc && loc.found) {
        if (loc.kind === "bar" && config.bar && config.bar.layout && config.bar.layout[loc.section])
          return config.bar.layout[loc.section][loc.index] || ({})
        if (loc.kind === "plugin" && config.plugins) return config.plugins[loc.index] || ({})
      }
      return ({})
    }
    return ShareModel.entryFromConfig(config, pluginId)
  }

  readonly property bool active: settingsEntry.active !== false
  readonly property string colorSpec: validColor(settingsEntry.color, defaultColor)
  // "fixed" paints colorSpec; "auto" keeps it unless the theme accent is close
  // enough to be confusable, in which case it separates them. See ShareModel.
  readonly property string colorMode: settingsEntry.colorMode === "auto" ? "auto" : "fixed"
  // Qt renders an opaque colour as "#rrggbb" but one carrying alpha as
  // "#aarrggbb"; ShareModel's hex parser only accepts 3- or 6-digit forms, so
  // an alpha-bearing accent would otherwise silently leave auto mode inert.
  readonly property string themeAccent: normalizeAccent(Color && Color.accent ? String(Color.accent) : "")
  // A throw would leave ringColor at QML's default for a string property that
  // never evaluated -- empty, which paints no ring at all. Fall back to
  // colorSpec instead.
  readonly property string ringColor: {
    if (colorMode !== "auto" || !themeAccent) return colorSpec
    try {
      return ShareModel.autoRingColor(colorSpec, themeAccent)
    } catch (e) {
      return colorSpec
    }
  }
  readonly property int widthPx: clampInt(settingsEntry.widthPx, 3, 1, 16)
  // At or below 500 ms the ring can still flash on Hyprland's own idle-stop
  // path, which fires 500 ms after the last copied frame.
  readonly property int debounceMs: clampInt(settingsEntry.debounceMs, 700, 0, 5000)
  // How long a stop is held before the ring comes down. Hyprland emits the
  // same screencastv2>>0 for a real "stop sharing" and for its own 500 ms
  // idle stop, and there is no live-session query to tell them apart, so this
  // is a straight trade: too low and a still screen flickers, too high and the
  // ring lingers after you really stop. 0 unmaps on the stop event.
  readonly property int stopGraceMs: clampInt(settingsEntry.stopGraceMs, 1500, 0, 5000)
  readonly property bool showWindowRings: settingsEntry.showWindowRings !== false
  readonly property bool showMonitorRings: settingsEntry.showMonitorRings !== false
  // Default false: the ring is already the cue, and an update should not
  // start adding pop-ups to someone's desktop unasked.
  readonly property bool notify: settingsEntry.notify === true

  // QML ids are not reachable from outside the component, so the strip count
  // has to be a property for the bar widget to read.
  readonly property int ringCount: stripModel.count
  // Whether a preview's own strips are mapped. Read by Strip.qml's
  // pluginActive and by syncStrips' early return.
  property bool previewing: false
  // The stripIds a preview last added, so stopPreview() can remove exactly
  // those rows -- never a hardcoded edge list, which would drift the moment
  // boxesForMonitor's edge set changes.
  property var previewIds: []

  property var shareState: ShareModel.emptyState()
  readonly property bool hasVisibleWindowTarget: computeHasVisibleWindowTarget(shareState)

  // The one honest answer to "is something being captured right now?", and the
  // only thing the bar chip and the notifications may read. Off the session
  // table, not the strip model: `visible` already carries the debounce and the
  // stop grace, and no settings path can empty it -- the master toggle and both
  // ring toggles stop the drawing, not the capture. See
  // ShareModel.anyVisibleSession.
  //
  // Not gated on root.active: pausing does not stop the capture, so this stays
  // true while paused. What pausing changes is that no ring is drawn (the
  // chip's slashed glyph says so) and, below, that no toast is sent.
  readonly property bool sharingNow: ShareModel.anyVisibleSession(shareState)
  property string lastEvent: "starting"
  property string lastEventAt: ""
  property bool sawScreencastV2: false
  property bool warnedLegacyOnly: false

  // ---------------------------------------------------------------- settings

  function clampInt(value, fallback, min, max) {
    var n = Number(value)
    if (!isFinite(n)) return fallback
    n = Math.floor(n)
    if (n < min) return min
    if (n > max) return max
    return n
  }

  // An unparseable color would silently render the ring invisible, which is the
  // one failure the user cannot see. Fall back loudly instead.
  function validColor(value, fallback) {
    var s = String(value === undefined || value === null ? "" : value).trim()
    if (!s) return fallback
    if (/^#([0-9a-fA-F]{3,8})$/.test(s)) return s
    if (/^[a-zA-Z]+$/.test(s)) return s
    console.warn("screen-sharing-indicator: ignoring unusable color " + s + "; using " + fallback)
    return fallback
  }

  // Strips a leading alpha pair from Qt's "#aarrggbb" stringification of a
  // color, leaving the "#rrggbb" form ShareModel's pure hex parser accepts.
  // Opaque colors already stringify as "#rrggbb" and pass through unchanged.
  function normalizeAccent(hex) {
    var s = String(hex || "")
    if (s.charAt(0) === "#" && s.length === 9) return "#" + s.slice(3)
    return s
  }

  // ---------------------------------------------------------------- logging

  function truncate(text, limit) {
    var s = String(text === undefined || text === null ? "" : text)
    var n = limit || 60
    return s.length <= n ? s : s.slice(0, n) + "…"
  }

  function logEvent(event, details) {
    var suffix = details === undefined || details === null || details === "" ? "" : ": " + String(details)
    root.lastEventAt = new Date().toISOString()
    root.lastEvent = event + suffix
    console.log("screen-sharing-indicator " + root.lastEventAt + " " + root.lastEvent)
  }

  // ---------------------------------------------------------------- Hyprland

  function toplevelList() {
    var model = Hyprland.toplevels
    if (!model) return []
    var values = model.values
    return values ? values : []
  }

  function monitorList() {
    var model = Hyprland.monitors
    if (!model) return []
    var values = model.values
    return values ? values : []
  }

  function monitorNameForIndex(index) {
    if (index === undefined || index === null) return ""
    var monitors = monitorList()
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      var id = monitor.id !== undefined ? monitor.id : (monitor.lastIpcObject ? monitor.lastIpcObject.id : undefined)
      if (id === index) return String(monitor.name ? monitor.name : "")
    }
    return ""
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
  }

  function handleHyprlandEvent(event) {
    if (!event || !event.name) return
    var name = String(event.name)

    if (name === "screencastv2") {
      root.sawScreencastV2 = true
      handleShareEvent(event)
      return
    }

    // 0.56.2 posts screencast immediately before screencastv2 for the same
    // session, so v1 arriving is not evidence that v2 is missing. Give the
    // pair a moment to land before concluding anything.
    if (name === "screencast") {
      if (root.sawScreencastV2 || root.warnedLegacyOnly) return
      legacyProbe.restart()
      return
    }

    // The per-monitor active workspace decides whether a tracked window is
    // drawable, and Hyprland.monitors does not track it without a refresh --
    // it keeps whatever was current when the shell started. A stale value that
    // matches the window's workspace pins the ring on every desktop of that
    // output; one that differs means the ring never appears at all. Neither
    // looks like a stale read from the outside.
    if (name === "workspace" || name === "workspacev2"
        || name === "focusedmon" || name === "focusedmonv2"
        || name === "moveworkspace" || name === "moveworkspacev2"
        || name === "monitoradded" || name === "monitorremoved") {
      Hyprland.refreshMonitors()
      monitorSettle.restart()
      return
    }

    // Every reload re-runs hypr.lua, so this is the one moment the layer
    // rule could have gone missing (snippet commented out, plugin removed,
    // hypr.lua broken). See the layer-rule section for why this requires
    // fresh content rather than mere presence.
    if (name === "configreloaded") {
      root.startLayerRuleCheck()
      return
    }

    // movewindow changes the window's own workspace, which is the other half
    // of the same comparison.
    if (name === "windowtitlev2" || name === "openwindow" || name === "closewindow"
        || name === "movewindow" || name === "movewindowv2") {
      syncWindowSessions()
      monitorSettle.restart()
    }
  }

  // refreshMonitors() is a round trip, so the data is not there yet when the
  // event handler returns. The 33 ms geometry poll would pick it up, but only
  // while a window ring is visible, so re-sync explicitly instead.
  Timer {
    id: monitorSettle
    interval: 50
    repeat: false
    onTriggered: root.syncStrips()
  }

  // v1 carries no NAME, so on a build that only emits it we can say "something
  // is capturing" but never which surface. Showing the wrong window is worse
  // than showing nothing, so we show nothing and say so once.
  Timer {
    id: legacyProbe
    interval: 250
    repeat: false
    onTriggered: {
      if (root.sawScreencastV2 || root.warnedLegacyOnly) return
      root.warnedLegacyOnly = true
      console.warn("screen-sharing-indicator: this build emits screencast without screencastv2; no target name on the wire, so no ring will be shown")
    }
  }

  function handleShareEvent(event) {
    var parsed = ShareModel.parseScreencastV2(event)
    if (!parsed.type) {
      logEvent("event-in", "unparsed " + truncate(event.data))
      return
    }

    logEvent("event-in", (parsed.active ? "start " : "stop ") + parsed.type + " " + truncate(parsed.name))

    // A stop carries the window's title *now*, not the one the session was
    // opened with, so a mid-share retitle would stop under a key that was
    // never started. Hand the model the addresses and let it resolve by
    // identity instead.
    if (!parsed.active && parsed.type === ShareModel.OWNER_WINDOW) {
      Hyprland.refreshToplevels()
      var hits = ShareModel.matchWindows(toplevelList(), parsed.name, [])
      var resolved = []
      for (var h = 0; h < hits.length; h++) resolved.push(hits[h].address)
      parsed.addresses = resolved
    }

    var result = ShareModel.applyEvent(root.shareState, parsed, Date.now(),
                                       root.debounceMs, root.stopGraceMs)
    var next = result.state
    var i

    // Match now, not when the debounce fires. Hyprland's NAME is the title
    // captured at session init; Teams has usually retitled by the time the ring
    // is due, and a title match then would come back empty.
    for (i = 0; i < result.armKeys.length; i++) {
      next = matchOnStart(next, result.armKeys[i])
      logEvent("debounce-arm", parsed.type + " " + truncate(parsed.name) + " in " + root.debounceMs + "ms")
    }

    for (i = 0; i < result.cancelKeys.length; i++) {
      logEvent("debounce-cancel", parsed.type + " " + truncate(parsed.name))
    }

    // The session stays exactly as it is -- same seq, same addresses, same
    // strip ids -- so a restart inside the grace never remaps a surface.
    for (i = 0; i < result.graceKeys.length; i++) {
      // The session's own name, which is not always the one the stop carried.
      // Showing both makes a retitled stop visible instead of invisible.
      var gname = result.graceKeys[i].split("\0")[1]
      logEvent("stop-grace", parsed.type + " " + truncate(gname)
               + (gname === parsed.name ? "" : " [stop arrived as \"" + truncate(parsed.name) + "\"]")
               + " holding " + root.stopGraceMs + "ms")
    }

    for (i = 0; i < result.revivedKeys.length; i++) {
      logEvent("revived", parsed.type + " " + truncate(parsed.name) + " inside the grace")
    }

    for (i = 0; i < result.dropped.length; i++) {
      onSessionDropped(result.dropped[i])
    }

    // applyEvent hands back the same state object when it found nothing to
    // apply. For a stop that means no session owned it, by address or by name
    // -- a ring nothing will take down. Rare, and invisible without this line.
    if (!parsed.active && result.state === root.shareState) {
      logEvent("stop-orphan", parsed.type + " " + truncate(parsed.name)
               + " matched no session")
    }

    root.shareState = next
    rescheduleDebounce()
    rescheduleGrace()
    rescheduleReap()
  }

  function matchOnStart(state, key) {
    var session = state.sessions[key]
    if (!session || session.type !== ShareModel.OWNER_WINDOW) return state

    Hyprland.refreshToplevels()
    var matches = ShareModel.matchWindows(toplevelList(), session.name, [])
    if (!matches.length) {
      // The only unmatched-title log: retries below stay quiet.
      logEvent("match-miss", "unmatched window title=" + truncate(session.name))
      return state
    }

    var addresses = []
    for (var i = 0; i < matches.length; i++) addresses.push(matches[i].address)
    logEvent(addresses.length > 1 ? "match-multi" : "match-ok",
             addresses.length + " window(s) for " + truncate(session.name))
    return ShareModel.attachAddresses(state, key, addresses, Date.now())
  }

  // Windows opening, closing or retitling while a session is tracked. Sticky:
  // once addresses are frozen the title is never consulted again, except to
  // recover a target that has disappeared entirely.
  function syncWindowSessions() {
    var state = root.shareState
    var keys = []
    for (var key in state.sessions) {
      if (state.sessions[key].type === ShareModel.OWNER_WINDOW) keys.push(key)
    }
    if (!keys.length) return

    Hyprland.refreshToplevels()
    var list = toplevelList()
    var next = state

    for (var i = 0; i < keys.length; i++) {
      var sessionKey = keys[i]
      var session = next.sessions[sessionKey]
      var addresses = session.addresses || []

      if (addresses.length) {
        var alive = ShareModel.matchWindows(list, session.name, addresses)
        if (alive.length === addresses.length) continue
        if (alive.length) {
          var kept = []
          for (var j = 0; j < alive.length; j++) kept.push(alive[j].address)
          next = ShareModel.attachAddresses(next, sessionKey, kept, Date.now())
          continue
        }
        // Every tracked window is gone; fall through and try the title once.
      }

      var retry = ShareModel.matchWindows(list, session.name, [])
      if (!retry.length) {
        if (addresses.length) next = ShareModel.attachAddresses(next, sessionKey, [], Date.now())
        continue
      }
      var found = []
      for (var m = 0; m < retry.length; m++) found.push(retry[m].address)
      next = ShareModel.attachAddresses(next, sessionKey, found, Date.now())
      logEvent("match-ok", "recovered " + found.length + " window(s) for " + truncate(session.name))
    }

    // Remember what each tracked window is called now, so a stop arriving
    // under a title the window has already left can still find its session.
    // windowtitlev2 brings us here on every retitle, which is exactly when
    // there is a new name worth keeping.
    for (var s2 = 0; s2 < keys.length; s2++) {
      var known = next.sessions[keys[s2]]
      if (!known) continue
      var owned = known.addresses || []
      for (var n = 0; n < owned.length; n++) {
        var live = findToplevel(list, owned[n])
        if (live) next = ShareModel.recordName(next, keys[s2], ShareModel.toplevelTitle(live))
      }
    }

    if (next !== state) {
      root.shareState = next
      rescheduleReap()
    }
  }

  // ---------------------------------------------------------------- layer rule

  // Nothing in Hyprland queries layer rules -- there is no `hyprctl
  // layerrules` -- so hypr.lua leaves a marker file behind every time it runs,
  // and that marker is the only evidence the no_screen_share rule loaded.
  //
  // The marker is never deleted. The obvious design -- clear it, wait, treat
  // its return as proof hypr.lua just ran -- cannot survive a reload followed
  // by shell restarts with no further reload: `hyprctl reload` returns "ok"
  // only after hypr.lua has already run, so the reload check's own delete
  // consumes the only evidence a later startup check could read. Gating which
  // caller may delete does not help, because the reload path has to delete on
  // every "ok" to stay self-correcting.
  //
  // Instead hypr.lua writes a value that changes on every run (epoch seconds
  // plus os.clock(), which free-runs for the life of the Hyprland process, so
  // two runs never tie). A reload check demands the content differ from the
  // last confirmed value -- proof hypr.lua ran for *this* reload. A startup
  // check demands only that content be present -- proof the rule was loaded as
  // of whenever it was last confirmed.
  //
  // "Last confirmed" is layerRuleLastContent below, a plain in-memory property:
  // "" at every fresh construction. Comparing a reload against an unseeded ""
  // is a trap, not a conservative default -- hypr.lua never writes "", so any
  // content on disk, stale marker included, reads as changed and passes as
  // fresh. That is a false "ok" on the highest-consequence signal in the
  // project, and it is reachable: the shell restarts, and a `hyprctl reload`
  // lands inside the ~250 ms-1 s settle window before the startup check has
  // read anything to seed with. So no freshness check runs until
  // seedLayerRuleBaseline has completed once -- see the gate at the top of
  // startLayerRuleCheck. Seeding is unconditional, so a check deferred behind
  // it is left "checking", never "missing".
  //
  // A deferred reload draws no verdict from a comparison either. Seeding is
  // its own read, racing that reload's hypr.lua write; if it lands after the
  // write, the baseline holds the very content the reload produced, and
  // comparing would report "missing" on a rule that just loaded fine. There is
  // no telling from here which way the race went, so a deferred reload resolves
  // to "indeterminate" -- no warning, no all-clear -- and the next ordinary
  // reload answers it for real. See onLayerRuleBaselineSeeded.
  //
  // Both paths share one settle/retry timer pair. Before seeding a reload never
  // touches it, only marking itself pending; after seeding, a reload preempting
  // an in-flight startup check is correct, since it is strictly newer
  // information.
  readonly property string layerRuleMarkerPath: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    var sig = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    if (!runtime || !sig) return ""
    return runtime + "/hypr/" + sig + "/screen-sharing-indicator-rule"
  }

  readonly property int layerRuleMaxRetries: 1
  // Strictly derived, never assigned: "ok" is the only state in which this
  // service has confirmed the rule loaded. A stored boolean initialised true
  // would read true during "checking" and forever on "indeterminate" -- the
  // state a configreloaded landing in the baseline-seed window produces, which
  // is the window the README's own install sequence opens (restart the shell,
  // then hyprctl reload). statusJson offers this as proof the rule loaded, and
  // an initialiser nobody overwrote is not proof.
  //
  // Reading false while "checking" raises no alarm: the UI warning comes from
  // ShareModel.layerRuleSeverity, which answers "" for everything but a
  // confirmed "missing". statusJson is the only consumer, and there
  // layerRuleCheckState beside it says which flavour of unconfirmed it is.
  readonly property bool layerRuleOk: root.layerRuleCheckState === "ok"
  property string layerRuleCheckState: "checking"
  property int layerRulePendingRetries: 0
  // The last marker content this service confirmed, reload or startup alike --
  // untrustworthy until layerRuleBaselineSeeded is true. Every terminal verdict
  // that saw non-empty content updates it, so the next check of either kind
  // compares against what was last actually observed.
  property string layerRuleLastContent: ""
  property bool layerRuleBaselineSeeded: false
  // A configreloaded landed while the seed read was still in flight. Its
  // verdict is drawn once seeding finishes, but never by comparison -- see
  // onLayerRuleBaselineSeeded for why.
  property bool layerRuleReloadPendingSeed: false
  // Whether the check in flight requires the content to have changed to
  // count as healthy (reload path) or merely be present (startup path). See
  // startLayerRuleCheck / startLayerRuleCheckAtStartup.
  property bool layerRuleRequireFresh: true

  // The one-shot, unconditional read that seeds layerRuleLastContent before
  // anything may compare against it. A separate Process from layerRuleChecker
  // below because it never produces a verdict of its own -- it never touches
  // layerRuleCheckState, only the baseline.
  Process {
    id: layerRuleSeeder
    running: false
    stdout: StdioCollector {
      id: layerRuleSeederOut
      onStreamFinished: root.onLayerRuleBaselineSeeded(text)
    }
  }

  function seedLayerRuleBaseline() {
    if (!root.layerRuleMarkerPath) {
      root.onLayerRuleBaselineSeeded("")
      return
    }
    layerRuleSeeder.running = false
    layerRuleSeeder.command = ["sh", "-c", "cat \"$1\" 2>/dev/null", "sh", root.layerRuleMarkerPath]
    layerRuleSeeder.running = true
  }

  function onLayerRuleBaselineSeeded(content) {
    root.layerRuleLastContent = String(content === undefined || content === null ? "" : content).trim()
    root.layerRuleBaselineSeeded = true
    if (root.layerRuleReloadPendingSeed) {
      root.layerRuleReloadPendingSeed = false
      // This read and the deferred reload raced each other, so there is no
      // telling whether this content is what hypr.lua wrote for that reload or
      // something older. Comparing could go either wrong way -- fresh when
      // nothing was proven, or a false "missing" on a rule that just loaded
      // fine -- so this reload draws no verdict at all. The next ordinary
      // reload compares against a baseline this race cannot touch.
      root.layerRuleCheckState = "indeterminate"
    } else {
      root.startLayerRuleCheckAtStartup()
    }
  }

  Process {
    id: layerRuleChecker
    running: false
    stdout: StdioCollector {
      id: layerRuleCheckerOut
      onStreamFinished: root.finishLayerRuleCheck(text)
    }
  }

  function checkLayerRuleMarker(retriesUsed) {
    root.layerRulePendingRetries = retriesUsed
    // With no env vars the path itself cannot be trusted, so the rule can
    // never be confirmed loaded. Fail toward the warning rather than toward
    // silently assuming the audience is protected.
    if (!root.layerRuleMarkerPath) {
      root.finishLayerRuleCheck("")
      return
    }
    layerRuleChecker.running = false
    layerRuleChecker.command = ["sh", "-c", "cat \"$1\" 2>/dev/null", "sh", root.layerRuleMarkerPath]
    layerRuleChecker.running = true
  }

  function finishLayerRuleCheck(content) {
    var trimmed = String(content === undefined || content === null ? "" : content).trim()
    // Never reached with an unseeded baseline: startLayerRuleCheck defers
    // instead of starting this cycle until seedLayerRuleBaseline has run,
    // and startLayerRuleCheckAtStartup is only ever called after it too.
    var present = ShareModel.layerRuleContentPresent(trimmed, root.layerRuleRequireFresh, root.layerRuleLastContent)
    var state = ShareModel.layerRuleState(present, root.layerRulePendingRetries, root.layerRuleMaxRetries)
    root.layerRuleCheckState = state
    if (state === "checking") {
      layerRuleRetryTimer.restart()
      return
    }
    // Record whatever was actually seen, so the next check compares against
    // reality rather than being reset to empty by a momentary read failure.
    // layerRuleOk needs no assignment: it derives from the state set above.
    if (trimmed !== "") root.layerRuleLastContent = trimmed
  }

  Timer {
    id: layerRuleSettleTimer
    interval: 250
    repeat: false
    onTriggered: root.checkLayerRuleMarker(0)
  }

  // Fires 750 ms after the settle check, i.e. 1 s after startLayerRuleCheck
  // was called -- only ever started from finishLayerRuleCheck's "checking"
  // branch, so a settle check that already found the marker fresh never
  // triggers a spurious re-check.
  Timer {
    id: layerRuleRetryTimer
    interval: 750
    repeat: false
    onTriggered: root.checkLayerRuleMarker(1)
  }

  // Reload path: the content must differ from the last confirmed value --
  // proof hypr.lua ran for *this* reload, not evidence left from an earlier
  // one. Refuses to compare at all until the baseline seed has completed; see
  // the layer-rule commentary above for the false "ok" that gate closes.
  function startLayerRuleCheck() {
    if (!root.layerRuleBaselineSeeded) {
      root.layerRuleReloadPendingSeed = true
      root.layerRuleCheckState = "checking"
      return
    }
    root.layerRuleCheckState = "checking"
    root.layerRuleRequireFresh = true
    layerRuleRetryTimer.stop()
    layerRuleSettleTimer.restart()
  }

  // Startup path: any content at all is enough. hypr.lua already ran (at
  // Hyprland's startup, or whatever reload came before) and nothing deletes
  // the marker, so restarting the shell changes nothing about it. Only ever
  // called from onLayerRuleBaselineSeeded, never from Component.onCompleted.
  function startLayerRuleCheckAtStartup() {
    root.layerRuleCheckState = "checking"
    root.layerRuleRequireFresh = false
    layerRuleRetryTimer.stop()
    layerRuleSettleTimer.restart()
  }

  // ------------------------------------------------------------------ cursor

  // Whether your pointer reaches the audience is governed entirely by
  // xdph.conf's cursor_mode (see ShareModel.parseCursorMode / cursorState),
  // and it applies at portal start -- a file edited afterwards is set and inert
  // at once, which is why "stale" is worth telling apart from "ok".
  //
  // That comparison needs the portal's start time and the file's mtime in the
  // same clock. `ActiveEnterTimestampMonotonic` is CLOCK_MONOTONIC, which
  // pauses across suspend; converting it to wall clock would need a "now" in
  // that same paused clock, and the only one available without a new runtime
  // dependency -- /proc/uptime -- is CLOCK_BOOTTIME, which does not pause.
  // Mixing the two makes every suspend before the portal's last start look like
  // the portal is older than it is, pushing the verdict toward a false "stale".
  // systemd captures ActiveEnterTimestamp (wall clock) in the same instant, so
  // it needs no conversion at all, and that is what this uses.
  //
  // Named residual risk: `date -d` has to resolve whatever timezone
  // abbreviation systemd prints (e.g. "CEST"), and GNU date's table is
  // ambiguous for some zones. A misresolved abbreviation parses successfully
  // with a wrong epoch, which the `|| echo PORTAL_TS=0` guard cannot catch, and
  // can push the verdict either way. Confirmed correct for CEST, unproven
  // elsewhere; fixing it properly would mean reopening the clock-domain
  // question settled above.
  readonly property string xdphConfPath: {
    var home = Quickshell.env("HOME")
    return home ? home + "/.config/hypr/xdph.conf" : ""
  }

  property bool cursorFileExists: false
  property var cursorMode: null
  property double cursorFileMtimeMs: 0
  property double cursorPortalStartedMs: 0
  // True only when the systemctl invocation itself failed (dbus not up yet, a
  // transient bus error), not when it succeeded with an empty value because the
  // unit has never been active. That second case is a harmless "ok" -- nothing
  // can be sharing without a portal. The first must never be. See
  // ShareModel.cursorState.
  property bool cursorPortalQueryFailed: false

  readonly property string cursorState: ShareModel.cursorState(
    root.cursorFileExists, root.cursorMode, root.cursorFileMtimeMs,
    root.cursorPortalStartedMs, root.cursorPortalQueryFailed)

  Process {
    id: cursorChecker
    running: false
    stdout: StdioCollector {
      id: cursorCheckerOut
      onStreamFinished: root.finishCursorCheck(text)
    }
  }

  // One shell round trip for all four inputs, in a fixed order: exists +
  // mtime, whether the portal query failed, the portal's wall-clock start time
  // (or 0), a sentinel, then the raw file. Everything before the sentinel is
  // KEY=VALUE; everything after is the file verbatim, which may contain "=" or
  // blank lines and so is never parsed as fields.
  //
  // systemctl exits 0 with an empty --value for a known but inactive unit, and
  // non-zero only when the invocation itself failed. `rc` captures that:
  // assigning a command substitution to a plain variable carries the
  // substituted command's exit status into `$?`, which POSIX guarantees.
  function checkCursorState() {
    if (!root.xdphConfPath) {
      root.finishCursorCheck("")
      return
    }
    cursorChecker.running = false
    cursorChecker.command = ["sh", "-c",
      'p="$1"; if [ -f "$p" ]; then echo EXISTS=1; stat -c "MTIME=%Y" "$p" 2>/dev/null || echo MTIME=0; ' +
      'else echo EXISTS=0; echo MTIME=0; fi; ' +
      'ts=$(systemctl --user show -p ActiveEnterTimestamp --value xdg-desktop-portal-hyprland 2>/dev/null); ' +
      'rc=$?; if [ "$rc" -ne 0 ]; then echo PORTAL_QUERY_FAILED=1; else echo PORTAL_QUERY_FAILED=0; fi; ' +
      'if [ -n "$ts" ]; then date -d "$ts" +"PORTAL_TS=%s" 2>/dev/null || echo PORTAL_TS=0; ' +
      'else echo PORTAL_TS=0; fi; ' +
      'echo ===CONTENT===; cat "$p" 2>/dev/null',
      "sh", root.xdphConfPath]
    cursorChecker.running = true
  }

  function finishCursorCheck(text) {
    var raw = String(text === undefined || text === null ? "" : text)
    var marker = "===CONTENT===\n"
    var idx = raw.indexOf(marker)
    var header = idx >= 0 ? raw.substring(0, idx) : raw
    var content = idx >= 0 ? raw.substring(idx + marker.length) : ""
    var fields = {}
    var lines = header.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var eq = lines[i].indexOf("=")
      if (eq < 0) continue
      fields[lines[i].substring(0, eq)] = lines[i].substring(eq + 1)
    }
    root.cursorFileExists = fields.EXISTS === "1"
    root.cursorFileMtimeMs = (parseInt(fields.MTIME, 10) || 0) * 1000
    root.cursorPortalStartedMs = (parseInt(fields.PORTAL_TS, 10) || 0) * 1000
    root.cursorPortalQueryFailed = fields.PORTAL_QUERY_FAILED === "1"
    root.cursorMode = ShareModel.parseCursorMode(content)
  }

  // ------------------------------------------------------------- cursor fix

  // The one-shot action: write cursor_mode = 2 into xdph.conf and restart the
  // portal that reads it. That restart drops any live share, so it must never
  // run while one is up.
  //
  // Both halves of the refusal overlap, deliberately over-broad -- refusing
  // when it was safe costs one more button press; proceeding when it was not
  // costs someone's live presentation:
  //
  //   ringCount   every strip on screen, real sessions and a running preview.
  //   sharingNow  the session table. ringCount alone misses a live capture with
  //               either ring toggle off, which draws no strip at all.
  //
  // Read live at call time and read twice: applyCursorFix() only starts a `cat`
  // of the file, and the restart is one more async round trip after that in
  // onCursorFixContentRead(). A share starting in that window would otherwise
  // be dropped with no refusal logged.
  readonly property bool portalRestartUnsafe: root.ringCount > 0 || root.sharingNow
  property bool cursorFixBusy: false

  Process {
    id: cursorFixReader
    running: false
    stdout: StdioCollector {
      id: cursorFixReaderOut
      onStreamFinished: root.onCursorFixContentRead(text)
    }
  }

  Process {
    id: cursorFixWriter
    running: false
    stdout: StdioCollector {
      id: cursorFixWriterOut
      onStreamFinished: root.onCursorFixWritten(text)
    }
  }

  // Called directly by Panel.qml (mirrors svc.startPreview()) and wrapped
  // by the IpcHandler's fixCursor() below -- one implementation, both
  // callers get the same refusal and the same result string.
  function applyCursorFix() {
    if (root.portalRestartUnsafe) return "refused: sharing"
    if (root.cursorFixBusy) return "refused: busy"
    if (!root.xdphConfPath) return "refused: no home"

    root.cursorFixBusy = true
    logEvent("cursor-fix", "start")
    cursorFixReader.running = false
    cursorFixReader.command = ["sh", "-c", 'cat "$1" 2>/dev/null', "sh", root.xdphConfPath]
    cursorFixReader.running = true
    return "ok"
  }

  function onCursorFixContentRead(text) {
    var content = String(text === undefined || text === null ? "" : text)
    var next
    try {
      next = ShareModel.applyCursorModeFix(content)
    } catch (e) {
      console.warn("screen-sharing-indicator: cursor fix failed to compute the new file: " + e)
      logEvent("cursor-fix", "aborted: " + e)
      root.cursorFixBusy = false
      return
    }

    // The second of the two gates described above. Same property as the first,
    // read live, so the two cannot drift apart.
    if (root.portalRestartUnsafe) {
      logEvent("cursor-fix", "refused: sharing started before the write; aborted with nothing touched")
      root.cursorFixBusy = false
      return
    }

    // One script, so backup, write and restart happen in that order with no
    // window for this service to be killed between them, and any partial state
    // is legible from the log. A failed backup exits before the real file is
    // touched: an unwritable backup means an unwritable directory, and failing
    // loud beats skipping the one safety net this action has.
    cursorFixWriter.running = false
    cursorFixWriter.command = ["sh", "-c",
      'p="$1"; c="$2"; ' +
      'if [ -f "$p" ]; then cp -p "$p" "$p.bak.$(date +%s)" || { echo BACKUP_FAILED=1; exit 0; }; fi; ' +
      'printf "%s" "$c" > "$p" || { echo WRITE_FAILED=1; exit 0; }; ' +
      'echo WRITE_FAILED=0; ' +
      'systemctl --user restart xdg-desktop-portal-hyprland 2>&1; ' +
      'if [ "$?" -ne 0 ]; then echo RESTART_FAILED=1; else echo RESTART_FAILED=0; fi',
      "sh", root.xdphConfPath, next]
    cursorFixWriter.running = true
  }

  function onCursorFixWritten(text) {
    var out = String(text === undefined || text === null ? "" : text)
    root.cursorFixBusy = false
    if (/BACKUP_FAILED=1/.test(out)) logEvent("cursor-fix", "aborted: could not back up xdph.conf; nothing written")
    else if (/WRITE_FAILED=1/.test(out)) logEvent("cursor-fix", "backed up but failed to write xdph.conf; portal not restarted")
    else if (/RESTART_FAILED=1/.test(out)) logEvent("cursor-fix", "wrote xdph.conf but the portal restart failed: " + truncate(out))
    else logEvent("cursor-fix", "wrote xdph.conf and restarted the portal")
    // Re-read regardless of outcome, so a failed write or restart shows up as
    // a non-ok readout rather than a stale "ok".
    root.checkCursorState()
  }

  // ---------------------------------------------------------------- debounce

  // None of the three timers below is gated on root.active. They are what keeps
  // the session table -- the source of truth for "am I being captured" -- in
  // step with reality. Freezing them while paused would leave `visible` stuck
  // at whatever it held when the switch flipped: pause during a share, end the
  // share, and the chip stays red for the rest of the shell's life, then fires
  // a "stopped" toast whenever the plugin is switched back on.
  //
  // The cost is three one-shot timers that may fire while nothing is drawn.
  // They wake, mutate shareState, and syncStrips() returns at its own
  // `!active && !previewing` guard before touching the compositor.

  // One timer aimed at the nearest deadline rather than one per session:
  // concurrent OBS + Teams + a screenshot flash are independent keys, but only
  // the soonest of them needs to wake us.
  Timer {
    id: debounceTimer
    repeat: false
    onTriggered: root.fireDebounce()
  }

  function rescheduleDebounce() {
    debounceTimer.stop()

    // Not a plain scan of pending: a key waiting out its grace keeps an overdue
    // deadline fireDue will not clear, and a 1 ms timer aimed at it would spin
    // for the whole grace.
    var soonest = ShareModel.soonestPending(root.shareState)
    if (soonest < 0) return

    var delay = soonest - Date.now()
    debounceTimer.interval = delay > 1 ? delay : 1
    debounceTimer.start()
  }

  function fireDebounce() {
    var nowMs = Date.now()
    var due = ShareModel.dueKeys(root.shareState, nowMs)
    var next = ShareModel.fireDue(root.shareState, nowMs)

    for (var i = 0; i < due.length; i++) {
      var session = next.sessions[due[i]]
      if (!session) continue
      logEvent("debounce-fire", session.type + " " + truncate(session.name)
               + " addresses=" + (session.addresses || []).length)
    }

    root.shareState = next
    rescheduleDebounce()
  }

  // ---------------------------------------------------------------- grace

  // The teardown applyEvent deferred. One timer aimed at the soonest deadline,
  // for the same reason the debounce uses one.
  Timer {
    id: graceTimer
    repeat: false
    onTriggered: root.fireGrace()
  }

  function rescheduleGrace() {
    graceTimer.stop()

    var soonest = ShareModel.nextGraceDeadline(root.shareState)
    if (soonest < 0) return

    var delay = soonest - Date.now()
    graceTimer.interval = delay > 1 ? delay : 1
    graceTimer.start()
  }

  function fireGrace() {
    var result = ShareModel.expireGrace(root.shareState, Date.now())
    for (var i = 0; i < result.dropped.length; i++) onSessionDropped(result.dropped[i])

    root.shareState = result.state
    // Expiring a session removes its pending entry too, so the debounce timer
    // may now have nothing to wake for.
    rescheduleGrace()
    rescheduleDebounce()
    rescheduleReap()
  }

  // ---------------------------------------------------------------- reaper

  // The last resort. A window retitled *and* closed before its stop arrives
  // leaves a session neither its address nor its name can resolve, pinned above
  // zero for the life of the shell. Collect on age, since the refcount is
  // precisely what cannot be trusted.
  Timer {
    id: reapTimer
    repeat: false
    onTriggered: root.fireReap()
  }

  function rescheduleReap() {
    reapTimer.stop()

    var soonest = ShareModel.nextReapDeadline(root.shareState, ShareModel.REAP_ADDRESSLESS_MS)
    if (soonest < 0) return

    var delay = soonest - Date.now()
    reapTimer.interval = delay > 1 ? delay : 1
    reapTimer.start()
  }

  function fireReap() {
    var result = ShareModel.reapAddressLess(root.shareState, Date.now(),
                                            ShareModel.REAP_ADDRESSLESS_MS)
    for (var i = 0; i < result.dropped.length; i++) {
      var parts = result.dropped[i].key.split("\0")
      logEvent("reaped", parts[0] + " " + truncate(parts[1]) + " had no window for "
               + ShareModel.REAP_ADDRESSLESS_MS + "ms; strips="
               + result.dropped[i].stripIds.length)
    }

    root.shareState = result.state
    rescheduleReap()
    rescheduleDebounce()
  }

  // The name matters as much as the type: with several sessions in flight a
  // bare "session-drop: window" cannot be tied back to anything.
  function onSessionDropped(dropped) {
    var parts = dropped.key.split("\0")
    logEvent("session-drop", parts[0] + " " + truncate(parts[1])
             + " strips=" + dropped.stripIds.length)
  }

  onActiveChanged: {
    logEvent("settings", "active=" + root.active)
    // Unconditional, both directions -- see the comment above debounceTimer.
    // No-ops when nothing is pending, so switching off costs nothing.
    rescheduleDebounce()
    rescheduleGrace()
    rescheduleReap()
    // A mapped strip still contributes its black bbox to a capture even with a
    // transparent colour, so a soft disable has to unmap, not just hide.
    syncStrips()
  }

  // ---------------------------------------------------------------- strips

  // Rows are mutated in place, never cleared and re-appended, because stripId
  // stays stable for the life of a session. Unmapping and remapping a
  // layer-shell surface 30 times a second is not flicker-free.
  ListModel { id: stripModel }

  Instantiator {
    model: stripModel
    delegate: Strip {
      // Declared rather than relying on implicit delegate injection, the same
      // way Bar.qml's Variants delegate takes modelData.
      required property var model

      stripId: model.stripId
      screenName: model.screenName
      boxX: model.boxX
      boxY: model.boxY
      boxW: model.boxW
      boxH: model.boxH
      shown: model.shown
      stripColor: root.ringColor
      // A preview stays visible with the master toggle off: someone who just
      // switched the ring off is exactly who wants to check a colour or width
      // before switching it back on.
      pluginActive: root.active || root.previewing
      screenResolver: root.screenByName
    }
  }

  function screenByName(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name) === String(name)) return screens[i]
    }
    return null
  }

  function upsertStrip(stripId, screenName, boxX, boxY, boxW, boxH, shown) {
    for (var i = 0; i < stripModel.count; i++) {
      var row = stripModel.get(i)
      if (row.stripId !== stripId) continue
      // Skip untouched rows so a geometry tick on a still window writes nothing.
      if (row.screenName === screenName && row.boxX === boxX && row.boxY === boxY
          && row.boxW === boxW && row.boxH === boxH && row.shown === shown) return
      stripModel.set(i, {
        stripId: stripId, screenName: screenName,
        boxX: boxX, boxY: boxY, boxW: boxW, boxH: boxH, shown: shown
      })
      return
    }
    stripModel.append({
      stripId: stripId, screenName: screenName,
      boxX: boxX, boxY: boxY, boxW: boxW, boxH: boxH, shown: shown
    })
  }

  function removeStripsByIds(ids) {
    var want = {}
    for (var k = 0; k < (ids || []).length; k++) want[String(ids[k])] = true
    for (var i = stripModel.count - 1; i >= 0; i--) {
      if (want[String(stripModel.get(i).stripId)]) stripModel.remove(i)
    }
  }

  function keepOnlyStrips(wanted) {
    for (var i = stripModel.count - 1; i >= 0; i--) {
      if (!wanted[String(stripModel.get(i).stripId)]) stripModel.remove(i)
    }
  }

  function findToplevel(toplevels, address) {
    for (var i = 0; i < toplevels.length; i++) {
      if (ShareModel.normalizeAddress(toplevels[i].address) === address) return toplevels[i]
    }
    return null
  }

  function collectMonitorRows(session, monitors, rows) {
    var monitor = ShareModel.matchMonitor(monitors, session.name)
    if (!monitor) return

    // HyprlandMonitor.width/height are buffer pixels (3840x2160 on an output
    // at scale 1.25) while PanelWindow margins, window at/size and the monitor
    // layout origin are all logical (3072x1728 for the same output). Mixing
    // the two overhangs the output by the scale factor.
    var qs = screenByName(monitor.name)
    var size = ShareModel.logicalOutputSize(monitor.width, monitor.height, monitor.scale,
                                            qs ? qs.width : 0, qs ? qs.height : 0)
    var boxes = ShareModel.boxesForMonitor(size.w, size.h, root.widthPx)

    for (var i = 0; i < boxes.length; i++) {
      var box = boxes[i]
      rows.push({
        stripId: ShareModel.stripIdMonitor(session.seq, box.edge),
        screenName: String(monitor.name),
        boxX: box.boxX, boxY: box.boxY, boxW: box.boxW, boxH: box.boxH,
        shown: true
      })
    }
  }

  // Returns a summary of why this session mapped what it did, so syncStrips
  // can report a ring that is tracked but draws nothing.
  function collectWindowRows(session, monitors, toplevels, rows) {
    var summary = { targets: 0, drawable: 0, unresolved: 0, missing: 0, detail: "" }
    var addresses = session.addresses || []
    for (var a = 0; a < addresses.length; a++) {
      var toplevel = findToplevel(toplevels, addresses[a])
      if (!toplevel) {
        summary.missing++
        if (!summary.detail)
          summary.detail = "address " + addresses[a] + " is in none of the "
                         + toplevels.length + " live toplevels"
        continue
      }

      var obj = toplevel.lastIpcObject || {}
      // Resolve the monitor by IPC id, the way isWindowDrawable does. Two paths
      // for one question would let the workspace check answer against one
      // monitor while the geometry came from another.
      var monitor = ShareModel.monitorForWindow(monitors, obj) || toplevel.monitor
      if (!obj.at || !obj.size) {
        summary.missing++
        if (!summary.detail)
          summary.detail = "toplevel " + addresses[a] + " has no geometry yet: at="
                         + JSON.stringify(obj.at) + " size=" + JSON.stringify(obj.size)
        continue
      }
      if (!monitor) {
        summary.missing++
        if (!summary.detail)
          summary.detail = "no monitor for ipc id " + obj.monitor + " among " + monitors.length
        continue
      }

      summary.targets++
      if (screenByName(monitor.name) === null) summary.unresolved++

      // at/size are layout coordinates across the whole desktop; strips are
      // positioned relative to their own output.
      var localX = obj.at[0] - monitor.x
      var localY = obj.at[1] - monitor.y
      var boxes = ShareModel.boxesForWindow(localX, localY, obj.size[0], obj.size[1], root.widthPx)
      var drawable = ShareModel.isWindowDrawable(toplevel, monitors)
      if (drawable) summary.drawable++
      else if (!summary.detail) {
        // Report the values, not the verdict. Four conditions can withdraw a
        // ring and they call for completely different fixes.
        var mIpc = monitor.lastIpcObject ? monitor.lastIpcObject : monitor
        summary.detail = "not drawable on " + monitor.name
                       + ": mapped=" + obj.mapped + " hidden=" + obj.hidden
                       + " visible=" + obj.visible + " pinned=" + obj.pinned
                       + " windowWs=" + (obj.workspace ? obj.workspace.id : "?")
                       + " monitorActiveWs=" + (mIpc && mIpc.activeWorkspace ? mIpc.activeWorkspace.id : "?")
      }

      for (var i = 0; i < boxes.length; i++) {
        var box = boxes[i]
        rows.push({
          stripId: ShareModel.stripIdWindow(session.seq, addresses[a], box.edge),
          screenName: String(monitor.name),
          boxX: box.boxX, boxY: box.boxY, boxW: box.boxW, boxH: box.boxH,
          shown: drawable
        })
      }
    }
    return summary
  }

  // A tracked, visible session that maps nothing is indistinguishable from a
  // broken ring, from the presenter's seat and from a recording alike. Name the
  // reason once per change of state, never once per 33 ms poll.
  property var mapReasons: ({})

  // Prefer the concrete detail. One sentence covering all four causes makes
  // distinct faults read identically in the journal, which is the opposite of
  // what this line is for.
  function reasonFor(summary) {
    if (summary.targets === 0) return summary.detail || "no live window for the frozen address"
    if (summary.unresolved >= summary.targets)
      return summary.detail || "monitor name resolves to no Quickshell screen"
    if (summary.drawable === 0) return summary.detail || "window not drawable"
    return ""
  }

  // The focused output through the same boxesForMonitor path collectMonitorRows
  // uses for a real monitor share, so a preview draws exactly what a real share
  // would. Only the source of the "session" differs.
  function collectPreviewRows(rows) {
    var monitor = Hyprland.focusedMonitor
    if (!monitor) { root.previewIds = []; return }

    var qs = screenByName(monitor.name)
    var size = ShareModel.logicalOutputSize(monitor.width, monitor.height, monitor.scale,
                                            qs ? qs.width : 0, qs ? qs.height : 0)
    var boxes = ShareModel.boxesForMonitor(size.w, size.h, root.widthPx)
    var ids = []

    for (var i = 0; i < boxes.length; i++) {
      var box = boxes[i]
      var stripId = ShareModel.stripIdMonitor("preview", box.edge)
      ids.push(stripId)
      rows.push({
        stripId: stripId,
        screenName: String(monitor.name),
        boxX: box.boxX, boxY: box.boxY, boxW: box.boxW, boxH: box.boxH,
        shown: true
      })
    }
    root.previewIds = ids
  }

  // Full reconcile: build every row the current state wants, drop rows nothing
  // wants any more, then upsert. One code path covers a session appearing, a
  // window moving, addresses changing, a setting toggling, a preview and
  // teardown.
  function syncStrips() {
    if (!root.active && !root.previewing) {
      if (stripModel.count) stripModel.clear()
      return
    }

    var rows = []

    if (root.active) {
      var state = root.shareState
      var monitors = monitorList()
      var toplevels = toplevelList()
      var nextReasons = ({})

      for (var key in state.visible) {
        if (state.visible[key] !== true) continue
        var session = state.sessions[key]
        if (!session) continue

        if (session.type === ShareModel.OWNER_WINDOW) {
          if (root.showWindowRings) {
            var reason = reasonFor(collectWindowRows(session, monitors, toplevels, rows))
            nextReasons[key] = reason
            if (root.mapReasons[key] !== reason) {
              if (reason) logEvent("no-strips", truncate(session.name) + ": " + reason)
              else logEvent("strips-up", truncate(session.name) + " mapping normally")
            }
          }
        } else if (root.showMonitorRings) {
          collectMonitorRows(session, monitors, rows)
        }
      }

      // Rebuilt every pass, so a session that goes away stops being remembered.
      var reasonsChanged = false
      for (var rk in nextReasons) if (root.mapReasons[rk] !== nextReasons[rk]) reasonsChanged = true
      if (!reasonsChanged) for (var ok in root.mapReasons) if (!(ok in nextReasons)) reasonsChanged = true
      if (reasonsChanged) root.mapReasons = nextReasons
    }

    if (root.previewing) collectPreviewRows(rows)

    var wanted = {}
    var i
    for (i = 0; i < rows.length; i++) wanted[rows[i].stripId] = true
    keepOnlyStrips(wanted)
    for (i = 0; i < rows.length; i++) {
      var row = rows[i]
      upsertStrip(row.stripId, row.screenName, row.boxX, row.boxY, row.boxW, row.boxH, row.shown)
    }
  }

  // ---------------------------------------------------------------- preview

  Timer {
    id: previewTimer
    interval: 3000
    repeat: false
    onTriggered: root.stopPreview()
  }

  // previewing must already be true before syncStrips() runs: its early return
  // is `if (!root.active && !root.previewing) return`, so with the master toggle
  // off, calling it a moment sooner would clear the model and return without
  // adding a preview row.
  //
  // syncStrips() is wrapped so that a throw still leaves the timer armed.
  // Otherwise `previewing` sticks true forever, holding four dead strips on
  // screen and pinning portalRestartUnsafe with them -- worse than a preview
  // that failed to draw.
  function startPreview() {
    root.previewing = true
    try {
      syncStrips()
    } catch (e) {
      console.warn("screen-sharing-indicator: preview failed to map: " + e)
    }
    previewTimer.restart()
    logEvent("preview", "widthPx=" + root.widthPx + " color=" + root.ringColor)
  }

  // Order matters both ways: previewIds is read for removal before it is
  // cleared, and previewing is cleared last, since Strip's pluginActive is
  // `root.active || root.previewing` and flipping it false while a preview row
  // is still in the model would drop that row a moment early.
  //
  // Wrapped for the same reason as startPreview, in reverse: a throw here must
  // not leave `previewing` stuck true, and the timer has already fired.
  function stopPreview() {
    try {
      removeStripsByIds(root.previewIds)
    } catch (e) {
      console.warn("screen-sharing-indicator: preview cleanup failed: " + e)
    }
    root.previewIds = []
    root.previewing = false
  }

  function computeHasVisibleWindowTarget(state) {
    for (var key in state.visible) {
      if (state.visible[key] !== true) continue
      var session = state.sessions[key]
      if (session && session.type === ShareModel.OWNER_WINDOW) return true
    }
    return false
  }

  // Hyprland has no resize or pixel-move event (movewindow is workspace moves
  // only), so a tracked window's geometry has to be polled.
  Timer {
    id: geometryPoll
    interval: 33
    repeat: true
    running: root.active && root.hasVisibleWindowTarget
    onTriggered: {
      Hyprland.refreshToplevels()
      root.syncStrips()
    }
  }

  onShareStateChanged: syncStrips()
  onWidthPxChanged: syncStrips()
  onShowWindowRingsChanged: syncStrips()
  onShowMonitorRingsChanged: syncStrips()

  // ---------------------------------------------------------------- status

  function sessionSummaries() {
    var state = root.shareState
    var out = []
    for (var key in state.sessions) {
      var session = state.sessions[key]
      out.push({
        type: session.type,
        name: session.name,
        count: session.count,
        stopping: (session.stoppingAt || 0) > 0,
        addressLessSince: session.addressLessSince || 0,
        names: (session.names || []).slice(),
        visible: state.visible[key] === true,
        addresses: (session.addresses || []).slice()
      })
    }
    return out
  }

  function targetSummaries() {
    var state = root.shareState
    var out = []
    var monitors = monitorList()
    Hyprland.refreshToplevels()
    var toplevels = toplevelList()

    for (var key in state.sessions) {
      var session = state.sessions[key]

      if (session.type === ShareModel.OWNER_WINDOW) {
        var matched = ShareModel.matchWindows(toplevels, session.name, session.addresses)
        for (var i = 0; i < matched.length; i++) {
          var obj = matched[i].lastIpcObject || {}
          out.push({
            kind: "window",
            address: matched[i].address,
            monitor: monitorNameForIndex(obj.monitor),
            at: obj.at ? obj.at : null,
            size: obj.size ? obj.size : null,
            drawable: ShareModel.isWindowDrawable(matched[i], monitors)
          })
        }
        continue
      }

      var monitor = ShareModel.matchMonitor(monitors, session.name)
      out.push({
        kind: session.type,
        monitor: session.name,
        found: monitor !== null
      })
    }
    return out
  }

  // Logical sizes, for confirming a monitor ring was built from 3072 rather
  // than the 3840 buffer width.
  function screenSummaries() {
    var out = []
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      out.push({ name: String(screens[i].name), width: screens[i].width, height: screens[i].height })
    }
    return out
  }

  function statusJson() {
    return JSON.stringify({
      enabled: true,
      active: root.active,
      debounceMs: root.debounceMs,
      stopGraceMs: root.stopGraceMs,
      widthPx: root.widthPx,
      color: root.colorSpec,
      colorMode: root.colorMode,
      ringColor: root.ringColor,
      showWindowRings: root.showWindowRings,
      showMonitorRings: root.showMonitorRings,
      sessions: sessionSummaries(),
      targets: targetSummaries(),
      // "Is something being captured" and "is a ring drawn" are two questions,
      // and the ring toggles can make them disagree. Both reported.
      sharingNow: root.sharingNow,
      strips: stripModel.count,
      screens: screenSummaries(),
      lastEvent: root.lastEvent,
      lastEventAt: root.lastEventAt,
      layerRuleOk: root.layerRuleOk,
      layerRuleCheckState: root.layerRuleCheckState,
      cursorState: root.cursorState
    }, null, 2)
  }

  IpcHandler {
    target: "screen-sharing-indicator"

    function status(): string {
      return root.statusJson()
    }

    function debug(): string {
      return root.statusJson()
    }

    // Three seconds of the real strips on the focused output, through the
    // normal strip path, so it draws exactly what a real share would. No
    // notification and no red chip: both read sharingNow, and a preview creates
    // no session.
    function preview(): string {
      root.startPreview()
      return "ok"
    }

    // Writes cursor_mode = 2 into xdph.conf and restarts the portal that reads
    // it. Refuses while anything is being captured, since that restart drops a
    // live share. See applyCursorFix() for the gate and the write.
    function fixCursor(): string {
      return root.applyCursorFix()
    }

    // Diagnostic for the two monitor-resolution paths: collectWindowRows builds
    // screenName from toplevel.monitor, isWindowDrawable resolves via
    // monitorForWindow(). If those disagree, or the name resolves to no
    // Quickshell screen, rows are built that no surface can ever map.
    function toplevels(): string {
      Hyprland.refreshToplevels()
      var list = root.toplevelList()
      var monitors = root.monitorList()
      var out = []
      for (var i = 0; i < list.length; i++) {
        var t = list[i]
        var obj = t.lastIpcObject || {}
        var mon = t.monitor
        var byIpc = ShareModel.monitorForWindow(monitors, obj)
        var mIpc = byIpc && byIpc.lastIpcObject ? byIpc.lastIpcObject : byIpc
        out.push({
          title: String(ShareModel.toplevelTitle(t)).substring(0, 38),
          ipcMonitorId: obj.monitor === undefined ? null : obj.monitor,
          fromToplevel: mon ? String(mon.name) : "<null monitor>",
          fromToplevelX: mon ? mon.x : null,
          fromIpcId: byIpc ? String(byIpc.name) : "<no match>",
          screenResolves: mon ? (root.screenByName(mon.name) !== null) : false,
          windowWorkspace: obj.workspace ? obj.workspace.id : null,
          monitorActiveWorkspace: mIpc && mIpc.activeWorkspace ? mIpc.activeWorkspace.id : null,
          drawable: ShareModel.isWindowDrawable(t, monitors)
        })
      }
      return JSON.stringify(out, null, 2)
    }
  }

  // ---------------------------------------------------------------- notifications

  // Sent from the service rather than the panel so notifications work with no
  // bar on screen and no dropdown open.
  Process {
    id: notifier
    running: false
  }

  function sendNotification(summary, body) {
    if (!root.notify) return
    notifier.running = false
    notifier.command = ["notify-send", "--app-name=Screen sharing", "--", summary, body || ""]
    notifier.running = true
  }

  // The output a window session is currently drawn on, resolved the same way
  // collectWindowRows resolves it: first live address, its toplevel, and the
  // monitor that toplevel's IPC object names.
  function outputForWindowSession(session) {
    var addresses = session.addresses || []
    if (!addresses.length) return ""
    var toplevel = findToplevel(toplevelList(), addresses[0])
    if (!toplevel) return ""
    var obj = toplevel.lastIpcObject || {}
    var monitor = ShareModel.monitorForWindow(monitorList(), obj) || toplevel.monitor
    return monitor ? String(monitor.name) : ""
  }

  // The first live session's name and where it is drawn, e.g. "Firefox on
  // DP-1". A monitor session's name is already the output, so it needs no
  // suffix. Returns "" when nothing is live, which is why the stop toast --
  // fired after the ring has already dropped -- never calls it.
  function describeShare() {
    var sessions = sessionSummaries()
    for (var i = 0; i < sessions.length; i++) {
      var session = sessions[i]
      if (!session.visible) continue
      if (session.type !== ShareModel.OWNER_WINDOW) return session.name
      var output = outputForWindowSession(session)
      return output ? session.name + " on " + output : session.name
    }
    return ""
  }

  property bool lastSharingNow: false

  // Watches the session table, not the strip model. Three properties follow
  // from that, and no strip tally has any of them:
  //
  //   - A preview adds no session, so it can never trip an edge.
  //   - The idle-stop churn revives its session inside the grace without
  //     clearing `visible`, so a capture restarting every 500 ms still produces
  //     exactly one "started" and one "stopped".
  //   - No settings toggle can move it, so flipping a ring switch mid-share
  //     announces neither a stop nor a start.
  //
  // lastSharingNow is updated before the notify gate, never inside it: the edge
  // happened whether or not we may speak about it, and replaying it later --
  // announcing a stop the moment the plugin is switched back on -- would be its
  // own false report.
  onSharingNowChanged: {
    var move = ShareModel.ringTransition(root.lastSharingNow ? 1 : 0, root.sharingNow ? 1 : 0)
    root.lastSharingNow = root.sharingNow
    // The master toggle is the whole widget's off switch, not just the ring's,
    // so a paused indicator says nothing. sharingNow stays truthful throughout;
    // only the toast is suppressed.
    if (!root.active) return
    if (move === "up") sendNotification("Screen sharing started", describeShare())
    else if (move === "down") sendNotification("Screen sharing stopped", "")
  }

  Component.onCompleted: {
    // Hyprland has no "what is being captured right now?" query and will not
    // re-emit a start event for a session that is already running, so a shell
    // restart mid-share leaves us blind until the next share begins.
    console.log("screen-sharing-indicator: no live-session query; ring appears on next start event")
    logEvent("settings", "active=" + root.active + " debounceMs=" + root.debounceMs
             + " stopGraceMs=" + root.stopGraceMs
             + " widthPx=" + root.widthPx + " color=" + root.colorSpec)
    // hypr.lua already ran by the time the shell starts, loaded from
    // hyprland.lua at Hyprland's own startup, but no reload of this service's
    // own is behind that run -- so the startup check requires the marker to be
    // present, not fresh. Seeds the baseline first, always: see the layer-rule
    // commentary for why a reload racing in before that read completes must not
    // compare against "".
    root.seedLayerRuleBaseline()
    root.checkCursorState()
  }
}
