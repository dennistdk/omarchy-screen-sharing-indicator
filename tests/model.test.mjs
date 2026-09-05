import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const M = require("../ShareModel.js")
const fixtures = require("./fixtures/events.json")

// screencastv2>>1,window,Title  ->  "1,window,Title"
function dataOf(line) {
  const idx = line.indexOf(">>")
  return idx < 0 ? line : line.slice(idx + 2)
}

// Stand-in for Quickshell's HyprlandEvent.
function fakeEvent(data, { parse } = {}) {
  return parse ? { data, parse } : { data }
}

// ------------------------------------------------------------------ parsing

test("fixtures parse to their documented expectations", () => {
  for (const { why, line, expect } of fixtures.events) {
    const got = M.parseScreencastV2(fakeEvent(dataOf(line)))
    assert.deepEqual(got, expect, `${why}: ${line}`)
  }
})

test("fixture file still covers both OWNER spellings", () => {
  const types = fixtures.events.map((e) => dataOf(e.line).split(",")[1])
  assert.ok(types.includes("window"), "needs a string OWNER case")
  assert.ok(types.includes("1"), "needs an integer OWNER fallback case")
})

test("captured events prove this build spells OWNER, not numbers it", () => {
  const captured = fixtures.events.filter((e) => e.captured)
  assert.ok(captured.length > 0, "at least one real capture must be committed")
  for (const e of captured) {
    const owner = dataOf(e.line).split(",")[1]
    assert.ok(
      ["monitor", "window", "region"].includes(owner),
      `captured OWNER ${owner} should be a formatter string`
    )
  }
})

test("splitLimit keeps the remainder instead of truncating", () => {
  assert.deepEqual(M.splitLimit("1,window,A, B, C", ",", 3), ["1", "window", "A, B, C"])
  assert.deepEqual(M.splitLimit("1,window", ",", 3), ["1", "window", ""])
  assert.deepEqual(M.splitLimit("", ",", 3), ["", "", ""])
})

test("a comma title survives the event.parse(3) path", () => {
  const title = "Inbox - Foo, Bar - Microsoft Teams"
  const event = fakeEvent(`1,window,${title}`, {
    parse: (n) => M.splitLimit(`1,window,${title}`, ",", n)
  })
  assert.equal(M.parseScreencastV2(event).name, title)
})

test("a throwing or absent parse() falls back to splitLimit", () => {
  const title = "A, B, C"
  const thrower = fakeEvent(`1,window,${title}`, {
    parse: () => {
      throw new Error("no parse on this build")
    }
  })
  assert.equal(M.parseScreencastV2(thrower).name, title)
  assert.equal(M.parseScreencastV2(fakeEvent(`1,window,${title}`)).name, title)
})

test("parseOwner rejects anything that is not a share type", () => {
  assert.equal(M.parseOwner("MONITOR"), "monitor")
  assert.equal(M.parseOwner(" window "), "window")
  assert.equal(M.parseOwner("3"), "")
  assert.equal(M.parseOwner("ERR NONE"), "")
  assert.equal(M.parseOwner(undefined), "")
})

test("normalizeAddress strips 0x and lowercases", () => {
  assert.equal(M.normalizeAddress("0x55BF55D490E0"), "55bf55d490e0")
  assert.equal(M.normalizeAddress("55bf55d490e0"), "55bf55d490e0")
  assert.equal(M.normalizeAddress(null), "")
})

// ------------------------------------------------------------------ keys/ids

test("sessionKey separates same-name targets of different kinds", () => {
  assert.notEqual(M.sessionKey("monitor", "DP-1"), M.sessionKey("region", "DP-1"))
  assert.ok(M.sessionKey("window", "x").includes("\0"))
})

test("strip ids are NUL-free and never embed the session key", () => {
  const title = "Inbox - Foo, Bar - Microsoft Teams"
  const key = M.sessionKey("window", title)
  const ids = [
    M.stripIdMonitor(12, "t"),
    M.stripIdWindow(12, "0x55bf55d490e0", "b"),
    ...M.stripIdsForSession({ type: "window", seq: 7, addresses: ["0xAABB"] }),
    ...M.stripIdsForSession({ type: "monitor", seq: 7 })
  ]
  for (const id of ids) {
    assert.ok(!id.includes("\0"), `${id} must be NUL-free`)
    assert.ok(!id.includes(key), `${id} must not embed the session key`)
    assert.ok(!id.includes(title), `${id} must not embed the window title`)
  }
  assert.equal(M.stripIdMonitor(12, "t"), "s12-mt")
  assert.equal(M.stripIdWindow(12, "0x55bf55d490e0", "b"), "s12-w-55bf55d490e0-b")
})

test("stripIdsForSession covers every address for a window share", () => {
  const ids = M.stripIdsForSession({ type: "window", seq: 3, addresses: ["aa", "bb"] })
  assert.equal(ids.length, 8)
  assert.deepEqual(ids.slice(0, 4), ["s3-w-aa-t", "s3-w-aa-b", "s3-w-aa-l", "s3-w-aa-r"])
})

test("region shares get the same four strips as a monitor share", () => {
  const monitor = M.stripIdsForSession({ type: "monitor", seq: 5 })
  const region = M.stripIdsForSession({ type: "region", seq: 5 })
  assert.deepEqual(region, monitor)
})

// ------------------------------------------------------------------ state

const DEBOUNCE = 700
const GRACE = 1500

function start(state, type, name, nowMs, graceMs = GRACE) {
  return M.applyEvent(state, { active: true, type, name }, nowMs, DEBOUNCE, graceMs)
}

function stop(state, type, name, nowMs, graceMs = GRACE) {
  return M.applyEvent(state, { active: false, type, name }, nowMs, DEBOUNCE, graceMs)
}

test("a start arms one debounce timer and assigns a sequence", () => {
  const key = M.sessionKey("window", "Teams")
  const r = start(M.emptyState(), "window", "Teams", 1000)
  assert.deepEqual(r.armKeys, [key])
  assert.deepEqual(r.cancelKeys, [])
  assert.equal(r.state.sessions[key].count, 1)
  assert.equal(r.state.sessions[key].seq, 1)
  assert.equal(r.state.pending[key], 1700)
  assert.equal(r.state.visible[key], undefined, "strips must not map before the debounce")
})

test("a second client on the same target refcounts without re-arming", () => {
  const key = M.sessionKey("monitor", "DP-1")
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = start(r.state, "monitor", "DP-1", 100)
  assert.deepEqual(r.armKeys, [], "no second timer")
  assert.equal(r.state.sessions[key].count, 2)
  assert.equal(r.state.pending[key], 700, "the original deadline stands")
})

test("concurrent OBS and Teams sessions are independent keys", () => {
  let r = start(M.emptyState(), "window", "Teams", 0)
  r = start(r.state, "monitor", "DP-1", 10)
  assert.equal(Object.keys(r.state.sessions).length, 2)
  assert.equal(Object.keys(r.state.pending).length, 2)
  assert.notEqual(
    r.state.sessions[M.sessionKey("window", "Teams")].seq,
    r.state.sessions[M.sessionKey("monitor", "DP-1")].seq
  )
})

test("with no grace configured a stop before the debounce cancels the pending show", () => {
  const key = M.sessionKey("monitor", "DP-1")
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = stop(r.state, "monitor", "DP-1", 120, 0)
  assert.deepEqual(r.cancelKeys, [key])
  assert.equal(r.state.pending[key], undefined)
  assert.equal(r.state.sessions[key], undefined)
  assert.deepEqual(M.dueKeys(r.state, 10000), [], "a cancelled key can never come due")
})

test("a grim flash inside the debounce window never becomes visible", () => {
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = stop(r.state, "monitor", "DP-1", 40)
  const after = M.fireDue(r.state, 5000)
  assert.deepEqual(Object.keys(after.visible), [])
})

test("with no grace configured dropping the last reference reports the strip ids to unmap", () => {
  const key = M.sessionKey("window", "Teams")
  let r = start(M.emptyState(), "window", "Teams", 0)
  let state = M.attachAddresses(r.state, key, ["0xAA"])
  state = M.fireDue(state, 700)
  const expected = state.sessions[key].stripIds.slice()
  assert.equal(expected.length, 4)

  r = stop(state, "window", "Teams", 900, 0)
  assert.equal(r.dropped.length, 1)
  assert.equal(r.dropped[0].key, key)
  assert.deepEqual(r.dropped[0].stripIds, expected)
})

test("a stop that leaves a reference keeps the session visible", () => {
  const key = M.sessionKey("monitor", "DP-1")
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = start(r.state, "monitor", "DP-1", 10)
  let state = M.fireDue(r.state, 700)
  assert.equal(state.visible[key], true)

  r = stop(state, "monitor", "DP-1", 800)
  assert.deepEqual(r.cancelKeys, [])
  assert.equal(r.state.sessions[key].count, 1)
  assert.equal(r.state.visible[key], true)
})

test("an unparseable event leaves the state untouched", () => {
  const before = M.emptyState()
  const r = M.applyEvent(before, { active: true, type: "", name: "x" }, 0, DEBOUNCE)
  assert.equal(r.state, before)
  assert.deepEqual(r.armKeys, [])
})

test("a stop for an unknown session is a no-op", () => {
  const before = M.emptyState()
  const r = stop(before, "window", "never started", 0)
  assert.equal(r.state, before)
  assert.deepEqual(r.cancelKeys, [])
})

test("dueKeys only reports keys whose deadline has passed", () => {
  const r = start(M.emptyState(), "window", "Teams", 1000)
  assert.deepEqual(M.dueKeys(r.state, 1699), [])
  assert.deepEqual(M.dueKeys(r.state, 1700), [M.sessionKey("window", "Teams")])
})

test("fireDue preserves the addresses frozen at start", () => {
  const key = M.sessionKey("window", "Teams")
  const r = start(M.emptyState(), "window", "Teams", 0)
  let state = M.attachAddresses(r.state, key, ["0x55BF55D490E0", "0xAABBCC"])
  const before = state.sessions[key].addresses.slice()

  state = M.fireDue(state, 700)
  assert.equal(state.visible[key], true)
  assert.deepEqual(state.sessions[key].addresses, before, "fireDue must never rematch or clear addresses")
  assert.deepEqual(state.sessions[key].addresses, ["55bf55d490e0", "aabbcc"])
  assert.equal(state.pending[key], undefined)
})

test("fireDue leaves a not-yet-due session pending", () => {
  const key = M.sessionKey("window", "Teams")
  const r = start(M.emptyState(), "window", "Teams", 0)
  const state = M.fireDue(r.state, 699)
  assert.equal(state.visible[key], undefined)
  assert.equal(state.pending[key], 700)
})

test("attachAddresses normalizes, drops blanks, and refreshes strip ids", () => {
  const key = M.sessionKey("window", "Teams")
  const r = start(M.emptyState(), "window", "Teams", 0)
  const state = M.attachAddresses(r.state, key, ["0xAA", "", null, "0xBB"])
  assert.deepEqual(state.sessions[key].addresses, ["aa", "bb"])
  assert.deepEqual(state.sessions[key].stripIds, M.stripIdsForSession(state.sessions[key]))
  assert.equal(state.sessions[key].stripIds.length, 8)
})

test("state transitions do not mutate the state handed in", () => {
  const key = M.sessionKey("window", "Teams")
  const original = start(M.emptyState(), "window", "Teams", 0).state
  const snapshot = JSON.stringify(original)

  M.attachAddresses(original, key, ["0xAA"])
  M.fireDue(original, 700)
  M.applyEvent(original, { active: false, type: "window", name: "Teams" }, 800, DEBOUNCE, GRACE)
  M.expireGrace(stop(original, "window", "Teams", 800).state, 99999)

  assert.equal(JSON.stringify(original), snapshot)
})

// ------------------------------------------------------------------ stop grace

// Hyprland ends a capture session after 500 ms with no copied frame and emits
// the same screencastv2>>0 a real "stop sharing" emits. Taking that at face
// value tears down live shares: on a still screen the 700 ms debounce is
// cancelled every cycle and the ring never appears at all.

function visibleWindowSession(nowMs = 0) {
  const key = M.sessionKey("window", "Teams")
  const r = start(M.emptyState(), "window", "Teams", nowMs)
  let state = M.attachAddresses(r.state, key, ["0xAA"])
  state = M.fireDue(state, nowMs + DEBOUNCE)
  return { key, state }
}

test("an idle stop holds the session instead of tearing it down", () => {
  const { key, state } = visibleWindowSession()
  const strips = state.sessions[key].stripIds.slice()

  const r = stop(state, "window", "Teams", 800)

  assert.deepEqual(r.graceKeys, [key])
  assert.deepEqual(r.dropped, [], "nothing may unmap while the grace runs")
  assert.equal(r.state.visible[key], true, "the ring stays up")
  assert.deepEqual(r.state.sessions[key].stripIds, strips, "same surfaces, no remap")
  assert.equal(r.state.sessions[key].stoppingAt, 800 + GRACE)
})

test("a restart inside the grace revives the session untouched", () => {
  const { key, state } = visibleWindowSession()
  const seq = state.sessions[key].seq
  const strips = state.sessions[key].stripIds.slice()

  let r = stop(state, "window", "Teams", 800)
  r = start(r.state, "window", "Teams", 1300)

  assert.deepEqual(r.revivedKeys, [key])
  assert.deepEqual(r.armKeys, [], "a revive is not a new share and must not rematch")
  const session = r.state.sessions[key]
  assert.equal(session.seq, seq, "a fresh seq would rename every strip and remap it")
  assert.deepEqual(session.addresses, ["aa"], "addresses stay frozen across the gap")
  assert.deepEqual(session.stripIds, strips)
  assert.equal(session.count, 1)
  assert.equal(session.stoppingAt, 0, "the teardown is cancelled")
  assert.equal(r.state.visible[key], true)
})

test("the 500 ms churn lets a ring appear on a screen that never changes", () => {
  // Journal: start 05.640, stop 06.140, start 06.640. Each session lives
  // exactly 500 ms, so the 700 ms deadline has to survive the gap.
  const key = M.sessionKey("monitor", "DP-2")
  let r = start(M.emptyState(), "monitor", "DP-2", 5640)
  assert.equal(r.state.pending[key], 6340)

  r = stop(r.state, "monitor", "DP-2", 6140)
  let state = M.fireDue(r.state, 6340)
  assert.equal(state.visible[key], undefined, "not while it is stopped")
  assert.equal(state.pending[key], 6340, "but the deadline must not be cancelled")

  r = start(state, "monitor", "DP-2", 6640)
  state = M.fireDue(r.state, 6640)
  assert.equal(state.visible[key], true, "the ring appears one churn cycle late, not never")
})

test("a grace that runs out drops the session and reports its strips", () => {
  const { key, state } = visibleWindowSession()
  const strips = state.sessions[key].stripIds.slice()
  const r = stop(state, "window", "Teams", 800)

  const early = M.expireGrace(r.state, 800 + GRACE - 1)
  assert.deepEqual(early.dropped, [])
  assert.equal(early.state, r.state, "an untouched state is handed back as-is")

  const gone = M.expireGrace(r.state, 800 + GRACE)
  assert.equal(gone.dropped.length, 1)
  assert.equal(gone.dropped[0].key, key)
  assert.deepEqual(gone.dropped[0].stripIds, strips)
  assert.equal(gone.state.sessions[key], undefined)
  assert.equal(gone.state.visible[key], undefined)
  assert.equal(gone.state.pending[key], undefined)
})

test("a screenshot flash stays invisible for its whole grace, then vanishes", () => {
  const key = M.sessionKey("monitor", "DP-1")
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = stop(r.state, "monitor", "DP-1", 40)

  const held = M.fireDue(r.state, 700)
  assert.deepEqual(Object.keys(held.visible), [], "a grim flash must never map a strip")

  const gone = M.expireGrace(held, 40 + GRACE)
  assert.equal(gone.state.sessions[key], undefined)
  assert.deepEqual(gone.dropped[0].stripIds, [], "nothing was mapped, so nothing to unmap")
})

test("a zero grace tears down on the stop event, as it always did", () => {
  const { key, state } = visibleWindowSession()
  const r = stop(state, "window", "Teams", 800, 0)
  assert.deepEqual(r.graceKeys, [])
  assert.equal(r.dropped.length, 1)
  assert.equal(r.state.sessions[key], undefined)
})

test("dueKeys ignores a session that is waiting out its grace", () => {
  const key = M.sessionKey("window", "Teams")
  let r = start(M.emptyState(), "window", "Teams", 0)
  r = stop(r.state, "window", "Teams", 100)
  assert.deepEqual(M.dueKeys(r.state, 10000), [], "a stopped session may not come due")
  assert.equal(r.state.pending[key], 700, "its deadline is kept, not cancelled")
})

test("soonestPending skips grace sessions so the debounce timer can idle", () => {
  // Otherwise Service.qml re-aims a 1 ms timer at an overdue deadline that
  // fireDue refuses to clear, and spins for the length of the grace.
  let r = start(M.emptyState(), "window", "Teams", 0)
  assert.equal(M.soonestPending(r.state), 700)

  r = stop(r.state, "window", "Teams", 100)
  assert.equal(M.soonestPending(r.state), -1)

  r = start(r.state, "window", "Teams", 200)
  assert.equal(M.soonestPending(r.state), 700, "the revived deadline is the original one")
})

test("nextGraceDeadline reports the soonest teardown, or -1", () => {
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = start(r.state, "window", "Teams", 0)
  assert.equal(M.nextGraceDeadline(r.state), -1)

  r = stop(r.state, "window", "Teams", 900)
  r = stop(r.state, "monitor", "DP-1", 500)
  assert.equal(M.nextGraceDeadline(r.state), 500 + GRACE)
})

test("a stop with another client still attached starts no grace", () => {
  const key = M.sessionKey("monitor", "DP-1")
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = start(r.state, "monitor", "DP-1", 10)
  r = stop(r.state, "monitor", "DP-1", 800)

  assert.deepEqual(r.graceKeys, [])
  assert.equal(r.state.sessions[key].count, 1)
  assert.equal(r.state.sessions[key].stoppingAt, 0)
})

// ------------------------------------------------------- orphaned sessions

// Hyprland's start event carries the title captured at session init, but
// the *stop* carries the window's title at stop time. A browser that retitles
// mid-share therefore stops under a key that was never started:
//
//   12:34:55 start window "Breaking news - Live coverage - Brave"
//   12:37:11 stop  window "(2) YouTube - Brave"
//
// The stop was dropped, the session stayed pinned at count=1 and VISIBLE, and
// the ring sat on a window that had not been shared for four hours. So a stop
// is resolved by address first and by title only as a fallback.

const REAP = 5000

function stopWith(state, type, name, nowMs, addresses) {
  return M.applyEvent(state, { active: false, type, name, addresses }, nowMs, DEBOUNCE, GRACE)
}

test("a stop under a new title still tears down the session it belongs to", () => {
  const key = M.sessionKey("window", "News - Brave")
  let r = start(M.emptyState(), "window", "News - Brave", 0)
  let state = M.attachAddresses(r.state, key, ["0xAA"], 0)
  state = M.fireDue(state, DEBOUNCE)
  assert.equal(state.visible[key], true)

  // the tab retitled, so the stop arrives under a name we never started
  r = stopWith(state, "window", "(2) YouTube - Brave", 5000, ["0xAA"])

  assert.deepEqual(r.graceKeys, [key], "the address must find the session the title cannot")
  assert.equal(r.state.sessions[key].count, 0)
})

test("a stop resolves to the session holding the address, not one sharing the name", () => {
  // Worse than a lost stop: a stray stop landing on a live share and taking
  // its ring down. The address decides, so it cannot.
  const kept = M.sessionKey("window", "Foo")
  const meant = M.sessionKey("window", "Bar")
  let r = start(M.emptyState(), "window", "Foo", 0)
  let state = M.attachAddresses(r.state, kept, ["0xAA"], 0)
  r = start(state, "window", "Bar", 10)
  state = M.attachAddresses(r.state, meant, ["0xBB"], 10)

  r = stopWith(state, "window", "Foo", 900, ["0xBB"])

  assert.deepEqual(r.graceKeys, [meant], "0xBB belongs to Bar, whatever the stop is called")
  assert.equal(r.state.sessions[kept].count, 1, "Foo must keep its reference")
})

test("a stop whose window is already gone falls back to the title", () => {
  const key = M.sessionKey("window", "Teams")
  let r = start(M.emptyState(), "window", "Teams", 0)
  let state = M.attachAddresses(r.state, key, ["0xAA"], 0)

  r = stopWith(state, "window", "Teams", 900, [])

  assert.deepEqual(r.graceKeys, [key])
})

test("a monitor stop is keyed by name and ignores addresses", () => {
  const key = M.sessionKey("monitor", "DP-1")
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = stopWith(r.state, "monitor", "DP-1", 900, [])
  assert.deepEqual(r.graceKeys, [key])
})

test("a window session that loses its window is reaped, pinned count and all", () => {
  const key = M.sessionKey("window", "News - Brave")
  let r = start(M.emptyState(), "window", "News - Brave", 0)
  let state = M.attachAddresses(r.state, key, ["0xAA"], 0)
  state = M.fireDue(state, DEBOUNCE)
  // the window closed: syncWindowSessions finds nothing and clears the addresses
  state = M.attachAddresses(state, key, [], 1000)
  assert.equal(state.sessions[key].addressLessSince, 1000)
  assert.equal(state.sessions[key].count, 1, "the orphan is still holding a reference")

  const early = M.reapAddressLess(state, 1000 + REAP - 1, REAP)
  assert.deepEqual(early.dropped, [])
  assert.equal(early.state, state, "an untouched state comes back as-is")

  const gone = M.reapAddressLess(state, 1000 + REAP, REAP)
  assert.equal(gone.dropped.length, 1)
  assert.equal(gone.dropped[0].key, key)
  assert.equal(gone.state.sessions[key], undefined, "count>0 must not save an orphan")
  assert.equal(gone.state.visible[key], undefined)
})

test("a window that comes back before the reaper is not collected", () => {
  const key = M.sessionKey("window", "Teams")
  let r = start(M.emptyState(), "window", "Teams", 0)
  let state = M.attachAddresses(r.state, key, ["0xAA"], 0)
  state = M.attachAddresses(state, key, [], 1000)
  state = M.attachAddresses(state, key, ["0xBB"], 1400)

  assert.equal(state.sessions[key].addressLessSince, 0, "the stamp must be cleared")
  assert.deepEqual(M.reapAddressLess(state, 99999, REAP).dropped, [])
})

test("a session that never matched a window is never reaped", () => {
  // A start whose title matches nothing draws no ring and may still be
  // recovered by a later retitle. Only a session that *lost* a window is dead.
  const r = start(M.emptyState(), "window", "unmatched", 0)
  assert.equal(r.state.sessions[M.sessionKey("window", "unmatched")].addressLessSince, 0)
  assert.deepEqual(M.reapAddressLess(r.state, 99999, REAP).dropped, [])
})

test("nextReapDeadline reports the soonest collection, or -1", () => {
  const key = M.sessionKey("window", "Teams")
  let r = start(M.emptyState(), "window", "Teams", 0)
  let state = M.attachAddresses(r.state, key, ["0xAA"], 0)
  assert.equal(M.nextReapDeadline(state, REAP), -1)

  state = M.attachAddresses(state, key, [], 2000)
  assert.equal(M.nextReapDeadline(state, REAP), 2000 + REAP)
})

// ------------------------------------------------------------- name aliases

// The stop event carries m_name as of the last calculateConstraints(),
// which is neither the title the session opened with nor necessarily the
// window's current one. So an exact key can miss, and resolving the stop's
// title to a live window can miss too -- the title may belong to nothing any
// more. A session therefore remembers every title its window has worn.
//
// Observed: a call ended, the stop resolved to nothing, the session stayed
// pinned with the ring up, and only killing the browser cleared it (the reaper
// will not collect a session whose window is still alive).

test("a stop under a title the window has already left still finds its session", () => {
  const key = M.sessionKey("window", "Overview - Dashboard - Brave")
  let r = start(M.emptyState(), "window", "Overview - Dashboard - Brave", 0)
  let state = M.attachAddresses(r.state, key, ["0xAA"], 0)
  state = M.fireDue(state, DEBOUNCE)
  // the tab moved on, and we recorded each title as it appeared
  state = M.recordName(state, key, "New Tab - Brave")
  state = M.recordName(state, key, "YouTube - Brave")

  // the stop names a title that now matches no live window, so there are no
  // addresses to resolve with either
  r = stopWith(state, "window", "New Tab - Brave", 9000, [])

  assert.deepEqual(r.graceKeys, [key], "the alias is the only thing that can find it")
  assert.equal(r.state.sessions[key].count, 0)
})

test("an exact key beats another session's alias", () => {
  const older = M.sessionKey("window", "Foo")
  const exact = M.sessionKey("window", "Bar")
  let r = start(M.emptyState(), "window", "Foo", 0)
  let state = M.attachAddresses(r.state, older, ["0xAA"], 0)
  state = M.recordName(state, older, "Bar")          // Foo has worn "Bar" before
  r = start(state, "window", "Bar", 10)              // a different window is "Bar" now
  state = M.attachAddresses(r.state, exact, ["0xBB"], 10)

  r = stopWith(state, "window", "Bar", 900, [])

  assert.deepEqual(r.graceKeys, [exact], "the session actually called Bar owns the stop")
  assert.equal(r.state.sessions[older].count, 1, "Foo keeps its reference")
})

test("a resolvable address still beats every name", () => {
  const byName = M.sessionKey("window", "Teams")
  const byAddr = M.sessionKey("window", "Other")
  let r = start(M.emptyState(), "window", "Teams", 0)
  let state = M.attachAddresses(r.state, byName, ["0xAA"], 0)
  r = start(state, "window", "Other", 10)
  state = M.attachAddresses(r.state, byAddr, ["0xBB"], 10)
  state = M.recordName(state, byName, "Other")

  r = stopWith(state, "window", "Other", 900, ["0xBB"])
  assert.deepEqual(r.graceKeys, [byAddr], "identity first, names only as fallback")
})

test("recordName is unique, bounded, and leaves the input alone", () => {
  const key = M.sessionKey("window", "T0")
  const original = start(M.emptyState(), "window", "T0", 0).state
  const snapshot = JSON.stringify(original)

  let state = M.recordName(original, key, "T1")
  assert.deepEqual(state.sessions[key].names, ["T0", "T1"], "the opening title counts too")
  assert.equal(M.recordName(state, key, "T1"), state, "a repeat is not a change")
  assert.equal(M.recordName(state, key, ""), state, "an empty title is not a name")

  for (let i = 0; i < 40; i++) state = M.recordName(state, key, "t" + i)
  assert.ok(state.sessions[key].names.length <= 16, "a retitling browser must not grow it forever")
  assert.equal(state.sessions[key].names.indexOf("t39"), state.sessions[key].names.length - 1,
               "the newest title is the one a stop is most likely to carry")
  assert.equal(JSON.stringify(original), snapshot)
})

test("an alias never resolves a stop across share types", () => {
  const key = M.sessionKey("monitor", "DP-1")
  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  const state = M.recordName(r.state, key, "some window title")
  r = stopWith(state, "window", "some window title", 900, [])
  assert.deepEqual(r.graceKeys, [], "a monitor session cannot own a window stop")
})

// ------------------------------------------------------------------ matching

const TOPLEVELS = [
  { address: "0xAA", title: "Teams", lastIpcObject: { address: "0xAA", title: "Teams", at: [12, 42], size: [1517, 830], monitor: 0, workspace: { id: 1 }, mapped: true } },
  { address: "0xBB", title: "Teams", lastIpcObject: { address: "0xBB", title: "Teams", at: [40, 40], size: [800, 600], monitor: 0, workspace: { id: 1 }, mapped: true } },
  { address: "0xCC", title: "Something else", lastIpcObject: { address: "0xCC", title: "Something else", monitor: 0, workspace: { id: 1 }, mapped: true } }
]

test("matchWindows rings every window sharing the title", () => {
  const hits = M.matchWindows(TOPLEVELS, "Teams", [])
  assert.deepEqual(hits.map((t) => t.address), ["0xAA", "0xBB"])
})

test("matchWindows is exact, not substring or case-folded", () => {
  assert.deepEqual(M.matchWindows(TOPLEVELS, "Team", []), [])
  assert.deepEqual(M.matchWindows(TOPLEVELS, "teams", []), [])
  assert.deepEqual(M.matchWindows(TOPLEVELS, "", []), [])
})

test("matchWindows sticks to stored addresses and ignores the title", () => {
  // The title has already changed by the time the ring maps: it must not matter.
  const renamed = TOPLEVELS.map((t) => ({ ...t, title: "Chat with someone | Microsoft Teams" }))
  const hits = M.matchWindows(renamed, "Teams", ["aa"])
  assert.deepEqual(hits.map((t) => t.address), ["0xAA"])
})

test("matchWindows drops stored addresses whose window is gone", () => {
  const hits = M.matchWindows(TOPLEVELS, "Teams", ["aa", "deadbeef"])
  assert.deepEqual(hits.map((t) => t.address), ["0xAA"])
})

test("matchMonitor resolves by connector name", () => {
  const monitors = [{ name: "DP-1" }, { name: "HDMI-A-1" }]
  assert.equal(M.matchMonitor(monitors, "HDMI-A-1").name, "HDMI-A-1")
  assert.equal(M.matchMonitor(monitors, "DP-9"), null)
  assert.equal(M.matchMonitor(monitors, ""), null)
})

test("isWindowDrawable withholds strips for unmapped or hidden windows", () => {
  const monitors = [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }]
  const base = { lastIpcObject: { monitor: 0, workspace: { id: 1 }, mapped: true } }
  assert.equal(M.isWindowDrawable(base, monitors), true)
  assert.equal(M.isWindowDrawable({ lastIpcObject: { ...base.lastIpcObject, mapped: false } }, monitors), false)
  assert.equal(M.isWindowDrawable({ lastIpcObject: { ...base.lastIpcObject, hidden: true } }, monitors), false)
  assert.equal(M.isWindowDrawable({ lastIpcObject: { ...base.lastIpcObject, visible: false } }, monitors), false)
  assert.equal(M.isWindowDrawable(null, monitors), false)
})

test("isWindowDrawable hides an off-workspace window but not a pinned one", () => {
  const monitors = [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }]
  const offWorkspace = { lastIpcObject: { monitor: 0, workspace: { id: 7 }, mapped: true } }
  assert.equal(M.isWindowDrawable(offWorkspace, monitors), false)
  const pinned = { lastIpcObject: { monitor: 0, workspace: { id: 7 }, mapped: true, pinned: true } }
  assert.equal(M.isWindowDrawable(pinned, monitors), true)
})

test("an XWayland window is not a special case", () => {
  const monitors = [{ id: 0, name: "DP-1", activeWorkspace: { id: 1 } }]
  const xwayland = { lastIpcObject: { monitor: 0, workspace: { id: 1 }, mapped: true, xwayland: true } }
  assert.equal(M.isWindowDrawable(xwayland, monitors), true)
})

test("monitorForWindow resolves by IPC id, the same way the geometry path does", () => {
  // The workspace check and the strip geometry must answer "which monitor is
  // this window on?" identically. Resolving it two ways -- toplevel.monitor
  // for one, lastIpcObject.monitor for the other -- lets the workspace check
  // be decided against one monitor while the geometry is built from another.
  // Both go through here.
  const monitors = [
    { name: "DP-1", x: 0, id: 0, lastIpcObject: { id: 0, name: "DP-1", activeWorkspace: { id: 1 } } },
    { name: "HDMI-A-1", x: 3072, id: 1, lastIpcObject: { id: 1, name: "HDMI-A-1", activeWorkspace: { id: 4 } } }
  ]
  assert.equal(M.monitorForWindow(monitors, { monitor: 1 }).name, "HDMI-A-1")
  assert.equal(M.monitorForWindow(monitors, { monitor: 0 }).name, "DP-1")
  assert.equal(M.monitorForWindow(monitors, { monitor: 9 }), null, "an unknown id must not guess")
  assert.equal(M.monitorForWindow(monitors, {}), null)

  // and the drawability answer is keyed off that same monitor
  const onHdmi = { address: "0xAA", lastIpcObject: { address: "0xAA", monitor: 1, workspace: { id: 4 }, mapped: true } }
  const offWs = { address: "0xBB", lastIpcObject: { address: "0xBB", monitor: 1, workspace: { id: 9 }, mapped: true } }
  assert.equal(M.isWindowDrawable(onHdmi, monitors), true)
  assert.equal(M.isWindowDrawable(offWs, monitors), false, "off-workspace withdraws the ring")
})

// ------------------------------------------------------------------ geometry

test("boxesForMonitor rings a logical 3072x1728 output, not a 3840x2160 buffer", () => {
  const boxes = M.boxesForMonitor(3072, 1728, 3)
  assert.deepEqual(boxes, [
    { edge: "t", boxX: 0, boxY: 0, boxW: 3072, boxH: 3 },
    { edge: "b", boxX: 0, boxY: 1725, boxW: 3072, boxH: 3 },
    { edge: "l", boxX: 0, boxY: 3, boxW: 3, boxH: 1722 },
    { edge: "r", boxX: 3069, boxY: 3, boxW: 3, boxH: 1722 }
  ])
  for (const b of boxes) {
    assert.notEqual(b.boxW, 3840, "a 3840-wide strip means buffer pixels leaked in")
    assert.ok(b.boxX + b.boxW <= 3072, "strip overhangs the logical output")
    assert.ok(b.boxY + b.boxH <= 1728, "strip overhangs the logical output")
  }
})

test("boxesForWindow rings an interior rectangle", () => {
  assert.deepEqual(M.boxesForWindow(12, 42, 1517, 830, 3), [
    { edge: "t", boxX: 12, boxY: 42, boxW: 1517, boxH: 3 },
    { edge: "b", boxX: 12, boxY: 869, boxW: 1517, boxH: 3 },
    { edge: "l", boxX: 12, boxY: 45, boxW: 3, boxH: 824 },
    { edge: "r", boxX: 1526, boxY: 45, boxW: 3, boxH: 824 }
  ])
})

test("a window shorter than two strips drops the side rails", () => {
  const boxes = M.boxesForWindow(0, 0, 200, 5, 3)
  assert.deepEqual(boxes.map((b) => b.edge), ["t", "b"])
  for (const b of boxes) {
    assert.ok(b.boxW >= 1 && b.boxH >= 1)
  }
})

test("degenerate geometry produces no strips at all", () => {
  assert.deepEqual(M.boxesForWindow(0, 0, 0, 100, 3), [])
  assert.deepEqual(M.boxesForMonitor(0, 0, 3), [])
})

test("widthPx is clamped to a sane, thin residual", () => {
  assert.equal(M.boxesForMonitor(3072, 1728, 0)[0].boxH, 1)
  assert.equal(M.boxesForMonitor(3072, 1728, -5)[0].boxH, 1)
  assert.equal(M.boxesForMonitor(3072, 1728, 999)[0].boxH, 16)
  assert.equal(M.boxesForMonitor(3072, 1728, "4")[0].boxH, 4)
})

// Both of the following pin measured geometry rather than drive a design. The
// ring is flush with the client area by construction; these lock that in, so a
// change to the box arithmetic cannot quietly move it by a pixel.

test("a window ring's outer edges land exactly on the client area", () => {
  // at=[12,42] size=[1517,1674]: a real tiled window on DP-1 at scale 1.25.
  // `at` is the client area, not the visible edge -- 12 is gaps_out 10 plus
  // border 2 -- so Hyprland's border sits outside the ring rather than under
  // it, and the ring hugs exactly the region a window capture would copy.
  const b = {}
  for (const box of M.boxesForWindow(12, 42, 1517, 1674, 3)) b[box.edge] = box

  assert.equal(b.t.boxX, 12)
  assert.equal(b.t.boxY, 42)
  assert.equal(b.l.boxX, 12)
  assert.equal(b.t.boxX + b.t.boxW, 12 + 1517, "top must reach the right edge")
  assert.equal(b.b.boxY + b.b.boxH, 42 + 1674, "bottom outer edge on the client edge")
  assert.equal(b.r.boxX + b.r.boxW, 12 + 1517, "right outer edge on the client edge")
  // the sides fill exactly what top and bottom leave: no seam, no double-drawn pixel
  assert.equal(b.l.boxY, 42 + 3)
  assert.equal(b.l.boxY + b.l.boxH, 42 + 1674 - 3)
})

test("no window geometry, however degenerate, emits a box the compositor drops", () => {
  // arrangeLayerArray honours a negative margin by plain addition and never
  // intersects the box with the output, so an offscreen strip is placed
  // literally and clipped at render -- harmless. The one input it refuses is
  // `box.width <= 0 || box.height <= 0`: it logs an error and drops the
  // surface. Nothing we emit may hit that, whatever the window is doing.
  const cases = [
    [-200, 400, 800, 600, 3],   // floating, dragged off the left
    [2800, 400, 800, 600, 3],   // off the right
    [400, -100, 800, 600, 3],   // off the top
    [-900, -900, 800, 600, 3],  // entirely offscreen
    [0, 0, 3072, 1728, 3],      // fullscreen
    [100, 100, 10, 4, 3],       // shorter than two strips
    [100, 100, 200, 6, 3],      // exactly two strips tall
    [100, 100, 200, 7, 3],      // one logical pixel of side left
    [100, 100, 2, 200, 3],      // narrower than the strip
    [100, 100, 200, 20, 16],    // widthPx at the ceiling
    [0, 0, 1, 1, 16]
  ]
  for (const [x, y, w, h, px] of cases) {
    for (const box of M.boxesForWindow(x, y, w, h, px)) {
      assert.ok(box.boxW >= 1 && box.boxH >= 1,
                `${JSON.stringify([x, y, w, h, px])} emitted ${box.edge} ${box.boxW}x${box.boxH}`)
    }
  }
})

// Real numbers from a three-head setup: 3840x2160 outputs at scale 1.25, laid
// out at x = 0, 3072, 6144. Monitor width is buffer pixels; the layout origins
// and every window's at/size are logical. Mixing the two is the geometry bug
// that only shows up on a fractionally scaled output.
test("a window ring is output-local, not desktop-global", () => {
  const monitor = { name: "HDMI-A-1", x: 3072, y: 0, width: 3840, height: 2160, scale: 1.25 }
  const at = [3084, 886]
  const size = [3048, 830]

  const localX = at[0] - monitor.x
  const localY = at[1] - monitor.y
  assert.equal(localX, 12, "subtracting the monitor origin is what keeps the ring on its own output")

  const boxes = M.boxesForWindow(localX, localY, size[0], size[1], 3)
  assert.deepEqual(boxes, [
    { edge: "t", boxX: 12, boxY: 886, boxW: 3048, boxH: 3 },
    { edge: "b", boxX: 12, boxY: 1713, boxW: 3048, boxH: 3 },
    { edge: "l", boxX: 12, boxY: 889, boxW: 3, boxH: 824 },
    { edge: "r", boxX: 3057, boxY: 889, boxW: 3, boxH: 824 }
  ])

  // Forgetting the subtraction pushes the ring off the right-hand edge of a
  // 3072-wide output entirely.
  const wrong = M.boxesForWindow(at[0], at[1], size[0], size[1], 3)
  assert.ok(wrong[0].boxX + wrong[0].boxW > 3072, "the un-subtracted box must be detectably off-output")
})

test("a monitor ring built from buffer pixels overhangs a scaled output", () => {
  const logical = M.logicalOutputSize(3840, 2160, 1.25, 3072, 1728)
  assert.deepEqual(M.boxesForMonitor(logical.w, logical.h, 3)[0].boxW, 3072)
  // What the same call produces if HyprlandMonitor.width leaks in.
  assert.equal(M.boxesForMonitor(3840, 2160, 3)[0].boxW, 3840)
})

test("logicalOutputSize prefers the Quickshell screen and divides only as fallback", () => {
  assert.deepEqual(M.logicalOutputSize(3840, 2160, 1.25, 3072, 1728), { w: 3072, h: 1728 })
  assert.deepEqual(M.logicalOutputSize(3840, 2160, 1.25, 0, 0), { w: 3072, h: 1728 })
  assert.deepEqual(M.logicalOutputSize(3840, 2160, 1.25, undefined, undefined), { w: 3072, h: 1728 })
  assert.deepEqual(M.logicalOutputSize(1920, 1080, 0, 0, 0), { w: 1920, h: 1080 })
})

// ------------------------------------------------------------------ end-to-end

test("a Teams window share survives a retitle across the whole debounce", () => {
  const key = M.sessionKey("window", "Teams")

  // Start: match while NAME still equals the live title, and freeze it.
  let r = start(M.emptyState(), "window", "Teams", 0)
  const matched = M.matchWindows(TOPLEVELS, "Teams", [])
  let state = M.attachAddresses(r.state, key, matched.map((t) => t.address))
  assert.deepEqual(state.sessions[key].addresses, ["aa", "bb"])

  // Teams retitles twice inside the 700 ms window.
  const renamed = TOPLEVELS.map((t) => ({ ...t, title: "Weekly sync | Microsoft Teams" }))
  assert.deepEqual(M.matchWindows(renamed, "Teams", []), [], "title matching would now miss")

  // The ring still maps, from the stored addresses.
  state = M.fireDue(state, 700)
  assert.equal(state.visible[key], true)
  const live = M.matchWindows(renamed, "Teams", state.sessions[key].addresses)
  assert.deepEqual(live.map((t) => t.address), ["0xAA", "0xBB"])
  assert.equal(state.sessions[key].stripIds.length, 8)
})

test("a screenshot flash and a real share can overlap without crossing", () => {
  const grim = M.sessionKey("monitor", "DP-1")
  const teams = M.sessionKey("window", "Teams")

  let r = start(M.emptyState(), "monitor", "DP-1", 0)
  r = start(r.state, "window", "Teams", 50)
  r = stop(r.state, "monitor", "DP-1", 90)

  const state = M.fireDue(r.state, 750)
  assert.equal(state.visible[grim], undefined, "the grim flash must not ring")
  assert.equal(state.visible[teams], true, "the real share must still ring")
})

// ------------------------------------------------------------------ settings

test("entryFromConfig prefers the bar layout over plugins[]", () => {
  const config = {
    bar: { layout: { left: [], center: [], right: [{ id: "screen-sharing-indicator", widthPx: 5 }] } },
    plugins: [{ id: "screen-sharing-indicator", widthPx: 9 }]
  }
  assert.equal(M.entryFromConfig(config, "screen-sharing-indicator").widthPx, 5)
})

test("entryFromConfig falls back to plugins[] when no widget is placed", () => {
  const config = {
    bar: { layout: { left: [], center: [], right: [] } },
    plugins: [{ id: "screen-sharing-indicator", widthPx: 9 }]
  }
  assert.equal(M.entryFromConfig(config, "screen-sharing-indicator").widthPx, 9)
})

test("entryFromConfig returns an empty entry when the plugin is absent", () => {
  assert.deepEqual(M.entryFromConfig({ bar: {}, plugins: [] }, "screen-sharing-indicator"), {})
  assert.deepEqual(M.entryFromConfig(null, "screen-sharing-indicator"), {})
})

// updateEntryInline rebuilds an entry as {id} plus exactly what it is handed,
// so anything the panel forgets to send is deleted from the user's config.
test("mergedSettings never drops a key the caller did not mention", () => {
  const current = { id: "screen-sharing-indicator", widthPx: 3, stopGraceMs: 1500, active: true }
  const merged = M.mergedSettings(current, { color: "#00FF00" })
  assert.equal(merged.stopGraceMs, 1500)
  assert.equal(merged.widthPx, 3)
  assert.equal(merged.active, true)
  assert.equal(merged.color, "#00FF00")
})

test("mergedSettings overwrites what the caller does mention", () => {
  const merged = M.mergedSettings({ widthPx: 3 }, { widthPx: 8 })
  assert.equal(merged.widthPx, 8)
})

// ------------------------------------------------------------------- colour

test("autoRingColor leaves the red alone on a blue-accented theme", () => {
  assert.equal(M.autoRingColor("#E81123", "#3B82F6"), "#E81123")
})

test("autoRingColor leaves the red alone on a washed-out accent", () => {
  // Saturation at or below 0.35 cannot compete with the ring, whatever its hue.
  assert.equal(M.autoRingColor("#E81123", "#9C8080"), "#E81123")
})

test("autoRingColor moves the ring when the accent is also red", () => {
  const out = M.autoRingColor("#E81123", "#E81123")
  assert.notEqual(out, "#E81123")
  assert.match(out, /^#[0-9a-f]{6}$/i)
})

test("autoRingColor never leaves the red-to-orange alarm band", () => {
  // The hue is read back out of an 8-bit hex string, so the hslToHex/hexToHsl
  // round trip quantises it by a few hundredths of a degree -- #FF6A00 selects
  // endpoint 350 and reads back 349.953. Allow half a degree of slack at each
  // edge: the assertion is about staying in the band, not about float equality
  // at its boundary, and half a degree is below the resolution of the hex
  // colour the function returns.
  const SLACK = 0.5
  for (const accent of ["#E81123", "#FF3B00", "#D40030", "#FF6A00"]) {
    const hsl = M.hexToHsl(M.autoRingColor("#E81123", accent))
    assert.ok(
      hsl.h >= M.ALARM_HUE_START - SLACK || hsl.h <= M.ALARM_HUE_END + SLACK,
      `hue ${hsl.h} left the alarm band for ${accent}`
    )
  }
})

test("autoRingColor is idempotent for a given accent", () => {
  const once = M.autoRingColor("#E81123", "#E81123")
  assert.equal(M.autoRingColor(once, "#E81123"), once)
})

test("autoRingColor returns the base unchanged for unparseable input", () => {
  assert.equal(M.autoRingColor("#E81123", "not a colour"), "#E81123")
})

// The two tests below pin the *choice*, not just the band. Everything above
// this point passes against a function that ignores the accent and returns
// hue 350 unconditionally -- which would collapse to the accent's own colour
// for exactly the themes this function exists to rescue. Two accents, one on
// each side of the band, selecting opposite endpoints, is the smallest pair
// that can tell "furthest endpoint" apart from "hardcoded endpoint".
//
// SLACK for the same reason as the band test above: the hue is read back out
// of an 8-bit hex string, so the round trip quantises it by a few hundredths
// of a degree.
test("autoRingColor picks the far endpoint 350 for an accent up at the orange edge", () => {
  const SLACK = 0.5
  const accent = "#FF6A00"
  assert.ok(Math.abs(M.hexToHsl(accent).h - 25) < 1, "fixture accent should sit near hue 25")
  // 25 is 15 degrees from the 40 endpoint and 35 from the 350 one, so 350 wins.
  const hue = M.hexToHsl(M.autoRingColor("#E81123", accent)).h
  assert.ok(Math.abs(hue - M.ALARM_HUE_START) < SLACK,
            `expected the 350 endpoint for an accent at hue 25, got ${hue}`)
})

test("autoRingColor picks the far endpoint 40 for an accent down at the red edge", () => {
  const SLACK = 0.5
  const accent = "#FF0015"
  assert.ok(Math.abs(M.hexToHsl(accent).h - 355) < 1, "fixture accent should sit near hue 355")
  // 355 is 5 degrees from the 350 endpoint and 45 from the 40 one, so 40 wins.
  const hue = M.hexToHsl(M.autoRingColor("#E81123", accent)).h
  assert.ok(Math.abs(hue - M.ALARM_HUE_END) < SLACK,
            `expected the 40 endpoint for an accent at hue 355, got ${hue}`)
})

// ------------------------------------------------------------ notifications

test("ringTransition reports one up when the first ring appears", () => {
  assert.equal(M.ringTransition(0, 4), "up")
})

test("ringTransition reports one down when the last ring goes", () => {
  assert.equal(M.ringTransition(4, 0), "down")
})

test("ringTransition stays silent through churn", () => {
  // The real 14-minute call revived 107 times without the ring ever coming
  // down. Session-level toasts would have fired over two hundred times.
  assert.equal(M.ringTransition(4, 4), null)
  assert.equal(M.ringTransition(4, 8), null)
  assert.equal(M.ringTransition(8, 4), null)
})

test("ringTransition stays silent when nothing was ever up", () => {
  assert.equal(M.ringTransition(0, 0), null)
})

test("ringTransition never claims a transition it cannot know", () => {
  // A false "stopped" while still sharing is this function's worst failure: it
  // tells you the capture ended when it has not. Unknown input stays silent
  // rather than coercing to zero. Negatives are unknown too -- they are not a
  // count, and treating -4 as truthy would swallow a real "up".
  assert.equal(M.ringTransition(4, undefined), null)
  assert.equal(M.ringTransition(4, NaN), null)
  assert.equal(M.ringTransition(4, null), null)
  assert.equal(M.ringTransition(undefined, 4), null)
  assert.equal(M.ringTransition(-4, 4), null)
})

test("ringTransition reads a boolean sharingNow fed in as 0/1", () => {
  // Service.qml drives this from anyVisibleSession, not a strip count, and
  // passes the boolean through as 0/1 -- the same 0<->N edge.
  assert.equal(M.ringTransition(0, 1), "up")
  assert.equal(M.ringTransition(1, 0), "down")
  assert.equal(M.ringTransition(1, 1), null)
  assert.equal(M.ringTransition(0, 0), null)
})

// --------------------------------------------------- am I being captured?

test("anyVisibleSession is false for an empty table", () => {
  assert.equal(M.anyVisibleSession(M.emptyState()), false)
})

test("anyVisibleSession is false while the session is still in its debounce", () => {
  // Observed with a real share picker: six window and three monitor previews
  // live at once, every one of them below the debounce.
  // None of them is a capture yet, and none may turn the chip red.
  let r = start(M.emptyState(), "window", "Teams", 0)
  r = start(r.state, "monitor", "DP-1", 10)
  assert.equal(M.anyVisibleSession(r.state), false)
})

test("anyVisibleSession turns true only once the debounce fires", () => {
  const r = start(M.emptyState(), "monitor", "DP-1", 0)
  assert.equal(M.anyVisibleSession(M.fireDue(r.state, 699)), false)
  assert.equal(M.anyVisibleSession(M.fireDue(r.state, 700)), true)
})

test("anyVisibleSession stays true across the idle-stop churn", () => {
  // This is the property that keeps a 14-minute call to one "started" and one
  // "stopped": Hyprland stops and restarts the capture every ~500 ms, and the
  // revive inside the grace never clears `visible`. 107 cycles, no flicker.
  const key = M.sessionKey("window", "Teams")
  let state = M.fireDue(start(M.emptyState(), "window", "Teams", 0).state, 700)
  assert.equal(M.anyVisibleSession(state), true)

  let now = 1000
  for (let i = 0; i < 107; i++) {
    state = stop(state, "window", "Teams", now).state
    assert.equal(M.anyVisibleSession(state), true, `cycle ${i}: went false inside the grace`)
    now += 500
    state = start(state, "window", "Teams", now).state
    assert.equal(M.anyVisibleSession(state), true, `cycle ${i}: went false on revive`)
    assert.equal(state.sessions[key].stoppingAt, 0, `cycle ${i}: revive must clear the grace`)
    now += 500
  }
})

test("anyVisibleSession goes false only when the grace actually expires", () => {
  let state = M.fireDue(start(M.emptyState(), "monitor", "DP-1", 0).state, 700)
  state = stop(state, "monitor", "DP-1", 1000).state
  assert.equal(M.anyVisibleSession(M.expireGrace(state, 2499).state), true, "still inside the grace")
  assert.equal(M.anyVisibleSession(M.expireGrace(state, 2500).state), false)
})

test("anyVisibleSession refuses a visible flag with no session behind it", () => {
  // Should be unreachable -- every teardown deletes from both maps together --
  // so this pins that a dangling flag is never enough to claim a live capture.
  const state = M.emptyState()
  state.visible[M.sessionKey("monitor", "DP-1")] = true
  assert.equal(M.anyVisibleSession(state), false)
})

test("anyVisibleSession tolerates junk in place of a state", () => {
  assert.equal(M.anyVisibleSession(null), false)
  assert.equal(M.anyVisibleSession(undefined), false)
  assert.equal(M.anyVisibleSession({}), false)
})

test("sessionStateWord says nothing about a row that is actually ringing", () => {
  assert.equal(M.sessionStateWord({ visible: true, stopping: false }), "")
  assert.equal(M.sessionStateWord({ visible: true, stopping: true }), "",
               "a ringing session in its stop grace is still on screen")
})

test("sessionStateWord labels a row the ring has not reached yet", () => {
  assert.equal(M.sessionStateWord({ visible: false, stopping: false }), "starting")
})

test("sessionStateWord does not call a session that already stopped 'starting'", () => {
  // A share that stops before its debounce fires never becomes visible and
  // sits out its grace instead. "starting" would be the wrong word for the
  // same missing ring.
  assert.equal(M.sessionStateWord({ visible: false, stopping: true }), "stopping")
})

test("sessionStateWord treats a missing row as not ringing", () => {
  assert.equal(M.sessionStateWord(null), "")
  assert.equal(M.sessionStateWord({}), "starting")
})

// ------------------------------------------------------------------- health

test("layerRuleState passes as soon as the marker is back", () => {
  assert.equal(M.layerRuleState(true, 0, 1), "ok")
  assert.equal(M.layerRuleState(true, 1, 1), "ok")
})

test("layerRuleState waits before crying wolf", () => {
  // A slow config reload must not raise a false alarm on the install footgun
  // with the worst consequence.
  assert.equal(M.layerRuleState(false, 0, 1), "checking")
})

test("layerRuleState reports missing once the retries are used", () => {
  assert.equal(M.layerRuleState(false, 1, 1), "missing")
})

test("layerRuleContentPresent treats empty content as absent regardless of freshness", () => {
  assert.equal(M.layerRuleContentPresent("", true, "abc"), false)
  assert.equal(M.layerRuleContentPresent("", false, "abc"), false)
  assert.equal(M.layerRuleContentPresent("", false, ""), false)
})

test("layerRuleContentPresent accepts any non-empty content when freshness is not required", () => {
  // The startup path: hypr.lua already ran with no reload of this
  // service's own behind it, so mere presence is all that can be asked.
  assert.equal(M.layerRuleContentPresent("abc", false, "abc"), true)
  assert.equal(M.layerRuleContentPresent("abc", false, "xyz"), true)
})

test("layerRuleContentPresent requires the content to differ when freshness is required", () => {
  // The reload path: unchanged content is indistinguishable from a stale
  // marker left over from before the guarded snippet was removed.
  assert.equal(M.layerRuleContentPresent("abc", true, "abc"), false)
  assert.equal(M.layerRuleContentPresent("abc", true, "xyz"), true)
})

test("parseCursorMode finds the setting inside the screencopy block", () => {
  assert.equal(M.parseCursorMode("screencopy {\n  cursor_mode = 2\n}\n"), 2)
})

test("parseCursorMode ignores cursor_mode outside screencopy", () => {
  assert.equal(M.parseCursorMode("general {\n  cursor_mode = 2\n}\n"), null)
})

test("parseCursorMode ignores comments", () => {
  assert.equal(M.parseCursorMode("screencopy {\n  # cursor_mode = 2\n}\n"), null)
})

test("cursorState tells 'set' apart from 'set but not live'", () => {
  // Applied at portal start. Setting it afterwards looks identical in the
  // file and does nothing at all, which is otherwise unexplainable.
  assert.equal(M.cursorState(true, 2, 1000, 2000), "ok")
  assert.equal(M.cursorState(true, 2, 3000, 2000), "stale")
})

test("cursorState covers the other three cases", () => {
  assert.equal(M.cursorState(false, null, 0, 0), "missing")
  assert.equal(M.cursorState(true, null, 1000, 2000), "unset")
  assert.equal(M.cursorState(true, 1, 1000, 2000), "hidden")
})

test("cursorState tells 'the portal never started' apart from 'I could not find out'", () => {
  // portalStartedMs === 0 is ambiguous on its own: the unit may simply be
  // inactive (systemctl exits 0 with an empty value), or the query itself
  // may have failed (dbus not up yet, a transient bus error) -- and a
  // failed query must never be reported as "ok", because that is exactly
  // the silently-wrong-ok the readout exists to avoid. Neither is it
  // "stale": staleness is undeterminable, not asserted.
  assert.equal(M.cursorState(true, 2, 1000, 0, false), "ok")
  assert.equal(M.cursorState(true, 2, 1000, 0, true), "unknown")
  assert.equal(M.cursorState(true, 2, 3000, 0, true), "unknown")
})

// ------------------------------------------------------------ health section

test("layerRuleSeverity only alarms on the one confirmed-bad state", () => {
  assert.equal(M.layerRuleSeverity("missing"), "error")
})

test("layerRuleSeverity renders nothing for ok, checking, or indeterminate", () => {
  // "checking" and "indeterminate" both mean "no verdict yet" -- neither a
  // false alarm nor a false all-clear on the project's highest-consequence
  // signal. See Service.qml's layerRuleLastContent comment for why
  // "indeterminate" exists at all.
  assert.equal(M.layerRuleSeverity("ok"), "")
  assert.equal(M.layerRuleSeverity("checking"), "")
  assert.equal(M.layerRuleSeverity("indeterminate"), "")
})

test("cursorSeverity warns on every confirmed-bad cursor state", () => {
  assert.equal(M.cursorSeverity("stale"), "warning")
  assert.equal(M.cursorSeverity("unset"), "warning")
  assert.equal(M.cursorSeverity("hidden"), "warning")
  assert.equal(M.cursorSeverity("missing"), "warning")
})

test("cursorSeverity renders nothing for ok or unknown", () => {
  // "unknown" means the portal-start query itself failed -- staleness is
  // undeterminable, not asserted. Warning here would be exactly the guess
  // this function exists to refuse.
  assert.equal(M.cursorSeverity("ok"), "")
  assert.equal(M.cursorSeverity("unknown"), "")
})

test("applyCursorModeFix creates a fresh minimal block when the file is missing", () => {
  assert.equal(M.applyCursorModeFix(""), "screencopy {\n    cursor_mode = 2\n}\n")
  assert.equal(M.applyCursorModeFix(null), "screencopy {\n    cursor_mode = 2\n}\n")
})

test("applyCursorModeFix inserts cursor_mode into an existing block, leaving every other line intact", () => {
  const before = "screencopy {\n    allow_token_by_default = true\n    custom_picker_binary = foo\n}\n"
  const after = "screencopy {\n    cursor_mode = 2\n    allow_token_by_default = true\n    custom_picker_binary = foo\n}\n"
  assert.equal(M.applyCursorModeFix(before), after)
})

test("applyCursorModeFix updates a wrong value in place instead of adding a second line", () => {
  const before = "screencopy {\n    cursor_mode = 1\n    allow_token_by_default = true\n}\n"
  const after = "screencopy {\n    cursor_mode = 2\n    allow_token_by_default = true\n}\n"
  assert.equal(M.applyCursorModeFix(before), after)
})

test("applyCursorModeFix is a no-op when cursor_mode is already 2", () => {
  const content = "screencopy {\n    cursor_mode = 2\n    allow_token_by_default = true\n}\n"
  assert.equal(M.applyCursorModeFix(content), content)
})

test("applyCursorModeFix treats a commented-out cursor_mode as absent, not as set", () => {
  const before = "screencopy {\n    # cursor_mode = 1\n    allow_token_by_default = true\n}\n"
  const after = "screencopy {\n    cursor_mode = 2\n    # cursor_mode = 1\n    allow_token_by_default = true\n}\n"
  assert.equal(M.applyCursorModeFix(before), after)
})

test("applyCursorModeFix appends a whole new block when the file has no screencopy at all, keeping existing content", () => {
  const before = "general {\n    gaps_in = 2\n}\n"
  const after = "general {\n    gaps_in = 2\n}\nscreencopy {\n    cursor_mode = 2\n}\n"
  assert.equal(M.applyCursorModeFix(before), after)
})

test("applyCursorModeFix matches the block's own indentation for the inserted line", () => {
  const before = "screencopy {\n  allow_token_by_default = true\n}\n"
  const after = "screencopy {\n  cursor_mode = 2\n  allow_token_by_default = true\n}\n"
  assert.equal(M.applyCursorModeFix(before), after)
})

test("applyCursorModeFix tracks brace depth through a nested block, not just the first '}'", () => {
  // The nested block's own closing brace (depth 2 -> 1) must not be
  // mistaken for the end of the outer screencopy block (depth 1 -> 0);
  // getting that wrong would insert cursor_mode after the wrong '}' or
  // miscompute the sibling indent to match against.
  const before = "screencopy {\n    sub {\n        foo = 1\n    }\n    allow_token_by_default = true\n}\n"
  const after = "screencopy {\n    cursor_mode = 2\n    sub {\n        foo = 1\n    }\n    allow_token_by_default = true\n}\n"
  assert.equal(M.applyCursorModeFix(before), after)
})

test("applyCursorModeFix on CRLF input: pinning current behaviour, not asserting it is ideal", () => {
  // Every original line's own trailing \r survives untouched (split/join
  // on "\n" never touches it), so the file is not corrupted -- but the
  // freshly inserted line has no \r of its own, so it alone ends in a bare
  // \n while its CRLF siblings keep \r\n. Cosmetic, not a correctness bug;
  // pinned as-is rather than normalized, per instruction.
  const before = "screencopy {\r\n    allow_token_by_default = true\r\n}\r\n"
  const after = "screencopy {\r\n    cursor_mode = 2\n    allow_token_by_default = true\r\n}\r\n"
  assert.equal(M.applyCursorModeFix(before), after)
})
