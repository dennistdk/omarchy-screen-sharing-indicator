import QtQuick
import qs.Commons
import qs.Ui

// Bar chip for the Screen Sharing Indicator plugin.
//
// Follows the first-party pattern: the widget owns the button and lazily loads
// the panel, forwarding the open/close contract the bar's popout coordinator
// expects. All state comes from the service, so two monitors show the same
// thing without either of them polling.
BarWidget {
  id: root
  moduleName: "screen-sharing-indicator"

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor("screen-sharing-indicator") : null
  // svc.sharingNow, not svc.ringCount: the chip answers "is something being
  // captured", the strip count answers "is a ring drawn", and the ring toggles
  // pull those apart. It also keeps a three-second Preview ring from turning the
  // chip red. See Service.qml's sharingNow.
  readonly property bool sharing: svc ? svc.sharingNow === true : false
  readonly property bool pluginActive: svc ? svc.active : false

  // Always visible, dim when idle: an indicator that vanishes when idle cannot
  // be told apart from one that died. Nerd Font glyphs, as every other bar
  // plugin uses. The slashed eye is not decoration -- a switched-off indicator
  // is the one state where the bar must not look normal. Red and slashed at once
  // is reachable and meant to be: the plugin is paused while something is being
  // captured anyway, which is when you most need to know the ring is not there.
  readonly property string glyphEye: "󰈈"     // md-eye (U+F0208)
  readonly property string glyphEyeOff: "󰈉"  // md-eye-off (U+F0209)
  readonly property string glyph: pluginActive ? glyphEye : glyphEyeOff

  readonly property color defaultForeground: bar ? bar.foreground : Color.foreground
  readonly property color iconColor: sharing ? Color.urgent : defaultForeground
  readonly property real iconOpacity: sharing ? 1.0 : (pluginActive ? 0.55 : 0.3)

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("svc" in target) target.svc = root.svc
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for the bar's summon/hide/toggle routing. The bar identifies
  // a panel by the widget in its slot, so these live on this root rather than on
  // the nested panel.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onSvcChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    foreground: root.iconColor
    opacity: root.iconOpacity
    slotSize: Style.bar.statusSlot
    tooltipText: ""

    onPressed: function(b) { root.togglePanel() }
  }
}
