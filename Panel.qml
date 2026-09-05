import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "ShareModel.js" as ShareModel

// The Screen Sharing Indicator panel: what is being shared right now, direct from the
// service's live session table.
//
// It exists to answer one question -- "is that ring stale?" -- so it reads
// svc.sessionSummaries()/targetSummaries() through property bindings rather
// than statusJson() on a timer. Both read Service.qml's own QML properties, and
// QML's binding tracker follows property reads through a function call, so
// `sessions`/`targets` re-evaluate whenever the service's state changes. No
// polling, no cached snapshot.
Panel {
  id: root
  moduleName: "screen-sharing-indicator"

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

  // Rows actually ringing, not rows in the table -- see countActiveRows. "0
  // active" over a list of rows marked "starting" is the honest reading of a
  // picker sitting open.
  readonly property int activeRowCount: countActiveRows(rows)
  readonly property string heroMeta: rows.length === 0
    ? ""
    : (activeRowCount === 1 ? "1 active" : activeRowCount + " active")

  // A third state, distinct from the idle string: answering "nothing is being
  // shared" from ignorance would be an all-clear this code has not earned.
  readonly property string statusText: root.serviceUnknown
    ? "Checking…"
    : "Nothing is being shared"

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
  readonly property bool windowRingsSetting: svc ? svc.showWindowRings : (root.setting("showWindowRings", true) !== false)
  readonly property bool monitorRingsSetting: svc ? svc.showMonitorRings : (root.setting("showMonitorRings", true) !== false)
  readonly property bool notifySetting: svc ? svc.notify : (root.setting("notify", false) === true)

  // ------------------------------------------------------------ appearance

  // Six hand-picked reds, close to the red-to-orange arc autoRingColor guards
  // for "auto" (hue >= 350 or <= 40); two (#D40030 at 346, #FF1744 at 348) sit
  // just outside that band. Unambiguously red regardless -- none is near a hue
  // that could read as a green "you are safe" ring.
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
  // this ring out of *other people's* captures, and the cursor mode that decides
  // whether your pointer reaches them at all. Both judge through a pure severity
  // function in ShareModel.js rather than inline here, because both source
  // states carry a "no verdict yet" value that must render exactly like "ok" --
  // nothing at all. See ShareModel.layerRuleSeverity.
  readonly property string layerRuleSeverity: svc ? ShareModel.layerRuleSeverity(svc.layerRuleCheckState) : ""
  readonly property string cursorSeverity: svc ? ShareModel.cursorSeverity(svc.cursorState) : ""
  readonly property bool layerRuleWarningShown: root.layerRuleSeverity === "error"

  // ------------------------------------------------------------ cursor fix

  readonly property bool cursorFixShown: root.cursorSeverity === "warning"
  // The service's own refusal gate, read off it rather than reconstructed here,
  // so the button is never enabled for a moment the action would refuse anyway.
  // It covers a drawn ring (real session or preview) and a live capture with no
  // ring, which is what either ring toggle produces.
  readonly property bool sharingActive: svc ? svc.portalRestartUnsafe === true : false
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
  readonly property int rowCount: root.cursorFixShown ? 8 : 7

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
    if (cursorIndex === 4) stepColorOption(dx > 0 ? 1 : -1)
    else if (cursorIndex === 5) stepWidth(dx > 0 ? 1 : -1)
  }

  function activateCursor() {
    clampCursor()
    if (cursorIndex === 0) toggleActive()
    else if (cursorIndex === 1) toggleWindowRings()
    else if (cursorIndex === 2) toggleMonitorRings()
    else if (cursorIndex === 3) toggleNotify()
    else if (cursorIndex === 4) stepColorOption(1)
    else if (cursorIndex === 5) stepWidth(1)
    else if (cursorIndex === 6) previewNow()
    else if (cursorIndex === 7) fixCursorNow()
  }

  // Shared by activateCursor() and each row's onClicked, so mouse and keyboard
  // flip the same write -- one path into writeSetting() per setting.
  function toggleActive() { root.writeSetting("active", !root.activeSetting) }
  function toggleWindowRings() { root.writeSetting("showWindowRings", !root.windowRingsSetting) }
  function toggleMonitorRings() { root.writeSetting("showMonitorRings", !root.monitorRingsSetting) }
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
    var rows = [toggleActiveRow, toggleWindowRingsRow, toggleMonitorRingsRow, toggleNotifyRow,
                colorRow, widthRow, previewButton, fixCursorButton]
    scrollItemIntoView(rows[cursorIndex])
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
        // that are not ringing -- one measured flow held six window previews and
        // three monitor ones at once, all inside their debounce with strips=0.
        // Dropping those rows would under-report a capture, the unsafe direction
        // in the one place a user asks "is that ring stale?". rowMeta says which
        // are not on screen.
        visible: session.visible === true,
        stopping: session.stopping === true
      })
    }
    return out
  }

  // How many rows are actually ringing. The hero counts this, not rows.length:
  // nine picker previews reading "9 active" over zero rings is the false alarm
  // that teaches someone to stop trusting the number. The rows stay visible.
  function countActiveRows(rowList) {
    var n = 0
    var list = rowList || []
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].visible) n++
    return n
  }

  // "Firefox · window · DP-1". When the identity already is the output
  // (monitor/region shares), the output segment would only repeat it, so it is
  // dropped. A row with no ring on screen gains a state word -- "window ·
  // starting" -- so a session the debounce has not passed never reads as a live
  // ring. See ShareModel.sessionStateWord for why the word is not always
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
    contentWidth: panel.fittedContentWidth(Style.space(280))
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
            title: "Screen Sharing"
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
          // your audience is seeing the ring right now -- outranks what is
          // currently sharing.
          Column {
            id: layerRuleWarningColumn
            visible: root.layerRuleWarningShown
            width: parent.width
            spacing: Style.spacing.xs

            Text {
              textFormat: Text.PlainText
              text: "Your audience can see this ring"
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: "The Hyprland layer rule that keeps this ring out of monitor captures is not loaded, so anyone watching a monitor share right now sees it burned into their stream. Add the guarded snippet from the README's \"Then do this - it is not optional\" install step to ~/.config/hypr/hyprland.lua (or autostart.lua), then hyprctl reload."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
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
            text: "Cursor issue - see Appearance below"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.rows.length === 0
            width: parent.width
            text: root.statusText
            color: root.dim
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
              description: "Off pauses the ring without losing your other settings. Removing this widget from your bar stops the ring entirely -- its bar entry is also its on switch."
              checked: root.activeSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === 0
              onClicked: root.toggleActive()
              onHovered: function(isHovered) {
                if (isHovered) { root.cursorActive = true; root.cursorIndex = 0 }
              }
            }

            Toggle {
              id: toggleWindowRingsRow
              width: parent.width
              label: "Window rings"
              description: "Draw a ring around a shared window."
              checked: root.windowRingsSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === 1
              onClicked: root.toggleWindowRings()
              onHovered: function(isHovered) {
                if (isHovered) { root.cursorActive = true; root.cursorIndex = 1 }
              }
            }

            Toggle {
              id: toggleMonitorRingsRow
              width: parent.width
              label: "Monitor rings"
              description: "Draw a ring around a shared monitor."
              checked: root.monitorRingsSetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === 2
              onClicked: root.toggleMonitorRings()
              onHovered: function(isHovered) {
                if (isHovered) { root.cursorActive = true; root.cursorIndex = 2 }
              }
            }

            Toggle {
              id: toggleNotifyRow
              width: parent.width
              label: "Notifications"
              description: "Toast when sharing starts and stops."
              checked: root.notifySetting
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === 3
              onClicked: root.toggleNotify()
              onHovered: function(isHovered) {
                if (isHovered) { root.cursorActive = true; root.cursorIndex = 3 }
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
              hasCursor: root.cursorActive && root.cursorIndex === 4
              implicitHeight: colorContent.implicitHeight + Style.spacing.huge

              HoverHandler {
                onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursorIndex = 4 }
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
                  text: "Ring color"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Presets are hand-picked reds, chosen so none could be mistaken for a green all-clear."
                  color: Qt.darker(root.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  width: parent.width
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
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.pickAuto()
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
              hasCursor: root.cursorActive && root.cursorIndex === 5
              implicitHeight: widthContent.implicitHeight + Style.spacing.huge

              HoverHandler {
                onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursorIndex = 5 }
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
                    text: "Ring width"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "The audience's monitor capture blacks out roughly double this in physical pixels -- not purely cosmetic."
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
              text: "Preview ring"
              tooltipText: "Show the ring on the focused output for three seconds -- no notification."
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === 6
              onClicked: root.previewNow()
              onHovered: function(isHovered) {
                if (isHovered) { root.cursorActive = true; root.cursorIndex = 6 }
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
                text: "Edits ~/.config/hypr/xdph.conf and restarts the desktop portal (xdg-desktop-portal-hyprland)."
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width
              }

              Button {
                id: fixCursorButton
                width: parent.width
                text: root.cursorFixBusy ? "Fixing…" : "Fix: show the cursor by default"
                tooltipText: "Edits ~/.config/hypr/xdph.conf and restarts the desktop portal."
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.cursorFixEnabled
                opacity: enabled ? 1.0 : 0.6
                hasCursor: root.cursorActive && root.cursorIndex === 7
                onClicked: root.fixCursorNow()
                onHovered: function(isHovered) {
                  if (isHovered) { root.cursorActive = true; root.cursorIndex = 7 }
                }
              }

              // Explained, not merely disabled: a dead control with no reason
              // looks broken, and the moment someone reaches for this is when
              // they are most likely to be presenting.
              Text {
                visible: root.sharingActive
                textFormat: Text.PlainText
                text: "Disabled while you are sharing your screen -- restarting the portal would drop it."
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
                text: "This changes only the default for apps that do not ask. An app that explicitly requests a hidden cursor still hides it."
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
