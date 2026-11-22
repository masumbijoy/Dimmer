# Dimmer

A tiny macOS menu-bar app that controls the **real backlight brightness** of an external monitor over DDC/CI, with the keyboard ☀︎ brightness keys, a slider, and Control Center shortcuts.

Built for an **LG 27UP85 (UltraFine 4K)** connected over USB-C to an Apple Silicon MacBook Air. macOS doesn't offer its own brightness slider for this monitor, and the monitor accepts DDC brightness *writes* but never answers *reads*, so Dimmer remembers the last value itself.

## Features

- Menu-bar slider plus 100 / 75 / 50 / 25 / 0% presets
- Keyboard ☀︎ brightness keys (F1 / F2) and **⌃⌥↑ / ⌃⌥↓**
- `dimmer://` links for Shortcuts, Control Center and Terminal
- Open at Login
- Hide the menu-bar icon; open Dimmer again (or `open dimmer://show`) to bring it back

## Requirements

- macOS on Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- [m1ddc](https://github.com/waydabber/m1ddc): `brew install m1ddc`

## Build and install

```bash
./build.sh
```

This builds `Dimmer.app`, installs it to `~/Applications`, and registers the `dimmer://` link scheme.

Then open **System Settings → Privacy & Security → Accessibility** and switch **Dimmer** on, so it can read the brightness keys.
> The app is ad-hoc signed, so macOS treats every rebuild as a new app. Switch it off and on again in Accessibility after rebuilding.

## Links

| Link | Action |
|---|---|
| `dimmer://up` | +5% |
| `dimmer://down` | −5% |
| `dimmer://set/50` | Set to 50% |
| `dimmer://show` | Show the menu-bar icon |
| `dimmer://hide` | Hide the menu-bar icon |

Example: `open dimmer://set/30`

## Control Center buttons

macOS only lets apps with a signed widget extension add native controls, so Dimmer uses Shortcuts instead:

1. In **Shortcuts**, create a shortcut named *Brightness Up* with a single **Open URLs** action: `dimmer://up`.
2. Do the same for *Brightness Down* with `dimmer://down`.
3. Open Control Center → **Edit Controls**, add **Run Shortcut**, and choose one of them.

## Files

- `main.swift`: the app
- `makeicon.swift`: draws the app icon at build time
- `build.sh`: builds, signs (ad-hoc) and installs the app
