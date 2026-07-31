# Changelog

## 1.4.0 — 2026-07-31

- Added dynamic CPU, GPU, display, and residual-power branches whose widths,
  labels, and terminal caps adapt to live power values.
- Added conservative CPU-power fallback estimation when a privileged
  `powermetrics` field is unavailable.
- Kept every flow label inside its animating ribbon, including the
  secondary battery path.
- Compact menu-bar battery now places the number inside the icon, omits the
  percent sign and separator gap, and turns green only while charging.
- Added a narrowly scoped launchd root helper so the same 1.4.0 binary needs
  administrator approval only once, including across relaunches and reboots.
- Added fixed-path staging, identifier plus CDHash validation, client UID
  validation, and a three-method XPC API with no arbitrary command surface.

### Known limitations

- Apple Silicon and macOS 13 or newer are required.
- The downloadable build is hardened ad-hoc signed but not Apple notarized.
- Rebuilding or upgrading changes the exact CDHash and requires one new
  approval. Stable cross-version identity requires Developer ID signing,
  notarization, and migration to `SMAppService`.
