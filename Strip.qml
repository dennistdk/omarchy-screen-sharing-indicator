import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Ui

// One edge of the ring. The surface *is* the ink: Hyprland's no_screen_share
// fills a layer's whole bounding box with black in monitor captures, so the
// bounding box has to be exactly as thin as the line. A full-output surface with
// a stroked ring inside it would black out the audience's entire stream.
PanelWindow {
  id: panel

  required property string stripId
  required property string screenName
  required property int boxX
  required property int boxY
  required property int boxW
  required property int boxH
  required property bool shown
  required property color stripColor
  required property bool pluginActive
  required property var screenResolver

  // Reading Quickshell.screens makes the lookup re-run when an output appears or
  // disappears. Calling screenResolver alone is not a tracked dependency and
  // would leave a strip pinned to a stale screen.
  readonly property var screenList: Quickshell.screens

  // Resolve once into our own property. Reading PanelWindow.screen from the
  // visible binding loops: the compositor re-resolves screen as the surface maps
  // and unmaps, which re-evaluates visible, which remaps it.
  readonly property var resolvedScreen: screenResolver && screenList ? screenResolver(screenName) : null

  screen: resolvedScreen
  visible: pluginActive && shown && boxW > 0 && boxH > 0 && resolvedScreen !== null && !remapGuard.remapping
  color: stripColor

  // One positioning mode for every strip, monitor edge and window-local alike:
  // top+left anchors, the box as margins and implicit size. Opposite-edge anchors
  // span a whole edge and cannot express an interior rectangle.
  anchors.top: true
  anchors.left: true
  margins.top: boxY
  margins.left: boxX
  implicitWidth: boxW
  implicitHeight: boxH

  exclusionMode: ExclusionMode.Ignore
  mask: Region {}

  WlrLayershell.namespace: "screen-sharing-indicator"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // above_lock is deliberately unset: the renderer skips non-above_lock layers
  // while the session is locked, which is exactly the behaviour we want.

  ScreenMoveRemap {
    id: remapGuard
    window: panel
  }
}
