-- Frosted glass behind the Omaview desktop dock, the same blur Omarchy's
-- Glassy bar uses (default/hypr/glass.lua). Save as ~/.config/hypr/omaview-blur.lua
-- and add `require("hypr.omaview-blur")` to ~/.config/hypr/hyprland.lua.
-- The overview itself draws its own tinted backdrop and needs no blur.
require("default.hypr.glass")()

hl.layer_rule({
  match = { namespace = "^omarchy-omaview-dock$" },
  blur = true,
  -- The dock's layer is wider than the dock to leave room for tooltips and
  -- menus; only the dock's own pixels are blurred, never the clear padding.
  ignore_alpha = 0.3,
  -- Blur the wallpaper behind the dock rather than windows, like a glassy bar.
  xray = true,
})
