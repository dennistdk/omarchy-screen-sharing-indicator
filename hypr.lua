-- Keeps the share ring out of other people's captures.
--
-- Hyprland fills every no_screen_share layer's bounding box with black when it
-- renders a monitor or region capture (CScreenshareFrame::renderMonitor). It
-- does not skip transparent pixels, so the bbox is the residual: four thin
-- strips cost the audience ~widthPx of black, while a full-output surface would
-- cost them the entire frame. Window captures never include layer-shell
-- surfaces at all.
--
-- Without this rule the presenter still gets a red ring, and so does everyone
-- watching a monitor share.
--
-- Loaded by a guarded dofile from the user's Hyprland config; see the plugin
-- README. The namespace is anchored so it cannot match anything else.
hl.layer_rule({
  match = { namespace = "^screen-sharing-indicator$" },
  no_screen_share = true,
  no_anim = true,
  animation = "none",
})

-- Proof the rule was applied. Nothing queries Hyprland's layer rules, so the
-- plugin compares this file's contents across config reloads to tell a fresh
-- write from a stale one, and never deletes it, so it still reads as "loaded,
-- as of last confirmed" across shell restarts between reloads. os.clock()
-- free-runs for the life of the Hyprland process, so paired with os.time() the
-- value never repeats between two runs of this file -- including two reloads
-- inside the same wall-clock second, where os.time() alone would tie.
local runtime = os.getenv("XDG_RUNTIME_DIR")
local sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
if runtime and sig then
  local f = io.open(runtime .. "/hypr/" .. sig .. "/screen-sharing-indicator-rule", "w")
  if f then
    f:write(tostring(os.time()) .. "." .. tostring(os.clock()))
    f:close()
  end
end
