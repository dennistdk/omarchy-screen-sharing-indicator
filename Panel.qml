import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "ShareModel.js" as ShareModel

// The Screen Sharing Indicator panel: what is being shared right now, direct from the
// service's live session table.
//
// It exists to answer one question -- "is that border stale?" -- so it reads
// svc.sessionSummaries()/targetSummaries() through property bindings rather
// than statusJson() on a timer. Both read Service.qml's own QML properties, and
// QML's binding tracker follows property reads through a function call, so
// `sessions`/`targets` re-evaluate whenever the service's state changes. No
// polling, no cached snapshot.
Panel {
  id: root
  moduleName: "io.github.dennistdk.screen-sharing-indicator"

  // Service.qml owns the single IpcHandler on this plugin's target. The base's
  // generic one is inert only while ipcTarget is unset, so this says out loud
  // what the empty ipcTarget only implies: a later ipcTarget here must not
  // quietly stand up a second handler competing for the same target.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var svc: null

  // The bar tracks the widget in its slot, not this nested panel, so
  // anything the popout coordinator compares against has to be the widget.
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // svc is null for a narrow window during shell startup and on any injection
  // hiccup. That is a genuinely unknown state, not a confirmed-idle one, so it
  // must never render the same as an empty session table. See statusText.
  readonly property bool serviceUnknown: !svc

  readonly property var sessions: svc ? svc.sessionSummaries() : []

  // targetSummaries() calls Hyprland.refreshToplevels() before reading
  // toplevelList(), and the binding tracker follows that read back through this
  // property -- so every refresh that changes the toplevels model re-triggers
  // the binding, which refreshes again. Gating on root.opened confines that loop
  // to the window the panel is actually readable in, rather than the shell's
  // whole lifetime via BarWidget.qml's always-active Loader.
  readonly property var targets: (svc && root.opened) ? svc.targetSummaries() : []
  readonly property var rows: buildRows(sessions, targets)

  // Rows actually bordered, not rows in the table -- see countActiveRows. "0
  // active" over a list of rows marked "starting" is the honest reading of a
  // picker sitting open.
  readonly property int activeRowCount: countActiveRows(rows)
  readonly property string heroMeta: rows.length === 0
    ? ""
    : (activeRowCount === 1 ? "1 active" : activeRowCount + " active")

  // A third state, distinct from the idle string: answering "nothing is being
  // shared" from ignorance would be an all-clear this code has not earned.
  //
  // And a fourth, for the same reason in the other direction. svc arrives by
  // injection once BarWidget's Loader completes, so a null is normal for a
  // moment at startup -- but shell.qml's ensureService logs a failed service
  // load to the journal and returns null, leaving nothing to ever inject. An
  // ellipsis that never resolves promises progress that is not coming, on a
  // plugin whose whole premise is that the silent failure is the dangerous one.
  property bool serviceLoadTimedOut: false

  readonly property string statusText: !root.serviceUnknown
    ? "Nothing is being shared"
    : (root.serviceLoadTimedOut
        ? "The indicator service is not running. Restart the shell."
        : "Checking…")

  onSvcChanged: {
    if (svc) {
      serviceLoadTimedOut = false
      serviceWaitTimer.stop()
    } else {
      serviceWaitTimer.restart()
    }
  }

  // Started here as well as on change: if injection never happens at all,
  // onSvcChanged never fires and the timer would never have been armed.
  Component.onCompleted: if (!root.svc) serviceWaitTimer.start()

  Timer {
    id: serviceWaitTimer
    interval: 5000
    repeat: false
    onTriggered: root.serviceLoadTimedOut = true
  }

  // Reset the settings cursor on every open, so a panel left mid-navigation
  // does not reopen with a stale cursor position or a highlight already lit.
  function open() {
    root.cursorActive = false
    root.cursorIndex = 0
    // checkCursorState() is one-shot: otherwise it runs only at shell start or
    // after the fix button writes xdph.conf. Without this call, someone who
    // fixes the file by hand and reopens the panel still sees the old reading.
    if (svc && typeof svc.checkCursorState === "function") svc.checkCursorState()
    root.controller.show()
  }

  function openFromHotkey() { root.open() }

  // Route panel switching through the widget, not this nested panel.
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ------------------------------------------------------------- settings

  // updateEntryInline rebuilds the entry as {id} plus exactly what it is handed,
  // so anything omitted is deleted from the user's config. mergedSettings folds
  // one change over the entry's current contents, so every write sends the whole
  // entry.
  //
  // Two call shapes: writeSetting("key", value) for a single field, and
  // writeSetting({key1: v1, ...}) when fields must land together -- picking a
  // swatch sets `color` and returns `colorMode` to "fixed" in one write.
  function writeSetting(key, value) {
    var changes
    if (key !== null && typeof key === "object") {
      changes = key
    } else {
      changes = ({})
      changes[key] = value
    }
    var merged = ShareModel.mergedSettings(root.settings, changes)
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, merged)
  }

  // Prefer the live service property, which reflects the moment the shell
  // finishes applying a write, and fall back to the same default the service
  // computes from settingsEntry -- so rows read right, and writeSetting still
  // works off root.settings, during the window where svc is null.
  readonly property bool activeSetting: svc ? svc.active : (root.setting("active", true) !== false)
  readonly property bool windowBordersSetting: svc ? svc.showWindowBorders : (root.setting("showWindowBorders", true) !== false)
  readonly property bool monitorBordersSetting: svc ? svc.showMonitorBorders : (root.setting("showMonitorBorders", true) !== false)
  readonly property bool notifySetting: svc ? svc.notify : (root.setting("notify", false) === true)

  // ------------------------------------------------------------ appearance

  // Six hand-picked reds, close to the red-to-orange arc autoBorderColor guards
  // for "auto" (hue >= 350 or <= 40); two (#D40030 at 346, #FF1744 at 348) sit
  // just outside that band. Unambiguously red regardless -- none is near a hue
  // that could read as a green "you are safe" border.
  readonly property var colorPresets: ["#E81123", "#FF3B30", "#FF6A00", "#D40030", "#C1121F", "#FF1744"]

  readonly property string colorSetting: svc ? svc.colorSpec : String(root.setting("color", "#E81123") || "#E81123")
  readonly property string colorModeSetting: svc ? svc.colorMode : (root.setting("colorMode", "fixed") === "auto" ? "auto" : "fixed")
  readonly property int widthSetting: svc ? svc.widthPx : clampWidth(root.setting("widthPx", 3))

  function clampWidth(value) {
    var n = Math.floor(Number(value))
    if (!isFinite(n)) return 3
    return Math.max(1, Math.min(16, n))
  }

  function isCurrentSwatch(hex) {
    return root.colorModeSetting === "fixed"
        && String(root.colorSetting).toLowerCase() === String(hex).toLowerCase()
  }

  function currentSwatchIndex() {
    for (var i = 0; i < root.colorPresets.length; i++) {
      if (String(root.colorPresets[i]).toLowerCase() === String(root.colorSetting).toLowerCase()) return i
    }
    return 0
  }

  // Picking a swatch is one write of both fields -- color and a return to
  // "fixed" -- so a swatch pick out of Auto never leaves colorMode stranded.
  function pickColor(hex) { root.writeSetting({ color: hex, colorMode: "fixed" }) }
  function pickAuto() { root.writeSetting("colorMode", "auto") }

  // Cycles preset -> preset -> ... -> Auto -> back to the first preset, so
  // Enter alone (no arrow keys) can reach every option from the swatch row.
  function stepColorOption(delta) {
    var n = root.colorPresets.length + 1 // +1 for Auto
    var idx = root.colorModeSetting === "auto" ? root.colorPresets.length : root.currentSwatchIndex()
    var next = (idx + delta + n) % n
    if (next >= root.colorPresets.length) root.pickAuto()
    else root.pickColor(root.colorPresets[next])
  }

  // Wraps rather than clamping, so Enter alone can cycle all the way round --
  // the same reasoning as stepColorOption.
  function stepWidth(delta) {
    var next = root.widthSetting + delta
    if (next > 16) next = 1
    if (next < 1) next = 16
    root.writeSetting("widthPx", next)
  }

  function previewNow() {
    if (svc && typeof svc.startPreview === "function") svc.startPreview()
  }

  // -------------------------------------------------------------- health
  //
  // Two readouts, two otherwise invisible failures: the layer rule that keeps
  // this border out of *other people's* captures, and the cursor mode that decides
  // whether your pointer reaches them at all. Both judge through a pure severity
  // function in ShareModel.js rather than inline here, because both source
  // states carry a "no verdict yet" value that must render exactly like "ok" --
  // nothing at all. See ShareModel.layerRuleSeverity.
  readonly property string layerRuleSeverity: svc ? ShareModel.layerRuleSeverity(svc.layerRuleCheckState) : ""
  readonly property string cursorSeverity: svc ? ShareModel.cursorSeverity(svc.cursorState) : ""
  readonly property bool layerRuleWarningShown: root.layerRuleSeverity === "error"

  // The rule being unloaded is always worth fixing, but "your audience can see
  // this" is only true while a monitor or region capture is actually carrying
  // it. Claiming it over an idle desktop, or during a window share that leaks
  // nothing, spends the red on a moment that has not earned it -- the same
  // standard statusText holds itself to. Both tiers carry the same fix.
  readonly property bool borderLeakingNow: countLeakingRows(root.rows) > 0

  readonly property string layerRuleHeadline: root.borderLeakingNow
    ? "Your audience can see this border"
    : "This border is not private yet"

  // The headline already gives the diagnosis, so the body only has to say what
  // it costs; the button below says how to end it. That is what let this drop
  // from ~330 characters of README directions to one line.
  readonly property string layerRuleBody: root.borderLeakingNow
    ? "Anyone watching your monitor share sees it in their stream."
    : "Share a monitor or region and your audience will see it too."

  // ------------------------------------------------------------ cursor fix

  readonly property bool cursorFixShown: root.cursorSeverity === "warning"
  // The service's own refusal gate, read off it rather than reconstructed here,
  // so the button is never enabled for a moment the action would refuse anyway.
  // It covers a drawn border (real session or preview) and a live capture with no
  // border, which is what either border toggle produces.
  readonly property bool sharingActive: svc ? svc.portalRestartUnsafe === true : false
  readonly property bool layerRuleFixBusy: svc ? svc.layerRuleFixBusy === true : false
  readonly property bool layerRuleFixShown: root.layerRuleWarningShown
    && svc && svc.layerRuleFixAvailable === true
  readonly property bool layerRuleFixEnabled: !root.layerRuleFixBusy

  function fixLayerRuleNow() {
    if (!root.layerRuleFixEnabled) return
    if (svc && typeof svc.applyLayerRuleFix === "function") svc.applyLayerRuleFix()
  }

  readonly property bool cursorFixBusy: svc ? svc.cursorFixBusy === true : false
  readonly property bool cursorFixEnabled: !root.sharingActive && !root.cursorFixBusy

  function fixCursorNow() {
    if (!root.cursorFixEnabled) return
    if (svc && typeof svc.applyCursorFix === "function") svc.applyCursorFix()
  }

  // --------------------------------------------------------- keyboard cursor

  // PanelKeyCatcher below eats Space/Return/Tab before any descendant Keys
  // handler sees them (Keys.priority: Keys.BeforeItem), so a row's own
  // focus/Keys handling never fires and this cursor is the only path a keyboard
  // user has to these controls. Follows the cursorIndex/cursorActive pattern the
  // Cloud panel uses, over fixed rows rather than a Repeater.
  property int cursorIndex: 0
  property bool cursorActive: false
  // 0-3 the four toggles; 4 the swatch row; 5 the width control; 6 preview;
  // 7 the cursor fix button -- only while that section is actually shown,
  // so a keyboard user can never land the cursor on a row that isn't there.
  // The ordering array is the single source of truth for keyboard navigation.
  // Conditional rows drop out of it entirely rather than leaving a hole, so
  // nothing downstream has to know that an index shifted. That matters now that
  // a conditional row sits at the *top*: with numeric literals, "index 3" would
  // have meant Notifications with the layer-rule warning hidden and Monitor
  // borders with it showing. Rows are compared by identity instead.
  readonly property var cursorRows: {
    var out = []
    if (root.layerRuleFixShown) out.push(fixLayerRuleButton)
    out.push(toggleActiveRow, toggleWindowBordersRow, toggleMonitorBordersRow,
             toggleNotifyRow, colorRow, widthRow, previewButton)
    if (root.cursorFixShown) out.push(fixCursorButton)
    return out
  }

  readonly property int rowCount: root.cursorRows.length

  // Deliberately not gated on cursorActive: moveCursor and activateCursor need
  // the row under the cursor even on the keystroke that first activates it.
  // The hasCursor bindings add the cursorActive check themselves.
  readonly property var cursorAt: (root.cursorIndex >= 0 && root.cursorIndex < root.cursorRows.length)
    ? root.cursorRows[root.cursorIndex] : null

  function indexOfRow(item) {
    var i = root.cursorRows.indexOf(item)
    return i < 0 ? root.cursorIndex : i
  }

  function focusRow(item) {
    root.cursorActive = true
    root.cursorIndex = root.indexOfRow(item)
  }

  function clampCursor() {
    if (cursorIndex >= rowCount) cursorIndex = Math.max(0, rowCount - 1)
    if (cursorIndex < 0) cursorIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy !== 0) {
      cursorIndex = Math.max(0, Math.min(rowCount - 1, cursorIndex + dy))
      scrollCursorIntoView()
      return
    }
    // Left/Right on the swatch or width row is a fast path; Enter alone
    // (activateCursor below) already reaches every value.
    if (dx === 0) return
    if (cursorAt === colorRow) stepColorOption(dx > 0 ? 1 : -1)
    else if (cursorAt === widthRow) stepWidth(dx > 0 ? 1 : -1)
  }

  function activateCursor() {
    clampCursor()
    var row = root.cursorAt
    if (row === toggleActiveRow) toggleActive()
    else if (row === toggleWindowBordersRow) toggleWindowBorders()
    else if (row === toggleMonitorBordersRow) toggleMonitorBorders()
    else if (row === toggleNotifyRow) toggleNotify()
    else if (row === colorRow) stepColorOption(1)
    else if (row === widthRow) stepWidth(1)
    else if (row === previewButton) previewNow()
    else if (row === fixCursorButton) fixCursorNow()
    else if (row === fixLayerRuleButton) fixLayerRuleNow()
  }

  // Shared by activateCursor() and each row's onClicked, so mouse and keyboard
  // flip the same write -- one path into writeSetting() per setting.
  function toggleActive() { root.writeSetting("active", !root.activeSetting) }
  function toggleWindowBorders() { root.writeSetting("showWindowBorders", !root.windowBordersSetting) }
  function toggleMonitorBorders() { root.writeSetting("showMonitorBorders", !root.monitorBordersSetting) }
  function toggleNotify() { root.writeSetting("notify", !root.notifySetting) }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    scrollItemIntoView(root.cursorAt)
  }

  // ------------------------------------------------------------ row model

  // The title a session's window has worn most recently. names[] is append-only,
  // so the last entry is the current one; session.name is the title captured at
  // start, a fallback for the moment before the first name lands.
  function currentTitle(session) {
    var names = session.names || []
    if (names.length) return names[names.length - 1]
    return session.name || ""
  }

  // A window session's identity (title) carries no output of its own.
  // targetSummaries() resolves that per matched window, keyed by the addresses
  // frozen on the session rather than by name, which is only a point-in-time
  // title. No match means the window is unresolved or already gone; either way
  // this returns "" and the row renders without an output segment.
  function outputForWindow(session, targetList) {
    var wanted = {}
    var addresses = session.addresses || []
    for (var i = 0; i < addresses.length; i++) {
      var addr = ShareModel.normalizeAddress(addresses[i])
      if (addr) wanted[addr] = true
    }
    for (var j = 0; j < targetList.length; j++) {
      var target = targetList[j]
      if (target.kind !== ShareModel.OWNER_WINDOW) continue
      if (wanted[ShareModel.normalizeAddress(target.address)]) return target.monitor || ""
    }
    return ""
  }

  // Monitor and region sessions carry the output name as their session name
  // directly -- there is no separate identity to resolve.
  function buildRows(sessionList, targetList) {
    var out = []
    var list = sessionList || []
    var byTarget = targetList || []
    for (var i = 0; i < list.length; i++) {
      var session = list[i]
      if (!session) continue
      var isWindow = session.type === ShareModel.OWNER_WINDOW
      var identity = isWindow ? currentTitle(session) : (session.name || "")
      var output = isWindow ? outputForWindow(session, byTarget) : (session.name || "")
      if (identity === "") identity = isWindow ? "(untitled window)" : "(unnamed output)"
      out.push({
        identity: identity,
        type: session.type || "",
        output: output,
        // Carried, not filtered on. sessionSummaries() returns the whole
        // session table, and a normal Teams picker flow fills it with sessions
        // that are not bordered -- one measured flow held six window previews and
        // three monitor ones at once, all inside their debounce with strips=0.
        // Dropping those rows would under-report a capture, the unsafe direction
        // in the one place a user asks "is that border stale?". rowMeta says which
        // are not on screen.
        visible: session.visible === true,
        stopping: session.stopping === true
      })
    }
    return out
  }

  // How many rows are actually bordered. The hero counts this, not rows.length:
  // nine picker previews reading "9 active" over zero borders is the false alarm
  // that teaches someone to stop trusting the number. The rows stay visible.
  function countActiveRows(rowList) {
    var n = 0
    var list = rowList || []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].visible) n++
    return n
  }

  // Rows whose border is actually reaching someone else. A window share leaks
  // nothing however broken the layer rule is -- window captures never include
  // layer-shell surfaces at all -- so only a monitor or region row counts, and
  // only once it is on screen rather than still inside its debounce.
  function countLeakingRows(rowList) {
    var n = 0
    var list = rowList || []
    for (var i = 0; i < list.length; i++) {
      var row = list[i]
      if (row && row.visible && row.type !== ShareModel.OWNER_WINDOW) n++
    }
    return n
  }

  // "Firefox · window · DP-1". When the identity already is the output
  // (monitor/region shares), the output segment would only repeat it, so it is
  // dropped. A row with no border on screen gains a state word -- "window ·
  // starting" -- so a session the debounce has not passed never reads as a live
  // border. See ShareModel.sessionStateWord for why the word is not always
  // "starting".
  function rowMeta(row) {
    var parts = [row.type]
    if (row.output !== "" && row.output !== row.identity) parts.push(row.output)
    var word = ShareModel.sessionStateWord(row)
    if (word !== "") parts.push(word)
    return parts.join(" · ")
  }

  // ---------------------------------------------------------------- surface

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    // No fixed cap: seven interactive rows plus an unbounded session list fit no
    // constant. fittedContentHeight's own screen-bound availableCardHeight is the
    // real limit, as it is for the first-party bluetooth, clock, weather, power
    // and network panels, and the Flickable below covers genuine overflow.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Screen Sharing Indicator"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰈈"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // Silent whenever the rule is loaded, still checking, or
          // indeterminate (see layerRuleSeverity above); the column collapses to
          // zero height when hidden, so a healthy setup shows nothing here.
          // Placed ahead of even the session list, because its consequence --
          // a border reaching people who are not in the room -- outranks what is
          // currently sharing. Whether that is happening or merely possible is
          // borderLeakingNow's call, and it picks both the wording and the red.
          Column {
            id: layerRuleWarningColumn
            visible: root.layerRuleWarningShown
            width: parent.width
            spacing: Style.spacing.xs

            Text {
              textFormat: Text.PlainText
              text: root.layerRuleHeadline
              color: root.borderLeakingNow ? Color.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: root.layerRuleBody
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            // Says what the button will do before it is pressed, for the same
            // reason the cursor fix does: this writes the user's compositor
            // config, and a keyboard user driving it never triggers a hover.
            Text {
              visible: root.layerRuleFixShown
              textFormat: Text.PlainText
              text: "Edits ~/.config/hypr/hyprland.lua and reloads Hyprland."
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
            }

            Button {
              id: fixLayerRuleButton
              visible: root.layerRuleFixShown
              width: parent.width
              text: root.layerRuleFixBusy ? "Hiding…" : "Hide the border from your audience"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.layerRuleFixEnabled
              opacity: enabled ? 1.0 : 0.6
              hasCursor: root.cursorActive && root.cursorAt === fixLayerRuleButton
              onClicked: root.fixLayerRuleNow()
              onHovered: function(isHovered) {
                if (isHovered) root.focusRow(fixLayerRuleButton)
              }
            }

            PanelSeparator {
              foreground: root.foreground
            }
          }

          // The cursor half of the health section sits at the bottom of
          // Appearance, out of sight until you scroll, so someone whose only
          // problem is the cursor would otherwise open this panel and see
          // nothing. This is the pointer, not the control: a plain Text rather
          // than a button, so it stays outside the keyboard cursor's row model
          // entirely. Same visibility gate as the section it points at.
          Text {
            visible: root.cursorFixShown
            width: parent.width
            textFormat: Text.PlainText
            text: "Your pointer may not reach your audience -- see Appearance below"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.rows.length === 0
            width: parent.width
            text: root.statusText
            color: root.serviceLoadTimedOut ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: sessionColumn
            visible: root.rows.length > 0
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.rows
              delegate: ColumnLayout {
                required property var modelData
                width: sessionColumn.width
                spacing: Style.space(1)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: modelData.identity
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.rowMeta(modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          PanelSectionHeader {
            text: "SETTINGS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            id: settingsColumn
            width: parent.width
            spacing: Style.space(6)

            Toggle {
              id: toggleActiveRow
              width: parent.width
              label: "Enabled"
              description: "Off hides the border. The icon still tracks shares."
              checked: root.activeSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorAt === toggleActiveRow
              onClicked: root.toggleActive()
              onHovered: function(isHovered) {
                if (isHovered) root.focusRow(toggleActiveRow)
              }
            }

            Toggle {
              id: toggleWindowBordersRow
              width: parent.width
              label: "Window borders"
              description: "Draw a border around a shared window."
              checked: root.windowBordersSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorAt === toggleWindowBordersRow
              onClicked: root.toggleWindowBorders()
              onHovered: function(isHovered) {
                if (isHovered) root.focusRow(toggleWindowBordersRow)
              }
            }

            Toggle {
              id: toggleMonitorBordersRow
              width: parent.width
              label: "Monitor borders"
              description: "Draw a border around a shared monitor."
              checked: root.monitorBordersSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorAt === toggleMonitorBordersRow
              onClicked: root.toggleMonitorBorders()
              onHovered: function(isHovered) {
                if (isHovered) root.focusRow(toggleMonitorBordersRow)
              }
            }

            Toggle {
              id: toggleNotifyRow
              width: parent.width
              label: "Notifications"
              description: "Desktop notification when sharing starts and stops."
              checked: root.notifySetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorAt === toggleNotifyRow
              onClicked: root.toggleNotify()
              onHovered: function(isHovered) {
                if (isHovered) root.focusRow(toggleNotifyRow)
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          PanelSectionHeader {
            text: "APPEARANCE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            id: appearanceColumn
            width: parent.width
            spacing: Style.space(6)

            CursorSurface {
              id: colorRow
              width: parent.width
              radius: Style.cornerRadius
              foreground: root.foreground
              accent: Color.accent
              hasCursor: root.cursorActive && root.cursorAt === colorRow
              implicitHeight: colorContent.implicitHeight + Style.spacing.huge

              HoverHandler {
                onHoveredChanged: if (hovered) root.focusRow(colorRow)
              }

              Column {
                id: colorContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  text: "Border color"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Row {
                  spacing: Style.spacing.sm
                  topPadding: Style.spacing.xs

                  Repeater {
                    model: root.colorPresets

                    delegate: Rectangle {
                      required property string modelData
                      width: Style.space(22)
                      height: Style.space(22)
                      radius: width / 2
                      color: modelData
                      border.width: root.isCurrentSwatch(modelData) ? Style.space(3) : Style.space(1)
                      border.color: root.isCurrentSwatch(modelData) ? root.foreground : Qt.darker(root.foreground, 2.2)

                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pickColor(modelData)
                      }
                    }
                  }

                  Rectangle {
                    width: Style.space(46)
                    height: Style.space(22)
                    radius: Style.cornerRadius
                    color: "transparent"
                    border.width: root.colorModeSetting === "auto" ? Style.space(3) : Style.space(1)
                    border.color: root.colorModeSetting === "auto" ? root.foreground : Qt.darker(root.foreground, 2.2)

                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: "Auto"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      id: autoMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.pickAuto()
                    }

                    PanelToolTip {
                      visible: autoMouse.containsMouse
                      text: "Shifts the colour if it is too close to your theme accent."
                      fontFamily: root.fontFamily
                    }
                  }
                }
              }
            }

            CursorSurface {
              id: widthRow
              width: parent.width
              radius: Style.cornerRadius
              foreground: root.foreground
              accent: Color.accent
              hasCursor: root.cursorActive && root.cursorAt === widthRow
              implicitHeight: widthContent.implicitHeight + Style.spacing.huge

              HoverHandler {
                onHoveredChanged: if (hovered) root.focusRow(widthRow)
              }

              RowLayout {
                id: widthContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.md

                Column {
                  Layout.fillWidth: true
                  spacing: Style.spacing.xs

                  Text {
                    textFormat: Text.PlainText
                    text: "Border width"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "Your audience sees roughly double this in black."
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    width: parent.width
                  }
                }

                PanelActionButton {
                  iconText: "−"
                  tooltipText: "Decrease width"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.stepWidth(-1)
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.widthSetting + " px"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  horizontalAlignment: Text.AlignHCenter
                  Layout.preferredWidth: Style.space(40)
                }

                PanelActionButton {
                  iconText: "+"
                  tooltipText: "Increase width"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.stepWidth(1)
                }
              }
            }

            Button {
              id: previewButton
              width: parent.width
              text: "Preview border"
              tooltipText: "Shows the border for three seconds on the focused output."
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorAt === previewButton
              onClicked: root.previewNow()
              onHovered: function(isHovered) {
                if (isHovered) root.focusRow(previewButton)
              }
            }

            // The cursor half of the health section; the other half is
            // layerRuleWarningColumn near the top. It sits at the foot of
            // Appearance because the fix it offers is an appearance change, and
            // because the layer-rule warning is the one whose consequence is
            // reaching the audience right now. Keyboard row index 7.
            //
            // cursorFixShown reads cursorSeverity rather than a plain "!= ok",
            // so it excludes "unknown": there the portal-start query failed and
            // staleness could not be determined, and warning over that would be
            // the guess this readout refuses to make.
            Column {
              id: cursorFixColumn
              visible: root.cursorFixShown
              width: parent.width
              spacing: Style.spacing.xs

              PanelSeparator {
                foreground: root.foreground
              }

              Text {
                textFormat: Text.PlainText
                text: "Your pointer may not reach your audience"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              // States what the button will do before it is pressed. Not a
              // hover tooltip: this restarts the desktop portal, and a keyboard
              // user driving it never triggers a hover.
              Text {
                textFormat: Text.PlainText
                text: "Edits ~/.config/hypr/xdph.conf and restarts the desktop portal."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width
              }

              Button {
                id: fixCursorButton
                width: parent.width
                text: root.cursorFixBusy ? "Fixing…" : "Show the cursor by default"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.cursorFixEnabled
                opacity: enabled ? 1.0 : 0.6
                hasCursor: root.cursorActive && root.cursorAt === fixCursorButton
                onClicked: root.fixCursorNow()
                onHovered: function(isHovered) {
                  if (isHovered) root.focusRow(fixCursorButton)
                }
              }

              // Explained, not merely disabled: a dead control with no reason
              // looks broken, and the moment someone reaches for this is when
              // they are most likely to be presenting.
              Text {
                visible: root.sharingActive
                textFormat: Text.PlainText
                text: "Disabled while sharing -- restarting the portal would drop it."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width
              }

              // Permanent, whether or not the button is enabled: the fix only
              // changes the *default* for clients that never ask, and without
              // this line it looks broken for an app that asks for a hidden
              // cursor and keeps getting one.
              Text {
                textFormat: Text.PlainText
                text: "Sets the default only -- an app can still hide the cursor."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width
              }
            }
          }
        }
      }
    }
  }
}
