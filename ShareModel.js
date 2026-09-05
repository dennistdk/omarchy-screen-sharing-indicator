// Pure model for the share indicator. No timers, no QML types, no I/O.
//
// QML loads this with `import "ShareModel.js" as ShareModel`; the guarded
// module.exports tail lets tests/model.test.mjs require the same file from
// node. Parsing and state transitions live here, Timer objects in Service.qml.

var OWNER_MONITOR = "monitor"
var OWNER_WINDOW = "window"
var OWNER_REGION = "region"

var EDGES = ["t", "b", "l", "r"]

// How long a window session may sit with no window before it is collected.
// Generous: syncWindowSessions' recovery path only needs to survive a remap,
// which takes well under a second.
var REAP_ADDRESSLESS_MS = 5000

// How many titles a session remembers. A browser retitles on every tab switch
// and every playback change, so this has to be bounded; the newest are the ones
// a stop is most likely to carry.
var MAX_NAMES = 16

// ---------------------------------------------------------------- parsing

// String.split(sep, n) truncates instead of keeping the remainder, which would
// eat window titles containing commas. Keep everything after the (n-1)th
// separator in the last slot.
function splitLimit(s, sep, n) {
  var out = []
  var rest = String(s === null || s === undefined ? "" : s)
  for (var i = 1; i < n; i++) {
    var idx = rest.indexOf(sep)
    if (idx < 0) {
      out.push(rest)
      rest = ""
      break
    }
    out.push(rest.slice(0, idx))
    rest = rest.slice(idx + sep.length)
  }
  while (out.length < n - 1) out.push("")
  out.push(rest)
  return out
}

// A plain split(",") is wrong for screencastv2 because NAME is a window title.
// Always cap at three fields.
function eventPartsV2(event) {
  try {
    if (event && event.parse) {
      var parsed = event.parse(3)
      if (parsed && parsed.length) return parsed
    }
  } catch (error) {
  }
  return splitLimit(event && event.data ? event.data : "", ",", 3)
}

// Hyprland 0.56.2 formats OWNER through std::formatter<eScreenshareType>, so
// the wire token is "monitor"/"window"/"region". The integer arm is a fallback
// for a build without that specialization.
function parseOwner(raw) {
  var s = String(raw === null || raw === undefined ? "" : raw).trim().toLowerCase()
  if (s === OWNER_MONITOR || s === OWNER_WINDOW || s === OWNER_REGION) return s
  if (s === "0") return OWNER_MONITOR
  if (s === "1") return OWNER_WINDOW
  if (s === "2") return OWNER_REGION
  return ""
}

function parseScreencastV2(event) {
  var parts = eventPartsV2(event)
  return {
    active: String(parts[0]) === "1",
    type: parseOwner(parts[1]),
    name: String(parts[2] === undefined || parts[2] === null ? "" : parts[2])
  }
}

// JS session table only. Contains a NUL: never put it in a QML ListModel role,
// a required property string, a log line, or a stripId -- QString truncates
// at the NUL and two sessions would collide.
function sessionKey(type, name) {
  return String(type) + "\0" + String(name)
}

function normalizeAddress(addr) {
  var s = String(addr === null || addr === undefined ? "" : addr).trim().toLowerCase()
  if (s.indexOf("0x") === 0) s = s.slice(2)
  return s
}

// ---------------------------------------------------------------- strip ids

function stripIdMonitor(seq, edge) {
  return "s" + String(seq) + "-m" + String(edge)
}

function stripIdWindow(seq, addr, edge) {
  return "s" + String(seq) + "-w-" + normalizeAddress(addr) + "-" + String(edge)
}

// Deterministic from (seq, type, addresses), so the ids a teardown removes are
// always the ids the last upsert created.
function stripIdsForSession(session) {
  var ids = []
  if (!session) return ids
  var i
  var j
  if (session.type === OWNER_WINDOW) {
    var addresses = session.addresses || []
    for (i = 0; i < addresses.length; i++) {
      for (j = 0; j < EDGES.length; j++) {
        ids.push(stripIdWindow(session.seq, addresses[i], EDGES[j]))
      }
    }
    return ids
  }
  for (j = 0; j < EDGES.length; j++) {
    ids.push(stripIdMonitor(session.seq, EDGES[j]))
  }
  return ids
}

// ---------------------------------------------------------------- state

function emptyState() {
  return { seq: 0, sessions: {}, pending: {}, visible: {} }
}

function nextSeq(state) {
  return (state && state.seq ? state.seq : 0) + 1
}

function copyMap(map) {
  var out = {}
  for (var key in map || {}) out[key] = map[key]
  return out
}

function copySession(session) {
  return {
    type: session.type,
    name: session.name,
    seq: session.seq,
    count: session.count,
    sinceMs: session.sinceMs,
    stoppingAt: session.stoppingAt || 0,
    addressLessSince: session.addressLessSince || 0,
    names: (session.names || []).slice(),
    addresses: (session.addresses || []).slice(),
    stripIds: (session.stripIds || []).slice()
  }
}

function copyState(state) {
  var sessions = {}
  for (var key in state.sessions || {}) sessions[key] = copySession(state.sessions[key])
  return {
    seq: state.seq || 0,
    sessions: sessions,
    pending: copyMap(state.pending),
    visible: copyMap(state.visible)
  }
}

// A session in its stop grace has count 0 and is still on screen. Anything
// that asks "should this be drawn or timed?" has to go through here.
function isLive(session) {
  return !!session && session.count > 0
}

function clampGrace(stopGraceMs) {
  var n = Math.floor(Number(stopGraceMs))
  if (!isFinite(n) || n < 0) return 0
  return n
}

// Which session does a stop belong to? Not necessarily the one its NAME names:
// the start carries the title captured at session init, the stop the title
// *now*, so a window retitled mid-share stops under a key that was never
// started. The addresses frozen at start are the stable identity; the title is
// only a fallback.
function findSessionByAddresses(state, addresses) {
  var list = addresses || []
  if (!list.length) return ""
  var want = {}
  var i
  for (i = 0; i < list.length; i++) {
    var addr = normalizeAddress(list[i])
    if (addr) want[addr] = true
  }
  var sessions = state.sessions || {}
  for (var key in sessions) {
    var session = sessions[key]
    if (session.type !== OWNER_WINDOW) continue
    var own = session.addresses || []
    for (i = 0; i < own.length; i++) {
      if (want[own[i]]) return key
    }
  }
  return ""
}

// Every title this window has worn while tracked. The stop event carries
// m_name as of the last calculateConstraints(), which is neither the title the
// session opened with nor reliably the window's current one -- so an exact key
// can miss, and so can resolving the stop's title to a live window.
function recordName(state, key, name) {
  var session = state.sessions ? state.sessions[key] : null
  if (!session) return state
  var wanted = String(name === null || name === undefined ? "" : name)
  if (!wanted) return state
  if ((session.names || []).indexOf(wanted) !== -1) return state

  var next = copyState(state)
  var target = next.sessions[key]
  var list = (target.names || []).slice()
  list.push(wanted)
  while (list.length > MAX_NAMES) list.shift()
  target.names = list
  return next
}

function findSessionByAlias(state, type, name) {
  var wanted = String(name === null || name === undefined ? "" : name)
  if (!wanted) return ""
  var sessions = state.sessions || {}
  for (var key in sessions) {
    var session = sessions[key]
    if (session.type !== type) continue
    if ((session.names || []).indexOf(wanted) !== -1) return key
  }
  return ""
}

// Refcount the session table and say which debounce timers to arm or cancel.
// Never fires a timer, never matches a window: Service.qml does both.
//
// Returns { state, armKeys, cancelKeys, graceKeys, revivedKeys, dropped }.
// `dropped` carries the stripIds of sessions this event cleared, because the
// session is gone from the returned state and the caller still has to unmap
// those surfaces. With a grace configured a stop clears nothing here: it only
// reports `graceKeys`, and expireGrace() does the dropping later.
function applyEvent(state, parsed, nowMs, debounceMs, stopGraceMs) {
  var result = { state: state, armKeys: [], cancelKeys: [], graceKeys: [], revivedKeys: [], dropped: [] }
  if (!parsed || !parsed.type) return result

  var key = sessionKey(parsed.type, parsed.name)
  var next = copyState(state)
  var session = next.sessions[key]

  if (parsed.active) {
    // Hyprland restarting the capture after an idle stop. Same session:
    // keep seq, addresses, strip ids and the original debounce deadline, so
    // nothing unmaps and the pending show still fires on its own schedule.
    if (session && session.stoppingAt > 0) {
      session.stoppingAt = 0
      session.count = session.count + 1
      result.revivedKeys.push(key)
      result.state = next
      return result
    }

    if (!session) {
      next.seq = nextSeq(next)
      session = {
        type: parsed.type,
        name: String(parsed.name || ""),
        seq: next.seq,
        count: 0,
        sinceMs: nowMs,
        stoppingAt: 0,
        addressLessSince: 0,
        names: [String(parsed.name || "")],
        addresses: [],
        stripIds: []
      }
      next.sessions[key] = session
    }
    session.count = session.count + 1
    // Only a 0->1 transition arms a timer. A second client joining an already
    // tracked target just bumps the refcount.
    if (session.count === 1) {
      next.pending[key] = nowMs + debounceMs
      result.armKeys.push(key)
    }
    result.state = next
    return result
  }

  // Identity first, then the exact name, then any name the window has worn.
  // The middle step matters: a session actually called this owns the stop over
  // one that merely answered to the name earlier.
  var stopKey = key
  if (parsed.type === OWNER_WINDOW) {
    var owner = findSessionByAddresses(next, parsed.addresses)
    if (owner) stopKey = owner
    else if (!next.sessions[stopKey]) {
      var alias = findSessionByAlias(next, OWNER_WINDOW, parsed.name)
      if (alias) stopKey = alias
    }
  }
  session = next.sessions[stopKey]
  if (!session) return result

  session.count = Math.max(0, session.count - 1)
  if (session.count === 0) {
    // A real stop and Hyprland's 500 ms idle stop are the identical event, with
    // no live-session query to tell them apart, so wait it out.
    var grace = clampGrace(stopGraceMs)
    if (grace > 0) {
      session.stoppingAt = nowMs + grace
      result.graceKeys.push(stopKey)
      result.state = next
      return result
    }
    result.cancelKeys.push(stopKey)
    result.dropped.push({ key: stopKey, stripIds: (session.stripIds || []).slice() })
    delete next.pending[stopKey]
    delete next.visible[stopKey]
    delete next.sessions[stopKey]
  }
  result.state = next
  return result
}

// Freeze the matched addresses onto the session. Called on the start event,
// before the debounce timer, while NAME still equals the live window title.
function attachAddresses(state, key, addresses, nowMs) {
  var session = state.sessions ? state.sessions[key] : null
  if (!session) return state
  var next = copyState(state)
  var target = next.sessions[key]
  var had = (target.addresses || []).length
  var normalized = []
  for (var i = 0; i < (addresses || []).length; i++) {
    var addr = normalizeAddress(addresses[i])
    if (addr) normalized.push(addr)
  }
  target.addresses = normalized

  if (normalized.length) {
    target.addressLessSince = 0
  } else if (had) {
    // It had windows and now has none, so it is a candidate for collection.
    // A session that never matched anything is left alone: it draws nothing
    // and a later retitle may still recover it.
    var stamp = Math.floor(Number(nowMs))
    target.addressLessSince = isFinite(stamp) && stamp > 0 ? stamp : 0
  }

  target.stripIds = stripIdsForSession(target)
  return next
}

// The orphan collector. Ignores `count` deliberately: a session whose stop
// arrived under a retitled key stays pinned above zero forever, so the refcount
// is exactly what cannot be trusted here.
function reapAddressLess(state, nowMs, maxIdleMs) {
  var result = { state: state, dropped: [] }
  var bound = Math.floor(Number(maxIdleMs))
  if (!isFinite(bound) || bound < 0) return result

  var sessions = state.sessions || {}
  var dead = []
  for (var key in sessions) {
    var session = sessions[key]
    if (session.type !== OWNER_WINDOW) continue
    if ((session.addresses || []).length) continue
    var since = session.addressLessSince || 0
    if (since <= 0) continue
    if (nowMs - since >= bound) dead.push(key)
  }
  if (!dead.length) return result

  var next = copyState(state)
  for (var i = 0; i < dead.length; i++) {
    var gone = dead[i]
    result.dropped.push({ key: gone, stripIds: (next.sessions[gone].stripIds || []).slice() })
    delete next.pending[gone]
    delete next.visible[gone]
    delete next.sessions[gone]
  }
  result.state = next
  return result
}

function nextReapDeadline(state, maxIdleMs) {
  var bound = Math.floor(Number(maxIdleMs))
  if (!isFinite(bound) || bound < 0) return -1
  var soonest = -1
  var sessions = state.sessions || {}
  for (var key in sessions) {
    var session = sessions[key]
    if (session.type !== OWNER_WINDOW) continue
    if ((session.addresses || []).length) continue
    var since = session.addressLessSince || 0
    if (since <= 0) continue
    var due = since + bound
    if (soonest < 0 || due < soonest) soonest = due
  }
  return soonest
}

function dueKeys(state, nowMs) {
  var out = []
  var sessions = state.sessions || {}
  for (var key in state.pending || {}) {
    // A key whose session is stopped is skipped, not cancelled: its deadline
    // has to outlive the gap so a restart within the grace still shows on time.
    if (!isLive(sessions[key])) continue
    if (state.pending[key] <= nowMs) out.push(key)
  }
  return out
}

// The soonest deadline worth waking for. Grace keys are excluded: their
// deadline may already be past and fireDue refuses to clear it, so a timer
// aimed at one would spin for the length of the grace.
function soonestPending(state) {
  var sessions = state.sessions || {}
  var soonest = -1
  for (var key in state.pending || {}) {
    if (!isLive(sessions[key])) continue
    if (soonest < 0 || state.pending[key] < soonest) soonest = state.pending[key]
  }
  return soonest
}

function nextGraceDeadline(state) {
  var soonest = -1
  var sessions = state.sessions || {}
  for (var key in sessions) {
    var at = sessions[key].stoppingAt || 0
    if (at <= 0) continue
    if (soonest < 0 || at < soonest) soonest = at
  }
  return soonest
}

// The teardown applyEvent deferred. Same shape as applyEvent's `dropped`:
// the sessions are gone from the returned state, the caller unmaps the ids.
function expireGrace(state, nowMs) {
  var result = { state: state, dropped: [] }
  var sessions = state.sessions || {}
  var expired = []
  for (var key in sessions) {
    var at = sessions[key].stoppingAt || 0
    if (at > 0 && at <= nowMs) expired.push(key)
  }
  if (!expired.length) return result

  var next = copyState(state)
  for (var i = 0; i < expired.length; i++) {
    var gone = expired[i]
    result.dropped.push({ key: gone, stripIds: (next.sessions[gone].stripIds || []).slice() })
    delete next.pending[gone]
    delete next.visible[gone]
    delete next.sessions[gone]
  }
  result.state = next
  return result
}

// Move due pending keys into visible. Does NOT rematch titles: strips are
// mapped from sessions[key].addresses, frozen at start.
function fireDue(state, nowMs) {
  var due = dueKeys(state, nowMs)
  if (!due.length) return state
  var next = copyState(state)
  for (var i = 0; i < due.length; i++) {
    var key = due[i]
    delete next.pending[key]
    var session = next.sessions[key]
    if (!session || session.count <= 0) continue
    next.visible[key] = true
    session.stripIds = stripIdsForSession(session)
  }
  return next
}

// "Is anything on this machine being captured right now?" -- answered from the
// session table, never from the strip model.
//
// Strips answer a different question, "is a ring drawn", and three settings
// paths empty the strip model while the capture runs: the master toggle, and
// either ring toggle against a live share of that kind. `visible` means "past
// its debounce, not yet through its stop grace", which is what "being captured"
// means here, and no setting can touch it.
//
// Requires the session to still exist. expireGrace and applyEvent's immediate
// teardown delete from `sessions` and `visible` together, so a key in one and
// not the other should be impossible -- this refuses to report a share on a
// dangling flag rather than trust that.
function anyVisibleSession(state) {
  var visible = (state && state.visible) || {}
  var sessions = (state && state.sessions) || {}
  for (var key in visible) {
    if (visible[key] !== true) continue
    if (sessions[key]) return true
  }
  return false
}

// The word a panel row wears when the session is in the table but not on
// screen; "" for a row that is actually ringing. Such rows are labelled, never
// filtered: a capture the ring has not caught up with is still a capture, and
// hiding it is the unsafe direction. "starting" is the debounce; a session that
// stopped before its debounce fired is waiting out its grace instead, which is
// the same missing ring for a different reason.
function sessionStateWord(row) {
  if (!row) return ""
  if (row.visible === true) return ""
  return row.stopping === true ? "stopping" : "starting"
}

// ---------------------------------------------------------------- matching

function toplevelAddress(toplevel) {
  if (!toplevel) return ""
  if (toplevel.address) return normalizeAddress(toplevel.address)
  var obj = toplevel.lastIpcObject
  return obj && obj.address ? normalizeAddress(obj.address) : ""
}

function toplevelTitle(toplevel) {
  if (!toplevel) return ""
  if (typeof toplevel.title === "string") return toplevel.title
  var obj = toplevel.lastIpcObject
  return obj && typeof obj.title === "string" ? obj.title : ""
}

// Sticky: once addresses are frozen the title is never consulted again, because
// calculateConstraints() re-reads m_window->metadata().title() on every run and
// Teams retitles within the debounce window. The same refresh is why a stop
// cannot be trusted to name its own session -- see findSessionByAddresses.
function matchWindows(toplevels, name, previousAddresses) {
  var list = toplevels || []
  var out = []
  var i

  var previous = previousAddresses || []
  if (previous.length) {
    var want = {}
    for (i = 0; i < previous.length; i++) want[normalizeAddress(previous[i])] = true
    for (i = 0; i < list.length; i++) {
      if (want[toplevelAddress(list[i])]) out.push(list[i])
    }
    return out
  }

  var wanted = String(name === null || name === undefined ? "" : name)
  if (!wanted) return out
  for (i = 0; i < list.length; i++) {
    // Exact match, not substring and not case-folded. Every duplicate-title
    // window gets ringed, deliberately: the event names a title, not an
    // address, so ringing an arbitrary one would be a guess presented as fact.
    if (toplevelTitle(list[i]) === wanted) out.push(list[i])
  }
  return out
}

function monitorIpc(monitor) {
  if (!monitor) return {}
  return monitor.lastIpcObject ? monitor.lastIpcObject : monitor
}

function matchMonitor(monitors, name) {
  var list = monitors || []
  var wanted = String(name === null || name === undefined ? "" : name)
  if (!wanted) return null
  for (var i = 0; i < list.length; i++) {
    var candidate = list[i]
    var ipcName = candidate && candidate.name ? candidate.name : monitorIpc(candidate).name
    if (String(ipcName) === wanted) return candidate
  }
  return null
}

function monitorForWindow(monitors, obj) {
  var list = monitors || []
  var i
  for (i = 0; i < list.length; i++) {
    var ipc = monitorIpc(list[i])
    if (obj.monitor !== undefined && ipc.id !== undefined && ipc.id === obj.monitor) return list[i]
  }
  return null
}

function workspaceId(workspace) {
  if (workspace === null || workspace === undefined) return null
  if (typeof workspace === "object") return workspace.id === undefined ? null : workspace.id
  return workspace
}

// Whether the four strips should currently be shown. Tracking continues while
// a window is hidden or off-workspace; only visibility is withdrawn.
function isWindowDrawable(toplevel, monitors) {
  if (!toplevel) return false
  var obj = toplevel.lastIpcObject || {}
  if (obj.mapped === false) return false
  if (obj.hidden === true) return false
  if (obj.visible === false) return false
  if (obj.pinned === true) return true

  var monitor = monitorForWindow(monitors, obj)
  if (!monitor) return true
  var active = workspaceId(monitorIpc(monitor).activeWorkspace)
  var own = workspaceId(obj.workspace)
  if (active === null || own === null) return true
  return active === own
}

// ---------------------------------------------------------------- geometry

function clampWidth(widthPx) {
  var n = Math.floor(Number(widthPx))
  if (!isFinite(n) || n < 1) return 1
  if (n > 16) return 16
  return n
}

// outputW/outputH MUST be logical pixels (Quickshell.screens[n].width/height),
// never HyprlandMonitor.width/height. On a 3840x2160 output at scale 1.25 those
// differ by 768 px and the top strip would overhang the screen.
function boxesForMonitor(outputW, outputH, widthPx) {
  var out = []
  var w = Math.floor(Number(outputW))
  var h = Math.floor(Number(outputH))
  var strip = clampWidth(widthPx)
  if (!isFinite(w) || !isFinite(h) || w < 1 || h < 1) return out

  out.push({ edge: "t", boxX: 0, boxY: 0, boxW: w, boxH: Math.min(strip, h) })
  out.push({ edge: "b", boxX: 0, boxY: Math.max(0, h - strip), boxW: w, boxH: Math.min(strip, h) })

  var sideH = h - 2 * strip
  if (sideH >= 1 && w >= strip) {
    out.push({ edge: "l", boxX: 0, boxY: strip, boxW: Math.min(strip, w), boxH: sideH })
    out.push({ edge: "r", boxX: Math.max(0, w - strip), boxY: strip, boxW: Math.min(strip, w), boxH: sideH })
  }
  return out
}

// x/y are output-local logical pixels: lastIpcObject.at minus the monitor origin.
function boxesForWindow(x, y, w, h, widthPx) {
  var out = []
  var bx = Math.round(Number(x))
  var by = Math.round(Number(y))
  var bw = Math.round(Number(w))
  var bh = Math.round(Number(h))
  var strip = clampWidth(widthPx)
  if (!isFinite(bx) || !isFinite(by) || !isFinite(bw) || !isFinite(bh)) return out
  if (bw < 1 || bh < 1) return out

  out.push({ edge: "t", boxX: bx, boxY: by, boxW: bw, boxH: Math.min(strip, bh) })
  out.push({ edge: "b", boxX: bx, boxY: by + Math.max(0, bh - strip), boxW: bw, boxH: Math.min(strip, bh) })

  var sideH = bh - 2 * strip
  if (sideH >= 1 && bw >= strip) {
    out.push({ edge: "l", boxX: bx, boxY: by + strip, boxW: Math.min(strip, bw), boxH: sideH })
    out.push({ edge: "r", boxX: bx + Math.max(0, bw - strip), boxY: by + strip, boxW: Math.min(strip, bw), boxH: sideH })
  }
  return out
}

// Prefer the Quickshell screen size, which is already logical. The scale
// division is only a fallback for a monitor with no matching QuickshellScreenInfo.
function logicalOutputSize(monitorWidth, monitorHeight, scale, qsWidth, qsHeight) {
  var qw = Number(qsWidth)
  var qh = Number(qsHeight)
  if (isFinite(qw) && isFinite(qh) && qw > 0 && qh > 0) {
    return { w: Math.round(qw), h: Math.round(qh) }
  }
  var s = Number(scale)
  if (!isFinite(s) || s <= 0) s = 1
  return {
    w: Math.round(Number(monitorWidth) / s),
    h: Math.round(Number(monitorHeight) / s)
  }
}

// ---------------------------------------------------------------- settings

// Mirrors PluginRegistry.findEntryLocation (Omarchy 4.0.2,
// services/PluginRegistry.qml:206). A plugin gets one entry in shell.json: in
// bar.layout when placed as a widget, in plugins[] otherwise, with the bar
// winning if both exist -- the precedence updateEntryInline writes with. The
// runtime prefers the registry's own function; this makes the rule testable
// without a shell, and covers a shell that lacks it.
function entryFromConfig(shellConfig, id) {
  var key = String(id || "")
  if (!shellConfig || !key) return ({})
  var bar = shellConfig.bar
  if (bar && bar.layout) {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var arr = bar.layout[sections[s]]
      if (!arr || !arr.length) continue
      for (var i = 0; i < arr.length; i++) {
        if (arr[i] && String(arr[i].id) === key) return arr[i]
      }
    }
  }
  var plugins = shellConfig.plugins
  if (plugins && plugins.length) {
    for (var j = 0; j < plugins.length; j++) {
      if (plugins[j] && String(plugins[j].id) === key) return plugins[j]
    }
  }
  return ({})
}

// updateEntryInline (shell.qml:366) rebuilds the entry as {id} plus exactly
// what it is handed, so a partial write deletes every key it omits. Callers
// must always send the whole entry; this is how they build it.
function mergedSettings(current, changes) {
  var out = ({})
  if (current) for (var k in current) out[k] = current[k]
  if (changes) for (var c in changes) out[c] = changes[c]
  return out
}

// ------------------------------------------------------------------- colour

// The ring is deliberately not the theme accent: a capture cue should read as
// "you are being captured", not as decoration. Auto mode does not harmonise
// with the theme; it rescues the one case that breaks the cue, a theme accent
// close enough to the ring that the two stop being distinguishable.
var ALARM_HUE_START = 350   // the band the ring never leaves: red ...
var ALARM_HUE_END = 40      // ... through orange
var ALARM_MIN_SAT = 0.35    // below this an accent cannot compete, whatever its hue

function hexToRgb(hex) {
  var s = String(hex || "").trim()
  if (s.charAt(0) === "#") s = s.slice(1)
  if (s.length === 3) s = s.charAt(0) + s.charAt(0) + s.charAt(1) + s.charAt(1) + s.charAt(2) + s.charAt(2)
  if (!/^[0-9a-fA-F]{6}$/.test(s)) return null
  return {
    r: parseInt(s.slice(0, 2), 16) / 255,
    g: parseInt(s.slice(2, 4), 16) / 255,
    b: parseInt(s.slice(4, 6), 16) / 255
  }
}

function hexToHsl(hex) {
  var rgb = hexToRgb(hex)
  if (!rgb) return null
  var max = Math.max(rgb.r, rgb.g, rgb.b)
  var min = Math.min(rgb.r, rgb.g, rgb.b)
  var l = (max + min) / 2
  var d = max - min
  if (d === 0) return { h: 0, s: 0, l: l }
  var s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
  var h
  if (max === rgb.r) h = (rgb.g - rgb.b) / d + (rgb.g < rgb.b ? 6 : 0)
  else if (max === rgb.g) h = (rgb.b - rgb.r) / d + 2
  else h = (rgb.r - rgb.g) / d + 4
  return { h: h * 60, s: s, l: l }
}

function hslToHex(h, s, l) {
  h = ((h % 360) + 360) % 360
  var c = (1 - Math.abs(2 * l - 1)) * s
  var x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  var m = l - c / 2
  var r = 0, g = 0, b = 0
  if (h < 60) { r = c; g = x }
  else if (h < 120) { r = x; g = c }
  else if (h < 180) { g = c; b = x }
  else if (h < 240) { g = x; b = c }
  else if (h < 300) { r = x; b = c }
  else { r = c; b = x }
  function hx(v) {
    var n = Math.round((v + m) * 255)
    n = n < 0 ? 0 : (n > 255 ? 255 : n)
    var t = n.toString(16)
    return t.length === 1 ? "0" + t : t
  }
  return "#" + hx(r) + hx(g) + hx(b)
}

function hueDistance(a, b) {
  var d = Math.abs(((a - b) % 360 + 360) % 360)
  return d > 180 ? 360 - d : d
}

function hueInAlarmBand(h) {
  return h >= ALARM_HUE_START || h <= ALARM_HUE_END
}

// The band is a contiguous arc, so the point within it furthest from the
// accent is always one of its two endpoints.
function autoRingColor(baseHex, accentHex) {
  var base = hexToHsl(baseHex)
  var accent = hexToHsl(accentHex)
  if (!base || !accent) return baseHex
  if (accent.s <= ALARM_MIN_SAT) return baseHex
  if (!hueInAlarmBand(accent.h)) return baseHex
  var hue = hueDistance(accent.h, ALARM_HUE_START) >= hueDistance(accent.h, ALARM_HUE_END)
    ? ALARM_HUE_START : ALARM_HUE_END
  return hslToHex(hue, base.s, base.l)
}

// ------------------------------------------------------------ notifications

// "I don't know the count" must never become "the count is zero" -- that would
// announce a stop over a live share. Unknown in, silence out.
function toCount(value) {
  if (value === null || value === undefined || value === "") return null
  var n = Number(value)
  if (!isFinite(n) || n < 0) return null
  return n
}

// Fed from anyVisibleSession, never from a strip tally -- see that function for
// why the two questions must not share an answer. Previews are not sessions so
// they never toast, the idle-stop churn revives inside the grace without
// clearing `visible` so it never toasts either, and both edges carry the
// debounce and the stop grace because those are what `visible` is made of.
//
// Callers pass counts; a boolean goes in as 0/1, the same 0<->N edge.
function ringTransition(prevCount, nextCount) {
  var p = toCount(prevCount)
  var n = toCount(nextCount)
  if (p === null || n === null) return null
  if (p === 0 && n > 0) return "up"
  if (p > 0 && n === 0) return "down"
  return null
}

// ------------------------------------------------------------------- health

// Nothing in Hyprland queries layer rules, so hypr.lua drops a marker whose
// value changes on every run and the service compares it across checks. See
// Service.qml for the full scheme and for why the marker is never deleted.
// Removing the guarded snippet is caught at the next `hyprctl reload`: the
// marker does not change, the freshness check fails, and the state goes
// "missing".
//
// The accepted cost: that "missing" does not outlive the shell. A restart runs
// the startup check, which requires presence and not freshness, so it reads the
// same stale marker and reports "ok" again while the audience still sees the
// ring. Bounded rather than fixed -- the marker lives in
// $XDG_RUNTIME_DIR/hypr/$HIS/ and cannot survive a Hyprland restart, and the
// next reload reports "missing" once more. A freshness-requiring startup check
// would instead cry wolf on every restart of a healthy setup.
function layerRuleState(markerPresent, retriesUsed, maxRetries) {
  if (markerPresent) return "ok"
  if (Number(retriesUsed) < Number(maxRetries)) return "checking"
  return "missing"
}

// Whether a marker read counts as "the rule is currently loaded". A reload
// demands the content differ from the last confirmed value -- proof hypr.lua
// ran for *this* reload. A shell startup demands only that content exist --
// proof the rule was loaded as of whenever it was last confirmed. Empty is
// never present under either rule, since hypr.lua never writes an empty marker.
// Callers must never pass an unseeded baseline with requireFresh; there is no
// third "unknown" input to reason about here.
function layerRuleContentPresent(trimmedContent, requireFresh, lastConfirmedContent) {
  if (trimmedContent === "") return false
  if (!requireFresh) return true
  return trimmedContent !== lastConfirmedContent
}

// Whether your pointer reaches your audience is xdph.conf's cursor_mode, not
// anything this plugin controls. teams-for-linux sends no cursor_mode in its
// SelectSources call and the portal spec defaults an absent value to HIDDEN, so
// the pointer is silently omitted. cursor_mode = 2 (EMBEDDED) changes the
// default for clients that do not ask.
function parseCursorMode(text) {
  var lines = String(text || "").split("\n")
  var inBlock = false
  var depth = 0
  var mode = null
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/#.*$/, "").trim()
    if (!line) continue
    if (!inBlock) {
      if (/^screencopy\b/.test(line) && line.indexOf("{") >= 0) { inBlock = true; depth = 1 }
      continue
    }
    if (line.indexOf("}") >= 0) {
      depth--
      if (depth <= 0) { inBlock = false; continue }
    }
    if (line.indexOf("{") >= 0) depth++
    var m = line.match(/^cursor_mode\s*=\s*(\d+)/)
    if (m) mode = parseInt(m[1], 10)
  }
  return mode
}

// Applies at portal start, so a file edited after the portal came up is set and
// inert at once.
//
// portalStartedMs === 0 is ambiguous alone: the unit may never have started
// (systemd answers with an empty, successful value) or the query may itself
// have failed (dbus not up yet, a transient bus error). portalQueryFailed
// carries that distinction in. A failed query must not resolve to "ok" -- that
// is the silently-wrong-ok this readout exists to catch -- nor to "stale", since
// staleness is undeterminable here rather than asserted. It gets its own state.
function cursorState(fileExists, mode, fileMtimeMs, portalStartedMs, portalQueryFailed) {
  if (!fileExists) return "missing"
  if (mode === null || mode === undefined) return "unset"
  if (mode !== 2) return "hidden"
  if (portalQueryFailed) return "unknown"
  if (fileMtimeMs && portalStartedMs && fileMtimeMs > portalStartedMs) return "stale"
  return "ok"
}

// The health section's two state->severity mappers. Both readouts carry a state
// meaning "nothing trustworthy to report yet" -- layerRuleCheckState's
// "checking"/"indeterminate", cursorState's "unknown" -- and both must render
// exactly like a clean "ok": nothing at all, neither a warning nor a
// reassurance. So this answers "error" only for the one confirmed-bad state.
function layerRuleSeverity(layerRuleCheckState) {
  if (layerRuleCheckState === "missing") return "error"
  return ""
}

// "stale", "unset" and "hidden" are confirmed: the file exists, the portal has
// read it, and what it read will not reach the audience. "missing" (no
// xdph.conf at all) is just as confirmed. "unknown" is the one state this does
// not warn on -- the portal-start query failed, so staleness could not be
// determined either way, and warning would be the guess this refuses to make.
function cursorSeverity(cursorState) {
  if (cursorState === "stale" || cursorState === "unset"
      || cursorState === "hidden" || cursorState === "missing") return "warning"
  return ""
}

// The one-shot fix's file-preserving edit, pure so that "leave every other line
// byte-identical" can be proven without touching disk. Mirrors parseCursorMode's
// screencopy-block scan (first top-level block only; a real xdph.conf has
// exactly one) so the two never disagree about where cursor_mode lives. No file
// yet comes in as "" and gets a fresh minimal block; an existing block gains or
// updates its line in place; a file with no screencopy block gets one appended.
function applyCursorModeFix(content) {
  var text = String(content === undefined || content === null ? "" : content)
  if (text === "") return "screencopy {\n    cursor_mode = 2\n}\n"

  var lines = text.split("\n")
  var inBlock = false
  var depth = 0
  var blockStart = -1
  var blockEnd = -1
  var cursorLine = -1

  for (var i = 0; i < lines.length; i++) {
    var stripped = lines[i].replace(/#.*$/, "").trim()
    if (!inBlock) {
      if (blockStart < 0 && /^screencopy\b/.test(stripped) && stripped.indexOf("{") >= 0) {
        inBlock = true
        depth = 1
        blockStart = i
      }
      continue
    }
    if (stripped.indexOf("}") >= 0) {
      depth--
      if (depth <= 0) { blockEnd = i; inBlock = false; continue }
    }
    if (stripped.indexOf("{") >= 0) depth++
    if (cursorLine < 0 && /^cursor_mode\s*=\s*\d+/.test(stripped)) cursorLine = i
  }

  if (blockStart < 0) {
    // No screencopy block anywhere: keep every existing line, then append one.
    var base = lines.join("\n")
    if (base !== "" && base.charAt(base.length - 1) !== "\n") base += "\n"
    return base + "screencopy {\n    cursor_mode = 2\n}\n"
  }

  if (cursorLine >= 0) {
    // Rewrite only the value; anything else on the line (a trailing
    // comment, its own indentation) is untouched.
    lines[cursorLine] = lines[cursorLine].replace(/(cursor_mode\s*=\s*)\d+/, "$12")
    return lines.join("\n")
  }

  // No active cursor_mode line inside the block (absent, or commented out).
  // Insert one, matching whatever indentation a sibling line already uses.
  var indent = "    "
  for (var k = blockStart + 1; blockEnd >= 0 && k < blockEnd; k++) {
    var m = lines[k].match(/^(\s+)\S/)
    if (m) { indent = m[1]; break }
  }
  lines.splice(blockStart + 1, 0, indent + "cursor_mode = 2")
  return lines.join("\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    OWNER_MONITOR: OWNER_MONITOR,
    OWNER_WINDOW: OWNER_WINDOW,
    OWNER_REGION: OWNER_REGION,
    splitLimit: splitLimit,
    eventPartsV2: eventPartsV2,
    parseOwner: parseOwner,
    parseScreencastV2: parseScreencastV2,
    sessionKey: sessionKey,
    normalizeAddress: normalizeAddress,
    stripIdMonitor: stripIdMonitor,
    stripIdWindow: stripIdWindow,
    stripIdsForSession: stripIdsForSession,
    emptyState: emptyState,
    nextSeq: nextSeq,
    applyEvent: applyEvent,
    attachAddresses: attachAddresses,
    findSessionByAddresses: findSessionByAddresses,
    recordName: recordName,
    findSessionByAlias: findSessionByAlias,
    MAX_NAMES: MAX_NAMES,
    reapAddressLess: reapAddressLess,
    nextReapDeadline: nextReapDeadline,
    REAP_ADDRESSLESS_MS: REAP_ADDRESSLESS_MS,
    dueKeys: dueKeys,
    soonestPending: soonestPending,
    nextGraceDeadline: nextGraceDeadline,
    expireGrace: expireGrace,
    fireDue: fireDue,
    anyVisibleSession: anyVisibleSession,
    sessionStateWord: sessionStateWord,
    matchWindows: matchWindows,
    matchMonitor: matchMonitor,
    isWindowDrawable: isWindowDrawable,
    monitorForWindow: monitorForWindow,
    toplevelTitle: toplevelTitle,
    boxesForMonitor: boxesForMonitor,
    boxesForWindow: boxesForWindow,
    logicalOutputSize: logicalOutputSize,
    entryFromConfig: entryFromConfig,
    mergedSettings: mergedSettings,
    autoRingColor: autoRingColor,
    hexToHsl: hexToHsl,
    ALARM_HUE_START: ALARM_HUE_START,
    ALARM_HUE_END: ALARM_HUE_END,
    toCount: toCount,
    ringTransition: ringTransition,
    layerRuleState: layerRuleState,
    layerRuleContentPresent: layerRuleContentPresent,
    parseCursorMode: parseCursorMode,
    cursorState: cursorState,
    layerRuleSeverity: layerRuleSeverity,
    cursorSeverity: cursorSeverity,
    applyCursorModeFix: applyCursorModeFix
  }
}
