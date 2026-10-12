# A Raspberry Pi renders the desktop on VideoCore VII with shared memory
# bandwidth, where animations and transparency cost every frame and the 4 GB
# RAM variant needs the headroom more, so start it without them and with
# opaque windows, like a VM does. omarchy-toggle-animations and Appearance >
# Window Transparency bring them back. This runs before any Hyprland session
# exists, so place the flags directly rather than through the commands, which
# reload Hyprland.
if omarchy-hw-aarch64-pi; then
  echo "Detected a Raspberry Pi. Turning off animations and transparency by default."
  mkdir -p "$HOME/.local/state/omarchy/toggles/hypr"
  cp "$OMARCHY_PATH/default/hypr/toggles/no-animations.lua" "$HOME/.local/state/omarchy/toggles/hypr/"
  cp "$OMARCHY_PATH/default/hypr/toggles/window-opaque.lua" "$HOME/.local/state/omarchy/toggles/hypr/"
fi
