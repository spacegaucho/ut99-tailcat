# Headless / Xvfb

Part of the [ut99-tailcat](../README.md) docs.

`ut99 client` runs the game under `xvfb-run` automatically when `DISPLAY` is
unset (ssh sessions, CI). Notes learned the hard way:

- The Xvfb screen **must match** the game's `FullscreenViewportX/Y` in
  `UnrealTournament.ini` (default here: 2560x1440). A mismatch makes the
  swapchain resize mid-startup and wine dies with an `X BadWindow` error.
  Use `--xvfb-res` to match a different ini resolution.
- Depth is fixed at **24-bit**: this system's Xvfb refuses 32-bit screens
  (`Couldn't add screen 0`), and a 24-bit root window maps to 32-bit D3D
  rendering exactly like a real desktop does.
- Headless Xvfb sessions still play game audio on your real sound device.
- `--no-xvfb` forces your real `DISPLAY`; `UT99_XVFB_RES` overrides the size.
